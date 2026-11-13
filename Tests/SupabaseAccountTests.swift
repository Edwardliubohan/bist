import Foundation

final class TestSupabaseSessions: SupabaseSessionStore {
    var values: [String: SupabaseSession] = [:]
    var failedScope: String?
    var failSave = false
    func load(scope: String) throws -> SupabaseSession? {
        if scope == failedScope { throw SupabaseAuthError.credentialStorage }
        return values[scope]
    }
    func save(_ session: SupabaseSession, scope: String) throws {
        if failSave { throw SupabaseAuthError.credentialStorage }
        values[scope] = session
    }
    func delete(scope: String) throws { values.removeValue(forKey: scope) }
}

actor TestSupabaseRefreshCounter {
    var count = 0
    var verificationCount = 0
    let userID: UUID
    init(userID: UUID) { self.userID = userID }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: [String: Any]
        if request.url!.path.hasSuffix("/token") || request.url!.path.hasSuffix("/verify") {
            if request.url!.path.hasSuffix("/token") { count += 1 }
            else {
                verificationCount += 1
                if verificationCount > 1 { throw SupabaseAuthError.invalidCode }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            body = ["access_token": "renewed-access", "refresh_token": "renewed-refresh", "expires_in": 3600,
                    "token_type": "bearer", "user": ["id": userID.uuidString, "email": "owner@example.com"]]
        } else { body = ["id": userID.uuidString, "email": "owner@example.com"] }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func calls() -> Int { count }
    func verificationCalls() -> Int { verificationCount }
}

@main
struct SupabaseAccountTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-supabase-account-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "sb_publishable_test"
        let old = try SupabaseConfiguration(projectURL: URL(string: "https://old.supabase.co")!, publishableKey: key)
        let next = try SupabaseConfiguration(projectURL: URL(string: "https://new.supabase.co")!, publishableKey: key)
        let file = directory.appendingPathComponent("supabase-project.json")
        try JSONEncoder().encode(old).write(to: file)
        let vault = TestSupabaseSessions()
        let saved = SupabaseSession(accessToken: "old-project-access", refreshToken: "old-project-refresh", expiresAt: Date().addingTimeInterval(3600), userID: UUID(), email: "owner@example.com")
        vault.values[old.scope] = saved
        let account = SupabaseAccountController(directory: directory, sessions: vault, sender: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        precondition(account.configuration == old && account.session == saved, "Existing project uses only its own Keychain session")
        vault.failedScope = next.scope
        account.configure(projectURL: next.projectURL.absoluteString, publishableKey: key)
        precondition(account.configuration == old, "A Keychain failure must not pair a new project URL with the old project's bearer token")
        precondition(account.session == saved, "Failed project changes preserve the old scoped connection")
        let disk = try JSONDecoder().decode(SupabaseConfiguration.self, from: Data(contentsOf: file))
        precondition(disk == old, "Rejected connection changes leave the old disk configuration intact")
        vault.failedScope = nil
        var stops = 0
        account.willChange = { stops += 1 }
        account.configure(projectURL: next.projectURL.absoluteString, publishableKey: key)
        precondition(account.configuration == next && account.session == nil, "A new project never inherits the prior project's token")
        precondition(stops == 1, "A successful account context change stops the previous transport")
        account.configure(projectURL: "http://new.supabase.co", publishableKey: key)
        precondition(account.configuration == next && account.error != nil, "Insecure project URLs are rejected without breaking the saved connection")
        account.configure(projectURL: old.projectURL.absoluteString, publishableKey: key)
        precondition(account.session == saved, "Reconnecting a project loads its own scoped session")
        let counter = TestSupabaseRefreshCounter(userID: saved.userID)
        let refreshing = SupabaseAccountController(directory: directory, sessions: vault, sender: { try await counter.send($0) })
        async let first = refreshing.refreshSession()
        async let second = refreshing.refreshSession()
        let tokens = try await (first, second)
        let count = await counter.calls()
        precondition(count == 1 && tokens.0 == tokens.1, "Concurrent refresh callers must share one rotation request for the same session")
        await account.signOut()
        precondition(account.session == nil && vault.values[old.scope] == nil, "Signing out removes the local refresh session")
        let otp = SupabaseAccountController(directory: directory, sessions: vault, sender: { try await counter.send($0) })
        await otp.requestCode(email: "owner@example.com")
        vault.failSave = true
        await otp.verifyCode("123456")
        precondition(otp.session == nil && otp.error != nil, "A locked Keychain cannot publish an unsaved authenticated session")
        vault.failSave = false
        await otp.verifyCode("123456")
        let verified = await counter.verificationCalls()
        precondition(otp.session?.userID == saved.userID && verified == 1,
                     "Retry after unlocking Keychain must save the already verified session without reusing a consumed OTP")
        vault.values[old.scope] = saved
        let rotatingCounter = TestSupabaseRefreshCounter(userID: saved.userID)
        let rotating = SupabaseAccountController(directory: directory, sessions: vault, sender: { try await rotatingCounter.send($0) })
        vault.failSave = true
        do { _ = try await rotating.refreshSession(); preconditionFailure("A failed credential write must be reported") }
        catch SupabaseAuthError.credentialStorage {}
        precondition(rotating.session?.refreshToken == "renewed-refresh",
                     "A verified rotation must remain in memory when Keychain is locked")
        precondition(vault.values[old.scope] == saved, "A failed credential write leaves the prior saved item intact")
        rotating.configure(projectURL: old.projectURL.absoluteString, publishableKey: key)
        precondition(rotating.session?.refreshToken == "renewed-refresh" && rotating.error != nil,
                     "Reconfiguring while locked cannot reload a stale credential over a rotated one")
        vault.failSave = false
        let recovered = try await rotating.accessToken()
        precondition(recovered == "renewed-access" && vault.values[old.scope]?.refreshToken == "renewed-refresh",
                     "The next request retries credential persistence before using the renewed session")
        let rotations = await rotatingCounter.calls()
        precondition(rotations == 1, "Credential persistence retry must not rotate or reuse a refresh token again")
        rotating.configure(projectURL: old.projectURL.absoluteString, publishableKey: key)
        precondition(rotating.session?.refreshToken == "renewed-refresh" && rotating.error == nil,
                     "Reconnecting after unlock uses the durable renewed session")
        print("PASS 18 Supabase account isolation and credential recovery checks")
    }
}
