import SwiftUI

struct PhoneRootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var note: NoteStore
    @ObservedObject var sync: BistSyncCoordinator

    var body: some View {
        TabView {
            PhoneTasksView(store: store, sync: sync)
                .tabItem { Label("Tasks", systemImage: "checklist") }
            PhoneNoteView(note: note)
                .tabItem { Label("Note", systemImage: "note.text") }
            PhoneSettingsView(store: store, sync: sync)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct PhoneTasksView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var sync: BistSyncCoordinator
    @State private var collapsed = Set<UUID>()
    @AppStorage("phone.capture.title") private var capture = ""
    @AppStorage("phone.capture.horizon") private var captureHorizon = TaskHorizon.shortTerm
    @State private var deletion: TaskItem?
    @State private var showTags = false
    @FocusState private var captureFocused: Bool

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                List {
                    if let error = store.storeError {
                        Section { PhoneErrorView(message: error) { _ = store.reload() } }
                    }
                    if store.tasks.isEmpty {
                        ContentUnavailableView("A little space to think", systemImage: "checklist",
                                               description: Text("Add a task below. It saves on this iPhone, even while you’re offline."))
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(TaskHorizon.allCases) { horizon in
                            let entries = ActiveChecklist(tasks: store.tasks, collapsedParents: collapsed, now: timeline.date).entries(for: horizon)
                            Section(horizon.title) {
                                if entries.isEmpty { Text("Nothing here yet").foregroundStyle(.secondary) }
                                ForEach(entries) { entry in
                                    taskRow(entry)
                                        .contextMenu { taskActions(entry.task) }
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button("Delete", role: .destructive) { deletion = entry.task }
                                        }
                                }
                            }
                        }
                        Section {
                            NavigationLink {
                                PhoneHistoryView(store: store)
                            } label: {
                                Label("Past tasks", systemImage: "clock.arrow.circlepath")
                            }.frame(minHeight: 44)
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .refreshable { await sync.syncNow() }
            }
            .navigationTitle("bist")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showTags = true } label: { Image(systemName: "tag") }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Manage tags")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { _ = store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!store.canUndo)
                        .accessibilityLabel("Undo task change")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { captureBar }
            .sheet(isPresented: $showTags) { PhoneTagsView(store: store) }
            .confirmationDialog("Delete this task?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                if let task = deletion {
                    Button("Delete task, keep subtasks", role: .destructive) { _ = store.deleteTask(id: task.id); deletion = nil }
                    if store.tasks.contains(where: { $0.parentID == task.id }) {
                        Button("Delete task and subtasks", role: .destructive) { _ = store.deleteTask(id: task.id, includingSubtasks: true); deletion = nil }
                    }
                }
                Button("Cancel", role: .cancel) { deletion = nil }
            }
        }
    }

    private var captureBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    Picker("List", selection: $captureHorizon) {
                        ForEach(TaskHorizon.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: captureHorizon == .shortTerm ? "sun.max" : "calendar") }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Add to \(captureHorizon.title)")
                TextField("Add a task…", text: $capture, axis: .vertical)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($captureFocused)
                    .onSubmit(addTask)
                    .accessibilityLabel("New task title")
                    .accessibilityIdentifier("phone.capture")
                Button(action: addTask) { Image(systemName: "plus.circle.fill").font(.title2) }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Add task")
                    .accessibilityIdentifier("phone.capture.add")
                    .disabled(capture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal).padding(.vertical, 8)
        }.background(.regularMaterial)
    }

    private func addTask() {
        if store.addTask(title: capture, horizon: captureHorizon) { capture = "" }
    }

    private func taskRow(_ entry: ChecklistEntry) -> some View {
        HStack(spacing: 0) {
            if entry.hasChildren {
                Button {
                    if !collapsed.insert(entry.id).inserted { collapsed.remove(entry.id) }
                } label: {
                    Image(systemName: collapsed.contains(entry.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(collapsed.contains(entry.id) ? "Expand subtasks" : "Collapse subtasks")
            }
            Button {
                _ = store.setUserCompletion(id: entry.id, completed: !entry.task.completed)
            } label: {
                Image(systemName: entry.task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }.buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(entry.task.completed ? "Reopen \(entry.task.title)" : "Complete \(entry.task.title)")
                .accessibilityIdentifier("phone.task.complete")
                .accessibilityValue(entry.task.completed ? "Completed" : "Outstanding")
            NavigationLink {
                PhoneTaskDetail(store: store, task: entry.task)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.task.title).strikethrough(entry.task.completed)
                        .foregroundStyle(entry.task.completed ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.task.labelIDs.isEmpty {
                        Text(store.labels.filter { entry.task.labelIDs.contains($0.id) }.map(\.name).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if entry.task.agentCompletion != nil {
                        Label("Agent result available", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }.frame(minHeight: 44)
                .accessibilityIdentifier("phone.task.open")
        }.padding(.leading, CGFloat(min(entry.depth, 3)) * 12)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func taskActions(_ task: TaskItem) -> some View {
        Menu("Move to") {
            ForEach(TaskHorizon.allCases) { horizon in
                Button(horizon.title) { _ = store.moveTask(id: task.id, to: .list(horizon)) }
            }
            let siblings = store.tasks.filter { $0.parentID == task.parentID && $0.horizon == task.horizon && !$0.completed }
            if let index = siblings.firstIndex(where: { $0.id == task.id }) {
                if index > 0 {
                    Button("Move up") { _ = store.moveTask(id: task.id, to: .before(siblings[index - 1].id)) }
                }
                if index + 1 < siblings.count {
                    Button("Move down") { _ = store.moveTask(id: task.id, to: .after(siblings[index + 1].id)) }
                }
            }
        }
        Button("Delete", role: .destructive) { deletion = task }
    }
}

struct PhoneTaskDetail: View {
    @ObservedObject var store: AppStore
    let taskID: UUID
    @State private var draft: PhoneTaskTextDraft
    @State private var localError: String?
    @State private var childTitle = ""
    @State private var confirmReload = false
    @Environment(\.dismiss) private var dismiss

    init(store: AppStore, task: TaskItem) {
        self.store = store
        taskID = task.id
        let key = "phone.task.draft." + task.id.uuidString
        let saved = PhoneLaunchConfiguration.preferences.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(PhoneTaskTextDraft.self, from: $0) }
        _draft = State(initialValue: saved ?? PhoneTaskTextDraft(task))
    }
    private var current: TaskItem? { store.tasks.first { $0.id == taskID } }

    var body: some View {
        Form {
            if let task = current {
                if let error = localError ?? store.storeError {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("Task") {
                    TextField("Title", text: $draft.title, axis: .vertical).accessibilityLabel("Task title").accessibilityIdentifier("phone.task.title")
                    TextField("Details", text: $draft.notes, axis: .vertical).lineLimit(3...12).accessibilityLabel("Task details").accessibilityIdentifier("phone.task.notes")
                    TextField("Next action", text: $draft.nextAction, axis: .vertical).lineLimit(1...4)
                    Toggle("I’m done", isOn: Binding(get: { task.completed }, set: { _ = store.setUserCompletion(id: task.id, completed: $0) }))
                }
                Section("Organization") {
                    Picker("List", selection: Binding(get: { task.horizon }, set: { _ = store.setTaskHorizon(id: task.id, horizon: $0) })) {
                        ForEach(TaskHorizon.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Parent", selection: Binding<UUID?>(get: { task.parentID }, set: { _ = store.reparentTask(id: task.id, parentID: $0) })) {
                        Text("None").tag(Optional<UUID>.none)
                        ForEach(PhoneTaskNavigation.parentChoices(for: task.id, tasks: store.tasks)) { parent in
                            Text(parent.title).tag(Optional(parent.id))
                        }
                    }
                    NavigationLink("Tags") { PhoneTaskTagsView(store: store, taskID: task.id) }
                }
                Section("Add a subtask") {
                    HStack {
                        TextField("Subtask title…", text: $childTitle, axis: .vertical).accessibilityLabel("Subtask title")
                        Button("Add") {
                            if store.addTask(title: childTitle, parentID: task.id, horizon: task.horizon) { childTitle = "" }
                        }.frame(minWidth: 44, minHeight: 44)
                            .disabled(childTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let result = task.agentCompletion {
                    Section("Agent result") {
                        Text(result.summary).textSelection(.enabled)
                        if let url = AppStore.safeURL(result.artifactURL) { Link("Open result", destination: url).frame(minHeight: 44) }
                        Text("Your checkmark stays under your control.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Reload saved text") { confirmReload = true }
                    ShareLink("Share draft", item: [draft.title, draft.notes, draft.nextAction].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                }
            } else {
                Section {
                    Text("This task was removed on another device. Your draft is still here.").foregroundStyle(.secondary)
                    Text(draft.title).textSelection(.enabled)
                    Text(draft.notes).textSelection(.enabled)
                    ShareLink("Share draft", item: [draft.title, draft.notes, draft.nextAction].joined(separator: "\n\n"))
                }
            }
        }
        .navigationTitle("Task details")
        .onChange(of: draft) { _, value in
            let key = "phone.task.draft." + taskID.uuidString
            if value.hasChanges, let data = try? JSONEncoder().encode(value) {
                PhoneLaunchConfiguration.preferences.set(data, forKey: key)
            } else { PhoneLaunchConfiguration.preferences.removeObject(forKey: key) }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(current == nil).accessibilityIdentifier("phone.task.save")
                    .frame(minHeight: 44)
            }
        }
        .confirmationDialog("Replace this draft with the saved text?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Reload saved text", role: .destructive) {
                if let task = current { draft = PhoneTaskTextDraft(task); localError = nil }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        guard let task = current else { return }
        do {
            let text = try draft.merging(into: task)
            if store.updateTask(id: task.id, title: text.title, notes: text.notes, nextAction: text.nextAction,
                                source: task.source, sourceURL: task.sourceURL) {
                localError = nil
                PhoneLaunchConfiguration.preferences.removeObject(forKey: "phone.task.draft." + taskID.uuidString)
                dismiss()
            }
        } catch { localError = error.localizedDescription }
    }
}

struct PhoneHistoryView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            List {
                let tasks = store.archivedTasks(at: timeline.date)
                if tasks.isEmpty {
                    ContentUnavailableView("No past tasks yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Completed tasks stay in your list for 24 hours, then appear here."))
                }
                if let error = store.storeError { Text(error).foregroundStyle(.red) }
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink { PhoneTaskDetail(store: store, task: task) } label: { Text(task.title) }
                        HStack {
                            if let date = task.completedAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            else { Text("Completion time unknown").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Reopen") { _ = store.setUserCompletion(id: task.id, completed: false) }
                                .buttonStyle(.borderless).frame(minHeight: 44)
                        }
                    }
                }
            }
        }.navigationTitle("Past tasks")
    }
}

struct PhoneNoteView: View {
    @ObservedObject var note: NoteStore
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = note.error {
                    PhoneErrorView(message: error, retry: note.canRetrySave ? { note.save() } : nil).padding()
                }
                TextEditor(text: Binding(get: { note.text }, set: { note.update($0) }))
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Scratchpad").accessibilityIdentifier("phone.note")
            }.navigationTitle("Note")
                .toolbar(content: noteToolbar)
        }
    }
    @ToolbarContentBuilder
    private func noteToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: note.text) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share note").disabled(note.text.isEmpty)
        }
    }

}

struct PhoneTaskTagsView: View {
    @ObservedObject var store: AppStore
    let taskID: UUID
    var body: some View {
        List {
            if let task = store.tasks.first(where: { $0.id == taskID }) {
                if let error = store.storeError { Text(error).foregroundStyle(.red) }
                ForEach(store.labels) { label in
                    Toggle(isOn: Binding(get: { task.labelIDs.contains(label.id) }, set: { enabled in
                        var ids = task.labelIDs
                        if enabled { ids.append(label.id) } else { ids.removeAll { $0 == label.id } }
                        _ = store.setTaskLabels(id: task.id, labelIDs: ids)
                    })) { PhoneTagLabel(label: label) }.frame(minHeight: 44)
                }
                if store.labels.isEmpty { Text("Create tags in Settings.").foregroundStyle(.secondary) }
            } else { Text("This task was removed.").foregroundStyle(.secondary) }
        }.navigationTitle("Task tags")
    }
}

struct PhoneTagsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = TaskLabelColor.blue
    @State private var deleting: TaskLabel?
    var body: some View {
        NavigationStack {
            Form {
                if let error = store.storeError { Text(error).foregroundStyle(.red) }
                Section("Tags") {
                    ForEach(store.labels) { label in
                        NavigationLink { PhoneLabelEditor(store: store, label: label) } label: { PhoneTagLabel(label: label) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { deleting = label }
                            }
                    }
                }
                Section("New tag") {
                    TextField("Name", text: $name).accessibilityLabel("New tag name")
                    Picker("Color", selection: $color) {
                        ForEach(TaskLabelColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Button("Add tag") {
                        if store.addLabel(name: name, color: color) { name = "" }
                    }.frame(minHeight: 44).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("Tags")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
                .confirmationDialog("Remove this tag from all tasks?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    if let label = deleting { Button("Delete tag", role: .destructive) { _ = store.deleteLabel(id: label.id); deleting = nil } }
                    Button("Cancel", role: .cancel) { deleting = nil }
                }
        }
    }
}

struct PhoneLabelEditor: View {
    @ObservedObject var store: AppStore
    let label: TaskLabel
    @State private var name: String
    @State private var color: TaskLabelColor
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, label: TaskLabel) {
        self.store = store; self.label = label
        _name = State(initialValue: label.name); _color = State(initialValue: label.color)
    }
    var body: some View {
        Form {
            if let error = store.storeError { Text(error).foregroundStyle(.red) }
            TextField("Name", text: $name).accessibilityLabel("Tag name")
            Picker("Color", selection: $color) { ForEach(TaskLabelColor.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            Button("Save tag") { if store.updateLabel(id: label.id, name: name, color: color) { dismiss() } }.frame(minHeight: 44)
        }.navigationTitle("Edit tag")
    }
}

struct PhoneSettingsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var sync: BistSyncCoordinator
    @State private var showTags = false
    @State private var confirmCloudRecovery = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync with iCloud", isOn: Binding(get: { sync.enabled }, set: sync.setEnabled))
                        .disabled(!sync.isAvailable)
                        .accessibilityIdentifier("phone.sync.toggle")
                    LabeledContent("Status", value: sync.status)
                    if sync.pendingCount > 0 { LabeledContent("Pending changes", value: "\(sync.pendingCount)") }
                    if let date = sync.lastSyncedAt {
                        LabeledContent("Last synced") { Text(date, style: .relative) }
                    }
                    if let error = sync.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if sync.recoveryRequired {
                        Button("Restore local data to iCloud") { confirmCloudRecovery = true }
                            .disabled(!sync.enabled || !sync.isAvailable).frame(minHeight: 44)
                    }
                    Button("Sync now") { Task { await sync.syncNow() } }
                        .disabled(!sync.enabled || !sync.isAvailable).frame(minHeight: 44)
                } header: { Text("iCloud") } footer: {
                    Text(sync.isAvailable
                         ? "Use the same iCloud account on your Mac and iPhone. Changes save locally first. Background sync may take time."
                         : "This build saves locally. Install a build with iCloud enabled to connect your Mac and iPhone.")
                }
                if !sync.noteVersions.isEmpty {
                    Section {
                        DisclosureGroup("Saved note versions") {
                            ForEach(Array(sync.noteVersions.enumerated()), id: \.offset) { item in
                                NavigationLink("Note version \(item.offset + 1)") { PhoneNoteVersion(sync: sync, text: item.element) }
                            }
                        }
                    }
                }
                Section {
                    Button("Manage tags") { showTags = true }.frame(minHeight: 44)
                    Button("Reload saved data") { _ = store.reload() }.frame(minHeight: 44)
                    if let error = store.storeError { Text(error).foregroundStyle(.red) }
                } header: { Text("Local data") } footer: {
                    Text("Tasks and notes work offline. Agent sessions stay on the Mac. Syncing a task does not run an agent.")
                }
            }.navigationTitle("Settings")
                .sheet(isPresented: $showTags) { PhoneTagsView(store: store) }
                .confirmationDialog("Restore local data to iCloud?", isPresented: $confirmCloudRecovery, titleVisibility: .visible) {
                    Button("Restore local data") { Task { await sync.recoverCloudData() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("A backup is saved on this iPhone, then your current local tasks and note are uploaded to your iCloud account.")
                }
        }
    }
}

struct PhoneNoteVersion: View {
    @ObservedObject var sync: BistSyncCoordinator
    let text: String
    @State private var confirmRestore = false
    var body: some View {
        ScrollView { Text(text.isEmpty ? "Empty note" : text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("Recovered note")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share recovered note")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { confirmRestore = true }.frame(minHeight: 44)
                }
            }
            .confirmationDialog("Use this version as your note?", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore note") { sync.restoreNoteVersion(text) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your current note remains in recovered versions.") }
    }
}

struct PhoneErrorView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).foregroundStyle(.red).textSelection(.enabled)
            if let retry { Button("Retry", action: retry).frame(minHeight: 44) }
        }.accessibilityElement(children: .contain)
    }
}

struct PhoneTagLabel: View {
    let label: TaskLabel
    private var color: Color {
        switch label.color {
        case .lavender: return .purple
        case .blue: return .blue
        case .green: return .green
        case .amber: return .orange
        case .rose: return .pink
        case .gray: return .gray
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(label.name)
        }
    }
}
