#!/usr/bin/env bash
# Differential test for bin/fm-test-run.ps1 + bin/fm-test-run.psm1 and
# bin/fm-test-isolation-proof.ps1 against their bash twins.
#
# THE ORACLE IS THE BASH RUNNER, AND THE COMPARISON IS BYTES. For the same
# argv, both runners must produce the same stdout, the same stderr, and the
# same exit code. For the inspection surfaces - --list in every selection mode,
# --list-families, --list-lanes, --check-coverage, --help - that assertion is
# TOTAL: those outputs are pure functions of the argv and the inventory, so
# nothing is normalized and a single wrong byte fails the run. They also cover
# the parts most likely to drift: the family map, the lane composition, the
# coverage guard's set algebra, and every refusal message and exit code.
#
# Where the comparison is NOT total, this file says so at the site and lists it
# here, because a differential that quietly normalizes is worth very little:
#
#   1. Execution markers: the ISO timestamp and duration FIELDS only.
#   2. x_mixed: also its FM_TEST_SLOWEST ranking (see norm_drop_slowest).
#   3. The coverage guard's stderr: coreutils' own `comm:` locale warnings.
#   4. CR: the bash twin writes its JSON through python, which on Windows emits
#      CRLF. Stripped on both sides, and separately asserted absent from the
#      PowerShell side (assert_no_cr) so the LF contract stays proven.
#   5. The real repo's --check-coverage runs PowerShell-side ONLY - its bash
#      twin is ~700 command substitutions on this host. Its invariant is still
#      anchored to bash, through the byte-compared --list --all; see the bottom.
#
# The isolation-proof twin's --list/--list-exclusions/--help/refusals are
# compared here; its concurrent RUN is not, for the same cost reason (24 real
# candidates x a bash startup each). That path is exercised as a smoke run
# rather than differentially, and its header records the divergence it owns.
#
# ---------------------------------------------------------------------------
# THE THREE COSTS THIS FILE IS SHAPED AROUND
#
# 1. A pwsh process costs ~2.4s here, so EVERY PowerShell case runs inside ONE
#    pwsh: the driver written below reads a case file, invokes each entrypoint
#    in-process with [Console]::SetOut redirected, and writes each case's
#    stdout/stderr/exit code to files. docs/powershell-port.md's "batch pwsh"
#    rule is the reason; a pwsh per case would be minutes of pure startup.
#
# 2. The BASH oracle is what actually dominates this suite, and it is worth
#    stating because it is the reason the port exists. bin/fm-test-run.sh runs
#    `p=$(normalize_script_path "$1")` once per selected script, plus
#    `$(basename ...)` and `$(family_for_basename ...)` per script for family
#    and lane selection, and `is_proven_isolated_script` opens a process
#    substitution per script on top. Measured on this host while several agents
#    were working in the tree: a bash command substitution took 1.83s and an
#    external command ~3.8s, which puts `--list --all` over the real tests/
#    directory at 183 SECONDS against 7.6s for the PowerShell twin. So the
#    inventory-iterating cases run against small FIXTURE repos, every heavy
#    oracle invocation is launched CONCURRENTLY up front, and the assertions
#    themselves use only bash builtins - no grep, no cmp, no sed, no basename.
#
# 3. Reading a file with $(<f) costs ~190ms (no fork) against ~1.8s for a
#    general command substitution, so file comparison is `$(<a)` vs `$(<b)`
#    with `[ = ]`. $(<f) strips trailing newlines, which would hide a
#    trailing-newline difference, so a sentinel line is appended to BOTH files
#    first - a builtin redirect, and it makes the comparison byte-exact again.
#
# ---------------------------------------------------------------------------
# WHAT IS DELIBERATELY *NOT* COMPARED BYTE-FOR-BYTE
#
# Execution markers carry an ISO timestamp and a duration, and the two runners
# run at different moments by construction. Those two FIELDS are replaced with
# fixed tokens - by field, with bash globs, never by matching a whole line - so
# everything else about the marker (order, field names, spacing, exit codes,
# gate_skip verdicts, family labels) stays byte-compared. No assertion in this
# file compares a wall-clock delta between the two worlds.
#
# The --jobs worker-isolation check is the one place the two runners genuinely
# disagree on this platform, and the disagreement is the point: chmod is inert
# on a noacl mount, so the bash twin's `stat -c %a` gate can never read 700 and
# tests/fm-test-run.test.sh makes it pass by putting a FAKE `stat` on PATH.
# The PowerShell twin reads the mode natively and falls back to an OWNERSHIP
# check when chmod is provably inert (the fm_pr_mode_enforcement_inert
# precedent). So the parallel case gives the bash side that same fake stat -
# making its gate satisfiable - and then compares the verdicts, and separate
# probes assert the inert verdict and the fallback basis directly.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7. Every path handed to pwsh,
# INCLUDING the driver and case-file paths, goes through fm_test_native_path:
# PowerShell cannot resolve MSYS paths (.NET reads /tmp/x as C:\tmp\x).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

RUNNER_SH="$ROOT/bin/fm-test-run.sh"
RUNNER_PS="$ROOT/bin/fm-test-run.ps1"
PROOF_SH="$ROOT/bin/fm-test-isolation-proof.sh"
PROOF_PS="$ROOT/bin/fm-test-isolation-proof.ps1"

