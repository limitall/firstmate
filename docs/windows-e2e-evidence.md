# End-to-end evidence

What was actually executed, with the real output, and what was not.

**Read the headline first.** The brief asked for this to be proven on the
Windows 11 laptop. **It was not**, because the laptop became unreachable and
stayed unreachable for the whole task. Everything below was executed on
PowerShell 7.6.4 on Linux. Each claim is tagged with where it was proven.

Tags used throughout:

| Tag | Meaning |
| --- | --- |
| `PROVEN (pwsh/Linux)` | executed, output captured below. The code path is platform-neutral but the run did not happen on Windows. |
| `NOT YET VERIFIED ON WINDOWS HARDWARE` | the mechanism is implemented and tested, but has never executed on Windows. |
| `BLOCKED (area)` | cannot be proven anywhere yet because the named area has not landed on `main`. |
| `BLOCKED (brief gate)` | deliberately not executed because this task's brief forbids it. |

---

## 0. The Windows laptop was unreachable

The brief provides `ssh -p 2222 -i ~/.ssh/fmwin_ed25519 admin@localhost`. It
never completed a handshake at any point during this task.

First attempt, 04:49 IST - TCP connects, no SSH banner ever arrives, i.e. the
forwarder on this box is listening but the laptop end of the tunnel is gone:

```
$ ssh -vv -p 2222 -i ~/.ssh/fmwin_ed25519 -o ConnectTimeout=45 admin@127.0.0.1 'echo OK'
debug1: Connecting to 127.0.0.1 [127.0.0.1] port 2222.
debug1: Connection established.
debug1: identity file /home/adit-admin/.ssh/fmwin_ed25519 type 3
debug1: Local version string SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u10
Connection timed out during banner exchange
Connection to 127.0.0.1 port 2222 timed out
```

```
$ ss -ltnp 'sport = :2222'
LISTEN 0  128  127.0.0.1:2222  0.0.0.0:*
LISTEN 0  128      [::1]:2222     [::]:*
```

Polled every 45s for 14 consecutive attempts (04:50 - 05:04 IST), all down.
Retried at 05:19 and again at 05:55 IST, by which point the listener itself had
gone:

```
$ ssh -p 2222 -i ~/.ssh/fmwin_ed25519 admin@127.0.0.1 'pwsh -NoProfile -Command "$PSVersionTable.PSVersion.ToString()"'
ssh: connect to host 127.0.0.1 port 2222: Connection refused
```

No file was ever copied to, and no command was ever run on,
`C:\Users\ADMIN\firstmate-win`.

**Consequence:** every Windows-specific claim in this port remains unmeasured.
That includes the ones this area introduces (`$PROFILE.CurrentUserAllHosts`
location and load behaviour, `PSModulePath`/`PATH` prepending in a Windows
session, `.ps1` command discovery from `PATH` on Windows) and the ones it
inherits (`treehouse` on Windows, `herdr` on Windows, Claude hooks with
`"shell": "powershell"`).

---

## Environment everything below ran on

```
Linux debian-12 6.1.0-52-amd64 x86_64 GNU/Linux
PowerShell        7.6.4          (the stock Windows toolchain version)
Pester            6.1.0
PSScriptAnalyzer  1.25.0
git               2.39.5
herdr             0.7.5
treehouse         v2.1.1
Claude Code       2.1.228
branch            fm/fmwin-install, rebased onto origin/main
```

Captures were taken before and after that rebase; the setup, doctor and digest
captures below were re-taken afterwards so they reflect the merged tree.

Paths in the captures are elided: `<REPO>` is the checkout, `<E2E>` the scratch
directory holding the throwaway home and demo project.

---

## Step 1 - setup runs and the doctor reports a healthy environment

**`PROVEN (pwsh/Linux)`.** From a clean home that did not exist:

