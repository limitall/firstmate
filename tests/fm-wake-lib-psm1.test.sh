#!/usr/bin/env bash
# tests/fm-wake-lib-psm1.test.sh - behavior test for bin/fm-wake-lib.psm1, the
# PowerShell twin of the durable wake queue and the watcher singleton lock.
#
# This is a DIFFERENTIAL test: bash is the ORACLE. Every pure function is driven
# with one fixture and both answers are compared BYTE for byte (values are hex
# encoded before comparison, so an empty field, a trailing space, a CR or a
# multibyte glyph cannot hide inside a "looks equal" string compare).
#
# The second half is the part that actually matters, and it is why risk R2 in
# docs/powershell-port-inventory.md exists: during the conversion a Git Bash
# process and a PowerShell process contend for the SAME state/.watch.lock, and
# if the two worlds publish or read different on-disk representations, both can
# believe they hold it and the watcher singleton silently stops being a
# singleton. So this file proves, with real processes:
#   * a lock taken by BASH is seen as held by POWERSHELL, and the bash holder's
#     lock is left untouched;
#   * a lock taken by POWERSHELL publishes the identical representation the
#     bash reader expects, and bash refuses to create over it;
#   * a lock released by either world is acquirable by the other;
#   * a wake queue written by either world drains identically in both,
#     including a record with an EMPTY MIDDLE FIELD.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7.
#
# Windows note: PowerShell cannot resolve MSYS paths (verified - .NET reads
# /tmp/x as C:\tmp\x), so EVERY path handed to pwsh here, including the
# Import-Module paths, goes through fm_test_native_path first.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-wake-lib-psm1)
LIB="$ROOT/bin/fm-wake-lib.sh"
[ -f "$ROOT/bin/fm-wake-lib.psm1" ] || fail "bin/fm-wake-lib.psm1 is missing"
[ -f "$ROOT/tests/wake-helpers.psm1" ] || fail "tests/wake-helpers.psm1 is missing"
MOD=$(fm_test_native_path "$ROOT/bin/fm-wake-lib.psm1")
HELPERS=$(fm_test_native_path "$ROOT/tests/wake-helpers.psm1")

# Results live in plain shell variables and every scoped case uses a PREFIX
# ASSIGNMENT rather than a `( ... )` subshell: a subshell cannot report a
# failure back to the parent's counters, so a bookkeeping scheme that can lose a
# failure would let this suite certify work it never checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""
assert_same() {  # <label> <expected(bash oracle)> <actual(powershell)>
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

assert_true() {  # <label> <condition-result:0|1> <detail>
  local label=$1 rc=$2 detail=${3:-}
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$rc" -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  ${detail}
"
  fi
}

# ---------------------------------------------------------------------------
# Shared fixture. Both worlds read exactly these bytes.
# ---------------------------------------------------------------------------
FIX="$TMP_ROOT/fixture"
FSTATE="$FIX/state"
FPROC="$FIX/proc"
mkdir -p "$FSTATE" "$FPROC/4242"

# Fake /proc, byte-identical to the fixture tests/fm-watcher-lock.test.sh uses.
# The comm field deliberately contains ')' and spaces so a parser that splits on
# the FIRST ')' shifts every later field and produces the wrong starttime.
printf '4242 (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20 21 22\n' > "$FPROC/4242/stat"
printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$FPROC/4242/cmdline"

# Status files for the bounded-read and annotation caps.
printf 'working: first\n\ndone: latest event\n' > "$FSTATE/task.status"
printf 'working: old turn-end context\n' > "$FSTATE/turn-only.status"
: > "$FSTATE/empty.status"
mkdir -p "$FSTATE/dir.status"
awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$FSTATE/huge.status"
i=1
while [ "$i" -le 9 ]; do
  awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$FSTATE/many-$i.status"
  i=$((i + 1))
done
# A trailing-blank-line status: the last NON-BLANK line is the event, and the
# blank tail must not become one.
printf 'done: trailing blanks follow\n\n\n' > "$FSTATE/blanks.status"
# TAB and CR inside an event line must be flattened to spaces by both worlds.
printf 'done: has\ta tab and\ra cr\n' > "$FSTATE/control.status"

# A queue file exercising every parsing hazard at once: duplicate signal keys,
# two DIFFERENT heartbeat keys that must still collapse onto one record, a row
# with an EMPTY KEY AND EMPTY PAYLOAD, a row with an empty trailing field, a row
# with too few fields, a row with MORE than five fields, and a blank line.
QFIX="$FSTATE/queue-fixture"
{
  printf '1000\t1\tsignal\ta.status\tp1\n'
  printf '1000\t2\theartbeat\thb-one\tnote\n'
  printf '1000\t3\tsignal\ta.status\tp2\n'
  printf '1000\t4\theartbeat\thb-two\tother\n'
  printf '1000\t5\tsignal\t\t\n'
  printf '1000\t6\tstale\tw:1\t\n'
  printf 'short-row-without-tabs\n'
  printf '1000\t7\tcheck\tc\td\te\n'
  printf '\n'
  printf '1000\t8\tsignal\t\tsecond-empty-key\n'
} > "$QFIX"

# The deduped-row set handed to the annotation phase. Row 3 has an EMPTY KEY on
# purpose: the bash twin parses these rows with `IFS=<TAB> read`, TAB is IFS
# whitespace, so bash COLLAPSES the empty field and the payload lands in the key
# position. That mis-parse is the CONTRACT here, not a defect to fix on one side.
ROWS=$(
  printf '1000\t1\tsignal\ttask.status\tsignal: task\n'
  printf '1000\t2\tsignal\tturn-only.turn-ended\tsignal: turn-only\n'
  printf '1000\t3\tsignal\t\ttask.status\n'
  printf '1000\t4\tsignal\tarbitrary-key\tsignal: nope\n'
  printf '1000\t5\tcheck\ttask.check.sh\tcheck: payload\n'
  printf '1000\t6\theartbeat\theartbeat\theartbeat\n'
  printf '1000\t7\tsignal\tblanks.status\tsignal: blanks\n'
  printf '1000\t8\tsignal\tcontrol.status\tsignal: control\n'
  printf '1000\t9\tsignal\tempty.status\tsignal: empty\n'
  printf '1000\t10\tsignal\tmissing.status\tsignal: missing\n'
  printf '1000\t11\tsignal\tdir.status\tsignal: dir\n'
)
ROWS_CAP=$(
  printf '1000\t1\tsignal\thuge.status\tsignal: huge\n'
  i=1
  while [ "$i" -le 9 ]; do
    printf '1000\t%d\tsignal\tmany-%d.status\tsignal: many\n' "$((i + 1))" "$i"
    i=$((i + 1))
  done
)
printf '%s' "$ROWS" > "$FIX/rows"
printf '%s' "$ROWS_CAP" > "$FIX/rows-cap"

# A lock directory with a known-old mtime, for the mid-acquire freshness window.
mkdir -p "$FSTATE/.old.lock"
touch -t 200001010000 "$FSTATE/.old.lock"
mkdir -p "$FSTATE/.fresh.lock"

# ---------------------------------------------------------------------------
# Pure-function probes: one bash run and one pwsh run over the same fixture,
# each printing "<key><TAB><hex of value>" lines. Hex because several values
# legitimately contain TABs, CRs, trailing spaces, or nothing at all.
# ---------------------------------------------------------------------------
cat > "$TMP_ROOT/probe.sh" <<'PROBE_SH'
#!/usr/bin/env bash
set -u
LIB=$1; FIX=$2
# shellcheck disable=SC1090
. "$LIB"

emit() {  # <key> <value>
  printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | od -An -v -tx1 | tr -d '[:space:]')"
}

