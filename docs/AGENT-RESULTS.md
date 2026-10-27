# Reviewed agent results

bist keeps two independent completion states:

- **I’m done** is your own checkbox. It does not change an agent result.
- **Agent done** means you explicitly reviewed submitted output for the task’s linked session. It does not imply that bist connected to that provider or observed a running agent.

A result file is a proposal, not proof of live integration. Arrival in the local inbox never marks a task complete.

## Review an output

1. Save the relevant session link and link the task or subtask to that session in its details.
2. Submit a local result with the exact task and session IDs, an output URL, and the time the output was observed.
3. Open **Review agent results** in bist. Check the task, session, summary, and linked output.
4. Select **I reviewed this output**, then **Mark agent done**.

The app records the observed time separately from your review time. Your **I’m done** state remains unchanged. Invalid or mismatched task/session references cannot be accepted. To change the session behind accepted evidence, explicitly clear that evidence first; bist does not silently transfer it to a different session.

## Submit a local proposal

From the project folder:

```sh
python3 scripts/bist-result.py \
  --task-id 1535401C-7219-4D92-AC8E-9810D8C132FE \
  --session-id 54A88361-6B8F-4B06-9194-631F7F20D4CA \
  --artifact-url https://example.com/output \
  --summary "Draft ready for review" \
  --observed-at 2026-10-26T12:00:00Z
```

The IDs and URL above are examples. Use the actual IDs of the task and saved session you intend to link. The command writes only to `.local-data/agent-results.json`; it sends nothing to an agent or website. Use `--data-dir /absolute/path` or `BIST_DATA_DIR` for another local store, including `.demo-data` for an isolated demo.

Pass `--id UUID` when retrying the same result, so the proposal keeps a stable identity. Accepted results are consumed only while their full queued content still matches what was reviewed. A retry does not create a second completion or overwrite the reviewed output. Reloading the review screen clears the review checkboxes, so changed output cannot inherit an earlier review.

## File contract

```json
{
  "version": 1,
  "results": [
    {
      "id": "10A6CD23-35DC-43B4-9D72-49A0F661CC01",
      "taskID": "1535401C-7219-4D92-AC8E-9810D8C132FE",
      "sessionID": "54A88361-6B8F-4B06-9194-631F7F20D4CA",
      "artifactURL": "https://example.com/output",
      "summary": "Draft ready for review",
      "observedAt": "2026-10-26T12:00:00Z"
    }
  ]
}
```

All fields are required. IDs must be UUIDs and result IDs must be unique. The inbox is limited to 100 results and 256 KiB (262,144 bytes); summaries must contain non-whitespace text and are limited to 2,000 characters. Output links must be complete HTTP or HTTPS URLs without embedded account credentials and no longer than 4,096 characters. Observation timestamps need an explicit timezone and must be on or after January 1, 1970. They cannot be in the future, apart from a 60-second clock-skew allowance. Use whole-second ISO 8601 timestamps as shown above; the CLI normalizes timestamps to UTC.

The app reads only on explicit review. File access uses a local lock, validation, and atomic replacement. Acceptance removes only the reviewed proposal and preserves results added after the preview. A proposal changed under the same ID stays in the inbox for another review; it is not silently discarded. Invalid, oversized, or non-regular inboxes, including symbolic links and named pipes, are rejected without rewriting them. A busy lock returns a retry message rather than waiting indefinitely.

## What is not connected

The local session adapter discovers Codex and Claude Code session metadata and can reopen a session in its CLI. It does not provide automatic drafting, a running-status feed, a background watcher, a scheduler, private-chat import, or automatic transmission of task text. Existing CLI logins handle authentication when resuming. Opening a result link is an explicit user action.

A future adapter needs a supported provider API, separately approved access, an exact task/session scope, clear outbound data rules, and reliable completion events with output evidence. It must not treat a local proposal as a verified provider event. End-to-end adapter behavior must be tested before bist can claim automatic solving or drafting works.