```
$ pwsh -NoProfile -Command "& '<REPO>/bin/fm-setup.ps1' -FirstmateHome '<E2E>/home' -ProfilePath '<E2E>/profile.ps1' -HookSettingsPath '<E2E>/settings.json'"

fm-setup: <E2E>/home

  [created] home - <E2E>/home
  [created] home/config
  [created] home/data
  [created] home/projects
  [created] home/state
  [created] backend - config/backend=herdr
  [created] profile wiring - <E2E>/profile.ps1
  [created] Claude hooks - <E2E>/settings.json

fm-doctor: <REPO> -> <E2E>/home

prerequisites:
  [ok]      PowerShell 7 - 7.6.4
  [ok]      git - git version 2.39.5
  [ok]      Pester 5+ - 6.1.0
  [ok]      herdr - herdr 0.7.5
  [ok]      treehouse - v2.1.1 (get --lease supported)
  [ok]      Claude CLI - 2.1.228 (Claude Code)

home:
  [ok]      FM_HOME - <E2E>/home
  [ok]      home layout - <E2E>/home (config, data, projects, state)
  [ok]      backend - herdr

wiring:
  [ok]      Firstmate module - Import-Module Firstmate resolves on PSModulePath
  [ok]      fm-* entry points - <REPO>/bin is on PATH
  [ok]      profile wiring - <E2E>/profile.ps1
  [ok]      Claude hooks - SessionStart, PreToolUse, Stop registered in <E2E>/settings.json

healthy: every check passed.
EXIT=0
```

### Idempotence, byte-for-byte

**`PROVEN (pwsh/Linux)`.** Second run of the same command:

```
  [already] home - <E2E>/home
  [already] home/config
  [already] home/data
  [already] home/projects
  [already] home/state
  [already] backend - config/backend=herdr
  [already] profile wiring - <E2E>/profile.ps1
  [already] Claude hooks - <E2E>/settings.json
```

```
$ md5sum settings.json profile.ps1          # before the second run
1486c7b5613d020e4ed97c51f9a2c282  settings.json
25bc0d1a52a32f5bec0394e8fc0db961  profile.ps1
$ md5sum settings.json profile.ps1          # after
1486c7b5613d020e4ed97c51f9a2c282  settings.json
25bc0d1a52a32f5bec0394e8fc0db961  profile.ps1
```

### `Import-Module Firstmate` really works from a fresh session

**`PROVEN (pwsh/Linux)`.** A new process, `-NoProfile`, loading only the block
setup wrote:

```
$ cd /tmp && pwsh -NoProfile -Command ". '<E2E>/profile.ps1'; Import-Module Firstmate; ..."
FM_HOME=<E2E>/home
module: <REPO>/module/Firstmate/Firstmate.psm1
doctor on PATH: <REPO>/bin/fm-doctor.ps1
setup exported: True
```

`NOT YET VERIFIED ON WINDOWS HARDWARE`: that `$PROFILE.CurrentUserAllHosts`
resolves to `Documents\PowerShell\profile.ps1` on the laptop and is loaded by
the host the captain actually opens.

### The doctor when things are wrong

**`PROVEN (pwsh/Linux)`.** Every check prints, each failure carries its fix,
exit code is 1:

```
$ pwsh -NoProfile -Command "& '<REPO>/bin/fm-doctor.ps1' -FirstmateHome '<HOME>/nonexistent-home' -ProfilePath '<HOME>/no-profile.ps1' -HookSettingsPath '<HOME>/no-settings.json'"

home:
  [missing] FM_HOME - not set in this session
              fix: run bin/fm-setup.ps1, then open a new PowerShell session
  [missing] home layout - '<HOME>/nonexistent-home' does not exist
              fix: bin/fm-setup.ps1 -FirstmateHome '<HOME>/nonexistent-home'

wiring:
  [missing] Firstmate module - not on PSModulePath in this session
              fix: run bin/fm-setup.ps1, then open a new PowerShell session
  [missing] fm-* entry points - <REPO>/bin is not on PATH in this session
              fix: run bin/fm-setup.ps1, then open a new PowerShell session
  [missing] profile wiring - no profile at <HOME>/no-profile.ps1
              fix: bin/fm-setup.ps1 -FirstmateHome '<HOME>/nonexistent-home'
  [missing] Claude hooks - not registered in <HOME>/no-settings.json
              fix: bin/fm-setup.ps1

unhealthy: 6 missing, 0 warning(s). Fix the missing ones above, then re-run fm-doctor.ps1.
EXIT=1
```

### Refuses rather than half-installing

**`PROVEN (pwsh/Linux)`,** by test rather than by capture -
`tests/FmInstall.Tests.ps1`, "installs nothing at all when a hard prerequisite
is missing", asserts the home, the profile and the settings file all still do
not exist after the refused run.

