# Task dispatch: brief, spawn, record

Windows/PowerShell port of the DECISION half of `bin/fm-spawn.sh`: what a task is
launched with, and what is recorded about it. The bash header remains the
authoritative statement of *why* each rule exists; this file records what the
port keeps, what it changes, and the seams other areas plug into.

**Neighbouring owners, bound by name rather than copied.** The brief itself is
the lifecycle area's (`Public/FmBrief.ps1`, `bin/fm-brief.ps1`, and its
byte-for-byte fixtures under `tests/fixtures/brief/`); this area only reads the
one machine-readable line the spawn must agree with. The status stream's parsers
and folds are `Public/FmClassify.ps1`. State-file bytes are the foundation's
(`Read-FmKeyValueFile` / `Write-FmKeyValueFile` / `Add-FmStateLine`). See
`docs/lifecycle.md` and `docs/foundation.md`.

## Commands

| Command | Bash original |
| --- | --- |
| `bin/fm-spawn.ps1 <task-id> <project> -Mode <mode> -Yolo <on\|off>` | `bin/fm-spawn.sh <id> <project> --mode --yolo` |
| `bin/fm-spawn.ps1 <task-id> <project> -Kind scout [-Harness <name>]` | `fm-spawn.sh <id> <project> --scout` |

Public functions this area publishes - the names other areas bind to at call
time:

| Function | Replaces | Consumed by |
| --- | --- | --- |
| `Get-FmHarnessLaunchCommand -Harness -BriefPath [-Model] [-Effort] [-Kind]` | `launch_template`, `model_flag_for_harness`, `effort_flag_for_harness` | `Start-FmWorker` |
| `Get-FmTaskRecord -Path`, `Write-FmTaskRecord -Path -Fields` | `state/<id>.meta` reads/writes | spawn, control plane, teardown, digest |
| `Add-FmTaskStatus -StateDir -TaskId -State -Note [-Key]` | `echo "<verb>: <note>" >> state/<id>.status` | every status writer, incl. `Add-FmStatusEvent` |

`Start-FmWorker` (backend area) calls `Resolve-FmSpawnPlan` before it touches the
fleet; that is the one seam between the dispatch decisions and the endpoint
mechanics.

## What the spawn needs from the brief

One line: `Delivery contract: mode=<mode>`, which the lifecycle area's scaffolder
writes into every ship brief. `Get-FmBriefDeliveryMode` reads it and
`Assert-FmBriefDeliveryAgreement` refuses a spawn that contradicts it, so an
adjusted brief and the recorded task delivery cannot drift apart. A brief with no
such line warns once and launches on the flag - the shape bash uses for briefs
scaffolded before the line existed.

Everything else about the brief - the worktree-isolation assertion every ship
brief must carry, the `{TASK}` placeholder contract, the `--herdr-lab` gate, and
the refusal of a yolo input - belongs to `Public/FmBrief.ps1`, whose generated
bytes are diffed against the bash scaffolder's own output.

## The spawn refuses rather than guesses

`Resolve-FmSpawnPlan` runs before a worktree is leased or an endpoint exists, so
every refusal below leaves nothing behind:

- **Delivery contract.** A ship spawn requires `-Mode` and `-Yolo`; both are
  closed-set validated; `no-mistakes-prod-only` is refused as the registry policy
  it is; a scout or secondmate carrying either is refused. The project registry
  is consulted only to *notice* a deviation (`Write-FmDeliveryPostureNotice` via
  `Get-FmProjectMode`), never to supply the answer.
- **Brief agreement.** A mismatch between the brief's recorded mode and the flag
  is a refusal; a brief with no contract line warns once and launches on the flag.
- **Harness.** An explicit name wins; otherwise the harness is resolved from
  config on every spawn (`config/secondmate-harness` → `config/crew-harness` →
  own for a secondmate, `config/crew-harness` for a crewmate), which is what
  makes the secondmate/crewmate split durable across respawns. When
  `config/crew-dispatch.json` exists, a crewmate/scout spawn must name its
  harness - the consultation backstop.
- **Verified adapters only.** `claude` is the one adapter with Windows evidence
  (`data/fmwin-design/report.md` §2, §6.2: "v1: Claude crews only"). The other
  seven are known but unverified, and naming one is refused rather than launched
  with a POSIX-shaped command line into a PowerShell pane. `-LaunchCommand` is
  the deliberate escape hatch and still records the derived harness name.
- **Missing dependency.** The adapter's executable must resolve on PATH before an
  endpoint exists, because a pane opened onto a shell error looks to supervision
  like a wedged worker rather than a missing install.
- **Profile axes.** `-Model`/`-Effort` reach the launch only where the axis is
  verified for that adapter and the value is in its vocabulary; an unsupported
  axis is omitted from the launch and still recorded in the task's metadata.

### How the brief reaches the agent

The bash template has the pane run
`$(fm-operational-input.sh encode launch-brief < brief)`, so the brief is never
typed through the terminal. The port keeps that shape: the launch command carries
a PowerShell sub-expression that reads the brief file and prepends the
operational-input header, whose U+2063 prefix is permanent compatibility
(`ConvertTo-FmOperationalInput`). Only the expression is typed.

