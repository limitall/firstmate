---
name: firstmate-codexapp
description: >-
  Codex Desktop coordination and the Codex App backend - NOT AVAILABLE on this Windows port.
  Load only when the captain asks to drive a visible Codex thread or evaluates a Codex App request, so the refusal is explained rather than looking like a bug.
user-invocable: false
metadata:
  internal: true
---

# firstmate-codexapp - not available on this port

**Codex is not a verified harness here, and the Codex App backend is not ported.**
`claude` is the only harness this port may dispatch, on the `herdr` session provider (`AGENTS.md` section 4, `harness-adapters`).
There is no Codex adapter, no Codex Desktop thread coordination, and no host-tool smoke evidence to reconcile.

## Why

Codex's firstmate integration is three separate things, and none of them exists here:

1. **The pane adapter** - launch, interrupt, exit, the `$<skill>` invocation popup and its settle timing, and the readiness checks that keep a send from being swallowed. All of it is empirical per-harness knowledge gathered on Linux.
2. **The hook surface** - a Stop hook that blocks on exit 2, and a watcher protocol built on bounded foreground checkpoints rather than a re-arm, because Codex cannot reason while a foreground tool call is running. This port's supervision is Stop-hook-and-re-arm shaped, which is the Claude shape.
3. **The visible-thread coordination** - driving a desktop app's thread rather than a pane.

Each would need Windows evidence of its own before a worker could be dispatched onto it, and none exists.
Launching an unverified adapter produces the specific failure this bar exists to prevent: a pane that looks healthy and a supervision chain that silently never fires.

## What to do

- **If the captain asks to run work on Codex:** tell them under `AGENTS.md` section 9 that the requested worker runtime is not available on this machine, use `claude` for the work in front of you, and ask only whether they want Codex investigated for a future port. Do not pause current work for that answer, and never launch it to see what happens.
- **If `config/crew-harness`, `config/secondmate-harness`, or a `config/crew-dispatch.json` profile names `codex`:** bootstrap reports the profile as invalid and `harness-adapters` owns the fallback. Report it, use `claude`, and do not select around it.
- **If a `state/<id>.meta` record names `harness=codex`:** that task belongs to another home. Do not adopt it, steer it, or tear it down.

## What would have to land

The three surfaces above, each proven on Windows: that Codex runs in a herdr pane and registers its agent state, that its Stop hook fires and blocks, and that its checkpoint-shaped watcher protocol works alongside this port's watcher.
`harness-adapters` owns the general shape of that verification task, and `docs/windows-e2e-evidence.md` is where its evidence would go before any dispatch relied on it.
