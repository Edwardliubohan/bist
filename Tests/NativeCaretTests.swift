import AppKit
import SwiftUI

private final class CaretProbe: NSTextView {
    var refreshes = 0
    var composing = false
    override func hasMarkedText() -> Bool { composing || super.hasMarkedText() }
    override func updateInsertionPointStateAndRestartTimer(_ restart: Bool) {
        if restart { refreshes += 1 }
        super.updateInsertionPointStateAndRestartTimer(restart)
    }
    // Isolate the panel's post-click handling from NSTextView's own refresh.
    override func mouseDown(with event: NSEvent) {}
}

@MainActor private final class CaretTestRunner: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var other: FloatingPanel!
    var editor: CaretProbe!
    var checks = 0
    func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel(contentRect: CGRect(x: 80, y: 80, width: 260, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        editor = CaretProbe(frame: CGRect(x: 0, y: 0, width: 260, height: 100))
        editor.string = "preserve this draft"
        panel.contentView = editor
        other = FloatingPanel(contentRect: CGRect(x: 80, y: 80, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        _ = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            MainActor.assumeIsolated { self.verify() }
        }
    }

    func verify() {
        panel.makeKeyAndOrderFront(nil); pump()
        expect(panel.isKeyWindow, "Native test must own actual keyboard focus")
        expect(panel.makeFirstResponder(editor), "Native text view accepts focus")
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 0,
                                      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        editor.refreshes = 0
        panel.sendEvent(click)
        expect(editor.refreshes > 0, "Panel restarts native caret after mouse handling even if the editor already owns focus")
        expect(editor.selectedRange() == NSRange(location: 4, length: 0), "Caret refresh preserves the insertion location")
        let color = editor.insertionPointColor.usingColorSpace(.sRGB)!
        expect(abs(color.redComponent - 0.64) < 0.01 && abs(color.greenComponent - 0.24) < 0.01 && abs(color.blueComponent - 0.055) < 0.01,
               "Native caret uses the app burnt-orange accent")

        let delegate = AppDelegate()
        delegate.panel = panel
        editor.refreshes = 0
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        expect(editor.refreshes > 0, "Completed application activation refreshes the current key editor")
        editor.composing = true
        editor.refreshes = 0
        panel.refreshTextInsertionPoint()
        expect(editor.refreshes == 0, "IME composition owns its native insertion indicator")
        editor.composing = false
        editor.isEditable = false
        editor.refreshes = 0
        panel.refreshTextInsertionPoint()
        expect(editor.refreshes == 0, "Read-only text never receives an editing caret refresh")
        editor.isEditable = true
        for _ in 0..<30 {
            other.makeKeyAndOrderFront(nil); pump()
            expect(!panel.isKeyWindow, "Test leaves the editing panel's key-window state")
            editor.refreshes = 0
            panel.refreshTextInsertionPoint()
            expect(editor.refreshes == 0, "Inactive panel cannot restart a caret or claim keyboard focus")
            panel.makeKeyAndOrderFront(nil); pump()
            expect(panel.isKeyWindow && panel.firstResponder === editor, "Reactivation retains the current editor")
            expect(editor.refreshes > 0, "Key-window reentry refreshes the current native caret")
            expect(editor.selectedRange() == NSRange(location: 4, length: 0), "Repeated reactivation never moves the insertion point")
        }
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.refreshes = 0
        panel.refreshTextInsertionPoint()
        expect(editor.refreshes == 0 && editor.selectedRange() == NSRange(location: 2, length: 3), "Selected text stays selected without drawing an insertion caret")
        expect(editor.string == "preserve this draft", "Focus repair never changes draft content")
        // A pending activation callback must inspect current focus, not restore
        // the editor after the user has clicked elsewhere.
        other.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        _ = panel.makeFirstResponder(nil)
        pump()
        expect(!(panel.firstResponder is NSTextView), "Deferred key callback does not resurrect a dismissed editor")
        panel.orderOut(nil); other.orderOut(nil)
        print("PASS: \(checks) native caret lifecycle checks (post-click refresh, 30 key-window cycles, selection/draft preservation)")
        NSApp.stop(nil)
    }
}

@main struct NativeCaretTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = CaretTestRunner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}
