# Setup and the doctor

The install area: `bin/fm-setup.ps1`, `bin/fm-doctor.ps1`,
`module/Firstmate/Private/FmInstall.ps1`, `Public/Install-FmHome.ps1`,
`Public/Invoke-FmDoctor.ps1`, `tests/FmInstall.Tests.ps1`.

The MACHINE install sits on top of it: `install.ps1` at the repo root,
`module/Firstmate/Private/FmToolInstall.ps1`, `Private/FmMachine.ps1`,
`Public/Install-FmMachine.ps1`, `Public/FmMachineStart.ps1`,
`tests/FmToolInstall.Tests.ps1`.
How that install ENDS, and how `start.ps1` answers the wrong shell, is "The last ten
seconds" below rather than part of the machine install proper.
"The machine install" is the section of that name below; everything else in this
file is about the home and the wiring, which is the step the machine install
runs in the middle of its own.

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
   it. `-KeepHomePointer` is the one thing that does - see "Provisioning a
   second home from one checkout" below.
4. **Home redirect** - when the home is NOT the checkout, writes an
   `AGENTS.md`/`CLAUDE.md` into the home that stops a session started there and
   names the checkout. Refused, with nothing written, when the named home is
   itself a checkout. See "Which directory do I start Claude in" below.
5. **Checkout memory** - repairs the checkout's own `CLAUDE.md` when git left it
   as the text of a symlink it could not create.
6. **Skills link** - repairs `.claude/skills` the same way, for the same reason.
   It is the second of this repo's two committed symlinks, and an unrepaired one
   means a session loads ZERO skills while every command still works.
   `docs/instruction-surface.md` owns why the two repair ladders differ (a
   hardlink cannot name a directory; a junction can).
7. **Instruction links** - marks `CLAUDE.md` and `.claude/skills`
   `--skip-worktree`, so an ordinary `git checkout -- .` cannot follow the
   junction and empty the skills tree behind it. `Protect-FmInstructionLink`
   owns why. It belongs to setup rather than to the machine install because
   skip-worktree is per-checkout index state that no clone and no new worktree
   inherits, so every copy has to be given it separately - which is exactly how
   it reappeared in a fresh worker copy after being fixed on the primary.
8. **Profile wiring** - the managed block in `$PROFILE.CurrentUserAllHosts`.
9. **Claude hooks** - `SessionStart`, `PreToolUse`, `Stop` in the checkout's
   `.claude/settings.json`.
10. **Doctor** - re-reads the environment and returns the report.

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

### Provisioning a second home from one checkout

A checkout has **exactly one** pointer, and it answers one question: which home
does this checkout resolve to with no profile and no environment. Setup used to
rewrite it on every run, which is correct while the captain is moving this
checkout's own home and wrong the moment the home being built belongs to someone
else.

Provisioning a secondmate is exactly that moment. Its home is built from the
primary's checkout, so setup repointed the primary at it. Nothing errored: the
running firstmate carried on and operated against the secondmate's state.

`-KeepHomePointer` withholds the write. It also withholds the session wiring at
step 9's predecessor - the `FM_HOME`/`PATH`/`PSModulePath` publication setup
normally applies to its own process - because those are the same claim at two
scopes, and a session that provisioned a secondmate by importing the module
rather than shelling out would otherwise be moved just as silently. The second
home is still built in full; only the claim on the checkout is withheld.

It is **opt-in**, not the default, because repointing is the correct behaviour
for the case it was written for. `.agents/skills/secondmate-provisioning`
requires the switch at the step that creates the home.

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

Four things now make that impossible to hit silently.

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

**A home that is itself a checkout is REFUSED.** MEASURED, 2026-08-14. A run
meaning only to repair a worker copy's skills link named one tree with
`-RepoRoot` and the primary checkout with `-FirstmateHome`. The home was
correctly judged "not the checkout", so the stop-and-redirect was spliced over
the top of the primary's own 51,675-byte `AGENTS.md`, and over `CLAUDE.md`,
which on a repaired checkout is the same file. The bytes below the block
survived; what did not is the contract's FIRST instruction, which became "do no
firstmate work from this directory" and named a disposable worktree. It was
reported as one `[updated] home redirect` line among a dozen, and was recovered
only because `AGENTS.md` is tracked in git.

`Assert-FmInstallHomeIsNotCheckout` now refuses that invocation, from
`Install-FmHome`'s gate so nothing at all is written, and from
`Set-FmInstallHomeRedirect` itself so the guard belongs to the destructive act
rather than to one caller. "Is a checkout" is the two things setup already
demands of a `-RepoRoot` plus the contract itself: `module/Firstmate`, and an
`AGENTS.md` that is not already a redirect - an `AGENTS.md` that *is* one is
generated material, so converging it destroys nothing and a re-install of a
separate home still works. Refusal rather than a prompt, because there is no
invocation this could be the right answer to: a caller who means to set that
checkout up says so with `-RepoRoot`, which is shorter AND leaves the contract
alone. The refusal names the file it would have overwritten and that
invocation. What did NOT change is the redirect for a home that is a plain
state directory: it stays unconditional, because without it `cd <home>; claude`
starts an agent with no instructions at all.

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

