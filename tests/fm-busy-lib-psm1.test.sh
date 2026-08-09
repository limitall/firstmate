#!/usr/bin/env bash
# Behavior test for bin/fm-busy-lib.psm1 - the PowerShell semantic busy-state
# contract.
#
# DIFFERENTIAL against bin/fm-busy-lib.sh: the same fixtures on disk are read by
# the bash twin and by the PowerShell twin, and every verdict must agree
# byte-for-byte. Bash is the oracle, and it can be the oracle for essentially
# everything here because this library is pure record-reading and string work -
# unlike the process primitives, there is no platform surface bash cannot reach.
#
# Two places where bash is NOT the oracle, both declared where they occur:
#   1. The four fm_backend_* / fm_meta_* functions fm-busy-lib.sh calls WITHOUT
#      sourcing them (docs/powershell-port-inventory.md R4). Neither world has a
#      real fm-backend here, so phase 2 installs BEHAVIOR TWIN fakes - a bash
#      function and a PowerShell function with identical, target-string-driven
#      logic. What is under test is fm-busy-lib's own use of them, which is what
#      this package owns; fm-backend's own conversion gets its own differential
#      in wave 3.
#   2. Phase 1 deliberately runs with NO fake at all, so the DEGRADED path is
#      differential too. That is the most valuable case in the file: a missing
#      endpoint probe must produce 'dead endpoint-gone' in both worlds, because
#      bash reaches it through `command not found` -> 127 -> `if !`, and
#      PowerShell reaches it through a capability probe that missed. Those are
#      completely different mechanisms and they must land on the same verdict.
#
# WHY THIS CONTRACT IS WORTH THIS MUCH TEST. A false idle lets a send corrupt a
# running agent's composer mid-thought; a false busy wedges supervision behind a
# worker that is actually waiting. So the fixtures below are deliberately
# unkind: records with no trailing newline, CRLF records, a second line, a blank
# second line, a glob-shaped field, an unarmed gen, a gen with no trailing
# newline. Each of those is a way a real record gets corrupted on this platform,
# and each must classify unknown in BOTH worlds rather than one world guessing.
#
# THREE BATCHED pwsh RUNS, not one per case: a pwsh start costs ~360ms on this
# Defender-protected host, and ~140 assertions would otherwise spend a minute in
# process creation. The phases exist because they need different global state
# (no fakes / backend fakes / FM_BUSY_REGEX), which is not something a single
# process can hold three ways at once.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7. No bash-4-only syntax.
#
# Every path handed to pwsh, INCLUDING the Import-Module path, goes through
# fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads /tmp/x
# as C:\tmp\x - verified).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

[ -f "$ROOT/bin/fm-busy-lib.psm1" ] || fail "bin/fm-busy-lib.psm1 is missing"
MOD=$(fm_test_native_path "$ROOT/bin/fm-busy-lib.psm1")

# The oracle.
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

EV="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-psm1)

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables, and nothing below runs inside a `( ... )` subshell. A
# subshell cannot report a failure back to the parent's counters, so a scheme
# that can LOSE a failure is worse than none: the suite would certify work it
# never checked. Environment-scoped cases use PREFIX ASSIGNMENTS instead.
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

# --- fixtures -----------------------------------------------------------------

