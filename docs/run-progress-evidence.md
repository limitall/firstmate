# Telling a run that is advancing from one that is merely alive

`Get-FmTaskRunLiveness` counts processes.
A process count answers "has this run exited?" and nothing else, and the two are not the same question: an idle shell is a live process, and a worker that hung twelve hours ago still has one.
This note records what was measured on this machine, what each candidate signal costs, how each one lies, and what can honestly be built on top.

The short answer is at the top because it is the load-bearing one.

**Progress can be measured in the positive and cannot be measured in the negative.**
Evidence that a run is advancing is real, cheap and available.
Evidence that a run is *not* advancing does not exist here, because every signal that stops moving when a run hangs also stops moving when a run is healthy and waiting.
So the reading gained an `advancing` answer, and it did not gain a `stalled` one, and nothing escalates on the absence of movement.

## Why this is the sharpest edge in the fleet

Both directions are already recorded, and they are not symmetric.

Telling a worker its run has finished when it has not is the expensive mistake, and it is the one that actually fired.
`docs/finished-run-stall.md` has nine such nudges out of nine, each wrong, costing a worker that abandoned a correct run and started over - `ui-voice` lost about 99 minutes to an answer that was complete on disk the whole time.
The waiting those nudges were meant to end was cheaper than the nudges.

Failing to notice a genuinely stalled worker is the other direction, and the reported instance is twelve hours of an idle shell reading as healthy.
That is a real cost, but it is a cost of *delay*, and the delay is bounded by the next thing that looks.
The first mistake destroys work that was already done.

A stall detector that is wrong sometimes therefore does not trade evenly against the status quo: its false positives land in the expensive direction.
That asymmetry is what decides the design, not a preference for caution.

## What was measured

Six process shapes, each a `pwsh` process, sampled through `Win32_Process` at **steady state** - which matters, because a first sample taken within a few seconds of launch catches pwsh's own startup burning about 11,500 write operations and 56 KB, and that startup noise is large enough to look like activity in every shape at once.
Raw cumulative counters, four samples six seconds apart.
`docs/windows-e2e-evidence.md` section 66 has the runs.

| shape | what it really is | CPU | file read/write ops | other ops | transfer bytes |
| --- | --- | --- | --- | --- | --- |
| `spin` | advancing: pure compute | **+0.9 to +1.1 s per 6 s** | frozen | frozen | frozen |
| `poll` | **alive and NOT advancing**: a retry loop testing a path that never appears | **+1.1 to +1.4 s per 6 s** | frozen | **+11k to +14k per 6 s** | frozen |
| `fileio` | advancing: appending to a log | +0.1 to +0.9 s per 6 s | **+139 to +155 per 6 s** | frozen | **+3.5 KB per 6 s** |
| `netactive` | advancing: continuous socket traffic | +0.8 to +1.0 s per 6 s | frozen | frozen | **frozen** |
| `sleep` | merely alive: `Start-Sleep` | **frozen** | frozen | frozen | frozen |
| `netwait` | **advancing, blocked**: waiting on a socket that never answers | **frozen** | frozen | frozen | frozen |

Two rows settle the whole question.

**`netwait` and `sleep` are identical on every counter the class exposes.**
A subprocess waiting on a slow API reply is the single commonest thing an agent's background run does, and from outside it is byte-for-byte a process doing nothing at all.
There is no threshold, no combination and no longer sampling window that separates them, because there is nothing to separate: both are a thread parked in a wait state.

**`poll` burns more CPU than `spin`.**
The shape most likely to be a genuinely stuck run - retrying something that will never succeed - is the shape that looks busiest.
So CPU movement does not mean progress either.

`netactive` adds a third: a run that is advancing entirely over the network moves no IO counter at all, so absence of IO is not absence of work.
`Win32_Process` read/write counters are file and device IO; socket traffic is not in them, and this port has no other portable process-level source.

## The candidates, what each costs, and how each lies

| candidate | cost | lies "advancing" when | lies "stalled" when |
| --- | --- | --- | --- |
| **CPU delta** over the task's process set | free - already in the `Win32_Process` row the reading reads; one prior sample in `state/` | a retry or spin loop burns CPU forever without progressing (`poll` above) | the run is blocked on a network reply, a lock, a disk, or a prompt - `netwait` above |
| **File IO counters** | free, same row | a log repeats "retrying" forever; a process re-reads the same file in a loop | the run is pure compute (`spin`) or pure network (`netactive`) |
| **Process-set churn** - pids appearing or exiting | free, the reading already builds the set | a recycled pid makes an unrelated process look like a descendant | the run is one long-lived process, which most are |
| **The run's output file growing** | not available: firstmate does not know the path. The harness owns it; `state/<id>.meta` records window, worktree, harness and kind and nothing about a run's output | the log repeats a retry line; a progress spinner redraws | the run buffers, or writes only its summary at the end - which is exactly what the Pester suite does |
| **Worktree file mtimes** | expensive - a recursive scan of a whole checkout per poll, per worker | a temp file, a lock file or a log churns; the agent's own editing counts as the run's progress | a read-only run: a test suite that computes and reports, which is the commonest long run here |
| **The pane hash** | already read by the watcher | a clock or a token counter redraws while the agent is stuck - `docs/supervision.md` records this limit for busy panes | circular for this question: the reading is only taken *because* the pane went quiet |
| **The worker's own status line** | already written and already read | a worker that lies or is confused | a correct worker that is mid-run and has nothing new to say |

