import Foundation
import Darwin

@main
struct SyncExternalNoteFailureTests {
    struct Failure: Error { let messages: [String] }
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bist-external-note-import-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) { checks += 1; if !value { failures.append(message) } }
        let directory = root.appendingPathComponent("existing")
        let original = AppStore(directory: directory)
        let originalNote = NoteStore(directory: directory)
        originalNote.update("Previous canonical note")
        do {
            let replica = try BistReplicaBridge(store: original, note: originalNote)
            expect(original.addTask(title: "Original task"), "seed existing replica")
            _ = replica
        }
        let large = Data(repeating: 120, count: 16 * 1024 * 1024 + 1)
        try large.write(to: originalNote.fileURL)
        let reopened = AppStore(directory: directory)
        let external = NoteStore(directory: directory)
        let bridge = try BistReplicaBridge(store: reopened, note: external)
        expect(try Data(contentsOf: external.fileURL) == large, "rejected external import never overwrites the original file")
        expect(Data(external.text.utf8) == large && external.error != nil, "external content and actionable error stay in the editor")
        external.save()
        let afterIdleSave = try Data(contentsOf: external.fileURL)
        expect(external.error != nil && afterIdleSave == large,
               "an idle background save preserves the rejected import and its error")
        expect(reopened.addTask(title: "Tasks still work"), "note import rejection never blocks task edits")
        expect(try bridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value == JSONEncoder().encode("Previous canonical note"), "rejected import keeps canonical note intact")

        let peerDirectory = root.appendingPathComponent("peer")
        let peer = AppStore(directory: peerDirectory)
        let peerNote = NoteStore(directory: peerDirectory)
        let peerBridge = try BistReplicaBridge(store: peer, note: peerNote)
        try peerBridge.receive(bridge.database.records())
        peerNote.update("Remote canonical update")
        expect(peer.addTask(title: "Remote task"), "seed incoming task")
        try bridge.receive(peerBridge.database.records())
        expect(reopened.tasks.contains { $0.title == "Remote task" }, "task projection continues while the external note is protected")
        expect(try Data(contentsOf: external.fileURL) == large && Data(external.text.utf8) == large, "later remote note projection cannot replace a rejected external version")
        expect(external.error != nil, "remote projection cannot silently clear the import error")
        expect(reopened.reload(), "task reload succeeds while rejected note remains protected")
        expect(try Data(contentsOf: external.fileURL) == large, "retry of a rejected import still preserves the file")

        try Data("External version repaired".utf8).write(to: external.fileURL)
        expect(reopened.reload() && external.text == "External version repaired" && external.error == nil,
               "a successful import retry clears protection and the note error")
        try peerBridge.receive(bridge.database.records())
        peerNote.update("Remote note after recovery")
        try bridge.receive(peerBridge.database.records())
        expect(external.text == "Remote note after recovery", "note projection resumes after successful recovery")

        let freshDirectory = root.appendingPathComponent("first-migration")
        let fresh = AppStore(directory: freshDirectory)
        expect(fresh.addTask(title: "Legacy task survives"), "seed fresh migration")
        try large.write(to: freshDirectory.appendingPathComponent("note.txt"))
        let freshNote = NoteStore(directory: freshDirectory)
        let freshBridge = try BistReplicaBridge(store: fresh, note: freshNote)
        expect(fresh.addTask(title: "After migration"), "oversized legacy note does not prevent task migration")
        expect(try Data(contentsOf: freshNote.fileURL) == large && freshNote.error != nil, "migration preserves an unimportable legacy note")
        expect(try !freshBridge.database.records().contains { $0.id == "note.main" }, "failed legacy import never invents a synced empty note")
        let blankDirectory = root.appendingPathComponent("blank-device")
        let blankStore = AppStore(directory: blankDirectory)
        let blankNote = NoteStore(directory: blankDirectory)
        let blankBridge = try BistReplicaBridge(store: blankStore, note: blankNote)
        blankNote.save()
        expect(try !blankBridge.database.records().contains { $0.id == "note.main" },
               "an untouched blank device cannot upload a default empty note")
        expect(!fm.fileExists(atPath: blankNote.fileURL.path), "an idle save does not manufacture an empty compatibility file")

        for deleteFile in [false, true] {
            for receiveRemote in [false, true] {
                let repairDirectory = root.appendingPathComponent("repair-\(deleteFile)-\(receiveRemote)")
                let seedStore = AppStore(directory: repairDirectory)
                let seedNote = NoteStore(directory: repairDirectory)
                seedNote.update("Previous canonical note")
                let seedBridge = try BistReplicaBridge(store: seedStore, note: seedNote)
                try large.write(to: seedNote.fileURL)
                let repairStore = AppStore(directory: repairDirectory)
                let repairNote = NoteStore(directory: repairDirectory)
                let repairBridge = try BistReplicaBridge(store: repairStore, note: repairNote)
                if receiveRemote {
                    // Advance the canonical note without touching the file.
                    try peerBridge.receive(seedBridge.database.records())
                    peerNote.update("Remote repair head")
                    try repairBridge.receive(peerBridge.database.records())
                }
                if deleteFile { try fm.removeItem(at: repairNote.fileURL) }
                else { try Data("Previous canonical note".utf8).write(to: repairNote.fileURL) }
                let expected = receiveRemote ? "Remote repair head" : "Previous canonical note"
                expect(repairStore.reload() && repairNote.text == expected && repairNote.error == nil,
                       "restoring or removing a rejected file recovers without relaunch, including an incoming canonical change")
                repairNote.update("Editable after repair")
                expect((try? Data(contentsOf: repairNote.fileURL)) == Data("Editable after repair".utf8) && repairNote.error == nil,
                       "file repair resets the physical baseline so later edits save")
            }
        }
        try fm.removeItem(at: freshNote.fileURL)
        expect(fresh.reload() && freshNote.text.isEmpty && freshNote.error == nil,
               "deleting a rejected first-migration note clears the stale editor and error")

        let retryDirectory = root.appendingPathComponent("idle-retry")
        let retry = NoteStore(directory: retryDirectory)
        retry.update("Saved value")
        let lock = open(retryDirectory.appendingPathComponent(".note.lock").path, O_RDWR)
        guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure(messages: ["fixture lock unavailable"]) }
        retry.update("Failed draft")
        expect(retry.canRetrySave, "a busy writer offers save retry")
        retry.update("Saved value")
        flock(lock, LOCK_UN); close(lock)
        retry.save()
        expect(retry.error == nil && !retry.canRetrySave,
               "reverting a failed edit clears a stale Retry button")

        try large.write(to: external.fileURL)
        let rejectedAgainStore = AppStore(directory: directory)
        let rejectedAgain = NoteStore(directory: directory)
        let rejectedAgainBridge = try BistReplicaBridge(store: rejectedAgainStore, note: rejectedAgain)
        let importError = rejectedAgain.error
        rejectedAgain.update(String(repeating: "x", count: large.count + 1))
        expect(rejectedAgain.canRetrySave, "an oversized replacement fails without replacing the protected file")
        rejectedAgain.update(String(decoding: large, as: UTF8.self))
        rejectedAgain.save()
        expect(rejectedAgain.error == importError && importError != nil && !rejectedAgain.canRetrySave,
               "reverting a failed save restores its unresolved import error instead of clearing it")
        expect(importError?.contains("16 MiB") == true && importError?.contains("Reload saved data") == true,
               "the rejected import names the sync limit and the actual recovery control")
        _ = rejectedAgainBridge

        let escapedDirectory = root.appendingPathComponent("escaped-limit")
        let escapedStore = AppStore(directory: escapedDirectory)
        try fm.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        let escapedBytes = Data(repeating: 10, count: 9 * 1024 * 1024)
        try escapedBytes.write(to: escapedDirectory.appendingPathComponent("note.txt"))
        let escapedNote = NoteStore(directory: escapedDirectory)
        let escapedBridge = try BistReplicaBridge(store: escapedStore, note: escapedNote)
        expect(escapedNote.error?.contains("16 MiB") == true && escapedNote.error?.contains("encoding") == true,
               "the limit explains why escaped text below16MiB can still be rejected")
        expect(try Data(contentsOf: escapedNote.fileURL) == escapedBytes, "encoded-size rejection preserves every external byte")
        _ = escapedBridge

        for hasFile in [false, true] {
            for appendAfterRepair in [false, true] {
                let staleDirectory = root.appendingPathComponent("stale-export-\(hasFile)-\(appendAfterRepair)")
                let staleStore = AppStore(directory: staleDirectory)
                let staleNote = NoteStore(directory: staleDirectory)
                if hasFile { staleNote.update("Old export") }
                let staleBridge = try BistReplicaBridge(store: staleStore, note: staleNote)
                let descriptor = open(staleDirectory.appendingPathComponent(".note.lock").path, O_CREAT | O_RDWR, 0o600)
                guard descriptor >= 0 else { throw Failure(messages: ["fixture note lock unavailable"]) }
                close(descriptor)
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staleDirectory.path)
                defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staleDirectory.path) }
                staleNote.update("New accepted")
                let canonical = try staleBridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value
                let accepted = try JSONEncoder().encode("New accepted")
                expect(staleNote.error == nil && canonical == accepted,
                       "SQLite accepts the note while its export is blocked")
                let oldBytes = hasFile ? Data("Old export".utf8) : nil
                expect((try? Data(contentsOf: staleNote.fileURL)) == oldBytes,
                       "the fixture leaves the physical export stale or missing")
                expect(staleStore.reload() && staleNote.text == "New accepted" && staleNote.error != nil,
                       "reload with a blocked export preserves the accepted editor text")
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staleDirectory.path)
                if appendAfterRepair { staleNote.update(staleNote.text + " plus typing") }
                else { staleNote.save() }
                let expected = appendAfterRepair ? "New accepted plus typing" : "New accepted"
                expect((try? Data(contentsOf: staleNote.fileURL)) == Data(expected.utf8) && staleNote.error == nil,
                       "idle retry and later typing preserve accepted content after export repair")
            }
        }
        for deleteRepairedFile in [false, true] {
            let pendingDirectory = root.appendingPathComponent("protected-pending-export-\(deleteRepairedFile)")
            let seedStore = AppStore(directory: pendingDirectory)
            let seedNote = NoteStore(directory: pendingDirectory)
            seedNote.update("Original export")
            let seedBridge = try BistReplicaBridge(store: seedStore, note: seedNote)
            try large.write(to: seedNote.fileURL)
            let pendingStore = AppStore(directory: pendingDirectory)
            let pendingNote = NoteStore(directory: pendingDirectory)
            let pendingBridge = try BistReplicaBridge(store: pendingStore, note: pendingNote)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pendingDirectory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingDirectory.path) }
            pendingNote.update("Accepted replacement")
            expect(pendingNote.error == nil && pendingNote.text == "Accepted replacement",
                   "an explicit replacement can commit while the rejected-file export is blocked")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingDirectory.path)
            if deleteRepairedFile { try fm.removeItem(at: pendingNote.fileURL) }
            else { try Data("Original export".utf8).write(to: pendingNote.fileURL) }
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pendingDirectory.path)
            expect(pendingStore.reload() && pendingNote.text == "Accepted replacement" && pendingNote.error != nil,
                   "resetting a repaired external baseline cannot rewind an accepted pending export")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingDirectory.path)
            pendingNote.save()
            expect((try? Data(contentsOf: pendingNote.fileURL)) == Data("Accepted replacement".utf8) && pendingNote.error == nil,
                   "idle save exports accepted content after both file repair and export repair")
            _ = seedBridge; _ = pendingBridge
        }
        for invalidUTF8 in [false, true] {
            let transientDirectory = root.appendingPathComponent("blank-rejection-\(invalidUTF8)")
            let transientStore = AppStore(directory: transientDirectory)
            let transientNote = NoteStore(directory: transientDirectory)
            let transientBridge = try BistReplicaBridge(store: transientStore, note: transientNote)
            try (invalidUTF8 ? Data([0xff, 0xfe]) : large).write(to: transientNote.fileURL)
            expect(transientStore.reload() && transientNote.error != nil, "an invalid file added to a blank device is rejected")
            try fm.removeItem(at: transientNote.fileURL)
            expect(transientStore.reload() && transientNote.error == nil && transientNote.text.isEmpty,
                   "removing a newly rejected file clears the blank device's stale error")
            transientNote.save()
            expect(transientNote.error == nil && !fm.fileExists(atPath: transientNote.fileURL.path),
                   "blank recovery stays clear without inventing an empty file")
            expect(try !transientBridge.database.records().contains { $0.id == "note.main" }, "blank recovery never uploads an empty default")
        }
        for hasFile in [false, true] {
            for removeLock in [false, true] {
                let launchDirectory = root.appendingPathComponent("blocked-relaunch-\(hasFile)-\(removeLock)")
                let seedStore = AppStore(directory: launchDirectory)
                let seedNote = NoteStore(directory: launchDirectory)
                if hasFile { seedNote.update("Old launch export") }
                let seedBridge = try BistReplicaBridge(store: seedStore, note: seedNote)
                let lockURL = launchDirectory.appendingPathComponent(".note.lock")
                let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
                guard descriptor >= 0 else { throw Failure(messages: ["fixture launch lock unavailable"]) }
                close(descriptor)
                try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: launchDirectory.path)
                defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchDirectory.path) }
                seedNote.update("Accepted before relaunch")
                expect(seedNote.error == nil, "seed a canonical note whose physical export is blocked")
                if removeLock {
                    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchDirectory.path)
                    try fm.removeItem(at: lockURL)
                    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: launchDirectory.path)
                }
                let launchStore = AppStore(directory: launchDirectory)
                let launchNote = NoteStore(directory: launchDirectory)
                let launchBridge = try BistReplicaBridge(store: launchStore, note: launchNote)
                expect(launchNote.text == "Accepted before relaunch" && launchNote.error != nil,
                       "relaunch adopts canonical text even if note export or lock creation fails")
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launchDirectory.path)
                launchNote.update(launchNote.text + " plus typing")
                let expected = "Accepted before relaunch plus typing"
                let canonical = try launchBridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value
                expect(try canonical == JSONEncoder().encode(expected), "typing after relaunch cannot sync the older file's text")
                expect((try? Data(contentsOf: launchNote.fileURL)) == Data(expected.utf8) && launchNote.error == nil,
                       "repaired export writes the accepted note after relaunch")
                _ = seedBridge
            }
        }
        let unreadableDirectory = root.appendingPathComponent("unreadable-pending-export")
        let unreadableStore = AppStore(directory: unreadableDirectory)
        let unreadableNote = NoteStore(directory: unreadableDirectory)
        unreadableNote.update("Old physical export")
        let unreadableBridge = try BistReplicaBridge(store: unreadableStore, note: unreadableNote)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unreadableDirectory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path) }
        unreadableNote.update("Accepted pending")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path)
        try Data([0xff, 0xfe]).write(to: unreadableNote.fileURL)
        expect(!unreadableNote.recoverFromDisk() && !unreadableNote.isReadable,
               "a failed second read leaves the accepted pending note in an unreadable state")
        try large.write(to: unreadableNote.fileURL)
        expect(unreadableStore.reload() && unreadableNote.error?.contains("16 MiB") == true,
               "reloading an unreadable note rejects an oversized replacement")
        expect(unreadableNote.exportBaselineBytes == Data("Old physical export".utf8),
               "recovery cannot trust bytes before SQLite accepts the external file")
        unreadableNote.save()
        expect(try Data(contentsOf: unreadableNote.fileURL) == large && unreadableNote.error != nil,
               "background save never overwrites an external file rejected after unreadable recovery")
        try Data("Valid external recovery".utf8).write(to: unreadableNote.fileURL)
        expect(unreadableStore.reload() && unreadableNote.isReadable && unreadableNote.text == "Valid external recovery" && unreadableNote.error == nil,
               "a proven valid import clears unreadable state without relaunch")
        _ = unreadableBridge

        for observedFile in [false, true] {
            let boundaryDirectory = root.appendingPathComponent("changed-after-read-\(observedFile)")
            let boundaryStore = AppStore(directory: boundaryDirectory)
            let boundaryNote = NoteStore(directory: boundaryDirectory)
            if observedFile { boundaryNote.update("Known export") }
            let boundaryBridge = try BistReplicaBridge(store: boundaryStore, note: boundaryNote)
            let descriptor = open(boundaryDirectory.appendingPathComponent(".note.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw Failure(messages: ["fixture boundary lock unavailable"]) }
            close(descriptor)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: boundaryDirectory.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: boundaryDirectory.path) }
            boundaryNote.update("Accepted at boundary")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: boundaryDirectory.path)
            let provenSnapshot = try boundaryNote.readableDiskSnapshot()
            try large.write(to: boundaryNote.fileURL)
            expect(boundaryNote.acceptReplicaFile(provenSnapshot, preservingAcceptedText: true) && boundaryNote.text == "Accepted at boundary",
                   "a changed file cannot alter the already proven snapshot or pending accepted text")
            boundaryNote.save()
            expect(try Data(contentsOf: boundaryNote.fileURL) == large && boundaryNote.error != nil,
                   "a new file appearing after a proven text or missing-file snapshot is preserved")
            let canonical = try boundaryBridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value
            expect(try canonical == JSONEncoder().encode("Accepted at boundary"), "an unaccepted file cannot replace canonical content")
        }

        let retryDirectory2 = root.appendingPathComponent("coordinator-unreadable-retry")
        let retrySeed = AppStore(directory: retryDirectory2)
        expect(retrySeed.addTask(title: "Before bootstrap failure"), "seed coordinator retry")
        let validState = try Data(contentsOf: retrySeed.stateURL)
        try Data("{broken".utf8).write(to: retrySeed.stateURL)
        try Data([0xff, 0xfe]).write(to: retryDirectory2.appendingPathComponent("note.txt"))
        let retryStore2 = AppStore(directory: retryDirectory2)
        let retryNote2 = NoteStore(directory: retryDirectory2)
        let retryCoordinator = BistSyncCoordinator(store: retryStore2, note: retryNote2)
        try validState.write(to: retryStore2.stateURL)
        try large.write(to: retryNote2.fileURL)
        expect(retryStore2.reload() && retryStore2.addTask(title: "Recovered task storage"), "startup repair attaches task storage independently of a rejected unreadable note")
        retryNote2.save()
        expect(try Data(contentsOf: retryNote2.fileURL) == large && retryNote2.error != nil,
               "startup attachment retry never trusts a rejected note before importing it")
        try Data("Recovered after startup failure".utf8).write(to: retryNote2.fileURL)
        expect(retryStore2.reload() && retryNote2.text == "Recovered after startup failure" && retryNote2.error == nil,
               "startup retry can adopt a later valid note without relaunch")
        _ = retryCoordinator

        for route in ["launch", "external", "known", "unreadable", "readonly"] {
            let bomDirectory = root.appendingPathComponent("bom-\(route)")
            var bomStore = AppStore(directory: bomDirectory)
            var bomNote = NoteStore(directory: bomDirectory)
            bomNote.update("Known export")
            var bomBridge = try BistReplicaBridge(store: bomStore, note: bomNote)
            let expected = route == "known" ? "Known export" : "External 📝\n"
            var bomBytes = Data([0xef, 0xbb, 0xbf])
            bomBytes.append(Data(expected.utf8))
            if route == "launch" || route == "unreadable" {
                try (route == "launch" ? bomBytes : Data([0xff, 0xfe])).write(to: bomNote.fileURL)
                bomStore = AppStore(directory: bomDirectory)
                bomNote = NoteStore(directory: bomDirectory)
                bomBridge = try BistReplicaBridge(store: bomStore, note: bomNote)
            }
            try bomBytes.write(to: bomNote.fileURL)
            if route == "readonly" { try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bomDirectory.path) }
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bomDirectory.path) }
            expect(bomStore.reload() && bomNote.text == expected && bomNote.error == nil && !bomNote.hasUnsavedDraft,
                   "BOM notes load without a false draft or stale-writer conflict on every recovery route")
            expect(try Data(contentsOf: bomNote.fileURL) == bomBytes, "projection preserves the physical BOM when the decoded text already matches")
            bomNote.save()
            expect(bomNote.error == nil && bomNote.exportBaselineBytes == bomBytes,
                   "idle save retains the raw BOM baseline without inventing a pending export")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bomDirectory.path)
            bomNote.update("Edited after BOM")
            expect(bomNote.error == nil && !bomNote.hasUnsavedDraft, "an actual edit of BOM text saves without relaunch")
            expect(try Data(contentsOf: bomNote.fileURL) == Data("Edited after BOM".utf8), "BOM recovery permits the later physical edit")
            let canonical = try bomBridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value
            expect(try canonical == JSONEncoder().encode("Edited after BOM"), "BOM edits reach canonical storage")
        }
        for removeFile in [false, true] {
            let draftDirectory = root.appendingPathComponent("unreadable-draft-\(removeFile)")
            let draftStore = AppStore(directory: draftDirectory)
            try fm.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
            try Data([0xff]).write(to: draftDirectory.appendingPathComponent("note.txt"))
            let draftNote = NoteStore(directory: draftDirectory)
            let draftBridge = try BistReplicaBridge(store: draftStore, note: draftNote)
            draftNote.update("Copy this unsaved draft")
            if removeFile { try fm.removeItem(at: draftNote.fileURL) }
            else { try Data("Repaired saved version".utf8).write(to: draftNote.fileURL) }
            expect(draftStore.reload() && draftNote.text == "Copy this unsaved draft" && draftNote.hasUnsavedDraft,
                   "repairing an unreadable file preserves a draft typed while it was blocked")
            expect(draftNote.error?.contains("Copy") == true && !draftNote.canRetrySave,
                   "a repaired file directs the person to copy the blocked draft")
            _ = draftBridge
        }
        let staleErrorDirectory = root.appendingPathComponent("changing-rejection-cause")
        let staleErrorStore = AppStore(directory: staleErrorDirectory)
        try fm.createDirectory(at: staleErrorDirectory, withIntermediateDirectories: true)
        try Data([0xff]).write(to: staleErrorDirectory.appendingPathComponent("note.txt"))
        let staleErrorNote = NoteStore(directory: staleErrorDirectory)
        let staleErrorBridge = try BistReplicaBridge(store: staleErrorStore, note: staleErrorNote)
        try large.write(to: staleErrorNote.fileURL)
        expect(staleErrorStore.reload() && staleErrorNote.error?.contains("16 MiB") == true, "an oversized repair reports the current size failure")
        try Data([0xff, 0xfe]).write(to: staleErrorNote.fileURL)
        expect(staleErrorStore.reload() && staleErrorNote.error?.contains("UTF-8") == true && staleErrorNote.error?.contains("16 MiB") == false,
               "a later invalid file replaces the stale size error with encoding guidance")
        staleErrorNote.save()
        expect(try Data(contentsOf: staleErrorNote.fileURL) == Data([0xff, 0xfe]) && staleErrorNote.error?.contains("UTF-8") == true,
               "background save preserves invalid bytes and their current error")
        _ = staleErrorBridge
        let literalDirectory = root.appendingPathComponent("canonical-bom-character")
        let literalSeedStore = AppStore(directory: literalDirectory)
        let literalSeedNote = NoteStore(directory: literalDirectory)
        let literalSeedBridge = try BistReplicaBridge(store: literalSeedStore, note: literalSeedNote)
        let literal = "\u{feff}Canonical prefix"
        literalSeedNote.update(literal)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: literalDirectory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: literalDirectory.path) }
        let literalStore = AppStore(directory: literalDirectory)
        let literalNote = NoteStore(directory: literalDirectory)
        let literalBridge = try BistReplicaBridge(store: literalStore, note: literalNote)
        expect(literalNote.text == literal && literalNote.error == nil,
               "a literal canonical BOM character already present in the raw export needs no rewrite")
        literalNote.save()
        expect(literalNote.error == nil && !literalNote.canRetrySave,
               "an exact raw canonical export needs no idle write on read-only storage")
        _ = literalSeedBridge; _ = literalBridge

        for revert in [false, true] {
            let reloadDirectory = root.appendingPathComponent("healthy-draft-reload-\(revert)")
            let reloadStore = AppStore(directory: reloadDirectory)
            let reloadNote = NoteStore(directory: reloadDirectory)
            reloadNote.update("Saved before lock")
            let reloadBridge = try BistReplicaBridge(store: reloadStore, note: reloadNote)
            let lock = open(reloadDirectory.appendingPathComponent(".note.lock").path, O_RDWR)
            guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure(messages: ["fixture retry lock unavailable"]) }
            reloadNote.update("Retryable healthy draft")
            expect(reloadNote.canRetrySave, "a locked save leaves a retryable draft")
            flock(lock, LOCK_UN); close(lock)
            expect(reloadStore.reload() && reloadNote.canRetrySave && reloadNote.text == "Retryable healthy draft",
                   "reload with an unchanged file preserves a readable draft's Retry save")
            if revert {
                reloadNote.update("Saved before lock")
                reloadNote.save()
                expect(reloadNote.error == nil && !reloadNote.canRetrySave && !reloadNote.hasUnsavedDraft,
                       "reverting a healthy draft after reload clears the stale draft error")
            } else {
                reloadNote.save()
                let canonical = try reloadBridge.database.records().first { $0.id == "note.main" }?.fields["text"]?.value
                expect(try canonical == JSONEncoder().encode("Retryable healthy draft"), "Retry after reload commits the draft to SQLite")
                expect((try? Data(contentsOf: reloadNote.fileURL)) == Data("Retryable healthy draft".utf8) && reloadNote.error == nil,
                       "Retry after reload exports the draft without another keystroke")
            }
        }
        let attachDirectory = root.appendingPathComponent("retry-draft-after-attachment")
        let attachSeed = AppStore(directory: attachDirectory)
        expect(attachSeed.addTask(title: "Before broken task storage"), "seed attachment retry")
        let attachState = try Data(contentsOf: attachSeed.stateURL)
        let attachNoteSeed = NoteStore(directory: attachDirectory)
        attachNoteSeed.update("Saved before attachment")
        try Data("{broken".utf8).write(to: attachSeed.stateURL)
        let attachStore = AppStore(directory: attachDirectory)
        let attachNote = NoteStore(directory: attachDirectory)
        let attachCoordinator = BistSyncCoordinator(store: attachStore, note: attachNote)
        attachNote.update("Draft while storage was broken")
        expect(attachNote.canRetrySave && attachNote.hasUnsavedDraft, "broken task storage leaves a retryable readable note draft")
        try attachState.write(to: attachStore.stateURL)
        expect(attachStore.reload() && attachNote.canRetrySave, "repairing task storage preserves the note draft's Retry save")
        attachNote.save()
        expect((try? Data(contentsOf: attachNote.fileURL)) == Data("Draft while storage was broken".utf8) && attachNote.error == nil,
               "Retry saves the retained draft after storage attaches")
        _ = attachCoordinator

        let conflictDirectory = root.appendingPathComponent("cleared-readable-conflict")
        let conflictStore = AppStore(directory: conflictDirectory)
        let conflictNote = NoteStore(directory: conflictDirectory)
        conflictNote.update("Original saved text")
        let conflictBridge = try BistReplicaBridge(store: conflictStore, note: conflictNote)
        try Data("Changed external file".utf8).write(to: conflictNote.fileURL)
        conflictNote.update("Unsaved conflict")
        expect(conflictStore.reload() && conflictNote.error?.contains("Copy") == true && !conflictNote.canRetrySave,
               "a changed file still directs a readable draft to copy recovery")
        conflictNote.update("Original saved text")
        conflictNote.save()
        expect(conflictNote.error?.contains("Reload saved data") == true && conflictNote.error?.contains("unsaved") == false && !conflictNote.hasUnsavedDraft,
               "a reverted draft retains the reload signal when the saved file differs")
        expect(try Data(contentsOf: conflictNote.fileURL) == Data("Changed external file".utf8), "clearing stale guidance never replaces the external file")
        _ = conflictBridge

        for removeFile in [false, true] {
            let changedDirectory = root.appendingPathComponent("live-retry-file-change-\(removeFile)")
            let changedStore = AppStore(directory: changedDirectory)
            let changedNote = NoteStore(directory: changedDirectory)
            changedNote.update("Saved")
            let changedBridge = try BistReplicaBridge(store: changedStore, note: changedNote)
            let lock = open(changedDirectory.appendingPathComponent(".note.lock").path, O_RDWR)
            guard lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure(messages: ["fixture changed-file lock unavailable"]) }
            changedNote.update("Retryable draft")
            expect(changedNote.canRetrySave, "seed a live Retry before the file changes")
            if removeFile { try fm.removeItem(at: changedNote.fileURL) }
            else { try Data("External".utf8).write(to: changedNote.fileURL) }
            flock(lock, LOCK_UN); close(lock)
            expect(changedStore.reload() && !changedNote.canRetrySave && changedNote.error?.contains("loading the saved version") == true,
                   "a changed or deleted file removes an ineffective live Retry")
            changedNote.save()
            let expected = removeFile ? nil : Data("External".utf8)
            expect((try? Data(contentsOf: changedNote.fileURL)) == expected,
                   "a save after changed-file reload cannot replace the external version")
            changedNote.update("Saved")
            expect(changedNote.error?.contains("Reload saved data") == true && !changedNote.hasUnsavedDraft,
                   "reverting a changed-file draft keeps accurate reload guidance")
            expect(changedStore.reload() && changedNote.error == nil && changedNote.text == (removeFile ? "Saved" : "External"),
                   "reload after reversion adopts canonical saved text and clears guidance")
            _ = changedBridge
        }
        let noRetryDirectory = root.appendingPathComponent("unchanged-file-without-retry")
        let noRetryStore = AppStore(directory: noRetryDirectory)
        let noRetryNote = NoteStore(directory: noRetryDirectory)
        noRetryNote.update("Saved")
        let noRetryBridge = try BistReplicaBridge(store: noRetryStore, note: noRetryNote)
        try Data("External".utf8).write(to: noRetryNote.fileURL)
        noRetryNote.update("Blocked draft")
        expect(!noRetryNote.canRetrySave, "seed a conflict without live Retry")
        try Data("Saved".utf8).write(to: noRetryNote.fileURL)
        expect(noRetryStore.reload() && !noRetryNote.canRetrySave && noRetryNote.error?.contains("loading the saved version") == true,
               "an unchanged file without a live Retry still follows draft recovery")
        noRetryNote.update("Saved")
        expect(noRetryNote.error == nil, "reversion clears guidance when the physical file matches the baseline")
        _ = noRetryBridge
        if !failures.isEmpty { throw Failure(messages: failures) }
        print("PASS \(checks) rejected external-note import and recovery checks")
    }
}
