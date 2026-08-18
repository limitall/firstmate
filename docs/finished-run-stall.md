# The finished-run stall, and what the evidence actually said

A crewmate starts a long background run, ends its turn, and waits.
Six times in one evening (2026-08-17) a worker sat idle while its supervisor believed the run was over, and every one of them moved only after firstmate typed a message into its pane.
This note records what was measured, why the first explanation was wrong, and what landed as a result.

## The reported symptom, and the check that produced it

The reported shape was: the worker's own view says a shell or a monitor is still running, while zero processes are alive in that worker's worktree.
The supervisor found every instance with one ad-hoc command:

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -match '\\6\\firstmate-win' }
```

On a count of zero it sent the worker a message of the form
*"your background run has already finished - there are zero processes left in your worktree, so the completion notice will never arrive; read its output file directly."*

## What the transcripts show

The Claude Code session transcripts under `~/.claude/projects/` record two things the pane does not: a `queue-operation` record written when a background task actually ends, and every message typed into the session.
Pairing them answers the question directly - for each nudge, had the run it declared finished actually finished?

**Nine nudges across four workers.**
**In every one, at least one run the supervisor declared finished was still running.**

| worker | nudge | the run it declared finished | actually finished |
| --- | --- | --- | --- |
| `crew-first` | 14:26:51 | `bx7a48x6f`, `bsx85glsp` | 14:34:41 - **7.8 min later** |
| `tg-route` | 14:27:39 | `bzosscsc8` / `bc840kjyp` | 14:41:20 / 15:08:32 - **13.7 / 40.9 min later** |
| `tg-route` | 14:51:43 | `bc840kjyp` | 15:08:32 - **16.8 min later** |
| `tg-route` | 15:31:23 | `bggr1k4cu` | 15:48:25 - **17.0 min later** |
| `ui-voice` | 15:25:40 | `brqzxsqeq`, `bpxyeb834` | 15:40:52 - **15.2 min later** |
| `ui-voice` | 15:33:50 | four tasks | 15:40:52 - 15:54:38 - **7.0 to 20.8 min later** |
| `ui-voice` | 16:08:55 | `buad8h5eq`, `b0hevoifg` | 16:29:29 / 17:02:58 - **20.6 / 54.1 min later** |
| `ui-voice` | 16:43:35 | `br2tgj71y`, `b0hevoifg` | 17:01:05 / 17:02:58 - **17.5 / 19.4 min later** |
| `installer` | 19:32:42 | `bx0oai8mb`, `be0xsgfhq` | 19:55:34 / 19:55:38 - **22.9 min later** |

The `installer` worker refused its nudge and proved the point in-session: thirty seconds after being told zero processes remained, it reported `suite pid 30016 alive, started 00:55:19, cpu=114s`, and fifteen minutes later `alive, cpu=340.9s, elapsed=22.9min`.
Its run then finished normally with `RUNA passed=2056 failed=1` and a second pass `RUNB passed=2063 failed=0`.

## The completion notice was neither lost nor un-sent

The same records show the mechanism working, and working fast.
A `queue-operation` `enqueue` carries the `<task-notification>`; a `dequeue` hands it to the session.

- `crew-first`, task `bm3wefu0n`: enqueued 13:29:44.614, dequeued 13:29:44.638 - **24 ms** - and the worker, whose turn had ended 33 minutes earlier with no message in between, resumed at 13:29:52.
- `crew-first`, task `bgy2p5ego`: enqueued and dequeued inside 30 ms, same shape.
- `tg-route`: two more self-wakes of the same kind.

So a background completion **does** resume an idle Claude Code session by itself, without a human and without firstmate.
Of the four deliveries measured, three took under 35 ms.

What happened to the notices in the stalled cases is the ordinary consequence of the nudge: by the time each run really finished, the worker had already been restarted on a different track, and its queued notice was `remove`d rather than delivered as a fresh turn.

## The diagnosis

**The completion notice was not lost, not un-sent, and not sent to something that stopped listening.**
**It was sent correctly, later than the supervisor believed.**
**The failure was the supervisor's own liveness check, and the false message it produced.**

The check was wrong for a mechanical reason.
A background run started through the harness is launched as

```
pwsh.exe -NoProfile -Command "<the script text>"
```

with the worktree as its **working directory**, not on its command line - so `CommandLine -match <worktree>` does not match it.
Reproduced live on 2026-08-18 against a running suite (`docs/windows-e2e-evidence.md`): the ad-hoc check returned **0** while the suite process was alive with 142 s of CPU.
It matched at all in other cases only by accident, through the `bash.exe` wrappers that the same filter's `Name='pwsh.exe'` clause then excluded.

The cost was not the waiting.
It was the cascade after it: told its run had finished, a worker read a still-growing log, found no summary line, concluded it had been "reaped", and relaunched.
`ui-voice` spent roughly 99 minutes relaunching a suite three times and grinding through foreground chunks; the answer it eventually shipped came from a log file that had been complete and correct on disk the whole time.
This is exactly the direction the task brief named as the dangerous one, and it is the one that actually fired.

## What landed

A correct reading, in the places a supervisor already looks - not a new cadence, not a new poll, and no change to how workers are dispatched or supervised.

**`Get-FmTaskRunLiveness`** (`module/Firstmate/Public/FmRunLiveness.ps1`) answers `processes`, `none`, or `unknown` for one task, from a single process-table read.
Two independent discovery passes union together:

1. **the launcher and its descendants.**
   firstmate itself put the task's brief path on the launch command line, so the launcher is identifiable without guessing, and everything the agent starts descends from it - a Windows child cannot leave its parent.
   This pass finds the run whose own command line names nothing, which is the case the ad-hoc check missed.
2. **anything naming the worktree**, in its command line or its own image path, and that process's descendants.
   This recovers a run orphaned by an intermediate shell exiting, which pass 1 would miss.

The **launch spine** - the launcher and the process running the recorded harness program - is then removed, because those live as long as the worker does and say nothing about whether it is running anything.
The harness name comes from `state/<id>.meta`, not a constant; a harness with no adapter leaves the agent counted as work, so the verdict can only become `processes`.

### The measurement it rests on

Taken on the captain's Windows 11 laptop, recorded in `docs/windows-e2e-evidence.md`: **a crewmate agent process with nothing running has zero live descendants.**
The Bash and PowerShell tool shells are created per call and exit with it; they are not long-lived session shells.
Without that, "has descendants" would not mean "is running something" and this rule would need an ignore-list.

### The asymmetry, which is the whole safety property

`none` is returned **only** after a process table was read successfully and the remaining set was empty.
Every other outcome is `unknown`: the probe disabled, no task record, an unreadable table, no launcher found.
Callers must read `unknown` as no information.
Answering `processes` when nothing runs costs one wasted look; answering `none` while a run is going reproduces the defect above.

Two shapes deliberately fail towards `processes`: a recycled pid that makes an unrelated process look like a descendant, and a harness with no adapter entry.

### Where the reading surfaces

| surface | what changes |
| --- | --- |
| `bin/fm-run-liveness.ps1 <task-id>` | one line - `liveness: <processes\|none\|unknown> · task: <id> · <detail> [· pids: …]`. Exit 0 for any answered reading including `unknown`; exit 2 only on usage. |
| the watcher's stale wake | every non-terminal stale and every wedge escalation carries a `[run-liveness: …]` clause, so the wake itself says what was measured and a supervisor never re-derives it. The `processes` wording names the pids and says outright not to tell the worker its run has finished. |
| `bin/fm-crew-state.ps1` | the status-log fallback line - the one path with no authority of its own - gains `run-liveness: …`. That path is where a crew waiting on a live run and a crew waiting on a finished one used to read identically. |

The reading is taken only where the question is otherwise unanswered: a busy pane and an attributed no-mistakes run both already answer it, and neither pays for a process-table read.
`FM_RUN_LIVENESS_DISABLE=1` turns the probe off; every verdict then becomes `unknown`.

### Why the clause is silent on `unknown` in the crew-state line but not in a wake reason

A wake reason is an action prompt: an absent reading there has to say it did not run, or silence reads as "nothing is running" - the failure this area exists to refuse.
A crew-state line already carries a `source:` field saying where its answer came from, and most `unknown` readings there mean the ordinary "this task has no live agent", which the line already reports.
An `unknown` clause on every such line would be noise rather than information.

## What this does NOT claim

It does not claim the stall the brief describes cannot happen.
It claims that none of the nine recorded instances was one: in every case a run was still running.
A genuine stall - a completion notice produced and never delivered - would still be caught by this reading, because `none` plus an idle endpoint plus a non-terminal status is exactly its signature, and the watcher now surfaces that with the evidence attached.
What changed is that the supervisor no longer has to guess, and the guess it used to make was wrong.

One thing bounds the detection, and it is not this area's to fix.
The clause rides the watcher's existing stale cadence, and this port has no automatic watcher arm (`AGENTS.md` section 14), so the reading reaches a supervisor when a watcher is running - the session-kept foreground cycle - and not otherwise.
That is the same bound every other stale wake already has; nothing here made it narrower, and widening it would be the supervision redesign this work deliberately stayed out of.
## Tests

`tests/FmRunLiveness.Tests.ps1` is weighted to the dangerous direction: every ambiguity, unreadable input and partial discovery is asserted to land on `processes` or `unknown`, and `none` only where the table positively holds nothing.
Three tests read the real machine rather than a fabricated table: two that the process table comes back with this process, its parent and its command line in it, and one that spawns a real background child, finds it, and then stops finding it once it has exited.
The clause wiring is covered where it is consumed: `tests/FmWatch.Tests.ps1` asserts all three clause shapes in a queued wake record and in a wedge escalation, and `tests/FmCrewState.Tests.ps1` asserts the fallback line gains the clause, gains nothing when the reading is inconclusive, and never pays for the reading when the pane is busy.
`docs/windows-e2e-evidence.md` section 32.4 carries the whole-suite and analyzer numbers this landed on.
