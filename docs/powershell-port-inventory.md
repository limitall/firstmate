# PowerShell port: conversion inventory and wave plan

Companion to [`docs/powershell-port.md`](powershell-port.md), which owns the
conventions, compatibility contracts, and verification method. This page owns
the **inventory**, the **dependency graph**, the **complexity ranking**, the
**wave packaging**, and the **risk register**. Where the two disagree, the
conventions page wins on contracts and this page wins on ordering — except
where section 5 explicitly says the conventions page has a gap.

Analysed against the **working tree** (~35 files carry uncommitted Windows-port
changes), not `git HEAD`. Snapshot taken 2026-08-02.

The tree was being edited concurrently while this was written — `tests/lib.sh`
grew by 30 lines mid-analysis. Line counts are therefore indicative, not exact;
the classifications, edges, and hazards below do not move with a few lines.

## Method (so a reader can re-derive every number)

Everything below is mechanical first, sampled-by-reading second.

| What | How |
| --- | --- |
| Line counts | one `awk` pass over each glob; `tests/*.sh` overlaps `tests/*.test.sh`, so counting both globs double-counts — count them separately |
| Source edges | lines whose first token is `.` or `source`, matched for `fm-*.sh` / `backends/*.sh` |
| Execute edges | `fm-*.sh` references on non-comment, non-`source` lines, minus self-references |
| Classification | presence of a `[ "${BASH_SOURCE[0]}" = "$0" ]` main guard; `-lib.sh` naming; fan-in from the source-edge table |
| DAG / cycles / depth | Python DFS over the source-edge table |
| Complexity markers | per-file counts of `trap`, `exec <fd>`, here-docs, `jq`, `mktemp`, `kill -0`, `ln -s`/`readlink`, `IFS=`, `/proc/`, `awk`, `perl`, `flock`/`set -C` |
| Windows accommodations | `OSTYPE\|msys\|cygpath\|CLAUDE_PID\|noacl\|SCRIPTED_CLI\|posixify\|MSYS` density per file |
| Implicit deps | every `fm_*` identifier used in a file, minus those defined in that file or in its transitive source closure; each hit then **read** to separate real call sites from comment mentions |

**Caveats, stated rather than hidden.** The execute-edge count (157) is an upper
bound: it still includes `fm-foo.sh` strings that appear inside usage heredocs
and `die` messages on non-comment lines. The direction and existence of each
edge is reliable; the multiplicity is not. Two judgement calls below are marked
*uncertain* rather than asserted.

Running the per-file loops in Git Bash is genuinely slow here — the MSYS fork
cost the port exists to remove. Single-pass `awk`/Python is ~40x faster and is
how these tables were built.

## Headline numbers

| Class | Count | Lines |
| --- | --- | --- |
| `bin/*.sh` | 99 | 36,632 |
| `bin/backends/*.sh` | 5 | 5,354 |
| `bin/backends/*.py` | 2 | 377 |
| `tests/*.test.sh` | 103 | 66,235 |
| `tests/*.test.py` | 1 | 106 |
| `tests/` shared helpers | 6 | 932 |
| **Total conversion surface** | **216** | **109,636** |

`bin/*.sh` by classification:

| Class | Count | Definition |
| --- | --- | --- |
| **lib** | 29 | sourced, defines functions, no side effects on source (28 `*-lib.sh` + `fm-backend.sh`) |
| **hybrid** | 5 | carries a `BASH_SOURCE[0]` main guard |
| **entrypoint** | 65 | executed only; argv + usage |

Table 1a below has 30 rows: the 29 libs plus `fm-operational-input.sh`, which is
counted as a hybrid here but is genuinely sourced by 4 production files.

Edges: **143 source edges**, **157 execute edges** (upper bound), **0 cycles**,
**max source depth 5**.

Complexity distribution across the 104 shell files in `bin/`:

| Call | Count | Meaning |
| --- | --- | --- |
| low | 44 | direct translation; no bash-only semantics |
| medium | 41 | one or two named hazards, each with a known PS idiom |
| high | 19 | multiple interacting hazards, or a contract the differential harness must police byte-for-byte |

---

## 1. Inventory

### 1a. Libraries (sourced; convert before consumers)

Ordered by fan-in — the number of files that `source` them. Fan-in is the single
best predictor of blast radius.

| File | Lines | Fan-in | Purpose | Cx |
| --- | ---: | ---: | --- | --- |
| `fm-wake-lib.sh` | 921 | 16 | Durable wake queue + portable lock primitives | **high** |
| `fm-backend.sh` | 986 | 13 | Runtime-backend selection, meta helpers, selector resolution; lazily sources one adapter | **high** |
| `fm-pr-lib.sh` | 984 | 9 | Validation + atomic artifact helpers for merge polling | **high** |
| `fm-x-lib.sh` | 1047 | 8 | X-mode connector client config resolution and HTTP | **high** |
| `fm-classify-lib.sh` | 414 | 7 | Shared wake classifier; captain-relevant status semantics | medium |
| `fm-psproc-lib.sh` | 244 | 6 | Portable process-query primitives (comm/args/ppid/pgid/alive) | medium |
| `fm-tasks-axi-lib.sh` | 76 | 5 | tasks-axi backend selection + compatibility probe | low |
| `fm-secondmate-registry-lib.sh` | 211 | 5 | Parser for `data/secondmates.md` records | medium |
| `fm-ff-lib.sh` | 419 | 5 | Fast-forward machinery for firstmate self-sync | medium |
| `fm-busy-lib.sh` | 376 | 5 | The one owner of the semantic busy-state contract | medium |
| `fm-public-followup-lib.sh` | 247 | 5 | Promised-public-reply commitment records | medium |
| `fm-primary-scope-lib.sh` | 33 | 4 | Marker-or-plain-checkout predicate for tracked hooks | low |
| `fm-tmux-lib.sh` | 429 | 4 | Shared tmux pane primitives | medium |
| `fm-operational-input.sh` | 252 | 4 | Canonical operational-input protocol *(hybrid)* | medium |
| `fm-gate-refuse-lib.sh` | 102 | 4 | Refusal that keeps a no-mistakes GATE agent out of fleet lifecycle | low |
| `fm-composer-lib.sh` | 234 | 4 | The one fleet-wide owner of composer-content classification | medium |
| `fm-startup-memory-budget-lib.sh` | 224 | 3 | Startup-memory budget primitives | low |
| `fm-config-inherit-lib.sh` | 1153 | 3 | Declared inherited-material propagation to secondmate homes | **high** |
| `fm-marker-lib.sh` | 12 | 3 | Compatibility entry point for from-firstmate routing | low |
| `fm-check-lib.sh` | 74 | 3 | Custom watcher-check hash/trust binding | medium |
| `fm-session-lock-lib.sh` | 175 | 3 | Session-lock harness identity | medium |
| `fm-supervision-lib.sh` | 80 | 3 | "supervision missing" predicate | low |
| `fm-pending-reply-lib.sh` | 1083 | 3 | Parent-owned secondmate missed-report guards | **high** |
| `fm-supervisor-target-lib.sh` | 78 | 2 | The single owner of supervisor-pane discovery | low |
| `fm-tangle-lib.sh` | 53 | 2 | Worktree-tangle guard for firstmate-on-itself | low |
| `fm-lock-lib.sh` | 104 | 2 | "is this git lock file provably abandoned?" decision | low |
| `fm-transition-lib.sh` | 103 | 2 | Backend-neutral agent-state transition shape | low |
| `fm-backend-hometag-lib.sh` | 52 | 2 | Per-installation home-tag derivation | low |
| `fm-quota-axi-lib.sh` | 52 | 1 | quota-axi compatibility floor for bootstrap | low |
| `fm-push-transition-lib.sh` | 76 | 1 | Watcher's native push-transition escalation | low |

