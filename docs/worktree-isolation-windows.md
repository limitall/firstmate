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

## Windows-unverified

**Treehouse ships official Windows builds, but it has never been measured
there** - not by this repo, and not upstream as far as this port can establish.
Everything here was executed against **treehouse v2.1.1 on Linux**. Mark this as
the first thing to measure on a Windows host.

Concretely unmeasured:

1. **Whether `treehouse get --lease` works at all on Windows**, and whether its
   stdout contract (path only, banners on stderr) holds there. The parser
   accepts the `--json` body and falls back to the documented plain-`--lease`
   single-line path, so a difference in banner routing is survivable, but an
   entirely different output shape is not.
2. **Whether a pooled worktree can be reset while a handle is open.** Windows
   locks open files where Linux does not, so `Update-FmWorktreeBase`'s
   `git reset --hard` can fail for reasons that never occur on Linux - an
   editor, a running test, an antivirus scan mid-file. The refusal is the
   *correct* Windows behaviour (it stops the task rather than launching from a
   half-reset base), but its frequency on a real Windows host is unknown and may
   need a bounded retry.
3. **Whether treehouse's pool paths and lease state survive case-insensitive
   path comparison.** This port compares paths case-insensitively on Windows; if
   treehouse stores and matches lease paths case-sensitively in its own state,
   a lease could be recorded under one spelling and looked up under another.
4. **Junctioned pool roots.** `Resolve-FmPhysicalPath` handles junctions through
   `ResolveLinkTarget`, exercised on Linux symlinks only.