for p in /a/b/c /a a/b abc / /a/; do
  fm_lock_path_dir "$p"; emit "path_dir:$p" "$FM_LOCK_PATH_DIR"
done

# Keyed by INDEX, not by the path: the fixture root is spelled differently in
# each world (/tmp/... under MSYS bash, a native drive path under PowerShell),
# so a key containing it could never match across the boundary - every case
# read as MISSING-KEY regardless of whether the VALUES agreed. The value is
# still compared, which is what this probe is actually about.
_abs_i=0
for p in "$FIX/state/.x.lock" "$FIX/state/./.x.lock" "$FIX/state/sub/../.x.lock"; do
  _abs_i=$((_abs_i + 1))
  emit "abs_path:$_abs_i" "$(fm_lock_abs_path "$p" 2>/dev/null || printf 'FAIL')"
done

lock="$FIX/state/.x.lock"
for cand in \
  "$FIX/state/.x.lock.owner.abc123" \
  "$FIX/state/.x.lock.owner." \
  "$FIX/state/.y.lock.owner.abc123" \
  "$FIX/other/.x.lock.owner.abc123" \
  "relative/.x.lock.owner.abc123" \
  ""; do
  if fm_lock_owner_shape_ok "$lock" "$cand"; then emit "owner_shape:$cand" ok; else emit "owner_shape:$cand" no; fi
done

for key in task.status task.turn-ended .hidden.status .status a-b_c.9.status "bad/key.status" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.status" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.status" \
  plain "x.turn-ended" "" ; do
  if fm_wake_status_key_map "$key"; then
    emit "status_key:$key" "$FM_WAKE_STATUS_KEY|$FM_WAKE_STATUS_HISTORICAL"
  else
    emit "status_key:$key" FAIL
  fi
done

emit "clean_field:tabs" "$(printf 'a\tb' | fm_wake_clean_field)"
emit "clean_field:crlf" "$(printf 'a\r\nb' | fm_wake_clean_field)"
emit "clean_field:plain" "$(printf 'plain value' | fm_wake_clean_field)"
emit "clean_field:empty" "$(printf '' | fm_wake_clean_field)"
emit "clean_field:utf8" "$(printf '\xe2\x9d\xaf\tx' | fm_wake_clean_field)"

emit "identity:proc" "$(FM_PROC_ROOT_OVERRIDE="$FIX/proc" fm_pid_identity 4242 || printf 'FAIL')"
emit "identity:missing" "$(FM_PROC_ROOT_OVERRIDE="$FIX/proc" fm_pid_identity 4243 2>/dev/null || printf 'FAIL')"
emit "identity:nonnumeric" "$(fm_pid_identity 'abc' 2>/dev/null || printf 'FAIL')"

