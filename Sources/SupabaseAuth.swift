import Foundation
import Security

enum SupabaseAuthError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidEmail
    case invalidCode
    case invalidSession
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable
    case network
    case malformedResponse
    case requestRejected
    case credentialStorage

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Enter an HTTPS Supabase project URL and its publishable key. Secret keys stay on the server."
        case .invalidEmail: return "Enter a valid email address."
        case .invalidCode: return "Enter the numeric code from your sign-in email."
        case .invalidSession: return "Your sign-in could not be verified. Request a new code and try again."
        case .unauthorized: return "Your sign-in has expired or was refused. Sign in again."
        case .rateLimited: return "Too many sign-in attempts. Wait a little before trying again."
        case .unavailable: return "Supabase is temporarily unavailable. Your local data is still saved."
        case .network: return "Couldn’t reach Supabase. Check your connection and try again."
        case .malformedResponse: return "Supabase returned an unreadable response. Your local data is unchanged."
        case .requestRejected: return "Sign-in could not be completed. Check your project’s email settings and try again."
        case .credentialStorage: return "Couldn’t access your saved sign-in securely. Unlock this device and try again."
        }
    }
}

struct SupabaseConfiguration: Codable, Equatable, Sendable {
    let projectURL: URL
    let publishableKey: String
    var scope: String { projectURL.absoluteString }

    init(projectURL: URL, publishableKey: String) throws {
        guard var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, ["", "/"].contains(components.percentEncodedPath),
              components.port.map({ $0 > 0 && $0 <= 65535 }) ?? true else {
            throw SupabaseAuthError.invalidConfiguration
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        if components.port == 443 { components.port = nil }
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 16 * 1024, Self.isPublicKey(key), let normalized = components.url else {
            throw SupabaseAuthError.invalidConfiguration
        }
        self.projectURL = normalized
        self.publishableKey = key
    }

    private enum CodingKeys: String, CodingKey { case projectURL, publishableKey }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(projectURL: values.decode(URL.self, forKey: .projectURL),
                      publishableKey: values.decode(String.self, forKey: .publishableKey))
    }

    private static func isPublicKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_publishable_") {
            let suffix = key.dropFirst("sb_publishable_".count)
            return !suffix.isEmpty && suffix.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
        }
        // This identifies the legacy anon key format, not an authenticated
        // identity. Supabase still verifies the actual key and user JWT.
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["role"] as? String == "anon"
    }
}

struct SupabaseSession: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: UUID
    let email: String?
    var description: String { "SupabaseSession(userID: \(userID.uuidString))" }
    var debugDescription: String { description }

    init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }

    fileprivate var isWellFormed: Bool {
        Self.validCredential(accessToken) && Self.validCredential(refreshToken)
            && expiresAt.timeIntervalSince1970.isFinite
            && (email.map { $0.utf8.count <= 320 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) } ?? true)
    }

    fileprivate static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 * 1024 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

typealias SupabaseHTTPSender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

private final class SupabaseRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a bearer token or API key to a redirect destination.
        completionHandler(nil)
    }
}

enum SupabaseHTTP {
    enum Transfer { case authentication, replica }
    private static let authSession = makeSession(idle: 30, total: 45)
    private static let replicaSession = makeSession(idle: 90, total: 1_800)

    static func session(for transfer: Transfer) -> URLSession {
        transfer == .authentication ? authSession : replicaSession
    }

    private static func makeSession(idle: TimeInterval, total: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = idle
        configuration.timeoutIntervalForResource = total
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: SupabaseRedirectBlocker(), delegateQueue: nil)
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, maximumResponseBytes: 256 * 1024)
    }

    static func send(_ request: URLRequest, maximumResponseBytes: Int, transfer: Transfer = .authentication) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, maximumResponseBytes > 0,
              maximumResponseBytes <= 128 * 1024 * 1024 else { throw SupabaseAuthError.invalidConfiguration }
        var bounded = request
        let session = session(for: transfer)
        bounded.timeoutInterval = min(max(request.timeoutInterval, 1), session.configuration.timeoutIntervalForRequest)
        bounded.cachePolicy = .reloadIgnoringLocalCacheData
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: bounded)
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw SupabaseAuthError.malformedResponse
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 16 * 1024))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw SupabaseAuthError.malformedResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}

