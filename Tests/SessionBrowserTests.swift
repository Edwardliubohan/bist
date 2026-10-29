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
        var external = sessions[0]
        external.threadID = external.sessionID.uuidString.lowercased()
        external.externalRunning = true
        external.activity = "Checking session detection · 2 helpers"
        external.childCount = 2
        var question = sessions[1]
        question.threadID = question.sessionID.uuidString.lowercased()
        question.preview = "The inbox now groups work by session. Tests pass.\n\nWhich row density would you prefer?\n- Compact rows\n- Roomier rows"
        question.activity = "Which row density would you prefer?"
        let t3 = LocalSessionConnection(scan: LocalSessionScan(t3: T3SessionScan(sessions: [external, question, sessions[2]], connected: true)))
        browser.query = ""; browser.selectedID = nil
        try capture("threads", source: t3)
        browser.selectedID = question.id
        try capture("question", source: t3)
        browser.selectedID = nil
        let preview = SessionHoverAnchor()
        preview.frame = CGRect(x: 0, y: 0, width: 200, height: 49)
        let trackingHost = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 560))
        trackingHost.addSubview(preview)
        panel.contentView = trackingHost
        panel.setFrame(CGRect(x: 700, y: 200, width: 360, height: 560), display: false)
        panel.orderFrontRegardless()
        preview.session = question
        preview.show(verifyPointer: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.22))
        guard let hover = NSApplication.shared.windows.first(where: { $0.title == "bist session preview" && $0.isVisible }),
              let hoverHost = hover.contentView else { preconditionFailure("Native preview must reveal") }
        expect(!hover.canBecomeKey && !hover.canBecomeMain, "Hover never takes keyboard focus")
        expect(hover.frame.maxX < panel.frame.minX, "Actual native preview opens beside the panel on its left")
        let bitmap = hoverHost.bitmapImageRepForCachingDisplay(in: hoverHost.bounds)!
        hoverHost.cacheDisplay(in: hoverHost.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/sessions-hover.png"))
        preview.dismiss()
        preview.show(verifyPointer: false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.22))
        expect(hover.isVisible, "A stale exit cannot dismiss a newer hover entrance")
        preview.reduced = true
        preview.show(verifyPointer: false)
        expect(hover.contentView?.layer?.animation(forKey: "session-reveal") == nil, "Reduced motion has no translation animation")
        preview.shutdown()
        expect(!hover.isVisible && hover.parent == nil, "Removing the row closes and detaches the hover window")
        panel.orderOut(nil)
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
        // Readable excerpts and blocks for the triage inbox.
        expect(SessionText.plain("Adding a `--sessions` **launch** flag") == "Adding a --sessions launch flag", "Excerpts drop inline markdown")
        expect(SessionText.plain("## Done\n\nSee [the PR](https://example.com) now") == "Done See the PR now", "Excerpts drop headings and link targets")
        expect(SessionText.plain("4. *Blocking integrity checks.") == "4. Blocking integrity checks.", "A dangling emphasis marker is removed")
        expect(SessionText.plain("2 * 3 = 6") == "2 * 3 = 6", "Spaced asterisks stay as text")
        let blocks = SessionText.blocks("Round 4 is done.\n\n1. **Stdin** isolation\n2. Hash-then-parse\n  - nested\n\n```\nswift test\n```\n# Next")
        expect(blocks == [.paragraph("Round 4 is done."), .item("1.", "**Stdin** isolation", 0), .item("2.", "Hash-then-parse", 0),
                          .item("•", "nested", 1), .code("swift test"), .heading("Next")], "Markdown becomes paragraphs, list items, code and headings")
        expect(SessionText.age(now.addingTimeInterval(-20), now: now) == "now", "Recent activity reads as now")
        expect(SessionText.age(now.addingTimeInterval(-4 * 60), now: now) == "4m", "Minutes use a compact column")
        expect(SessionText.age(now.addingTimeInterval(-3 * 3600), now: now) == "3h", "Hours use a compact column")
        expect(SessionText.age(now.addingTimeInterval(-2 * 86_400), now: now) == "2d", "Days use a compact column")
        var meta = sessions[0]; meta.childCount = 2
        expect(meta.meta == "bist · Codex · 2 helpers", "Row meta names project, agent and helpers")
        expect(sessions[4].meta == "Root folder · Codex", "Root workspace meta stays readable")
        // Keyboard triage moves through the visible order and stops at either end.
        let order = ["q", "r", "u1", "u2"]
        expect(SessionTriage.neighbor(of: nil, in: order, step: 1) == "q", "Down with nothing selected starts at the top")
        expect(SessionTriage.neighbor(of: nil, in: order, step: -1) == "u2", "Up with nothing selected starts at the bottom")
        expect(SessionTriage.neighbor(of: "r", in: order, step: 1) == "u1", "Down moves to the next row")
        expect(SessionTriage.neighbor(of: "r", in: order, step: -1) == "q", "Up moves to the previous row")
        expect(SessionTriage.neighbor(of: "u2", in: order, step: 1) == nil, "Down at the end has no next row")
        expect(SessionTriage.neighbor(of: "q", in: order, step: -1) == nil, "Up at the start has no previous row")
        expect(SessionTriage.neighbor(of: "gone", in: order, step: 1) == "q", "A row that left the list restarts at the top")
        expect(SessionTriage.neighbor(of: "q", in: [], step: 1) == nil, "An empty list has no rows")
        // Search covers Archive and History by title, project, agent and activity.
        browser.provider = nil
        browser.query = "caret"
        expect(SessionTriage.search(sessions, browser: browser).map(\.sessionID) == [latestID], "Search matches the activity title")
        browser.query = "archive codex"
        expect(SessionTriage.search(sessions, browser: browser).count == 1, "Every search word must match")
        browser.query = ""
        expect(SessionTriage.search(sessions, browser: browser).count == sessions.count, "An empty search keeps every session")
        expect(SessionText.plain("Fixed `__init__` in `*ptr` handling") == "Fixed __init__ in *ptr handling", "Inline code keeps its exact characters")
        expect(SessionText.blocks("- parent\n\t- tab child\n    - four child") == [.item("•", "parent", 0), .item("•", "tab child", 1), .item("•", "four child", 1)], "Tab and four-space indents nest one level")
        let batch = SessionBrowserState()
        expect(batch.read(Array(sessions.prefix(3))), "Mark all read succeeds")
        expect(sessions.prefix(3).allSatisfy(batch.isRead) && !batch.isRead(sessions[3]), "Mark all read covers exactly the given updates")
        print("PASS: \(checks) session-browser checks; native captures cover grouping, older sessions, search, no matches, saved links, long names and a smaller panel")
    }
}