emit "mtime:old" "$(fm_path_mtime "$FIX/state/.old.lock")"
emit "mtime:missing" "$(fm_path_mtime "$FIX/state/nope" || printf 'FAIL')"
emit "age:missing" "$(fm_path_age "$FIX/state/nope")"

if fm_lock_mid_acquire_is_fresh "$FIX/state/.fresh.lock" ""; then emit "midfresh:fresh-empty" yes; else emit "midfresh:fresh-empty" no; fi
if fm_lock_mid_acquire_is_fresh "$FIX/state/.old.lock" ""; then emit "midfresh:old-empty" yes; else emit "midfresh:old-empty" no; fi
if fm_lock_mid_acquire_is_fresh "$FIX/state/.fresh.lock" 12345; then emit "midfresh:fresh-pid" yes; else emit "midfresh:fresh-pid" no; fi

emit "deduped" "$(fm_wake_print_deduped "$FIX/state/queue-fixture")"
emit "manifest" "$(fm_wake_annotation_manifest "$(cat "$FIX/rows")")"
emit "annotations" "$(fm_wake_print_annotations "$(cat "$FIX/rows")")"
emit "annotations_cap" "$(fm_wake_print_annotations "$(cat "$FIX/rows-cap")")"

for s in task.status blanks.status control.status empty.status missing.status dir.status huge.status; do
  if fm_wake_latest_event "$FIX/state/$s" 8192; then
    emit "event:$s" "0|$FM_WAKE_EVENT_LINE|$FM_WAKE_EVENT_TRUNCATED"
  else
    emit "event:$s" "1||false"
  fi
done

if fm_lock_symlinks_work "$FIX/state/.probe.lock"; then emit "symlinks_work" yes; else emit "symlinks_work" no; fi

rc=0
err=$(fm_wake_append bogus k p 2>&1 >/dev/null) || rc=$?
emit "append_bad_kind" "$rc|$err"
PROBE_SH

# Arguments arrive through $args rather than a param() block: a param() block
# has to be the FIRST statement in a script, which the Set-StrictMode /
# ErrorActionPreference preamble this repo requires already occupies.
cat > "$TMP_ROOT/probe.ps1" <<'PROBE_PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = $args[0]
$fix = $args[1]
Import-Module $modulePath -Force
# fm-wake-lib imports fm-common for its OWN scope; a module does not re-export
# what it imports, so this probe imports it too rather than reaching through.
Import-Module (Join-Path ([System.IO.Path]::GetDirectoryName($modulePath)) 'fm-common.psm1') -Force

function Get-Hex {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Text)) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}
function Write-Probe {
    param([string]$Key, [AllowEmptyString()][AllowNull()][string]$Value)
    [Console]::Out.Write($Key + "`t" + (Get-Hex -Text $Value) + "`n")
}

foreach ($p in @('/a/b/c', '/a', 'a/b', 'abc', '/', '/a/')) {
    Write-Probe -Key "path_dir:$p" -Value (Get-FmLockPathDir -Path $p)
}

# Index-keyed to match the bash side; see the note there.
$absIndex = 0
foreach ($p in @("$fix/state/.x.lock", "$fix/state/./.x.lock", "$fix/state/sub/../.x.lock")) {
    $absIndex++
    $abs = Get-FmLockAbsPath -Path $p
    if ([string]::IsNullOrEmpty($abs)) { $abs = 'FAIL' }
    Write-Probe -Key "abs_path:$absIndex" -Value $abs
}

$lock = "$fix/state/.x.lock"
foreach ($cand in @(
        "$fix/state/.x.lock.owner.abc123",
        "$fix/state/.x.lock.owner.",
        "$fix/state/.y.lock.owner.abc123",
        "$fix/other/.x.lock.owner.abc123",
        'relative/.x.lock.owner.abc123',
        '')) {
    $verdict = if (Test-FmLockOwnerShapeOk -LockPath $lock -Candidate $cand) { 'ok' } else { 'no' }
    Write-Probe -Key "owner_shape:$cand" -Value $verdict
}

foreach ($key in @('task.status', 'task.turn-ended', '.hidden.status', '.status', 'a-b_c.9.status',
        'bad/key.status',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.status',
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.status',
        'plain', 'x.turn-ended', '')) {
    $mapped = Get-FmWakeStatusKeyMap -Key $key
    if ($null -eq $mapped) {
        Write-Probe -Key "status_key:$key" -Value 'FAIL'
    } else {
        $historical = if ($mapped.Historical) { 'true' } else { 'false' }
        Write-Probe -Key "status_key:$key" -Value "$($mapped.Key)|$historical"
    }
}

Write-Probe -Key 'clean_field:tabs' -Value (ConvertTo-FmWakeField -Text "a`tb")
Write-Probe -Key 'clean_field:crlf' -Value (ConvertTo-FmWakeField -Text "a`r`nb")
Write-Probe -Key 'clean_field:plain' -Value (ConvertTo-FmWakeField -Text 'plain value')
Write-Probe -Key 'clean_field:empty' -Value (ConvertTo-FmWakeField -Text '')
Write-Probe -Key 'clean_field:utf8' -Value (ConvertTo-FmWakeField -Text ([char]0x276F + "`tx"))