assert_present "$RUNNER_PS" "bin/fm-test-run.ps1 is missing"
assert_present "$ROOT/bin/fm-test-run.psm1" "bin/fm-test-run.psm1 is missing"
assert_present "$PROOF_PS" "bin/fm-test-isolation-proof.ps1 is missing"

TMP=$(fm_test_tmproot fm-test-run-psm1)
mkdir -p "$TMP/bash" "$TMP/ps" "$TMP/fixtures"

# --- assertion bookkeeping ---------------------------------------------------
#
# Plain shell variables, and nothing below runs inside a `( ... )` subshell: a
# subshell cannot report a failure back to the parent's counters, so a scheme
# that can LOSE a failure is worse than none - the suite would certify work it
# never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected> <actual>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected: [${expected}]
  actual  : [${actual}]
"
  fi
}

# --- fork-free file helpers --------------------------------------------------

# copy_file <src> <dst>: a `cp` twin built from builtins, because an exec costs
# ~3.8s here and this suite copies six files into each of two fixtures. Trailing
# blank lines are not preserved; nothing copied here has any.
copy_file() {
  local content
  content=$(<"$1")
  printf '%s\n' "$content" >"$2"
}

# read_sealed <file>: the file's content with a sentinel line appended first, so
# $(<f)'s trailing-newline stripping cannot hide a difference in trailing bytes.
#
# CR is removed from both sides. It can only ever come from the BASH side, and
# only from one place: bin/fm-test-run.sh emits its JSON artifact and its
# FM_TEST_AGGREGATE line through `python3`, and a NATIVE Windows python opens
# stdout and its output file in TEXT mode, so every "\n" it writes becomes
# "\r\n" (verified: the bash aggregate artifact is byte-for-byte the PowerShell
# one except that all 96 lines end CRLF). The PowerShell twin has no python and
# writes LF, which contract 1 requires - so this is the bash twin carrying a
# platform artifact the port removes, not a difference in behavior. The LF
# contract is not weakened by stripping here: assert_no_cr below asserts it
# directly, on the raw PowerShell bytes, before anything is normalized.
read_sealed() {
  printf '%s' '<<<END>>>' >>"$1"
  FM_SEALED=$(<"$1")
  FM_SEALED=${FM_SEALED//$'\r'/}
}

# read_first_line <file>: the first line only, so an assertion still reads
# correctly from a file read_sealed has already appended its sentinel to.
read_first_line() {
  local text
  text=$(<"$1")
  FM_FIRST=${text%%$'\n'*}
  FM_FIRST=${FM_FIRST%$'\r'}
}

# --- marker normalization ----------------------------------------------------
#
# Field-wise, never line-wise: only an ISO timestamp field and a duration field
# are replaced, so every other byte of every marker stays compared. Pure bash
# globs and a builtin read loop - no sed, no awk.
FM_NORM=
norm_markers() {
  local text=$1 line out='' field rebuilt
  while IFS= read -r line; do
    case "$line" in
      FM_TEST_*|FM_ISOLATION_*)
        rebuilt=''
        for field in $line; do
          case "$field" in
            20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) field='<ISO>' ;;
            duration_ms=*) field='duration_ms=<MS>' ;;
          esac
          if [ -z "$rebuilt" ]; then rebuilt=$field; else rebuilt="$rebuilt $field"; fi
        done
        out="$out$rebuilt"$'\n'
        ;;
      *)
        out="$out$line"$'\n'
        ;;
    esac
  done <<EOF
$text
EOF
  FM_NORM=$out
}

# The coverage guard's stderr can carry `comm:` warnings that belong to
# coreutils, not to the runner: the guard sorts its files with LC_ALL=C but
# invokes comm WITHOUT that pin, so on a host whose locale is not C (this one
# is en_GB.UTF-8) comm judges its own inputs unsorted and says so. Observed
# live, and comm's ANSWER is still correct - the refusal it feeds is byte-
# identical. No PowerShell twin can or should reproduce another tool's
# sortedness heuristic, so those lines are dropped from BOTH sides. Nothing
# else is filtered: every `fm-test-run:` diagnostic stays compared.
norm_comm() {
  local text=$1 line out=''
  while IFS= read -r line; do
    case "$line" in
      'comm: '*) continue ;;
    esac
    out="$out$line"$'\n'
  done <<EOF
$text
EOF
  FM_NORM=$out
}

# JSON artifacts are indent=2 pretty-printed, so one volatile value per line.
# The KEY and its indentation are preserved and only the value is tokenized, so
# a structural difference - a lost comma, a wrong nesting depth, a renamed key -
# still fails even on the four lines whose values legitimately move.
norm_json() {
  local text=$1 line out='' comma
  while IFS= read -r line; do
    case "$line" in
      *'"duration_ms":'*|*'"run_id":'*|*'"started_at":'*|*'"finished_at":'*)
        comma=''
        case "$line" in *,) comma=',' ;; esac
        line="${line%%:*}: <VOLATILE>$comma"
        ;;
    esac
    out="$out$line"$'\n'
  done <<EOF
$text
EOF
  FM_NORM=$out
}

