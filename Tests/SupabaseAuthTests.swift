import Foundation
import Security

private actor AuthHTTPStub {
    struct Step {
        let status: Int
        let data: Data
        var headers: [String: String] = [:]
    }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        precondition(!steps.isEmpty, "Unexpected HTTP request")
        let step = steps.removeFirst()
        return (step.data, HTTPURLResponse(url: request.url!, statusCode: step.status,
                                         httpVersion: "HTTP/1.1", headerFields: step.headers)!)
    }
    nonisolated var sender: SupabaseHTTPSender { { request in try await self.send(request) } }
}

private final class AuthKeychainStub {
    var values: [String: Data] = [:]
    var status: OSStatus = errSecSuccess
    var lastAdded: [String: Any] = [:]
    var lastUpdated: [String: Any] = [:]
    var queries: [[String: Any]] = []
    var operations: SupabaseKeychainOperations {
        SupabaseKeychainOperations(copyMatching: { query, output in
            let q = query as! [String: Any]
            self.queries.append(q)
            guard self.status == errSecSuccess else { return self.status }
            guard let value = self.values[q[kSecAttrAccount as String] as! String] else { return errSecItemNotFound }
            output?.pointee = value as CFData
            return errSecSuccess
        }, update: { query, attributes in
            let q = query as! [String: Any]
            let a = attributes as! [String: Any]
            self.queries.append(q)
            self.lastUpdated = a
            guard self.status == errSecSuccess else { return self.status }
            let scope = q[kSecAttrAccount as String] as! String
            guard self.values[scope] != nil else { return errSecItemNotFound }
            self.values[scope] = a[kSecValueData as String] as? Data
            return errSecSuccess
        }, add: { query, _ in
            let q = query as! [String: Any]
            self.lastAdded = q
            guard self.status == errSecSuccess else { return self.status }
            self.values[q[kSecAttrAccount as String] as! String] = q[kSecValueData as String] as? Data
            return errSecSuccess
        }, delete: { query in
            let q = query as! [String: Any]
            self.queries.append(q)
            guard self.status == errSecSuccess else { return self.status }
            guard self.values.removeValue(forKey: q[kSecAttrAccount as String] as! String) != nil else { return errSecItemNotFound }
            return errSecSuccess
        })
    }
}