> `fm-check-lib.sh` is the **only** file in `bin/` with no header comment — it
> opens straight into code. The port doc's "carries its twin's header comment
> adapted" convention has nothing to adapt; its PS twin needs an author-written
> header.

### 1b. Hybrids (main guard: sourced *and* executed)

| File | Lines | Sourced by | Why the guard exists |
| --- | ---: | --- | --- |
| `fm-operational-input.sh` | 252 | 4 production files | genuine dual use |
| `fm-afk-start.sh` | 156 | `fm-afk-launch.sh` | genuine dual use |
| `fm-afk-launch.sh` | 656 | tests only | testability |
| `fm-herdr-lab.sh` | 346 | tests only | testability |
| `fm-supervise-daemon.sh` | 1622 | tests only | testability |

PowerShell has no `BASH_SOURCE`/`$0` distinction for a `.psm1`. The natural twin
is a `.psm1` module holding the functions plus a thin `.ps1` that imports it and
runs `main`. **This changes the file count for these five** — flag it in the
package brief so an agent does not silently invent a different shape.

### 1c. Backend adapters

| File | Lines | Cx | Notes |
| --- | ---: | --- | --- |
| `backends/herdr.sh` | 3491 | **high** | 97 `jq`, 27 Windows accommodations, mkfifo + `exec 9<` + background reader, 8 here-docs. The single hardest file in the repo. |
| `backends/cmux.sh` | 674 | medium | 10 `jq`, experimental |
| `backends/zellij.sh` | 642 | medium | 14 `jq`, experimental |
| `backends/orca.sh` | 336 | low | thinnest adapter |
| `backends/tmux.sh` | 211 | low | delegates to `fm-tmux-lib.sh`; **the verified reference backend** |
| `backends/herdr-eventwait.py` | 263 | medium | AF_UNIX/JSONL subscriber — absorbed natively per the conventions page |
| `backends/herdr-workspace-move.py` | 114 | low | *uncertain*: the conventions page names only `herdr-eventwait.py` as absorbed. This one is invoked as a subprocess (3 call sites) and could legitimately stay Python behind that boundary. **Needs a decision, not a guess.** |

### 1d. Entrypoints (65)

Grouped by subsystem, with line counts. Purposes are the files' own header
comments.

**Lifecycle core** — `fm-spawn.sh` 1725 · `fm-teardown.sh` 1549 ·
`fm-send.sh` 340 · `fm-brief.sh` 411 · `fm-crew-state.sh` 613 ·
`fm-peek.sh` 25 · `fm-promote.sh` 29 · `fm-review-diff.sh` 158

**Watcher / supervision** — `fm-supervise-daemon.sh` 1622 · `fm-watch.sh` 1064 ·
`fm-watch-arm.sh` 498 · `fm-watch-checkpoint.sh` 109 · `fm-guard.sh` 220 ·
`fm-turnend-guard.sh` 239 · `fm-turnend-guard-grok.sh` 90 ·
`fm-claude-stop-autoarm.sh` 194 · `fm-supervision-instructions.sh` 209 ·
`fm-wake-drain.sh` 79 · `fm-kimi-turnend-hook.sh` 276

**Session start / bootstrap** — `fm-bootstrap.sh` 1002 · `fm-session-start.sh` 461 ·
`fm-sessionstart-nudge.sh` 58 · `fm-lock.sh` 87 · `fm-harness.sh` 162 ·
`fm-startup-memory-budget.sh` 94 · `fm-vendor-auth-probe.sh` 200

**Fleet / project** — `fm-fleet-snapshot.sh` 1341 · `fm-fleet-view.sh` 96 ·
`fm-fleet-sync.sh` 430 · `fm-bearings-snapshot.sh` 518 · `fm-project-mode.sh` 66 ·
`fm-ensure-agents-md.sh` 287 · `fm-update.sh` 91 · `fm-merge-local.sh` 68

**Secondmate** — `fm-home-seed.sh` 960 · `fm-config-push.sh` 199 ·
`fm-backlog-handoff.sh` 336 · `fm-secondmate-report.sh` 88

**PR / checks** — `fm-pr-check-migrate.sh` 1148 · `fm-pr-check.sh` 122 ·
`fm-pr-merge.sh` 84 · `fm-pr-poll.sh` 110 · `fm-check-register.sh` 41 ·
`fm-decision-hold.sh` 464

**X mode / public follow-up** — `fm-x-reply.sh` 385 · `fm-x-followup.sh` 280 ·
`fm-x-poll.sh` 185 · `fm-x-link.sh` 176 · `fm-x-dismiss.sh` 116 ·
`fm-public-followup.sh` 906 · `fm-public-followup-emit.sh` 260

**AFK** — `fm-afk-launch.sh` 656 · `fm-afk-return.sh` 219 · `fm-afk-start.sh` 156

**Hooks / guards** — `fm-arm-pretool-check.sh` 173 · `fm-cd-pretool-check.sh` 166 ·
`fm-subagent-pretool-check.sh` 207 · `fm-busy-event.sh` 216

**Herdr operations** — `fm-herdr-lab.sh` 346 · `fm-herdr-session-cleanup.sh` 335 ·
`fm-herdr-ci-cleanup.sh` 115

**Tooling / install** — `fm-test-run.sh` 1435 · `fm-test-isolation-proof.sh` 494 ·
`fm-lint.sh` 466 · `fm-doc-audience-check.sh` 269 · `fm-windows-setup.sh` 451 ·
`fm-install-herdr.sh` 107 · `fm-install-shellcheck.sh` 129 ·
`fm-install-treehouse.sh` 127

### 1e. Tests, and what they verify

103 `.test.sh` + 1 `.test.py` + 6 helpers. 72 of 103 source `tests/lib.sh`.

