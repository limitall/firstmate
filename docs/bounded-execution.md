# Bounded execution, and the worktree-tangle detector

Two small owners that other areas were already calling by name and not finding.

| This module | Ported from | Owns |
| --- | --- | --- |
| `module/Firstmate/Private/FmBounded.ps1` | the process-group half of `bin/fm-timeout-lib.sh`, `bin/fm-watch.sh`'s `run_check_process` | the kill-on-close job policy, on top of the teardown area's job shim |
| `module/Firstmate/Public/FmBounded.ps1` | `fm_run_timed`, the check half of `bin/fm-watch.sh` | `Invoke-FmBoundedCommand`, `Invoke-FmValidatedCheck`, `Test-FmCheckAuthenticated` |
| `module/Firstmate/Public/FmTangle.ps1` | `bin/fm-tangle-lib.sh` | `Get-FmPrimaryTangleBranch`, `Get-FmDefaultBranch` |

## Exit 124 is the contract

GNU `timeout`, the perl fallback and the bash fallback in the reference
implementation all agree: **124 means the bound was hit**, and nothing else.
Callers branch on that number, so this port keeps it rather than inventing a
boolean of its own. `Invoke-FmBoundedCommand` returns `ExitCode`, `StdOut`,
`StdErr`, `TimedOut` and `Mechanism`, and never throws for a command that fails
or does not exist (127 with the reason in `StdErr`).

A **non-positive bound is refused**, because `timeout 0` and `alarm 0` both
DISABLE the deadline in the original. A caller that passes 0 would otherwise get
an unbounded run under a name that promises the opposite.

## The whole tree dies with the bound

The bash versions put the child in its own process GROUP (perl `setpgrp`, or
bash monitor mode) and signal its negative pid, so a vendor CLI spawned by a
check script cannot outlive the bound. Windows has no process groups of that
shape. Report section 3.3 names the replacement and this implements it:

- create a **Job Object** with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`,
- assign the child immediately after `Process.Start`, so everything it spawns
  from that moment is created inside the job,
- `TerminateJobObject` on timeout.

Kill-on-close matters as much as the terminate does: if the watcher itself dies,
the last handle to the job closes and the OS reaps the tree. A job object is
also strictly stronger than a Unix process group here - a child cannot escape by
re-grouping itself.

**One P/Invoke surface, two lifetimes.** `Private/FmJobCustody.ps1` (teardown
area) already owns every kernel32 job-object declaration this module makes, so
bounding adds a policy on top of it rather than a second set of imports:
`JobCustody::CreateKillOnClose` is the anonymous, kill-on-close job this needs.
The difference from custody is the lifetime, and it is the whole point - a
task's custody job must OUTLIVE the process that created it so teardown can find
it later, while a bounded run's job must die WITH its owner so a crashed watcher
cannot strand a check's tree.

**# WINDOWS-UNVERIFIED: no job-object call in this module has executed on
Windows in this repo.** Everywhere else - and whenever the shim fails to load -
the fallback is .NET's `Process.Kill($true)`, which walks the child list at kill
time. That is the weaker `taskkill /T` guarantee the report describes, which is
why the job object is the primary path rather than the only one. The returned
`Mechanism` says which ran, and `FM_BOUNDED_FORCE_FALLBACK=1` forces the
fallback so both paths are exercised on one platform.

`Invoke-FmChildProcess` (backend area) stays the generic argv runner for
ordinary CLI calls; its `-TimeoutSeconds` is a courtesy bound on a cooperating
tool. This file owns the other thing: a hard bound on code firstmate does not
trust, where the caller must be able to tell "it ran and said nothing" from "it
never finished".

## The validated-check seam

`Invoke-FmWatchCheckSweep` calls `Invoke-FmValidatedCheck <path> <state>
<timeout>` and treats `$null` or `Authorized = $false` as
`check: rejected unauthenticated state checks`. A check executes only when ALL of
these hold:

1. it is a `*.check.ps1`. A `*.check.sh` belongs to a Linux firstmate sharing
   the home; this port has no bash and never invents one, so the `.sh` is
   REFUSED rather than skipped. The sweep enumerates both extensions precisely
   so the refusal is loud;
2. it is a regular file directly inside the state directory, and not a reparse
   point - a check that is a link points somewhere nobody authenticated;
3. the check-registry seam authenticates it.

**Today every check is still refused**, because the registry (the port of
`bin/fm-check-register.sh`'s sha256 binding) is not in the module. That is the
same observable behaviour the watcher had before, with the execution half now
built and tested behind it. When that area lands it publishes
`Test-FmCheckRegistered -Path -State`, or takes `Invoke-FmValidatedCheck` over
wholesale and calls `Invoke-FmBoundedCommand` itself.

**Snapshot before execute.** What runs is never the file that was
authenticated: the bytes are copied to a private temporary inside the state
directory, re-hashed, and the SNAPSHOT is what the bounded child executes. That
closes the window between "authenticated" and "executed" in which the original
could be swapped - the same reason the bash watcher runs from a snapshot. A hash
that changes between the two reads is a refusal, and the snapshot is removed
whatever happens.

A check that hits its bound produces no output, so - exactly as in bash - it
wakes nobody. The timeout is written to the triage log instead, because a check
that never finishes is a supervision fact even when it is silent.

## The worktree-tangle detector

`Public/FmGuard.ps1` already carried the whole alarm - banner, read-only
wording, restore command - behind a seam nothing in the module answered, so the
documented degradation ("no worktree-tangle alarm") was the only behaviour
anyone got. `Public/FmTangle.ps1` answers it.

Tangled means: a real work tree, **not** a linked worktree, on a **named**
branch that is not its default branch. Every legitimate state is silent - the
primary on its default branch, a detached HEAD, a linked worktree, a fresh repo
with no commits, a directory that is not a checkout at all. Both functions
return a string and never throw: the caller is an alarm, and a guard that throws
is a guard that blocks.

**One rule differs from `bin/fm-tangle-lib.sh`, deliberately.** Bash keeps
linked worktrees quiet by relying on detached HEAD, because that is how they sit
in the bash fleet. This port's crewmates work on NAMED branches inside linked
worktrees, so the detached-HEAD test alone would fire the alarm inside every
crewmate. The detector compares git-dir against git-common-dir instead - the
same test `FmBootstrap`'s own fallback already used, so publishing this owner
cannot make bootstrap noisier than it was without one.
`tests/FmTangle.Tests.ps1` pins that case against a real `git worktree add`.

Both functions bind positionally (`Invoke-FmSeam -Arguments @($root)`, how the
guard calls them) and by name (`& $shared -Root $Root`, how bootstrap calls
them). The tests assert both, because those two call styles are live in the
module today.

## Maintaining this file

Keep it to what a future session needs before changing these owners: the 124
contract, why the job object replaced the process group, the three conditions a
check must satisfy, and the one place this detector deliberately differs from
bash. Point at the test that pins a behaviour rather than restating it.
