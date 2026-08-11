# The Herdr backend on native Windows PowerShell

`module/Firstmate/Private/FmBackendHerdr.ps1` is the PowerShell 7 port of
`bin/backends/herdr.sh` (3,297 lines) from the bash firstmate. This note records
what was ported, what was deliberately left out, what changed for the better,
and what cannot be proven from a Linux development box.

Herdr is a **session provider only**. The worktree provider stays treehouse -
see [worktree-isolation-windows.md](worktree-isolation-windows.md).

## Two dependencies became one

The bash adapter requires `herdr` **and `jq`**: every response is parsed by
shelling out to `jq` with expressions like `.result.pane.pane_id // empty`. On
this port there is no jq. Herdr's JSON is parsed with `ConvertFrom-Json`, and
`Get-FmJsonValue` provides the same "missing path yields nothing" semantics
safely under `Set-StrictMode -Version Latest`, where a plain missing-property
access would throw.

One consequence is worth stating because it bit during development: a
`ConvertFrom-Json` array returned from a function is **unrolled** by PowerShell,
so an *empty* array would come back as `$null` and read as "the response was
unparseable" rather than "this workspace has no tabs". `Get-FmJsonValue` returns
arrays wrapped (`, $node`) so the two stay distinguishable - the same
distinction jq's `(.result.tabs | type) == "array"` draws.

There is no shell anywhere either. Every CLI call goes through
`Invoke-FmChildProcess` (`System.Diagnostics.Process` with an argv array), so no
argument is ever re-parsed by a shell and a missing binary is a returned verdict
rather than an exception.

## What is ported

The core loop this area owns - create a pane, send text and keys, capture
output, read agent state, tear down:

| Concern | Functions |
| --- | --- |
| CLI plumbing | `Invoke-FmHerdrCli`, `Invoke-FmHerdrCliJson`, `Assert-FmHerdrTool`, `Assert-FmHerdrVersion`, `Get-FmHerdrSession` |
| Container | `Start-FmHerdrServer`, `Get-FmHerdrWorkspaceLabel`, `Get-FmHerdrWorkspaceIdAll`, `Get-FmHerdrLauncherIdentity`, `Resolve-FmHerdrWorkspace`, `New-FmHerdrContainer` |
| Task creation | `New-FmHerdrTask`, `Remove-FmHerdrSeededDefaultTab`, `Get-FmHerdrPaneForTab` |
| Addressing | `Split-FmHerdrTarget`, `Test-FmHerdrTargetReady`, `Test-FmHerdrTargetExists`, `Get-FmHerdrCurrentPath` |
| Send | `Send-FmHerdrTextLine`, `Send-FmHerdrLiteral`, `Send-FmHerdrKey`, `ConvertTo-FmHerdrKey`, `Send-FmHerdrTextSubmit` |
| Read | `Get-FmHerdrCapture`, `Get-FmHerdrAgentStatusRaw`, `Get-FmHerdrBusyState`, `Get-FmHerdrAgentState`, `Get-FmHerdrPaneAgentState`, `Get-FmHerdrPanePresenceState`, `Get-FmHerdrAgentIdentity` |
| Teardown | `Remove-FmHerdrPane`, `Test-FmHerdrEndpointGone` |
| Discovery | `Get-FmHerdrLiveTask` |

Every empirically-derived behaviour in the bash adapter's comments is carried
over, because each one is a scar:

- **Target shape.** `"<session>:<pane_id>"` splits on the **first** colon only;
  the pane id itself contains one (`default:w1:p2`).
- **The `--session` flag, not `HERDR_SESSION` alone.** The env var is not
  reliably honoured once another herdr server is bound on the machine - queries
  silently answer from whichever server *is* running. Both are always set.
- **`pane read --lines N` returns nothing** when N is below the pane's viewport
  height (~23 rows) instead of clamping. `Get-FmHerdrCapture` always fetches at
  least 200 rows and trims to the caller's bound itself.
- **`foreground_cwd`, never `cwd`.** A pane's `cwd` is frozen at creation time
  and does not follow a `cd` or a subshell.
- **Classify from the JSON body, never from exit status.** Herdr exits nonzero
  for ordinary business-logic answers like `pane_not_found`, which is a normal
  outcome, not a call failure.
- **Create before close, always.** Closing a workspace's last remaining tab
  deletes the whole workspace, so a husk is replaced by creating the
  replacement first.
- **The seeded default tab is pruned only by exact id.** The bash original
  carries a live-fire incident from 2026-07-02: a label-only heuristic closed a
  captain's own live pane 27ms after creating a task tab, because herdr enforces
  no label uniqueness and derives an unlabelled workspace's displayed label from
  its pane cwd's basename. Only a workspace the same call just created carries a
  seeded tab id at all; an adopted workspace's tabs are never even queried.
- **`blocked` means opposite things to two callers.** For the watcher a blocked
  agent is `idle` (it is waiting on a human and must be surfaced, not suppressed
  as busy); for submit confirmation it is `busy` (it took the input). Both
  mappings are kept, as `ConvertTo-FmHerdrBusyState` and
  `ConvertTo-FmHerdrSubmitState`.
