# Delivery and project management

Windows/PowerShell port of `bin/fm-merge-local.sh`, `bin/fm-promote.sh`,
`bin/fm-fleet-sync.sh`, `bin/fm-ensure-agents-md.sh`, and the mechanical half of
the `project-management` skill's add / create / remove procedure. The bash
headers and that skill remain the authoritative statement of *why* each rule
exists; this file records what the port keeps, what it changes, and what it
refuses.

## Commands

| Command | Bash original |
| --- | --- |
| `bin/fm-merge-local.ps1 <task-id>` | `bin/fm-merge-local.sh` |
| `bin/fm-promote.ps1 <task-id> -Mode <mode> -Yolo <on\|off>` | `bin/fm-promote.sh` |
| `bin/fm-fleet-sync.ps1 [<project-dir-or-name>]` | `bin/fm-fleet-sync.sh` |
| `bin/fm-ensure-agents-md.ps1 [<dir>]` | `bin/fm-ensure-agents-md.sh` |
| `bin/fm-project-mode.ps1 [-Raw] <name>` | `bin/fm-project-mode.sh` |
| `bin/fm-project-add.ps1 <name> <source> -Mode … -Description …` | the `project-management` skill's add/clone step |
| `bin/fm-project-create.ps1 <name> -Description …` | its create step (local half) |
| `bin/fm-project-remove.ps1 <name> -Approved` | its remove step |

Public functions: `Invoke-FmMergeLocal`, `Invoke-FmPromote`,
`Invoke-FmFleetSync`, `Set-FmAgentsMemory`, `Add-FmProject`, `New-FmProject`,
`Remove-FmProject`, `Get-FmProjectMode`.

Entry points map outcomes to exit codes the same way everywhere else in this
port does: **0** success, **1** refusal or failure, **2** usage. Refusals go
straight to stderr, so a CLI message is never wrapped in a PowerShell error
record.

## Composition seam

| Direction | Name | Meaning when absent |
| --- | --- | --- |
| resolves | `Invoke-FmGuard` | The bash starts merge-local, promote and fleet-sync with `fm-guard.sh \|\| true` - an advisory supervision check whose failure never blocks the action. When the owner is absent the check simply did not run, which is the correct direction for a check that gates nothing here. |
| publishes | `Invoke-FmFleetSync` | Bootstrap's network sweep resolves this name (`docs/session-start.md`). It must stay callable with no arguments. |
| publishes | `Get-FmProjectMode` | The registered-posture reader. Fleet sync consumes it to skip local-only clones. |
| resolves | `Request-FmLock` / `Unlock-FmLock` / `Get-FmMetaLockPath` | The foundation owns every lock. This area's stand-in is gone (see below); the control-lock PATH is still named here because the foundation publishes no helper for bash's `state/.control-<id>.lock`. |
| resolves | `Test-FmTeardownGitLockHeld` | The teardown area owns "is this lock file held". Fleet sync owns only the AGE half of the staleness rule and asks that owner for the rest; absent, its fallback reaches the same verdicts. |

## v1 delivery modes: `direct-PR` and `local-only`, and nothing pretended

`Private/FmDelivery.ps1` owns one question - *can this port ship a task in this
mode* - and `Get-FmDeliveryModeSupport` is the single place that answers it.

- `direct-PR` and `local-only` are first-class.
- `no-mistakes` is **refused by name**, as a real mode this port cannot run
  rather than as an unknown one. Recording `mode=no-mistakes` in a task record
  would make every consumer treat the task as pipeline-gated while nothing on
  this platform runs that pipeline - the exact "appears to work" failure the
  port must not have.
- `no-mistakes-prod-only` is refused twice over, for two different reasons: as a
  *task* mode it is a registry policy and not a mode at all (the bash refusal,
  kept verbatim), and as a *registry* posture its product-facing leg runs the
  same unavailable pipeline.

When no-mistakes gains Windows support, `Get-FmDeliveryModeSupport` is the one
function that changes.

`Get-FmProjectMode` still returns `no-mistakes` as the fallback posture for an
unknown or unregistered project, exactly as the bash does. That is a *reading*
of the registry, not an attempt to deliver anything, so the fallback keeps its
fail-safe meaning: a typo never silently drops the gate.

## The local landing path

`Invoke-FmMergeLocal` is a faithful port, guard for guard and in the bash's
order - the first failing guard is the one whose message the operator acts on:

1. the task record exists, and its `mode=` is `local-only`;
2. the `fm/<id>` branch exists in the project;
3. the project checkout is on its default branch (origin/HEAD, else main, else
   master) and is clean;
4. the default branch is an ancestor of `fm/<id>`, so the merge is a clean
   fast-forward.

Then `git merge --ff-only`. Nothing is forced, stashed, or discarded, and a
diverged branch is sent back to the crewmate to rebase.

