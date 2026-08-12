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
3. **Home pointer** - writes the chosen home to `<checkout>/.fm-home`. See
   "Working without the profile" below; this is the step that makes the entry
   points work in a shell that loads no profile, so `-SkipProfile` does not skip
   it.
4. **Home redirect** - when the home is NOT the checkout, writes an
   `AGENTS.md`/`CLAUDE.md` into the home that stops a session started there and
   names the checkout. See "Which directory do I start Claude in" below.
5. **Checkout memory** - repairs the checkout's own `CLAUDE.md` when git left it
   as the text of a symlink it could not create.
6. **Skills link** - repairs `.claude/skills` the same way, for the same reason.
   It is the second of this repo's two committed symlinks, and an unrepaired one
   means a session loads ZERO skills while every command still works.
   `docs/instruction-surface.md` owns why the two repair ladders differ (a
   hardlink cannot name a directory; a junction can).
7. **Profile wiring** - the managed block in `$PROFILE.CurrentUserAllHosts`.
8. **Claude hooks** - `SessionStart`, `PreToolUse`, `Stop` in the checkout's
   `.claude/settings.json`.
9. **Doctor** - re-reads the environment and returns the report.

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

## Working without the profile

The profile block is loaded by an interactive PowerShell session and by nothing
else. Not by a herdr pane, a Claude hook, a scheduled task, an IDE terminal, a
window opened before setup ran - and not by the worker sessions firstmate
dispatches itself. On the captain's laptop, one install produced both of these:

```
pwsh -ExecutionPolicy Bypass -Command "fm-doctor.ps1"          -> healthy, exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File ...fm-doctor.ps1 -> 3 missing, exit 1
```

and, silently, `bin/fm-home.ps1` in the same bare shell printed the **checkout**
as the home and exited 0 - because with `FM_HOME` unset `Get-FmHome` falls
through to the code root, which is the bash contract where the checkout *is* the
home. Every state read and write in that session went to the wrong directory
while every command reported success. That is the dispatch-breaking half of this
defect, and it is the half nothing was reporting.

Two mechanisms fix it, and neither is an environment variable.

**`bin/fm-module-load.ps1` is the one prelude every entry point dot-sources.**
It derives the checkout from its own `$PSScriptRoot`, prepends `<checkout>/module`
to `PSModulePath` for its own process, imports the manifest, and publishes the
resolved home into `$env:FM_HOME`. `PSModulePath` genuinely cannot be fixed from
inside a module - the module has to be importable first - which is why this one
rule lives in a script rather than in the module.

It publishes `FM_HOME` rather than leaving each caller to look the home up
because nine functions across seven areas read `$env:FM_HOME` directly
(`Get-FmPane`, `Send-FmText`, `Start-FmWorker`, `Stop-FmWorker`,
`Invoke-FmTeardown`, the session-start paths, the lifecycle paths, the herdr
backend, the install default). One publication fixes all of them, fixes every
area that lands later without its author knowing this rule exists, and fixes the
herdr pane a dispatched worker runs in, which inherits its launcher's
environment.

It deliberately does **not** put `bin/` on `PATH`. Nothing here invokes an entry
point by bare name, and doing so would make the doctor's `PATH` check pass in
its own process while the captain's shell still could not type `fm-doctor.ps1`.

**`<checkout>/.fm-home` is where setup persists the home.** A file beside the
script is readable from the script's own location with nothing configured, which
is the only property that survives a bare shell. It is one absolute path, UTF-8
without a BOM, LF-only; blank lines and `#` comments are skipped; an unreadable
or empty pointer degrades to "no pointer" and never throws, because it is read
before anything else an entry point does. It is per-machine and gitignored - two
checkouts can point at two homes and each stays self-consistent.

`Resolve-FmEntryPointHome` owns the precedence:

| | Source | Why it is where it is |
| --- | --- | --- |
| 1 | an explicit `-HomePath` | the caller said so |
| 2 | `$env:FM_HOME`, then `$env:FM_ROOT_OVERRIDE` | delegated whole to `Get-FmHome`, so the bash contract keeps one owner; **the environment outranks the pointer** so a secondmate home, a test home or a one-off override still wins |
| 3 | `<checkout>/.fm-home` | the new step, and the only one that works with nothing configured |
| 4 | `Get-FmHome`'s documented tail | unchanged: `FM_ROOT_OVERRIDE`, then the code root |

`Initialize-FmEntryPointHome` is what the prelude calls, and it publishes **only**
step 3. Publishing step 4 as well would be writing a guess into the environment,
where it then outranks a pointer written a moment later and is exported to every
child. The first version did exactly that, and a setup run followed by
`fm-home.ps1` in the same session printed the checkout as the home - setup's own
prelude had pinned the fallback before setup wrote the pointer.

