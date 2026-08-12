#!/usr/bin/env bash
# Behavior test for the W3-herdr PowerShell twin:
#
#   bin/backends/herdr.psm1  <- bin/backends/herdr.sh   (the herdr adapter)
#
# This is a DIFFERENTIAL test: every case drives the bash function and the
# PowerShell function with byte-identical input and asserts byte-identical
# output. BASH IS THE ORACLE - no expectation is hard-coded, so a case can never
# quietly encode what the author believed instead of what the shipped code does.
#
# WHY THIS FILE IS WORTH ITS LENGTH. bin/backends/herdr.sh is the largest and
# most dangerous file in the repo, and its comments record incidents that
# destroyed real work. Four of the verdicts compared here decide whether
# firstmate recovers a crew, ignores one, or destroys one:
#
#   - Get-FmBackendHerdrAgentState's missing/dead/unreadable split is
#     RECOVERY-GRADE. Only `dead` and `missing` license a relaunch, so a twin
#     that answered `missing` where bash answers `unreadable` would license a
#     duplicate spawn against a worker that is still running.
#   - Remove-FmBackendHerdrSeededDefaultTab is the 2026-07-02 self-kill fix. A
#     twin that pruned on a label heuristic instead of the create-response tab id
#     would close a captain's live pane, which is exactly what happened once.
#   - Get-FmBackendHerdrComposerState's `empty` verdict is what away-mode
#     injection reads as "safe to type into". A twin that answered `empty` where
#     bash answers `unknown` would type an escalation into a dead login shell.
#   - Get-FmBackendHerdrPresentationSessionLockPath decides WHICH lock file a
#     process takes. A twin that hashed differently would let a bash watcher and
#     a PowerShell watcher both believe they hold the same session lock.
#
# ---------------------------------------------------------------------------
# TRANSPORT, and the traps this pattern has already sprung in this repo.
#
# All cases are written to a FILE and evaluated by ONE pwsh driver, which returns
# one result per record. Fields are separated by 0x01 and records by 0x02 - two
# bytes that appear in no fixture - so every value crosses the boundary as RAW
# BYTES: an ESC, a TAB, an embedded newline and a multibyte glyph all arrive
# unencoded, and the comparison is byte-exact by construction.
#
#   1. PER-CASE ENVIRONMENT DOES NOT SURVIVE THE BATCH. A bash prefix assignment
#      persists in the shell after a FUNCTION call, so by the time the single
#      pwsh runs it holds only the LAST value assigned. Every case that depends
#      on the environment carries its own settings in the RECORD, and the driver
#      applies and clears them per case.
#   2. NEVER KEY A PROBE BY A PATH. The two worlds spell the same location
#      differently, so a key containing one never matches. Every case is keyed by
#      INDEX, and the few values that legitimately contain a path are normalized
#      through norm_paths on BOTH sides.
#   3. NO `( ... )` SUBSHELLS. A failure recorded inside one cannot reach the
#      parent's counters, so it would vanish into a FALSE PASS. Everything below
#      runs in parent scope.
#   4. WRAP `.Split()` AND FUNCTION-RETURNED COLLECTIONS IN `@( ... )`.
#      PowerShell unrolls a single-element array into a bare string.
#
# ---------------------------------------------------------------------------
# THE FAKE herdr, AND WHY THERE ARE TWO OF THEM.
#
# Phase B drives both worlds through a fake `herdr` on PATH with NUMBERED
# response fixtures, the convention bin/backends/herdr.sh's own suite already
# uses. It cannot be ONE file: .NET's Process.Start does not search PATH for a
# bare name and cannot start an extension-less shebang script at all, while a
# `.cmd` trampoline into Git Bash mangles the arguments. So the fakebin holds:
#
#     fakebin/herdr       a bash script  - what `command -v herdr` finds
#     fakebin/herdr.cmd   a batch script - what Get-Command -CommandType
#                                          Application resolves first, by PATHEXT
#
# The two are kept honest three ways rather than by review: they SHARE every
# response fixture (so no response content is written twice), they both APPEND
# THEIR ARGV to a per-world log and the two logs are compared as a first-class
# assertion, and any divergence in the dispatch rule shows up as a verdict
# mismatch. The batch fake writes CRLF (cmd `echo` has no other mode), so the log
# comparison strips CR; fixture CONTENT is emitted with `type`/`cat`, which are
# byte-exact.
#
# Phase B arguments avoid cmd metacharacters (& | < > ^ % " and non-ASCII), which
# the batch fake could not carry. Every Unicode-bearing rule - the presentation
# label grammar, the Pi separator row, the composer border glyphs - is therefore
# exercised in Phase A, where no child process is involved on either side.
#
# ---------------------------------------------------------------------------
# COST, stated because it decides how this file is shaped. Measured on the
# reference host under load: a bash fork is ~3s and a child process started from
# pwsh is ~1.8s. So Phase A - the bulk of the assertions - drives FORK-FREE bash
# functions, captures the oracle through a redirect plus the `read` builtin
# rather than `$( ... )`, and never spawns anything. Phase B is a BOUNDED set of
# scenarios rather than a case per shape, and `pwsh` is spawned a small constant
# number of times, never once per case.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT COVERED HERE, and why - so nobody reads a green run as more than
# it is:
#   - REAL herdr lifecycle. tests/fm-backend-herdr-smoke.test.sh and the eight
#     *-e2e suites remain the real-server authority, through the guarded
#     bin/fm-herdr-lab.sh named-lab path. Nothing in this file talks to a real
#     herdr server or to the captain's default session.
#   - The named-pipe event transport end to end. Its wire behavior was verified
#     live against an isolated lab session (see the module header); what IS
#     compared here is the reader-override arm, whose contract the bash twin
#     shares byte-for-byte, plus the return-code trichotomy.
#   - The pane-death close path's signals. Its `ps -o comm=` gate cannot be
#     satisfied by Cygwin ps, so the path is unreachable on this host in BOTH
#     worlds; the planning decision that leads to it IS compared.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the bash herdr oracle)"; exit 0; }

[ -f "$ROOT/bin/backends/herdr.psm1" ] || fail "bin/backends/herdr.psm1 is missing"

# A Herdr pane identity leaked in from the developer's own terminal would make
# the launcher-identity oracle resolve a parent this suite never models.
herdr_forget_inherited_pane

# The oracle. Sourced ONCE in this shell, not per case: sourcing it in a
# subshell per case would cost a fork per assertion.
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-psm1)
CAP="$TMP_ROOT/oracle.out"
ERRCAP="$TMP_ROOT/oracle.err"
CASES="$TMP_ROOT/cases.bin"
RESULTS="$TMP_ROOT/results.bin"
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_ERR="$TMP_ROOT/driver.err"

MOD_HERDR_N=$(fm_test_native_path "$ROOT/bin/backends/herdr.psm1")
MOD_BACKEND_N=$(fm_test_native_path "$ROOT/bin/fm-backend.psm1")

LF=$'\n'
TAB=$'\t'
# BYTE escapes, never printf '\uXXXX': bash renders \u through the CURRENT
# locale's charmap, and when that charmap cannot encode the code point (the
# MSYS default when no locale variable is exported - exactly firstmate's
# production hook environment) printf silently emits the LITERAL six bytes
# "\u2502" instead of the glyph. Every fixture built from these then contained
# no real glyph at all, the suite's own byte-copied expectations stayed
# self-consistently wrong, and the code-point-built PowerShell probe was the
# only honest participant. Same incident and same fix as the composer,
# classify and backend-core suites (task ps-port-locale).
GLYPH_CORNER=$'\xe2\x94\x94'   # U+2514
GLYPH_MIDDOT=$'\xc2\xb7'       # U+00B7
GLYPH_DASH=$'\xe2\x94\x80'     # U+2500
GLYPH_BAR=$'\xe2\x94\x82'      # U+2502
GLYPH_CLAUDE=$'\xe2\x9d\xaf'   # U+276F
TOKEN22='AbC0123456789_-xyzABCD'

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables in parent scope; see trap 3 in the header.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# assert_not_same <label> <unwanted> <actual>: the inverse guard, for a case
# where the contract is that a value must NOT be a particular sentinel (e.g.
# a count that must be non-zero). Kept beside assert_same so both share the
# same bookkeeping and a failure is reported the same way.
assert_not_same() {  # <label> <unwanted> <actual>
  local label=$1 unwanted=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$unwanted" = "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  must not be: $(printf '%q' "$unwanted")
"
  fi
}

assert_same() {  # <label> <expected(bash)> <actual(pwsh)>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): $(printf '%q' "$expected")
  actual(pwsh)  : $(printf '%q' "$actual")
"
  fi
}

# --- fork-free oracle capture -------------------------------------------------
#
# `read -d ''` reads to NUL, i.e. the whole file, and returns non-zero at EOF
# while still assigning - hence `|| true`. This costs no fork, where `$( ... )`
# costs one per call.
ORACLE=''
ORACLE_ERR=''
ORACLE_RC=0

run_oracle() {  # <fn> <args...>
  ORACLE=''; ORACLE_ERR=''; ORACLE_RC=0
  "$@" > "$CAP" 2> "$ERRCAP" || ORACLE_RC=$?
  IFS= read -r -d '' ORACLE < "$CAP" || true
  IFS= read -r -d '' ORACLE_ERR < "$ERRCAP" || true
}

first_line() {  # <text>
  printf '%s' "${1%%"$LF"*}"
}

# rstrip_oracle: the `$( ... )` convention, applied in place and fork-free.
#
# WHICH CASES NEED IT, and why this is not softening the comparison. Several bash
# functions here end in a pipeline (`grep | cut`, `jq | head -1`) or a
# `printf '%s\n'`, so their raw stdout carries a trailing newline - and EVERY
# bash call site consumes them through `$( ... )`, which strips it. The
# PowerShell twins return the value a bash caller ends up holding, so comparing
# at that convention compares what the consumers actually get. Every interior
# byte still has to match.
rstrip_oracle() {
  while [ "${ORACLE%"$LF"}" != "$ORACLE" ]; do ORACLE=${ORACLE%"$LF"}; done
}

yesno() {  # <fn> <args...> -> yes when it succeeds
  if "$@" > "$CAP" 2> "$ERRCAP"; then printf 'yes'; else printf 'no'; fi
}

# run_yesno is the FORK-FREE spelling of `$(yesno ...)`. Every `$( ... )` costs a
# fork, and this host charges ~3.3s for one under conversion load (measured), so
# a helper that answers through a variable instead of a subshell is the
# difference between a suite that finishes and one that reads as a hang.
YESNO=''
run_yesno() {  # <fn> <args...>
  if "$@" > "$CAP" 2> "$ERRCAP"; then YESNO=yes; else YESNO=no; fi
}

# read_file: the whole file into READ_FILE, without a subshell. `read -d ''`
# reads to NUL - i.e. everything - and returns non-zero at EOF while still
# assigning, hence `|| true`.
READ_FILE=''
read_file() {  # <path>
  READ_FILE=''
  IFS= read -r -d '' READ_FILE < "$1" 2>/dev/null || true
}

# Progress markers. A fork-bound differential suite is legitimately slow under
# load, and the port doc's own warning is that such a suite "presents as a hang,
# not as slowness" because it buffers its verdict to the end. These are TAP
# comments, so they are informational to any runner and visible to a human.
phase() {  # <text>
  printf '# phase: %s\n' "$1"
}

# --- case machinery -----------------------------------------------------------
#
# Field 0 is the op, field 1 the per-case environment (KEY=VALUE entries joined
# by 0x1F; see trap 1), fields 2..7 the arguments. Empty middle fields are
# meaningful, so the driver splits on the separator and asserts the FIELD COUNT
# rather than trusting a regex split.
FS=$(printf '\001')
RS=$(printf '\002')
US=$(printf '\037')

LABELS=()
EXPECT=()

add_case() {  # <label> <expected> <op> <env> <a1..a6>
  # Arity is checked rather than trusted. Under `set -u` a call that lost an
  # argument - a stray line continuation into a comment, say - dies with
  # "$2: unbound variable" pointing HERE, tens of minutes into a fork-bound run,
  # naming neither the case nor the mistake. This turns that into an instant,
  # attributable failure.
  [ "$#" -eq 10 ] || fail "add_case needs 10 arguments, got $# (first argument: ${1:-<none>})"
  LABELS+=("$1")
  EXPECT+=("$2")
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$3" "$FS" "$4" "$FS" "$5" "$FS" "$6" "$FS" "$7" "$FS" "$8" "$FS" "$9" "$FS" "${10}" >> "$CASES"
  printf '%s' "$RS" >> "$CASES"
}

: > "$CASES"

# --- shared fixtures ----------------------------------------------------------