- **Submit is confirmed from native agent state**, not from reading the
  composer's own row. That is what closed the bash side's 2026-07-07 redelivery
  loop, and it handles the earlier slash-popup incident with no popup-specific
  logic: filling a completion placeholder never starts a turn, so the retry loop
  simply sends another Enter. The text is typed once and only Enter is retried.

## What is deliberately NOT ported

Each of these is out of this brief's scope; none is an oversight.

**Presentation-space projection** (~1,400 lines): disposable per-task
workspaces, the version floor and its warning dedupe, the v1/v2 projection
journal, the focus-preserving close plan, `workspace.move`, the reclaim path,
and the per-session presentation lock. It is a non-authoritative *visual*
projection, gated on Herdr >= 0.8.0, whose entire purpose is keeping the
captain's spaces sidebar tidy. Without it, `Remove-FmHerdrPane` is the bash
adapter's own documented fallback: one explicit close proven by a structured
presence read.

**The `pane.agent_status_changed` push subscriber**
(`fm_backend_herdr_wait_transition` and friends). That is the watcher's event
fast path, and polling is the permanent fail-closed backstop on the bash side
too. It belongs with whoever ports the watcher.

**Composer shape classification.** `bin/fm-composer-lib.sh` is explicitly *the
one fleet-wide owner* of composer shapes, shared by every adapter, and its
header records the audit that made it so: five adapters each carried their own
copy, no adapter was right about more than five harnesses, and no two were wrong
in the same places. This port stays the thin consumer that design requires -
`Get-FmHerdrComposerState` captures a screen, describes its capabilities
(`styled`/`cursor`/`identity`/`rows`), and delegates to `Get-FmComposerState` if
a module provides it, otherwise returning `unknown`.

`unknown` is the fail-safe verdict, but it has one visible consequence today:
`Send-FmHerdrTextSubmit` confirms natively when the pre-Enter baseline is
legibly idle, and falls back to the classifier when it is not. **Steering an
already-busy agent will therefore report `unknown` - "delivery unconfirmed" -
until a composer classifier is loaded.** That is the correct direction (a steer
either lands or reports that it did not), and it is the first thing to fix when
the shared classifier lands.

**Other backends.** tmux, zellij, orca and cmux are not implemented. A task
recorded on one is *validated* (tmux) or *refused by name* (the rest) rather
than driven blind.

## Also carried in this file

Two smaller ports have no file of their own in the agreed module layout and live
in clearly delimited sections at the bottom of `FmBackendHerdr.ps1`:

- the backend-neutral **task metadata, selector and endpoint-validation** layer
  from `bin/fm-backend.sh` (`Get-FmMetaValue`, `Get-FmMetaExactValue`,
  `Test-FmTaskEndpoint`, `Resolve-FmTaskSelector`, and the LF file helpers), and
- the **control-plane capability tables** from `bin/fm-control-lib.sh`
  (`Get-FmControlHarnessFamily`, interrupt key/repeat/clear, exit command,
  backend key support, and the state-verified gate).

When the module layout gains `Private/FmBackend.ps1` and
`Private/FmControl.ps1`, move those two sections there verbatim.

`Test-FmTaskEndpoint` is worth calling out: it binds task id, backend, target,
project and worktree together **from durable metadata alone**, before any
runtime command runs, so a lifecycle command can never be delivered to an
endpoint belonging to a different task. Its refusals all end "preserving task
state", which is the point - a refusal never erases anything.

## The LF byte contract

`state/<id>.meta` and `state/<id>.status` are shared file formats: a Linux
firstmate and this one must read each other's files. Windows PowerShell writes
CRLF by default and historically wrote a BOM, either of which would break that.
Every durable record goes through `Write-FmTextFileLf` / `Add-FmTextLineLf`,
which write UTF-8 without BOM and LF only, and a test asserts the bytes.

## Windows-unverified

Everything that talks to a live herdr server. Herdr ships a Windows preview and
this repo measured its core loop passing on a Windows runner, but *this port's*
calls have never run against a Windows herdr server. All 153 tests drive the
adapter through mocked CLI responses; no test starts, stops, or otherwise drives
a real herdr server, which is also a hard safety requirement of the task that
produced this code.

Specifically unmeasured on Windows:

1. Whether the `--session` routing behaviour, the `pane read --lines` viewport
   quirk, and the `foreground_cwd` semantics hold identically on the Windows
   preview build. All three are Linux/macOS observations.
2. `Start-FmHerdrServer` launches a detached `herdr server`. On Windows there is
   no `fork`; the port uses `System.Diagnostics.Process` with
   `UseShellExecute = $false` and redirected streams, which does not tie the
   server's lifetime to the caller - but this has not been confirmed against a
   real Windows herdr server, including whether the server survives the parent
   PowerShell session exiting.
3. Pane ids, tab labels and workspace labels are compared **case-sensitively**
   (`-ceq`), matching herdr's own semantics. If the Windows build ever folds
   case in labels, `New-FmHerdrTask`'s duplicate detection would need revisiting.
