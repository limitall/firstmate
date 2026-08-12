# firstmate-win

A native Windows / PowerShell port of firstmate.

**Goal:** run on Windows with PowerShell natively, with no Linux dependency of any kind.

## Start here

- **[docs/windows-quickstart.md](docs/windows-quickstart.md)** - install, set up,
  and run it. One command: `bin/fm-setup.ps1`.
- **[docs/windows-e2e-evidence.md](docs/windows-e2e-evidence.md)** - what has
  actually been executed and what has not. Read this before relying on anything.
- [AGENTS.md](AGENTS.md) - rules for changing this repo.
- `docs/` - one design note per area.

```powershell
.\bin\fm-setup.ps1     # bare machine -> working firstmate home, idempotent
fm-doctor.ps1          # what is missing, and how to fix it
```
