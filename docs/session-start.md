# Session start, bootstrap, and the project registry

Windows/PowerShell port of `bin/fm-session-start.sh`, `bin/fm-bootstrap.sh`, and
`bin/fm-project-mode.sh`. The bash headers remain the authoritative statement of
*why* each rule exists; this file records what the port keeps, what it changes,
and the seams other areas of the module plug into.

## Commands

| Command | Bash original |
| --- | --- |
| `bin/fm-session-start.ps1 [--reemit]` | `bin/fm-session-start.sh` |
| `bin/fm-bootstrap.ps1 [-DetectOnly] [-Locked] [-Network all\|skip\|only]` | `bin/fm-bootstrap.sh` |
| `bin/fm-bootstrap.ps1 -Install <tool>... -Approved` | `fm-bootstrap.sh install <tool>...` |
| `bin/fm-project-mode.ps1 [-Raw] <name>` | `bin/fm-project-mode.sh [--raw] <name>` |
| `bin/fm-claude-hook.ps1 -Event <event> [-Check <check>]` | the tracked `.claude/settings.json` entries |

Public functions: `Invoke-FmSessionStart`, `Invoke-FmBootstrap`,
`Install-FmTool`, `Get-FmProjectMode`, `Invoke-FmClaudeHook`,
`Get-FmClaudeHookSettings`.

## The digest is unchanged

Nine stages, in this order, with the same section rules, headings, and wording as
the bash digest, because the captain reads it and `AGENTS.md` section 3 describes
it:

```
lock  bootstrap  wake-queue  supervision-instructions  read-once
fleet-state  network-checks  context  next-step
```

The reasons behind that order are the bash header's and still hold: lock before
any mutating step; fleet state before curated context so a truncated tail takes
the cheapest thing to lose; the read-once contract ahead of both digests it
governs.

`tests/FmSessionStart.Tests.ps1` pins the order and the section text. The compact
backlog rendering and every crew-dispatch reason string were diffed against the
bash originals on the same fixture home and are byte-identical.

## Composition seam: what this area expects from the others

The digest owns sequencing and formatting only. Everything else is resolved by
name at call time through `Resolve-FmSessionCommand`, so this area loads and runs
before the other areas exist. **A missing owner is reported in the digest as a
step that did NOT run - never as one that passed**, and the lock specifically
fails closed to a read-only session.

**Which of these have owners is no longer a matter of reading this table.**
`tests/FmModuleAssembly.Tests.ps1` derives every by-name target in the module
from the source and fails on any one that is neither defined nor listed in its
registry of deliberate absences, each with a written reason. This table records
the SHAPE each caller expects; that test records what actually exists.

