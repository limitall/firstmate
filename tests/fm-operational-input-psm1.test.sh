#!/usr/bin/env bash
# Behavior test for bin/fm-operational-input.psm1 + bin/fm-operational-input.ps1
# - the PowerShell twin of the canonical operational-input protocol
# (bin/fm-operational-input.sh).
#
# DIFFERENTIAL: every case drives the bash function and the PowerShell function
# with byte-identical input and asserts byte-identical output. BASH IS THE
# ORACLE, so no expectation below encodes what the author believed the protocol
# does instead of what the shipped owner does.
#
# WHY THIS ONE MATTERS MORE THAN A ROUTINE PORT TEST. This protocol is how
# firstmate tells its OWN injected input apart from a real captain message. A
# twin that accepts one byte too loosely reads a captain sentence as an internal
# escalation and never exits away mode; a twin that accepts one byte too tightly
# reads firstmate's own session-start digest as the captain talking to it. So
# the REJECTIONS are tested as hard as the acceptances, and each near miss is
# asserted twice: once differentially, and once against the oracle itself, so a
# day when bash starts ACCEPTING one cannot pass merely because both sides
# agreed.
#
# THREE THINGS THIS SUITE IS BUILT AROUND
#
# 1. ONE pwsh FOR ~230 ASSERTIONS. A bare `pwsh -NoProfile -Command "exit 0"`
#    costs 4.8s on this host - interpreter startup, not module import - so a
#    pwsh call per case would be 20 minutes of startup before the first
#    comparison, and because this suite buffers its verdict to the end that
#    presents as a HANG rather than as slowness. Every in-process case is
#    therefore written to a case FILE, evaluated by ONE driver, and returned as
#    `index<TAB-equivalent>result`. Cases are keyed by INDEX, never by a path or
#    a fixture string: the two worlds spell paths differently, and a key that
#    cannot match makes every case read as MISSING rather than as a mismatch.
#
#    The end-to-end CLI phase cannot be batched - argv, stdin, exit code and the
#    stdout/stderr split are properties of a PROCESS - so it is a fixed budget of
#    NINE spawns, listed and justified at that phase. Nine, not "one per case",
#    is what keeps this suite finishing.
#
# 2. THE BASH ORACLE SIDE IS FORK-FREE. Every protocol function publishes
#    through `printf -v`, so it is called directly and its answer read from a
#    variable - no `$( ... )`, which would fork a subshell per case, and an MSYS
#    fork is the dominant cost in this tree. The case file is appended with
#    redirected `printf`, also a builtin.
#
# 3. FIELD 0x01, RECORD 0x02. Two bytes that appear in no fixture, so every
#    value crosses the boundary as RAW BYTES - the U+2063 marker, embedded
#    newlines, and a zero-width space all arrive unencoded. The comparison is
#    byte-exact by construction, and the fact that the results come back through
#    a UTF-8 file proves the marker survives the round trip in both directions.
#
# Nothing here runs inside a `( ... )` subshell: a subshell cannot report a
# failure back to the parent's counters, so a bookkeeping scheme that can LOSE a
# failure is worse than none. The assertion COUNT is itself asserted at the end,
# so a suite that silently ran nothing cannot read as a pass.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

SH_OWNER="$ROOT/bin/fm-operational-input.sh"
PS_OWNER="$ROOT/bin/fm-operational-input.ps1"
MOD="$ROOT/bin/fm-operational-input.psm1"
COMMON="$ROOT/bin/fm-common.psm1"
[ -f "$MOD" ] || fail "bin/fm-operational-input.psm1 is missing"
[ -f "$PS_OWNER" ] || fail "bin/fm-operational-input.ps1 is missing (the hybrid's executable half)"
[ -f "$COMMON" ] || fail "bin/fm-common.psm1 is missing (this module builds on it)"

# The oracle.
# shellcheck source=bin/fm-operational-input.sh
. "$SH_OWNER"

TMP_ROOT=$(fm_test_tmproot fm-opinput-psm1)

# PowerShell cannot resolve MSYS paths (.NET reads /tmp/x as C:\tmp\x), so EVERY
# path handed to pwsh - including the Import-Module paths - is converted first.
# fm_test_native_path is a no-op off Windows.
MOD_N=$(fm_test_native_path "$MOD")
COMMON_N=$(fm_test_native_path "$COMMON")
PS_OWNER_N=$(fm_test_native_path "$PS_OWNER")
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_N=$(fm_test_native_path "$DRIVER")
CASES="$TMP_ROOT/cases.bin"
CASES_N=$(fm_test_native_path "$CASES")
RESULTS="$TMP_ROOT/results.bin"
RESULTS_N=$(fm_test_native_path "$RESULTS")
DRIVER_OUT="$TMP_ROOT/driver.out"
DRIVER_ERR="$TMP_ROOT/driver.err"
CAP="$TMP_ROOT/oracle.out"
B_OUT="$TMP_ROOT/bash.out"
B_ERR="$TMP_ROOT/bash.err"
P_OUT="$TMP_ROOT/pwsh.out"
P_ERR="$TMP_ROOT/pwsh.err"
STDIN_EMPTY="$TMP_ROOT/stdin.empty"
STDIN_BODY="$TMP_ROOT/stdin.body"
STDIN_TRAILNL="$TMP_ROOT/stdin.trailnl"

