import AppKit
import SwiftUI

struct BistSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: PanelState
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
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Appearance")
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
                        Text("Adjust the transparency of the entire panel. The task preview always uses a solid warm surface.")
                            .font(.system(size: 10)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
                        Toggle("Solid background", isOn: $state.opaque).toggleStyle(.switch)
                        if systemOpaque { note("macOS Reduce Transparency is on.") }
                        Divider().padding(.vertical, 2)
                        HStack(spacing: 8) {
                            Circle().fill(accent).frame(width: 10, height: 10)
                            Text("Warm orange").fontWeight(.medium)
                            Spacer()
                            Text("Accent").foregroundColor(muted)
                        }
                        note("Dark warm text, orange controls, and distinct tag colors.")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Motion")
                        Toggle("Reduce motion", isOn: $state.reduced).toggleStyle(.switch)
                        note(systemReduced ? "macOS Reduce Motion is on." : "Short transitions connect pages. The corner mark responds to hover and opening.")
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        heading("Organize tasks")
                        note("Drag the handle beside a task. Drop at a row’s edge to reorder, or in its center to nest. Drop on a list heading to move between lists.")
                        note("Right-click a task for Move to… and Delete. Deleting a parent keeps its subtasks unless you choose to delete both. Undo restores the change.")
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        heading("Keyboard")
                        shortcut("New task", "⌘N")
                        shortcut("Tasks / Sessions", "⌘1 / ⌘2")
                        shortcut("Settings", "⌘,")
                        shortcut("Undo task change", "⌘Z")
                        shortcut("Go back / collapse", "Esc")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        heading("Local data")
                        settingsAction("Reload task file", symbol: "arrow.clockwise") { _ = store.reload() }
                        settingsAction("Review local updates", symbol: "tray", action: reviewUpdates)
                        settingsAction("Review agent results", symbol: "checkmark.seal", action: reviewResults)
                        settingsAction(store.tasks.contains(where: \.isSample) ? "Remove sample tasks" : "Load sample tasks", symbol: "square.stack") {
                            if store.tasks.contains(where: \.isSample) { _ = store.clearSamples() }
                            else { _ = store.loadSamples() }
                        }
                        if let error = store.storeError { Text(error).foregroundColor(.red).font(.system(size: 10)) }
                        note("Tasks stay on this Mac. Appearance preferences save automatically.")
                    }
                    Button("Reset appearance") { state.transparency = 0.5; state.opaque = false; state.reduced = false }
                        .buttonStyle(.plain).foregroundColor(accent)
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
