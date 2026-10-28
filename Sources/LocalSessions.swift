import AppKit
import SwiftUI

/// Bounded local metadata and text previews. No credentials or transcript copies.
struct LocalAgentSession: Identifiable, Equatable {
    let provider: SessionProvider
    let sessionID: UUID
    let directory: String
    var modifiedAt: Date
    var configurationDirectory: String? = nil
    var name: String? = nil
    var activity: String = "Activity saved"
    var preview: String = ""
    var threadID: String? = nil
    var t3BaseDirectory: String? = nil
    var externalRunning = false
    var activeThread = true
    var needsInput = false
    var requiresT3Response = false
    var question: String? = nil
    var childCount = 0
    var id: String {
        if let threadID { return "t3:\(threadID)" }
        return "\(provider.rawValue):\(sessionID.uuidString)"
    }
    var title: String { name ?? (directory == "/" ? "Root folder" : URL(fileURLWithPath: directory).lastPathComponent) }
    var awaitingReply: Bool { needsInput || SessionDigest.question(preview) != nil }
    var shortID: String { "\(sessionID.uuidString.prefix(8).lowercased())…\(sessionID.uuidString.suffix(4).lowercased())" }
}

struct LocalSessionScan {
    var sessions: [LocalAgentSession] = []
    var messages: [SessionProvider: String] = [:]
    var t3 = T3SessionScan()

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
                guard let session = parse(file: file, provider: provider, modified: modified, configurationDirectory: root.deletingLastPathComponent().path), seen.insert(session.sessionID).inserted else { continue }
                result.sessions.append(session)
                if seen.count == 30 { break }
            }
            result.messages[provider] = failed ? "Some session folders could not be read" : "Local sessions connected"
        }
        result.t3 = T3SessionScan.read(home: home, environment: environment)
        result.sessions.sort { $0.modifiedAt > $1.modifiedAt }
        return result
    }

    static func parse(file: URL, provider: SessionProvider, modified: Date, configurationDirectory: String? = nil) -> LocalAgentSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // Bounded prefix; ignore a partial final record and unknown formats.
        guard let data = try? handle.read(upToCount: 262_144), case let text = String(decoding: data, as: UTF8.self) else { return nil }
        for line in text.split(separator: "\n").prefix(40) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let metadata: [String: Any]
            if provider == .codex {
                guard object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any] else { continue }
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return nil }
                if payload["source"] as? String == "subagent" { return nil }
                metadata = payload
            } else {
                guard object["isSidechain"] as? Bool != true else { return nil }
                metadata = object
            }
            guard let raw = (metadata["sessionId"] ?? metadata["id"]) as? String, let id = UUID(uuidString: raw),
                  let cwd = metadata["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("t3code-claude-title-") else { continue }
            var session = LocalAgentSession(provider: provider, sessionID: id, directory: cwd, modifiedAt: modified, configurationDirectory: configurationDirectory)
            session.name = (metadata["title"] as? String).map { String($0.prefix(100)) }
            // Read only a bounded tail; discard an incomplete leading record.
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > 65_536 ? size - 65_536 : 0
            try? handle.seek(toOffset: start)
            let tail = (try? handle.read(upToCount: 65_536)) ?? Data()
            var lines = String(decoding: tail, as: UTF8.self).components(separatedBy: "\n")
            if start > 0 && !lines.isEmpty { lines.removeFirst() }
            let prefixLines = text.components(separatedBy: "\n").prefix(40)
            for record in Array(prefixLines) + lines {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any] else { continue }
                if let title = entry["customTitle"] as? String { session.name = String(title.prefix(100)) }
                let payload = entry["payload"] as? [String: Any] ?? entry
                let type = payload["type"] as? String ?? ""
                let message = entry["message"] as? [String: Any] ?? payload
                let role = message["role"] as? String ?? entry["type"] as? String
                let blocks = message["content"] as? [[String: Any]] ?? []
                let body = (message["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
                if (role == "user" || type == "user_message"), session.name == nil {
                    let prompt = payload["message"] as? String ?? body
                    if !prompt.isEmpty && !prompt.hasPrefix("<") && !prompt.hasPrefix("#") {
                        session.name = String(prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "".prefix(80))
                    }
                }
                if role == "assistant" || type == "agent_message" {
                    let value = payload["message"] as? String ?? body
                    if !value.isEmpty {
                        session.preview = String(value.prefix(4000))
                        session.activity = String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
                    }
                }
                if type == "function_call", let tool = payload["name"] as? String { session.activity = "Using \(tool)" }
                if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String { session.activity = "Using \(tool)" }
            }
            return session
        }
        return nil
    }
}

@MainActor
final class LocalSessionConnection: ObservableObject {
    @Published private(set) var scan = LocalSessionScan()
    @Published private(set) var refreshing = false
    @Published var error: String?
    @Published var running = Set<String>()
    @Published var replies: [String: SessionReply] = [:]
    @Published var managedSessions: [String: LocalAgentSession] = [:]

    private var lastHistoryRefresh = Date.distantPast

    init(scan: LocalSessionScan = LocalSessionScan()) { self.scan = scan }

    func refresh(forceHistory: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        let includeHistory = forceHistory || Date().timeIntervalSince(lastHistoryRefresh) >= 20
        let previous = scan
        let value = await Task.detached(priority: .utility) {
            if includeHistory { return LocalSessionScan.read() }
            var value = previous
            value.t3 = T3SessionScan.read()
            return value
        }.value
        if includeHistory { lastHistoryRefresh = Date() }
        scan = value
        refreshing = false
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func resumeCommand(_ session: LocalAgentSession, executable: String) -> String {
        let arguments = session.provider == .codex ? ["resume", session.sessionID.uuidString.lowercased()] : ["--resume", session.sessionID.uuidString.lowercased()]
        var invocation = [executable] + arguments
        if let configurationDirectory = session.configurationDirectory {
            let key = session.provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            invocation = ["/usr/bin/env", "\(key)=\(configurationDirectory)"] + invocation
        }
        return "cd -- \(shellQuote(session.directory)) && \(invocation.map(shellQuote).joined(separator: " "))"
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
