import Foundation
import CoreGraphics

@main
struct PanelMotionTests {
    static func main() {
        let compact = CGRect(x: 936, y: 736, width: 48, height: 48)
        let expanded = CGRect(x: 624, y: 224, width: 360, height: 560)
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        for (start, target) in [(compact, expanded), (expanded, compact)] {
            expect(PanelMotion.frame(from: start, to: target, progress: -1) == start, "Clamps before start")
            expect(PanelMotion.frame(from: start, to: target, progress: 2) == target, "Clamps after end")
            for step in 0...100 {
                let frame = PanelMotion.frame(from: start, to: target, progress: Double(step) / 100)
                expect(abs(frame.maxX - target.maxX) < 0.0001, "Right anchor remains fixed")
                expect(abs(frame.maxY - target.maxY) < 0.0001, "Top anchor remains fixed")
                expect(frame.width >= 48 && frame.width <= 360, "Width never overshoots")
                expect(frame.height >= 48 && frame.height <= 560, "Height never overshoots")
                let interrupted = PanelMotion.frame(from: frame, to: start, progress: 0)
                expect(interrupted == frame, "Reversal resumes at current geometry")
            }
        }
        let bottomLeft = CGRect(x: 0, y: 0, width: 48, height: 48)
        let clampedOpen = CGRect(x: 0, y: 0, width: 360, height: 560)
        for (start, target) in [(bottomLeft, clampedOpen), (clampedOpen, bottomLeft),
                                (CGRect(x: -1200, y: -900, width: 48, height: 48), expanded)] {
            expect(PanelMotion.frame(from: start, to: target, progress: 0) == start, "Different anchors never jump at start")
            expect(PanelMotion.frame(from: start, to: target, progress: 1) == target, "Different anchors finish exactly")
            for step in 0...100 {
                let t = Double(step) / 100
                let frame = PanelMotion.frame(from: start, to: target, progress: t)
                expect(frame.minX >= min(start.minX, target.minX) && frame.minX <= max(start.minX, target.minX), "Origin never overshoots")
                expect(frame.minY >= min(start.minY, target.minY) && frame.minY <= max(start.minY, target.minY), "Vertical origin never overshoots")
                expect(PanelMotion.frame(from: frame, to: start, progress: 0) == frame, "Interrupted clamped transition starts at current frame")
            }
        }
        expect(PanelMotion.fraction(0.1) > 0.3, "Reveal responds promptly with the compositor ease-out curve")
        expect(1 - PanelMotion.fraction(0.999) < 0.0000001, "Reveal settles softly")
        print("PASS: \(checks) panel motion checks")
    }
}
