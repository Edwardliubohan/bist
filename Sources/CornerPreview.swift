import AppKit
import SwiftUI
import Combine

/// Read-only hover surface. It cannot take keyboard focus or activate bist.
private final class ReadOnlyPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Drives the card's grow-out-of-the-icon reveal inside the preview window.
@MainActor
final class PreviewReveal: ObservableObject {
    @Published var shown = false
    @Published var reduced = false
    @Published var origin = CGPoint(x: 1, y: 0)
}

@MainActor
final class PreviewPanelController {
    private let store: AppStore
    private let panel: ReadOnlyPreviewPanel
    private var interaction = HoverPreviewInteraction()
    private var timer: Timer?
    private var pointerTimer: Timer?
    private var observation: AnyCancellable?
    private var anchor = CGRect.zero
    private var visibleFrame: CGRect?
    private var aboveAnchor = false
    private let reveal = PreviewReveal()
    private var presented = false
    private var revealGeneration: UInt64 = 0
    var reducedMotion = false { didSet { reveal.reduced = reducedMotion } }
    var isVisible: Bool { interaction.isVisible }
    var isRevealed: Bool { reveal.shown }
    #if BIST_TESTING
    var testPointer: CGPoint?
    /// Snapshots of preview layout need the settled card without a hover.
    func revealForTesting() {
        var instant = Transaction(); instant.disablesAnimations = true
        withTransaction(instant) { reveal.shown = true }
    }
    private var pointerLocation: CGPoint { testPointer ?? NSEvent.mouseLocation }
    #else
    private var pointerLocation: CGPoint { NSEvent.mouseLocation }
    #endif

    deinit {
        timer?.invalidate()
        pointerTimer?.invalidate()
    }

    init(store: AppStore) {
        self.store = store
        panel = ReadOnlyPreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "bist task preview"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false
        refreshContent()
        observation = store.objectWillChange.sink { [weak self] in
            // Published values become readable after objectWillChange finishes.
            DispatchQueue.main.async { self?.updateGeometry() }
        }
    }

    func cornerHoverChanged(_ inside: Bool) {
        interaction.pointerChanged(.corner, inside: inside, at: ProcessInfo.processInfo.systemUptime)
        reconcile()
    }

    func setExpanded(_ expanded: Bool) {
        interaction.setExpanded(expanded)
        reconcile(animated: false)
    }

    func reposition(anchor: CGRect, visibleFrame: CGRect? = nil) {
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        updateGeometry()
    }

    func cancel() {
        interaction.cancel()
        reconcile(animated: false)
    }

    @discardableResult
    func handleEscape() -> Bool {
        let handled = interaction.escape()
        // An explicit dismissal still shrinks, but re-hovering must wait the full dwell.
        reconcile(reversible: false)
        return handled
    }

    private func previewHoverChanged(_ inside: Bool) {
        interaction.pointerChanged(.preview, inside: inside, at: ProcessInfo.processInfo.systemUptime)
        reconcile()
    }

    private var contentHeight: CGFloat {
        let selection = PreviewTaskSelection(store.tasks, isOutstanding: { !$0.completed }, isShortTerm: { $0.horizon == .shortTerm })
        return selection.contentHeight
    }

    private func updateGeometry() {
        let screen = visibleFrame ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let frame = CornerLayout.previewFrame(anchor: anchor, contentHeight: contentHeight, visibleFrame: screen)
        panel.setFrame(frame, display: true)
        let origin = CornerLayout.previewGrowthOrigin(preview: frame, anchor: anchor)
        if origin != reveal.origin { reveal.origin = origin }
        let above = frame.minY >= anchor.maxY
        if above != aboveAnchor { aboveAnchor = above; refreshContent() }
    }

    private func refreshContent() {
        let host = GlassHostingView(rootView: HoverTaskPreview(store: store, reveal: reveal, aboveAnchor: aboveAnchor, onHover: { [weak self] inside in self?.previewHoverChanged(inside) }))
        // The panel, not SwiftUI's intrinsic content size, owns screen geometry.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        updateGeometry()
    }

