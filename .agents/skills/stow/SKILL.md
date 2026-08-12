---
name: stow
description: Sweep the current session for uncaptured durable knowledge, file it to disk, and curate the home's tiered, decaying startup memory before a context reset. Use when the captain invokes /stow (e.g. "/stow", "stow what you've learned"), before a session reset or context compaction, or periodically to keep operational memory current.
user-invocable: true
metadata:
  internal: true
---

# stow

Sweep this session for durable knowledge that exists only in conversation, then leave the next session with a compact current operating map rather than an accumulating journal.
Memory entries are tiered and decay between passes, and stale material retires to a cold archive instead of being deleted.
This skill writes only through the existing Firstmate ownership and write boundaries.

## Two port differences, up front

- **`bin/fm-startup-memory-budget.sh` is not ported.** `config/startup-memory-budget` is still materialized and validated by bootstrap, so the home has an effective budget; there is no command that estimates each file's token total against it. Estimate the totals yourself, conservatively, and say that the figure is an estimate. Never claim a precise accounting you did not compute.
- **`bin/fm-stow-cascade.sh` is not ported**, and neither is any cross-home write path (`AGENTS.md` section 14). A `/stow` here curates THIS home only. If registered secondmates exist, say so in the receipt and leave their memory to their own `/stow`; do not reach into another home's files.

Everything else below - the tiers, the markers, the clocks, the archive, the offload rules, the receipt - is ordinary file work and ports unchanged.

## Memory tiers and entry markers

Markers are compact trailing HTML comments, deliberately cheap because marker bytes are counted content:

- `<!--a:YYYY-MM-DD-->` - an `aging` entry; the embedded date is its last-reinforced date.
- `<!--p:YYYY-MM-DD-->` - a `perishable` entry; the embedded date is its last-reinforced date.
- `<!--P-->` - an explicitly `pinned` entry in a file whose default tier is not `pinned`.
- `<!--g-->` - migration-only: an unconfirmed legacy entry that has consumed its one grace cycle, carrying no date because grace is not reinforcement.

```markdown
- Treehouse pool slots share one repo, so workers must create their task branch before editing. <!--a:2026-08-03-->
- The captain works from Windows in the morning; keep replies short before 09:00. <!--p:2026-08-12-->
- Never force teardown past a refusal. <!--P-->
```

The tier names say what the pass does with an entry:

- `pinned` - no clock is ever read for it: exempt from decay and from budget eviction, changed only through inspect-then-update when the captain or reality changes it, except that an explicit per-item captain approval may offload it under the flow below.
- `aging` - it must re-prove itself: an entry 30 days or older since its last-reinforced date is stale, and a stale entry is re-validated (date refreshed) or archived, never kept by inertia alone.
- `perishable` - it is stored expecting disposal: an entry 7 days or older since its last-reinforced date is stale, and its prose must name a checkable expiry condition, such as a backlog id, a version floor, or a dated expectation.
  An admitted durable entry that cannot name a checkable expiry condition is not `perishable` and must be stored as `aging`.

Marking rules:

- Tier defaults are file-scoped: entries in `data/captain.md` default to `pinned` because preferences and authority boundaries do not age, and entries in `data/learnings.md` default to `aging` because operational facts must re-prove themselves.
- An entry matching its file's default carries no marker at all; every `aging` and `perishable` entry always carries its dated marker, whose letter names the tier.
- Marker and header-pointer bytes count toward the startup-memory budget: the pass's own bookkeeping is costed content, never free, which is why the spellings above are as short as they are.
- Each memory file's header carries at most a one-line pointer naming this skill as the scheme owner, such as `<!-- memory tiers: see the stow skill -->`.
  This skill text is the single owner of tier semantics, marker spellings, and clocks, and no memory file header may restate them.
- A pre-existing missing or hand-dropped marker is never grounds for destructive treatment: it means the file's default tier.

Decay advances only when a pass runs, so a home stowed less often than a clock experiences that clock at its stow interval.

## Required startup-memory pass

Every `/stow` invocation performs this complete pass, even when the session contains no new finding:

1. Read `config/startup-memory-budget` and record the effective budget.
   Estimate each memory file's token total conservatively, and record that these are estimates rather than a tool's accounting.
   If the setting is malformed, do not infer the default: report that concrete exception and do not call the session reset-safe.
2. Read every current memory file completely: `data/captain.md` and `data/learnings.md`.
   Treat an absent local file as absent, not as an invitation to manufacture content.
   `data/captain-shared.md` has no propagation path on this port; if the file exists because a Linux firstmate wrote it into a shared home, count it and leave it byte-identical, reporting any needed change as an ownership exception rather than editing it.
