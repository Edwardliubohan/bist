import Foundation
import Combine
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private struct ReplicaPlacement: Codable {
    var parentID: UUID?
    var horizon: TaskHorizon
}

private struct ReplicaCompletion: Codable {
    var completed: Bool
    var completedAt: Date?
}

/// Portable task data and its durable outbox share a SQLite transaction. The
/// current AppStore remains the single task-rule implementation on both devices.
@MainActor
final class BistReplicaBridge {
    let database: ReplicaDatabase
    let backupDirectory: URL
    private let store: AppStore
    private let note: NoteStore
    private var projectedTaskIDs = Set<UUID>()
    private var projectedLabelIDs = Set<UUID>()
    private var labelAliases: [UUID: UUID] = [:]
    // Keep alias provenance for the lifetime of local Undo, including a fetch
    // that leaves the currently deleted label invisible.
    private var knownLabelAliases: [UUID: UUID] = [:]
    private var projectedSnapshot: BistSnapshot?
    private var noteProjectionAllowed = false
    var didChange: (() -> Void)?

    init(store: AppStore, note: NoteStore) throws {
        let directory = store.directory.appendingPathComponent("sync", isDirectory: true)
        let hasReplica = FileManager.default.fileExists(atPath: directory.appendingPathComponent("sync.sqlite").path)
        guard hasReplica || (store.storeError == nil && store.prepareForAuxiliaryWrite()) else {
            throw ReplicaError.storage("Repair local data before opening sync")
        }
        self.store = store
        self.note = note
        database = try ReplicaDatabase(directory: directory)
        backupDirectory = directory.appendingPathComponent("legacy-backup", isDirectory: true)
        if try database.metadata(forKey: "migration") == nil {
            guard store.storeError == nil else { throw ReplicaError.storage("Repair the legacy task file before migration") }
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            for name in ["state.json", "note.txt"] {
                let source = store.directory.appendingPathComponent(name)
                let backup = backupDirectory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: source, to: backup)
                }
            }
            // Every installation starts from the same low seed revision. Only
            // actual user edits create device-authored revisions. Omitted
            // defaults in an existing store are explicit deletions.
            let seed = ReplicaStamp(counter: 1, deviceID: "bist-default-labels-v1")
            let seedRecords = try TaskLabel.defaults.enumerated().map { index, label in
                ReplicaRecord(id: Self.labelID(label.id), kind: "label", fields: [
                    "name": ReplicaField(value: try Self.encode(label.name), stamp: seed),
                    "color": ReplicaField(value: try Self.encode(label.color), stamp: seed),
                    "order": ReplicaField(value: try Self.encode(index), stamp: seed)
                ])
            }
            try database.merge(remote: seedRecords)
            projectedTaskIDs = Set(store.tasks.filter { !$0.isSample }.map(\.id))
            projectedLabelIDs = Set(store.labels.map(\.id))
            var mutations: [ReplicaMutation] = TaskLabel.defaults.filter { !projectedLabelIDs.contains($0.id) }.map { .delete(id: Self.labelID($0.id)) }
            mutations += try snapshotMutations(store.currentSnapshot, restoring: false)
            // Notes import separately so a rejected note cannot block task
            // migration or advance the note's physical-export baseline.
            try database.apply(mutations, metadata: ["migration": Data("1".utf8),
                                                     "localSnapshot": try Self.encodeSnapshot(store.currentSnapshot)])
        }
        note.didExportText = { [weak self] bytes in
            try? self?.database.setMetadata(bytes, forKey: "noteExport")
        }
        try importDiskNote()
        try project()
        store.persistSnapshot = { [weak self] value, restoring in
            guard let self else { throw ReplicaError.storage("Replica unavailable") }
            let mutations = try self.snapshotMutations(value, restoring: restoring)
            try self.database.apply(mutations, metadata: ["localSnapshot": try Self.encodeSnapshot(value)])
            self.projectedTaskIDs = Set(value.tasks.filter { !$0.isSample }.map(\.id))
            self.projectedLabelIDs = Set(value.labels.map(\.id))
            self.projectedSnapshot = value
            self.didChange?()
        }
        store.reloadPersistedSnapshot = { [weak self] in
            guard let self else { throw ReplicaError.storage("Replica unavailable") }
            try self.reload()
        }
        note.persistText = { [weak self] text in
            guard let self else { throw ReplicaError.storage("Replica unavailable") }
            try self.database.mutate(recordID: "note.main", kind: "note", values: ["text": try Self.encode(text)])
            self.noteProjectionAllowed = true
            self.didChange?()
        }
    }

    func reload() throws {
        try importDiskNote()
        try project()
    }

    private func importDiskNote() throws {
        // An import failure must keep the external file protected through later
        // receives too. Only accepted content can become a derived export.
        noteProjectionAllowed = false
        var encodedSize = 0
        do {
            let snapshot = try note.readableDiskSnapshot()
            guard let diskText = snapshot.text, let bytes = snapshot.bytes else {
                noteProjectionAllowed = note.acceptReplicaFile(snapshot, preservingAcceptedText: true) || note.hasUnsavedDraft
                return
            }
            guard try database.metadata(forKey: "noteExport") != bytes else {
                // These bytes are a proven export. Trust only that snapshot,
                // without rereading and trusting a different external file.
                noteProjectionAllowed = note.acceptReplicaFile(snapshot, preservingAcceptedText: true) || note.hasUnsavedDraft
                return
            }
            // A readable external edit is a real local revision. Remember the
            // old canonical text in recovery before adopting the file.
            let encoded = try Self.encode(diskText)
            encodedSize = encoded.count
            try database.apply([.set(id: "note.main", kind: "note", values: ["text": encoded])],
                               metadata: ["noteExport": bytes])
            noteProjectionAllowed = note.acceptReplicaFile(snapshot) || note.hasUnsavedDraft
        } catch {
            note.reportReplicaFailure(error, exceedsSyncLimit: encodedSize > 16 * 1024 * 1024)
        }
    }

    func receive(_ records: [ReplicaRecord], metadata: [String: Data] = [:]) throws {
        for record in records { try validate(record) }
        try database.merge(remote: records, metadata: metadata)
        try project()
        didChange?()
    }

    func receiveDeletions(_ ids: [String], metadata: [String: Data?] = [:]) throws {
        let known = Set(try database.records().map(\.id))
        var mutations: [ReplicaMutation] = []
        for id in ids where known.contains(id) {
            // The scratchpad is a singleton. A server deletion means clear its
            // text, preserving the old draft in recovery rather than deleting
            // the record that every future edit needs.
            if id == "note.main" {
                mutations.append(.set(id: id, kind: "note", values: ["text": try Self.encode("")]))
            } else { mutations.append(.delete(id: id)) }
        }
        try database.apply(mutations, metadata: metadata)
        try project()
        didChange?()
    }

    func noteVersions() throws -> [String] {
        try database.recoverableValues(recordID: "note.main", field: "text").map {
            try JSONDecoder().decode(String.self, from: $0)
        }
    }

    private func snapshotMutations(_ value: BistSnapshot, restoring: Bool) throws -> [ReplicaMutation] {
        let records = try database.records()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var result: [ReplicaMutation] = []
        let taskIDs = Set(value.tasks.filter { !$0.isSample }.map(\.id))
        let labelIDs = Set(value.labels.map(\.id))
        let previousPortable = projectedSnapshot?.tasks.filter { !$0.isSample } ?? []
        let portable = value.tasks.filter { !$0.isSample }
        let taskOrderChanged = previousPortable.map(\.id) != portable.map(\.id)
        let labelOrderChanged = projectedSnapshot?.labels.map(\.id) != value.labels.map(\.id)
        for id in projectedTaskIDs.subtracting(taskIDs) { result.append(.delete(id: Self.taskID(id))) }
        for id in projectedLabelIDs.subtracting(labelIDs) {
            result.append(.delete(id: Self.labelID(id)))
            for (alias, canonical) in knownLabelAliases where canonical == id && alias != id {
                result.append(.delete(id: Self.labelID(alias)))
            }
        }
        for (index, label) in value.labels.enumerated() {
            let id = Self.labelID(label.id)
            if byID[id]?.isDeleted == true, restoring { result.append(.restore(id: id)) }
            let prior = projectedSnapshot?.labels.first { $0.id == label.id }
            var fields: [String: Data] = [:]
            if prior?.name != label.name { fields["name"] = try Self.encode(label.name) }
            if prior?.color != label.color { fields["color"] = try Self.encode(label.color) }
            let order = try Self.encode(index)
            if labelOrderChanged && byID[id]?.fields["order"]?.value != order {
                fields["order"] = order
            }
            if !fields.isEmpty {
                result.append(.set(id: id, kind: "label", values: fields))
                // A displayed duplicate tag represents all of its source IDs.
                // Rename those aliases together so they cannot reappear later.
                for (alias, canonical) in knownLabelAliases where canonical == label.id && alias != label.id {
                    let aliasID = Self.labelID(alias)
                    if byID[aliasID]?.isDeleted == true {
                        if restoring { result.append(.restore(id: aliasID)) }
                        else { continue }
                    }
                    let sharedFields = fields.filter { $0.key != "order" }
                    if !sharedFields.isEmpty { result.append(.set(id: aliasID, kind: "label", values: sharedFields)) }
                }
            }
        }
        for (index, task) in portable.enumerated() {
            let id = Self.taskID(task.id)
            if byID[id]?.isDeleted == true, restoring { result.append(.restore(id: id)) }
            let values = try Self.taskFields(task, index: index)
            let priorFields: [String: Data]
            if let previous = previousPortable.firstIndex(where: { $0.id == task.id }) {
                priorFields = try Self.taskFields(previousPortable[previous], index: previous)
            } else { priorFields = [:] }
            var changed = values.filter { priorFields[$0.key] != $0.value }
            // A projection can contain gaps from concurrent edits. When the
            // person changes this list, compact every stored order to match
            // the order they see, including rows whose local index stayed put.
            if taskOrderChanged && byID[id]?.fields["order"]?.value != values["order"] {
                changed["order"] = values["order"]
            }
            if !changed.isEmpty { result.append(.set(id: id, kind: "task", values: changed)) }
        }
        return result
    }

    private static func taskFields(_ task: TaskItem, index: Int) throws -> [String: Data] {
        ["title": try encode(task.title), "notes": try encode(task.notes),
         "nextAction": try encode(task.nextAction), "createdAt": try encode(task.createdAt),
         "lane": try encode(task.lane), "labelIDs": try encode(task.labelIDs),
         "completion": try encode(ReplicaCompletion(completed: task.completed, completedAt: task.completedAt)),
         "placement": try encode(ReplicaPlacement(parentID: task.parentID, horizon: task.horizon)),
         "order": try encode(index)]
    }

    private func project() throws {
        let records = try database.records()
        for record in records { try validate(record) }
        let local: BistSnapshot
        if let data = try database.metadata(forKey: "localSnapshot") { local = try Self.decodeSnapshot(data) }
        else { local = store.currentSnapshot }
        let localTasks = Dictionary(uniqueKeysWithValues: local.tasks.map { ($0.id, $0) })
        let live = records.filter { !$0.isDeleted }
        // Concurrently created labels with the same name share one displayed ID.
        // The underlying records remain intact, allowing either delivery order.
        var labels: [TaskLabel] = []
        var canonicalByName: [String: UUID] = [:]
        var labelOrders: [UUID: Int] = [:]
        labelAliases = [:]
        for record in live.filter({ $0.kind == "label" }).sorted(by: { $0.id < $1.id }) {
            let id = try Self.uuid(record, prefix: "label.")
            let name: String = try Self.field(record, "name")
            let color: TaskLabelColor = try Self.field(record, "color")
            let order: Int = try Self.field(record, "order")
            if let canonical = canonicalByName[name.lowercased()] { labelAliases[id] = canonical }
            else {
                canonicalByName[name.lowercased()] = id; labelAliases[id] = id
                labelOrders[id] = order
                labels.append(TaskLabel(id: id, name: name, color: color))
            }
        }
        knownLabelAliases.merge(labelAliases) { _, current in current }
        labels.sort { (labelOrders[$0.id] ?? 0, $0.id.uuidString) < (labelOrders[$1.id] ?? 0, $1.id.uuidString) }
        var tasks: [TaskItem] = []
        var orders: [UUID: Int] = [:]
        for record in live where record.kind == "task" {
            let id = try Self.uuid(record, prefix: "task.")
            var task = localTasks[id] ?? TaskItem(id: id, title: "")
            task.title = try Self.field(record, "title")
            task.notes = try Self.field(record, "notes")
            task.nextAction = try Self.field(record, "nextAction")
            task.createdAt = try Self.field(record, "createdAt")
            task.lane = try Self.field(record, "lane")
            let tags: [UUID] = try Self.field(record, "labelIDs")
            task.labelIDs = canonicalLabels(tags)
            let completion: ReplicaCompletion = try Self.field(record, "completion")
            task.completed = completion.completed; task.completedAt = completion.completedAt
            let placement: ReplicaPlacement = try Self.field(record, "placement")
            task.parentID = placement.parentID; task.horizon = placement.horizon
            orders[id] = try Self.field(record, "order")
            tasks.append(task)
        }
        tasks.sort { (orders[$0.id] ?? 0, $0.id.uuidString) < (orders[$1.id] ?? 0, $1.id.uuidString) }
        // Samples occupy local slots without changing the coordinate system
        // used by portable rows on devices that have no samples.
        for (index, sample) in local.tasks.enumerated() where sample.isSample {
            var sample = sample
            sample.labelIDs = canonicalLabels(sample.labelIDs)
            tasks.insert(sample, at: min(index, tasks.count))
        }
        // Parent and child records may arrive out of order. Missing parents are
        // displayed at root until they arrive. Break cycles at the largest UUID.
        let ids = Set(tasks.map(\.id))
        var parents = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.parentID.flatMap { ids.contains($0) ? $0 : nil }) })
        for task in tasks {
            var visited: [UUID] = []
            var current: UUID? = task.id
            while let id = current {
                if let start = visited.firstIndex(of: id) {
                    let cut = visited[start...].max { $0.uuidString < $1.uuidString }!
                    parents[cut] = .some(nil)
                    break
                }
                visited.append(id)
                current = parents[id] ?? nil
            }
        }
        let horizons = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.horizon) })
        for index in tasks.indices {
            tasks[index].parentID = parents[tasks[index].id] ?? nil
            var root = tasks[index].id
            while let parent = parents[root] ?? nil { root = parent }
            tasks[index].horizon = horizons[root] ?? tasks[index].horizon
        }
        let value = BistSnapshot(tasks: tasks, sessions: local.sessions, labels: labels)
        try store.validateReplicaSnapshot(value)
        try store.applyReplicaSnapshot(value)
        projectedSnapshot = value
        projectedTaskIDs = Set(tasks.filter { !$0.isSample }.map(\.id))
        projectedLabelIDs = Set(labels.map(\.id))
        if noteProjectionAllowed, let record = live.first(where: { $0.id == "note.main" }) {
            let text: String = try Self.field(record, "text")
            _ = try note.applyReplicaText(text)
        }
    }

    private func canonicalLabels(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.compactMap { labelAliases[$0] }.filter { seen.insert($0).inserted }
    }

    private func validate(_ record: ReplicaRecord) throws {
        switch record.kind {
        case "task":
            _ = try Self.uuid(record, prefix: "task.")
            guard !record.fields.isEmpty || record.isDeleted else { throw ReplicaError.invalidRecord(record.id) }
            if !record.isDeleted {
                let title: String = try Self.field(record, "title")
                let notes: String = try Self.field(record, "notes")
                let next: String = try Self.field(record, "nextAction")
                let date: Date = try Self.field(record, "createdAt")
                let _: TaskLane = try Self.field(record, "lane")
                let tags: [UUID] = try Self.field(record, "labelIDs")
                let completion: ReplicaCompletion = try Self.field(record, "completion")
                let _: ReplicaPlacement = try Self.field(record, "placement")
                let _: Int = try Self.field(record, "order")
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 240,
                      notes.count <= 8000, next.count <= 2000, date.timeIntervalSince1970.isFinite,
                      Set(tags).count == tags.count, completion.completed || completion.completedAt == nil,
                      completion.completedAt?.timeIntervalSince1970.isFinite ?? true,
                      Set(record.fields.keys) == Set(["title", "notes", "nextAction", "createdAt", "lane", "labelIDs", "completion", "placement", "order"]) else { throw ReplicaError.invalidRecord(record.id) }
            }
        case "label":
            _ = try Self.uuid(record, prefix: "label.")
            if !record.isDeleted {
                let name: String = try Self.field(record, "name")
                let _: TaskLabelColor = try Self.field(record, "color")
                let _: Int = try Self.field(record, "order")
                guard !name.isEmpty, name.count <= 40,
                      name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                      name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil,
                      Set(record.fields.keys) == Set(["name", "color", "order"]) else { throw ReplicaError.invalidRecord(record.id) }
            }
        case "note":
            guard record.id == "note.main", !record.isDeleted, Set(record.fields.keys) == Set(["text"]) else { throw ReplicaError.invalidRecord(record.id) }
            let _: String = try Self.field(record, "text")
        default: throw ReplicaError.invalidRecord(record.id)
        }
    }

    private static func taskID(_ id: UUID) -> String { "task." + id.uuidString.lowercased() }
    private static func labelID(_ id: UUID) -> String { "label." + id.uuidString.lowercased() }
    private static func uuid(_ record: ReplicaRecord, prefix: String) throws -> UUID {
        guard record.id.hasPrefix(prefix), let id = UUID(uuidString: String(record.id.dropFirst(prefix.count))),
              record.id == prefix + id.uuidString.lowercased() else { throw ReplicaError.invalidRecord(record.id) }
        return id
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private static func field<T: Decodable>(_ record: ReplicaRecord, _ name: String) throws -> T {
        guard let data = record.fields[name]?.value else { throw ReplicaError.invalidRecord(record.id) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private static func encodeSnapshot(_ value: BistSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { try BistDateCoding.encode($0, to: $1) }
        return try encoder.encode(value)
    }
    private static func decodeSnapshot(_ data: Data) throws -> BistSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try BistDateCoding.decode($0) }
        return try decoder.decode(BistSnapshot.self, from: data)
    }
}

