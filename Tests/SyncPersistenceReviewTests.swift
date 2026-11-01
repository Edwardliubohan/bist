import Foundation
import Darwin

@main
struct SyncPersistenceReviewTests {
    struct InjectedFailure: Error {}

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-persistence-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        let directory = root.appendingPathComponent("authority")
        let store = AppStore(directory: directory)
        expect(store.addTask(title: "Canonical task"), "seed canonical task")
        let canonical = store.currentSnapshot
        store.reloadPersistedSnapshot = { try store.applyReplicaSnapshot(canonical) }
        try FileManager.default.removeItem(at: store.stateURL)
        expect(store.reload(), "canonical reload succeeds without the compatibility export")
        expect(store.tasks.map(\.title) == ["Canonical task"], "missing JSON cannot erase canonical tasks")
        let stale = BistSnapshot(tasks: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { try BistDateCoding.encode($0, to: $1) }
        try encoder.encode(stale).write(to: store.stateURL)
        expect(store.reload(), "canonical reload ignores a stale compatibility export")
        expect(store.tasks.map(\.title) == ["Canonical task"], "stale JSON cannot replace authoritative data")
        store.reloadPersistedSnapshot = { throw InjectedFailure() }
        expect(!store.reload() && store.storeError != nil, "authoritative reload failure stays visible")
        expect(store.tasks.map(\.title) == ["Canonical task"], "failed reload retains the current view")
        store.reloadPersistedSnapshot = { try store.applyReplicaSnapshot(canonical) }
        expect(store.reload() && store.addTask(title: "Recovered"), "retry clears the write gate after authoritative recovery")

        let legacyDirectory = root.appendingPathComponent("legacy-repair")
        let seed = AppStore(directory: legacyDirectory)
        expect(seed.addTask(title: "Original"), "seed legacy repair")
        let goodBytes = try Data(contentsOf: seed.stateURL)
        try Data("{broken".utf8).write(to: seed.stateURL)
        let repair = AppStore(directory: legacyDirectory)
        expect(repair.storeError != nil, "broken bootstrap is reported")
        repair.reloadPersistedSnapshot = {
            guard repair.reloadLegacySnapshot() else { throw InjectedFailure() }
        }
        try goodBytes.write(to: repair.stateURL)
        expect(repair.reload() && repair.addTask(title: "After repair"), "bootstrap repair remains possible with a recovery callback")

        let proposalDirectory = root.appendingPathComponent("proposals")
        let proposals = AppStore(directory: proposalDirectory)
        let proposalNote = NoteStore(directory: proposalDirectory)
        let proposalBridge = try BistReplicaBridge(store: proposals, note: proposalNote)
        let id = UUID()
        let proposal = TaskProposal(id: id, title: "Reviewed proposal", nextAction: "Read", source: "Local", createdAt: Date())
        expect(proposals.importProposals([proposal]), "initial reviewed proposal import")
        expect(proposals.deleteTask(id: id), "delete reviewed proposal")
        expect(proposals.importProposals([proposal]), "explicit reviewed reimport restores a tombstone")
        expect(proposals.tasks.contains { $0.id == id }, "restored proposal is visible")
        let restored = try proposalBridge.database.records().filter { $0.id == "task." + id.uuidString.lowercased() }
        expect(restored.count == 1 && !restored[0].isDeleted, "reviewed reimport is durable in canonical storage")

        let noteDirectory = root.appendingPathComponent("note-repair")
        try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
        let noteURL = noteDirectory.appendingPathComponent("note.txt")
        let invalid = Data([0xff, 0xfe, 0x00])
        try invalid.write(to: noteURL)
        let note = NoteStore(directory: noteDirectory)
        expect(!note.isReadable && note.error != nil, "invalid UTF-8 is a note-only load error")
        expect(try Data(contentsOf: noteURL) == invalid, "invalid note bytes are preserved")
        try Data("Repaired text".utf8).write(to: noteURL)
        expect(note.recoverFromDisk(), "repaired note can be reloaded without relaunch")
        expect(note.isReadable && note.text == "Repaired text" && note.error == nil, "note recovery clears only the note gate")
        try Data("External edit".utf8).write(to: noteURL)
        note.update("Unsaved local draft")
        expect(note.hasUnsavedDraft && note.error != nil, "stale writer retains its draft")
        expect(try note.readableDiskText() == "External edit", "external note remains available for import")
        expect(!note.recoverFromDisk(), "reloading refuses to discard an unsaved local draft")
        expect(note.text == "Unsaved local draft", "draft survives note recovery attempt")
        expect(try Data(contentsOf: noteURL) == Data("External edit".utf8), "recovery never overwrites the external file")

        let changingNote = NoteStore(directory: noteDirectory)
        try Data("Another external edit".utf8).write(to: noteURL)
        expect(!changingNote.recoverFromDisk(expectedText: "External edit"), "recovery refuses to adopt a different external snapshot")
        expect(changingNote.exportBaselineBytes == Data("External edit".utf8), "changed-again snapshot never advances the physical baseline")
        try Data("External edit".utf8).write(to: noteURL)

        let lockedNote = NoteStore(directory: noteDirectory)
        let descriptor = open(noteDirectory.appendingPathComponent(".note.lock").path, O_CREAT | O_RDWR, 0o600)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let busyProjection = try lockedNote.applyReplicaText("Remote text during a local write")
        flock(descriptor, LOCK_UN); close(descriptor)
        expect(!busyProjection && lockedNote.error != nil, "remote projection respects a busy note writer")
        expect(try Data(contentsOf: noteURL) == Data("External edit".utf8), "busy projection leaves the physical note unchanged")

        let exportDirectory = root.appendingPathComponent("note-export")
        let exportStore = AppStore(directory: exportDirectory)
        let exportedNote = NoteStore(directory: exportDirectory)
        exportedNote.update("Before export failure")
        let exportBridge = try BistReplicaBridge(store: exportStore, note: exportedNote)
        var observedExports: [Data] = []
        let priorObserver = exportedNote.didExportText
        exportedNote.didExportText = { bytes in priorObserver?(bytes); observedExports.append(bytes) }
        let persist = exportedNote.persistText
        exportedNote.persistText = { text in
            try persist?(text)
            guard chmod(exportDirectory.path, 0o500) == 0 else { throw InjectedFailure() }
        }
        defer { _ = chmod(exportDirectory.path, 0o700) }
        exportedNote.update("Accepted canonical note")
        expect(observedExports.isEmpty, "failed physical export cannot announce successful export")
        expect(try String(contentsOf: exportedNote.fileURL, encoding: .utf8) == "Before export failure", "failed physical export preserves previous file")
        let canonicalNote = try exportBridge.database.records().first { $0.id == "note.main" }!.fields["text"]!.value
        expect(try JSONDecoder().decode(String.self, from: canonicalNote) == "Accepted canonical note", "canonical note survives failed compatibility export")
        expect(exportedNote.exportBaselineBytes == Data("Before export failure".utf8), "physical export baseline advances only after successful write")
        _ = chmod(exportDirectory.path, 0o700)
        exportedNote.persistText = persist
        // Resetting a callback must retain the physical baseline after failure.
        exportedNote.save()
        expect(try String(contentsOf: exportedNote.fileURL, encoding: .utf8) == "Accepted canonical note", "retry repairs export without another text edit")
        expect(observedExports == [Data("Accepted canonical note".utf8)], "successful retry announces exact physical bytes once")
        let coordinatorDirectory = root.appendingPathComponent("coordinator-repair")
        let coordinatorSeed = AppStore(directory: coordinatorDirectory)
        expect(coordinatorSeed.addTask(title: "Before malformed export"), "seed coordinator recovery")
        let goodCoordinatorBytes = try Data(contentsOf: coordinatorSeed.stateURL)
        try Data("{broken".utf8).write(to: coordinatorSeed.stateURL)
        let coordinatorStore = AppStore(directory: coordinatorDirectory)
        let coordinatorNote = NoteStore(directory: coordinatorDirectory)
        let coordinator = BistSyncCoordinator(store: coordinatorStore, note: coordinatorNote)
        expect(coordinatorStore.storeError != nil, "coordinator preserves bootstrap failure")
        try goodCoordinatorBytes.write(to: coordinatorStore.stateURL)
        expect(coordinatorStore.reload() && coordinatorStore.addTask(title: "After bootstrap retry"), "coordinator retries repaired storage without relaunch")
        expect(coordinator.error == nil, "successful storage retry clears coordinator error")

        let invalidNoteDirectory = root.appendingPathComponent("coordinator-invalid-note")
        let invalidNoteStore = AppStore(directory: invalidNoteDirectory)
        expect(invalidNoteStore.addTask(title: "Usable task"), "seed task with invalid scratchpad")
        try invalid.write(to: invalidNoteDirectory.appendingPathComponent("note.txt"))
        let invalidNote = NoteStore(directory: invalidNoteDirectory)
        let invalidNoteCoordinator = BistSyncCoordinator(store: invalidNoteStore, note: invalidNote)
        expect(invalidNote.error != nil && invalidNoteStore.addTask(title: "Tasks still work"), "invalid UTF-8 never blocks task editing")
        let invalidNoteDatabase = try ReplicaDatabase(directory: invalidNoteDirectory.appendingPathComponent("sync"))
        expect(try !invalidNoteDatabase.records().contains { $0.kind == "note" }, "unreadable note never publishes an empty record")
        try Data("Repaired independent note".utf8).write(to: invalidNote.fileURL)
        expect(invalidNoteStore.reload() && invalidNote.text == "Repaired independent note", "task reload can retry the repaired note")
        expect(invalidNote.error == nil && invalidNoteCoordinator.error == nil, "note repair clears independent errors")

        let externalDirectory = root.appendingPathComponent("external-between-launches")
        let externalStore = AppStore(directory: externalDirectory)
        let originalNote = NoteStore(directory: externalDirectory)
        originalNote.update("Earlier canonical note")
        let originalBridge = try BistReplicaBridge(store: externalStore, note: originalNote)
        try Data("Changed in TextEdit".utf8).write(to: originalNote.fileURL)
        let relaunchedStore = AppStore(directory: externalDirectory)
        let relaunchedNote = NoteStore(directory: externalDirectory)
        let relaunchedBridge = try BistReplicaBridge(store: relaunchedStore, note: relaunchedNote)
        expect(relaunchedNote.text == "Changed in TextEdit", "valid external note becomes canonical on next launch")
        expect(try String(contentsOf: relaunchedNote.fileURL, encoding: .utf8) == "Changed in TextEdit", "launch never replaces external note with older replica text")
        let externalCanonical = try relaunchedBridge.database.records().first { $0.id == "note.main" }!.fields["text"]!.value
        expect(try JSONDecoder().decode(String.self, from: externalCanonical) == "Changed in TextEdit", "external edit is durably imported")
        expect(try relaunchedBridge.noteVersions().contains("Earlier canonical note"), "import retains the earlier canonical note for recovery")
        _ = originalBridge

        print("PASS: \(checks) authoritative reload, proposal and note recovery checks")
    }
}
