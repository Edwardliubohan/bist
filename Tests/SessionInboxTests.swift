import Foundation

@main
struct SessionInboxTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bist-session-inbox-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let session = LocalAgentSession(provider: .codex, sessionID: UUID(), directory: folder.path, modifiedAt: Date().addingTimeInterval(-60), configurationDirectory: folder.appendingPathComponent("codex-config").path, name: "Fix inbox", activity: "Running checks", preview: "Tests passed")
        expect(SessionSource(.claudeCode) == .claude && SessionSource(.codex) == .chat, "Running threads are tagged by who you sent them to")
        expect([SessionSource.claude, .chat, .bobot].map(\.label) == ["Claude", "Chat", "Bobot"], "Source tags use plain names")
        expect(Set([SessionSource.claude, .chat, .bobot].map(\.tint)).count == 3, "Each source has its own color")
        expect(session.meta == "\(folder.lastPathComponent) · Codex" && session.meta(showingProvider: false) == folder.lastPathComponent,
               "A tagged row drops the duplicate provider name")
        let state = SessionBrowserState(directory: folder)
        expect(state.inbox([session], running: []).count == 1, "New updates are unread")
        expect(state.inbox([session], running: [session.id]).isEmpty, "Running sessions are not duplicated below")
        expect(state.read(session), "Opening an update archives it")
        expect(state.inbox([session], running: []).isEmpty, "Read sessions leave notifications")
        expect(state.inbox([session], running: [], archived: true).count == 1, "Archive keeps session accessible")
        let reloaded = SessionBrowserState(directory: folder)
        expect(reloaded.isRead(session), "Archive survives relaunch")
        let otherState = SessionBrowserState(directory: folder)
        var newer = session
        newer = LocalAgentSession(provider: .codex, sessionID: session.sessionID, directory: folder.path, modifiedAt: session.modifiedAt.addingTimeInterval(10), name: session.name, activity: "New update")
        expect(!state.isRead(newer), "An unseen update written before opening an older snapshot still returns to inbox")
        expect(otherState.read(newer) && state.read(session), "Opening a stale snapshot is allowed")
        expect(SessionBrowserState(directory: folder).isRead(newer), "A stale read cannot reduce a newer persisted read marker")
        let other = LocalAgentSession(provider: .claudeCode, sessionID: UUID(), directory: folder.path, modifiedAt: .distantPast, configurationDirectory: folder.appendingPathComponent("claude-config").path)
        expect(otherState.read(other), "Second instance merges current archive")
        expect(SessionBrowserState(directory: folder).isRead(session), "Concurrent archive retains prior reads")
        let damaged = folder.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: damaged.appendingPathComponent("sessions-read.json"))
        let broken = SessionBrowserState(directory: damaged)
        expect(!broken.read(session) && broken.archiveError != nil, "Malformed archive is preserved, not overwritten")
        expect(try String(contentsOf: damaged.appendingPathComponent("sessions-read.json"), encoding: .utf8) == "broken", "Original damaged bytes retained")
        let gated = SessionBrowserState(directory: folder.appendingPathComponent("gated"), prepareForWrite: { false })
        expect(!gated.read(session), "Migration preparation gate respected")
        let connection = LocalSessionConnection(scan: LocalSessionScan(sessions: [session, other]), home: folder, environment: [:])
        let prompt = "--not-an-option\nLiteral 'quotes' $(touch SHOULD_NOT_EXIST) 🧡"
        for selected in [session, other] {
            let fake = folder.appendingPathComponent("fake-cli")
            let script = "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$CODEX_HOME\" \"$CLAUDE_CONFIG_DIR\" \"$@\"\n/bin/cat\nsleep 0.1\n"
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            let task = Task { await connection.send(prompt, to: selected, executableOverride: fake.path) }
            await Task.yield()
            // Wait briefly for the main actor task to enter its detached process.
            try await Task.sleep(for: .milliseconds(30))
            expect(connection.running.contains(selected.id), "Running state during actual process")
            let duplicate = await connection.send("duplicate", to: selected, executableOverride: fake.path)
            expect(!duplicate, "Duplicate send refused while busy")
            let success = await task.value
            expect(success && !connection.running.contains(selected.id), "Process completion clears running state")
            let reply = connection.replies[selected.id]!
            expect(reply.text.contains(prompt), "Literal Unicode multiline prompt reaches stdin")
            expect(reply.text.contains(selected.sessionID.uuidString.lowercased()), "Exact selected session ID sent")
            expect(reply.text.contains(selected.configurationDirectory!), "Discovered provider configuration retained")
            expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("SHOULD_NOT_EXIST").path), "No shell interpolation")
        }
        let missing = await connection.send("hello", to: session, executableOverride: "/no/such/cli")
        expect(!missing && connection.replies[session.id]?.failed == true && !connection.running.contains(session.id), "Launch failures yield retryable update and clear busy state")
        let fake = folder.appendingPathComponent("fake-cli")
        try "#!/bin/sh\nprintf 'login required'\nexit 7\n".write(to: fake, atomically: true, encoding: .utf8)
        let failed = await connection.send("retry me", to: session, executableOverride: fake.path)
        expect(!failed && connection.replies[session.id]?.text == "login required", "CLI failures preserve meaningful diagnostics")
        expect(connection.inboxSessions.contains { $0.id == session.id && $0.activity.contains("Needs attention") }, "Failed send becomes notification")
        let staleConnection = LocalSessionConnection(scan: LocalSessionScan(sessions: [newer]))
        staleConnection.replies[newer.id] = SessionReply(text: "Old reply", failed: false, date: session.modifiedAt)
        expect(staleConnection.inboxSessions.first?.activity == newer.activity, "Cached replies never replace newer scanned content")
        let visibility = SessionBrowserState()
        visibility.selectedID = session.id
        visibility.acknowledge(session, visible: false, running: false)
        expect(!visibility.isRead(session), "Hidden mounted detail never archives a completed response")
        visibility.acknowledge(session, visible: true, running: true)
        expect(!visibility.isRead(session), "Visible running turn is not acknowledged early")
        visibility.acknowledge(session, visible: true, running: false)
        expect(visibility.isRead(session), "Returning to visible detail acknowledges the displayed response")
        let empty = await connection.send(" \n", to: session, executableOverride: fake.path)
        let tooLong = await connection.send(String(repeating: "x", count: 16_385), to: session, executableOverride: fake.path)
        expect(!empty && !tooLong, "Empty and oversize prompts rejected")
        print("PASS: \(checks) session inbox, persistence and actual subprocess messaging checks")
    }
}
