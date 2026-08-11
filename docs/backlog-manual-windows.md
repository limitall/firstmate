# The manual backlog backend on Windows

Windows/PowerShell port of firstmate's documented hand-edited backlog path -
`config/backlog-backend manual` - plus the backend-selection probe from
`bin/fm-tasks-axi-lib.sh`. The format owner is elsewhere and stays elsewhere:
this is the same file format, written by a different hand.

## Commands

| Command | Bash / tool original |
| --- | --- |
| `bin/fm-backlog.ps1 list\|ready\|held\|blocked\|show` | `tasks-axi list\|ready\|show` |
| `bin/fm-backlog.ps1 add\|start\|done\|reopen` | `tasks-axi add\|start\|done\|reopen` |
| `bin/fm-backlog.ps1 block\|unblock\|hold\|unhold` | `tasks-axi block\|unblock\|hold\|unhold` |
| `bin/fm-backlog.ps1 prune` | `tasks-axi prune`, and the `done --keep` retention |
| `bin/fm-backlog.ps1 backend` | `fm_backlog_backend_value` + `fm_tasks_axi_backend_available` |

Public functions: `Get-FmBacklog`, `Get-FmBacklogTask`, `Get-FmBacklogReady`,
`Get-FmBacklogHeld`, `Get-FmBacklogBlocked`, `Add-FmBacklogTask`,
`Start-FmBacklogTask`, `Reset-FmBacklogTask`, `Complete-FmBacklogTask`,
`Block-FmBacklogTask`, `Unblock-FmBacklogTask`, `Set-FmBacklogHold`,
`Clear-FmBacklogHold`.

Exit codes are the repo's: 0 success, 1 refusal or failure, 2 usage. Refusals go
to stderr as a plain line.

## Why this is a real backend, not a stub

`docs/configuration.md` in the reference implementation states it plainly: "the
file format is unchanged in both modes; tasks-axi and manual edits produce the
same `## In flight`, `## Queued`, and `## Done` sections". The manual path is not
a degraded format - it is the same format, hand-edited. The design report's port
map (§2) lists `tasks-axi`'s platform support as unknown and settles v1 on
`config/backlog-backend manual`, so this port implements that path completely:
read, write, add, start, done, reopen, block/unblock, hold/unhold, ready, and the
configured recent-Done retention with its archive.

The selection precedence is unchanged from bash, and `bin/fm-session-start.ps1`
already consumes it: `manual` opts out of tasks-axi outright; otherwise a
compatible `tasks-axi` is preferred and the manual path is the fallback.

## The format owner is tasks-axi

`tasks-axi` 0.2.5's markdown backend (`dist/src/backends/markdown-grammar.js` and
`markdown.js`) is the specification this port was written against, function by
function:

- the three bullet shapes (`- [ ] <id> - `, `- [x] <id> - `, and the legacy
  `- **<id>** - ` that is still parsed but never re-emitted),
- the trailing tag region - `blocked-by:`/`parent:`/`discovered-from:`,
  `(repo: …)`, `(kind: …)`, `(priority: 0-4)`, `(since YYYY-MM-DD)`,
  `(merged|reported|done|closed YYYY-MM-DD)`, `(hold: …)`, `(hold-kind: …)`,
  `(hold-until: …)` - stripped only from the END of the line, so a mid-sentence
  parenthetical stays in the prose,
- link derivation from the prose (PR, report, doc) and the closure verb that
  follows it,
- the canonical tag order, with a reason-carrying dependency edge emitted last
  because it runs to the end of the line,
- two-space body continuation with blank paragraph separators preserved,
- the advisory `<path>.lock` protocol and temp-file-then-replace writes.

**Byte-exact round trip.** Parsing keeps each entry's original lines; rendering
re-emits them verbatim unless that entry was mutated. Editing one queued item
cannot reflow another item's prose, reorder its tags, or drop a hand-written
note. `tests/FmBacklog.Tests.ps1` pins this, and - when a compatible `tasks-axi`
is on PATH - runs the same mutation sequence through both implementations and
compares the resulting backlog and archive byte for byte.

## Does tasks-axi run on Windows?

