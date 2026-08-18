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

```
Invoke-Pester -Path ./tests
  2063 passed, 0 failed, 25 skipped   (30m15s)
```

One whole-directory run in one process, on Windows 11, over the merged tree.
`tests/FmAnalyzer.Tests.ps1` is inside that run, so the repo-wide
`Invoke-ScriptAnalyzer` sweep at every severity is clean as part of it.
The run before it, over the same tree with the idempotence defect above still in
place, was 2056 passed / 1 failed - so the failure was real and the fix is what
closed it, rather than the number moving on its own.

As section 30's note says, these were made in a checkout whose `CLAUDE.md` and
`.claude/skills` were already materialized.
That repair is now also what `Protect-FmInstructionLink` keeps in place, and this
run is the first where `git status` stayed clean of both paths for the whole
suite.

---

## 32. The finished-run stall: the diagnosis was the opposite of the report - `PROVEN (Windows 11)`

Reported: workers wait forever on background runs that have already finished,
found by counting processes whose command line names the worker's worktree.
`docs/finished-run-stall.md` owns the full account; this section is what was
executed.

### 32.1 The forensic pass - `PROVEN`, from the harness's own records

Claude Code writes a `queue-operation` record when a background task actually
ends, and every typed message, into `~/.claude/projects/<project>/<session>.jsonl`.
Pairing the two answers the question directly.
Read-only analyzers over the four workers' transcripts (`crew-first`,
`tg-route`, `ui-voice`, `installer`) produced:

```
NUDGE line=333 17-08-2026 02:26:51 PM
   "Your background suite run has already finished - there are zero pwsh
    processes left in your worktree, so the completion ..."
   STILL RUNNING: bsx85glsp started 14:04:32, FINISHED 14:34:42 = 7.8 min AFTER the nudge
   STILL RUNNING: bx7a48x6f started 14:01:01, FINISHED 14:34:41 = 7.8 min AFTER the nudge
```

Nine nudges, four workers, and **every one named at least one run that was still
running** - by 7.0 to 54.1 minutes. The table is in
`docs/finished-run-stall.md`.

The completion mechanism itself was measured working, and fast. From
`crew-first`, whose turn had ended 33 minutes earlier with no message in between:

```
238 13:29:44.614 enqueue  <task-notification><task-id>bm3wefu0n</task-id> ... <status>failed</status>
239 13:29:44.638 dequeue
240 13:29:45     user     <task-notification> ... (delivered as a fresh turn)
242 13:29:52     assistant (the worker resumes)
```

24 ms from enqueue to delivery into an idle session. Four such deliveries were
measured; three completed inside 35 ms.

### 32.2 The false positive, reproduced live against a running suite - `PROVEN (Windows 11)`

`Invoke-Pester -Path ./tests` was launched in the background exactly as the
stalled workers launched theirs, and both readings were taken while it ran.
The measuring command builds the worktree pattern from `state/<id>.meta` rather
than naming it, because a command that names the path it searches for matches
itself:

```
$ Get-CimInstance Win32_Process -Filter "ProcessId=33228"
  ALIVE  cpu=267.8s
  its own command line names the worktree: False

$ the ad-hoc check the supervisor used (pwsh.exe naming the worktree)
  count = 1
  includes the running suite: False

$ pwsh bin/fm-run-liveness.ps1 finished-run-stall
  liveness: processes · task: finished-run-stall · 7 live process(es) · pids: 7888, 11372, 11632, 24412, 30540, 33228, 36068
  includes the running suite: True
```

**The ad-hoc check cannot see the run at all.** The single process it did match
was not the suite but a transient grandchild the suite had just spawned:

```
ProcessId       : 28580
ParentProcessId : 33228
cmd             : pwsh.exe -NoProfile -File ...\6\firstmate-win\bin\fm-watch.ps1 -MaxCycles 1
```

That is why the count read zero intermittently rather than always: it was
sampling incidental grandchildren, never the run.

The mechanical reason is in the run's own command line. The harness starts a
background command as `pwsh.exe -NoProfile -Command "<script text>"` with the
worktree as its **working directory**, which never appears in `CommandLine`.

### 32.3 The measurement the new reading rests on - `PROVEN (Windows 11)`

