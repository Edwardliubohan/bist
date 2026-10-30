import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension TaskLabelColor {
    var tint: Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xAD7A38
        return BistPalette.category(NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                                            green: Double((value >> 8) & 255) / 255,
                                            blue: Double(value & 255) / 255, alpha: 1))
    }
}

struct ChecklistPane: View {
    @ObservedObject var store: AppStore
    let openTask: (UUID) -> Void
    let focusRequest: Int
    let reducedMotion: Bool
    @ObservedObject var viewState: ChecklistViewState
    @StateObject private var drag = TaskDragState()
    @State private var movingTask: TaskItem?

    private var collapsedParents: Set<UUID> {
        get { viewState.collapsedParents }
        nonmutating set { viewState.collapsedParents = newValue }
    }
    private var showLabels: Bool {
        get { viewState.showLabels }
        nonmutating set { viewState.showLabels = newValue }
    }
    private func entries(for horizon: TaskHorizon, at now: Date) -> [ChecklistEntry] {
        ActiveChecklist(tasks: store.tasks, collapsedParents: collapsedParents, now: now).entries(for: horizon)
    }

    var body: some View {
        TaskRetentionClock(tasks: store.tasks) { now in
            content(at: now)
        }
    }

    private func content(at now: Date) -> some View {
        ZStack {
            if showLabels {
                TaskLabelManager(store: store) { showLabels = false }
                    .transition(navigationTransition)
            } else if viewState.showHistory {
                TaskHistoryPane(store: store, now: now, openTask: openTask) { viewState.showHistory = false }
                    .transition(navigationTransition)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if store.tasks.contains(where: \.isSample) {
                            Text("Sample").font(.system(size: 8)).foregroundColor(accent)
                        }
                        PanelNavigationButton(title: "Past tasks", symbol: "clock.arrow.circlepath") { viewState.showHistory = true }
                        PanelNavigationButton(title: "Tags", symbol: "tag") { showLabels = true }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 20).padding(.bottom, 7)
                    HStack(spacing: 0) {
                        Text("Me").frame(width: 26).padding(.leading, 14).accessibilityLabel("My completion column")
                        Text("Task").padding(.leading, 12)
                        Spacer()
                        Text("Agent").frame(width: 32).accessibilityLabel("Agent completion column")
                    }.font(.system(size: 8, weight: .medium)).foregroundColor(muted).padding(.horizontal, 16).padding(.bottom, 5)
                    Rectangle().fill(ink.opacity(0.07)).frame(height: 0.5).padding(.horizontal, 17)
                    ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if store.tasks.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Your next step, right here.").font(.system(size: 13, weight: .medium))
                                    Text("Add a task below. Labels and subtasks keep the rest in order.").font(.system(size: 11)).foregroundColor(muted)
                                    BistButton("Try sample tasks") { _ = store.loadSamples() }
                                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(accent)
                                }.padding(.horizontal, 9).padding(.vertical, 22)
                            } else {
                                section(.shortTerm, at: now, scrollProxy: scrollProxy)
                                section(.longerTerm, at: now, scrollProxy: scrollProxy)
                                if store.tasks.allSatisfy(\.completed) {
                                    Text("All checked. Completed tasks move to Past tasks after 24 hours.")
                                        .font(.system(size: 11)).foregroundColor(muted).padding(12)
                                }
                            }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }
                    }
                    TaskUndoLine(store: store).padding(.horizontal, 19).padding(.bottom, 7)
                    TaskComposer(store: store, draft: viewState.creation) { parentID in
                        if let parentID { collapsedParents.remove(parentID) }
                    }.padding(.horizontal, 17)
                    HStack {
                        Text("\(store.tasks.filter { !$0.completed }.count) open")
                        Spacer()
                        Text("On this Mac · No live sync")
                    }.font(.system(size: 9)).foregroundColor(muted).padding(.horizontal, 21).padding(.top, 9).padding(.bottom, 15)
                }.transition(reducedMotion ? .opacity : .offset(x: -18).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(reducedMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.20), value: showLabels)
        .animation(reducedMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.20), value: viewState.showHistory)
        .popover(item: $movingTask) { task in
            TaskMovePicker(store: store, taskID: task.id) { movingTask = nil }
        }
        .onAppear(perform: consumeFocusRequest)
        .onChange(of: focusRequest) { consumeFocusRequest() }
    }

    private func section(_ horizon: TaskHorizon, at now: Date, scrollProxy: ScrollViewProxy) -> some View {
        let rows = entries(for: horizon, at: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(horizon.title).font(.system(size: 13, weight: .semibold))
                Text("\(rows.filter { $0.depth == 0 }.count)").font(.system(size: 9)).foregroundColor(muted)
                Spacer()
                BistButton {
                    viewState.creation.parentID = nil
                    viewState.creation.horizon = horizon
                    viewState.creation.requestFocus()
                } label: { Image(systemName: "plus").font(.system(size: 9)).frame(width: 23, height: 25) }
                    .buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("Add task to \(horizon.title)")
            }.padding(.horizontal, 6).padding(.top, 5).frame(height: 30)
                .contentShape(Rectangle())
                .background(drag.target == .list(horizon) ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .onDrop(of: [.text], delegate: TaskRowDropDelegate(rowID: nil, horizon: horizon, store: store, drag: drag, didMove: revealMovedParent))
            ForEach(rows) { entry in
                ChecklistRow(entry: entry, labels: store.labels.filter { entry.task.labelIDs.contains($0.id) },
                             collapsed: collapsedParents.contains(entry.id), reducedMotion: reducedMotion,
                             dragProvider: { drag.provider(for: entry.id) },
                             toggleUser: { _ = store.setUserCompletion(id: entry.id, completed: !entry.task.completed) },
                             toggleChildren: {
                                 if collapsedParents.contains(entry.id) { collapsedParents.remove(entry.id) }
                                 else { collapsedParents.insert(entry.id) }
                             }, open: { openTask(entry.id) })
                .overlay(TaskDropIndicator(placement: drag.target, rowID: entry.id))
                .onDrop(of: [.text], delegate: TaskRowDropDelegate(rowID: entry.id, horizon: horizon, store: store, drag: drag, didMove: revealMovedParent))
                .id(entry.id)
                .environment(\.bistFocusReveal, { scrollProxy.scrollTo(entry.id, anchor: .center) })
                .contextMenu {
                    Button("Open details") { openTask(entry.id) }
                    Button(entry.task.completed ? "Mark mine unfinished" : "Mark mine done") {
                        _ = store.setUserCompletion(id: entry.id, completed: !entry.task.completed)
                    }
                    Button("Add subtask") {
                        viewState.creation.parentID = entry.id
                        viewState.creation.horizon = entry.task.horizon
                        collapsedParents.remove(entry.id)
                        viewState.creation.requestFocus()
                    }
                    Button("Move to…") { movingTask = entry.task }
                    if entry.task.parentID != nil {
                        Button("Move out one level") {
                            let parent = store.tasks.first { $0.id == entry.task.parentID }
                            if let grandparent = parent?.parentID { _ = store.moveTask(id: entry.id, to: .inside(grandparent)) }
                            else { _ = store.moveTask(id: entry.id, to: .list(entry.task.horizon)) }
                        }
                    }
                    Menu("Move to list") {
                        ForEach(TaskHorizon.allCases) { destination in
                            Button(destination.title) { _ = store.moveTask(id: entry.id, to: .list(destination)) }
                                .disabled(destination == entry.task.horizon && entry.task.parentID == nil)
                        }
                    }
                    Divider()
                    Button("Delete task", role: .destructive) { _ = store.deleteTask(id: entry.id) }
                    if entry.hasChildren {
                        Button("Delete task and subtasks", role: .destructive) { _ = store.deleteTask(id: entry.id, includingSubtasks: true) }
                    }
                    Menu("Tags") {
                        ForEach(store.labels) { label in
                            Toggle(label.name, isOn: Binding(get: { entry.task.labelIDs.contains(label.id) }, set: { selected in
                                var ids = entry.task.labelIDs
                                if selected { ids.append(label.id) } else { ids.removeAll { $0 == label.id } }
                                _ = store.setTaskLabels(id: entry.id, labelIDs: ids)
                            }))
                        }
                        Divider()
                        Button("Manage labels…") { showLabels = true }
                    }
                }
            }
        }
    }

    private func revealMovedParent(_ id: UUID?) {
        if let id { collapsedParents.remove(id) }
    }

    private var navigationTransition: AnyTransition {
        reducedMotion ? .opacity : .offset(x: 24).combined(with: .opacity)
    }

    private func consumeFocusRequest() {
        guard viewState.consumeFocusRequest(focusRequest) else { return }
        showLabels = false
        viewState.showHistory = false
        viewState.creation.requestFocus()
    }
}

