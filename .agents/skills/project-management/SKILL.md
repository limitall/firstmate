---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Commands

| Operation | Command |
|---|---|
| clone and register an existing project | `bin/fm-project-add.ps1 <name> <source> [-Mode <posture>] [-Yolo on\|off] [-Description <text>]` |
| create a new LOCAL project and register it | `bin/fm-project-create.ps1 <name> [-Mode <posture>] [-Description <text>]` |
| read a project's registered posture | `bin/fm-project-mode.ps1 [-Raw] <name>` |
| remove a clone and reconcile the registry | `bin/fm-project-remove.ps1 <name> -Approved` |
| refresh every registered clone | `bin/fm-fleet-sync.ps1` |

Each script's comment-based help and `-h` output own its exact parameters; read the one you are about to run rather than trusting this table for flags.
Never issue a raw `git clone`, `Remove-Item`, or registry edit around these guards.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
`bin/fm-project-mode.ps1` owns the registry format and parser contract.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect `data/secondmates.md` and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's routing rules; if an existing scope owns that domain, route the operation there instead of creating a duplicate main-home clone.
Absence from the main registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery posture, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

The registry records the project's standing posture, which is the captain's default for the work rather than any task's answer; `AGENTS.md` section 7 owns how each task's concrete mode and yolo are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.

- `direct-PR` pushes and opens a PR. **This is the strongest posture this port can actually run.**
- `local-only` has no required remote or PR and lands only through `bin/fm-merge-local.ps1`.
- `no-mistakes` and `no-mistakes-prod-only` remain valid registry values, because a home may be shared with a Linux firstmate that can run them, but **this port refuses to dispatch a task in `no-mistakes` mode** (`AGENTS.md` section 7).

Choosing a posture on this machine therefore has one extra step.
A project with no remote defaults to `local-only`, unchanged.
For a remote-backed project, do not silently register `no-mistakes-prod-only` as the Linux default would: tell the captain that this machine cannot run the validation pipeline, offer `direct-PR` as the posture that works here, and register `no-mistakes-prod-only` only if they say the project will also be worked from a Linux home and they want that recorded.
State the resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch.
Existing registry entries keep the meaning they already have and are never migrated or reinterpreted, so a legacy entry with no bracket stays `no-mistakes`.

The optional `+yolo` posture changes routine approval authority but does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the complete authority boundary and exceptions when it is on.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Run `bin/fm-project-add.ps1`, which clones into `projects/<name>` and writes the registry entry only after the destination is known to be unused, and which rolls back its own clone if registration fails.
A `direct-PR` project needs an `origin` remote.
A `local-only` project may have no remote.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally with `bin/fm-project-add.ps1` and register it.

`bin/fm-project-create.ps1` creates a **local** repository only.
It makes no GitHub call by design, so the captain's request to create a local project authorizes it fully, and it never authorizes an unmentioned remote.

## Initialize

There is no `no-mistakes init` step on this port, because the mode it configures is refused here.
Do not run one, and do not create a commit merely because a project was added.
If the captain wants that project initialized for a Linux home, that is work for that home, not this one.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and the clone for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
`bin/fm-project-remove.ps1` runs that preflight itself and refuses without `-Approved`; both halves matter, so do not pass `-Approved` before you have actually asked.
If any dependency or unlanded work exists, stop and report it before changing anything.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
