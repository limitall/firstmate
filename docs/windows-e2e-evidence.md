# End-to-end evidence

What was actually executed, with the real output, and what was not.

**Sections 10 to 13 are the current headline.** The five acceptance steps -
a session that takes the lock, an emitted supervision protocol, a real worker
dispatched into an isolated worktree, its state read back, and a cleanup that
refuses to discard unlanded work - were all executed on the captain's laptop and
all pass. Sections 11 to 13 record the two defects that run exposed, and three
findings that are environment rather than code. Where sections 2 to 5 say a
session is read-only or a worker cannot be dispatched, section 10 supersedes
them.

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

**Section 7 is the same shape again.** The identity task had the link for one
window and lost it for the rest.

- **7.1 to 7.5 were executed on the laptop**, against a fresh clone: the
  9-byte `CLAUDE.md` and 17-byte `.claude/skills` a Windows clone actually
  produces, the doctor reporting both `[missing]` and exiting 1, setup repairing
  both, all 19 skills reachable afterwards, and the negative control putting the
  failure back.
- **7.6 is PARTIAL** - 9 of 33 test files ran there before the link died, which
  includes this area's own suite and the repo-wide analyzer sweep, and does not
  include the rest.
- **The whole-suite Windows re-run is still outstanding**, and 7.6 says so and
  gives the command. The complete suite numbers in this file are Linux.

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

---

## 8. The instruction surface, on the captain's Windows 11 laptop

**Read the tag per subsection, not per section.** 8.1 to 8.5 are
`PROVEN (Windows 11)`: the failure, the doctor's verdict either side of setup,
the repair, the loaded surface, and the negative control all executed on the
laptop with the output below. 8.6 is **partial** - the suite run there covered 9
of 33 files before the link died. 8.7 lists what section 8 does not prove at all.

The identity area. Its whole subject is a failure that produces **no error**: a
checkout where every command works and the session is not firstmate. So the proof
had to start from a **real clone**, because the two things that break are the two
committed symlinks, and a copied directory would have proven nothing.

Method: `git bundle` of the branch, scp to `C:\Users\ADMIN`, `git clone` from the
bundle on the laptop, then one `.ps1` run with `pwsh -NoProfile -File`. Nothing
outside `C:\Users\ADMIN`.

```
pwsh    : 7.6.4
os      : Microsoft Windows NT 10.0.26200.0
git     : git version 2.49.0.windows.1
symlinks: core.symlinks=false
pester  : 6.1.0
herdr   : 0.7.5-preview.2026-07-21
claude  : 2.1.228
```

### 8.1 The failure reproduces, exactly as designed for

```
=== STEP 1 - what a Windows clone actually did to the two committed symlinks ===
CLAUDE.md : file, 9 bytes
         content: 'AGENTS.md'
.claude\skills : file, 17 bytes
         content: '../.agents/skills'
```

Not imagined, not inferred from `core.symlinks=false`: measured on the clone. A
session started there reads one filename as its operating contract and finds no
skills directory at all.

### 8.2 The doctor reports it, before setup

```
instructions:
  [ok]      operating contract - C:\Users\ADMIN\fmwin-identity\AGENTS.md (49160 bytes)
  [missing] contract for Claude - ...\CLAUDE.md is the text git leaves for a symlink it could not create, not the instructions; a session here comes up with one filename and no contract
              fix: bin/fm-setup.ps1
  [ok]      skills - 19 in C:\Users\ADMIN\fmwin-identity\.agents\skills (5 captain-invocable)
  [missing] skills for Claude - ...\.claude\skills is the text git leaves for a symlink it could not create, so a session here loads ZERO skills while every command still works
              fix: bin/fm-setup.ps1

unhealthy: 6 missing, 3 warning(s).
exit: 1
```

This is the precise shape of the bug and the reason the group has four checks
rather than two: the tree and the contract are **fine**, and both mirrors are
broken, so a session gets neither. A check that only asked "does AGENTS.md exist"
would have passed here, and so would one that only counted skills.

### 8.3 Setup repairs both

```
  [updated] checkout memory - symlinked: CLAUDE.md -> AGENTS.md in C:\Users\ADMIN\fmwin-identity (it was a symlink git checked out as text)
  [updated] skills link - C:\Users\ADMIN\fmwin-identity\.claude\skills symlinked to C:\Users\ADMIN\fmwin-identity\.agents\skills
```

```
=== STEP 4 - the two links, after setup ===
CLAUDE.md : link -> AGENTS.md
.claude\skills : link -> ..\.agents\skills

CLAUDE.md first 5 lines - this is what a session actually reads:
  | # Firstmate
  |
  | You are the first mate.
  | The user is the captain.
  | This file is your entire job description.

skills reachable at .claude\skills:
  afk  ahoy  ask-user-authority  bearings  bootstrap-diagnostics
  decision-hold-lifecycle  diagnostic-reasoning  firstmate-codexapp
  firstmate-coding-guidelines  firstmate-orca  fmx-respond  harness-adapters
  process-event-sources  project-management  quota-array-dispatch
  secondmate-provisioning  stow  stuck-crewmate-recovery  updatefirstmate
```

That host allows symlink creation, so the Auto ladder took its first rung both
times and reported `symlinked` honestly. **The junction rung was therefore never
reached and remains unverified anywhere** - see 7.6.

Doctor after setup: all four `instructions` checks `[ok]`,
`healthy: nothing is missing. 2 warning(s)`, `exit: 0`. The two remaining
warnings are the profile block and `bin/` on `PATH`, both expected from
`-SkipProfile`.

### 8.4 The loaded instruction surface, as a session sees it

```
instruction surface: C:\Users\ADMIN\fmwin-identity

  operating contract  present - ...\AGENTS.md
  for Claude          link - ...\CLAUDE.md
  skills              19 - ...\.agents\skills
  for Claude          symlink - ...\.claude\skills

  / afk                         Away-mode supervision - NOT AVAILABLE on this Windows port. ...
  / ahoy                        Recap visible session events and guide the captain through ...
    ask-user-authority          Agent-only decision procedure for ask-user findings and ...
  / bearings                    Generate a "pick up where I left off" fleet digest ...
    ...
    firstmate-orca              The Orca runtime backend - NOT AVAILABLE on this Windows port. ...
    fmx-respond                 Relay public-mention handling - NOT AVAILABLE on this Windows port. ...
    process-event-sources       Registered process-to-event sources - NOT AVAILABLE on this Windows port. ...
  / stow                        Sweep the current session for uncaptured durable knowledge ...
  / updatefirstmate             Self-update a running firstmate to the latest from origin. ...
```

`/` marks a captain-invocable skill. Every not-ported capability names itself as
absent **in the description**, which is the line the model matches on - so the gap
is visible without loading anything.

### 8.5 Negative control, and repair again

Replacing `.claude/skills` with the placeholder put the doctor straight back:

```
  [missing] skills for Claude - ...\.claude\skills is the text git leaves for a symlink it could not create, so a session here loads ZERO skills while every command still works
unhealthy: 1 missing, 2 warning(s).
exit: 1  (must be 1)
```

A second `bin/fm-setup.ps1` reported `[updated] skills link` and `[already]` for
every other step, and the doctor returned to `exit: 0`. Idempotent, and the repair
is not a one-shot.

### 8.6 The suite on Windows - partial, and said so

The same run went on to the full Pester suite in that clone. **The tunnel died
partway through.** This is exactly what completed - 9 of 33 files, 375 tests,
0 failures - and no more:

```
[+] tests\FmAgentsMemory.Tests.ps1     9.43s   (36 tests)
[+] tests\FmAnalyzer.Tests.ps1       106.14s   (12 tests)
[+] tests\FmBackendHerdr.Tests.ps1     8.28s   (80 tests)
[+] tests\FmBacklog.Tests.ps1         28.65s   (87 tests)
[+] tests\FmBootstrap.Tests.ps1       16.80s   (34 tests)
[+] tests\FmBounded.Tests.ps1         39.11s   (19 tests)
[+] tests\FmBrief.Tests.ps1            3.32s   (22 tests)
[+] tests\FmClassify.Tests.ps1         6.03s   (50 tests)
[+] tests\FmContract.Tests.ps1        11.00s   (35 tests)
```

Two of those matter for this area specifically. `FmContract.Tests.ps1` is this
area's own suite and passed 35/35 on Windows, including every rung of the repair
ladder it can reach there and every assertion about the real checkout's surface.
`FmAnalyzer.Tests.ps1` is the repo-wide PSScriptAnalyzer sweep, so **zero findings
at every severity is Windows-proven** for this branch's code.

The other 24 files were not reached. The clone this ran against also predates the
two test-fixture fixes made afterwards (`FmEntryPoint`, `FmInstall`) - neither of
which is among the 9 above, so no result here is affected by them, but neither is
either fix Windows-proven.

Retries to restart the run over the next hour found the forwarder refusing
connections. **Nothing here should be read as "the whole suite is green on
Windows for this branch."** The complete run is the Linux one under "Suite and
analyzer numbers"; the Windows run is partial by exactly this much.

**Outstanding, for whoever has the link next.** The whole-suite Windows re-run is
the one thing this area still owes, and it is one command in a fresh clone:

```powershell
git clone -b <branch> <source> C:\Users\ADMIN\fmwin-suite
C:\Users\ADMIN\fmwin-suite\bin\fm-setup.ps1 -SkipProfile
Invoke-Pester -Path C:\Users\ADMIN\fmwin-suite\tests
```

Expect the same 5 skips as Linux to become real tests there - the three
job-object custody tests, the sharing-violation retry, and the exclusive-open
git-lock probe are Windows-gated, so a Windows run should report **more** passes
than the Linux total, not the same.

### 8.7 What section 8 does NOT prove

- **The junction rung.** The laptop allows symlinks, so the ladder's second rung
  never ran. It is reachable only through `-Strategy Junction`, which is
  Windows-only, so it has executed nowhere. Failure is safe: the ladder falls
  through to the copy, which the suite proves end to end on both platforms.
- **A real Claude session loading a skill through a COPIED `.claude/skills`.**
  Skill discovery scans the filesystem, so a copy should be indistinguishable
  from a link - reasoned, not observed. It matters on a machine without Developer
  Mode, where the copy is the rung that lands.
- **The captain's own observation** that a session there behaves as firstmate.
  That is the acceptance test and it belongs to the captain, not to a check. What
  8.1 to 8.5 prove is that the instructions and the skills are *present and
  reachable* - the structural cause of the original complaint. A live `claude`
  session was not started in that directory as part of *this* run, because a
  separate worker was still fixing the Claude hooks. Section 9 closes that gap:
  the hook fix landed, and the session was run.

---

## 9. A real `claude` session in the captain's checkout, on the merged tree - `PROVEN (Windows 11)`

Executed after `fm/fmwin-hookstdin` merged, on the rebased branch (`d3f12a4`,
section 7's hook and cd-guard work plus section 8's identity work in one tree),
at `C:\Users\ADMIN\firstmate-win`. PowerShell 7.6.4, Pester 6.1.0,
PSScriptAnalyzer 1.25.0, git 2.49.0.windows.1, Claude Code 2.1.228,
herdr 0.7.5-preview.

### 9.1 The Windows placeholder failure, reproduced once more by an ordinary checkout - `PROVEN (Windows 11)`

The branch arrived by `git bundle` into the existing clone and was checked out.
No fixture, no staging - just `git checkout`:

```
AGENTS.md          EXISTS  len=50301 attrs=Archive
CLAUDE.md          EXISTS  len=0     attrs=Archive, ReparsePoint
CONTRIBUTING.md    EXISTS  len=21171 attrs=Archive
.agents\skills     EXISTS  dir       attrs=Directory
.claude\skills     EXISTS  len=17    attrs=Archive        <- the placeholder
```

`.claude/skills` is new to this checkout, so git wrote the 17-byte link text
instead of a symlink and a session there would have loaded **zero skills** while
every command still worked. `CLAUDE.md` already existed as a real reparse point
from an earlier install, so it survived - which is the honest reason only one of
the two placeholders appears here.

### 9.2 The doctor names it, and exits non-zero - `PROVEN (Windows 11)`

```
instructions:
  [ok]      operating contract - C:\Users\ADMIN\firstmate-win\AGENTS.md (50301 bytes)
  [ok]      contract for Claude - C:\Users\ADMIN\firstmate-win\CLAUDE.md is a link to AGENTS.md
  [ok]      skills - 19 in C:\Users\ADMIN\firstmate-win\.agents\skills (5 captain-invocable)
  [missing] skills for Claude - C:\Users\ADMIN\firstmate-win\.claude\skills is the text git
            leaves for a symlink it could not create, so a session here loads ZERO skills
            while every command still works
              fix: bin/fm-setup.ps1

unhealthy: 1 missing, 1 warning(s).
DOCTOR EXIT = 1
```

`[missing]`, not `[warn]`, and exit 1 - a checkout with every command and no
first mate is broken, not merely inelegant.

### 9.3 Setup repairs it to a real symlink - `PROVEN (Windows 11)`

```
SETUP EXIT = 0
.claude\skills  attrs=Directory, ReparsePoint  linkType=SymbolicLink  target=..\.agents\skills
skills reachable THROUGH .claude\skills: count=19
  afk, ahoy, ask-user-authority, bearings, bootstrap-diagnostics,
  decision-hold-lifecycle, diagnostic-reasoning, firstmate-codexapp,
  firstmate-coding-guidelines, firstmate-orca, fmx-respond, harness-adapters,
  process-event-sources, project-management, quota-array-dispatch,
  secondmate-provisioning, stow, stuck-crewmate-recovery, updatefirstmate

instructions:  all four [ok]
healthy: nothing is missing.
DOCTOR EXIT = 0
```

The first rung of the ladder landed, so the junction and copy rungs still have
not executed on Windows (8.7 stands).

### 9.4 The acceptance test: the session reads the contract and answers as the first mate - `PROVEN (Windows 11)`

**How this is tested matters.** The captain's own
`C:\Users\ADMIN\.claude\settings.json` carries `permissions.defaultMode=dontAsk`,
which denies tool calls that are not explicitly allow-listed (section 7.0). That
setting is outside this repo and was **not changed**. It also does not need to
be: whether the operating contract and the skills reach the model is a question
about the *loaded instruction surface*, which requires no tool call at all. Each
prompt below therefore forbids tool use, so what is being measured is our
instruction surface and not the captain's permission mode.

`claude -p` run in `C:\Users\ADMIN\firstmate-win`, verbatim reply:

```
> Answer from your loaded instructions only. Do not use any tool.
> 1. Who are you, and who am I to you? Quote the first three lines of your job
>    description verbatim.
> 2. State hard rule 1 in full, verbatim.
> 3. Which file are these instructions in?

Captain, here are your answers.

**1. Who we are.** I'm your first mate - your single point of contact for all
software work across your projects; you're the captain. The first three lines
of my job description:

> You are the first mate.
> The user is the captain.
> This file is your entire job description.

**2. Hard rule 1, verbatim:**

> 1. **Never write to a project.**
>    Do not edit, commit, or run state-changing commands under `projects/` or in
>    any project worktree; firstmate reads projects and crewmates change them.
>    [...full rule reproduced correctly...]

**3. The file.** `C:\Users\ADMIN\firstmate-win\CLAUDE.md` - which is really
`AGENTS.md`; `CLAUDE.md` is a link to it.

EXIT = 0
```

Unprompted address as "Captain", the identity, the hard rule quoted from the
file, and the link relationship - from a session given nothing but the checkout.
This is the observation the captain made in the negative, now made in the
positive.

### 9.5 All 19 skills are visible to that session - `PROVEN (Windows 11)`

Asked to list every skill available to it, again with no tool use, the session
returned all nineteen with their triggers, grouped, and closed with:

```
**Total: 19.**

Five of them say this port does not support their subject: **afk**,
**fmx-respond**, **process-event-sources**, **firstmate-orca**, and
**firstmate-codexapp**.
```

That is the gap-recording group working exactly as intended: the absent
capabilities are *visible to the model without loading anything*, because the
description is what it matches on.

### 9.6 The session found a defect in the contract that every test had passed - `PROVEN (Windows 11)`

It also volunteered this, unasked:

```
One correction worth flagging, captain: section 13 of the operating contract
calls that last group "four more skills" but then names five. The count is
wrong in the file, not in the list above.
```

It was right. Section 13 read "Four more skills exist only to record a
capability this port does not have" and then named five, because `afk` is
counted in the captain-invocable group as well and the sentence was written
before it was. **Nothing failed.** A miscount in an always-loaded instruction
raises no error, breaks no command, and passes every existing check - the only
reader that had ever verified it was the model, on the laptop, in the product.

Fixed in section 13, which now states five and says which one is also
captain-invocable. `tests/FmContract.Tests.ps1` gained
`counts the gap-recording skills correctly where section 13 states how many
there are`: it parses the number word, counts the names beside it, and requires
that set to equal the skills whose own description declares `NOT AVAILABLE`, so
the fact cannot drift apart from itself again. Negative control - restoring
"Four" - fails it with:

```
Expected 5, because the contract says 4 and names 5: afk, fmx-respond,
process-event-sources, firstmate-orca, firstmate-codexapp, but got 4.
```

### 9.7 An instruction the PRODUCT prints that does not work - `FOUND, NOT FIXED (cross-area)`

Found while checking that no rule in the ported contract names machinery this
port lacks. This one is the same defect class in the opposite direction: the
contract correctly does **not** mention it, and the running code does.

`module/Firstmate/Public/FmWake.ps1` ends its open-decisions block with

```
OPEN DECISIONS: close one by answering it: bin/fm-send.ps1 <task> -ResolveKey <key> '<answer>'
```

`bin/fm-send.ps1` has no `-ResolveKey` parameter. Its `-Key` is a *keyboard* key
(`-Key Escape`), an unrelated thing, and nothing in `module/` declares
`ResolveKey` at all.

It does not fail loudly. The script's last parameter is
`[Parameter(ValueFromRemainingArguments)][string[]]$Message`, which swallows the
unmatched switch and its value:

```
Target  = sometask
Key     = ''
Message = -ResolveKey | somekey | the captain says use option B
TEXT THAT WOULD BE TYPED INTO THE WORKER: '-ResolveKey somekey the captain says use option B'
```

So following firstmate's own printed instruction types the literal text
`-ResolveKey somekey <answer>` into the worker's pane, exits 0, and leaves the
decision open - while the comment above that line in `FmWake.ps1` states the
opposite guarantee, that "closure never depends on the busy worker writing a
matching resolved line". The Linux contract's `AGENTS.md` line 294 is the rule
this hint implements, and it is the one rule this port's `AGENTS.md` section 7
deliberately omits, precisely because the parameter is absent here.

**Not fixed by this branch, on purpose.** The hint belongs to the wake area and
the parameter to the send area, both of which are landing tonight; implementing
a new cross-area parameter here would collide with their owners and would be the
second copy of a rule that must have one owner. Either half closes it:

- add `-ResolveKey <key>` to `bin/fm-send.ps1` so a confirmed delivery also
  appends a `resolved: ... [key=<key>]` line to `state/<target>.status`, which
  `Private/FmClassify.ps1` already recognises - then add the rule back to
  `AGENTS.md` section 7 as the Linux contract states it; **or**
- stop printing the hint until that exists.

The first is the Linux behaviour and the better answer. Until one lands, the
port's contract is correct as written and the printed hint is not.

### 9.8 Suite numbers, both platforms, on the exact committed tree

Both runs are of tree `1d5c86f`, which is this branch's final content except for
**this document** - the numbers below could not be written down until after they
existed, and no test reads this file. Every `.ps1`, `.psm1`, `.psd1`, `AGENTS.md`
and `SKILL.md` that ships is byte-identical to what these two runs executed.
`Result` is reported alongside the counts, because 7.6 is the file that proves a
container can fail while every count says clean.

| Run | Where | Result |
| --- | --- | --- |
| `Invoke-Pester -Path ./tests` | Linux, PowerShell 7.6.4, Pester 6.1 | `RESULT=Passed TOTAL=1452 PASSED=1447 FAILED=0 SKIPPED=5` |
| `Invoke-Pester -Path ./tests` | Windows 11 laptop, PowerShell 7.6.4, Pester 6.1.0 | `RESULT=Passed TOTAL=1452 PASSED=1436 FAILED=0 SKIPPED=16` |

Same total on both, no failure and no container error on either. The Windows
skip count is higher for the reasons 7.7 gives - platform-conditional suites -
and lower than the 22 recorded there because PSScriptAnalyzer is now installed
on the laptop, so `tests/FmAnalyzer.Tests.ps1` **runs** rather than skipping.
The repo-wide zero-findings analyzer bar is therefore Windows-proven for this
tree, not assumed.

**This closes two items section 7 left open**, and it is worth being explicit
because they were recorded as outstanding by the worker who found them:

- *"whether the FULL Windows suite reports `RESULT=Passed` rather than merely
  `FAILED=0`"* - it does, above.
- *"A Windows re-run of `tests/FmCdGuard.Tests.ps1` reporting `RESULT=Passed` is
  the outstanding check"* - the whole-suite `RESULT=Passed` includes it, so the
  7.6 fixture-teardown fix is now Windows-proven rather than Linux-only.

An earlier whole-suite Windows run on this branch, at `d3f12a4`, reported
`RESULT=Passed TOTAL=1450 PASSED=1434 FAILED=0 SKIPPED=16`. The two extra tests
are the 9.6 ones; `git diff d3f12a4..1d5c86f -- module/ bin/` is empty, so no
product code differs between the two runs.

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
| Dispatching a real worker | **RESOLVED - see section 10.3**, and the two defects it exposed in section 11 |
| Stopping a real agent | **RESOLVED - see section 10.5** |
| Teardown past the refusal (process custody, returning the worktree) | **RESOLVED** - reached during the section 10 cleanup, with explicit `--approved-by` discard authority |
| A session that is not read-only | **RESOLVED - see section 10.1.** `Invoke-FmLock` has landed over the session-lock machinery that was already there |
| Turn-end supervision | **RESOLVED - see section 10.2.** `Get-FmSupervisionInstructions` has landed, and reports what this build actually has |
| `fm-peek` | not ported |

### Never executed on Windows

**Superseded in part by sections 6 to 9** - the install area, the home
resolution, every entry point (6), the Claude hook transport and the cd guard
(7), the whole instruction surface (8), and a live `claude` session reading the
contract and the skills in the captain's own checkout (9) have since been run on
the laptop, as has the full suite. What follows was true of the task that wrote
it.

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

### Identity task, on `fm/fmwin-identity` over `6ef403d`

```
$ pwsh -NoProfile -Command 'Invoke-Pester -Path ./tests/'      # Linux, PowerShell 7.6.4
RESULT total=1360 passed=1355 failed=0 skipped=5 notrun=0
```

The 5 skips are the same Windows-only gates as every run below: three Win32
job-object custody tests, the sharing-violation retry test, and the
exclusive-open git-lock probe.

This area added `tests/FmContract.Tests.ps1` (35 tests) and two tests to
`tests/FmInstall.Tests.ps1`. PSScriptAnalyzer: **0 findings** across the changed
files, and the repo-wide sweep inside `tests/FmAnalyzer.Tests.ps1` is green on
both platforms - see 7.6 for the Windows half.

Two failures appeared in the full run that neither affected file produced in
isolation, both in fixtures rather than in the new code, and both worth naming
because they are the same class of thing the whole-directory rule exists for:

- `tests/FmEntryPoint.Tests.ps1` builds a fixture checkout by copying a subset of
  the real one, and did not copy `.agents/skills`. The new doctor checks then
  reported that fixture unhealthy - correctly. The fixture now carries the skills
  tree AND a `.claude/skills` in the same broken shape a real Windows clone has,
  which is what it should have had from the start.
- `tests/FmInstall.Tests.ps1`'s "every step reports created on the first run"
  exempted `checkout memory` because that step is about the CHECKOUT rather than
  the fresh home. `skills link` is the same kind of step and needed the same
  exemption; reporting `already` there is the converge rule working.

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

---

## 10. The five acceptance steps, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

Sections 2 to 5 above were written when a session on this port could not take
the lock and no worker could be dispatched. This section is the same five steps
run for real, on the laptop, on `fm/fmwin-dispatchable` over `99a0e96`.

The captain's own checkout at `C:\Users\ADMIN\firstmate-win` was **not
touched**: it had uncommitted work in it from another lane. The branch was
cloned to `C:\Users\ADMIN\fmwin-accept` and set up there with `-SkipProfile`,
so the captain's PowerShell profile and their global Claude settings were left
alone. Everything this run created was removed afterwards.

### 10.1 A session starts and ACQUIRES the lock - not read-only

Run first over SSH, which correctly REFUSED, and that refusal is worth keeping:

```
lock: NOT ACQUIRED - error: cannot locate harness process in ancestry
```

An ssh shell is not a firstmate session. The lock records the harness process,
there is none in that ancestry, and a session that cannot verify ownership must
stay read-only. That is the bash contract, unchanged.

Then run the way the captain runs it - inside a real `claude` session in the
home - and captured from the digest the session itself produced:

```
   6: LOCK
   8: lock acquired: harness pid 28872
  10: BOOTSTRAP
  20: WAKE QUEUE
  24: SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude
  27: - Lock: held by this session; this session owns normal supervision unless away mode says otherwise.
  30: - Automatic re-arm: NOT available in this build; this session keeps the cycle itself.
  31: - Ordinary wake: drain, handle the wake, then start the next FOREGROUND bin/fm-watch.ps1 cycle yourself while supervision is still needed.
  33: Mode: Claude, session-kept FOREGROUND supervision cycle.
  94: NETWORK CHECKS

ASSERT 1 lock acquired      : True
ASSERT 1 not read-only      : True
ASSERT 2 protocol emitted   : True
ASSERT 2 no NOT EMITTED     : True

state/.lock                   = 28872
state/.session-start-complete = 28872
```

`state/.session-start-complete` is written **only** on a locked, non-re-emit
digest, and it carries the pid it read out of `state/.lock`. So the two files
agreeing on `28872` is independent evidence that the session was not read-only,
separate from the digest text.

### 10.2 It emits a supervision protocol

Above: `SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude`, and the
harness detected as `claude` rather than `unknown`. The emitted block reports
the automatic arm as **absent in this build**, because it is, and hands the
session the foreground cycle instead. It is selected from the seams present at
run time, so the day an arm owner lands the block changes with it.

### 10.3 A worker is dispatched into an isolated worktree and shows up alive

```
spawned probe-alive harness=claude kind=ship mode=local-only yolo=off window=default:wB:p2 worktree=C:\Users\ADMIN\.treehouse\probe-ab08a6\1\probe
SPAWN_EXIT=0

worktree = C:\Users\ADMIN\.treehouse\probe-ab08a6\1\probe
project  = C:\Users\ADMIN\fmwin-accept\projects\probe
ASSERT spawn reported success     : True
ASSERT worktree is isolated       : True

--- what the session-start digest now says about this task ---
--- probe-alive ---
endpoint: alive (backend=herdr window=default:wB:p2)
```

And the worker really ran: it read its brief and appended its own status line.

```
probe: alive in /c/Users/ADMIN/.treehouse/probe-ab08a6/1/probe
```

### 10.4 Its state can be read back

Read while the worker was mid-turn:

```
crew state   : state: working | source: pane | harness busy (busy herdr-native)
busy verdict : busy herdr-native
status file  : working: probe holding
```

Before this branch that read was `state: unknown | source: none | no backend
state reader available (backend herdr)` for every task in this build - the
generic window contract the reader binds by name existed nowhere, while every
herdr primitive under it had already landed.

### 10.5 It can be stopped, and cleanup REFUSES to discard uncommitted work

```
Target          : default:wB:p5
Outcome         : stopped
PaneClosed      : False
WorktreeRelease : not-requested
ASSERT the agent is stopped       : True
ASSERT worktree preserved         : True

uncommitted in the worktree: ?? UNLANDED-WORK.txt
REFUSED: worktree C:\Users\ADMIN\.treehouse\probe-ab08a6\4\probe has uncommitted changes.
uncommitted changes present
Commit them (or get the captain's explicit OK to discard, then --force).
TEARDOWN_EXIT=1
ASSERT cleanup REFUSED            : True
ASSERT the work is still there    : True
ASSERT the task record survived   : True

fm-teardown: --force discards work that has not landed, so it requires --approved-by "<who approved it>"
BARE_FORCE_EXIT=2
```

## 11. Two defects only a real dispatch could find - `PROVEN (Windows 11)`

Both were invisible to a green suite, and the second had been corrupting every
brief this port has ever handed a crewmate.

### 11.1 The spawn reported FAILURE for a dispatch that had succeeded

First real spawn:

```
spawned ... window=default:wA:p2 worktree=C:\Users\ADMIN\.treehouse\probe-ab08a6\1\probe
The property 'Message' cannot be found on this object. Verify that the property exists.
exit=1
```

The task record was on disk, the pane existed, the agent was launched - and the
entry point exited 1. `Confirm-FmWorkerWorktree` returns a bool and was called
without discarding it, so `Start-FmWorker` emitted two objects and
`$worker.Message` failed under strict mode on the resulting array.

Every existing test assigned the result to `$null`, so the leak was invisible to
all of them. `tests/FmWorker.Tests.ps1` now asserts the function emits exactly
one object, and that test fails on the unfixed code.

### 11.2 The pane's shell is Windows PowerShell 5.1, and it mangled every brief

A brief whose text contained `pwsh -NoProfile -Command "Start-Sleep -Seconds 75"`
aborted its own launch:

```
PS ...\2\probe> $env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false'; claude --dangerously-skip-permissions ('FIRSTMATE_OP: v1 launch-brief: ' + (Get-Content -Raw -LiteralPath '...\brief.md'))
error: unknown option '-Seconds'
```

Measured, rather than guessed at, in three steps:

1. PowerShell 7 passes that expression to a child as **one** argv element, with
   the newlines and quotes intact - so the construction is right.
2. `claude.exe` does not split a single argument: a payload containing
   `-Seconds`, `--herdr-lab`, or embedded quotes is accepted whole.
3. The pane itself:

```
PS ...> "SHELL=" + $PSVersionTable.PSVersion.ToString() + " HOST=" + $host.Name + " EXE=" + (Get-Process -Id $PID).ProcessName
SHELL=5.1.26100.8115 HOST=ConsoleHost EXE=powershell
```

A herdr pane opens **`powershell.exe` 5.1**, not `pwsh`. 5.1 has no
`$PSNativeCommandArgumentPassing` at all and always applies the legacy
command-line quoting, which does not escape a double quote inside an argument. A
brief is full of quoted commands, so its own quotes ended the argument early and
the next option-shaped token became a flag. A brief without such a token still
arrived silently mangled, which is worse than the loud failure.

The launch now runs under PowerShell 7, whose argument passing is exact. The
only text crossing the 5.1 boundary is the wrapper, which carries no double
quote of its own and still no brief content - the pane reads the brief from disk
itself. With that in place the same brief launched, was read intact, and the
worker ran the exact command it named.

## 12. The 8 red tests that were never regressions - `PROVEN (Windows 11)`

The captain hit eight failures on a stock Windows shell that pass when the same
commit runs elevated:

```
New-Item: A required privilege is not held by the client.
```

Creating a symlink on Windows needs `SeCreateSymbolicLinkPrivilege`, which a
non-elevated shell does not hold unless Developer Mode is on. In every one of
those tests the symlink is a **fixture**, not the thing under test. Eight red
that turn green when run elevated look exactly like a regression, and cost the
captain time to disprove.

`tests/FmSymlink.TestHelpers.ps1` now probes the privilege by trying to create
one, and any test whose fixture needs it reports SKIPPED with the reason and the
fix instead of failing. Nothing whose SUBJECT is symlink handling on a path that
does not need the privilege is skipped: the `CLAUDE.md` placeholder repair, the
hardlink and copy fallbacks, and every refusal path stay live.

The related wording mismatch was the same environment, not a defect either.
`Set-FmAgentsMemory` reports the link kind that is actually on disk - where
symlinks are unavailable the second name is a hardlink or a copy, and calling
that `CLAUDE.md -> AGENTS.md` would claim a link that is not there. The test
asserted one wording regardless; it now expects the message that matches what
the host produced.

**The SSH session used for this run holds the privilege**, so the skip path
itself was exercised on Linux by forcing the probe, not on the laptop. A
non-elevated Windows run is the outstanding confirmation.

## 13. Findings this run produced that are NOT firstmate defects

- **`gh` is absent on the laptop**, so the `direct-PR` path cannot complete
  there. That is an install, not a code defect. `local-only` needs no network
  and was used throughout section 10.
- **A project with no `origin` cannot be leased.** `treehouse get --lease`
  creates its worktree from `refs/remotes/origin/main`, so a repository made by
  `bin/fm-project-create.ps1` - which is deliberately local and makes no network
  call - cannot be dispatched into until it has an origin and an `origin/HEAD`.
  The spawn refuses loudly and records nothing, which is the right direction,
  but the message names treehouse's failure rather than the missing remote.
  Worth a captain-facing improvement; it is treehouse's rule, not firstmate's.

---

## 14. The 40 "regressions" that belonged to the RUNNER, not to either commit - `PROVEN`

This section replaces an earlier one that left the base-vs-branch comparison
open. It is closed now, and the answer was not the one the shape of the evidence
suggested.

### What was measured

Both suites were run back to back in ONE elevated session, from fresh clones at
the exact commits - which is the correct way to compare, because privilege
context changes the result and has to be held constant:

```
BASE   99a0e96  1452 total  1434 passed   2 failed  16 skipped
BRANCH 59d0f8e  1516 total  1458 passed  42 failed  16 skipped
```

The 2 were shared. The other 40 were absent from the baseline and present in the
branch, and they grouped in exactly the areas this branch's by-name binding
sweep had touched:

```
  12  Retry discipline
  12  Harness name matching
   6  Session lock
   5  Stale-holder recovery
   4  Get-FmHarnessAncestry
   1  Test-FmProcessAlive
```

That is a persuasive shape. It is also a coincidence, and worth recording as one:
the areas a sweep touches are the areas with the most module-scope tests, so
"the failures cluster where you worked" was always going to be true here
regardless of cause.

### The actual cause

`Import-Module <path> -Force` replaces only a module already loaded from the
**same path**. Two clones of this repo in one process therefore leave **two**
modules named `Firstmate` loaded:

```powershell
Import-Module C:\Users\ADMIN\pbase\module\Firstmate\Firstmate.psd1   -Force  # 1
Import-Module C:\Users\ADMIN\pbranch\module\Firstmate\Firstmate.psd1 -Force  # 2
```

and Pester then refuses every `InModuleScope Firstmate` block:

```
Multiple script or manifest modules named 'Firstmate' are currently loaded.
Make sure to remove any extra copies of the module from your session before testing.
```

The 40 are **exactly** the suite's 40 `InModuleScope` tests. Counted from the
source before any run: Retry discipline 10 `It`s of which one is a 3-case
`-ForEach` = 12, Harness name matching 2 `It`s that are 6-case `-ForEach`es = 12,
Session lock 6, Stale-holder recovery 5, `Get-FmHarnessAncestry` 4,
`Test-FmProcessAlive` 1. Total 40, and the three files that own them -
`FmIdentity`, `FmLock`, `FmState` - are three of the only four test files that
import the module in-process at all.

### Reproduced independently, on the laptop, elevated

The same pair re-run from the same two clones, in one elevated session
(`CONTEXT elevated=True`), reproduced it exactly:

```
BASE   99a0e96  1452 total  1436 passed   0 failed  16 skipped
BRANCH 59d0f8e  1516 total  1460 passed  40 failed  16 skipped

  12  Retry discipline          6  Session lock          4  Get-FmHarnessAncestry
  12  Harness name matching     5  Stale-holder recovery  1  Test-FmProcessAlive
```

This clone reported 0 baseline failures rather than 2 - the shared pair is a
fresh-clone artifact of a checkout setup has not run in, section 7 - so the
delta measured here is exactly 40, the same 40, in the same six groups.

### The experiment that settles it

Reverse the order. Same two clones, same one process, nothing else changed:

```
ORDER pbase -> pbranch     pbase   modules_loaded_after=1  failed=0
                           pbranch modules_loaded_after=2  failed=40

ORDER pbranch -> pbase     pbranch modules_loaded_after=1  failed=0
                           pbase   modules_loaded_after=2  failed=40
```

Identical six groups, identical counts, on the **base** commit. The 40 belong to
whichever suite runs **second**. Neither commit causes them.

A control that explains why this was never seen before: base against **itself**
- the same path twice - is `failed=0` both times, because `-Force` does replace
a module loaded from the same path. Comparing a commit against itself, or
running one suite alone, cannot expose this. Only a genuine two-clone comparison
can, which is why the first real comparison this port ever ran found it.

### The fix

`tests/FmModule.TestHelpers.ps1` owns a single supported way to load the module:
unload every copy, import this checkout's, assert exactly one is left. The four
suites that reach into module scope use it, and a parsed check in
`FmModuleAssembly.Tests.ps1` keeps any future `InModuleScope` suite on it, so
this cannot come back silently. A second test loads a decoy copy from a temp
directory, imports through the helper, and asserts both that one module is left
and that `InModuleScope` still runs - the failure mode itself, held down.

After the fix, in one process:

```
ORDER pbase -> pfixed      pbase   modules_loaded_after=1  failed=0
                           pfixed  modules_loaded_after=1  failed=0
```

### After the fix, on the laptop

The branch alone, elevated, whole suite - the cleanest single measurement:

```
FIXED 308b9f9  1523 total  1507 passed  0 failed  16 skipped
```

Zero. The 40 are gone.

The paired run at that commit reported 3, and all three were chased rather than
dismissed. `MODULES_LOADED_BEFORE=1` on the second suite confirms it started in
exactly the contaminated condition that used to produce 40, and produced none of
them:

```
BASE  99a0e96  1452 total  1436 passed  0 failed  16 skipped
FIXED 308b9f9  1523 total  1504 passed  3 failed  16 skipped

  this checkout's own instruction surface.is healthy
  this checkout's own instruction surface.keeps the contract reachable under both names it is read by
  One holder, proven with real processes.never lets two processes increment a counter at once
```

- The **instruction-surface pair** checks the checkout it runs in. That clone was
  a plain bundle clone `bin/fm-setup.ps1` had never run in, unlike the two
  comparison clones, which is a difference in clone state and not in code.
  **Recorded weaker than the rest of this file deliberately:** setup was run
  before the failure text was captured, so this is attribution by elimination
  rather than by message.
