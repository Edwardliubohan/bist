import AppKit
import Foundation
import SwiftUI

/// Hidden panels exercise the real delegate without sending desktop input events.
@main
struct PanelLifecycleTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = AppDelegate()
        delegate.store = AppStore(directory: directory, demo: false)
        delegate.preview = PreviewPanelController(store: delegate.store)
        delegate.positionURL = directory.appendingPathComponent("panel-position.json")
        delegate.panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        delegate.panel.contentView = NSView(frame: .zero)
        let bounds = NSScreen.main!.visibleFrame
        let compact = CornerLayout.frame(expanded: false, visibleFrame: bounds)
        delegate.compactOrigin = compact.origin
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: delegate.panel.windowNumber, context: nil, eventNumber: 0,
                              clickCount: 1, pressure: 1)!
        }

        // Keyboard and visible settings navigation must use the same reset path.
        let navigation = PanelState()
        navigation.showSessionForm = true
        navigation.showInbox = true
        navigation.showAgentResults = true
        navigation.detailID = UUID()
        navigation.openSettings()
        expect(navigation.expanded && navigation.showSettings, "Settings opens even from a compact key panel")
        expect(!navigation.showSessionForm && !navigation.showInbox && !navigation.showAgentResults && navigation.detailID == nil, "Settings normalizes stale page flags")
        navigation.showSettings = false
        navigation.showInbox = true
        expect(navigation.showInbox && !navigation.showSessionForm, "Settings can route to updates without stale session form")
        navigation.toggleSettings()
        expect(navigation.showSettings && !navigation.showInbox, "Settings button shares the normalized opening route")
        navigation.toggleSettings()
        expect(!navigation.showSettings && navigation.expanded, "Settings button returns to the open task panel")

        // A half-open header must not cancel the only animation that can finish the reveal.
        delegate.state.expanded = true
        delegate.state.reveal = 0.5
        delegate.panel.setFrame(CGRect(x: compact.maxX - 204, y: compact.maxY - 304, width: 204, height: 304), display: false)
        delegate.state.focusContext.interactionRegions = [BistInteractionRegion(kind: .drag, rect: CGRect(x: 0, y: 0, width: 204, height: 48))]
        let opening = Timer(timeInterval: 100, repeats: false) { _ in }
        delegate.resizeTimer = opening
        expect(!delegate.handleCompactPointer(event(.leftMouseDown, CGPoint(x: 100, y: 280))), "Half-open header defers dragging")
        expect(opening.isValid && delegate.resizeTimer === opening, "Opening timer remains able to complete")
        expect(delegate.compactDrag == nil, "Half-open press cannot start a stranded drag")
        opening.invalidate()

        // Grabbing the closing logo settles to compact geometry before moving.
        delegate.state.expanded = false
        delegate.state.reveal = 0.5
        delegate.panel.setFrame(CGRect(x: compact.maxX - 200, y: compact.maxY - 300, width: 200, height: 300), display: false)
        delegate.resizeTimer = Timer(timeInterval: 100, repeats: false) { _ in }
        expect(delegate.handleCompactPointer(event(.leftMouseDown, CGPoint(x: 176, y: 276))), "Closing logo press starts compact drag")
        expect(delegate.panel.frame.size == CornerLayout.compactSize && delegate.state.reveal == 0, "Closing drag cannot freeze an oversized window")
        expect(delegate.resizeTimer == nil, "Settled compact drag leaves no resize timer")

        // A displaced release counts even when the event stream omitted drag samples.
        expect(delegate.handleCompactPointer(event(.leftMouseUp, CGPoint(x: 16, y: 24))), "Release is handled")
        expect(!delegate.state.expanded, "Unsampled drag release does not open panel")
        expect(delegate.compactOrigin == CGPoint(x: compact.minX - 8, y: compact.minY), "Release position determines saved origin")
        expect(FileManager.default.fileExists(atPath: delegate.positionURL.path), "Drag persists position in isolated store")
        expect(delegate.panel.frame.size == CornerLayout.compactSize, "Released compact drag stays 48 by 48")
        // Hidden full-size pages must not impose their minimum size on the
        // compact host; this previously cropped the corner mark out entirely.
        let host = GlassHostingView(rootView: BistView(store: delegate.store, state: delegate.state, directory: directory))
        host.sizingOptions = []
        delegate.panel.contentView = host
        delegate.state.reveal = 0
        delegate.panel.setFrame(compact, display: false)
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.width <= CornerLayout.compactSize.width && host.fittingSize.height <= CornerLayout.compactSize.height, "Hidden open page cannot enlarge compact layout")
        expect(host.frame.size == CornerLayout.compactSize, "Actual compact host remains 48 by 48")
        print("PASS: \(checks) native panel lifecycle checks")
    }
}
