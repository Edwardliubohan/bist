import Foundation
import CSQLite

/// Logical time has no dependency on either device's clock.
public struct ReplicaStamp: Codable, Equatable, Comparable, Sendable {
    public let counter: Int64
    public let deviceID: String

    public init(counter: Int64, deviceID: String) {
        self.counter = counter
        self.deviceID = deviceID
    }

    public static func < (lhs: ReplicaStamp, rhs: ReplicaStamp) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}

public struct ReplicaVersion: Codable, Equatable, Sendable {
    public let value: Data
    public let stamp: ReplicaStamp

    public init(value: Data, stamp: ReplicaStamp) {
        self.value = value
        self.stamp = stamp
    }
}

public struct ReplicaField: Codable, Equatable, Sendable {
    public let value: Data
    public let stamp: ReplicaStamp
    /// Concurrent heads travel with the record. Sequential drafts stay in local recovery.
    public let history: [ReplicaVersion]
    /// Largest predecessor counter observed from each author for this field.
    public let context: [String: Int64]

    public init(value: Data, stamp: ReplicaStamp, history: [ReplicaVersion] = [], context: [String: Int64] = [:]) {
        self.value = value
        self.stamp = stamp
        self.history = history
        self.context = context
    }
}

public struct ReplicaRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public var fields: [String: ReplicaField]
    public var deletion: ReplicaStamp?
    public var restoration: ReplicaStamp?

    public init(id: String, kind: String, fields: [String: ReplicaField] = [:],
                deletion: ReplicaStamp? = nil, restoration: ReplicaStamp? = nil) {
        self.id = id
        self.kind = kind
        self.fields = fields
        self.deletion = deletion
        self.restoration = restoration
    }

    public var isDeleted: Bool {
        guard let deletion else { return false }
        return restoration.map { $0 <= deletion } ?? true
    }

    fileprivate var maximumCounter: Int64 {
        var result = max(deletion?.counter ?? 0, restoration?.counter ?? 0)
        for field in fields.values {
            result = max(result, field.stamp.counter)
            for version in field.history { result = max(result, version.stamp.counter) }
        }
        return result
    }
}

public enum ReplicaMutation: Sendable {
    case set(id: String, kind: String, values: [String: Data])
    case delete(id: String)
    case restore(id: String)
}

public enum ReplicaError: Error, LocalizedError, Equatable {
    case storage(String)
    case unsupportedSchema(Int)
    case invalidRecord(String)
    case missingRecord(String)
    case deletedRecord(String)
    case counterExhausted

    public var errorDescription: String? {
        switch self {
        case .storage: return "Couldn’t save synced data. Check the data folder and try again."
        case .unsupportedSchema: return "This data needs a newer version of bist. Update the app before continuing."
        case .invalidRecord: return "Synced data could not be read safely. Your existing data is unchanged."
        case .missingRecord: return "That item is no longer available. Refresh the list and try again."
        case .deletedRecord: return "That item was deleted on another device. Restore it before editing."
        case .counterExhausted: return "Sync could not assign a new revision. Your existing data is unchanged."
        }
    }
}

