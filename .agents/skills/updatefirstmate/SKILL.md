---
name: updatefirstmate
description: >-
  Self-update a running firstmate to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this checkout's default branch, never forced and never disruptive, then re-reads AGENTS.md so the running session is operating on the new instructions rather than the stale ones it started with.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
New tracked material - `AGENTS.md`, `bin/`, `module/`, and `.agents/skills/` - reaches this home only when this checkout fast-forwards, so a running session keeps operating on whatever it started with until you do this.

**There is no `fm-update.ps1` on this port** (`AGENTS.md` section 14), so this skill owns the procedure directly.
It is a small, guarded, fast-forward-only sequence, and every guard below is load-bearing.

## What it does

1. **Confirm the checkout is safe to advance.**
   Run these three reads first, from the checkout root:

   ```powershell
   git status --porcelain
   git rev-parse --abbrev-ref HEAD
   git fetch origin
   ```

   Stop and report, changing nothing, if any of these is true:
   - `git status --porcelain` printed anything. The checkout is dirty; an update would either fail or invite a stash, and nothing here stashes.
   - The current branch is not the default branch. Restore the default branch first (this is also what a `TANGLE:` bootstrap line asks for), then re-run.
   - `git fetch` failed. This is offline or an auth problem, not an update problem; say which.

2. **Fast-forward, and only fast-forward.**

   ```powershell
   git merge --ff-only origin/<default-branch>
   ```

   `--ff-only` is the whole safety property: a diverged checkout fails this command loudly instead of producing a merge commit or discarding anything.
   If it fails, report the divergence and stop.
   Never reach for `--force`, `reset --hard`, `rebase`, or `stash` to make it succeed.
   A tracked-files fast-forward leaves the gitignored operational directories (`data/`, `state/`, `config/`, `projects/`) untouched, so nothing in flight is disturbed.

3. **Repair the two committed links if this machine's git could not materialize them.**
   A fast-forward that brought in a change to `CLAUDE.md` or `.claude/skills` can leave a placeholder text file behind on a `core.symlinks=false` clone (`AGENTS.md` section 2).

   ```powershell
   ./bin/fm-setup.ps1
   ```

   Setup is idempotent and reports `already` for every step it did not need to change, so running it here is cheap and is the supported repair.
   Then confirm with `./bin/fm-doctor.ps1` that the `instructions` group is clean.

4. **Re-read `AGENTS.md` when your own instructions changed.**
   Compare the fast-forward's diff against `AGENTS.md`, `.agents/skills/`, `bin/`, and `module/`:

   ```powershell
   git diff --name-only <old-sha>..HEAD
   ```

   If any of those four paths appears, **read `AGENTS.md` now** before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   If none does, nothing changed for you and there is nothing to re-read.

5. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without internal vocabulary: whether firstmate is now on the latest, and what was left as-is and why.
   For example: "Captain, firstmate is now on the latest." or "Captain, I left the update alone - there are uncommitted changes here, so pulling would have risked them; they need a look first."

## Safety

- **Fast-forward only.**
  A checkout that has diverged, is dirty, is offline, or is on a non-default branch is left untouched and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive 3.
- **Only this checkout is touched, never `projects/`.**
  Refreshing project clones is a separate, separately guarded command: `bin/fm-fleet-sync.ps1`.
- **Secondmates are not updated from here.**
  The cross-home update path is not ported (`AGENTS.md` section 14). If a secondmate home exists on this machine, say plainly that it stays on its current version and needs its own update run, rather than reaching into it.
