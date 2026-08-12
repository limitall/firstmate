---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest from firstmate's live fleet state.
  Use when the captain invokes /bearings or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Plain /bearings is chat-only by default, while /bearings file explicitly writes the dated data/status-report-<YYYY-MM-DD>.md artifact; live PR enrichment remains opt-in and composes with file mode.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
This skill is operationally read-only in both modes.
It never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, mutates backlog or task state, or writes any file except the single dated report in explicit file mode.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a path to that report.
- Treat `file` only as an explicit invocation option in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", or "make a file" as file mode unless the invocation explicitly includes the standalone `file` option.
- `/bearings include PRs` remains chat-only and adds the live-PR read.
- `/bearings file include PRs` writes the dated report and adds the live-PR read.

## Gathering the snapshot on this port

**`bin/fm-bearings-snapshot.sh` is not ported** (`AGENTS.md` section 14), so there is no single deterministic snapshot command here.
Gather from the same durable records it reads, in this bounded order, and nothing else:

1. `bin/fm-backlog.ps1 list` for the queue, dependencies, gates, and the recent Done baseline; its header owns the grammar.
2. `state/<id>.meta` for every task, for its project, kind, mode, yolo, worktree, and recorded PR.
3. `bin/fm-crew-state.ps1 <id>` for each live task's CURRENT state.
   The `state/<id>.status` tail is an event log, not current state, so use it only for the last event's wording and never as the state itself.
4. `bin/fm-wake-drain.ps1` output already presented this turn, if any, for records still awaiting handling.
   Do not drain the queue from inside this skill; presenting a queue is a mutation of supervision state and belongs to the wake-handling turn.
5. `data/projects.md` for the delivery posture of each project you name.
6. Only when the captain asked to include PRs, one `gh-axi` read per recorded PR.
   Skip this entirely by default; a recorded PR with no live read is still reported, just without its live check state.

Keep the read bounded: do not walk report bodies, review artifacts, terminal scrollback, or visible conversation history to supplement current state.
A queued item only becomes "next work" when its blocker is gone and its date gate has arrived; until then it stays queued with the reason.
Registered secondmates have no structured home classification on this port, so report a secondmate from its own recorded status and say plainly when its state is unavailable rather than inferring one.

If a source is absent or unreadable, say which one and what that leaves unknown.
A missing source is never reported as an empty section.

## What it does

1. **Gather live fleet state** exactly as above.

2. **Compose the four-section chat digest from the fresh snapshot.**
   The gather step is mechanical; your judgment is scoped to ranking those facts by what matters right now and writing scannable captain-facing prose.
   The chat response uses the four complete sections in the chat-response contract below, in the same order, each always present.
   Plain mode stops here and writes no report artifact.

3. **In explicit file mode only, compose and replace the detailed report file.**
   The report uses the same four complete sections as the chat, in the same order, and adds the detail the chat omits.
   Never read an earlier `data/status-report-*.md` to decide what to omit, include, describe as changed, or call current.
   Write the full report to `data/status-report-<YYYY-MM-DD>.md` using today's date.
   If today's file already exists, delete it first, then create a new file from scratch.
   This is the only write allowed by the skill.
   The detailed report includes:
   - **Title** - `# Bearings - <day> <YYYY-MM-DD>` (use "Morning status" only when the captain specifically asks for a morning brief), followed by two or three sentences framing where things stand.
   - **Captain's Call** - every open decision summarized with its options, plus each PR ready to merge and each needed credential or login, every PR with the full `https://...` URL, never a bare `#number`.
   - **Recently Landed** - the bounded current recent-completions baseline from the backlog's Done history, rendered in full on every run.
   - **Underway** - each live direct report making progress, with its current state, and the pickup pointers worth reopening (`data/<id>/report.md` files).
   - **Charted Next** - queued or gated work with each item's blocker or date.
   After writing the file, return the concise four-section chat digest and include the report path without adding a fifth section.
   For a richer review surface, optionally offer a Lavish board with `lavish-axi` when it is installed and the report has enough structure to deserve one, but only after the required digest is ready.

## Chat-response contract

This skill is the one owner of the `/bearings` chat-response format, and no other file restates this contract.
Every `/bearings` chat response renders EXACTLY these four sections, in THIS order, and nothing else structural (there is no At Anchor section):

1. **Captain's Call** - ONLY items that need the captain's own action now: a decision to make, a PR to approve or merge, a credential or login to provide, or a blocker only the captain can clear.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the bounded current recent-completions baseline: merged PRs, completed scouts, and finished local-only merges.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state per direct report.
   Empty-state: "Nothing is underway."
4. **Charted Next** - queued or gated work waiting on the fleet or a date, plus action-free fleet-integrity warnings, never on the captain.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence; never omit a section.
- Every chat digest and file-mode report is a complete current snapshot, never a delta against a prior report.
- Recently Landed always renders the bounded current baseline, even when the same completions appeared in an earlier report.
- The four buckets are mutually exclusive, so every item is forced into exactly one: needs-your-action is Captain's Call, done is Recently Landed, self-progressing is Underway, and not-yet-started work or an action-free integrity warning is Charted Next.
- The strict boundary keeps action-free items OUT of Captain's Call: a working task, a queued item blocked on another task or a date, landed work, a completed scout's report pointer, a declared `paused:` external wait, and a bare recorded PR with no merge-ready signal each belong to one of the other three sections, never Captain's Call.
- Include the required direct address to the captain inside one item or empty-state sentence.
- Every PR appears as the full `https://...` URL; a shorthand `#number` is fine only as a back-reference after the full URL has already appeared in the same digest.
- The chat follows `AGENTS.md` section 9 and carries one scannable line per item.
- Detailed decisions, plans, full gate reasons, and evidence belong in the file only when file mode is explicit, so plain chat stays concise and file-mode chat stays materially shorter than that file.
- In file mode, include the report path inside the four-section digest without adding another heading.

## Tone and content rules

- The optional file-mode report is a private, captain-facing internal artifact that lives in gitignored `data/`, so unlike normal captain chat it MAY reference task ids, PR URLs, and repo names.
- The captain works with those directly and needs them to resume; keep the report organized and scannable, not a raw dump.
- Every PR reference is a full `https://...` URL, never a bare `#number`.
- Never include PHI or secret values; the report is an operational artifact, but it is still subject to the same security and compliance rules that govern everything else in this fleet.

## Supervision discipline

This skill changes no fleet state.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, drain or acknowledge the wake queue, or mutate any `state/` or `data/` file other than the single report file in explicit file mode.
If the state you read suggests an action - a PR ready to merge, a queued item whose gate has arrived, or a decision needing an answer - name it in its section and leave the action to the normal lifecycle and configured authority rather than taking it from inside this skill.
