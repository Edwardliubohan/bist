import AppKit
import SwiftUI

private final class EntryState: ObservableObject {
    @Published var request = 0
    @Published var editor = false
    var focused = false
    var text = "Caret regression"
}

private struct EntryHarness: View {
    @ObservedObject var state: EntryState
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if state.editor {
                TextEditor(text: Binding(get: { state.text }, set: { state.text = $0 }))
                    .scrollContentBackground(.hidden)
                    .bistTextEntry(focused: $focused)
            } else {
                TextField("Task name", text: Binding(get: { state.text }, set: { state.text = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .bistTextEntry(focused: $focused)
            }
        }
        .font(.system(size: 13)).foregroundColor(ink)
        .padding(10).frame(width: 300, height: 180)
        .background(ivory).tint(accent).environment(\.controlActiveState, .key)
        .onChange(of: state.request) { focused = true }
        .onChange(of: focused) { state.focused = focused }
    }
}

@main struct TextEntryFocusTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let context = BistFocusContext()
        let state = EntryState()
        let host = NSHostingView(rootView: EntryHarness(state: state).environmentObject(context))
        let window = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)); host.layoutSubtreeIfNeeded() }
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        func capture() -> Data {
            host.displayIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        func hasOutline(_ data: Data) -> Bool {
            let bitmap = NSBitmapImageRep(data: data)!
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            return (10..<170).contains { y in
                let color = bitmap.colorAt(x: Int(8 * scale), y: Int(CGFloat(y) * scale))!.usingColorSpace(.sRGB)!
                return color.redComponent < 0.9 && color.greenComponent < 0.6 && color.blueComponent < 0.5
            }
        }
        for editor in [false, true] {
            state.editor = editor; pump()
            state.request += 1; pump()
            expect(state.focused, "Task input and Note accept programmatic keyboard focus")
            let views = textViews(host)
            expect(!views.isEmpty, "Real SwiftUI text entry has a native backing editor")
            let color = views[0].insertionPointColor.usingColorSpace(.sRGB)!
            expect(abs(color.redComponent - 0.16) < 0.01 && abs(color.greenComponent - 0.12) < 0.01 && abs(color.blueComponent - 0.09) < 0.01,
                   "Caret uses dark ink rather than the inherited accent")
            expect(!hasOutline(capture()), "Focused inputs retain the borderless appearance without a highlighted box")
            context.dismissTextEntry(); pump()
            expect(!state.focused, "Click-away/collapse dismissal clears the entry's SwiftUI focus")
            expect(!hasOutline(capture()), "Dismissed input has no stale focus outline")
            expect(state.text == "Caret regression", "Dismissing focus preserves draft text")
            state.request += 1; pump()
            expect(state.focused, "Entry can regain focus after dismissal")
            context.dismissTextEntry(); pump()
        }
        window.orderOut(nil)
        print("PASS: \(checks) native text-entry focus checks")
    }
}