new_state() {  # <name> -> the state dir path
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

put_rec() {  # <state> <text>: one LF-terminated line, the normal shape
  printf '%s\n' "$2" > "$1/t1.busy-state"
}

put_rec_raw() {  # <state> <exact bytes>
  printf '%s' "$2" > "$1/t1.busy-state"
}

S_EMPTY=$(new_state s-empty)

S_ARMED=$(new_state s-armed)
G_ARMED=$("$EV" arm "$S_ARMED" t1) || fail "arm failed for s-armed"

S_IDLE=$(new_state s-idle)
G_IDLE=$("$EV" arm "$S_IDLE" t1) || fail "arm failed for s-idle"
"$EV" apply "$S_IDLE" t1 idle --gen "$G_IDLE" --source claude-hook --event stop \
  || fail "apply idle failed"

S_PI=$(new_state s-pi)
G_PI=$("$EV" arm "$S_PI" t1) || fail "arm failed for s-pi"
"$EV" apply "$S_PI" t1 busy --gen "$G_PI" --source pi-ext --event agent-start \
  || fail "apply pi-ext failed"

S_OC=$(new_state s-oc)
G_OC=$("$EV" arm "$S_OC" t1) || fail "arm failed for s-oc"
"$EV" apply "$S_OC" t1 idle --gen "$G_OC" --source opencode-plugin --event session-status \
  || fail "apply opencode-plugin failed"

S_UNKNOWN=$(new_state s-unknown)
G_UNKNOWN=$("$EV" arm "$S_UNKNOWN" t1) || fail "arm failed for s-unknown"
"$EV" apply "$S_UNKNOWN" t1 unknown --gen "$G_UNKNOWN" --source fm-recovery --event relaunch \
  || fail "apply fm-recovery failed"

# A record left behind by a superseded incarnation.
S_STALE=$(new_state s-stale)
"$EV" arm "$S_STALE" t1 >/dev/null || fail "arm failed for s-stale"
printf 'g-superseded.1.1\n' > "$S_STALE/t1.busy-gen"

# A record with no gen sidecar to bind to.
S_ORPHAN=$(new_state s-orphan)
put_rec "$S_ORPHAN" 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1'

# A sidecar whose single line is NOT LF-terminated. bash's `read` fails at EOF
# and the twin's `|| gen=` then discards the partial value, so this reads as
# NEVER ARMED - and a record that exists without an armed gen is malformed.
S_NONL_GEN=$(new_state s-nonl-gen)
G_NONL=$("$EV" arm "$S_NONL_GEN" t1) || fail "arm failed for s-nonl-gen"
printf '%s' "$G_NONL" > "$S_NONL_GEN/t1.busy-gen"

S_EMPTY_GEN=$(new_state s-empty-gen)
"$EV" arm "$S_EMPTY_GEN" t1 >/dev/null || fail "arm failed for s-empty-gen"
: > "$S_EMPTY_GEN/t1.busy-gen"

S_BAD_GEN=$(new_state s-bad-gen)
"$EV" arm "$S_BAD_GEN" t1 >/dev/null || fail "arm failed for s-bad-gen"
printf 'bad gen\n' > "$S_BAD_GEN/t1.busy-gen"

# Record-shape corruptions, each under a VALID armed gen so the only thing being
# judged is the record itself.
S_NONL_REC=$(new_state s-nonl-rec)
G=$("$EV" arm "$S_NONL_REC" t1)
put_rec_raw "$S_NONL_REC" "v1 gen=$G seq=1 state=busy source=claude-hook event=x ts=1"

S_CRLF=$(new_state s-crlf)
G=$("$EV" arm "$S_CRLF" t1)
put_rec_raw "$S_CRLF" "v1 gen=$G seq=1 state=busy source=claude-hook event=x ts=1"$'\r'$'\n'

S_TWOLINE=$(new_state s-twoline)
G=$("$EV" arm "$S_TWOLINE" t1)
put_rec_raw "$S_TWOLINE" "v1 gen=$G seq=1 state=busy source=claude-hook event=x ts=1"$'\n'"second line"$'\n'

S_BLANKLINE=$(new_state s-blankline)
G=$("$EV" arm "$S_BLANKLINE" t1)
put_rec_raw "$S_BLANKLINE" "v1 gen=$G seq=1 state=busy source=claude-hook event=x ts=1"$'\n'$'\n'

S_EMPTY_REC=$(new_state s-empty-rec)
"$EV" arm "$S_EMPTY_REC" t1 >/dev/null
: > "$S_EMPTY_REC/t1.busy-state"

S_GARBAGE=$(new_state s-garbage)
"$EV" arm "$S_GARBAGE" t1 >/dev/null
put_rec "$S_GARBAGE" 'garbage'

S_V0=$(new_state s-v0)
G=$("$EV" arm "$S_V0" t1)
put_rec "$S_V0" "v0 gen=$G seq=1 state=busy source=claude-hook event=x ts=1"

S_SEQNAN=$(new_state s-seqnan)
G=$("$EV" arm "$S_SEQNAN" t1)
put_rec "$S_SEQNAN" "v1 gen=$G seq=NaN state=busy source=claude-hook event=x ts=1"

S_STATEBAD=$(new_state s-statebad)
G=$("$EV" arm "$S_STATEBAD" t1)
put_rec "$S_STATEBAD" "v1 gen=$G seq=1 state=frobbing source=claude-hook event=x ts=1"

# `source=bad source` splits into an extra bare field with no recognized prefix.
S_SRCSPACE=$(new_state s-srcspace)
G=$("$EV" arm "$S_SRCSPACE" t1)
put_rec "$S_SRCSPACE" "v1 gen=$G seq=1 state=busy source=bad source event=x ts=1"

S_ROGUE=$(new_state s-rogue)
G=$("$EV" arm "$S_ROGUE" t1)
put_rec "$S_ROGUE" "v1 gen=$G seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"

# A glob-shaped field must be REJECTED, never expanded against the cwd. bash
# gets that from `read -a`; PowerShell gets it from .Split on a plain string.
S_GLOB=$(new_state s-glob)
G=$("$EV" arm "$S_GLOB" t1)
put_rec "$S_GLOB" "v1 gen=$G seq=1 state=busy source=* event=x ts=1"

S_NOTS=$(new_state s-nots)
G=$("$EV" arm "$S_NOTS" t1)
put_rec "$S_NOTS" "v1 gen=$G seq=1 state=busy source=claude-hook event=x"

S_NOGENFIELD=$(new_state s-nogenfield)
"$EV" arm "$S_NOGENFIELD" t1 >/dev/null
put_rec "$S_NOGENFIELD" "v1 seq=1 state=busy source=claude-hook event=x ts=1"

# Valid, but exercising the parser rather than the happy path: runs of spaces
# collapse and leading space is ignored (IFS=' ' word splitting), a repeated key
# takes the LAST occurrence, and seq is reported as its RAW token.
S_SPACES=$(new_state s-spaces)
G=$("$EV" arm "$S_SPACES" t1)
put_rec "$S_SPACES" "  v1   gen=$G  seq=007   state=idle  source=claude-hook   event=stop  ts=1  "

S_DUPGEN=$(new_state s-dupgen)
G=$("$EV" arm "$S_DUPGEN" t1)
put_rec "$S_DUPGEN" "v1 gen=g-wrong.0.0 seq=2 state=busy source=claude-hook event=x ts=1 gen=$G"

# Meta fixtures for the classify_meta cases.
META_DIR="$TMP_ROOT/meta"
mkdir -p "$META_DIR"
META_MISSING="$META_DIR/absent.meta"
META_CLAUDE="$META_DIR/claude.meta"
fm_write_meta "$META_CLAUDE" 'window=w1' 'harness=claude'
META_NOWIN="$META_DIR/nowin.meta"
fm_write_meta "$META_NOWIN" 'window=' 'harness=claude'
META_PI="$META_DIR/pi.meta"
fm_write_meta "$META_PI" 'window=w1' 'harness=pi'
META_HERDR="$META_DIR/herdr.meta"
fm_write_meta "$META_HERDR" 'backend=herdr' 'window=s:nativebusy' 'harness=claude'

# --- case definition ----------------------------------------------------------
#
# Each case is declared ONCE. The helper drives the bash oracle immediately and
# appends the matching line to the pwsh case file, so the two sides can never
# drift apart over which inputs they were asked about.
#
# Case-file shape: line 1 is the module path, line 2 is the fake directive, and
# every later line is exactly 8 TAB-separated fields
#   <fn> <label> <a1> <a2> <a3> <a4> <a5> <a6>
# Empty middle fields are meaningful and must survive, so the PowerShell side
# splits on TAB and asserts the FIELD COUNT rather than trusting a regex split
# (docs/powershell-port-inventory.md R9). bash never parses this file at all.
CASES=""
BASH_ANS=""

# Multi-line arguments (rendered tails) travel with LF encoded as a literal
# backslash-n, because the case file is line-based. Guarded rather than assumed:
# a case whose text contains a backslash or a tab would decode wrong, so it fails
# the run instead of silently comparing the wrong bytes.
enc() {  # <text>
  local s=$1
  case "$s" in *\\*) fail "case text must not contain a backslash: [$s]" ;; esac
  case "$s" in *$'\t'*) fail "case text must not contain a tab: [$s]" ;; esac
  printf '%s' "${s//$'\n'/\\n}"
}

