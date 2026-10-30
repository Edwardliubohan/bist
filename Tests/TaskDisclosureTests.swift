import AppKit
import SwiftUI

/// Collapsing a group near the bottom must release scroll space gradually.
@main
struct TaskDisclosureTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-disclosure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        for index in 0..<12 { precondition(store.addTask(title: "Task \(index)")) }
        let parent = store.tasks.last!.id
        for index in 0..<4 { precondition(store.addTask(title: "Child \(index)", parentID: parent)) }
        precondition(store.addTask(title: "Later", horizon: .longerTerm))
        let state = ChecklistViewState()
        let focus = BistFocusContext()
        let bobot = BobotStore(directory: directory)
        func root(reduced: Bool) -> some View {
            ChecklistPane(store: store, openTask: { _ in }, focusRequest: 0,
                          reducedMotion: reduced, viewState: state)
                .environmentObject(focus).environmentObject(bobot)
        }
        let host = NSHostingView(rootView: root(reduced: false))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 440),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func capture(_ name: String) {
            guard let path = ProcessInfo.processInfo.environment["BIST_DISCLOSURE_SNAPSHOT_DIR"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = URL(fileURLWithPath: path).appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
        pump(0.5)
        let scroll = descendants(host).compactMap { $0 as? NSScrollView }.first!
        let document = scroll.documentView!
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        pump(0.1)
        let start = document.frame.height
        let startOffset = scroll.contentView.bounds.minY
        capture("collapse-00")
        state.collapsedParents.insert(parent)
        var heights: [CGFloat] = []
        var offsets: [CGFloat] = []
        var sampleTimes = [Date.timeIntervalSinceReferenceDate]
        for frame in 1...24 {
            pump(1.0 / 60)
            heights.append(document.frame.height)
            offsets.append(scroll.contentView.bounds.minY)
            sampleTimes.append(Date.timeIntervalSinceReferenceDate)
            if [4, 8, 12, 18, 24].contains(frame) { capture(String(format: "collapse-%02d", frame)) }
        }
        pump(0.3)
        let end = document.frame.height
        print("Disclosure heights \(start) → \(heights) → \(end)")
        print("Disclosure offsets \(startOffset) → \(offsets)")
        precondition(start - end > 100, "Fixture collapses four rows in an overflowing list")
        let intermediate = heights.filter { $0 > end + 2 && $0 < start - 2 }
        precondition(intermediate.count >= 5, "Collapse must retain intermediate document heights, not remove scroll space immediately")
        let deltas = zip([startOffset] + offsets, offsets).map { abs($0 - $1) }
        // Capture/encoding or machine load can delay a sample beyond one display frame.
        let intervals = zip(sampleTimes, sampleTimes.dropFirst()).map { $1 - $0 }
        let frameSteps = zip(deltas, intervals).map { $0 / max(1, $1 * 60) }
        precondition((frameSteps.max() ?? 0) < 50, "Collapse must not jump the bottom scroll position in one frame")

        // Expansion must also grow the real document rather than jump to its end size.
        state.collapsedParents.remove(parent)
        var expanding: [CGFloat] = []
        for _ in 0..<24 { pump(1.0 / 60); expanding.append(document.frame.height) }
        pump(0.3)
        precondition(abs(document.frame.height - start) < 1, "Expansion restores the full group")
        precondition(expanding.filter { $0 > end + 2 && $0 < start - 2 }.count >= 5,
                     "Expansion grows scroll space gradually")

        // Retarget the in-flight height without a delayed removal hiding reopened children.
        state.collapsedParents.insert(parent); pump(0.08)
        state.collapsedParents.remove(parent); pump(0.06)
        state.collapsedParents.insert(parent); pump(0.06)
        state.collapsedParents.remove(parent); pump(0.7)
        precondition(abs(document.frame.height - start) < 1, "Rapid reversals settle at the latest expanded state")

        host.rootView = root(reduced: true)
        pump(0.1)
        state.collapsedParents.insert(parent); pump(0.05)
        precondition(abs(document.frame.height - end) < 1, "Reduced motion collapses immediately")
        state.collapsedParents.remove(parent); pump(0.05)
        precondition(abs(document.frame.height - start) < 1, "Reduced motion expands immediately")
        print("PASS: native disclosure retains scroll space, expands gradually, reverses safely and respects reduced motion")
    }
}