@main
@MainActor
struct SupabaseAuthTests {
    static var checks = 0
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static let userID = UUID(uuidString: "e7591e41-bc54-4466-aa69-944beff30a2d")!
    nonisolated static let otherID = UUID(uuidString: "58d0f36e-99c1-4dc1-ad18-fc6bea2608fa")!

    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    static func throwsError(_ expected: SupabaseAuthError, _ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected \(expected)") }
        catch let error as SupabaseAuthError { check(error == expected, "Wrong typed error \(error)") }
        catch { preconditionFailure("Unexpected error \(type(of: error))") }
    }
    static func throwsAsync(_ expected: SupabaseAuthError, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure("Expected \(expected)") }
        catch let error as SupabaseAuthError { check(error == expected, "Wrong typed error \(error)") }
        catch { preconditionFailure("Unexpected error \(type(of: error))") }
    }
    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    static func jwt(role: String) -> String {
        func part(_ value: Any) -> String {
            json(value).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return part(["alg": "HS256", "typ": "JWT"]) + "." + part(["role": role]) + ".signature"
    }
    static func config() throws -> SupabaseConfiguration {
        try SupabaseConfiguration(projectURL: URL(string: "https://bist-test.supabase.co")!,
                                  publishableKey: "sb_publishable_fixture")
    }
    static func token(_ id: UUID = userID, expiresIn: Int = 3600) -> Data {
        json(["access_token": "access-fixture", "refresh_token": "refresh-fixture", "token_type": "bearer",
              "expires_in": expiresIn, "user": ["id": id.uuidString, "email": "bist@example.com"]])
    }
    static func user(_ id: UUID = userID) -> Data { json(["id": id.uuidString, "email": "bist@example.com"]) }
    static func session() -> SupabaseSession {
        SupabaseSession(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now,
                        userID: userID, email: "bist@example.com")
    }
    static func main() async throws {
        let normalized = try SupabaseConfiguration(projectURL: URL(string: "https://BIST-TEST.supabase.co:443/")!,
                                                   publishableKey: "  sb_publishable_fixture\n")
        check(normalized.projectURL.absoluteString == "https://bist-test.supabase.co", "Normalize project origin")
        check(normalized.scope == "https://bist-test.supabase.co", "Scope must use canonical project origin")
        check(normalized.publishableKey == "sb_publishable_fixture", "Trim a pasted public key")
        for url in ["http://bist-test.supabase.co", "https://user:password@bist-test.supabase.co",
                    "https://bist-test.supabase.co/rest/v1", "https://bist-test.supabase.co?key=x",
                    "https://bist-test.supabase.co#token", "file:///tmp/project"] {
            throwsError(.invalidConfiguration) { _ = try SupabaseConfiguration(projectURL: URL(string: url)!, publishableKey: "sb_publishable_fixture") }
        }
        for key in ["", "sb_secret_fixture", jwt(role: "service_role"), jwt(role: "authenticated"),
                    "not-a-public-key", "sb_publishable_has space", "sb_publishable_a\r\nHeader:value"] {
            throwsError(.invalidConfiguration) { _ = try SupabaseConfiguration(projectURL: normalized.projectURL, publishableKey: key) }
        }
        let legacy = try SupabaseConfiguration(projectURL: normalized.projectURL, publishableKey: jwt(role: "anon"))
        check(legacy.publishableKey == jwt(role: "anon"), "Legacy anon keys remain supported")
        let invalidSaved = json(["projectURL": "http://bad.example", "publishableKey": "sb_publishable_fixture"])
        do { _ = try JSONDecoder().decode(SupabaseConfiguration.self, from: invalidSaved); preconditionFailure("Stored config must be validated") }
        catch { checks += 1 }

        let otpStub = AuthHTTPStub([.init(status: 200, data: Data())])
        let otp = SupabaseAuthClient(configuration: try config(), sender: otpStub.sender, now: { now })
        try await otp.requestCode(email: "  Bist@Example.com \n")
        let request = await otpStub.requests[0]
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(request.url?.absoluteString == "https://bist-test.supabase.co/auth/v1/otp", "OTP route")
        check(request.httpMethod == "POST", "OTP uses POST")
        check(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_fixture", "Public API key header")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "Publishable keys are not bearer tokens")
        check(body["email"] as? String == "bist@example.com", "Normalize email")
        check(body["create_user"] as? Bool == true, "Allow the account's initial OTP sign in")
        check(request.timeoutInterval <= 30, "Bound network wait")
        check(request.cachePolicy == .reloadIgnoringLocalCacheData, "Auth requests must not use cached credentials")
        for email in ["", "not-an-email", "a@", "@example.com", "bist@example.com\r\nHeader:value"] {
            await throwsAsync(.invalidEmail) { try await otp.requestCode(email: email) }
        }
        for code in ["", "12345", "12345678901", "123 456", "１２３４５６", "123abc"] {
            await throwsAsync(.invalidCode) { _ = try await otp.verifyCode(email: "bist@example.com", code: code) }
        }
        check(await otpStub.requests.count == 1, "Reject invalid inputs before sending")

        let verifyStub = AuthHTTPStub([.init(status: 200, data: token()), .init(status: 200, data: user())])
        let verifier = SupabaseAuthClient(configuration: try config(), sender: verifyStub.sender, now: { now })
        let verified = try await verifier.verifyCode(email: "bist@example.com", code: " 123456 ")
        let verifyRequests = await verifyStub.requests
        let verifyBody = try JSONSerialization.jsonObject(with: verifyRequests[0].httpBody!) as! [String: Any]
        check(verifyBody["type"] as? String == "email", "Use the email verification type")
        check(verifyBody["token"] as? String == "123456", "Trim OTP")
        check(verifyRequests[1].url?.path == "/auth/v1/user", "Verify identity at Auth user endpoint")
        check(verifyRequests[1].httpMethod == "GET", "Identity check uses GET")
        check(verifyRequests[1].value(forHTTPHeaderField: "Authorization") == "Bearer access-fixture", "Verify the returned access token")
        check(verified.userID == userID && verified.email == "bist@example.com", "Use verified identity")
        check(verified.expiresAt == now.addingTimeInterval(3600), "Decode expires_in relative to request clock")
        check(verified.refreshToken == "refresh-fixture", "Keep rotated refresh credential")
        check(!String(describing: verified).contains("access-fixture") && !String(reflecting: verified).contains("refresh-fixture"),
              "Incidental session descriptions must redact credentials")

        let mismatched = AuthHTTPStub([.init(status: 200, data: token()), .init(status: 200, data: user(otherID))])
        let mismatchedClient = SupabaseAuthClient(configuration: try config(), sender: mismatched.sender, now: { now })
        await throwsAsync(.invalidSession) { _ = try await mismatchedClient.verifyCode(email: "bist@example.com", code: "123456") }
        let wrongEmail = AuthHTTPStub([.init(status: 200, data: token()), .init(status: 200, data: json(["id": userID.uuidString, "email": "other@example.com"]))])
        let wrongEmailClient = SupabaseAuthClient(configuration: try config(), sender: wrongEmail.sender, now: { now })
        await throwsAsync(.invalidSession) { _ = try await wrongEmailClient.verifyCode(email: "bist@example.com", code: "123456") }
        let expired = AuthHTTPStub([.init(status: 200, data: token(expiresIn: 0))])
        let expiredClient = SupabaseAuthClient(configuration: try config(), sender: expired.sender, now: { now })
        await throwsAsync(.invalidSession) { _ = try await expiredClient.verifyCode(email: "bist@example.com", code: "123456") }

        let refreshStub = AuthHTTPStub([.init(status: 200, data: token()), .init(status: 200, data: user())])
        let refresher = SupabaseAuthClient(configuration: try config(), sender: refreshStub.sender, now: { now })
        let refreshed = try await refresher.refresh(session())
        let refreshRequests = await refreshStub.requests
        check(refreshRequests[0].url?.query == "grant_type=refresh_token", "Refresh grant type")
        let refreshBody = try JSONSerialization.jsonObject(with: refreshRequests[0].httpBody!) as! [String: Any]
        check(refreshBody["refresh_token"] as? String == "old-refresh", "Refresh sends only its own credential")
        check(refreshed.userID == userID && refreshed.accessToken == "access-fixture", "Refresh verifies same identity")
        let changed = AuthHTTPStub([.init(status: 200, data: token(otherID)), .init(status: 200, data: user(otherID))])
        let changedClient = SupabaseAuthClient(configuration: try config(), sender: changed.sender, now: { now })
        await throwsAsync(.invalidSession) { _ = try await changedClient.refresh(session()) }
        let malformedUser = AuthHTTPStub([.init(status: 200, data: token()), .init(status: 200, data: json(["id": userID.uuidString, "email": "bad\r\nidentity"]))])
        let malformedUserClient = SupabaseAuthClient(configuration: try config(), sender: malformedUser.sender, now: { now })
        await throwsAsync(.invalidSession) { _ = try await malformedUserClient.refresh(session()) }

        let logoutStub = AuthHTTPStub([.init(status: 204, data: Data())])
        let logout = SupabaseAuthClient(configuration: try config(), sender: logoutStub.sender)
        try await logout.signOut(session())
        let logoutRequest = await logoutStub.requests[0]
        check(logoutRequest.url?.path == "/auth/v1/logout", "Logout route")
        check(logoutRequest.url?.query == "scope=local", "Signing out one device must not sign out its peer")
        check(logoutRequest.httpMethod == "POST", "Logout uses POST")

        for (status, expected) in [(401, SupabaseAuthError.unauthorized), (403, .unauthorized), (429, .rateLimited(retryAfter: 120)), (503, .unavailable)] {
            let stub = AuthHTTPStub([.init(status: status, data: json(["message": "SECRET access-fixture refresh-fixture"]), headers: ["Retry-After": "120"])])
            let client = SupabaseAuthClient(configuration: try config(), sender: stub.sender)
            await throwsAsync(expected) { try await client.requestCode(email: "bist@example.com") }
            check(!expected.localizedDescription.contains("SECRET") && !expected.localizedDescription.contains("fixture"), "Never reflect a response body into a UI error")
        }
        let failed = SupabaseAuthClient(configuration: try config(), sender: { _ in throw URLError(.notConnectedToInternet) })
        await throwsAsync(.network) { try await failed.requestCode(email: "bist@example.com") }
        let cancelled = SupabaseAuthClient(configuration: try config(), sender: { _ in throw CancellationError() })
        do { try await cancelled.requestCode(email: "bist@example.com"); preconditionFailure("Cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        let tooLarge = AuthHTTPStub([.init(status: 200, data: Data(repeating: 65, count: 256 * 1024 + 1))])
        let huge = SupabaseAuthClient(configuration: try config(), sender: tooLarge.sender)
        await throwsAsync(.malformedResponse) { try await huge.requestCode(email: "bist@example.com") }

        let authNetwork = SupabaseHTTP.session(for: .authentication).configuration
        let replicaNetwork = SupabaseHTTP.session(for: .replica).configuration
        check(authNetwork.timeoutIntervalForRequest == 30 && authNetwork.timeoutIntervalForResource == 45,
              "Auth requests keep a short bounded timeout")
        check(replicaNetwork.timeoutIntervalForRequest == 90 && replicaNetwork.timeoutIntervalForResource == 1_800,
              "The actual replica URLSession permits long progressing transfers rather than imposing the auth deadline")
        check(authNetwork.urlCache == nil && replicaNetwork.urlCache == nil
              && authNetwork.urlCredentialStorage == nil && replicaNetwork.urlCredentialStorage == nil,
              "Both actual URLSessions avoid persistent data and credentials")
        check(authNetwork.httpCookieStorage == nil && replicaNetwork.httpCookieStorage == nil
              && !authNetwork.httpShouldSetCookies && !replicaNetwork.httpShouldSetCookies,
              "Longer replica transfers must not enable cookie storage")

        let keychain = AuthKeychainStub()
        let store = KeychainSupabaseSessionStore(service: "bist.auth.tests", operations: keychain.operations)
        check(try store.load(scope: "project-one") == nil, "Missing credentials mean signed out")
        try store.save(verified, scope: "project-one")
        check(try store.load(scope: "project-one") == verified, "Keychain round trip")
        #if os(macOS)
        check(keychain.lastAdded[kSecAttrAccessible as String] == nil, "A login Keychain item must not claim unsupported iOS protection classes")
        check(keychain.lastAdded[kSecUseDataProtectionKeychain as String] as? Bool == false, "Ad-hoc Mac builds use their non-synchronizing login Keychain")
        #else
        check(keychain.lastAdded[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, "iPhone credentials stay on this device")
        #endif
        check(keychain.lastAdded[kSecAttrSynchronizable as String] as? Bool == false, "Never upload session credentials to iCloud Keychain")
        check(keychain.lastAdded[kSecAttrService as String] as? String == "bist.auth.tests", "Dedicated keychain service")
        try store.save(refreshed, scope: "project-one")
        check(try store.load(scope: "project-one") == refreshed, "Refresh replaces stored credentials atomically")
        check(keychain.lastUpdated[kSecValueData as String] != nil, "Use update instead of delete-before-add")
        check(try store.load(scope: "project-two") == nil, "Projects cannot read each other's sessions")
        try store.save(session(), scope: "project-two")
        try store.delete(scope: "project-one")
        check(try store.load(scope: "project-one") == nil, "Sign out removes only its session")
        check(try store.load(scope: "project-two") == session(), "A different project's credentials survive sign out")
        try store.delete(scope: "project-one")
        checks += 1
        keychain.status = errSecInteractionNotAllowed
        throwsError(.credentialStorage) { _ = try store.load(scope: "project-two") }
        throwsError(.credentialStorage) { try store.save(verified, scope: "project-two") }
        throwsError(.credentialStorage) { try store.delete(scope: "project-two") }
        keychain.status = errSecSuccess
        check(try store.load(scope: "project-two") == session(), "A locked keychain must not erase a session")
        keychain.values["project-two"] = Data("broken".utf8)
        throwsError(.credentialStorage) { _ = try store.load(scope: "project-two") }
        let unscoped = KeychainSupabaseSessionStore(service: "", operations: keychain.operations)
        throwsError(.credentialStorage) { _ = try unscoped.load(scope: "project-three") }
        print("PASS \(checks) Supabase authentication and credential storage checks")
    }
}
