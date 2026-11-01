import Foundation
import Combine
import Darwin

/// A single local scratchpad, independent of task snapshots and task Undo.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var error: String?
    @Published private(set) var canRetrySave = false
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("note.txt") }
    private var savedBytes: Data?
    private var unreadable = false
    private let prepareForWrite: (() -> Bool)?
    private var replicaExportBytes: Data?
    var persistText: ((String) throws -> Void)?
    /// Called after a physical export succeeds, never merely after canonical
    /// storage accepts an edit. The bridge records its compatibility baseline.
    var didExportText: ((Data) -> Void)?
    var exportBaselineBytes: Data? { replicaExportBytes }
    var isReadable: Bool { !unreadable }
    var hasUnsavedDraft: Bool { Data(text.utf8) != (savedBytes ?? Data()) }

    init(directory: URL, prepareForWrite: (() -> Bool)? = nil) {
        self.directory = directory
        self.prepareForWrite = prepareForWrite
        do {
            let bytes = try readBytes()
            replicaExportBytes = bytes
            let decoded = try decode(bytes)
            savedBytes = bytes
            text = decoded ?? ""
        } catch {
            unreadable = true
            self.error = "Couldn’t open note.txt. The original is preserved. Repair the file, then reload saved data."
        }
    }

    /// Read a valid external version without changing the editor or the saved
    /// baseline. The bridge imports it before projecting a canonical note.
    func readableDiskText() throws -> String? { try decode(readBytes()) }

    /// Repair can re-open the note without restarting the task store. An
    /// unsaved editor draft always stays under the person's control.
    @discardableResult
    func recoverFromDisk(expectedText: String? = nil) -> Bool {
        do {
            let bytes = try readBytes()
            let decoded = try decode(bytes)
            if let expectedText, decoded != expectedText {
                canRetrySave = false
                error = "The saved note changed again while reloading. Your text and that file are preserved. Retry reload."
                return false
            }
            guard !hasUnsavedDraft else {
                canRetrySave = false
                error = "Your unsaved note is still here. Copy it before loading the saved version."
                return false
            }
            savedBytes = bytes; replicaExportBytes = bytes; text = decoded ?? ""
            unreadable = false; error = nil; canRetrySave = false
            return true
        } catch {
            unreadable = true; canRetrySave = false
            self.error = "Couldn’t open note.txt. Your text and the original file are preserved. Repair the file, then reload saved data."
            return false
        }
    }

    func update(_ value: String) {
        text = value
        save()
    }

    /// Save synchronously so switching tabs, collapsing, or quitting cannot drop a pending edit.
    func save() {
        guard !unreadable else { return }
        do {
            if let prepareForWrite {
                guard prepareForWrite() else { throw CocoaError(.fileWriteUnknown) }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let descriptor = open(directory.appendingPathComponent(".note.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(descriptor, LOCK_UN) }
            guard try readBytes() == replicaExportBytes else {
                canRetrySave = false
                error = "The saved note changed elsewhere. Copy your text before reopening bist to load that version."
                return
            }
            let bytes = Data(text.utf8)
            if bytes != savedBytes {
                if let persistText {
                    try persistText(text)
                    // Canonical acceptance survives a failed compatibility
                    // export. A later save can retry the same physical bytes.
                    savedBytes = bytes
                    do { try export(bytes) } catch {}
                } else {
                    try export(bytes)
                    savedBytes = bytes
                }
            } else if bytes != replicaExportBytes {
                // Repair a stale export even when no further text was typed.
                try export(bytes)
            }
            error = nil
            canRetrySave = false
        } catch {
            canRetrySave = true
            self.error = "Couldn’t save the note. Your text is still here. Check the data folder and retry."
        }
    }

    /// Note export failures never turn a successful task sync into a task
    /// failure. The incoming note remains in canonical storage for recovery.
    func reportReplicaFailure(_ failure: Error) {
        guard !unreadable else { return }
        error = "Couldn’t update the saved note. Your current text and the saved file are preserved. Check note.txt, then reload saved data."
        canRetrySave = false
    }

    /// Never replace an unsaved local draft or an external file when a remote
    /// note arrives. These are note-only errors and leave task editing usable.
    @discardableResult
    func applyReplicaText(_ value: String) throws -> Bool {
        guard !unreadable, !hasUnsavedDraft else { return false }
        do {
            if let prepareForWrite {
                guard prepareForWrite() else { throw CocoaError(.fileWriteUnknown) }
            } else {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let descriptor = open(directory.appendingPathComponent(".note.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(descriptor, LOCK_UN) }
            let bytes = Data(value.utf8)
            guard try readBytes() == replicaExportBytes else {
                canRetrySave = false
                error = "The saved note changed elsewhere. Your text and that file are preserved. Reload saved data to import it."
                return false
            }
            if bytes != replicaExportBytes {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try export(bytes)
            }
            savedBytes = bytes; text = value; error = nil; canRetrySave = false
            return true
        } catch {
            reportReplicaFailure(error)
            return false
        }
    }

    private func export(_ bytes: Data) throws {
        try bytes.write(to: fileURL, options: .atomic)
        replicaExportBytes = bytes
        didExportText?(bytes)
    }

    private func decode(_ bytes: Data?) throws -> String? {
        guard let bytes else { return nil }
        guard let decoded = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return decoded
    }

    private func readBytes() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