- The **real-process lock test** spawns three workers and waits on them. Run
  alone on the same machine it passed `47/47` three times consecutively. It
  failed only in second position, after about fifty minutes of continuous load.

Both were re-measured with the clones equalized; the tunnel dropped mid-run, so
that result is NOT recorded here and nothing in this section rests on it.

### A second defect this investigation exposed

Both test helpers this branch added set `Set-StrictMode -Version Latest` at
**file** scope. A dot-source applies that to the scope that dot-sourced it, so
each helper silently turned strict mode ON for whole suites that never asked -
three of the four module-importing suites, and three of the four symlink ones,
set none themselves. It immediately broke an untouched `FmState` assertion,
`(Read-FmStateLines ...).Count`, which is legal without strict mode and throws
with it. That is the same action-at-a-distance class as the by-name bindings
this branch exists to fix. Strict mode now sits inside each helper function.

### What this costs the next person

Nothing, if they use the helper. The rule is one line: **a test that uses
`InModuleScope` imports through `Import-FmTestModule`**, and the suite enforces
it. The deeper rule is the one worth carrying: a green suite proves nothing
about a comparison harness, and a failure that clusters in the area you just
edited is a hypothesis, not a finding.

---

## 15. Two lock-entry-point defects the sweep's own test found - `PROVEN`

The brief's warning was that giving an absent by-name owner a body can satisfy
the name and miss the behaviour. It did, twice, in `bin/fm-lock.ps1` - and the
reason both shipped is simpler than anything subtle: **the entry point had no
test at all.** `grep -rn "fm-lock.ps1" tests/` returned nothing.

### 15.1 `status` swallowed its own output

Without `-PassThru` the command's only product IS the status line. The entry
point wrote `$null = Invoke-FmLock -Status`, so:

```
$ pwsh -File bin/fm-lock.ps1 status        $ bash bin/fm-lock.sh status
EXIT=0                                     lock: free
                                           EXIT=0
```

A status command that reports no status, and exits 0 while doing it.

### 15.2 Acquisition reported read-only on the path that had just succeeded

`-PassThru` returned the human line **and** the result object, so `$result` was
a two-element array and `$result.Acquired` threw under strict mode:

```
ParentContainsErrorRecordException: bin/fm-lock.ps1:47
  47 |  if ($result -and $result.Acquired) { exit 0 }
     |  The property 'Acquired' cannot be found on this object.
EXIT=1
```

Exit 1 means "operate read-only until resolved" - while the lock file the same
run had just written said the session owned it. A session would have believed it
held nothing while holding everything. That is worse than either honest outcome,
and it is the precise failure this whole task exists to end.

Note what this does NOT mean: the digest's lock stage never went through this
entry point, so section 10.1's acquisition stands. The standalone command was
broken; the session path was not.

### The fix and the contract it restores

`-PassThru` returns the object INSTEAD OF the line, never both. The refusal goes
to the error stream either way, because "operate read-only until resolved" is a
diagnostic every caller needs. The entry point prints the line. Output is now
byte-identical to `bin/fm-lock.sh`:

```
free    lock: free
held    lock: held by live harness pid 2586502
stale   lock: stale (pid 2147483600 dead or not a harness)
acquire lock acquired: harness pid 2586502          exit 0
```

Five tests now cover it. The last one asserts the invariant that actually broke -
**the exit code, the printed line and the lock file on disk agree** - without
asserting whether this particular host has a harness in its ancestry, which is
not the point and differs per machine.

---

## 16. The four whole-suite failures that were open, now settled - `PROVEN`

An earlier section left four Linux whole-suite failures unattributed. Both
commits were run to completion and the answer is unambiguous - identical lists:

```
BASE   99a0e96  1452 total  1443 passed  4 failed  5 skipped
BRANCH 59d0f8e  1516 total  1507 passed  4 failed  5 skipped

  the sweep runner itself.gives up after the full attempt budget when every sweep crashes
  the sweep runner itself.recovers when a later attempt completes, and keeps that attempt s findings
  Get-FmTaskStatePath.composes state/<id>.<suffix>
  Reading.returns an empty collection of lines for a missing file
```

Same four, same names, at both commits. They are **pre-existing whole-suite
cross-file interference** and this branch did not introduce them. Each passes
when its own file runs alone, which is the signature of that class and matches
the `FM_BACKEND` leak already recorded further up this file. They remain open as
a separate defect; what is closed is the question of whose they are.

---

## 17. Findings left open for their owners

- **`bin/fm-control.ps1` has no test at all.** Nothing under `tests/` references
  it; `FmLifecycleCli.Tests.ps1` drives `fm-brief.ps1` and its siblings but not
  this one. It is the entry point section 10.5 uses to stop a worker, and the
  two defects in section 15 are exactly what an untested entry point looks like.
  It belongs to the lifecycle area, not this one, so it is reported rather than
  edited here - a second lane rewriting that file would collide.
- **Four whole-suite Linux failures remain** (section 16). Established as
  pre-existing at `99a0e96`, unattributed as to which file leaks into them. One
  of the four - `Get-FmTaskStatePath.composes state/<id>.<suffix>` - is now
  diagnosed and fixed (section 21.8); the other three are not.
- **`gh` is absent on the laptop**, so `direct-PR` cannot complete there. An
  install, not a code defect (section 13).
- **One intermittent lost increment in the lock area** (section 24.4).
  **SETTLED - see section 28.** It was the lock, not the test: reproduced
  deliberately under contention, traced to a stale verdict that named nobody
  breaking a live holder's claim, and fixed.
- **The lock evicted a live holder on a torn identity read** (section 28.4).
  A second, distinct mechanism found while settling the one above: `pid` and
  `pid-identity` were read as separate operations, so the pid-reuse guard could
  compare one holder's pid against another holder's identity and report a live
  holder stale. Traced with the eviction captured.
  **SETTLED - see section 28.7.** The lock record gained a pid-keyed identity
  child, published before the claim and retained while its process lives; every
  file bash reads keeps its bytes.
- **Two whole-suite flakes, attributed but not fixed** (section 28.8).
  `FmWatch`'s terminal wait ends early because a FileSystemWatcher event queued
  by one notifier outlives it and is picked up by the next - reproduced 10 times
  in 40 with no lock code in the path. `FmJobCustody`'s real-custody test found
  its own just-added child missing from the job once, in a file that references
  no lock function and that passes 7 of 7 alone. Both are other areas' files.
- **The SESSION lock reports the same tear** (section 28.7, last subsection).
  `Get-FmSessionLockStatus` reads `state/.lock` and then `state/.lock.identity`,
  and `Request-FmSessionLock` writes them in that order, so a reporter reading
  between those two writes calls a live session's lock stale. Found by reading
  the code while fixing 28.4, not reproduced. Confined to reporting - every
  writer holds `state/.lock.acquire` for both writes - so it is reported rather
  than fixed, because the fix is a second on-disk shape decision on a file whose
  one-line bash contract `docs/foundation.md` states.
- **`tests/FmInstall.Tests.ps1` repairs the checkout it runs in** (section 21.6),
  which dirties a fresh Windows worktree mid-suite and leaves it needing
  `--force` to tear down. The install area's file, so it is reported here.
- **Four Windows-only test failures are open at `2e60e39`** and are nobody's
  regression (18.8 measures them at the base commit): two in
  `tests/FmAnalyzer.Tests.ps1`, where `Invoke-FmAnalyzerSweep`'s own crash and
  recovery cases raise `The property 'Analysed' cannot be found on this
  object`, and one each in `tests/FmPaths.Tests.ps1` (`$id cannot be
  retrieved`) and `tests/FmState.Tests.ps1` (`Count` missing on a read result).
  They belong to the analyzer harness and the foundation area, so they are
  reported here rather than edited by a lane that does not own them. **The
  `FmPaths` one is now closed**: section 21.8 has its cause - Pester reads the
  angle brackets in that test's own title as a `-ForEach` placeholder - and the
  test is renamed. The other three stand.
- **The suite dirties the checkout it runs in.** `tests/FmInstall.Tests.ps1`'s
  "the entry points" block runs `fm-setup.ps1 -RepoRoot $script:RepoRoot`, i.e.
  the real checkout, so setup does its repo-side repairs on the live working
  tree: `CLAUDE.md` becomes a mirror of `AGENTS.md` instead of the tracked
  9-byte placeholder, and `.claude/skills` becomes a real link. `git status` is
  dirty after every full run, and the pollution leaks into the NEXT run -
  `FmContract.Tests.ps1`'s "this checkout's own instruction surface / is healthy"
  then reports `MirrorState` as `conflict` and fails, having passed in the run
  that caused it. That fixture already routes the home pointer somewhere
  disposable for exactly this reason and says so in a comment; the two repairs
  were missed. The fix is to point `-RepoRoot` at a disposable copy - the helper
  already exists as `New-TestCheckout` in `tests/FmEntryPoint.Tests.ps1` and
  would need extracting into a shared `tests/*.TestHelpers.ps1`. It belongs to
  the install area, so it is reported rather than edited here.

  **Restoring it has a trap of its own**, now recorded in `CONTRIBUTING.md`:
  once setup has repaired `.claude/skills` into a real link, `git checkout --
  .claude/skills` deletes the link's TARGET and takes the entire
  `.agents/skills` tree with it. It is recoverable with `git checkout --
  .agents/skills`, but only if you notice. Remove the reparse point first
  (`[System.IO.Directory]::Delete($link, $false)`), then restore.
- **Eight tests require a SET-UP checkout**, not merely a cloned one. Two are
  `FmContract`'s "own instruction surface" pair, asserting `MirrorState` is
  `link` or `mirror` and that `CLAUDE.md` carries the contract's bytes. The other
  six are `FmInstall` doctor checks that pass the REAL repo root and assert
  `$doctor.Healthy`, which reads the same surface. In a fresh task worktree,
  where `CLAUDE.md` is still the 9-byte git placeholder and `.claude/skills` the
  14-byte one, all eight fail until `bin/fm-setup.ps1` has been run against that
  checkout once. That is a real precondition of the suite and is worth stating
  where a new lane will hit it. Section 26.6 measures the set and shows all eight
  passing from the same code once the surface is materialized; it was recorded
  here as two because only two had been hit.
- **Three entry points have a `-h` flag that prints nothing.** `fm-brief.ps1`,
  `fm-lock.ps1` and `fm-crew-state.ps1` each answer `-h` with `Get-Help -Full`,
  and each prints only the script name: their header block carries no
  `.SYNOPSIS`/`.DESCRIPTION` keyword AND sits flush against `#requires`, and
  PowerShell attaches script help only when both are right (section 25.5 has the
  measurement). Fixing it means rewriting three other areas' help blocks, so it
  is reported rather than done here.

## 18. Autolaunch, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

The opt-in `config/autolaunch` command and its interruptible grace window
(`docs/autolaunch-windows.md`), on `fm/fmwin-autolaunch` over `2e60e39`.

The captain's own checkout at `C:\Users\ADMIN\firstmate-win` was **not touched**
in either of the two runs this section records. The branch was carried over as a
`git bundle` and cloned elsewhere - `C:\Users\ADMIN\fmwin-autolaunch` for
18.1-18.4, and `...-live` plus a pre-fix `...-pre` for the live-pane work in 18.5
and 18.9 - and set up with `-SkipProfile`, so the captain's PowerShell profile
and their global Claude settings were left alone. Everything either run created
on the laptop was removed afterwards; `win-*.ps1` files belonging to earlier
lanes were left alone.

Environment, read on the laptop at the start of each run:

```
pwsh      : 7.6.4
pester    : 6.1.0
git       : git version 2.49.0.windows.1
herdr     : herdr 0.7.5-preview.2026-07-21-0f10e1453a7f
claude    : C:\Users\ADMIN\AppData\Roaming\npm\claude.ps1  (2.1.229)
os        : Microsoft Windows NT 10.0.26100.0   (18.1-18.4)
os        : Microsoft Windows NT 10.0.26200.0   (18.5, 18.9 - the laptop moved
                                                 build between the two runs)
```

### 18.1 Unconfigured: nothing happens at all - `PROVEN (Windows 11)`

```
> pwsh -NoProfile -File bin\fm-autolaunch.ps1 default:w1:p2
autolaunch disabled: no C:\Users\ADMIN\fmwin-autolaunch\config\autolaunch - autolaunch is off
exit: 0  (0 = deliberately nothing to do)
```

Nothing was typed and no backend call was made: with no config the command
returns before it looks at the target at all.

### 18.2 The doctor says which state it is in, and prints the command - `PROVEN (Windows 11)`

Unconfigured:

```
  [ok]      autolaunch - off - no config/autolaunch, so nothing is started automatically
```

With the captain's own choice written into `config/autolaunch`:

```
  [ok]      autolaunch - on - types 'claude --dangerously-skip-permissions --continue --chrome' into a named pane and submits it after 10s unless the pane is touched
```

That line is the whole point of making the feature opt-in: the flag that
disables Claude's permission checks is printed where the captain already looks,
not left in a file someone has to remember to open.

### 18.3 A typo is a refusal, not a silent off - `PROVEN (Windows 11)`

```
> pwsh -NoProfile -File bin\fm-autolaunch.ps1 default:w1:p2      # config has delayy=10
autolaunch refused: C:\Users\ADMIN\fmwin-autolaunch\config\autolaunch line 2: unknown key 'delayy' (expected command or delay)
exit: 1  (1 = refused)

  [warn]    autolaunch - off - C:\Users\ADMIN\fmwin-autolaunch\config\autolaunch line 2: unknown key 'delayy' (expected command or delay)
              fix: correct C:\Users\ADMIN\fmwin-autolaunch\config\autolaunch (command=<command>, optional delay=<seconds>) or delete it
```

### 18.4 A target that is not a pane submits nothing, and says why - `PROVEN (Windows 11)`

```
> pwsh -NoProfile -File bin\fm-autolaunch.ps1 not-a-pane
autolaunch refused: 'not-a-pane' is not a herdr pane target of the form <session>:<pane-id>
exit: 1

> pwsh -NoProfile -File bin\fm-autolaunch.ps1
usage: fm-autolaunch.ps1 <session>:<pane-id> [-DelaySeconds <n>] [-WhatIf]
exit: 2
```

### 18.5 The three live-pane demonstrations - `PROVEN (Windows 11)` and `PROVEN (pwsh/Linux)`

These three were previously recorded here as `BLOCKED (brief gate)`: they need a
live herdr pane to type into, creating one is Herdr lifecycle, and the earlier
brief carried no `--herdr-lab` gate. A re-issued brief carries that gate, so they
have now been run against a **real herdr server** - no mocks anywhere in the path
- on both platforms:

- **the captain's Windows 11 laptop**, herdr `0.7.5-preview.2026-07-21`, which is
  the run that matters and the one quoted below;
- **Linux**, herdr `0.7.5`, run first because the laptop's tunnel was down for
  the first half of this task (18.10) and used to find the defect in 18.9.

Both platforms give the same answers. Where they differ at all it is noted
inline.

**Isolation.** On Linux every herdr call went through `bin/fm-herdr-lab.sh` in a
named `fm-lab-fmwin-autolaunch-*` session under an `EXIT` trap. That helper is
bash and cannot run on the laptop, so the Windows run used a PowerShell port of
its guarantees, enforced call by call: an `fm-lab-*` name that can never be
`default`, a trailing `--session <lab>` on every call, no server-global operation
at all, a fresh refuse-if-default check immediately before stop and again before
delete, and the running `default` session recorded as a fleet-state tripwire
before provisioning and required to be identical afterwards.

```
TRIPWIRE BEFORE: default|True|True|C:\Users\ADMIN\AppData\Roaming\herdr\herdr.sock
LAB RUNNING: fm-lab-winauto-20740
...
TRIPWIRE AFTER : default|True|True|C:\Users\ADMIN\AppData\Roaming\herdr\herdr.sock
TEARDOWN CLEAN: lab gone, default identical
```

The captain's own `default` session on the laptop was live throughout and was
never a target. The autolaunch code is in any case session-scoped by its own
target - `Invoke-FmHerdrCli` appends `--session <session-from-the-target>` to
every call - so arming `fm-lab-...:w1:p2` cannot reach `default` even in
principle. A throwaway `FM_HOME` held the `config/autolaunch`; the captain's own
checkout at `C:\Users\ADMIN\firstmate-win` was not read or written, and the
branch was carried over as a `git bundle` and cloned elsewhere.

#### 1. Enabled, pane untouched: it starts by itself - `PROVEN (Windows 11)`

`config/autolaunch` held the captain's own choice and `delay=10`. A fresh
PowerShell pane in the lab, then one `Invoke-FmAutolaunch`. A separate observer
read the pane once a second throughout, which is the "during the window"
capture:

```
--- BEFORE ---
PS C:\Users\ADMIN\fmwin-autolaunch-live-work>

===== observer t=1s, t=2s =====     <- nothing yet
PS C:\Users\ADMIN\fmwin-autolaunch-live-work>

===== observer t=3s =====           <- typed, and NOT submitted
PS C:\Users\ADMIN\fmwin-autolaunch-live-work> claude -
-dangerously-skip-permissions --continue --chrome

===== observer t=4s ... t=13s =====  <- byte-identical, every poll
PS C:\Users\ADMIN\fmwin-autolaunch-live-work> claude -
-dangerously-skip-permissions --continue --chrome
```

```
--- running autolaunch (delay=10) --- 21:27:40
<<RESULT>> action=submitted armed=True submitted=True
<<REASON>> started 'claude --dangerously-skip-permissions --continue --chrome'
           after 10s untouched - an agent started in the pane
--- done --- 21:27:54
```

Claude really started on the laptop: `agent get` on that pane afterwards returns
a registered agent, and herdr's own title for the pane has become `claude`.

```
{"result":{"agent":{"agent":"claude","agent_status":"idle","pane_id":"w1:p2",
 "cwd":"C:\\Users\\ADMIN\\fmwin-autolaunch-live-work","terminal_title":"claude", ...
```

That is the captain's acceptance criterion end to end, on the laptop - placed
ready, visible and unsubmitted for the whole ten seconds, submitted by itself,
and Claude running.

**One platform difference worth keeping.** At the moment of confirmation the
Windows pane text had not yet repainted - the observer at t=14s still shows the
command line rather than Claude's UI - so the *pane-changed* signal was not what
proved the start there; the *agent-registered* signal was. `Wait-FmAutolaunchStarted`
watches both for exactly this reason, and on Windows the second one is what
earned its place.

#### 2. Enabled, captain types during the window: firstmate stands down - `PROVEN (Windows 11)`

Same setup, and a simulated captain sending ` && echo CAPTAIN-WAS-HERE` into the
pane about five seconds in.

```
--- running autolaunch --- 21:28:01
<<RESULT>> action=stood-down armed=True submitted=False
<<REASON>> the pane changed during the wait, so the captain is using it;
           nothing was submitted
--- done --- 21:28:07        <- ended when they typed, not at the deadline
captain typed at 21:28:06
```

The pane afterwards, holding both texts and unsubmitted:

```
PS C:\Users\ADMIN\fmwin-autolaunch-live-work> claude -
-dangerously-skip-permissions --continue --chrome && e
cho CAPTAIN-WAS-HERE
```

And nothing was submitted, from herdr rather than from our own report:

```
{"error":{"code":"agent_not_found","message":"agent target w2:p2 not found"}}
```

The captain's characters are exactly as they typed them, after the command
firstmate had already placed for them to see. This is the demonstration the brief
calls the one that matters most - and running it live is what exposed the defect
in 18.9, which no mocked version of it could have caught.

#### 3. Pane busy, or unreadable: nothing is submitted and the reason is reported - `PROVEN (Windows 11)`

Busy - an agent registered in the pane with `pane report-agent ... --state
working`:

```
<<RESULT>> action=refused armed=False submitted=False
<<REASON>> nothing was typed: something is already running in the pane

--- AFTER (must be identical) ---
PS C:\Users\ADMIN\fmwin-autolaunch-live-work>
PANE UNCHANGED BY REFUSAL: True
```

The pane after the refusal is byte-identical to the pane before it, compared with
`-ceq` in the run itself: nothing was typed, not merely nothing submitted.

Unreadable - a pane id that does not exist in the lab session, and a target that
is not a pane target at all:

```
<<REASON>> nothing was typed: there is no live pane
           'fm-lab-winauto-20740:pane-that-does-not-exist'
<<REASON>> 'not-a-pane' is not a herdr pane target of the form <session>:<pane-id>
```

#### The two controls, re-confirmed on the laptop

```
<<RESULT>> action=disabled submitted=False
<<REASON>> no ...\labhome-empty\config\autolaunch - autolaunch is off

  [ok]  autolaunch - on - types 'claude --dangerously-skip-permissions --continue
        --chrome' into a named pane and submits it after 10s unless the pane is touched
  [ok]  autolaunch - off - no config/autolaunch, so nothing is started automatically
```

The other `[warn]` and `[missing]` lines in that second doctor run belong to a
deliberately bare throwaway home (no backend file, no profile block) and are not
this area's.

### 18.6 The suite, on both platforms - `PROVEN (Windows 11)` and `PROVEN (pwsh/Linux)`

Re-run on both platforms after the 18.9 fix landed, both at the branch tip
`82732d0`:

```
Linux,      PowerShell 7.6.4, Pester 6.1.0,  574s
RESULT total=1584 passed=1579 failed=0 skipped=5 notrun=0

Windows 11, PowerShell 7.6.4, Pester 6.1.0, 1919s
RESULT total=1584 passed=1564 failed=4 skipped=16 notrun=0
```

The earlier run of the same suite, before the fix, was `1572 / 1567 / 0 / 5` on
Linux and `1572 / 1550 / 6 / 16` on Windows. The 12 extra tests are 18.9's.

The Windows suite was run twice, at the fix commit and again at the tip after a
private function was renamed, and returned the identical
`1584 / 1564 / 4 / 16` both times.

This area's own file is green on both: `tests/FmAutolaunch.Tests.ps1`, 59 tests,
59 passed, 0 failed.

The skip counts differ by platform because the guards do: Linux skips the 5
Windows-only cases, and Windows skips 16 - the POSIX-only cases plus the ones
gated on a tool that machine does not have (`tasks-axi`, the no-mistakes
pipeline). Neither set was skipped by anything this area added.

The **Windows failures are all outside this area**, and 18.8 establishes that by
measurement rather than by argument.

- `FmAnalyzer.Tests.ps1` x2 - `Invoke-FmAnalyzerSweep` raises
  `The property 'Analysed' cannot be found on this object` from its own crash
  and recovery cases. The analyzer harness, not the sweep it guards; the
  repo-wide sweep test itself passes.
- `FmPaths.Tests.ps1` and `FmState.Tests.ps1` x1 each - `$id cannot be
  retrieved`, and `Count` missing on the result of a read. Both are in the
  foundation area.

The earlier run had **6**, the two extra being `FmContract.Tests.ps1` reading
`placeholder` and a `CLAUDE.md` containing the literal text `AGENTS.md` - the
9-byte placeholder a `core.symlinks=false` checkout produces. 18.8 argued those
two were an artifact of that run refreshing with `git reset --hard`, which
rewrites both committed links back to text after setup has repaired them. This
run runs `fm-setup.ps1` before Pester and they are gone, which is that argument
confirmed by a second measurement rather than left as a claim.

18.8 re-runs the four remaining files at the base commit and on this branch, in
a bare environment with the links repaired, and gets identical results.

### 18.7 The three modelled assumptions, now measured - and what is still open

This section previously listed three assumptions this area took from
`bin/backends/herdr.sh` rather than measured. 18.5 measured all three against a
real herdr 0.7.5 server:

| Assumption | Now |
| --- | --- |
| a fresh shell pane answers `agent get` with `agent_not_found`, which is what makes it a legal target | **measured.** The pre-flight accepted the fresh lab pane and typed into it, which it does only on `no-agent`; the same pane answered with a registered agent once Claude started, and with one after `pane report-agent`, which was refused. |
| `pane read --source recent` over a quiet shell pane returns the same bytes twice | **measured.** Nine consecutive one-second polls over the armed pane were byte-identical, which is what held the window open to its deadline. |
| `pane send-text` leaves the line visible and unsubmitted, and a following `enter` runs it | **measured.** Visible and unsubmitted from t=2s to t=10s, and Claude running at t=11s. |

Measuring them also **found a defect none of them describes** - the pane is not
the only thing that can change between typing and reading back. That is 18.9.

All three were measured on **both** platforms - Windows herdr
`0.7.5-preview.2026-07-21` on the laptop and Linux herdr `0.7.5` - and gave the
same answers. `NOT YET VERIFIED ON WINDOWS HARDWARE` no longer applies to this
area's live pane behaviour.

Measuring on Windows specifically earned two things a Linux-only run would have
missed:

- **the agent-registered signal is load-bearing there.** At the moment Enter's
  effect was confirmed, the Windows pane text had not repainted yet, so the
  pane-changed signal alone would have reported an *unconfirmed* submit for a
  command that had in fact started (18.5, demo 1).
- **a herdr CLI round-trip on Windows is slower than the 0.4s settle**, which is
  why reproducing 18.9's race there needed the settle widened before a simulated
  captain could get into it at all.

What remains modelled rather than measured is unchanged and is stated in this
file's header: a shell running a *silent* foreground process is indistinguishable
from a shell at its prompt, because herdr's live foreground-process reading comes
back empty on Windows. The grace window is the mitigation, not a check.

### 18.8 Attributing all six, base against branch - `PROVEN (Windows 11)`

The four affected files re-run twice on the laptop, at the base commit and on
this branch, in the same bare environment: no `FM_HOME`, no
`FM_ROOT_OVERRIDE`, and `fm-setup.ps1` re-run after each checkout so the two
committed links are repaired rather than left as the placeholders a hard reset
writes.

```
== BASE (origin/main) (2e60e39) ==
total 148 passed 144 failed 4 skipped 0
  FAIL: the sweep runner itself.gives up after the full attempt budget when every sweep crashes
  FAIL: the sweep runner itself.recovers when a later attempt completes, and keeps that attempt s findings
  FAIL: Get-FmTaskStatePath.composes state/<id>.<suffix>
  FAIL: Reading.returns an empty collection of lines for a missing file

== BRANCH (fm/fmwin-autolaunch) (37e3b29) ==
total 148 passed 144 failed 4 skipped 0
  FAIL: the sweep runner itself.gives up after the full attempt budget when every sweep crashes
  FAIL: the sweep runner itself.recovers when a later attempt completes, and keeps that attempt s findings
  FAIL: Get-FmTaskStatePath.composes state/<id>.<suffix>
  FAIL: Reading.returns an empty collection of lines for a missing file
```

Identical, so:

- **Four are pre-existing Windows failures** at `2e60e39`, in the analyzer
  harness and the foundation area. This branch neither caused nor fixed them,
  and they are reported to their owners rather than edited here.
- **The two `FmContract` failures disappear** in both runs once the links are
  repaired, which confirms them as an artifact of the `git reset --hard`
  refresh and not a fault in the checkout or in this branch.

One earlier guess is worth correcting rather than quietly dropping: the
foundation pair looked like `FM_HOME` leaking out of the runner into the whole
Pester process. It is not - they fail with the environment cleared, at the base
commit, on their own.

### 18.9 The defect the live pane found - `PROVEN (Windows 11)` and `PROVEN (pwsh/Linux)`

**Firstmate submitted the captain's own line, and reported it as a success.**

The mocked suite was green, and had been green through every stand-down case
this area has. Driving the same state machine against a real pane found a defect
none of those cases could express.

**What was wrong.** Typing is not atomic. `pane send-text` returns, a settle
passes, and only then is the pane read back to establish the armed baseline that
the whole grace window is compared against. A keystroke made in that gap is
already in the pane when the baseline is taken - so it becomes *part of the
baseline*. Every subsequent poll then reproduces those bytes perfectly, because
the pane genuinely does not change again, and the window runs to its deadline
and presses Enter. The captain's half-written line is submitted along with
firstmate's command, and the result is reported as a clean success.

No test in the grace window can catch this, because by the time the window
starts there is nothing left to detect: the interference is already inside the
thing the window trusts.

**Reproduced, before fixing.** A lab pane, `delay=6`, a stand-in command so the
race is about whose text is submitted rather than what starts, and a simulated
captain typing `; echo CAPTAIN-TEXT` the instant firstmate's characters appear:

```
<<RESULT>> action=submitted submitted=True
<<REASON>> started 'echo FIRSTMATE-COMMAND' after 6s untouched - the pane took the command
captain typed at 21:13:20.754

--- AFTER ---
...racework$ echo FIRSTMATE-COMMAND; echo CAPTAIN-TEXT
FIRSTMATE-COMMAND
CAPTAIN-TEXT
...racework$
```

`CAPTAIN-TEXT` **ran**. And the reason line says "after 6s untouched" about a
pane that was touched. This is precisely the failure the feature must not have,
reported as success.

**The fix** is to stop trusting the baseline and prove it instead:
`Test-FmAutolaunchArmedByFirstmate` requires the pane after typing to read as the pane
before plus exactly the command and nothing else. Whitespace is dropped from
both sides before comparing, because herdr hard-wraps a capture at the pane
width and splits the command mid-token - a 53-column pane renders
`claude --dangerously...` as `cl\naude --dangerously...`. That keeps the
comparison immune to where the wrap falls without weakening it: no keystroke
that adds a visible character can survive it. The comparison is anchored at the
tail, so history may scroll off the *start* of the capture - which typing at the
bottom of a full pane genuinely causes - while nothing may be gained anywhere.

**The same race after the fix**, same script, same timing:

```
<<RESULT>> action=stood-down submitted=False
<<REASON>> the pane does not hold exactly the command that was typed, so
           something else reached it at the same moment; nothing was submitted
captain typed at 21:14:41.156

--- AFTER ---
...racework$ echo FIRSTMATE-COMMAND; echo CAPTAIN-TEXT
```

Nothing ran. The captain's characters are exactly where they typed them.

#### The same A/B on the laptop - `PROVEN (Windows 11)`

Because the fix is in the state machine rather than in herdr, it was worth
proving on the platform this port exists for. Two clones on the laptop - one at
`326f7af` before the fix, one at the fix - one lab, one simulated captain, back
to back:

```
================ BEFORE-THE-FIX =========commit:   326f7af Name the commit each suite run was measured at
<<RESULT>> action=submitted submitted=True
<<REASON>> started 'echo FIRSTMATE-COMMAND' after 6s untouched - the pane took the command
--- AFTER ---
PS C:\Users\ADMIN\...> echo FIR
STMATE-COMMAND; echo CAPTAIN-TEXT
FIRSTMATE-COMMAND
CAPTAIN-TEXT
CAPTAIN'S TEXT WAS EXECUTED: True        <-- the defect, on the laptop

================ AFTER-THE-FIX ================
<<RESULT>> action=stood-down submitted=False
<<REASON>> the pane does not hold exactly the command that was typed, so
           something else reached it at the same moment; nothing was submitted
--- AFTER ---
PS C:\Users\ADMIN\...> echo FIR
STMATE-COMMAND; echo CAPTAIN-TEXT
CAPTAIN'S TEXT WAS EXECUTED: False       <-- typed, held, never run
```

**Which commits those two runs are.** The pre-fix side is `326f7af` exactly. The
post-fix side ran at the fix commit as it stood then; the branch tip renames one
private function (`Test-FmAutolaunchArmedByUs` to
`Test-FmAutolaunchArmedByFirstmate`) and edits comments, with no behavioural
change, and the tip is what 18.6's suite numbers are measured at. The live A/B
was not re-run for the rename.

**How the race had to be entered there, stated plainly.** A herdr CLI
round-trip on Windows takes longer than autolaunch's own 0.4s settle, so a
simulated captain polling the pane cannot get inside that gap - three attempts
typed only after Enter had already been sent, and are not counted as
demonstrations of anything. The run above therefore does two things: it widens
the settle with `-SettleSeconds 8`, and it types on a clock rather than by
polling. Neither changes the mechanism - the gap between `send-text` and the
read-back is what it is at any width - but it does mean the *timing* of this
particular reproduction was arranged rather than natural. What is measured is
that with a keystroke in that gap, the pre-fix code submits it and the fixed
code does not.

Two of the intermediate attempts are worth keeping rather than discarding: when
the simulated captain typed slightly earlier, into the *pre-flight* window
instead, both checkouts refused with `nothing was typed: the pane is changing,
so it is already in use`. That is the older guard doing its job, and it is why
the settle-gap defect needed a keystroke landing in one specific interval to
show up at all.

**The fixture is why it hid.** `Set-CalmPane` had `Send-FmHerdrLiteral` insert a
`"> "` of its own before the text. No pane does that - a real one puts the
characters at the shell's prompt exactly as a keyboard would, which is what
every capture in 18.5 shows. That invented separator meant the mocked pane never
looked like a real one, and the check that catches this defect is exactly the
check that fiction would have defeated. The fixture is corrected in the same
commit; with it corrected the pre-existing cases still pass, so the correction
removed a fiction rather than a behaviour.

**Cost of the check.** It is one more way to stand down, and standing down
wrongly costs the captain a keypress. Two of the twelve new tests exist to keep
that cost from becoming a feature that never fires: a capture whose command is
wrapped across lines, and one where older output scrolled off the top while the
command was typed, both still submit.

### 18.10 The laptop tunnel, and what it cost

The laptop is reached over `ssh -p 2222` on a forwarded port. It was **down for
the first half of this task** and came up partway through, which is why the same
demonstrations exist twice.

```
21:08:35  Connection timed out during banner exchange   <- listener up, laptop end gone
   ...    21 consecutive attempts over ~11 minutes
21:19:30  ssh: connect to host 127.0.0.1 port 2222: Connection refused
21:19:50  ALIVE
```

The listener on this box stayed up throughout, so the failure was the laptop end
of the tunnel rather than the forwarder - the same shape section 0 records for an
earlier lane, where it never recovered.

Two practical notes for the next run rather than for this one:

- The remote default shell is **`cmd.exe`**, not PowerShell. `ssh ... 'echo X;
  pwsh -Command "..."'` gets echoed literally instead of run, and a long
  `pwsh -Command` string mangles on the way through. Copy a `.ps1` across and run
  it with `pwsh -NoProfile -File`; every Windows step here does that.
- A herdr CLI round-trip on Windows costs longer than autolaunch's own 0.4s
  settle, which matters for anything trying to *time* against it - see 18.9.

Everything this run created on the laptop was removed afterwards: two clones,
the transferred bundle, the runner scripts, and the throwaway homes, all
verified gone. The captain's own checkout at `C:\Users\ADMIN\firstmate-win` was
never read or written by anything here - no path in any script above refers to
it - their PowerShell profile was left alone (`-SkipProfile`), and their live
`default` herdr session was never a target and was verified unchanged after
every lab teardown.

One thing worth naming so a later reader does not misread it: that checkout
**does** have recent write timestamps and uncommitted changes
(`FmBacklogAdmin.ps1`, `FmBacklog.Tests.ps1`, a `testResults.xml`), including
writes that landed *after* this run had finished and cleaned up. That is another
lane working in the captain's checkout concurrently, not this one. Timestamps
there are not evidence about this task either way.

---

## 19. The backlog wrote one file and read another - `PROVEN (Windows 11)`

The captain hit this in a real session on the laptop: a work item was added, and
the next session start reported the queue absent. The tracked suite was green
throughout, because every test that touched the backlog passed the file path in.

### 19.1 The defect, reproduced on the laptop at `2e60e39`, BEFORE the fix

A scratch home under `C:\Users\ADMIN`, `config\backlog-backend = manual`, one
`bin\fm-backlog.ps1 add`, then `bin\fm-session-start.ps1`:

```
=== 1. add a work item to a fresh home ===
add fmwin-demo -> queued
=== 2. what is on disk under the home ===
backlog.md
config\backlog-backend
=== 3. the session-start digest's backlog section ===
ABSENT
```

The command confirmed the item. It went to `<home>\backlog.md`. The digest reads
`<home>\data\backlog.md` and reported ABSENT. Nothing failed and nothing warned;
the captain's task queue was invisible to every reader.

### 19.2 After the fix, same script, same machine

```
=== 1. add a work item to a fresh home ===
add fmwin-demo -> queued
=== 2. what is on disk under the home ===
config\backlog-backend
data\backlog.md
=== 3. the session-start digest's backlog section ===
compact backlog listing (manual backend; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to 20; indented task bodies omitted)
## Queued
- [ ] fmwin-demo - Ship the morning brief (since 2026-08-13)
```

### 19.3 The captain's own home was NOT in the split state

Inspected, never written:

```
C:\Users\ADMIN\firstmate-win        no backlog.md at the root
C:\Users\ADMIN\firstmate-win\data   0 File(s)
```

So the migration path had nothing to collect there. It still ships, because any
home that ran `add` on the old code does have items in the wrong file, and
losing them to the fix would repeat the bug the fix is for. All destructive
testing used scratch homes under `C:\Users\ADMIN`.

### 19.4 The two project-memory tests, on a machine WITHOUT Developer Mode

Developer Mode is off on the laptop - `HKLM\...\AppModelUnlock` does not exist.
What let the earlier runs create symlinks is that the SSH session is elevated, so
its token holds `SeCreateSymbolicLinkPrivilege`. Removing that one privilege from
the process token reproduces the captain's stock shell exactly, and the run says
so rather than assuming it:

```
remaining SeCreateSymbolicLinkPrivilege: 0 (0 = removed)
symlink now refused, exactly as a stock non-elevated shell does: Administrator privilege required for this operation.
fallback produced: hardlink (no LinkTarget)
```

Same file, same machine, same removed privilege, at both commits:

```
BEFORE 2e60e39   T=36 P=28 F=2 S=6
  FAILED: Set-FmAgentsMemory in an empty worktree.creates AGENTS.md ... and links CLAUDE.md to it
  FAILED: Set-FmAgentsMemory promoting a lone CLAUDE.md.moves it to AGENTS.md ... and links CLAUDE.md back
AFTER  fm/fmwin-backlogpath   T=36 P=30 F=0 S=6
```

The six SKIPPED are unchanged and are the fixture-privilege ones section 12
already gated. These two were the leftover half: their subject is what
`Set-FmAgentsMemory` produces, not whether a fixture can be built, so skipping
them would have stopped checking the command on exactly the machine it has to
work on. They now assert that both names resolve to the same content, by reading
through both - which is true of a symlink, a hardlink and a copy alike. Section
12's "a non-elevated Windows run is the outstanding confirmation" is now closed.

