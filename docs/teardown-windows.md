# Teardown and process custody on Windows

The area that must never destroy work. Ported from `bin/fm-teardown.sh` and
`bin/fm-lock-lib.sh` in the bash firstmate; the design decisions for the
Windows-specific parts come from `data/fmwin-design/report.md` (section 2 port
map, section 4.3), not from this port.

| Command | Bash original |
| --- | --- |
| `bin/fm-teardown.ps1 <task-id>` | `bin/fm-teardown.sh <task-id>` |
| `bin/fm-teardown.ps1 <task-id> --force --approved-by "<authority>"` | `bin/fm-teardown.sh <task-id> --force` |

Exit codes are the repo convention: 0 success, 1 refusal or failure, 2 usage.

## What teardown proves, in order

Teardown hard-resets a worktree, deletes its branch and kills its processes.
Every step below is a proof that must SUCCEED before the next one runs; a step
that cannot establish its fact refuses, and a refusal leaves every durable
record intact so a plain rerun is always safe.

0. **The control lock** - `state/.control-<id>.lock`, a directory plus a `pid`
   file: the same on-disk shape `bin/fm-wake-lib.sh`'s `fm_lock_try_acquire`
   creates, so a Linux firstmate and this one recognise each other's held lock.
   One lifecycle action per task at a time; a contended lock changes nothing.
   An ownerless lock is reclaimed; a lock whose `pid` file cannot be READ is
   treated as live, because stealing it costs two teardowns in one worktree
   while refusing costs an operator one `rm`.
1. **Shape gates** - the meta must record `herdr`; a `remote_host` (the work
   lives on another machine) and `kind=secondmate` (home retirement is its own
   area) are refused by name rather than half-performed.
2. **Scout gate** - `kind=scout` declares the worktree scratch, so the report at
   `data/<id>/report.md` IS the work product. No report, no teardown. The
   unresolved-decision completion gate then runs through its owner
   (`Test-FmDecisionHoldComplete`); an absent owner refuses, because a gate that
   did not run cannot report a pass.
3. **The landed-work test** - see below. The single most important thing here.
4. **Process custody** - close the pane, terminate the task's job object, refuse
   on any survivor.
5. **The pool return** - conditional on this task's own lease. A failed return
   keeps the worktree AND the state files.
6. **The endpoint gate** - durable records are erased only once the exact
   recorded pane is confirmed gone (`Test-FmHerdrEndpointGone`).
7. **The artifact gate** - the task's PR-check artifacts (`<id>.check.sh`,
   `.pr-poll`, `.pr-poll-registration`, `.pr-poll-retirement`, `.check-trust`)
   and its `.pr-check-quarantine` entries are validated as ordinary,
   non-symlinked files in an ordinary state directory before removal. A
   symlinked one refuses and preserves task state instead of following the link
   out of the home.

Before the destructive steps, teardown also concludes a no-mistakes run that
THIS worktree provably owns and that is parked at a gate no worker will ever
answer (branch AND code identity must both match). That is housekeeping, not a
safety property: a failure there is recorded and never strands the teardown.

## The landed-work test

`Test-FmTeardownWorktreeSafety` returns a verdict (`allow` / `refuse` /
`lock-blocked`) rather than throwing, because a refusal is a normal outcome and
`throw` under `$ErrorActionPreference = 'Stop'` would make it indistinguishable
from a bug.

| Situation | Verdict |
| --- | --- |
| uncommitted changes | REFUSE - uncommitted changes are never landed |
| untracked `.claude/`, `.fm-grok-turnend`, `.fm-kimi-turnend` | allow - firstmate's own dropped-in files are not the crew's work |
| commits on no remote, not landed | REFUSE |
| commits on no remote, contained in a MERGED PR head | allow |
| commits on no remote whose patch-ids are all in the PR head | allow - survives a rebase or force-push |
| commits on no remote whose content is already in the up-to-date default branch | allow - the squash-merge-then-delete-branch flow |
| `mode=local-only` with commits not merged into the local default branch | REFUSE |
| `mode=local-only`, merged locally, but dirty | REFUSE |
| the default branch cannot be determined | REFUSE |
| `git status` / `git log` cannot run, and a git lock explains it | `lock-blocked` - try the staleness proof, then RE-RUN the checks |
| `git status` / `git log` cannot run, nothing explains it | REFUSE |
| a `gh` lookup errors and the content check is inconclusive | REFUSE |
| `kind` is `scout` or `secondmate` | allow - their gates are elsewhere |
| `-Force` | allow - which is why `-Force` needs authority |

A `lock-blocked` verdict never becomes a pass by itself: the lock is cleared
only if it is provably stale, and then the whole test runs again. The same
re-run happens inside the pool return, so a lock discovered late cannot skip
the test either.

## `--force` requires explicit authority

