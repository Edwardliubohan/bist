import AppKit
import Foundation
import SQLite3

@main
struct T3SessionTests {
    @MainActor static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bist-t3-\(UUID())")
        let directory = home.appendingPathComponent(".t3/userdata")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("statev2.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ query: String) {
            var error: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(db, query, nil, nil, &error)
            let detail = error.map { String(cString: $0) } ?? ""
            sqlite3_free(error)
            precondition(code == SQLITE_OK, detail)
        }
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        sql("""
        CREATE TABLE projection_projects(project_id TEXT, workspace_root TEXT, deleted_at TEXT);
        CREATE TABLE orchestration_v2_projection_threads(thread_id TEXT,title TEXT,project_id TEXT,updated_at TEXT,default_provider TEXT,payload_json TEXT,deleted_at TEXT,archived_at TEXT);
        CREATE TABLE orchestration_v2_projection_runs(run_id TEXT,thread_id TEXT,ordinal INTEGER,status TEXT,completed_at TEXT);
        CREATE TABLE orchestration_v2_projection_messages(message_id TEXT,thread_id TEXT,role TEXT,payload_json TEXT,created_at TEXT,updated_at TEXT);
        CREATE TABLE orchestration_v2_projection_subagents(thread_id TEXT,child_thread_id TEXT,status TEXT);
        CREATE TABLE orchestration_v2_projection_runtime_requests(runtime_request_id TEXT,thread_id TEXT,status TEXT,created_at TEXT,payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_turn_items(thread_id TEXT,type TEXT,ordinal INTEGER,payload_json TEXT);
        INSERT INTO projection_projects VALUES ('p',\(quoted(home.path)),NULL);
        """)
        let first = UUID().uuidString, second = UUID().uuidString, finished = UUID().uuidString
        let child = UUID().uuidString, settled = UUID().uuidString, archived = UUID().uuidString, waiting = UUID().uuidString
        let timestamp = "2026-10-28T01:00:00.123Z"
        func thread(_ id: String, status: String, payload: String = "{}", archive: Bool = false) {
            sql("INSERT INTO orchestration_v2_projection_threads VALUES (\(quoted(id)),'Inbox work','p',\(quoted(timestamp)),'acpRegistry_codex',\(quoted(payload)),NULL,\(archive ? quoted(timestamp) : "NULL"));")
            sql("INSERT INTO orchestration_v2_projection_runs VALUES (\(quoted(id+"run")),\(quoted(id)),1,\(quoted(status)),NULL);")
            let body = "Built the inbox.\n\nWhich layout should I use?\n- Compact rows\n- Roomier rows"
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["text": body]), as: UTF8.self)
            sql("INSERT INTO orchestration_v2_projection_messages VALUES (\(quoted(id)),\(quoted(id)),'assistant',\(quoted(json)),\(quoted(timestamp)),\(quoted(timestamp)));")
        }
        thread(first, status: "running")
        thread(second, status: "running")
        thread(finished, status: "completed")
        thread(child, status: "running", payload: "{\"lineage\":{\"relationshipToParent\":\"subagent\"}}")
        thread(settled, status: "completed", payload: "{\"settledOverride\":\"settled\"}")
        thread(archived, status: "running", archive: true)
        thread(waiting, status: "waiting")
        sql("INSERT INTO orchestration_v2_projection_subagents VALUES (\(quoted(first)),\(quoted(child)),'running');")
        sql("INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('request-1',\(quoted(waiting)),'pending',\(quoted(timestamp)),'{\"kind\":\"user_input\",\"responseCapability\":{\"type\":\"live\"}}');")
        sql("INSERT INTO orchestration_v2_projection_turn_items VALUES (\(quoted(waiting)),'user_input_request',1,'{\"requestId\":\"request-1\",\"questions\":[{\"id\":\"q1\",\"header\":\"Layout\",\"question\":\"Which option?\",\"options\":[{\"label\":\"Compact rows\",\"description\":\"Fits more sessions\"}]}]}');")
        let result = T3SessionScan.read(home: home, environment: [:], serverAlive: true)
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        expect(result.connected && result.error == nil, "Supported schema connects read-only")
        expect(result.sessions.count == 5, "One root per session; child and archived threads excluded")
        expect(result.sessions.filter(\.externalRunning).count == 2, "Both externally running tasks are detected")
        expect(result.sessions.first { $0.threadID == first }?.childCount == 1, "Child work rolls up under parent")
        expect(result.sessions.first { $0.threadID == finished }?.externalRunning == false, "Completed turns are not running")
        let question = result.sessions.first { $0.threadID == waiting }!
        expect(question.needsInput && question.requiresT3Response && !question.externalRunning, "Pending question is actionable, not falsely working")
        expect(question.question == "Which option?" && question.suggestedReplies == ["Compact rows"], "Question text and choices come from the corresponding turn item")
        sql("UPDATE orchestration_v2_projection_runs SET status='completed' WHERE thread_id=\(quoted(first));")
        let childOnly = T3SessionScan.read(home: home, environment: [:], serverAlive: true)
        expect(childOnly.sessions.first { $0.threadID == first }?.externalRunning == true, "Live child work keeps the root session running after its own turn completes")
        sql("UPDATE orchestration_v2_projection_runs SET status='running' WHERE thread_id=\(quoted(first));")
        sql("UPDATE orchestration_v2_projection_subagents SET status='pending';")
        expect(T3SessionScan.read(home: home, environment: [:], serverAlive: true).sessions.first { $0.threadID == first }?.childCount == 1, "Pending helpers count as active work")
        let state = SessionBrowserState()
        let connection = LocalSessionConnection(scan: LocalSessionScan(t3: result))
        let historyOnly = LocalAgentSession(provider: .codex, sessionID: UUID(), directory: home.path, modifiedAt: Date())
        connection.managedSessions[historyOnly.id] = historyOnly
        expect(!connection.inboxSessions.contains { $0.id == historyOnly.id }, "Managed provider history never pollutes the canonical T3 inbox")
        let items = state.inbox(connection.inboxSessions, running: connection.busyIDs)
        expect(!items.contains { $0.threadID == settled }, "Settled threads excluded from active inbox")
        expect(items.contains { $0.id == question.id }, "Pending answer appears in inbox")
        state.read(question)
        expect(state.inbox(connection.inboxSessions, running: connection.busyIDs).contains { $0.id == question.id }, "Reading cannot hide an unanswered structured question")
        expect(T3SessionScan.read(home: home, environment: [:], serverAlive: false).sessions.allSatisfy { !$0.externalRunning }, "Offline saved projections never claim to be running")
        let oldRun = UUID().uuidString
        thread(oldRun, status: "running")
        sql("INSERT INTO orchestration_v2_projection_runs VALUES ('newer',\(quoted(oldRun)),2,'completed',\(quoted(timestamp)));")
        expect(T3SessionScan.read(home: home, environment: [:], serverAlive: true).sessions.first { $0.threadID == oldRun }?.externalRunning == false, "Latest run wins over stale running record")
        let fake = home.appendingPathComponent("fake-t3")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n/bin/cat\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        var target = result.sessions.first { $0.threadID == finished }!
        let args = SessionMessageRunner.arguments(target)
        expect(args.prefix(4) == ["thread", "send", finished, "-"], "Replies route to the exact T3 thread, using stdin")
        let reply = try SessionMessageRunner().run(target, text: "Literal $(ignored) 🧡", executable: fake.path)
        expect(reply.delivered && reply.text.contains("Literal $(ignored) 🧡"), "T3 CLI acceptance is distinct from agent completion")
        let duplicate = await connection.send("hello", to: result.sessions.first { $0.threadID == first }!, executableOverride: fake.path)
        expect(!duplicate, "Cannot fork an already running external session")
        let gated = await connection.send("yes", to: question, executableOverride: fake.path)
        expect(!gated, "Ordinary messages cannot answer a structured permission or question")
        target.externalRunning = false
        let unsupported = home.appendingPathComponent("other/.t3/userdata")
        try FileManager.default.createDirectory(at: unsupported, withIntermediateDirectories: true)
        try Data().write(to: unsupported.appendingPathComponent("statev2.sqlite"))
        let unknown = T3SessionScan.read(home: home.appendingPathComponent("other"), environment: [:])
        expect(!unknown.connected && unknown.error != nil, "Schema drift is visible instead of silently showing false state")
        expect(SessionDigest.suggestions("- Tests passed\n\nWhich should I use?").isEmpty, "Progress bullets are not suggested approvals")
        expect(SessionDigest.suggestions("Done.").isEmpty, "No invented consent suggestion")
        expect(SessionDigest.suggestions(target.preview) == ["Compact rows", "Roomier rows"], "Suggested replies come from explicit source choices")
        let frame = SessionHoverAnchor.frame(anchor: CGRect(x: 1000,y: 500,width: 300,height: 49), parent: CGRect(x: 980,y: 200,width: 360,height: 560), screen: CGRect(x: 0,y: 0,width: 1440,height: 900))
        expect(frame.maxX < 980, "Hover preview is on the left when space allows")
        let narrow = CGRect(x: -500,y: 0,width: 500,height: 400)
        expect(narrow.contains(SessionHoverAnchor.frame(anchor: CGRect(x: -480,y: 300,width: 300,height: 49), parent: CGRect(x: -480,y: 0,width: 360,height: 400), screen: narrow)), "Preview stays on screen, including negative display origins")
        let live = T3SessionScan.read()
        print("PASS: \(checks) T3 thread, running, question, reply and geometry checks; live roots=\(live.sessions.count), running=\(live.sessions.filter(\.externalRunning).count), connected=\(live.connected)")
    }
}
