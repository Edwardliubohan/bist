import AppKit

/// Visual QA without Screen Recording permission. Set BIST_SNAPSHOT_DIR to write
/// the panel's own rendering to panel.png every second. Off by default.
enum QASnapshot {
    static func start(_ window: @escaping () -> NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["BIST_SNAPSHOT_DIR"] else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent("panel.png")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard let window = window(), window.isVisible, let view = window.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file, options: .atomic)
        }
    }
}