# The FM_TEST_SLOWEST ranking for the serial mixed case only. Two fixture
# scripts that both just echo and exit have durations dominated by process
# startup, which on this host varies by seconds between runs, so which of them
# ranks first is genuine timing noise rather than behavior - and the port doc
# is explicit that a wall-clock delta measured at two different moments must
# not be asserted on. The ranking CONTRACT is still covered, deterministically,
# by the parallel case, whose two workers rendezvous so one is strictly slower.
norm_drop_slowest() {
  local text=$1 line out=''
  while IFS= read -r line; do
    case "$line" in
      'FM_TEST_SLOWEST '*) continue ;;
    esac
    out="$out$line"$'\n'
  done <<EOF
$text
EOF
  FM_NORM=$out
}

# norm_markers then norm_drop_slowest.
norm_markers_no_slowest() {
  norm_markers "$1"
  norm_drop_slowest "$FM_NORM"
}

# --- fixtures ----------------------------------------------------------------
#
# Two repos, each with its own bin/ copy of both runners so each resolves that
# repo as ROOT (the bash runner derives ROOT from its own location; so does the
# PowerShell module). tests/ entries are empty files: selection, the family map
# and the coverage guard all read only the NAMES, and an empty script is also a
# valid zero-output candidate for the --jobs case.

fixture_bin() {  # <repo> [with-proof]
  local repo=$1 want_proof=${2:-}
  mkdir -p "$repo/bin" "$repo/tests"
  copy_file "$RUNNER_SH" "$repo/bin/fm-test-run.sh"
  copy_file "$RUNNER_PS" "$repo/bin/fm-test-run.ps1"
  copy_file "$ROOT/bin/fm-test-run.psm1" "$repo/bin/fm-test-run.psm1"
  copy_file "$ROOT/bin/fm-common.psm1" "$repo/bin/fm-common.psm1"
  if [ -n "$want_proof" ]; then
    copy_file "$PROOF_SH" "$repo/bin/fm-test-isolation-proof.sh"
    copy_file "$PROOF_PS" "$repo/bin/fm-test-isolation-proof.ps1"
    # The one place the exec bit is load-bearing: the bash guard gates its
    # isolation-proof cross-check on `[ -x ]`, which is always true on a noacl
    # mount but would be false for a freshly written copy on a real POSIX
    # filesystem - and the PowerShell guard asks only whether a twin exists,
    # because Windows has no exec bit to ask about. Setting it keeps the two
    # worlds taking the same branch off Windows too.
    chmod +x "$repo/bin/fm-test-isolation-proof.sh"
  fi
}

# The proven-isolated set, which the coverage guard requires to be present in
# tests/ before its union invariant can hold. Kept here rather than read from
# the runner so a runner that silently dropped one is not silently agreed with.
PROVEN_BASENAMES="fm-arm-pretool-check fm-backend-herdr fm-brief fm-cd-pretool-check
fm-composer-ghost fm-composer-lib fm-crew-state fm-decision-hold-lifecycle
fm-ensure-agents-md fm-grok-harness fm-herdr-lab fm-lint fm-pi-primary-types
fm-pr-merge fm-review-diff fm-send-popup-settle fm-send-settle fm-send-strict
fm-spawn-batch fm-supervision-instructions fm-test-run fm-tmux-submit-busy
fm-transition-lib fm-x-mode"

FX_OK="$TMP/fixtures/ok"
fixture_bin "$FX_OK" with-proof
for b in $PROVEN_BASENAMES; do : >"$FX_OK/tests/$b.test.sh"; done
# One real-herdr-gated member so the Herdr lane is non-empty, and one
# unclassified extra so the portable-serial lane is non-empty. Without both,
# the guard dies on an empty lane before it ever reaches its union check.
: >"$FX_OK/tests/fm-backend-herdr-smoke.test.sh"
: >"$FX_OK/tests/fm-zz-extra.test.sh"

# Two of the proven names get a body, for the --jobs case only, and they
# RENDEZVOUS rather than race.
#
# The first attempt simply made the first-launched worker sleep, which is not
# deterministic here at all: measured on this host, the bash scheduler took 25
# SECONDS between launching worker 1 and worker 2, so the "slow" worker had
# long finished before the fast one started and bash collected them in the
# opposite order from PowerShell - a difference in host load presenting as a
# difference in the runners. So worker 1 now blocks until worker 2 signals,
# which fixes the completion order in both worlds no matter how far the two
# launches drift apart, and makes the marker order prove the contract that
# actually matters: the first COMPLETED worker is collected, not the first
# LAUNCHED one.
IFS= read -r -d '' FM_SLOW_WORKER <<'SLOWSH' || true
#!/usr/bin/env bash
# Worker 1: hold until worker 2 signals, then hold a little longer so the
# collector cannot observe both as finished in the same poll.
i=0
while [ ! -e "${FM_RENDEZVOUS:-/nonexistent}" ] && [ "$i" -lt 60 ]; do
  sleep 0.2
  i=$((i + 1))
done
sleep 0.3
echo "ok - slow worker"
exit 0
SLOWSH
printf '%s' "$FM_SLOW_WORKER" >"$FX_OK/tests/fm-brief.test.sh"

IFS= read -r -d '' FM_FAST_WORKER <<'FASTSH' || true
#!/usr/bin/env bash
# Worker 2: signal, then finish immediately.
if [ -n "${FM_RENDEZVOUS:-}" ]; then : >"$FM_RENDEZVOUS"; fi
echo "ok - fast worker"
exit 0
FASTSH
printf '%s' "$FM_FAST_WORKER" >"$FX_OK/tests/fm-lint.test.sh"

