import Foundation

@main
struct SyncReviewTests {
    struct Failure: Error { let messages: [String] }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-review-regression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) { checks += 1; if !condition { failures.append(name) } }
        func make(_ name: String) throws -> (AppStore, NoteStore, BistReplicaBridge) {
            let store = AppStore(directory: root.appendingPathComponent(name))
            let note = NoteStore(directory: store.directory)
            return (store, note, try BistReplicaBridge(store: store, note: note))
        }
        let (a, _, ab) = try make("hierarchy-a")
        for title in ["X", "Y", "Z"] { precondition(a.addTask(title: title)) }
        let (b, _, bb) = try make("hierarchy-b")
        try bb.receive(ab.database.records())
        let (x, y, z) = (a.tasks[0].id, a.tasks[1].id, a.tasks[2].id)
        precondition(b.reparentTask(id: z, parentID: y))
        precondition(a.deleteTask(id: x))
        let ar = try ab.database.records(), br = try bb.database.records()
        try ab.receive(br); try bb.receive(ar)
        check(a.tasks.first { $0.id == z }?.parentID == y, "deleting unrelated row preserves concurrent nesting on Mac")
        check(b.tasks.first { $0.id == z }?.parentID == y, "deleting unrelated row preserves concurrent nesting on phone")
        for index in 0..<12 {
            let directory = root.appendingPathComponent("seed-owner-\(index)")
            let owner = AppStore(directory: directory)
            let school = owner.labels.first { $0.name == "School" }!.id
            let koan = owner.labels.first { $0.name == "Koan" }!.id
            precondition(owner.updateLabel(id: school, name: "University", color: .rose))
            precondition(owner.deleteLabel(id: koan))
            let ownerBridge = try BistReplicaBridge(store: owner, note: NoteStore(directory: directory))
            let (phone, _, phoneBridge) = try make("seed-phone-\(index)")
            let ownerRecords = try ownerBridge.database.records(), phoneRecords = try phoneBridge.database.records()
            try ownerBridge.receive(phoneRecords); try phoneBridge.receive(ownerRecords)
            check(owner.labels.contains { $0.name == "University" } && phone.labels.contains { $0.name == "University" }, "fresh defaults cannot overwrite renamed label \(index)")
            check(!owner.labels.contains { $0.id == koan } && !phone.labels.contains { $0.id == koan }, "fresh defaults cannot restore deleted label \(index)")
        }
        let orderedDir = root.appendingPathComponent("ordered")
        let ordered = AppStore(directory: orderedDir)
        precondition(ordered.addLabel(name: "Zeta", color: .rose))
        let tagOrder = ordered.labels.map(\.id)
        let selectedOrder = [ordered.labels[2].id, ordered.labels[0].id]
        precondition(ordered.addTask(title: "Ordered labels", labelIDs: selectedOrder))
        let orderedBridge = try BistReplicaBridge(store: ordered, note: NoteStore(directory: orderedDir))
        check(ordered.labels.map(\.id) == tagOrder, "migration preserves label order")
        check(ordered.tasks[0].labelIDs == selectedOrder, "migration preserves assigned tag order")
        let (peer, _, peerBridge) = try make("order-peer")
        try peerBridge.receive(orderedBridge.database.records())
        check(peer.labels.map(\.id) == tagOrder && peer.tasks[0].labelIDs == selectedOrder, "label and assigned tag order syncs")
        let (tagsA, _, tagsABridge) = try make("alias-a")
        let (tagsB, _, tagsBBridge) = try make("alias-b")
        precondition(tagsA.addLabel(name: "Duplicate", color: .blue))
        precondition(tagsB.addLabel(name: "Duplicate", color: .amber))
        let labelsA = try tagsABridge.database.records(), labelsB = try tagsBBridge.database.records()
        try tagsABridge.receive(labelsB); try tagsBBridge.receive(labelsA)
        let canonical = tagsA.labels.first { $0.name == "Duplicate" }!.id
        precondition(tagsA.deleteLabel(id: canonical))
        try tagsABridge.receive([])
        check(tagsA.undo(), "Undo restores merged tag and its deleted aliases")
        let restoredAliases = try tagsABridge.database.records().filter { record in
            record.kind == "label" && !record.isDeleted && record.fields["name"]?.value == Data("\"Duplicate\"".utf8)
        }
        check(restoredAliases.count == 2, "Undo retains alias provenance across an unchanged cloud projection")
        check(tagsA.updateLabel(id: canonical, name: "Renamed duplicate", color: .green), "restored merged tag remains editable")
        try tagsBBridge.receive(tagsABridge.database.records())
        check(tagsB.labels.filter { $0.name == "Renamed duplicate" }.count == 1, "restored merged tag syncs once")
        let (reloadStore, _, reloadBridge) = try make("reload-canonical")
        precondition(reloadStore.addTask(title: "One"))
        let staleJSON = try Data(contentsOf: reloadStore.stateURL)
        precondition(reloadStore.addTask(title: "Two"))
        try FileManager.default.removeItem(at: reloadStore.stateURL)
        check(reloadStore.reload() && reloadStore.tasks.count == 2, "real bridge reload ignores missing JSON")
        precondition(reloadStore.addTask(title: "Three"))
        try staleJSON.write(to: reloadStore.stateURL)
        check(reloadStore.reload() && reloadStore.tasks.count == 3, "real bridge reload ignores stale JSON")
        let tombstones = try reloadBridge.database.records().filter { $0.kind == "task" && $0.isDeleted }
        check(tombstones.isEmpty, "reload never creates tombstones from an export")

        let noteDirectory = root.appendingPathComponent("invalid-note")
        let noteTasks = AppStore(directory: noteDirectory)
        precondition(noteTasks.addTask(title: "Before bad note"))
        let badBytes = Data([0xff, 0xfe, 0x00])
        try badBytes.write(to: noteDirectory.appendingPathComponent("note.txt"))
        let badNote = NoteStore(directory: noteDirectory)
        let badNoteCoordinator = BistSyncCoordinator(store: noteTasks, note: badNote)
        check(noteTasks.addTask(title: "After bad note"), "invalid note never blocks unrelated task writes")
        check(try Data(contentsOf: badNote.fileURL) == badBytes, "invalid note file remains untouched")
        let badNoteDB = try ReplicaDatabase(directory: noteDirectory.appendingPathComponent("sync"))
        check(try !badNoteDB.records().contains { $0.id == "note.main" }, "invalid note never uploads invented empty text")
        _ = badNoteCoordinator

        let repairDirectory = root.appendingPathComponent("bootstrap-repair")
        let repairSeed = AppStore(directory: repairDirectory)
        precondition(repairSeed.addTask(title: "Original"))
        let valid = try Data(contentsOf: repairSeed.stateURL)
        try Data("{broken".utf8).write(to: repairSeed.stateURL)
        let repairStore = AppStore(directory: repairDirectory)
        let repairCoordinator = BistSyncCoordinator(store: repairStore, note: NoteStore(directory: repairDirectory))
        try valid.write(to: repairSeed.stateURL)
        check(repairStore.reload() && repairStore.addTask(title: "After repair"), "coordinator startup failure can recover without relaunch")
        _ = repairCoordinator

        let externalDirectory = root.appendingPathComponent("external-note")
        let externalStore = AppStore(directory: externalDirectory)
        let originalNote = NoteStore(directory: externalDirectory)
        originalNote.update("Canonical original")
        let originalBridge = try BistReplicaBridge(store: externalStore, note: originalNote)
        try Data("External TextEdit version".utf8).write(to: originalNote.fileURL)
        let nextStore = AppStore(directory: externalDirectory)
        let nextNote = NoteStore(directory: externalDirectory)
        let nextBridge = try BistReplicaBridge(store: nextStore, note: nextNote)
        check(nextNote.text == "External TextEdit version", "valid external note is imported on restart")
        check(try nextBridge.noteVersions().contains("Canonical original"), "previous canonical note stays recoverable after external import")
        check(try Data(contentsOf: nextNote.fileURL) == Data("External TextEdit version".utf8), "external note file is never silently overwritten")
        _ = originalBridge
        if !failures.isEmpty { throw Failure(messages: failures) }
        print("PASS \(checks) review hierarchy, seed and label-order regressions")
    }
}
