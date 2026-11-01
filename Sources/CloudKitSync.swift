import Foundation
import CloudKit
#if os(macOS)
import Security
#endif

/// CloudKit schedules network work while SQLite owns durable content and retries.
@MainActor
final class CloudKitReplicaTransport: CKSyncEngineDelegate {
    private let bridge: BistReplicaBridge
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: "BistPersonalV1")
    private var engine: CKSyncEngine?
    private var active = true
    private var failure: Error?
    private var inFlight: [String: ReplicaRecord] = [:]
    private var assets: [String: URL] = [:]
    private let environment: String
    private var engineGeneration = 0
    private var zoneRecovery: Task<Void, Error>?
    private var progress = CloudKitProgressState()
    private(set) var latestStatus = CloudKitSyncStatus(message: "Saved on this device", error: nil)
    var needsRestart: Bool { !active || failure != nil }
    var stateChanged: ((String, String?) -> Void)?

    static var configuredEnvironment: String {
        Bundle.main.object(forInfoDictionaryKey: "BistCloudKitEnvironment") as? String ?? "Development"
    }
    static func scopeIdentifier(_ containerID: String) -> String { containerID + "|" + configuredEnvironment }
    static func recoveryRequired(in database: ReplicaDatabase) throws -> Bool {
        try CloudKitReplicaState.isPaused(database: database, environment: configuredEnvironment)
    }

    static func configuredContainer(_ value: String) -> String? {
        guard ["Development", "Production"].contains(configuredEnvironment), value.hasPrefix("iCloud."), value.count > 7, !value.contains("$("),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }) else { return nil }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              identifiers.contains(value),
              let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit") else { return nil }
        #endif
        return value
    }

    init(bridge: BistReplicaBridge, containerID: String) throws {
        guard Self.configuredContainer(containerID) != nil else { throw ReplicaError.storage("CloudKit signing is not configured") }
        self.bridge = bridge
        environment = Self.configuredEnvironment
        container = CKContainer(identifier: containerID)
    }

    func synchronize() async throws {
        var currentFlow = CloudKitProgressState.Flow.fetch
        do {
            guard active else { throw CancellationError() }
            if let failure { throw failure }
            guard try !CloudKitReplicaState.isPaused(database: bridge.database, environment: environment) else { throw CloudSyncError.paused }
            emit(CloudKitSyncStatus(message: "Connecting to iCloud…", error: progress.error))
            try await bindAccount()
            while active {
                if let recovery = zoneRecovery {
                    try await recovery.value
                    zoneRecovery = nil
                }
                guard active else { throw CancellationError() }
                if engine == nil { try initializeEngine() }
                try queuePendingChanges()
                guard let current = engine else { throw CancellationError() }
                do {
                    currentFlow = .fetch
                    try await current.fetchChanges()
                    guard active else { throw CancellationError() }
                    if let failure { throw failure }
                    if zoneRecovery != nil { continue }
                    try queuePendingChanges()
                    currentFlow = .send
                    try await current.sendChanges()
                    guard active else { throw CancellationError() }
                    if let failure { throw failure }
                    if zoneRecovery != nil { continue }
                    return
                } catch {
                    // A missing zone replaces the engine after the current delegate
                    // callback returns. Its canceled old operation is then retried.
                    if active, zoneRecovery != nil { continue }
                    throw error
                }
            }
            throw CancellationError()
        } catch {
            if active {
                if let cloud = error as? CKError, CloudKitFailurePolicy.isRetryable(cloud.code) {
                    emit(progress.failed(currentFlow, message: cloud.localizedDescription))
                    emit(progress.finished(currentFlow, pending: (try? bridge.database.pendingRecords().count) ?? 1))
                } else if case CloudSyncError.noAccount = error {
                    emit(CloudKitSyncStatus(message: "Sync needs attention", error: error.localizedDescription))
                } else if !(error is CancellationError) {
                    failure = error
                    emit(CloudKitSyncStatus(message: "Sync paused", error: error.localizedDescription))
                }
            }
            throw error
        }
    }

    /// Called only by the explicit user action after a cloud-zone deletion.
    func recoverCloudData() async throws {
        guard active else { throw CancellationError() }
        guard try CloudKitReplicaState.isPaused(database: bridge.database, environment: environment) else { throw CloudKitRecoveryError.notPaused }
        try await bindAccount()
        zoneRecovery?.cancel(); zoneRecovery = nil
        let old = engine
        engine = nil
        engineGeneration += 1
        let generation = engineGeneration
        await old?.cancelOperations()
        guard active, generation == engineGeneration else { throw CancellationError() }
        cleanupAssets()
        inFlight.removeAll()
        _ = try CloudKitReplicaState.restoreLocalData(database: bridge.database, environment: environment,
                                                      backupDirectory: bridge.database.directory.appendingPathComponent("cloud-recovery-backups", isDirectory: true))
        failure = nil
        progress.abandonActiveFlows()
        try await synchronize()
    }

    private func bindAccount() async throws {
        guard active else { throw CancellationError() }
        let status = try await container.accountStatus()
        guard active else { throw CancellationError() }
        guard status == .available else { throw CloudSyncError.noAccount }
        let owner = try await container.userRecordID().recordName
        guard active else { throw CancellationError() }
        if let known = try bridge.database.metadata(forKey: environmentKey("cloudOwner")), known != Data(owner.utf8) {
            throw CloudSyncError.accountChanged
        }
        if let knownContainer = try bridge.database.metadata(forKey: "cloudContainer"),
           knownContainer != Data(container.containerIdentifier!.utf8) { throw CloudSyncError.containerChanged }
        if try bridge.database.metadata(forKey: "activeEnvironment") != Data(environment.utf8) {
            try bridge.database.enqueueAll()
        }
        try bridge.database.apply([], metadata: [environmentKey("cloudOwner"): Data(owner.utf8),
                                                "cloudContainer": Data(container.containerIdentifier!.utf8),
                                                "activeEnvironment": Data(environment.utf8)])
    }

    private func initializeEngine() throws {
        let serialization: CKSyncEngine.State.Serialization?
        if let data = try bridge.database.metadata(forKey: environmentKey("engineState")) {
            serialization = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } else { serialization = nil }
        let configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                      stateSerialization: serialization, delegate: self)
        engine = CKSyncEngine(configuration)
    }

    func queuePendingChanges() throws {
        guard active, failure == nil, let engine else { return }
        guard try !CloudKitReplicaState.isPaused(database: bridge.database, environment: environment) else { throw CloudSyncError.paused }
        let records = try bridge.database.pendingRecords()
        let needsZone = try bridge.database.metadata(forKey: environmentKey("zoneNeedsCreation")) != nil
        guard !records.isEmpty || needsZone else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: records.map { .saveRecord(CKRecord.ID(recordName: $0.id, zoneID: zoneID)) })
    }

    func stop() {
        active = false
        engineGeneration += 1
        zoneRecovery?.cancel(); zoneRecovery = nil
        let old = engine
        engine = nil
        let files = Array(assets.values)
        assets.removeAll(); inFlight.removeAll()
        Task {
            await old?.cancelOperations()
            for url in files { try? FileManager.default.removeItem(at: url) }
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard active, failure == nil, engine === syncEngine else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try bridge.database.setMetadata(JSONEncoder().encode(update.stateSerialization), forKey: environmentKey("engineState"))
            case .accountChange(let change):
                switch change.changeType {
                case .signOut, .switchAccounts: throw CloudSyncError.accountChanged
                case .signIn(let current):
                    if let known = try bridge.database.metadata(forKey: environmentKey("cloudOwner")), known != Data(current.recordName.utf8) {
                        throw CloudSyncError.accountChanged
                    }
                @unknown default: throw CloudSyncError.accountChanged
                }
                try queuePendingChanges()
            case .fetchedRecordZoneChanges(let changes):
                var records: [ReplicaRecord] = []
                var metadata: [String: Data] = [:]
                for item in changes.modifications where item.record.recordID.zoneID == zoneID {
                    let record = item.record
                    records.append(try decode(record))
                    metadata[systemKey(record.recordID.recordName)] = try systemFields(record)
                }
                let deletedIDs = changes.deletions.filter { $0.recordID.zoneID == zoneID }.map { $0.recordID.recordName }
                try bridge.receive(records, metadata: metadata)
                if !deletedIDs.isEmpty {
                    let removedFields = Dictionary(uniqueKeysWithValues: deletedIDs.map { (systemKey($0), Optional<Data>.none) })
                    try bridge.receiveDeletions(deletedIDs, metadata: removedFields)
                }
                try queuePendingChanges()
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    try CloudKitReplicaState.pauseAfterDeletion(database: bridge.database, environment: environment)
                    throw CloudSyncError.paused
                }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    try bridge.database.setMetadata(systemFields(record), forKey: systemKey(record.recordID.recordName))
                    if let sent = inFlight.removeValue(forKey: record.recordID.recordName) {
                        try bridge.database.acknowledge([sent])
                    }
                    removeAsset(record.recordID.recordName)
                }
                for failed in changes.failedRecordSaves {
                    let name = failed.record.recordID.recordName
                    inFlight.removeValue(forKey: name)
                    removeAsset(name)
                    switch failed.error.code {
                    case .serverRecordChanged:
                        guard let server = failed.error.serverRecord else { throw failed.error }
                        try bridge.receive([decode(server)], metadata: [systemKey(name): try systemFields(server)])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(server.recordID)])
                    case .zoneNotFound:
                        try rebuildZone(after: syncEngine)
                        return
                    case .unknownItem:
                        try CloudKitReplicaState.discardStaleRecord(database: bridge.database, environment: environment, recordID: name)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    default:
                        if CloudKitFailurePolicy.isRetryable(failed.error.code) {
                            emit(progress.failed(.send, message: failed.error.localizedDescription))
                        } else { throw failed.error }
                    }
                }
                try queuePendingChanges()
                emit(progress.pendingStatus(pending: try bridge.database.pendingRecords().count))
            case .sentDatabaseChanges(let changes):
                if changes.savedZones.contains(where: { $0.zoneID == zoneID }) {
                    try CloudKitReplicaState.recordZoneEstablished(database: bridge.database, environment: environment)
                    try bridge.database.setMetadata(nil, forKey: environmentKey("zoneNeedsCreation"))
                }
                for failed in changes.failedZoneSaves {
                    if CloudKitFailurePolicy.isRetryable(failed.error.code) {
                        emit(progress.failed(.send, message: failed.error.localizedDescription))
                    } else { throw failed.error }
                }
            case .willFetchChanges:
                emit(progress.begin(.fetch))
            case .willSendChanges:
                emit(progress.begin(.send))
            case .didFetchChanges:
                emit(progress.finished(.fetch, pending: try bridge.database.pendingRecords().count))
            case .didSendChanges:
                emit(progress.finished(.send, pending: try bridge.database.pendingRecords().count))
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error {
                    if error.code == .zoneNotFound {
                        try rebuildZone(after: syncEngine)
                        return
                    }
                    emit(progress.failed(.fetch, message: error.localizedDescription))
                } else if changes.zoneID == zoneID {
                    try CloudKitReplicaState.recordZoneEstablished(database: bridge.database, environment: environment)
                }
            case .willFetchRecordZoneChanges:
                break
            @unknown default: break
            }
        } catch {
            failure = error
            emit(CloudKitSyncStatus(message: "Sync paused", error: error.localizedDescription))
            // A failed merge must not let a later cursor advance past unsaved data.
            Task { await syncEngine.cancelOperations() }
        }
    }

    private func rebuildZone(after previous: CKSyncEngine) throws {
        guard zoneRecovery == nil else { return }
        try CloudKitReplicaState.rebuildMissingZone(database: bridge.database, environment: environment)
        engine = nil
        engineGeneration += 1
        let generation = engineGeneration
        inFlight.removeAll()
        let files = Array(assets.values)
        assets.removeAll()
        progress.abandonActiveFlows()
        emit(progress.pendingStatus(pending: try bridge.database.pendingRecords().count))
        zoneRecovery = Task { @MainActor [weak self] in
            // Never await cancelOperations inside its own delegate callback.
            await previous.cancelOperations()
            for url in files { try? FileManager.default.removeItem(at: url) }
            guard let self, self.active, self.engineGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            do {
                try await self.bindAccount()
                guard self.active, self.engineGeneration == generation, !Task.isCancelled else { throw CancellationError() }
                try self.initializeEngine()
                try self.queuePendingChanges()
            } catch {
                if self.active, self.engineGeneration == generation {
                    self.failure = error
                    self.emit(CloudKitSyncStatus(message: "Sync paused", error: error.localizedDescription))
                }
                throw error
            }
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                  syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard active, failure == nil, engine === syncEngine else { return nil }
        do {
            let records = try bridge.database.pendingRecords()
            var outbound: [CKRecord.ID: CKRecord] = [:]
            let pending = Set(records.map(\.id))
            let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
            for record in records {
                let id = CKRecord.ID(recordName: record.id, zoneID: zoneID)
                guard context.options.scope.contains(.saveRecord(id)) else { continue }
                let cloud: CKRecord
                if let data = try bridge.database.metadata(forKey: systemKey(record.id)) {
                    let coder = try NSKeyedUnarchiver(forReadingFrom: data)
                    coder.requiresSecureCoding = true
                    defer { coder.finishDecoding() }
                    guard let decoded = CKRecord(coder: coder), decoded.recordID == id else { throw ReplicaError.invalidRecord(record.id) }
                    cloud = decoded
                } else { cloud = CKRecord(recordType: "BistRecord", recordID: id) }
                let payload = try JSONEncoder().encode(record)
                if payload.count < 750_000 {
                    cloud["payload"] = payload as CKRecordValue
                    cloud["payloadAsset"] = nil
                } else {
                    let directory = bridge.database.directory.appendingPathComponent("outbound-assets", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(UUID().uuidString + ".json")
                    try payload.write(to: url, options: .atomic)
                    removeAsset(record.id)
                    assets[record.id] = url
                    cloud["payload"] = nil
                    cloud["payloadAsset"] = CKAsset(fileURL: url)
                }
                inFlight[record.id] = record
                outbound[id] = cloud
            }
            let batchChanges = changes.filter { change in
                switch change {
                case .saveRecord(let id): return pending.contains(id.recordName)
                case .deleteRecord: return false
                @unknown default: return false
                }
            }
            guard !batchChanges.isEmpty else { return nil }
            let prepared = outbound
            var batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: batchChanges) { prepared[$0] }
            batch?.atomicByZone = false
            return batch
        } catch {
            failure = error
            emit(CloudKitSyncStatus(message: "Sync paused", error: error.localizedDescription))
            return nil
        }
    }

    private func decode(_ record: CKRecord) throws -> ReplicaRecord {
        guard record.recordType == "BistRecord", record.recordID.zoneID == zoneID else { throw ReplicaError.invalidRecord(record.recordID.recordName) }
        let data: Data
        if let bytes = record["payload"] as? Data { data = bytes }
        else if let asset = record["payloadAsset"] as? CKAsset, let url = asset.fileURL { data = try Data(contentsOf: url) }
        else { throw ReplicaError.invalidRecord(record.recordID.recordName) }
        let value = try JSONDecoder().decode(ReplicaRecord.self, from: data)
        guard value.id == record.recordID.recordName else { throw ReplicaError.invalidRecord(value.id) }
        return value
    }

    private func systemFields(_ record: CKRecord) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }
    private func emit(_ status: CloudKitSyncStatus) {
        latestStatus = status
        stateChanged?(status.message, status.error)
    }
    private func environmentKey(_ key: String) -> String { environment + "." + key }
    private func systemKey(_ id: String) -> String { environmentKey("cloudRecord." + id) }
    private func removeAsset(_ id: String) {
        if let url = assets.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
    }
    private func cleanupAssets() {
        for id in Array(assets.keys) { removeAsset(id) }
    }
}

