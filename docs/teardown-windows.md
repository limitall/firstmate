# Teardown and process custody on Windows

The area that must never destroy work. Ported from `bin/fm-teardown.sh` and
`bin/fm-lock-lib.sh` in the bash firstmate; the design decisions for the
Windows-specific parts come from `data/fmwin-design/report.md` (section 2 port
map, section 4.3), not from this port.

| Command | Bash original |
| --- | --- |
| `bin/fm-teardown.ps1 <task-id>` | `bin/fm-teardown.sh <task-id>` |
| `bin/fm-teardown.ps1 <task-id> --force --approved-by "<authority>"` | `bin/fm-teardown.sh <task-id> --force` |

The same command retires a secondmate: `kind=secondmate` selects the retirement
gate and the two extra removal steps rather than a second entry point.

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
1. **Shape gates** - the meta must record `herdr`, and a `remote_host` (the work
   lives on another machine) is refused by name rather than half-performed.
1a. **The secondmate retirement gate** - `kind=secondmate` retires a whole
   firstmate home, so `Private/FmSecondmate.ps1` proves that home is finished
   with before any step runs. See "Retiring a secondmate" below.
2. **Scout gate** - `kind=scout` declares the worktree scratch, so the report at
   `data/<id>/report.md` IS the work product. No report, no teardown. The
   unresolved-decision completion gate then runs through its owner
   (`Test-FmDecisionHoldComplete`, below); an absent owner refuses, because a
   gate that did not run cannot report a pass.
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
8. **The home, then the routing row** (`kind=secondmate` only) - the home comes
   off disk while this home's meta still names it, and `data/secondmates.md` is
   edited last of all.

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

The `secondmate` row is a DEFERRAL, not an exemption. The retirement gate below
calls this same function back with `-Kind ship`, for that secondmate's own
worktree and for every project clone in its home, so the ordinary rules do run
over a secondmate - once, here, rather than twice with two different answers.

A `lock-blocked` verdict never becomes a pass by itself: the lock is cleared
only if it is provably stale, and then the whole test runs again. The same
re-run happens inside the pool return, so a lock discovered late cannot skip
the test either.

## The unresolved-decision completion gate

`Test-FmDecisionHoldComplete` (`Private/FmDecisionHold.ps1`) is the read side of
the policy `.agents/skills/decision-hold-lifecycle/SKILL.md` owns, and the skill
stays the owner of that policy: this answers only the mechanical question of
whether this home's durable records STILL carry an unresolved decision against
one task. The semantic inventory is the agent's attestation, because no script
can infer a decision from report prose or a visual review.

Teardown is why the question is worth asking. Discarding a scout erases the task
`bin/fm-promote.ps1` promotes in place once the captain authorises the work an
investigation recommended (`AGENTS.md` section 7), so tearing one down while its
decision is unanswered destroys what the answer would act on.

There is no `fm-decision-hold` command here (`AGENTS.md` section 14) and no hold
store, so the gate reads the two records that exist:

- `state/<id>.status`, folded by the classifier that owns the rule:
  `needs-decision`/`blocked` opens a keyed decision and only
  `resolved`/`captain-held` carrying that exact key closes it
  (`docs/lifecycle.md`). An open key is a decision that was raised and routed
  nowhere.
- this home's backlog, where the skill requires every unresolved captain
  decision to become a durable held item. A hold counts when it is ACTIVE
  (`Test-FmBacklogHoldActive`) and its kind is `captain` or absent;
  `external`/`load`/`parked`/`future` are declared dispatch holds, not decisions.

| Attribution the backlog itself states | Example |
| --- | --- |
| the held item IS the task's own item | `- [ ] <id> - ... (hold: ...) (hold-kind: captain)` |
| the task's item is blocked by the held item | `blocked-by: <key>` on `<id>` |
| the held item was discovered by the task | `discovered-from: <id>` on `<key>` |
| the held item names the task's report | `data/<id>/report.md` in the held item's title |

Nothing is inferred from prose, and every other hold in the backlog belongs to
somebody else's work. That is also what keeps the skill's rule intact that a
hold outlives the investigation that filed it: the gate reads, and never closes
one - not even under `--force`, which skips the gate rather than resolving it.

It returns a verdict record (`Verdict` / `Message` / `Detail`), not a boolean,
for the same reason `Test-FmTeardownWorktreeSafety` does: the refusal has to
name the decision. A caller must read `.Verdict`, because coercing any record to
a boolean is always true and would pass everything. It refuses just as loudly
when it cannot READ a record - an unparseable backlog, a status file that is not
an ordinary file, a home that is not there - because a gate that answered "pass"
on a file it failed to open is worse than the refusal it replaced.

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

## Retiring a secondmate

`Private/FmSecondmate.ps1`. A `kind=secondmate` teardown does not tear down a
task: it removes a whole firstmate installation - its own state records, its own
backlog, its own descendant tasks - and edits the fleet's only routing record.
Before this landed, teardown refused it by name and operators deleted the home
by hand, which is the unguarded discard this area exists to prevent.

### The gate, before anything is touched

