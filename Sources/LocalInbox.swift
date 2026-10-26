import Foundation
import Darwin

/// A proposed local task. Reading this record never completes work or controls an agent.
struct TaskProposal: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let nextAction: String
    let source: String
    let createdAt: Date
}

enum LocalInboxError: LocalizedError {
    case invalid(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Local updates could not be read: \(reason)"
        case .unavailable: return "The local updates file is busy or unavailable. Try again."
        }
    }
}

/// Explicit review only: this type has no watcher, network requests, or timer.
struct LocalInbox {
    static let maximumBytes = 256 * 1024
    static let maximumProposals = 100
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("inbox.json") }
    private var lockURL: URL { directory.appendingPathComponent(".inbox.lock") }

    private struct Envelope: Codable {
        let version: Int
        var proposals: [TaskProposal]
    }

    func load() throws -> [TaskProposal] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try withLock(exclusive: false) { try readEnvelope().proposals }
    }

    /// Removes only reviewed IDs while retaining proposals added after the preview.
    func consume(ids: Set<UUID>) throws {
        guard !ids.isEmpty, FileManager.default.fileExists(atPath: directory.path) else { return }
        try withLock(exclusive: true) {
            var envelope = try readEnvelope()
            let originalCount = envelope.proposals.count
            envelope.proposals.removeAll { ids.contains($0.id) }
            guard envelope.proposals.count != originalCount else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private func readEnvelope() throws -> Envelope {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Envelope(version: 1, proposals: [])
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalInboxError.invalid("use a regular inbox.json file, not a link or folder.")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else {
            throw LocalInboxError.invalid("the file exceeds 256 KB.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { throw LocalInboxError.invalid("the file is not a valid version 1 proposal list.") }
        guard envelope.version == 1 else {
            throw LocalInboxError.invalid("this version is not supported.")
        }
        guard envelope.proposals.count <= Self.maximumProposals else {
            throw LocalInboxError.invalid("there are more than 100 proposals.")
        }
        guard Set(envelope.proposals.map(\.id)).count == envelope.proposals.count else {
            throw LocalInboxError.invalid("proposal IDs must be unique.")
        }
        for item in envelope.proposals {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.title.count <= 200,
                  item.nextAction.count <= 600,
                  item.source.count <= 160 else {
                throw LocalInboxError.invalid("a task is empty or exceeds its text limit.")
            }
        }
        return envelope
    }

    private func withLock<T>(exclusive: Bool, operation: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalInboxError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            throw LocalInboxError.unavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
