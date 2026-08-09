#!/usr/bin/env bash
# tests/fm-marker-session-psm1.test.sh - ONE differential behavior test for the
# three W3-marker-session PowerShell twins:
#
#   bin/fm-marker-lib.psm1        vs  bin/fm-marker-lib.sh
#   bin/fm-session-lock-lib.psm1  vs  bin/fm-session-lock-lib.sh
#   bin/fm-pending-reply-lib.psm1 vs  bin/fm-pending-reply-lib.sh
#
# The bash tree is the ORACLE. Every assertion names the module it covers with a
# [marker], [lock] or [pending] prefix, so a failure says which twin broke
# without reading the case.
#
# WHY THIS SUITE IS WORTH ITS RUNTIME.
#   [lock]     state/.lock holds the harness pid. If identity resolution fails,
#              firstmate runs PERMANENTLY READ-ONLY - no spawn, steer, merge or
#              wake drain. If the two worlds resolve DIFFERENT pids for one
#              session, a lock written by bash is unreadable to PowerShell and
#              the same outcome arrives silently. The single highest-value
#              assertion in this file is that both twins return the SAME pid,
#              and the second is that a DIFFERENT session's pid correctly FAILS
#              the ownership match - an ownership test that always says yes is
#              worse than none.
#   [pending]  two digests land in DURABLE RECORD FIELDS the other language
#              later compares, so a mismatch makes every tick believe the world
#              changed and rewrite the record forever.
#   [marker]   the from-firstmate marker bytes are what a secondmate recognizes;
#              a drift there silently unroutes every relayed request.
#
# THE ONE RULE THAT DECIDES WHETHER THIS SUITE FINISHES: BATCH pwsh. A bare
# `pwsh -NoProfile -Command "exit 0"` costs ~4.8s here, so a pwsh per case turns
# this into pure interpreter startup and it times out with ZERO output. This
# suite spawns pwsh a small CONSTANT number of times: one batched phase for
# every case, plus one import-hygiene check.
#
# The traps this is built around, all previously paid for in this repo: no
# `( ... )` subshell ever holds an ASSERTION (a subshell cannot reach the
# parent's counters, so a failure would vanish as a FALSE PASS - subshells are
# used only to CAPTURE an oracle value); no probe is keyed by a PATH, because
# the two worlds spell paths differently; per-case environment travels in the
# case RECORD, never in a bash prefix assignment; and a stub a module must find
# is declared `function global:`, because Get-Command inside a .psm1 does not
# search an `&`-invoked script's own scope.
#
# Every path handed to pwsh, INCLUDING the Import-Module paths, goes through
# fm_test_native_path.
#
# Skips cleanly where pwsh is absent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for m in fm-marker-lib fm-session-lock-lib fm-pending-reply-lib; do
  [ -f "$ROOT/bin/$m.psm1" ] || fail "bin/$m.psm1 is missing"
done
MARKER_MOD=$(fm_test_native_path "$ROOT/bin/fm-marker-lib.psm1")
LOCK_MOD=$(fm_test_native_path "$ROOT/bin/fm-session-lock-lib.psm1")
PENDING_MOD=$(fm_test_native_path "$ROOT/bin/fm-pending-reply-lib.psm1")

TMP_ROOT=$(fm_test_tmproot fm-marker-session-psm1)
B_BASE="$TMP_ROOT/bash"
P_BASE="$TMP_ROOT/ps"
mkdir -p "$B_BASE" "$P_BASE"

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
mkdir -p "$FM_STATE_OVERRIDE"
# Deterministic clock for every record the pending machinery writes, on BOTH
# sides. Without it the two snapshots run minutes apart and every epoch field
# differs for reasons that have nothing to do with the conversion.
export FM_PENDING_REPLY_NOW=1700000000

# --- the oracles --------------------------------------------------------------
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

# --- assertion bookkeeping ----------------------------------------------------
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