Every recorded worker's agent process, and its direct children, read from one
`Win32_Process` table:

```
  finished-run-stall     agent pid 34720    direct children 2   liveness processes
  lock-identity          agent pid 37388    direct children 4   liveness processes
  nm-windows             agent pid 32480    direct children 1   liveness processes
  ui-readonly            agent pid 11932    direct children 2   liveness processes
```

and, sampled earlier the same day while two of those workers were idle at their
prompt, the same agents had **zero** children. The Bash and PowerShell tool
shells are created per call and exit with it - measured, for instance, at
`bash.exe` pid 11372 created 10:32:26, the same second its background command
started, under `claude.exe` pid 34720 created at 10:23:56. There is no
long-lived idle tool shell, which is what makes "the agent has descendants" and
"the worker is running something" the same statement.

The launcher is identifiable without guessing because firstmate wrote its
command line:

```
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command "$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false';
 claude --dangerously-skip-permissions --effort 'xhigh'
 ('...launch-brief: ' + (Get-Content -Raw -LiteralPath 'C:\Users\ADMIN\firstmate-win\data\finished-run-stall\brief.md'))"
```

### 32.4 Suite and analyzer numbers - `PROVEN (Windows 11)`

Two back-to-back whole-directory runs on the rebased branch (`8097620`, a clean
fast-forward onto `main` at `835bc53`):

```
PASS1 total=2121 passed=2087 failed=9 skipped=25
  this checkout's own instruction surface  x3
  Install-FmHome / where do I start Claude x2
  Invoke-FmDoctor                          x4
PASS2 total=2121 passed=2096 failed=0 skipped=25
git status after: (clean)
```

The nine PASS1 failures are the documented fresh-worktree instruction-surface
set that the suite repairs as it goes; PASS2 is the run to read. Worth recording
against the earlier account of this: `git status` came back **clean** after both
passes this time, so the worktree no longer ends with `CLAUDE.md` and
`.claude/skills` dirty.

The analyzer sweep, repo-wide and file-by-file so nothing is silently skipped:

```
0 findings across 186 files
```

Three markdown-only edits landed after PASS2 (a wrapped bullet in
`CONTRIBUTING.md`, two sentences in `docs/finished-run-stall.md`, and this
subsection). No `.ps1`, `.psm1` or `.psd1` differs from the validated tree.
`tests/FmContract.Tests.ps1` is the only suite that reads `CONTRIBUTING.md`, and
it was re-run against the final tree: **39 passed, 0 failed**, with the analyzer
sweep repeated there at 0 findings.

### 32.5 What is NOT proven here

- That no genuine stall exists. Nine instances were checked and none was one;
  that is not the same claim.
- The Linux `/proc` branch of `Get-FmRunLivenessProcessTable`. It is the
  development path; the Windows branch is the product and is what ran above.
- The reading against a torn-down or crashed endpoint on Windows. It returns
  `unknown` by construction there, and the tests cover that branch, but no
  crashed worker was observed during this task.

## 33. The screen that argued with itself - `PROVEN (Windows 11)`

Task: the browser screen showed the captain two contradictory answers to one
question, in machinery, over and over.
Run in a disposable worktree on the captain's Windows 11 laptop on 2026-08-18,
on `fm/ui-readonly` over `835bc53`, against a real headed Chrome driven by
`chrome-devtools-axi` and a real hosted session.

The captain read an in-progress version of this work on their own screen partway
through and sent an addendum that changed its shape.
Section 33.6 onward is that second half, and it overrides the first where the two
disagree.

Nothing on the captain's own workspace was touched: the whole run used a scratch
workspace under the session's temporary directory, pointed at by this worktree's
own `.fm-workspace`, which is gitignored and per-machine.

### 33.1 What the captain saw

One screen, one moment.
The left panel listed three jobs with live percentages.
The reply beside it said:

```
Captain, nothing is under way - no active work, an empty queue, and no held or
blocked items... this session opened read-only: another firstmate session (pid
25876) holds the lock, so I can't dispatch, steer, or merge from here.
```

Both halves were honest, which is precisely why it was unusable.
The panel reads the durable records.
The reply came from the session the bridge hosts, which had a much narrower view
of that home and answered from it.
Three faults in one reply: the two halves disagreed, the reply explained the
internal arrangement in machinery, and the same event re-fired and produced eight
near-identical messages in a row.

