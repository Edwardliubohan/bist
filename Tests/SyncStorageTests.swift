import Foundation
import CSQLite

@main
struct SyncStorageTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
    static func bytes(_ text: String) -> Data { Data(text.utf8) }
    static func value(_ database: ReplicaDatabase, _ id: String, _ field: String) throws -> String? {
        try database.records().first { $0.id == id }?.fields[field].flatMap { String(data: $0.value, encoding: .utf8) }
    }
    static func rawSQL(_ directory: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("sync.sqlite").path, &handle) == SQLITE_OK else {
            throw Failure(message: "test database failed to open")
        }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure(message: "test SQL failed")
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-sync-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("a")
        let bURL = root.appendingPathComponent("b")
        let a = try ReplicaDatabase(directory: aURL)
        let b = try ReplicaDatabase(directory: bURL)

        // A write without an atomic outbox entry loses an offline edit after relaunch.
        try a.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"First\""), "completed": bytes("false")])
        let initial = try a.records()
        try check(initial.count == 1, "local task saved")
        try check(a.pendingRecords().count == 1, "write and outbox committed together")
        let sameA = try ReplicaDatabase(directory: aURL)
        try check(sameA.deviceID == a.deviceID, "device ID survives relaunch")
        try check(value(sameA, "task-1", "title") == "\"First\"", "offline task survives relaunch")
        try check(sameA.pendingRecords().count == 1, "outbox survives relaunch")
        try b.merge(remote: initial)
        try a.acknowledge(initial)
        try check(a.pendingRecords().isEmpty, "exact revision acknowledgement clears outbox")

        // Whole-record replacement would lose one of these independent edits.
        try a.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"Phone title\"")])
        try b.mutate(recordID: "task-1", kind: "task", values: ["completed": bytes("true")])
        let aEdit = try a.records()
        let bEdit = try b.records()
        try a.merge(remote: bEdit)
        try b.merge(remote: aEdit)
        try check(value(a, "task-1", "title") == "\"Phone title\"", "title preserved")
        try check(value(a, "task-1", "completed") == "true", "independent completion preserved")
        try check(a.records() == b.records(), "independent changes converge")

        // A late upload acknowledgement must not drop an edit made during upload.
        let uploading = try a.pendingRecords()
        try a.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"Newer while uploading\"")])
        try a.acknowledge(uploading)
        try check(a.pendingRecords().count == 1, "old upload cannot clear newer revision")

        // Same-field resolution must be deterministic in both delivery orders.
        try b.merge(remote: a.records())
        try a.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"A conflict\"")])
        try b.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"B conflict\"")])
        let left = try a.records()
        let right = try b.records()
        try a.merge(remote: right)
        try b.merge(remote: left)
        try check(a.records() == b.records(), "same-field changes converge in either order")
        let leftWriter = left.first { $0.id == "task-1" }!.fields["title"]!.stamp.deviceID
        let rightWriter = right.first { $0.id == "task-1" }!.fields["title"]!.stamp.deviceID
        let expected = leftWriter > rightWriter ? "\"A conflict\"" : "\"B conflict\""
        try check(value(a, "task-1", "title") == expected, "writer identity breaks equal logical counters")

        // A tombstone cannot disappear when a device sends an old live record.
        let beforeDelete = try a.records()
        try a.delete(recordID: "task-1")
        let deleted = try a.records()
        try b.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"Stale offline edit\"")])
        try a.merge(remote: b.records())
        try b.merge(remote: deleted)
        try a.merge(remote: beforeDelete)
        try check(a.records().first!.isDeleted, "stale edit cannot resurrect deletion")
        try check(b.records().first!.isDeleted, "deletion reaches offline editor")
        do {
            try a.mutate(recordID: "task-1", kind: "task", values: ["title": bytes("\"Accidental resurrection\"")])
            throw Failure(message: "ordinary edit of deleted record should fail")
        } catch is ReplicaError { checks += 1 }
        try a.apply([.restore(id: "task-1")])
        try b.merge(remote: a.records())
        try check(!b.records().first!.isDeleted, "explicit restore supports task Undo")
        try b.merge(remote: deleted)
        try check(!b.records().first!.isDeleted, "old tombstone cannot undo explicit restoration")

        // Keeping only the winning note text silently destroys the other draft.
        try a.mutate(recordID: "note", kind: "note", values: ["text": bytes("\"Base\"")])
        try b.merge(remote: a.records())
        try a.mutate(recordID: "note", kind: "note", values: ["text": bytes("\"Mac draft\"")])
        try b.mutate(recordID: "note", kind: "note", values: ["text": bytes("\"Phone draft\"")])
        let noteA = try a.records()
        let noteB = try b.records()
        try a.merge(remote: noteB)
        try b.merge(remote: noteA)
        try check(a.records() == b.records(), "notes converge with matching history")
        let current = try value(a, "note", "text")!
        let recovered = try a.recoverableValues(recordID: "note", field: "text").compactMap { String(data: $0, encoding: .utf8) }
        let losing = current == "\"Mac draft\"" ? "\"Phone draft\"" : "\"Mac draft\""
        try check(recovered.contains(losing), "losing draft remains recoverable")
        try check(recovered.contains("\"Base\""), "prior note version remains recoverable")

        // Sequential typing must not accumulate every prior draft in the CloudKit payload.
        for index in 0..<100 {
            try a.mutate(recordID: "note", kind: "note", values: ["text": bytes("\"Draft \(index)\"")])
        }
        let latestNote = try a.records().first { $0.id == "note" }!
        try check(latestNote.fields["text"]!.history.isEmpty, "sequential drafts stay out of network history")
        try check(a.recoverableValues(recordID: "note", field: "text").contains(bytes(losing)), "resolved conflict retained locally")
        try check(a.recoverableValues(recordID: "note", field: "text").count <= 36, "ordinary local drafts have bounded retention")
        try b.merge(remote: a.records())
        try check(b.records().first { $0.id == "note" }!.fields["text"]!.history.isEmpty, "observed conflict heads are resolved")
        try b.merge(remote: noteA)
        try check(value(b, "note", "text") == "\"Draft 99\"", "old draft cannot reappear after resolution")

        // An invalid later mutation must roll back both data and the earlier outbox change.
        let beforeFailure = try a.records()
        let pendingBeforeFailure = try a.pendingRecords()
        do {
            try a.apply([
                .set(id: "rollback", kind: "task", values: ["title": bytes("\"Must roll back\"")]),
                .set(id: "", kind: "task", values: ["title": bytes("\"Invalid ID\"")])
            ])
            throw Failure(message: "invalid transaction should fail")
        } catch is ReplicaError { checks += 1 }
        try check(a.records() == beforeFailure, "failed transaction rolls back records")
        try check(a.pendingRecords() == pendingBeforeFailure, "failed transaction rolls back outbox")
        try a.setMetadata(bytes("serialized engine state"), forKey: "engine-state")
        try check(sameA.metadata(forKey: "engine-state") == bytes("serialized engine state"), "engine state persisted")
        try a.setMetadata(nil, forKey: "engine-state")
        try check(a.metadata(forKey: "engine-state") == nil, "metadata removal persisted")

        // Local-only snapshot bytes must commit atomically with their portable fields.
        try a.apply([.set(id: "atomic", kind: "task", values: ["title": bytes("\"Atomic\"")])],
                    metadata: ["snapshot": bytes("snapshot one")])
        try check(a.metadata(forKey: "snapshot") == bytes("snapshot one"), "snapshot committed with edit")
        let atomicBeforeFailure = try a.records()
        do {
            try a.apply([.set(id: "atomic", kind: "task", values: ["title": bytes("\"Rollback\"")])],
                        metadata: ["__bist_forbidden": bytes("invalid")])
            throw Failure(message: "invalid metadata should reject whole transaction")
        } catch is ReplicaError { checks += 1 }
        try check(a.records() == atomicBeforeFailure, "metadata failure rolls back record changes")
        try check(a.metadata(forKey: "snapshot") == bytes("snapshot one"), "previous snapshot retained after failure")
        try a.apply([], metadata: ["snapshot": nil])
        try check(a.metadata(forKey: "snapshot") == nil, "atomic metadata removal")
        try b.merge(remote: a.records(), metadata: ["token": bytes("token one")])
        try check(b.metadata(forKey: "token") == bytes("token one"), "remote record and token committed together")

        // Conflicting kinds and malformed JSON must not poison an otherwise readable replica.
        do {
            try a.mutate(recordID: "note", kind: "task", values: ["text": bytes("\"wrong kind\"")])
            throw Failure(message: "record kind mutation should fail")
        } catch is ReplicaError { checks += 1 }
        do {
            try a.mutate(recordID: "bad-json", kind: "task", values: ["title": bytes("not JSON")])
            throw Failure(message: "malformed JSON should fail")
        } catch is ReplicaError { checks += 1 }
        try check(!a.records().contains(where: { $0.id == "bad-json" }), "bad JSON was not written")

        // A removed server zone must be rebuilt from acknowledged local records.
        try a.acknowledge(a.pendingRecords())
        try check(a.pendingRecords().isEmpty, "all uploaded revisions acknowledged")
        try a.enqueueAll()
        try check(a.pendingRecords() == a.records(), "zone reset requeues every retained record")

        // A real SQLite write failure must roll back field history and outbox as well as data.
        let failingURL = root.appendingPathComponent("failing")
        let failing = try ReplicaDatabase(directory: failingURL)
        try failing.mutate(recordID: "locked", kind: "task", values: ["title": bytes("\"Original\"")])
        try failing.acknowledge(failing.pendingRecords())
        let failureBefore = try failing.records()
        try rawSQL(failingURL, "CREATE TRIGGER reject_updates BEFORE UPDATE ON records BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        do {
            try failing.mutate(recordID: "locked", kind: "task", values: ["title": bytes("\"Rejected\"")])
            throw Failure(message: "SQLite failure must reject edit")
        } catch is ReplicaError { checks += 1 }
        try check(failing.records() == failureBefore, "SQLite failure leaves saved data unchanged")
        try check(failing.pendingRecords().isEmpty, "SQLite failure does not publish outbox entry")
        try check(failing.recoverableValues(recordID: "locked", field: "title").isEmpty, "SQLite failure rolls back recovery history")
        try rawSQL(failingURL, "DROP TRIGGER reject_updates")
        try failing.mutate(recordID: "locked", kind: "task", values: ["title": bytes("\"Accepted\"")])
        try check(failing.records().first!.fields["title"]!.stamp.counter == 2, "SQLite failure rolls back logical counter")
        try rawSQL(failingURL, "UPDATE records SET body=X'626164206a736f6e'")
        do {
            _ = try ReplicaDatabase(directory: failingURL)
            throw Failure(message: "unreadable saved data must fail closed")
        } catch is ReplicaError { checks += 1 }

        // A future database schema is not an empty database and cannot be reinitialized.
        let futureURL = root.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: futureURL, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        sqlite3_open(futureURL.appendingPathComponent("sync.sqlite").path, &handle)
        sqlite3_exec(handle, "PRAGMA user_version=99", nil, nil, nil)
        sqlite3_close(handle)
        do {
            _ = try ReplicaDatabase(directory: futureURL)
            throw Failure(message: "future schema must fail closed")
        } catch is ReplicaError { checks += 1 }
        try backupRestoreChecks(root: root.appendingPathComponent("backup-restore"))
        print("PASS \(checks) sync storage checks")
    }

    static func backupRestoreChecks(root: URL) throws {
        let directory = root.appendingPathComponent("installation")
        let backup = root.appendingPathComponent("backup")
        let peerDirectory = root.appendingPathComponent("peer")
        var installationID = ""
        do {
            let original = try ReplicaDatabase(directory: directory)
            installationID = original.deviceID
            try original.mutate(recordID: "task.restored", kind: "task", values: ["title": bytes("\"Original task\"")])
            try original.mutate(recordID: "note.main", kind: "note", values: ["text": bytes("\"Original note\"")])
            try original.acknowledge(original.pendingRecords())
        }
        try FileManager.default.copyItem(at: directory, to: backup)
        var alreadySynced = [ReplicaRecord]()
        do {
            let advanced = try ReplicaDatabase(directory: directory)
            try advanced.mutate(recordID: "task.restored", kind: "task", values: ["title": bytes("\"Edited after backup\"")])
            try advanced.mutate(recordID: "note.main", kind: "note", values: ["text": bytes("\"Synced note draft\"")])
            alreadySynced = try advanced.records()
        }
        let peer = try ReplicaDatabase(directory: peerDirectory)
        try peer.merge(remote: alreadySynced)
        try peer.mutate(recordID: "task.from-peer", kind: "task", values: ["title": bytes("\"Unrelated peer task\"")])
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let restored = try ReplicaDatabase(directory: directory)
        try check(restored.deviceID == installationID, "backup restoration preserves installation identity")
        try restored.mutate(recordID: "task.restored", kind: "task", values: ["title": bytes("\"Offline edit after restore\"")])
        try restored.mutate(recordID: "note.main", kind: "note", values: ["text": bytes("\"Restored note draft\"")])
        let restoredBeforeFetch = try restored.records()
        let priorStamp = alreadySynced.first { $0.id == "task.restored" }!.fields["title"]!.stamp
        let restoredStamp = restoredBeforeFetch.first { $0.id == "task.restored" }!.fields["title"]!.stamp
        try check(priorStamp.counter == restoredStamp.counter, "restored file really reuses the old logical counter")
        // Before writer epochs, this real fetched batch throws conflicting values
        // for one revision and rolls back the unrelated task as well.
        try restored.merge(remote: peer.records())
        try peer.merge(remote: restored.records())
        try check(restored.records().contains { $0.id == "task.from-peer" }, "restored edit cannot poison an unrelated incoming record")
        try check(restored.records() == peer.records(), "restored backup edits converge in both directions")
        try check(priorStamp.deviceID != restoredStamp.deviceID, "restored backup uses a fresh revision author")
        try check(restoredStamp.deviceID.utf8.count <= 512, "writer epoch fits the supported revision identity")
        for database in [restored, peer] {
            let current = try value(database, "note.main", "text")!
            let versions = try database.recoverableValues(recordID: "note.main", field: "text")
            let losing = current == "\"Synced note draft\"" ? "\"Restored note draft\"" : "\"Synced note draft\""
            try check(versions.contains(bytes(losing)), "both devices retain the other restored note draft")
        }

        // Epochs prevent legitimate collisions. Corrupt input that reuses an
        // identical stamp with different content must still reject atomically.
        let validBeforeForgery = try restored.records()
        var forged = validBeforeForgery.first { $0.id == "task.restored" }!
        let field = forged.fields["title"]!
        forged.fields["title"] = ReplicaField(value: bytes("\"Different bytes for the same revision\""), stamp: field.stamp,
                                               history: field.history, context: field.context)
        try peer.mutate(recordID: "task.must-roll-back", kind: "task", values: ["title": bytes("\"Do not accept partial batch\"")])
        let unrelated = try peer.records().first { $0.id == "task.must-roll-back" }!
        do {
            try restored.merge(remote: [unrelated, forged])
            throw Failure(message: "corrupt identical-stamp revision was accepted")
        } catch is ReplicaError { checks += 1 }
        try check(restored.records() == validBeforeForgery, "corrupt stamp collision still rolls back the entire batch")
    }
}