---

## Step 2 - a session starts and produces its digest

**`PROVEN (pwsh/Linux)`.**

```
$ FM_HOME=<E2E>/home pwsh -NoProfile -Command "& '<REPO>/bin/fm-session-start.ps1'"
================================================================================
SESSION START - <E2E>/home
================================================================================

LOCK
--------------------------------------------------------------------------------
lock: NOT ACQUIRED - Invoke-FmLock is not available in this module build, so fleet-lock ownership could not be verified.
●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED
...
BOOTSTRAP
--------------------------------------------------------------------------------
(silent - all good)

WAKE QUEUE
--------------------------------------------------------------------------------
skipped (read-only session) - 0 record(s) remain queued because this session lacks verified fleet-lock ownership.
SUPERVISION INSTRUCTIONS: NOT EMITTED - Get-FmSupervisionInstructions is not available in this module build.
```

The digest is produced and the nine stages are in order. Two stages report
themselves as NOT RUN rather than passed, correctly, so the session degrades to
READ-ONLY. That is the designed degradation, not a defect - but it does mean
**a session today is still a read-only session**, and the reason is worth
naming precisely:

- `Invoke-FmLock` is the name the session-start area resolves (it is in the
  table in `docs/session-start.md`). The foundation area has landed and does
  publish session locking, but under different names -
  `Request-FmSessionLock` / `Get-FmSessionLockStatus`. Neither area is wrong on
  its own; they simply have not been introduced to each other. This is exactly
  the by-name binding hazard `AGENTS.md` describes, and it is currently costing
  every session its write capability. It belongs to whoever owns that seam, not
  to this area, so it is reported rather than patched here.
- `Get-FmSupervisionInstructions` has genuinely not landed.

One cosmetic defect also shows up in this capture and is not this area's to
change: a bare `0` is printed after the WAKE QUEUE line. It looks like a count
leaking into the digest from the wake-drain owner. The digest text is a
byte-for-byte contract with the bash original, so it is flagged here rather than
edited from this branch.

### A finding this step produced, and the fix

The first run of this digest against a freshly created home printed:

```
BOOTSTRAP
--------------------------------------------------------------------------------
MISSING: tmux (install: brew install tmux  # or the platform's package manager)
```

A home with no `config/backend` resolves to `tmux`, so the captain's very first
Windows session opened by asking for a tool that has no Windows build. Setup now
writes `config/backend=herdr` when the home has not already chosen one, and the
same digest prints `(silent - all good)`. Covered by four tests in
`tests/FmInstall.Tests.ps1`, including one that asserts
`Get-FmBootstrapBackendName` resolves to `herdr` specifically so the regression
cannot come back silently.

---

## Step 3 - a worker is dispatched into an isolated copy, genuinely isolated

**Split verdict. The isolation half is proven; the dispatch half is not.**

### The isolated copy - `PROVEN (pwsh/Linux)`, against real treehouse v2.1.1

A throwaway git project with a treehouse pool, then the port's own acquisition
path:

```
$ pwsh -NoProfile -Command "Import-Module <REPO>/module/Firstmate/Firstmate.psd1; New-FmIsolatedWorktree -Project '<E2E>/demo' -LeaseHolder 'fm-e2e-demo'"
LEASED PATH : <E2E>/demo/.treehouse/demo-be25ec/1/demo
LEASE ID    : 1da7b84383f5d8c0e106d0749828112c
HOLDER      : fm-e2e-demo
isolation   : True
same as primary? False
```

The isolation is real, not asserted:

```
$ git -C <leased> rev-parse --show-toplevel
<E2E>/demo/.treehouse/demo-be25ec/1/demo
$ git -C <E2E>/demo rev-parse --show-toplevel
<E2E>/demo

$ git -C <E2E>/demo worktree list
<E2E>/demo                                c6b56a7 [main]
<E2E>/demo/.treehouse/demo-be25ec/1/demo  c6b56a7 (detached HEAD)

# a worker writing in the copy does not touch the primary
$ echo "work done by the worker" > <leased>/worker-artifact.txt
in copy   : <leased>/worker-artifact.txt
in primary: (absent - primary untouched)
copy status   : ?? worker-artifact.txt
```