### 33.2 The design that was chosen, and the one that was not

The honest alternative was to forbid the hosted session from speaking about the
fleet at all - the panel owns what is happening, the assistant owns conversation.
That was rejected: the captain talks to this screen precisely to ask what is
happening, and an assistant that must answer "I cannot say" to the main question
is a worse screen than the one it replaces.
It also does not actually fix the contradiction - the captain still reads the
panel and the reply together.

What shipped is **one reading, rendered twice**.
`Get-FmBridgeFleet` was already the panel's source; `/api/say` now makes that
same call once per turn and hands the result to the session with the captain's
words, so the reply is drawn from the object the panel is painting rather than
from a second look that could differ in timing, in parsing, or in what it was
allowed to see.
Two read paths that agree by convention would drift; two renderings of one object
cannot.

Two guarantees sit on top, and they are code rather than requests:

- every reply leaves through `ConvertTo-FmBridgePlainText -Prose`, the same
  translator the panels already used, extended rather than duplicated;
- `Remove-FmBridgeRepetition` collapses a reply that says one thing twice.

### 33.3 The contradiction, closed, with three jobs genuinely running

Three real worker processes, each doing real work in this checkout and reporting
its own percentage into its durable record, plus one open decision.
The panel and the reply, read out of the live page in the same call, with the
panel read immediately before the turn and immediately after it:

```
panel before   LOCK IDENTITY 75%   TG ROUTE 25%   UI READONLY 55%
panel after    LOCK IDENTITY 75%   TG ROUTE 25%   UI READONLY 55%
header         UNDER WAY 3   WAITING ON YOU 1

reply          "Three jobs are moving right now. lock-identity is at 75 percent
                and has just finished reading the tests. ui-readonly is at 55
                percent, having worked through the bin. tg-route is at 25
                percent, done with the docs, and it is waiting on you: it needs
                to know which provider the test should use."
```

Same three names, same three percentages, same count, same decision.

**One bounded property, stated rather than hidden.**
The reading is taken when the turn is sent, and a turn takes tens of seconds, so
a job whose percentage moves during it leaves the reply quoting the older number
beside a panel showing the newer one.
Measured on an earlier run, while the workers were still climbing:

```
reading at turn   lock-identity 45%   tg-route 10%   ui-readonly 40%
panel ~30s later  lock-identity 60%   tg-route 25%   ui-readonly 55%
```

The names, the count and the open decision were identical throughout; only the
numbers had moved on.
That is an answer describing the moment it was asked, which the activity log
timestamps, and it is a different thing from the defect this section is about -
the panel listing three jobs while the reply said none existed.
It is recorded here rather than papered over.

### 33.4 The cure reintroduced the disease, and the browser caught it twice

Both of these are the same defect arriving through the fix for it, and neither
would have been found by reading the code.

**A job's own name, translated.**
The panel row read `LOCK IDENTITY` and the reply beside it called the same job
`controls-identity`:

```
reply   "Three things are moving right now: the controls-identity at 90%,
         ui-readonly at 55%, and tg-route at 25% ..."
```

The vocabulary had translated `lock` inside a job's own name.
That observation is also the proof that the translator is genuinely on the live
reply path: no model produces the string "the controls-identity" - it is exactly
what the `lock -> the controls` rule makes of `lock-identity`, article and all.
The rule that closed it is `-Keep`: a name the screen is showing is masked and
restored untouched, on the same principle as a URL.

**A record handle, repeated back.**
The reading carried each open decision's exact key so the session could close it,
and the session told the captain that tg-route was "still held up on the carrier
question" - `carrier` being the handle, a word on no panel and in no vocabulary.
Asking a model to hold a secret is not a design, so the handle is simply not sent
any more; the session reads the record for it at the moment it writes to it,
which is the only moment it needs one.

### 33.5 The machinery, swept

Every reply and every panel line on screen at the end of the run, with the job
names masked out first because a name the panel prints is not machinery:

```
lock, locks, read-only, read only, pid, process id, uncommitted, dispatch,
steer, merge, checkout, worktree, crewmate, teardown, harness, carrier, key=,
session, unable   ->   no internal term on screen
```

