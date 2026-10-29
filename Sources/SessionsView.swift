import AppKit
import SwiftUI

/// A triage inbox. What needs you comes first, then what is running, then what changed.
struct SessionsPane: View {
    @EnvironmentObject private var bobot: BobotStore
    @State private var selectedBobotID: String?
    @ObservedObject var store: AppStore
    @ObservedObject var connection: LocalSessionConnection
    @ObservedObject var browser: SessionBrowserState
    let active: Bool
    let addLink: () -> Void
    @State private var changedLink = false
    @State private var showFullResponse = false
    @State private var hoveredID: String?
    @State private var showBobotSetup = false
    @State private var keyboardID: String?
    @State private var keyboardIndex: Int?
    @State private var triageOrder: [String] = []
    @FocusState private var listFocused: Bool
    @Environment(\.bistReduced) private var reduced
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    private var sessions: [LocalAgentSession] { browser.collection == .history ? connection.scan.sessions : connection.inboxSessions }
    private var selected: LocalAgentSession? { sessions.first { $0.id == browser.selectedID } }
    private var running: [LocalAgentSession] { sessions.filter { connection.busyIDs.contains($0.id) } }
    private var updates: [LocalAgentSession] { browser.inbox(sessions, running: connection.busyIDs, archived: browser.collection == .archived) }
    private var questions: [LocalAgentSession] { updates.filter { $0.awaitingReply } }
    private var notices: [LocalAgentSession] { updates.filter { !$0.awaitingReply } }
    private var initialLoad: Bool { connection.scan.messages.isEmpty && sessions.isEmpty }
    private var bobotQuestions: [BobotJob] { bobot.jobs.reversed().filter { $0.pendingQuestion != nil } }
    private var bobotActive: [BobotJob] { bobot.jobs.reversed().filter { !$0.terminal && $0.pendingQuestion == nil } }
    private var bobotDone: [BobotJob] { bobot.jobs.reversed().filter(\.terminal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let job = bobot.jobs.first(where: { $0.id == selectedBobotID }) {
                detailBar(title: "Inbox", current: "bobot:\(job.id)", openTitle: nil, open: nil)
                BobotJobDetail(job: job, bobot: bobot).padding(.horizontal, 8)
            } else if let session = selected {
                detailBar(title: browser.collection.title, current: session.id, openTitle: session.openTitle, open: { open(session) })
                detail(session).padding(.horizontal, 8)
            } else {
                toolbar.padding(.horizontal, 8).padding(.bottom, 6)
                if browser.collection == .archived || browser.collection == .history { searchField.padding(.horizontal, 8).padding(.bottom, 4) }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        switch browser.collection {
                        case .saved: savedLinks
                        case .recent: inbox
                        case .archived, .history: archive
                        }
                    }.padding(.bottom, 12)
                }.background(OverlayScrollStyle())
                .focusable().focusEffectDisabled().focused($listFocused)
                .onKeyPress(.downArrow) { moveKeyboard(1, proxy: proxy) }
                .onKeyPress(.upArrow) { moveKeyboard(-1, proxy: proxy) }
                .onKeyPress(.return) { guard let id = keyboardRow else { return .ignored }; openFromList(id); return .handled }
                .onKeyPress(characters: CharacterSet(charactersIn: "eE")) { _ in
                    guard let id = keyboardRow, let session = sessions.first(where: { $0.id == id }), !browser.isRead(session) else { return .ignored }
                    browser.read(session); return .handled
                }
                .onAppear { listFocused = true }
                }
                if changedLink && store.canUndo {
                    BistButton("Undo removed link") { if store.undo() { changedLink = false } }
                        .buttonStyle(.plain).foregroundColor(accent).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
                }
            }
            if let error = bobot.error ?? browser.archiveError ?? connection.scan.t3.error ?? connection.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(danger)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).foregroundColor(ink)
        .onChange(of: browser.collection) { selectedBobotID = nil; browser.selectedID = nil; keyboardID = nil; keyboardIndex = nil }
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                await connection.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    // MARK: List

    private var toolbar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach([SessionCollection.recent, .archived, .history, .saved], id: \.self) { collection in
                    let current = browser.collection == collection
                    BistButton(focusRadius: 6) { browser.collection = collection } label: {
                        Text(collection.title).font(.system(size: 12, weight: current ? .semibold : .regular))
                            .foregroundColor(current ? ink : muted)
                            .frame(maxWidth: .infinity).frame(height: 24)
                            .background {
                                if current {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ivory)
                                        .shadow(color: ink.opacity(0.12), radius: 1.5, y: 0.5)
                                }
                            }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : [])
                }
            }.padding(2).background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if browser.collection == .saved {
                iconButton("plus", label: "Add saved link", action: addLink)
            } else {
                iconButton("arrow.clockwise", label: "Refresh sessions") { Task { await connection.refresh(forceHistory: true) } }
                    .disabled(connection.refreshing)
            }
        }.frame(height: 30)
    }

    @ViewBuilder private var inbox: some View {
        let needsCount = questions.count + bobotQuestions.count
        let runningCount = running.count + bobotActive.count
        if needsCount > 0 {
            heading("Needs you", count: needsCount, tint: accent)
            ForEach(bobotQuestions) { bobotRow($0, kind: .needsYou) }
            ForEach(questions) { row($0, kind: .needsYou) }
        }
        if runningCount > 0 {
            heading("Running", count: runningCount)
            ForEach(running) { row($0, kind: .running) }
            ForEach(bobotActive) { bobotRow($0, kind: .running) }
        }
        if !notices.isEmpty {
            heading("Updates", count: notices.count, action: notices.contains { !browser.isRead($0) } ? ("Mark all read", { _ = browser.read(notices.filter { !browser.isRead($0) }) }) : nil)
            ForEach(notices) { row($0, kind: browser.isRead($0) ? .read : .unread) }
        }
        if needsCount + runningCount + notices.count == 0 {
            emptyState(initialLoad ? "Finding sessions…" : "You’re all caught up",
                       detail: initialLoad ? nil : "Questions, running agents and new replies show up here.",
                       symbol: initialLoad ? nil : "checkmark.circle")
        }
        if !bobotDone.isEmpty {
            heading("Bobot", count: bobotDone.count)
            ForEach(bobotDone) { bobotRow($0, kind: .read) }
        }
        bobotFooter
    }

    @ViewBuilder private var archive: some View {
        let values = browser.collection == .history ? historyRows : updates
        if values.isEmpty {
            emptyState(initialLoad ? "Finding sessions…" : browser.isSearching ? "No matches" : browser.collection == .history ? "No local sessions" : "Nothing archived yet",
                       detail: browser.collection == .history ? "Codex and Claude sessions on this Mac appear here." : "Updates you open move here.",
                       symbol: initialLoad ? nil : browser.collection == .history ? "clock" : "archivebox")
        } else {
            Color.clear.frame(height: 4)
            ForEach(values) { row($0, kind: connection.busyIDs.contains($0.id) ? .running : .read) }
        }
    }
    private var historyRows: [LocalAgentSession] { SessionTriage.search(sessions, browser: browser).sorted { $0.modifiedAt > $1.modifiedAt } }

    private func heading(_ title: String, count: Int, tint: Color? = nil, action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(tint ?? ink)
                Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundColor(muted)
            }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
            Spacer()
            if let action {
                BistButton(action.0, action: action.1).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(accent)
            }
        }.padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    /// Display order of the current list, so arrows and Next match what you see.
    private var visibleOrder: [String] {
        switch browser.collection {
        case .recent:
            let bobotID: (BobotJob) -> String = { "bobot:\($0.id)" }
            var order: [String] = bobotQuestions.map(bobotID)
            order += questions.map(\.id)
            order += running.map(\.id)
            order += bobotActive.map(bobotID)
            order += notices.map(\.id)
            order += bobotDone.map(bobotID)
            return order
        case .archived: return updates.map(\.id)
        case .history: return historyRows.map(\.id)
        case .saved: return []
        }
    }
    /// The keyboard row only while it is still visible. A row that left the list hands its place to the next one.
    private var keyboardRow: String? { keyboardID.flatMap { visibleOrder.contains($0) ? $0 : nil } }
    private func moveKeyboard(_ step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let order = visibleOrder
        var id = SessionTriage.neighbor(of: keyboardRow, in: order, step: step)
        if keyboardRow == nil, let index = keyboardIndex, !order.isEmpty {
            id = order[min(max(step > 0 ? index : index - 1, 0), order.count - 1)]
        }
        guard let id else { return .ignored }
        select(id, in: order)
        proxy.scrollTo(id)
        return .handled
    }
    private func select(_ id: String, in order: [String]) {
        keyboardID = id
        keyboardIndex = order.firstIndex(of: id)
    }
    private func openFromList(_ id: String) {
        triageOrder = visibleOrder
        select(id, in: triageOrder)
        open(id: id)
    }
    private func open(id: String) {
        hoveredID = nil
        showFullResponse = false
        if id.hasPrefix("bobot:") { browser.selectedID = nil; selectedBobotID = String(id.dropFirst(6)); return }
        selectedBobotID = nil
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        browser.selectedID = id
        if !connection.busyIDs.contains(id) { browser.read(session) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(muted)
            TextField(browser.collection == .history ? "Search history" : "Search archive", text: $browser.query)
                .textFieldStyle(.plain).font(.system(size: 12)).bistTextEntry().accessibilityLabel("Search sessions")
            if browser.isSearching {
                BistButton(focusRadius: 6) { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(faint)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, 8).frame(height: 26)
            .background(fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(hairline, lineWidth: 1))
    }

    private func emptyState(_ title: String, detail: String?, symbol: String?) -> some View {
        VStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundColor(faint).padding(.bottom, 2) }
            else { ProgressView().controlSize(.small).padding(.bottom, 2) }
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12)).foregroundColor(muted).multilineTextAlignment(.center) }
        }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 36)
    }

    private func row(_ session: LocalAgentSession, kind: SessionRowKind) -> some View {
        let hovered = hoveredID == session.id || (hoveredID == nil && keyboardRow == session.id && listFocused)
        return BistButton(focusRadius: 7) { openFromList(session.id) } label: {
            SessionRow(kind: kind, title: SessionText.plain(session.title), meta: session.meta, excerpt: excerpt(session, kind: kind),
                       date: session.modifiedAt, hovered: hovered, showsActions: hovered && kind != .running)
        }.buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                if hovered && kind != .running { rowActions(session, kind: kind).padding(.top, 6).padding(.trailing, 6) }
            }
            .onHover { inside in
                hoveredID = inside ? session.id : hoveredID == session.id ? nil : hoveredID
                if inside { select(session.id, in: visibleOrder) }
            }
            .background(SessionHoverPreview(session: session, enabled: active && selected == nil, reduced: reduced || systemReduced))
            .contextMenu { rowMenu(session, kind: kind) }
            .id(session.id)
            .accessibilityLabel("\(kind.accessibilityPrefix)\(session.title), \(session.meta). \(excerpt(session, kind: kind))")
            .accessibilityHint(kind == .running ? "Opens the running session" : kind == .unread || kind == .needsYou ? "Opens and archives this update" : "Opens this session")
    }

    private func excerpt(_ session: LocalAgentSession, kind: SessionRowKind) -> String {
        if kind == .needsYou, let question = session.question ?? SessionDigest.question(session.preview) { return SessionText.plain(question) }
        let text = SessionText.plain(session.activity)
        return text.isEmpty ? "No messages yet" : text
    }

    private func rowActions(_ session: LocalAgentSession, kind: SessionRowKind) -> some View {
        HStack(spacing: 2) {
            if kind == .unread {
                iconButton("checkmark", label: "Mark as read") { browser.read(session) }.help("Mark as read")
            }
            iconButton(session.threadID == nil ? "terminal" : "arrow.up.forward.app", label: session.openTitle) { open(session) }
                .help(session.openTitle)
        }.padding(2).background(ivory.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func rowMenu(_ session: LocalAgentSession, kind: SessionRowKind) -> some View {
        Button("Open") { openFromList(session.id) }
        Button(session.openTitle) { open(session) }
        if kind == .unread { Button("Mark as Read") { browser.read(session) } }
        Divider()
        Button("Copy Workspace Path") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.directory, forType: .string)
        }
    }

    private func bobotRow(_ job: BobotJob, kind: SessionRowKind) -> some View {
        let id = "bobot:\(job.id)"
        let excerpt = job.pendingQuestion?.text ?? (job.state == "completed" ? (job.result ?? job.status) : job.status)
        return BistButton(focusRadius: 7) { openFromList(id) } label: {
            SessionRow(kind: kind, title: job.title, meta: "Bobot · \(job.status)", excerpt: SessionText.plain(excerpt),
                       date: Date(timeIntervalSince1970: job.updatedAt),
                       hovered: hoveredID == id || (hoveredID == nil && keyboardRow == id && listFocused), showsActions: false)
        }.buttonStyle(.plain).id(id)
            .onHover { inside in
                hoveredID = inside ? id : hoveredID == id ? nil : hoveredID
                if inside { select(id, in: visibleOrder) }
            }
            .accessibilityLabel("\(kind.accessibilityPrefix)\(job.title), Bobot, \(job.status)")
    }

    @ViewBuilder private var bobotFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 10)
            BistButton(focusRadius: 6) { showBobotSetup.toggle() } label: {
                HStack(spacing: 6) {
                    Circle().fill(bobot.connected ? Color.green : faint).frame(width: 6, height: 6)
                    Text(bobot.connected ? "Bobot connected" : "Connect Bobot").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(faint)
                        .rotationEffect(.degrees(showBobotSetup ? 90 : 0))
                }.foregroundColor(muted).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(bobot.connected ? "Bobot connected, setup details" : "Connect Bobot")
            if showBobotSetup { BobotSetup(bobot: bobot) }
        }.padding(.horizontal, 8)
    }

    // MARK: Detail

    private func detailBar(title: String, current: String, openTitle: String?, open: (() -> Void)?) -> some View {
        let order = triageOrder.isEmpty ? visibleOrder : triageOrder
        let previous = SessionTriage.neighbor(of: current, in: order, step: -1).flatMap { order.contains(current) ? $0 : nil }
        let next = SessionTriage.neighbor(of: current, in: order, step: 1).flatMap { order.contains(current) ? $0 : nil }
        return HStack(spacing: 6) {
            BistButton(focusRadius: 6) { browser.selectedID = nil; selectedBobotID = nil; listFocused = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(title).font(.system(size: 12, weight: .medium))
                }.padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(accent).accessibilityLabel("Back to \(title)")
            Spacer()
            if order.count > 1 {
                HStack(spacing: 0) {
                    iconButton("chevron.up", label: "Previous session") { if let previous { self.open(id: previous) } }
                        .disabled(previous == nil).opacity(previous == nil ? 0.35 : 1).keyboardShortcut(.upArrow, modifiers: [.command, .option]).help("Previous · ⌥⌘↑")
                    iconButton("chevron.down", label: "Next session") { if let next { self.open(id: next) } }
                        .disabled(next == nil).opacity(next == nil ? 0.35 : 1).keyboardShortcut(.downArrow, modifiers: [.command, .option]).help("Next · ⌥⌘↓")
                }
            }
            if let openTitle, let open {
                BistButton(focusRadius: 6, action: open) {
                    Label(openTitle, systemImage: "arrow.up.forward.app").font(.system(size: 12))
                        .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel(openTitle)
            }
        }.frame(height: 30).padding(.horizontal, 2).padding(.bottom, 4)
    }

    private func detail(_ session: LocalAgentSession) -> some View {
        let busy = connection.busyIDs.contains(session.id)
        let summary = SessionDigest.summary(session.preview)
        let question = session.question ?? SessionDigest.question(session.preview)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.title).font(.system(size: 15, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    statusLabel(session, busy: busy)
                    Text("·").foregroundColor(faint)
                    Text(session.meta).foregroundColor(muted).lineLimit(1).truncationMode(.middle)
                        .help((session.directory as NSString).abbreviatingWithTildeInPath)
                }.font(.system(size: 12))
            }.padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let question, !busy {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Your next step", systemImage: "questionmark.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundColor(accent)
                            SessionMarkdown(text: question, size: 13, weight: .medium)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(busy ? "Latest activity" : "What it did").font(.system(size: 11, weight: .semibold)).foregroundColor(muted)
                        if session.preview.isEmpty {
                            Text(SessionText.plain(session.activity)).font(.system(size: 13)).foregroundColor(muted)
                        } else {
                            SessionMarkdown(text: showFullResponse || summary.isEmpty ? session.preview : summary, size: 13)
                        }
                        if session.preview.count > summary.count && !summary.isEmpty {
                            BistButton(showFullResponse ? "Show less" : "Show full response") { showFullResponse.toggle() }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(accent).padding(.top, 2)
                        }
                    }
                }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }.background(OverlayScrollStyle())
            composer(session, busy: busy)
        }
        .onChange(of: active, initial: true) { _, visible in
            browser.acknowledge(session, visible: visible, running: busy)
        }
        .onChange(of: session.modifiedAt) { _, _ in
            browser.acknowledge(session, visible: active, running: connection.busyIDs.contains(session.id))
        }
    }

    @ViewBuilder private func statusLabel(_ session: LocalAgentSession, busy: Bool) -> some View {
        if busy {
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Working").foregroundColor(ink) }
        } else if session.awaitingReply {
            Text("Needs your reply").foregroundColor(accent)
        } else {
            Text(SessionText.age(session.modifiedAt) == "now" ? "Updated just now" : "Updated \(SessionText.age(session.modifiedAt)) ago").foregroundColor(muted)
        }
    }

    @ViewBuilder private func composer(_ session: LocalAgentSession, busy: Bool) -> some View {
        let draft = browser.drafts[session.id] ?? ""
        let tooLong = draft.utf8.count > 16_384
        VStack(alignment: .leading, spacing: 6) {
            if !busy { suggestions(session) }
            if let reply = connection.replies[session.id], reply.failed, session.threadID != nil {
                Text(reply.text).font(.system(size: 11)).foregroundColor(danger).textSelection(.enabled).lineLimit(4)
            }
            if let reply = connection.replies[session.id], reply.delivered {
                Label("Sent. The thread updates here.", systemImage: "checkmark").font(.system(size: 11)).foregroundColor(muted)
            }
            if session.threadID == nil && connection.scan.t3.connected {
                Text("Local history is read-only while T3 is connected. Reply from its thread in Inbox.")
                    .font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(busy ? "Wait for this turn to finish…" : session.requiresT3Response ? "Write a reply to copy to T3…" : "Reply or give a next step…",
                              text: Binding(get: { browser.drafts[session.id] ?? "" }, set: { browser.drafts[session.id] = $0 }), axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 13)).bistTextEntry()
                        .padding(.vertical, 3).accessibilityLabel("Message to \(session.title)")
                    let disabled = browser.sending.contains(session.id) || busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tooLong
                    BistButton(focusRadius: 12) {
                        if session.requiresT3Response { connection.copyReplyAndOpen(draft, session: session) } else { send(session) }
                    } label: {
                        Image(systemName: session.requiresT3Response ? "arrow.up.forward.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 20)).foregroundColor(disabled ? faint : accent).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).disabled(disabled)
                        .help(session.requiresT3Response ? "Copy reply and open T3" : "Send")
                        .accessibilityLabel(session.requiresT3Response ? "Copy reply and open T3" : "Send message to \(session.title)")
                }.padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                    .background(fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hairline, lineWidth: 1))
                Text(session.requiresT3Response ? "Copies your text and opens T3, where you answer." : session.threadID != nil ? "Sends to this T3 thread with its existing permissions." : "Continues this session with its CLI login and permissions.")
                    .font(.system(size: 10)).foregroundColor(muted).padding(.horizontal, 2)
            }
            if tooLong { Text("Message is too long (16 KB maximum).").font(.system(size: 11)).foregroundColor(danger) }
        }.padding(.top, 10)
    }

    @ViewBuilder private func suggestions(_ session: LocalAgentSession) -> some View {
        let choices = session.requiresT3Response ? session.suggestedReplies
            : SessionDigest.question(session.preview) != nil ? SessionDigest.suggestions(session.preview) + ["What do you recommend, and why?"] : []
        if session.requiresT3Response {
            Text("This question needs T3’s answer controls.").font(.system(size: 11)).foregroundColor(muted)
        }
        if !choices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    BistButton(focusRadius: 7) { browser.drafts[session.id] = choice } label: {
                        Text(choice).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundColor(accent)
                        .accessibilityHint(session.requiresT3Response ? "Fills a draft to copy into T3 without sending" : "Fills the reply field without sending")
                }
            }
        }
        if session.requiresT3Response {
            BistButton("Answer in T3") { connection.openThread(session, answering: true) }
                .buttonStyle(TactileStyle(prominent: true, compact: true)).font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: Actions

    private func open(_ session: LocalAgentSession) {
        if session.threadID != nil { connection.openThread(session) } else { connection.resume(session) }
    }
    private func send(_ session: LocalAgentSession) {
        guard browser.sending.insert(session.id).inserted else { return }
        let text = browser.drafts[session.id] ?? ""
        Task {
            defer { browser.sending.remove(session.id) }
            if await connection.send(text, to: session), browser.drafts[session.id] == text { browser.drafts[session.id] = "" }
        }
    }
    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        BistButton(focusRadius: 6, action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel(label)
    }

    // MARK: Saved links

    @ViewBuilder private var savedLinks: some View {
        if store.sessions.isEmpty {
            emptyState("No saved links", detail: "Keep a link to any agent session close at hand.", symbol: "link")
            BistButton("Add saved link", action: addLink).buttonStyle(TactileStyle(compact: true)).font(.system(size: 12)).frame(maxWidth: .infinity)
        } else { Color.clear.frame(height: 4) }
        ForEach(store.sessions) { session in
            let id = "link:\(session.id)"
            HStack(spacing: 8) {
                BistButton(focusRadius: 7) {
                    if let string = session.url, let url = safeURL(string) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link").font(.system(size: 11)).foregroundColor(muted).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title).font(.system(size: 13)).lineLimit(1)
                            Text(session.url.flatMap { URL(string: $0)?.host } ?? providerName(session.provider)).font(.system(size: 11)).foregroundColor(muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open saved link: \(session.title)")
                Menu {
                    Button("Remove saved link") { if store.removeSession(id: session.id) { changedLink = true } else { connection.error = store.storeError } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().bistPointingHand()
                    .opacity(hoveredID == id ? 1 : 0.4).accessibilityLabel("Options for \(session.title)")
            }.padding(.horizontal, 8).padding(.vertical, 6)
                .background(hoveredID == id ? ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { inside in hoveredID = inside ? id : hoveredID == id ? nil : hoveredID }
        }
    }
}

enum SessionRowKind {
    case needsYou, running, unread, read
    var accessibilityPrefix: String {
        switch self { case .needsYou: return "Needs you: "; case .running: return "Running: "; case .unread: return "Unread: "; case .read: return "" }
    }
}

/// Status, title and age on top, with the project and a plain excerpt below.
struct SessionRow: View {
    let kind: SessionRowKind
    let title: String
    let meta: String
    let excerpt: String
    let date: Date
    let hovered: Bool
    let showsActions: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            mark.frame(width: 14, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: kind == .read ? .regular : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SessionText.age(date))
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(muted)
                        .opacity(showsActions ? 0 : 1)
                }
                Text(meta).font(.system(size: 11)).foregroundColor(muted).lineLimit(1).truncationMode(.middle)
                Text(excerpt).font(.system(size: 12)).foregroundColor(kind == .needsYou ? ink : muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? ink.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .needsYou: Image(systemName: "questionmark.circle.fill").font(.system(size: 13)).foregroundColor(accent)
        case .running: ProgressView().controlSize(.mini).scaleEffect(0.85)
        case .unread: Circle().fill(ink).frame(width: 7, height: 7)
        case .read: Color.clear
        }
    }
}

/// Renders agent markdown as readable blocks (paragraphs, lists, headings and code).
struct SessionMarkdown: View {
    let text: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(SessionText.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let value):
                    inline(value).font(.system(size: size, weight: weight)).lineSpacing(2)
                case .heading(let value):
                    inline(value).font(.system(size: size, weight: .semibold)).padding(.top, 2)
                case .item(let marker, let value, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(.system(size: size)).monospacedDigit().foregroundColor(muted).frame(minWidth: 12, alignment: .trailing)
                        inline(value).font(.system(size: size, weight: weight)).lineSpacing(2)
                    }.padding(.leading, CGFloat(depth) * 14)
                case .code(let value):
                    Text(value).font(.system(size: size - 1, design: .monospaced)).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

enum SessionBlock: Equatable {
    case paragraph(String), heading(String), item(String, String, Int), code(String)
}

/// Readable text from agent output. Never adds content, only removes markup.
enum SessionText {
    static func plain(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "```", with: " ")
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        // Odd segments sit inside backticks and keep their exact characters.
        let segments = value.components(separatedBy: "`").enumerated().map { index, segment -> String in
            guard index.isMultiple(of: 2) else { return segment }
            var prose = segment.replacingOccurrences(of: "**", with: "")
            prose = prose.replacingOccurrences(of: #"(?<=\s|^)__(?=\S)|(?<=\S)__(?=\s|$|[.,;:!?])"#, with: "", options: .regularExpression)
            return prose.replacingOccurrences(of: #"(?<=\s|^)\*(?=\S)|(?<=\S)\*(?=\s|$|[.,;:!?])"#, with: "", options: .regularExpression)
        }
        return segments.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func blocks(_ text: String) -> [SessionBlock] {
        var blocks: [SessionBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let width = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let indent = width == 0 ? 0 : max(1, (width + 2) / 4)
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(line[match.upperBound...]))); continue
            }
            if let match = line.range(of: #"^([-*•+])\s+"#, options: .regularExpression) {
                flush(); blocks.append(.item("•", String(line[match.upperBound...]), min(indent, 3))); continue
            }
            if let match = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush()
                let marker = line[match].trimmingCharacters(in: .whitespaces)
                blocks.append(.item(marker, String(line[match.upperBound...]), min(indent, 3))); continue
            }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// Compact age for a fixed right-hand column (now, 4m, 3h, 2d, Oct 3).
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension LocalAgentSession {
    /// Project and agent in one line, so the row says where the work lives.
    var meta: String {
        let project = directory == "/" ? "Root folder" : URL(fileURLWithPath: directory).lastPathComponent
        var parts = [project, provider.shortName]
        if childCount > 0 { parts.append("\(childCount) helper\(childCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
    var openTitle: String { threadID == nil ? "Open in Terminal" : "Open in T3" }
}

extension SessionCollection {
    var title: String {
        switch self { case .recent: return "Inbox"; case .archived: return "Archive"; case .history: return "History"; case .saved: return "Links" }
    }
}
