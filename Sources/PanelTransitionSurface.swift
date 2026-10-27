import AppKit
import QuartzCore

/// SwiftUI always lays out at the final reading size. Only compositor paths and
/// layer positions move; the native window changes size at transition boundaries.
@MainActor
final class PanelTransitionSurface: NSView {
    let host: NSView
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private(set) var tintOpacity: Double = 1
    private(set) var isGlassEnabled = false
    private let content = NSView()
    private let clip = CAShapeLayer()
    private let backdropClip = CAShapeLayer()
    private let border = CAShapeLayer()
    private var modelRect = CGRect.zero
    private var flight: (from: CGRect, to: CGRect, start: CFTimeInterval, duration: TimeInterval)?
    private(set) var contentSize = CornerLayout.expandedSize

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Keep desktop sampling outside the content's compositing mask.
        // Content and backdrop use separate, synchronized reveal paths.
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.mask = clip
        content.autoresizingMask = [.width, .height]
        border.fillColor = NSColor.clear.cgColor
        border.strokeColor = NSColor.white.withAlphaComponent(0.72).cgColor
        border.lineWidth = 1
        // Keep the backdrop outside NSHostingView's compositing hierarchy so it
        // samples the desktop rather than an opaque SwiftUI backing surface.
        material.wantsLayer = true
        material.layer?.cornerRadius = CornerLayout.cornerRadius
        material.layer?.masksToBounds = true
        material.blendingMode = .behindWindow
        material.material = .underWindowBackground
        material.state = .active
        // Native materials carry their own tint. Leave a genuine transparent
        // component too, rather than relying on the system's material opacity.
        material.alphaValue = 0.8
        material.appearance = NSAppearance(named: .aqua)
        material.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        addSubview(material)
        addSubview(content)
        content.addSubview(tint)
        updateAppearance(transparency: 0, opaque: false)
        host.wantsLayer = true
        host.autoresizingMask = []
        content.addSubview(host)
        layer?.addSublayer(border)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateAppearance(transparency: Double, opaque: Bool) {
        let amount = min(1, max(0, transparency))
        isGlassEnabled = !opaque && amount > 0
        tintOpacity = opaque ? 1 : 1 - 0.94 * amount
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        material.isHidden = !isGlassEnabled
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.99, green: 0.97, blue: 0.94, alpha: tintOpacity).cgColor
        CATransaction.commit()
    }

    var presentationRect: CGRect {
        guard let flight else { return modelRect }
        if let path = clip.presentation()?.path { return path.boundingBoxOfPath }
        // Hidden panels and same-run-loop reversals may not yet have a
        // presentation layer. The identical curve supplies a safe fallback.
        return PanelMotion.frame(from: flight.from, to: flight.to,
                                 progress: (CACurrentMediaTime() - flight.start) / flight.duration)
    }

    #if BIST_TESTING
    var nativeBackdrop: NSVisualEffectView { material }
    var hasAnimatedPresentation: Bool { clip.presentation()?.path != nil && clip.animation(forKey: "panel.clip") != nil }
    #endif

    private func contentFrame(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - contentSize.width, y: rect.maxY - contentSize.height,
               width: contentSize.width, height: contentSize.height)
    }
    private func path(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: CornerLayout.cornerRadius,
               cornerHeight: CornerLayout.cornerRadius, transform: nil)
    }
    private func borderPath(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: CornerLayout.cornerRadius - 0.5,
               cornerHeight: CornerLayout.cornerRadius - 0.5, transform: nil)
    }

    func settle(rect: CGRect, contentSize: CGSize) {
        flight = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.removeAllAnimations(); backdropClip.removeAllAnimations(); border.removeAllAnimations(); host.layer?.removeAnimation(forKey: "panel.position")
        self.contentSize = contentSize
        modelRect = rect
        content.frame = bounds
        material.frame = bounds
        backdropClip.frame = bounds
        // At rest, use AppKit's native rounded backdrop directly. A custom
        // backdrop mask is needed only while its visible outline is changing.
        material.layer?.mask = rect == bounds ? nil : backdropClip
        tint.frame = bounds
        clip.frame = bounds
        border.frame = bounds
        host.frame = contentFrame(for: rect)
        clip.path = path(rect)
        backdropClip.path = path(rect)
        border.path = borderPath(rect)
        CATransaction.commit()
        host.layoutSubtreeIfNeeded()
    }

    func animate(from start: CGRect, to target: CGRect, contentSize: CGSize,
                 duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        settle(rect: start, contentSize: contentSize)
        let oldPosition = host.layer!.position
        flight = (start, target, CACurrentMediaTime(), duration)
        modelRect = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            Task { @MainActor in completion() }
        }
        material.layer?.mask = backdropClip
        host.frame = contentFrame(for: target)
        clip.path = path(target)
        backdropClip.path = path(target)
        border.path = borderPath(target)
        let curve = PanelMotion.curve
        let timing = CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
        func animate(_ layer: CALayer, keyPath: String, from: Any, to: Any, key: String) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from; animation.toValue = to
            animation.duration = duration; animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        animate(clip, keyPath: "path", from: path(start), to: path(target), key: "panel.clip")
        animate(backdropClip, keyPath: "path", from: path(start), to: path(target), key: "panel.backdrop")
        animate(border, keyPath: "path", from: borderPath(start), to: borderPath(target), key: "panel.border")
        if oldPosition != host.layer!.position {
            animate(host.layer!, keyPath: "position", from: NSValue(point: oldPosition),
                    to: NSValue(point: host.layer!.position), key: "panel.position")
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard path(presentationRect).contains(point) else { return nil }
        return super.hitTest(point)
    }
}
