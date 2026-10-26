import SwiftUI

/// bist's monochrome vector mark. State changes are brief and user-driven.
struct BistFace: View {
    var size: CGFloat = 24
    var isHovered = false
    var isExpanded = false
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var response: CGFloat { isExpanded ? 1 : (isHovered ? 0.55 : 0) }
    private var motion: Animation? {
        reduceMotion || systemReduceMotion ? nil : .easeOut(duration: 0.16)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 6.5 / 24, style: .circular)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 6.5 / 24, style: .circular)
                        .strokeBorder(Color.black, lineWidth: max(1.4, size * 2.15 / 24))
                }
                .padding(size * 1.5 / 24)

            FaceFeatures(response: response)
                .stroke(Color.black, style: StrokeStyle(lineWidth: max(1.5, size * 2.3 / 24), lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .animation(motion, value: isHovered)
        .animation(motion, value: isExpanded)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Chunky short eyes and an off-center smile remain readable at 16 points.
private struct FaceFeatures: Shape {
    var response: CGFloat
    var animatableData: CGFloat {
        get { response }
        set { response = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let offset = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
        }
        var path = Path()
        let eyeTop = 8.7 - response * 0.15
        let eyeBottom = 10.1 + response * 0.1
        for x: CGFloat in [8.7, 15.3] {
            path.move(to: point(x + response * 0.2, eyeTop))
            path.addLine(to: point(x + response * 0.2, eyeBottom))
        }
        path.move(to: point(9.2, 14.9 - response * 0.2))
        path.addLine(to: point(10.7, 15.8 + response * 0.3))
        path.addLine(to: point(13.0, 15.8 + response * 0.3))
        path.addLine(to: point(14.8, 14.5 - response * 0.4))
        return path
    }
}