Install commands have one owner: `Get-FmBootstrapInstallCommand`,
`Get-FmBootstrapPortableRelease` and `Get-FmBootstrapManualInstallUrl` in the
bootstrap area, which are already platform-aware. This area never keeps a second
table, and neither does `install.ps1` - see below for what a second table cost.

## The machine install

`install.ps1` is the captain's one command on a fresh machine, and `Install-FmMachine` is all of it except the prompting.
It exists because `bin/fm-setup.ps1` deliberately installs nothing: setup answers "is this home wired", and something still has to answer "does this machine have the tools at all".

**Why the route table is not here.**
`install.ps1` used to keep its own, and the two disagreed in the one way that matters.
Measured 2026-08-17: it installed `treehouse` and `herdr` FROM NPM, where the package called `treehouse` is an unrelated single-page-application state framework and the one called `herdr` is a `0.0.0` placeholder containing nothing.
Both installs exit 0.
Nothing reported a problem until a dispatch failed with no explanation, and the bootstrap area had the correct treehouse route the whole time.
So the machine install now reads every route from that one owner, and the regression is pinned in `tests/FmToolInstall.Tests.ps1` as "never resolves treehouse or herdr to npm again".

**Never trust a package name; read a version back.**
A route is only correct if the installed command runs and prints something `Get-FmToolVersionNumber` can parse.
A command that resolves but answers nothing to `--version` is reported as unverified, never as installed, because that is the exact shape a wrong package takes.

**Which flag proves a tool is the TOOL'S answer, not a literal.**
That rule above was written as `--version` in four places, and Handy does not have one: its CLI is a clap parser declared with no `version`, so the flag is never generated and asking for it is an unknown argument that exits non-zero having printed nothing.
Reporting that silence as "not verified as the real tool" would libel a correctly installed engine, so `Get-FmToolProof` owns the question per tool and Handy's is `--list-models` - which is a stronger identity check, because the binary must start, build its own model registry and exit 0.
A tool that proves itself that way has its VERSION read from the executable's `ProductVersion`, and only after that run has already succeeded: presence still proves nothing, and a binary that will not run still has no version.
`docs/windows-e2e-evidence.md` section 45 has the measurements.

**Detection asks PATH, and then asks where the vendor actually put it.**
`Get-FmBootstrapInstalledLocation` was the install's last resort, for a vendor installer that reported success and left nothing this session could reach.
The same machine state arrives another way entirely - a captain who installed the tool themselves, before firstmate ever ran - and Handy is exactly that case, because its installer puts nothing on `PATH` at all.
Without `Find-FmToolInstalledCommand`, detection calls a working tool `missing` and the run reinstalls over a machine that was already right, which is the opposite of "re-running changes nothing".
It can only ever turn a false `missing` into a true `present`: it is reached only after `PATH` has failed, it writes nothing, and what it finds is still run before anything is claimed about it.
It is also scoped to `installer` routes, where the VENDOR chose the location - an `archive` route is placed on PATH by this installer, so for those a missing PATH entry is a truthful "not installed", and the runtime check above reads that same answer to decide whether the Visual C++ runtime is present.

**And "answers nothing" is a symptom, so the code it returned is carried with it.**
`Get-FmInstallCommandProbe` used to read the exit code to decide whether the output was a version and then discard it, which left a clean VM reporting a correctly installed herdr as "answers nothing to --version" and nothing more.
The code was `0xC0000135` and says exactly what happened: a DLL it needs is missing, so Windows stopped it before its own first instruction and it had no chance to print anything.
`Get-FmToolStatus` now carries the code, `Get-FmToolExitCodeMeaning` names the ones Windows itself chooses for a process that never ran, and `Get-FmToolUnprovenDetail` is the single owner of the sentence both the plan and the proving pass print.
Naming a cause never softens the verdict: an unproven tool is still unproven, and a required one still ends the run NOT READY.
`docs/windows-e2e-evidence.md` section 40 has the reproduction and the evidence against the alternatives.

**And the cure belongs with the cause, or the diagnosis sends the captain round a loop.**
That diagnosis shipped with `fix: ... install.ps1` under it - the run that had just produced it - and stood for two days while the captain was told the real answer by hand.
So `Get-FmToolExitCodeRemedy` sits beside the meaning and is asked the same question the meaning is asked: what did WINDOWS return, not which tool was being started.
The codes that mean a dependency is missing answer with the command that installs it, and `Get-FmToolFixCommand` prefers that over the tool's own route - because a route answers "this tool is not here", which is the wrong question for a binary that is here and dies in the loader.
That remedy needs administrator, so it says so, and **since the captain asked for it this installer also takes that step itself** - once, with one explained consent dialog, under the rules the section on it below states in full.
The remedy line survives all of it: it is what a captain who declines, or whose install fails, still gets, and it is still what a tool dying in the loader prints.
The runtime IS now checked as a requirement of its own, before anything needs it, which section 43.3 had judged against - read that judgment and the paragraph below it together, because two thirds of it survived: the fact that herdr needs the runtime lives on herdr's own catalog row rather than on a standing list of firstmate's prerequisites, and running the tool is still the stronger test and still wins over any file on disk.
`docs/windows-e2e-evidence.md` sections 43 and 44 have the measurements, the verified package identifier and both judgments in full.