private struct TaskComposer: View {
    @EnvironmentObject private var bobot: BobotStore
    @ObservedObject var store: AppStore
    @ObservedObject var draft: TaskCreationDraft
    var onCreated: (UUID?) -> Void = { _ in }
    @FocusState private var nameFocused: Bool
    @EnvironmentObject private var focusContext: BistFocusContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let parentID = draft.parentID {
                Label("Subtask of \(store.tasks.first(where: { $0.id == parentID })?.title ?? "task")", systemImage: "arrow.turn.down.right")
                    .font(.system(size: 8)).foregroundColor(muted).lineLimit(1)
            } else if draft.expanded && draft.horizon == .longerTerm {
                Text("Longer term").font(.system(size: 8)).foregroundColor(muted)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundColor(accent).frame(height: 25)
                TextField(draft.parentID == nil ? "Add a task" : "Add a subtask", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...3).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5).onSubmit(submit)
                    .accessibilityLabel("Task name").bistTextEntry(focused: $nameFocused)
                if draft.expanded {
                    BistButton { draft.cancel(); nameFocused = false } label: {
                        Image(systemName: "xmark").font(.system(size: 8)).frame(width: 20, height: 25)
                    }.buttonStyle(.plain).foregroundColor(muted).help("Cancel task").accessibilityLabel("Cancel task")
                    BistButton(action: submit) {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 10, weight: .medium)).frame(width: 23, height: 25)
                    }.buttonStyle(.plain).foregroundColor(accent).help("Add task · Return").accessibilityLabel("Add task")
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text("⌘N").font(.system(size: 9)).foregroundColor(muted).frame(height: 25)
                    BistButton { draft.detailsExpanded = true } label: {
                        Image(systemName: "chevron.down").font(.system(size: 8)).frame(width: 23, height: 25)
                    }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("Show optional task details")
                }
            }
            if draft.expanded {
                HStack(spacing: 7) {
                    BistButton { draft.detailsExpanded.toggle() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: draft.detailsExpanded ? "chevron.down" : "chevron.right").font(.system(size: 7))
                            Text("Details").font(.system(size: 10))
                        }.frame(height: 23)
                    }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("\(draft.detailsExpanded ? "Hide" : "Show") optional details")
                    TaskTagPicker(store: store, selectedIDs: $draft.labelIDs,
                                  newLabelName: $draft.newLabelName, creatingLabel: $draft.creatingLabel, compact: true)
                    AgentHelpToggle(isOn: $draft.agentHelpRequested, compact: true)
                    Spacer(minLength: 0)
                }.frame(height: 25)
                if draft.detailsExpanded {
                    TextEditor(text: $draft.details).font(.system(size: 11)).bistTextEntry().scrollContentBackground(.hidden)
                        .frame(height: 42).padding(6).background(surfaceHighlight.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("Optional task details")
                }
            }
            if let id = draft.pendingBobotTaskID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task saved. Bobot assignment needs retry.").font(.system(size: 10)).foregroundColor(.red)
                    BistButton("Retry Bobot assignment") {
                        if let task = store.tasks.first(where: { $0.id == id }), bobot.assign(task) { draft.pendingBobotTaskID = nil }
                    }.buttonStyle(.plain).foregroundColor(accent).font(.system(size: 11))
                }
            }
        }.padding(.horizontal, 9).padding(.vertical, 5)
            .background(surfaceHighlight.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(nameFocused ? accent.opacity(0.5) : surfaceBorder.opacity(0.8), lineWidth: 0.8))
            .onChange(of: draft.expanded) {
                if !draft.expanded { draft.detailsExpanded = false; draft.creatingLabel = false }
            }
            .onAppear {
                draft.reconcileLabels(available: Set(store.labels.map(\.id)))
                draft.reconcileParent(tasks: store.tasks)
                consumeFocus()
            }
            .onChange(of: store.labels.map(\.id)) { draft.reconcileLabels(available: Set(store.labels.map(\.id))) }
            .onChange(of: store.tasks) { draft.reconcileParent(tasks: store.tasks) }
            .onChange(of: draft.focusRequest) { consumeFocus() }
            .onChange(of: focusContext.textDismissGeneration) { nameFocused = false }
    }
    private func submit() {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.reconcileParent(tasks: store.tasks)
        let parent = draft.parentID
        let sendToBobot = draft.agentHelpRequested
        if draft.submit(to: store) {
            if sendToBobot, let task = store.tasks.last, !bobot.assign(task) { draft.pendingBobotTaskID = task.id }
            onCreated(parent)
        }
    }
    private func consumeFocus() {
        guard draft.consumeFocus() else { return }
        let request = draft.focusRequest
        let generation = focusContext.textDismissGeneration
        DispatchQueue.main.async {
            if draft.focusRequest == request && focusContext.textDismissGeneration == generation { nameFocused = true }
        }
    }
}

