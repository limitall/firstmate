# The Claude Code hook surface on Windows

Windows/PowerShell port of the tracked Claude hook entrypoints:
`bin/fm-sessionstart-run.sh`, the three PreToolUse checks,
`bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh`.

`docs/turnend-guard.md` in the reference implementation remains the authoritative
contract for the turn-end guard and the Stop-owned auto-arm. This file records
only what the Windows port assumes, what it proves, and what it cannot.

## How Claude Code actually invokes a PowerShell hook - MEASURED

Measured on the captain's Windows 11 laptop against **Claude Code 2.1.228**, by
registering an instrumented hook that recorded its own and its parent's command
line. A `"shell": "powershell"` hook runs as:

```
"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -NonInteractive
    -ExecutionPolicy Bypass -Command "<the command string from settings.json>"
```

with the JSON payload on the process's **stdin**, and with `CLAUDE_PROJECT_DIR`
set. Two consequences are load-bearing, and each one had already produced a
silent defect:

**1. The payload is raw console input, not pipeline input.** In that shape
PowerShell places nothing on the script's own pipeline (the instrumented hook
recorded zero pipeline objects), so the payload is reachable only through
`[Console]::In.ReadToEnd()`. But a PowerShell *caller* that pipes the payload -
`Get-Content p.json | fm-claude-hook.ps1 -Event ...`, or any host wrapping the
hook as `$input | & <script>` - delivers it as pipeline input instead, and
against an entry point with no pipeline-bound parameter that is a **parameter
binding failure**:

```
The input object cannot be bound to any parameters for the command either
because the command does not take pipeline input ...
```

Binding happens *before* the script body, so the entry point's own `try`/`catch`
cannot catch it: the hook exits non-zero having never run the guard. The entry
point therefore declares an `-InputObject` parameter that accepts anything, so no
input can fail to bind, and joins what arrives into the payload.

An earlier commit (`ed1fdab`) is titled "Fix the hook entry point never reading
its stdin payload". It fixed a real and *different* bug one layer in:
`Invoke-FmClaudeHook` decided whether to read stdin by testing `$Payload` for
`$null`, and an unbound `[string]` parameter arrives as the empty string, so the
read was skipped and every hook failed open. That fix is correct and still
stands - the raw-stdin transport is measured working above. What it could not
reach is the *entry point's parameter binding*, which fails before any of that
code runs. Both layers are now correct, and both have tests.

**2. `pwsh -Command '& <script>'` DOES NOT PROPAGATE THE SCRIPT'S EXIT CODE.**
A script that exits 2 makes `pwsh` itself exit **1**, because `-Command` derives
its status from `$?` rather than from the child script's code. Claude Code blocks
on exit 2 and treats every other non-zero code as an ignorable non-blocking
error, so with the bare `& <script>` form **every PreToolUse deny and every Stop
block was computed correctly and then discarded**. It took the `asyncRewake`
auto-arm with it: that hook signals "wake this idle session" with exit 2 as
well, so watcher continuity had no path back into the session either. Every registered command
therefore ends with `; exit $LASTEXITCODE`, which carries 2 through unchanged and
leaves 0 as 0. Both directions are asserted by `tests/FmHooks.Tests.ps1`, which
drives the entry point through Claude Code's exact invocation shape.

## WINDOWS-UNVERIFIED: what is still on the far side

These remain documentation-only, and every function implementing one carries its
own `# WINDOWS-UNVERIFIED:` marker naming what specifically is unproven:

- that Claude Code honours exit 2 plus stderr as a block-with-feedback for
  `Stop`, and as a deny for `PreToolUse` with stdout required to stay empty;
- that a `Stop` hook with `"asyncRewake": true` fires in the background on every
  Stop, honours the 28800-second timeout, and turns its exit 2 into a rewake of
  an idle session;
- that `SessionStart` hook stdout is injected into model context.

## The captain's "every shell command is denied" was NOT this hook

Recorded here because the misdiagnosis cost a full investigation. The reported
symptom - a session in the checkout that could read and write files but could not
execute anything, reporting "both PowerShell and Bash denied" - is Claude Code's
own permission layer, not firstmate. The session transcript on the laptop
(`~/.claude/projects/C--Users-ADMIN-firstmate-win/`) records it verbatim:

```
Error: Permission to use Bash has been denied because Claude Code is running
in don't ask mode.
```

`C:\Users\ADMIN\.claude\settings.json` carries
`"permissions": { "defaultMode": "dontAsk" }`, which denies every tool call not
on the explicit allow-list without prompting. File reads and writes stay allowed,
which is exactly the observed split. All six firstmate hooks were measured
exiting 0 on that machine with realistic payloads. **No hook change can fix
that symptom**; it is a setting in the captain's own Claude configuration.

## What IS proven on this host

Everything on the near side of that boundary, by `tests/FmHooks.Tests.ps1`
(77 tests, run on Linux with PowerShell 7.6 and Pester 6.1):

- payload parsing, including `stopHookActive` taking precedence over
  `stop_hook_active` and a non-boolean value being treated as malformed;