**A portable install is not finished until the tool RUNS.**
The command route has ended by reaching what it installed since the Claude CLI was reported missing by the run that installed it; the portable route ended at "the bytes are on disk", so one clean-VM report contained `[missing] tool herdr` and `summary: herdr installed` together.
`Invoke-FmToolRoute` now proves a portable install by running the tool and reports `failed` - naming where the files went, and why it does not run - when it cannot.

**No TOOL route needs administrator, and exactly one step does.**
Every preferred route writes into the user's own profile: the vendor's per-user installer (Claude Code, treehouse, PowerShell 7) or a release archive expanded under `%LOCALAPPDATA%\Programs` with its directory added to the USER PATH (gh, herdr).
herdr is on the archive route for a second reason: its own installer leaves no herdr on a clean machine, twice measured, so `Get-FmBootstrapPortableRelease` takes the release that installer points at - read out of it, not guessed - and installs it directly.
That is not a claim that their installer is broken, and this file used to imply it was: their step refuses to certify a binary that will not run, and section 40 of `docs/windows-e2e-evidence.md` records that on the captain's VM the binary genuinely does not run, for a reason no install route here can fix without administrator.
`choco install gh` was measured failing with "Access to the path 'C:\ProgramData\chocolatey\lib-bad' is denied" on an unelevated session; the portable zip needed nothing.
The routes that genuinely need elevation are the winget packages, which run machine-scope MSIs.
Those are DECLARED by `Test-FmBootstrapInstallNeedsAdministrator`, named in the report, and skipped - never attempted, and never allowed to stop the rest of the run.
The Visual C++ runtime is the exception, and the section below owns it.

**The one step that asks, and why it does not break the rule above it.**
The Visual C++ runtime is not a tool and not a route: it is what herdr cannot start without, and no per-user install of it exists - measured, in `docs/windows-e2e-evidence.md` section 40.7, where Microsoft's own bundle run unelevated as `/extract` produced an empty directory and had to be killed.
This installer printed the command for it and stopped there, on the standing rule that nothing here needs elevation.
**That rule was ours and the captain overruled it**, in as many words: everything must be done from the script, with nothing left for them to run by hand.
They had already run the printed line themselves on a fresh VM - which is precisely what the rule was supposed to prevent.

It is not an all-or-nothing choice, because Windows can elevate ONE child.
The run itself stays unelevated; `Start-FmToolElevated` starts one process with `-Verb RunAs`, which raises the standard consent dialog, and `Install-FmToolRuntime` is the only caller.

**It sits on the right side of the line this file already drew.**
That line is stated in the no-prompting section below: an installer may ask a question IT composed and printed, and must never let a child it started for verification ask one.
`install.ps1` prints, before anything appears on screen, what the runtime is, which tool needs it, that Windows is about to ask permission, and that declining is safe.
A consent dialog raised immediately under that paragraph is the first kind.
A consent dialog with nothing above it is indistinguishable from something going wrong, which is why the paragraph is the requirement rather than a courtesy.

**How to decline, and what it costs.**
Say no to the Windows prompt.
The run reports the step as `DECLINED at the administrator prompt`, everything else still installs, the run finishes, and it ends exactly where it ended before this step existed: herdr cannot be proven, the machine is `NOT READY`, and the same `winget install -e --id Microsoft.VCRedist.2015+.x64 ...` line is printed for you to run yourself.
That path is reused rather than rewritten - it is `Get-FmToolExitCodeRemedy` and the herdr check, unchanged.
`-Unattended` and a redirected stdin skip the step entirely and say so: that switch's documented meaning is "never ask anything", and a consent dialog is asking - one nobody would ever see, on a run that has already gone on without a person.
`Install-FmMachine` will not raise it at all without `-InstallRuntime`, which `install.ps1` passes only after printing that paragraph to somebody who is there.

**The bar did not move.**
Installing the runtime does not certify herdr.
herdr is still proved by running it and reading a version back, the run still ends `NOT READY` when it cannot, and the runtime step deliberately gets no vote in that verdict - a machine where herdr answers `--version` is ready whatever happened to a step it turned out not to need, and a machine where it mattered fails herdr's own check anyway.

