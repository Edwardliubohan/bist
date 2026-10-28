import AppKit
import SwiftUI

/// Exercise the real Swift queue -> stdio MCP tools -> native popup -> answer -> result.
/// Fake agent messages only: no OpenAI calls, subscriptions or user data.
@main
struct BobotFlowTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-bobot-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        precondition(store.addTask(title: "Compare the two venue proposals", details: "Compare price and accessibility. Prepare a recommendation for review."))
        let bobot = BobotStore(directory: directory)
        precondition(bobot.assign(store.tasks[0]))
        let id = bobot.jobs[0].id, claim = UUID().uuidString.lowercased()
        func tool(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "scripts/bist-bobot.py", "--data-dir", directory.path]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            var bytes = try JSONSerialization.data(withJSONObject: request); bytes.append(10)
            try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let rpc = try JSONSerialization.jsonObject(with: response) as! [String: Any]
            let result = rpc["result"] as! [String: Any]
            precondition(result["isError"] as? Bool != true, "MCP tool succeeded")
            let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        }
        let claimed = try tool("claim_job", ["job_id": id, "claim_id": claim])
        _ = try tool("update_job", ["job_id": id, "claim_id": claim, "execution_id": claim, "revision": claimed["revision"]!, "state": "waiting", "message": "Should I prioritize the lower price, or step-free access for every guest?"])
        bobot.refresh()
        precondition(bobot.pending.count == 1)

        let preferences = UserDefaults(suiteName: "bist.bobot-flow.\(UUID())")!
        let state = PanelState(preferences: preferences)
        let panel = FloatingPanel(contentRect: CGRect(x: 50, y: 50, width: 360, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = GlassHostingView(rootView: BistView(store: store, state: state, directory: directory))
        host.sizingOptions = []
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let surface = PanelTransitionSurface(host: host)
        panel.contentView = surface
        surface.frame = CGRect(origin: .zero, size: panel.frame.size)
        surface.settle(rect: surface.bounds, contentSize: surface.bounds.size)
        state.resize = { expanded, _ in state.reveal = expanded ? 1 : 0 }
        panel.orderFrontRegardless()
        func pump(_ seconds: Double = 0.2) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        pump(0.7)
        precondition(state.expanded, "Incoming question expands collapsed panel")
        precondition(panel.attachedSheet != nil, "Incoming question opens a native sheet")
        func snapshot(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/bobot-\(name).png"))
        }
        func expectTransparentCorners(_ name: String) throws {
            // Capture the native frame, including AppKit's sibling sheet dimmer,
            // rather than just the already-masked SwiftUI content surface.
            let frame = panel.contentView!.superview!
            let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            for x in [1, bitmap.pixelsWide - 2] {
                for y in [1, bitmap.pixelsHigh - 2] {
                    precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                                 "Native panel corners stay transparent \(name)")
                }
            }
            precondition(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.9,
                         "Panel interior remains visible")
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/bobot-\(name).png"))
        }
        try expectTransparentCorners("sheet-parent")
        surface.updateAppearance(transparency: 0.75, opaque: false)
        try expectTransparentCorners("sheet-glass")
        surface.updateAppearance(transparency: 0, opaque: true)
        try snapshot(panel.attachedSheet!.contentView!, "question")
        let sheet = panel.attachedSheet!
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        let input = editors(sheet.contentView!).first!
        input.string = "Prioritize step-free access."
        input.didChangeText()
        pump()
        // Route a real AppKit click through this test's own sheet, without global input.
        let point = sheet.contentView!.convert(NSPoint(x: 240, y: sheet.contentView!.isFlipped ? sheet.contentView!.bounds.height - 33 : 33), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            sheet.sendEvent(event)
        }
        pump()
        let ready = try tool("read_job", ["job_id": id])
        precondition(ready["state"] as? String == "ready", "MCP sees persisted native answer")
        precondition(panel.attachedSheet == nil, "Submitting the answer dismisses the sheet")
        try expectTransparentCorners("sheet-dismissed")
        let execution = UUID().uuidString.lowercased()
        let resumed = try tool("resume_job", ["job_id": id, "claim_id": claim, "execution_id": execution, "answer_revision": ready["revision"]!])
        bobot.refresh()
        let checklist = GlassHostingView(rootView: ChecklistPane(store: store, openTask: { _ in }, focusRequest: 0,
            reducedMotion: true, viewState: ChecklistViewState())
            .foregroundColor(ink).frame(width: 360, height: 560).background(ivory)
            .environmentObject(BistFocusContext()).environmentObject(bobot))
        panel.contentView = checklist; pump()
        try snapshot(checklist, "agent-working")
        let done = try tool("update_job", ["job_id": id, "claim_id": claim, "execution_id": execution, "revision": resumed["revision"]!, "state": "completed", "message": "Venue B has step-free access for every guest and costs $200 more. I recommend Venue B.", "result_url": "https://example.com/recommendation"])
        precondition(done["state"] as? String == "completed")
        let reopened = BobotStore(directory: directory)
        precondition(reopened.jobs[0].result?.contains("Venue B") == true && !store.tasks[0].completed)
        precondition(reopened.agentCompletionStatus(for: store.tasks[0]).done,
                     "Persisted MCP completion checks Agent before user review")
        bobot.refresh(); pump()
        try snapshot(checklist, "agent-done")
        let mePoint = checklist.convert(NSPoint(x: 43, y: checklist.isFlipped ? 100 : checklist.bounds.height - 100), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: mePoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            panel.sendEvent(event)
        }
        precondition(store.tasks[0].completed, "Native Me checkbox independently completes personal work")
        pump()
        try snapshot(checklist, "both-done")
        precondition(AppStore(directory: directory).tasks[0].completed &&
                     BobotStore(directory: directory).agentCompletionStatus(for: store.tasks[0]).done,
                     "Both independent checkmarks survive reopening")
        if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
        let focus = BistFocusContext()
        let browser = SessionBrowserState()
        let sessions = LocalSessionConnection(scan: LocalSessionScan(messages: [.codex: "No local sessions"]))
        let list = GlassHostingView(rootView: SessionsPane(store: store, connection: sessions, browser: browser, active: false, addLink: {})
            .padding(.top, 14).frame(width: 360, height: 560).background(ivory).environmentObject(focus).environmentObject(reopened))
        panel.contentView = list; pump()
        try snapshot(list, "sessions")
        let detail = GlassHostingView(rootView: BobotJobDetail(job: reopened.jobs[0], bobot: reopened)
            .padding(20).frame(width: 360, height: 560).background(ivory).environmentObject(focus))
        panel.contentView = detail; pump()
        try snapshot(detail, "result")
        panel.orderOut(nil)
        print("PASS: Swift assignment -> real stdio MCP claim/question -> collapsed native popup -> Swift answer -> MCP result -> persisted Sessions; native captures saved")
    }
}
