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
