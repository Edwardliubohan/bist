import Foundation

@main
struct LocalSessionTests {
    @MainActor static func main() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bist-connections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex/sessions/2026/10/27")
        let claude = home.appendingPathComponent(".claude/projects/workspace")
        for folder in [codex, claude] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let id = UUID()
        let otherID = UUID()
        func write(_ value: [String: Any], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try write(["type": "session_meta", "payload": ["id": id.uuidString, "cwd": "/tmp/My 'workspace' $(touch ignored)"]], to: codex.appendingPathComponent("rollout.jsonl"))
        try write(["type": "user", "sessionId": otherID.uuidString, "cwd": "/tmp/project"], to: claude.appendingPathComponent("session.jsonl"))
        try write(["type": "user", "sessionId": UUID().uuidString, "cwd": "/tmp/project", "isSidechain": true], to: claude.appendingPathComponent("sidechain.jsonl"))
        try "broken record".write(to: claude.appendingPathComponent("broken.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("symlink.jsonl"), withDestinationURL: codex.appendingPathComponent("rollout.jsonl"))
        let scan = LocalSessionScan.read(home: home, environment: [:])
        precondition(scan.sessions.count == 2, "Finds both providers, skips malformed files, symlinks and subagents")
        precondition(scan.sessions.contains { $0.provider == .codex && $0.sessionID == id })
        precondition(scan.sessions.contains { $0.provider == .claudeCode && $0.sessionID == otherID })
        let missing = LocalSessionScan.read(home: home.appendingPathComponent("missing"), environment: [:])
        precondition(missing.sessions.isEmpty && missing.messages[.codex] == "No local session folder found")
        let override = LocalSessionScan.read(home: home.appendingPathComponent("missing"), environment: ["CODEX_HOME": home.appendingPathComponent(".codex").path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path])
        precondition(override.sessions.count == 2, "Respects custom provider data directories")
        let session = scan.sessions.first { $0.provider == .codex }!
        let command = LocalSessionConnection.resumeCommand(session, executable: "/tmp/fake codex")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Verify quoting through the actual shell, with a harmless printf executable.
        process.arguments = ["-c", "printf '%s' " + LocalSessionConnection.shellQuote(session.directory)]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        precondition(output == session.directory && process.terminationStatus == 0, "Shell metacharacters stay literal")
        precondition(command.contains("'resume' '\(id.uuidString.lowercased())'"))
        precondition(LocalSessionConnection.resumeCommand(scan.sessions.first { $0.provider == .claudeCode }!, executable: "/tmp/claude").contains("'--resume'"))
        let live = LocalSessionScan.read()
        print("PASS: local session parsing, custom roots, invalid files, shell quoting, resume arguments; live discovery: \(live.sessions.filter { $0.provider == .codex }.count) Codex, \(live.sessions.filter { $0.provider == .claudeCode }.count) Claude")
    }
}
