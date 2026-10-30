import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared by disclosure, hierarchy changes and the destination feedback.
enum TaskListMotion {
    static func hierarchy(reduced: Bool) -> Animation? {
        reduced ? nil : .smooth(duration: 0.28, extraBounce: 0)
    }

    static func feedback(reduced: Bool) -> Animation? {
        reduced ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    }

    static func disclosure(reduced: Bool) -> Animation? {
        reduced ? nil : .smooth(duration: 0.34, extraBounce: 0)
    }
}

struct TaskDragGrip: View {
    var body: some View {
        HStack(spacing: 2) {
            dots
            dots
        }.accessibilityElement(children: .ignore)
    }

    private var dots: some View {
        VStack(spacing: 2) {
            ForEach(0..<3) { _ in Circle().frame(width: 2, height: 2) }
        }
    }
}

/// Keep hidden rows in layout so the scroll extent follows every animation frame.
/// Removal transitions only retain drawing and let AppKit clamp scrolling early.
struct TaskRowReveal: AnimatableModifier {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: 30, alignment: .top)
            .frame(height: 30 * max(0, min(1, progress)), alignment: .top)
            .clipped().opacity(Double(min(1, max(0, progress) * 2)))
    }
}

@MainActor
final class TaskDragState: ObservableObject {
    @Published var taskID: UUID?
    @Published var target: TaskPlacement?

    func provider(for id: UUID) -> NSItemProvider {
        taskID = id
        target = nil
        // A standard text representation reliably enters AppKit's drag loop.
        // The destination checks both the in-app source and this exact payload.
        let provider = NSItemProvider(object: "bist-task:\(id.uuidString)" as NSString)
        provider.suggestedName = "bist task"
        return provider
    }
}

/// The thin top/bottom zones reorder siblings; the center nests, like an outliner.
struct TaskRowDropDelegate: DropDelegate {
    let rowID: UUID?
    let horizon: TaskHorizon
    let store: AppStore
    let drag: TaskDragState
    let didMove: (UUID?) -> Void

    private func destination(_ info: DropInfo) -> TaskPlacement {
        guard let rowID else { return .list(horizon) }
        if info.location.y < 7 { return .before(rowID) }
        if info.location.y > 23 { return .after(rowID) }
        return .inside(rowID)
    }
    func validateDrop(info: DropInfo) -> Bool {
        guard let id = drag.taskID else { return false }
        return info.hasItemsConforming(to: [.text]) && store.canMoveTask(id: id, to: destination(info))
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { drag.target = nil }
    private func update(_ info: DropInfo) { drag.target = validateDrop(info: info) ? destination(info) : nil }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let id = drag.taskID,
              let provider = info.itemProviders(for: [.text]).first else { return false }
        let placement = destination(info)
        drag.target = nil
        provider.loadObject(ofClass: NSString.self) { object, _ in
            Task { @MainActor in
                defer {
                    if drag.taskID == id { drag.taskID = nil; drag.target = nil }
                }
                guard let text = object as? NSString, text as String == "bist-task:\(id.uuidString)",
                      store.moveTask(id: id, to: placement) else { return }
                if case .inside(let parent) = placement { didMove(parent) }
                else { didMove(nil) }
            }
        }
        return true
    }
}

struct TaskDropIndicator: View {
    let placement: TaskPlacement?
    let rowID: UUID
    let depth: Int
    let reducedMotion: Bool
    var body: some View {
        ZStack {
            if placement == .inside(rowID) {
                RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.09))
                RoundedRectangle(cornerRadius: 6).strokeBorder(accent.opacity(0.65), lineWidth: 1)
            }
            if placement == .before(rowID) || placement == .after(rowID) {
                Capsule().fill(accent).frame(height: 2)
                    .overlay(alignment: .leading) { Circle().fill(accent).frame(width: 4, height: 4) }
                    .padding(.leading, 42 + CGFloat(min(depth, 5)) * 12)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity, alignment: placement == .before(rowID) ? .top : .bottom)
            }
        }.animation(TaskListMotion.feedback(reduced: reducedMotion), value: placement)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Searchable native popover gives keyboard and non-drag users the same moves.
struct TaskMovePicker: View {
    @ObservedObject var store: AppStore
    let taskID: UUID
    var didMove: () -> Void = {}
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @EnvironmentObject private var focusContext: BistFocusContext
    @State private var presentationID = UUID()
    @State private var mounted = false
    private var destinations: [TaskItem] {
        store.tasks.filter { !$0.completed && store.canMoveTask(id: taskID, to: .inside($0.id)) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move task").font(.system(size: 14, weight: .semibold))
            TextField("Find a parent task…", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find destination task").focused($searchFocused)
            ForEach(TaskHorizon.allCases) { horizon in
                Button { move(.list(horizon)) } label: {
                    Label("\(horizon.title) · top level", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 28)
                }.buttonStyle(.plain)
            }
            Divider()
            Text("Make a subtask of").font(.system(size: 10, weight: .medium)).foregroundColor(muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(destinations) { task in
                        Button { move(.inside(task.id)) } label: {
                            Label(task.title, systemImage: "arrow.turn.down.right").lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 30)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if destinations.isEmpty { Text("No matching tasks").foregroundColor(muted).padding(.vertical, 8) }
                }
            }.frame(maxHeight: 190)
        }.font(.system(size: 11)).foregroundColor(ink).tint(accent).padding(14).frame(width: 270)
            .background(ivory)
            .onAppear {
                mounted = true
                focusContext.setPickerPresented(id: presentationID, presented: true)
                DispatchQueue.main.async { if mounted { searchFocused = true } }
            }
            .onDisappear {
                mounted = false
                focusContext.setPickerPresented(id: presentationID, presented: false)
            }
            .onExitCommand { didMove() }
    }
    private func move(_ placement: TaskPlacement) {
        if store.moveTask(id: taskID, to: placement) { didMove() }
    }
}