    private func reconcile(animated: Bool = true, reversible: Bool = true) {
        timer?.invalidate()
        timer = nil
        // A reversal is due now. Running it here means it cannot lose a race
        // with the shrink's orderOut.
        if let due = interaction.pending, due.deadline <= ProcessInfo.processInfo.systemUptime {
            _ = interaction.advance(at: ProcessInfo.processInfo.systemUptime, generation: due.generation)
        }
        if let pending = interaction.pending {
            let interval = max(0.001, pending.deadline - ProcessInfo.processInfo.systemUptime)
            let token = pending.generation
            let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.samplePointer()
                    _ = self.interaction.advance(at: ProcessInfo.processInfo.systemUptime, generation: token)
                    self.reconcile()
                }
            }
            RunLoop.main.add(next, forMode: .common)
            timer = next
        }
        if interaction.isVisible {
            if !presented { present() }
        } else if presented || (!animated && panel.isVisible) {
            // A running shrink owns its own orderOut. Pointer ticks must not restart it.
            dismiss(animated: animated, reversible: reversible)
        }
        if interaction.needsPointerSampling {
            if pointerTimer == nil {
                let next = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.samplePointer()
                        self.reconcile()
                    }
                }
                RunLoop.main.add(next, forMode: .common)
                pointerTimer = next
            }
        } else {
            pointerTimer?.invalidate()
            pointerTimer = nil
        }
    }

    /// Grows the card out of the corner control. A reveal that interrupts a
    /// running dismissal reverses from the card's current size.
    private func present() {
        presented = true
        interaction.setShrinking(false)
        revealGeneration &+= 1
        let token = revealGeneration
        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            updateGeometry()
            var collapsed = Transaction(); collapsed.disablesAnimations = true
            withTransaction(collapsed) { reveal.shown = false }
            // The window server cannot follow a scaling card, so the native
            // shadow returns once the card has settled at full size.
            panel.hasShadow = false
            panel.alphaValue = 1
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
        }
        let duration = reducedMotion ? PreviewRevealMotion.reducedDuration : PreviewRevealMotion.showDuration
        // The main panel's ease-out curve. No overshoot, so the card never clips at the window edge.
        let curve = PanelMotion.curve
        let animation: Animation = reducedMotion ? .easeOut(duration: duration) : .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)
        // Commit the collapsed frame before animating, or SwiftUI skips the growth.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revealGeneration == token else { return }
            withAnimation(animation) { self.reveal.shown = true }
            // Timed from the real start of the growth, not from the request.
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, self.revealGeneration == token, self.panel.isVisible else { return }
                self.panel.hasShadow = true
                self.panel.invalidateShadow()
            }
        }
    }

    private func dismiss(animated: Bool, reversible: Bool) {
        presented = false
        revealGeneration &+= 1
        let token = revealGeneration
        guard panel.isVisible else { return }
        panel.hasShadow = false
        guard animated else {
            interaction.setShrinking(false)
            var instant = Transaction(); instant.disablesAnimations = true
            withTransaction(instant) { reveal.shown = false }
            panel.orderOut(nil)
            return
        }
        // A shrinking card should not swallow clicks meant for windows behind it.
        panel.ignoresMouseEvents = true
        interaction.setShrinking(reversible)
        let duration = reducedMotion ? PreviewRevealMotion.reducedDuration : PreviewRevealMotion.hideDuration
        withAnimation(.easeIn(duration: duration)) { reveal.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.revealGeneration == token else { return }
            self.interaction.setShrinking(false)
            self.panel.orderOut(nil)
            self.panel.ignoresMouseEvents = false
        }
    }

    private func samplePointer() {
        let regions = CornerLayout.previewRegions(pointer: pointerLocation, anchor: anchor, preview: presented ? panel.frame : nil)
        interaction.reconcilePointer(regions: regions, at: ProcessInfo.processInfo.systemUptime)
    }
}

@MainActor
private struct HoverTaskPreview: View {
    @ObservedObject var store: AppStore
    @ObservedObject var reveal: PreviewReveal
    var aboveAnchor = false
    let onHover: (Bool) -> Void
    private let secondary = muted
    private var selection: PreviewTaskSelection<TaskItem> {
        PreviewTaskSelection(store.tasks, isOutstanding: { !$0.completed }, isShortTerm: { $0.horizon == .shortTerm })
    }
    var body: some View {
        VStack(spacing: 0) {
            // Transparent tracking bridge: no visible surface touches the icon.
            if !aboveAnchor { Color.clear.frame(height: CornerLayout.previewGap) }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if selection.outstandingCount == 0 {
                        Text("No outstanding tasks.")
                            .font(.system(size: 12))
                            .foregroundStyle(secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        previewGroup(.shortTerm, tasks: selection.shortTerm)
                        previewGroup(.longerTerm, tasks: selection.longerTerm)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ivory)
            .clipShape(RoundedRectangle(cornerRadius: CornerLayout.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CornerLayout.cornerRadius, style: .continuous).strokeBorder(accent.opacity(0.16), lineWidth: 1))
            // Only the visible card scales. The tracking region keeps its full size.
            .scaleEffect(reveal.shown || reveal.reduced ? 1 : PreviewRevealMotion.collapsedScale,
                         anchor: UnitPoint(x: reveal.origin.x, y: reveal.origin.y))
            .opacity(reveal.shown ? 1 : 0)
            if aboveAnchor { Color.clear.frame(height: CornerLayout.previewGap) }
        }
        .foregroundStyle(ink)
        .background(CornerHoverRegion(onHover: onHover))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read-only outstanding task preview")
    }

    @ViewBuilder
    private func previewGroup(_ horizon: TaskHorizon, tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(horizon.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(secondary)
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        HStack(alignment: .center, spacing: 9) {
                            Circle().fill(dotColor(task)).frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if task.isSample { Text("Sample").font(.system(size: 9)).foregroundStyle(secondary) }
                        }.frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    }
                }
            }
        }
    }

    private func dotColor(_ task: TaskItem) -> Color {
        if let label = store.labels.first(where: { task.labelIDs.contains($0.id) }) {
            return label.color.tint
        }
        return accent
    }
}