private struct AgentHelpToggle: View {
    @Binding var isOn: Bool
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            BistButton { isOn.toggle() } label: {
                HStack(spacing: compact ? 4 : 7) {
                    if !compact { Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(isOn ? accent : muted) }
                    Text("Ask Bobot").font(.system(size: compact ? 10 : 11)).fixedSize()
                    if !compact { Spacer() }
                    Capsule().fill(isOn ? accent : muted.opacity(0.25)).frame(width: compact ? 23 : 28, height: compact ? 13 : 16)
                        .overlay(Circle().fill(.white).frame(width: compact ? 9 : 12, height: compact ? 9 : 12).offset(x: isOn ? 5 : -5))
                }.frame(height: compact ? 23 : 25).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Ask Bobot").accessibilityValue(isOn ? "Assign when saved" : "Off")
                .help("Assigns the task name and details to Bobot when saved.")
            if isOn && !compact { Text("Save to queue this task for Bobot. Follow it in Sessions.").font(.system(size: 9)).foregroundColor(muted) }
        }
    }
}

/// A real popover owns dismissal and focus; option rows remain compact and use
/// the same mouse/keyboard treatment as the rest of bist.
private struct TaskTagPicker: View {
    @EnvironmentObject private var focusContext: BistFocusContext
    @State private var presentationID = UUID()
    @ObservedObject var store: AppStore
    @Binding var selectedIDs: [UUID]
    @Binding var newLabelName: String
    @Binding var creatingLabel: Bool
    var compact = false
    @State private var presented = false
    private var selected: [TaskLabel] { store.labels.filter { selectedIDs.contains($0.id) } }
    var body: some View {
        BistButton {
            focusContext.setPickerPresented(id: presentationID, presented: true)
            presented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tag").font(.system(size: 10))
                Text(selected.isEmpty ? "Tag" : selected.map(\.name).joined(separator: ", ")).font(.system(size: 10)).lineLimit(1)
                    .truncationMode(.tail).frame(maxWidth: compact ? 55 : nil, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }.padding(.horizontal, compact ? 6 : 8).frame(width: compact ? 88 : nil, height: compact ? 23 : 25)
                .background((selected.first?.color.tint ?? accent).opacity(0.10), in: Capsule())
        }.buttonStyle(.plain).foregroundColor(selected.first?.color.tint ?? muted)
            .accessibilityLabel("Choose tags").accessibilityValue(selected.map(\.name).joined(separator: ", "))
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tags").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        BistButton("Done") { presented = false }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundColor(accent)
                    }
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.labels) { label in
                                BistButton {
                                    if selectedIDs.contains(label.id) { selectedIDs.removeAll { $0 == label.id } }
                                    else { selectedIDs.append(label.id) }
                                } label: {
                                    HStack(spacing: 7) {
                                        Circle().fill(label.color.tint).frame(width: 7, height: 7)
                                        Text(label.name).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                        if selectedIDs.contains(label.id) { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(accent) }
                                    }.padding(.horizontal, 7).frame(height: 29).contentShape(Rectangle())
                                        .background(selectedIDs.contains(label.id) ? label.color.tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).accessibilityLabel(label.name).accessibilityValue(selectedIDs.contains(label.id) ? "Selected" : "Not selected")
                            }
                        }.background(OverlayScrollStyle())
                    }.frame(height: min(174, CGFloat(max(1, store.labels.count)) * 31))
                    if creatingLabel {
                        NewTagEntry(name: $newLabelName, create: createLabel)
                    } else {
                        BistButton { creatingLabel = true } label: { Label("New label", systemImage: "plus").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundColor(accent)
                    }
                    if let error = store.storeError { Text(error).font(.system(size: 9)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(12).frame(width: 260).foregroundColor(ink)
                    .onExitCommand { presented = false }
            }
            .onChange(of: presented) { focusContext.setPickerPresented(id: presentationID, presented: presented) }
            .onDisappear { focusContext.setPickerPresented(id: presentationID, presented: false) }
            .onAppear(perform: pruneSelection)
            .onChange(of: store.labels.map(\.id)) { pruneSelection() }
    }
    private func pruneSelection() {
        let known = Set(store.labels.map(\.id))
        let retained = selectedIDs.filter { known.contains($0) }
        if retained != selectedIDs { selectedIDs = retained }
    }
    private func createLabel() {
        if store.addLabel(name: newLabelName, color: .amber), let label = store.labels.last {
            if !selectedIDs.contains(label.id) { selectedIDs.append(label.id) }
            newLabelName = ""; creatingLabel = false
        }
    }
}