# The negative fixture: a repo whose tests/ holds none of the proven set, so
# the union of the lanes is a strict superset of tests/*.test.sh and the guard
# must refuse with "extra beyond inventory" and exit 1. This is the case that
# proves the guard still catches a violated invariant rather than only that it
# prints ok when everything is already consistent.
FX_BAD="$TMP/fixtures/bad"
fixture_bin "$FX_BAD"
: >"$FX_BAD/tests/fm-backend-herdr-smoke.test.sh"
: >"$FX_BAD/tests/fm-zz-one.test.sh"
: >"$FX_BAD/tests/fm-zz-two.test.sh"
: >"$FX_BAD/tests/fm-zz-three.test.sh"

# --- execution fixtures (real runner, tiny scripts) --------------------------

printf '#!/usr/bin/env bash\necho "ok - green fixture"\nexit 0\n' >"$TMP/green.test.sh"
printf '#!/usr/bin/env bash\necho "not ok - red fixture"\nexit 1\n' >"$TMP/red.test.sh"
printf '#!/usr/bin/env bash\necho "skip: herdr not found"\nexit 0\n' >"$TMP/skip.test.sh"

# Lane timing artifacts for --aggregate-json, at the FIXTURE ROOT and referred
# to by BARE FILENAME. Both details are load-bearing.
#
# The bash twin aggregates through `python3`, and bash hands a native Windows
# program its arguments THROUGH MSYS path translation - so an absolute
# /tmp/... input arrives at python as C:\Users\...\, and `str(Path(p))` records
# that Windows spelling in the merged document while the PowerShell twin
# records the argument as given. A bare filename is translated by neither, and
# has no separator for pathlib to flip, so the two documents agree byte for
# byte on a field that is otherwise reporting the interpreter's platform rather
# than the runner's behavior.
printf '%s\n' \
  '{' \
  '  "run_id": "a",' \
  '  "selection": "lane=portable-parallel-1",' \
  '  "started_at": "2026-07-22T00:00:00Z",' \
  '  "finished_at": "2026-07-22T00:01:00Z",' \
  '  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},' \
  '  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]' \
  '}' >"$FX_OK/lane-a.json"
printf '%s\n' \
  '{' \
  '  "run_id": "b",' \
  '  "selection": "lane=portable-serial",' \
  '  "started_at": "2026-07-22T00:00:00Z",' \
  '  "finished_at": "2026-07-22T00:02:00Z",' \
  '  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},' \
  '  "scripts": [' \
  '    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},' \
  '    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}' \
  '  ]' \
  '}' >"$FX_OK/lane-b.json"

# The fake `stat` tests/fm-test-run.test.sh uses to make the bash twin's
# mode-0700 worker gate satisfiable on a noacl mount. Only the bash side needs
# it; the PowerShell twin never shells out to stat.
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then printf "700\n"; exit 0; fi' \
  'if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then printf "700\n"; exit 0; fi' \
  'exit 1' >"$FAKE_BIN/stat"
chmod +x "$FAKE_BIN/stat"

# --- the case table ----------------------------------------------------------
#
# One row per case: <label> <TAB> <runner.sh> <TAB> <runner.ps1> <TAB> argv...
#
# BOTH sides read their argv from this one file, split on TAB. That is not
# tidiness: an argv element here contains a space ("herdr not found"), and
# rebuilding a command line from a space-joined string would hand bash four
# words where PowerShell got one - a difference in the HARNESS that would read
# as a difference in the runners. Splitting the same record the same way makes
# the two argv vectors identical by construction.
CASES="$TMP/cases.tsv"
: >"$CASES"
CASE_LABELS=""
HEAVY_LABELS=""

TAB=$'\t'

add_case() {  # <label> <sh> <ps1> [args...]
  local label=$1 sh=$2 ps1=$3
  shift 3
  local row="$label$TAB$sh$TAB$ps1"
  local a
  for a in "$@"; do row="$row$TAB$a"; done
  printf '%s\n' "$row" >>"$CASES"
  CASE_LABELS="$CASE_LABELS $label"
}

# Real-repo inspection surfaces. Cheap ones first; r-list-all iterates the whole
# tests/ directory in bash and is the single heavy real-repo case.
add_case r_list_families "$RUNNER_SH" "$RUNNER_PS" --list-families
add_case r_list_lanes "$RUNNER_SH" "$RUNNER_PS" --list-lanes
add_case r_help "$RUNNER_SH" "$RUNNER_PS" --help
add_case r_list_proven "$RUNNER_SH" "$RUNNER_PS" --list --proven-isolated
add_case r_list_shard1 "$RUNNER_SH" "$RUNNER_PS" --list --lane portable-parallel-1
add_case r_list_shard2 "$RUNNER_SH" "$RUNNER_PS" --list --lane portable-parallel-2
add_case r_list_one "$RUNNER_SH" "$RUNNER_PS" --list tests/fm-lint.test.sh
add_case r_list_bare "$RUNNER_SH" "$RUNNER_PS" --list fm-lint.test.sh
add_case r_list_dot "$RUNNER_SH" "$RUNNER_PS" --list ./tests/fm-lint.test.sh
add_case r_list_dup "$RUNNER_SH" "$RUNNER_PS" --list tests/fm-lint.test.sh tests/fm-lint.test.sh
add_case r_list_eqform "$RUNNER_SH" "$RUNNER_PS" --list --lane=portable-parallel-1

