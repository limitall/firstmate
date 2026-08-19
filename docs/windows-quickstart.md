# firstmate on Windows - quickstart

Native PowerShell 7. No WSL, no Git Bash, no Linux anything.

## 1. One clone, one command

```powershell
git clone <your firstmate-win remote> C:\Users\<you>\firstmate-win
cd C:\Users\<you>\firstmate-win
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That is everything.
`install.ps1` assumes nothing is already on the machine - including the shell it is running in - and does step 2 below as part of its run.
It is safe to re-run at any time.

**Why `-ExecutionPolicy Bypass` is part of the first command.**
Windows ships with script execution switched off, so a bare `.\install.ps1` on a clean machine answers `install.ps1 cannot be loaded because running scripts is disabled on this system` and nothing else happens.
The form above applies to the one process it starts, needs no administrator, and changes no machine setting - which is why it is the default written here rather than an instruction to run `Set-ExecutionPolicy`.

Run it from Windows PowerShell 5.1 if that is what opened: it detects the wrong shell, offers to install PowerShell 7 into your own profile with no administrator, and re-runs itself under it.
That per-user install expands an archive rather than running the machine-wide installer, so it registers nothing by itself; the run adds PowerShell 7 to your Start menu and tells you where the executable went, so "installed" means you can open it.

**What it installs, and from where.**
Each of these is the vendor's own published installer or release archive, and each one writes into your own profile rather than into Program Files, so none of it needs administrator:

| tool | source |
| --- | --- |
| Claude CLI | `irm https://claude.ai/install.ps1 \| iex` |
| herdr | `irm https://herdr.dev/install.ps1 \| iex` |
| treehouse | `irm https://kunchenguid.github.io/treehouse/install.ps1 \| iex` |
| gh | the `gh_*_windows_*.zip` from `cli/cli` releases, expanded under `%LOCALAPPDATA%\Programs\gh` |
| the five axi tools | `npm install -g <name>` - these genuinely are npm packages |
| Pester, PSScriptAnalyzer | `Install-Module -Scope CurrentUser` |
| git, Node.js | `winget install` - the only two that need an elevated shell, so they are named and skipped when you do not have one |

**Do not install `treehouse` or `herdr` from npm.**
The npm package called `treehouse` is an unrelated single-page-application state framework, and the one called `herdr` is an empty `0.0.0` placeholder.
Both install cleanly and leave a machine that fails at dispatch with nothing saying why.

**Three outcomes per requirement.**
Anything missing is installed.
Anything present but older than the latest published version is offered as an optional update, one question at a time, and declining is always safe.
Anything present but below a minimum this repo actually states is reported and **skipped** rather than installed over, and the run ends by saying the machine is not ready.

Add `-Unattended` to that command to take the safe default for every question, `-SkipOptional` for the required tools only, and `-DetectOnly` to see the state of the machine without changing it.

**It ends by proving itself**, not by announcing success: every tool is run and made to print a version, the doctor re-reads the home and the instruction surface, and this repo's own test suite is executed.
The last thing printed is a summary of every requirement and what happened to it.

## 2. What setup does, if you run it alone

```powershell
C:\Users\<you>\firstmate-win\bin\fm-setup.ps1
```

`install.ps1` runs this for you; run it directly when you only want the home and the wiring repaired and no tool touched.

That creates the home (`config/ data/ projects/ state/`) **inside the checkout**,
selects the herdr backend, records the home in `.fm-home`, repairs the checkout's
`CLAUDE.md` and `.claude/skills`, puts `Import-Module Firstmate` and the `fm-*`
commands on PATH for every new session, registers the Claude hooks, and prints a
doctor report.

Those two repairs are not cosmetic, and they are why you run setup before your
first session. The repo tracks `CLAUDE.md` and `.claude/skills` as symlinks so it
works on Linux; Windows git writes each one as a short text file naming its target
instead. Left alone, the result is a checkout where every command works and the
session has no operating instructions and no skills, silently. `fm-doctor.ps1`
reports both as `[missing]` until setup has run.

It is idempotent - re-run it any time, after moving the checkout, or to repair
the wiring. If a hard prerequisite is missing it installs **nothing** and tells
you what to fix.

### Where to start Claude

**In the checkout.** That one directory:

```powershell
cd C:\Users\<you>\firstmate-win
claude
```

This is the same layout the Linux firstmate has: the repo root *is* the home, so
`AGENTS.md`, `.agents/skills/`, `.claude/` and `config/ data/ projects/ state/`
all sit together and one `cd` gets you everything. The four operational
directories are gitignored, so `git pull` still works normally.

A session started there reads `AGENTS.md` - the first mate's operating contract -
and has the 19 skills under `.agents/skills/` available. If it does not behave
like firstmate, that is a broken install rather than a mood: run
`fm-doctor.ps1` and look at the `instructions` group.

You can put the home somewhere else if you want to - a second drive, a home
shared with a Linux firstmate:

```powershell
.\bin\fm-setup.ps1 -FirstmateHome D:\firstmate
```

Then the two are **separate**, and you must still start Claude in the checkout,
not in the home. Setup writes an `AGENTS.md`/`CLAUDE.md` into that home saying
exactly that, so a session started in the wrong place stops and tells you rather
than coming up with no instructions. `fm-doctor.ps1` prints the answer too:

```
[ok]      start Claude in - C:\Users\<you>\firstmate-win - the home IS the checkout, as on Linux
```

**Open a new `pwsh` window** before step 3 - or do not. Every command below
also works by its full path in a window that has never seen the profile:

```powershell
pwsh -NoProfile -File C:\Users\<you>\firstmate-win\bin\fm-doctor.ps1
```

The new window is only so you can type `fm-doctor.ps1` instead of the full path.
That matters, because the shells firstmate itself runs in - a herdr pane, a
Claude hook, a dispatched worker - never load your profile.

## 3. Check the environment

```powershell
fm-doctor.ps1
```

Every check is printed. `[ok]` verified, `[warn]` it works but not as
conveniently (or it cannot dispatch yet), `[missing]` broken. Each non-ok line
carries the command that fixes it. Exit code 0 means nothing is missing.

A `[warn] profile wiring` line means only that the bare `fm-doctor.ps1` command
name will not work in a new window; running the script by its full path still
does everything.

## 4. Start a session

```powershell
fm-session-start.ps1
```

Prints the startup digest: lock, bootstrap diagnostics, wake queue, the
read-once contract, fleet state, and next step. Read it once - it deliberately
prints everything so you do not go re-read the same files.

## 5. Dispatch a worker

```powershell
fm-spawn.ps1 -TaskId my-task -Project C:\repos\thing `
             -BriefPath $env:FM_HOME\data\my-task\brief.md `
             -Harness claude -LaunchCommand claude
```

`-LaunchCommand` is required today: the per-harness launch-command templates
are a separate area that has not landed, and this port never guesses how to
start an agent. Pass the command you would type in the pane yourself.

The worker lands in its own leased worktree acquired with
`treehouse get --lease`, never in your checkout. If the isolation check fails
the task stops before an agent exists.

## 6. See what it is doing

```powershell
fm-session-start.ps1          # the whole fleet, one digest
Get-Content $env:FM_HOME\state\my-task.meta
Get-Content $env:FM_HOME\state\my-task.status -Tail 20
```

`state\<id>.meta` is the durable record (endpoint, worktree, project, harness).
`state\<id>.status` is the append-only event log the worker writes. The digest
prints both, plus whether the endpoint is still alive.

There is no `fm-peek.ps1` yet - the pane-capture command has not been ported.

## 7. Steer or stop it

```powershell
fm-send.ps1 my-task "please rebase onto main"
fm-control.ps1 my-task interrupt     # cancel the current turn, agent keeps running
fm-control.ps1 my-task exit          # stop the agent, keep the worktree and its work
```

Task id first, then the verb.

`exit` preserves the endpoint, the worktree and every uncommitted change. It is
not a teardown. Nothing in this port discards a worker's uncommitted work: the
pooled-worktree refresh refuses outright on a dirty copy rather than resetting
over it.

## Optional: have a pane start Claude for you

Off unless you ask for it. Write `config/autolaunch` in the home:

```
command=claude --dangerously-skip-permissions --continue --chrome
delay=10
```

Then point `fm-autolaunch.ps1` at a herdr pane (`<session>:<pane-id>`). It types
that command into the pane without submitting it, waits the delay, and presses
Enter only if you have not touched the pane in the meantime. Touch it - type
anything at all - and it stands down and leaves your text alone.

`fm-doctor.ps1` prints the command whenever this is on, which matters here:
`--dangerously-skip-permissions` turns off Claude's permission checks for every
session it starts. That is your call to make, and the doctor line is so it is
never a surprise. [`autolaunch-windows.md`](autolaunch-windows.md) has the rest.

## Optional: hear it instead of watching for it

Also off unless you ask for it. Write `config/voice` in the home - the file
existing is the switch, and all three keys are optional:

```
voice=Microsoft Hazel Desktop
rate=1
confidence=0.75
```

Then `fm-say.ps1 "the payments fix is ready for your review"` says it out loud,
and `fm-ask.ps1 "Ready to land?" -Options yes,no` asks you and listens for which
one you say. Each script's `-h` has the rest, and this lists the voice names your
machine has:

```powershell
Add-Type -AssemblyName System.Speech
(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices().VoiceInfo.Name
```

A name it does not recognise falls back to the default voice and says so on
stderr, rather than going quiet.

`fm-ask.ps1` only ever picks between the options you give it, and it refuses
rather than guesses: below `confidence` it returns no answer at all, and tells
you what it thought it heard and how sure it was. Silence returns no answer too,
within a few seconds.

Three things to know. Nothing speaks or listens on its own: firstmate does not
call either command, so turning this on cannot leave your machine talking about
work you did not ask to hear about, and the microphone is never opened unless
you created that file. Speaking is never delivery - anything needing your answer
still reaches you in chat whether or not you also heard it. And **a spoken answer
is never taken as your word for a merge, a delete, or anything else you cannot
undo**; ask one of those by voice and it refuses outright.
[`voice-windows.md`](voice-windows.md) has the rest.

## When something is wrong

```powershell
fm-doctor.ps1                 # what is missing and how to fix it
fm-bootstrap.ps1              # the diagnostics the digest folds in; silence = all good
.\bin\fm-setup.ps1            # repair the wiring, idempotently
```

If a command reports the wrong home - or `fm-home.ps1` prints your checkout
where the home should be - the `.fm-home` file beside the checkout is missing or
stale. Re-run `.\bin\fm-setup.ps1`. `$env:FM_HOME` always overrides it.

`fm-setup.ps1` never installs a tool. It reports what to install and leaves the
decision to you.

## What is not there yet

The port is being built area by area. `docs/windows-e2e-evidence.md` lists
exactly what has been proven to run, what is blocked on an unlanded area, and
what has not yet been executed on Windows hardware. Read it before relying on
anything above beyond steps 1-4.