# Two journal directories, one per world: the journal publish is deliberately
# create-if-absent, so both worlds writing the same file would make the second
# one refuse and the comparison meaningless. They are seeded identically and each
# world is told its own base through the per-case environment.
JBASH="$TMP_ROOT/journal-bash"
JPS="$TMP_ROOT/journal-ps"
mkdir -p "$JBASH" "$JPS"
JPS_N=$(fm_test_native_path "$JPS")

SBASH="$TMP_ROOT/state-bash"
SPS="$TMP_ROOT/state-ps"
mkdir -p "$SBASH" "$SPS"
SPS_N=$(fm_test_native_path "$SPS")

HOME_PRIMARY="$TMP_ROOT/home-primary"; mkdir -p "$HOME_PRIMARY"
HOME_SECOND="$TMP_ROOT/home-second"; mkdir -p "$HOME_SECOND"
printf 'sshhip-h7\n' > "$HOME_SECOND/.fm-secondmate-home"
HOME_PAD="$TMP_ROOT/home-pad"; mkdir -p "$HOME_PAD"
printf '  bravo-b2  \n\n' > "$HOME_PAD/.fm-secondmate-home"
HOME_EMPTY="$TMP_ROOT/home-empty"; mkdir -p "$HOME_EMPTY"
: > "$HOME_EMPTY/.fm-secondmate-home"
# Presentation config dirs: ONE DIRECTORY PER CONFIGURED STATE, written once here
# and never mutated again.
#
# This is trap 1 (per-case environment does not survive the batch) wearing a
# different hat, and it cost a red run to find: the bash oracle answers DURING
# case construction while the single pwsh driver answers minutes later, so a
# single config file rewritten between cases hands every PowerShell case the LAST
# state written. The failure is maximally misleading - every case reports the
# unconfigured default, which is a real verdict, so it reads as a broken parser
# rather than a fixture that moved. A file shared across cases is per-case state,
# exactly like an environment variable.
#
# The dirs are shared BETWEEN the two worlds (read-only on both sides, so the two
# reads cannot diverge on content) but never between cases. Each one's path
# appears inside the unrecognized-value warning, which is why norm_paths knows the
# common prefix.
PCFG_ROOT="$TMP_ROOT/prescfg"
mkdir -p "$PCFG_ROOT"
PCFG_ROOT_N=$(fm_test_native_path "$PCFG_ROOT")
PCFG_DIR=''
PCFG_DIR_N=''
make_pres_config() {  # <name> [<content>]   (no content argument = no file at all)
  PCFG_DIR="$PCFG_ROOT/$1"
  mkdir -p "$PCFG_DIR"
  rm -f "$PCFG_DIR/herdr-presentation-spaces"
  [ "$#" -lt 2 ] || printf '%s' "$2" > "$PCFG_DIR/herdr-presentation-spaces"
  PCFG_DIR_N=$(fm_test_native_path "$PCFG_DIR")
}

HOME_PRIMARY_N=$(fm_test_native_path "$HOME_PRIMARY")
HOME_SECOND_N=$(fm_test_native_path "$HOME_SECOND")
HOME_PAD_N=$(fm_test_native_path "$HOME_PAD")
HOME_EMPTY_N=$(fm_test_native_path "$HOME_EMPTY")

