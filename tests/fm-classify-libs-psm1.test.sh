#!/usr/bin/env bash
# Behavior test for the three PowerShell leaf-library twins of wave-2 package
# W2-classify:
#
#   bin/fm-transition-lib.psm1    the normalized transition record + the
#                                 single-owner status -> action policy table
#   bin/fm-classify-lib.psm1      the shared wake classifier: captain-relevance,
#                                 the durable keyed decision fold, and the
#                                 working/paused absorb classification
#   bin/fm-supervision-lib.psm1   the "supervision missing" predicate
#
# Together these decide what a supervision event MEANS - whether a status line
# is actionable, whether a crew is provably working or merely quiet, and which
# action a state transition maps to - and the verdicts are consumed by the
# always-on watcher and the away-mode daemon. A PowerShell twin that answers
# `absorb` where bash answers `actionable` does not fail loudly; it silently
# stops waking the supervisor. So every case here is DIFFERENTIAL: it drives the
# bash function and the PowerShell function with byte-identical input and
# asserts byte-identical output, with BASH AS THE ORACLE. No expectation is
# hard-coded except for the handful of documented divergences, which are
# asserted against BOTH written-down answers so a twin cannot drift into or out
# of one by accident.
#
# TRANSPORT, and why it is shaped this way. One case list, in one file, read by
# both sides - not two hand-written case lists that could drift. Fields are
# separated by 0x01 and records by 0x02, two bytes that appear in no fixture,
# so every value crosses the boundary as RAW BYTES: a TAB, an embedded newline,
# a middle-dot and a non-breaking space all arrive unencoded. That matters more
# here than anywhere else in the port, because the transition record IS a TAB
# record with meaningful EMPTY fields and the decision fold emits TAB records of
# its own; an encoding layer would hide exactly the bug this file exists to
# catch. The results come back the same way, one `<index>0x01<value>0x02` record
# per case, so a failure names its own case.
#
# COST. Process creation on this Windows host is expensive (pwsh startup alone
# is ~360ms, and a bare `git rev-parse` was measured at 2.3s under load), so
# both sides run ONCE: one bash launch and one pwsh launch for the whole case
# list. Environment changes that would normally need a separate process are
# themselves CASES (`env.set` / `env.unset`), executed in order by both drivers,
# which is how the FM_CAPTAIN_RE, verb-vocabulary and LC_ALL variants are
# covered without paying for another interpreter each.
#
# NO SUBSHELLS AROUND BOOKKEEPING. Nothing that records an assertion runs inside
# `( ... )`: a subshell cannot report a failure back to the parent counters, so
# a scheme that can LOSE a failure is worse than none - the suite would certify
# work it never checked. Command substitution appears only where a VALUE is
# computed. The assertion COUNT is asserted at the end for the same reason: a
# run that silently executed nothing must not read as a pass.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
#
# Every path handed to pwsh, INCLUDING the module and driver paths, goes through
# fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads /tmp/x
# as C:\tmp\x - verified).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for lib in fm-transition-lib fm-classify-lib fm-supervision-lib; do
  [ -f "$ROOT/bin/$lib.psm1" ] || fail "bin/$lib.psm1 is missing"
  [ -f "$ROOT/bin/$lib.sh" ] || fail "bin/$lib.sh is missing (the oracle)"
done

TMP_ROOT=$(fm_test_tmproot fm-classify-psm1)
FIX="$TMP_ROOT/fix"
mkdir -p "$FIX"

CASES="$TMP_ROOT/cases.bin"
: > "$CASES"
ORACLE="$TMP_ROOT/oracle.sh"
PROBE="$TMP_ROOT/probe.ps1"
O_RES="$TMP_ROOT/oracle.bin"
P_RES="$TMP_ROOT/probe.bin"
O_ERR="$TMP_ROOT/oracle.err"
P_ERR="$TMP_ROOT/probe.err"

BIN_N=$(fm_test_native_path "$ROOT/bin")
PROBE_N=$(fm_test_native_path "$PROBE")
CASES_N=$(fm_test_native_path "$CASES")

# --- assertion bookkeeping ----------------------------------------------------

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# %q renders the invisible bytes these values are full of (TABs, trailing
# newlines, non-breaking spaces) and is a builtin, so a failure message costs
# nothing on the passing path.
assert_same() {  # <label> <expected> <actual>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected: $(printf '%q' "$expected")
  actual  : $(printf '%q' "$actual")
"
  fi
}

# --- the shared case list -----------------------------------------------------
#
# LABELS, IS_DIV, DIV_BASH and DIV_PS are index-parallel with the records in
# $CASES, and only `add`/`add_div` ever append, so the alignment cannot drift.

LABELS=()
IS_DIV=()
DIV_BASH=()
DIV_PS=()

add() {  # <label> <op> [arg...]
  local label=$1 op=$2 a
  shift 2
  LABELS+=("$label")
  IS_DIV+=(0)
  DIV_BASH+=("")
  DIV_PS+=("")
  printf '%s' "$op" >> "$CASES"
  for a in "$@"; do printf '\001%s' "$a" >> "$CASES"; done
  printf '\002' >> "$CASES"
}

# A case where the two trees deliberately DISAGREE. Both answers are written
# down, so the divergence is tested rather than merely documented, and a twin
# that quietly converges (or drifts further) fails.
add_div() {  # <label> <expected-bash> <expected-ps> <op> [arg...]
  local label=$1 eb=$2 ep=$3 op=$4 a
  shift 4
  LABELS+=("$label")
  IS_DIV+=(1)
  DIV_BASH+=("$eb")
  DIV_PS+=("$ep")
  printf '%s' "$op" >> "$CASES"
  for a in "$@"; do printf '\001%s' "$a" >> "$CASES"; done
  printf '\002' >> "$CASES"
}

# =============================================================================
# Fixtures
# =============================================================================

STATE="$FIX/state"
mkdir -p "$STATE"

# A meta whose name starts with a dot. A bash `*` NEVER matches a leading dot,
# so this record must be invisible to every glob below - and it is deliberately
# given the SAME window as tk1 and a name that sorts FIRST, so a twin that
# enumerated it would return ".hidden" where bash returns "tk1".
fm_write_meta "$STATE/.hidden.meta" "window=default:wG:pQ" "kind=ship"
fm_write_meta "$STATE/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE/tk2.meta" "window=fmses:fm-tk2" "terminal=alt:zzz" "kind=ship"
# A truncated record and a repeated key: fm_meta_get takes the LAST match and
# everything after the FIRST '=', and the glob scan must not choke on either.
fm_write_meta "$STATE/tk5.meta" "window=first:one" "window=second:two=three" "noequalsline"

# The decision fold fixture. Deliberately interleaved so that reading it
# last-event-wins would give a different answer than the fold: a `done:` line
# sits between an open decision and its resolution, and a blank line plus a
# whitespace-only line sit in the middle.
{
  printf 'working: started\n'
  printf 'needs-decision [key=api-shape]: pick REST or gRPC\n'
  printf 'working: still going\n'
  printf 'needs-decision: bare default key opens too\n'
  printf 'done: finished the first half\n'
  printf '\n'
  printf '   \n'
  printf 'resolved [key=api-shape]: chose REST\n'
  printf 'blocked [key=deploy]: need the staging creds\n'
  printf 'paused: waiting on the vendor window\n'
  printf 'captain-held: bare transfer closes default\n'
} > "$STATE/tk1.status"

{
  printf 'working: making progress\n'
  printf 'paused: waiting on the upstream release\n'
} > "$STATE/tk2.status"

# A legacy bare line with no verb and no colon: the free-text arm exists only
# for these.
printf 'merged\n' > "$STATE/tk3.status"

# The documented false positive the verb-aware rule exists to kill.
printf 'working: rebased onto merged #76\n' > "$STATE/tk4.status"

# A file whose LAST line is blank under a UTF-8 locale and NOT blank under C,
# because U+00A0 is [[:space:]] only in the former. Measured on this host:
# grep and bash agree with each other and flip together.
{
  printf 'done: an early terminal line\n'
  printf '   \n'
  printf '\u00a0\n'
} > "$STATE/blank.status"

