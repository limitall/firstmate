#!/usr/bin/env bash
# Behavior test for the ten PowerShell leaf-library twins of wave 2 packages
# W2-small-a and W2-small-b:
#
#   bin/fm-tasks-axi-lib.psm1            bin/fm-secondmate-registry-lib.psm1
#   bin/fm-quota-axi-lib.psm1            bin/fm-startup-memory-budget-lib.psm1
#   bin/fm-tangle-lib.psm1               bin/fm-supervisor-target-lib.psm1
#   bin/fm-lock-lib.psm1                 bin/fm-backend-hometag-lib.psm1
#   bin/fm-primary-scope-lib.psm1        bin/fm-gate-refuse-lib.psm1
#
# This is a DIFFERENTIAL test: it drives each bash library and its PowerShell
# twin with the same fixtures and asserts they agree. Bash is the ORACLE
# (docs/powershell-port.md) - where the two differ the bash is right, unless
# the twin's header documents the divergence, and the documented divergences
# get their own assertions here so the twin behaves as documented rather than
# by accident.
#
# STRUCTURE, and why it is shaped this way. Process creation on this Windows
# host is expensive and highly variable: a bare `git rev-parse` was measured at
# 2.3s while several agents were building concurrently, and pwsh startup alone
# is ~360ms. A file that spawned one interpreter per assertion would run for an
# hour. So BOTH worlds are batched the same way: each library gets exactly one
# `bash` oracle script and one `pwsh` probe script, each emitting
# `label<TAB>value` lines, and the assertions below compare the two streams
# label by label. Twenty interpreter launches, not four hundred.
#
# Every assertion label names the library it covers so a failure is
# attributable at a glance, and ps_get yields a loud <<MISSING:label>> sentinel
# rather than an empty string when either side never emitted a case - a probe
# that died halfway cannot pass by matching an empty oracle.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7.
#
# Windows note for later conversion authors: PowerShell cannot resolve MSYS
# paths (verified - [System.IO.File] reads /tmp/x as C:\tmp\x), so every path
# handed to pwsh here, INCLUDING module and probe-script paths, goes through
# fm_test_native_path first.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-small-libs-psm1)
PROBES="$TMP_ROOT/probes"; mkdir -p "$PROBES"
FIX="$TMP_ROOT/fix"; mkdir -p "$FIX"
BIN_N=$(fm_test_native_path "$ROOT/bin")
FIX_N=$(fm_test_native_path "$FIX")

for lib in fm-tasks-axi-lib fm-quota-axi-lib fm-tangle-lib fm-lock-lib fm-primary-scope-lib \
           fm-secondmate-registry-lib fm-startup-memory-budget-lib fm-supervisor-target-lib \
           fm-backend-hometag-lib fm-gate-refuse-lib; do
  [ -f "$ROOT/bin/$lib.psm1" ] || fail "bin/$lib.psm1 is missing"
done

# --- bookkeeping -------------------------------------------------------------
#
# Results live in plain shell variables in THIS shell. Nothing that records an
# assertion may run inside `( ... )`: a subshell cannot report a failure back
# to the parent's counters, so a bookkeeping scheme that loses a failure would
# certify work it never checked. Command substitution appears only where an
# oracle VALUE is computed, never where a result is recorded.
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

# ps_get <stream> <label>: the value one side emitted for one label.
ps_get() {
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '
    BEGIN { f = 0 }
    $1 == k && !f { f = 1; sub(/^[^\t]*\t/, ""); print }
    END { if (!f) print "<<MISSING:" k ">>" }'
}

# both <label> <bash-stream> <ps-stream> [assertion-label]: the workhorse.
both() {
  assert_same "${4:-$1}" "$(ps_get "$2" "$1")" "$(ps_get "$3" "$1")"
}