Not measured here, and this port does not depend on the answer. What can be said
with evidence: the published package is pure JavaScript (`"type": "module"`,
`engines.node >= 20`, dependencies `@toon-format/toon` and `axi-sdk-js`, no
native addons, no postinstall script), and its markdown backend uses only
`node:fs` and `node:path` - no POSIX-only API, no shelling out. There is no
structural reason it would fail under `node.exe`. That is a portability argument,
not a measurement: nobody has run it on Windows, the port map lists its support
as unknown, and firstmate's own bootstrap treats an incompatible or absent
`tasks-axi` as a first-class case. The manual backend ships either way, and the
differential test above is what keeps the two honest when both are present.

## Refusals, and why each one exists

| Refusal | Why |
| --- | --- |
| duplicate id, unknown blocker, self-block | a dangling or circular edge silently changes what `ready` means |
| id outside `[A-Za-z0-9][A-Za-z0-9._-]*` | the grammar could not round-trip it |
| title ending in canonical tags | it would parse back as a tag and mutate on the next write |
| hold reason containing parentheses | parentheses are the hold tag's own delimiters |
| a PR link that is not `/pull/<n>`, a report link that is not `data/<id>/report.md` | the closure verb is derived from link kind |
| `Backlog changed on disk; retry the command` | another writer landed between read and write |
| `backlog is locked by another process` | the advisory lock is held; a stale lock is NAMED, never broken on a guess |
| every generic mutation on a public-followup obligation | those have their own delivery state machine and their own command family |

**Public-followup obligations** are read, round-tripped byte-exact, excluded from
`ready`, and never archived by retention while active - their `delivery.state` is
decoded only to answer "is this still active", and a payload that cannot be
decoded is treated as active. Everything else about them is refused rather than
approximated. A corrupted public obligation is a broken promise to someone
outside the fleet, so refusing is the safe direction.

## What the port changes, and why

**Locking.** The bash side never touches the backlog lock; `tasks-axi` owns it.
This port implements the same protocol, because both tools write the same file:
an exclusively-created `<path>.lock` holding a unique token, released only while
the file still holds THAT token, 2.5s acquisition budget, 25ms retry, and a stale
lock (30s+) named rather than broken. Corruption safety does not rest on the
lock: every write is a temp file replaced over the destination.

**Writes go through the foundation's state writer** (`Write-FmStateFile`), so the
backlog is published the way every other durable record is: a temp file flushed
to disk, moved over the destination, LF-only, no BOM, with the transient-IO retry
Windows needs when an indexer or scanner holds the file for a moment. It is
called with `-NoTrailingNewline` because the rendered document already carries
the file's own final-newline state; adding one would break the byte-exact round
trip for a backlog that legitimately ends without it.

**Dates are local**, not UTC - matching `today()` in the markdown backend, so a
Windows and a Linux home stamp the same day the captain is living in.

**No jq, no sed, no node** on the read path: the grammar is native .NET regex and
`ConvertFrom-Json` (used only to decode a public-followup payload).

**`.tasks.toml` is parsed by a deliberately tiny reader** - a top-level `backend`
key and a `[markdown]` table with `path`, `archive`, `done_keep` - the same
three-key surface `tasks-axi` itself reads, and for the same reason: a general
TOML parser would be a second thing to keep correct.

## What this area publishes for the others

`Test-FmBacklogBackendManual -ConfigDir` and `Test-FmTasksAxiCompatible` are
resolved by name from two already-merged areas: the session-start digest chooses
its backlog rendering with them, and `Test-FmTasksAxiBacklogBackend` in the
teardown area defers its version-floor probe to the second ("the full tasks-axi
version-floor probe lives in the backlog area"). Both keep the bash signatures,
and `Test-FmTasksAxiCompatible` honours a verdict handed in through
`FM_TASKS_AXI_COMPATIBLE` before consulting its own memo, so one session start
and its bootstrap child pay for the probe once.

## Where the retention rule lives

`done_keep` (default 10) comes from `.tasks.toml`; `Complete-FmBacklogTask`
applies it after closing an item unless `-NoPrune` is passed, and
`Invoke-FmBacklogPrune` can apply it on its own. The surplus is appended to the
archive (`data/done-archive.md` by default) under a `## Archived <date>` heading,
using each record's ORIGINAL lines, and the archive append is rolled back to its
previous length if the backlog rewrite then fails - so a failed prune never
leaves a record in two places or in none.
