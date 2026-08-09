#!/usr/bin/env bash
# Behavior test for the PowerShell twins of the four secondmate entrypoints:
# bin/fm-home-seed.ps1, bin/fm-config-push.ps1, bin/fm-backlog-handoff.ps1 and
# bin/fm-secondmate-report.ps1.
#
# DIFFERENTIAL, WITH BASH AS THE ORACLE. Every assertion runs the bash
# entrypoint and its PowerShell twin over the SAME fixture recipe with the same
# argv and the same environment, then compares the combined output, the exit
# code, and the files each one left behind. No expectation is hard-coded, so a
# case can never quietly encode what the author believed instead of what the
# shipped script does.
#
# WHY THE REFUSALS DOMINATE THIS FILE. These four scripts create homes, move
# work between homes, and push one home's local material into another's. Every
# one of their failure paths is a decision NOT to touch something:
#
#   - fm-home-seed is TRANSACTIONAL. A partially seeded home looks registered,
#     routes work, and cannot serve it - strictly worse than no home at all. So
#     its refusals are asserted on three surfaces at once: the exact message,
#     the exit code, and the fixture's own files afterwards (registry, marker,
#     charter and project registry all still exactly as they were found).
#   - fm-backlog-handoff moves work between two durable queues, where losing or
#     duplicating an item is unrecoverable by inspection. Its in-flight, Done,
#     missing-key and malformed-body refusals are each proven to move NOTHING,
#     and its idempotent already-present path is proven to report rather than
#     re-move.
#   - fm-config-push pushes MAIN-AUTHORITATIVE material downstream, so its
#     unsafe-home skips are what stop it writing into a directory that is not a
#     secondmate home at all.
#
# BATCHED pwsh - the rule that decides whether this suite finishes. A bare
# `pwsh -NoProfile -Command "exit 0"` costs seconds on the reference host, so a
# pwsh per case would spend the whole run in interpreter startup and present as
# a hang rather than as slowness. Every case is therefore written to a FILE and
# executed by ONE pwsh, which invokes each `.ps1` with `& script @argv` inside
# that single process - `exit` in an &-invoked script sets $LASTEXITCODE and
# returns to the driver, so the exit codes stay exact - and returns everything
# as label<TAB>value records that bash joins by LABEL.
#
# Three consequences of batching, each of which has bitten this repo:
#   - Per-case environment cannot ride on the shell, because by the time the
#     single pwsh runs it would hold only the LAST value assigned. Environment
#     travels in the case RECORD and is cleared and re-applied around each case
#     on the PowerShell side.
#   - Nothing runs inside a `( ... )` subshell whose counter updates could not
#     reach the parent, because a failure that vanishes reads as a pass.
#   - No probe is keyed by a path: the two worlds spell the same location
#     differently, so such a key would never match and every case would read
#     MISSING-KEY even when the values agree. Keys are stable labels.
#
# TWIN FIXTURES. Both scripts MUTATE what they are pointed at, so each case
# builds its world TWICE from one recipe - .../<case>/bash and .../<case>/ps -
# and the world segment is normalized away before comparison.
#
# NORMALIZATION, DECLARED RATHER THAN APPLIED SILENTLY. Exactly three
# transformations are applied, identically on both sides:
#   1. separators are unified to '/', because one directory is legitimately
#      spelled F:\x by .NET and /f/x by MSYS;
#   2. the temp root becomes @R@ and the firstmate repo becomes @F@, each in
#      every spelling the two worlds produce (/tmp/x, C:/Users/.../Temp/x and
#      /c/Users/.../Temp/x are all one directory here), because the roots
#      themselves are not under test;
#   3. the per-world segment /bash or /ps becomes /W, because the two copies of
#      one fixture are deliberately different directories.
# Nothing else is softened: every message, every exit code and every byte of
# every probed file still has to match exactly.
#
# FM_ROOT_OVERRIDE IS SET IN EVERY FIXTURE, not just FM_HOME. Without it FM_ROOT
# falls back to the real firstmate checkout, and fm-guard's worktree-tangle
# check prints into the captured output - a mismatch with nothing to do with the
# twins under test. The config-push and handoff worlds point it at their own
# (non-git) fixture root; the home-seed worlds point it at the REAL repo,
# because fm-home-seed reaches $FM_ROOT/bin/fm-project-mode for its delivery
# -mode refusal, and a fixture root would leave that edge missing in a different
# way on each side.
#
# ITEM-LEVEL INHERITANCE IS OUT OF SCOPE HERE. FM_INHERITABLE_CONFIG is pinned
# to one name no fixture defines, so config-push is exercised on its OWN logic
# (home discovery, validation, dedup, locking, reporting) rather than on
# fm-config-inherit-lib's copy semantics, which tests/fm-ff-inherit-psm1.test.sh
# already covers differentially - including the one deliberate gitignore-guard
# divergence that would otherwise surface here as a false failure.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in fm-home-seed.ps1 fm-config-push.ps1 fm-backlog-handoff.ps1 fm-secondmate-report.ps1; do
  [ -f "$ROOT/bin/$f" ] || fail "bin/$f is missing"
done

TMP_ROOT=$(fm_test_tmproot fm-secondmate-psm1)
fm_git_identity fmtest fmtest@example.invalid

# Path spellings, resolved ONCE: cygpath is a child process and the per-path
# form would dominate this suite.
TMP_ROOT_M=$(cygpath -m "$TMP_ROOT" 2>/dev/null || printf '%s' "$TMP_ROOT")
ROOT_M=$(cygpath -m "$ROOT" 2>/dev/null || printf '%s' "$ROOT")