| Proof | Refuses when | `--force` |
| --- | --- | --- |
| identity | `home=` is the launching home, the checkout, the task's worktree, or its project clone; contains either of the first two; is not shaped like a firstmate home | never |
| liveness | a lock in that home has a live holder, or its session lock is held by a live harness | **never** |
| work under way | that home has a `state/<id>.meta`, or an item in flight in ITS OWN backlog | overrides |
| unlanded work | the ordinary landed-work test refuses for its worktree or for any project clone in its home | overrides |

The identity proof exists because `home=` **defaults to the project directory**
when a secondmate is spawned without `-LabelHome` (`ConvertTo-FmTaskRecordField`),
so "the recorded home is a project clone" is a real record shape rather than a
hypothetical one. A home that is already absent is a verdict of its own (`gone`),
not an error - that is the state an interrupted retirement leaves behind, and a
rerun has to be able to finish the job, which at that point is the routing row.

**`--force` never reaches the liveness proof.** Force is captain authority to
discard WORK; it is not authority to remove a home a running agent is using, and
no approval makes that a defined operation. The two forced proofs are skipped
whole; the two unforced ones run either way, which is what makes that rule true
rather than merely documented.

The in-flight backlog read goes through `Get-FmBacklogConfig -IgnoreEnvironment`.
`TASKS_AXI_FILE` is process-wide, so honouring it would answer a question about
the secondmate's home from whichever file the operator pointed at - most likely
the launching home's, the one file this check must not consult.

### The order of removal, which is the safety property

1. the descendant leases, returned conditionally on each descendant's own
   recorded lease id. Their meta records are the only things that name those
   leases and they go with the home, so a return that fails REFUSES rather than
   being noted and walked past - the same rule that keeps the state files when
   the task's own pool return fails.
2. the home, while `state/<id>.meta` in the launching home still names it. A
   partial removal (Windows refuses a delete while a handle is open) is reported
   as a failure and names what is left.
3. this home's own volatile records, as for any task.
4. **`data/secondmates.md`, last of all.** While the row is there the home is
   findable, so it may never be removed at or before a step that can still
   refuse. Untouched lines are re-emitted byte for byte, a wrapped row's
   indented continuation goes with it, the file keeps its LF/no-BOM contract, and
   the removed lines are returned so a hand-maintained file gets an auditable
   edit rather than a silent one.

### Deliberately not acquired

Retirement does not quietly bring in the rest of the Linux provisioning
contract. Home seeding, startup convergence, the liveness sweep, cross-home
backlog handoff, the re-read nudge and every remote route remain absent
(`.agents/skills/secondmate-provisioning`), and there is no process-event state
to restore because there are no process-to-event sources here at all.

## Cross-area binding

Resolved by name at call time through `Resolve-FmTeardownOwner`; a missing owner
is reported as a step that did NOT run, never as one that passed.

| Expected function | Replaces | Direction when absent |
| --- | --- | --- |
| `Test-FmDecisionHoldComplete -TaskId -FirstmateHome` (landed) | `bin/fm-decision-hold.sh verify` | REFUSE (fail closed - destructive step) |
| `Invoke-FmNoMistakes`, `Get-FmNmField`, `Test-FmNmHeadMatchesWorktree` (crew-state area) | `bin/fm-nm-run-lib.sh` | the run-conclusion step reports nothing-to-do; the local fallback parse still attributes correctly |
| `Test-FmLifecycleRegularFile`, `Test-FmLifecycleRegularDirectory` (lifecycle area) | the bash path-safety tests | a local copy of the same predicate is used |
| `Test-FmSessionTasksAxiBackendAvailable -ConfigDir` (landed) | `fm_tasks_axi_backend_available` | fall back to the manual backlog reminder |
| `Remove-FmHerdrPane`, `Test-FmHerdrEndpointGone` (landed) | the herdr adapter | pane close is unconfirmed -> the endpoint gate refuses |

Consumed from other landed areas: `Invoke-FmGit`, `Get-FmGitOutput`,
`Get-FmGitDefaultBranch`, `Resolve-FmPhysicalPathOrRaw`, `Test-FmPathEqual`
(FmWorktree), `Invoke-FmChildProcess`, `Get-FmMetaValue`, `Get-FmMetaBackend`,
`Get-FmMetaTarget`, `Test-FmTaskIdShape`, `Write-FmTextFileLf`,
`ConvertFrom-FmJsonSafe`, `Get-FmJsonValue` (FmBackendHerdr). The retirement gate
adds `Get-FmRoot` (FmPaths), `Get-FmLockInfo` and `Get-FmSessionLockStatus`
(FmLock), and `Get-FmBacklogConfig` / `Get-FmBacklog` (backlog area). These are
called DIRECTLY, not through `Resolve-FmTeardownOwner`: each is landed, and a
safety gate that silently degraded to "no locks found" would be worse than one
that fails.

`Invoke-FmChildProcess` gained an optional `-StandardInput`, which is how
`git show | git patch-id --stable` is composed without a shell pipe.
`Get-FmBacklogConfig` gained `-IgnoreEnvironment`, so a question about ANOTHER
home's backlog cannot be redirected by a process-wide `TASKS_AXI_FILE`.

## Not ported, and refused by name

Each of these refuses loudly rather than being approximated, because half of any
of them is worse than none:

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
