import Foundation
import Darwin

/// A local claim about an agent output. It is not completion evidence until the
/// user reviews the output and the store accepts it for the linked task/session.
struct AgentResultProposal: Codable, Identifiable, Equatable {
    let id: UUID
    let taskID: UUID
    let sessionID: UUID
    let artifactURL: String
    let summary: String
    let observedAt: Date
}

enum AgentResultsError: LocalizedError {
    case invalid(String)
    case unavailable
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Agent results could not be read: \(reason)"
        case .unavailable: return "The local results file is busy or unavailable. Try again."
        }
    }
}

/// Bounded, explicit review only. This type never polls, contacts an agent,
/// imports a conversation, or changes task/session state when a file arrives.
struct AgentResultsInbox {
    static let maximumBytes = 256 * 1024
    static let maximumResults = 100
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("agent-results.json") }
    private var lockURL: URL { directory.appendingPathComponent(".agent-results.lock") }

    private struct Envelope: Codable {
        let version: Int
        var results: [AgentResultProposal]
    }

    func load(now: Date = Date()) throws -> [AgentResultProposal] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try withLock(exclusive: false) { try readEnvelope(now: now).results }
    }

    /// Consume only accepted IDs. A retry is harmless, and records added after
    /// the preview survive. Malformed input is never rewritten.
    func consume(ids: Set<UUID>, now: Date = Date()) throws {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: directory.path) else { return }
        try withLock(exclusive: true) {
            var envelope = try readEnvelope(now: now)
            let previousCount = envelope.results.count
            envelope.results.removeAll { ids.contains($0.id) }
            guard previousCount != envelope.results.count else { return }
            try writeEnvelope(envelope)
        }
    }

    /// The review UI uses this form so a changed payload with a reused ID can
    /// never be silently removed after an earlier version was reviewed.
    func consume(proposal: AgentResultProposal, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try withLock(exclusive: true) {
            var envelope = try readEnvelope(now: now)
            guard let index = envelope.results.firstIndex(where: { $0.id == proposal.id }) else { return }
            guard envelope.results[index] == proposal else {
                throw AgentResultsError.invalid("the queued result changed after review. Reload to inspect it.")
            }
            envelope.results.remove(at: index)
            try writeEnvelope(envelope)
        }
    }

    private func writeEnvelope(_ envelope: Envelope) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumBytes else {
            throw AgentResultsError.invalid("the updated file would exceed 256 KB.")
        }
        // The temporary file is private from creation, including before the
        // atomic rename; there is no wider-permission window for output URLs.
        let temporary = directory.appendingPathComponent(".agent-results-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AgentResultsError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, fileURL.path) == 0 else { throw AgentResultsError.unavailable }
    }

    static func safeURL(_ string: String) -> URL? {
        guard string.count <= 4096,
              string.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let value = URL(string: string),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil else { return nil }
        return value
    }

    private func readEnvelope(now: Date) throws -> Envelope {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return Envelope(version: 1, results: []) }
            throw AgentResultsError.invalid("use a readable regular agent-results.json file, not a link or folder.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw AgentResultsError.invalid("use a regular agent-results.json file, not a link or folder.")
        }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw AgentResultsError.invalid("the file exceeds 256 KB.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw AgentResultsError.invalid("the file is not a valid version 1 result list.") }
        guard envelope.version == 1 else { throw AgentResultsError.invalid("this version is not supported.") }
        guard envelope.results.count <= Self.maximumResults else {
            throw AgentResultsError.invalid("there are more than 100 results.")
        }
        guard Set(envelope.results.map(\.id)).count == envelope.results.count else {
            throw AgentResultsError.invalid("result IDs must be unique.")
        }
        for result in envelope.results {
            guard !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentResultsError.invalid("each result needs a nonblank output summary.")
            }
            guard result.summary.count <= 2000 else { throw AgentResultsError.invalid("a summary exceeds 2,000 characters.") }
            guard Self.safeURL(result.artifactURL) != nil else {
                throw AgentResultsError.invalid("output links must be full http or https URLs without account credentials.")
            }
            guard result.observedAt >= Date(timeIntervalSince1970: 0), result.observedAt <= now.addingTimeInterval(60) else {
                throw AgentResultsError.invalid("an observation time is invalid or in the future.")
            }
        }
        return envelope
    }

    private func withLock<T>(exclusive: Bool, operation: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw AgentResultsError.unavailable }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw AgentResultsError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
