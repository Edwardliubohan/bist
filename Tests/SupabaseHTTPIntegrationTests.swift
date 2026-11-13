import Foundation

private struct HTTPFixture: Decodable {
    let origin: URL
    let apiKey: String
    let aliceID: String
    let bobID: String
    let aliceToken: String
    let bobToken: String
    let anonToken: String
    let forgedToken: String
    let expiredToken: String
}

private actor FixtureWire {
    let origin: URL
    let apiKey: String
    let session = URLSession(configuration: .ephemeral)
    var offline = false
    var losePushReceipt = false
    var statementTimeout = false
    var beforePushReturn: (@Sendable () async -> Void)?
    var requests = 0

    init(_ fixture: HTTPFixture) { origin = fixture.origin; apiKey = fixture.apiKey }
    func setOffline(_ value: Bool) { offline = value }
    func loseNextPushReceipt() { losePushReceipt = true }
    func timeOutNextStatement() { statementTimeout = true }
    func onNextPushReturn(_ action: @escaping @Sendable () async -> Void) { beforePushReturn = action }
    func count() -> Int { requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(origin.scheme == "http" && origin.host == "127.0.0.1", "Fixture may contact localhost only")
        guard let url = request.url, url.scheme == "https", url.host == "project.test",
              url.path.hasPrefix("/rest/v1/rpc/") else { preconditionFailure("Unexpected production URL") }
        precondition(request.httpMethod == "POST" && request.httpBody != nil, "Actual relay request body is required")
        precondition(request.value(forHTTPHeaderField: "apikey") == apiKey, "Public key header must survive the URL rewrite")
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true,
                     "Authenticated bearer header must survive the URL rewrite")
        if offline { throw URLError(.notConnectedToInternet) }
        var rewritten = request
        rewritten.url = origin.appendingPathComponent(String(url.path.dropFirst("/rest/v1/".count)))
        if statementTimeout {
            statementTimeout = false
            rewritten.setValue("1", forHTTPHeaderField: "x-bist-fixture-timeout")
        }
        requests += 1
        let isPush = url.lastPathComponent == "bist_sync_push"
        let lose = isPush && losePushReceipt
        if lose { losePushReceipt = false }
        let action = isPush ? beforePushReturn : nil
        if action != nil { beforePushReturn = nil }
        // PostgREST performs real JWT verification, role switching, RPC routing
        // and SQL execution. The test seam changes only the target origin.
        let (data, response) = try await session.data(for: rewritten)
        guard let response = response as? HTTPURLResponse else { preconditionFailure("No real HTTP response") }
        if response.statusCode >= 400 {
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            print("Fixture HTTP \(response.statusCode) at \(url.lastPathComponent), code \(error?["code"] ?? "unknown"), message \(error?["message"] ?? "unknown")")
            fflush(stdout)
        }
        if let action { await action() }
        if lose { throw URLError(.networkConnectionLost) }
        return (data, response)
    }
}