private enum CloudSyncError: Error, LocalizedError {
    case noAccount, accountChanged, containerChanged, paused
    var errorDescription: String? {
        switch self {
        case .noAccount: return "Sign in to iCloud in system settings, then try Sync now. Your changes are saved here."
        case .accountChanged: return "Sync paused because the iCloud account changed. Sign back in to the original account. Your local data is preserved."
        case .containerChanged: return "Sync paused because this build uses a different iCloud container. Open the build configured for your original data."
        case .paused: return "The iCloud data was removed. Your local copy is preserved. Choose Restore local data to iCloud to upload it again."
        }
    }
}

/// Keep CKSyncEngine alive for the failures it automatically retries.
enum CloudKitFailurePolicy {
    static func isRetryable(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkFailure, .networkUnavailable, .requestRateLimited, .notAuthenticated,
             .accountTemporarilyUnavailable, .zoneBusy, .serviceUnavailable, .operationCancelled: return true
        default: return false
        }
    }
}

/// A recovery backup contains portable records and the local-only snapshot.
struct CloudKitRecoveryBackup: Codable {
    let schemaVersion: Int
    let environment: String
    let records: [ReplicaRecord]
    let pendingRecordIDs: [String]
    let localSnapshot: Data?
    let noteVersions: [Data]
}

