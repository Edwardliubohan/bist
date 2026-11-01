# Shared sync API

`ReplicaDatabase(directory:)` opens `sync.sqlite` and keeps a stable installation `deviceID`. Every method throws on storage or validation failure. Calls are serialized internally.

Each opened database connection uses a fresh writer epoch UUID in `ReplicaStamp.deviceID`. The wire field name stays compatible, but revision authors identify writer epochs rather than installations. Restoring a backed-up data folder therefore cannot reuse an already-synced revision when its logical counter rolls back. Causal contexts track these writer epochs. The installation `deviceID` remains unchanged for local metadata.

`ReplicaRecord` has `id`, `kind`, `fields`, `deletion` and `restoration`. `isDeleted` compares explicit deletion and restoration stamps. Ordinary edits never restore a deleted record.

Each `ReplicaField` has JSON bytes in `value`, a Lamport `stamp`, causal `context` and `history` containing concurrent losing heads. Fields compare logical counters then device IDs, never wall clocks. Each new local field edit observes and resolves existing heads. Sequential typing does not grow the network payload.

`records()` includes tombstones. `pendingRecords()` is the durable outbox. `apply(_ mutations: [ReplicaMutation], metadata: [String: Data?] = [:])` commits the whole batch atomically. Mutation cases are `.set(id:kind:values:)`, `.delete(id:)` and `.restore(id:)`. `mutate(recordID:kind:values:)` and `delete(recordID:)` are convenience calls. Missing fields are unchanged, so explicit JSON null clears an optional field.

`merge(remote: [ReplicaRecord], metadata: [String: Data?] = [:])` merges a fetched batch atomically, including engine tokens or CloudKit system fields. A nil metadata value removes the key. `acknowledge(_ sent: [ReplicaRecord])` removes an outbox entry only if its current record equals that exact sent record.

`metadata(forKey:)` and `setMetadata(_:forKey:)` persist opaque engine and CloudKit system-field bytes. Keys starting with `__bist_` are reserved. `enqueueAll()` requeues every retained record after a server zone reset without changing its revision.

`recoverableValues(recordID:field:)` returns distinct prior field values, excluding the current value. SQLite preserves every concurrent alternative permanently and the latest 32 ordinary revisions per field. Sequential drafts stay out of each cloud record. This keeps routine typing bounded while preserving competing drafts for recovery.

The package is `BistSync`. Direct source compilation uses `Shared/Sources/BistSync/*.swift -I Shared/Sources/CSQLite -lsqlite3`. Source files import Foundation and CSQLite only.

Task hierarchy and sibling ordering projections belong to the app adapter. The generic layer preserves record fields and versions without interpreting task semantics.