**And the detection is the file, not the package list.**
`Get-FmToolRuntimeStatus` answers in three stages, ordered so it can never report present on a machine where the loader would still fail.
A tool that imports the runtime and DIED in the loader wins first - that is the case no file check can see, where the DLL is present and older than the build importing from it.
A tool that RAN wins next, because the loader resolved every import it has.
Only then the file: `VCRUNTIME140.dll`, in the directories an x64 process searches, **and an x64 image when found** - `Get-FmToolImageMachine` reads the PE header, because "the file exists" is not the question.
`winget list` is the obvious alternative and is the weaker one: a machine carrying only the 32-bit redistributable, or an ARM64 machine carrying only the ARM64 one, has the name on disk and reports a package installed, and neither can satisfy the x64 build herdr publishes.
The remaining optimism is named rather than hidden: a copy that is present, x64 and too old reads as present until a tool is run against it, which is why the tool proof stays the authority.

`docs/windows-e2e-evidence.md` section 44 has the measurements and section 43.3 the decision this reversed.

**Three outcomes per requirement, not two.**
`Get-FmToolClassification` is the single owner of the decision, and `older` and `unsupported` must never be blurred into each other:

| class | what happens |
| --- | --- |
| `missing` | installed. Running `install.ps1` is the consent for that. |
| `unusable` | present, and this machine refuses to START it. TOLD, SKIPPED, NOT READY - a second copy in the same place would be refused the same way. |
| `older` | the captain is ASKED, once, with the installed and published versions and the cost of declining. The default is no, and declining never stops the run. |
| `unsupported` | the captain is TOLD, the step is SKIPPED, nothing is installed over the top, and the run reports the machine as NOT READY. |
| `superseded` | below the same kind of stated minimum, but what this repo needs installs BESIDE it rather than over it. Installed, without asking, and the older copy is left alone. |
| `unknown-version` | present, STARTED, and printed no readable version, so nothing about it is proven. The exit code is reported with it, because a process stopped by the loader prints nothing on either stream and the code is the only evidence there is. |
| `unknown-latest` | present, but no vendor answered, so currency is unknown rather than assumed. |

A minimum only exists where this repo STATES one, and `Get-FmToolMinimum` names where each comes from: the axi-family floors bootstrap already enforces, Pester 5 for the suite, and treehouse's `get --lease`, which is a capability rather than a number.
Nothing invents a threshold, so a tool with no stated minimum can be older but never unsupported.

`superseded` and `unsupported` differ on ONE question - does putting what this repo needs on the machine remove what is already there?
For a tool it does, so that one is told and skipped.
For a PowerShell module it does not: `Install-Module -Scope CurrentUser` writes a new version directory into the user's own module tree, PowerShell loads modules by version, and the previous copy stays loadable.
`Get-FmMachineInstallPlan` is the only caller that sets `-Supersedable`, and it sets it for every module and for no tool.
Windows ships Pester 3.4.0 on every machine, so this is not an edge case - it is what a clean machine looks like, and refusing it is what used to end a clean-machine install with a step for the captain.

`Get-FmToolUpdateCommand` exists for one difference that is not cosmetic: `winget install <id>` on an already-installed package reports "already installed" and exits 0 without upgrading anything, so a captain who agreed to an update would have been told it happened and left on the old version.
Every other route already fetches the newest thing there is, so only the winget verb is rewritten.

**Every route must be able to finish with nobody at the keyboard.**
The installer runs each one in a child shell and collects its output, so a route that stops to ask a question asks it into a pipe where nobody can see it.
winget is the case that bit: it asks the operator to accept its source agreements the first time it is used, and a run that cannot answer exits without installing anything.
Measured from the captain's install log, 2026-08-20, in an ADMINISTRATOR shell: `winget install OpenJS.NodeJS` exited 1 and installed nothing on a machine that had winget v1.9.25200 and ran it.
Elevation had nothing to do with it, and `docs/windows-e2e-evidence.md` section 35 records that the failure was first reported to the captain as an administrator problem and that they had already opened an elevated shell on that advice.

`Get-FmBootstrapWingetCommand` is the one owner of that shape, so the flags are stated once rather than once per package: `--accept-source-agreements` and `--accept-package-agreements` answer both agreements ahead of the prompt, `-e --id <id>` matches one package by its exact identifier rather than running a search that can match several and ask a second question, and `--source winget` names the one source they all come from.
Both commands printed for a human to run come from it too, because a captain who pastes one into a script meets the same prompt.
`tests/FmToolInstall.Tests.ps1` sweeps the catalog the installer actually walks rather than a list of today's tools, so a winget route added later without one of those fails in the suite instead of on a machine.

**A component we do not need must not be able to fail us.**
That is the sharper form of the rule above, and `--source winget` is where it bit.
winget queries every configured source that is not marked explicit, and on the captain's clean VM the `msstore` source failed with a certificate mismatch - a TLS-inspecting proxy, a clock skew, a locked-down image, none of it this repo's business.
One erroring source was enough for winget to stop and ask which of the working ones to use, and the install exited having done nothing, on a machine where the `winget` source was healthy and had the package.
Measured 2026-08-20: every id this repo names resolves from the `winget` source, and `msstore` has none of them, so it could never have supplied a single package here and was still able to stop the whole run.
`docs/windows-e2e-evidence.md` section 36 has the log, the source list and the searches, and section 36.8 records the rest of that class - including `Install-Module`, whose missing `-Repository` is the same shape and is deliberately left alone, because a captain may legitimately have an internal mirror registered instead of PSGallery.