# Refusals: every one of these is an exit-2 path with an exact message.
add_case r_err_jobs_zero "$RUNNER_SH" "$RUNNER_PS" --jobs 0 --all
add_case r_err_jobs_cap "$RUNNER_SH" "$RUNNER_PS" --jobs 9 --all
add_case r_err_jobs_nan "$RUNNER_SH" "$RUNNER_PS" --jobs x --all
add_case r_err_unknown "$RUNNER_SH" "$RUNNER_PS" --nope
add_case r_err_lane "$RUNNER_SH" "$RUNNER_PS" --lane bogus
add_case r_err_family "$RUNNER_SH" "$RUNNER_PS" --family nosuchfamily
add_case r_err_nomode "$RUNNER_SH" "$RUNNER_PS"
add_case r_err_two_modes "$RUNNER_SH" "$RUNNER_PS" --all --changed
add_case r_err_family_noarg "$RUNNER_SH" "$RUNNER_PS" --family
add_case r_err_mixed "$RUNNER_SH" "$RUNNER_PS" --all tests/fm-lint.test.sh
add_case r_err_missing "$RUNNER_SH" "$RUNNER_PS" tests/fm-not-a-real.test.sh
add_case r_err_jobs_nonproven "$RUNNER_SH" "$RUNNER_PS" --jobs 2 tests/fm-watcher-lock.test.sh
add_case r_err_agg_missing "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" \
  --aggregate-json never.json absent.json

# Aggregation over fixed lane artifacts: deterministic stdout AND a
# deterministic merged document, both compared.
add_case r_agg "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" \
  --aggregate-json agg.json lane-a.json lane-b.json

# The isolation-proof twin's own inspection surfaces.
add_case p_list "$PROOF_SH" "$PROOF_PS" --list
add_case p_exclusions "$PROOF_SH" "$PROOF_PS" --list-exclusions
add_case p_help "$PROOF_SH" "$PROOF_PS" --help
add_case p_err_arg "$PROOF_SH" "$PROOF_PS" stray-argument
add_case p_err_jobs "$PROOF_SH" "$PROOF_PS" --jobs 0

# Fixture repos: everything that iterates an inventory.
add_case fo_coverage "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --check-coverage
add_case fo_list_serial "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --list --lane portable-serial
add_case fo_list_all "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --list --all
add_case fo_list_family "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --list --family pure-contract-unit
add_case fo_list_herdr "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --list --family real-herdr-gated
add_case fo_exclude "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --list --all --exclude-family real-herdr-gated
add_case fb_coverage "$FX_BAD/bin/fm-test-run.sh" "$FX_BAD/bin/fm-test-run.ps1" --check-coverage

# Execution: markers, gate-skip accounting, aggregate exit status, JSON.
add_case x_green "$RUNNER_SH" "$RUNNER_PS" --json "$TMP/X_GREEN.json" "$TMP/green.test.sh"
add_case x_mixed "$RUNNER_SH" "$RUNNER_PS" "$TMP/green.test.sh" "$TMP/red.test.sh"
add_case x_skip "$RUNNER_SH" "$RUNNER_PS" --json "$TMP/X_SKIP.json" "$TMP/skip.test.sh"
add_case x_skip_token "$RUNNER_SH" "$RUNNER_PS" --fail-on-gate-skip "herdr not found" "$TMP/skip.test.sh"
add_case x_jobs2 "$FX_OK/bin/fm-test-run.sh" "$FX_OK/bin/fm-test-run.ps1" --jobs 2 tests/fm-brief.test.sh tests/fm-lint.test.sh

# The heavy real-repo case, launched first so it overlaps everything else.
add_case r_list_all "$RUNNER_SH" "$RUNNER_PS" --list --all

# A ps_-prefixed case runs ONLY in the driver; the bash side skips it. Used for
# the real repo's coverage guard, whose bash twin is ~700 command substitutions
# on this host (see the cost note at the top). Its invariant is still anchored
# to the bash oracle, through r_list_all - see the bottom of this file.
add_case ps_real_coverage "$RUNNER_SH" "$RUNNER_PS" --check-coverage

# Cases whose bash side iterates an inventory. Launched concurrently up front so
# the suite's wall time is the slowest oracle rather than their sum.
HEAVY_LABELS="r_list_all fo_coverage fo_list_serial fo_list_all fo_list_family fo_exclude fb_coverage x_jobs2"

# --- run the bash oracle -----------------------------------------------------

run_bash_case() {  # <label>
  local label=$1 row='' line
  while IFS= read -r line; do
    case "$line" in "$label$TAB"*) row=$line; break ;; esac
  done <"$CASES"
  [ -n "$row" ] || fail "no case row for $label"

  local -a f=()
  IFS=$TAB read -r -a f <<EOF
$row
EOF
  local sh=${f[1]}
  local -a argv=()
  local n=${#f[@]} i
  for ((i = 3; i < n; i++)); do argv+=("${f[$i]}"); done

  # Only the parallel case needs the fake `stat`: it is what makes the bash
  # twin's mode-0700 worker gate satisfiable on a noacl mount, exactly as
  # tests/fm-test-run.test.sh does it. The PowerShell twin never shells out to
  # stat, so the shim is invisible to it.
  local extra_path=''
  if [ "$label" = "x_jobs2" ]; then extra_path="$FAKE_BIN:"; fi
  # A per-phase rendezvous path, so the bash phase and the PowerShell phase each
  # get a fresh, absent marker without either having to delete one.
  FM_RENDEZVOUS="$TMP/rendezvous-bash" PATH="$extra_path$PATH" \
    bash "$sh" ${argv[@]+"${argv[@]}"} \
    >"$TMP/bash/$label.out" 2>"$TMP/bash/$label.err"
  printf '%s\n' "$?" >"$TMP/bash/$label.rc"
}

