# Contributing to firstmate-win

This file is the **contributor and build memory** for this port: how to write,
test, and land code here. It is not the operating contract - a running firstmate
session's job description is [`AGENTS.md`](AGENTS.md), and `AGENTS.md` section 2
lists this port's own file layout and state contracts.

Read `AGENTS.md` first if you are operating the fleet. Read this file if you are
changing the port.

firstmate-win is a native Windows / PowerShell 7 port of firstmate. The bash
original is the specification; read the corresponding `bin/*.sh` before writing
or changing an equivalent here. Reference checkout:
`/home/adit-admin/dhaval_first_test/firstmate` (read-only; its `AGENTS.md`
section 2 lists the state-file formats).

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
- **An absent by-name owner is a DECISION, and it is written down.** Areas bind
  to each other by name at call time, so a call whose target nothing defines
  does not conflict in git, does not fail to compile, and either dies at run
  time or silently takes a degraded path for ever. Twenty-two of them were live
  at once on this port, one of which left every session read-only.
  `tests/FmModuleAssembly.Tests.ps1` now derives every literal by-name target
  from the source - `Resolve-Fm*Command`, `Invoke-FmSeam`/`Test-FmSeam`,
  `-CommandName`, and direct `Get-Command` probes - and fails on any that is
  neither defined nor listed in its registry of deliberate absences. Each
  registry entry says which kind it is (`PREFERRED`, meaning the caller has a
  complete local fallback, or `ABSENT`, meaning the capability is not in this
  port) and why. It also fails on a stale entry in either direction: an owner
  that has since landed, and a name nothing binds any more. Add an entry only
  after establishing which kind it is - never to make the test green.
- `tests/FmModuleAssembly.Tests.ps1` mechanises the cross-area rules below: no
  duplicate function name, the manifest imports, every `Public/` function is
  exported, and every `Fm` function a `bin/` entry point calls is exported.
  It enumerates the tree, so a new area or entry point is covered as soon as it
  exists - nothing to add to a list.
- Mark anything provable only on Windows with a `# WINDOWS-UNVERIFIED:` comment
  and a one-line reason. Where behaviour must differ by platform, branch on
  `$IsWindows`; the Linux path is a development convenience, not the product.
- **Never start a screen that serves a page, and never point a browser at one.**
  This is the captain's rule, not a preference. Test bridges left running by
  workers spoke aloud on their machine twice, and "no browser was open" was
  literally true: the pages were being driven HEADLESS, so there was a live page
  talking with no window anywhere to close. `-NoEngine` does not help - it stops
  the session, not the page, and the page is what speaks. Verify over HTTP
  instead; layout and how a reply looks once it lands are the only things HTTP
  cannot answer, and those go to the captain. The page itself is now silent
  unless `config/bridge-voice` says otherwise, and the bridge sets
  `FM_VOICE_OFF` for its whole process tree so a home with `config/voice` on
  cannot speak out of a process the page never reaches - but neither of those is
  a licence to start driving screens again. The same rule is why
  `tests/FmVoice.Tests.ps1` never switches a voice ON to prove a guard: a suite
  that does makes a noise on the captain's machine every time the guard
  regresses.

## Layout

```
module/Firstmate/Firstmate.psd1   manifest
module/Firstmate/Firstmate.psm1   loader
module/Firstmate/Private/*.ps1    internals, one file per area
module/Firstmate/Public/*.ps1     exported verbs, one file per area
bin/fm-*.ps1                      thin entry points, one per command
install.ps1 start.ps1             the CAPTAIN's two commands, at the root because
                                  they are not for firstmate's own use
tests/*.Tests.ps1                 Pester 5+, one per area
docs/                             per-area design notes
AGENTS.md                         the OPERATING contract; CLAUDE.md links to it
.agents/skills/                   the loaded skills; .claude/skills links to it
```

`AGENTS.md` and `.agents/skills/` are the running agent's instruction surface,
not build memory. Anything a session needs only in a nameable situation belongs
in a skill with a one-line trigger in `AGENTS.md` section 13; anything a
contributor needs belongs in this file or a `docs/` note. `docs/instruction-surface.md`
owns why the surface is shaped that way and what verifies it.

