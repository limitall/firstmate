# firstmate-win

A native Windows / PowerShell port of firstmate.

**Goal:** run on Windows with PowerShell natively, with no Linux dependency of any kind.

## One clone, one command

```powershell
git clone <this repo> C:\Users\<you>\firstmate-win
cd C:\Users\<you>\firstmate-win
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That is the whole setup on a fresh Windows machine.
**The `-ExecutionPolicy Bypass` is not optional on a clean machine and it changes no machine setting.**
Windows ships with script execution switched off, so a bare `.\install.ps1` answers `install.ps1 cannot be loaded because running scripts is disabled on this system` - which is the first thing a newcomer would meet.
That form sets the policy for the one process it starts and nothing else, so it needs no administrator and leaves the machine exactly as it found it.
`install.ps1` assumes nothing is already installed - not the shell, not git, not Node, not even the package manager it would use for them - and checks every one of those before it needs them.
It installs each missing tool from the vendor that publishes it, wires the home, repairs the two committed symlinks a Windows clone does not get, and then **proves the result**: every tool is run and made to print a version, the instructions and skills are read and counted, and this repo's own test suite is executed.

No step needs administrator.
Where a tool is already installed but older than the latest published version, you are asked once, with what is installed and what is available; declining is always safe and never stops the run.
Where a tool is below a minimum this repo actually states, you are told, that step is skipped rather than installed over, and the machine is reported as not ready.
Where a MODULE is below one, it is simply installed: PowerShell keeps every version of a module in its own directory, so the copy already there is left exactly where it is.
That is how Windows' own Pester 3.4.0 stops being something you have to replace by hand.

Add `-Unattended` to that command to take the safe default for every question, or `-DetectOnly` to see what the machine has and change nothing.
Re-running it at any time is safe.

Then, from any shell:

```powershell
firstmate               # start it - opens your browser, everything happens there
```

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
