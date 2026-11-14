import AppKit
import SwiftUI

@main struct PanelResizeTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-resize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "bist.resize-tests.\(UUID())"
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
        delegate.state.setExpanded(true, animated: false)
        precondition(delegate.panel.styleMask.contains(.resizable), "Expanded panel supports native edge resizing")
        let topEdge = CGPoint(x: delegate.panel.frame.midX, y: delegate.panel.frame.maxY - 1)
        let edgeEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: delegate.panel.convertPoint(fromScreen: topEdge),
            modifierFlags: [], timestamp: 0, windowNumber: delegate.panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(!delegate.handleCompactPointer(edgeEvent), "Header dragging leaves the native resize edge available")
        let before = delegate.panel.frame
        let desired = CGSize(width: 500, height: 400)
        delegate.panel.setFrame(CGRect(x: before.maxX - desired.width, y: before.maxY - desired.height,
                                      width: desired.width, height: desired.height), display: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        precondition(delegate.state.openSize == desired && host.frame.size == desired,
                     "Native resizing updates SwiftUI and reading size")
        precondition(surface.presentationRect == surface.bounds && surface.contentSize == desired,
                     "Native resizing updates masks and hit bounds")
        let anchor = CGPoint(x: delegate.panel.frame.maxX, y: delegate.panel.frame.maxY)
        delegate.state.setExpanded(false, animated: false)
        precondition(delegate.panel.frame.size == CornerLayout.compactSize, "Collapse stays exactly 48 points")
        precondition(!delegate.panel.styleMask.contains(.resizable), "Compact control cannot be resized")
        delegate.state.setExpanded(true, animated: false)
        precondition(delegate.panel.frame.size == desired, "Collapse and reopen retain the chosen size")
        precondition(delegate.panel.frame.maxX == anchor.x && delegate.panel.frame.maxY == anchor.y,
                     "Resizing retains the compact corner anchor")
        precondition(delegate.panel.minSize == CornerLayout.minimumExpandedSize,
                     "Minimum size keeps navigation and editing usable")
        let smallerScreen = CGRect(x: 0, y: 0, width: 450, height: 380)
        delegate.draggingExpanded = true
        let fitted = CornerLayout.dragFrame(expanded: true, origin: .zero, visibleFrame: smallerScreen, expandedSize: desired)
        delegate.applyDraggedFrame(fitted, visibleFrame: smallerScreen)
        precondition(delegate.state.openSize == CGSize(width: 418, height: 348), "Smaller screens fit the reading area")
        precondition(delegate.panel.maxSize == fitted.size, "Screen moves refresh native resize limits")
        var widthOnly = fitted
        widthOnly.size.width = 400
        delegate.panel.setFrame(widthOnly, display: false)
        precondition(delegate.state.preferredOpenSize == CGSize(width: 400, height: desired.height),
                     "A width-only resize on a smaller screen preserves the preferred height")
        delegate.state.rememberOpenSize(desired)
        delegate.position(true)
        precondition(delegate.panel.frame.size == desired, "Temporary screen fitting preserves the chosen size")
        delegate.state.openSettings(animated: false)
        precondition(delegate.panel.frame.size == desired, "Settings and repeated open retain size")
        let restored = AppDelegate(state: PanelState(preferences: preferences))
        restored.store = delegate.store; restored.preview = delegate.preview
        restored.panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        restored.state.expanded = true
        restored.position(true)
        precondition(restored.panel.frame.size == desired, "Chosen size survives a new app state")
        delegate.draggingExpanded = true
        delegate.updateDraggedFrame(CGPoint(x: before.minX, y: before.minY), pointer: before.origin)
        precondition(delegate.panel.frame.size == desired, "Dragging retains the chosen expanded size")
        preferences.set([-1.0, 0.0], forKey: "panelExpandedSize")
        precondition(PanelState(preferences: preferences).preferredOpenSize == CornerLayout.expandedSize,
                     "Invalid saved sizes fall back to a usable default")
        print("PASS native panel resizing, content geometry, compact size, reopening, persistence and dragging")
    }
}
