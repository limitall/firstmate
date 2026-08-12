---
name: harness-adapters
description: Agent-only reference for firstmate harness operations on this Windows port. Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, or resuming an exited agent. Contains the verified facts for claude, which is the only adapter this port may dispatch, and states why every other adapter is refused here.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

Use this reference before any harness-specific firstmate operation: spawn, recovery, trust-dialog handling, skill invocation, interrupt, exit, or resume.

## The one verified adapter

**`claude` is the only harness this port may dispatch, and `herdr` is the only session provider it may dispatch onto.**

That is not a default that can be argued past.
Every other adapter the Linux firstmate supports - `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`, `muse` - depends on hook mechanics, composer classification, or process-ancestry detection that have no Windows evidence and no ported implementation here.
Launching one would produce a pane that looks healthy and a supervision chain that silently never fires.

If `config/crew-harness` or `config/secondmate-harness` names an unverified adapter, tell the captain under `AGENTS.md` section 9 that the requested worker runtime is not available on this machine, use `claude` for current work, and ask only whether they want that runtime investigated for a future port.
Do not pause current work for that future choice, and never launch it.
The same applies to a `config/crew-dispatch.json` profile naming another adapter: bootstrap reports it as invalid, and you stop profile-based dispatch rather than selecting around it.

Crewmates default to the same harness firstmate is running on unless `config/crew-harness` records an adapter name; `default` means mirror firstmate's own.
`config/secondmate-harness` is the harness the primary uses to launch secondmate agents, resolved through `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own, and it may pin a model and effort token on the same line.
On this port all three resolve to `claude` or they are refused.

## Detection

**Harness detection itself is not ported.**
The digest resolves `Get-FmHarness` by name and no area owns it yet, so the session-start digest reports the primary harness as `unknown` and emits the `unknown` supervision protocol.
That is a degradation on purpose, not a fault to work around: do not infer the harness from a process name, and do not tell the captain the runtime is broken because the digest says `unknown`.

In practice it costs nothing today, because there is exactly one dispatchable adapter.
Treat the primary as `claude` when this session is a Claude session, and ask the captain rather than guessing if it plausibly is not.
A captain override always beats detection.

For stuck recovery the target's harness is recorded as `harness=` in `state/<id>.meta`, which IS written and is authoritative; use that value for interrupt, exit, and skill-invocation facts.

## Launch profile axes

`bin/fm-spawn.ps1` accepts concrete `-Harness`, `-Model`, and `-Effort` values chosen by firstmate at intake.
Do not make the scripts parse or match natural-language dispatch rules.

| Harness | Model flag | Effort flag | Notes |
|---|---|---|---|
| claude | `--model <model>` | `--effort <low\|medium\|high\|xhigh\|max>` | The only adapter this port launches. |

Effort precedence is an explicit per-task captain instruction first, then any applicable standing dispatch profile or secondmate pin, then the generic fallback.
Never replace an effort value supplied by either higher-precedence source.
Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design, choosing intermediate levels proportionally as complexity, uncertainty, blast radius, or open-ended reasoning increases.
Never select `max` from this fallback; use it only when the captain has explicitly expressed that per-task or standing preference.

Establish which models are currently available from the harness's own authoritative surface rather than memory: open the interactive session's `/model` picker, and read `claude --help` for the accepted alias or full-model-name input shape.
A listing that reaches the account and does not contain the model is concrete evidence the model is unsupported: block that candidate and quote the result.
A discovery surface you could not reach establishes nothing; report that as uncertainty rather than turning it into a verdict.

## Submission acknowledgement hazards

A send or key action reporting success is not proof that the intended action happened.
`bin/fm-send.ps1` verifies delivery through herdr's native agent state - an idle-to-busy transition across its own Enter is what proves the turn started - rather than trusting a bare success return, and it exits non-zero when a steer's Enter was positively swallowed.
Herdr on Windows strips styling from its capture, so the composer classifier cannot tell ghost text from typed text and answers `unknown` where a styled read would answer `empty`.
That is a deliberate safe direction: an `unknown` composer defers rather than injecting.
The consequence to remember is that composer-based proofs are weaker here than on Linux, and native agent state is the reading to trust.

## claude

| Fact | Value |
|---|---|
| Busy state | Owned lifecycle hooks plus herdr's native agent state. Claude fires no hook for a manual interrupt, so `bin/fm-control.ps1 interrupt` reports only delivered keys and the verified endpoint, publishes no idle event, makes no cancellation claim, and leaves adapter-observed state unchanged; a mid-turn worker typically remains busy. |
| Exit command | `/exit` |
| Interrupt | single Escape |
| Skill invocation | `/<skill>` |
| Autonomy | `--dangerously-skip-permissions`, passed by `bin/fm-spawn.ps1` for every crewmate and scout |

First launch in a fresh worktree, or first ever on a machine, may show a trust or bypass-permissions confirmation.
After every spawn, read the pane with `Get-FmPane fm-<id>` within about 20 seconds.
If such a dialog is showing, accept it with `bin/fm-send.ps1 <target> -Key Enter`, or the choice the dialog requires, then verify the brief started processing.

Claude renders a predicted-next-prompt suggestion as dim text inside an otherwise-empty composer after a turn completes.
`bin/fm-spawn.ps1` launches every claude worker with `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, scoped to firstmate-launched agents so it never touches the captain's global config.
The styled-capture ghost stripper the Linux fleet relies on as defense in depth cannot work here, because Windows herdr's capture arrives with styling removed - which is exactly why that launch variable, not the stripper, is the load-bearing control on this port.

