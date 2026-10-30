import AppKit
import SwiftUI

/// A nil native appearance follows macOS, including changes while bist is open.
enum BistAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Shared semantic colors resolve in each native window and SwiftUI host.
enum BistPalette {
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static func color(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: adaptive(rgb(light), rgb(dark)))
    }
    private static func rgb(_ value: (Double, Double, Double)) -> NSColor {
        NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
    }
    static let surface = adaptive(rgb((0.99, 0.97, 0.94)), rgb((0.13, 0.115, 0.10)))
    static let border = adaptive(.white, rgb((0.40, 0.35, 0.30)))
    static func category(_ light: NSColor) -> Color {
        Color(nsColor: adaptive(light, light.blended(withFraction: 0.38, of: .white) ?? light))
    }
}
