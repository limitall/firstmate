# Project agent memory

firstmate-win is a native Windows / PowerShell 7 port of firstmate. The bash
original is the specification; read the corresponding `bin/*.sh` before writing
or changing an equivalent here. Reference checkout:
`/home/adit-admin/dhaval_first_test/firstmate` (read-only; `AGENTS.md` section 2
lists the state-file formats).

## Rules that apply to every change here

- **PowerShell 7 only** (`#requires -Version 7.0`). No Windows PowerShell 5.1
  idioms.
- **No Linux dependency, ever.** No WSL, Git Bash, Cygwin, MSYS; never shell out
  to `sh`, `bash`, `sed`, `awk`, `grep`, or `jq`. Reaching for one means a wrong
  turn - parse JSON with `ConvertFrom-Json`, run child processes with an argv
  array, not a command string.
- **State files are a byte-for-byte shared contract** with a Linux firstmate:
  `state/<id>.meta`, `state/<id>.status`, wake-queue records, brief format.
  Write them UTF-8 **without BOM and with LF only** - Windows PowerShell's
  defaults break both. See `Write-FmTextFileLf` / `Add-FmTextLineLf`.
- Use `Join-Path`, never a hard-coded separator. Compare paths through
  `Test-FmPathEqual`, which is case-insensitive on Windows and case-sensitive on
  Linux; getting that backwards silently defeats the worktree-isolation guard.
- The module runs under `Set-StrictMode -Version Latest` and
  `$ErrorActionPreference = 'Stop'`. Two consequences bite: accessing a missing
  property on a `ConvertFrom-Json` object **throws** (use `Get-FmJsonValue`),
  and `Write-Error` **terminates**. A function that returns a verdict must
  either `throw` deliberately or use `Write-Error -ErrorAction Continue`; name
  hard-requirement checks `Assert-*`, not `Test-*`.
- Every public function gets Pester tests. Run them: `pwsh -NoProfile -Command
  'Invoke-Pester -Path ./tests/'`. Do not hand back unexecuted PowerShell.
  **Run the whole directory, never one file.** Pester containers share one
  process, so an `$env:FM_*` override left set by one file decides another
  file's behaviour; that has already produced two failures that passed in
  isolation. Save and restore every environment key your tests touch.
- `tests/FmModuleAssembly.Tests.ps1` mechanises the cross-area rules below: no
  duplicate function name, the manifest imports, every `Public/` function is
  exported, and every `Fm` function a `bin/` entry point calls is exported.
  It enumerates the tree, so a new area or entry point is covered as soon as it
  exists - nothing to add to a list.
- Mark anything provable only on Windows with a `# WINDOWS-UNVERIFIED:` comment
  and a one-line reason. Where behaviour must differ by platform, branch on
  `$IsWindows`; the Linux path is a development convenience, not the product.

## Layout

```
module/Firstmate/Firstmate.psd1   manifest
module/Firstmate/Firstmate.psm1   loader
module/Firstmate/Private/*.ps1    internals, one file per area
module/Firstmate/Public/*.ps1     exported verbs, one file per area
bin/fm-*.ps1                      thin entry points, one per command
tests/*.Tests.ps1                 Pester 5+, one per area
docs/                             per-area design notes
```

`bin/` scripts are thin: they resolve the module, forward arguments, and map
outcomes to exit codes (0 success, 1 refusal or failure, 2 usage). Refusals go
straight to stderr via `[Console]::Error.WriteLine`, not `Write-Error`, so a CLI
message is not wrapped in a PowerShell error record. Entry points may only call
**exported** functions - a private helper is unreachable once the manifest
governs the import.

**Every entry point loads the module exactly one way**, and it is not
`Import-Module`:

```powershell
. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmThing'
```

That prelude is the only thing that makes a bin script work in a shell which
loaded no profile - a herdr pane, a Claude hook, a dispatched worker. It puts
`<checkout>/module` on `PSModulePath` for its own process (a module cannot fix
that from inside itself), imports the manifest with a dot-source fallback for a
partial build, and publishes the home into `$env:FM_HOME`. Three conventions
used to coexist here; two of them looked equivalent and silently were not.
`tests/FmModuleAssembly.Tests.ps1` now fails an entry point that imports the
module any other way.

## Where the design notes live

