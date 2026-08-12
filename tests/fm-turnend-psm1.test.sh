#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Differential test for the four wave-4 turn-end hook twins:
#
#   bin/fm-turnend-guard.ps1        vs bin/fm-turnend-guard.sh
#   bin/fm-turnend-guard-grok.ps1   vs bin/fm-turnend-guard-grok.sh
#   bin/fm-claude-stop-autoarm.ps1  vs bin/fm-claude-stop-autoarm.sh
#   bin/fm-kimi-turnend-hook.ps1    vs bin/fm-kimi-turnend-hook.sh
#
# THE EXIT CODE IS THE INTERFACE, AND IT IS ASYMMETRIC. These four run as
# harness turn-end hooks: 2 BLOCKS the turn ending and 0 allows it. A wrong 2
# can wedge a captain's session; a wrong 0 lets the fleet run unsupervised. So
# this suite compares the exact triple (exit code, stdout, stderr) rather than a
# summarized verdict, and it spends its cases on the decision boundaries -
# scope, the loop guards, the --claude cooperative path, and the bounded block
# budget - rather than on the happy path alone.
#
# THE BLOCK BUDGET IS CHECKED AS A NUMBER, NOT AS A BEHAVIOR. Phase D drives the
# same session id through consecutive blocks and pins the count the durable
# record reaches, together with the fact that exceeding the bound ALONE never
# degrades to an allow: the attended fail-open also needs a verified failure
# episode (the auto-arm's own failure notice plus a failed outcome in its epoch
# ledger), which these fixtures deliberately do not have. A twin that quietly
# changed the bound, or that opened the fail-open on the count alone, would still
# "work" in every other case here.
#
# THE BATCHING RULE (docs/powershell-port.md, "the one rule that decides whether
# a suite finishes"). A bare `pwsh -NoProfile -Command "exit 0"` costs 4.8s on
# the reference host, so a suite that spawns one pwsh per case never finishes -
# it times out at 25-60 minutes with ZERO output and presents as a hang. This
# file therefore writes every PowerShell case to a TSV case file and runs ONE
# pwsh over all of them, joining the two worlds' answers by LABEL. The oracle
# half is fork-bound in the same way, so it prefers bash builtins over
# sed/grep/cut and never uses `$( )` inside a per-assertion helper.
#
# THE BATCHING TRAP THIS SUITE FOUND. fm-common's module body assigns the
# console encoding, and that assignment RESETS [Console]::In and [Console]::Out.
# docs/powershell-port.md records the -Force form of this; the sharper form is
# that it happens on ANY genuine load, including the first import in a batch
# driver and again for a copy of the same module imported from a DIFFERENT
# fixture path. A case that redirected the console and then invoked a script
# whose import triggered a load therefore lost its StringReader before the
# script read it - observed here as the SAME fixture answering 0 on its first
# run and 2 on its third. The driver warms every fixture's modules BEFORE
# redirecting; see Initialize-FixtureModule.
#
# WHAT THE PWSH SIDE STILL SPAWNS, AND WHY THAT IS ACCEPTED. A BLOCKING guard
# case runs bin/fm-supervision-instructions to render its repair line, and the
# Grok adapter's native path runs the shared guard - both are process
# boundaries in production and are left as process boundaries here, because the
# banner bytes those children produce are exactly what this suite compares.
# The case list is sized against that: blocking cases are counted, not sprinkled.
#
# FIXTURES THAT CANNOT BE SHARED, AND WHY EACH IS STILL ONE ASSERTION. Three
# things are spelled differently by the two worlds, and in every case what is
# ASSERTED is identical:
#
#   1. A LIVE HARNESS PROCESS. bash proves session-lock ownership through an
#      MSYS process named `claude` (a copy of bash); PowerShell resolves
#      identity through the native process table, where an MSYS pid is
#      invisible, so it uses a native image named claude.exe. Each world builds
#      its own and each asserts the same inertness or arming decision.
#   2. THE RESOLVED SESSION OWNER. bin/fm-session-lock-lib's two twins start
#      their ancestry walk in different pid spaces (bash at its MSYS $$,
#      PowerShell at its Windows $PID), so the "this session owns the lock"
#      fixture writes whatever THAT world's shared library resolves. The
#      positive case is constructed in both worlds; the discriminating evidence
#      is in the NEGATIVE cases - another live harness, a malformed lock, a
#      missing lock - which are compared directly.
#   3. A RESTRICTED PATH. MSYS and Windows disagree about what a PATH is, so
#      the jq-less fixture names different directories on purpose.
#
# DECLARED DIVERGENCES, ASSERTED RATHER THAN NORMALIZED AWAY:
#
#   A. jq. The bash guard and adapter fail OPEN when jq is missing, because jq
#      is their only JSON reader. The PowerShell twins parse in-process and have
#      nothing to be missing, so on a jq-less host they still classify and still
#      guard. Phase F asserts the difference so the day it changes is loud.
#   B. A MULTI-DOCUMENT payload reaching the GUARD. jq reads a stream, so bash
#      emits one loop-guard answer per document and proceeds with a value that
#      is never the literal "true"; ConvertFrom-Json parses exactly one document
#      and the twin allows instead. Phase F asserts it. (The Grok adapter
#      refuses multi-document payloads in BOTH worlds, and those cases are
#      compared normally in phase C.)
#   D. THE KIMI VALIDATOR'S LINE ENDINGS. Python's stderr is a text stream, so
#      on Windows it writes CRLF. The bash twin inherits that stream and passes
#      the bytes through; the PowerShell twin captures and re-emits them through
#      Write-FmErr, which guarantees LF (contract 1). The wording is compared
#      after stripping CR from the Kimi phase only, and the line-ending
#      difference itself is asserted so it cannot vanish unnoticed.
#   C. `remove` for the Kimi hook cannot succeed on Windows in EITHER world.
#      The shared Python validator refuses a hook script whose mode is not
#      0o700, and Windows chmod is inert, so both twins refuse identically.
#      That is a platform limitation of the shared validator, not a conversion
#      defect, and phase E asserts the two worlds refuse the same way.
#
# NORMALIZATION IS DECLARED AND MINIMAL. Path SPELLINGS are unified (separators
# first, then both spellings of the fixture root collapse to <ROOT>), because
# /tmp/x and C:\Users\...\Temp\x are the SAME LOCATION and comparing the
# spellings would test the MSYS mount table rather than the twin. Pids and epoch
# seconds are never compared raw. Nothing else is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the bash twins' JSON reader)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (the Kimi hook's validator)"; exit 0; }

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-turnend-psm1)

# A stray value for any knob these hooks read would silently disarm whole
# phases, so the base state is pinned rather than assumed.
unset FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_GUARD_GRACE
unset FM_CLAUDE_AUTOARM_SYNC_WAIT_MS FM_CLAUDE_AUTOARM_EPOCH_FRESH FM_CLAUDE_TURNEND_BLOCK_BUDGET
unset GROK_WORKSPACE_ROOT GROK_TURNEND_GUARD_ACTIVE CLAUDE_PROJECT_DIR

# --- record encoding ---------------------------------------------------------
#
# The case file and both answer buffers are TAB-delimited line records, but a
# hook's OUTPUT legitimately contains newlines (every block banner is five
# lines) and a payload may carry tabs. So every value is transport-encoded onto
# the C0 separators, which no case value uses: US separates list items, RS
# stands for LF, GS for CR, FS for TAB.
US=$'\x1f'
RS=$'\x1e'
GS=$'\x1d'
FS=$'\x1c'

