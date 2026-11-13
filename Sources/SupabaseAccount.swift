import Foundation
import Combine

/// Native account UI owns no passwords. Only the Keychain holds bearer and
/// refresh credentials; the project file contains public connection settings.
@MainActor
final class SupabaseAccountController: ObservableObject {
    @Published private(set) var configuration: SupabaseConfiguration?
    @Published private(set) var session: SupabaseSession?
    @Published private(set) var error: String?
    @Published private(set) var working = false
    @Published private(set) var emailForCode: String?
    private let configurationURL: URL
    private let sessions: any SupabaseSessionStore
    private let sender: SupabaseHTTPSender?
    private var generation = 0
    private var refreshTask: Task<SupabaseSession, Error>?
    private var sessionNeedsPersistence = false
    private var pendingSignIn: (scope: String, email: String, session: SupabaseSession)?
    var willChange: (() -> Void)?
    var didChange: (() -> Void)?

    init(directory: URL, sessions: any SupabaseSessionStore = KeychainSupabaseSessionStore(), sender: SupabaseHTTPSender? = nil,
         useBundledDefaults: Bool = true) {
        configurationURL = directory.appendingPathComponent("supabase-project.json")
        self.sessions = sessions; self.sender = sender
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                let saved = try JSONDecoder().decode(SupabaseConfiguration.self, from: Data(contentsOf: configurationURL))
                configuration = try SupabaseConfiguration(projectURL: saved.projectURL, publishableKey: saved.publishableKey)
            } else if useBundledDefaults, let url = Bundle.main.object(forInfoDictionaryKey: "BistSupabaseURL") as? String,
                      let key = Bundle.main.object(forInfoDictionaryKey: "BistSupabasePublishableKey") as? String,
                      !url.isEmpty, !url.contains("$("), let parsed = URL(string: url) {
                configuration = try SupabaseConfiguration(projectURL: parsed, publishableKey: key)
            }
            if let configuration { session = try sessions.load(scope: configuration.scope) }
        } catch { self.error = "Couldn’t open the sync connection. Check the project settings and sign in again." }
    }

    func configure(projectURL: String, publishableKey: String) {
        do {
            guard let url = URL(string: projectURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw SupabaseSyncError.unavailable }
            let configuration = try SupabaseConfiguration(projectURL: url, publishableKey: publishableKey.trimmingCharacters(in: .whitespacesAndNewlines))
            try persistRenewedSession()
            // Prepare the complete scoped connection before changing any
            // persisted or live context. A locked Keychain must never leave a
            // prior project's bearer token paired with a newly selected URL.
            let nextSession = try sessions.load(scope: configuration.scope)
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: configurationURL, options: .atomic)
            willChange?()
            generation += 1; refreshTask?.cancel(); refreshTask = nil; pendingSignIn = nil; working = false; emailForCode = nil
            self.configuration = configuration
            session = nextSession
            error = nil
            didChange?()
        } catch { self.error = error.localizedDescription }
    }

    func requestCode(email: String) async {
        guard !working, let configuration else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count <= 320 else { error = "Enter the email address you want to use on both devices."; return }
        working = true; error = nil
        let current = generation
        defer { if generation == current { working = false } }
        do {
            try await SupabaseAuthClient(configuration: configuration, sender: sender).requestCode(email: email)
            guard current == generation else { return }
            emailForCode = email
            pendingSignIn = nil
        } catch { if current == generation { self.error = error.localizedDescription } }
    }

    func verifyCode(_ code: String) async {
        guard !working, let configuration, let email = emailForCode else { return }
        working = true; error = nil
        let current = generation
        defer { if generation == current { working = false } }
        do {
            let session: SupabaseSession
            if let pending = pendingSignIn, pending.scope == configuration.scope,
               pending.email.caseInsensitiveCompare(email) == .orderedSame, pending.session.expiresAt > Date() {
                // A verified OTP is consumed by the server. If Keychain was
                // locked, retry its write using this in-memory session instead
                // of consuming another code or losing the verified sign-in.
                session = pending.session
            } else {
                session = try await SupabaseAuthClient(configuration: configuration, sender: sender).verifyCode(email: email, code: code)
            }
            guard current == generation else { return }
            pendingSignIn = (configuration.scope, email, session)
            willChange?()
            try sessions.save(session, scope: configuration.scope)
            self.session = session; emailForCode = nil; pendingSignIn = nil
            sessionNeedsPersistence = false
            didChange?()
        } catch { if current == generation { self.error = error.localizedDescription } }
    }

    func accessToken() async throws -> String {
        try persistRenewedSession()
        guard configuration != nil, let session else { throw SupabaseSyncError.signInRequired }
        if session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        return try await refreshSession()
    }

    func refreshSession() async throws -> String {
        guard let configuration, let session else { throw SupabaseSyncError.signInRequired }
        if sessionNeedsPersistence {
            try persistRenewedSession()
            if session.expiresAt.timeIntervalSinceNow > 60 { return session.accessToken }
        }
        let current = generation
        let task: Task<SupabaseSession, Error>
        if let existing = refreshTask { task = existing }
        else {
            let client = SupabaseAuthClient(configuration: configuration, sender: sender)
            task = Task { try await client.refresh(session) }
            refreshTask = task
        }
        defer { if generation == current { refreshTask = nil } }
        let renewed = try await task.value
        guard current == generation, renewed.userID == session.userID else { throw CancellationError() }
        // Rotation has already happened on the server. Keep the verified new
        // credentials even if Keychain is temporarily locked, then retry that
        // write before another request can reuse the superseded refresh token.
        self.session = renewed
        sessionNeedsPersistence = true
        try persistRenewedSession()
        return renewed.accessToken
    }

    private func persistRenewedSession() throws {
        guard sessionNeedsPersistence, let configuration, let session else { return }
        try sessions.save(session, scope: configuration.scope)
        sessionNeedsPersistence = false
    }

    func signOut() async {
        let previous = session
        let configuration = configuration
        willChange?(); generation += 1; refreshTask?.cancel(); refreshTask = nil; pendingSignIn = nil; working = false; emailForCode = nil
        // Clear locally even offline. Logout revokes this refresh session only,
        // so signing out here does not sign out the other device.
        do {
            if let configuration { try sessions.delete(scope: configuration.scope) }
            session = nil; sessionNeedsPersistence = false; error = nil; didChange?()
        } catch { self.error = "Couldn’t remove the saved sign-in. Try signing out again."; return }
        if let configuration, let previous { try? await SupabaseAuthClient(configuration: configuration, sender: sender).signOut(previous) }
    }
}