**After editing `AGENTS.md` on Windows, re-run `bin/fm-setup.ps1`.**
On this platform `CLAUDE.md` is a HARDLINK to `AGENTS.md`, and most editors write a new file and rename it over the old one, which breaks the link silently.
`AGENTS.md` then carries the edit while `CLAUDE.md` still carries the bytes from before it, so the session reads instructions nothing else agrees with.
`fm-doctor.ps1` catches it as `[missing] contract for Claude`.
Setup will not overwrite either file once they differ - two real, different memory files are the captain's to reconcile - so the repair is to delete `CLAUDE.md` and run setup again, which re-links it.

**Stage your files by name, never with `git add -A` or `git add .`.**
`.claude/skills` is committed as a symlink and materialized on Windows as a junction, and `git add -A` walks THROUGH that junction: it replaces the one symlink entry in the index with the 19 real `SKILL.md` files behind it.
`Protect-FmInstructionLink`'s skip-worktree mark does not stop this - it governs checkout and status, not `add` - so the damage is silent and lands in the commit.
Measured while landing the installer, and recovered with `git reset --mixed`, which restores the index and leaves the working tree alone; re-run `bin/fm-setup.ps1` afterwards, because the reset clears the skip-worktree bit.

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
- `docs/claude-hooks-windows.md` - the Claude hook surface. Now carries the
  MEASURED invocation shape Claude Code uses on Windows, the two transport
  defects that shape caused (a pipeline-bound payload, and `pwsh -Command`
  silently downgrading a deny's exit 2 to 1), and the line between what is
  `# WINDOWS-UNVERIFIED:` documentation and what the tests actually prove.
- `docs/cd-guard-windows.md` - the cd guard: the native-PowerShell shell
  classifier that replaced the `.mjs` engines, the 119-command differential
  comparison against the Linux reference, and the two silent PowerShell hazards
  (case-insensitive hash keys and case-insensitive variable names) it had to
  survive.
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
- `docs/finished-run-stall.md` - why a crewmate waiting on a background run and
  one waiting on a finished run used to read identically, what the ad-hoc process
  count got wrong nine times in one evening, and the tri-state reading that
  replaced it. Read the asymmetry section before touching that area: answering
  `none` while a run is going is the failure it exists to refuse.
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
- `docs/autolaunch-windows.md` - the opt-in `config/autolaunch` startup command
  and its interruptible grace window: why it is off until a file says otherwise,
  why "untouched" is proved by unchanged capture bytes rather than by a composer
  shape verdict this port does not own, and why the baseline those bytes come
  from has to be proved to be firstmate's own rather than trusted.
- `docs/telegram-windows.md` - the private Telegram channel: why it ships inert,
  why the tier-3 refusal is a constant in the code rather than a setting, where
  the bot token leaks if anything logs a request, how a message about one piece of
  work is resolved to it and the answer matched back without opening a route
  between a phone and a worker, and what has never been run against a real
  endpoint.
- `docs/windows-install.md` - `fm-setup.ps1` and `fm-doctor.ps1`: why the wiring
  is a managed PowerShell-profile block rather than a User environment variable,
  why setup writes `config/backend=herdr` (without it a fresh home resolves
  to `tmux` and the captain's first digest asks Windows to install it), and why
  `-KeepHomePointer` exists - a checkout has exactly one `.fm-home`, so
  provisioning a second home from it must not claim that pointer.
  Its "The machine install" section covers `install.ps1` and `Install-FmMachine`:
  why the route table has exactly one owner (a second one installed two tools from npm packages that were not the software),
  why no route may need administrator, the three-outcome classification and why `older` and `unsupported` must never be blurred,
  and why `install.ps1` carries no `#requires` line.
- `docs/instruction-surface.md` - the operating contract and the skills: what
  `AGENTS.md` is for, how each Linux skill was ported or recorded as absent, how
  the two committed links survive a Windows clone, and what the doctor checks.
- `docs/voice-windows.md` - the voice channel (`fm-say` and `fm-ask`): why it is
  off until `config/voice` exists, why the engine calls are asynchronous with a
  deadline rather than blocking or detached, why a spoken answer is never the
  captain's explicit word for a merge or a delete, and why the four functions
  that touch System.Speech are the only ones the suite has to mock - plus the
  blind spot that mocking creates, which has already cost one defect a green
  suite could not see. It also owns how written text is prepared for an engine
  (`ConvertTo-FmSpokenText`, one owner for both speaking paths) and why
  `FM_VOICE_OFF` outranks `config/voice` for a process whose parent owns the
  speaking.
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
- **A function that `return , $list`s must be ASSIGNED, never wrapped or piped.**
  Thirty functions here return a list behind a unary comma so an empty one cannot
  unroll to `$null` and read as "unparseable" (`docs/herdr-backend-windows.md`
  explains the original case). The caller-side half is the trap: `@(Get-FmThing)`
  collects the ONE array-shaped output object into a one-element array, so an empty
  result becomes a single nameless element and the next property read throws under
  strict mode - and piping it straight into `Where-Object` does the same. Assign
  first, then wrap or filter. Both halves of this bit during development.
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
- **A test that builds its own input proves nothing about the caller's input.**
  The parameter-name rule above has a twin one level down: a function that takes
  an untyped RECORD has an undeclared shape contract, and nothing checks it.
  `Invoke-FmToolRoute` read `$Entry.Tool`; its one caller passes a requirement
  from `Get-FmMachineInstallPlan`, which publishes `Name`. Under strict mode the
  first real install threw and the whole run died - on the first clean machine
  this installer ever met, at the one step a machine that already had the tools
  could never reach. Every test in the area passed, because every one of them
  constructed the record it handed over. Where a producer and a consumer live in
  different functions, at least one test must put the PRODUCER'S OWN output
  through the consumer, untouched; `-WhatIf` usually gets that far without
  performing the side effect. Better still, do not accept a record whose shape
  nobody declares - pass the one the other side already owns, as that function
  now does with its route.
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
  escaped from your code". Same hazard as a `-Home` parameter. It bites module
  code too, where it surfaces plainly as "Cannot overwrite variable HOME".
- **Never put `<angle brackets>` in a Pester test name.** Pester reads `<name>`
  in an `It` title as a `-ForEach` data placeholder and resolves it as a
  variable, so a descriptive `'composes state/<id>.<suffix>'` fails under strict
  mode with "The variable '$id' cannot be retrieved because it has not been
  set", pointing at `<ScriptBlock>, <No file>:1` rather than at the title.
- **The suite dirties this checkout, so restore it before you commit.**
  `tests/FmInstall.Tests.ps1`'s "the entry points" block runs `fm-setup.ps1
  -RepoRoot <this checkout>`, and setup repairs the checkout's `CLAUDE.md`
  mirror and `.claude/skills` link as part of its job. The fixture already sends
  the home pointer somewhere disposable for exactly this reason; the two repairs
  were missed. Check `git status` after a full run.
- **Never point ANY git write at a repaired `.claude/skills`.** Once setup has
  turned that placeholder into a real link to `.agents/skills`, a git operation
  that writes that path deletes the link's TARGET - the whole skills tree goes
  with it. `git checkout --` does it and so does `git stash push -- .claude/skills`,
  which is how `.agents/skills/updatefirstmate/SKILL.md` was lost while clearing
  the tree for a rebase. Restore `.agents/skills` from git afterwards.
  When a clean tree is genuinely needed, do not go through git at all: both paths
  are tracked mode 120000 and `core.symlinks` is false here, so what git wants on
  disk is a plain file holding the target text. Write those bytes with no trailing
  newline - `../.agents/skills` and `AGENTS.md`, 17 and 9 bytes - and the tree is
  clean with the skills tree untouched. Remove the junction first with
  `[System.IO.Directory]::Delete($path, $false)`, which unlinks it rather than
  walking through; `Remove-Item -Recurse` would take the target with it. `ln -s` is not the answer either: with symlinks off, MSYS
  copies instead, which turned `.claude/skills` into a 19-directory duplicate and
  `CLAUDE.md` into a 56KB copy of the contract.

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
- **`.claude/skills` is the second committed link, and it breaks the same way.**
  It points at `.agents/skills`, and a `core.symlinks=false` clone writes a
  17-byte file containing the text `../.agents/skills` - the link is relative to
  `.claude/`, so the `../` is part of it - which means a session in that checkout
  loads zero skills while every command still works.
  `Test-FmSkillsLinkPlaceholder` recognises it and setup repairs it, asking for
  a symlink, then a directory junction (no privilege needed on NTFS), then a
  synced copy. Never "fix" this by deleting the committed link: a Linux clone of
  the same repo needs it.
- The doctor's `start Claude in` check answers the question outright, and calls a
  silent split - or a placeholder `CLAUDE.md` - `[missing]`, not `[warn]`. The
  `instructions` group does the same for the operating contract and the skills:
  a checkout that has every command and no identity is reported, not discovered
  by the captain noticing the tone.

## Seeing the browser screen

`ui/bridge.html` is proven by running it, and the evidence goes in
`docs/windows-e2e-evidence.md`. A test that read its stylesheet would assert
implementation source, which the rules above forbid, so most of this page has no
Pester coverage and is not going to get any.

**Its BEHAVIOUR is a different question, and push to talk now has coverage.**
`tests/ui/bridge-page-harness.js` loads the page's own `<script>` into a stubbed
window under `node:vm` and drives it through its own event listeners, with a
virtual clock so a thirty-second hold costs milliseconds.
That is executing the program, not reading its text, so it is behaviour in the
sense the rules mean - and it needs no server, no browser and no microphone,
which is what makes it allowed here at all.
`tests/FmBridgeScreen.Tests.ps1` runs it and turns each check into a Pester
result, so `Invoke-Pester -Path ./tests` stays the one gate; node's absence is
reported as a skip with the reason, never as a pass.
Add to that harness when a change to the page has a state machine in it - which
edge a request is on, whose data a poll may take, whether a hold survives
something - and leave anything visual to a browser run and the evidence file.
Its server model mirrors `bin/fm-bridge.ps1`, so a change to either one belongs
in both. `docs/windows-e2e-evidence.md` section 32 is what that harness was
built for and states what it still cannot prove.

- **Do not serve the page to check something, and do not open a browser at it.**
  This is the captain's standing rule after their machine spoke at them, twice,
  with several copies at once and no window they could find to silence - see
  `docs/windows-e2e-evidence.md` section 33.11. The page now asks
  `Test-FmBridgeVoiceAllowed` before it speaks, and that repair does not reopen
  the door: `-NoEngine` stops the session, not the page.
- **Verify over HTTP instead.** `Invoke-RestMethod` against `/api/fleet` with the
  `X-Fm-Token` header reads the very object the panel paints, so what the panel
  will show is assertable with nothing rendering. Layout, and how a reply looks
  once it lands, are the things HTTP cannot answer - ask the captain and let them
  arrange it rather than starting a screen.
- Clean up what you start, and check by worktree rather than by name. A
  force-killed bridge skips its own exit path and leaves the dictation key behind
  at `Get-FmBridgeTokenPath`; browsers driven headless outlive the session that
  opened them; and several lanes share this machine, so match on the worktree
  path before stopping anything. A `pwsh` whose command line merely CONTAINS
  `fm-bridge` is usually an agent's own tool call, which is the same false
  positive `Get-FmBridgeHouseWork` documents - and killing it kills yourself.
- **The session is not confined to the scratch workspace either.** A `.meta`
  copied in to make the fleet look real names the captain's own checkout, so a
  session started without `-NoEngine` can read it and reach the scripts there.
  That is a standing hazard on a home whose voice is switched on, which is what
  `FM_VOICE_OFF` guards - it is NOT what made the noise in the incidents above.
  That was diagnosed as the session by the lane it happened to, and measured as
  the page by the next one; `docs/windows-e2e-evidence.md` 35.5 records the
  correction. Gate the page, and still do not start the engine.
- **The reply path needs no session to verify.** `Test-FmBridgeGrounded` and
  `Protect-FmBridgeReply` take a reply and a reading and answer whether the one
  can be substantiated by the other, so a fabrication is provable at a prompt.
- **Measure, do not look.** Claims about what overlaps what come from
  `getBoundingClientRect` and `document.documentElement.scrollWidth`, at several
  window sizes. A screenshot shows the defect; the numbers are what pin it.
- **Changing only the URL fragment does not reload the page.** A new run mints a
  new token, so re-opening `.../#t=<new>` in the same tab leaves the OLD page
  running and quietly measures the code you just replaced. Reload explicitly.
- The layout hazard this file keeps hitting is the same one twice: a child that
  will not shrink. `min-width:0` plus `max-width` for a flex row, `minmax(0,1fr)`
  for a grid track, and a canvas sized in pixels must be re-measured from its
  container - an arriving reply is not a resize event.
- **The dictation engine's flag both starts and stops, so somebody has to own
  which edge a request is on, and that somebody is the bridge.**
  `Step-FmSpeechCaptureState` holds that rule and the one beside it: a transcript
  produced by a capture the page asked for leaves by `/api/heard` and never by
  `/api/fleet`. Both were unowned, and the pair of them is what made push to talk
  stop after a second and then work backwards for the life of the page - section
  32. Never send `Invoke-FmSpeechCapture` an edge decided by a caller's guess.
- **Everything the screen shows leaves through `ConvertTo-FmBridgePlainText`** -
  a panel line in its default form, a whole reply with `-Prose`. It is one
  translator on purpose, so a term that leaked is fixed by adding a word to
  `Get-FmBridgeVocabulary`, never by a second pass somewhere else. Names the
  screen is displaying go in as `-Keep`, or the vocabulary translates a word
  inside a job's own name and the two halves stop agreeing about what it is
  called.
- **The panel and the reply answer the same question, so they answer from one
  read.** `/api/say` calls `Get-FmBridgeFleet` once and hands that object to the
  session through `New-FmBridgeTurnPrompt`; the panel paints the same object. A
  second read path for the session would drift, and the screen contradicting
  itself is the worst thing it can do.
- **A limitation is never the reply.** The captain's ruling, after one shipped:
  a screen worth talking to gives the way to get the thing done, never a
  confession about its own arrangement, and a softer phrasing of the same
  confession is the same mistake. `Get-FmBridgeRoute` owns the route that goes in
  its place. Nothing is ever appended under the session's answer either - a fixed
  line cannot know what the answer above it already says, and the one that used
  to be there made the screen state the same point twice in one reply.
- **Do not send the session what the captain must not read.** Anything in the
  turn prompt can come back out in the answer: a decision's record handle went in
  so the session could close it and came back as "the carrier question". Job
  names belong there because the panel prints them; handles and ids do not.

- **A number on that screen comes from something real, or it does not appear.**
  Blank, or the words "not measured", is the correct outcome when no source
  exists; a plausible figure that was never measured is the defect this screen
  has already shipped twice. The progress rows set the standard - a job that
  declared no percentage shows "not said" against a hatched bar, never a zero.
  Wiring a placeholder to something approximate so it moves convincingly is the
  same defect wearing a better disguise.
- **The reading grounds the answer; the gate is what makes it true.** Handing the
  session the panel's own reading stops it answering from a narrower view, but it
  cannot stop it answering from a WIDER one: the screen named "the payment
  tests", a phrase this repository carries only as placeholder text, gave it a
  percentage and recommended halting real work for it. So every reply is checked
  against that same reading before it ships. `FmBridgeGround.ps1` states the
  contract in full; the short version is that a name may come only from the
  records or from the captain's own words, and a name the records do not carry
  may be mentioned but never given a state, a percentage, or a recommended
  action. If you find yourself adding a rule to the prompt to stop the screen
  saying something, the check belongs in the courier instead - a prompt is a
  request, exactly as the translator note above says.
The whole suite takes about three quarters of an hour here, and it must run from
a parent that OUTLIVES it. An orphaned run fails
`Get-FmParentProcessId.finds a parent for this process` and nothing else, because
.NET's `Process.Parent` resolves only a live parent - that failure is the
launcher, not the tree, and it costs an hour to rediscover. A run backgrounded by
an agent harness tends to be killed long before the end instead. What works is a
keeper: one process that runs no tests itself, starts the suite as its child, and
waits for it. `docs/windows-e2e-evidence.md` section 33.10 has the probe and both
failure shapes.

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