# np <value>: normalize fixture paths so a message that EMBEDS a path can be
# compared across worlds. Several library errors quote the path they were
# given, and the two worlds legitimately hold different spellings of one
# location (/tmp/x vs C:\Users\...\Temp\x). Separators are folded first,
# because a backslash in a bash substitution pattern would escape the next
# character instead of matching one.
np() {
  local v=${1//\\//}
  local fixn=${FIX_N//\\//}
  v=${v//$fixn/<FIX>}
  v=${v//$FIX/<FIX>}
  printf '%s' "$v"
}
both_np() {  # same as both, but path-normalized on each side
  assert_same "${4:-$1}" "$(np "$(ps_get "$2" "$1")")" "$(np "$(ps_get "$3" "$1")")"
}

# canon <path>: native spelling of one location, for comparing a path VALUE the
# two worlds may spell differently (tests/fm-common-psm1.test.sh applies the
# same rule). WHICH location is named still has to match exactly.
canon() { [ -n "$1" ] || { printf ''; return 0; }; fm_test_native_path "$1"; }
both_path() {
  assert_same "${4:-$1}" "$(canon "$(ps_get "$2" "$1")")" "$(canon "$(ps_get "$3" "$1")")"
}

probe() {  # <name> [args...] - one pwsh launch
  local name=$1; shift
  # MSYS2_ARG_CONV_EXCL: pwsh.exe is a NATIVE binary, so without this MSYS
  # rewrites any POSIX-looking argument (/f/...) into mixed form (F:/...) on
  # the way in - but only when the ambient environment has path conversion
  # enabled, so the probe's argv SPELLING silently depends on the caller's
  # shell. That is exactly how tag (badroot) failed in one shell and passed in
  # another: the twin hashes an unresolvable root VERBATIM, and the two worlds
  # were handed different verbatims. Every path this suite wants native is
  # already converted explicitly with fm_test_native_path, so blanket
  # exclusion pins every argument to the exact bytes written here.
  MSYS2_ARG_CONV_EXCL='*' pwsh -NoProfile -File "$(fm_test_native_path "$PROBES/$name.ps1")" "$@" 2>&1
}
oracle() {  # <name> [args...] - one bash launch
  local name=$1; shift
  bash "$PROBES/$name.sh" "$@" 2>/dev/null
}

# Shared preambles. Both sides emit the same record shape, with embedded
# newlines encoded identically so a multi-line error message compares as one
# line.
probe_head() {
  cat <<'PS'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Emit {
    param([Parameter(Mandatory)][string]$Label, [AllowEmptyString()][string]$Value = '')
    [Console]::Out.Write($Label + "`t" + ($Value -replace "`n", '\n') + "`n")
}
PS
}
oracle_head() {  # <lib-basename>
  cat <<SH
#!/usr/bin/env bash
set -u
ROOT=\$1; shift
. "\$ROOT/bin/$1.sh"
SH
  cat <<'SH'
emit() { local v=${2:-}; printf '%s\t%s\n' "$1" "${v//$'\n'/\\n}"; }
tf() { if "$@" >/dev/null 2>&1; then printf True; else printf False; fi }
SH
}

# ============================================================================
# fm-tasks-axi-lib
# ============================================================================
# tasks-axi is NOT installed on this machine, which is exactly the state
# firstmate hits here, so the tool-absent paths are asserted against the real
# absence first. The version and capability logic is then driven from recorded
# output through a fake tool built for BOTH worlds: a bash shim (which bash's
# PATH lookup prefers) and a .cmd shim (which is what Get-Command resolves on
# Windows). That pairing is what exercises the twin's full-path resolution -
# CreateProcess cannot launch a .cmd by bare name even when Get-Command has
# just found it.

mk_fake_tasks_axi() {  # <dir> <version-line> <archive:yes|no> <multiid:yes|no>
  local dir=$1 ver=$2 arch=$3 multi=$4 archline mvline
  mkdir -p "$dir"
  if [ "$arch" = yes ]; then archline='  --archive-body  rewrite the note'; else archline='  --body  rewrite the note'; fi
  if [ "$multi" = yes ]; then mvline='  tasks-axi mv [<id>...] <status>'; else mvline='  tasks-axi mv <id> <status>'; fi
  cat > "$dir/tasks-axi" <<SH
#!/usr/bin/env bash
case "\$1" in
  --version) printf '%s\n' '$ver' ;;
  update) printf '%s\n' '$archline' ;;
  mv) printf '%s\n' '$mvline' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/tasks-axi"
  # cmd.exe wants CRLF in a batch file, and < > must be caret-escaped.
  {
    printf '@echo off\r\n'
    printf 'if "%%~1"=="--version" goto ver\r\n'
    printf 'if "%%~1"=="update" goto upd\r\n'
    printf 'if "%%~1"=="mv" goto mvh\r\n'
    printf 'exit /b 1\r\n'
    printf ':ver\r\n'
    printf 'echo %s\r\n' "$ver"
    printf 'exit /b 0\r\n'
    printf ':upd\r\n'
    printf 'echo %s\r\n' "$(printf '%s' "$archline" | sed 's/</^</g; s/>/^>/g')"
    printf 'exit /b 0\r\n'
    printf ':mvh\r\n'
    printf 'echo %s\r\n' "$(printf '%s' "$mvline" | sed 's/</^</g; s/>/^>/g')"
    printf 'exit /b 0\r\n'
  } > "$dir/tasks-axi.cmd"
}

TA="$FIX/tasksaxi"; mkdir -p "$TA"
mk_fake_tasks_axi "$TA/good"      'tasks-axi 0.2.4' yes yes
mk_fake_tasks_axi "$TA/oldver"    'tasks-axi 0.1.0' yes yes
mk_fake_tasks_axi "$TA/noarchive" 'tasks-axi 0.2.4' no  yes
mk_fake_tasks_axi "$TA/nomulti"   'tasks-axi 0.2.4' yes no
# Parse-only scenarios: only the version reader runs for these, because each
# extra capability probe is another second of process creation on this host.
mk_fake_tasks_axi "$TA/weird"     'v10.20.30'       yes yes
mk_fake_tasks_axi "$TA/noversion" 'tasks-axi build' yes yes

TAC="$FIX/tasksaxi-config"; mkdir -p "$TAC/absent" "$TAC/manual" "$TAC/blank" "$TAC/spaced" "$TAC/plain"
printf 'manual\n'     > "$TAC/manual/backlog-backend"
printf '   \n'        > "$TAC/blank/backlog-backend"
printf '  man ual \n' > "$TAC/spaced/backlog-backend"
printf 'tasks-axi\n'  > "$TAC/plain/backlog-backend"

oracle_head fm-tasks-axi-lib > "$PROBES/tasksaxi.sh"
cat >> "$PROBES/tasksaxi.sh" <<'SH'
FAKE=$1 CFG=$2
parts() { if v=$(fm_tasks_axi_version_parts); then printf '0|%s' "$v"; else printf '1|'; fi; }

emit absent.parts "$(parts)"
emit absent.compatible "$(tf fm_tasks_axi_compatible)"
emit absent.archive "$(tf fm_tasks_axi_update_has_archive_body)"
emit absent.multi "$(tf fm_tasks_axi_mv_has_multi_id)"

BASE=$PATH
for c in good oldver noarchive nomulti; do
  PATH="$FAKE/$c:$BASE"
  emit "$c.parts" "$(parts)"
  emit "$c.compatible" "$(tf fm_tasks_axi_compatible)"
  emit "$c.archive" "$(tf fm_tasks_axi_update_has_archive_body)"
  emit "$c.multi" "$(tf fm_tasks_axi_mv_has_multi_id)"
done
for c in weird noversion; do
  PATH="$FAKE/$c:$BASE"
  emit "$c.parts" "$(parts)"
done
PATH=$BASE

for c in absent manual blank spaced plain; do
  emit "cfg.$c.value" "$(fm_backlog_backend_value "$CFG/$c")"
  emit "cfg.$c.manual" "$(tf fm_backlog_backend_manual "$CFG/$c")"
  emit "cfg.$c.available" "$(tf fm_tasks_axi_backend_available "$CFG/$c")"
done
SH

cat > "$PROBES/tasksaxi.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FakeRoot, [string]$ConfigRoot)
PSHEAD
probe_head >> "$PROBES/tasksaxi.ps1"
cat >> "$PROBES/tasksaxi.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-tasks-axi-lib.psm1') -Force
function Get-Parts { $v = Get-FmTasksAxiVersionPart; if ($null -eq $v) { '1|' } else { "0|$v" } }

$basePath = $env:PATH
Emit 'absent.parts' (Get-Parts)
Import-Module (Join-Path $BinDir 'fm-tasks-axi-lib.psm1') -Force
Emit 'absent.compatible' ([string](Test-FmTasksAxiCompatible))
Emit 'absent.archive' ([string](Test-FmTasksAxiUpdateHasArchiveBody))
Emit 'absent.multi' ([string](Test-FmTasksAxiMvHasMultiId))

foreach ($case in @('good', 'oldver', 'noarchive', 'nomulti')) {
    $env:PATH = (Join-Path $FakeRoot $case) + [System.IO.Path]::PathSeparator + $basePath
    # Fresh import per case: bash reads each verdict in a $( ) subshell, so its
    # memo never leaks between cases; reloading the module is that boundary's
    # twin (import-time env consumption included).
    Import-Module (Join-Path $BinDir 'fm-tasks-axi-lib.psm1') -Force
    Emit "$case.parts" (Get-Parts)
    Emit "$case.compatible" ([string](Test-FmTasksAxiCompatible))
    Emit "$case.archive" ([string](Test-FmTasksAxiUpdateHasArchiveBody))
    Emit "$case.multi" ([string](Test-FmTasksAxiMvHasMultiId))
}
foreach ($case in @('weird', 'noversion')) {
    $env:PATH = (Join-Path $FakeRoot $case) + [System.IO.Path]::PathSeparator + $basePath
    Emit "$case.parts" (Get-Parts)
}
$env:PATH = $basePath

foreach ($case in @('absent', 'manual', 'blank', 'spaced', 'plain')) {
    $dir = Join-Path $ConfigRoot $case
    Emit "cfg.$case.value" (Get-FmBacklogBackendValue -ConfigDir $dir)
    Emit "cfg.$case.manual" ([string](Test-FmBacklogBackendManual -ConfigDir $dir))
    Emit "cfg.$case.available" ([string](Test-FmTasksAxiBackendAvailable -ConfigDir $dir))
}
PS

B_TA=$(oracle tasksaxi "$ROOT" "$TA" "$TAC")
P_TA=$(probe tasksaxi "$BIN_N" "$FIX_N/tasksaxi" "$FIX_N/tasksaxi-config")

for k in absent.parts absent.compatible absent.archive absent.multi; do
  both "$k" "$B_TA" "$P_TA" "fm-tasks-axi-lib: tool absent ($k)"
done
for case in good oldver noarchive nomulti; do
  for f in parts compatible archive multi; do
    both "$case.$f" "$B_TA" "$P_TA" "fm-tasks-axi-lib: $f ($case)"
  done
done
for case in weird noversion; do
  both "$case.parts" "$B_TA" "$P_TA" "fm-tasks-axi-lib: version parts ($case)"
done
for case in absent manual blank spaced plain; do
  for f in value manual available; do
    both "cfg.$case.$f" "$B_TA" "$P_TA" "fm-tasks-axi-lib: backlog-backend $f ($case)"
  done
done

# Literal assertions where "both worlds agree" is not enough on its own: these
# are the readings a future author would most plausibly "fix" in one world.
assert_same "fm-tasks-axi-lib: greedy version regex keeps the bash reading" \
  "0|0 20 30" "$(ps_get "$P_TA" 'weird.parts')"
assert_same "fm-tasks-axi-lib: a compatible build is usable" \
  "True" "$(ps_get "$P_TA" 'good.compatible')"
assert_same "fm-tasks-axi-lib: a build below the floor is not usable" \
  "False" "$(ps_get "$P_TA" 'oldver.compatible')"
assert_same "fm-tasks-axi-lib: a build without --archive-body is not usable" \
  "False" "$(ps_get "$P_TA" 'noarchive.compatible')"
assert_same "fm-tasks-axi-lib: a build without multi-id mv is not usable" \
  "False" "$(ps_get "$P_TA" 'nomulti.compatible')"
assert_same "fm-tasks-axi-lib: all whitespace is stripped from a config value" \
  "manual" "$(ps_get "$P_TA" 'cfg.spaced.value')"

# ============================================================================
# fm-quota-axi-lib
# ============================================================================

mk_fake_quota_axi() {  # <dir> <version-line>
  local dir=$1 ver=$2
  mkdir -p "$dir"
  cat > "$dir/quota-axi" <<SH
#!/usr/bin/env bash
case "\$1" in
  --version) printf '%s\n' '$ver' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/quota-axi"
  {
    printf '@echo off\r\n'
    printf 'if "%%~1"=="--version" goto ver\r\n'
    printf 'exit /b 1\r\n'
    printf ':ver\r\n'
    printf 'echo %s\r\n' "$ver"
    printf 'exit /b 0\r\n'
  } > "$dir/quota-axi.cmd"
}

QA="$FIX/quotaaxi"; mkdir -p "$QA"
mk_fake_quota_axi "$QA/floor"   'quota-axi 0.1.17'
mk_fake_quota_axi "$QA/below"   'quota-axi 0.1.15'
# 0.1.9 is the string-comparison trap: '9' sorts above '16' lexically, so a
# twin that compared version fields as strings would wrongly accept it.
mk_fake_quota_axi "$QA/trap"    'quota-axi 0.1.9'
mk_fake_quota_axi "$QA/majorup" 'quota-axi 1.0.0'
mk_fake_quota_axi "$QA/junk"    'quota-axi dev build'

oracle_head fm-quota-axi-lib > "$PROBES/quotaaxi.sh"
cat >> "$PROBES/quotaaxi.sh" <<'SH'
FAKE=$1
emit floorvalue "$FM_QUOTA_AXI_MIN"
emit absent.compatible "$(tf fm_quota_axi_compatible)"
BASE=$PATH
for c in floor below trap majorup junk; do
  PATH="$FAKE/$c:$BASE"
  emit "$c.compatible" "$(tf fm_quota_axi_compatible)"
done
PATH="$FAKE/floor:$BASE"
for t in 5 0 abc 3x ''; do
  emit "timeout.[$t]" "$(tf fm_quota_axi_compatible "$t")"
done
PATH=$BASE
SH

cat > "$PROBES/quotaaxi.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FakeRoot)
PSHEAD
probe_head >> "$PROBES/quotaaxi.ps1"
cat >> "$PROBES/quotaaxi.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-quota-axi-lib.psm1') -Force

Emit 'floorvalue' (Get-FmQuotaAxiMinimumVersion)
$basePath = $env:PATH
Emit 'absent.compatible' ([string](Test-FmQuotaAxiCompatible))

foreach ($case in @('floor', 'below', 'trap', 'majorup', 'junk')) {
    $env:PATH = (Join-Path $FakeRoot $case) + [System.IO.Path]::PathSeparator + $basePath
    Emit "$case.compatible" ([string](Test-FmQuotaAxiCompatible))
}
# Timeout-argument validation, driven against a build that IS compatible so
# only the argument decides the verdict.
$env:PATH = (Join-Path $FakeRoot 'floor') + [System.IO.Path]::PathSeparator + $basePath
foreach ($t in @('5', '0', 'abc', '3x', '')) {
    Emit "timeout.[$t]" ([string](Test-FmQuotaAxiCompatible -TimeoutSeconds $t))
}
$env:PATH = $basePath
PS

B_QA=$(oracle quotaaxi "$ROOT" "$QA")
P_QA=$(probe quotaaxi "$BIN_N" "$FIX_N/quotaaxi")

both floorvalue "$B_QA" "$P_QA" "fm-quota-axi-lib: the floor version has one owner"
both absent.compatible "$B_QA" "$P_QA" "fm-quota-axi-lib: compatible with tool absent"
for case in floor below trap majorup junk; do
  both "$case.compatible" "$B_QA" "$P_QA" "fm-quota-axi-lib: compatible ($case)"
