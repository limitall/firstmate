# End-to-end evidence

What was actually executed, with the real output, and what was not.

**Read the headline first.** Sections 0-5 below were written by an earlier task
for which the Windows 11 laptop was unreachable for its whole duration; they say
so, and everything in them was executed on PowerShell 7.6.4 on Linux.

**Section 6 is different, but only in part.** The laptop was reachable for the
first half of the entry-point bootstrap task and then died mid-task.

- **6.1 to 6.4 were executed on the laptop.** Where they contradict the sweeping
  "Never executed on Windows / Everything." claim under "Honest summary", they
  are the ones that ran. That makes the install, the home resolution, all 23
  entry points and the whole Pester suite Windows-proven.
- **6.5 was NOT.** The tunnel was gone before it could run. Its fix is green on
  Linux and covered by regression tests, and it says so in its own words rather
  than borrowing the credibility of the sections around it.

Tags used throughout:

| Tag | Meaning |
| --- | --- |
| `PROVEN (Windows 11)` | executed on the captain's laptop, output captured below. |
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

## 6. The entry points, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

The laptop was reachable for this one. Everything in this section was executed
on it over `ssh -p 2222`, with the scripts copied across and run with `-File`.
Nothing outside `C:\Users\ADMIN` was touched.

Setup used for all of it, so the reproduction and the fix are the same install:

| | |
| --- | --- |
| checkout | `C:\Users\ADMIN\fmwin5`, a fresh clone from a bundle |
| home | `C:\Users\ADMIN\firstmate5` |
| toolchain | PowerShell 7.6.4, Pester 6.1.0, git 2.49.0.windows.1, herdr 0.7.5-preview, treehouse v2.1.1, Claude CLI 2.1.224 |

### 6.1 The defect, reproduced on `main` at `c8fa82c`, BEFORE the fix

`fm-setup.ps1` ran cleanly and the doctor reported `healthy: every check passed.`
in the shell that ran it. In a shell that had not loaded the profile, the same
install reported:

```
$ pwsh -NoProfile -ExecutionPolicy Bypass -File C:\Users\ADMIN\fmwin5\bin\fm-doctor.ps1
fm-doctor: C:\Users\ADMIN\fmwin5 -> C:\Users\ADMIN\firstmate
home:
  [missing] FM_HOME - not set in this session
  [ok]      home layout - C:\Users\ADMIN\firstmate (config, data, projects, state)
wiring:
  [missing] Firstmate module - not on PSModulePath in this session
  [missing] fm-* entry points - C:\Users\ADMIN\fmwin5\bin is not on PATH in this session
unhealthy: 3 missing, 1 warning(s).
EXIT=1
```

**And the half the report did not mention, which is the worse one.** The same
bare shell, one command later:

```
$ pwsh -NoProfile -ExecutionPolicy Bypass -File C:\Users\ADMIN\fmwin5\bin\fm-home.ps1
Root:     C:\Users\ADMIN\fmwin5
Home:     C:\Users\ADMIN\fmwin5
State:    C:\Users\ADMIN\fmwin5\state  (absent)
Data:     C:\Users\ADMIN\fmwin5\data  (absent)
Config:   C:\Users\ADMIN\fmwin5\config  (absent)
Projects: C:\Users\ADMIN\fmwin5\projects  (absent)
EXIT=0
```

The home is the CHECKOUT, not `C:\Users\ADMIN\firstmate5`, and the exit code is
0. Every state read and write in a shell like that went to the wrong directory
while every command reported success. Note also that the doctor above resolved
its home to `C:\Users\ADMIN\firstmate` while the module resolved
`C:\Users\ADMIN\fmwin5` - two different wrong answers from one install,
disagreeing with each other.

Bare command name, same shell, for completeness:

```
$ pwsh -NoProfile -ExecutionPolicy Bypass -Command "fm-doctor.ps1"
fm-doctor.ps1: The term 'fm-doctor.ps1' is not recognized as a name of a cmdlet, ...
EXIT=1
```

### 6.2 After the fix

`fm-setup.ps1` run from a bare `-NoProfile` shell, writing the pointer:

```
  [created] home pointer - C:\Users\ADMIN\fmwin5\.fm-home -> C:\Users\ADMIN\firstmate5
  ...
  healthy: every check passed.
  EXIT=0
```