# norm_paths: the ONE place a path may legitimately appear in a compared value.
norm_paths() {
  NORMALIZED=$1
  NORMALIZED=${NORMALIZED//"$JPS_N"/<J>}
  NORMALIZED=${NORMALIZED//"$JPS"/<J>}
  NORMALIZED=${NORMALIZED//"$JBASH"/<J>}
  NORMALIZED=${NORMALIZED//"$SPS_N"/<S>}
  NORMALIZED=${NORMALIZED//"$SPS"/<S>}
  NORMALIZED=${NORMALIZED//"$SBASH"/<S>}
  # The presentation config dirs are SHARED between the worlds, but each world
  # names them in its own spelling and the unrecognized-value warning quotes that
  # name back.
  NORMALIZED=${NORMALIZED//"$PCFG_ROOT_N"/<C>}
  NORMALIZED=${NORMALIZED//"$PCFG_ROOT"/<C>}
  # ...and the ONE separator inside them, because each world was handed its own
  # spelling of the same directory. Scoped to the marker so no other value's
  # backslashes are touched.
  NORMALIZED=${NORMALIZED//'<C>\'/<C>/}
}

# =============================================================================
# PHASE A - fork-free, no child process on either side.
# =============================================================================

phase 'A: pure string and label rules'

# --- workspace label: the per-HOME container identity -------------------------
FM_HOME="$HOME_PRIMARY" run_oracle fm_backend_herdr_workspace_label
add_case 'herdr:label a primary home (no marker) resolves to firstmate' "$ORACLE" \
  wslabel "FM_HOME=$HOME_PRIMARY_N" '' '' '' '' '' ''
FM_HOME="$HOME_SECOND" run_oracle fm_backend_herdr_workspace_label
add_case 'herdr:label a secondmate home resolves to 2ndmate-<id>' "$ORACLE" \
  wslabel "FM_HOME=$HOME_SECOND_N" '' '' '' '' '' ''
FM_HOME="$HOME_PAD" run_oracle fm_backend_herdr_workspace_label
add_case 'herdr:label the marker id is whitespace-trimmed' "$ORACLE" \
  wslabel "FM_HOME=$HOME_PAD_N" '' '' '' '' '' ''
FM_HOME="$HOME_EMPTY" run_oracle fm_backend_herdr_workspace_label
add_case 'herdr:label an empty marker falls back to the primary label' "$ORACLE" \
  wslabel "FM_HOME=$HOME_EMPTY_N" '' '' '' '' '' ''
FM_HOME="$TMP_ROOT/home-missing" run_oracle fm_backend_herdr_workspace_label
add_case 'herdr:label a nonexistent home falls back to the primary label' "$ORACLE" \
  wslabel "FM_HOME=$(fm_test_native_path "$TMP_ROOT/home-missing")" '' '' '' '' '' ''

# --- session selection --------------------------------------------------------
unset HERDR_SESSION
run_oracle fm_backend_herdr_session
add_case 'herdr:session an unset HERDR_SESSION means the default session' "$ORACLE" \
  session '' '' '' '' '' '' ''
HERDR_SESSION=fm-lab-x run_oracle fm_backend_herdr_session
add_case 'herdr:session an explicit HERDR_SESSION is used verbatim' "$ORACLE" \
  session 'HERDR_SESSION=fm-lab-x' '' '' '' '' '' ''
HERDR_SESSION='' run_oracle fm_backend_herdr_session
add_case 'herdr:session an EMPTY HERDR_SESSION falls back to default' "$ORACLE" \
  session 'HERDR_SESSION=' '' '' '' '' '' ''
unset HERDR_SESSION

# --- target parsing: the first-colon-only rule --------------------------------
add_target_case() {  # <label> <target>
  local target=$2 answer
  if fm_backend_herdr_parse_target "$target"; then
    answer="$FM_BACKEND_HERDR_SESSION|$FM_BACKEND_HERDR_PANE"
  else
    answer='<none>'
  fi
  add_case "herdr:target $1" "$answer" target '' "$target" '' '' '' '' ''
}
add_target_case 'a pane id containing a colon splits on the FIRST colon only' 'default:w1:p2'
add_target_case 'a simple session:pane splits cleanly' 'fmtest:p9'
add_target_case 'a target with no colon is refused' 'nocolon'
add_target_case 'an empty session half is refused' ':w1:p2'
add_target_case 'an empty pane half is refused' 'sess:'
add_target_case 'an empty target is refused' ''
add_target_case 'a triple colon keeps everything after the first' 'a:b:c:d'

# --- key normalization --------------------------------------------------------
for k in Enter enter Escape escape Esc esc C-c c-c ctrl+c Ctrl+C ENTER 'space' ''; do
  run_oracle fm_backend_herdr_normalize_key "$k"
  add_case "herdr:key '$k' normalizes identically" "$ORACLE" key '' "$k" '' '' '' '' ''
done

# --- the presentation projection gate, part 1: the pure halves ----------------
#
# WHY THIS BLOCK EXISTS. The twin shipped a PRESENCE test of
# config/herdr-presentation-spaces while the oracle had become a version-gated
# tri-state that is default-ON, so with the ordinary configuration - no file at
# all - bash projected the worker into its own disposable workspace and the twin
# dropped it into the launcher's workspace with the launcher's working directory.
# `treehouse get` then had no repository to allocate from and fm-spawn's isolation
# assertion refused the launch, so EVERY native herdr spawn failed. Nothing in the
# suite caught it because nothing drove the decision at all. These cases drive it.
#
# The pure classifiers come first, fork-free: the config parser (no herdr call at
# all) and the two release comparisons.

# --- config/herdr-presentation-spaces parsing ---------------------------------
add_prespref_case() {  # <label> <config-dir(bash)> <config-dir(native)>
  local pref
  run_oracle fm_backend_herdr_presentation_preference "$2"
  rstrip_oracle
  pref="$ORACLE|$(first_line "$ORACLE_ERR")"
  add_case "herdr:prespref $1" "$pref" prespref "FM_T_CDIR=$3" '' '' '' '' '' ''
}
add_prespref_state_case() {  # <label> <config-name>
  add_prespref_case "$1" "$PCFG_DIR" "$PCFG_DIR_N"
}

make_pres_config absent
add_prespref_state_case 'an ABSENT flag is the unconfigured default'
make_pres_config empty ''
add_prespref_state_case 'an EMPTY flag is the historical opt-in and still means on'
make_pres_config spacey "$LF $TAB$LF"
add_prespref_state_case 'a whitespace-only flag is also the historical opt-in'
make_pres_config on "on$LF"
add_prespref_state_case 'an explicit on is honored'
make_pres_config off "off$LF"
add_prespref_state_case 'an explicit off is honored'
make_pres_config offpadded "  OFF  $LF"
add_prespref_state_case 'the value is whitespace-stripped and case-folded'
make_pres_config onmixed 'On'
add_prespref_state_case 'a mixed-case on with no trailing newline is honored'
make_pres_config bogus "disabled$LF"
add_prespref_state_case 'an unrecognized value warns and falls back to the default'
make_pres_config twowords "off off$LF"
add_prespref_state_case 'two words collapse to one unrecognized token, not to off'
add_prespref_case 'a missing config DIRECTORY is the unconfigured default' \
  "$PCFG_ROOT/nothere" "$(fm_test_native_path "$PCFG_ROOT/nothere")"
add_prespref_case 'an EMPTY config-dir argument is the unconfigured default' '' ''

# --- dotted-release comparison ------------------------------------------------
#
# The return code is a TRICHOTOMY (at-or-above / below / unparseable) and the
# unparseable arm is load-bearing: it is what keeps an unreadable release from
# being read as "below" and warned about with the wrong words.
add_verat_case() {  # <candidate> <floor>
  local status=0
  fm_backend_herdr_version_at_least "$1" "$2" || status=$?
  add_case "herdr:versionatleast '$1' vs '$2' compares identically" "$status" \
    versionatleast '' "$1" "$2" '' '' '' ''
}
add_verat_case '0.8.0' '0.8.0'
add_verat_case '0.8.1' '0.8.0'
add_verat_case '0.7.5' '0.8.0'
add_verat_case '0.7.9' '0.8.0'
add_verat_case '1.0.0' '0.8.0'
add_verat_case '0.10.0' '0.8.0'
add_verat_case '0.8' '0.8.0'
add_verat_case '0.8.0-preview.2026-08-04-d78e3d3b5126' '0.8.0'
add_verat_case '0.7.5-preview.1' '0.8.0'
add_verat_case '0.8.0+build.7' '0.8.0'
add_verat_case '' '0.8.0'
add_verat_case 'unknown' '0.8.0'
add_verat_case '0.8.0rc1' '0.8.0'
add_verat_case '-1.0.0' '0.8.0'
add_verat_case '08.0.0' '0.8.0'
add_verat_case '0.08.0' '0.8.0'
add_verat_case '..' '0.8.0'
add_verat_case '0.8.0.1' '0.8.0'
# A component too large for the shell's integer type makes BOTH bash comparisons
# fail, so the pair is skipped and the walk continues as though equal. The twin
# reproduces that rather than answering from a wider type.
add_verat_case '99999999999999999999.0.0' '0.8.0'
add_verat_case '0.8.0' ''

# --- the two-signal floor classifier ------------------------------------------
#
# The measured release identities, from docs/verification/runtime-backends.md
# "Presentation version floor": 0.7.3/0.7.4 report protocol 16, 0.7.5 reports 17,
# the first post-fix preview reports 18, and 0.8.0 reports 19.
# stderr is captured rather than inherited: the oracle's own `[ -ge ]` prints
# "integer expression expected" for a protocol too large for the shell's integer
# type, and that diagnostic belongs in the case, not in the suite's output where
# it reads as a suite failure.
add_floor_case() {  # <protocol> <version>
  local status=0
  fm_backend_herdr_release_floor_verdict "$1" "$2" 2>"$ERRCAP" || status=$?
  add_case "herdr:floorverdict protocol='$1' version='$2' classifies identically" "$status" \
    floorverdict '' "$1" "$2" '' '' '' ''
}
add_floor_case 19 '0.8.0'
add_floor_case 20 '0.9.0'
add_floor_case 18 '0.8.0-preview.1'
add_floor_case 17 '0.7.5'
add_floor_case 16 '0.7.3'
add_floor_case 19 ''
add_floor_case '' '0.8.0'
add_floor_case '' '0.7.5'
add_floor_case '' ''
add_floor_case '' 'unknown'
add_floor_case 'abc' '0.8.0'
add_floor_case 'abc' '0.7.5'
add_floor_case 'abc' 'unknown'
add_floor_case 18 'unknown'
add_floor_case 999999999999999999999 '0.7.5'

# --- presentation labels (Unicode; Phase A only) ------------------------------
for t in 'firstmate/alpha' '2ndmate-sm1/beta' 'fm-gamma' 'plain-task' '2ndmate-nolash' \
         'firstmate/fm-delta' '' 'fm-'; do
  run_oracle fm_backend_herdr_projection_concise_task_label "$t"
  add_case "herdr:concise '$t' strips owner prefixes identically" "$ORACLE" \
    concise '' "$t" '' '' '' '' ''
  run_oracle fm_backend_herdr_projection_workspace_label "$t" "$TOKEN22"
  add_case "herdr:wslabel '$t' builds the same presentation label" "$ORACLE" \
    projlabel '' "$t" "$TOKEN22" '' '' '' ''
done

# --- agent-status classification ----------------------------------------------
for s in working idle done blocked unknown '' bogus WORKING; do
  run_oracle fm_backend_herdr_classify_agent_status "$s"
  add_case "herdr:classify '$s' maps to the watcher vocabulary identically" "$ORACLE" \
    classify '' "$s" '' '' '' '' ''
  run_oracle fm_backend_herdr_classify_submit_agent_status "$s"
  add_case "herdr:classifysubmit '$s' maps to the submit vocabulary identically" "$ORACLE" \
    classifysubmit '' "$s" '' '' '' '' ''
done

# --- escalation marker keying (must match the watcher's own .stale-<key>) -----
for w in 'sess:w1:p2' 'a/b:c.d' 'plain' '' 'x:::y' 'a.b.c'; do
  run_oracle fm_backend_herdr_escalation_marker '/st' "$w"
  add_case "herdr:marker '$w' keys identically to the watcher scheme" "$ORACLE" \
    marker '' '/st' "$w" '' '' '' ''
done

# --- submit confirmation budget ------------------------------------------------
add_budget_case() {  # <min> <budget>
  local min=$1 budget=$2
  FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=$min run_oracle fm_backend_herdr_submit_confirm_budget "$budget"
  add_case "herdr:budget min=$min budget=$budget floors identically" "$ORACLE" \
    budget "FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=$min" "$budget" '' '' '' '' ''
}
add_budget_case 0.6 0
add_budget_case 0.6 0.25
add_budget_case 0.6 2
add_budget_case 0 0.4
add_budget_case 0.6 ''
add_budget_case 0.6 -3
add_budget_case 1.5 1.5
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6

# --- Pi separator rows (Unicode width rule) -----------------------------------
add_sep_case() {  # <label> <row>
  # The oracle's ${#row} counts BYTES under the C-default locale firstmate's
  # hooks actually run in, so seven 3-byte rule characters read as 21 and pass
  # the >=8 rule - production bash lowers the intended character threshold to
  # three dashes. The twin implements the rule's stated intent (characters).
  # Pin a UTF-8 LC_ALL around the oracle call so the differential asserts the
  # RULE rather than the host's byte-counting accident; the production-side
  # divergence itself is documented at Test-FmBackendHerdrPiSeparatorRow.
  local _sep_saved_lc=${LC_ALL-} _sep_had_lc=${LC_ALL+set}
  LC_ALL=C.UTF-8
  run_yesno fm_backend_herdr_pi_separator_row "$2"
  if [ -n "$_sep_had_lc" ]; then LC_ALL=$_sep_saved_lc; else unset LC_ALL; fi
  add_case "herdr:pisep $1" "$YESNO" pisep '' "$2" '' '' '' '' ''
}
SEP8=$(printf "$GLYPH_DASH%.0s" 1 2 3 4 5 6 7 8)
SEP7=$(printf "$GLYPH_DASH%.0s" 1 2 3 4 5 6 7)
SEP12=$(printf "$GLYPH_DASH%.0s" 1 2 3 4 5 6 7 8 9 10 11 12)
add_sep_case 'exactly eight rule characters is a separator' "$SEP8"
add_sep_case 'seven rule characters is not' "$SEP7"
add_sep_case 'a padded rule is trimmed before measuring' "   $SEP12   "
add_sep_case 'a rule with an embedded letter is not a separator' "${SEP8}x"
add_sep_case 'an empty row is not a separator' ''
add_sep_case 'a run of ASCII dashes is not a separator' '--------'

# --- Pi composer structure ----------------------------------------------------
add_pi_case() {  # <label> <capture>
  local answer
  fm_backend_herdr_pi_composer_find "$2"
  answer="$FM_BACKEND_HERDR_PI_PAIR_FOUND|$FM_BACKEND_HERDR_PI_PAIR_VALID|$FM_BACKEND_HERDR_PI_PAIR_OPEN_LINE|$FM_BACKEND_HERDR_PI_PAIR_LINE|$FM_BACKEND_HERDR_PI_LAST_SEPARATOR_LINE|$FM_BACKEND_HERDR_PI_CONTENT"
  add_case "herdr:picomposer $1" "$answer" picomposer '' "$2" '' '' '' '' ''
}
add_pi_case 'a complete pair around one content row' "top${LF}${SEP12}${LF}hello${LF}${SEP12}"
add_pi_case 'a complete pair around an EMPTY content row' "${SEP12}${LF}${LF}${SEP12}"
add_pi_case 'two empty content rows accumulate as one empty string' "${SEP12}${LF}${LF}${LF}${SEP12}"
add_pi_case 'an unmatched separator records only its line number' "a${LF}${SEP12}${LF}b"
add_pi_case 'no separators at all' "a${LF}b${LF}c"
add_pi_case 'the LOWER pair wins over an earlier one' "${SEP12}${LF}one${LF}${SEP12}${LF}two${LF}${SEP12}"
add_pi_case 'an over-tall candidate is found but invalid' \
  "${SEP12}${LF}1${LF}2${LF}3${LF}4${LF}5${LF}6${LF}7${LF}8${LF}9${LF}${SEP12}"
add_pi_case 'an empty capture' ''

# --- bordered / bare composer row shapes --------------------------------------
add_row_case() {  # <label> <row>
  local trimmed answer
  trimmed=$2
  case "$trimmed" in
    "$GLYPH_BAR"*"$GLYPH_BAR"|'|'*'|') answer=bordered ;;
    *) answer=other ;;
  esac
  add_case "herdr:borderrow $1" "$answer" borderrow '' "$2" '' '' '' '' ''
}
add_row_case 'a box-drawing bordered row' "${GLYPH_BAR} hi ${GLYPH_BAR}"
add_row_case 'an ASCII pipe bordered row' '| hi |'
add_row_case 'a lone border glyph is not a bordered row' "$GLYPH_BAR"
add_row_case 'two adjacent border glyphs are a bordered row' "${GLYPH_BAR}${GLYPH_BAR}"
add_row_case 'a footer using the glyph only internally is not bordered' 'Enter:send | quit'
add_row_case 'a bare claude prompt row is not bordered' "${GLYPH_CLAUDE} hello"

# --- cut/tail record primitives -----------------------------------------------
# The oracle here is the real `cut`/`tail`, not a bash re-implementation of them:
# the whole point is that the PowerShell twin matches the tools the bash adapter
# actually pipes through, including cut's no-delimiter quirk. The pipeline is run
# directly rather than through `bash -c` so it costs two forks, not three.
# Captured through `$( )`, NOT byte-exactly, because every real caller in
# herdr.sh consumes cut that way (`pane_id=$(printf '%s' "$line" | cut -f1)`)
# and command substitution strips cut's trailing newline. Comparing raw cut
# stdout would demand the twin return a terminator that no caller ever sees.
# tail below IS captured byte-exactly, because its two callers pipe its stdout
# straight through instead of substituting it - the shapes genuinely differ.
add_cut_case() {  # <line> <field>
  ORACLE=$(printf '%s' "$1" | cut -f"$2")
  add_case "herdr:cut field $2 of record $3" "$ORACLE" cut '' "$1" "$2" '' '' '' ''
}
add_cut_case "a${TAB}b${TAB}c${TAB}d" 1 'four-full'
add_cut_case "a${TAB}${TAB}c${TAB}d" 2 'empty-middle'
add_cut_case "a${TAB}${TAB}c${TAB}d" 3 'after-empty-middle'
add_cut_case "a${TAB}b" 4 'past-the-end'
add_cut_case 'nodelimiter' 2 'no-delimiter'
add_cut_case "${TAB}b${TAB}c${TAB}d" 1 'empty-first'

add_tail_case() {  # <text> <count> <label>
  printf '%s' "$1" | tail -n "$2" > "$CAP"
  ORACLE=''; IFS= read -r -d '' ORACLE < "$CAP" || true
  add_case "herdr:tail last $2 of $3" "$ORACLE" tail '' "$1" "$2" '' '' '' ''
}
add_tail_case "a${LF}b${LF}c" 2 'three-lines'
add_tail_case "a${LF}b${LF}c" 5 'bound-above-content'
add_tail_case '' 3 'empty-input'
add_tail_case "only" 2 'single-unterminated-line'

# --- host path normalization ---------------------------------------------------
for p in 'F:\proj\x' 'F:/proj/x' '/f/proj/x' '/tmp/socket' 'relative/x' ''; do
  run_oracle fm_backend_herdr_normalize_host_path "$p"
  rstrip_oracle
  add_case "herdr:normhost '$p' normalizes identically" "$ORACLE" \
    normhost '' "$p" '' '' '' '' ''
done

# --- canonical socket identity (feeds the cross-runtime lock hash) ------------
for s in '/c/Users/x/herdr.sock' 'C:\Users\x\herdr.sock' 'C:/Users/x/herdr.sock' \
         'relative.sock' '' '/nodir-here/herdr.sock'; do
  if fm_backend_herdr_canonical_socket_path "$s" > "$CAP" 2>/dev/null; then
    IFS= read -r -d '' ORACLE < "$CAP" || true
  else
    ORACLE='<none>'
  fi
  add_case "herdr:canonsock '$s' canonicalizes identically" "$ORACLE" \
    canonsock '' "$s" '' '' '' '' ''
done

# --- the lock namespace and the lock-path hash --------------------------------
run_oracle fm_backend_herdr_presentation_lock_namespace
add_case 'herdr:locknamespace the machine-private namespace path is identical' "$ORACLE" \
  locknamespace '' '' '' '' '' '' ''

# The lock PATH itself needs a live session listing, so the hash is compared
# through its own deterministic input instead: identical session+socket must
# produce the identical file name, which is what stops two runtimes from taking
# two different locks for one session (inventory R2).
add_lockhash_case() {  # <session> <socket>
  local hash key
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s\0%s' "$1" "$2" | shasum -a 256 2>/dev/null | awk '{print $1}')
  else
    hash=$(printf '%s\0%s' "$1" "$2" | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  key=${hash:0:32}
  add_case "herdr:lockhash '$1' + '$2' hashes to the same lock key" "$key" \
    lockhash '' "$1" "$2" '' '' '' ''
}
add_lockhash_case 'default' '/c/Users/x/herdr.sock'
add_lockhash_case 'fm-lab-a' '/tmp/herdr/sessions/fm-lab-a/herdr.sock'
add_lockhash_case '' ''

# --- normalized transition records --------------------------------------------
add_event_case() {  # <pane> <ws> <status> <agent>
  run_oracle fm_backend_herdr_normalize_event "$1" "$2" "$3" "$4"
  add_case "herdr:event ($1,$2,$3,$4) normalizes identically" "$ORACLE" \
    event '' "$1" "$2" "$3" "$4" '' ''
}
add_event_case 'w1:p2' 'w1' 'blocked' 'claude'
add_event_case 'w1:p2' '' 'working' ''
add_event_case '' '' '' ''
add_event_case "w1:p2" "ws${TAB}x" 'idle' 'pi'

# --- the reader override, and the ONE documented divergence -------------------
FM_BACKEND_HERDR_EVENT_READER='fakereader --replay a b' run_oracle fm_backend_herdr_event_reader_cmd
rstrip_oracle
add_case 'herdr:readercmd an explicit reader override splits identically' "$ORACLE" \
  readercmd 'FM_BACKEND_HERDR_EVENT_READER=fakereader --replay a b' '' '' '' '' '' ''
FM_BACKEND_HERDR_EVENT_READER='  spaced   reader  ' run_oracle fm_backend_herdr_event_reader_cmd
rstrip_oracle
add_case 'herdr:readercmd whitespace runs in an override collapse identically' "$ORACLE" \
  readercmd 'FM_BACKEND_HERDR_EVENT_READER=  spaced   reader  ' '' '' '' '' '' ''
unset FM_BACKEND_HERDR_EVENT_READER

# The DEFAULT reader deliberately differs: bash names herdr-eventwait.py, the
# PowerShell twin absorbed that transport and returns nothing so its own native
# reader is used. Asserted as the documented divergence rather than compared,
# because comparing it would demand the port keep a Python dependency it removed.
run_oracle fm_backend_herdr_event_reader_cmd
ASSERTIONS=$((ASSERTIONS + 1))
case "$ORACLE" in
  *herdr-eventwait.py*) : ;;
  *)
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}herdr:readercmd the bash oracle no longer defaults to herdr-eventwait.py, so the documented absorption divergence needs re-checking
  got: $ORACLE
"
    ;;
esac
add_case 'herdr:readercmd the PowerShell default is the native transport (documented divergence)' \
  '<native>' readercmd '' '' '' '' '' '' ''

phase 'A: presentation journal readers (the fork-heavy phase)'

# --- the presentation journal --------------------------------------------------
#
# The journals are SEEDED directly rather than through the create path, because
# the create path mints a random 128-bit token and a random value cannot be
# compared across two processes. The token generator gets its own shape
# assertions below; everything that READS a journal is compared against a fixed
# token, which is what makes snapshot, bind and replace deterministic.

seed_journal() {  # <leaf> <content>
  printf '%s' "$2" > "$JBASH/$1"
  printf '%s' "$2" > "$JPS/$1"
}

V2_WSLABEL="${GLYPH_CORNER} t2 ${GLYPH_MIDDOT} p:${TOKEN22}"
seed_journal 't1.herdr-presentation' \
  "version=1${LF}task_id=t1${LF}projection_id=${TOKEN22}${LF}"
seed_journal 'extra.herdr-presentation' \
  "version=1${LF}task_id=extra${LF}projection_id=${TOKEN22}${LF}stray=1${LF}"
seed_journal 'shorttok.herdr-presentation' \
  "version=1${LF}task_id=shorttok${LF}projection_id=tooshort${LF}"
seed_journal 'dupkey.herdr-presentation' \
  "version=1${LF}version=1${LF}task_id=dupkey${LF}projection_id=${TOKEN22}${LF}"
seed_journal 'badtok.herdr-presentation' \
  "version=1${LF}task_id=badtok${LF}projection_id=AbC0123456789_-xyzAB!D${LF}"
V2_BODY="version=2${LF}task_id=t2${LF}projection_id=${TOKEN22}${LF}home=/w/home${LF}session=fmtest${LF}workspace_id=w7${LF}tab_id=w7:t1${LF}pane_id=w7:p1${LF}parent_workspace_id=w1${LF}parent_label=firstmate${LF}workspace_label=${V2_WSLABEL}${LF}task_label=fm-t2${LF}"
seed_journal 't2.herdr-presentation' "$V2_BODY"
seed_journal 'relhome.herdr-presentation' "${V2_BODY//home=\/w\/home/home=w/home}"
seed_journal 'spacey.herdr-presentation' "${V2_BODY//session=fmtest/session=fm test}"
seed_journal 'wronglabel.herdr-presentation' "${V2_BODY//task_label=fm-t2/task_label=fm-other}"
seed_journal 'short2.herdr-presentation' "${V2_BODY%task_label=fm-t2$LF}"
seed_journal 'v3.herdr-presentation' "${V2_BODY//version=2/version=3}"

# snapshot_answer answers through a GLOBAL, not stdout: `$( ... )` would cost a
# fork per case on top of the ~11-38 the reader itself spends (three per field,
# because the bash field reader is grep -c plus grep | cut).
SNAP=''
snapshot_answer() {  # <journal> <task-id>
  if fm_backend_herdr_projection_journal_snapshot "$1" "$2"; then
    SNAP="$FM_BACKEND_HERDR_JOURNAL_VERSION|$FM_BACKEND_HERDR_JOURNAL_TASK_ID|$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID|$FM_BACKEND_HERDR_JOURNAL_HOME|$FM_BACKEND_HERDR_JOURNAL_SESSION|$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID|$FM_BACKEND_HERDR_JOURNAL_TAB_ID|$FM_BACKEND_HERDR_JOURNAL_PANE_ID|$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID|$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL|$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL|$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL"
  else
    SNAP='<none>'
  fi
}

add_snapshot_case() {  # <label> <leaf> <task-id>
  snapshot_answer "$JBASH/$2" "$3"
  add_case "herdr:journal $1" "$SNAP" journalsnapshot "FM_T_JDIR=$JPS_N" "$2" "$3" '' '' '' ''
}
add_snapshot_case 'a valid version 1 attempt validates' 't1.herdr-presentation' t1
add_snapshot_case 'a version 1 journal with an extra line is refused' 'extra.herdr-presentation' extra
add_snapshot_case 'a short projection token is refused' 'shorttok.herdr-presentation' shorttok
add_snapshot_case 'a duplicated key is refused' 'dupkey.herdr-presentation' dupkey
add_snapshot_case 'a token with an illegal character is refused' 'badtok.herdr-presentation' badtok
add_snapshot_case 'a task-id mismatch is refused' 't1.herdr-presentation' other
add_snapshot_case 'a valid version 2 binding validates' 't2.herdr-presentation' t2
add_snapshot_case 'a relative home is refused' 'relhome.herdr-presentation' t2
add_snapshot_case 'a whitespace-bearing exact field is refused' 'spacey.herdr-presentation' t2
add_snapshot_case 'a task label that is not fm-<id> is refused' 'wronglabel.herdr-presentation' t2
add_snapshot_case 'a truncated version 2 record is refused' 'short2.herdr-presentation' t2
add_snapshot_case 'an unknown version is refused' 'v3.herdr-presentation' t2
add_snapshot_case 'a missing journal is refused' 'nothere.herdr-presentation' t2

add_token_case() {  # <label> <leaf> <task-id>
  run_oracle fm_backend_herdr_projection_journal_token "$JBASH/$2" "$3"
  [ "$ORACLE_RC" -eq 0 ] || ORACLE='<none>'
  add_case "herdr:journaltoken $1" "$ORACLE" journaltoken "FM_T_JDIR=$JPS_N" "$2" "$3" '' '' '' ''
}
add_token_case 'a version 1 token is readable' 't1.herdr-presentation' t1
add_token_case 'a malformed journal has no token' 'shorttok.herdr-presentation' shorttok

add_field_case() {  # <leaf> <key>
  run_oracle fm_backend_herdr_projection_journal_field "$JBASH/$1" "$2"
  rstrip_oracle
  [ "$ORACLE_RC" -eq 0 ] || ORACLE='<none>'
  add_case "herdr:journalfield $1/$2 reads identically" "$ORACLE" \
    journalfield "FM_T_JDIR=$JPS_N" "$1" "$2" '' '' '' ''
}
add_field_case 't1.herdr-presentation' version
add_field_case 't1.herdr-presentation' missing
add_field_case 'dupkey.herdr-presentation' version

phase 'presentation journal write paths'

# bind and replace compare the RESULTING FILE BYTES rather than a re-read
# snapshot. That is both stronger - the twelve-line record has to match
# byte-for-byte, key order included, which is what keeps a journal written by one
# world readable by the other - and far cheaper, because reading a file costs no
# fork while re-running the field reader costs three per field.
BIND_LABEL="${GLYPH_CORNER} t1 ${GLYPH_MIDDOT} p:${TOKEN22}"
if fm_backend_herdr_projection_journal_bind "$JBASH/t1.herdr-presentation" t1 \
    /w/home fmtest w7 w7:t1 w7:p1 w1 firstmate "$BIND_LABEL" fm-t1 >/dev/null 2>&1; then
  read_file "$JBASH/t1.herdr-presentation"
else
  READ_FILE='<none>'
fi
add_case 'herdr:journalbind a version 1 attempt upgrades to a byte-exact version 2 record' \
  "$READ_FILE" journalbind "FM_T_JDIR=$JPS_N" 't1.herdr-presentation' t1 '' '' '' ''

run_yesno fm_backend_herdr_projection_journal_bind "$JBASH/t1.herdr-presentation" t1 \
  /w/home fmtest w9 w9:t1 w9:p1 w1 firstmate "$BIND_LABEL" fm-t1
add_case 'herdr:journalbind a second bind on a version 2 binding is refused' \
  "$YESNO" journalbind2 "FM_T_JDIR=$JPS_N" 't1.herdr-presentation' t1 '' '' '' ''

if fm_backend_herdr_projection_journal_replace_endpoint "$JBASH/t2.herdr-presentation" t2 \
    w7:t1 w7:p1 w7:t9 w7:p9 >/dev/null 2>&1; then
  read_file "$JBASH/t2.herdr-presentation"
else
  READ_FILE='<none>'
fi
add_case 'herdr:journalreplace an exact old endpoint advances the record byte-exactly' \
  "$READ_FILE" journalreplace "FM_T_JDIR=$JPS_N" 't2.herdr-presentation' t2 'w7:t1' 'w7:p1' 'w7:t9' 'w7:p9'

run_yesno fm_backend_herdr_projection_journal_replace_endpoint "$JBASH/t2.herdr-presentation" t2 \
  w7:t1 w7:p1 w7:tX w7:pX
add_case 'herdr:journalreplace a mismatched old endpoint is refused' \
  "$YESNO" journalreplace2 "FM_T_JDIR=$JPS_N" 't2.herdr-presentation' t2 'w7:t1' 'w7:p1' 'w7:tX' 'w7:pX'

# create: the token is random, so the SHAPE is compared, not the value.
#
# The record is compared with the random token MASKED, which leaves the whole
# rest of the record - key order, key names, the task id, the trailing newline -
# under byte-exact comparison while the one unpredictable value is reduced to
# "22 characters from the base64url alphabet".
mask_token() {  # <text> <token>
  MASKED=${1//"$2"/<tok22>}
}
run_oracle fm_backend_herdr_projection_journal_create "$JBASH" fresh
if [ "$ORACLE_RC" -eq 0 ]; then
  FRESH_TOKEN=$ORACLE
  read_file "$JBASH/fresh.herdr-presentation"
  mask_token "$READ_FILE" "$FRESH_TOKEN"
  case "$FRESH_TOKEN" in
    ??????????????????????) case "$FRESH_TOKEN" in *[!A-Za-z0-9_-]*) MASKED='<badtoken>' ;; esac ;;
    *) MASKED='<badtoken>' ;;
  esac
else
  MASKED='<none>'
fi
add_case 'herdr:journalcreate publishing an attempt yields a byte-exact version 1 record with a 22-char base64url token' \
  "$MASKED" journalcreate "FM_T_JDIR=$JPS_N" fresh '' '' '' '' ''

add_create_refusal_case() {  # <label> <task-id>
  run_oracle fm_backend_herdr_projection_journal_create "$JBASH" "$2"
  add_case "herdr:journalcreate $1" "$(first_line "$ORACLE_ERR")" \
    journalcreate2 "FM_T_JDIR=$JPS_N" "$2" '' '' '' '' ''
}
add_create_refusal_case 'a second create for the same task is refused loudly' fresh
add_create_refusal_case 'an invalid task id is refused loudly' '../escape'
add_create_refusal_case 'a dot-prefixed task id is refused loudly' '.hidden'

phase 'A: escalation dedupe markers'

# --- the per-pane escalation dedupe marker ------------------------------------
#
# The lifecycle the watcher depends on: a fresh blocked edge fires ONCE, a
# committed marker suppresses the next one, and a working edge clears it.
BLOCKED_RECORD=$(fm_backend_herdr_normalize_event 'w1:p2' 'w1' 'blocked' 'claude')
WORKING_RECORD=$(fm_backend_herdr_normalize_event 'w1:p2' 'w1' 'working' 'claude')
IDLE_RECORD=$(fm_backend_herdr_normalize_event 'w1:p2' 'w1' 'idle' 'claude')
EMPTY_PANE_RECORD=$(fm_backend_herdr_normalize_event '' 'w1' 'blocked' 'claude')

TSEQ=''
tseq_step() {  # <hit-word> <miss-word> <fn> <args...>
  local hit=$1 miss=$2
  shift 2
  [ -z "$TSEQ" ] || TSEQ="$TSEQ|"
  if "$@" > "$CAP" 2> "$ERRCAP"; then TSEQ="$TSEQ$hit"; else TSEQ="$TSEQ$miss"; fi
}
transition_sequence() {  # <state-dir>
  local state=$1
  TSEQ=''
  rm -f "$state"/.herdr-escalated-* 2>/dev/null || true
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$BLOCKED_RECORD"
  tseq_step committed nocommit fm_backend_herdr_commit_transition "$state" fmtest "$BLOCKED_RECORD"
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$BLOCKED_RECORD"
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$WORKING_RECORD"
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$BLOCKED_RECORD"
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$IDLE_RECORD"
  tseq_step hit miss fm_backend_herdr_apply_transition "$state" fmtest "$EMPTY_PANE_RECORD"
  tseq_step cleared noclear fm_backend_herdr_clear_transition "$state" 'fmtest:w1:p2'
  tseq_step cleared noclear fm_backend_herdr_clear_transition "$state" ''
}
transition_sequence "$SBASH"
add_case 'herdr:transition the blocked/commit/absorb/clear lifecycle is identical' \
  "$TSEQ" transitionseq "FM_T_SDIR=$SPS_N" '' '' '' '' '' ''

rm -f "$SBASH"/.herdr-escalated-* 2>/dev/null || true
run_oracle fm_backend_herdr_apply_transition "$SBASH" fmtest "$BLOCKED_RECORD"
[ "$ORACLE_RC" -eq 0 ] || ORACLE='<none>'
add_case 'herdr:transition a fresh blocked edge returns the exact normalized record' \
  "$ORACLE" applytransition "FM_T_SDIR=$SPS_N" fmtest "$BLOCKED_RECORD" '' '' '' ''

# =============================================================================
# PHASE B - both worlds driven through a fake herdr CLI. See the header for why
# there are two fakes and why these arguments stay ASCII.
# =============================================================================

phase 'B: fake-CLI scenarios'

BASE_PATH="$PATH"
export FM_BACKEND_HERDR_SCRIPTED_CLI=1

make_herdr_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
# Fake herdr (bash side). Twin: herdr.cmd. Responses are NUMBERED and consumed in
# call order from $FM_HERDR_RESPONSES; the counter and the log are per-world so
# the two runs cannot interfere, while the FIXTURES are shared.
set -u
raw=
for a in "$@"; do
  case $a in
    *' '*) raw="$raw \"$a\"" ;;
    *) raw="$raw $a" ;;
  esac
done
printf '%s\n' "${raw# }" >> "$FM_HERDR_LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.5","protocol":18},"server":{"running":true}}\n'
  exit 0
