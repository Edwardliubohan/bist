import Foundation
import CoreGraphics

enum PanelMotion {
    static let duration: TimeInterval = 0.24

    static func frame(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let fraction = min(1, max(0, progress))
        let eased = 1 - pow(1 - fraction, 3)
        let width = start.width + (target.width - start.width) * eased
        let height = start.height + (target.height - start.height) * eased
        return CGRect(x: target.maxX - width, y: target.maxY - height, width: width, height: height)
    }
}