The pointer's bytes, checked on Windows because this is a shared contract file:

```
path     : C:\Users\ADMIN\fmwin5\.fm-home
content  : C:\Users\ADMIN\firstmate5<LF>
bom      : False
has CR   : False
```

`fm-doctor.ps1` in a bare `-NoProfile` shell - the run that used to print
`unhealthy: 3 missing`:

```
home:
  [ok]      FM_HOME - C:\Users\ADMIN\firstmate5 (persisted in C:\Users\ADMIN\fmwin5\.fm-home; resolves with no profile and no environment)
  [ok]      home layout - C:\Users\ADMIN\firstmate5 (config, data, projects, state)
  [ok]      backend - herdr
wiring:
  [ok]      Firstmate module - Import-Module Firstmate resolves on PSModulePath
  [warn]    fm-* entry points - C:\Users\ADMIN\fmwin5\bin is not on PATH in this session, so the bare command name does not work; running one by its full path does
              fix: open a new PowerShell session, which loads the profile block bin/fm-setup.ps1 writes
  [ok]      profile wiring - C:\Users\ADMIN\Documents\PowerShell\profile.ps1
  [ok]      Claude hooks - SessionStart, PreToolUse, Stop registered in C:\Users\ADMIN\fmwin5\.claude\settings.json

healthy: nothing is missing. 1 warning(s) - each line above says what it costs.
EXIT=0
```

The one remaining `[warn]` is the honest one and it is the point of the
reclassification: that session genuinely cannot type a bare `fm-doctor.ps1`, and
nothing else about the install is affected.

`fm-doctor.ps1` in a PROFILE shell, same checkout, same moment:

```
healthy: every check passed.
EXIT=0
```

`fm-home.ps1` in a bare `-NoProfile` shell - the silent failure, fixed:

```
Root:     C:\Users\ADMIN\fmwin5
Home:     C:\Users\ADMIN\firstmate5
State:    C:\Users\ADMIN\firstmate5\state
Data:     C:\Users\ADMIN\firstmate5\data
Config:   C:\Users\ADMIN\firstmate5\config
Projects: C:\Users\ADMIN\firstmate5\projects
EXIT=0
```

The environment still overrides the pointer, so a secondmate or test home is
unaffected:

```
$ pwsh -NoProfile -Command "$env:FM_HOME='C:\Users\ADMIN\firstmate'; & ...\fm-home.ps1 -Path Home"
C:\Users\ADMIN\firstmate
```

### 6.3 Every entry point, in a bare shell

Enumerated from `bin/` on the laptop rather than from a list, so a new entry
point is covered the moment it exists. For each one, its own declared
`-RequiredCommand` is resolved through the prelude alone:

```
entry points swept: 23
PSModulePath has module/: True
FM_HOME published      : C:\Users\ADMIN\firstmate5
ALL OK
EXIT=0
```

23 is every `bin/fm-*.ps1` except the prelude itself. Three read-only entry
points were additionally run for real, each in its own bare `-NoProfile` child:

```
fm-crew-state.ps1 nobody          -> EXIT=0   state: unknown - source: none - no metadata for nobody
fm-project-mode.ps1 nosuchproject -> EXIT=0   warn: no registry at C:\Users\ADMIN\firstmate5\data\projects.md ...
fm-bootstrap.ps1 -DetectOnly      -> EXIT=0   MISSING: gh ... (the tool probes, correctly reported)
```

`fm-bootstrap.ps1` reading the right home is the load-bearing detail there: it
resolved `C:\Users\ADMIN\firstmate5\data\projects.md`, not a path under the
checkout.

And the convenience still works where it is supposed to - bare command name in a
profile shell:

```
$ pwsh -ExecutionPolicy Bypass -Command "fm-home.ps1 -Path Home"
C:\Users\ADMIN\firstmate5
EXIT=0
```

### 6.4 The full Pester suite, on Windows

```
$ pwsh -NoProfile -File suite.ps1        # Invoke-Pester -Path C:\Users\ADMIN\fmwin5\tests
pwsh   : 7.6.4
pester : 6.1.0
RESULT total=1295 passed=1272 failed=1 skipped=22 notrun=0
FAILED: Read-FmHomePointer.skips comment lines, so the captain can say what the file is for
```