fi
n=$(( $(cat "$FM_HERDR_COUNTER" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$FM_HERDR_COUNTER"
if [ -f "$FM_HERDR_RESPONSES/$n.exit" ]; then
  [ -f "$FM_HERDR_RESPONSES/$n.out" ] && cat "$FM_HERDR_RESPONSES/$n.out"
  exit "$(cat "$FM_HERDR_RESPONSES/$n.exit")"
fi
[ -f "$FM_HERDR_RESPONSES/$n.out" ] && cat "$FM_HERDR_RESPONSES/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  # Batch twin. `%*` keeps the raw command line intact, because cmd tokenizes
  # `%1` on `=` as well as on space and would log a different shape.
  {
    printf '@echo off\r\n'
    printf 'setlocal enabledelayedexpansion\r\n'
    printf '>>"%%FM_HERDR_LOG%%" echo %%*\r\n'
    printf 'if /I "%%~1"=="status" if /I "%%~2"=="--json" (\r\n'
    printf '  echo {"client":{"version":"0.7.5","protocol":18},"server":{"running":true}}\r\n'
    printf '  exit /b 0\r\n'
    printf ')\r\n'
    printf 'set n=0\r\n'
    printf 'if exist "%%FM_HERDR_COUNTER%%" set /p n=<"%%FM_HERDR_COUNTER%%"\r\n'
    printf 'set /a n=!n!+1\r\n'
    printf '>"%%FM_HERDR_COUNTER%%" echo !n!\r\n'
    printf 'if exist "%%FM_HERDR_RESPONSES%%\\!n!.out" type "%%FM_HERDR_RESPONSES%%\\!n!.out"\r\n'
    printf 'if exist "%%FM_HERDR_RESPONSES%%\\!n!.exit" (\r\n'
    printf '  set /p rc=<"%%FM_HERDR_RESPONSES%%\\!n!.exit"\r\n'
    printf '  exit /b !rc!\r\n'
    printf ')\r\n'
    printf 'exit /b 0\r\n'
  } > "$fb/herdr.cmd"
  printf '%s\n' "$fb"
}

# One scenario: its own fixture dir, its own shared responses, and one log per
# world. Returns through B_* variables (no subshell - see trap 3).
B_DIR=''
B_FB=''
B_RESP=''
B_LOG_BASH=''
B_LOG_PS=''
B_ENV=''
new_scenario() {  # <name>
  B_DIR="$TMP_ROOT/b-$1"
  mkdir -p "$B_DIR/responses"
  B_FB=$(make_herdr_fakebin "$B_DIR")
  B_RESP="$B_DIR/responses"
  B_LOG_BASH="$B_DIR/log.bash"
  B_LOG_PS="$B_DIR/log.ps"
  : > "$B_LOG_BASH"
  : > "$B_LOG_PS"
  : > "$B_DIR/count.bash"
  : > "$B_DIR/count.ps"
  B_ENV="PATH=$(fm_test_native_path "$B_FB")${US}FM_HERDR_LOG=$(fm_test_native_path "$B_LOG_PS")${US}FM_HERDR_COUNTER=$(fm_test_native_path "$B_DIR/count.ps")${US}FM_HERDR_RESPONSES=$(fm_test_native_path "$B_RESP")${US}FM_BACKEND_HERDR_SCRIPTED_CLI=1"
}

# The command-log pairs collected for the final structural diff.
LOG_PAIRS=()

run_scenario() {  # <label> <expected-producer-fn> <op> <a1..a6>
  local label=$1 producer=$2 op=$3
  shift 3
  PATH="$B_FB:$BASE_PATH"
  FM_HERDR_LOG="$B_LOG_BASH" FM_HERDR_COUNTER="$B_DIR/count.bash" FM_HERDR_RESPONSES="$B_RESP" \
    "$producer" "$@"
  PATH="$BASE_PATH"
  add_case "$label" "$B_ANSWER" "$op" "$B_ENV" "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
  LOG_PAIRS+=("$B_LOG_BASH|$B_LOG_PS|$label")
}

B_ANSWER=''

# --- presence and the recovery-grade agent state ------------------------------
p_presence() { run_oracle fm_backend_herdr_pane_presence_state "$1" "$2"; B_ANSWER=$ORACLE; }
p_paneagent() { run_oracle fm_backend_herdr_pane_agent_state "$1" "$2"; B_ANSWER=$ORACLE; }
p_agentstate() { run_oracle fm_backend_herdr_agent_state "$1"; B_ANSWER=$ORACLE; }
p_agentalive() { run_oracle fm_backend_herdr_agent_alive "$1"; B_ANSWER=$ORACLE; }
p_endpointgone() { run_yesno fm_backend_herdr_endpoint_confirmed_gone "$1"; B_ANSWER=$YESNO; }

new_scenario presence-dead
printf '%s\n' '{"error":{"code":"pane_not_found","message":"gone"}}' > "$B_RESP/1.out"
run_scenario 'herdr:presence a structured pane_not_found is dead' p_presence presence fmtest 'w1:p1'

new_scenario presence-present
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
run_scenario 'herdr:presence a round-tripping pane id is present' p_presence presence fmtest 'w1:p1'

new_scenario presence-mismatch
printf '%s\n' '{"result":{"pane":{"pane_id":"w9:p9"}}}' > "$B_RESP/1.out"
run_scenario 'herdr:presence a pane id that does not round-trip is unknown' p_presence presence fmtest 'w1:p1'

new_scenario presence-othererror
printf '%s\n' '{"error":{"code":"internal_error"}}' > "$B_RESP/1.out"
run_scenario 'herdr:presence a NON pane_not_found error is unknown, never dead' p_presence presence fmtest 'w1:p1'

new_scenario presence-garbage
printf '%s\n' 'not json at all' > "$B_RESP/1.out"
run_scenario 'herdr:presence an unparseable response is unknown, never dead' p_presence presence fmtest 'w1:p1'

new_scenario agent-live
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:paneagent a registered IDLE agent is live, not a husk' p_paneagent paneagent fmtest 'w1:p1'

new_scenario agent-blocked
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"blocked"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:paneagent a BLOCKED agent is live, not a husk' p_paneagent paneagent fmtest 'w1:p1'

new_scenario agent-noagent
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$B_RESP/2.out"
run_scenario 'herdr:paneagent a restored agent-less shell is no-agent' p_paneagent paneagent fmtest 'w1:p1'

new_scenario agent-weirdstatus
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"teleporting"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:paneagent an unrecognized agent_status is unknown' p_paneagent paneagent fmtest 'w1:p1'

new_scenario agentstate-missing
printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$B_RESP/1.out"
run_scenario 'herdr:agentstate a gone pane is MISSING (recovery-grade)' p_agentstate agentstate 'fmtest:w1:p1'

new_scenario agentstate-dead
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$B_RESP/2.out"
run_scenario 'herdr:agentstate an agent-free pane is DEAD (recovery-grade)' p_agentstate agentstate 'fmtest:w1:p1'

new_scenario agentstate-alive
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:agentstate a registered agent is ALIVE' p_agentstate agentstate 'fmtest:w1:p1'

new_scenario agentstate-unreadable
printf '%s\n' '{"error":{"code":"internal_error"}}' > "$B_RESP/1.out"
run_scenario 'herdr:agentstate a transient read failure is UNREADABLE, never dead' p_agentstate agentstate 'fmtest:w1:p1'

new_scenario agentalive-missing
printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$B_RESP/1.out"
run_scenario 'herdr:agentalive a missing endpoint collapses to dead' p_agentalive agentalive 'fmtest:w1:p1'

new_scenario agentalive-unreadable
printf '%s\n' '{"error":{"code":"internal_error"}}' > "$B_RESP/1.out"
run_scenario 'herdr:agentalive an unreadable endpoint is unknown, never dead' p_agentalive agentalive 'fmtest:w1:p1'

new_scenario endpointgone-yes
printf '%s\n' '{"error":{"code":"pane_not_found"}}' > "$B_RESP/1.out"
run_scenario 'herdr:endpointgone only a structured not-found proves the endpoint gone' p_endpointgone endpointgone 'fmtest:w1:p1'

new_scenario endpointgone-present
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/1.out"
run_scenario 'herdr:endpointgone a present pane refuses record removal' p_endpointgone endpointgone 'fmtest:w1:p1'

new_scenario endpointgone-badtarget
run_scenario 'herdr:endpointgone a malformed target is ambiguity, not proof' p_endpointgone endpointgone 'notarget'

# --- capture and the pane-read line bound -------------------------------------
p_capture() { run_oracle fm_backend_herdr_capture "$1" "$2"; rstrip_oracle; B_ANSWER=$ORACLE; }

new_scenario capture-trim
printf 'l1\nl2\nl3\nl4\nl5\n' > "$B_RESP/1.out"
run_scenario 'herdr:capture the local tail trim keeps only the requested bound' p_capture capture 'fmtest:w1:p1' 2

new_scenario capture-all
printf 'l1\nl2\n' > "$B_RESP/1.out"
run_scenario 'herdr:capture a bound above the content returns everything' p_capture capture 'fmtest:w1:p1' 50

new_scenario capture-default
printf 'only\n' > "$B_RESP/1.out"
run_scenario 'herdr:capture a non-numeric bound falls back to the default' p_capture capture 'fmtest:w1:p1' 'abc'

# --- the composer classifier --------------------------------------------------
p_composer() { run_oracle fm_backend_herdr_composer_state "$1"; B_ANSWER=$ORACLE; }

new_scenario composer-bordered-empty
printf '%s\n' "${GLYPH_BAR}   ${GLYPH_BAR}" > "$B_RESP/1.out"
run_scenario 'herdr:composer an empty bordered composer is empty' p_composer composer 'fmtest:w1:p1'

new_scenario composer-bordered-pending
printf '%s\n' "${GLYPH_BAR} typed text ${GLYPH_BAR}" > "$B_RESP/1.out"
run_scenario 'herdr:composer a bordered composer with text is pending' p_composer composer 'fmtest:w1:p1'

new_scenario composer-shellprompt
printf '%s\n' '$ ' > "$B_RESP/1.out"
run_scenario 'herdr:composer a bare shell prompt is UNKNOWN, never empty' p_composer composer 'fmtest:w1:p1'

new_scenario composer-noread
printf '1\n' > "$B_RESP/1.exit"
printf '1\n' > "$B_RESP/2.exit"
run_scenario 'herdr:composer an unreadable pane is unknown' p_composer composer 'fmtest:w1:p1'

new_scenario composer-badtarget
run_scenario 'herdr:composer a malformed target is unknown' p_composer composer 'notarget'

# --- native submit confirmation -----------------------------------------------
p_waitworking() { run_oracle fm_backend_herdr_wait_for_working "$1" "$2" "$3" "$4"; B_ANSWER=$ORACLE; }

new_scenario wait-busy
printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$B_RESP/1.out"
run_scenario 'herdr:waitworking a submit-active status returns busy immediately' p_waitworking waitworking fmtest 'w1:p1' 0 1

new_scenario wait-idle
printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:waitworking a legibly idle window returns idle' p_waitworking waitworking fmtest 'w1:p1' 0 2

new_scenario wait-unknown
printf '1\n' > "$B_RESP/1.exit"
printf '1\n' > "$B_RESP/2.exit"
run_scenario 'herdr:waitworking a window that never read at all is unknown' p_waitworking waitworking fmtest 'w1:p1' 0 2

new_scenario wait-blockedbusy
printf '%s\n' '{"result":{"agent":{"agent_status":"blocked"}}}' > "$B_RESP/1.out"
run_scenario 'herdr:waitworking a blocked status counts as submit-active' p_waitworking waitworking fmtest 'w1:p1' 0 1

# --- send/submit: text typed ONCE, Enter retried ------------------------------
p_submit() { run_oracle fm_backend_herdr_send_text_submit "$1" "$2" "$3" "$4" "$5"; B_ANSWER=$ORACLE; }

new_scenario submit-confirmed
: > "$B_RESP/1.out"                                                       # send-text
printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$B_RESP/2.out"    # baseline
: > "$B_RESP/3.out"                                                       # send-keys Enter
printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$B_RESP/4.out" # confirm
run_scenario 'herdr:submit an idle baseline confirmed by native state reports empty' \
  p_submit submit 'fmtest:w1:p1' 'hello captain' 2 0 0

new_scenario submit-sendfailed
printf '1\n' > "$B_RESP/1.exit"
run_scenario 'herdr:submit a failed literal send reports send-failed and never presses Enter' \
  p_submit submit 'fmtest:w1:p1' 'hello' 2 0 0

new_scenario submit-badtarget
run_scenario 'herdr:submit a malformed target reports unknown' p_submit submit 'notarget' 'hello' 2 0 0

# --- the 2026-07-02 seeded-default-tab prune safety boundary ------------------
p_prune() { run_yesno fm_backend_herdr_workspace_prune_seeded_default_tab "$1" "$2" "$3"; B_ANSWER=$YESNO; }

new_scenario prune-adopted
run_scenario 'herdr:prune an ADOPTED workspace (empty seeded tab id) never queries anything' \
  p_prune prune fmtest w1 ''

new_scenario prune-onlytab
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:prune the seeded tab is never closed while it is the only tab' \
  p_prune prune fmtest w1 'w1:t1'

new_scenario prune-relabelled
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"captain"},{"tab_id":"w1:t2","label":"fm-x"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:prune a seeded tab that was renamed is never closed' \
  p_prune prune fmtest w1 'w1:t1'

new_scenario prune-working
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"},{"tab_id":"w1:t2","label":"fm-x"}]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}' > "$B_RESP/2.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$B_RESP/3.out"
run_scenario 'herdr:prune a seed pane hosting a WORKING agent is never closed' \
  p_prune prune fmtest w1 'w1:t1'

new_scenario prune-proceeds
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1"},{"tab_id":"w1:t2","label":"fm-x"}]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}' > "$B_RESP/2.out"
printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$B_RESP/3.out"
: > "$B_RESP/4.out"
run_scenario 'herdr:prune an idle seed pane beside a real task tab is pruned' \
  p_prune prune fmtest w1 'w1:t1'

# --- workspace placement ------------------------------------------------------
#
# The --cwd argument is passed in its NATIVE spelling, because that is the shape
# that reaches herdr in production on this platform in BOTH worlds and nothing
# else is comparable. herdr is a native binary, so MSYS rewrites a POSIX --cwd on
# the way into it from bash; PowerShell performs no such rewrite, which is why
# ConvertTo-FmBackendHerdrCwdArgument now does it explicitly (a POSIX --cwd is not
# refused by herdr - it silently starts the pane in the user's home instead).
# Driving both worlds with an already-native path leaves the argv comparison
# asserting the COMMAND SHAPE rather than which of the two path spellings each
# world happened to be handed.
CWD_X=$(fm_test_native_path /tmp/x)
CWD_W=$(fm_test_native_path /tmp/w)
p_wsensure() {
  local status err=''
  fm_backend_herdr_workspace_ensure "$1" "$2" "$3" >/dev/null 2>"$ERRCAP" && status=0 || status=$?
  IFS= read -r -d '' err < "$ERRCAP" || true
  B_ANSWER="$status|$FM_BACKEND_HERDR_WS_ID|$FM_BACKEND_HERDR_WS_SEEDED_TAB_ID|${err%%$'
'*}"
}

new_scenario wsensure-adopt
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:wsensure a single label match is ADOPTED with no seeded tab id' \
  p_wsensure wsensure fmtest "$CWD_X" launcher-home

new_scenario wsensure-duplicate
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:wsensure two same-labeled home workspaces REFUSE rather than guess' \
  p_wsensure wsensure fmtest "$CWD_X" launcher-home

new_scenario wsensure-create
printf '%s\n' '{"result":{"workspaces":[]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"workspace":{"workspace_id":"w5"},"tab":{"tab_id":"w5:t1"},"root_pane":{"pane_id":"w5:p1"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:wsensure a created workspace carries its own seeded tab id' \
  p_wsensure wsensure fmtest "$CWD_X" launcher-home

new_scenario wsensure-createfail
printf '%s\n' '{"result":{"workspaces":[]}}' > "$B_RESP/1.out"
printf '1\n' > "$B_RESP/2.exit"
run_scenario 'herdr:wsensure a failed create reports the generic failure code' \
  p_wsensure wsensure fmtest "$CWD_X" launcher-home

new_scenario wsensure-otherhome
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:wsensure an other-home launch never inherits the launcher workspace' \
  p_wsensure wsensure fmtest "$CWD_X" other-home

# --- task tab creation, husk replacement, duplicate refusal -------------------
p_createtask() {
  local status
  run_oracle fm_backend_herdr_create_task "$1" "$2" "$3" "$4"
  status=$ORACLE_RC
  [ "$status" -eq 0 ] || status=1
  B_ANSWER="$status|$ORACLE|${ORACLE_ERR%%$'
'*}"
}

new_scenario create-clean
printf '%s\n' '{"result":{"tabs":[]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}' > "$B_RESP/2.out"
run_scenario 'herdr:createtask a clean workspace yields the tab and pane ids' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

new_scenario create-liveduplicate
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-x"}]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$B_RESP/2.out"
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/3.out"
printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$B_RESP/4.out"
run_scenario 'herdr:createtask a LIVE same-labeled tab refuses rather than replacing' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

new_scenario create-unreadableduplicate
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-x"}]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$B_RESP/2.out"
printf '%s\n' '{"error":{"code":"internal_error"}}' > "$B_RESP/3.out"
run_scenario 'herdr:createtask an UNREADABLE duplicate refuses; only a confirmed husk is replaced' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

new_scenario create-huskreplace
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-x"}]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$B_RESP/2.out"
printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$B_RESP/3.out"
printf '%s\n' '{"error":{"code":"agent_not_found"}}' > "$B_RESP/4.out"
printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}' > "$B_RESP/5.out"
: > "$B_RESP/6.out"
printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t9","label":"fm-x"}]}}' > "$B_RESP/7.out"
run_scenario 'herdr:createtask a confirmed husk is replaced AFTER the new tab exists' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

new_scenario create-parsefail
printf '%s\n' '{"result":{"tabs":[]}}' > "$B_RESP/1.out"
printf '%s\n' '{"result":{"tab":{}}}' > "$B_RESP/2.out"
run_scenario 'herdr:createtask an incomplete create response is refused loudly' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

new_scenario create-badtablist
printf '%s\n' '{"result":{}}' > "$B_RESP/1.out"
run_scenario 'herdr:createtask an unparseable tab listing is refused loudly' \
  p_createtask createtask 'fmtest:w1' 'fm-x' "$CWD_W" ''

# --- launcher identity: the exact parent, or a refusal ------------------------
p_launcher() {
  local status err=''
  fm_backend_herdr_launcher_identity "$1" >/dev/null 2>"$ERRCAP" && status=0 || status=$?
  IFS= read -r -d '' err < "$ERRCAP" || true
  B_ANSWER="$status|$FM_BACKEND_HERDR_LAUNCHER_PANE_ID|$FM_BACKEND_HERDR_LAUNCHER_TAB_ID|$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID|${err%%$'
'*}"
}

new_scenario launcher-nopane
run_scenario 'herdr:launcher no injected pane means there is no parent to inherit' p_launcher launcher fmtest

# --- discovery ----------------------------------------------------------------
p_paneforTab() {
  run_oracle fm_backend_herdr_pane_for_tab "$1" "$2" "$3"
  rstrip_oracle
  [ "$ORACLE_RC" -eq 0 ] || ORACLE='<none>'
  B_ANSWER=$ORACLE
}
p_workspacefind() { run_oracle fm_backend_herdr_workspace_find "$1"; rstrip_oracle; B_ANSWER=$ORACLE; }

new_scenario paneforTab-hit
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:paneforTab a tab id resolves to its own root pane' p_paneforTab paneforTab fmtest w1 'w1:t2'

new_scenario paneforTab-miss
printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:paneforTab an unmatched tab resolves to nothing' p_paneforTab paneforTab fmtest w1 'w1:t9'

new_scenario workspacefind-first
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"firstmate"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:workspacefind the read-only recovery lookup keeps first-match' p_workspacefind workspacefind fmtest

new_scenario workspacefind-none
printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"someone-else"}]}}' > "$B_RESP/1.out"
run_scenario 'herdr:workspacefind a non-matching label finds nothing' p_workspacefind workspacefind fmtest