done
for t in 5 0 abc 3x ''; do
  both "timeout.[$t]" "$B_QA" "$P_QA" "fm-quota-axi-lib: timeout argument [$t]"
done
assert_same "fm-quota-axi-lib: 0.1.9 stays below the 0.1.17 floor (numeric, not string, compare)" \
  "False" "$(ps_get "$P_QA" 'trap.compatible')"
assert_same "fm-quota-axi-lib: the floor build itself passes" \
  "True" "$(ps_get "$P_QA" 'floor.compatible')"
assert_same "fm-quota-axi-lib: a malformed timeout argument is itself a refusal" \
  "False" "$(ps_get "$P_QA" 'timeout.[abc]')"

# ============================================================================
# fm-tangle-lib
# ============================================================================

TG="$FIX/tangle"; mkdir -p "$TG"
fm_git_identity
fm_git_init_commit "$TG/onmain";     git -C "$TG/onmain" branch -M main
fm_git_init_commit "$TG/feature";    git -C "$TG/feature" branch -M main
git -C "$TG/feature" checkout -q -b fm/readme-restructure-d3
fm_git_init_commit "$TG/detached";   git -C "$TG/detached" branch -M main
git -C "$TG/detached" checkout -q --detach HEAD
fm_git_init_commit "$TG/masteronly"; git -C "$TG/masteronly" branch -M master
mkdir -p "$TG/notarepo"

oracle_head fm-tangle-lib > "$PROBES/tangle.sh"
cat >> "$PROBES/tangle.sh" <<'SH'
FIXROOT=$1
for c in onmain feature detached masteronly notarepo missing; do
  if v=$(fm_default_branch "$FIXROOT/$c" 2>/dev/null); then emit "$c.default" "0|$v"; else emit "$c.default" '1|'; fi
  if v=$(fm_primary_tangle_branch "$FIXROOT/$c" 2>/dev/null); then emit "$c.tangle" "0|$v"; else emit "$c.tangle" '1|'; fi
done
SH

cat > "$PROBES/tangle.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot)
PSHEAD
probe_head >> "$PROBES/tangle.ps1"
cat >> "$PROBES/tangle.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-tangle-lib.psm1') -Force
foreach ($case in @('onmain', 'feature', 'detached', 'masteronly', 'notarepo', 'missing')) {
    $dir = Join-Path $FixRoot $case
    $d = Get-FmDefaultBranch -Directory $dir
    Emit "$case.default" $(if ($null -eq $d) { '1|' } else { "0|$d" })
    $t = Get-FmPrimaryTangleBranch -Root $dir
    Emit "$case.tangle" $(if ($null -eq $t) { '1|' } else { "0|$t" })
}
PS

B_TG=$(oracle tangle "$ROOT" "$TG")
P_TG=$(probe tangle "$BIN_N" "$FIX_N/tangle")

for case in onmain feature detached masteronly notarepo missing; do
  both "$case.default" "$B_TG" "$P_TG" "fm-tangle-lib: default branch ($case)"
  both "$case.tangle" "$B_TG" "$P_TG" "fm-tangle-lib: tangle branch ($case)"
done
# The alarm and the two silences that matter most, asserted literally so a
# regression cannot hide behind "both worlds agree on the wrong answer".
assert_same "fm-tangle-lib: a feature branch in a primary checkout is the alarm" \
  "0|fm/readme-restructure-d3" "$(ps_get "$P_TG" 'feature.tangle')"
assert_same "fm-tangle-lib: detached HEAD is silent" "1|" "$(ps_get "$P_TG" 'detached.tangle')"
assert_same "fm-tangle-lib: the default branch is silent" "1|" "$(ps_get "$P_TG" 'onmain.tangle')"
assert_same "fm-tangle-lib: a non-repo is silent" "1|" "$(ps_get "$P_TG" 'notarepo.tangle')"
assert_same "fm-tangle-lib: master is the default when there is no main" \
  "0|master" "$(ps_get "$P_TG" 'masteronly.default')"

# ============================================================================
# fm-lock-lib
# ============================================================================

LK="$FIX/lock"; mkdir -p "$LK/worktree"
printf 'lock\n' > "$LK/index.lock"
printf 'lock\n' > "$LK/aged.lock"
touch -d '@1700000000' "$LK/aged.lock" 2>/dev/null || touch -t 202311141122 "$LK/aged.lock"

oracle_head fm-lock-lib > "$PROBES/lock.sh"
cat >> "$PROBES/lock.sh" <<'SH'
F=$1
emit mtime.aged "$(fm_lock_path_mtime "$F/aged.lock")"
if fm_lock_path_mtime "$F/no-such.lock" >/dev/null 2>&1; then emit mtime.missing '0|'; else emit mtime.missing '1|'; fi
if fm_lock_age "$F/no-such.lock" >/dev/null 2>&1; then emit age.missing '0|'; else emit age.missing '1|'; fi
emit holder.fresh "$(tf fm_lock_has_live_holder "$F/index.lock" "$F/worktree")"
emit holder.empty "$(tf fm_lock_has_live_holder '' '')"
emit stale.fresh "$(tf fm_lock_is_provably_stale "$F/index.lock" "$F/worktree" 0)"
emit stale.aged "$(tf fm_lock_is_provably_stale "$F/aged.lock" "$F/worktree" 60)"
emit stale.missing "$(tf fm_lock_is_provably_stale "$F/no-such.lock" "$F/worktree" 0)"
emit stale.emptylock "$(tf fm_lock_is_provably_stale '' "$F/worktree" 0)"
emit stale.badage "$(tf fm_lock_is_provably_stale "$F/index.lock" "$F/worktree" abc)"
emit stale.dirlock "$(tf fm_lock_is_provably_stale "$F/worktree" "$F/worktree" 0)"
FM_LOCK_LOG_PREFIX=teardown
emit log.env "$(fm_lock_log sample 2>&1)"
FM_LOCK_LOG_PREFIX=fleet-sync
emit log.param "$(fm_lock_log sample 2>&1)"
unset FM_LOCK_LOG_PREFIX
emit log.default "$(fm_lock_log sample 2>&1)"
SH

cat > "$PROBES/lock.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot)
PSHEAD
probe_head >> "$PROBES/lock.ps1"
cat >> "$PROBES/lock.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-lock-lib.psm1') -Force

# Write-FmLockLog writes to the real stderr HANDLE (contract 1), not to a
# PowerShell stream, so `2>&1` cannot see it. Swapping Console.Error for a
# StringWriter captures the exact bytes an operator would have seen.
function Get-CapturedError {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $sw = [System.IO.StringWriter]::new()
    $orig = [Console]::Error
    [Console]::SetError($sw)
    try { & $Body } finally { [Console]::SetError($orig) }
    return $sw.ToString().TrimEnd("`n")
}

$lock = Join-Path $FixRoot 'index.lock'
$aged = Join-Path $FixRoot 'aged.lock'
$wt = Join-Path $FixRoot 'worktree'
$gone = Join-Path $FixRoot 'no-such.lock'

Emit 'mtime.aged' ([string](Get-FmLockPathMtime -Path $aged))
Emit 'mtime.missing' $(if ($null -eq (Get-FmLockPathMtime -Path $gone)) { '1|' } else { '0|' })
Emit 'age.missing' $(if ($null -eq (Get-FmLockAge -Lock $gone)) { '1|' } else { '0|' })
Emit 'holder.fresh' ([string](Test-FmLockHasLiveHolder -Lock $lock -Directory $wt))
Emit 'holder.empty' ([string](Test-FmLockHasLiveHolder))
Emit 'stale.fresh' ([string](Test-FmLockProvablyStale -Lock $lock -Directory $wt -MinimumAgeSeconds '0'))
Emit 'stale.aged' ([string](Test-FmLockProvablyStale -Lock $aged -Directory $wt -MinimumAgeSeconds '60'))
Emit 'stale.missing' ([string](Test-FmLockProvablyStale -Lock $gone -Directory $wt -MinimumAgeSeconds '0'))
Emit 'stale.emptylock' ([string](Test-FmLockProvablyStale -Lock '' -Directory $wt -MinimumAgeSeconds '0'))
Emit 'stale.badage' ([string](Test-FmLockProvablyStale -Lock $lock -Directory $wt -MinimumAgeSeconds 'abc'))
Emit 'stale.dirlock' ([string](Test-FmLockProvablyStale -Lock $wt -Directory $wt -MinimumAgeSeconds '0'))

$env:FM_LOCK_LOG_PREFIX = 'teardown'
Emit 'log.env' (Get-CapturedError { Write-FmLockLog -Message 'sample' })
Emit 'log.param' (Get-CapturedError { Write-FmLockLog -Message 'sample' -LogPrefix 'fleet-sync' })
[Environment]::SetEnvironmentVariable('FM_LOCK_LOG_PREFIX', $null)
Emit 'log.default' (Get-CapturedError { Write-FmLockLog -Message 'sample' })
PS

B_LK=$(oracle lock "$ROOT" "$LK")
P_LK=$(probe lock "$BIN_N" "$FIX_N/lock")

for k in mtime.aged mtime.missing age.missing holder.fresh holder.empty \
         stale.fresh stale.aged stale.missing stale.emptylock stale.badage stale.dirlock \
         log.env log.param log.default; do
  both "$k" "$B_LK" "$P_LK" "fm-lock-lib: $k"
done
# The fail-safe verdict itself, asserted literally: with no lsof on this host
# NOTHING may ever be declared provably stale, in either world. If a later
# change teaches this module a native holder check, this line is where the
# behavior difference has to be argued.
assert_same "fm-lock-lib: an aged lock is NOT stale while holders are unprovable" \
  "False" "$(ps_get "$P_LK" 'stale.aged')"
