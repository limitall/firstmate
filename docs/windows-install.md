# Setup and the doctor

The install area: `bin/fm-setup.ps1`, `bin/fm-doctor.ps1`,
`module/Firstmate/Private/FmInstall.ps1`, `Public/Install-FmHome.ps1`,
`Public/Invoke-FmDoctor.ps1`, `tests/FmInstall.Tests.ps1`.

There is no bash original for this area. The Linux firstmate is installed by
cloning it and being on a machine that already has a POSIX userland; nothing in
`bin/` corresponds to "make this machine able to run firstmate". The closest
relative is `bin/fm-bootstrap.sh`, whose *detection* the doctor models -
including its `MISSING: <tool> (install: <command>)` vocabulary, which is
reused rather than reinvented.

| Command | Closest bash relative |
| --- | --- |
| `bin/fm-setup.ps1` | none - `bin/fm-home-seed.sh` seeds a home's *content*, not the machine |
| `bin/fm-doctor.ps1` | `bin/fm-bootstrap.sh` (detection only) |

Public functions: `Install-FmHome`, `Invoke-FmDoctor`.

## What setup does, in order

1. **Home layout** - `config/ data/ projects/ state/` under `FM_HOME`.
2. **Backend** - writes `config/backend=herdr` when the home has not already
   chosen one. See "Why setup picks a backend" below.
3. **Profile wiring** - the managed block in `$PROFILE.CurrentUserAllHosts`.
4. **Claude hooks** - `SessionStart`, `PreToolUse`, `Stop` in the checkout's
   `.claude/settings.json`.
5. **Doctor** - re-reads the environment and returns the report.

## The three rules this area is built on

**Detect before mutate.** The hard prerequisites (PowerShell 7, git) are checked
before anything is written. One missing and the run refuses having created
nothing. "Half installed" is the failure mode a setup script must not have,
because recovering from it requires knowing what the installer does.

Everything else - herdr, treehouse, the Claude CLI, Pester - is a **warning**,
not a gate. A home with no herdr is a correctly installed home that cannot
dispatch yet, and the doctor line says exactly that. Conflating "cannot
dispatch" with "broken installation" would make the doctor useless on the
machine where it matters most.

**Idempotent by construction.** Directories are created only when absent; the
profile wiring lives in one delimited block that is replaced wholesale; the hook
registration rewrites exactly the three events this port owns. A second run
produces byte-identical files and reports `already` for every step. The tests
compare the bytes, not the exit code.

**Never install a tool.** `AGENTS.md` section 3's detect-ask-install rule is
mechanical here: setup reports the command and stops. `Install-FmTool -Approved`
is the only thing in this module that installs anything.

## Why the profile block, and not a User environment variable

`Import-Module Firstmate` from any session and `fm-*.ps1` on PATH are both
achieved by ONE mechanism: a managed block in the user's PowerShell profile that
prepends the checkout's `module/` to `PSModulePath` and `bin/` to `PATH`, and
sets `FM_HOME`.

The rejected alternative was `[Environment]::SetEnvironmentVariable(..., 'User')`
(the Windows registry route). It reaches cmd.exe as well, but:

- it is **silently a no-op on non-Windows .NET**, so the development path would
  report success while doing nothing - the exact dishonesty this port's
  composition rules exist to prevent;
- it cannot express "prepend to whatever this session already has";
- it needs the session restarted to take effect, with no way to also fix the
  current one.

The profile block behaves identically on both platforms, needs no admin rights
and no Developer Mode, and is repaired by re-running setup after the checkout
moves. firstmate is driven from PowerShell, so a PowerShell-session mechanism is
the whole requirement.

**The module is not copied anywhere.** It is used from the checkout, so
`git pull` updates the installed firstmate and there is no second copy to drift.

**The profile is the captain's file.** Only the text between the two markers is
authored by setup. Everything outside them is written back byte-for-byte,
including CRLF line endings - normalizing a user's profile would be an uninvited
edit. `tests/FmInstall.Tests.ps1` pins that.

## Why setup picks a backend

`Start-FmWorker -Backend` is `[ValidateSet('herdr')]`, and the design report
drops the tmux/zellij/orca/cmux adapters for Windows outright. But a home with
no `config/backend` resolves to `tmux` (the bash default, preserved by
`Get-FmBootstrapBackendName`), so the captain's very first session digest opens
with `MISSING: tmux` on a machine where tmux does not exist and would not help
if it did.

Writing the backend the port can actually drive is part of producing a *working*
home. An existing `config/backend` is never overwritten - which backend a home
uses is the captain's decision, and setup only supplies the answer when none was
given. A home that resolves to something else is a doctor **warning**, because a
shared home may legitimately be driven by a Linux firstmate on another backend.

## Hook registration scope

`Get-FmClaudeHookSettingsObject` (hook area) owns the shape; this area only
merges it into a settings file. The three events in `$FmInstallOwnedHookEvents`
are replaced wholesale, because a stale half-registration is worse than none.
Every other event and every other top-level key is carried through untouched.

A settings file that cannot be parsed is a **refusal**, not an overwrite.

When the hook area is not loaded, the step reports that it did NOT run. It is
never reported as registered - the cross-area rule.

## The module manifest

`module/Firstmate/Firstmate.psd1` and `Firstmate.psm1` are the **foundation
area's** files, taken verbatim from the `fm/fmwin-foundation` branch so the two
copies are identical and the eventual merge is a no-op rather than a conflict.
They are here because `Import-Module Firstmate` cannot work without them and
that is this area's headline deliverable. If the foundation area changes them,
its version wins - do not edit them here.

`PSScriptAnalyzerSettings.psd1` came from the same branch for the same reason
and is likewise not this area's to edit.

## What the doctor checks

| Group | Checks |
| --- | --- |
| prerequisites | PowerShell 7 (required), git (required), Pester 5+, herdr, treehouse incl. `get --lease` support, Claude CLI |
| home | `FM_HOME` set, the four directories, the resolved backend |
| wiring | `Import-Module Firstmate` resolves on `PSModulePath`, `bin/` on `PATH`, the profile block is current, the hooks are registered |

Statuses are `ok` / `warn` / `missing`; healthy means no `missing`. Every check
prints whether or not it passed, and every non-`ok` check carries a fix - a test
asserts that, so a check cannot be added without an actionable remedy.

Install commands have one owner: `Get-FmBootstrapInstallCommand` and
`Get-FmBootstrapManualInstallUrl` in the bootstrap area, which are already
platform-aware. This area never keeps a second table.

## Platform notes

- `WINDOWS-UNVERIFIED`: everything in this area was executed on PowerShell 7.6.4
  on Linux, not on Windows hardware. The mechanisms are platform-neutral
  (`$PROFILE`, `PSModulePath`, `PATH`, `[System.IO.Path]::PathSeparator`), and
  the paths it writes are built with `Join-Path`, but the run has not happened
  on Windows. `docs/windows-e2e-evidence.md` records exactly what was and was
  not executed.
- PowerShell resolves a bare `fm-doctor` as well as `fm-doctor.ps1` from `PATH`.
  The `.ps1` form is what the quickstart documents, because it is the one that
  does not depend on host command-discovery behaviour.