The translator is what makes that a guarantee rather than a hope, and the suite
drives the captain's exact leaked reply through it:

```
in    Captain, nothing is under way - ... This session opened read-only: another
      firstmate session (pid 25876) holds the fleet lock, so I can't dispatch,
      steer, or merge from here. Your checkout has uncommitted changes.
out   Captain, nothing is under way - ... This session opened watching only:
      another firstmate session holds the controls, so I can't start work,
      redirect, or land the work from here. Your local copy has unsaved edits.
```

One trap the table walked into on the way, worth recording because nothing on
screen would have shown it: `merge` was first translated to "bring the work in",
and the dangling-preposition tidy-up at the end of the same function - which
exists to clean up after a REMOVAL and cannot tell a leftover from a word the
table meant - then ate the "in" it had just been handed.
"It was merged." became "It was brought."
The plain words are now clear of those prepositions and `Get-FmBridgeVocabulary`
has a test that keeps them so.

### 33.6 The captain's addendum: a limitation is never the reply

Their words, on seeing the in-progress version:

> it also say "I can see the work but cannot start or stop anything from here"
> this is wrong as smart AI system it never should say this line instead it
> should give the solution of that or way to do that

They are right, and the sentence they threw out was mine.
A limitation is an explanation of this system's own arrangement wearing the
clothes of an answer; the captain did not ask how the screen is put together.
Softening it would have been the same mistake with better manners, and deleting
it and saying nothing would have left them asking twice.

So the bridge no longer appends anything.
`Get-FmBridgeStandingNote` is gone and `Get-FmBridgeRoute` is in its place, and
it returns a route rather than a refusal: starting, stopping and steering work
happens in the firstmate window the captain already has open on this machine,
which is the same fact read from the side that has an action on it.
The session is told, in the turn prompt, never to answer with something it cannot
do - not as the reply, not as a closing line, not softened - and to give the next
step instead.

Asked to do exactly the thing this screen has no hands for:

```
captain   stop lock-identity right now and start the payment tests instead.
firstmate Halting lock-identity at its 75 percent and putting the payment tests
          in its place is a call you make in the firstmate window on this machine
          - ask there to stop lock-identity and to begin the payment tests, and I
          will write that request out for you word for word if it helps. From
          here I will keep watching ... Once the payment tests appear I will
          report them by name alongside the rest.
```

The route, the offer, and what it will do about it.
No confession anywhere in it.

One more turn was needed to finish the rule, and it is the case a prompt written
in good faith misses.
Asked point blank, with the form of the answer constrained:

```
captain   can you do it yourself? yes or no.
firstmate No.
```

Responsive to the letter, and still a limitation standing alone as the whole
reply - a bare no on a screen, which is exactly what the captain threw out.
A yes-or-no is them asking for brevity, not for a dead end, so the instruction
now says so outright.
The same question, after:

```
firstmate No - starting, stopping and redirecting work isn't something this
          screen does; that happens in the firstmate window you already have open
          on this machine. Ask for it there, or I'll write out the exact wording
          for you to paste. Meanwhile, here's where things stand: lock-identity is
          at 75 percent ... Tell me the provider and I'll draft that answer for
          you to hand over.
```

### 33.7 It said the same thing twice in one breath

Also from the addendum, off the captain's screen, inside a single reply:

```
...I can see this work but cannot start or stop any of it from here.
I can see the work but cannot start or stop anything from here.
```

The cause, precisely: the session had been told the same fact and said it in its
own words at the end of its answer, and the bridge then appended its canned
sentence underneath.
A fixed line added under a written answer cannot know what that answer already
says.
Deleting the append removes the cause outright, and 32.6 is why it was deleted
anyway.

The guard behind it was widened as well, because the shape the captain hit was
invisible to it: `Remove-FmBridgeRepetition` compared whole LINES, and both of
those sentences were on one.
It now compares sentences, putting them back on the line they came from.
The threshold moved from 0.7 to 0.6 for a measured reason rather than a hunch -
that observed pair shares eleven of the seventeen distinct words between them,
0.65, so a rule at 0.7 watched it go past.
Every list and stepped answer in the suite sits below 0.35, so there is a wide
gap between the two rather than a fine line being walked.

### 33.8 The mangled work summaries: half a defect, precisely

