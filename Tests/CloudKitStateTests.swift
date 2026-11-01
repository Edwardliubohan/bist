import Foundation
import CloudKit

@main
struct CloudKitStateTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw Failure(message: message) }
    }
    static func bytes(_ value: String) -> Data { Data(value.utf8) }

    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-cloud-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ReplicaDatabase(directory: root.appendingPathComponent("replica"))
        try database.apply([
            .set(id: "task.one", kind: "task", values: ["title": bytes("\"One\"")]),
            .set(id: "task.two", kind: "task", values: ["title": bytes("\"Two\"")]),
            .set(id: "note.main", kind: "note", values: ["text": bytes("\"Keep my draft\"")]),
            .set(id: "task.deleted", kind: "task", values: ["title": bytes("\"Past task\"")]),
            .delete(id: "task.deleted")
        ], metadata: ["localSnapshot": bytes("local session fields"), "Development.cloudOwner": bytes("original-owner"),
                      "cloudContainer": bytes("iCloud.test.bist")])
        try database.acknowledge(database.pendingRecords())
        let original = try database.records()
        for record in original {
            try database.setMetadata(bytes("production fields"), forKey: "Production.cloudRecord." + record.id)
        }
        try database.setMetadata(bytes("production cursor"), forKey: "Production.engineState")

        // A first-time absent zone can be created and queues every local record.
        try CloudKitReplicaState.rebuildMissingZone(database: database, environment: "Development")
        try check(database.records() == original, "zone rebuild preserves all live content and tombstones")
        try check(database.pendingRecords() == original, "zone rebuild requeues acknowledged records")
        try check(database.metadata(forKey: "Development.engineState") == nil, "zone rebuild removes old cursor")
        for record in original {
            try check(database.metadata(forKey: "Development.cloudRecord." + record.id) == nil, "zone rebuild removes every stale system record")
            try check(database.metadata(forKey: "Production.cloudRecord." + record.id) == bytes("production fields"), "zone rebuild leaves other environment cache intact")
        }
        try check(database.metadata(forKey: "Production.engineState") == bytes("production cursor"), "other environment cursor preserved")
        try check(database.metadata(forKey: "Development.zoneNeedsCreation") != nil, "fresh engine must recreate zone")

        // A failed save with stale system fields is not evidence of a cloud deletion.
        try database.setMetadata(bytes("stale"), forKey: "Development.cloudRecord.note.main")
        try CloudKitReplicaState.discardStaleRecord(database: database, environment: "Development", recordID: "note.main")
        try check(database.records() == original, "unknownItem cannot tombstone the note or tasks")
        try check(database.metadata(forKey: "Development.cloudRecord.note.main") == nil, "unknownItem clears stale system fields")

        // An established zone disappearing must pause instead of silently republishing.
        try database.acknowledge(database.pendingRecords())
        try CloudKitReplicaState.recordZoneEstablished(database: database, environment: "Development")
        try database.setMetadata(bytes("old cursor"), forKey: "Development.engineState")
        for record in original { try database.setMetadata(bytes("old system fields"), forKey: "Development.cloudRecord." + record.id) }
        do {
            try CloudKitReplicaState.rebuildMissingZone(database: database, environment: "Development")
            throw Failure(message: "established missing zone was republished without consent")
        } catch is CloudKitRecoveryError { checks += 1 }
        try check(database.pendingRecords().isEmpty, "established missing zone never queues acknowledged data automatically")
        try check(database.metadata(forKey: "Development.engineState") == bytes("old cursor"), "pause preserves cursor until explicit recovery")
        // An observed cloud wipe stays paused across restart until explicit restore.
        let reopened = try ReplicaDatabase(directory: database.directory)
        try check(CloudKitReplicaState.isPaused(database: reopened, environment: "Development"), "cloud wipe pause survives restart")
        do {
            try CloudKitReplicaState.rebuildMissingZone(database: reopened, environment: "Development")
            throw Failure(message: "paused data was republished without explicit recovery")
        } catch is CloudKitRecoveryError { checks += 1 }
        try check(reopened.pendingRecords().isEmpty, "observed deletion does not automatically republish")
        try database.setMetadata(bytes("paused cursor"), forKey: "Development.engineState")
        try database.setMetadata(bytes("paused system fields"), forKey: "Development.cloudRecord.task.one")
        try database.mutate(recordID: "task.offline", kind: "task", values: ["title": bytes("\"Unsent task\"")])
        let beforeRestore = try database.records()
        let backup = try CloudKitReplicaState.restoreLocalData(database: database, environment: "Development",
                                                              backupDirectory: root.appendingPathComponent("backups"))
        try check(FileManager.default.fileExists(atPath: backup.path), "explicit restore creates a local backup first")
        let backupMode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as! NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: backup.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        try check(backupMode.intValue & 0o777 == 0o600 && directoryMode.intValue & 0o777 == 0o700, "recovery backup is private to this user")
        let exported = try JSONDecoder().decode(CloudKitRecoveryBackup.self, from: Data(contentsOf: backup))
        try check(exported.records == beforeRestore, "backup retains portable content and tombstones")
        try check(exported.pendingRecordIDs == ["task.offline"], "backup retains unsent outbox identities")
        try check(exported.localSnapshot == bytes("local session fields"), "backup retains local-only session fields")
        try check(database.records() == beforeRestore, "explicit restore preserves local revisions")
        try check(database.pendingRecords() == beforeRestore, "explicit restore requeues all local data")
        try check(!CloudKitReplicaState.isPaused(database: database, environment: "Development"), "explicit restore clears pause")
        try check(database.metadata(forKey: "Development.engineState") == nil, "explicit restore clears old cursor")
        try check(database.metadata(forKey: "Development.cloudRecord.task.one") == nil, "explicit restore clears stale system fields")
        try check(database.metadata(forKey: "Development.cloudZoneEstablished") == nil, "restore marks replacement zone as not yet established")
        try check(database.metadata(forKey: "Development.cloudOwner") == bytes("original-owner"), "restore preserves account binding")
        try check(database.metadata(forKey: "cloudContainer") == bytes("iCloud.test.bist"), "restore preserves container binding")

        // If making the required backup fails, the pause and outbox must remain unchanged.
        try database.acknowledge(database.pendingRecords())
        try CloudKitReplicaState.pauseAfterDeletion(database: database, environment: "Development")
        try database.setMetadata(bytes("keep cursor"), forKey: "Development.engineState")
        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        try bytes("blocked").write(to: blockedDirectory)
        do {
            _ = try CloudKitReplicaState.restoreLocalData(database: database, environment: "Development", backupDirectory: blockedDirectory)
            throw Failure(message: "restore succeeded without its required backup")
        } catch is Failure { throw Failure(message: "backup failure was swallowed") }
          catch { checks += 1 }
        try check(CloudKitReplicaState.isPaused(database: database, environment: "Development"), "backup failure preserves pause")
        try check(database.pendingRecords().isEmpty, "backup failure does not publish records")
        try check(database.metadata(forKey: "Development.engineState") == bytes("keep cursor"), "backup failure preserves cursor")

        // Retry errors stay visible until a complete successful flow has zero pending records.
        var progress = CloudKitProgressState()
        _ = progress.begin(.send)
        _ = progress.failed(.send, message: "Network unavailable")
        let failedBatch = progress.pendingStatus(pending: 4)
        try check(failedBatch.message == "Changes waiting to sync" && failedBatch.error == "Network unavailable", "same batch cannot hide retry status before completion")
        let failedSend = progress.finished(.send, pending: 4)
        try check(failedSend.error == "Network unavailable" && failedSend.message != "Up to date", "didSend does not clear transient failure")
        _ = progress.begin(.fetch)
        let fetched = progress.finished(.fetch, pending: 4)
        try check(fetched.error == "Network unavailable", "successful fetch cannot hide unsent-change error")
        _ = progress.begin(.send)
        let pendingSend = progress.finished(.send, pending: 1)
        try check(pendingSend.error == "Network unavailable", "partial retry retains visible failure")
        _ = progress.begin(.send)
        let success = progress.finished(.send, pending: 0)
        try check(success.error == nil && success.message == "Up to date", "completed successful retry clears error")
        _ = progress.begin(.fetch)
        _ = progress.failed(.fetch, message: "Could not fetch")
        let fetchFailure = progress.finished(.fetch, pending: 0)
        try check(fetchFailure.error == "Could not fetch" && fetchFailure.message != "Up to date", "zero pending is not proof a failed fetch succeeded")
        _ = progress.begin(.send)
        let unrelatedSend = progress.finished(.send, pending: 0)
        try check(unrelatedSend.error == "Could not fetch" && unrelatedSend.message != "Up to date", "successful empty send cannot conceal a failed fetch")
        _ = progress.begin(.fetch)
        _ = progress.begin(.send)
        let midSend = progress.finished(.send, pending: 0)
        try check(midSend.message != "Up to date", "in-flight fetch prevents premature success")
        let finishedAll = progress.finished(.fetch, pending: 0)
        try check(finishedAll.message == "Up to date" && finishedAll.error == nil, "completed clean flows establish up-to-date state")
        print("PASS \(checks) CloudKit durable recovery and progress checks")
    }
}
