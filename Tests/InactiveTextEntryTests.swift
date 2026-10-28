import AppKit
import SwiftUI

private final class InactiveEntryState: ObservableObject {
    @Published var text = "cold caret"
}

/// Use the same native SwiftUI controls and focus modifier as task capture and
/// Note. Each control runs in a fresh process, without prior text focus.
private struct InactiveEntryView: View {
    @ObservedObject var state: InactiveEntryState
    let note: Bool
    var body: some View {
        Group {
            if note {
                TextEditor(text: $state.text).scrollContentBackground(.hidden).bistTextEntry()
            } else {
                TextField("Task name", text: $state.text, axis: .vertical).textFieldStyle(.plain).bistTextEntry()
            }
        }
        .font(.system(size: 13)).foregroundColor(ink)
        .padding(10).frame(width: 300, height: 180).background(ivory)
        .tint(accent).environment(\.controlActiveState, .key)
    }
}

@MainActor private final class InactiveEntryRunner: NSObject, NSApplicationDelegate {
    let state = InactiveEntryState()
    let note = CommandLine.arguments.contains("--note")
    var panel: FloatingPanel!
    var host: NSHostingView<AnyView>!
    var insertionLocation = 0

    func later(_ action: @escaping @MainActor () -> Void) {
        _ = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel(contentRect: NSRect(x: 650, y: 500, width: 300, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        host = NSHostingView(rootView: AnyView(InactiveEntryView(state: state, note: note).environmentObject(BistFocusContext())))
        panel.contentView = host
        panel.orderFrontRegardless()
        later {
            NSApp.deactivate()
            self.later { self.firstClick() }
        }
    }

    func firstClick() {
        precondition(!NSApp.isActive && !NSRunningApplication.current.isActive,
                     "First text click must start with an inactive application")
        precondition(!(panel.firstResponder is NSTextView), "No editor may be focused before the first click")
        // Opening bist requests key focus. There is deliberately no application
        // activation here: the panel must not depend on its completion.
        panel.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func inputs(_ view: NSView) -> [NSView] {
            (view is NSTextView || view is NSTextField) ? [view] : view.subviews.flatMap(inputs)
        }
        let input = inputs(host).first!
        let point = input.convert(CGPoint(x: 30, y: input.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        later { self.verifyCaret() }
    }

    func verifyCaret() {
        precondition(!NSRunningApplication.current.isActive, "A separate application activation must not mask the first-click result")
        precondition(panel.isKeyWindow && NSApp.keyWindow === panel, "First click must own actual keyboard focus")
        let editor = panel.firstResponder as! NSTextView
        precondition(editor.window === panel && editor.selectedRange().length == 0, "First click must place the native insertion point")
        precondition(state.text == "cold caret", "Pointer focus must preserve the draft")
        insertionLocation = editor.selectedRange().location

        // Cache the native rendering while the blink is on. Brown text and the
        // ivory background cannot satisfy this orange-pixel predicate. Allow
        // color-profile conversion; exact caret color is checked separately.
        host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var caretPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if color.redComponent > 0.4 && color.redComponent - color.greenComponent > 0.2 &&
                    color.greenComponent - color.blueComponent > 0.07 && color.alphaComponent > 0.9 {
                    caretPixels += 1
                }
            }
        }
        precondition(caretPixels >= 10, "The first native caret must actually render, not just report focus")
        let path = "build/tests/inactive-\(note ? "note" : "task")-caret.png"
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))

        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                  context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
        NSApp.postEvent(key, atStart: false)
        later { self.verifyTyping() }
    }

    func verifyTyping() {
        var expected = "cold caret"
        expected.insert("x", at: expected.index(expected.startIndex, offsetBy: insertionLocation))
        precondition(state.text == expected, "Native keyboard input must reach the first-click insertion location")
        panel.orderOut(nil)
        print("PASS: inactive first-click \(note ? "Note" : "task capture") has key focus, visible native caret pixels and working keyboard input")
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }
}

@main struct InactiveTextEntryTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = InactiveEntryRunner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}
