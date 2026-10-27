import Foundation

@main
struct CoreTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }

        let store = AppStore(directory: root.appendingPathComponent("normal"))
        expect(store.tasks.isEmpty && store.sessions.isEmpty, "new store is clean")
        expect(!store.canUndo, "clean store has no undo")
        expect(!store.addTask(title: "  \n"), "blank title rejected")
        expect(!store.addTask(title: String(repeating: "a", count: 241)), "overlong title rejected")
        expect(!FileManager.default.fileExists(atPath: store.stateURL.path), "invalid input writes no file")
        expect(store.addTask(title: "  First local task  "), "valid task added")
        expect(store.storeError == nil, "success clears validation error")
        expect(store.tasks[0].title == "First local task", "title is trimmed")
        let first = store.tasks[0].id
        expect(!store.tasks[0].isSample, "user task not labeled sample")
        expect(store.complete(id: first), "completion succeeds")
        expect(!store.complete(id: first), "repeated completion is ignored")
        expect(store.undo(), "completion can be undone")
        expect(!store.tasks[0].completed, "undo restored completion state")
        expect(store.addTask(title: "Second local task"), "second task added")
        let second = store.tasks[1].id
        expect(store.complete(id: first) && store.complete(id: second), "two separate completions succeed")
        expect(store.undo() && !store.tasks[1].completed && store.tasks[0].completed, "LIFO undo restores newest task only")
        expect(store.undo() && !store.tasks[0].completed, "older completion also restored")
        expect(store.moveTask(id: first, lane: .attention), "task moved to attention")
        expect(store.deferTask(id: first), "task deferred")
        expect(store.tasks[0].lane == .waiting, "defer enters waiting")
        expect(!store.deferTask(id: first), "repeated defer ignored")
        expect(store.undo() && store.tasks[0].lane == .attention, "defer undo preserves prior lane")
        expect(store.updateTask(id: first, title: "Revised title", notes: "Local notes", nextAction: "Do the next thing", source: "A source", sourceURL: "https://example.com/task"), "details update succeeds")
        expect(!store.updateTask(id: first, title: "Changed", notes: "", nextAction: "", sourceURL: "javascript:alert(1)"), "unsafe source link rejected")
        expect(store.tasks[0].title == "Revised title", "failed update leaves task unchanged")
        for value in ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com", "https:///", "not a url"] {
            expect(!store.addSession(provider: .codex, title: "Session", url: value), "unsafe session URL rejected: \(value)")
        }
        expect(store.addSession(provider: .codex, title: "My bookmark", url: "https://chatgpt.com/"), "valid session bookmark added")
        expect(store.sessions[0].status == .unknown && store.sessions[0].observedAt == nil, "bookmark makes no live status claim")
        expect(store.sessions[0].provider == .codex, "provider stored explicitly")
        let sessionID = store.sessions[0].id
        expect(store.removeSession(id: sessionID) && store.sessions.isEmpty, "session removal succeeds")
        expect(store.undo() && store.sessions[0].id == sessionID, "session removal can be undone")
        let restored = AppStore(directory: store.directory)
        expect(restored.tasks.map(\.id) == store.tasks.map(\.id), "tasks persist across launches")
        expect(restored.tasks[0].notes == "Local notes", "task details persist")
        expect(restored.sessions == store.sessions, "session bookmark persists")
        expect(!restored.canUndo, "undo is scoped to current launch")

        expect(store.loadSamples(), "sample tasks load explicitly")
        expect(store.tasks.filter(\.isSample).count == 4, "all demo rows labeled samples")
        expect(!store.loadSamples(), "sample load is idempotent")
        expect(store.clearSamples(), "samples clear")
        expect(store.tasks.count == 2 && store.tasks.allSatisfy { !$0.isSample }, "clearing samples preserves user tasks")
        let demo = AppStore(directory: root.appendingPathComponent("demo"), demo: true)
        expect(demo.tasks.count == 4 && demo.tasks.allSatisfy(\.isSample), "explicit demo mode contains samples only")
        expect(!demo.canUndo, "initial demo population does not create undo noise")

        let corruptDirectory = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("state.json")
        let corruptBytes = Data("{unfinished local task file".utf8)
        try corruptBytes.write(to: corruptFile)
        let corrupt = AppStore(directory: corruptDirectory)
        expect(corrupt.storeError != nil, "corrupt state surfaces an error")
        expect(!corrupt.addTask(title: "Cannot overwrite") && !corrupt.loadSamples(), "writes blocked after failed load")
        let preservedBytes = try Data(contentsOf: corruptFile)
        expect(preservedBytes == corruptBytes, "corrupt original is preserved")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BistSnapshot()).write(to: corruptFile, options: .atomic)
        expect(corrupt.reload() && corrupt.addTask(title: "After repair"), "explicit reload recovers after file repair")

        let nonDirectory = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: nonDirectory)
        let failing = AppStore(directory: nonDirectory)
        expect(!failing.addTask(title: "Unsaved"), "write failure returns false")
        expect(failing.tasks.isEmpty && !failing.canUndo, "write failure leaves in-memory state unchanged")
        expect(failing.storeError != nil, "write failure is visible")

        let invalidSnapshotDirectory = root.appendingPathComponent("invalid-snapshot")
        try FileManager.default.createDirectory(at: invalidSnapshotDirectory, withIntermediateDirectories: true)
        let duplicate = TaskItem(title: "Duplicate")
        let invalid = BistSnapshot(tasks: [duplicate, duplicate])
        try encoder.encode(invalid).write(to: invalidSnapshotDirectory.appendingPathComponent("state.json"))
        let invalidStore = AppStore(directory: invalidSnapshotDirectory)
        expect(invalidStore.storeError != nil && !invalidStore.addTask(title: "No overwrite"), "duplicate IDs rejected on reload")

        let imports = AppStore(directory: root.appendingPathComponent("imports"))
        let proposalA = TaskProposal(id: UUID(), title: "First proposal", nextAction: "Review the local draft", source: "Local update", createdAt: Date(timeIntervalSince1970: 12345))
        let proposalB = TaskProposal(id: UUID(), title: "Second proposal", nextAction: "Choose the next step", source: "Local update", createdAt: Date(timeIntervalSince1970: 12346))
        let badProposal = TaskProposal(id: UUID(), title: "  ", nextAction: "", source: "Local update", createdAt: Date())
        expect(!imports.importProposals([proposalA, badProposal]) && imports.tasks.isEmpty, "invalid batch imports nothing")
        expect(!imports.importProposals([proposalA, proposalA]) && imports.tasks.isEmpty, "duplicate proposal IDs rejected")
        expect(imports.importProposals([proposalA, proposalB]), "reviewed batch imports")
        expect(imports.tasks.map(\.id) == [proposalA.id, proposalB.id], "import preserves proposal UUIDs")
        expect(imports.tasks[0].nextAction == proposalA.nextAction && imports.tasks[0].source == proposalA.source, "import preserves next action and source")
        expect(imports.tasks[0].createdAt == proposalA.createdAt, "import preserves creation date")
        expect(imports.tasks.allSatisfy { !$0.isSample && !$0.completed && $0.lane == .next }, "imports are local open tasks")
        expect(imports.importProposals([proposalA, proposalB]) && imports.tasks.count == 2, "repeated import succeeds without duplicates")
        expect(imports.undo() && imports.tasks.isEmpty && !imports.canUndo, "whole batch has exactly one undo step")
        expect(imports.importProposals([proposalA]), "single proposal import succeeds")
        expect(imports.updateTask(id: proposalA.id, title: "User-edited task", notes: "Keep my changes", nextAction: "My next step"), "imported task remains editable")
        expect(imports.importProposals([proposalA, proposalB]) && imports.tasks.count == 2, "mixed existing/new batch appends only new IDs")
        expect(imports.tasks[0].title == "User-edited task" && imports.tasks[0].notes == "Keep my changes", "retry never overwrites edited task")
        expect(imports.undo() && imports.tasks.count == 1 && imports.tasks[0].id == proposalA.id, "mixed batch undo removes only its additions")
        let importsReloaded = AppStore(directory: imports.directory)
        expect(importsReloaded.importProposals([proposalA]) && importsReloaded.tasks.count == 1, "retry remains idempotent after process restart")
        expect(!importsReloaded.canUndo, "no-op import creates no undo entry")
        expect(!failing.importProposals([proposalA]) && failing.tasks.isEmpty, "failed import write rolls back entire batch")
        expect(!invalidStore.importProposals([proposalA]) && invalidStore.tasks.isEmpty, "unreadable store blocks imports")

        let unchanged = AppStore(directory: root.appendingPathComponent("unchanged-detail"))
        expect(unchanged.addTask(title: "Untouched detail"), "no-op scenario creates its task")
        let unchangedTask = unchanged.tasks[0]
        let bytesBeforeSave = try Data(contentsOf: unchanged.stateURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: unchanged.stateURL.path)
        let attributesBeforeSave = try FileManager.default.attributesOfItem(atPath: unchanged.stateURL.path)
        expect(unchanged.updateTask(id: unchangedTask.id, title: unchangedTask.title, notes: unchangedTask.notes, nextAction: unchangedTask.nextAction), "untouched detail saves successfully")
        let bytesAfterSave = try Data(contentsOf: unchanged.stateURL)
        let attributesAfterSave = try FileManager.default.attributesOfItem(atPath: unchanged.stateURL.path)
        expect(bytesBeforeSave == bytesAfterSave, "unchanged detail preserves file bytes")
        expect(attributesBeforeSave[.modificationDate] as? Date == attributesAfterSave[.modificationDate] as? Date, "unchanged detail does not rewrite the file")
        expect(unchanged.updateTask(id: unchangedTask.id, title: unchangedTask.title, notes: unchangedTask.notes, nextAction: unchangedTask.nextAction) && unchanged.moveTask(id: unchangedTask.id, lane: .waiting), "untouched detail can save then move")
        expect(unchanged.undo() && unchanged.tasks[0].lane == .next, "undo after save-and-move restores lane")
        expect(unchanged.undo() && unchanged.tasks.isEmpty && !unchanged.canUndo, "next undo removes creation without a phantom detail entry")

        let blockedNoop = AppStore(directory: root.appendingPathComponent("blocked-noop"))
        expect(blockedNoop.addTask(title: "Known task"), "blocked no-op scenario creates its task")
        let blockedTask = blockedNoop.tasks[0]
        try corruptBytes.write(to: blockedNoop.stateURL)
        expect(!blockedNoop.reload(), "invalid external file blocks a populated store")
        expect(!blockedNoop.updateTask(id: blockedTask.id, title: blockedTask.title, notes: blockedTask.notes, nextAction: blockedTask.nextAction), "unchanged detail still fails when store is unreadable")
        let blockedBytes = try Data(contentsOf: blockedNoop.stateURL)
        expect(blockedBytes == corruptBytes && blockedNoop.storeError != nil, "blocked no-op preserves invalid file and error")

        // A v1 fixture includes every legacy field; opening it must not rewrite it.
        let legacyTask = TaskItem(title: "Keep every legacy field", notes: "Existing notes", nextAction: "Existing action", source: "Local source", sourceURL: "https://example.com/source", lane: .waiting, isSample: true, completed: true, createdAt: Date(timeIntervalSince1970: 1000))
        let legacySession = SessionItem(provider: .claudeCode, title: "Existing session", url: "https://example.com/session", status: .disconnected, observedAt: Date(timeIntervalSince1970: 900))
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(BistSnapshot(tasks: [legacyTask], sessions: [legacySession]))) as! [String: Any]
        legacyObject["schemaVersion"] = 1
        legacyObject.removeValue(forKey: "labels")
        var legacyTasks = legacyObject["tasks"] as! [[String: Any]]
        for key in ["parentID", "labelIDs", "linkedSessionID", "agentCompletion", "horizon", "agentHelpRequested"] { legacyTasks[0].removeValue(forKey: key) }
        legacyObject["tasks"] = legacyTasks
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject, options: [.prettyPrinted, .sortedKeys])
        let migrationDirectory = root.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
        let migrationFile = migrationDirectory.appendingPathComponent("state.json")
        try legacyBytes.write(to: migrationFile)
        let migrated = AppStore(directory: migrationDirectory)
        expect(migrated.tasks == [legacyTask] && migrated.sessions == [legacySession], "v1 migration preserves all legacy task and session data")
        expect(migrated.labels == TaskLabel.defaults, "v1 migration offers deterministic editable defaults")
        expect(migrated.tasks[0].parentID == nil && migrated.tasks[0].labelIDs.isEmpty && migrated.tasks[0].linkedSessionID == nil && migrated.tasks[0].agentCompletion == nil, "legacy tasks receive only empty optional feature defaults")
        expect(migrated.tasks[0].horizon == .shortTerm && !migrated.tasks[0].agentHelpRequested && migrated.tasks[0].lane == .waiting, "v1 horizon and help defaults do not reinterpret legacy lane")
        expect(migrated.tasks[0].completed && migrated.tasks[0].completedAt == nil, "legacy completed task keeps unknown completion date")
        let bytesAfterMigrationRead = try Data(contentsOf: migrationFile)
        expect(bytesAfterMigrationRead == legacyBytes && !migrated.canUndo, "opening v1 performs no write or undo mutation")
        expect(migrated.updateTask(id: legacyTask.id, title: legacyTask.title, notes: legacyTask.notes, nextAction: legacyTask.nextAction, source: legacyTask.source, sourceURL: legacyTask.sourceURL), "unchanged legacy detail saves successfully")
        let bytesAfterLegacyNoop = try Data(contentsOf: migrationFile)
        expect(bytesAfterLegacyNoop == legacyBytes, "no-op legacy save does not migrate on disk")
        expect(migrated.addLabel(name: "Research", color: .amber), "first real mutation after migration succeeds")
        let migratedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationFile)) as! [String: Any]
        expect(migratedObject["schemaVersion"] as? Int == 2, "next real write persists schema v2")
        let migratedReload = AppStore(directory: migrationDirectory)
        expect(migratedReload.tasks == [legacyTask] && migratedReload.sessions == [legacySession], "v2 reload retains exact legacy fields")
        expect(migratedReload.labels.map(\.name) == ["School", "Class", "Koan", "Research"], "migrated label mutation persists")
        expect(migrated.undo() && migrated.labels == TaskLabel.defaults && migrated.tasks == [legacyTask], "migration-era undo restores data without losing legacy content")

        let hierarchy = AppStore(directory: root.appendingPathComponent("hierarchy"))
        expect(hierarchy.labels == TaskLabel.defaults, "new store starts with editable default labels")
        expect(!hierarchy.addTask(title: "Orphan", parentID: UUID()), "new child cannot reference a missing parent")
        expect(hierarchy.addTask(title: "Parent"), "parent task added")
        let parentID = hierarchy.tasks[0].id
        expect(hierarchy.addTask(title: "Child", parentID: parentID), "child task added")
        let childID = hierarchy.tasks[1].id
        expect(hierarchy.addTask(title: "Grandchild", parentID: childID), "grandchild task added")
        let grandchildID = hierarchy.tasks[2].id
        expect(!hierarchy.reparentTask(id: parentID, parentID: parentID), "task cannot parent itself")
        expect(!hierarchy.reparentTask(id: parentID, parentID: grandchildID), "reparent cannot create ancestor cycle")
        expect(!hierarchy.reparentTask(id: childID, parentID: UUID()), "reparent cannot orphan a task")
        expect(hierarchy.reparentTask(id: grandchildID, parentID: parentID), "valid reparent succeeds")
        expect(hierarchy.undo() && hierarchy.tasks[2].parentID == childID, "reparent undo restores hierarchy")
        expect(hierarchy.complete(id: parentID), "parent user completion succeeds")
        expect(hierarchy.tasks[0].completed && !hierarchy.tasks[1].completed && !hierarchy.tasks[2].completed, "parent completion does not complete or remove descendants")
        expect(hierarchy.tasks[1].parentID == parentID, "open child remains linked under completed parent")
        expect(hierarchy.setUserCompletion(id: parentID, completed: false) && !hierarchy.tasks[0].completed, "user completion can be independently reopened")
        expect(hierarchy.addTask(title: "Another child", parentID: parentID), "completed or reopened parent accepts explicit child creation")

        expect(!hierarchy.addLabel(name: " school ", color: .rose), "case-insensitive duplicate label rejected")
        expect(!hierarchy.addLabel(name: "", color: .gray) && !hierarchy.addLabel(name: "Two\nLines", color: .gray), "empty and multiline label names rejected")
        expect(!hierarchy.addLabel(name: "Two\u{2028}Lines", color: .gray) && !hierarchy.addLabel(name: "Two\u{2029}Paragraphs", color: .gray), "Unicode line separators rejected in labels")
        expect(!hierarchy.addLabel(name: String(repeating: "x", count: 41), color: .gray), "overlong label rejected")
        expect(hierarchy.addLabel(name: "  Research  ", color: .amber), "custom label added and trimmed")
        let researchID = hierarchy.labels.last!.id
        expect(hierarchy.labels.last?.name == "Research", "label name normalization persists")
        expect(hierarchy.setTaskLabels(id: parentID, labelIDs: [researchID, hierarchy.labels[0].id]), "task can have several valid labels")
        expect(hierarchy.setTaskLabels(id: childID, labelIDs: [researchID]), "label can be shared across tasks")
        expect(!hierarchy.setTaskLabels(id: parentID, labelIDs: [researchID, researchID]), "duplicate labels on one task rejected")
        expect(!hierarchy.setTaskLabels(id: parentID, labelIDs: [UUID()]), "missing task label rejected")
        expect(hierarchy.updateLabel(id: researchID, name: "Reading", color: .rose), "label edit keeps identity")
        expect(hierarchy.labels.last?.id == researchID && hierarchy.labels.last?.color == .rose && hierarchy.tasks[0].labelIDs.contains(researchID), "label edit preserves task references")
        expect(!hierarchy.updateLabel(id: researchID, name: "Class", color: .blue), "label rename cannot duplicate another name")
        let labelsBeforeRemoval = hierarchy.labels
        let taskLabelsBeforeRemoval = hierarchy.tasks.map(\.labelIDs)
        expect(hierarchy.deleteLabel(id: researchID), "referenced label removal succeeds")
        expect(!hierarchy.labels.contains { $0.id == researchID } && hierarchy.tasks.allSatisfy { !$0.labelIDs.contains(researchID) }, "label removal clears all references atomically")
        expect(hierarchy.undo() && hierarchy.labels == labelsBeforeRemoval && hierarchy.tasks.map(\.labelIDs) == taskLabelsBeforeRemoval, "one undo restores label and every task reference")
        let hierarchyReload = AppStore(directory: hierarchy.directory)
        expect(hierarchyReload.tasks.map(\.parentID) == hierarchy.tasks.map(\.parentID) && hierarchyReload.labels == hierarchy.labels && hierarchyReload.tasks.map(\.labelIDs) == hierarchy.tasks.map(\.labelIDs), "hierarchy and label edits persist")

        let evidenceStore = AppStore(directory: root.appendingPathComponent("evidence"))
        expect(evidenceStore.addTask(title: "User and agent work"), "evidence scenario creates task")
        let evidenceTaskID = evidenceStore.tasks[0].id
        expect(evidenceStore.addSession(provider: .codex, title: "Saved Codex link", url: "https://example.com/codex"), "evidence scenario saves session bookmark")
        let codexID = evidenceStore.sessions[0].id
        expect(evidenceStore.addSession(provider: .claudeCode, title: "Saved Claude link", url: "https://example.com/claude"), "second session saved")
        let claudeID = evidenceStore.sessions[1].id
        expect(!evidenceStore.linkTask(id: evidenceTaskID, sessionID: UUID()), "task cannot link missing session")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let evidence = AgentCompletion(sessionID: codexID, artifactURL: "https://example.com/artifact", summary: "Reviewed local result", observedAt: now.addingTimeInterval(-60), reviewedAt: now)
        expect(!evidenceStore.recordAgentCompletion(evidence, taskID: evidenceTaskID), "agent evidence rejected before explicit task session link")
        expect(evidenceStore.linkTask(id: evidenceTaskID, sessionID: codexID), "task links existing session")
        var mismatch = evidence
        mismatch.sessionID = claudeID
        expect(!evidenceStore.recordAgentCompletion(mismatch, taskID: evidenceTaskID), "evidence session must match task link")
        var unsafe = evidence
        unsafe.artifactURL = "javascript:alert(1)"
        expect(!evidenceStore.recordAgentCompletion(unsafe, taskID: evidenceTaskID), "unsafe evidence artifact rejected")
        unsafe.artifactURL = "https://name:secret@example.com/result"
        expect(!evidenceStore.recordAgentCompletion(unsafe, taskID: evidenceTaskID), "credential-bearing evidence artifact rejected")
        var future = evidence
        future.observedAt = now.addingTimeInterval(600)
        future.reviewedAt = now.addingTimeInterval(600)
        expect(!evidenceStore.recordAgentCompletion(future, taskID: evidenceTaskID), "future-dated evidence rejected beyond clock tolerance")
        var reversed = evidence
        reversed.reviewedAt = evidence.observedAt.addingTimeInterval(-600)
        expect(!evidenceStore.recordAgentCompletion(reversed, taskID: evidenceTaskID), "review cannot significantly precede observation")
        var blankEvidence = evidence
        blankEvidence.summary = "  "
        expect(!evidenceStore.recordAgentCompletion(blankEvidence, taskID: evidenceTaskID), "empty evidence summary rejected")
        expect(evidenceStore.recordAgentCompletion(evidence, taskID: evidenceTaskID), "explicit reviewed evidence accepted")
        expect(evidenceStore.tasks[0].agentCompletion == evidence && !evidenceStore.tasks[0].completed, "agent completion is independent of user completion")
        expect(evidenceStore.sessions[0].status == .unknown && evidenceStore.sessions[0].observedAt == nil, "reviewed evidence never fabricates live session status")
        expect(evidenceStore.recordAgentCompletion(evidence, taskID: evidenceTaskID), "exact evidence retry is idempotently successful")
        var replacementEvidence = evidence
        replacementEvidence.id = UUID()
        replacementEvidence.summary = "A different reviewed result"
        expect(!evidenceStore.recordAgentCompletion(replacementEvidence, taskID: evidenceTaskID) && evidenceStore.tasks[0].agentCompletion == evidence, "existing evidence cannot be replaced before explicit clear")
        var changedRetry = evidence
        changedRetry.reviewedAt = evidence.reviewedAt.addingTimeInterval(1)
        expect(!evidenceStore.recordAgentCompletion(changedRetry, taskID: evidenceTaskID), "same evidence ID cannot overwrite its recorded review timestamp")
        expect(!evidenceStore.removeSession(id: codexID), "linked session deletion is blocked")
        expect(!evidenceStore.linkTask(id: evidenceTaskID, sessionID: nil) && !evidenceStore.linkTask(id: evidenceTaskID, sessionID: claudeID), "evidence provenance prevents silent unlink or relink")
        expect(evidenceStore.complete(id: evidenceTaskID) && evidenceStore.tasks[0].agentCompletion == evidence, "user completion preserves agent evidence")
        expect(evidenceStore.setUserCompletion(id: evidenceTaskID, completed: false) && evidenceStore.tasks[0].agentCompletion == evidence, "reopening user completion preserves agent evidence")
        expect(evidenceStore.clearAgentCompletion(taskID: evidenceTaskID) && !evidenceStore.tasks[0].completed && evidenceStore.tasks[0].agentCompletion == nil, "explicit evidence clearing preserves user state")
        expect(evidenceStore.undo() && evidenceStore.tasks[0].agentCompletion == evidence && !evidenceStore.tasks[0].completed, "evidence-clear undo restores exact provenance")
        expect(evidenceStore.addTask(title: "Other result task"), "second evidence task created")
        let secondEvidenceTaskID = evidenceStore.tasks[1].id
        expect(evidenceStore.linkTask(id: secondEvidenceTaskID, sessionID: codexID), "second task links same session")
        expect(!evidenceStore.recordAgentCompletion(evidence, taskID: secondEvidenceTaskID), "evidence ID cannot be reused across different tasks")
        let evidenceReload = AppStore(directory: evidenceStore.directory)
        expect(evidenceReload.tasks[0].agentCompletion == evidence && evidenceReload.tasks[0].linkedSessionID == codexID && !evidenceReload.tasks[0].completed, "agent evidence and independent user state persist")
        expect(evidenceStore.clearAgentCompletion(taskID: evidenceTaskID) && evidenceStore.linkTask(id: evidenceTaskID, sessionID: nil), "explicit evidence clear allows unlink")
        expect(evidenceStore.linkTask(id: secondEvidenceTaskID, sessionID: nil) && evidenceStore.removeSession(id: codexID), "session can be removed after all tasks explicitly unlink")
        expect(evidenceStore.undo() && evidenceStore.sessions.contains { $0.id == codexID }, "session removal undo restores bookmark")

        let sampleTree = AppStore(directory: root.appendingPathComponent("sample-tree"), demo: true)
        let sampleParentID = sampleTree.tasks[0].id
        expect(sampleTree.addTask(title: "Real child of sample", parentID: sampleParentID), "user can explicitly add a real child under sample")
        let realChildID = sampleTree.tasks.last!.id
        expect(sampleTree.addTask(title: "Real grandchild", parentID: realChildID), "real grandchild added")
        expect(sampleTree.clearSamples(), "sample tree clears safely")
        expect(sampleTree.tasks.count == 2 && sampleTree.tasks[0].parentID == nil && sampleTree.tasks[1].parentID == realChildID, "clearing samples promotes real descendants without losing hierarchy")
        expect(sampleTree.undo() && sampleTree.tasks.count == 6 && sampleTree.tasks[4].parentID == sampleParentID, "sample clear undo restores samples and original parent link")

        // Deep hierarchies are validated iteratively; corrupt references never
        // replace a loaded file or become a silently repaired task tree.
        let deepDirectory = root.appendingPathComponent("deep-hierarchy")
        try FileManager.default.createDirectory(at: deepDirectory, withIntermediateDirectories: true)
        var deepTasks: [TaskItem] = []
        for depth in 0..<1200 {
            deepTasks.append(TaskItem(title: "Level \(depth)", createdAt: Date(timeIntervalSince1970: 1000), parentID: deepTasks.last?.id))
        }
        let deepFile = deepDirectory.appendingPathComponent("state.json")
        try encoder.encode(BistSnapshot(tasks: deepTasks)).write(to: deepFile)
        let deepStore = AppStore(directory: deepDirectory)
        expect(deepStore.tasks.count == 1200 && deepStore.storeError == nil, "deep hierarchy loads without recursive stack growth")
        expect(!deepStore.reparentTask(id: deepTasks[0].id, parentID: deepTasks.last!.id), "deep ancestor cycle rejected")
        expect(deepStore.reparentTask(id: deepTasks.last!.id, parentID: nil) && deepStore.undo(), "deep reparent and undo succeed")

        func rejectsSnapshot(_ value: BistSnapshot, _ name: String) throws -> Bool {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("state.json")
            let original = try encoder.encode(value)
            try original.write(to: file)
            let loaded = AppStore(directory: directory)
            let rejected = loaded.storeError != nil && !loaded.addTask(title: "Must not overwrite")
            let after = try Data(contentsOf: file)
            return rejected && after == original
        }
        var orphan = TaskItem(title: "Orphan", parentID: UUID())
        let orphanRejected = try rejectsSnapshot(BistSnapshot(tasks: [orphan]), "invalid-parent")
        expect(orphanRejected, "persisted orphan reference rejected without modifying file")
        orphan.parentID = orphan.id
        let selfParentRejected = try rejectsSnapshot(BistSnapshot(tasks: [orphan]), "invalid-self-parent")
        expect(selfParentRejected, "persisted self-parent rejected")
        var cycleA = TaskItem(title: "Cycle A")
        let cycleB = TaskItem(title: "Cycle B", parentID: cycleA.id)
        cycleA.parentID = cycleB.id
        let cycleRejected = try rejectsSnapshot(BistSnapshot(tasks: [cycleA, cycleB]), "invalid-cycle")
        expect(cycleRejected, "persisted multi-node cycle rejected")
        let invalidLabelTask = TaskItem(title: "Missing label", labelIDs: [UUID()])
        let missingLabelRejected = try rejectsSnapshot(BistSnapshot(tasks: [invalidLabelTask]), "invalid-label-reference")
        expect(missingLabelRejected, "persisted missing label rejected")
        let duplicateLabel = TaskLabel.defaults[0]
        let duplicateLabelRejected = try rejectsSnapshot(BistSnapshot(labels: [duplicateLabel, duplicateLabel]), "invalid-label-ids")
        expect(duplicateLabelRejected, "duplicate persisted label IDs rejected")
        let duplicateNameRejected = try rejectsSnapshot(BistSnapshot(labels: [duplicateLabel, TaskLabel(name: "school", color: .gray)]), "invalid-label-names")
        expect(duplicateNameRejected, "duplicate persisted label names rejected")
        let invalidSessionTask = TaskItem(title: "Missing session", linkedSessionID: UUID())
        let missingSessionRejected = try rejectsSnapshot(BistSnapshot(tasks: [invalidSessionTask]), "invalid-session-reference")
        expect(missingSessionRejected, "persisted missing session link rejected")
        let unlinkedEvidenceTask = TaskItem(title: "Unlinked evidence", agentCompletion: evidence)
        let unlinkedEvidenceRejected = try rejectsSnapshot(BistSnapshot(tasks: [unlinkedEvidenceTask], sessions: evidenceReload.sessions), "invalid-evidence-reference")
        expect(unlinkedEvidenceRejected, "persisted evidence requires matching linked session")
        let futureSchemaRejected = try rejectsSnapshot(BistSnapshot(schemaVersion: 999), "future-schema")
        expect(futureSchemaRejected, "unknown future schema is preserved and rejected")

        let creation = AppStore(directory: root.appendingPathComponent("atomic-creation"))
        let creationTag = creation.labels[0].id
        expect(!creation.addTask(title: " ", details: "Details", labelIDs: [creationTag], agentHelpRequested: true), "atomic creation rejects empty title before writing anything")
        expect(!creation.addTask(title: "No partial task", details: String(repeating: "x", count: 8001), agentHelpRequested: true), "atomic creation rejects oversized details")
        expect(!creation.addTask(title: "No unknown tag", labelIDs: [UUID()], agentHelpRequested: true), "atomic creation rejects nonexistent labels")
        expect(!creation.addTask(title: "No duplicate tag", labelIDs: [creationTag, creationTag], agentHelpRequested: true), "atomic creation rejects duplicate labels")
        expect(creation.tasks.isEmpty && !creation.canUndo && !FileManager.default.fileExists(atPath: creation.stateURL.path), "invalid multi-field creation has no disk or undo side effect")
        expect(creation.addTask(title: "  New local task  ", details: "Optional details", labelIDs: [creationTag], agentHelpRequested: true, horizon: .longerTerm), "name details tag help intent and horizon commit together")
        let created = creation.tasks[0]
        expect(created.title == "New local task" && created.notes == "Optional details" && created.labelIDs == [creationTag] && created.agentHelpRequested && created.horizon == .longerTerm, "creation stores all requested values")
        expect(!created.completed && created.agentCompletion == nil && created.linkedSessionID == nil && creation.sessions.isEmpty, "agent-help intent creates no agent connection or completion")
        expect(creation.undo() && creation.tasks.isEmpty && !creation.canUndo, "one undo removes whole creation without partial fields")

        var orderedParent = TaskItem(title: "First stored root", lane: .waiting, completed: true, createdAt: Date(timeIntervalSince1970: 900))
        let orderedChild = TaskItem(title: "Second stored child", lane: .attention, createdAt: Date(timeIntervalSince1970: 100), parentID: orderedParent.id)
        let orderedSibling = TaskItem(title: "Third stored sibling", createdAt: Date(timeIntervalSince1970: 500), parentID: orderedParent.id)
        let orderedOtherRoot = TaskItem(title: "Fourth stored root", lane: .attention, createdAt: Date(timeIntervalSince1970: 50))
        orderedParent.notes = "Preserve hidden old details"
        let orderedTasks = [orderedParent, orderedChild, orderedSibling, orderedOtherRoot]
        var previousV2 = try JSONSerialization.jsonObject(with: encoder.encode(BistSnapshot(tasks: orderedTasks))) as! [String: Any]
        var previousV2Tasks = previousV2["tasks"] as! [[String: Any]]
        for index in previousV2Tasks.indices {
            previousV2Tasks[index].removeValue(forKey: "horizon")
            previousV2Tasks[index].removeValue(forKey: "agentHelpRequested")
        }
        previousV2["tasks"] = previousV2Tasks
        let previousV2Bytes = try JSONSerialization.data(withJSONObject: previousV2, options: [.sortedKeys])
        let horizonDirectory = root.appendingPathComponent("horizon-migration")
        try FileManager.default.createDirectory(at: horizonDirectory, withIntermediateDirectories: true)
        let horizonFile = horizonDirectory.appendingPathComponent("state.json")
        try previousV2Bytes.write(to: horizonFile)
        let horizons = AppStore(directory: horizonDirectory)
        expect(horizons.tasks == orderedTasks, "previous v2 without horizon/help preserves exact stored task order and fields")
        expect(horizons.tasks.allSatisfy { $0.horizon == .shortTerm && !$0.agentHelpRequested }, "all existing v2 tasks default short term without inferred help")
        let unchangedV2Bytes = try Data(contentsOf: horizonFile)
        expect(unchangedV2Bytes == previousV2Bytes, "reading older v2 does not write inferred fields")
        expect(horizons.setTaskHorizon(id: orderedChild.id, horizon: .longerTerm), "moving child context moves its whole root tree")
        expect(horizons.tasks.map(\.horizon) == [.longerTerm, .longerTerm, .longerTerm, .shortTerm], "parent and siblings stay in one group")
        expect(horizons.tasks.map(\.id) == orderedTasks.map(\.id) && horizons.tasks.map(\.createdAt) == orderedTasks.map(\.createdAt) && horizons.tasks.map(\.lane) == orderedTasks.map(\.lane), "group move never reorders or rewrites legacy lanes and dates")
        expect(horizons.tasks[0].completed && !horizons.tasks[1].completed, "group move does not change user completion")
        expect(horizons.undo() && horizons.tasks == orderedTasks && !horizons.canUndo, "one group-move undo restores whole tree")
        expect(horizons.setTaskHorizon(id: orderedOtherRoot.id, horizon: .longerTerm), "independent root can move groups")
        expect(horizons.reparentTask(id: orderedChild.id, parentID: orderedOtherRoot.id), "reparent across groups succeeds")
        expect(horizons.tasks[1].horizon == .longerTerm && horizons.tasks[0].horizon == .shortTerm && horizons.tasks[2].horizon == .shortTerm, "reparent adopts new parent group without changing former siblings")
        expect(horizons.addTask(title: "Inherited horizon child", parentID: orderedOtherRoot.id, horizon: .shortTerm), "new child can be created under longer-term parent")
        expect(horizons.tasks.last?.horizon == .longerTerm, "new child always inherits parent horizon")
        let inheritedChildID = horizons.tasks.last!.id
        expect(horizons.reparentTask(id: orderedOtherRoot.id, parentID: orderedParent.id), "root with descendants can become a subtask")
        expect(horizons.tasks.allSatisfy { $0.horizon == .shortTerm }, "reparent moves entire nested subtree to new parent group")
        expect(horizons.tasks.map(\.id) == orderedTasks.map(\.id) + [inheritedChildID], "nested reparent retains stable store order")
        expect(horizons.undo() && horizons.tasks[1].horizon == .longerTerm && horizons.tasks[3].horizon == .longerTerm && horizons.tasks[4].horizon == .longerTerm, "nested reparent undo restores all affected group memberships")
        expect(horizons.reparentTask(id: orderedChild.id, parentID: nil) && horizons.tasks[1].horizon == .longerTerm, "detaching child keeps its explicit current group")
        let horizonsReload = AppStore(directory: horizonDirectory)
        expect(horizonsReload.tasks.map(\.id) == horizons.tasks.map(\.id) && horizonsReload.tasks.map(\.horizon) == horizons.tasks.map(\.horizon) && horizonsReload.tasks.map(\.parentID) == horizons.tasks.map(\.parentID), "horizon edits and stable order persist across reload")
        expect(!horizons.setTaskHorizon(id: UUID(), horizon: .shortTerm), "unknown task cannot move groups")

        let helpStore = AppStore(directory: root.appendingPathComponent("help-intent"))
        expect(helpStore.addTask(title: "Intent only", details: "Detail", agentHelpRequested: true), "agent help can be requested at creation")
        let helpID = helpStore.tasks[0].id
        expect(helpStore.updateTask(id: helpID, title: "Updated intent task", notes: "Updated detail", nextAction: "Hidden legacy action", source: "Original source", sourceURL: "https://example.com/source"), "editing without help argument succeeds")
        expect(helpStore.tasks[0].agentHelpRequested && helpStore.tasks[0].agentCompletion == nil && !helpStore.tasks[0].completed, "omitted help argument preserves intent without implying completion")
        expect(helpStore.updateTask(id: helpID, title: "Updated intent task", notes: "Updated detail", nextAction: "Hidden legacy action", source: "Original source", sourceURL: "https://example.com/source", agentHelpRequested: false), "explicit help toggle changes only intent")
        expect(!helpStore.tasks[0].agentHelpRequested && helpStore.tasks[0].nextAction == "Hidden legacy action" && helpStore.tasks[0].source == "Original source", "help edit preserves supplied hidden legacy fields")
        expect(helpStore.undo() && helpStore.tasks[0].agentHelpRequested, "help intent edit is undoable")
        expect(helpStore.complete(id: helpID) && helpStore.tasks[0].agentHelpRequested && helpStore.tasks[0].agentCompletion == nil, "user completion does not create agent evidence or erase intent")
        let helpReload = AppStore(directory: helpStore.directory)
        expect(helpReload.tasks[0].agentHelpRequested && helpReload.tasks[0].completed && helpReload.sessions.isEmpty, "help intent persists with independent user state and no session execution")

        let mismatchedRoot = TaskItem(title: "Longer root", horizon: .longerTerm)
        let mismatchedChild = TaskItem(title: "Short child", parentID: mismatchedRoot.id)
        let mismatchedGroupsRejected = try rejectsSnapshot(BistSnapshot(tasks: [mismatchedRoot, mismatchedChild]), "invalid-horizon-tree")
        expect(mismatchedGroupsRejected, "persisted hierarchy cannot split a parent and child across groups")

        let historyTasks = [
            TaskItem(title: "Legacy A", completed: true, createdAt: Date(timeIntervalSince1970: 999)),
            TaskItem(title: "Older completion", completed: true, createdAt: Date(timeIntervalSince1970: 2000), completedAt: Date(timeIntervalSince1970: 100)),
            TaskItem(title: "Same time A", completed: true, createdAt: Date(timeIntervalSince1970: 800), completedAt: Date(timeIntervalSince1970: 500)),
            TaskItem(title: "Still open", lane: .waiting, createdAt: Date(timeIntervalSince1970: 3000)),
            TaskItem(title: "Newest completion", completed: true, createdAt: Date(timeIntervalSince1970: 50), completedAt: Date(timeIntervalSince1970: 900)),
            TaskItem(title: "Same time B", completed: true, createdAt: Date(timeIntervalSince1970: 700), completedAt: Date(timeIntervalSince1970: 500)),
            TaskItem(title: "Legacy B", completed: true, createdAt: Date(timeIntervalSince1970: 200))
        ]
        let historyDirectory = root.appendingPathComponent("completion-history")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try encoder.encode(BistSnapshot(tasks: historyTasks)).write(to: historyDirectory.appendingPathComponent("state.json"))
        let history = AppStore(directory: historyDirectory)
        expect(history.completedHistory.map(\.title) == ["Newest completion", "Same time A", "Same time B", "Older completion", "Legacy A", "Legacy B"], "history sorts actual completion date descending with stable ties and unknown dates last")
        expect(history.tasks == historyTasks, "history sorting leaves stored task order and creation dates untouched")
        let legacyHistoryID = historyTasks[0].id
        expect(history.setUserCompletion(id: legacyHistoryID, completed: true) && history.tasks[0].completedAt == nil, "idempotent legacy completion never invents a date")
        let openHistoryID = historyTasks[3].id
        let beforeCompletion = Date()
        expect(history.setUserCompletion(id: openHistoryID, completed: true), "user completion records an actual timestamp")
        let firstCompletion = history.tasks[3].completedAt!
        expect(firstCompletion >= beforeCompletion && firstCompletion <= Date(), "completion timestamp is the user's action time")
        expect(history.completedHistory.first?.id == openHistoryID, "newly completed task leads user history")
        let completionBytes = try Data(contentsOf: history.stateURL)
        expect(history.setUserCompletion(id: openHistoryID, completed: true) && history.tasks[3].completedAt == firstCompletion, "repeated completion preserves original timestamp")
        let repeatedCompletionBytes = try Data(contentsOf: history.stateURL)
        expect(repeatedCompletionBytes == completionBytes, "repeated completion does not rewrite timestamp on disk")
        expect(history.undo() && !history.tasks[3].completed && history.tasks[3].completedAt == nil && !history.canUndo, "one undo restores open task without a phantom idempotent completion step")
        expect(history.setUserCompletion(id: openHistoryID, completed: true), "user can complete after undo")
        let secondCompletion = history.tasks[3].completedAt!
        expect(secondCompletion > firstCompletion, "recompletion records a fresh action timestamp")
        expect(history.setUserCompletion(id: openHistoryID, completed: false) && history.tasks[3].completedAt == nil, "reopening clears user completion timestamp")
        expect(!history.completedHistory.contains { $0.id == openHistoryID }, "reopened task leaves completion history")
        expect(history.undo() && history.tasks[3].completedAt == secondCompletion && history.tasks[3].completed, "undo reopen restores exact completion time")
        expect(history.addSession(provider: .codex, title: "History evidence session", url: "https://example.com/history-session"), "history scenario adds local session")
        let historySessionID = history.sessions[0].id
        expect(history.linkTask(id: openHistoryID, sessionID: historySessionID), "completed task can link a session explicitly")
        let historyEvidence = AgentCompletion(sessionID: historySessionID, artifactURL: "https://example.com/history-result", summary: "Reviewed artifact", observedAt: now.addingTimeInterval(-1), reviewedAt: now)
        expect(history.recordAgentCompletion(historyEvidence, taskID: openHistoryID) && history.tasks[3].completedAt == secondCompletion, "recording agent evidence does not alter user completion time")
        expect(history.clearAgentCompletion(taskID: openHistoryID) && history.tasks[3].completedAt == secondCompletion, "clearing agent evidence does not alter user completion time")
        expect(history.undo() && history.tasks[3].agentCompletion == historyEvidence && history.tasks[3].completedAt == secondCompletion, "agent evidence undo also preserves user completion timestamp")
        expect(history.setTaskHorizon(id: openHistoryID, horizon: .longerTerm) && history.tasks[3].completedAt == secondCompletion && history.tasks[3].createdAt == historyTasks[3].createdAt && history.tasks[3].lane == .waiting, "group changes preserve completion date, creation date, and legacy lane")
        let historyReload = AppStore(directory: historyDirectory)
        expect(historyReload.completedHistory.map(\.id) == history.completedHistory.map(\.id), "history order persists across restart")
        expect(abs(historyReload.tasks[3].completedAt!.timeIntervalSince(secondCompletion)) < 0.000001, "fractional completion timestamp survives persistence to microsecond precision")
        expect(historyReload.tasks[3].agentCompletion == historyEvidence && historyReload.tasks[0].completedAt == nil, "restart preserves evidence and unknown legacy completion dates")
        let invalidOpenTimestamp = TaskItem(title: "Open with impossible completion date", completedAt: Date(timeIntervalSince1970: 100))
        let invalidOpenTimestampRejected = try rejectsSnapshot(BistSnapshot(tasks: [invalidOpenTimestamp]), "invalid-open-completion-time")
        expect(invalidOpenTimestampRejected, "persisted open task cannot carry a completion timestamp")
        // Outliner moves are atomic and carry descendants, never unrelated siblings.
        let moving = AppStore(directory: root.appendingPathComponent("moving"))
        expect(moving.addTask(title: "A") && moving.addTask(title: "B") && moving.addTask(title: "C", horizon: .longerTerm), "move fixtures added")
        let a = moving.tasks[0].id, b = moving.tasks[1].id, c = moving.tasks[2].id
        expect(moving.addTask(title: "A child", parentID: a), "move child added")
        let child = moving.tasks.last!.id
        expect(moving.addTask(title: "Grandchild", parentID: child), "move grandchild added")
        let grandchild = moving.tasks.last!.id
        let originalTree = moving.tasks
        expect(moving.moveTask(id: child, to: .list(.longerTerm)), "child can move independently to another list")
        expect(moving.tasks.first { $0.id == child }?.parentID == nil, "list drop promotes dragged child")
        expect(moving.tasks.first { $0.id == grandchild }?.horizon == .longerTerm, "descendant follows moved child")
        expect(moving.tasks.first { $0.id == a }?.horizon == .shortTerm, "old parent stays in its own list")
        expect(moving.undo() && moving.tasks == originalTree, "entire subtree move has one exact undo")
        expect(moving.moveTask(id: a, to: .inside(c)), "cross-list nesting succeeds")
        expect(moving.tasks.filter { [a, child, grandchild].contains($0.id) }.allSatisfy { $0.horizon == .longerTerm }, "nested subtree inherits destination list")
        let nestedTree = moving.tasks
        expect(!moving.canMoveTask(id: c, to: .inside(grandchild)), "descendant nesting disabled")
        expect(!moving.moveTask(id: c, to: .before(child)) && moving.tasks == nestedTree, "cycle through sibling destination rejected without mutation")
        expect(!moving.moveTask(id: a, to: .inside(a)), "self drop rejected")
        expect(!moving.moveTask(id: a, to: .before(UUID())), "missing destination rejected")
        expect(moving.moveTask(id: a, to: .before(b)), "row edge moves subtree to target siblings")
        expect(moving.tasks.first { $0.id == a }?.parentID == nil, "sibling move uses destination parent")
        expect(moving.tasks.firstIndex { $0.id == a }! < moving.tasks.firstIndex { $0.id == b }!, "before drop preserves intended order")
        expect(moving.moveTask(id: b, to: .after(a)), "after drop succeeds")
        let afterTree = moving.tasks
        let movedReload = AppStore(directory: moving.directory)
        expect(movedReload.tasks.map(\.id) == afterTree.map(\.id) && zip(movedReload.tasks, afterTree).allSatisfy { $0.parentID == $1.parentID && $0.horizon == $1.horizon }, "move persists order and hierarchy")
        expect(moving.deleteTask(id: a), "delete parent succeeds")
        expect(moving.tasks.contains { $0.id == child && $0.parentID == nil }, "default delete preserves and promotes children")
        expect(moving.tasks.contains { $0.id == grandchild && $0.parentID == child }, "delete preserves deeper hierarchy")
        expect(moving.undo() && moving.tasks == afterTree, "delete restores tree and exact order with undo")
        expect(moving.deleteTask(id: a, includingSubtasks: true), "explicit subtree deletion succeeds")
        expect(!moving.tasks.contains { [a, child, grandchild].contains($0.id) }, "subtree deletion removes exactly the selected tree")
        expect(moving.tasks.contains { $0.id == b } && moving.tasks.contains { $0.id == c }, "subtree deletion retains other tasks")
        expect(moving.undo() && moving.tasks == afterTree, "subtree deletion has one undo")
        let failureMover = AppStore(directory: root.appendingPathComponent("move-write-failure"))
        expect(failureMover.addTask(title: "Retained A") && failureMover.addTask(title: "Retained B"), "write failure fixture added")
        let failureBefore = failureMover.tasks
        try FileManager.default.removeItem(at: failureMover.stateURL)
        try FileManager.default.createDirectory(at: failureMover.stateURL, withIntermediateDirectories: false)
        expect(!failureMover.moveTask(id: failureBefore[0].id, to: .inside(failureBefore[1].id)) && failureMover.tasks == failureBefore, "failed move persistence leaves memory unchanged")
        expect(!failureMover.deleteTask(id: failureBefore[0].id) && failureMover.tasks == failureBefore, "failed delete persistence leaves memory unchanged")

        print("PASS: \(checks) core checks")
    }
}
