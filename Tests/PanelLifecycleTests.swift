import AppKit
import Foundation
import SwiftUI

/// Exercise the real native surface, event router and completion callbacks in an
/// isolated store. No synthesized desktop input and no changes to the user's app.
@main
struct PanelLifecycleTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let onScreen = CommandLine.arguments.contains("--on-screen-motion-check")
        app.setActivationPolicy(onScreen ? .accessory : .prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "bist.motion-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate(state: PanelState(preferences: preferences))
        delegate.store = AppStore(directory: directory, demo: true)
        delegate.preview = PreviewPanelController(store: delegate.store)
        delegate.positionURL = directory.appendingPathComponent("panel-position.json")
        delegate.panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = GlassHostingView(rootView: BistView(store: delegate.store, state: delegate.state, directory: directory))
        host.sizingOptions = []
        let surface = PanelTransitionSurface(host: host)
        delegate.panel.contentView = surface
        delegate.state.resize = { [weak delegate] expanded, animated in delegate?.position(expanded, animated: animated) }
        let bounds = NSScreen.main!.visibleFrame
        let compact = CornerLayout.frame(expanded: false, visibleFrame: bounds)
        let open = CornerLayout.frame(expanded: true, visibleFrame: bounds)
        delegate.compactOrigin = compact.origin
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func event(_ type: NSEvent.EventType, screenPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: delegate.panel.convertPoint(fromScreen: screenPoint), modifierFlags: [], timestamp: 0,
                              windowNumber: delegate.panel.windowNumber, context: nil, eventNumber: 0,
                              clickCount: 1, pressure: 1)!
        }
        func set(_ value: Bool, animated: Bool = true) { delegate.state.setExpanded(value, animated: animated) }
        func cornerPoint() -> CGPoint {
            let rect = surface.presentationRect.offsetBy(dx: delegate.panel.frame.minX, dy: delegate.panel.frame.minY)
            return CGPoint(x: rect.maxX - 24, y: rect.maxY - 24)
        }

        let navigation = PanelState(preferences: preferences)
        navigation.showSessionForm = true; navigation.showInbox = true
        navigation.showAgentResults = true; navigation.detailID = UUID()
        navigation.openSettings()
        expect(navigation.expanded && navigation.showSettings, "Settings opens from compact")
        expect(!navigation.showSessionForm && !navigation.showInbox && !navigation.showAgentResults && navigation.detailID == nil, "Settings normalizes stale navigation")
        navigation.toggleSettings()
        expect(!navigation.showSettings && navigation.expanded, "Settings returns to open panel")

        set(false, animated: false)
        if onScreen { delegate.panel.orderFrontRegardless(); pump(0.1) }
        expect(delegate.panel.frame == compact, "Compact native window is exactly 48 points")
        expect(host.frame.size == open.size, "SwiftUI retains its final reading size while compact")
        set(true)
        let generation = delegate.transitionGeneration
        let stage = delegate.panel.frame
        expect(delegate.state.isTransitioning, "Opening starts a compositor transition")
        expect(!delegate.preview.isVisible, "Preview suppressed during opening")
        pump(0.04)
        if onScreen { expect(surface.hasAnimatedPresentation, "Visible test exercises the render-server presentation layer") }
        expect(delegate.panel.frame == stage && host.frame.size == open.size, "No per-frame native resizing or SwiftUI layout resizing")
        delegate.position(true, animated: true)
        expect(delegate.transitionGeneration == generation, "Repeated open cannot restart the reveal")
        let header = CGPoint(x: stage.midX, y: stage.maxY - 20)
        expect(delegate.handleCompactPointer(event(.leftMouseDown, screenPoint: header)), "Half-open content press is consumed")
        expect(delegate.transitionGeneration == generation && delegate.state.isTransitioning, "Content press never strands the transition")
        pump(0.35)
        expect(!delegate.state.isTransitioning && delegate.panel.frame == open, "Opening finishes exactly and re-enables input")

        set(false)
        pump(0.04)
        let closingStage = delegate.panel.frame
        let closingGeneration = delegate.transitionGeneration
        let press = cornerPoint()
        expect(delegate.handleCompactPointer(event(.leftMouseDown, screenPoint: press)), "Closing corner accepts a reversal click")
        expect(delegate.state.isTransitioning && delegate.panel.frame == closingStage && delegate.transitionGeneration == closingGeneration, "Mouse down does not snap to compact")
        expect(delegate.handleCompactPointer(event(.leftMouseUp, screenPoint: press)), "Reversal click release is handled")
        expect(delegate.state.expanded && delegate.state.isTransitioning, "Reversal retargets to open")
        pump(0.35)
        expect(delegate.panel.frame == open && !delegate.state.isTransitioning, "Cancelled completion cannot collapse a reopened panel")

        for index in 0..<100 {
            set(index % 2 == 0)
            expect(host.frame.size == open.size, "Rapid toggles preserve a stable content layout")
            expect(!delegate.preview.isVisible, "Rapid toggles never display a hover preview")
        }
        set(true)
        pump(0.4)
        expect(delegate.state.expanded && !delegate.state.isTransitioning && delegate.panel.frame == open, "100 reversals settle on the latest request")
        pump(0.15)
        expect(delegate.panel.frame == open, "Stale callbacks remain inert after settlement")

        // Retarget while the render server has advanced, in addition to the
        // same-run-loop burst above. Run this against a visible panel as well.
        for index in 0..<16 {
            set(index % 2 == 0)
            pump(0.025 + Double(index % 3) * 0.015)
            expect(host.frame.size == open.size, "Timed reversals never reflow SwiftUI")
            expect(surface.presentationRect.width >= 47.9 && surface.presentationRect.width <= open.width + 0.1, "Presentation width stays within endpoints")
            expect(surface.presentationRect.height >= 47.9 && surface.presentationRect.height <= open.height + 0.1, "Presentation height stays within endpoints")
        }
        set(true); pump(0.35)
        expect(delegate.state.expanded && !delegate.state.isTransitioning && delegate.panel.frame == open, "Timed reversals settle exactly")

        set(false, animated: false); set(true)
        CATransaction.flush()
        Thread.sleep(forTimeInterval: 0.3)
        pump(0.1)
        expect(!delegate.state.isTransitioning && delegate.panel.frame == open, "A busy main thread cannot strand the reveal between endpoints")

        set(false)
        pump(0.03)
        delegate.state.reduced = true
        delegate.position(false, animated: true)
        expect(!delegate.state.isTransitioning && delegate.panel.frame == compact, "Reduce Motion cancels motion and settles synchronously")
        pump(0.3)
        expect(delegate.panel.frame == compact, "Old animation cannot revive after reduced-motion settlement")
        delegate.state.reduced = false

        // Grabbing and dragging during closing settles before moving, but an
        // ordinary click above was handled without any geometry snap.
        set(true, animated: false); set(false)
        let dragStart = cornerPoint()
        _ = delegate.handleCompactPointer(event(.leftMouseDown, screenPoint: dragStart))
        let dragEnd = CGPoint(x: dragStart.x - 20, y: dragStart.y - 10)
        _ = delegate.handleCompactPointer(event(.leftMouseDragged, screenPoint: dragEnd))
        _ = delegate.handleCompactPointer(event(.leftMouseUp, screenPoint: dragEnd))
        expect(!delegate.state.expanded && !delegate.state.isTransitioning, "Drag during closing leaves a settled compact panel")
        expect(delegate.panel.frame.size == CornerLayout.compactSize, "Drag cannot leave a large invisible hit window")
        expect(FileManager.default.fileExists(atPath: delegate.positionURL.path), "Drag persists only in isolated data")

        // Fractional drag coordinates must be normalized BEFORE opening. Check
        // the actual native hosting-view center, not just the abstract rectangle.
        delegate.compactOrigin = CGPoint(x: bounds.maxX - 96.23828125, y: bounds.maxY - 260.9296875)
        set(false, animated: false)
        let scale = NSScreen.main!.backingScaleFactor
        expect((delegate.panel.frame.minX * scale).rounded() == delegate.panel.frame.minX * scale, "Compact x uses physical pixels")
        expect((delegate.panel.frame.minY * scale).rounded() == delegate.panel.frame.minY * scale, "Compact y uses physical pixels")
        func markCenter() -> CGPoint {
            let point = CGPoint(x: host.bounds.maxX - 24, y: host.isFlipped ? 24 : host.bounds.maxY - 24)
            return delegate.panel.convertPoint(toScreen: host.convert(point, to: nil))
        }
        let pinned = markCenter()
        for _ in 0..<8 {
            set(true)
            expect(markCenter() == pinned, "Mark does not jump on opening mouse-up")
            pump(0.06)
            let visible = surface.presentationRect.offsetBy(dx: delegate.panel.frame.minX, dy: delegate.panel.frame.minY)
            expect(abs(visible.maxX - 24 - pinned.x) < 0.01 && abs(visible.maxY - 24 - pinned.y) < 0.01, "Visible mask keeps the mark pinned in flight")
            set(false)
            expect(markCenter() == pinned, "Reversal does not move the native mark")
            pump(0.3)
            expect(markCenter() == pinned && !delegate.state.isTransitioning, "Collapse returns to identical native coordinates")
        }

        // Verify the actual backdrop lives below SwiftUI, and that the full
        // slider range changes alpha instead of uncovering an opaque material.
        surface.updateAppearance(transparency: 0, opaque: false)
        expect(!surface.isGlassEnabled && surface.tintOpacity == 1, "Zero percent is actually solid")
        surface.updateAppearance(transparency: 0.5, opaque: false)
        expect(surface.isGlassEnabled && abs(surface.tintOpacity - 0.53) < 0.0001, "Middle setting mixes tint with native glass")
        surface.updateAppearance(transparency: 1, opaque: false)
        expect(surface.isGlassEnabled && abs(surface.tintOpacity - 0.06) < 0.0001, "Full glass leaves only a light warm tint")
        expect(surface.nativeBackdrop.superview === surface && surface.nativeBackdrop.blendingMode == .behindWindow && surface.nativeBackdrop.material == .underWindowBackground, "Desktop blur is a native sibling beneath the hosting view")
        expect(surface.layer?.mask == nil && surface.nativeBackdrop.layer?.mask == nil, "Settled desktop backdrop is outside the content mask")
        expect(abs(surface.nativeBackdrop.alphaValue - 0.8) < 0.0001, "Native material cannot turn the glass endpoint fully opaque")
        surface.updateAppearance(transparency: 1, opaque: true)
        expect(!surface.isGlassEnabled && surface.nativeBackdrop.isHidden && surface.tintOpacity == 1, "Solid / system transparency override disables blur and restores opaque tint")
        surface.updateAppearance(transparency: 0, opaque: false)

        // Expansion near the bottom-left has different endpoint anchors. The
        // mask and content translate together, then collapse returns precisely.
        delegate.compactOrigin = CGPoint(x: bounds.minX + 5, y: bounds.minY + 5)
        delegate.position(false)
        let displacedCompact = delegate.panel.frame
        set(true); pump(0.35)
        expect(bounds.contains(delegate.panel.frame), "Edge expansion stays on screen")
        set(false); pump(0.35)
        expect(delegate.panel.frame == displacedCompact, "Edge collapse returns to the chosen compact position")
        expect(surface.presentationRect == surface.bounds, "Settled mask exactly matches the native window")
        expect(host.frame.size == open.size, "Even clamped transitions retain final content size")

        // Capture the real native host for a visual check of the new steady states.
        func capture(_ name: String) throws {
            surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
            if let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
                surface.cacheDisplay(in: surface.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "build/tests/\(name).png"))
                }
            }
        }
        try capture("motion-compact")
        set(true, animated: false); pump(0.05)
        try capture("motion-expanded")
        delegate.panel.orderOut(nil)
        print("PASS: \(checks) native panel lifecycle checks (fixed layout, 100 reversals, stale callbacks, click/drag interruption, reduced motion, edge clamping)")
    }
}
