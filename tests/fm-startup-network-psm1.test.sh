#!/usr/bin/env bash
# tests/fm-startup-network-psm1.test.sh - differential tests for
# bin/fm-startup-network.ps1 against bin/fm-startup-network.sh, the deferred
# network stage a session start launches instead of running its network work on
# the blocking path.
#
# The bash tree is the ORACLE (docs/powershell-port.md): every case drives both
# implementations with the same fixture and compares exit code, stdout, stderr,
# and every state file written. tests/fm-startup-network.test.sh owns the
# stage's CONTRACT; this suite owns the claim that the PowerShell twin obeys it
# identically.
#
# ---------------------------------------------------------------------------
# THE TWO COST RULES THIS FILE IS BUILT AROUND
#
#   1. ONE pwsh FOR THE WHOLE SUITE. A bare `pwsh -NoProfile -Command "exit 0"`
#      costs ~5s on this host, so a suite that spawns one per case never
#      finishes. Every PowerShell case is written to a TAB-delimited case FILE;
#      one driver process runs them all IN-PROCESS and writes per-case
#      out/err/rc files; bash then joins by LABEL.
#   2. THE ORACLE HALF IS FORK-BOUND. The bash side uses builtins (parameter
#      expansion, `case`, `$(<file)`) wherever it does not cost coverage, and
#      forks only for the script under test.
#
# The `start` cases are where those rules meet this script's own subject: the
# driver's stdout IS a pipe bash reads to EOF, so a worker that inherited it
# would wedge THIS SUITE. A hang in phase 2 is therefore a real finding about
# the detachment, not a slow machine.
#
# ---------------------------------------------------------------------------
# WHY NO CASE COMPARES A LIVE ELAPSED TIME
#
# The oracle is fork-bound and the twin is interpreter-bound, so the same run
# takes wildly different wall time in the two worlds and every "in Ns" string
# would differ by construction. Following tests/fm-session-psm1.test.sh's
# seed_network_pin, the in-flight and finished states are PINNED instead:
#   - `started=pinned` is deliberately non-numeric, because worker_alive treats
#     an unparseable age as ALIVE and print_pending SKIPS its "Started Ns ago"
#     line - which removes the last timing-dependent byte from IN PROGRESS;
#   - a finished record carries fixed started/finished stamps, so "completed off
#     the startup path in 7s" is a constant;
#   - the timings artifact a `report` renders is a PINNED file, so the rendered
#     table is a constant too.
# The cases that genuinely RUN the stage compare state files with the volatile
# fields (pid, epoch stamps, generation, elapsed milliseconds) normalized to
# placeholders, never the raw numbers.
#
# The same rule has a second, less obvious face: an artifact whose CONTENTS
# depend on how fast a child reaches a write is as timing-dependent as a printed
# duration. The run-timeout case hit exactly that, and its comment records the
# measurement and the fix - the fixture stops racing, the comparison stays whole.
#
# ---------------------------------------------------------------------------
# WHY FIXTURES LIVE ON A DRIVE PATH, AND WHY EACH SIDE GETS ITS OWN HOME
#
# Git Bash's /tmp is an MSYS mount-table fiction with no native spelling, so a
# fixture there is /tmp/x to bash and C:\Users\...\Temp\x to .NET. Rooting
# TMPDIR on a real drive makes the two spellings exact mirrors (/f/x <-> F:\x).
#
# The two implementations MUTATE the home they are pointed at, so each side gets
# its own copy of every home; the homes are never printed, so nothing needs
# normalizing for them. They SHARE one fixture root, which IS printed (every
# "rerun <root>/bin/fm-startup-network.sh ..." line), and both worlds render it
# as the same POSIX string - bash because that is what FM_ROOT_OVERRIDE held,
# PowerShell because Get-FmContext publishes PosixRoot for exactly this.
#
# FM_HOME reaches the PowerShell side in NATIVE spelling, which is what MSYS
# itself does when bash launches a native binary with a path-valued variable
# (measured: FM_HOME=/f/x arrives as F:/x). It is not cosmetic: PowerShell's
# Join-Path turns a POSIX-rooted path into \f\x, which resolves against the
# CURRENT DRIVE, so a POSIX FM_HOME set INSIDE pwsh sends fm-wake-lib's queue to
# a phantom directory. Passing each world the spelling it would really receive
# keeps this suite testing the twin rather than that boundary.
set -u

# TMPDIR must be set BEFORE lib.sh is sourced: the cleanup registry path is
# computed at source time.
_suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR="$_suite_root/.no-mistakes/ps-startup-network-tmp"
mkdir -p "$TMPDIR"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || fail "pwsh is required for the PowerShell differential suite"

# Symmetry: the driver clears exactly these before every case, so the oracle
# must not inherit an ambient value for a case that deliberately sets none. A
# captain running this suite from a live firstmate session has FM_HOME exported.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_STARTUP_NETWORK_TIMEOUT FM_SESSION_START_TIMEOUT FM_TIMING_LOG FM_TIMING_EPOCH_MS \
  FM_FAKE_BOOTSTRAP_LOG FM_FAKE_BOOTSTRAP_OUT FM_FAKE_BOOTSTRAP_SLEEP FM_FAKE_BOOTSTRAP_RC \
  FM_FAKE_TIMING_PHASE FM_FAKE_TIMING_DETAIL FM_FAKE_TIMING_SKIP \
  FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK CDPATH

