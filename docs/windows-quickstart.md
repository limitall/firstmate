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

That creates the home (`config/ data/ projects/ state/`), selects the herdr
backend, puts `Import-Module Firstmate` and the `fm-*` commands on PATH for
every new session, registers the Claude hooks, and prints a doctor report.

It is idempotent - re-run it any time, after moving the checkout, or to repair
the wiring. If a hard prerequisite is missing it installs **nothing** and tells
you what to fix.

The home defaults to `%USERPROFILE%\firstmate`. To put it elsewhere:

```powershell
.\bin\fm-setup.ps1 -FirstmateHome D:\firstmate
```

**Open a new `pwsh` window** before step 3.

## 3. Check the environment

```powershell
fm-doctor.ps1
```

Every check is printed. `[ok]` verified, `[warn]` installed but cannot dispatch
yet, `[missing]` broken. Each non-ok line carries the command that fixes it.
Exit code 0 means nothing is missing.

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

`fm-setup.ps1` never installs a tool. It reports what to install and leaves the
decision to you.

## What is not there yet

The port is being built area by area. `docs/windows-e2e-evidence.md` lists
exactly what has been proven to run, what is blocked on an unlanded area, and
what has not yet been executed on Windows hardware. Read it before relying on
anything above beyond steps 1-4.