3. Build one whole-file retention plan before editing, ordered by likelihood of informing a future session.
   Keep in always-loaded memory only current captain preferences, authority and safety boundaries, recurring working style, fleet-wide or frequently relevant operating facts, and concise pointers that are expensive to rediscover.
   Prefer offloading current but conditional, narrow, project-specific, or context-specific material to a live on-demand owner, and archive stale, superseded, or low-recurrence material to the cold tier.
4. Reinforce and stamp.
   Refresh an entry's last-reinforced date to today only when this session actually exercised, confirmed, or re-derived it.
   **Hard rule: reinforcement requires independent evidence from this session that you can name in the receipt; plausibility, importance, prior knowledge, and the entry's own text are not evidence.**
   For an unmarked `data/learnings.md` entry with no such evidence, append `<!--g-->` and retain it for this entire pass; never stamp or archive it during that same invocation.
   Stamp each newly written entry with today's date and its tier, and admit a new `perishable` entry only with its named checkable expiry condition in the prose.
5. Evaluate every dated entry against its tier clock.
   Re-validate a stale `aging` entry from current evidence and refresh its date, or archive it.
   Re-confirm a stale `perishable` entry against its named condition: still open means refresh the date, while resolved, expired, or no longer checkable means archive it in this pass.
   Promote `perishable` to `aging` when its condition keeps proving durable past its expected life.
   `pinned` is exempt from this automatic decay step entirely.
6. Consolidate every memory file as needed, not only the file apparently related to a new finding.
   Prefer one concise current rule or authoritative pointer over duplicate prose.
   Archive completed incident chronology, stale versions and paths, transient task state, resolved alternatives, and report-sized procedures.
   Never plainly remove a unique current fact: every such exit must archive it with provenance in the cold tier or relocate it to a live on-demand owner.
7. When the total is still over budget after decay and consolidation, make aggressive reduction the default, in this order: archive every stale, superseded, or low-utility entry eligible for archival; consolidate tighter; run the offload sweep below and relocate every eligible non-pinned conditional entry into an already-existing allowed owner only after that owner holds it; then archive eligible `aging` entries oldest-reinforced-first until within budget.
   Before evicting anything, total the eligible pool and check that archiving all of it would reach the budget; when even that cannot, skip the eviction rung entirely and carry the concrete inability to the final step, naming the exempt pinned floor that crowds out the budget.
   Automatic processes never move a `pinned` entry.
8. Re-estimate after the complete pass.
   Finish at or below the effective budget, or open a concrete captain decision before ending the pass.
   In that last-resort case, create one captain-held backlog item that names the shortfall and each relevant pinned entry, with exactly these options: raise the effective budget, or explicitly approve offloading or trimming a named pinned entry.
   Never end a pass over budget as an accepted exception.

A net increase is allowed only for a genuinely new current fact with no stronger owner.
Never describe the session as reset-safe while the memory total is over budget or an exception is unresolved.

## The cold tier: data/memory-archive.md

Stale never means deleted: pruning an entry from a memory file always means moving it to `data/memory-archive.md`, this home's append-only, never-injected cold tier, gitignored with the rest of `data/` and never counted by the budget.
Each archived entry keeps its provenance under a dated pass heading: source file, tier, last-reinforced date, and the reason it left.

```markdown
## 2026-08-12 stow
- (from learnings.md, tier: perishable, reinforced: 2026-06-30) The herdr preview strips styling from its capture... [archived: unreinforced 43d]
```

Reasons include `unreinforced <N>d`, `budget oldest-first`, and `legacy-unvalidated`.
Archiving is a move, not a removal, and recovery is a search plus a copy back with no tooling.
Each home keeps its own archive, the archive never cascades, and truncating a grown archive is a captain decision, not a mechanism.

## Over-budget offload to on-demand owners

Decay handles staleness over time; offload handles scope: knowledge that is current and durable but relevant only in a nameable context, and therefore wrong to pay for in every session.
For the offload sweep's evaluation only, each entry has exactly three outcomes decided in this fixed order:

1. Archive, the time outcome, always evaluated first: staleness is judged before scope.
2. Offload, the scope outcome, asked only of current durable entries: is this needed in nearly every session, or only in a nameable context?
3. Keep, the default: current, durable, and either fleet-wide-relevant or safety-relevant even in sessions that never name the topic.

The offload sweep runs only when the pass is still over budget after decay archiving and consolidation.
Every test must hold for a candidate: durable (not `perishable`, not stale), non-pinned and dated, conditional with a one-line nameable trigger, roughly 50 estimated tokens or more, a destination that fits its privacy, and not already preserved by a stronger owner.