Exact matching also settled a question a search had been hiding: `winget install orca` and `winget install cmux` named packages that do not exist.
Measured 2026-08-20, both answer "No package found matching input criteria" while every other id here resolves to exactly one package, so those two routes could never have succeeded - the same defect as the `npm install -g treehouse` route this area was built to remove.
Both are backends this port cannot drive, so they now answer as tmux already did, through `Get-FmBootstrapManualInstallUrl`: a named human step rather than a command that reports itself as failed.

The rest of the class is either already answered or named.
`Install-Module` is asked with `-Force`, which answers the untrusted-PSGallery question that a machine nobody has configured otherwise will ask, and `-Confirm:$false`, which refuses the other route to the same halt.
The child shell is started `-NonInteractive`, so PowerShell's own prompts do not wait on a person who is not there; a native program's prompt is its own business and is answered by that program's flags, which is what the winget flags above are.
**That applies to EVERY PowerShell child this repo starts, not only a route's**, and the switch is NOT inherited: each child decides from its own command line, so a grandchild started inside a child that has it can still prompt.
The suite child was the one that did not have it, and `-NoNewWindow` gave it the captain's own console to ask on: an install stopped dead on a mandatory parameter that `tests/FmBridge.Tests.ps1` leaves off on purpose to prove a refusal, under a bare `Supply values for the following parameters:` with no test name against it.
Measured 2026-08-21, the same call in a console child: it hangs indefinitely without the switch and raises `MissingMandatoryParameter` with it, which makes any prompt this suite can reach one named test failure in the report the captain is already reading.
`docs/windows-e2e-evidence.md` section 39 has the captain's screen and both measurements, and `tests/FmToolInstall.Tests.ps1` proves the launch from inside the process it starts.
`install.ps1`'s two questions are the deliberate exception, and both take the safe default under `-Unattended` or a redirected stdin rather than waiting.
The line between the two: an installer may ask a question IT composed and printed, and must never let a child it started for verification ask one.
`gh auth login` genuinely needs a human, and bootstrap reports `NEEDS_GH_AUTH` instead of trying to run it.

**A launch this machine refuses is an outcome, not a crash.**
Windows declines to start a program for reasons that have nothing to do with this repo, and it reports every one of them as "access is denied".
Measured on the captain's machine, 2026-08-20: the second real install died at the first tool needing a child shell, with `Program 'pwsh.exe' failed to run` and a stack trace, having installed nothing and leaving every later requirement unattempted and unreported.
The same executable had started successfully seconds earlier in the same run, as the same user, from the same directory - `docs/windows-e2e-evidence.md` section 34 has the whole reproduction, including the cross-user diagnosis that text produced and why it was wrong.

What differs between the two launches is measurable and is the reason one can be allowed and the other refused.
Collecting a child's output means .NET must redirect its streams, and .NET refuses to redirect a process started through the shell, so `& $pwsh ... 2>&1 | ForEach-Object` is always on the `CreateProcess` path - which is also the only path that produces that message.
`install.ps1`'s own re-launch collects nothing and is not the same operation.
PowerShell raises a refused launch as a terminating `ApplicationFailedException` whatever `$ErrorActionPreference` says, which is why an unguarded invocation takes the whole run with it.

So `Invoke-FmToolShellCommand` owns starting a child shell and never lets a refusal escape, `Invoke-FmToolRoute` reports it as `blocked` and the run carries on, and `Get-FmToolLaunchRefusal` owns what is said - which never quotes the exception, because "access is denied" plus a trace is exactly what sent the first diagnosis after a permission problem that did not exist.
The same guard is on `install.ps1`'s re-launch, the suite runner, the home setup and the command shim, so none of them can hand the captain a .NET error.
WHAT refuses such a launch is not established and this repo does not claim it: the report names the two things that most often do, as things to check.

**A failure is reported with its cause, or it is not reported at all.**
This area used to report a failing route as the command, its exit code, and the LAST non-blank line the tool printed.
Measured from the captain's install log, 2026-08-20, that produced `'winget install OpenJS.NodeJS' exited 1: Node.js OpenJS.NodeJS winget` - a row of winget's package table, not an error, and not a sentence.
Firstmate read that report, found no cause in it, and told the captain the install needed administrator; one failure reported without its cause produced a wrong diagnosis and cost them the time twice.

