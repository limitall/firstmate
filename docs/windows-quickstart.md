# firstmate on Windows - quickstart

Native PowerShell 7. No WSL, no Git Bash, no Linux anything.

## 1. Install the prerequisites

```powershell
winget install Microsoft.PowerShell     # PowerShell 7.6+  - required
winget install Git.Git                  # git              - required
npm install -g @anthropic-ai/claude-code
irm https://kunchenguid.github.io/treehouse/install.ps1 | iex   # isolated worktrees
# herdr (the session provider): https://herdr.dev
```

Then **open a new `pwsh` window** so the installs are on PATH.

Only PowerShell 7 and git are hard requirements. Without herdr and treehouse
you get a working home that cannot dispatch a worker yet; the doctor says so.

## 2. Set up - one command

```powershell
git clone <your firstmate-win remote> C:\Users\<you>\firstmate-win
C:\Users\<you>\firstmate-win\bin\fm-setup.ps1
```

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
existing is the switch, and both keys are optional:

```
voice=Microsoft Hazel Desktop
rate=1
```

Then `fm-say.ps1 "the payments fix is ready for your review"` says it out loud.
`fm-say.ps1 -h` has the rest, and this lists the voice names your machine has:

```powershell
Add-Type -AssemblyName System.Speech
(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices().VoiceInfo.Name
```

A name it does not recognise falls back to the default voice and says so on
stderr, rather than going quiet.

Two things to know. Nothing speaks on its own: firstmate does not call this, so
turning it on cannot leave your machine talking about work you did not ask to
hear about. And speaking is never delivery - there is no spoken question in this
port, so anything needing your answer still reaches you in chat.
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
