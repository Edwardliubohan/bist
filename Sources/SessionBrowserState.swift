import Foundation
import Combine
import Darwin

enum SessionCollection: String, CaseIterable { case recent, archived, saved, history }

struct SessionWorkspace: Identifiable {
    let directory: String
    let sessions: [LocalAgentSession]
    var id: String { directory }
    var title: String {
        directory == "/" ? "Root folder" : URL(fileURLWithPath: directory).lastPathComponent
    }
}

/// Search, filtering and disclosure are independent from task and session data.
final class SessionBrowserState: ObservableObject {
    @Published var collection: SessionCollection = .recent {
        didSet { if collection != oldValue { query = ""; provider = nil } }
    }
    @Published var selectedID: String?
    @Published var sending = Set<String>()
    @Published var drafts: [String: String] = [:]
    @Published private(set) var readDates: [String: Date] = [:]
    @Published var archiveError: String?
    private let directory: URL?
    private let prepareForWrite: (() -> Bool)?

    init(directory: URL? = nil, prepareForWrite: (() -> Bool)? = nil) {
        self.directory = directory
        self.prepareForWrite = prepareForWrite
        if let directory {
            do { readDates = try Self.load(directory) }
            catch { archiveError = "Couldn’t read the session archive. Check sessions-read.json and reopen bist." }
        }
    }
    private static func load(_ directory: URL) throws -> [String: Date] {
        let file = directory.appendingPathComponent("sessions-read.json")
        do { return try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [:] }
    }
    func isRead(_ session: LocalAgentSession) -> Bool { (readDates[session.id] ?? .distantPast) >= session.modifiedAt }
    @discardableResult func read(_ session: LocalAgentSession) -> Bool {
        do {
            var dates = readDates
            if let directory {
                if let prepareForWrite { guard prepareForWrite() else { throw CocoaError(.fileWriteUnknown) } }
                else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                let descriptor = open(directory.appendingPathComponent(".sessions-read.lock").path, O_CREAT | O_RDWR, 0o600)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { flock(descriptor, LOCK_UN) }
                dates = try Self.load(directory)
                dates[session.id] = max(dates[session.id] ?? .distantPast, session.modifiedAt)
                try JSONEncoder().encode(dates).write(to: directory.appendingPathComponent("sessions-read.json"), options: .atomic)
            } else { dates[session.id] = max(dates[session.id] ?? .distantPast, session.modifiedAt) }
            readDates = dates
            archiveError = nil
            return true
        } catch {
            archiveError = "Couldn’t archive this update. Check the data folder, then open it to retry."
            return false
        }
    }
    func acknowledge(_ session: LocalAgentSession, visible: Bool, running: Bool) {
        guard visible, selectedID == session.id, !running, !isRead(session) else { return }
        read(session)
    }
    func inbox(_ sessions: [LocalAgentSession], running: Set<String>, archived: Bool = false) -> [LocalAgentSession] {
        sessions.filter {
            !running.contains($0.id) && (archived || $0.activeThread) && (archived ? isRead($0) && !$0.requiresT3Response : !isRead($0) || $0.requiresT3Response) &&
            (provider == nil || provider == $0.provider) && matches("\($0.title) \($0.activity) \($0.directory) \($0.sessionID) \($0.provider.displayName)")
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @Published var query = ""
    @Published var provider: SessionProvider?
    @Published var expandedWorkspaces = Set<String>()
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func matches(_ text: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
    func workspaces(_ sessions: [LocalAgentSession]) -> [SessionWorkspace] {
        let filtered = sessions.filter {
            (provider == nil || provider == $0.provider) && matches("\($0.directory) \($0.sessionID.uuidString) \($0.provider.displayName)")
        }
        return Dictionary(grouping: filtered, by: \.directory).map { directory, values in
            SessionWorkspace(directory: directory, sessions: values.sorted {
                $0.modifiedAt == $1.modifiedAt ? $0.id < $1.id : $0.modifiedAt > $1.modifiedAt
            })
        }.sorted {
            let first = $0.sessions[0].modifiedAt, second = $1.sessions[0].modifiedAt
            return first == second ? $0.directory < $1.directory : first > second
        }
    }
    func savedLinks(_ sessions: [SessionItem]) -> [SessionItem] {
        sessions.filter {
            (provider == nil || provider == $0.provider) && matches("\($0.title) \($0.url ?? "") \($0.provider.displayName)")
        }
    }
    func toggle(_ workspace: String) {
        if !expandedWorkspaces.insert(workspace).inserted { expandedWorkspaces.remove(workspace) }
    }
}

extension SessionProvider {
    var shortName: String {
        switch self { case .codex: return "Codex"; case .claudeCode: return "Claude"; case .muse: return "Meta Muse" }
    }
    var symbol: String {
        switch self { case .codex: return "command"; case .claudeCode: return "asterisk"; case .muse: return "infinity" }
    }
}