(The primary's only `git status` entry is treehouse's own `.gitignore`, not the
worker's file.)

The lease release is conditional on the exact lease identity, as designed:

```
return with a WRONG lease id (must refuse):
  released = False
return with the CORRECT lease id:
  released = True
```

`NOT YET VERIFIED ON WINDOWS HARDWARE`: treehouse has never been measured on
Windows by this repo or upstream. The two specific risks flagged in
`docs/worktree-isolation-windows.md` - resetting a leased worktree while a
handle is open, and case-insensitive pool-path comparison - remain unmeasured.

### The dispatch itself - `BLOCKED (brief gate)` and `BLOCKED (harness area)`

`Start-FmWorker` was **not** executed. Two independent reasons:

1. **`BLOCKED (brief gate)`.** This task's brief carries
   `Herdr lifecycle declaration - NOT ENABLED`, which forbids driving Herdr
   lifecycle behaviour without regenerating the brief with `--herdr-lab`.
   `Start-FmWorker` creates a herdr container, tab and pane (and may start the
   herdr server); `Stop-FmWorker -ClosePane` removes a pane. Both are exactly
   that. The herdr server on this box also serves the live firstmate fleet, so
   this is not a theoretical concern.
2. **`BLOCKED (harness area)`.** `Start-FmWorker` requires a launch command and
   refuses to invent one: `error: no launch command for harness 'claude'; pass
   -LaunchCommand, because this port never guesses how to start an agent`.
   `Get-FmHarnessLaunchCommand` is not on `main`, so `-Harness claude` alone
   does not work yet. The quickstart documents `-LaunchCommand` as required for
   this reason.

The spawn path's own logic is covered by 47 tests in `tests/FmWorker.Tests.ps1`
against a mocked herdr, and 29 in `tests/FmWorktree.Tests.ps1`. Those are unit
proofs, not an end-to-end dispatch, and I am not calling them one.

---

## Step 4 - its state can be read back

**`PROVEN (pwsh/Linux)`** for the file-contract half.

Written through the real `Write-FmTaskMeta`, read through the real
`Get-FmMetaValue`:

```
record written: <E2E>/home/state/e2e-demo.meta

read back through Get-FmMetaValue:
  window             = fm-e2e-demo
  worktree           = <E2E>/demo/.treehouse/demo-be25ec/1/demo
  project            = <E2E>/demo
  harness            = claude
  backend            = herdr
  treehouse_lease_id = 1da7b84383f5d8c0e106d0749828112c

bytes  : 461, CR present: False, BOM: False
```

The byte-for-byte contract with a Linux firstmate holds - `cat -A` shows LF
only, no BOM, fields in the bash order:

```
window=fm-e2e-demo$
endpoint_task_id=e2e-demo$
worktree=<E2E>/demo/.treehouse/demo-be25ec/1/demo$
project=<E2E>/demo$
harness=claude$
kind=ship$
backend=herdr$
treehouse_lease_id=1da7b84383f5d8c0e106d0749828112c$
```

And the digest reads it back as fleet state, including endpoint liveness and the
status tail:

```
Work under way (state/*.meta)
--------------------------------------------------------------------------------

--- e2e-demo ---
window=fm-e2e-demo
endpoint_task_id=e2e-demo
worktree=<E2E>/demo/.treehouse/demo-be25ec/1/demo
project=<E2E>/demo
harness=claude
kind=ship
backend=herdr
treehouse_lease_id=1da7b84383f5d8c0e106d0749828112c
endpoint: dead (backend=herdr window=fm-e2e-demo)
status tail (last 5 line(s), each capped at 220 characters, ...):
working: leased an isolated copy
blocked: demo blocker [key=demo]
```

`endpoint: dead` is correct - the record was written by hand, so no pane exists.
Reading back the state of a **live** worker is `BLOCKED (brief gate)` for the
same reason as step 3.

---

## Step 5 - it can be stopped, and cleanup refuses to discard uncommitted work

**Split verdict.**

### Cleanup refuses to discard uncommitted work - `PROVEN (pwsh/Linux)`

Against the real dirty worktree from step 3:

```
uncommitted work present: ?? worker-artifact.txt

Update-FmWorktreeBase on the dirty copy:
  REFUSED: error: pooled worktree '<E2E>/demo/.treehouse/demo-be25ec/1/demo' is not clean;
           refusing to discard uncommitted work while refreshing its base

the uncommitted work is still there: True
its contents: work done by the worker
```

This is the refusal that exists on `main` today: the pooled-base refresh will
not reset over a dirty worktree. It is a genuine "never discard a worker's
work" guarantee and it holds.

### The real teardown refusal - `PROVEN (pwsh/Linux)`

The teardown area landed on `main` during this task (the rebase brought
`bin/fm-teardown.ps1` and `Invoke-FmTeardown`), so the strongest form of this
guarantee is now demonstrable - and it is demonstrable **without** driving
herdr, because the landed-work test runs before the `ShouldProcess` gate and
before any process is touched.

A task record pointing at a leased worktree holding an uncommitted file:

```
$ git -C <leased> status --porcelain
?? worker-artifact.txt

$ FM_HOME=<E2E>/home pwsh -NoProfile -Command "& '<REPO>/bin/fm-teardown.ps1' e2e-demo"
REFUSED: worktree <E2E>/demo/.treehouse/demo-be25ec/1/demo has uncommitted changes.
uncommitted changes present
Commit them (or get the captain's explicit OK to discard, then --force).
EXIT=1

$ ls <leased>/worker-artifact.txt
<leased>/worker-artifact.txt          # the work is untouched
```

And `--force` is not the path of least resistance - a bare one is a usage error,
not a slightly harder retry:

```
$ FM_HOME=<E2E>/home pwsh -NoProfile -Command "& '<REPO>/bin/fm-teardown.ps1' e2e-demo --force"
fm-teardown: --force discards work that has not landed, so it requires --approved-by "<who approved it>"
usage: fm-teardown.ps1 <task-id> [--force --approved-by "<authority>"]
EXIT=2
```

`NOT YET VERIFIED ON WINDOWS HARDWARE`: the teardown steps *after* the refusal -
Win32 job-object process custody, the exclusive-open stale-lock probe, and
returning the worktree while Windows may hold handles inside it - were not
reached here and are the Windows-specific half of that area.

### Stopping the agent - `BLOCKED (brief gate)`

`Stop-FmWorker` was not executed, for the herdr-lifecycle reason in step 3. Its
logic - endpoint identity validation, the interrupt-then-exit sequence, and the
agent-state postcondition - is covered by `tests/FmWorker.Tests.ps1` against a
mocked herdr.

---

## Honest summary

### Works end to end, executed on PowerShell 7.6.4 (Linux)

- `bin/fm-setup.ps1` from a clean machine to a working home; idempotent,
  byte-for-byte, refuses rather than half-installing.
- `Import-Module Firstmate` and `fm-*.ps1` on `PATH` in a fresh session.
- `bin/fm-doctor.ps1`, healthy and unhealthy, every check printed with a fix,
  exit codes 0 and 1.
- Claude hook registration, preserving unrelated keys and events, refusing an
  unparseable settings file.
- `bin/fm-session-start.ps1` digest, including bootstrap diagnostics falling
  silent on a correctly set-up home.
- Isolated-worktree acquisition against real treehouse v2.1.1, with the
  isolation independently verified through git, and conditional lease release.
- Task-record write and read-back, LF-only and BOM-free.
- Refusal to discard uncommitted work, in both places it is enforced: the
  pooled-base refresh, and `fm-teardown.ps1`'s landed-work test (plus its
  `--force` usage gate).