# The sentinel for "this function refused". Distinct from an empty string
# because the bash contract distinguishes "returned 0 with an empty result" from
# "returned non-zero", and flattening the two would hide exactly the failures
# this suite exists to catch. No fixture below contains it.
NULLTOK='<null>'

# --- assertion bookkeeping ----------------------------------------------------

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected> <actual>
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    # %q renders the invisible bytes these values are full of (U+2063 becomes
    # $'\342\201\243'), and it is a builtin, so a failure message costs nothing
    # on the passing path.
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): $(printf '%q' "$expected")
  actual(pwsh)  : $(printf '%q' "$actual")
"
  fi
}

# --- fixtures -----------------------------------------------------------------
#
# Built from the OWNER's own constants wherever the protocol defines them, so a
# fixture cannot drift from the thing it is testing, and from octal escapes for
# anything the owner does not define - keeping this file pure ASCII, which
# matters because several cases exist precisely to prove an invisible character
# survived intact. A fixture that had itself been mangled by an editor or a
# patch tool would silently weaken exactly those cases.
MARK=$FM_OPERATIONAL_MARK
PREFIX=$FM_OPERATIONAL_PREFIX
HEADER=$FM_OPERATIONAL_HEADER_PREFIX
FFMARK=$FM_FROMFIRST_MARK
LF=$'\n'
ZWSP=$(printf '\342\200\213')   # U+200B, ignorable under a culture-sensitive compare
NBSP=$(printf '\302\240')       # U+00A0

CURRENT_KINDS='session-start watcher turn-end-guard away-supervisor launch-brief'

# --- fork-free oracle capture -------------------------------------------------

ORACLE=''

# Slurp $CAP into ORACLE. `read -d ''` reads to NUL, i.e. the whole file, and
# returns non-zero at EOF while still assigning - hence `|| true`.
read_cap() {
  ORACLE=''
  IFS= read -r -d '' ORACLE < "$CAP" || true
}

# --- batch machinery ----------------------------------------------------------
#
# LABELS and EXPECT are parallel arrays indexed by the record ordinal, which is
# also the key the driver returns. Every add_* helper appends exactly one record
# and exactly one expectation, in lockstep.
LABELS=()
EXPECT=()

# add_record <label> <expected> <op> <field>...
add_record() {
  local label=$1 expected=$2 op=$3 field
  shift 3
  LABELS+=("$label")
  EXPECT+=("$expected")
  printf '%s' "$op" >> "$CASES"
  for field in "$@"; do printf '\001%s' "$field" >> "$CASES"; done
  printf '\002' >> "$CASES"
}

add_const() {  # <bash-variable-name> <bash-value>
  add_record "constant $1" "$2" const "$1"
}

add_kindcur() {  # <label> <kind>
  local answer=no
  fm_operational_kind_is_current "$2" && answer=yes
  add_record "kind-is-current: $1" "$answer" kindcur "$2"
}

add_encode() {  # <label> <kind> <body>
  local out=''
  if fm_operational_input_encode "$2" "$3" out 2>/dev/null; then
    add_record "encode: $1" "$out" encode "$2" "$3"
  else
    add_record "encode: $1" "$NULLTOK" encode "$2" "$3"
  fi
}

add_construct() {  # <label> <kind> <body>
  local out=''
  if fm_operational_input_construct "$2" "$3" out 2>/dev/null; then
    add_record "construct: $1" "$out" construct "$2" "$3"
  else
    add_record "construct: $1" "$NULLTOK" construct "$2" "$3"
  fi
}

add_generic() {  # <label> <message>
  local out=''
  if fm_operational_generic_kind "$2" out 2>/dev/null; then
    add_record "generic-kind: $1" "$out" generic "$2"
  else
    add_record "generic-kind: $1" "$NULLTOK" generic "$2"
  fi
}

# ORACLE_LAST carries the bash answer of the most recent add_kind/add_body/
# add_classify call out to the caller, so a caller can make a GROUND-TRUTH
# assertion about it (e.g. "the oracle really does still reject this") without
# invoking the oracle a second time.
ORACLE_LAST=''

add_kind() {  # <label> <message>
  local out=''
  if fm_operational_input_kind "$2" out 2>/dev/null; then ORACLE_LAST=$out; else ORACLE_LAST=$NULLTOK; fi
  add_record "input-kind: $1" "$ORACLE_LAST" kind "$2"
}

add_body() {  # <label> <message>
  local out=''
  if fm_operational_input_body "$2" out 2>/dev/null; then ORACLE_LAST=$out; else ORACLE_LAST=$NULLTOK; fi
  add_record "input-body: $1" "$ORACLE_LAST" body "$2"
}

add_legacy() {  # <label> <message>
  local out=''
  if fm_legacy_operational_input_kind "$2" out 2>/dev/null; then ORACLE_LAST=$out; else ORACLE_LAST=$NULLTOK; fi
  add_record "legacy-kind: $1" "$ORACLE_LAST" legacy "$2"
}

