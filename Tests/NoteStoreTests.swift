import Foundation
import Darwin

@main
struct NoteStoreTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-note-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        let note = NoteStore(directory: root)
        expect(note.text.isEmpty && note.error == nil, "existing task stores need no note migration")
        expect(!FileManager.default.fileExists(atPath: note.fileURL.path), "opening does not create a note")
        let content = "  A little space to think\n\n中文 — café 📝\n"
        note.update(content)
        expect(note.error == nil, "first edit saves")
        expect(NoteStore(directory: root).text == content, "whitespace and Unicode persist across launch")
        let stale = NoteStore(directory: root)
        note.update("newer note")
        stale.update("keep my unsaved draft")
        expect(stale.error != nil && stale.text == "keep my unsaved draft", "stale save retains draft and reports conflict")
        expect(!stale.canRetrySave, "conflict directs recovery through copy and reopen")
        expect(NoteStore(directory: root).text == "newer note", "stale save does not overwrite another writer")
        note.update("")
        expect(NoteStore(directory: root).text.isEmpty && note.error == nil, "clearing the note persists")
        let long = String(repeating: "A long note with multiple lines.\n", count: 5000)
        note.update(long)
        expect(NoteStore(directory: root).text == long, "long notes persist without truncation")
        // A task operation and its Undo cannot restore an older note.
        let tasks = AppStore(directory: root)
        expect(tasks.addTask(title: "Separate task"), "task saved alongside note")
        note.update("independent")
        expect(tasks.undo(), "task undo succeeds")
        expect(NoteStore(directory: root).text == "independent", "task undo preserves note")
        let invalid = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let invalidBytes = Data([0xff, 0xfe, 0xff])
        try invalidBytes.write(to: invalid.appendingPathComponent("note.txt"))
        let unreadable = NoteStore(directory: invalid)
        unreadable.update("cannot replace original")
        expect(unreadable.error != nil, "invalid UTF-8 reports load failure")
        expect(!unreadable.canRetrySave, "unreadable note offers no ineffective retry")
        let preserved = try Data(contentsOf: unreadable.fileURL)
        expect(preserved == invalidBytes, "unreadable original preserved")
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let failing = NoteStore(directory: blocked)
        failing.update("still here")
        expect(failing.error != nil && failing.text == "still here", "failed IO retains editable draft")
        let retryDirectory = root.appendingPathComponent("retry")
        let retry = NoteStore(directory: retryDirectory)
        try Data().write(to: retryDirectory)
        retry.update("retry this")
        expect(retry.error != nil && retry.canRetrySave && retry.text == "retry this", "save error retains text and offers retry")
        try FileManager.default.removeItem(at: retryDirectory)
        retry.save()
        expect(retry.error == nil && NoteStore(directory: retryDirectory).text == "retry this", "retry recovers from transient failure")
        let lock = open(retryDirectory.appendingPathComponent(".note.lock").path, O_RDWR)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { fatalError("Cannot acquire fixture lock") }
        retry.update("busy writer")
        expect(retry.canRetrySave && retry.text == "busy writer", "busy writer fails promptly while retaining text")
        flock(lock, LOCK_UN)
        close(lock)
        retry.save()
        expect(retry.error == nil && NoteStore(directory: retryDirectory).text == "busy writer", "retry recovers after writer releases lock")
        let badLegacy = root.appendingPathComponent("bad-legacy")
        try Data("not a folder".utf8).write(to: badLegacy)
        let destination = root.appendingPathComponent("migration-destination")
        let migrating = AppStore(directory: destination, legacyDirectory: badLegacy)
        let gatedNote = NoteStore(directory: destination, prepareForWrite: migrating.prepareForAuxiliaryWrite)
        gatedNote.update("keep this draft")
        expect(gatedNote.error != nil && gatedNote.text == "keep this draft", "migration failure retains note draft")
        expect(!FileManager.default.fileExists(atPath: destination.path), "note cannot create destination after failed migration")
        try FileManager.default.removeItem(at: badLegacy)
        try FileManager.default.createDirectory(at: badLegacy, withIntermediateDirectories: true)
        expect(migrating.reload(), "migration can recover after repair")
        gatedNote.save()
        expect(gatedNote.error == nil && NoteStore(directory: destination).text == "keep this draft", "note saves after migration recovery")
        print("PASS: \(checks) note store checks")
    }
}
