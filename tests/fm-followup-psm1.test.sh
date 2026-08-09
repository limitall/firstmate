#!/usr/bin/env bash
# tests/fm-followup-psm1.test.sh - ONE differential behavior test for the two
# W3-followup PowerShell twins:
#
#   bin/fm-public-followup-lib.psm1  vs  bin/fm-public-followup-lib.sh
#   bin/fm-push-transition-lib.psm1  vs  bin/fm-push-transition-lib.sh
#
# The bash tree is the ORACLE. Every assertion names the module it covers with a
# [pf] or [push] prefix, so a failure says which twin broke without reading the
# case.
#
# WHY THIS SUITE IS WORTH ITS RUNTIME. fm-public-followup-lib owns the durable
# transport for a PROMISED PUBLIC REPLY - a commitment firstmate made in a real
# thread that real people can see. It survives restarts and compaction only
# because it is on disk, and during the whole conversion BOTH LANGUAGES ARE LIVE
# AGAINST THE SAME state/ DIRECTORY. So the interop sections are not a nicety: a
# registration written by bash must read back identically in PowerShell and vice
# versa, and the derived event id must agree to the byte, or "delivered exactly
# once" quietly becomes "delivered twice" or "never delivered".
#
# THE ONE RULE THAT DECIDES WHETHER THIS SUITE FINISHES: BATCH pwsh.
# A bare `pwsh -NoProfile -Command "exit 0"` costs ~4.8s on the reference host,
# so a pwsh call per case turns a 200-case suite into 17 minutes of pure
# interpreter startup and it times out with ZERO output - a hang, not a failure.
# This suite therefore spawns pwsh a small CONSTANT number of times:
#
#   phase 1  every case, in one process, with FMX_PAIRING_TOKEN UNSET
#   phase 2  the relay cases only, with an INHERITED EMPTY FMX_PAIRING_TOKEN
#   phase 3  the relay cases only, with an INHERITED NON-EMPTY token
#   phase 4  the import-hygiene check
#
# Phases 2 and 3 exist because of a real platform limit, not for tidiness:
# `[Environment]::SetEnvironmentVariable(name, '')` DELETES the variable on
# Windows, so a PowerShell process cannot set one of its own to the empty
# string. bash's `${FMX_PAIRING_TOKEN+x}` test distinguishes set-but-empty from
# unset and fm_pf_relay_active branches on exactly that, so the empty value has
# to be INHERITED from this shell at launch. One extra process per environment,
# never one per case.
#
# THREE MORE TRAPS THIS SUITE IS BUILT AROUND, each already paid for here:
#   * No `( ... )` subshell ever holds an ASSERTION. A subshell cannot report
#     back to the parent's counters, so a failure would vanish as a FALSE PASS.
#     Subshells are used only to CAPTURE an oracle value - including the three
#     paths where the bash twin calls `exit` and would otherwise end this
#     script - and every assertion runs in the parent.
#   * No probe is keyed by a PATH. The two worlds spell the same location
#     differently, so a path-keyed answer never matches. Every case is keyed by
#     a stable label, and every path travels as a fixture-RELATIVE tail.
#   * Per-case environment travels in the case RECORD or in its own phase, never
#     in a bash prefix assignment: a prefix assignment persists in this shell
#     after a FUNCTION call, so by the time the single pwsh runs it would hold
#     only the last value assigned.
#
# CONTROL CHARACTERS AND THE CASE FILE. The case file is TAB-delimited with NINE
# fixed columns and meaningful EMPTY middles, so a value containing a TAB, LF,
# CR or a C0 control travels as an @TOKEN@ that both sides expand identically,
# and the PowerShell reader asserts the FIELD COUNT rather than trusting a split
# that could drop an empty. One limit is stated rather than worked around: a NUL
# byte cannot live in a bash variable at all, so `tr -d '\000-...'`'s NUL arm has
# no differential case here; SOH, VT, FF, US and DEL cover the same code path.
#
# Every path handed to pwsh, INCLUDING the Import-Module paths, goes through
# fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads /tmp/x
# as C:\tmp\x).
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

[ -f "$ROOT/bin/fm-public-followup-lib.psm1" ] || fail "bin/fm-public-followup-lib.psm1 is missing"
[ -f "$ROOT/bin/fm-push-transition-lib.psm1" ] || fail "bin/fm-push-transition-lib.psm1 is missing"

PF_MOD=$(fm_test_native_path "$ROOT/bin/fm-public-followup-lib.psm1")
PT_MOD=$(fm_test_native_path "$ROOT/bin/fm-push-transition-lib.psm1")

TMP_ROOT=$(fm_test_tmproot fm-followup-psm1)

# --- layout -------------------------------------------------------------------
#
# The two worlds need separate STATE directories (each writes its own wake
# queue, triage log and markers) plus SHARED directories for the interop
# sections. Set BEFORE the oracle libraries are sourced, because fm-wake-lib.sh
# and fm-push-transition-lib.sh resolve STATE, FM_WAKE_QUEUE and TRIAGE_LOG at
# SOURCE TIME - exactly as their PowerShell twins resolve them at import time.
B_BASE="$TMP_ROOT/bash"          # bash fixture root
P_BASE="$TMP_ROOT/ps"            # PowerShell fixture root, identical content
B_STATE="$TMP_ROOT/bstate"       # bash push-transition state
P_STATE="$TMP_ROOT/psstate"      # PowerShell push-transition state
SHARED_A="$TMP_ROOT/shared-a"    # bash writes here, PowerShell reads
SHARED_B="$TMP_ROOT/shared-b"    # PowerShell writes here, bash reads
mkdir -p "$B_STATE/q" "$P_STATE/q" "$SHARED_A" "$SHARED_B" "$TMP_ROOT/home"

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$B_STATE"
# The wake queue lives one directory DOWN so the enqueue-failure case can be
# produced honestly - by removing the directory the append target sits in -
# rather than by stubbing fm_wake_append, which would test the stub.
export FM_WAKE_QUEUE="$B_STATE/q/.wake-queue"

# --- the oracles --------------------------------------------------------------
#
# fm-public-followup-lib.sh sources fm-x-lib.sh; fm-push-transition-lib.sh
# sources fm-wake-lib, fm-classify-lib, fm-backend and fm-transition-lib. That
# is the same graph bin/fm-watch.sh loads, so sourcing both together is the
# production shape.
# shellcheck source=bin/fm-public-followup-lib.sh
. "$ROOT/bin/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-push-transition-lib.sh
. "$ROOT/bin/fm-push-transition-lib.sh"

# The library's own wake() does the heartbeat-streak bookkeeping AND exits, so
# it is preserved under a second name before being overridden: the streak cases
# need the real one, and every other case needs it not to end this script.
eval "real_$(declare -f wake)"

WAKE_LOG="$TMP_ROOT/b-wakes"
SLEEP_LOG="$TMP_ROOT/b-sleeps"
: > "$WAKE_LOG"; : > "$SLEEP_LOG"
# Overrides mirroring tests/fm-supervision-events.test.sh - the library's own
# declared test seams.
# shellcheck disable=SC2329  # runtime override called by the isolated owner
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
# shellcheck disable=SC2329  # runtime override called by the isolated owner
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

# The backend commit boundary, overridden on BOTH sides with the same shape so
# the differential covers THIS library's control flow rather than the herdr
# adapter's: what got committed, in what order relative to the durable enqueue,
# and what happens when the commit refuses.
COMMIT_LOG="$TMP_ROOT/b-commits"
: > "$COMMIT_LOG"
COMMIT_RC=0
# shellcheck disable=SC2329  # runtime override called by the isolated owner
fm_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  # $2 is a path and differs between the two worlds, so it is deliberately NOT
  # logged: a path-bearing answer could never match.
  printf '%s|%s|%s\n' "$1" "$3" "${4//$'\t'/|}" >> "$COMMIT_LOG"
  [ "$COMMIT_RC" -eq 0 ] || return 1
  : > "$STATE/.commit-marker"
  return 0
}

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables in the parent shell. Nothing that asserts runs inside a
# `( ... )`, because a subshell cannot report a failure back and a bookkeeping
# scheme that can LOSE a failure is worse than none.
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

