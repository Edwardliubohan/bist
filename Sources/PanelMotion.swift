import Foundation
import CoreGraphics

enum PanelMotion {
    static let duration: TimeInterval = 0.28

    static func fraction(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func frame(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let t = fraction(progress)
        return CGRect(x: start.minX + (target.minX - start.minX) * t,
                      y: start.minY + (target.minY - start.minY) * t,
                      width: start.width + (target.width - start.width) * t,
                      height: start.height + (target.height - start.height) * t)
    }
}
