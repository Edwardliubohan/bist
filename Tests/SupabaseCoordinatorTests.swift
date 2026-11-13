import Foundation
import Combine

final class CoordinatorSupabaseSessions: SupabaseSessionStore {
    var session: SupabaseSession?
    func load(scope: String) throws -> SupabaseSession? { session }
    func save(_ session: SupabaseSession, scope: String) throws { self.session = session }
    func delete(scope: String) throws { session = nil }
}

actor CoordinatorSupabaseRelay: SupabaseRelayAPI {
    let serverID = UUID()
    var beforeReceipt: (@Sendable () async -> Void)?
    var tokens: [String] = []
    var uploads = 0
    var feed: [SupabaseFeedEvent] = []
    var interruption = 0
    var delayPull = false
    var delayedPullStarted = false
    var delayedPullCancelled = false
    var pullDelay: UInt64 = 30_000_000_000
    var unwindDelay: UInt64 = 0
    func delayNextPull(duration: UInt64 = 30_000_000_000, unwind: UInt64 = 0) {
        delayPull = true; delayedPullStarted = false; delayedPullCancelled = false
        pullDelay = duration; unwindDelay = unwind
    }
    func delayState() -> (Bool, Bool) { (delayedPullStarted, delayedPullCancelled) }
    func interruptNextPull(urlError: Bool = false) { interruption = urlError ? 2 : 1 }
    func enqueue(_ records: [ReplicaRecord]) throws {
        for record in records {
            let event = try SupabaseRelayEvent(record: record)
            if !feed.contains(where: { $0.eventID == event.eventID }) {
                feed.append(.init(sequence: Int64(feed.count + 1), eventID: event.eventID, record: record))
            }
        }
    }
    func onReceipt(_ action: @escaping @Sendable () async -> Void) { beforeReceipt = action }
    func uploadCount() -> Int { uploads }
    func receivedTokens() -> [String] { tokens }
    func pull(after: Int64, accessToken: String) async throws -> SupabasePullPage {
        tokens.append(accessToken)
        if delayPull {
            delayPull = false; delayedPullStarted = true
            let duration = pullDelay, unwind = unwindDelay
            do { try await Task.sleep(nanoseconds: duration) }
            catch {
                delayedPullCancelled = true
                if unwind > 0 {
                    // A URLSession cancellation can take time to unwind. Keep
                    // the old caller suspended even though it was cancelled.
                    await Task.detached { try? await Task.sleep(nanoseconds: unwind) }.value
                }
                throw error
            }
        }
        if interruption != 0 {
            let value = interruption; interruption = 0
            if value == 2 { throw URLError(.cancelled) }
            throw CancellationError()
        }
        let events = Array(feed.filter { $0.sequence > after }.prefix(100))
        let next = events.last?.sequence ?? after
        return SupabasePullPage(events: events, nextCursor: next, hasMore: feed.contains { $0.sequence > next }, serverID: serverID)
    }
    func push(_ events: [SupabaseRelayEvent], accessToken: String) async throws -> SupabasePushReceipt {
        tokens.append(accessToken); uploads += 1
        try enqueue(events.map(\.record))
        if let action = beforeReceipt { beforeReceipt = nil; await action() }
        return SupabasePushReceipt(accepted: events.map(\.eventID), serverID: serverID)
    }
}

