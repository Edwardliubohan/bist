import AppKit
import SwiftUI

/// Local metadata only: never copies messages, credentials, or completion claims.
struct LocalAgentSession: Identifiable, Equatable {
    let provider: SessionProvider
    let sessionID: UUID
    let directory: String
    let modifiedAt: Date
    var id: String { "\(provider.rawValue):\(sessionID.uuidString)" }
    var title: String { URL(fileURLWithPath: directory).lastPathComponent }
    var shortID: String { "\(sessionID.uuidString.prefix(8).lowercased())…\(sessionID.uuidString.suffix(4).lowercased())" }
}

struct LocalSessionScan {
    var sessions: [LocalAgentSession] = []
    var messages: [SessionProvider: String] = [:]

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var result = Self()
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
        for (provider, root) in [(SessionProvider.codex, codex.appendingPathComponent("sessions")),
                                 (.claudeCode, claude.appendingPathComponent("projects"))] {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
                result.messages[provider] = "No local session folder found"; continue
            }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else {
                result.messages[provider] = "Cannot read local sessions"; continue
            }
            var files: [(URL, Date)] = []
            for case let file as URL in enumerator {
                if file.lastPathComponent == "subagents" || file.lastPathComponent.contains("t3code-claude-title-") { enumerator.skipDescendants(); continue }
                guard file.pathExtension == "jsonl",
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files.append((file, values.contentModificationDate ?? .distantPast))
            }
            var seen = Set<UUID>()
            for (file, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(100) {
                guard let session = parse(file: file, provider: provider, modified: modified), seen.insert(session.sessionID).inserted else { continue }
                result.sessions.append(session)
                if seen.count == 30 { break }
            }
            result.messages[provider] = failed ? "Some session folders could not be read" : "Local sessions connected"
        }
        result.sessions.sort { $0.modifiedAt > $1.modifiedAt }
        return result
    }

    static func parse(file: URL, provider: SessionProvider, modified: Date) -> LocalAgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // Bounded prefix; ignore a partial final record and unknown formats.
        guard let data = try? handle.read(upToCount: 262_144), case let text = String(decoding: data, as: UTF8.self) else { return nil }
        for line in text.split(separator: "\n").prefix(40) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let metadata: [String: Any]
            if provider == .codex {
                guard object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] else { continue }
                metadata = payload
            } else {
                guard object["isSidechain"] as? Bool != true else { continue }
                metadata = object
            }
            guard let raw = (metadata["sessionId"] ?? metadata["id"]) as? String, let id = UUID(uuidString: raw),
                  let cwd = metadata["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("t3code-claude-title-") else { continue }
            return LocalAgentSession(provider: provider, sessionID: id, directory: cwd, modifiedAt: modified)
        }
        return nil
    }
}

@MainActor
final class LocalSessionConnection: ObservableObject {
    @Published private(set) var scan = LocalSessionScan()
    @Published private(set) var refreshing = false
    @Published var error: String?

    init(scan: LocalSessionScan = LocalSessionScan()) { self.scan = scan }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let value = await Task.detached(priority: .utility) { LocalSessionScan.read() }.value
        scan = value
        refreshing = false
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func resumeCommand(_ session: LocalAgentSession, executable: String) -> String {
        let arguments = session.provider == .codex ? ["resume", session.sessionID.uuidString.lowercased()] : ["--resume", session.sessionID.uuidString.lowercased()]
        return "cd -- \(shellQuote(session.directory)) && \(([executable] + arguments).map(shellQuote).joined(separator: " "))"
    }

    func resume(_ session: LocalAgentSession) {
        let name = session.provider == .codex ? "codex" : "claude"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = paths.map({ $0 + "/" + name }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            error = "Install \(name) CLI to resume this session."; return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "This session’s workspace no longer exists."; return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bist-resume-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("Resume \(name).command")
            let script = "#!/bin/zsh\n" + Self.resumeCommand(session, executable: executable) + "\nresult=$?\n/bin/rm -f -- \(Self.shellQuote(file.path))\n/bin/rmdir -- \(Self.shellQuote(folder.path))\nexit $result\n"
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard NSWorkspace.shared.open(file) else { throw CocoaError(.fileReadUnknown) }
            error = nil
        } catch { self.error = "Could not open Terminal: \(error.localizedDescription)" }
    }
}