That one failure was in a test written during this task, not in the port: it
asserted a hard-coded `/srv/firstmate`, which Windows resolves to
`C:\srv\firstmate` because a POSIX-looking path is drive-relative there. It is a
platform assumption in an assertion - the exact kind this port exists to remove -
and the test now builds the path with `Join-Path` instead. Fixed, and green in
the Linux suite; the corrected file has NOT been re-run on Windows, because the
tunnel died first. Re-running the suite there is part of what section 6.5 lists.

22 skipped on Windows against 5 on Linux: the two sets are different, and both
are platform gates. Linux skips the Win32 job-object and file-locking tests;
Windows skips the ones gated the other way.

### 6.5 Which directory do I start Claude in - `PROVEN (Windows 11)`

The second silent failure of the same morning, hit immediately after the first.

**The layout that caused it, read off the laptop.** On Linux the firstmate repo
root IS the home: `config/ data/ projects/ state/` are gitignored *inside* the
checkout, beside `AGENTS.md`, `CLAUDE.md` and `.claude/`. Every doc in the fleet
therefore says `cd <firstmate>; claude`. This port split them:

```
C:\Users\ADMIN\fmwin4      AGENTS.md  CLAUDE.md  .claude  bin  module  docs  tests
C:\Users\ADMIN\firstmate   config  data  projects  state
```

The captain did the documented thing - `cd C:\Users\ADMIN\firstmate`, `claude` -
and that directory has no `CLAUDE.md` and no `.claude`, so the agent came up with
no instructions, no digest and no supervision, and nothing said so.

**And a second one hiding behind it.** This repo tracks `CLAUDE.md` as a symlink
to `AGENTS.md`. Read off the laptop's clone:

```
Name       : CLAUDE.md
Length     : 9
LinkTarget :
CONTENT:
AGENTS.md
core.symlinks: false
```

Git with `core.symlinks=false` - the default for a non-elevated Windows git -
checks the symlink out as a 9-byte ordinary file containing the string
`AGENTS.md`. So `cd <checkout>; claude`, the directory that was supposed to be
the *right* answer, also gave a session one filename and no instructions.
Fixing only the home would have moved the failure, not removed it.

**After the fix.** A fresh clone, `bin\fm-setup.ps1` with no `-FirstmateHome`:

**NOT PROVEN ON THE LAPTOP.** The tunnel died before this half could be run
there, and it is recorded as unproven rather than described as if it had been.

The fix for 6.5 is implemented, is green in the full suite on Linux
(1323 tests, 0 failed), and is covered by regression tests that build their
fixture checkout with `CLAUDE.md` as the 9-byte git placeholder measured above -
but the `pwsh` run on Windows hardware did not happen. Sections 6.1 to 6.4 were
executed on the laptop; this one was not.

What died, in the order it happened, at 12:57-13:16 IST:

```
$ ssh -p 2222 ... admin@localhost 'echo alive'
Connection timed out during banner exchange          # forwarder up, laptop end gone

$ ss -ltn 'sport = :2222'
LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*                # still listening

... 19 minutes of retries at 30s ...

$ ssh -p 2222 ... admin@localhost 'echo alive'
ssh: connect to host localhost port 2222: Connection refused

$ ss -ltn 'sport = :2222'
(nothing)                                            # the forwarder itself is gone
```

This is the same progression section 0 records from an earlier task. Restoring
it needs the port forward re-established from the laptop end; nothing on this
side can do it.

**What to run when the laptop is back**, against this branch:

```powershell
# 1. a fresh clone, so CLAUDE.md is the git placeholder a real Windows clone has
git clone -b fm/fmwin-bootstrap <bundle-or-remote> C:\Users\ADMIN\fmwin6
Get-Item C:\Users\ADMIN\fmwin6\CLAUDE.md | Select-Object Length   # expect 9

# 2. setup naming NO home
pwsh -NoProfile -File C:\Users\ADMIN\fmwin6\bin\fm-setup.ps1 -SkipProfile

# 3. the one directory must now hold all of these
#    AGENTS.md CLAUDE.md .claude\settings.json config data projects state
#    and CLAUDE.md must no longer be 9 bytes
# 4. fm-home.ps1 must print the checkout as Home
# 5. fm-doctor.ps1 must print [ok] start Claude in - C:\Users\ADMIN\fmwin6
# 6. setup with -FirstmateHome elsewhere must leave a CLAUDE.md in THAT home
#    whose first line is the STOP, naming the checkout
# 7. deleting that CLAUDE.md must make fm-doctor.ps1 report
#    [missing] start Claude in ... and exit 1
```

