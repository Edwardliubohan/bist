import Foundation

@main
struct TaskViewStateTests {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            guard value() else { fatalError("FAIL: \(label)") }
        }

        var task = TaskItem(title: "Original", nextAction: "Read", source: "Sample")
        let cache = TaskInspectorDrafts()
        let draft = cache.draft(for: task)
        expect(!draft.isDirty, "new draft starts clean")
        draft.title = "My draft"
        draft.subtaskTitle = "Unsubmitted child"
        expect(cache.draft(for: task) === draft, "navigation preserves same draft object")
        expect(cache.draft(for: task).subtaskTitle == "Unsubmitted child", "subtask capture persists")

        task.completed = true
        draft.reconcile(with: task)
        expect(draft.title == "My draft" && draft.incoming == nil, "metadata cannot erase dirty text")
        task.title = "External revision"
        draft.reconcile(with: task)
        expect(draft.title == "My draft" && draft.incoming != nil, "dirty external revision produces conflict")
        draft.keepDraft()
        expect(draft.title == "My draft" && draft.incoming == nil && draft.isDirty, "keep text resolves explicitly")
        draft.reconcile(with: task)
        expect(draft.incoming == nil && draft.title == "My draft", "resolved conflict stays resolved")

        task.notes = "New saved notes"
        draft.reconcile(with: task)
        expect(draft.incoming != nil, "another external text change conflicts again")
        draft.useLatest()
        expect(draft.title == task.title && draft.notes == task.notes && !draft.isDirty, "use latest explicitly loads saved text")
        task.title = "Clean refresh"
        draft.reconcile(with: task)
        expect(draft.title == "Clean refresh" && !draft.isDirty, "clean draft follows external text")

        draft.title = "Saved next"
        task.title = "Saved next"
        draft.acceptedSave(task)
        expect(!draft.isDirty && draft.incoming == nil, "successful save resets baseline")
        draft.title = "Draft before undo"
        task.title = "External change"
        draft.reconcile(with: task)
        expect(draft.incoming != nil, "new external change conflicts")
        task.title = "Saved next"
        draft.reconcile(with: task)
        expect(draft.incoming == nil && draft.title == "Draft before undo", "external undo resolves conflict without deleting draft")

        cache.retainTasks(ids: [task.id])
        expect(cache.draft(for: task) === draft, "retained task preserves draft")
        cache.retainTasks(ids: [])
        cache.retainTasks(ids: [])
        expect(cache.draft(for: task) === draft, "deleted task draft survives repeated retention for undo")

        let boundedCache = TaskInspectorDrafts(deletedDraftLimit: 2)
        let retired = (0..<3).map { TaskItem(title: "Retired \($0)") }
        let retiredDrafts = retired.map { boundedCache.draft(for: $0) }
        let liveTask = TaskItem(title: "Live")
        let liveDraft = boundedCache.draft(for: liveTask)
        boundedCache.retainTasks(ids: [liveTask.id, retired[1].id, retired[2].id])
        boundedCache.retainTasks(ids: [liveTask.id, retired[2].id])
        boundedCache.retainTasks(ids: [liveTask.id, retired[2].id])
        boundedCache.retainTasks(ids: [liveTask.id])
        expect(boundedCache.draft(for: retired[0]) !== retiredDrafts[0], "oldest deleted draft is evicted at retention bound")
        expect(boundedCache.draft(for: retired[1]) === retiredDrafts[1] && boundedCache.draft(for: retired[2]) === retiredDrafts[2],
               "recent deleted drafts survive without repeated retention refreshing their age")
        expect(boundedCache.draft(for: liveTask) === liveDraft, "deleted retention bound never evicts a live draft")

        let recoverableCache = TaskInspectorDrafts(deletedDraftLimit: 1)
        let recoverableTasks = (0..<3).map { TaskItem(title: "Recoverable \($0)") }
        let recoverableDrafts = recoverableTasks.map { recoverableCache.draft(for: $0) }
        recoverableCache.retainTasks(ids: [], undoableIDs: Set(recoverableTasks.map(\.id)))
        expect(zip(recoverableTasks, recoverableDrafts).allSatisfy { recoverableCache.draft(for: $0.0) === $0.1 },
               "undoable subtree drafts bypass fallback retention cap")
        recoverableCache.retainTasks(ids: [], undoableIDs: [])
        expect(recoverableCache.draft(for: recoverableTasks[0]) !== recoverableDrafts[0], "draft is pruned once neither live nor undoable")

        let checklist = ChecklistViewState()
        expect(!checklist.consumeFocusRequest(0), "mouse opening never focuses capture by default")
        expect(checklist.consumeFocusRequest(1), "new keyboard capture request is handled on mount")
        expect(!checklist.consumeFocusRequest(1), "navigation cannot replay a consumed focus request")
        expect(checklist.consumeFocusRequest(2), "later keyboard capture request is handled")
        expect(!checklist.consumeFocusRequest(1) && checklist.lastConsumedFocusRequest == 2,
               "stale view callback cannot steal focus or roll request state back")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bist-view-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(directory: directory)
        let undoStore = AppStore(directory: directory.appendingPathComponent("draft-delete-undo"))
        expect(undoStore.addTask(title: "Persisted title", details: "Persisted details"), "create deletion regression task")
        let undoTask = undoStore.tasks[0]
        let undoCache = TaskInspectorDrafts()
        let unsaved = undoCache.draft(for: undoTask)
        unsaved.title = "Unsaved title"; unsaved.notes = "Unsaved details"
        unsaved.subtaskCreation.title = "Unsubmitted child"
        unsaved.subtaskCreation.details = "Unsubmitted child details"
        expect(undoStore.deleteTask(id: undoTask.id), "delete task with dirty inspector")
        undoCache.retainTasks(ids: Set(undoStore.tasks.map(\.id)), undoableIDs: undoStore.undoTaskIDs)
        undoCache.retainTasks(ids: Set(undoStore.tasks.map(\.id)), undoableIDs: undoStore.undoTaskIDs)
        expect(undoStore.undoTaskIDs.contains(undoTask.id), "deleted task ID is retained by undo snapshots")
        expect(undoStore.undo(), "undo deletion with retained inspector draft")
        undoCache.retainTasks(ids: Set(undoStore.tasks.map(\.id)), undoableIDs: undoStore.undoTaskIDs)
        expect(!undoStore.undoTaskIDs.contains(undoTask.id), "completed undo releases obsolete task IDs from undo snapshots")
        let undoRestored = undoStore.tasks.first { $0.id == undoTask.id }!
        let reopenedDraft = undoCache.draft(for: undoRestored)
        reopenedDraft.reconcile(with: undoRestored)
        expect(reopenedDraft === unsaved && reopenedDraft.title == "Unsaved title" && reopenedDraft.notes == "Unsaved details",
               "reopening after delete and undo preserves dirty title and details")
        expect(reopenedDraft.subtaskCreation.title == "Unsubmitted child" && reopenedDraft.subtaskCreation.details == "Unsubmitted child details" &&
               reopenedDraft.subtaskCreation.parentID == undoTask.id,
               "reopening after delete and undo preserves complete subtask capture")
        expect(reopenedDraft.isDirty && reopenedDraft.incoming == nil && undoRestored.title == "Persisted title" && undoRestored.notes == "Persisted details",
               "undo restores persisted baseline without silently saving or conflicting with retained draft")
        expect(undoStore.deleteTask(id: undoTask.id), "delete retained task again")
        undoCache.retainTasks(ids: Set(undoStore.tasks.map(\.id)), undoableIDs: undoStore.undoTaskIDs)
        expect(undoStore.addTask(title: undoTask.title, details: undoTask.notes), "create same-text replacement with fresh UUID")
        undoCache.retainTasks(ids: Set(undoStore.tasks.map(\.id)), undoableIDs: undoStore.undoTaskIDs)
        let replacement = undoStore.tasks[0]
        let replacementDraft = undoCache.draft(for: replacement)
        expect(replacement.id != undoTask.id && replacementDraft !== unsaved && !replacementDraft.isDirty &&
               replacementDraft.title == undoTask.title && replacementDraft.notes == undoTask.notes && replacementDraft.subtaskTitle.isEmpty,
               "same-text replacement never resurrects deleted UUID's unsaved draft")
        let orphanStore = AppStore(directory: directory.appendingPathComponent("creation-parent-deletion"))
        expect(orphanStore.addTask(title: "Project", horizon: .longerTerm), "create parent for global capture")
        let projectID = orphanStore.tasks[0].id
        let capture = TaskCreationDraft()
        capture.parentID = projectID; capture.horizon = .longerTerm
        capture.title = "Keep typed title"; capture.details = "Keep typed details"
        capture.labelIDs = [orphanStore.labels[0].id]; capture.agentHelpRequested = true
        capture.detailsExpanded = true; capture.newLabelName = "Unsubmitted tag"; capture.creatingLabel = true
        capture.requestFocus()
        let focusBeforeDeletion = capture.focusRequest
        expect(orphanStore.deleteTask(id: projectID), "delete selected creation parent")
        capture.reconcileParent(tasks: orphanStore.tasks)
        expect(capture.parentID == nil && capture.horizon == .longerTerm, "orphan global capture selects top level in its current list")
        expect(capture.title == "Keep typed title" && capture.details == "Keep typed details" &&
               capture.labelIDs == [orphanStore.labels[0].id] && capture.agentHelpRequested &&
               capture.detailsExpanded && capture.newLabelName == "Unsubmitted tag" && capture.creatingLabel,
               "deletion reconciliation preserves every creation input")
        expect(capture.focusRequest == focusBeforeDeletion, "deletion reconciliation does not steal focus")
        expect(orphanStore.undo(), "undo selected parent deletion")
        capture.reconcileParent(tasks: orphanStore.tasks)
        expect(capture.parentID == nil, "Undo does not silently change the reconciled global destination")
        expect(capture.submit(to: orphanStore), "reconciled global capture can submit")
        expect(orphanStore.tasks.last?.parentID == nil && orphanStore.tasks.last?.horizon == .longerTerm &&
               orphanStore.tasks.last?.title == "Keep typed title", "submission uses the visible fallback destination")

        expect(orphanStore.addTask(title: "Nested parent", parentID: projectID), "create subtree capture parent")
        let nestedParentID = orphanStore.tasks.last!.id
        let nestedCapture = TaskCreationDraft()
        nestedCapture.parentID = nestedParentID; nestedCapture.horizon = .longerTerm
        nestedCapture.title = "Subtree draft"
        let pinnedCapture = TaskCreationDraft(parentID: nestedParentID)
        pinnedCapture.title = "Inspector child draft"
        expect(orphanStore.deleteTask(id: projectID, includingSubtasks: true), "delete ancestor and selected parent subtree")
        pinnedCapture.reconcileParent(tasks: orphanStore.tasks)
        expect(pinnedCapture.parentID == nestedParentID && pinnedCapture.title == "Inspector child draft",
               "unmounted inspector capture remains pinned through deletion for Undo")
        expect(nestedCapture.submit(to: orphanStore), "submit fallback works before a view reconciliation callback")
        expect(orphanStore.tasks.last?.parentID == nil && orphanStore.tasks.last?.horizon == .longerTerm,
               "deleted-subtree capture cannot retain an invalid parent")
        expect(orphanStore.undo() && orphanStore.undo(), "restore subtree after undoing fallback submission")
        pinnedCapture.reconcileParent(tasks: orphanStore.tasks)
        expect(pinnedCapture.submit(to: orphanStore) && orphanStore.tasks.last?.parentID == nestedParentID,
               "restored inspector capture submits under its original parent")
        let retainedCapture = TaskCreationDraft()
        retainedCapture.parentID = nestedParentID
        expect(orphanStore.deleteTask(id: projectID), "delete ancestor while preserving selected child")
        retainedCapture.reconcileParent(tasks: orphanStore.tasks)
        expect(retainedCapture.parentID == nestedParentID && retainedCapture.horizon == .longerTerm,
               "surviving selected parent stays attached after ancestor promotion")

        let creation = TaskCreationDraft()
        expect(creation.horizon == .shortTerm && !creation.agentHelpRequested && !creation.expanded,
               "creation starts minimal in short term with no agent request")
        creation.title = "Name alone"
        expect(creation.submit(to: store), "name-only submission succeeds")
        let first = store.tasks.last!
        expect(first.title == "Name alone" && first.notes.isEmpty && first.labelIDs.isEmpty && !first.agentHelpRequested,
               "name-only capture has clean defaults")
        expect(first.agentCompletion == nil && first.linkedSessionID == nil && store.sessions.isEmpty,
               "creation cannot invent agent evidence or a connection")
        expect(creation.title.isEmpty && creation.details.isEmpty, "successful creation resets text")
        expect(store.undo() && store.tasks.isEmpty, "creation is one undoable action")

        creation.title = "With optional fields"
        creation.details = "Useful details"
        creation.labelIDs = [store.labels[0].id]
        creation.agentHelpRequested = true
        creation.horizon = .longerTerm
        creation.requestFocus()
        expect(creation.consumeFocus() && !creation.consumeFocus(), "composer consumes each focus request exactly once")
        expect(creation.submit(to: store), "optional creation fields submit atomically")
        let optionalTask = store.tasks.last!
        expect(optionalTask.notes == "Useful details" && optionalTask.labelIDs == [store.labels[0].id] && optionalTask.agentHelpRequested,
               "details tag and agent intent reach saved task")
        expect(optionalTask.horizon == .longerTerm && optionalTask.agentCompletion == nil && optionalTask.linkedSessionID == nil,
               "agent intent has no evidence or session side effects")
        expect(creation.labelIDs.isEmpty && !creation.agentHelpRequested && creation.horizon == .longerTerm,
               "after submit optional fields clear while current group context remains")
        expect(store.undo() && store.tasks.isEmpty, "optional values share one atomic undo")

        creation.title = "Keep this draft"
        creation.details = "Draft detail"
        creation.labelIDs = [UUID()]
        creation.agentHelpRequested = true
        expect(!creation.submit(to: store) && store.tasks.isEmpty, "invalid optional field does not create a partial task")
        expect(creation.title == "Keep this draft" && creation.details == "Draft detail" && creation.agentHelpRequested,
               "failed creation retains user input")
        creation.newLabelName = "Unsubmitted label"; creation.creatingLabel = true; creation.detailsExpanded = true
        creation.parentID = UUID()
        creation.cancel()
        expect(store.tasks.isEmpty && store.labels.count == 3, "cancel does not create tasks or draft labels")
        expect(creation.title.isEmpty && creation.details.isEmpty && creation.labelIDs.isEmpty && !creation.agentHelpRequested,
               "cancel clears name details tags and agent request")
        expect(!creation.expanded && !creation.detailsExpanded && !creation.creatingLabel && creation.newLabelName.isEmpty,
               "cancel resets optional disclosure and new-label input")
        expect(creation.parentID == nil && creation.horizon == .shortTerm, "global cancel resets inherited creation context")

        expect(store.addTask(title: "Parent", horizon: .longerTerm), "test parent created")
        let parent = store.tasks.last!
        let childCreation = TaskCreationDraft(parentID: parent.id)
        childCreation.title = "Child"; childCreation.agentHelpRequested = true
        expect(childCreation.submit(to: store), "subtask uses same minimal atomic composer")
        let child = store.tasks.last!
        expect(child.parentID == parent.id && child.horizon == .longerTerm, "child inherits existing parent group")
        childCreation.title = "Cancelled child"; childCreation.cancel()
        expect(childCreation.parentID == parent.id && childCreation.title.isEmpty,
               "inspector subtask cancel retains fixed parent context")

        expect(store.updateTask(id: child.id, title: child.title, notes: "Existing details", nextAction: "Hidden next action",
                                source: "Existing source", sourceURL: "https://example.com/source"), "set hidden test text")
        expect(store.moveTask(id: child.id, lane: .waiting), "set retained legacy lane")
        expect(store.setTaskLabels(id: child.id, labelIDs: [store.labels[1].id]), "set retained task label")
        expect(store.addSession(provider: .codex, title: "Explicit local bookmark", url: "https://example.com/session"), "set local test session")
        let session = store.sessions.last!
        expect(store.linkTask(id: child.id, sessionID: session.id), "link test task")
        let result = AgentCompletion(sessionID: session.id, artifactURL: "https://example.com/result", summary: "Reviewed test result",
                                     observedAt: Date(), reviewedAt: Date())
        expect(store.recordAgentCompletion(result, taskID: child.id), "set explicit reviewed test evidence")
        expect(store.setUserCompletion(id: child.id, completed: true), "set separate user completion")
        let before = store.tasks.first { $0.id == child.id }!
        let simpleDraft = TaskInspectorDraft(task: before)
        expect(!simpleDraft.moreExpanded && !simpleDraft.detailsExpanded, "inspector starts with advanced and details collapsed")
        simpleDraft.title = "Edited name"; simpleDraft.notes = "Edited details"; simpleDraft.agentHelpRequested = false
        expect(simpleDraft.save(to: store, taskID: child.id), "primary inspector fields save")
        let after = store.tasks.first { $0.id == child.id }!
        expect(after.title == "Edited name" && after.notes == "Edited details" && !after.agentHelpRequested,
               "primary inspector edits persist")
        expect(after.nextAction == before.nextAction && after.source == before.source && after.sourceURL == before.sourceURL,
               "collapsed advanced text is preserved")
        expect(after.parentID == before.parentID && after.labelIDs == before.labelIDs && after.horizon == before.horizon && after.lane == before.lane,
               "collapsed organization and legacy lane are preserved")
        expect(after.linkedSessionID == before.linkedSessionID && after.agentCompletion == before.agentCompletion,
               "collapsed session and reviewed evidence are preserved")
        expect(after.completed == before.completed && after.completedAt == before.completedAt && after.createdAt == before.createdAt,
               "primary edits preserve completion and actual timestamps")
        expect(!simpleDraft.isDirty, "actual save refreshes draft baseline")
        let reopened = AppStore(directory: directory)
        let restored = reopened.tasks.first(where: { $0.id == child.id })!
        expect(restored.title == after.title && restored.notes == after.notes && restored.agentHelpRequested == after.agentHelpRequested &&
               restored.nextAction == after.nextAction && restored.source == after.source && restored.sourceURL == after.sourceURL &&
               restored.parentID == after.parentID && restored.labelIDs == after.labelIDs && restored.horizon == after.horizon && restored.lane == after.lane &&
               restored.linkedSessionID == after.linkedSessionID && restored.agentCompletion?.id == after.agentCompletion?.id &&
               restored.completed == after.completed && abs(restored.completedAt!.timeIntervalSince(after.completedAt!)) < 0.001,
               "saved primary edits and hidden metadata survive restart")

        let navigationDraft = TaskCreationDraft()
        let retainedLabelID = store.labels[0].id
        let deletedLabelID = store.labels[2].id
        navigationDraft.title = "Retained navigation draft"; navigationDraft.details = "Keep my details"
        navigationDraft.labelIDs = [retainedLabelID, deletedLabelID]; navigationDraft.agentHelpRequested = true
        expect(store.deleteLabel(id: deletedLabelID), "delete label while capture is unmounted")
        navigationDraft.reconcileLabels(available: Set(store.labels.map(\.id)))
        expect(navigationDraft.labelIDs == [retainedLabelID] && navigationDraft.details == "Keep my details" && navigationDraft.agentHelpRequested,
               "returning to capture drops deleted tags without discarding other draft inputs")
        expect(navigationDraft.submit(to: store), "draft remains submittable after selected label deletion")

        let minimal = TaskCreationDraft()
        minimal.requestFocus()
        expect(!minimal.expanded && minimal.consumeFocus(), "CmdN focuses empty creation without expanding optional controls")
        minimal.title = "Typed"
        expect(minimal.expanded, "typing a task reveals compact optional controls")
        minimal.title = ""
        expect(!minimal.expanded, "clearing the only text restores minimal creation")
        minimal.title = "Title"; minimal.details = "Retain details"; minimal.title = ""
        expect(minimal.expanded && minimal.details == "Retain details", "clearing title retains visible optional details draft")
        minimal.details = ""; minimal.labelIDs = [store.labels[0].id]
        expect(minimal.expanded, "selected tag keeps its draft controls available")
        minimal.labelIDs = []; minimal.agentHelpRequested = true
        expect(minimal.expanded, "agent intent remains visible when title is cleared")
        minimal.cancel()
        expect(!minimal.expanded && !minimal.consumeFocus(), "cancel returns minimal and invalidates queued focus request")
        minimal.title = "Rapid capture"
        expect(minimal.submit(to: store) && !minimal.expanded, "successful title submission returns to single line")

        minimal.detailsExpanded = true
        expect(minimal.expanded, "explicit details request expands an empty capture")
        minimal.cancel()
        expect(!minimal.expanded, "cancel closes explicitly requested details")

        let treeStore = AppStore(directory: directory.appendingPathComponent("active-tree"))
        expect(treeStore.addTask(title: "Koan"), "create project")
        let parentID = treeStore.tasks[0].id
        expect(treeStore.addTask(title: "Child", parentID: parentID), "create unfinished child")
        let childID = treeStore.tasks[1].id
        expect(treeStore.addTask(title: "Grandchild", parentID: childID), "create grandchild")
        let grandchildID = treeStore.tasks[2].id
        expect(treeStore.addTask(title: "Next root"), "create next stable root")
        let nextID = treeStore.tasks[3].id
        func active(_ collapsed: Set<UUID> = [], at now: Date = Date()) -> [ChecklistEntry] {
            ActiveChecklist(tasks: treeStore.tasks, collapsedParents: collapsed, now: now).entries(for: .shortTerm)
        }
        expect(active().map(\.id) == [parentID, childID, grandchildID, nextID], "active preorder preserves tree ordering")
        expect(active([parentID]).map(\.id) == [parentID, nextID], "active project collapses descendants")
        expect(treeStore.setUserCompletion(id: parentID, completed: true), "complete collapsed parent")
        let parentDeadline = treeStore.tasks[0].archiveDate!
        expect(active([parentID]).map(\.id) == [parentID, nextID], "recent completion stays in its collapsed position")
        expect(active().map(\.id) == [parentID, childID, grandchildID, nextID], "recent completion retains full hierarchy")
        expect(active().first?.task.completed == true, "retained row carries checked state for strikethrough")
        expect(treeStore.completedHistory.isEmpty, "recent completion has not entered archive")
        expect(active([parentID], at: parentDeadline.addingTimeInterval(-0.001)).first?.id == parentID, "visible just before rolling 24-hour deadline")
        expect(active([parentID], at: parentDeadline).map(\.id) == [childID, grandchildID, nextID], "at deadline archived parent cannot hide unfinished children")
        expect(active(at: parentDeadline).map(\.depth) == [0, 1, 0], "archived ancestors promote visually")
        expect(treeStore.tasks[1].parentID == parentID && !treeStore.tasks[1].completed, "projection never mutates child data")
        expect(treeStore.archivedTasks(at: parentDeadline).map(\.id) == [parentID], "completion enters archive at exact deadline")
        expect(treeStore.setUserCompletion(id: childID, completed: true), "complete nested child")
        let childDeadline = treeStore.tasks[1].archiveDate!
        expect(ActiveChecklist(tasks: treeStore.tasks, collapsedParents: []).children(of: parentID).map(\.id) == [childID],
               "inspector retains recent completed direct child")
        expect(active([parentID, childID], at: childDeadline).map(\.id) == [grandchildID, nextID], "archived ancestors cannot hide unfinished descendants")
        expect(treeStore.archivedTasks(at: childDeadline).map(\.id) == [childID, parentID], "archive uses actual completion order")
        expect(treeStore.undo() && active().map(\.id) == [parentID, childID, grandchildID, nextID], "undo completion preserves retained hierarchy")
        expect(treeStore.setUserCompletion(id: parentID, completed: false), "reopen parent")
        expect(active().map(\.id) == [parentID, childID, grandchildID, nextID], "reopen restores original ordering")
        expect(treeStore.setTaskHorizon(id: childID, horizon: .longerTerm), "move tree from child")
        expect(active().map(\.id) == [nextID], "group move leaves unrelated order stable")
        let moved = ActiveChecklist(tasks: treeStore.tasks, collapsedParents: []).entries(for: .longerTerm)
        expect(moved.map(\.id) == [parentID, childID, grandchildID], "group move retains tree order")
        expect(treeStore.setUserCompletion(id: childID, completed: true) && treeStore.setUserCompletion(id: grandchildID, completed: true), "complete all descendants")
        expect(ActiveChecklist(tasks: treeStore.tasks, collapsedParents: []).entries(for: .longerTerm).first?.hasChildren == true,
               "retained completed children keep disclosure")
        expect(ActiveChecklist(tasks: treeStore.tasks, collapsedParents: []).children(of: parentID).map(\.id) == [childID],
               "inspector retains completed direct child for a day")

        let reload = AppStore(directory: treeStore.directory)
        expect(ActiveChecklist(tasks: reload.tasks, collapsedParents: []).entries(for: .longerTerm).map(\.id) == [parentID, childID, grandchildID], "restart preserves retained rows and hierarchy")
        let finalDeadline = reload.tasks.compactMap(\.archiveDate).max()!
        expect(ActiveChecklist(tasks: reload.tasks, collapsedParents: [], now: finalDeadline).entries(for: .longerTerm).map(\.id) == [parentID], "restart projects expired descendants into archive")
        expect(ActiveChecklist(tasks: reload.tasks, collapsedParents: [], now: finalDeadline).children(of: parentID).isEmpty, "inspector excludes expired descendants")
        expect(treeStore.setUserCompletion(id: childID, completed: false), "reopen retained child")
        expect(treeStore.tasks[1].archiveDate == nil, "reopening cancels archive deadline")
        expect(treeStore.undo() && treeStore.tasks[1].archiveDate == reload.tasks[1].archiveDate, "undo reopening restores original deadline")

        print("PASS: \(checks) task view-state checks")
    }
}