# --- token expansion, identical on both sides ---------------------------------
#
# Published through a global rather than stdout so a call site needs no command
# substitution: an MSYS fork costs ~0.36s here and this runs dozens of times.
UNESC=
unesc() {
  local v=$1
  v=${v//@TAB@/$'\t'}
  v=${v//@LF@/$'\n'}
  v=${v//@CR@/$'\r'}
  v=${v//@SOH@/$'\001'}
  v=${v//@VT@/$'\013'}
  v=${v//@FF@/$'\014'}
  v=${v//@US@/$'\037'}
  v=${v//@DEL@/$'\177'}
  v=${v//@SP@/ }
  v=${v//@NBSP@/$'\u00A0'}
  v=${v//@ZWSP@/$'\u200B'}
  v=${v//@EMDASH@/$'\u2014'}
  UNESC=$v
}

# Hex of a value's bytes. Used wherever an answer can carry a control character,
# a trailing space, or a deliberately broken UTF-8 sequence - all three of which
# a plain string comparison would hide.
#
# `od` is the only PROCESS here; the whitespace is stripped with parameter
# expansion rather than a `tr` in the pipeline. That is not micro-tuning: an
# MSYS fork costs ~0.36s on an idle reference host and was measured at ~8s on
# this one under four concurrent agents, and these run ~50 times.
hex() {  # <value>
  local o
  o=$(printf '%s' "$1" | od -An -tx1)
  o=${o// /}
  printf '%s' "${o//$'\n'/}"
}
hexfile() {  # <path>
  local o
  [ -f "$1" ] || { printf '<absent>'; return 0; }
  o=$(od -An -tx1 < "$1")
  o=${o// /}
  printf '%s' "${o//$'\n'/}"
}

# The newline-to-comma join without the process, for the same reason as join_lines above.
join_commas() {  # stdin -> stdout, each line followed by ','
  local line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="$out$line,"
  done
  printf '%s' "$out"
}

# --- the shared fixture, built identically under each base --------------------
#
# Identical CONTENT under two different roots is what makes the answers
# comparable while the paths differ. Nothing here depends on the base's spelling.
build_fixture() {  # <base>
  local base=$1

  mkdir -p "$base/homeon" "$base/homeoff" "$base/homeempty" "$base/homequoted"
  printf 'FMX_PAIRING_TOKEN=tok\n' > "$base/homeon/.env"
  printf 'FMX_PAIRING_TOKEN=\n' > "$base/homeempty/.env"
  printf 'export FMX_PAIRING_TOKEN="  spaced  "\n' > "$base/homequoted/.env"

  mkdir -p "$base/state/public-followup/registry/subdir" \
           "$base/state/public-followup/events" \
           "$base/state/public-followup/consumed" \
           "$base/state/public-followup/rejected" \
           "$base/emptystate"

  # A registration whose values exercise last-wins, an empty value, and a value
  # that itself contains '='.
  printf 'work_home=secondmate:kid\nwork_id=w2\ndup=first\ndup=second\nempty=\neq=a=b\n' \
    > "$base/state/public-followup/registry/pf-a"
  printf 'obligation_id=pf-b\nrelation_id=rel-code\nwork_home=main\nwork_id=w1\ngeneration=1\nplatform=discord\nrequest_id=req-b\n' \
    > "$base/state/public-followup/registry/pf-b"
  printf 'work_home=main\nwork_id=w1\n' > "$base/state/public-followup/registry/pf-c"
  # Neither of these may ever appear in a listing: a bash `*` glob skips the
  # dotfile, and `[ -f ]` skips the directory.
  printf 'hidden\n' > "$base/state/public-followup/registry/.hidden"
  printf 'x\n' > "$base/state/public-followup/registry/subdir/inner"

  printf '{}\n' > "$base/state/public-followup/events/bbb.json"
  printf '{}\n' > "$base/state/public-followup/events/aaa.json"
  printf 'not an event\n' > "$base/state/public-followup/events/notjson.txt"

  mkdir -p "$base/dirs/empty" "$base/dirs/dotonly" "$base/dirs/withfile"
  printf 'k\n' > "$base/dirs/dotonly/.keep"
  printf 'v\n' > "$base/dirs/withfile/x"
  printf 'a file, not a directory\n' > "$base/dirs/afile"

  mkdir -p "$base/status"
  printf 'working: still going\nblocked: needs a credential for the registry\n' > "$base/status/cap.status"
  printf 'working: still going\n' > "$base/status/work.status"
  printf 'paused: waiting on the upstream release\n' > "$base/status/paused.status"
  printf 'done: PR https://example.invalid/pull/1 checks green\n' > "$base/status/done.status"
  : > "$base/status/empty.status"
}
build_fixture "$B_BASE"
build_fixture "$P_BASE"

# --- the case file ------------------------------------------------------------
#
# NINE fixed TAB columns: label, op, then seven arguments. Empty middles are
# deliberate and legitimate.
CASE_BUF=""
case_add() {  # <label> <op> [a1..a7]
  local label=$1 op=$2
  shift 2
  local a1=${1:-} a2=${2:-} a3=${3:-} a4=${4:-} a5=${5:-} a6=${6:-} a7=${7:-}
  CASE_BUF="${CASE_BUF}${label}	${op}	${a1}	${a2}	${a3}	${a4}	${a5}	${a6}	${a7}
"
}

# --- 1. [pf] slug and home-id validation --------------------------------------
#
# These two gates decide whether a value from tasks-axi, the relay, or a child
# home may compose a FILENAME. The traversal case is not hypothetical:
# tests/fm-public-followup.test.sh rewrites a registration to
# work_home=secondmate:../../x and requires delivery to refuse it.
L128=$(printf 'x%.0s' $(seq 1 128))
L129=$(printf 'x%.0s' $(seq 1 129))

SLUG_CASES="ok:a okmixed:a.b_c-d okdigit:0 empty: dot:. dotdot:.. leaddot:.x \
slash:a/b tab:a@TAB@b space:a@SP@b hyphen:a-b plus:a+b colon:secondmate:x \
tilde:a~b emdash:caf@EMDASH@e zwsp:x@ZWSP@y nbsp:a@NBSP@b ctrl:a@SOH@b \
len128:L128 len129:L129"

B_SLUG=""
for spec in $SLUG_CASES; do
  name=${spec%%:*}
  raw=${spec#*:}
  case "$raw" in
    L128) UNESC=$L128 ;;
    L129) UNESC=$L129 ;;
    *) unesc "$raw" ;;
  esac
  if fm_pf_slug_valid "$UNESC"; then B_SLUG="$B_SLUG$name=true "; else B_SLUG="$B_SLUG$name=false "; fi
  case_add "slug.$name" slug "$raw"
done

HOMEID_CASES="main:main sm:secondmate:a smempty:secondmate: smtrav:secondmate:../x \
main2:main2 empty: smcolon:secondmate:a:b smdot:secondmate:.hidden smok:secondmate:fm-dev.1"
B_HOMEID=""
for spec in $HOMEID_CASES; do
  name=${spec%%:*}
  unesc "${spec#*:}"
  if fm_pf_home_id_valid "$UNESC"; then B_HOMEID="$B_HOMEID$name=true "; else B_HOMEID="$B_HOMEID$name=false "; fi
  case_add "homeid.$name" homeid "${spec#*:}"
done

# --- 2. [pf] the derived event identity ---------------------------------------
#
# THE highest-value assertion in this package. The id is a SHA-256 over seven
# US-separated fields with NO trailing newline, and it decides which file on
# disk a terminal result lands in. A bash emitter and a PowerShell emitter that
# disagreed by one byte would each write their own event file for one landed
# outcome, and the thread would get two public replies.
B_EVENTID=""
add_eventid() {  # <name> <7 fields>
  local name=$1 f
  shift
  case_add "eventid.$name" eventid "$@"
  local u=()
  for f in "$@"; do unesc "$f"; u+=("$UNESC"); done
  B_EVENTID="$B_EVENTID$name=$(fm_pf_event_id "${u[0]}" "${u[1]}" "${u[2]}" "${u[3]}" "${u[4]}" "${u[5]}" "${u[6]}") "
}
add_eventid plain pf-1 rel-code main work-1 1 pr-merged '{"pr_url":"https://example.invalid/1"}'
add_eventid secondmate pf-2 rel-code secondmate:kid work-2 3 pr-merged '{}'
add_eventid empties '' '' '' '' '' '' ''
add_eventid unicode pf-3 rel-code main work-3 1 pr-merged '{"note":"caf@EMDASH@@NBSP@"}'
add_eventid embedded pf-4 'rel=code' main 'work@SP@4' 1 'pr-merged' 'a=b@SP@c'
# A field that CONTAINS the separator proves the separator choice matters: if
# both sides used a character that can occur in a field, two different tuples
# could hash the same.
add_eventid unitsep 'pf@US@5' rel main work 1 out deliv

# --- 3. [pf] sha256 -----------------------------------------------------------
B_SHA=""
add_sha() {  # <name> <text>
  local name=$1
  case_add "sha.$name" sha256 "$2"
  unesc "$2"
  B_SHA="$B_SHA$name=$(printf '%s' "$UNESC" | fm_pf_sha256) "
}
add_sha empty ''
add_sha ascii 'the@SP@quick@SP@brown@SP@fox'
add_sha unicode 'caf@EMDASH@@NBSP@tail'
add_sha newline 'a@LF@b@LF@'

# --- 4. [pf] outcome-text cleaning --------------------------------------------
#
# The result becomes a PUBLIC reply, so mangling a character here is visible to
# the world. Answers are compared as HEX because several of these differ only in
# bytes a terminal would not show.
B_CLEAN=""
add_clean() {  # <name> <text>
  local name=$1
  case_add "clean.$name" clean "$2"
  unesc "$2"
  B_CLEAN="$B_CLEAN$name=$(printf '%s' "$UNESC" | fm_pf_clean_outcome_text | od -An -tx1 | tr -d ' \n') "
}
add_clean empty ''
add_clean spacesonly '@SP@@SP@@SP@'
add_clean plain 'a@SP@@SP@b'
add_clean tabs 'a@TAB@b@LF@c@CR@d'
add_clean ctrl '@SOH@x@VT@@FF@y@DEL@z'
add_clean trim '@SP@@SP@padded@SP@@SP@'
add_clean unicode 'Shipped@TAB@the@SP@caf@EMDASH@@SP@fix@LF@second@SP@line'
# The case a "tidier" \s or .Trim() would get WRONG: a NON-BREAKING SPACE is not
# an ASCII space, so LC_ALL=C tr neither squeezes nor trims it.
add_clean nbsp '@NBSP@a@NBSP@@NBSP@b@NBSP@'
add_clean leadtab '@TAB@@TAB@lead'

# --- 5. [pf] byte bounding ----------------------------------------------------
#
# `cut -b` cuts at a BYTE boundary and will halve a multi-byte character; the
# twin must reproduce that, dangling lead byte and all, because those bytes land
# verbatim in rejected/<id>.reason. Hex is the only honest comparison.
B_BOUND=""
add_bound() {  # <name> <max> <text>
  local name=$1
  case_add "bound.$name" bound "$2" "$3"
  unesc "$3"
  B_BOUND="$B_BOUND$name=$(printf '%s' "$UNESC" | fm_pf_bound_bytes "$2" | od -An -tx1 | tr -d ' \n') "
}
add_bound short 4 ab
add_bound exact 4 abcd
add_bound cut 4 abcdefgh
add_bound splitchar 4 'caf@EMDASH@x'
add_bound empty 4 ''
add_bound multiline 3 'abcdef@LF@ghijkl'
add_bound one 1 'abc'

# --- 6. [pf] directory helpers ------------------------------------------------
#
# Keyed by NAME and compared as the tail after each world's own base, because
# the two worlds spell the base differently and a path-keyed probe never matches.
B_DIRS=""
for which in root registry events consumed rejected; do
  case_add "dir.$which" dir "$which"
  case "$which" in
    root) v=$(fm_pf_root "$B_BASE/state") ;;
    registry) v=$(fm_pf_registry_dir "$B_BASE/state") ;;
    events) v=$(fm_pf_events_dir "$B_BASE/state") ;;
    consumed) v=$(fm_pf_consumed_dir "$B_BASE/state") ;;
    rejected) v=$(fm_pf_rejected_dir "$B_BASE/state") ;;
  esac
  B_DIRS="$B_DIRS$which=${v#"$B_BASE"} "
done

# --- 7. [pf] directory presence gates -----------------------------------------
B_DIRENTRY=""
add_direntry() {  # <name> <relpath>
  local name=$1 rel=$2
  case_add "direntry.$name" direntry "$rel"
  if fm_pf_dir_has_entry "$B_BASE$rel"; then B_DIRENTRY="$B_DIRENTRY$name=true "; else B_DIRENTRY="$B_DIRENTRY$name=false "; fi
}
add_direntry empty /dirs/empty
add_direntry dotonly /dirs/dotonly
add_direntry withfile /dirs/withfile
add_direntry missing /dirs/nope
add_direntry afile /dirs/afile
add_direntry registry /state/public-followup/registry

# --- 8. [pf] the two-gate activation contract ---------------------------------
#
# The hard acceptance criterion for a relay-disabled home is that it pays
# nothing, and the ORDER of the gates is what delivers it.
B_GATE=""
add_gate() {  # <name> <home-rel> <state-rel>
  local name=$1 hrel=$2 srel=$3 r a e
  case_add "gate.$name" gate "$hrel" "$srel"
  if fm_pf_has_registrations "$B_BASE$srel"; then r=true; else r=false; fi
  if fm_pf_has_events "$B_BASE$srel"; then e=true; else e=false; fi
  if fm_pf_active "$B_BASE$hrel" "$B_BASE$srel"; then a=true; else a=false; fi
  B_GATE="$B_GATE$name=$r/$e/$a "
}
add_gate on /homeon /state
add_gate off /homeoff /state
add_gate onempty /homeon /emptystate
add_gate offempty /homeoff /emptystate

# --- 9. [pf] registry reads ---------------------------------------------------
B_REGGET=""
add_regget() {  # <name> <id> <key>
  local name=$1 id=$2 key=$3 out rc
  case_add "regget.$name" regget "$id" "$key"
  out=$(fm_pf_registry_get "$B_BASE/state" "$id" "$key"); rc=$?
  # rc 1 is the REFUSAL (an unsafe id); rc 0 with empty output is "no such
  # record or key". The PowerShell twin carries that distinction as $null vs '',
  # so it is carried here too rather than flattened.
  [ "$rc" -eq 0 ] || out='<null>'
  B_REGGET="$B_REGGET$name=[$out] "
}
add_regget present pf-b work_home
add_regget lastwins pf-a dup
add_regget emptyval pf-a empty
add_regget equals pf-a eq
add_regget nokey pf-a nosuch
add_regget norecord pf-zzz work_home
add_regget unsafeid ../evil work_home
add_regget dotid .hidden work_home

B_REGIDS=$(fm_pf_registry_ids "$B_BASE/state" | join_commas)
case_add regids regids
B_REGIDS_EMPTYSTATE=$(fm_pf_registry_ids "$B_BASE/emptystate" | join_commas)
case_add regids.emptystate regids.emptystate
B_REGIDS_MAIN=$(fm_pf_registry_ids_for_work "$B_BASE/state" main w1 | join_commas)
case_add regidswork.main regidswork main w1
B_REGIDS_KID=$(fm_pf_registry_ids_for_work "$B_BASE/state" secondmate:kid w2 | join_commas)
case_add regidswork.kid regidswork secondmate:kid w2
B_REGIDS_NONE=$(fm_pf_registry_ids_for_work "$B_BASE/state" main nope | join_commas)
case_add regidswork.none regidswork main nope

# --- 10. [pf] the pending-event signature -------------------------------------
#
# The relay poll wakes ONCE per new event set, and that promise is exactly this
# digest. `notjson.txt` must not be in it, and the order must come from the sort
# rather than from the directory.
B_EVSIG=$(fm_pf_events_signature "$B_BASE/state") || B_EVSIG='<null>'
case_add evsig evsig
B_EVSIG_EMPTY=$(fm_pf_events_signature "$B_BASE/emptystate") || B_EVSIG_EMPTY='<null>'
case_add evsig.empty evsig.empty
# Asserted against a hand-built value too, so a shared bug in BOTH
# implementations cannot pass as agreement.
B_EVSIG_HAND=$(printf 'aaa.json\nbbb.json\n' | fm_pf_sha256)

# --- 11. [pf] constants -------------------------------------------------------
B_CONST="dirname=$FM_PF_DIRNAME schema=$FM_PF_EVENT_SCHEMA_VERSION outmax=$FM_PF_OUTCOME_TEXT_MAX bytesmax=$FM_PF_EVENT_BYTES_MAX surfaced=$FM_PF_SURFACED_BASENAME"
case_add const const

# --- 12. [pf] relay activation (phase 1 arm: the token is UNSET) --------------
for which in on off empty quoted; do
  case_add "relay.$which" relay "/home$which"
done

# --- 13. [push] path and record shapes ----------------------------------------
B_SURFPATH=""
add_surfpath() {  # <name> <task>
  local name=$1 v
  case_add "surfpath.$name" surfpath "$2"
  unesc "$2"
  v=$(_hb_surfaced_path "$UNESC")
  B_SURFPATH="$B_SURFPATH$name=${v#"$B_STATE"} "
}
add_surfpath plain tk1
add_surfpath window default:wG:pQ
add_surfpath dotted mate.id
add_surfpath slash a/b
add_surfpath empty ''

# The five-field record with an EMPTY MIDDLE FIELD, built by each world and
# compared as hex; the PowerShell side also asserts the field COUNT.
BASH_RECORD=$(fm_transition_record 'wG:pQ' 'wG' '' 'blocked' 'claude')
B_RECORD=$(hex "$BASH_RECORD")
case_add record record
# A record BUILT BY BASH, parsed by PowerShell: cross-world interop for exactly
# the shape docs/powershell-port.md warns about.
case_add parserec parserec "$(printf '%s' "$BASH_RECORD" | sed 's/\t/@TAB@/g')"

B_TRIAGECAP=$TRIAGE_LOG_MAX_BYTES
case_add triagecap triagecap

# --- 14. [push] heartbeat streak ----------------------------------------------
STREAK_FILE="$B_STATE/.heartbeat-streak"
B_STREAK=""
add_streak() {  # <name> <reason> <seed|@NONE@>
  local name=$1 reason=$2 seed=$3 s=''
  case_add "streak.$name" streak "$reason" "$seed"
  if [ "$seed" = '@NONE@' ]; then rm -f "$STREAK_FILE"; else printf '%s\n' "$seed" > "$STREAK_FILE"; fi
  unesc "$reason"
  # The REAL wake, which exits 0 - so it runs in a subshell whose only purpose
  # is to survive that exit. The file it writes is the answer, read below in
  # the parent.
  ( real_wake "$UNESC" ) >/dev/null 2>&1
  [ -f "$STREAK_FILE" ] && IFS= read -r s < "$STREAK_FILE"
  B_STREAK="$B_STREAK$name=$s "
}
add_streak fresh heartbeat @NONE@
add_streak grow heartbeat 4
add_streak prefix 'heartbeat@SP@extra' 7
add_streak reset 'stale:@SP@default:wG:pQ' 9
add_streak garbage heartbeat abc

# --- 15. [push] surfaced markers ----------------------------------------------
B_SETSURF=""
add_setsurf() {  # <name> <status-rel>
  local name=$1 rel=$2 task marker
  case_add "setsurf.$name" setsurf "$rel"
  task=${rel##*/}; task=${task%.status}
  marker=$(_hb_surfaced_path "$task")
  rm -f "$marker"
  mark_surfaced "$B_BASE$rel"
  B_SETSURF="$B_SETSURF$name=$(hexfile "$marker") "
}
add_setsurf captain /status/cap.status
add_setsurf terminal /status/done.status
add_setsurf working /status/work.status
add_setsurf paused /status/paused.status
add_setsurf empty /status/empty.status

# --- 16. [push] the transition handler ----------------------------------------
#
# Each scenario resets the world, drives one transition, and reports a composite
# answer: return code, what the durable queue got, what the commit boundary saw,
# whether the dedupe marker exists, what was waked, what was slept, what was
# absorbed, and what was marked surfaced.
#
# The bash `exit 1` paths run inside a command substitution so this shell
# survives; every ASSERTION on the captured value happens in the parent, which
# is the rule that keeps a failure from vanishing.
push_reset() {  # <status-line|@NONE@> [queue-dir-present:0|1]
  rm -f "$B_STATE"/*.meta "$B_STATE"/*.status "$B_STATE/.commit-marker" \
        "$B_STATE/q/.wake-queue" "$B_STATE/.wake-queue.seq" "$B_STATE/.watch-triage.log" \
        "$B_STATE"/.hb-surfaced-* 2>/dev/null
  rm -rf "$B_STATE/.wake-queue.lock" 2>/dev/null
  : > "$WAKE_LOG"; : > "$SLEEP_LOG"; : > "$COMMIT_LOG"
  fm_write_meta "$B_STATE/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
  [ "$1" = '@NONE@' ] || printf '%s\n' "$1" > "$B_STATE/tk1.status"
  if [ "${2:-1}" = 1 ]; then mkdir -p "$B_STATE/q"; else rm -rf "$B_STATE/q"; fi
}
# Assembled entirely with `read` and parameter expansion - no cut, sed or tr.
# Seven scenarios times eight fields is over fifty forks in the obvious
# spelling, and a fork costs seconds on a loaded host here.
join_lines() {  # <path> -> stdout, each line followed by ';'
  local line out=''
  [ -f "$1" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="$out$line;"
  done < "$1"
  printf '%s' "$out"
}
push_answer() {  # <rc>
  local q='' t='' line rest
  # Fields 3..5 of the durable record (kind, key, payload). The epoch and the
  # sequence number are deliberately excluded: they are wall clock and per-run
  # state, and asserting on them across two snapshots minutes apart would be a
  # flaky test rather than a differential one.
  if [ -f "$B_STATE/q/.wake-queue" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      rest=${line#*$'\t'}      # drop the epoch
      rest=${rest#*$'\t'}      # drop the sequence number
      q="$q${rest//$'\t'/|};"
    done < "$B_STATE/q/.wake-queue"
  fi
  if [ -f "$B_STATE/.watch-triage.log" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      t="$t${line#*\] };"      # drop the "[<timestamp>] " prefix
    done < "$B_STATE/.watch-triage.log"
  fi
  local marker=no surfaced=no
  [ -e "$B_STATE/.commit-marker" ] && marker=yes
  [ -e "$B_STATE/.hb-surfaced-tk1" ] && surfaced=$(hexfile "$B_STATE/.hb-surfaced-tk1")
  printf 'rc=%s queue=%s commit=%s marker=%s wake=%s sleep=%s triage=%s surfaced=%s' \
    "$1" "$q" "$(join_lines "$COMMIT_LOG")" "$marker" \
    "$(join_lines "$WAKE_LOG")" "$(join_lines "$SLEEP_LOG")" "$t" "$surfaced"
}

REC_BLOCKED=$BASH_RECORD
REC_NOPANE=$(fm_transition_record '' 'wG' '' 'blocked' 'claude')

case_add push.blocked push.blocked
push_reset '@NONE@'
handle_push_transition herdr default "$REC_BLOCKED"; rc=$?
B_PUSH_BLOCKED=$(push_answer "$rc")

case_add push.paused push.paused
push_reset 'paused: waiting on the upstream release'
handle_push_transition herdr default "$REC_BLOCKED"; rc=$?
B_PUSH_PAUSED=$(push_answer "$rc")

case_add push.surfaced push.surfaced
push_reset 'blocked: needs a credential for the registry'
handle_push_transition herdr default "$REC_BLOCKED"; rc=$?
B_PUSH_SURFACED=$(push_answer "$rc")

case_add push.nopane push.nopane
push_reset '@NONE@'
handle_push_transition herdr default "$REC_NOPANE"; rc=$?
B_PUSH_NOPANE=$(push_answer "$rc")

# The commit refuses. handle_push_transition exits 1, so it runs inside a
# command substitution; the assertion is made in the parent from the value.
case_add push.commitfail push.commitfail
push_reset '@NONE@'
COMMIT_RC=1
rc=$( (handle_push_transition herdr default "$REC_BLOCKED" >/dev/null 2>&1); printf '%s' "$?" )
B_PUSH_COMMITFAIL=$(push_answer "$rc")
COMMIT_RC=0

# The durable enqueue fails because its target directory is gone. The contract
# tests/fm-supervision-events.test.sh pins: a failed enqueue must NOT commit, so
# the blocked edge stays eligible for reconnect reconciliation.
case_add push.enqueuefail push.enqueuefail
push_reset '@NONE@' 0
rc=$( (handle_push_transition herdr default "$REC_BLOCKED" >/dev/null 2>&1); printf '%s' "$?" )
B_PUSH_ENQUEUEFAIL=$(push_answer "$rc")
mkdir -p "$B_STATE/q"

push_reset '@NONE@'

# The DECLARED fm-backend edge, asserted in each world's own idiom. bash gets
# fm_backend_commit_transition purely by sourcing fm-push-transition-lib.sh;
# PowerShell gets Save-FmBackendTransition purely by importing
# fm-push-transition-lib.psm1. Probed in a FRESH subshell that sources nothing
# else, because this test shell has since overridden the function and would
# report `command -v` true either way - which would assert nothing.
B_BACKEND_EDGE=$(
  env -u FM_WAKE_QUEUE FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT/home" \
      FM_STATE_OVERRIDE="$TMP_ROOT/edgeprobe" bash -c '
        . "$FM_ROOT_OVERRIDE/bin/fm-push-transition-lib.sh" >/dev/null 2>&1
        if command -v fm_backend_commit_transition >/dev/null 2>&1; then
          printf resolved
        else
          printf missing
        fi'
)

# --- 17. [pf] cross-world interop, direction A: bash writes -------------------
#
# The exact bytes bin/fm-public-followup.sh's `register` publishes.
mkdir -p "$SHARED_A/public-followup/registry" "$SHARED_A/public-followup/events"
printf 'obligation_id=%s\nrelation_id=%s\nwork_home=%s\nwork_id=%s\ngeneration=%s\nplatform=%s\nrequest_id=%s\n' \
  pf-shared rel-code secondmate:kid work-shared 2 discord req-shared \
  > "$SHARED_A/public-followup/registry/pf-shared"
IOP_A_HEX=$(hexfile "$SHARED_A/public-followup/registry/pf-shared")
IOP_A_READ=""
for k in obligation_id relation_id work_home work_id generation platform request_id; do
  IOP_A_READ="$IOP_A_READ$k=$(fm_pf_registry_get "$SHARED_A" pf-shared "$k") "
done
IOP_A_IDS=$(fm_pf_registry_ids "$SHARED_A" | join_commas)
IOP_A_FORWORK=$(fm_pf_registry_ids_for_work "$SHARED_A" secondmate:kid work-shared | join_commas)
# A terminal event whose FILE NAME is the bash-derived id.
IOP_DELIVERABLES='{"pr_url":"https://example.invalid/9"}'
IOP_A_EVENTID=$(fm_pf_event_id pf-shared rel-code secondmate:kid work-shared 2 pr-merged "$IOP_DELIVERABLES")
printf '{}\n' > "$SHARED_A/public-followup/events/$IOP_A_EVENTID.json"
IOP_A_SIG=$(fm_pf_events_signature "$SHARED_A")
printf '%s' "$IOP_A_SIG" > "$SHARED_A/public-followup/surfaced"

# --- the PowerShell side, in ONE process per environment ----------------------
QUERY="$TMP_ROOT/query.ps1"
cat > "$QUERY" <<'PS1'
#Requires -Version 7.0
# The PowerShell half of tests/fm-followup-psm1.test.sh.
#
# Reads a case FILE (never argv: PowerShell re-splits a -File script argument on
# spaces, and a repo or temp path containing one would break the same way), and
# prints one "<label><TAB><answer>" line per answer. The bash driver joins the
# two answer sets BY LABEL - never by a path, which the two worlds spell
# differently.
#
# Header lines: 1 = fm-public-followup-lib.psm1, 2 = fm-push-transition-lib.psm1,
# 3 = the fixture base, 4 = the push-transition state dir, 5 = shared-A (bash
# wrote it), 6 = shared-B (this process writes it). Case lines follow.
param([Parameter(Mandatory)][string]$CaseFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines     = @([System.IO.File]::ReadAllLines($CaseFile))
$PfModule  = $lines[0]
$PtModule  = $lines[1]
$Base      = $lines[2]
$PushState = $lines[3]
$SharedA   = $lines[4]
$SharedB   = $lines[5]
$Cases     = @($lines | Select-Object -Skip 6 | Where-Object { $_ -ne '' })

# Dependency order, and NO -Force: this is a fresh process every run, and a
# -Force on a nested module would remove the instance the other modules bound
# to. fm-common is imported explicitly because a module's own imports land in
# ITS session state, not in this script's.
$BinDir = Split-Path -Parent $PfModule
Import-Module (Join-Path $BinDir 'fm-common.psm1')
Import-Module (Join-Path $BinDir 'fm-transition-lib.psm1')
Import-Module $PfModule
Import-Module $PtModule
# This script uses fm-common's own commands (ConvertTo-FmNativePath and
# Set-FmFileText, in the interop section), so it claims them LAST - after every
# module that might nest-import fm-common. That ordering makes the script's
# binding the surviving one no matter what flags a nested import uses, which is
# the difference between a readable failure and a CommandNotFoundException
# thousands of lines from its cause. It is not decoration: a nested
# `Import-Module -Force` REMOVES the loaded instance globally, and this suite
# found exactly that live in the tree (fixed since, and now a rule in
# docs/powershell-port.md - "Never -Force a NESTED module import"). Modules keep
# working through it because their bindings live in their own session states;
# only a script loses its commands, which is why an entrypoint is where it bites.
Import-Module (Join-Path $BinDir 'fm-common.psm1') -Global

$Utf8 = [System.Text.UTF8Encoding]::new($false, $false)

function Write-Record {
    param([Parameter(Mandatory)][string]$Key, [Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { $Value = '<null>' }
    $text = ([string]$Value) -replace "`t", ' '
    [Console]::Out.Write($Key + "`t" + $text + "`n")
}

function Expand-Token {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text
    $t = $t.Replace('@TAB@', "`t").Replace('@LF@', "`n").Replace('@CR@', "`r")
    $t = $t.Replace('@SOH@',    [string][char]0x01)
    $t = $t.Replace('@VT@',     [string][char]0x0B)
    $t = $t.Replace('@FF@',     [string][char]0x0C)
    $t = $t.Replace('@US@',     [string][char]0x1F)
    $t = $t.Replace('@DEL@',    [string][char]0x7F)
    $t = $t.Replace('@SP@',     ' ')
    $t = $t.Replace('@NBSP@',   [string][char]0x00A0)
    $t = $t.Replace('@ZWSP@',   [string][char]0x200B)
    $t = $t.Replace('@EMDASH@', [string][char]0x2014)
    return $t
}

function ConvertTo-Hex {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}
function ConvertTo-HexText {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return (ConvertTo-Hex $Utf8.GetBytes($Text))
}
function ConvertTo-HexFile {
    param([Parameter(Position = 0)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return '<absent>' }
    return (ConvertTo-Hex ([System.IO.File]::ReadAllBytes($Path)))
}
function Get-Tail {
    # The two worlds spell the base differently; only the tail is comparable.
    # Both spellings are normalized to '/' so a Windows base cannot leak a
    # backslash into an answer the bash side produced with forward slashes.
    param([Parameter(Position = 0)][string]$Value, [Parameter(Position = 1)][string]$Prefix)
    $v = $Value -replace '\\', '/'
    $p = ($Prefix -replace '\\', '/').TrimEnd('/')
    if ($v.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $v.Substring($p.Length)
    }
    return $v
}
function Join-List {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Items)
    if ($null -eq $Items -or $Items.Count -eq 0) { return '' }
    return (($Items -join ',') + ',')
}

# --- the fm-backend commit boundary, stubbed exactly as the bash side stubs it -
#
# bin/fm-push-transition-lib.psm1 IMPORTS fm-backend.psm1, because the bash twin
# SOURCES fm-backend.sh - a declared edge, not the R4 undeclared class. An
# imported module command cannot be shadowed by redefining it out here, which is
# why the module exposes -CommitAction and this passes a recorder through it.
# The bash side gets the same seam by redefining the shell function, so both
# worlds are stubbed identically and the differential stays about THIS file
# rather than about the herdr adapter.
$script:CommitLog = [System.Collections.Generic.List[string]]::new()
$script:CommitOk = $true
$CommitAction = {
    param($Backend, $State, $Session, $Record)
    # $State is a path and differs between the worlds, so it is not logged.
    $script:CommitLog.Add(("{0}|{1}|{2}" -f $Backend, $Session, ([string]$Record -replace "`t", '|')))
    if (-not $script:CommitOk) { return $false }
    [System.IO.File]::WriteAllText((Join-Path $PushState '.commit-marker'), '')
    return $true
}

# --- push-transition scenario plumbing ---------------------------------------
$script:WakeLog = [System.Collections.Generic.List[string]]::new()
$script:SleepLog = [System.Collections.Generic.List[string]]::new()
$WakeAction = { param($Reason) $script:WakeLog.Add([string]$Reason) }
$SleepAction = { $script:SleepLog.Add('SLEEP') }

function Reset-PushWorld {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$StatusLine,
          [Parameter(Position = 1)][bool]$QueueDir = $true)
    foreach ($pattern in @('*.meta', '*.status', '.commit-marker', '.wake-queue.seq',
                           '.watch-triage.log', '.hb-surfaced-*')) {
        foreach ($f in @(Get-ChildItem -LiteralPath $PushState -Filter $pattern -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath (Join-Path $PushState '.wake-queue.lock') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $PushState 'q') -Recurse -Force -ErrorAction SilentlyContinue
    if ($QueueDir) { [void][System.IO.Directory]::CreateDirectory((Join-Path $PushState 'q')) }
    $script:WakeLog.Clear(); $script:SleepLog.Clear(); $script:CommitLog.Clear()
    [System.IO.File]::WriteAllText((Join-Path $PushState 'tk1.meta'),
        "window=default:wG:pQ`nbackend=herdr`nkind=ship`n")
    if ($StatusLine -ne '@NONE@') {
        [System.IO.File]::WriteAllText((Join-Path $PushState 'tk1.status'), $StatusLine + "`n")
    }
}

function Get-PushAnswer {
    param([Parameter(Position = 0)][int]$ReturnCode)
    $queuePath = Join-Path (Join-Path $PushState 'q') '.wake-queue'
    $queue = ''
    if ([System.IO.File]::Exists($queuePath)) {
        $rows = @()
        foreach ($line in ([System.IO.File]::ReadAllText($queuePath) -split "`n")) {
            if ($line -eq '') { continue }
            # .Split on the RAW string, and the FIELD COUNT is asserted: a regex
            # split would silently drop the empty middles this format allows.
            $f = @($line.Split("`t"))
            if ($f.Count -ne 5) { $rows += "BADFIELDS:$($f.Count)"; continue }
            $rows += ($f[2] + '|' + $f[3] + '|' + $f[4])
        }
        if ($rows.Count -gt 0) { $queue = ($rows -join ';') + ';' }
    }
    $triagePath = Join-Path $PushState '.watch-triage.log'
    $triage = ''
    if ([System.IO.File]::Exists($triagePath)) {
        $msgs = @()
        foreach ($line in ([System.IO.File]::ReadAllText($triagePath) -split "`n")) {
            if ($line -eq '') { continue }
            $msgs += ($line -replace '^\[[^\]]*\] ', '')
        }
        if ($msgs.Count -gt 0) { $triage = ($msgs -join ';') + ';' }
    }
    $commit = ''
    if ($script:CommitLog.Count -gt 0) { $commit = ($script:CommitLog -join ';') + ';' }
    $wake = ''
    if ($script:WakeLog.Count -gt 0) { $wake = ($script:WakeLog -join ';') + ';' }
    $slept = ''
    if ($script:SleepLog.Count -gt 0) { $slept = ($script:SleepLog -join ';') + ';' }
    $marker = if ([System.IO.File]::Exists((Join-Path $PushState '.commit-marker'))) { 'yes' } else { 'no' }
    $surfacedPath = Join-Path $PushState '.hb-surfaced-tk1'
    $surfaced = if ([System.IO.File]::Exists($surfacedPath)) { ConvertTo-HexFile $surfacedPath } else { 'no' }
    return ('rc={0} queue={1} commit={2} marker={3} wake={4} sleep={5} triage={6} surfaced={7}' -f
        $ReturnCode, $queue, $commit, $marker, $wake, $slept, $triage, $surfaced)
}

$RecBlocked = New-FmTransitionRecord 'wG:pQ' 'wG' '' 'blocked' 'claude'
$RecNoPane  = New-FmTransitionRecord '' 'wG' '' 'blocked' 'claude'

# --- dispatch ----------------------------------------------------------------
$slugAcc = ''; $homeAcc = ''; $eventAcc = ''; $shaAcc = ''; $cleanAcc = ''
$boundAcc = ''; $dirAcc = ''; $direntryAcc = ''; $gateAcc = ''; $reggetAcc = ''
$surfpathAcc = ''; $streakAcc = ''; $setsurfAcc = ''

foreach ($case in $Cases) {
    $f = @($case.Split("`t"))
    if ($f.Count -ne 9) {
        Write-Record -Key 'FATAL.fieldcount' -Value "$($f.Count) in [$case]"
        continue
    }
    $label = $f[0]
    $op = $f[1]
    $a = @(1..7 | ForEach-Object { Expand-Token $f[$_ + 1] })
    $name = $label.Substring($label.IndexOf('.') + 1)

    try {
        switch ($op) {
            'slug' {
                # The two length cases carry a NAME rather than 128 literal
                # characters, so the case file stays readable.
                $v = if ($f[2] -eq 'L128') { 'x' * 128 } elseif ($f[2] -eq 'L129') { 'x' * 129 } else { $a[0] }
                $slugAcc += "$name=$((Test-FmPfSlug $v).ToString().ToLowerInvariant()) "
            }
            'homeid'  { $homeAcc  += "$name=$((Test-FmPfHomeId $a[0]).ToString().ToLowerInvariant()) " }
            'eventid' { $eventAcc += "$name=$(Get-FmPfEventId $a[0] $a[1] $a[2] $a[3] $a[4] $a[5] $a[6]) " }
            'sha256'  { $shaAcc   += "$name=$(Get-FmPfSha256 -Text $a[0]) " }
            'clean'   { $cleanAcc += "$name=$(ConvertTo-HexText (Get-FmPfCleanOutcomeText $a[0])) " }
            'bound'   { $boundAcc += "$name=$(ConvertTo-Hex (Get-FmPfBoundByte ([int]$a[0]) $a[1])) " }
            'dir' {
                $state = Join-Path $Base 'state'
                $v = switch ($a[0]) {
                    'root'     { Get-FmPfRoot $state }
                    'registry' { Get-FmPfRegistryDir $state }
                    'events'   { Get-FmPfEventsDir $state }
                    'consumed' { Get-FmPfConsumedDir $state }
                    'rejected' { Get-FmPfRejectedDir $state }
                }
                $dirAcc += "$($a[0])=$(Get-Tail $v $Base) "
            }
            'direntry' {
                $direntryAcc += "$name=$((Test-FmPfDirHasEntry ($Base + $a[0])).ToString().ToLowerInvariant()) "
            }
            'gate' {
                $h = $Base + $a[0]
                $s = $Base + $a[1]
                $r   = (Test-FmPfHasRegistration $s).ToString().ToLowerInvariant()
                $e   = (Test-FmPfHasEvent $s).ToString().ToLowerInvariant()
                $act = (Test-FmPfActive $h $s).ToString().ToLowerInvariant()
                $gateAcc += "$name=$r/$e/$act "
            }
            'regget' {
                $v = Get-FmPfRegistryValue (Join-Path $Base 'state') $a[0] $a[1]
                if ($null -eq $v) { $v = '<null>' }
                $reggetAcc += "$name=[$v] "
            }
            'regids' {
                Write-Record -Key 'regids' -Value (Join-List @(Get-FmPfRegistryId (Join-Path $Base 'state')))
            }
            'regids.emptystate' {
                Write-Record -Key 'regids.emptystate' -Value (Join-List @(Get-FmPfRegistryId (Join-Path $Base 'emptystate')))
            }
            'regidswork' {
                Write-Record -Key $label -Value (Join-List @(Get-FmPfRegistryIdForWork (Join-Path $Base 'state') $a[0] $a[1]))
            }
            'evsig'       { Write-Record -Key 'evsig'       -Value (Get-FmPfEventsSignature (Join-Path $Base 'state')) }
            'evsig.empty' { Write-Record -Key 'evsig.empty' -Value (Get-FmPfEventsSignature (Join-Path $Base 'emptystate')) }
            'const' {
                Write-Record -Key 'const' -Value ("dirname={0} schema={1} outmax={2} bytesmax={3} surfaced={4}" -f
                    (Get-FmPfDirName), (Get-FmPfEventSchemaVersion), (Get-FmPfOutcomeTextMax),
                    (Get-FmPfEventByteMax), (Get-FmPfSurfacedBaseName))
            }
            'relay' {
                Write-Record -Key $label -Value ((Test-FmPfRelayActive ($Base + $a[0])).ToString().ToLowerInvariant())
            }
            'surfpath' {
                $surfpathAcc += "$name=$(Get-Tail (Get-FmPushSurfacedPath -Task $a[0] -State $PushState) $PushState) "
            }
            'record' { Write-Record -Key 'record' -Value (ConvertTo-HexText $RecBlocked) }
            'parserec' {
                # A record BUILT BY BASH, parsed here: the field count first,
                # then the two fields the handler actually reads.
                $rec = $a[0]
                $fields = @($rec.Split("`t"))
                Write-Record -Key 'parserec' -Value ("n={0} pane={1} to={2}" -f $fields.Count,
                    (Get-FmTransitionPaneId -Record $rec), (Get-FmTransitionToStatus -Record $rec))
            }
            'triagecap' { Write-Record -Key 'triagecap' -Value (Get-FmPushTriageLogSizeCap) }
            'streak' {
                $streakFile = Join-Path $PushState '.heartbeat-streak'
                if ($a[1] -eq '@NONE@') {
                    Remove-Item -LiteralPath $streakFile -Force -ErrorAction SilentlyContinue
                } else {
                    [System.IO.File]::WriteAllText($streakFile, $a[1] + "`n")
                }
                # Invoke-FmPushWake prints the reason through [Console]::Out,
                # which is this script's ANSWER STREAM, so the console writer is
                # swapped for the duration rather than redirected with a
                # PowerShell stream operator (which cannot see a direct
                # Console write at all).
                $prevOut = [Console]::Out
                $sink = [System.IO.StringWriter]::new()
                [Console]::SetOut($sink)
                try { Invoke-FmPushWake -Reason $a[0] -State $PushState -NoExit }
                finally { [Console]::SetOut($prevOut) }
                $streakAcc += "$name=$(([System.IO.File]::ReadAllText($streakFile)) -replace "`n", '') "
            }
            'setsurf' {
                $statusPath = $Base + $a[0]
                $task = [System.IO.Path]::GetFileName($a[0])
                if ($task.EndsWith('.status')) { $task = $task.Substring(0, $task.Length - 7) }
                $marker = Get-FmPushSurfacedPath -Task $task -State $PushState
                Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
                [void](Set-FmPushSurfaced -StatusPath $statusPath -State $PushState)
                $setsurfAcc += "$name=$(ConvertTo-HexFile $marker) "
            }
            'push.blocked' {
                Reset-PushWorld '@NONE@'
                $rc = Invoke-FmPushTransition herdr default $RecBlocked $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                Write-Record -Key 'push.blocked' -Value (Get-PushAnswer $rc)
            }
            'push.paused' {
                Reset-PushWorld 'paused: waiting on the upstream release'
                $rc = Invoke-FmPushTransition herdr default $RecBlocked $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                Write-Record -Key 'push.paused' -Value (Get-PushAnswer $rc)
            }
            'push.surfaced' {
                Reset-PushWorld 'blocked: needs a credential for the registry'
                $rc = Invoke-FmPushTransition herdr default $RecBlocked $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                Write-Record -Key 'push.surfaced' -Value (Get-PushAnswer $rc)
            }
            'push.nopane' {
                Reset-PushWorld '@NONE@'
                $rc = Invoke-FmPushTransition herdr default $RecNoPane $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                Write-Record -Key 'push.nopane' -Value (Get-PushAnswer $rc)
            }
            'push.commitfail' {
                Reset-PushWorld '@NONE@'
                $script:CommitOk = $false
                $rc = Invoke-FmPushTransition herdr default $RecBlocked $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                $script:CommitOk = $true
                Write-Record -Key 'push.commitfail' -Value (Get-PushAnswer $rc)
            }
            'push.enqueuefail' {
                Reset-PushWorld '@NONE@' $false
                $rc = Invoke-FmPushTransition herdr default $RecBlocked $PushState -WakeAction $WakeAction -SleepAction $SleepAction -CommitAction $CommitAction
                $answer = Get-PushAnswer $rc
                [void][System.IO.Directory]::CreateDirectory((Join-Path $PushState 'q'))
                Write-Record -Key 'push.enqueuefail' -Value $answer
            }
            default { Write-Record -Key "FATAL.$label" -Value "unknown op [$op]" }
        }
    } catch {
        Write-Record -Key "$label.error" -Value $_.Exception.Message
    }
}

if ($slugAcc)     { Write-Record -Key 'slug'     -Value $slugAcc }
if ($homeAcc)     { Write-Record -Key 'homeid'   -Value $homeAcc }
if ($eventAcc)    { Write-Record -Key 'eventid'  -Value $eventAcc }
if ($shaAcc)      { Write-Record -Key 'sha'      -Value $shaAcc }
if ($cleanAcc)    { Write-Record -Key 'clean'    -Value $cleanAcc }
if ($boundAcc)    { Write-Record -Key 'bound'    -Value $boundAcc }
if ($dirAcc)      { Write-Record -Key 'dir'      -Value $dirAcc }
if ($direntryAcc) { Write-Record -Key 'direntry' -Value $direntryAcc }
if ($gateAcc)     { Write-Record -Key 'gate'     -Value $gateAcc }
if ($reggetAcc)   { Write-Record -Key 'regget'   -Value $reggetAcc }
if ($surfpathAcc) { Write-Record -Key 'surfpath' -Value $surfpathAcc }
if ($streakAcc)   { Write-Record -Key 'streak'   -Value $streakAcc }
if ($setsurfAcc)  { Write-Record -Key 'setsurf'  -Value $setsurfAcc }

# --- the fm-backend seam, asserted directly ----------------------------------
if ($Cases -match '^push\.') {
    # The declared edge: Save-FmBackendTransition must be reachable FROM INSIDE
    # the module, purely because the module imports fm-backend.psm1 - nothing in
    # this script imports it.
    #
    # The probe runs INSIDE the module's session state, because a nested
    # Import-Module publishes THERE and not into the caller. Verified on this
    # host: after importing only fm-push-transition-lib.psm1, session-scope
    # Get-Command reports Save-FmBackendTransition False, Get-FmMetaValue False,
    # and fm-backend does not even appear in Get-Module - while the same probe
    # inside the module reports True. A session-scope check would therefore
    # report "missing" no matter what, which is the mirror image of the trap
    # below.
    #
    # Calling through Invoke-FmPushCommitTransition instead would be a check that
    # CANNOT FAIL. The module deliberately catches CommandNotFoundException, logs
    # the bash twin's diagnostic and returns $false - correct and faithful, since
    # bash prints "command not found", returns 127 and fires the same `|| exit 1`
    # - so a DROPPED IMPORT is indistinguishable from an ordinary refusal.
    # Verified directly: driving that catch with a thrown
    # CommandNotFoundException returns $false and does not rethrow.
    $mod = Get-Module fm-push-transition-lib
    $edge = 'missing'
    if ($null -ne $mod -and (& $mod { $null -ne (Get-Command Save-FmBackendTransition -ErrorAction SilentlyContinue) })) {
        $edge = 'resolved'
    }
    Write-Record -Key 'seam.edge' -Value $edge
    # A NEGATIVE CONTROL on the same probe, in the same scope: an edge check on a
    # path whose job is not to drop a human-waiting agent has to be shown capable
    # of reporting failure, not merely observed passing.
    $neg = 'missing'
    if ($null -ne $mod -and (& $mod { $null -ne (Get-Command Save-FmBackendTransitionXYZ -ErrorAction SilentlyContinue) })) {
        $neg = 'resolved'
    }
    Write-Record -Key 'seam.edge.negative' -Value $neg
    Write-Record -Key 'seam.results' -Value (
        "true=$((Test-FmPushBackendResult $true).ToString().ToLowerInvariant()) " +
        "false=$((Test-FmPushBackendResult $false).ToString().ToLowerInvariant()) " +
        "zero=$((Test-FmPushBackendResult 0).ToString().ToLowerInvariant()) " +
        "one=$((Test-FmPushBackendResult 1).ToString().ToLowerInvariant()) " +
        "null=$((Test-FmPushBackendResult $null).ToString().ToLowerInvariant()) " +
        "strFalse=$((Test-FmPushBackendResult 'False').ToString().ToLowerInvariant())")
}

# --- interop, only in the full phase -----------------------------------------
if (-not ($Cases -match '^push\.')) { return }

# Direction A: bash wrote the registration; read it back here.
$iopA = ''
foreach ($k in @('obligation_id','relation_id','work_home','work_id','generation','platform','request_id')) {
    $iopA += "$k=$(Get-FmPfRegistryValue $SharedA 'pf-shared' $k) "
}
Write-Record -Key 'iopA.read' -Value $iopA
$aRegistryFile = Join-Path (Get-FmPfRegistryDir $SharedA) 'pf-shared'
Write-Record -Key 'iopA.hex' -Value (ConvertTo-HexFile $aRegistryFile)
Write-Record -Key 'iopA.ids' -Value (Join-List @(Get-FmPfRegistryId $SharedA))
Write-Record -Key 'iopA.forwork' -Value (Join-List @(Get-FmPfRegistryIdForWork $SharedA 'secondmate:kid' 'work-shared'))

# The event id bash derived is the FILE NAME bash used. Deriving it here and
# finding that file is the whole idempotency guarantee, across languages.
$deliverables = '{"pr_url":"https://example.invalid/9"}'
$aEventId = Get-FmPfEventId 'pf-shared' 'rel-code' 'secondmate:kid' 'work-shared' '2' 'pr-merged' $deliverables
Write-Record -Key 'iopA.eventid' -Value $aEventId
$aEventPath = Join-Path (Get-FmPfEventsDir $SharedA) "$aEventId.json"
Write-Record -Key 'iopA.eventfile' -Value ([System.IO.File]::Exists($aEventPath)).ToString().ToLowerInvariant()
$aSig = Get-FmPfEventsSignature $SharedA
Write-Record -Key 'iopA.sig' -Value $aSig
# The surfaced record bash wrote must equal the signature computed here, or the
# relay poll would wake firstmate again for an unchanged pending set.
$aSurfacedPath = Join-Path (Get-FmPfRoot $SharedA) (Get-FmPfSurfacedBaseName)
$aSurfacedText = if ([System.IO.File]::Exists($aSurfacedPath)) { [System.IO.File]::ReadAllText($aSurfacedPath) } else { '<absent>' }
Write-Record -Key 'iopA.surfacedmatch' -Value ([string]::Equals($aSurfacedText, $aSig, [System.StringComparison]::Ordinal)).ToString().ToLowerInvariant()

# Direction B: write a registration HERE for bash to read back. The bytes go
# through fm-common's Set-FmFileText, the SAME writer a converted entrypoint
# would use, so this proves the writer as well as the reader.
$bRegistry = Get-FmPfRegistryDir $SharedB
$bEvents   = Get-FmPfEventsDir $SharedB
[void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $bRegistry))
[void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $bEvents))
$bRecord = "obligation_id=pf-shared`nrelation_id=rel-code`nwork_home=secondmate:kid`nwork_id=work-shared`ngeneration=2`nplatform=discord`nrequest_id=req-shared`n"
Set-FmFileText -Path (Join-Path $bRegistry 'pf-shared') -Text $bRecord -NoNewline
$bEventId = Get-FmPfEventId 'pf-shared' 'rel-code' 'secondmate:kid' 'work-shared' '2' 'pr-merged' $deliverables
Set-FmFileText -Path (Join-Path $bEvents "$bEventId.json") -Text '{}'
$bSig = Get-FmPfEventsSignature $SharedB
Set-FmFileText -Path (Join-Path (Get-FmPfRoot $SharedB) (Get-FmPfSurfacedBaseName)) -Text $bSig -NoNewline
Write-Record -Key 'iopB.hex' -Value (ConvertTo-HexFile (ConvertTo-FmNativePath (Join-Path $bRegistry 'pf-shared')))
Write-Record -Key 'iopB.eventid' -Value $bEventId
Write-Record -Key 'iopB.sig' -Value $bSig
PS1
QUERY_N=$(fm_test_native_path "$QUERY")

CASES="$TMP_ROOT/cases.txt"
CASES_RELAY="$TMP_ROOT/cases-relay.txt"
CASES_HEADER=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  "$PF_MOD" "$PT_MOD" \
  "$(fm_test_native_path "$P_BASE")" \
  "$(fm_test_native_path "$P_STATE")" \
  "$(fm_test_native_path "$SHARED_A")" \
  "$(fm_test_native_path "$SHARED_B")")
printf '%s\n%s' "$CASES_HEADER" "$CASE_BUF" > "$CASES"
CASES_N=$(fm_test_native_path "$CASES")

{
  printf '%s\n' "$CASES_HEADER"
  for which in on off empty quoted; do
    printf 'relay.%s\trelay\t/home%s\t\t\t\t\t\t\n' "$which" "$which"
  done
} > "$CASES_RELAY"
CASES_RELAY_N=$(fm_test_native_path "$CASES_RELAY")

# The bash oracle for the three relay environments. `export`/`unset` around each
# call rather than a prefix assignment: a prefix assignment PERSISTS in this
# shell after a FUNCTION call, so every later case would see the last value.
relay_oracle() {
  local out='' which h
  for which in on off empty quoted; do
    h="$B_BASE/home$which"
    if fm_pf_relay_active "$h"; then out="$out$which=true "; else out="$out$which=false "; fi
  done
  printf '%s' "$out"
}
unset FMX_PAIRING_TOKEN
B_RELAY_UNSET=$(relay_oracle)
export FMX_PAIRING_TOKEN=
B_RELAY_EMPTY=$(relay_oracle)
export FMX_PAIRING_TOKEN=zz
B_RELAY_VALUE=$(relay_oracle)
unset FMX_PAIRING_TOKEN

# --- run the phases -----------------------------------------------------------
#
# Every bash oracle answer above is already captured, so the child environment
# can now be pointed at the PowerShell state directory without disturbing them.
export FM_STATE_OVERRIDE="$P_STATE"
export FM_WAKE_QUEUE="$P_STATE/q/.wake-queue"

PS_OUT_FILE="$TMP_ROOT/ps.out"
PS_ERR_FILE="$TMP_ROOT/ps.err"

run_phase() {  # <case-file-native> <out> <err>
  pwsh -NoProfile -Command "& '$QUERY_N' -CaseFile '$1'" > "$2" 2> "$3"
}

run_phase "$CASES_N" "$PS_OUT_FILE" "$PS_ERR_FILE" \
  || fail "the PowerShell query script failed (phase 1):"$'\n'"$(cat "$PS_ERR_FILE")"
export FMX_PAIRING_TOKEN=
run_phase "$CASES_RELAY_N" "$TMP_ROOT/ps-empty.out" "$TMP_ROOT/ps-empty.err" \
  || fail "the PowerShell query script failed (phase 2, empty token):"$'\n'"$(cat "$TMP_ROOT/ps-empty.err")"
export FMX_PAIRING_TOKEN=zz
run_phase "$CASES_RELAY_N" "$TMP_ROOT/ps-value.out" "$TMP_ROOT/ps-value.err" \
  || fail "the PowerShell query script failed (phase 3, non-empty token):"$'\n'"$(cat "$TMP_ROOT/ps-value.err")"
unset FMX_PAIRING_TOKEN

# --- read the PowerShell answers ---------------------------------------------
PS_LINES=()
while IFS= read -r ps_line; do
  [ -n "$ps_line" ] && PS_LINES+=("$ps_line")
done < "$PS_OUT_FILE"

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

phase_relay() {  # <out-file>
  local out='' which v
  for which in on off empty quoted; do
    v=$(sed -n "s/^relay\\.$which"$'\t'"//p" "$1" | head -1)
    out="$out$which=${v:-<missing>} "
  done
  printf '%s' "$out"
}

# --- 0. nothing may throw, and no case may lose a field -----------------------
ps_errors=''
for ps_line in ${PS_LINES+"${PS_LINES[@]}"}; do
  case "$ps_line" in
    *.error$'\t'*|FATAL.*) ps_errors="$ps_errors ${ps_line%%$'\t'*}" ;;
  esac
done
assert_same "[both] no function throws and every case record kept its 9 fields" "" "${ps_errors# }"

# --- 1-11. fm-public-followup-lib ---------------------------------------------
psv slug;     assert_same "[pf] fm_pf_slug_valid: same verdict for every id shape" "$B_SLUG" "$FM_PSV"
psv homeid;   assert_same "[pf] fm_pf_home_id_valid: same verdict, including the traversal shape" "$B_HOMEID" "$FM_PSV"
psv eventid;  assert_same "[pf] fm_pf_event_id: identical digests for every identity tuple" "$B_EVENTID" "$FM_PSV"
psv sha;      assert_same "[pf] fm_pf_sha256: identical digests with shasum replaced by .NET" "$B_SHA" "$FM_PSV"
psv clean;    assert_same "[pf] fm_pf_clean_outcome_text: byte-identical, including NBSP and control characters" "$B_CLEAN" "$FM_PSV"
psv bound;    assert_same "[pf] fm_pf_bound_bytes: byte-identical, including a split multi-byte character" "$B_BOUND" "$FM_PSV"
psv dir;      assert_same "[pf] the transport directory names agree" "$B_DIRS" "$FM_PSV"
psv direntry; assert_same "[pf] fm_pf_dir_has_entry: dotfiles, a missing path, and a plain file all agree" "$B_DIRENTRY" "$FM_PSV"
psv gate;     assert_same "[pf] both activation gates agree in every relay/commitment combination" "$B_GATE" "$FM_PSV"
psv regget;   assert_same "[pf] fm_pf_registry_get: last-wins, empty, embedded '=', and the unsafe-id refusal" "$B_REGGET" "$FM_PSV"
psv regids;   assert_same "[pf] fm_pf_registry_ids: same ids, same order, dotfile and subdirectory excluded" "$B_REGIDS" "$FM_PSV"
psv regids.emptystate; assert_same "[pf] fm_pf_registry_ids: an absent registry lists nothing" "$B_REGIDS_EMPTYSTATE" "$FM_PSV"
psv regidswork.main;   assert_same "[pf] fm_pf_registry_ids_for_work: both bindings for main/w1" "$B_REGIDS_MAIN" "$FM_PSV"
psv regidswork.kid;    assert_same "[pf] fm_pf_registry_ids_for_work: the secondmate binding" "$B_REGIDS_KID" "$FM_PSV"
psv regidswork.none;   assert_same "[pf] fm_pf_registry_ids_for_work: no binding is an empty answer, not an error" "$B_REGIDS_NONE" "$FM_PSV"
psv evsig;       assert_same "[pf] fm_pf_events_signature: identical digest over the pending set" "$B_EVSIG" "$FM_PSV"
psv evsig.empty; assert_same "[pf] fm_pf_events_signature: an empty set refuses rather than digesting nothing" "$B_EVSIG_EMPTY" "$FM_PSV"
assert_same "[pf] the signature really is sha256 of the sorted LF-terminated names" "$B_EVSIG_HAND" "$B_EVSIG"
psv const;    assert_same "[pf] the published constants agree" "$B_CONST" "$FM_PSV"

# --- 12. relay activation across three environments ---------------------------
assert_same "[pf] fm_pf_relay_active: the .env decides when the token is UNSET" \
  "$B_RELAY_UNSET" "$(phase_relay "$PS_OUT_FILE")"
assert_same "[pf] fm_pf_relay_active: an inherited EMPTY token means inactive and the .env is not consulted" \
  "$B_RELAY_EMPTY" "$(phase_relay "$TMP_ROOT/ps-empty.out")"
assert_same "[pf] fm_pf_relay_active: an inherited non-empty token wins over every .env" \
  "$B_RELAY_VALUE" "$(phase_relay "$TMP_ROOT/ps-value.out")"

# --- 13-15. fm-push-transition-lib shapes -------------------------------------
psv surfpath;  assert_same "[push] _hb_surfaced_path: ':' '/' and '.' all become '_'" "$B_SURFPATH" "$FM_PSV"
psv record;    assert_same "[push] the five-field transition record is byte-identical, empty middle included" "$B_RECORD" "$FM_PSV"
psv parserec;  assert_same "[push] a record BUILT BY BASH parses here with all five fields intact" \
  "n=5 pane=wG:pQ to=blocked" "$FM_PSV"
psv triagecap; assert_same "[push] the triage-log size cap agrees" "$B_TRIAGECAP" "$FM_PSV"
# DOCUMENTED DIVERGENCE, not a defect in either twin, and normalized here rather
# than hidden: with a NON-NUMERIC streak record, bash's
# `echo $(( $(cat file) + 1 ))` expands `abc` as a VARIABLE, and under `set -u`
# - which bin/fm-watch.sh sets - that is an unbound-variable error raised during
# expansion, BEFORE the redirection is applied. So bash leaves the junk in place
# and the watcher dies. The twin cannot fake that, and faking it would be worse
# than the honest degrade: it treats an unreadable record as 0, exactly as it
# treats a missing one, and carries on. Both facts are asserted.
assert_same "[push] a non-numeric streak record is fatal to the bash twin under set -u, so bash leaves it unchanged" \
  "yes" "$(case "$B_STREAK" in *'garbage=abc '*) printf yes ;; *) printf 'no: %s' "$B_STREAK" ;; esac)"
psv streak;    assert_same "[push] the heartbeat streak grows on heartbeat, resets otherwise, and degrades junk to 0" \
  "${B_STREAK/garbage=abc /garbage=1 }" "$FM_PSV"
psv setsurf;   assert_same "[push] mark_surfaced records only a captain-relevant line, byte-exactly and unterminated" "$B_SETSURF" "$FM_PSV"

# --- 16. the transition handler, scenario by scenario -------------------------
psv push.blocked;      assert_same "[push] a blocked crew enqueues a stale wake, commits, and wakes the supervisor" "$B_PUSH_BLOCKED" "$FM_PSV"
psv push.paused;       assert_same "[push] a declared-pause crew is absorbed into the triage log with no wake" "$B_PUSH_PAUSED" "$FM_PSV"
psv push.surfaced;     assert_same "[push] a captain-relevant status is marked surfaced after the wake is enqueued" "$B_PUSH_SURFACED" "$FM_PSV"
psv push.nopane;       assert_same "[push] a record with no pane id sleeps and does nothing else" "$B_PUSH_NOPANE" "$FM_PSV"
psv push.commitfail;   assert_same "[push] a refused commit fails the whole handler" "$B_PUSH_COMMITFAIL" "$FM_PSV"
psv push.enqueuefail;  assert_same "[push] a failed durable enqueue never commits the dedupe marker" "$B_PUSH_ENQUEUEFAIL" "$FM_PSV"

# --- 17. the fm-backend seam --------------------------------------------------
#
# Ground truth rather than differential for the probe itself: bash's twin is
# `command -v`, so the bash side asserts the same fact in its own idiom.
# The same question - "does loading the library alone give it the backend commit
# function?" - asked in each language's own scope, because the two languages have
# no common one: bash sources into the caller's single shell scope, and a nested
# PowerShell import publishes into the importing MODULE's session state.
assert_same "[push] sourcing the bash lib alone resolves fm_backend_commit_transition, at bash's caller scope"   "resolved" "$B_BACKEND_EDGE"
psv seam.edge
assert_same "[push] importing the module alone resolves Save-FmBackendTransition, inside the module's own scope"   "resolved" "$FM_PSV"
psv seam.edge.negative
assert_same "[push] that edge probe can report failure: an absent command in the same scope reads missing"   "missing" "$FM_PSV"
psv seam.results
assert_same "[push] the commit result is read as bash reads \$?: 0 and \$true succeed; 1, \$false, \$null and 'False' do not" \
  "true=true false=false zero=true one=false null=false strFalse=false" "$FM_PSV"

# --- 18. cross-world interop, direction A: bash wrote, PowerShell read --------
psv iopA.read
assert_same "[pf] INTEROP A: every field of a BASH-written registration reads back identically in PowerShell" \
  "$IOP_A_READ" "$FM_PSV"
psv iopA.hex
assert_same "[pf] INTEROP A: PowerShell sees the same registration bytes bash wrote" "$IOP_A_HEX" "$FM_PSV"
psv iopA.ids
assert_same "[pf] INTEROP A: the bash-written registration is listed" "$IOP_A_IDS" "$FM_PSV"
psv iopA.forwork
assert_same "[pf] INTEROP A: the completion guard finds the bash-written binding" "$IOP_A_FORWORK" "$FM_PSV"
psv iopA.eventid
assert_same "[pf] INTEROP A: PowerShell derives the SAME event id bash used as the filename" "$IOP_A_EVENTID" "$FM_PSV"
psv iopA.eventfile
assert_same "[pf] INTEROP A: that derivation actually lands on the bash-written event file" "true" "$FM_PSV"
psv iopA.sig
assert_same "[pf] INTEROP A: the pending-event signature agrees over a bash-written set" "$IOP_A_SIG" "$FM_PSV"
psv iopA.surfacedmatch
assert_same "[pf] INTEROP A: a bash-written surfaced record still suppresses a repeat wake in PowerShell" "true" "$FM_PSV"

# --- 19. cross-world interop, direction B: PowerShell wrote, bash reads -------
#
# Read AFTER the PowerShell phases, in this shell, with the bash library.
IOP_B_FILE="$SHARED_B/public-followup/registry/pf-shared"
assert_same "[pf] INTEROP B: PowerShell published a registration where bash looks for one" \
  "yes" "$([ -f "$IOP_B_FILE" ] && echo yes || echo no)"
IOP_B_READ=""
for k in obligation_id relation_id work_home work_id generation platform request_id; do
  IOP_B_READ="$IOP_B_READ$k=$(fm_pf_registry_get "$SHARED_B" pf-shared "$k") "
done
assert_same "[pf] INTEROP B: bash reads back every field of a POWERSHELL-written registration" \
  "$IOP_A_READ" "$IOP_B_READ"
assert_same "[pf] INTEROP B: the two worlds write the same registration BYTE FOR BYTE" \
  "$IOP_A_HEX" "$(hexfile "$IOP_B_FILE")"
psv iopB.eventid
assert_same "[pf] INTEROP B: bash derives the SAME event id PowerShell used as the filename" \
  "$IOP_A_EVENTID" "$FM_PSV"
assert_same "[pf] INTEROP B: that derivation lands on the PowerShell-written event file" \
  "yes" "$([ -f "$SHARED_B/public-followup/events/$IOP_A_EVENTID.json" ] && echo yes || echo no)"
IOP_B_SIG=$(fm_pf_events_signature "$SHARED_B")
psv iopB.sig
assert_same "[pf] INTEROP B: bash computes the same signature PowerShell did over the same set" \
  "$IOP_B_SIG" "$FM_PSV"
assert_same "[pf] INTEROP B: a PowerShell-written surfaced record still suppresses a repeat wake in bash" \
  "$IOP_B_SIG" "$(cat "$SHARED_B/public-followup/surfaced" 2>/dev/null)"
assert_same "[pf] INTEROP: the same pending set digests identically no matter which world built it" \
  "$IOP_A_SIG" "$IOP_B_SIG"

# --- 20. module hygiene -------------------------------------------------------
import_noise=$(pwsh -NoProfile -Command "Import-Module '$PF_MOD' -Force; Import-Module '$PT_MOD' -Force" 2>&1)
assert_same "[both] importing both modules emits nothing" "" "$import_noise"

# --- report -------------------------------------------------------------------
if [ -s "$PS_ERR_FILE" ]; then
  # stderr is not automatically a failure: the missing-capability case
  # deliberately produces one diagnostic. Anything else is worth seeing.
  printf '# PowerShell stderr (phase 1):\n' >&2
  sed 's/^/#   /' "$PS_ERR_FILE" >&2
fi

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W3-followup PowerShell twins differ from their oracles (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. This is an EXACT total observed on a green run, not
# a guess and not a loose floor: dropping a single case fails the run instead of
# quietly shrinking it.
MIN_ASSERTIONS=57
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-public-followup-lib.psm1 and fm-push-transition-lib.psm1 hold their contracts across %d assertions\n' "$ASSERTIONS"
printf '# fm-followup-psm1.test.sh: all assertions passed\n'