`C:\Users\ADMIN\verify2.ps1` on the laptop already automates exactly this.

Paste its output here, replacing this whole block, when the run happens:

```
WINDOWS_SPLIT_PLACEHOLDER
```

### 6.6 What section 6 does NOT prove

It does not make the rest of this document Windows-proven. Dispatching a real
worker, stopping a real agent and teardown past its refusal were not run here
either - they are gated for the same reasons sections 3 and 5 record. What is
now proven on Windows is the install, the home resolution, all 23 entry points
in a shell with no profile, and the suite that guards them - the suite at the
revision current when it ran, which is one test fix behind the branch. The
checkout/home layout of 6.5 is NOT among them.

---

---

## 7. The Claude hook transport and the cd guard, on the captain's laptop - `PROVEN (Windows 11)`

Executed on the laptop at `C:\Users\ADMIN\firstmate-win` (checkout and home are
the same directory), PowerShell 7.6.4, Pester 6.1, Claude Code **2.1.228**, with
the branch checked out and `.claude/settings.json` regenerated from
`Get-FmClaudeHookSettings`.

### 7.0 The reported symptom was not this hook - `PROVEN (Windows 11)`

The brief's premise was that `bin/fm-claude-hook.ps1` denied every tool call.
It does not, and the laptop says what did. The captain's own session transcript,
`~/.claude/projects/C--Users-ADMIN-firstmate-win/3a278456-....jsonl`:

```
Error: Permission to use PowerShell has been denied because Claude Code is
running in don't ask mode.
Error: Permission to use Bash has been denied because Claude Code is running
in don't ask mode.
```

and that session's own reply, which is what the captain relayed:

```
I can't run anything - both PowerShell and Bash are blocked in this session
("don't ask" permission mode), so there's no way for me to execute the Pester
suite.
```

`C:\Users\ADMIN\.claude\settings.json` carries
`"permissions": { ..., "defaultMode": "dontAsk" }`. That mode denies every tool
call not on the explicit allow-list without prompting, and leaves file reads and
writes alone - exactly the observed split. **No firstmate change fixes it**; it
is a setting in the captain's own Claude configuration. It is recorded here so
the next investigation does not start from the same wrong place.

### 7.1 How Claude Code invokes a PowerShell hook - `PROVEN (Windows 11)`

Measured by registering an instrumented hook in a throwaway project and driving a
real `claude` session at it. The hook recorded its own and its parent's command
line:

```
selfCommandLine="C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile
    -NonInteractive -ExecutionPolicy Bypass
    -Command "& \"$env:CLAUDE_PROJECT_DIR/probe-hook.ps1\" -Check bashprobe"
parentCommandLine="C:\Users\ADMIN\.local\bin\claude.exe" -p ...
pipelineObjectCount=0
IsInputRedirected=True
consoleInReadToEnd=[{"session_id":"784b2cf4-...","cwd":"C:\\Users\\ADMIN\\fmprobe",
  "hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":"echo probe-marker-9931",...},...}]
```

So: `-Command`, payload on raw stdin, nothing on the script's pipeline. That one
capture settles both transport questions below.

### 7.2 Every hook, every transport, realistic payload - `PROVEN (Windows 11)`

```
--- transport: Command (Claude Code's own shape) ---
  PreToolUse arm       exit=0 stdout=empty binding=ok
  PreToolUse cd        exit=0 stdout=empty binding=ok
  PreToolUse subagent  exit=0 stdout=empty binding=ok
  SessionStart         exit=0 stdout=6411b binding=ok
  Stop turnend-guard   exit=0 stdout=empty binding=ok
  Stop autoarm         exit=0 stdout=empty binding=ok
--- transport: Pipeline (the shape that used to be a binding error) ---
  PreToolUse arm       exit=0 stdout=empty binding=ok
  PreToolUse cd        exit=0 stdout=empty binding=ok
  PreToolUse subagent  exit=0 stdout=empty binding=ok
  SessionStart         exit=0 stdout=6411b binding=ok
  Stop turnend-guard   exit=0 stdout=empty binding=ok
  Stop autoarm         exit=0 stdout=empty binding=ok
```