$env:FM_PROC_ROOT_OVERRIDE = "$fix/proc"
foreach ($pair in @(@('identity:proc', '4242'), @('identity:missing', '4243'), @('identity:nonnumeric', 'abc'))) {
    $value = Get-FmPidIdentity -ProcessId $pair[1]
    if ([string]::IsNullOrEmpty($value)) { $value = 'FAIL' }
    Write-Probe -Key $pair[0] -Value $value
}
$env:FM_PROC_ROOT_OVERRIDE = ''

$mtime = Get-FmPathMtime -Path "$fix/state/.old.lock"
Write-Probe -Key 'mtime:old' -Value ([string]$mtime)
$missing = Get-FmPathMtime -Path "$fix/state/nope"
Write-Probe -Key 'mtime:missing' -Value $(if ($null -eq $missing) { 'FAIL' } else { [string]$missing })
Write-Probe -Key 'age:missing' -Value ([string](Get-FmPathAge -Path "$fix/state/nope"))

foreach ($case in @(@('midfresh:fresh-empty', "$fix/state/.fresh.lock", ''),
        @('midfresh:old-empty', "$fix/state/.old.lock", ''),
        @('midfresh:fresh-pid', "$fix/state/.fresh.lock", '12345'))) {
    $verdict = if (Test-FmLockMidAcquireIsFresh -LockPath $case[1] -ProcessId $case[2]) { 'yes' } else { 'no' }
    Write-Probe -Key $case[0] -Value $verdict
}

# Command substitution strips the trailing newline from every bash value, so the
# multi-line values are trimmed the same way before comparison.
Write-Probe -Key 'deduped' -Value (((Get-FmWakeDeduped -Path "$fix/state/queue-fixture") -join "`n"))
$rows = [System.IO.File]::ReadAllText((ConvertTo-FmNativePath "$fix/rows"))
$rowsCap = [System.IO.File]::ReadAllText((ConvertTo-FmNativePath "$fix/rows-cap"))
Write-Probe -Key 'manifest' -Value (((Get-FmWakeAnnotationManifest -Rows $rows) -join "`n"))
Write-Probe -Key 'annotations' -Value ((Get-FmWakeAnnotation -Rows $rows).TrimEnd("`n"))
Write-Probe -Key 'annotations_cap' -Value ((Get-FmWakeAnnotation -Rows $rowsCap).TrimEnd("`n"))

foreach ($s in @('task.status', 'blanks.status', 'control.status', 'empty.status',
        'missing.status', 'dir.status', 'huge.status')) {
    $latest = Get-FmWakeLatestEvent -Path "$fix/state/$s" -TailBytes 8192
    if ($null -eq $latest) {
        Write-Probe -Key "event:$s" -Value '1||false'
    } else {
        $truncated = if ($latest.Truncated) { 'true' } else { 'false' }
        Write-Probe -Key "event:$s" -Value "0|$($latest.Line)|$truncated"
    }
}

$works = if (Test-FmLockSymlinksWork -LockPath "$fix/state/.probe.lock") { 'yes' } else { 'no' }
Write-Probe -Key 'symlinks_work' -Value $works

$errFile = [System.IO.Path]::GetTempFileName()
$prevErr = [Console]::Error
$writer = [System.IO.StreamWriter]::new($errFile, $false, [System.Text.UTF8Encoding]::new($false))
[Console]::SetError($writer)
$rc = Add-FmWake -Kind 'bogus' -Key 'k' -Payload 'p'
$writer.Flush()
[Console]::SetError($prevErr)
$writer.Dispose()
$captured = ([System.IO.File]::ReadAllText($errFile)).TrimEnd("`n")
[System.IO.File]::Delete($errFile)
Write-Probe -Key 'append_bad_kind' -Value "$rc|$captured"
PROBE_PS1

# Both probes get the SAME fixture path, in MSYS form. That is deliberate on two
# counts: several probe cases are path-shaped (fm_lock_abs_path,
# fm_lock_owner_shape_ok) and answer in the FORM they were given, so feeding the
# two worlds different spellings would compare two different questions - and the
# MSYS form is the one that matters, because the durable records both worlds
# read during the transition carry it. Only the module PATH itself is native,
# because Import-Module resolves it before any firstmate code can convert it.
#
# They also run with the same FM_STATE_OVERRIDE: each library resolves its state
# directory once, when it is loaded, and the annotation phase reads status files
# out of it, so a differing STATE would compare two different fixtures.
FM_STATE_OVERRIDE="$FSTATE" bash "$TMP_ROOT/probe.sh" "$LIB" "$FIX" \
  > "$TMP_ROOT/probe.bash.out" 2>"$TMP_ROOT/probe.bash.err" \
  || fail "bash probe failed: $(cat "$TMP_ROOT/probe.bash.err")"
FM_STATE_OVERRIDE="$FSTATE" pwsh -NoProfile \
  -File "$(fm_test_native_path "$TMP_ROOT/probe.ps1")" "$MOD" "$FIX" \
  > "$TMP_ROOT/probe.pwsh.out" 2>"$TMP_ROOT/probe.pwsh.err" \
  || fail "pwsh probe failed: $(cat "$TMP_ROOT/probe.pwsh.err")"