- `docs/herdr-backend-windows.md` - the Herdr session provider: what was ported
  from `bin/backends/herdr.sh`, what was deliberately left out, and the
  empirical quirks that must not be "cleaned up".
- `docs/worktree-isolation-windows.md` - worktree isolation via
  `treehouse get --lease`, and why that replaced scraping a pane's cwd.
- `docs/session-start.md` - the startup digest and bootstrap detection, plus the
  table of function names one area resolves from another. **Read that table
  before naming a cross-area function**: areas are built in parallel and bind to
  each other by name at call time, so a rename is a silent break.
- `docs/claude-hooks-windows.md` - the Claude hook surface, and the line between
  what is `# WINDOWS-UNVERIFIED:` documentation and what the tests actually
  prove.
- `docs/foundation.md` - the module foundation: paths, state files, locks, and
  process identity, plus where this port deliberately differs from bash.
- `docs/supervision.md` - the wake queue, the watcher and the guards: the
  byte-exact wake-queue record, why locks are directories rather than symlinks,
  why the FileSystemWatcher may only shorten a wait, and the collaborating
  functions each other area may supply.
- `docs/bounded-execution.md` - the hard bound on untrusted code: Job Objects,
  the exit-124 convention, and the validated-check seam the watcher calls. Also
  the home of the worktree-tangle detector the guard binds by name.
- `docs/lifecycle.md` - briefs and the wake classifier, plus how that area
  degrades when another area's owner is absent.
- `docs/teardown-windows.md` - teardown: the landed-work test (the one thing
  that must never be relaxed), process custody via Win32 job objects instead of
  `lsof` and process groups, the exclusive-open stale-lock probe, and the lease
  rules for returning a worktree to the pool.
- `docs/task-dispatch-windows.md` - the dispatch half of the spawn: the refusals
  that make it stop instead of guess (delivery contract, brief agreement,
  unverified adapter, missing dependency), and the `state/<id>.meta` field order.
- `docs/delivery-and-projects.md` - the guarded local merge, scout promotion,
  fleet sync, project add/create/remove, and the agent-memory file convention.
  It also states the v1 delivery-mode gate: `direct-PR` and `local-only` ship,
  and `no-mistakes` is **refused by name** rather than recorded and not run.
- `docs/backlog-manual-windows.md` - the manual backlog backend: tasks-axi's
  markdown grammar as the format contract, byte-exact round trip, and every
  refusal.
