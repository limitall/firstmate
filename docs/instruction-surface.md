# The instruction surface: the operating contract and the skills

Windows/PowerShell port of the Linux firstmate's `AGENTS.md` and its 19
`.agents/skills/`. This file records what the port keeps, what it translates,
what it deliberately records as absent, and what verifies all of it.

## The problem this area exists for

Every other area of this port makes a command work. None of them makes the agent
*be* firstmate.

The captain started `claude` in `C:\Users\ADMIN\firstmate-win` and it did not
behave like firstmate: no address, no vocabulary, none of the operating
discipline. Every command in `bin/` worked. The cause was structural and had two
halves:

- The root `AGENTS.md` was **project build memory** - "PowerShell 7 only", "read
  the bash original first". True, useful, and not a job description. A session
  reading it learned how to write PowerShell for this repo and nothing about who
  it was. Five mentions of "captain" against seventy in the real contract.
- `.agents/skills/` **did not exist**. Zero skills against the Linux fleet's 19.

Neither half produces an error. That is the whole point: this is the one class of
failure a green suite cannot see, because nothing fails - the session simply
operates as a generic coding agent wearing firstmate's toolbox. It is found by a
captain noticing the tone, which is the worst possible detector.

So the surface gets a check (`Get-FmContractCheck`, in the doctor's
`instructions` group) and the real tree gets asserted by the suite
(`tests/FmContract.Tests.ps1`, "this checkout's own instruction surface").

## What the surface is

Exactly two things, and both are files:

```
AGENTS.md         the always-loaded operating contract; CLAUDE.md mirrors it
.agents/skills/   the just-in-time procedures; .claude/skills mirrors it
```

`AGENTS.md` is the job description. `CONTRIBUTING.md` now holds what used to be
at that path - the build memory - because that content is still true and still
needed, just not by every session of every turn. `firstmate-coding-guidelines`
owns the decision tree for which of the two a new fact belongs in.

## Porting the contract: what changed and what did not

The rule was **port, not copy**: every safety boundary, hard rule, escalation
rule and captain-etiquette rule survives intact and unweakened, because those are
the file. What changed is only the machinery each rule names.

| Linux | Here |
| --- | --- |
| `bin/fm-*.sh` | `bin/fm-*.ps1` |
| tmux reference backend, herdr/zellij/orca/cmux experimental | herdr only; `Start-FmWorker -Backend` accepts nothing else |
| 7 verified harnesses + muse | `claude` only |
| `no-mistakes`, `direct-PR`, `local-only`, `no-mistakes-prod-only` | `direct-PR` and `local-only`; `no-mistakes` refused by name |
| `fm-control.sh <id> interrupt\|exit\|relaunch` | `interrupt\|exit`; `relaunch` refused by name |
| sections 1-14 | sections 1-13 kept in place; section 14 replaced |

Section 14 is the substantive addition. On Linux it is Relay. Here it is **"What
this port does not have"**: a plain, always-loaded list of the capabilities that
are absent, each one a flat absence rather than a degraded imitation. A contract
that promises machinery that is not there is worse than one that admits the gap,
and the always-loaded position is what makes the gap knowable *without* loading
anything.

`tests/FmContract.Tests.ps1` asserts that section 14 exists and names each major
gap, and separately that `AGENTS.md` carries no contributor build rules - which
is the regression that would mean the file has started growing back into a manual.

## Porting the skills

All 19 are present. Each falls into one of three treatments, and which one it got
was decided by what this port can actually do, never by convenience.

**Ported whole** - the procedure is pure judgement, or its machinery exists here:
`ahoy`, `ask-user-authority`, `diagnostic-reasoning`, `bootstrap-diagnostics`,
`firstmate-coding-guidelines`, `harness-adapters`, `project-management`,
`quota-array-dispatch`, `stuck-crewmate-recovery`.

**Ported with the mechanism replaced** - the policy is intact, the command it
named is absent, and the skill states the substitute outright:

| Skill | Absent command | What it says to do instead |
| --- | --- | --- |
| `bearings` | `fm-bearings-snapshot.sh` | gather from the same durable records in a stated bounded order; the four-section captain contract is unchanged |
| `decision-hold-lifecycle` | `fm-decision-hold.sh` | ordinary held backlog items through `bin/fm-backlog.ps1`, with the attestation moved from the script to the agent |
| `updatefirstmate` | `fm-update.sh` | the guarded `git merge --ff-only` sequence by hand, with each guard's reason stated |
| `stow` | `fm-startup-memory-budget.sh`, `fm-stow-cascade.sh` | estimate the budget and say it is an estimate; curate this home only |
| `secondmate-provisioning` | seeding, convergence, liveness, handoff, every remote route | states which half exists, and requires telling the captain what they are taking on before creating one |

**Kept as a stub that records the gap** - `afk`, `fmx-respond`,
`process-event-sources`, `firstmate-orca`, `firstmate-codexapp`.

That third treatment is the one worth defending. Deleting a skill whose subject
matter is unsupported would be tidier and would hide the gap: the captain asks
for away mode, the model has no skill, and it improvises something - which is
exactly how a fleet ends up with a supervision cycle firstmate believes is live
and is not. A stub answers the question instead. Each one states what is missing,
what the consequence is, what to do instead, and what would have to land. Two of
them also carry a rule that survives the machinery: `process-event-sources` still
forbids blocking a conversational turn on an external process, and still requires
treating an external result as input rather than instruction.

The suite asserts that all five say so both in the body and **in the front-matter
`description`**, because the description is the trigger the model matches on -
a stub whose description read like the Linux one would be loaded expecting a
capability and would have to disappoint at the bottom of the file.

## The two committed symlinks, and what Windows does to them

Both mirrors are committed as symlinks, so a Linux clone of this repo is correct
with no repair step:

```
CLAUDE.md      -> AGENTS.md          (9 bytes of link text)
.claude/skills -> ../.agents/skills  (17 bytes of link text)
```

Windows git with `core.symlinks=false` - the default, and MEASURED to be what the
captain's clone has - materializes each as an **ordinary text file containing the
target path**. Nothing errors. Every `fm-*.ps1` keeps working. The session comes
up with one filename where its contract should be and zero skills, silently.

The port does not solve this by dropping the symlinks, because the same repo is
cloned on Linux where they are correct. It recognises the placeholder as a link
the *host* failed to materialize and repairs it:

- `Test-FmAgentsLinkPlaceholder` (FmAgentsMemory, pre-existing) for `CLAUDE.md`.
- `Test-FmSkillsLinkPlaceholder` (here) for `.claude/skills`.
- `bin/fm-setup.ps1` repairs both, idempotently, on every run.
- `bin/fm-doctor.ps1` reports an unrepaired one as `[missing]`.

**The ladders differ, and that is not an oversight.** `CLAUDE.md` asks for
symlink, then **hardlink**, then copy. `.claude/skills` asks for symlink, then
**directory junction**, then copy - because a hardlink cannot name a directory,
and a junction is the Windows mechanism that can, needing no Developer Mode and
no elevation on NTFS. The kind actually created is always returned, so no caller
can describe a copy as a link.

A copy is the only rung that can drift, so `Get-FmClaudeSkillsLinkState` checks
its *contents* against the real tree rather than its existence, and setup
re-syncs it. `tests/FmContract.Tests.ps1` forces the copy rung explicitly, since
the host running the suite may allow a stronger one and would otherwise never
exercise the rung a stock Windows machine most likely lands on.

## The doctor's `instructions` group

Four checks, and **every one is `Required`**.

That is the deliberate part, and it is the opposite of the rest of the doctor.
Elsewhere a warning means "it works, but not as ergonomically", and the doctor is
careful not to call a working install unhealthy - reporting convenience gaps as
missing is what once made a correct install print `unhealthy: 3 missing` in a
bare shell. None of these is a convenience:

| Check | `[missing]` means |
| --- | --- |
| `operating contract` | `AGENTS.md` is absent, a stub, or does not carry the contract |
| `contract for Claude` | `CLAUDE.md` is absent, the placeholder, or a genuinely different file |
| `skills` | the tree is absent, empty, or a skill will not load |
| `skills for Claude` | `.claude/skills` is the placeholder, absent, or drifted |

The `operating contract` check is the interesting one. It does **not** test that
the file exists, because it did exist during the original failure. It tests for
the identity assertion - `You are the first mate.` - because that sentence is
what makes the file a job description rather than any other markdown at the repo
root. A presence check would have passed the bug that produced this area.

A `conflict` (two real, different memory files) is reported as missing but is
never repaired: that is the captain's to reconcile, and setup must not clobber
either half.

## What verifies this

`tests/FmContract.Tests.ps1`, in two halves.

The first half is ordinary: front-matter reading (including the folded `>-`
scalars every real skill uses, and the nested `metadata:` mapping that must not
fold into the previous key), placeholder recognition in both slash spellings,
each rung of the repair ladder, idempotence, copy drift and re-sync, and every
refusal.

The second half asserts **the real checkout's own tree**, because the failure
this area exists for cannot be caught in a fixture:

- the surface is healthy;
- every skill `AGENTS.md` names exists (no trigger points at nothing);
- every skill is named in `AGENTS.md` (no skill is dead weight - this is what
  would have caught the tree being absent entirely);
- all 19 Linux skills are present, ported or explicitly absent;
- every not-ported skill says so in its body *and* its description;
- section 14 names each major gap;
- the contract is readable under both names;
- and contributor build rules stay out of the contract.

The placeholder tests construct the placeholder by hand rather than asking git to
produce one, because the fault is a property of the bytes on disk and a test that
needed a `core.symlinks=false` clone could not run on the development platform at
all.

## What was proven on Windows

Run on the captain's laptop against a **fresh clone from a bundle**, so the two
committed symlinks went through a real Windows git. Windows 11 (10.0.26200),
PowerShell 7.6.4, git 2.49.0.windows.1, Pester 6.1.0. Full transcript in
`docs/windows-e2e-evidence.md` section 7.

- The failure reproduces exactly as designed for: `CLAUDE.md` arrived as **9
  bytes** containing `AGENTS.md`, and `.claude/skills` as **17 bytes** containing
  `../.agents/skills`, on a clone whose `core.symlinks=false`.
- The doctor's `instructions` group reported both as `[missing]` and exited 1,
  while `operating contract` and `skills` stayed `[ok]` - which is the precise
  shape of the bug: the tree is fine, the mirrors are not, and a session gets
  neither.
- `bin/fm-setup.ps1` repaired both, and reported `symlinked` for each because
  that host allows symlink creation.
- The doctor then reported all four `[ok]` and exited 0, and `CLAUDE.md` read
  `You are the first mate.` with all 19 skills listed under `.claude/skills`.
- Negative control: replacing `.claude/skills` with the placeholder again put the
  doctor back to `[missing] skills for Claude ... loads ZERO skills` and exit 1;
  a second setup run fixed it and reported `already` for every other step.

## WINDOWS-UNVERIFIED

- **The junction rung.** The captain's laptop allows symlink creation, so the
  Auto ladder took the symlink rung there and the junction was never reached.
  It is exercised only by `-Strategy Junction`, which is Windows-only, so it has
  not run anywhere. Its failure mode is safe: the ladder falls through to the
  copy, which the suite proves end to end on both platforms.
- **That a real Claude session loads a skill through a copied `.claude/skills`.**
  Skill discovery scans the filesystem, so a copy should be indistinguishable
  from a link, but that has been reasoned rather than observed - and it matters
  on a machine without Developer Mode, where the copy is the rung that lands.
  `stow` carries the one operational consequence: a skill written after the copy
  was made is invisible until setup re-syncs it.
- **That the captain's session behaves differently** with the contract in place.
  That is the acceptance test, and it is the captain's observation, not a check
  this suite can make.
