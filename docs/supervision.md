# Supervision: the wake queue, the watcher, and the guards

Native PowerShell 7 port of how firstmate learns something happened.

| This module | Ported from | Owns |
| --- | --- | --- |
| `module/Firstmate/Private/FmWake.ps1` | `bin/fm-wake-lib.sh` | the durable wake queue, portable locks, the recovery marker, watcher-liveness predicates |
| `module/Firstmate/Public/FmWake.ps1` | `bin/fm-wake-drain.sh` | `Add-FmWake`, `Get-FmWake`, `Invoke-FmWakeDrain` |
| `module/Firstmate/Private/FmWatch.ps1` | `bin/fm-watch.sh`, `bin/fm-push-transition-lib.sh` | signal scan, wedge timer, pause cadence, triage log, terminal wait |
| `module/Firstmate/Public/FmWatch.ps1` | `bin/fm-watch.sh` (main entry) | `Start-FmWatch` |
| `module/Firstmate/Private/FmGuard.ps1` | `bin/fm-supervision-lib.sh`, `bin/fm-primary-scope-lib.sh` | supervision status, primary scope, banner episode dedup, the liveness beacon |
| `module/Firstmate/Public/FmGuard.ps1` | `bin/fm-guard.sh`, `bin/fm-turnend-guard.sh` | `Invoke-FmGuard`, `Invoke-FmTurnEndGuard`, `Update-FmWatcherBeacon` |
| `bin/fm-watch.ps1`, `bin/fm-wake-drain.ps1` | `bin/fm-watch.sh`, `bin/fm-wake-drain.sh` | thin entry points |

## The queue record is a hard contract

`state/.wake-queue` holds one record per line:

```
epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload<LF>
```

UTF-8, **no BOM**, **LF** (never CRLF), appended never rewritten. `kind` is one
of `signal`, `stale`, `check`, `heartbeat`. TAB, CR and LF in `key` and
`payload` each become a single space, so no field value can forge a record
boundary.

A Linux firstmate must be able to read a queue this code wrote, and the reverse.
Verified both directions on this box against
`/home/adit-admin/dhaval_first_test/firstmate`:

- bash `fm_wake_print_deduped` and `fm_wake_queued_keys` read a PowerShell-written
  queue unchanged; bash `fm_wake_append` continued the sequence from the
  PowerShell-written `.wake-queue.seq`; PowerShell then read the bash-appended
  record back;
- end to end, `bin/fm-watch.ps1` queued a signal and the unmodified bash
  `bin/fm-wake-drain.sh` presented it - annotation, OPEN DECISIONS fold and all -
  then acknowledged it against the recovery generation the PowerShell side had
  opened, leaving the queue empty and the marker `acked:`;
- the lock, too: bash `fm_lock_try_acquire` correctly reports a PowerShell-held
  lock as held by its live pid, and `Lock-FmPath` does the same for a bash-held
  symlink lock.

Everything that writes a shared state file goes through `Set-FmFileTextLf` or
`Add-FmWakeQueueBytes`. Never `Add-Content`, `Out-File` or `Set-Content` -
their Windows defaults emit CRLF and would break the contract silently.

`tests/FmWake.Tests.ps1` asserts the **bytes**, not the parsed fields, so a
regression here fails the suite rather than escaping into a state file.

## Locks: a directory, not a symlink

The bash implementation claims a lock with `ln -s <ownerdir> <lockdir>`, relying
on symlink creation being atomic. Windows needs elevation or developer mode for
symlinks, so this port claims a plain **directory** and takes it with
`File.Move(tmp -> <lockdir>/pid, overwrite: false)`, which fails when the
destination already exists on both Windows and Linux. Same guarantee: exactly
one winner. Writing the pid content into the temporary *before* the move means
no reader can ever observe a half-written holder.

The lock directory holds the same files bash readers already `cat`: `pid`,
`fm-home`, `pid-identity`, `role`, `watcher-path`. bash's own release and
stale-recovery paths handle the non-symlink directory form, so the two
implementations interoperate on one machine - verified in both directions.
The foundation's locks add one child bash does not read, `pid-identity.<pid>`,
and change none of those files' bytes; `docs/foundation.md` owns why.
`Remove-FmLockPath` also follows and cleans up a bash symlink lock and its
private owner directory when evicting a dead holder.