`binding=ok` means the stderr carried no "cannot be bound to any parameters".
`SessionStart` returning 6411 bytes of digest is the payload having been read.

### 7.3 The exit code, which is where the guard surface was actually lost - `PROVEN (Windows 11)`

```
pwsh -Command 'exit 2'                 -> 2
pwsh -Command '& <hook>'   (old form)  -> 1   <- a deny arriving as a non-blocking error
pwsh -Command '& <hook>; exit $LASTEXITCODE'  -> 2   <- Claude blocks
```

Measured on the laptop, against the real hook, with a real deny payload. The old
form is what every installed `.claude/settings.json` contained, so every
PreToolUse deny, every Stop block, and every `asyncRewake` rewake was computed
correctly and then discarded.

### 7.4 The cd guard denying and allowing - `PROVEN (Windows 11)`

```
DENY case  'cd projects/acme && git status':
  exit=2                       (2 = Claude blocks the tool call)
  stdout=[]                    (must be empty on a deny)
  stderr={"hookSpecificOutput":{"hookEventName":"PreToolUse",
          "permissionDecision":"deny"},
          "systemMessage":"[persistent-cd] a persistent top-level directory
          change in the primary firstmate checkout is blocked; ..."}
ALLOW case 'git status':
  exit=0   stdout=[]   stderr=[]
```

and through the policy owner in process, in the real checkout:

```
  cd projects/acme                              DENY [persistent-cd]
  pushd x                                       DENY [persistent-cd]
  (cd x && y)                                   allow
  cd x &                                        allow
  cd x | cat                                    allow
  git -C x status                               allow
  echo "cd x"                                   allow
  sudo cd x                                     allow
  command -v cd                                 allow
  CD x                                          allow
  pwsh -NoProfile -Command "Invoke-Pester -Path ./tests"   allow
  cd projects/acme in a LINKED WORKTREE       -> allow (correct - inert)
```

That last line is the one that keeps every crewmate and scout task worktree
working: a worker there cds freely and must never be denied.

### 7.5 The acceptance test: a real Claude session in the captain's checkout - `PROVEN (Windows 11)`

`claude` run in `C:\Users\ADMIN\firstmate-win` with all six firstmate hooks live
in `.claude/settings.json`. This is the captain's own scenario.

**It can execute a shell command** - the thing the reported outage was about:

```
=== A. a real claude session must be able to EXECUTE a shell command ===
Output:

```
acceptance-marker-5512
```
```

**And the guard actually blocks**, which is the stronger half. Asked to run
`cd projects && pwd`, the session reported:

```
The command was blocked - it never ran. The cd guard hook
(`bin/fm-claude-hook.ps1 -Event PreToolUse -Check cd`) returned a `deny`
decision. Exact message:

> [persistent-cd] a persistent top-level directory change in the primary
> firstmate checkout is blocked; it would move the shell out of the home so a
> later firstmate-owned command runs inside a project clone. ...

So no `pwd` output was produced.
```

That is the whole chain, end to end, in the real product: Claude Code fires the
hook, the hook reads its payload off stdin, the classifier tokenizes the command,
the policy denies, the exit code survives `pwsh -Command`, and Claude blocks the
tool call and shows the reason. Before this change the same command ran, because
the deny arrived as exit 1 and was discarded.

### 7.6 A test that passed every assertion and still failed - observation `PROVEN (Windows 11)`, fix `PROVEN (pwsh/Linux)` only

The same acceptance test asked the session to run `tests/FmCdGuard.Tests.ps1` and
print Pester's `Result`. It printed:

```
RESULT=Failed TOTAL=73 PASSED=73 FAILED=0
```

Every assertion passed and the CONTAINER failed - Pester's git-fixture
`TestDrive` cleanup, against `.git/objects` files that Windows creates read-only
plus a linked worktree's registration in its parent repo. Every check used on
this port reads the passed/failed counts, and the counts call that a clean run.
Fixed by tearing the fixtures down explicitly in `AfterAll`
(`git worktree remove --force`, prune, clear the read-only bit), and the
suite-reporting one-liner now prints `Result` as well as the counts.

