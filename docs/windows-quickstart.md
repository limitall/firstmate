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
`CLAUDE.md`, puts `Import-Module Firstmate` and the `fm-*` commands on PATH for
every new session, registers the Claude hooks, and prints a doctor report.

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
`AGENTS.md`, `.claude/` and `config/ data/ projects/ state/` all sit together and
one `cd` gets you everything. The four operational directories are gitignored,
so `git pull` still works normally.

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