assert_same "fm-lock-lib: an unprovable holder counts as a live holder" \
  "True" "$(ps_get "$P_LK" 'holder.fresh')"
assert_same "fm-lock-lib: the caller-supplied log prefix is used" \
  "fleet-sync: sample" "$(ps_get "$P_LK" 'log.param')"

# ============================================================================
# fm-primary-scope-lib
# ============================================================================

PSC="$FIX/scope"; mkdir -p "$PSC"
mk_scope_home() {  # <dir> [marker-content-or-NONE]
  local dir=$1 marker=${2:-NONE}
  mkdir -p "$dir/bin" "$dir/state"
  printf '# agents\n' > "$dir/AGENTS.md"
  [ "$marker" = NONE ] || printf '%s' "$marker" > "$dir/.fm-secondmate-home"
}
mk_scope_home "$PSC/plain"
mk_scope_home "$PSC/marker-nl" 'alpha
'
mk_scope_home "$PSC/marker-nonl" 'alpha'
mk_scope_home "$PSC/marker-empty" ''
mk_scope_home "$PSC/marker-spaced" '  alpha
'
mk_scope_home "$PSC/marker-bad" 'al pha!
'
mk_scope_home "$PSC/nostate"; rm -rf "$PSC/nostate/state"
mk_scope_home "$PSC/noagents"; rm -f "$PSC/noagents/AGENTS.md"
# A plain checkout and two linked worktrees of one repo: only the plain one is
# a primary scope, unless a linked one carries a valid marker. linked2 is left
# for the PowerShell probe to mark, so the bash oracle afterwards reads a
# marker PowerShell wrote - the cross-world half of the contract.
fm_git_init_commit "$PSC/repo"
mkdir -p "$PSC/repo/bin" "$PSC/repo/state"; printf '# agents\n' > "$PSC/repo/AGENTS.md"
git -C "$PSC/repo" worktree add --quiet -b wt1 "$PSC/linked" >/dev/null 2>&1
git -C "$PSC/repo" worktree add --quiet -b wt2 "$PSC/linked2" >/dev/null 2>&1
for w in linked linked2; do
  mkdir -p "$PSC/$w/bin" "$PSC/$w/state"; printf '# agents\n' > "$PSC/$w/AGENTS.md"
done

SCOPE_CASES="plain marker-nl marker-nonl marker-empty marker-spaced marker-bad nostate noagents repo linked missing"

oracle_head fm-primary-scope-lib > "$PROBES/scope.sh"
cat >> "$PROBES/scope.sh" <<SH
CASES="$SCOPE_CASES"
SH
cat >> "$PROBES/scope.sh" <<'SH'
F=$1
for c in $CASES; do
  emit "$c.home" "$(tf fm_root_is_secondmate_home "$F/$c")"
  emit "$c.scope" "$(tf fm_primary_scope_matches "$F/$c" "$F/$c/state")"
done
# Read back the marker the PowerShell probe wrote into linked2.
emit "linked2.home" "$(tf fm_root_is_secondmate_home "$F/linked2")"
emit "linked2.scope" "$(tf fm_primary_scope_matches "$F/linked2" "$F/linked2/state")"
SH

cat > "$PROBES/scope.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot, [string]$Cases)
PSHEAD
probe_head >> "$PROBES/scope.ps1"
cat >> "$PROBES/scope.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-primary-scope-lib.psm1') -Force

foreach ($case in ($Cases -split ' ')) {
    if ($case -eq '') { continue }
    $dir = Join-Path $FixRoot $case
    Emit "$case.home" ([string](Test-FmRootIsSecondmateHome -Root $dir))
    Emit "$case.scope" ([string](Test-FmPrimaryScopeMatch -Root $dir -State (Join-Path $dir 'state')))
}
# A linked worktree that DOES carry a valid marker is force-included. The
# marker is written here, LF and no BOM, so the bash oracle that runs
# afterwards is reading a PowerShell-authored record.
$marked = Join-Path $FixRoot 'linked2'
[System.IO.File]::WriteAllText((Join-Path $marked '.fm-secondmate-home'), "beta`n",
    [System.Text.UTF8Encoding]::new($false))
Emit 'linked2.home' ([string](Test-FmRootIsSecondmateHome -Root $marked))
Emit 'linked2.scope' ([string](Test-FmPrimaryScopeMatch -Root $marked -State (Join-Path $marked 'state')))
PS

# The PowerShell probe runs FIRST here: it writes the marker into linked2 that
# the bash oracle then reads back, which is the direction that proves a
# PowerShell-authored record is readable by the bash twin.
P_SC=$(probe scope "$BIN_N" "$FIX_N/scope" "$SCOPE_CASES")
B_SC=$(oracle scope "$ROOT" "$PSC")

for case in $SCOPE_CASES; do
  both "$case.home" "$B_SC" "$P_SC" "fm-primary-scope-lib: secondmate-home marker ($case)"
  both "$case.scope" "$B_SC" "$P_SC" "fm-primary-scope-lib: primary scope ($case)"
done
both linked2.home "$B_SC" "$P_SC" "fm-primary-scope-lib: PowerShell-written marker reads as a home under bash"
both linked2.scope "$B_SC" "$P_SC" "fm-primary-scope-lib: a valid marker force-includes a linked home"
# The subtleties the twin's header calls out, asserted literally.
assert_same "fm-primary-scope-lib: a marker with no trailing newline is NOT a home" \
  "False" "$(ps_get "$P_SC" 'marker-nonl.home')"
assert_same "fm-primary-scope-lib: a marker with surrounding whitespace IS a home" \
  "True" "$(ps_get "$P_SC" 'marker-spaced.home')"
assert_same "fm-primary-scope-lib: an id with illegal characters is NOT a home" \
  "False" "$(ps_get "$P_SC" 'marker-bad.home')"
assert_same "fm-primary-scope-lib: a linked worktree is not a primary scope" \
  "False" "$(ps_get "$P_SC" 'linked.scope')"
assert_same "fm-primary-scope-lib: a plain checkout is a primary scope" \
  "True" "$(ps_get "$P_SC" 'repo.scope')"
assert_same "fm-primary-scope-lib: that force-inclusion really is True" \
  "True" "$(ps_get "$P_SC" 'linked2.scope')"

# ============================================================================
# fm-secondmate-registry-lib
# ============================================================================

RG="$FIX/registry"; mkdir -p "$RG/realhome/child"
OK_LINE='- alpha - runs the alpha domain (home: /h/a; scope: alpha work; projects: p1,p2; added 2026-01-02)'
PUNCT_LINE='- beta - handles (b) work; carefully (home: /h/b; scope: things (like this); and more; projects: p3; added 2026-02-03)'
{ printf '# Secondmates\n\n'; printf '%s\n' "$OK_LINE"; printf '%s\n' "$PUNCT_LINE"; } > "$RG/ok.md"
printf '%s\n- alpha - second copy (home: /h/z; scope: s; projects: ; added 2026-01-02)\n' "$OK_LINE" > "$RG/dupid.md"
printf '%s\n- beta - same home (home: /h/a; scope: s; projects: ; added 2026-01-02)\n' "$OK_LINE" > "$RG/duphome.md"
printf '%s\n- beta - nested (home: /h/a/inner; scope: s; projects: ; added 2026-01-02)\n' "$OK_LINE" > "$RG/overlap.md"
printf '%s\n- gamma - broken entry\n' "$OK_LINE" > "$RG/malformed.md"
printf -- '- delta - rel (home: rel/path; scope: s; projects: ; added 2026-01-02)\n' > "$RG/relhome.md"
printf -- '- eps - tabbed (home: /h/\ta; scope: s; projects: ; added 2026-01-02)\n' > "$RG/tabhome.md"
printf -- '- zeta - nohome (home: ; scope: s; projects: ; added 2026-01-02)\n' > "$RG/nohome.md"
printf -- '- eta - noscope (home: /h/e; scope: ; projects: ; added 2026-01-02)\n' > "$RG/noscope.md"
printf '%s' "$OK_LINE" > "$RG/noeol.md"

PARSE_KEYS="ok punct nohome noscope broken baddate"
FIELD_CASES="ok.md:alpha ok.md:beta ok.md:nope dupid.md:alpha ok.md:bad! ok.md: missing.md:alpha noeol.md:alpha relhome.md:delta"
BIND_CASES="ok.md:: ok.md:alpha: ok.md:alpha:/h/a ok.md:alpha:/h/z ok.md:gamma: ok.md:bad!: dupid.md:: duphome.md:: overlap.md:: malformed.md:: relhome.md:: tabhome.md:: nohome.md:: noscope.md:: missing.md:: noeol.md:alpha:/h/a"

oracle_head fm-secondmate-registry-lib > "$PROBES/registry.sh"
cat >> "$PROBES/registry.sh" <<SH
PARSE_KEYS="$PARSE_KEYS"
FIELD_CASES="$FIELD_CASES"
BIND_CASES="$BIND_CASES"
SH
cat >> "$PROBES/registry.sh" <<'SH'
F=$1 REALHOME=$2
identity_resolver() { printf '%s\n' "$1"; }

parse_line_for() {
  case "$1" in
    ok) printf '%s' '- alpha - runs the alpha domain (home: /h/a; scope: alpha work; projects: p1,p2; added 2026-01-02)' ;;
    punct) printf '%s' '- beta - handles (b) work; carefully (home: /h/b; scope: things (like this); and more; projects: p3; added 2026-02-03)' ;;
    nohome) printf '%s' '- zeta - nohome (home: ; scope: s; projects: ; added 2026-01-02)' ;;
    noscope) printf '%s' '- eta - noscope (home: /h/e; scope: ; projects: ; added 2026-01-02)' ;;
    broken) printf '%s' '- gamma - broken entry' ;;
    baddate) printf '%s' '- theta - x (home: /h/t; scope: s; projects: ; added 26-01-02)' ;;
  esac
}
for k in $PARSE_KEYS; do
  if secondmate_registry_parse_line "$(parse_line_for "$k")"; then
    emit "parse.$k" "0|$SECONDMATE_REGISTRY_ID|$SECONDMATE_REGISTRY_SUMMARY|$SECONDMATE_REGISTRY_HOME|$SECONDMATE_REGISTRY_SCOPE|$SECONDMATE_REGISTRY_PROJECTS|$SECONDMATE_REGISTRY_ADDED"
  else
    emit "parse.$k" '1|'
  fi