/// Focus state lives inside the popover's own hosting hierarchy.
private struct NewTagEntry: View {
    @Binding var name: String
    let create: () -> Void
    @FocusState private var focused: Bool
    @State private var isMounted = false

    var body: some View {
        HStack(spacing: 6) {
            TextField("New label name", text: $name).textFieldStyle(.plain).bistTextEntry(focused: $focused).font(.system(size: 11))
                .padding(7).background(surfaceHighlight.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .onSubmit(create).accessibilityLabel("New label name")
            BistButton("Create", action: create).buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundColor(accent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            isMounted = true
            DispatchQueue.main.async { if isMounted { focused = true } }
        }
        .onDisappear { isMounted = false }
    }
}

private struct CompactOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
}

private struct CompactSelection<Value: Hashable>: View {
    @EnvironmentObject private var focusContext: BistFocusContext
    @State private var presentationID = UUID()
    let title: String
    @Binding var selection: Value
    let options: [CompactOption<Value>]
    @State private var presented = false
    var body: some View {
        BistButton {
            focusContext.setPickerPresented(id: presentationID, presented: true)
            presented = true
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 10)).foregroundColor(muted)
                Spacer(minLength: 4)
                Text(options.first(where: { $0.id == selection })?.title ?? "Not available").font(.system(size: 11)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundColor(muted)
            }.padding(.horizontal, 8).frame(height: 29).contentShape(Rectangle())
                .background(surfaceHighlight.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(options.first(where: { $0.id == selection })?.title ?? "Not available")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(options) { option in
                                BistButton { selection = option.id; presented = false } label: {
                                    HStack {
                                        Text(option.title).font(.system(size: 11)).lineLimit(2)
                                        Spacer()
                                        if selection == option.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(accent) }
                                    }.padding(.horizontal, 7).frame(minHeight: 29).contentShape(Rectangle())
                                        .background(selection == option.id ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).accessibilityValue(selection == option.id ? "Selected" : "Not selected")
                            }
                        }.background(OverlayScrollStyle())
                    }.frame(height: min(216, CGFloat(options.count) * 31))
                    BistButton("Cancel") { presented = false }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(muted)
                }.padding(12).frame(width: 270).foregroundColor(ink)
                    .onExitCommand { presented = false }
            }
            .onChange(of: presented) { focusContext.setPickerPresented(id: presentationID, presented: presented) }
            .onDisappear { focusContext.setPickerPresented(id: presentationID, presented: false) }
    }
}

