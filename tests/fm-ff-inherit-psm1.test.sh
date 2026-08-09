#!/usr/bin/env bash
# Behavior test for bin/fm-ff-lib.psm1 and bin/fm-config-inherit-lib.psm1 - the
# PowerShell twins of the guarded fast-forward machinery and of inherited
# local-material propagation.
#
# DIFFERENTIAL, with BASH AS THE ORACLE. Every assertion drives the bash function
# and the PowerShell function over the SAME fixture recipe and compares the
# answers; no expectation is hard-coded, so a case can never quietly encode what
# the author believed instead of what the shipped library does. Each assertion
# label names the module it covers, [ff] or [inherit], so a failure is
# attributable without reading the code.
#
# WHY THE REFUSALS DOMINATE THIS FILE. fm-ff-lib is one of the few paths in the
# tree allowed to move a checkout, and every "skipped:" arm is a decision NOT to
# touch someone's unlanded work. A twin that recovered where the oracle refuses
# would be worse than one that failed outright, because it would look like it
# worked. So each refusal is asserted three ways: the exact reported line, the
# recorded status, and the fixture's own state afterwards (HEAD unmoved, edit
# still on disk).
#
# TWIN FIXTURES, IDENTICAL COMMITS. bash mutates the checkout it fast-forwards,
# so each case builds its world TWICE from one recipe - .../<case>/bash and
# .../<case>/ps. Author and committer identity AND dates are pinned, so the two
# copies produce BYTE-IDENTICAL commit SHAs: a git commit hash covers the tree,
# parents, identity, dates and message, and never the path. That is what makes
# "diverged from <sha>" and the post-run HEADs directly comparable rather than
# needing a second layer of normalization.
#
# BATCHED pwsh - the rule that decides whether this suite finishes. A bare
# `pwsh -NoProfile -Command "exit 0"` costs ~4.8s on the reference host, so a
# pwsh per case would spend 25-60 minutes in interpreter startup alone and
# present as a hang, not as slowness. Every case is therefore written to a FILE
# and evaluated by ONE pwsh, which also performs its own post-state probes and
# returns everything as label<TAB>value records that bash joins by LABEL.
#
# Three consequences of batching, each of which has bitten this repo:
#   - Per-case environment cannot ride on the shell. A bash prefix assignment
#     persists after a function call, so by the time the single pwsh runs it
#     would hold only the LAST value assigned. Per-case env travels in the case
#     RECORD and is applied and cleared around each case on the PowerShell side.
#   - Nothing runs inside a `( ... )` subshell whose counter updates could not
#     reach the parent, because a failure that vanishes reads as a pass.
#   - No probe is keyed by a path: the two worlds spell the same location
#     differently, so such a key never matches and every case would read
#     MISSING-KEY even when the values agree. Keys are stable labels.
#
# NORMALIZATION, DECLARED RATHER THAN APPLIED SILENTLY. Exactly four
# transformations are applied to values that can carry a path, and both sides
# apply the same ones:
#   1. the temp root becomes @R@ and separators become '/', because the two
#      worlds legitimately spell one directory as /tmp/x and C:\...\Temp\x;
#   2. the per-world segment /bash/ or /ps/ becomes /W/, because the two copies
#      of one fixture are deliberately different directories;
#   3. a quarantine timestamp becomes @S@, because the two phases run minutes
#      apart on this host and the stamp is wall-clock;
#   4. a quarantine collision suffix (.1, .2, ...) is dropped, because whether
#      the computed name was already taken is decided by that same wall clock.
#      What the suffix EXISTS to guarantee is asserted where timing cannot reach
#      it: the artifact count, and the bytes each artifact still holds.
# Nothing else is softened. The content HASH inside a quarantine name, every
# reported reason, every status and every exit code still have to match exactly.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in fm-ff-lib.psm1 fm-config-inherit-lib.psm1 fm-common.psm1 \
  fm-secondmate-registry-lib.psm1 fm-startup-memory-budget-lib.psm1; do
  [ -f "$ROOT/bin/$f" ] || fail "bin/$f is missing"
done

# The oracles. fm-ff-lib.sh sources fm-secondmate-registry-lib.sh and
# fm-config-inherit-lib.sh sources fm-startup-memory-budget-lib.sh, so the whole
# closure of both libraries is live in this shell.
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ff-inherit-psm1)

# Deterministic identity AND dates: see the twin-fixtures note in the header.
fm_git_identity fmtest fmtest@example.invalid
export GIT_AUTHOR_DATE='2026-01-01T00:00:00 +0000'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00 +0000'

# Native spellings, resolved ONCE. fm_test_native_path is a cygpath process, and
# at ~360ms a call the per-path form would dominate this suite; every later
# conversion is pure parameter expansion off these two roots.
TMP_ROOT_N=$(fm_test_native_path "$TMP_ROOT")
BIN_N=$(fm_test_native_path "$ROOT/bin")

FM_NAT=
nat() {  # <path under TMP_ROOT> -> FM_NAT (native Windows spelling)
  local rel=${1#"$TMP_ROOT"}
  FM_NAT="$TMP_ROOT_N${rel//\//\\}"
}

# Progress markers. This suite drives a few hundred git invocations through the
# bash oracle, and a git spawn costs ~2.4s under load on this host, so a silent
# run reads as a hang long before it is one. Each phase announces itself as it
# starts, so an operator watching the log can tell slowness from a stall.
PHASE_START=$SECONDS
phase() { printf '# phase (+%ss): %s\n' "$((SECONDS - PHASE_START))" "$1"; }

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables in PARENT scope only. A `( ... )` subshell cannot report
# a failure back to these counters, so a scheme that can LOSE a failure is worse
# than none: the suite would certify work it never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected> <actual>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${expected}]
  actual(pwsh)  : [${actual}]
"
  fi
}

# --- normalization ------------------------------------------------------------

# The ps-world twin of a bash-world path. A TRAILING component is handled as
# well as an interior one, because several validation cases name the world root
# itself and a plain `/bash/` substitution would leave those pointing at the
# oracle's own fixture.
FM_TOPS=
to_ps() {  # <bash-world path> -> FM_TOPS
  local v=$1
  v=${v//\/bash\//\/ps\/}
  case $v in */bash) v=${v%/bash}/ps ;; esac
  FM_TOPS=$v
}

# The `$(cat f)` twin, without the fork. Every value this suite captures from a
# file goes through it: an MSYS fork costs ~2.4s under load on this host, and an
# earlier draft issued enough of them to exhaust the fork retry limit outright
# rather than merely running slowly. `read -d ''` reads to NUL - the whole file -
# and returns non-zero at EOF while still assigning, hence the `|| true`.
FM_SLURP=
slurp() {  # <path> -> FM_SLURP
  FM_SLURP=''
  [ -f "$1" ] || return 0
  local content=''
  IFS= read -r -d '' content < "$1" || true
  # Command substitution strips TRAILING newlines and nothing else.
  while [ "${content%$'\n'}" != "$content" ]; do content=${content%$'\n'}; done
  FM_SLURP=$content
}

