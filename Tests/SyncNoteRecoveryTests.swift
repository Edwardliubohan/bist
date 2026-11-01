import Foundation

@main
struct SyncNoteRecoveryTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bist-sync-note-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? fm.removeItem(at: root)
        }
        let store = AppStore(directory: root)
        let note = NoteStore(directory: root)
        note.update("initial")
        let bridge = try BistReplicaBridge(store: store, note: note)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        note.update("accepted while export blocked")
        precondition(note.error == nil, "Canonical note save succeeds even if its compatibility export fails")
        note.update("second accepted edit")
        precondition(note.error == nil, "A failed compatibility export must not become a false stale-writer conflict")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let restoredStore = AppStore(directory: root)
        let restoredNote = NoteStore(directory: root)
        let reopened = try BistReplicaBridge(store: restoredStore, note: restoredNote)
        precondition(restoredNote.text == "second accepted edit", "Restart restores the accepted SQLite note")
        let pending = try reopened.database.pendingRecords()
        let originalPending = try bridge.database.pendingRecords()
        precondition(pending == originalPending)
        try reopened.receiveDeletions(["note.main"])
        precondition(restoredNote.text.isEmpty, "A hard cloud note deletion clears the singleton note")
        let versions = try reopened.noteVersions()
        precondition(versions.contains("second accepted edit"), "Cloud-deleted text remains recoverable")
        let finalStore = AppStore(directory: root)
        let finalNote = NoteStore(directory: root)
        let finalBridge = try BistReplicaBridge(store: finalStore, note: finalNote)
        precondition(finalStore.addTask(title: "Still editable"), "Hard-deleted note must not poison the canonical database")
        _ = finalBridge
        print("PASS canonical note export recovery, cloud deletion and restart")
    }
}