private struct TaskHistoryPane: View {
    @ObservedObject var store: AppStore
    let now: Date
    private var archived: [TaskItem] { store.archivedTasks(at: now) }
    let openTask: (UUID) -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            PanelNavigationButton(title: "Back to tasks", symbol: "chevron.left", action: close)
            HStack { Text("Past tasks").font(.system(size: 17, weight: .medium)); Spacer(); Text("\(archived.count)").font(.system(size: 10)).foregroundColor(muted) }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(archived) { task in
                        HStack(spacing: 8) {
                            BistButton { openTask(task.id) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundColor(accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title).font(.system(size: 11)).lineLimit(1)
                                        Text(task.completedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Completion date unknown")
                                            .font(.system(size: 9)).foregroundColor(muted)
                                    }
                                    Spacer()
                                    AgentDoneMark(task: task)
                                }.padding(.vertical, 7).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            BistButton {
                                _ = store.setUserCompletion(id: task.id, completed: false)
                            } label: {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).frame(width: 26, height: 26)
                            }.buttonStyle(.plain).accessibilityLabel("Reopen \(task.title)")
                        }.padding(.horizontal, 6)
                            .contextMenu {
                                Button("Mark mine unfinished") { _ = store.setUserCompletion(id: task.id, completed: false) }
                                Button("Delete task", role: .destructive) { _ = store.deleteTask(id: task.id) }
                            }
                    }
                    if archived.isEmpty { Text("Completed tasks appear here after 24 hours.").font(.system(size: 11)).foregroundColor(muted).padding(.top, 22) }
                }
            }
            TaskUndoLine(store: store)
        }.padding(.horizontal, 20).padding(.bottom, 19)
    }
}

private struct ChecklistRow: View {
    let entry: ChecklistEntry
    let labels: [TaskLabel]
    let collapsed: Bool
    let reducedMotion: Bool
    let dragProvider: () -> NSItemProvider
    let toggleUser: () -> Void
    let toggleChildren: () -> Void
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .medium))
                .foregroundColor(muted.opacity(hovered ? 1 : 0.5)).frame(width: 14, height: 30)
                .contentShape(Rectangle()).onDrag(dragProvider) {
                    Label(entry.task.title, systemImage: "line.3.horizontal")
                        .font(.system(size: 11)).foregroundColor(ink).padding(9)
                        .background(ivory, in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityLabel("Drag \(entry.task.title) to move or nest")
            BistButton(focusRadius: 5, action: toggleUser) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(entry.task.completed ? accent : surfaceHighlight.opacity(0.35))
                    RoundedRectangle(cornerRadius: 3).strokeBorder(entry.task.completed ? accent : muted.opacity(0.5), lineWidth: 0.8)
                    ChecklistTick().trim(from: 0, to: entry.task.completed ? 1 : 0)
                        .stroke(actionInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).padding(3)
                }.frame(width: 13, height: 13).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(entry.task.completed ? "Mark mine unfinished" : "Mark mine done"): \(entry.task.title)")
                .accessibilityValue(entry.task.completed ? "Done by me" : "Not done by me")
                .accessibilityHint("Subtasks and agent results stay independent.")
            Color.clear.frame(width: CGFloat(min(entry.depth, 5)) * 10)
            if entry.hasChildren {
                BistButton(focusRadius: 4, action: toggleChildren) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 7, weight: .semibold))
                        .foregroundColor(muted).frame(width: 12, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(collapsed ? "Expand" : "Collapse") subtasks of \(entry.task.title)")
            } else { Color.clear.frame(width: 12) }
            BistButton(focusRadius: 4, action: open) {
                Text(entry.task.title).font(.system(size: 11, weight: .regular))
                    .foregroundColor(entry.task.completed ? muted : ink).strikethrough(entry.task.completed, color: muted.opacity(0.6))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Details for \(entry.task.title), level \(entry.depth + 1)")
            if let label = labels.first {
                HStack(spacing: 3) {
                    Circle().fill(label.color.tint).frame(width: 4, height: 4)
                    Text(label.name).font(.system(size: 8, weight: .medium)).lineLimit(1)
                    if labels.count > 1 { Text("+\(labels.count - 1)").font(.system(size: 7)) }
                }.foregroundColor(ink.opacity(0.8)).padding(.horizontal, 5).frame(height: 16)
                    .background(label.color.tint.opacity(0.13), in: Capsule())
                    .frame(maxWidth: 78).padding(.leading, 4)
                    .accessibilityLabel("Tags: \(labels.map(\.name).joined(separator: ", "))")
            }
            AgentDoneMark(task: entry.task).frame(width: 32, height: 26)
        }
        .frame(height: 30)
        .background(labels.first.map { $0.color.tint.opacity(hovered ? 0.22 : 0.15) } ?? (hovered ? surfaceHighlight.opacity(0.36) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.045)).frame(height: 0.5).padding(.leading, 38).allowsHitTesting(false) }
        .onHover { hovered = $0 }
        .animation(reducedMotion ? nil : .easeOut(duration: 0.14), value: entry.task.completed)
    }
}

