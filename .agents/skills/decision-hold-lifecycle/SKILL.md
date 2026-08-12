---
name: decision-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain decisions.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a decision, and when recording or routing the captain's answer.
user-invocable: false
metadata:
  internal: true
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved captain decisions discovered by an investigation or visual review.

## Policy

Every unresolved decision that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must become a durable captain-held work item in this home's backlog before that work or review may be treated as complete.
The agent performs the semantic inventory because no script can infer decisions from report prose, visual-review artifacts, terminal output, or chat.
Give each distinct unresolved decision a stable privacy-safe key and file it once, so a retry with the same key is idempotent while different decisions retain different durable identities.
Do not close a hold merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
The hold remains the authoritative Captain's Call item until the captain's answer is durably recorded, dependent work is created in the same backlog and blocked by that hold, and those dependency edges are cleared before the hold is closed.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create holds.
Bearings reads the resulting backlog state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

## Mechanism on this port

**`bin/fm-decision-hold.sh` is not ported** (`AGENTS.md` section 14), so the policy above is carried by ordinary backlog commands.
That changes the tooling and nothing about the obligation.

Use `bin/fm-backlog.ps1`; its header and `-h` output own the exact grammar:

- File the hold as its own work item whose id IS the stable key: `bin/fm-backlog.ps1 add <key> '<concise title>' -Repo <repo> -Body '<the choice and its options>'`.
- Mark it captain-held so it is not dispatchable and shows up as a Captain's Call item: `bin/fm-backlog.ps1 hold <key> -Reason '<what the captain must decide>' -Kind captain`.
- Block each dependent work item on that key: `bin/fm-backlog.ps1 block <dependent-id> -By <key>`.
- After the captain answers, write the exact durable decision into the dependent item's note, unblock it, and close the hold: `bin/fm-backlog.ps1 done <key> -Note '<the captain's decision, verbatim in substance>'`.

Because no script attests the inventory here, the completion attestation is yours: before declaring the investigation or review complete, state in the same turn either the full list of keys you filed or that the reviewed surface contained no unresolved captain decision.
Do not declare completion and then go looking.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain.
3. For each choice, choose a stable key and file the held item with a concise title, reason, and repository.
4. State the full unresolved-key inventory for that review pass, or state explicitly that there is none.
5. Relay the choices to the captain as decisions in Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. After the captain decides, record dependent work in the backlog and block it by the hold's key.
7. Put the captain's exact durable decision in the dependent item's note, clear the block, and close the hold.
8. Confirm `/bearings` no longer shows the closed hold and that routed work remains in the backlog.
