# firstmate-win

A native Windows / PowerShell port of firstmate.

**Goal:** run on Windows with PowerShell natively, with no Linux dependency of any kind.

## One clone, one command

```powershell
git clone <this repo> C:\Users\<you>\firstmate-win
cd C:\Users\<you>\firstmate-win
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That is the whole setup on a fresh Windows machine, and it is the ONLY command.
Nothing else is left for you to run: a step you have to perform yourself for the machine to work is a defect in the installer, not an instruction to you.
The one exception is a step no script can take, and that one is named on screen with its reason rather than left to be discovered.

**Clone it into your own profile, as above, and not into Documents, Desktop or OneDrive.**
OneDrive replaces files with placeholders and does not carry the two links this repo commits, so an install there fails a check nothing in this repo can fix; Documents and Desktop are what Controlled folder access protects when it is switched on.
The installer checks where it is before it does anything, says so, and proves the location by writing to it rather than guessing.

**The `-ExecutionPolicy Bypass` is not optional on a clean machine and it changes no machine setting.**
Windows ships with script execution switched off, so a bare `.\install.ps1` answers `install.ps1 cannot be loaded because running scripts is disabled on this system` - which is the first thing a newcomer would meet.
That form sets the policy for the one process it starts and nothing else, so it needs no administrator and leaves the machine exactly as it found it.
`install.ps1` assumes nothing is already installed - not the shell, not git, not Node, not even the package manager it would use for them - and checks every one of those before it needs them.
It installs each missing tool from the vendor that publishes it, wires the home, repairs the two committed symlinks a Windows clone does not get, and then **proves the result**: every tool is run and made to print a version, the instructions and skills are read and counted, and this repo's own test suite is executed.

No step needs administrator, and none of it is silent about that: every tool comes from a per-user installer or a release archive expanded under `%LOCALAPPDATA%\Programs`.
The one route that would need elevation is git's, and you already have git - you used it to clone this.
Where a tool is already installed but older than the latest published version, you are asked once, with what is installed and what is available; declining is always safe and never stops the run.
Where a tool is below a minimum this repo actually states, you are told, that step is skipped rather than installed over, and the machine is reported as not ready.
Where a MODULE is below one, it is simply installed: PowerShell keeps every version of a module in its own directory, so the copy already there is left exactly where it is.
That is how Windows' own Pester 3.4.0 stops being something you have to replace by hand.

Add `-Unattended` to that command to take the safe default for every question, or `-DetectOnly` to see what the machine has and change nothing.
Re-running it at any time is safe, and changes only what it must.

The last thing it prints is a verdict, not a summary: **READY**, or **NOT READY** with every requirement and what happened to it.

Then it offers to start firstmate, once, and only an explicit yes starts anything - pressing Enter declines, and nothing starts on an unattended run.

Whether you accept or not, it also names how to start it yourself:

```powershell
firstmate               # start it - opens your browser, everything happens there
```

That one-word command works in any NEW window.
The window you installed from took its copy of `PATH` when it opened, and no program can hand a running window a new one - that is Windows, not a step the installer skipped - so for that window the install prints the full path to the same command, which works there straight away.

## Start here

- **[docs/windows-quickstart.md](docs/windows-quickstart.md)** - install, set up,
  and run it, with what each step does.
- **[docs/windows-e2e-evidence.md](docs/windows-e2e-evidence.md)** - what has
  actually been executed and what has not. Read this before relying on anything.
- [AGENTS.md](AGENTS.md) - the first mate's operating contract. This is what a
  session started in this directory reads, and `CLAUDE.md` links to it.
- [CONTRIBUTING.md](CONTRIBUTING.md) - rules for changing this repo.
- `docs/` - one design note per area.

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1    # fresh machine -> working, verified firstmate; idempotent
.\bin\fm-setup.ps1     # just the home and the wiring, without touching any tool
fm-doctor.ps1          # what is missing, and how to fix it
```