### Destinations

**Hard rule: the stow pass never creates or writes a tracked firstmate-win skill.**
Every skill this offload produces is user-owned and local, excluded through this home's repository-local exclude file (`git rev-parse --git-path info/exclude`), never through `.gitignore`.
Contributing a lesson to the tracked template is a separate deliberate captain action, never automatic.

- A user-owned local skill: a directory under `.agents/skills/<freeform-name>/` whose path is appended to this checkout's `info/exclude`.
  Validate before and again at migration that the destination is absent from the git index and collides with no existing file, and verify the future `SKILL.md` path is ignored with `git check-ignore` before writing any private content.
  The harness still lists and loads it, because skill discovery scans the filesystem and ignores git status.
  Its precise, condition-stated `description` line is its entire trigger; it gets no `AGENTS.md` declaration, because `AGENTS.md` is shared tracked material.
  **One Windows caveat:** if `.claude/skills` on this machine is a synced COPY rather than a real link (`AGENTS.md` section 2), a new skill written under `.agents/skills/` is not visible to Claude until the copy is re-synced. Run `bin/fm-setup.ps1` after creating one, then confirm the skill appears, and never report the destination live until you have.
- An already-existing user-owned local on-demand note with an established trigger, after confirming it is untracked and private.
  The pass may add to that existing owner but never creates a new note or trigger for this purpose.
- A project's existing committed `AGENTS.md`, for project-intrinsic knowledge, through a normal crewmate ship task using `bin/fm-ensure-agents-md.ps1` and the project's registered delivery mode.

Forbidden destinations: any tracked firstmate-win skill; this repo's own `AGENTS.md` or `CONTRIBUTING.md`, which are shared tracked material; `docs/` alone, which is never loaded on demand; and any committed surface for private content.

### Flow: reduce, approve, migrate, remove

1. Reduce non-pinned material now, relocating each eligible candidate only by adding it to an already-existing allowed owner, then confirming that owner holds the quoted entry before removing the memory entry.
   A destination that needs creation or uncompleted delivery is not live and cannot count as relief.
2. Propose pinned relocation only, as a durable captain-held backlog item, and require explicit approval for that named item before any migration.
   If the captain never answers, nothing migrates and the item persists, but it is never treated as budget relief.
3. Migrate an approved candidate outside this pass, re-validating index absence and filesystem collision, writing the exclude rule and verifying the ignore before creating any content, and removing both the content and the rule if any step fails.
4. Remove the memory entry only once the destination is live.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.**
   Look for operational learnings, captain preferences expressed in passing, project-intrinsic facts, standing decisions, and undone next steps.
2. **Route each finding using `AGENTS.md` section 6's knowledge-routing list.**
   That section is the source of truth for destinations; do not re-derive or duplicate the mapping here.
   Note the port's extra destination: knowledge about how to BUILD this port goes to `CONTRIBUTING.md` or a `docs/` note through a normal branch and merge, never into memory.
3. **Write within the existing boundaries.**
   - Captain preferences and fleet-local operational facts belong in the destination `AGENTS.md` selects, after the required whole-file curation pass.
     Create `data/learnings.md` only for a genuinely new local learning with no stronger owner.
   - Project-intrinsic knowledge never goes directly into a project's `AGENTS.md`; route it through a normal ship task.
   - For task-scoped notes, inspect the item with `bin/fm-backlog.ps1 show <id>` first, classify the change as new, duplicate, superseding, or obsolete, then replace the considered body rather than appending.
   - File each undone next step as a queued backlog item with a genuine blocker when applicable.
4. **Use inspect-then-update.**
   For every retained fact, ask which current statement it supersedes, whether it can be a one-sentence rewrite, and whether a stale entry should be refreshed, archived, or routed to an existing stronger owner.
   A stale unique fact is never deleted, only archived.

## Completion receipt

Report the outcome in plain captain-facing language with all of these facts:

- the effective startup-memory budget and the estimated totals before and after, labeled as estimates;
- one or more actions for each of `data/captain.md` and `data/learnings.md`, using only `unchanged`, `added`, `rewritten`, `pruned`, `routed`, `archived`, or `proposed-offload`;
- each durable finding filed outside memory and its authoritative owner;
- each archived entry's reason, and each offload's live destination and actual relief;
- every unresolved exception, and every concrete captain decision opened for an over-budget result;
- that this pass covered this home only, naming any registered secondmate whose memory was not touched;
- whether the session is safe to reset, only when all durable findings are captured and the post-pass result is within budget with no exception.

Do not hide an over-budget result behind a reset-safe claim.
