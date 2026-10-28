import AppKit

import Foundation
import SQLite3
import Darwin

/// Read-only adapter for T3's local projections. No event writes or credentials.
struct T3SessionScan {
    var sessions: [LocalAgentSession] = []
    var connected = false
    var error: String?

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     serverAlive: Bool? = nil) -> Self {
        let base = environment["T3CODE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".t3")
        let directory = base.appendingPathComponent("userdata")
        let file = directory.appendingPathComponent("statev2.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return Self(error: "T3 sessions could not be read. Refresh to retry.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)
        var alive = false
        if let data = try? Data(contentsOf: directory.appendingPathComponent("server-runtime.json")),
           let runtime = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = runtime["pid"] as? Int32 { alive = kill(pid, 0) == 0 }
        alive = serverAlive ?? alive
        // One consistent snapshot, including responses and questions.
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let sql = """
        SELECT t.thread_id, t.title, p.workspace_root, t.updated_at,
               json_extract(t.payload_json,'$.worktreePath'),
               json_extract(t.payload_json,'$.settledOverride'),
               r.status, r.completed_at, t.default_provider,
               (SELECT substr(json_extract(m.payload_json,'$.text'),1,12000)
                  FROM orchestration_v2_projection_messages m
                 WHERE m.thread_id=t.thread_id AND m.role='assistant'
                 ORDER BY m.created_at DESC,m.message_id DESC LIMIT 1),
               (SELECT m.updated_at FROM orchestration_v2_projection_messages m
                 WHERE m.thread_id=t.thread_id AND m.role='assistant'
                 ORDER BY m.created_at DESC,m.message_id DESC LIMIT 1),
               (SELECT count(*) FROM orchestration_v2_projection_subagents s
                 WHERE s.thread_id=t.thread_id AND s.status IN ('pending','running','waiting')),
               (SELECT json_object('type', i.type,
                       'prompt', substr(json_extract(i.payload_json,'$.prompt'),1,4000),
                       'questions', json_extract(i.payload_json,'$.questions'))
                  FROM orchestration_v2_projection_runtime_requests q
                  LEFT JOIN orchestration_v2_projection_turn_items i ON i.thread_id=q.thread_id
                       AND json_extract(i.payload_json,'$.requestId')=q.runtime_request_id
                 WHERE (q.thread_id=t.thread_id OR q.thread_id IN (
                    SELECT s.child_thread_id FROM orchestration_v2_projection_subagents s WHERE s.thread_id=t.thread_id)) AND q.status='pending'
                 ORDER BY q.created_at DESC,i.ordinal DESC LIMIT 1)
          FROM orchestration_v2_projection_threads t
          JOIN projection_projects p ON p.project_id=t.project_id
          LEFT JOIN orchestration_v2_projection_runs r ON r.run_id=(
               SELECT run_id FROM orchestration_v2_projection_runs WHERE thread_id=t.thread_id ORDER BY ordinal DESC LIMIT 1)
         WHERE t.deleted_at IS NULL AND t.archived_at IS NULL AND p.deleted_at IS NULL
           AND json_extract(t.payload_json,'$.lineage.relationshipToParent') IS NOT 'subagent'
           AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_subagents s WHERE s.child_thread_id=t.thread_id)
         ORDER BY CASE WHEN r.status IN ('queued','preparing','starting','running','waiting') THEN 0 ELSE 1 END,
                  t.updated_at DESC LIMIT 100
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return Self(error: "This T3 session format isn’t supported. Local history is available from the menu.")
        }
        defer { sqlite3_finalize(statement) }
        func string(_ index: Int32) -> String? { sqlite3_column_text(statement, index).map { String(cString: $0) } }
        var result = Self(connected: true)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let id = string(0), !id.isEmpty, let workspace = string(2) else { continue }
            let uuid = UUID(uuidString: id) ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
            let status = string(6) ?? "idle"
            let childCount = Int(sqlite3_column_int(statement, 11))
            let running = alive && (["queued", "preparing", "starting", "running", "waiting"].contains(status) || childCount > 0)
            let request = string(12)
            let preview = string(9) ?? ""
            let needsInput = request != nil
            var session = LocalAgentSession(provider: (string(8) ?? "").localizedCaseInsensitiveContains("claude") ? .claudeCode : .codex,
                sessionID: uuid, directory: string(4) ?? workspace,
                modifiedAt: [date(string(10)), date(string(7)), date(string(3))].compactMap { $0 }.max() ?? .distantPast,
                name: string(1), activity: SessionDigest.excerpt(preview, limit: 160), preview: preview)
            session.threadID = id
            session.t3BaseDirectory = base.path
            session.externalRunning = running && !needsInput
            session.needsInput = needsInput
            session.requiresT3Response = needsInput
            session.activeThread = string(5) != "settled" || running || needsInput
            session.childCount = childCount
            if needsInput { session.activity = "Waiting for your answer in T3" }
            else if running { session.activity = session.childCount > 0 ? "Working · \(session.childCount) helpers" : preview.isEmpty ? "Working in T3…" : session.activity }
            else if !alive { session.activity = "T3 offline · last saved update" }
            if let request, let data = request.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Request state and visible prompts are separate T3 projection records.
                // Structured answers and permission decisions remain in T3.
                if let questions = object["questions"] as? [[String: Any]], !questions.isEmpty {
                    session.question = questions.prefix(5).compactMap { ($0["question"] as? String).map { String($0.prefix(800)) } }.joined(separator: "\n\n")
                    if questions.count == 1 {
                        session.suggestedReplies = Array((questions[0]["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }.filter { $0.count <= 160 }.prefix(3))
                    }
                } else {
                    session.question = object["prompt"] as? String ?? "Open this request in T3 to review its details."
                }
            }
            result.sessions.append(session)
        }
        guard step == SQLITE_DONE else { return Self(error: "T3 sessions are busy. Refresh to retry.") }
        return result
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Extracts readable source text, never invents an outcome or approval.
enum SessionDigest {
    static func excerpt(_ text: String, limit: Int = 700) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
    static func question(_ text: String) -> String? {
        text.components(separatedBy: .newlines).last { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value.hasSuffix("?") || value.hasSuffix("？")) && !value.hasPrefix("```")
        }.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800)) }
    }
    static func summary(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let questionIndex = lines.firstIndex { line in line.trimmingCharacters(in: .whitespaces).hasSuffix("?") }
        let body = questionIndex.map { lines.prefix($0).joined(separator: "\n") } ?? text
        let paragraphs = body.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return String(paragraphs.prefix(2).joined(separator: "\n\n").prefix(800))
    }
    static func suggestions(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard let question = question(text), let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == question }) else { return [] }
        // Only contiguous choices after a question qualify; earlier progress bullets do not.
        var choices: [String] = []
        for line in lines.dropFirst(index + 1) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { if choices.isEmpty { continue }; break }
            guard value.hasPrefix("- ") || value.hasPrefix("• ") else { break }
            let choice = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !choice.isEmpty, choice.count <= 160 else { break }
            if !choices.contains(choice) { choices.append(choice) }
            if choices.count == 3 { break }
        }
        return choices
    }
}

/// Uses T3's supported thread CLI; the app never writes its database.
enum T3Command {
    static var application: Bundle? {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code")
            ?? URL(fileURLWithPath: "/Applications/T3 Code (Beta).app")
        return Bundle(url: path)
    }
    static var entrypoint: String? {
        application?.resourceURL?.appendingPathComponent("app.asar/apps/server/dist/bin.mjs").path
    }
    static var executable: String? { application?.executableURL?.path }
}

extension LocalSessionConnection {
    func openThread(_ session: LocalAgentSession) {
        guard let base = session.t3BaseDirectory, let threadID = session.threadID,
              let data = try? Data(contentsOf: URL(fileURLWithPath: base).appendingPathComponent("userdata/server-runtime.json")),
              let runtime = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = runtime["origin"] as? String, var components = URLComponents(string: origin),
              components.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(components.host ?? ""),
              let environment = try? String(contentsOf: URL(fileURLWithPath: base).appendingPathComponent("userdata/environment-id"), encoding: .utf8) else {
            error = "Open T3 Code to answer this session. Its local server is unavailable."; return
        }
        components.path = "/\(environment.trimmingCharacters(in: .whitespacesAndNewlines))/\(threadID)"
        guard let url = components.url, NSWorkspace.shared.open(url) else { error = "Couldn’t open this T3 thread."; return }
        error = nil
    }
    func copyReplyAndOpen(_ text: String, session: LocalAgentSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        openThread(session)
    }
}