Shared helpers (convert first, in wave 1/2):

| Helper | Lines | Used by |
| --- | ---: | --- |
| `tests/lib.sh` | 289 | 72 tests |
| `tests/wake-helpers.sh` | 299 | 7 tests |
| `tests/secondmate-helpers.sh` | 191 | 3 tests |
| `tests/herdr-test-safety.sh` | 42 | 11 tests |
| `tests/zellij-test-safety.sh` | 60 | zellij suites |
| `tests/cmux-test-safety.sh` | 51 | cmux suites |

The ten largest suites, with the script each principally verifies (derived from
which `bin/*.sh` each test invokes most, then spot-read):

| Test | Lines | Verifies |
| --- | ---: | --- |
| `fm-backend-herdr.test.sh` | 4024 | `backends/herdr.sh` (fake-CLI unit) |
| `fm-pr-check-security.test.sh` | 3363 | `fm-pr-lib.sh`, `fm-pr-poll.sh`, `fm-x-poll.sh` |
| `fm-calm-pi-extension.test.sh` | 3284 | Pi `/calm` extension + `fm-wake-drain.sh` |
| `fm-x-mode.test.sh` | 2993 | `fm-x-reply/poll/followup/link/dismiss` |
| `fm-secondmate-safety.test.sh` | 2432 | `fm-home-seed.sh`, `fm-teardown.sh`, `fm-spawn.sh` |
| `fm-secondmate-harness.test.sh` | 2357 | `fm-harness.sh`, `fm-spawn.sh`, `fm-config-push.sh` |
| `fm-pi-watch-extension.test.sh` | 2156 | `fm-watch-arm.sh`, Pi watcher extension |
| `fm-bearings-snapshot.test.sh` | 1932 | `fm-fleet-snapshot.sh`, `fm-bearings-snapshot.sh` |
| `fm-daemon.test.sh` | 1928 | `fm-supervise-daemon.sh`, `fm-afk-start.sh` |
| `fm-teardown.test.sh` | 1865 | `fm-teardown.sh` |

Full test→target mapping is reproducible with the awk one-liner in *Method*;
it is not duplicated here because it rots. **Rule for packaging: a test belongs
to the package that owns the script it names in its header comment.** Every test
file in this repo states its target in its header — that is the authority, not
the invocation histogram, which over-weights fixture setup.

---

## 2. The real dependency graph

**This is the section that determines parallelism.** Two edge kinds, two very
different consequences.

### 2a. Source edges (hard ordering)

`. "$SCRIPT_DIR/fm-foo-lib.sh"` inlines a file into the caller's shell. A `.psm1`
cannot import a `.sh`. **A sourced lib must be converted before, or in the same
package as, every consumer.** 143 such edges.

The graph is a **clean DAG — no cycles** — with **maximum depth 5**:

```
fm-watch.sh ─► fm-pending-reply-lib.sh ─► fm-backend.sh ─► backends/tmux.sh
                                                         ─► fm-tmux-lib.sh
                                                         ─► fm-composer-lib.sh
```

Thirteen other files share the shorter `X → fm-backend.sh → backends/tmux.sh →
fm-tmux-lib.sh → fm-composer-lib.sh` tail. **`fm-composer-lib.sh` is the deepest
leaf in the repo and must be converted first of everything.**

**Leaf libs (source nothing)** — 21 genuine libraries, safely convertible in
parallel on day one:

`fm-composer-lib` · `fm-psproc-lib` · `fm-wake-lib` · `fm-classify-lib` ·
`fm-pr-lib` · `fm-x-lib` · `fm-busy-lib` · `fm-tasks-axi-lib` ·
`fm-secondmate-registry-lib` · `fm-primary-scope-lib` · `fm-gate-refuse-lib` ·
`fm-startup-memory-budget-lib` · `fm-check-lib` · `fm-supervision-lib` ·
`fm-supervisor-target-lib` · `fm-tangle-lib` · `fm-lock-lib` ·
`fm-transition-lib` · `fm-backend-hometag-lib` · `fm-quota-axi-lib` ·
`fm-operational-input` *(hybrid)*

### 2b. Execute edges (NO ordering — this is where the parallelism is)

`"$SCRIPT_DIR/fm-foo.sh" args` is a **process boundary**. The child can stay
bash indefinitely. 157 such edges, and **none of them forces serialization**.

Concretely, the biggest orchestrators are almost pure execute-edge consumers and
can therefore be converted *at any time, by any agent, in any wave*:

| Orchestrator | Source edges | Execute edges | Consequence |
| --- | ---: | ---: | --- |
| `fm-test-run.sh` (1435) | **0** | ~48 | zero ordering constraints — convertible on day one |
| `fm-session-start.sh` (461) | 3 | 8 | needs only 3 libs; the 8 children stay bash |
| `fm-teardown.sh` (1549) | 8 | 7 | the 7 children stay bash |
| `fm-supervision-instructions.sh` (209) | **0** | 5 | zero constraints |
| `fm-watch.sh` (1064) | 7 | 5 | 5 children stay bash |
| `fm-bootstrap.sh` (1002) | 9 | 7 | 7 children stay bash |

**This buys the single largest parallelism win available.** `fm-teardown.ps1`
does not need `fm-fleet-sync.ps1`, `fm-decision-hold.ps1`,
`fm-public-followup.ps1`, `fm-pr-poll.ps1`, `fm-merge-local.ps1`,
`fm-busy-event.ps1`, or `fm-guard.ps1` to exist. Six different agents can own
those seven files concurrently with the agent that owns teardown.

**But that win is conditional on a resolver that `docs/powershell-port.md` does
not currently specify.** See risk R1.

### 2c. Implicit source edges (undeclared — the dangerous class)

Two files call functions they never source. This works today only because every
caller happens to source both. **A PowerShell module has its own scope; a
`.psm1` cannot see functions its *caller* imported.** These will fail at
conversion time in a way unit tests may not catch, because the test harness also
sources both.

| File | Silently needs | Nature |
| --- | --- | --- |
| `fm-check-lib.sh` | `fm-pr-lib.sh` — `fm_pr_task_id_valid`, `fm_pr_file_device`, `fm_pr_private_file_valid`, `fm_pr_file_mode`, `fm_pr_file_link_count` | **hard and unconditional** (lines 20, 22, 24, 42–43, 53–54, 60–64) |
| `fm-busy-lib.sh` | `fm-backend.sh` — `fm_backend_target_exists`, `fm_backend_of_meta`, `fm_backend_target_of_meta`, `fm_meta_get` hard (lines 343, 357–359); `fm_backend_busy_state`, `fm_backend_capture` guarded by `command -v` (lines 303, 313) | **mixed**: part hard, part optional-capability probe |

