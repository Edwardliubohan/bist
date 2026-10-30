import AppKit
import SwiftUI

@main struct AppearanceTests {
    static func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
        var result: NSColor!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)!
        }
        return result
    }
    static func luminance(_ color: NSColor) -> Double {
        func linear(_ n: Double) -> Double { n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        let dark = resolved(ivory, .darkAqua)
        precondition(luminance(dark) < 0.08, "Dark appearance must use a dark panel surface")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let background = resolved(ivory, name)
            for color in [ink, muted, accent] {
                precondition(contrast(resolved(color, name), background) >= 4.5, "Text must remain readable in both appearances")
            }
        }
        let suite = "bist.appearance-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); NSApp.appearance = nil }
        let state = PanelState(preferences: preferences)
        precondition(state.appearanceMode == .system, "Existing users follow macOS by default")
        state.appearanceMode = .dark
        precondition(NSApp.appearance?.name == .darkAqua, "Changing theme updates native windows immediately")
        precondition(PanelState(preferences: preferences).appearanceMode == .dark, "Theme survives a fresh state")
        state.resetAppearance()
        precondition(state.appearanceMode == .system && NSApp.appearance == nil, "Reset restores live system appearance")
        preferences.set("unknown", forKey: "panelAppearance")
        precondition(PanelState(preferences: preferences).appearanceMode == .system, "Unknown preference falls back safely")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-appearance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory, demo: true)
        let panel = FloatingPanel(contentRect: CGRect(x: 100, y: 100, width: 360, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.orderOut(nil) }
        state.reduced = true
        let host = GlassHostingView(rootView: BistView(store: store, state: state, directory: directory))
        host.sizingOptions = []
        let surface = PanelTransitionSurface(host: host)
        panel.contentView = surface
        state.expanded = true; state.reveal = 1
        surface.settle(rect: CGRect(origin: .zero, size: panel.frame.size), contentSize: panel.frame.size)
        panel.orderFrontRegardless()
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35)) }
        func capture(_ name: String) {
            guard let path = ProcessInfo.processInfo.environment["BIST_APPEARANCE_SNAPSHOTS"] else { return }
            host.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
            let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
            surface.cacheDisplay(in: surface.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        for mode in [BistAppearance.dark, .light, .dark] {
            state.appearanceMode = mode
            surface.updateAppearance(transparency: 0.5, opaque: false)
            pump()
            let expected = mode == .dark ? NSAppearance.Name.darkAqua : .aqua
            precondition(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "Native panel follows the selected theme")
            precondition(surface.nativeBackdrop.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "Native glass inherits the theme")
            let tint = NSColor(cgColor: surface.nativeTint!)!.usingColorSpace(.sRGB)!
            precondition(abs(tint.redComponent - resolved(ivory, expected).redComponent) < 0.01, "Compositor tint refreshes after every switch")
            precondition(abs(tint.alphaComponent - 0.53) < 0.01, "Theme switching preserves transparency")
            surface.updateAppearance(transparency: 1, opaque: true)
            precondition(surface.nativeBackdrop.isHidden && surface.tintOpacity == 1, "Solid and Reduce Transparency behavior survives switching")
            capture(mode.rawValue + "-tasks")
            state.showSettings = true; pump(); capture(mode.rawValue + "-settings")
            state.showSettings = false
            state.selectTab(2); pump(); capture(mode.rawValue + "-note")
            state.selectTab(0); pump()
        }
        // With no app override, native windows must continue to inherit their
        // parent appearance rather than pinning either the host or material.
        state.appearanceMode = .system
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: name); pump()
            let tint = NSColor(cgColor: surface.nativeTint!)!.usingColorSpace(.sRGB)!
            precondition(abs(tint.redComponent - resolved(ivory, name).redComponent) < 0.01, "System appearance changes refresh existing compositor layers")
        }
        print("Appearance checks passed, palette contrast, live switching, native glass, persistence, reset and system inheritance")
    }
}
