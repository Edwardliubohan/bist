import SwiftUI
import AppKit

/// Shared reference keeps input modality live inside separately hosted popovers.
final class BistFocusContext: ObservableObject {
    @Published var keyboardNavigation = false
    @Published private(set) var textDismissGeneration = 0
    func dismissTextEntry() { textDismissGeneration &+= 1 }
    typealias RegionKind = BistInteractionRegion.Kind
    var interactionRegions: [BistInteractionRegion] = []
    func contains(_ kind: RegionKind, point: CGPoint, in window: NSWindow) -> Bool {
        BistInteractionRegion.contains(kind, point: point,
                                       contentHeight: window.contentView?.bounds.height ?? window.frame.height,
                                       regions: interactionRegions)
    }
    private var presentedPickers = Set<UUID>()
    var hasPresentedPicker: Bool { !presentedPickers.isEmpty }
    func setPickerPresented(id: UUID, presented: Bool) {
        if presented { presentedPickers.insert(id) } else { presentedPickers.remove(id) }
    }
}

private struct BistReducedKey: EnvironmentKey { static let defaultValue = false }
private struct BistFocusRevealKey: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues { var bistReduced: Bool { get { self[BistReducedKey.self] } set { self[BistReducedKey.self] = newValue } } }
extension EnvironmentValues { var bistFocusReveal: () -> Void { get { self[BistFocusRevealKey.self] } set { self[BistFocusRevealKey.self] = newValue } } }

let ink = Color(red: 0.16, green: 0.12, blue: 0.09)
let muted = Color(red: 0.34, green: 0.28, blue: 0.23)
let accent = Color(red: 0.64, green: 0.24, blue: 0.055)
let cornerOrange = Color(red: 0.94, green: 0.36, blue: 0.12)
let ivory = Color(red: 0.99, green: 0.97, blue: 0.94)

private struct BistPointingHand: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let enabled: Bool
    func body(content: Content) -> some View {
        content.background(PointingHandRegion(enabled: enabled && isEnabled))
    }
}

extension View {
    func bistPointingHand(enabled: Bool = true) -> some View {
        modifier(BistPointingHand(enabled: enabled))
    }
}

private struct PointingHandRegion: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) { view.enabled = enabled; view.refresh() }
    static func dismantleNSView(_ view: CursorView, coordinator: ()) { view.discardCursorRects() }

    final class CursorView: NSView {
        var enabled = true
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        override func layout() { super.layout(); refresh() }
        func refresh() { window?.invalidateCursorRects(for: self) }
        override func resetCursorRects() {
            super.resetCursorRects()
            var exclusions = [CGRect]()
            func inspect(_ view: NSView) {
                if let field = view as? NSTextField, field.isEditable || field.isSelectable {
                    exclusions.append(convert(field.bounds, from: field))
                } else if let text = view as? NSTextView, text.isEditable || text.isSelectable {
                    exclusions.append(convert(text.bounds, from: text))
                } else if let control = view as? NSControl, !control.isEnabled {
                    exclusions.append(convert(control.bounds, from: control))
                }
                view.subviews.forEach(inspect)
            }
            if let root = window?.contentView { inspect(root) }
            for rectangle in PointingHandGeometry.rectangles(in: visibleRect, excluding: exclusions, enabled: enabled) {
                addCursorRect(rectangle, cursor: .pointingHand)
            }
        }
    }
}

