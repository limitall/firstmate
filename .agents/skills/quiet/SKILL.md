---
name: quiet
description: >-
  Quiet supervision mode - NOT AVAILABLE on this Windows port.
  Load when the captain invokes /quiet or /quiet off, or asks for quiet mode or fewer routine updates while they stay in the session, so you can tell them plainly what this machine already does and what it cannot.
user-invocable: true
metadata:
  internal: true
---

# quiet - not available on this port

**Quiet mode is not ported.**
On the Linux firstmate it is away mode with a different exit rule: the same sub-supervisor daemon handles routine wakes outside the session and escalates only what matters, but ordinary chat does not end it - only `/quiet off` does.
This port has no away mode (see `afk`), so there is no daemon to make quiet.
This skill exists so that typing `/quiet` gets a plain answer rather than silence; `AGENTS.md` section 14 lists the gap.

Do not simulate it.
Do not start a background loop, do not skip or defer notifications, and do not write a `state/.afk` flag in any mode.
Each of those would leave firstmate believing something is handling wakes that nothing is handling.

## What to tell the captain

Most of what they are asking for is already how this machine behaves: `AGENTS.md` section 9 keeps routine progress, retries, and internal mechanics out of chat and batches non-urgent updates.
What quiet mode adds on Linux is a helper outside this session that absorbs routine notifications without spending the session's turns, and that is the part this port cannot do.
Say so in section 9 language, something like:

> Captain, there is no separate quiet mode on this machine, and most of it is already how I work: routine progress stays out of this chat, and I only bring you finished work, decisions, failures, and anything that needs a login. What I cannot do here is hand routine notifications to a helper outside this session, so they are still handled here as they arrive.

`/quiet off` has nothing to turn off; say that in one line and carry on.
Nothing about approval authority changes either way.

## What would have to land

Away mode first, and `afk` names its three missing pieces.
Once that daemon exists, quiet mode is a mode line on its flag plus a different exit rule, which is a small change on top.
The Linux design is kunchenguid/firstmate#4337, and the Linux skill exactly as it arrived with the merge is recoverable with `git show b182d0f9:.agents/skills/quiet/SKILL.md`.
When it lands, `docs/windows-e2e-evidence.md` records the evidence first, then this skill, then `AGENTS.md` section 14.