# $'\t' rather than a literal tab everywhere below: a raw tab inside a `case`
# PATTERN ends the pattern word and is a syntax error, and a raw tab in a
# string is invisible to review. TAB is the field separator on both sides of
# this test, so it is spelled explicitly wherever it appears.
add_case() {  # <fn> <label> <a1..a6>
  CASES="${CASES}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"$'\t'"$7"$'\t'"$8"$'\n'
}

add_answer() {  # <label> <bash-answer>
  BASH_ANS="${BASH_ANS}$1"$'\t'"$2"$'\n'
}

# yesno <command...>: 'yes' when the command succeeds, 'no' otherwise. The
# bash contract is an exit status; the PowerShell contract is a [bool]; this is
# the shared spelling both are compared in.
yesno() {
  if "$@" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
}

case_token() {  # <label> <value>
  add_answer "$1" "$(yesno fm_busy_token_valid "$2")"
  add_case token "$1" "$(enc "$2")" '' '' '' '' ''
}

case_path() {  # <label> <state-string> <id>   (pure string work: same input both sides)
  add_answer "$1.rec" "$(fm_busy_record_path "$2" "$3")"
  add_answer "$1.gen" "$(fm_busy_gen_path "$2" "$3")"
  add_case path "$1" "$2" "$3" '' '' '' ''
}

case_gen() {  # <label> <state-dir>
  local out
  if out=$(fm_busy_current_gen "$2" t1 2>/dev/null); then
    add_answer "$1" "$out"
  else
    add_answer "$1" '<fail>'
  fi
  add_case gen "$1" "$(fm_test_native_path "$2")" '' '' '' '' ''
}

case_sources() {  # <label> <harness>
  add_answer "$1" "$(fm_busy_sources_for_harness "$2")"
  add_case sources "$1" "$2" '' '' '' '' ''
}

case_trusted() {  # <label> <harness> <source>
  add_answer "$1" "$(yesno fm_busy_source_trusted "$2" "$3")"
  add_case trusted "$1" "$2" "$3" '' '' '' ''
}

case_read() {  # <label> <state-dir>
  local out rc
  out=$(fm_busy_record_read "$2" t1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    add_answer "$1" "ok $out"
  else
    add_answer "$1" "fail $out"
  fi
  add_case read "$1" "$(fm_test_native_path "$2")" '' '' '' '' ''
}

case_grok() {  # <label> <tail>
  local verdict
  if printf '%s' "$2" | fm_busy_grok_tail_busy; then verdict=yes; else verdict=no; fi
  add_answer "$1" "$verdict"
  # a6 carries THIS case's FM_BUSY_REGEX. A prefix assignment
  # (`FM_BUSY_REGEX=x case_grok ...`) applies to the bash oracle call, but the
  # pwsh child runs later in phase_run, by which point the shell holds only the
  # LAST value assigned in the phase - so every case would be evaluated against
  # one pattern. Recording it per case is what actually makes the override
  # differential.
  add_case grok "$1" "$(enc "$2")" '' '' '' '' "$(enc "${FM_BUSY_REGEX-}")"
}

case_classify() {  # <label> <backend> <target> <harness> <state-dir> [tail]
  add_answer "$1" "$(fm_busy_classify "$2" "$3" "$4" t1 "$5" "${6-}")"
  add_case classify "$1" "$2" "$3" "$4" "$(fm_test_native_path "$5")" "$(enc "${6-}")" "$(enc "${FM_BUSY_REGEX-}")"
}

case_live() {  # <label> <backend> <target> <harness> <state-dir> [label-arg]
  add_answer "$1" "$(fm_busy_classify_live "$2" "$3" "$4" t1 "$5" "${6-}")"
  add_case live "$1" "$2" "$3" "$4" "$(fm_test_native_path "$5")" "${6-}" ''
}

case_meta() {  # <label> <meta-file> <state-dir> [tail]
  add_answer "$1" "$(fm_busy_classify_meta "$2" t1 "$3" "${4-}")"
  add_case meta "$1" "$(fm_test_native_path "$2")" "$(fm_test_native_path "$3")" "$(enc "${4-}")" '' '' ''
}

case_isbusy() {  # <label> <backend> <target> <harness> <state-dir> [tail]
  add_answer "$1" "$(yesno fm_busy_is_busy "$2" "$3" "$4" t1 "$5" "${6-}")"
  add_case isbusy "$1" "$2" "$3" "$4" "$(fm_test_native_path "$5")" "$(enc "${6-}")" ''
}

case_gate() {  # <label> <bash-fn>
  add_answer "$1" "$(yesno "$2")"
  add_case gate "$1" "$1" '' '' '' '' ''
}

# --- the PowerShell side ------------------------------------------------------
#
# The cases arrive in a FILE rather than as arguments: PowerShell re-splits a
# `-File` script argument on spaces, and a repo or temp path containing a space
# would break the same way (both learned in tests/fm-psproc-lib-psm1.test.sh).
#
# Every probe runs inside a try/catch. The catch matters as much as the values:
# with $ErrorActionPreference = 'Stop' a module that forgot to guard a fault
# surfaces here as an .error record instead of as a silently wrong verdict.
QUERY="$TMP_ROOT/query.ps1"
cat > "$QUERY" <<'PS1'
#Requires -Version 7.0
# Line 1 of -CaseFile is the module path, line 2 is the fake directive, and every
# later line is 8 TAB-separated fields: <fn> <label> <a1..a6>.
param([Parameter(Mandatory)][string]$CaseFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = @([System.IO.File]::ReadAllLines($CaseFile))
$Module = $lines[0]
$Fakes = $lines[1]

Import-Module $Module -Force
# Imported separately because a .psm1 does not re-export its own dependencies:
# the fakes below need Get-FmMetaValue, the same reader the module itself uses.
Import-Module ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Module), 'fm-common.psm1')) -Force

