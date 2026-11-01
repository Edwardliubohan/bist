import Foundation
import Darwin
import CSQLite

@main
struct SyncProjectionExportTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-projection-export-\(UUID())")
        let localDirectory = root.appendingPathComponent("local")
        defer {
            _ = chmod(localDirectory.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func snapshot(at url: URL) throws -> BistSnapshot {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { try BistDateCoding.decode($0) }
            return try decoder.decode(BistSnapshot.self, from: Data(contentsOf: url))
        }

        let local = AppStore(directory: localDirectory)
        expect(local.addTask(title: "Original task"), "seed a compatibility export")
        let localNote = NoteStore(directory: localDirectory)
        let localBridge = try BistReplicaBridge(store: local, note: localNote)
        let remoteDirectory = root.appendingPathComponent("remote")
        let remote = AppStore(directory: remoteDirectory)
        let remoteNote = NoteStore(directory: remoteDirectory)
        let remoteBridge = try BistReplicaBridge(store: remote, note: remoteNote)
        try remoteBridge.receive(localBridge.database.records())
        expect(remote.addTask(title: "Accepted remote task"), "seed remote change")
        let remoteRecords = try remoteBridge.database.records()
        guard chmod(localDirectory.path, 0o500) == 0 else { fatalError("Could not make export fixture read-only") }
        var projectionError: Error?
        do { try localBridge.receive(remoteRecords) } catch { projectionError = error }
        expect(try localBridge.database.records().filter { $0.kind == "task" && !$0.isDeleted }.count == 2,
               "remote receive commits canonical tasks before compatibility projection")
        expect(projectionError == nil, "failed compatibility export cannot reject accepted canonical receive")
        expect(local.tasks.map(\.title) == ["Original task", "Accepted remote task"], "accepted canonical tasks reach the live view")
        expect(local.storeError == nil, "compatibility export failure does not block the task store")
        expect(try snapshot(at: local.stateURL).tasks.count == 1, "read-only fixture leaves compatibility export stale")
        expect(local.addTask(title: "Local edit while export is blocked"), "SQLite-backed editing remains usable")

        let reopened = AppStore(directory: localDirectory)
        expect(reopened.tasks.count == 1, "legacy reader sees the deliberately stale export before attachment")
        let reopenedNote = NoteStore(directory: localDirectory)
        var reopenedBridge: BistReplicaBridge?
        var launchError: Error?
        do { reopenedBridge = try BistReplicaBridge(store: reopened, note: reopenedNote) }
        catch { launchError = error }
        expect(launchError == nil && reopenedBridge != nil, "canonical storage attaches despite a failed launch export")
        expect(reopened.tasks.count == 3 && reopened.storeError == nil, "launch projects every accepted SQLite task")
        expect(reopened.addTask(title: "Edit after launch"), "failed compatibility export never installs a permanent write gate")
        expect(reopened.reload() && reopened.tasks.count == 4, "authoritative reload preserves tasks while export is blocked")
        _ = chmod(localDirectory.path, 0o700)
        expect(reopened.reload(), "reload retries export after folder access returns")
        expect(try snapshot(at: reopened.stateURL).tasks.count == 4, "an unchanged canonical snapshot repairs its stale export")
        try FileManager.default.removeItem(at: reopened.stateURL)
        expect(reopened.reload() && reopened.tasks.count == 4, "a missing export cannot erase an unchanged canonical view")
        expect(try snapshot(at: reopened.stateURL).tasks.count == 4, "reload recreates the missing derived export")

        let beforeInvalid = reopened.currentSnapshot
        let validExport = try Data(contentsOf: reopened.stateURL)
        var invalid = beforeInvalid
        invalid.tasks.append(invalid.tasks[0])
        var invalidRejected = false
        do { try reopened.applyReplicaSnapshot(invalid) } catch { invalidRejected = true }
        expect(invalidRejected && reopened.currentSnapshot == beforeInvalid, "invalid snapshots still fail before changing the task view")
        expect(try Data(contentsOf: reopened.stateURL) == validExport, "invalid snapshots never reach the compatibility export")

        let emptyDirectory = root.appendingPathComponent("empty-canonical")
        let empty = AppStore(directory: emptyDirectory)
        let emptyBridge = try BistReplicaBridge(store: empty, note: NoteStore(directory: emptyDirectory))
        try Data("{broken".utf8).write(to: empty.stateURL)
        let blocked = AppStore(directory: emptyDirectory)
        expect(blocked.storeError != nil, "seed unreadable compatibility data over an empty replica")
        let recoveredBridge = try BistReplicaBridge(store: blocked, note: NoteStore(directory: emptyDirectory))
        expect(blocked.storeError == nil && blocked.addTask(title: "Recovered empty replica"),
               "an unchanged valid canonical snapshot clears the old compatibility read gate")
        _ = emptyBridge; _ = recoveredBridge

        // A real canonical database failure must retain the normal failure gate.
        var database: OpaquePointer?
        let databasePath = localDirectory.appendingPathComponent("sync/sync.sqlite").path
        guard sqlite3_open(databasePath, &database) == SQLITE_OK else { fatalError("Could not open failure fixture") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "DROP TABLE records", nil, nil, nil) == SQLITE_OK else { fatalError("Could not inject canonical table failure") }
        let beforeFailure = reopened.currentSnapshot
        expect(!reopened.addTask(title: "Must not be accepted") && reopened.storeError != nil,
               "canonical database errors still reject edits with a visible error")
        expect(reopened.currentSnapshot == beforeFailure, "failed canonical writes preserve the last accepted view")
        var databaseRejected = false
        do { try reopenedBridge!.receive(remoteRecords) } catch { databaseRejected = true }
        expect(databaseRejected && reopened.currentSnapshot == beforeFailure, "canonical receive failures remain real failures")
        print("PASS: \(checks) canonical projection and compatibility export checks")
    }
}