enum BistSyncBackend: String, CaseIterable, Identifiable {
    case supabase, iCloud
    var id: String { rawValue }
    var title: String { self == .supabase ? "Supabase" : "iCloud" }
}

@MainActor
final class BistSyncCoordinator: ObservableObject {
    @Published private(set) var status = "Saved on this device"
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var enabled = false
    @Published private(set) var isAvailable = false
    @Published private(set) var noteVersions: [String] = []
    @Published private(set) var recoveryRequired = false
    @Published private(set) var backend: BistSyncBackend = .supabase
    let supabaseAccount: SupabaseAccountController
    private var bridge: BistReplicaBridge?
    private var transport: CloudKitReplicaTransport?
    private var supabaseTransport: SupabaseReplicaTransport?
    private var pollingTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var activeSupabaseTask: Task<Void, Error>?
    private var foreground = true
    private let settingsURL: URL
    private let backendURL: URL
    private let store: AppStore
    private let note: NoteStore
    private let containerID: String?
    private let supabaseRelayFactory: (SupabaseConfiguration) -> any SupabaseRelayAPI
    private var refreshGeneration = 0
    private var activeRefreshGeneration: Int?

    init(store: AppStore, note: NoteStore, useBundledSupabaseDefaults: Bool = true,
         supabaseSessions: any SupabaseSessionStore = KeychainSupabaseSessionStore(),
         supabaseRelayFactory: @escaping (SupabaseConfiguration) -> any SupabaseRelayAPI = { SupabaseRelayClient(configuration: $0) }) {
        self.store = store; self.note = note
        self.supabaseRelayFactory = supabaseRelayFactory
        settingsURL = store.directory.appendingPathComponent("sync-enabled")
        backendURL = store.directory.appendingPathComponent("sync-backend")
        supabaseAccount = SupabaseAccountController(directory: store.directory, sessions: supabaseSessions, useBundledDefaults: useBundledSupabaseDefaults)
        let configured = Bundle.main.object(forInfoDictionaryKey: "BistCloudKitContainer") as? String ?? ""
        containerID = CloudKitReplicaTransport.configuredContainer(configured)
        let selected = (try? String(contentsOf: backendURL, encoding: .utf8)).flatMap(BistSyncBackend.init(rawValue:))
        backend = selected ?? (containerID != nil ? .iCloud : .supabase)
        refreshAvailability()
        enabled = canEnable && enabledScope != nil && (try? Data(contentsOf: settingsURL)) == enabledScope.map { Data($0.utf8) }
        do { try attachLocalStorage() }
        catch {
            self.error = error.localizedDescription; status = "Local data needs attention"
            let failure = error
            store.persistSnapshot = { _, _ in throw failure }
            // An unreadable note is independent of task storage. Keep its own
            // recovery path instead of replacing it with a permanent failure.
            if note.isReadable { note.persistText = { _ in throw failure } }
        }
        store.reloadPersistedSnapshot = { [weak self] in
            guard let self else { throw ReplicaError.storage("Replica unavailable") }
            try self.retryLocalStorage()
        }
        supabaseAccount.willChange = { [weak self] in
            guard self?.backend == .supabase else { return }
            self?.setEnabled(false)
            self?.lastSyncedAt = nil
        }
        supabaseAccount.didChange = { [weak self] in
            self?.refreshAvailability(); self?.updateSummary()
        }
        if enabled { startPolling(); Task { await refresh() } }
    }

