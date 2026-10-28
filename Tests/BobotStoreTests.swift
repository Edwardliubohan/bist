import Foundation

@main
struct BobotStoreTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-bobot-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let tasks = AppStore(directory: directory)
        expect(tasks.addTask(title: "Research Unicode 🧡", details: "Snapshot details", agentHelpRequested: true), "Create task")
        let task = tasks.tasks[0]
        let bobot = BobotStore(directory: directory)
        expect(bobot.jobs.isEmpty, "Restored intent never assigns work")
        expect(bobot.assign(task) && bobot.assign(task) && bobot.jobs.count == 1, "Duplicate assignment is idempotent")
        expect(!bobot.connected && bobot.jobs[0].state == "queued", "Disconnected work is queued truthfully")
        let other = BobotStore(directory: directory)
        expect(other.jobs == bobot.jobs, "Assignments survive restart")
        expect(tasks.updateTask(id: task.id, title: "Changed task", notes: "New details", nextAction: "", source: "", sourceURL: ""), "Edit task")
        other.refresh()
        expect(other.jobs[0].title == task.title && other.jobs[0].details == task.notes, "Assignment keeps exact snapshot")
        let file = directory.appendingPathComponent("bobot-jobs.json")
        var ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var jobs = ledger["jobs"] as! [[String: Any]]
        jobs[0]["state"] = "waiting"
        jobs[0]["claimID"] = UUID().uuidString.lowercased()
        let questionID = UUID().uuidString.lowercased()
        jobs[0]["questions"] = [["id": questionID, "text": "Which source?"]]
        ledger["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: ledger).write(to: file, options: .atomic)
        other.refresh()
        expect(other.pending.count == 1, "Bridge question appears")
        expect(!other.answer(jobID: jobs[0]["id"] as! String, questionID: "stale", text: "Answer"), "Stale question is rejected")
        expect(other.answer(jobID: jobs[0]["id"] as! String, questionID: questionID, text: "Use this source"), "Answer commits")
        let restored = BobotStore(directory: directory)
        expect(restored.jobs[0].state == "ready" && restored.jobs[0].questions[0].answer == "Use this source", "Answer persists for continuation")
        expect(!restored.answer(jobID: jobs[0]["id"] as! String, questionID: questionID, text: "Overwrite"), "Cannot answer twice")
        expect(restored.cancel(restored.jobs[0].id), "Cancellation commits")
        expect(!restored.cancel(restored.jobs[0].id), "Terminal job cannot change")
        expect(restored.assign(task) && restored.jobs.count == 2, "Explicit rerun gets separate history")
        let longTitleTask = TaskItem(title: String(repeating: "a", count: 240))
        expect(restored.assign(longTitleTask) && BobotStore(directory: directory).jobs.count == 3, "Longest valid task title survives reload")
        expect(!restored.assign(TaskItem(title: String(repeating: "a", count: 241))), "Invalid proposed ledger is rejected before publication")
        expect(BobotStore(directory: directory).jobs.count == 3, "Rejected write leaves valid queue readable")
        expect(!tasks.tasks[0].completed && tasks.tasks[0].agentCompletion == nil, "Agent ledger never completes task")
        var reviewedTask = TaskItem(title: "Previously reviewed output")
        reviewedTask.agentCompletion = AgentCompletion(sessionID: UUID(), artifactURL: "https://example.com/result",
            summary: "Reviewed result", observedAt: Date(), reviewedAt: Date())
        expect(BobotStore(directory: directory).agentCompletionStatus(for: reviewedTask).done,
               "Legacy manual evidence still checks Agent without a Bobot assignment")
        // Agent completion follows persisted assignment state, independently of Me.
        func report(_ state: String) throws {
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            var records = value["jobs"] as! [[String: Any]]
            let index = records.lastIndex { $0["taskID"] as? String == task.id.uuidString.lowercased() }!
            records[index]["state"] = state
            records[index]["result"] = "Finished draft for review"
            value["jobs"] = records
            try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
            restored.refresh()
        }
        for state in ["queued", "working", "waiting", "ready", "failed", "cancelled"] {
            try report(state)
            expect(!restored.agentCompletionStatus(for: task).done, "Non-completed assignment stays unchecked: \(state)")
        }
        try report("completed")
        expect(restored.agentCompletionStatus(for: task).done, "Agent report checks Agent before review")
        expect(BobotStore(directory: directory).agentCompletionStatus(for: task).done, "Agent check survives reopening")
        expect(!AppStore(directory: directory).tasks[0].completed, "Agent completion never checks Me")
        expect(tasks.setUserCompletion(id: task.id, completed: true), "User independently checks Me")
        expect(restored.agentCompletionStatus(for: tasks.tasks[0]).done, "User completion preserves Agent")
        expect(tasks.setUserCompletion(id: task.id, completed: false), "User can reopen their work")
        expect(restored.agentCompletionStatus(for: tasks.tasks[0]).done, "Reopening Me preserves Agent")
        expect(restored.assign(task), "Explicit new assignment succeeds")
        expect(!restored.agentCompletionStatus(for: task).done, "Latest queued assignment supersedes completed result")
        try report("completed")
        let validQueue = try Data(contentsOf: file)
        let original = Data("malformed".utf8)
        try original.write(to: file)
        restored.refresh()
        expect(!restored.agentCompletionStatus(for: task).done, "Unreadable status cannot claim completion")
        expect(!restored.assign(task), "Malformed store blocks assignment")
        expect(try Data(contentsOf: file) == original, "Malformed bytes preserved")
        try validQueue.write(to: file, options: .atomic)
        restored.refresh()
        expect(restored.error == nil, "Successful refresh recovers from queue errors")
        try report("completed")
        expect(restored.agentCompletionStatus(for: task).done, "Recovered completed result checks Agent")
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("private-target")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        expect(!restored.assign(task), "Symlink ledger refused")
        expect(try Data(contentsOf: target) == original, "Symlink target unchanged")
        print("PASS: \(checks) Bobot queue, question, persistence and isolation checks")
    }
}
