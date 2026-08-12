#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2086
# Differential test for the W4-fleet entrypoint twins:
#
#   bin/fm-fleet-sync.ps1      vs bin/fm-fleet-sync.sh
#   bin/fm-fleet-snapshot.ps1  vs bin/fm-fleet-snapshot.sh
#   bin/fm-fleet-view.ps1      vs bin/fm-fleet-view.sh
#   bin/fm-update.ps1          vs bin/fm-update.sh
#   bin/fm-merge-local.ps1     vs bin/fm-merge-local.sh
#
# WHAT IS ACTUALLY AT STAKE, WHICH IS WHY THE CASE MIX LOOKS LIKE THIS
#
#   1. THESE ARE AMONG THE VERY FEW PATHS ALLOWED TO TOUCH A PROJECT CHECKOUT,
#      and only through a guarded fast-forward (AGENTS.md hard rule 1). So the
#      cases are weighted toward REFUSALS rather than toward the happy path: a
#      dirty tree, a non-default branch, a detached HEAD, a diverged default, a
#      missing remote, a local-only project, a branch that still has a worktree.
#      Each of those is a decision NOT to touch someone's work, and each one's
#      exact wording and exit code is compared byte-for-byte, because a
#      session-start refresh relays these lines to the captain verbatim.
#   2. fm-merge-local IS A MERGE-AUTHORITY BOUNDARY. Every one of its seven
#      refusals is driven, including the REFUSED-on-divergence path, because a
#      twin that merged where the original refused would land unreviewed work in
#      a project's default branch.
#   3. fm-fleet-snapshot's JSON IS A CONSUMED CONTRACT (bearings, fm-fleet-view,
#      the secondmate roll-up). It is compared as BYTES, not through a
#      canonicalizer, so a key-order, empty-collection, or number-formatting
#      regression fails here rather than surfacing later as a renderer bug. The
#      backlog fixture therefore carries every row shape the parser branches on:
#      checkbox and bold rows, an unstructured row, indented body lines, blocked-by
#      with and without a reason, captain holds, completion metadata in all three
#      verbs, a PR link, and a report pointer.
#   4. THE RECURSIVE SECONDMATE READ IS DRIVEN FOR REAL. The rich fixture carries
#      a properly seeded secondmate home, so the parent actually validates it and
#      runs the child --secondmate-home-summary, which is the only way to cover
#      home validation, the byte/schema gate, and the parent-evidence
#      reconciliation.
#
# THE BATCHING RULE (docs/powershell-port.md, "the one rule that decides whether
# a suite finishes"). A bare `pwsh -NoProfile -Command "exit 0"` costs 4.8s on
# the reference host, so a suite that spawns one pwsh per case never finishes.
# This file writes every PowerShell case to a TSV case file and runs ONE pwsh
# over all of them, joining the two worlds' answers by LABEL.
#
# ONE EXTRA pwsh, DELIBERATELY. `fm-fleet-view --json` streams its child's
# output through the REAL process stdout handle (Invoke-FmScript -Stream), which
# by construction bypasses the driver's [Console]::SetOut redirection. Driving
# that one case inside the batch would silently compare an EMPTY answer against a
# full snapshot, so it is driven as its own real process at the end. That is a
# constant, not a per-case cost.
#
# THE SAME PROPERTY IS WHY EVERY GUARD-CALLING FIXTURE IS GUARD-SILENT.
# fm-fleet-sync, fm-update and fm-merge-local all run `fm-guard || true` with the
# child's streams inherited, so a guard that PRINTED would reach the driver's own
# stderr on the PowerShell side and the case answer on the bash side - a
# systematic mismatch that says nothing about the twins. Their fixtures therefore
# have no in-flight metadata, or a fresh watcher beacon, and an empty wake queue,
# and the bash side is asserted to have produced no banner so the assumption
# fails loudly if it ever stops holding.
#
# PATH NORMALIZATION - THE ONLY NORMALIZATION, DECLARED HERE AND APPLIED TO BOTH
# SIDES WITH THE SAME PROGRAM:
#
#   1. Every backslash becomes a forward slash. JSON's escaped "\\" is collapsed
#      FIRST, then a raw "\", because doing raw-first would turn one "\\" into
#      "//" and leave a path that no longer matches anything.
#   2. Every "X:/" then becomes "/x/", the MSYS drive form the bash tree prints.
#
# Order is load-bearing: "C:\Users" contains no "C:/" to match until step 1 has
# run, so a drive rule applied first would silently match nothing and every path
# would read as a mismatch. Nothing else is normalized - no message text, no exit
# code, no tool line. Nondeterministic values are not compared at all: the
# snapshot clock is pinned with FM_SNAPSHOT_NOW/FM_SNAPSHOT_NOW_EPOCH, and every
# git hash that appears in output comes from a fixture COPY (not a rebuild), so
# both worlds see the same commits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the bash oracle needs it)"; exit 0; }

# A stray override in the ambient session would silently repoint every case, so
# the base state is pinned here rather than assumed.
unset FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
unset FM_PROJECTS_OVERRIDE FM_SNAPSHOT_NOW FM_SNAPSHOT_NOW_EPOCH FM_FLEET_PRUNE