The `command -v fm_backend_busy_state` probe is a *deliberate* optional-capability
pattern. Its PS twin is `Get-Command ... -ErrorAction SilentlyContinue`, and it
must keep answering "absent" when the backend module is not loaded — converting
it into a hard import would change behavior.

**Checked and cleared** (so no one re-derives them as risks):

- `fm-psproc-lib.sh` → `fm_pid_identity`: **comment only** (line 41). Not an edge.
- `backends/*.sh` → `fm_backend_*`: **comment only** (herdr.sh lines 10, 1331).
  The backends do **not** call up into the dispatcher. Layering is strictly
  one-directional, so there is no import cycle to design around.

---

## 3. Conversion complexity ranking

Ranked by what actually makes bash→PowerShell hard *in this repo*.

### High (19)

| File | Specific reason |
| --- | --- |
| `backends/herdr.sh` (3491) | 97 `jq` · 27 Windows accommodations · `mkfifo` + `exec 9<` + backgrounded reader + `rm -rf` teardown (3413–3486) · 8 here-docs · 14 `IFS=` · 6 `awk`. Everything hard in one file. |
| `fm-wake-lib.sh` (921) | Two coexisting lock representations (symlink vs `mkdir`), a live capability probe that decides between them, `set -C` noclobber pid write, owner-token shape validation, steal protocol. Fan-in 16. See R2. |
| `fm-pr-lib.sh` (984) | 39 `exec <fd>` operations (fds 7/8/9) reading fixed-position record files line-by-line · 36 `IFS=` · device/mode/link-count private-file gates that `noacl` already makes unsatisfiable on Windows |
| `fm-x-lib.sh` (1047) | 27 `jq` · 7 `mktemp` · 3 `trap` with signal-specific exit codes (143) · auth-header temp files · `noacl` ownership fallback (lines 106, 180) |
| `fm-spawn.sh` (1725) | Largest entrypoint · 8 here-docs generating brief/launch content · 7 source edges · worktree isolation assertion is a safety contract |
| `fm-teardown.sh` (1549) | 1549 lines of landed-work safety · 8 source edges · 6 here-docs · conditional `trap` inside a branch (1181) |
| `fm-supervise-daemon.sh` (1622) | 3 `trap` on TERM/INT with `trap -` windows · portable single-instance lock · `kill -0` · 10 `wait` · daemon process lifetime |
| `fm-watch.sh` (1064) | 2 `trap` including a *signal-flag* trap (`FM_CHECK_SIGNAL_PENDING=1`, line 520) that PowerShell has no direct equivalent for · 13 `wait` · writes 4 children into the lock dir |
| `fm-config-inherit-lib.sh` (1153) | 10 `mktemp` + atomic rename · 8 `IFS=` · 5 here-docs · declared-material schema |
| `fm-pending-reply-lib.sh` (1083) | Correlation/recovery/escalation state machine · 4 `IFS=` TSV records · 4 `awk` |
| `fm-pr-check-migrate.sh` (1148) | 12 `exec <fd>` (fds 6/7) · 6 `mktemp` · 7 `IFS=` · quarantine/migration transactional semantics |
| `fm-fleet-snapshot.sh` (1341) | **73 `jq` invocations** · 6 here-docs · 4 `awk` + 4 `perl` · dynamic `. "$classify"` source at line 892 |
| `fm-bootstrap.sh` (1002) | 9 source edges (highest) · 5 `mktemp` · 6 `IFS=` · gated MUTATING sweeps |
| `fm-home-seed.sh` (960) | `trap seed_rollback EXIT` + `trap - EXIT` rollback protocol (847/942) · 7 `IFS=` · 6 `awk` |
| `fm-public-followup.sh` (906) | 24 `jq` · 5 `mktemp` · 5 here-docs · typed terminal-result inbox |
| `fm-backend.sh` (986) | Dispatcher with lazy per-adapter `source` and per-adapter sourced-once flags (601–641). Fan-in 13. See R3. |
| `fm-test-run.sh` (1435) | Embedded `python3 - <<'PY'` heredocs · 16 `IFS=` · lane/shard/parallel orchestration · 5 `mktemp` |
| `fm-lint.sh` (466) | 4 `trap` incl. worker-scoped HUP/INT/TERM with exit codes 129/130/143 · background workers · 2 `/proc/` reads |
| `fm-windows-setup.sh` (451) | 24 `jq` · `MSYS=winsymlinks:nativestrict` probe · symlink materialization. **Arguably should not be ported at all** — see R7. |

### Medium (41)

Characterised by one or two named hazards:

- **`jq`-heavy** (becomes `ConvertFrom-Json -AsHashtable`, a clear win):
  `backends/zellij.sh` (14) · `backends/cmux.sh` (10) · `fm-herdr-lab.sh` (10) ·
  `fm-x-reply.sh` (10) · `fm-bearings-snapshot.sh` (11) ·
  `fm-herdr-ci-cleanup.sh` (7) · `fm-herdr-session-cleanup.sh` (7) ·
  `fm-afk-launch.sh` (7) · `fm-x-poll.sh` (6) · `fm-turnend-guard.sh` (5) ·
  `fm-turnend-guard-grok.sh` (4) · `fm-kimi-turnend-hook.sh` (4) ·
  `fm-x-dismiss.sh` (4) · `fm-arm-pretool-check.sh` (4) ·
  `fm-public-followup-emit.sh` (4) · `fm-subagent-pretool-check.sh` (3) ·
  `fm-cd-pretool-check.sh` (3) · `fm-x-link.sh` (3) · `fm-fleet-view.sh` (2)
- **Signal/trap**: `fm-watch-arm.sh` (6 traps, named handlers mapping HUP/TERM/INT
  to 129/143/130) · `fm-afk-return.sh` · `fm-config-push.sh` ·
  `fm-wake-drain.sh` · `fm-pr-check.sh` · `fm-lock.sh` · `fm-check-register.sh`
- **`mktemp` + atomic rename**: `fm-install-{herdr,shellcheck,treehouse}.sh` ·
  `fm-watch-checkpoint.sh` · `fm-test-isolation-proof.sh`
- **Record parsing where empty fields matter**: `fm-classify-lib.sh` ·
  `fm-secondmate-registry-lib.sh` · `fm-decision-hold.sh` ·
  `fm-backlog-handoff.sh` · `fm-tmux-lib.sh` · `fm-pr-poll.sh`
- **Process identity**: `fm-psproc-lib.sh` · `fm-session-lock-lib.sh` ·
  `fm-harness.sh` · `fm-sessionstart-nudge.sh`
- **here-doc file generation**: `fm-brief.sh` (8) · `fm-session-start.sh` (5) ·
  `fm-ensure-agents-md.sh` (3, plus 4 symlink ops)