### 19.5 Suite numbers, both platforms, AFTER the rebase onto `59925eb`

Measured after the rebase, not before, because a clean replay can still break
code:

```
Linux    pwsh 7.6.4 / Pester 6.1.0   T=1601  P=1596  F=0  S=5
Windows  pwsh 7.6.4 / Pester 6.1.0   T=1601  P=1583  F=4  S=14
```

Before the rebase this branch alone was `T=1540 P=1535 F=0 S=5` on Linux against
a `2e60e39` baseline of `T=1523 P=1518 F=0 S=5`, so it adds 17 tests and every
one passes; the other 61 arrived with section 18's branch. The skip counts differ
by platform, not by branch: the Windows-only and POSIX-only cases are gated by
their own probes.

The four Windows failures are the four section 16 established as pre-existing,
and section 18.8 then measured at the base commit on this same laptop and got an
identical list. They are named here so this run's number is readable on its own:

```
the sweep runner itself.gives up after the full attempt budget when every sweep crashes
the sweep runner itself.recovers when a later attempt completes, and keeps that attempt s findings
Get-FmTaskStatePath.composes state/<id>.<suffix>
Reading.returns an empty collection of lines for a missing file
```

**Two more failed on the first Windows run and are NOT that class, so they were
attributed rather than assumed.** `this checkout's own instruction surface.is
healthy` and `...keeps the contract reachable under both names it is read by`
read the REAL checkout, and the scratch clone used for this run had never had
`bin/fm-setup.ps1` run against it - so `CLAUDE.md` and `.claude\skills` were
still the placeholders a Windows clone leaves. Running `tests/FmContract.Tests.ps1`
in that same clone once the two links existed gives `T=37 P=37 F=0` at BOTH
`2e60e39` and this branch, and the whole-suite re-run above no longer lists them.
They were the clone's state, not this change.

One regression check that is easy to skip and worth stating: both new backlog
regression tests were confirmed RED with only the two behaviour hunks reverted
and the new tests left in place - `THE REGRESSION: an added item is found through
the path session start reads` and `THE REGRESSION: an added item appears in the
digest, not ABSENT` - so neither passes for a reason other than the fix.

## 20. Reconciling the two independent fixes for the same defect - `PROVEN (Windows 11)`

The captain's own laptop session fixed the backlog split (commit `9464471`) while
a worker fixed it here (`59925eb..da5ce55`). Both were real work. This section
records what each side contributed and what was executed to settle the two places
they disagreed.

| Area | Side taken | Why |
| --- | --- | --- |
| backlog location | this side's migration | the laptop's second candidate fixes a fresh home and leaves an already-split one split; see 20.1 |
| `-KeepHomePointer` | the laptop's, whole | this side never found it; see 20.2 |
| the same switch for the live session | new here | the same hijack one scope up, which the laptop fix did not cover |
| agent-memory tests | this side's | reads both names and compares bytes rather than ORing a narrower length-first check |
| secondmate launch findings | the laptop's, unchanged | a project directory and `-LabelHome` are needed even for a `--no-projects` charter |

### 20.1 Why the root candidate was dropped, executed rather than argued

Both sides agree `data/backlog.md` is the one location. They differ on the home
that already ran the old code. Case B below is the whole disagreement: the
laptop's version keeps `<home>\backlog.md` resolving, so the resolver reads it
while the digest, cleanup and a Linux firstmate keep reading `data\backlog.md` -
the captain's own home would still report the queue absent with their items in
it. Migrating is what actually closes it, and it is also the stronger answer to
the concern behind the laptop's version, because the captain's file is the one
that arrives at the canonical path rather than an empty one appearing beside it.

Scratch homes under `C:\Users\ADMIN`, `config\backlog-backend = manual`, real
`bin\fm-backlog.ps1` runs:

```
=== A. FRESH home: the first add must land where the digest reads ===
  add fmwin-demo -> queued
  files under the home:
    config\backlog-backend
    data\backlog.md

=== B. ALREADY-SPLIT home: a real root backlog.md with the captain's item ===
  before:
    backlog.md
    done-archive.md
    config\backlog-backend
  list (this is the command that triggers the reconciliation):
    WARNING: backlog: moved the backlog from ...\split\backlog.md to ...\split\data\backlog.md,
             and its done-archive.md with it (it was created in the pre-fix location, where
             nothing else reads it).
    queued	keep-me	the captain's real item
  after:
    config\backlog-backend
    data\backlog.md
    data\done-archive.md
  the item, read through the path session start computes for itself:
    - [ ] keep-me - the captain's real item (since 2026-08-01)

=== C. TWO real queues: must refuse, and merge neither ===
  two backlogs in this home: ...\twoqueues\backlog.md is the pre-fix location and
  ...\twoqueues\data\backlog.md is the one firstmate reads. Both hold work items, so
  nothing here decides which is current: move the items you still want into
  ...\twoqueues\data\backlog.md, then delete ...\twoqueues\backlog.md.
  both files still intact: root='True' data='True'

=== D. the captain's REAL home, inspected only ===
  root backlog.md present : False
  data\backlog.md present : True
```

A home that deliberately pins another path through `.tasks.toml` is left alone,
which is also the escape hatch for the one legitimate root-level layout the
laptop's version was protecting.

### 20.2 The second-home defect, proven fixed and proven real

Asserting the switch exists is not proof. This provisions a second home from a
scratch checkout with real `bin\fm-setup.ps1`, then asks `bin\fm-home.ps1` in a
bare `-NoProfile` shell the question every entry point asks - and the negative
control puts the defect back:

```
=== 1. Provision the PRIMARY home from this checkout ===
    [created] home pointer - ...\checkout\.fm-home -> ...\primary-home
  after primary setup:
    .fm-home              = C:\Users\ADMIN\fmwin-proof\primary-home
    fm-home.ps1 (bare)    = C:\Users\ADMIN\fmwin-proof\primary-home

=== 2. Provision a SECONDMATE home from the SAME checkout, WITH -KeepHomePointer ===
    [skipped] home pointer - -KeepHomePointer: left ...\checkout\.fm-home naming this
              checkout's existing home, not ...\secondmate-home
  after secondmate setup:
    .fm-home              = C:\Users\ADMIN\fmwin-proof\primary-home
    fm-home.ps1 (bare)    = C:\Users\ADMIN\fmwin-proof\primary-home

  RESULT: PASS - the checkout still resolves to the primary home.
  second home built: True

=== 3. NEGATIVE CONTROL: the same run WITHOUT the switch (this is the bug) ===
    [updated] home pointer - ...\checkout\.fm-home -> ...\secondmate-home
  after secondmate setup with NO switch:
    .fm-home              = C:\Users\ADMIN\fmwin-proof\secondmate-home
    fm-home.ps1 (bare)    = C:\Users\ADMIN\fmwin-proof\secondmate-home
  RESULT: the primary was repointed at the secondmate's home - the defect, reproduced.
```

The second home is still built in full, `AGENTS.md` stop-and-redirect included;
only the claim on the checkout is withheld.

The same call also publishes `FM_HOME`/`PATH`/`PSModulePath` into its own
process. Through `bin\fm-setup.ps1` that dies with the subprocess, so it was not
the live defect - but a session that provisions a secondmate by importing the
module rather than shelling out would be moved just as silently, so
`-KeepHomePointer` now withholds that too. `tests/FmInstall.Tests.ps1` pins all
three surfaces: the pointer file, `Resolve-FmEntryPointHome`, and the session.

### 20.3 Suite numbers, both platforms, at the reconciled tree

Measured after `git fetch origin`, with `origin/main` at `da5ce55` and this
branch a clean fast-forward onto it:

```
Linux    pwsh 7.6.4 / Pester 6.1.0   T=1605  P=1600  F=0  S=5
Windows  pwsh 7.6.4 / Pester 6.1.0   T=1605  P=1588  F=3  S=14   (first run, fresh clone)
Windows  pwsh 7.6.4 / Pester 6.1.0   T=1605  P=1591  F=0  S=14   (re-run, same clone)
```

**The Windows re-run is fully green**, and it is the number to read: the only
difference between the two runs is that `bin\fm-setup.ps1` had by then run in
that clone. All three first-run failures cleared without a code change, which is
what the attributions below predicted.

`main` alone is `T=1601 P=1596 F=0 S=5` on Linux, so the reconciliation adds
exactly 4 tests - the laptop's two `-KeepHomePointer` tests, the end-to-end
resolution proof in 20.2, and the backlog decision test in 20.1 - and every one
passes. The laptop branch's own reported `1503 passed / 0 failed / 25 skipped`
was measured against an older base and a different skip gating; it is not
comparable row-for-row, and no attempt is made to reconcile the two totals.
The skip counts differ by platform, not by branch.

The three first-run Windows failures were attributed rather than assumed, and
none is this change:

**Two are the clone's state, not the code.** `this checkout's own instruction
surface.is healthy` and `...keeps the contract reachable under both names it is
read by` read the REAL checkout. The whole suite ran in a fresh `git bundle`
clone that `bin\fm-setup.ps1` had never run against, so `CLAUDE.md` and
`.claude\skills` were still the placeholders a Windows clone leaves, and
`FmContract` runs before `FmInstall` - whose own setup runs then repair them.
Running that file on its own in the same clone gives `T=37 P=37 F=0`. This is the
same pair, with the same cause, that section 19.5 attributed.

**One is a load-dependent flake in the lock area, and it is NOT ours.** `One
holder, proven with real processes.never lets two processes increment a counter
at once` reported `Expected 36, but got 35` in the first whole-suite run, passed
`T=47 P=47 F=0` on three consecutive standalone runs, and passed again in the
whole-suite re-run - 4 passes to 1 failure, with no code change between them. It
is left open for the lock area rather than patched blind from here, and 20.4
records what is known.

### 20.4 Left open for the lock area: one lost increment under whole-suite load

The test is already guarded against the two innocent explanations - it asserts
every worker reached `Completed` and that no worker threw, BEFORE it judges the
counter - and those guards passed. So the run really did lose one increment
across 3 processes x 12 increments while all three finished cleanly.

What is known, and what is not:

- It did not reproduce: 3 consecutive standalone runs of `tests\FmLock.Tests.ps1`
  in the same clone on the same machine were `47/47`, and the whole-suite re-run
  passed it too. One failure in five attempts, none of them a code change.
- The one window in the design that is width-limited rather than atomic is the
  mid-claim grace: a claimer creates its `pid` file and writes it as two steps,
  and a competitor treats an unreadable claim as held only while it is younger
  than `FM_LOCK_STALE_AFTER`, floored at 2s. A claimer starved for longer than
  that between the two steps would be judged stale and its lock taken.
- That floor is **not** a port invention - it is `fm_lock_mid_acquire_is_fresh`
  from the bash original, preserved deliberately. So if this is the mechanism, it
  is inherited from the reference implementation and not introduced here.
- **This is a hypothesis, not a diagnosis.** Nothing here observed the window
  being exceeded; it is the candidate that fits, named so the owner starts
  somewhere rather than from nothing.

It is recorded rather than fixed because a wrong change to mutual exclusion is
worse than a known flake, and because the reconciliation this section documents
touches nothing in the lock area.

---

## 21. Secondmate retirement, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

Executed 2026-08-14 in the disposable worktree
`C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\2\firstmate-win`, on Windows 11
Pro 10.0.26200 with PowerShell 7.6.4, a real `treehouse` pool and a real lease.
Every run below drove `bin/fm-teardown.ps1` as an operator does; nothing here is
a unit test's account of itself.

### 21.1 The gap, reproduced first

A provisioned secondmate home, a task record in the launching home, a row in
`data/secondmates.md`, and an agent already exited cleanly - the exact situation
the brief describes:

```
=== bin/fm-teardown.ps1 sm-demo ===
REFUSED: secondmate sm-demo cannot be retired by this port yet.
Its home retirement owner (descendant task locks, the registry entry, and process-event restoration) has not landed;
no step of it ran, and every record is preserved.
exit=1

=== bin/fm-teardown.ps1 sm-demo --force --approved-by 'captain' ===
(the identical refusal)
exit=1
```

`--force` did not help, which is what left hand-deleting the home as the only
route.

### 21.2 An idle, clean secondmate retires - `PROVEN (Windows 11)`

Same fixture, with the retirement owner landed. The worktree is a genuine
`treehouse get --lease` allocation, returned conditionally on its lease id:

```
leased worktree: C:\Users\ADMIN\.treehouse\project-dbfb02\1\project (lease 033ba4f2a5b94fe3aad3cc7365d2818c)

=== bin/fm-teardown.ps1 sm-demo ===
teardown: step process-custody did NOT run [did-not-run]: no custody job named Local\firstmate-task-sm-demo (win32 error 2)
teardown sm-demo complete (window fm:w1:p1, worktree C:\Users\ADMIN\.treehouse\project-dbfb02\1\project)
exit=0

  registry has sm-demo row : False        # removed
  registry has sm-demo-2   : True         # the other lane survives
  secondmate home on disk  : False        # retired
  launching meta on disk   : False
  project clone on disk    : True         # untouched
```

The `did NOT run` line is the honest custody report this port already gives a
task whose processes have all exited; it is not a retirement defect.

### 21.3 Work under way in its own home refuses, naming it - `PROVEN (Windows 11)`

A descendant task record in the secondmate's own `state/`:

```
REFUSED: secondmate sm-demo still has work under way in its own home C:\...\sm-demo-home.
  task record child-1 (C:\...\sm-demo-home\state\child-1.meta)
Let that home finish its work, or tear those tasks down in that home first.
A forced discard needs the captain's explicit OK: --force --approved-by "<who approved it>".
exit=1
```

And its own backlog, read through that home's own `data/backlog.md` rather than
the launching home's:

```
REFUSED: secondmate sm-demo still has work under way in its own home C:\...\sm-demo-home.
  backlog item in flight: sm-work - Fix the demo lane
exit=1
```

Both left the home, the registry row and every state file in place, and both
completed under `--force --approved-by "captain, e2e"`.

### 21.4 A live descendant refuses, and `--force` does NOT override it - `PROVEN (Windows 11)`

A held lock in the secondmate's home, owner alive:

```
=== bin/fm-teardown.ps1 sm-demo ===
REFUSED: secondmate sm-demo still has a live descendant holding a lock in C:\...\sm-demo-home.
  C:\...\sm-demo-home\state\.control-child-1.lock - held by pid 27852
exit=1

=== bin/fm-teardown.ps1 sm-demo --force --approved-by 'captain, e2e' ===
(the identical refusal)
exit=1

  registry has sm-demo row : True
  secondmate home on disk  : True
  launching meta on disk   : True
```

This is the one refusal captain authority does not reach, and the run shows it
holding with the flag and the authority both present.

### 21.5 Unlanded work refuses, and `--force` records the authority - `PROVEN (Windows 11)`

An unpushed commit in a project clone inside the secondmate's home:

```
REFUSED: secondmate sm-demo cannot be retired while project clone project in C:\...\sm-demo-home holds work that has not landed.
  REFUSED: worktree C:\...\sm-demo-home\projects\project has work not on any remote and not landed.
  unpushed commits:
  70a1c70 unlanded
  Push the branch, land its PR, or get the captain's explicit OK to discard, then --force.
exit=1
```

The nested refusal is the ORDINARY landed-work test's own wording: the gate
calls `Test-FmTeardownWorktreeSafety` back rather than carrying a second copy of
it. With `--force --approved-by "captain, e2e"` the same fixture retired, exit 0,
and the authority is recorded on the `secondmate-retirement-gate` step.

### 21.6 A `home=` that is not a home refuses - `PROVEN (Windows 11)`

`home=` defaults to the PROJECT directory when a secondmate is spawned without
`-LabelHome`, so this is a real record shape, not a contrived one:

```
REFUSED: secondmate sm-demo records its home as C:\...\project, which is task sm-demo's project clone.
That is not a retirable secondmate home - a secondmate is provisioned with `fm-setup.ps1 -FirstmateHome <path> -KeepHomePointer`,
and a home= that landed on one of those paths means no separate home was ever created. Nothing was removed.
exit=1

  project clone on disk    : True
```

### 21.7 What is NOT proven here

- **The descendant-lease release against a real pool.** The E2E fixtures had no
  descendant holding a treehouse lease; that path is covered by
  `tests/FmSecondmate.Tests.ps1` and `tests/FmTeardown.Tests.ps1` against a
  mocked `treehouse`, including the refusal when a return fails.
- **Closing a real herdr pane.** The runs above recorded a pane that herdr had
  already lost, so `Test-FmHerdrEndpointGone` confirmed it gone rather than
  `Remove-FmHerdrPane` closing a live one. The close itself is the herdr area's,
  and unchanged by this work.
- **A single uninterrupted whole-directory `Invoke-Pester -Path ./tests`.** The
  laptop was heavily loaded by the captain's own applications throughout and
  each attempt ran for hours; the last one was stopped deliberately, to rebase
  onto a `main` that had advanced. What IS measured in this worktree: per-file,
  `FmSecondmate` 40/40, `FmTeardown` 105 passed + 3 skipped (the
  symlink-privilege ones), and `FmModuleAssembly` + `FmPaths` + `FmSecondmate`
  111/111 in one process; and inside a whole-directory run that reached 26 of
  38 files before being stopped, `FmAnalyzer` - the repo-wide sweep, clean at
  Error, Warning AND Information - plus `FmBacklog`, `FmContract` and 23 others,
  zero failures throughout. The whole-directory pass is the one claim this
  section does not make, and it should be re-run before the merge.

### 21.8 Two defects this work found in landed code - `PROVEN (Windows 11)`

Both were found by running the thing, not by reading it.

1. **`Get-FmBacklog` raised on an EMPTY backlog.** `Get-FmBacklogTaskBullet`
   declared `-Line` mandatory without `[AllowEmptyString()]`, and
   `ConvertFrom-FmBacklogEntry` offers it every line in a section. The canonical
   rendering puts a blank line under each `##` header, so a fresh home's backlog
   is nothing but blank lines:

   ```
   FAILED: Cannot bind argument to parameter 'Line' because it is an empty string.
   at ConvertFrom-FmBacklogEntry, module/Firstmate/Private/FmBacklog.ps1: line 616
   at Get-FmBacklog, module/Firstmate/Public/Get-FmBacklog.ps1: line 44
   ```

   The suite never caught it because its fixture's blank lines all sit inside an
   item BODY, which a different scan consumes. A regression test for the
   item-less section is now in `tests/FmBacklog.Tests.ps1`.

2. **Pester reads angle brackets in an `It` title as a data placeholder.** A test
   named `'reports one record per state/<id>.meta'` fails with "The variable
   '$id' cannot be retrieved because it has not been set" under strict mode, and
   the error points at `<ScriptBlock>, <No file>:1` rather than at the title.

   That is the cause of `Get-FmTaskStatePath.composes state/<id>.<suffix>`,
   which sections 16 and 17 both carry as unattributed - on Linux and on Windows
   alike. It is the only `It` in the whole suite carrying placeholders with no
   `-ForEach` data to fill them, and it explains the recorded symptom exactly:
   it passes when its own file runs alone, and fails after a file that leaves
   strict mode on. It is renamed here, and `CONTRIBUTING.md` carries the rule.
   The other three of section 16's four were NOT diagnosed by this work.

---
## 22. The unresolved-decision completion gate, on the captain's Windows 11 machine - `PROVEN (Windows 11)`

Run on 2026-08-14, PowerShell 7.6.4 on Windows 11 Pro 10.0.26200, in a
disposable treehouse worktree of this repo on branch `fm/hold-gate`. Every
command below is the real entry point against a real home; nothing is mocked.

The branch was cut from `9464471`, which `main` had already reconciled into
`2f24ea0` by the time this finished, so everything below was measured twice:
first at the branch point, then again after rebasing onto `2f24ea0` - where the
backlog area this gate reads through had itself changed. Both demonstrations
agree, and the second is the one that describes the tree being merged.

### 22.1 The refusal, reproduced first - at the branch point, before the change

A home carrying a finished scout: `data/demo-1/report.md`, a `state/demo-1.meta`
recording `kind=scout` and `backend=herdr`, and a status stream ending `done:`.

```
$ $env:FM_HOME = <scratch home>; ./bin/fm-teardown.ps1 demo-1
REFUSED: scout task demo-1 cannot pass the unresolved-decision completion gate.
Its owner (Test-FmDecisionHoldComplete or Test-FmDecisionHoldVerified) has not landed, so the gate did NOT run and cannot report a pass.
Inventory the report and any visual review through the decision-hold owner before teardown, or use --force after explicit discard approval.
EXIT=1
```

That is every completed investigation on this port, and the only way past it was
the flag that discards work.

### 22.2 The same task, after the owner landed

```
$ ./bin/fm-teardown.ps1 demo-1
teardown: step process-custody did NOT run [did-not-run]: no custody job named Local\firstmate-task-demo-1 (win32 error 2); ...
teardown: step worktree-return did NOT run [did-not-run]: no worktree on disk
teardown demo-1 complete (window default:pane-1, worktree ...\repro-wt)
Backlog: demo-1 just finished. Run tasks-axi done demo-1 --report data/demo-1/report.md, ...
EXIT=0
```

No `--force`, and the two steps that could not run still say so. Re-run
unchanged after the rebase onto `2f24ea0`, which matters here rather than being
box-ticking: `main` had reconciled the backlog resolver this gate reads through,
including a migration that moves a pre-fix root-level backlog. Same pass, and
the hold refusal in 22.3 re-runs identically too.

### 22.3 The three refusals, each through the same entry point

An unresolved decision hold in the backlog, attributed by `discovered-from`:

```
REFUSED: task demo-1 has an unresolved decision hold in this home's backlog.
  api-shape - captain must choose flat or nested responses (hold: choose the response shape) [hold-kind: captain] - it carries discovered-from: demo-1
That decision is still the captain's to answer, and demo-1 is what bin/fm-promote.ps1 promotes once it is answered - tearing it down now discards what the answer would act on.
Record the captain's answer and close the hold, or use --force after explicit discard approval.
EXIT=1
```

A decision the task opened in its own status stream and never closed:

```
REFUSED: task demo-1 still has an unresolved decision recorded in its own status stream.
  [key=api-shape] needs-decision: flat or nested response shape
...\state\demo-1.status opened it and no resolved/captain-held line carrying the same key ever closed it.
EXIT=1
```

No report - the separate gate, with its own message, unweakened:

```
REFUSED: scout task demo-1 has no report at ...\data\demo-1\report.md.
The report is the work product. Have the crewmate write it, or use --force after explicit discard approval.
EXIT=1
```

### 22.4 `--force` is unchanged

```
$ ./bin/fm-teardown.ps1 demo-1 --force
fm-teardown: --force discards work that has not landed, so it requires --approved-by "<who approved it>"
EXIT=2

$ ./bin/fm-teardown.ps1 demo-1 --force --approved-by "captain, 2026-08-14"
teardown demo-1 complete ...
EXIT=0
```

The held item is still in the backlog afterwards, unclosed: teardown discards
the task, never the captain's decision.

### 22.5 Suite and analyzer

`Invoke-Pester -Path ./tests` on this branch, in that worktree. Twice at the
branch point, and twice more after the rebase onto `2f24ea0`, where the tree is
`ad890ea` plus this section's own prose:

```
branch point, run 1   Tests Passed: 1533, Failed: 2, Skipped: 25   (1205s)
branch point, run 2   Tests Passed: 1535, Failed: 0, Skipped: 25   (1147s)
rebased, run 1        Tests Passed: 1611, Failed: 1, Skipped: 25   (1087s)
rebased, run 2        Tests Passed: 1612, Failed: 0, Skipped: 25
```

The rebased runs are 76 tests larger because `main` gained 13 commits in the
meantime; both were run with the two committed links materialized first, which
is the protocol 18.8 established.

The one failure in the third run was `bin/fm-teardown.ps1.exits 1 and preserves
the task when work has not landed`, expecting exit 1 and getting **-1** - a
child `pwsh` that did not run to completion, not a refusal that came out wrong.
It is a ship task, so it never reaches this change's gate at all; the file
passes on its own (15/15) and the failure is absent from the fourth run. Recorded
rather than dismissed, because an intermittent failure in this repo has twice
turned out to be a real race - what argues against that here is the -1 itself,
which is the process never producing an exit code rather than producing a wrong
one.

The analyzer sweep inside it (`FmAnalyzer.Tests.ps1`, 12 tests) is green in
both, so the repo-wide bar of zero findings at every severity holds with the new
area in it. The 25 skips are the pre-existing symlink-privilege ones: this
session does not hold `SeCreateSymbolicLinkPrivilege`, so those fixtures cannot
be built.

**The first run's two failures are the fresh-worktree clone artifact, not this
change**, and the second run is what proves it. They were `this checkout's own
instruction surface.is healthy` and `.keeps the contract reachable under both
names it is read by`. Git materialized this worktree with
`core.symlinks=false`, so `CLAUDE.md` was the 9-byte placeholder and
`.claude/skills` the 17-byte one that `CONTRIBUTING.md` already documents. Both
files were byte-identical to the base commit (`git diff 9464471 -- CLAUDE.md
.claude` empty), the captain's primary checkout has the real link and the real
junction, and the second run passed both without any change to the tree except
the one 18.6 describes.

### 22.6 A finding for the install area's owner

`tests/FmInstall.Tests.ps1` runs the real `bin/fm-setup.ps1` as a child process
with `-RepoRoot $script:RepoRoot`, which is **the checkout the suite is running
in**. Setup repairs the instruction surface of the root it is given, so in a
checkout whose links are already materialized - the captain's own - it is a
silent no-op and nobody has ever seen it. In a fresh Windows worktree it is not:
the run rewrote this worktree's `CLAUDE.md` from the 9-byte placeholder into a
51,707-byte hardlink of `AGENTS.md` and replaced the `.claude/skills`
placeholder with a symlink, mid-suite, and `git status` went from clean to two
modified tracked files.

Observed here at 01:21 and 01:30 while `FmInstall.Tests.ps1` was the file under
way. That is also the whole explanation of 22.5: `FmContract.Tests.ps1` sorts
before `FmInstall.Tests.ps1`, so the first run read the placeholders and failed,
the install suite then repaired them mid-run, and the second run found a healthy
surface and passed. The suite fixed its own two failures by mutating the
repository, which is a worse outcome than the failures were.

This also completes 18.6 and 18.8, which met the same two `FmContract` failures
and settled them by running `fm-setup.ps1` before Pester. That is the right
remedy and their measurement stands; what was missing is that the suite performs
that repair itself, on the checkout it is running in, whether or not anybody
asked it to.

The consequence is the one this port cares about most: a crewmate that merely
ran the test suite leaves uncommitted changes to tracked files, and its worktree
can then only be torn down with `--force`.

Undoing it has a sharper edge still, measured here. The repair points
`.claude/skills` at an ABSOLUTE path inside the same checkout, so the obvious
cleanup - `git checkout -- .claude/skills`, putting the tracked placeholder back
- followed the link while removing it and deleted all 19 `SKILL.md` files out of
`.agents/skills/`. They are tracked, so `git checkout -- .agents/skills` brought
them back, but a session that had done that and not looked would have been left
loading zero skills in a tree `git status` called clean.

Reported rather than fixed here, because it belongs to the install area and
rewriting another area's suite from this lane would collide with it.

---

## 23. A wedge alarm that fired on two healthy workers - `MEASURED (Windows 11)`

Observed on 2026-08-14, on the captain's Windows 11 laptop, by firstmate while
supervising two crewmates that were each running the whole Pester suite - about
23 minutes of work that produces no pane output while it blocks. For each of
them, roughly every four minutes and for over an hour:

```
stale: default:w9:p4 (idle 240s, possible wedge, escalation 1)
```

Every one was a false alarm. Both workers were healthy - token counts climbing,
commits landing - and both finished normally.

**What it was.** `Test-FmBusyTurnOverAge` bounds how long a pane herdr reports
`busy` may go without a completed turn, and ported bash's anchor unchanged:
`state/<id>.turn-ended`, falling back to `state/<id>.meta`. This port installs no
crewmate turn-end hook (section 14 of `AGENTS.md`), so `turn-ended` never exists
and the bound was really the age of the spawn record - which only grows, and
which no healthy worker can reset. Every busy crewmate crossed the 3600s bound
one hour after dispatch and then wedge-escalated on the stale cadence for the
rest of its life. The alarm was not tied to the silent stretch at all, which is
why it outlasted the 23-minute test run by a factor of three.

**What proves the pieces.** That herdr reports `busy` for a mid-turn claude here
is section 10.4 above, measured. That the bound now reads observed progress
instead of time since spawn is `tests/FmWatch.Tests.ps1`, whose
"does not wedge-alarm a pane that is silent while its agent is demonstrably
working" fails against the unfixed watcher and whose
"still wedge-alarms a pane that is silent while its agent is NOT working" passes
against both, so the alarm's own cadence is pinned rather than merely believed.

**What is NOT claimed.** The fix has not been re-observed against a live fleet on
Windows; the evidence for it is the suite, and the measurement above is the
defect, not the repair. `docs/supervision.md` owns the resulting contract.

### 23.1 Suite state this landed against, and what the 8 reds belong to

Whole directory, on the captain's Windows 11 laptop, at the commit this section
lands on:

```
Tests Passed: 1716, Failed: 8, Skipped: 25
tests/FmWatch.Tests.ps1   55 tests, all green
Invoke-ScriptAnalyzer -Path . -Recurse   FINDINGS=0
```

The 8 are **not this lane's**, and that is measured rather than asserted: every
one of them reproduces at `main` with this commit absent, run in the same
worktree.

```
tests/FmContract.Tests.ps1 at main   Passed 35, Failed 2
tests/FmInstall.Tests.ps1  at main   Passed 65, Failed 6
```

Both families come from the same thing this worktree started in: a
`core.symlinks=false` clone, where `CLAUDE.md` is 9 bytes of the text `AGENTS.md`
and `.claude/skills` is 17 bytes of the text `.agents/skills`, and setup has
never run to repair them. `FmContract` reads that placeholder directly;
`Invoke-FmDoctor` calls it `[missing]` and so reports the checkout unhealthy.

One operational note for the next lane, because it costs a tree: the install
suite still repairs the checkout it runs in, so a whole-directory run leaves
`CLAUDE.md` modified and `.claude/skills` deleted. Undoing it needs BOTH steps
and in this order - `git checkout -- CLAUDE.md .claude/skills` follows the
restored junction and deletes all 19 `SKILL.md` files, and
`git checkout -- .agents/skills` puts them back. Section 21.6 recorded the
side effect; this run confirms it survives the fix in `a798faa`.

---

## 24. The home redirect written over a checkout's own contract - `PROVEN (Windows 11)`

2026-08-14, Windows 11 Pro 10.0.26200, PowerShell 7.6.4, in the disposable
worktree `.treehouse/firstmate-win-e0ed2e/1/firstmate-win`, at `6d13d7f`.

### 24.1 The defect, reproduced end to end BEFORE the fix

`bin/fm-setup.ps1` was run exactly as the incident ran it - `-RepoRoot` naming
one tree and `-FirstmateHome` naming ANOTHER that is itself a full checkout,
with a synthetic 36,691-byte contract standing in for the primary's:

```
bin/fm-setup.ps1 -RepoRoot <worktree> -FirstmateHome <a checkout with its own AGENTS.md> `
    -SkipProfile -SkipHooks -KeepHomePointer -HomePointerPath <scratch>
```

```
before: AGENTS.md = 36691 bytes
  [updated] home redirect - <home>\AGENTS.md (and CLAUDE.md) redirect to <worktree>
after:  AGENTS.md = 37941 bytes
--- first 6 lines of what was that checkout's operating contract ---
  <!-- >>> firstmate-win home >>> -->
  # STOP - this is a firstmate HOME, not the firstmate checkout
```

**One detail of the incident report is corrected by this run.** The contract's
bytes are NOT truncated - `Set-FmInstallHomeRedirect` prepends and preserves
everything outside the markers, and the mirror to `CLAUDE.md` writes the same
text, so even a hardlinked pair stays consistent. What is destroyed is the
contract's FIRST instruction, which becomes "do no firstmate work from this
directory" and names a disposable worktree. Every session in that checkout then
opens on a stop order. It was reported as one `[updated] home redirect` line
among a dozen, and git is what recovered it.

### 24.2 The refusal, same invocation, AFTER the fix

```
fm-setup: error: the firstmate home '<primary>' is itself a firstmate-win checkout, with its own '<primary>\AGENTS.md'.
       Setup writes a stop-and-redirect block at the TOP of a home's AGENTS.md and mirrors it to CLAUDE.md,
       so this run would have overwritten the first thing every session in that checkout reads. Refusing;
       nothing was written.
       To set THAT checkout up, name it as the checkout: bin/fm-setup.ps1 -RepoRoot '<primary>'
       To give '<worktree>' a separate home, name a directory that is not a checkout.
exit code: 1
after:  AGENTS.md = 36691 bytes (unchanged: True)
home layout written: False
```

Byte-identical, and `config/backend` was never created: the assertion sits at
`Install-FmHome`'s gate, ahead of the prerequisite check, so a refused run
writes nothing at all. It is asserted a second time inside
`Set-FmInstallHomeRedirect`, so the guard belongs to the destructive act rather
than to one caller.

### 24.3 The suite

`Invoke-Pester -Path ./tests` on this branch, with the checkout set up (see
section 17's precondition - `Set-FmAgentsMemory` and `Set-FmClaudeSkillsLink`
were run against it once first): **1730 passed, 0 failed, 25 skipped**, in
1375s, and the repo-wide analyzer sweep inside the suite reports nothing at
Error, Warning or Information. All 6 new install tests pass.

### 24.4 One finding this run leaves open

**An intermittent lost increment in the lock area.** In a whole-suite run at the
pre-rebase base, `One holder, proven with real processes / never lets two
processes increment a counter at once` read 35 where 36 increments were made.
That test's two false-attribution guards - a worker that threw, and a worker
still running at the deadline - both passed, so it is a genuine lost increment
and not a timeout. It did NOT reproduce in 3 idle runs of that test alone, nor
in 6 runs under 6 parallel CPU-burn jobs, nor in the two later whole-suite runs.
This branch touches no locking code. It is the same whole-suite-only class as
section 16, and an intermittent lost increment is a real mutual-exclusion defect
until something proves otherwise - one green run does not. Left open for the
lock area's owner.

---

## 25. The spoken alert, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

`bin/fm-say.ps1` and `config/voice` (`docs/voice-windows.md`), on
`fm/voice-say` over `fb1931d`. Run in a disposable worktree against a temporary
home on 2026-08-14. Everything below was heard as well as printed.

### 25.1 The engine, and the five voices that are actually installed

```
installed: Microsoft Hazel Desktop, Microsoft Zira Desktop, Microsoft George,
           Microsoft Hazel, Microsoft Susan
```

No install, no service, no network: `Add-Type -AssemblyName System.Speech` and a
`SpeechSynthesizer` are enough. Note the names - two pairs share a prefix
(`Microsoft Hazel` and `Microsoft Hazel Desktop`), which is why the matcher is
exact rather than a prefix match.

### 25.2 The entry point, off and on

```
=== 1. voice off (no config/voice) ===
fm-say: not spoken - the voice is off (create config/voice to turn it on)
exit=0
=== 2. voice on ===
exit=0 elapsed=7.4s
=== 3. usage ===
usage: fm-say.ps1 <message...>
exit=2
```

With no `config/voice` the machine is silent and the caller is not failed: one
line on stderr and exit 0. With `config/voice` present the sentence was spoken
aloud, in the configured voice. The 7.4 seconds is the whole child process -
PowerShell startup, module import, then the utterance.

### 25.3 The four config paths, measured

A 217-character message, spoken through `Invoke-FmSay`:

```
[voice=Microsoft Zira Desktop / rate=1]  spoken=True  voice='Microsoft Zira Desktop' rate=1  truncated=True  12.8s
[voice=Nobody At All]                    spoken=True  voice=''                       rate=0  truncated=True  15.2s
[rate=99]                                spoken=True  voice=''                       rate=10 truncated=True   5.6s
[off / voice=Microsoft Susan]            spoken=False reason=off                              truncated=False 0.0s
```

Each row is one of the requirements, heard: the configured voice is used, an
unknown voice name falls back to the default and still speaks, an out-of-range
rate is clamped to 10 rather than refused (audibly faster - 5.6s against 12.8s
for the same text), and `off` says nothing at all.

The full-length utterances took 13 to 15 seconds, which is what sets the
30-second default deadline: it clears a full-length message with room for a
slower rate.

### 25.4 The truncation, heard

The same 217-character message was spoken as:

```
the payments fix is ready for your review, and the second change to the checkout
flow is waiting behind it, and there is a decision about the refund window that
nobody has made yet, and the release, message truncated
```

Cut at a word boundary, and it says that it was cut. The captain cannot re-read
a spoken sentence, so a silent truncation would be indistinguishable from the
news simply ending there.

### 25.5 The whole suite, on Windows, at this branch

```
Tests completed in 1395.85s
Tests Passed: 1764, Failed: 0, Skipped: 25, Inconclusive: 0, NotRun: 0
```

42 files, zero failures, including the repo-wide analyzer sweep
`tests/FmAnalyzer.Tests.ps1` runs. `tests/FmVoice.Tests.ps1` contributes 34 of
those and makes no sound while doing it.

Two things that run holds honest. **The run before it failed one test**, and it
was this area's fault: `FmContract`'s "lists every not-ported capability"
asserts section 14 still names the `voice channel`, and the first rewrite of
that bullet dropped the phrase. The test was right and the wording was fixed -
worth recording because it is exactly the class of thing a green suite is
supposed to catch, and did. **And the two `FmContract` instruction-surface
tests need a set-up checkout**, as section 17 already notes: this run was made
with `CLAUDE.md` mirroring `AGENTS.md`, and re-materializing that mirror after
editing `AGENTS.md` is part of running the suite in a task worktree.

### 25.6 The `-h` measurement, and what it found

PowerShell attaches comment-based help to a SCRIPT only when the block carries a
`.SYNOPSIS`/`.DESCRIPTION` keyword AND is separated by a blank line from
`#requires` and from `param()`. Probed both ways on this machine: without the
blank lines `Get-Help` prints the syntax line alone, and with a keyword-less
block it prints the syntax line whatever the spacing. `bin/fm-say.ps1` carries a
comment saying so, because the failure is silent - the script still runs, and
`-h` just stops being worth typing. Three existing entry points are in that
state, recorded in section 17.