# The MSYS spelling of a native drive path, which is what ConvertTo-FmPosixPath
# hands back from the PowerShell side.
posixify() {  # <C:/x/y> -> /c/x/y
  local v=$1 drive
  case $v in
    [A-Za-z]:/*)
      drive=${v%%:*}
      printf '/%s%s' "${drive,,}" "${v#*:}"
      ;;
    *) printf '%s' "$v" ;;
  esac
}
TMP_ROOT_P=$(posixify "$TMP_ROOT_M")
ROOT_P=$(posixify "$ROOT_M")

PHASE_START=$SECONDS
phase() { printf '# phase (+%ss): %s\n' "$((SECONDS - PHASE_START))" "$1"; }

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables in PARENT scope only. A `( ... )` subshell cannot report
# a failure back to these counters, and a scheme that can LOSE a failure is
# worse than none: the suite would certify work it never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected(bash)> <actual(pwsh)>
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

# --- normalization and escaping (bash side) -----------------------------------

FM_NORM=
norm() {  # <value> -> FM_NORM
  local v=$1
  v=${v//\\//}
  v=${v//"$TMP_ROOT_M"/@R@}
  v=${v//"$TMP_ROOT_P"/@R@}
  v=${v//"$TMP_ROOT"/@R@}
  v=${v//"$ROOT_M"/@F@}
  v=${v//"$ROOT_P"/@F@}
  v=${v//"$ROOT"/@F@}
  v=${v//\/bash/\/W}
  v=${v//\/ps/\/W}
  FM_NORM=$v
}

FM_ESC=
esc() {  # <value> -> FM_ESC (one TSV-safe line)
  local v=$1
  v=${v//\\/\\\\}
  v=${v//$'\r'/}
  v=${v//$'\n'/\\n}
  v=${v//$'\t'/\\t}
  FM_ESC=$v
}

# The `$(cat f)` twin without the fork: an MSYS fork is expensive enough under
# load that the per-probe form dominated an earlier draft of this suite.
FM_SLURP=
slurp() {  # <path> -> FM_SLURP ('<absent>' when the file is not there)
  FM_SLURP='<absent>'
  [ -f "$1" ] || return 0
  local content=''
  IFS= read -r -d '' content < "$1" || true
  FM_SLURP=$content
}

# --- oracle and result tables -------------------------------------------------

ORC_KEYS=()
ORC_VALS=()
FM_ORC=

orc() { ORC_KEYS+=("$1"); ORC_VALS+=("$2"); }

orcv() {  # <key> -> FM_ORC
  local key=$1 i
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

cmp_key() {  # <key> <label>
  orcv "$1"
  psv "$1"
  assert_same "$2" "$FM_ORC" "$FM_PSV"
}

# --- the case runner ----------------------------------------------------------
#
# One record per case: label \t script \t env \t probes \t argv.
#   env    K=V;K=V   (V may contain @W@ or @F@, expanded per world)
#   probes ';'-separated world-relative paths, or '-'
#   argv   \x1f-separated tokens, or '-' for none (an EMPTY field is a
#          one-element argv holding the empty string, which several cases need)
US=$'\x1f'
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$CASE_FILE"

# The environment variables this suite OWNS. Every one is cleared before each
# case and re-applied from the record, on both sides, so no case can inherit a
# neighbour's setting.
MANAGED_ENV="FM_HOME FM_ROOT_OVERRIDE FM_INHERITABLE_CONFIG FM_SECONDMATE_CHARTER FM_SECONDMATE_SCOPE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE"

CASE_LABELS=()

run_case() {  # <label> <builder> <script> <env> <probes> <argv...>
  local label=$1 builder=$2 script=$3 envspec=$4 probes=$5
  shift 5

  local world_b="$TMP_ROOT/$label/bash"
  "$builder" "$world_b"
  "$builder" "$TMP_ROOT/$label/ps"

  local name pair k v tok
  for name in $MANAGED_ENV; do unset "$name"; done

  local pairs=()
  local old_ifs=$IFS
  IFS=';' read -r -a pairs <<< "$envspec"
  IFS=$old_ifs
  for pair in ${pairs+"${pairs[@]}"}; do
    [ -n "$pair" ] || continue
    k=${pair%%=*}
    v=${pair#*=}
    v=${v//@W@/$world_b}
    v=${v//@F@/$ROOT}
    export "$k=$v"
  done

  local argv=()
  for tok in "$@"; do
    tok=${tok//@W@/$world_b}
    tok=${tok//@F@/$ROOT}
    argv+=("$tok")
  done

  local out rc
  out=$(bash "$ROOT/bin/$script.sh" ${argv+"${argv[@]}"} 2>&1)
  rc=$?
  norm "$out"; esc "$FM_NORM"
  orc "$label.rc" "$rc"
  orc "$label.out" "$FM_ESC"

  if [ "$probes" != "-" ]; then
    local probe_list=()
    IFS=';' read -r -a probe_list <<< "$probes"
    IFS=$old_ifs
    local i=0 probe
    for probe in ${probe_list+"${probe_list[@]}"}; do
      [ -n "$probe" ] || continue
      slurp "$world_b/$probe"
      norm "$FM_SLURP"; esc "$FM_NORM"
      orc "$label.file$i" "$FM_ESC"
      i=$((i + 1))
    done
  fi
  for name in $MANAGED_ENV; do unset "$name"; done

  # The pwsh case record. The argv list is built by INDEX rather than by testing
  # the accumulator for emptiness: several cases pass '' as their FIRST token,
  # and an emptiness test would silently drop it.
  local argvspec='-' n=0
  for tok in "$@"; do
    if [ "$n" -eq 0 ]; then argvspec=$tok; else argvspec="$argvspec$US$tok"; fi
    n=$((n + 1))
  done
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$script" "$envspec" "$probes" "$argvspec" >> "$CASE_FILE"
  CASE_LABELS+=("$label")
}

# --- shared fixture builders --------------------------------------------------

# A directory that passes the "is this a firstmate home" test used by both
# fm-home-seed and fm-backlog-handoff: AGENTS.md, bin/, and the four
# operational dirs.
mk_firstmate_home() {  # <dir>
  mkdir -p "$1/bin" "$1/data" "$1/state" "$1/config" "$1/projects"
  printf 'agents\n' > "$1/AGENTS.md"
}

mk_active_home() {  # <world>
  mkdir -p "$1/home/data" "$1/home/state" "$1/home/config" "$1/home/projects"
}

mk_seeded_home() {  # <dir> <id>
  mk_firstmate_home "$1"
  printf '%s\n' "$2" > "$1/.fm-secondmate-home"
}

mk_registry() {  # <world> <record-line...>
  mkdir -p "$1/home/data"
  shift 0
  :
}

mk_secondmate_meta() {  # <world> <id> <home|-> [window]
  mkdir -p "$1/home/state"
  local meta="$1/home/state/$2.meta"
  printf 'kind=secondmate\n' > "$meta"
  [ "$3" = "-" ] || printf 'home=%s\n' "$3" >> "$meta"
  [ $# -lt 4 ] || printf 'window=%s\n' "$4" >> "$meta"
}

# A charter brief that satisfies every content gate: a Charter section, a
# Routing scope section, and a project-less Project clones section.
mk_brief() {  # <path> [charter] [scope] [clones]
  local path=$1
  mkdir -p "${path%/*}"
  {
    printf '# Charter\n%s\n\n' "${2-Own the widget domain.}"
    printf '# Routing scope\n%s\n\n' "${3-widget work}"
    printf '# Project clones\n%s\n' "${4-None. This is a project-less domain.}"
  } > "$path"
}

phase 'building cases'

# =============================================================================
# fm-secondmate-report
# =============================================================================

RPT_ENV='FM_HOME=@W@/home;FM_ROOT_OVERRIDE=@W@/root'
fx_rpt() { mkdir -p "$1/root" "$1/home"; }
fx_rpt_blocked() { fx_rpt "$1"; printf 'x\n' > "$1/blocker"; }

run_case rpt-usage fx_rpt fm-secondmate-report "$RPT_ENV" -
run_case rpt-short fx_rpt fm-secondmate-report "$RPT_ENV" - '@W@/s.status' 'done' abcdef0123456789
run_case rpt-badcorr fx_rpt fm-secondmate-report "$RPT_ENV" - '@W@/s.status' 'done' zz note
run_case rpt-badcorr-prefix fx_rpt fm-secondmate-report "$RPT_ENV" - \
  '@W@/s.status' 'done' 'corr=xyz' note
run_case rpt-corr-prefix fx_rpt fm-secondmate-report "$RPT_ENV" 's.status' \
  '@W@/s.status' 'done' 'corr=abcdef0123456789' note
run_case rpt-note fx_rpt fm-secondmate-report "$RPT_ENV" 's.status' \
  '@W@/s.status' 'done' abcdef0123456789 audit clean
run_case rpt-nonote fx_rpt fm-secondmate-report "$RPT_ENV" 's.status' \
  '@W@/s.status' 'done' abcdef0123456789 ''
run_case rpt-doc-note fx_rpt fm-secondmate-report "$RPT_ENV" 's.status' \
  --doc '@W@/s.status' 'done' abcdef0123456789 data/x/report.md see report
run_case rpt-doc-nonote fx_rpt fm-secondmate-report "$RPT_ENV" 's.status' \
  --doc '@W@/s.status' 'done' abcdef0123456789 data/x/report.md
run_case rpt-doc-nopath fx_rpt fm-secondmate-report "$RPT_ENV" - \
  --doc '@W@/s.status' 'done' abcdef0123456789
run_case rpt-emptystatus fx_rpt fm-secondmate-report "$RPT_ENV" - '' 'done' abcdef0123456789 note
run_case rpt-emptystatus-badcorr fx_rpt fm-secondmate-report "$RPT_ENV" - '' 'done' zz note
run_case rpt-nested fx_rpt fm-secondmate-report "$RPT_ENV" 'deep/er/s.status' \
  '@W@/deep/er/s.status' 'done' abcdef0123456789 note
run_case rpt-parent-is-file fx_rpt_blocked fm-secondmate-report "$RPT_ENV" - \
  '@W@/blocker/s.status' 'done' abcdef0123456789 note

phase 'report cases built'

# =============================================================================
# fm-home-seed
# =============================================================================

HS_ENV='FM_HOME=@W@/home;FM_ROOT_OVERRIDE=@F@'

fx_hs() { mk_active_home "$1"; }

fx_hs_reg_ok() {
  mk_active_home "$1"; mkdir -p "$1/sub"
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_hs_reg_malformed() {
  mk_active_home "$1"
  printf -- '- s1 - broken record with no suffix\n' > "$1/home/data/secondmates.md"
}
fx_hs_reg_relhome() {
  mk_active_home "$1"
  printf -- '- s1 - own widgets (home: rel/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    > "$1/home/data/secondmates.md"
}
fx_hs_reg_dupid() {
  mk_active_home "$1"; mkdir -p "$1/a" "$1/b"
  {
    printf -- '- s1 - own widgets (home: %s/a; scope: widget work; projects: ; added 2026-01-01)\n' "$1"
    printf -- '- s1 - own gadgets (home: %s/b; scope: gadget work; projects: ; added 2026-01-01)\n' "$1"
  } > "$1/home/data/secondmates.md"
}
fx_hs_reg_duphome() {
  mk_active_home "$1"; mkdir -p "$1/a"
  {
    printf -- '- s1 - own widgets (home: %s/a; scope: widget work; projects: ; added 2026-01-01)\n' "$1"
    printf -- '- s2 - own gadgets (home: %s/a; scope: gadget work; projects: ; added 2026-01-01)\n' "$1"
  } > "$1/home/data/secondmates.md"
}
fx_hs_reg_overlap() {
  mk_active_home "$1"; mkdir -p "$1/a/inner"
  {
    printf -- '- s1 - own widgets (home: %s/a; scope: widget work; projects: ; added 2026-01-01)\n' "$1"
    printf -- '- s2 - own gadgets (home: %s/a/inner; scope: gadget work; projects: ; added 2026-01-01)\n' "$1"
  } > "$1/home/data/secondmates.md"
}

run_case hs-usage fx_hs fm-home-seed "$HS_ENV" -
run_case hs-help fx_hs fm-home-seed "$HS_ENV" - --help
run_case hs-validate-empty fx_hs fm-home-seed "$HS_ENV" - validate
run_case hs-validate-extra fx_hs fm-home-seed "$HS_ENV" - validate extra
run_case hs-validate-ok fx_hs_reg_ok fm-home-seed "$HS_ENV" - validate
run_case hs-validate-malformed fx_hs_reg_malformed fm-home-seed "$HS_ENV" - validate
run_case hs-validate-relhome fx_hs_reg_relhome fm-home-seed "$HS_ENV" - validate
run_case hs-validate-dupid fx_hs_reg_dupid fm-home-seed "$HS_ENV" - validate
run_case hs-validate-duphome fx_hs_reg_duphome fm-home-seed "$HS_ENV" - validate
run_case hs-validate-overlap fx_hs_reg_overlap fm-home-seed "$HS_ENV" - validate
run_case hs-few-args fx_hs fm-home-seed "$HS_ENV" - s1 '@W@/sub'
run_case hs-noproj-and-list fx_hs fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects widgets
run_case hs-home-is-active fx_hs fm-home-seed "$HS_ENV" - s1 '@W@/home' --no-projects
run_case hs-home-in-repo fx_hs fm-home-seed "$HS_ENV" - s1 '@F@/nested-sub' --no-projects
run_case hs-home-ancestor fx_hs fm-home-seed "$HS_ENV" - s1 '@W@' --no-projects

# Project pre-flight refusals. The first two fire before fm-project-mode is
# consulted; the third is the delivery-mode refusal itself.
fx_hs_proj_notgit() { mk_active_home "$1"; mkdir -p "$1/home/projects/widgets"; }
fx_hs_proj_localonly() {
  mk_active_home "$1"
  mkdir -p "$1/home/projects/widgets"
  git -C "$1/home/projects/widgets" init --quiet
  printf -- '- widgets - the widget project (local-only; added 2026-01-01)\n' \
    > "$1/home/data/projects.md"
}
run_case hs-project-missing fx_hs fm-home-seed "$HS_ENV" - s1 '@W@/sub' widgets
run_case hs-project-notgit fx_hs_proj_notgit fm-home-seed "$HS_ENV" - s1 '@W@/sub' widgets
run_case hs-project-localonly fx_hs_proj_localonly fm-home-seed "$HS_ENV" - s1 '@W@/sub' widgets

# Home-assignment refusals.
fx_hs_marked_other() { mk_active_home "$1"; mk_seeded_home "$1/sub" other; }
fx_hs_id_elsewhere() {
  mk_active_home "$1"; mk_firstmate_home "$1/sub"; mkdir -p "$1/other"
  printf -- '- s1 - own widgets (home: %s/other; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_hs_home_taken() {
  mk_active_home "$1"; mk_firstmate_home "$1/sub"
  printf -- '- other - own gadgets (home: %s/sub; scope: gadget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_hs_home_overlaps() {
  mk_active_home "$1"; mk_firstmate_home "$1/sub"; mkdir -p "$1/sub/inner"
  printf -- '- other - own gadgets (home: %s/sub/inner; scope: gadget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
run_case hs-marked-other fx_hs_marked_other fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-id-elsewhere fx_hs_id_elsewhere fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-home-taken fx_hs_home_taken fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-home-overlaps fx_hs_home_overlaps fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects

# "Is this a firstmate home" refusals. Each target EXISTS, so the git clone arm
# is never taken: cloning the real repo twice per case would dominate this
# suite's runtime and add nothing to the refusal being asserted.
fx_hs_bare_dir() { mk_active_home "$1"; mkdir -p "$1/sub"; }
fx_hs_no_bin() { mk_active_home "$1"; mkdir -p "$1/sub"; printf 'agents\n' > "$1/sub/AGENTS.md"; }
fx_hs_not_dir() { mk_active_home "$1"; printf 'x\n' > "$1/sub"; }
run_case hs-not-home fx_hs_bare_dir fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-no-bin fx_hs_no_bin fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-not-dir fx_hs_not_dir fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects

# Charter-brief content gates.
fx_hs_ready() { mk_active_home "$1"; mk_firstmate_home "$1/sub"; }
fx_hs_brief_task() {
  fx_hs_ready "$1"; mk_brief "$1/home/data/s1/brief.md" '{TASK}' 'widget work'
}
fx_hs_brief_nocharter() {
  fx_hs_ready "$1"; mk_brief "$1/home/data/s1/brief.md" '' 'widget work'
}
fx_hs_brief_noscope() {
  fx_hs_ready "$1"; mk_brief "$1/home/data/s1/brief.md" 'Own the widget domain.' ''
}
run_case hs-no-charter fx_hs_ready fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-brief-task fx_hs_brief_task fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-empty-charter fx_hs_brief_nocharter fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-empty-scope fx_hs_brief_noscope fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects

# --no-projects refusals: an existing home that holds project data, and a
# charter that contradicts the flag.
fx_hs_populated() {
  fx_hs_ready "$1"
  mkdir -p "$1/sub/projects/widgets"
  printf -- '- gadgets - the gadget project (added 2026-01-01)\n' > "$1/sub/data/projects.md"
  mk_brief "$1/home/data/s1/brief.md"
}
fx_hs_charter_conflict() {
  fx_hs_ready "$1"
  mk_brief "$1/home/data/s1/brief.md" 'Own the widget domain.' 'widget work' '- widgets'
}
run_case hs-projectless-populated fx_hs_populated fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects
run_case hs-projectless-charter fx_hs_charter_conflict fm-home-seed "$HS_ENV" - s1 '@W@/sub' --no-projects

# The transactional happy path, and the rollback that protects it. The success
# case is probed on every durable artifact it writes; the rollback case fails at
# the LAST content gate - after the backups were taken - and is probed on every
# artifact that must still be exactly as it was found.
fx_hs_seed_ok() {
  fx_hs_ready "$1"
  mk_brief "$1/home/data/s1/brief.md"
  mkdir -p "$1/old"
  printf -- '- old - a previously registered secondmate (home: %s/old; scope: old work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_hs_rollback() {
  mk_active_home "$1"
  mk_seeded_home "$1/sub" s1
  printf 'OLD CHARTER\n' > "$1/sub/data/charter.md"
  printf -- '- gadgets - previously seeded (added 2026-01-01)\n' > "$1/sub/data/projects.md"
  mkdir -p "$1/old"
  printf -- '- old - a previously registered secondmate (home: %s/old; scope: old work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
  mk_brief "$1/home/data/s1/brief.md" 'Own the widget domain.' ''
}
HS_ARTIFACTS='home/data/secondmates.md;sub/.fm-secondmate-home;sub/data/charter.md;sub/data/projects.md'
run_case hs-seed-ok fx_hs_seed_ok fm-home-seed "$HS_ENV" "$HS_ARTIFACTS" s1 '@W@/sub' --no-projects
run_case hs-rollback fx_hs_rollback fm-home-seed "$HS_ENV" "$HS_ARTIFACTS" s1 '@W@/sub' --no-projects

# The inline-charter override: the path a seed takes when no filled brief exists.
run_case hs-inline-charter fx_hs_ready fm-home-seed \
  "$HS_ENV;FM_SECONDMATE_CHARTER=Own the widget domain;FM_SECONDMATE_SCOPE=widget work" \
  'home/data/secondmates.md;sub/.fm-secondmate-home' s1 '@W@/sub' --no-projects

phase 'home-seed cases built'

# =============================================================================
# fm-backlog-handoff
# =============================================================================

BH_ENV='FM_HOME=@W@/home;FM_ROOT_OVERRIDE=@W@/root'

mk_main_backlog() {  # <world>
  mkdir -p "$1/home/data"
  {
    printf '## In flight\n\n'
    printf -- '- [ ] flying an in-flight item\n'
    printf '  more body\n\n'
    printf '## Queued\n\n'
    printf -- '- [ ] queued a queued item\n'
    printf '  body line\n\n'
    printf -- '- [ ] badbody an item with a bad continuation\n'
    printf ' single-space continuation\n\n'
    printf '## Done\n\n'
    printf -- '- [x] finished a done item\n'
  } > "$1/home/data/backlog.md"
}

fx_bh() {  # <world>: registry + a genuine seeded secondmate home + a main backlog
  mkdir -p "$1/root"
  mk_active_home "$1"
  mk_seeded_home "$1/sub" s1
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
  mk_main_backlog "$1"
}
fx_bh_no_registry() { mkdir -p "$1/root"; mk_active_home "$1"; }
fx_bh_no_home() {
  mkdir -p "$1/root"; mk_active_home "$1"
  printf -- '- other - own gadgets (home: %s/sub; scope: gadget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_bh_unseeded() {
  mkdir -p "$1/root"; mk_active_home "$1"; mk_firstmate_home "$1/sub"
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_bh_wrong_marker() {
  mkdir -p "$1/root"; mk_active_home "$1"; mk_seeded_home "$1/sub" other
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_bh_home_is_active() {
  mkdir -p "$1/root"; mk_active_home "$1"
  printf -- '- s1 - own widgets (home: %s/home; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_bh_no_agents() {
  mkdir -p "$1/root"; mk_active_home "$1"
  mkdir -p "$1/sub/bin" "$1/sub/data" "$1/sub/state" "$1/sub/config" "$1/sub/projects"
  printf 's1\n' > "$1/sub/.fm-secondmate-home"
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_bh_already() {
  fx_bh "$1"
  printf '## In flight\n\n## Queued\n\n- [ ] queued a queued item\n\n## Done\n' \
    > "$1/sub/data/backlog.md"
}
fx_bh_sub_notfile() { fx_bh "$1"; mkdir -p "$1/sub/data/backlog.md"; }

run_case bh-usage fx_bh fm-backlog-handoff "$BH_ENV" - s1
run_case bh-no-registry fx_bh_no_registry fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-no-home fx_bh_no_home fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-unseeded fx_bh_unseeded fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-wrong-marker fx_bh_wrong_marker fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-home-is-active fx_bh_home_is_active fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-no-agents fx_bh_no_agents fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-inflight fx_bh fm-backlog-handoff "$BH_ENV" 'home/data/backlog.md' s1 flying
run_case bh-done fx_bh fm-backlog-handoff "$BH_ENV" 'home/data/backlog.md' s1 finished
run_case bh-missing fx_bh fm-backlog-handoff "$BH_ENV" 'home/data/backlog.md' s1 queued nosuchkey
run_case bh-badbody fx_bh fm-backlog-handoff "$BH_ENV" 'home/data/backlog.md' s1 badbody
run_case bh-already fx_bh_already fm-backlog-handoff "$BH_ENV" \
  'home/data/backlog.md;sub/data/backlog.md' s1 queued
run_case bh-sub-notfile fx_bh_sub_notfile fm-backlog-handoff "$BH_ENV" - s1 queued
run_case bh-move fx_bh fm-backlog-handoff "$BH_ENV" \
  'home/data/backlog.md;sub/data/backlog.md' s1 queued

phase 'handoff cases built'

# =============================================================================
# fm-config-push
# =============================================================================
#
# FM_INHERITABLE_CONFIG names one item no fixture defines: see the header.

CP_ENV='FM_HOME=@W@/home;FM_ROOT_OVERRIDE=@W@/root;FM_INHERITABLE_CONFIG=zz-not-a-real-item'

fx_cp() {  # <world>
  mkdir -p "$1/root"
  mk_active_home "$1"
  # A fresh watcher beacon keeps fm-guard silent: an absent beacon alongside a
  # live task record is exactly its stale-watcher alarm, and that banner is not
  # what this suite is comparing.
  : > "$1/home/state/.last-watcher-beat"
}
fx_cp_no_home_field() { fx_cp "$1"; mk_secondmate_meta "$1" s1 -; }
fx_cp_registry_home() {
  fx_cp "$1"
  mk_secondmate_meta "$1" s1 -
  mk_seeded_home "$1/sub" s1
  printf -- '- s1 - own widgets (home: %s/sub; scope: widget work; projects: ; added 2026-01-01)\n' \
    "$1" > "$1/home/data/secondmates.md"
}
fx_cp_unsafe_home() { fx_cp "$1"; mkdir -p "$1/sub"; mk_secondmate_meta "$1" s1 "$1/sub"; }
fx_cp_unmarked_home() { fx_cp "$1"; mk_firstmate_home "$1/sub"; mk_secondmate_meta "$1" s1 "$1/sub"; }
fx_cp_valid() { fx_cp "$1"; mk_seeded_home "$1/sub" s1; mk_secondmate_meta "$1" s1 "$1/sub"; }
fx_cp_dirty() {
  fx_cp "$1"
  mk_seeded_home "$1/sub" s1
  git -C "$1/sub" init --quiet
  mk_secondmate_meta "$1" s1 "$1/sub"
}

run_case cp-help fx_cp fm-config-push "$CP_ENV" - --help
run_case cp-h fx_cp fm-config-push "$CP_ENV" - -h
run_case cp-badarg fx_cp fm-config-push "$CP_ENV" - bogus
run_case cp-nohomes fx_cp fm-config-push "$CP_ENV" -
run_case cp-no-home-field fx_cp_no_home_field fm-config-push "$CP_ENV" -
run_case cp-registry-home fx_cp_registry_home fm-config-push "$CP_ENV" -
run_case cp-unsafe-home fx_cp_unsafe_home fm-config-push "$CP_ENV" -
run_case cp-unmarked-home fx_cp_unmarked_home fm-config-push "$CP_ENV" -
run_case cp-valid fx_cp_valid fm-config-push "$CP_ENV" -
run_case cp-dirty fx_cp_dirty fm-config-push "$CP_ENV" -

phase 'config-push cases built; running the single pwsh batch'

# =============================================================================
# ONE pwsh over every case
# =============================================================================

DRIVER="$TMP_ROOT/driver.ps1"
cat > "$DRIVER" <<'PSEOF'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$caseFile = $args[0]
$binDir = $args[1]
# The six root spellings come from a FILE, never from argv. Git Bash rewrites a
# POSIX-looking command-line argument into its Windows spelling on the way to a
# native program, so /tmp/x and /c/Users/.../Temp/x both arrived here already
# converted to C:/Users/.../Temp/x - three identical roots - and every output
# carrying an unconverted spelling then failed to normalize. A file is not
# touched by that conversion.
$roots = @([System.IO.File]::ReadAllLines($args[2]))
$tmpRootM = $roots[0]   # C:/Users/.../Temp/<root>
$tmpRootP = $roots[1]   # /c/Users/.../Temp/<root>
$tmpRootB = $roots[2]   # /tmp/<root>
$rootM = $roots[3]
$rootP = $roots[4]
$rootB = $roots[5]

$managed = @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_INHERITABLE_CONFIG', 'FM_SECONDMATE_CHARTER',
    'FM_SECONDMATE_SCOPE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
    'FM_PROJECTS_OVERRIDE')

$sb = [System.Text.StringBuilder]::new()
function Add-Record {
    param([string]$Key, [string]$Value)
    $v = $Value.Replace('\', '\\').Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
    [void]$sb.Append($Key).Append("`t").Append($v).Append("`n")
}

# The bash `norm` twin: the identical transformations in the identical order.
function ConvertTo-Normalized {
    param([string]$Value)
    $v = $Value.Replace('\', '/')
    foreach ($r in @($tmpRootM, $tmpRootP, $tmpRootB)) {
        if ($r -ne '') { $v = $v.Replace($r, '@R@') }
    }
    foreach ($r in @($rootM, $rootP, $rootB)) {
        if ($r -ne '') { $v = $v.Replace($r, '@F@') }
    }
    return $v.Replace('/bash', '/W').Replace('/ps', '/W')
}

foreach ($line in [System.IO.File]::ReadAllLines($caseFile)) {
    if ($line -eq '') { continue }
    # @(...) around Split: PowerShell unrolls a single-element array into a bare
    # string, which then fails to index.
    $f = @($line.Split("`t"))
    if ($f.Length -lt 5) { continue }
    $label = $f[0]; $entry = $f[1]; $envSpec = $f[2]; $probeSpec = $f[3]; $argvSpec = $f[4]

    $world = "$tmpRootM/$label/ps"

    # Per-case environment: cleared FIRST, then applied from the RECORD. Riding
    # on the shell would leave every case evaluated under the last one's values.
    foreach ($name in $managed) { [Environment]::SetEnvironmentVariable($name, $null) }
    foreach ($pair in @($envSpec.Split(';'))) {
        if ($pair -eq '') { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -lt 1) { continue }
        [Environment]::SetEnvironmentVariable($pair.Substring(0, $eq),
            $pair.Substring($eq + 1).Replace('@W@', $world).Replace('@F@', $rootB))
    }

    $argv = @()
    if ($argvSpec -ne '-') {
        foreach ($tok in @($argvSpec.Split([char]0x1f))) {
            $argv += ($tok.Replace('@W@', $world).Replace('@F@', $rootB))
        }
    }

    $target = Join-Path $binDir "$entry.ps1"
    $writer = [System.IO.StringWriter]::new()
    $savedOut = [Console]::Out
    $savedErr = [Console]::Error
    $global:LASTEXITCODE = 0
    try {
        [Console]::SetOut($writer)
        [Console]::SetError($writer)
        if ($argv.Count -eq 0) { & $target } else { & $target @argv }
    } catch {
        $writer.Write("DRIVER-EXCEPTION: $($_.Exception.Message)`n")
    } finally {
        [Console]::SetOut($savedOut)
        [Console]::SetError($savedErr)
    }
    $rc = $global:LASTEXITCODE

    # `$(cmd 2>&1)` strips trailing newlines and nothing else.
    Add-Record -Key "$label.rc" -Value ([string]$rc)
    Add-Record -Key "$label.out" -Value (ConvertTo-Normalized ($writer.ToString().TrimEnd("`n")))

    if ($probeSpec -ne '-') {
        $i = 0
        foreach ($probe in @($probeSpec.Split(';'))) {
            if ($probe -eq '') { continue }
            $path = "$world/$probe"
            $text = '<absent>'
            if ([System.IO.File]::Exists($path)) { $text = [System.IO.File]::ReadAllText($path) }
            Add-Record -Key "$label.file$i" -Value (ConvertTo-Normalized $text)
            $i++
        }
    }
}
foreach ($name in $managed) { [Environment]::SetEnvironmentVariable($name, $null) }
[Console]::Out.Write($sb.ToString())
PSEOF

# The root spellings travel in a FILE, not in argv: Git Bash converts a
# POSIX-looking argument to its Windows spelling before a native program sees
# it, which silently collapsed /tmp/<root> and /c/.../<root> onto the third
# spelling and left every output carrying one of the first two unnormalized.
ROOTS_FILE="$TMP_ROOT/roots.txt"
for r in "$TMP_ROOT_M" "$TMP_ROOT_P" "$TMP_ROOT" "$ROOT_M" "$ROOT_P" "$ROOT"; do
  printf '%s\n' "$r"
done > "$ROOTS_FILE"

CASE_FILE_N=$(fm_test_native_path "$CASE_FILE")
DRIVER_N=$(fm_test_native_path "$DRIVER")
ROOTS_FILE_N=$(fm_test_native_path "$ROOTS_FILE")
BIN_N=$(fm_test_native_path "$ROOT/bin")
PS_OUT="$TMP_ROOT/ps-out.tsv"
PS_ERR="$TMP_ROOT/ps-err.txt"

pwsh -NoProfile -File "$DRIVER_N" "$CASE_FILE_N" "$BIN_N" "$ROOTS_FILE_N" > "$PS_OUT" 2>"$PS_ERR"
PS_RC=$?

if [ "$PS_RC" -ne 0 ]; then
  echo "not ok - the pwsh batch driver failed (rc=$PS_RC)" >&2
  cat "$PS_ERR" >&2
  exit 1
fi

while IFS= read -r line; do
  PS_LINES+=("$line")
done < "$PS_OUT"

phase 'comparing'

# --- comparison ---------------------------------------------------------------
#
# Every case contributes an exit-code assertion and a combined-output assertion;
# a case that declared probes contributes one per probed file. The labels name
# the contract rather than the case id, so a failure is readable on its own.

FM_DESC=
describe() {  # <label> -> FM_DESC
  case $1 in
    rpt-usage) FM_DESC='[report] no arguments prints usage' ;;
    rpt-short) FM_DESC='[report] REFUSAL: three arguments is not enough' ;;
    rpt-badcorr) FM_DESC='[report] REFUSAL: a non-hex corr id' ;;
    rpt-badcorr-prefix) FM_DESC='[report] REFUSAL: a corr= prefix is stripped before validation' ;;
    rpt-corr-prefix) FM_DESC='[report] a corr= prefixed id is accepted' ;;
    rpt-note) FM_DESC='[report] a multi-word note is joined by single spaces' ;;
    rpt-nonote) FM_DESC='[report] an empty note takes the no-note form' ;;
    rpt-doc-note) FM_DESC='[report] --doc with a note carries both' ;;
    rpt-doc-nonote) FM_DESC='[report] --doc with no note carries the path alone' ;;
    rpt-doc-nopath) FM_DESC='[report] REFUSAL: --doc with no document path' ;;
    rpt-emptystatus) FM_DESC='[report] REFUSAL: an empty status file path' ;;
    rpt-emptystatus-badcorr) FM_DESC='[report] the corr check precedes the status-file check' ;;
    rpt-nested) FM_DESC='[report] a missing parent directory is created' ;;
    rpt-parent-is-file) FM_DESC='[report] REFUSAL: the parent directory cannot be created' ;;
    hs-usage) FM_DESC='[seed] no arguments prints usage' ;;
    hs-help) FM_DESC='[seed] --help prints usage' ;;
    hs-validate-empty) FM_DESC='[seed] validate accepts an absent registry' ;;
    hs-validate-extra) FM_DESC='[seed] REFUSAL: validate takes no extra argument' ;;
    hs-validate-ok) FM_DESC='[seed] validate accepts a well-formed registry' ;;
    hs-validate-malformed) FM_DESC='[seed] REFUSAL: a malformed registry entry' ;;
    hs-validate-relhome) FM_DESC='[seed] REFUSAL: a non-absolute registered home' ;;
    hs-validate-dupid) FM_DESC='[seed] REFUSAL: one id bound to two homes' ;;
    hs-validate-duphome) FM_DESC='[seed] REFUSAL: two ids bound to one home' ;;
    hs-validate-overlap) FM_DESC='[seed] REFUSAL: one registered home nested in another' ;;
    hs-few-args) FM_DESC='[seed] REFUSAL: too few arguments' ;;
    hs-noproj-and-list) FM_DESC='[seed] REFUSAL: --no-projects with a project list' ;;
    hs-home-is-active) FM_DESC='[seed] REFUSAL: the home is the active firstmate home' ;;
    hs-home-in-repo) FM_DESC='[seed] REFUSAL: the home is inside the firstmate repo' ;;
    hs-home-ancestor) FM_DESC='[seed] REFUSAL: the home is an ancestor of the active home' ;;
    hs-project-missing) FM_DESC='[seed] REFUSAL: a project that is not cloned here' ;;
    hs-project-notgit) FM_DESC='[seed] REFUSAL: a project directory that is not a git repo' ;;
    hs-project-localonly) FM_DESC='[seed] REFUSAL: a local-only project cannot be routed' ;;
    hs-marked-other) FM_DESC='[seed] REFUSAL: the home is already marked for another secondmate' ;;
    hs-id-elsewhere) FM_DESC='[seed] REFUSAL: the id is already registered to another home' ;;
    hs-home-taken) FM_DESC='[seed] REFUSAL: the home is already registered to another id' ;;
    hs-home-overlaps) FM_DESC='[seed] REFUSAL: the home overlaps a registered home' ;;
    hs-not-home) FM_DESC='[seed] REFUSAL: the target is not a firstmate home (no AGENTS.md)' ;;
    hs-no-bin) FM_DESC='[seed] REFUSAL: the target is not a firstmate home (no bin/)' ;;
    hs-not-dir) FM_DESC='[seed] REFUSAL: the target exists and is not a directory' ;;
    hs-no-charter) FM_DESC='[seed] REFUSAL: no filled charter brief and no inline charter' ;;
    hs-brief-task) FM_DESC='[seed] REFUSAL: the charter brief still holds the {TASK} placeholder' ;;
    hs-empty-charter) FM_DESC='[seed] REFUSAL: an empty Charter section' ;;
    hs-empty-scope) FM_DESC='[seed] REFUSAL: an empty Routing scope section' ;;
    hs-projectless-populated) FM_DESC='[seed] REFUSAL: --no-projects into a home holding project data' ;;
    hs-projectless-charter) FM_DESC='[seed] REFUSAL: --no-projects against a project-ful charter' ;;
    hs-seed-ok) FM_DESC='[seed] the transactional happy path' ;;
    hs-rollback) FM_DESC='[seed] a late refusal leaves every durable artifact untouched' ;;
    hs-inline-charter) FM_DESC='[seed] FM_SECONDMATE_CHARTER seeds without a filled brief' ;;
    bh-usage) FM_DESC='[handoff] REFUSAL: no item keys' ;;
    bh-no-registry) FM_DESC='[handoff] REFUSAL: no secondmate registry' ;;
    bh-no-home) FM_DESC='[handoff] REFUSAL: the id has no registered home' ;;
    bh-unseeded) FM_DESC='[handoff] REFUSAL: the home carries no secondmate marker' ;;
    bh-wrong-marker) FM_DESC='[handoff] REFUSAL: the home is marked for another secondmate' ;;
    bh-home-is-active) FM_DESC='[handoff] REFUSAL: the home is the active firstmate home' ;;
    bh-no-agents) FM_DESC='[handoff] REFUSAL: the home is missing AGENTS.md' ;;
    bh-inflight) FM_DESC='[handoff] REFUSAL: an in-flight item is never handed off' ;;
    bh-done) FM_DESC='[handoff] REFUSAL: a Done record stays with its home' ;;
    bh-missing) FM_DESC='[handoff] REFUSAL: an unmatched key moves nothing at all' ;;
    bh-badbody) FM_DESC='[handoff] REFUSAL: a non-2-space continuation line' ;;
    bh-already) FM_DESC='[handoff] an already-present key is reported, not re-moved' ;;
    bh-sub-notfile) FM_DESC='[handoff] REFUSAL: the secondmate backlog is not a regular file' ;;
    bh-move) FM_DESC='[handoff] the delegated move' ;;
    cp-help) FM_DESC='[config-push] --help prints the usage block' ;;
    cp-h) FM_DESC='[config-push] -h prints the usage block' ;;
    cp-badarg) FM_DESC='[config-push] REFUSAL: an unknown argument' ;;
    cp-nohomes) FM_DESC='[config-push] no live secondmate homes is a clean exit' ;;
    cp-no-home-field) FM_DESC='[config-push] a record with no home and no registry entry is skipped' ;;
    cp-registry-home) FM_DESC='[config-push] the registry backfills a missing home field' ;;
    cp-unsafe-home) FM_DESC='[config-push] REFUSAL: a home that is not a firstmate home' ;;
    cp-unmarked-home) FM_DESC='[config-push] REFUSAL: a home carrying no secondmate marker' ;;
    cp-valid) FM_DESC='[config-push] a valid seeded home is pushed to' ;;
    cp-dirty) FM_DESC='[config-push] a dirty secondmate home is reported and pushed to anyway' ;;
    *) FM_DESC="[?] $1" ;;
  esac
}

for label in "${CASE_LABELS[@]}"; do
  describe "$label"
  cmp_key "$label.rc" "$FM_DESC - exit code"
  cmp_key "$label.out" "$FM_DESC - reported output"
  i=0
  while :; do
    orcv "$label.file$i"
    [ "$FM_ORC" = '<no-oracle>' ] && break
    cmp_key "$label.file$i" "$FM_DESC - durable artifact $i"
    i=$((i + 1))
  done
done

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The floor is EXACT and was taken from an observed
# green run, so dropping a single case fails the run instead of quietly
# shrinking it.
MIN_ASSERTIONS=168
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the four secondmate PowerShell entrypoints hold their contract across %d assertions\n' \
  "$ASSERTIONS"
printf '# fm-secondmate-psm1.test.sh: all assertions passed\n'
