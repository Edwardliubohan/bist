import Foundation
import Combine

struct SessionReply {
    let text: String
    let failed: Bool
    let date: Date
}

/// Runs a single noninteractive continuation of the exact selected session.
/// stdin and output use private files so prompts never enter a shell or argv.
final class SessionMessageRunner: @unchecked Sendable {
    let process = Process()

    static func arguments(_ session: LocalAgentSession) -> [String] {
        session.provider == .codex
            ? ["exec", "resume", session.sessionID.uuidString.lowercased(), "-"]
            : ["--resume", session.sessionID.uuidString.lowercased(), "--print", "--output-format", "text"]
    }

    func run(_ session: LocalAgentSession, text: String, executable: String) throws -> SessionReply {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bist-message-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input")
        let output = folder.appendingPathComponent("output")
        let lastMessage = folder.appendingPathComponent("last-message")
        try Data(text.utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let reader = try FileHandle(forReadingFrom: input)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Self.arguments(session)
        if session.provider == .codex { process.arguments! += ["--output-last-message", lastMessage.path] }
        process.currentDirectoryURL = URL(fileURLWithPath: session.directory)
        var environment = ProcessInfo.processInfo.environment
        if let directory = session.configurationDirectory {
            environment[session.provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = directory
        }
        // Do not inherit a parent Claude invocation's nesting marker.
        environment.removeValue(forKey: "CLAUDECODE")
        process.environment = environment
        process.standardInput = reader
        process.standardOutput = writer
        process.standardError = writer
        try process.run()
        process.waitUntilExit()
        let resultReader = try FileHandle(forReadingFrom: process.terminationStatus == 0 && FileManager.default.fileExists(atPath: lastMessage.path) ? lastMessage : output)
        defer { try? resultReader.close() }
        let size = try resultReader.seekToEnd()
        try resultReader.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let data = try resultReader.read(upToCount: 16_384) ?? Data()
        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionReply(text: result.isEmpty ? (process.terminationStatus == 0 ? "Turn finished without text." : "The CLI exited without a response. Open in Terminal to check login and permissions.") : result,
                            failed: process.terminationStatus != 0, date: Date())
    }
}

extension LocalSessionConnection {
    func send(_ text: String, to session: LocalAgentSession, executableOverride: String? = nil) async -> Bool {
        guard session.provider != .muse, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 16_384, !running.contains(session.id) else { return false }
        let name = session.provider == .codex ? "codex" : "claude"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = executableOverride ?? paths.map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Install \(name) CLI, then try again."; return false
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.directory, isDirectory: &directory), directory.boolValue else {
            error = "This workspace no longer exists. Choose another session."; return false
        }
        running.insert(session.id)
        managedSessions[session.id] = session
        replies.removeValue(forKey: session.id)
        error = nil
        let runner = SessionMessageRunner()
        do {
            let reply = try await Task.detached(priority: .utility) { try runner.run(session, text: text, executable: executable) }.value
            replies[session.id] = reply
        } catch {
            replies[session.id] = SessionReply(text: "Could not send: \(error.localizedDescription). Your message is kept for retry.", failed: true, date: Date())
        }
        let success = replies[session.id]?.failed == false
        await refresh()
        running.remove(session.id)
        return success
    }

    var inboxSessions: [LocalAgentSession] {
        var values = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.id, $0) })
        for (id, session) in managedSessions where values[id] == nil { values[id] = session }
        return values.values.map { session in
            var value = session
            if running.contains(session.id) {
                value.activity = value.modifiedAt > (managedSessions[session.id]?.modifiedAt ?? .distantFuture)
                    ? value.activity : "Working on your message…"
            }
            else if let reply = replies[session.id], reply.date >= value.modifiedAt {
                value.preview = reply.text
                value.activity = (reply.failed ? "Needs attention · " : "") + String(reply.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").suffix(160))
                value = LocalAgentSession(provider: value.provider, sessionID: value.sessionID, directory: value.directory,
                                          modifiedAt: max(value.modifiedAt, reply.date), configurationDirectory: value.configurationDirectory,
                                          name: value.name, activity: value.activity, preview: value.preview)
            }
            return value
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}