| Expected function | Replaces | Consumed by |
| --- | --- | --- |
| `Invoke-FmLock` (LANDED - `Public/Invoke-FmLock.ps1`, `bin/fm-lock.ps1`) | `bin/fm-lock.sh` | digest stage 1, Stop auto-arm recovery |
| `Start-FmStartupNetwork -Locked -HarvestPid` | `fm-startup-network.sh start` | digest stage 1 |
| `Invoke-FmStartupNetworkHarvest -HarvestPid` | `fm-startup-network.sh harvest` | digest stage 7 |
| `Invoke-FmWakeDrain` | `bin/fm-wake-drain.sh` | digest stage 3 |
| `Invoke-FmGuard` | `bin/fm-guard.sh` | digest stage 3, read-only path |
| `Get-FmSupervisionInstructions -Harness -ReadOnly -Afk -XMode` (LANDED - `Public/FmSupervision.ps1`; ALSO takes one positional options hashtable, which is the guard seam's shape) | `fm-supervision-instructions.sh` | digest stage 4, every guard repair line |
| `Get-FmSupervisionRepairLine -Afk -XMode` | `fm-supervision-instructions.sh --repair-line` | turn-end guard banner |
| `Get-FmHarness` (LANDED - `Public/Get-FmHarness.ps1`) | `bin/fm-harness.sh` (own-harness detection only; the crew and secondmate resolutions are `Get-FmConfiguredHarness`'s) | digest stages 4 and 9, every spawn |
| `Get-FmBackendName`, `Get-FmBackendRequiredTool -Backend`, `Get-FmBackendKnown`, `Test-FmBackendRequiredToolAvailable` | `bin/fm-backend.sh` | bootstrap tool detection |
| `Get-FmMetaBackend -Path`, `Get-FmMetaTarget -Path` (backend area, landed) | `bin/fm-backend.sh` | digest stage 6 endpoint liveness |
| `Test-FmHerdrTargetExists -Target` (backend area, landed), or a generic `Test-FmBackendTargetExists -Backend -Target -Name` if one is ever published | `fm_backend_target_exists` | digest stage 6 endpoint liveness |
| `Get-FmMetaValue -Path -Key` (landed), `Write-FmTextFileLf -Path -Text` (landed) | `fm_meta_get`, LF-only writes | digest stage 6, every contract-file write |
| `Test-FmWatcherHealthy -State -Grace` | `fm_watcher_healthy` | turn-end guard, Stop auto-arm |
| `Get-FmSupervisionStatus -State -Grace` | `fm_supervision_status` | turn-end guard, Stop auto-arm |
| `Invoke-FmWatchArm` | `bin/fm-watch-arm.sh` | Stop auto-arm |
| `Test-FmSessionLockOwnedBySelf -State`, `Test-FmHarnessPidAlive -ProcessId` (both LANDED) | `fm-session-lock-lib.sh` | Stop auto-arm, SessionStart routing |
| `Invoke-FmSessionStartNudge` (LANDED - `Public/Invoke-FmSessionStart.ps1`) | `bin/fm-sessionstart-nudge.sh` | SessionStart resume/reload/fork |
| `Test-FmGateAgent -Root` | `fm_is_gate_agent` | SessionStart eligibility |
| `Test-FmArmCommandPolicy -Command`, `Test-FmCdCommandPolicy -Command` (cd-guard area, LANDED - `-Root` is defaulted), `Test-FmSubagentPolicy -Payload` | the PreToolUse policy owners | PreToolUse hook |
| `Invoke-FmPrCheckMigrate`, `Invoke-FmSecondmateLivenessSweep`, `Invoke-FmSecondmateSync`, `Invoke-FmSecondmateHandoffResume`, `Set-FmXModeArtifact`, `Invoke-FmFleetSync` (delivery area, landed - callable with no arguments), `Invoke-FmHerdrSessionCleanup` | bootstrap's six mutating sweeps plus Herdr cleanup | `Invoke-FmBootstrap` |
| `Test-FmTasksAxiCompatible`, `Test-FmQuotaAxiCompatible`, `Test-FmBacklogBackendManual -ConfigDir` | the axi compatibility probes | bootstrap, backlog listing |
| `Set-FmStartupMemoryBudget -ConfigDir`, `Set-FmTraceContextSessionStart`, `Get-FmPublicFollowupPending`, `Get-FmPrimaryTangleBranch -Root`, `Get-FmDefaultBranch -Root` | their bash libraries | bootstrap, digest |

Three shapes matter:

- **`Invoke-FmLock`** may report refusal by throwing, by writing an error
  record, or by returning an object carrying `Acquired = $false`. All are
  honoured, and so is not existing at all. Every one lands on a read-only
  session, because a session that cannot verify lock ownership must not mutate
  shared fleet state. What it returns is printed verbatim under the `LOCK`
  subsection, which is why the landed owner emits TEXT unless asked for
  `-PassThru`: an object emitted by default would reach the captain as a
  stringified hashtable.
- **`Get-FmSupervisionInstructions`** has two callers with two shapes - the
  digest's named parameters and the guard seam's ONE positional hashtable
  (`Invoke-FmSeam` splats an argument array and cannot bind a named one).
  Declaring only the named form would not fail loudly: the seam call would throw,
  the guard's catch would read that as "no owner", and every banner would keep
  its generic fallback sentence for ever.
- **The three PreToolUse policy predicates** return an object (or hashtable) with
  `Deny`, `Code`, and `Reason`. An invalid verdict fails open, because only the
  policy owner may decide deny.

If an owner lands under a different name, change the name in the one
`Resolve-FmSessionCommand` call that asks for it. The fallbacks are deliberately
minimal and are documented at their call sites.

## What the port changes, and why

**The runtime bound uses a child `pwsh` process, not a re-exec.** Windows has no
`fork`, and a thread-based job cannot be reliably aborted when it blocks. So the
parent starts `bin/fm-session-start.ps1` as a real child process with
`FM_SESSION_START_STAGE_FILE` set - the same flag the bash version uses to tell a
child it is the child, so the parent never recurses - and kills the process tree
when `FM_SESSION_START_TIMEOUT` (default 120s) expires. The child writes to
`FM_SESSION_START_OUTPUT_FILE` and the parent streams that file line by line, so
everything emitted before the bound is delivered and the STARTUP TRUNCATED banner
still names the exact stage that did not finish.

**No jq, no awk, no sed, no grep.** `config/crew-dispatch.json` validation is
native `ConvertFrom-Json`, and the compact backlog renderer is native regex. Both
produce the bash reason strings byte-for-byte, which is what the
`bootstrap-diagnostics` skill matches on.

**Install commands are platform-aware.** The line *shape* is the contract
(`MISSING: <tool> (install: <cmd>)`), but the command inside it has to run on the
host being diagnosed, and `brew install tmux` is not a runnable instruction on
Windows. On Windows the port emits winget/npm equivalents; on Linux it keeps the
bash strings verbatim. `tmux` has no native Windows build at all, so a Windows
home reports it as `MISSING_MANUAL` - selecting a backend that exists on Windows
is a human decision, not an install.

**Every contract file is written LF-only with no BOM**, through
`Write-FmSessionTextFile`. No caller in this area may use `Set-Content` or
`Out-File` for a state or config file. This is what keeps
`state/.session-start-complete`, `config/startup-memory-budget`,
`state/.claude-autoarm-epoch`, and `state/.turnend-claude-blocks` byte-identical
to what a Linux firstmate writes.

**Reads tolerate CRLF.** `Get-FmSessionFileLines` normalizes line endings on
read, so a file an operator edited with a Windows editor still parses.

**Dot-prefixed files are hidden on Unix**, so every `Get-Item` on a state record
passes `-Force`. This bit in practice and is covered by tests.

## The stages that write through the console, not the pipeline

Two owners this digest composes are entry-point shaped: their report goes to the
console and their return value is an exit code. Calling them like an ordinary
step got both halves wrong - the report bypassed the digest completely (in the
bounded child it went straight past the output file the parent streams, so it
landed in the terminal out of order or not at all) and the exit code was
stringified into the digest as a bare `0` where the queue should have been.

`Invoke-FmSessionConsoleStep` runs those two - the wake drain and the read-only
guard - with the console redirected into memory, reports what they wrote, and
drops the exit code. The wake queue is the turn's FIRST work queue, so losing it
is not a cosmetic defect.

## Bootstrap: detect, ask, then install

`Invoke-FmBootstrap` never installs anything. `Install-FmTool` refuses without
`-Approved`, and prints the plan it *would* run instead, so the caller can show
it and ask. That is `AGENTS.md` section 3's rule made mechanical rather than
advisory.

## Backend resolution in a partial build

`Get-FmBackendName` is the backend area's. Until it lands, the fallback is
`FM_BACKEND`, then `config/backend`, then `tmux`. Runtime auto-detection - the
backend firstmate itself is executing inside - is deliberately not guessed at
here; it belongs to the backend area and reaching for it from bootstrap would put
two owners on one decision.