@main
struct SupabaseHTTPIntegrationTests {
    @MainActor static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["BIST_SUPABASE_HTTP_FIXTURE"] else {
            preconditionFailure("Run through scripts/test-supabase-http.sh with an isolated database")
        }
        let fixture = try JSONDecoder().decode(HTTPFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let configuration = try SupabaseConfiguration(projectURL: URL(string: "https://project.test")!, publishableKey: fixture.apiKey)
        let wire = FixtureWire(fixture)
        let client = SupabaseRelayClient(configuration: configuration, sender: { try await wire.send($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bist-http-replicas-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        func make(_ name: String) throws -> (AppStore, NoteStore, BistReplicaBridge) {
            let directory = root.appendingPathComponent(name)
            let store = AppStore(directory: directory)
            let note = NoteStore(directory: directory, prepareForWrite: store.prepareForAuxiliaryWrite)
            return (store, note, try BistReplicaBridge(store: store, note: note))
        }
        func transport(_ bridge: BistReplicaBridge, token: String = fixture.aliceToken,
                       user: String = fixture.aliceID) throws -> SupabaseReplicaTransport {
            try SupabaseReplicaTransport(bridge: bridge, scope: configuration.scope + "/" + user,
                                         relay: client, credentials: { token })
        }

        let empty = try await client.pull(after: 0, accessToken: fixture.aliceToken)
        expect(empty.events.isEmpty && empty.nextCursor == 0 && !empty.hasMore, "Real HTTP empty feed decodes correctly")
        let bobEmpty = try await client.pull(after: 0, accessToken: fixture.bobToken)
        expect(bobEmpty.events.isEmpty && bobEmpty.serverID == empty.serverID, "Authenticated tenants share only instance identity")
        for token in [fixture.forgedToken, fixture.expiredToken] {
            do { _ = try await client.pull(after: 0, accessToken: token); preconditionFailure("Invalid JWT accepted") }
            catch SupabaseSyncError.signInRequired { checks += 1 }
        }
        do { _ = try await client.pull(after: 0, accessToken: fixture.anonToken); preconditionFailure("Anonymous RPC accepted") }
        catch SupabaseSyncError.signInRequired { checks += 1 }
        let forbidden = try SupabaseRelayEvent(record: ReplicaRecord(id: "note.main", kind: "note", fields: [
            "text": ReplicaField(value: try JSONEncoder().encode("Forbidden"), stamp: ReplicaStamp(counter: 1, deviceID: "anon"))
        ]))
        do { _ = try await client.push([forbidden], accessToken: fixture.anonToken); preconditionFailure("Anonymous write accepted") }
        catch SupabaseSyncError.signInRequired { checks += 1 }
        expect(try await client.pull(after: 0, accessToken: fixture.aliceToken).events.isEmpty,
               "Rejected JWTs and anonymous writes cannot mutate a user's feed")
        let malformed = try SupabaseRelayEvent(record: ReplicaRecord(id: "note.main", kind: "note", fields: [:]))
        do { _ = try await client.push([forbidden, malformed], accessToken: fixture.aliceToken); preconditionFailure("Malformed batch accepted") }
        catch SupabaseSyncError.unavailable { checks += 1 }
        expect(try await client.pull(after: 0, accessToken: fixture.aliceToken).events.isEmpty,
               "Real PostgREST RPC rolls back the valid prefix of a malformed batch")

        let (mac, macNote, macBridge) = try make("mac")
        let (phone, phoneNote, phoneBridge) = try make("phone")
        let macSync = try transport(macBridge)
        let phoneSync = try transport(phoneBridge)
        expect(mac.addTask(title: "Created on Mac"), "Mac local capture succeeds")
        let taskID = mac.tasks[0].id
        let originalNote = "Shared original note 🌱 e\u{301} \u{feff} \u{ffff}\u{0}"
        macNote.update(originalNote); macNote.save()
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.first?.id == taskID, "Task identity crosses actual HTTP and SQL")
        expect(phoneNote.text == originalNote, "Unicode, combining marks, BOM and NUL cross actual HTTP and SQL")
        expect(try macBridge.database.pendingRecords().isEmpty && phoneBridge.database.pendingRecords().isEmpty,
               "Both durable outboxes acknowledge real accepted bodies")

        await wire.setOffline(true)
        expect(mac.updateTask(id: taskID, title: "Mac offline title", notes: "Mac details", nextAction: "Next"), "Offline Mac edit succeeds")
        expect(phone.setUserCompletion(id: taskID, completed: true), "Offline phone completion succeeds")
        macNote.update("Mac concurrent note"); macNote.save()
        phoneNote.update("Phone concurrent note"); phoneNote.save()
        do { try await macSync.synchronize(); preconditionFailure("Offline transport succeeded") } catch is URLError { checks += 1 }
        expect(try !macBridge.database.pendingRecords().isEmpty, "Network failure preserves the durable outbox")
        await wire.setOffline(false)
        async let fromMac: Void = macSync.synchronize()
        async let fromPhone: Void = phoneSync.synchronize()
        _ = try await (fromMac, fromPhone)
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(mac.tasks.first?.title == "Mac offline title" && phone.tasks.first?.title == "Mac offline title",
               "Concurrent HTTP exchanges preserve independent title editing")
        expect(mac.tasks.first?.completed == true && phone.tasks.first?.completed == true,
               "Concurrent HTTP exchanges preserve independent completion")
        expect(macNote.text == phoneNote.text, "Concurrent notes converge through PostgREST")
        let noteVersions = try macBridge.noteVersions()
        expect(noteVersions.contains("Mac concurrent note") || noteVersions.contains("Phone concurrent note"),
               "Concurrent note text remains recoverable after real HTTP merge")
        expect(try macBridge.database.records() == phoneBridge.database.records(), "Native replicas converge exact portable values")

        expect(mac.addTask(title: "Retry after lost HTTP response"), "Second local capture succeeds")
        await wire.loseNextPushReceipt()
        do { try await macSync.synchronize(); preconditionFailure("Lost receipt was accepted locally") } catch is URLError { checks += 1 }
        expect(try !macBridge.database.pendingRecords().isEmpty, "Lost real response cannot ACK local changes")
        let countAfterLoss = try await client.pull(after: 0, accessToken: fixture.aliceToken).events.count
        try await macSync.synchronize()
        let countAfterRetry = try await client.pull(after: 0, accessToken: fixture.aliceToken).events.count
        expect(countAfterRetry == countAfterLoss, "Real SQL deduplicates a lost-response retry")
        expect(try macBridge.database.pendingRecords().isEmpty, "Retry eventually ACKs exact accepted records")

        expect(mac.addTask(title: "Old in-flight body"), "In-flight fixture task created")
        let inflightID = mac.tasks.last!.id
        await wire.onNextPushReturn { @MainActor in
            precondition(mac.updateTask(id: inflightID, title: "Newer in-flight body", notes: "", nextAction: ""))
        }
        try await macSync.synchronize()
        expect(try macBridge.database.pendingRecords().contains { $0.id == "task." + inflightID.uuidString.lowercased() },
               "Newer edits survive a real old-body upload acknowledgment")
        try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(phone.tasks.contains { $0.title == "Newer in-flight body" }, "Pending in-flight edit reaches the phone on retry")

        expect(mac.deleteTask(id: taskID, includingSubtasks: false), "Mac deletion succeeds")
        expect(phone.updateTask(id: taskID, title: "Stale offline phone edit", notes: "", nextAction: ""), "Stale offline phone edit succeeds locally")
        try await phoneSync.synchronize(); try await macSync.synchronize(); try await phoneSync.synchronize()
        expect(!mac.tasks.contains { $0.id == taskID } && !phone.tasks.contains { $0.id == taskID },
               "Tombstone defeats a stale edit through real HTTP")

        expect(mac.addTask(title: "Offline before relaunch"), "Relaunch fixture task created")
        macSync.stop()
        let (reopened, _, reopenedBridge) = try make("mac")
        expect(try !reopenedBridge.database.pendingRecords().isEmpty, "Pending work survives native storage reopening")
        let reopenedSync = try transport(reopenedBridge)
        try await reopenedSync.synchronize(); try await phoneSync.synchronize()
        expect(reopened.tasks.contains { $0.title == "Offline before relaunch" } && phone.tasks.contains { $0.title == "Offline before relaunch" },
               "Relaunched offline edits cross actual HTTP")

        let (bob, _, bobBridge) = try make("bob")
        expect(bob.addTask(title: "Bob private task"), "Second tenant captures locally")
        let bobSync = try transport(bobBridge, token: fixture.bobToken, user: fixture.bobID)
        try await bobSync.synchronize()
        expect(bob.tasks.count == 1 && bob.tasks[0].title == "Bob private task", "Second JWT user cannot read Alice data")
        try await phoneSync.synchronize()
        expect(!phone.tasks.contains { $0.title == "Bob private task" }, "First JWT user cannot read Bob data")
        do { _ = try transport(phoneBridge, token: fixture.bobToken, user: fixture.bobID); preconditionFailure("Silent account switch accepted") }
        catch SupabaseSyncError.accountChanged { checks += 1 }
        do { _ = try await client.pull(after: Int64.max, accessToken: fixture.aliceToken); preconditionFailure("Cursor ahead accepted") }
        catch SupabaseSyncError.serverChanged { checks += 1 }

        // Exercise the real 100-event API page and the transport's continuation
        // loop, without substituting a small fake page implementation.
        let start = try await client.pull(after: 0, accessToken: fixture.aliceToken).nextCursor
        var bulk = [SupabaseRelayEvent]()
        for index in 0..<105 {
            let record = ReplicaRecord(id: "note.main", kind: "note", fields: [
                "text": ReplicaField(value: try JSONEncoder().encode("Page \(index)"),
                                     stamp: ReplicaStamp(counter: Int64(10_000 + index), deviceID: "http-page-fixture"))
            ])
            bulk.append(try SupabaseRelayEvent(record: record))
        }
        for offset in stride(from: 0, to: bulk.count, by: 32) {
            _ = try await client.push(Array(bulk[offset..<min(offset + 32, bulk.count)]), accessToken: fixture.aliceToken)
        }
        let firstPage = try await client.pull(after: start, accessToken: fixture.aliceToken)
        expect(firstPage.events.count == 100 && firstPage.hasMore, "Actual PostgREST returns a full100-event page")
        let lastPage = try await client.pull(after: firstPage.nextCursor, accessToken: fixture.aliceToken)
        expect(lastPage.events.count == 5 && !lastPage.hasMore, "Actual PostgREST continuation retains every remaining event")
        await wire.timeOutNextStatement()
        let recoveredPage = try await client.pull(after: start, accessToken: fixture.aliceToken)
        expect(recoveredPage.events.count == 50 && recoveredPage.hasMore,
               "A real PostgreSQL query-canceled response shrinks the next request at the same cursor")
        await wire.timeOutNextStatement()
        let duplicateBatch = Array(bulk.prefix(32))
        let recoveredReceipt = try await client.push(duplicateBatch, accessToken: fixture.aliceToken)
        expect(recoveredReceipt.accepted == duplicateBatch.map(\.eventID),
               "PostgREST statement cancellation splits uploads and preserves their exact receipt identities")
        expect(try await client.pull(after: lastPage.nextCursor, accessToken: fixture.aliceToken).events.isEmpty,
               "Split retries after query cancellation retain server deduplication")
        let (_, freshNote, freshBridge) = try make("fresh-paginated")
        let freshSync = try transport(freshBridge)
        try await freshSync.synchronize()
        expect(freshNote.text == "Page 104", "Fresh native transport consumes all real HTTP pages")
        expect(try freshBridge.database.pendingRecords().isEmpty, "Paginated merged replica completes durable acknowledgment")
        expect(await wire.count() > 40, "Feature journey exercised actual network requests")
        print("PASS \(checks) native Supabase HTTP/PostgREST integration checks")
    }
}