function Write-Record {
    param([Parameter(Mandatory)][string]$Key, [Parameter()]$Value)
    if ($null -eq $Value) { $Value = '' }
    # TAB is the field separator, so a value may never contain one. Nothing this
    # module returns does; stripping is a guard, not a fixup.
    $text = ([string]$Value) -replace "`t", ' '
    [Console]::Out.Write($Key + "`t" + $text + "`n")
}

function ConvertFrom-CaseText {
    param([Parameter()][AllowEmptyString()][string]$Text)
    # The LF encoding from the bash side. A plain string Replace, not -replace:
    # the pattern is a literal, and a regex would give '\n' a second meaning.
    return $Text.Replace('\n', "`n")
}

# --- behavior-twin fakes for the fm-backend seam ------------------------------
#
# Mirrors of the bash fakes in the test, driven entirely by SUBSTRINGS OF THE
# TARGET so one batch can exercise every variation with no per-case global
# state. Published at global scope on purpose: that is where a real consumer's
# Import-Module of fm-backend.psm1 would put them, and it is the scope a .psm1's
# command lookup falls back to (verified on this host).
if ($Fakes -eq 'backend') {
    function global:Test-FmBackendTargetExists {
        param($Backend, $Target, $Label)
        return (-not ([string]$Target).Contains('gone'))
    }
    function global:Get-FmBackendBusyState {
        param($Backend, $Target)
        if (([string]$Target).Contains('nativebusy')) { return 'busy' }
        if (([string]$Target).Contains('nativeidle')) { return 'idle' }
        return 'unknown'
    }
    function global:Get-FmBackendCapture {
        param($Backend, $Target, $Lines)
        if (([string]$Target).Contains('nocap')) { throw 'capture failed' }
        if (([string]$Target).Contains('capbusy')) { return 'thinking hard' + "`n" + 'Ctrl+c:cancel' }
        if (([string]$Target).Contains('capidle')) { return 'done.' + "`n" + '> ' }
        return ''
    }
    function global:Get-FmBackendOfMeta {
        param($MetaPath)
        $v = Get-FmMetaValue $MetaPath 'backend'
        if ([string]::IsNullOrEmpty($v)) { return 'tmux' }
        return $v
    }
    function global:Get-FmBackendTargetOfMeta {
        param($MetaPath)
        return (Get-FmMetaValue $MetaPath 'window')
    }
}

foreach ($line in ($lines | Select-Object -Skip 2)) {
    if ($line -eq '') { continue }
    # .Split on the raw string, and the field COUNT asserted: several fields are
    # meaningfully EMPTY, and a regex split would drop them silently.
    $f = $line.Split("`t")
    if ($f.Length -ne 8) {
        Write-Record -Key 'case.error' -Value "expected 8 fields, got $($f.Length): $line"
        continue
    }
    $fn = $f[0]
    $label = $f[1]
    $a1 = $f[2]; $a2 = $f[3]; $a3 = $f[4]; $a4 = $f[5]; $a5 = $f[6]
    # a6 is the per-case FM_BUSY_REGEX override (see case_grok in the test).
    # Applied here, per case, and CLEARED when absent so one case's override
    # cannot leak into the next - the exact failure this field exists to fix.
    $a6 = $f[7]
    if ($a6 -ne '') {
        $env:FM_BUSY_REGEX = ConvertFrom-CaseText $a6
    } elseif (Test-Path Env:FM_BUSY_REGEX) {
        Remove-Item Env:FM_BUSY_REGEX
    }

    try {
        switch ($fn) {
            'token' {
                Write-Record -Key $label -Value $(if (Test-FmBusyToken (ConvertFrom-CaseText $a1)) { 'yes' } else { 'no' })
            }
            'path' {
                Write-Record -Key "$label.rec" -Value (Get-FmBusyRecordPath $a1 $a2)
                Write-Record -Key "$label.gen" -Value (Get-FmBusyGenPath $a1 $a2)
            }
            'gen' {
                $g = Get-FmBusyCurrentGen $a1 't1'
                Write-Record -Key $label -Value $(if ($null -eq $g) { '<fail>' } else { $g })
            }
            'sources' {
                Write-Record -Key $label -Value (@(Get-FmBusySourcesForHarness $a1) -join ' ')
            }
            'trusted' {
                Write-Record -Key $label -Value $(if (Test-FmBusySourceTrusted $a1 $a2) { 'yes' } else { 'no' })
            }
            'read' {
                $r = Read-FmBusyRecord $a1 't1'
                if ($r.Ok) {
                    Write-Record -Key $label -Value ('ok {0} {1} {2} {3}' -f $r.State, $r.Source, $r.Event, $r.Seq)
                } else {
                    Write-Record -Key $label -Value ('fail ' + $r.Reason)
                }
            }
            'grok' {
                Write-Record -Key $label -Value $(if (Test-FmBusyGrokTail (ConvertFrom-CaseText $a1)) { 'yes' } else { 'no' })
            }
            'classify' {
                Write-Record -Key $label -Value (Get-FmBusyClassification $a1 $a2 $a3 't1' $a4 (ConvertFrom-CaseText $a5))
            }
            'live' {
                Write-Record -Key $label -Value (Get-FmBusyLiveClassification $a1 $a2 $a3 't1' $a4 $a5)
            }
            'meta' {
                Write-Record -Key $label -Value (Get-FmBusyMetaClassification $a1 't1' $a2 (ConvertFrom-CaseText $a3))
            }
            'isbusy' {
                Write-Record -Key $label -Value $(if (Test-FmBusy $a1 $a2 $a3 't1' $a4 (ConvertFrom-CaseText $a5)) { 'yes' } else { 'no' })
            }
            'gate' {
                $answer = switch ($a1) {
                    'gate.kimi' { Test-FmBusyKimiVerified }
                    'gate.codex-appserver' { Test-FmBusyCodexAppServerObservable }
                    'gate.codex-hooks' { Test-FmBusyCodexHooksVerified }
                    'gate.codex-any' { Test-FmBusyCodexSemanticSource }
                    default { throw "unknown gate $a1" }
                }
                Write-Record -Key $label -Value $(if ($answer) { 'yes' } else { 'no' })
            }
            default { Write-Record -Key 'case.error' -Value "unknown fn $fn" }
        }
    } catch {
        Write-Record -Key $label -Value '<threw>'
        Write-Record -Key "$label.error" -Value $_.Exception.Message
    }
}
PS1
QUERY_N=$(fm_test_native_path "$QUERY")

