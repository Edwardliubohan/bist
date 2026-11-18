# bist — project overview

bist is a small native macOS checklist and session panel that lives in the
top-right corner of the screen, with an iPhone companion that shares the same
task rules (`Sources/BistCore.swift`, `Sources/TaskViewState.swift`) and syncs
through private iCloud or Supabase. `README.md` covers installation and the full feature
list; the other files in `docs/` cover Bobot, agent results, local updates and
the iPhone build.

## Where things stand

### Subtasks and completion

- **Inline subtask entry.** Every open row on the Mac shows a **+** on hover.
  It opens a text field directly beneath that task's open subtasks
  (`InlineSubtaskEntry` in `Sources/TaskViews.swift`). Return adds the subtask
  and keeps the field focused for the next one; Escape, the × button, or
  leaving the field empty closes it. The row menu's **Add subtask** opens the
  same field instead of redirecting the bottom composer. Which parent has the
  field open is `ChecklistViewState.inlineSubtaskParentID`.
- **Parents complete themselves.** `AppStore.setUserCompletion` checks a parent
  when its last open direct subtask is checked, then repeats for the next level
  up. Reopening a subtask reopens every checked ancestor. The task and its
  cascaded ancestors change in a single commit, so one Undo reverts all of
  them. Checking a parent still never checks its children.
- **Completed tasks sink.** Within each sibling group the list shows open tasks
  in their stored order, then completed tasks with the newest completion first
  (`ActiveChecklist.completedLast`). This is a display ordering only: stored
  order is untouched, so sync, drag-and-drop and Undo are unaffected, and a
  reopened task returns to its original position. Both the Mac and iPhone lists
  use this projection.

- **Dragging can't nest a main task.** `AppStore.canDragTask` lets a dragged
  top-level task be reordered among other top-level tasks or moved to a list
  heading, but never dropped into or beside a subtask. Over a top-level row the
  whole row acts as a reorder zone. Subtasks can still be dragged anywhere,
  including out to the top level. Making a main task a subtask is done from its
  details (parent picker) or the row menu's **Move to…**.
- **Delete button on main tasks.** Each top-level row ends with a trash button
  that deletes the task together with its subtasks, undoable from the Undo line.

Tests: `Tests/CoreTests.swift` covers the drag rules;
`Tests/TaskViewStateTests.swift` covers the cascade and ordering rules;
`Tests/InlineSubtaskTests.swift` mounts the real checklist and types through the
native field editor to confirm the inline field adds on Return and stays open.

### Opening from Spotlight

When bist is already running, Spotlight, Finder and Launchpad don't start a
second copy. macOS sends the running app a "reopen" event instead. bist used to
ignore it, so the panel stayed collapsed and nothing appeared to happen.
`AppDelegate.applicationShouldHandleReopen` in `Sources/BistApp.swift` now
expands the panel and brings it forward, and leaves an already open panel on
its current page. `Tests/PanelLifecycleTests.swift` covers both cases.

Spotlight lists every bundle named bist, including stale copies such as
`build/bist.app` in this repo and any backup in `~/Applications`. All of them
share the bundle ID `local.bist.panel`, so while one is running macOS routes
them to it. When none is running, a stale copy launches its own older code.
Keep only `~/Applications/bist.app`, or add the repo's `build` folder to
System Settings → Spotlight → Search Privacy.

### Known test-environment issue

`Tests/InactiveTextEntryTests.swift` intermittently fails its "first native
caret must actually render" precondition (also on unmodified `main`), which
stops `./test.sh` early. Rerunning usually passes.
