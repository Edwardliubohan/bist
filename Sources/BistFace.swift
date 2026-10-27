import SwiftUI

struct BistFace: View {
    var size: CGFloat = 24
    var isHovered = false
    var isExpanded = false
    var reduceMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var motionDisabled: Bool { reduceMotion || systemReduceMotion }
    private var response: Double { !motionDisabled && !isExpanded && isHovered ? 3 : 0 }

    var body: some View {
        ZStack {
            ForEach(0..<2) { index in
                OrbitArc(opposing: index == 1)
                    .stroke(
                        LinearGradient(stops: [
                            .init(color: Color(.sRGB, red: 255 / 255, green: 194 / 255, blue: 138 / 255), location: 0),
                            .init(color: Color(.sRGB, red: 245 / 255, green: 138 / 255, blue: 61 / 255), location: 0.5),
                            .init(color: Color(.sRGB, red: 201 / 255, green: 83 / 255, blue: 27 / 255), location: 1)
                        ], startPoint: UnitPoint(x: 4 / 24, y: 3 / 24), endPoint: UnitPoint(x: 20 / 24, y: 21 / 24)),
                        style: StrokeStyle(lineWidth: size * 4.5 / 24, lineCap: .round, lineJoin: .round)
                    )
                    .rotationEffect(.degrees(index == 0 ? response : -response))
            }
        }
        .frame(width: size, height: size)
        .animation(motionDisabled ? nil : .easeOut(duration: 0.16), value: isHovered)
        .transaction { transaction in
            if motionDisabled || isExpanded {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private struct OrbitArc: Shape {
    var opposing: Bool

    private let controlPoints: [CGPoint] = [
        CGPoint(x: 8.25, y: 5.504809),
        CGPoint(x: 10.570508, y: 4.165064),
        CGPoint(x: 13.429492, y: 4.165064),
        CGPoint(x: 15.75, y: 5.504809),
        CGPoint(x: 18.070508, y: 6.844555),
        CGPoint(x: 19.5, y: 9.320508),
        CGPoint(x: 19.5, y: 12)
    ]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ index: Int) -> CGPoint {
            let source = controlPoints[index]
            let position = opposing ? CGPoint(x: 24 - source.x, y: 24 - source.y) : source
            return CGPoint(x: rect.midX + (position.x - 12) * scale, y: rect.midY + (position.y - 12) * scale)
        }
        var path = Path()
        path.move(to: point(0))
        path.addCurve(to: point(3), control1: point(1), control2: point(2))
        path.addCurve(to: point(6), control1: point(4), control2: point(5))
        return path
    }
}