# --- staged verification ------------------------------------------------------
#
# FM_FLEET_PSM1_PHASES selects a comma-separated subset; unset runs all of them.
# The reason is measured, not cosmetic: every one of these entrypoints RUNS
# siblings (fm-guard, fm-project-mode, fm-crew-state, and the recursive
# fm-fleet-snapshot), and on the PowerShell side each of those is a real pwsh
# spawn at ~4.8s. That cost belongs to the architecture - an execute edge is a
# process boundary in both worlds - so the answer is to stagger the phases, which
# is docs/powershell-port.md's own guidance, rather than to delete coverage. The
# join below compares only the labels the oracle actually produced, so a staged
# run is a real verdict for that phase.
PHASES=${FM_FLEET_PSM1_PHASES:-snapshot,view,sync,update,merge}
want() {  # <phase>
  case ",$PHASES," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# --- transport encoding -------------------------------------------------------
#
# Case and answer records are TAB-delimited lines, but an answer legitimately
# contains newlines (every snapshot does) and could contain tabs. So payloads are
# transport-encoded onto the C0 separators, which no case value uses: US joins
# list items, RS stands for LF, GS for CR, FS for TAB.
US=$'\x1f'
RS=$'\x1e'
GS=$'\x1d'
FS=$'\x1c'

# enc <text>: sets ENC. A global out-parameter rather than a command
# substitution, because `$(...)` forks and a fork costs 2.5-3.1s on this host
# under load. Every helper on the per-case path obeys the same rule.
ENC=""
enc() {
  local s=$1
  s=${s//$'\r'/$GS}
  s=${s//$'\n'/$RS}
  s=${s//$'\t'/$FS}
  ENC=$s
}

# --- fixture root -------------------------------------------------------------
#
# The fixture root must have a DRIVE-form POSIX spelling (/c/...), not an MSYS
# mount fiction (/tmp/...), because the SAME path string is handed to both
# worlds: bash uses it verbatim and the PowerShell twins convert it with
# fm-common's pure-string MSYS-drive rule. A /tmp path would need cygpath on
# every conversion (a fork each) and would print back through a mount table the
# bash side never applies.
if command -v cygpath >/dev/null 2>&1; then
  # `cygpath -u` is NOT the inverse here: it maps the Windows temp directory
  # straight back onto the /tmp MOUNT it came from, which is the spelling this
  # suite must avoid. The drive form is derived from the Windows path by hand.
  TMP_WIN=$(cygpath -w /tmp)
  case "$TMP_WIN" in
    [A-Za-z]:*)
      TMP_DRIVE=${TMP_WIN%%:*}
      TMP_REST=${TMP_WIN#*:}
      TMP_REST=${TMP_REST//\\//}
      TMPDIR="/${TMP_DRIVE,,}$TMP_REST"
      export TMPDIR
      ;;
  esac
fi
TMP_ROOT=$(fm_test_tmproot fm-fleet-psm1)
case "$TMP_ROOT" in
  /[A-Za-z]/*) ;;
  *)
    if command -v cygpath >/dev/null 2>&1; then
      echo "skip: fixture root $TMP_ROOT has no drive-form spelling; cannot drive both worlds from one path string"
      exit 0
    fi
    ;;
esac

fm_git_identity fmtest fmtest@example.invalid

# The snapshot clock is PINNED so `generated`, `observed_at` and every
# age_seconds are functions of the fixture rather than of the wall clock. This is
# the alternative to normalizing a nondeterministic value: make it deterministic.
PIN_NOW=2026-08-09T00:00:00Z
PIN_EPOCH=9999999999

# THE BOUNDED-READ TIMEOUTS ARE RAISED FOR EVERY SNAPSHOT CASE, AND THAT IS A
# CORRECTNESS REQUIREMENT, NOT A CONVENIENCE.
#
# The bash twin enforces its byte and line bounds by running each bounded read in
# a CHILD SHELL under `timeout`, defaulting to 2 seconds for the registry and
# parent-activity reads and 8 for the child home summary. On this fork-bound host
# those reads are 5-10 forks each, and MEASURED under load a trivial fork costs
# 2.5-3.1s - so the oracle was reporting "registered secondmate table read timed
# out" and an empty record set while the twin, which does the same read
# IN-PROCESS, correctly returned three records. That is the machine's fork cost
# deciding the answer, not a difference between the twins.
#
# Raising the timeouts removes the machine from the comparison. It also names a
# real, declared divergence: the PowerShell twin has NO timeout on the registry
# and parent-activity reads, because there is no child process to bound - the
# byte, line and record CAPS still apply identically and are asserted by the
# snap-registry-trunc case. The child-home-summary read, which IS a process in
# both worlds, keeps its timeout in both.
PIN_TIMEOUTS=(
  FM_SNAPSHOT_REGISTRY_TIMEOUT=120
  FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT=120
  FM_SNAPSHOT_TERMINAL_TIMEOUT=120
  FM_SNAPSHOT_SECONDMATE_TIMEOUT=300
)

# =============================================================================
# fixtures
# =============================================================================

mk_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data" "$1/projects"
}

# A git checkout usable as a project clone or as FM_ROOT.
mk_repo() {  # <dir> [branch]
  local dir=$1 branch=${2:-}
  git init -q -b main "$dir"
  : > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m one
  [ -z "$branch" ] || git -C "$dir" checkout -q -b "$branch"
}

# --- snapshot fixture ---------------------------------------------------------
#
# One home, read by BOTH worlds, because every snapshot mode is read-only. The
# backlog below is the parser's whole branch surface in one file.

SNAP="$TMP_ROOT/snap"
SUB_HOME="$TMP_ROOT/subhome"

if want snapshot || want view; then
mk_home "$SNAP"
mk_home "$SUB_HOME"

cat > "$SNAP/data/backlog.md" <<'EOF'
## In flight
- [ ] t1 - build the thing (repo: demo, kind: ship, priority: high)
  a body line that becomes the excerpt
  and a second one
- [x] t2 - the persistent mate (repo: demo, kind: secondmate)
- [ ] t3 - captain held item (repo: demo, kind: captain, hold: waiting on the captain, hold-kind: captain)
## Queued
- **q1** - a bold row blocked-by: t1 - needs t1 to land first (repo: demo, kind: ship)
- [ ] q2 - actionable hold (repo: demo, kind: captain, hold: decide the lane, hold-kind: captain)
- a free-form row that is not a task
## Done
- [x] d1 - landed with a PR https://example.invalid/o/r/pull/12 (repo: demo, kind: ship, merged 2026-01-02)
- [x] d2 - a scout - data/d2/report.md (repo: demo, kind: scout, reported 2026-01-01)
- [x] d3 - landed locally - local main (repo: demo, kind: ship, done 2026-01-03)
## Notes
- [ ] n1 - must not be counted (repo: demo)
EOF

{
  printf 'kind=ship\n'
  printf 'project=demo\n'
  printf 'harness=claude\n'
  printf 'mode=no-mistakes\n'
  printf 'yolo=off\n'
  printf 'worktree=%s\n' "$TMP_ROOT/nowhere-wt"
} > "$SNAP/state/t1.meta"
printf 'needs-decision[key=k1]: pick a lane\nrunning: still going\n' > "$SNAP/state/t1.status"

{
  printf 'kind=secondmate\n'
  printf 'harness=codex\n'
  printf 'home=%s\n' "$SUB_HOME"
  printf 'projects=demo, other,\n'
} > "$SNAP/state/t2.meta"
printf 'working[key=w1]: routing a change\nneeds-decision[key=k2]: which repo\n' > "$SNAP/state/t2.status"

mkdir -p "$SNAP/data/d2"
printf 'the report body\n' > "$SNAP/data/d2/report.md"

# Registry: one good record, a duplicate id (the group_by collapse), a record
# whose home field is EMPTY, and a line with no structured suffix at all.
#
# The last two are not the same case, and the difference is the subtle part of
# this parser. jq's `(capture(...)?) as $home` yields NOTHING when the suffix does
# not match, so `as` iterates zero times and the line is DROPPED silently; the
# "registry entry has no home" message is reachable only through a suffix that
# DOES match with an empty home field. Both arms are driven so a twin that binds
# null and reports instead of dropping fails here.
{
  printf -- '- t2 - the persistent mate (home: %s; scope: everything demo; projects: demo; added 2026-01-01)\n' "$SUB_HOME"
  printf -- '- t2 - a duplicate id (home: %s; scope: also demo; projects: demo; added 2026-01-02)\n' "$SUB_HOME"
  printf -- '- ghost - never seeded (home: %s/nope; scope: nothing; projects: none; added 2026-01-03)\n' "$TMP_ROOT"
  printf -- '- blankhome - no home field (home: ; scope: nothing; projects: none; added 2026-01-04)\n'
  printf -- '- not a record at all\n'
} > "$SNAP/data/secondmates.md"

# A properly seeded secondmate home, so the parent really validates it and really
# runs the child summary rather than falling into the unsafe-home arm.
printf 't2\n' > "$SUB_HOME/.fm-secondmate-home"
: > "$SUB_HOME/AGENTS.md"
mkdir -p "$SUB_HOME/bin"
cat > "$SUB_HOME/data/backlog.md" <<'EOF'
## In flight
## Queued
- [ ] s1 - queued in the mate home (repo: demo, kind: ship)
## Done
- [x] s0 - landed there (repo: demo, kind: ship, merged 2026-02-02)
EOF

SNAP_EMPTY="$TMP_ROOT/snap-empty"
mk_home "$SNAP_EMPTY"
fi

# --- sync fixture -------------------------------------------------------------
#
# Built ONCE and then COPIED per world, so both sides see byte-identical objects
# and therefore identical short hashes in "synced <before>..<after>".

SYNC_SRC="$TMP_ROOT/sync-src"
if want sync; then
mkdir -p "$SYNC_SRC"
git init -q -b main "$SYNC_SRC/seed"
: > "$SYNC_SRC/seed/f.txt"
git -C "$SYNC_SRC/seed" add f.txt
git -C "$SYNC_SRC/seed" commit -q -m one
git init -q --bare -b main "$SYNC_SRC/origin.git"
git -C "$SYNC_SRC/seed" remote add origin "$SYNC_SRC/origin.git"
git -C "$SYNC_SRC/seed" push -q -u origin main

mk_home "$SYNC_SRC/home"
# behind: cloned before the second commit, so the sweep must fast-forward it.
git clone -q "$SYNC_SRC/origin.git" "$SYNC_SRC/home/projects/behind" 2>/dev/null
# prune: a branch whose upstream is deleted on the remote, plus a second whose
# worktree still exists - the guard that keeps pruning from discarding work.
git -C "$SYNC_SRC/seed" checkout -q -b gone-branch
git -C "$SYNC_SRC/seed" push -q -u origin gone-branch
git -C "$SYNC_SRC/seed" checkout -q -b kept-branch
git -C "$SYNC_SRC/seed" push -q -u origin kept-branch
git -C "$SYNC_SRC/seed" checkout -q main
git clone -q "$SYNC_SRC/origin.git" "$SYNC_SRC/home/projects/prune" 2>/dev/null
git -C "$SYNC_SRC/home/projects/prune" branch -q --track gone-branch origin/gone-branch
git -C "$SYNC_SRC/home/projects/prune" branch -q --track kept-branch origin/kept-branch
git -C "$SYNC_SRC/home/projects/prune" worktree add -q --detach "$SYNC_SRC/wt" kept-branch 2>/dev/null
git -C "$SYNC_SRC/wt" checkout -q kept-branch 2>/dev/null
git -C "$SYNC_SRC/origin.git" branch -q -D gone-branch
git -C "$SYNC_SRC/origin.git" branch -q -D kept-branch
# stuck: a named non-default branch that may hold real work.
git clone -q "$SYNC_SRC/origin.git" "$SYNC_SRC/home/projects/stuck" 2>/dev/null
git -C "$SYNC_SRC/home/projects/stuck" checkout -q -b feature/x
# dirty: on the default branch with uncommitted changes.
git clone -q "$SYNC_SRC/origin.git" "$SYNC_SRC/home/projects/dirty" 2>/dev/null
printf 'uncommitted\n' > "$SYNC_SRC/home/projects/dirty/f.txt"
# noorigin and notgit: the two benign skips.
git init -q -b main "$SYNC_SRC/home/projects/noorigin"
: > "$SYNC_SRC/home/projects/noorigin/a"
git -C "$SYNC_SRC/home/projects/noorigin" add a
git -C "$SYNC_SRC/home/projects/noorigin" commit -q -m x
mkdir -p "$SYNC_SRC/home/projects/notgit"
# localonly: registered local-only, so the sweep must decline to fetch it at all.
git clone -q "$SYNC_SRC/origin.git" "$SYNC_SRC/home/projects/localonly" 2>/dev/null
{
  printf '# projects\n\n'
  printf -- '- behind - x (added 2026-01-01)\n'
  printf -- '- localonly [local-only] - x (added 2026-01-01)\n'
} > "$SYNC_SRC/home/data/projects.md"

# Now advance origin so `behind` and `prune` are genuinely behind.
printf 'two\n' > "$SYNC_SRC/seed/f.txt"
git -C "$SYNC_SRC/seed" commit -q -a -m two
git -C "$SYNC_SRC/seed" push -q origin main

cp -r "$SYNC_SRC/home" "$TMP_ROOT/sync-bash"
cp -r "$SYNC_SRC/home" "$TMP_ROOT/sync-ps"
# A second, single-project pair, so the sweep cases and the argument-form cases
# cannot disturb each other's clones.
cp -r "$SYNC_SRC/home" "$TMP_ROOT/sync1-bash"
cp -r "$SYNC_SRC/home" "$TMP_ROOT/sync1-ps"
fi

# --- update fixture -----------------------------------------------------------

UPD_SRC="$TMP_ROOT/upd-src"
if want update; then
mkdir -p "$UPD_SRC"
git init -q -b main "$UPD_SRC/seed"
: > "$UPD_SRC/seed/AGENTS.md"
mkdir -p "$UPD_SRC/seed/bin" "$UPD_SRC/seed/.agents/skills"
: > "$UPD_SRC/seed/bin/placeholder"
: > "$UPD_SRC/seed/.agents/skills/placeholder"
git -C "$UPD_SRC/seed" add -A
git -C "$UPD_SRC/seed" commit -q -m one
git init -q --bare -b main "$UPD_SRC/origin.git"
git -C "$UPD_SRC/seed" remote add origin "$UPD_SRC/origin.git"
git -C "$UPD_SRC/seed" push -q -u origin main
git clone -q "$UPD_SRC/origin.git" "$UPD_SRC/clean" 2>/dev/null
# The second commit touches AGENTS.md, so the fast-forward must report
# "instructions changed" and the summary must say reread-firstmate: yes.
printf 'new instructions\n' > "$UPD_SRC/seed/AGENTS.md"
git -C "$UPD_SRC/seed" commit -q -a -m two
git -C "$UPD_SRC/seed" push -q origin main

# The operational dirs live OUTSIDE the checkout for the clean case, because an
# untracked data/ would make the tree dirty and the fast-forward would refuse.
mk_home "$TMP_ROOT/upd-home-bash"
mk_home "$TMP_ROOT/upd-home-ps"
{
  printf -- '- ghost - never seeded (home: %s/nope; scope: nothing; projects: none; added 2026-01-01)\n' "$TMP_ROOT"
  printf -- '- malformed entry with no suffix\n'
} > "$TMP_ROOT/upd-home-bash/data/secondmates.md"
cp "$TMP_ROOT/upd-home-bash/data/secondmates.md" "$TMP_ROOT/upd-home-ps/data/secondmates.md"
cp -r "$UPD_SRC/clean" "$TMP_ROOT/upd-bash"
cp -r "$UPD_SRC/clean" "$TMP_ROOT/upd-ps"
# A second pair left DIRTY, to drive the refusal.
cp -r "$UPD_SRC/clean" "$TMP_ROOT/upd-dirty-bash"
cp -r "$UPD_SRC/clean" "$TMP_ROOT/upd-dirty-ps"
printf 'local edit\n' > "$TMP_ROOT/upd-dirty-bash/AGENTS.md"
printf 'local edit\n' > "$TMP_ROOT/upd-dirty-ps/AGENTS.md"
mk_home "$TMP_ROOT/upd-dirty-home-bash"
mk_home "$TMP_ROOT/upd-dirty-home-ps"
fi

# --- merge-local fixture ------------------------------------------------------

if want merge; then
mk_merge_world() {  # <suffix>
  local w=$1 home="$TMP_ROOT/ml-$1"
  mk_home "$home"
  # A fresh watcher beacon keeps fm-guard silent even though metadata exists;
  # see the header on why a printing guard would be a systematic mismatch.
  : > "$home/state/.last-watcher-beat"
  # fm-merge-local is the ONE entrypoint here that runs the guard from
  # "$FM_ROOT/bin", not from its own script dir, so pointing FM_ROOT_OVERRIDE at
  # this home (which keeps the real checkout's live branch out of the tangle
  # check) also moves where the guard is looked up. A silent STUB is planted at
  # that exact path so BOTH worlds run the same no-op: without it bash reports
  # "No such file or directory" into the captured case answer while
  # Invoke-FmScript returns 127 silently, and the phase then fails on a fixture
  # artifact rather than on anything the twins do.
  mkdir -p "$home/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/bin/fm-guard.sh"
  chmod +x "$home/bin/fm-guard.sh"
  mk_repo "$TMP_ROOT/ml-proj-$w"
  git -C "$TMP_ROOT/ml-proj-$w" checkout -q -b fm/ok
  printf 'landed\n' > "$TMP_ROOT/ml-proj-$w/f.txt"
  git -C "$TMP_ROOT/ml-proj-$w" commit -q -a -m two
  git -C "$TMP_ROOT/ml-proj-$w" checkout -q main
  # A diverged branch: main gains a commit the branch does not have.
  git -C "$TMP_ROOT/ml-proj-$w" checkout -q -b fm/diverged
  printf 'branch side\n' > "$TMP_ROOT/ml-proj-$w/b.txt"
  git -C "$TMP_ROOT/ml-proj-$w" add b.txt
  git -C "$TMP_ROOT/ml-proj-$w" commit -q -m branchside
  git -C "$TMP_ROOT/ml-proj-$w" checkout -q main
  printf 'main side\n' > "$TMP_ROOT/ml-proj-$w/m.txt"
  git -C "$TMP_ROOT/ml-proj-$w" add m.txt
  git -C "$TMP_ROOT/ml-proj-$w" commit -q -m mainside
  # Separate checkouts for the off-default and dirty refusals, so one case
  # cannot put another out of reach.
  mk_repo "$TMP_ROOT/ml-off-$w" feature/y
  git -C "$TMP_ROOT/ml-off-$w" branch -q fm/off
  mk_repo "$TMP_ROOT/ml-dirty-$w"
  git -C "$TMP_ROOT/ml-dirty-$w" branch -q fm/dirt
  printf 'uncommitted\n' > "$TMP_ROOT/ml-dirty-$w/f.txt"

  printf 'project=%s\nmode=local-only\n' "$TMP_ROOT/ml-proj-$w" > "$home/state/ok.meta"
  printf 'project=%s\nmode=local-only\n' "$TMP_ROOT/ml-proj-$w" > "$home/state/diverged.meta"
  printf 'project=%s\nmode=local-only\n' "$TMP_ROOT/ml-proj-$w" > "$home/state/nobranch.meta"
  printf 'project=%s\nmode=no-mistakes\n' "$TMP_ROOT/ml-proj-$w" > "$home/state/wrongmode.meta"
  printf 'project=%s\nmode=local-only\n' "$TMP_ROOT/ml-off-$w" > "$home/state/off.meta"
  printf 'project=%s\nmode=local-only\n' "$TMP_ROOT/ml-dirty-$w" > "$home/state/dirt.meta"
}
mk_merge_world bash
mk_merge_world ps
fi

# =============================================================================
# case plumbing
# =============================================================================

ORACLE_FILE="$TMP_ROOT/oracle.tsv"
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$ORACLE_FILE"
: > "$CASE_FILE"

TOUCHED_ENV="FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE
FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_SNAPSHOT_NOW FM_SNAPSHOT_NOW_EPOCH
FM_SNAPSHOT_SECONDMATES FM_SNAPSHOT_SECONDMATE_TIMEOUT
FM_SNAPSHOT_SECONDMATE_MAX_BYTES FM_SNAPSHOT_SECONDMATE_CHILDREN
FM_SNAPSHOT_SECONDMATE_QUEUED FM_SNAPSHOT_SECONDMATE_DECISIONS
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME FM_SNAPSHOT_TERMINAL_LINES
FM_SNAPSHOT_TERMINAL_BYTES FM_SNAPSHOT_TERMINAL_TIMEOUT
FM_SNAPSHOT_PARENT_ACTIVITY_LINES FM_SNAPSHOT_PARENT_ACTIVITY_BYTES
FM_SNAPSHOT_PARENT_ACTIVITIES FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT
FM_SNAPSHOT_REGISTRY_LINES FM_SNAPSHOT_REGISTRY_BYTES
FM_SNAPSHOT_REGISTRY_RECORDS FM_SNAPSHOT_REGISTRY_TIMEOUT
FM_FLEET_PRUNE FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS FM_GUARD_GRACE"

CASE_ENV=()
CASE_PS_ENV=()

# run_case <label> <script> [args...] - drives the BASH twin, records both the
# oracle answer and the PowerShell case record. CASE_ENV is the bash-side
# environment; CASE_PS_ENV, when non-empty, is the PowerShell-side one, which is
# how a MUTATING case points each world at its own copy of a fixture. Both are
# consumed and reset.
run_case() {
  local label=$1 script=$2
  shift 2
  local kv name value rc out err args_raw env_raw a

  # shellcheck disable=SC2086  # deliberate word splitting over the name list
  unset $TOUCHED_ENV
  for kv in ${CASE_ENV[@]+"${CASE_ENV[@]}"}; do
    [ -n "$kv" ] || continue
    name=${kv%%=*}
    value=${kv#*=}
    export "$name=$value"
  done

  env_raw=""
  if [ ${#CASE_PS_ENV[@]} -gt 0 ]; then
    for kv in "${CASE_PS_ENV[@]}"; do
      [ -n "$kv" ] || continue
      if [ -n "$env_raw" ]; then env_raw="$env_raw$US$kv"; else env_raw=$kv; fi
    done
  else
    for kv in ${CASE_ENV[@]+"${CASE_ENV[@]}"}; do
      [ -n "$kv" ] || continue
      if [ -n "$env_raw" ]; then env_raw="$env_raw$US$kv"; else env_raw=$kv; fi
    done
  fi

  "$ROOT/bin/$script.sh" "$@" >"$TMP_ROOT/.stdout" 2>"$TMP_ROOT/.stderr"
  rc=$?
  out=""
  err=""
  # `read -r -d ''` slurps the whole file with a BUILTIN; `$(cat ...)` would fork
  # twice per case, and this suite runs well over a hundred of them.
  IFS= read -r -d '' out < "$TMP_ROOT/.stdout" || true
  IFS= read -r -d '' err < "$TMP_ROOT/.stderr" || true

  args_raw=""
  for a in "$@"; do
    enc "$a"
    if [ -n "$args_raw" ]; then args_raw="$args_raw$US$ENC"; else args_raw=$ENC; fi
  done

  local ans
  enc "$out"; ans="$rc$US$ENC"
  enc "$err"; ans="$ans$US$ENC"
  printf '%s\t%s\n' "$label" "$ans" >> "$ORACLE_FILE"
  printf '%s\t%s\t%s\t%s\n' "$label" "$script" "$args_raw" "$env_raw" >> "$CASE_FILE"

  CASE_ENV=()
  CASE_PS_ENV=()
}

# =============================================================================
# phase 1: fm-fleet-snapshot
# =============================================================================

if want snapshot; then

snap_env() {  # [extra=value ...]
  CASE_ENV=("FM_HOME=$SNAP" "FM_SNAPSHOT_NOW=$PIN_NOW" "FM_SNAPSHOT_NOW_EPOCH=$PIN_EPOCH"
            "${PIN_TIMEOUTS[@]}" "$@")
}

# Argument surface. `--help` and `-h` print the same block on stdout at 0; an
# unknown word prints it on STDERR at 2; an empty first argument takes the
# `${1:---json}` default rather than being an unknown word.
snap_env; run_case snap-help fm-fleet-snapshot --help
snap_env; run_case snap-help-h fm-fleet-snapshot -h
snap_env; run_case snap-bad-arg fm-fleet-snapshot --nope

# Bound validation happens BEFORE argument parsing in the bash twin, so an
# invalid bound refuses even a `--help` invocation. Both refusals name the knob.
snap_env FM_SNAPSHOT_SECONDMATES=x; run_case snap-bound-secondmates fm-fleet-snapshot --help
snap_env FM_SNAPSHOT_TERMINAL_LINES=0; run_case snap-bound-zero fm-fleet-snapshot --json
snap_env FM_SNAPSHOT_REGISTRY_BYTES=nope; run_case snap-bound-nondigit fm-fleet-snapshot --json

# The whole contract, including the recursive secondmate read.
snap_env; run_case snap-json fm-fleet-snapshot --json
snap_env; run_case snap-summary fm-fleet-snapshot --secondmate-home-summary

# A cap of 0 LIFTS the secondmate bound rather than emptying the list, and a
# record cap of 1 must disclose record_limit truncation rather than silently
# dropping a registered home.
snap_env FM_SNAPSHOT_SECONDMATES=0; run_case snap-cap-lifted fm-fleet-snapshot --json
snap_env FM_SNAPSHOT_REGISTRY_RECORDS=1; run_case snap-registry-trunc fm-fleet-snapshot --json

# An empty home: absent backlog, no metadata, no registry, no reports.
CASE_ENV=("FM_HOME=$SNAP_EMPTY" "FM_SNAPSHOT_NOW=$PIN_NOW" "FM_SNAPSHOT_NOW_EPOCH=$PIN_EPOCH" "${PIN_TIMEOUTS[@]}")
run_case snap-empty fm-fleet-snapshot --json
CASE_ENV=("FM_HOME=$SNAP_EMPTY" "FM_SNAPSHOT_NOW=$PIN_NOW" "FM_SNAPSHOT_NOW_EPOCH=$PIN_EPOCH" "${PIN_TIMEOUTS[@]}")
run_case snap-empty-summary fm-fleet-snapshot --secondmate-home-summary

fi

# =============================================================================
# phase 2: fm-fleet-view
# =============================================================================

if want view; then

CASE_ENV=("FM_HOME=$SNAP"); run_case view-help fm-fleet-view --help
CASE_ENV=("FM_HOME=$SNAP"); run_case view-help-h fm-fleet-view -h
CASE_ENV=("FM_HOME=$SNAP"); run_case view-bad-arg fm-fleet-view --nope
CASE_ENV=("FM_HOME=$SNAP" "FM_SNAPSHOT_NOW=$PIN_NOW" "FM_SNAPSHOT_NOW_EPOCH=$PIN_EPOCH" "${PIN_TIMEOUTS[@]}")
run_case view-render fm-fleet-view
CASE_ENV=("FM_HOME=$SNAP_EMPTY" "FM_SNAPSHOT_NOW=$PIN_NOW" "FM_SNAPSHOT_NOW_EPOCH=$PIN_EPOCH" "${PIN_TIMEOUTS[@]}")
run_case view-render-empty fm-fleet-view

fi

# =============================================================================
# phase 3: fm-fleet-sync
# =============================================================================

if want sync; then

# fm-fleet-sync runs "$FM_ROOT/bin/fm-guard.sh" and "$FM_ROOT/bin/fm-project-mode.sh"
# from FM_ROOT, not from its own script dir. Left unset, FM_ROOT is the REAL
# checkout - so the guard's worktree-tangle banner fires for every case whenever
# this suite is run from a feature branch, and the phase's result depends on
# which branch the runner happens to be on. That is a fixture artifact, not a
# twin difference: both worlds emit the banner identically, they just capture it
# differently.
#
# Same remedy the merge phase already uses: point FM_ROOT_OVERRIDE at a scratch
# root carrying a SILENT guard stub, so both worlds run the same no-op. The mode
# resolver is copied in rather than stubbed, because a MISSING one makes bash
# report "No such file or directory" into the captured answer while the twin
# returns 127 silently - failing the phase on the fixture instead of on the code.
SYNC_ROOT="$TMP_ROOT/sync-root"
mk_sync_root() {
  mkdir -p "$SYNC_ROOT/bin"
  printf '#!/usr/bin/env bash
exit 0
' > "$SYNC_ROOT/bin/fm-guard.sh"
  chmod +x "$SYNC_ROOT/bin/fm-guard.sh"
  cp "$ROOT/bin/fm-project-mode.sh" "$SYNC_ROOT/bin/fm-project-mode.sh"
  chmod +x "$SYNC_ROOT/bin/fm-project-mode.sh"
}
mk_sync_root

CASE_ENV=("FM_HOME=$TMP_ROOT/sync-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-help fm-fleet-sync --help
CASE_ENV=("FM_HOME=$TMP_ROOT/sync-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-too-many fm-fleet-sync a b

# The whole sweep: fast-forward, prune, and every refusal in one ordered listing.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-sweep fm-fleet-sync

# A second sweep over the SAME (now advanced) clones proves the already-current
# and no-op-prune arms, which the first sweep cannot reach.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-sweep-again fm-fleet-sync

# Argument forms, against the untouched second pair. A bare name and the
# "projects/<name>" form both resolve against this home's projects dir; an
# unresolvable argument still reaches the "not a directory" skip.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-one-bare fm-fleet-sync behind
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-one-projects fm-fleet-sync projects/stuck
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-one-missing fm-fleet-sync no-such-project
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-one-localonly fm-fleet-sync localonly

# FM_FLEET_PRUNE=0 must leave a [gone] branch alone.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT" FM_FLEET_PRUNE=0)
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT" FM_FLEET_PRUNE=0)
run_case sync-prune-off fm-fleet-sync prune
# ...and the default must then prune it.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT"); CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT")
run_case sync-prune-on fm-fleet-sync prune

# An invalid retry-wait is reported and defaulted rather than used.
CASE_ENV=("FM_HOME=$TMP_ROOT/sync1-bash" "FM_ROOT_OVERRIDE=$SYNC_ROOT" FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=abc)
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/sync1-ps" "FM_ROOT_OVERRIDE=$SYNC_ROOT" FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=abc)
run_case sync-bad-wait fm-fleet-sync --help

fi

# =============================================================================
# phase 4: fm-update
# =============================================================================

if want update; then

CASE_ENV=("FM_HOME=$TMP_ROOT/upd-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-ps")
run_case upd-help fm-update --help
CASE_ENV=("FM_HOME=$TMP_ROOT/upd-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-ps")
run_case upd-help-h fm-update -h
CASE_ENV=("FM_HOME=$TMP_ROOT/upd-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-ps")
run_case upd-extra-arg fm-update wat

# The dirty refusal, and the registry backstop reporting a malformed entry and an
# unsafe home. Nothing is forced, and the summary still reports.
CASE_ENV=("FM_HOME=$TMP_ROOT/upd-dirty-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-dirty-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-dirty-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-dirty-ps")
run_case upd-dirty fm-update

# The clean fast-forward, whose instruction-surface change must set
# reread-firstmate: yes.
CASE_ENV=("FM_HOME=$TMP_ROOT/upd-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-ps")
run_case upd-clean fm-update
# ...and a second run is already current.
CASE_ENV=("FM_HOME=$TMP_ROOT/upd-home-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-bash")
CASE_PS_ENV=("FM_HOME=$TMP_ROOT/upd-home-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/upd-ps")
run_case upd-current fm-update

fi

# =============================================================================
# phase 5: fm-merge-local
# =============================================================================

if want merge; then

ml_env() {  # <task-id-less>: points each world at its own home
  # FM_ROOT_OVERRIDE is as load-bearing as FM_HOME here. Without it FM_ROOT
  # falls back to the REAL firstmate checkout, whose live branch and
  # uncommitted state make fm-guard's worktree-tangle check print - and a
  # printing guard contaminates stdout in a phase built to compare silence,
  # which is exactly what the suite's own premise check caught. Pointing it at
  # the (non-git) home keeps the check inert, the same technique
  # tests/fm-bootstrap.test.sh uses for the same reason.
  CASE_ENV=("FM_HOME=$TMP_ROOT/ml-bash" "FM_ROOT_OVERRIDE=$TMP_ROOT/ml-bash")
  CASE_PS_ENV=("FM_HOME=$TMP_ROOT/ml-ps" "FM_ROOT_OVERRIDE=$TMP_ROOT/ml-ps")
}

ml_env; run_case ml-no-arg fm-merge-local
ml_env; run_case ml-no-meta fm-merge-local nosuch
ml_env; run_case ml-wrong-mode fm-merge-local wrongmode
ml_env; run_case ml-no-branch fm-merge-local nobranch
ml_env; run_case ml-off-default fm-merge-local off
ml_env; run_case ml-dirty fm-merge-local dirt
ml_env; run_case ml-diverged fm-merge-local diverged
ml_env; run_case ml-ok fm-merge-local ok

fi

# =============================================================================
# the PowerShell half: ONE pwsh for every case
# =============================================================================

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

DRIVER="$TMP_ROOT/driver.ps1"
{
  printf 'Set-StrictMode -Version Latest\n'
  printf "\$ErrorActionPreference = 'Continue'\n"
  printf "\$US = [char]0x1f\n\$RS = [char]0x1e\n\$GS = [char]0x1d\n\$FS = [char]0x1c\n"
  printf "\$CaseFile = '%s'\n" "$(to_native "$CASE_FILE")"
  printf "\$OutFile  = '%s'\n" "$(to_native "$TMP_ROOT/ps-answers.tsv")"
  printf "\$BinDir   = '%s'\n" "$(to_native "$ROOT/bin")"
} > "$DRIVER"
cat >> "$DRIVER" <<'PSEOF'

function Restore-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace($RS, "`n").Replace($GS, "`r").Replace($FS, "`t")
}

function Protect-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", $GS).Replace("`n", $RS).Replace("`t", $FS)
}

# Pre-imported ONCE, before any console redirection: fm-common's body assigns
# [Console]::OutputEncoding, and that assignment REBUILDS [Console]::Out. Doing
# it inside the first redirected case would silently discard that case's output.
# Every module the five entrypoints touch is warmed here for the same reason and
# to keep the per-case cost to the script body alone.
foreach ($m in @('fm-common', 'fm-ff-lib', 'fm-secondmate-registry-lib', 'fm-lock-lib',
        'fm-backend', 'fm-classify-lib', 'fm-psproc-lib')) {
    Import-Module (Join-Path $BinDir "$m.psm1") -ErrorAction SilentlyContinue
}

# Every environment name any case may set, cleared before each case so a value
# from one case can never leak into the next - the batch equivalent of a bash
# prefix assignment, which does NOT survive to a single trailing pwsh run.
$TouchedNames = @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
    'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_SNAPSHOT_NOW', 'FM_SNAPSHOT_NOW_EPOCH',
    'FM_SNAPSHOT_SECONDMATES', 'FM_SNAPSHOT_SECONDMATE_TIMEOUT',
    'FM_SNAPSHOT_SECONDMATE_MAX_BYTES', 'FM_SNAPSHOT_SECONDMATE_CHILDREN',
    'FM_SNAPSHOT_SECONDMATE_QUEUED', 'FM_SNAPSHOT_SECONDMATE_DECISIONS',
    'FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME', 'FM_SNAPSHOT_TERMINAL_LINES',
    'FM_SNAPSHOT_TERMINAL_BYTES', 'FM_SNAPSHOT_TERMINAL_TIMEOUT',
    'FM_SNAPSHOT_PARENT_ACTIVITY_LINES', 'FM_SNAPSHOT_PARENT_ACTIVITY_BYTES',
    'FM_SNAPSHOT_PARENT_ACTIVITIES', 'FM_SNAPSHOT_PARENT_ACTIVITY_TIMEOUT',
    'FM_SNAPSHOT_REGISTRY_LINES', 'FM_SNAPSHOT_REGISTRY_BYTES',
    'FM_SNAPSHOT_REGISTRY_RECORDS', 'FM_SNAPSHOT_REGISTRY_TIMEOUT',
    'FM_FLEET_PRUNE', 'FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES',
    'FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS',
    'FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS', 'FM_GUARD_GRACE')

$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
$Answers = [System.Text.StringBuilder]::new()

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    # Split on the record's real TAB, NOT on $FS: FS is the ESCAPE for a tab that
    # appears inside a value, which is exactly why the record separator can still
    # be a plain tab. StringSplitOptions::None keeps trailing empty fields, which
    # most cases legitimately have, and the COUNT is asserted rather than assumed.
    $fields = @($line.Split("`t", [System.StringSplitOptions]::None))
    if ($fields.Count -ne 4) {
        [void]$Answers.AppendLine("PARSE-ERROR-$($fields.Count)`tfields=$($fields.Count)")
        continue
    }
    $label = $fields[0]
    $scriptName = $fields[1]
    $argsRaw = $fields[2]
    $envRaw = $fields[3]

    $caseArgs = @()
    if (-not [string]::IsNullOrEmpty($argsRaw)) {
        # Wrapped in @(...): PowerShell unrolls a single-element array into a bare
        # string, which would then splat as characters.
        foreach ($a in @($argsRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            $caseArgs += (Restore-CaseText $a)
        }
    }

    foreach ($n in $TouchedNames) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    if (-not [string]::IsNullOrEmpty($envRaw)) {
        foreach ($kv in @($envRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            if ([string]::IsNullOrEmpty($kv)) { continue }
            $eq = $kv.IndexOf('=')
            if ($eq -lt 1) { continue }
            Set-Item -LiteralPath "env:$($kv.Substring(0, $eq))" -Value $kv.Substring($eq + 1)
        }
    }

    $outWriter = [System.IO.StringWriter]::new()
    $errWriter = [System.IO.StringWriter]::new()
    $rc = 0
    try {
        [Console]::SetOut($outWriter)
        [Console]::SetError($errWriter)
        $global:LASTEXITCODE = 0
        & (Join-Path $BinDir "$scriptName.ps1") @caseArgs
        $rc = $LASTEXITCODE
    } catch {
        $errWriter.Write("DRIVER-EXCEPTION: $($_.Exception.Message)`n")
        $rc = 99
    } finally {
        [Console]::SetOut($OrigOut)
        [Console]::SetError($OrigErr)
    }

    $outText = $outWriter.ToString() -replace "`r`n", "`n"
    $errText = $errWriter.ToString() -replace "`r`n", "`n"
    $answer = "$rc$US" + (Protect-CaseText $outText) + $US + (Protect-CaseText $errText)
    [void]$Answers.AppendLine("$label`t$answer")
}

[System.IO.File]::WriteAllText($OutFile, $Answers.ToString().Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false))
PSEOF

PS_ANSWERS="$TMP_ROOT/ps-answers.tsv"
pwsh -NoProfile -File "$(to_native "$DRIVER")" >"$TMP_ROOT/driver.log" 2>&1 || {
  printf 'not ok - the PowerShell driver failed to run\n' >&2
  cat "$TMP_ROOT/driver.log" >&2
  exit 1
}
[ -f "$PS_ANSWERS" ] || {
  printf 'not ok - the PowerShell driver produced no answers\n' >&2
  cat "$TMP_ROOT/driver.log" >&2
  exit 1
}

# =============================================================================
# join by label and compare
# =============================================================================

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# --- the per-world fixture substitutions --------------------------------------
#
# Every MUTATING case runs each world against its OWN copy of a fixture, so the
# two worlds legitimately name two different directories for the same role. That
# is a fixture fact, not a behavior difference, so each world's own fixture path
# is replaced by the same ROLE token before comparison - the same technique the
# W4-session suite uses for its per-world session homes.
#
# Longest paths first, so a shorter sibling can never eat a prefix of a longer
# one. These are the ONLY string substitutions beyond the two path rules in the
# header; no message text is otherwise touched.
SUB_FROM_BASH=()
SUB_FROM_PS=()
SUB_TO=()
add_world_sub() {  # <bash-path> <ps-path> <token>
  SUB_FROM_BASH+=("$1")
  SUB_FROM_PS+=("$2")
  SUB_TO+=("$3")
}
add_world_sub "$TMP_ROOT/upd-dirty-home-bash" "$TMP_ROOT/upd-dirty-home-ps" '<UPD-DIRTY-HOME>'
add_world_sub "$TMP_ROOT/upd-dirty-bash" "$TMP_ROOT/upd-dirty-ps" '<UPD-DIRTY-ROOT>'
add_world_sub "$TMP_ROOT/upd-home-bash" "$TMP_ROOT/upd-home-ps" '<UPD-HOME>'
add_world_sub "$TMP_ROOT/upd-bash" "$TMP_ROOT/upd-ps" '<UPD-ROOT>'
add_world_sub "$TMP_ROOT/sync1-bash" "$TMP_ROOT/sync1-ps" '<SYNC1-HOME>'
add_world_sub "$TMP_ROOT/sync-bash" "$TMP_ROOT/sync-ps" '<SYNC-HOME>'
add_world_sub "$TMP_ROOT/ml-proj-bash" "$TMP_ROOT/ml-proj-ps" '<ML-PROJ>'
add_world_sub "$TMP_ROOT/ml-dirty-bash" "$TMP_ROOT/ml-dirty-ps" '<ML-DIRTY>'
add_world_sub "$TMP_ROOT/ml-off-bash" "$TMP_ROOT/ml-off-ps" '<ML-OFF>'
add_world_sub "$TMP_ROOT/ml-bash" "$TMP_ROOT/ml-ps" '<ML-HOME>'
SUB_COUNT=${#SUB_TO[@]}

# norm <text> <world>: sets NORMED. See the header for the two path rules and why
# their ORDER matters, then the per-world fixture substitutions above. Pure
# parameter expansion - no `$( )`, no sed - because this runs once per side per
# assertion and a fork here has turned a passing suite into an hour-long timeout
# before.
NORMED=""
NORM_DRIVES="A B C D E F G H I J K L M N O P Q R S T U V W X Y Z"
norm() {
  local s=$1 world=$2 u l pat rep i
  s=${s//\\\\//}
  s=${s//\\//}
  for u in $NORM_DRIVES; do
    l=${u,,}
    pat="$u:/"; rep="/$l/"
    s=${s//"$pat"/"$rep"}
    pat="$l:/"
    s=${s//"$pat"/"$rep"}
  done
  for ((i = 0; i < SUB_COUNT; i++)); do
    if [ "$world" = bash ]; then
      s=${s//"${SUB_FROM_BASH[$i]}"/"${SUB_TO[$i]}"}
    else
      s=${s//"${SUB_FROM_PS[$i]}"/"${SUB_TO[$i]}"}
    fi
  done
  NORMED=$s
}

EXP=""
ACT=""
assert_same() {  # <label> <expected(bash)> <actual(pwsh)>
  local label=$1
  norm "$2" bash; EXP=$NORMED
  norm "$3" pwsh; ACT=$NORMED
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$EXP" != "$ACT" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${EXP}]
  actual(pwsh)  : [${ACT}]
"
  fi
}

declare -A PS_ANSWER=()
while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  PS_ANSWER[$label]=$answer
done < "$PS_ANSWERS"

while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  if [ -z "${PS_ANSWER[$label]+x}" ]; then
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${answer}]
  actual(pwsh)  : <NO ANSWER - the driver never reported this label>
"
    continue
  fi
  ps_answer=${PS_ANSWER[$label]}
  case "$label" in
    ml-no-arg)
      # DECLARED DIVERGENCE: the missing-argument diagnostic. The bash uses
      # `${1:?usage: ...}`, whose message BASH ITSELF emits with the shell's own
      # prefix and the source LINE NUMBER ("...fm-merge-local.sh: line 20: 1:
      # usage: ..."). No PowerShell construct produces that shape, and faking a
      # bash line number would be a lie. What the contract actually requires is
      # asserted instead: the same exit code, and the same usage sentence at the
      # end of stderr. Recorded in bin/fm-merge-local.ps1's header.
      for world in bash pwsh; do
        if [ "$world" = bash ]; then v=$answer; else v=$ps_answer; fi
        rc_part=${v%%$US*}
        err_part=${v##*$US}
        err_part=${err_part%"$RS"}   # the answer's encoded trailing newline
        ASSERTIONS=$((ASSERTIONS + 1))
        case "$rc_part|$err_part" in
          '1|'*'usage: fm-merge-local.sh <task-id>') ;;
          *)
            FAILURES=$((FAILURES + 1))
            FAILURE_TEXT="${FAILURE_TEXT}${label} ($world)
  expected: exit 1 and stderr ending in 'usage: fm-merge-local.sh <task-id>'
  actual  : [${rc_part}|${err_part}]
"
            ;;
        esac
      done
      ;;
    *)
      assert_same "$label" "$answer" "$ps_answer"
      ;;
  esac
done < "$ORACLE_FILE"

# --- the guard-silence assumption --------------------------------------------
#
# Every guard-calling fixture is built to keep fm-guard quiet, because the guard
# writes through an INHERITED stream that the driver cannot capture on the
# PowerShell side (see the header). If that ever stops holding, the comparison
# above would start failing for a reason that has nothing to do with the twins -
# so the assumption is asserted directly, on the side that CAN see it.
while IFS=$'\t' read -r label answer; do
  case "$label" in
    sync-*|upd-*|ml-*) ;;
    *) continue ;;
  esac
  ASSERTIONS=$((ASSERTIONS + 1))
  case "$answer" in
    *"WATCHER DOWN"*|*"queued wake"*|*"TANGLE"*)
      FAILURES=$((FAILURES + 1))
      FAILURE_TEXT="${FAILURE_TEXT}${label}
  the guard printed in a fixture built to keep it silent, so this phase's
  comparison is no longer meaningful; give the fixture a fresh watcher beacon,
  an empty wake queue, and a default-branch FM_ROOT.
"
      ;;
  esac
done < "$ORACLE_FILE"

# --- the one case the batch cannot drive --------------------------------------
#
# `fm-fleet-view --json` hands its child the REAL process streams
# (Invoke-FmScript -Stream), which bypasses the driver's console redirection by
# construction. Driving it inside the batch would compare an empty answer against
# a full snapshot and call it a failure of the twin. So it gets its own real
# process - one extra pwsh, a constant, not a per-case cost.
if want view; then
  # This block runs AFTER every phase, and run_case's per-case cleanup cannot
  # reach it - the last case of the last phase leaves its own FM_HOME and
  # FM_ROOT_OVERRIDE exported. Clearing them here is what stops the merge
  # phase's fixture root from silently becoming this snapshot's fm_root.
  # shellcheck disable=SC2086  # deliberate word splitting over the name list
  unset $TOUCHED_ENV
  # The same raised bounded-read timeouts the batched snapshot cases use; see
  # PIN_TIMEOUTS above for why the machine's fork cost must not decide the answer.
  export "${PIN_TIMEOUTS[@]}"
  FM_HOME="$SNAP" FM_SNAPSHOT_NOW="$PIN_NOW" FM_SNAPSHOT_NOW_EPOCH="$PIN_EPOCH" \
    "$ROOT/bin/fm-fleet-view.sh" --json >"$TMP_ROOT/.vj-bash" 2>"$TMP_ROOT/.vj-bash-err"
  VJ_BASH_RC=$?
  FM_HOME="$SNAP" FM_SNAPSHOT_NOW="$PIN_NOW" FM_SNAPSHOT_NOW_EPOCH="$PIN_EPOCH" \
    pwsh -NoProfile -File "$(to_native "$ROOT/bin/fm-fleet-view.ps1")" --json \
    >"$TMP_ROOT/.vj-ps" 2>"$TMP_ROOT/.vj-ps-err"
  VJ_PS_RC=$?
  assert_same "view-json (exit code)" "$VJ_BASH_RC" "$VJ_PS_RC"
  VJ_B=""
  VJ_P=""
  IFS= read -r -d '' VJ_B < "$TMP_ROOT/.vj-bash" || true
  IFS= read -r -d '' VJ_P < "$TMP_ROOT/.vj-ps" || true
  assert_same "view-json (snapshot passthrough)" "$VJ_B" "$VJ_P"
fi

# =============================================================================
# report
# =============================================================================

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W4-fleet twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# Asserted from an OBSERVED green run, so a refactor that silently drops whole
# phases fails loudly instead of certifying an empty suite.
#
# The counts below are per PHASE and were read off a green run of that phase, and
# their sum is the 70 a green FULL run reports - so the floor is exact rather
# than a guess, and it stays exact under the phase selector instead of having to
# be relaxed to a token 1 that would certify almost anything.
MIN_ASSERTIONS=0
want snapshot && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 12))
want view     && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 7))
want sync     && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 22))
want update   && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 12))
want merge    && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 17))
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the five W4-fleet twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-fleet-psm1.test.sh: all assertions passed\n'