- Remainder: `fm-busy-lib` · `fm-busy-event` · `fm-check-lib` · `fm-crew-state` ·
  `fm-ff-lib` · `fm-fleet-sync` · `fm-composer-lib` · `fm-operational-input` ·
  `fm-public-followup-lib` · `fm-doc-audience-check` · `fm-afk-start` ·
  `fm-review-diff` · `fm-vendor-auth-probe` · `fm-startup-memory-budget-lib`

### Low (44)

Direct translations with no bash-only semantics: `fm-peek` (25) ·
`fm-promote` (29) · `fm-primary-scope-lib` (33) · `fm-check-register` (41) ·
`fm-backend-hometag-lib` (52) · `fm-quota-axi-lib` (52) · `fm-tangle-lib` (53) ·
`fm-sessionstart-nudge` (58) · `fm-project-mode` (66) · `fm-merge-local` (68) ·
`fm-tasks-axi-lib` (76) · `fm-push-transition-lib` (76) ·
`fm-supervisor-target-lib` (78) · `fm-wake-drain` (79) · `fm-supervision-lib` (80) ·
`fm-pr-merge` (84) · `fm-lock` (87) · `fm-secondmate-report` (88) ·
`fm-update` (91) · `fm-startup-memory-budget` (94) · `fm-fleet-view` (96) ·
`fm-transition-lib` (103) · `fm-lock-lib` (104) · `backends/tmux.sh` (211) ·
`backends/orca.sh` (336) · `fm-marker-lib` (12) — plus the smaller entrypoints
listed in 1d.

### Windows accommodations that get *simpler* in PowerShell

Every one of these marks a place where the PS twin should be **shorter** than
its bash twin. Say so in the converted file's header.

| File | Hits | What disappears |
| --- | ---: | --- |
| `backends/herdr.sh` | 27 | `pane_posixify` inverts to a no-op; `/tmp` `noacl` notes; `SCRIPTED_CLI` test hooks stay |
| `fm-psproc-lib.sh` | 13 | **The entire file collapses.** The Cygwin-`ps` column parsing, `ps -W` WINPID matching, `tasklist //FI` fallback, `/proc/<pid>/exename` reads and the `kill -0`-can't-see-native-processes workaround all become `Get-Process` / `Get-CimInstance Win32_Process`. ~244 lines → an estimated ~60. |
| `fm-windows-setup.sh` | 9 | `MSYS=winsymlinks:nativestrict` probing is moot |
| `fm-session-lock-lib.sh` | 9 | native pid identity |
| `fm-supervise-daemon.sh` | 6 | native process lifetime |
| `fm-wake-lib.sh` | 5 | symlink-capability probe *may* be removable — but see R2 before removing it |
| `fm-install-treehouse.sh` | 5 | `cygpath` translation |
| `fm-bootstrap.sh` | 5 | path conversion |
| `fm-x-lib.sh`, `fm-pr-lib.sh` | 2, 1 | `noacl` private-file gates: on Windows the mode-0600/0700 checks are already unsatisfiable, so the PS twin should use ACL checks — **a behavior improvement, not a translation**, and therefore needs explicit sign-off, not a silent change |

---

## 4. Proposed wave assignment

Constraints honoured: exclusive file ownership; coherent single-subsystem
packages; sourced-dependency order respected across waves; execute-edge
consumers deliberately *not* serialized; every package carries its own tests.

Sizes are "agent-days" as a rough relative unit, not a schedule.

### Wave 1 — Foundation (sequential; blocks everything)

| Package | Files owned | Size |
| --- | --- | ---: |
| **W1-common** | `bin/fm-common.psm1` (new), PSScriptAnalyzer settings, **plus the `Invoke-FmScript` sibling resolver of R1** | 2.0 |
| **W1-testlib** | `tests/lib.psm1` (port of `tests/lib.sh`), fakebin-as-`.ps1`-shim mechanism | 1.5 |
| **W1-diff** | `tools/fm-ps-diff.ps1` (already under way) | 1.0 |
| **W1-exemplar** | `bin/fm-transition-lib.psm1` + `tests/fm-transition-lib.test.ps1` — the pattern every later agent copies | 0.5 |

`tests/lib.sh`'s `fm_fakebin_tool` already documents why a symlink shim is wrong
on this platform and uses a two-line `exec` wrapper. The PS twin needs the
equivalent: a `.ps1` (or `.cmd`) shim on `$env:PATH`. That mechanism is
load-bearing for **72 test files** and must be settled in wave 1.

### Wave 2 — Leaf libs (fully parallel: no package depends on another)

| Package | Files owned (+ tests) | Depends on | Size |
| --- | --- | --- | ---: |
| **W2-composer** | `fm-composer-lib` + `fm-composer-lib.test`, `fm-composer-ghost.test` | W1 | 1.0 |
| **W2-psproc** | `fm-psproc-lib` (expect a large simplification) | W1 | 1.0 |
| **W2-wake** | `fm-wake-lib` + `fm-wake-queue.test`, `fm-watcher-lock.test`, `tests/wake-helpers` | W1 | **3.0** |
| **W2-classify** | `fm-classify-lib`, `fm-transition-lib` (done in W1), `fm-supervision-lib` + `fm-supervision-events.test` | W1 | 1.5 |
| **W2-pr** | `fm-pr-lib` **+ `fm-check-lib`** (R4: undeclared dependency — same package) + `fm-pr-check-security.test` | W1 | **3.0** |
| **W2-x** | `fm-x-lib` + the `fm-x-mode.test` portions covering it | W1 | 2.5 |
| **W2-busy** | `fm-busy-lib` + `fm-busy-state.test`, `fm-busy-adapter-wiring.test` | W1 | 1.5 |
| **W2-small-a** | `fm-tasks-axi-lib`, `fm-quota-axi-lib`, `fm-tangle-lib`, `fm-lock-lib`, `fm-primary-scope-lib` + `fm-tangle-guard.test` | W1 | 1.0 |
| **W2-small-b** | `fm-secondmate-registry-lib`, `fm-startup-memory-budget-lib`, `fm-supervisor-target-lib`, `fm-backend-hometag-lib`, `fm-gate-refuse-lib` + `fm-startup-memory-budget.test`, `fm-gate-refuse.test` | W1 | 1.0 |
| **W2-opinput** | `fm-operational-input` (hybrid → `.psm1` + `.ps1`) + `fm-operational-input.test` | W1 | 1.0 |

W2-busy carries the *other* implicit dependency (`fm-busy-lib` → `fm-backend`).
Because `fm-backend` is not converted until W3, W2-busy must implement the
`command -v` probe as a genuine runtime capability check, not an import.

### Wave 3 — Tier-2 libs, backend dispatcher, adapters

`fm-backend` and the adapters are packaged **together**, contradicting the
conventions page's wave 3/4 split. Rationale in R3.