# Count the lines of a newline-joined value without `wc`.
FM_COUNT=0
count_lines() {  # <text> -> FM_COUNT
  local text=$1
  FM_COUNT=0
  [ -n "$text" ] || return 0
  while [ "${text#*$'\n'}" != "$text" ]; do
    FM_COUNT=$((FM_COUNT + 1))
    text=${text#*$'\n'}
  done
  [ -z "$text" ] || FM_COUNT=$((FM_COUNT + 1))
}

FM_NORM=
norm() {  # <value> -> FM_NORM  (bash side of the three declared transforms)
  local v=$1
  v=${v//"$TMP_ROOT"/@R@}
  v=${v//\/bash\//\/W\/}
  case $v in */bash) v=${v%/bash}/W ;; esac
  case $v in
    *quarantine.*)
      # The wall-clock stamp, and the collision suffix that depends on it. The
      # suffix appears exactly when the name a world computed was already taken,
      # which is a function of WHICH SECOND each world ran in - the two are
      # minutes apart here. What the collision suffix exists to guarantee, that
      # no artifact is ever overwritten, is asserted separately on the artifact
      # count and on the preserved bytes, where timing cannot reach it.
      v=$(printf '%s' "$v" |
        sed -E 's/quarantine\.[0-9]{8}T[0-9]{6}Z\./quarantine.@S@./g; s/(quarantine\.@S@\.[0-9a-f]+)\.[0-9]+/\1/g')
      ;;
  esac
  FM_NORM=$v
}

# --- oracle and result tables -------------------------------------------------
#
# Parallel arrays plus a linear lookup, matching tests/fm-psproc-lib-psm1.test.sh:
# there are a few hundred records, and a lookup is pure builtin work.
ORC_KEYS=()
ORC_VALS=()
FM_ORC=

orc() {  # <key> <value>
  ORC_KEYS+=("$1")
  ORC_VALS+=("$2")
}

orc_norm() {  # <key> <value> - record after the declared normalization
  norm "$2"
  orc "$1" "$FM_NORM"
}

orcv() {  # <key> -> FM_ORC
  local key=$1 i=0
  FM_ORC='<no-oracle>'
  for i in "${!ORC_KEYS[@]}"; do
    if [ "${ORC_KEYS[$i]}" = "$key" ]; then FM_ORC=${ORC_VALS[$i]}; return 0; fi
  done
}

PS_LINES=()
FM_PSV=
psv() {  # <key> -> FM_PSV, or the literal <missing>
  local key=$1 line
  FM_PSV='<missing>'
  for line in ${PS_LINES+"${PS_LINES[@]}"}; do
    case "$line" in
      "$key"$'\t'*) FM_PSV=${line#*$'\t'}; return 0 ;;
    esac
  done
}

cmp_key() {  # <key> <description>
  orcv "$1"
  local expected=$FM_ORC
  psv "$1"
  assert_same "$2 [$1]" "$expected" "$FM_PSV"
}

# --- case file ----------------------------------------------------------------
#
# One record per line: label <TAB> env <TAB> op <TAB> args... Every field is
# TAB-delimited and read with .Split("`t") on the PowerShell side, asserting the
# field COUNT, because an empty middle field is meaningful here (an empty env
# spec, an empty base) and a regex split would silently drop it.
CASES="$TMP_ROOT/cases.tsv"
CASES_N=$(fm_test_native_path "$CASES")
: > "$CASES"

# TAB and LF are the field and record separators, so an argument carrying either
# is encoded here and decoded on the PowerShell side. That is not cosmetic: the
# first_line fixtures exist precisely to prove tab and newline handling, and an
# unencoded tab silently split one case into two fields while an unencoded
# newline produced a second, malformed record - both observed live before this
# encoding existed, and both of which read as a library bug rather than as a
# transport bug.
ps_case() {  # <label> <env> <op> <arg>...
  local label=$1 envspec=$2 op=$3
  shift 3
  local record="$label	$envspec	$op" a
  for a in "$@"; do
    a=${a//$'\t'/<TAB>}
    a=${a//$'\n'/<NL>}
    record="$record	$a"
  done
  printf '%s\n' "$record" >> "$CASES"
}

# ps_path_case: the common shape - every argument after the op is a path under
# TMP_ROOT and is converted to its native spelling here rather than in pwsh.
ps_path_case() {  # <label> <env> <op> <path>...
  local label=$1 envspec=$2 op=$3 a
  shift 3
  local args=()
  for a in "$@"; do nat "$a"; args+=("$FM_NAT"); done
  ps_case "$label" "$envspec" "$op" ${args+"${args[@]}"}
}

# --- world builders -----------------------------------------------------------
#
# A recipe takes a world directory and lays down a PRIMARY firstmate repo plus
# whatever the case needs. Each recipe runs twice, once per world copy.

world_primary() {  # <w>: a primary firstmate repo on main with one commit
  local w=$1
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  git init -q -b main "$w/main"
  printf 'projects/\nstate/\ndata/\nconfig/\n.no-mistakes/\n' > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin" "$w/main/.agents/skills"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  printf 's1\n' > "$w/main/.agents/skills/note.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
}

bump_instr() {  # <w>: advance main by a commit that touches the instruction surface
  local w=$1
  printf 'r-instr\n' >> "$w/main/README.md"
  printf 'v-instr\n' > "$w/main/AGENTS.md"
  printf 'echo instr\n' > "$w/main/bin/tool.sh"
  printf 's-instr\n' > "$w/main/.agents/skills/note.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm bump-instr
}

# The commit that lands the seed marker in .gitignore. Everything a marker home
# needs is decided by whether it sits before or after this commit.
ignore_marker_commit() {  # <w>
  local w=$1
  printf '.fm-secondmate-home\n' >> "$w/main/.gitignore"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm ignore-marker
}

live_meta() {  # <w> <id>: a running kind=secondmate direct report
  local w=$1 id=$2
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || printf '<fail>'; }

build_pair() {  # <case> <recipe-fn>: build both world copies from one recipe
  local c=$1 fn=$2 bash_pid ps_pid
  mkdir -p "$TMP_ROOT/$c"
  # The two copies are independent directory trees, and a builder returns
  # NOTHING to this shell - it only creates files. That is what makes running
  # them concurrently safe here while nothing else in this file is backgrounded:
  # no counter, no oracle value and no case record crosses this boundary, so
  # there is nothing a subshell could lose. Fixture construction is the single
  # largest cost in the suite, and halving its wall time is the difference
  # between a run that finishes inside a supervision window and one that does
  # not.
  "$fn" "$TMP_ROOT/$c/bash" &
  bash_pid=$!
  "$fn" "$TMP_ROOT/$c/ps" &
  ps_pid=$!
  wait "$bash_pid" || fail "building the $c bash world failed"
  wait "$ps_pid" || fail "building the $c ps world failed"
}

# --- the ff oracle driver -----------------------------------------------------
#
# ff_target prints its line and publishes FF_STATUS/FF_INSTR as globals, so it
# must run in THIS shell, not in a command substitution: output goes to a file.
FF_LINE=
run_ff() {  # <dir> <label> <base> <allow_detached> <ignore_marker>
  local out="$TMP_ROOT/ff.out"
  ff_target "$1" "$2" "$3" "$4" "$5" > "$out" 2>&1
  slurp "$out"
  FF_LINE=$FM_SLURP
}

# ff_case: run the bash oracle over the bash world and queue the identical
# PowerShell case over the ps world, recording the line, the status, the
# instruction list and the resulting HEAD from both sides.
ff_case() {  # <key> <world> <world-relative-dir> <label> <base-mode> <allow_detached> <ignore_marker>
  local key=$1 world=$2 rel=$3 label=$4 mode=$5 detached=$6 marker=$7
  local bdir="$TMP_ROOT/$world/bash/$rel" pdir="$TMP_ROOT/$world/ps/$rel"

  run_ff "$bdir" "$label" "$mode" "$detached" "$marker"
  orc_norm "$key.line" "$FF_LINE"
  orc "$key.status" "$FF_STATUS"
  orc "$key.instr" "$FF_INSTR"
  orc "$key.head" "$(head_of "$bdir")"

  nat "$pdir"
  ps_case "$key" '' fftarget "$FM_NAT" "$label" "$mode" "$detached" "$marker"
}

# =============================================================================
# [ff] pure helpers - no fixture, so they cost nothing
# =============================================================================

fl_case() {  # <key> <text>
  orc "$1.value" "$(first_line "$2")"
  ps_case "$1" '' firstline "$2"
}
fl_case ff-firstline-plain 'fatal: Not possible to fast-forward, aborting.'
fl_case ff-firstline-runs 'fatal:   many    spaces   here'
fl_case ff-firstline-tabs "$(printf 'fatal:\ttabbed\t\tvalue')"
fl_case ff-firstline-multi "$(printf 'first line\nsecond line')"
fl_case ff-firstline-empty ''
fl_case ff-firstline-leading "$(printf '   indented message')"

anc_case() {  # <key> <ancestor> <path>
  if path_is_ancestor_of "$2" "$3"; then orc "$1.value" true; else orc "$1.value" false; fi
  ps_case "$1" '' ancestor "$2" "$3"
}
anc_case ff-anc-child /a/b /a/b/c
anc_case ff-anc-equal /a/b /a/b
anc_case ff-anc-sibling /a/b /a/bc
anc_case ff-anc-parent /a/b/c /a/b
anc_case ff-anc-empty-ancestor '' /a/b
anc_case ff-anc-empty-path /a/b ''
anc_case ff-anc-deep /a /a/b/c/d

# =============================================================================
# [ff] the fast-forward decision table, over ONE shared world
# =============================================================================
#
# Every case gets its OWN home, but they all hang off one primary repository.
# That is a cost decision with teeth: a git spawn costs ~2.4s on this
# Defender-protected host, and an earlier draft that built a fresh primary per
# case issued enough forks to exhaust the MSYS fork retry limit outright
# ("dofork: child died unexpectedly ... Resource temporarily unavailable"), i.e.
# it did not merely run slowly, it FAILED. Nothing in the decision table needs an
# isolated primary: ff_target only ever touches the one directory it is handed,
# and each case here is handed a different one.
#
# The primary carries three commits, and which one a home starts at is what
# selects its case:
#   c1  the base instruction surface
#   c2  an instruction-surface bump (AGENTS.md, bin/, .agents/skills)
#   c3  the commit that adds the seed marker to .gitignore
# A home at c1 is behind by an instruction change; a home at c2 predates the
# ignore rule, so its seed marker is genuinely untracked-and-unignored, which is
# the exact state the marker-tolerance contract exists for.

recipe_ff() {
  local w=$1 c1 c2 c3 m
  world_primary "$w"
  c1=$(head_of "$w/main")
  bump_instr "$w"
  c2=$(head_of "$w/main")
  ignore_marker_commit "$w"
  c3=$(head_of "$w/main")
  printf '%s\n%s\n%s\n' "$c1" "$c2" "$c3" > "$w/commits"

  # Homes that are simply behind, or already at the tip. h-refuse is shared by
  # the three cases that refuse BEFORE touching anything - a detached home when
  # detachment is banned, a base that does not exist, and origin mode with no
  # origin - so one clean home serves all three without any of them being able
  # to observe the others.
  for m in h-updated h-dirty h-refuse h-local; do
    git -C "$w/main" worktree add -q --detach "$w/$m" "$c1"
  done
  git -C "$w/main" worktree add -q --detach "$w/h-current" "$c3"
  printf 'uncommitted local edit\n' >> "$w/h-dirty/AGENTS.md"

  # A home carrying its own commit has DIVERGED and can never be fast-forwarded.
  git -C "$w/main" worktree add -q --detach "$w/h-diverged" "$c1"
  printf 'fork work\n' > "$w/h-diverged/AGENTS.md"
  git -C "$w/h-diverged" add -A
  git -C "$w/h-diverged" commit -qm local-work

  # In-flight work sits on a named feature branch, not a detached default HEAD.
  git -C "$w/main" worktree add -q -b feature/wip "$w/h-feature" "$c1"
  printf 'work in progress\n' >> "$w/h-feature/README.md"
  git -C "$w/h-feature" add -A
  git -C "$w/h-feature" commit -qm wip

  # Marker homes predate the ignore rule, so the marker reads as dirt until the
  # fast-forward that lands the rule. h-marker-b doubles as the marker-only
  # dirtiness probe: its case refuses, so nothing it observes can change.
  for m in h-marker-a h-marker-b h-marker-c; do
    git -C "$w/main" worktree add -q --detach "$w/$m" "$c2"
    printf 'sm\n' > "$w/$m/.fm-secondmate-home"
  done
  printf 'real local change\n' >> "$w/h-marker-c/AGENTS.md"

  # The validation and read-only-probe home: a properly seeded secondmate home
  # with a live direct-report record and some ordinary dirt.
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  printf 'sm\n' > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf 'charter\n' > "$w/sm/data/charter.md"
  printf 'dirt\n' >> "$w/sm/README.md"
  live_meta "$w" sm

  # The sweep's own direct reports, recorded in their OWN state dir so the sweep
  # sees exactly these three live records and never the probe home above. Their
  # starting commits are what make the sweep's nudge decision observable:
  # sm-instr is behind by an instruction change (nudged), sm-readme is behind by
  # a commit that touches no watched path (advanced but NOT nudged), sm-current
  # is already at the tip, and sm-nonlive has no record at all, so a sweep must
  # never touch it however far behind it is.
  mkdir -p "$w/sweep-state"
  git -C "$w/main" worktree add -q --detach "$w/sm-instr" "$c1"
  git -C "$w/main" worktree add -q --detach "$w/sm-readme" "$c2"
  git -C "$w/main" worktree add -q --detach "$w/sm-current" "$c3"
  git -C "$w/main" worktree add -q --detach "$w/sm-nonlive" "$c1"
  for m in sm-instr sm-readme sm-current sm-nonlive; do
    printf '%s\n' "$m" > "$w/$m/.fm-secondmate-home"
  done
  for m in sm-instr sm-readme sm-current; do
    {
      printf 'window=firstmate:fm-%s\n' "$m"
      printf 'kind=secondmate\n'
      printf 'harness=codex\n'
      printf 'home=%s/%s\n' "$w" "$m"
    } > "$w/sweep-state/$m.meta"
  done

  # A directory that is not a git repo at all.
  mkdir -p "$w/plain"
  printf 'not a repo\n' > "$w/plain/file.txt"
}

phase 'building the shared fast-forward world (2 copies)'
build_pair ff-world recipe_ff
FFW_B="$TMP_ROOT/ff-world/bash"
FFW_P="$TMP_ROOT/ff-world/ps"
slurp "$FFW_B/commits"
FF_REST=${FM_SLURP#*$'\n'}
FF_C3=${FF_REST#*$'\n'}
[ -n "$FF_C3" ] || fail "the shared ff world did not record its three commits"


phase 'the fast-forward decision table (bash oracle)'
ff_case ff-updated ff-world h-updated 'secondmate sm' "$FF_C3" yes yes
# The tip of a fast-forward has exactly one parent; a merge would have two.
ff_parents=$(git -C "$FFW_B/h-updated" rev-list --parents -n1 HEAD)
# Word-counted through the builtin splitter rather than `wc -w`, which is a fork.
set -- $ff_parents
orc "ff-updated.parents" "$#"
ps_path_case ff-updated '' parentcount "$FFW_P/h-updated"
orc "ff-updated.detached" "$(git -C "$FFW_B/h-updated" symbolic-ref -q HEAD >/dev/null && echo attached || echo detached)"
ps_path_case ff-updated '' detachment "$FFW_P/h-updated"

ff_case ff-current ff-world h-current 'secondmate sm' "$FF_C3" yes yes

# --- REFUSAL: a dirty home is skipped and its edit survives --------------------
ff_case ff-dirty ff-world h-dirty 'secondmate sm' "$FF_C3" yes yes
slurp "$FFW_B/h-dirty/AGENTS.md"; orc "ff-dirty.text" "$FM_SLURP"
ps_path_case ff-dirty '' filetext "$FFW_P/h-dirty/AGENTS.md"

# --- REFUSAL: a home carrying its own commit has diverged ----------------------
ff_case ff-diverged ff-world h-diverged 'secondmate sm' "$FF_C3" yes yes

# --- REFUSAL: a home on a feature branch is in-flight work ---------------------
ff_case ff-feature ff-world h-feature 'secondmate sm' "$FF_C3" yes yes

# --- REFUSAL: a detached home when detachment is not allowed -------------------
ff_case ff-detached ff-world h-refuse 'secondmate sm' "$FF_C3" no yes

# --- REFUSAL: the target is not a directory, or not a git repo -----------------
ff_case ff-notdir ff-world missing 'secondmate sm' "$FF_C3" yes yes
ff_case ff-notrepo ff-world plain 'secondmate sm' "$FF_C3" yes yes

# --- REFUSAL: the base commit does not exist in the target's object store ------
ff_case ff-nobase ff-world h-refuse 'secondmate sm' 0123456789012345678901234567890123456789 yes yes

# --- REFUSAL: origin base mode with no origin remote --------------------------
# The same world in LOCAL base mode advances, which is the structural proof that
# the local-HEAD sync never reaches for origin: this repo HAS no origin, so a
# fetch would have had to fail and the case would have been skipped instead.
ff_case ff-origin-missing ff-world h-refuse 'secondmate sm' origin yes yes
ff_case ff-local-nofetch ff-world h-local 'secondmate sm' "$FF_C3" yes yes

# --- the seed-marker convergence contract -------------------------------------
ff_case ff-marker-converge ff-world h-marker-a 'secondmate sm' "$FF_C3" yes yes
ff_case ff-marker-intolerant ff-world h-marker-b 'secondmate sm' "$FF_C3" yes no
ff_case ff-marker-realdirt ff-world h-marker-c 'secondmate sm' "$FF_C3" yes yes
slurp "$FFW_B/h-marker-c/AGENTS.md"; orc "ff-marker-realdirt.text" "$FM_SLURP"
ps_path_case ff-marker-realdirt '' filetext "$FFW_P/h-marker-c/AGENTS.md"

# =============================================================================
# [ff] the read-only helpers, over the same world
# =============================================================================

PROBE_B=$FFW_B
PROBE_P=$FFW_P
PROBE_BASE=$FF_C3

orc "ff-probe-default.value" "$(default_branch "$PROBE_B/main")"
ps_path_case ff-probe-default '' defaultbranch "$PROBE_P/main"

orc "ff-probe-head.value" "$(primary_head_commit "$PROBE_B/main")"
ps_path_case ff-probe-head '' primaryhead "$PROBE_P/main"

orc "ff-probe-instr.value" "$(changed_instr "$PROBE_B/sm" "$PROBE_BASE")"
nat "$PROBE_P/sm"; ps_case ff-probe-instr '' changedinstr "$FM_NAT" "$PROBE_BASE"

orc "ff-probe-dirty.value" "$(dirty_status "$PROBE_B/sm" no)"
nat "$PROBE_P/sm"; ps_case ff-probe-dirty '' dirtystatus "$FM_NAT" no

orc "ff-probe-dirty-marker.value" "$(dirty_status "$PROBE_B/sm" yes)"
nat "$PROBE_P/sm"; ps_case ff-probe-dirty-marker '' dirtystatus "$FM_NAT" yes

# A home whose ONLY dirt is the seed marker: the tolerance itself, isolated.
orc "ff-markeronly-plain.value" "$(dirty_status "$FFW_B/h-marker-b" no)"
nat "$FFW_P/h-marker-b"; ps_case ff-markeronly-plain '' dirtystatus "$FM_NAT" no
orc "ff-markeronly-tolerant.value" "$(dirty_status "$FFW_B/h-marker-b" yes)"
nat "$FFW_P/h-marker-b"; ps_case ff-markeronly-tolerant '' dirtystatus "$FM_NAT" yes

# --- live secondmate meta records ---------------------------------------------
# The record carries a path (the meta file), so only its LEAF is compared; the
# id, the home string read verbatim out of the record, and the window all still
# have to match byte for byte.
records_of() {  # <state> <registry> -> newline-joined id|home|window|<meta leaf>
  local line id home window meta out=''
  while IFS='|' read -r id home window meta; do
    [ -n "$id" ] || continue
    line="$id|$home|$window|${meta##*/}"
    out="$out$line"$'\n'
  done < <(live_secondmate_meta_records "$1" "$2")
  printf '%s' "$out"
}
orc_norm "ff-records.value" "$(records_of "$PROBE_B/home/state" "$PROBE_B/home/data/secondmates.md")"
nat "$PROBE_P/home/state"; RECS_STATE=$FM_NAT
nat "$PROBE_P/home/data/secondmates.md"
ps_case ff-records '' liverecords "$RECS_STATE" "$FM_NAT"

# =============================================================================
# [ff] secondmate home validation - the refusal surface with no paths in it
# =============================================================================

vh_case() {  # <key> <id> <home> <active-home> <root>
  local key=$1 id=$2 home=$3 active=$4 root=$5
  local saved_home=${FM_HOME:-} saved_root=${FM_ROOT:-}
  FM_HOME=$active FM_ROOT=$root
  if validate_secondmate_home "$id" "$home"; then orc "$key.ok" true; else orc "$key.ok" false; fi
  orc "$key.error" "$VALIDATION_ERROR"
  FM_HOME=$saved_home FM_ROOT=$saved_root
  to_ps "$home"; nat "$FM_TOPS"; local hn=$FM_NAT
  to_ps "$active"; nat "$FM_TOPS"; local an=$FM_NAT
  to_ps "$root"; nat "$FM_TOPS"; local rn=$FM_NAT
  ps_case "$key" '' validatehome "$id" "$hn" "$an" "$rn"
}

phase 'secondmate home validation'
VH_B="$FFW_B"
vh_case ff-vh-ok sm "$VH_B/sm" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-missing sm "$VH_B/nope" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-wrong-id other "$VH_B/sm" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-unseeded sm "$VH_B/main" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-is-active sm "$VH_B/home" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-is-root sm "$VH_B/main" "$VH_B/main" "$VH_B/main"
vh_case ff-vh-bad-active sm "$VH_B/sm" "$VH_B/absent-home" "$VH_B/main"
vh_case ff-vh-bad-root sm "$VH_B/sm" "$VH_B/home" "$VH_B/absent-root"
# A path that is NEVER created, deliberately distinct from the one below. The
# two phases are separated in time - bash answers now, PowerShell answers after
# every fixture has been built - so a case whose subject is created later would
# be asked two different questions and would report a library difference that is
# really a fixture-ordering difference.
vh_case ff-vh-inside-active sm "$VH_B/home/never-created" "$VH_B/home" "$VH_B/main"
mkdir -p "$FFW_B/home/inner" "$FFW_P/home/inner"
vh_case ff-vh-inside-active-real sm "$VH_B/home/inner" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-ancestor-of-active sm "$VH_B" "$VH_B/home" "$VH_B/main"

# A home that is missing AGENTS.md, and one missing bin/: both are "this is not a
# firstmate home", and both are checked AFTER the identity marker so a wrong
# marker is always reported first.
mk_partial() {  # <w> <name> <what>
  local w=$1 name=$2 what=$3
  mkdir -p "$w/$name/data" "$w/$name/state" "$w/$name/config" "$w/$name/projects"
  printf 'sm\n' > "$w/$name/.fm-secondmate-home"
  [ "$what" = noagents ] || printf 'x\n' > "$w/$name/AGENTS.md"
  [ "$what" = nobin ] || mkdir -p "$w/$name/bin"
}
for wcopy in bash ps; do
  mk_partial "$TMP_ROOT/ff-world/$wcopy" partial-noagents noagents
  mk_partial "$TMP_ROOT/ff-world/$wcopy" partial-nobin nobin
done
vh_case ff-vh-no-agents sm "$VH_B/partial-noagents" "$VH_B/home" "$VH_B/main"
vh_case ff-vh-no-bin sm "$VH_B/partial-nobin" "$VH_B/home" "$VH_B/main"

# An operational dir that escapes the home. Real file symlinks need admin on this
# host (verified: New-Item -ItemType SymbolicLink refuses, and Git Bash `ln -s`
# silently COPIES), but a directory JUNCTION works and MSYS reports it as a
# symlink - so the directory-escape refusal is exercised for real rather than
# skipped. The junction is created by PowerShell for both worlds up front.
JUNCTION_MADE=0
mk_junction() {  # <link> <target>
  local link=$1 target=$2 ln tn
  nat "$link"; ln=$FM_NAT
  nat "$target"; tn=$FM_NAT
  pwsh -NoProfile -Command "New-Item -ItemType Junction -Path '$ln' -Target '$tn' -ErrorAction Stop | Out-Null" \
    >/dev/null 2>&1
}

for wcopy in bash ps; do
  W="$TMP_ROOT/ff-world/$wcopy"
  mkdir -p "$W/escape-target" "$W/junction-home"
  printf 'sm\n' > "$W/junction-home/.fm-secondmate-home"
  printf 'x\n' > "$W/junction-home/AGENTS.md"
  mkdir -p "$W/junction-home/bin" "$W/junction-home/state" \
    "$W/junction-home/config" "$W/junction-home/projects"
  if mk_junction "$W/junction-home/data" "$W/escape-target"; then JUNCTION_MADE=1; fi
done
if [ -L "$FFW_B/junction-home/data" ] &&
  [ -L "$FFW_P/junction-home/data" ]; then
  JUNCTION_MADE=1
  vh_case ff-vh-escaping-dir sm "$VH_B/junction-home" "$VH_B/home" "$VH_B/main"
else
  JUNCTION_MADE=0
fi

# =============================================================================
# [ff] the sweep: which homes advance, and which are nudged
# =============================================================================

# The sweep runs over the same world, against its OWN state dir - see recipe_ff.
# Its four homes are untouched by every case above, so the two phases cannot
# interfere even though they share one primary.
phase 'the secondmate sweep'
SWEEP_B=$FFW_B
SWEEP_P=$FFW_P
SWEEP_BASE=$FF_C3

FM_HOME="$SWEEP_B/home" FM_ROOT="$SWEEP_B/main"
FF_NUDGE_WINDOWS=""
# The bash sweep reads both accumulators, so both are reset before it runs even
# though only the nudge list is compared afterwards.
# shellcheck disable=SC2034
FF_SEEN_HOMES=""
sweep_live_secondmate_metas "$SWEEP_B/sweep-state" "$SWEEP_BASE" yes > "$TMP_ROOT/sweep.out" 2>&1
orc "ff-sweep.nudges" "${FF_NUDGE_WINDOWS# }"
orc_norm "ff-sweep.out" "$(sort < "$TMP_ROOT/sweep.out")"
FM_HOME=""; FM_ROOT=""
# The sweep case is queued BEFORE the per-home HEAD probes, because the driver
# evaluates cases in file order: the oracle reads its HEADs after sweeping, so
# the twin must too. Queued the other way round, every home reported its
# pre-sweep commit and the sweep looked like it had done nothing.
nat "$SWEEP_P/sweep-state"; SW_STATE=$FM_NAT
nat "$SWEEP_P/home"; SW_HOME=$FM_NAT
nat "$SWEEP_P/main"; SW_ROOT=$FM_NAT
ps_case ff-sweep '' sweep "$SW_STATE" "$SWEEP_BASE" yes "$SW_HOME" "$SW_ROOT"
for id in sm-instr sm-readme sm-current sm-nonlive; do
  orc "ff-sweep-$id.head" "$(head_of "$SWEEP_B/$id")"
  ps_path_case "ff-sweep-$id" '' githead "$SWEEP_P/$id"
done

# =============================================================================
# [inherit] pure helpers
# =============================================================================

phase 'inherited local material'
INH="$TMP_ROOT/inherit"
mkdir -p "$INH"
printf 'alpha\n' > "$INH/a.txt"
printf 'alpha\n' > "$INH/a-copy.txt"
printf 'beta\n' > "$INH/b.txt"
ln "$INH/a.txt" "$INH/a-hard.txt" 2>/dev/null || true
chmod 444 "$INH/b.txt"

orc "inh-sha-a.value" "$(fm_inherit_sha256 "$INH/a.txt")"
ps_path_case inh-sha-a '' sha256 "$INH/a.txt"
orc "inh-sha-b.value" "$(fm_inherit_sha256 "$INH/b.txt")"
ps_path_case inh-sha-b '' sha256 "$INH/b.txt"
# The bash returns SUCCESS with empty output for a missing file (its awk sees no
# input), while the PowerShell twin answers $null. Both are "no digest", and the
# assertion is written on that shared contract rather than on the exit status -
# no caller in the tree reaches this without an existence check first, and a
# twin that invented a digest here would be the real failure.
inh_missing_sha=$(fm_inherit_sha256 "$INH/nope.txt")
[ -n "$inh_missing_sha" ] || inh_missing_sha='<fail>'
orc "inh-sha-missing.value" "$inh_missing_sha"
ps_path_case inh-sha-missing '' sha256 "$INH/nope.txt"

orc "inh-links-single.value" "$(fm_inherit_file_link_count "$INH/b.txt")"
ps_path_case inh-links-single '' linkcount "$INH/b.txt"
orc "inh-links-hard.value" "$(fm_inherit_file_link_count "$INH/a.txt")"
ps_path_case inh-links-hard '' linkcount "$INH/a.txt"

orc "inh-mode-plain.mode" "$(fm_inherit_file_mode "$INH/a.txt")"
ps_path_case inh-mode-plain '' filemode "$INH/a.txt"
orc "inh-mode-readonly.mode" "$(fm_inherit_file_mode "$INH/b.txt")"
ps_path_case inh-mode-readonly '' filemode "$INH/b.txt"

orc "inh-same-yes.value" "$(cmp -s "$INH/a.txt" "$INH/a-copy.txt" && echo true || echo false)"
nat "$INH/a.txt"; INH_A=$FM_NAT
nat "$INH/a-copy.txt"; ps_case inh-same-yes '' samecontent "$INH_A" "$FM_NAT"
orc "inh-same-no.value" "$(cmp -s "$INH/a.txt" "$INH/b.txt" && echo true || echo false)"
nat "$INH/b.txt"; ps_case inh-same-no '' samecontent "$INH_A" "$FM_NAT"

# --- the shared captain header gate -------------------------------------------
shared_header() {
  cat <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF
}
write_shared() { shared_header > "$1"; printf '%s\n' "$2" >> "$1"; }

mkdir -p "$INH/headers"
write_shared "$INH/headers/good.md" 'body v1'
printf '# nothing useful\n' > "$INH/headers/empty.md"
shared_header | grep -v 'main-authoritative' > "$INH/headers/no-auth.md"
shared_header | grep -v 'read-only in secondmate homes' > "$INH/headers/no-readonly.md"
shared_header | grep -v 'marked status' > "$INH/headers/no-route.md"
# The warning past line 12 must NOT count: the gate reads a bounded head.
{ for ((n = 1; n <= 12; n++)); do printf 'x\n'; done; shared_header; } > "$INH/headers/too-late.md"

for h in good empty no-auth no-readonly no-route too-late; do
  if shared_captain_header_valid "$INH/headers/$h.md"; then orc "inh-hdr-$h.value" true
  else orc "inh-hdr-$h.value" false; fi
  ps_path_case "inh-hdr-$h" '' headervalid "$INH/headers/$h.md"
done

# --- the safe-file predicate ---------------------------------------------------
for probe in a.txt a-hard.txt nope.txt; do
  if shared_captain_file_safe_existing "$INH/$probe"; then orc "inh-safe-$probe.value" true
  else orc "inh-safe-$probe.value" false; fi
  ps_path_case "inh-safe-$probe" '' safefile "$INH/$probe"
done

# =============================================================================
# [inherit] shared captain-preference convergence
# =============================================================================

new_pair() {  # <case> <copy>: a primary/second home pair with local files
  local base="$TMP_ROOT/$1/$2"
  mkdir -p "$base/primary/data" "$base/primary/config" "$base/second/data" "$base/second/config"
  printf 'primary local captain\n' > "$base/primary/data/captain.md"
  printf 'second local captain\n' > "$base/second/data/captain.md"
  printf 'second local learning\n' > "$base/second/data/learnings.md"
}

# sync_case: run the bash oracle on the bash copy and queue the PowerShell case
# on the ps copy, comparing exit status, stdout, stderr and the report file.
sync_case() {  # <key> <case> <op>
  local key=$1 c=$2 op=$3
  local b="$TMP_ROOT/$c/bash" p="$TMP_ROOT/$c/ps"
  # Per-KEY report and error files: two syncs over one case directory (the
  # first-copy then the idempotent re-run) would otherwise append to one report
  # and the second comparison would read the first one's lines as well.
  local rep="$TMP_ROOT/$c/bash.$key.report" err="$TMP_ROOT/$c/bash.$key.err" out rc
  : > "$rep"
  case $op in
    shared)
      out=$(FM_CONFIG_INHERIT_REPORT="$rep" \
        propagate_shared_captain_preferences "$b/primary/data" "$b/second/data" 2>"$err") || rc=$?
      ;;
    config)
      out=$(FM_CONFIG_INHERIT_REPORT="$rep" \
        propagate_inheritable_config "$b/primary/config" "$b/second/config" 2>"$err") || rc=$?
      ;;
    both)
      out=$(FM_CONFIG_INHERIT_REPORT="$rep" \
        propagate_secondmate_inheritance "$b/primary" "$b/second" 2>"$err") || rc=$?
      ;;
  esac
  rc=${rc:-0}
  orc "$key.rc" "$rc"
  orc_norm "$key.out" "$out"
  orc_norm "$key.err" "$(<"$err")"
  orc_norm "$key.report" "$(<"$rep")"

  nat "$p"; local pn=$FM_NAT
  nat "$TMP_ROOT/$c/ps.$key.report"
  ps_case "$key" "FM_CONFIG_INHERIT_REPORT=$FM_NAT" "sync$op" "$pn"
}

# --- first copy, then an idempotent re-run ------------------------------------
for copy in bash ps; do
  new_pair inh-first "$copy"
  write_shared "$TMP_ROOT/inh-first/$copy/primary/data/captain-shared.md" 'shared v1'
done
sync_case inh-first-copy inh-first shared
orc "inh-first-copy.mode" "$(fm_inherit_file_mode "$TMP_ROOT/inh-first/bash/second/data/captain-shared.md")"
ps_path_case inh-first-copy '' filemode "$TMP_ROOT/inh-first/ps/second/data/captain-shared.md"
orc "inh-first-copy.text" "$(<"$TMP_ROOT/inh-first/bash/second/data/captain-shared.md")"
ps_path_case inh-first-copy '' filetext "$TMP_ROOT/inh-first/ps/second/data/captain-shared.md"
# The domain-local files must be untouched by a shared-file convergence.
orc "inh-first-copy.local" "$(<"$TMP_ROOT/inh-first/bash/second/data/captain.md")$(<"$TMP_ROOT/inh-first/bash/second/data/learnings.md")"
nat "$TMP_ROOT/inh-first/ps/second/data/captain.md"; LOCAL_A=$FM_NAT
nat "$TMP_ROOT/inh-first/ps/second/data/learnings.md"
ps_case inh-first-copy '' filetext2 "$LOCAL_A" "$FM_NAT"
# An ordinary append must FAIL against the read-only copy: the mode is the
# mechanism that stops a secondmate editing a main-authoritative file.
if ( printf 'secondmate edit\n' >> "$TMP_ROOT/inh-first/bash/second/data/captain-shared.md" ) 2>/dev/null
then orc "inh-first-copy.writable" yes; else orc "inh-first-copy.writable" no; fi
ps_path_case inh-first-copy '' appendable "$TMP_ROOT/inh-first/ps/second/data/captain-shared.md"

sync_case inh-second-run inh-first shared

# --- drift: the local copy is quarantined, never discarded ---------------------
for copy in bash ps; do
  new_pair inh-drift "$copy"
  write_shared "$TMP_ROOT/inh-drift/$copy/primary/data/captain-shared.md" 'shared v2'
  write_shared "$TMP_ROOT/inh-drift/$copy/second/data/captain-shared.md" 'local drift'
  chmod 444 "$TMP_ROOT/inh-drift/$copy/second/data/captain-shared.md"
done
sync_case inh-drift inh-drift shared
orc "inh-drift.text" "$(<"$TMP_ROOT/inh-drift/bash/second/data/captain-shared.md")"
ps_path_case inh-drift '' filetext "$TMP_ROOT/inh-drift/ps/second/data/captain-shared.md"
# The quarantine artifact is named for the CONTENT hash, so its name is
# comparable across worlds once the wall-clock stamp is normalized.
qleaf_of() {  # <dir> -> the sorted quarantine leaves, stamp-normalized
  local d=$1 f out=''
  for f in "$d"/.captain-shared.md.quarantine.*; do
    [ -e "$f" ] || continue
    out="$out${f##*/}"$'\n'
  done
  printf '%s' "$out" | LC_ALL=C sort
}
orc_norm "inh-drift.artifacts" "$(qleaf_of "$TMP_ROOT/inh-drift/bash/second/data")"
ps_path_case inh-drift '' quarantineleaves "$TMP_ROOT/inh-drift/ps/second/data"
orc "inh-drift.preserved" "$(cat "$TMP_ROOT"/inh-drift/bash/second/data/.captain-shared.md.quarantine.* 2>/dev/null)"
ps_path_case inh-drift '' quarantinetext "$TMP_ROOT/inh-drift/ps/second/data"

# --- drift where the quarantine name is already taken -------------------------
# The name carries a wall-clock stamp, and the two worlds run minutes apart on
# this host, so a fixture that occupied one exact name could not be relied on to
# still collide when the other world got there. What must hold either way is the
# property the collision suffix exists FOR: an artifact that is already on disk
# is never overwritten. So the assertion is on the artifact COUNT and on the
# preserved bytes rather than on a name that legitimately differs - and it still
# fails loudly if either world clobbers the pre-existing file.
for copy in bash ps; do
  new_pair inh-collide "$copy"
  write_shared "$TMP_ROOT/inh-collide/$copy/primary/data/captain-shared.md" 'shared v3'
  write_shared "$TMP_ROOT/inh-collide/$copy/second/data/captain-shared.md" 'collide drift'
done
nat "$TMP_ROOT/inh-collide/ps/second/data"
ps_case inh-collide-prep '' occupyquarantine "$FM_NAT"
COLLIDE_HASH=$(fm_inherit_sha256 "$TMP_ROOT/inh-collide/bash/second/data/captain-shared.md")
COLLIDE_NAME=$(shared_captain_quarantine_name "$TMP_ROOT/inh-collide/bash/second/data" "$COLLIDE_HASH")
printf 'preexisting different artifact\n' > "$COLLIDE_NAME"
sync_case inh-collide inh-collide shared
count_lines "$(qleaf_of "$TMP_ROOT/inh-collide/bash/second/data")"
orc "inh-collide.count" "$FM_COUNT"
ps_path_case inh-collide '' quarantinecount "$TMP_ROOT/inh-collide/ps/second/data"
orc "inh-collide.preserved" "$(cat "$TMP_ROOT"/inh-collide/bash/second/data/.captain-shared.md.quarantine.* 2>/dev/null | LC_ALL=C sort)"
ps_path_case inh-collide '' quarantinesorted "$TMP_ROOT/inh-collide/ps/second/data"

# --- drift whose bytes are ALREADY quarantined: reuse, do not accumulate -------
for copy in bash ps; do
  new_pair inh-reuse "$copy"
  write_shared "$TMP_ROOT/inh-reuse/$copy/primary/data/captain-shared.md" 'shared v4'
  write_shared "$TMP_ROOT/inh-reuse/$copy/second/data/captain-shared.md" 'reused drift'
done
REUSE_HASH=$(fm_inherit_sha256 "$TMP_ROOT/inh-reuse/bash/second/data/captain-shared.md")
for copy in bash ps; do
  cp "$TMP_ROOT/inh-reuse/$copy/second/data/captain-shared.md" \
    "$TMP_ROOT/inh-reuse/$copy/second/data/.captain-shared.md.quarantine.20260102T030405Z.$REUSE_HASH"
done
sync_case inh-reuse inh-reuse shared
orc_norm "inh-reuse.artifacts" "$(qleaf_of "$TMP_ROOT/inh-reuse/bash/second/data")"
ps_path_case inh-reuse '' quarantineleaves "$TMP_ROOT/inh-reuse/ps/second/data"

# --- the primary has no shared file: mirror absence, after quarantining --------
for copy in bash ps; do
  new_pair inh-absent "$copy"
  write_shared "$TMP_ROOT/inh-absent/$copy/second/data/captain-shared.md" 'orphaned local shared file'
  chmod 444 "$TMP_ROOT/inh-absent/$copy/second/data/captain-shared.md"
done
sync_case inh-absent inh-absent shared
orc "inh-absent.exists" "$([ -e "$TMP_ROOT/inh-absent/bash/second/data/captain-shared.md" ] && echo yes || echo no)"
ps_path_case inh-absent '' exists "$TMP_ROOT/inh-absent/ps/second/data/captain-shared.md"
orc "inh-absent.preserved" "$(cat "$TMP_ROOT"/inh-absent/bash/second/data/.captain-shared.md.quarantine.* 2>/dev/null)"
ps_path_case inh-absent '' quarantinetext "$TMP_ROOT/inh-absent/ps/second/data"

# --- nothing anywhere: a complete no-op ---------------------------------------
for copy in bash ps; do new_pair inh-nothing "$copy"; done
sync_case inh-nothing inh-nothing shared

# --- REFUSAL: the primary's header lacks the required warnings ------------------
for copy in bash ps; do
  new_pair inh-badhdr "$copy"
  printf '# not the shared file\n\njust prose\n' > "$TMP_ROOT/inh-badhdr/$copy/primary/data/captain-shared.md"
done
sync_case inh-badhdr inh-badhdr shared

# --- REFUSAL: a hard-linked destination is a second name for the same bytes ----
for copy in bash ps; do
  new_pair inh-hardlink "$copy"
  write_shared "$TMP_ROOT/inh-hardlink/$copy/primary/data/captain-shared.md" 'shared v5'
  write_shared "$TMP_ROOT/inh-hardlink/$copy/second/data/captain-shared.md" 'hardlinked local drift'
  ln "$TMP_ROOT/inh-hardlink/$copy/second/data/captain-shared.md" \
    "$TMP_ROOT/inh-hardlink/$copy/second/data/hardlink-copy" 2>/dev/null || true
done
if [ "$(fm_inherit_file_link_count "$TMP_ROOT/inh-hardlink/bash/second/data/captain-shared.md")" = 2 ]; then
  HARDLINK_MADE=1
  sync_case inh-hardlink inh-hardlink shared
else
  HARDLINK_MADE=0
fi

# --- REFUSAL: a linked destination DIRECTORY ----------------------------------
JUNCTION_DEST=0
for copy in bash ps; do
  base="$TMP_ROOT/inh-junction/$copy"
  mkdir -p "$base/primary/data" "$base/primary/config" "$base/second" "$base/real-data"
  write_shared "$base/primary/data/captain-shared.md" 'shared v6'
  write_shared "$base/real-data/captain-shared.md" 'drifted through a junction'
  mk_junction "$base/second/data" "$base/real-data"
done
if [ -L "$TMP_ROOT/inh-junction/bash/second/data" ] &&
  [ -L "$TMP_ROOT/inh-junction/ps/second/data" ]; then
  JUNCTION_DEST=1
  sync_case inh-junction inh-junction shared
fi

# =============================================================================
# [inherit] declared config items
# =============================================================================

# A destination OUTSIDE any git work tree: both worlds allow it unconditionally,
# so this half of the contract is a clean differential with no divergence.
#
# Each of the three outcomes gets its OWN directory pair, built to its starting
# state up front, rather than one pair mutated between calls. That is not tidiness:
# the bash oracle runs now and the PowerShell driver runs at the END, so a
# fixture the oracle mutates in between is a DIFFERENT fixture by the time the
# twin sees it. An earlier draft cleared the primary's crew-harness for the
# absence case after the push case had already run, and the twin - which saw only
# the final state - reported "unchanged" for a push the oracle had recorded as
# "pushed". The library was right both times; the fixture had moved.
for copy in bash ps; do
  new_pair inh-cfg "$copy"
  printf '{"rules":[]}\n' > "$TMP_ROOT/inh-cfg/$copy/primary/config/crew-dispatch.json"
  printf 'codex\n' > "$TMP_ROOT/inh-cfg/$copy/primary/config/crew-harness"

  # Already converged: identical bytes on both sides.
  new_pair inh-cfg-same "$copy"
  printf 'codex\n' > "$TMP_ROOT/inh-cfg-same/$copy/primary/config/crew-harness"
  printf 'codex\n' > "$TMP_ROOT/inh-cfg-same/$copy/second/config/crew-harness"

  # The primary has no value; the secondmate still holds one.
  new_pair inh-cfg-gone "$copy"
  printf 'codex\n' > "$TMP_ROOT/inh-cfg-gone/$copy/second/config/crew-harness"
done
sync_case inh-cfg-push inh-cfg config
orc "inh-cfg-push.text" "$(<"$TMP_ROOT/inh-cfg/bash/second/config/crew-harness")"
ps_path_case inh-cfg-push '' filetext "$TMP_ROOT/inh-cfg/ps/second/config/crew-harness"
sync_case inh-cfg-unchanged inh-cfg-same config

# Clearing the primary's value clears it downstream (primary-authoritative).
sync_case inh-cfg-absence inh-cfg-gone config
orc "inh-cfg-absence.exists" "$([ -e "$TMP_ROOT/inh-cfg-gone/bash/second/config/crew-harness" ] && echo yes || echo no)"
ps_path_case inh-cfg-absence '' exists "$TMP_ROOT/inh-cfg-gone/ps/second/config/crew-harness"

# --- REFUSAL: a declared item that tries to escape the config dir --------------
for copy in bash ps; do
  new_pair inh-cfg-escape "$copy"
  printf 'x\n' > "$TMP_ROOT/inh-cfg-escape/$copy/primary/config/crew-harness"
done
sync_escape() {  # the traversal guard aborts the WHOLE propagation
  local b="$TMP_ROOT/inh-cfg-escape/bash" rep="$TMP_ROOT/inh-cfg-escape/bash.report" rc=0
  : > "$rep"
  local saved=$FM_INHERITABLE_CONFIG
  FM_INHERITABLE_CONFIG='crew-harness ../escape'
  FM_CONFIG_INHERIT_REPORT="$rep" \
    propagate_inheritable_config "$b/primary/config" "$b/second/config" >/dev/null 2>&1 || rc=$?
  FM_INHERITABLE_CONFIG=$saved
  orc "inh-cfg-escape.rc" "$rc"
  orc_norm "inh-cfg-escape.report" "$(<"$rep")"
  nat "$TMP_ROOT/inh-cfg-escape/ps"; local pn=$FM_NAT
  nat "$TMP_ROOT/inh-cfg-escape/ps.report"
  ps_case inh-cfg-escape "FM_CONFIG_INHERIT_REPORT=$FM_NAT;FM_INHERITABLE_CONFIG=crew-harness ../escape" \
    syncconfig "$pn"
}
sync_escape

# --- REFUSAL: an unsafe startup-memory-budget artifact -------------------------
for copy in bash ps; do
  new_pair inh-budget "$copy"
  printf '7500\n' > "$TMP_ROOT/inh-budget/$copy/primary/config/startup-memory-budget"
  printf 'not-a-number\n' > "$TMP_ROOT/inh-budget/$copy/second/config/startup-memory-budget"
done
sync_case inh-budget inh-budget config
orc "inh-budget.text" "$(<"$TMP_ROOT/inh-budget/bash/second/config/startup-memory-budget")"
ps_path_case inh-budget '' filetext "$TMP_ROOT/inh-budget/ps/second/config/startup-memory-budget"

for copy in bash ps; do
  new_pair inh-budget-src "$copy"
  printf '0075\n' > "$TMP_ROOT/inh-budget-src/$copy/primary/config/startup-memory-budget"
done
sync_case inh-budget-src inh-budget-src config

# --- the gitignore guard, and the ONE declared divergence ---------------------
# Both worlds are asserted against their own real answer rather than against each
# other, because on Windows the bash prefix test can never match (`pwd -P` says
# /tmp/x, `git rev-parse --show-toplevel` says C:/Users/.../Temp/x) and therefore
# skips unconditionally, while the twin normalizes and answers the question the
# guard was written to ask. Asserting each side's verdict keeps the difference
# visible instead of hiding it behind a softened comparison.
mk_git_dest() {  # <dir> <ignore-config>
  local d=$1 ignore=$2
  mkdir -p "$d/config"
  git init -q -b main "$d"
  if [ "$ignore" = yes ]; then printf 'config/\n' > "$d/.gitignore"; else printf 'nothing\n' > "$d/.gitignore"; fi
  printf 'seed\n' > "$d/seed.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm seed
}
for copy in bash ps; do
  base="$TMP_ROOT/inh-gitdest/$copy"
  mkdir -p "$base/primary/config"
  printf 'codex\n' > "$base/primary/config/crew-harness"
  mk_git_dest "$base/second" yes
  mkdir -p "$base/tracked-primary/config"
  printf 'codex\n' > "$base/tracked-primary/config/crew-harness"
  mk_git_dest "$base/tracked-second" no
done
# Both worlds are asked the SAME question - the predicate itself - so the two
# answers are directly comparable and the divergence, where there is one, is
# visible rather than inferred from a downstream status.
gitdest_case() {  # <key> <second-name>
  local key=$1 sn=$2 b="$TMP_ROOT/inh-gitdest/bash"
  if destination_allows_inherited_item "$b/$sn/config" crew-harness; then
    orc "$key.verdict" true
  else
    orc "$key.verdict" false
  fi
  nat "$TMP_ROOT/inh-gitdest/ps/$sn/config"
  ps_case "$key" '' destallows "$FM_NAT" crew-harness
}
gitdest_case inh-gitdest-ignored second
gitdest_case inh-gitdest-tracked tracked-second
# A destination outside any git work tree is allowed unconditionally by both.
gitdest_nogit() {
  local b="$TMP_ROOT/inh-gitdest/bash"
  mkdir -p "$b/plain/config" "$TMP_ROOT/inh-gitdest/ps/plain/config"
  if destination_allows_inherited_item "$b/plain/config" crew-harness; then
    orc "inh-gitdest-nogit.verdict" true
  else
    orc "inh-gitdest-nogit.verdict" false
  fi
  nat "$TMP_ROOT/inh-gitdest/ps/plain/config"
  ps_case inh-gitdest-nogit '' destallows "$FM_NAT" crew-harness
}
gitdest_nogit

# =============================================================================
# [inherit] the config-reread instruction and its retry machinery
# =============================================================================

phase 'the config-reread instruction and its retry machinery'
RR="$TMP_ROOT/reread"
for copy in bash ps; do
  mkdir -p "$RR/$copy/source/state" "$RR/$copy/dest/config" "$RR/$copy/dest/state"
  printf 'codex\n' > "$RR/$copy/dest/config/crew-harness"
  printf '{"rules":[]}' > "$RR/$copy/dest/config/crew-dispatch.json"
  # A SECOND destination whose crew-harness copy was removed. It is a separate
  # home rather than the same one mutated later for the same reason the config
  # cases each get their own pair: the twin sees only the final state, so a
  # destination the oracle empties after its own run would be empty for both of
  # the twin's runs.
  mkdir -p "$RR/$copy/dest-absent/config" "$RR/$copy/dest-absent/state"
  printf '{"rules":[]}' > "$RR/$copy/dest-absent/config/crew-dispatch.json"
  {
    printf 'crew-dispatch.json\tpushed\t\n'
    printf 'crew-harness\tpushed\t\n'
    printf 'backend\tunchanged\t\n'
    printf 'data/captain-shared.md\tpushed\t\n'
  } > "$RR/$copy/report.tsv"
  printf 'backend\tunchanged\t\n' > "$RR/$copy/report-none.tsv"
done

orc "inh-changed.value" "$(fm_config_reread_changed_items "$RR/bash/report.tsv" | tr '\n' ',')"
ps_path_case inh-changed '' changeditems "$RR/ps/report.tsv"
orc "inh-changed-none.value" "$(fm_config_reread_changed_items "$RR/bash/report-none.tsv" | tr '\n' ',')"
ps_path_case inh-changed-none '' changeditems "$RR/ps/report-none.tsv"

for item in crew-harness data/captain-shared.md secondmate-harness; do
  if fm_config_reread_is_allowlisted_item "$item"; then orc "inh-allow-$item.value" true
  else orc "inh-allow-$item.value" false; fi
  ps_case "inh-allow-$item" '' allowlisted "$item"
done

# The instruction file carries only relative paths and destination bytes, so its
# CONTENT is byte-comparable between the two worlds with no normalization at all.
fm_config_write_reread_instruction "$RR/bash/dest" "$RR/bash/report.tsv" "$RR/bash/instr.txt" \
  && orc "inh-instr.rc" 0 || orc "inh-instr.rc" 1
slurp "$RR/bash/instr.txt"; orc "inh-instr.text" "$FM_SLURP"
nat "$RR/ps/dest"; RR_DEST=$FM_NAT
nat "$RR/ps/report.tsv"; RR_REP=$FM_NAT
nat "$RR/ps/instr.txt"
ps_case inh-instr '' writeinstr "$RR_DEST" "$RR_REP" "$FM_NAT"

# A destination copy that was REMOVED renders as the literal token ABSENT, never
# as the primary's bytes and never as an empty block.
fm_config_write_reread_instruction "$RR/bash/dest-absent" "$RR/bash/report.tsv" "$RR/bash/instr-absent.txt" \
  && orc "inh-instr-absent.rc" 0 || orc "inh-instr-absent.rc" 1
slurp "$RR/bash/instr-absent.txt"; orc "inh-instr-absent.text" "$FM_SLURP"
nat "$RR/ps/dest-absent"; RR_DEST_ABSENT=$FM_NAT
nat "$RR/ps/instr-absent.txt"
ps_case inh-instr-absent '' writeinstr "$RR_DEST_ABSENT" "$RR_REP" "$FM_NAT"

# No allowlisted change at all: no instruction is written and the call fails.
fm_config_write_reread_instruction "$RR/bash/dest" "$RR/bash/report-none.tsv" "$RR/bash/instr-none.txt" \
  && orc "inh-instr-none.rc" 0 || orc "inh-instr-none.rc" 1
orc "inh-instr-none.exists" "$([ -e "$RR/bash/instr-none.txt" ] && echo yes || echo no)"
nat "$RR/ps/report-none.tsv"; RR_REPN=$FM_NAT
nat "$RR/ps/instr-none.txt"
ps_case inh-instr-none '' writeinstr "$RR_DEST" "$RR_REPN" "$FM_NAT"

# The retry directory token: an id carrying separators or a traversal segment can
# never steer the retry directory out of the source home.
for id in 'sm-one' '../escape' 'a b/c' ''; do
  key="inh-retrydir-$(printf '%s' "$id" | tr -c 'a-zA-Z0-9' '_')"
  # The exit status must be read from the FUNCTION, not from a pipeline whose
  # last stage always succeeds: piping into sed made a refusal look like an
  # empty answer, and the twin's own refusal then read as a difference.
  if retry_dir_value=$(fm_config_reread_retry_dir "$RR/bash/source" "$id" 2>/dev/null); then
    retry_dir_value=${retry_dir_value##*/}
  else
    retry_dir_value='<fail>'
  fi
  orc "$key.value" "$retry_dir_value"
  nat "$RR/ps/source"
  ps_case "$key" '' retrydir "$FM_NAT" "$id"
done

# Queue bound. The EMPTY probe uses an id that is never populated: sm-one is
# filled to the bound below, and the twin - which runs after every fixture
# exists - would otherwise be asked about a queue that is no longer empty.
orc "inh-queue-empty.value" "$(fm_config_reread_retry_queue_is_full "$RR/bash/source" sm-never && echo true || echo false)"
nat "$RR/ps/source"; RR_SRC=$FM_NAT
ps_case inh-queue-empty '' queuefull "$RR_SRC" sm-never
for copy in bash ps; do
  d="$RR/$copy/source/state/.fm-inherited-config-reread-retry/sm-one"
  mkdir -p "$d"
  for ((n = 1; n <= 16; n++)); do printf 'stage %s\n' "$n" > "$d/.fm-inherited-config-reread.gen.$n"; done
done
orc "inh-queue-full.value" "$(fm_config_reread_retry_queue_is_full "$RR/bash/source" sm-one && echo true || echo false)"
ps_case inh-queue-full '' queuefull "$RR_SRC" sm-one
orc "inh-queue-staged.value" "$(fm_config_reread_has_staged "$RR/bash/source" sm-one && echo true || echo false)"
ps_case inh-queue-staged '' hasstaged "$RR_SRC" sm-one
count_lines "$(fm_config_reread_pending_stages "$RR/bash/source" sm-one)"
orc "inh-queue-stagecount.value" "$FM_COUNT"
ps_case inh-queue-stagecount '' stagecount "$RR_SRC" sm-one
# A zero-length stage is not a stage: an empty instruction would tell a live
# agent to re-read nothing.
for copy in bash ps; do
  : > "$RR/$copy/source/state/.fm-inherited-config-reread-retry/sm-one/.fm-inherited-config-reread.gen.empty"
done
count_lines "$(fm_config_reread_pending_stages "$RR/bash/source" sm-one)"
orc "inh-queue-emptystage.value" "$FM_COUNT"
ps_case inh-queue-emptystage '' stagecount "$RR_SRC" sm-one

# Pending instructions and the sent-history bound.
for copy in bash ps; do
  s="$RR/$copy/dest/state"
  for ((n = 1; n <= 20; n++)); do printf 'sent %s\n' "$n" > "$s/.fm-inherited-config-reread.sent.$n"; done
  printf 'x\n' > "$s/.fm-inherited-config-reread.keepme"
  printf '%s\n' "$s/.fm-inherited-config-reread.keepme" > "$s/.fm-inherited-config-reread.keepme.pending"
done
orc "inh-pending.value" "$(fm_config_reread_pending_instructions "$RR/bash/dest/state" | sed 's|.*/||' | LC_ALL=C sort | tr '\n' ',')"
nat "$RR/ps/dest/state"; RR_DSTATE=$FM_NAT
ps_case inh-pending '' pendinginstr "$RR_DSTATE"
orc "inh-haspending.value" "$(fm_config_reread_has_pending "$RR/bash/dest" && echo true || echo false)"
ps_case inh-haspending '' haspending "$RR_DEST"
fm_config_reread_cleanup_sent "$RR/bash/dest"
# Counted with a glob rather than `ls`, which does not show dotfiles and would
# have reported zero for every generation here.
sent_count=0
for f in "$RR"/bash/dest/state/.fm-inherited-config-reread.sent.*; do
  [ -e "$f" ] && sent_count=$((sent_count + 1))
done
orc "inh-cleanup.count" "$sent_count"
orc "inh-cleanup.kept" "$([ -e "$RR/bash/dest/state/.fm-inherited-config-reread.keepme" ] && echo yes || echo no)"
ps_case inh-cleanup '' cleanupsent "$RR_DEST"

# The pointer send refusals, each of which returns before fm-send is reached.
mkdir -p "$RR/bash/ptr" "$RR/ps/ptr"
for copy in bash ps; do
  printf 'instruction\n' > "$RR/$copy/ptr/present"
  printf '%s\n' "$RR/$copy/ptr/present" > "$RR/$copy/ptr/present.pending"
  printf 'instruction\n' > "$RR/$copy/ptr/mismatched"
  printf '%s\n' "/somewhere/else" > "$RR/$copy/ptr/mismatched.pending"
done
ptr_case() {  # <key> <path> <fm_home>
  local key=$1 p=$2 home=$3 out rc=0
  local saved=${FM_HOME:-}
  if [ -n "$home" ]; then export FM_HOME="$home"; else unset FM_HOME; fi
  out=$(fm_config_reread_send_pointer smx "$p" 2>&1) || rc=$?
  if [ -n "$saved" ]; then export FM_HOME="$saved"; else unset FM_HOME; fi
  orc "$key.rc" "$rc"
  orc_norm "$key.out" "$out"
  to_ps "$p"; nat "$FM_TOPS"; local pn=$FM_NAT
  local envspec=''
  if [ -n "$home" ]; then to_ps "$home"; nat "$FM_TOPS"; envspec="FM_HOME=$FM_NAT"
  else envspec='FM_HOME='; fi
  ps_case "$key" "$envspec" sendpointer "$pn"
}
ptr_case inh-ptr-missing "$RR/bash/ptr/absent" "$RR/bash/source"
ptr_case inh-ptr-mismatch "$RR/bash/ptr/mismatched" "$RR/bash/source"
ptr_case inh-ptr-nohome "$RR/bash/ptr/present" ''

# =============================================================================
# The PowerShell driver - ONE process for every case above
# =============================================================================
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_N=$(fm_test_native_path "$DRIVER")
RESULTS="$TMP_ROOT/results.tsv"
DRIVER_ERR="$TMP_ROOT/driver.err"

cat > "$DRIVER" <<'PS1'
#Requires -Version 7.0
# Evaluates every queued case in ONE process and prints label<TAB>value records.
# Records accumulate in a StringBuilder and are written at the very end through
# the SAVED console writer, because each case redirects [Console]::Out to capture
# what the library prints.
param(
    [Parameter(Mandatory)][string]$CaseFile,
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$RootNative
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The MSYS spelling of the temp root arrives through the ENVIRONMENT, not as an
# argument: Git Bash path-mangles any argument that looks like an absolute POSIX
# path when it hands it to a native program, so /tmp/x reached pwsh already
# rewritten to C:\...\Temp\x and the normalization that depends on it silently
# did nothing. Environment values are passed through untouched.
$RootPosix = $env:FM_TEST_ROOT_POSIX
if ($RootPosix.StartsWith('@@')) { $RootPosix = $RootPosix.Substring(2) }

# fm-common is imported LAST, and that order is load-bearing rather than
# stylistic. Each library below opens with its own `Import-Module fm-common
# -Force`, and -Force REMOVES the module before re-importing it - which takes
# fm-common's exports out of THIS session even though they were imported here
# first. Verified: Invoke-FmTool, Test-FmSymlink and Set-FmFileText all became
# "not recognized" in a session that imported fm-common first, and every case
# that called one directly threw.
Import-Module (Join-Path $BinDir 'fm-ff-lib.psm1') -Force
Import-Module (Join-Path $BinDir 'fm-config-inherit-lib.psm1') -Force
Import-Module (Join-Path $BinDir 'fm-common.psm1') -Force

$out = [System.Text.StringBuilder]::new()
$realOut = [Console]::Out

function Add-Record {
    param([Parameter(Mandatory)][string]$Key, [AllowNull()][AllowEmptyString()]$Value)
    if ($null -eq $Value) { $Value = '' }
    # TAB separates fields and LF separates records, so neither may appear in a
    # value. Nothing compared here legitimately contains one except a multi-line
    # capture, which is folded onto one line with a visible marker so a missing
    # line still shows as a difference.
    $text = ([string]$Value) -replace "`t", '<TAB>' -replace "`r`n", '<NL>' -replace "`n", '<NL>'
    [void]$out.Append($Key).Append("`t").Append($text).Append("`n")
}

# The three declared transforms, matching the bash side exactly.
function ConvertTo-Normal {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    # BOTH spellings of the temp root: a value can carry the native form (a path
    # this module resolved) or the MSYS form (a string read verbatim out of a
    # record the fixture wrote, such as a meta home= field).
    $v = $Value.Replace($RootNative, '@R@')
    $v = $v.Replace('\', '/')
    $v = $v.Replace($RootPosix, '@R@')
    $v = $v.Replace('/ps/', '/W/')
    if ($v.EndsWith('/ps')) { $v = $v.Substring(0, $v.Length - 3) + '/W' }
    $v = [regex]::Replace($v, 'quarantine\.[0-9]{8}T[0-9]{6}Z\.', 'quarantine.@S@.')
    # The collision suffix: see the bash-side norm() for why it is folded. It is
    # STRIPPED rather than tokenized, because whether it is there at all depends
    # on which second each world ran in - one world found the name free and the
    # other found it taken, and both were right.
    $v = [regex]::Replace($v, '(quarantine\.@S@\.[0-9a-f]+)\.[0-9]+', '$1')
    return $v
}

# Capture what a library call writes to the console. Write-FmOut/Write-FmErr read
# [Console]::Out and [Console]::Error at call time, so a SetOut here genuinely
# intercepts them - which is also what keeps those lines out of the record
# stream this driver is writing.
function Invoke-Captured {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $oldOut = [Console]::Out
    $oldErr = [Console]::Error
    $swOut = [System.IO.StringWriter]::new()
    $swErr = [System.IO.StringWriter]::new()
    $value = $null
    $threw = ''
    [Console]::SetOut($swOut)
    [Console]::SetError($swErr)
    try {
        $value = & $Body
    } catch {
        $threw = $_.Exception.Message
    } finally {
        [Console]::SetOut($oldOut)
        [Console]::SetError($oldErr)
    }
    return @{ Value = $value; Out = $swOut.ToString(); Err = $swErr.ToString(); Threw = $threw }
}

function Get-Rc {
    param($Value)
    # A scriptblock that emitted more than one object comes back as an array;
    # the LAST element is the return value, and anything else in it would be a
    # library leaking output into the pipeline - which the record would then
    # show as a mismatch rather than hide.
    if ($Value -is [array]) { if ($Value.Count -eq 0) { return '1' } else { $Value = $Value[-1] } }
    if ($Value -is [bool]) { if ($Value) { return '0' } else { return '1' } }
    if ($null -eq $Value) { return '1' }
    return '0'
}

# `$(cmd)` strips trailing newlines; every captured stream is compared at that
# convention because the bash oracle values were captured the same way.
function Get-Trimmed {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace "`r`n", "`n").TrimEnd("`n")
}

function Get-QuarantineLeaf {
    param([Parameter(Mandatory)][string]$Directory)
    $names = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Directory -PathType Container) {
        foreach ($f in [System.IO.Directory]::EnumerateFileSystemEntries($Directory)) {
            $leaf = [System.IO.Path]::GetFileName($f)
            if ($leaf.StartsWith('.captain-shared.md.quarantine.')) { $names.Add($leaf) }
        }
    }
    $names.Sort([System.StringComparer]::Ordinal)
    if ($names.Count -eq 0) { return '' }
    return (($names -join "`n") + "`n")
}

$lines = @([System.IO.File]::ReadAllLines($CaseFile))
foreach ($line in $lines) {
    if ($line -eq '') { continue }
    $f = @($line.Split("`t"))
    if ($f.Count -lt 3) { Add-Record -Key 'BAD' -Value $line; continue }
    $label = $f[0]
    $envSpec = $f[1]
    $op = $f[2]
    # Decode the transport escapes the case writer applied to TAB and LF.
    $a = @($f | Select-Object -Skip 3 | ForEach-Object {
            $_.Replace('<TAB>', "`t").Replace('<NL>', "`n")
        })

    # Per-case environment: applied here and cleared after, because a batched
    # run cannot inherit it from the shell that queued the case.
    $applied = [System.Collections.Generic.List[string]]::new()
    $saved = @{}
    if ($envSpec -ne '') {
        foreach ($pair in @($envSpec.Split(';'))) {
            if ($pair -eq '') { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $pair.Substring(0, $eq)
            $value = $pair.Substring($eq + 1)
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $value)
            $applied.Add($name)
        }
    }

    try {
        switch ($op) {
            'fftarget' {
                $r = Invoke-Captured -Body {
                    $call = @{ Directory = $a[0]; Label = $a[1]; BaseMode = $a[2] }
                    if ($a[3] -eq 'yes') { $call['AllowDetached'] = $true }
                    if ($a[4] -eq 'yes') { $call['IgnoreSeedMarker'] = $true }
                    Invoke-FmFfTarget @call
                }
                if ($r.Threw -ne '') {
                    Add-Record -Key "$label.line" -Value "<threw> $($r.Threw)"
                    Add-Record -Key "$label.status" -Value '<threw>'
                    Add-Record -Key "$label.instr" -Value '<threw>'
                } else {
                    Add-Record -Key "$label.line" -Value (ConvertTo-Normal (Get-Trimmed $r.Out))
                    Add-Record -Key "$label.status" -Value $r.Value.Status
                    Add-Record -Key "$label.instr" -Value $r.Value.Instructions
                }
                $head = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $a[0], 'rev-parse', 'HEAD')
                if ($head.Ok) { Add-Record -Key "$label.head" -Value $head.StdOut.TrimEnd("`n") }
                else { Add-Record -Key "$label.head" -Value '<fail>' }
            }
            'parentcount' {
                $r = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $a[0], 'rev-list', '--parents', '-n1', 'HEAD')
                Add-Record -Key "$label.parents" -Value (@($r.StdOut.TrimEnd("`n").Split(' ') |
                            Where-Object { $_ -ne '' }).Count)
            }
            'detachment' {
                $r = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $a[0], 'symbolic-ref', '-q', 'HEAD')
                if ($r.Ok) { Add-Record -Key "$label.detached" -Value 'attached' }
                else { Add-Record -Key "$label.detached" -Value 'detached' }
            }
            'githead' {
                $r = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $a[0], 'rev-parse', 'HEAD')
                if ($r.Ok) { Add-Record -Key "$label.head" -Value $r.StdOut.TrimEnd("`n") }
                else { Add-Record -Key "$label.head" -Value '<fail>' }
            }
            'firstline' { Add-Record -Key "$label.value" -Value (Get-FmFfFirstLine -Text $a[0]) }
            'ancestor' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmFfPathIsAncestor -Ancestor $a[0] -Path $a[1]).ToString().ToLowerInvariant())
            }
            'defaultbranch' {
                $v = Get-FmFfDefaultBranch -Directory $a[0]
                Add-Record -Key "$label.value" -Value $v
            }
            'primaryhead' {
                $v = Get-FmFfPrimaryHeadCommit -Root $a[0]
                Add-Record -Key "$label.value" -Value $v
            }
            'changedinstr' {
                Add-Record -Key "$label.value" -Value (Get-FmFfChangedInstruction -Directory $a[0] -Base $a[1])
            }
            'dirtystatus' {
                $call = @{ Directory = $a[0] }
                if ($a[1] -eq 'yes') { $call['IgnoreSeedMarker'] = $true }
                Add-Record -Key "$label.value" -Value (Get-FmFfDirtyStatus @call)
            }
            'validatehome' {
                $v = Resolve-FmFfSecondmateHome -Id $a[0] -HomePath $a[1] -ActiveHome $a[2] -RepoRoot $a[3]
                Add-Record -Key "$label.ok" -Value ($v.Ok.ToString().ToLowerInvariant())
                Add-Record -Key "$label.error" -Value $v.Error
            }
            'liverecords' {
                $text = ''
                foreach ($rec in (Get-FmFfLiveSecondmateMetaRecord -StateDir $a[0] -Registry $a[1])) {
                    $text += "$($rec.Id)|$($rec.Home)|$($rec.Window)|$([System.IO.Path]::GetFileName($rec.Meta))`n"
                }
                Add-Record -Key "$label.value" -Value (ConvertTo-Normal (Get-Trimmed $text))
            }
            'sweep' {
                $state = New-FmFfSweepState
                $r = Invoke-Captured -Body {
                    $call = @{
                        StateDir = $a[0]; BaseMode = $a[1]; State = $state
                        ActiveHome = $a[3]; RepoRoot = $a[4]
                    }
                    if ($a[2] -eq 'yes') { $call['NudgeRequiresInstruction'] = $true }
                    Invoke-FmFfSecondmateSweep @call
                }
                Add-Record -Key "$label.nudges" -Value ($state.NudgeWindows -join ' ')
                $sorted = @((Get-Trimmed $r.Out) -split "`n" | Sort-Object -CaseSensitive)
                Add-Record -Key "$label.out" -Value (ConvertTo-Normal ($sorted -join "`n"))
            }
            'filetext' {
                if ([System.IO.File]::Exists($a[0])) {
                    Add-Record -Key "$label.text" -Value (Get-Trimmed ([System.IO.File]::ReadAllText($a[0])))
                } else { Add-Record -Key "$label.text" -Value '<absent>' }
            }
            'filetext2' {
                $joined = ''
                foreach ($p in $a) {
                    if ([System.IO.File]::Exists($p)) { $joined += (Get-Trimmed ([System.IO.File]::ReadAllText($p))) }
                }
                Add-Record -Key "$label.local" -Value $joined
            }
            'filemode' { Add-Record -Key "$label.mode" -Value (Get-FmInheritFileMode -Path $a[0]) }
            'linkcount' { Add-Record -Key "$label.value" -Value (Get-FmInheritFileLinkCount -Path $a[0]) }
            'sha256' {
                $v = Get-FmInheritSha256 -Path $a[0]
                if ($null -eq $v) { $v = '<fail>' }
                Add-Record -Key "$label.value" -Value $v
            }
            'samecontent' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmInheritSameContent -Left $a[0] -Right $a[1]).ToString().ToLowerInvariant())
            }
            'headervalid' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmSharedCaptainHeader -Source $a[0]).ToString().ToLowerInvariant())
            }
            'safefile' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmSharedCaptainFile -Path $a[0]).ToString().ToLowerInvariant())
            }
            'exists' {
                if ((Test-Path -LiteralPath $a[0]) -or (Test-FmSymlink $a[0])) {
                    Add-Record -Key "$label.exists" -Value 'yes'
                } else { Add-Record -Key "$label.exists" -Value 'no' }
            }
            'appendable' {
                $ok = 'yes'
                try { [System.IO.File]::AppendAllText($a[0], "secondmate edit`n") } catch { $ok = 'no' }
                Add-Record -Key "$label.writable" -Value $ok
            }
            'quarantineleaves' {
                Add-Record -Key "$label.artifacts" -Value (
                    ConvertTo-Normal (Get-Trimmed (Get-QuarantineLeaf -Directory $a[0])))
            }
            'quarantinecount' {
                $leaves = Get-Trimmed (Get-QuarantineLeaf -Directory $a[0])
                $n = 0
                if ($leaves -ne '') { $n = @($leaves -split "`n").Count }
                Add-Record -Key "$label.count" -Value $n
            }
            'quarantinesorted' {
                # The artifacts' CONTENTS, sorted as `cat ... | sort` sorts them:
                # the names carry a wall-clock stamp and so are not comparable
                # across worlds, but the bytes they preserve are exactly what the
                # quarantine exists to keep.
                $texts = [System.Collections.Generic.List[string]]::new()
                if (Test-Path -LiteralPath $a[0] -PathType Container) {
                    foreach ($f in [System.IO.Directory]::EnumerateFileSystemEntries($a[0])) {
                        if (-not [System.IO.Path]::GetFileName($f).StartsWith('.captain-shared.md.quarantine.')) { continue }
                        foreach ($l in @((Get-Trimmed ([System.IO.File]::ReadAllText($f))) -split "`n")) {
                            $texts.Add($l)
                        }
                    }
                }
                $texts.Sort([System.StringComparer]::Ordinal)
                Add-Record -Key "$label.preserved" -Value ($texts -join "`n")
            }
            'quarantinetext' {
                $text = ''
                if (Test-Path -LiteralPath $a[0] -PathType Container) {
                    $names = [System.Collections.Generic.List[string]]::new()
                    foreach ($f in [System.IO.Directory]::EnumerateFileSystemEntries($a[0])) {
                        if ([System.IO.Path]::GetFileName($f).StartsWith('.captain-shared.md.quarantine.')) {
                            $names.Add($f)
                        }
                    }
                    $names.Sort([System.StringComparer]::Ordinal)
                    foreach ($n in $names) { $text += [System.IO.File]::ReadAllText($n) }
                }
                Add-Record -Key "$label.preserved" -Value (Get-Trimmed $text)
            }
            'occupyquarantine' {
                # Ask the module for the name it is about to use, then take it,
                # so the collision path is exercised without faking a clock.
                $dest = Join-Path $a[0] 'captain-shared.md'
                $hash = Get-FmInheritSha256 -Path $dest
                $name = New-FmSharedCaptainQuarantineName -Parent $a[0] -Hash $hash
                Set-FmFileText -Path $name -Text 'preexisting different artifact'
                Add-Record -Key "$label.ready" -Value 'yes'
            }
            'syncshared' {
                $r = Invoke-Captured -Body {
                    Sync-FmSharedCaptainPreference -SourceData (Join-Path $a[0] 'primary\data') `
                        -DestinationData (Join-Path $a[0] 'second\data')
                }
                Add-Record -Key "$label.rc" -Value (Get-Rc $r.Value)
                Add-Record -Key "$label.out" -Value (ConvertTo-Normal (Get-Trimmed $r.Out))
                Add-Record -Key "$label.err" -Value (ConvertTo-Normal (Get-Trimmed ($r.Err + $r.Threw)))
                $rep = [Environment]::GetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT')
                $text = if ($rep -and [System.IO.File]::Exists($rep)) { [System.IO.File]::ReadAllText($rep) } else { '' }
                Add-Record -Key "$label.report" -Value (ConvertTo-Normal (Get-Trimmed $text))
            }
            'syncconfig' {
                $r = Invoke-Captured -Body {
                    Sync-FmInheritableConfig -SourceConfig (Join-Path $a[0] 'primary\config') `
                        -DestinationConfig (Join-Path $a[0] 'second\config')
                }
                Add-Record -Key "$label.rc" -Value (Get-Rc $r.Value)
                Add-Record -Key "$label.out" -Value (ConvertTo-Normal (Get-Trimmed $r.Out))
                Add-Record -Key "$label.err" -Value (ConvertTo-Normal (Get-Trimmed ($r.Err + $r.Threw)))
                $rep = [Environment]::GetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT')
                $text = if ($rep -and [System.IO.File]::Exists($rep)) { [System.IO.File]::ReadAllText($rep) } else { '' }
                Add-Record -Key "$label.report" -Value (ConvertTo-Normal (Get-Trimmed $text))
            }
            'syncboth' {
                $r = Invoke-Captured -Body {
                    Sync-FmSecondmateInheritance -SourceHome (Join-Path $a[0] 'primary') `
                        -DestinationHome (Join-Path $a[0] 'second')
                }
                Add-Record -Key "$label.rc" -Value (Get-Rc $r.Value)
                Add-Record -Key "$label.out" -Value (ConvertTo-Normal (Get-Trimmed $r.Out))
                Add-Record -Key "$label.err" -Value (ConvertTo-Normal (Get-Trimmed ($r.Err + $r.Threw)))
                $rep = [Environment]::GetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT')
                $text = if ($rep -and [System.IO.File]::Exists($rep)) { [System.IO.File]::ReadAllText($rep) } else { '' }
                Add-Record -Key "$label.report" -Value (ConvertTo-Normal (Get-Trimmed $text))
            }
            'destallows' {
                Add-Record -Key "$label.verdict" -Value (
                    (Test-FmInheritableDestination -DestinationConfig $a[0] -Item $a[1]).ToString().ToLowerInvariant())
            }
            'changeditems' {
                $items = @(Get-FmConfigRereadChangedItem -Report $a[0])
                $joined = ''
                foreach ($i in $items) { $joined += "$i," }
                Add-Record -Key "$label.value" -Value $joined
            }
            'allowlisted' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmConfigRereadAllowlistedItem -Item $a[0]).ToString().ToLowerInvariant())
            }
            'writeinstr' {
                $ok = Write-FmConfigRereadInstruction -DestinationHome $a[0] -Report $a[1] -InstructionPath $a[2]
                Add-Record -Key "$label.rc" -Value $(if ($ok) { '0' } else { '1' })
                if ([System.IO.File]::Exists($a[2])) {
                    Add-Record -Key "$label.text" -Value (Get-Trimmed ([System.IO.File]::ReadAllText($a[2])))
                    Add-Record -Key "$label.exists" -Value 'yes'
                } else {
                    Add-Record -Key "$label.text" -Value ''
                    Add-Record -Key "$label.exists" -Value 'no'
                }
            }
            'retrydir' {
                $v = Get-FmConfigRereadRetryDirectory -SourceHome $a[0] -Id $a[1]
                if ($null -eq $v) { Add-Record -Key "$label.value" -Value '<fail>' }
                else { Add-Record -Key "$label.value" -Value ([System.IO.Path]::GetFileName($v)) }
            }
            'queuefull' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmConfigRereadRetryQueueFull -SourceHome $a[0] -Id $a[1]).ToString().ToLowerInvariant())
            }
            'hasstaged' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmConfigRereadStaged -SourceHome $a[0] -Id $a[1]).ToString().ToLowerInvariant())
            }
            'stagecount' {
                Add-Record -Key "$label.value" -Value (
                    Measure-FmInheritItem (Get-FmConfigRereadPendingStage -SourceHome $a[0] -Id $a[1]))
            }
            'pendinginstr' {
                $names = [System.Collections.Generic.List[string]]::new()
                foreach ($p in (Get-FmConfigRereadPendingInstruction -StateDir $a[0])) {
                    $names.Add([System.IO.Path]::GetFileName($p))
                }
                $names.Sort([System.StringComparer]::Ordinal)
                $joined = ''
                foreach ($n in $names) { $joined += "$n," }
                Add-Record -Key "$label.value" -Value $joined
            }
            'haspending' {
                Add-Record -Key "$label.value" -Value (
                    (Test-FmConfigRereadPending -DestinationHome $a[0]).ToString().ToLowerInvariant())
            }
            'cleanupsent' {
                Clear-FmConfigRereadSent -DestinationHome $a[0]
                $state = Join-Path $a[0] 'state'
                $count = 0
                foreach ($p in [System.IO.Directory]::EnumerateFiles($state)) {
                    if ([System.IO.Path]::GetFileName($p).StartsWith('.fm-inherited-config-reread.sent.')) { $count++ }
                }
                Add-Record -Key "$label.count" -Value $count
                $keep = Join-Path $state '.fm-inherited-config-reread.keepme'
                Add-Record -Key "$label.kept" -Value $(if ([System.IO.File]::Exists($keep)) { 'yes' } else { 'no' })
            }
            'sendpointer' {
                $r = Invoke-Captured -Body {
                    Send-FmConfigRereadPointer -Id 'smx' -InstructionPath $a[0] -BinDir $BinDir
                }
                Add-Record -Key "$label.rc" -Value (Get-Rc $r.Value)
                Add-Record -Key "$label.out" -Value (ConvertTo-Normal (Get-Trimmed ($r.Out + $r.Err + $r.Threw)))
            }
            default { Add-Record -Key "$label.value" -Value "UNKNOWN-OP:$op" }
        }
    } catch {
        Add-Record -Key "$label.threw" -Value $_.Exception.Message
    } finally {
        foreach ($name in $applied) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

$realOut.Write($out.ToString())
PS1

phase 'running every queued case in ONE pwsh'
# Prefixed with @@ so Git Bash does not rewrite it on the way to a native
# program. MSYS path-mangles a VALUE that looks like an absolute POSIX path, in
# an argument OR in the environment - verified twice here, once each way - and a
# root that arrived already converted to C:\...\Temp silently normalized nothing.
# A value that does not start with / is passed through untouched.
export FM_TEST_ROOT_POSIX="@@$TMP_ROOT"
if ! pwsh -NoProfile -File "$DRIVER_N" -CaseFile "$CASES_N" -BinDir "$BIN_N" \
  -RootNative "$TMP_ROOT_N" \
  > "$RESULTS" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero:"$'\n'"$(<"$DRIVER_ERR")"
fi
# A clean run is also a SILENT run: a module warning (an unapproved verb, a
# shadowed command) would surface here and must not be tolerated.
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr:"$'\n'"$(<"$DRIVER_ERR")"

while IFS= read -r ps_line; do
  [ -n "$ps_line" ] && PS_LINES+=("$ps_line")
done < "$RESULTS"

# The bash oracle values are folded exactly as the driver folds its own, so the
# comparison is between two identically-shaped strings.
fold_oracle() {
  local i v
  for i in "${!ORC_VALS[@]}"; do
    v=${ORC_VALS[$i]}
    v=${v//$'\t'/<TAB>}
    v=${v//$'\n'/<NL>}
    ORC_VALS[$i]=$v
  done
}
fold_oracle

# --- 0. no case may throw ------------------------------------------------------
ps_threw=''
for ps_line in ${PS_LINES+"${PS_LINES[@]}"}; do
  case "$ps_line" in
    *.threw$'\t'*) ps_threw="$ps_threw ${ps_line%%$'\t'*}" ;;
    BAD$'\t'*) ps_threw="$ps_threw BAD" ;;
  esac
done
assert_same "no case throws in the PowerShell driver" "" "${ps_threw# }"

# =============================================================================
# Assertions
# =============================================================================

# --- [ff] pure helpers --------------------------------------------------------
for k in ff-firstline-plain ff-firstline-runs ff-firstline-tabs ff-firstline-multi \
  ff-firstline-empty ff-firstline-leading; do
  cmp_key "$k.value" "[ff] first_line collapses whitespace identically"
done
for k in ff-anc-child ff-anc-equal ff-anc-sibling ff-anc-parent ff-anc-empty-ancestor \
  ff-anc-empty-path ff-anc-deep; do
  cmp_key "$k.value" "[ff] path ancestry predicate agrees"
done

# --- [ff] the fast-forward decision table -------------------------------------
ff_assert() {  # <key> <what>
  cmp_key "$1.line" "[ff] $2: the reported line"
  cmp_key "$1.status" "[ff] $2: the recorded status"
  cmp_key "$1.instr" "[ff] $2: the instruction list"
  cmp_key "$1.head" "[ff] $2: HEAD afterwards"
}
ff_assert ff-updated 'a behind home advances'
cmp_key ff-updated.parents "[ff] the advanced tip is a single-parent fast-forward, not a merge"
cmp_key ff-updated.detached "[ff] the advanced home stays detached"
ff_assert ff-current 'an at-HEAD home is a no-op'
ff_assert ff-dirty 'REFUSAL: a dirty working tree'
cmp_key ff-dirty.text "[ff] REFUSAL: the uncommitted edit survives the refusal"
ff_assert ff-diverged 'REFUSAL: a diverged home'
ff_assert ff-feature 'REFUSAL: a home on a feature branch'
ff_assert ff-detached 'REFUSAL: a detached home when detachment is not allowed'
ff_assert ff-notdir 'REFUSAL: the target is not a directory'
ff_assert ff-notrepo 'REFUSAL: the target is not a git repo'
ff_assert ff-nobase 'REFUSAL: the base commit does not exist'
ff_assert ff-origin-missing 'REFUSAL: origin base mode with no origin remote'
ff_assert ff-local-nofetch 'the local base mode advances without any origin'
ff_assert ff-marker-converge 'a marker-only-dirty home converges when tolerated'
ff_assert ff-marker-intolerant 'REFUSAL: the same home without marker tolerance'
ff_assert ff-marker-realdirt 'REFUSAL: marker tolerance does not mask real dirt'
cmp_key ff-marker-realdirt.text "[ff] REFUSAL: the genuine edit survives marker tolerance"

# --- [ff] read-only helpers ---------------------------------------------------
cmp_key ff-probe-default.value "[ff] the default branch is resolved identically"
cmp_key ff-probe-head.value "[ff] the primary default-branch commit is resolved identically"
cmp_key ff-probe-instr.value "[ff] the changed instruction surface is listed identically"
cmp_key ff-probe-dirty.value "[ff] dirty status without marker tolerance"
cmp_key ff-probe-dirty-marker.value "[ff] dirty status with marker tolerance"
cmp_key ff-markeronly-plain.value "[ff] a marker-only tree is dirty without tolerance"
cmp_key ff-markeronly-tolerant.value "[ff] a marker-only tree is clean with tolerance"
cmp_key ff-records.value "[ff] live secondmate meta records agree"

# --- [ff] secondmate home validation ------------------------------------------
vh_assert() {  # <key> <what>
  cmp_key "$1.ok" "[ff] validate home, $2: the verdict"
  cmp_key "$1.error" "[ff] validate home, $2: the reason"
}
vh_assert ff-vh-ok 'a well-formed seeded home'
vh_assert ff-vh-missing 'REFUSAL: the home does not exist'
vh_assert ff-vh-wrong-id 'REFUSAL: the marker names a different secondmate'
vh_assert ff-vh-unseeded 'REFUSAL: not a seeded home'
vh_assert ff-vh-is-active 'REFUSAL: the home IS the active firstmate home'
vh_assert ff-vh-is-root 'REFUSAL: the home IS the firstmate repo'
vh_assert ff-vh-bad-active 'REFUSAL: the active firstmate home is missing'
vh_assert ff-vh-bad-root 'REFUSAL: the firstmate repo is missing'
vh_assert ff-vh-inside-active 'REFUSAL: a home path inside the active home'
vh_assert ff-vh-inside-active-real 'REFUSAL: an existing directory inside the active home'
vh_assert ff-vh-ancestor-of-active 'REFUSAL: a home that contains the active home'
vh_assert ff-vh-no-agents 'REFUSAL: no AGENTS.md, so not a firstmate home'
vh_assert ff-vh-no-bin 'REFUSAL: no bin/, so not a firstmate home'
if [ "$JUNCTION_MADE" = 1 ]; then
  vh_assert ff-vh-escaping-dir 'REFUSAL: an operational dir linked outside the home'
fi

# --- [ff] the sweep -----------------------------------------------------------
cmp_key ff-sweep.nudges "[ff] the sweep nudges exactly the instruction-changed home"
cmp_key ff-sweep.out "[ff] the sweep reports the same per-home lines"
for id in sm-instr sm-readme sm-current sm-nonlive; do
  cmp_key "ff-sweep-$id.head" "[ff] the sweep leaves $id at the same commit"
done

# --- [inherit] pure helpers ---------------------------------------------------
cmp_key inh-sha-a.value "[inherit] sha256 of an ordinary file"
cmp_key inh-sha-b.value "[inherit] sha256 of a read-only file"
cmp_key inh-sha-missing.value "[inherit] sha256 refuses a missing file"
cmp_key inh-links-single.value "[inherit] a single-linked file reports one link"
cmp_key inh-links-hard.value "[inherit] a hard-linked file reports more than one"
cmp_key inh-mode-plain.mode "[inherit] an ordinary file reports a writable mode"
cmp_key inh-mode-readonly.mode "[inherit] a read-only file reports 444"
cmp_key inh-same-yes.value "[inherit] identical bytes compare equal"
cmp_key inh-same-no.value "[inherit] different bytes compare unequal"
for h in good empty no-auth no-readonly no-route too-late; do
  cmp_key "inh-hdr-$h.value" "[inherit] the shared-captain header gate, $h"
done
for probe in a.txt a-hard.txt nope.txt; do
  cmp_key "inh-safe-$probe.value" "[inherit] the safe-file predicate, $probe"
done

# --- [inherit] shared captain convergence -------------------------------------
sync_assert() {  # <key> <what>
  cmp_key "$1.rc" "[inherit] $2: the exit status"
  cmp_key "$1.out" "[inherit] $2: stdout"
  cmp_key "$1.err" "[inherit] $2: stderr"
  cmp_key "$1.report" "[inherit] $2: the report line"
}
sync_assert inh-first-copy 'the first shared-captain copy'
cmp_key inh-first-copy.mode "[inherit] the pushed shared copy is read-only"
cmp_key inh-first-copy.text "[inherit] the pushed shared copy holds the primary bytes"
cmp_key inh-first-copy.local "[inherit] the domain-local captain and learnings files are untouched"
cmp_key inh-first-copy.writable "[inherit] an ordinary write to the pushed copy is refused"
sync_assert inh-second-run 'an unchanged re-run stays quiet'
sync_assert inh-drift 'local drift is quarantined'
cmp_key inh-drift.text "[inherit] drift convergence installs the primary bytes"
cmp_key inh-drift.artifacts "[inherit] the quarantine artifact is named for the content hash"
cmp_key inh-drift.preserved "[inherit] the quarantined artifact still holds the local bytes"
sync_assert inh-collide 'a quarantine name collision'
cmp_key inh-collide.count "[inherit] a taken quarantine name adds an artifact rather than replacing one"
cmp_key inh-collide.preserved "[inherit] neither the pre-existing artifact nor the new drift is clobbered"
sync_assert inh-reuse 'drift whose bytes are already quarantined'
cmp_key inh-reuse.artifacts "[inherit] identical drift reuses its artifact instead of accumulating"
sync_assert inh-absent 'an absent primary mirrors as absence'
cmp_key inh-absent.exists "[inherit] the destination copy is removed once quarantined"
cmp_key inh-absent.preserved "[inherit] the orphaned local bytes are preserved in quarantine"
sync_assert inh-nothing 'nothing on either side is a complete no-op'
sync_assert inh-badhdr 'REFUSAL: the primary header lacks its warnings'
if [ "$HARDLINK_MADE" = 1 ]; then
  sync_assert inh-hardlink 'REFUSAL: a hard-linked destination'
fi
if [ "$JUNCTION_DEST" = 1 ]; then
  sync_assert inh-junction 'REFUSAL: a linked destination directory'
fi

# --- [inherit] declared config items ------------------------------------------
sync_assert inh-cfg-push 'an inheritable config item is pushed'
cmp_key inh-cfg-push.text "[inherit] the pushed config item holds the primary bytes"
sync_assert inh-cfg-unchanged 'an unchanged config item is not rewritten'
sync_assert inh-cfg-absence 'clearing the primary value clears it downstream'
cmp_key inh-cfg-absence.exists "[inherit] the mirrored absence removed the destination item"
cmp_key inh-cfg-escape.rc "[inherit] REFUSAL: a traversal item aborts the whole propagation"
cmp_key inh-cfg-escape.report "[inherit] REFUSAL: a traversal item writes no outcome for later items"
sync_assert inh-budget 'REFUSAL: an invalid startup-memory-budget destination'
cmp_key inh-budget.text "[inherit] the invalid budget destination is left untouched"
sync_assert inh-budget-src 'REFUSAL: an invalid startup-memory-budget source'
cmp_key inh-gitdest-nogit.verdict "[inherit] a destination outside any git work tree is allowed by both"
# The safety-critical direction, and the one that must agree on every platform:
# an item the destination repo TRACKS is refused by both worlds, so inheritance
# can never dirty a secondmate home with a tracked file.
orcv inh-gitdest-tracked.verdict; gd_bash=$FM_ORC
psv inh-gitdest-tracked.verdict; gd_ps=$FM_PSV
assert_same "[inherit] REFUSAL: a TRACKED destination is refused by both worlds" \
  "bash=false ps=false" "bash=$gd_bash ps=$gd_ps"
# The declared divergence, asserted as a PAIR so it can never drift silently.
# On Windows the bash prefix test compares `pwd -P` (/tmp/x) against
# `git rev-parse --show-toplevel` (C:/Users/.../Temp/x) and can therefore never
# match, so the oracle skips every item whose destination is inside a work tree;
# the twin normalizes both spellings and answers the question the guard was
# written to ask. Only these two combinations are acceptable: agreement, or that
# exact known Windows path-spelling difference.
orcv inh-gitdest-ignored.verdict; gd_bash=$FM_ORC
psv inh-gitdest-ignored.verdict; gd_ps=$FM_PSV
case "$gd_bash/$gd_ps" in
  true/true) gd_combo=documented-agreement ;;
  false/true) gd_combo=documented-windows-path-spelling-divergence ;;
  *) gd_combo="UNDOCUMENTED bash=$gd_bash ps=$gd_ps" ;;
esac
ASSERTIONS=$((ASSERTIONS + 1))
case "$gd_combo" in
  documented-*) : ;;
  *)
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}[inherit] the gitignore guard on a gitignored destination
  expected: documented-agreement or documented-windows-path-spelling-divergence
  actual  : ${gd_combo}
"
    ;;
esac
printf '# gitignore-guard verdicts: bash=%s pwsh=%s (%s)\n' "$gd_bash" "$gd_ps" "$gd_combo"

# --- [inherit] the config-reread instruction ----------------------------------
cmp_key inh-changed.value "[inherit] changed allowlisted items, in declared order"
cmp_key inh-changed-none.value "[inherit] no changed allowlisted items"
for item in crew-harness data/captain-shared.md secondmate-harness; do
  cmp_key "inh-allow-$item.value" "[inherit] the reread allowlist, $item"
done
cmp_key inh-instr.rc "[inherit] the reread instruction is written"
cmp_key inh-instr.text "[inherit] the reread instruction bytes are identical"
cmp_key inh-instr-absent.rc "[inherit] the reread instruction is written for a removed item"
cmp_key inh-instr-absent.text "[inherit] a removed destination renders as the ABSENT token"
cmp_key inh-instr-none.rc "[inherit] no allowlisted change means no instruction"
cmp_key inh-instr-none.exists "[inherit] a refused instruction leaves no file behind"
for id in 'sm-one' '../escape' 'a b/c' ''; do
  key="inh-retrydir-$(printf '%s' "$id" | tr -c 'a-zA-Z0-9' '_')"
  cmp_key "$key.value" "[inherit] the retry directory token for an id"
done
cmp_key inh-queue-empty.value "[inherit] an empty retry queue is not full"
cmp_key inh-queue-full.value "[inherit] a retry queue at its bound is full"
cmp_key inh-queue-staged.value "[inherit] staged retries are detected"
cmp_key inh-queue-stagecount.value "[inherit] the staged retry count"
cmp_key inh-queue-emptystage.value "[inherit] a zero-length stage is not counted"
cmp_key inh-pending.value "[inherit] pending instructions are listed by marker"
cmp_key inh-haspending.value "[inherit] a home with a pending marker reports pending"
cmp_key inh-cleanup.count "[inherit] the sent-history is pruned to its bound"
cmp_key inh-cleanup.kept "[inherit] a still-pending instruction is never pruned"
cmp_key inh-ptr-missing.rc "[inherit] REFUSAL: a missing instruction file is not sent"
cmp_key inh-ptr-missing.out "[inherit] REFUSAL: a missing instruction file reports why"
cmp_key inh-ptr-mismatch.rc "[inherit] REFUSAL: a mismatched pending marker is not sent"
cmp_key inh-ptr-mismatch.out "[inherit] REFUSAL: a mismatched pending marker reports why"
cmp_key inh-ptr-nohome.rc "[inherit] REFUSAL: no FM_HOME means no send"
cmp_key inh-ptr-nohome.out "[inherit] REFUSAL: no FM_HOME reports why"

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The totals below are EXACT rather than loose floors
# and were taken from an observed green run, so dropping a single case fails the
# run instead of quietly shrinking it. The two conditional blocks depend on
# host capabilities that are probed rather than assumed: directory junctions
# (used for the linked-directory refusals) and hard links.
MIN_ASSERTIONS=234
[ "$JUNCTION_MADE" = 1 ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 2))
[ "$JUNCTION_DEST" = 1 ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 4))
[ "$HARDLINK_MADE" = 1 ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 4))
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-ff-lib.psm1 and fm-config-inherit-lib.psm1 hold their contract across %d assertions\n' \
  "$ASSERTIONS"
printf '# fm-ff-inherit-psm1.test.sh: all assertions passed\n'