**Process identity** pins a lock to one process incarnation so a recycled pid
can never look like the live watcher. On Linux this reproduces the bash string
byte-for-byte (`linux-starttime=<stat field 22> cmdline-hex=<hex>`) by reading
`/proc` through .NET - no `od`, no `ps`, no shelling out. On Windows there is no
`/proc`, so the process start time in ticks plus the full command line play the
same role.

## The watcher's guarantee is signature-based

Each `state/*.status` and `state/*.turn-ended` is compared against a persisted
`size:mtime` signature in `state/.seen-*`. That is why:

- a signal that lands while **no watcher is running** is caught by the next one;
- two writes in the same second cannot slip through a strict newer-than test;
- `.seen-*` advances only *after* the wake is surfaced or deliberately absorbed,
  so a watcher killed mid-cycle re-surfaces rather than swallows.

`Wait-FmWatchInterval` may additionally use a `FileSystemWatcher` to end the
terminal sleep early. It is **never** a source of truth. The contract is that no
event is missed, not that delivery is push-based, so the polling fallback is not
optional: the notifier only shortens latency, and the next cycle re-reads every
signature from disk regardless. Set `FM_WATCH_DISABLE_FSNOTIFY=1` to run pure
polling. On Windows the notifier sits on `ReadDirectoryChangesW`, whose kernel
buffer silently drops events under a burst - which is exactly why the scan, not
the notifier, decides what happened.

## Telling a working silence from a wedge

A crewmate that blocks for twenty minutes on one long command is silent in
exactly the way a wedged one is. The watcher separates them on two signals it
already holds, and on nothing else.

**The signal is the endpoint's native agent state, read positive-only.**
`Test-FmWindowBusy` asks herdr, which reports agent state natively rather than
from a pane-tail regex. Only a positive `busy` asserts that work is happening: a
busy pane never enters the stale triage at all. Everything else - `idle`, `dead`,
and the `unknown` of a read that could not be made - **defers**. It asserts
nothing, suppresses nothing, and leaves the pane on precisely the stale path it
took before, so a genuinely idle silent pane is surfaced and escalated at the
same cadence as ever. That asymmetry is the whole design: only positive evidence
may quiet an alarm.

**Its honest limits, stated rather than assumed.** The reading is herdr's
`agent_status`, not a pane-tail regex and not a composer shape - which matters
here, because herdr strips styling from its Windows capture. Any reading derived
from the composer's appearance is weaker on this platform for that reason:
`Get-FmHerdrComposerState` reports its capture's `styled` capability honestly and
falls back to `unknown` whenever it cannot prove a shape - and this port loads no
composer classifier at all, so that path answers `unknown` unconditionally
(`docs/herdr-backend-windows.md`). The wedge judgement never consults it. Where
`unknown` does arrive - a native read that failed - it defers, so it can cost a
suppression the worker deserved but can never grant one it did not.
`Get-FmPane` returns the same native state beside the capture, which is what a
supervisor should read before acting on a stale wake. `agent_status` reporting
`busy` for a mid-turn claude on Windows is measured, not assumed:
`docs/windows-e2e-evidence.md` section 10.4.

**A busy pane is still bounded.** Positive liveness has no duration of its own,
so a hung foreground call can hide behind a busy footer that redraws every poll.
`Test-FmBusyTurnOverAge` bounds how long a busy pane may go with **no observed
progress**, and a crossed bound routes through the ordinary wedge timer -
escalation counter, demand-deep-inspection marker and all. Progress is the
freshest of `state/<id>.turn-ended`, `state/<id>.status`, the watcher's own
`state/.hash-<key>` marker (rewritten only when the captured tail changes, so its
mtime is when the pane last produced output), and `state/<id>.meta` last.
`Get-FmPathAge` reads an unreadable path as 999999, so an endpoint with no
evidence at all still crosses the bound.

Its own limit, stated plainly: a pane that redraws a clock or a token counter
while its agent is truly stuck keeps resetting that bound. The stale path is
unaffected - this bound governs only panes herdr positively calls busy.