| Package | Files owned (+ tests) | Depends on | Size |
| --- | --- | --- | ---: |
| **W3-backend-core** | `fm-backend` + `backends/tmux` + `fm-tmux-lib` + `fm-backend.test`, `fm-backend-tmux-smoke.test`, `fm-tmux-submit-busy.test` | W2-composer, W2-psproc, W2-busy | **3.0** |
| **W3-herdr** | `backends/herdr` + `backends/herdr-eventwait.py` (absorbed) + `fm-backend-herdr.test` (4024) + the 8 herdr e2e suites + `tests/herdr-test-safety` | W3-backend-core, W2-wake | **6.0 — the largest single package** |
| **W3-zellij-cmux-orca** | `backends/{zellij,cmux,orca}` + their 6 test files + the two safety helpers | W3-backend-core | 2.5 |
| **W3-marker-session** | `fm-marker-lib`, `fm-session-lock-lib`, `fm-pending-reply-lib` + `fm-pending-reply.test`, `fm-send-secondmate-marker.test` | W2-opinput, W2-psproc, W3-backend-core | 2.5 |
| **W3-ff-inherit** | `fm-ff-lib`, `fm-config-inherit-lib` + `fm-secondmate-sync.test`, `fm-shared-captain-inheritance.test` | W2-small-b | 2.5 |
| **W3-followup** | `fm-public-followup-lib`, `fm-push-transition-lib` + `fm-public-followup.test` | W2-x, W2-classify | 1.5 |

### Wave 4 — Entrypoints (heavily parallel via execute edges)

Every package here talks to its siblings through **process boundaries**, so
none blocks another.

| Package | Files owned (+ tests) | Size |
| --- | --- | ---: |
| **W4-spawn** | `fm-spawn` + `fm-spawn-{batch,dispatch-profile,worktree-settle}.test` | 3.0 |
| **W4-teardown** | `fm-teardown`, `fm-promote` + `fm-teardown.test`, `fm-teardown-endpoint-safety.test` | 3.0 |
| **W4-send-peek** | `fm-send`, `fm-peek`, `fm-crew-state` + `fm-send-{strict,settle,popup-settle}.test`, `fm-crew-state.test` | 2.5 |
| **W4-brief** | `fm-brief`, `fm-ensure-agents-md`, `fm-project-mode` + `fm-brief.test`, `fm-ensure-agents-md.test`, `fm-ask-user-authority.test` | 2.0 |
| **W4-watch** | `fm-watch`, `fm-watch-arm`, `fm-watch-checkpoint`, `fm-guard`, `fm-wake-drain` + `fm-watch-triage.test`, `fm-arm-pretool-check.test`, `fm-watch-checkpoint.test`, `fm-guard-stale-banner.test` | **4.0** |
| **W4-turnend** | `fm-turnend-guard`, `fm-turnend-guard-grok`, `fm-claude-stop-autoarm`, `fm-kimi-turnend-hook` + `fm-turnend-guard.test`, `fm-claude-stop-autoarm.test`, `fm-grok-harness.test`, `fm-kimi-harness.test` | 3.0 |
| **W4-daemon-afk** | `fm-supervise-daemon`, `fm-afk-{start,launch,return}` + `fm-daemon.test`, `fm-afk-*.test` (5 files) | **4.0** |
| **W4-session** | `fm-session-start`, `fm-bootstrap`, `fm-lock`, `fm-harness`, `fm-sessionstart-nudge`, `fm-supervision-instructions`, `fm-startup-memory-budget` + 6 tests | **4.0** |
| **W4-fleet** | `fm-fleet-snapshot`, `fm-fleet-view`, `fm-fleet-sync`, `fm-bearings-snapshot`, `fm-update`, `fm-merge-local` + `fm-fleet-snapshot-view.test`, `fm-bearings-snapshot.test`, `fm-fleet-sync.test`, `fm-update.test` | **4.0** |
| **W4-secondmate** | `fm-home-seed`, `fm-config-push`, `fm-backlog-handoff`, `fm-secondmate-report` + `fm-secondmate-{safety,harness,liveness,lifecycle-e2e}.test`, `fm-backlog-handoff.test` | **4.0** |
| **W4-pr** | `fm-pr-check`, `fm-pr-merge`, `fm-pr-poll`, `fm-pr-check-migrate`, `fm-check-register`, `fm-decision-hold`, `fm-review-diff` + `fm-pr-merge.test`, `fm-review-diff.test`, `fm-decision-hold-lifecycle.test` | 3.5 |
| **W4-xmode** | `fm-x-{reply,followup,poll,link,dismiss}`, `fm-public-followup`, `fm-public-followup-emit` + remaining `fm-x-mode.test` | 3.0 |
| **W4-hooks** | `fm-arm-pretool-check`, `fm-cd-pretool-check`, `fm-subagent-pretool-check`, `fm-busy-event` + `fm-cd-pretool-check.test`, `fm-subagent-pretool-check.test` | 1.5 |
| **W4-herdr-ops** | `fm-herdr-lab`, `fm-herdr-session-cleanup`, `fm-herdr-ci-cleanup` + `fm-herdr-lab.test`, `fm-herdr-session-cleanup{,-e2e}.test` | 2.0 |

### Wave 5 — Tooling, cutover, decisions

| Package | Files owned | Size |
| --- | --- | ---: |
| **W5-testrun** | `fm-test-run`, `fm-test-isolation-proof` + their tests. **Zero source edges — could be pulled forward to wave 2 if an agent is free.** | 3.0 |
| **W5-lint-docs** | `fm-lint`, `fm-doc-audience-check` + `fm-lint.test`, `fm-documentation-audiences.test` | 2.0 |
| **W5-install** | `fm-install-{herdr,shellcheck,treehouse}`, `fm-vendor-auth-probe` + `fm-vendor-auth-probe.test` | 1.5 |
| **W5-pi-calm** | `fm-calm-pi-extension.test` (3284), `fm-pi-watch-extension.test` (2156), `fm-pi-primary-types.test` — tracked Pi extensions, not `bin/` scripts | 2.5 |
| **W5-cutover** | hook rewiring to `pwsh -NoProfile -File`, CI lane, `docs/powershell-port.md` rewrite, retire-or-keep decision per bash file | 2.0 |
| **W5-live-e2e** | the 8 opt-in credentialed `*-live-e2e.test.sh` suites — **decide whether to port at all** (they drive real vendor CLIs; the bash originals may simply remain the authority) | 1.0 |

### Ordering summary

```
W1 (sequential)
 └─► W2  ×10 packages, fully parallel
      └─► W3  ×6 packages; W3-herdr is the long pole
           └─► W4  ×14 packages, fully parallel (execute edges only)
                └─► W5  (W5-testrun can start any time after W1)
```

