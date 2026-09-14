# Worktree isolation on native Windows PowerShell

`module/Firstmate/Private/FmWorktree.ps1` is the PowerShell 7 port of the
worktree half of `bin/fm-spawn.sh`: `validate_spawn_worktree`,
`freshen_spawn_worktree_base`, and the `treehouse get` acquisition.

## The guarantee

Unchanged, and it is the whole point of this file:

1. **A worker lands in a genuinely isolated copy.**
2. **A failed isolation check stops the task** - it never warns and continues.

## The one design change: `treehouse get --lease`

The bash spawn **types `treehouse get` into the worker's own pane**, then polls
that pane's foreground cwd up to 60 times, requiring two consecutive reads to
agree on a non-project path, and takes whatever it scraped as the worktree.

That design exists because `treehouse get` opens an interactive subshell and had
no other way to report where it landed. `bin/fm-spawn.sh`'s own comments record
its costs: a transiently stale pane cwd can be accepted as the worktree (seen
live as an unrelated real checkout on some tmux/WSL setups), a rename or a
mistargeted pane can read firstmate's *own* cwd and tangle a hook into the
primary checkout, and the worktree is only ever known to the spawner as a string
scraped off a terminal.

treehouse v2 has `get --lease`: a non-interactive, durable acquire that reserves
the worktree, marks it leased in persistent state, and prints its absolute path
on stdout - banners go to stderr, and `--json` adds the lease identity. This
port acquires with `--lease --json` and reads the path from that output.

Every consequence is an improvement:

- **The path is reported, not inferred.** There is no scrape and no poll, so the
  stale-read failure mode is gone outright rather than defended against.
- **The lease is durable.** A leased worktree is never handed out by a later
  `get` and never removed by `prune`, even with no process running inside it,
  which closes the window where a crashed spawn leaves a worktree that looks
  free.
- **The release can be conditional.** `treehouse return --if-lease-id <id>`
  means a rollback can never return a worktree that something else has since
  acquired. `Start-FmWorker`'s rollback and `Stop-FmWorker -ReleaseWorktree`
  both use it, and `Stop-FmWorker` **refuses** to return a worktree whose record
  carries no lease id, because that worktree was not leased by this port and
  returning it would be a guess about who owns it.
- **The pane is created in the worktree.** Because the path is known before any
  pane exists, `New-FmHerdrTask` is called with `--cwd <worktree>`. The worker's
  shell is *born* in the isolated copy instead of being told to walk into it,
  and on Windows nothing has to host an interactive subshell for the lifetime of
  the task.

The isolation check moves earlier as a result: it runs on the leased path
*before* anything is created. `Confirm-FmWorkerWorktree` then reads the pane's
own reported cwd as an independent second reading. That check is deliberately a
**confirmation, not a discovery** - the answer is already known from the lease,
so a disagreement is not ambiguity to resolve, it is a refusal that rolls the
spawn back (pane closed, record removed, lease released).

The lease id is recorded in `state/<id>.meta` as `treehouse_lease_id=`. That is
a **new field**, additive to the bash meta contract: a Linux firstmate reading
this record ignores an unknown key, and every field it does read is byte-
identical and in the same order.

## The isolation test itself

`Test-FmWorktreeIsolation` / `Assert-FmWorktreeIsolation` are the same three
legs as bash's `validate_spawn_worktree`:

1. the candidate path resolves physically,
2. it **is** a git worktree root - its own `rev-parse --show-toplevel` resolves
   to itself, so a *subdirectory* of the primary checkout cannot pass,
3. it is not the primary checkout.

Both comparisons run on physically resolved paths.
`Resolve-FmPhysicalPath` resolves **every** component, not just the leaf,
because a symlinked or junctioned prefix would otherwise make the guard misfire
in both directions - refusing a spawn that never tangled, or missing one that
did.

`Test-FmPathEqual` uses the platform's own case rule: ordinal on Linux,
**ordinal-ignore-case on Windows**. This is not cosmetic. On Windows
`C:\Repos\Proj` and `C:\repos\proj` are the same checkout, and comparing them
case-sensitively would let the "is it the primary checkout?" leg pass a spawn
that must be refused.