enum CloudKitRecoveryError: Error, LocalizedError {
    case paused, notPaused, invalidEnvironment
    var errorDescription: String? {
        switch self {
        case .paused: return "iCloud data was removed. Choose Restore local data to iCloud to upload your saved copy."
        case .notPaused: return "iCloud recovery is not needed. Use Sync now to refresh your data."
        case .invalidEnvironment: return "This build has an invalid iCloud environment. Check its signing configuration."
        }
    }
}

/// These transitions operate on real durable records, independently of network scheduling.
enum CloudKitReplicaState {
    static func isPaused(database: ReplicaDatabase, environment: String) throws -> Bool {
        try validateEnvironment(environment)
        return try database.metadata(forKey: environment + ".cloudPause") != nil
    }

    static func pauseAfterDeletion(database: ReplicaDatabase, environment: String) throws {
        try validateEnvironment(environment)
        try database.setMetadata(Data("zone removed".utf8), forKey: environment + ".cloudPause")
    }

    static func recordZoneEstablished(database: ReplicaDatabase, environment: String) throws {
        try validateEnvironment(environment)
        try database.setMetadata(Data("1".utf8), forKey: environment + ".cloudZoneEstablished")
    }

    static func rebuildMissingZone(database: ReplicaDatabase, environment: String) throws {
        guard try !isPaused(database: database, environment: environment) else { throw CloudKitRecoveryError.paused }
        let established = try database.metadata(forKey: environment + ".cloudZoneEstablished") != nil
        // Cached server revisions also prove establishment for an upgraded build
        // that predates the explicit marker.
        let records = try database.records()
        let hasServerRecords = try records.contains {
            try database.metadata(forKey: environment + ".cloudRecord." + $0.id) != nil
        }
        if established || hasServerRecords {
            try pauseAfterDeletion(database: database, environment: environment)
            throw CloudKitRecoveryError.paused
        }
        try resetZone(database: database, environment: environment, clearPause: false)
    }

