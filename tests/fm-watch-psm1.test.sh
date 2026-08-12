#!/usr/bin/env bash
# tests/fm-watch-psm1.test.sh - the differential suite for the PowerShell
# watcher twins: bin/fm-watch.psm1 (+ bin/fm-watch.ps1) and bin/fm-watch-arm.ps1.
#
# Bash is the ORACLE. Every case drives the bash original and the PowerShell twin
# with the SAME fixture and asserts they agree, because during the conversion
# both worlds read and write the same durable records: a watcher that classifies
# one wake differently in the two languages is a supervision defect that shows up
# as firstmate going QUIET, not as a loud failure.
#
# ---------------------------------------------------------------------------
# COST DISCIPLINE - the two rules that decide whether this suite finishes
#
# 1. EXACTLY TWO pwsh SPAWNS, both driving a whole PHASE. A bare
#    `pwsh -NoProfile -Command "exit 0"` costs 4.8s on the reference Windows
#    host, so a per-case spawn would put this suite past the point where it
#    times out with ZERO output and reads as a hang rather than as slowness
#    (docs/powershell-port.md, "The one rule that decides whether a suite
#    finishes"). Cases are written to a FILE, one driver evaluates all of them,
#    and the two sides are joined by LABEL.
# 2. THE ORACLE SIDE IS FORK-BOUND TOO. Under load a trivial fork on this host
#    was MEASURED at 3.1s. So the oracle helpers here never use `$( )`: `cap`
#    redirects a function's stdout to a scratch file and `read`s it back
#    (redirection and read are builtins, no subshell), and `pred` branches on the
#    exit status directly. Every assertion is recorded with `printf >>`, which is
#    also a builtin.
#
# ---------------------------------------------------------------------------
# NORMALIZATION RULES, DECLARED RATHER THAN APPLIED SILENTLY
#
# * PATH SPELLING. The oracle is handed the POSIX state path and the driver the
#   native one, deliberately: a POSIX path reaching a .NET API costs a cygpath
#   child (~1.2s on this host) on EVERY conversion, which would dominate the
#   run. Both sides therefore name the same directory differently, so every
#   value is compared after unifying separators to '/' and replacing that
#   world's own state-directory prefix with the literal @STATE@. What the cases
#   prove - WHICH file each function reads and writes - is unchanged.
# * ELAPSED SECONDS. Reason strings embed an "idle <n>s" / "paused <n>s" age
#   computed at the moment each side runs, and the two sides run minutes apart on
#   a loaded host. Those digits are replaced with <N> on both sides. Everything
#   else in the reason - the escalation COUNT, and the demand-deep-inspection
#   marker that makes a repeat wedge force a closer look - is deterministic and
#   is compared exactly.
# * MULTI-VALUED RESULTS are joined with '|' on both sides.
# * NONDETERMINISTIC VALUES (pids, epochs, queue sequence numbers) are never
#   compared as values; a timestamp marker is asserted as "numeric" instead.
#
# Read-only cases share ONE fixture between the two worlds. Mutating cases get a
# per-world copy built by the identical fixture function, so the assertion covers
# the state each side WRITES, not only what it returns.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# wake-helpers.sh brings lib.sh (ROOT, fail, pass, fm_test_tmproot,
# fm_write_meta), the fake crew-state builder the pause classifier needs, and -
# importantly - an FM_ROOT_OVERRIDE pointing at a non-git scratch dir, so
# fm-guard's worktree-tangle banner cannot print into captured stdout.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in bin/fm-watch.psm1 bin/fm-watch.ps1 bin/fm-watch-arm.ps1; do
  [ -f "$ROOT/$f" ] || fail "$f is missing"
done

TMP_ROOT=$(fm_test_tmproot fm-watch-psm1)
NL=$'\n'
TAB=$'\t'

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# --- fixtures ----------------------------------------------------------------

SHARED="$TMP_ROOT/shared/state"
SHARED_AFK="$TMP_ROOT/shared-afk/state"
MUT_BASH="$TMP_ROOT/mut-bash/state"
MUT_PS="$TMP_ROOT/mut-ps/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$SHARED" "$SHARED_AFK" "$MUT_BASH" "$MUT_PS" "$FAKEBIN"
make_fake_crew_state "$FAKEBIN" >/dev/null
PATH="$FAKEBIN:$PATH"
export PATH
export FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh"
export FM_FAKE_CREW_STATE="state: unknown · source: none · fixture default"

build_shared() {  # <state-dir>
  local s=$1
  # Windows recorded through metadata: one plain ship, one explicit kind, one
  # secondmate, one meta with no backend= (the P1 "absent means tmux" contract),
  # and one endpoint recorded by TWO metas so the dedup in recorded_windows is
  # actually exercised rather than assumed.
  fm_write_meta "$s/alpha.meta" "window=sess:fm-alpha" "backend=tmux" "harness=claude"
  fm_write_meta "$s/bravo.meta" "window=sess:fm-bravo" "backend=herdr" "harness=codex" "kind=scout"
  fm_write_meta "$s/charlie.meta" "window=sess:fm-charlie" "backend=tmux" "kind=secondmate"
  fm_write_meta "$s/delta.meta" "window=sess:fm-delta" "harness=pi"
  fm_write_meta "$s/delta-dup.meta" "window=sess:fm-delta"
  printf 'working: compiling\n' > "$s/alpha.status"
  printf 'working: one\ndone: PR https://example.invalid/pr/1 checks green\n' > "$s/bravo.status"
  printf 'paused: waiting on CI\n' > "$s/charlie.status"
  : > "$s/alpha.turn-ended"
  # A pre-seen signal, so the scan proves it reports only what CHANGED.
  printf '%s' "$(seen_signature "$s/alpha.status")" > "$s/.seen-alpha_status"
}

