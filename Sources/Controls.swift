import SwiftUI

/// Shared reference keeps input modality live inside separately hosted popovers.
final class BistFocusContext: ObservableObject {
    @Published var keyboardNavigation = false
    private var presentedPickers = Set<UUID>()
    var hasPresentedPicker: Bool { !presentedPickers.isEmpty }
    func setPickerPresented(id: UUID, presented: Bool) {
        if presented { presentedPickers.insert(id) } else { presentedPickers.remove(id) }
    }
}

private struct BistReducedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var bistReduced: Bool { get { self[BistReducedKey.self] } set { self[BistReducedKey.self] = newValue } } }

let ink = Color(red: 0.18, green: 0.17, blue: 0.23)
let muted = Color(red: 0.43, green: 0.41, blue: 0.49)
let violet = Color(red: 0.47, green: 0.37, blue: 0.73)
let ivory = Color(red: 0.97, green: 0.96, blue: 0.94)

/// Native focus effects are suppressed; keyboard users keep an intentional ring.
private struct BistButtonFocus: ViewModifier {
    @EnvironmentObject private var focusContext: BistFocusContext
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    var radius: CGFloat = 10
    let action: () -> Void
    func body(content: Content) -> some View {
        content.focusable(isEnabled).focused($focused).focusEffectDisabled()
            .onKeyPress(keys: [.space, .return, KeyEquivalent("\u{3}")], phases: .down) { _ in
                guard focused && isEnabled else { return .ignored }
                action()
                return .handled
            }
            .overlay {
                if ButtonFocusPolicy.showsRing(focused: focused, keyboardNavigation: focusContext.keyboardNavigation) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .inset(by: 2)
                        .strokeBorder(violet.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
/// One focus target with explicit keyboard activation for custom button styling.
struct BistButton<Label: View>: View {
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
        Button(action: action) { label }
            .modifier(BistButtonFocus(radius: focusRadius, action: action))
    }
}

struct TactileStyle: ButtonStyle {
    var accent = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) var reduce
    @Environment(\.bistReduced) var localReduce
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(accent ? .white : ink)
            .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 7 : 9)
            .background(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).fill(accent ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.62, green: 0.51, blue: 0.84), violet], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.35 : 0.62))))
            .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous).strokeBorder(.white.opacity(accent ? 0.25 : 0.8), lineWidth: 0.8))
            .shadow(color: (accent ? violet : .black).opacity(configuration.isPressed ? 0.03 : 0.10), radius: configuration.isPressed ? 1 : 3, x: 0, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && !(reduce || localReduce) ? 0.97 : 1)
            .animation(reduce || localReduce ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.5)
    }
}


/// Visual feedback changes only paint, so the corner target never moves or grows.
struct CornerButtonStyle: ButtonStyle {
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.bistReduced) private var localReduce
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(configuration.isPressed ? violet.opacity(0.12) : .white.opacity(hovered ? 0.46 : 0))
                    .shadow(color: violet.opacity(hovered && !configuration.isPressed ? 0.16 : 0), radius: 3, y: 1)
            }
            .animation(reduceMotion || localReduce ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