/// One SQLite transaction contains the record edit, its revision, and the outbox entry.
/// Access is serialized and connections also use SQLite's full mutex mode.
public final class ReplicaDatabase: @unchecked Sendable {
    public let directory: URL
    public var deviceID: String { identityStorage }
    // Installation identity survives a file backup. Revision authors must not,
    // because a restored logical counter can revisit an already-synced number.
    private let writerEpoch = UUID().uuidString.lowercased()
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let schemaVersion = 1
    private static let internalPrefix = "__bist_"

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("sync.sqlite").path
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ReplicaError.storage("Could not open SQLite database")
        }
        handle = opened
        do {
            sqlite3_busy_timeout(opened, 5000)
            try Self.initialize(opened)
            try Self.run(opened, sql: "BEGIN IMMEDIATE")
            do {
                let stored = try Self.readMetadata(opened, key: "__bist_device")
                if let stored {
                    guard let decoded = String(data: stored, encoding: .utf8), Self.validIdentifier(decoded) else {
                        throw ReplicaError.invalidRecord("Invalid device identity")
                    }
                    identityStorage = decoded
                } else {
                    identityStorage = UUID().uuidString.lowercased()
                    try Self.writeMetadata(opened, value: Data(identityStorage.utf8), key: "__bist_device")
                }
                try Self.run(opened, sql: "COMMIT")
            } catch {
                try? Self.run(opened, sql: "ROLLBACK")
                throw error
            }
            let existing = try readRecords(pendingOnly: false)
            guard try currentCounter() >= (existing.map(\.maximumCounter).max() ?? 0) else {
                throw ReplicaError.invalidRecord("Logical counter is behind saved data")
            }
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    // Stored separately so initialization can fail closed before exposing an identity.
    private var identityStorage = ""
    deinit { if let handle { sqlite3_close(handle) } }

    public func records() throws -> [ReplicaRecord] {
        try synchronized { try readRecords(pendingOnly: false) }
    }

    public func pendingRecords() throws -> [ReplicaRecord] {
        try synchronized { try readRecords(pendingOnly: true) }
    }

    public func mutate(recordID: String, kind: String, values: [String: Data]) throws {
        try apply([.set(id: recordID, kind: kind, values: values)])
    }

    public func delete(recordID: String) throws { try apply([.delete(id: recordID)]) }

    public func apply(_ mutations: [ReplicaMutation], metadata: [String: Data?] = [:]) throws {
        try synchronized {
            try transaction {
                for mutation in mutations {
                    switch mutation {
                    case let .set(id, kind, values):
                        guard Self.validIdentifier(id), Self.validIdentifier(kind), values.count <= 256 else {
                            throw ReplicaError.invalidRecord(id)
                        }
                        var record = try readRecord(id: id) ?? ReplicaRecord(id: id, kind: kind)
                        guard record.kind == kind else { throw ReplicaError.invalidRecord("Record kind changed") }
                        guard !record.isDeleted else { throw ReplicaError.deletedRecord(id) }
                        var changed = [String: Data]()
                        for (name, value) in values {
                            try Self.validateValue(value, field: name)
                            if record.fields[name]?.value != value { changed[name] = value }
                        }
                        guard !changed.isEmpty else { continue }
                        let stamp = try tick()
                        for (name, value) in changed {
                            var context = record.fields[name]?.context ?? [:]
                            if let previous = record.fields[name] {
                                for prior in previous.history + [ReplicaVersion(value: previous.value, stamp: previous.stamp)] {
                                    context[prior.stamp.deviceID] = max(context[prior.stamp.deviceID] ?? 0, prior.stamp.counter)
                                }
                            }
                            record.fields[name] = ReplicaField(value: value, stamp: stamp, context: context)
                        }
                        try save(record, pending: true)
                    case let .delete(id):
                        guard var record = try readRecord(id: id) else { throw ReplicaError.missingRecord(id) }
                        guard !record.isDeleted else { continue }
                        record.deletion = try tick()
                        try save(record, pending: true)
                    case let .restore(id):
                        guard var record = try readRecord(id: id) else { throw ReplicaError.missingRecord(id) }
                        guard record.isDeleted else { continue }
                        record.restoration = try tick()
                        try save(record, pending: true)
                    }
                }
                for (key, value) in metadata {
                    try validateMetadataKey(key)
                    try Self.writeMetadata(try database(), value: value, key: key)
                }
            }
        }
    }

    /// Metadata can be committed with incoming records before advancing an engine token.
    public func merge(remote incoming: [ReplicaRecord], metadata: [String: Data?] = [:]) throws {
        try synchronized {
            try transaction {
                for remote in incoming {
                    try Self.validate(remote)
                    let local = try readRecord(id: remote.id)
                    if let local, local.kind != remote.kind {
                        throw ReplicaError.invalidRecord("Record kind changed")
                    }
                    let merged = try Self.merged(local, remote)
                    try retainHistory(remote)
                    let wasPending = try isPending(id: remote.id)
                    // If the local result contains anything absent from the server revision,
                    // it must return to the outbox even if a previous upload was acknowledged.
                    let needsUpload = merged != remote
                    try save(merged, pending: wasPending || needsUpload)
                    try advanceCounter(to: merged.maximumCounter)
                }
                for (key, value) in metadata {
                    try validateMetadataKey(key)
                    try Self.writeMetadata(try database(), value: value, key: key)
                }
            }
        }
    }

    /// Rebuild a removed server zone without manufacturing local edits.
    public func enqueueAll() throws {
        try synchronized { try execute("UPDATE records SET pending=1") }
    }

    /// An acknowledgement describes an exact uploaded body, never just an item ID.
    public func acknowledge(_ sent: [ReplicaRecord]) throws {
        try synchronized {
            try transaction {
                for record in sent {
                    if try readRecord(id: record.id) == record {
                        try execute("UPDATE records SET pending=0 WHERE id=?", values: [.text(record.id)])
                    }
                }
            }
        }
    }

    public func metadata(forKey key: String) throws -> Data? {
        try synchronized {
            try validateMetadataKey(key)
            return try Self.readMetadata(try database(), key: key)
        }
    }

    public func setMetadata(_ value: Data?, forKey key: String) throws {
        try synchronized {
            try validateMetadataKey(key)
            try Self.writeMetadata(try database(), value: value, key: key)
        }
    }

    public func recoverableValues(recordID: String, field: String) throws -> [Data] {
        try synchronized {
            guard let item = try readRecord(id: recordID)?.fields[field] else { return [] }
            let statement = try Self.prepare(try database(), sql: "SELECT value FROM field_history WHERE record_id=? AND field=? ORDER BY counter DESC,device_id DESC")
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, index: 1, value: .text(recordID))
            try Self.bind(statement, index: 2, value: .text(field))
            var result = [Data]()
            var seen = Set<Data>([item.value])
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw storageError() }
                let value = Self.blob(statement, column: 0)
                if seen.insert(value).inserted { result.append(value) }
            }
        }
    }

    private static func merged(_ local: ReplicaRecord?, _ remote: ReplicaRecord) throws -> ReplicaRecord {
        guard var result = local else { return remote }
        for (name, other) in remote.fields {
            guard let existing = result.fields[name] else { result.fields[name] = other; continue }
            let all = existing.history + other.history + [
                ReplicaVersion(value: existing.value, stamp: existing.stamp),
                ReplicaVersion(value: other.value, stamp: other.stamp)
            ]
            var versions = [ReplicaStampKey: ReplicaVersion]()
            for version in all {
                let key = ReplicaStampKey(version.stamp)
                if let duplicate = versions[key], duplicate.value != version.value {
                    throw ReplicaError.invalidRecord("A revision has conflicting values")
                }
                versions[key] = version
            }
            var context = existing.context
            for (device, counter) in other.context { context[device] = max(context[device] ?? 0, counter) }
            let ordered = versions.values.filter {
                $0.stamp.counter > (context[$0.stamp.deviceID] ?? 0)
            }.sorted { $0.stamp < $1.stamp }
            guard let latest = ordered.last else { throw ReplicaError.invalidRecord("Invalid causal context") }
            result.fields[name] = ReplicaField(value: latest.value, stamp: latest.stamp,
                                               history: Array(ordered.dropLast()), context: context)
        }
        result.deletion = maximum(result.deletion, remote.deletion)
        result.restoration = maximum(result.restoration, remote.restoration)
        return result
    }

    private struct ReplicaStampKey: Hashable {
        let counter: Int64
        let deviceID: String
        init(_ stamp: ReplicaStamp) { counter = stamp.counter; deviceID = stamp.deviceID }
    }

    private static func maximum(_ left: ReplicaStamp?, _ right: ReplicaStamp?) -> ReplicaStamp? {
        switch (left, right) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    private static func validIdentifier(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.count <= 512 && !string.contains("\0")
    }

    private static func validateValue(_ data: Data, field: String) throws {
        guard validIdentifier(field), data.count <= 16 * 1024 * 1024,
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw ReplicaError.invalidRecord("Invalid field value")
        }
    }

    private static func validateStamp(_ stamp: ReplicaStamp) throws {
        guard stamp.counter > 0, stamp.counter < Int64.max, validIdentifier(stamp.deviceID) else {
            throw ReplicaError.invalidRecord("Invalid revision")
        }
    }

    private static func validate(_ record: ReplicaRecord) throws {
        guard validIdentifier(record.id), validIdentifier(record.kind), record.fields.count <= 256 else {
            throw ReplicaError.invalidRecord("Invalid record identity")
        }
        if let deletion = record.deletion { try validateStamp(deletion) }
        if let restoration = record.restoration { try validateStamp(restoration) }
        for (name, field) in record.fields {
            try validateValue(field.value, field: name)
            try validateStamp(field.stamp)
            guard field.context.allSatisfy({ validIdentifier($0.key) && $0.value > 0 && $0.value < field.stamp.counter }),
                  field.stamp.counter > (field.context[field.stamp.deviceID] ?? 0) else {
                throw ReplicaError.invalidRecord("Invalid causal context")
            }
            var seen = Set<ReplicaStampKey>([ReplicaStampKey(field.stamp)])
            for prior in field.history {
                try validateValue(prior.value, field: name)
                try validateStamp(prior.stamp)
                guard (prior.stamp < field.stamp),
                      prior.stamp.counter > (field.context[prior.stamp.deviceID] ?? 0),
                      seen.insert(ReplicaStampKey(prior.stamp)).inserted else {
                    throw ReplicaError.invalidRecord("Invalid field history")
                }
            }
        }
    }

    private func validateMetadataKey(_ key: String) throws {
        guard Self.validIdentifier(key), !key.hasPrefix(Self.internalPrefix) else {
            throw ReplicaError.invalidRecord("Invalid metadata key")
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func database() throws -> OpaquePointer {
        guard let handle else { throw ReplicaError.storage("Database is closed") }
        return handle
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static func initialize(_ handle: OpaquePointer) throws {
        let version = try scalarInteger(handle, sql: "PRAGMA user_version")
        guard version == 0 || version == schemaVersion else { throw ReplicaError.unsupportedSchema(version) }
        if version == 0 {
            let tables = try scalarInteger(handle, sql: "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            guard tables == 0 else { throw ReplicaError.invalidRecord("Unrecognized database schema") }
            try run(handle, sql: "BEGIN IMMEDIATE")
            do {
                try run(handle, sql: "CREATE TABLE records (id TEXT PRIMARY KEY NOT NULL, body BLOB NOT NULL, pending INTEGER NOT NULL CHECK(pending IN (0,1)))")
                try run(handle, sql: "CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
                try run(handle, sql: "CREATE TABLE field_history (record_id TEXT NOT NULL, field TEXT NOT NULL, counter INTEGER NOT NULL, device_id TEXT NOT NULL, value BLOB NOT NULL, protected INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(record_id,field,counter,device_id))")
                try run(handle, sql: "PRAGMA user_version=1")
                try run(handle, sql: "COMMIT")
            } catch {
                try? run(handle, sql: "ROLLBACK")
                throw error
            }
        }
        try run(handle, sql: "PRAGMA journal_mode=WAL")
        try run(handle, sql: "PRAGMA synchronous=FULL")
    }

    private func currentCounter() throws -> Int64 {
        guard let data = try Self.readMetadata(try database(), key: "__bist_counter") else { return 0 }
        guard let text = String(data: data, encoding: .utf8), let counter = Int64(text), counter >= 0 else {
            throw ReplicaError.invalidRecord("Invalid logical counter")
        }
        return counter
    }

    private func tick() throws -> ReplicaStamp {
        let current = try currentCounter()
        guard current < Int64.max - 1 else { throw ReplicaError.counterExhausted }
        let next = current + 1
        try Self.writeMetadata(try database(), value: Data(String(next).utf8), key: "__bist_counter")
        return ReplicaStamp(counter: next, deviceID: writerEpoch)
    }

    private func advanceCounter(to counter: Int64) throws {
        if try currentCounter() < counter {
            try Self.writeMetadata(try database(), value: Data(String(counter).utf8), key: "__bist_counter")
        }
    }

    private func readRecords(pendingOnly: Bool) throws -> [ReplicaRecord] {
        let sql = "SELECT id,body FROM records" + (pendingOnly ? " WHERE pending=1" : "") + " ORDER BY id"
        let statement = try Self.prepare(try database(), sql: sql)
        defer { sqlite3_finalize(statement) }
        var records = [ReplicaRecord]()
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw storageError() }
            let record = try decodeRecord(Self.blob(statement, column: 1))
            guard let identity = sqlite3_column_text(statement, 0), String(cString: identity) == record.id else {
                throw ReplicaError.invalidRecord("Record identity mismatch")
            }
            records.append(record)
        }
    }

    private func readRecord(id: String) throws -> ReplicaRecord? {
        let statement = try Self.prepare(try database(), sql: "SELECT body FROM records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try Self.bind(statement, index: 1, value: .text(id))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw storageError() }
        let record = try decodeRecord(Self.blob(statement, column: 0))
        guard record.id == id else { throw ReplicaError.invalidRecord("Record identity mismatch") }
        return record
    }

    private func decodeRecord(_ bytes: Data) throws -> ReplicaRecord {
        let record: ReplicaRecord
        do { record = try JSONDecoder().decode(ReplicaRecord.self, from: bytes) }
        catch { throw ReplicaError.invalidRecord("Could not decode saved record") }
        try Self.validate(record)
        return record
    }

    private func isPending(id: String) throws -> Bool {
        let statement = try Self.prepare(try database(), sql: "SELECT pending FROM records WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try Self.bind(statement, index: 1, value: .text(id))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW else { throw storageError() }
        return sqlite3_column_int(statement, 0) != 0
    }

    private func save(_ record: ReplicaRecord, pending: Bool) throws {
        try Self.validate(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        try retainHistory(record)
        try execute("INSERT INTO records(id,body,pending) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body,pending=excluded.pending",
                    values: [.text(record.id), .blob(bytes), .integer(pending ? 1 : 0)])
    }

    private func retainHistory(_ record: ReplicaRecord) throws {
        for (name, field) in record.fields {
            for version in field.history + [ReplicaVersion(value: field.value, stamp: field.stamp)] {
                try execute("INSERT INTO field_history(record_id,field,counter,device_id,value,protected) VALUES(?,?,?,?,?,?) ON CONFLICT(record_id,field,counter,device_id) DO UPDATE SET protected=MAX(protected,excluded.protected)",
                            values: [.text(record.id), .text(name), .integer(version.stamp.counter), .text(version.stamp.deviceID), .blob(version.value), .integer(field.history.isEmpty ? 0 : 1)])
            }
            // Keep recent ordinary revisions without copying an entire growing
            // scratchpad forever. Concurrent alternatives are never pruned.
            try execute("DELETE FROM field_history WHERE record_id=? AND field=? AND protected=0 AND rowid NOT IN (SELECT rowid FROM field_history WHERE record_id=? AND field=? AND protected=0 ORDER BY counter DESC,device_id DESC LIMIT 32)",
                        values: [.text(record.id), .text(name), .text(record.id), .text(name)])
        }
    }

    private enum SQLValue { case text(String), blob(Data), integer(Int64) }

    private func execute(_ sql: String, values: [SQLValue] = []) throws {
        let statement = try Self.prepare(try database(), sql: sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() { try Self.bind(statement, index: Int32(offset + 1), value: value) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw storageError() }
    }

    private static func prepare(_ handle: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReplicaError.storage(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private static func bind(_ statement: OpaquePointer, index: Int32, value: SQLValue) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let status: Int32
        switch value {
        case let .text(text): status = sqlite3_bind_text(statement, index, text, -1, transient)
        case let .blob(data):
            if data.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) }
            else { status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) } }
        case let .integer(number): status = sqlite3_bind_int64(statement, index, number)
        }
        guard status == SQLITE_OK else { throw ReplicaError.storage("Could not bind database value") }
    }

    private static func blob(_ statement: OpaquePointer, column: Int32) -> Data {
        let size = Int(sqlite3_column_bytes(statement, column))
        guard size > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: size)
    }

    private static func readMetadata(_ handle: OpaquePointer, key: String) throws -> Data? {
        let statement = try prepare(handle, sql: "SELECT value FROM metadata WHERE key=?")
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, value: .text(key))
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw ReplicaError.storage(String(cString: sqlite3_errmsg(handle))) }
        return blob(statement, column: 0)
    }

    private static func writeMetadata(_ handle: OpaquePointer, value: Data?, key: String) throws {
        let sql = value == nil ? "DELETE FROM metadata WHERE key=?" : "INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        let statement = try prepare(handle, sql: sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, index: 1, value: .text(key))
        if let value { try bind(statement, index: 2, value: .blob(value)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ReplicaError.storage(String(cString: sqlite3_errmsg(handle))) }
    }

    private static func scalarInteger(_ handle: OpaquePointer, sql: String) throws -> Int {
        let statement = try prepare(handle, sql: sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ReplicaError.storage(String(cString: sqlite3_errmsg(handle))) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func run(_ handle: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ReplicaError.storage(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func storageError() -> ReplicaError {
        .storage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
    }
}
