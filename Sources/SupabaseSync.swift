import Foundation
import CryptoKit

enum SupabaseSyncError: Error, LocalizedError, Equatable {
    case invalidResponse, signInRequired, accountChanged, serverChanged, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The sync service returned unreadable data. Your local changes are still saved. Try again after checking the project setup."
        case .signInRequired: return "Sign in again to continue syncing. Your local changes are still saved."
        case .accountChanged: return "This device was connected to another sync account. Review the account before combining its data."
        case .serverChanged: return "The saved project history changed. Restore this device’s data to the project to resume syncing."
        case .tooLarge: return "A change is too large for the sync service. It remains saved on this device."
        case .unavailable: return "The sync project is unavailable. Check its Supabase dashboard and try again. Your local changes are still saved."
        }
    }
}

struct SupabaseRelayEvent: Codable, Equatable, Sendable {
    let eventID: String
    let record: ReplicaRecord
    enum CodingKeys: String, CodingKey { case eventID = "event_id", record }
    init(record: ReplicaRecord) throws {
        self.record = record
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        eventID = SHA256.hash(data: try encoder.encode(record)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SupabaseFeedEvent: Codable, Equatable, Sendable {
    let sequence: Int64
    let eventID: String
    let record: ReplicaRecord
    enum CodingKeys: String, CodingKey { case sequence, eventID = "event_id", record }
}

struct SupabasePullPage: Codable, Sendable {
    let events: [SupabaseFeedEvent]
    let nextCursor: Int64
    let hasMore: Bool
    let serverID: UUID
    enum CodingKeys: String, CodingKey {
        case events, nextCursor = "next_cursor", hasMore = "has_more", serverID = "server_id"
    }
}

struct SupabasePushReceipt: Codable, Sendable {
    let accepted: [String]
    let serverID: UUID
    enum CodingKeys: String, CodingKey { case accepted, serverID = "server_id" }
}

protocol SupabaseRelayAPI: Sendable {
    func pull(after: Int64, accessToken: String) async throws -> SupabasePullPage
    func push(_ events: [SupabaseRelayEvent], accessToken: String) async throws -> SupabasePushReceipt
}

struct SupabaseRelayClient: SupabaseRelayAPI {
    let configuration: SupabaseConfiguration
    private let sender: SupabaseHTTPSender
    private let now: @Sendable () -> TimeInterval
    static let maximumBytes = 64 * 1024 * 1024
    init(configuration: SupabaseConfiguration, sender: SupabaseHTTPSender? = nil,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.now = now
        self.sender = sender ?? { try await SupabaseHTTP.send($0, maximumResponseBytes: Self.maximumBytes, transfer: .replica) }
    }
    func pull(after: Int64, accessToken: String) async throws -> SupabasePullPage {
        struct Parameters: Encodable { let p_after: Int64; let p_limit: Int }
        let deadline = now() + 120
        var limit = 100
        while true {
            try Task.checkCancellation()
            do { return try await call("bist_sync_pull", body: Parameters(p_after: after, p_limit: limit), accessToken: accessToken, deadline: deadline) }
            catch let error as URLError where error.code == .timedOut && limit > 1 {
                // Retry the same cursor with less history. Never skip a large
                // event or advance a cursor because a response timed out.
                limit = max(1, limit / 2)
            }
        }
    }
    func push(_ events: [SupabaseRelayEvent], accessToken: String) async throws -> SupabasePushReceipt {
        try await push(events, accessToken: accessToken, deadline: now() + 120)
    }
    private func push(_ events: [SupabaseRelayEvent], accessToken: String, deadline: TimeInterval) async throws -> SupabasePushReceipt {
        struct Parameters: Encodable { let p_events: [SupabaseRelayEvent] }
        guard events.count <= 32 else { throw SupabaseSyncError.tooLarge }
        try Task.checkCancellation()
        do { return try await call("bist_sync_push", body: Parameters(p_events: events), accessToken: accessToken, deadline: deadline) }
        catch let error as URLError where error.code == .timedOut && events.count > 1 {
            // A timed-out request may already have committed. Keep immutable
            // IDs when splitting so the server can deduplicate every retry.
            let midpoint = events.count / 2
            let first = try await push(Array(events[..<midpoint]), accessToken: accessToken, deadline: deadline)
            let second = try await push(Array(events[midpoint...]), accessToken: accessToken, deadline: deadline)
            guard first.serverID == second.serverID else { throw SupabaseSyncError.serverChanged }
            return SupabasePushReceipt(accepted: first.accepted + second.accepted, serverID: first.serverID)
        }
    }
    private func call<Body: Encodable, Value: Decodable>(_ name: String, body: Body, accessToken: String, deadline: TimeInterval) async throws -> Value {
        guard !accessToken.isEmpty, !accessToken.contains("\n"), !accessToken.contains("\r") else { throw SupabaseSyncError.signInRequired }
        var request = URLRequest(url: configuration.projectURL.appendingPathComponent("rest/v1/rpc/" + name))
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        guard request.httpBody!.count <= Self.maximumBytes else { throw SupabaseSyncError.tooLarge }
        // Share one retry window across page reductions and both upload
        // halves. A dead connection cannot multiply the 90s idle timeout.
        // A response that keeps making progress may still finish under the
        // separate resource timeout, but cannot start more retries afterward.
        let remaining = deadline - now()
        guard remaining > 0 else { throw URLError(.timedOut) }
        request.timeoutInterval = min(90, remaining)
        let (data, response) = try await sender(request)
        guard data.count <= Self.maximumBytes else { throw SupabaseSyncError.tooLarge }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw SupabaseSyncError.signInRequired
        case 413: throw SupabaseSyncError.tooLarge
        default:
            // Match our own stable marker only. Never show server bodies, which
            // can contain submitted data or diagnostic credentials.
            if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (value["message"] as? String)?.contains("BIST_CURSOR_AHEAD") == true {
                    throw SupabaseSyncError.serverChanged
                }
                if response.statusCode == 500, value["code"] as? String == "57014" {
                    throw URLError(.timedOut)
                }
            }
            throw SupabaseSyncError.unavailable
        }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw SupabaseSyncError.invalidResponse }
    }
}