### Does not work end to end yet, and precisely why

| Capability | Blocked by |
| --- | --- |
| Dispatching a real worker | this brief's herdr-lifecycle gate; plus `Get-FmHarnessLaunchCommand` (harness area) is not on `main`, so `-LaunchCommand` is mandatory |
| Stopping a real agent | this brief's herdr-lifecycle gate |
| Teardown past the refusal (process custody, returning the worktree) | not reached; its Windows-specific half needs Windows |
| A session that is not read-only | the session area resolves `Invoke-FmLock`; the foundation publishes `Request-FmSessionLock`. A name mismatch across a landed seam, not a missing area |
| Turn-end supervision | `Get-FmSupervisionInstructions` not on `main` |
| `fm-peek` | not ported |

### Never executed on Windows

Everything. No line of this port has run on Windows hardware during this task.
The mechanisms this area introduces are platform-neutral by construction
(`$PROFILE`, `PSModulePath`, `PATH`, `[System.IO.Path]::PathSeparator`,
`Join-Path` throughout, no `$IsWindows`-only code path in the setup itself), and
the install-command table is already platform-aware, but "should work" is not
"was proven". The first thing to do when the laptop returns:

```powershell
cd C:\Users\ADMIN\firstmate-win
git pull
.\bin\fm-setup.ps1
# open a NEW pwsh window
fm-doctor.ps1
fm-session-start.ps1
Invoke-Pester -Path .\tests\
```