**Why more than one anchor.** bash ages `state/<id>.turn-ended` alone, which is
sound there because a crewmate Stop hook touches it every turn. This port
installs no such hook (`AGENTS.md` section 14), so that file never exists and the
bound degraded to the age of the spawn record - a quantity that only grows and
that no healthy worker can reset. Every busy crewmate crossed it one hour after
dispatch and then wedge-escalated every `FM_STALE_ESCALATE_SECS` for the rest of
its life, whatever its pane was doing. `docs/windows-e2e-evidence.md` section 23
has the measurement. A wedge alarm that fires while nothing is wrong trains the
supervisor to acknowledge without looking, which is the one thing a real wedge
needs nobody to do.

## Two guards, two different questions

`Invoke-FmGuard` is **pull**-based: it fires when some other supervision command
happens to run, uses the model-aware verdict, and always returns 0. It warns; it
never blocks. Under the Claude Stop auto-arm model the watcher runs only between
turns, so mid-turn a fresh beacon with no live watcher is healthy and only a
stale beacon is a real lapse. The banner names the true failing condition
(`no-watcher` vs `stale-beacon`) and is printed once per episode, keyed on that
condition rather than the beacon mtime.

`Invoke-FmTurnEndGuard` is **push**-based: a verified harness turn-end hook
invokes it every time a primary session is about to end a turn. It uses the
PID-strict predicate and returns 2 to block. In `-Claude` mode it ignores
`stop_hook_active` - Claude sets it on every auto-armed stop, so honouring it
would re-open the exact blind window the guard exists to close - and instead
cooperates with the Stop-owned auto-arm firing on the same event. An absent,
unreadable or unparseable payload always fails **open**.

`Update-FmWatcherBeacon` touches `state/.last-watcher-beat`. The watcher touches
it every cycle, including cycles that only absorb benign wakes, because
absorbing is the watcher working.

## Entry points

```powershell
pwsh bin/fm-watch.ps1                 # block, classify, exit on the first actionable wake
pwsh bin/fm-wake-drain.ps1            # present durable records (does not consume)
pwsh bin/fm-wake-drain.ps1 -AckThrough 42 -RecoveryGeneration 1234.5678.ab12
```

The turn-end guard has no entry point in this area; a harness hook adapter calls
`Invoke-FmTurnEndGuard` and exits with the returned code.

## Seams other areas of the module supply

Every one of these is probed with `Get-Command` and **fails closed** when
absent, so a partially assembled module can lose latency or pane-derived
staleness but can never swallow a wake.

| Function | Absent behaviour |
| --- | --- |
| `Test-FmSignalActionable` | signal treated as actionable - surfaced |
| `Test-FmSignalCrewProvablyWorking` | crew treated as not working - surfaced |
| `Invoke-FmValidatedCheck` (owned since the bounded-execution area landed - `docs/bounded-execution.md`) | check refused **without execution**, reported as `check: rejected unauthenticated state checks` |
| `Get-FmRecordedWindows`, `Get-FmBackendCapture` | pane staleness skipped, noted once in the triage log |
| `Get-FmWindowKind`, `Get-FmWindowTask`, `Test-FmWindowBusy`, `Get-FmBackendAgentAlive` | not proven working / not a secondmate / agent state unknown |
| `Test-FmStaleIsTerminal`, `Test-FmCrewProvablyWorking`, `Get-FmCrewAbsorbClass` | non-terminal, not working, class `none` - surfaced |
| `Get-FmLastStatusLine`, `Test-FmStatusPaused`, `Test-FmStatusPausedOrCaptainHeld` | no declared pause |
| `Get-FmCaptainRelevantStatuses`, `Set-FmStatusSurfaced` | heartbeat backstop finds nothing |
| `Get-FmOpenDecisions` | the drain prints no OPEN DECISIONS section |
| `Get-FmSupervisionInstructions` (LANDED - see below) | guards fall back to the generic repair sentence |
| `Get-FmHarness` (LANDED - `Public/Get-FmHarness.ps1`) | supervision model defaults to `persistent` (the stricter one) |
| `Get-FmPrimaryTangleBranch`, `Get-FmDefaultBranch` (owned since `Public/FmTangle.ps1` landed - see below) | no worktree-tangle alarm |
| `Invoke-FmPrCheckMigration`, `Repair-FmPrPollRetirementAll`, `Publish-FmPrPollRetirement` | migration assumed done, no retirement recovery |
| `Invoke-FmPendingReplyTick`, `Invoke-FmProceventReconcile` | no-op |
| `Get-FmTaskRunLiveness` (LANDED - `Public/FmRunLiveness.ps1`) | stale reasons carry no run-liveness clause; a supervisor is back to deriving it by hand, which is what `docs/finished-run-stall.md` records going wrong |