done

for c in $FIELD_CASES; do
  file=${c%%:*}; id=${c#*:}
  for key in home projects; do
    if v=$(secondmate_registry_field "$F/$file" "$id" "$key" 2>/dev/null); then
      emit "field.$file.$id.$key" "0|$v"
    else
      emit "field.$file.$id.$key" '1|'
    fi
  done
done
if v=$(secondmate_registry_field "$F/ok.md" alpha scope 2>/dev/null); then emit field.badkey "0|$v"; else emit field.badkey '1|'; fi

emit pathkey.dir "$(secondmate_registry_path_key "$REALHOME" 2>/dev/null)"
emit pathkey.child "$(secondmate_registry_path_key "$REALHOME/child" 2>/dev/null)"
emit pathkey.newleaf "$(secondmate_registry_path_key "$REALHOME/not-yet" 2>/dev/null)"
if v=$(secondmate_registry_path_key 'relative/path' 2>/dev/null); then emit pathkey.relative "0|$v"; else emit pathkey.relative '1|'; fi

for c in $BIND_CASES; do
  file=${c%%:*}; rest=${c#*:}; xid=${rest%%:*}; xhome=${rest#*:}
  if secondmate_registry_validate_bindings "$F/$file" identity_resolver "$xid" "$xhome" 2>/dev/null; then ok=True; else ok=False; fi
  emit "bind.$file.$xid.$xhome" "$ok|$SECONDMATE_REGISTRY_ERROR|$SECONDMATE_REGISTRY_MATCH_HOME|$SECONDMATE_REGISTRY_MATCH_PROJECTS"
done
SH

cat > "$PROBES/registry.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot, [string]$RealHome, [string]$ParseKeys, [string]$FieldCases, [string]$BindCases)
PSHEAD
probe_head >> "$PROBES/registry.ps1"
cat >> "$PROBES/registry.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-secondmate-registry-lib.psm1') -Force
function Get-RegPath { param([string]$Name) Join-Path $FixRoot $Name }

$parseLines = @{
    'ok'      = '- alpha - runs the alpha domain (home: /h/a; scope: alpha work; projects: p1,p2; added 2026-01-02)'
    'punct'   = '- beta - handles (b) work; carefully (home: /h/b; scope: things (like this); and more; projects: p3; added 2026-02-03)'
    'nohome'  = '- zeta - nohome (home: ; scope: s; projects: ; added 2026-01-02)'
    'noscope' = '- eta - noscope (home: /h/e; scope: ; projects: ; added 2026-01-02)'
    'broken'  = '- gamma - broken entry'
    'baddate' = '- theta - x (home: /h/t; scope: s; projects: ; added 26-01-02)'
}
foreach ($k in ($ParseKeys -split ' ')) {
    if ($k -eq '') { continue }
    $r = ConvertFrom-FmSecondmateRegistryLine -Line $parseLines[$k]
    if ($null -eq $r) {
        Emit "parse.$k" '1|'
    } else {
        Emit "parse.$k" ("0|{0}|{1}|{2}|{3}|{4}|{5}" -f $r.Id, $r.Summary, $r.Home, $r.Scope, $r.Projects, $r.Added)
    }
}

foreach ($c in ($FieldCases -split ' ')) {
    if ($c -eq '') { continue }
    $file = $c.Substring(0, $c.IndexOf(':'))
    $id = $c.Substring($c.IndexOf(':') + 1)
    foreach ($key in @('home', 'projects')) {
        $v = Get-FmSecondmateRegistryField -Registry (Get-RegPath $file) -Id $id -Key $key
        Emit "field.$file.$id.$key" $(if ($null -eq $v) { '1|' } else { "0|$v" })
    }
}
$bad = Get-FmSecondmateRegistryField -Registry (Get-RegPath 'ok.md') -Id 'alpha' -Key 'scope'
Emit 'field.badkey' $(if ($null -eq $bad) { '1|' } else { "0|$bad" })

Emit 'pathkey.dir' ([string](Get-FmSecondmateRegistryPathKey -Path $RealHome))
Emit 'pathkey.child' ([string](Get-FmSecondmateRegistryPathKey -Path (Join-Path $RealHome 'child')))
Emit 'pathkey.newleaf' ([string](Get-FmSecondmateRegistryPathKey -Path (Join-Path $RealHome 'not-yet')))
$rel = Get-FmSecondmateRegistryPathKey -Path 'relative/path'
Emit 'pathkey.relative' $(if ($null -eq $rel) { '1|' } else { "0|$rel" })

# The default resolver canonicalizes through the filesystem, and MSYS keeps its
# /tmp mount alias where this twin resolves the physical location, so the two
# worlds would legitimately produce different KEYS - and the duplicate and
# overlap messages embed those keys. An identity resolver removes that
# difference while exercising the same resolver-injection path fm-spawn and
# fm-home-seed actually use.
$identity = { param($p) $p }
foreach ($c in ($BindCases -split ' ')) {
    if ($c -eq '') { continue }
    $parts = $c.Split(':')
    $file = $parts[0]; $xid = $parts[1]; $xhome = $parts[2]
    $r = Resolve-FmSecondmateRegistryBinding -Registry (Get-RegPath $file) -Resolver $identity `
        -ExpectedId $xid -ExpectedHome $xhome
    Emit "bind.$file.$xid.$xhome" ("{0}|{1}|{2}|{3}" -f ([string]$r.Ok), $r.Error, $r.MatchHome, $r.MatchProjects)
}
PS

B_RG=$(oracle registry "$ROOT" "$RG" "$RG/realhome")
P_RG=$(probe registry "$BIN_N" "$FIX_N/registry" "$FIX_N/registry/realhome" \
  "$PARSE_KEYS" "$FIELD_CASES" "$BIND_CASES")

for k in $PARSE_KEYS; do
  both "parse.$k" "$B_RG" "$P_RG" "fm-secondmate-registry-lib: parse ($k)"
done
# The punctuated case is the one a recent bash fix exists for; assert the field
# boundaries literally so neither world can regress to the first delimiter.
assert_same "fm-secondmate-registry-lib: punctuated scope binds to the LAST '; projects:'" \
  "0|beta|handles (b) work; carefully|/h/b|things (like this); and more|p3|2026-02-03" \
  "$(ps_get "$P_RG" 'parse.punct')"
assert_same "fm-secondmate-registry-lib: an empty scope is rejected" "1|" "$(ps_get "$P_RG" 'parse.noscope')"

for c in $FIELD_CASES; do
  file=${c%%:*}; id=${c#*:}
  both "field.$file.$id.home" "$B_RG" "$P_RG" "fm-secondmate-registry-lib: field home ($file/$id)"
  both "field.$file.$id.projects" "$B_RG" "$P_RG" "fm-secondmate-registry-lib: field projects ($file/$id)"
done
both field.badkey "$B_RG" "$P_RG" "fm-secondmate-registry-lib: an unknown field key fails"
assert_same "fm-secondmate-registry-lib: a duplicate id refuses to resolve" \
  "1|" "$(ps_get "$P_RG" 'field.dupid.md.alpha.home')"
assert_same "fm-secondmate-registry-lib: a final line with no newline still parses" \
  "0|/h/a" "$(ps_get "$P_RG" 'field.noeol.md.alpha.home')"
assert_same "fm-secondmate-registry-lib: an empty projects field is a value, not a failure" \
  "0|" "$(ps_get "$P_RG" 'field.relhome.md.delta.projects')"

# Path keys name a LOCATION; the two worlds may legitimately spell it
# differently, so both sides are canonicalized. WHICH location is named still
# has to match.
for k in pathkey.dir pathkey.child pathkey.newleaf; do
  both_path "$k" "$B_RG" "$P_RG" "fm-secondmate-registry-lib: $k"
done
both pathkey.relative "$B_RG" "$P_RG" "fm-secondmate-registry-lib: a relative path has no key"

for c in $BIND_CASES; do
  file=${c%%:*}; rest=${c#*:}; xid=${rest%%:*}; xhome=${rest#*:}
  both_np "bind.$file.$xid.$xhome" "$B_RG" "$P_RG" \
    "fm-secondmate-registry-lib: binding validation ($file id=[$xid] home=[$xhome])"
done
# The three multi-entry safety verdicts, asserted literally: these messages
# reach the captain verbatim through fm-teardown and fm-spawn.
assert_same "fm-secondmate-registry-lib: the overlap message names both homes" \
  "False|overlapping secondmate home assignment: local:/h/a (alpha) contains local:/h/a/inner (beta)||" \
  "$(ps_get "$P_RG" 'bind.overlap.md..')"
assert_same "fm-secondmate-registry-lib: the duplicate-home message names both ids" \
  "False|duplicate secondmate home assignment: local:/h/a: alpha, beta||" \
  "$(ps_get "$P_RG" 'bind.duphome.md..')"
assert_same "fm-secondmate-registry-lib: an expected home mismatch names both" \
  "False|secondmate alpha is registered at /h/a, not /h/z|/h/a|p1,p2" \
  "$(ps_get "$P_RG" 'bind.ok.md.alpha./h/z')"
assert_same "fm-secondmate-registry-lib: a clean registry validates" \
  "True|||" "$(ps_get "$P_RG" 'bind.ok.md..')"

# ============================================================================
# fm-startup-memory-budget-lib
# ============================================================================

MB="$FIX/membudget"; mkdir -p "$MB"
mkdir -p "$MB/cfg-valid" "$MB/cfg-empty" "$MB/cfg-bad" "$MB/cfg-zero" "$MB/cfg-leading" \
         "$MB/cfg-noeol" "$MB/cfg-extra" "$MB/cfg-hardlink" "$MB/cfg-dirfile"
printf '7500\n'   > "$MB/cfg-valid/startup-memory-budget"
printf 'abc\n'    > "$MB/cfg-bad/startup-memory-budget"
printf '0\n'      > "$MB/cfg-zero/startup-memory-budget"
printf '07500\n'  > "$MB/cfg-leading/startup-memory-budget"
printf '7500'     > "$MB/cfg-noeol/startup-memory-budget"
printf '7500\n\n' > "$MB/cfg-extra/startup-memory-budget"
printf '7500\n'   > "$MB/hardlink-source"
ln "$MB/hardlink-source" "$MB/cfg-hardlink/startup-memory-budget" 2>/dev/null || true
mkdir -p "$MB/cfg-dirfile/startup-memory-budget"
printf 'hello world\n' > "$MB/measure-11"   # 12 bytes -> ceil(12/3) = 4
printf 'x' > "$MB/measure-1"                # 1 byte   -> 1
: > "$MB/measure-0"                         # 0 bytes  -> 0
mkdir -p "$MB/measure-dir"

MB_FILE_CASES="valid empty bad zero leading noeol extra hardlink dirfile"
MB_BYTES="0 1 2 3 4 300 EMPTY abc 12x"
MB_MEASURE="measure-11 measure-1 measure-0 measure-dir measure-absent"
MB_LE="9~10 10~9 7500~7500 7499~7500 7501~7500 EMPTY~5 5~EMPTY a~5 1:2~3 99999999999999999999~100000000000000000000"

oracle_head fm-startup-memory-budget-lib > "$PROBES/membudget.sh"
cat >> "$PROBES/membudget.sh" <<SH
FILE_CASES="$MB_FILE_CASES"
BYTES="$MB_BYTES"
MEASURES="$MB_MEASURE"
LE_PAIRS="$MB_LE"
SH
cat >> "$PROBES/membudget.sh" <<'SH'
F=$1
unesc() { if [ "$1" = EMPTY ]; then printf ''; else printf '%s' "$1"; fi; }

emit const.file "$FM_STARTUP_MEMORY_BUDGET_FILE"
emit const.default "$FM_STARTUP_MEMORY_BUDGET_DEFAULT"

for c in $FILE_CASES; do
  if fm_startup_memory_budget_file_valid "$F/cfg-$c/startup-memory-budget"; then ok=True; else ok=False; fi
  emit "file.$c" "$ok|$FM_STARTUP_MEMORY_BUDGET_ERROR|$FM_STARTUP_MEMORY_BUDGET_VALUE"
  if fm_startup_memory_budget_read "$F/cfg-$c" >/dev/null 2>&1; then
    emit "read.$c" "0|$(fm_startup_memory_budget_read "$F/cfg-$c" 2>/dev/null)"
  else
    emit "read.$c" "1|$FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
done

if fm_startup_memory_budget_config_dir_safe "$F/cfg-does-not-exist"; then ok=True; else ok=False; fi
emit dirsafe.missing "$ok|$FM_STARTUP_MEMORY_BUDGET_ERROR"
if fm_startup_memory_budget_config_dir_safe "$F/cfg-valid"; then ok=True; else ok=False; fi
emit dirsafe.real "$ok|$FM_STARTUP_MEMORY_BUDGET_ERROR"

for b in $BYTES; do
  bv=$(unesc "$b")
  if v=$(fm_startup_memory_estimated_tokens_for_bytes "$bv"); then emit "tokens.[$b]" "0|$v"; else emit "tokens.[$b]" '1|'; fi
done

for m in $MEASURES; do
  if fm_startup_memory_measure_file "$F/$m" >/dev/null 2>&1; then
    emit "measure.$m" "0|$(fm_startup_memory_measure_file "$F/$m" 2>/dev/null)"
  else
    emit "measure.$m" "1|$FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
done

for p in $LE_PAIRS; do
  l=$(unesc "${p%%~*}"); r=$(unesc "${p#*~}")
  emit "le.$p" "$(tf fm_startup_memory_decimal_le "$l" "$r")"
done

# The bash publishes into its own fresh directory; the PowerShell reader
# validates that artifact afterwards.
fm_startup_memory_budget_materialize "$F/cfg-bash-new" >/dev/null 2>&1 || true
SH

cat > "$PROBES/membudget.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot, [string]$FileCases, [string]$ByteCases, [string]$Measures, [string]$LePairs)
PSHEAD
probe_head >> "$PROBES/membudget.ps1"
cat >> "$PROBES/membudget.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-startup-memory-budget-lib.psm1') -Force
function Convert-Token { param([string]$T) if ($T -eq 'EMPTY') { '' } else { $T } }

Emit 'const.file' (Get-FmStartupMemoryBudgetFileName)
Emit 'const.default' (Get-FmStartupMemoryBudgetDefault)

foreach ($case in ($FileCases -split ' ')) {
    if ($case -eq '') { continue }
    $dir = Join-Path $FixRoot "cfg-$case"
    $ok = Test-FmStartupMemoryBudgetFile -Path (Join-Path $dir 'startup-memory-budget')
    Emit "file.$case" ("{0}|{1}|{2}" -f ([string]$ok), (Get-FmStartupMemoryBudgetError), (Get-FmStartupMemoryBudgetValue))
    $v = Get-FmStartupMemoryBudget -ConfigDir $dir
    Emit "read.$case" $(if ($null -eq $v) { "1|$(Get-FmStartupMemoryBudgetError)" } else { "0|$v" })
}

$missing = Test-FmStartupMemoryBudgetConfigDir -Directory (Join-Path $FixRoot 'cfg-does-not-exist')
Emit 'dirsafe.missing' ("{0}|{1}" -f ([string]$missing), (Get-FmStartupMemoryBudgetError))
$real = Test-FmStartupMemoryBudgetConfigDir -Directory (Join-Path $FixRoot 'cfg-valid')
Emit 'dirsafe.real' ("{0}|{1}" -f ([string]$real), (Get-FmStartupMemoryBudgetError))

foreach ($b in ($ByteCases -split ' ')) {
    if ($b -eq '') { continue }
    $t = Get-FmStartupMemoryEstimatedToken -Bytes (Convert-Token $b)
    Emit "tokens.[$b]" $(if ($null -eq $t) { '1|' } else { "0|$t" })
}

foreach ($m in ($Measures -split ' ')) {
    if ($m -eq '') { continue }
    $r = Measure-FmStartupMemoryFile -Path (Join-Path $FixRoot $m)
    Emit "measure.$m" $(if ($null -eq $r) { "1|$(Get-FmStartupMemoryBudgetError)" } else { "0|$($r.Text)" })
}

foreach ($p in ($LePairs -split ' ')) {
    if ($p -eq '') { continue }
    $l = Convert-Token $p.Substring(0, $p.IndexOf('~'))
    $r = Convert-Token $p.Substring($p.IndexOf('~') + 1)
    Emit "le.$p" ([string](Test-FmStartupMemoryDecimalLe -Left $l -Right $r))
}

# Materialization into a directory that does not exist yet, then a second run
# over the file it just published.
$newDir = Join-Path $FixRoot 'cfg-ps-new'
Emit 'materialize.fresh' ([string](Initialize-FmStartupMemoryBudget -ConfigDir $newDir))
Emit 'materialize.again' ([string](Initialize-FmStartupMemoryBudget -ConfigDir $newDir))
Emit 'materialize.value' ([string](Get-FmStartupMemoryBudget -ConfigDir $newDir))
$badOk = Initialize-FmStartupMemoryBudget -ConfigDir (Join-Path $FixRoot 'cfg-bad')
Emit 'materialize.bad' ("{0}|{1}" -f ([string]$badOk), (Get-FmStartupMemoryBudgetError))
# Read back what the bash oracle published into its own directory.
$fromBash = Get-FmStartupMemoryBudget -ConfigDir (Join-Path $FixRoot 'cfg-bash-new')
Emit 'materialize.frombash' $(if ($null -eq $fromBash) { "1|$(Get-FmStartupMemoryBudgetError)" } else { "0|$fromBash" })
PS

# Bash publishes first so the PowerShell probe can read its artifact back.
B_MB=$(oracle membudget "$ROOT" "$MB")
P_MB=$(probe membudget "$BIN_N" "$FIX_N/membudget" "$MB_FILE_CASES" "$MB_BYTES" "$MB_MEASURE" "$MB_LE")

both const.file "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: config file name"
both const.default "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: default value"
for case in $MB_FILE_CASES; do
  both "file.$case" "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: file validity ($case)"
  both "read.$case" "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: read ($case)"
done
both dirsafe.missing "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: config dir safety (missing)"
both dirsafe.real "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: config dir safety (real)"
for b in $MB_BYTES; do
  both "tokens.[$b]" "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: token estimate [$b]"
done
for m in $MB_MEASURE; do
  both_np "measure.$m" "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: measure ($m)"
done
for p in $MB_LE; do
  both "le.$p" "$B_MB" "$P_MB" "fm-startup-memory-budget-lib: decimal <= ($p)"
done

assert_same "fm-startup-memory-budget-lib: a hard-linked budget file is rejected" \
  "False|file is hardlinked|" "$(ps_get "$P_MB" 'file.hardlink')"
assert_same "fm-startup-memory-budget-lib: a value with no terminating newline is rejected" \
  "False|file must contain exactly one value followed by one newline|" "$(ps_get "$P_MB" 'file.noeol')"
assert_same "fm-startup-memory-budget-lib: a leading zero is rejected" \
  "False|value must be one positive decimal integer|" "$(ps_get "$P_MB" 'file.leading')"
assert_same "fm-startup-memory-budget-lib: the estimate rounds UP" "0|2" "$(ps_get "$P_MB" 'tokens.[4]')"
assert_same "fm-startup-memory-budget-lib: an absent memory file measures as absent, not as an error" \
  "0|0 0 absent" "$(ps_get "$P_MB" 'measure.measure-absent')"
assert_same "fm-startup-memory-budget-lib: a 12-byte file estimates 4 tokens" \
  "0|12 4 present" "$(ps_get "$P_MB" 'measure.measure-11')"
assert_same "fm-startup-memory-budget-lib: comparison survives past shell integer range" \
  "True" "$(ps_get "$P_MB" 'le.99999999999999999999~100000000000000000000')"

# Cross-world publication, in both directions.
assert_same "fm-startup-memory-budget-lib: materialize into a fresh directory" \
  "True" "$(ps_get "$P_MB" 'materialize.fresh')"
assert_same "fm-startup-memory-budget-lib: materialize is idempotent" \
  "True" "$(ps_get "$P_MB" 'materialize.again')"
assert_same "fm-startup-memory-budget-lib: materialize refuses a malformed existing file" \
  "False|value must be one positive decimal integer" "$(ps_get "$P_MB" 'materialize.bad')"
assert_same "fm-startup-memory-budget-lib: bash-published default reads under PowerShell" \
  "0|7500" "$(ps_get "$P_MB" 'materialize.frombash')"
assert_same "fm-startup-memory-budget-lib: PowerShell-published default is exactly value+LF" \
  "$(printf '7500\n' | od -c)" "$(od -c "$MB/cfg-ps-new/startup-memory-budget")"
oracle_head fm-startup-memory-budget-lib > "$PROBES/membudget-read.sh"
cat >> "$PROBES/membudget-read.sh" <<'SH'
F=$1
if v=$(fm_startup_memory_budget_read "$F/cfg-ps-new"); then emit psnew "0|$v"; else emit psnew "1|$FM_STARTUP_MEMORY_BUDGET_ERROR"; fi
SH
B_MB2=$(oracle membudget-read "$ROOT" "$MB")
assert_same "fm-startup-memory-budget-lib: PowerShell-published default reads under bash" \
  "0|7500" "$(ps_get "$B_MB2" psnew)"

# ============================================================================
# fm-supervisor-target-lib
# ============================================================================
#
# The env matrix is walked inside each side's single interpreter, so no case
# can leak an exported variable into the next or into the parent shell.

oracle_head fm-supervisor-target-lib > "$PROBES/supervisor.sh"
cat >> "$PROBES/supervisor.sh" <<'SH'
emit const.target "$FM_SUPERVISOR_TARGET_DEFAULT"
emit const.backend "$FM_SUPERVISOR_BACKEND_DEFAULT"
sup() {
  local name=$1; shift
  unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION
  local kv t b tr br
  for kv in "$@"; do export "$kv"; done
  t=$(discover_supervisor_target); tr=$?
  b=$(discover_supervisor_backend); br=$?
  emit "sup.$name" "$t|$tr|$b|$br"
}
sup none
sup explicit FM_SUPERVISOR_TARGET=fm:cap FM_SUPERVISOR_BACKEND=herdr
sup tmux TMUX_PANE=%7
sup herdr HERDR_ENV=1 HERDR_PANE_ID=p9
sup herdrsess HERDR_ENV=1 HERDR_PANE_ID=p9 HERDR_SESSION=lab
sup tmuxwins TMUX_PANE=%7 HERDR_ENV=1 HERDR_PANE_ID=p9
sup herdrnopane HERDR_ENV=1
sup emptytarget FM_SUPERVISOR_TARGET= TMUX_PANE=%7
SH

cat > "$PROBES/supervisor.ps1" <<'PSHEAD'
param([string]$BinDir)
PSHEAD
probe_head >> "$PROBES/supervisor.ps1"
cat >> "$PROBES/supervisor.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-supervisor-target-lib.psm1') -Force

Emit 'const.target' (Get-FmSupervisorTargetDefault)
Emit 'const.backend' (Get-FmSupervisorBackendDefault)

$cases = @(
    @{ n = 'none';        e = @{} },
    @{ n = 'explicit';    e = @{ FM_SUPERVISOR_TARGET = 'fm:cap'; FM_SUPERVISOR_BACKEND = 'herdr' } },
    @{ n = 'tmux';        e = @{ TMUX_PANE = '%7' } },
    @{ n = 'herdr';       e = @{ HERDR_ENV = '1'; HERDR_PANE_ID = 'p9' } },
    @{ n = 'herdrsess';   e = @{ HERDR_ENV = '1'; HERDR_PANE_ID = 'p9'; HERDR_SESSION = 'lab' } },
    @{ n = 'tmuxwins';    e = @{ TMUX_PANE = '%7'; HERDR_ENV = '1'; HERDR_PANE_ID = 'p9' } },
    @{ n = 'herdrnopane'; e = @{ HERDR_ENV = '1' } },
    @{ n = 'emptytarget'; e = @{ FM_SUPERVISOR_TARGET = ''; TMUX_PANE = '%7' } }
)
$names = @('FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION')
# Remove-Item, not SetEnvironmentVariable($null): the latter leaves the name
# behind with an empty value (see the gate probe). Get-FmEnv's `${VAR:-}`
# semantics happen to make the two equivalent here, but the correct spelling is
# what later waves will copy.
foreach ($c in $cases) {
    foreach ($n in $names) { Remove-Item -LiteralPath "Env:\$n" -ErrorAction SilentlyContinue }
    foreach ($k in $c.e.Keys) { [Environment]::SetEnvironmentVariable($k, $c.e[$k]) }
    $t = Get-FmSupervisorTarget
    $b = Get-FmSupervisorBackend
    Emit "sup.$($c.n)" ("{0}|{1}|{2}|{3}" -f $t.Value, $(if ($t.Detected) { '0' } else { '1' }), `
        $b.Value, $(if ($b.Detected) { '0' } else { '1' }))
}
PS

B_SUP=$(oracle supervisor "$ROOT")
P_SUP=$(probe supervisor "$BIN_N")

both const.target "$B_SUP" "$P_SUP" "fm-supervisor-target-lib: default target"
both const.backend "$B_SUP" "$P_SUP" "fm-supervisor-target-lib: default backend"
for case in none explicit tmux herdr herdrsess tmuxwins herdrnopane emptytarget; do
  both "sup.$case" "$B_SUP" "$P_SUP" "fm-supervisor-target-lib: discovery ($case)"
done
assert_same "fm-supervisor-target-lib: nothing configured falls back and reports it" \
  "firstmate:0|1|tmux|1" "$(ps_get "$P_SUP" 'sup.none')"
assert_same "fm-supervisor-target-lib: a tmux pane nested inside herdr resolves to tmux" \
  "%7|0|tmux|0" "$(ps_get "$P_SUP" 'sup.tmuxwins')"
assert_same "fm-supervisor-target-lib: a herdr pane composes session:pane" \
  "lab:p9|0|herdr|0" "$(ps_get "$P_SUP" 'sup.herdrsess')"
assert_same "fm-supervisor-target-lib: an empty override falls through" \
  "%7|0|tmux|0" "$(ps_get "$P_SUP" 'sup.emptytarget')"

# ============================================================================
# fm-backend-hometag-lib
# ============================================================================
#
# The tag is a CROSS-WORLD contract (a bash adapter and a PowerShell one may
# address one shared workspace namespace), so the FULL tag string is compared,
# not just its shape.
#
# The hashed input is the ROOT's physical POSIX path, and that is where the two
# worlds can legitimately disagree: MSYS mounts /tmp onto the user's Temp
# directory and `pwd -P` keeps the /tmp alias, while the twin resolves the
# physical location - so a root under /tmp hashes differently in each world.
# The module header documents that divergence. Rather than hide it behind a
# canonicalization, the fixture uses a root where no alias exists: the
# firstmate repo root itself, which both worlds spell /f/... . It is only READ
# (the marker fixtures that decide the prefix still live under the temp root),
# so nothing is written outside the test's own directory.

HT="$FIX/hometag"; mkdir -p "$HT"
HT_ROOT=$ROOT
HT_BADROOT="$ROOT/fm-no-such-root"
mkdir -p "$HT/primary" "$HT/second" "$HT/spaced" "$HT/emptymarker"
printf 'alpha\n'     > "$HT/second/.fm-secondmate-home"
printf '  al pha \n' > "$HT/spaced/.fm-secondmate-home"
: > "$HT/emptymarker/.fm-secondmate-home"

oracle_head fm-backend-hometag-lib > "$PROBES/hometag.sh"
cat >> "$PROBES/hometag.sh" <<'SH'
F=$1 ROOTDIR=$2 BADROOT=$3
emit const.marker "$FM_BACKEND_HOMETAG_SECONDMATE_MARKER"
FM_ROOT=$ROOTDIR
for c in primary second spaced emptymarker missing; do
  FM_HOME="$F/$c"
  emit "tag.$c" "$(fm_backend_hometag)"
done
FM_HOME="$F/primary"; FM_ROOT=$BADROOT
emit tag.badroot "$(fm_backend_hometag)"
SH

cat > "$PROBES/hometag.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot, [string]$RootDir, [string]$BadRoot)
PSHEAD
probe_head >> "$PROBES/hometag.ps1"
cat >> "$PROBES/hometag.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-backend-hometag-lib.psm1') -Force

Emit 'const.marker' (Get-FmBackendHometagMarkerName)
# RootDir and BadRoot arrive in POSIX form, the same strings the bash oracle
# is given: the tag must not depend on which spelling a caller happens to hold.
foreach ($case in @('primary', 'second', 'spaced', 'emptymarker', 'missing')) {
    Emit "tag.$case" (Get-FmBackendHomeTag -FmHome (Join-Path $FixRoot $case) -FmRoot $RootDir)
}
# A root that does not exist falls back to the given spelling rather than
# failing, so a tag is still produced.
Emit 'tag.badroot' (Get-FmBackendHomeTag -FmHome (Join-Path $FixRoot 'primary') -FmRoot $BadRoot)
PS

B_HT=$(oracle hometag "$ROOT" "$HT" "$HT_ROOT" "$HT_BADROOT")
P_HT=$(probe hometag "$BIN_N" "$(fm_test_native_path "$HT")" "$HT_ROOT" "$HT_BADROOT")

both const.marker "$B_HT" "$P_HT" "fm-backend-hometag-lib: marker name"
for case in primary second spaced emptymarker missing badroot; do
  both "tag.$case" "$B_HT" "$P_HT" "fm-backend-hometag-lib: tag ($case)"
done
# The prefix half of the contract: a secondmate home and the primary home under
# the same root differ ONLY in prefix, so both the prefix rule and the hash of
# the root path have to agree.
assert_same "fm-backend-hometag-lib: primary and secondmate tags share one root hash" \
  "$(ps_get "$P_HT" 'tag.primary' | sed 's/^firstmate-//')" \
  "$(ps_get "$P_HT" 'tag.second' | sed 's/^2ndmate-alpha-//')"
assert_same "fm-backend-hometag-lib: an empty marker falls back to the primary prefix" \
  "$(ps_get "$P_HT" 'tag.primary')" "$(ps_get "$P_HT" 'tag.emptymarker')"

# ============================================================================
# fm-gate-refuse-lib
# ============================================================================
#
# tests/lib.sh exports FM_GATE_REFUSE_BYPASS=1 for the whole suite, so the
# refusal cases below strip it explicitly (as tests/fm-gate-refuse.test.sh
# does) - otherwise this would only ever prove that the bypass works.

GT="$FIX/gate"; mkdir -p "$GT"
git init -q --bare "$GT/.no-mistakes/repos/proj.git"
fm_git_init_commit "$GT/normal"

oracle_head fm-gate-refuse-lib > "$PROBES/gate.sh"
cat >> "$PROBES/gate.sh" <<'SH'
F=$1
GATE="$F/.no-mistakes/repos/proj.git"
NORMAL="$F/normal"
emit const.exit "$FM_GATE_REFUSE_EXIT"
one() {  # <label> <anchor> <bypass|-> <nmgate|-|EMPTY>
  unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_GATE_REFUSE_REASON FM_GATE_REFUSE_COMMON
  [ "$3" = - ] || export FM_GATE_REFUSE_BYPASS="$3"
  case "$4" in
    -) : ;;
    EMPTY) export NO_MISTAKES_GATE= ;;
    *) export NO_MISTAKES_GATE="$4" ;;
  esac
  if fm_is_gate_agent "$2"; then ok=True; else ok=False; fi
  emit "$1" "$ok|${FM_GATE_REFUSE_REASON:-}"
}
one gate.bypass "$GATE" 1 -
one gate.env "$NORMAL" - x
one gate.envempty "$NORMAL" - EMPTY
one gate.path "$GATE" - -
one gate.normal "$NORMAL" - -
one gate.missing "$F/no-such-dir" - -
one gate.fix "$F" - -
unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
fm_is_gate_agent "$GATE" >/dev/null 2>&1
emit gate.common "${FM_GATE_REFUSE_COMMON:-}"
SH

