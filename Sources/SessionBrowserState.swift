import Foundation
import Combine

enum SessionCollection: String, CaseIterable { case recent, saved }

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