### 25.7 What was NOT proven here

- **Nothing calls `fm-say` automatically**, so there is no evidence of an
  escalation being spoken - by design. The capability shipped alone.
- **`fm-ask` does not exist**, so nothing was answered by voice.
- **The timeout path was not provoked on real hardware.** It is covered by a
  test at the seam, and no engine on this machine wedged long enough to see it.
- **A machine with no audio device at all was not tested**, only a machine with
  no speech assembly (simulated at `Add-Type`, in the suite).

## 26. The spoken question, on the captain's Windows 11 laptop - `PROVEN (Windows 11)`

`bin/fm-ask.ps1`, `Invoke-FmAsk` and the two recognizer seams
(`docs/voice-windows.md`), on `fm/voice-ask` over `29bbb80`.
Run in a disposable worktree against a temporary home on 2026-08-15.
The spoken half was heard as well as printed.

### 26.1 The engine, and the one recognizer that is actually installed

```
MS-2057-80-DESK | en-GB | Microsoft Speech Recognizer 8.0 for Windows (English - UK)
```

No install, no service, no network, exactly as the synthesizer needed none:
`Add-Type -AssemblyName System.Speech` and a `SpeechRecognitionEngine` are
enough.
One recognizer, and its culture is `en-GB` rather than the machine's input
language - which is why the engine is constructed from a named installed
recognizer and the grammar is built in that recognizer's own culture.
The default constructor picks by input language and throws when nothing
installed matches it.

Note also what `RecognizerInfo.Name` returns here: `MS-2057-80-DESK`, the engine
id rather than a name a person would read.
`Get-FmInstalledSpeechRecognizer` returns `Description` for that reason.

### 26.2 The closed grammar, measured against a `yes`/`no` option set

Each word was synthesized to a WAV and fed to the recognition engine, so these
are real recognitions with no microphone and no human in the loop:

```
spoke 'yes'                       -> heard 'yes' at 0.98
spoke 'no'                        -> heard 'no'  at 0.91
spoke 'maybe'                     -> nothing accepted
spoke 'the payments fix is ready' -> nothing accepted
```

**This is the measurement the 0.75 floor is set against.** An in-grammar word
lands well above it, and an out-of-grammar word produces nothing at all rather
than a confident wrong answer - so the floor sits in the gap rather than in the
middle of the range, and refusing below it costs a correct answer nothing on this
hardware.

### 26.3 The entry point, end to end

Against a home carrying `voice=Microsoft Hazel Desktop` / `rate=0`:

```
=== 1. voice off (no config/voice) ===
answer=
heard=
confidence=0.00
reason=off
fm-ask: no answer - the voice is off (create config/voice to turn it on)
exit=0

=== 2. voice on, question spoken aloud, nobody answers ===
answer=
heard=
confidence=0.00
reason=silence
fm-ask: no answer - nothing was said within 6 seconds
exit=0 elapsed=15.7s

=== 3. merge confirmation ===
answer=
heard=
confidence=0.00
reason=refused
fm-ask: no answer - a spoken answer is not the captain's explicit word for 'merge'
exit=1
```

Row 2 is the whole channel working: "Ready to land?" was spoken aloud through the
synthesizer, the recognizer then listened for six seconds, and the bounded wait
returned cleanly with no answer.
The 15.7 seconds is the entire child process - PowerShell startup, module import,
the utterance, then the listening window.

Row 3 is the authority boundary, and it holds with the voice OFF as well as on:
the refusal is evaluated before the config is read, so a caller cannot discover it
only on a machine that talks.

**Row 2 also caught a defect no test could.** It first returned
`reason=unavailable` - see 26.4.

### 26.4 The defect a real run found, and a green suite could not

`Invoke-FmSpeechListenRequest` reported `unavailable` - "no speech recognizer,
microphone or audio device is available" - on a machine that had all three, when
the truth was that nobody had said anything.

The cause was one expression:

```powershell
$received = @(Get-Event | Where-Object { $sources.Contains($_.SourceIdentifier) })[0]
```

Under `Set-StrictMode -Version Latest` indexing an EMPTY array does not answer
`$null`; it throws `Index was outside the bounds of the array`.
Every poll of a quiet microphone therefore threw, the seam's own `catch` turned
that into `unavailable`, and silence was reported as broken hardware.
The same `[0]` form on `InstalledRecognizers()` had the same fault.
Both are now `Select-Object -First 1`.

**Why the suite could not see it.** The seam is mocked in every test that reaches
it - which is the design, and is what lets the suite pass with no microphone - so
the seam's own body is executed by exactly one test, the one that replaces
`Add-Type` with a throw and never reaches the polling loop at all. A seam every
test replaces is a seam no test executes. `docs/voice-windows.md` now says so
where someone about to change one will read it.

This is also the second time this port has been bitten by a strict-mode surprise
inside a `catch`-wrapped verdict function: the failure is silent by construction,
because the wrapper's whole job is to turn errors into answers.

### 26.5 The comma the documented invocation needed

`./bin/fm-ask.ps1 "Ready to land?" -Options yes,no` is the documented form, and it
reached the script two different ways.
Typed in a PowerShell session, `yes,no` is an array literal and arrives as two
elements.
Run through `pwsh -File` - which is how a herdr pane, a Claude hook, or any
non-PowerShell caller reaches it - it arrives as one string, `yes,no`, and bound
unsplit it is a ONE-option grammar.
That is the degenerate set `Invoke-FmAsk` refuses, so the documented invocation
failed with `reason=invalid` for everyone who was not already in PowerShell.

Found by the entry-point tests, which run real `pwsh -File` children for exactly
this class of difference.
The script now splits on commas, and a test asserts the split rather than the
symptom.

### 26.6 The whole suite, on Windows, at this branch

```
Tests completed in 2235.62s
Tests Passed: 1793, Failed: 8, Skipped: 25, Inconclusive: 0, NotRun: 0
```

43 files, including the repo-wide analyzer sweep `tests/FmAnalyzer.Tests.ps1`
runs.
`tests/FmVoice.Tests.ps1` contributes 71 of those, 37 of them fm-ask's, and makes
no sound and opens no microphone while doing it.

**All eight failures are section 17's known set-up-checkout dependency, and this
run made that provable rather than asserted.** Every one is either a
`MirrorState`/`ClaudeSkillsState` assertion or a `$doctor.Healthy` check against
the REAL repo root, in a fresh task worktree where `CLAUDE.md` is still the
9-byte git placeholder and `.claude/skills` the 14-byte one. Six of them are in
`FmInstall`, which section 17 did not previously name - it counted only the two
in `FmContract`.

The proof is in the run itself. `FmInstall`'s own "the entry points" block runs
`fm-setup.ps1 -RepoRoot <this checkout>` and repairs both links as part of its
job, so by the end of the run the surface was materialized. Re-running the two
files against that repaired checkout:

```
tests/FmContract.Tests.ps1   Tests Passed: 37, Failed: 0
tests/FmInstall.Tests.ps1    Tests Passed: 77, Failed: 0
```

Zero failures, from the same code. Both files were then restored to their tracked
placeholders - by unlinking the junction with `Directory.Delete` FIRST, because
`git checkout -- .claude/skills` on a materialized link deletes the link's TARGET
and takes `.agents/skills` with it, as `CONTRIBUTING.md` warns.

`FmAnalyzer`, `FmVoice` and `FmModuleAssembly` were re-run last, after the final
edits: 112 passed, 0 failed. The analyzer bar is zero findings at every severity
and `fm-ask.ps1` is inside the enumerated sweep, so it is covered rather than
skipped.

The arithmetic cross-checks against the branch this one rebased onto, which was
measured on a set-up checkout: `7be4760` reports 1764 passed, 0 failed, 25
skipped. This branch adds 37 tests to `FmVoice`, and 1764 + 37 = 1801 = the 1793
passed plus the 8 environmental failures above. Nothing else moved.

### 26.8 Two failures this branch inherited from main, and did not cause

Rebasing onto `7be4760` brought in `bin/fm-bridge.ps1`, and with it two failures
that are not this branch's:

```
FmAnalyzer       fm-bridge.ps1:137 [PSAvoidUsingEmptyCatchBlock]
FmModuleAssembly fm-bridge.ps1: does not dot-source fm-module-load.ps1 with -RequiredCommand
```

**Attributed by reproduction, not by argument.** Both were re-run at a detached
`7be4760` - main's tip, without this branch's commit - and both fail there
identically: 39 passed, 2 failed. `bin/fm-ask.ps1` clears both gates.

They are real and worth fixing by their owner: the analyzer bar is zero findings
at every severity, and the module-load prelude is what makes a `bin/` script work
in a shell that loaded no profile, which is exactly the shell `fm-bridge.ps1`
will be launched from. Left here rather than fixed, because that file is another
lane's in-flight work and this branch has no business editing it.

### 26.7 What was NOT proven here

- **A human answering out loud.** The mic on this machine has no acoustic path to
  its own speakers, so an attempt to have `fm-say` answer `fm-ask`'s question
  through the room returned silence - correctly. The recognition itself is proven
  in 26.2 through a WAV rather than through a microphone, so what remains
  unproven is the capture device, not the grammar, the matching or the
  confidence.
- **A machine with no recognizer, and a machine with no microphone.** Both are
  covered by tests at the seam and neither was reproduced on hardware; this
  machine has both.
- **Nothing calls `fm-ask` automatically**, so there is no evidence of an
  escalation being asked aloud. The capability ships alone, by design.
- **The permissive authority behaviour was not built**, deliberately: the captain
  has an open decision on whether a spoken answer may ever approve a merge, and
  this branch implements only the conservative side of it.

## 27. The private Telegram channel, built and tested with no bot - `PROVEN (Windows 11), OFFLINE ONLY`

`bin/fm-tell.ps1`, `bin/fm-tg-poll.ps1` and `module/Firstmate/*/FmTelegram.ps1`
(`docs/telegram-windows.md`), on `fm/tg-build` over `03fe14d`.
Run in a disposable worktree on the captain's Windows 11 laptop on 2026-08-17.

**Read the limit first, because it is the whole shape of this section.**
No bot was created, no token was obtained, no real message was sent, and nothing
in this task reached `api.telegram.org` at all.
The captain has not decided whether to create the bot, so everything below was
executed against a mocked endpoint or against a loopback port nothing listens on.
What is proven is the code path, the refusals and the discipline; what is
untouched is the real endpoint.

### 27.1 What was executed

The area's own suite, which needs neither a token nor a network:

```
tests/FmTelegram.Tests.ps1   Tests Passed: 75, Failed: 0
```

`Invoke-FmTelegramApi` is the one function in the area that opens a socket, so
every test that would reach it mocks exactly that one - the same discipline the
voice channel applies to its four speech-engine seams.
The seven entry-point tests cannot mock anything, because a child process cannot
be mocked, so each is given either a home with no token or
`FM_TELEGRAM_API_BASE=http://127.0.0.1:9`, a loopback port nothing listens on.
That is what makes the failing-send test a REAL `Invoke-RestMethod` failure
rather than a simulated one, with no packet leaving the machine.

The whole suite, on this branch, after the commit:

```
Tests Passed: 1878, Failed: 0, Skipped: 25   (43 files, 1878s)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1   ->  0 findings
```

Two things about that run should be said rather than left to be inferred.
It was made in a checkout whose `CLAUDE.md` and `.claude/skills` had already been
materialized - `tests/FmInstall.Tests.ps1` runs `fm-setup.ps1` against this
checkout as part of its own job - so it is not measuring an unrepaired Windows
clone, and section 26.6's set-up-checkout dependency is neither reproduced nor
contradicted here.
An earlier run in the same worktree, before that repair and before two analyzer
findings in this branch's own new files were fixed, reported 11 failures; the two
analyzer ones are named and settled, and the rest were not individually captured,
so this section claims only the clean run above.

### 27.2 The token-leak assertion, which is the one worth naming

The scout measured that Telegram carries the token in the URL path and that both
`Invoke-RestMethod -Verbose` and `$_.TargetObject.RequestUri` print it verbatim.
So the test does not merely check that nothing printed a token - it first proves
the token WAS used, then proves it did not escape:

```
Should -Invoke Invoke-FmTelegramApi -ParameterFilter { $Url -like "*$Token*" }   # it really was used
$sent | Format-List | Out-String     ->  no match for the token, or for its secret half
$sent | ConvertTo-Json -Depth 5      ->  no match for either
```

and at the entry point, as a real child process against the dead loopback port:

```
fm-tell.ps1 ... -> exit 0, stderr "fm-tell: not sent - the link could not be reached, after 1 attempt(s)"
stdout + stderr           ->  no match for the token, or for its secret half
every file under state/   ->  no match for the secret half
```

The fixture token is literal nonsense (`9988776655:AAF-NOT-A-REAL-TOKEN-DO-NOT-USE`).

### 27.3 The refusal, proven to be in the code and not in a setting

The tier-3 refusal was exercised through four different ways of trying to widen
it, and all four still refuse:

```
-MaxTier 3 / 4 / 99 / [int]::MaxValue        -> refused, tier 3
config/telegram-authority allow-tier=3       -> refused, and warned "allow-tier 3 is refused"
config/telegram-authority allow-tier=99      -> refused
no config/telegram-authority at all          -> refused
config/telegram-authority full of nonsense   -> refused
```

Narrowing still works in the direction it is meant to: `allow-tier=1` refuses a
steer and still answers a question, and `allow-tier=0` is clamped up to 1, so
asking how things stand can never be switched off.

### 27.4 The singleton, proven across two real processes

The Pester process takes the poller lock itself - so the holder is unarguably
alive and the refusal under test is the singleton rather than stale-owner
recovery - and then `bin/fm-tg-poll.ps1` is launched as a real child:

```
fm-tg-poll.ps1 -MaxCycles 1 -> exit 0
stderr: fm-tg-poll: not listening - another one is already listening; two would take each other's messages
```

The in-process half also asserts the refused poller left the holder's lock
untouched on its way out, and that a poller which finishes releases the lock.

### 27.5 The decision closure, end to end

The defect the scout found is that the wake drain prints a `-ResolveKey` flag
`bin/fm-send.ps1` does not have, and that entry point absorbs the flag into the
message body rather than refusing it - so the command it prints closes nothing.
This does not change `fm-send.ps1`; it gives the closure an owner that works:

```
needs-decision [key=api-shape]: flat or nested response
resolved [key=api-shape]: use the flat one          <- written by the answer from the phone
Get-FmOpenDecisionScan -> 0 open
```

Proven for the single-open case, for a message naming `key=<slug>` while two are
open, and - equally - for the case it REFUSES to guess: two open and none named
closes nothing, records the words, and says so.
A tier-1 question never closes a decision.

### 27.6 What was NOT proven here, and cannot be without the captain's decision

- **Every call against a real bot.** `getMe`, a real long poll, a real
  `sendMessage`, the API's own 4096 rejection, the 429 back-off, and the
  two-poller conflict on one token. All need a bot and a token.
- **The two-poller conflict itself remains inferred**, exactly as the scout
  reported it. The singleton lock is cheap insurance against a failure that would
  be very hard to diagnose, not a fix for a measured one.
- **Nothing is wired into the escalation path**, deliberately, so there is no
  evidence of an escalation reaching a phone. The capability ships alone.
- **The permissive authority behaviour was not built**, deliberately: the captain
  has an open decision on where the tier line sits, and this branch implements
  only the conservative side of it.
- **The channel is session-scoped.** A message sent while nothing is running
  waits up to 24 hours on Telegram's servers and is then dropped. That is a
  property of the design, not a gap in the testing, and it stays true until the
  long-lived service exists.

---

## 28. The concurrent-increment check was not flaky - the lock was - `PROVEN (Windows 11)`

This settles the finding section 24.4 left open.

**Verdict: the lock.**
`FmLock.Tests.ps1`'s "never lets two processes increment a counter at once" read 35 where 36 increments were made, on a busy machine, and passed four times in isolation - the classic shape of a flaky test.
It is not flaky.
Two processes really were inside one critical section, the counter really did lose a write, and the mechanism was captured in the act.

Run on 2026-08-17, Windows 11 Pro 26200, 12 cores, PowerShell 7.6.4.

### 28.1 Reproduced deliberately, not by chance

Section 24.4 could not reproduce it because it ran the test as written.
The shape is right - workers take the lock, read a counter, sleep 5ms, write it back - but 3 workers x 12 iterations is 36 chances, and the defect fires at roughly one lost increment per 1200.
Scaled to 6 worker processes x 100 iterations per run, with 12 to 16 CPU-spinning `pwsh` processes as competing load, it reproduces on demand.

The workers were instrumented so a lost increment could be attributed rather than guessed:

| Signal | What it proves |
| --- | --- |
| `Unlock-FmLock` returning false | the pid file no longer named this worker when it released, so something took the lock off a live holder |
| the same counter value read twice | two processes were inside the critical section together |
| the worker's own throws and unfinished jobs | a worker that died never made an increment, which is NOT a mutual-exclusion defect |

Four runs at that scale, 2400 increments, against the code as it stood:

```
Run Seconds Expected Final Lost WorkerErrors StolenLocks DupReads
  1     121      600   600    0            0           4
  2     126      600   599    1            0           5  value 110 read 2x
  3     159      600   599    1            0           1  value 358 read 2x
  4     135      600   600    0            0           5
```

Fifteen live holders lost their lock, two increments were lost, and each loss came with two workers reading the same counter value.
No worker threw and none was unfinished, so the losses are not workers dying - which is exactly what section 24.4's guards already established for the original sighting.

### 28.2 The defect: a stale verdict about nobody, breaking whoever was there

`Get-FmLockInfo` took the pid file's AGE before its CONTENT.
A release is exactly one delete, so the pid file can vanish between the function's existence check and the age read, and `Get-FmPathAge` answers its documented 999999 sentinel - "very old", so that no caller mistakes an unreadable path for a fresh one - for a path it cannot read at all.
A lock that had just been released therefore read as a holder that was unreadable and 999999 seconds old, which is to say `stale`.

That verdict has no process id in it, because no pid was parsed.
`Invoke-FmLockBreak`'s guard - break only the holder you proved stale, the guard its own help calls "the whole safety" - took a process id and **skipped itself entirely when it got none**.
So exactly the verdicts with the least evidence behind them broke whatever pid file happened to be there by the time the break ran, which under contention is the next process's live claim.

Instrumented, the whole chain lands in two lines from one worker:

```
36972 12:34:15.9194255 INFO-UNREADABLE state=stale age=999999 raw=[] exists=True now=[35908]
36972 12:34:16.2208986 BREAK   holder=[]  age=999999 victim=[35908] result=True
```

A stale verdict naming nobody, breaking a lock that live holder 35908 was holding.
The victim's own log line is the other half:

```
i=40 pid=35908 unlock=False
```

35908 released and found the pid file no longer named it - silently, with nothing thrown, which is why this has always looked like a flaky test rather than a defect.

### 28.3 The fix

Two changes, both in `module/Firstmate/Private/FmLock.ps1`:

- **The pid file is read before its age is taken.** A pid file that is not there when it is read is the same answer as a pid file that was not there one statement earlier, which is `free`. The age sentinel is out of the decision entirely rather than merely less likely to be hit. A read that THREW is a different thing - something is there and cannot be read - and keeps the existing grace treatment, but records no holder.
- **The break is conditional on the exact record judged, not on a parsed pid.** `Get-FmLockInfo` publishes the exact text it read as `.HolderRecord`, `Request-FmLock` passes it, and `Invoke-FmLockBreak` refuses outright when it is `$null`. When the text is a pid it is the pid, so legitimate stale recovery is unchanged; when it is blank or malformed the break still only removes the same blank or malformed claim that was judged.

Two tests pin them, and both were confirmed to FAIL against the code with only these changes backed out:

```
[-] reads a pid file that went away as free, not as a very old stale one
    Expected: 'free'   But was: 'stale'
[-] refuses a break for a stale verdict that observed no holder at all
    Expected $false, because a verdict that named nobody may not evict somebody, but got $true
```

Every other test in the file passed with the fix backed out, so these two are the only thing guarding it.

After the fix, at the same scale and under the same load: **4200 increments across seven runs, zero lost, zero duplicate reads.**
Two live-holder evictions remain in that total, both in one run, and they are 28.4 rather than this defect.

### 28.4 A SECOND defect, reported not fixed: a torn pid/identity read

**FIXED - see section 28.7**, which took the layout decision this section says it could not.
The diagnosis below is left exactly as it was traced, because it is what the fix was built from.

The evictions that survive the fix have a different mechanism, and it is reported here rather than fixed because the brief for this work scopes out redesigning the locking approach - which every sound fix for it requires.

`Get-FmLockInfo` reads the `pid` file and then reads the `pid-identity` sidecar as a separate operation.
Between those two reads the lock can be released and re-taken any number of times, so the identity it compares can belong to a **different holder** than the pid it compares it against.
The pid-reuse guard then fires on a live, legitimate holder and reports it stale - and this verdict DOES carry a process id, so the break's guard passes and the eviction succeeds:

```
9868 12:59:20.2672849 INFO-DEAD pid=24792 age=0 rec=[24792]
       recordedIdentity=[windows-starttime=639225683282158377 name=pwsh]
       observedIdentity=[windows-starttime=639225683322273488 name=pwsh]
       getprocess=[found] plainAlive=True
9868 12:59:20.3834679 BREAK-OK rec=[24792]
```

`getprocess=[found] plainAlive=True` - process 24792 was alive and holding the lock.
The recorded and observed start times differ by 4.0 seconds because they belong to two different `pwsh` workers, and that same recorded token turns up against a second pid elsewhere in the same trace, which is the mis-pairing itself.

**Why no fix here.** The pairing cannot be made provable by re-reading: pid, identity, pid can return the same pair through an A-B-A handover, so a re-read only narrows the window, and narrowing a window is what this task exists to avoid. The sound fixes each change something out of scope:

- bind the identity to its pid inside the sidecar's content, which a Linux firstmate sharing the home would then misread as a mismatch and steal from;
- key the sidecar by pid (`pid-identity.<pid>`), which adds a child to the record layout that `docs/foundation.md` documents as matching bash;
- drop the sidecar and prove reuse from the pid file's claim time against the process's start time - sound, needs no sidecar at all, and changes the staleness mechanism outright.

The last is the strongest and is the recommended direction, but choosing it is a cross-platform compatibility decision above an implementation worker.

**Rate.** Three evictions in 4800 post-fix increments (0.06%) against fifteen in 2400 before it (0.63%), so this path is roughly a tenth of the original and did not lose an increment in any post-fix run.
It still can: an eviction that lands earlier in the victim's critical section loses its write.

**Why the concurrent-increment test was not tightened to catch it.** Asserting that every release succeeded would make that test catch an eviction directly, rather than only when one happens to lose a write - but it would then fail intermittently while 28.4 is open, and a red suite is not an acceptable way to hold a finding. That assertion belongs with the fix for 28.4.
That assertion landed with it: section 28.7.

### 28.5 Suite and analyzer, on the rebased tree

```
Invoke-Pester -Path ./tests
  1918 passed  0 failed  25 skipped        (44 files, 1980s)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  0 findings
```

The 25 skips are the pre-existing symlink-privilege ones.
Two earlier runs got there:

- **Run 1 failed 9**, all of them the fresh-worktree clone artifact sections 22.5 and 22.6 already own - `FmContract`'s own-instruction-surface trio plus six `FmInstall`/`Invoke-FmDoctor` tests that read the same surface. `FmInstall.Tests.ps1` repaired the surface mid-run, exactly as 22.6 describes, and re-running that file alone afterwards passed all 77. Nothing in this work touches those paths.
- **Run 2 failed 1**, and that one was real: `hands the lock on when a holder is killed outright` failed in its own CLEANUP with a terminating `IOException: The pipe is being closed`. `Remove-Job -Force` stops the job first, this test has just killed that job's process on purpose, and `-ErrorAction` does not suppress a terminating error. Every assertion in the test had already passed. The reap is now wrapped; no assertion was relaxed and no timing value was touched.

### 28.6 One red herring, recorded so it is not chased twice

An instrumented run showed a worker throwing `this process already holds the lock` for 91 consecutive iterations and losing 91 increments.
That was **not** the lock.
It was a bug in the throwaway instrumentation: `(try { ... } catch { ... })` is not a valid PowerShell expression, so the diagnostic line raised `The term 'try' is not recognized` and aborted `Unlock-FmLock` before it cleared its held-lock table entry.
Useful anyway - the diagnostic only runs on the release-refused path, so its failure is independent proof that 24792's release WAS refused, which is the victim half of 28.4.


### 28.7 The torn pid/identity read, fixed - `PROVEN (Windows 11)`

28.4 reported this one rather than fixing it, because every sound fix changed the lock record's layout and that was a decision above that task.
This is the fix, with that decision taken: **the lock record gains a child**, stated in full below, and a record written by the old code still reads correctly.

Run on 2026-08-18 on the same laptop as the rest of section 28 - Windows 11 Pro 26200, 12 cores, PowerShell 7.6.4 - on `fm/lock-identity`.
Every number below was measured over `835bc53`; the branch was then rebased onto `caa511d`, which `main` had advanced to, and the lock, module-assembly, analyzer and contract suites were re-run there.

#### It does not reproduce by chance, so the window was opened on purpose

At exactly 28.1's scale and load - 6 worker processes x 100 iterations, 14 CPU-spinning `pwsh` processes - the code as 28.4 left it, unmodified, lost nothing across **4800 increments in 8 runs: 0 lost, 0 evictions, 0 duplicate reads**.
That is not the defect being absent.
The window is two adjacent statements inside `Get-FmLockInfo`, and 28.4's own `INFO-DEAD` and `BREAK-OK` trace lines are proof that the runs which caught it had that function instrumented - which is what held the window open long enough to be entered.

So it is opened deliberately here, and identically on both sides.
The same three insertions go into a throwaway copy of the tree BEFORE the fix and a throwaway copy AFTER it: log what the pid read observed, hold 1ms, log what the identity read observed together with the identity actually observed for that pid, and log every break that succeeded.
Nothing else differs between the two runs, and neither copy is what ships.

| | Increments | Mis-paired comparisons | Breaks that succeeded | Live holders evicted | Increments lost |
| --- | --- | --- | --- | --- | --- |
| Before the fix | 2400 (4 runs) | 74 | 2 | 2 | 0 |
| After the fix | 4800 (8 runs) | **0** | **0** | **0** | **0** |

A mis-paired comparison is counted from the trace rather than inferred: an inspection whose recorded identity differs from the identity observed for the pid it read, while that pid is ALIVE.
That is the defect itself, and it is what went to zero - the evictions are its consequence.

#### The eviction, captured again

One breaker's trace, before the fix, with the mis-pairing provable from within the same file.
Two tenths of a second earlier the same inspector read the same holder and agreed with itself:

```
34204 05:35:01.4024365 INFO-ID rec=[38056] recorded=[windows-starttime=639226280617915325 name=pwsh]
                                            observed=[windows-starttime=639226280617915325 name=pwsh] plainAlive=True
34204 05:35:01.5260384 INFO-PID rec=[38056]
34204 05:35:01.5944894 INFO-ID rec=[38056] recorded=[windows-starttime=639226280620459884 name=pwsh]
                                            observed=[windows-starttime=639226280617915325 name=pwsh] plainAlive=True
34204 05:35:01.9229645 BREAK-OK rec=[38056]
```

The recorded token in the second reading belongs to a different worker.
`plainAlive=True` says 38056 was alive and holding the lock, and the victim's own log line is the other half:

```
i=12 pid=38056 read=54 unlock=False
```

#### The fix: an identity record named after the process it describes

Two things had to be true at once, and neither is a timing argument.

- **`pid-identity.<pid>` is published BEFORE the claim.**
  The pid file is the lock, so the instant it names a process an inspection may go looking for that process's identity, and publishing after winning leaves a window where the holder is live and its record is not there yet.
  It is published only when the lock looks free, because `CreateNew` can only win then.
  Publishing over an existing claim would be actively wrong: a lock recorded by a DEAD process whose id this process has since been given would gain a matching live record, read as held by us for ever, and be recoverable by nobody.
- **The record is RETAINED for as long as its process lives.**
  It describes a process, not a claim: release does not remove it, a break does not remove it, and only `Clear-FmLockResidue` does, once that process is gone.

Together those make the answer independent of WHEN the read happens, which is what re-reading could never do: a record named `.<pid>` can only have been written by a process holding that id, and it is there whenever that process is.
`pid`, `pid-identity`, `fm-home`, `role` and `watcher-path` keep their bytes, so a bash reader `cat`ting the lock sees exactly what it saw before; the new child is one bash does not read, exactly as `state/.lock.identity` already is.

#### Retention is load-bearing, and that was measured, not reasoned

The first version of this fix removed the keyed record on release, which looked tidy and was wrong.
Measured at the same scale with the same instrumentation: **2400 increments, 16 mis-paired comparisons, 2 live holders evicted and 1 increment genuinely lost** - the last of those the first lost increment any run in section 28 has produced since 28.3.

The mechanism is one step removed from the original.
An inspection read the pid file just before that holder released, then found no record for that pid - the release had just deleted it - and fell back to the unkeyed sidecar, which by then belonged to the NEXT holder.
A fallback that exists for old records had become reachable by new ones.
Retention closes it: the record cannot go missing while its process is alive, so the fallback is reachable only by a claim that never had one.

#### What a record written by the old code does now

A claim carrying only `pid` and the unkeyed `pid-identity` - what the previous version wrote, and what bash writes - is read from that sidecar, exactly as before.
It reads as the holder it names, and it keeps its pid-reuse guard: `recovers a lock whose process id was recycled by an unrelated process` stages precisely that shape and still recovers.
An old record is never read as "no holder", and never as stale for lacking the new child.

#### The coverage, and it was confirmed by backing the change out

Four tests were added and one was tightened.
With `module/Firstmate/Private/FmLock.ps1` reverted to `835bc53` and the tests left as they are, three of the four fail and the rest of the file's 50 tests pass:

```
[-] does not evict a live holder over an identity that belongs to a different one
    Expected: 'held'   But was: 'stale'
[-] still proves a recycled process id stale from the record that names it
    Expected: 'stale'  But was: 'held'
[-] sweeps an identity record whose process is gone and keeps one whose process is alive
    CommandNotFoundException: The term 'Clear-FmLockResidue' is not recognized
```

The first two are the fix stated as a pair: give the unkeyed sidecar and the pid-keyed record DIFFERENT values and the lock must follow the keyed one, whichever way round the disagreement points.
That is the property, and either half alone could be passed by accident.
The fourth test - `reads a lock claimed before the pid-keyed record existed` - passes both with and without the fix on purpose: it is the backward-compatibility guard, and a guard that only holds after a change is not one.

`never lets two processes increment a counter at once` is the tightened one.
It now asserts that **every release succeeded**, which is the only trace an evicted holder leaves, and it takes the lock directly rather than through `Invoke-FmWithLock` so that result is visible.
28.4 held that assertion back because it would have failed intermittently while this defect was open.
It does not fail with the fix backed out either - 36 increments is far too few to enter the window, which is the whole reason 28.1 had to build a bigger harness - so it is a standing guard rather than back-out coverage, and it is recorded as such.

#### What is NOT fixed here

One window survives, narrowed to something compound rather than removed.
A process that wins a claim without having published - the pid file existed when it looked, its holder released, and `CreateNew` then won - holds the lock for the few microseconds until the claimed branch publishes.
An inspection landing exactly there falls back to the unkeyed sidecar, which the releasing holder deletes BEFORE the pid file, so it finds nothing and answers held.
Evicting anyone through that door needs the previous holder's sidecar delete to have FAILED as well, and it was not observed in any run above.

#### A third instance, reported not fixed: the SESSION lock reports the same tear

`state/.lock` carries its pid-reuse guard in a `state/.lock.identity` sidecar, and the same two-read pattern is there: `Get-FmSessionLockStatus` reads the lock file and then reads the sidecar.
`Request-FmSessionLock` writes them in that order too - lock file first, identity second - so a reporter reading between those two writes sees the NEW session's pid beside the PREVIOUS session's identity, and prints `lock: stale (pid N dead or not a harness)` for a session that is alive and holds the home.

Reading the code rather than reproducing it, this one is confined to REPORTING, which is why it is left alone here rather than counted with the defect above.
Every writer of `state/.lock` holds `state/.lock.acquire` for both writes, so the two acquirers that could act on a wrong verdict cannot interleave; `Unlock-FmSessionLock` is the one writer outside that mutex and it only DELETES, which tears into "identity missing" - the fail-safe direction, read as held.
Fixing it means giving the session lock the same pid-keyed record, which is a second on-disk shape decision on a file whose one-line bash contract is stated in `docs/foundation.md`, and this task's brief scopes that out.

### 28.8 Suite and analyzer, and two flakes attributed on the way past

```
Invoke-Pester -Path ./tests
  RUN1  2058 passed  9 failed  25 skipped      (45 files, 2326s)
  RUN2  2066 passed  1 failed  25 skipped      (45 files, 2378s)
  RUN3  2066 passed  1 failed  25 skipped      (45 files, 4751s)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  0 findings, run inside the suite by tests/FmAnalyzer.Tests.ps1 and green in all three
```

On the rebased tree - `main` had advanced to `caa511d`, which lands a new area - `FmLock`, `FmModuleAssembly`, `FmAnalyzer`, `FmContract` and `FmInstall` together are **222 passed, 0 failed**.
That run needed one worktree repair first, and it is the one `CONTRIBUTING.md` already names: the rebase updated `AGENTS.md` while this worktree's `CLAUDE.md` hardlink was already broken by `FmInstall.Tests.ps1` (section 22.6), leaving `Get-FmInstructionSurface` reporting `MirrorState: conflict`.
Setup will not overwrite either side of a conflict, by design, so the repair is the documented one - delete `CLAUDE.md` and re-link it to `AGENTS.md`. No tracked content changed; `CLAUDE.md` is marked skip-worktree.

`tests/FmLock.Tests.ps1` is **53 of 53 in every run**, and no run failed the same test twice.
Three whole-suite runs produced three different failure sets, none of them in the lock area and none of them the same one twice - which is the shape of a suite with load-dependent flakes in it, not of a regression.
Each is attributed below rather than waved at, and neither is fixed here: they are other areas' files and this brief scopes them out.

**Run 1's 9** are the fresh-worktree clone artifact sections 22.5 and 22.6 already own, unchanged: `FmContract`'s own-instruction-surface trio plus six `FmInstall`/`Invoke-FmDoctor` tests reading the same surface, repaired mid-run by `FmInstall.Tests.ps1` itself.
That is why there is a second run at all.

**Run 2's 1** is `FmWatch` / `Terminal wait` / `still waits the full interval when nothing happens`, and it is a queued event outliving its notifier.

`Wait-FmWatchInterval` returned `$true` after 70ms, so an event was already queued when the wait began.
The FileSystemWatcher is registered with `Register-ObjectEvent` and no `-Action`, so its events sit on the session event queue; `Wait-FmWatchInterval` drains that queue only on the path where it returns early, and `Stop-FmWatchFileNotifier` unregisters the subscribers without purging what is already queued.
An event arriving after that drain and before the dispose therefore outlives its notifier and ends the NEXT notifier's first wait, whatever directory that one is watching.

Reproduced with no lock code anywhere in the path - the probe calls only `Start-FmWatchFileNotifier`, `Set-FmFileTextLf`, `Wait-FmWatchInterval` and `Stop-FmWatchFileNotifier`, in the order those two adjacent tests call them, under the same 14-process CPU load:

```
iter 4: RETURNED EARLY after 19ms - a queued event outlived its notifier
iter 5: RETURNED EARLY after 17ms - a queued event outlived its notifier
...
10 of 40 iterations ended the wait early
```

`tests/FmWatch.Tests.ps1` alone passed 55 tests five times running on this tree, which is why this only shows up in a whole-suite run: the load is what lets the late event land after the drain.
The fix belongs with the notifier - purge the queued events for those source identifiers when stopping it, or drain them when starting - plus a test that fails without it.

**Run 3's 1** is `FmJobCustody` / `real job-object custody` / `terminates every process in the job and proves the job is empty`, failing on its `Should -Be 'processes'` with `empty`: the `cmd.exe /c pause` child it had just added to the job was not in the job when the job was queried.
`module/Firstmate/Private/FmJobCustody.ps1` contains no reference to any lock function, so nothing this work changed is on that path, and `tests/FmJobCustody.Tests.ps1` alone passed 7 of 7 four times running.
Recorded for the bounded-execution area's owner with no diagnosis offered beyond that, because none was earned here.

---

## 29. Reaching the worker a message is about, and hearing back - `PROVEN (Windows 11), OFFLINE ONLY`

The routing half of the private channel: `Resolve-FmTelegramWorker`,
`Get-FmTelegramRoute`, `Send-FmTelegramWorkerReply`, `bin/fm-tg-route.ps1`, and the
routing added to `Receive-FmTelegramCommand` (`docs/telegram-windows.md`).
Run in a disposable worktree on the captain's Windows 11 laptop on 2026-08-17, on
`fm/tg-route` over `87f71e0`.

**Section 27's limit applies unchanged and is the whole shape of this one too.**
No bot was created, no token was obtained, no real message was sent, and nothing in
this task reached `api.telegram.org`. Everything below ran against a mocked
`Invoke-FmTelegramApi` or, for the entry points, against
`FM_TELEGRAM_API_BASE=http://127.0.0.1:9` - a loopback port nothing listens on.

**No worker was driven either, and that is a design property rather than a testing
gap.** Nothing in this half types into a pane: the routing decision is recorded and
firstmate hands the message over itself through the ordinary steer path. So there is
no evidence here of a steer reaching a live worker, because nothing here attempts
one.

### 29.1 What was executed

```
tests/FmTelegram.Tests.ps1   Tests Passed: 145, Failed: 0   (69s)
tests/FmBridge.Tests.ps1     Tests Passed:  26, Failed: 0
```

Measured against the same Telegram file on `main` before this task, which passes 87,
so 58 of those are the routing's own. `FmBridge` is listed because the fix in 29.5
is in its file and the two were run together after the rebase.

**A FULLY GREEN WHOLE-DIRECTORY RUN WAS NOT ACHIEVED IN THIS WORKTREE, and this
section does not claim one.** Four attempts were made. Every number below is
reported, including the ones that make the branch look worse, because the only
thing this file is for is telling those apart.