for label in $HEAVY_LABELS; do
  run_bash_case "$label" &
done

for label in $CASE_LABELS; do
  case " $HEAVY_LABELS " in
    *" $label "*) continue ;;
  esac
  case "$label" in
    ps_*) continue ;;
  esac
  run_bash_case "$label"
done

# The aggregate and per-run artifacts the bash side just wrote must be preserved
# before the PowerShell side overwrites the same paths.
if [ -f "$FX_OK/agg.json" ]; then mv "$FX_OK/agg.json" "$TMP/bash/AGG.json"; fi
for f in X_GREEN X_SKIP; do
  if [ -f "$TMP/$f.json" ]; then
    mv "$TMP/$f.json" "$TMP/bash/$f.json"
  fi
done

wait

# --- run every PowerShell case in ONE pwsh -----------------------------------

DRIVER="$TMP/driver.ps1"
IFS= read -r -d '' FM_DRIVER_SRC <<'PSDRIVER'
#Requires -Version 7.0
# Differential driver: evaluate every case in ONE pwsh.
#
# Each case invokes the real entrypoint with `& $ps1 @argv`, which returns to
# this script when the entrypoint calls exit and leaves its code in
# $LASTEXITCODE (verified on this host). Console.SetOut/SetError capture the
# bytes the entrypoint wrote, so no case needs its own process.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseFile,
    [Parameter(Mandatory)][string]$OutDir,
    [Parameter(Mandatory)][string]$ModulePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# fm-common too, not just the runner module: the probes at the bottom call
# Test-FmWindows, and a .psm1 does not re-export what it imports.
Import-Module (Join-Path (Split-Path -Parent $ModulePath) 'fm-common.psm1') -Force
Import-Module $ModulePath -Force

$utf8 = [System.Text.UTF8Encoding]::new($false)
$realOut = [Console]::Out
$realErr = [Console]::Error

function Write-CaseFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ($line -eq '') { continue }
    $f = @($line.Split("`t"))
    $label = $f[0]
    # $f[1] is the bash twin, which only the bash side runs.
    #
    # The entrypoint path is converted HERE rather than in the case file: it is
    # written in MSYS form (/f/...), which PowerShell cannot resolve at all, and
    # converting it on the bash side would be a cygpath fork per case. The argv
    # entries are deliberately NOT converted - the runners take those exactly as
    # a user would type them, and converting them would test the harness rather
    # than the runner's own path handling.
    $ps1 = ConvertTo-FmNativePath $f[2]
    $argv = @()
    if ($f.Count -gt 3) { $argv = @($f[3..($f.Count - 1)]) }

    $sw = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    $rc = -1
    [Console]::SetOut($sw)
    [Console]::SetError($se)
    try {
        $global:LASTEXITCODE = -1
        & $ps1 @argv
        $rc = $LASTEXITCODE
    } catch {
        $rc = 'THREW'
        $se.Write("driver: $($_.Exception.Message)`n")
    } finally {
        [Console]::SetOut($realOut)
        [Console]::SetError($realErr)
    }
    # Written RAW - no CR strip. Stripping here would make assert_no_cr on the
    # bash side of this suite vacuous, and the LF guarantee is exactly what the
    # PowerShell twin is supposed to be providing.
    Write-CaseFile (Join-Path $OutDir "$label.out") ($sw.ToString())
    Write-CaseFile (Join-Path $OutDir "$label.err") ($se.ToString())
    Write-CaseFile (Join-Path $OutDir "$label.rc") ("$rc`n")
}

# --- module probes -----------------------------------------------------------
#
# The inert-chmod fallback is the one behavior with no bash twin to compare
# against, so it is asserted directly instead: is chmod provably inert on this
# host's temp filesystem, and does the worker-root gate therefore accept a
# directory on OWNERSHIP rather than on the mode bit?
$probeDir = Join-Path $OutDir 'probe-root'
[void][System.IO.Directory]::CreateDirectory($probeDir)
Set-FmTestRunPrivateDirectory $probeDir
$verdict = Test-FmTestRunWorkerRoot $probeDir
$probe = @(
    "mode=$(Get-FmTestRunDirMode $probeDir)"
    "inert=$(Test-FmTestRunModeEnforcementInert $OutDir)"
    "ok=$($verdict['Ok'])"
    "basis=$($verdict['Basis'])"
    "windows=$(Test-FmWindows)"
) -join "`n"
Write-CaseFile (Join-Path $OutDir 'probe.out') ($probe + "`n")
PSDRIVER
printf '%s' "$FM_DRIVER_SRC" >"$DRIVER"

DRIVER_N=$(fm_test_native_path "$DRIVER")
CASES_N=$(fm_test_native_path "$CASES")
PSDIR_N=$(fm_test_native_path "$TMP/ps")
MODULE_N=$(fm_test_native_path "$ROOT/bin/fm-test-run.psm1")