add_classify() {  # <label> <message>
  local out=''
  if fm_operational_input_classify "$2" out 2>/dev/null; then ORACLE_LAST=$out; else ORACLE_LAST=$NULLTOK; fi
  add_record "classify: $1" "$ORACLE_LAST" classify "$2"
}

add_isfrom() {  # <label> <message>
  local answer=no
  fm_message_from_firstmate "$2" && answer=yes
  add_record "from-firstmate?: $1" "$answer" isfrom "$2"
}

add_mark() {  # <label> <message>
  local out=''
  fm_message_mark_from_firstmate "$2" out 2>/dev/null || out=$NULLTOK
  add_record "mark-from-firstmate: $1" "$out" mark "$2"
}

# add_main <label> <arg>...: the CLI dispatcher, in-process on both sides.
#
# ONLY commands that write nothing to either stream belong here - the driver
# asserts its own stdout and stderr are empty, and a usage dump would break
# that. The --help and unknown-command paths, whose whole point is WHICH stream
# they write to, are covered by the end-to-end phase instead.
#
# Both sides read stdin from /dev/null, so a case that unexpectedly reaches the
# stdin read behaves identically instead of hanging on a terminal.
add_main() {
  local label=$1 rc n
  shift
  n=$#
  fm_operational_main "$@" </dev/null >/dev/null 2>&1
  rc=$?
  add_record "cli-main: $label" "rc=$rc" main "$n" "$@"
}

# A genuine near miss: something a captain could plausibly type or quote that
# must NEVER be read as firstmate's own input. Asserted twice - differentially,
# and against the oracle - so this cannot pass by both sides agreeing to accept.
add_nearmiss() {  # <label> <fixture>
  local current=''
  add_classify "near miss - $1" "$2"
  # The near-miss property is that the CURRENT TYPED grammar refuses the
  # fixture - that is the security boundary, because a typed kind is what makes
  # firstmate treat input as its own internal escalation rather than as the
  # captain speaking.
  #
  # It is deliberately NOT asserted against fm_operational_input_classify: that
  # entrypoint falls back to the legacy parser, and a fixture still carrying the
  # untyped FIRSTMATE_OP prefix (PR 899) is classified generic
  # legacy-operational BY DESIGN - verified directly against the bash oracle.
  # Asserting "unclassified" there claimed something bash does not do, and the
  # resulting failure looked like a PowerShell defect while both languages in
  # fact agreed. The bash-vs-PowerShell comparison for the classify path still
  # happens, through the record add_classify just queued.
  if ! fm_operational_input_kind "$2" current 2>/dev/null; then
    current=$NULLTOK
  fi
  assert_same "near miss is refused by the CURRENT typed grammar - $1" "$NULLTOK" "$current"
}

# --- the PowerShell driver ----------------------------------------------------
#
# Quoted here-doc: bash expands nothing in it, so the PowerShell source is
# byte-exact. Paths arrive through the environment rather than through
# interpolation, which keeps every quoting hazard out of the file. Those four
# variables are CONSTANT for the whole run - there is no per-case environment
# here, which is the one shape of the "prefix assignment does not survive the
# batch" trap this suite could have hit.
#
# Results go to a FILE, not to stdout, so the driver's own stdout and stderr
# stay empty and can themselves be asserted: a module that printed a warning on
# import, or a CLI case that wrote where it should not, surfaces there.
cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_COMMON -Force
Import-Module $env:FM_PSM1 -Force

$FS = [char]1
$RS = [char]2
$NULLTOK = '<null>'
$utf8 = [System.Text.UTF8Encoding]::new($false)