```
attempt 1  Passed: 1965  Failed: 9  Skipped: 25  (1948s)   fresh worktree, surface unrepaired
attempt 2  Passed: 1973  Failed: 1  Skipped: 25  (1588s)   heavy concurrent load
attempt 3  Passed: 1969  Failed: 5  Skipped: 25            orphaned process - INVALID
attempt 4  Passed: 1972  Failed: 2  Skipped: 25  (1589s)   surface changed underneath it
attempt 5  no result - killed before it reported, as were two earlier tries
```

**Not one of those five is a clean measurement, and four of the five were spoiled by
how this task ran them rather than by the port.** Attempts 1 and 4 read an
instruction surface that was changing, attempt 2 ran against contention this task
created by overlapping its own attempts, attempt 3 ran orphaned, and attempt 5 was
killed. That is a finding about this worktree's ability to hold a 30-minute run, and
it is why the verdict below rests on targeted suites instead.

What WAS measured cleanly, on the rebased tree, with the surface repaired and nothing
else running - the seven suites that between them cover this branch's own code, the
files it changed, the cross-area assembly rules, and the repo-wide analyzer bar:

```
FmTelegram + FmBridge + FmInstall + FmContract + FmLock + FmModuleAssembly
  + FmAnalyzer                                     Passed: 377  Failed: 0
FmLock + FmIdentity + FmSupervision + FmState      Passed: 188  Failed: 0
```

**Attempt 1's nine failures are the fresh-worktree instruction surface.** A
`core.symlinks=false` clone writes `CLAUDE.md` and `.claude/skills` as text
placeholders, and `tests/FmInstall.Tests.ps1` repairs them by running
`fm-setup.ps1` against this checkout as part of its own job - so the tests that read
that surface fail before the repair lands and pass after it. All nine are
`this checkout's own instruction surface` (3), `Invoke-FmDoctor` (4), the
`Install-FmHome` backend warning, and the home-vs-checkout doctor warning. Nine is
the known count here. Section 27.1 recorded the same effect from the other side: it
ran in an already-repaired checkout and said so.

**Attempt 2's single failure has since been diagnosed and fixed by somebody else,
and section 28.5 owns it.** It was `One holder, proven with real processes.hands the
lock on when a holder is killed outright, with no cleanup step`, and the cause was
not the lock and not this branch: the test reaps a job whose process it has just
killed on purpose, `Remove-Item -Force` stops that job first, and the resulting
`IOException: The pipe is being closed` is terminating, so it fails in its own
cleanup after every assertion has already passed. That reap is now wrapped on `main`.

This section's own checks pointed the same way before that landed, and are kept
because they are what a reader would otherwise have to redo:

```
FmLock alone, under load                            Passed: 47   Failed: 0
FmLock + FmIdentity + FmSupervision + FmState, idle Passed: 188  Failed: 0
```

The staged diff also adds no lock, state, or process-identity code, checked
mechanically rather than asserted. `CONTRIBUTING.md` requires treating a failure
there as a real race until proven otherwise, and the proof is section 28's, not this
one's.

**Attempt 3 is invalid and is listed so nobody reads its five failures as real.** It
was launched with `Start-Process` from a shell that then exited, so the suite ran
orphaned - and `Get-FmParentProcessId.finds a parent for this process` is one of the
five that failed. Every one of the five is a process-identity or lock-ownership test,
all of which need live process ancestry. That run measured the workaround, not the
port.

**Attempt 4's two failures are `Invoke-FmDoctor` reading the instruction surface
while this task was changing it.** The rebase onto `main` needed a clean tree, so
`CLAUDE.md` and `.claude/skills` were put back to the placeholder bytes git records
for them - at 21:05, while that run was still going and did not finish until 21:18.
Mutating the tree under a running suite invalidates it. Worth noting anyway: the lock
crash-recovery test PASSED in this one, which is what an intermittent failure looks
like from the other side.

**Attempt 5 was killed before printing a result**, as were two earlier tries; a
30-minute run did not reliably survive here. What that leaves is stated plainly: the
suites above are proven and the whole-directory green is not.

The suite fixtures build live work the way the real thing does - a
`state/<id>.meta` for each dispatched piece of work, and status lines written
through `Add-FmTaskStatus` - so what routing enumerates is what a real spawn and a
real worker leave behind, not a hand-written imitation of it.

### 29.2 The resolution, and the two cases that are not ambiguity

Two pieces of live work in the home (`fix-signin` on `acme-web` restoring sign-in,
`cart-speed` on `acme-shop` profiling the cart page):

```
how is the sign-in fix going          -> routed  fix-signin   evidence=name    score 7
any progress on sign-in               -> routed  fix-signin   (matched across the hyphen)
how are the invoice totals looking    -> routed  task-one     evidence=report
any news?                             -> ambiguous, question asked
how is the login fix going  (two "fix-login-*")  -> ambiguous, question asked
have someone look at the pricing page -> none, no question asked
get someone else onto the sign-in fix -> routed  fix-signin   (start-shaped AND named)
any news?  (one piece of work only)   -> routed, evidence=only-one
any news?  (after a named message)    -> routed, evidence=recent
any news?  (that work since done)     -> ambiguous again
```

The hyphen case is worth naming: the captain writes "sign-in" and the work is called
`fix-signin`, so splitting on punctuation alone yields "sign" from one and "signin"
from the other and the strongest signal available misses completely. Each side also
offers its joined-up form.

**One measured false positive, now guarded.** Before the name/report weights were
tracked apart, "have someone look at the pricing page" routed to the worker
profiling the CART page, because both strings contain the word "page". An
instruction to start something now needs the work *named* rather than brushed
against; a test asserts that exact message resolves to nothing.

The question asked instead of a guess was checked for what it must not contain as
well as what it must: no task id, no percentage, no status verb. Five live pieces of
work produce a question listing three and saying "or one of 2 others" rather than
dropping the rest silently.

### 29.3 The record, and the answer matched back to its question

```
1786971831  routed  79b77503e35a  fix-signin  1  how is the sign-in fix going
```

One report existed when the captain asked, so the answer is what that worker says
after line 1. Proven for the whole loop, in one test that runs the poller and then
the carry-back:

```
poll     -> 1 taken, and the captain told "Restoring sign-in", never "fix-signin"
route    -> 1 outstanding, Reported=False
worker   -> done: sign-in works again for accounts made before the migration
carry    -> "Captain, you asked: how is the sign-in fix going" + the translated answer
```

Two questions to two different workers each get their own worker's report, and a
report from an unrelated worker answers neither. A carried answer is recorded
`answered` under the same id - a second record, not a rewrite - and a second call
sends nothing. A send that timed out leaves the routing open and reported, so the
next call tries it again.

### 29.4 The two boundaries this half must not move

**Refusal happens before routing.** Five refused messages that each plainly name
live work (`merge the sign-in fix`, `discard the sign-in work`, `delete the sign-in
branch`, `tear down the sign-in fix`, `show me the token for the sign-in work`) each
came back refused with nothing in the inbox and nothing in the routing record, and
the same held for one taken by the poller itself. A steer a narrowed
(`allow-tier=1`) channel refuses records nothing either, while a question over the
same channel still routes.

**No worker's raw words reach the captain.** A status line stuffed with everything
`AGENTS.md` section 9 forbids was carried back and the sent body asserted to contain
none of it - no `done:`, no `95%`, no `key=`, no `fm/fix-signin`, no `docs/`, no
`state/`, no filename - while still carrying "Sign-in restored", because stripping
rather than refusing is the point.

### 29.5 One captain-facing defect fixed in the shared stripper

`ConvertTo-FmBridgePlainText` removed a branch name and left the word that
introduced it behind, so a worker's answer arrived on the phone reading "writing the
test in". It now takes a dangling preposition with the token it stripped, as the last
removal after the vocabulary pass, because every pass above it can leave one behind.
Fixed in the one owner rather than worked round here, so the browser and the voice
channel get it too.

The reuse is asserted rather than assumed: a worker note reading "crewmate wedged in
its worktree, the harness went stale after teardown" is carried back with none of
those words in it and "worker", "local copy" and "cleanup" in their place. That test
is what would notice if this path ever grew a translator of its own, which is the
failure the one-owner rule exists to prevent - the vocabulary table landed on `main`
during this task and this path picked it up with no change.

### 29.6 What was NOT proven here

- **Everything in section 27.6 still stands**, unchanged.
- **No steer was delivered to a live worker**, because nothing in this half
  attempts one. The handover is firstmate's, through `fm-send.ps1`, whose own
  delivery guarantee is proven in its own section.
- **Nothing calls the carry-back by itself.** Wiring this into the escalation path
  is a separate decision the captain has not made, so there is no evidence of an
  answer reaching a phone unprompted.
- **The resolution is lexical, and its limits are not measured against real
  traffic.** "Sign-in" and "login" mean the same thing to a captain and share no
  letters that matter; where the last report does not bridge them, this asks rather
  than guessing. That is the intended behaviour, but how often it asks when a human
  would not have needed to is unknown until the channel carries real messages.
- **A fully green `Invoke-Pester -Path ./tests` was not obtained here**, as 29.1 sets
  out in full: of four attempts, one predated the surface repair, one hit the
  cleanup defect section 28.5 has since fixed, one was invalidated by being run
  orphaned, and one was killed before it reported. The area suites and the repo-wide
  analyzer bar are proven; the whole-directory green is the one acceptance criterion
  of this task that rests on targeted re-runs rather than on a clean whole run, so
  whoever lands this should take that run themselves - it is now expected to pass,
  since the only real failure any attempt found has an owner and a fix.

## 30. The bridge screen: a reply that destroyed the panel, dictation that took fifteen seconds, and a screen that said nothing - `PROVEN (Windows 11)`

Task: three faults the captain hit on `ui/bridge.html` and the dictation path,
on `fm/ui-voice` over `df6494d`.
Run in a disposable worktree on the captain's Windows 11 laptop on 2026-08-17,
against a real Chrome (`chrome-devtools-axi`) and the captain's own installed
dictation app.

The screen was driven rather than reasoned about: a bridge on a scratch
workspace, a real browser, and `getBoundingClientRect` for every claim about
where something sits.
Nothing was changed on the captain's machine - the one setting the fast path
wants is named below and deliberately left for them.

### 30.1 The long reply, measured before and after

The defect reproduces only in the real sequence, which is why reading the CSS
found nothing: the radar is sized in pixels when the page loads, an arriving
reply is not a resize event, and nothing ever told the canvas its row had
shrunk.
An 85-word reply at 1366x768, before:

```
radar canvas   top 18px, bottom 511px   (493px tall, in a 408px row)
radar wrap     top 78px, bottom 486px   -> 59px out through the top of the panel
CORE ACTIVE    top 521px, bottom 546px  -> inside the transcript, which starts at 521px
overlapLabel   true
```

The caption was drawn over the reply's first line and the radar over the header.
The same page, same window, same reply, after:

```
radar canvas   top 92px, bottom 417px   (325px tall)   radarInsideWrap true
CORE ACTIVE    top 427px, bottom 452px                 labelInsideWrap  true
transcript     top 521px, bottom 657px                 overlapLabel     false
```

A 220-word reply then stops growing and scrolls instead: box height 220px,
content 349px, `overflow-y:auto`, radar still 241px and inside its row, and the
last line fades rather than being cut in half.

Checked at seven window sizes with the same reply, all with `overlapLabel false`,
`radarInsideWrap true`, everything inside the panel, and no horizontal document
overflow:

```
1024x700  radar 238px      1290x720  radar 258px      1300x800  radar 303px
1366x768  radar 325px      1600x1000 radar 538px      1920x1080 radar 618px
1366x600  radar 113px  (the floor is small on purpose - a floor the row cannot keep IS the defect)
```

One measuring note, because it cost a wrong reading here first: a synchronous
measurement in the same task as the text change sees the box BEFORE the radar has
been told, since a `ResizeObserver` callback runs after layout rather than during
it.
It runs before paint, so no frame is ever painted at the old size - every number
above is read a frame later, which is what the captain actually sees.

A long unbroken string was tested deliberately, since that is the case
`max-width` alone does not answer:

```
before   document scrollWidth 1790 against a 1366 window   (424px of the page pushed off-screen)
after    document scrollWidth 1366 against a 1366 window   transcript scrollWidth == clientWidth == 513
```

The fixture was a 481-character line carrying a PR URL with a long anchor, a
Windows path, and 180 unbroken characters.

### 30.2 Dictation: the fifteen seconds, and where they went

The slow path is `Convert-FmSpeechToText`, which starts a one-shot engine
process per utterance.
Three runs of one 5.35s clip, wall clock from PowerShell beside the engine's own
log:

```
run 1  wall 19.31s   model load 14802ms   transcribe 3.31s   unload 613ms
run 2  wall 15.00s   model load 10910ms   transcribe 3.02s   unload 642ms
run 3  wall 14.80s   model load 10852ms   transcribe 2.97s   unload 601ms
```

Every run transcribed the clip correctly, and every run spent three quarters of
its time loading a model the captain's own running instance already holds.

The fast path asks that instance instead.
Measured, from its log:

```
Invoke-FmSpeechCapture -Action Toggle   ->  exit 0 in 172ms
                                            "TranscribeAction::start called for binding: transcribe"
                                            "Microphone stream initialized in 125.454ms"
                                            "Starting to load model" AT RECORDING START, not after it
Invoke-FmSpeechCapture -Action Cancel   ->  exit 0 in 190ms, "returned to idle state"
```

So the transcription itself is the only cost left.
Isolated exactly, one process that loads once and transcribes the same clip three
times (`--transcribe-file <clip> --repeat 3 --json`):

```
load_ms 8686        transcribe_ms [3009, 2635, 2495]     rtf 2.14
```

That is the whole shape of the fix in one line: the 8.7s-to-14.8s load is what a
warm model does not pay, and 2.5s-3.0s is what is left.
The engine's own resident runs agree - 5.55s for 17.52s of audio, no load line
before it - and when a load IS needed it now overlaps the captain speaking rather
than following it.
Against 14.8s-19.3s per phrase, that is item 2.

The return channel was proven end to end, page included:

```
bin/fm-dictate.cmd -Port 7455  <- "how many tasks are under way and is anything waiting on me" on stdin
  -> exit 0, printed nothing (delivered rather than echoed back)
  -> bridge console: heard: how many tasks are under way and is anything waiting on me
  -> the page picked it up on its 400ms wait, showed it, logged it, and asked it
  -> with no session behind it: "No answer came back" / "firstmate is not running here, so nothing is listening"
```

### 30.3 The one manual step, and why it is a `.cmd`

The engine spawns its hook as a process, and Windows cannot execute a `.ps1`
that way.
Measured, both directions:

```
Process.Start(bin/fm-dictate.ps1)  ->  "The specified executable is not a valid application for this OS platform"
Process.Start(bin/fm-dictate.cmd)  ->  exit 0, transcript on stdin      -> delivered
Process.Start(bin/fm-dictate.cmd)  ->  exit 0, transcript as argv[1]    -> delivered
```

Hence `bin/fm-dictate.cmd`, one line in front of the script.
The step the captain makes by hand, in their dictation app's own settings:

```
paste method          external script
external script path  <checkout>\bin\fm-dictate.cmd
```

Their current setting is `paste_method: direct` with no script path, read and
reported rather than changed.
The bridge prints both the state and the step on startup, and the page says the
same thing when the words do not arrive.

### 30.4 The screen now says what it is doing

Driven with the real engine from the page, at 1366x768:

```
mic pressed   strip "LISTENING 3s", red pip and red dock, caption LISTENING / SPEAK NOW,
              hint "RELEASE WHEN YOU HAVE FINISHED"   (a real capture: the engine opened the microphone)
released      strip "TURNING THAT INTO WORDS 4s", cyan pip, caption WORKING
words land    strip ANSWERED, the line in the transcript and in Activity
nothing came  strip "THE WORDS DID NOT ARRIVE", amber pip, and the reason plus the one
              setting to change, in the transcript AND in Activity
```

The counter is elapsed seconds, not a percentage: nothing on this path knows a
percentage, and inventing one would be the same lie as the silence it replaces.

### 30.5 What was NOT proven here

- **The engine calling the hook itself.** Proving it means setting
  `paste_method` on the captain's machine, which this task was told not to do.
  What IS proven: the hook runs when spawned exactly as the engine spawns one,
  it delivers to the bridge, and the page acts on what arrives - the last inch is
  the setting.
- **A warm transcription of real speech in one pass.** The microphone cannot be
  spoken into from here, and the engine mutes output while recording, so a clip
  cannot be played into it either - so the warm numbers above are the engine's
  own log lines, and the cold numbers are wall clock on this machine.
- **The page has no Pester coverage and deliberately gets none.** A test that
  read the stylesheet would assert implementation source rather than behaviour,
  which `CONTRIBUTING.md` forbids - so the browser run above is the evidence,
  and `tests/FmBridge.Tests.ps1` covers the two new speech seams and their
  refusals.
- **A live capture is not exercised by the suite.** `Invoke-FmSpeechCapture`
  with a running engine opens the captain's microphone; only its refusals are
  tested.
- **One footprint this testing DID leave**, recorded rather than tidied away:
  driving a real capture from the page opens the captain's microphone, and the
  engine saves each recording into its own history. One 3-second clip of a silent
  room (`handy-1786980118.wav`, 20:51 local) is in there, and the app's own
  five-item retention evicted its oldest entry to fit it. Every capture in this
  work was dropped with `--cancel` before transcription, so nothing was typed
  anywhere and no transcript of it exists; the file is left for the app to prune
  rather than reached into another application's store to delete.
- **Also observed, not fixed:** `ui/bridge.html` carries two NUL bytes (offsets
  54043 and 54052, inside the Activity dedup key), which is why `rg` and `grep`
  skip the file entirely and report it as binary - it predates this task, it does
  not affect the page, and `git diff` still renders it as text.

### 30.6 The checks, on this branch, after the change

On this branch rebased onto `df6494d`, which is what will be merged:

```
Invoke-Pester -Path ./tests
  44 files   Tests Passed: 1992, Failed: 0, Skipped: 25   (1326.33s)

Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
  0 findings   (46s)
```

`main` moved twice while this was being measured, so the same change was measured
green on all three bases it sat on: 1932 passed over `7aa1af5`, 1934 over
`87f71e0`, and 1992 here - the growth is other lanes' tests arriving, not this
one's.
Each of those was one whole-directory process, and the 44 files were additionally
run as smaller `Invoke-Pester` processes on the last two bases, agreeing exactly
with the whole run each time.
`tests/FmBridge.Tests.ps1` is 42 of those tests and passes against
`df6494d`'s new dangling-preposition rule in `ConvertTo-FmBridgePlainText`, which
lands in the same function this branch touches.

Three things about those runs should be said rather than left to be inferred.
They were made in a checkout whose `CLAUDE.md` and `.claude/skills` had already
been materialized, so they are not measuring an unrepaired Windows clone: a first
run in a fresh worktree fails the instruction-surface tests until
`tests/FmInstall.Tests.ps1` repairs them, and those repairs are local to the host
and are deliberately not committed.
The suite must also be run in a process whose PARENT is still alive -
`Get-FmParentProcessId -Id $PID` legitimately finds nothing when the launcher has
exited, so a detached run whose launcher returned immediately fails one identity
test for a reason that is not a defect.
And a split into smaller processes is weaker evidence than one whole-directory
run, not stronger - Pester shares one process per run, so a split hides exactly
the cross-file environment leak `CONTRIBUTING.md` warns about.
It is recorded because it corroborates the single run, never as a substitute for
it.

## 31. The installer, on the captain's Windows 11 machine - `PROVEN (Windows 11)`, with one part deliberately not run

Dated 2026-08-17/18, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\3\firstmate-win`,
PowerShell 7.6.4, Windows 11 Pro 10.0.26200.

**The brief's premise, confirmed first.** `install.ps1` installed the two most
important tools from npm. Both npm names are the wrong software:

```
npm "treehouse"  -> "Opinionated mini-framework for dealing with state in
                    single-page applications"
npm "herdr"      -> 0.0.0, "Reserved package name for Herdr"
```

What this machine actually runs, and where each came from:

```
treehouse -> C:\Users\ADMIN\AppData\Local\treehouse\treehouse.exe          v2.1.1
herdr     -> C:\Users\ADMIN\AppData\Local\Programs\Herdr\bin\herdr.exe     0.7.5-preview.2026-07-21-0f10e1453a7f
gh        -> C:\Users\ADMIN\AppData\Local\Programs\gh\bin\gh.exe           2.97.0
claude    -> C:\Users\ADMIN\.local\bin\claude.exe                          2.1.233
```

Each of those directories is exactly what the vendor's own installer writes, and
each is on the USER PATH. None of them came from npm and none needed
administrator. The four published installers were fetched and read before being
written into the route table:

| tool | fetched | what it does |
| --- | --- | --- |
| `https://kunchenguid.github.io/treehouse/install.ps1` | 200, 1360 bytes | GitHub release zip -> `%LOCALAPPDATA%\treehouse`, adds it to the USER PATH |
| `https://herdr.dev/install.ps1` | 200, 25635 bytes | versioned folders under `%LOCALAPPDATA%\Programs\Herdr\bin`, preview channel on Windows |
| `https://claude.ai/install.ps1` | 200, 3189 bytes | checksum-verified binary, then `claude install` |
| `https://aka.ms/install-powershell.ps1` | 200 | Microsoft's own; `-Destination` + `-AddToPath`, zip rather than MSI |
| `https://api.github.com/repos/cli/cli/releases/latest` | 200 | `gh_2.97.0_windows_amd64.zip`, whose root is `bin/` and `LICENSE` |

**winget is present and unreachable by name - measured.**

```
PS> Get-Command winget
Get-Command: The term 'winget' is not recognized ...

PS> & "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version
v1.29.280

PS> [Environment]::GetEnvironmentVariable('Path','User') -split ';' | Select-String WindowsApps
C:\WINDOWS\system32\config\systemprofile\AppData\Local\Microsoft\WindowsApps
```

The user PATH carries the SYSTEM profile's app-alias directory rather than this
user's, so a `Get-Command`-only check refuses every winget route on a machine
that has winget. `Get-FmToolWingetPath` looks in the real place second.

**The Windows PowerShell 5.1 preflight, run for real.**

```
PS> & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -DetectOnly

  FIRSTMATE - install

  This is Windows PowerShell 5.1.26100.8115. Firstmate is PowerShell 7 only -
  every script in this repo declares '#requires -Version 7.0'.

  Re-running under C:\Program Files\PowerShell\7\pwsh.exe...
  ...
EXIT=0
```

The branch that INSTALLS PowerShell 7 was not exercised: this machine has it, and
installing a second copy to prove the path would have changed the environment the
rest of this run was measured in. What was proven is the detection and the
relaunch, which is the half that decides whether the captain ever sees a useful
message.

**Detection, end to end, against the real machine.**

```
PS> .\install.ps1 -DetectOnly
  what this machine has:
    [ok]          PowerShell 7            7.6.4
    [ok]          winget                  v1.29.280
    [ok]          npm                     11.11.0

    [older]       git                     git version 2.49.0.windows.1 is installed; v2.55.0.windows.4 is published
    [older]       Node.js                 v22.15.0 is installed; v24.19.0 is published
    [ok]          Claude CLI              2.1.233 (Claude Code) is the latest published version
    [older]       herdr                   herdr 0.7.5-preview.2026-07-21-0f10e1453a7f is installed; preview-2026-08-17-1147e60bc0a4 is published
    [ok]          treehouse               v2.1.1 is the latest published version
    [ok]          gh                      gh version 2.97.0 (2026-07-31) is the latest published version
    [ok]          gh-axi                  0.1.30 is the latest published version
    [ok]          chrome-devtools-axi     0.1.29 is the latest published version
    [ok]          lavish-axi              0.1.52 is the latest published version
    [ok]          tasks-axi               0.2.5 is the latest published version
    [ok]          quota-axi               0.1.28 is the latest published version
    [ok]          module Pester           6.1.0 is the latest published version
    [ok]          module PSScriptAnalyzer 1.25.0 is the latest published version
    [skipped]     no-mistakes             the validation pipeline has no Windows support ...
  -DetectOnly: nothing was changed.
```

Three tools classify as `older` on the captain's own machine, which is the case
the addendum's optional-update question exists for. herdr is the interesting one:
its Windows builds are tagged `preview-<date>-<sha>` with no semantic version at
all, so ranking it by semver would compare `0.7.5` against nothing.
`Get-FmToolComparableVersion` ranks two date-stamped builds by their date and
refuses to rank a date against a semver.

**One bug this detection found in itself.** The first online run reported every
Node.js and herdr version at once as a single space-joined "latest":

```
node -> "v26.7.0 v26.6.0 v26.5.1 ... v0.1.14"
```

`Invoke-RestMethod` hands a JSON array back as ONE object, so `@(...)` around it
produces a one-element array holding the whole list, and `$wrapped[0].version`
then member-enumerates every entry. Both call sites now pipe instead, and both
carry the reason.

**The protection, applied and verified.**

```
PS> bin\fm-setup.ps1
  [updated] instruction links - git will no longer restore over .claude/skills or CLAUDE.md
PS> git ls-files -v -- CLAUDE.md .claude/skills
S .claude/skills
S CLAUDE.md
```

**A defect the suite caught in this change.** Wiring `Protect-FmInstructionLink`
into setup made setup non-idempotent, and `tests/FmInstall.Tests.ps1` failed on
it:

```
FAIL: Install-FmHome: the home layout.is idempotent: the second run changes nothing and reports already
```

`git update-index --skip-worktree` exits 0 on a path that ALREADY carries the
bit, so the step reported `updated` on every run and could never converge to
`already` like every other step in the area. The fix reads the state first -
`git ls-files -v` prints the tag `S` for a skip-worktree entry - and reports
`already` when there is nothing to do. That function had no tests at all before
this; it has six now, including the negative control that runs the real
`git checkout -- .` against a protected checkout and finds the skills still
there.

**What was NOT run, and why.** No tool was actually installed or updated on this
machine. Doing so would have replaced the working treehouse, herdr, gh and Claude
CLI this whole task was measured against, which the brief forbids. So:

- the classification, the plan, the questions, the routes, the elevation
  declarations, the summary and the refusals are all covered by
  `tests/FmToolInstall.Tests.ps1` and were run;
- the portable install - expand, layout check, PATH edit, second-run idempotence,
  `-StripRoot`, and the refusal when the archive layout is wrong - runs for real
  in that suite against a zip built in `TestDrive`, with `-PathScope Process` so
  it never touches the captain's environment;
- the DOWNLOAD itself, and `Invoke-FmToolRoute` actually executing a vendor
  installer, have not been executed anywhere. They are the one part of this area
  that a clean machine is needed to prove.

**The suite and the analyzer, on this branch.**

Measured over this lane's commit rebased onto `c4aa731`, the tree that will
merge, with both passes run back to back in one keeper.

```
Invoke-Pester -Path ./tests          run A   2333 passed, 13 failed, 17 skipped   (46m19s)
Invoke-Pester -Path ./tests          run B   2333 passed, 13 failed, 17 skipped   (52m14s)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
                                             zero findings at every severity
```

47 files in one process each time, the same thirteen both times, and a clean
working tree after.

THIRTEEN FAILURES, AND NONE OF THEM IS THIS BRANCH'S. Reported as a number
rather than buried, and attributed by measurement rather than by argument.

Nine are the instruction-surface set section 30 describes: the committed
`CLAUDE.md` is the link placeholder git leaves as text, this lane keeps it that
way because `CONTRIBUTING.md` requires it for a Linux clone, and the checks that
read the surface fail until the suite repairs it.

The other four are pre-existing, and the same probe run against `main` WITHOUT
this commit is what says so:

```
three files, run from a script file      this branch   3 failed
same three files, same runner, on main   c4aa731       4 failed
```

`Get-FmBridgeHouseWork.reports only what is running`, `Reading.returns an empty
collection of lines for a missing file`, and both `the sweep runner itself`
cases. All four are one shape - `The property 'X' cannot be found on this
object` - which is what `Set-StrictMode -Version Latest` says when a test reads
`.Count`, `.Name` or `.Analysed` off a result that came back empty. The
house-work one is exact and was reproduced directly: with nothing it recognises
running, `Get-FmBridgeHouseWork` correctly returns no rows, and the test's
`@(Get-FmBridgeHouseWork).Name` throws on the empty array. It passed for years
because the suite was always launched by a command line containing the words
`Invoke-Pester`, which the function counts as a test run - and the keeper
launches from a script file, so that string is nowhere.

That makes them a property of how the suite is RUN, not of the tree, which is
why they are absent from every earlier run in this file and appear in both of
these. They are left for the areas that own them rather than fixed from here.

## 32. Push to talk stopped after a second and never worked again - `PROVEN (Windows 11), NO BROWSER AND NO MICROPHONE`

Dated 2026-08-19, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\11\firstmate-win`,
PowerShell 7.6.4, node v22.15.0, Windows 11 Pro 10.0.26200, against `main` at `3af8a04`.

The captain's report, verbatim:

> found bug push to talk not working proper on click/push it stop in 1-2 sec and
> then after it not workig any time

### 32.1 How this was reproduced without starting a screen

No bridge was started, no page was served, and no browser was opened at any point in this work.
That is the captain's standing rule after the two speaking incidents, and `CONTRIBUTING.md`'s "Seeing the browser screen" states it.
It is also not a limitation here: every defect below is in the page's own state machine, and a state machine does not need a microphone to be driven.

`tests/ui/bridge-page-harness.js` loads `ui/bridge.html`'s own `<script>` into a stubbed window under `node:vm` and drives it through its own event listeners.
The clock is virtual, so a thirty-second hold and ten consecutive presses cost milliseconds.
The server model mirrors `bin/fm-bridge.ps1`, including the two behaviours that turned out to matter: `/api/listen` is a toggle whose edge the caller owns, and `/api/fleet` and `/api/heard` drain the same pending transcript.

Nothing renders and nothing can speak, because there is no page and no `speechSynthesis` behind the stub.

### 32.2 Both symptoms, reproduced

Driven against `3af8a04` unmodified.

```
=== the keyboard route the screen advertises ===
dock hint says              : "Hold right Alt to speak"
after holding right Alt     : stage=undefined  mic=Mic closed  engine toggles=[]

=== the button, held, while a transcript lands mid-hold ===
t=0.3s  stage               : listening  mic=Mic open  toggles=["START"]
t=2.7s  stage               : answered  (still holding)
t=2.7s  asked already       : ["what is the fleet doing"]
t=6.7s  stage               : idle  (still holding)
t=6.7s  mic badge           : Mic open
released -> engine toggles  : ["START","START"]
released -> engine recording: true
released -> mic badge       : Mic closed

=== and now the button again ===
press 2 -> stage            : hearing
press 2 -> new engine calls : 0
press 2 -> anything on screen saying why: "Acknowledged."
```

Both halves of the captain's report, in one run.
It stopped at 2.7 seconds while still held, and the next press produced nothing at all with nothing on screen to say so.

### 32.3 The causes, stated plainly

Seven defects, not one. The first two produce the captain's two symptoms; the rest are the same class and were found on the way, several of them by the checks written for the first two.

**1. The fleet poll answered a capture the captain was still holding.**
`refreshFleet()` runs every 2000 ms and did `if(f.dictated && !awaitingReply){ wordsArrived(f.dictated); }`.
`/api/fleet` drains the very same `$script:pendingDictation` that `/api/heard` does, so a transcript arriving mid-hold was taken by whichever poll got there first and asked as a question immediately.
The engine takes about three seconds to transcribe, so the line in flight from the PREVIOUS press routinely landed inside the NEXT hold.
That is the 1-2 seconds: the page flipped from Listening to Thinking to Standing by while the captain was still speaking.

**2. The release then re-started the engine, and every press after it was inverted.**
`Invoke-FmSpeechCapture`'s own description says it: one flag starts and stops, so "the CALLER owns which edge it is on - a stray second stop would begin a new recording."
Nobody owned it. The page sent a bare toggle on press and another on release and assumed they paired up.
Once anything else finished a capture first they stopped pairing, and the measurement above shows the result: two `START` edges, the engine left recording, and the page's own badge saying `Mic closed` over a live microphone.
From that point push-to-talk was exactly backwards for the life of the page.

**3. The keyboard route was never bound at all.**
`idleHint()` returns `Hold right Alt to speak`. The only key handler was `e.code === 'Space'`.
Nothing anywhere in the file referenced `AltRight`.
This one IS a regression from the listening-mode work, and 32.4 has the bisect.

**4. And Space could not work either, from 300 ms after load.**
The keydown handler refused while `document.activeElement.id === 'typed'`, and `setTimeout(focusMessage, 300)` puts the caret in the message box at load and `focusMessage()` returns it there after every exchange.
So the advertised key did nothing ever, and the unadvertised one did nothing after the first three hundred milliseconds.

**5. Every refusal was a bare `return`.**
All three guards at the top of `talkStart` returned silently, and `awaitingWords` kept one of them true for up to 45 seconds after every capture.
The captain pressed a control, nothing happened, and the page looked perfectly healthy.
That is why the report says "then after it not workig any time" rather than naming an error.

**6. Three smaller ones, same class.**
`mouseleave` ended a hold, so a few pixels of pointer drift off a 40px button read as the microphone closing by itself.
The settle timer from the previous answer (`setTimeout(... 2200)`) relabelled a live hold as Standing by if the captain pressed again inside that window.
That one was found by the ten-cycle check rather than by reading: nine of ten cycles reported the hold as Standing by while the microphone was open and recording.
`collectPcm` connected a fresh `GainNode` to `actx.destination` on every press and never disconnected it: 22 nodes still connected after ten presses, measured.

**7. A refused microphone killed the slow path for good.**
`recordHere`'s `catch` cleared `capture` but not `listening`, and `recordHere` refuses to start while `listening` is set.
So one denied permission - or any throw after the capture began - left the slow path dead for the rest of the page's life, silently.
Exactly the shape of the defect the captain reported, on the other path, and it would have outlived the fix for the first six.

### 32.4 Did it regress when the listening mode landed - partly, and here is which part

The same interaction, driven at five commits:

```
0870c15    hint=""                          hold:undefined->undefined  stolen=no   edges=[]
8f6567a    hint=""                          hold:listening->answered   stolen=YES  edges=[START,START]  2nd-press-calls=0
ed75d0d    hint=""                          hold:listening->answered   stolen=YES  edges=[START,START]  2nd-press-calls=0
c4aa731    hint="Hold right Alt to speak"   hold:listening->answered   stolen=YES  edges=[START,START]  2nd-press-calls=0
3af8a04    hint="Hold right Alt to speak"   hold:listening->answered   stolen=YES  edges=[START,START]  2nd-press-calls=0
```

**The steal and the inversion are older than the listening mode.**
They are identical at `8f6567a`, which is where the fleet poll's `dictated` pickup reached the fast engine path, and at `ed75d0d`, the commit before the listening mode.
`c4aa731` did not cause them.

**What `c4aa731` did cause is defect 3.**
`git log -S` puts the string `Hold right Alt to speak` in that commit and the only `e.code` binding in the file has been `Space` since `29bbb80`.
So the listening-mode work put the words "right Alt" on screen and bound nothing to them.
That is a real regression from it, and it is the reason the captain was pressing a key that could never have worked.

### 32.5 The fix

**The bridge owns the edge, and it owns whose transcript a line is.**
`Step-FmSpeechCaptureState` and `New-FmSpeechCaptureState` in `module/Firstmate/Public/FmBridge.ps1` are one small machine with both rules in it.
A stop with nothing running resolves to `None` rather than a toggle, which is the whole of defect 2.
A transcript produced under a page-driven capture is refused to `/api/fleet` entirely and leaves only by `/api/heard`, which is the whole of defect 1.
A bare `toggle` from a tab left open from before is resolved against what is actually running rather than passed through, so a stale page is safer than it was rather than merely tolerated.
An engine that refused a request establishes exactly one fact, that it is not recording for us, and the `Failed` step records that fact and nothing more - in particular it leaves an outstanding wait for words alone, because clearing that would put the line back on the fleet channel.

**One more instance of the same race, caught in review before it shipped.**
The first version of this machine ended the page's claim on the first `/api/heard` poll, whatever that poll returned.
The page polls every 400 ms and the engine spends about three seconds transcribing, so the first several polls are empty by design - and clearing the claim on one of them handed the transcript straight back to the fleet channel the moment it landed.
That is the original defect, one poll later and further from where anyone would look for it.
Only a line that actually arrived ends the wait now, and a page that gives up says so with `Cancel` rather than in silence, so a line nobody collected is released rather than pinned out of reach.
Reverting just that one line turns the Pester case `does not end the wait on an empty poll, which is most of them` red, which is how it was confirmed to be load-bearing rather than decorative.

`/api/listen` now takes `start`, `stop` or `cancel`, and answers with `recording`, which `/api/fleet` also carries.
The mic badge reads that rather than the page's own `capture` variable, which is the value that used to go stale.

**On the page**: right Alt is bound and works wherever the caret is (Control plus right Alt is left alone, because that is AltGr typing a character); Space keeps its guard so it still types a space; pointer capture replaces `mouseleave` so the hold follows the pointer; a lost window or a hidden tab ends the capture instead of stranding it; every refusal says why; a press while the last words are outstanding abandons that wait instead of swallowing the press; `releaseMic` takes down the sink, the source and the analyser; and `setStage` cancels a pending settle so an old answer cannot relabel a live hold.

### 32.6 Fixed, measured the same way

```
74 checks, 0 failed
  ok   right Alt opens the microphone
  ok   right Alt: the engine is told exactly once
  ok   Control and right Alt together is AltGr, not push to talk
  ok   Space while typing does not open the microphone
  ok   a whole fleet poll later, still listening
  ok   a whole fleet poll later, nothing has been asked
  ok   six seconds in, still listening
  ok   the engine is not left recording
  ok   and the very next press opens the microphone
  ok   ten consecutive holds each opened the microphone
  ok   ten consecutive releases each produced an answer
  ok   ten consecutive releases each closed the microphone
  ok   twenty engine edges, strictly alternating
  ok   a thirty second hold captures the whole thirty seconds
  ok   a long hold tells the engine once, not repeatedly
  ok   the pointer leaving the button does not end the hold
  ok   a window that loses focus closes the microphone
  ok   a window that loses focus says so on screen
  ok   a press while waiting for the last words is not swallowed
  ok   the previous answer does not relabel the hold that follows it
  ok   a press behind the reply overlay is refused
  ok   and the refusal is said out loud
  ok   every stream the slow path opened was stopped
  ok   no audio node is left connected after ten presses
  ok   a refused microphone is reported
  ok   and the press after a refusal still opens the microphone
  ok   nothing was asked while the transcript was still being made
  ok   a slow transcript still reaches the page
  ok   and the captain own-key dictation reaches the screen again
  ok   two phrases, four engine edges, alternating
  ok   switching back to push closes the microphone
  ok   no listener or timer raised