and replace the `NOT YET VERIFIED ON WINDOWS HARDWARE` tags above with the real
output.

---

## Suite and analyzer numbers

Run **after** the rebase onto `origin/main` (which brought 24 commits: the
foundation, teardown, watcher, wake and lifecycle areas):

```
$ pwsh -NoProfile -Command 'Invoke-Pester -Path ./tests/'
Tests Passed: 902, Failed: 0, Skipped: 5, Inconclusive: 0, NotRun: 0
```

This area contributes 47 tests in `tests/FmInstall.Tests.ps1` and the merged
`tests/FmModuleAssembly.Tests.ps1`.

PSScriptAnalyzer, with the repository's own settings file:

```
$ Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

- **This area's files: 0 findings** (`FmInstall.ps1`, `Install-FmHome.ps1`,
  `Invoke-FmDoctor.ps1`, `fm-setup.ps1`, `fm-doctor.ps1`, `FmInstall.Tests.ps1`,
  `FmModuleAssembly.Tests.ps1`).
- **Repository-wide: 779 findings (219 Warning, 560 Information)**, all in files
  owned by other areas - `FmTeardown.ps1` 112, `FmBackendHerdr.ps1` 105,
  `FmBootstrap.ps1` 70, `FmHooks.Tests.ps1` 63, `FmHooks.ps1` 53, and so on.
  This area did not create them and did not silence them by editing the shared
  settings file, which belongs to the foundation area. Flagging it here because
  the repo does not currently meet its own "PSScriptAnalyzer clean" bar and
  nothing else is reporting that.

## A rebase break this work caught

Worth recording because it is the second instance of the same hazard, and this
one was caught by the discipline the brief asks for - re-running after the
rebase rather than trusting a clean replay.

`Get-FmInstallHomeDirectoryName` delegated to the foundation area's
`Get-FmHomeLayout` by name and read its output as a **list of directory names**.
`Get-FmHomeLayout` returns **one pscustomobject** with `Home`/`State`/`Data`/
`Config`/`Projects` properties. While the foundation area was unlanded the
delegation never fired and every test passed; the moment the rebase landed it,
the object stringified into a single bogus directory name:

```
what the delegation produced as a directory name:
  [@{Root=...; Home=/tmp/fmprobe-...; State=/tmp/fmprobe-.../state; Data=...; Config=...; Projects=...}]
```

Setup would have created that instead of the four directories. Fixed by reading
the named properties explicitly, which also means the layout owner's
`FM_STATE_OVERRIDE` handling is now honoured rather than bypassed - a partial
answer falls back to the local layout rather than producing half a home. Pinned
by four tests in `tests/FmInstall.Tests.ps1`, including one asserting no
directory name ever looks like a stringified object.

## A flaky test this work exposed, and fixed

Running the whole suite (rather than one file) failed two of this area's tests
while the same tests passed in isolation. Cause: `tests/FmBootstrap.Tests.ps1`
sets `$env:FM_BACKEND = 'nonesuch'` in its last-but-one `Describe`, whose
following `Describe` has no `BeforeEach` to reset it. Environment variables are
process-wide and Pester containers are not isolated from each other, so the
override escaped into every test file that runs after it alphabetically - where
`Get-FmBootstrapBackendName` honours `FM_BACKEND` ahead of `config/backend`.

Fixed at the source (a root `AfterAll` in `FmBootstrap.Tests.ps1`) and
defensively in `FmInstall.Tests.ps1`, which now saves, clears and restores
`FM_BACKEND` like the other environment keys it depends on. Both files pass
alone and in the full suite.
