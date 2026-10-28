import AppKit
import SwiftUI

/// Mount the production checklist, cross a real scheduled deadline, and reopen
/// through the model without remounting the view or modifying personal data.
@main
struct CompletionRetentionTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-retention-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let task = TaskItem(title: "Finish the draft", completed: true, completedAt: now.addingTimeInterval(-86400 + 5))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BistSnapshot(tasks: [task])).write(to: directory.appendingPathComponent("state.json"))
        let store = AppStore(directory: directory)
        let state = ChecklistViewState()
        let host = NSHostingView(rootView: ChecklistPane(store: store, openTask: { _ in }, focusRequest: 0,
                                                        reducedMotion: true, viewState: state)
            .environmentObject(BistFocusContext()).foregroundColor(ink).frame(width: 360, height: 500).background(ivory))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        @discardableResult func snapshot(_ name: String) throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/bist-retention-\(name).png"))
            return bitmap
        }
        func checkedPixels(_ bitmap: NSBitmapImageRep) -> Int {
            let scale = CGFloat(bitmap.pixelsWide) / 360
            var count = 0
            for y in Int(90 * scale)..<Int(112 * scale) {
                for x in Int(34 * scale)..<Int(54 * scale) {
                    let c = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if c.redComponent - c.greenComponent > 0.2 && c.redComponent - c.blueComponent > 0.25 { count += 1 }
                }
            }
            return count
        }
        pump(0.4)
        let originalBytes = try Data(contentsOf: store.stateURL)
        let checked = try snapshot("checked")
        precondition(checkedPixels(checked) > 20, "Recently completed checked row actually renders")
        pump(5)
        let expired = try snapshot("expired")
        precondition(checkedPixels(expired) == 0, "Mounted checklist removes checked row at deadline without another edit")
        let expiredBytes = try Data(contentsOf: store.stateURL)
        precondition(expiredBytes == originalBytes, "Archive transition never rewrites persisted data")
        state.showHistory = true
        pump(0.3)
        precondition(store.completedHistory.map(\.id) == [task.id], "Expired task enters archive")
        try snapshot("archive")
        precondition(store.setUserCompletion(id: task.id, completed: false), "Reopen succeeds")
        state.showHistory = false
        pump(0.3)
        try snapshot("reopened")
        precondition(store.setUserCompletion(id: task.id, completed: true), "Complete again")
        pump(0.3)
        let recompleted = try snapshot("recompleted")
        precondition(checkedPixels(recompleted) > 20, "New checked row renders after an earlier deadline has passed")
        precondition(store.completedHistory.isEmpty, "Recompletion starts a fresh retention window")
        print("PASS: native retained row, scheduled expiry, archive, reopen and recompletion")
    }
}