The last line of a failing run is not the error, and picking it is a coin toss rather than a summary: measured here on winget v1.29.280, a rejected command line prints 51 lines whose cause is the third and whose last is usage boilerplate.
So `Get-FmToolRunFailureDetail` quotes what the tool said rather than distilling it, keeps both ends when there is too much to keep and says how many lines it dropped, and says so explicitly when a tool printed nothing at all.
`Get-FmToolExitCodeMeaning` adds what a code means only where this repo has measured one, and returns nothing where it has not, because an invented meaning is the defect this exists to stop repeating.

The exit code had to be recovered before any of that could mean anything.
`pwsh -Command <native command>` reports its own verdict, 0 or 1, and discards the code the native command returned - measured here, a winget failure that exits `0x8A150014` on its own makes the child exit 1.
Every winget failure this installer had ever reported therefore arrived as a bare 1, which is what the captain was handed.
`Get-FmToolShellCommandText` appends an epilogue that hands back the tool's own code while keeping `$?` the authority on whether the run failed, so a stale code from some earlier call inside a vendor script cannot turn a working install into a reported failure.
It is appended on its own line because the published one-liners carry trailing `#` notes, and on one line a comment swallows everything after it.

`Format-FmInstallStepLine` and `Get-FmMachineSummaryLine` indent the continuation of a multi-line detail rather than dropping it, so the cause survives into both the transcript and the end summary.

**Two enablers are checked before they are used**, because the failure they prevent is a bare "command not found" in the middle of a run: `winget`, which the git and Node.js routes need, and `npm`, which the five axi tools need.
Both are reported in the plan with what they enable and what to do when absent, and both are probed by RUNNING them: an enabler this machine will not start is not an enabler, so its routes are skipped with a reason rather than each one discovering the same refusal.

`Get-FmToolWingetPath` also looks for `%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe` directly.
Measured on the captain's machine: `Get-Command winget` fails while that file runs and prints `v1.29.280`, because the user PATH carries the SYSTEM profile's app-alias directory rather than this user's.
Without that fallback, every winget route is refused on a machine that has winget.

**The shell itself is the first requirement.**
`install.ps1` carries NO `#requires -Version 7.0`, and that is deliberate: a clean Windows machine opens Windows PowerShell 5.1, where the directive produces "cannot be run because it contained a '#requires' statement" and nothing about what to do next.
It checks `$PSVersionTable` itself, offers Microsoft's own per-user PowerShell 7 install, and re-runs itself under `pwsh`.
Nothing above that relaunch may use PowerShell 7 syntax, and `tests/FmModuleAssembly.Tests.ps1` parses the file with the real 5.1 to keep it that way.

**And running it at all is the requirement before that.**
Windows ships with script execution switched off, so a bare `.\install.ps1` on a clean machine answers `install.ps1 cannot be loaded because running scripts is disabled on this system` - measured on the captain's clean Windows 11 machine, 2026-08-20, before any of the above could happen.
`README.md`, `docs/windows-quickstart.md` and this script's own help all give `powershell -ExecutionPolicy Bypass -File .\install.ps1` instead, which applies to the one process it starts, needs no administrator, and changes no machine setting.
`Set-ExecutionPolicy` is deliberately NOT what is documented: the first command in our own instructions must not ask a newcomer to change a security setting of their machine.
`tests/FmModuleAssembly.Tests.ps1` takes the command out of `README.md` and RUNS it in a real Windows PowerShell 5.1 given the clean-machine policy, with the bare form as its negative control, so a README that regresses fails the suite rather than the next clean machine.

**"Installed" has to mean the captain can find it.**
The PowerShell 7 route is the one that needs no administrator, and that is why it is `install-powershell.ps1 -Destination "$env:LOCALAPPDATA\Programs\PowerShell7" -AddToPath`: an archive expansion.
It writes `pwsh.exe`, it edits the user PATH, and it **registers nothing** - no Start menu entry, no Windows Terminal profile, no context-menu entries, because only the machine-wide MSI adds those.
Measured on the same clean machine: the run reported success, re-launched itself under `C:\Users\<them>\AppData\Local\Programs\PowerShell7\pwsh.exe`, and left the captain with no way to open PowerShell 7 as an application.

The route was kept, because no-administrator is the harder constraint and the right one.
What was added is `Set-FmMachineShellShortcut`, which writes a `.lnk` into the captain's OWN `Start Menu\Programs` folder - the folder Start and its search box read, and the one that needs no elevation.
It runs on every install rather than only on the run that installed the shell, so a machine already in that state is repaired by re-running.
It never adds a second entry: both the user and the machine-wide Start Menu folders are searched, recursively, and matched on what each `.lnk` actually POINTS AT rather than on its name - the MSI's entry is `PowerShell\PowerShell 7 (x64).lnk`, nested and named nothing this could have guessed.
`Get-FmMachineShellLine` then says out loud where the executable is and how to open it, and names `winget install Microsoft.PowerShell` as the optional elevated route for the Windows Terminal profile and the right-click entries - which is the honest answer, since nothing without administrator can add them.

