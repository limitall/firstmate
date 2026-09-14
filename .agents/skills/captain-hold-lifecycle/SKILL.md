---
name: captain-hold-lifecycle
description: >-
  The Linux firstmate's successor to decision-hold-lifecycle - NOT AVAILABLE on this Windows port.
  Load only when a brief, report, document, or the captain names captain-hold-lifecycle, fm-captain-hold, or a RECORD DIVERGENCE line, so you follow decision-hold-lifecycle instead of machinery this machine does not have.
user-invocable: false
metadata:
  internal: true
---

# captain-hold-lifecycle - not available on this port

**This is the Linux firstmate's replacement for `decision-hold-lifecycle`, and it is not ported.**
Upstream collapsed "a decision" into "a task held for the captain" (kunchenguid/firstmate#2728) and moved the whole lifecycle onto `bin/fm-captain-hold.sh`: `hold`, `complete`, `answer`, `answers`, `bind`, `reconcile`, and `diverged`, whose output the Linux wake drain prints as `RECORD DIVERGENCE`.
That script now sits in this tree only because the Linux firstmate was merged in beside the port; it is bash, and this port takes no dependency on bash (`CONTRIBUTING.md`).
`AGENTS.md` section 14 lists the gap.

## What to do instead

**`decision-hold-lifecycle` is the policy in force on this machine.**
Load it at its own triggers and follow it: it carries the same obligation - no unresolved captain call is lost when an investigation or review ends - on ordinary held backlog items through `bin/fm-backlog.ps1`, and teardown enforces its read side.

Never run `bin/fm-captain-hold.sh` or `bin/fm-decision-hold.sh`, under Git Bash or any other shell.
Nothing on this port reads the answer records, source bindings, or reconcile requests they keep, so a call closed through them would look answered to nothing that checks.
When a brief, report, or document tells you to load this skill or run that command, treat it as written for the Linux firstmate and do the `decision-hold-lifecycle` equivalent.
This port's wake drain never prints `RECORD DIVERGENCE`; a line like that in something you are reading came from a Linux home.

## Why it is not simply adopted

It is not a rename.
Upstream's rules differ in substance: hold the work item the question gates rather than minting a new row, keep one held task per genuine gate, close a call only with the captain's own words, re-hold "later" with a date so the call comes back, and never treat `reconcile` as an answer.
Some of that `bin/fm-backlog.ps1` could carry today, but not all of it the same way - a hold with `-Until` here simply stops holding on its date, so the item becomes ready to dispatch rather than coming back as a call waiting on the captain.
Teardown's unresolved-decision gate also attributes holds by the rules `decision-hold-lifecycle` states (`docs/teardown-windows.md`).
Changing the policy therefore changes that gate, `/bearings`, and the in-force skill together, which is its own piece of work.

## What would have to land

Either a port of `fm-captain-hold` and its records, or a deliberate adoption of the refined rules onto `bin/fm-backlog.ps1` with the teardown gate and `/bearings` changed to match.
`docs/windows-e2e-evidence.md` records the evidence first, then this skill and `decision-hold-lifecycle` change together, then `AGENTS.md` section 14.
The Linux skill exactly as it arrived with the merge is recoverable with `git show b182d0f9:.agents/skills/captain-hold-lifecycle/SKILL.md`.
`docs/captain-hold-lifecycle.md`, which arrived with it, describes the Linux mechanism, not this machine.