struct SupabaseAuthClient: Sendable {
    let configuration: SupabaseConfiguration
    private let sender: SupabaseHTTPSender
    private let now: @Sendable () -> Date

    init(configuration: SupabaseConfiguration, sender: SupabaseHTTPSender? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.sender = sender ?? { try await SupabaseHTTP.send($0) }
        self.now = now
    }

    func requestCode(email: String) async throws {
        let email = try Self.normalizedEmail(email)
        _ = try await request(path: "otp", body: OTPRequest(email: email, create_user: true))
    }

    func verifyCode(email: String, code: String) async throws -> SupabaseSession {
        let email = try Self.normalizedEmail(email)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...10).contains(code.utf8.count), code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw SupabaseAuthError.invalidCode
        }
        let data = try await request(path: "verify", body: VerifyRequest(type: "email", email: email, token: code))
        let session = try decodeSession(data)
        let verifiedUser = try await verifiedUser(accessToken: session.accessToken)
        guard verifiedUser.id == session.userID,
              let verifiedEmail = verifiedUser.email, try Self.normalizedEmail(verifiedEmail) == email else {
            throw SupabaseAuthError.invalidSession
        }
        return SupabaseSession(accessToken: session.accessToken, refreshToken: session.refreshToken,
                               expiresAt: session.expiresAt, userID: verifiedUser.id, email: verifiedEmail)
    }

    func refresh(_ session: SupabaseSession) async throws -> SupabaseSession {
        guard session.isWellFormed else { throw SupabaseAuthError.invalidSession }
        let data = try await request(path: "token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                     body: RefreshRequest(refresh_token: session.refreshToken))
        let refreshed = try decodeSession(data)
        let verifiedUser = try await verifiedUser(accessToken: refreshed.accessToken)
        guard refreshed.userID == session.userID, verifiedUser.id == session.userID else {
            throw SupabaseAuthError.invalidSession
        }
        return SupabaseSession(accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken,
                               expiresAt: refreshed.expiresAt, userID: verifiedUser.id, email: verifiedUser.email)
    }

    func signOut(_ session: SupabaseSession) async throws {
        guard session.isWellFormed else { throw SupabaseAuthError.invalidSession }
        do {
            _ = try await request(path: "logout", query: [URLQueryItem(name: "scope", value: "local")],
                                  body: EmptyBody(), accessToken: session.accessToken)
        } catch SupabaseAuthError.unauthorized {
            // An expired/revoked token is already signed out. The owner still
            // deletes its local Keychain entry, without revoking the peer.
        }
    }

    func user(accessToken: String) async throws -> UUID { try await verifiedUser(accessToken: accessToken).id }

    private func verifiedUser(accessToken: String) async throws -> AuthUser {
        let data = try await request(path: "user", method: "GET", body: Optional<EmptyBody>.none,
                                     accessToken: accessToken)
        let user: AuthUser
        do { user = try JSONDecoder().decode(AuthUser.self, from: data) }
        catch { throw SupabaseAuthError.malformedResponse }
        if let email = user.email, (try? Self.normalizedEmail(email)) == nil {
            throw SupabaseAuthError.invalidSession
        }
        return user
    }

    private func decodeSession(_ data: Data) throws -> SupabaseSession {
        let token: TokenResponse
        do { token = try JSONDecoder().decode(TokenResponse.self, from: data) }
        catch { throw SupabaseAuthError.malformedResponse }
        let date = now()
        let expiry = token.expires_at.map(Date.init(timeIntervalSince1970:))
            ?? token.expires_in.map { date.addingTimeInterval($0) }
        guard let expiry, expiry.timeIntervalSince1970.isFinite, expiry > date,
              token.token_type.lowercased() == "bearer" else { throw SupabaseAuthError.invalidSession }
        let session = SupabaseSession(accessToken: token.access_token, refreshToken: token.refresh_token,
                                      expiresAt: expiry, userID: token.user.id, email: token.user.email)
        guard session.isWellFormed else { throw SupabaseAuthError.invalidSession }
        return session
    }

    private func request<Body: Encodable>(path: String, method: String = "POST", query: [URLQueryItem] = [],
                                          body: Body?, accessToken: String? = nil) async throws -> Data {
        try Task.checkCancellation()
        if let accessToken, !SupabaseSession.validCredential(accessToken) { throw SupabaseAuthError.invalidSession }
        var components = URLComponents(url: configuration.projectURL.appendingPathComponent("auth/v1/\(path)"),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await sender(request)
            try Task.checkCancellation()
            guard data.count <= 256 * 1024, response.url == request.url else { throw SupabaseAuthError.malformedResponse }
            switch response.statusCode {
            case 200..<300: return data
            case 401, 403: throw SupabaseAuthError.unauthorized
            case 429:
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw SupabaseAuthError.rateLimited(retryAfter: retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            case 500..<600: throw SupabaseAuthError.unavailable
            case 300..<400: throw SupabaseAuthError.malformedResponse
            default: throw SupabaseAuthError.requestRejected
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SupabaseAuthError { throw error }
        catch { throw SupabaseAuthError.network }
    }

    private static func normalizedEmail(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 320, parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw SupabaseAuthError.invalidEmail
        }
        return email
    }

    private struct OTPRequest: Encodable { let email: String; let create_user: Bool }
    private struct VerifyRequest: Encodable { let type: String; let email: String; let token: String }
    private struct RefreshRequest: Encodable { let refresh_token: String }
    private struct EmptyBody: Encodable {}
    private struct AuthUser: Decodable { let id: UUID; let email: String? }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let token_type: String
        let expires_at: TimeInterval?
        let expires_in: TimeInterval?
        let user: AuthUser
    }
}

protocol SupabaseSessionStore: AnyObject {
    func load(scope: String) throws -> SupabaseSession?
    func save(_ session: SupabaseSession, scope: String) throws
    func delete(scope: String) throws
}

struct SupabaseKeychainOperations {
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    static let system = SupabaseKeychainOperations(copyMatching: { SecItemCopyMatching($0, $1) },
                                                  update: { SecItemUpdate($0, $1) },
                                                  add: { SecItemAdd($0, $1) }, delete: { SecItemDelete($0) })
}

final class KeychainSupabaseSessionStore: SupabaseSessionStore, @unchecked Sendable {
    private let service: String
    private let operations: SupabaseKeychainOperations
    private let lock = NSLock()

    init(service: String = "local.bist.supabase.session.v1", operations: SupabaseKeychainOperations = .system) {
        self.service = service
        self.operations = operations
    }

    func load(scope: String) throws -> SupabaseSession? {
        lock.lock(); defer { lock.unlock() }
        var query = try baseQuery(scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 256 * 1024,
              let session = try? JSONDecoder().decode(SupabaseSession.self, from: data), session.isWellFormed else {
            throw SupabaseAuthError.credentialStorage
        }
        return session
    }

    func save(_ session: SupabaseSession, scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        let query = try baseQuery(scope: scope)
        guard session.isWellFormed, let data = try? JSONEncoder().encode(session), data.count <= 256 * 1024 else {
            throw SupabaseAuthError.credentialStorage
        }
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        var status = operations.update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            for (key, value) in attributes { addition[key] = value }
            status = operations.add(addition as CFDictionary, nil)
            if status == errSecDuplicateItem { status = operations.update(query as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw SupabaseAuthError.credentialStorage }
    }

    func delete(scope: String) throws {
        lock.lock(); defer { lock.unlock() }
        let status = operations.delete(try baseQuery(scope: scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SupabaseAuthError.credentialStorage }
    }

    private func baseQuery(scope: String) throws -> [String: Any] {
        guard !scope.isEmpty, scope.utf8.count <= 4096,
              !scope.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !service.isEmpty, service.utf8.count <= 512,
              !service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SupabaseAuthError.credentialStorage
        }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: scope,
                                    kSecAttrSynchronizable as String: false]
        #if os(macOS)
        // The ordinary Mac app is ad-hoc signed. The Data Protection keychain
        // requires signing entitlements it does not have. Use the login
        // Keychain and its access controls, with synchronization explicitly off.
        // iOS accessibility classes do not apply to this macOS keychain.
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
        return query
    }
}
