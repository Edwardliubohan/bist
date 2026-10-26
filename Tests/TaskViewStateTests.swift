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
        expect(cache.draft(for: task) !== draft, "removed task draft is pruned")

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

        print("PASS: \(checks) task view-state checks")
    }
}
