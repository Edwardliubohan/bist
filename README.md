# bist

A small native macOS task panel, held in the top-right corner of your desktop. Warm frosted glass, quiet lavender controls, and a compact pill that opens into Tasks and Sessions.

## Run locally

Requires an Apple Silicon Mac running macOS 14 or later and the already-installed Apple Swift command-line tools. No packages, account connection, or network service is required.

```sh
cd bist
./run.sh
```

The build produces `build/bist.app`. `run.sh` compiles and opens this native app; there is no browser preview.

To explore clearly labeled sample tasks in an expanded panel:

```sh
./run.sh --demo
```

Additional launch options can be combined:

```sh
./run.sh --expanded
./run.sh --demo --reduced-motion --opaque
```

`--expanded` opens the full panel immediately. `--reduced-motion` disables movement; `--opaque` uses a solid material. The app also respects the corresponding macOS accessibility settings.

Quit any running bist instance before using `run.sh` to rebuild. You can also reopen `build/bist.app` directly.

Run the local checks with `./test.sh`. The build and data stay in this project. Regular tasks use `.local-data/`; demo tasks use `.demo-data/`. `BIST_DATA_DIR` can select a separate data folder. The regular app starts with a clean task list; sample tasks are explicitly labeled and can be removed.

## What works

- A floating panel placed 16 points inside the screen’s usable top-right corner, below the menu-bar safe area. The compact pill is approximately 224 × 44 points; the expanded panel is approximately 360 × 560 points.
- Local task capture, Needs attention / Next / Waiting groups, task details and next actions, completion, defer, and undo. Changes are saved to a local JSON file.
- Explicit sample tasks for trying the interactions without changing real commitments.
- Session bookmarks for Claude Code (Anthropic), ChatGPT / Codex (OpenAI), and Meta Muse. Save your own session URL and open it in its normal browser destination.
- Manual review of local task proposals. See [Local updates](docs/LOCAL-UPDATES.md).

## Session boundaries

Session bookmarks do not connect accounts. Their activity status stays **Unknown**, with no fabricated last-observed time. Unconnected providers are shown honestly. bist does not start, stop, or message external agents; import private chats; install credentials; or run background synchronization.

Actual cross-platform control and proactive live updates need a separately approved integration with a supported provider API, authenticated access, and a defined scope. This first version provides a safe local review interface for that future work.

## Data and behavior

The local store contains only entered tasks, explicit sample tasks, and saved session links. Keep private tokens and credentials out of task text and URLs. A malformed store is preserved and reported instead of being silently replaced.

The panel uses native glass material, rim highlights, and subtle press/hover states. It respects macOS Reduce Motion and Reduce Transparency. There is no perpetual decorative animation and no automatic focus grab for incoming updates. It does not change login items or request Accessibility permissions.

Close or quit from the app’s controls or menu-bar item. No background service or scheduled job is installed.

## Keyboard

⌘N captures a task; ⌘1 / ⌘2 switch Tasks and Sessions; Escape returns from details or collapses the panel. Tab moves keyboard focus. ⌘Z undoes local task actions when a text editor does not have focus; text editors retain normal text undo. Use the visible Undo action at any time it is available.

The test suites cover task persistence, validation, completion, deferral, undo, sample separation, session URL validation, and idempotent proposal imports. Live provider integrations and background sync are not implemented.