**None of that has actually executed on the captain's machine**, and nothing here may imply it has.
The shortcut is step 4 of the install, and both of their runs died in step 1 - the first on the record-shape defect section 33 fixed, the second on the refused launch above.
The mechanism is proven against disposable directories, and against this machine's real Start menu read-only, which is a different claim from "the captain's Start menu was repaired".

**A route may RUN what it downloads, and the speech engine is why.**
Handy publishes no archive - only an NSIS `-setup.exe` and two machine-scope MSIs - so there is nothing to expand.
Rather than a second way to fetch, the route record gained `Placement`: `archive` expands into `%LOCALAPPDATA%\Programs\<tool>`, `installer` runs the downloaded file and lets the vendor choose where it lands.
Everything before that last step - resolving the asset, downloading it, checking the publisher's checksum, cleaning up - is the same code either way.
The arguments are the route's own, and what is ABSENT matters: `/S` makes it silent, and `/R` is deliberately not passed, because their NSIS template starts the app after a silent install only when it is.
Installing the engine therefore does not start the engine.

**Installing a speech engine is not turning voice on, and the report keeps them apart.**
`config/voice` is the only thing that opens a microphone (`AGENTS.md` section 9), and nothing in the install writes it: a machine that has just gained Handy still reports `[off] voice`.
The summary prints the engine and its model as two lines because they genuinely differ - the 1.4 GB model can be declined or fail and leave a perfectly good engine with nothing to transcribe with, and one "speech: ok" line would hide exactly that.
The engine is OPTIONAL in the catalog, because "required" means firstmate cannot dispatch a worker without it and it dispatches perfectly well with voice off.
`FmSpeechInstall.ps1` owns the model, the selection and both lines; section 45 of the evidence has the reasoning about the download's size and what silence means.