The isolation tests run against **real** git repositories created in
`TestDrive`, not mocks: the guarantee is a property of real repositories, and a
mocked `rev-parse` would only prove the mock agrees with itself.

## The pooled base

Before a worker launches, `Update-FmWorktreeBase` moves the leased copy to the newest commit of the project's default branch.
The newest commit is read from two tips, the project's local `<default>` and a freshly fetched `origin/<default>`, and the base is whichever of them contains the other.

**This is a deliberate departure from the Linux refresh**, which resets to `origin/<default>` alone (upstream #2116).
That is right only where origin is where work lands.
A `local-only` merge (`Invoke-FmMergeLocal`) fast-forwards the local default branch and pushes nothing, so on a project that has any origin at all, origin falls one landing further behind every time, and a refresh that trusts origin starts every new worker behind the work already landed.
That is what happened to firstmate-win itself: its `origin` is a bare repository on the same machine that nothing updates, so every worker copy was handed out at `main` and reset backwards to that mirror three seconds later.
It is why lanes kept needing hand rebases and workers kept rediscovering bugs that were already fixed.
Upstream carries the same defect for a `local-only` project with an origin; it simply rarely has one.

| local `<default>` against `origin/<default>` | where the worker starts |
| --- | --- |
| the same commit, or local is behind | `origin/<default>` - for example a merged pull request the clone has not synced |
| local is ahead | local `<default>` - work landed here that origin never received |
| there is no origin remote | local `<default>`, with nothing fetched (upstream #3885); `New-FmProject` creates exactly these projects, and the refresh used to refuse every spawn into them |
| they have diverged | **refused**, saying how far apart they are, because starting on either tip silently drops the other's commits |

Three smaller rules sit around that choice.
The copy's cleanliness is checked before anything is fetched, so a dirty copy is reported as dirty rather than as whatever the fetch ran into first.
An origin that is configured but cannot be fetched still refuses: only a missing remote means there is nothing to be stale against.
The copy is detached in place before the hard reset, so a copy ever handed out with a branch checked out keeps that branch where it was.

A repository with no commit at all still cannot host a worker, because there is nothing to check a copy out at.
`New-FmWorktreeLease` refuses that before asking treehouse, whose own refusal names an invalid `refs/remotes/origin/main` and so points at a remote the project never had.
A project from `New-FmProject` therefore needs a first commit before its first spawn.

One consequence is worth knowing: a `direct-PR` task on a project whose local default branch holds commits landed locally starts on top of them, so its pull request carries them in its diff.
That only arises on a project that mixes `local-only` and pull-request delivery, and there the alternative is a pull request that starts behind the project's own history.

**Firstmate does not keep `origin` current when work lands, and should not start.**
`local-only` is the promise that nothing leaves the machine, and on most projects `origin` is a hosted repository, so pushing on landing would publish work the captain approved only for a local landing.
With the base read from both tips nothing depends on origin being current, which removes the only reason to add that outward-facing write.

`docs/windows-e2e-evidence.md` section 58 has the reproduction on real treehouse leases and each case above.

## Windows-unverified

This note was first written against **treehouse v2.1.1 on Linux**.
`treehouse get --lease --json` and the conditional return have since run on Windows 11 with the same v2.1.1: a real worker dispatch in `docs/windows-e2e-evidence.md` section 10.3, and four real leases through `New-FmIsolatedWorktree` in section 58.

Still unmeasured:

1. **Whether a pooled worktree can be reset while a handle is open.** Windows
   locks open files where Linux does not, so `Update-FmWorktreeBase`'s
   `git reset --hard` can fail for reasons that never occur on Linux - an
   editor, a running test, an antivirus scan mid-file. The refusal is the
   *correct* Windows behaviour (it stops the task rather than launching from a
   half-reset base), but its frequency on a real Windows host is unknown and may
   need a bounded retry.
2. **Whether treehouse's pool paths and lease state survive case-insensitive
   path comparison.** This port compares paths case-insensitively on Windows; if
   treehouse stores and matches lease paths case-sensitively in its own state,
   a lease could be recorded under one spelling and looked up under another.
3. **Junctioned pool roots.** `Resolve-FmPhysicalPath` handles junctions through
   `ResolveLinkTarget`, exercised on Linux symlinks only.