# Paired in ONE awk pass rather than a lookup per key: a process spawn costs
# ~360ms on this host, so two spawns per key would add a minute of pure fork
# time to a comparison that is already the cheapest part of this file.
awk -F '\t' '
  NR == FNR { bash[$1] = $2; order[++n] = $1; next }
  { pwsh[$1] = $2 }
  END {
    for (i = 1; i <= n; i++) {
      k = order[i]
      printf "%s\t%s\t%s\n", k, bash[k], (k in pwsh ? pwsh[k] : "MISSING-KEY")
    }
  }
' "$TMP_ROOT/probe.bash.out" "$TMP_ROOT/probe.pwsh.out" > "$TMP_ROOT/probe.paired"

while IFS=$'\t' read -r key expected actual; do
  [ -n "$key" ] || continue
  assert_same "probe $key" "$expected" "$actual"
done < "$TMP_ROOT/probe.paired"

probe_value() {  # <file> <key>
  awk -F '\t' -v k="$2" '$1 == k { print $2; found = 1 } END { if (!found) print "MISSING-KEY" }' "$1"
}

# A probe that silently stopped emitting would make every remaining comparison
# vacuous, so the two key SETS are compared as well.
assert_same "probe key set" \
  "$(cut -f1 "$TMP_ROOT/probe.bash.out" | LC_ALL=C sort | md5sum)" \
  "$(cut -f1 "$TMP_ROOT/probe.pwsh.out" | LC_ALL=C sort | md5sum)"

# The /proc identity is the one identity form both worlds can produce, so it is
# also asserted against its literal expected value: an equality between two
# broken parsers would otherwise pass.
assert_same "probe identity:proc literal" \
  "$(printf '%s' 'proc-starttime=987654 cmdline-hex=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700' | od -An -v -tx1 | tr -d '[:space:]')" \
  "$(probe_value "$TMP_ROOT/probe.pwsh.out" 'identity:proc')"

# ---------------------------------------------------------------------------
# Cross-world interop, with real processes. This is the R2 evidence.
# ---------------------------------------------------------------------------

# A PowerShell lock holder: acquires, publishes its pid, waits for a release
# flag, then releases. A flag rather than a fixed sleep because a process spawn
# costs ~360ms here and a fixed hold would either flake or waste the whole
# budget.
cat > "$TMP_ROOT/holder.ps1" <<'HOLDER_PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = $args[0]
$lockPath = $args[1]
$pidFile = $args[2]
$releaseFlag = $args[3]
$doneFile = $args[4]
Import-Module $modulePath -Force
# Imported explicitly: a module does not re-export what IT imports, so the
# fm-common helpers this fixture needs to write an MSYS-form path are not in
# scope just because fm-wake-lib uses them.
Import-Module (Join-Path ([System.IO.Path]::GetDirectoryName($modulePath)) 'fm-common.psm1') -Force

if (-not (Request-FmLock -LockPath $lockPath)) {
    Set-FmFileText -Path $pidFile -Text 'ACQUIRE-FAILED'
    exit 9
}
Set-FmFileText -Path $pidFile -Text ([string]$PID)
$waited = 0
while (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath $releaseFlag)) -and $waited -lt 1200) {
    Start-Sleep -Milliseconds 100
    $waited++
}
Unlock-FmLock -LockPath $lockPath
Set-FmFileText -Path $doneFile -Text 'released'
HOLDER_PS1
HOLDER_PS1_N=$(fm_test_native_path "$TMP_ROOT/holder.ps1")