The addendum asked why the panel read as nonsense, citing four rows.
Checking each against the record it came from separates them into two kinds.

**Three of the four are faithful, and the fault is this evidence run's own
scaffolding.**
The worker script written to give the browser something real to show wrote its
notes ungrammatically:

```
record   working: [75%] the tests is read
panel    The tests is read
```

The translator removed the state label and the percentage and changed nothing
else.
A real worker writing that sentence would see the same on screen, correctly.
The scaffolding now writes "finished reading the tests" and the panel reads
`Finished reading the tests`.

**The check did turn up a real defect of exactly the shape they suspected**,
which the earlier screenshot in this section shows as three rows all reading
`Is through`.
A removal at the HEAD of a line takes the sentence's subject with it:

```
record   working: [90%] FmLock.Tests.ps1 is through          panel   Is through
record   working: [10%] tests/FmBridge.Tests.ps1 needs a case panel   Needs a case
record   working: [40%] fm/fix-signin is rebased              panel   Is rebased
record   done: report at docs/windows-e2e-evidence.md is ready
                                                    panel   Report ready is ready
```

A name at the head now leaves a noun behind rather than a hole, and the
report-path rule tells apart a path that ENDS the line from one the sentence
carries on past:

```
That file is through          That file needs another case
That branch is rebased        The report is ready
```

A name mid-sentence is still removed rather than replaced - it was never the
problem, and a placeholder there would add noise to a sentence that already
reads.

### 33.9 Two smaller things fixed in the same pass

The decision panel's "Answer by voice" button used to prefill the captain's own
message box with `Answer the open decision <key> on task <id>: `, putting two
internal identifiers into the box they then read and type into.
It now reads `About the question on tg route: `.

A stale key made the reply box say the bridge was not reachable, about a bridge
that was running perfectly well - hit while driving this seam, after the bridge
was restarted under a tab that still held the old key.
`bootCheck` already guarded that; `respond` did not, and now does.

Markdown reached the screen as literal asterisks - `- **lock-identity** - 75%,
working` - because the page sets a reply as text rather than parsing it, and the
voice reads the same string aloud.
Emphasis and heading markers are now stripped in prose, and the turn prompt asks
for plain sentences; the bullet itself is kept, since it reads as a list either
way.

### 33.10 One failure that was the launcher, not the tree - and how to not repeat it

Recorded because it looks exactly like a regression and is not one, and because
the next person to run this suite in the background will hit it.

Running the whole suite as a process detached from a launcher that then exits
fails one assertion, twenty minutes in:

```
[-] Get-FmParentProcessId.finds a parent for this process
    Expected the actual value to be greater than 1, but got $null.
```

Diagnosed rather than assumed.
`Get-FmParentProcessId` reads .NET's `Process.Parent`, which resolves only a LIVE
parent - it cannot safely identify a pid that has been recycled - so an orphaned
process has no parent to find.
A probe pinned it both ways:

```
detached, launcher still alive   parent -> 12345
detached, launcher exited        parent -> (nothing), while Win32_Process
                                 still reports the dead pid
```

So the test is asserting something true of every normal run and false of an
orphaned one, and the tree is untouched: the same file passes in a run whose
launcher stays alive, and the twenty-three other files in the orphaned run
passed with it.

**The rule this leaves:** run `Invoke-Pester -Path ./tests` from a parent that
outlives it.
This is an environmental constraint on the runner, not a defect in
`Get-FmParentProcessId`, whose null is the correct answer to "who is my parent"
when the parent is gone.

Which is narrower than it sounds, because the suite takes about three quarters of
an hour and the two obvious ways to give it that time both fail:

```
harness background run   killed at ~10 minutes, 17 of 45 files, 0 failures
plain detached run       orphaned, 24 of 45 files, that one assertion fails
```

What works is a keeper: a process that runs no tests itself, starts the suite as
its child, and waits for it.
The keeper being orphaned costs nothing, and the suite has a living parent for
its whole run.

### 33.11 The screen spoke on the captain's machine, and that is my defect

Reported by the captain as impact, twice, with three copies talking at once:

> your test copies of the screen have been SPEAKING ALOUD on the captain's
> machine twice now, with no browser open and no way for them to find or silence
> it