## The two seams that now have owners

Both of these were documented degradations with nobody on the other side. They
are the only supervision behaviour that changed when the bounded-execution area
landed; everything else in this file is untouched.

**The check sweep can now execute something.** `Invoke-FmValidatedCheck` lives in
`Public/FmBounded.ps1` (`docs/bounded-execution.md`): it refuses anything it
cannot authenticate - which, until the check registry is ported, is still every
check - and otherwise runs a private snapshot of the check under a hard bound
with the exit-124 convention. `Invoke-FmWatchCheckSweep` now enumerates
`*.check.ps1` as well as `*.check.sh`: a `.ps1` is what this port can execute,
and a `.sh` is enumerated so the seam REFUSES it out loud instead of leaving it
silently unswept.

**The worktree-tangle alarm now fires.** `Public/FmTangle.ps1` publishes
`Get-FmPrimaryTangleBranch` and `Get-FmDefaultBranch`. The banner above was
already complete; it simply never had an answer to its question. One rule
differs from `bin/fm-tangle-lib.sh` and it is deliberate: bash keeps linked
worktrees quiet through detached HEAD, while this port's crewmates work on named
branches inside linked worktrees, so the detector tests git-dir against
git-common-dir instead. `tests/FmTangle.Tests.ps1` pins that case against a real
`git worktree add`.

## Shared helpers this area consumes

Reading git belongs to the worktree area: `Get-FmGitOutput` / `Invoke-FmGit` in
`FmWorktree.ps1` run git through `Invoke-FmChildProcess` with an argv array and
no shell. `Test-FmPrimaryScope` calls it with `-Directory`.

Note its failure convention: it returns an **empty string**, not `$null`. The
emptiness check in `Test-FmPrimaryScope` is load-bearing - without it two failed
reads would compare equal and a directory that is not a checkout at all would
scope in as a primary, where bash returns 1.

This area briefly carried its own `Get-FmGitOutput` under the same name. Because
every `Private/*.ps1` and `Public/*.ps1` is dot-sourced into one scope, the
later file silently won and the guard broke on the first rebase onto a main
carrying the backend port. `tests/FmWake.Tests.ps1` now fails on any function
name defined in two files, so the next collision surfaces at test time rather
than at integration time.

Still duplicated on purpose, pending a consolidation decision: this area writes
LF files through `Set-FmFileTextLf` / `Add-FmWakeQueueBytes` while the backend
area has `Write-FmTextFileLf` / `Add-FmTextLineLf`. Same contract, different
names, no collision. Folding them together is worth doing once the foundation
area lands, but not while the byte-level interop evidence above is pinned to
these call paths.

## What a stale reason now carries

A quiet pane is the same shape whether the worker is waiting on a run that is
still going or on one that has already ended, and the difference decides what a
supervisor does next. Every non-terminal stale and every wedge escalation
therefore appends a `[run-liveness: ...]` clause read through the seam above:
`none`, `N live process(es)` with their pids, or `unknown` saying the check did
NOT run. `docs/finished-run-stall.md` owns why - the ad-hoc derivation this
replaced declared nine genuinely-running suites finished - and the `processes`
wording exists specifically to stop that steer being repeated. Nothing about the
surface/absorb decision changed; only the evidence attached to it.

## Environment