- `docs/windows-install.md` - `fm-setup.ps1` and `fm-doctor.ps1`: why the wiring
  is a managed PowerShell-profile block rather than a User environment variable,
  and why setup writes `config/backend=herdr` (without it a fresh home resolves
  to `tmux` and the captain's first digest asks Windows to install it).
- `docs/windows-quickstart.md` - the captain-facing path. Keep it short and keep
  it true: it is the only doc written for someone who has not read the others.
- **`docs/windows-e2e-evidence.md` - what has actually been executed, and
  where.** Update it whenever an area lands; it is the one place that
  distinguishes proven from merely implemented, and its honesty is the point.

## Cross-area composition

Areas resolve each other by name at call time and degrade explicitly when an
owner is absent, so any one area can be developed and tested alone. That
by-name binding is also where this port's costliest bugs have come from: every
one of them was silent, and every one had a passing test over it. The rules
below are what those bugs cost.

- **Say when a step did not run.** A missing owner is reported as a step that did
  NOT run, never as one that passed. Which direction the degradation takes is
  chosen per step: a hook that cannot evaluate its predicate fails OPEN, while a
  session that cannot verify lock ownership falls back to READ-ONLY.
- **One owner per rule.** When a shared helper exists, delegate to it rather than
  keeping a second copy (`Write-FmTextFileLf`, `Get-FmMetaValue`,
  `Test-FmPathEqual`, `Get-FmJsonValue`).
- **Two areas defining one function name is silent, not an error.** The loader
  dot-sources `Private/*.ps1` then `Public/*.ps1` in filename order, so the
  later file simply wins and every caller gets it - a Public copy also takes
  over the exported name. Before landing an area, check:
  `grep -rh '^function' module/Firstmate/{Private,Public} | awk '{print $2}' |
  sort | uniq -d` must print nothing. Where two areas genuinely need different
  contracts, name them apart (`Wait-FmLock` vs `Wait-FmPathLock`,
  `Get-FmProcessIdentity` vs `Get-FmWakeProcessIdentity`) rather than letting
  one shadow the other.
- **Match the published parameter names, or the caller degrades in silence.**
  A by-name call is `& $cmd -Foo $x`: if the owner does not declare `-Foo` the
  call throws, the caller's `catch` reads that as "no owner", and it takes its
  degraded path forever while looking healthy. This exact break made the
  turn-end guard fail OPEN on every turn. Worse, an owner that is a SIMPLE
  function (no `[CmdletBinding()]`, no `[Parameter()]`) does not even throw -
  the arguments land in `$args` and are dropped, so the call succeeds having
  discarded its input. The table in `docs/session-start.md` is the contract for
  both sides; an owner that needs more should default it, not require it.
  `tests/FmModuleAssembly.Tests.ps1` now checks this mechanically, so a
  mismatch fails the suite instead of degrading in silence - but only for an
  owner that is PRESENT, and only where the resolved name is a literal. A
  by-name call whose owner is still unported is a degradation on purpose and is
  not flagged.
- **A degradation test stops testing degradation once the owner lands.** Suites
  asserting the "owner not loaded" branch must stage the absence at the
  `Resolve-Fm*Command` seam. Deleting the function is not enough - the
  foundation suites import the manifest, and an imported module keeps exporting
  the name whatever the test session's function table says. Check such a test
  still fails when you revert the code it guards; several here did not.

## Working without the PowerShell profile

The profile block `fm-setup.ps1` writes is a **convenience** - it is what lets
the captain type a bare `fm-doctor.ps1`. It is loaded by an interactive session
and by nothing else, so nothing load-bearing may depend on it.

- `FM_HOME` resolves without any environment variable, from `<checkout>/.fm-home`
  written by setup. `Resolve-FmEntryPointHome` owns the precedence: explicit
  parameter, then `$env:FM_HOME`/`$env:FM_ROOT_OVERRIDE` (delegated whole to
  `Get-FmHome`, which keeps the bash contract's one owner), then the pointer,
  then `Get-FmHome`'s tail. **The environment outranks the pointer** so a
  secondmate or test home still wins.
- `Initialize-FmEntryPointHome` publishes ONLY the pointer's value. Publishing
  the fallback too would pin a guess into the environment where it outranks a
  pointer written a moment later - which broke `fm-setup.ps1` followed by
  `fm-home.ps1` in one session on the first attempt.
- In the doctor, `[missing]` means broken and `[warn]` means it works but not as
  ergonomically. `PSModulePath`, `PATH` and the profile block are all warnings:
  they only affect what the captain can type. Reporting them as missing is what
  made one correct install print `unhealthy: 3 missing` in a bare shell.
- **A test that only ever runs inside an already-configured session cannot see
  this class of bug** - that is exactly why it shipped with a green suite.
  `tests/FmEntryPoint.Tests.ps1` runs real `pwsh -NoProfile` children against a
  checkout copied to a temp path with `FM_*` and `PSModulePath` removed from the
  child's environment, and pairs each one with a negative control that deletes
  the pointer and asserts the old symptom returns. Add to that file when an
  entry point gains a behaviour a bare shell must have.
- Never name a Pester variable `$script:Home`: `$HOME` is read-only, and the
  failure surfaces as Pester's misleading "a 'break' or 'continue' statement
  escaped from your code". Same hazard as a `-Home` parameter.

## Which directory a Claude session starts in

**The checkout, and by default that is also the home.** On Linux the firstmate
repo root IS the home - `config/ data/ projects/ state/` are gitignored beside
`AGENTS.md` and `.claude/` - so every doc says `cd <firstmate>; claude`. This
port defaulted the home elsewhere, the captain followed the docs into a
directory with no instructions and no hooks, and nothing said so.

- `Resolve-FmEntryPointHome`'s tail is the **checkout**, which is `Get-FmHome`'s
  documented tail too. There is no second answer to "where does the home
  default to" - the installer's copy was deleted, because the two disagreeing is
  what produced the bug.
- A home that is deliberately separate is supported and made to **fail loudly**:
  setup writes a managed block into `<home>/AGENTS.md` and mirrors it to
  `<home>/CLAUDE.md`, naming the checkout. The block goes first in the file.
- **This repo's `CLAUDE.md` is a symlink, and a Windows clone does not get one.**
  Git with `core.symlinks=false` (the Windows default) writes a 9-byte file
  containing the text `AGENTS.md`. `Test-FmAgentsLinkPlaceholder` recognises
  that as a link the host failed to materialize, and setup repairs it. Anything
  that reads `CLAUDE.md` on Windows must assume this until setup has run.
- The doctor's `start Claude in` check answers the question outright, and calls a
  silent split - or a placeholder `CLAUDE.md` - `[missing]`, not `[warn]`.

## Module foundation

`docs/foundation.md` is the contract every area builds on: home resolution
(`FM_HOME` and the `data/state/config/projects` layout), state-file reads and
writes, the per-home mutexes and session lock, and process identity. Read it
before touching a state file or a lock.

- State files go through `Read-FmStateFile` / `Write-FmStateFile` /
  `Add-FmStateLine` / `Read-FmKeyValueFile` / `Set-FmKeyValueField`. They hold
  the UTF-8-no-BOM, LF-only contract above AND the retry-and-backoff discipline
  Windows needs, where it raises a sharing violation for a file another process
  holds open. (`Write-FmTextFileLf` / `Add-FmTextLineLf` predate the foundation
  and cover the byte contract only; prefer the `Fm*State` functions for anything
  under `state/`, and note that a concurrent append needs the locked one.)
- Take a lock with `Invoke-FmWithLock`, which releases even when the body
  throws. One process must not take the same lock twice.
- Adding a `module/Firstmate/Public/*.ps1` file exports its top-level functions
  automatically - the loader discovers them by parsing. Neither the manifest nor
  the loader needs editing, so separate areas never collide in one export list.

## Checks

```powershell
Invoke-Pester -Path ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

The analyzer bar is **zero findings at every severity**, not just Error and
Warning, and `tests/FmAnalyzer.Tests.ps1` runs that same repo-wide sweep inside
the Pester suite - so `Invoke-Pester` alone will fail on a new finding. Per-area
cleanliness does not compose: the repo reached 814 findings while every area
believed it was clean, which is why the check is repo-wide and why there is no
tolerated count to re-baseline.

`PSScriptAnalyzerSettings.psd1` is the one agreed bar and carries the reason for
each excluded rule. When a rule is wrong for ONE function rather than the whole
repo, suppress it there with a `Justification` argument, not a bare attribute -
the suite fails a suppression that does not say why. Two rules are deliberately
scoped rather than excluded: `PSAvoidUsingPositionalParameters` allows only
`Join-Path`, and `PSUseShouldProcessForStateChangingFunctions` stays ON so a
future state-changing entry point is still caught, with each existing internal
helper and Pester fixture carrying its own reason for opting out.

**The sweep runs in a child process, and must keep doing so.** PSScriptAnalyzer's
`Helper.GetExportedFunction` raises a NullReferenceException from
`CommandInfo.ResolveParameter` on `Firstmate.psm1`, the only file here that calls
`Export-ModuleMember`. Several rules use that helper (`AvoidReservedCharInCmdlet`,
`ProvideCommentHelp`), so excluding one only moves the crash to the next. It fires
about 3 times in 10 when the Firstmate module is loaded in the session doing the
analysing - which is every Pester session - against about 1 in 40 from a clean
one, so `tests/FmAnalyzer.Tests.ps1` shells out and retries. A crashed rule
analyses that file no further, so its findings go MISSING rather than clean;
never "fix" this by ignoring the sweep's error stream.

**The sweep is driven from an enumerated file list, not `-Recurse`**, because
"found nothing to report" and "looked at four files" are the same empty result.
The swept set is asserted to equal every `.ps1`/`.psm1`/`.psd1` on disk, so a
new area is covered the moment its files exist and a subset is a failure rather
than a pass. Nothing to add to a list when an area lands - but if you ever
narrow that enumeration, you have removed the bar, not tidied it.

The lock and state suites spawn real background processes on purpose - every
concurrency defect found in this port was found by running them, never by
reading the code. Treat an intermittent failure there as a real race until
proven otherwise: the multi-process append test looked like load flakiness and
was a genuine one (`Read-FmStateFile` raised instead of answering "missing"
when another process deleted a lock's `pid-identity` mid-open, losing status
lines). Run those suites under CPU load - several `Invoke-ScriptAnalyzer`
sweeps in parallel is enough - because a race that never loses at idle loses
reliably when contended.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