**It ends by proving itself.**
`Install-FmMachine` finishes with a verification pass rather than a success message: every catalogued tool is run and made to print a version, `Invoke-FmDoctor` re-reads the home and the instruction surface (including the skills count and the contract's byte length), and the repository's own Pester suite is executed in a bounded child process.
`Ready` is false when any of that fails, when anything was skipped as unsupported, or when any install did not complete - and the last line says so in plain words instead of ending on a cheerful note.
`-SkipSuite` is allowed and reports the install as unproven.

**Whether the WHOLE suite should be the thing that ends an install is an open question, and it is argued in `docs/windows-e2e-evidence.md` section 42.7 rather than restated here.**
The short of it: the suite defends this repo's contracts against a change a fresh install has not made, so on the one clean VM that reached this step it returned ten failures and not one of them was a fact about that machine.
Nothing has been changed - which failures may end an install is the captain's call - but read 39.7 before touching this step.

The verification's tool group and the doctor's prerequisite group overlap on herdr, treehouse and the Claude CLI on purpose: they ask different questions at different thresholds.
The doctor asks whether this HOME is healthy, where an absent herdr is a warning.
The verification asks whether the INSTALL delivered what it promised, where a required tool that cannot print a version is a failure.


## The last ten seconds

`install.ps1`'s closing block, `module/Firstmate/Public/FmMachineStart.ps1`, and `start.ps1`'s version guard.

**The install succeeded and the captain's very next command failed, twice.**
The run ended `READY`, printed "This window took its PATH when it opened, so type this in a NEW one" and named `firstmate`, and the captain typed it in the window they were standing in.
The run before that ended the same way with `claude` and `.\start.ps1`.
Two clean-machine installs in a row therefore ended on a `CommandNotFoundException`, at the last step of an otherwise clean install and as the first impression firstmate makes.
The instruction was accurate, it was on screen, and it was walked past anyway - so the finish line was badly placed, and blaming the reader was the wrong conclusion.

**What is actually true was measured, not inherited from the report.**
The report said the PATH was stale; that is right about the captain's window and wrong about the installing session, and the difference is the whole design.

- The installing PROCESS resolves `firstmate` perfectly well.
  `Add-FmToolUserPath` updates `$env:PATH` for the process it runs in, so the shim is on the PATH of the `pwsh` that ran the install, and a bare `firstmate` there returns the shim.
- The captain's WINDOW is not that process.
  The documented command is `powershell -ExecutionPolicy Bypass -File .\install.ps1`, which is a child, and `install.ps1` then relaunches itself under `pwsh`, so the work happens two processes below the prompt.
  Reproduced 2026-08-26 on Windows PowerShell 5.1.26100.8115: with the shim directory removed from the parent's PATH, the child writes the shim and resolves it, the parent does not, and the parent's error is `The term 'firstmate' is not recognized as the name of a cmdlet, function, script file, or operable program` - the captain's line, verbatim.
- A change made in a process cannot reach an ancestor, so that window can be given neither a PATH entry nor a function.
  Measured alongside it: a script run IN a PowerShell 7 session does leave both behind - a `$env:PATH` edit and a `function global:` survive into that session's prompt - which is exactly why the distinction matters and why the failure looks arbitrary.
  It is unreachable only because the installer never runs in the captain's session.

**So two of the four candidate fixes are impossible here, and saying which is part of the answer.**

| direction | verdict |
| --- | --- |
| make it work in that window | Impossible as a PATH repair, for the reason above. Taken in the sense that survives: name a command that works there. |
| offer to start it | Taken. It is the same shape as the administrator prompt this run already puts, and it removes the failing command from the path entirely. |
| make the failure teach | Rejected as unreachable. It needs a function in the captain's own session, and the installer is never in it, so a `CommandNotFoundException` in that window cannot be intercepted from outside it. |
| make the instruction unmissable | Rejected. It is what was already there. The text was correct and was still walked past, so louder text is a fix that has already been tried and has already failed twice. |

**What the ending does now.**
It stops sending the captain somewhere else.
`Get-FmMachineStartLine` names two commands and says which window each is for: the shim's full path, which works in the window being read, and `firstmate`, which works in any new one.
Then `install.ps1` offers to start it here, once.
The reason travels with them - "this window took its copy of PATH when it opened" - because a bare instruction is what was skim-read the first two times.

**The full path to the shim is the command that always works, and that is not incidental.**
Measured 2026-08-26 in a Windows PowerShell 5.1 window with the install's PATH entry removed and the execution policy at `Restricted`, which is what a clean Windows client has: `firstmate` is not recognized, `.\start.ps1` answers `cannot be loaded because running scripts is disabled on this system`, and `<...>\Programs\firstmate\firstmate.cmd` starts `start.ps1` under PowerShell 7.6.4.
It is immune to both because a `.cmd` is not subject to an execution policy and the `pwsh` it starts is given `-ExecutionPolicy Bypass`.
That is why the ending names it rather than `.\start.ps1`, which would have failed for a second reason on the machine shape this file already documents.

**Nothing starts without an explicit yes in that run.**
`Get-FmMachineStartDecision` is the gate, and it is a function rather than a condition inside `install.ps1` so that the rule can be tested.
Only `y` or `yes` starts anything; an empty answer is a no, so pressing Enter cannot open a browser; and `-Unattended` or a redirected stdin is never asked at all, on the reasoning `Test-CaptainPresent` already states for the administrator prompt.
That is deliberately the opposite default from `Confirm-SpeechModel`, and the difference is what the two questions cost: one finishes a download, this one starts a process and opens a browser.
`AGENTS.md` is emphatic about this - things that start themselves are how the captain ended up with audio playing from a window they could not find - so here the silent answer is the safe one.

**`start.ps1` from Windows PowerShell 5 is the same failure at the other door, and this closes `start-wrong-shell`.**
That file carried `#requires -Version 7.0`, so the captain who typed `.\start.ps1` in the 5.1 window they had just installed from got
`The script 'start.ps1' cannot be run because it contained a "#requires" statement for Windows PowerShell 7.0` - accurate, not firstmate speaking, and silent about what to do, on a machine that already had PowerShell 7 on it.
Only the window was wrong, and unlike the `firstmate` case that IS something the script can fix, because it is the script's own process.
So `start.ps1` now carries no `#requires`, checks `$PSVersionTable` itself, says what is wrong in firstmate's own words, and relaunches under `pwsh` carrying the captain's arguments across.
Typing `.\start.ps1` is the consent to start, so relaunching starts nothing that was not asked for.
Where there is no PowerShell 7 to switch to it installs nothing and names `install.ps1`, which is the same one-installer rule its missing-tool refusal is built on.

**The two version guards are deliberately separate, and this is the reason.**
`install.ps1`'s has to survive on a machine with no PowerShell 7 at all, so it offers to install the shell; `start.ps1`'s runs after that install and must never install anything.
They share only how `pwsh` is found - four lines and one well-known location - and `install.ps1`'s block stays self-contained because it is the one file that must be able to say "you are on the wrong shell" before anything else on the machine is known to be there.

**What this does NOT close.**
A captain whose execution policy is the clean-machine `Restricted` never reaches `start.ps1`'s guard at all: the policy refuses the file first, and `README.md` gives the `-ExecutionPolicy Bypass` form for exactly that reason.
The guard closes the raw version mismatch, which is what `start-wrong-shell` describes and what the captain actually hit; it does not and cannot close the policy refusal, which is a different failure with its own owner above.

**How it is proved.**
`tests/FmModuleAssembly.Tests.ps1` RUNS `start.ps1` in a real Windows PowerShell 5.1 rather than reading it: once with a stub `pwsh` at the front of PATH, which measures the relaunch and the arguments it carries without a bridge or a browser starting, and once with no `pwsh` anywhere, which measures the refusal and its exit code.
Both fail against the pre-fix file, which is what makes them worth having.
`tests/FmToolInstall.Tests.ps1` covers the closing lines, the fallback when no shim could be written, and every path through the consent gate - including that nobody at the keyboard is never a yes whatever the answer string says.
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