$text = [System.IO.File]::ReadAllText($env:FM_CASES, $utf8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++

    # @( ) around Split: PowerShell unrolls a single-element array into a bare
    # string, and the fixed-width copy below would then index its CHARACTERS.
    $parts = @($record.Split($FS))
    $f = [string[]]::new(10)
    for ($i = 0; $i -lt 10; $i++) {
        $f[$i] = if ($i -lt $parts.Count) { [string]$parts[$i] } else { '' }
    }

    $result = ''
    try {
        switch -CaseSensitive ($f[0]) {
            'const'     { $result = Get-FmOperationalConstant -Name $f[1] }
            'kindcur'   { $result = if (Test-FmOperationalKindIsCurrent -Kind $f[1]) { 'yes' } else { 'no' } }
            'encode'    { $result = ConvertTo-FmOperationalInput -Kind $f[1] -Body $f[2] }
            'construct' { $result = ConvertTo-FmOperationalMessage -Kind $f[1] -Body $f[2] }
            'generic'   { $result = Get-FmOperationalGenericKind -Message $f[1] }
            'kind'      { $result = Get-FmOperationalInputKind -Message $f[1] }
            'body'      { $result = Get-FmOperationalInputBody -Message $f[1] }
            'legacy'    { $result = Get-FmLegacyOperationalInputKind -Message $f[1] }
            'classify'  { $result = Get-FmOperationalInputClassification -Message $f[1] }
            'isfrom'    { $result = if (Test-FmMessageFromFirstmate -Message $f[1]) { 'yes' } else { 'no' } }
            'mark'      { $result = Add-FmFromFirstmateMark -Message $f[1] }
            'usage'     { $result = (@(Get-FmOperationalUsage) -join "`n") + "`n" }
            'main' {
                # Arity is the thing under test, so the record carries the exact
                # argument COUNT: a fixed-width field array cannot otherwise tell
                # `encode` (one argument) from `encode ''` (two).
                $n = [int]$f[1]
                $argv = [string[]]::new($n)
                for ($i = 0; $i -lt $n; $i++) { $argv[$i] = $f[$i + 2] }
                $result = 'rc=' + (Invoke-FmOperationalMain -Arguments $argv)
            }
            default { $result = "UNKNOWN-OP:$($f[0])" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    }
    if ($null -eq $result) { $result = $NULLTOK }

    [void]$out.Append($index).Append($FS).Append([string]$result).Append($RS)
}

[System.IO.File]::WriteAllText($env:FM_RESULTS, $out.ToString(), $utf8)
PS1

export FM_COMMON="$COMMON_N" FM_PSM1="$MOD_N" FM_CASES="$CASES_N" FM_RESULTS="$RESULTS_N"

: > "$CASES"

# =============================================================================
# 1. The wire vocabulary, byte for byte.
# =============================================================================
#
# Every public constant the bash library defines. These are the bytes the whole
# protocol is built from, so they are compared before anything that uses them -
# a mismatch here would make every later case fail for one reason.
add_const FM_OPERATIONAL_MARK "$FM_OPERATIONAL_MARK"
add_const FM_OPERATIONAL_PREFIX "$FM_OPERATIONAL_PREFIX"
add_const FM_OPERATIONAL_VERSION "$FM_OPERATIONAL_VERSION"
add_const FM_OPERATIONAL_HEADER_PREFIX "$FM_OPERATIONAL_HEADER_PREFIX"
add_const FM_OPERATIONAL_KINDS "$FM_OPERATIONAL_KINDS"
add_const FM_INJECT_MARK "$FM_INJECT_MARK"
add_const FM_FROMFIRST_LABEL "$FM_FROMFIRST_LABEL"
add_const FM_FROMFIRST_SEPARATOR "$FM_FROMFIRST_SEPARATOR"
add_const FM_FROMFIRST_MARK "$FM_FROMFIRST_MARK"
add_const FM_LEGACY_SESSIONSTART "$FM_LEGACY_SESSIONSTART"
add_const FM_LEGACY_WATCHER_PREFIX "$FM_LEGACY_WATCHER_PREFIX"
add_const FM_LEGACY_WATCHER_SUFFIX "$FM_LEGACY_WATCHER_SUFFIX"
add_const FM_LEGACY_TURNEND_PREFIX "$FM_LEGACY_TURNEND_PREFIX"
add_const FM_LEGACY_AWAY_PREFIX "$FM_LEGACY_AWAY_PREFIX"

# The usage text, which is a CLI surface contract (docs/powershell-port.md
# contract 4) and is therefore compared as bytes, blank line and column
# alignment included, rather than eyeballed.
fm_operational_usage > "$CAP"
read_cap
add_record "usage text is byte-identical" "$ORACLE" usage

# =============================================================================
# 2. Current construction kinds.
# =============================================================================
for k in $CURRENT_KINDS; do
  add_kindcur "$k is current" "$k"
done
add_kindcur "from-firstmate is NOT a generic construction kind" from-firstmate
add_kindcur "legacy-operational is not current" legacy-operational
add_kindcur "empty kind" ''
add_kindcur "unknown kind" bogus
add_kindcur "truncated kind" watch
add_kindcur "kind with a trailing space" 'watcher '
add_kindcur "kind with a leading space" ' watcher'
add_kindcur "wrong case" WATCHER
# The bash membership test is a SUBSTRING test over a space-padded list, so an
# adjacent RUN of list members is accepted. Nothing constructs one, but a twin
# that reached for real set membership would answer differently on input the
# owner accepts - and only a differential case can catch that.
add_kindcur "adjacent run of two kinds (the substring quirk)" 'watcher turn-end-guard'

# =============================================================================
# 3. Construction: what the current protocol emits, and what it refuses.
# =============================================================================
for k in $CURRENT_KINDS; do
  add_encode "$k" "$k" "CURRENT_BODY_FOR_${k}"
  add_construct "$k routes to the generic envelope" "$k" "CURRENT_BODY_FOR_${k}"
done

# Refusals. Each is a way the current wire could be polluted, and each must
# fail rather than emit something a parser would later accept.
add_encode "a legacy kind is not a current producer kind" legacy-operational body
add_encode "from-firstmate is refused by the GENERIC encoder" from-firstmate body
add_encode "an unknown kind" bogus body
add_encode "an empty kind" '' body
add_encode "an empty body" watcher ''
add_construct "an empty body, for a generic kind" watcher ''
add_construct "an empty body, for from-firstmate" from-firstmate ''
add_construct "an empty body, for an unknown kind" bogus ''
add_construct "an unknown kind" bogus body

# Bodies that stress the grammar rather than the vocabulary.
add_encode "a body containing the field separator ': '" watcher 'step 1: do the thing'
add_encode "a body with a trailing newline" watcher "line one${LF}"
add_encode "a multi-line body" watcher "first${LF}second${LF}third"
add_encode "a body that itself contains the marker" watcher "quoting ${MARK} inline"
add_encode "a body that is itself a full envelope" watcher "${HEADER}watcher: inner"
add_encode "a body of a single space" watcher ' '
add_encode "a body with leading and trailing spaces" watcher '  padded  '
add_encode "a body containing a zero-width space" watcher "zero${ZWSP}width"
add_encode "a body containing a non-breaking space" watcher "non${NBSP}breaking"

# =============================================================================
# 4. Parsing: every current envelope round-trips to its exact kind and body.
# =============================================================================
for k in $CURRENT_KINDS; do
  body="CURRENT_BODY_FOR_${k}"
  fm_operational_input_encode "$k" "$body" encoded || fail "could not encode the $k fixture with the oracle"
  add_generic "$k" "$encoded"
  add_kind "$k" "$encoded"
  add_body "$k" "$encoded"
  # Ground truth on the ORACLE side too: the body that comes back is the body
  # that went in. A purely differential pair could agree on a mangled body.
  assert_same "round trip: the oracle recovers the exact $k body" "$body" "$ORACLE_LAST"
  add_classify "$k envelope" "$encoded"
done

# Bodies whose bytes are the interesting part survive the round trip intact.
fm_operational_input_encode watcher "line one${LF}" enc_trailnl || fail "could not encode the trailing-newline fixture"
add_body "a trailing newline is preserved, not trimmed" "$enc_trailnl"
assert_same "round trip: the oracle preserves the trailing newline" "line one${LF}" "$ORACLE_LAST"

fm_operational_input_encode watcher 'step 1: do the thing' enc_colon || fail "could not encode the colon-body fixture"
add_kind "a body containing ': ' does not confuse the kind split" "$enc_colon"
add_body "a body containing ': ' is returned whole" "$enc_colon"
assert_same "round trip: the oracle returns the colon body whole" 'step 1: do the thing' "$ORACLE_LAST"

fm_operational_input_encode watcher "${HEADER}watcher: inner" enc_nested || fail "could not encode the nested fixture"
add_kind "a nested envelope parses as the OUTER kind" "$enc_nested"
add_body "a nested envelope returns the inner envelope as its body" "$enc_nested"

fm_operational_input_encode watcher '  padded  ' enc_pad || fail "could not encode the padded fixture"
add_body "a padded body keeps its padding" "$enc_pad"

# =============================================================================
# 5. The established from-firstmate carrier.
# =============================================================================
fm_message_mark_from_firstmate 'corr=0123456789abcdef inspect the report' ff_marked
add_mark "an unmarked message gains the carrier" 'corr=0123456789abcdef inspect the report'
add_mark "marking is idempotent" "$ff_marked"
add_mark "an EMPTY message yields the bare carrier (which is not a valid input)" ''
add_kind "the carrier is structurally typed" "$ff_marked"
add_body "the carrier's body is recovered exactly" "$ff_marked"
assert_same "round trip: the oracle recovers the exact carrier body" \
  'corr=0123456789abcdef inspect the report' "$ORACLE_LAST"
add_classify "the carrier classifies" "$ff_marked"
add_isfrom "a marked message is from firstmate" "$ff_marked"
add_isfrom "an unmarked message is not" 'inspect the report'
add_isfrom "a generic envelope is not from-firstmate" "$encoded"
add_isfrom "the bare carrier with nothing after it is not" "$FFMARK"
add_construct "from-firstmate constructs the carrier" from-firstmate 'inspect the report'
add_construct "from-firstmate construction is idempotent" from-firstmate "$ff_marked"

# =============================================================================
# 6. Historical prose compatibility, isolated from current parsing.
# =============================================================================
LEGACY_WATCHER="${FM_LEGACY_WATCHER_PREFIX}signal: legacy${FM_LEGACY_WATCHER_SUFFIX}"
LEGACY_TURNEND="${FM_LEGACY_TURNEND_PREFIX}watcher: FAILED - legacy"
LEGACY_AWAY="${FM_LEGACY_AWAY_PREFIX}1 event(s)): done: legacy"
UNTYPED="${PREFIX}body whose historical subtype is unknowable"

add_legacy "the session-start instruction" "$FM_LEGACY_SESSIONSTART"
add_legacy "the watcher envelope" "$LEGACY_WATCHER"
add_legacy "the turn-end-guard prefix" "$LEGACY_TURNEND"
add_legacy "the away-supervisor prefix" "$LEGACY_AWAY"
add_legacy "the untyped FIRSTMATE_OP prefix PR 899 landed" "$UNTYPED"

# Each historical fixture must be REFUSED by the current parser: that isolation
# is what stops a persisted transcript from being replayed as current input.
add_kind "the session-start instruction must not reach the current parser" "$FM_LEGACY_SESSIONSTART"
assert_same "isolation: the oracle refuses legacy session-start currently" "$NULLTOK" "$ORACLE_LAST"
add_kind "the watcher envelope must not reach the current parser" "$LEGACY_WATCHER"
assert_same "isolation: the oracle refuses the legacy watcher envelope currently" "$NULLTOK" "$ORACLE_LAST"
add_kind "the turn-end prefix must not reach the current parser" "$LEGACY_TURNEND"
assert_same "isolation: the oracle refuses the legacy turn-end prefix currently" "$NULLTOK" "$ORACLE_LAST"
add_kind "the away prefix must not reach the current parser" "$LEGACY_AWAY"
assert_same "isolation: the oracle refuses the legacy away prefix currently" "$NULLTOK" "$ORACLE_LAST"
add_kind "the untyped prefix must not reach the current parser" "$UNTYPED"
assert_same "isolation: the oracle refuses the untyped prefix currently" "$NULLTOK" "$ORACLE_LAST"

# ...and the classifier must reach them anyway, with the right answer. The ORDER
# is what makes this work: every current envelope also begins with the untyped
# prefix, so a classifier that tried legacy first would flatten every typed
# input to legacy-operational.
add_classify "legacy session-start" "$FM_LEGACY_SESSIONSTART"
add_classify "legacy watcher envelope" "$LEGACY_WATCHER"
add_classify "legacy turn-end prefix" "$LEGACY_TURNEND"
add_classify "legacy away prefix" "$LEGACY_AWAY"
add_classify "the untyped prefix stays explicitly legacy-operational" "$UNTYPED"

# The watcher envelope's length rule: prefix and suffix with NOTHING between
# them is not a watcher wake. bash commits to that `case` arm and refuses inside
# it rather than falling through to the turn-end arm, so this also pins the
# no-fall-through behavior.
add_legacy "an EMPTY watcher envelope is not a watcher wake" \
  "${FM_LEGACY_WATCHER_PREFIX}${FM_LEGACY_WATCHER_SUFFIX}"
add_legacy "a bare turn-end prefix with nothing after it" "$FM_LEGACY_TURNEND_PREFIX"
add_legacy "a bare untyped prefix with nothing after it" "$PREFIX"
add_legacy "the bare away prefix (which allows an empty tail)" "$FM_LEGACY_AWAY_PREFIX"
add_legacy "a one-character watcher envelope" \
  "${FM_LEGACY_WATCHER_PREFIX}x${FM_LEGACY_WATCHER_SUFFIX}"

# =============================================================================
# 7. Genuine near misses. Every one must stay UNCLASSIFIED.
# =============================================================================
#
# The nine from tests/fm-operational-input.test.sh, plus the grammar edges that
# suite does not reach - each one a way a twin could be a byte too permissive.
add_nearmiss "a captain quoting a current envelope" "Captain quote: ${HEADER}watcher"
add_nearmiss "the ASCII prefix with no marker at all" 'FIRSTMATE_OP: v1 watcher'
add_nearmiss "arbitrary captain text that happens to carry the marker" "$MARK arbitrary captain text"
add_nearmiss "a captain quoting the legacy session-start line" "Captain quote: $FM_LEGACY_SESSIONSTART"
add_nearmiss "the legacy session-start line with a question appended" \
  "${FM_LEGACY_SESSIONSTART} Please explain this sentence."
add_nearmiss "a captain asking about the watcher wake wording" \
  'FIRSTMATE WATCHER WAKE: can you explain this phrase?'
add_nearmiss "a captain asking about the turn-end wording" \
  'TURN WOULD END BLIND - can you make this warning friendlier?'
add_nearmiss "a captain asking about the escalation wording" \
  'Supervisor escalate (1 event(s)): is this wording clear?'
add_nearmiss "the from-firstmate LABEL without its separator" \
  '[fm-from-firstmate] inspect this visible label'
add_nearmiss "the bare from-firstmate carrier with nothing after it" "$FFMARK"
add_nearmiss "the bare marker alone" "$MARK"
add_nearmiss "an empty message" ''
add_nearmiss "a header with an EMPTY body" "${HEADER}watcher: "
add_nearmiss "a header with an unknown kind" "${HEADER}bogus: body"
add_nearmiss "a header whose separator is missing its space" "${HEADER}watcher:body"
add_nearmiss "a header with no separator at all" "${HEADER}watcher"
add_nearmiss "a header with no kind at all" "$HEADER"
add_nearmiss "the wrong protocol version" "${PREFIX}v2 watcher: body"
add_nearmiss "the version with no trailing space" "${PREFIX}v1watcher: body"
add_nearmiss "the marker with no space after the label" "${MARK}FIRSTMATE_OP:v1 watcher: body"
# The culture-sensitive-comparison trap, and the reason every comparison in the
# twin names StringComparison::Ordinal. .NET's default comparison treats
# U+200B as IGNORABLE, so a message wearing a zero-width space in front of the
# marker would match the prefix under -ceq / StartsWith-with-no-comparison and
# be accepted as firstmate's own input. bash compares bytes and refuses.
add_nearmiss "a zero-width space BEFORE the marker" "${ZWSP}${HEADER}watcher: body"
add_nearmiss "a zero-width space INSIDE the from-firstmate carrier" \
  "${FM_FROMFIRST_LABEL}${ZWSP}${MARK}body"
add_nearmiss "the marker one character into the message" "x${HEADER}watcher: body"
add_nearmiss "the from-firstmate label with a plain space as its separator" \
  "${FM_FROMFIRST_LABEL} body"

# =============================================================================
# 8. The CLI dispatcher, in-process: exit codes and argument arity.
# =============================================================================
#
# Exit codes ARE the interface (docs/powershell-port.md contract 1): 0 success,
# 1 no match, 2 invalid use. Only the silent paths run here; see add_main.
add_main "encode with no kind is invalid use" encode
add_main "encode with an extra argument is invalid use" encode watcher extra
add_main "kind with an argument is invalid use" kind extra
add_main "classify with an argument is invalid use" classify extra
add_main "body with an argument is invalid use" body extra
add_main "encode with an EMPTY kind and empty stdin" encode ''
add_main "encode with a legacy kind and empty stdin" encode legacy-operational
add_main "encode with a valid kind but EMPTY stdin" encode watcher
add_main "kind on empty stdin is a clean no-match" kind
add_main "classify on empty stdin is a clean no-match" classify
add_main "body on empty stdin is a clean no-match" body

# =============================================================================
# Run the batch: ONE pwsh for everything above.
# =============================================================================
: > "$RESULTS"
if ! pwsh -NoProfile -File "$DRIVER_N" > "$DRIVER_OUT" 2> "$DRIVER_ERR" < /dev/null; then
  fail "the PowerShell case driver exited non-zero:"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A clean run is also a SILENT run. The driver writes its results to a file, so
# anything on these streams is either a module warning at import or a CLI case
# writing where it must not - both of which would be invisible to the
# value comparisons below.
[ ! -s "$DRIVER_OUT" ] || fail "the driver wrote to stdout:"$'\n'"$(cat "$DRIVER_OUT")"
[ ! -s "$DRIVER_ERR" ] || fail "the driver wrote to stderr:"$'\n'"$(cat "$DRIVER_ERR")"

# Results are keyed by INDEX. A key built from a path or a fixture string would
# never match across the two worlds and every case would read as MISSING while
# the values agreed perfectly.
GOT=()
seen=0
while IFS=$'\001' read -r -d $'\002' idx value; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  GOT[$idx]=$value
  seen=$((seen + 1))
done < "$RESULTS"
[ "$seen" -eq "${#LABELS[@]}" ] \
  || fail "the driver returned $seen results for ${#LABELS[@]} cases (a driver that died halfway returns fewer)"

i=0
while [ "$i" -lt "${#LABELS[@]}" ]; do
  assert_same "${LABELS[$i]}" "${EXPECT[$i]}" "${GOT[$i]}"
  i=$((i + 1))
done

# --- the marker's actual BYTES, from the PowerShell side -----------------------
#
# The whole protocol hangs on U+2063, which is by construction invisible: a
# rendering comparison would pass on a mangled marker, and a '?' substitution
# (what PowerShell emits without an explicit UTF-8 console encoding) looks like
# nothing at all in a diff. So the bytes the twin actually produced - carried
# back through the results file - are hexdumped and compared to the landed
# constant, exactly as tests/fm-operational-input.test.sh does for bash.

# Located by LABEL rather than by a hard-coded ordinal, so inserting a case
# above cannot silently repoint this at a different record.
ps_value_by_label() {  # <label> -> PS_VALUE, or fail
  local want=$1 j=0
  PS_VALUE=''
  while [ "$j" -lt "${#LABELS[@]}" ]; do
    if [ "${LABELS[$j]}" = "$want" ]; then PS_VALUE=${GOT[$j]}; return 0; fi
    j=$((j + 1))
  done
  fail "could not locate the PowerShell record labelled '$want'"
}
PS_VALUE=''

ps_value_by_label 'constant FM_OPERATIONAL_PREFIX'
printf '%s' "$PS_VALUE" > "$CAP"
ps_prefix_hex=$(od -An -tx1 < "$CAP" | tr -d ' \n')
assert_same "the PowerShell twin emits the landed U+2063 FIRSTMATE_OP bytes" \
  e281a346495253544d4154455f4f503a20 "$ps_prefix_hex"

printf '%s' "$FM_OPERATIONAL_PREFIX" > "$CAP"
bash_prefix_hex=$(od -An -tx1 < "$CAP" | tr -d ' \n')
assert_same "the two worlds agree on the prefix bytes" "$bash_prefix_hex" "$ps_prefix_hex"

# --- cross-world interop: PowerShell encodes, BASH decodes ---------------------
#
# The batch above already proves bash->PowerShell (bash-encoded envelopes are
# what every parse case is fed). This is the other direction, and it is free:
# the bytes PowerShell produced came back through the results file, so they can
# be handed straight to the bash parser with no extra process.
for k in $CURRENT_KINDS; do
  ps_value_by_label "encode: $k"
  parsed=''
  if fm_operational_input_kind "$PS_VALUE" parsed; then :; else parsed=$NULLTOK; fi
  assert_same "interop: bash reads the PowerShell-encoded $k kind" "$k" "$parsed"
  parsed=''
  if fm_operational_input_body "$PS_VALUE" parsed; then :; else parsed=$NULLTOK; fi
  assert_same "interop: bash reads the PowerShell-encoded $k body" "CURRENT_BODY_FOR_${k}" "$parsed"
done

# The from-firstmate carrier, same direction.
ps_value_by_label 'construct: from-firstmate constructs the carrier'
parsed=''
if fm_operational_input_kind "$PS_VALUE" parsed; then :; else parsed=$NULLTOK; fi
assert_same "interop: bash reads the PowerShell-built from-firstmate carrier" from-firstmate "$parsed"
parsed=''
if fm_operational_input_body "$PS_VALUE" parsed; then :; else parsed=$NULLTOK; fi
assert_same "interop: bash reads the PowerShell-built carrier's body" 'inspect the report' "$parsed"

# =============================================================================
# 9. End to end: the .ps1 as a real process.
# =============================================================================
#
# NINE spawns, and the count is a budget rather than an accident: pwsh startup
# is 4.8s on this host, so this phase costs ~45s and everything that CAN be
# answered in-process already was. What genuinely cannot: argv reaching a
# script with no param() block (the `-h` case would not even bind), stdin read
# to EOF with its trailing bytes intact, the process exit code, and WHICH
# stream usage goes to. Each case runs the bash CLI and the PowerShell CLI on
# the same stdin and compares exit code, stdout bytes, and stderr bytes.
printf '' > "$STDIN_EMPTY"
printf 'CROSS_LANGUAGE_BODY' > "$STDIN_BODY"
printf 'body with a trailing newline\n' > "$STDIN_TRAILNL"

cli_case() {  # <label> <stdin-file> <arg>...
  local label=$1 stdin=$2 brc prc bhex phex berrhex perrhex
  shift 2
  bash "$SH_OWNER" "$@" < "$stdin" > "$B_OUT" 2> "$B_ERR"
  brc=$?
  pwsh -NoProfile -File "$PS_OWNER_N" "$@" < "$stdin" > "$P_OUT" 2> "$P_ERR"
  prc=$?
  assert_same "cli [$label]: exit code" "$brc" "$prc"
  bhex=$(od -An -tx1 < "$B_OUT" | tr -d ' \n')
  phex=$(od -An -tx1 < "$P_OUT" | tr -d ' \n')
  assert_same "cli [$label]: stdout bytes" "$bhex" "$phex"
  berrhex=$(od -An -tx1 < "$B_ERR" | tr -d ' \n')
  perrhex=$(od -An -tx1 < "$P_ERR" | tr -d ' \n')
  assert_same "cli [$label]: stderr bytes" "$berrhex" "$perrhex"
}

# 1-2. Construction, including the from-firstmate carrier. The stdout bytes
#      compared here ARE the wire payload, marker included.
cli_case 'encode watcher' "$STDIN_BODY" encode watcher
CLI_ENCODED=$(cat "$P_OUT")
cli_case 'encode from-firstmate' "$STDIN_BODY" encode from-firstmate

# 3-5. Decoding, fed the payload PowerShell itself just produced - so this is a
#      real cross-world round trip through two processes, not a replay of a
#      bash-built fixture.
printf '%s' "$CLI_ENCODED" > "$TMP_ROOT/stdin.encoded"
cli_case 'kind on a PowerShell-produced envelope' "$TMP_ROOT/stdin.encoded" kind
cli_case 'classify on a PowerShell-produced envelope' "$TMP_ROOT/stdin.encoded" classify
cli_case 'body on a PowerShell-produced envelope' "$TMP_ROOT/stdin.encoded" body

# 6. A body whose LAST byte is a newline: `printf '%s' "$(cat; printf x)"` in
#    the bash twin exists solely to keep it, and `body` must return it without a
#    terminator of its own. Only a real stdin can exercise that.
bash "$SH_OWNER" encode watcher < "$STDIN_TRAILNL" > "$TMP_ROOT/stdin.trailenc" 2>/dev/null \
  || fail "the oracle could not encode the trailing-newline payload"
cli_case 'body preserves a trailing newline' "$TMP_ROOT/stdin.trailenc" body

# 7. A non-match exits 1 SILENTLY - no diagnostic on either stream.
printf '%s' "Captain quote: ${HEADER}watcher" > "$TMP_ROOT/stdin.nearmiss"
cli_case 'classify refuses a near miss' "$TMP_ROOT/stdin.nearmiss" classify

# 8-9. The two usage paths, which differ only in WHICH stream they write to -
#      the one thing an in-process case cannot check.
cli_case '--help writes usage to stdout' "$STDIN_EMPTY" --help
cli_case 'no command writes usage to stderr' "$STDIN_EMPTY"

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-operational-input.psm1/.ps1 differ from their oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. This is an EXACT floor rather than a loose one: the
# case list above is unconditional (nothing here depends on a fixture that might
# not materialize), so dropping a single case fails the run instead of quietly
# shrinking it into a green one.
# The count OBSERVED on a green run, not an estimate. It was originally set to
# 231 by guesswork and never validated, because the suite's first complete run
# failed earlier on a bad near-miss assertion and exited before reaching this
# guard. Lowering a floor is normally suspect, so the justification is explicit:
# the add_nearmiss rewrite that preceded this is assertion-count NEUTRAL (one
# assert_same per fixture before and after), so no assertion was dropped to
# reach this number. Raise it whenever cases are added.
MIN_ASSERTIONS=228
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-operational-input.psm1/.ps1 hold the protocol across %d assertions\n' "$ASSERTIONS"
printf '# fm-operational-input-psm1.test.sh: all assertions passed\n'
