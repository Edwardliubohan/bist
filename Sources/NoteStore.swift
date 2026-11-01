import Foundation
import Combine
import Darwin

/// A single local scratchpad, independent of task snapshots and task Undo.
@MainActor
final class NoteStore: ObservableObject {
    private enum ReplicaFailure {
        case file(String)
        case draft
        var message: String {
            switch self {
            case .file(let value): return value
            case .draft: return "Your unsaved note is still here. Copy it before loading the saved version."
            }
        }
    }
    struct DiskSnapshot {
        let bytes: Data?
        let text: String?
        fileprivate let textBytes: Data?
        fileprivate init(bytes: Data?, text: String?) {
            self.bytes = bytes; self.text = text
            textBytes = text.map { Data($0.utf8) }
        }
    }
    @Published private(set) var text = ""
    @Published private(set) var error: String?
    @Published private(set) var canRetrySave = false
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("note.txt") }
    private var savedBytes: Data?
    private var unreadable = false
    private let prepareForWrite: (() -> Bool)?
    private var replicaExportBytes: Data?
    private var replicaExportTextBytes: Data?
    private var replicaFailure: ReplicaFailure?
    var persistText: ((String) throws -> Void)?
    /// Called after a physical export succeeds, never merely after canonical
    /// storage accepts an edit. The bridge records its compatibility baseline.
    var didExportText: ((Data) -> Void)?
    var exportBaselineBytes: Data? { replicaExportBytes }
    var isReadable: Bool { !unreadable }
    var hasUnsavedDraft: Bool { Data(text.utf8) != (savedBytes ?? Data()) }

    private func matchesExportedText(_ bytes: Data?) -> Bool {
        // A BOM may be an encoding marker or literal canonical text. Either
        // exact representation can already be on disk without needing a write.
        bytes == replicaExportTextBytes || bytes == replicaExportBytes
    }

    init(directory: URL, prepareForWrite: (() -> Bool)? = nil) {
        self.directory = directory
        self.prepareForWrite = prepareForWrite
        do {
            let bytes = try readBytes()
            replicaExportBytes = bytes
            let decoded = try decode(bytes)
            savedBytes = decoded.map { Data($0.utf8) }
            replicaExportTextBytes = savedBytes
            text = decoded ?? ""
        } catch {
            unreadable = true
            self.error = "Couldn’t open note.txt. The original is preserved. Repair the file, then reload saved data."
        }
    }

    /// Read a valid external version without changing the editor or the saved
    /// baseline. The bridge imports it before projecting a canonical note.
    func readableDiskSnapshot() throws -> DiskSnapshot {
        let bytes = try readBytes()
        return DiskSnapshot(bytes: bytes, text: try decode(bytes))
    }
    func readableDiskText() throws -> String? { try readableDiskSnapshot().text }

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
            savedBytes = decoded.map { Data($0.utf8) }
            replicaExportBytes = bytes; replicaExportTextBytes = savedBytes; text = decoded ?? ""
            unreadable = false; error = nil; replicaFailure = nil; canRetrySave = false
            return true
        } catch {
            unreadable = true; canRetrySave = false
            self.error = "Couldn’t open note.txt. Your text and the original file are preserved. Repair the file, then reload saved data."
            return false
        }
    }

    /// The bridge calls this only after importing this exact snapshot, matching
    /// a proven export, or observing a missing file. Never read different bytes
    /// here. A later export still checks the current file against this snapshot.
    @discardableResult
    func acceptReplicaFile(_ snapshot: DiskSnapshot, preservingAcceptedText: Bool = false) -> Bool {
        guard !hasUnsavedDraft else {
            // Reload must keep a working retry for an unchanged readable file.
            if !unreadable, snapshot.bytes == replicaExportBytes, canRetrySave { return false }
            canRetrySave = false
            replicaFailure = .draft
            error = replicaFailure?.message
            return false
        }
        let keepAcceptedText = preservingAcceptedText && savedBytes != nil && !matchesExportedText(savedBytes)
        replicaExportBytes = snapshot.bytes
        replicaExportTextBytes = snapshot.textBytes
        if !keepAcceptedText { savedBytes = snapshot.textBytes; text = snapshot.text ?? "" }
        unreadable = false; error = nil; replicaFailure = nil; canRetrySave = false
        return true
    }

    func update(_ value: String) {
        text = value
        save()
    }

    /// Save synchronously so switching tabs, collapsing, or quitting cannot drop a pending edit.
    func save() {
        guard !unreadable else { return }
        // An idle save neither accepts a rejected import nor creates a default
        // empty cloud note. Keep its error until content changes or recovery.
        if !hasUnsavedDraft && matchesExportedText(savedBytes) {
            if case .draft? = replicaFailure {
                do {
                    let changed = try readBytes() != replicaExportBytes
                    let message = changed ? "The saved note changed elsewhere. Choose Reload saved data in Settings to load it." : nil
                    replicaFailure = message.map(ReplicaFailure.file)
                    error = message
                    canRetrySave = false
                } catch { reportReplicaFailure(error) }
            } else if canRetrySave {
                error = replicaFailure?.message
                canRetrySave = false
            }
            return
        }
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
            } else if !matchesExportedText(bytes) {
                // Repair a stale export even when no further text was typed.
                try export(bytes)
            }
            error = nil
            replicaFailure = nil
            canRetrySave = false
        } catch {
            canRetrySave = true
            self.error = "Couldn’t save the note. Your text is still here. Check the data folder and retry."
        }
    }

    /// Note export failures never turn a successful task sync into a task
    /// failure. The incoming note remains in canonical storage for recovery.
    func reportReplicaFailure(_ failure: Error, exceedsSyncLimit: Bool = false) {
        let message: String
        if exceedsSyncLimit {
            message = "This note exceeds the 16 MiB sync limit after encoding. Line breaks and special characters can count as extra bytes. Your text and file are preserved. Shorten note.txt, then choose Reload saved data in Settings."
        } else if (failure as? CocoaError)?.code == .fileReadInapplicableStringEncoding {
            message = "Couldn’t read note.txt as UTF-8. Your text and file are preserved. Repair the file, then choose Reload saved data in Settings."
        } else {
            message = "Couldn’t update the saved note. Your current text and the saved file are preserved. Check note.txt, then choose Reload saved data in Settings."
        }
        replicaFailure = .file(message)
        error = message
        canRetrySave = false
    }

    /// Never replace an unsaved local draft or an external file when a remote
    /// note arrives. These are note-only errors and leave task editing usable.
    @discardableResult
    func applyReplicaText(_ value: String) throws -> Bool {
        guard !unreadable, !hasUnsavedDraft else { return false }
        // This text is already accepted by SQLite. Keep it visible and ready
        // to retry even when the physical export or its lock cannot be written.
        let bytes = Data(value.utf8)
        savedBytes = bytes
        text = value
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
                error = "The saved note changed elsewhere. Your text and that file are preserved. Reload saved data to import it."
                return false
            }
            if !matchesExportedText(bytes) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try export(bytes)
            }
            error = nil; replicaFailure = nil; canRetrySave = false
            return true
        } catch {
            reportReplicaFailure(error)
            return false
        }
    }

    private func export(_ bytes: Data) throws {
        try bytes.write(to: fileURL, options: .atomic)
        replicaExportBytes = bytes
        replicaExportTextBytes = bytes
        didExportText?(bytes)
    }

    private func decode(_ bytes: Data?) throws -> String? {
        guard let bytes else { return nil }
        // Pin BOM handling independently of Foundation's decoder. Strip one
        // encoding marker and use Swift's codec with a lossless check.
        let payload = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? bytes.dropFirst(3) : bytes
        let decoded = String(decoding: payload, as: UTF8.self)
        guard payload.elementsEqual(decoded.utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return decoded
    }

    private func readBytes() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
