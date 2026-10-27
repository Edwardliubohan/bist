import Foundation
import CoreGraphics

enum PanelMotion {
    static let duration: TimeInterval = 0.22
    static let curve = (x1: 0.23, y1: 1.0, x2: 0.32, y2: 1.0)

    static func fraction(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        // Match CAMediaTimingFunction and SwiftUI's content fade exactly.
        func bezier(_ x: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - x) * (1 - x) * x * a + 3 * (1 - x) * x * x * b + x * x * x
        }
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let middle = (low + high) / 2
            if bezier(middle, curve.x1, curve.x2) < t { low = middle } else { high = middle }
        }
        if t == 0 || t == 1 { return t }
        return bezier((low + high) / 2, curve.y1, curve.y2)
    }

    static func frame(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let t = fraction(progress)
        return CGRect(x: start.minX + (target.minX - start.minX) * t,
                      y: start.minY + (target.minY - start.minY) * t,
                      width: start.width + (target.width - start.width) * t,
                      height: start.height + (target.height - start.height) * t)
    }
}
