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

    init(directory: URL, prepareForWrite: (() -> Bool)? = nil) {
        self.directory = directory
        self.prepareForWrite = prepareForWrite
        do {
            savedBytes = try readBytes()
            if let savedBytes {
                guard let decoded = String(data: savedBytes, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text = decoded
            }
        } catch {
            unreadable = true
            self.error = "Couldn’t open note.txt. The original is preserved. Check the file and reopen bist."
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
            // Respect the shared migration gate before any auxiliary file can
            // publish an empty destination that would hide the legacy store.
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
            guard try readBytes() == savedBytes else {
                canRetrySave = false
                error = "The saved note changed elsewhere. Copy your text before reopening bist to load that version."
                return
            }
            let bytes = Data(text.utf8)
            if bytes != savedBytes {
                try bytes.write(to: fileURL, options: .atomic)
                savedBytes = bytes
            }
            error = nil
            canRetrySave = false
        } catch {
            canRetrySave = true
            self.error = "Couldn’t save the note. Your text is still here. Check the data folder and retry."
        }
    }

    private func readBytes() throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}