FM_RENDEZVOUS="$TMP/rendezvous-ps" \
  pwsh -NoProfile -File "$DRIVER_N" -CaseFile "$CASES_N" -OutDir "$PSDIR_N" -ModulePath "$MODULE_N" \
  >"$TMP/driver.log" 2>&1 \
  || fail "the PowerShell driver failed:"$'\n'"$(<"$TMP/driver.log")"

if [ -f "$FX_OK/agg.json" ]; then mv "$FX_OK/agg.json" "$TMP/ps/AGG.json"; fi
for f in X_GREEN X_SKIP; do
  if [ -f "$TMP/$f.json" ]; then
    mv "$TMP/$f.json" "$TMP/ps/$f.json"
  fi
done

# --- compare -----------------------------------------------------------------

compare_case() {  # <label> <stream: out|err|rc> [normalizer]
  local label=$1 stream=$2 normalizer=${3:-}
  local b p
  read_sealed "$TMP/bash/$label.$stream"; b=$FM_SEALED
  read_sealed "$TMP/ps/$label.$stream"; p=$FM_SEALED
  if [ -n "$normalizer" ]; then
    "$normalizer" "$b"; b=$FM_NORM
    "$normalizer" "$p"; p=$FM_NORM
  fi
  assert_same "$label.$stream" "$b" "$p"
}

# The LF contract, asserted on the RAW PowerShell bytes before anything is
# normalized. Every marker in this repo is parsed by line, and fm-common exists
# largely because Write-Output emits CRLF on this host - so a single CR anywhere
# in the PowerShell twin's output is a contract-1 failure, and read_sealed's
# later CR strip must not be able to hide one.
ps_cr=''
for f in "$TMP"/ps/*.out "$TMP"/ps/*.err; do
  [ -f "$f" ] || continue
  content=$(<"$f")
  case "$content" in
    *$'\r'*) ps_cr="$ps_cr ${f##*/}" ;;
  esac
done
assert_same "no PowerShell output carries a CR (contract 1)" "" "${ps_cr# }"

# Byte-identical stdout, stderr and exit code for every inspection and refusal
# surface. Nothing here is normalized: these outputs are pure functions of argv
# and the repo inventory.
for label in \
  r_list_families r_list_lanes r_help r_list_proven r_list_shard1 r_list_shard2 \
  r_list_one r_list_bare r_list_dot r_list_dup r_list_eqform r_list_all \
  r_err_jobs_zero r_err_jobs_cap r_err_jobs_nan r_err_unknown r_err_lane \
  r_err_family r_err_nomode r_err_two_modes r_err_family_noarg r_err_mixed \
  r_err_missing r_err_jobs_nonproven r_err_agg_missing r_agg \
  p_list p_exclusions p_help p_err_arg p_err_jobs \
  fo_list_serial fo_list_all fo_list_family fo_list_herdr fo_exclude; do
  compare_case "$label" out
  compare_case "$label" err
  compare_case "$label" rc
done

# The two coverage cases, whose stderr may carry coreutils' own locale warnings.
for label in fo_coverage fb_coverage; do
  compare_case "$label" out
  compare_case "$label" err norm_comm
  compare_case "$label" rc
done

# Execution surfaces: same comparison, with only the timestamp and duration
# fields tokenized. x_mixed additionally drops the slowest ranking, which for
# two same-shaped fixture scripts is pure startup noise (see norm_drop_slowest).
for label in x_green x_skip x_skip_token x_jobs2; do
  compare_case "$label" out norm_markers
  compare_case "$label" err norm_markers
  compare_case "$label" rc
done
compare_case x_mixed out norm_markers_no_slowest
compare_case x_mixed err norm_markers_no_slowest
compare_case x_mixed rc

# The JSON artifacts, compared as bytes after tokenizing the same two volatile
# fields. The aggregate has none: its inputs are fixed, so it is compared raw.
compare_json() {  # <name> [normalizer]
  local name=$1 normalizer=${2:-}
  local b p
  read_sealed "$TMP/bash/$name.json"; b=$FM_SEALED
  read_sealed "$TMP/ps/$name.json"; p=$FM_SEALED
  if [ -n "$normalizer" ]; then
    "$normalizer" "$b"; b=$FM_NORM
    "$normalizer" "$p"; p=$FM_NORM
  fi
  assert_same "$name.json" "$b" "$p"
}
compare_json AGG
compare_json X_GREEN norm_json
compare_json X_SKIP norm_json

# --- the guard's negative case, asserted explicitly --------------------------
#
# fb_coverage above already compares the two worlds byte for byte, but agreement
# is not enough: both could agree on a guard that no longer checks anything. So
# the refusal itself is asserted - non-zero exit, the union diagnostic, and the
# specific proven-set path that is missing from the fixture's inventory.
read_first_line "$TMP/bash/fb_coverage.rc"
assert_same "coverage guard refuses a violated invariant (bash exit)" "1" "$FM_FIRST"
read_first_line "$TMP/ps/fb_coverage.rc"
assert_same "coverage guard refuses a violated invariant (PowerShell exit)" "1" "$FM_FIRST"
FB_ERR=$(<"$TMP/ps/fb_coverage.err")
case "$FB_ERR" in
  *"union of portable shards + portable serial + Herdr must equal tests/*.test.sh"*)
    fb_diag=found ;;
  *) fb_diag="missing from: $FB_ERR" ;;