Same names and defaults as the bash originals: `FM_POLL` (15), `FM_HEARTBEAT`
(600), `FM_HEARTBEAT_MAX` (7200), `FM_CHECK_INTERVAL` (300), `FM_CHECK_TIMEOUT`
(30), `FM_SIGNAL_GRACE` (30), `FM_STALE_ESCALATE_SECS` (240),
`FM_BUSY_TURN_MAX_SECS` (3600), `FM_PAUSE_RESURFACE_SECS` (3600),
`FM_WEDGE_DEMAND_INSPECT_COUNT` (3), `FM_GUARD_GRACE` (300),
`FM_WATCHER_STALE_GRACE`, `FM_LOCK_STALE_AFTER` (2), `FM_SUPERVISION_MODEL`,
`FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (800), `FM_CLAUDE_AUTOARM_EPOCH_FRESH` (15),
`FM_CLAUDE_TURNEND_BLOCK_BUDGET` (3). Paths follow `FM_ROOT_OVERRIDE`,
`FM_ROOT`, `FM_HOME`, `FM_STATE_OVERRIDE`, `STATE` with the same precedence.

`FM_WATCH_DISABLE_FSNOTIFY=1` only disables the latency shortcut.
`FM_RUN_LIVENESS_DISABLE=1` turns off the run-liveness reading the stale clause
quotes; every verdict then becomes `unknown`, which every caller already treats as
no information. Those two are this port's only additions here.

## Not verified on Windows

Everything here runs and is tested on Linux with PowerShell 7.6.4 and Pester
6.1. These points are marked `# WINDOWS-UNVERIFIED:` in the source and can only
be proven on Windows:

- `Win32_Process` command-line retrieval and start-time stability, used for the
  process identity string.
- `File.Move` replacing a target another process holds open - Windows locks open
  files where POSIX does not.
- The `FileSystemWatcher` kernel buffer dropping events under a burst.
- `chmod 0600` on the recovery marker has no Windows equivalent; the file
  inherits the state directory's ACL instead.

## Tests

```
pwsh -NoProfile -c 'Invoke-Pester -Path ./tests'
```

157 tests across `FmWake.Tests.ps1`, `FmWatch.Tests.ps1` and
`FmGuard.Tests.ps1`. `FmWatch.Tests.ps1` drives `bin/fm-watch.ps1` and
`bin/fm-wake-drain.ps1` out-of-process, the way a harness arms them.

## The emitted supervision block

`Public/FmSupervision.ps1` publishes `Get-FmSupervisionInstructions`, the port of
`bin/fm-supervision-instructions.sh`. It renders stage 4 of the session-start
digest and the one repair sentence every guard and turn-end banner ends with.

**The protocol it emits is selected from the seams present at run time, not from
a constant.** On Linux this renderer picks between six harness protocols; this
port dispatches one harness, so the axis that actually matters here is whether an
automatic re-arm owner exists in the build at all. It does not
(`Invoke-FmWatchArm` is in the registry of deliberate absences), so the Claude
Stop auto-arm is registered and inert, and the block says so and hands the
session the foreground cycle. Emitting the Stop-owned protocol in that state
would tell the captain a mechanism is running when nothing is.

Two call shapes bind, and both are load-bearing:

```powershell
Get-FmSupervisionInstructions -Harness claude -ReadOnly 0 -Afk 0 -XMode 0  # the digest
Get-FmSupervisionInstructions @{ RepairLine = $true; Afk = $false }        # the guard seam
```

The second is `Get-FmSupervisionRepairLine` reaching it through `Invoke-FmSeam`,
which splats an argument ARRAY. A named-only signature would throw there, the
guard's catch would read the throw as "no owner", and every banner would keep its
generic fallback sentence for ever without a word.

## The window contract the pane layer needs

`Public/FmBackendWindow.ps1` publishes `Get-FmRecordedWindows`,
`Get-FmBackendCapture`, `Get-FmWindowKind`, `Get-FmWindowBackend`,
`Test-FmWindowBusy`, `Get-FmBackendAgentAlive` and `Get-FmBackendBusyVerdict`.

These are the names the seam table above lists, and until they existed the
watcher skipped its ENTIRE layer-1 staleness backbone on every cycle: the herdr
adapter had landed with every primitive underneath them under its own names, and
nobody published the generic ones. A dispatched crewmate could wedge and no wake
would ever be raised, while every test stayed green.

The capture is gated on the read-only existence probe rather than the ready
probe, because readiness starts a stopped session server and a watcher poll must
never resurrect an endpoint it is only observing.