cat > "$PROBES/gate.ps1" <<'PSHEAD'
param([string]$BinDir, [string]$FixRoot)
PSHEAD
probe_head >> "$PROBES/gate.ps1"
cat >> "$PROBES/gate.ps1" <<'PS'
Import-Module (Join-Path $BinDir 'fm-gate-refuse-lib.psm1') -Force

Emit 'const.exit' ([string](Get-FmGateRefuseExitCode))
$gateRepo = Join-Path $FixRoot '.no-mistakes/repos/proj.git'
$normal = Join-Path $FixRoot 'normal'

# [Environment]::SetEnvironmentVariable(name, $null) does NOT delete the
# variable from PowerShell: $null binds to the [string] parameter as '', so the
# name survives with an EMPTY value and GetEnvironmentVariable then answers ''
# instead of $null (verified on PowerShell 7.6.4). Distinguishing unset from
# set-but-empty is precisely what this library's primary signal does, so the
# provider's Remove-Item is what genuinely clears one.
function Clear-EnvVar {
    param([Parameter(Mandatory)][string]$Name)
    Remove-Item -LiteralPath "Env:\$Name" -ErrorAction SilentlyContinue
}
function Set-EnvVar {
    param([Parameter(Mandatory)][string]$Name, [object]$Value)
    if ($null -eq $Value) { Clear-EnvVar -Name $Name } else { [Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}
function Test-GateCase {
    param([string]$Label, [string]$Anchor, [object]$Bypass, [object]$GateEnv)
    Set-EnvVar -Name 'FM_GATE_REFUSE_BYPASS' -Value $Bypass
    Set-EnvVar -Name 'NO_MISTAKES_GATE' -Value $GateEnv
    $r = Test-FmGateAgent -Anchor $Anchor
    Emit $Label ("{0}|{1}" -f ([string]$r), (Get-FmGateRefuseReason))
}
Test-GateCase -Label 'gate.bypass' -Anchor $gateRepo -Bypass '1' -GateEnv $null
Test-GateCase -Label 'gate.env' -Anchor $normal -Bypass $null -GateEnv 'x'
Test-GateCase -Label 'gate.envempty' -Anchor $normal -Bypass $null -GateEnv ''
Test-GateCase -Label 'gate.path' -Anchor $gateRepo -Bypass $null -GateEnv $null
Test-GateCase -Label 'gate.normal' -Anchor $normal -Bypass $null -GateEnv $null
Test-GateCase -Label 'gate.missing' -Anchor (Join-Path $FixRoot 'no-such-dir') -Bypass $null -GateEnv $null
Test-GateCase -Label 'gate.fix' -Anchor $FixRoot -Bypass $null -GateEnv $null

Clear-EnvVar -Name 'FM_GATE_REFUSE_BYPASS'
Clear-EnvVar -Name 'NO_MISTAKES_GATE'
$null = Test-FmGateAgent -Anchor $gateRepo
Emit 'gate.common' (Get-FmGateRefuseCommonDir)
PS

B_GT=$(oracle gate "$ROOT" "$GT")
P_GT=$(probe gate "$BIN_N" "$FIX_N/gate")

both const.exit "$B_GT" "$P_GT" "fm-gate-refuse-lib: refusal exit code"
for k in gate.bypass gate.env gate.envempty gate.path gate.normal gate.missing gate.fix; do
  both "$k" "$B_GT" "$P_GT" "fm-gate-refuse-lib: $k"
done
# The reported gate dir names one location the two worlds may spell differently.
both_path gate.common "$B_GT" "$P_GT" "fm-gate-refuse-lib: the reported gate dir names the same location"
assert_same "fm-gate-refuse-lib: the unspoofable path signal really fires" \
  "True|path" "$(ps_get "$P_GT" 'gate.path')"
assert_same "fm-gate-refuse-lib: a normal checkout is unaffected" \
  "False|" "$(ps_get "$P_GT" 'gate.normal')"
assert_same "fm-gate-refuse-lib: the test-harness bypass wins over both signals" \
  "False|" "$(ps_get "$P_GT" 'gate.bypass')"

# --- the hard exit ----------------------------------------------------------
# The refusal must terminate the CALLING script, not merely return, and it must
# use exit code 3 with the exact operator-facing message. `exit` inside a
# PowerShell module function unwinds through the importing script, which is what
# makes this a genuine twin of the bash `exit "$FM_GATE_REFUSE_EXIT"`.
cat > "$PROBES/gate-assert.ps1" <<'PS'
param([string]$BinDir, [string]$Anchor)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $BinDir 'fm-gate-refuse-lib.psm1') -Force
Assert-FmNotGateAgent -Anchor $Anchor
[Console]::Out.Write("NOT REFUSED`n")
PS
cat > "$PROBES/gate-assert.sh" <<SH
#!/usr/bin/env bash
. "$ROOT/bin/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent "\$1"
printf 'NOT REFUSED\n'
SH

gate_assert_ps() {  # <anchor-native> <nmgate|-> -> "<rc>|<output>"
  local out rc
  if [ "$2" = - ]; then
    out=$(env -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
      pwsh -NoProfile -File "$(fm_test_native_path "$PROBES/gate-assert.ps1")" "$BIN_N" "$1" 2>&1); rc=$?
  else
    out=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE="$2" \
      pwsh -NoProfile -File "$(fm_test_native_path "$PROBES/gate-assert.ps1")" "$BIN_N" "$1" 2>&1); rc=$?
  fi
  printf '%s|%s' "$rc" "$out"
}
gate_assert_bash() {  # <anchor> <nmgate|-> -> "<rc>|<output>"
  local out rc
  if [ "$2" = - ]; then
    out=$(env -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE bash "$PROBES/gate-assert.sh" "$1" 2>&1); rc=$?
  else
    out=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE="$2" bash "$PROBES/gate-assert.sh" "$1" 2>&1); rc=$?
  fi
  printf '%s|%s' "$rc" "$out"
}

assert_same "fm-gate-refuse-lib: refusal exits 3 with the env message" \
  "$(gate_assert_bash "$GT/normal" x)" "$(gate_assert_ps "$(fm_test_native_path "$GT/normal")" x)"
assert_same "fm-gate-refuse-lib: a normal session proceeds past the guard" \
  "$(gate_assert_bash "$GT/normal" -)" "$(gate_assert_ps "$(fm_test_native_path "$GT/normal")" -)"
assert_same "fm-gate-refuse-lib: the refusal really is exit 3, and the caller stops" \
  "3|error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)" \
  "$(gate_assert_ps "$(fm_test_native_path "$GT/normal")" x)"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - PowerShell leaf libs differ from their bash contracts (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass: the assertion
# count is itself asserted, so a future refactor that drops cases fails loudly
# instead of certifying an empty run.
MIN_ASSERTIONS=170
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - ten PowerShell leaf libs match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-small-libs-psm1.test.sh: all assertions passed\n'