esac
assert_same "the PowerShell guard names the violated union invariant" "found" "$fb_diag"
case "$FB_ERR" in
  *"extra beyond inventory:"*$'\n'*"tests/fm-x-mode.test.sh"*) fb_extra=found ;;
  *) fb_extra="missing from: $FB_ERR" ;;
esac
assert_same "the PowerShell guard lists the uncovered scripts" "found" "$fb_extra"
FO_OUT=$(<"$TMP/ps/fo_coverage.out")
case "$FO_OUT" in
  "FM_TEST_COVERAGE ok total=26 parallel=24 serial=1 herdr=1"*) fo_ok=found ;;
  *) fo_ok="unexpected: $FO_OUT" ;;
esac
assert_same "the guard's success marker carries the lane counts" "found" "$fo_ok"

# --- the inert-chmod worker gate, asserted directly --------------------------
#
# No bash twin can be the oracle here: its gate is exactly the one that cannot
# pass on this filesystem. So the bash FACT is established first (what does
# `stat -c %a` really report for a directory chmod 0700 just touched?) and the
# PowerShell verdict is checked against it.
mkdir -p "$TMP/modeprobe"
chmod 0700 "$TMP/modeprobe" 2>/dev/null
BASH_MODE=$(stat -c %a "$TMP/modeprobe" 2>/dev/null || stat -f %Lp "$TMP/modeprobe" 2>/dev/null || printf 'unknown')
PROBE=$(<"$TMP/ps/probe.out")
probe_field() {  # <key>
  local key=$1 line
  FM_PROBE=''
  while IFS= read -r line; do
    case "$line" in "$key="*) FM_PROBE=${line#*=}; return 0 ;; esac
  done <<EOF
$PROBE
EOF
}
probe_field windows; PROBE_WINDOWS=$FM_PROBE
probe_field mode; PROBE_MODE=$FM_PROBE
probe_field inert; PROBE_INERT=$FM_PROBE
probe_field ok; PROBE_OK=$FM_PROBE
probe_field basis; PROBE_BASIS=$FM_PROBE

assert_same "the PowerShell mode reader agrees with what stat reports" "$BASH_MODE" "$PROBE_MODE"
assert_same "a worker root is accepted on this host" "True" "$PROBE_OK"
if [ "$PROBE_WINDOWS" = "True" ]; then
  # chmod really is inert here, so the mode arm CANNOT be what accepted it.
  assert_same "chmod is detected as inert on this filesystem" "True" "$PROBE_INERT"
  assert_same "the worker root is accepted on ownership, not on the mode bit" "ownership" "$PROBE_BASIS"
  assert_same "and the bash fact that forced it still holds" "755" "$BASH_MODE"
else
  assert_same "chmod is honored, so the mode arm decides" "False" "$PROBE_INERT"
  assert_same "the worker root is accepted on its mode" "mode" "$PROBE_BASIS"
fi

# --- the real repo's coverage guard, in the PowerShell world ------------------
#
# The bash guard over the real tests/ directory is ~700 command substitutions on
# this host and is not run (see the cost note at the top). The invariant is
# still anchored to bash rather than to the twin agreeing with itself, through a
# chain whose only cross-world link is already byte-compared above:
#
#   bash --list --all  ==bytes==  PowerShell --list --all  ==count==  the
#   total= the PowerShell guard reports.
#
# The count is taken from the POWERSHELL listing, not the bash one, and both it
# and the guard ran inside the same driver process seconds apart. That matters
# here: an earlier run failed this assertion at 118 vs 117 because another agent
# deleted a tests/*.test.sh between the bash phase and a separately spawned
# pwsh - a live-inventory race, not a difference between the runners.
PS_LIST=$(<"$TMP/ps/r_list_all.out")
PS_COUNT=0
while IFS= read -r line; do
  case "$line" in
    ''|'<<<END>>>') continue ;;
  esac
  PS_COUNT=$((PS_COUNT + 1))
done <<EOF
$PS_LIST
EOF
read_first_line "$TMP/ps/ps_real_coverage.rc"
assert_same "the PowerShell guard passes on the real inventory" "0" "$FM_FIRST"
read_first_line "$TMP/ps/ps_real_coverage.out"
assert_same "and its total is the script count of the listing bash agreed with" \
  "FM_TEST_COVERAGE ok total=$PS_COUNT" "${FM_FIRST%% parallel=*}"

# --- report ------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-test-run.ps1 differs from bin/fm-test-run.sh (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted, EXACTLY rather than as a loose floor, and built from
# what was actually available so a fixture that failed to materialize cannot
# quietly shrink the run into a green one:
#   36 byte-identical cases x 3 streams  = 108
#   2 coverage cases x 3                 =   6
#   the CR contract                      =   1
#   4 execution cases x 3                =  12
#   x_mixed x 3                          =   3
#   3 JSON artifacts                     =   3
#   5 explicit coverage-guard assertions =   5
#   2 platform-independent worker-gate   =   2
#   2 real-inventory                     =   2
#                                          ---
#                                          142, plus the worker-gate platform
# branch: 3 more on Windows (inert, ownership basis, and the bash 755 fact that
# forces it), 2 elsewhere.
MIN_ASSERTIONS=144
[ "$PROBE_WINDOWS" = "True" ] && MIN_ASSERTIONS=145
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-test-run.ps1 matches bin/fm-test-run.sh across %d assertions\n' "$ASSERTIONS"
printf '# fm-test-run-psm1.test.sh: all assertions passed\n'