Every row lies in both directions.
The difference between them is not reliability, it is *which* lie is available: for CPU and process churn a false "advancing" costs nothing because nothing acts on it, while a false "stalled" costs a destroyed run.

## What landed

A second dimension on the reading, positive-only, and no change to any timer.

`Get-FmTaskRunLiveness` returns `Activity` beside `State` on a `processes` verdict.
`advancing` means movement was measured since the last look: CPU burned above the noise floor, or the set of live pids changed.
That floor is per-window rather than fixed, at 1 ms per second of window with a 200 ms minimum, because the noise it has to clear grows with the window.
A settled idle process was measured burning 0 to 15.6 ms per minute - one scheduler tick, which is quantisation rather than work - so a fixed 50 ms floor would have called an idle process `advancing` over a four-minute window, while the least busy advancing shape measured burned 23 ms per second and clears the scaled floor more than twentyfold.
A process also needs about 10 seconds to settle after launch: a window opened 5 seconds in still catches roughly 300 ms of startup, which is why the reading compares two looks of an existing run rather than measuring from a spawn.
`unobserved` means a comparable earlier sample existed and nothing moved.
`unknown` means nothing was comparable - a first look, a gap under 30 seconds, a process table with no CPU column, or the probe switched off.

The two positives are independent on purpose.
CPU catches a single long-running process; pid churn catches a runner that spends its life spawning one short process per unit of work and burning nothing itself while it waits.

`unobserved` is **not** a stall verdict, and this is enforced rather than merely documented.
It defers a wedge escalation exactly as `advancing` does, it advances no counter, and `tests/FmWatch.Tests.ps1` asserts that both produce no wedge alarm - so a future change that made `unobserved` escalate fails a test that names the reason.
Its own wording carries the caveat into every surface that quotes it: *"which does NOT mean it is stalled - a run awaiting a network reply measures identically"*.

The comparison needs two samples separated in time, so one sample per task is kept at `state/.run-activity-<id>`: the time, the summed CPU, and the pid set.
CPU is summed only over pids present in **both** samples, so a process that started or ended in between cannot contribute its whole lifetime's CPU as though it were burned in one window.
The sample is dropped when the task's work set empties, so a task id that runs again later cannot compare against a run that ended hours ago.
An unparseable sample reads as `unknown` rather than as a zero baseline, because a zero baseline would report the run's entire lifetime CPU as one window's movement - a manufactured `advancing`.

The clause a supervisor reads was also corrected.
It said **"work IS in flight"** off the process count alone, which is a claim about progress that a process count cannot support - the same overclaim in `bin/fm-crew-state.ps1`'s fallback line.
Both now state what was measured: the process count, and then the activity reading when there is one.

## What was deliberately not done

**No timing decision keys off activity, in either direction.**

Escalating on `unobserved` is the obvious next step and it is the one the measurement forbids: `netwait` proves the reading cannot tell a hung run from a healthy one waiting on a reply, so escalating on it would rebuild `docs/finished-run-stall.md`'s defect under a new name, with a number attached to make it look measured.

Stretching the re-surface cadence when a run reads `advancing` was also considered and rejected.
It would be the noise reduction T1.2 exists for, but `poll` is exactly the shape of a genuinely stuck run and it reads `advancing` at full confidence - so the case that most needs surfacing is the case that would be surfaced least.
The evidence is reported to the supervisor instead, where a human reading "it burned 14 s of CPU in the last 240 s" alongside a quiet pane can weigh it against what the worker was supposed to be doing.

## What should happen instead

External process inspection is structurally incapable of answering "is this run advancing?", so the answer has to come from something that knows what the run is *for*.

The worker already reports that, and the port already collects it: the `working: [pct%]` status line, surfaced by `fm-progress`, from the worker's own claim and never invented.
A worker that has appended nothing for an hour is a far better stall signal than any counter here, because the claim is about the task rather than about the process - and unlike CPU it does not move when a retry loop spins.
It has its own failure mode, a worker that stops reporting while still working, and that failure is visible and cheap: a supervisor reads the pane.

The honest division is therefore:

- **the process set** says whether the run has exited - trustworthy, and the only thing that may ever license "your run has finished";
- **the activity reading** says whether something executed - real evidence, reported, never acted on alone;
- **the worker's own status** says whether the *task* is advancing, and it is the only signal that can mean that.

A supervisor holding all three is in a genuinely better position than one holding a process count.
None of the three, alone or together, licenses telling a worker its run has stopped when the reading is anything other than `none`.

## Tests

`tests/FmRunLiveness.Tests.ps1` covers the decision procedure against fabricated tables, and is weighted the opposite way to the liveness tests above it: `advancing` is asserted only where movement was positively measured, and every gap, missing column and unreadable sample lands on `unknown` rather than on a verdict.
One test spawns a real busy process and a real idle one and asserts that `Win32_Process` CPU actually moves for the first and stands still for the second - without it the whole dimension could become silently useless while every fabricated-table test still passed.
`tests/FmWatch.Tests.ps1` asserts the three clause shapes and that neither `advancing` nor `unobserved` ever escalates; `tests/FmCrewState.Tests.ps1` asserts the fallback line carries the reading and no longer claims work is in flight from a count.