# Nothing but blank lines: last_status_line is empty under either locale.
{
  printf '\n'
  printf '\t \n'
} > "$STATE/empty.status"

# Routed-work phases, for the activity fold.
{
  printf 'working [key=alpha]: building the adapter\n'
  printf 'working: legacy default phase\n'
  printf 'paused [key=beta]: waiting on the vendor\n'
  printf 'done [key=alpha]: shipped\n'
} > "$STATE/act1.status"

# Key-grammar edge cases: two refusals that must skip their whole line, an
# UNCLOSED token that falls through to the default key rather than being
# refused, and one full legal slug.
{
  printf 'needs-decision [key=bad key]: refused, skipped entirely\n'
  printf 'needs-decision [key=]: also refused\n'
  printf 'needs-decision [key=unclosed: no closing bracket means the default key\n'
  printf 'blocked [key=ok.slug-1_2]: a full legal slug\n'
} > "$STATE/key1.status"

# A dot-prefixed status the fleet scan must not see, and a turn-end marker the
# signal helpers must skip on extension rather than on existence.
printf 'done: hidden\n' > "$STATE/.hidden.status"
: > "$STATE/tk1.turn-ended"

# Signal-helper fixtures live in their OWN directory so they cannot perturb the
# fleet-scan expectations above.
SIG="$FIX/sig"
mkdir -p "$SIG"
printf 'working: mid-run\n' > "$SIG/wk.status"
: > "$SIG/wk.turn-ended"
printf 'paused: vendor window\n' > "$SIG/pa.status"
printf 'not a status file\n' > "$SIG/notatask.txt"

# The stubbed current-state reader. FM_CREW_STATE_BIN exists precisely so the
# run-step/pane verdict can be driven without a real worktree or a no-mistakes
# install. The middle dots are U+00B7, which is also what proves the UTF-8
# console encoding survives the whole PowerShell path.
CREW_FAKE="$FIX/fake-crew-state.sh"
cat > "$CREW_FAKE" <<'SH'
#!/usr/bin/env bash
case "$1" in
  wk)      printf 'state: working \u00b7 source: run-step \u00b7 nm run r1 step running\n' ;;
  wkpane)  printf 'state: working \u00b7 source: pane \u00b7 busy signature\n' ;;
  wklog)   printf 'state: working \u00b7 source: status-log \u00b7 last line said working\n' ;;
  pa)      printf 'state: paused \u00b7 source: status-log \u00b7 waiting on the vendor\n' ;;
  dn)      printf 'state: done \u00b7 source: run-step \u00b7 passed\n' ;;
  junk)    printf 'no state prefix at all\n' ;;
  nospace) printf 'state:working \u00b7 source: run-step \u00b7 no space after the colon\n' ;;
  nosrc)   printf 'state: working \u00b7 there is no source token here\n' ;;
  fail)    printf 'state: working \u00b7 source: run-step \u00b7 and then exits non-zero\n'; exit 3 ;;
  silent)  : ;;
  *)       printf 'state: unknown \u00b7 source: none \u00b7 no metadata for %s\n' "$1" ;;
esac
SH
chmod +x "$CREW_FAKE"

# Supervision fixtures.
SUP_IDLE="$FIX/sup-idle"; mkdir -p "$SUP_IDLE"
SUP_WORK="$FIX/sup-work"; mkdir -p "$SUP_WORK"
SUP_STALE="$FIX/sup-stale"; mkdir -p "$SUP_STALE"
SUP_XONLY="$FIX/sup-xonly"; mkdir -p "$SUP_XONLY"
EMPTY_STATE="$FIX/empty-state"; mkdir -p "$EMPTY_STATE"

fm_write_meta "$SUP_WORK/a.meta" "window=s:fm-a"
fm_write_meta "$SUP_WORK/b.meta" "window=s:fm-b"
fm_write_meta "$SUP_WORK/.hidden.meta" "window=s:fm-hidden"
touch "$SUP_WORK/.last-watcher-beat"
printf 'queued\trecord\n' > "$SUP_WORK/.wake-queue"

fm_write_meta "$SUP_STALE/c.meta" "window=s:fm-c"
: > "$SUP_STALE/x-watch.check.sh"
: > "$SUP_STALE/.wake-queue"
touch -t 202001020304.05 "$SUP_STALE/.last-watcher-beat"

: > "$SUP_XONLY/x-watch.check.sh"

# A file with a PINNED mtime, so the epoch differential is exact rather than
# racing the clock between the two runs.
MTIME_FILE="$FIX/pinned-mtime"
: > "$MTIME_FILE"
touch -t 202001020304.05 "$MTIME_FILE"

# The stdin fixture for the `-` form of the activity fold, consumed by exactly
# one case at the very end of the stream.
STDIN_FIX="$TMP_ROOT/stdin.txt"
{
  printf 'working [key=one]: from standard input\n'
  printf 'paused: default phase from standard input\n'
  printf 'done [key=one]: closed from standard input\n'
} > "$STDIN_FIX"

TAB=$(printf '\t')
NBSP=$(printf '\u00a0')

# =============================================================================
# Case list - section A: bin/fm-transition-lib
# =============================================================================

add "transition: a full record is five TAB-separated fields" \
  t.record 'wG:pQ' 'wG' '' 'blocked' 'claude'
add "transition: a full record carries exactly four separators" \
  t.recordtabs 'wG:pQ' 'wG' '' 'blocked' 'claude'
add "transition: every optional field empty still carries four separators" \
  t.recordtabs 'w1:p3' '' '' 'working' ''
add "transition: the record with empty optionals is byte-identical" \
  t.record 'w1:p3' '' '' 'working' ''
add "transition: every field empty is still a five-column record" \
  t.record '' '' '' '' ''
# The scrub is what keeps the column count fixed no matter what a backend hands
# in; a stray TAB or newline in the agent field would otherwise desync to_status.
add "transition: a field carrying TAB and newline is scrubbed to spaces" \
  t.record 'wG:pQ' 'wG' '' 'blocked' "multi${TAB}line
agent"
add "transition: a scrubbed field cannot add columns" \
  t.recordtabs 'wG:pQ' 'wG' '' 'blocked' "multi${TAB}line
agent"
add "transition: to_status survives a dirty neighbouring field" \
  t.to "$(printf 'wG:pQ\twG\t\tblocked\tmulti line agent')"
add "transition: clean_field turns CR into a space" \
  t.clean "$(printf 'a\rb')"
add "transition: clean_field leaves ordinary text alone" t.clean 'plain value'
add "transition: clean_field on an empty value" t.clean ''
add "transition: a trailing newline becomes a trailing space, not nothing" \
  t.clean "$(printf 'tail\n')x"

REC5=$(printf 'p1\tw1\tidle\tworking\tclaude')
add "transition: field 1 is the pane id" t.field "$REC5" 1
add "transition: field 2 is the workspace id" t.field "$REC5" 2
add "transition: field 3 is the previous status" t.field "$REC5" 3
add "transition: field 4 is the new status" t.field "$REC5" 4
add "transition: field 5 is the agent" t.field "$REC5" 5
add "transition: a field past the last one is empty, not an error" t.field "$REC5" 6
add "transition: pane_id accessor" t.pane "$REC5"
add "transition: workspace_id accessor" t.ws "$REC5"
add "transition: from_status accessor" t.from "$REC5"
add "transition: to_status accessor" t.to "$REC5"
add "transition: agent accessor" t.agent "$REC5"

# EMPTY FIELDS ARE MEANINGFUL. These are the cases a `read`-style or
# RemoveEmptyEntries-style split gets wrong, and they are the reconcile path's
# actual record shape.
REC_EMPTY=$(printf 'p1\t\t\tworking\t')
add "transition: an empty MIDDLE field does not shift the columns" t.ws "$REC_EMPTY"
add "transition: to_status is still column 4 with two empty middles" t.to "$REC_EMPTY"
add "transition: an empty LAST field reads as empty" t.agent "$REC_EMPTY"
REC_LEAD=$(printf '\tw1\t\tblocked\t')
add "transition: an empty FIRST field reads as empty" t.pane "$REC_LEAD"
add "transition: column 4 survives an empty first field" t.to "$REC_LEAD"
add "transition: an all-empty record still has five readable columns" t.to "$(printf '\t\t\t\t')"