TMP_ROOT=$(fm_test_tmproot fm-startup-network-ps)
OUT="$TMP_ROOT/out"
HOMES="$TMP_ROOT/homes"
LOGS="$TMP_ROOT/logs"
FX="$TMP_ROOT/root"
CASE_FILE="$TMP_ROOT/cases.tsv"
mkdir -p "$OUT" "$HOMES" "$LOGS"
: > "$CASE_FILE"

# Unit/record separators keep argv and environment lists unambiguous inside one
# TAB-delimited line; no fixture value contains either byte.
ES=$'\037'
AS=$'\036'
TAB=$'\t'

progress() { printf '# %s\n' "$1" >&2; }

ASSERTIONS=0
# Observed on a green run; a suite that silently stops exercising cases must
# fail rather than report success on a handful of assertions.
MIN_ASSERTIONS=135

# --- assertions --------------------------------------------------------------

assert_eq() { # actual expected label
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- powershell ---"$'\n'"$1"$'\n'"--- bash oracle ---"$'\n'"$2"
}

# --- pure-bash helpers (every avoided fork is worth ~3s under load) -----------

# nat <posix-path>: the native spelling of an /x/... drive path. The fixtures
# only ever live on a drive, which is the whole point of rooting TMPDIR there,
# so this needs no cygpath fork.
nat() {
  local p=$1 drive rest
  case "$p" in
    /?/*)
      drive=${p:1:1}
      rest=${p:2}
      printf '%s:%s' "${drive^^}" "${rest//\//\\}"
      ;;
    *) printf '%s' "$p" ;;
  esac
}

# norm_status <file>: the status record with every volatile field replaced.
norm_status() {
  local line key val
  [ -f "$1" ] || { printf 'ABSENT\n'; return 0; }
  while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    case "$key" in
      pid|lock_pid)
        case "$val" in '' | *[!0-9]*) ;; *) val='@PID@' ;; esac
        ;;
      started|finished)
        case "$val" in '' | *[!0-9]*) ;; *) val='@EPOCH@' ;; esac
        ;;
      generation)
        case "$val" in *.*.*) val='@GEN@' ;; esac
        ;;
    esac
    printf '%s=%s\n' "$key" "$val"
  done < "$1"
}

# norm_wake <file>: the durable wake records with epoch and sequence replaced.
norm_wake() {
  local line rest
  [ -f "$1" ] || { printf 'ABSENT\n'; return 0; }
  while IFS= read -r line; do
    rest=${line#*"$TAB"}
    rest=${rest#*"$TAB"}
    printf '@EPOCH@\t@SEQ@\t%s\n' "$rest"
  done < "$1"
}

# norm_timings <file>: the timing records with the two millisecond columns
# replaced, so the artifact's SHAPE is compared and its live durations are not.
norm_timings() {
  local line f1 f2 f3 f4 f5 f6
  [ -f "$1" ] || { printf 'ABSENT\n'; return 0; }
  while IFS=$'\t' read -r f1 f2 f3 f4 f5 f6; do
    [ -n "$f1" ] || continue
    case "$f4$f5" in '' | *[!0-9]*) ;; *) f4='@MS@'; f5='@MS@' ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$f1" "$f2" "$f3" "$f4" "$f5" "$f6"
  done < "$1"
}

file_or_absent() { # <path>
  if [ -f "$1" ]; then printf '%s' "$(<"$1")"; else printf 'ABSENT'; fi
}

# --- fixture root ------------------------------------------------------------
#
# A full copy of bin/, with fm-bootstrap replaced on BOTH sides by a scriptable
# stand-in. The stage's contract is about WHEN and WHETHER the network half runs
# and how its result is published; bin/fm-bootstrap's own behavior is owned by
# its own suites, so pinning it here would duplicate that owner and make these
# assertions depend on unrelated tool detection.
#
# Both stand-ins record the same log line and the same timing record, which is
# what proves the stage hands FM_TIMING_LOG to its child in either language and
# publishes what the child wrote.

progress 'phase 0: fixture root'
cp -r "$_suite_root/bin" "$FX" || fail "could not build the fixture bin/"
mkdir -p "$TMP_ROOT/rootdir"
mv "$FX" "$TMP_ROOT/rootdir/bin" || fail "could not place the fixture bin/"
FX="$TMP_ROOT/rootdir"
FX_BIN="$FX/bin"

cat > "$FX_BIN/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
# Scriptable stand-in: records how it was invoked, then behaves as the test asks.
set -u
printf 'network=%s detect_only=%s\n' \
  "${FM_BOOTSTRAP_NETWORK:-all}" "${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
  >> "${FM_FAKE_BOOTSTRAP_LOG:?}"
# FM_FAKE_TIMING_SKIP silences this record for the ONE case whose bound kills
# this stand-in mid-run; see the run-timeout case for why that record cannot be
# compared across the two worlds.
if [ -n "${FM_TIMING_LOG:-}" ] && [ -z "${FM_FAKE_TIMING_SKIP:-}" ]; then
  # shellcheck source=bin/fm-timing-lib.sh
  . "$(dirname "$0")/fm-timing-lib.sh"
  fm_timing_record phase "${FM_FAKE_TIMING_PHASE:-gh-auth}" \
    "$(( $(fm_timing_now_ms) - 1500 ))" "${FM_FAKE_TIMING_DETAIL:-}"
fi
[ -z "${FM_FAKE_BOOTSTRAP_SLEEP:-}" ] || sleep "$FM_FAKE_BOOTSTRAP_SLEEP"
[ -z "${FM_FAKE_BOOTSTRAP_OUT:-}" ] || printf '%s\n' "$FM_FAKE_BOOTSTRAP_OUT"
exit "${FM_FAKE_BOOTSTRAP_RC:-0}"
SH
chmod +x "$FX_BIN/fm-bootstrap.sh"

cat > "$FX_BIN/fm-bootstrap.ps1" <<'PSEOF'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Twin: the bash stand-in above. Same log line, same timing record, same exits.
$network = if ($env:FM_BOOTSTRAP_NETWORK) { $env:FM_BOOTSTRAP_NETWORK } else { 'all' }
$detect = if ($env:FM_BOOTSTRAP_DETECT_ONLY) { $env:FM_BOOTSTRAP_DETECT_ONLY } else { '0' }
[System.IO.File]::AppendAllText($env:FM_FAKE_BOOTSTRAP_LOG, "network=$network detect_only=$detect`n",
    [System.Text.UTF8Encoding]::new($false))
if ($env:FM_TIMING_LOG -and -not $env:FM_FAKE_TIMING_SKIP) {
    $clean = {
        param([string]$t)
        if ($null -eq $t) { return '' }
        if ($t -cmatch "[ `t`n`v`f`r]") { return 'unrecordable' }
        $c = $t -creplace '[^A-Za-z0-9._@:/+-]', '_'
        if ($c.Length -gt 80) { $c = $c.Substring(0, 80) }
        return $c
    }
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 1500
    [long]$epoch = 0
    if (-not [long]::TryParse($env:FM_TIMING_EPOCH_MS, [ref]$epoch)) { $epoch = $start }
    $offset = $start - $epoch
    if ($offset -lt 0) { $offset = 0 }
    $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $start
    $phase = if ($env:FM_FAKE_TIMING_PHASE) { $env:FM_FAKE_TIMING_PHASE } else { 'gh-auth' }
    $detail = if ($env:FM_FAKE_TIMING_DETAIL) { $env:FM_FAKE_TIMING_DETAIL } else { '' }
    $record = "v1`t$(& $clean 'phase')`t$(& $clean $phase)`t$offset`t$elapsed`t$(& $clean $detail)`n"
    [System.IO.File]::AppendAllText($env:FM_TIMING_LOG, $record, [System.Text.UTF8Encoding]::new($false))
}
if ($env:FM_FAKE_BOOTSTRAP_SLEEP) { Start-Sleep -Seconds ([double]$env:FM_FAKE_BOOTSTRAP_SLEEP) }
if ($env:FM_FAKE_BOOTSTRAP_OUT) { [Console]::Out.Write($env:FM_FAKE_BOOTSTRAP_OUT + "`n") }
if ($env:FM_FAKE_BOOTSTRAP_RC) { exit ([int]$env:FM_FAKE_BOOTSTRAP_RC) }
exit 0
PSEOF

[ -f "$FX_BIN/fm-startup-network.ps1" ] || fail "bin/fm-startup-network.ps1 does not exist"

# --- homes and case plumbing -------------------------------------------------

mk_home() { # <name>
  mkdir -p "$HOMES/$1/sh/state" "$HOMES/$1/ps/state"
}

# seed <name> <file-suffix>: write stdin into BOTH sides' state/<suffix>.
seed() {
  local body
  body=$(cat)
  printf '%s\n' "$body" > "$HOMES/$1/sh/state/$2"
  printf '%s\n' "$body" > "$HOMES/$1/ps/state/$2"
}

# add_case <label> <home> <extra-env> <argspec>
#
# Runs the BASH oracle immediately (capturing out/err/rc) and appends the
# PowerShell half to the case file for the single driver run. Each side is
# handed its OWN home, in the spelling that world really receives, and the two
# sides share the one fixture root.
add_case() {
  local label=$1 home=$2 extra=$3 argspec=$4 rc=0
  local -a envpairs=() argv=()
  local envsh="FM_HOME=$HOMES/$home/sh${ES}FM_ROOT_OVERRIDE=$FX${ES}FM_FAKE_BOOTSTRAP_LOG=$LOGS/$label.sh.log"
  local envps
  envps="FM_HOME=$(nat "$HOMES/$home/ps")${ES}FM_ROOT_OVERRIDE=$(nat "$FX")${ES}FM_FAKE_BOOTSTRAP_LOG=$(nat "$LOGS/$label.ps.log")"
  if [ -n "$extra" ]; then
    envsh="$envsh$ES$extra"
    envps="$envps$ES$extra"
  fi
  IFS=$ES read -r -a envpairs <<< "$envsh"
  [ "$argspec" = "-" ] || IFS=$AS read -r -a argv <<< "$argspec"
  env ${envpairs[@]+"${envpairs[@]}"} "$FX_BIN/fm-startup-network.sh" \
    ${argv[@]+"${argv[@]}"} > "$OUT/$label.sh.out" 2> "$OUT/$label.sh.err" || rc=$?
  printf '%s\n' "$rc" > "$OUT/$label.sh.rc"
  printf '%s\t%s\t%s\n' "$label" "$envps" "$argspec" >> "$CASE_FILE"
}

compare_case() { # <label>
  local label=$1
  [ -f "$OUT/$label.ps.rc" ] || fail "$label: the PowerShell driver produced no result"
  assert_eq "$(<"$OUT/$label.ps.rc")" "$(<"$OUT/$label.sh.rc")" "$label: exit code differs"
  assert_eq "$(<"$OUT/$label.ps.out")" "$(<"$OUT/$label.sh.out")" "$label: stdout differs"
  assert_eq "$(<"$OUT/$label.ps.err")" "$(<"$OUT/$label.sh.err")" "$label: stderr differs"
}

# norm_took <text>: the ONE line that legitimately differs after a case that
# really ran the stage - "completed off the startup path in <N>s" - with its
# live elapsed seconds folded away. Used only where a case had to run for real;
# every pinned case compares the raw bytes.
norm_took() {
  local t=$1 head='completed off the startup path in ' rest num
  case "$t" in
    "$head"*)
      rest=${t#"$head"}
      num=${rest%%s:*}
      case "$num" in '' | *[!0-9]*) ;; *) t="${head}@S@s:${rest#*s:}" ;; esac
      ;;
  esac
  printf '%s' "$t"
}

compare_case_took() { # <label> - as compare_case, with the elapsed line folded
  local label=$1
  [ -f "$OUT/$label.ps.rc" ] || fail "$label: the PowerShell driver produced no result"
  assert_eq "$(<"$OUT/$label.ps.rc")" "$(<"$OUT/$label.sh.rc")" "$label: exit code differs"
  assert_eq "$(norm_took "$(<"$OUT/$label.ps.out")")" "$(norm_took "$(<"$OUT/$label.sh.out")")" \
    "$label: stdout differs"
  assert_eq "$(<"$OUT/$label.ps.err")" "$(<"$OUT/$label.sh.err")" "$label: stderr differs"
}

compare_state() { # <home> <what>  (status|report|timings|wake|claim|delivered|log:<label>)
  local home=$1 what=$2
  local sh=$HOMES/$home/sh/state ps=$HOMES/$home/ps/state
  case "$what" in
    status) assert_eq "$(norm_status "$ps/.startup-network.status")" \
      "$(norm_status "$sh/.startup-network.status")" "$home: status record differs" ;;
    report) assert_eq "$(file_or_absent "$ps/.startup-network.report")" \
      "$(file_or_absent "$sh/.startup-network.report")" "$home: published report differs" ;;
    timings) assert_eq "$(norm_timings "$ps/.startup-network.timings")" \
      "$(norm_timings "$sh/.startup-network.timings")" "$home: timings artifact differs" ;;
    wake) assert_eq "$(norm_wake "$ps/.wake-queue")" "$(norm_wake "$sh/.wake-queue")" \
      "$home: durable wake record differs" ;;
    claim) assert_eq "$(file_or_absent "$ps/.startup-network.claim")" \
      "$(file_or_absent "$sh/.startup-network.claim")" "$home: inline-print claim differs" ;;
    delivered) assert_eq "$(file_or_absent "$ps/.startup-network.delivered")" \
      "$(file_or_absent "$sh/.startup-network.delivered")" "$home: delivery acknowledgement differs" ;;
  esac
}

compare_log() { # <label>
  assert_eq "$(file_or_absent "$LOGS/$1.ps.log")" "$(file_or_absent "$LOGS/$1.sh.log")" \
    "$1: the bootstrap stand-in was not invoked identically"
}

# =============================================================================
# PHASE 1 - fixtures and oracle runs
# =============================================================================

# The pinned in-flight record. `pid` is this suite shell's own pid, which is
# alive in BOTH worlds' liveness checks (bash `kill -0`, and Test-FmPidAlive's
# MSYS namespace fallback), so `start` takes its single-flight branch and no
# real worker is launched for the pinned cases.
PINNED_STATUS="state=running
pid=$$
started=pinned
locked=1
phases=probe,sweeps
generation=fmtest-pinned
lock_pid="

# A finished record with FIXED stamps: 1786000000 -> 1786000007 is "in 7s" in
# both worlds forever.
DONE_STATUS="state=done
pid=$$
started=1786000000
finished=1786000007
rc=0
locked=1
phases=probe,sweeps
generation=fmtest-done
lock_pid=
report_published=1"

progress 'phase 1: argument-shape oracle runs'
mk_home shape
add_case help-long shape '' '--help'
add_case help-short shape '' '-h'
add_case unknown-mode shape '' 'bogus'
add_case no-mode shape '' '-'
add_case report-empty shape '' 'report'
add_case wait-unpublished shape '' "wait${AS}1"

progress 'phase 1: pinned in-flight oracle runs'
mk_home pending
seed pending .startup-network.status <<< "$PINNED_STATUS"
add_case report-pending pending '' 'report'
add_case harvest-pending pending '' "harvest${AS}--pid${AS}$$"

# A record older than the whole aggregate bound is abandoned even when its pid
# is alive, so "in progress" can never become permanent.
mk_home stale-record
seed stale-record .startup-network.status <<EOF
state=running
pid=$$
started=$(( $(date +%s) - 400 ))
locked=1
phases=probe,sweeps
generation=fmtest-stale
lock_pid=
EOF
add_case report-stale-record stale-record 'FM_STARTUP_NETWORK_TIMEOUT=10' 'report'

mk_home dead-worker
seed dead-worker .startup-network.status <<'EOF'
state=running
pid=999999999
started=1786000000
locked=1
phases=probe,sweeps
generation=fmtest-dead
lock_pid=
EOF
add_case report-dead-worker dead-worker '' 'report'

progress 'phase 1: finished-record oracle runs'
# The timings fixture is PINNED, so the rendered table is a constant: it carries
# a detail that must be appended to its name, an empty detail that must not, the
# 'unrecordable' marker a refused label leaves behind, a fourth record so the
# "slowest" line has to pick three, and two junk lines the renderer must skip
# (a wrong version tag and a too-short record).
mk_home finished
seed finished .startup-network.status <<< "$DONE_STATUS"
seed finished .startup-network.report <<'EOF'
sweep finding
EOF
{
  printf 'v1\tphase\tgh-auth\t0\t120\t\n'
  printf 'v1\tsecondmate\tliveness\t130\t4200\tmate-a@host-one\n'
  printf 'v1\tphase\tfleet-sync\t140\t900\tunrecordable\n'
  printf 'v1\tstage\tnetwork-checks\t5\t5400\tprobe_sweeps\n'
  printf 'v2\tphase\tignored-version\t1\t1\tx\n'
  printf 'v1\tshort\trecord\n'
} > "$HOMES/finished/sh/state/.startup-network.timings"
cp "$HOMES/finished/sh/state/.startup-network.timings" \
  "$HOMES/finished/ps/state/.startup-network.timings"
add_case report-finished finished '' 'report'
# harvest prints the same section WITHOUT the timings, and durably acknowledges.
add_case harvest-finished finished '' "harvest${AS}--pid${AS}$$"

mk_home unpublished
seed unpublished .startup-network.status <<'EOF'
state=failed
pid=999999999
started=1786000000
finished=1786000009
rc=1
locked=1
phases=probe,sweeps
generation=fmtest-unpublished
lock_pid=
report_published=0
EOF
add_case report-unpublished unpublished '' 'report'
# A result whose report was never published must NOT be acknowledged as printed.
add_case harvest-unpublished unpublished '' "harvest${AS}--pid${AS}$$"

mk_home timedout
seed timedout .startup-network.status <<'EOF'
state=timeout
pid=999999999
started=1786000000
finished=1786000122
rc=124
locked=0
phases=probe
generation=fmtest-timeout
lock_pid=
report_published=1
EOF
seed timedout .startup-network.report <<'EOF'
NETWORK_CHECKS: hit the 120s bound before finishing, so GitHub authentication may be incomplete
EOF
add_case report-timedout timedout '' 'report'

# A finished record with an EMPTY report file is the "no problems found" arm.
mk_home silent
seed silent .startup-network.status <<< "$DONE_STATUS"
: > "$HOMES/silent/sh/state/.startup-network.report"
: > "$HOMES/silent/ps/state/.startup-network.report"
add_case report-silent silent '' 'report'

progress 'phase 1: claim-handshake oracle runs'
# Another session's live claim is left alone; only a claim naming THIS harvester
# (or a harvest with no pid at all) is released.
mk_home foreign-claim
seed foreign-claim .startup-network.status <<< "$DONE_STATUS"
seed foreign-claim .startup-network.report <<'EOF'
foreign claim result
EOF
printf 'fmtest-done\t4242\n' > "$HOMES/foreign-claim/sh/state/.startup-network.claim"
printf 'fmtest-done\t4242\n' > "$HOMES/foreign-claim/ps/state/.startup-network.claim"
add_case harvest-foreign-claim foreign-claim '' "harvest${AS}--pid${AS}$$"

progress 'phase 1: start oracle runs'
# Single-flight: a live worker for the same lock owner is left alone. Nothing is
# launched, the status record is untouched, and only the claim is written - with
# the RESERVED generation, which is what a harvest then observes.
mk_home single-flight
seed single-flight .startup-network.status <<< "$PINNED_STATUS"
add_case start-single-flight single-flight '' "start${AS}--locked${AS}0${AS}--harvest-pid${AS}4242"

# Mutation authority: `start --locked 1` refuses outright when the fleet lock
# does not name this session, leaving no record and launching nothing.
mk_home unowned-lock
printf '999999999\n' > "$HOMES/unowned-lock/sh/state/.lock"
printf '999999999\n' > "$HOMES/unowned-lock/ps/state/.lock"
add_case start-unowned-lock unowned-lock '' "start${AS}--locked${AS}1${AS}--harvest-pid${AS}4242"

progress 'phase 1: run oracle runs (each drives the bootstrap stand-in)'
mk_home run-probe
add_case run-probe run-probe 'FM_FAKE_BOOTSTRAP_OUT=sweep finding' "run${AS}--locked${AS}0"

# The worker outlives the command that launched it. If another session took the
# lock meanwhile, running the mutating sweeps would sweep underneath that
# session, so they are refused - and the refusal is reported, not silent.
mk_home run-downgrade
printf '222222\n' > "$HOMES/run-downgrade/sh/state/.lock"
printf '222222\n' > "$HOMES/run-downgrade/ps/state/.lock"
add_case run-downgrade run-downgrade '' "run${AS}--locked${AS}1${AS}--lock-pid${AS}111111"

mk_home run-failed
add_case run-failed run-failed 'FM_FAKE_BOOTSTRAP_RC=3' "run${AS}--locked${AS}0"

# FM_FAKE_TIMING_SKIP is the ONE fixture concession in this suite, and it removes
# a race rather than relaxing a comparison. The stand-in writes its timing record
# BEFORE its sleep, so whether that record exists when the 2s bound kills the
# child is decided by how fast the child reaches the append - and the two worlds
# reach it at wildly different speeds. Measured on this host, same fixture, same
# settings, three runs each:
#   oracle: record present 1 of 3   (the bash stand-in pays a source plus four
#           command substitutions before its append, at ~1s per fork under load,
#           against a 2s bound)
#   twin:   record present 3 of 3   (one process start, then a microsecond append)
# Neither world is wrong - both kill the tree at the deadline and publish
# whatever the child wrote - so the artifact is genuinely nondeterministic and
# comparing it compares the host's fork cost. Silencing the child's record makes
# the published artifact exactly the stage total, which the stage writes AFTER
# the bounded run returns and therefore cannot race; the comparison below is a
# full byte comparison, strengthened rather than weakened. That a CHILD's record
# survives into the published artifact stays covered, deterministically, by
# run-probe and run-failed, neither of which involves the bound.
mk_home run-timeout
add_case run-timeout run-timeout \
  "FM_FAKE_BOOTSTRAP_SLEEP=20${ES}FM_STARTUP_NETWORK_TIMEOUT=2${ES}FM_SESSION_START_TIMEOUT=1${ES}FM_FAKE_TIMING_SKIP=1" \
  "run${AS}--locked${AS}0"

progress 'phase 1: detached start, then wait for its worker'
# The only case that launches a REAL detached worker. It proves the whole
# handshake end to end: `start` returns without holding its caller's stdout,
# reserves the generation the harvest observes, and the worker it launched
# records its own pid, runs the bootstrap phase, publishes, reaps the dead claim
# and queues the wake.
mk_home detached
#
# No `report` between the start and the wait: whether the worker has finished by
# then is a race the two worlds run at different speeds, and the finished text
# carries a live elapsed count. The in-flight rendering is pinned instead, by
# report-pending above.
add_case start-detached detached '' "start${AS}--locked${AS}0${AS}--harvest-pid${AS}999999999"
add_case start-detached-wait detached '' "wait${AS}90"
add_case start-detached-settled detached '' 'harvest'

# =============================================================================
# PHASE 2 - one pwsh for every PowerShell case
# =============================================================================

progress 'phase 2: one pwsh driver for every PowerShell case'

cat > "$TMP_ROOT/driver.ps1" <<'PSEOF'
# One process, every case. See the suite header for why this shape is mandatory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$caseFile = $args[0]
$outDir = $args[1]
$script = $args[2]

# Deliberately NOT importing fm-common: the entrypoint imports it with -Force,
# which REMOVES the loaded copy before re-importing, and the driver must not
# depend on a binding that disappears mid-run.
$clearNames = @(
    'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
    'FM_STARTUP_NETWORK_TIMEOUT', 'FM_SESSION_START_TIMEOUT',
    'FM_TIMING_LOG', 'FM_TIMING_EPOCH_MS',
    'FM_FAKE_BOOTSTRAP_LOG', 'FM_FAKE_BOOTSTRAP_OUT', 'FM_FAKE_BOOTSTRAP_SLEEP',
    'FM_FAKE_BOOTSTRAP_RC', 'FM_FAKE_TIMING_PHASE', 'FM_FAKE_TIMING_DETAIL',
    'FM_FAKE_TIMING_SKIP', 'FM_WAKE_QUEUE', 'FM_WAKE_QUEUE_LOCK', 'CDPATH'
)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$unit = [char]0x1F
$record = [char]0x1E

foreach ($line in [System.IO.File]::ReadAllLines($caseFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = @($line.Split("`t"))
    if ($fields.Count -ne 3) { throw "malformed case record: $line" }
    $label = $fields[0]
    $envSpec = $fields[1]
    $argSpec = $fields[2]

    foreach ($name in $clearNames) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
    if ($envSpec -ne '-') {
        foreach ($pair in @($envSpec.Split($unit))) {
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            Set-Item -Path ('Env:' + $pair.Substring(0, $eq)) -Value $pair.Substring($eq + 1)
        }
    }
    # Assigned in STATEMENT form, never as `$argv = if (...) { @(...) }`: an if
    # used as an expression writes its result through the output stream, and the
    # stream UNROLLS a single-element array into a bare string.
    $argv = @()
    if ($argSpec -ne '-') { $argv = [string[]]@($argSpec.Split($record)) }

    $oldOut = [Console]::Out
    $oldErr = [Console]::Error
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $global:LASTEXITCODE = -1
    $rc = -1
    try {
        & $script @argv
        $rc = $LASTEXITCODE
    } catch {
        $rc = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        [Console]::SetOut($oldOut)
        [Console]::SetError($oldErr)
    }

    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.out"), $so.ToString(), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.err"), $se.ToString(), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.rc"), "$rc`n", $utf8)
}
PSEOF

# MSYS2_ARG_CONV_EXCL is scoped to this one invocation: a blanket export would
# break the doubled-slash idiom other suites rely on. Paths that must be native
# are converted explicitly.
MSYS2_ARG_CONV_EXCL='*' pwsh -NoProfile -File "$(nat "$TMP_ROOT/driver.ps1")" \
  "$(nat "$CASE_FILE")" "$(nat "$OUT")" "$(nat "$FX_BIN/fm-startup-network.ps1")" \
  || fail "the PowerShell driver exited non-zero"

# =============================================================================
# PHASE 3 - join by label and compare
# =============================================================================

test_argument_shapes() {
  compare_case help-long
  compare_case help-short
  compare_case unknown-mode
  compare_case no-mode
  compare_case report-empty
  compare_case wait-unpublished
  # The header IS the usage text in both worlds, so a drifting comment block is
  # a real failure rather than cosmetics.
  case "$(<"$OUT/help-long.ps.out")" in
    "fm-startup-network.sh - the deferred network stage of a session start."*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "help-long: the PowerShell twin did not render the shared header" ;;
  esac
  assert_eq "$(<"$OUT/unknown-mode.ps.rc")" 2 'an unknown mode must still exit 2 in PowerShell'
  assert_eq "$(<"$OUT/wait-unpublished.ps.rc")" 1 'wait must fail when no stage publishes'
  pass "fm-startup-network.ps1: --help, an unknown mode and a failed wait match the bash oracle"
}

test_in_progress_reporting() {
  compare_case report-pending
  compare_case harvest-pending
  compare_state pending status
  compare_state pending claim
  compare_state pending delivered
  case "$(<"$OUT/report-pending.ps.out")" in
    "IN PROGRESS - the deferred network checks have not finished yet."*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "report-pending: the twin did not report an in-flight stage" ;;
  esac
  case "$(<"$OUT/report-pending.ps.out")" in
    *"Started "*) fail "report-pending: a non-numeric start stamp still printed an age" ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac
  case "$(<"$OUT/harvest-pending.ps.out")" in
    *"NOT yet confirmed: GitHub authentication, dead-secondmate relaunch"*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "harvest-pending: the digest section did not name the unconfirmed checks" ;;
  esac
  compare_case report-stale-record
  compare_case report-dead-worker
  case "$(<"$OUT/report-dead-worker.ps.out")" in
    "NETWORK_CHECKS: the deferred check worker stopped before publishing"*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "report-dead-worker: an abandoned run did not read as needing a rerun" ;;
  esac
  pass "fm-startup-network.ps1: in-flight, abandoned and outlived-the-bound records read identically"
}

test_finished_reporting_and_acknowledgement() {
  compare_case report-finished
  compare_case harvest-finished
  compare_state finished status
  compare_state finished delivered
  # The timings belong to the on-demand report ONLY: a timing line in the digest
  # section would be a change to every session start's output.
  case "$(<"$OUT/report-finished.ps.out")" in
    *'TIMINGS - where the deferred network checks spent their time (ms):'*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "report-finished: the twin printed no timings table" ;;
  esac
  # Ordered by elapsed DESCENDING, three deep, each label carrying its detail:
  # 5400, 4200, 900 - and NOT the 120ms record, which is what proves the twin
  # sorts rather than truncating the file order.
  case "$(<"$OUT/report-finished.ps.out")" in
    *'slowest: stage network-checks probe_sweeps 5400ms, secondmate liveness mate-a@host-one 4200ms, phase fleet-sync unrecordable 900ms'*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "report-finished: the twin did not order the slowest steps like awk" ;;
  esac
  case "$(<"$OUT/report-finished.ps.out")" in
    *ignored-version*) fail "report-finished: the twin rendered a record awk would skip" ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac
  case "$(<"$OUT/harvest-finished.ps.out")" in
    *TIMINGS* | *slowest:*) fail "harvest-finished: the timings leaked into the digest section" ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac
  assert_eq "$(file_or_absent "$HOMES/finished/ps/state/.startup-network.delivered")" 'delivered' \
    'harvest did not durably acknowledge the result it printed'

  compare_case report-unpublished
  compare_case harvest-unpublished
  compare_state unpublished delivered
  assert_eq "$(file_or_absent "$HOMES/unpublished/ps/state/.startup-network.delivered")" 'ABSENT' \
    'harvest acknowledged a result whose report was never published'
  compare_case report-timedout
  compare_case report-silent
  case "$(<"$OUT/report-silent.ps.out")" in
    *'(silent - no problems found)'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "report-silent: an empty report did not read as no problems found" ;;
  esac
  pass "fm-startup-network.ps1: finished, unpublishable, timed-out and silent results render identically"
}

test_claim_handshake() {
  compare_case harvest-foreign-claim
  compare_state foreign-claim claim
  assert_eq "$(file_or_absent "$HOMES/foreign-claim/ps/state/.startup-network.claim")" \
    "fmtest-done${TAB}4242" 'another session live claim must survive this harvest'
  pass "fm-startup-network.ps1: another session's claim is left alone, exactly as in bash"
}

test_start_single_flight_and_authority() {
  compare_case start-single-flight
  compare_state single-flight status
  compare_state single-flight claim
  compare_log start-single-flight
  assert_eq "$(norm_status "$HOMES/single-flight/ps/state/.startup-network.status")" \
    "$(norm_status "$HOMES/single-flight/sh/state/.startup-network.status")" \
    'single-flight rewrote the live worker record'
  assert_eq "$(file_or_absent "$HOMES/single-flight/ps/state/.startup-network.claim")" \
    "fmtest-pinned${TAB}4242" 'single-flight did not claim the RESERVED generation'
  assert_eq "$(file_or_absent "$LOGS/start-single-flight.ps.log")" 'ABSENT' \
    'a second start launched a competing worker'

  compare_case start-unowned-lock
  compare_state unowned-lock status
  compare_state unowned-lock claim
  compare_log start-unowned-lock
  assert_eq "$(file_or_absent "$HOMES/unowned-lock/ps/state/.startup-network.status")" 'ABSENT' \
    'a refused start still recorded a stage'
  assert_eq "$(file_or_absent "$LOGS/start-unowned-lock.ps.log")" 'ABSENT' \
    'a start refused for want of the fleet lock still launched a worker'
  pass "fm-startup-network.ps1: single-flight and lock-ownership refusal behave identically"
}

test_run_publishes_identically() {
  local label
  for label in run-probe run-downgrade run-failed run-timeout; do
    compare_case "$label"
    compare_log "$label"
  done
  compare_state run-probe status
  compare_state run-probe report
  compare_state run-probe timings
  compare_state run-probe wake
  assert_eq "$(file_or_absent "$LOGS/run-probe.ps.log")" 'network=only detect_only=1' \
    'the read-only probe did not run bootstrap network-only in detect-only mode'

  compare_state run-downgrade status
  compare_state run-downgrade report
  case "$(file_or_absent "$HOMES/run-downgrade/ps/state/.startup-network.report")" in
    *'NETWORK_CHECKS: the fleet lock was no longer held'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "run-downgrade: the downgrade to a read-only probe was not reported" ;;
  esac

  compare_state run-failed status
  compare_state run-failed report
  case "$(file_or_absent "$HOMES/run-failed/ps/state/.startup-network.report")" in
    *'NETWORK_CHECKS: the deferred check worker exited 3'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "run-failed: a failing sweep was not reported with its exit code" ;;
  esac

  compare_state run-timeout status
  compare_state run-timeout report
  compare_state run-timeout timings
  case "$(file_or_absent "$HOMES/run-timeout/ps/state/.startup-network.report")" in
    *'NETWORK_CHECKS: hit the 2s bound before finishing'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "run-timeout: the aggregate bound was swallowed instead of reported" ;;
  esac
  case "$(norm_status "$HOMES/run-timeout/ps/state/.startup-network.status")" in
    'state=timeout'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "run-timeout: a bounded run did not record itself as timed out" ;;
  esac
  # Exact, not a shape: with the child's racing record silenced, a timed-out run
  # publishes precisely its own stage total, in both worlds.
  assert_eq "$(norm_timings "$HOMES/run-timeout/ps/state/.startup-network.timings")" \
    "v1${TAB}stage${TAB}network-checks${TAB}@MS@${TAB}@MS@${TAB}probe" \
    'a timed-out run did not publish the stage total it recorded after the bound'
  pass "fm-startup-network.ps1: probe, downgrade, failure and bound publish identically"
}

test_detached_worker_end_to_end() {
  compare_case start-detached
  compare_case start-detached-wait
  # The only stdout in this suite that is compared with a fold rather than byte
  # for byte, and only for the one live elapsed count (see norm_took).
  compare_case_took start-detached-settled
  compare_log start-detached
  compare_state detached status
  compare_state detached report
  compare_state detached timings
  compare_state detached wake
  compare_state detached claim
  assert_eq "$(<"$OUT/start-detached-wait.ps.rc")" 0 \
    'the detached PowerShell worker never published'
  assert_eq "$(file_or_absent "$LOGS/start-detached.ps.log")" 'network=only detect_only=1' \
    'the detached PowerShell worker never ran the bootstrap network phase'
  # The worker recorded its OWN pid, not the launcher's: that handshake is what
  # lets the worker prove the status record names it before it does any work.
  case "$(norm_status "$HOMES/detached/ps/state/.startup-network.status")" in
    'state=done'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "start-detached: the detached worker did not publish a finished record" ;;
  esac
  case "$(norm_wake "$HOMES/detached/ps/state/.wake-queue")" in
    *'check: startup-network: deferred startup network checks finished (done)'*)
      ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "start-detached: a result with no live claimant never reached the wake queue" ;;
  esac
  assert_eq "$(file_or_absent "$HOMES/detached/ps/state/.startup-network.claim")" 'ABSENT' \
    'a dead session stale claim was not reaped'
  pass "fm-startup-network.ps1: a real detached worker publishes, wakes and settles like the oracle"
}

test_assertion_floor() {
  [ "$ASSERTIONS" -ge "$MIN_ASSERTIONS" ] \
    || fail "only $ASSERTIONS assertions ran; expected at least $MIN_ASSERTIONS (cases stopped being exercised)"
  pass "fm-startup-network differential: $ASSERTIONS assertions compared against the bash oracle"
}

progress 'phase 3: joining and comparing'
test_argument_shapes
test_in_progress_reporting
test_finished_reporting_and_acknowledgement
test_claim_handshake
test_start_single_flight_and_authority
test_run_publishes_identically
test_detached_worker_end_to_end
test_assertion_floor
echo "# fm-startup-network-psm1.test.sh: all assertions passed"