seen_signature() {  # <file> - the same size:mtime shape fm-watch.sh's stat_sig writes
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

build_shared "$SHARED"
build_shared "$SHARED_AFK"
: > "$SHARED_AFK/.afk"

# Busy-turn-age fixtures: a fresh completed turn, one aged far past any bound,
# and a task with no turn marker at all so the spawn-record fallback is covered.
: > "$SHARED/fresh.turn-ended"
fm_write_meta "$SHARED/fresh.meta" "window=sess:fm-fresh"
: > "$SHARED/aged.turn-ended"
fm_write_meta "$SHARED/aged.meta" "window=sess:fm-aged"
fm_write_meta "$SHARED/noturn.meta" "window=sess:fm-noturn"
age_file() {  # <file> <seconds-ago>
  local f=$1 secs=$2 epoch stamp
  epoch=$(( $(date +%s) - secs ))
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then touch -t "$stamp" "$f"
  else touch -t "$(date -d "@$epoch" +%Y%m%d%H%M.%S)" "$f"; fi
}
age_file "$SHARED/aged.turn-ended" 100000
age_file "$SHARED/noturn.meta" 100000

# Heartbeat backstop: one captain-relevant status already marked surfaced, one
# not. The "yes" fixture must live in its own directory or the "none" case could
# never be observed.
HB_NONE="$TMP_ROOT/hb-none/state"
HB_YES="$TMP_ROOT/hb-yes/state"
mkdir -p "$HB_NONE" "$HB_YES"
printf 'needs-decision: pick A or B\n' > "$HB_NONE/echo.status"
printf '%s' 'needs-decision: pick A or B' > "$HB_NONE/.hb-surfaced-echo"
printf 'needs-decision: pick A or B\n' > "$HB_YES/echo.status"

build_mut() {  # <state-dir>
  local s=$1
  fm_write_meta "$s/wedge.meta" "window=sess:fm-wedge" "backend=tmux"
  printf 'working: still going\n' > "$s/wedge.status"
  fm_write_meta "$s/hold.meta" "window=sess:fm-hold" "backend=tmux"
  printf 'paused: awaiting upstream release\n' > "$s/hold.status"
  fm_write_meta "$s/quiet.meta" "window=sess:fm-quiet" "backend=tmux"
  printf 'working: quiet\n' > "$s/quiet.status"
  fm_write_meta "$s/heldq.meta" "window=sess:fm-heldq" "backend=tmux"
  printf 'needs-decision: which base\n' > "$s/heldq.status"
  fm_write_meta "$s/second.meta" "window=sess:fm-second" "backend=tmux" "kind=secondmate"
  printf 'paused: awaiting routed work\n' > "$s/second.status"
  # Pre-existing pause bookkeeping, so the clear paths have something to clear.
  : > "$s/.paused-sess_fm-hold"
  : > "$s/.paused-rechecked-sess_fm-hold"
  : > "$s/.paused-resurfaced-sess_fm-hold"
  printf 'deadbeef' > "$s/.stale-sess_fm-hold"
  printf '123' > "$s/.stale-since-sess_fm-hold"
  printf '2' > "$s/.wedge-escalations-sess_fm-hold"
  # An old status mtime so the pause re-surface cadence can fire.
  age_file "$s/hold.status" 100000
  # The secondmate pause fixture: a declared pause, a live pause marker, and a
  # FRESH recheck stamp, which together are what let pause_state_class answer
  # "paused" without reading agent liveness at all. Built in BOTH worlds' state
  # dirs - building it in only one is a fixture asymmetry that reads exactly like
  # a conversion defect.
  : > "$s/.paused-sess_fm-second"
  printf '%s' "$(date +%s)" > "$s/.paused-rechecked-sess_fm-second"
}
build_mut "$MUT_BASH"
build_mut "$MUT_PS"

# --- assertion bookkeeping ---------------------------------------------------
#
# Plain shell variables, never a `( ... )` subshell: a subshell cannot report a
# failure back to the parent's counters AND it fires lib.sh's inherited EXIT
# trap. A bookkeeping scheme that can lose a failure is worse than none, because
# the suite then certifies work it never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

ORACLE="$TMP_ROOT/oracle.tsv"
CASES="$TMP_ROOT/cases.tsv"
ACTUAL="$TMP_ROOT/actual.tsv"
CAPF="$TMP_ROOT/.capture"
WAKELOG="$TMP_ROOT/wake-bash.log"
: > "$ORACLE"; : > "$CASES"; : > "$ACTUAL"; : > "$WAKELOG"

# normalize <value> <state-dir-a> <state-dir-b>: unify separators, replace either
# world's state prefix with @STATE@, and blank out elapsed-second digits.
normalize() {
  local v=$1 a=$2 b=$3
  v=${v//\\//}
  a=${a//\\//}
  b=${b//\\//}
  v=${v//"$a"/@STATE@}
  v=${v//"$b"/@STATE@}
  # `idle 217s` / `paused 100403s` -> `idle <N>s` / `paused <N>s`, without a
  # sed fork: strip digits between the keyword and the trailing 's'.
  while [[ $v =~ (idle|paused)\ [0-9]+s ]]; do
    v=${v/${BASH_REMATCH[0]}/${BASH_REMATCH[1]} <N>s}
  done
  printf '%s' "$v"
}

record() {  # record <label> <value> - oracle side, no fork
  printf '%s\t%s\n' "$1" "$2" >> "$ORACLE"
}

# The `|| [ -n "$line" ]` legs below are load-bearing, not defensive: almost
# every value this suite captures is written with `printf '%s'` and therefore has
# NO trailing newline, and plain `while read` discards exactly that last partial
# line. Without them the oracle silently records an empty string for most cases -
# which reads as "the twin invented a value" rather than as a harness bug.
cap() {  # cap <label> <command...> - capture stdout with no subshell
  local label=$1 line out=""
  shift
  "$@" > "$CAPF" 2>/dev/null
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$out" ]; then out=$line; else out="$out|$line"; fi
  done < "$CAPF"
  record "$label" "$out"
}

pred() {  # pred <label> <command...> - record a predicate's verdict, no subshell
  local label=$1
  shift
  if "$@"; then record "$label" true; else record "$label" false; fi
}

# The case FILE is TAB-delimited and line-oriented, so an argument that itself
# contains a TAB or a newline is encoded rather than smuggled through: the driver
# decodes <TAB> and <NL> back before use. Without this the multi-line hash case
# and the arm's whitespace-flattening case would silently become several
# malformed records instead of one.
case_line() {  # case_line <label> <op> [args...]
  local label=$1 op=$2 out a
  shift 2
  out="$label$TAB$op"
  for a in "$@"; do
    a=${a//$TAB/<TAB>}
    a=${a//$NL/<NL>}
    out="$out$TAB$a"
  done
  printf '%s\n' "$out" >> "$CASES"
}

# --- load the bash oracle ----------------------------------------------------
#
# fm-watch.sh carries a BASH_SOURCE main guard, so sourcing it loads the triage
# functions and returns BEFORE acquiring the singleton lock or entering the
# blocking loop - which is exactly what that guard exists for. FM_STATE_OVERRIDE
# is set first because the durable wake queue binds to it at source time on both
# sides.
export FM_STATE_OVERRIDE="$MUT_BASH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# The bash suite's standard technique: replace wake() so an actionable
# classification is observable without ending the process. The PowerShell twin
# cannot be redefined that way, so it exposes a -WakeAction scriptblock seam
# instead; both capture the reason and neither exits, which is what keeps the two
# comparable.
# shellcheck disable=SC2317  # invoked indirectly, through the sourced watcher functions.
wake() { printf '%s\n' "$1" >> "$WAKELOG"; }

# =============================================================================
# PHASE 1 - read-only contracts, one shared fixture
# =============================================================================

STATE="$SHARED"

# hash_pane: the pane-suppression key. Both worlds must agree byte-for-byte or a
# restart (or a cross-world handover) re-surfaces every already-classified pane.
hash_of() { printf '%s' "$1" | hash_pane; }
cap hash-empty      hash_of ""
cap hash-simple     hash_of "hello"
cap hash-multiline  hash_of "one${NL}two${NL}"
cap hash-utf8       hash_of "❯ progress ⣾"
case_line hash-empty     hash ""
case_line hash-simple    hash "hello"
case_line hash-multiline hash "one${NL}two${NL}"
case_line hash-utf8      hash "❯ progress ⣾"

# The per-window state key. The bash twin spells this two ways (`tr ':/.' '___'`
# and a chain of ${w//:/_}); one of them writes the marker the other deletes, so
# a drift here strands pause bookkeeping forever.
key_tr() { printf '%s' "$1" | tr ':/.' '___'; }
cap key-plain  key_tr "plain"
cap key-colon  key_tr "sess:fm-a"
cap key-slash  key_tr "a/b"
cap key-dot    key_tr "a.b"
cap key-all    key_tr "default:w1.2:p3/x"
case_line key-plain key "plain"
case_line key-colon key "sess:fm-a"
case_line key-slash key "a/b"
case_line key-dot   key "a.b"
case_line key-all   key "default:w1.2:p3/x"

cap sig-status  stat_sig "$SHARED/alpha.status"
cap sig-missing stat_sig "$SHARED/nope.status"
case_line sig-status  sig "$(to_native "$SHARED")\\alpha.status"
case_line sig-missing sig "$(to_native "$SHARED")\\nope.status"

# age_of's 999999 sentinel is load-bearing: an unreadable schedule marker must
# read as "due immediately", never as "recently done".
cap age-missing age_of "$SHARED/never-existed"
case_line age-missing age "$(to_native "$SHARED")\\never-existed"

cap kind-plain     window_kind "sess:fm-alpha"
cap kind-explicit  window_kind "sess:fm-bravo"
cap kind-secondmate window_kind "sess:fm-charlie"
cap kind-unknown   window_kind "sess:fm-nosuch"
cap backend-tmux   window_backend "sess:fm-alpha"
cap backend-herdr  window_backend "sess:fm-bravo"
cap backend-absent window_backend "sess:fm-delta"
cap backend-nometa window_backend "sess:fm-nosuch"
cap harness-known  window_harness "sess:fm-alpha"
cap harness-absent window_harness "sess:fm-charlie"
cap label-known    window_label "sess:fm-alpha"
cap label-unknown  window_label "sess:fm-nosuch"
case_line kind-plain      kind    "sess:fm-alpha"
case_line kind-explicit   kind    "sess:fm-bravo"
case_line kind-secondmate kind    "sess:fm-charlie"
case_line kind-unknown    kind    "sess:fm-nosuch"
case_line backend-tmux    backend "sess:fm-alpha"
case_line backend-herdr   backend "sess:fm-bravo"
case_line backend-absent  backend "sess:fm-delta"
case_line backend-nometa  backend "sess:fm-nosuch"
case_line harness-known   harness "sess:fm-alpha"
case_line harness-absent  harness "sess:fm-charlie"
case_line label-known     label   "sess:fm-alpha"
case_line label-unknown   label   "sess:fm-nosuch"

# recorded_windows: order and dedup are both observable, because the stale loop
# walks this list and a duplicate would double every marker write for one pane.
cap recorded-windows recorded_windows
case_line recorded-windows windows

# scan_signals is a PURE read - the .seen-* markers advance only after a wake is
# surfaced or deliberately absorbed - so a watcher killed mid-cycle can never
# swallow a signal. The pre-seen alpha.status proves the suppression works.
cap changed-signals scan_signals
case_line changed-signals signals

pred afk-absent  afk_present
STATE="$SHARED_AFK"
pred afk-present afk_present
case_line afk-absent  afk "$(to_native "$SHARED")"
case_line afk-present afk "$(to_native "$SHARED_AFK")"

STATE="$SHARED"
pred busyturn-fresh   busy_turn_over_age fresh
pred busyturn-aged    busy_turn_over_age aged
pred busyturn-nomarker busy_turn_over_age noturn
case_line busyturn-fresh    busyturn fresh
case_line busyturn-aged     busyturn aged
case_line busyturn-nomarker busyturn noturn

STATE="$HB_NONE"
pred heartbeat-surfaced heartbeat_scan_finds_actionable
STATE="$HB_YES"
pred heartbeat-pending  heartbeat_scan_finds_actionable
case_line heartbeat-surfaced heartbeat "$(to_native "$HB_NONE")"
case_line heartbeat-pending  heartbeat "$(to_native "$HB_YES")"

# =============================================================================
# PHASE 2 - mutating contracts, one fixture per world
# =============================================================================
#
# Each case records the returned value, the wake reason it emitted (or none), and
# an inventory of the markers it left behind, so the assertion covers what each
# side WROTE and not only what it returned.

STATE="$MUT_BASH"

markers() {  # markers <label> <key> - the private per-window bookkeeping, as text
  local label=$1 key=$2 out="" name f v
  for name in stale stale-since wedge-escalations paused paused-rechecked paused-resurfaced; do
    f="$STATE/.$name-$key"
    if [ -e "$f" ]; then
      v=""
      IFS= read -r v < "$f" || true
      case "$name" in
        stale-since|paused-rechecked|paused-resurfaced)
          # An epoch is nondeterministic; assert only that one was written.
          case "$v" in ''|*[!0-9]*) v="<non-numeric>" ;; *) v="<epoch>" ;; esac ;;
      esac
      out="$out$name=$v;"
    else
      out="$out$name=-;"
    fi
  done
  record "$label" "$out"
}

drain_wake() {  # drain_wake <label> - the reasons wake() collected, then reset
  local label=$1 line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$out" ]; then out=$line; else out="$out|$line"; fi
  done < "$WAKELOG"
  record "$label" "$(normalize "$out" "$MUT_BASH" "$MUT_PS")"
  : > "$WAKELOG"
}

# --- wedge timer -------------------------------------------------------------
# shellcheck disable=SC2034  # read by the fm-watch.sh functions sourced above, not by this file.
STALE_ESCALATE_SECS=1
# shellcheck disable=SC2034  # read by the fm-watch.sh functions sourced above, not by this file.
FM_WEDGE_DEMAND_INSPECT_COUNT=3

# No timer recorded yet: repair it (self-healing a watcher restart between
# recording the hash and recording the timer) and do NOT escalate.
rm -f "$STATE/.stale-since-sess_fm-wedge" "$STATE/.wedge-escalations-sess_fm-wedge"
wedge_timer_check "sess:fm-wedge" "$STATE/.stale-since-sess_fm-wedge" "non-terminal stale" "$STATE/.wedge-escalations-sess_fm-wedge"
markers wedge-reset-markers sess_fm-wedge
drain_wake wedge-reset-wake
case_line wedge-reset wedge "sess:fm-wedge" sess_fm-wedge reset 1 3

# A timer well past the threshold escalates once, with the count in the reason
# and the timer cleared so the next poll restarts it.
printf '%s' "$(( $(date +%s) - 10000 ))" > "$STATE/.stale-since-sess_fm-wedge"
rm -f "$STATE/.wedge-escalations-sess_fm-wedge"
wedge_timer_check "sess:fm-wedge" "$STATE/.stale-since-sess_fm-wedge" "non-terminal stale" "$STATE/.wedge-escalations-sess_fm-wedge"
markers wedge-escalate-markers sess_fm-wedge
drain_wake wedge-escalate-wake
case_line wedge-escalate wedge "sess:fm-wedge" sess_fm-wedge escalate 1 3

# At the demand threshold the wake PAYLOAD itself must carry the
# demand-deep-inspection marker: repetition alone is not a signal the supervisor
# can be relied on to notice.
printf '%s' "$(( $(date +%s) - 10000 ))" > "$STATE/.stale-since-sess_fm-wedge"
printf '2' > "$STATE/.wedge-escalations-sess_fm-wedge"
wedge_timer_check "sess:fm-wedge" "$STATE/.stale-since-sess_fm-wedge" "non-terminal stale" "$STATE/.wedge-escalations-sess_fm-wedge"
markers wedge-demand-markers sess_fm-wedge
drain_wake wedge-demand-wake
case_line wedge-demand wedge "sess:fm-wedge" sess_fm-wedge demand 1 3

# A corrupt timer value is treated as "no timer", never as an ancient one that
# would escalate instantly.
printf 'garbage' > "$STATE/.stale-since-sess_fm-wedge"
rm -f "$STATE/.wedge-escalations-sess_fm-wedge"
wedge_timer_check "sess:fm-wedge" "$STATE/.stale-since-sess_fm-wedge" "non-terminal stale" "$STATE/.wedge-escalations-sess_fm-wedge"
markers wedge-corrupt-markers sess_fm-wedge
drain_wake wedge-corrupt-wake
case_line wedge-corrupt wedge "sess:fm-wedge" sess_fm-wedge corrupt 1 3

# --- declared-pause absorb ---------------------------------------------------
# A long cadence absorbs; the status mtime, not a per-hash marker, anchors it, so
# a churny idle pane cannot keep resetting it.
# shellcheck disable=SC2034  # read by the fm-watch.sh functions sourced above, not by this file.
PAUSE_RESURFACE_SECS=999999
handle_paused_stale "sess:fm-hold" hold "hash-absorb"
markers paused-absorb-markers sess_fm-hold
drain_wake paused-absorb-wake
case_line paused-absorb paused "sess:fm-hold" hold hash-absorb sess_fm-hold 999999

# Past the window it re-surfaces exactly once for a recheck, so a forgotten hold
# cannot rot invisibly.
# shellcheck disable=SC2034  # read by the fm-watch.sh functions sourced above, not by this file.
PAUSE_RESURFACE_SECS=1
rm -f "$STATE/.paused-resurfaced-sess_fm-hold"
handle_paused_stale "sess:fm-hold" hold "hash-resurface"
markers paused-resurface-markers sess_fm-hold
drain_wake paused-resurface-wake
case_line paused-resurface paused "sess:fm-hold" hold hash-resurface sess_fm-hold 1

# --- non-terminal stale surface ----------------------------------------------
surface_nonterminal_stale "sess:fm-quiet" "hash-quiet"
markers nonterminal-plain-markers sess_fm-quiet
drain_wake nonterminal-plain-wake
case_line nonterminal-plain nonterminal "sess:fm-quiet" hash-quiet sess_fm-quiet

# A captain-held status takes the pause branch, so the same surface also arms the
# bounded recheck cadence rather than leaving the hold untracked.
surface_nonterminal_stale "sess:fm-heldq" "hash-held"
markers nonterminal-held-markers sess_fm-heldq
drain_wake nonterminal-held-wake
case_line nonterminal-held nonterminal "sess:fm-heldq" hash-held sess_fm-heldq

# --- pause bookkeeping clears ------------------------------------------------
clear_pause_state "sess:fm-hold"
markers clear-state-markers sess_fm-hold
case_line clear-state clearstate "sess:fm-hold" sess_fm-hold

clear_pause_tracking "sess:fm-hold"
markers clear-tracking-markers sess_fm-hold
case_line clear-tracking cleartracking "sess:fm-hold" sess_fm-hold

# --- pause classification ----------------------------------------------------
# Only the branches that need no live backend are compared: a status that is not
# paused/held falls straight through to the crew verdict, and a secondmate skips
# the agent-liveness read entirely. The agent-alive branches need a real backend
# endpoint on both sides and belong to the herdr/tmux adapter suites, which own
# that fixture.
cap pauseclass-working pause_state_class "sess:fm-quiet" quiet
case_line pauseclass-working pauseclass "sess:fm-quiet" quiet

# shellcheck disable=SC2034  # read by the fm-watch.sh functions sourced above, not by this file.
STALE_ESCALATE_SECS=999999
cap pauseclass-secondmate pause_state_class "sess:fm-second" second
case_line pauseclass-secondmate pauseclass "sess:fm-second" second

# =============================================================================
# PHASE 3 - the arm's own pure helpers
# =============================================================================
#
# bin/fm-watch-arm.sh has NO source guard, so its definitions cannot simply be
# sourced - the file would run its whole arm flow. Both sides are therefore
# loaded the SAME way: the definition PREFIX (everything above the file's main
# section) is extracted and loaded, so the oracle and the twin are reached by one
# identical technique and neither side gets a testing-only entry point that
# production never exercises.
# Two lines are dropped from the extracted prefix, and both would be bugs to
# keep: the `trap` installations would put the ARM's signal handlers on this test
# shell, and `. "$SCRIPT_DIR/fm-wake-lib.sh"` would resolve SCRIPT_DIR to the
# scratch copy's own directory and fail (fm-wake-lib is already loaded, through
# fm-watch.sh). The PowerShell side drops the exact analogues.
ARM_PREFIX="$TMP_ROOT/arm-prefix.sh"
# shellcheck disable=SC2016  # the single quotes are deliberate: this is a literal
# grep PATTERN that must match the text `. "$SCRIPT_DIR/`, not an expansion of it.
awk '/^mode=arm$/ { exit } { print }' "$ROOT/bin/fm-watch-arm.sh" |
  grep -v -e '^trap ' -e '^\. "\$SCRIPT_DIR/' > "$ARM_PREFIX"
# shellcheck source=/dev/null
. "$ARM_PREFIX"

cap armfield-plain     cycle_clean_field "plain-value"
cap armfield-tabs      cycle_clean_field "a${TAB}b${NL}c"
cap armsignal-zero     cycle_signal_name 0
cap armsignal-one      cycle_signal_name 1
cap armsignal-bad      cycle_signal_name "x"
case_line armfield-plain armfield "plain-value"
case_line armfield-tabs  armfield "a${TAB}b${NL}c"
case_line armsignal-zero armsignal 0
case_line armsignal-one  armsignal 1
case_line armsignal-bad  armsignal "x"

WOUT="$TMP_ROOT/watch-out"
printf 'watcher: noise\nsignal: /x/a.status\n' > "$WOUT.signal"
printf 'stale: sess:fm-a (idle 300s)\n' > "$WOUT.stale"
printf 'check: /x/y.check.sh: merged\n' > "$WOUT.check"
printf 'heartbeat\n' > "$WOUT.heartbeat"
printf 'watcher: already running pid 5\n' > "$WOUT.none"
for kind in signal stale check heartbeat none; do
  pred "armhaswake-$kind" watch_output_has_wake "$WOUT.$kind"
  cap  "armreason-$kind"  watch_output_reason_type "$WOUT.$kind"
  case_line "armhaswake-$kind" armhaswake "$(to_native "$WOUT.$kind")"
  case_line "armreason-$kind"  armreason  "$(to_native "$WOUT.$kind")"
done

# =============================================================================
# Drive the PowerShell side - ONE pwsh for every case above
# =============================================================================

DRIVER="$TMP_ROOT/driver.ps1"
cat > "$DRIVER" <<'PS'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Force is correct at the TOP level: this driver deliberately wants a fresh copy
# of the modules under test. It is never correct on a NESTED import.
Import-Module (Join-Path $env:FM_BIN 'fm-common.psm1') -Force
Import-Module (Join-Path $env:FM_BIN 'fm-watch.psm1') -Force

$casesPath = $env:FM_CASES
$mutState = $env:FM_MUT_STATE
$wakes = [System.Collections.Generic.List[string]]::new()
$wakeAction = { param($fmReason) [void]$wakes.Add($fmReason) }
$out = [System.Text.StringBuilder]::new()

function Emit {
    param([string]$Label, [AllowEmptyString()][AllowNull()][string]$Value)
    [void]$out.Append($Label).Append("`t").Append([string]$Value).Append("`n")
}

function Join-Values {
    # @() from a function can arrive as $null; the wrap is not decorative.
    param([AllowNull()][object]$Values)
    if ($null -eq $Values) { return '' }
    return (@($Values) -join '|')
}

function Get-MarkerReport {
    param([string]$State, [string]$Key)
    $report = ''
    foreach ($name in @('stale', 'stale-since', 'wedge-escalations', 'paused', 'paused-rechecked', 'paused-resurfaced')) {
        $path = Join-Path $State ".$name-$Key"
        if (-not (Test-Path -LiteralPath $path)) { $report += "$name=-;"; continue }
        $value = ''
        try {
            $text = [System.IO.File]::ReadAllText($path)
            $idx = $text.IndexOf("`n")
            $value = if ($idx -ge 0) { $text.Substring(0, $idx) } else { $text }
        } catch { $value = '' }
        if ($name -in @('stale-since', 'paused-rechecked', 'paused-resurfaced')) {
            $value = if ($value -match '^[0-9]+$') { '<epoch>' } else { '<non-numeric>' }
        }
        $report += "$name=$value;"
    }
    return $report
}

function Set-Knob {
    param([string]$Name, [AllowEmptyString()][string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

# The arm's own helpers, loaded by the SAME prefix-extraction technique the bash
# oracle uses (see the suite's phase 3 note): everything above the "--- main"
# banner is definitions, so it loads without running the arm flow.
$armSource = [System.IO.File]::ReadAllText((Join-Path $env:FM_BIN 'fm-watch-arm.ps1'))
$armMarker = $armSource.IndexOf('# --- main ---')
if ($armMarker -lt 0) { throw 'fm-watch-arm.ps1 has no main banner to split on' }
$armPrefix = Join-Path $env:FM_TMP 'arm-prefix.ps1'
# The module imports are dropped from the extracted copy - the exact analogue of
# the `. "$SCRIPT_DIR/fm-wake-lib.sh"` line the bash side drops, and for the same
# reason: in a scratch copy $PSScriptRoot (like SCRIPT_DIR) names the scratch
# directory, so the import would look for the modules there and fail. This driver
# has already imported them. Dropping them also avoids re-importing with -Force,
# which REMOVES the loaded module globally and strips the commands this driver is
# already holding (docs/powershell-port.md, "Never -Force a NESTED module
# import"); the failure mode is a CommandNotFoundException on the very next call.
$armText = $armSource.Substring(0, $armMarker) -replace '(?m)^Import-Module \(Join-Path \$PSScriptRoot.*$', ''
[System.IO.File]::WriteAllText($armPrefix, $armText, [System.Text.UTF8Encoding]::new($false))
. $armPrefix

foreach ($line in [System.IO.File]::ReadAllLines($casesPath)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    $f = @($line.Split("`t"))
    if ($f.Count -lt 2) { continue }
    $label = $f[0]
    $op = $f[1]
    # The encoding the suite applies when an argument contains a TAB or a
    # newline, undone here. Field COUNT is checked rather than trusting a split
    # to preserve empties (docs/powershell-port.md, "TAB record parsing").
    $arg = { param([int]$i) if ($f.Count -gt $i) { $f[$i].Replace('<TAB>', "`t").Replace('<NL>', "`n") } else { '' } }
    $a1 = & $arg 2
    $a2 = & $arg 3
    $a3 = & $arg 4
    $a4 = & $arg 5
    $a5 = & $arg 6

    switch -CaseSensitive ($op) {
        'hash'     { Emit $label (Get-FmWatchPaneHash $a1) }
        'key'      { Emit $label (Get-FmWatchWindowKey $a1) }
        'sig'      { Emit $label (Get-FmWatchSignature $a1) }
        'age'      { Emit $label ([string](Get-FmWatchAge $a1)) }
        'kind'     { Emit $label (Get-FmWatchWindowKind $a1 $env:FM_SHARED) }
        'backend'  { Emit $label (Get-FmWatchWindowBackend $a1 $env:FM_SHARED) }
        'harness'  { Emit $label (Get-FmWatchWindowHarness $a1 $env:FM_SHARED) }
        'label'    { Emit $label (Get-FmWatchWindowLabel $a1 $env:FM_SHARED) }
        'windows'  { Emit $label (Join-Values (Get-FmWatchRecordedWindow $env:FM_SHARED)) }
        'signals'  { Emit $label (Join-Values (Get-FmWatchChangedSignal $env:FM_SHARED)) }
        'afk'      { Emit $label ((Test-FmWatchAfk $a1).ToString().ToLowerInvariant()) }
        'busyturn' { Emit $label ((Test-FmWatchBusyTurnOverAge $a1 $env:FM_SHARED).ToString().ToLowerInvariant()) }
        'heartbeat' { Emit $label ((Test-FmWatchHeartbeatActionable $a1).ToString().ToLowerInvariant()) }

        'wedge' {
            # a1=window a2=key a3=variant a4=escalate-secs a5=demand-count
            Set-Knob 'FM_STALE_ESCALATE_SECS' $a4
            Set-Knob 'FM_WEDGE_DEMAND_INSPECT_COUNT' $a5
            $since = Join-Path $mutState ".stale-since-$a2"
            $esc = Join-Path $mutState ".wedge-escalations-$a2"
            foreach ($p in @($since, $esc)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
            $old = [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 10000)
            switch -CaseSensitive ($a3) {
                'escalate' { Set-FmFileText -Path $since -Text $old -NoNewline }
                'demand'   { Set-FmFileText -Path $since -Text $old -NoNewline
                             Set-FmFileText -Path $esc -Text '2' -NoNewline }
                'corrupt'  { Set-FmFileText -Path $since -Text 'garbage' -NoNewline }
                default    { }
            }
            $wakes.Clear()
            [void](Test-FmWatchWedgeTimer -Window $a1 -SinceFile $since -Label 'non-terminal stale' `
                    -EscalationFile $esc -State $mutState -WakeAction $wakeAction)
            Emit "$label-markers" (Get-MarkerReport -State $mutState -Key $a2)
            Emit "$label-wake" (Join-Values $wakes)
            Set-Knob 'FM_STALE_ESCALATE_SECS' ''
            Set-Knob 'FM_WEDGE_DEMAND_INSPECT_COUNT' ''
        }

        'paused' {
            # a1=window a2=task a3=hash a4=key a5=resurface-secs
            Set-Knob 'FM_PAUSE_RESURFACE_SECS' $a5
            if ($a5 -eq '1') {
                $p = Join-Path $mutState ".paused-resurfaced-$a4"
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
            $wakes.Clear()
            [void](Invoke-FmWatchPausedStale -Window $a1 -Task $a2 -Hash $a3 -State $mutState -WakeAction $wakeAction)
            Emit "$label-markers" (Get-MarkerReport -State $mutState -Key $a4)
            Emit "$label-wake" (Join-Values $wakes)
            Set-Knob 'FM_PAUSE_RESURFACE_SECS' ''
        }

        'nonterminal' {
            # a1=window a2=hash a3=key
            $wakes.Clear()
            Show-FmWatchNonterminalStale -Window $a1 -Hash $a2 -State $mutState -WakeAction $wakeAction
            Emit "$label-markers" (Get-MarkerReport -State $mutState -Key $a3)
            Emit "$label-wake" (Join-Values $wakes)
        }

        'clearstate' {
            Clear-FmWatchPauseState -Window $a1 -State $mutState
            Emit "$label-markers" (Get-MarkerReport -State $mutState -Key $a2)
        }
        'cleartracking' {
            Clear-FmWatchPauseTracking -Window $a1 -State $mutState
            Emit "$label-markers" (Get-MarkerReport -State $mutState -Key $a2)
        }
        'pauseclass' {
            if ($label -eq 'pauseclass-secondmate') { Set-Knob 'FM_STALE_ESCALATE_SECS' '999999' }
            Emit $label (Get-FmWatchPauseStateClass -Window $a1 -Task $a2 -State $mutState)
            Set-Knob 'FM_STALE_ESCALATE_SECS' ''
        }

        'armfield'   { Emit $label (Format-FmArmField $a1) }
        'armsignal'  { Emit $label (Get-FmArmSignalName $a1) }
        'armhaswake' { Emit $label ((Test-FmArmOutputHasWake -Path $a1).ToString().ToLowerInvariant()) }
        'armreason'  { Emit $label (Get-FmArmOutputReasonType -Path $a1) }

        default { Emit $label "UNKNOWN-OP:$op" }
    }
}

Write-FmRaw $out.ToString()
PS

FM_BIN=$(to_native "$ROOT/bin") \
FM_TMP=$(to_native "$TMP_ROOT") \
FM_CASES=$(to_native "$CASES") \
FM_SHARED=$(to_native "$SHARED") \
FM_MUT_STATE=$(to_native "$MUT_PS") \
FM_STATE_OVERRIDE=$(to_native "$MUT_PS") \
FM_HOME=$(to_native "$TMP_ROOT/mut-ps") \
  pwsh -NoProfile -File "$(to_native "$DRIVER")" > "$ACTUAL" 2> "$TMP_ROOT/driver.err"

if [ ! -s "$ACTUAL" ]; then
  printf 'not ok - the PowerShell driver produced no output:\n' >&2
  cat "$TMP_ROOT/driver.err" >&2
  exit 1
fi

# --- join by label and compare ------------------------------------------------

declare -A PS_ANSWER=()
while IFS=$TAB read -r label value; do
  [ -n "$label" ] || continue
  PS_ANSWER["$label"]=$(normalize "$value" "$MUT_BASH" "$MUT_PS")
done < "$ACTUAL"

# The state prefixes the two worlds spell differently, replaced on BOTH sides
# before comparison (see the normalization note at the top).
# The six native prefixes are resolved ONCE, outside the loop: to_native is a
# cygpath child, and computing them per key would be hundreds of forks - the
# exact cost that turns a passing suite into an apparent hang on this host.
declare -A PS_NORM=()
NAT_SHARED=$(to_native "$SHARED");      NAT_SHARED=${NAT_SHARED//\\//}
NAT_AFK=$(to_native "$SHARED_AFK");     NAT_AFK=${NAT_AFK//\\//}
NAT_HB_NONE=$(to_native "$HB_NONE");    NAT_HB_NONE=${NAT_HB_NONE//\\//}
NAT_HB_YES=$(to_native "$HB_YES");      NAT_HB_YES=${NAT_HB_YES//\\//}
NAT_MUT=$(to_native "$MUT_PS");         NAT_MUT=${NAT_MUT//\\//}
NAT_TMP=$(to_native "$TMP_ROOT");       NAT_TMP=${NAT_TMP//\\//}
for k in "${!PS_ANSWER[@]}"; do
  v=${PS_ANSWER[$k]}
  v=${v//\\//}
  v=${v//"$NAT_SHARED"/@STATE@}; v=${v//"$NAT_AFK"/@STATE@}
  v=${v//"$NAT_HB_NONE"/@STATE@}; v=${v//"$NAT_HB_YES"/@STATE@}
  v=${v//"$NAT_MUT"/@STATE@}; v=${v//"$NAT_TMP"/@TMP@}
  PS_NORM["$k"]=$v
done

assert_same() {
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

while IFS=$TAB read -r label value; do
  [ -n "$label" ] || continue
  expected=$value
  # The oracle's own paths get the same treatment; recorded values already have
  # the mutating dirs replaced by drain_wake/normalize, so only the read-only
  # fixtures remain.
  expected=${expected//"$SHARED"/@STATE@}
  expected=${expected//"$HB_NONE"/@STATE@}
  expected=${expected//"$HB_YES"/@STATE@}
  expected=${expected//"$SHARED_AFK"/@STATE@}
  expected=${expected//"$MUT_BASH"/@STATE@}
  expected=${expected//"$TMP_ROOT"/@TMP@}
  if [ -z "${PS_NORM[$label]+set}" ]; then
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${expected}]
  actual(pwsh)  : <MISSING LABEL>
"
    continue
  fi
  assert_same "$label" "$expected" "${PS_NORM[$label]}"
done < "$ORACLE"

# =============================================================================
# PHASE 4 - the two entrypoints, end to end
# =============================================================================
#
# A small, bounded number of real process runs: everything above proves the
# triage functions agree, and these prove the .ps1 halves actually wire up. Kept
# to a handful because each pwsh start costs ~4.8s here.

usage_out=$(pwsh -NoProfile -File "$(to_native "$ROOT/bin/fm-watch-arm.ps1")" --bogus 2>&1)
usage_rc=$?
assert_same "arm usage exits 2" "2" "$usage_rc"
case "$usage_out" in
  *usage:*) assert_same "arm usage prints a usage line" "yes" "yes" ;;
  *) assert_same "arm usage prints a usage line" "yes" "no: $usage_out" ;;
esac

# run_watcher <world> <state> <home> - a BOUNDED watcher run. A watcher that
# acquires the lock blocks forever by design, so an unbounded invocation would
# turn a stand-down regression into a silent suite hang instead of a failed
# assertion - the exact shape docs/powershell-port.md warns reads as a timeout
# with zero output.
#
# NOT `timeout`: MSYS timeout(1) around a NATIVE Windows process does not return
# when the child exits early - measured here, a watcher that exited 1 in under a
# second still cost the full budget and reported 124. So the child is backgrounded
# and polled, and only a genuinely blocked watcher is stopped. The stop targets
# exactly the pid this function started; nothing here matches on a process NAME,
# because a pattern would reach every firstmate home's watcher (AGENTS.md
# section 8).
RUN_WATCHER_OUT=""
RUN_WATCHER_RC=0
run_watcher() {
  local world=$1 state=$2 home=$3 out="$TMP_ROOT/.watcher-run.$$" pid i=0
  : > "$out"
  if [ "$world" = bash ]; then
    FM_STATE_OVERRIDE="$state" FM_HOME="$home" bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  else
    FM_STATE_OVERRIDE=$(to_native "$state") FM_HOME=$(to_native "$home")       pwsh -NoProfile -File "$(to_native "$ROOT/bin/fm-watch.ps1")" > "$out" 2>&1 &
  fi
  pid=$!
  while [ "$i" -lt 2400 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    RUN_WATCHER_RC=124
  else
    wait "$pid" 2>/dev/null
    RUN_WATCHER_RC=$?
  fi
  RUN_WATCHER_OUT=$(cat "$out" 2>/dev/null || true)
  rm -f "$out"
}

# A NOTE THAT DECIDES BOTH FIXTURES BELOW, found by this suite the hard way.
# Every watcher runs bin/fm-pr-check-migrate.sh BEFORE it touches the lock, and
# on a state directory that has never been migrated that script takes the lock
# itself - stopping or evicting whatever holds it. So the stand-down branch is
# simply unreachable there, and a fixture that skips this step measures the
# MIGRATION, not the singleton. In production the migration is already complete
# and early-exits without going near the lock, which is the state reproduced
# here by running it once, before any holder exists.
#
# It also exposed a genuine cross-world gap worth naming: that bash script's
# fm_pid_alive cannot see a POWERSHELL holder's pid (a Windows pid is not in the
# MSYS namespace), so on an unmigrated state directory it treats a live
# PowerShell watcher's lock as abandoned and clears it. That is the mirror of
# the divergence bin/fm-wake-lib.psm1 already records against bin/fm-wake-lib.sh,
# and it belongs to the bash side; nothing in this package can close it.
prime_migration() {  # <state> <home>
  FM_STATE_OVERRIDE="$1" FM_HOME="$2" bash "$ROOT/bin/fm-pr-check-migrate.sh" --checks-safe >/dev/null 2>&1
}

# THE SINGLETON, in two cases. This is the most important behavior in the
# package, so it is asserted against a real lock rather than a mock.
#
# CASE A - CROSS-WORLD. The lock is taken by the BASH library and both watchers
# are pointed at it. What can be asserted here is bounded by a divergence
# bin/fm-wake-lib.psm1 already documents: a lock written by a Git Bash holder
# carries an MSYS pid whose identity string a native Windows process cannot
# reproduce, so a PowerShell reader can never IDENTITY-match a bash-held lock.
# Both worlds therefore stop at the same earlier gate - bin/fm-pr-check-migrate
# refuses on a watcher lock it cannot attribute, before the lock is even
# attempted - and the assertion is that they refuse IDENTICALLY and that neither
# steals the lock. That last property is the one that matters: answering "not
# held" here would start a second watcher in one home.
LOCK_STATE="$TMP_ROOT/lockcase/state"
LOCK_HOME="$TMP_ROOT/lockcase"
mkdir -p "$LOCK_STATE"
prime_migration "$LOCK_STATE" "$LOCK_HOME"
FM_STATE_OVERRIDE="$LOCK_STATE" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$2/.watch.lock" || exit 9
  printf "%s\n" "$3" > "$2/.watch.lock/fm-home"
  printf "%s\n" "$1/bin/fm-watch.sh" > "$2/.watch.lock/watcher-path"
  fm_pid_identity "${BASHPID:-$$}" > "$2/.watch.lock/pid-identity" 2>/dev/null || true
  sleep 900
' _ "$ROOT" "$LOCK_STATE" "$LOCK_HOME" &
LOCK_HOLDER=$!
i=0
while [ "$i" -lt 200 ] && [ ! -e "$LOCK_STATE/.watch.lock/pid-identity" ]; do sleep 0.1; i=$((i + 1)); done
touch "$LOCK_STATE/.last-watcher-beat"
held_owner=$(cat "$LOCK_STATE/.watch.lock/pid" 2>/dev/null || true)

held_bash=$(FM_STATE_OVERRIDE="$LOCK_STATE" FM_HOME="$LOCK_HOME" bash "$ROOT/bin/fm-watch.sh" 2>&1)
held_bash_rc=$?
held_ps=$(FM_STATE_OVERRIDE=$(to_native "$LOCK_STATE") FM_HOME=$(to_native "$LOCK_HOME") \
  pwsh -NoProfile -File "$(to_native "$ROOT/bin/fm-watch.ps1")" 2>&1)
held_ps_rc=$?

assert_same "cross-world held lock: exit code" "$held_bash_rc" "$held_ps_rc"
assert_same "cross-world held lock: bash stands down cleanly" "0" "$held_bash_rc"
case "$held_ps" in
  *"already running"*) assert_same "cross-world held lock: PowerShell recognizes the bash holder" "yes" "yes" ;;
  *) assert_same "cross-world held lock: PowerShell recognizes the bash holder" "yes" "no: $held_ps" ;;
esac
# Digits are masked because each world names the same holder pid in its own
# namespace; the SENTENCES are what must agree.
mask_digits() { printf '%s' "${1//[0-9]/N}"; }
assert_same "cross-world held lock: refusal text" \
  "$(mask_digits "$held_bash")" "$(mask_digits "$held_ps")"
assert_same "cross-world held lock: holder pid untouched" "$held_owner" \
  "$(cat "$LOCK_STATE/.watch.lock/pid" 2>/dev/null || true)"
kill "$LOCK_HOLDER" 2>/dev/null || true
wait "$LOCK_HOLDER" 2>/dev/null || true

# CASE B - SAME-WORLD. With the lock held by a live POWERSHELL process, the
# identity DOES match, the migration gate passes, and the watcher must reach its
# own stand-down: exit 0, one "already running pid <N>" line, and the holder's
# lock left exactly as it was. This is the assertion the cross-world case cannot
# make, and it is the one that proves a second PowerShell watcher never runs.
PSLOCK_STATE="$TMP_ROOT/pslock/state"
PSLOCK_HOME="$TMP_ROOT/pslock"
mkdir -p "$PSLOCK_STATE"
prime_migration "$PSLOCK_STATE" "$PSLOCK_HOME"
PSHOLD="$TMP_ROOT/pshold.ps1"
cat > "$PSHOLD" <<'PSH'
Import-Module (Join-Path $env:FM_BIN 'fm-common.psm1') -Force
Import-Module (Join-Path $env:FM_BIN 'fm-wake-lib.psm1') -Force
$lock = Join-Path $env:FM_LOCK_STATE '.watch.lock'
if (-not (Request-FmLock -LockPath $lock)) { exit 9 }
Set-FmFileText -Path (Join-Path $lock 'fm-home') -Text $env:FM_HOME
Set-FmFileText -Path (Join-Path $lock 'watcher-path') -Text (Join-Path $env:FM_BIN 'fm-watch.ps1')
Set-FmFileText -Path (Join-Path $lock 'pid-identity') -Text (Get-FmPidIdentity -ProcessId ([string]$PID))
Start-Sleep -Seconds 900
PSH
FM_BIN=$(to_native "$ROOT/bin") FM_LOCK_STATE=$(to_native "$PSLOCK_STATE") \
  FM_HOME=$(to_native "$PSLOCK_HOME") FM_STATE_OVERRIDE=$(to_native "$PSLOCK_STATE") \
  pwsh -NoProfile -File "$(to_native "$PSHOLD")" &
PS_HOLDER=$!
i=0
while [ "$i" -lt 400 ] && [ ! -e "$PSLOCK_STATE/.watch.lock/pid-identity" ]; do sleep 0.1; i=$((i + 1)); done
touch "$PSLOCK_STATE/.last-watcher-beat"
ps_owner=$(cat "$PSLOCK_STATE/.watch.lock/pid" 2>/dev/null || true)
assert_same "same-world held lock: the PowerShell holder took the lock" "yes"   "$([ -n "$ps_owner" ] && echo yes || echo "no (holder never published a pid)")"

run_watcher ps "$PSLOCK_STATE" "$PSLOCK_HOME"
standdown=$RUN_WATCHER_OUT; standdown_rc=$RUN_WATCHER_RC
# If the holder died first the lock was legitimately stale and a steal is
# CORRECT, so the case would be proving nothing. Asserted rather than assumed,
# because that is exactly how this case first failed: the watcher runs the
# fork-heavy bin/fm-pr-check-migrate BEFORE it ever touches the lock, and under
# load that outlived the holder.
assert_same "same-world held lock: the holder outlived the watcher's check" "yes" \
  "$(kill -0 "$PS_HOLDER" 2>/dev/null && echo yes || echo "no (holder exited first; case inconclusive)")"
kill "$PS_HOLDER" 2>/dev/null || true
wait "$PS_HOLDER" 2>/dev/null || true

assert_same "same-world held lock: stands down cleanly" "0" "$standdown_rc"
assert_same "same-world held lock: names the running watcher" \
  "watcher: already running pid $ps_owner" "$standdown"
assert_same "same-world held lock: holder pid untouched" "$ps_owner" \
  "$(cat "$PSLOCK_STATE/.watch.lock/pid" 2>/dev/null || true)"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell watcher twins differ from the bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass. The floor is taken
# from an OBSERVED green run, so a future refactor that drops cases fails loudly
# instead of certifying an empty one.
MIN_ASSERTIONS=80
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-watch.psm1 / fm-watch.ps1 / fm-watch-arm.ps1 match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-watch-psm1.test.sh: all assertions passed\n'
