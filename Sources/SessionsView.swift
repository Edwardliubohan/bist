import AppKit
import SwiftUI

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
    @Environment(\.bistReduced) private var reduced
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    private var sessions: [LocalAgentSession] { browser.collection == .history ? connection.scan.sessions : connection.inboxSessions }
    private var selected: LocalAgentSession? { sessions.first { $0.id == browser.selectedID } }
    private var running: [LocalAgentSession] { sessions.filter { connection.busyIDs.contains($0.id) } }
    private var updates: [LocalAgentSession] { browser.inbox(sessions, running: connection.busyIDs, archived: browser.collection == .archived) }
    private var questions: [LocalAgentSession] { updates.filter { $0.awaitingReply } }
    private var notices: [LocalAgentSession] { updates.filter { session in !questions.contains { $0.id == session.id } } }
    private var initialLoad: Bool { connection.scan.messages.isEmpty && sessions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.bottom, 8)
            if let job = bobot.jobs.first(where: { $0.id == selectedBobotID }) { BobotJobDetail(job: job, bobot: bobot) }
            else if let session = selected { detail(session) }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if browser.collection == .saved { savedLinks }
                        else {
                            if browser.collection == .recent {
                                BobotSetup(bobot: bobot)
                                if !bobot.jobs.isEmpty {
                                    heading("Bobot", count: bobot.jobs.count)
                                    ForEach(bobot.jobs.reversed()) { job in
                                        BistButton { selectedBobotID = job.id } label: {
                                            HStack(spacing: 7) {
                                                Image(systemName: job.pendingQuestion != nil ? "questionmark.circle.fill" : job.state == "completed" ? "checkmark.circle" : "circle").foregroundColor(accent)
                                                Text(job.title).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                                                Text(job.status).foregroundColor(muted).lineLimit(1)
                                                Spacer(minLength: 0)
                                            }.font(.system(size: 11)).frame(height: 28).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityLabel("\(job.title), Bobot, \(job.status)")
                                    }
                                }
                                heading("Running", count: running.count)
                                ForEach(running) { row($0, working: true) }
                                if running.isEmpty { hint("No sessions running") }
                            }
                            if !questions.isEmpty && browser.collection == .recent {
                                heading("Needs you", count: questions.count).padding(.top, 12)
                                ForEach(questions) { row($0, working: false) }
                            }
                            heading(browser.collection == .archived ? "Archive" : browser.collection == .history ? "Local history" : "Updates", count: browser.collection == .recent ? notices.count : updates.count).padding(.top, 12)
                            ForEach(browser.collection == .recent ? notices : updates) { row($0, working: false) }
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
            if let error = bobot.error ?? browser.archiveError ?? connection.scan.t3.error ?? connection.error {
                Text(error).font(.system(size: 11)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 14).foregroundColor(ink)
        .onChange(of: browser.collection) { selectedBobotID = nil }
        .task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                await connection.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if selected != nil || selectedBobotID != nil {
                BistButton { browser.selectedID = nil; selectedBobotID = nil } label: {
                    Label("Inbox", systemImage: "chevron.left").font(.system(size: 11, weight: .medium)).frame(height: 28)
                }.buttonStyle(.plain).foregroundColor(accent)
            } else {
                Text(browser.collection == .recent ? "Inbox" : browser.collection == .archived ? "Archive" : browser.collection == .history ? "Local history" : "Saved links").font(.system(size: 13, weight: .semibold))
            }
            Spacer()
            BistButton { Task { await connection.refresh(forceHistory: true) } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundColor(muted).disabled(connection.refreshing).accessibilityLabel("Refresh sessions")
            Menu {
                Button("Inbox") { browser.collection = .recent; browser.selectedID = nil }
                Button("Archive") { browser.collection = .archived; browser.selectedID = nil }
                Button("Local history") { browser.collection = .history; browser.selectedID = nil }
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
            hoveredID = nil
            showFullResponse = false
            browser.selectedID = session.id
            if !working { browser.read(session) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: working ? "circle.fill" : session.awaitingReply ? "questionmark.circle" : "circle.fill")
                    .font(.system(size: working ? 5 : 8)).foregroundColor(working ? accent : muted.opacity(0.65)).frame(width: 10)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(session.modifiedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).font(.system(size: 9)).foregroundColor(muted).lineLimit(1)
                    }
                    Text(session.activity.isEmpty ? "Open to see this session" : session.activity).font(.system(size: 11)).foregroundColor(muted).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(muted.opacity(0.6))
            }.padding(.horizontal, 7).frame(height: 49).contentShape(Rectangle())
                .background(hoveredID == session.id ? accent.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 7))

        }.buttonStyle(.plain)
            .onHover { inside in hoveredID = inside ? session.id : hoveredID == session.id ? nil : hoveredID }
            .background(SessionHoverPreview(session: session, enabled: active && selected == nil, reduced: reduced || systemReduced))
            .accessibilityLabel("\(session.title), \(session.provider.shortName), \(session.activity)")
            .accessibilityHint(working ? "Opens running session" : "Opens and archives this update")
    }
    private func detail(_ session: LocalAgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack {
                Text(session.provider.shortName).font(.system(size: 10)).foregroundColor(muted)
                Spacer()
                BistButton(session.threadID == nil ? "Open in Terminal" : "Open in T3") { if session.threadID != nil { connection.openThread(session) } else { connection.resume(session) } }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(accent)
            }
            Text((session.directory as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundColor(muted).lineLimit(1).truncationMode(.middle)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(connection.busyIDs.contains(session.id) ? "Latest activity" : "What it did").font(.system(size: 10, weight: .semibold)).foregroundColor(muted)
                    Text(readable(session.preview.isEmpty ? session.activity : SessionDigest.summary(session.preview).isEmpty ? "Waiting for your direction." : SessionDigest.summary(session.preview)))
                        .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if session.preview.count > SessionDigest.summary(session.preview).count {
                        DisclosureGroup("Full response", isExpanded: $showFullResponse) {
                            Text(readable(session.preview)).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }.font(.system(size: 10)).foregroundColor(muted)
                    }
                    if let question = session.question ?? SessionDigest.question(session.preview) {
                        Text("Your next step").font(.system(size: 10, weight: .semibold)).foregroundColor(muted).padding(.top, 5)
                        Text(question).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                    }
                }

            }.background(OverlayScrollStyle())
            if connection.busyIDs.contains(session.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(session.threadID == nil ? "Working on your message…" : "Working in T3…").font(.system(size: 11)).foregroundColor(muted) }
            }
            if !connection.busyIDs.contains(session.id) {
                if session.requiresT3Response {
                    Text("This question or approval needs T3’s response controls.").font(.system(size: 11)).foregroundColor(muted)
                    ForEach(session.suggestedReplies, id: \.self) { suggestion in
                        BistButton(suggestion) { browser.drafts[session.id] = suggestion }
                            .buttonStyle(.plain).foregroundColor(accent).font(.system(size: 11)).frame(height: 26)
                            .accessibilityHint("Fills a draft to copy into T3 without sending")
                    }
                    BistButton("Answer in T3") { connection.openThread(session, answering: true) }.buttonStyle(.plain).foregroundColor(accent).font(.system(size: 12, weight: .medium)).frame(height: 28)
                } else if SessionDigest.question(session.preview) != nil {
                    Text("Choose a reply to edit, or write your own.").font(.system(size: 10)).foregroundColor(muted)
                    ForEach(SessionDigest.suggestions(session.preview), id: \.self) { suggestion in
                        BistButton { browser.drafts[session.id] = suggestion } label: {
                            Text(suggestion).font(.system(size: 11)).lineLimit(2).padding(.horizontal, 9).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).foregroundColor(accent).accessibilityHint("Fills the reply field without sending")
                    }
                    BistButton("Ask for a recommendation") { browser.drafts[session.id] = "What do you recommend, and why?" }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(accent).frame(height: 26)
                } else {
                    Text("Review the update, then send a follow-up or return to Inbox.").font(.system(size: 10)).foregroundColor(muted)
                }
            }
            if let reply = connection.replies[session.id], reply.failed, session.threadID != nil {
                Text(reply.text).font(.system(size: 11)).foregroundColor(.red).textSelection(.enabled).lineLimit(4)
            }
            if let reply = connection.replies[session.id], reply.delivered {
                Text("Sent to T3. The thread will update here.").font(.system(size: 10)).foregroundColor(muted)
            }
            Divider()
            if session.threadID == nil && connection.scan.t3.connected {
                Text("Local history is read-only while T3 is connected. Reply from its thread in Inbox.")
                    .font(.system(size: 11)).foregroundColor(muted)
            } else {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(session.requiresT3Response ? "Write a reply to copy to T3…" : "Reply or give a next step…", text: Binding(get: { browser.drafts[session.id] ?? "" }, set: { browser.drafts[session.id] = $0 }), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).font(.system(size: 12)).bistTextEntry().accessibilityLabel("Message to \(session.title)")
                BistButton { if session.requiresT3Response { connection.copyReplyAndOpen(browser.drafts[session.id] ?? "", session: session) } else { send(session) } } label: { Image(systemName: session.requiresT3Response ? "arrow.up.forward.circle.fill" : "arrow.up.circle.fill").font(.system(size: 22)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundColor(accent).accessibilityLabel(session.requiresT3Response ? "Copy reply and open T3" : "Send message to \(session.title)")
                    .disabled(browser.sending.contains(session.id) || connection.busyIDs.contains(session.id) || (browser.drafts[session.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (browser.drafts[session.id] ?? "").utf8.count > 16_384)
            }.padding(.vertical, 6)
            Text(session.requiresT3Response ? "Copies your text and opens T3 so you can answer there." : session.threadID != nil ? "Sends to this T3 thread. Uses its existing permissions." : "Continues this session using its CLI login and permissions.").font(.system(size: 9)).foregroundColor(muted)
            }
            if (browser.drafts[session.id] ?? "").utf8.count > 16_384 { Text("Message is too long (16 KB maximum).").font(.system(size: 10)).foregroundColor(.red) }
        }
        .onChange(of: active, initial: true) { _, visible in
            browser.acknowledge(session, visible: visible, running: connection.busyIDs.contains(session.id))
        }
        .onChange(of: session.modifiedAt) { _, _ in
            browser.acknowledge(session, visible: active, running: connection.busyIDs.contains(session.id))
        }
    }
    private func readable(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
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
