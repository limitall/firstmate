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

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