# cut behaviors that a naive index would get wrong.
add "transition: a record with NO separator passes through whole (cut rule)" \
  t.field 'abc' 3
add "transition: field 1 of a separator-free record is the record" t.field 'abc' 1
add "transition: an empty record yields an empty field (zero lines to cut)" t.field '' 1
add "transition: a multi-line argument yields one result per line" \
  t.field "$(printf 'a\tb\nc\td')" 2
add "transition: a trailing newline terminates rather than adds a line" \
  t.field "$(printf 'a\tb\n')" 2

add "transition: the field separator is a literal TAB" t.sep

add "transition: blocked is the one immediately actionable status" t.policy blocked
add "transition: working absorbs and clears the dedupe marker" t.policy working
add "transition: idle defers to the poll backstop" t.policy idle
add "transition: done defers to the poll backstop" t.policy done
add "transition: an unrecognized status falls back to polling" t.policy unknown
add "transition: an empty status falls back to polling" t.policy ''
add "transition: a future status falls back to polling" t.policy some-future-status
# Case sensitivity is the property PowerShell switch would have silently lost.
add "transition: the policy table is case-SENSITIVE" t.policy BLOCKED
add "transition: a padded status is not the status" t.policy ' blocked'

# =============================================================================
# Case list - section B: bin/fm-classify-lib, pure line parsing
# =============================================================================

add "classify: verb of a plain status line" c.verb 'done: shipped it'
add "classify: verb of a keyed status line" c.verb 'needs-decision [key=api-shape]: pick one'
add "classify: verb of a line with no colon" c.verb 'merged'
add "classify: verb of an empty line" c.verb ''
add "classify: verb is trimmed on both sides" c.verb '   blocked   : padded'
add "classify: verb stops at the FIRST colon" c.verb 'done: a note: with a colon'
add "classify: a key token inside the NOTE is not part of the verb" \
  c.verb 'done: mentions [key=x] in prose'
add "classify: an all-whitespace verb is empty" c.verb '   : note'
add "classify: verb of a whitespace-only line" c.verb '   '

add "classify: note is everything after the first colon, left-trimmed" \
  c.note 'done:    shipped it'
add "classify: note keeps interior and TRAILING whitespace" c.note 'done: padded   '
add "classify: a line with no colon is its own note, untouched" c.note '  merged  '
add "classify: note of a keyed line keeps only the text" \
  c.note 'needs-decision [key=api-shape]: pick REST'
add "classify: an empty note" c.note 'done:'
add "classify: note of an empty line" c.note ''

add "classify: no key token means the default key" c.key 'needs-decision: bare'
add "classify: a legal slug is the key" c.key 'needs-decision [key=api-shape]: x'
add "classify: a slug of every legal character class" c.key 'blocked [key=ok.slug-1_2]: x'
add "classify: a slug with a space is REFUSED" c.key 'needs-decision [key=bad key]: x'
add "classify: an empty slug is REFUSED" c.key 'needs-decision [key=]: x'
add "classify: a slug with a slash is REFUSED" c.key 'needs-decision [key=a/b]: x'
add "classify: an unclosed key token falls through to the default key" \
  c.key 'needs-decision [key=unclosed: x'
add "classify: a key token AFTER the colon is not a key" c.key 'done: see [key=nope] here'
add "classify: a key on a line with no colon at all" c.key 'blocked [key=zz] no colon'

add "classify: done is a terminal verb" c.terminal 'done: x'
add "classify: needs-decision is a terminal verb" c.terminal 'needs-decision: x'
add "classify: blocked is a terminal verb" c.terminal 'blocked: x'
add "classify: failed is a terminal verb" c.terminal 'failed: x'
add "classify: working is NOT a terminal verb" c.terminal 'working: x'
add "classify: a keyed terminal verb still counts" c.terminal 'blocked [key=k]: x'
add "classify: free text alone is not a terminal verb" c.terminal 'merged'
add "classify: an empty line has no terminal verb" c.terminal ''

add "classify: a done line is captain-relevant" c.relevant 'done: PR ready'
add "classify: a needs-decision line is captain-relevant" c.relevant 'needs-decision: pick one'
add "classify: a blocked line is captain-relevant" c.relevant 'blocked: need creds'
add "classify: a failed line is captain-relevant" c.relevant 'failed: the build broke'
add "classify: a working line is NOT captain-relevant" c.relevant 'working: still going'
add "classify: a resolved line is NOT captain-relevant" c.relevant 'resolved: chose REST'
add "classify: a captain-held line is NOT captain-relevant" c.relevant 'captain-held: filed'
add "classify: a paused line is NOT captain-relevant" c.relevant 'paused: vendor window'
# The documented false positive the verb-aware rule exists to kill.
add "classify: free text inside a working line does NOT surface it" \
  c.relevant 'working: rebased onto merged #76'
add "classify: free text inside a paused line does NOT surface it" \
  c.relevant 'paused: waiting for the merged upstream'
add "classify: a legacy bare free-text line still surfaces" c.relevant 'merged'
add "classify: a legacy PR-ready line still surfaces" c.relevant 'PR ready for review'
add "classify: a legacy checks-green line still surfaces" c.relevant 'checks green on the branch'
add "classify: a legacy ready-in-branch line still surfaces" c.relevant 'ready in branch feat/x'
add "classify: unrelated prose is not captain-relevant" c.relevant 'just some note'
add "classify: an empty line is not captain-relevant" c.relevant ''
# grep -i: the free-text arm is case-insensitive, the verb arm is not.
add "classify: the free-text arm is case-insensitive" c.relevant 'DONE: shouted'
add "classify: a keyed done line is captain-relevant" c.relevant 'done [key=k]: shipped'

add "classify: a paused line is a declared pause" c.paused 'paused: vendor window'
add "classify: a keyed paused line is a declared pause" c.paused 'paused [key=k]: vendor'
add "classify: prose mentioning paused is NOT a declared pause" \
  c.paused 'working: the run is paused upstream'
add "classify: a done line is not a declared pause" c.paused 'done: x'
add "classify: an empty line is not a declared pause" c.paused ''
add "classify: paused satisfies the pause-or-held predicate" c.pausedheld 'paused: x'
add "classify: captain-held satisfies the pause-or-held predicate" c.pausedheld 'captain-held: x'
add "classify: a keyed captain-held satisfies it too" c.pausedheld 'captain-held [key=k]: x'
add "classify: done satisfies neither" c.pausedheld 'done: x'
add "classify: an empty line satisfies neither" c.pausedheld ''

# =============================================================================
# Case list - section C: bin/fm-classify-lib, files and folds
# =============================================================================

add "classify: last status line of a multi-event log" c.lastline "$STATE/tk1.status"
add "classify: blank lines are skipped when finding the last line" c.lastline "$STATE/blank.status"
add "classify: a file of only blank lines has no last line" c.lastline "$STATE/empty.status"
add "classify: a missing status file has no last line" c.lastline "$STATE/nosuch.status"
add "classify: a directory is not a readable status file" c.lastline "$STATE"

# The fold contract: a later unrelated `done:` must NOT close an earlier keyed
# decision, and only a matching resolution or captain-held transfer may.
add "classify: the decision fold survives a later unrelated terminal line" \
  c.opendecisions "$STATE/tk1.status"
add "classify: the decision fold refuses malformed keys and keeps legal ones" \
  c.opendecisions "$STATE/key1.status"
add "classify: a log with no decisions folds to nothing" c.opendecisions "$STATE/tk2.status"
add "classify: a missing file folds to nothing" c.opendecisions "$STATE/nosuch.status"
add "classify: a directory folds to nothing" c.opendecisions "$STATE"

add "classify: the activity fold keeps one phase per key, newest last" \
  c.openactivities "$STATE/act1.status"
add "classify: the activity fold closes a phase on a decision event" \
  c.openactivities "$STATE/tk1.status"