Critical path: **W1 → W2-composer/psproc/busy → W3-backend-core → W3-herdr →
W4-\***. `backends/herdr.sh` is the long pole and should be staffed first
within its wave.

---

## 5. Risk register

Ordered by how much damage a wrong call does.

### R1 — The conventions page does not say how a PS twin calls a bash sibling

**This is the most consequential gap, and it is a gap in
`docs/powershell-port.md`, not in the code.**

Both trees coexist during the transition. When `fm-teardown.ps1` reaches its
execute edge to `fm-fleet-sync`, does it invoke `bin/fm-fleet-sync.sh` via
`bash`, or `bin/fm-fleet-sync.ps1`? The page is silent. Left to individual
agents, some will hard-code `.ps1` (breaking until the sibling lands, which
re-serializes waves 4 and 5 and destroys the parallelism in §2b) and some will
hard-code `.sh` (leaving ~157 call sites to sweep at cutover).

**Recommendation:** make `Invoke-FmScript <name> [args]` a **wave-1 foundation
deliverable** in `fm-common.psm1`: prefer `bin/<name>.ps1` when it exists, else
`bash bin/<name>.sh`. Then every execute edge is transition-safe automatically,
wave order genuinely stops mattering for execute edges, and cutover is deleting
one fallback branch rather than editing 157 sites.

**Evidence to demand:** a differential run of `fm-teardown` with the sibling
present *and* absent, producing identical observable behavior both ways.

### R2 — `fm-wake-lib.sh`'s lock has two on-disk representations, and a PS twin could pick a third

`fm-wake-lib.sh` lines 110–143 document that the lock is published either as
`ln -s "$ownerdir" "$lockdir"` (where symlinks work) or as
`mkdir "$lockdir"` + `pid` + `.fm-lock-owner` (where they do not) — chosen by a
**live probe** (`fm_lock_symlinks_work`, line 172) whose verdict is memoized
per directory and explicitly *not* inferred from `uname`, because "the same MSYS
host answers differently with Developer Mode or `MSYS=winsymlinks` set."

Two hazards:

1. **Cross-runtime mutual exclusion.** During the transition a bash watcher and
   a PS watcher may contend for the same `state/.watch.lock`. If the PS twin
   picks a different representation than the bash twin would have picked on that
   same directory, **both processes can believe they hold the lock**. The
   watcher singleton silently stops being a singleton. `AGENTS.md` section 8's
   "never broadly kill watchers" guidance exists because sibling homes are
   already easy to damage; two live watchers in one home is worse.
2. **`docs/powershell-port.md` line 102 is ambiguous.** "`[System.IO.File]::Open`
   with `FileMode.CreateNew` is the atomic claim primitive (the noclobber twin)"
   is *correct* if read as the twin of the `set -C` pid write at line 407. Read
   as "the lock is a file", it is **wrong**: lines 129–133 state the lock path
   stays a **directory** in both modes deliberately, because `fm-watch.sh` and
   `fm-watch-arm.sh` read and write `$lockdir/pid`, `/fm-home`, `/pid-identity`
   and `/watcher-path` directly (confirmed at `fm-watch.sh:698–700, 721` and
   `fm-watch-arm.sh:97–98, 217–219, 336`). A file lock makes all ten of those
   `ENOTDIR`.

**Recommendation:** the PS twin must run the *same* capability probe and produce
the *same* representation, including the directory shape. Do not "simplify to
native Windows locking" even though PowerShell could.

**Evidence to demand:** a contention test with a bash `fm-watch.sh` and a PS
`fm-watch.ps1` racing for one lock, on a directory where symlinks work and again
where they do not — four combinations, exactly one winner each time.

### R3 — `fm-backend` and the five adapters cannot be split across waves 3 and 4

`fm_backend_source` (lines 601–641) lazily `source`s exactly one adapter, guarded
by a per-adapter `_FM_BACKEND_<X>_SOURCED` flag. That is a **source edge**, so
`fm-backend.psm1` cannot load a bash adapter. But `fm-backend` sits on the
sourced path of **13 files**, including `fm-spawn`, `fm-teardown`, `fm-send`,
`fm-watch`, `fm-crew-state`, `fm-supervise-daemon` and `fm-session-start` — i.e.
most of the conventions page's wave 3.

The conventions page puts entrypoints in wave 3 and backends in wave 4. **That
ordering is inverted for this chain**: nothing that sources `fm-backend` can be
converted until the adapters it can select are converted.

Two viable resolutions, and the choice should be explicit:

- **(a) Package together** — `fm-backend` + `tmux` + `herdr` land as one unit
  (this document's W3-backend-core + W3-herdr), with `zellij`/`orca`/`cmux`
  following. This is the recommendation.
- **(b) Fail closed on unconverted adapters** — `fm_backend_source`'s PS twin
  imports `<name>.psm1` if present and otherwise returns the existing
  unsupported-backend refusal. `AGENTS.md` section 4 already treats an
  unsupported backend as a blocker, so the contract survives; but a captain whose
  `config/backend` names `zellij` would lose a working backend mid-transition.
  Acceptable only if stated in the release note.

**Evidence to demand:** for each of the five backends, a differential run of
`fm-spawn` proving identical meta-file contents and identical exit codes.

### R4 — Two undeclared cross-lib dependencies will break module scoping

Detailed in §2c. `fm-check-lib.sh` **unconditionally** calls five `fm_pr_*`
functions it never sources; `fm-busy-lib.sh` calls four `fm_backend_*`/`fm_meta_*`
functions unconditionally plus two behind `command -v`.

Bash tolerates this because every caller sources both files and the test harness
does too — so **the existing tests will not catch the failure**. A `.psm1`
resolves function names at its own scope; the first PS twin of `fm-check-lib`
will throw at runtime on a code path the unit tests cover only through a caller
that happened to import both.

**Recommendation:** `fm-check-lib` ships in the same package as `fm-pr-lib`
(W2-pr) with an explicit `Import-Module`. `fm-busy-lib` (W2-busy) keeps the
`command -v` cases as genuine `Get-Command` capability probes and gains an
explicit import for the four hard ones — which means W2-busy has a real
dependency on W3-backend-core for those four, and should either be deferred to
wave 3 or ship with the hard calls behind the same probe.

**Evidence to demand:** the PS twin imported **standalone** in a fresh `pwsh`
session, with every exported function invoked at least once — no reliance on a
caller having imported anything else.

### R5 — `backends/herdr.sh`'s fifo bridge has no faithful translation, and that is fine

Lines 3413–3486: `mktemp -d` → `mkfifo` → background reader writing to the fifo
→ `exec 9< "$fifo"` → line reads → `exec 9<&-` → `rm -rf`. Plus `exec 9<` at
3422 inside an `if`, a `reader_pid`, and a `reader_rc`.

PowerShell has no `mkfifo` and no fd-table manipulation. The conventions page
already prescribes the right answer (named pipes + `ReadAsync` +
`CancellationTokenSource`), and that is a **redesign, not a translation** — so
the differential harness cannot compare internals, only the emitted transition
records.

**Recommendation:** accept the redesign; contract the *output*, not the
mechanism. Specifically: identical normalized transition records, identical
return-code trichotomy (0 = fresh actionable edge, 1 = clean timeout, 2 = event
path unusable — `fm-backend.sh` callers branch on all three), and identical
timeout behavior at the boundary.

**Evidence to demand:** a timing-sensitive differential — same JSONL event
stream replayed into both implementations, asserting the same record *and* the
same return code for at least: fresh edge, clean timeout, unusable path, and a
pane that disappears mid-wait.

### R6 — `fm-pr-lib.sh`'s private-file gates are already vestigial on Windows

`fm-pr-lib.sh:268` and `fm-x-lib.sh:106,180` record that Git Bash mounts `/tmp`
`noacl,posix=0,usertemp`, so "every strict private-mode gate in this lib is
unsatisfiable" and the code already substitutes an ownership check for the
0700-bit check. The PS twin *could* implement real Windows ACL checks — which
would be **stronger** than both the bash-on-Linux and bash-on-Windows behavior.

That is a security-relevant behavior change wearing the costume of a port.

**Recommendation:** do not change it inside a conversion package. Port the
current semantics faithfully, and file ACL hardening as separate, explicitly
authorized work.

**Evidence to demand:** the differential must show the *same* accept/reject
verdict on the same fixture, including the cases the bash code currently accepts
because the mode bit is unobservable.

### R7 — `fm-windows-setup.sh` probably should not be ported

451 lines, 24 `jq`, whose entire job is materializing tracked symlinks on a
Windows clone by probing `MSYS=winsymlinks:nativestrict`. In a PowerShell-native
world the MSYS symlink emulation it works around does not exist, and
`New-Item -ItemType SymbolicLink` / junctions are direct.

A faithful translation would carry MSYS-shaped logic into a tree that has no
MSYS. **Alternatives, in preference order:** (a) rewrite natively as a much
smaller script, (b) keep it as bash behind a process boundary since it runs once
at clone time, (c) retire it if wave-5 cutover removes the need.

**Evidence to demand:** whichever is chosen, a clean-clone bootstrap on a
machine without Developer Mode, proving the tracked symlinks resolve.

### R8 — Signal semantics PowerShell cannot reproduce exactly

Three specific patterns, in descending danger:

- **`fm-watch.sh:520`** — `trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM`: a
  trap that *sets a flag and continues*, checked later in the loop. PowerShell
  has no async signal handler that mutates a running scope. `Console.CancelKeyPress`
  covers Ctrl-C only; there is no HUP or TERM on Windows at all.
- **`fm-watch-arm.sh:301–303, 394–396`** and **`fm-lint.sh:55–57, 198–200`** —
  named handlers mapping HUP/TERM/INT to exit codes **129/143/130**. Contract 1
  says exit codes are byte-identical, and these are load-bearing.
- **`fm-home-seed.sh:847,942`** — `trap seed_rollback EXIT` then `trap - EXIT`
  on success: a rollback protocol. `try/finally` is close but not identical
  (a `finally` runs on a terminating error where bash's EXIT trap also runs on
  a clean exit; the *disarm* step is the subtle part).

**Recommendation:** treat exit codes 129/130/143 as the contract and the signal
*delivery* as best-effort. Document per file which signals are unreachable on
Windows rather than pretending they were ported.

**Evidence to demand:** for each, an explicit statement in the twin's header of
which signals are unreachable, plus a differential proving the exit code on the
paths that *are* reachable (clean exit, error exit, Ctrl-C).

### R9 — `IFS`/TAB record parsing where empty middle fields matter

The conventions page already flags this (`-split` regex semantics differ from
`IFS`). Concentrations: `fm-pr-lib.sh` (36 `IFS=`), `fm-test-run.sh` (16),
`backends/herdr.sh` (14), `fm-teardown.sh` (8), `fm-watch.sh` (8),
`fm-config-inherit-lib.sh` (8), `fm-pr-check-migrate.sh` (7),
`fm-home-seed.sh` (7).

The durable wake-queue record is `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`
(AGENTS.md section 2) — an empty `payload` or `key` must survive the round trip.
`-split "`t"` drops nothing, but `.Split()` with default options *does*, and
`-split` with a regex metacharacter in the delimiter behaves differently again.

**Evidence to demand:** for every converted record parser, a fixture with an
empty first field, an empty middle field, an empty last field, and a payload
containing a literal tab — round-tripped bash→PS and PS→bash.

### R10 — 8 opt-in live e2e suites may not be portable at all

`fm-{claude-stop-autoarm,codex-continuity,grok-continuity,grok-stop,opencode-primary,pi-primary}-live-e2e` and friends drive **real credentialed vendor CLIs**. They cannot be differentially verified without burning quota, and their value is proving the *bash* integration works.

**Recommendation:** decide explicitly in wave 5 whether these are ported, kept as bash-only, or retired. Do not let them silently fall off the list — the retire-or-keep table the conventions page promises should name all eight.

---

## Appendix — what this analysis suggests is wrong or missing in `docs/powershell-port.md`

1. **Missing (highest value):** no rule for how a PS twin invokes a bash sibling
   during the transition. See R1. This should be a wave-1 deliverable.
2. **Wrong ordering:** waves 3 (entrypoints) and 4 (backends) are inverted for
   the `fm-backend` → adapter chain, which sits under 13 files. See R3.
3. **Ambiguous:** "`FileMode.CreateNew` is the atomic claim primitive" reads as
   "the lock is a file". The lock is a **directory** whose children are read
   directly by the watcher. See R2.
4. **Missing:** `backends/herdr-workspace-move.py` has no disposition. Only
   `herdr-eventwait.py` is named as absorbed.
5. **Missing:** no statement on the `noacl` private-file gates. Porting them
   "natively" silently *strengthens* a security check. See R6.
6. **Missing:** no acknowledgement that HUP/TERM do not exist on Windows, while
   contract 1 requires exit codes 129/143 to be byte-identical. See R8.
7. **Understated:** the hybrid scripts (5 files with `BASH_SOURCE` main guards)
   have no 1:1 file mapping — each becomes a `.psm1` + `.ps1` pair. The layout
   section's "same basename, side by side" rule needs an exception.
8. **Missing:** `fm-check-lib.sh` has no header comment to adapt.
9. **Worth adding:** the leaf-lib list and the "execute edges do not serialize"
   principle belong in the conventions page itself, since they are what make the
   fan-out safe.
