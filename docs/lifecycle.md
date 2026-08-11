# Task lifecycle: briefs, classification, teardown, local merge

The Windows-native port of firstmate's task lifecycle. Source of truth for the
behaviour is the bash original in the firstmate repo; this document records what
was ported, what was deliberately not, and where the port touches another area.

| PowerShell | ported from |
| --- | --- |
| `Private/FmBrief.ps1`, `Public/FmBrief.ps1`, `bin/fm-brief.ps1` | `bin/fm-brief.sh` |
| `Private/FmClassify.ps1`, `Public/FmClassify.ps1` | `bin/fm-classify-lib.sh` |
| `Private/FmTeardown.ps1`, `Public/FmTeardown.ps1`, `bin/fm-teardown.ps1` | `bin/fm-teardown.sh` |
| `Private/FmMerge.ps1`, `Public/FmMerge.ps1`, `bin/fm-merge-local.ps1` | `bin/fm-merge-local.sh` |
| `Private/FmCrewState.ps1`, `Public/FmCrewState.ps1`, `bin/fm-crew-state.ps1` | `bin/fm-crew-state.sh`, `bin/fm-nm-run-lib.sh` |
| `Private/FmLifecycle.ps1` | the helpers the bash lifecycle scripts each carried inline |

## The landed-work test

`Test-FmTeardownSafety` is the one that matters. Teardown hard-resets and removes
the worktree and kills its processes, so a refusal is a stop-and-investigate
result, never an obstacle to bypass.

Work has landed when it is committed **and** any of:

- reachable from some remote-tracking branch (a fork counts, so
  upstream-contribution PRs satisfy this in any mode);
- its PR is merged and GitHub reports a head containing the current local work,
  either directly or - for commits that exist only locally - by patch identity;
- its content is already in the up-to-date default branch, which is the
  squash-merge-then-delete-branch shape;
- for `local-only`, merged into the **local** default branch.

Uncommitted changes are never landed. The scout and secondmate carve-outs and
`-Force` are the only ways past the checks, and `-Force` means exactly one thing:
the captain has explicitly authorized discarding that work.

**Every inconclusive answer refuses.** A `gh` error falls back to the content
check; an inconclusive content check refuses. An inspection that cannot run at
all - a corrupt index, a missing repository - refuses exactly like unlanded work.
That asymmetry is the design: a false refusal costs a rerun, a false success
destroys work that exists nowhere else.

`Test-FmTeardownSafety` returns `Code` 0 (proceed), 1 (refuse), or 3 (a git lock
made the inspection impossible). Only 3 is retryable, and only after
`Clear-FmTeardownStaleSafetyLock` proves the lock stale - older than
`FM_STALE_WORKTREE_LOCK_AGE_SECS` (default 30) with no live holder. A lock that
cannot be proven dead is left alone: the fix for a transient `index.lock` is
patience, not `rm`.

## What teardown refuses to attempt

`Invoke-FmTeardown` covers local ship and scout tasks on an ordinary task
worktree. These shapes refuse before anything is touched, because each owns
safety machinery outside this area and a half-performed teardown is worse than
none:

| shape | why it refuses |
| --- | --- |
| `kind=secondmate` | retiring a home needs the child-work inventory, home removal, and registry update |
| `remote_host=` set | the retirement runs on the host that owns the route |
| `backend=orca` / `backend=herdr` | those worktree and pane lifecycles (including the focus-preserving close) are the backend area's |
| scout with no decision-hold verifier available | the unresolved-decision completion gate is a real gate; with no verifier it cannot pass |

The last one fails closed on purpose. When a decision-hold verifier
(`Test-FmDecisionHoldVerified`) is present in the module, it is used; until then a
scout teardown needs explicit discard authority.