- the primary-scope predicate: a genuinely marked secondmate home is included, an
  invalid marker is not, and a crewmate linked worktree stays inert;
- the supervision-need predicate, including the relay poll and process-event
  source cases that have no task metadata;
- SessionStart source routing, and the completion record that decides whether a
  clear or compact re-emits or runs a full startup;
- the whole turn-end block/allow state machine, and the auto-arm's epoch and
  failure-episode progression;
- the byte layout of `state/.claude-autoarm-epoch` and
  `state/.turnend-claude-blocks`;
- **the transport, through every shape**. Each event is driven end to end in a
  real child process with a real payload, through Claude Code's own
  `-Command "& <script> ...; exit $LASTEXITCODE"` invocation AND through the
  PowerShell-pipeline shape, and the `cd` guard is asserted both DENYING the
  command it exists to deny (exit 2, empty stdout, the deny object on stderr) and
  ALLOWING an ordinary one. Each of those has a negative control: reverting the
  entry point fails 7 of them, removing `; exit $LASTEXITCODE` fails the wiring
  test, and removing the policy owner fails both deny tests.

That is possible because the hook functions never write to the host. They return
a decision object - `ExitCode`, `Stdout`, `Stderr` - and `bin/fm-claude-hook.ps1`
is the single place that turns it into a process exit code and stream writes.

## Registration

`Get-FmClaudeHookSettings` emits the `.claude/settings.json` block:

```powershell
Get-FmClaudeHookSettings | Set-Content .claude/settings.json
```

It registers, all through `bin/fm-claude-hook.ps1`:

| Event | Matcher | Check | Notes |
| --- | --- | --- | --- |
| SessionStart | - | - | runs the digest, re-emits, or nudges by source |
| PreToolUse | `Bash` | `arm` | watcher-arm command policy |
| PreToolUse | `Bash` | `cd` | cd guard |
| PreToolUse | `.*` | `subagent` | subagent guard, every tool |
| Stop | - | `turnend-guard` | synchronous, blocks with exit 2 |
| Stop | - | `autoarm` | `asyncRewake: true`, `timeout: 28800` |

The bash entries carry a `GROK_AGENT`/`GROK_HOOK_EVENT` inert-guard prefix so a
Grok session that loads Claude-compatible settings cannot create a second
continuation path. That guard is **not** ported here: Grok is not among the
harnesses this Windows port targets, and re-adding it is a one-line prefix in
`Get-FmClaudeHookSettingsObject` if a Grok primary is ever run on Windows. This is
a deliberate omission, recorded so it is not mistaken for an oversight.

## Fail-open rules, and the one place they change

The bash guard fails open when it cannot read its own inputs (`jq` missing, empty
stdin). This port applies the same rule to a wider class, because a module can be
loaded in pieces:

- an unreadable or malformed payload allows;
- **a missing `Test-FmWatcherHealthy` owner allows**. The guard cannot evaluate
  its own predicate, and blocking every turn end on that basis would wedge the
  session outright. This is the module-partial-build analogue of missing `jq`;
- a missing PreToolUse policy owner allows, because only the policy owner may
  decide deny. The `cd` owner now exists (`Test-FmCdCommandPolicy`, see
  `docs/cd-guard-windows.md`); `arm` and `subagent` are still unported, so those
  two hooks are deliberately inert rather than accidentally so;
- a missing `Invoke-FmWatchArm` leaves the Stop auto-arm silent and inert;
- any unexpected exception in `bin/fm-claude-hook.ps1` exits 0 with a diagnostic
  on stderr. A hook that crashes must never take a session with it.

Note the asymmetry with the session-start digest, which fails *closed* to a
read-only session when `Invoke-FmLock` is missing. A hook that cannot evaluate
its predicate must not block; a session that cannot verify lock ownership must
not mutate. Both are the conservative direction for their own failure.

## Locks: a deliberate Windows-native divergence

The bash locks are a symlink pointing at a freshly created owner directory,
because that is how they get an atomic claim on a POSIX filesystem. Creating a
symlink on Windows needs Developer Mode or an elevated process, so a
symlink-based lock would simply fail for most users.

This port claims a lock by creating the directory *exclusively* - `New-Item
-ItemType Directory` without `-Force`, which fails when it already exists, and is
atomic on NTFS. The readable layout is the same: `<lock>/pid` and `<lock>/role`.

Locks are volatile runtime state, never read across machines, so this does not
touch the cross-platform file contracts. The two coordination locks are always
acquired owner-lock-then-budget-lock, in that order, everywhere.

## Files this area owns

`state/.claude-autoarm.lock`, `state/.claude-autoarm-epoch`,
`state/.claude-autoarm-failure-notified`,
`state/.claude-autoarm-failure-alarmed`, `state/.turnend-claude-blocks`, and
`state/.turnend-claude-blocks.lock` - the same set `AGENTS.md` section 2 lists as
"never touch". The two record files keep the bash byte layout exactly:

```
.claude-autoarm-epoch    epoch=<n> owner_pid=<pid> outcome=<word> updated_at=<unix>\n
.turnend-claude-blocks   session=<id>\ncount=<n>\nepoch=<n>\n
```
