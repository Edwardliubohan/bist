import AppKit
import SwiftUI

final class HoverTestPanel: NSPanel {
    var testPointer = NSPoint(x: -1000, y: -1000)
    override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
}

@main
struct CornerHoverTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-hover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "bist.hover-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = PanelState(preferences: preferences)
        state.setExpanded(true, animated: false)
        let store = AppStore(directory: directory, demo: true)
        let panel = HoverTestPanel(contentRect: CGRect(x: 100, y: 100, width: 360, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: BistView(store: store, state: state, directory: directory))
        host.sizingOptions = []
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12)) }
        pump()
        func hoverViews(_ view: NSView) -> [CornerHoverRegion.HoverView] {
            (view as? CornerHoverRegion.HoverView).map { [$0] } ?? view.subviews.flatMap(hoverViews)
        }
        let views = hoverViews(host)
        precondition(views.count == 1, "Expanded panel has one corner hover region")
        let view = views[0]
        view.updateTrackingAreas()
        precondition(view.bounds.size == CornerLayout.compactHitSize, "Hover target stays 44 points")
        precondition(view.trackingAreas.count == 1 && view.trackingAreas[0].rect == view.bounds.intersection(view.visibleRect), "Native tracking is confined to the logo")
        let area = view.trackingAreas[0]
        view.updateTrackingAreas()
        precondition(view.trackingAreas[0] === area, "Unchanged layout preserves the tracking area")
        panel.testPointer = NSPoint(x: 336, y: 536)
        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: panel.testPointer, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseEntered(with: entered)
        pump()
        precondition(state.corner.isHovered, "Entering the expanded logo activates hover")
        panel.testPointer = NSPoint(x: 180, y: 280)
        // No synthetic exit event: the real timer must notice departure even
        // when SwiftUI or another control consumes the mouse event.
        pump()
        precondition(!state.corner.isHovered, "Leaving the logo for the panel body clears hover")
        precondition(!state.cornerHighlighted && state.expanded, "Leaving clears feedback without collapsing the panel")
        panel.testPointer = NSPoint(x: 336, y: 536)
        view.mouseEntered(with: entered)
        pump()
        precondition(state.corner.isHovered, "Reentering the logo activates hover again")
        panel.testPointer = NSPoint(x: -10, y: -10)
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: panel.testPointer, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseExited(with: exited)
        precondition(!state.corner.isHovered, "Leaving the window still clears hover")
        state.setExpanded(false, animated: false)
        pump()
        panel.testPointer = NSPoint(x: 336, y: 536)
        view.mouseEntered(with: entered)
        precondition(state.corner.isHovered && state.cornerHighlighted, "Compact logo retains hover feedback")
        view.stopTracking()
        precondition(!state.corner.isHovered, "Dismantling clears hover and cancels the timer")
        // Exercise the actual preview host, geometry updates, and AppKit scroll view.
        let previewStore = AppStore(directory: directory.appendingPathComponent("preview"), demo: false)
        let preview = PreviewPanelController(store: previewStore)
        let screen = NSScreen.main!.visibleFrame
        let anchor = CornerLayout.frame(expanded: false, visibleFrame: screen)
        preview.reposition(anchor: anchor, visibleFrame: screen)
        let previewWindow = NSApplication.shared.windows.first { $0.title == "bist task preview" }!
        let previewHost = previewWindow.contentView!
        func settlePreview() { pump(); previewHost.layoutSubtreeIfNeeded(); pump() }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func snapshot(_ name: String) throws {
            guard let output = ProcessInfo.processInfo.environment["BIST_PREVIEW_EVIDENCE"] else { return }
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = previewHost.bitmapImageRepForCachingDisplay(in: previewHost.bounds)!
            previewHost.cacheDisplay(in: previewHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
        }
        settlePreview()
        precondition(previewWindow.frame.height == 50, "Empty preview hugs its message plus bridge")
        for index in 1...12 { precondition(previewStore.addTask(title: "Preview task \(index)")) }
        settlePreview()
        let selection = PreviewTaskSelection(previewStore.tasks, isOutstanding: { !$0.completed }, isShortTerm: { $0.horizon == .shortTerm })
        precondition(previewWindow.frame.height == selection.contentHeight + CornerLayout.previewGap, "Twelve rows grow beyond the old cap without scrolling")
        let scroll = scrollViews(previewHost).first!
        precondition(scroll.scrollerStyle == .overlay && scroll.autohidesScrollers, "Preview uses auto-hiding native overlay scrollers")
        precondition(scroll.verticalScroller?.controlSize == .mini, "Preview scrollbar is thin")
        precondition(scroll.documentView!.frame.height <= scroll.contentView.bounds.height + 1, "Medium list fits without overflow")
        try snapshot("twelve-tasks")
        for index in 13...50 { precondition(previewStore.addTask(title: "Preview task \(index)", horizon: index > 35 ? .longerTerm : .shortTerm)) }
        settlePreview()
        precondition(previewWindow.frame == CornerLayout.previewFrame(anchor: anchor, contentHeight: 2000, visibleFrame: screen), "Long preview uses the increased screen-safe cap")
        precondition(scroll.documentView!.frame.height > scroll.contentView.bounds.height, "Long list scrolls")
        let document = scroll.documentView!
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
        settlePreview()
        precondition(scroll.contentView.bounds.maxY >= document.bounds.maxY - 1, "Scrolling reaches the end beyond task fifteen and into Longer term")
        try snapshot("fifty-tasks-end")
        if ProcessInfo.processInfo.environment["BIST_PREVIEW_EVIDENCE"] != nil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
            try snapshot("fifty-tasks-idle")
        }
        for task in previewStore.tasks { precondition(previewStore.complete(id: task.id)) }
        settlePreview()
        precondition(previewWindow.frame.height == 50, "Completing tasks shrinks the preview back to empty")
        precondition(!previewWindow.canBecomeKey && !previewWindow.canBecomeMain, "Scrolling preview remains passive")
        preview.cancel()
        print("PASS: native preview content fitting, 720-point cap, full-list scrolling, overlay style, and completion shrink")
        print("PASS: native logo tracking bounds, stable area, expanded enter/body exit/reentry/window exit, compact hover, teardown")
    }
}