add "classify: an activity fold over a missing file is empty" \
  c.openactivities "$STATE/nosuch.status"

# =============================================================================
# Case list - section D: directory scans and window resolution
# =============================================================================

add "classify: a recorded window resolves to its task, ignoring dotfiles" \
  c.windowtask 'default:wG:pQ' "$STATE"
add "classify: a recorded terminal= target resolves to its task" \
  c.windowtask 'alt:zzz' "$STATE"
add "classify: a window= target resolves to its task" c.windowtask 'fmses:fm-tk2' "$STATE"
add "classify: the LAST window= line of a repeated key wins" \
  c.windowtask 'second:two=three' "$STATE"
add "classify: an unrecorded window falls back to the tmux-shaped id" \
  c.windowtask 'fmses:fm-nope' "$STATE"
add "classify: the fallback strips only one leading fm-" \
  c.windowtask 'fmses:fm-fm-nested' "$STATE"
add "classify: a target with no colon falls back to itself" c.windowtask 'bare' "$STATE"
add "classify: a missing state directory falls back" c.windowtask 'sess:fm-abc' "$FIX/nodir"
add "classify: an empty state argument falls back" c.windowtask 'sess:fm-abc' ''
add "classify: an empty window falls back to an empty id" c.windowtask '' "$STATE"

add "classify: the fleet scan emits every captain-relevant status, dotfiles excluded" \
  c.scan "$STATE"
add "classify: the fleet scan of a directory with no statuses is empty" c.scan "$SIG"
add "classify: the fleet scan of a missing directory is empty" c.scan "$FIX/nodir"

add "classify: a stale window whose last line is captain-relevant" \
  c.staleterminal 'fmses:fm-tk3' "$STATE"
add "classify: a stale window whose last line is a captain-held transfer" \
  c.staleterminal 'default:wG:pQ' "$STATE"
add "classify: a stale window with no status file at all" \
  c.staleterminal 'fmses:fm-nosuch' "$STATE"

# =============================================================================
# Case list - section E: the absorb classification (the one impure read)
# =============================================================================

add "env: point the current-state reader at the stub" \
  env.set FM_CREW_STATE_BIN "$CREW_FAKE"

add "classify: a run-step working crew is provably working" c.absorb wk
add "classify: a busy-pane working crew is provably working" c.absorb wkpane
add "classify: a status-log working crew is NOT provably working" c.absorb wklog
add "classify: a declared external-wait pause classifies as paused" c.absorb pa
add "classify: a finished crew absorbs as neither" c.absorb dn
add "classify: an unparseable verdict absorbs as neither" c.absorb junk
add "classify: a missing space after state: is not a state" c.absorb nospace
add "classify: working with no source token absorbs as neither" c.absorb nosrc
# The reader exit code is IGNORED - stdout counts even from a failing run.
add "classify: a non-zero exit does not discard the verdict it printed" c.absorb fail
add "classify: a silent reader absorbs as neither" c.absorb silent
add "classify: an empty task id never calls the reader" c.absorb ''
add "classify: an unknown task absorbs as neither" c.absorb nosuchtask

add "classify: provably-working predicate agrees for a run-step crew" c.provably wk
add "classify: provably-working predicate rejects a paused crew" c.provably pa
add "classify: provably-working predicate rejects a finished crew" c.provably dn
add "classify: paused predicate accepts a paused crew" c.crewpaused pa
add "classify: paused predicate rejects a working crew" c.crewpaused wk

# The DEFAULT resolution path: bash falls back to its source-time
# bin/fm-crew-state.sh, PowerShell falls back to Invoke-FmScript, which prefers
# a .ps1 twin and otherwise runs the .sh under Git Bash. Both must reach the
# same real sibling and agree.
add "classify: the default reader resolves to the real sibling in both trees" \
  c.absorbdefault nosuchtask

# =============================================================================
# Case list - section F: signal triage
# =============================================================================

add "classify: a signal naming a captain-relevant status is actionable" \
  c.signalact "$STATE/tk3.status"
add "classify: a signal naming a captain-held status is not actionable" \
  c.signalact "$STATE/tk1.status"
add "classify: any actionable file in the list makes the signal actionable" \
  c.signalact "$STATE/tk1.status" "$STATE/tk3.status"
add "classify: a turn-end marker carries no verb and is skipped" \
  c.signalact "$STATE/tk1.turn-ended"
add "classify: a status file that does not exist is skipped" \
  c.signalact "$STATE/nosuch.status"
add "classify: an empty signal list is not actionable" c.signalact

add "classify: every task in a no-verb signal provably working absorbs it" \
  c.signalworking "$SIG/wk.status"
add "classify: a turn-end marker maps to its task id too" \
  c.signalworking "$SIG/wk.turn-ended"
add "classify: one non-working task makes the whole signal surface" \
  c.signalworking "$SIG/wk.status" "$SIG/pa.status"
add "classify: duplicate ids are visited once" \
  c.signalworking "$SIG/wk.status" "$SIG/wk.turn-ended"
add "classify: a file that is neither status nor turn-end resolves no task" \
  c.signalworking "$SIG/notatask.txt"
add "classify: an empty signal list must SURFACE, not absorb" c.signalworking
# Divergence (e): the bash twin splits the basename on '/' only, so a native
# Windows path is taken whole and resolves no task; the PowerShell twin also
# accepts '\', because a PowerShell caller holds native paths. The widening
# cannot change a '/'-only verdict, and it is asserted in both directions so a
# later convergence in either tree is loud.
add_div "classify: a backslash path resolves a task only in the PowerShell tree" \
  false true c.signalworking "$SIG\\wk.status"

# =============================================================================
# Case list - section G: FM_CAPTAIN_RE, whose two reads have different semantics
# =============================================================================

add "env: install a custom captain vocabulary" env.set FM_CAPTAIN_RE 'ship-it'
add "classify: a custom vocabulary SUPPRESSES the built-in terminal-verb arm" \
  c.relevant 'done: shipped'
add "classify: a custom vocabulary matches its own token" c.relevant 'ship-it: now'
add "classify: a custom vocabulary still refuses a working line" c.relevant 'working: ship-it'
add "classify: the resolved regex reports the override" c.captainre

add "env: set the captain vocabulary to the empty string" env.set FM_CAPTAIN_RE ''
# `+x` versus `:-`: SET-but-empty suppresses the shortcut, yet the PATTERN falls
# back to the default. Both halves are asserted.
add "classify: an empty vocabulary still suppresses the terminal-verb arm" \
  c.relevant 'zzz'
add "classify: an empty vocabulary falls back to the DEFAULT pattern" \
  c.relevant 'done: shipped'
add "classify: the resolved regex falls back when the override is empty" c.captainre

add "env: install an invalid captain vocabulary" env.set FM_CAPTAIN_RE '['
add "classify: an invalid vocabulary reads as no match, not an error" \
  c.relevant 'done: shipped'

add "env: remove the captain vocabulary override" env.unset FM_CAPTAIN_RE
add "classify: removing the override restores the terminal-verb arm" \
  c.relevant 'done: shipped'
add "classify: the resolved regex is the built-in default again" c.captainre

# =============================================================================
# Case list - section H: the verb vocabulary overrides
# =============================================================================

add "env: rename the declared-pause verb" env.set FM_CLASSIFY_PAUSED_VERB holding
add "classify: the renamed pause verb is the declared pause" c.paused 'holding: vendor'
add "classify: the built-in pause verb no longer declares a pause" c.paused 'paused: vendor'
add "classify: the renamed pause verb is not captain-relevant" c.relevant 'holding: vendor'
add "classify: the resolved pause verb reports the override" c.pausedverb
add "classify: the activity fold opens a phase on the renamed pause verb" \
  c.openactivities "$STATE/act1.status"
add "env: restore the declared-pause verb" env.unset FM_CLASSIFY_PAUSED_VERB
add "classify: the resolved pause verb is the built-in default again" c.pausedverb

add "env: rename the resolution verb" env.set FM_CLASSIFY_RESOLVE_VERB closed
add "classify: the built-in resolution verb no longer closes a decision" \
  c.opendecisions "$STATE/tk1.status"
