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
        print("PASS: \(checks) core checks")
    }
}
