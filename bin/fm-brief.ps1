# bin/fm-brief.ps1 - crewmate brief and secondmate charter scaffolder.
# Scaffold a crewmate brief or persistent secondmate charter at
# data/<task-id>/brief.md under the active firstmate home.
# For ordinary tasks, the standard Setup/Rules/Definition-of-done contract is
# filled in. Firstmate then replaces the {TASK} placeholder with the task
# description, acceptance criteria, and context, and may adjust other sections
# when the task genuinely deviates (e.g. working an existing external PR instead
# of shipping a new one).
# Usage: fm-brief.sh <task-id> <repo-name> [--scout] [--herdr-lab]
#        fm-brief.sh <task-id> --secondmate {<project>...|--no-projects}
#   --scout writes the scout contract instead: the deliverable is a report at
#   data/<task-id>/report.md (no branch, no push, no PR) and the worktree is scratch.
#   --secondmate writes a persistent secondmate charter. The project list
#   is cloned into the secondmate home, while the natural-language scope
#   tells the main firstmate when to route work there; routine churn stays in its own home;
#   captain-relevant escalations and marked from-firstmate replies append to this
#   home's status file.
#   --no-projects writes a project-less charter for a domain whose subject is the
#   firstmate repo itself (its home is a firstmate worktree, its crews take pooled
#   worktrees of the same repo). It is mutually exclusive with a project list, and
#   omitting both still fails loudly so an accidental omission is never silent.
#   Set FM_SECONDMATE_CHARTER='<charter>' to fill the charter text.
#   Set FM_SECONDMATE_SCOPE='<scope>' to write a routing scope distinct from the charter text.
#   --herdr-lab is mandatory when the task will issue Herdr lifecycle commands.
#   It adds the hard isolation contract backed by bin/fm-herdr-lab.sh.
#   The flag must be explicit because {TASK} is filled after scaffolding and the
#   caller-supplied repo string cannot reliably identify this repo. Briefs made
#   without it carry a loud declaration so an omitted contract cannot be silent.
# For ship tasks, the definition of done is shaped by the project's delivery mode
# (data/projects.md via fm-project-mode.sh; see the project-management skill
# and AGENTS.md task lifecycle):
#   no-mistakes  implement -> /no-mistakes pipeline -> PR -> captain merge (default)
#   direct-PR    implement -> push + open PR via gh-axi (no pipeline) -> captain merge
#   local-only   implement on branch, stop and report "ready in branch" (no push/PR);
#                captain approves, firstmate merges to local main
# Ship briefs begin with a worktree-isolation assertion before the branch step.
# Scout tasks ignore mode - their deliverable is a report, not a merge.
# Every scaffold's status protocol distinguishes the configured
# declared-external-wait verb (FM_CLASSIFY_PAUSED_VERB, default "paused") from
# "blocked:": pause for a known external wait expected to clear on its own,
# blocked when firstmate must act.
# Ship tasks include a project-memory section so durable project-intrinsic
# learnings can be committed to AGENTS.md through the project's delivery path;
# it carries the AGENTS.md authoring bar (widely useful knowledge only, pointers
# over copied detail) and has the crewmate add the fm-ensure-agents-md.sh
# self-governance section when a touched project AGENTS.md lacks it.
# Refuses to overwrite an existing brief.