# enc <text>: sets ENC. A function with a global out-parameter rather than a
# command substitution, because `$(...)` forks and a fork costs 0.36-3.1s on
# this host under load.
ENC=""
enc() {
  local s=$1
  s=${s//$'\r'/$GS}
  s=${s//$'\n'/$RS}
  s=${s//$'\t'/$FS}
  ENC=$s
}

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

TMP_ROOT_NATIVE=$(to_native "$TMP_ROOT")
TMP_ROOT_FWD=${TMP_ROOT_NATIVE//\\//}
# The THIRD spelling of the same location. bin/fm-supervision-instructions
# renders its repair line with the home in MSYS drive form, so a message quoting
# the fixture root can arrive as /c/Users/... from one world and
# C:/Users/... from the other. Derived from the native spelling rather than
# guessed.
TMP_ROOT_MSYS=$TMP_ROOT_FWD
case $TMP_ROOT_MSYS in
  [A-Za-z]:/*) TMP_ROOT_MSYS="/$(printf '%s' "${TMP_ROOT_MSYS:0:1}" | tr 'A-Z' 'a-z')${TMP_ROOT_MSYS:2}" ;;
esac

# TWO-WORLD FIXTURE ROOTS. Any case that MUTATES its fixture - the --claude
# block budget, every auto-arm epoch and owner lock, every Kimi install - must
# not share that fixture between the worlds, because the oracle runs to
# completion BEFORE the driver starts and would hand the twin a half-spent
# budget or an already-installed config. Sharing one caused exactly that: the
# twin degraded on its third block instead of its fourth, and looked like an
# off-by-one in the bound. w1 is the oracle's tree and w2 is the twin's; the
# comparison collapses the two names so the assertion stays single.
W1="$TMP_ROOT/w1"
W2="$TMP_ROOT/w2"
mkdir -p "$W1" "$W2"

# --- fixtures ----------------------------------------------------------------
#
# Every fixture carries BOTH twins plus every module and library they source, so
# the two worlds run against byte-identical trees and a scoping difference can
# only come from the code under test.
#
# ONE cp per fixture, not one per file: a fork costs 0.36-3.8s here depending on
# contention, and eight fixtures times twenty files would be most of the suite's
# wall clock before a single case ran.
GUARD_FILES=(
  fm-turnend-guard.sh fm-turnend-guard.ps1
  fm-turnend-guard-grok.sh fm-turnend-guard-grok.ps1
  fm-claude-stop-autoarm.sh fm-claude-stop-autoarm.ps1
  fm-supervision-instructions.sh fm-supervision-instructions.ps1
  fm-harness.sh fm-harness.ps1
  fm-lock.sh fm-lock.ps1
  fm-operational-input.sh fm-operational-input.psm1
  fm-primary-scope-lib.sh fm-primary-scope-lib.psm1
  fm-supervision-lib.sh fm-supervision-lib.psm1
  fm-wake-lib.sh fm-wake-lib.psm1
  fm-session-lock-lib.sh fm-session-lock-lib.psm1
  fm-psproc-lib.sh fm-psproc-lib.psm1
  fm-lock-lib.sh fm-lock-lib.psm1
  fm-classify-lib.sh fm-classify-lib.psm1
  fm-kimi-turnend-hook.sh fm-kimi-turnend-hook.ps1
  fm-common.psm1
)
GUARD_SOURCES=()
for guard_file in "${GUARD_FILES[@]}"; do
  [ -f "$ROOT/bin/$guard_file" ] || fail "missing source file bin/$guard_file"
  GUARD_SOURCES+=("$ROOT/bin/$guard_file")
done

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "${GUARD_SOURCES[@]}" "$dir/bin/"
  chmod +x "$dir/bin"/*.sh
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
}

make_primary_fixture() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
}

# A plain checkout: the main home's shape.
PRIMARY="$TMP_ROOT/primary"
make_primary_fixture "$PRIMARY"
PRIMARY_N=$(to_native "$PRIMARY")

# A secondmate's own home: a plain checkout carrying the seed-time marker. Its
# session is a PRIMARY session and must be guarded like the main home.
SECONDMATE="$TMP_ROOT/secondmate"
make_primary_fixture "$SECONDMATE"
printf 'sm-turnend-1\n' > "$SECONDMATE/.fm-secondmate-home"
SECONDMATE_N=$(to_native "$SECONDMATE")

# A genuine linked worktree - the shape bin/fm-spawn.sh hands every crewmate.
# git-dir and git-common-dir differ here, so every one of these hooks is inert.
WT_BASE="$TMP_ROOT/wt-base"
CHILD_WT="$TMP_ROOT/child-wt"
fm_git_worktree "$WT_BASE" "$CHILD_WT" fm/turnend-psm1-branch
mkdir -p "$CHILD_WT/state"
: > "$CHILD_WT/AGENTS.md"
install_guard_scripts "$CHILD_WT"
CHILD_WT_N=$(to_native "$CHILD_WT")

# The anti-spoof fixture: a linked worktree carrying an EMPTY marker. Marker
# validation rejects it, so it falls back to the linked-worktree exemption.
STRAY_WT="$TMP_ROOT/stray-wt"
fm_git_worktree "$TMP_ROOT/stray-base" "$STRAY_WT" fm/turnend-psm1-stray
mkdir -p "$STRAY_WT/state"
: > "$STRAY_WT/AGENTS.md"
install_guard_scripts "$STRAY_WT"
: > "$STRAY_WT/.fm-secondmate-home"
STRAY_WT_N=$(to_native "$STRAY_WT")

# A jq-less PATH in each world's own spelling: two different directories naming
# the same condition - jq absent.
NOJQ_BASH_PATH=$(fm_fakebin "$TMP_ROOT/nojq")
for tool in bash sh git cat printf date uname stat mkdir dirname sed grep python3; do
  tool_path=$(command -v "$tool") || continue
  fm_fakebin_tool "$NOJQ_BASH_PATH" "$tool" "$tool_path"
done
# The PowerShell spelling needs pwsh's own directory as well as git's: the
# jq-less case is run as a real process there rather than in the batch driver,
# because a PATH is the one fixture a batched case cannot carry.
NOJQ_PS_PATH=""
if command -v git >/dev/null 2>&1; then
  git_dir_posix=$(dirname "$(command -v git)")
  pwsh_dir_posix=$(dirname "$(command -v pwsh)")
  # POSIX form joined with ':', not the Windows form joined with ';': `env` here
  # is MSYS's, so it resolves the child through a POSIX PATH and converts the
  # value on the way into a native process. Handing it a Windows list makes the
  # lookup fail with 127 instead of running a jq-less pwsh.
  NOJQ_PS_PATH="$git_dir_posix:$pwsh_dir_posix"
fi
PWSH_ABS=$(command -v pwsh)

# --- the two live-harness fixtures -------------------------------------------
#
# See fixture note 1 in the header. The bash world's harness is an MSYS process
# named `claude`; the PowerShell world's is a native image named claude.exe,
# built from a copy of a self-contained system binary so it needs no DLLs beside
# it (lib.sh records why a COPIED Windows .exe usually loses its own).
FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness")
# `ln -s`, not `cp`, and deliberately the same spelling
# tests/fm-claude-stop-autoarm.test.sh uses: a COPIED bash.exe loses the DLLs
# that live beside it and dies on start, which would make this "live harness"
# a dead one and quietly turn an inertness case into an arming case.
ln -s "$(command -v bash)" "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

PS_HARNESS_DIR="$TMP_ROOT/ps-harness"
mkdir -p "$PS_HARNESS_DIR"
PS_HARNESS_EXE=""
for candidate in "$SYSTEMROOT/System32/PING.EXE" "/c/Windows/System32/PING.EXE"; do
  if [ -f "$candidate" ]; then
    cp "$candidate" "$PS_HARNESS_DIR/claude.exe" && PS_HARNESS_EXE="$PS_HARNESS_DIR/claude.exe"
    break
  fi
done
PS_HARNESS_EXE_N=""
[ -z "$PS_HARNESS_EXE" ] || PS_HARNESS_EXE_N=$(to_native "$PS_HARNESS_EXE")

# The bash world's live harness, started once and reaped at exit.
#
# The trailing `; :` is load-bearing. bash EXECS a lone simple command given to
# `-c`, so `-c 'sleep <n>'` replaces the process image and the live process is
# named `sleep`, not `claude` - which makes the shared harness predicate
# correctly answer "not a harness" and would silently turn every inertness case
# into an arming case. A second command defeats that optimization.
#
# THE LIFETIME MUST OUTLAST THE WHOLE SUITE, AND 900s DID NOT. The two halves of
# this suite are minutes apart by construction, and the oracle half is
# fork-bound: measured on this host with other verification runs live, it took
# over half an hour to reach phase E. The 15-minute harness had already exited by
# then, so `e-inert-foreign-owner` stopped being inert in the BASH world only -
# the stale numeric owner became recoverable, the hook armed, and the twin
# (whose own ping-based harness was still alive, because the driver runs late and
# fast) correctly reported the inertness the case name asks for. That reads as a
# conversion defect and is a fixture clock. FM_HARNESS_LIFETIME is bounded rather
# than infinite so a crashed run cannot strand a process for a day.
FM_HARNESS_LIFETIME=14400
"$FAKE_CLAUDE" -c "sleep $FM_HARNESS_LIFETIME; :" &
BASH_HARNESS_PID=$!
cleanup_turnend_psm1() {
  kill "$BASH_HARNESS_PID" 2>/dev/null || true
  wait "$BASH_HARNESS_PID" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup_turnend_psm1 EXIT

dead_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  DEAD_PID=$pid
}
DEAD_PID=0
dead_pid

# The fixture is only meaningful if the SHARED predicate actually recognizes it
# as a live harness; a fake that died on start would turn every inertness case
# into an arming case and certify the opposite of what the case name claims.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-psproc-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_harness_pid_alive "$BASH_HARNESS_PID" \
  || fail "the bash-world live-harness fixture is not recognized as a live harness (pid $BASH_HARNESS_PID)"

# --- oracle / case bookkeeping -----------------------------------------------
#
# Results live in plain shell variables and every case is a direct call, never a
# `( ... )` subshell: a subshell cannot report a failure back to the parent's
# counters, so a scheme built on one can lose a failure and certify work it
# never checked.
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$CASE_FILE"
ORACLE_FILE="$TMP_ROOT/oracle.tsv"
: > "$ORACLE_FILE"

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

record_expectation() {  # <label> <encoded-answer>
  printf '%s\t%s\n' "$1" "$2" >> "$ORACLE_FILE"
}

ORACLE_TMP="$TMP_ROOT/oracle.work"
mkdir -p "$ORACLE_TMP"

# run_oracle <label> <base> <fixture> <stdin> <env-list> [args...]
#
# Runs the BASH twin and records label -> "rc<US>stdout<US>stderr", all encoded.
# stdout/stderr come back through `read -d ''`, a builtin, rather than
# `$(cat ...)`: two fewer forks per case.
run_oracle() {
  local label=$1 base=$2 fixture=$3 stdin=$4 envs=$5
  shift 5
  local rc out err o="$ORACLE_TMP/o" e="$ORACLE_TMP/e"
  local -a envarr=()
  if [ -n "$envs" ]; then
    IFS=$US read -ra envarr <<< "$envs"
  fi
  rc=0
  if [ ${#envarr[@]} -gt 0 ]; then
    printf '%s' "$stdin" | env "${envarr[@]}" "$fixture/bin/$base.sh" "$@" >"$o" 2>"$e" || rc=$?
  else
    printf '%s' "$stdin" | "$fixture/bin/$base.sh" "$@" >"$o" 2>"$e" || rc=$?
  fi
  out=""; err=""
  IFS= read -r -d '' out < "$o" || true
  IFS= read -r -d '' err < "$e" || true
  enc "$out"; local eout=$ENC
  enc "$err"; local eerr=$ENC
  record_expectation "$label" "$rc$US$eout$US$eerr"
}

# emit_case <label> <base> <fixture-native> <stdin> <env-list> [args...]
#
# Six TAB fields, fixed arity, so the driver can assert the field COUNT rather
# than trusting a split.
emit_case() {
  local label=$1 base=$2 fixture=$3 stdin=$4 envs=$5
  shift 5
  local args="" a
  for a in "$@"; do
    enc "$a"
    if [ -z "$args" ]; then args=$ENC; else args="$args$US$ENC"; fi
  done
  enc "$stdin"; local estdin=$ENC
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$base" "$fixture" "$args" "$estdin" "$envs" >> "$CASE_FILE"
}

# both <label> <base> <bash-fixture> <ps-fixture> <stdin> <env-bash> <env-ps> [args...]
both() {
  local label=$1 base=$2 bfix=$3 pfix=$4 stdin=$5 benv=$6 penv=$7
  shift 7
  run_oracle "$label" "$base" "$bfix" "$stdin" "$benv" "$@"
  emit_case "$label" "$base" "$pfix" "$stdin" "$penv" "$@"
}

# guard <label> <bash-fixture> <ps-fixture> <stdin> <extra-env> [args...]
#
# The common guard shape: FM_HOME and FM_ROOT_OVERRIDE are pinned for BOTH
# worlds. FM_ROOT_OVERRIDE is not optional - without it FM_ROOT falls back to
# the real checkout, the scope check passes against the captain's own home, and
# bin/fm-guard prints into the captured stdout of a case that should have been
# silent.
guard() {
  local label=$1 bfix=$2 pfix=$3 stdin=$4 extra=$5
  shift 5
  local benv="FM_HOME=$bfix${US}FM_ROOT_OVERRIDE=$bfix"
  local penv="FM_HOME=$pfix${US}FM_ROOT_OVERRIDE=$pfix"
  if [ -n "$extra" ]; then benv="$benv$US$extra"; penv="$penv$US$extra"; fi
  both "$label" fm-turnend-guard "$bfix" "$pfix" "$stdin" "$benv" "$penv" "$@"
}

# observe <label> <bash-path> <ps-path-native> <mode>
#
# A filesystem OBSERVATION rather than a script run: both worlds report the same
# reduced view of a durable record. Modes: `exists`, `epoch` (the outcome word
# only, because the sequence, owner pid and timestamp are nondeterministic), and
# `budget` (the two-line consecutive-block record verbatim).
observe() {
  local label=$1 bpath=$2 ppath=$3 mode=$4 answer="" line=""
  case $mode in
    exists)
      if [ -e "$bpath" ]; then answer=present; else answer=absent; fi
      ;;
    epoch)
      answer=absent
      if [ -f "$bpath" ]; then
        answer=unparsed
        IFS= read -r line < "$bpath" || true
        case $line in
          *"outcome="*) answer=${line#*outcome=}; answer=${answer%% *} ;;
        esac
      fi
      ;;
    budget)
      answer=absent
      if [ -f "$bpath" ]; then
        answer=""
        while IFS= read -r line; do
          if [ -z "$answer" ]; then answer=$line; else answer="$answer;$line"; fi
        done < "$bpath"
      fi
      ;;
    *) fail "observe: unknown mode $mode" ;;
  esac
  enc "$answer"
  record_expectation "$label" "$ENC"
  # The mode travels in the ARGS field, which is where the driver reads it;
  # putting it in the stdin field made every observation answer 'absent' while
  # looking perfectly well-formed.
  emit_case "$label" "__observe" "$ppath" "" "" "$mode"
}

# two_world <name>: build one fixture per world and publish TW_BASH / TW_PS.
TW_BASH=""
TW_PS=""
TW_PS_POSIX=""
two_world() {
  local name=$1
  TW_BASH="$W1/$name"
  TW_PS_POSIX="$W2/$name"
  make_primary_fixture "$TW_BASH"
  make_primary_fixture "$TW_PS_POSIX"
  TW_PS=$(to_native "$TW_PS_POSIX")
}

# --- phase A: the guard's scope and its default (codex/Grok) loop guard ------
#
# Six shapes, one case each: the two that must GUARD (a plain primary and a
# marked secondmate home), the two that must stay INERT (a linked task worktree
# and one carrying a stray empty marker that must not spoof inclusion), and the
# two transport refusals (empty stdin, an unknown flag).
: > "$PRIMARY/state/task1.meta"
: > "$SECONDMATE/state/task1.meta"
: > "$CHILD_WT/state/task1.meta"
: > "$STRAY_WT/state/task1.meta"

PAYLOAD_FALSE='{"stop_hook_active":false,"session_id":"sess-diff"}'
PAYLOAD_TRUE='{"stop_hook_active":true,"session_id":"sess-diff"}'

guard a-primary-blocks "$PRIMARY" "$PRIMARY_N" "$PAYLOAD_FALSE" ""
guard a-secondmate-blocks "$SECONDMATE" "$SECONDMATE_N" "$PAYLOAD_FALSE" ""
guard a-child-worktree-inert "$CHILD_WT" "$CHILD_WT_N" "$PAYLOAD_FALSE" ""
guard a-stray-marker-inert "$STRAY_WT" "$STRAY_WT_N" "$PAYLOAD_FALSE" ""
guard a-loop-guard-allows "$PRIMARY" "$PRIMARY_N" "$PAYLOAD_TRUE" ""
guard a-empty-stdin "$PRIMARY" "$PRIMARY_N" "" ""
guard a-bad-flag "$PRIMARY" "$PRIMARY_N" "$PAYLOAD_FALSE" "" --bogus

# --- phase B: payload typing and the state-selection knobs -------------------
#
# The loop-guard field is TYPED: a string "true" is not a boolean and must make
# the guard fail open rather than silently read as false. camelCase wins over
# snake_case when both are present, which is the whole reason the two spellings
# are read in that order.
guard b-not-an-object "$PRIMARY" "$PRIMARY_N" '["stop_hook_active"]' ""
guard b-malformed-json "$PRIMARY" "$PRIMARY_N" '{' ""
guard b-string-not-boolean "$PRIMARY" "$PRIMARY_N" '{"stop_hook_active":"true"}' ""
guard b-camel-string-not-boolean "$PRIMARY" "$PRIMARY_N" '{"stopHookActive":"false","stop_hook_active":false}' ""
guard b-camel-precedence-allows "$PRIMARY" "$PRIMARY_N" '{"stopHookActive":true,"stop_hook_active":false}' ""
guard b-camel-precedence-blocks "$PRIMARY" "$PRIMARY_N" '{"stopHookActive":false,"stop_hook_active":true}' ""
guard b-no-loop-guard-field "$PRIMARY" "$PRIMARY_N" '{"session_id":"sess-diff"}' ""

# FM_STATE_OVERRIDE must win over FM_HOME/state - the knob a secondmate home and
# every test fixture relies on.
OVERRIDE_STATE="$TMP_ROOT/override-state"
mkdir -p "$OVERRIDE_STATE"
: > "$OVERRIDE_STATE/task1.meta"
OVERRIDE_STATE_N=$(to_native "$OVERRIDE_STATE")
QUIET_HOME="$TMP_ROOT/quiet-home"
mkdir -p "$QUIET_HOME/state"
QUIET_HOME_N=$(to_native "$QUIET_HOME")

both b-state-override fm-turnend-guard "$PRIMARY" "$PRIMARY_N" "$PAYLOAD_FALSE" \
  "FM_HOME=$QUIET_HOME${US}FM_ROOT_OVERRIDE=$PRIMARY${US}FM_STATE_OVERRIDE=$OVERRIDE_STATE" \
  "FM_HOME=$QUIET_HOME_N${US}FM_ROOT_OVERRIDE=$PRIMARY_N${US}FM_STATE_OVERRIDE=$OVERRIDE_STATE_N"
both b-fm-home-hides-repo-state fm-turnend-guard "$PRIMARY" "$PRIMARY_N" "$PAYLOAD_FALSE" \
  "FM_HOME=$QUIET_HOME${US}FM_ROOT_OVERRIDE=$PRIMARY" \
  "FM_HOME=$QUIET_HOME_N${US}FM_ROOT_OVERRIDE=$PRIMARY_N"

# An X-mode-only home: a relay poll needs supervision without a single task in
# flight, so BOTH modes must block. The gate is whether supervision is NEEDED,
# not how many tasks exist, and a twin that still counted tasks here would go
# silent on exactly the home whose watcher exists so a mention can wake it with
# no fleet work at all.
XMODE="$TMP_ROOT/xmode"
make_primary_fixture "$XMODE"
mkdir -p "$XMODE/config"
: > "$XMODE/config/x-mode.env"
: > "$XMODE/state/x-watch.check.sh"
XMODE_N=$(to_native "$XMODE")
guard b-x-mode-only-default "$XMODE" "$XMODE_N" "$PAYLOAD_FALSE" ""

# --- phase C: the Grok adapter's classification and delegation ---------------
#
# The adapter starts one of exactly two paths, or neither. Every refusal below
# must start NEITHER, and the two native cases must delegate the shared guard's
# status and its stderr unchanged.
grok_case() {  # <label> <payload> [extra-env]
  local label=$1 payload=$2 extra=${3:-}
  local benv="GROK_WORKSPACE_ROOT=$PRIMARY"
  local penv="GROK_WORKSPACE_ROOT=$PRIMARY_N"
  if [ -n "$extra" ]; then benv="$benv$US$extra"; penv="$penv$US$extra"; fi
  both "$label" fm-turnend-guard-grok "$PRIMARY" "$PRIMARY_N" "$payload" "$benv" "$penv"
}

grok_case c-native-false-blocks '{"sessionId":"native","stopHookActive":false}'
grok_case c-native-true-allows '{"sessionId":"native","stopHookActive":true}'
grok_case c-native-snake-false '{"sessionId":"native","stop_hook_active":false}'
grok_case c-native-camel-wins '{"sessionId":"native","stopHookActive":true,"stop_hook_active":false}'
grok_case c-invalid-empty ' '
grok_case c-invalid-truncated '{'
grok_case c-invalid-string-flag '{"sessionId":"x","stopHookActive":"false"}'
grok_case c-invalid-number-flag '{"sessionId":"x","stop_hook_active":1}'
grok_case c-invalid-two-documents '{"sessionId":"x"}{"sessionId":"y"}'
grok_case c-invalid-two-typed-documents '{"sessionId":"x","stopHookActive":false}{"sessionId":"y","stopHookActive":false}'
grok_case c-invalid-duplicate-session '{"sessionId":"x","sessionId":"y"}'
grok_case c-invalid-duplicate-flag '{"sessionId":"x","stop_hook_active":false,"stop_hook_active":false}'
grok_case c-invalid-structured-session '{"sessionId":{"a":1,"b":2},"stopHookActive":false}'
# Legacy shape (no typed capability field): the bounded one-resume path, whose
# every gate below refuses BEFORE a resume process could start.
grok_case c-legacy-loop-guarded '{"sessionId":"legacy"}' "GROK_TURNEND_GUARD_ACTIVE=1"
grok_case c-legacy-no-session-id '{"hookEventName":"stop"}'
# A root the adapter cannot use, and a root with no guard to delegate to.
both c-missing-root fm-turnend-guard-grok "$PRIMARY" "$PRIMARY_N" \
  '{"sessionId":"x","stopHookActive":false}' "" ""
MISSING_ROOT="$TMP_ROOT/no-such-root"
MISSING_ROOT_N=$(to_native "$TMP_ROOT")\\no-such-root
both c-root-without-guard fm-turnend-guard-grok "$PRIMARY" "$PRIMARY_N" \
  '{"sessionId":"x","stopHookActive":false}' \
  "GROK_WORKSPACE_ROOT=$MISSING_ROOT" "GROK_WORKSPACE_ROOT=$MISSING_ROOT_N"
# CLAUDE_PROJECT_DIR is the documented fallback root.
both c-project-dir-fallback fm-turnend-guard-grok "$PRIMARY" "$PRIMARY_N" \
  '{"sessionId":"x","stopHookActive":true}' \
  "CLAUDE_PROJECT_DIR=$PRIMARY" "CLAUDE_PROJECT_DIR=$PRIMARY_N"

# --- phase D: the --claude cooperative path and its bounded block budget -----
#
# Claude marks EVERY stop after any stop-hook continuation stop_hook_active=true,
# so --claude mode ignores the field and cooperates with the Stop-owned auto-arm
# instead. A short sync wait keeps the cases fast; the WAIT itself is bounded
# behavior owned by tests/fm-turnend-guard.test.sh.
CLAUDE_ENV="FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100"

two_world claude-reblock
: > "$TW_BASH/state/task1.meta"
: > "$TW_PS_POSIX/state/task1.meta"
guard d-reblocks-loop-guarded "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" "$CLAUDE_ENV" --claude
observe d-reblock-budget "$TW_BASH/state/.turnend-claude-blocks" \
  "$TW_PS\\state\\.turnend-claude-blocks" budget

# X-mode-only, --claude: blocks with the X-mode wording and spends budget.
two_world claude-xmode
for xm in "$TW_BASH" "$TW_PS_POSIX"; do
  mkdir -p "$xm/config"
  : > "$xm/config/x-mode.env"
  : > "$xm/state/x-watch.check.sh"
done
guard d-x-mode-only-reblocks "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" "$CLAUDE_ENV" --claude

# A fresh rewake outcome means the auto-arm already owns recovery for this event
# epoch, so a continuation would be a duplicate.
#
# The freshness window is widened for this case rather than left at its default
# 15s: the oracle half and the driver half of a batched suite run MINUTES apart,
# so a fixture whose meaning depends on wall-clock age would answer "fresh" to
# one world and "stale" to the other and read as a conversion defect. The
# STALE-side assertion is the one that needs no widening, because its ledger is
# dated 2020 and is ancient whenever it is read.
two_world claude-epoch
for ce in "$TW_BASH" "$TW_PS_POSIX"; do
  : > "$ce/state/task1.meta"
  printf 'epoch=3 owner_pid=999 outcome=rewake updated_at=%s\n' "$(date +%s)" > "$ce/state/.claude-autoarm-epoch"
done
guard d-fresh-rewake-allows "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" \
  "$CLAUDE_ENV${US}FM_CLAUDE_AUTOARM_EPOCH_FRESH=86400" --claude

# The same ledger, far outside the freshness window, is NOT this event's
# recovery and must not buy a blind stop.
two_world claude-stale-epoch
for ce in "$TW_BASH" "$TW_PS_POSIX"; do
  : > "$ce/state/task1.meta"
  printf 'epoch=3 owner_pid=999 outcome=rewake updated_at=1\n' > "$ce/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$ce/state/.claude-autoarm-epoch"
done
guard d-stale-rewake-blocks "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" "$CLAUDE_ENV" --claude

# A `clean` outcome is not a rewake claim at all, however fresh it is.
two_world claude-clean-epoch
for ce in "$TW_BASH" "$TW_PS_POSIX"; do
  : > "$ce/state/task1.meta"
  printf 'epoch=4 owner_pid=999 outcome=clean updated_at=%s\n' "$(date +%s)" > "$ce/state/.claude-autoarm-epoch"
done
guard d-clean-outcome-blocks "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" \
  "$CLAUDE_ENV${US}FM_CLAUDE_AUTOARM_EPOCH_FRESH=86400" --claude

# THE BOUNDED BUDGET. Five consecutive blocks for one session id, accounted into
# state/.turnend-claude-blocks. The bound itself (3, deliberately below Claude
# Code's hard 8-consecutive-block override) is necessary for the attended
# fail-open but not sufficient: without a verified failure episode every block
# past the bound still blocks and the count keeps climbing, which is what these
# fixtures assert. Each world drives its own fixture through the same sequence.
two_world claude-budget
: > "$TW_BASH/state/task1.meta"
: > "$TW_PS_POSIX/state/task1.meta"
BUDGET_BASH=$TW_BASH
BUDGET_PS=$TW_PS
for budget_i in 1 2 3 4 5; do
  guard "d-budget-$budget_i" "$BUDGET_BASH" "$BUDGET_PS" "$PAYLOAD_TRUE" "$CLAUDE_ENV" --claude
done
observe d-budget-after "$BUDGET_BASH/state/.turnend-claude-blocks" \
  "$BUDGET_PS\\state\\.turnend-claude-blocks" budget

# A DIFFERENT session id starts its own chain rather than inheriting the count.
two_world claude-sessions
: > "$TW_BASH/state/task1.meta"
: > "$TW_PS_POSIX/state/task1.meta"
SESSIONS_BASH=$TW_BASH
SESSIONS_PS=$TW_PS
guard d-session-a "$SESSIONS_BASH" "$SESSIONS_PS" \
  '{"stop_hook_active":true,"session_id":"sess-A"}' "$CLAUDE_ENV" --claude
guard d-session-b "$SESSIONS_BASH" "$SESSIONS_PS" \
  '{"stop_hook_active":true,"session_id":"sess-B"}' "$CLAUDE_ENV" --claude
observe d-session-budget "$SESSIONS_BASH/state/.turnend-claude-blocks" \
  "$SESSIONS_PS\\state\\.turnend-claude-blocks" budget

# An idle home in --claude mode allows AND clears any budget it was carrying.
two_world claude-idle
for ce in "$TW_BASH" "$TW_PS_POSIX"; do
  printf 'session=old\ncount=2\n' > "$ce/state/.turnend-claude-blocks"
done
guard d-idle-allows "$TW_BASH" "$TW_PS" "$PAYLOAD_TRUE" "$CLAUDE_ENV" --claude
observe d-idle-budget-cleared "$TW_BASH/state/.turnend-claude-blocks" \
  "$TW_PS\\state\\.turnend-claude-blocks" exists

# --- phase E: the Stop-owned auto-arm ----------------------------------------
#
# Its inertness gates are its safety, and they run in one fixed order: scope,
# identity, AFK, need, and only then the mutating claim. Every case below that
# must stay inert asserts BOTH the exit code and that no epoch ledger was ever
# written - an idle or away home is byte-for-byte inert, not merely quiet.
AUTOARM_PAYLOAD='{"session_id":"sess-autoarm","stop_hook_active":false}'

write_arm_fixture() {  # <dir> <kind>
  local dir=$1 kind=$2
  case $kind in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=fixture (beacon fresh)\n'
printf 'stale: fixture actionable reason\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: attached pid=fixture (beacon 2s)\n'
exit 0
SH
      ;;
    need-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
rm -f "$FM_STATE_DIR_FOR_FIXTURE"/*.meta
printf 'watcher: started pid=fixture (beacon fresh)\n'
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_STATE_DIR_FOR_FIXTURE/.afk"
printf 'watcher: started pid=fixture (beacon fresh)\n'
printf 'check: fixture\n'
exit 0
SH
      ;;
    *) fail "write_arm_fixture: unknown kind $kind" ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# make_autoarm_fixture <name> <arm-kind>: two worlds, publishing AA_BASH/AA_PS.
# Every auto-arm case writes an epoch ledger and takes an owner lock, so the two
# worlds cannot share one tree (see the two-world note above).
AA_BASH=""
AA_PS=""
AA_PS_POSIX=""
make_autoarm_fixture() {
  local name=$1 kind=$2
  AA_BASH="$W1/$name"
  AA_PS_POSIX="$W2/$name"
  make_primary_fixture "$AA_BASH"
  make_primary_fixture "$AA_PS_POSIX"
  write_arm_fixture "$AA_BASH" "$kind"
  write_arm_fixture "$AA_PS_POSIX" "$kind"
  AA_PS=$(to_native "$AA_PS_POSIX")
}

# run_autoarm_oracle <label> <fixture> <owner> [extra-env]
#
# <owner> selects how the fixture's state/.lock is populated for the BASH world:
#   self    - run under the fake harness, which writes its own pid (the shape
#             tests/fm-claude-stop-autoarm.test.sh uses)
#   foreign - another LIVE harness holds it
#   dead    - a stale numeric owner no harness liveness check can confirm
#   junk    - a malformed lock
#   none    - no lock at all
run_autoarm_oracle() {
  local label=$1 fixture=$2 owner=$3 extra=${4:-}
  local rc out err o="$ORACLE_TMP/o" e="$ORACLE_TMP/e"
  local -a envarr=()
  envarr=("FM_HOME=$fixture" "FM_ROOT_OVERRIDE=$fixture" "FM_STATE_DIR_FOR_FIXTURE=$fixture/state")
  if [ -n "$extra" ]; then
    local -a extraarr=()
    IFS=$US read -ra extraarr <<< "$extra"
    envarr+=("${extraarr[@]}")
  fi
  rm -f "$fixture/state/.lock"
  case $owner in
    foreign) printf '%s\n' "$BASH_HARNESS_PID" > "$fixture/state/.lock" ;;
    dead)    printf '%s\n' "$DEAD_PID" > "$fixture/state/.lock" ;;
    junk)    printf 'not-a-pid\n' > "$fixture/state/.lock" ;;
    none)    : ;;
    self)    : ;;
    *) fail "run_autoarm_oracle: unknown owner $owner" ;;
  esac
  rc=0
  if [ "$owner" = self ]; then
    printf '%s' "$AUTOARM_PAYLOAD" | env "${envarr[@]}" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' >"$o" 2>"$e" || rc=$?
  else
    printf '%s' "$AUTOARM_PAYLOAD" | env "${envarr[@]}" "$fixture/bin/fm-claude-stop-autoarm.sh" >"$o" 2>"$e" || rc=$?
  fi
  out=""; err=""
  IFS= read -r -d '' out < "$o" || true
  IFS= read -r -d '' err < "$e" || true
  enc "$out"; local eout=$ENC
  enc "$err"; local eerr=$ENC
  record_expectation "$label" "$rc$US$eout$US$eerr"
}

# autoarm <label> <owner> [extra-env] - drives the fixtures published by the
# preceding make_autoarm_fixture call.
autoarm() {
  local label=$1 owner=$2 extra=${3:-}
  run_autoarm_oracle "$label" "$AA_BASH" "$owner" "$extra"
  # The PowerShell world takes the same owner selector; the driver resolves
  # `self` through the shared session-lock library rather than through a
  # process it launched, because the two ancestry walks live in different pid
  # spaces (fixture note 2). It answers `unresolved` when the library cannot
  # name this session's harness, so a fixture that silently made every case
  # inert fails by name instead of by symptom.
  emit_case "$label-own" __own "$AA_PS" "" "" "$owner"
  local penv="FM_HOME=$AA_PS${US}FM_ROOT_OVERRIDE=$AA_PS${US}FM_STATE_DIR_FOR_FIXTURE=$AA_PS_POSIX/state"
  if [ -n "$extra" ]; then penv="$penv$US$extra"; fi
  record_expectation "$label-own" ok
  emit_case "$label" fm-claude-stop-autoarm "$AA_PS" "$AUTOARM_PAYLOAD" "$penv"
}

make_autoarm_worktree() {  # <name>
  local name=$1 world dir
  for world in "$W1" "$W2"; do
    dir="$world/$name"
    fm_git_worktree "$world/$name-base" "$dir" "fm/turnend-psm1-$name-${world##*/}"
    mkdir -p "$dir/state"
    : > "$dir/AGENTS.md"
    install_guard_scripts "$dir"
    write_arm_fixture "$dir" actionable
    : > "$dir/state/task.meta"
  done
  AA_BASH="$W1/$name"
  AA_PS_POSIX="$W2/$name"
  AA_PS=$(to_native "$AA_PS_POSIX")
}

make_autoarm_worktree aa-child-wt
autoarm e-inert-child-worktree self

make_autoarm_fixture aa-foreign actionable
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
AA_FOREIGN_BASH=$AA_BASH; AA_FOREIGN_PS=$AA_PS
autoarm e-inert-foreign-owner foreign

make_autoarm_fixture aa-junk actionable
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-inert-malformed-lock junk

make_autoarm_fixture aa-nolock actionable
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-inert-missing-lock none

make_autoarm_fixture aa-afk actionable
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
: > "$AA_BASH/state/.afk"; : > "$AA_PS_POSIX/state/.afk"
AA_AFK_BASH=$AA_BASH; AA_AFK_PS=$AA_PS
autoarm e-inert-afk self

make_autoarm_fixture aa-idle actionable
AA_IDLE_BASH=$AA_BASH; AA_IDLE_PS=$AA_PS
autoarm e-inert-idle self

make_autoarm_fixture aa-clean clean
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-clean-close self
observe e-clean-epoch "$AA_BASH/state/.claude-autoarm-epoch" \
  "$AA_PS\\state\\.claude-autoarm-epoch" epoch

make_autoarm_fixture aa-actionable actionable
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-actionable-rewake self
observe e-actionable-epoch "$AA_BASH/state/.claude-autoarm-epoch" \
  "$AA_PS\\state\\.claude-autoarm-epoch" epoch

make_autoarm_fixture aa-failed failed
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-failed-rewake self
observe e-failed-epoch "$AA_BASH/state/.claude-autoarm-epoch" \
  "$AA_PS\\state\\.claude-autoarm-epoch" epoch

make_autoarm_fixture aa-vanish need-vanishes
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-need-vanishes self
observe e-vanish-epoch "$AA_BASH/state/.claude-autoarm-epoch" \
  "$AA_PS\\state\\.claude-autoarm-epoch" epoch

make_autoarm_fixture aa-afk-mid afk-appears
: > "$AA_BASH/state/task.meta"; : > "$AA_PS_POSIX/state/task.meta"
autoarm e-afk-appears-mid-cycle self
observe e-afk-mid-epoch "$AA_BASH/state/.claude-autoarm-epoch" \
  "$AA_PS\\state\\.claude-autoarm-epoch" epoch

# Inert cases must leave NO ledger at all - that is the difference between
# "decided nothing was needed" and "claimed the home and then changed its mind".
observe e-inert-idle-no-epoch "$AA_IDLE_BASH/state/.claude-autoarm-epoch" \
  "$AA_IDLE_PS\\state\\.claude-autoarm-epoch" exists
observe e-inert-afk-no-epoch "$AA_AFK_BASH/state/.claude-autoarm-epoch" \
  "$AA_AFK_PS\\state\\.claude-autoarm-epoch" exists
observe e-inert-foreign-no-epoch "$AA_FOREIGN_BASH/state/.claude-autoarm-epoch" \
  "$AA_FOREIGN_PS\\state\\.claude-autoarm-epoch" exists

# --- phase F: the Kimi turn-end hook -----------------------------------------
#
# The CLI surface is this twin's own; the TOML validator is the SAME Python
# program in both worlds, deliberately (see bin/fm-kimi-turnend-hook.ps1's
# header), so what is compared here is the surface plus the resulting bytes.
KIMI_B="$W1/kimi"
KIMI_P="$W2/kimi"
mkdir -p "$KIMI_B" "$KIMI_P"

kimi_case() {  # <label> <bash-home> <ps-home-native> <args...>
  local label=$1 bhome=$2 phome=$3
  shift 3
  both "$label" fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
    "HOME=$bhome" "HOME=$phome" "$@"
}

KIMI_EMPTY_B="$KIMI_B/empty"
KIMI_EMPTY_P="$KIMI_P/empty"
mkdir -p "$KIMI_EMPTY_B" "$KIMI_EMPTY_P"
KIMI_EMPTY_PN=$(to_native "$KIMI_EMPTY_P")
kimi_case f-help "$KIMI_EMPTY_B" "$KIMI_EMPTY_PN" --help
kimi_case f-usage "$KIMI_EMPTY_B" "$KIMI_EMPTY_PN" bogus
kimi_case f-no-args "$KIMI_EMPTY_B" "$KIMI_EMPTY_PN"
kimi_case f-missing-config-dir "$KIMI_EMPTY_B" "$KIMI_EMPTY_PN" install

# HOME empty is the documented refusal, and `${VAR:-}` treats empty as unset in
# both worlds.
kimi_case f-home-unset "" "" install

# Malformed and partially marked configs must be refused WITHOUT a write.
KIMI_BAD_B="$KIMI_B/bad"; mkdir -p "$KIMI_BAD_B/.kimi-code"
printf '[broken\n' > "$KIMI_BAD_B/.kimi-code/config.toml"
KIMI_BAD_P="$KIMI_P/bad"; mkdir -p "$KIMI_BAD_P/.kimi-code"
printf '[broken\n' > "$KIMI_BAD_P/.kimi-code/config.toml"
both f-malformed-toml fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
  "HOME=$KIMI_BAD_B" "HOME=$(to_native "$KIMI_BAD_P")" install
observe f-malformed-no-hook-script "$KIMI_BAD_B/.kimi-code/fm-turn-end.sh" \
  "$(to_native "$KIMI_BAD_P")\\.kimi-code\\fm-turn-end.sh" exists

KIMI_PARTIAL_B="$KIMI_B/partial"; mkdir -p "$KIMI_PARTIAL_B/.kimi-code"
printf '# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$KIMI_PARTIAL_B/.kimi-code/config.toml"
KIMI_PARTIAL_P="$KIMI_P/partial"; mkdir -p "$KIMI_PARTIAL_P/.kimi-code"
printf '# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$KIMI_PARTIAL_P/.kimi-code/config.toml"
both f-partial-marker fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
  "HOME=$KIMI_PARTIAL_B" "HOME=$(to_native "$KIMI_PARTIAL_P")" install

# A real install, once per world, then a second install proving idempotence.
# The two worlds get their own HOME because both actually WRITE; the resulting
# config bytes are then compared against each other directly.
KIMI_OK_B="$KIMI_B/ok"; mkdir -p "$KIMI_OK_B/.kimi-code"
printf 'default_model = "test"\n' > "$KIMI_OK_B/.kimi-code/config.toml"
KIMI_OK_P="$KIMI_P/ok"; mkdir -p "$KIMI_OK_P/.kimi-code"
printf 'default_model = "test"\n' > "$KIMI_OK_P/.kimi-code/config.toml"
both f-install-1 fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
  "HOME=$KIMI_OK_B" "HOME=$(to_native "$KIMI_OK_P")" install
both f-install-2 fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
  "HOME=$KIMI_OK_B" "HOME=$(to_native "$KIMI_OK_P")" install
# The captain-visible product of an install: the config bytes and the presence
# of the hook script and its registry.
KIMI_CONFIG_ANSWER=""
IFS= read -r -d '' KIMI_CONFIG_ANSWER < "$KIMI_OK_B/.kimi-code/config.toml" || true
enc "$KIMI_CONFIG_ANSWER"
record_expectation f-install-config "$ENC"
emit_case f-install-config __readfile "$(to_native "$KIMI_OK_P")\\.kimi-code\\config.toml" "" "" ""
observe f-install-hook-script "$KIMI_OK_B/.kimi-code/fm-turn-end.sh" \
  "$(to_native "$KIMI_OK_P")\\.kimi-code\\fm-turn-end.sh" exists
observe f-install-registry "$KIMI_OK_B/.kimi-code/fm-turn-end.d" \
  "$(to_native "$KIMI_OK_P")\\.kimi-code\\fm-turn-end.d" exists
# DECLARED DIVERGENCE C: `remove` refuses in BOTH worlds on Windows, because the
# shared Python validator rejects a hook script whose mode is not 0o700 and
# Windows chmod is inert. Compared directly, so a host where it DOES succeed
# still agrees.
both f-remove fm-kimi-turnend-hook "$PRIMARY" "$PRIMARY_N" "" \
  "HOME=$KIMI_OK_B" "HOME=$(to_native "$KIMI_OK_P")" remove

# --- run the PowerShell half: ONE pwsh for every case ------------------------
DRIVER="$TMP_ROOT/driver.ps1"
cat > "$DRIVER" <<PSEOF
Set-StrictMode -Version Latest
\$ErrorActionPreference = 'Stop'

\$US = [char]0x1f
\$RS = [char]0x1e
\$GS = [char]0x1d
\$FS = [char]0x1c
\$CaseFile = '$(to_native "$CASE_FILE")'
\$OutFile  = '$(to_native "$TMP_ROOT/ps-answers.tsv")'
\$HarnessExe = '$PS_HARNESS_EXE_N'
\$HarnessLifetime = '$FM_HARNESS_LIFETIME'
\$SessionLockLib = '$(to_native "$PRIMARY/bin/fm-session-lock-lib.psm1")'
PSEOF
cat >> "$DRIVER" <<'PSEOF'

function Restore-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace($RS, "`n").Replace($GS, "`r").Replace($FS, "`t")
}

function Protect-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", $GS).Replace("`n", $RS).Replace("`t", $FS)
}