**The fix is NOT verified on Windows.** The tunnel dropped before it could be
re-run there, and the failure it addresses only appears on Windows - so what is
proven is that the fixed file reports `RESULT=Passed` on Linux, and that the
whole Linux suite reports `RESULT=Passed` with no container error anywhere. A
Windows re-run of `tests/FmCdGuard.Tests.ps1` reporting `RESULT=Passed` is the
outstanding check.

### 7.7 Suite and analyzer numbers

| Run | Where | Result |
| --- | --- | --- |
| `Invoke-Pester -Path ./tests` | Linux, PowerShell 7.6.4, Pester 6.1 | `RESULT=Passed TOTAL=1413 PASSED=1408 FAILED=0 SKIPPED=5` |
| `Invoke-Pester -Path ./tests` | Windows 11 laptop, PowerShell 7.6.4, Pester 6.1 | `TOTAL=1413 PASSED=1391 FAILED=0 SKIPPED=22` |
| `tests/FmAnalyzer.Tests.ps1` | Windows 11 laptop | `TOTAL=12 PASSED=12 FAILED=0 SKIPPED=0` |
| `Invoke-ScriptAnalyzer -Path . -Recurse` | Linux | CLEAN at every severity |

The Windows skip count is higher because platform-conditional suites skip there
(POSIX-only lock semantics, tasks-axi differential parity, the CI-log reconciler).
Six of those skips were the **analyzer bar itself**: PSScriptAnalyzer was not
installed on the laptop, so the repo-wide sweep silently skipped rather than ran.
It is installed now (1.25.0, `CurrentUser` scope) and the bar passes there - the
fourth row above. A skipped bar reads exactly like a met bar in a summary line,
which is the same lesson as 7.6.

**One honest boundary, stated exactly.** Sections 7.1-7.5 and the first three
rows of the 7.7 table were executed on the laptop against an earlier revision of
this same branch. Everything added to the branch after that run is confined to
`tests/FmCdGuard.Tests.ps1` and `docs/`: **no file under `module/` or `bin/`
changed**, so the product code that ships is byte-identical to the code those
sections exercised, and every hook and guard behaviour recorded above is proven
for it.

What is NOT proven on Windows, and must not be read as if it were:

- the 7.6 fixture-teardown fix, and therefore whether
  `tests/FmCdGuard.Tests.ps1` reports `RESULT=Passed` on Windows. Proven on
  Linux only. The Windows run in the 7.7 table predates that fix, and reported
  its counts (`FAILED=0`) rather than its `Result`, so it neither confirms nor
  denies the container-level failure.
- whether the FULL Windows suite reports `RESULT=Passed` rather than merely
  `FAILED=0`. Only the counts were captured there. The full Linux suite does
  report `RESULT=Passed` with no container error in any file.

Nothing else in section 7 depends on either.

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

**Superseded in part by section 6** - the install area, the home resolution and
every entry point have since been run on the laptop. What follows was true of
the task that wrote it.

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

### Entry-point bootstrap task, on `fm/fmwin-bootstrap` over `c8fa82c`

```
$ pwsh -NoProfile -Command 'Invoke-Pester -Path ./tests/'      # Linux, PowerShell 7.6.4
RESULT total=1323 passed=1318 failed=0 skipped=5 notrun=0
```

The 5 skips are the Windows-only gates: three Win32 job-object custody tests,
the sharing-violation retry test, and the exclusive-open git-lock probe.

A note on how those numbers were reached, because it is the point of running the
whole directory. Three failures appeared in the full run that **all four
affected files passed in isolation**: the new `checkout memory` step reporting
`already` against a checkout that already exists, a doctor test whose fixture
checkout had no memory files, and a by-name call passing `-Confirm:$false` to an
owner that does not declare it - the cross-area binding hazard `AGENTS.md`
describes, caught by the shared assembly suite rather than by the author.

Earlier areas' numbers, kept for comparison:

```
Tests Passed: 902, Failed: 0, Skipped: 5      # install area, after its rebase
```

The install area contributed 47 tests in `tests/FmInstall.Tests.ps1` and the
merged `tests/FmModuleAssembly.Tests.ps1`.

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
