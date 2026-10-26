import AppKit
import SwiftUI
import Combine

/// Read-only hover surface. It cannot take keyboard focus or activate bist.
private final class ReadOnlyPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PreviewPanelController {
    private let store: AppStore
    private let panel: ReadOnlyPreviewPanel
    private var interaction = HoverPreviewInteraction()
    private var timer: Timer?
    private var observation: AnyCancellable?
    private var anchor = CGRect.zero
    private var visibleFrame: CGRect?
    var reducedMotion = false
    var reduceTransparency = false { didSet { if oldValue != reduceTransparency { refreshContent() } } }
    var isVisible: Bool { interaction.isVisible }

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
        reconcile()
    }

    func reposition(anchor: CGRect, visibleFrame: CGRect? = nil) {
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        updateGeometry()
    }

    func cancel() {
        interaction.cancel()
        reconcile()
    }

    @discardableResult
    func handleEscape() -> Bool {
        let handled = interaction.escape()
        reconcile()
        return handled
    }

    private func previewHoverChanged(_ inside: Bool) {
        interaction.pointerChanged(.preview, inside: inside, at: ProcessInfo.processInfo.systemUptime)
        reconcile()
    }

    private var contentHeight: CGFloat {
        let selection = PreviewTaskSelection(store.tasks, isOutstanding: { !$0.completed }, isShortTerm: { $0.horizon == .shortTerm })
        return selection.visibleCount == 0 ? 126 : CGFloat(90 + selection.visibleCount * 27 + selection.visibleGroupCount * 20)
    }

    private func updateGeometry() {
        let screen = visibleFrame ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        panel.setFrame(CornerLayout.previewFrame(anchor: anchor, contentHeight: contentHeight, visibleFrame: screen), display: true)
    }

    private func refreshContent() {
        let host = NSHostingView(rootView: HoverTaskPreview(store: store, opaque: reduceTransparency, onHover: { [weak self] inside in self?.previewHoverChanged(inside) }))
        // The panel, not SwiftUI's intrinsic content size, owns screen geometry.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        updateGeometry()
    }

    private func reconcile() {
        timer?.invalidate()
        timer = nil
        if let pending = interaction.pending {
            let interval = max(0.001, pending.deadline - ProcessInfo.processInfo.systemUptime)
            let token = pending.generation
            let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = self.interaction.advance(at: ProcessInfo.processInfo.systemUptime, generation: token)
                    self.reconcile()
                }
            }
            RunLoop.main.add(next, forMode: .common)
            timer = next
        }
        if interaction.isVisible {
            if !panel.isVisible {
                updateGeometry()
                // An immediate reveal avoids distracting motion or a moving target.
                // Reduced-motion users receive the exact same stationary behavior.
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }
}

@MainActor
private struct HoverTaskPreview: View {
    @ObservedObject var store: AppStore
    let opaque: Bool
    let onHover: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let ink = Color(red: 0.18, green: 0.17, blue: 0.23)
    private let secondary = Color(red: 0.40, green: 0.38, blue: 0.46)
    private let violet = Color(red: 0.47, green: 0.37, blue: 0.73)
    private var selection: PreviewTaskSelection<TaskItem> {
        PreviewTaskSelection(store.tasks, isOutstanding: { !$0.completed }, isShortTerm: { $0.horizon == .shortTerm })
    }
    private var solid: Bool { opaque || reduceTransparency }
    var body: some View {
        VStack(spacing: 0) {
            // Transparent tracking bridge: no visible surface touches the icon.
            Color.clear.frame(height: CornerLayout.previewGap)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Outstanding").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(selection.outstandingCount)").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                }
                if selection.outstandingCount == 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A little room to breathe.").font(.system(size: 12, weight: .medium))
                        Text("No outstanding tasks.").font(.system(size: 11)).foregroundStyle(secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        previewGroup(.shortTerm, tasks: selection.shortTerm)
                        previewGroup(.longerTerm, tasks: selection.longerTerm)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow").font(.system(size: 9))
                    Text("Click bist to open").font(.system(size: 10))
                    Spacer()
                    if selection.outstandingCount > selection.visibleCount {
                        Text("+\(selection.outstandingCount - selection.visibleCount) more").font(.system(size: 10))
                    }
                }.foregroundStyle(secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    PreviewGlass(opaque: solid)
                    Color(red: 0.97, green: 0.96, blue: 0.94).opacity(solid ? 1 : 0.52)
                    if !solid { LinearGradient(colors: [.white.opacity(0.36), violet.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.86), lineWidth: 1))
        }
        .foregroundStyle(ink)
        .preferredColorScheme(.light)
        .background(CornerHoverRegion(onHover: onHover))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read-only outstanding task preview")
    }

    @ViewBuilder
    private func previewGroup(_ horizon: TaskHorizon, tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(horizon.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(secondary)
                ForEach(tasks) { task in
                    HStack(alignment: .center, spacing: 9) {
                        Circle().fill(dotColor(task)).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if task.isSample { Text("Sample").font(.system(size: 9)).foregroundStyle(secondary) }
                    }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                }
            }
        }
    }

    private func dotColor(_ task: TaskItem) -> Color {
        if let label = store.labels.first(where: { task.labelIDs.contains($0.id) }) {
            let value = UInt64(label.color.hex.dropFirst(), radix: 16) ?? 0x7567B7
            return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
        }
        return violet
    }
}

private struct PreviewGlass: NSViewRepresentable {
    let opaque: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .popover
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.isHidden = opaque }
}
