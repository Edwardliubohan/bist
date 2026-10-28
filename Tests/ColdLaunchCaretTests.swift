import AppKit
import SwiftUI

/// A newly mounted native editor can supply its input context during mouse
/// tracking, after AppKit has already processed its first-responder change.
private final class FirstContext: NSTextInputContext {
    var activations = 0
    override func activate() { activations += 1; super.activate() }
}
private final class FirstEditor: NSTextView {
    var firstContext: FirstContext?
    var mouseDowns = 0
    var activatedBeforeCaretRefresh = false
    override var inputContext: NSTextInputContext? { firstContext ?? super.inputContext }
    override func mouseDown(with event: NSEvent) {
        mouseDowns += 1
        _ = window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: 3, length: 0))
        // Model the first lazy context arriving within this input event. No
        // context getter or window update is used to warm it before the click.
        firstContext = FirstContext(client: self)
        precondition(firstContext!.activations == 0, "Fixture must begin with an unregistered input context")
    }
    override func updateInsertionPointStateAndRestartTimer(_ restart: Bool) {
        if restart, let context = firstContext, context.activations > 0 { activatedBeforeCaretRefresh = true }
        super.updateInsertionPointStateAndRestartTimer(restart)
    }
}
private final class KeySink: NSView { override var acceptsFirstResponder: Bool { true } }

@MainActor private final class ColdLaunchRunner: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var editor: FirstEditor!
    var sink: KeySink!
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel(contentRect: NSRect(x: 80, y: 80, width: 260, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        sink = KeySink(frame: NSRect(x: 259, y: 99, width: 1, height: 1))
        editor = FirstEditor(frame: NSRect(x: 0, y: 0, width: 250, height: 90))
        editor.string = "cold launch draft"
        editor.font = .systemFont(ofSize: 13)
        content.addSubview(editor); content.addSubview(sink)
        panel.contentView = content; panel.initialFirstResponder = sink
        _ = panel.makeFirstResponder(sink)
        // Do not activate the application first. On cold launch its activation
        // can still be pending when the panel receives its first text click.
        panel.makeKeyAndOrderFront(nil)
        _ = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated { self.verifyFirstClick() }
        }
    }
    func verifyFirstClick() {
        precondition(panel.isKeyWindow && NSApp.keyWindow === panel, "Cold panel must accept keyboard focus without prior application activation")
        precondition(editor.firstContext == nil && panel.firstResponder === sink, "No text editor may be focused before the first click")
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 30, y: 30), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        panel.sendEvent(event)
        // Check synchronously, before another event-loop turn could happen to
        // register the context or an external app activation could mask it.
        precondition(editor.mouseDowns == 1 && panel.firstResponder === editor, "The first pointer click must focus the native editor")
        precondition(editor.firstContext!.activations > 0, "First-click input context must be registered before the caret is refreshed")
        precondition(editor.activatedBeforeCaretRefresh, "Blink refresh must run after native input-context activation")
        precondition(editor.selectedRange() == NSRange(location: 3, length: 0), "Cold-start repair must preserve the insertion location")
        precondition(editor.string == "cold launch draft", "Cold-start repair must preserve draft text")
        let color = editor.insertionPointColor.usingColorSpace(.sRGB)!
        precondition(abs(color.redComponent - 0.64) < 0.01 && abs(color.greenComponent - 0.24) < 0.01 && abs(color.blueComponent - 0.055) < 0.01,
                     "First caret must use the app burnt-orange accent")
        _ = panel.makeFirstResponder(sink)
        NSApp.updateWindows()
        panel.orderOut(nil)
        print("PASS: native cold-start panel takes key focus without prior app activation, then registers first-click input context before caret drawing")
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
    }
}
@main struct ColdLaunchCaretTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let runner = ColdLaunchRunner(); app.delegate = runner
        app.run(); withExtendedLifetime(runner) {}
    }
}