add "classify: the resolved resolution verb reports the override" c.resolveverb
add "env: restore the resolution verb" env.unset FM_CLASSIFY_RESOLVE_VERB

add "env: rename the captain-held transfer verb" env.set FM_CLASSIFY_CAPTAIN_HELD_VERB transferred
add "classify: the built-in transfer verb no longer closes a decision" \
  c.opendecisions "$STATE/tk1.status"
add "classify: the renamed transfer verb satisfies pause-or-held" \
  c.pausedheld 'transferred: filed'
add "classify: the resolved transfer verb reports the override" c.heldverb
add "env: restore the captain-held transfer verb" env.unset FM_CLASSIFY_CAPTAIN_HELD_VERB

add "classify: the pause re-surface cadence default" c.resurface
add "env: override the pause re-surface cadence" env.set FM_PAUSE_RESURFACE_SECS 900
add "classify: the pause re-surface cadence reports the override" c.resurface
add "env: restore the pause re-surface cadence" env.unset FM_PAUSE_RESURFACE_SECS

# =============================================================================
# Case list - section I: the locale-dependent [[:space:]] class
#
# Measured on this host: grep and bash resolve [[:space:]] against LC_CTYPE and
# agree with each other exactly, so U+00A0 is whitespace under en_GB.UTF-8 and
# is NOT under C. Every fixture below was written ONCE, in the ambient locale,
# so only the CLASSIFIER locale changes here - rebuilding them under C would
# change the bytes and prove nothing.
# =============================================================================

add "classify: a non-breaking space is blank under the ambient UTF-8 locale" \
  c.lastline "$STATE/blank.status"
add "classify: a non-breaking space trims out of a verb under UTF-8" \
  c.verb "${NBSP}done${NBSP}: x"
add "classify: the space set under the ambient locale" c.spaceset

add "env: narrow the locale to C" env.set LC_ALL C
add "classify: under C a non-breaking space is NOT blank, so it wins the tail" \
  c.lastline "$STATE/blank.status"
# DECLARED DIVERGENCE - bash is byte-oriented, PowerShell is character-oriented.
# Under LC_ALL=C bash trims the NBSP SECOND byte (octal 240) while keeping its
# lead byte (octal 302), emitting <NBSP>done+lead - a lone lead byte with no
# continuation, which is not valid UTF-8. A .NET string is UTF-16 and cannot
# hold an unpaired byte, so PowerShell keeps the whole character and emits
# <NBSP>done<NBSP>. PowerShell's result is the well-formed one; byte equality is
# unreachable here by construction, so the divergence is DECLARED, not hidden.
# NOT part of the framed differential: this case cannot travel through it.
# bash emits a LONE lead byte (octal 302) here, and bash `read` in a UTF-8
# locale then treats the following record delimiter as that character's
# continuation byte - the invalid sequence literally EATS the framing and
# merges two records. So the value is checked directly, on the PowerShell side
# only, after the framed comparison below. The bash behaviour is recorded in
# docs/powershell-port.md as an unreachable divergence.
add "classify: under C an ASCII space still trims" c.verb '  done  : x'
add "classify: the space set under C" c.spaceset
add "classify: a file of ASCII blanks is still blank under C" c.lastline "$STATE/empty.status"

add "env: POSIX must resolve exactly as C does" env.set LC_ALL POSIX
add "classify: under POSIX a non-breaking space is NOT blank either" \
  c.lastline "$STATE/blank.status"
add "classify: the space set under POSIX" c.spaceset

add "env: restore the ambient locale" env.unset LC_ALL
add "classify: restoring the locale restores the UTF-8 blank rule" \
  c.lastline "$STATE/blank.status"

# =============================================================================
# Case list - section J: bin/fm-supervision-lib
# =============================================================================

add "supervision: an idle home has nothing in flight" s.inflight "$SUP_IDLE" ''
add "supervision: an idle home needs no watcher" s.neededflag "$SUP_IDLE" ''
add "supervision: an idle home has no beacon" s.beacon "$SUP_IDLE" ''
add "supervision: an idle home has no pending queue" s.queue "$SUP_IDLE" ''
add "supervision: an idle home is not unhealthy" s.unhealthy "$SUP_IDLE" ''
add "supervision: a missing state directory is simply idle" s.inflight "$FIX/nodir" ''

add "supervision: in-flight tasks are counted, dotfiles excluded" s.inflight "$SUP_WORK" ''
add "supervision: in-flight work needs a watcher" s.neededflag "$SUP_WORK" ''
add "supervision: a fresh beacon is fresh" s.fresh "$SUP_WORK" ''
add "supervision: a non-empty wake queue is pending" s.queue "$SUP_WORK" ''
add "supervision: a watched home with a fresh beacon is healthy" s.unhealthy "$SUP_WORK" ''
add "supervision: the needed predicate agrees with the field" s.needed "$SUP_WORK" ''

add "supervision: an old beacon is not fresh" s.fresh "$SUP_STALE" ''
add "supervision: in-flight work plus a stale beacon is the dangerous state" \
  s.unhealthy "$SUP_STALE" ''
add "supervision: an empty wake queue is not pending" s.queue "$SUP_STALE" ''
add "supervision: an explicit grace wide enough revives the old beacon" \
  s.fresh "$SUP_STALE" 999999999
add "supervision: a wide grace also clears the unhealthy verdict" \
  s.unhealthy "$SUP_STALE" 999999999
# A malformed grace must NOT be silently repaired into a default: bash's
# `[ age -lt abc ]` errors and the freshness flag stays false.
add "supervision: a non-numeric grace leaves the watcher NOT fresh" \
  s.fresh "$SUP_STALE" abc

add "supervision: an X-mode relay poll alone needs a watcher" s.neededflag "$SUP_XONLY" ''
add "supervision: an X-mode relay poll alone is never UNHEALTHY" s.unhealthy "$SUP_XONLY" ''
add "supervision: an X-mode-only home has nothing in flight" s.inflight "$SUP_XONLY" ''

add "env: widen the default grace through FM_GUARD_GRACE" env.set FM_GUARD_GRACE 999999999
add "supervision: FM_GUARD_GRACE supplies the default grace" s.fresh "$SUP_STALE" ''
add "env: narrow the default grace through FM_GUARD_GRACE" env.set FM_GUARD_GRACE 1
add "supervision: a narrow FM_GUARD_GRACE stales the beacon" s.fresh "$SUP_STALE" ''
add "supervision: an explicit grace still beats FM_GUARD_GRACE" \
  s.fresh "$SUP_STALE" 999999999
add "env: restore the default grace" env.unset FM_GUARD_GRACE

add "supervision: a pinned mtime reads as the same epoch second in both trees" \
  s.mtime "$MTIME_FILE"
add "supervision: a directory mtime is readable" s.mtime "$SUP_WORK"
add "supervision: a missing path has no mtime" s.mtime "$FIX/nosuchfile"

# The beacon description embeds an age computed from the CURRENT clock, and the
# two drivers run seconds apart, so its digits legitimately differ. The shape is
# compared here, the exact epoch read is compared by s.mtime above, and the two
# ages are separately asserted to be close below - together that covers the
# value without pretending the clock stood still.
add "supervision: the beacon description names an age in seconds" \
  s.beacon "$SUP_WORK" ''
add "supervision: the beacon description of an old beacon" s.beacon "$SUP_STALE" ''

# =============================================================================
# Case list - section K: the stdin form, LAST because it consumes stdin
# =============================================================================

add "classify: the activity fold reads standard input for the dash form" \
  c.activitiesstdin

# =============================================================================
# The bash oracle
# =============================================================================

cat > "$ORACLE" <<'SH'
#!/usr/bin/env bash
# The oracle: sources the three bash libraries and answers the shared case list.
# Deliberately NOT `set -u` - the libraries are written against a live shell
# whose optional knobs may be unset, which is the environment they must work in.