/// A single backend owns the durable outbox at a time. The relay stores immutable
/// portable revisions; established SQLite merge owns conflict resolution.
@MainActor
final class SupabaseReplicaTransport {
    static let bindingKey = "supabase.binding"
    private let bridge: BistReplicaBridge
    private let relay: any SupabaseRelayAPI
    private let credentials: @MainActor () async throws -> String
    private let isCurrent: @MainActor () -> Bool
    private let prefix: String
    private var active = true
    let scope: String
    var cursorKey: String { prefix + ".cursor" }
    var serverKey: String { prefix + ".server" }
    var pauseKey: String { prefix + ".paused" }

    init(bridge: BistReplicaBridge, scope: String, relay: any SupabaseRelayAPI,
         credentials: @escaping @MainActor () async throws -> String,
         isCurrent: @escaping @MainActor () -> Bool = { true }) throws {
        self.bridge = bridge; self.scope = scope; self.relay = relay
        self.credentials = credentials; self.isCurrent = isCurrent
        prefix = "supabase." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        if let binding = try bridge.database.metadata(forKey: Self.bindingKey) {
            guard binding == Data(scope.utf8) else { throw SupabaseSyncError.accountChanged }
        } else {
            // Requeue before remembering a first connection so a crash cannot
            // leave an acknowledged local record absent from this new backend.
            try bridge.database.enqueueAll()
            try bridge.database.setMetadata(Data(scope.utf8), forKey: Self.bindingKey)
        }
    }

    func stop() { active = false }
    var recoveryRequired: Bool { (try? bridge.database.metadata(forKey: pauseKey)) != nil }