### Hooks

Two distinct hook surfaces, and confusing them is a real failure mode.

- **The primary's own hooks** live in this checkout's `.claude/settings.json` and are written by `bin/fm-setup.ps1`: `SessionStart` (the digest), `PreToolUse` (the command policies and the delegation-shape guard), and `Stop` (the turn-end guard and the watcher re-arm).
  They all route to `bin/fm-claude-hook.ps1` and are registered with the PowerShell shell so nothing assumes a bash interpreter exists.
  A project-level `.claude/settings.json` only takes effect when Claude Code's project root is that exact directory - it does not walk up from a subdirectory - so the primary is started from the checkout root.
- **A crewmate's turn-end hook is NOT written on this port.**
  On Linux, `fm-spawn` writes a per-task Stop hook into the worktree's own `.claude/settings.local.json` whose entire guarantee is "touch `state/<id>.turn-ended` after each turn" - a wake notification, never state.
  This port does not write it yet (`docs/task-dispatch-windows.md`, "Not ported here"), so **no crewmate turn ever touches that marker here.**
  The watcher still consumes the marker if something else writes one, and every other wake path is intact: a crewmate's `state/<id>.status` append is still a wake, and a worker that goes quiet still ages into a stale wake.
  What is lost is the precise per-turn notification, so a worker that finishes a turn without appending a status line is noticed on the stale cadence rather than immediately.
  Do not paper over this by asking a worker to touch the marker itself; the brief's status protocol is the supported signal.

`docs/claude-hooks-windows.md` owns the exact contract and, importantly, the line between what has actually been executed on Windows and what is documentation only.
Read it before changing a hook, and never treat a documented hook behavior as verified.

### Delegation-shape guard

Claude exposes built-in delegation, scheduling, and worktree tools that a primary session can use to create work with no `state/<id>.meta`, which makes the whole guard stack inert because every guard counts that metadata.
The shipped mechanism is a `PreToolUse` guard that denies a delegation-shaped tool name.
A Claude primary should also keep an untracked per-home local `permissions.deny` list as hardening, because it removes those tools from the model's schema so they are never offered.
That deny list must not ship in tracked `.claude/settings.json`, because tracked project settings propagate into linked worktrees where they would disarm legitimate crewmates.

## Verifying a new adapter later

If the captain asks for another harness, do not launch it and see.
Propose verifying it first, as its own scoped task: prove on Windows that the harness runs in a herdr pane, that its turn-end hook fires and touches the marker file, that its interrupt and exit keys behave, and that its busy state is readable - then record those facts here and in `docs/windows-e2e-evidence.md` before any dispatch uses it.
Until that evidence exists the adapter stays refused, and saying so plainly is the correct answer.
