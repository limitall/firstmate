---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, SECONDMATE_HANDOFF, a fleet-refresh STUCK line, or a NETWORK CHECKS line - or when a standalone bin/fm-bootstrap.ps1 run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.ps1`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.ps1 -Install <approved tools...> -Approved`.
  The printed commands are the Windows ones (`winget`, `npm`, the vendor's PowerShell installer); never substitute a Linux package manager.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request, because this port acquires every task worktree as a durable lease and cannot fall back to the pane-cwd path.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; `bin/fm-bootstrap.ps1` owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe; `config/backlog-backend=manual` only suppresses the `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report, and `bin/fm-backlog.ps1` remains available either way.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
  For `no-mistakes`, report it to the captain as informational only: this port refuses the `no-mistakes` delivery mode by name (`AGENTS.md` section 7), so installing that tool does not make the mode available here.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `-Install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected.
  On this port the only value that can dispatch is `herdr`; a home sharing state with a Linux firstmate may legitimately carry another value, in which case say plainly that work cannot be dispatched from this machine until it is `herdr` here.
- `NEEDS_GH_AUTH` - ask the captain to run `gh auth login` themselves (it is interactive; you cannot run it for them).
  This probe arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK CHECKS: ...` reporting checks still IN PROGRESS or NOT CONFIRMED - the deferred network stage did not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  Treat none of the named checks as passed until the result lands.
- `TANGLE: primary checkout on feature branch '<branch>' (expected '<default>')` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
  A read-only session prints the advisory wording without the command; leave the restore to the session holding the lock.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive token count; do not infer the default.
  Correct the local file, then rerun session start.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
  On this port `claude` is the only verified harness name, so a profile naming any other adapter is invalid here even if it is valid on a Linux home.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in that route's backlog-format outbox.
  Preserve that outbox; never re-add or dispatch the items from the main backlog.
  The resume helper is not ported (`AGENTS.md` section 14), so report the pending delivery to the captain and hand the items back by hand into the owning home's backlog once it is reachable.
  An `unsafe outbox` variant requires path and file-type inspection before any retry.
- A fleet-refresh `<repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
- A fleet-refresh `<repo>: recovered: <detail>` - the clone had drifted and the refresh self-healed it without forcing or discarding; no action needed, it is reported only so the self-heal is visible.
- A fleet-refresh `<repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the refresh left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.

Lines the Linux bootstrap emits that this port never prints, because the machinery is absent (`AGENTS.md` section 14): `PR_CHECK_MIGRATION:`, `SECONDMATE_SYNC:`, `SECONDMATE_LIVENESS:`, `NUDGE_SECONDMATES:`, and `FMX:`.
If you ever see one, it came from a Linux firstmate sharing this home, not from this port.
