import AppKit
import Foundation
import SwiftUI

@main
struct PersistenceTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--launch-write") || CommandLine.arguments.contains("--launch-read") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let store = delegate.store!
                if CommandLine.arguments.contains("--launch-write") {
                    precondition(store.tasks.isEmpty)
                    precondition(store.addTask(title: "Survives quitting", details: "Saved notes"))
                    precondition(store.addTask(title: "Completed history"))
                    precondition(store.complete(id: store.tasks[1].id))
                    precondition(store.addLabel(name: "Persistent tag", color: .amber))
                    precondition(store.addSession(provider: .codex, title: "Saved bookmark", url: "https://example.com/session"))
                    delegate.savePosition()
                } else {
                    precondition(store.tasks.count == 2 && store.tasks[0].notes == "Saved notes")
                    let completed = store.tasks[1]
                    precondition(completed.completed && completed.completedAt != nil)
                    precondition(store.completedHistory.isEmpty)
                    precondition(ActiveChecklist(tasks: store.tasks, collapsedParents: []).entries(for: .shortTerm).contains { $0.id == completed.id })
                    precondition(store.archivedTasks(at: completed.archiveDate!).map(\.id) == [completed.id])
                    precondition(store.labels.contains { $0.name == "Persistent tag" })
                    precondition(store.sessions.count == 1)
                    precondition(FileManager.default.fileExists(atPath: delegate.positionURL.path))
                    precondition(store.storeError == nil)
                }
                app.terminate(nil)
            }
            app.run()
            return
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bist-persistence-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let canonical = BistDataLocation.directory(environment: [:], home: root)
        expect(canonical.path == root.appendingPathComponent("Library/Application Support/bist").path, "stable regular location")
        expect(BistDataLocation.directory(demo: true, environment: [:], home: root) != canonical, "demo isolation")
        let override = root.appendingPathComponent("explicit")
        expect(BistDataLocation.directory(demo: true, environment: ["BIST_DATA_DIR": override.path], home: root).path == override.path, "explicit demo override")
        let legacy = root.appendingPathComponent("old/.local-data")
        let old = AppStore(directory: legacy)
        expect(old.addTask(title: "Legacy task"), "legacy fixture")
        let original = try Data(contentsOf: old.stateURL)
        for name in ["panel-position.json", "inbox.json", "agent-results.json", "archive/old.json"] {
            let file = legacy.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
        try BistDataLocation.prepare(canonical, legacy: legacy)
        expect(try Data(contentsOf: canonical.appendingPathComponent("state.json")) == original, "migration preserves state bytes")
        expect(try Data(contentsOf: old.stateURL) == original, "original retained")
        for name in ["panel-position.json", "inbox.json", "agent-results.json", "archive/old.json"] {
            expect(try Data(contentsOf: canonical.appendingPathComponent(name)) == Data(name.utf8), "complete directory migration")
        }
        let migrated = AppStore(directory: canonical)
        expect(migrated.tasks.first?.title == "Legacy task", "migrated data loads")
        expect(migrated.addTask(title: "New canonical edit"), "new store edit")
        try BistDataLocation.prepare(canonical, legacy: legacy)
        expect(AppStore(directory: canonical).tasks.count == 2, "repeat migration never overwrites newer data")
        let bad = root.appendingPathComponent("bad-legacy")
        try Data("not a folder".utf8).write(to: bad)
        let failed = root.appendingPathComponent("failed")
        do { try BistDataLocation.prepare(failed, legacy: bad); fatalError("invalid migration accepted") } catch {}
        expect(!fm.fileExists(atPath: failed.path), "failed migration publishes nothing")
        let blockedStore = AppStore(directory: failed, legacyDirectory: bad)
        expect(blockedStore.storeError != nil && !blockedStore.addTask(title: "Blocked"), "failed migration blocks task writes")
        let delegate = AppDelegate()
        delegate.store = blockedStore
        delegate.positionURL = failed.appendingPathComponent("panel-position.json")
        delegate.compactOrigin = CGPoint(x: 20, y: 20)
        delegate.savePosition()
        expect(!fm.fileExists(atPath: failed.path), "drag after failed migration cannot create an empty destination")
        try fm.removeItem(at: bad)
        try fm.copyItem(at: legacy, to: bad)
        expect(blockedStore.reload() && blockedStore.tasks.first?.title == "Legacy task", "repair and reload retries migration")
        delegate.savePosition()
        expect(fm.fileExists(atPath: delegate.positionURL.path), "position saves after successful recovery")
        let malformed = root.appendingPathComponent("malformed-old")
        try fm.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: malformed.appendingPathComponent("state.json"))
        let corrupt = root.appendingPathComponent("corrupt-copy")
        try BistDataLocation.prepare(corrupt, legacy: malformed)
        let corruptStore = AppStore(directory: corrupt)
        expect(corruptStore.storeError != nil && !corruptStore.addTask(title: "No overwrite"), "malformed migration preserved and blocked")

        // Render the settings addition at native panel width; a tall capture shows the scroll content.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let suite = "bist.persistence-ui.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = PanelState(preferences: preferences)
        let settings = BistSettingsView(store: migrated, state: state, close: {}, reviewUpdates: {}, reviewResults: {})
            .background(ivory).preferredColorScheme(.light).environmentObject(state.focusContext)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = GlassHostingView(rootView: settings)
        host.sizingOptions = []
        panel.contentView = host
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/tests/storage-settings.png"))
        }

        // Real AppDelegate launches and normal NSApplication termination, in separate processes.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let moved = root.appendingPathComponent("moved-test-binary")
        try fm.copyItem(at: executable, to: moved)
        let nativeData = root.appendingPathComponent("native-data")
        for (binary, phase, cwd) in [(executable, "--launch-write", root), (moved, "--launch-read", fm.temporaryDirectory)] {
            let process = Process()
            process.executableURL = binary
            process.arguments = [phase]
            var environment = ProcessInfo.processInfo.environment
            environment["BIST_DATA_DIR"] = nativeData.path
            process.environment = environment
            process.currentDirectoryURL = cwd
            try process.run()
            process.waitUntilExit()
            expect(process.terminationStatus == 0, "native quit/reopen from changed cwd and binary location")
        }
        print("PASS: \(checks) storage and native relaunch checks")
    }
}