```

The ten cycles in full, each one a press, a hold, a release and an answer:

```
cycle  1  opened=yes  engine=["START","stop"]  asked=1   mic-after=Mic closed  engine-recording-after=false
cycle  2  opened=yes  engine=["START","stop"]  asked=2   mic-after=Mic closed  engine-recording-after=false
cycle  3  opened=yes  engine=["START","stop"]  asked=3   mic-after=Mic closed  engine-recording-after=false
cycle  4  opened=yes  engine=["START","stop"]  asked=4   mic-after=Mic closed  engine-recording-after=false
cycle  5  opened=yes  engine=["START","stop"]  asked=5   mic-after=Mic closed  engine-recording-after=false
cycle  6  opened=yes  engine=["START","stop"]  asked=6   mic-after=Mic closed  engine-recording-after=false
cycle  7  opened=yes  engine=["START","stop"]  asked=7   mic-after=Mic closed  engine-recording-after=false
cycle  8  opened=yes  engine=["START","stop"]  asked=8   mic-after=Mic closed  engine-recording-after=false
cycle  9  opened=yes  engine=["START","stop"]  asked=9   mic-after=Mic closed  engine-recording-after=false
cycle 10  opened=yes  engine=["START","stop"]  asked=10  mic-after=Mic closed  engine-recording-after=false
```

And the thirty-second hold, which the old page could not survive past the first fleet poll:

```
t= 5s  stage=listening  Mic open  elapsed-shown="5s"
t=10s  stage=listening  Mic open  elapsed-shown="10s"
t=15s  stage=listening  Mic open  elapsed-shown="15s"
t=20s  stage=listening  Mic open  elapsed-shown="20s"
t=25s  stage=listening  Mic open  elapsed-shown="25s"
t=30s  stage=listening  Mic open  elapsed-shown="30s"
engine told:  ["START"]  then, on release, ["START","stop"]
```

**The negative control.** The same 74 checks run against `3af8a04` unmodified fail 35 of them, including every one named in 32.3.
A check that cannot fail against the code it guards is not guarding anything, and `CONTRIBUTING.md` requires this to be shown rather than assumed.

The eleven continuous-listening checks, and the five over a slow transcript, pass on BOTH trees, and that is the correct result rather than a weak one.
Continuous mode was never broken; it is the SECOND caller of the `/api/listen` edge, and an edge with two callers is how the first one drifted.
They are regression guards, not defect demonstrations, and they are labelled as such rather than counted among the 35.

### 32.7 What was NOT proven here, and cannot be from this seat

- **Real amplitude from real hardware.** The analyser is stubbed and returns a constant level, so "the bars move when the captain speaks" is untested and untestable here.
- **The browser's own permission prompt.** The refusal PATH is exercised; the prompt the captain sees is not.
- **That the dictation app behaves as this models it.** The model comes from `bin/fm-dictate.ps1` and `Invoke-FmSpeechCapture`'s description - one flag that starts and stops, no silence cutoff of its own, which is why the page owns a VAD for continuous mode. That is a modelled assumption, not a measurement against the app.
- **Layout, at any window size.** Unchanged by this work and still measured only in a real browser.
- **A live bridge end to end.** No listener was started. The HTTP surface is wired to a machine that is covered by 29 Pester cases, but the two together have not been run against a real engine.

**One limitation the fix does not remove, recorded rather than hidden.**
A transcript still arriving from the PREVIOUS press is now held for the page instead of broadcast, so it is delivered as the answer to the press that is in flight when it lands.
The bridge cannot tell that line apart from the current capture's, because the engine hands over text with nothing identifying which capture produced it.
That is the dictation path's own timing and is out of this task's scope; it can only be fixed by the engine correlating a transcript to a capture.
What has changed is that it can no longer be asked mid-hold, and can no longer desynchronise the toggle.

### 32.8 The suite and the analyzer

Both runs from one keeper, at `33ad893`, which is every line of code this task
ships. The only commit after it is this section and a correction to
`CONTRIBUTING.md` - two Markdown files, neither of them swept by the analyzer and
neither read by a test.

```
Invoke-Pester -Path ./tests    run A   2438 passed,  9 failed, 18 skipped   (39.5m)
Invoke-Pester -Path ./tests    run B   2447 passed,  0 failed, 18 skipped   (40.7m)
Invoke-ScriptAnalyzer, repo-wide, via tests/FmAnalyzer.Tests.ps1
                                       zero findings at every severity
```

48 files in one process each time.

**RUN B IS THE NUMBER, AND RUN A IS WHY.** All nine of run A's failures are the
instruction-surface set: this worktree is a fresh clone, `core.symlinks` is false
on Windows, so git leaves `CLAUDE.md` and `.claude/skills` as the 9-byte and
14-byte placeholder files that hold their target text.
Everything that reads the operating contract fails against those until
`tests/FmInstall.Tests.ps1` runs `fm-setup.ps1` against this checkout and repairs
them, part-way through the same run.
Run B starts with the surface already repaired and finds nothing.
None of the nine touches anything this task changed - they are `this checkout's
own instruction surface`, `Invoke-FmDoctor`, and the two setup checks either side
of them.

**The earlier baseline in section 31 was thirteen, and four of those are absent
here for a reason worth writing down.** Those four were a property of how the
suite was LAUNCHED rather than of the tree: `Get-FmBridgeHouseWork` treats a
command line containing the words `Invoke-Pester` as a test run, and section 31's
keeper started the suite from a script file, where that string appears nowhere.
This keeper starts its child with `-Command "Invoke-Pester ..."`, so the string is
present and those four pass. That is the launcher, not a fix - the underlying
strict-mode reads on an empty result are still there for the areas that own them.

Eighteen skipped is seventeen pre-existing plus one added here: `did not run the
page checks, and here is why`, which is present so a machine WITHOUT node reports
the gap rather than a clean run that proved nothing. Node is on this machine, so
it skips.

**The checkout was dirtied by the run and restored without git.** `fm-setup.ps1`
turns `.claude/skills` into a junction, and a git write to that path deletes the
link's target - the whole skills tree. Both files were put back to the bytes git
wants by writing them directly, and the junction was removed with
`Directory.Delete(path, $false)` so nothing could walk through it.

## 33. The first clean-machine install: it crashed, and PowerShell 7 could not be found - `PROVEN (Windows 11) FOR THE DEFECTS AND THE FIXES, NOT FOR A CLEAN MACHINE`

Dated 2026-08-20, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\12\firstmate-win`,
PowerShell 7.6.4, Windows 11 Pro 10.0.26200, branched from `main` at `9508233`.

Section 31 ended by naming exactly one thing this installer had never done: an actual install.
It said so in as many words - "the DOWNLOAD itself, and `Invoke-FmToolRoute` actually executing a vendor installer, have not been executed anywhere.
They are the one part of this area that a clean machine is needed to prove."
The captain then closed that gap the hard way, on a genuinely clean Windows 11 machine, and it produced three defects in the order a newcomer meets them.

**READ THE HEADING'S QUALIFIER.**
This machine has every tool the installer installs, so nothing here is a clean-machine run.
What was proven is stated against each item below, and 33.5 is the honest list of what still rests on reasoning.

### 33.1 The three defects, as the captain met them

```
1.  .\install.ps1 : File ...\install.ps1 cannot be loaded because running
    scripts is disabled on this system.
2.  PowerShell 7 installed "successfully" and was in no Start menu and nowhere
    else a person looks.
3.  Invoke-FmToolRoute: module/Firstmate/Public/Install-FmMachine.ps1:408
      The property 'Tool' cannot be found on this object.
```

The captain's own words on the second one:

> as first step it install powershell 7 version but after success install
> message it not visible in start menu or anywhere

Everything before the crash worked and was left alone: the wrong-shell detection and relaunch, the detection table, the Pester version explanation, the no-mistakes skip.

### 33.2 The crash, reproduced at the captain's own stack frame - `PROVEN`

Reproduced twice, at two depths, before anything was changed.
Neither reproduction installed anything.

At the seam, with the record the real producer publishes:

```
requirement properties: Kind, Name, Command, Label, Why, Required, Present,
    Path, Version, Latest, Minimum, MinimumSource, MinimumCapability,
    Classification, Route, UpdateCommand, Reason, Question
has Tool?  False
CRASH: The property 'Tool' cannot be found on this object. Verify that the
    property exists.
```

And through `Install-FmMachine -Approved`, the captain's own path, driven at a plan whose requirements were all made inert except one `missing` with a route that installs nothing:

```
CRASH: The property 'Tool' cannot be found on this object.
  at: Install-FmMachine.ps1:408 char:23
  +   $result = Invoke-FmToolRoute -Entry $requirement -Route $requiremen ...
```

The same frame and the same message the captain reported, and the run died there - before `Install-FmHome`, before the shim, before the doctor - so it wrote nothing.

`Invoke-FmToolRoute` took an untyped `-Entry` record beside the route and built its result from `$Entry.Tool`.
Nothing declared what shape `-Entry` had to be.
Its one caller passes a `Get-FmMachineInstallPlan` requirement, which publishes `Name`.

**Why every test passed over it.**
Not because the tests were thin - the area has sixty-odd - but because no test ever put the planner's own records through the install call, and every test that touched a requirement built one for itself.
The `-WhatIf` test that drives `Install-FmMachine` skips the loop body entirely.
A record a test writes proves the function accepts THAT record, which was never the question.

The fix removes the shape rather than correcting it: `-Entry` is gone, the route is the only record passed, and it names its own tool.
`CONTRIBUTING.md`'s cross-area composition section now carries the rule.

After the fix, every requirement the real planner produces, through the real call, under `-WhatIf` so nothing downloads:

```
git                  tool=git                 action=needs-admin
node                 tool=node                action=needs-admin
claude               tool=claude              action=skipped (WhatIf)
herdr                tool=herdr               action=skipped (WhatIf)
treehouse            tool=treehouse           action=skipped (WhatIf)
gh                   tool=gh                  action=skipped (WhatIf)
gh-axi ... quota-axi tool=<each>              action=skipped (WhatIf)
Pester               tool=Pester              action=skipped (WhatIf)
PSScriptAnalyzer     tool=PSScriptAnalyzer    action=skipped (WhatIf)
```

That is `tests/FmToolInstall.Tests.ps1`, "running a route on what the planner actually hands over".
`-WhatIf` is not a weaker check for THIS defect: the crash was on the first line of the function body, which `-WhatIf` reaches before it declines to do anything.

### 33.3 Scripts are disabled on a clean machine - `PROVEN`

The first command in our own instructions could not run.
Reproduced here without changing any machine setting, by giving a CHILD shell the policy a clean machine has:

```
powershell -NoProfile -ExecutionPolicy Restricted -Command
    "Set-Location <checkout>; .\install.ps1 -DetectOnly -Offline"

.\install.ps1 : File ...\install.ps1 cannot be loaded because running scripts
is disabled on this system. For more information, see about_Execution_Policies
    + FullyQualifiedErrorId : UnauthorizedAccess
```

The documented form, from that same Restricted shell:

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DetectOnly -Offline

  FIRSTMATE - install
  This is Windows PowerShell 5.1.26100.8115. Firstmate is PowerShell 7 only -
  Re-running under C:\Program Files\PowerShell\7\pwsh.exe...
  what this machine has:   [13 requirements, classified]
  -DetectOnly: nothing was changed.                              exit 0
```

`README.md`, `docs/windows-quickstart.md` and `install.ps1`'s own help all give that form now.
`Set-ExecutionPolicy` is deliberately not what is documented: the first thing a newcomer types must not be a change to their machine's security settings, and `-ExecutionPolicy Bypass` on the command line applies to the one process it starts.

Both runs above are now a test.
`tests/FmModuleAssembly.Tests.ps1` takes the command OUT of `README.md` and runs it, with the bare form as its negative control, so a README that regresses fails the suite rather than the next clean machine.
It skips itself, with the reason, where Windows PowerShell 5.1 is absent or a Group Policy pins the execution policy.

### 33.4 PowerShell 7 was installed and could not be found - `PROVEN for the mechanism`

The route is `install-powershell.ps1 -Destination "$env:LOCALAPPDATA\Programs\PowerShell7" -AddToPath`, and it was chosen because it is the one that needs no administrator.
It expands an archive: it writes `pwsh.exe`, it edits the user PATH, and it registers nothing.
Only the machine-wide MSI creates a Start menu entry, a Windows Terminal profile or the context-menu entries.

**The route was kept.**
No-administrator is the harder constraint and the right one, and switching to an unverified per-user MSI invocation would be exactly the "never trust a route you have not read" defect this area exists for.

What was added is a `.lnk` in the captain's OWN `Start Menu\Programs` folder - the folder Start and its search box read, and the one that needs no elevation - plus output that says where the executable went and how to open it.

Measured here, against this machine's REAL Start menu, read-only under `-WhatIf`:

```
folders searched:
  C:\Users\ADMIN\AppData\Roaming\Microsoft\Windows\Start Menu\Programs
  C:\ProgramData\Microsoft\Windows\Start Menu\Programs

Action   : already
Detail   : in Start as 'PowerShell 7 (x64)' -> C:\Program Files\PowerShell\7\pwsh.exe
Shortcut : C:\ProgramData\...\Start Menu\Programs\PowerShell\PowerShell 7 (x64).lnk
```

That is the vendor's own MSI entry, found on the machine that has one, so no second entry is added.
It is nested in a `PowerShell` subfolder and named nothing this could have guessed, which is why the search is recursive and matches on what each `.lnk` POINTS AT rather than on its name.

Creating one is exercised for real in `tests/FmToolInstall.Tests.ps1` against disposable directories: the `.lnk` is written, and its target is read back through `WScript.Shell` rather than trusted - a shortcut pointing at nothing is precisely the outcome this exists to refuse.
The idempotence, the user-folder choice, the nested vendor entry, a decoy pointing at Windows PowerShell 5.1, and `-WhatIf` each have their own test.

What the report prints, rendered from a per-user install:

```
PowerShell 7 - the shell everything here runs in:
  installed at  C:\Users\<them>\AppData\Local\Programs\PowerShell7\pwsh.exe
  open it from  Start, as "PowerShell 7" - or type pwsh in any NEW window
  the Windows Terminal profile and the right-click entries need the machine-wide
  installer, which is the one thing here that needs administrator. Optional, once:
      winget install Microsoft.PowerShell
```

and from a machine that already registers it, where that last block is correctly absent:

```
PowerShell 7 - the shell everything here runs in:
  installed at  C:\Program Files\PowerShell\7\pwsh.exe
  open it from  Start, as "PowerShell 7 (x64)" - or type pwsh in any NEW window
```

`install.ps1` also says where it went at the moment the captain previously saw "success" and nothing else - in the Windows PowerShell 5.1 block, before the relaunch that adds the Start entry.

It runs on EVERY install rather than only the run that installed the shell, so the captain's machine - already in the bad state - is repaired by re-running.

**CORRECTED BY SECTION 34: that repair has still never executed on the captain's machine.**
It is step 4 of the install, and their next run died in step 1 on a refused launch.
The sentence above describes what the code does, not something that has happened there.

### 33.5 What was NOT run, and what rests on reasoning

Stated plainly, because the whole reason this task existed is that section 31 was honest about the same gap.

- **No clean machine was used, and no tool was installed on this one.**
  This machine has git, Node, the Claude CLI, herdr, treehouse, gh, the five axi tools, Pester and PSScriptAnalyzer, and the brief forbids installing over them.
  Every route call recorded above ran under `-WhatIf`.
- **A full `install.ps1` run to completion on a machine missing the tools is still unproven.**
  What is proven is that the step it died on now accepts every record the planner produces, for all thirteen of them, and that the run reaches that step.
- **PowerShell 7 was not installed by this work.**
  That the `-Destination` route registers nothing is the captain's measurement, not this seat's: their run reported success, relaunched under `C:\Users\<them>\AppData\Local\Programs\PowerShell7\pwsh.exe`, and no Start entry existed.
  It is consistent with what that route does - expand a zip - but it was not re-measured here.
- **No `.lnk` was written into this machine's real Start menu.**
  The real folders were only read.
  Creation and read-back were proven against disposable directories, and the default folder choice was asserted under `-WhatIf`.
- **How quickly Windows Search indexes a new per-user Start entry was not measured.**
  The entry is in the Start menu's app list; whether the search box finds it in the same second is not claimed.
- **`winget install Microsoft.PowerShell` was not run.**
  It is named as the optional elevated route for the Windows Terminal profile and the context-menu entries, which is the same claim this repo already makes about the two winget routes it declares as needing administrator.

### 33.6 The suite and the analyzer, on this branch

Both passes run back to back in one keeper, on the final tree, with the analyzer
sweep taken separately as well as inside the suite.

```
Invoke-Pester -Path ./tests    run A   2461 passed, 0 failed, 18 skipped   (28.5m)
Invoke-Pester -Path ./tests    run B   2461 passed, 0 failed, 18 skipped   (24.2m)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
                                       zero findings at every severity
```

48 files in one process each time, and a clean working tree afterwards - only
the ten files this task changed.

**Run A is clean here, and section 32's was not, for a reason worth stating
rather than reading as an improvement.** The instruction-surface failures that
open a fresh worktree's first run were already gone before this run started:
earlier in this task the install and tool files were run on their own to gate
the first commit, and `tests/FmInstall.Tests.ps1` repairs `CLAUDE.md` and
`.claude/skills` as part of its own work. That first subset run showed the
familiar set - six of them, all doctor, backend and separate-home checks - and
the immediate re-run showed none. So this is still "report the SECOND run"; the
second run simply happened earlier than usual.

The eighteen skips are all pre-existing and none is new: fifteen are symlink
tests on a host without Developer Mode or POSIX-only cases, two are the Job
Object degradation pair, and one is the bridge page-check reporter.

The analyzer needed one fix during this work and it is recorded rather than
quietly absorbed: `Get-FmMachineShellLine` built its lines into an untyped array
and tripped `PSUseOutputTypeCorrectly`. Declaring `[string[]]$lines` is the fix,
not widening the `OutputType`.

## 34. The second install attempt: a refused launch, and a diagnosis that was wrong - `PROVEN (Windows 11) FOR THE MECHANISM AND THE FIX, NOT FOR THE REFUSAL ITSELF`

Dated 2026-08-20, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\13\firstmate-win`,
PowerShell 7.6.4, Windows 11 Pro 10.0.26200, branched from `main` at `b27acca`.

Section 33 fixed the crash the captain's first real install hit and said, in 33.5, that a full run to completion on a machine missing the tools was still unproven.
The captain ran it again.
It died again, at the same function, for an entirely different reason - and the first explanation offered for it was wrong.
That wrong explanation is recorded here on purpose, because leaving it out would be the more comfortable and less useful record.

### 34.1 What the captain met

```
PS C:\Users\higet\Documents\firstmate> .\install.ps1
...
Re-running under C:\Users\higet\AppData\Local\Programs\PowerShell7\pwsh.exe...
[the whole detection table then prints correctly]
...
Invoke-FmToolRoute: ...\Install-FmMachine.ps1:411
  Program 'pwsh.exe' failed to run: An error occurred trying to start process
  'C:\Users\higet\AppData\Local\Programs\PowerShell7\pwsh.exe'
  with working directory 'C:\Users\higet\Documents\firstmate'. Access is denied.
  At ...\Private\FmToolInstall.ps1:943 char:17
  + $output = @(& $pwsh -NoProfile -Command $command 2>&1 | ForEach-O ...
```

Everything up to that point worked, including the whole of section 33's fix: the wrong-shell detection, the re-launch, and a detection table that printed all thirteen requirements.
The run then ended at the first requirement whose route needs a child shell, with nothing installed and every later requirement unattempted and unreported.

### 34.2 The first diagnosis was WRONG, and the captain is what caught it

The first reading of that output was that `Adit` was being made to run a PowerShell 7 belonging to `higet` - two accounts, one private profile, and a permission denial that follows from it.
A whole task was briefed on that basis, including a rule about rejecting a per-user path belonging to another account.

**It was inferred from two usernames appearing in two different screenshots, and it was not checked.**
The captain then ran the entire thing as ONE user, from `C:\Users\higet\Documents\firstmate` as `higet`, and it failed identically.
Same user, same profile, same machine.
There is no cross-account problem here and this repo carries no rule about one.

The lesson is not about accounts.
It is that `Access is denied` plus a stack trace is a text a reader will complete with the most familiar explanation that fits, and permission problems between users are the most familiar of all.
That is the cost this section's fix is paid to remove.

### 34.3 The fact that makes the shape clear

**That same `pwsh.exe` had started successfully seconds earlier in the same run.**
The installer detected Windows PowerShell 5.1, re-launched itself under that exact path, and the detection table above printed FROM the re-launched process.
So the file is executable by this user, from this working directory, on this machine.

The question is therefore not "may this user run pwsh" - demonstrably yes - but what is different about the SECOND launch.

### 34.4 What differs between the two launches - `PROVEN`, locally

Three measurements, all made on this machine, all reproducible without a second account and without a machine that refuses anything.

**1. The message belongs to one .NET start path and no other.**
`Process.Start` with `UseShellExecute = $false` was pointed at a file that is not a program:

```
CreateProcess path : Exception calling "Start" with "1" argument(s):
  "An error occurred trying to start process
   'C:\Users\ADMIN\AppData\Local\Temp\fm-probe-....exe'
   with working directory 'C:\Users\ADMIN\...\firstmate-win'.
   The specified executable is not a valid application for this OS platform."
```

That is the captain's wording, with a different Win32 reason at the end.
"An error occurred trying to start process '\<exe>' with working directory '\<dir>'" is .NET's `ErrorStartingProcess` string, emitted from the `CreateProcess` path and used with a working directory only when one was set.

**2. Collecting the child's output forces that path.**
.NET refuses the other combination outright:

```
redirect+shellexecute: Exception calling "Start" with "1" argument(s):
  "The Process object must have the UseShellExecute property set to false
   in order to redirect IO streams."
```

`FmToolInstall.ps1:943` was `& $pwsh -NoProfile -Command $command 2>&1 | ForEach-Object`, which collects the child's merged output, so PowerShell has no choice: that launch is always `CreateProcess` with three redirected pipe handles.
`install.ps1`'s re-launch is `& $pwshCommand.Source ... -File $PSCommandPath` with nothing collected.
Measured from a real console, the two children differ accordingly - the uncaptured one reports `redirected = False`, the piped one `redirected = True`.
**They are not the same operation**, which is how one can be allowed and the next refused seconds later.

**3. A refused launch is terminating whatever the preference says.**

```
EAP=Continue -> THREW ApplicationFailedException
EAP=Stop     -> THREW ApplicationFailedException
```

So the unguarded invocation could only ever end the whole run.
This is also why the fix is a `try`/`catch` rather than an `$ErrorActionPreference` adjustment.

### 34.5 What refused it - `NOT PROVEN`, and this repo does not claim it

**The denial itself could not be reproduced here.**
Measured on this machine:

```
ControlledFolderAccess: 0
ProtectedFolders      :
ASR ids               :
ASR actions           :
```

Controlled folder access is off and no attack-surface-reduction rules are set, so nothing here refuses a launch.
Two candidates fit the captain's evidence and neither is established:

- **The working directory.** Both of their runs were inside Documents - `C:\Users\higet\OneDrive\Documents\firstmate` and `C:\Users\higet\Documents\firstmate` - and Documents is a Controlled-folder-access protected folder by default. Against this: an inaccessible working directory did NOT reproduce the failure here. `C:\System Volume Information`, which this account cannot list, was accepted as a working directory by both start paths - consistent with bypass-traverse-checking being granted to everyone by default, though that explanation was not itself measured.
- **The command line.** The requirement that dies first is the Claude CLI, whose route is `irm https://claude.ai/install.ps1 | iex`. A child shell started with a download-and-run one-liner is the canonical shape security software watches for, and it is present on the second launch and absent from the first. This was not tested, and testing it properly would mean running that exact line on this machine, which would install software the brief does not authorize.

Either would produce exactly what the captain saw.
Naming one as the cause would be the same mistake as 34.2, made a second time.

### 34.6 The fix, which is ours whichever it is

The captain cannot act on `Access is denied` and a stack trace, and neither could the reader who first tried.
So a refused launch is now an outcome:

- `Invoke-FmToolShellCommand` owns starting the child shell and never lets a refusal escape. `Invoke-FmToolRoute` reports it as `blocked`, and the run continues through every remaining requirement instead of ending at the first.
- `Get-FmToolLaunchRefusal` owns what is said, and it never quotes the exception. The raw text goes to `Write-Debug` and nowhere else.
- Detection stopped conflating three different facts. `Invoke-FmSessionCommandLine` now separates "not on PATH" from "would not start" from "ran and answered", and it no longer returns the exception text as though it were the command's output. A tool this machine refuses to start is classified `unusable` rather than as one that prints no readable version, because a version was not read - nothing ran.
- `unusable` is TOLD and SKIPPED, like `unsupported`. Installing a second copy into the same place would be refused the same way, so the run says so and reports the machine NOT READY.
- The same guard is on `install.ps1`'s own re-launch, the suite runner, the home setup and the command shim. The home setup matters most of those: it writes into the checkout, and the checkout is inside Documents on the machine that reproduces this, so it is the next thing a folder guard would refuse.
- An enabler is only satisfied if it actually starts, so a `winget` or `npm` that will not run blocks its routes with a reason instead of being rediscovered by each one.

What the captain would now see in place of the stack trace:

```
Windows refused to start 'C:\Users\...\PowerShell7\pwsh.exe' from
C:\Users\...\firstmate, so claude was not installed. The machine declined the
launch; the program itself did not fail. A launch refused with nothing but
"access is denied" is usually security software guarding how a program is
started, or Controlled folder access, which protects Documents - a checkout
that is not under Documents rules the second one out. Run this yourself in a
new PowerShell 7 window, then re-run this installer:
irm https://claude.ai/install.ps1 | iex
```

### 34.7 The coverage, and its negative control

The refusal is exercised for real rather than mocked: a file that is not a program, which `CreateProcess` declines on any machine.
`tests/FmToolInstall.Tests.ps1` drives the real detection, the real plan and the real route record through it, in both directions - a tool that will not start is `unusable`, and `git`, which does start, is not.
The plan test narrows PATH onto stubs and stands `Update-FmToolSessionPath` down, because that function reads the persisted environment and this suite must never write it.

One test runs the captain's first command end to end: `install.ps1` under the real Windows PowerShell 5.1, with a `pwsh` on PATH that resolves and cannot be started.
It asserts exit 1, the plain-words output, and the ABSENCE of `failed to run`, `An error occurred trying to start process` and `At line:`.

Every guard was reverted on the finished tree, one at a time, to check the tests are not passing for some other reason.
All five put their own failure back and nothing else:

| reverted | the test that failed |
| --- | --- |
| the child-shell `try`/`catch` in `Invoke-FmToolShellCommand` | turns a refused install command into an outcome, not a terminating error |
| the `try`/`catch` around `install.ps1`'s re-launch | tells the captain plainly when install.ps1 cannot re-launch itself |
| the `unusable` branch of `Get-FmMachineToolVerification` | fails the verification pass over a tool that will not start, and says which failure it is |
| the `try`/`catch` around the suite's `Start-Process` | reports a suite it could not start as NOT RUN, in words, rather than crashing the report |
| the enabler's launch probe | calls an enabler that will not start UNSATISFIED rather than present |

```
tests/FmToolInstall.Tests.ps1   81 passed, 0 failed
```

### 34.8 What was NOT run

- **No clean machine, and no tool installed.** Every route call here ran against a shell that cannot start, which is also what makes running them safe.
- **The refusal itself was never reproduced.** See 34.5. Everything about WHY the captain's machine declined the launch rests on their evidence and on reasoning, not on a measurement from this seat.
- **A full `install.ps1` run to completion is still unproven**, exactly as section 33.5 said. What is now proven is that a refused launch cannot end the run.
- **The captain's machine was not touched.** No profile, no Start menu entry, no Defender setting.
- **`Set-FmMachineShellShortcut` has still never run on the captain's machine.** It is step 4, and both of their runs died in step 1. Section 33.4's "a machine already in that state is repaired by re-running" describes what the code does, not something that has happened; `docs/windows-install.md` now carries that qualifier.

### 34.9 The suite and the analyzer, on this branch

Both passes run back to back in one keeper, on the final tree, with the analyzer
sweep taken inside the suite as `tests/FmAnalyzer.Tests.ps1`.

```
Invoke-Pester -Path ./tests    run A   2474 passed, 0 failed, 18 skipped   (34m)
Invoke-Pester -Path ./tests    run B   2474 passed, 0 failed, 18 skipped   (39m)
Invoke-ScriptAnalyzer, repo-wide, via tests/FmAnalyzer.Tests.ps1
                                       zero findings at every severity
```

48 files in one process each time, and a clean working tree afterwards - only
the files this task changed.

2474 is 2461 plus the thirteen tests this task adds, which is the whole
difference from section 33.6's baseline.

**RUN A IS CLEAN HERE, AND THAT IS NOT AN IMPROVEMENT.** The instruction-surface
failures a fresh worktree's first run produces had already been cleared: earlier
in this task the install and tool files were run on their own to gate the first
commit, and `tests/FmInstall.Tests.ps1` repairs `CLAUDE.md` and `.claude/skills`
as part of its own work. That subset run showed the familiar set - six of them,
all `$doctor.Healthy` on the doctor, backend and separate-home checks - and the
immediate re-run showed none. So this is still "report the SECOND run"; the
second run simply happened earlier than usual, exactly as in 33.6.

The eighteen skips are all pre-existing and none is new.

---

## 35. winget could not succeed unattended, and the failure was reported as an administrator problem - `PROVEN (Windows 11) FOR THE MECHANISM, THE REPORTING AND THE FIXES, NOT FOR THE AGREEMENT PROMPT ITSELF`

Dated 2026-08-20, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\14\firstmate-win`,
PowerShell 7.6.4, Windows 11 Pro 10.0.26200, branched from `main` at `6cbb918`.

Section 34 fixed the refused launch that ended the captain's second install.
The same install log carries a second failure that section 34 did not touch, and a report of it that was worse than the failure.

### 35.1 What the captain met, and what they were told

```
[skipped] Node.js - FAILED: 'winget install OpenJS.NodeJS' exited 1:
          Node.js OpenJS.NodeJS winget
...
Node.js   FAILED   'winget install OpenJS.NodeJS' exited 1
```

This was an **Administrator** Windows PowerShell - the title bar said so.
The same log shows winget v1.9.25200 present and running, so winget was neither missing nor unreachable.

**The captain was told this needed administrator.**
They were already running as administrator, specifically because of that advice, and they pushed back on being told it again.
They were right.

### 35.2 The cause: `winget install <id>` with no agreement flags cannot complete unattended

winget asks the operator to accept its source agreements the first time it is used.
Run where it cannot ask - a script, or output collected through a pipeline, which is exactly how `Invoke-FmToolShellCommand` runs every route - it exits without installing anything.
Elevation is irrelevant to that, and so is winget's presence.

A bare `winget install <name>` is also a SEARCH rather than an exact match, and a search that matches several packages asks a second question nobody is there to answer either.

**This is the one claim in this section taken from the captain's log rather than measured here.**
This machine has already accepted winget's source agreements, and resetting them would change global machine state to reproduce a prompt the fix removes either way, so it was not done.
What WAS measured here is that the flags exist on this winget, that they are accepted, and that the exact-match form resolves to one package:

```
PS> & "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version
v1.29.280

PS> winget install --help
  --id                                 Filter results by id
  -e,--exact                           Find package using exact match
  --accept-package-agreements          Accept all license agreements for packages
  --accept-source-agreements           Accept all source agreements during source operations

PS> winget search -e --id OpenJS.NodeJS --accept-source-agreements
Name    Id            Version Source
-------------------------------------
Node.js OpenJS.NodeJS 26.7.0  winget
```

That last table is worth looking at twice.
Its final row carries the same three fields, in the same order, as the fragment the captain was handed as the cause of their failure: name, id, source.
Their report's "error" has the shape of a row of winget's package table, not the shape of an error.

### 35.3 The fix to the commands - `PROVEN`

`Get-FmBootstrapWingetCommand` is the one owner of the shape, so the flags are stated once rather than once per package, and every winget command this repo prints or runs comes from it:

```
node     winget install -e --id OpenJS.NodeJS --accept-source-agreements --accept-package-agreements
git      winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
gh       winget install -e --id GitHub.cli --accept-source-agreements --accept-package-agreements  # or ./install.ps1, ...
curl     winget install -e --id cURL.cURL --accept-source-agreements --accept-package-agreements
jq       winget install -e --id jqlang.jq --accept-source-agreements --accept-package-agreements