# ---------------------------------------------------------------------------
# Twin: bin/fm-brief.sh
#
# EVERYTHING ABOVE THE BLANK LINE IS THE --help TEXT, AND THAT IS DELIBERATE.
# The bash twin renders --help by awk-ing its own header: skip line 1 (the
# shebang), print every following comment line with `# ` stripped, stop at the
# first non-comment line. This file reproduces that reader exactly, so the
# header above is laid out to the same shape - line 1 is the skipped title, the
# next 46 lines are its twin's header verbatim, and the blank line above
# terminates the block. Everything from here down is invisible to --help, which
# is the only reason these port notes can live in the header at all. Keeping the
# reader (rather than hard-coding the text) is what makes a future header edit
# land in --help in BOTH languages instead of silently in one.
#
# The text still names bin/fm-brief.sh: CLI surfaces are identical during the
# transition (docs/powershell-port.md contract 4) and the differential harness
# compares this stdout byte for byte. Flipping the spelling belongs to the
# wave-5 cutover, in one change.
#
# ---------------------------------------------------------------------------
# THE GENERATED BRIEF IS A SAFETY CONTRACT, NOT FORMATTED OUTPUT
#
# AGENTS.md section 11: the worktree-isolation assertion and the status protocol
# are the scaffold's reason to exist. A crewmate that never reads the isolation
# assertion can branch and commit inside the primary checkout; one that never
# reads the status protocol goes dark. So the brief text is reproduced BYTE for
# byte here and the differential suite compares generated briefs with cmp, every
# variant, rather than grepping for landmark phrases.
#
# Two mechanics protect those bytes:
#
#   1. TEMPLATES ARE SINGLE-QUOTED HERE-STRINGS WITH @@NAME@@ SLOTS. The brief
#      text is dense with backticks and dollar signs - ``git checkout -b``,
#      `$("$HERDR_LAB_HELPER" name ...)`, `{state}` - and PowerShell treats the
#      backtick as its ESCAPE character inside any double-quoted string or
#      here-string. A single-quoted here-string interpolates nothing, so what is
#      written is what is emitted; the slots are then filled by one
#      non-recursive pass (Expand-FmTemplate) so a substituted value that itself
#      contained @@SOMETHING@@ can never be re-expanded.
#
#   2. CRLF IS NORMALIZED ON THE WAY IN, NOT TRUSTED. A here-string carries this
#      FILE's line endings, so a checkout that ever materialized CRLF here would
#      silently write CRLF briefs. Expand-FmTemplate normalizes every template,
#      and Set-FmFileText normalizes again on write.
#
# ---------------------------------------------------------------------------
# PATH FORM: RECORDED AS THE BASH TWIN RECORDS IT
#
# The brief embeds paths its reader will use (the status file, the report, the
# skills dir, the Herdr helper), and those strings must match what the bash twin
# writes because both worlds scaffold into the same home. So resolve_directory_input's
# rule is reproduced literally: an ALREADY-ABSOLUTE path is echoed back
# untouched (never normalized, never resolved), and only a relative one is
# resolved - to MSYS/POSIX form, which is what `pwd -P` gives bash. Native
# drive-absolute input (F:\x) is additionally treated as already absolute, which
# bash's `case $path in /*)` cannot recognize; that is a Windows-native addition
# rather than a divergence, because bash on this host would resolve it through
# `cd` to the same location.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCES FROM THE BASH ORACLE (deliberate, not normalized away)
#
#   a. MISSING POSITIONAL ARGUMENTS. `ID=${POS[0]}` and `REPO=${POS[1]}` fail
#      under `set -u` with bash's own "unbound variable" text and a line number.
#      The exit code (1) and the refusal are reproduced; the message is this
#      script's own, because pinning a twin to another language's line numbering
#      would be worse than useless.
#
#   b. A MISSING DELIVERY-MODE RESOLVER READS DIFFERENTLY. If FM_ROOT_OVERRIDE
#      names a root with no bin/fm-project-mode.* at all, bash reports the OS
#      error for the file it tried to execute and this reports Invoke-FmScript's
#      "fm: no twin found for fm-project-mode". Both then fall through to the
#      no-mistakes default with an identical brief, and the message belongs to
#      fm-common's execute-edge resolver rather than to this script, so it is
#      recorded rather than emulated.
#
#   c. THE RELATIVE-PATH FIXTURE SPELLING. Resolving a relative directory under
#      an MSYS-only mount (/tmp) yields /c/Users/.../Temp here where bash says
#      /tmp, because MSYS's /tmp is a mount-table fiction with no native
#      equivalent. Under any real drive path the two agree exactly, which is why
#      the differential suite roots its fixtures on a drive.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
# The same two libraries the bash twin sources, in the same order, for the same
# two values: the from-firstmate label and the configured pause verb.
Import-Module (Join-Path $PSScriptRoot 'fm-marker-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force

# Both captured at SCRIPT scope, not inside the Invoke-FmMain block: inside that
# block `$args` would resolve to the BLOCK's own (empty) argument array, and
# $PSCommandPath is equally a property of the script rather than of the
# scriptblock's execution. bin/fm-operational-input.ps1's header records the
# $args half of this trap in full.
$fmArgv = @($args)
$fmScriptPath = $PSCommandPath

# --- helpers -----------------------------------------------------------------

<#
.SYNOPSIS
Render the --help text by reading this file's own header.
.DESCRIPTION
The twin of the bash `usage()` awk program, rule for rule: skip line 1, strip a
leading '#' plus at most one space, stop at the first line that is not a comment.
#>
function Get-FmBriefUsage {
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $lines = @(Get-FmFileLines $Path)
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
        $body = $line.Substring(1)
        if ($body.StartsWith(' ', [System.StringComparison]::Ordinal)) { $body = $body.Substring(1) }
        $out.Add($body)
    }
    return $out.ToArray()
}

