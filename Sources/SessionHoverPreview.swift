import AppKit
import SwiftUI
import QuartzCore

private final class SessionPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct SessionHoverPreview: NSViewRepresentable {
    let session: LocalAgentSession
    let enabled: Bool
    let reduced: Bool
    func makeNSView(context: Context) -> SessionHoverAnchor { SessionHoverAnchor() }
    func updateNSView(_ view: SessionHoverAnchor, context: Context) {
        view.session = session; view.reduced = reduced
        if !enabled { view.dismiss() }
        view.enabled = enabled
    }
    static func dismantleNSView(_ view: SessionHoverAnchor, coordinator: ()) { view.shutdown() }
}

/// The native tracking area only responds to a real mouse. It never takes focus.
final class SessionHoverAnchor: NSView {
    var session: LocalAgentSession?
    var enabled = true
    var reduced = false
    private var pending: DispatchWorkItem?
    private var preview: SessionPreviewPanel?
    private var tracking: NSTrackingArea?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        if let window {
            for name in [NSWindow.willMoveNotification, NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.dismiss() })
            }
        } else { shutdown() }
    }
    deinit {
        pending?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.show() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    override func mouseExited(with event: NSEvent) { dismiss() }

    static func frame(anchor: CGRect, parent: CGRect, screen: CGRect) -> CGRect {
        let width = min(310, max(1, screen.width - 24)), height = min(260, max(1, screen.height - 24))
        let left = parent.minX - width - 12
        let proposed = left >= screen.minX + 12 ? left : parent.maxX + 12
        return CGRect(x: min(max(screen.minX + 12, proposed), screen.maxX - width - 12),
                      y: min(max(screen.minY + 12, anchor.maxY - height), screen.maxY - height - 12), width: width, height: height)
    }
    func show(verifyPointer: Bool = true) {
        guard enabled, let session, let window, !visibleRect.isEmpty, window.isVisible else { return }
        let anchor = window.convertToScreen(convert(visibleRect, to: nil))
        // Do not reveal if a delayed callback survived scrolling away from the row.
        guard !verifyPointer || anchor.contains(NSEvent.mouseLocation) else { return }
        generation += 1
        let panel = preview ?? SessionPreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        preview = panel
        panel.title = "bist session preview"
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        let host = NSHostingView(rootView: SessionPreviewContent(session: session))
        host.sizingOptions = []; host.wantsLayer = true
        panel.contentView = host
        let screen = window.screen?.visibleFrame ?? window.frame
        panel.setFrame(Self.frame(anchor: anchor, parent: window.frame, screen: screen), display: true)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        animate(visible: true)
    }
    func shutdown() {
        pending?.cancel(); pending = nil; generation += 1
        if let panel = preview {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
    func dismiss() {
        pending?.cancel(); pending = nil
        generation += 1
        guard let panel = preview, panel.isVisible else { return }
        let token = generation
        animate(visible: false) { [weak self, weak panel] in
            guard let self, self.generation == token, let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
    private func animate(visible: Bool, completion: (() -> Void)? = nil) {
        guard let panel = preview else { return }
        let duration = 0.16
        if let layer = panel.contentView?.layer {
            let target = CATransform3DMakeTranslation(visible || reduced ? 0 : 4, 0, 0)
            let current = layer.presentation()?.transform ?? (visible && !reduced ? CATransform3DMakeTranslation(4, 0, 0) : layer.transform)
            layer.removeAnimation(forKey: "session-reveal")
            layer.transform = target
            if !reduced {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = NSValue(caTransform3D: current)
                animation.toValue = NSValue(caTransform3D: target)
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(controlPoints: Float(PanelMotion.curve.x1), Float(PanelMotion.curve.y1), Float(PanelMotion.curve.x2), Float(PanelMotion.curve.y2))
                layer.add(animation, forKey: "session-reveal")
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(PanelMotion.curve.x1), Float(PanelMotion.curve.y1), Float(PanelMotion.curve.x2), Float(PanelMotion.curve.y2))
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { completion?() }
    }
}

struct SessionPreviewContent: View {
    let session: LocalAgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if session.awaitingReply { Image(systemName: "questionmark.circle.fill").foregroundColor(accent) }
                Text(session.awaitingReply ? "Needs your reply" : session.externalRunning ? "Running" : "Latest update")
                    .foregroundColor(session.awaitingReply ? accent : session.externalRunning ? ink : muted)
                Spacer()
                Text(SessionText.age(session.modifiedAt)).monospacedDigit().foregroundColor(muted)
            }.font(.system(size: 11, weight: .medium))
            Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
            Text("\(session.meta) · \((session.directory as NSString).abbreviatingWithTildeInPath)")
                .font(.system(size: 11)).foregroundStyle(muted).lineLimit(2).truncationMode(.middle)
            Divider()
            Text(SessionText.plain(session.question ?? (session.preview.isEmpty ? session.activity : session.preview)))
                .font(.system(size: 12)).lineSpacing(2).lineLimit(7)
            Spacer(minLength: 0)
            Text("Click to read and reply").font(.system(size: 11)).foregroundStyle(muted)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(ink).background(ivory)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hairline, lineWidth: 1))
    }
}