@main
struct SupabaseCoordinatorTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-supabase-coordinator-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = root.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let configuration = ["projectURL": "https://bist-test.supabase.co", "publishableKey": "sb_publishable_" + String(repeating: "a", count: 48)]
        try JSONSerialization.data(withJSONObject: configuration).write(to: configured.appendingPathComponent("supabase-project.json"))
        let store = AppStore(directory: configured)
        let note = NoteStore(directory: configured)
        let vault = CoordinatorSupabaseSessions()
        let relay = CoordinatorSupabaseRelay()
        let sync = BistSyncCoordinator(store: store, note: note, supabaseSessions: vault, supabaseRelayFactory: { _ in relay })
        precondition(sync.isAvailable, "A configured HTTPS sync project must work in the ordinary build without CloudKit entitlements")
        precondition(!sync.enabled, "A configured project must not upload before account sign-in and explicit enable")
        precondition(store.addTask(title: "Offline before sign-in"), "Adding Supabase must preserve local editing")
        let localDirectory = root.appendingPathComponent("local")
        let local = AppStore(directory: localDirectory)
        let localSync = BistSyncCoordinator(store: local, note: NoteStore(directory: localDirectory))
        precondition(!localSync.enabled && !localSync.isAvailable, "Unconfigured source builds must remain local")
        let owner = SupabaseSession(accessToken: "owner-session", refreshToken: "owner-refresh", expiresAt: Date().addingTimeInterval(3600), userID: UUID(), email: "owner@example.com")
        vault.session = owner
        sync.supabaseAccount.configure(projectURL: configuration["projectURL"]!, publishableKey: configuration["publishableKey"]!)
        precondition(sync.canEnable && !sync.enabled, "Sign-in makes sync available without automatically uploading")
        await relay.onReceipt { @MainActor in sync.setBackend(.iCloud) }
        sync.setEnabled(true)
        await sync.refresh()
        precondition(sync.backend == .iCloud && !sync.enabled && sync.pendingCount > 0,
                     "An old Supabase response cannot ACK after selecting another backend")
        sync.setBackend(.supabase); sync.setEnabled(true)
        await sync.refresh()
        precondition(sync.enabled && sync.pendingCount == 0 && sync.lastSyncedAt != nil, "Reconnecting sends retained records and reaches a real successful response")
        let uploads = await relay.uploadCount()
        sync.setBackend(.iCloud); sync.setBackend(.supabase); sync.setEnabled(true)
        await sync.refresh()
        let repeated = await relay.uploadCount()
        precondition(repeated > uploads, "A provider switch requeues records acknowledged by the other backend")
        sync.setEnabled(false)

        let other = SupabaseSession(accessToken: "other-session", refreshToken: "other-refresh", expiresAt: Date().addingTimeInterval(3600), userID: UUID(), email: "other@example.com")
        vault.session = other
        sync.supabaseAccount.configure(projectURL: configuration["projectURL"]!, publishableKey: configuration["publishableKey"]!)
        precondition(sync.accountMergeRequired && !sync.enabled, "Changing accounts requires a visible merge decision")
        sync.setEnabled(true)
        precondition(!sync.enabled && sync.error != nil, "A backend cannot silently move this device's data into another account")
        let beforeApproval = await relay.receivedTokens()
        precondition(!beforeApproval.contains(other.accessToken), "No other-account request is sent before approval")
        sync.authorizeSupabaseAccountChange()
        await sync.refresh()
        let afterApproval = await relay.receivedTokens()
        precondition(sync.enabled && afterApproval.contains(other.accessToken), "Explicit backed-up combination connects the chosen account")
        precondition(store.tasks.contains { $0.title == "Offline before sign-in" }, "Account combination preserves local tasks")
        try await Task.sleep(nanoseconds: 50_000_000)
        let remoteDirectory = root.appendingPathComponent("remote")
        let remote = AppStore(directory: remoteDirectory)
        let remoteBridge = try BistReplicaBridge(store: remote, note: NoteStore(directory: remoteDirectory))
        for index in 0..<105 { precondition(remote.addTask(title: "Remote \(index)")) }
        try await relay.enqueue(remoteBridge.database.records())
        var syncErrors: [String] = []
        let observer = sync.$error.compactMap { $0 }.sink { syncErrors.append($0) }
        let beforeDebounce = await relay.uploadCount()
        precondition(store.addTask(title: "Debounced local edit"))
        for _ in 0..<120 {
            if !syncErrors.isEmpty { break }
            if await relay.uploadCount() > beforeDebounce, sync.pendingCount == 0,
               store.tasks.filter({ $0.title.hasPrefix("Remote ") }).count == 105 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(syncErrors.isEmpty, "Receiving remote pages must not cancel the debounce task that is currently syncing")
        let afterDebounce = await relay.uploadCount()
        precondition(afterDebounce > beforeDebounce && sync.pendingCount == 0,
                     "One debounced sync must upload local work after fetching more than one remote page")
        precondition(store.tasks.filter { $0.title.hasPrefix("Remote ") }.count == 105,
                     "A debounce receives every remote page before uploading")
        let lastSuccess = sync.lastSyncedAt
        for urlError in [false, true] {
            await relay.interruptNextPull(urlError: urlError)
            await sync.refresh()
            precondition(sync.error == nil && sync.enabled, "Expected cancellation must leave sync enabled without a raw error")
            precondition(sync.lastSyncedAt == lastSuccess, "Cancellation cannot report a new successful sync")
        }
        observer.cancel()
        for disabling in [true, false] {
            precondition(store.addTask(title: disabling ? "Pending on disconnect" : "Pending in background"))
            await relay.delayNextPull()
            let request = Task { await sync.refresh() }
            for _ in 0..<100 {
                if await relay.delayState().0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let started = await relay.delayState().0
            precondition(started, "The test must own an active network request")
            let lastSuccess = sync.lastSyncedAt
            if disabling { sync.setEnabled(false) }
            else { sync.setForeground(false) }
            for _ in 0..<100 {
                if await relay.delayState().1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let cancelled = await relay.delayState().1
            request.cancel()
            await request.value
            precondition(cancelled, "Disabling sync or entering the background must cancel an active network request")
            precondition(sync.error == nil && sync.lastSyncedAt == lastSuccess,
                         "Explicit cancellation must not show a failure or claim a successful exchange")
            precondition(sync.pendingCount > 0, "Cancellation must retain the durable unsent edit")
            sync.setForeground(true)
            if disabling { sync.setEnabled(true) }
            await sync.refresh()
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        precondition(store.addTask(title: "Keep syncing through an inactive phase"))
        await relay.delayNextPull(duration: 200_000_000)
        let inactiveUploads = await relay.uploadCount()
        let inactiveRequest = Task { await sync.refresh() }
        for _ in 0..<100 {
            if await relay.delayState().0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let inactiveStarted = await relay.delayState().0
        precondition(inactiveStarted, "The inactive-phase test must own an active request")
        // Both .inactive and .active remain foreground in the phone adapter.
        sync.setForeground(true); sync.setForeground(true)
        await sync.refresh()
        await inactiveRequest.value
        let inactiveCancelled = await relay.delayState().1
        precondition(!inactiveCancelled, "An inactive phase must not cancel a foreground transfer")
        let inactiveFinished = await relay.uploadCount()
        precondition(inactiveFinished > inactiveUploads && sync.pendingCount == 0,
                     "The foreground request finishes its upload without waiting for a poll")

        precondition(store.addTask(title: "Resume while cancellation is unwinding"))
        await relay.delayNextPull(unwind: 200_000_000)
        let backgroundRequest = Task { await sync.refresh() }
        for _ in 0..<100 {
            if await relay.delayState().0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let backgroundStarted = await relay.delayState().0
        precondition(backgroundStarted, "The fast-resume test must own the cancelled request")
        sync.setForeground(false); sync.setForeground(true)
        await sync.refresh()
        precondition(sync.pendingCount == 0, "Returning immediately must sync before the old cancellation has unwound")
        let foregroundSuccess = sync.lastSyncedAt
        precondition(foregroundSuccess != nil && sync.error == nil, "The replacement foreground request succeeds")
        await backgroundRequest.value
        let backgroundCancelled = await relay.delayState().1
        precondition(backgroundCancelled, "Real backgrounding still cancels its original request")
        precondition(sync.lastSyncedAt == foregroundSuccess && sync.error == nil && sync.status == "Up to date",
                     "The old cancellation cannot clear or replace the resumed request's result")

        sync.setForeground(false)
        let backgroundUploads = await relay.uploadCount()
        precondition(store.addTask(title: "Saved during the background note flush"))
        try await Task.sleep(nanoseconds: 1_800_000_000)
        let whileBackgrounded = await relay.uploadCount()
        precondition(whileBackgrounded == backgroundUploads && sync.pendingCount > 0,
                     "A background save must not restart a foreground-only sync through its debounce")
        sync.setForeground(true)
        await sync.refresh()
        precondition(sync.pendingCount == 0, "Returning to the foreground sends edits saved during backgrounding")
        sync.setEnabled(false)
        print("PASS 38 Supabase coordinator activation, lifecycle and account-boundary checks")
    }
}