# --- the presentation projection gate, part 2: the whole decision -------------
#
# This is the case the missing coverage would have caught: with NO config file at
# all, on a release at the floor, the answer must be ON. It needs its own fake
# because the shared Phase B fake answers `status --json` with one hard-coded
# below-floor release, and this decision reads exactly that response.
make_release_fakebin() {  # <dir> <protocol> <version>
  local fb="$1/fakebin" doc
  mkdir -p "$fb"
  doc="{\"client\":{\"version\":\"$3\",\"protocol\":$2},\"server\":{\"running\":true,\"version\":\"$3\",\"protocol\":$2}}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'raw=\n'
    printf 'for a in "$@"; do raw="$raw $a"; done\n'
    printf 'printf %%s\\\\n "${raw# }" >> "$FM_HERDR_LOG"\n'
    printf '[ "${1:-}" = status ] || exit 3\n'
    if [ "$2" = unreadable ]; then
      printf 'exit 4\n'
    else
      printf 'printf %%s\\\\n %s\n' "'$doc'"
    fi
  } > "$fb/herdr"
  chmod +x "$fb/herdr"
  {
    printf '@echo off\r\n'
    printf '>>"%%FM_HERDR_LOG%%" echo %%*\r\n'
    printf 'if /I "%%~1"=="status" (\r\n'
    if [ "$2" = unreadable ]; then
      printf '  exit /b 4\r\n'
    else
      printf '  echo %s\r\n' "$doc"
      printf '  exit /b 0\r\n'
    fi
    printf ')\r\n'
    printf 'exit /b 3\r\n'
  } > "$fb/herdr.cmd"
  printf '%s\n' "$fb"
}

