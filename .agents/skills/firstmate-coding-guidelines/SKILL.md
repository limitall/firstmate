---
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate-win's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-win task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, trigger hygiene for new skills, and this repo's PowerShell, test, and analyzer bar.
user-invocable: false
metadata:
  internal: true
---

# firstmate-coding-guidelines

Load this before changing firstmate's shared, tracked material, as defined by `AGENTS.md` section 1.
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md) is the full contributor contract for this port and is the authoritative owner of the PowerShell rules, the layout, the cross-area composition rules, and the checks.
**Read it before your first change here.**
This skill owns the knowledge-placement and instruction-surface discipline that keeps `AGENTS.md` from growing into a manual, plus the short list of repo rules that bite hardest.

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the firstmate AGENT need this on every session or every turn to operate?
   If yes: `AGENTS.md`, inline.
2. Does the agent need it only in a nameable situation - a spawn, a recovery, a specific wake type, a specific lifecycle step?
   If yes: an agent-only skill under `.agents/skills/`, plus a one-line trigger pointer left inline in `AGENTS.md` (usually section 13).
3. Is it how to BUILD or change this port - a PowerShell idiom, a test rule, an analyzer rule, a cross-area binding hazard?
   If yes: `CONTRIBUTING.md`, or the `docs/` note for that area when it needs more than a few lines.
   It does not belong in `AGENTS.md`, which every session pays for whether or not it ever touches the port's own code.
4. Is it the design rationale for one area - what was ported, what was replaced, what was deliberately left out?
   If yes: that area's `docs/*.md` note, which `CONTRIBUTING.md` indexes.
5. Is it a claim about what has actually been RUN on Windows?
   If yes: `docs/windows-e2e-evidence.md`, with the date and the command. Nothing else may claim a Windows behavior is proven.
6. Is it mechanics - exact flags, exact parameters, exact paths?
   If yes: the script's own comment-based help plus its `-h` output, not prose in `AGENTS.md`, a skill, or a second doc.

Stop at the first tier that answers yes.
Do not place a fact at a more convenient tier than the one this tree gives you.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly once.
Every other mention of it is a one-line cross-reference, never a restatement.
A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a "don't forget X" placed exactly where forgetting X is costly.
Restating the contract's substance a second time is not allowed: the two copies will drift the moment only one is edited.
When you touch a contract, patch, replace, or prune the owner's existing language rather than appending a new clause, then search the repo for its other mentions and update the cross-references rather than duplicating the change into a second full copy.

This rule has a mechanical twin in this port that has already cost real tests: **two areas defining one function name is silent, not an error.**
`CONTRIBUTING.md` owns that rule and the check that catches it.

## Inline-stub pattern

When content moves out of `AGENTS.md` into a skill, decide what stays behind by asking one question: what must survive with no skill loaded?
That is the trigger condition for loading the skill, plus any safety-critical fact that fires on a wake the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.
Do not leave a partial restatement behind "just in case"; a partial copy is exactly the duplication the one-owner rule forbids.

## Size discipline

Apply the decision tree above to every line you are about to add to `AGENTS.md`.
If an addition needs more than a few lines of conditional detail (detail that matters only in a specific situation) or reference detail (a wire format, an exact schema, historical rationale), you are almost certainly adding it to the wrong file.
`AGENTS.md`'s token cost is paid by every session, every time, whether or not that session ever hits the situation the new lines describe.
A skill's cost is paid only by the sessions that actually load it.
When in doubt, write the fact into the skill or doc first by patching that owner's existing language, and add only the one-line trigger to `AGENTS.md`.

## Trigger hygiene

A new skill is dead weight if nothing loads it.
Every new skill needs its load trigger declared inline: section 13 for agent-only reference skills, or the relevant operating section for anything else.
State the trigger as a condition ("load before X", "load on Y wake"), never as a vague pointer.
Every skill directory must contain a `SKILL.md` with YAML front matter carrying at least `name` and `description`; `tests/FmContract.Tests.ps1` fails a skill that does not, and `bin/fm-doctor.ps1` reports it.
Briefs for tasks that touch this repo's own tracked material should tell the crewmate to load this skill; firstmate adds that instruction to firstmate-win briefs by hand.

## Recording an absent capability

This port is a kernel port, so a Linux skill whose subject matter does not exist here is **kept as a short skill that says so**, never deleted.
A quiet omission hides the gap from the captain; a stub makes it answerable.
Such a skill states what is missing, what the consequence is, what to do instead, and what would have to land for it to become real.
It also appears in `AGENTS.md` section 14, which is the always-loaded list of what this port does not have.
When a capability genuinely lands, update `docs/windows-e2e-evidence.md` first, then the skill, then section 14 - in that order, because the evidence is what makes the other two true.

## Repo rules that bite hardest

`CONTRIBUTING.md` is the owner of all of these; they are repeated here only because forgetting one is expensive.

- One full sentence per line in tracked Markdown; never wrap multiple sentences onto one physical line.
- Plain dash `-`, never an em dash.
- Never add an agent name as a commit co-author.
- PowerShell 7 only, `Set-StrictMode -Version Latest`, and no Linux dependency of any kind - no WSL, no Git Bash, and never shelling out to `sh`, `sed`, `awk`, `grep`, or `jq`.
- Every public function gets Pester tests, including its refusal paths, and you run the whole `tests/` directory, never one file.
- `Invoke-ScriptAnalyzer` must report zero findings at every severity; the Pester suite runs that same repo-wide sweep, so `Invoke-Pester` alone fails on a new finding.
- Tests must exercise behavior through a public interface and must never assert implementation-source bytes.
- A degradation test stops testing degradation once the owner lands; check that such a test still fails when you revert the code it guards.