`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` rides every claude launch. On Linux
that is defence in depth behind a dim-aware composer reader; on Windows herdr's
capture is MEASURED to arrive with SGR stripped, so nothing downstream can tell
ghost text from real input and this env var is load-bearing.

## The task record

`ConvertTo-FmTaskRecordField` owns the field set and ORDER, byte for byte from
`bin/fm-spawn.sh`; the foundation owns the bytes
(`Write-FmKeyValueFile` publishes atomically and LF-only,
`Read-FmKeyValueFile` splits on the first `=` and keeps a duplicated key's last
value at its first position):

```
window endpoint_task_id worktree project harness kind [mode] [yolo] tasktmp
model effort [busy_gen] [backend] [herdr_session herdr_workspace_id
herdr_tab_id herdr_pane_id] [home projects] [treehouse_lease_id]
```

`mode`/`yolo` only on a ship, `home`/`projects` only on a secondmate, and
`backend=` only for a non-default backend - **absent `backend=` means tmux**, the
bash compatibility contract, whose owner is `Get-FmMetaBackend`.
`treehouse_lease_id` is this port's own field (the durable lease identity that
replaced scraping a pane's cwd) and is written last, so a reader that does not
know it never reaches it. `busy_gen` and `traceparent` are accepted and read back
but written by their own areas, which are not ported yet.

## Writing one status event

`Add-FmTaskStatus` is this area's one writer: it forms the line in the grammar
`Public/FmClassify.ps1` reads, refuses a key that fold could not parse (a
malformed key makes the fold drop the whole line, so a bad key would look like a
report that silently never landed), and flattens a note so one append is exactly
one event. `Add-FmStatusEvent` (backend area) delegates to it.

The append itself is `Add-FmStateLine`. That is not a style preference: .NET's
`FileMode.Append` writes at the offset it recorded when the handle opened, so
concurrent appends overwrite each other where bash's `>>` does not - the
foundation measured a fifth of a status log disappearing before its lock existed.

The keyed open/resolved semantics, including the divergence this port makes from
the bash key parser, are documented with their owner in `docs/lifecycle.md`.

## The endpoint-side confirmation, and the Windows degradation

After the pane exists, `Confirm-FmWorkerWorktree` takes an independent second
reading of where the endpoint is. A pane's live `foreground_cwd` is MEASURED to
come back EMPTY on the Windows herdr preview
(`data/fmwin-design/report.md` §3.2), and an empty reading is *no information*,
not evidence the pane is elsewhere - so treating it as a refusal would stop every
Windows spawn while adding nothing, given the copy was already proven isolated
and the pane was created IN it rather than told to walk into it.

The degradation is therefore chosen per outcome:

| Reading | Verdict |
| --- | --- |
| live path == leased worktree | confirmed |
| live path names anywhere else | **refuse**, immediately - more polling cannot make it acceptable |
| no live path, creation path == leased worktree | confirmed, with a loud "the live-cwd confirmation did NOT run" |
| no live path, creation path names anywhere else | **refuse** |
| neither field readable | the check did NOT run: say so, return `$false`, and let the lease, the isolation assertion, and the brief's own worker-side assertion carry it |

The creation-path fallback is a real second reading rather than a shrug: herdr
freezes a pane's `cwd` at creation, so it still answers "was this pane created
where we asked" even where the live field is dead
(`Get-FmHerdrPaneCreationPath`).

## Proving the isolation refusal

`tests/FmDispatch.Tests.ps1` builds a real git repository, then hands the spawn a
"leased" worktree that IS that primary checkout. Everything else on the path is
real - the assertion runs `git rev-parse --show-toplevel` against the repository
and compares physically resolved paths. The spawn refuses, and the test asserts
what did NOT happen: no herdr container, no pane, no launch delivered, no task
record on disk, and the lease released conditionally on its own id. A
subdirectory of the primary checkout is refused too (it is not a worktree root),
and a genuine second `git worktree` of the same repository passes.

`bin/fm-brief.ps1` and `bin/fm-spawn.ps1` are also run as real child processes:
usage exits 2, a refusal exits 1 with a bare message on stderr (no PowerShell
error record), and a brief scaffolded as `local-only` refuses a `direct-PR`
spawn end to end.

## Not ported here

Relaunch, batch `id=repo` dispatch, remote secondmates, trace-context carriers,
busy generations, the herdr presentation projection, per-task lock files, and the
per-harness turn-end hook writing. Each is another area's; the record writer
accepts their fields so a record this port writes stays the same shape as a Linux
one's.

## WINDOWS-UNVERIFIED

- The claude launch line itself: that `claude --dangerously-skip-permissions`
  plus a PowerShell sub-expression argument reaches the agent intact through
  `herdr pane run` on Windows. The quoting is native PowerShell and the brief is
  read by the pane rather than typed, which is the design that minimises this
  risk, but it has not been observed on Windows.
- That a Windows crew registers with herdr and fires its turn-end hook, which is
  what makes an adapter "verified"; this is why only claude is listed and why the
  list is data (`Get-FmHarnessAdapter`) rather than prose.
- The brief's `[IO.File]::AppendAllText` instruction has been proven to produce
  LF-only bytes by this port's own writers, not by a Windows worker following the
  instruction.
