# Task lifecycle: briefs, classification, local merge

The Windows-native port of firstmate's task lifecycle. Source of truth for the
behaviour is the bash original in the firstmate repo; this document records what
was ported, what was deliberately not, and where the port touches another area.

**Teardown is not here.** This area originally carried its own teardown port;
the captain's decision (2026-08-12) landed the teardown area's version instead,
because this one refused the herdr backend - the only backend the port ships -
and returned worktrees with an unconditional `treehouse return --force` that can
recycle a re-issued lease. Its behaviours that the surviving version lacked were
carried across first. See `docs/teardown-windows.md`; the landed-work test, the
stale-lock proof and the pool return all live there now.

| PowerShell | ported from |
| --- | --- |
| `Private/FmBrief.ps1`, `Public/FmBrief.ps1`, `bin/fm-brief.ps1` | `bin/fm-brief.sh` |
| `Private/FmClassify.ps1`, `Public/FmClassify.ps1` | `bin/fm-classify-lib.sh` |
| `Private/FmMerge.ps1`, `Public/FmMerge.ps1`, `bin/fm-merge-local.ps1` | `bin/fm-merge-local.sh` |
| `Private/FmCrewState.ps1`, `Public/FmCrewState.ps1`, `bin/fm-crew-state.ps1` | `bin/fm-crew-state.sh`, `bin/fm-nm-run-lib.sh` |
| `Private/FmLifecycle.ps1` | the helpers the bash lifecycle scripts each carried inline |

## Teardown

Owned by the teardown area - `docs/teardown-windows.md`, `Private/FmTeardown.ps1`,
`Public/Invoke-FmTeardown.ps1`, `bin/fm-teardown.ps1`. What this area still
contributes to it:

- `Get-FmTaskParkedRunId` and `Stop-FmTaskNoMistakesRun` conclude a no-mistakes
  run that the torn-down worktree provably owns and that is parked at a gate no
  worker will ever answer. `tests/FmCrewState.Tests.ps1` covers the attribution
  rule; the functions themselves now live with teardown.
- `Test-FmLifecycleRegularFile` / `Test-FmLifecycleRegularDirectory` are the
  path-safety predicates teardown's PR-check artifact validation binds to.

## Integration seams

The lifecycle calls into other areas by looking the function up and degrading
honestly when it is absent:

| function | when absent |
| --- | --- |
| `Stop-FmBackendEndpoint` | warns and continues - the endpoint close is best effort in the original too |
| `Get-FmBackendBusyVerdict` | `Get-FmCrewState` reports `unknown`, never `working`: absorb-only-when-provably-working means a missing reader must surface the wake |
| `Test-FmDecisionHoldVerified` | scout teardown refuses; see `docs/teardown-windows.md` |
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

- Every generated artifact is written LF-only UTF-8 without a BOM through the
  module's shared `Write-FmTextFileLf`, so a Linux firstmate and this one read
  each other's files. Git and CLI calls go through the shared
  `Invoke-FmGit`/`Invoke-FmChildProcess`, and meta reads through
  `Get-FmMetaValue`; this area keeps only `Get-FmGitFirstLine`, which takes the
  first line the way the bash `| head -1` does. Brief
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
- The exclusive-open lock probe that cannot be exercised on Linux now lives in
  the teardown area (`Test-FmTeardownGitLockHeld`), which reports `unknown`
  rather than `free` off Windows.

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