<#
.SYNOPSIS
Fill @@NAME@@ slots in one pass, with no re-expansion of substituted values.
.DESCRIPTION
Regex.Split with a capturing group returns literal and captured segments in
alternation, so odd indices are slot names and even indices are literal text.
That shape is what makes the pass non-recursive: a value containing @@X@@ lands
in the output as literal text, never as another slot. An unknown slot is left
verbatim so a typo shows up in the generated brief instead of vanishing.
#>
function Expand-FmTemplate {
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [Parameter(Mandatory, Position = 1)][hashtable]$Values
    )
    $normalized = $Text -replace "`r`n", "`n"
    $parts = @([regex]::Split($normalized, '@@([A-Z0-9_]+)@@'))
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if (($i % 2) -eq 0) {
            [void]$sb.Append($parts[$i])
        } elseif ($Values.ContainsKey($parts[$i])) {
            [void]$sb.Append([string]$Values[$parts[$i]])
        } else {
            [void]$sb.Append('@@').Append($parts[$i]).Append('@@')
        }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
Single-quote a string for a POSIX shell, the `'\''` way.
.DESCRIPTION
Twin of the bash shell_quote(). The generated brief is read by an agent that
will paste these strings into a shell, so a home or helper path containing an
apostrophe must survive as one argument.
#>
function ConvertTo-FmShellQuoted {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

<#
.SYNOPSIS
Twin of resolve_directory_input: absolute in, absolute out; relative resolved.
.DESCRIPTION
Returns $null when a relative path cannot be resolved, leaving the diagnostic and
the exit to the caller (bash prints it from the function and returns 1). An
already-absolute path is returned UNTOUCHED - not normalized, not existence-
checked - because bash's `case "$path" in /*) printf; return` does exactly that
and the brief embeds the result verbatim.
#>
function Resolve-FmDirectoryInput {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ($Path.StartsWith('/', [System.StringComparison]::Ordinal)) { return $Path }
    if ($Path -match '^[A-Za-z]:[\\/]') { return $Path }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    if (-not [System.IO.Directory]::Exists($candidate)) { return $null }
    # `pwd -P`: physical, so a junctioned fixture reports its real location.
    $resolvedLink = [System.IO.Directory]::ResolveLinkTarget($candidate, $true)
    if ($null -ne $resolvedLink) { $candidate = $resolvedLink.FullName }
    return (ConvertTo-FmPosixPath ($candidate.TrimEnd('\')))
}

# --- brief templates ---------------------------------------------------------
#
# Single-quoted here-strings: nothing below interpolates. See mechanic 1 in the
# header for why that is load-bearing rather than stylistic.

$fmSecondmateTemplate = @'
You are a persistent second mate managed by the main firstmate. Work on your own; do not wait for a human.

# Charter
@@CHARTER@@

# Routing scope
@@SCOPE@@

# Project clones
@@CLONES_BODY@@

# Operating model
You are in an isolated firstmate home. The local `AGENTS.md` is your job description, and your local `data/`, `state/`, `config/`, and `projects/` dirs are yours to operate.
@@CLONES_NOTE@@
Delegate project work to your own crewmates with the normal firstmate lifecycle: brief, spawn, status, watcher, steer, teardown, and recovery.
Do not invent a second delegation system.
You do not generate your own work.
Act only on tasks the main firstmate routes to you.
Never start a survey, audit, or "find improvements" sweep on your own initiative; that is not your job and it is unwanted.

# Requests from the main firstmate
You are a firstmate in your own home, so an incoming message reaches you in your own chat.
You must distinguish who it is from, because the answer goes to a different place.
A request relayed to you by the main firstmate is tagged with a leading `@@FROMFIRST@@` marker followed by an invisible system separator; this marker is untypable, so a human never produces it.
When a message carries that marker, do the work, then respond via the STATUS/ESCALATION path below, never only in this chat: the main firstmate does not read your chat, so a chat-only reply is lost.
Marked requests also carry a privacy-safe `corr=<id>` token after the marker; include that exact token in your parent status reply (or in the status pointer to a detailed doc) so the parent can correlate the answer.
Optional helper: `bin/fm-secondmate-report.sh` can append a correlated status line for you, but a plain `echo` that includes the same `corr=<id>` is equally valid - do not depend on the helper being present.
For a terse result, a status line is the whole answer.
For a detailed answer (an investigation, a plan, an audit), write it to a doc under your home's `data/` and append a status line that points to that doc - the scout-report pattern - so the main firstmate is woken and can read it.
Before treating an investigation or visual review as complete, load `decision-hold-lifecycle` from this home's `.agents/skills/` and pass its shared completion gate.
A message with NO marker is the captain typing directly into your pane: treat it as authoritative captain intervention and stay conversational exactly as you would for any captain message; do not force it onto the status path.

# Escalation to main firstmate
Handle routine work yourself.
Report only true captain-relevant outcomes or a declared external wait by appending one line:
   `echo "{state}: {one short line}" >> @@STATUS_FILE@@`
States: working, needs-decision, blocked, @@PAUSED@@, done, failed.
Use `@@PAUSED@@: {why}` (distinct from `blocked:`) only when your domain is deliberately idling on a known external wait you expect to clear on its own; use `blocked:` when you are stuck and need firstmate to act.
Use this only for material phase changes, a captain decision, a real blocker, a failure, or work ready for review.
This is also how you return the answer to a marked from-firstmate request above.
A marked request requires one correlated answer after the work; it does not require a separate receipt or start acknowledgement.
Never append `working:` merely to acknowledge receipt or announce that a marked request has started.
When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above, give that reported phase a stable key.
If its first reportable event is `working [key=<work-slug>]: {material phase}`, use the same key on its later `@@PAUSED@@`, `done`, `failed`, `needs-decision`, or `blocked` event so the earlier working phase is superseded.
When a keyed phase ends without another reportable state, append `resolved [key=<work-slug>]: {why it is no longer active}`.
When a decision you escalated is answered or a blocker clears and your domain resumes, append `resolved: {how it was decided or unblocked}` (keyed with `[key=<slug>]` if you opened it with one) so it is durably closed instead of resurfacing behind later unrelated events.
Routine internal supervision, heartbeats, retries, and crewmate churn stay inside your own home and must not touch that status file.

# Definition of done
You are persistent by default. Do not exit just because your queue is empty.
On startup and restart, run normal firstmate bootstrap and recovery through `bin/fm-session-start.sh` for your own home, but only to RECONCILE work that is already yours: in-flight crewmates, tracked backlog items, and durable watches recorded in this home.
When you have no assigned or in-flight work after that reconciliation, go idle and wait silently for the main firstmate to route you a task.
An empty queue is a healthy resting state, not a cue to invent work: never spawn a survey, audit, or any self-directed "find work" task on your own initiative.
If this charter cannot be carried out, append `blocked: {why}` or `failed: {why}` to the main status file and stop.
'@

$fmHerdrLabTemplate = @'
# Herdr isolation - HARD SAFETY CONTRACT
This brief was explicitly scaffolded with `--herdr-lab` because the task will drive Herdr lifecycle behavior.
On Herdr 0.7.3 the API socket is not relocatable by `HERDR_CONFIG_PATH`, `XDG_CONFIG_HOME`, or `HOME`.
A named non-`default` session plus a trailing `--session <name>` on every call is the only viable local isolation.

1. Set `HERDR_LAB_HELPER=@@HELPER@@` and generate the session name with `HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name @@ID@@)`.
   Install `trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT` before provisioning, then provision only with `"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"`.
2. Run every task-specific non-lifecycle Herdr command through `"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" <arguments...>`.
   The helper appends the required trailing `--session "$HERDR_LAB_SESSION"`; `HERDR_SESSION` alone is never accepted as isolation.
3. Teardown only through `"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"`.
   It re-checks refuse-default immediately before stop and again immediately before delete, and fails closed on ambiguity.
4. If an experiment requires a deliberate mid-run session stop, use only `"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION"`; it performs the same immediate refuse-default check.
5. Forbidden commands: direct `herdr server stop`, every other server-global operation such as `herdr server live-handoff` or reload/update operations, direct `herdr session stop`, direct `herdr session delete`, and any Herdr call scoped only by ambient or inline `HERDR_SESSION`.
6. The helper records the live default session before provisioning and verifies the identical fleet state after teardown.
   A missing, stopped, or changed default session is a hard tripwire failure, never a cleanup warning to ignore.

Never bypass the helper, even for a read-only lifecycle probe or cleanup after failure.
The captain fleet uses the running `default` session.
'@

$fmHerdrDeclarationTemplate = @'
# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text that replaces `{TASK}` later.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.
'@

$fmScoutTemplate = @'
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

@@HERDR@@

# Setup
You are in a disposable git worktree of @@REPO@@, at a detached HEAD on a clean default branch.
This is a SCOUT task: the deliverable is a written report, not a PR.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state}: {one short line}" >> @@STATUS_FILE@@`
   States: working, needs-decision, blocked, @@PAUSED@@, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on and the needs-decision/blocked/paused/done/failed states. No step-by-step
   FYI progress lines; firstmate reads your pane for that.
   Use `@@PAUSED@@: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset):
   firstmate then leaves your idle pane alone and rechecks it on a long cadence instead of
   treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
5. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
6. If a decision belongs to a human (product choices, destructive actions),
   append `needs-decision: {summary of options}` and stop. Firstmate will reply with the decision.
   When firstmate replies or a blocker clears and you resume, append `resolved: {how it was decided or unblocked}` (add the same `[key=<slug>]` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.

# Definition of done
Write your findings to `@@DATA@@/@@ID@@/report.md`.
The report must stand alone: what you did, what you found, the evidence (commands run, output, file:line references), and what you recommend.
Before reporting done, read and follow `@@FMROOT@@/.agents/skills/decision-hold-lifecycle/SKILL.md` and pass its shared completion gate for the report and any visual review.
When the report is complete, append `done: {one-line conclusion}` to the status file and stop.
If your findings reveal work that should ship (e.g. you reproduced a bug and the fix is clear), say so in the report; firstmate may promote this task in place, and you would then receive mode-specific ship instructions as a follow-up message.
'@

$fmShipTemplate = @'
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
{TASK}

@@HERDR@@

# Setup
You are in a disposable git worktree of @@REPO@@, at a detached HEAD on a clean default branch.

**Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from.
The path check is authoritative: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` can help inspect the repo, but they do not prove you are outside the primary checkout.
If the top-level path is the primary checkout or not the worktree you were launched in, STOP - do not branch or commit here - append `blocked: launched in primary checkout, not an isolated worktree` to the status file and stop.

1. First action: create your branch: `git checkout -b fm/@@ID@@`@@SETUP2@@

# Rules
@@RULE1@@
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state}: {one short line}" >> @@STATUS_FILE@@`
   States: working, needs-decision, blocked, @@PAUSED@@, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   A mid-task `working:` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined `done:` gate under Definition of done.
   Use `@@PAUSED@@: {why}` - distinct from `blocked:` - ONLY when you are deliberately idling on a
   known external wait you expect to clear on its own (an upstream release, a rate-limit reset,
   a scheduled window): firstmate then leaves your idle pane alone and rechecks it on a long
   cadence instead of treating it as a possible wedge. Use `blocked:` when you are stuck and need help.
5. If you hit the same obstacle twice, append `blocked: {why}` and stop; firstmate will help.
6. If a decision belongs above the implementation worker (product choices, destructive actions, ask-user findings),
   append `needs-decision: {summary of options}` and stop. Firstmate will apply the configured authority and reply with the decision.
   When firstmate replies or a blocker clears and you resume, append `resolved: {how it was decided or unblocked}` (add the same `[key=<slug>]` if you opened it with one) so the decision or blocker is durably closed and does not keep resurfacing.
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.

# Project memory
If `AGENTS.md` or `CLAUDE.md` already exists, or if this task produced durable project-intrinsic knowledge, run `@@FMROOT@@/bin/fm-ensure-agents-md.sh .` in the worktree.
Record only project knowledge useful to almost every future session.
For anything the codebase already shows, prefer a pointer to the authoritative file, command, or doc over copying the detail.
If you touch a project `AGENTS.md` that lacks `## Maintaining this file`, add that short self-governance section from `@@FMROOT@@/bin/fm-ensure-agents-md.sh` in the same pass.
Keep it proportionate: skip `AGENTS.md` edits for trivial tasks that produced no durable project knowledge.

@@DOD@@
'@

$fmDodDirectPr = @'
# Definition of done
This project ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
'@

$fmDodLocalOnly = @'
# Definition of done
This project ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/@@ID@@`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/@@ID@@` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
'@

$fmDodNoMistakes = @'
# Definition of done
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
'@

# --- main --------------------------------------------------------------------

Invoke-FmMain -UnexpectedCode 70 {
    # --help is answered before any resolution, exactly as the bash twin's `case`
    # sits above its library sourcing: a broken FM_HOME must not hide the usage.
    $first = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    if ($first -ceq '-h' -or $first -ceq '--help') {
        foreach ($line in (Get-FmBriefUsage $fmScriptPath)) { Write-FmOut $line }
        Exit-FmScript 0
    }

    $pausedVerb = Get-FmClassifyPausedVerb
    $fromFirstLabel = Get-FmOperationalConstant 'FM_FROMFIRST_LABEL'

    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
    }

    $homeEnv = Get-FmEnv 'FM_HOME'
    $homeInput = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }
    $fmHome = Resolve-FmDirectoryInput $homeInput
    if ($null -eq $fmHome) {
        Write-FmErr "error: FM_HOME directory cannot be resolved: $homeInput"
        Exit-FmScript 1
    }

    $dataOverride = Get-FmEnv 'FM_DATA_OVERRIDE'
    if ($dataOverride) {
        $data = Resolve-FmDirectoryInput $dataOverride
        if ($null -eq $data) {
            Write-FmErr "error: FM_DATA_OVERRIDE directory cannot be resolved: $dataOverride"
            Exit-FmScript 1
        }
    } else {
        $data = "$fmHome/data"
    }

    $stateOverride = Get-FmEnv 'FM_STATE_OVERRIDE'
    if ($stateOverride) {
        $state = Resolve-FmDirectoryInput $stateOverride
        if ($null -eq $state) {
            Write-FmErr "error: FM_STATE_OVERRIDE directory cannot be resolved: $stateOverride"
            Exit-FmScript 1
        }
    } else {
        $state = "$fmHome/state"
    }

    # Flags are recognized ANYWHERE in argv and everything else is positional,
    # matching the bash `for a in "$@"` loop rather than a stricter parser.
    $kind = 'ship'
    $herdrLab = $false
    $noProjects = $false
    $positional = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $fmArgv) {
        $arg = [string]$a
        # No break/continue keywords: the four conditions are distinct literals,
        # so at most one can match a scalar, and `continue` inside a switch has
        # loop-vs-switch semantics not worth relying on here.
        switch -CaseSensitive ($arg) {
            '--scout' { $kind = 'scout' }
            '--secondmate' { $kind = 'secondmate' }
            '--herdr-lab' { $herdrLab = $true }
            '--no-projects' { $noProjects = $true }
            default { $positional.Add($arg) }
        }
    }

    if ($positional.Count -lt 1) {
        # Divergence (a): bash reports its own unbound-variable text here.
        Write-FmErr 'error: missing <task-id>'
        Exit-FmScript 1
    }
    $id = $positional[0]

    if ($kind -ceq 'secondmate' -and $herdrLab) {
        Write-FmErr 'error: --herdr-lab applies only to crewmate ship or scout briefs'
        Exit-FmScript 1
    }
    if ($noProjects -and $kind -cne 'secondmate') {
        Write-FmErr 'error: --no-projects applies only to --secondmate charters'
        Exit-FmScript 1
    }

    $brief = "$data/$id/brief.md"
    $briefNative = ConvertTo-FmNativePath $brief
    if ([System.IO.File]::Exists($briefNative) -or [System.IO.Directory]::Exists($briefNative)) {
        Write-FmErr "error: $brief already exists"
        Exit-FmScript 1
    }
    $null = New-Item -ItemType Directory -Force -Path (ConvertTo-FmNativePath "$data/$id")

    $statusFile = ConvertTo-FmShellQuoted "$state/$id.status"

    if ($kind -ceq 'secondmate') {
        # POS[1..] joined with single spaces, then split on every space: an
        # argument containing a space becomes two bullets, exactly as the bash
        # `tr ' ' '\n'` pipeline does.
        $projects = ''
        for ($i = 1; $i -lt $positional.Count; $i++) {
            if ($projects -ne '') { $projects += ' ' }
            $projects += $positional[$i]
        }
        if ($noProjects) {
            if ($projects -ne '') {
                Write-FmErr 'error: --no-projects cannot be combined with a project list'
                Exit-FmScript 1
            }
        } elseif ($projects -eq '') {
            Write-FmErr 'error: --secondmate requires at least one project, or --no-projects for a project-less home'
            Exit-FmScript 1
        }

        $charter = Get-FmEnv 'FM_SECONDMATE_CHARTER' '{TASK}'
        $scope = Get-FmEnv 'FM_SECONDMATE_SCOPE' $charter

        if ($noProjects) {
            $clonesBody = 'None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under `projects/`; its crews take pooled worktrees of that firstmate repo.'
            $clonesNote = 'This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo.'
        } else {
            $clonesBody = (@($projects.Split(' ') | ForEach-Object { "- $_" }) -join "`n")
            $clonesNote = 'The projects above are local clones for work you supervise; they are not an exclusive ownership claim.'
        }

        $text = Expand-FmTemplate $fmSecondmateTemplate @{
            CHARTER     = $charter
            SCOPE       = $scope
            CLONES_BODY = $clonesBody
            CLONES_NOTE = $clonesNote
            FROMFIRST   = $fromFirstLabel
            STATUS_FILE = $statusFile
            PAUSED      = $pausedVerb
        }
        Set-FmFileText -Path $brief -Text $text
        if ($charter -ceq '{TASK}') {
            Write-FmOut "scaffolded: $brief (secondmate charter; replace {TASK})"
        } else {
            Write-FmOut "scaffolded: $brief (secondmate charter)"
        }
        Exit-FmScript 0
    }

    if ($positional.Count -lt 2) {
        # Divergence (a), the REPO half.
        Write-FmErr 'error: missing <repo-name>'
        Exit-FmScript 1
    }
    $repo = $positional[1]

    if ($herdrLab) {
        $herdrSection = Expand-FmTemplate $fmHerdrLabTemplate @{
            HELPER = ConvertTo-FmShellQuoted "$fmRoot/bin/fm-herdr-lab.sh"
            ID     = $id
        }
    } else {
        $herdrSection = Expand-FmTemplate $fmHerdrDeclarationTemplate @{}
    }

    if ($kind -ceq 'scout') {
        $text = Expand-FmTemplate $fmScoutTemplate @{
            HERDR       = $herdrSection
            REPO        = $repo
            STATUS_FILE = $statusFile
            PAUSED      = $pausedVerb
            DATA        = $data
            ID          = $id
            FMROOT      = $fmRoot
        }
        Set-FmFileText -Path $brief -Text $text
        Write-FmOut "scaffolded: $brief (scout; replace {TASK})"
        Exit-FmScript 0
    }

    # Ship task: shape Setup / Rule 1 / Definition of done by the project's
    # delivery mode. yolo does not affect the brief because the worker never owns
    # approval decisions; firstmate applies the authority contract in AGENTS.md
    # section 7, so it is discarded here.
    #
    # Invoke-FmScript, not a hard-coded extension: the delivery mode resolver is a
    # separate PROCESS, so it may be on either side of the conversion
    # (docs/powershell-port.md contract 7). Its warnings are the caller's
    # responsibility to surface - bash lets the child's stderr through untouched,
    # so the captured stream is replayed line for line.
    $modeResult = Invoke-FmScript 'fm-project-mode' @($repo) -BinDir (ConvertTo-FmNativePath "$fmRoot/bin")
    if (-not [string]::IsNullOrEmpty($modeResult.StdErr)) {
        foreach ($line in @($modeResult.StdErr -split "`n")) {
            if ($line -ne '') { Write-FmErr $line }
        }
    }
    $modeLine = @($modeResult.StdOut -split "`n")[0]
    $mode = @($modeLine -split '\s+' | Where-Object { $_ -ne '' })
    $mode = if ($mode.Count -ge 1) { $mode[0] } else { '' }

    $dodValues = @{ ID = $id }
    switch -CaseSensitive ($mode) {
        'direct-PR' {
            $setup2 = ''
            $rule1 = '1. Never push to the default branch (push only your `fm/' + $id + '` branch). Never merge a PR.'
            $dod = Expand-FmTemplate $fmDodDirectPr $dodValues
        }
        'local-only' {
            $setup2 = ''
            $rule1 = "1. Never push to any remote and never open a PR. Work only on your ``fm/$id`` branch; firstmate handles the merge into local ``main``."
            $dod = Expand-FmTemplate $fmDodLocalOnly $dodValues
        }
        default {
            $setup2 = "`n2. Run ``no-mistakes doctor``; if it reports the repo is not initialized here, run ``no-mistakes init``."
            $rule1 = '1. Never push to the default branch. Never merge a PR.'
            $dod = Expand-FmTemplate $fmDodNoMistakes $dodValues
        }
    }

    $text = Expand-FmTemplate $fmShipTemplate @{
        HERDR       = $herdrSection
        REPO        = $repo
        ID          = $id
        SETUP2      = $setup2
        RULE1       = $rule1
        STATUS_FILE = $statusFile
        PAUSED      = $pausedVerb
        FMROOT      = $fmRoot
        DOD         = $dod
    }
    Set-FmFileText -Path $brief -Text $text
    Write-FmOut "scaffolded: $brief (ship, mode=$mode; replace {TASK})"
    Exit-FmScript 0
}
