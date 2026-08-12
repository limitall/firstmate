---
name: stuck-crewmate-recovery
description: >-
  Agent-only playbook for stuck or missing Firstmate direct reports.
  Use when the session-start digest reports a direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer.
  Reconciles recorded work before escalating from targeted inspection through safe relaunch or failure.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when the session-start digest reports a direct report's endpoint dead or its metadata has no window, or when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, unresponsive, or when a steer failed to land.

Interrupt and stop a worker through `bin/fm-control.ps1 <task-id> interrupt|exit`, which resolves the recorded runtime itself, verifies each action, and never tears down or discards anything.
**`relaunch` is refused by name on this port**: it is a durable transaction (checkpoint, note capture, staged rollback, replacement launch) and half of one is worse than none.
The replacement is two explicit steps, described in step 4 below.
Load `harness-adapters` before a resume command or a harness-specific skill invocation, and whenever the adapter's own quirks matter.
The target window's harness is recorded as `harness=` in `state/<id>.meta`; on this port it is `claude` or the record is wrong.

## The one signal that is weaker here

This port does not install a crewmate turn-end hook, so `state/<id>.turn-ended` is never touched by a worker's turn (`harness-adapters`, "Hooks").
A worker that is quietly working therefore looks exactly like a worker that finished a turn and said nothing, until its next `state/<id>.status` append or until it ages into a stale wake.
**Do not read a stale wake as proof of a wedge on this port.**
Read the current state first, every time, before escalating: `bin/fm-crew-state.ps1 <id>`.

## Session-start reconciliation for a dead direct report

Treat the digest's endpoint result as a presence signal, not proof that the task's work is gone.
Read the targeted current state with `bin/fm-crew-state.ps1 <id>` before deciding to relaunch, and read the pane with `Get-FmPane fm-<id>` when the state line alone does not explain what you are seeing.
`Get-FmPane` returns the bounded capture, herdr's native busy state, and the recovery-grade agent state together; only `dead` and `missing` license recovery, and `unreadable` licenses nothing.

When no live agent accounts for the task, inspect only its recorded backend and worktree inventory.
Use `treehouse status` for the worktree pool, and the recorded `worktree=` and `treehouse_lease_id=` in `state/<id>.meta` as the task identity.
Because this port acquires every task worktree as a durable lease, a reboot does not free a worktree that `state/<id>.meta` still points at - so a lease that is still held while the endpoint is gone is the expected shape of a crashed worker, not a leak to clean up.
Do not sweep another home's endpoints or infer ownership from a matching window label.

Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.
Preserve its uncommitted changes and commits, keep the same task identity, and relaunch in that existing worktree with the same brief plus a concise progress note.
Do not use a fresh generic spawn while the recorded worktree is unaccounted for, because allocating another worktree can split one task across two copies.
If the worktree or ownership cannot be reconciled safely, leave all state intact and report the task failed or blocked with the conflicting evidence.

## Live-endpoint escalation

Escalate in order:

1. Read the pane with `Get-FmPane fm-<id>`.
2. If the crewmate is waiting on a question its brief already answers, answer in one line with `bin/fm-send.ps1 <task-id> '<answer>'`.
   `fm-send` fails closed on an unresolved home and exits non-zero when the Enter was positively swallowed, so a zero exit is real evidence the line landed.
3. If the crewmate is confused or looping, interrupt with `bin/fm-control.ps1 <task-id> interrupt`, then redirect with one corrective line through `fm-send`.
   Claude fires no hook for a manual interrupt, so the control plane reports only the delivered key and makes no cancellation claim; confirm the interrupt landed by reading the pane, not by trusting the exit code.
4. If the crewmate is genuinely wedged after redirection, replace it in two explicit steps, because there is no `relaunch` verb here.
   First, append the progress so far to the existing `data/<id>/brief.md` as a short note, so the replacement starts where the original got to.
   Then `bin/fm-control.ps1 <task-id> exit`, confirm the agent is gone, and spawn the replacement with `bin/fm-spawn.ps1` against the **same task id, the same brief, and the same recorded worktree**.
   Never let the replacement acquire a new worktree while the recorded one still holds the task's commits: that splits one task across two copies, which is the exact failure the durable lease was adopted to prevent.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so replacement is cheap.
5. If a second replacement fails too, write `failed` to the backlog and tell the captain the plain failure, preserved work, and consequence using `AGENTS.md` section 9; do not mention metadata, harness, window, or worktree unless the path itself is needed for action.

## Never do these

- Never delete or hard-reset a task worktree to unstick a worker. The landed-work test in `bin/fm-teardown.ps1` is the only path that decides a worktree is disposable.
- Never return a lease by hand while a task record still points at it.
- Never force teardown to clear a stuck task; a teardown refusal is the evidence, not the obstacle.
- Never kill processes by name match to clear a pane, because that reaches sibling firstmate homes.
