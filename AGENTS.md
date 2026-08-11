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
- `docs/lifecycle.md` - briefs, the wake classifier, teardown and the local
  merge: the landed-work test and the rule that every inconclusive answer
  refuses, which task shapes teardown refuses rather than half-performs, and how
  this area degrades when another area's owner is absent.

## Cross-area composition

Areas resolve each other by name at call time and degrade explicitly when an
owner is absent, so any one area can be developed and tested alone. Two rules
follow:

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
- **A degradation test stops testing degradation once the owner lands.** Suites
  asserting the "owner not loaded" branch must stage the absence at the
  `Resolve-Fm*Command` seam. Deleting the function is not enough - the
  foundation suites import the manifest, and an imported module keeps exporting
  the name whatever the test session's function table says.

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

Keep the analyzer clean of Error and Warning findings; its three excluded rules
each carry their reason in `PSScriptAnalyzerSettings.psd1`. The lock and state
suites spawn real background processes on purpose - every concurrency defect
found in this port was found by running them, never by reading the code.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
