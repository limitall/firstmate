#!/usr/bin/env bash
# Behavior test for the PowerShell twin of the away-mode sub-supervisor:
#
#   bin/fm-supervise-daemon.psm1  vs  bin/fm-supervise-daemon.sh
#   bin/fm-supervise-daemon.ps1   (the thin argv half of the hybrid pair)
#
# This is a DIFFERENTIAL test: it drives each bash function and its PowerShell
# twin with the same fixtures and asserts they agree. Bash is the ORACLE
# (docs/powershell-port.md) - where the two differ the bash is right, unless the
# twin's header documents the divergence, and each documented divergence gets
# its own assertion here so the twin behaves as documented rather than by
# accident.
#
# WHAT IS COVERED, and why that is the whole testable surface. The daemon splits
# cleanly into a pure classification/marker layer and a long-lived loop. The
# pure layer - argument and marker parsing, wake classification, the escalation
# buffer, the wedge-alarm channel resolution, and every refusal path - is
# exercised here in both worlds. The LOOP is not: it sleeps, forks a watcher
# child, and only ever terminates on a signal, so a differential run of it would
# assert against timing rather than behavior. What IS reachable from the loop's
# owner is its STARTUP REFUSALS (unsupported supervisor backend, unresolvable
# supervisor target), and those are driven end to end: the bash file is EXECUTED
# and the PowerShell main is called in-process, and both are checked for exit
# code, diagnostic text, and the artifacts a refused start must not leave behind.
#
# Deliberately NOT covered, each for a stated reason:
#   - the watcher child lifecycle, crash-loop backoff and housekeeping cadence:
#     all three are defined by sleeps inside the loop above;
#   - the real notifier channels (osascript / powershell toast / herdr / a
#     captain command): every one of them posts a REAL desktop notification, so
#     both worlds are driven through the FM_WEDGE_ALARM_EXEC recorder seam that
#     exists precisely so a test can prove the routing without firing anything;
#   - pane injection past the presence gate: it needs a live tmux or herdr pane,
#     which this host has neither of. The gate itself (away mode off = refuse,
#     buffer preserved) IS asserted, because that is the refusal that matters.
#
# STRUCTURE. Process creation on this Windows host is expensive and pwsh startup
# dominates everything (docs/powershell-port.md: ~4.8s measured), so BOTH worlds
# are batched: the whole module surface is one `bash` oracle script and one
# `pwsh` probe script, each emitting `label<TAB>value` lines, and the assertions
# below join the two streams by label. The startup refusals add one bash exec
# per case (there is no other way to execute a bash program) but no extra pwsh:
# they run inside the same probe process, which is exactly why the PowerShell
# twin keeps main in the .psm1 rather than the .ps1.
#
# Both sides write their answers to a FILE rather than to stdout, so a stray
# diagnostic from a module import cannot corrupt the record stream.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
#
# Windows note: PowerShell cannot resolve MSYS paths (verified - [System.IO.File]
# reads /tmp/x as C:\tmp\x), so every path handed to pwsh here, INCLUDING module
# and probe-script paths, goes through fm_test_native_path first.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in bin/fm-supervise-daemon.psm1 bin/fm-supervise-daemon.ps1 bin/fm-supervise-daemon.sh; do
  [ -f "$ROOT/$f" ] || fail "$f is missing"
done

TMP_ROOT=$(fm_test_tmproot fm-daemon-psm1)
PROBES="$TMP_ROOT/probes"; mkdir -p "$PROBES"
FIX="$TMP_ROOT/fix"; mkdir -p "$FIX"
BIN_N=$(fm_test_native_path "$ROOT/bin")

# --- bookkeeping -------------------------------------------------------------
#
# Results live in plain shell variables in THIS shell. Nothing that records an
# assertion may run inside `( ... )`: a subshell cannot report a failure back to
# the parent's counters, so a bookkeeping scheme that lost a failure would
# certify work it never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""
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

# ps_get <stream> <label>: the value one side emitted for one label. A loud
# <<MISSING:label>> sentinel rather than an empty string, so a probe that died
# halfway cannot pass by matching an empty oracle.
ps_get() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '
    BEGIN { f = 0 }
    $1 == k && !f { f = 1; sub(/^[^\t]*\t/, ""); print }
    END { if (!f) print "<<MISSING:" k ">>" }'
}

both() {  # <label> <bash-stream> <ps-stream> [assertion-label]
  assert_same "${4:-$1}" "$(ps_get "$2" "$1")" "$(ps_get "$3" "$1")"
}

