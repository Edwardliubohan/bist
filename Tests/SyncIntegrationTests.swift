import Foundation
import CSQLite

@main
struct SyncIntegrationTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-sync-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let aDir = root.appendingPathComponent("a")
        let a = AppStore(directory: aDir)
        let aNote = NoteStore(directory: aDir)
        expect(a.addTask(title: "Original", details: "Keep details"), "legacy task fixture")
        let id = a.tasks[0].id
        aNote.update("  legacy note\n中文\n")
        let original = try Data(contentsOf: a.stateURL)
        let left = try BistReplicaBridge(store: a, note: aNote)
        expect(a.tasks.first?.id == id && aNote.text == "  legacy note\n中文\n", "migration preserves identity and note bytes")
        expect(try Data(contentsOf: left.backupDirectory.appendingPathComponent("state.json")) == original, "migration keeps original backup")
        let bDir = root.appendingPathComponent("b")
        let b = AppStore(directory: bDir)
        let bNote = NoteStore(directory: bDir)
        let right = try BistReplicaBridge(store: b, note: bNote)
        try right.receive(left.database.records())
        try left.receive(right.database.records())
        expect(b.tasks.first?.id == id && b.tasks.first?.notes == "Keep details", "second device imports task")
        expect(bNote.text == aNote.text, "second device imports note")
        expect(a.updateTask(id: id, title: "Renamed on Mac", notes: "Keep details", nextAction: "", source: nil, sourceURL: nil, agentHelpRequested: false), "title edit")
        expect(b.setUserCompletion(id: id, completed: true), "phone completion")
        let aChanges = try left.database.records()
        let bChanges = try right.database.records()
        try left.receive(bChanges)
        try right.receive(aChanges)
        expect(a.tasks.first?.title == "Renamed on Mac" && a.tasks.first?.completed == true, "independent fields survive on Mac")
        expect(b.tasks.first?.title == "Renamed on Mac" && b.tasks.first?.completed == true, "independent fields survive on phone")
        expect(!a.canUndo && !b.canUndo, "incoming edits invalidate snapshot Undo")
        aNote.update("Mac note")
        bNote.update("Phone note")
        let aNotes = try left.database.records()
        let bNotes = try right.database.records()
        try left.receive(bNotes)
        try right.receive(aNotes)
        expect(aNote.text == bNote.text, "note winner converges")
        let recovered = try left.noteVersions()
        expect(recovered.contains(aNote.text == "Mac note" ? "Phone note" : "Mac note"), "losing note text recoverable")
        expect(a.deleteTask(id: id, includingSubtasks: false), "delete synchronized task")
        try right.receive(left.database.records())
        try left.receive(bChanges)
        expect(a.tasks.isEmpty && b.tasks.isEmpty, "stale replica cannot resurrect deleted task")
        let pendingBeforeRestart = try left.database.pendingRecords()
        let reopened = AppStore(directory: aDir)
        let reopenedNote = NoteStore(directory: aDir)
        let reopenedBridge = try BistReplicaBridge(store: reopened, note: reopenedNote)
        expect(try reopenedBridge.database.pendingRecords() == pendingBeforeRestart, "outbox survives restart")
        expect(reopened.tasks.isEmpty && reopenedNote.text == aNote.text, "restart projects canonical state")
        expect(reopened.addTask(title: "Undo deletion"), "new local task")
        let undoID = reopened.tasks[0].id
        expect(reopened.deleteTask(id: undoID, includingSubtasks: false) && reopened.undo(), "explicit Undo restores tombstone")
        try right.receive(reopenedBridge.database.records())
        expect(b.tasks.contains { $0.id == undoID }, "restoration syncs")
        let malformed = ReplicaRecord(id: "task/not-a-uuid", kind: "task", fields: [:])
        do { try right.receive([malformed]); fatalError("invalid remote record accepted") } catch {}
        expect(b.tasks.contains { $0.id == undoID }, "invalid remote batch keeps current task view")
        checks += try adversarialChecks(root: root.appendingPathComponent("adversarial"))
        print("PASS: \(checks) shared sync integration checks")
    }

    struct AdversarialFailure: Error { let messages: [String] }

    @MainActor static func adversarialChecks(root: URL) throws -> Int {
        var checks = 0
        var failures = [String]()
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func make(_ name: String) throws -> (AppStore, NoteStore, BistReplicaBridge) {
            let directory = root.appendingPathComponent(name)
            let store = AppStore(directory: directory)
            let note = NoteStore(directory: directory)
            return (store, note, try BistReplicaBridge(store: store, note: note))
        }
        func taskRecord(_ bridge: BistReplicaBridge, _ id: UUID) throws -> ReplicaRecord {
            try bridge.database.records().first { $0.id == "task." + id.uuidString.lowercased() }!
        }

        // An unrelated deletion must not turn a temporarily orphaned child into
        // a permanent root while its parent record is still in transit.
        let (owner, _, ownerBridge) = try make("parent-owner")
        precondition(owner.addTask(title: "Parent", horizon: .longerTerm))
        let parentID = owner.tasks[0].id
        precondition(owner.addTask(title: "Child", parentID: parentID))
        let childID = owner.tasks[1].id
        let (receiver, _, receiverBridge) = try make("child-receiver")
        precondition(receiver.addTask(title: "Unrelated earlier row"))
        let unrelatedID = receiver.tasks[0].id
        try receiverBridge.receive([taskRecord(ownerBridge, childID)])
        expect(receiver.tasks.first { $0.id == childID }?.parentID == nil, "missing parent displays child at root")
        precondition(receiver.deleteTask(id: unrelatedID, includingSubtasks: false))
        let rawPlacement = try JSONSerialization.jsonObject(with: taskRecord(receiverBridge, childID).fields["placement"]!.value) as! [String: Any]
        expect(rawPlacement["parentID"] as? String == parentID.uuidString, "unrelated deletion preserves raw missing parent")
        try receiverBridge.receive([taskRecord(ownerBridge, parentID)])
        expect(receiver.tasks.first { $0.id == childID }?.parentID == parentID, "late parent restores child's original relationship")

        // Concurrent opposite parent moves must converge to one valid tree.
        let (cycleA, _, cycleABridge) = try make("cycle-a")
        precondition(cycleA.addTask(title: "Cycle A"))
        precondition(cycleA.addTask(title: "Cycle B"))
        let first = cycleA.tasks[0].id
        let second = cycleA.tasks[1].id
        let (cycleB, _, cycleBBridge) = try make("cycle-b")
        try cycleBBridge.receive(cycleABridge.database.records())
        precondition(cycleA.reparentTask(id: first, parentID: second))
        precondition(cycleB.reparentTask(id: second, parentID: first))
        let cycleLeft = try cycleABridge.database.records()
        let cycleRight = try cycleBBridge.database.records()
        try cycleABridge.receive(cycleRight)
        try cycleBBridge.receive(cycleLeft)
        let aParents = Dictionary(uniqueKeysWithValues: cycleA.tasks.map { ($0.id, $0.parentID) })
        let bParents = Dictionary(uniqueKeysWithValues: cycleB.tasks.map { ($0.id, $0.parentID) })
        expect(aParents == bParents, "opposite parent moves converge")
        expect(cycleA.tasks.filter { $0.parentID == nil }.count == 1, "concurrent cycle is broken once")
        let rootID = cycleA.tasks.first { $0.parentID == nil }!.id
        precondition(cycleA.setTaskHorizon(id: rootID, horizon: .longerTerm))
        try cycleBBridge.receive(cycleABridge.database.records())
        expect(cycleB.tasks.allSatisfy { $0.horizon == .longerTerm }, "reconciled tree shares its root horizon")

        // Two offline tag creations represent one logical tag after convergence.
        let (tagsA, _, tagsABridge) = try make("tags-a")
        let (tagsB, _, tagsBBridge) = try make("tags-b")
        precondition(tagsA.addLabel(name: "Shared custom tag", color: .blue))
        precondition(tagsB.addLabel(name: "Shared custom tag", color: .amber))
        let labelA = tagsA.labels.first { $0.name == "Shared custom tag" }!.id
        let labelB = tagsB.labels.first { $0.name == "Shared custom tag" }!.id
        precondition(tagsA.addTask(title: "Tagged A", labelIDs: [labelA]))
        precondition(tagsB.addTask(title: "Tagged B", labelIDs: [labelB]))
        let leftTags = try tagsABridge.database.records()
        let rightTags = try tagsBBridge.database.records()
        try tagsABridge.receive(rightTags)
        try tagsBBridge.receive(leftTags)
        expect(tagsA.labels.filter { $0.name == "Shared custom tag" }.count == 1, "duplicate tag names share one displayed label")
        let canonical = tagsA.labels.first { $0.name == "Shared custom tag" }!.id
        expect(tagsA.tasks.allSatisfy { $0.labelIDs == [canonical] }, "both offline tags map to canonical ID")
        precondition(tagsA.updateLabel(id: canonical, name: "Renamed shared tag", color: .green))
        try tagsBBridge.receive(tagsABridge.database.records())
        try tagsABridge.receive(tagsBBridge.database.records())
        expect(!tagsA.labels.contains { $0.name == "Shared custom tag" }, "renaming canonical label does not resurrect hidden duplicate")
        expect(tagsA.tasks.allSatisfy { $0.labelIDs == [canonical] }, "canonical rename preserves both task assignments")

        // Local agent and session state must survive a remote portable edit and restart.
        let (local, localNote, localBridge) = try make("local-metadata")
        precondition(local.addTask(title: "Private local metadata"))
        let localID = local.tasks[0].id
        precondition(local.addSession(provider: .codex, title: "Local session", url: "https://example.com/session"))
        let sessionID = local.sessions[0].id
        precondition(local.linkTask(id: localID, sessionID: sessionID))
        precondition(local.updateTask(id: localID, title: "Private local metadata", notes: "", nextAction: "", source: "Local source", sourceURL: "https://example.com/source", agentHelpRequested: true))
        let evidence = AgentCompletion(sessionID: sessionID, artifactURL: "https://example.com/result", summary: "Reviewed locally", observedAt: Date(), reviewedAt: Date())
        precondition(local.recordAgentCompletion(evidence, taskID: localID))
        let (peer, _, peerBridge) = try make("local-metadata-peer")
        try peerBridge.receive(localBridge.database.records())
        precondition(peer.updateTask(id: localID, title: "Remote title", notes: "", nextAction: ""))
        try localBridge.receive(peerBridge.database.records())
        let relaunched = AppStore(directory: local.directory)
        let relaunchedNote = NoteStore(directory: local.directory)
        let relaunchedBridge = try BistReplicaBridge(store: relaunched, note: relaunchedNote)
        expect(relaunched.tasks.first?.title == "Remote title", "portable title survives restart")
        expect(relaunched.tasks.first?.linkedSessionID == sessionID && relaunched.sessions.first?.id == sessionID, "local session link survives remote edits and restart")
        let restoredEvidence = relaunched.tasks.first?.agentCompletion
        expect(restoredEvidence?.id == evidence.id && restoredEvidence?.sessionID == sessionID && restoredEvidence?.summary == "Reviewed locally" && restoredEvidence?.artifactURL == "https://example.com/result" && relaunched.tasks.first?.agentHelpRequested == true, "local reviewed agent evidence survives restart")
        expect(abs((restoredEvidence?.reviewedAt.timeIntervalSince1970 ?? 0) - evidence.reviewedAt.timeIntervalSince1970) < 0.000001, "local review timestamp survives restart")
        expect(relaunched.tasks.first?.source == "Local source" && relaunched.tasks.first?.sourceURL == "https://example.com/source", "local source fields survive restart")
        _ = localNote
        _ = relaunchedBridge

        // A broken canonical store must block writes rather than falling back to JSON.
        let failureDirectory = root.appendingPathComponent("canonical-failure")
        let failureStore = AppStore(directory: failureDirectory)
        precondition(failureStore.addTask(title: "Saved before DB failure"))
        let beforeFailure = try Data(contentsOf: failureStore.stateURL)
        let failureNote = NoteStore(directory: failureDirectory)
        let failureReplicaDirectory = failureDirectory.appendingPathComponent("sync")
        _ = try ReplicaDatabase(directory: failureReplicaDirectory)
        var handle: OpaquePointer?
        sqlite3_open(failureReplicaDirectory.appendingPathComponent("sync.sqlite").path, &handle)
        sqlite3_exec(handle, "PRAGMA user_version=99", nil, nil, nil)
        sqlite3_close(handle)
        let coordinator = BistSyncCoordinator(store: failureStore, note: failureNote)
        expect(coordinator.error != nil, "failed canonical database shows a visible error")
        expect(!failureStore.addTask(title: "Must not reach JSON"), "failed canonical database rejects local task mutation")
        expect(try Data(contentsOf: failureStore.stateURL) == beforeFailure, "failed canonical database preserves JSON export")

        // Validation must reject a whole fetched batch before changing data or view.
        let beforeMalformed = try localBridge.database.records()
        let visibleBeforeMalformed = local.currentSnapshot
        var malformedFields = try taskRecord(localBridge, localID).fields
        let titleField = malformedFields["title"]!
        malformedFields["title"] = ReplicaField(value: Data("\"\"".utf8), stamp: titleField.stamp, history: titleField.history, context: titleField.context)
        let malformed = ReplicaRecord(id: "task." + localID.uuidString.lowercased(), kind: "task", fields: malformedFields)
        do {
            try localBridge.receive([taskRecord(ownerBridge, parentID), malformed])
            failures.append("malformed fetched batch was accepted")
        } catch { checks += 1 }
        expect(try localBridge.database.records() == beforeMalformed, "malformed fetched batch preserves canonical database")
        expect(local.currentSnapshot == visibleBeforeMalformed, "malformed fetched batch preserves visible snapshot")

        guard failures.isEmpty else { throw AdversarialFailure(messages: failures) }
        return checks
    }
}
