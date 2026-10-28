import Foundation
import Combine

/// Owned by the persistent panel view, so navigation never discards a capture
/// draft or silently changes the user's tree and visibility choices.
final class ChecklistViewState: ObservableObject {
    @Published var collapsedParents: Set<UUID> = []
    @Published var showLabels = false
    @Published var showHistory = false
    let creation = TaskCreationDraft()
    private(set) var lastConsumedFocusRequest = 0

    /// Requests are monotonic within the panel lifetime. Reopening by mouse or
    /// receiving a stale view callback cannot replay an earlier keyboard request.
    func consumeFocusRequest(_ request: Int) -> Bool {
        guard request > lastConsumedFocusRequest else { return false }
        lastConsumedFocusRequest = request
        return true
    }
}

struct ChecklistEntry: Identifiable {
    let task: TaskItem
    let depth: Int
    let hasChildren: Bool
    var id: UUID { task.id }
}

struct ActiveChecklist {
    let tasks: [TaskItem]
    let collapsedParents: Set<UUID>
    var now: Date = Date()

    func children(of parentID: UUID) -> [TaskItem] {
        let children = Dictionary(grouping: tasks.filter { $0.parentID != nil }, by: { $0.parentID! })
        var visited: Set<UUID> = [parentID]
        func visible(_ task: TaskItem) -> [TaskItem] {
            guard visited.insert(task.id).inserted else { return [] }
            return task.isArchived(at: now) ? (children[task.id] ?? []).flatMap(visible) : [task]
        }
        return (children[parentID] ?? []).flatMap(visible)
    }

    func entries(for horizon: TaskHorizon) -> [ChecklistEntry] {
        let ids = Set(tasks.map(\.id))
        let children = Dictionary(grouping: tasks.filter { $0.parentID != nil }, by: { $0.parentID! })
        var visited = Set<UUID>()
        var result: [ChecklistEntry] = []
        func append(_ task: TaskItem, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            let descendants = children[task.id] ?? []
            if task.isArchived(at: now) {
                descendants.forEach { append($0, depth: depth) }
            } else {
                result.append(ChecklistEntry(task: task, depth: depth,
                                             hasChildren: hasActiveDescendants(task.id, seen: [])))
                if !collapsedParents.contains(task.id) {
                    descendants.forEach { append($0, depth: depth + 1) }
                }
            }
        }
        func hasActiveDescendants(_ parentID: UUID, seen: Set<UUID>) -> Bool {
            guard !seen.contains(parentID) else { return false }
            var next = seen; next.insert(parentID)
            return (children[parentID] ?? []).contains { !$0.isArchived(at: now) || hasActiveDescendants($0.id, seen: next) }
        }
        tasks.filter { ($0.parentID == nil || !ids.contains($0.parentID!)) && $0.horizon == horizon }
            .forEach { append($0, depth: 0) }
        return result
    }
}

/// Creation intentionally has no session, source, next-action, date, or urgency
/// fields. Nothing reaches the store until the single atomic submit succeeds.
final class TaskCreationDraft: ObservableObject {
    @Published var title = ""
    @Published var details = ""
    @Published var labelIDs: [UUID] = []
    @Published var agentHelpRequested = false
    @Published var detailsExpanded = false
    @Published var parentID: UUID?
    @Published var horizon: TaskHorizon = .shortTerm
    @Published var newLabelName = ""
    @Published var creatingLabel = false
    @Published private(set) var focusRequest = 0
    private(set) var consumedFocusRequest = 0
    private let initialParentID: UUID?

    init(parentID: UUID? = nil) { self.parentID = parentID; initialParentID = parentID }
    var expanded: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !details.isEmpty ||
            !labelIDs.isEmpty || agentHelpRequested || !newLabelName.isEmpty || detailsExpanded
    }
    func requestFocus() { focusRequest += 1 }
    func consumeFocus() -> Bool {
        guard focusRequest > consumedFocusRequest else { return false }
        consumedFocusRequest = focusRequest; return true
    }
    func reconcileLabels(available ids: Set<UUID>) {
        labelIDs = labelIDs.filter { ids.contains($0) }
    }
    /// Global capture falls back to its current list when its chosen parent is
    /// deleted. Inspector capture stays pinned so its draft can return via Undo.
    func reconcileParent(tasks: [TaskItem]) {
        if let initialParentID {
            if let parent = tasks.first(where: { $0.id == initialParentID }) {
                parentID = parent.id
                horizon = parent.horizon
            }
            return
        }
        guard let parentID else { return }
        if let parent = tasks.first(where: { $0.id == parentID }) {
            horizon = parent.horizon
        } else {
            self.parentID = nil
        }
    }
    func cancel() {
        resetFields()
        parentID = initialParentID; horizon = .shortTerm
        // Invalidate any focus callback queued before the user cancelled.
        focusRequest += 1; consumedFocusRequest = focusRequest
    }
    @MainActor
    @discardableResult func submit(to store: AppStore) -> Bool {
        reconcileParent(tasks: store.tasks)
        guard store.addTask(title: title, details: details, labelIDs: labelIDs,
                            agentHelpRequested: agentHelpRequested, parentID: parentID, horizon: horizon) else { return false }
        resetFields()
        return true
    }
    private func resetFields() {
        title = ""; details = ""; labelIDs = []; agentHelpRequested = false
        detailsExpanded = false; newLabelName = ""; creatingLabel = false
    }
}