PS_LINES=()

phase_begin() {  # <fake-directive>
  CASES=""
  BASH_ANS=""
  PHASE_FAKES=$1
}

# phase_run: write the case file, run ONE pwsh over it, then compare every
# recorded bash answer against the PowerShell answer for the same label.
phase_run() {  # <phase-name>
  local phase=$1 case_file="$TMP_ROOT/cases-$1.txt" case_file_n out line key expected actual
  {
    printf '%s\n' "$MOD"
    printf '%s\n' "$PHASE_FAKES"
    printf '%s' "$CASES"
  } > "$case_file"
  case_file_n=$(fm_test_native_path "$case_file")

  out=$(pwsh -NoProfile -Command "& '$QUERY_N' -CaseFile '$case_file_n'" 2>&1) ||
    fail "the PowerShell query script failed in phase $phase:"$'\n'"$out"

  PS_LINES=()
  while IFS= read -r line; do
    [ -n "$line" ] && PS_LINES+=("$line")
  done <<PSOUT
$out
PSOUT

  # An .error record means an exception escaped a primitive - exactly the
  # failure $ErrorActionPreference = 'Stop' makes the DEFAULT for an unguarded
  # fault, and the reason every probe in the module pins its own handling.
  local errors=''
  for line in ${PS_LINES+"${PS_LINES[@]}"}; do
    case "$line" in
      *.error$'\t'*) errors="$errors ${line%%$'\t'*}" ;;
    esac
  done
  assert_same "$phase: no case throws" "" "${errors# }"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    expected=${line#*$'\t'}
    ps_value "$key"
    assert_same "$phase/$key" "$expected" "$FM_PSV"
  done <<ANS
$BASH_ANS
ANS
}

FM_PSV=
ps_value() {  # <key> -> FM_PSV, or the literal <missing>
  local key=$1 line
  FM_PSV='<missing>'
  for line in ${PS_LINES+"${PS_LINES[@]}"}; do
    case "$line" in
      "$key"$'\t'*) FM_PSV=${line#*$'\t'}; return 0 ;;
    esac
  done
}

# ==============================================================================
# PHASE 1 - no fm-backend capability present in EITHER world.
#
# This is the honest wave-2 state and it is where the R4 seam is proved: bash
# has not sourced fm-backend.sh, PowerShell has no fm-backend.psm1 to import,
# and the two must still agree on every verdict including the degraded ones.
# ==============================================================================

phase_begin none

# --- the token charset --------------------------------------------------------
case_token token.empty ''
case_token token.simple 'g1'
case_token token.dotted 'g1755123456.4242.31337'
case_token token.underscore 'a_b'
case_token token.hyphen 'claude-hook'
case_token token.dot '.'
case_token token.upper 'ABC'
case_token token.space 'a b'
case_token token.star 'a*'
case_token token.slash 'a/b'
case_token token.equals 'a=b'
# A trailing newline must be REJECTED. This is the case .NET's '$' anchor would
# have silently accepted, which is why the module anchors with \z.
case_token token.newline 'abc
'

# --- path composition (pure strings: the SAME input reaches both sides) -------
case_path path.plain '/tmp/s' 't1'
case_path path.dotted '/a/b' 'x.y-z'
case_path path.empty '' ''

# --- the armed generation ------------------------------------------------------
case_gen gen.armed "$S_ARMED"
case_gen gen.absent "$S_EMPTY"
case_gen gen.nonl "$S_NONL_GEN"
case_gen gen.empty "$S_EMPTY_GEN"
case_gen gen.bad "$S_BAD_GEN"
case_gen gen.stale "$S_STALE"

# --- the per-harness trust table -----------------------------------------------
case_sources src.claude 'claude'
case_sources src.claude-code 'claude-code'
case_sources src.codex 'codex'
case_sources src.codex-cli 'codex-cli'
case_sources src.opencode 'opencode'
case_sources src.opencode-x 'opencode-x'
case_sources src.pi 'pi'
case_sources src.pi-signed 'pi-signed'
case_sources src.pi-prefix 'pi-foo'
case_sources src.kimi 'kimi'
case_sources src.kimi-cli 'kimi-cli'
case_sources src.grok 'grok'
case_sources src.grok-cli 'grok-cli'
case_sources src.empty ''
case_sources src.tmux 'tmux'
# Case sensitivity: bash `case` patterns are case-SENSITIVE, and PowerShell's
# default -like/-eq are not. A harness spelled 'Claude' must trust nothing.
case_sources src.capital 'Claude'

case_trusted trust.claude-own 'claude' 'claude-hook'
case_trusted trust.claude-fmspawn 'claude' 'fm-spawn'
case_trusted trust.claude-interrupt 'claude' 'fm-interrupt'
case_trusted trust.claude-recovery 'claude' 'fm-recovery'
case_trusted trust.claude-foreign 'claude' 'pi-ext'
case_trusted trust.pi-own 'pi' 'pi-ext'
case_trusted trust.grok-any 'grok' 'pi-ext'
case_trusted trust.grok-fmspawn 'grok' 'fm-spawn'
case_trusted trust.codex-own 'codex' 'codex-hook'
case_trusted trust.kimi-own 'kimi' 'kimi-hook'
case_trusted trust.empty-source 'claude' ''
case_trusted trust.case 'claude' 'CLAUDE-HOOK'