wait_for_file() {  # <path> [tenths]
  local path=$1 limit=${2:-600} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -s "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# --- 1. BASH takes the lock; POWERSHELL must see it held --------------------
IOP="$TMP_ROOT/iop-bash-first"
IOP_STATE="$IOP/state"
mkdir -p "$IOP_STATE"
BLOCK="$IOP_STATE/.cross.lock"
FM_STATE_OVERRIDE="$IOP_STATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"
  fm_lock_try_acquire "$2" || exit 9
  printf "%s\n" "${BASHPID:-$$}" > "$3"
  i=0
  while [ ! -e "$4" ] && [ "$i" -lt 1200 ]; do sleep 0.1; i=$((i + 1)); done
  fm_lock_release "$2"
  printf "released\n" > "$5"
' _ "$LIB" "$BLOCK" "$IOP/bash.pid" "$IOP/release" "$IOP/bash.done" &
BASH_HOLDER=$!
if wait_for_file "$IOP/bash.pid"; then
  BASH_HOLDER_PID=$(cat "$IOP/bash.pid")
else
  BASH_HOLDER_PID=""
fi
assert_true "bash holder took the lock" "$([ -n "$BASH_HOLDER_PID" ] && echo 0 || echo 1)" \
  "bash lock holder never published a pid"

# The representation bash published, read back through the bash reader, is the
# baseline every PowerShell answer below is compared against.
BASH_TOKEN=$(cat "$BLOCK/.fm-lock-owner" 2>/dev/null || true)
BASH_LOCKPID=$(cat "$BLOCK/pid" 2>/dev/null || true)

PS_ON_BASH_LOCK=$(FM_STATE_OVERRIDE="$(fm_test_native_path "$IOP_STATE")" pwsh -NoProfile -Command "
Import-Module '$MOD' -Force
\$got = Request-FmLock -LockPath '$BLOCK'
\$owner = Get-FmLockFallbackOwner -LockPath '$BLOCK'
\$live = Test-FmPidAlive -ProcessId '$BASH_HOLDER_PID'
[Console]::Out.Write('acquired=' + \$got + ' held=' + (Get-FmLockHeldPid) + ' token=' + \$owner + ' bashpid_alive=' + \$live)
" 2>&1)

assert_same "PS refuses a lock BASH holds" "acquired=False" \
  "$(printf '%s' "$PS_ON_BASH_LOCK" | sed 's/ .*//')"
assert_same "PS names the BASH holder pid" "held=$BASH_HOLDER_PID" \
  "$(printf '%s\n' "$PS_ON_BASH_LOCK" | tr ' ' '\n' | grep '^held=' || true)"
assert_same "PS reads the BASH owner token" "token=$BASH_TOKEN" \
  "$(printf '%s\n' "$PS_ON_BASH_LOCK" | tr ' ' '\n' | grep '^token=' || true)"
assert_same "PS sees the MSYS holder pid as alive" "bashpid_alive=True" \
  "$(printf '%s\n' "$PS_ON_BASH_LOCK" | tr ' ' '\n' | grep '^bashpid_alive=' || true)"
assert_same "refused acquire left the BASH holder's pid untouched" "$BASH_LOCKPID" \
  "$(cat "$BLOCK/pid" 2>/dev/null || true)"
assert_same "refused acquire left the BASH owner token untouched" "$BASH_TOKEN" \
  "$(cat "$BLOCK/.fm-lock-owner" 2>/dev/null || true)"

# --- 2. BASH releases; POWERSHELL must be able to take it -------------------
: > "$IOP/release"
wait_for_file "$IOP/bash.done" || true
wait "$BASH_HOLDER" 2>/dev/null || true
assert_true "bash holder released cleanly" "$([ -e "$BLOCK" ] && echo 1 || echo 0)" \
  "bash release left $BLOCK behind"

PS_AFTER_RELEASE=$(FM_STATE_OVERRIDE="$(fm_test_native_path "$IOP_STATE")" pwsh -NoProfile -Command "
Import-Module '$MOD' -Force
\$got = Request-FmLock -LockPath '$BLOCK'
[Console]::Out.Write('acquired=' + \$got)
" 2>&1)
assert_same "PS acquires a lock BASH released" "acquired=True" "$PS_AFTER_RELEASE"
# That pwsh exited, so its lock now names a dead pid; bash must reclaim it.
BASH_RECLAIM=$(FM_STATE_OVERRIDE="$IOP_STATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"
  if fm_lock_try_acquire "$2"; then printf "reclaimed\n"; else printf "refused held=%s\n" "${FM_LOCK_HELD_PID:-}"; fi
' _ "$LIB" "$BLOCK" 2>&1)
assert_same "BASH reclaims a PS lock whose holder exited" "reclaimed" "$BASH_RECLAIM"

# --- 3. POWERSHELL takes the lock; BASH must read the same representation ---
IOP2="$TMP_ROOT/iop-ps-first"
IOP2_STATE="$IOP2/state"
mkdir -p "$IOP2_STATE"
PLOCK="$IOP2_STATE/.cross.lock"
# The holder's stderr is captured rather than discarded: a fixture that dies
# before publishing its pid would otherwise turn every assertion below into an
# unexplained failure, and the reason lives on that stream.
FM_STATE_OVERRIDE="$IOP2_STATE" pwsh -NoProfile -File "$HOLDER_PS1_N" \
  "$MOD" "$PLOCK" "$IOP2/ps.pid" "$IOP2/release" "$IOP2/ps.done" 2> "$IOP2/holder.err" &
PS_HOLDER=$!
if wait_for_file "$IOP2/ps.pid"; then
  PS_HOLDER_PID=$(cat "$IOP2/ps.pid")
else
  PS_HOLDER_PID=""
fi
assert_true "PS holder took the lock" \
  "$([ -n "$PS_HOLDER_PID" ] && [ "$PS_HOLDER_PID" != "ACQUIRE-FAILED" ] && echo 0 || echo 1)" \
  "PowerShell lock holder never published a pid (got '$PS_HOLDER_PID'); stderr: $(head -c 600 "$IOP2/holder.err" 2>/dev/null)"

# The shape assertions: a lock path that is a DIRECTORY holding pid and
# .fm-lock-owner, with a sibling owner directory - not a regular file, and not a
# third representation invented by the PowerShell side.
assert_same "PS lock path is a directory" "yes" \
  "$([ -d "$PLOCK" ] && [ ! -L "$PLOCK" ] && echo yes || echo no)"
assert_same "PS lock holds exactly the protocol's own children" "$(printf '.fm-lock-owner\npid')" \
  "$(ls -A "$PLOCK" 2>/dev/null | LC_ALL=C sort | tr '\n' '@' | sed 's/@$//' | tr '@' '\n')"
PS_TOKEN=$(cat "$PLOCK/.fm-lock-owner" 2>/dev/null || true)
assert_same "PS owner token is an absolute POSIX path bash can parse" "yes" \
  "$(case "$PS_TOKEN" in /*) echo yes ;; *) echo no ;; esac)"
assert_same "PS owner directory exists beside the lock" "yes" \
  "$([ -d "$PS_TOKEN" ] && echo yes || echo no)"

BASH_ON_PS_LOCK=$(FM_STATE_OVERRIDE="$IOP2_STATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"
  if fm_lock_fallback_owner "$2"; then printf "token=%s " "$FM_LOCK_FALLBACK_OWNER"; else printf "token=NONE "; fi
  if fm_lock_points_to_owner "$2" "$FM_LOCK_FALLBACK_OWNER"; then printf "points=yes "; else printf "points=no "; fi
  if fm_lock_try_create "$2"; then printf "created=yes "; else printf "created=no "; fi
  if fm_pid_alive "$3"; then printf "pspid_alive=yes"; else printf "pspid_alive=no"; fi
' _ "$LIB" "$PLOCK" "$PS_HOLDER_PID" 2>&1)

assert_same "BASH reads the PS owner token" "token=$PS_TOKEN" \
  "$(printf '%s\n' "$BASH_ON_PS_LOCK" | tr ' ' '\n' | grep '^token=' || true)"
assert_same "BASH agrees the PS lock points to its owner" "points=yes" \
  "$(printf '%s\n' "$BASH_ON_PS_LOCK" | tr ' ' '\n' | grep '^points=' || true)"
assert_same "BASH refuses to create over the PS lock" "created=no" \
  "$(printf '%s\n' "$BASH_ON_PS_LOCK" | tr ' ' '\n' | grep '^created=' || true)"

# KNOWN DIVERGENCE, asserted so it cannot change silently. Git Bash records MSYS
# pids and PowerShell records Windows pids; `kill -0` cannot see a Windows pid,
# so bin/fm-wake-lib.sh's fm_pid_alive reads a live PowerShell holder as dead and
# would reclaim its lock once the mid-acquire grace lapses. The PowerShell side
# already resolves BOTH namespaces (asserted above), and the bash side cannot be
# fixed from this package. If this assertion ever FAILS, fm_pid_alive gained a
# Windows-pid leg: that is the fix, and the divergence note in
# bin/fm-wake-lib.psm1's header plus this case should be retired together.
assert_same "KNOWN DIVERGENCE: bash cannot see a Windows holder pid as alive" "pspid_alive=no" \
  "$(printf '%s\n' "$BASH_ON_PS_LOCK" | tr ' ' '\n' | grep '^pspid_alive=' || true)"

# --- 4. POWERSHELL releases; BASH must be able to take it -------------------
: > "$IOP2/release"
wait_for_file "$IOP2/ps.done" || true
wait "$PS_HOLDER" 2>/dev/null || true
assert_true "PS release removed the lock path" "$([ -e "$PLOCK" ] && echo 1 || echo 0)" \
  "PowerShell release left $PLOCK behind"
assert_true "PS release removed its owner directory" "$([ -e "$PS_TOKEN" ] && echo 1 || echo 0)" \
  "PowerShell release left the owner directory $PS_TOKEN behind"

BASH_AFTER_PS=$(FM_STATE_OVERRIDE="$IOP2_STATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"
  if fm_lock_try_acquire "$2"; then printf "acquired=yes"; else printf "acquired=no held=%s" "${FM_LOCK_HELD_PID:-}"; fi
' _ "$LIB" "$PLOCK" 2>&1)
assert_same "BASH acquires a lock PS released" "acquired=yes" "$BASH_AFTER_PS"

# --- 5. The wake queue crosses both ways, empty middle field included -------
QSTATE="$TMP_ROOT/queue-interop/state"
mkdir -p "$QSTATE"
FM_STATE_OVERRIDE="$QSTATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"
  fm_wake_append signal task.status "signal: $2/task.status" || exit 1
  fm_wake_append signal "" "payload with an empty key" || exit 1
  fm_wake_append stale "test:fm-task" "" || exit 1
  fm_wake_append heartbeat heartbeat heartbeat || exit 1
' _ "$LIB" "$QSTATE" || fail "bash queue append failed"

QUEUE="$QSTATE/.wake-queue"
assert_same "bash wrote four records" "4" "$(awk 'NF { c++ } END { print c + 0 }' "$QUEUE")"
assert_same "the empty-key record really has five TAB fields" "1" \
  "$(awk -F '\t' '$3 == "signal" && $4 == "" && NF == 5 { c++ } END { print c + 0 }' "$QUEUE")"
assert_same "the empty-payload record really has five TAB fields" "1" \
  "$(awk -F '\t' '$3 == "stale" && $5 == "" && NF == 5 { c++ } END { print c + 0 }' "$QUEUE")"

BASH_DRAIN=$(FM_STATE_OVERRIDE="$QSTATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"; fm_wake_print_deduped "$2"' _ "$LIB" "$QUEUE")
PS_DRAIN=$(FM_STATE_OVERRIDE="$(fm_test_native_path "$QSTATE")" pwsh -NoProfile -Command "
Import-Module '$MOD' -Force
Write-FmWakeDeduped -Path '$QUEUE'
")
assert_same "PS drains a BASH-written queue identically" \
  "$(printf '%s' "$BASH_DRAIN" | od -An -v -tx1 | tr -d '[:space:]')" \
  "$(printf '%s' "$PS_DRAIN" | od -An -v -tx1 | tr -d '[:space:]')"

# Now the other direction, through tests/wake-helpers.psm1's own append helper
# so the shared helper is exercised rather than assumed.
QSTATE2="$TMP_ROOT/queue-interop-2/state"
mkdir -p "$QSTATE2"
QSTATE2_N=$(fm_test_native_path "$QSTATE2")
pwsh -NoProfile -Command "
Import-Module '$HELPERS' -Force
[void](Add-FmTestWake -State '$QSTATE2_N' -Kind signal -Key 'task.status' -Payload 'signal: task')
[void](Add-FmTestWake -State '$QSTATE2_N' -Kind signal -Key '' -Payload 'payload with an empty key')
[void](Add-FmTestWake -State '$QSTATE2_N' -Kind stale -Key 'test:fm-task' -Payload '')
[void](Add-FmTestWake -State '$QSTATE2_N' -Kind heartbeat -Key heartbeat -Payload heartbeat)
" >/dev/null 2>&1 || fail "PowerShell queue append failed"

QUEUE2="$QSTATE2/.wake-queue"
assert_true "PS wrote a queue file" "$([ -s "$QUEUE2" ] && echo 0 || echo 1)" "no queue at $QUEUE2"
assert_same "PS records carry five TAB fields, empties included" "4" \
  "$(awk -F '\t' 'NF == 5 { c++ } END { print c + 0 }' "$QUEUE2")"
assert_same "PS queue file has no CR bytes" "0" \
  "$(od -An -v -tx1 "$QUEUE2" | tr -d '[:space:]' | grep -o '0d' | wc -l | tr -d ' ')"
assert_same "PS sequence numbers are 1..4" "$(printf '1\n2\n3\n4')" "$(cut -f2 "$QUEUE2")"

BASH_DRAIN2=$(FM_STATE_OVERRIDE="$QSTATE2" bash -c '
  # shellcheck disable=SC1090
  . "$1"; fm_wake_print_deduped "$2"' _ "$LIB" "$QUEUE2")
PS_DRAIN2=$(FM_STATE_OVERRIDE="$QSTATE2_N" pwsh -NoProfile -Command "
Import-Module '$MOD' -Force
Write-FmWakeDeduped -Path '$QUEUE2'
")
assert_same "BASH drains a PS-written queue identically" \
  "$(printf '%s' "$BASH_DRAIN2" | od -An -v -tx1 | tr -d '[:space:]')" \
  "$(printf '%s' "$PS_DRAIN2" | od -An -v -tx1 | tr -d '[:space:]')"
assert_same "the PS-written empty-key record survives a BASH drain" "1" \
  "$(printf '%s\n' "$BASH_DRAIN2" | awk -F '\t' '$3 == "signal" && $4 == "" { c++ } END { print c + 0 }')"

# --- 6. Both worlds agree on the lock REPRESENTATION for one directory ------
# The verdict decides which of the two on-disk shapes gets published, so a
# disagreement here is the R2 failure mode in its purest form: two processes
# publishing different shapes at one path.
REPR_STATE="$TMP_ROOT/repr/state"
mkdir -p "$REPR_STATE"
BASH_REPR=$(FM_STATE_OVERRIDE="$REPR_STATE" bash -c '
  # shellcheck disable=SC1090
  . "$1"; if fm_lock_symlinks_work "$2"; then echo symlink; else echo fallback; fi' _ "$LIB" "$REPR_STATE/.r.lock")
PS_REPR=$(FM_STATE_OVERRIDE="$(fm_test_native_path "$REPR_STATE")" pwsh -NoProfile -Command "
Import-Module '$MOD' -Force
if (Test-FmLockSymlinksWork -LockPath '$REPR_STATE/.r.lock') { [Console]::Out.Write('symlink') } else { [Console]::Out.Write('fallback') }
")
assert_same "both worlds choose the same lock representation" "$BASH_REPR" "$PS_REPR"

# --- 7. The helper module's own fixtures agree with their bash twins --------
HELPER_OUT=$(pwsh -NoProfile -Command "
Import-Module '$HELPERS' -Force
[Console]::Out.Write('hash=' + (Get-FmTestTextHash -Text 'idle prompt') + \"\`n\")
[Console]::Out.Write('deadalive=' + (Test-FmTestProcessLive -ProcessId (Get-FmTestDeadPid)) + \"\`n\")
[Console]::Out.Write('selfalive=' + (Test-FmTestProcessLive -ProcessId ([string]\$PID)) + \"\`n\")
" 2>&1)
assert_same "helper hash_text matches md5sum" \
  "hash=$(printf '%s' 'idle prompt' | md5sum | cut -d' ' -f1)" \
  "$(printf '%s\n' "$HELPER_OUT" | grep '^hash=' || true)"
assert_same "helper dead_pid really is dead" "deadalive=False" \
  "$(printf '%s\n' "$HELPER_OUT" | grep '^deadalive=' || true)"
assert_same "helper liveness sees its own process" "selfalive=True" \
  "$(printf '%s\n' "$HELPER_OUT" | grep '^selfalive=' || true)"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-wake-lib.psm1 differs from its bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass: the assertion count
# is itself asserted, so a probe that stopped emitting - or a future refactor
# that drops cases - fails loudly instead of certifying an empty run.
MIN_ASSERTIONS=70
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-wake-lib.psm1 matches the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-wake-lib-psm1.test.sh: lock representation, wake records and cross-world interop verified\n'
