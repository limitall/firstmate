---
name: afk
description: >-
  Away-mode supervision - NOT AVAILABLE on this Windows port.
  Load when the captain invokes /afk, says they are going afk or stepping away, or asks what happens overnight, so you can tell them exactly what this machine will and will not do while they are gone.
user-invocable: true
metadata:
  internal: true
---

# afk - not available on this port

**Away mode is not ported.**
There is no `state/.afk` flag, no sub-supervisor daemon, and no mechanism that injects an escalation into a live session while the captain is away.
This skill exists so the gap is answerable rather than silently missing; `AGENTS.md` section 14 lists it alongside the rest.

Do not simulate it.
Specifically: do not start a background loop, do not schedule a job that types into this session, and do not promise batched overnight digests.
Every one of those would produce exactly the failure away mode was built to prevent - a supervision cycle firstmate believes is live and is not.

## What to tell the captain

When they say they are going away, say plainly what is true, in `AGENTS.md` section 9 language. Something like:

> Captain, I will keep the work supervised and nothing will be lost while you are out - every worker's progress and every notification is recorded and waits for you. What I cannot do on this machine is reach you or act on your behalf while you are gone, so anything that needs your decision will simply be waiting when you are back, rather than being handled overnight.

Then, before they go, do the one thing that actually helps: clear what can be cleared now.
Surface every decision currently waiting on them and get the answers while they are still here, so the queue that greets them is as short as possible.
`/bearings` is the right shape for that sweep.

## What still works while they are away

This matters, because "away mode is not ported" is not "nothing happens".

- Workers keep working. They are autonomous; they do not wait on firstmate mid-task.
- Every status event a worker appends is durable, and every wake it raises stays on the queue until it has been handled and acknowledged. Nothing is dropped because nobody was watching.
- The supervision cycle keeps running for as long as this session is alive, and handles what it can handle on its own.
- Work that reaches a decision point stops safely and waits, rather than guessing.

## What does not happen

- No escalation is injected into this session or any other while the captain is absent.
- Nothing batches routine wakes into a digest to save tokens; each one is handled normally.
- No wedge alarm fires. A worker that gets stuck stays stuck until the next time someone looks.
- If this session itself ends, supervision ends with it. The durable records survive; the live cycle does not.

That last point is the one worth saying out loud when the captain is stepping away for a long stretch: leaving the session open keeps supervision live, and closing it does not lose work but does stop the watching.

## What would have to land

For away mode to become real here, three things: a supervisor daemon that survives outside the session, a composer-state read reliable enough to prove a pane is safe to type into, and an alert channel that reaches the captain.
The second is the hard one - Windows herdr strips styling from its capture, which is exactly the signal the Linux composer guard depends on, so the honest classification is `unknown` and `unknown` must defer.
`docs/herdr-backend-windows.md` records that measurement.
When it changes, `docs/windows-e2e-evidence.md` is where the new evidence goes first.