Everything of mine was stopped first - the screens, their hosted sessions, the
browsers behind them, and the stale key a force-kill leaves on disk.
One bridge on this machine was left alone deliberately: it belongs to another
lane's worktree, and killing another lane's live work is not a repair.

**What was actually making the noise, checked rather than guessed.**
Not firstmate's voice channel: `config/voice` exists in no home on this machine,
so `bin/fm-say.ps1` and `bin/fm-ask.ps1` were gated off throughout.
It was the page.
`ui/bridge.html` called the browser's own speech synthesis on every reply,
unconditionally:

```
respond()  ->  speak(res.reply)  ->  speechSynthesis.speak(...)
```

A page driven for a check runs in a browser with nothing on screen, so the sound
comes out of a machine whose owner can see no browser to close and no control to
mute - and one bridge per check meant several talking over each other.

**It is the contract, not a preference.** `AGENTS.md` section 9: the voice
channel "is off until the captain creates `config/voice`, and nothing calls it by
itself".
This page was calling it by itself, on the one surface loud enough to be heard
across a room.

So the page now asks before it speaks.
`Test-FmBridgeVoiceAllowed` puts the question to `Get-FmVoiceConfig`, which is
the gate's owner, and the bridge serves the answer on `/api/health` and again on
every `/api/fleet` poll so switching the voice off silences a page that is
already open.
`speak()` starts from `false` and returns early unless the captain has switched
it on.

**One test failure worth keeping.** The first cut called a function name I had
assumed rather than checked, and the "silent when it cannot tell" catch swallowed
the `CommandNotFound` - so three of the five tests passed for the wrong reason,
all of them the ones expecting silence.
The single test that asserts the voice DOES turn on is what caught it.
A guard that fails safe hides its own breakage from every test that only checks
the safe direction.

**Operating rule for this surface, and it is the captain's, not a preference.**
Do not start a screen that serves a page, and do not open a browser at one.
`-NoEngine` was my own first answer and it is not enough: it stops the session,
not the page, and the page is what the captain hears.
The gate above is a repair to the product, not a licence to go on driving it.

Verify over HTTP, against the API, with nothing rendering:

```
Invoke-RestMethod -Uri http://127.0.0.1:<port>/api/fleet -Headers @{ 'X-Fm-Token' = $token }
```

That reads the same object the panel paints, which is precisely the point of this
section - one reading behind both halves - so an assertion about what the panel
shows can be made without a browser existing.
What HTTP cannot answer is layout and what a reply looks like on screen; those
need a person to look, so ask the captain and let them arrange it.
Their machine is not a test rig.

### 33.12 The suite and the analyzer, on this branch

```
Invoke-Pester -Path ./tests
  2167 passed, 0 failed, 25 skipped   (33m11s, 46 files, one process)
```

Measured on this branch rebased onto `a0a1243`, which is the tree that will
merge.
`tests/FmAnalyzer.Tests.ps1` is inside that run, so the repo-wide
`Invoke-ScriptAnalyzer` sweep at every severity is clean as part of it.
`tests/FmBridge.Tests.ps1` is 109 of those tests, against 42 before this work.

Run under the keeper of section 33.10, which is what let it finish at all.
Three earlier whole-suite runs bracket that number and are worth keeping,
because each moved for a stated reason rather than on its own:

```
2125 passed / 0 failed   before the voice gate, over 835bc53
2130 passed / 0 failed   after it - the five tests the gate brought
2167 passed / 0 failed   rebased onto a0a1243, which brought 37 tests of its own
```

**One failure on the way, and it was the rebase rather than the tree.**
Checking out main's one-line `AGENTS.md` edit broke the Windows hardlink
`CLAUDE.md` holds to it, so the mirror read `conflict`:

```
[-] this checkout's own instruction surface.is healthy
    Expected collection @('link', 'mirror') to contain 'conflict'

AGENTS.md 56982 bytes 16:27      CLAUDE.md 56735 bytes 10:25
```

That is the hazard `CONTRIBUTING.md` already documents, with the repair it
already names - delete `CLAUDE.md`, run setup, which re-links it.
Worth recording anyway, because a rebase is a likelier way to hit it than the
editor the note describes, and the failure names the surface rather than the
rebase that broke it.