private struct ChecklistTick: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct AgentDoneMark: View {
    let task: TaskItem
    @EnvironmentObject private var bobot: BobotStore
    var body: some View {
        if bobot.agentAssigned(task) {
            let status = bobot.agentCompletionStatus(for: task)
            Group {
                if status.done {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundColor(accent)
                } else {
                    Circle().strokeBorder(muted.opacity(0.3), lineWidth: 0.8).frame(width: 10, height: 10)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent completion for \(task.title)")
            .accessibilityValue(status.value)
            .accessibilityHint(status.hint)
        }
    }
}

private struct TaskUndoLine: View {
    @ObservedObject var store: AppStore
    var body: some View {
        if let error = store.storeError {
            Text(error).font(.system(size: 10)).foregroundColor(.red).frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
        } else if store.canUndo {
            HStack(spacing: 7) {
                Text(store.lastActionLabel ?? "Updated").font(.system(size: 10)).foregroundColor(muted).lineLimit(1)
                Spacer()
                BistButton("Undo") { _ = store.undo() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundColor(accent)
                    .accessibilityLabel("Undo last local action")
            }.frame(height: 22)
        }
    }
}

struct TaskInspector: View {
    let taskID: UUID
    @ObservedObject var store: AppStore
    let close: () -> Void
    let reviewAgentResults: () -> Void
    let drafts: TaskInspectorDrafts

    var body: some View {
        if let task = store.tasks.first(where: { $0.id == taskID }) {
            TaskInspectorContent(taskID: taskID, store: store, close: close,
                                 reviewAgentResults: reviewAgentResults, draft: drafts.draft(for: task))
        } else {
            VStack(spacing: 12) {
                Text("This task is no longer in your list.").font(.system(size: 12)).foregroundColor(muted)
                BistButton("Back to tasks", action: close).buttonStyle(TactileStyle(compact: true))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TaskInspectorContent: View {
    @EnvironmentObject private var bobot: BobotStore
    let taskID: UUID
    @ObservedObject var store: AppStore
    let close: () -> Void
    let reviewAgentResults: () -> Void
    @ObservedObject var draft: TaskInspectorDraft
    @State private var showLabels = false
    @State private var localError: String?
    @State private var movePresented = false

    private var task: TaskItem? { store.tasks.first { $0.id == taskID } }
    private var subtasks: [TaskItem] { ActiveChecklist(tasks: store.tasks, collapsedParents: []).children(of: taskID) }
    private var parentChoices: [TaskItem] {
        var descendants: Set<UUID> = [taskID]
        var changed = true
        while changed {
            let old = descendants.count
            store.tasks.filter { $0.parentID.map(descendants.contains) ?? false }.forEach { descendants.insert($0.id) }
            changed = old != descendants.count
        }
        return store.tasks.filter { !descendants.contains($0.id) }
    }

    var body: some View {
        Group {
            if showLabels {
                TaskLabelManager(store: store) { showLabels = false }
            } else if let task {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PanelNavigationButton(title: "Back to tasks", symbol: "chevron.left", action: close)
                            .accessibilityHint("Returns to your list. Unsaved text stays in this draft.")
                        Spacer()
                        if hasTextChanges {
                            Text("Unsaved draft").font(.system(size: 10, weight: .medium)).foregroundColor(muted)
                                .accessibilityLabel("Unsaved draft. Save changes to update the task.")
                        }
                        if task.isSample { Text("Sample task").font(.system(size: 9)).foregroundColor(muted) }
                    }.padding(.bottom, 12)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if draft.incoming != nil { conflictNotice }
                            field("Task name", text: $draft.title)
                            BistButton { draft.detailsExpanded.toggle() } label: {
                                Label("Details", systemImage: draft.detailsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10)).frame(height: 22)
                            }.buttonStyle(.plain).foregroundColor(muted)
                                .accessibilityLabel("\(draft.detailsExpanded ? "Hide" : "Show") optional details")
                            if draft.detailsExpanded {
                                TextEditor(text: $draft.notes).font(.system(size: 11)).bistTextEntry().scrollContentBackground(.hidden)
                                    .frame(height: 70).padding(6).background(surfaceHighlight.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                                    .accessibilityLabel("Optional task details")
                            }
                            TaskTagPicker(store: store,
                                          selectedIDs: Binding(get: { task.labelIDs }, set: { _ = store.setTaskLabels(id: taskID, labelIDs: $0) }),
                                          newLabelName: $draft.newLabelName, creatingLabel: $draft.creatingLabel)
                            AgentHelpToggle(isOn: $draft.agentHelpRequested)
                            BobotAssignment(task: task)
                            HStack(spacing: 16) {
                                BistButton { movePresented = true } label: {
                                    Label("Move to…", systemImage: "arrow.turn.down.right")
                                }.buttonStyle(.plain).foregroundColor(accent)
                                Spacer()
                                Menu {
                                    Button("Delete task · keep subtasks", role: .destructive) {
                                        if store.deleteTask(id: taskID) { close() }
                                    }
                                    if !subtasks.isEmpty {
                                        Button("Delete task and subtasks", role: .destructive) {
                                            if store.deleteTask(id: taskID, includingSubtasks: true) { close() }
                                        }
                                    }
                                } label: { Label("Delete", systemImage: "trash") }
                                .menuStyle(.borderlessButton).fixedSize().foregroundColor(muted)
                                .accessibilityLabel("Delete task")
                            }.font(.system(size: 11)).frame(minHeight: 30)
                            .popover(isPresented: $movePresented) {
                                TaskMovePicker(store: store, taskID: taskID) { movePresented = false }
                            }
                            BistButton { draft.moreExpanded.toggle() } label: {
                                Label("More", systemImage: draft.moreExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10)).frame(height: 25)
                            }.buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("\(draft.moreExpanded ? "Hide" : "Show") more task settings")
                            if draft.moreExpanded {
                                HStack(spacing: 6) {
                                    BistButton { _ = store.setUserCompletion(id: taskID, completed: !task.completed) } label: {
                                        Label("I’m done", systemImage: task.completed ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 11)).foregroundColor(task.completed ? accent : ink)
                                    }.buttonStyle(.plain).accessibilityValue(task.completed ? "Checked" : "Unchecked")
                                    Spacer()
                                    if bobot.agentAssigned(task) {
                                        AgentDoneMark(task: task)
                                        Text("Agent done").font(.system(size: 11)).foregroundColor(muted)
                                    }
                                }.frame(height: 24)
                                field("Next action", text: $draft.nextAction, prompt: "One concrete next step")
                                organization(task)
                                subtasksSection
                                sessionSection(task)
                                field("Source", text: $draft.source, prompt: "Added by you")
                                field("Source link", text: $draft.sourceURL, prompt: "https://…")
                                if let url = AppStore.safeURL(draft.sourceURL) {
                                    BistButton { NSWorkspace.shared.open(url) } label: { Label("Open source", systemImage: "arrow.up.right").font(.system(size: 10)) }
                                        .buttonStyle(.plain).foregroundColor(accent)
                                }
                                BistButton("Manage labels") { showLabels = true }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(accent)
                            }
                        }.padding(.bottom, 10)
                    }
                    if let error = localError ?? store.storeError { Text(error).font(.system(size: 10)).foregroundColor(.red).padding(.top, 5) }
                    HStack {
                        Text("Text and agent help need Save. Back keeps your draft.").font(.system(size: 10)).foregroundColor(muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        BistButton("Save changes") { save() }.buttonStyle(TactileStyle(prominent: true, compact: true))
                            .font(.system(size: 11)).disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.top, 10)
                }.padding(.horizontal, 21).padding(.bottom, 18)
            } else {
                VStack(spacing: 12) {
                    Text("This task is no longer in your list.").font(.system(size: 12)).foregroundColor(muted)
                    BistButton("Back to tasks", action: close).buttonStyle(TactileStyle(compact: true))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if let task { draft.reconcile(with: task) } }
        .onChange(of: task.map { InspectorText(task: $0) }) { if let task { draft.reconcile(with: task) } }
    }

    private var conflictNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("This task’s saved text changed. Your draft is still here.").font(.system(size: 10)).foregroundColor(ink)
            HStack(spacing: 12) {
                BistButton("Keep my text") { draft.keepDraft(); localError = nil }
                BistButton("Use latest text") { draft.useLatest(); localError = nil }
            }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundColor(accent)
        }.padding(9).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func organization(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            CompactSelection(title: "Parent", selection: Binding<UUID?>(get: { task.parentID }, set: { _ = store.reparentTask(id: taskID, parentID: $0) }),
                             options: [CompactOption(id: Optional<UUID>.none, title: "None · top-level task")] + parentChoices.map { CompactOption(id: Optional($0.id), title: $0.title) })
            CompactSelection(title: "List", selection: Binding(get: { task.horizon }, set: { _ = store.moveTask(id: taskID, to: .list($0)) }),
                             options: TaskHorizon.allCases.map { CompactOption(id: $0, title: $0.title) })
            if task.parentID != nil {
                Text("Changing list moves this task and its subtasks to the top level.").font(.system(size: 9)).foregroundColor(muted)
            }
        }
    }

    private var subtasksSection: some View {
        TaskRetentionClock(tasks: store.tasks) { now in
            subtasksSection(at: now)
        }
    }

    private func subtasksSection(at now: Date) -> some View {
        let subtasks = ActiveChecklist(tasks: store.tasks, collapsedParents: [], now: now).children(of: taskID)
        return VStack(alignment: .leading, spacing: 6) {
            caption("Subtasks")
            ForEach(subtasks) { subtask in
                HStack(spacing: 6) {
                    BistButton { _ = store.setUserCompletion(id: subtask.id, completed: !subtask.completed) } label: {
                        Image(systemName: subtask.completed ? "checkmark.square.fill" : "square").foregroundColor(subtask.completed ? accent : muted).frame(width: 22, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("\(subtask.completed ? "Reopen" : "Complete") subtask \(subtask.title)")
                    Text(subtask.title).font(.system(size: 10)).lineLimit(1).strikethrough(subtask.completed)
                    Spacer()
                    AgentDoneMark(task: subtask)
                }.frame(height: 24)
            }
            TaskComposer(store: store, draft: draft.subtaskCreation)
            if !subtasks.isEmpty { Text("Your checkmark does not complete subtasks.").font(.system(size: 9)).foregroundColor(muted) }
        }
    }

    private func sessionSection(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            caption("Agent session")
            CompactSelection(title: "Session", selection: Binding<UUID?>(get: { task.linkedSessionID }, set: { _ = store.linkTask(id: taskID, sessionID: $0) }),
                             options: [CompactOption(id: Optional<UUID>.none, title: "No session linked")] + store.sessions.map { CompactOption(id: Optional($0.id), title: "\($0.provider.displayName): \($0.title)") })
                .disabled(task.agentCompletion != nil)
            if task.agentCompletion != nil { Text("Clear the local review before changing its session.").font(.system(size: 9)).foregroundColor(muted) }
            Text("A saved link only. It does not start an agent or report live activity.").font(.system(size: 9)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            if let result = task.agentCompletion {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Result reviewed by you", systemImage: "checkmark.seal.fill").font(.system(size: 10, weight: .medium)).foregroundColor(accent)
                    Text(result.summary).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    Text("Observed: \(result.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundColor(muted)
                    Text("Reviewed: \(result.reviewedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 9)).foregroundColor(muted)
                    if let url = AppStore.safeURL(result.artifactURL) {
                        BistButton { NSWorkspace.shared.open(url) } label: { Label("Open result artifact", systemImage: "arrow.up.right").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundColor(accent)
                    }
                    BistButton("Clear local review") { _ = store.clearAgentCompletion(taskID: taskID) }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundColor(muted)
                        .help("Remove this local evidence record; your own completion stays unchanged.")
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Completed Bobot assignments check Agent automatically. Check Me when you’ve reviewed and finished your part.").font(.system(size: 9)).foregroundColor(muted)
            }
            BistButton(hasTextChanges ? "Save & review results" : "Review agent results") {
                if persistText() { reviewAgentResults() }
            }.buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundColor(accent)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(muted)
    }
    private func field(_ name: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(name)
            TextField(prompt, text: text).textFieldStyle(.plain).bistTextEntry().font(.system(size: 11)).padding(8)
                .background(surfaceHighlight.opacity(0.4), in: RoundedRectangle(cornerRadius: 7)).accessibilityLabel(name)
        }
    }
    private var hasTextChanges: Bool { draft.isDirty }
    private func save() {
        let assign = draft.agentHelpRequested && (task?.agentHelpRequested != true || bobot.latest(for: taskID) == nil)
        if persistText() {
            if assign, let task {
                if !bobot.assign(task) { localError = bobot.error; return }
            }
            close()
        }
    }
    private func persistText() -> Bool {
        localError = nil
        guard let task else { return false }
        draft.reconcile(with: task)
        guard draft.incoming == nil else { localError = "Choose whether to keep your text or use the latest saved text before saving."; return false }
        let link = draft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.isEmpty || AppStore.safeURL(link) != nil else { localError = "Use a full http or https source link without credentials."; return false }
        return draft.save(to: store, taskID: taskID)
    }
}

private struct TaskLabelManager: View {
    @ObservedObject var store: AppStore
    let close: () -> Void
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var color: TaskLabelColor = .amber
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelNavigationButton(title: "Back", symbol: "chevron.left", action: close)
            HStack { Text("Tags").font(.system(size: 17, weight: .medium)); Spacer(); Text("\(store.labels.count)").font(.system(size: 10)).foregroundColor(muted) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.labels) { label in
                        HStack(spacing: 7) {
                            Circle().fill(label.color.tint).frame(width: 7, height: 7)
                            BistButton {
                                editingID = label.id; name = label.name; color = label.color; nameFocused = true
                            } label: { Text(label.name).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).frame(height: 29).contentShape(Rectangle()) }
                                .buttonStyle(.plain).accessibilityLabel("Edit \(label.name) label")
                            BistButton {
                                if store.deleteLabel(id: label.id), editingID == label.id { reset() }
                            } label: { Image(systemName: "trash").font(.system(size: 10)).frame(width: 26, height: 29) }
                                .buttonStyle(.plain).foregroundColor(muted).accessibilityLabel("Delete \(label.name) label").help("Remove this label from all tasks")
                        }.padding(.horizontal, 7)
                            .background(editingID == label.id ? surfaceHighlight.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    if store.labels.isEmpty { Text("Add your first label below.").font(.system(size: 11)).foregroundColor(muted).padding(.vertical, 20) }
                }
            }
            Text(editingID == nil ? "New label" : "Edit label").font(.system(size: 10, weight: .medium)).foregroundColor(muted)
            TextField("Label name", text: $name).textFieldStyle(.plain).bistTextEntry(focused: $nameFocused).font(.system(size: 12)).padding(9)
                .background(surfaceHighlight.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)).onSubmit(save).accessibilityLabel("Label name")
            HStack(spacing: 8) {
                ForEach(TaskLabelColor.allCases) { candidate in
                    BistButton(focusRadius: 12) { color = candidate } label: {
                        Circle().fill(candidate.tint).frame(width: 17, height: 17)
                            .overlay { if color == candidate { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(actionInk) } }
                            .frame(width: 25, height: 25).contentShape(Circle())
                    }.buttonStyle(.plain).accessibilityLabel("\(candidate.rawValue.capitalized) color").accessibilityValue(color == candidate ? "Selected" : "Not selected")
                }
            }
            HStack {
                if editingID != nil { BistButton("Cancel edit") { reset() }.buttonStyle(.plain).font(.system(size: 10)).foregroundColor(muted) }
                Spacer()
                BistButton(editingID == nil ? "Create label" : "Save label", action: save)
                    .buttonStyle(TactileStyle(prominent: true, compact: true)).font(.system(size: 11))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            TaskUndoLine(store: store)
        }.padding(.horizontal, 22).padding(.bottom, 20)
    }
    private func save() {
        let success: Bool
        if let editingID { success = store.updateLabel(id: editingID, name: name, color: color) }
        else { success = store.addLabel(name: name, color: color) }
        if success { reset() }
    }
    private func reset() { editingID = nil; name = ""; color = .amber }
}

/// Projection only: archiving never rewrites data or adds an Undo action.
private struct TaskRetentionClock<Content: View>: View {
    let tasks: [TaskItem]
    @ViewBuilder let content: (Date) -> Content
    @State private var now = Date()

    var body: some View {
        content(now)
            .task(id: tasks.compactMap(\.archiveDate)) {
                while !Task.isCancelled {
                    now = Date()
                    guard let next = tasks.compactMap(\.archiveDate).filter({ $0 > now }).min() else { return }
                    do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) }
                    catch { return }
                }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in now = Date() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = Date() }
    }
}
