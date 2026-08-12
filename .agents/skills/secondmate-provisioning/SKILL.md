---
name: secondmate-provisioning
description: >-
  Agent-only procedure for persistent secondmates on this Windows port.
  Load before creating, launching, routing work to, recovering, or retiring a secondmate, and before editing data/secondmates.md.
  States exactly which half of the Linux provisioning contract exists here and which half does not, so a secondmate is never created on machinery that is absent.
user-invocable: false
metadata:
  internal: true
---

# secondmate-provisioning

Load this before creating, launching, routing work to, recovering, or retiring a secondmate, and before editing `data/secondmates.md`.

A secondmate is a crewmate with an isolated firstmate home and a charter, not a second architecture.

## Read this before creating one

**Half of the Linux provisioning contract is not ported, and the missing half is the automatic half.**

What EXISTS on this port:

- Charter briefs: `bin/fm-brief.ps1 <id> --secondmate {<project>...|--no-projects}`, with `FM_SECONDMATE_CHARTER` and `FM_SECONDMATE_SCOPE` filling the text.
  The charter's idle-by-default and marked-return-channel contracts are intact.
- Launching one: `bin/fm-spawn.ps1 -TaskId <id> -Kind secondmate ...`, which resolves the launch harness through `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own, and may take a model and effort token pinned on the same `config/secondmate-harness` line.
  `-Mode` and `-Yolo` are refused for a secondmate spawn, because a charter is not a delivery contract.
- The digest reads `data/secondmates.md` and prints it, or `ABSENT`.
- `bin/fm-project-remove.ps1` refuses to remove a project that `data/secondmates.md` still references.

What does NOT exist here (`AGENTS.md` section 14):

- **Home seeding.** Nothing creates or seeds a secondmate's `FM_HOME` for you. Its `config/`, `data/`, `state/`, `projects/`, its backlog, and its own project clones are yours to create by hand with `bin/fm-setup.ps1 -FirstmateHome <path>` and the ordinary project commands run against that home.
- **Startup convergence.** Nothing fast-forwards a secondmate's checkout, propagates inherited local material, or mirrors captain preferences into it. `data/captain-shared.md` has no propagation path here; a shared preference is copied by hand or it does not travel.
- **The liveness sweep.** Session start never relaunches a dead secondmate. A secondmate that died stays dead until you notice and act.
- **Cross-home backlog handoff.** `bin/fm-backlog-handoff` is absent. Work routed to a secondmate is added to that home's backlog by hand, running `bin/fm-backlog.ps1` with that home resolved.
- **The re-read nudge after an update.** Nothing tells a running secondmate its instructions changed.
- **Every remote route.** No ssh placement, no remote home provisioning, no remote reply source. A secondmate here is a local home on this machine, full stop.
- **`data/secondmates.md` maintenance.** The registry is a hand-maintained file. Nothing writes it, and nothing validates it.

## The consequence, stated plainly

A secondmate on this port is a persistent local agent you set up by hand and supervise by hand.
That is a legitimate thing to want, and nothing here is unsafe.
But it is materially more work than the Linux path, and the automatic recovery the captain may be expecting is not there.

**So do not create one silently.**
Before creating a secondmate, tell the captain in plain language: a second mate here is set up and kept alive by hand, and if it stops nothing will notice for you.
Then ask whether they want that, or whether an ordinary worker for the specific piece of work is the better fit.
For most work it is: a crewmate is dispatched, supervised, and torn down by machinery that IS ported.

If the captain says go ahead, that is their decision and you build it.

## Creating one, when the captain has said yes

1. Agree the scope in one natural-language sentence, the project list, and where the home lives.
   The scope drives routing; the project list is non-exclusive provisioning data, not ownership.
2. Create and wire the home: `bin/fm-setup.ps1 -FirstmateHome <path>`.
   Because that home is not the checkout, setup writes a stop-and-redirect `AGENTS.md`/`CLAUDE.md` into it naming this checkout - leave that in place, it is what stops a session started in the wrong directory.
3. Clone the secondmate's projects into that home with `bin/fm-project-add.ps1`, run with that home resolved.
4. Write the charter with `bin/fm-brief.ps1 <id> --secondmate <project>...`, filling `{TASK}` with the scope, the standing expectations, and the return channel.
5. Launch it with `bin/fm-spawn.ps1 -TaskId <id> -Kind secondmate`.
6. Add its row to `data/secondmates.md` by hand: its id, its home path, and its one-sentence scope.
   Keep the file readable, because it is the only routing record and no parser will forgive you.
7. Record it as a registered secondmate, never as a backlog work item.

## Routing work to one

Route by the nature of the work against each registered scope, not by the clone list.
Keep `local-only` work in the main home.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it.
Because there is no handoff command, routing means adding the item to that home's backlog directly and steering the live secondmate with one line through `bin/fm-send.ps1`.
Do not read the secondmate's chat: a routed reply returns through its status file or a document it points to.
Do not reconstruct or supervise a secondmate's own child tree from the main home.

## Recovery

A secondmate's idle endpoint is healthy; an empty queue is healthy.
When one is genuinely dead, reconcile only that secondmate, never its whole child tree.
Nothing relaunches it for you, so read its recorded home and endpoint, confirm no live agent still owns it, and relaunch it against the same home and the same charter.
Its home holds its own durable state, so a restart is a non-event for its work as long as the home is intact.

## Retiring

Retire one only on an explicit captain or main-firstmate decision.
Its home must contain no work under way; check its backlog and its `state/` before agreeing.
Forced discard still requires explicit captain authority, and nothing here authorizes deleting a home that holds unlanded work.
Remove its row from `data/secondmates.md` last, once the home is genuinely finished with.