UNESC=
unesc() {
  local v=$1
  v=${v//@TAB@/$'\t'}
  v=${v//@LF@/$'\n'}
  v=${v//@CR@/$'\r'}
  v=${v//@SP@/ }
  v=${v//@ACUTE@/$'\u00E9'}
  v=${v//@EMDASH@/$'\u2014'}
  UNESC=$v
}

hex() {  # <value>
  local o
  o=$(printf '%s' "$1" | od -An -tx1)
  o=${o// /}
  printf '%s' "${o//$'\n'/}"
}

# --- the case file ------------------------------------------------------------
# SIX fixed TAB columns: label, op, then four arguments. Empty middles are
# deliberate; the PowerShell reader asserts the field COUNT.
CASE_BUF=""
case_add() {  # <label> <op> [a1..a4]
  local label=$1 op=$2
  shift 2
  CASE_BUF="${CASE_BUF}${label}	${op}	${1:-}	${2:-}	${3:-}	${4:-}
"
}

# --- 1. [marker] the compatibility surface -----------------------------------
#
# Sourcing fm-marker-lib.sh must yield the operational-input surface; importing
# fm-marker-lib.psm1 must do the same, which PowerShell does NOT do for free.
B_MARK_HEX=$(hex "$FM_FROMFIRST_MARK")
case_add mark.hex mark.hex
B_MARK_ONCE=''
fm_message_mark_from_firstmate 'do the work' B_MARK_ONCE
B_MARK_ONCE_HEX=$(hex "$B_MARK_ONCE")
case_add mark.once mark.once
B_MARK_TWICE=''
fm_message_mark_from_firstmate "$B_MARK_ONCE" B_MARK_TWICE
B_MARK_IDEMPOTENT=$([ "$B_MARK_ONCE" = "$B_MARK_TWICE" ] && printf true || printf false)
case_add mark.idempotent mark.idempotent
B_MARK_DETECT=""
for spec in "marked:${FM_FROMFIRST_MARK}do the work" 'bare:do the work' 'labelonly:[fm-from-firstmate]do the work'; do
  name=${spec%%:*}
  if fm_message_from_firstmate "${spec#*:}"; then B_MARK_DETECT="$B_MARK_DETECT$name=true "
  else B_MARK_DETECT="$B_MARK_DETECT$name=false "; fi
done
case_add mark.detect mark.detect

# --- 2. [lock] the harness identity contract ---------------------------------
#
# The crown jewel. Both twins must resolve the SAME pid in this session even
# though bash starts its walk at $$ (an MSYS pid) and the twin starts at $PID (a
# Windows pid) - on this platform both walks come up empty and both fall through
# to the published CLAUDE_PID.
B_ANCESTRY=$(fm_harness_ancestry_pid 2>/dev/null || printf '<none>')
case_add lock.ancestry lock.ancestry
B_NATIVE_SESSION=$(fm_harness_native_session_pid 2>/dev/null || printf '<none>')
case_add lock.nativesession lock.nativesession

B_IMAGE=""
add_image() {  # <name> <image> <path>
  local name=$1
  case_add "lock.image.$name" lock.image "$2" "$3"
  if fm_harness_native_image_matches "$2" "$3"; then B_IMAGE="$B_IMAGE$name=true "
  else B_IMAGE="$B_IMAGE$name=false "; fi
}
add_image claude claude.exe 'C:\x\claude.exe'
add_image codex codex 'C:\x\codex'
add_image nodebare node.exe 'C:\x\node.exe'
add_image nodeharness node.exe 'C:\x\claude\cli.js'
add_image unrelated notepad.exe 'C:\x\notepad.exe'
add_image pi pi '/usr/bin/pi'
add_image pip pip '/usr/bin/pip'

B_INTERP=""
for img in node node.exe python python3.exe py nodemon claude.exe; do
  case_add "lock.interp.$img" lock.interp "$img"
  if fm_harness_native_image_is_interpreter "$img"; then B_INTERP="$B_INTERP$img=true "
  else B_INTERP="$B_INTERP$img=false "; fi
done

# Liveness of the real harness pid, and of a pid that cannot exist. 999983 is
# not a multiple of 4 and the NT kernel allocates pids in steps of 4, so no
# Windows process ever carries it - a negative that cannot turn positive
# mid-run, unlike a recently-killed pid on a host that recycles aggressively.
B_ALIVE_CLAUDE=$(if fm_harness_pid_alive "${CLAUDE_PID:-0}" 2>/dev/null; then printf true; else printf false; fi)
case_add lock.alive.claude lock.alive "${CLAUDE_PID:-0}"
B_ALIVE_NEVER=$(if fm_harness_pid_alive 999983 2>/dev/null; then printf true; else printf false; fi)
case_add lock.alive.never lock.alive 999983

# Ownership, in both directions. The SAFETY PROPERTY is the second one: a
# concurrent session carries a different pid and must FAIL.
B_OWNED=""
add_owned() {  # <name> <lock-content|@NONE@>
  local name=$1 content=$2 dir="$B_BASE/lock-$1"
  mkdir -p "$dir"
  case_add "lock.owned.$name" lock.owned "$name" "$content"
  if [ "$content" = '@NONE@' ]; then rm -f "$dir/.lock"; else printf '%s\n' "$content" > "$dir/.lock"; fi
  if fm_session_lock_owned_by_self "$dir"; then B_OWNED="$B_OWNED$name=true "
  else B_OWNED="$B_OWNED$name=false "; fi
}
add_owned nolock '@NONE@'
add_owned self "${CLAUDE_PID:-0}"
add_owned other 999983
add_owned garbage 'not-a-pid'
add_owned empty ''
add_owned padded "0${CLAUDE_PID:-0}"

# --- 3. [pending] pure helpers ------------------------------------------------
B_CORR=""
add_corr() {  # <name> <text>
  local name=$1
  case_add "pending.corr.$name" pending.corr "$2"
  unesc "$2"
  B_CORR="$B_CORR$name=[$(fm_pending_reply_extract_corr "$UNESC")] "
}
add_corr present 'blah corr=aabbccdd00112233 tail'
add_corr upper 'blah corr=AABBCCDD00112233 tail'
add_corr absent 'nothing here'
add_corr short 'corr=abc'
add_corr first 'corr=1111111111111111 then corr=2222222222222222'

B_SUMMARY=""
add_summary() {  # <name> <text>
  local name=$1
  case_add "pending.summary.$name" pending.summary "$2"
  unesc "$2"
  B_SUMMARY="$B_SUMMARY$name=$(hex "$(fm_pending_reply_summarize "$UNESC")") "
}
add_summary plain '@SP@@SP@a@TAB@b@SP@@SP@'
add_summary nonascii 'caf@ACUTE@@SP@and@SP@@EMDASH@'
add_summary marked "${FM_FROMFIRST_MARK}corr=aabbccdd00112233 the body"
add_summary multiline 'first@LF@second'
add_summary empty ''

B_VIA=""
add_via() {  # <name> <line>
  local name=$1
  case_add "pending.via.$name" pending.via "$2"
  unesc "$2"
  B_VIA="$B_VIA$name=$(fm_pending_reply_resolve_via_of_line "$UNESC") "
}
add_via document 'done:@SP@see@SP@data/x/report.md'
add_via reportmd 'done:@SP@report.md@SP@written'
add_via helper 'done:@SP@via-helper'
add_via status 'done:@SP@all@SP@good'
add_via pointer 'done:@SP@pointer@SP@follows'

B_RESOLVES=""
add_resolves() {  # <name> <line> <corr>
  local name=$1
  case_add "pending.resolves.$name" pending.resolves "$2" "$3"
  unesc "$2"
  if fm_pending_reply_line_resolves "$UNESC" "$3"; then B_RESOLVES="$B_RESOLVES$name=true "
  else B_RESOLVES="$B_RESOLVES$name=false "; fi
}
add_resolves match 'done:@SP@corr=aabbccdd00112233' aabbccdd00112233
add_resolves wrongcorr 'done:@SP@corr=1111111111111111' aabbccdd00112233
add_resolves selfescalation 'blocked:@SP@pending-reply-missed:@SP@task=t@SP@corr=aabbccdd00112233' aabbccdd00112233
add_resolves empty '' aabbccdd00112233

# The cksum digest, on IDENTICAL BYTES, which is the part that must agree.
B_CKSUM=""
add_cksum() {  # <name> <text>
  local name=$1
  case_add "pending.cksum.$name" pending.cksum "$2"
  unesc "$2"
  B_CKSUM="$B_CKSUM$name=$(printf '%s' "$UNESC" | cksum | awk '{printf "%s-%s", $1, $2}') "
}
add_cksum empty ''
add_cksum a 'a'
add_cksum abc 'abc'
add_cksum sentence 'hello@SP@world'
add_cksum colons 'x:y:z'
add_cksum multiline 'aaa.status@LF@bbb.status@LF@'

# The stat signature, on the SAME physical file, so all five fields must agree.
SIGFILE="$TMP_ROOT/sig.txt"
printf 'line one\n' > "$SIGFILE"
B_FILESIG=$(fm_pending_reply_file_signature "$SIGFILE")
case_add pending.filesig pending.filesig
B_FILESIG_MISSING=$(fm_pending_reply_file_signature "$TMP_ROOT/nope.txt")
case_add pending.filesig.missing pending.filesig.missing
# A file whose mtime and ctime DIFFER, so the %Z mapping is proven rather than
# assumed - a freshly created file has them equal and cannot distinguish.
TOUCHED="$TMP_ROOT/touched.txt"
printf 'one\n' > "$TOUCHED"
sleep 1
printf 'two\n' >> "$TOUCHED"
B_FILESIG_TOUCHED=$(fm_pending_reply_file_signature "$TOUCHED")
case_add pending.filesig.touched pending.filesig.touched

B_GRACE=$(fm_pending_reply_grace_secs)
B_NOW=$(fm_pending_reply_now)
B_SCHEMA=$FM_PENDING_REPLY_SCHEMA
case_add pending.consts pending.consts

# --- 4. [pending] the durable record lifecycle -------------------------------
#
# Built on each side under its own base, then compared field by field. The
# corr id is random by design, so it is EXCLUDED from the comparison and every
# other field must match.
B_LIFE_STATE="$B_BASE/life/state"
mkdir -p "$B_LIFE_STATE"
B_LIFE_CORR=$(fm_pending_reply_create "$B_BASE/life" "$B_LIFE_STATE" domain 'audit the build')
B_LIFE_REC=$(fm_pending_reply_path "$B_LIFE_STATE" "$B_LIFE_CORR")
case_add pending.life pending.life

life_fields() {  # <record> <corr> <state-root> -> stdout
  local rec=$1 corr=$2 root=$3 line key value out=''
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      corr_id|parent_home|parent_status|parent_status_scan_signature) continue ;;
    esac
    value=${value//"$corr"/@CORR@}
    value=${value//"$root"/@ROOT@}
    out="$out$key=$value;"
  done < "$rec"
  printf '%s' "$out"
}
B_LIFE_CREATED=$(life_fields "$B_LIFE_REC" "$B_LIFE_CORR" "$B_BASE")

fm_pending_reply_confirm_delivery "$B_LIFE_STATE" "$B_LIFE_CORR" >/dev/null 2>&1
B_LIFE_CONFIRM_RC=$?
B_LIFE_DELIVERED=$(life_fields "$B_LIFE_REC" "$B_LIFE_CORR" "$B_BASE")

printf 'working: still going\ndone: report corr=%s\n' "$B_LIFE_CORR" > "$B_LIFE_STATE/domain.status"
B_LIFE_RESOLVE=$(if fm_pending_reply_try_resolve "$B_LIFE_STATE" "$B_LIFE_CORR"; then printf true; else printf false; fi)
B_LIFE_RESOLVED=$(life_fields "$B_LIFE_REC" "$B_LIFE_CORR" "$B_BASE")
B_LIFE_HASOPEN=$(if fm_pending_reply_task_has_open "$B_LIFE_STATE" domain; then printf true; else printf false; fi)

# A second record that is never delivered, then discarded: a transport failure
# must not masquerade as a missed report later.
B_DISCARD_CORR=$(fm_pending_reply_create "$B_BASE/life" "$B_LIFE_STATE" other 'second request')
B_DISCARD_RC=$(if fm_pending_reply_discard_undelivered "$B_LIFE_STATE" "$B_DISCARD_CORR"; then printf true; else printf false; fi)
B_DISCARD_GONE=$([ -f "$(fm_pending_reply_path "$B_LIFE_STATE" "$B_DISCARD_CORR")" ] && printf present || printf gone)

# --- 5. [pending] corr embedding ---------------------------------------------
B_EMBED=""
add_embed() {  # <name> <message> <corr>
  local name=$1 out=''
  case_add "pending.embed.$name" pending.embed "$2" "$3"
  unesc "$2"
  fm_pending_reply_embed_corr "$UNESC" "$3" out
  B_EMBED="$B_EMBED$name=$(hex "$out") "
}
add_embed plain 'body' aabbccdd00112233
add_embed trailingnl 'body@LF@@LF@' aabbccdd00112233
add_embed replace "${FM_FROMFIRST_MARK}corr=1111111111111111 body" aabbccdd00112233
add_embed idempotent "${FM_FROMFIRST_MARK}corr=aabbccdd00112233 body" aabbccdd00112233

# --- 6. [pending] pid identity, under a SHARED synthetic /proc ----------------
#
# The only cross-world-comparable identity source: a real /proc cannot be shared
# between an MSYS process and a native one, so the suite builds one. Both worlds
# read the SAME files, so the rendered identity must be byte-identical - and the
# twin must also agree with fm-wake-lib's Get-FmPidIdentity, since this module
# duplicates it deliberately and only a test can keep them from drifting.
PROC_ROOT="$TMP_ROOT/proc"
mkdir -p "$PROC_ROOT/4242"
printf '4242 (some cmd) S 1 1 1 0 -1 0 0 0 0 0 1 2 3 4 20 0 1 0 987654 0 0 0\n' > "$PROC_ROOT/4242/stat"
printf 'bash\000-c\000true\000' > "$PROC_ROOT/4242/cmdline"
B_IDENTITY=$(FM_PROC_ROOT_OVERRIDE="$PROC_ROOT" fm_pending_reply_pid_identity 4242 2>/dev/null || printf '<none>')
case_add pending.identity pending.identity
B_IDENTITY_BAD=$(FM_PROC_ROOT_OVERRIDE="$PROC_ROOT" fm_pending_reply_pid_identity 'abc' 2>/dev/null || printf '<none>')
case_add pending.identity.bad pending.identity.bad

# --- the PowerShell side ------------------------------------------------------
QUERY="$TMP_ROOT/query.ps1"
cat > "$QUERY" <<'PS1'
#Requires -Version 7.0
# The PowerShell half of tests/fm-marker-session-psm1.test.sh.
#
# Header lines: 1 marker module, 2 session-lock module, 3 pending module,
# 4 fixture base, 5 synthetic /proc root, 6 stat-signature file, 7 the
# mtime/ctime-differing file. Case lines follow, SIX TAB columns each.
param([Parameter(Mandatory)][string]$CaseFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = @([System.IO.File]::ReadAllLines($CaseFile))
$MarkerModule = $lines[0]
$LockModule = $lines[1]
$PendingModule = $lines[2]
$Base = $lines[3]
$ProcRoot = $lines[4]
$SigFile = $lines[5]
$TouchedFile = $lines[6]
$Cases = @($lines | Select-Object -Skip 7 | Where-Object { $_ -ne '' })

$BinDir = Split-Path -Parent $MarkerModule
Import-Module (Join-Path $BinDir 'fm-common.psm1')
Import-Module $MarkerModule
Import-Module $LockModule
Import-Module $PendingModule
# fm-common LAST and -Global: this script uses its commands directly, and a
# nested import elsewhere publishes into ITS module's session state, not here.
Import-Module (Join-Path $BinDir 'fm-common.psm1') -Global
# fm-wake-lib is imported ONLY to compare its Get-FmPidIdentity against the
# pending twin's deliberate duplicate. It creates its state directory on import,
# which is exactly why fm-pending-reply-lib does not import it.
Import-Module (Join-Path $BinDir 'fm-wake-lib.psm1')

$Utf8 = [System.Text.UTF8Encoding]::new($false, $false)

function Write-Record {
    param([Parameter(Mandatory)][string]$Key, [Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { $Value = '<none>' }
    [Console]::Out.Write($Key + "`t" + (([string]$Value) -replace "`t", ' ') + "`n")
}
function Expand-Token {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text
    $t = $t.Replace('@TAB@', "`t").Replace('@LF@', "`n").Replace('@CR@', "`r").Replace('@SP@', ' ')
    $t = $t.Replace('@ACUTE@', [string][char]0x00E9).Replace('@EMDASH@', [string][char]0x2014)
    return $t
}
function ConvertTo-HexText {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $Utf8.GetBytes($Text)) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}
function Get-LifeFields {
    param([string]$Record, [string]$Corr, [string]$Root)
    $out = ''
    foreach ($line in (Get-FmFileLines $Record)) {
        if ($line -eq '') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { continue }
        $key = $line.Substring(0, $eq)
        $value = $line.Substring($eq + 1)
        if ($key -cin @('corr_id', 'parent_home', 'parent_status', 'parent_status_scan_signature')) { continue }
        $value = $value.Replace($Corr, '@CORR@').Replace($Root, '@ROOT@')
        $out += "$key=$value;"
    }
    return $out
}

$markDetectAcc = ''; $imageAcc = ''; $interpAcc = ''; $ownedAcc = ''
$corrAcc = ''; $summaryAcc = ''; $viaAcc = ''; $resolvesAcc = ''; $cksumAcc = ''
$embedAcc = ''; $aliveAcc = @{}

foreach ($case in $Cases) {
    $f = @($case.Split("`t"))
    if ($f.Count -ne 6) { Write-Record -Key 'FATAL.fieldcount' -Value "$($f.Count) in [$case]"; continue }
    $label = $f[0]; $op = $f[1]
    $a = @(1..4 | ForEach-Object { Expand-Token $f[$_ + 1] })
    $name = $label.Substring($label.LastIndexOf('.') + 1)
    try {
        switch ($op) {
            'mark.hex'   { Write-Record -Key 'mark.hex' -Value (ConvertTo-HexText (Get-FmOperationalConstant 'FM_FROMFIRST_MARK')) }
            'mark.once'  { Write-Record -Key 'mark.once' -Value (ConvertTo-HexText (Add-FmFromFirstmateMark 'do the work')) }
            'mark.idempotent' {
                $once = Add-FmFromFirstmateMark 'do the work'
                Write-Record -Key 'mark.idempotent' -Value ((Add-FmFromFirstmateMark $once) -ceq $once).ToString().ToLowerInvariant()
            }
            'mark.detect' {
                $mark = Get-FmOperationalConstant 'FM_FROMFIRST_MARK'
                foreach ($p in @(@('marked', ($mark + 'do the work')), @('bare', 'do the work'),
                                 @('labelonly', '[fm-from-firstmate]do the work'))) {
                    $markDetectAcc += "$($p[0])=$((Test-FmMessageFromFirstmate $p[1]).ToString().ToLowerInvariant()) "
                }
            }
            'lock.ancestry'      { Write-Record -Key 'lock.ancestry' -Value (Get-FmHarnessAncestryPid) }
            'lock.nativesession' { Write-Record -Key 'lock.nativesession' -Value (Get-FmHarnessNativeSessionPid) }
            'lock.image'  { $imageAcc += "$name=$((Test-FmHarnessNativeImage $a[0] $a[1]).ToString().ToLowerInvariant()) " }
            # Keyed by the ARGUMENT, not by parsing the label: an image name
            # containing a dot (node.exe) made the label-derived key collide.
            'lock.interp' { $interpAcc += "$($a[0])=$((Test-FmHarnessNativeInterpreter $a[0]).ToString().ToLowerInvariant()) " }
            'lock.alive'  { $aliveAcc[$name] = (Test-FmHarnessPidAlive $a[0]).ToString().ToLowerInvariant() }
            'lock.owned' {
                $dir = Join-Path $Base "lock-$($a[0])"
                [void][System.IO.Directory]::CreateDirectory($dir)
                $lock = Join-Path $dir '.lock'
                if ($a[1] -eq '@NONE@') {
                    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
                } else {
                    [System.IO.File]::WriteAllText($lock, $a[1] + "`n", $Utf8)
                }
                $ownedAcc += "$($a[0])=$((Test-FmSessionLockOwnedBySelf $dir).ToString().ToLowerInvariant()) "
            }
            'pending.corr'     { $corrAcc += "$name=[$(Get-FmPendingReplyCorr $a[0])] " }
            'pending.summary'  { $summaryAcc += "$name=$(ConvertTo-HexText (Get-FmPendingReplySummary $a[0])) " }
            'pending.via'      { $viaAcc += "$name=$(Get-FmPendingReplyResolveVia $a[0]) " }
            'pending.resolves' { $resolvesAcc += "$name=$((Test-FmPendingReplyResolvingLine $a[0] $a[1]).ToString().ToLowerInvariant()) " }
            'pending.cksum'    { $cksumAcc += "$name=$(Get-FmPendingReplyCksum $a[0]) " }
            'pending.embed'    { $embedAcc += "$name=$(ConvertTo-HexText (Add-FmPendingReplyCorr $a[0] $a[1])) " }
            'pending.filesig'         { Write-Record -Key 'pending.filesig' -Value (Get-FmPendingReplyFileSignature $SigFile) }
            'pending.filesig.missing' { Write-Record -Key 'pending.filesig.missing' -Value (Get-FmPendingReplyFileSignature (Join-Path $Base 'nope.txt')) }
            'pending.filesig.touched' { Write-Record -Key 'pending.filesig.touched' -Value (Get-FmPendingReplyFileSignature $TouchedFile) }
            'pending.consts' {
                Write-Record -Key 'pending.consts' -Value ("grace={0} now={1} schema={2}" -f
                    (Get-FmPendingReplyGraceSec), (Get-FmPendingReplyNow), (Get-FmPendingReplySchema))
            }
            'pending.identity' {
                $prev = $env:FM_PROC_ROOT_OVERRIDE
                $env:FM_PROC_ROOT_OVERRIDE = $ProcRoot
                try {
                    Write-Record -Key 'pending.identity' -Value (Get-FmPendingReplyPidIdentity '4242')
                    # The no-drift assertion: fm-wake-lib's own identity for the
                    # SAME synthetic /proc must render identically.
                    Write-Record -Key 'pending.identity.wake' -Value (Get-FmPidIdentity '4242')
                } finally { $env:FM_PROC_ROOT_OVERRIDE = $prev }
            }
            'pending.identity.bad' {
                $prev = $env:FM_PROC_ROOT_OVERRIDE
                $env:FM_PROC_ROOT_OVERRIDE = $ProcRoot
                try { Write-Record -Key 'pending.identity.bad' -Value (Get-FmPendingReplyPidIdentity 'abc') }
                finally { $env:FM_PROC_ROOT_OVERRIDE = $prev }
            }
            'pending.life' {
                $home_ = Join-Path $Base 'life'
                $stateDir = Join-Path $home_ 'state'
                [void][System.IO.Directory]::CreateDirectory($stateDir)
                $S = $stateDir.Replace([char]92, [char]47)
                $corr = New-FmPendingReply $home_ $S 'domain' 'audit the build'
                $rec = Get-FmPendingReplyPath $S $corr
                Write-Record -Key 'pending.life.created' -Value (Get-LifeFields $rec $corr ($Base.Replace([char]92, [char]47)))
                $rc = Confirm-FmPendingReplyDelivery $S $corr
                Write-Record -Key 'pending.life.confirmrc' -Value $rc
                Write-Record -Key 'pending.life.delivered' -Value (Get-LifeFields $rec $corr ($Base.Replace([char]92, [char]47)))
                [System.IO.File]::WriteAllText((Join-Path $stateDir 'domain.status'),
                    "working: still going`ndone: report corr=$corr`n", $Utf8)
                Write-Record -Key 'pending.life.resolve' -Value (Resolve-FmPendingReply $S $corr).ToString().ToLowerInvariant()
                Write-Record -Key 'pending.life.resolved' -Value (Get-LifeFields $rec $corr ($Base.Replace([char]92, [char]47)))
                Write-Record -Key 'pending.life.hasopen' -Value (Test-FmPendingReplyTaskHasOpen $S 'domain').ToString().ToLowerInvariant()
                $d = New-FmPendingReply $home_ $S 'other' 'second request'
                Write-Record -Key 'pending.life.discardrc' -Value (Remove-FmPendingReplyUndelivered $S $d).ToString().ToLowerInvariant()
                $gone = if ([System.IO.File]::Exists((ConvertTo-FmNativePath (Get-FmPendingReplyPath $S $d)))) { 'present' } else { 'gone' }
                Write-Record -Key 'pending.life.discardgone' -Value $gone
            }
            default { Write-Record -Key "FATAL.$label" -Value "unknown op [$op]" }
        }
    } catch {
        Write-Record -Key "$label.error" -Value $_.Exception.Message
    }
}

if ($markDetectAcc) { Write-Record -Key 'mark.detect' -Value $markDetectAcc }
if ($imageAcc)      { Write-Record -Key 'lock.image' -Value $imageAcc }
if ($interpAcc)     { Write-Record -Key 'lock.interp' -Value $interpAcc }
if ($ownedAcc)      { Write-Record -Key 'lock.owned' -Value $ownedAcc }
if ($corrAcc)       { Write-Record -Key 'pending.corr' -Value $corrAcc }
if ($summaryAcc)    { Write-Record -Key 'pending.summary' -Value $summaryAcc }
if ($viaAcc)        { Write-Record -Key 'pending.via' -Value $viaAcc }
if ($resolvesAcc)   { Write-Record -Key 'pending.resolves' -Value $resolvesAcc }
if ($cksumAcc)      { Write-Record -Key 'pending.cksum' -Value $cksumAcc }
if ($embedAcc)      { Write-Record -Key 'pending.embed' -Value $embedAcc }
foreach ($k in $aliveAcc.Keys) { Write-Record -Key "lock.alive.$k" -Value $aliveAcc[$k] }

# The marker shim's export list must MIRROR fm-operational-input's, or a
# consumer loads this path and cannot find its function.
#
# fm-operational-input is imported EXPLICITLY here to be asked. It is a NESTED
# module of the shim, so it publishes into the SHIM's session state and does not
# appear in this session at all - `Get-Command -Module fm-operational-input`
# returns nothing before this import, which is precisely why the shim has to
# re-export by name in the first place.
Import-Module (Join-Path $BinDir 'fm-operational-input.psm1')
# ExportedCommands, NOT Get-Command -Module: a re-exported command is
# ATTRIBUTED TO ITS ORIGIN module, so once fm-operational-input is imported in
# its own right `Get-Command -Module fm-marker-lib` returns ZERO commands even
# though the shim exports all fourteen (measured). ExportedCommands is
# definitional and does not move with attribution.
$shim = @((Get-Module fm-marker-lib).ExportedCommands.Keys | Sort-Object)
$src = @((Get-Module fm-operational-input).ExportedCommands.Keys | Sort-Object)
Write-Record -Key 'marker.mirror.shim' -Value ($shim -join ',')
Write-Record -Key 'marker.mirror' -Value (($shim -join ',') -ceq ($src -join ','))
PS1
QUERY_N=$(fm_test_native_path "$QUERY")

CASES="$TMP_ROOT/cases.txt"
{
  printf '%s\n%s\n%s\n' "$MARKER_MOD" "$LOCK_MOD" "$PENDING_MOD"
  printf '%s\n' "$(fm_test_native_path "$P_BASE")"
  printf '%s\n' "$(fm_test_native_path "$PROC_ROOT")"
  printf '%s\n' "$(fm_test_native_path "$SIGFILE")"
  printf '%s\n' "$(fm_test_native_path "$TOUCHED")"
  printf '%s' "$CASE_BUF"
} > "$CASES"
CASES_N=$(fm_test_native_path "$CASES")

PS_OUT="$TMP_ROOT/ps.out"
PS_ERR="$TMP_ROOT/ps.err"
pwsh -NoProfile -Command "& '$QUERY_N' -CaseFile '$CASES_N'" > "$PS_OUT" 2> "$PS_ERR" \
  || fail "the PowerShell query script failed:"$'\n'"$(cat "$PS_ERR")"

PS_LINES=()
while IFS= read -r ps_line; do
  [ -n "$ps_line" ] && PS_LINES+=("$ps_line")
done < "$PS_OUT"
FM_PSV=
psv() {
  local key=$1 line
  FM_PSV='<missing>'
  for line in ${PS_LINES+"${PS_LINES[@]}"}; do
    case "$line" in "$key"$'\t'*) FM_PSV=${line#*$'\t'}; return 0 ;; esac
  done
}

# --- 0. nothing may throw, and no case may lose a field -----------------------
ps_errors=''
for ps_line in ${PS_LINES+"${PS_LINES[@]}"}; do
  case "$ps_line" in
    *.error$'\t'*|FATAL.*) ps_errors="$ps_errors ${ps_line%%$'\t'*}" ;;
  esac
done
assert_same "[all] no function throws and every case record kept its 6 fields" "" "${ps_errors# }"

# --- 1. marker ----------------------------------------------------------------
psv mark.hex;        assert_same "[marker] the from-firstmate marker bytes are identical" "$B_MARK_HEX" "$FM_PSV"
psv mark.once;       assert_same "[marker] marking bare content produces identical bytes" "$B_MARK_ONCE_HEX" "$FM_PSV"
psv mark.idempotent; assert_same "[marker] marking already-marked content is idempotent" "$B_MARK_IDEMPOTENT" "$FM_PSV"
psv mark.detect;     assert_same "[marker] the detector agrees on marked, bare, and label-without-U+2063" "$B_MARK_DETECT" "$FM_PSV"
psv marker.mirror;   assert_same "[marker] the shim re-exports EXACTLY fm-operational-input's surface" "True" "$FM_PSV"

# --- 2. session lock ----------------------------------------------------------
psv lock.ancestry
assert_same "[lock] BOTH twins resolve the SAME harness pid for this session" "$B_ANCESTRY" "$FM_PSV"
psv lock.nativesession
assert_same "[lock] the CLAUDE_PID fallback resolves identically" "$B_NATIVE_SESSION" "$FM_PSV"
psv lock.image;  assert_same "[lock] the native image rule agrees for every image/path shape" "$B_IMAGE" "$FM_PSV"
psv lock.interp; assert_same "[lock] the bare-interpreter allow list agrees exactly" "$B_INTERP" "$FM_PSV"
psv lock.alive.claude
assert_same "[lock] the live harness pid reads alive in both worlds" "$B_ALIVE_CLAUDE" "$FM_PSV"
psv lock.alive.never
assert_same "[lock] a pid that cannot exist reads dead in both worlds" "$B_ALIVE_NEVER" "$FM_PSV"
psv lock.owned
assert_same "[lock] lock ownership agrees, INCLUDING that another session's pid fails the match" "$B_OWNED" "$FM_PSV"
# Asserted against the contract too, not only against agreement: two twins that
# both said "yes, mine" would agree and be catastrophically wrong.
assert_same "[lock] the ownership test is not a tautology: self true, other false" \
  "self=true other=false" \
  "$(printf 'self=%s other=%s' \
      "$(case "$B_OWNED" in *'self=true '*) printf true ;; *) printf false ;; esac)" \
      "$(case "$B_OWNED" in *'other=true '*) printf true ;; *) printf false ;; esac)")"

# --- 3. pending-reply pure helpers -------------------------------------------
psv pending.corr;     assert_same "[pending] corr extraction agrees, including the uppercase fold and the first-match rule" "$B_CORR" "$FM_PSV"
psv pending.summary;  assert_same "[pending] the summary is byte-identical, including the non-ASCII strip" "$B_SUMMARY" "$FM_PSV"
psv pending.via;      assert_same "[pending] resolve-via classification agrees in the twin's arm order" "$B_VIA" "$FM_PSV"
psv pending.resolves; assert_same "[pending] line-resolves agrees, including refusing the parent's own escalation line" "$B_RESOLVES" "$FM_PSV"
psv pending.cksum;    assert_same "[pending] POSIX cksum is identical on identical bytes" "$B_CKSUM" "$FM_PSV"
psv pending.embed;    assert_same "[pending] corr embedding is byte-identical, including trailing newlines and replacement" "$B_EMBED" "$FM_PSV"
psv pending.consts;   assert_same "[pending] the published constants agree" \
  "grace=$B_GRACE now=$B_NOW schema=$B_SCHEMA" "$FM_PSV"

# --- 4. the stat signature ----------------------------------------------------
psv pending.filesig
assert_same "[pending] the stat signature agrees on the SAME file, all five fields" "$B_FILESIG" "$FM_PSV"
psv pending.filesig.missing
assert_same "[pending] a missing file signs as 'missing' in both worlds" "$B_FILESIG_MISSING" "$FM_PSV"
psv pending.filesig.touched
assert_same "[pending] the signature agrees for a file whose mtime and ctime DIFFER" "$B_FILESIG_TOUCHED" "$FM_PSV"

# --- 5. pid identity ----------------------------------------------------------
psv pending.identity
assert_same "[pending] the /proc identity is byte-identical over a SHARED synthetic /proc" "$B_IDENTITY" "$FM_PSV"
psv pending.identity.wake
assert_same "[pending] the deliberate duplicate has NOT drifted from fm-wake-lib's identity" "$B_IDENTITY" "$FM_PSV"
psv pending.identity.bad
assert_same "[pending] a non-numeric pid declines in both worlds" "$B_IDENTITY_BAD" "$FM_PSV"

# --- 6. the durable record lifecycle -----------------------------------------
psv pending.life.created
assert_same "[pending] a freshly created record has identical fields in both worlds" "$B_LIFE_CREATED" "$FM_PSV"
psv pending.life.confirmrc
assert_same "[pending] confirming delivery returns the same status" "$B_LIFE_CONFIRM_RC" "$FM_PSV"
psv pending.life.delivered
assert_same "[pending] the record after delivery is identical, and delivery did NOT resolve it" "$B_LIFE_DELIVERED" "$FM_PSV"
psv pending.life.resolve
assert_same "[pending] a correlated parent report resolves in both worlds" "$B_LIFE_RESOLVE" "$FM_PSV"
psv pending.life.resolved
assert_same "[pending] the resolved record is identical, including resolved_via and field order" "$B_LIFE_RESOLVED" "$FM_PSV"
psv pending.life.hasopen
assert_same "[pending] a resolved record leaves no open pending reply for the task" "$B_LIFE_HASOPEN" "$FM_PSV"
psv pending.life.discardrc
assert_same "[pending] discarding an undelivered expectation succeeds in both worlds" "$B_DISCARD_RC" "$FM_PSV"
psv pending.life.discardgone
assert_same "[pending] the discarded record is gone in both worlds" "$B_DISCARD_GONE" "$FM_PSV"

# --- 7. hygiene ---------------------------------------------------------------
import_noise=$(pwsh -NoProfile -Command "Import-Module '$MARKER_MOD' -Force; Import-Module '$LOCK_MOD' -Force; Import-Module '$PENDING_MOD' -Force" 2>&1)
assert_same "[all] importing all three modules emits nothing" "" "$import_noise"

# --- report -------------------------------------------------------------------
if [ -s "$PS_ERR" ]; then
  printf '# PowerShell stderr:\n' >&2
  sed 's/^/#   /' "$PS_ERR" >&2
fi
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W3-marker-session twins differ from their oracles (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# An EXACT total observed on a green run, not a guess: dropping a case fails the
# run instead of quietly shrinking it.
MIN_ASSERTIONS=36
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-marker-lib.psm1, fm-session-lock-lib.psm1 and fm-pending-reply-lib.psm1 hold their contracts across %d assertions\n' "$ASSERTIONS"
printf '# fm-marker-session-psm1.test.sh: all assertions passed\n'