One message changed: the bash points a non-`local-only` task at
`bin/fm-pr-merge.sh`, which this port does not have. The refusal names what a
Windows captain can actually do instead of a script that is not on the platform.

`Invoke-FmMergeLocal` is `ConfirmImpact = 'High'`: a captain calling the cmdlet
directly is asked before firstmate writes into a project checkout. The entry
point passes `-Confirm:$false`, because reaching it *is* the approved action -
the merge decision was made before the command ran. Any programmatic caller must
do the same.

### Ownership: one merge-local, and what came from the lifecycle area

The lifecycle area also ported `bin/fm-merge-local.sh`. The captain's ruling is
that the area owner keeps the command, so this is the only `Invoke-FmMergeLocal`
and `Private/FmMerge.ps1`, `Public/FmMerge.ps1` and `tests/FmMerge.Tests.ps1`
are gone. Before deleting them, every guard, refusal and test case in that
implementation was inventoried against this one. Three things it had that this
one did not were carried over rather than lost:

- `ConfirmImpact = 'High'` (above).
- The refusal for a task whose recorded project checkout is **missing**, not
  merely unrecorded, naming the task and the path: `no project checkout recorded
  for task <id> at '<path>'`. This one had the check but split across two
  messages that each said less.
- Its test fixture's topology - the task branch checked out in a **linked
  worktree** while the project stays on its default branch, which is the real
  spawn shape - is now a test here.

Everything else it guarded was already guarded here, including the
unreadable-working-tree refusal, which now has a test on both sides of the swap
(driven by a genuinely corrupt index rather than a mock).

Two of its behaviours were dropped deliberately: its `{ExitCode, Messages}`
return shape, because every public function in this port throws and lets the
entry point map exit codes; and its `-h`/`--help` flag, because PowerShell's own
`-?` already prints this script's help and a bash-style long flag is the Linux
idiom this port exists to leave behind. Its usage exit code was `1`; this port's
documented convention is `2` for usage.

## Promotion

`Invoke-FmPromote` flips `kind=scout` to `kind=ship` and writes the decided
`mode=` and `yolo=`, preserving every other field and its order. `kind=scout`
must be a whole line, as in the bash `grep -qx`. The record is written to a
sibling temp file and moved over the original, LF-only and with no BOM, so a
reader never sees a half-written record and a Linux firstmate reads the same
bytes.

Both the mode and the yolo are **required**, and both are refused with the
bash's own guidance rather than prompted for - a mandatory PowerShell parameter
prompts, and a lifecycle command that stops to ask in a non-interactive session
wedges whatever ran it.

The printed `next:` line is the crewmate's ship instructions, in PowerShell form
(`$env:FM_HOME = '…'; ./bin/fm-send.ps1 fm-<id> '…'`). It carries the
requirement the bash carries: inventory the scratch state, **return to a clean
default-branch base**, carry over only intended fix changes, create `fm/<id>`,
implement, report done.

### The per-task interlock is the foundation's

The bash takes two locks through `fm-wake-lib.sh`'s symlink-owner mutex: a
control lock (no two lifecycle actions against one task) and a meta lock (around
the read-modify-write). This area carried a stand-in for both until the lock
area landed. It has, so **the stand-in is gone** and both locks are
`Request-FmLock` / `Unlock-FmLock`, with `Get-FmMetaLockPath` owning the
meta-lock path. Two things that owner gets right and the stand-in did not:

- **the pid file is the lock, not the directory.** Removing the directory on
  release is what broke mutual exclusion there once; the stand-in removed the
  directory. Tests assert release by RE-ACQUIRING rather than by the path being
  gone, which is the property that actually matters.
- stale recovery, holder reporting and the break protocol are one
  implementation for the whole module instead of one per area.

`Request-FmLock`, not `Wait-FmLock`: a second lifecycle action against one task
is REFUSED with the bash's message, never silently queued behind the first. Two
refusal shapes are honoured, because the owner uses both - it returns nothing
when another PROCESS holds the lock, and it THROWS on re-entry from the same
process (a lock is per process, so taking it twice would deadlock). Both are
this command's "another lifecycle action is already running" refusal. Any other
throw is rethrown unchanged: "already running" must never stand in for "the
state directory is unwritable".

The control-lock path stays here, on bash's `state/.control-<id>.lock`, because
the foundation publishes `Get-FmMetaLockPath` and `Get-FmTaskSetLockPath` but
nothing for it.

## Fleet sync

A faithful port of the sync logic, including the output strings - they are a
contract, since a session-start refresh relays them and other tooling matches on
them. One safe drift self-heals (a clean detached HEAD holding no unique commits
whose default branch is free); everything else is reported as a quantified
`STUCK: … N commits behind … - needs attention` and left alone. Pruning still
never touches the checked-out branch or a branch that still has a worktree.

The function is named `Invoke-FmFleetSync` because that is the name bootstrap's
network sweep resolves (`docs/session-start.md`), and it must stay callable with
no arguments.

