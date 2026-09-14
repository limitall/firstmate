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
| `Add-FmTaskStatus -StateDir -TaskId -State -Note [-Key] [-SelfAnnounced]` | `echo "<verb>: <note>" >> state/<id>.status` | every status writer, incl. `Add-FmStatusEvent` |

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

### Attribution and feedback drafts off

Every claude launch also carries `--settings <module>/claude-worker-settings.json`, which turns attribution off (`commit` and `pr` empty, `sessionUrl` false) and sets `feedbackDrafts` to `off`.
`CLAUDE_CODE_SEND_FEEDBACK=0` rides beside it as a second feedback control; each alone removes the drafting tool, and upstream notes a managed settings policy can turn the setting back on but cannot reach the variable.
Without them a worker added `Co-Authored-By: Claude ...` to the captain's commits against a standing rule, and could draft a bug report on their behalf.
Flag settings sit above the user, project and local scopes, so the policy holds whichever of those a worker loads, and the captain's own settings are never written.

**Why a file, when upstream passes the JSON inline (#3945, #3661).**
The pane command cannot carry a double quote: the pane shell is Windows PowerShell 5.1, `ConvertTo-FmPaneCommand` refuses the character rather than type a command that arrives mangled, and the JSON is all quotes.
Composing the JSON inside the pane instead would dodge that refusal and still leave the string to pwsh's native argument quoting on its way to `claude.exe`.
A path contains no double quote (Windows forbids one), so it crosses both shells as the same single-quoted literal every other launch value already uses, and the policy is a tracked file anyone can read.
A missing file refuses the launch before an endpoint exists.

`docs/windows-e2e-evidence.md` section 60 measures each control on and off in a real herdr pane on Claude Code 2.1.270.

## Claude workspace trust

Claude holds a project it has never seen behind a trust dialog that `--dangerously-skip-permissions` does not cover, and the dialog opens on `No, exit` - measured on this machine, section 60.
Firstmate cannot answer it, so the first worker on a new project would sit there before reading its brief.
`Start-FmWorker` therefore calls `Register-FmClaudeWorkspaceTrust` (`Private/FmClaudeTrust.ps1`) after the lease and before any endpoint exists, and a registration that fails refuses the spawn with the lease released.

What this port does differently from upstream's `bin/fm-claude-trust.sh` (#3663), and why - the file header owns the full reasoning:

- **One entry, the checkout's.**
  Claude keys a worktree session under the primary checkout, and a flag on either the checkout or the worktree lets a worker through.
  The checkout's is one entry per project, so once it is set no later spawn writes the live store at all; upstream writes both.
- **Trust only.**
  Upstream's external-imports consent handling (#3944) is not copied: every entry on this machine carries that flag at its default `false`, which upstream reads as a decline, so it would refuse every spawn.
- **No node.**
  The store is edited through System.Text.Json's node model, which reproduced this machine's live store byte for byte, and it is replaced only if the bytes read are still the bytes on disk.

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

- No longer unverified: the claude launch line.
  Section 60 typed it through `herdr pane run` seven times, with and without the settings flag; six started Claude Code 2.1.270 with the brief as its first prompt, and the seventh was the never-trusted control held at the trust dialog.
  The multi-kilobyte, quote-heavy brief of the task that measured it reached its own worker through the same line.
- That a Windows crew registers with herdr and fires its turn-end hook, which is
  what makes an adapter "verified"; this is why only claude is listed and why the
  list is data (`Get-FmHarnessAdapter`) rather than prose.
- The brief's `[IO.File]::AppendAllText` instruction has been proven to produce
  LF-only bytes by this port's own writers, not by a Windows worker following the
  instruction.