    deinit { pollingTask?.cancel(); changeTask?.cancel(); activeSupabaseTask?.cancel() }

    var cloudNotificationsEnabled: Bool { backend == .iCloud && enabled && isAvailable }
    var canEnable: Bool { isAvailable && (backend == .iCloud || supabaseAccount.session != nil) }
    private var supabaseScope: String? {
        guard let config = supabaseAccount.configuration, let session = supabaseAccount.session else { return nil }
        return config.scope + "|" + session.userID.uuidString.lowercased()
    }
    private var enabledScope: String? {
        backend == .iCloud ? containerID.map(CloudKitReplicaTransport.scopeIdentifier) : supabaseScope.map { "supabase|" + $0 }
    }
    var accountMergeRequired: Bool {
        guard backend == .supabase, let bridge, let scope = supabaseScope,
              let binding = try? bridge.database.metadata(forKey: SupabaseReplicaTransport.bindingKey) else { return false }
        return binding != Data(scope.utf8)
    }
    private func refreshAvailability() {
        isAvailable = backend == .iCloud ? containerID != nil : supabaseAccount.configuration != nil
    }
    func setBackend(_ value: BistSyncBackend) {
        guard value != backend else { return }
        setEnabled(false)
        do {
            try Data(value.rawValue.utf8).write(to: backendURL, options: .atomic)
            backend = value; recoveryRequired = false; lastSyncedAt = nil
            refreshAvailability(); updateSummary()
        } catch { self.error = error.localizedDescription }
    }
    func authorizeSupabaseAccountChange() {
        guard let bridge, let scope = supabaseScope else { return }
        do {
            setEnabled(false)
            try SupabaseReplicaTransport.authorizeConnection(bridge: bridge, scope: scope)
            error = nil
            setEnabled(true)
        } catch { self.error = error.localizedDescription }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { startPolling() }
        else {
            pollingTask?.cancel(); pollingTask = nil
            changeTask?.cancel(); changeTask = nil
            if let operation = activeSupabaseTask {
                operation.cancel(); activeSupabaseTask = nil
                // The app can return before URLSession unwinds cancellation.
                // Retire the old generation so its late cleanup cannot block
                // or overwrite a fresh foreground exchange.
                supabaseTransport?.stop(); supabaseTransport = nil
                refreshGeneration += 1; activeRefreshGeneration = nil
                error = nil; status = "Waiting to sync"
                updateSummary()
            }
        }
    }
    private func startPolling() {
        guard backend == .supabase, enabled, foreground, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func attachLocalStorage() throws {
        let bridge = try BistReplicaBridge(store: store, note: note)
        self.bridge = bridge
        bridge.didChange = { [weak self] in self?.localChange() }
        error = nil
        updateSummary()
    }

    private func retryLocalStorage() throws {
        if let bridge { try bridge.reload() }
        else {
            // The legacy reader is used only while authority has not attached.
            // No user action can run between this synchronous read and attach.
            guard store.reloadLegacySnapshot() else { throw ReplicaError.storage("Repair the local task file and retry") }
            try attachLocalStorage()
        }
        error = nil
        updateSummary()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled, !value || canEnable else { return }
        if value && accountMergeRequired { error = SupabaseSyncError.accountChanged.localizedDescription; return }
        // Disconnection must take effect immediately, even if a full or broken
        // data directory prevents updating the preference file.
        if !value {
            activeSupabaseTask?.cancel(); activeSupabaseTask = nil
            enabled = false; refreshGeneration += 1; activeRefreshGeneration = nil
            transport?.stop(); transport = nil; supabaseTransport?.stop(); supabaseTransport = nil
            pollingTask?.cancel(); pollingTask = nil; changeTask?.cancel(); changeTask = nil
            status = "Saved on this device"
        }
        do {
            if value, let scope = enabledScope {
                // One selected provider owns ACKs. Requeue canonical records
                // when connecting so a previous backend's ACK cannot omit them.
                try bridge?.database.enqueueAll()
                try Data(scope.utf8).write(to: settingsURL, options: .atomic)
            }
            else if FileManager.default.fileExists(atPath: settingsURL.path) { try FileManager.default.removeItem(at: settingsURL) }
            enabled = value
            refreshGeneration += 1
            activeRefreshGeneration = nil
            error = nil
            if value {
                if backend == .iCloud {
                #if os(macOS)
                NSApplication.shared.registerForRemoteNotifications()
                #elseif os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #endif
                }
                startPolling()
                Task { await refresh() }
            }
            else { transport?.stop(); transport = nil; status = "Saved on this device" }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async { await performSync(recovering: false) }

    func recoverCloudData() async {
        guard recoveryRequired else { return }
        activeSupabaseTask?.cancel(); activeSupabaseTask = nil
        transport?.stop(); transport = nil
        supabaseTransport?.stop(); supabaseTransport = nil
        refreshGeneration += 1
        activeRefreshGeneration = nil
        await performSync(recovering: true)
    }

    private func performSync(recovering: Bool) async {
        if backend == .supabase { await performSupabaseSync(recovering: recovering); return }
        guard enabled, let bridge, let containerID,
              activeRefreshGeneration != refreshGeneration else { updateSummary(); return }
        let generation = refreshGeneration
        activeRefreshGeneration = generation
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #elseif os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        defer { if activeRefreshGeneration == generation { activeRefreshGeneration = nil } }
        do {
            if transport?.needsRestart == true { transport?.stop(); transport = nil }
            if transport == nil {
                let transport = try CloudKitReplicaTransport(bridge: bridge, containerID: containerID)
                transport.stateChanged = { [weak self] message, failure in
                    guard let self, self.enabled, self.refreshGeneration == generation else { return }
                    self.status = message; self.error = failure
                    if message == "Up to date" { self.lastSyncedAt = Date() }
                    self.updateSummary()
                }
                self.transport = transport
            }
            let currentTransport = transport
            if recovering { try await currentTransport?.recoverCloudData() }
            else { try await currentTransport?.synchronize() }
            guard enabled, generation == refreshGeneration else { return }
            if let progress = currentTransport?.latestStatus {
                status = progress.message; error = progress.error
                if progress.message == "Up to date", progress.error == nil { lastSyncedAt = Date() }
            }
            updateSummary()
        } catch {
            guard generation == refreshGeneration else { return }
            if transport?.needsRestart == true { transport?.stop(); transport = nil }
            self.error = error.localizedDescription
            status = transport == nil ? "Sync needs attention" : "Changes waiting to sync"
            updateSummary()
        }
    }

    func syncNow() async { await refresh() }

    private func performSupabaseSync(recovering: Bool) async {
        guard enabled, foreground, let bridge, let configuration = supabaseAccount.configuration, let scope = supabaseScope,
              activeRefreshGeneration != refreshGeneration else { updateSummary(); return }
        let generation = refreshGeneration
        activeRefreshGeneration = generation
        defer {
            if activeRefreshGeneration == generation {
                activeRefreshGeneration = nil; activeSupabaseTask = nil
            }
        }
        do {
            if supabaseTransport == nil {
                supabaseTransport = try SupabaseReplicaTransport(bridge: bridge, scope: scope,
                    relay: supabaseRelayFactory(configuration),
                    credentials: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await self.supabaseAccount.accessToken()
                    }, isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.enabled && self.backend == .supabase && self.refreshGeneration == generation && self.supabaseScope == scope
                    })
            }
            guard let current = supabaseTransport else { return }
            status = "Syncing with Supabase…"; error = nil
            if recovering { try current.authorizeRecovery() }
            let account = supabaseAccount
            let operation = Task {
                do { try await current.synchronize() }
                catch SupabaseSyncError.signInRequired {
                    try Task.checkCancellation()
                    _ = try await account.refreshSession()
                    try Task.checkCancellation()
                    try await current.synchronize()
                }
            }
            activeSupabaseTask = operation
            try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
            guard enabled, backend == .supabase, generation == refreshGeneration else { return }
            lastSyncedAt = Date(); error = nil; recoveryRequired = false
            status = "Up to date"
            updateSummary()
        } catch {
            guard generation == refreshGeneration, enabled, backend == .supabase else { return }
            // Leaving the foreground can cancel an in-flight URLSession poll.
            // That is expected control flow, not an account or sync failure.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            self.error = cancelled ? nil : error.localizedDescription
            recoveryRequired = supabaseTransport?.recoveryRequired ?? false
            status = recoveryRequired ? "Sync paused" : cancelled ? "Waiting to sync" : "Changes waiting to sync"
            updateSummary()
        }
    }

    func restoreNoteVersion(_ text: String) {
        note.update(text)
        updateSummary()
    }

    private func localChange() {
        updateSummary()
        guard enabled else { return }
        if backend == .supabase {
            changeTask?.cancel()
            changeTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                // Only pending debounce sleeps are replaceable. Remote merges
                // also call localChange, so release this handle before sync
                // starts or the sync would cancel itself on the first page.
                self?.changeTask = nil
                await self?.refresh()
            }
            return
        }
        do { try transport?.queuePendingChanges() }
        catch { self.error = error.localizedDescription; status = "Sync needs attention" }
    }

    private func updateSummary() {
        guard let bridge else { return }
        do {
            pendingCount = try bridge.database.pendingRecords().count
            recoveryRequired = backend == .iCloud
                ? try CloudKitReplicaTransport.recoveryRequired(in: bridge.database)
                : supabaseTransport?.recoveryRequired ?? false
            noteVersions = try bridge.noteVersions()
            if !enabled { status = "Saved on this device" }
            else if pendingCount > 0 && error == nil { status = "Changes waiting to sync" }
        } catch { self.error = error.localizedDescription }
    }
}