# The session-lock library is imported ONCE, at the top level, deliberately with
# no -Force: -Force removes the loaded module globally and would evict fm-common
# from every case that already holds it (docs/powershell-port.md).
Import-Module $SessionLockLib

# THE LIVE HARNESS THIS WORLD CAN SEE. An MSYS process named `claude` is
# invisible to the native process table, so the PowerShell world builds its own
# native one - a copy of a self-contained system binary named claude.exe - and
# uses it for the "another live harness holds the lock" case. Started once, with
# the SAME bounded lifetime as the oracle's harness: ping's -n count is one
# second apart, so the two worlds' fixtures expire together instead of one
# outliving the other and turning a fixture clock into an apparent conversion
# defect (see the FM_HARNESS_LIFETIME note in the oracle half).
$HarnessProc = $null
if (-not [string]::IsNullOrEmpty($HarnessExe) -and [System.IO.File]::Exists($HarnessExe)) {
    $HarnessProc = Start-Process -FilePath $HarnessExe -ArgumentList @('-n', $HarnessLifetime, '127.0.0.1') `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 700
}

# A pid no process holds. Searched upward from a high number exactly as the
# oracle's dead_pid does, and re-checked rather than assumed.
$DeadPid = 999999
while ($null -ne (Get-Process -Id $DeadPid -ErrorAction Ignore)) { $DeadPid++ }

# THE RESOLVED SESSION OWNER for this world (fixture note 2 in the suite
# header): whatever the SHARED library resolves for this process, which is what
# the hook itself will compare the lock against.
$SelfOwner = Get-FmHarnessAncestryPid

$TouchedNames = @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
    'FM_GUARD_GRACE', 'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS', 'FM_CLAUDE_AUTOARM_EPOCH_FRESH',
    'FM_CLAUDE_TURNEND_BLOCK_BUDGET', 'FM_STATE_DIR_FOR_FIXTURE',
    'GROK_WORKSPACE_ROOT', 'GROK_TURNEND_GUARD_ACTIVE', 'GROK_HOME', 'CLAUDE_PROJECT_DIR',
    'HOME', 'PATH')
$BasePath = $env:PATH
$BaseHome = $env:HOME
foreach ($n in $TouchedNames) {
    if ($n -ne 'PATH' -and $n -ne 'HOME') { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
}

$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
$OrigIn = [Console]::In
$Answers = [System.Text.StringBuilder]::new()

# THE TRAP THIS SUITE PAID FOR, AND THE ONE LINE THAT FIXES IT.
#
# fm-common's module BODY sets [Console]::OutputEncoding and
# [Console]::InputEncoding, and assigning either RESETS [Console]::In and
# [Console]::Out. docs/powershell-port.md records that for -Force; the sharper
# form is that it happens on any genuine LOAD - including the very first import
# in a batch driver, and again for a copy of the same module imported from a
# DIFFERENT fixture path. So a case that redirected the console and then invoked
# a script whose import triggered a load had its StringReader replaced by the
# driver's own stdin before the script ever read it. Observed exactly: the same
# fixture answered 0 (silent, empty stdin) on its first run and 2 (correct
# banner) on its third, once every module was warm.
#
# The fix is to make the load happen BEFORE the redirection: every module in a
# fixture's bin is imported once, the first time that fixture is used. Idempotent
# and cheap afterwards, because an already-loaded path is a no-op.
$Warmed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
function Initialize-FixtureModule([string]$FixtureDir) {
    if (-not $Warmed.Add($FixtureDir)) { return }
    $binDir = Join-Path $FixtureDir 'bin'
    if (-not [System.IO.Directory]::Exists($binDir)) { return }
    foreach ($module in (Get-ChildItem -LiteralPath $binDir -Filter '*.psm1' -ErrorAction SilentlyContinue)) {
        try { Import-Module $module.FullName } catch { $null = $_ }
    }
}

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    # Split on the record's real TAB, NOT on $FS: FS is the ESCAPE for a tab
    # inside a value, which is exactly why the record separator can still be a
    # plain tab. StringSplitOptions::None keeps trailing empty fields, which
    # several cases legitimately have, and the COUNT is asserted rather than
    # assumed.
    $fields = @($line.Split("`t", [System.StringSplitOptions]::None))
    if ($fields.Count -ne 6) {
        [void]$Answers.AppendLine("PARSE-ERROR-$($fields.Count)`tfields=$($fields.Count) line=$line")
        continue
    }
    $label = $fields[0]
    $base = $fields[1]
    $fixture = $fields[2]
    $argsRaw = $fields[3]
    $stdin = Restore-CaseText $fields[4]
    $envRaw = $fields[5]

    $caseArgs = @()
    if (-not [string]::IsNullOrEmpty($argsRaw)) {
        foreach ($a in @($argsRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            $caseArgs += (Restore-CaseText $a)
        }
    }

    # --- pseudo-cases: fixture setup and filesystem observations -------------
    if ($base -eq '__own') {
        # The session-lock fixture for one autoarm case. `self` writes THIS
        # world's resolved owner; the other selectors are compared directly
        # against the oracle and carry the discriminating evidence.
        $lockPath = Join-Path (Join-Path $fixture 'state') '.lock'
        if ([System.IO.File]::Exists($lockPath)) { [System.IO.File]::Delete($lockPath) }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        switch ($argsRaw) {
            'self' { [System.IO.File]::WriteAllText($lockPath, "$SelfOwner`n", $utf8) }
            'foreign' {
                $foreign = if ($null -ne $HarnessProc) { [string]$HarnessProc.Id } else { [string]$DeadPid }
                [System.IO.File]::WriteAllText($lockPath, "$foreign`n", $utf8)
            }
            'dead' { [System.IO.File]::WriteAllText($lockPath, "$DeadPid`n", $utf8) }
            'junk' { [System.IO.File]::WriteAllText($lockPath, "not-a-pid`n", $utf8) }
            'none' { }
            default { }
        }
        # `unresolved` rather than a silent ok: a session whose harness the
        # shared library cannot name would make every auto-arm case inert, and
        # inert is a legitimate answer for several of them - so the fixture has
        # to report its own failure or the suite certifies the wrong thing.
        $ownAnswer = if ($argsRaw -ne 'self' -or -not [string]::IsNullOrEmpty($SelfOwner)) { 'ok' } else { 'unresolved' }
        [void]$Answers.AppendLine("$label`t$ownAnswer")
        continue
    }
    if ($base -eq '__observe') {
        $answer = 'absent'
        switch ($argsRaw) {
            'exists' {
                if ([System.IO.File]::Exists($fixture) -or [System.IO.Directory]::Exists($fixture)) {
                    $answer = 'present'
                }
            }
            'epoch' {
                if ([System.IO.File]::Exists($fixture)) {
                    $answer = 'unparsed'
                    $text = [System.IO.File]::ReadAllText($fixture)
                    $nl = $text.IndexOf("`n")
                    $first = if ($nl -ge 0) { $text.Substring(0, $nl) } else { $text }
                    $m = [regex]::Match($first, 'outcome=([^ ]*)')
                    if ($m.Success) { $answer = $m.Groups[1].Value }
                }
            }
            'budget' {
                if ([System.IO.File]::Exists($fixture)) {
                    $text = [System.IO.File]::ReadAllText($fixture).Replace("`r`n", "`n")
                    if ($text.EndsWith("`n")) { $text = $text.Substring(0, $text.Length - 1) }
                    $answer = ($text -split "`n") -join ';'
                }
            }
        }
        [void]$Answers.AppendLine("$label`t" + (Protect-CaseText $answer))
        continue
    }
    if ($base -eq '__readfile') {
        $answer = ''
        if ([System.IO.File]::Exists($fixture)) {
            $answer = [System.IO.File]::ReadAllText($fixture).Replace("`r`n", "`n")
            # `$(cat f)` strips trailing newlines; the oracle's `read -d ''`
            # keeps the file verbatim, so only the CRLF normalization applies.
        }
        [void]$Answers.AppendLine("$label`t" + (Protect-CaseText $answer))
        continue
    }

    # --- environment for exactly this case -----------------------------------
    foreach ($n in $TouchedNames) {
        if ($n -eq 'PATH') { $env:PATH = $BasePath }
        elseif ($n -eq 'HOME') { if ($null -eq $BaseHome) { Remove-Item -LiteralPath 'env:HOME' -ErrorAction SilentlyContinue } else { $env:HOME = $BaseHome } }
        else { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    }
    if (-not [string]::IsNullOrEmpty($envRaw)) {
        foreach ($pair in @($envRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            if ([string]::IsNullOrEmpty($pair)) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $pair.Substring(0, $eq)
            $value = Restore-CaseText $pair.Substring($eq + 1)
            if ($value -eq '') {
                # `HOME= cmd` exports an EMPTY value, which `${HOME:-}` treats
                # as unset; Set-Item on an empty value REMOVES the variable,
                # which is the same observable state for a `:-` reader.
                Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item -LiteralPath "env:$name" -Value $value
            }
        }
    }

    Initialize-FixtureModule $fixture

    $script = Join-Path (Join-Path $fixture 'bin') "$base.ps1"
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetIn([System.IO.StringReader]::new($stdin))
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $global:LASTEXITCODE = 0
    $threw = ''
    try {
        & $script @caseArgs
    } catch {
        $threw = $_.Exception.Message
    }
    $rc = $LASTEXITCODE
    [Console]::SetOut($OrigOut)
    [Console]::SetError($OrigErr)
    [Console]::SetIn($OrigIn)

    $outText = $so.ToString()
    $errText = $se.ToString()
    if ($threw -ne '') { $errText = $errText + "DRIVER-EXCEPTION: $threw`n" }

    $answer = "$rc$US" + (Protect-CaseText $outText) + $US + (Protect-CaseText $errText)
    [void]$Answers.AppendLine("$label`t$answer")
}

if ($null -ne $HarnessProc) {
    try { $HarnessProc.Kill() } catch { $null = $_ }
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

# --- join by label and compare ------------------------------------------------
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

# DECLARED NORMALIZATION - path SPELLINGS only.
#
# A diagnostic naming a path is emitted by each world in its own form: bash says
# /tmp/fm-turnend-psm1.X/y, the twin says the native AppData Temp path. Those are
# the SAME LOCATION (MSYS mounts /tmp onto it), so comparing the spellings tests
# the mount table rather than the twin. Both roots collapse to <ROOT> and
# separators unify, leaving the wording, the exit code and the trailing
# component of every message fully compared.
#
# Separators are unified FIRST, then the root is matched in its unified
# spelling: the PowerShell answer arrives with backslashes, so a forward-slash
# root would never match otherwise.
#
# ASSIGNS to the named variable rather than printing, because `$(norm ...)` is a
# forked subshell and this runs twice per assertion; on a host where a fork
# costs 0.36-4s that alone decides whether the suite finishes.
norm_into() {  # <target-var> <text>
  local s=$2
  s=${s//\\//}
  s=${s//"$TMP_ROOT_FWD"/<ROOT>}
  s=${s//"$TMP_ROOT_MSYS"/<ROOT>}
  s=${s//"$TMP_ROOT"/<ROOT>}
  # SECOND DECLARED NORMALIZATION - the two-world fixture trees. A mutating
  # case gets one tree per world (see the two-world note above), so a message
  # quoting its own home names w1 in one world and w2 in the other. Both
  # collapse to <ROOT>/w, leaving the rest of the path fully compared.
  s=${s//<ROOT>\/w1\//<ROOT>/w/}
  s=${s//<ROOT>\/w2\//<ROOT>/w/}
  printf -v "$1" '%s' "$s"
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
  norm_into NORM_EXPECTED "$answer"
  norm_into NORM_ACTUAL "${PS_ANSWER[$label]}"
  # THIRD DECLARED NORMALIZATION - the Kimi validator's line endings, and ONLY
  # there. Python's stderr is a text stream, so on Windows it writes CRLF; the
  # bash twin inherits the stream and passes those bytes through, while the twin
  # captures and re-emits them through Write-FmErr, which guarantees LF
  # (contract 1 in docs/powershell-port.md). Stripping CR for the f-* labels
  # compares the WORDS, and divergence D below pins the line-ending difference
  # itself so it can never disappear unnoticed. It is deliberately NOT applied
  # anywhere else: every other byte in this suite is produced by the twin
  # itself, where a CR would be a real contract violation.
  case $label in
    f-*)
      NORM_EXPECTED=${NORM_EXPECTED//$GS/}
      NORM_ACTUAL=${NORM_ACTUAL//$GS/}
      ;;
  esac
  assert_same "$label" "$NORM_EXPECTED" "$NORM_ACTUAL"
done < "$ORACLE_FILE"

# --- DECLARED DIVERGENCE D: the Kimi validator's line endings ----------------
KIMI_ORACLE=""
while IFS=$'\t' read -r label answer; do
  if [ "$label" = f-malformed-toml ]; then KIMI_ORACLE=$answer; fi
done < "$ORACLE_FILE"
case $KIMI_ORACLE in
  *"$GS"*) KIMI_CR_BASH=crlf ;;
  *) KIMI_CR_BASH=lf ;;
esac
case ${PS_ANSWER[f-malformed-toml]:-} in
  *"$GS"*) KIMI_CR_PS=crlf ;;
  *) KIMI_CR_PS=lf ;;
esac
assert_same "divergence D: the bash twin passes the validator's CRLF through" "crlf" "$KIMI_CR_BASH"
assert_same "divergence D: the twin re-emits the same diagnostic as LF" "lf" "$KIMI_CR_PS"

# --- the block budget, asserted as a NUMBER ----------------------------------
#
# The join above already proved the two worlds agree case by case. What it
# cannot show is that they agree on the right NUMBER, because two twins that
# both blocked five times would match each other whatever bound they carried.
# These read the joined answers and pin the accounting itself: every block in
# the chain blocks, the durable record reaches exactly five, and no block
# degrades to an allow - the attended fail-open stays shut because these
# fixtures carry no verified failure episode, only an exhausted count.
budget_rc() {  # <target-var> <label>
  local a=${PS_ANSWER[$2]:-}
  printf -v "$1" '%s' "${a%%"$US"*}"
}
BUDGET_MSG=none
for budget_i in 1 2 3 4 5; do
  budget_rc BUDGET_RC "d-budget-$budget_i"
  assert_same "budget: block $budget_i of the chain exits 2" "2" "$BUDGET_RC"
  BUDGET_OUT=${PS_ANSWER["d-budget-$budget_i"]:-}
  BUDGET_OUT=${BUDGET_OUT#*"$US"}
  BUDGET_OUT=${BUDGET_OUT%%"$US"*}
  case $BUDGET_OUT in
    *'"systemMessage"'*) BUDGET_MSG="block $budget_i: $BUDGET_OUT" ;;
  esac
done
assert_same "budget: exceeding the bound alone never opens the attended fail-open" \
  "none" "$BUDGET_MSG"
# The bound as a number, read from the twin's OWN answer rather than only from
# the oracle it was already compared against: five blocks, five counted.
assert_same "budget: the durable record counted every block in the chain" \
  "session=sess-diff;count=5;epoch=" "${PS_ANSWER[d-budget-after]:-}"

# --- DECLARED DIVERGENCE A: jq ------------------------------------------------
#
# With jq removed from PATH the bash guard cannot read the loop-guard field and
# allows; the PowerShell guard parses in-process and still blocks. Asserted as a
# DIFFERENCE, per world, so the day it changes is loud.
NOJQ_RC=0
printf '%s' "$PAYLOAD_FALSE" \
  | env "PATH=$NOJQ_BASH_PATH" "FM_HOME=$PRIMARY" "FM_ROOT_OVERRIDE=$PRIMARY" \
      "$PRIMARY/bin/fm-turnend-guard.sh" >/dev/null 2>&1 || NOJQ_RC=$?
assert_same "divergence A: the bash guard fails open without jq" "0" "$NOJQ_RC"
NOJQ_PS_RC=0
if [ -n "$NOJQ_PS_PATH" ]; then
  # pwsh by ABSOLUTE path: `env` resolves the child through the ambient PATH,
  # which this case has deliberately narrowed, so a bare name would exit 127
  # instead of running the guard.
  printf '%s' "$PAYLOAD_FALSE" \
    | env "PATH=$NOJQ_PS_PATH" "FM_HOME=$PRIMARY_N" "FM_ROOT_OVERRIDE=$PRIMARY_N" \
        "$PWSH_ABS" -NoProfile -File "$(to_native "$PRIMARY/bin/fm-turnend-guard.ps1")" >/dev/null 2>&1 \
    || NOJQ_PS_RC=$?
  assert_same "divergence A: the PowerShell guard needs no jq and still blocks" "2" "$NOJQ_PS_RC"
fi

# --- DECLARED DIVERGENCE B: a multi-document payload reaching the GUARD -------
#
# jq reads a stream, so bash emits one loop-guard answer per document and the
# concatenation is never the literal "true" - it proceeds and blocks.
# ConvertFrom-Json parses exactly one document and the twin allows. No verified
# harness emits one, and the Grok adapter refuses them in both worlds (phase C).
MULTIDOC='{"stop_hook_active":true}{"stop_hook_active":true}'
MULTI_RC=0
printf '%s' "$MULTIDOC" \
  | env "FM_HOME=$PRIMARY" "FM_ROOT_OVERRIDE=$PRIMARY" \
      "$PRIMARY/bin/fm-turnend-guard.sh" >/dev/null 2>&1 || MULTI_RC=$?
assert_same "divergence B: bash proceeds on a multi-document payload" "2" "$MULTI_RC"
MULTI_PS_RC=0
printf '%s' "$MULTIDOC" \
  | env "FM_HOME=$PRIMARY_N" "FM_ROOT_OVERRIDE=$PRIMARY_N" \
      pwsh -NoProfile -File "$(to_native "$PRIMARY/bin/fm-turnend-guard.ps1")" >/dev/null 2>&1 \
  || MULTI_PS_RC=$?
assert_same "divergence B: the twin treats a multi-document payload as unreadable" "0" "$MULTI_PS_RC"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the turn-end hook twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# Asserted from an OBSERVED green run, so a refactor that silently drops whole
# phases fails loudly instead of certifying an empty suite.
MIN_ASSERTIONS=109
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the four turn-end hook twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-turnend-psm1.test.sh: all assertions passed\n'