struct InspectorText: Equatable {
    var title: String
    var nextAction: String
    var notes: String
    var source: String
    var sourceURL: String
    var agentHelpRequested: Bool

    init(task: TaskItem) {
        title = task.title; nextAction = task.nextAction; notes = task.notes
        source = task.source ?? ""; sourceURL = task.sourceURL ?? ""
        agentHelpRequested = task.agentHelpRequested
    }
    init(title: String, nextAction: String, notes: String, source: String, sourceURL: String, agentHelpRequested: Bool) {
        self.title = title; self.nextAction = nextAction; self.notes = notes
        self.source = source; self.sourceURL = sourceURL
        self.agentHelpRequested = agentHelpRequested
    }
}

/// A task's unsaved text lives beyond the inspector's view lifetime. Model-only
/// organization changes do not reset it; conflicting text never overwrites it.
final class TaskInspectorDraft: ObservableObject {
    @Published var title: String
    @Published var nextAction: String
    @Published var notes: String
    @Published var source: String
    @Published var sourceURL: String
    @Published var agentHelpRequested: Bool
    @Published var detailsExpanded = false
    @Published var moreExpanded = false
    @Published var newLabelName = ""
    @Published var creatingLabel = false
    let subtaskCreation: TaskCreationDraft
    var subtaskTitle: String {
        get { subtaskCreation.title }
        set { subtaskCreation.title = newValue }
    }
    @Published private(set) var incoming: InspectorText?
    private var baseline: InspectorText

    init(task: TaskItem) {
        let initial = InspectorText(task: task)
        title = initial.title; nextAction = initial.nextAction; notes = initial.notes
        source = initial.source; sourceURL = initial.sourceURL; baseline = initial
        agentHelpRequested = initial.agentHelpRequested
        subtaskCreation = TaskCreationDraft(parentID: task.id)
    }
    private var text: InspectorText {
        InspectorText(title: title, nextAction: nextAction, notes: notes, source: source, sourceURL: sourceURL,
                      agentHelpRequested: agentHelpRequested)
    }
    var isDirty: Bool { text != baseline }
    func reconcile(with task: TaskItem) {
        let latest = InspectorText(task: task)
        guard latest != baseline else { incoming = nil; return }
        if !isDirty || text == latest { load(latest) }
        else { incoming = latest }
    }
    func acceptedSave(_ task: TaskItem) { load(InspectorText(task: task)) }
    func useLatest() { if let incoming { load(incoming) } }
    func keepDraft() { if let incoming { baseline = incoming; self.incoming = nil } }
    private func load(_ value: InspectorText) {
        baseline = value; incoming = nil
        title = value.title; nextAction = value.nextAction; notes = value.notes
        source = value.source; sourceURL = value.sourceURL
        agentHelpRequested = value.agentHelpRequested
    }
    @MainActor
    @discardableResult func save(to store: AppStore, taskID: UUID) -> Bool {
        guard let task = store.tasks.first(where: { $0.id == taskID }) else { return false }
        reconcile(with: task)
        guard incoming == nil else { return false }
        let link = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.updateTask(id: taskID, title: title, notes: notes, nextAction: nextAction,
                               source: source, sourceURL: link.isEmpty ? nil : link,
                               agentHelpRequested: agentHelpRequested) else { return false }
        if let saved = store.tasks.first(where: { $0.id == taskID }) { acceptedSave(saved) }
        return true
    }
}

final class TaskInspectorDrafts: ObservableObject {
    private var drafts: [UUID: TaskInspectorDraft] = [:]
    private var deletedDraftIDs: [UUID] = []
    private let deletedDraftLimit: Int

    /// Deleted tasks can return through Undo. Keep their entire inspector draft
    /// (including an unsent subtask) for this panel session, bounded separately
    /// from live tasks. Only the exact UUID can reclaim a retained draft.
    init(deletedDraftLimit: Int = 100) {
        self.deletedDraftLimit = max(0, deletedDraftLimit)
    }

    func draft(for task: TaskItem) -> TaskInspectorDraft {
        deletedDraftIDs.removeAll { $0 == task.id }
        if let draft = drafts[task.id] { return draft }
        let draft = TaskInspectorDraft(task: task)
        drafts[task.id] = draft
        return draft
    }
    func retainTasks(ids: Set<UUID>, undoableIDs: Set<UUID>? = nil) {
        if let undoableIDs {
            let recoverable = ids.union(undoableIDs)
            drafts = drafts.filter { recoverable.contains($0.key) }
            deletedDraftIDs.removeAll { !recoverable.contains($0) || ids.contains($0) }
            return
        }
        deletedDraftIDs.removeAll { ids.contains($0) }
        let alreadyDeleted = Set(deletedDraftIDs)
        let newlyDeleted = drafts.keys.filter { !ids.contains($0) && !alreadyDeleted.contains($0) }
        // Stable ordering when a subtree disappears in one update. Repeated
        // reconciliation must not refresh the age of an already deleted draft.
        deletedDraftIDs.append(contentsOf: newlyDeleted.sorted { $0.uuidString < $1.uuidString })
        let excess = max(0, deletedDraftIDs.count - deletedDraftLimit)
        for id in deletedDraftIDs.prefix(excess) { drafts.removeValue(forKey: id) }
        deletedDraftIDs.removeFirst(excess)
    }
}
