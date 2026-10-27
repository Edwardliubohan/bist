import AppKit
import SwiftUI

struct SessionsPane: View {
    @ObservedObject var store: AppStore
    @ObservedObject var connection: LocalSessionConnection
    @ObservedObject var browser: SessionBrowserState
    let active: Bool
    let addLink: () -> Void
    @State private var changedLink = false

    private var sessions: [LocalAgentSession] { connection.inboxSessions }
    private var selected: LocalAgentSession? { sessions.first { $0.id == browser.selectedID } }
    private var running: [LocalAgentSession] { sessions.filter { connection.running.contains($0.id) } }
    private var updates: [LocalAgentSession] { browser.inbox(sessions, running: connection.running, archived: browser.collection == .archived) }
    private var initialLoad: Bool { connection.scan.messages.isEmpty && sessions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.bottom, 8)
            if let session = selected { detail(session) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if browser.collection == .saved { savedLinks }
                        else {
                            if browser.collection == .recent {
                                heading("Running", count: running.count)
                                ForEach(running) { row($0, working: true) }
                                if running.isEmpty { hint("No turns running in bist") }
                            }
                            heading(browser.collection == .archived ? "Archive" : "Notifications", count: updates.count).padding(.top, 12)
                            ForEach(updates) { row($0, working: false) }
                            if updates.isEmpty {
                                hint(initialLoad ? "Finding local sessions…" : browser.collection == .archived ? "Read updates appear here." : "You’re all caught up.")
                            }
                        }
                    }.padding(.bottom, 12)
                }.background(OverlayScrollStyle())
                if changedLink && store.canUndo {
                    BistButton("Undo removed link") { if store.undo() { changedLink = false } }.buttonStyle(.plain).foregroundColor(accent).font(.system(size: 11))
                }
            }
            if let error = browser.archiveError ?? connection.error {
                Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14).foregroundColor(ink)
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                await connection.refresh()
                do { try await Task.sleep(for: .seconds(20)) } catch { break }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if selected != nil {
                BistButton { browser.selectedID = nil } label: {
                    Label("Inbox", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)).frame(height: 28)
                }.buttonStyle(.plain).foregroundColor(accent)
            } else {
                Text(browser.collection == .recent ? "Inbox" : browser.collection == .archived ? "Archive" : "Saved links").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            BistButton { Task { await connection.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundColor(muted).disabled(connection.refreshing).accessibilityLabel("Refresh sessions")
            Menu {
                Button("Inbox") { browser.collection = .recent; browser.selectedID = nil }
                Button("Archive") { browser.collection = .archived; browser.selectedID = nil }
                Button("Saved links") { browser.collection = .saved; browser.selectedID = nil }
                Divider()
                Button("Add saved link", action: addLink)
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().bistPointingHand().accessibilityLabel("Session collections and links")
        }
    }
    private func heading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold))
            Spacer()
            Text("\(count)").font(.system(size: 10)).monospacedDigit().foregroundColor(muted)
        }.frame(height: 24)
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundColor(muted).padding(.vertical, 7)
    }
    private func row(_ session: LocalAgentSession, working: Bool) -> some View {
        BistButton {
            browser.selectedID = session.id
            if !working { browser.read(session) }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(working ? accent : browser.isRead(session) ? .clear : muted).frame(width: 5, height: 5)
                Text(session.title).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 115, alignment: .leading)
                Text(session.activity).font(.system(size: 11)).foregroundColor(muted).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: session.provider.symbol).font(.system(size: 9)).foregroundColor(muted).frame(width: 12)
            }.frame(height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(session.title), \(session.provider.shortName), \(session.activity)")
            .accessibilityHint(working ? "Opens running session" : "Opens and archives this update")
    }
    private func detail(_ session: LocalAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack {
                Text(session.provider.shortName).font(.system(size: 10)).foregroundColor(muted)
                Spacer()
                BistButton("Open in Terminal") { connection.resume(session) }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(accent)
            }
            Text((session.directory as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundColor(muted).lineLimit(1).truncationMode(.middle)
            Divider()
            ScrollView {
                Text(session.preview.isEmpty ? session.activity : session.preview)
                    .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.background(OverlayScrollStyle())
            if connection.running.contains(session.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working on your message…").font(.system(size: 11)).foregroundColor(muted) }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Tell this agent what to do…", text: Binding(get: { browser.drafts[session.id] ?? "" }, set: { browser.drafts[session.id] = $0 }), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).font(.system(size: 12)).bistTextEntry().accessibilityLabel("Message to \(session.title)")
                BistButton { send(session) } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundColor(accent).accessibilityLabel("Send message to \(session.title)")
                    .disabled(browser.sending.contains(session.id) || connection.running.contains(session.id) || (browser.drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (browser.drafts[session.id] ?? "").utf8.count > 16_384)
            }.padding(.vertical, 6)
            Text("Continues this session using its CLI login and permissions.").font(.system(size: 9)).foregroundColor(muted)
            if (browser.drafts[session.id] ?? "").utf8.count > 16_384 { Text("Message is too long (16 KB maximum).").font(.system(size: 10)).foregroundColor(.red) }
        }
        .onChange(of: active, initial: true) { _, visible in
            browser.acknowledge(session, visible: visible, running: connection.running.contains(session.id))
        }
        .onChange(of: session.modifiedAt) { _, _ in
            browser.acknowledge(session, visible: active, running: connection.running.contains(session.id))
        }
    }
    private func send(_ session: LocalAgentSession) {
        guard browser.sending.insert(session.id).inserted else { return }
        let text = browser.drafts[session.id] ?? ""
        Task {
            defer { browser.sending.remove(session.id) }
            if await connection.send(text, to: session), browser.drafts[session.id] == text { browser.drafts[session.id] = "" }
        }
    }
    @ViewBuilder private var savedLinks: some View {
        if store.sessions.isEmpty {
            hint("Save a session link to keep it close.")
            BistButton("Add saved link", action: addLink).buttonStyle(.plain).font(.system(size: 11)).foregroundColor(accent).frame(height: 28)
        }
        ForEach(store.sessions) { session in
            HStack(spacing: 8) {
                BistButton {
                    if let string = session.url, let url = safeURL(string) { NSWorkspace.shared.open(url) }
                } label: { Text(session.title).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).foregroundColor(accent).accessibilityLabel("Open saved link: \(session.title)")
                Menu {
                    Button("Remove saved link") { if store.removeSession(id: session.id) { changedLink = true } else { connection.error = store.storeError } }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().bistPointingHand().accessibilityLabel("Options for \(session.title)")
            }.frame(height: 28)
        }
    }
}