# Two state dirs, one per world: the below-floor warning is deduplicated by a
# marker FILE, so a shared dir would let whichever world ran first silence the
# other and the comparison would assert nothing.
PSTATE_BASH="$TMP_ROOT/presstate-bash"
PSTATE_PS="$TMP_ROOT/presstate-ps"
mkdir -p "$PSTATE_BASH" "$PSTATE_PS"
PSTATE_PS_N=$(fm_test_native_path "$PSTATE_PS")

# One release scenario: its own fakebin and its own per-world command log. The
# fake answers only `status --json`, which is the whole of this decision's CLI
# surface, so there is no numbered-response counter to keep.
PR_DIR=''
PR_FB=''
PR_ENV=''
PR_LOG_BASH=''
PR_LOG_PS=''
new_release_scenario() {  # <name> <protocol> <version>
  PR_DIR="$TMP_ROOT/pres-$1"
  mkdir -p "$PR_DIR"
  PR_FB=$(make_release_fakebin "$PR_DIR" "$2" "$3")
  PR_LOG_BASH="$PR_DIR/log.bash"
  PR_LOG_PS="$PR_DIR/log.ps"
  : > "$PR_LOG_BASH"
  : > "$PR_LOG_PS"
  PR_ENV="PATH=$(fm_test_native_path "$PR_FB")${US}FM_HERDR_LOG=$(fm_test_native_path "$PR_LOG_PS")${US}FM_T_SDIR2=$PSTATE_PS_N"
}

