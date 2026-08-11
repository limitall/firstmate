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
| `Invoke-FmValidatedCheck` | check refused **without execution**, reported as `check: rejected unauthenticated state checks` |
| `Get-FmRecordedWindows`, `Get-FmBackendCapture` | pane staleness skipped, noted once in the triage log |
| `Get-FmWindowKind`, `Get-FmWindowTask`, `Test-FmWindowBusy`, `Get-FmBackendAgentAlive` | not busy / not a secondmate / agent state unknown |
| `Test-FmStaleIsTerminal`, `Test-FmCrewProvablyWorking`, `Get-FmCrewAbsorbClass` | non-terminal, not working, class `none` - surfaced |
| `Get-FmLastStatusLine`, `Test-FmStatusPaused`, `Test-FmStatusPausedOrCaptainHeld` | no declared pause |
| `Get-FmCaptainRelevantStatuses`, `Set-FmStatusSurfaced` | heartbeat backstop finds nothing |
| `Get-FmOpenDecisions` | the drain prints no OPEN DECISIONS section |
| `Get-FmSupervisionInstructions` | guards fall back to the generic repair sentence |
| `Get-FmHarness` | supervision model defaults to `persistent` (the stricter one) |
| `Get-FmPrimaryTangleBranch`, `Get-FmDefaultBranch` | no worktree-tangle alarm |
| `Invoke-FmPrCheckMigration`, `Repair-FmPrPollRetirementAll`, `Publish-FmPrPollRetirement` | migration assumed done, no retirement recovery |
| `Invoke-FmPendingReplyTick`, `Invoke-FmProceventReconcile` | no-op |

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

`FM_WATCH_DISABLE_FSNOTIFY=1` is the only addition, and it only disables the
latency shortcut.

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