# --- record parsing ------------------------------------------------------------
case_read read.armed "$S_ARMED"
case_read read.idle "$S_IDLE"
case_read read.unknown "$S_UNKNOWN"
case_read read.missing "$S_EMPTY"
case_read read.stale "$S_STALE"
case_read read.orphan "$S_ORPHAN"
case_read read.nonl-gen "$S_NONL_GEN"
case_read read.empty-gen "$S_EMPTY_GEN"
case_read read.bad-gen "$S_BAD_GEN"
case_read read.nonl-rec "$S_NONL_REC"
case_read read.crlf "$S_CRLF"
case_read read.twoline "$S_TWOLINE"
case_read read.blankline "$S_BLANKLINE"
case_read read.empty-rec "$S_EMPTY_REC"
case_read read.garbage "$S_GARBAGE"
case_read read.v0 "$S_V0"
case_read read.seqnan "$S_SEQNAN"
case_read read.statebad "$S_STATEBAD"
case_read read.srcspace "$S_SRCSPACE"
case_read read.rogue "$S_ROGUE"
case_read read.glob "$S_GLOB"
case_read read.nots "$S_NOTS"
case_read read.nogenfield "$S_NOGENFIELD"
case_read read.spaces "$S_SPACES"
case_read read.dupgen "$S_DUPGEN"

# --- the Grok rendered-tail fallback -------------------------------------------
case_grok grok.signature 'Ctrl+c:cancel'
case_grok grok.in-tail 'thinking hard
Ctrl+c:cancel'
case_grok grok.idle 'done.
> '
case_grok grok.empty ''
# grep -i: the signature match is case-insensitive in both worlds.
case_grok grok.upper 'CTRL+C:CANCEL'
# Another adapter's footer must never read as Grok busy.
case_grok grok.claude-footer 'Working (6s - esc to interrupt)'
# tail -12 window: the signature on the FIRST of 14 non-blank lines falls
# outside the window and must not match.
case_grok grok.outside-window 'Ctrl+c:cancel
l1
l2
l3
l4
l5
l6
l7
l8
l9
l10
l11
l12
l13'
# ...and the blank-line filter runs BEFORE the window, so 13 blank lines do not
# push the signature out of it.
case_grok grok.blanks-dont-shift 'Ctrl+c:cancel










'
# The one place .NET's \s and POSIX [[:space:]] could disagree: 12 lines holding
# only U+00A0. If the two worlds classify this the same way, the module's
# explicit ASCII whitespace class matches grep on this host.
case_grok grok.nbsp-lines 'Ctrl+c:cancel











 '

# --- classification: valid records ----------------------------------------------
case_classify cls.armed-claude tmux w1 claude "$S_ARMED"
case_classify cls.idle-claude tmux w1 claude "$S_IDLE"
case_classify cls.unknown-recovery tmux w1 claude "$S_UNKNOWN"
case_classify cls.pi-on-pi tmux w1 pi "$S_PI"
case_classify cls.pi-on-pisigned tmux w1 pi-signed "$S_PI"
case_classify cls.oc-on-opencode tmux w1 opencode "$S_OC"
# Adapter isolation: one adapter's writer can never classify another adapter.
case_classify cls.pi-on-claude tmux w1 claude "$S_PI"
case_classify cls.claude-on-pi tmux w1 pi "$S_IDLE"
case_classify cls.claude-on-grok tmux w1 grok "$S_IDLE"
case_classify cls.claude-on-opencode tmux w1 opencode "$S_IDLE"

# --- classification: the verification gates outrank every record ----------------
case_classify cls.kimi-armed tmux w1 kimi "$S_ARMED"
case_classify cls.kimi-empty tmux w1 kimi "$S_EMPTY"
case_classify cls.codex-armed tmux w1 codex "$S_ARMED"
case_classify cls.codex-empty tmux w1 codex "$S_EMPTY"
# A gated adapter must not fall back to footer text either.
case_classify cls.kimi-spinner tmux w1 kimi "$S_EMPTY" 'thinking'
case_classify cls.codex-footer tmux w1 codex "$S_EMPTY" 'Working (6s - esc to interrupt)'

# --- classification: missing, stale, and malformed all mean unknown --------------
case_classify cls.missing-claude tmux w1 claude "$S_EMPTY"
case_classify cls.missing-opencode tmux w1 opencode "$S_EMPTY"
case_classify cls.missing-pi tmux w1 pi "$S_EMPTY"
case_classify cls.missing-pisigned tmux w1 pi-signed "$S_EMPTY"
case_classify cls.stale tmux w1 claude "$S_STALE"
case_classify cls.orphan tmux w1 claude "$S_ORPHAN"
case_classify cls.garbage tmux w1 claude "$S_GARBAGE"
case_classify cls.v0 tmux w1 claude "$S_V0"
case_classify cls.seqnan tmux w1 claude "$S_SEQNAN"
case_classify cls.statebad tmux w1 claude "$S_STATEBAD"
case_classify cls.rogue tmux w1 claude "$S_ROGUE"
case_classify cls.glob tmux w1 claude "$S_GLOB"
case_classify cls.crlf tmux w1 claude "$S_CRLF"
case_classify cls.twoline tmux w1 claude "$S_TWOLINE"
case_classify cls.nonl-rec tmux w1 claude "$S_NONL_REC"
case_classify cls.nonl-gen tmux w1 claude "$S_NONL_GEN"
case_classify cls.spaces tmux w1 claude "$S_SPACES"
case_classify cls.dupgen tmux w1 claude "$S_DUPGEN"

# --- classification: a converted adapter NEVER reads rendered text ---------------
FOOTER='- Working (6s - esc to interrupt)
   esc interrupt