# run_pres_case drives fm_backend_herdr_presentation_enabled - the ONE gate
# fm-spawn consults - and compares the verdict together with the first line of any
# warning, so a decision that changed WORDING fails as loudly as one that changed
# answer. The config dir comes from the CURRENT make_pres_config state and is
# carried in the record, because a config file rewritten between cases would reach
# the batched PowerShell side only in its final form.
run_pres_case() {  # <label>
  local verdict err
  PATH="$PR_FB:$BASE_PATH"
  FM_HERDR_LOG="$PR_LOG_BASH" run_yesno fm_backend_herdr_presentation_enabled "$PCFG_DIR" "$PSTATE_BASH"
  PATH="$BASE_PATH"
  IFS= read -r -d '' err < "$ERRCAP" || true
  if [ "$YESNO" = yes ]; then verdict=on; else verdict=off; fi
  add_case "$1" "$verdict|$(first_line "$err")" presenabled \
    "$PR_ENV${US}FM_T_CDIR=$PCFG_DIR_N" '' '' '' '' '' ''
  LOG_PAIRS+=("$PR_LOG_BASH|$PR_LOG_PS|$1")
}

AT_FLOOR_PROTOCOL=19
AT_FLOOR_VERSION=0.8.0
BELOW_FLOOR_PROTOCOL=17
BELOW_FLOOR_VERSION=0.7.5

# THE REGRESSION CASE. Absent flag, release at the floor: the projection is ON.
make_pres_config absent
new_release_scenario absent-at-floor "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an ABSENT flag at the floor projects by default'

# Absent flag below the floor: flat fallback, with one naming warning.
new_release_scenario absent-below-floor "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an ABSENT flag below the floor falls back flat and warns'
# ...and the SAME release does not warn twice, because the marker is per release.
run_pres_case 'herdr:presenabled the below-floor warning is one per home per release'
# A different release IS announced again.
new_release_scenario absent-older-floor 16 0.7.3
run_pres_case 'herdr:presenabled a changed below-floor release re-announces itself'

# An unreadable release is indeterminate, not "below": different words, same flat
# fallback, and the twin must not guess from the client alone.
new_release_scenario absent-unreadable unreadable unreadable
run_pres_case 'herdr:presenabled an unreadable release falls back flat with its own wording'

# A deliberate opt-in is never silently downgraded below the floor, in either of
# its two spellings, and it must not warn - a migrated home would warn on every
# spawn otherwise.
make_pres_config empty ''
new_release_scenario empty-below-floor "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an EMPTY flag is a deliberate opt-in below the floor'
make_pres_config on "on$LF"
new_release_scenario on-below-floor "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an explicit on survives the floor'
new_release_scenario on-unreadable unreadable unreadable
run_pres_case 'herdr:presenabled an explicit on does not even read the release'

# An explicit off opts out regardless of release.
make_pres_config off "off$LF"
new_release_scenario off-at-floor "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an explicit off opts out at the floor'
make_pres_config offpadded "  OFF  $LF"
new_release_scenario off-folded-at-floor "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION"
run_pres_case 'herdr:presenabled a padded upper-case off opts out too'

# A typo is not a deliberate opt-in: it warns and then FOLLOWS THE DEFAULT, which
# means on at the floor and flat below it.
make_pres_config bogus "disabled$LF"
new_release_scenario bogus-at-floor "$AT_FLOOR_PROTOCOL" "$AT_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an unrecognized value warns and keeps the default on'
new_release_scenario bogus-below-floor "$BELOW_FLOOR_PROTOCOL" "$BELOW_FLOOR_VERSION"
run_pres_case 'herdr:presenabled an unrecognized value below the floor follows the flat default'

unset FM_BACKEND_HERDR_SCRIPTED_CLI
PATH="$BASE_PATH"

# =============================================================================
# THE ONE pwsh DRIVER. Every case above is evaluated here, in a single process.
# =============================================================================
cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_MOD_HERDR -Force

$FS = [char]1
$RS = [char]2
$US = [char]31
$NONE = '<none>'

# Every environment variable any case touches, snapshotted so a per-case setting
# cannot leak into the next case (the batch trap the port doc names first).
$managed = @('FM_HOME', 'HERDR_SESSION', 'FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP',
    'FM_BACKEND_HERDR_EVENT_READER', 'FM_BACKEND_HERDR_SCRIPTED_CLI',
    'FM_HERDR_LOG', 'FM_HERDR_COUNTER', 'FM_HERDR_RESPONSES',
    'FM_T_JDIR', 'FM_T_SDIR', 'FM_T_CDIR', 'FM_T_SDIR2',
    'FM_BACKEND_HERDR_COMPOSER_LINES',
    'FM_BACKEND_HERDR_SUBMIT_POLLS')
$original = @{}
foreach ($k in $managed) { $original[$k] = [Environment]::GetEnvironmentVariable($k) }
$originalPath = $env:PATH

function Get-Yesno {
    param([bool]$Value)
    if ($Value) { return 'yes' }
    return 'no'
}