    func synchronize() async throws {
        try checkActive()
        guard !recoveryRequired else { throw SupabaseSyncError.serverChanged }
        do {
            try await fetch()
            // Snapshot only after merging remote records. Exact-body ACK keeps
            // any edit made while a request is in flight in the durable outbox.
            let pending = try bridge.database.pendingRecords()
            var batch = [SupabaseRelayEvent]()
            var bytes = 32
            for record in pending {
                let event = try SupabaseRelayEvent(record: record)
                let count = try JSONEncoder().encode(event).count + 1
                guard count <= 48 * 1024 * 1024 else { throw SupabaseSyncError.tooLarge }
                if !batch.isEmpty && (batch.count == 32 || bytes + count > 60 * 1024 * 1024) {
                    try await upload(batch); batch = []; bytes = 32
                }
                batch.append(event); bytes += count
            }
            if !batch.isEmpty { try await upload(batch) }
            // Read back accepted revisions and concurrent commits before
            // reporting success. Do not synthesize a cursor from upload ACKs.
            try await fetch()
        } catch SupabaseSyncError.serverChanged {
            if active && isCurrent() { try bridge.database.setMetadata(Data("1".utf8), forKey: pauseKey) }
            throw SupabaseSyncError.serverChanged
        }
    }

    private func checkActive() throws {
        guard active, isCurrent(), !Task.isCancelled else { throw CancellationError() }
    }
    private func cursor() throws -> Int64 {
        guard let bytes = try bridge.database.metadata(forKey: cursorKey) else { return 0 }
        guard let value = String(data: bytes, encoding: .utf8).flatMap(Int64.init), value >= 0 else { throw SupabaseSyncError.invalidResponse }
        return value
    }
    private func checkServer(_ id: UUID) throws {
        if let known = try bridge.database.metadata(forKey: serverKey), known != Data(id.uuidString.lowercased().utf8) {
            throw SupabaseSyncError.serverChanged
        }
    }
    private func fetch() async throws {
        var after = try cursor()
        var pages = 0
        while true {
            try checkActive()
            let token = try await credentials()
            try checkActive()
            let page = try await relay.pull(after: after, accessToken: token)
            try checkActive()
            try checkServer(page.serverID)
            guard page.events.count <= 100, page.nextCursor >= after,
                  (page.events.last?.sequence ?? after) == page.nextCursor,
                  !page.hasMore || !page.events.isEmpty else { throw SupabaseSyncError.invalidResponse }
            var previous = after
            for event in page.events {
                guard event.sequence > previous,
                      event.eventID == (try SupabaseRelayEvent(record: event.record)).eventID else { throw SupabaseSyncError.invalidResponse }
                previous = event.sequence
            }
            // Validation, merge and the new cursor commit together. Invalid
            // records must not consume a page or erase unsent local work.
            let metadata = [
                cursorKey: Data(String(page.nextCursor).utf8), serverKey: Data(page.serverID.uuidString.lowercased().utf8)
            ]
            if page.events.isEmpty {
                // An idle poll changes only durable transport metadata. Avoid
                // re-exporting state.json and touching note/editor state.
                try bridge.database.merge(remote: [], metadata: metadata)
            } else { try bridge.receive(page.events.map(\.record), metadata: metadata) }
            after = page.nextCursor
            if !page.hasMore { return }
            pages += 1
            guard pages < 100_000 else { throw SupabaseSyncError.invalidResponse }
        }
    }
    private func upload(_ events: [SupabaseRelayEvent]) async throws {
        try checkActive()
        let token = try await credentials()
        try checkActive()
        let receipt = try await relay.push(events, accessToken: token)
        try checkActive()
        try checkServer(receipt.serverID)
        guard receipt.accepted.count == events.count,
              Set(receipt.accepted) == Set(events.map(\.eventID)) else { throw SupabaseSyncError.invalidResponse }
        try bridge.database.acknowledge(events.map(\.record))
    }

    /// Called only after a visible recovery/account-merge confirmation. Save a
    /// portable local backup first; never discard local records or notes.
    func authorizeRecovery() throws {
        try checkActive()
        try Self.authorizeConnection(bridge: bridge, scope: scope)
    }

    static func authorizeConnection(bridge: BistReplicaBridge, scope: String) throws {
        let prefix = "supabase." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = bridge.database.directory.appendingPathComponent("supabase-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bridge.database.records())
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try bridge.database.enqueueAll()
        try bridge.database.apply([], metadata: [prefix + ".cursor": nil, prefix + ".server": nil,
                                               prefix + ".paused": nil, bindingKey: Data(scope.utf8)])
    }
}
