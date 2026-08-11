# The Claude Code hook surface on Windows

Windows/PowerShell port of the tracked Claude hook entrypoints:
`bin/fm-sessionstart-run.sh`, the three PreToolUse checks,
`bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh`.

`docs/turnend-guard.md` in the reference implementation remains the authoritative
contract for the turn-end guard and the Stop-owned auto-arm. This file records
only what the Windows port assumes, what it proves, and what it cannot.

## WINDOWS-UNVERIFIED: the boundary

Claude Code documents a PowerShell-native hook mode on Windows, with a per-hook
`"shell": "powershell"` field. **Everything on the far side of that documentation
is unverified from this port**, because the port was written on Linux where the
host does not exist. Specifically, none of these has been observed:

- that Claude Code on Windows runs a `"shell": "powershell"` hook at all, or
  applies the command-string quoting `Get-FmClaudeHookSettings` emits;
- that it delivers the JSON payload on stdin to such a hook;
- that it honours exit 2 plus stderr as a block-with-feedback for `Stop`, and as
  a deny for `PreToolUse` with stdout required to stay empty;
- that a `Stop` hook with `"asyncRewake": true` fires in the background on every
  Stop, honours the 28800-second timeout, and turns its exit 2 into a rewake of
  an idle session;
- that `SessionStart` hook stdout is injected into model context;
- that `CLAUDE_PROJECT_DIR` is set for a PowerShell-native hook.

Every function implementing one of those behaviours carries its own
`# WINDOWS-UNVERIFIED:` marker naming what specifically is unproven. Confirming
them needs one session on a real Windows host; until then, treat the hook
registration as a design, not a validated integration.

## What IS proven on this host

Everything on the near side of that boundary, by `tests/FmHooks.Tests.ps1`
(54 tests, run on Linux with PowerShell 7.6 and Pester 6.1):

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
  `state/.turnend-claude-blocks`.

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
  decide deny;
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