. "$FM_TEST_ROOT/bin/fm-transition-lib.sh"
. "$FM_TEST_ROOT/bin/fm-classify-lib.sh"
. "$FM_TEST_ROOT/bin/fm-supervision-lib.sh"

IDX=0
CAP="$FM_TEST_TMP/oracle.cap"
R=''

emit() { printf '%s\001%s\002' "$IDX" "$1"; }

# Raw capture: the fold and scan functions emit newline-TERMINATED records and
# `$( )` would strip the terminator, so those values are read back through a
# file. `read -d ''` reads to NUL, i.e. the whole file, and returns non-zero at
# EOF while still assigning.
cap() { "$@" > "$CAP" 2>/dev/null; R=''; IFS= read -r -d '' R < "$CAP" || true; }

tf() { if "$@" >/dev/null 2>&1; then printf true; else printf false; fi }

# The case list arrives on fd 3 so the driver's own stdin stays free for the
# one case that reads it.
while IFS=$'\001' read -r -u 3 -d $'\002' op a1 a2 a3 a4 a5 a6 a7 a8 a9; do
  r=''
  case "$op" in
    env.set)   export "$a1=$a2"; r=ok ;;
    env.unset) unset "$a1"; r=ok ;;

    t.record)     r=$(fm_transition_record "$a1" "$a2" "$a3" "$a4" "$a5") ;;
    t.recordtabs) r=$(fm_transition_record "$a1" "$a2" "$a3" "$a4" "$a5" | tr -cd '\t' | wc -c | tr -d '[:space:]') ;;
    t.clean)      r=$(fm_transition_clean_field "$a1") ;;
    t.field)      r=$(fm_transition_field "$a1" "$a2") ;;
    t.pane)       r=$(fm_transition_pane_id "$a1") ;;
    t.ws)         r=$(fm_transition_workspace_id "$a1") ;;
    t.from)       r=$(fm_transition_from_status "$a1") ;;
    t.to)         r=$(fm_transition_to_status "$a1") ;;
    t.agent)      r=$(fm_transition_agent "$a1") ;;
    t.policy)     r=$(fm_transition_policy "$a1") ;;
    t.sep)        r=$(printf '%s' "$FM_TRANSITION_FIELD_SEP") ;;

    c.verb)        r=$(status_line_verb "$a1") ;;
    c.note)        r=$(status_line_note "$a1") ;;
    c.key)         if r=$(_fm_decision_key "$a1"); then :; else r='<refused>'; fi ;;
    c.terminal)    r=$(tf status_is_terminal_verb "$a1") ;;
    c.relevant)    r=$(tf status_is_captain_relevant "$a1") ;;
    c.paused)      r=$(tf status_is_paused "$a1") ;;
    c.pausedheld)  r=$(tf status_is_paused_or_captain_held "$a1") ;;
    c.lastline)    r=$(last_status_line "$a1") ;;

    c.opendecisions)   cap status_open_decisions "$a1"; r=$R ;;
    c.openactivities)  cap status_open_activities "$a1"; r=$R ;;
    c.scan)            cap scan_captain_relevant_statuses "$a1"; r=$R ;;
    c.activitiesstdin) status_open_activities - > "$CAP" 2>/dev/null
                       R=''; IFS= read -r -d '' R < "$CAP" || true; r=$R ;;

    c.windowtask)    r=$(window_to_task "$a1" "$a2") ;;
    c.staleterminal) r=$(tf stale_is_terminal "$a1" "$a2") ;;

    c.absorb)     r=$(crew_absorb_class "$a1") ;;
    c.provably)   r=$(tf crew_is_provably_working "$a1") ;;
    c.crewpaused) r=$(tf crew_is_paused "$a1") ;;
    # The DEFAULT reader is what fm-classify-lib.sh resolves at source time.
    c.absorbdefault)
      _saved=$FM_CREW_STATE_BIN
      FM_CREW_STATE_BIN="$FM_TEST_ROOT/bin/fm-crew-state.sh"
      r=$(crew_absorb_class "$a1")
      FM_CREW_STATE_BIN=$_saved
      ;;

    c.signalact)
      set --
      for v in "$a1" "$a2" "$a3" "$a4"; do [ -n "$v" ] && set -- "$@" "$v"; done
      r=$(tf signal_reason_is_actionable "$@")
      ;;
    c.signalworking)
      set --
      for v in "$a1" "$a2" "$a3" "$a4"; do [ -n "$v" ] && set -- "$@" "$v"; done
      r=$(tf signal_crew_provably_working "$@")
      ;;

    c.captainre)  r=${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT} ;;
    c.pausedverb) r=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT} ;;
    c.resolveverb) r=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT} ;;
    c.heldverb)   r=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT} ;;
    c.resurface)  r=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT} ;;
    # The [[:space:]] class, enumerated by asking bash itself which of a fixed
    # code-point list it currently calls whitespace.
    c.spaceset)
      r=''
      for cp in 0009 000A 000B 000C 000D 0020 0085 00A0 1680 2000 2003 2007 200A 200B 2028 2029 202F 205F 3000 FEFF; do
        ch=$(printf "\\u$cp")
        if [ -z "${ch//[[:space:]]/}" ]; then r="$r$cp,"; fi
      done
      ;;

    s.inflight)   fm_supervision_status "$a1" "$a2" >/dev/null 2>&1; r=$FM_SUP_IN_FLIGHT ;;
    s.neededflag) fm_supervision_status "$a1" "$a2" >/dev/null 2>&1; r=$FM_SUP_NEEDED ;;
    s.fresh)      fm_supervision_status "$a1" "$a2" >/dev/null 2>&1; r=$FM_SUP_WATCHER_FRESH ;;
    s.beacon)     fm_supervision_status "$a1" "$a2" >/dev/null 2>&1; r=$FM_SUP_BEACON_DESC ;;
    s.queue)      fm_supervision_status "$a1" "$a2" >/dev/null 2>&1; r=$FM_SUP_QUEUE_PENDING ;;
    s.needed)     r=$(tf fm_supervision_needed "$a1" "$a2") ;;
    s.unhealthy)  r=$(tf fm_supervision_unhealthy "$a1" "$a2") ;;
    s.mtime)      r=$(fm_sup_stat_mtime "$a1") ;;

    *) r="UNKNOWN-OP:$op" ;;
  esac
  emit "$r"
  IDX=$((IDX + 1))
done 3< "$FM_TEST_CASES"
SH

# =============================================================================
# The PowerShell probe
# =============================================================================
# Quoted here-doc: bash expands nothing in it, so the PowerShell source is
# byte-exact. Paths arrive through the environment rather than by interpolation,
# which keeps every quoting hazard out of the file.

cat > "$PROBE" <<'PS1'
#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $env:FM_TEST_BIN 'fm-transition-lib.psm1') -Force
Import-Module (Join-Path $env:FM_TEST_BIN 'fm-classify-lib.psm1') -Force
Import-Module (Join-Path $env:FM_TEST_BIN 'fm-supervision-lib.psm1') -Force

$FS = [char]1
$RS = [char]2

# Out-of-range indexing is not a case shape here, it is a shorter record, so it
# answers '' rather than tripping StrictMode.
function Get-CaseArg {
    # AllowEmptyString/AllowEmptyCollection are required, not decorative: a
    # record with one empty field arrives here as an EMPTY STRING (see the
    # array-unrolling note at the Split below), and a mandatory [string[]]
    # otherwise refuses to bind it and aborts the whole probe.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Field,
        [Parameter(Mandatory)][int]$Index)
    if ($Index -lt $Field.Count) { return $Field[$Index] }
    return ''
}

function Get-Flag {
    param([Parameter(Mandatory)][bool]$Value)
    if ($Value) { return 'true' }
    return 'false'
}

# The variadic signal helpers take however many non-empty paths a case supplied.
function Get-CaseList {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Field)
    $list = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -le 4; $i++) {
        $v = Get-CaseArg -Field $Field -Index $i
        if (-not [string]::IsNullOrEmpty($v)) { $list.Add($v) }
    }
    return $list.ToArray()
}

