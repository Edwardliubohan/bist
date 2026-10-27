import AppKit
import SwiftUI

struct SessionsPane: View {
    @ObservedObject var store: AppStore
    @ObservedObject var connection: LocalSessionConnection
    @ObservedObject var browser: SessionBrowserState
    let active: Bool
    let addLink: () -> Void
    @State private var changedLink = false
    @State private var linkError: String?

    private var groups: [SessionWorkspace] { browser.workspaces(connection.scan.sessions) }
    private var links: [SessionItem] { browser.savedLinks(store.sessions) }
    private var matchingCount: Int { groups.reduce(0) { $0 + $1.sessions.count } }
    private var initialLoad: Bool { connection.scan.messages.isEmpty && connection.scan.sessions.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar.padding(.bottom, 12)
            search.padding(.bottom, 10)
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(.system(size: 10)).foregroundColor(muted).lineLimit(1)
                Spacer(minLength: 8)
                providerFilter
            }.padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if browser.collection == .recent { recentContent }
                    else { savedContent }
                }.padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .background(OverlayScrollStyle())
            Divider()
            footer.padding(.top, 10).padding(.bottom, 14)
        }
        .padding(.horizontal, 20)
        .foregroundColor(ink)
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
            Picker("Session collection", selection: $browser.collection) {
                Text("Recent").tag(SessionCollection.recent)
                Text("Saved links").tag(SessionCollection.saved)
            }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                .accessibilityLabel("Session collection")
            BistButton(action: addLink) {
                Label("Add link", systemImage: "plus").font(.system(size: 11, weight: .medium)).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(accent).accessibilityLabel("Add a saved session link").help("Add a saved link")
            BistButton { Task { await connection.refresh() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(muted).disabled(connection.refreshing)
                .accessibilityLabel(connection.refreshing ? "Refreshing local sessions" : "Refresh local sessions")
                .help("Refresh local sessions")
        }
    }
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(muted)
            ZStack(alignment: .leading) {
                if browser.query.isEmpty {
                    Text(browser.collection == .recent ? "Search workspace or session ID" : "Search saved links")
                        .font(.system(size: 11)).foregroundColor(muted).allowsHitTesting(false).accessibilityHidden(true)
                }
                TextField("", text: $browser.query)
                    .textFieldStyle(.plain).font(.system(size: 11)).bistTextEntry()
                    .accessibilityLabel(browser.collection == .recent ? "Search recent sessions" : "Search saved links")
            }
            if !browser.query.isEmpty {
                BistButton { browser.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).frame(width: 20, height: 24)
                }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("Clear session search")
            }
        }.padding(.horizontal, 9).frame(height: 30)
            .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }
    private var providerFilter: some View {
        Menu {
            Button { browser.provider = nil } label: {
                if browser.provider == nil { Label("All providers", systemImage: "checkmark") } else { Text("All providers") }
            }
            ForEach(browser.collection == .recent ? [.codex, .claudeCode] : SessionProvider.allCases, id: \.self) { provider in
                Button { browser.provider = provider } label: {
                    if browser.provider == provider { Label(provider.displayName, systemImage: "checkmark") } else { Text(provider.displayName) }
                }
            }
        } label: { Text(browser.provider?.shortName ?? "All providers").font(.system(size: 10)).foregroundColor(accent) }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().bistPointingHand()
        .accessibilityLabel("Filter by provider: \(browser.provider?.shortName ?? "All providers")")
    }
    private var summary: String {
        if browser.collection == .saved { return "\(links.count) saved link\(links.count == 1 ? "" : "s")" }
        if initialLoad { return "Finding local sessions…" }
        return "\(matchingCount) session\(matchingCount == 1 ? "" : "s") · \(groups.count) workspace\(groups.count == 1 ? "" : "s")"
    }

    @ViewBuilder private var recentContent: some View {
        if initialLoad {
            ForEach(0..<3) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.06)).frame(width: 145, height: 11)
                    RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.04)).frame(height: 9)
                }.padding(.vertical, 14).accessibilityHidden(true)
            }
        } else if groups.isEmpty {
            emptyState(title: browser.isSearching || browser.provider != nil ? "No matching sessions" : "No local sessions yet",
                       message: browser.isSearching || browser.provider != nil ? "Try another workspace, session ID, or provider." : "Start a session in Codex or Claude Code, then refresh here.")
        } else {
            ForEach(groups) { group in
                workspace(group)
                if group.id != groups.last?.id { Divider().padding(.vertical, 12) }
            }
        }
        // Folder availability and read errors belong with the local source list.
        ForEach([SessionProvider.codex, .claudeCode], id: \.self) { provider in
            if (browser.provider == nil || browser.provider == provider), let message = connection.scan.messages[provider], message != "Local sessions connected" {
                Text("\(provider.shortName): \(message)").font(.system(size: 10)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
        }
    }
    private func workspace(_ group: SessionWorkspace) -> some View {
        let expanded = browser.isSearching || browser.expandedWorkspaces.contains(group.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundColor(muted).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text((group.directory as NSString).abbreviatingWithTildeInPath).font(.system(size: 9)).foregroundColor(muted).lineLimit(1).truncationMode(.middle)
                        .help(group.directory)
                }
                Spacer(minLength: 4)
                Text("\(group.sessions.count)").font(.system(size: 10)).foregroundColor(muted).monospacedDigit().padding(.top, 1)
            }.accessibilityElement(children: .combine)
            if let latest = group.sessions.first { recentRow(latest, latest: group.sessions.count > 1) }
            if expanded {
                ForEach(Array(group.sessions.dropFirst())) { session in recentRow(session, latest: false) }
            }
            if group.sessions.count > 1 && !browser.isSearching {
                BistButton { browser.toggle(group.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                        Text(expanded ? "Hide older sessions" : "\(group.sessions.count - 1) older session\(group.sessions.count == 2 ? "" : "s")").font(.system(size: 10))
                    }.frame(minHeight: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundColor(muted)
                    .accessibilityLabel("\(expanded ? "Hide" : "Show") older sessions for \(group.title)")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
    }
    private func recentRow(_ session: LocalAgentSession, latest: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: session.provider.symbol).font(.system(size: 11)).foregroundColor(muted).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(session.provider.shortName).font(.system(size: 11, weight: .medium))
                    if latest { Text("Latest").font(.system(size: 9)).foregroundColor(muted) }
                }
                Text("\(session.modifiedAt.formatted(.relative(presentation: .named))) · \(session.shortID)")
                    .font(.system(size: 9)).foregroundColor(muted).lineLimit(1)
                    .accessibilityLabel("Saved \(session.modifiedAt.formatted(date: .abbreviated, time: .shortened)), session \(session.sessionID.uuidString)")
            }
            Spacer(minLength: 4)
            sessionAction("Resume") { connection.resume(session) }
                .accessibilityLabel("Resume \(session.provider.shortName) session \(session.shortID) in \(session.title)")
        }.padding(.leading, 20).padding(.vertical, 4)
    }
    @ViewBuilder private var savedContent: some View {
        if links.isEmpty {
            emptyState(title: browser.isSearching || browser.provider != nil ? "No matching links" : "Keep a session close",
                       message: browser.isSearching || browser.provider != nil ? "Try another title, link, or provider." : "Save a session URL to open it here later.")
            if !browser.isSearching && browser.provider == nil {
                sessionAction("Add a link", action: addLink).padding(.top, 10)
            }
        } else {
            ForEach(links) { session in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2).help(session.title)
                        Text(session.provider.displayName).font(.system(size: 10)).foregroundColor(muted)
                        if let string = session.url, let url = safeURL(string) {
                            Text(url.host ?? string).font(.system(size: 9)).foregroundColor(muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let string = session.url, let url = safeURL(string) {
                        sessionAction("Open") { NSWorkspace.shared.open(url) }.accessibilityLabel("Open saved link: \(session.title)")
                    }
                    Menu {
                        Button("Remove saved link") {
                            if store.removeSession(id: session.id) { changedLink = true; linkError = nil }
                            else { linkError = store.storeError }
                        }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().bistPointingHand()
                    .accessibilityLabel("Options for saved link: \(session.title)")
                }.padding(.vertical, 10)
                if session.id != links.last?.id { Divider() }
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = browser.collection == .recent ? connection.error : linkError {
                Text(error).font(.system(size: 10)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            if browser.collection == .saved && changedLink && store.canUndo {
                HStack {
                    Text("Link removed").font(.system(size: 10)).foregroundColor(muted)
                    Spacer()
                    BistButton("Undo") { if store.undo() { changedLink = false; linkError = nil } else { linkError = store.storeError } }
                        .buttonStyle(.plain).foregroundColor(accent).font(.system(size: 10, weight: .medium))
                }
            }
            Text(browser.collection == .recent ? "Resume opens Terminal. Times show saved activity." : "Saved links open in your browser.")
                .font(.system(size: 9)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(message).font(.system(size: 11)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            if browser.isSearching || browser.provider != nil {
                BistButton("Clear filters") { browser.query = ""; browser.provider = nil }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(accent).frame(minHeight: 28)
            }
        }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sessionAction(_ title: String, action: @escaping () -> Void) -> some View {
        BistButton(action: action) { Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(minHeight: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundColor(accent).background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
    }
}