update   winget upgrade -e --id Git.Git --accept-source-agreements --accept-package-agreements
digest   MISSING: node (install: winget install -e --id OpenJS.NodeJS --accept-source-agreements --accept-package-agreements)
```

The two commands printed for a human to run - the prerequisite check's fix line and the optional elevated PowerShell 7 route - come from the same builder, because a captain who pastes one into a script meets the same prompt.

**Those command lines are what this commit produced and are no longer current**: section 36 adds `--source winget` to every one of them, for a failure this shape did not survive on a clean VM.
Read 36.4 for the lines as they stand.

**Two of the routes named packages that do not exist**, which exact matching turned from a vague search into a measurable fact.
Every id was checked against this machine's winget:

```
OpenJS.NodeJS          exit=0   Node.js OpenJS.NodeJS 26.7.0  winget
Git.Git                exit=0   Git  Git.Git 2.55.0.3 winget
GitHub.cli             exit=0   GitHub CLI GitHub.cli 2.97.0  winget
cURL.cURL              exit=0   cURL cURL.cURL 8.21.0.6 winget
jqlang.jq              exit=0   jq   jqlang.jq 1.8.2   winget
Microsoft.PowerShell   exit=0   PowerShell Microsoft.PowerShell 7.6.5.0 winget
orca                   exit=-1978335212 No package found matching input criteria.
cmux                   exit=-1978335212 No package found matching input criteria.
```

`winget install orca` and `winget install cmux` were never going to work on any machine, which is the same defect as the `npm install -g treehouse` route this area was built to remove: a package name nobody checked.
Both are also backends this port cannot drive, since `Start-FmWorker -Backend` is `[ValidateSet('herdr')]`, so they now answer exactly as tmux already did - `MISSING_MANUAL`, naming a human step, through `Get-FmBootstrapManualInstallUrl`:

```
tmux    MISSING_MANUAL: tmux (instructions: https://firstmate.invalid/windows-backends)
orca    MISSING_MANUAL: orca (instructions: https://firstmate.invalid/windows-backends)
cmux    MISSING_MANUAL: cmux (instructions: https://firstmate.invalid/windows-backends)
```

A step nobody can take is a better answer than a step that reports itself as failed, and it is what "state plainly that it needs a human" means here.
This one was found by the fix rather than by the report: `-e --id` is what turns "a search returned nothing useful" into "this package does not exist".

**That was committed on its own, first**, as `9880b28`, so it could be landed while the captain was blocked; everything below it is the second commit.

### 35.4 The reporting was the worse half - `PROVEN`

The old report took the command, the exit code, and the LAST non-blank line the tool printed.
Reading the last line is not a summary of a failure, it is a coin toss, and this machine will demonstrate it losing.
`winget install` with a rejected argument prints 51 lines, of which the cause is the THIRD and the last is help text:

```
Windows Package Manager v1.29.280
© 2026 Microsoft. All rights reserved.
Argument name was not recognized for the current command: '--definitely-not-a-flag'
[... 47 lines of usage ...]
More help can be found at: https://aka.ms/winget-command-install
```

So nothing tries to pick out the one line that is the cause.
The tool's words are quoted; a truncation keeps both ends and says how many lines it dropped; a tool that printed nothing is reported as having printed nothing, which is a different fact from "no cause was reported".

### 35.5 The exit code was the child shell's, not the tool's - `PROVEN`

`exited 1` told the captain nothing, and this is why.

```
PS> winget install -e --id Firstmate.NoSuchPackage.Test --accept-source-agreements --accept-package-agreements
No package found matching input criteria.
exit = -1978335212   hex = 0x8A150014

PS> pwsh -NoProfile -NonInteractive -Command "<that same command>"
child exit = 1
```

`pwsh -Command` reports its own verdict, 0 or 1, and discards the native code inside it.
Every winget failure this installer has ever reported therefore arrived as a bare 1 - a number that distinguishes nothing from anything and has no meaning to look up.

`Get-FmToolShellCommandText` appends an epilogue that hands the tool's own code back, on its own line because the published one-liners carry trailing `#` notes and on one line a comment would swallow it.
`$?` stays the authority on WHETHER the run failed and `$LASTEXITCODE` only supplies the number, so a code left behind by an earlier native call inside a vendor script cannot turn a working install into a reported failure.
Four paths measured through `Invoke-FmToolRoute`, comparing only what this changes - the outcome and the code reported:

| command | outcome | code reported |
| --- | --- | --- |
| `winget install -e --id <no such package> ...` | `failed` | was `1`, now `-1978335212 (0x8A150014)` |
| `cmd /c exit 42` | `failed` | was `1`, now `42` |
| `cmd /c exit 3 \| Out-Null; Write-Output done` | `installed` | unchanged: a working install stays installed |
| `Write-Output ok` | `installed` | unchanged |

The third row is the one that had to be checked rather than assumed.
Preferring `$LASTEXITCODE` alone would have reported that install as a failure on a leftover 3, which is why `$?` and not the number decides whether a run failed.
A vendor script that throws never reaches the epilogue at all and pwsh exits 1 by itself, exactly as before.

### 35.6 What the captain would see now, on the same failure - `PROVEN`

What the captain was given, from their log:

```
[skipped] Node.js - FAILED: 'winget install OpenJS.NodeJS' exited 1:
          Node.js OpenJS.NodeJS winget
```

The same SHAPE replayed through the real `Invoke-FmToolRoute` - a banner, the cause in the middle, and a package table whose last row is the fragment that used to be the whole report - now returns this.
The command is a `Write-Output` stand-in because reproducing the agreement refusal itself would mean resetting this machine's winget state; the reporting path under test is the real one.

```
'Write-Output "Windows Package Manager v1.9.25200"; ...' exited 1.
what it printed, in full:
    Windows Package Manager v1.9.25200
    The source agreements were not accepted.
    Name    Id            Version Source
    Node.js OpenJS.NodeJS 26.7.0  winget
```

The cause is in the report, and the table row is still there rather than standing in for it.

And on a real winget failure, with the exit code and its meaning both recovered:

```
'winget install -e --id Firstmate.NoSuchPackage.Test --accept-source-agreements --accept-package-agreements'
    exited -1978335212 (0x8A150014), which means winget found no package matching what it was asked for.
what it printed, in full:
    No package found matching input criteria.
run as: & "C:\Users\ADMIN\AppData\Local\Microsoft\WindowsApps\winget.exe" install -e --id Firstmate.NoSuchPackage.Test ...
```

`Get-FmToolExitCodeMeaning` carries only codes measured on this machine - `0x8A150002` and `0x8A150014` - and returns nothing for anything else.
An unrecognised code gets no meaning at all rather than a plausible one, because a plausible-sounding cause invented for a failure is precisely what started this.

### 35.7 The rest of the class

Anything that can stop and ask when nobody is there is in this class, so the whole repo was swept for the rest of it.
Four more members turned up: two needed a change, and two were already correct and are recorded here so the next sweep does not have to establish it again.

- **`Install-Module`** asks "are you sure you want to install the modules from 'PSGallery'?" on a machine where the gallery is Untrusted, which is the default. `-Force` already answered that; `-Confirm:$false` was missing and now refuses the other route to the same halt, a confirmation inherited from a caller. The portable route already defended itself this way and this one did not.
- **The child shell** is started `-NonInteractive`, so PowerShell's own prompts do not wait on a person who is not there. Measured: a route whose command calls `Read-Host` returns instead of waiting. It governs PowerShell's prompting only - a native program's prompt is its own business, which is what the winget flags are for.
- **`install.ps1`'s two questions** are the deliberate exception and were already correct: both take the safe default under `-Unattended` or a redirected stdin rather than waiting. Nothing was changed there.
- **`gh auth login`** genuinely needs a human, and bootstrap says so as `NEEDS_GH_AUTH` rather than trying to run it. That is the "state plainly that it needs a person" answer, and it was already in place.

### 35.8 The negative controls

Every guard here was checked against the code it guards, by putting the defect back.

```
flags removed from Get-FmBootstrapWingetCommand
  -> 3 failed: the catalog sweep, the elevated PowerShell 7 route, the upgrade command

reporting reverted to the last-line + child-verdict form
  -> 2 failed: 'keeps the cause, instead of the last line that happened to follow it'
               'reports the exit code the TOOL returned, not the child shell verdict'
```

The catalog sweep walks `Get-FmToolCatalog` rather than a list of today's tools, so a winget route added later without the flags fails in the suite rather than on a machine.

### 35.9 What was NOT run

- **No tool was installed, and the captain's machine was not touched.** Every winget call made here was a `search`, a `--help`, or an install of a package id that does not exist. Nothing was installed, upgraded or removed on this machine.
- **The agreement prompt itself was never reproduced.** See 35.2. This machine has already accepted the agreements, and resetting winget's source state to reproduce a prompt would change global machine state for no gain the fix does not already give. That one link in the chain rests on the captain's log and on winget's documented behaviour, not on a measurement from this seat.
- **`install.ps1` has still never run to completion on a machine missing the tools**, exactly as sections 33.5 and 34.8 said. This section removes a reason it could not; it does not prove it now does.
- **The `Install-Module` prompt was not reproduced either.** PSGallery is already Trusted on this machine and the NuGet provider is present (3.0.0.1), so there is nothing here to prompt. `-Confirm:$false` is a flag matching what the portable route already carries, not a measured repair.

### 35.10 The suite and the analyzer, on this branch

Both passes run back to back in one keeper, on the final tree, with the analyzer
sweep taken inside the suite as `tests/FmAnalyzer.Tests.ps1`.

```
Invoke-Pester -Path ./tests    run A   2490 passed, 0 failed, 18 skipped   (58m)
Invoke-Pester -Path ./tests    run B   2490 passed, 0 failed, 18 skipped   (49m)
Invoke-ScriptAnalyzer, repo-wide, via tests/FmAnalyzer.Tests.ps1
                                       zero findings at every severity
```

2490 is section 34.9's 2474 plus the sixteen tests this task adds: two with the
flags commit, fourteen with this one.

**RUN A IS CLEAN HERE, AND THAT IS NOT AN IMPROVEMENT**, for exactly the reason
34.9 gives. The instruction-surface failures a fresh worktree's first run
produces had already been cleared: `tests/FmInstall.Tests.ps1` was run on its own
earlier in this task to gate the first commit, and it repairs `CLAUDE.md` and
`.claude/skills` as part of its own work. That subset run showed the familiar six
- all `$doctor.Healthy` - and the immediate re-run showed none. So this is still
"report the SECOND run"; the second run simply happened earlier than usual.

The eighteen skips are all pre-existing and none is new.

Two earlier whole-suite runs were started and DISCARDED rather than reported,
because the tree changed under them: the first while this section's reporting fix
was still being written, the second when `orca` and `cmux` were found not to be
winget packages. A suite run against a tree that no longer exists proves nothing
about the one that does.

## 36. A source the install never needed stopped it, and the reporting fix is why that took five minutes - `PROVEN (Windows 11) FOR THE FAILURE, THE SOURCES AND THE FIX, NOT FOR THE CERTIFICATE CONDITION`

Dated 2026-08-20, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\15\firstmate-win`,
PowerShell 7.6.4, Windows 11 Pro 10.0.26200, branched from `main` at `33eee1a`.
The fix was committed alone as `a8dcbe5` and landed while the captain was blocked; this section is the second commit, written on `87aa469`.

Section 35 made every winget command answerable with nobody at the keyboard, and made a failed install carry its own exit code and the tool's own words.
The captain then rebuilt a clean VM and ran the installer with both of those in.
It still installed nothing - and this time the report said exactly why.

### 36.1 What the captain met

```
[skipped] Node.js - FAILED: 'winget install -e --id OpenJS.NodeJS
          --accept-source-agreements --accept-package-agreements'
          exited -1978335138 (0x8A15005E).
  ...
  Failed when searching source: msstore
  An unexpected error occurred while executing the command:
  0x8a15005e : The server certificate did not match any of the expected values.
  The following packages were found among the working sources.
  Please specify one of them using the --source option to proceed.
  Name    Id            Source
  Node.js OpenJS.NodeJS winget
```

Read the last two lines before anything else.
The `winget` source was healthy and it HAD the package.
The source that failed was `msstore`, with a certificate mismatch - a TLS-inspecting proxy, a clock skew, a locked-down image - and none of that is under this repo's control.

### 36.2 The mechanism: one erroring source is enough, and it asks a question nobody can answer

winget queries every configured source that is not marked explicit, and when one of them errors it will not go ahead with the package the others found.
It says which source failed, says the package WAS found among the working sources, and asks to be told which one to use.
Measured here, winget v1.29.280, 2026-08-20:

```
PS> winget source list
Name        Argument                                      Explicit
------------------------------------------------------------------
msstore     https://storeedgefd.dsx.mp.microsoft.com/v9.0 false
winget      https://cdn.winget.microsoft.com/cache        false
winget-font https://cdn.winget.microsoft.com/fonts        true

PS> winget install --help
  -s,--source                          Find package using the specified source
```

The `Explicit` column is the whole finding.
`winget-font` is `true`, so it is consulted only when it is named; `msstore` is `false`, so every unpinned command consults it whether this repo wants it or not.
That is a dependency on a component being healthy, taken without ever asking for it.

And the failure it produced is not a soft one.
"Please specify one of them using the `--source` option to proceed" is a question, asked into a pipe by a run that has nobody at it, and the exit that follows installs nothing - which is the same shape as the agreement prompt section 35 removed, arriving through a different door.

### 36.3 The Store could not have supplied these packages anyway

This is the part that settles it.
Measured here, 2026-08-20, every id this repo names resolves from the `winget` source alone, and the source that failed the install has none of them:

```
PS> winget search -e --id <id> --source winget --accept-source-agreements
OpenJS.NodeJS          exit=0   Node.js       OpenJS.NodeJS        26.7.0
Git.Git                exit=0   Git           Git.Git              2.55.0.3
GitHub.cli             exit=0   GitHub CLI    GitHub.cli           2.97.0
cURL.cURL              exit=0   cURL          cURL.cURL            8.21.0.6
jqlang.jq              exit=0   jq            jqlang.jq            1.8.2
Microsoft.PowerShell   exit=0   PowerShell    Microsoft.PowerShell 7.6.5.0

PS> winget search -e --id <id> --source msstore --accept-source-agreements
OpenJS.NodeJS          exit=-1978335212   No package found matching input criteria.
Git.Git                exit=-1978335212   No package found matching input criteria.
```

msstore was not merely unnecessary to this install.
It could never have supplied a single package in it, and it was still able to stop the whole thing.
A source we do not use must not be able to fail our install.

### 36.4 The fix - `PROVEN`

`--source winget` goes on the command in `Get-FmBootstrapWingetCommand`, which section 35 already made the one owner of the shape, so all eight surfaces pick it up from one line:

```
node     winget install -e --id OpenJS.NodeJS --source winget --accept-source-agreements --accept-package-agreements
git      winget install -e --id Git.Git --source winget --accept-source-agreements --accept-package-agreements
gh       winget install -e --id GitHub.cli --source winget --accept-source-agreements --accept-package-agreements  # or ./install.ps1, ...
curl     winget install -e --id cURL.cURL --source winget --accept-source-agreements --accept-package-agreements
jq       winget install -e --id jqlang.jq --source winget --accept-source-agreements --accept-package-agreements

ps7      winget install -e --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements
update   winget upgrade -e --id Git.Git --source winget --accept-source-agreements --accept-package-agreements
digest   MISSING: node (install: winget install -e --id OpenJS.NodeJS --source winget --accept-source-agreements --accept-package-agreements)
```

The two lines printed for a human to paste carry it for the same reason the agreement flags do, and the upgrade rewrite keeps it because it only replaces the verb.

**The trade-off, stated rather than discovered later.**
A machine whose `winget` source has been removed or renamed - some managed images do that - now fails on the name instead of searching whatever else is configured.
Measured here, 2026-08-20, that failure is a good one:

```
PS> winget search -e --id OpenJS.NodeJS --source no-such-source --accept-source-agreements
exit = -1978335214
No sources match the given value: no-such-source
The configured sources are:
  msstore
  winget
  winget-font
```

It names the machine's actual configuration, it arrives through the same report as every other failure, and what it replaces is an install that stopped on a question with nobody there to answer it.
`-1978335214` is deliberately NOT added to `Get-FmToolExitCodeMeaning`, even though it was measured here and this change is what makes it reachable: winget already says what is wrong and lists the sources it does have, and a one-line gloss cannot improve on that.
The rule is that a meaning is added where the tool's own words are not enough, not wherever a code has been seen.

### 36.5 The reporting fix is what made this findable

This is the strongest argument for section 35's second half, and it is worth stating in full.

The run BEFORE that commit met this same failure and reported it like this:

```
[skipped] Node.js - FAILED: 'winget install OpenJS.NodeJS' exited 1:
          Node.js OpenJS.NodeJS winget
```

`exited 1` was the child shell's verdict, not winget's, so the one number that identifies this failure was thrown away.
The "cause" was the last line the tool happened to print, which was a row of winget's package table.
Firstmate read that, found no cause in it, and told the captain the install needed administrator - twice, wrongly, while they were already elevated.

The run AFTER it met the same failure and reported `-1978335138 (0x8A15005E)` with winget's own paragraph underneath, naming the source, the certificate, and the question it was asking.
Diagnosis took five minutes and needed no access to the captain's machine.

Same defect, same machine class, two reports.
One cost the captain two wrong diagnoses and their time twice; the other was solved from the log.
Nothing else in this port has demonstrated its own value that cleanly.

### 36.6 The pin must not become a gag - `PROVEN`

Naming the source removes one failure, and it must not cost the captain the report on any of the others.
`tests/FmToolInstall.Tests.ps1` runs the real reporting path over the real pinned command, failing for a reason the pin has nothing to do with, and requires the command, the code in both forms, and the tool's own words to survive:

```
'winget install -e --id OpenJS.NodeJS --source winget --accept-source-agreements --accept-package-agreements'
    exited -1978335138 (0x8A15005E), which means a source's server certificate did not match what winget expected.
what it printed, in full:
    Failed when searching source: winget
    An unexpected error occurred while executing the command:
    0x8a15005e : The server certificate did not match any of the expected values.
```

`-1978335138` also joins `Get-FmToolExitCodeMeaning`, and it is the only entry in it taken from the captain's log rather than from this seat.
It qualifies on the same rule as the others: it is winget's OWN sentence about itself, quoted, not a meaning invented for a number.
Note what it now means with the pin in - the source this repo DOES need is unreachable, which points at the machine rather than at the package, and is a different answer worth saying.

### 36.7 Coverage

```
tests/FmToolInstall.Tests.ps1
  'pins the one source these packages come from, so an unused one cannot fail the install'
  'reports a pinned-source install that failed anyway just as fully'
  'says what an exit code means only where this repo has measured one'   (extended)
```

The pin sweep walks `Get-FmToolCatalog` rather than a list of today's tools, on the install form AND the upgrade form, so a winget route added later without the pin fails in the suite rather than on the captain's next clean VM.

Negative control, RUN rather than asserted, by putting the defect back in `Get-FmBootstrapWingetCommand` and restoring it afterwards:

```
--source winget removed        Invoke-Pester ./tests/FmToolInstall.Tests.ps1
                               96 passed, 3 failed

  - pins the one source these packages come from, so an unused one cannot fail the install
  - gives the elevated PowerShell 7 route the same flags, because it is copied and pasted
  - hands the captain an upgrade command for the winget tools, not an install one
```

Those three are the install route, the human-pasted line and the update route, which is the whole surface the builder feeds.
`reports a pinned-source install that failed anyway just as fully` stays green through it, and that is correct: it holds a literal command rather than the builder's, because its subject is the report and not the flag.

### 36.8 The rest of the class

The question section 35.7 asked was "what else can stop and ask when nobody is there".
This section asks the sharper one: what else must be HEALTHY for us to succeed, that we never needed?
The repo was swept for it, and nothing else is in the same position.

- **`Install-Module` names no `-Repository`**, so it searches every registered repository, which is structurally the same shape. It is deliberately left alone. `-Repository PSGallery` would be one word, but the two cases are not alike: every winget id here is published on `winget` and none on the Store, whereas a captain on a corporate network may legitimately have an internal mirror registered INSTEAD of PSGallery, and pinning would break exactly that machine. It is also not measured - PSGallery is Trusted and healthy here, so there is nothing to reproduce. Recorded as considered and declined, not as overlooked.
- **The "latest published version" lookups were already correct**, and are the pattern this fix should be judged against. `Get-FmToolLatestVersion` and `Get-FmToolModuleLatestVersion` return `''` on any failure and `Get-FmToolClassification` reports `unknown-latest`, so a vendor release feed being down cannot fail a tool. A component we do not need in order to INSTALL already cannot stop us there.
- **The portable route, the vendor installers and `npm install -g`** each have exactly one source, and it is the source of the thing being installed. There is no unneeded component to drop.
- **`Get-FmToolWingetPath`** already resolves winget by PATH and then by its real location, so a `Get-Command` miss on a locked-down profile does not refuse a machine that has winget. Same class, already answered; section 33 owns that measurement.

### 36.9 What was NOT run

- **The certificate condition itself was not reproduced.** msstore is healthy on this machine, and breaking a machine's TLS trust or its clock to reproduce it would change global state to prove a link the fix removes either way. That one link rests on the captain's log and on winget's own printed explanation, not on a measurement from this seat. Everything else here - the source list, the `Explicit` column, the flag, and which source has which package - was measured on this machine.
- **No tool was installed, and no machine was changed.** Every winget call in this section was `--version`, `source list`, `--help`, or `search`. Nothing was installed, upgraded, removed, or re-sourced.
- **`install.ps1` has still never completed on a machine missing the tools.** This section removes another reason it could not; sections 33.5, 34.8 and 35.9 said the same about theirs, and it stays true until a clean VM finishes.
- **The pinned command has never run a real install on the captain's VM.** That VM is rebuilt for each attempt, and the fix was committed alone as `a8dcbe5` and landed on `main` while this section was still being written, precisely so the next rebuild would be its first real test. What is proven here is that the pinned form resolves every id from a source that answered; whether it carries a clean VM to the end is the captain's next run to report.

### 36.10 The suite and the analyzer, on this branch

Both passes run on the final tree, with the analyzer sweep taken inside the suite as `tests/FmAnalyzer.Tests.ps1`.

```
Invoke-Pester -Path ./tests    run A   2492 passed, 0 failed, 18 skipped   (56m)
Invoke-Pester -Path ./tests    run B   2492 passed, 0 failed, 18 skipped   (53m)
Invoke-ScriptAnalyzer, repo-wide, via tests/FmAnalyzer.Tests.ps1
                                       zero findings at every severity
```

2492 is section 35.10's 2490 plus the two tests this task adds.

**Run A is clean here, and as in 35.10 that is not an improvement.**
The instruction-surface failures a fresh worktree's first run produces had already been cleared before it started: `tests/FmToolInstall.Tests.ps1`, `tests/FmInstall.Tests.ps1` and `tests/FmAnalyzer.Tests.ps1` were run together earlier to gate the first commit, and that subset showed the familiar six - all `$doctor.Healthy` - which an immediate re-run of `tests/FmInstall.Tests.ps1` cleared at 83 passed, 0 failed.
So this is still "report the SECOND run"; the repair simply happened before run A rather than during it.

**The two runs bracket the negative control, and the tree was checked rather than assumed.**
36.7's control edits `Get-FmBootstrapWingetCommand`, so it ran between the two passes and the file was restored from a copy afterwards.
`git status` then reported only the two markdown files this commit changes, which is what proves the restored source is byte-identical to what run A tested and to what is committed.
Nothing else moved between the passes: no test in `tests/` reads anything under `docs/`, so both runs cover exactly the same code.

The eighteen skips are all pre-existing and none is new.

One earlier whole-suite run was started and DISCARDED rather than reported, because it was launched before the fix was finished and the tree changed under it.
A suite run against a tree that no longer exists proves nothing about the one that does.

## 37. The clean VM got most of the way, and the three things that stopped it - `PROVEN (Windows 11) FOR THE CAUSES AND THE FIXES; THE CLEAN-MACHINE RUN ITSELF IS STILL THE CAPTAIN'S`

The captain rebuilt a Windows 11 VM at 00:22 on 2026-08-21 and kept the log.
It is the third clean-machine attempt and by far the furthest one: Node.js, npm, all five axi tools, gh, treehouse, PSScriptAnalyzer, the home, the instruction links, the protection, the `firstmate` command and PowerShell 7 in Start all came out `[created]` on a machine that had none of them.

Three things did not, and the captain's instruction about them is the bar this section is written against:

> "add all things in script in don't want user have to execute any thing else manual or extra all must be done from our script itself"

So a printed instruction is a failure, not an acceptable outcome.
That reverses what sections 31 and 35 recorded as correct behaviour for one class of requirement, and the reversal is deliberate: the older rule was "never install over a version the captain did not agree to replace", and the answer is not to abandon it but to notice that two of these three were never replacements at all.

**That log tests nothing about the source pin.**
It was taken from a clone made before `a8dcbe5` landed, and its Node.js line carries no `--source winget`.
Section 36 stands unchanged and untested by this run.

### 37.1 Pester: the machine had it, we refused it, and the line we printed was wrong twice over

Measured, from the log:

```
[skipped] module Pester - UNSUPPORTED: 3.4.0 is installed; this repo requires at least
          5.0.0 ... Update it yourself, then re-run:
          Install-Module Pester -Scope CurrentUser -Force
```

and then, because the suite could not run without it:

```
[missing] test suite - the suite process produced no result file (exit code 1)
NOT READY: 1 requirement(s) are installed at a version this repo cannot work with
```

Windows ships Pester 3.4.0 in `C:\Program Files\WindowsPowerShell\Modules` on every machine, so this is not an edge case - it is what a clean machine IS, and it ended every clean install with a chore.

**Is the printed line even runnable? MEASURED here rather than assumed**, because the addendum asked for exactly that and it is a claim about a machine neither seat is on:

| what was measured | result |
| --- | --- |
| `Get-AuthenticodeSignature` on Windows' `Pester\3.4.0\Pester.psd1` | `Valid`, `CN=Microsoft Windows, O=Microsoft Corporation` |
| `Get-AuthenticodeSignature` on the gallery's Pester (via `Save-Module` to a temp directory) | `Valid`, `CN=Jakub Jares, O=Jakub Jares, L=Praha, C=CZ` |
| `PublishersMismatch` in PowerShellGet's own resource table | "A Microsoft-signed module ... conflicts with the new module ... from publisher ... If you still want to install or update, use -SkipPublisherCheck parameter." |
| `$script:WhitelistedModules` in PowerShellGet **2.2.5** (what PowerShell 7 carries) | `@{ "Pester" = $true; "PSReadline" = $true }` - the mismatch is downgraded to a warning and the install proceeds |
| the same table in PowerShellGet **1.0.0.1** (what Windows PowerShell 5.1 ships) | absent - `WhitelistedModules` occurs 0 times, `PublishersMismatch` twice |

So the honest answer is narrower than "it fails" and narrower than "it works": **it depends on which window the captain pastes it into, and the log shows them sitting in Windows PowerShell 5.1 - the one where it throws.**
A printed fix is a line someone pastes into whatever shell they have open, so `-SkipPublisherCheck` is what makes it true in both.
`Get-FmToolModuleInstallCommand` is now the only place that builds it, which also settles the two callers that disagreed about `-Force`.

**But the line is no longer the point.**
`superseded` is a new classification beside `unsupported`, and the two differ on one question: does putting what this repo needs on the machine REMOVE what is already there?

- For a tool it does, so that one is still told and skipped and still ends the run NOT READY.
- For a PowerShell module it does not. `Install-Module -Scope CurrentUser` writes a new version directory into the user's own module tree and PowerShell loads modules by version.

**Side-by-side is not a hope here; it is what this machine is doing.**
This seat has Windows' `Pester\3.4.0` in `C:\Program Files\WindowsPowerShell\Modules` and a `Pester\6.1.0` in a separate tree, `Get-Module -ListAvailable` lists both, and every suite run in this document ran on the 6.1.0 one.
`Get-FmMachineInstallPlan` is the only caller that sets `-Supersedable`, and it sets it for every module and for no tool.

**And the same fact stopped arriving twice.**
Before any of that, the run dumped a raw `Import-Module Pester -MinimumVersion 5.0.0` failure with a source-line caret into the middle of the log - the same version problem the plan had already reported cleanly two lines earlier, arriving again as an unhandled error.
Three things now prevent it: `Get-FmMachineSuitePrerequisite` decides on the VERSION rather than the name before a process is started, the runner writes a refusal into its own result file instead of throwing, and the child's error stream is redirected to a file and folded into this function's verdict rather than printed onto the console the report is being composed on.

### 37.2 A tool this run installed, reported missing by this run

Measured, in the same log, eight lines apart:

```
[created] Claude CLI - irm https://claude.ai/install.ps1 | iex
...
[missing] tool Claude CLI - not on PATH - firstmate itself
            fix: irm https://claude.ai/install.ps1 | iex
```

Both lines are true.
The vendor's installer wrote `claude.exe` into the user's own profile, this already-running process could not see it, and the run then advised the captain to repeat an install that had already worked - and called a working machine broken.

Reloading PATH from the persisted environment was already happening after every install and is not always enough: an installer that reports where it put the tool, rather than persisting a PATH entry, leaves nothing to reload.
So `Resolve-FmToolAfterInstall` asks the last question that is left - is it actually there? - and looks in the directory that vendor's own installer uses.

**MEASURED on a machine that has them, 2026-08-21:**

| tool | where its own installer left it |
| --- | --- |
| Claude CLI | `%USERPROFILE%\.local\bin\claude.exe` |
| herdr | `%LOCALAPPDATA%\Programs\Herdr\bin\herdr.exe` - **not** the `.herdr\packages\standalone\releases\.staging...` path its failure message names |
| treehouse | `%LOCALAPPDATA%\treehouse` (from the captain's own log) |

A tool with no entry, or an entry that is not on this machine, changes nothing and the recovery reports that it found nothing.
The step line says when a tool was reached that way, so a vendor installer that stops persisting PATH is visible rather than silently patched over.

### 37.3 herdr: read their installer, take the same release, prove it runs

herdr's own installer has now failed its own verification on two clean VMs:

```
==> Downloading Herdr
Downloaded Herdr command failed verification:
C:\Users\...\.herdr\packages\standalone\releases\.staging.0.8.2-...\herdr.exe --version
```

Nothing here fixes someone else's script and nothing here tries to.
What this does instead is what the captain asked for: read that installer rather than run it, take the two facts out of it, and install the same release the way `gh` already is.

**Read from `https://herdr.dev/install.ps1` on 2026-08-21:**

| what their installer does | where |
| --- | --- |
| stable channel is `https://herdr.dev/latest.json`, preview is `preview.json` beside it | the `$ManifestUrl` default |
| a Windows machine is the triple `x86_64-pc-windows-msvc`, asset key `windows-x86_64` | `$targetTriple` |
| an asset is a bare URL string OR an object carrying `url`/`sha256`/`format` | their `Get-ManifestAsset` accepts both |
| the version identity is `version` on stable, `"<base_version>-preview.<build_id>"` on preview | their `Resolve-HerdrVersion` |

**Measured against the real manifests and the real release, from this seat:**

```
https://herdr.dev/latest.json    version 0.8.2
                                 windows-x86_64 -> github.com/herdrdev/herdr/releases/
                                 download/v0.8.2/herdr-windows-x86_64.zip   (bare string, no sha256)
https://herdr.dev/preview.json   base_version 0.8.2 + build_id 2026-08-19-b5c4a0176e91
                                 windows-x86_64 -> { url; sha256 01c8bc9f...c6e25e; format zip }
zip layout                       herdr.exe at the root, beside conpty/ and THIRD-PARTY-NOTICES/
                                 7 entries; no versioned root directory to strip
```

and then, the thing that actually decides it - **the expanded binary was run**:

```
Install-FmToolPortable -Portable (Get-FmBootstrapPortableRelease -Tool herdr)
    -InstallRoot <scratch> -PathScope Process
  action : installed
  exe    : True
  proof  : herdr 0.8.2   exit=0
```

**CORRECTED BY SECTION 39, AND THE CORRECTION IS THE POINT.**
This section originally read "The binary was never the problem - their staging step was", on the strength of the binary running here.
That was wrong.
The binary runs HERE because this machine has something the captain's clean VM does not, their staging step was reporting a real fault on that machine, and the same release installed by this repo's own route failed the captain's VM in exactly the same way.
Section 39 has the cause, the reproduction and the evidence against the alternatives; read it before trusting anything else in this subsection about WHY their installer failed.
What stands here is what was measured here: their manifest contract, the release layout, and that this seat's expanded `herdr.exe` answers `--version`.
`Get-FmToolLatestVersion -Tool 'herdr'` reads the same manifest, so "is it current" and "what would be installed" cannot disagree - and it replaces a GitHub prerelease scan whose newest tag is a date stamp that nothing can rank against the `herdr 0.8.2` the tool itself prints.
Where a channel publishes a checksum the download is verified against it; the stable channel publishes none, and an absent checksum is never treated as a passing one.

### 37.4 What was NOT proven here, and needs the captain's VM

- **No clean machine has run any of this.** Every measurement above was taken on a machine that already has the tools. What is proven is the mechanism, the classification, the manifest contract and that the herdr binary runs; what is not proven is a full `install.ps1` from a fresh clone.
- **Pester 5 was never installed on this machine to watch it succeed.** Doing so would have written into the captain's own module tree to answer a question that source-reading and two signature checks already answer. The side-by-side claim rests on this machine ALREADY being in that state, and on PowerShellGet's own whitelist table - not on a fresh install observed here.
- **The `-SkipPublisherCheck` refusal was not reproduced.** Reproducing it means installing Pester 5 over Windows' copy from Windows PowerShell 5.1 and watching it throw. What is measured is both signers, PowerShellGet's own message text, and the presence and absence of the whitelist in the two versions - which is why the conclusion is stated as "depends which shell" rather than as a flat failure.
- **The Claude CLI recovery was exercised against a stand-in, not against the Claude installer.** `Resolve-FmToolAfterInstall` was run for real against a disposable directory holding a dummy command, with `-PathScope Process`. Whether `%USERPROFILE%\.local\bin` is where that installer puts it on a CLEAN machine rests on it being where it is on this one.
- **herdr was installed to a scratch directory, not to `%LOCALAPPDATA%\Programs`.** The download, the manifest read, the expansion, the layout check, the PATH edit and `herdr --version` all ran; what did not run is the same route landing on a machine that has no herdr at all.
- **The whole-run report has not been seen end to end.** The lines this section changes were exercised through their own functions and through the suite, not by watching an install print them.

## 38. Closing the last three of the five: elevation, the execution policy, and where the clone is - `PROVEN (Windows 11) FOR EACH MECHANISM; NO CLEAN MACHINE HAS RUN THE WHOLE COMMAND`

Section 37 did the three things the captain's 00:22 clean-VM log exposed.
This does the rest of the original five, and its subject is the gap between "the installer works" and "ONE command takes a clean machine all the way".

### 38.1 Node.js was the last required tool behind administrator, and five more depended on it

The captain's log shows the winget route SUCCEEDING - `[created] Node.js`, then all five axi tools `[created]` after it.
That run was elevated: its prompt starts at `C:\WINDOWS\system32` and Node landed in `C:\Program Files\nodejs`.

That is the whole problem.
`Test-FmBootstrapInstallNeedsAdministrator` correctly declares the winget routes as needing elevation, and `Invoke-FmToolRoute` correctly names and skips them on an unelevated run - so on a clean machine where the captain simply opens PowerShell, Node.js is skipped, npm never appears, and all five axi tools come back BLOCKED with "install Node.js first and re-run this installer".
A sixth manual step and a second run, reached by doing nothing wrong.

nodejs.org publishes the same build as a plain zip, so the per-user pattern this repo already uses for gh removes both.

**MEASURED, 2026-08-21, against the real release:**

```
https://nodejs.org/dist/index.json     newest LTS  v24.19.0 (Krypton), files include win-x64-zip
HEAD .../v24.19.0/node-v24.19.0-win-x64.zip        200, 35.6 MB
zip layout      2454 entries under ONE root, node-v24.19.0-win-x64
                at its top level: node.exe, npm, npm.cmd, npm.ps1, npx, npx.cmd,
                corepack, LICENSE, README.md - and NO node_modules/npm/npmrc
```

so `StripRoot` is true, `BinSubdirectory` is empty, and the expansion itself is what goes on PATH.

**And then the whole route was run:**

```
Install-FmToolPortable -Portable (Get-FmBootstrapPortableRelease -Tool node)
    -InstallRoot <scratch> -PathScope Process
  action      : installed
  node -v     : v24.19.0
  npm -v      : 11.11.0
  npm root -g : C:\Users\ADMIN\AppData\Roaming\npm\node_modules
```

**The npmrc is not decoration, and this is the measurement that settles it.**
The same zip, expanded bare with nothing written into it:

```
npm root -g : <expansion>\node-v24.19.0-win-x64\node_modules
```

That is INSIDE the directory this route replaces wholesale on the next Node.js update - so updating Node would silently delete the five axi tools installed into it.
With `node_modules\npm\npmrc` holding `prefix=${APPDATA}\npm`, the same command answers `C:\Users\ADMIN\AppData\Roaming\npm\node_modules`.
npm expands `${APPDATA}` itself; this is what the official MSI writes, not an invention here.
It is also exactly where the captain's own clean VM already has them - their log reads `C:\Users\higet\AppData\Roaming\npm\gh-axi.cmd` - so the zip route and the MSI route put globals in the same place.

**What is left behind administrator, swept rather than asserted:**

```
foreach ($entry in Get-FmToolCatalog) { (Get-FmToolRoute -Tool $entry.Tool).NeedsAdministrator }
  -> git, and nothing else
```

git's route is winget and does need elevation - and a machine that has this checkout already has git, because the documented first command is `git clone`.
So no requirement a clean machine can actually reach demands administrator, and the one that would is named rather than silent.
`tests/FmToolInstall.Tests.ps1` pins that list to exactly `@('git')`, so a future winget route added to a required tool fails there.

### 38.2 The execution policy, on the path the one command actually takes

The README's first command carries `-ExecutionPolicy Bypass`, and section 33 established why.
The question this closes is the brief's: does the one-command path REINTRODUCE the refusal further in?

Two places start a child PowerShell, and one of them runs a FILE - which is the only thing Windows' default policy refuses:

- `Invoke-FmToolShellCommand`, which runs each vendor one-liner
- `Invoke-FmMachineSuite`, which runs a generated `.ps1` through `Start-Process`

**The first hop was already proven, and it is proven on every suite run.**
`tests/FmModuleAssembly.Tests.ps1` reads the command out of README's first code block and RUNS it in Windows PowerShell 5.1 with `-ExecutionPolicy Restricted` - which is what a clean Windows client has - alongside a negative control that runs the bare form.
Both ran here rather than skipping (38 passed, 0 skipped), and re-run by hand:

```
README command, powershell.exe 5.1, -ExecutionPolicy Restricted
    exit 0, reaches "what this machine has:" and
    "-DetectOnly: nothing was installed and nothing was left changed."
the bare .\install.ps1, same shell
    "...because running scripts is disabled on this system."
```

**The SECOND hop was not, and it was genuinely broken.**
`-ExecutionPolicy Bypass` is inherited by child processes through the `PSExecutionPolicyPreference` environment variable, so the documented path carried it down - but that only happens when the parent got the switch, and a run started from a window that is ALREADY PowerShell 7 never passes through the relaunch that supplies it.
`Invoke-FmMachineSuite` runs a generated `.ps1` FILE, and a file is the one thing the default policy refuses.

MEASURED, 2026-08-21, with `$env:PSExecutionPolicyPreference` set to `Restricted` so every child sees a clean machine's policy:

```
child running a .ps1 FILE, launched as the suite runner used to be
    SecurityError: File ...\fm-restricted-<guid>.ps1 cannot be loaded because
    running scripts is disabled on this system.
the same child, launched as it is now (-ExecutionPolicy Bypass -File)
    the child ran
Invoke-FmMachineSuite against a throwaway repo, same inherited policy
    Ran: True     1 passed, 1 failed, 0 skipped     Failed: demo.fails on purpose
```

So on a machine at the Windows default, the step that PROVES the install was the one thing that would have been declined - silently reported as "the suite process produced no result file".
Both child launches now state the switch themselves, and the first block above is the negative control showing the refusal is real rather than hypothetical.

### 38.3 A clone in a place the machine guards

`Get-FmMachineLocationCheck` answers before anything is attempted, and the plan prints it first.
It tells three refusals apart from one warning, because the remedy differs:

| what | verdict | why |
| --- | --- | --- |
| a network share (`\\host\share\...`) | refused | the one-word command written into `%LOCALAPPDATA%\Programs\firstmate` points straight at this `start.ps1`, so it works only while the share is mounted |
| a drive that is not there | refused | same, and it stops working the moment the drive is detached |
| a OneDrive folder | refused | OneDrive replaces files with placeholders and carries neither a junction nor a symlink, and this repo commits two links that every install repairs and then VERIFIES |
| Documents, Desktop and the other known folders | warned | Controlled folder access protects them WHEN IT IS ON, and it is off by default - so this works on most machines and is refused on some |
| a write this machine refuses | refused | proved by doing it, which is the only proof there is |

**MEASURED here, 2026-08-21:**

```
this checkout                              usable, "accepted a write into it"          [ok]
C:\Users\ADMIN\Documents                   usable, with the Controlled-folder note     [warn]
\\somehost\share\firstmate                 refused, "on a network share"               [missing]
Z:\firstmate-win  (no such drive)          refused, "a drive letter with nothing
                                           mounted on it"                              [missing]
C:\Users\ADMIN\OneDrive\firstmate-win      refused, naming the two committed links     [missing]
```

Two things that had to be got right and were checked rather than assumed:

- **The probe cleans up after itself.** It creates a directory and a file, then removes both in a `finally`. A probe left behind would appear in the captain's own `git status`.
- **A prefix is not a parent.** `Documents2` is not inside `Documents`; `Test-FmMachinePathUnder` compares normalized full paths with a trailing separator, and a test pins it.

**A DEFECT THIS SECTION FOUND IN ITSELF, and it is the reason to run the thing rather than only its tests.**
`Install-FmMachine -Approved -WhatIf` reported THIS checkout as one the machine had refused a write into.
`New-Item` honours the WhatIf preference and created nothing; the raw `[System.IO.File]::WriteAllText` beneath it honours nothing and failed on the directory that was never made; and the probe read that as a refusal.
A WhatIf run still has to DETECT, and this probe changes nothing to report on because it removes what it makes - so both halves now pass `-WhatIf:$false`, and a removal WhatIf skipped can no longer leave a probe in the captain's own checkout either.
Pinned by a test, and the test was checked against a reverted guard: with the flag removed exactly that one test fails, and with it restored the file is 139 passed, 0 failed.

The location is a REQUIRED check, so an unusable one makes the run end NOT READY rather than on a cheerful note - and it is named at the TOP of the plan as well, before several minutes of installing.
The run still does everything else it can: tools install into `%LOCALAPPDATA%` regardless of where the checkout is, so the captain gets a full report rather than an early exit.

**Not proven:** no OneDrive folder, network share or Controlled-folder-access-protected directory was actually installed into. The classification is proven; the consequence it predicts is not, and cannot be from a machine where Controlled folder access is off.

### 38.4 The digest stopped naming a command that does not work

`Get-FmBootstrapMissingDiagnostic` printed `MISSING: herdr (install: irm https://herdr.dev/install.ps1 | iex)` - the installer measured failing its own verification on two clean VMs.
Any tool this repo installs from a release archive now names `install.ps1` instead, which is the thing that actually does it.
The `MISSING: <tool> (install: <cmd>)` shape the diagnostics skill matches on is unchanged.

### 38.5 What was NOT proven here, and still needs the captain's VM

- **No clean machine has run the one command end to end.** That remains true after this section, as it was after 33, 34, 35, 36 and 37. Every mechanism below it is proven; the whole is not.
- **Node.js was installed to a scratch directory, not to `%LOCALAPPDATA%\Programs`, and not on a machine without Node.** The download URL was proved by a `HEAD` and the install by expanding the real 35.6 MB zip, but the route has never run on a machine that needed it.
- **No axi tool was installed through the zip's npm.** `npm root -g` proves WHERE a global install would land, both with and without the npmrc. That one of the five then resolves on PATH afterwards is inference from that location, not a measurement.
- **The unelevated skip was not watched.** This seat cannot easily run the installer unelevated against a machine missing Node. What is measured is the route table: `NeedsAdministrator` is now false for Node.js and true only for git.
- **A machine whose LocalMachine policy is `Restricted` was not used.** The refusal was reproduced by giving children the clean-machine policy through `PSExecutionPolicyPreference`, and by running the README command under `-ExecutionPolicy Restricted` in Windows PowerShell 5.1. That is the same mechanism, not the same machine.
- **No guarded location was installed into.** See 38.3.
- **The Windows-on-ARM Node.js zip was not fetched.** The route picks `arm64` from `PROCESSOR_ARCHITECTURE`, and only the x64 asset was downloaded and run here.

## 39. The install hung forever on a question nobody could see - `PROVEN (Windows 11)`

Dated 2026-08-21, on `C:\Users\ADMIN\.treehouse\firstmate-win-e0ed2e\2\firstmate-win`,
PowerShell 7.6.4, Pester 6.1.0, Windows 11 Pro 10.0.26200, branched from `main` at `feb2c2d`.
The two fixes were committed alone as `2f4d97e`, landed on `main` and pushed while the captain was still blocked on a fresh VM; this section is the second commit.

Section 38 closed the last of the five things that stopped a clean machine.
The captain then ran the installer on a fresh VM and it got all the way to its final step, the one that PROVES the install.
It never came back.

### 39.1 What the captain met

After `Installing what is missing, and proving the result`, their screen, verbatim:

```
What if: Performing the operation "create AGENTS.md and link CLAUDE.md to it" on target "...\Temp\Pester_zdxw\..."
What if: Performing the operation "materialize the CLAUDE.md link git left as text" on target "..."
What if: Performing the operation "type 'claude' and submit it after 1s unless touched" on target "default:w1:p2"
What if: Performing the operation "run: npm install -g tasks-axi" on target "tasks-axi"

cmdlet Step-FmSpeechCaptureState at command pipeline position 1
Supply values for the following parameters:
State:
```

And there it sat.
No test name, no file, nothing on screen to say what wanted an answer or what typing one would do.
The install was not slow and it was not crashed: it was waiting, and it would have waited forever.

### 39.2 The chain, measured

The report that opened this task proposed a chain in which a leaked `$WhatIfPreference` suppressed whatever builds the speech-capture state, and a `$null` state then reached a mandatory parameter.
Two of its links do not survive measurement.
The load-bearing ones are the last two, and the first three are not what they looked like.

1. `tests/FmBridge.Tests.ps1`, `requires a state rather than inventing one`, is `{ Step-FmSpeechCaptureState -Step 'Start' } | Should -Throw`.
   The mandatory `-State` is left off ON PURPOSE, because leaving it off is how that test proves the refusal.
   Nothing produced a `$null` state; no state was ever passed.
2. `Step-FmSpeechCaptureState` declares `-State` as `[Parameter(Mandatory)]`.
   Given no value at all, PowerShell decides what to do from the HOST: a host that can prompt binds the parameter by ASKING, and a host that cannot raises `MissingMandatoryParameter`.
3. `Invoke-FmMachineSuite` starts the suite child with `Start-Process -NoNewWindow`, which hands that child the captain's own console, and did not pass `-NonInteractive`.
   So the child was a host that could prompt, and it asked - on the console the install was composing its report on.

Measured here, running that same call in a child with a real console, once with the switch and once without:

```
interactive     : STILL RUNNING after 30s - HUNG, killed
noninteractive  : EXITED, code 0
```

The non-interactive child's own log:

```
interactive-host=False
THREW: MissingMandatoryParameter,Step-FmSpeechCaptureState
DONE
```

That is the whole defect.
The test is correct, `Step-FmSpeechCaptureState` is correct, and the mandatory parameter is correct.
What was wrong is that the installer gave a child the power to ask a question.

### 39.3 The four `What if:` lines were not a leak

They are ordinary output from four tests that pass `-WhatIf` on purpose, printed in the order Pester runs the files:

| line | the test that printed it |
| --- | --- |
| `create AGENTS.md and link CLAUDE.md to it` | `tests/FmAgentsMemory.Tests.ps1`, `creates nothing under -WhatIf` |
| `materialize the CLAUDE.md link git left as text` | `tests/FmAgentsMemory.Tests.ps1`, `writes nothing under -WhatIf` |
| `type 'claude' and submit it after 1s unless touched` | `tests/FmAutolaunch.Tests.ps1`, `types nothing under -WhatIf` |
| `run: npm install -g tasks-axi` | `tests/FmBootstrap.Tests.ps1`, `runs nothing under -WhatIf even when approved` |

Reproduced here: a run stopped before it ever reaches `tests/FmToolInstall.Tests.ps1` prints all four, in that order.
`FmToolInstall` sorts after `FmBridge`, so nothing in it can have suppressed anything the bridge tests did.
The Herdr pane line is `FmAutolaunch`'s own test proving that `-WhatIf` types nothing into a pane, which is exactly what it should print.

They reached the captain's console for a different reason worth writing down.
The runner sets `Output.Verbosity = 'None'`, which silences Pester's own output but not a host's `What if:` messages, and `-NoNewWindow` makes the child's console the captain's.
So the only thing the captain could see of a 50-file suite was the handful of lines Pester does not control.

### 39.4 The bare preference assignment was a trap, not the cause

`tests/FmToolInstall.Tests.ps1` set `$WhatIfPreference = $true` bare inside an `It`, to prove that the location probe still detects under `-WhatIf`.
The reason that test exists is right, and section 38.3 records it.
The assignment was still wrong, and measuring it says exactly how wrong.

Measured, Pester 6.1.0, with a `SupportsShouldProcess` probe called from each position:

| where `$WhatIfPreference = $true` is written | rest of that `It` | the next `It` | a later `Describe`, same file | a later FILE |
| --- | --- | --- | --- | --- |
| bare, inside an `It` | suppressed | not suppressed | not suppressed | not suppressed |
| in the file's top-level `BeforeAll` | suppressed | suppressed | SUPPRESSED | not suppressed |
| `& { $WhatIfPreference = $true; <call> }` | that one call only | not suppressed | not suppressed | not suppressed |

So the bare form was not leaking, and could not have caused 39.2.
It was one refactor away from silence: the same line moved up into a `BeforeAll` suppresses every cmdlet in the whole file, and a test whose write is quietly skipped still passes.
It is now scoped to the one call that needs it, with an assertion under it that fails if the preference outlives that call.

Swept for the same shape across all 50 test files: that was the only assignment to a silencing preference in the suite.
The roughly 25 `$ErrorActionPreference = 'Stop'` lines are file setup rather than silencers - they make errors terminating, which surfaces failures instead of hiding them - and are deliberately left alone.
A test in `tests/FmModuleAssembly.Tests.ps1` now parses every `*.Tests.ps1` and fails on a silencing preference written anywhere a later test can inherit it.

### 39.5 What each fix buys

**`-NonInteractive` on the suite child** is the one that matters.
It does not fix this prompt; it fixes the CLASS.
Any prompt this suite can reach - a mandatory parameter, a `Read-Host` someone adds later, a confirmation - now fails instantly and arrives as one named test failure in the report the captain is already reading, instead of stopping the install with nothing on screen.

The same switch was then given to every other place in this repo that starts a PowerShell child to run a real entry point.
It matters because `-NonInteractive` is NOT inherited: a grandchild started from inside the suite decides its own interactivity from its own command line, so the four remaining entry-point helpers were each a second route to the same hang.
Three helpers already passed it, so this closed an inconsistency rather than introducing a rule.

`install.ps1` itself is deliberately NOT given the switch.
It is the captain's front door and legitimately asks two questions with `Read-Host`.
The rule this section establishes is narrower than "an installer never prompts": an installer may ask a question IT composed and printed, and must never let a child it started for verification ask one.

**Scoping the preference** buys nothing today and removes a trap for tomorrow, which is the honest description of it.

`Step-FmSpeechCaptureState` was left alone.
The prompt came from the parameter being OMITTED, not from being handed `$null`, so a null guard would not have prevented any of this - it would have turned one refusal into a different refusal on a path nobody took.

### 39.6 Both guards were checked against the code they guard

A guard test that has never been seen to fail is not yet a guard.
Each was run once with the thing it protects removed, and once with it back.

| guard | with the fix reverted | restored |
| --- | --- | --- |
| `tests/FmToolInstall.Tests.ps1`, `starts that child as a host that cannot ask the captain anything` | fails, naming the child's own failing test: `the host this suite was given.cannot prompt` | passes |
| `tests/FmToolInstall.Tests.ps1`, the escape assertion under `still detects under -WhatIf` | fails: `Expected $false, because the preference must not outlive the one call that needed it, but got $true` | passes |
| `tests/FmModuleAssembly.Tests.ps1`, `sets a silencing preference only in a scope that ends at the call needing it` | fails, naming file and line: `FmToolInstall.Tests.ps1:1943 sets $WhatIfPreference where the tests after it inherit it` | passes |

The first of those is worth one more note.
With the switch removed, the fixture's SECOND test - the one that binds a mandatory parameter - still passed, because the parent running it here has a redirected stdin and so the grandchild had no console to ask on.
Only the first assertion, which reads the child's own command line, fails in every environment.
That is why the launch is checked directly and not left to be inferred from the consequence.

### 39.7 One stale test found on the way, and fixed

`tests/FmBootstrap.Tests.ps1` still asserted `MISSING: herdr (install: irm https://herdr.dev/install.ps1 | iex)`.
Section 38.4 moved every release-archive tool onto `install.ps1`, and `Get-FmBootstrapMissingDiagnostic` has answered with that ever since.

Proven pre-existing rather than assumed, because "it was already broken" is exactly the claim that should not be taken on trust.
`git archive feb2c2d` was extracted to a scratch directory holding none of this branch's work, and that one test run there:

```
MAIN feb2c2d: PASSED=0 FAILED=1
  Expected: 'MISSING: herdr (install: irm https://herdr.dev/install.ps1 | iex)'
  But was:  'MISSING: herdr (install: powershell -ExecutionPolicy Bypass -File .\install.ps1)'
```

`git log -S` places the two sides exactly: the `install.ps1` answer arrived in `feb2c2d`, and the assertion was last written in `835bc53` on 2026-08-18 and never revisited.
So `main` landed red one commit before this branch existed, and the suite has been one test short of green since.
The assertion now matches the landed route, and still holds the part that was the point: `MISSING` with a command the captain can paste, never `MISSING_MANUAL` with a web page.

### 39.8 Not proven

- **The captain's own VM was not used.** The hang was reproduced here by giving a child a real console, which is the same mechanism, not the same machine. No clean-machine install has been run end to end from this seat; that remains true after this section as it was after 33 through 38.
- **The captain's screen shows four `What if:` lines where a full run here prints five.** `tests/FmBacklog.Tests.ps1` prints a `move to ...backlog.md` line between the third and fourth. Their transcript was trimmed, or that test did not run for them; nothing here needed to tell the two apart.
- **Only one prompting shape was measured.** A missing mandatory parameter was measured hanging without the switch and failing with it. That `Read-Host`, `Get-Credential` and `PromptForChoice` fail the same way under `-NonInteractive` is PowerShell's documented behavior, taken rather than measured.
- **The four entry-point helpers were never observed hanging.** They are a route to the same defect by the same mechanism, closed by inspection. None of them reaches a prompt today, so there was nothing to reproduce.
- **39.7 fixed a stale assertion, not a route.** That `powershell -ExecutionPolicy Bypass -File .\install.ps1` actually installs herdr on a clean machine is section 38.4's claim and is untouched here; herdr's own install verification was explicitly out of this task's scope. What is proven is which of the two strings `Get-FmBootstrapMissingDiagnostic` returns.
## 40. herdr installs correctly and will not run, and the vendor's verification was right all along - `PROVEN (Windows 11) FOR THE FAILURE SHAPE, THE REPRODUCTION AND THE REPORTING FIX; THE CAUSE ON THE CAPTAIN'S VM IS UNCONFIRMED AND THE DIAGNOSTIC BELOW IS WHAT CONFIRMS IT`

The captain's clean Windows 11 VM, with this repo's own direct install in place:

```
[missing] tool herdr - 'herdr' resolves to
          C:\Users\higet\AppData\Local\Programs\herdr\herdr.exe but answers
          nothing to --version, so it is not verified as the real tool

summary: herdr  installed  C:\Users\higet\AppData\Local\Programs\herdr
```

The download worked, the placement worked, and the program produces nothing when run.
This section is what that means, what it does not mean, and which part of it this seat could not settle.

### 40.1 The correction: "the binary was never the problem" was wrong

Section 37.3 concluded, on 2026-08-21, that herdr's own installer had a broken verification step, because the same release ran here and printed `herdr 0.8.2`.
It said so in this document and in `Get-FmBootstrapPortableRelease`'s comment, and both have been corrected in place rather than left standing.

The evidence that overturns it is the captain's own log above.
This repo's route does not use their staging directory, does not use their script, and placed the file where it belongs - and the binary still answers nothing.
So the thing their installer refused to certify was a binary that genuinely does not run on that machine, and their check was reporting a real fault.

**This matters beyond one comment.** The wrong conclusion was drawn from a single machine's success and generalised to every machine, and it is exactly the kind of inference this document exists to stop: `herdr --version` answering here is a fact about THIS SEAT, not about the release.

### 40.2 The report shape rules out everything that blocks a LAUNCH

`Get-FmToolClassification` has two separate classes for a tool that prints no version, and which one the captain got is evidence.

- `unusable` means Windows would not START it - `Invoke-FmSessionCommandLine` caught an exception and reported `Launched = $false`.
- `unknown-version` means it STARTED and printed nothing readable.

The captain's line is the `unknown-version` wording, so the process was created.

**MEASURED here, 2026-08-21, through the real detection rather than by reading the source:**

| what was put on PATH as `herdr` | `Launchable` | classification |
| --- | --- | --- |
| a file that is not a program at all | `False` | `unusable` |
| an ARM64 `OpenConsole.exe` on this x64 machine | `False` | `unusable` |
| the real herdr 0.8.2 with one imported DLL name rewritten | `True` | `unknown-version` |
| the real herdr 0.8.2, untouched | `True` | `current` |

Everything that stops a process being CREATED - a wrong-architecture image, a corrupt file, and by the same mechanism Smart App Control, WDAC, AppLocker or antivirus refusing the launch - lands in `unusable`.
The captain's machine did not report `unusable`.
It reported the class that means **the process started and died before it said anything**.

### 40.3 The one thing herdr needs that Windows does not ship

The real release was downloaded from the manifest their own installer reads, and its import table was read directly:

```
https://herdr.dev/latest.json  ->  version 0.8.2
                                   github.com/herdrdev/herdr/releases/download/
                                   v0.8.2/herdr-windows-x86_64.zip   (8,382,621 bytes)

herdr.exe   x64, 22,400,512 bytes, Authenticode NotSigned
imports     ADVAPI32 bcryptprimitives combase imm32 KERNEL32 ntdll ole32
            oleaut32 propsys shell32 USER32 ws2_32
            api-ms-win-core-synch-l1-2-0, api-ms-win-crt-{environment,heap,
            locale,math,runtime,stdio,string,time}
            VCRUNTIME140.dll
```

Every name on that list is part of Windows **except one**.
The `api-ms-win-*` entries are OS API sets, and the `bcryptprimitives`/`combase`/`propsys` family are inbox system DLLs.
`VCRUNTIME140.dll` is not: it comes from the Microsoft Visual C++ 2015-2022 Redistributable, which is a separate download and is not part of a Windows installation.

**Why it works on this seat, stated as a fact about this seat:**

```
C:\WINDOWS\System32\VCRUNTIME140.dll      v14.42.34438.0
uninstall entry  Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.42.34438
                 installed 2025-05-12
```

That is the difference between the two machines: something installed the redistributable here on 2025-05-12, and a clean Windows 11 VM has had nothing put it there.
A fresh VM is precisely the machine least likely to have it, because it arrives as a dependency of software nobody has installed yet.

### 40.4 The reproduction, on the real binary

A copy of the real 0.8.2 `herdr.exe` had the sixteen bytes `VCRUNTIME140.dll` in its import directory rewritten to `VCRUNTIMEZZZ.dll` - the same length, so nothing else in the image moves.
That is a machine without the runtime, simulated from the other side, using the actual release rather than a stand-in.

```
& herdr.exe --version
  output lines : 0
  LASTEXITCODE : -1073741515  (0xC0000135)

Start-Process, streams captured to files
  exit code    : -1073741515  (0xC0000135)
  stdout bytes : 0
  stderr bytes : 0
```

No exception, no dialog, no text on either stream, and `0xC0000135` is `STATUS_DLL_NOT_FOUND`.
Through the real detection:

```
Get-FmToolStatus -Command 'herdr'
  Present    : True
  Version    : ''
  Launchable : True
  ExitCode   : -1073741515
  -> classification: unknown-version
```

That is the captain's log, reproduced: the same class, the same empty version, the same sentence.

### 40.5 The alternatives, and what is against each

None of these was assumed away; each has evidence.

| possibility | evidence against it |
| --- | --- |
| a fresh machine's defences refusing an unsigned downloaded binary | Any refusal to START lands in `unusable`, measured twice in 40.2. The captain got `unknown-version`. Smart App Control also cannot be the whole story on a machine that reported the tool as started. |
| the mark a browser or download API puts on a file from the internet | Our route does not create one. `Invoke-WebRequest -OutFile` then `Expand-Archive` leaves `:$DATA` and nothing else on both the zip and the expanded `herdr.exe` - measured. And a `Zone.Identifier` added deliberately to a working copy here did not stop it: it printed `herdr 0.8.2`, exit 0. There is nothing for the install to clear. |
| an architecture mismatch between what we fetch and what the machine is | The asset is x64 and Windows 11 on ARM64 runs x64 under emulation. A genuine mismatch is `unusable` anyway - measured with a real ARM64 image on this x64 box. |
| a runtime component present here and absent there | **This one.** One non-OS import, present here from a redistributable installed 2025-05-12, and its absence reproduces the exact symptom and the exact report text. |
| the process starting and dying before it writes anything | True, and this is the family the cause belongs to. `0xC0000135` says which member: it died in the loader, before its own first instruction. |

**The honest limit.** What is proven is that a missing dependency produces exactly what the captain saw, and that `VCRUNTIME140.dll` is the only dependency herdr has that a clean Windows 11 machine can be missing.
What is NOT proven is that the captain's VM is missing it, because this seat cannot reach that machine.
That is what 40.7 is for.

### 40.6 What the install says now, and what it will not say

Two things were wrong in the report itself, independently of the cause.

**The exit code was thrown away.** `Get-FmInstallCommandProbe` ran the tool, read `$res.ExitCode` to decide whether the output was a version, and then discarded it.
`0xC0000135` was returned on the captain's machine and never printed, so the log named a symptom and no cause - the exact thing `CONTRIBUTING.md` forbids ("report the code the TOOL returned ... never summarise an error into something that has to be guessed at later").
It is now carried through `Get-FmToolStatus` and into the requirement record, and `Get-FmToolExitCodeMeaning` names the codes Windows itself chooses for a process that never reached its own code.
That function already existed for winget's HRESULTs and was extended rather than duplicated; a second one with the same name was written first and caught, which is the hazard `CONTRIBUTING.md` describes as silent.

Before and after, for the captain's own case:

```
before  'herdr' resolves to C:\...\herdr.exe but answers nothing to --version,
        so it is not verified as the real tool

after   'herdr' resolves to C:\...\herdr.exe but answers nothing to --version,
        so it is not verified as the real tool - it exited 0xC0000135, which
        means a DLL it needs is not on this machine, so Windows stopped it
        before it ran any of its own code
```

**The summary said `installed` for a tool that will not run.** The command route has ended by reaching what it installed since section 37.2; the portable route ended at "the bytes are on disk", which is why the captain's report contained `[missing] tool herdr` and `summary: herdr installed` in the same run.
`Invoke-FmToolRoute` now proves a portable install by RUNNING the tool, and reports `failed` - naming where the files went, and why the tool does not run - when it cannot.

**What did NOT change is the bar.** `unknown-version` is still not a pass, a required tool that fails it still ends the run NOT READY, and naming a cause never turns a failure into a success.
A test pins that specifically: the sentence carrying `0xC0000135` still ends "so it is not verified as the real tool".

### 40.7 What this seat cannot do, and the one paste that settles it

**We cannot confirm the cause from here, and we cannot fix it from here.**

- The captain's VM is unreachable from this seat, so whether `VCRUNTIME140.dll` is absent there is inference, not measurement.
- The redistributable that supplies it needs administrator, which this brief puts out of scope and this installer refuses on principle.
- Extracting the single DLL from Microsoft's own bundle without administrator does not work - **MEASURED, 2026-08-21**: `vc_redist.x64.exe` (25,635,768 bytes, Authenticode `Valid`, `CN=Microsoft Corporation`) run unelevated as `/extract:<dir> /quiet /norestart` produced an empty directory and had to be killed at 90 seconds.

So what this task produces instead is a diagnostic that answers it in one paste.
It runs in **Windows PowerShell 5.1 and PowerShell 7** - the captain's clean-VM log shows them in 5.1, so a `pwsh`-only script would be a trap - needs no administrator, installs nothing, changes nothing, and prints a verdict rather than evidence to interpret.

```powershell
# ---------------------------------------------------------------------------
# firstmate: why will a tool that is on this machine not run?
# Paste this whole block into a PowerShell window - Windows PowerShell 5.1 or
# PowerShell 7, either works. It needs no administrator, installs nothing,
# changes nothing, and prints what it finds.
# ---------------------------------------------------------------------------
$tool = 'herdr'

function Show($label, $value) { Write-Host ("  {0,-22} {1}" -f $label, $value) }
function Head($text) { Write-Host ''; Write-Host $text -ForegroundColor Cyan }
$verdict = @()

Head "1. this machine"
Show 'windows' ((Get-CimInstance Win32_OperatingSystem).Caption + ' build ' + [Environment]::OSVersion.Version.Build)
Show 'processor' $env:PROCESSOR_ARCHITECTURE
Show 'shell' ("PowerShell " + $PSVersionTable.PSVersion)

Head "2. where '$tool' resolves"
$cmd = Get-Command -Name $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) {
    Show 'result' "NOT ON PATH - nothing else below can be answered"
    $verdict += "'$tool' is not on PATH at all."
    Write-Host ''; Write-Host 'VERDICT' -ForegroundColor Yellow; $verdict | ForEach-Object { Write-Host "  $_" }
    return
}
$exe = $cmd.Source
$file = Get-Item -LiteralPath $exe
Show 'path' $exe
Show 'bytes' $file.Length
Show 'modified' $file.LastWriteTime
Show 'sha256' (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash

Head "3. what happens when it is run"
# The .NET API rather than Start-Process: Windows PowerShell 5.1 hands back a
# process object whose ExitCode is EMPTY after a timed WaitForExit, and the exit
# code is the single most important line in this whole report.
$code = $null; $out = ''; $err = ''
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '--version'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $code = $proc.ExitCode
} catch {
    Show 'result' 'WINDOWS REFUSED TO START IT'
    Show 'refusal' $_.Exception.Message
    $verdict += "Windows would not start $exe at all. That is the machine declining the launch, not the program failing."
}
if ($null -ne $code) {
    Show 'exit code' ('{0} (0x{1:X8})' -f $code, $code)
    Show 'stdout bytes' $out.Length
    Show 'stderr bytes' $err.Length
    foreach ($line in @(($out + $err) -split "`r?`n")) {
        if ($line.Trim()) { Show 'printed' $line.Trim() }
    }
    $known = @{
        -1073741515 = 'STATUS_DLL_NOT_FOUND - a DLL it needs is not on this machine'
        -1073741502 = 'STATUS_DLL_INIT_FAILED - a DLL it needs failed to start up'
        -1073741701 = 'STATUS_INVALID_IMAGE_FORMAT - built for a different processor'
        -1073741795 = 'STATUS_ILLEGAL_INSTRUCTION - built for a newer CPU than this one'
        -1073741790 = 'STATUS_ACCESS_DENIED - this machine denied it as it started'
    }
    if ($known.ContainsKey($code)) { Show 'meaning' $known[$code] }
    if ($code -eq 0 -and $out.Trim()) { $verdict += "It RUNS. '$tool --version' answered and exited 0, so this is not where the problem is." }
    if ($code -ne 0 -and -not ($out + $err).Trim()) { $verdict += "It started, printed NOTHING on either stream, and exited 0x$('{0:X8}' -f $code). A program that reaches its own code says something; this one did not." }
}

Head "4. what the file is, and what it needs"
$b = [System.IO.File]::ReadAllBytes($exe)
$peOff = if ($b.Length -gt 0x40) { [BitConverter]::ToInt32($b, 0x3C) } else { 0 }
$isPe = ($b.Length -gt 0x40 -and $b[0] -eq 0x4D -and $b[1] -eq 0x5A -and
         $peOff -gt 0 -and ($peOff + 250) -lt $b.Length -and
         $b[$peOff] -eq 0x50 -and $b[$peOff + 1] -eq 0x45)
if (-not $isPe) {
    Show 'result' 'THIS IS NOT A WINDOWS PROGRAM - it has no PE header, so Windows cannot run it whatever else is true'
    $verdict += "$exe is not a Windows executable at all. Whatever put it there did not put a program there."
}
$machine = if ($isPe) { [BitConverter]::ToUInt16($b, $peOff + 4) } else { 0 }
$arch = switch ($machine) { 0x8664 { 'x64' } 0x14c { 'x86' } 0xAA64 { 'arm64' } default { ('0x{0:X}' -f $machine) } }
if ($isPe) { Show 'built for' $arch }
$numSec = if ($isPe) { [BitConverter]::ToUInt16($b, $peOff + 6) } else { 0 }
$optOff = $peOff + 24
$plus = ($isPe -and [BitConverter]::ToUInt16($b, $optOff) -eq 0x20B)
$dd = $optOff + $(if ($plus) { 112 } else { 96 })
$impRva = if ($isPe) { [BitConverter]::ToUInt32($b, $dd + 8) } else { 0 }
$secOff = $optOff + $(if ($plus) { 240 } else { 224 })
$sections = @()
for ($i = 0; $i -lt $numSec; $i++) {
    $s = $secOff + ($i * 40)
    $sections += New-Object psobject -Property @{
        VA = [BitConverter]::ToUInt32($b, $s + 12); VSize = [BitConverter]::ToUInt32($b, $s + 8); Raw = [BitConverter]::ToUInt32($b, $s + 20)
    }
}
function ToOffset($rva) {
    foreach ($s in $sections) { if ($rva -ge $s.VA -and $rva -lt ($s.VA + [Math]::Max($s.VSize, 1))) { return $s.Raw + ($rva - $s.VA) } }
    return 0
}
$needed = @()
if ($impRva -ne 0) {
    $p = ToOffset $impRva
    while ($true) {
        $nameRva = [BitConverter]::ToUInt32($b, $p + 12)
        if ($nameRva -eq 0) { break }
        $n = ToOffset $nameRva; $end = $n
        while ($b[$end] -ne 0) { $end++ }
        $needed += [Text.Encoding]::ASCII.GetString($b, $n, $end - $n)
        $p += 20
    }
}
$dirs = @([System.IO.Path]::GetDirectoryName($exe), (Join-Path $env:SystemRoot 'System32'), $env:SystemRoot) +
        (($env:PATH -split ';') | Where-Object { $_ })
$missing = @()
foreach ($dll in ($needed | Sort-Object -Unique)) {
    # api-ms-win-* and ext-ms-* are API SETS: Windows resolves them itself and
    # there is no file to find, so an absent file is not an absent dependency.
    if ($dll -like 'api-ms-win-*' -or $dll -like 'ext-ms-*') { Show $dll 'OS api-set'; continue }
    $found = ''
    foreach ($d in $dirs) {
        try { $c = Join-Path $d $dll } catch { continue }
        if (Test-Path -LiteralPath $c -PathType Leaf) { $found = $c; break }
    }
    if ($found) { Show $dll $found } else { Show $dll '*** MISSING ON THIS MACHINE ***'; $missing += $dll }
}
if ($missing.Count -gt 0) {
    $verdict += ("$tool cannot start because this machine does not have: " + ($missing -join ', ') + '.')
    if ($missing -contains 'VCRUNTIME140.dll' -or $missing -contains 'MSVCP140.dll' -or $missing -contains 'VCRUNTIME140_1.dll') {
        $verdict += 'Those come from the Microsoft Visual C++ 2015-2022 Redistributable, which is not part of Windows.'
    }
}
if ($arch -eq 'arm64' -and $env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { $verdict += 'The file is an ARM64 build and this is an x64 machine, which cannot run it.' }

Head "5. the marks on the file"
$streams = @()
try { $streams = @(Get-Item -LiteralPath $exe -Stream '*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Stream) } catch { }
Show 'streams' (($streams | Where-Object { $_ -ne ':$DATA' }) -join ', ')
if ($streams -contains 'Zone.Identifier') {
    Show 'zone' ((Get-Content -LiteralPath $exe -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) -join ' / ')
    $verdict += 'The file carries a download mark (Zone.Identifier). Clear it with: Unblock-File -LiteralPath "' + $exe + '"'
} else { Show 'zone' 'none - this file carries no download mark' }
$sig = Get-AuthenticodeSignature -LiteralPath $exe
Show 'signature' $sig.Status
Show 'signer' $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '<unsigned>' })

Head "6. what could be refusing to run it"
$sac = 'not set (off)'
try {
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop).VerifiedAndReputablePolicyState
    $sac = switch ($v) { 0 { 'OFF' } 1 { 'ON - ENFORCED' } 2 { 'EVALUATION MODE' } default { "state $v" } }
} catch { }
Show 'Smart App Control' $sac
if ($sac -like 'ON*') { $verdict += 'Smart App Control is ENFORCED. It blocks unsigned programs, and this one is ' + $sig.Status + '.' }
try {
    $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop
    Show 'WDAC enforcement' $dg.CodeIntegrityPolicyEnforcementStatus
} catch { Show 'WDAC enforcement' 'could not be read from this session' }
try {
    $al = Get-AppLockerPolicy -Effective -ErrorAction Stop
    Show 'AppLocker' $(if ($al.RuleCollections.Count -gt 0) { 'rules are configured' } else { 'no rules' })
} catch { Show 'AppLocker' 'no policy readable from this session' }
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Show 'Defender realtime' $mp.RealTimeProtectionEnabled
} catch { Show 'Defender realtime' 'needs administrator to read' }

Write-Host ''
Write-Host 'VERDICT' -ForegroundColor Yellow
if ($verdict.Count -eq 0) { $verdict += 'Nothing above explains a failure. Send this whole output back.' }
$verdict | ForEach-Object { Write-Host "  $_" }
Write-Host ''
```

**It was run here against all three cases, in both shells, before being written down.**

Against the reproduction, in Windows PowerShell 5.1:

```
1. this machine
  windows                Microsoft Windows 11 Pro build 26200
  processor              AMD64
  shell                  PowerShell 5.1.26100.8115

3. what happens when it is run
  exit code              -1073741515 (0xC0000135)
  stdout bytes           0
  stderr bytes           0
  meaning                STATUS_DLL_NOT_FOUND - a DLL it needs is not on this machine

4. what the file is, and what it needs
  built for              x64
  ADVAPI32.dll           C:\WINDOWS\System32\ADVAPI32.dll
  api-ms-win-crt-runtime-l1-1-0.dll OS api-set
  ...
  VCRUNTIMEZZZ.dll       *** MISSING ON THIS MACHINE ***
  ws2_32.dll             C:\WINDOWS\System32\ws2_32.dll

VERDICT
  herdr cannot start because this machine does not have: VCRUNTIMEZZZ.dll.
```

Against the untouched 0.8.2 release, in PowerShell 7.6.4:

```
3. what happens when it is run
  exit code              0 (0x00000000)
  stdout bytes           12

VERDICT
  It RUNS. 'herdr --version' answered and exited 0, so this is not where the problem is.
```

Against a file that is not a program, in Windows PowerShell 5.1:

```
  result                 WINDOWS REFUSED TO START IT
  refusal                Exception calling "Start" with "1" argument(s): "The specified
                         executable is not a valid application for this OS platform."
  result                 THIS IS NOT A WINDOWS PROGRAM - it has no PE header, so Windows
                         cannot run it whatever else is true

VERDICT
  Windows would not start C:\...\herdr.exe at all. That is the machine declining the
  launch, not the program failing.
```

**One detail in it was a defect found by running it.** The first version used `Start-Process -PassThru`, and Windows PowerShell 5.1 returns a process object whose `ExitCode` is EMPTY after a timed `WaitForExit` - measured, and it printed nothing at all where the exit code should have been.
The exit code is the single most valuable line in the whole report, so it uses `System.Diagnostics.Process` directly, which behaves identically in both shells.

**A second detail matters for reading section 4 of its output.** `api-ms-win-*` names are API sets that Windows resolves internally and that have NO file in `System32` - measured on this Windows 11 build - so a file check reports every one of them missing unless it knows that.
It knows.

### 40.7a The prompt-hang bug, hit again while fixing this one

**MEASURED here, 2026-08-21, on this task's own working session, and it is the same bug commit 2f4d97e fixed for the installer.**

The first version of the reporting change called `Get-FmToolExitCodeMeaning -ExitCode $code` without `-Command`, because a second function of that name was written before the existing one was found.
`-Command` is `[Parameter(Mandatory)]`, so PowerShell did not fail the call.
**It asked for a value.**

Which of those two things happened depended entirely on how the suite was started:

| how the suite was run | what a missing mandatory parameter did |
| --- | --- |
| `pwsh -NoProfile -NonInteractive -Command "Invoke-Pester ..."` | threw `ParameterBindingException`, one named test failure, visible immediately |
| `pwsh -NoProfile -Command "Invoke-Pester -Path ./tests"` | printed `Supply values for the following parameters:` into a redirected pipe and blocked indefinitely - **two runs produced 0 bytes of output and had to be killed after 10 and 15 minutes** |

That is commit 2f4d97e's finding reproduced from the other side.
Its fix put `-NonInteractive` on the suite child that `Invoke-FmMachineSuite` starts, so any prompt the suite can reach becomes a named test failure instead of a dead install.
The same flag was missing from the shell this task used to run the suite by hand, and it cost the same two things it cost on the clean VM: no output, and no clue why.

**Two things came out of it beyond a lesson.**

`Get-FmToolUnprovenDetail`'s string parameters now all carry `[AllowEmptyString()]`, matching `Get-FmToolExitCodeMeaning` and `Get-FmToolRunFailureDetail`, which already did.
A mandatory `[string]` without it REJECTS `''` and prompts for a replacement, and this function composes a report line on a console nobody is watching.
A line built from an empty command name is wrong and readable; a line that stops to ask for one hangs the install.
A test pins it.

**And the duplicate name is the second hazard, which `CONTRIBUTING.md` already names: two areas defining one function name is silent, not an error.**
The second `Get-FmToolExitCodeMeaning` was never called - the later definition in the same file won - so the symptom was not "duplicate function" but "the function I just wrote has a parameter I did not give it".
The existing one was extended instead, which is also what the one-owner rule required.

### 40.8 What the captain does with the answer, and what is not ours to decide

If the diagnostic names `VCRUNTIME140.dll` as missing, the remedy is the Microsoft Visual C++ 2015-2022 Redistributable, and it needs administrator once:

```
winget install --id Microsoft.VCRedist.2015+.x64 --source winget
```

or the same installer from Microsoft directly at `https://aka.ms/vs/17/release/vc_redist.x64.exe`.
Then re-run `install.ps1`, which needs no administrator and will prove herdr by running it.

**This installer does not do that itself, and the reason is the boundary rather than the difficulty.** It needs elevation, and nothing here installs a machine-wide Microsoft runtime on the captain's machine without being asked.

If the diagnostic instead reports Smart App Control enforced, that is the captain's machine refusing an unsigned program, and it stays their call.
Nothing here turns a protection off, and nothing here should: herdr 0.8.2 is `NotSigned` - measured - so a machine set to run only signed and reputable programs is behaving correctly, and the options are theirs to weigh.

**What must not happen either way is a looser check.** A herdr that cannot run means no worker can be dispatched, so a report that called that machine ready would be worse than the honest failure it prints today.

### 40.9 What was NOT proven here

- **The captain's VM was never touched.** Every measurement in this section was taken on a machine that HAS the Visual C++ runtime. That `VCRUNTIME140.dll` is what is missing there is the strongest available inference, not a measurement, and 40.7 exists because of that gap.
- **The missing runtime was simulated, not removed.** `VCRUNTIME140.dll` was not uninstalled from this machine; a copy of the real binary was given an import name that does not resolve. The loader path, the exit code, the empty streams and the classification are all real; the DLL's absence is staged.
- **No fix for the dependency was implemented, because none exists without administrator.** The unelevated extraction attempt in 40.7 is the measurement behind that statement, not an assumption.
- **The `install.ps1` report was not watched end to end on a clean machine.** The changed lines were exercised through their own functions and through the suite, including the portable route running for real against an archive containing a tool that answers `--version` and one that does not.
- **Smart App Control was never observed blocking anything.** This machine reports it OFF, so the branch that names it in the diagnostic is written and unexercised against a machine where it is on.
