---
name: firstmate-orca
description: >-
  The Orca runtime backend - NOT AVAILABLE on this Windows port.
  Load only when the captain asks for Orca, or when a task record or config names it, so the refusal is explained rather than looking like a bug.
user-invocable: false
metadata:
  internal: true
---

# firstmate-orca - not available on this port

**The Orca runtime backend is not ported, and neither are tmux, zellij, or cmux.**
`herdr` is the only session provider this port drives: `Start-FmWorker -Backend` accepts `herdr` and nothing else, and `bin/fm-setup.ps1` writes `config/backend=herdr` so a fresh home never resolves to a backend that cannot dispatch here.
`AGENTS.md` section 4 owns that boundary and `harness-adapters` owns the harness half of it.

## Why, in one paragraph

A runtime backend owns the task endpoint, and for Orca it also owns the task worktree.
Adopting one means porting its spawn, capture, steer, liveness, and teardown paths and then proving each on Windows - and Orca has no Windows evidence at all.
herdr does: it ships a Windows preview whose core loop was measured end to end, it is the only adapter with semantic agent state rather than a rendered-output guess, and this port's worktree isolation was redesigned around durable `treehouse get --lease` acquisition precisely because it does not depend on reading a pane's working directory, which is empty on Windows herdr.
Adding a second backend now would mean a second unproven path through every one of those, which is how a fleet ends up with a supervision chain that looks healthy and never fires.

## What to do

- **If the captain asks for Orca:** say plainly that this machine runs one worker runtime, that it is the one with measured Windows support, and that adding another is its own piece of work with its own evidence bar. Do not switch, do not experiment, and do not offer a partial trial.
- **If `config/backend` names Orca or another absent backend:** bootstrap prints `BACKEND_INVALID`. Do not dispatch. Load `bootstrap-diagnostics` and follow it: the value must be `herdr` on this machine before work can be dispatched from it. A home shared with a Linux firstmate may legitimately carry a different value there, in which case say that work cannot be dispatched from this machine until it is corrected here.
- **If a `state/<id>.meta` record names `backend=orca`:** that task was created by another home. Do not adopt it, do not steer it, and do not tear it down. Report it as belonging to the machine that spawned it, and leave its worktree and its lease alone.

## What would have to land

A full adapter (spawn, read, send, liveness, teardown), Windows evidence for each of those, and a reason to want a second endpoint owner.
The reason is the part that is missing: nothing this port needs is blocked by herdr today.
If that changes, `docs/windows-e2e-evidence.md` is where the evidence goes first, then `docs/herdr-backend-windows.md`'s sibling for the new backend, then this skill and `AGENTS.md` section 14.
