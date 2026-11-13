import Foundation

final class RelayTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}

actor TimeoutRelayWire {
    let serverID = UUID()
    var limits: [Int] = []
    var cursors: [Int64] = []
    var batchSizes: [Int] = []
    var accepted = Set<String>()
    var mode = 0
    let clock: RelayTestClock?
    var timeouts: [TimeInterval] = []
    init(clock: RelayTestClock? = nil) { self.clock = clock }
    func setMode(_ value: Int) { mode = value }
    func attempts() -> ([Int], [Int64], [Int], Int) { (limits, cursors, batchSizes, accepted.count) }
    func deadlines() -> [TimeInterval] { timeouts }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        timeouts.append(request.timeoutInterval)
        if mode == 2 { throw CancellationError() }
        if mode == 3 { return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) }
        let data: Data
        if request.url!.lastPathComponent == "bist_sync_pull" {
            let parameters = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let limit = parameters["p_limit"] as! Int
            let cursor = (parameters["p_after"] as! NSNumber).int64Value
            limits.append(limit); cursors.append(cursor)
            if mode == 4 {
                clock?.advance(request.timeoutInterval + 0.01)
                throw URLError(.timedOut)
            }
            if mode == 5 && limit > 1 {
                return (Data(#"{"code":"57014","message":"canceling statement due to statement timeout"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            if limit > 1 || mode == 1 { throw URLError(.timedOut) }
            data = try JSONEncoder().encode(SupabasePullPage(events: [], nextCursor: cursor, hasMore: false, serverID: serverID))
        } else {
            struct Parameters: Decodable { let p_events: [SupabaseRelayEvent] }
            let events = try JSONDecoder().decode(Parameters.self, from: request.httpBody!).p_events
            batchSizes.append(events.count)
            if mode == 4 {
                clock?.advance(request.timeoutInterval + 0.01)
                throw URLError(.timedOut)
            }
            if mode == 5 && events.count > 1 {
                return (Data(#"{"code":"57014","message":"canceling statement due to statement timeout"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }
            // The server may commit before the response times out. Retries
            // must use the exact same event IDs and tolerate that ambiguity.
            accepted.formUnion(events.map(\.eventID))
            if events.count > 1 || mode == 1 { throw URLError(.timedOut) }
            data = try JSONEncoder().encode(SupabasePushReceipt(accepted: events.map(\.eventID), serverID: serverID))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

actor TestSupabaseRelay: SupabaseRelayAPI {
    var serverID = UUID()
    var feeds: [String: [SupabaseFeedEvent]] = [:]
    var failPush = false
    var loseReceipt = false
    var invalidPage = false
    var beforeReceipt: (@Sendable () async -> Void)?
    var pageSize = 2

    func setFailPush(_ value: Bool) { failPush = value }
    func loseNextReceipt() { loseReceipt = true }
    func makeNextPageInvalid() { invalidPage = true }
    func resetServer() { serverID = UUID(); feeds = [:] }
    func setBeforeReceipt(_ action: @escaping @Sendable () async -> Void) { beforeReceipt = action }
    func count(_ token: String) -> Int { feeds[token, default: []].count }

    func pull(after: Int64, accessToken: String) async throws -> SupabasePullPage {
        let all = feeds[accessToken, default: []]
        let events = Array(all.filter { $0.sequence > after }.prefix(pageSize))
        let next = events.last?.sequence ?? after
        if invalidPage {
            invalidPage = false
            let invalid = ReplicaRecord(id: "note.main", kind: "note", fields: [:])
            let event = try SupabaseRelayEvent(record: invalid)
            return SupabasePullPage(events: [.init(sequence: after + 1, eventID: event.eventID, record: invalid)], nextCursor: after + 1, hasMore: false, serverID: serverID)
        }
        return SupabasePullPage(events: events, nextCursor: next, hasMore: all.contains { $0.sequence > next }, serverID: serverID)
    }

    func push(_ events: [SupabaseRelayEvent], accessToken: String) async throws -> SupabasePushReceipt {
        if failPush { throw URLError(.notConnectedToInternet) }
        var feed = feeds[accessToken, default: []]
        for event in events where !feed.contains(where: { $0.eventID == event.eventID }) {
            feed.append(.init(sequence: (feed.last?.sequence ?? 0) + 1, eventID: event.eventID, record: event.record))
        }
        feeds[accessToken] = feed
        if let action = beforeReceipt { beforeReceipt = nil; await action() }
        if loseReceipt { loseReceipt = false; throw URLError(.networkConnectionLost) }
        return SupabasePushReceipt(accepted: events.map(\.eventID), serverID: serverID)
    }
}

@main
struct SupabaseSyncTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-supabase-relay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        func make(_ name: String) throws -> (AppStore, NoteStore, BistReplicaBridge) {
            let directory = root.appendingPathComponent(name)
            let store = AppStore(directory: directory)
            let note = NoteStore(directory: directory)
            return (store, note, try BistReplicaBridge(store: store, note: note))
        }
        func transport(_ bridge: BistReplicaBridge, _ relay: TestSupabaseRelay, token: String = "owner") throws -> SupabaseReplicaTransport {
            try SupabaseReplicaTransport(bridge: bridge, scope: "project/" + token, relay: relay, credentials: { token })
        }

        let slowWire = TimeoutRelayWire()
        let configuration = try SupabaseConfiguration(projectURL: URL(string: "https://project.test")!, publishableKey: "sb_publishable_test")
        let slowClient = SupabaseRelayClient(configuration: configuration, sender: { try await slowWire.send($0) })
        let smallPage = try await slowClient.pull(after: 41, accessToken: "owner")
        let pullAttempts = await slowWire.attempts()
        expect(smallPage.nextCursor == 41 && pullAttempts.0 == [100, 50, 25, 12, 6, 3, 1],
               "A timed-out page must retry smaller limits down to one event")
        expect(Set(pullAttempts.1) == [41], "Smaller-page retries must never advance the durable cursor")
        let slowEvents = try (0..<5).map { index in
            try SupabaseRelayEvent(record: ReplicaRecord(id: "task." + UUID().uuidString.lowercased(), kind: "task", fields: [
                "title": ReplicaField(value: try JSONEncoder().encode("Slow \(index)"), stamp: ReplicaStamp(counter: 1, deviceID: "slow-wire"))
            ]))
        }
        let receipt = try await slowClient.push(slowEvents, accessToken: "owner")
        let pushAttempts = await slowWire.attempts()
        expect(receipt.accepted == slowEvents.map(\.eventID) && pushAttempts.2.contains(1),
               "Timed-out uploads split into smaller batches and retain exact accepted event identities")
        expect(pushAttempts.3 == slowEvents.count, "A response lost after server commit cannot duplicate immutable events")
        await slowWire.setMode(1)
        do { _ = try await slowClient.pull(after: 41, accessToken: "owner"); preconditionFailure("One-event timeout must still surface") }
        catch let error as URLError { expect(error.code == .timedOut, "Minimum page timeouts remain retryable failures") }
        do { _ = try await slowClient.push([slowEvents[0]], accessToken: "owner"); preconditionFailure("One-event timeout must still surface") }
        catch let error as URLError { expect(error.code == .timedOut, "Minimum upload timeouts remain retryable failures") }
        for mode in [2, 3] {
            await slowWire.setMode(mode)
            let before = await slowWire.attempts()
            do { _ = try await slowClient.pull(after: 41, accessToken: "owner"); preconditionFailure("Cancellation and auth failure cannot be hidden by retries") }
            catch is CancellationError { expect(mode == 2, "Expected task cancellation") }
            catch SupabaseSyncError.signInRequired { expect(mode == 3, "Expected sign-in failure") }
            let after = await slowWire.attempts()
            expect(before.0 == after.0, "Adaptive transfer retry must not retry cancellation or authorization failures")
        }
        for pulling in [true, false] {
            let clock = RelayTestClock()
            let stalledWire = TimeoutRelayWire(clock: clock)
            await stalledWire.setMode(4)
            let stalled = SupabaseRelayClient(configuration: configuration, sender: { try await stalledWire.send($0) }, now: { clock.now() })
            do {
                if pulling { _ = try await stalled.pull(after: 41, accessToken: "owner") }
                else { _ = try await stalled.push(slowEvents, accessToken: "owner") }
                preconditionFailure("A dead connection must surface its timeout")
            } catch let error as URLError { expect(error.code == .timedOut, "The deadline preserves the network failure") }
            let deadlines = await stalledWire.deadlines()
            expect(deadlines.count == 2 && deadlines[0] == 90 && deadlines[1] < 30,
                   "A dead connection gets at most the shared two-minute retry window, including upload halves")
            expect(clock.now() < 121, "No-progress retries cannot occupy sync for ten minutes")
        }
        await slowWire.setMode(5)
        expect(try await slowClient.pull(after: 41, accessToken: "owner").nextCursor == 41,
               "A PostgREST statement timeout shrinks the page without advancing its cursor")
        expect(try await slowClient.push(slowEvents, accessToken: "owner").accepted == slowEvents.map(\.eventID),
               "A PostgREST statement timeout splits a batch without relaxing server limits")

        let relay = TestSupabaseRelay()
        let (mac, macNote, macBridge) = try make("mac")
        let (phone, phoneNote, phoneBridge) = try make("phone")
        let macSync = try transport(macBridge, relay)
        let phoneSync = try transport(phoneBridge, relay)
        precondition(mac.addTask(title: "Shared task"))
        let id = mac.tasks[0].id
        macNote.update("Original note"); macNote.save()
        try await macSync.synchronize()
        try await phoneSync.synchronize()
        expect(phone.tasks.first?.id == id, "Phone receives the same task identity")
        expect(phoneNote.text == "Original note", "Phone receives the Mac note")
        expect(try macBridge.database.pendingRecords().isEmpty, "Accepted uploads are acknowledged")
        expect(try phoneBridge.database.pendingRecords().isEmpty, "A fresh replica converges without unsent seed records")

        precondition(mac.updateTask(id: id, title: "Mac offline title", notes: "", nextAction: ""))
        precondition(phone.setUserCompletion(id: id, completed: true))
        macNote.update("Mac concurrent note"); macNote.save()
        phoneNote.update("Phone concurrent note"); phoneNote.save()
        try await phoneSync.synchronize(); try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.first?.title == "Mac offline title", "Independent offline title survives phone completion")
        expect(mac.tasks.first?.completed == true, "Independent phone completion survives Mac title")
        expect(macNote.text == phoneNote.text, "Concurrent notes resolve deterministically")
        let versions = try macBridge.noteVersions()
        expect(versions.contains("Mac concurrent note") || versions.contains("Phone concurrent note"), "The competing note remains recoverable")
        expect(try macBridge.database.records() == phoneBridge.database.records(), "Paginated feed converges all records")

        precondition(mac.deleteTask(id: id, includingSubtasks: false))
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.isEmpty, "Tombstones propagate without erasing the deletion stamp")
        expect(mac.undo(), "Local undo restores the deletion")
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.first?.id == id, "Explicit restoration crosses the relay")

        precondition(mac.addTask(title: "Retry me"))
        await relay.setFailPush(true)
        do { try await macSync.synchronize(); preconditionFailure("Offline push must fail") } catch is URLError {}
        expect(try !macBridge.database.pendingRecords().isEmpty, "Offline failure preserves pending changes")
        await relay.setFailPush(false); await relay.loseNextReceipt()
        do { try await macSync.synchronize(); preconditionFailure("Lost receipt must fail") } catch is URLError {}
        expect(try !macBridge.database.pendingRecords().isEmpty, "A lost response cannot ACK an upload")
        let countAfterLoss = await relay.count("owner")
        try await macSync.synchronize()
        expect(await relay.count("owner") == countAfterLoss, "Lost-response retries reuse immutable event IDs")
        expect(try macBridge.database.pendingRecords().isEmpty, "Retry eventually ACKs exact accepted bodies")

        precondition(mac.addTask(title: "Older in-flight body"))
        let duringID = mac.tasks.last!.id
        await relay.setBeforeReceipt { @MainActor in
            precondition(mac.updateTask(id: duringID, title: "Newer local body", notes: "", nextAction: ""))
        }
        try await macSync.synchronize()
        expect(try macBridge.database.pendingRecords().contains { $0.id == "task." + duringID.uuidString.lowercased() }, "An edit during upload remains pending after the old body ACK")
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.contains { $0.title == "Newer local body" }, "The newer in-flight edit eventually arrives")

        let oldCursor = try phoneBridge.database.metadata(forKey: phoneSync.cursorKey)
        let oldRecords = try phoneBridge.database.records()
        await relay.makeNextPageInvalid()
        do { try await phoneSync.synchronize(); preconditionFailure("Invalid portable payload must fail") } catch is ReplicaError {}
        expect(try phoneBridge.database.metadata(forKey: phoneSync.cursorKey) == oldCursor, "Rejected records cannot advance a cursor")
        expect(try phoneBridge.database.records() == oldRecords, "Rejected pages cannot mutate accepted records")

        let (_, _, otherBridge) = try make("other-account")
        let otherSync = try transport(otherBridge, relay, token: "other-user")
        try await otherSync.synchronize()
        expect(try !otherBridge.database.records().contains { $0.kind == "task" }, "The client carries each user's token on both fetch and upload")
        do { _ = try transport(macBridge, relay, token: "other-user"); preconditionFailure("Account changes require an explicit review") }
        catch SupabaseSyncError.accountChanged { checks += 1 }

        let (_, _, stoppedBridge) = try make("stopped")
        let stoppedSync = try transport(stoppedBridge, relay, token: "stopped")
        await relay.setBeforeReceipt { @MainActor in stoppedSync.stop() }
        do { try await stoppedSync.synchronize(); preconditionFailure("A stopped transport cannot ACK its old request") } catch is CancellationError {}
        expect(try !stoppedBridge.database.pendingRecords().isEmpty, "Stopping during upload preserves the new backend's outbox")

        await relay.resetServer()
        do { try await phoneSync.synchronize(); preconditionFailure("A replaced project must pause") } catch SupabaseSyncError.serverChanged {}
        expect(phoneSync.recoveryRequired, "Server replacement persists a recovery pause")
        expect(try phoneBridge.database.records() == oldRecords, "A server reset never empties local tasks")
        try phoneSync.authorizeRecovery()
        try await phoneSync.synchronize()
        expect(!phoneSync.recoveryRequired, "Explicit backed-up recovery resumes sync")
        expect(try phoneBridge.database.pendingRecords().isEmpty, "Recovery reuploads retained data")
        let backups = try FileManager.default.contentsOfDirectory(at: phoneBridge.database.directory.appendingPathComponent("supabase-recovery"), includingPropertiesForKeys: nil)
        expect(backups.count == 1, "Recovery saves a portable local backup before clearing the cursor")
        print("PASS \(checks) Supabase replica transport checks")
    }
}