    static func discardStaleRecord(database: ReplicaDatabase, environment: String, recordID: String) throws {
        try validateEnvironment(environment)
        // An unknownItem save failure proves only that the cached server revision
        // is stale. Actual fetched deletions take the separate deletion path.
        try database.setMetadata(nil, forKey: environment + ".cloudRecord." + recordID)
    }

    @discardableResult
    static func restoreLocalData(database: ReplicaDatabase, environment: String, backupDirectory: URL) throws -> URL {
        guard try isPaused(database: database, environment: environment) else { throw CloudKitRecoveryError.notPaused }
        let records = try database.records()
        let backup = CloudKitRecoveryBackup(schemaVersion: 1, environment: environment, records: records,
                                             pendingRecordIDs: try database.pendingRecords().map(\.id),
                                             localSnapshot: try database.metadata(forKey: "localSnapshot"),
                                             noteVersions: try database.recoverableValues(recordID: "note.main", field: "text"))
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = backupDirectory.appendingPathComponent(UUID().uuidString.lowercased() + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(backup).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A crash before the following transition leaves the pause in place.
        // The backup has already been published before anything can be uploaded.
        try resetZone(database: database, environment: environment, clearPause: true)
        try database.setMetadata(Data(url.path.utf8), forKey: environment + ".cloudRecoveryBackup")
        return url
    }

    private static func resetZone(database: ReplicaDatabase, environment: String, clearPause: Bool) throws {
        try validateEnvironment(environment)
        let records = try database.records()
        var metadata: [String: Data?] = [environment + ".engineState": nil,
                                         environment + ".cloudZoneEstablished": nil,
                                         environment + ".zoneNeedsCreation": Data("1".utf8)]
        if clearPause { metadata.updateValue(nil, forKey: environment + ".cloudPause") }
        for record in records { metadata.updateValue(nil, forKey: environment + ".cloudRecord." + record.id) }
        // Requeue first. A crash can cause a harmless retry but cannot clear the
        // cursor while losing acknowledged local records from the outbox.
        try database.enqueueAll()
        try database.apply([], metadata: metadata)
    }

    private static func validateEnvironment(_ environment: String) throws {
        guard environment == "Development" || environment == "Production" else {
            throw CloudKitRecoveryError.invalidEnvironment
        }
    }
}

struct CloudKitSyncStatus {
    let message: String
    let error: String?
}

/// Only completed, successful work with no outstanding records establishes success.
struct CloudKitProgressState {
    enum Flow: Hashable { case fetch, send }
    private var running = Set<Flow>()
    private var failedFlows = Set<Flow>()
    private(set) var error: String?

