# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native SwiftUI and AppKit floating panel; not a web view)

## Users

One person (the owner) who runs several coding agents at once (Claude Code, Codex, ChatGPT "Bobot") through T3 Code and the CLIs, while doing their own work in other apps. Inferred from the README and the redesign request, they glance at bist between other tasks, so the panel must answer "does anything need me?" in a second and let them reply without switching apps. The owner wants short, front-loaded information.

## Product Purpose

A small always-available corner panel that holds a personal checklist (Tasks), an inbox of agent threads (Sessions) and a scratchpad (Note). Success is that agent work never stalls unnoticed and the owner never has to hunt through T3 or terminal windows to learn what changed.

## Positioning

bist sits in the screen corner across all Spaces and reads local agent state (T3 projections, Codex and Claude session files, the Bobot queue) without accounts, servers or background services. It joins the owner's own tasks to the agents doing them.

## Operating Context

- Collapsed 48 × 48 corner control; expanded panel 360 × 560 points, clamped on small screens. Hover preview of outstanding tasks.
- Sessions refreshes T3 state every 3 s and local history every 20 s while open.
- Replies go through T3's `thread send` CLI or `codex exec resume` / `claude --resume --print`. Structured questions and permission approvals must be answered in T3.
- Opening an update archives its displayed revision. Unanswered questions stay in the inbox.

## Capabilities and Constraints

- Tasks with Me and Agent columns, nesting, labels, Short term / Longer term, Past tasks, Undo.
- Sessions collections are Inbox (Needs you, Running, Updates), Archive, Local history, Saved links (Links). Bobot jobs with questions and results.
- bist only has each thread's latest response excerpt, not full history.
- Must respect Reduce Motion and Reduce Transparency, keyboard navigation (⌘1–3, ⌘N, Escape, Tab), and never take Accessibility or Screen Recording permissions.
- System font only (README commitment). No network services.

## Brand Commitments

- Name `bist`, lowercase.
- The rounded orange-gradient geometric mark (`Assets/bist-mark.svg`) and its opening turn animation.

## Evidence on Hand

Real local T3 threads and demo tasks (`--demo`). No testimonials or usage metrics exist and none should be invented.

## Product Principles

1. What needs the owner comes first, always.
2. Glanceable before readable, readable before complete.
3. Never act on the owner's behalf silently (no auto-send, no approvals).
4. Quiet when nothing is happening.