Working...
Ctrl+c:cancel'
case_classify cls.footer-claude tmux w1 claude "$S_EMPTY" "$FOOTER"
case_classify cls.footer-opencode tmux w1 opencode "$S_EMPTY" "$FOOTER"
case_classify cls.footer-pi tmux w1 pi "$S_EMPTY" "$FOOTER"

# --- classification: the Grok arm, scoped to grok --------------------------------
case_classify cls.grok-busy tmux w1 grok "$S_EMPTY" 'thinking
Ctrl+c:cancel'
case_classify cls.grok-idle tmux w1 grok "$S_EMPTY" 'done.
> '
case_classify cls.grok-claude-footer tmux w1 grok "$S_EMPTY" '- Working (6s - esc to interrupt)'
# No tail AND no capture capability in either world: capture-failed, not idle.
case_classify cls.grok-nocapture tmux w1 grok "$S_EMPTY"
# A record still outranks the rendered fallback, even for grok - but grok trusts
# no source, so the record makes it source-mismatch rather than letting the tail
# speak.
case_classify cls.grok-record-wins tmux w1 grok "$S_IDLE" 'Ctrl+c:cancel'

# --- classification: herdr's native verdict is unavailable without fm-backend ----
case_classify cls.herdr-noprobe herdr s:nativebusy claude "$S_EMPTY"

# --- the live wrapper, DEGRADED: the R4 case -------------------------------------
#
# bash gets here through `command not found` -> 127 -> the `if !` inversion;
# PowerShell gets here through a capability probe that missed. Different
# mechanisms, one verdict.
case_live live.noprobe tmux w1 claude "$S_ARMED"
case_live live.noprobe-empty-state tmux w1 claude "$S_EMPTY"
case_live live.no-target tmux '' claude "$S_ARMED"
case_live live.no-target-label tmux '' claude "$S_ARMED" 'fm-t1'

# --- the meta wrapper, DEGRADED ---------------------------------------------------
case_meta meta.absent "$META_MISSING" "$S_ARMED"
case_meta meta.noprobe "$META_CLAUDE" "$S_ARMED"

# --- the boolean view -------------------------------------------------------------
case_isbusy busy.armed tmux w1 claude "$S_ARMED"
case_isbusy busy.idle tmux w1 claude "$S_IDLE"
case_isbusy busy.unknown tmux w1 claude "$S_UNKNOWN"
case_isbusy busy.garbage tmux w1 claude "$S_GARBAGE"
case_isbusy busy.missing tmux w1 claude "$S_EMPTY"
case_isbusy busy.grok-tail tmux w1 grok "$S_EMPTY" 'Ctrl+c:cancel'

# --- the verification gates themselves ---------------------------------------------
case_gate gate.kimi fm_busy_kimi_verified
case_gate gate.codex-appserver fm_busy_codex_appserver_observable
case_gate gate.codex-hooks fm_busy_codex_hooks_verified
case_gate gate.codex-any fm_busy_codex_semantic_source

phase_run phase1

# ==============================================================================
# PHASE 2 - the fm-backend seam WIRED, with behavior-twin fakes.
#
# The bash fakes below and the PowerShell fakes in the query script are written
# to be the same function twice: every decision is driven by a substring of the
# TARGET, so one batch exercises alive/gone, native busy/idle, and capture
# ok/empty/failed with no per-case global state on either side.
# ==============================================================================

phase_begin backend

# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
fm_backend_target_exists() {
  case "$2" in *gone*) return 1 ;; esac
  return 0
}
# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
fm_backend_busy_state() {
  case "$2" in
    *nativebusy*) printf 'busy' ;;
    *nativeidle*) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}
# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
fm_backend_capture() {
  case "$2" in
    *nocap*) return 1 ;;
    *capbusy*) printf 'thinking hard\nCtrl+c:cancel' ;;
    *capidle*) printf 'done.\n> ' ;;
    *) printf '' ;;
  esac
}
# fm_meta_get, fm_backend_of_meta and fm_backend_target_of_meta reproduced from
# bin/fm-backend.sh rather than sourced: sourcing the real dispatcher would also
# install a REAL fm_backend_target_exists that talks to tmux, which would make
# these cases depend on a live terminal multiplexer. The PowerShell side uses
# fm-common's Get-FmMetaValue, which tests/fm-common-psm1.test.sh already proves
# byte-compatible with fm_meta_get, so the meta read stays genuinely differential.
# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_meta
fm_meta_get() {
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_meta
fm_backend_of_meta() {
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}
# shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_meta
fm_backend_target_of_meta() {
  local window
  window=$(fm_meta_get "$1" window)
  [ -n "$window" ] && printf '%s' "$window"
}

# --- herdr's native verdict: trusted for BUSY only ---------------------------------
case_classify nat.busy herdr s:nativebusy claude "$S_EMPTY"
# Native idle is narrower than turn state (a long foreground tool call reads
# idle), so it must stay unknown rather than becoming idle.
case_classify nat.idle herdr s:nativeidle claude "$S_EMPTY"
case_classify nat.unknown herdr s:plain claude "$S_EMPTY"
# Scoped to herdr: the same native answer on another backend is never consulted.
case_classify nat.tmux-scoped tmux s:nativebusy claude "$S_EMPTY"
case_classify nat.zellij-scoped zellij s:nativebusy claude "$S_EMPTY"
# A valid record outranks the native verdict.
case_classify nat.record-wins herdr s:nativebusy claude "$S_IDLE"
case_classify nat.malformed-wins herdr s:nativebusy claude "$S_GARBAGE"
# The gates outrank it too.
case_classify nat.kimi herdr s:nativebusy kimi "$S_EMPTY"
case_classify nat.codex herdr s:nativebusy codex "$S_EMPTY"

# --- the Grok capture path ----------------------------------------------------------
case_classify cap.busy tmux capbusy grok "$S_EMPTY"
case_classify cap.idle tmux capidle grok "$S_EMPTY"
# A capture that SUCCEEDS with empty output is not a failure: the twin branches
# on the exit status alone, so an empty tail classifies idle. This is the
# "empty output plus status" distinction the callers depend on.
case_classify cap.empty tmux plain grok "$S_EMPTY"
case_classify cap.failed tmux nocap grok "$S_EMPTY"
# A supplied tail short-circuits the capture entirely.
case_classify cap.tail-wins tmux nocap grok "$S_EMPTY" 'Ctrl+c:cancel'
# Capture is consulted for grok only.
case_classify cap.claude-never tmux capbusy claude "$S_EMPTY"

# --- the live wrapper, WIRED ----------------------------------------------------------
case_live live.alive tmux alive claude "$S_ARMED"
case_live live.alive-idle tmux alive claude "$S_IDLE"
case_live live.gone tmux gone claude "$S_ARMED"
case_live live.gone-empty tmux gone claude "$S_EMPTY"
case_live live.gone-label tmux gone claude "$S_ARMED" 'fm-t1'
case_live live.alive-target-empty tmux '' claude "$S_ARMED"
# Endpoint death outranks a busy record, and never yields busy.
case_live live.gone-outranks-record tmux gone pi "$S_PI"
# The live wrapper does NOT forward its label as a tail, so a grok task with a
# live endpoint still goes through capture.
case_live live.grok-capture tmux alivecapbusy grok "$S_EMPTY"
case_live live.grok-nocap tmux alivenocap grok "$S_EMPTY"

# --- the meta wrapper, WIRED -----------------------------------------------------------
case_meta meta.claude "$META_CLAUDE" "$S_ARMED"
case_meta meta.claude-idle "$META_CLAUDE" "$S_IDLE"
case_meta meta.no-window "$META_NOWIN" "$S_ARMED"
case_meta meta.absent-wired "$META_MISSING" "$S_ARMED"
# The harness recorded in the meta decides trust, so a pi-ext record under a
# claude meta is a source mismatch.
case_meta meta.pi-harness "$META_PI" "$S_PI"
case_meta meta.pi-harness-claude-record "$META_CLAUDE" "$S_PI"
# backend= is read from the meta too, so a herdr task reaches the native arm.
case_meta meta.herdr-native "$META_HERDR" "$S_EMPTY"
case_meta meta.herdr-record-wins "$META_HERDR" "$S_IDLE"

case_isbusy busy.live-native herdr s:nativebusy claude "$S_EMPTY"
case_isbusy busy.native-idle herdr s:nativeidle claude "$S_EMPTY"

phase_run phase2

unset -f fm_backend_target_exists fm_backend_busy_state fm_backend_capture
unset -f fm_meta_get fm_backend_of_meta fm_backend_target_of_meta

# ==============================================================================
# PHASE 3 - the FM_BUSY_REGEX operator override.
#
# Its own phase because it is process-wide environment state. Prefix
# assignments carry it to the bash oracle and to the pwsh child alike, with no
# subshell (see the assertion-bookkeeping note above).
# ==============================================================================

phase_begin none

FM_BUSY_REGEX='thinking' case_grok ovr.match 'thinking hard'
FM_BUSY_REGEX='thinking' case_grok ovr.default-no-longer-matches 'Ctrl+c:cancel'
FM_BUSY_REGEX='thinking' case_grok ovr.case-insensitive 'THINKING HARD'
FM_BUSY_REGEX='busy|churning' case_grok ovr.alternation 'churning away'
FM_BUSY_REGEX='busy|churning' case_grok ovr.alternation-miss 'resting'
FM_BUSY_REGEX='^step [0-9]+' case_grok ovr.anchored-class 'step 42 of 99'
FM_BUSY_REGEX='^step [0-9]+' case_grok ovr.anchored-miss 'at step 42'
FM_BUSY_REGEX='thinking' case_classify ovr.classify-grok tmux w1 grok "$S_EMPTY" 'thinking hard'
FM_BUSY_REGEX='thinking' case_classify ovr.classify-claude tmux w1 claude "$S_EMPTY" 'thinking hard'

FM_BUSY_REGEX='thinking' phase_run phase3-thinking

# The second override needs a different value, so it needs its own batch.
phase_begin none
FM_BUSY_REGEX='busy|churning' case_grok ovr2.alternation 'churning away'
FM_BUSY_REGEX='busy|churning' case_grok ovr2.miss 'Ctrl+c:cancel'
FM_BUSY_REGEX='busy|churning' phase_run phase3-alternation

# ==============================================================================
# Module hygiene
# ==============================================================================

import_noise=$(pwsh -NoProfile -Command "Import-Module '$MOD' -Force" 2>&1)
assert_same "importing the module emits nothing" "" "$import_noise"

# The module must be importable STANDALONE - no reliance on a caller having
# imported anything else - and every exported function must be present under the
# name the mapping table in its header promises (R4's "evidence to demand").
EXPECTED_EXPORTS='Get-FmBusyClassification Get-FmBusyCurrentGen Get-FmBusyGenPath Get-FmBusyLibVersion Get-FmBusyLiveClassification Get-FmBusyMetaClassification Get-FmBusyRecordPath Get-FmBusySourcesForHarness Read-FmBusyRecord Test-FmBusy Test-FmBusyCodexAppServerObservable Test-FmBusyCodexHooksVerified Test-FmBusyCodexSemanticSource Test-FmBusyGrokTail Test-FmBusyKimiVerified Test-FmBusySourceTrusted Test-FmBusyToken'
actual_exports=$(pwsh -NoProfile -Command "Import-Module '$MOD' -Force; (Get-Command -Module fm-busy-lib | Sort-Object Name | ForEach-Object { \$_.Name }) -join ' '" 2>&1)
assert_same "exported surface matches the header mapping table" "$EXPECTED_EXPORTS" "$actual_exports"

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-busy-lib.psm1 differs from its bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. This is a floor, not a ceiling: adding cases is
# meant to be cheap, but DROPPING them fails the run instead of quietly
# shrinking it into a green one.
MIN_ASSERTIONS=170
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-busy-lib.psm1 matches the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-busy-lib-psm1.test.sh: all assertions passed\n'