# DECLARED NORMALIZATION - the per-world fixture root, and nothing else.
#
# A signal wake reason IS a list of file paths, and the daemon logs the reason
# verbatim. Each world is handed its OWN copy of the wake fixture (they mutate
# it), spelled in its own form - /tmp/... under MSYS, the native AppData Temp
# path under PowerShell. Those name the same shape of tree, so both roots
# collapse to <WAKE> and every trailing component, the wording and the decision
# stay fully compared. Separators are folded FIRST, because the PowerShell
# answer arrives with backslashes and a forward-slash root would never match.
np() {
  local v=${1//\\//} wb wp
  wb=${WK//\\//}/b
  wp=$(fm_test_native_path "$WK/p"); wp=${wp//\\//}
  v=${v//$wb/<WAKE>}
  v=${v//$wp/<WAKE>}
  printf '%s' "$v"
}
both_np() {  # same as both, path-normalized on each side
  assert_same "${4:-$1}" "$(np "$(ps_get "$2" "$1")")" "$(np "$(ps_get "$3" "$1")")"
}

# --- fixtures ----------------------------------------------------------------
#
# One state tree per world for the read-only classification cases (they share it
# safely), and a FRESH pair of trees per mutating wake case, because handle_wake
# writes markers and the escalation buffer.

mk_status_state() {  # <dir>
  local d=$1
  mkdir -p "$d"
  # t1: a terminal captain-relevant line nobody has escalated yet.
  printf 'working: started\ndone: PR https://example.invalid/pr/1 checks green\n' > "$d/t1.status"
  # t2: a non-terminal progress line - routine.
  printf 'working: still going\n' > "$d/t2.status"
  # t3: a DECLARED external wait - an idle pane here is expected, not a wedge.
  printf 'paused: awaiting external CI\n' > "$d/t3.status"
  # t4: firstmate action needed.
  printf 'blocked: need a credential\n' > "$d/t4.status"
  # t7: terminal AND already recorded as escalated by the catch-all scan.
  printf 'done: PR https://example.invalid/pr/7 checks green\n' > "$d/t7.status"
  printf 'done: PR https://example.invalid/pr/7 checks green' > "$d/.subsuper-seen-status-t7"
  # t6: a present but EMPTY status file - no last line at all.
  : > "$d/t6.status"
  local t
  for t in t1 t2 t3 t4 t6 t7; do
    fm_write_meta "$d/$t.meta" "window=firstmate:fm-$t" "harness=claude" "backend=tmux"
  done
}

ST_B="$FIX/state-b"; mk_status_state "$ST_B"
ST_P="$FIX/state-p"; mk_status_state "$ST_P"
ST_P_N=$(fm_test_native_path "$ST_P")

# Escalation-buffer fixtures. `aged` carries a .since sidecar 1000s in the past,
# which is what makes the batch-window age measurable without waiting for one.
mk_buffer_state() {  # <dir>
  local d=$1 now
  now=$(date +%s)
  mkdir -p "$d/empty" "$d/nosince" "$d/aged" "$d/zero"
  printf 'one\ntwo\n' > "$d/nosince/.subsuper-escalations"
  printf 'one\ntwo\nthree\n' > "$d/aged/.subsuper-escalations"
  printf '%s\n' "$((now - 1000))" > "$d/aged/.subsuper-escalations.since"
  : > "$d/zero/.subsuper-escalations"
  printf '%s\n' "$((now - 1000))" > "$d/zero/.subsuper-escalations.since"
  # An age fixture with a KNOWN mtime, so the reader's answer can be checked
  # against an independently computed expectation rather than against a fixed
  # window. The two worlds run minutes apart on this host, so any assertion on
  # an absolute age would compare clocks instead of code.
  printf 'marker\n' > "$d/aged.marker"
  touch -d "@$((now - 1000))" "$d/aged.marker" 2>/dev/null ||
    touch -t "$(date -d "@$((now - 1000))" '+%Y%m%d%H%M.%S' 2>/dev/null || printf '202601010000.00')" "$d/aged.marker"
}
BUF_B="$FIX/buf-b"; mk_buffer_state "$BUF_B"
BUF_P="$FIX/buf-p"; mk_buffer_state "$BUF_P"

# config/wedge-alarm fixtures. Shared by both worlds: they are read-only here.
WA="$FIX/wedge"; mkdir -p "$WA/absent" "$WA/plain" "$WA/comments" "$WA/multi" "$WA/onlycomments" "$WA/blankonly"
printf 'herdr\n' > "$WA/plain/wedge-alarm"
printf '# leading comment\n\n   osascript   \n#trailing\n' > "$WA/comments/wedge-alarm"
printf 'herdr\ncommand:notify-me\noff\n' > "$WA/multi/wedge-alarm"
printf '# only a comment\n' > "$WA/onlycomments/wedge-alarm"
printf '\n   \n' > "$WA/blankonly/wedge-alarm"
mkdir -p "$WA/single" "$WA/bogus" "$WA/offonly"
printf 'herdr\n' > "$WA/single/wedge-alarm"
printf 'not-a-channel\n' > "$WA/bogus/wedge-alarm"
printf 'off\n' > "$WA/offonly/wedge-alarm"
WA_N=$(fm_test_native_path "$WA")

# A fake `uname` so the platform arm of the wedge alarm is decided by the SUITE
# and not by the host. Installed twice on purpose: bash's PATH lookup prefers the
# extension-less script, while .NET resolves only what PATHEXT knows, so without
# the .cmd the PowerShell side would silently run the REAL uname and the case
# would prove nothing (docs/powershell-port.md).
mk_fake_uname() {  # <dir> <kernel>
  local dir=$1 kernel=$2
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n %s\n' "$kernel" > "$dir/uname"
  chmod +x "$dir/uname"
  {
    printf '@echo off\r\n'
    printf 'echo %s\r\n' "$kernel"
    printf 'exit /b 0\r\n'
  } > "$dir/uname.cmd"
}
UN="$FIX/uname"
mk_fake_uname "$UN/darwin" Darwin
mk_fake_uname "$UN/mingw" 'MINGW64_NT-10.0-26200'
mk_fake_uname "$UN/linux" Linux
UN_N=$(fm_test_native_path "$UN")

# The notifier RECORDER. FM_WEDGE_ALARM_EXEC replaces every real channel with
# this, so the routing is provable without a single desktop notification. Only a
# bash script is needed: the bash twin execs it directly and the PowerShell twin
# routes an extension-less program through Git Bash by design
# (Get-FmDaemonProgramInvocation), which is the behavior this also pins.
REC_B="$FIX/rec-b.log"
REC_P="$FIX/rec-p.log"
mk_recorder() {  # <path> <log>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\${1:-}" "\${2:-}" >> "$2"
exit 0
SH
  chmod +x "$1"
}
mk_recorder "$FIX/recorder-b" "$REC_B"
mk_recorder "$FIX/recorder-p" "$REC_P"
# A notifier that FAILS, so the "the override exited non-zero" arm is exercised
# rather than assumed. Shared by both worlds; neither may create it lazily, or
# the case would depend on which world ran first.
printf '#!/usr/bin/env bash\nexit 3\n' > "$FIX/failing-notifier"
chmod +x "$FIX/failing-notifier"

# --- wake-dispatch fixtures (MUTATING: one fresh tree per case per world) -----
WAKE_CASES="w-signal-new w-signal-routine w-signal-seen w-stale-terminal w-stale-transient \
w-stale-paused w-stale-wedgedetail w-check w-heartbeat w-unknown w-forceself"
WK="$FIX/wake"
for c in $WAKE_CASES; do
  mk_status_state "$WK/b/$c"
  mk_status_state "$WK/p/$c"
done

# --- probe / oracle drivers --------------------------------------------------
oracle() {  # <name> [args...] - one bash launch; stderr is quarantined
  local name=$1; shift
  bash "$PROBES/$name.sh" "$@" 2>"$TMP_ROOT/$name.oracle.err"
}

# ============================================================================
# The bash ORACLE: one process, every module-level case.
# ============================================================================
cat > "$PROBES/daemon.sh" <<'SH'
#!/usr/bin/env bash
set -u
ROOT=$1 STATE=$2 BUF=$3 WA=$4 UN=$5 REC=$6 WAKE=$7 RECLOG=$8 LOGPATH=$9
# The recorder must be wired BEFORE sourcing: the daemon's library-mode footer
# defaults FM_WEDGE_ALARM_EXEC to "discard" only when it is unset, and every case
# below then chooses discard or the recorder explicitly. No case ever leaves it
# empty, because empty means "run the real notifier".
export FM_WEDGE_ALARM_EXEC=discard
export FM_HOME="$STATE"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"

emit() { local v=${2:-}; printf '%s\t%s\n' "$1" "${v//$'\n'/\\n}"; }
tf() { if "$@" >/dev/null 2>&1; then printf True; else printf False; fi }
LOGFILE=$LOGPATH
log_reset() { : > "$LOGFILE"; LOG=$LOGFILE; }
log_read() {
  # Strip the "[timestamp] " prefix each line carries so the WORDING is
  # compared and the clock is not.
  sed 's/^\[[^]]*\] //' "$LOGFILE" 2>/dev/null | tr '\n' '\036'
}

# --- constants --------------------------------------------------------------
emit const.backends "$FM_SUPERVISOR_SUPPORTED_BACKENDS"
emit const.InjectSkip "$INJECT_SKIP_DEFAULT"
emit const.StaleEscalateSecs "$STALE_ESCALATE_SECS_DEFAULT"
emit const.EscalateBatchSecs "$ESCALATE_BATCH_SECS_DEFAULT"
emit const.HeartbeatScanSecs "$HEARTBEAT_SCAN_SECS_DEFAULT"
emit const.HousekeepingTick "$HOUSEKEEPING_TICK_DEFAULT"
emit const.MaxDeferSecs "$MAX_DEFER_SECS_DEFAULT"
emit const.WedgeAlarmTimeout "$WEDGE_ALARM_TIMEOUT_SECS_DEFAULT"
emit const.InjectFailSleep "$INJECT_FAIL_SLEEP_DEFAULT"
emit const.InjectConfirmRetries "$INJECT_CONFIRM_RETRIES_DEFAULT"
emit const.InjectConfirmSleep "$INJECT_CONFIRM_SLEEP_DEFAULT"
emit const.CrashThreshold "$CRASH_THRESHOLD_DEFAULT"
emit const.CrashWindow "$CRASH_WINDOW_DEFAULT"
emit const.CrashBackoff "$CRASH_BACKOFF_DEFAULT"
emit const.CrashNormalSleep "$CRASH_NORMAL_SLEEP_DEFAULT"
emit const.LogMaxBytes "$LOG_MAX_BYTES_DEFAULT"
emit const.LogKeepLines "$LOG_KEEP_LINES_DEFAULT"

# --- pure string helpers ----------------------------------------------------
i=0
for k in 'a:b/c.d' '' 'plain' 'fm-x.status' 'firstmate:fm-t1' '::://...'; do
  emit "key.$i" "$(_stale_key "$k")"
  i=$((i + 1))
done
i=0
while IFS= read -r line; do
  emit "collapse.$i" "$(_collapse_newlines "$line")"
  i=$((i + 1))
done <<'CASES'
plain
CASES
emit collapse.multi "$(_collapse_newlines "$(printf 'a\nb\nc')")"
emit collapse.empty "$(_collapse_newlines '')"
emit collapse.blankline "$(_collapse_newlines "$(printf 'a\n\nb')")"
emit hash.empty "$(_hash_text '')"
emit hash.hello "$(_hash_text 'hello')"
emit hash.spaced "$(_hash_text 'a b c')"

i=0
for r in 'signal: a b' 'stale: firstmate:fm-x' 'check: merged' 'heartbeat' 'heartbeat: 5' \
         '' 'watcher: already running' 'signal' 'Signal: x' 'heartbeatx'; do
  emit "wake.$i" "$(tf is_wake_reason "$r")"
  i=$((i + 1))
done

# should_force_self: per-case env, applied and cleared explicitly. A bash prefix
# assignment on a FUNCTION call persists in the shell, so it is never used here.
force_case() {  # <label> <skip-or-UNSET> <reason>
  if [ "$2" = UNSET ]; then unset FM_INJECT_SKIP; else FM_INJECT_SKIP=$2; fi
  emit "force.$1" "$(tf should_force_self "$3")"
  unset FM_INJECT_SKIP
}
force_case default.hb UNSET 'heartbeat'
force_case default.sig UNSET 'signal: x'
force_case empty.hb '' 'heartbeat'
force_case multi.check 'check:|stale:' 'check: a'
force_case multi.stale 'check:|stale:' 'stale: b'
force_case multi.signal 'check:|stale:' 'signal: c'
force_case bars.only '|' 'anything'
force_case exact 'signal: x' 'signal: x'
force_case prefixonly 'sig' 'signal: x'

# --- marker / envelope predicates -------------------------------------------
MARKED="${FM_INJECT_MARK}legacy body"
PREFIXED="${FM_OPERATIONAL_PREFIX}untyped body"
TYPED=
fm_operational_input_encode away-supervisor 'typed body' TYPED || TYPED='ENCODE-FAILED'
emit inj.empty "$(tf message_is_injection '')"
emit inj.plain "$(tf message_is_injection 'plain text')"
emit inj.marked "$(tf message_is_injection "$MARKED")"
emit inj.prefixed "$(tf message_is_injection "$PREFIXED")"
emit inj.typed "$(tf message_is_injection "$TYPED")"
emit inj.late "$(tf message_is_injection "x${FM_INJECT_MARK}body")"

emit strip.typed "$(strip_injection_marker "$TYPED")"
emit strip.prefixed "$(strip_injection_marker "$PREFIXED")"
emit strip.marked "$(strip_injection_marker "$MARKED")"
emit strip.plain "$(strip_injection_marker 'plain text')"
emit strip.empty "$(strip_injection_marker '')"

AFK_ON="$STATE/afkon"; mkdir -p "$AFK_ON"; afk_enter "$AFK_ON"
AFK_OFF="$STATE/afkoff"; mkdir -p "$AFK_OFF"
emit afk.on "$(tf afk_active "$AFK_ON")"
emit afk.off "$(tf afk_active "$AFK_OFF")"
i=0
for m in 'captain is back' "$MARKED" "$TYPED" '/afk' '/afk 30m' '' 'x/afk'; do
  emit "exit.on.$i" "$(tf should_exit_afk "$AFK_ON" "$m")"
  emit "exit.off.$i" "$(tf should_exit_afk "$AFK_OFF" "$m")"
  i=$((i + 1))
done
# afk_exit must make the flag read as absent again.
afk_exit "$AFK_ON"
emit afk.after_exit "$(tf afk_active "$AFK_ON")"

# --- classifiers ------------------------------------------------------------
emit cls.signal.new "$(classify_signal "$STATE/t1.status" "$STATE")"
emit cls.signal.routine "$(classify_signal "$STATE/t2.status" "$STATE")"
emit cls.signal.seen "$(classify_signal "$STATE/t7.status" "$STATE")"
emit cls.signal.mixed "$(classify_signal "$STATE/t7.status $STATE/t1.status" "$STATE")"
emit cls.signal.two "$(classify_signal "$STATE/t1.status $STATE/t2.status" "$STATE")"
emit cls.signal.missing "$(classify_signal "$STATE/nosuch.status" "$STATE")"
emit cls.signal.empty "$(classify_signal '' "$STATE")"
emit cls.signal.emptyfile "$(classify_signal "$STATE/t6.status" "$STATE")"
emit cls.signal.blocked "$(classify_signal "$STATE/t4.status" "$STATE")"

emit cls.stale.terminal "$(classify_stale 'firstmate:fm-t1' "$STATE")"
emit cls.stale.transient "$(classify_stale 'firstmate:fm-t2' "$STATE")"
emit cls.stale.paused "$(classify_stale 'firstmate:fm-t3' "$STATE")"
emit cls.stale.seen "$(classify_stale 'firstmate:fm-t7' "$STATE")"
emit cls.stale.blocked "$(classify_stale 'firstmate:fm-t4' "$STATE")"
emit cls.stale.nostatus "$(classify_stale 'firstmate:fm-nosuch' "$STATE")"
emit cls.stale.emptyfile "$(classify_stale 'firstmate:fm-t6' "$STATE")"
emit cls.stale.nocolon "$(classify_stale 'fm-t4' "$STATE")"

emit cls.check "$(classify_check 'check: PR merged https://example.invalid/pr/1')"
emit cls.heartbeat "$(classify_heartbeat)"
emit cls.unknown "$(classify_unknown 'watcher: already running')"

emit task.backend "$(task_window_backend 'firstmate:fm-t1' "$STATE")"
emit task.harness "$(task_window_harness 'firstmate:fm-t1' "$STATE")"
emit task.backend.missing "$(task_window_backend 'firstmate:fm-nosuch' "$STATE")"
emit win.fortask "$(window_for_task t1 "$STATE" || true)"
emit win.fortask.missing "$(window_for_task nosuch-key "$STATE" || true)"

# --- escalation buffer ------------------------------------------------------
# An AGE is measured against each world's own clock, and the two worlds run
# minutes apart on this host, so an absolute age can never be compared directly.
# Each side instead BRACKETS the reader: it samples its own clock immediately
# before and after the call, and the answer must land inside [before-base,
# after-base]. That is exact rather than tolerant, and it survives a host where
# a single `date` fork takes seconds under load - measured here at 3s, which is
# what a fixed +/-2s tolerance could not survive.
bracket() {  # <answer> <base> <clock-before> <clock-after>
  local a=$1 base=$2 n1=$3 n2=$4
  if [ "$a" -ge $((n1 - base)) ] && [ "$a" -le $((n2 - base)) ]; then
    printf in-bracket
  else
    printf 'out:%s' "$a"
  fi
}
emit age.missing "$(_file_age "$BUF/nope")"
N1=$(date +%s); AGE_KNOWN=$(_file_age "$BUF/aged.marker"); N2=$(date +%s)
emit age.known "$(bracket "$AGE_KNOWN" "$(_stat_file_mtime "$BUF/aged.marker")" "$N1" "$N2")"
emit oldest.absent "$(_oldest_line_age "$BUF/empty/.subsuper-escalations")"
emit oldest.zero "$(_oldest_line_age "$BUF/zero/.subsuper-escalations")"
emit oldest.nosince "$(_oldest_line_age "$BUF/nosince/.subsuper-escalations")"
N1=$(date +%s); AGE_OLDEST=$(_oldest_line_age "$BUF/aged/.subsuper-escalations"); N2=$(date +%s)
emit oldest.aged "$(bracket "$AGE_OLDEST" "$(cat "$BUF/aged/.subsuper-escalations.since")" "$N1" "$N2")"

# escalate_add on an empty buffer writes the .since sidecar; a second add must
# NOT reset it, or the batch window would measure the newest item.
ADD="$BUF/add"; mkdir -p "$ADD"
escalate_add "$ADD" 'first item'
S1=$(cat "$ADD/.subsuper-escalations.since" 2>/dev/null || printf MISSING)
escalate_add "$ADD" 'second item'
S2=$(cat "$ADD/.subsuper-escalations.since" 2>/dev/null || printf MISSING)
emit add.buffer "$(cat "$ADD/.subsuper-escalations")"
emit add.since_stable "$( [ "$S1" = "$S2" ] && printf stable || printf reset )"

# The presence gate: away mode OFF means the flush REFUSES and the buffer is
# preserved for the next catch-up. This is the refusal that matters most - a
# flush that "succeeded" while nobody was listening would drop escalations.
FL="$BUF/flush"; mkdir -p "$FL"
escalate_add "$FL" 'alpha'
escalate_add "$FL" 'beta'
log_reset
emit flush.gated "$(tf escalate_flush "$FL")"
emit flush.log "$(log_read)"
emit flush.preserved "$(cat "$FL/.subsuper-escalations")"
LOG=

# inject_msg refuses the same way, and says so.
log_reset
emit inject.gated "$(tf inject_msg 'a digest' "$FL")"
emit inject.log "$(log_read)"
LOG=

# --- wedge alarm: configured channels ---------------------------------------
chan_case() {  # <label> <config-dir-or-NONE> <env-or-UNSET>
  if [ "$3" = UNSET ]; then unset FM_WEDGE_ALARM_CHANNEL; else FM_WEDGE_ALARM_CHANNEL=$3; fi
  if [ "$2" = NONE ]; then unset FM_CONFIG_OVERRIDE; else FM_CONFIG_OVERRIDE=$WA/$2; fi
  emit "chan.$1" "$(wedge_alarm_configured_channels | tr '\n' ',')"
  unset FM_WEDGE_ALARM_CHANNEL FM_CONFIG_OVERRIDE
}
chan_case absent absent UNSET
chan_case plain plain UNSET
chan_case comments comments UNSET
chan_case multi multi UNSET
chan_case onlycomments onlycomments UNSET
chan_case blankonly blankonly UNSET
chan_case envwins multi 'command:override-me'
chan_case envonly absent off

# --- wedge alarm: platform default ------------------------------------------
plat_case() {  # <label> <fake-uname-dir>
  local base=$PATH
  PATH="$UN/$2:$base"
  emit "plat.$1" "$(wedge_alarm_platform_default)"
  PATH=$base
}
plat_case darwin darwin
plat_case mingw mingw
plat_case linux linux

# --- wedge alarm: notification routing (through the recorder seam) -----------
notify_case() {  # <label> <config-dir> <uname-dir> <exec>
  local base=$PATH
  PATH="$UN/$3:$base"
  FM_CONFIG_OVERRIDE=$WA/$2
  FM_WEDGE_ALARM_EXEC=$4
  log_reset
  wedge_alarm_notify "SUMMARY" "/tmp/marker" >/dev/null 2>&1
  emit "notify.$1.log" "$(log_read)"
  unset FM_CONFIG_OVERRIDE
  FM_WEDGE_ALARM_EXEC=discard
  LOG=
  PATH=$base
}
NOTIFY_DIR=$(dirname "$REC")
notify_case single single mingw "$REC"
notify_case multi multi mingw "$REC"
notify_case bogus bogus mingw "$REC"
notify_case offonly offonly mingw "$REC"
notify_case autolinux absent linux "$REC"
notify_case autodarwin absent darwin "$REC"
emit notify.recorded "$(LC_ALL=C sort "$RECLOG" 2>/dev/null | tr '\n' ',')"

# The override seam's own return convention: 2 = no override configured (run the
# real notifier), 0 = discard or a clean run, 1 = the override failed.
FM_WEDGE_ALARM_EXEC=discard
wedge_alarm_os_notifier_override herdr 'x'; emit override.discard "$?"
FM_WEDGE_ALARM_EXEC="$REC"
wedge_alarm_os_notifier_override herdr 'x'; emit override.recorder "$?"
FM_WEDGE_ALARM_EXEC="$NOTIFY_DIR/failing-notifier"
log_reset
wedge_alarm_os_notifier_override herdr 'x'; emit override.failing "$?"
emit override.failing.log "$(log_read)"
LOG=
FM_WEDGE_ALARM_EXEC=discard

# --- wake dispatch (mutating; a fresh state tree per case) -------------------
observe() {  # <dir>
  local d=$1 f base names out='' seen='' buf
  # Collated with LC_ALL=C so the ordering matches the twin's ordinal sort
  # rather than the host's locale.
  names=$(for f in "$d"/.subsuper-*; do
      [ -e "$f" ] || continue
      printf '%s\n' "${f##*/}"
    done | LC_ALL=C sort)
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    out="$out$base,"
    case "$base" in
      .subsuper-seen-status-*) seen="$seen$base=$(cat "$d/$base");" ;;
    esac
  done <<EOF
$names
EOF
  buf=$(cat "$d/.subsuper-escalations" 2>/dev/null || true)
  printf '%s\036%s\036%s' "$out" "$seen" "$buf"
}
wake_case() {  # <label> <reason> <skip-or-UNSET>
  local d="$WAKE/$1"
  if [ "$3" = UNSET ]; then unset FM_INJECT_SKIP; else FM_INJECT_SKIP=$3; fi
  FM_ESCALATE_BATCH_SECS=90
  log_reset
  handle_wake "$2" "$d"
  emit "wake.$1.state" "$(observe "$d")"
  emit "wake.$1.log" "$(log_read)"
  LOG=
  unset FM_INJECT_SKIP FM_ESCALATE_BATCH_SECS
}
wake_case w-signal-new "signal: $WAKE/w-signal-new/t1.status" UNSET
wake_case w-signal-routine "signal: $WAKE/w-signal-routine/t2.status" UNSET
wake_case w-signal-seen "signal: $WAKE/w-signal-seen/t7.status" UNSET
wake_case w-stale-terminal 'stale: firstmate:fm-t1' UNSET
wake_case w-stale-transient 'stale: firstmate:fm-t2' UNSET
wake_case w-stale-paused 'stale: firstmate:fm-t3' UNSET
wake_case w-stale-wedgedetail 'stale: firstmate:fm-t2 (idle 300s, possible wedge, escalation 1)' UNSET
wake_case w-check 'check: PR merged https://example.invalid/pr/1' UNSET
wake_case w-heartbeat 'heartbeat' UNSET
wake_case w-unknown 'watcher: already running' UNSET
wake_case w-forceself 'check: PR merged' 'check:'
SH

# ============================================================================
# The PowerShell PROBE: one process, the same cases plus the startup refusals.
# ============================================================================
cat > "$PROBES/daemon.ps1" <<'PSHEAD'
param(
    [string]$BinDir, [string]$StateDir, [string]$BufDir, [string]$WedgeDir,
    [string]$UnameDir, [string]$Recorder, [string]$WakeDir, [string]$OutFile,
    [string]$MainDir, [string]$RecorderLog, [string]$LogPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Answers = [System.Text.StringBuilder]::new()
function Emit {
    param([Parameter(Mandatory)][string]$Label, [AllowEmptyString()][AllowNull()][string]$Value = '')
    if ($null -eq $Value) { $Value = '' }
    [void]$Answers.Append($Label + "`t" + ($Value -replace "`n", '\n') + "`n")
}
function TF { param([bool]$Value) if ($Value) { 'True' } else { 'False' } }
function Set-CaseEnv {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value) { [Environment]::SetEnvironmentVariable($Name, $null) }
    else { [Environment]::SetEnvironmentVariable($Name, $Value) }
}

# The recorder is wired BEFORE the library-mode default so no case can ever
# leave the seam empty - empty means "fire the real notifier".
[Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_EXEC', 'discard')
[Environment]::SetEnvironmentVariable('FM_HOME', $StateDir)
Import-Module (Join-Path $BinDir 'fm-supervise-daemon.psm1') -Force
Import-Module (Join-Path $BinDir 'fm-common.psm1')
Import-Module (Join-Path $BinDir 'fm-operational-input.psm1')
Set-FmDaemonLibraryMode

$LogFile = $LogPath
function Reset-Log {
    Set-FmFileText -Path $LogFile -Text '' -NoNewline
    Set-FmDaemonLogPath -Path $LogFile
}
function Read-Log {
    Set-FmDaemonLogPath -Path ''
    $text = Get-FmFileText -Path $LogFile
    if ($text -eq '') { return '' }
    $out = ''
    # NOT `@(Get-FmFileLines ...)`. That helper returns `, @($lines)` so an empty
    # result survives the pipeline as an array; wrapping it in @() hands back a
    # ONE-element array whose element is the whole string[], and the body below
    # then -replaces an ARRAY and concatenates it with $OFS - which shows up as a
    # stray space before every record separator. Measured: 17 assertions failed
    # with exactly that one-space difference before this line lost its @().
    $lines = Get-FmFileLines -Path $LogFile
    foreach ($line in $lines) {
        # Drop the "[timestamp] " prefix so the WORDING is compared, not the clock.
        $out += ([string]$line -replace '^\[[^\]]*\] ', '') + [char]0x1e
    }
    return $out
}
PSHEAD
cat >> "$PROBES/daemon.ps1" <<'PS'

# --- constants ---------------------------------------------------------------
Emit 'const.backends' (Get-FmDaemonSupportedBackend)
foreach ($n in @('InjectSkip', 'StaleEscalateSecs', 'EscalateBatchSecs', 'HeartbeatScanSecs',
        'HousekeepingTick', 'MaxDeferSecs', 'WedgeAlarmTimeout', 'InjectFailSleep',
        'InjectConfirmRetries', 'InjectConfirmSleep', 'CrashThreshold', 'CrashWindow',
        'CrashBackoff', 'CrashNormalSleep', 'LogMaxBytes', 'LogKeepLines')) {
    Emit "const.$n" (Get-FmDaemonDefault $n)
}

# --- pure string helpers -----------------------------------------------------
$i = 0
foreach ($k in @('a:b/c.d', '', 'plain', 'fm-x.status', 'firstmate:fm-t1', '::://...')) {
    Emit "key.$i" (Get-FmDaemonStaleKey $k)
    $i++
}
Emit 'collapse.0' (ConvertTo-FmDaemonSingleLine 'plain')
Emit 'collapse.multi' (ConvertTo-FmDaemonSingleLine "a`nb`nc")
Emit 'collapse.empty' (ConvertTo-FmDaemonSingleLine '')
Emit 'collapse.blankline' (ConvertTo-FmDaemonSingleLine "a`n`nb")
Emit 'hash.empty' (Get-FmDaemonTextHash '')
Emit 'hash.hello' (Get-FmDaemonTextHash 'hello')
Emit 'hash.spaced' (Get-FmDaemonTextHash 'a b c')

$i = 0
foreach ($r in @('signal: a b', 'stale: firstmate:fm-x', 'check: merged', 'heartbeat', 'heartbeat: 5',
        '', 'watcher: already running', 'signal', 'Signal: x', 'heartbeatx')) {
    Emit "wake.$i" (TF (Test-FmDaemonWakeReason -Reason $r))
    $i++
}

function Test-ForceCase {
    param([string]$Label, [AllowNull()][string]$Skip, [string]$Reason)
    Set-CaseEnv 'FM_INJECT_SKIP' $Skip
    Emit "force.$Label" (TF (Test-FmDaemonForceSelf -Reason $Reason))
    Set-CaseEnv 'FM_INJECT_SKIP' $null
}
Test-ForceCase 'default.hb' $null 'heartbeat'
Test-ForceCase 'default.sig' $null 'signal: x'
Test-ForceCase 'empty.hb' '' 'heartbeat'
Test-ForceCase 'multi.check' 'check:|stale:' 'check: a'
Test-ForceCase 'multi.stale' 'check:|stale:' 'stale: b'
Test-ForceCase 'multi.signal' 'check:|stale:' 'signal: c'
Test-ForceCase 'bars.only' '|' 'anything'
Test-ForceCase 'exact' 'signal: x' 'signal: x'
Test-ForceCase 'prefixonly' 'sig' 'signal: x'

# --- marker / envelope predicates --------------------------------------------
$Mark = Get-FmOperationalConstant -Name 'FM_INJECT_MARK'
$Prefix = Get-FmOperationalConstant -Name 'FM_OPERATIONAL_PREFIX'
$Marked = $Mark + 'legacy body'
$Prefixed = $Prefix + 'untyped body'
$Typed = ConvertTo-FmOperationalInput -Kind 'away-supervisor' -Body 'typed body'
if ($null -eq $Typed) { $Typed = 'ENCODE-FAILED' }
Emit 'inj.empty' (TF (Test-FmMessageIsInjection -Message ''))
Emit 'inj.plain' (TF (Test-FmMessageIsInjection -Message 'plain text'))
Emit 'inj.marked' (TF (Test-FmMessageIsInjection -Message $Marked))
Emit 'inj.prefixed' (TF (Test-FmMessageIsInjection -Message $Prefixed))
Emit 'inj.typed' (TF (Test-FmMessageIsInjection -Message $Typed))
Emit 'inj.late' (TF (Test-FmMessageIsInjection -Message ('x' + $Mark + 'body')))

Emit 'strip.typed' (Remove-FmInjectionMarker -Message $Typed)
Emit 'strip.prefixed' (Remove-FmInjectionMarker -Message $Prefixed)
Emit 'strip.marked' (Remove-FmInjectionMarker -Message $Marked)
Emit 'strip.plain' (Remove-FmInjectionMarker -Message 'plain text')
Emit 'strip.empty' (Remove-FmInjectionMarker -Message '')

$AfkOn = Join-Path $StateDir 'afkon'
$AfkOff = Join-Path $StateDir 'afkoff'
[void][System.IO.Directory]::CreateDirectory($AfkOn)
[void][System.IO.Directory]::CreateDirectory($AfkOff)
Enter-FmAfk -State $AfkOn
Emit 'afk.on' (TF (Test-FmAfkActive -State $AfkOn))
Emit 'afk.off' (TF (Test-FmAfkActive -State $AfkOff))
$i = 0
foreach ($m in @('captain is back', $Marked, $Typed, '/afk', '/afk 30m', '', 'x/afk')) {
    Emit "exit.on.$i" (TF (Test-FmShouldExitAfk -State $AfkOn -Message $m))
    Emit "exit.off.$i" (TF (Test-FmShouldExitAfk -State $AfkOff -Message $m))
    $i++
}
Exit-FmAfk -State $AfkOn
Emit 'afk.after_exit' (TF (Test-FmAfkActive -State $AfkOn))

# --- classifiers -------------------------------------------------------------
function S { param([string]$Name) Join-Path $StateDir $Name }
Emit 'cls.signal.new' (Get-FmDaemonSignalDecision -Reason (S 't1.status') -State $StateDir)
Emit 'cls.signal.routine' (Get-FmDaemonSignalDecision -Reason (S 't2.status') -State $StateDir)
Emit 'cls.signal.seen' (Get-FmDaemonSignalDecision -Reason (S 't7.status') -State $StateDir)
Emit 'cls.signal.mixed' (Get-FmDaemonSignalDecision -Reason ((S 't7.status') + ' ' + (S 't1.status')) -State $StateDir)
Emit 'cls.signal.two' (Get-FmDaemonSignalDecision -Reason ((S 't1.status') + ' ' + (S 't2.status')) -State $StateDir)
Emit 'cls.signal.missing' (Get-FmDaemonSignalDecision -Reason (S 'nosuch.status') -State $StateDir)
Emit 'cls.signal.empty' (Get-FmDaemonSignalDecision -Reason '' -State $StateDir)
Emit 'cls.signal.emptyfile' (Get-FmDaemonSignalDecision -Reason (S 't6.status') -State $StateDir)
Emit 'cls.signal.blocked' (Get-FmDaemonSignalDecision -Reason (S 't4.status') -State $StateDir)

Emit 'cls.stale.terminal' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t1' -State $StateDir)
Emit 'cls.stale.transient' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t2' -State $StateDir)
Emit 'cls.stale.paused' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t3' -State $StateDir)
Emit 'cls.stale.seen' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t7' -State $StateDir)
Emit 'cls.stale.blocked' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t4' -State $StateDir)
Emit 'cls.stale.nostatus' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-nosuch' -State $StateDir)
Emit 'cls.stale.emptyfile' (Get-FmDaemonStaleDecision -Window 'firstmate:fm-t6' -State $StateDir)
Emit 'cls.stale.nocolon' (Get-FmDaemonStaleDecision -Window 'fm-t4' -State $StateDir)

Emit 'cls.check' (Get-FmDaemonCheckDecision -Reason 'check: PR merged https://example.invalid/pr/1')
Emit 'cls.heartbeat' (Get-FmDaemonHeartbeatDecision)
Emit 'cls.unknown' (Get-FmDaemonUnknownDecision -Reason 'watcher: already running')

Emit 'task.backend' (Get-FmDaemonTaskBackend -Window 'firstmate:fm-t1' -State $StateDir)
Emit 'task.harness' (Get-FmDaemonTaskHarness -Window 'firstmate:fm-t1' -State $StateDir)
Emit 'task.backend.missing' (Get-FmDaemonTaskBackend -Window 'firstmate:fm-nosuch' -State $StateDir)
Emit 'win.fortask' (Get-FmDaemonWindowForTask -Key 't1' -State $StateDir)
Emit 'win.fortask.missing' (Get-FmDaemonWindowForTask -Key 'nosuch-key' -State $StateDir)

# --- escalation buffer -------------------------------------------------------
function B { param([string]$Name) Join-Path $BufDir $Name }
# The bracket the oracle uses: sample the clock either side of the call and
# require the answer to land between them. See the note in the oracle.
function Get-Bracket {
    param([long]$Answer, [long]$Base, [long]$Before, [long]$After)
    if ($Answer -ge ($Before - $Base) -and $Answer -le ($After - $Base)) { return 'in-bracket' }
    return "out:$Answer"
}
Emit 'age.missing' ([string](Get-FmDaemonFileAge -Path (B 'nope')))
$markerMtime = [DateTimeOffset]::new(
    ([System.IO.FileInfo]::new((ConvertTo-FmNativePath (B 'aged.marker')))).LastWriteTimeUtc,
    [TimeSpan]::Zero).ToUnixTimeSeconds()
$n1 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ageKnown = Get-FmDaemonFileAge -Path (B 'aged.marker')
$n2 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Emit 'age.known' (Get-Bracket $ageKnown $markerMtime $n1 $n2)
Emit 'oldest.absent' ([string](Get-FmDaemonOldestEscalationAge -Path (B 'empty/.subsuper-escalations')))
Emit 'oldest.zero' ([string](Get-FmDaemonOldestEscalationAge -Path (B 'zero/.subsuper-escalations')))
Emit 'oldest.nosince' ([string](Get-FmDaemonOldestEscalationAge -Path (B 'nosince/.subsuper-escalations')))
$sinceValue = [long]((Get-FmFileText -Path (B 'aged/.subsuper-escalations.since')).Trim())
$n1 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ageOldest = Get-FmDaemonOldestEscalationAge -Path (B 'aged/.subsuper-escalations')
$n2 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Emit 'oldest.aged' (Get-Bracket $ageOldest $sinceValue $n1 $n2)

$add = B 'add'
[void][System.IO.Directory]::CreateDirectory($add)
Add-FmDaemonEscalation -State $add -Item 'first item'
$s1 = Get-FmFileText -Path (Join-Path $add '.subsuper-escalations.since')
Add-FmDaemonEscalation -State $add -Item 'second item'
$s2 = Get-FmFileText -Path (Join-Path $add '.subsuper-escalations.since')
Emit 'add.buffer' ((Get-FmFileText -Path (Join-Path $add '.subsuper-escalations')).TrimEnd("`n"))
Emit 'add.since_stable' $(if ($s1 -ceq $s2) { 'stable' } else { 'reset' })

$flush = B 'flush'
[void][System.IO.Directory]::CreateDirectory($flush)
Add-FmDaemonEscalation -State $flush -Item 'alpha'
Add-FmDaemonEscalation -State $flush -Item 'beta'
Reset-Log
Emit 'flush.gated' (TF (Send-FmDaemonEscalationDigest -State $flush))
Emit 'flush.log' (Read-Log)
Emit 'flush.preserved' ((Get-FmFileText -Path (Join-Path $flush '.subsuper-escalations')).TrimEnd("`n"))

Reset-Log
Emit 'inject.gated' (TF (Send-FmDaemonInjection -Message 'a digest' -State $flush))
Emit 'inject.log' (Read-Log)

# --- wedge alarm: configured channels ----------------------------------------
function Test-ChannelCase {
    param([string]$Label, [string]$Config, [AllowNull()][string]$Override)
    Set-CaseEnv 'FM_WEDGE_ALARM_CHANNEL' $Override
    if ($Config -eq 'NONE') { Set-CaseEnv 'FM_CONFIG_OVERRIDE' $null }
    else { Set-CaseEnv 'FM_CONFIG_OVERRIDE' (Join-Path $WedgeDir $Config) }
    Emit "chan.$Label" ((@(Get-FmWedgeAlarmChannel) -join ',') + ',')
    Set-CaseEnv 'FM_WEDGE_ALARM_CHANNEL' $null
    Set-CaseEnv 'FM_CONFIG_OVERRIDE' $null
}
Test-ChannelCase 'absent' 'absent' $null
Test-ChannelCase 'plain' 'plain' $null
Test-ChannelCase 'comments' 'comments' $null
Test-ChannelCase 'multi' 'multi' $null
Test-ChannelCase 'onlycomments' 'onlycomments' $null
Test-ChannelCase 'blankonly' 'blankonly' $null
Test-ChannelCase 'envwins' 'multi' 'command:override-me'
Test-ChannelCase 'envonly' 'absent' 'off'

# --- wedge alarm: platform default -------------------------------------------
$BasePath = $env:PATH
function Test-PlatformCase {
    param([string]$Label, [string]$Kernel)
    $env:PATH = (Join-Path $UnameDir $Kernel) + [System.IO.Path]::PathSeparator + $BasePath
    Emit "plat.$Label" (Get-FmWedgeAlarmPlatformDefault)
    $env:PATH = $BasePath
}
Test-PlatformCase 'darwin' 'darwin'
Test-PlatformCase 'mingw' 'mingw'
Test-PlatformCase 'linux' 'linux'

# --- wedge alarm: notification routing ---------------------------------------
function Test-NotifyCase {
    param([string]$Label, [string]$Config, [string]$Kernel, [string]$Exec)
    $env:PATH = (Join-Path $UnameDir $Kernel) + [System.IO.Path]::PathSeparator + $BasePath
    Set-CaseEnv 'FM_CONFIG_OVERRIDE' (Join-Path $WedgeDir $Config)
    Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' $Exec
    Reset-Log
    Send-FmWedgeAlarmNotification -Summary 'SUMMARY' -Marker '/tmp/marker'
    Emit "notify.$Label.log" (Read-Log)
    Set-CaseEnv 'FM_CONFIG_OVERRIDE' $null
    Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' 'discard'
    $env:PATH = $BasePath
}
Test-NotifyCase 'single' 'single' 'mingw' $Recorder
Test-NotifyCase 'multi' 'multi' 'mingw' $Recorder
Test-NotifyCase 'bogus' 'bogus' 'mingw' $Recorder
Test-NotifyCase 'offonly' 'offonly' 'mingw' $Recorder
Test-NotifyCase 'autolinux' 'absent' 'linux' $Recorder
Test-NotifyCase 'autodarwin' 'absent' 'darwin' $Recorder
$recorded = [string[]]@()
if ([System.IO.File]::Exists($RecorderLog)) {
    # No @() wrapper - see the note on Read-Log above.
    $recorded = [string[]](Get-FmFileLines -Path $RecorderLog)
    [System.Array]::Sort($recorded, [System.StringComparer]::Ordinal)
}
Emit 'notify.recorded' (($recorded -join ',') + $(if ($recorded.Count -gt 0) { ',' } else { '' }))

Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' 'discard'
Emit 'override.discard' ([string](Invoke-FmWedgeAlarmOverride -Channel 'herdr' -Summary 'x'))
Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' $Recorder
Emit 'override.recorder' ([string](Invoke-FmWedgeAlarmOverride -Channel 'herdr' -Summary 'x'))
$failing = Join-Path (Split-Path -Parent $Recorder) 'failing-notifier'
Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' $failing
Reset-Log
Emit 'override.failing' ([string](Invoke-FmWedgeAlarmOverride -Channel 'herdr' -Summary 'x'))
Emit 'override.failing.log' (Read-Log)
Set-CaseEnv 'FM_WEDGE_ALARM_EXEC' 'discard'

# --- wake dispatch -----------------------------------------------------------
function Get-Observation {
    param([string]$Dir)
    $names = @()
    foreach ($p in [System.IO.Directory]::EnumerateFileSystemEntries($Dir)) {
        $n = [System.IO.Path]::GetFileName($p)
        if ($n.StartsWith('.subsuper-', [System.StringComparison]::Ordinal)) { $names += $n }
    }
    # ORDINAL, not Sort-Object: PowerShell's default comparer is culture-aware
    # and treats '.' and '-' as ignorable at the primary level, so it can order
    # two marker names differently from the oracle's `LC_ALL=C sort`.
    $names = [string[]]@($names)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $nameField = if ($names.Count -eq 0) { '' } else { ($names -join ',') + ',' }
    $seen = ''
    foreach ($n in $names) {
        if (-not $n.StartsWith('.subsuper-seen-status-', [System.StringComparison]::Ordinal)) { continue }
        $seen += "$n=" + (Get-FmFileText -Path (Join-Path $Dir $n)) + ';'
    }
    # `$(cat f)` strips trailing newlines, so the raw read is trimmed to match.
    $buffer = (Get-FmFileText -Path (Join-Path $Dir '.subsuper-escalations')).TrimEnd("`n")
    return $nameField + [char]0x1e + $seen + [char]0x1e + $buffer
}
function Test-WakeCase {
    param([string]$Label, [string]$Reason, [AllowNull()][string]$Skip)
    $dir = Join-Path $WakeDir $Label
    Set-CaseEnv 'FM_INJECT_SKIP' $Skip
    Set-CaseEnv 'FM_ESCALATE_BATCH_SECS' '90'
    Reset-Log
    Invoke-FmDaemonWake -Reason $Reason -State $dir
    Emit "wake.$Label.state" (Get-Observation $dir)
    Emit "wake.$Label.log" (Read-Log)
    Set-CaseEnv 'FM_INJECT_SKIP' $null
    Set-CaseEnv 'FM_ESCALATE_BATCH_SECS' $null
}
function StatusPath { param([string]$Case, [string]$Name) Join-Path (Join-Path $WakeDir $Case) $Name }
Test-WakeCase 'w-signal-new' ('signal: ' + (StatusPath 'w-signal-new' 't1.status')) $null
Test-WakeCase 'w-signal-routine' ('signal: ' + (StatusPath 'w-signal-routine' 't2.status')) $null
Test-WakeCase 'w-signal-seen' ('signal: ' + (StatusPath 'w-signal-seen' 't7.status')) $null
Test-WakeCase 'w-stale-terminal' 'stale: firstmate:fm-t1' $null
Test-WakeCase 'w-stale-transient' 'stale: firstmate:fm-t2' $null
Test-WakeCase 'w-stale-paused' 'stale: firstmate:fm-t3' $null
Test-WakeCase 'w-stale-wedgedetail' 'stale: firstmate:fm-t2 (idle 300s, possible wedge, escalation 1)' $null
Test-WakeCase 'w-check' 'check: PR merged https://example.invalid/pr/1' $null
Test-WakeCase 'w-heartbeat' 'heartbeat' $null
Test-WakeCase 'w-unknown' 'watcher: already running' $null
Test-WakeCase 'w-forceself' 'check: PR merged' 'check:'

# --- startup refusals: main, in-process --------------------------------------
#
# This is why main lives in the .psm1 and not the .ps1: the whole startup-refusal
# surface is reachable without spawning one pwsh per case. Console output is
# captured through the real handles because fm-common writes to them directly,
# not to a PowerShell stream.
$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
function Test-MainCase {
    param([string]$Label, [string]$State, [hashtable]$Env)
    [void][System.IO.Directory]::CreateDirectory($State)
    $touched = @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_SUPERVISOR_BACKEND', 'FM_SUPERVISOR_TARGET',
        'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID')
    foreach ($n in $touched) { [Environment]::SetEnvironmentVariable($n, $null) }
    [Environment]::SetEnvironmentVariable('FM_HOME', $State)
    [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $State)
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }

    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $rc = -1
    $threw = ''
    try { $rc = Invoke-FmSuperviseDaemonMain } catch { $threw = $_.Exception.Message }
    [Console]::SetOut($OrigOut)
    [Console]::SetError($OrigErr)

    Emit "main.$Label.rc" ([string]$rc)
    Emit "main.$Label.out" ($so.ToString().TrimEnd("`n"))
    Emit "main.$Label.err" ($se.ToString().TrimEnd("`n") + $(if ($threw -ne '') { "THREW: $threw" } else { '' }))
    $leftovers = @()
    foreach ($n in @('.supervise-daemon.lock', '.supervise-daemon.pid')) {
        if (Test-Path -LiteralPath (Join-Path $State $n)) { $leftovers += $n }
    }
    Emit "main.$Label.leftovers" ($leftovers -join ',')
    foreach ($n in $touched) { [Environment]::SetEnvironmentVariable($n, $null) }
    [Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_EXEC', 'discard')
}
Test-MainCase 'zellij' (Join-Path $MainDir 'zellij') @{ FM_SUPERVISOR_BACKEND = 'zellij' }
Test-MainCase 'orca' (Join-Path $MainDir 'orca') @{ FM_SUPERVISOR_BACKEND = 'orca' }
Test-MainCase 'cmux' (Join-Path $MainDir 'cmux') @{ FM_SUPERVISOR_BACKEND = 'cmux' }
Test-MainCase 'bogus' (Join-Path $MainDir 'bogus') @{ FM_SUPERVISOR_BACKEND = 'not-a-backend' }
Test-MainCase 'notarget' (Join-Path $MainDir 'notarget') `
    @{ FM_SUPERVISOR_BACKEND = 'tmux'; FM_SUPERVISOR_TARGET = 'nosuch-session:0' }

[System.IO.File]::WriteAllText($OutFile, $Answers.ToString().Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false))
PS

# --- run both worlds ---------------------------------------------------------
MAIN_B="$FIX/main-b"; mkdir -p "$MAIN_B"
MAIN_P="$FIX/main-p"; mkdir -p "$MAIN_P"

B_OUT=$(oracle daemon "$ROOT" "$ST_B" "$BUF_B" "$WA" "$UN" "$FIX/recorder-b" "$WK/b" \
  "$REC_B" "$FIX/oracle.log")

# The bash STARTUP REFUSALS. There is no way to execute a bash program without a
# process, so these are the suite's only per-case forks; the PowerShell side runs
# all five inside the single probe below. Each is bounded by `timeout` where the
# host has one: a refusal that did NOT refuse would otherwise loop forever, and a
# hung suite is a worse failure report than a red one.
run_main_case() {  # <label> <backend> <target-or-empty>
  local label=$1 backend=$2 target=$3 rc out err leftovers=''
  local dir="$MAIN_B/$label"
  mkdir -p "$dir"
  out="$TMP_ROOT/main-$label.out"; err="$TMP_ROOT/main-$label.err"
  if command -v timeout >/dev/null 2>&1; then
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir" FM_SUPERVISOR_BACKEND="$backend" \
      FM_SUPERVISOR_TARGET="$target" FM_WEDGE_ALARM_EXEC=discard \
      timeout 120 bash "$ROOT/bin/fm-supervise-daemon.sh" >"$out" 2>"$err"
    rc=$?
  else
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir" FM_SUPERVISOR_BACKEND="$backend" \
      FM_SUPERVISOR_TARGET="$target" FM_WEDGE_ALARM_EXEC=discard \
      bash "$ROOT/bin/fm-supervise-daemon.sh" >"$out" 2>"$err"
    rc=$?
  fi
  local n
  for n in .supervise-daemon.lock .supervise-daemon.pid; do
    [ -e "$dir/$n" ] && leftovers="${leftovers:+$leftovers,}$n"
  done
  # Same record encoding as the oracle's emit(): embedded newlines become a
  # literal \n so one case is one line, and `$(cat)`'s trailing-newline strip
  # matches the twin's TrimEnd.
  local ov ev
  ov=$(cat "$out"); ev=$(cat "$err")
  printf 'main.%s.rc\t%s\n' "$label" "$rc"
  printf 'main.%s.out\t%s\n' "$label" "${ov//$'\n'/\\n}"
  printf 'main.%s.err\t%s\n' "$label" "${ev//$'\n'/\\n}"
  printf 'main.%s.leftovers\t%s\n' "$label" "$leftovers"
}
B_MAIN=$(
  run_main_case zellij zellij ''
  run_main_case orca orca ''
  run_main_case cmux cmux ''
  run_main_case bogus not-a-backend ''
  run_main_case notarget tmux 'nosuch-session:0'
)
B_OUT="$B_OUT
$B_MAIN"

PS_ANSWERS="$TMP_ROOT/ps-answers.tsv"
pwsh -NoProfile -File "$(fm_test_native_path "$PROBES/daemon.ps1")" \
  "$BIN_N" "$ST_P_N" "$(fm_test_native_path "$BUF_P")" "$WA_N" "$UN_N" \
  "$(fm_test_native_path "$FIX/recorder-p")" "$(fm_test_native_path "$WK/p")" \
  "$(fm_test_native_path "$PS_ANSWERS")" "$(fm_test_native_path "$MAIN_P")" \
  "$(fm_test_native_path "$REC_P")" "$(fm_test_native_path "$FIX/probe.log")" \
  >"$TMP_ROOT/probe.out" 2>&1 || {
    printf 'not ok - the PowerShell probe failed to run\n' >&2
    cat "$TMP_ROOT/probe.out" >&2
    exit 1
  }
[ -f "$PS_ANSWERS" ] || {
  printf 'not ok - the PowerShell probe produced no answers\n' >&2
  cat "$TMP_ROOT/probe.out" >&2
  exit 1
}
P_OUT=$(cat "$PS_ANSWERS")

# ============================================================================
# Assertions
# ============================================================================

for k in backends InjectSkip StaleEscalateSecs EscalateBatchSecs HeartbeatScanSecs \
         HousekeepingTick MaxDeferSecs WedgeAlarmTimeout InjectFailSleep \
         InjectConfirmRetries InjectConfirmSleep CrashThreshold CrashWindow \
         CrashBackoff CrashNormalSleep LogMaxBytes LogKeepLines; do
  both "const.$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: default $k has one value in both worlds"
done
assert_same "fm-supervise-daemon: only tmux and herdr have verified injection primitives" \
  "tmux herdr" "$(ps_get "$P_OUT" 'const.backends')"

for i in 0 1 2 3 4 5; do
  both "key.$i" "$B_OUT" "$P_OUT" "fm-supervise-daemon: marker key ($i)"
done
assert_same "fm-supervise-daemon: the marker key maps ':' '/' and '.' to '_', character by character" \
  "a_b_c_d" "$(ps_get "$P_OUT" 'key.0')"
for k in collapse.0 collapse.multi collapse.empty collapse.blankline; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: $k"
done
assert_same "fm-supervise-daemon: every newline collapses to ' - ' so a digest stays one line" \
  "a - b - c" "$(ps_get "$P_OUT" 'collapse.multi')"
for k in hash.empty hash.hello hash.spaced; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: $k"
done

for i in 0 1 2 3 4 5 6 7 8 9; do
  both "wake.$i" "$B_OUT" "$P_OUT" "fm-supervise-daemon: is-a-wake-reason ($i)"
done
assert_same "fm-supervise-daemon: a watcher singleton-collision line is NOT a wake" \
  "False" "$(ps_get "$P_OUT" 'wake.6')"
assert_same "fm-supervise-daemon: a bare heartbeat IS a wake" \
  "True" "$(ps_get "$P_OUT" 'wake.3')"
assert_same "fm-supervise-daemon: 'heartbeatx' is not a heartbeat wake" \
  "False" "$(ps_get "$P_OUT" 'wake.9')"

for k in default.hb default.sig empty.hb multi.check multi.stale multi.signal bars.only exact prefixonly; do
  both "force.$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: force-self prefix match ($k)"
done
assert_same "fm-supervise-daemon: the default skip list force-handles heartbeat" \
  "True" "$(ps_get "$P_OUT" 'force.default.hb')"
# The header says "empty disables", but the CODE says `${FM_INJECT_SKIP:-heartbeat}`,
# so an EMPTY value falls back to the default rather than switching force-self
# off; only a non-empty list that matches nothing disables it in practice. Both
# worlds agree on the code's reading, and it is pinned literally here so a later
# author cannot "fix" one world to match the prose.
assert_same "fm-supervise-daemon: an EMPTY skip list means the default list, not 'disabled'" \
  "True" "$(ps_get "$P_OUT" 'force.empty.hb')"
assert_same "fm-supervise-daemon: a non-empty skip list that matches nothing does not force-self" \
  "False" "$(ps_get "$P_OUT" 'force.multi.signal')"
assert_same "fm-supervise-daemon: a bars-only skip list matches nothing" \
  "False" "$(ps_get "$P_OUT" 'force.bars.only')"

for k in inj.empty inj.plain inj.marked inj.prefixed inj.typed inj.late; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: injection-marker predicate ($k)"
done
assert_same "fm-supervise-daemon: a marker that is not at the START does not forge an injection" \
  "False" "$(ps_get "$P_OUT" 'inj.late')"
for k in strip.typed strip.prefixed strip.marked strip.plain strip.empty; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: envelope stripping ($k)"
done
assert_same "fm-supervise-daemon: the current typed envelope yields its body" \
  "typed body" "$(ps_get "$P_OUT" 'strip.typed')"
assert_same "fm-supervise-daemon: the legacy bare sentinel still yields its body" \
  "legacy body" "$(ps_get "$P_OUT" 'strip.marked')"

both afk.on "$B_OUT" "$P_OUT" "fm-supervise-daemon: the away flag reads present"
both afk.off "$B_OUT" "$P_OUT" "fm-supervise-daemon: the away flag reads absent"
both afk.after_exit "$B_OUT" "$P_OUT" "fm-supervise-daemon: clearing the away flag is observable"
for i in 0 1 2 3 4 5 6; do
  both "exit.on.$i" "$B_OUT" "$P_OUT" "fm-supervise-daemon: away-exit decision, away ON ($i)"
  both "exit.off.$i" "$B_OUT" "$P_OUT" "fm-supervise-daemon: away-exit decision, away OFF ($i)"
done
assert_same "fm-supervise-daemon: an ordinary captain message ends away mode" \
  "True" "$(ps_get "$P_OUT" 'exit.on.0')"
assert_same "fm-supervise-daemon: a marked internal escalation does NOT end away mode" \
  "False" "$(ps_get "$P_OUT" 'exit.on.1')"
assert_same "fm-supervise-daemon: a typed away envelope does NOT end away mode" \
  "False" "$(ps_get "$P_OUT" 'exit.on.2')"
assert_same "fm-supervise-daemon: re-invoking /afk does NOT end away mode" \
  "False" "$(ps_get "$P_OUT" 'exit.on.3')"
assert_same "fm-supervise-daemon: away mode already off has nothing to exit" \
  "False" "$(ps_get "$P_OUT" 'exit.off.0')"

for k in cls.signal.new cls.signal.routine cls.signal.seen cls.signal.mixed cls.signal.two \
         cls.signal.missing cls.signal.empty cls.signal.emptyfile cls.signal.blocked; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: signal classification ($k)"
done
assert_same "fm-supervise-daemon: a fresh terminal status escalates with its distilled line" \
  "escalate|t1.status: done: PR https://example.invalid/pr/1 checks green" \
  "$(ps_get "$P_OUT" 'cls.signal.new')"
assert_same "fm-supervise-daemon: an already-escalated terminal self-handles instead of duplicating" \
  "self|signal already escalated (catch-all scan): t7.status: done: PR https://example.invalid/pr/7 checks green" \
  "$(ps_get "$P_OUT" 'cls.signal.seen')"
assert_same "fm-supervise-daemon: one unseen relevant file among seen ones still escalates" \
  "escalate|t7.status: done: PR https://example.invalid/pr/7 checks green | t1.status: done: PR https://example.invalid/pr/1 checks green" \
  "$(ps_get "$P_OUT" 'cls.signal.mixed')"
assert_same "fm-supervise-daemon: a working: line is routine" \
  "self|routine signal: t2.status: working: still going" \
  "$(ps_get "$P_OUT" 'cls.signal.routine')"

for k in cls.stale.terminal cls.stale.transient cls.stale.paused cls.stale.seen \
         cls.stale.blocked cls.stale.nostatus cls.stale.emptyfile cls.stale.nocolon; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: stale classification ($k)"
done
assert_same "fm-supervise-daemon: a DECLARED pause is a pause, never a wedge" \
  "pause|paused (awaiting external), rechecked on a long cadence: paused: awaiting external CI" \
  "$(ps_get "$P_OUT" 'cls.stale.paused')"
assert_same "fm-supervise-daemon: a stale pane with a terminal status escalates" \
  "escalate|stale + terminal status: done: PR https://example.invalid/pr/1 checks green" \
  "$(ps_get "$P_OUT" 'cls.stale.terminal')"
assert_same "fm-supervise-daemon: a working: line keeps wedge aging rather than taking the terminal path" \
  "self|transient stale (firstmate:fm-t2): working: still going" \
  "$(ps_get "$P_OUT" 'cls.stale.transient')"
assert_same "fm-supervise-daemon: an unknown window has no status to read" \
  "self|transient stale (firstmate:fm-nosuch): no status" \
  "$(ps_get "$P_OUT" 'cls.stale.nostatus')"

both cls.check "$B_OUT" "$P_OUT" "fm-supervise-daemon: a check wake always escalates"
both cls.heartbeat "$B_OUT" "$P_OUT" "fm-supervise-daemon: a heartbeat wake always self-handles"
both cls.unknown "$B_OUT" "$P_OUT" "fm-supervise-daemon: an unrecognized wake escalates (fail-safe)"
assert_same "fm-supervise-daemon: the unknown-wake distillation names the reason" \
  "escalate|unknown wake: watcher: already running" "$(ps_get "$P_OUT" 'cls.unknown')"

for k in task.backend task.harness task.backend.missing win.fortask win.fortask.missing; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: $k"
done
assert_same "fm-supervise-daemon: a marker key with no recorded task resolves to nothing" \
  "" "$(ps_get "$P_OUT" 'win.fortask.missing')"

for k in age.missing age.known oldest.absent oldest.zero oldest.nosince oldest.aged \
         add.buffer add.since_stable flush.gated flush.log flush.preserved \
         inject.gated inject.log; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: escalation buffer ($k)"
done
assert_same "fm-supervise-daemon: an unreadable mtime reads as ancient, never as fresh" \
  "999999" "$(ps_get "$P_OUT" 'age.missing')"
assert_same "fm-supervise-daemon: a readable mtime yields the real age, not the sentinel" \
  "in-bracket" "$(ps_get "$P_OUT" 'age.known')"
assert_same "fm-supervise-daemon: the batch age is measured from the .since sidecar" \
  "in-bracket" "$(ps_get "$P_OUT" 'oldest.aged')"
assert_same "fm-supervise-daemon: a buffer with no .since sidecar reads as overdue" \
  "999999" "$(ps_get "$P_OUT" 'oldest.nosince')"
assert_same "fm-supervise-daemon: the .since sidecar measures the BATCH, not its newest member" \
  "stable" "$(ps_get "$P_OUT" 'add.since_stable')"
assert_same "fm-supervise-daemon: a flush with away mode off REFUSES" \
  "False" "$(ps_get "$P_OUT" 'flush.gated')"
assert_same "fm-supervise-daemon: a refused flush PRESERVES the buffer" \
  "alpha\nbeta" "$(ps_get "$P_OUT" 'flush.preserved')"

for k in absent plain comments multi onlycomments blankonly envwins envonly; do
  both "chan.$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: wedge-alarm channel config ($k)"
done
assert_same "fm-supervise-daemon: an ABSENT wedge-alarm config means auto, never silence" \
  "auto," "$(ps_get "$P_OUT" 'chan.absent')"
assert_same "fm-supervise-daemon: a comments-and-blanks-only config still means auto" \
  "auto," "$(ps_get "$P_OUT" 'chan.onlycomments')"
assert_same "fm-supervise-daemon: comments are dropped and directives are trimmed" \
  "osascript," "$(ps_get "$P_OUT" 'chan.comments')"
assert_same "fm-supervise-daemon: FM_WEDGE_ALARM_CHANNEL replaces the whole file with one directive" \
  "command:override-me," "$(ps_get "$P_OUT" 'chan.envwins')"

for k in darwin mingw linux; do
  both "plat.$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: platform default channel ($k)"
done
assert_same "fm-supervise-daemon: a Windows kernel resolves auto to the powershell toast" \
  "powershell" "$(ps_get "$P_OUT" 'plat.mingw')"
assert_same "fm-supervise-daemon: a Linux kernel has no built-in OS channel" \
  "" "$(ps_get "$P_OUT" 'plat.linux')"

for k in single multi bogus offonly autolinux autodarwin; do
  both "notify.$k.log" "$B_OUT" "$P_OUT" "fm-supervise-daemon: wedge-alarm notify log ($k)"
done
both notify.recorded "$B_OUT" "$P_OUT" "fm-supervise-daemon: every channel routes through the notifier seam"
for k in override.discard override.recorder override.failing override.failing.log; do
  both "$k" "$B_OUT" "$P_OUT" "fm-supervise-daemon: notifier seam ($k)"
done
assert_same "fm-supervise-daemon: 'discard' fires nothing and reports success" \
  "0" "$(ps_get "$P_OUT" 'override.discard')"
assert_same "fm-supervise-daemon: a failing notifier override is reported, not swallowed" \
  "1" "$(ps_get "$P_OUT" 'override.failing')"

for c in $WAKE_CASES; do
  both "wake.$c.state" "$B_OUT" "$P_OUT" "fm-supervise-daemon: wake dispatch state ($c)"
  both_np "wake.$c.log" "$B_OUT" "$P_OUT" "fm-supervise-daemon: wake dispatch log ($c)"
done

for c in zellij orca cmux bogus notarget; do
  both "main.$c.rc" "$B_OUT" "$P_OUT" "fm-supervise-daemon: startup refusal exit code ($c)"
  both "main.$c.err" "$B_OUT" "$P_OUT" "fm-supervise-daemon: startup refusal diagnostic ($c)"
  both "main.$c.out" "$B_OUT" "$P_OUT" "fm-supervise-daemon: startup refusal prints nothing on stdout ($c)"
  both "main.$c.leftovers" "$B_OUT" "$P_OUT" "fm-supervise-daemon: a refused start leaves no lock or pid file ($c)"
done
assert_same "fm-supervise-daemon: an unsupported supervisor backend refuses loudly" \
  "1" "$(ps_get "$P_OUT" 'main.zellij.rc')"
assert_same "fm-supervise-daemon: a refused start leaves nothing behind" \
  "" "$(ps_get "$P_OUT" 'main.zellij.leftovers')"

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - %s of %s differential assertions failed\n\n%s\n' \
    "$FAILURES" "$ASSERTIONS" "$FAILURE_TEXT" >&2
  exit 1
fi
pass "fm-supervise-daemon.psm1 matches bin/fm-supervise-daemon.sh across $ASSERTIONS differential assertions"
