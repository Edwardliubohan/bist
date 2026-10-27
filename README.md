# bist

A small native macOS checklist and session panel in the top-right corner. A rounded orange-gradient geometric mark sits in a 48-point glass control; hover briefly for a passive task preview, or click for the full panel.

## Run locally

Requires an Apple Silicon Mac running macOS 14 or later and Apple Swift command-line tools. No packages, account connection, or network service is required.

```sh
cd bist
./run.sh
```

The build produces `build/bist.app`. Quit any running instance before rebuilding, then reopen this app or use `run.sh`. Clearly labeled sample tasks use a separate store:

```sh
./run.sh --demo
./run.sh --expanded
./run.sh --demo --reduced-motion --opaque
```

The app respects macOS Reduce Motion and Reduce Transparency; the corresponding launch options and options-menu toggles also allow local testing. `./test.sh` runs the local regression suites.

## Checklist

- Thin 26-point rows, with separate **Me** and **Agent** columns. Checking “I'm done” immediately removes the row from the active checklist and hover preview, without changing agent completion or any child task. Unfinished children remain visible in their existing order, even when their completed parent was collapsed.
- Nested subtasks with collapsible disclosure. Add a child from the row menu or task details; edit its parent in details. Cycles and missing parents are rejected.
- User-defined labels with a name and one of six colors. School, Class, and Koan are initial editable labels. Tasks may have multiple labels.
- Minimal single-line capture expands only after typing or explicitly opening details. Details, Tag and Agent help share one compact row. Short term / Longer term groups retain their stored order; dates do not reorder them. Drag a task handle onto a list heading to move that task and its subtree independently. Row edges reorder siblings; the center nests a task. Invalid self/descendant drops are rejected. Right-click **Move to…** opens a searchable destination picker; **Move out one level** promotes a subtask. These moves preserve labels and completion evidence and have one Undo step.
- Completed history uses actual user-completion timestamps, newest first, with an explicit Reopen control. Older completed tasks without a timestamp are shown last as time unknown. Reopening clears the completion time; undo restores it. Agent results never set this timestamp.
- A read-only hover preview after a short intent delay, with a grace period and transparent bridge when moving into the preview. It does not activate the app or move the corner control. Clicking the corner opens the full panel.

Delete is available from each task’s context menu and its details. Deleting just the parent promotes its children; **Delete task and subtasks** explicitly removes the tree. Both support Undo during the current launch.

Details and tags are simple to edit; parent selection, session linking, evidence and source fields stay behind More in task details. Custom compact selection popovers support keyboard navigation and dismissal. A draft in the capture field and tree disclosure state survive navigation within the running app.

## Agent results and session links

Save session bookmarks for Claude Code, ChatGPT / Codex, or Meta Muse. These open the saved URL in the browser. Providers remain **Not connected**, session activity remains **Unknown**, and last observed activity remains **Never** until a real adapter exists.

Agent help saves intent only. Without a supported connection, the UI says it is not connected; no task is dispatched. A task can link to one saved session. “Agent done” records a specific output URL, summary, observation time and local review time after explicit review. Incoming result files alone do not complete tasks. Review does not change “I'm done.” See [Agent results](docs/AGENT-RESULTS.md) for the bounded local result format and CLI.

[Local updates](docs/LOCAL-UPDATES.md) describes the separate reviewed task-proposal interface. Neither interface installs a watcher or sends tasks to a provider. Actual automatic solving, drafting, live session controls, and proactive synchronization need a supported adapter, defined task/session scope, and separately approved account access. No live adapter is implemented.

## Local data and interaction

Regular tasks use `.local-data/`; demo tasks use `.demo-data/`. `BIST_DATA_DIR` can select another folder. Schema 1 stores migrate in memory without losing task/session fields; the next successful edit saves schema 2. Malformed data is preserved and reported. Writes use atomic replacement and stale-write protection. Local stores, builds, screenshots, and credentials are excluded from Git.

The panel starts 16 points inside the usable top-right screen edge. Drag the minimized control or the empty space in the open panel’s header to move it; a normal click opens it. Its position is saved locally in the selected data directory and restored on launch. Expansion and the hover preview stay within the usable screen; collapse returns to the chosen compact position. Its compact window is 48 × 48 points with a stationary 44 × 44 hit target; the full panel is 360 × 560 points, clamped on small screens. The geometric mark stays anchored at the top right while the glass panel opens or closes; click it again to collapse. Tasks and Sessions share a compact system-font header. Page changes use a short 200 ms clipped slide and fade. The settings gear opens a full settings page; ⌘, opens it from the keyboard. The window opens and closes with a continuous eased reveal, a small geometric turn of the logo, and a fading orange hover highlight. Content keeps its final layout while the glass expands. Task editing and secondary navigation use short, clipped slide-and-fade transitions. Reduced motion disables movement. Clickable controls use a pointing-hand cursor, while text inputs keep their I-beam. Task rows never display delayed tooltips. Mouse clicks suppress the unwanted native blue button box while keyboard navigation retains a rounded focus indicator.

Past tasks and Tags are visible, labeled 32-point navigation targets above the checklist. Subtasks retain their individual disclosure controls, without a bulk expand/collapse menu. The editor's fixed Back to tasks control stays above its scroll area. Back preserves unsaved drafts without silently saving them; a dirty-state label and readable footer distinguish immediately saved tags from text and agent-help changes that require Save. All panel typography uses the default system font. The warm ivory surface uses dark brown text and burnt-orange controls. Settings includes a live transparency slider, a solid-background switch, and reduced motion. Appearance preferences persist automatically. A separate reading surface maintains contrast at the strongest glass setting; macOS Reduce Transparency overrides the slider. The compact control has its own opaque backing and remains legible over other apps. Clicking a text field activates the panel for typing; clicking elsewhere dismisses its insertion point without discarding the draft.

The editable identity asset is `Assets/bist-mark.svg`, also bundled in the app's Resources. Its `orbit-upper` and `orbit-lower` groups can be transformed independently around the 24-unit canvas center. `Assets/bist-mark-animated.svg` provides matching hover and press motion through self-contained CSS, including a reduced-motion fallback; both assets are bundled with the app. The native SwiftUI mark and generated app icons match those rounded paths and orange gradient; minimized hover adds only a brief opposing rotation, never a continuous loop. The expanded mark stays still without the minimized hover/press highlight; accessible keyboard focus remains available. Reduced motion keeps the mark still. `scripts/make-icon.swift` generates small-size light/dark previews alongside the ICNS for visual checks.

No login item, background service, scheduled job, credentials, chat import, or Accessibility permission is installed. Private task data is not uploaded by bist.

## Keyboard

⌘N focuses task capture. ⌘1 / ⌘2 select Tasks and Sessions. Escape returns from details or collapses the panel; a visible preview is dismissed first when bist already has keyboard focus. Tab / Shift-Tab navigate controls; Space or Return activates focused buttons. ⌘Z undoes a local task action outside text editors; text editors retain normal text undo.

The tests cover atomic drag placement and ordering, cycle rejection, independent subtree moves, deletion with child preservation, subtree deletion and undo, failed move/delete writes, migration, persistence and stale writes, tree integrity, horizons and stable ordering, labels, completion timestamps and history, independent completion, session/evidence validation, reviewed inbox consumption, CLI validation, panel geometry, hover-preview timing and cancellation, and input focus policy. Native visual checks are also needed for interaction changes. No hosted CI is configured.

A passive preview cannot receive Escape while another app owns keyboard focus. Pointer-leave dismissal works without global keyboard monitoring; bist deliberately does not request permissions to intercept another app’s keys.