/// Native focus effects are suppressed; keyboard users keep an intentional ring.
private struct BistButtonFocus: ViewModifier {
    @EnvironmentObject private var focusContext: BistFocusContext
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.bistFocusReveal) private var revealFocus
    var radius: CGFloat = 10
    let action: () -> Void
    func body(content: Content) -> some View {
        content.focusable(isEnabled).focused($focused).focusEffectDisabled()
            .onChange(of: focused) {
                if focused && focusContext.keyboardNavigation { revealFocus() }
            }
            .onKeyPress(keys: [.space, .return, KeyEquivalent("\u{3}")], phases: .down) { _ in
                guard focused && isEnabled else { return .ignored }
                action()
                return .handled
            }
            .overlay {
                if ButtonFocusPolicy.showsRing(focused: focused, keyboardNavigation: focusContext.keyboardNavigation) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .inset(by: 2)
                        .strokeBorder(accent.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
/// One focus target with explicit keyboard activation for custom button styling.
struct BistButton<Label: View>: View {
    @EnvironmentObject private var focusContext: BistFocusContext
    let action: () -> Void
    let label: Label
    var focusRadius: CGFloat
    init(focusRadius: CGFloat = 10, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action; self.label = label(); self.focusRadius = focusRadius
    }
    init(_ title: String, action: @escaping () -> Void) where Label == Text {
        self.action = action; self.label = Text(title); self.focusRadius = 10
    }
    var body: some View {
        Button {
            // Native/AX activation can arrive without a local mouse-down event.
            // Explicit keyboard activation is handled by the modifier below.
            focusContext.keyboardNavigation = false
            action()
        } label: { label }
            .modifier(BistButtonFocus(radius: focusRadius, action: action))
            .bistPointingHand()
    }
}

struct PanelNavigationButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        BistButton(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).frame(minHeight: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundColor(ink)
        .background(ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(title)
    }
}

struct TactileStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) var reduce
    @Environment(\.bistReduced) var localReduce
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(prominent ? .white : ink)
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 7 : 9)
            .background(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.73, green: 0.29, blue: 0.08), accent], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.35 : 0.62))))
            .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).strokeBorder(.white.opacity(prominent ? 0.25 : 0.8), lineWidth: 0.8))
            .shadow(color: (prominent ? accent : .black).opacity(configuration.isPressed ? 0.03 : 0.10), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && !(reduce || localReduce) ? 0.97 : 1)
            .animation(reduce || localReduce ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.5)
            .bistPointingHand()
    }
}


/// Visual feedback changes only paint, so the corner target never moves or grows.
struct CornerButtonStyle: ButtonStyle {
    let hovered: Bool
    let feedback: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bistReduced) private var localReduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(cornerOrange.opacity((configuration.isPressed ? 0.28 : hovered ? 0.18 : 0) * feedback))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(cornerOrange.opacity((hovered || configuration.isPressed) ? 0.42 * feedback : 0), lineWidth: 1)
                    }
                    .shadow(color: cornerOrange.opacity(hovered && !configuration.isPressed ? 0.24 * feedback : 0), radius: 3, y: 1)

            }
            .animation(reduceMotion || localReduce ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .bistPointingHand()
    }
}

/// Keep scrolling native and accessible while matching the translucent material.
func styleGlassScrollViews(in view: NSView) {
    if let scroll = view as? NSScrollView {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.verticalScroller?.controlSize = .mini
        scroll.horizontalScroller?.controlSize = .mini
    }
    view.subviews.forEach { styleGlassScrollViews(in: $0) }
}

final class GlassHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        styleGlassScrollViews(in: self)
    }
}

/// Place inside a SwiftUI scroll view's content, including separately hosted popovers.
struct OverlayScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.applySoon() }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applySoon() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); applySoon() }
        func applySoon() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView { styleGlassScrollViews(in: scroll); return }
                    ancestor = view.superview
                }
            }
        }
    }
}

/// SwiftUI geometry is authoritative: native backing views can span the whole host.
struct BistInteractionRegionsKey: PreferenceKey {
    static let defaultValue: [BistInteractionRegion] = []
    static func reduce(value: inout [BistInteractionRegion], nextValue: () -> [BistInteractionRegion]) {
        value += nextValue()
    }
}
extension View {
    func bistInteractionRegion(_ kind: BistFocusContext.RegionKind) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: BistInteractionRegionsKey.self,
                                   value: [BistInteractionRegion(kind: kind, rect: proxy.frame(in: .named("bistPanel")))])
        })
    }
    func bistTextEntry() -> some View { bistInteractionRegion(.text) }
}
