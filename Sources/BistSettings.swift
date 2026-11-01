import AppKit
import SwiftUI

struct BistSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: PanelState
    var sync: BistSyncCoordinator? = nil
    let close: () -> Void
    let reviewUpdates: () -> Void
    let reviewResults: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var systemOpaque
    @Environment(\.accessibilityReduceMotion) private var systemReduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PanelNavigationButton(title: "Back", symbol: "chevron.left", action: close)
                Spacer()
                Text("Settings").font(.system(size: 17, weight: .semibold))
            }.padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let sync { BistSyncSettingsView(sync: sync) }
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Appearance")
                        Picker("Theme", selection: $state.appearanceMode) {
                            ForEach(BistAppearance.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }.pickerStyle(.segmented)
                            .accessibilityLabel("Color theme")
                        HStack {
                            Text("Transparency")
                            Spacer()
                            Text("\(Int((state.transparency * 100).rounded()))%").monospacedDigit().foregroundColor(muted)
                        }
                        Slider(value: $state.transparency, in: 0...1)
                            .tint(accent).disabled(state.opaque || systemOpaque)
                            .accessibilityLabel("Panel transparency")
                            .accessibilityValue("\(Int((state.transparency * 100).rounded())) percent")
                        HStack { Text("Solid"); Spacer(); Text("Glass") }.font(.system(size: 10)).foregroundColor(muted)
                        Toggle("Solid background", isOn: $state.opaque).toggleStyle(.switch)
                        if systemOpaque { note("macOS Reduce Transparency is on.") }
                        Toggle("Reduce motion", isOn: $state.reduced).toggleStyle(.switch)
                        if systemReduced { note("macOS Reduce Motion is on.") }
                        Button("Reset appearance") { state.resetAppearance() }
                            .buttonStyle(.plain).foregroundColor(accent)
                            .frame(minHeight: 30)
                    }
                    DisclosureGroup("Keyboard shortcuts") {
                        VStack(alignment: .leading, spacing: 9) {
                            shortcut("New task", "⌘N")
                            shortcut("Tasks / Sessions / Note", "⌘1 / ⌘2 / ⌘3")
                            shortcut("Move through sessions", "↑ / ↓")
                            shortcut("Open session / mark read", "Return / E")
                            shortcut("Previous / next session", "⌥⌘↑ / ⌥⌘↓")
                            shortcut("Settings", "⌘,")
                            shortcut("Undo task change", "⌘Z")
                            shortcut("Go back / collapse", "Esc")
                        }.padding(.top, 8)
                    }.tint(accent)
                    DisclosureGroup("Local data") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.directory.path).font(.system(size: 10)).foregroundColor(muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            settingsAction("Show data folder", symbol: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.directory.path)
                            }
                            settingsAction("Reload saved data", symbol: "arrow.clockwise") { _ = store.reload() }
                            settingsAction("Review local updates", symbol: "tray", action: reviewUpdates)
                            settingsAction("Review agent results", symbol: "checkmark.seal", action: reviewResults)
                            settingsAction(store.tasks.contains(where: \.isSample) ? "Remove sample tasks" : "Load sample tasks", symbol: "square.stack") {
                                if store.tasks.contains(where: \.isSample) { _ = store.clearSamples() }
                                else { _ = store.loadSamples() }
                            }
                        }.padding(.top, 8)
                    }.tint(accent)
                    if let error = store.storeError { Text(error).foregroundColor(.red).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true) }
                    Divider()
                    settingsAction("Quit bist", symbol: "power") { NSApp.terminate(nil) }
                }.padding(.bottom, 16)
            }.scrollContentBackground(.hidden)
        }.font(.system(size: 11)).foregroundColor(ink).padding(.horizontal, 21).padding(.bottom, 12)
    }
    private func heading(_ title: String) -> some View { Text(title).font(.system(size: 13, weight: .semibold)) }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true) }
    private func shortcut(_ title: String, _ keys: String) -> some View {
        HStack { Text(title); Spacer(); Text(keys).foregroundColor(muted) }
    }
    private func settingsAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        BistButton(action: action) { Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

struct BistSyncSettingsView: View {
    @ObservedObject var sync: BistSyncCoordinator
    @State private var restoredVersion: String?
    @State private var confirmCloudRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Sync").font(.system(size: 13, weight: .semibold))
            Toggle("Sync with iCloud", isOn: Binding(get: { sync.enabled }, set: sync.setEnabled))
                .toggleStyle(.switch).disabled(!sync.isAvailable)
            Text(sync.status).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            if !sync.isAvailable {
                Text("This build saves on this Mac. An iCloud-enabled build can sync with your iPhone.")
                    .foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            }
            if sync.enabled {
                if sync.pendingCount > 0 { Text("\(sync.pendingCount) changes waiting").foregroundColor(muted) }
                if let date = sync.lastSyncedAt {
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))").foregroundColor(muted)
                }
                if sync.recoveryRequired {
                    Button("Restore local data to iCloud") { confirmCloudRecovery = true }
                        .buttonStyle(.plain).foregroundColor(accent).frame(minHeight: 30)
                }
                Button("Sync now") { Task { await sync.syncNow() } }
                    .buttonStyle(.plain).foregroundColor(accent).frame(minHeight: 30)
            }
            if let error = sync.error {
                Text(error).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !sync.noteVersions.isEmpty {
                DisclosureGroup("Saved note versions") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(sync.noteVersions.enumerated()), id: \.offset) { _, text in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(text.isEmpty ? "Empty note" : text).lineLimit(4)
                                    .foregroundColor(muted).textSelection(.enabled)
                                Button("Restore this version") { restoredVersion = text }
                                    .buttonStyle(.plain).foregroundColor(accent).frame(minHeight: 30)
                            }
                        }
                    }.padding(.top, 8)
                }.tint(accent)
            }
        }
        .confirmationDialog("Restore local data to iCloud?", isPresented: $confirmCloudRecovery, titleVisibility: .visible) {
            Button("Restore local data") { Task { await sync.recoverCloudData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A backup is saved on this Mac, then your current local tasks and note are uploaded to your iCloud account.")
        }
        .confirmationDialog("Restore this note version?", isPresented: Binding(get: { restoredVersion != nil }, set: { if !$0 { restoredVersion = nil } })) {
            Button("Restore note") {
                if let text = restoredVersion { sync.restoreNoteVersion(text) }
                restoredVersion = nil
            }
            Button("Cancel", role: .cancel) { restoredVersion = nil }
        } message: {
            Text("Your saved current note remains in saved versions.")
        }
    }
}