$text = [System.IO.File]::ReadAllText($env:FM_TEST_CASES, [System.Text.Encoding]::UTF8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++
    # @(...) is load-bearing: PowerShell UNROLLS a single-element array on
    # assignment, so a record with no field separator would make $f a bare
    # string rather than an array - and every Get-CaseArg call against it would
    # then fail to bind. Forcing array shape keeps a short record a short
    # record instead of a probe-wide crash.
    $f = @($record.Split($FS))
    $op = $f[0]
    $a1 = Get-CaseArg -Field $f -Index 1
    $a2 = Get-CaseArg -Field $f -Index 2
    $a3 = Get-CaseArg -Field $f -Index 3
    $a4 = Get-CaseArg -Field $f -Index 4
    $a5 = Get-CaseArg -Field $f -Index 5
    $result = ''
    try {
        switch ($op) {
            'env.set'   { [Environment]::SetEnvironmentVariable($a1, $a2); $result = 'ok' }
            'env.unset' { [Environment]::SetEnvironmentVariable($a1, $null); $result = 'ok' }

            't.record' {
                $result = New-FmTransitionRecord -PaneId $a1 -WorkspaceId $a2 `
                    -FromStatus $a3 -ToStatus $a4 -Agent $a5
            }
            't.recordtabs' {
                $rec = New-FmTransitionRecord -PaneId $a1 -WorkspaceId $a2 `
                    -FromStatus $a3 -ToStatus $a4 -Agent $a5
                $n = 0
                foreach ($ch in $rec.ToCharArray()) { if ([int]$ch -eq 9) { $n++ } }
                $result = [string]$n
            }
            't.clean'  { $result = Get-FmTransitionCleanField -Value $a1 }
            't.field'  { $result = Get-FmTransitionField -Record $a1 -Index ([int]$a2) }
            't.pane'   { $result = Get-FmTransitionPaneId -Record $a1 }
            't.ws'     { $result = Get-FmTransitionWorkspaceId -Record $a1 }
            't.from'   { $result = Get-FmTransitionFromStatus -Record $a1 }
            't.to'     { $result = Get-FmTransitionToStatus -Record $a1 }
            't.agent'  { $result = Get-FmTransitionAgent -Record $a1 }
            't.policy' { $result = Get-FmTransitionPolicy -ToStatus $a1 }
            't.sep'    { $result = Get-FmTransitionFieldSeparator }

            'c.verb' { $result = Get-FmStatusLineVerb -Line $a1 }
            'c.note' { $result = Get-FmStatusLineNote -Line $a1 }
            'c.key'  {
                $k = Get-FmStatusDecisionKey -Line $a1
                if ($null -eq $k) { $result = '<refused>' } else { $result = $k }
            }
            'c.terminal'   { $result = Get-Flag -Value (Test-FmStatusTerminalVerb -Line $a1) }
            'c.relevant'   { $result = Get-Flag -Value (Test-FmStatusCaptainRelevant -Line $a1) }
            'c.paused'     { $result = Get-Flag -Value (Test-FmStatusPaused -Line $a1) }
            'c.pausedheld' { $result = Get-Flag -Value (Test-FmStatusPausedOrHeld -Line $a1) }
            'c.lastline'   { $result = Get-FmLastStatusLine -Path $a1 }

            'c.opendecisions'   { $result = Get-FmStatusOpenDecisions -Path $a1 }
            'c.openactivities'  { $result = Get-FmStatusOpenActivities -Path $a1 }
            'c.activitiesstdin' { $result = Get-FmStatusOpenActivities -Path '-' }
            'c.scan'            { $result = Get-FmCaptainRelevantStatus -State $a1 }

            'c.windowtask'    { $result = Get-FmWindowTask -Window $a1 -State $a2 }
            'c.staleterminal' { $result = Get-Flag -Value (Test-FmStaleTerminal -Window $a1 -State $a2) }

            'c.absorb'     { $result = Get-FmCrewAbsorbClass -Id $a1 }
            'c.provably'   { $result = Get-Flag -Value (Test-FmCrewProvablyWorking -Id $a1) }
            'c.crewpaused' { $result = Get-Flag -Value (Test-FmCrewPaused -Id $a1) }
            'c.absorbdefault' {
                # Clear the override so resolution goes through Invoke-FmScript,
                # which prefers a .ps1 twin and falls back to the .sh under bash.
                $saved = [Environment]::GetEnvironmentVariable('FM_CREW_STATE_BIN')
                [Environment]::SetEnvironmentVariable('FM_CREW_STATE_BIN', $null)
                try { $result = Get-FmCrewAbsorbClass -Id $a1 }
                finally { [Environment]::SetEnvironmentVariable('FM_CREW_STATE_BIN', $saved) }
            }

            'c.signalact' {
                $result = Get-Flag -Value (Test-FmSignalActionable -Path (Get-CaseList -Field $f))
            }
            'c.signalworking' {
                $result = Get-Flag -Value (Test-FmSignalCrewProvablyWorking -Path (Get-CaseList -Field $f))
            }

            'c.captainre'   { $result = Get-FmClassifyCaptainRegex }
            'c.pausedverb'  { $result = Get-FmClassifyPausedVerb }
            'c.resolveverb' { $result = Get-FmClassifyResolveVerb }
            'c.heldverb'    { $result = Get-FmClassifyCaptainHeldVerb }
            'c.resurface'   { $result = Get-FmClassifyPauseResurfaceInterval }
            'c.spaceset' {
                $set = Get-FmClassifySpaceSet
                $sb = [System.Text.StringBuilder]::new()
                foreach ($cp in @(0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020,
                                  0x0085, 0x00A0, 0x1680, 0x2000, 0x2003, 0x2007,
                                  0x200A, 0x200B, 0x2028, 0x2029, 0x202F, 0x205F,
                                  0x3000, 0xFEFF)) {
                    if ([Array]::IndexOf($set, [char]$cp) -ge 0) {
                        [void]$sb.Append(('{0:X4}' -f $cp)).Append(',')
                    }
                }
                $result = $sb.ToString()
            }

            's.inflight'   { $result = [string](Get-FmSupervisionStatus -State $a1 -Grace $a2).InFlight }
            's.neededflag' { $result = Get-Flag -Value (Get-FmSupervisionStatus -State $a1 -Grace $a2).Needed }
            's.fresh'      { $result = Get-Flag -Value (Get-FmSupervisionStatus -State $a1 -Grace $a2).WatcherFresh }
            's.beacon'     { $result = (Get-FmSupervisionStatus -State $a1 -Grace $a2).BeaconDescription }
            's.queue'      { $result = Get-Flag -Value (Get-FmSupervisionStatus -State $a1 -Grace $a2).QueuePending }
            's.needed'     { $result = Get-Flag -Value (Test-FmSupervisionNeeded -State $a1 -Grace $a2) }
            's.unhealthy'  { $result = Get-Flag -Value (Test-FmSupervisionUnhealthy -State $a1 -Grace $a2) }
            's.mtime' {
                $m = Get-FmSupervisionMtime -Path $a1
                if ($null -eq $m) { $result = '' } else { $result = [string]$m }
            }

            default { $result = "UNKNOWN-OP:$op" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    }
    [void]$out.Append($index).Append($FS).Append($result).Append($RS)
}

[Console]::Out.Write($out.ToString())
PS1

# =============================================================================
# Run both sides, once each
# =============================================================================

# Each side's own clock, captured around ITS OWN run: the beacon assertion
# below reconstructs the mtime each side saw (now - age), and the two runs can
# be many minutes apart on a slow host, so one shared timestamp would describe
# neither of them.
O_NOW=$(date -u +%s)
FM_TEST_ROOT="$ROOT" FM_TEST_CASES="$CASES" FM_TEST_TMP="$TMP_ROOT" \
  bash "$ORACLE" > "$O_RES" 2> "$O_ERR" < "$STDIN_FIX" \
  || fail "the bash oracle exited non-zero:"$'\n'"$(cat "$O_ERR")"

P_NOW=$(date -u +%s)
FM_TEST_BIN="$BIN_N" FM_TEST_CASES="$CASES_N" \
  pwsh -NoProfile -File "$PROBE_N" > "$P_RES" 2> "$P_ERR" < "$STDIN_FIX" \
  || fail "the PowerShell probe exited non-zero:"$'\n'"$(cat "$P_ERR")"

# A clean probe run is also a SILENT one: a module warning (an unapproved verb,
# a shadowed command) surfaces here and must not be tolerated. The bash oracle
# is deliberately NOT held to this - one case drives `[ age -lt abc ]`, whose
# diagnostic is exactly the behavior under test.
[ ! -s "$P_ERR" ] || fail "the PowerShell probe wrote to stderr:"$'\n'"$(cat "$P_ERR")"

O_VAL=()
while IFS=$'\001' read -r -d $'\002' idx val; do
  case $idx in ''|*[!0-9]*) continue ;; esac
  O_VAL[$idx]=$val
done < "$O_RES"

P_VAL=()
while IFS=$'\001' read -r -d $'\002' idx val; do
  case $idx in ''|*[!0-9]*) continue ;; esac
  P_VAL[$idx]=$val
