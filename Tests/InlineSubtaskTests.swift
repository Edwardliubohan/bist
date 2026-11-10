import AppKit
import SwiftUI

/// Mount the production checklist, open the inline subtask field from a row,
/// and type real text through the native field editor, pressing Return twice.
@main
struct InlineSubtaskTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-inline-subtask-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        precondition(store.addTask(title: "Plan the trip") && store.addTask(title: "Water plants"), "Seed tasks")
        let parentID = store.tasks[0].id
        let state = ChecklistViewState()
        let host = NSHostingView(rootView: ChecklistPane(store: store, openTask: { _ in }, focusRequest: 0,
                                                        reducedMotion: true, viewState: state)
            .environmentObject(BistFocusContext()).environmentObject(BobotStore(directory: directory)).foregroundColor(ink).frame(width: 360, height: 500).background(ivory))
        let window = KeyableWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 500),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func editor() -> NSTextView? { window.firstResponder as? NSTextView }
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("bist-inline-subtask-\(name).png"))
        }

        pump(0.4)
        state.inlineSubtaskParentID = parentID
        pump(0.4)
        precondition(editor() != nil, "Opening the inline field focuses it")
        for title in ["Book flights", "Pack bags"] {
            editor()!.insertText(title, replacementRange: NSRange(location: NSNotFound, length: 0))
            editor()!.insertNewline(nil)
            pump(0.4)
            precondition(store.tasks.contains { $0.title == title && $0.parentID == parentID }, "Return adds \(title) under the parent")
            precondition(state.inlineSubtaskParentID == parentID && editor() != nil, "Field stays open and focused after adding \(title)")
        }
        let order = ActiveChecklist(tasks: store.tasks, collapsedParents: []).entries(for: .shortTerm).map(\.task.title)
        precondition(order == ["Plan the trip", "Book flights", "Pack bags", "Water plants"], "Subtasks appear in entry order: \(order)")
        try snapshot("open")

        window.makeFirstResponder(nil)
        pump(0.4)
        precondition(state.inlineSubtaskParentID == nil, "Leaving the empty field closes it")
        print("PASS: inline subtask field focuses, adds on Return, stays open for the next subtask, and closes when left empty")
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