    mutating func begin(_ flow: Flow) -> CloudKitSyncStatus {
        running.insert(flow)
        failedFlows.remove(flow)
        return CloudKitSyncStatus(message: "Syncing…", error: error)
    }

    mutating func failed(_ flow: Flow, message: String) -> CloudKitSyncStatus {
        failedFlows.insert(flow)
        error = message
        return CloudKitSyncStatus(message: "Changes waiting to sync", error: error)
    }

    mutating func finished(_ flow: Flow, pending: Int) -> CloudKitSyncStatus {
        let succeeded = !failedFlows.contains(flow)
        running.remove(flow)
        if succeeded && pending == 0 && running.isEmpty && failedFlows.isEmpty {
            error = nil
            failedFlows.removeAll()
            return CloudKitSyncStatus(message: "Up to date", error: nil)
        }
        return pendingStatus(pending: pending)
    }

    func pendingStatus(pending: Int) -> CloudKitSyncStatus {
        if let error {
            return CloudKitSyncStatus(message: pending > 0 ? "Changes waiting to sync" : "Sync needs attention", error: error)
        }
        return CloudKitSyncStatus(message: running.isEmpty ? "Changes waiting to sync" : "Syncing…", error: nil)
    }

    mutating func abandonActiveFlows() {
        running.removeAll()
        failedFlows.removeAll()
    }
}