Two further pre-teardown steps from the bash original are **not** ported:
reaping leaked descendant processes by working directory, and the abandoned
remote-job-worker sweep. Both are best-effort in the original and neither is a
safety gate; the process-inventory half is platform work for the runtime area.
Concluding this task's own parked no-mistakes run **is** ported
(`Stop-FmTaskNoMistakesRun`), because a run left parked at a gate with no worker
to answer it holds a fleet slot indefinitely.

The worktree return still goes through `treehouse`. If it is unavailable the
teardown aborts **before** deleting the task branch, so nothing is lost.

## Integration seams

The lifecycle calls into other areas by looking the function up and degrading
honestly when it is absent:

| function | when absent |
| --- | --- |
| `Stop-FmBackendEndpoint` | warns and continues - the endpoint close is best effort in the original too |
| `Get-FmBackendBusyVerdict` | `Get-FmCrewState` reports `unknown`, never `working`: absorb-only-when-provably-working means a missing reader must surface the wake |
| `Test-FmDecisionHoldVerified` | scout teardown refuses (above) |
| `Test-FmTasksAxiCompatible` | the backlog reminder falls back to whether `tasks-axi` is on PATH |

## Classification

`Public/FmClassify.ps1` is the shared wake classifier. Two rules carry the
weight:

- **Verb-aware captain relevance.** The free-text tokens (`PR ready`,
  `checks green`, `merged`, …) only apply to a line with no leading verb, so
  `working: rebased onto merged #76` stays absorbed.
- **Keyed decisions.** `needs-decision`/`blocked` opens a decision under its
  `[key=<slug>]` (or `default`); only `resolved`/`captain-held` carrying that
  exact key closes it. A later unrelated `done:` never clears an open captain
  decision. Reserved key namespaces (`pending-reply-`) only transition on a note
  that speaks their vocabulary, so no other writer into the same stream can claim
  or clear them.

`Get-FmOpenDecisionIncremental` is the bounded-cost sibling: it folds only the
bytes appended since its last call through the same per-line rule, so the two
strategies cannot disagree about what is open.

Collection-returning functions return a real array even when empty, so
`.Count` and indexing always work. That means the result is one object in a
pipeline - use `$open = Get-FmOpenDecision …; foreach ($d in $open) { … }` rather
than piping.

## Platform notes

- Every generated artifact is written LF-only UTF-8 without a BOM, on every
  platform, so a Linux firstmate and this one read each other's files. Brief
  output is verified byte-identical to the bash scaffolder across all eight
  generated variants; the fixtures in `tests/fixtures/brief/` were captured from
  `bin/fm-brief.sh` itself.
- Generated briefs still point at the repo's `bin/fm-ensure-agents-md.sh` and
  `bin/fm-herdr-lab.sh` by their real names. That text is part of the brief
  contract and must not diverge per platform.
- The open-decisions cursor records file identity as a hash of the bytes it has
  already consumed rather than the bash version's `dev:inode`, which .NET does
  not expose portably. An append leaves it unchanged; a recreated file at the
  same path changes it. The cursor is private, and deleting it just forces one
  full re-fold, so a cursor written on the other platform costs one re-fold and
  nothing else.
- `# WINDOWS-UNVERIFIED:` marks the one behaviour that cannot be exercised on
  Linux: the exclusive-open probe in `Test-FmTeardownLockProvablyStale`, which is
  how Windows detects a live lock holder. On Linux the open always succeeds, so
  that probe can only ever add refusals there, never remove them.

## Running the tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

The suites dot-source the module's own files, so they run before the module
manifest exists. `tests/FmLifecycleCli.Tests.ps1` runs the real `bin/fm-*.ps1`
entry points from a copy of the repo, adding a stand-in manifest only when the
real one is not present yet.

To regenerate the brief fixtures, run `bin/fm-brief.sh` from the firstmate repo
with `FM_ROOT_OVERRIDE=/fm/root` and `FM_HOME=/tmp/fm-brief-fixture-home` for
each variant named in `tests/FmBrief.Tests.ps1`.