This is the one deliberate divergence from the bash CLI. `--force` skips the
landed-work test and the scout report gate - it discards work - so it requires
`--approved-by "<who authorized it>"`, and a bare `--force` is a usage error
(exit 2), not a slightly harder retry. The authority is recorded on the
`landed-work-test` step in the result. Nothing in the code path escalates to
force on its own.

## Process custody: job objects, not `lsof` and not process groups

`bin/fm-teardown.sh`'s Fix 2 finds every process whose CWD is under the task's
worktree or tasktmp with one bounded `lsof -a -d cwd` scan, then TERM -> KILL
with an identity recheck between passes. Its lsof-less fallback signals the
pane's process group. Neither primitive exists on Windows.

The replacement (report section 4.3) is a **Win32 job object per task**,
`Local\firstmate-task-<id>`:

- A process assigned to a job cannot leave it, and everything it spawns is in
  the job too. `TerminateJobObject` is a complete answer where `kill -- -$pgid`
  is best effort - a child that re-groups escapes the Unix version, which is
  exactly how the observed leaks (`go test` binaries reparented to init)
  happened.
- **Lifetime**: a named job lives while any handle is open OR any process is
  assigned. firstmate's spawner exits long before teardown, so custody survives
  through the assigned processes. `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is
  deliberately NOT set - it would kill the worker when the spawner exits.
- **Open-by-name failing is ambiguous** and is reported as such: it means either
  the task never registered custody or every process has already exited.
  `Stop-FmTaskJob` returns `not-found`, teardown records the step as one that
  did NOT run, and it continues - because the pool return is itself a
  fail-closed backstop on Windows (a delete fails while anything holds the
  directory).
- **What is lost**: the discovery half. A process some other tool started inside
  the worktree is not in our job. Section 4.3 accepts that loss because the OS
  enforces the guarantee harder than Linux does, and `Get-FmFileHolderProcess`
  (Restart Manager `RmGetList`) names the holder in the refusal. Restart Manager
  reports handles on FILES only; it can explain a refusal, never authorize a
  delete.

The spawn path is what puts a process under custody: `New-FmTaskJob` then
`Add-FmTaskJobProcess` with the pane's process id (herdr's `pane process-info`
is MEASURED PASS on Windows).

## The stale-git-lock probe

`bin/fm-lock-lib.sh`'s protocol is kept exactly; only the primitive is replaced.
A lock is provably stale iff ALL of:

1. the lock file exists,
2. no live process holds it - `Test-FmTeardownGitLockHeld`,
3. nothing holds the companion directory - `Test-FmTeardownDirectoryHeld`,
4. its mtime age is at least `FM_STALE_WORKTREE_LOCK_AGE_SECS` (default 30),
5. it is not itself a symlink - removing one would follow the link and delete
   something else entirely.

Any uncertainty returns "not stale". Never remove a lock the proof rejects.

**The primitive** (report section 4.3 item 2): git holds its lock file open for
the whole operation, so an exclusive open (`FileShare.None`) that SUCCEEDS is
direct proof that nothing holds it. That is the OS's own arbitration rather than
a snapshot of a table, so it is stronger than lsof's answer. Verdicts are
`absent` / `free` / `held` / `unknown`, and `unknown` is treated exactly like
`held`.

**On non-Windows the probe returns `unknown`, always.** POSIX advisory locking
means a successful exclusive open proves nothing; claiming `free` there would
delete a lock a live git is holding. The consequence is that the stale-lock
recovery path is a no-op on a Linux development host - which is the correct
fail-safe direction.

**The companion-directory leg** has no Windows equivalent to lsof's cwd scan, so
it consults job custody instead: `holders` / `none` / `unknown`, with `unknown`
as strong a refusal as `holders` (the bash rule that a missing lsof means
"assume live"). A task with no custody job therefore never gets its lock
removed - the return's bounded retries and the OS's own fail-closed delete carry
that case.

## Returning the worktree, and the lease rules

`Invoke-FmTeardownWorktreeReturn` runs `treehouse return <path> --if-lease-id
<id> --force`:

- **`--if-lease-id`** is what stops a return recycling a lease the pool has since
  re-issued. A record with no lease id is returned unconditionally (there is no
  identity to condition on) and that is reported, not hidden.
- **`--force`** is treehouse's own "return even though it is dirty" flag. It is
  safe only because the landed-work test already passed above it.
- **A failed return keeps everything.** The worktree, the meta and every state
  file stay in place, because deleting the record that names the worktree is how
  a still-held lease becomes invisible.

The transient-`index.lock` patience protocol is ported exactly: retry
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` times (default 3) waiting
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` (default 1s, falling back to the
older `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` name), keyed off the error TEXT
rather than the lock file's presence; any non-lock failure aborts immediately;
after the retry window a provably stale lock is removed, the safety checks
re-run, and the return is attempted once more.

## Ordering: pane close BEFORE the return

The bash closes the pane after returning the worktree. Windows locks open files,
so the return fails while anything holds a handle or a cwd inside the worktree.
Report section 4.3 settles the order as close-pane -> terminate-job ->
return-with-retries -> name-holders-and-refuse. The cost is that a refusal after
the custody step leaves the pane closed; the benefit is that the return is only
attempted once the worktree is provably ours.

## Cross-area binding

Resolved by name at call time through `Resolve-FmTeardownOwner`; a missing owner
is reported as a step that did NOT run, never as one that passed.

| Expected function | Replaces | Direction when absent |
| --- | --- | --- |
| `Test-FmDecisionHoldComplete -TaskId -FirstmateHome`, or `Test-FmDecisionHoldVerified -Id` (either name is accepted) | `bin/fm-decision-hold.sh verify` | REFUSE (fail closed - destructive step) |
| `Invoke-FmNoMistakes`, `Get-FmNmField`, `Test-FmNmHeadMatchesWorktree` (crew-state area) | `bin/fm-nm-run-lib.sh` | the run-conclusion step reports nothing-to-do; the local fallback parse still attributes correctly |
| `Test-FmLifecycleRegularFile`, `Test-FmLifecycleRegularDirectory` (lifecycle area) | the bash path-safety tests | a local copy of the same predicate is used |
| `Test-FmSessionTasksAxiBackendAvailable -ConfigDir` (landed) | `fm_tasks_axi_backend_available` | fall back to the manual backlog reminder |
| `Remove-FmHerdrPane`, `Test-FmHerdrEndpointGone` (landed) | the herdr adapter | pane close is unconfirmed -> the endpoint gate refuses |

Consumed from other landed areas: `Invoke-FmGit`, `Get-FmGitOutput`,
`Get-FmGitDefaultBranch` (FmWorktree), `Invoke-FmChildProcess`,
`Get-FmMetaValue`, `Get-FmMetaBackend`, `Get-FmMetaTarget`, `Test-FmTaskIdShape`,
`Write-FmTextFileLf`, `ConvertFrom-FmJsonSafe`, `Get-FmJsonValue`
(FmBackendHerdr).

`Invoke-FmChildProcess` gained an optional `-StandardInput`, which is how
`git show | git patch-id --stable` is composed without a shell pipe.

## Not ported, and refused by name

Each of these refuses loudly rather than being approximated, because half of any
of them is worse than none:

- **secondmate home retirement** - descendant task locks, the registry entry,
  process-event snapshot/restore, and child-work discard are their own area. The
  in-flight-children refusal IS ported and fires first.
- **the Orca backend** - dropped by directive.
- **the myfirstmate public-followup gate** and **remote secondmates** - deferred
  in the port scope (report section 2).
- **the Herdr presentation journal** and the focus-preserving projected close -
  the backend area owns the projection; this port closes the exact recorded pane
  and nothing else.

## What is WINDOWS-UNVERIFIED here

Marked in the source at each site:

- every P/Invoke in `FmJobCustody.ps1` (job objects and Restart Manager). The
  Win32 semantics are documented and stable; none of it has run on Windows.
- the exclusive-open probe's verdict against a lock a live `git.exe` holds.
- the `treehouse` CLI's behaviour on Windows generally (inherited from the
  worktree area).

The tests split accordingly. The degradation contract - every entry point
reporting "not proven" rather than "nothing to kill" - is covered everywhere and
is the part that protects work. The real terminate-and-verify path is covered by
tests that SKIP off Windows rather than silently passing.

## Provenance: the lifecycle area's teardown

Two areas ported teardown in parallel. The captain's decision (2026-08-12) was
that this one lands and the lifecycle area's four teardown files are dropped,
because that version refused the herdr backend - the only backend this port
ships - and returned worktrees with an unconditional `treehouse return --force`
that could recycle a re-issued lease.

Nothing was lost in the swap. Carried over from it, under its exact names where
another area resolves them: the per-task control lock (`Enter-FmTeardownLock` /
`Exit-FmTeardownLock` / `Test-FmTeardownLockOwnerAlive`), the parked-run
conclusion (`Get-FmTaskParkedRunId` - `tests/FmCrewState.Tests.ps1` calls it
directly - and `Stop-FmTaskNoMistakesRun`), the PR-check artifact validation
(`Remove-FmTaskPrPollArtifact`), the `remote_host` refusal, the
treehouse-not-installed pre-check, the symlinked-lock refusal, the
`config/backlog-backend` fallback read, and `--help` on the entry point.

Deliberately NOT carried over: the blanket herdr/orca refusal (the defect that
decided the swap), the unconditional force-return, and the
`ExitCode`/`Messages` return shape - this port throws on refusal so a refusal
stays distinguishable from a bug, and `bin/fm-teardown.ps1` maps it to exit 1.