done < "$P_RES"

# =============================================================================
# Compare
# =============================================================================

CASE_COUNT=${#LABELS[@]}
i=0
while [ "$i" -lt "$CASE_COUNT" ]; do
  label=${LABELS[$i]}
  ob=${O_VAL[$i]-<<MISSING>>}
  pb=${P_VAL[$i]-<<MISSING>>}
  case "$label" in
    "supervision: the beacon description"*)
      # Declared normalization, applied to exactly two labels: the digits are a
      # live clock reading and the two drivers run seconds apart. The shape,
      # the exact mtime read (s.mtime) and the freshness verdict together cover
      # the value; the ages themselves are compared numerically below.
      case "$ob" in *"s ago") ob='<n>s ago' ;; esac
      case "$pb" in *"s ago") pb='<n>s ago' ;; esac
      ;;
  esac
  if [ "${IS_DIV[$i]}" = 1 ]; then
    assert_same "$label [bash side]" "${DIV_BASH[$i]}" "$ob"
    assert_same "$label [PowerShell side]" "${DIV_PS[$i]}" "$pb"
  else
    assert_same "$label" "$ob" "$pb"
  fi
  i=$((i + 1))
done

# The beacon ages themselves, compared numerically rather than byte-for-byte:
# the two drivers read the clock at different moments, so the assertion is that
# they describe the SAME beacon, not that time stood still. A twin that computed
# the age from local time instead of UTC would be an hour out and fail here.
#
# The comparison is anchored to the BEACON, not to a fixed drift window. age is
# `now - mtime`, so `now - age` recovers the mtime each side actually saw - a
# stable fact that must match regardless of WHEN each side measured. The
# original form compared the two ages against a 300s tolerance, which is ample
# on Linux (the suite runs in about a minute) but wrong here: this suite takes
# ~40 minutes on Windows, so the two measurements were legitimately 513s apart
# and a correct twin was reported as drifted. Widening the window instead would
# have been worse - an hour-wide tolerance cannot detect the local-vs-UTC error
# this assertion exists to catch, which is exactly one hour.
BEACON_TOLERANCE=2
beacon_index=-1
i=0
while [ "$i" -lt "$CASE_COUNT" ]; do
  case "${LABELS[$i]}" in
    "supervision: the beacon description of an old beacon") beacon_index=$i; break ;;
  esac
  i=$((i + 1))
done
[ "$beacon_index" -ge 0 ] || fail "the beacon-age case disappeared from the case list"
ob=${O_VAL[$beacon_index]-}
pb=${P_VAL[$beacon_index]-}
o_age=${ob%%s*}
p_age=${pb%%s*}
case "$o_age$p_age" in
  ''|*[!0-9]*)
    # Non-numeric on both sides is AGREEMENT, not a failure: a beacon that does
    # not exist reads as "never" in both trees, and that is the two trees
    # computing the same thing - which is all this assertion claims. Only a
    # genuine disagreement (or one side numeric and the other not) is a fault.
    if [ "$ob" = "$pb" ]; then
      age_close=close
    else
      age_close="not two comparable ages: [$ob] [$pb]"
    fi
    ;;
  *)
    # Recover the mtime each side observed: mtime = its own now - its own age.
    # Those two mtimes describe one unchanging file, so they must agree within
    # rounding regardless of how far apart the measurements were taken.
    o_mtime=$((O_NOW - o_age))
    p_mtime=$((P_NOW - p_age))
    if [ $((o_mtime - p_mtime)) -le "$BEACON_TOLERANCE" ] &&
       [ $((p_mtime - o_mtime)) -le "$BEACON_TOLERANCE" ]; then
      age_close=close
    else
      age_close="drifted: bash saw mtime=$o_mtime (age $o_age at $O_NOW), pwsh saw mtime=$p_mtime (age $p_age at $P_NOW)"
    fi
    ;;
esac
assert_same "supervision: both trees compute the same beacon age (UTC, whole seconds)" \
  close "$age_close"

# =============================================================================
# Import hygiene - what a batched probe cannot observe about itself
# =============================================================================

for lib in fm-transition-lib fm-classify-lib fm-supervision-lib; do
  mod_n=$(fm_test_native_path "$ROOT/bin/$lib.psm1")
  import_out=$(pwsh -NoProfile -Command "Import-Module '$mod_n' -Force" 2>&1)
  assert_same "$lib.psm1: importing the module is silent" '' "$import_out"
done

# None of these may evict a caller's own fm-common. A nested `Import-Module
# -Force` does exactly that - verified live during the composer conversion - and
# every real consumer (fm-watch, fm-supervise-daemon) imports fm-common itself.
COMMON_N=$(fm_test_native_path "$ROOT/bin/fm-common.psm1")
CLASSIFY_N=$(fm_test_native_path "$ROOT/bin/fm-classify-lib.psm1")
SUPERVISION_N=$(fm_test_native_path "$ROOT/bin/fm-supervision-lib.psm1")
coexist_out=$(pwsh -NoProfile -Command \
  "Import-Module '$COMMON_N' -Force; Import-Module '$CLASSIFY_N' -Force; Import-Module '$SUPERVISION_N' -Force; [Console]::Out.Write([string][bool](Get-Command Write-FmOut -ErrorAction SilentlyContinue))" 2>&1)
assert_same "importing these modules leaves a caller's fm-common loaded" 'True' "$coexist_out"

# =============================================================================
# Report
# =============================================================================

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W2-classify PowerShell twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The floor is the exact total this file produces:
# dropping a case - by deleting it, or through a bookkeeping regression that
# stops recording it - fails loudly instead of certifying a shorter run.
# The NBSP-under-C verb trim, checked directly because it cannot travel through
# the framed differential (see the note where its framed case used to live).
# Only the PowerShell side is asserted: bash emits an invalid UTF-8 fragment
# there, which a .NET string cannot represent by construction. What matters is
# that the PowerShell twin does NOT trim a non-breaking space under LC_ALL=C -
# .NET String.Trim() WOULD (it treats U+00A0 as whitespace), so this guards the
# locale-aware space set that exists precisely to prevent that.
NBSP_COMMON_N=$(fm_test_native_path "$ROOT/bin/fm-common.psm1")
NBSP_CLASSIFY_N=$(fm_test_native_path "$ROOT/bin/fm-classify-lib.psm1")
nbsp_verb=$(LC_ALL=C pwsh -NoProfile -Command "
  Import-Module '$NBSP_COMMON_N' -Force
  Import-Module '$NBSP_CLASSIFY_N' -Force
  \$nb = [char]0x00A0
  Write-FmRaw (Get-FmStatusLineVerb -Line (\$nb + 'done' + \$nb + ': x'))" 2>/dev/null)
assert_same "classify: PowerShell does not trim a non-breaking space under C" \
  "${NBSP}done${NBSP}" "$nbsp_verb"

MIN_ASSERTIONS=249
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-transition-lib.psm1, fm-classify-lib.psm1 and fm-supervision-lib.psm1 match their bash oracles across %d assertions\n' \
  "$ASSERTIONS"
printf '# fm-classify-libs-psm1.test.sh: all assertions passed\n'
