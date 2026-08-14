# gnhf: what went wrong, what we fixed, and how it is guarded now

Written 2026-08-14. Applies to both the Linux firstmate and the Windows
firstmate; the captain's standing rule is that both follow the same practice.

## Why this document exists

The captain's instruction was clear: *"you must have to manage the GNHF whenever
it's required... I just always give command to you."* Firstmate owns gnhf; the
captain never invokes it. That makes the guards firstmate's responsibility
alone, and it means a guard that quietly fails is a guard nobody else will catch.

One did quietly fail, on the very first real run. This is the record of it.

## What gnhf is

`gnhf` - "good night, have fun" (github.com/kunchenguid/gnhf, same author as
firstmate) - is an orchestrator for long-running work. You give it an objective;
it breaks it into small steps, each in a fresh context seeded with the base plus
what earlier steps learned. Each success is a small committed change. **Failures
roll back automatically** and the next attempt takes the failure into account.

It is the right instrument when a request is a *direction* rather than a
*destination*: measurable, iterative, where many small attempts beat one large
one and a failed attempt is safe to discard. It is the wrong instrument when the
deliverable is specific, when success needs human judgement, or when a failed
attempt would be costly to undo - that work belongs to a crewmate.

## Defect 1: the config file is decorative

`~/.gnhf/config.yml` was written with the guards firstmate needs:

```yaml
agent: claude
worktree: true      # never share a checkout with the crew
push: false         # delivery stays the captain's decision
maxIterations: 40   # always bounded
preventSleep: "off"
```

**gnhf ignored all of it.** The file was present, well-formed, and had no effect.

### What that cost

The first real run - a small, safe objective, two missing module docstrings -
checked its own branch out **in the primary checkout** of `sqlToPGPlan`. That is
the checkout firstmate's crew uses as reference, and keeping gnhf out of it was
the entire purpose of `worktree: true`.

Nothing was lost: the work was on its own branch, `main` was unmoved, and the
checkout was restored with a single `git checkout main`. But the exposure was
real. Two agents in one directory is how work gets destroyed, and the only reason
it did not happen is that no crewmate was using that checkout at that moment.

### The proof, not the assumption

Passing `--worktree` **on the command line** works. Verified by running the same
objective twice:

| | primary checkout after |
|---|---|
| config file only | switched to `gnhf/add-a-module-docstri-43167f` |
| `--worktree` on the command line | still on `main`, unmoved |

The second run created `sqlToPGPlan-gnhf-worktrees/...` and left the primary
checkout alone, which is the required behaviour.

## The fix: `fm-gnhf`

Firstmate no longer calls `gnhf` directly. It calls `fm-gnhf`, which applies the
guards where they demonstrably take effect - the command line - and then
**verifies they held** rather than trusting they did.

```
fm-gnhf <repo-path> <max-iterations> <objective>
```

| Guard | How it is enforced |
|---|---|
| Own worktree | `--worktree` passed always; not overridable by a caller |
| Bounded iterations | required argument, 1-100; refuses a missing or silly value |
| Never pushes | the flag is never passed |
| Clean tree first | refuses up front and prints what is dirty |
| **Primary checkout untouched** | branch and commit recorded before, **compared after**; a mismatch is a hard failure (exit 3) with the exact restore command |

The last row is the one that matters. It does not trust gnhf to behave. It
checks, and it fails loudly when the check does not hold.

Building this was justified only because the direct path had already failed. The
captain's standing rule is to take the simplest direct path and not build
wrappers until one exposes a concrete blocker. The ignored config was that
blocker.

## Defect 2: the wrapper's own bug, found on first use

The first version of `fm-gnhf` **refused when the tree was completely clean** -
the normal case.

```bash
DIRTY=$(git -C "$REPO" status --porcelain | grep -v '^?? .gnhf' | wc -l)
```

`grep` exits 1 when it matches nothing, which is exactly what a clean tree
produces. Under `set -euo pipefail` that failed the pipeline, failed the
assignment, and killed the script **silently** - exit 1, no output, no reason.

Fixed by counting without a pipeline that can fail:

```bash
DIRTY=$(git -C "$REPO" status --porcelain | grep -cv '^?? \.gnhf' || true)
[ -n "$DIRTY" ] || DIRTY=0
```

Worth keeping in mind generally: `set -e` plus `pipefail` plus a `grep` that
legitimately matches nothing is a silent-exit trap, and it looks identical to a
refusal.

## What this cost us, stated plainly

Two defects, both found by *using* the thing rather than reading it:

1. A configuration that looked correct and did nothing.
2. A guard script that looked correct and refused everything.

Neither would have been caught by inspection. Both were caught within minutes of
a real run. That is the same lesson the Windows port taught repeatedly this week:
**a thing that looks correct and does nothing is more dangerous than a thing that
visibly breaks.**

## Standing practice from here

- Never invoke `gnhf` directly. Always `fm-gnhf`.
- Never rely on `~/.gnhf/config.yml` for anything that matters. Keep it as
  documentation of intent, not as enforcement.
- After any gnhf run, confirm the primary checkout is where it was. `fm-gnhf`
  does this, but check the output rather than assuming it ran.
- Report gnhf outcomes to the captain the same way as crew work: what changed,
  what it proved, what it could not.

## The Windows side

The captain requires both homes to follow the same practice. The **knowledge**
here applies unchanged. The **script** does not - `fm-gnhf` is bash, and the
Windows firstmate is PowerShell with no bash dependency by design.

So on Windows, one of these is needed and it is a decision, not an assumption:

1. A PowerShell equivalent of `fm-gnhf` with the identical guards, or
2. gnhf is not used on Windows at all, and that is written down so nobody
   assumes it is available.

Until one is chosen, **do not run gnhf on the Windows machine** - it would run
with the same decorative config and no verification that the guards held, which
is precisely the failure documented above.
