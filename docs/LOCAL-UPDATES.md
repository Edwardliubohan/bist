# Local task proposals

bist has an explicit local update interface. A helper can propose new tasks, and the person using bist reviews them before they enter the task list. There is **no running sync**, file watcher, scheduled job, account connection, or automatic private-chat import.

## Propose a task

From the project folder:

```sh
python3 scripts/bist-propose.py \
  --title "Review the draft" \
  --next-action "Read the introduction" \
  --source "Local draft review"
```

This writes a proposal to `.local-data/inbox.json`. In bist, choose **Review local updates**, inspect the proposal, and add it if wanted. Generating a proposal does not mark an external commitment complete and does not control any agent.

Use `--data-dir /absolute/path` or `BIST_DATA_DIR` to target the same data folder used by the app. Regular mode uses `.local-data/`, while `./run.sh --demo` uses `.demo-data/`. To propose a sample for demo mode, add `--data-dir .demo-data` to the command above.

## File contract

```json
{
  "version": 1,
  "proposals": [
    {
      "id": "1535401C-7219-4D92-AC8E-9810D8C132FE",
      "title": "Review the draft",
      "nextAction": "Read the introduction",
      "source": "Local draft review",
      "createdAt": "2026-10-26T16:00:00Z"
    }
  ]
}
```

Each ID is a unique UUID. `createdAt` is an ISO 8601 timestamp with a timezone. All fields are required; `nextAction` and `source` can be empty. Titles are limited to 200 characters, next actions to 600, and sources to 160. An inbox holds at most 100 proposals and 256 KB.

The Python helper uses a local advisory lock and an atomic file replacement. The app validates before reading and preserves malformed input. When proposals are accepted, it removes only those reviewed IDs, retaining proposals that arrived after the preview. Unknown versions, duplicate IDs, symbolic-link inboxes, malformed dates, and oversized files are rejected.

Do not write directly to `state.json` while bist is running. That file belongs to the task store. The inbox accepts task proposals only: it has no command field for completion, deletion, messages, terminal commands, or agent control.

## Future proactive integrations

A future adapter can write this proposal format from a source the user explicitly authorizes. It should identify the source, preserve stable proposal IDs, avoid secrets and private conversation text, and never claim a live status without an observed event and timestamp. The adapter, its access, its cadence, and any notification behavior require separate implementation and approval. None is enabled by this app.