**What the port replaces.** The bash proves a `packed-refs.lock` stale with
`lsof` (no holder) plus mtime age, treating a missing `lsof` as "live". Windows
has no `lsof` and needs none: git holds its lock file open while it operates, so
an exclusive open (`FileShare.None`) succeeding **is** direct proof that nobody
holds it.

That proof is the teardown area's `Test-FmTeardownGitLockHeld`, and fleet sync
asks it rather than keeping a second copy. Splitting it that way fixed a real
error in the local copy: **on POSIX the same successful open proves nothing**,
because the locking there is advisory - a live git process holding the lock lets
the open through, and deleting the lock on that basis corrupts the ref rewrite
it exists to protect. The owner answers `unknown` on a non-Windows host, and
`free` is the only verdict that proves staleness; `held`, `unknown` and a
probe that throws all leave the lock alone. That is the bash rule intact: no
proof, no removal.

**What is deliberately not ported.** The per-clone timing records
(`fm-timing-lib.sh`): they are inert unless the deferred network stage sets
`FM_TIMING_LOG`, and that stage is out of this port's scope.

## Project add / create / remove

The decisions - which project, which name, which posture, whether an existing
second mate already owns that domain - are made above these commands by the
`project-management` procedure. What these own is performing the resolved
operation without leaving the clone and the registry disagreeing.

- **Add** clones and registers, refusing an existing destination, an
  already-registered name, an unsupported posture, and a `direct-PR` clone with
  no `origin`. If anything after the clone fails, **the clone this command
  created** is removed - and only that.
- **Create** creates a *local* repository and registers it, and **never creates
  a GitHub repository**. That is outward-facing and needs the captain's explicit
  consent for the exact name, owner, and visibility; the repository is created
  with `gh-axi` above this command and brought in with `Add-FmProject`. Any
  posture needing a remote is refused with that path spelled out.
- **Remove** has two gates and neither substitutes for the other: `-Approved`
  is the captain's explicit removal decision, and the preflight runs even with
  it. The preflight reports **all** blockers at once - tasks still recorded
  against the clone, second mates that reference it, linked worktrees,
  uncommitted changes, and commits that exist nowhere else. What "nowhere else"
  means depends on the clone: a remote-backed clone's work is landed once it is
  on a remote, while a clone with no remote is tested against its default
  branch instead. A repository with no commits at all has nothing to lose and
  is not reported.

  When the clone is already gone and only a registry line remains, that line is
  removed so navigation matches reality.

**The Windows delete is fail-closed, and that is an improvement.** A directory
cannot be removed while a process holds a handle inside it or has its cwd there.
Transient holders (an indexer, a scanner) clear on their own, so the delete is
retried a bounded number of times; a persistent holder **refuses** the removal
and the registry is left pointing at what is actually on disk. Linux would
quietly succeed and strand the holder.

## The agent-memory file convention

`Set-FmAgentsMemory` is a faithful port: create the skeleton, promote a lone
`CLAUDE.md`, inject the canonical `## Maintaining this file` section
idempotently (preserving a CRLF file's own line endings), and refuse to clobber
distinct real files, a wrong link, or a case-variant `agents.md` whose link
target would dangle on a case-sensitive filesystem. The skeleton it writes is
**byte-identical** to the bash script's - verified by hashing both against the
same empty directory - so a memory file written by a Windows crewmate and one
written by a Linux crewmate are the same file.

**The one Windows difference.** On Linux `CLAUDE.md` is a relative symlink, and
that is still what this port creates when the host allows one. Creating a
symlink on Windows needs Developer Mode or elevation (the design report MEASURED
that failing on a stock runner), so the port asks for the strongest link
available in order:

| kind | what it is | drift |
| --- | --- | --- |
| symlink | the Linux shape, portable back to Linux | impossible |
| hardlink | two names for ONE file on NTFS, no privilege needed | impossible |
| copy | last resort | possible, and detected on the next run |

The kind actually created is always named in the output: `symlinked:` is a claim
about the filesystem, and a copy is never described as one.

Because a hardlinked or copied `CLAUDE.md` *is* a real file, the bash's "both
are real files" refusal would otherwise make the command permanently unusable on
such a host. So on Windows only, a real `CLAUDE.md` that is byte-identical to
`AGENTS.md` is recognized as a materialized link and re-synced instead of
refused; a `CLAUDE.md` whose content differs is still refused, on every platform.

## Module assembly

`tests/FmModuleAssembly.Tests.ps1` checks the things that only break when the
areas are combined: no function name defined in two files (the loader
dot-sources in name order, so a duplicate silently *replaces* the earlier
definition instead of colliding loudly), every `Public/*.ps1` defining the
function it is named after, approved verbs throughout, every `bin/*.ps1`
parsing, no entry point calling an `*-Fm*` function no area defines, and the
documented exit codes as observed from real child processes.