function Get-FirstLine {
    param([AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $i = $Text.IndexOf("`n")
    if ($i -ge 0) { return $Text.Substring(0, $i) }
    return $Text
}

# [object], NOT [string]: binding $null to a [string] parameter COERCES it to the
# empty string, so a typed helper could never tell "no answer" from "an empty
# answer" - and several verdicts here turn on exactly that difference.
function Get-OrNone {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $NONE }
    return [string]$Value
}

function Get-JournalPath {
    param([string]$Leaf)
    return (Join-Path $env:FM_T_JDIR $Leaf)
}

function Get-SnapshotAnswer {
    param([string]$Journal, [AllowEmptyString()][string]$TaskId)
    $s = Get-FmBackendHerdrProjectionJournalSnapshot -Journal $Journal -TaskId $TaskId
    if ($null -eq $s) { return $NONE }
    return @($s.Version, $s.TaskId, $s.ProjectionId, $s.Home, $s.Session, $s.WorkspaceId,
        $s.TabId, $s.PaneId, $s.ParentWorkspaceId, $s.ParentLabel, $s.WorkspaceLabel,
        $s.TaskLabel) -join '|'
}

function Clear-EscalationMarker {
    param([string]$StateDir)
    foreach ($f in [System.IO.Directory]::EnumerateFiles($StateDir, '.herdr-escalated-*')) {
        try { [System.IO.File]::Delete($f) } catch { $null = $_ }
    }
}

$text = [System.IO.File]::ReadAllText($env:FM_CASES, [System.Text.Encoding]::UTF8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++
    $f = @($record.Split($FS))
    if ($f.Count -ne 8) {
        [void]$out.Append($index).Append($FS).Append("BAD-FIELD-COUNT:$($f.Count)").Append($RS)
        continue
    }

    foreach ($k in $managed) { [Environment]::SetEnvironmentVariable($k, $original[$k]) }
    $env:PATH = $originalPath
    foreach ($entry in @($f[1].Split($US))) {
        if ($entry -ceq '') { continue }
        $eq = $entry.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $entry.Substring(0, $eq)
        $v = $entry.Substring($eq + 1)
        if ($k -ceq 'PATH') { $env:PATH = $v + ';' + $originalPath }
        else { [Environment]::SetEnvironmentVariable($k, $v) }
    }

    # stderr is captured per case rather than for the whole run, so a refusal
    # stays attributable to the case that produced it.
    $sw = [System.IO.StringWriter]::new()
    $oldErr = [Console]::Error
    [Console]::SetError($sw)
    $result = ''
    try {
        switch -CaseSensitive ($f[0]) {
            'wslabel' { $result = Get-FmBackendHerdrWorkspaceLabel }
            'session' { $result = Get-FmBackendHerdrSession }
            'target' {
                $t = Get-FmBackendHerdrTarget $f[2]
                if ($null -eq $t) { $result = $NONE } else { $result = $t.Session + '|' + $t.Pane }
            }
            'key' { $result = ConvertTo-FmBackendHerdrKey $f[2] }
            'prespref' { $result = Get-FmBackendHerdrPresentationPreference $env:FM_T_CDIR }
            'versionatleast' { $result = Test-FmBackendHerdrVersionAtLeast $f[2] $f[3] }
            'floorverdict' { $result = Get-FmBackendHerdrReleaseFloorVerdict $f[2] $f[3] }
            'presenabled' {
                $decision = Test-FmBackendHerdrPresentationEnabled $env:FM_T_CDIR $env:FM_T_SDIR2
                if ([bool]$decision.Enabled) { $result = 'on' } else { $result = 'off' }
            }
            'concise' { $result = Get-FmBackendHerdrProjectionConciseTaskLabel $f[2] }
            'projlabel' { $result = Get-FmBackendHerdrProjectionWorkspaceLabel -TaskId $f[2] -ProjectionId $f[3] }
            'classify' { $result = Get-FmBackendHerdrAgentStatusClass $f[2] }
            'classifysubmit' { $result = Get-FmBackendHerdrSubmitStatusClass $f[2] }
            'marker' { $result = Get-FmBackendHerdrEscalationMarker -StateDir $f[2] -Window $f[3] }
            'budget' { $result = Get-FmBackendHerdrSubmitConfirmBudget $f[2] }
            'pisep' { $result = Get-Yesno (Test-FmBackendHerdrPiSeparatorRow $f[2]) }
            'picomposer' {
                $p = Get-FmBackendHerdrPiComposer $f[2]
                $result = @(
                    $(if ($p.Found) { '1' } else { '0' }),
                    $(if ($p.Valid) { '1' } else { '0' }),
                    $p.OpenLine, $p.Line, $p.LastSeparatorLine, $p.Content) -join '|'
            }
            'borderrow' {
                if (Test-FmBackendHerdrBorderedRow $f[2]) { $result = 'bordered' } else { $result = 'other' }
            }
            'cut' { $result = Get-FmBackendHerdrCutField -Line $f[2] -Field ([int]$f[3]) }
            'tail' { $result = Get-FmBackendHerdrTailLine -Text $f[2] -Count ([int]$f[3]) }
            'normhost' { $result = ConvertTo-FmBackendHerdrHostPath $f[2] }
            'canonsock' { $result = Get-OrNone (Get-FmBackendHerdrCanonicalSocketPath $f[2]) }
            'locknamespace' { $result = Get-FmBackendHerdrPresentationLockNamespace }
            'lockhash' { $result = Get-FmBackendHerdrSessionLockKey -Session $f[2] -Socket $f[3] }
            'event' { $result = ConvertTo-FmBackendHerdrEventRecord $f[2] $f[3] $f[4] $f[5] }
            'readercmd' {
                $cmd = @(Get-FmBackendHerdrEventReaderCommand)
                if ($cmd.Count -eq 0) { $result = '<native>' } else { $result = ($cmd -join "`n") }
            }
            'journalsnapshot' { $result = Get-SnapshotAnswer -Journal (Get-JournalPath $f[2]) -TaskId $f[3] }
            'journaltoken' {
                $result = Get-OrNone (Get-FmBackendHerdrProjectionJournalToken -Journal (Get-JournalPath $f[2]) -TaskId $f[3])
            }
            'journalfield' {
                $result = Get-OrNone (Get-FmBackendHerdrProjectionJournalField -Journal (Get-JournalPath $f[2]) -Key $f[3])
            }
            'journalbind' {
                $j = Get-JournalPath $f[2]
                $ok = Set-FmBackendHerdrProjectionJournalBinding -Journal $j -TaskId $f[3] `
                    -FmHome '/w/home' -Session 'fmtest' -WorkspaceId 'w7' -TabId 'w7:t1' -PaneId 'w7:p1' `
                    -ParentWorkspaceId 'w1' -ParentLabel 'firstmate' `
                    -WorkspaceLabel (Get-FmBackendHerdrProjectionWorkspaceLabel -TaskId $f[3] -ProjectionId (Get-FmBackendHerdrProjectionJournalToken -Journal $j -TaskId $f[3])) `
                    -TaskLabel "fm-$($f[3])"
                if ($ok) { $result = [System.IO.File]::ReadAllText($j) } else { $result = $NONE }
            }
            'journalbind2' {
                $j = Get-JournalPath $f[2]
                $ok = Set-FmBackendHerdrProjectionJournalBinding -Journal $j -TaskId $f[3] `
                    -FmHome '/w/home' -Session 'fmtest' -WorkspaceId 'w9' -TabId 'w9:t1' -PaneId 'w9:p1' `
                    -ParentWorkspaceId 'w1' -ParentLabel 'firstmate' `
                    -WorkspaceLabel 'irrelevant' -TaskLabel "fm-$($f[3])"
                if ($ok) { $result = 'yes' } else { $result = 'no' }
            }
            'journalreplace' {
                $j = Get-JournalPath $f[2]
                $ok = Update-FmBackendHerdrProjectionJournalEndpoint -Journal $j -TaskId $f[3] `
                    -OldTabId $f[4] -OldPaneId $f[5] -NewTabId $f[6] -NewPaneId $f[7]
                if ($ok) { $result = [System.IO.File]::ReadAllText($j) } else { $result = $NONE }
            }
            'journalreplace2' {
                $j = Get-JournalPath $f[2]
                $ok = Update-FmBackendHerdrProjectionJournalEndpoint -Journal $j -TaskId $f[3] `
                    -OldTabId $f[4] -OldPaneId $f[5] -NewTabId $f[6] -NewPaneId $f[7]
                if ($ok) { $result = 'yes' } else { $result = 'no' }
            }
            'journalcreate' {
                $token = New-FmBackendHerdrProjectionJournal -StateDir $env:FM_T_JDIR -TaskId $f[2]
                if ([string]::IsNullOrEmpty($token)) { $result = $NONE }
                elseif ($token.Length -ne 22 -or $token -notmatch '^[A-Za-z0-9_-]+$') { $result = '<badtoken>' }
                else {
                    $j = Get-JournalPath "$($f[2]).herdr-presentation"
                    # The bash oracle reads the file with `read -d ''`, which
                    # drops the trailing newline; TrimEnd matches that exactly.
                    $body = [System.IO.File]::ReadAllText($j)
                    $result = $body.Replace($token, '<tok22>')
                }
            }
            'journalcreate2' {
                [void](New-FmBackendHerdrProjectionJournal -StateDir $env:FM_T_JDIR -TaskId $f[2])
                $result = ''
            }
            'transitionseq' {
                $s = $env:FM_T_SDIR
                Clear-EscalationMarker $s
                $blocked = ConvertTo-FmBackendHerdrEventRecord 'w1:p2' 'w1' 'blocked' 'claude'
                $working = ConvertTo-FmBackendHerdrEventRecord 'w1:p2' 'w1' 'working' 'claude'
                $idle = ConvertTo-FmBackendHerdrEventRecord 'w1:p2' 'w1' 'idle' 'claude'
                $emptyPane = ConvertTo-FmBackendHerdrEventRecord '' 'w1' 'blocked' 'claude'
                $hit = { param($r) if ([string]::IsNullOrEmpty((Select-FmBackendHerdrTransition -StateDir $s -Session 'fmtest' -Record $r))) { 'miss' } else { 'hit' } }
                $parts = @()
                $parts += (& $hit $blocked)
                $parts += $(if (Save-FmBackendHerdrTransition -StateDir $s -Session 'fmtest' -Record $blocked) { 'committed' } else { 'nocommit' })
                $parts += (& $hit $blocked)
                $parts += (& $hit $working)
                $parts += (& $hit $blocked)
                $parts += (& $hit $idle)
                $parts += (& $hit $emptyPane)
                $parts += $(if (Clear-FmBackendHerdrTransition -StateDir $s -Window 'fmtest:w1:p2') { 'cleared' } else { 'noclear' })
                $parts += $(if (Clear-FmBackendHerdrTransition -StateDir $s -Window '') { 'cleared' } else { 'noclear' })
                $result = $parts -join '|'
            }
            'applytransition' {
                Clear-EscalationMarker $env:FM_T_SDIR
                $result = Get-OrNone (Select-FmBackendHerdrTransition -StateDir $env:FM_T_SDIR -Session $f[2] -Record $f[3])
            }
            'presence' { $result = Get-FmBackendHerdrPanePresenceState -Session $f[2] -PaneId $f[3] }
            'paneagent' { $result = Get-FmBackendHerdrPaneAgentState -Session $f[2] -PaneId $f[3] }
            'agentstate' { $result = Get-FmBackendHerdrAgentState $f[2] }
            'agentalive' { $result = Get-FmBackendHerdrAgentAlive $f[2] }
            'endpointgone' { $result = Get-Yesno (Test-FmBackendHerdrEndpointGone $f[2]) }
            'capture' {
                $c = Get-FmBackendHerdrCapture -Target $f[2] -Lines $f[3]
                if ($null -eq $c) { $result = '' } else { $result = $c }
            }
            'composer' { $result = Get-FmBackendHerdrComposerState $f[2] }
            'waitworking' {
                $result = Wait-FmBackendHerdrWorking -Session $f[2] -PaneId $f[3] -Budget $f[4] -Polls $f[5]
            }
            'submit' {
                $result = Send-FmBackendHerdrTextSubmit -Target $f[2] -Text $f[3] -Retries $f[4] `
                    -EnterSleep $f[5] -Settle $f[6]
            }
            'prune' {
                $result = Get-Yesno (Remove-FmBackendHerdrSeededDefaultTab -Session $f[2] `
                        -WorkspaceId $f[3] -SeededTabId $f[4])
            }
            'wsensure' {
                $r = Initialize-FmBackendHerdrWorkspace -Session $f[2] -WorkingDirectory $f[3] -Relationship $f[4]
                $result = @($r.Code, $r.WorkspaceId, $r.SeededTabId) -join '|'
            }
            'createtask' {
                $o = New-FmBackendHerdrTask -Container $f[2] -Label $f[3] -WorkingDirectory $f[4] `
                    -SeededDefaultTabId $f[5]
                if ($null -eq $o) { $result = '1|' } else { $result = "0|$o" }
            }
            'launcher' {
                $r = Get-FmBackendHerdrLauncherIdentity $f[2]
                $result = @($r.Code, $r.PaneId, $r.TabId, $r.WorkspaceId) -join '|'
            }
            'paneforTab' {
                $result = Get-OrNone (Get-FmBackendHerdrPaneForTab -Session $f[2] -WorkspaceId $f[3] -TabId $f[4])
            }
            'workspacefind' { $result = Get-FmBackendHerdrWorkspace $f[2] }
            default { $result = "UNKNOWN-OP:$($f[0])" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    } finally {
        [Console]::SetError($oldErr)
    }
    $errText = $sw.ToString()

    # The ops whose bash twin publishes a diagnostic alongside its value carry the
    # first stderr line in the same field, so a refusal that changed WORDING fails
    # as loudly as one that changed verdict.
    switch -CaseSensitive ($f[0]) {
        'journalcreate2' { $result = Get-FirstLine $errText }
        'prespref' { $result = $result + '|' + (Get-FirstLine $errText) }
        'presenabled' { $result = $result + '|' + (Get-FirstLine $errText) }
        'wsensure' { $result = $result + '|' + (Get-FirstLine $errText) }
        'createtask' { $result = $result + '|' + (Get-FirstLine $errText) }
        'launcher' { $result = $result + '|' + (Get-FirstLine $errText) }
        default { }
    }

    [void]$out.Append($index).Append($FS).Append($result).Append($RS)
}

[Console]::Out.Write($out.ToString())
PS1

phase 'evaluating every case in one pwsh'

export FM_MOD_HERDR="$MOD_HERDR_N" FM_CASES="$(fm_test_native_path "$CASES")"

if ! pwsh -NoProfile -File "$(fm_test_native_path "$DRIVER")" > "$RESULTS" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A clean run is also a SILENT run. Every diagnostic a case produces is captured
# per case, so anything reaching the real stderr is a module warning (an
# unapproved verb, a shadowed command) and a real finding.
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr"$'\n'"$(cat "$DRIVER_ERR")"

SEEN=0
while IFS=$'\001' read -r -d $'\002' idx got; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  norm_paths "${EXPECT[$idx]}"; want=$NORMALIZED
  norm_paths "$got"; have=$NORMALIZED
  assert_same "${LABELS[$idx]}" "$want" "$have"
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] \
  || fail "driver returned $SEEN results for ${#LABELS[@]} cases (a driver that died halfway returns fewer, which must not read as a shorter passing run)"

# --- the herdr command-sequence differential ----------------------------------
#
# The strongest structural assertion in this file: both worlds ran each Phase B
# scenario through their own fake, and every argument vector must match. A twin
# that issued one extra `pane get`, or reordered a verification, shows up here
# even when its final verdict happens to agree. CR is stripped because cmd `echo`
# has no LF-only mode.
LOGGED=0
for pair in "${LOG_PAIRS[@]}"; do
  bash_log=${pair%%|*}
  rest=${pair#*|}
  ps_log=${rest%%|*}
  pair_label=${rest#*|}
  tr -d '\r' < "$bash_log" > "$bash_log.norm"
  tr -d '\r' < "$ps_log" > "$ps_log.norm"
  ASSERTIONS=$((ASSERTIONS + 1))
  if ! diff -u "$bash_log.norm" "$ps_log.norm" > "$bash_log.diff" 2>&1; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}herdr:command-sequence [$pair_label] the two worlds issued different herdr commands
$(cat "$bash_log.diff")
"
  fi
  [ -s "$bash_log.norm" ] && LOGGED=$((LOGGED + 1))
done
ASSERTIONS=$((ASSERTIONS + 1))
if [ "$LOGGED" -lt 30 ]; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}herdr:command-sequence only $LOGGED scenarios issued any herdr command at all; a fake that was never reached would make every Phase B verdict agree vacuously
"
fi

# =============================================================================
# IMPORT HYGIENE, and the two ownership facts a batch driver cannot observe
# about itself.
# =============================================================================
import_out=$(pwsh -NoProfile -Command "Import-Module '$MOD_BACKEND_N' -Force; \$null = Import-FmBackendAdapter 'herdr'" 2>&1)
import_rc=$?
assert_same 'herdr:import the dispatcher loads the adapter silently' '' "$import_out"
assert_same 'herdr:import the dispatcher loads the adapter successfully' 0 "$import_rc"

# Every function the dispatcher's herdr arms call must be resolvable GLOBALLY
# after Import-FmBackendAdapter - that -Global import is the faithful twin of
# bash's `source`, and a missing arm would only surface at the first real spawn.
surface_out=$(pwsh -NoProfile -Command "
Import-Module '$MOD_BACKEND_N' -Force
\$null = Import-FmBackendAdapter 'herdr'
\$missing = @()
foreach (\$n in @('Get-FmBackendHerdrCapture','Send-FmBackendHerdrKey','Send-FmBackendHerdrTextSubmit','Remove-FmBackendHerdrTarget','Get-FmBackendHerdrBusyState','Get-FmBackendHerdrComposerState','Invoke-FmBackendHerdrCli','Get-FmBackendHerdrAgentState','Test-FmBackendHerdrEventsCapable','Wait-FmBackendHerdrTransition','Save-FmBackendHerdrTransition','Clear-FmBackendHerdrTransition')) {
  if (\$null -eq (Get-Command \$n -ErrorAction SilentlyContinue)) { \$missing += \$n }
}
[Console]::Out.Write(\$(if (\$missing.Count -eq 0) { 'complete' } else { \$missing -join ',' }))" 2>&1)
assert_same 'herdr:surface every dispatcher arm resolves after the adapter import' 'complete' "$surface_out"

# fm_backend_herdr_strip_ansi has NO twin in the adapter on purpose: fm-composer-lib
# owns the stripper and a second implementation is exactly the drift this port
# exists to prevent. This asserts the ownership rather than trusting the comment.
# Asserted at SOURCE level, not by asking whether Get-FmComposerPlainText is
# visible after importing the adapter. That earlier form failed for a reason
# that had nothing to do with the property: a properly scoped PowerShell module
# does NOT re-export the commands of a module it imports, so the composer
# function is correctly invisible to the importer while still being the one the
# adapter calls. Visibility was never the contract - SINGLE OWNERSHIP is.
stripper_defined=$(grep -cE '^function [A-Za-z-]*(StripAnsi|PlainText)' "$ROOT/bin/backends/herdr.psm1")
assert_same 'herdr:stripper the adapter defines no competing ANSI stripper' \
  '0' "$stripper_defined"
stripper_used=$(grep -c 'Get-FmComposerPlainText' "$ROOT/bin/backends/herdr.psm1")
assert_not_same 'herdr:stripper the adapter uses the composer-owned stripper' \
  '0' "$stripper_used"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - bin/backends/herdr.psm1 differs from its bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# COUNT is itself asserted. Set from an OBSERVED green run, never a guess.
MIN_ASSERTIONS=339
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - bin/backends/herdr.psm1 matches its bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-backend-herdr-psm1.test.sh: all assertions passed\n'
