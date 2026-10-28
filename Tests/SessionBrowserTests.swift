import AppKit
import SwiftUI

@main
struct SessionBrowserTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-session-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, demo: false)
        let browser = SessionBrowserState()
        let now = Date()
        let oldestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let latestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessions = [
            LocalAgentSession(provider: .codex, sessionID: oldestID, directory: "/Users/example/Projects/bist", modifiedAt: now.addingTimeInterval(-3600), name: "Inbox layout", activity: "Checked the compact row spacing", preview: "The sessions inbox now uses one compact line per session.\n\nAll checks passed; ready for your review."),
            LocalAgentSession(provider: .claudeCode, sessionID: latestID, directory: "/Users/example/Projects/bist", modifiedAt: now, name: "Native caret", activity: "Checking focus after activation", preview: "I’m checking keyboard focus and the native insertion caret after the panel opens."),
            LocalAgentSession(provider: .codex, sessionID: UUID(), directory: "/Users/example/Archive/bist", modifiedAt: now.addingTimeInterval(-600), name: "Task sorting", activity: "Reorder tests passed"),
            LocalAgentSession(provider: .claudeCode, sessionID: UUID(), directory: "/Users/example/Projects/A very long workspace name for a research project", modifiedAt: now.addingTimeInterval(-900)),
            LocalAgentSession(provider: .codex, sessionID: UUID(), directory: "/", modifiedAt: now.addingTimeInterval(-7200))
        ]
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        var groups = browser.workspaces(sessions)
        expect(groups.count == 4, "Same basename in different directories remains distinct")
        expect(groups[0].sessions.map(\.sessionID) == [latestID, oldestID], "Workspace mixes providers and keeps newest session first")
        expect(groups[1].directory == "/Users/example/Archive/bist", "Workspace order follows last saved activity")
        expect(groups.last?.title == "Root folder", "Root workspace has a readable name")
        expect(groups.reduce(0) { $0 + $1.sessions.count } == sessions.count, "Grouping preserves every session identity")
        browser.provider = .codex
        groups = browser.workspaces(sessions)
        expect(groups[0].directory == "/Users/example/Archive/bist", "Provider filter recomputes workspace recency")
        expect(groups.flatMap(\.sessions).allSatisfy { $0.provider == .codex }, "Provider filter is exact")
        browser.query = "PROJECTS BIST"
        expect(browser.workspaces(sessions).flatMap(\.sessions).map(\.sessionID) == [oldestID], "Search is case-insensitive and all terms must match")
        browser.query = "11111111"; browser.provider = nil
        expect(browser.workspaces(sessions).flatMap(\.sessions).map(\.sessionID) == [oldestID], "Search finds an older/hidden session by ID")
        browser.query = " \n "
        expect(!browser.isSearching && browser.workspaces(sessions).count == 4, "Whitespace behaves as an empty search")
        browser.toggle(sessions[0].directory)
        expect(browser.expandedWorkspaces.contains(sessions[0].directory), "Workspace disclosure retains its identity")
        browser.query = "bist"; browser.provider = .codex; browser.collection = .saved
        expect(browser.query.isEmpty && browser.provider == nil, "Switching collections starts with clear filters")
        expect(browser.expandedWorkspaces.contains(sessions[0].directory), "Collection switching preserves disclosure state")
        expect(store.addSession(provider: .codex, title: "bist design review", url: "https://example.com/review"), "Saved link fixture added")
        expect(store.addSession(provider: .claudeCode, title: "A saved conversation with a long descriptive title that wraps onto two lines", url: "https://example.com/conversation"), "Long saved link fixture added")
        browser.query = "REVIEW"
        expect(browser.savedLinks(store.sessions).count == 1, "Saved links search both titles and URLs")
        browser.query = "example.com"; browser.provider = .claudeCode
        expect(browser.savedLinks(store.sessions).count == 1, "Saved link provider filter combines with URL search")
        browser.query = "not a match"
        expect(browser.savedLinks(store.sessions).isEmpty, "No-match state has no unrelated results")
        browser.provider = nil; browser.query = ""
        let beforeTasks = store.tasks, beforeLinks = store.sessions
        let connection = LocalSessionConnection(scan: LocalSessionScan(sessions: sessions, messages: [.codex: "Local sessions connected", .claudeCode: "Local sessions connected"]))
        let focus = BistFocusContext()
        let panel = NSPanel(contentRect: CGRect(x: 50, y: 50, width: 360, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        var browserActive = false
        func root(_ source: LocalSessionConnection, data: AppStore) -> some View {
            VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Tasks").foregroundColor(muted)
                Text("Sessions").fontWeight(.semibold)
                Spacer()
                BistFace(size: 25, isExpanded: true)
            }.font(.system(size: 13)).padding(.horizontal, 20).frame(height: 48)
            SessionsPane(store: data, connection: source, browser: browser, active: browserActive, addLink: {})
            }.background(ivory).preferredColorScheme(.light).tint(accent).environmentObject(focus)
                .environmentObject(BobotStore(directory: directory))
        }
        func capture(_ name: String, size: CGSize = CGSize(width: 360, height: 560), source: LocalSessionConnection? = nil, data: AppStore? = nil) throws {
            let host = GlassHostingView(rootView: root(source ?? connection, data: data ?? store))
            host.sizingOptions = []
            panel.contentView = host
            panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: false)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Cannot capture native sessions fixture") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/sessions-\(name).png"))
        }
        connection.running = [sessions[1].id]
        connection.managedSessions[sessions[1].id] = sessions[1]
        browser.collection = .recent; browser.expandedWorkspaces = []
        try capture("recent")
        browser.toggle(sessions[0].directory)
        try capture("expanded")
        browser.read(sessions[0])
        browser.collection = .archived
        try capture("archive")
        browser.collection = .recent
        browser.selectedID = sessions[1].id
        browser.drafts[sessions[1].id] = "Please check the inbox layout."
        try capture("reply")
        browser.selectedID = nil
        browser.query = "22222222"
        try capture("search")
        browser.query = "No such workspace"
        try capture("no-matches")
        browser.collection = .saved
        try capture("saved")
        browser.collection = .recent
        try capture("small", size: CGSize(width: 320, height: 400))
        browser.query = ""; browser.expandedWorkspaces = []
        let empty = LocalSessionConnection(scan: LocalSessionScan(messages: [.codex: "No local session folder found", .claudeCode: "No local session folder found"]))
        try capture("empty", source: empty)
        try capture("loading", source: LocalSessionConnection())
        let emptyStore = AppStore(directory: directory.appendingPathComponent("empty"), demo: false)
        browser.collection = .saved
        try capture("empty-saved", source: empty, data: emptyStore)
        browser.collection = .recent
        browser.selectedID = sessions[2].id
        try capture("hidden-detail")
        expect(!browser.isRead(sessions[2]), "Mounted hidden detail does not acknowledge unread content")
        browserActive = true
        try capture("visible-detail")
        expect(browser.isRead(sessions[2]), "Remounting visible detail acknowledges its initial displayed update")
        expect(store.tasks == beforeTasks && store.sessions == beforeLinks, "Browsing and rendering never changes user data")
        print("PASS: \(checks) session-browser checks; native captures cover grouping, older sessions, search, no matches, saved links, long names and a smaller panel")
    }
}