`tests/FmEntryPoint.Tests.ps1` runs real `pwsh -NoProfile` children against a
checkout copied to a temporary path with `FM_*` and `PSModulePath` stripped from
the child's environment, because a test that only ever runs inside an
already-configured session cannot see this class of bug - which is precisely why
it shipped. Every one of those tests is paired with a negative control that
deletes the pointer and asserts the old symptom returns.

## Which directory do I start Claude in

**The checkout**, and by default that is also the home.

On Linux the two are one directory: the firstmate repo root IS the home, with
`config/ data/ projects/ state/` gitignored beside `AGENTS.md`, `CLAUDE.md` and
`.claude/`. Every doc in the fleet therefore says `cd <firstmate>; claude`, and
it gives a session the instructions, the hooks and the state at once.

This port used to default the home to `%USERPROFILE%\firstmate`, separate from
the checkout. The captain did the documented thing - `cd C:\Users\ADMIN\firstmate`,
`claude` - and landed in a directory with no `CLAUDE.md` and no `.claude/`, so
the agent came up with **no instructions at all and no indication anything was
wrong**. Same class as the profile defect: the install is correct, the user does
the obvious thing, and it silently does not work.

Three things now make that impossible to hit silently.

**The default is the checkout.** `Resolve-FmEntryPointHome`'s tail is the
checkout, which is also `Get-FmHome`'s own documented tail - so the installer
stopped contradicting the module, and a fresh install reproduces the Linux
layout exactly. `.gitignore` carries the same four directories the Linux repo
ignores, for the same reason.

**A home that IS separate says so, in both memory files.** A separate home stays
supported - a secondmate home, another drive, a home shared with a Linux
firstmate - so it is not refused; it is made to fail loudly. Setup splices a
managed block into `<home>/AGENTS.md` and mirrors it to `<home>/CLAUDE.md`
(identical bytes, because the file is generated and never hand-edited, and the
agent-memory area already treats a byte-identical real `CLAUDE.md` on Windows as
a materialized link). The block goes FIRST in the file, so an agent that reads
only the top still hits the stop, and text outside the markers is preserved.

**The checkout's own `CLAUDE.md` is repaired.** This repo tracks `CLAUDE.md` as a
symlink to `AGENTS.md`. Git with `core.symlinks=false` - the default for a
non-elevated Windows git - checks that out as a 9-byte ordinary file containing
the string `AGENTS.md`. MEASURED on the captain's laptop. A session started in
the checkout then reads one filename and gets nothing, which would have defeated
the whole fix. `Test-FmAgentsLinkPlaceholder` recognises it as a link the host
failed to materialize rather than a second memory file, and `Set-FmAgentsMemory`
replaces it. Two genuinely different real files are still a refusal.

The doctor's `start Claude in` check names the directory in every case:

| | |
| --- | --- |
| `ok` | the home IS the checkout, and its `CLAUDE.md` holds the instructions |
| `warn` | they are separate, but the home carries the redirect that names the checkout |
| `missing` | they are separate and nothing says so; or the checkout's `CLAUDE.md` is the git placeholder |

## Why the profile block, and not a User environment variable

The profile block is now a **convenience**, not the foundation: it is what lets
the captain type `Import-Module Firstmate` and a bare `fm-doctor.ps1` in an
interactive session. Both are achieved by ONE mechanism: a managed block in the
user's PowerShell profile that prepends the checkout's `module/` to
`PSModulePath` and `bin/` to `PATH`, and sets `FM_HOME`.

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
| home | the home resolves without the environment (`.fm-home`), the four directories, the resolved backend |
| wiring | `Import-Module Firstmate` resolves on `PSModulePath`, `bin/` on `PATH`, the profile block is current, the hooks are registered |
| instructions | the operating contract is present AND is one, `CLAUDE.md` reaches it, the skills tree loads, `.claude/skills` reaches it |

Statuses are `ok` / `warn` / `missing`; healthy means no `missing`. Every check
prints whether or not it passed, and every non-`ok` check carries a fix - a test
asserts that, so a check cannot be added without an actionable remedy.

**Every check in the `instructions` group is required**, which is deliberately
the opposite of the wiring group below. A checkout whose contract or skills are
unreachable has every command and no first mate; that is broken, not less
ergonomic, and it is the one fault a captain would otherwise discover by noticing
the session's tone. `docs/instruction-surface.md` owns that group.

**`missing` means broken; `warn` means it works but not as ergonomically.** The
three wiring checks about `PSModulePath`, `PATH` and the profile block are all
about the captain's *interactive shell* being able to type `Import-Module
Firstmate` and `fm-doctor.ps1` bare. Running an entry point by its own path
works without any of them, so they are warnings. Reporting them as `missing` is
what made one correct install print `unhealthy: 3 missing` the moment it ran in
a shell that had not loaded the profile.

The `FM_HOME` check is no longer "the variable is set". It asks the question
that actually matters - does the home resolve with nothing configured - and so
it tests the pointer. An environment variable on top of the pointer is an
override and the line says which one is winning.

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
