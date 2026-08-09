#!/usr/bin/env bash
# Behavior test for bin/fm-psproc-lib.psm1 - the PowerShell process primitives.
#
# DIFFERENTIAL against bin/fm-psproc-lib.sh wherever bash can answer, and
# GROUND-TRUTH wherever it cannot. That split is not a convenience: it is the
# whole reason fm-psproc-lib.sh exists. The bash lib was written during the
# Windows bash port to work around an EMULATED process table - Cygwin `ps`
# rejects `-o` outright, `/proc` covers MSYS processes only, and a bash whose
# parent is a native Windows process reports PPID=1 - so about a NATIVE process
# it can answer "is it alive and what is its image" and nothing else. Where the
# bash twin returns a documented failure it cannot be the oracle, so each such
# case says so, asserts the refusal, and then checks the PowerShell answer
# against a fact this test established itself: a process it spawned, with a
# parent and an argument it chose.
#
# TWO PID SPACES. Git Bash's `$$` is an MSYS-side pid from a different number
# space than Windows uses: verified on this host, one bash reported $$=2102028
# while its Windows pid was 22316. The bash primitives take the MSYS pid; the
# PowerShell module takes the Windows pid, the only space it can see. So a
# differential case asks each side about the SAME OS PROCESS through the pid
# that side understands, bridging with the WINPID column of `ps -p` (fm_winpid
# below). Off Windows the two spaces are one and the bridge is identity.
#
# TWO SNAPSHOTS, NOT INTERLEAVED QUERIES. Every bash answer is captured up
# front, immediately after the fixtures come up, and every PowerShell answer in
# one batched process right after. Comparing is then pure string work. This is
# load-bearing rather than tidy: an earlier draft queried each side inside the
# assertions, and MSYS fork cost stretched the run past the fixtures' own
# lifetime, so late assertions compared a live PowerShell answer against a bash
# answer about a process that had since exited. The helpers below therefore
# avoid external processes wherever bash builtins can do the work.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7. No bash-4-only syntax (no
# associative arrays, no ${var,,}), matching the rest of this tree.
#
# Every path handed to pwsh, INCLUDING the Import-Module path, goes through
# fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads /tmp/x
# as C:\tmp\x - verified).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

[ -f "$ROOT/bin/fm-psproc-lib.psm1" ] || fail "bin/fm-psproc-lib.psm1 is missing"
MOD=$(fm_test_native_path "$ROOT/bin/fm-psproc-lib.psm1")

# The oracle.
# shellcheck source=bin/fm-psproc-lib.sh
. "$ROOT/bin/fm-psproc-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-psproc-psm1)

case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

# --- fixture lifetime ---------------------------------------------------------
#
# Declared before anything is spawned so a failure between spawn and assertion
# still tears the fixtures down. Every kill is best-effort: a fixture that
# already exited is a normal outcome, not an error. Each live fixture also
# self-terminates within 180s, so even a hard kill of this script cannot leak
# one. That budget is deliberately generous, because the runtime is dominated by
# the BASH side and every bash probe is a process spawn: measured on this host
# while four agents were working in the tree, `ps -W` took 2.2s, `tasklist`
# 3.7s, and fm_proc_comm on an absent pid 8.9s, putting a full run in the
# minutes. On an idle host the same run is well under a minute. A fixture that
# dies mid-run does not fail SAFE - it makes the live PowerShell answer disagree
# with a bash answer about a process that has since exited, which reads as a
# module bug rather than as a fixture that expired.
FIXTURE_MSYS_JOB=
FIXTURE_NATIVE_JOB=
FIXTURE_NATIVE_PARENT=
FIXTURE_NATIVE_CHILD=

psproc_cleanup() {
  [ -n "$FIXTURE_MSYS_JOB" ] && kill "$FIXTURE_MSYS_JOB" 2>/dev/null
  [ -n "$FIXTURE_NATIVE_JOB" ] && kill "$FIXTURE_NATIVE_JOB" 2>/dev/null
  if [ "$IS_WINDOWS" = 1 ]; then
    # //F //T: the child is `cmd /c ping`, so the tree, not just cmd, must go.
    # MSYS turns each leading // into a single / for the native tool.
    [ -n "$FIXTURE_NATIVE_CHILD" ] && taskkill //F //T //PID "$FIXTURE_NATIVE_CHILD" >/dev/null 2>&1
    [ -n "$FIXTURE_NATIVE_PARENT" ] && taskkill //F //PID "$FIXTURE_NATIVE_PARENT" >/dev/null 2>&1
  fi
  fm_test_cleanup
}
trap psproc_cleanup EXIT

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables, and nothing below runs inside a `( ... )` subshell. A
# subshell cannot report a failure back to the parent's counters, so a
# bookkeeping scheme that can LOSE a failure is worse than none: the suite would
# certify work it never checked.
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

# --- normalization, declared rather than applied silently ---------------------
#
# The two worlds can name one executable differently and both be right, so
# demanding byte equality would fail on spelling rather than on behavior.
# Exactly three spellings differ, and each is normalized explicitly:
#
#   .exe        Windows carries the suffix; MSYS /proc/<pid>/exename does not
#               (/usr/bin/sleep vs C:\...\sleep.exe).
#   path form   Cygwin `ps -W` posixifies image paths under a known mount and
#               drops the suffix (/c/Program Files/PowerShell/7/pwsh) yet leaves
#               others in Windows form (C:\Windows\System32\cmd.exe). Both were
#               observed on this host in one run.
#   case        the same file comes back as C:\WINDOWS\SYSTEM32\cmd.exe from one
#               side and C:\Windows\System32\cmd.exe from the other.
#
# Nothing else is softened: WHICH process each side names, whether it answered
# at all, and every pid value still have to match exactly. The refusal markers
# pass through untouched, so "both failed" can never be mistaken for "both
# agreed on an empty value".
#
# Each helper publishes through a global instead of stdout so a call site needs
# no command substitution; see the fork-cost note in the file header.
FM_NORM=

fm_norm_image() {  # <value> -> FM_NORM: the lowercased leaf without .exe
  local v=$1
  case "$v" in '<fail>'|'<missing>'|'<skipped>'|'') FM_NORM=$v; return 0 ;; esac
  v=${v##*[/\\]}
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  FM_NORM=${v%.exe}
}

fm_norm_path() {  # <value> -> FM_NORM: lowercased MSYS form without .exe
  local p=$1 drive rest
  case "$p" in '<fail>'|'<missing>'|'<skipped>'|'') FM_NORM=$p; return 0 ;; esac
  # A POSIX path that is NOT already MSYS drive form (/c/...) is a MOUNT alias,
  # and only the mount table can resolve it: Cygwin `ps -W` reports the sleep
  # fixture as /usr/bin/sleep while PowerShell reports C:\Program
  # Files\Git\usr\bin\sleep.exe, and both name the same file. This is the same
  # class of difference tests/fm-common-psm1.test.sh records for /tmp. cygpath
  # is a process, so it is consulted ONLY for this case; the drive forms below
  # are pure parameter expansion.
  case "$p" in
    /?/*|/) ;;
    /*) p=$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p") ;;
  esac
  case "$p" in
    # The ConvertTo-FmPosixPath transform, by parameter expansion rather than a
    # cygpath process: C:\a\b -> /C/a/b, then folded to lower case below.
    [A-Za-z]:[\\/]*)
      drive=${p%%:*}
      rest=${p#?:}
      p="/$drive${rest//\\//}"
      ;;
    *) p=${p//\\//} ;;
  esac
  p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  FM_NORM=${p%.exe}
}

# The argument tail of a command line, with argv[0] removed in either spelling:
# a QUOTED Windows image path (which contains spaces) or a bare first token.
fm_args_tail() {  # <command-line> -> FM_NORM
  local s=$1
  case "$s" in '<fail>'|'<missing>'|'<skipped>'|'') FM_NORM=$s; return 0 ;; esac
  case "$s" in
    '"'*)
      s=${s#\"}     # drop the opening quote
      s=${s#*\"}    # drop everything through the closing quote
      ;;
    *' '*) s=${s#* } ;;
    *) s='' ;;
  esac
  while [ "${s# }" != "$s" ]; do s=${s# }; done
  FM_NORM=$s
}

fm_args_program() {  # <command-line> -> FM_NORM (normalized image leaf)
  local s=$1
  case "$s" in '<fail>'|'<missing>'|'<skipped>'|'') FM_NORM=$s; return 0 ;; esac
  case "$s" in
    '"'*) s=${s#\"}; s=${s%%\"*} ;;
    *' '*) s=${s%% *} ;;
  esac
  fm_norm_image "$s"
}

# The Windows pid for an MSYS pid. Cygwin `ps` prints a fixed column set whose
# 4th field is WINPID; the row is selected by an exact PID-column match so the
# header can never be read as data. Identity off Windows, where there is one
# pid space.
fm_winpid() {
  if [ "$IS_WINDOWS" != 1 ]; then printf '%s' "$1"; return 0; fi
  ps -p "$1" 2>/dev/null | awk -v p="$1" '$1 == p { print $4; exit }'
}

# --- the bash oracle, as comparable tokens ------------------------------------
#
# A primitive's value when it answered, and the literal <fail> when it returned
# non-zero. That distinction IS the bash contract ("empty output plus non-zero"
# versus "empty output plus zero"), so it is carried into the comparison rather
# than flattened to an empty string.
fm_bash_call() {  # <fn> <pid>
  local out rc
  out=$("$1" "$2" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { printf '<fail>'; return 0; }
  printf '%s' "$out"
}

fm_bash_alive() {  # <pid>
  if fm_proc_alive "$1" 2>/dev/null; then printf 'alive'; else printf 'dead'; fi
}

# Both halves of one fm_native_pid_info call, published through globals. The
# bash twin already publishes FM_NATIVE_PID_IMAGE and FM_NATIVE_PID_PATH
# precisely because a command substitution would run it in a subshell, and this
# reads them the same way its real callers do - which also halves the cost,
# since each call runs `ps -W` (2.2s under load here) and, for a pid it cannot
# find, `tasklist` (3.7s) as well.
FM_BN_IMAGE=
FM_BN_PATH=
fm_bash_native_pair() {  # <pid>
  FM_NATIVE_PID_IMAGE=; FM_NATIVE_PID_PATH=
  if fm_native_pid_info "$1" >/dev/null 2>&1; then
    FM_BN_IMAGE=$FM_NATIVE_PID_IMAGE
    FM_BN_PATH=$FM_NATIVE_PID_PATH
  else
    FM_BN_IMAGE='<fail>'
    FM_BN_PATH='<fail>'
  fi
}

# --- the PowerShell side, in ONE process --------------------------------------
#
# Batched deliberately: a pwsh start costs ~360ms on this Defender-protected
# host and every WMI query costs ~350ms more (~2.4s for the first in a process),
# so per-assertion invocations would dominate the run for no extra coverage.
#
# The cases arrive in a FILE rather than as arguments, and the module path is
# its first line. Two reasons, both learned here: PowerShell re-splits a `-File`
# script argument on spaces (a case value of "= 33976 " arrived as two arguments
# and the second had no '='), and a repo or temp path containing a space would
# break the same way. A file has neither hazard, and the one path still handed
# to pwsh is quoted inside -Command exactly as tests/fm-common-psm1.test.sh does.
#
# Every primitive runs inside a try/catch. The catch matters as much as the
# values: with $ErrorActionPreference = 'Stop', `Get-Process -Id` on a dead pid
# THROWS, so a module that forgot to pin -ErrorAction surfaces here as an .error
# record rather than as a silently wrong answer.
QUERY="$TMP_ROOT/query.ps1"
cat > "$QUERY" <<'PS1'
#Requires -Version 7.0
# Line 1 of -CaseFile is the module path; every later line is "<label>=<pid>",
# where the pid may be empty, non-numeric, or whitespace-padded on purpose.
param([Parameter(Mandatory)][string]$CaseFile)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = @([System.IO.File]::ReadAllLines($CaseFile))
$Module = $lines[0]
$Case = @($lines | Select-Object -Skip 1 | Where-Object { $_ -ne '' })

Import-Module $Module -Force

function Write-Record {
    param([Parameter(Mandatory)][string]$Key, [Parameter()]$Value)
    if ($null -eq $Value) { $Value = '' }
    # TAB is the field separator, so a value may never contain one. Nothing in
    # this repo's process fields does; stripping is a guard, not a fixup.
    $text = ([string]$Value) -replace "`t", ' '
    [Console]::Out.Write($Key + "`t" + $text + "`n")
}

# The command line is the one field that costs a WMI query, so it is asked for
# only where a case actually asserts on it. Cases that skip it record <skipped>
# rather than an empty value, so a later assertion can never read "not asked"
# as "answered with nothing".
$wantsCommandLine = @('msys', 'nativechild', 'claude')

foreach ($case in $Case) {
    $split = $case.IndexOf('=')
    $label = $case.Substring(0, $split)
    $id = $case.Substring($split + 1)

    $probes = [System.Collections.Generic.List[hashtable]]::new()
    $probes.Add(@{ Name = 'comm';   Script = { Get-FmProcCommand -ProcessId $id } })
    $probes.Add(@{ Name = 'parent'; Script = { Get-FmProcParentId -ProcessId $id } })
    $probes.Add(@{ Name = 'pgid';   Script = { Get-FmProcGroupId -ProcessId $id } })
    $probes.Add(@{ Name = 'image';  Script = { $i = Get-FmNativeProcessInfo -ProcessId $id; if ($i) { $i.Image } else { $null } } })
    $probes.Add(@{ Name = 'path';   Script = { $i = Get-FmNativeProcessInfo -ProcessId $id; if ($i) { $i.Path } else { $null } } })
    $probes.Add(@{ Name = 'alive';  Script = { if (Test-FmProcAlive -ProcessId $id) { 'alive' } else { 'dead' } } })
    if ($wantsCommandLine -contains $label) {
        $probes.Add(@{ Name = 'cmdline'; Script = { Get-FmProcCommandLine -ProcessId $id } })
    } else {
        Write-Record -Key "$label.cmdline" -Value '<skipped>'
    }

    foreach ($probe in $probes) {
        try {
            Write-Record -Key "$label.$($probe.Name)" -Value (& $probe.Script)
        } catch {
            Write-Record -Key "$label.$($probe.Name)" -Value '<threw>'
            Write-Record -Key "$label.error" -Value $_.Exception.Message
        }
    }
}
PS1
QUERY_N=$(fm_test_native_path "$QUERY")
CASES="$TMP_ROOT/cases.txt"
CASES_N=$(fm_test_native_path "$CASES")

# --- fixtures -----------------------------------------------------------------
#
# Every background fixture detaches its OUTPUT streams. A child that inherits
# this script's stdout holds that pipe open for its whole lifetime, so a harness
# capturing the suite's output blocks until the fixture exits rather than when
# the suite finishes - observed here as a 45-second "hang" on a run that had
# already completed.

# 1. An MSYS process, visible to both worlds through the WINPID bridge.
sleep 180 >/dev/null 2>&1 &
FIXTURE_MSYS_JOB=$!
MSYS_PID=$FIXTURE_MSYS_JOB
sleep 0.3
MSYS_WINPID=$(fm_winpid "$MSYS_PID")
[ -n "$MSYS_WINPID" ] || fail "could not resolve the Windows pid of the MSYS fixture ($MSYS_PID)"

# 2. A pid that CANNOT name a process. 999983 is not a multiple of 4, and the
#    NT kernel allocates process ids out of a handle table in steps of 4, so no
#    Windows process ever carries it.
#
#    An earlier draft used a stronger-looking negative instead: a real fixture
#    killed and reaped moments before. It was WRONG here, and the way it failed
#    is worth keeping in view. Windows recycles pids aggressively, this host
#    churns hundreds of processes, and a differential run takes minutes under
#    load - so between the bash snapshot and the PowerShell snapshot the kernel
#    handed the number to a new bash.exe, and the suite reported the module as
#    broken for correctly saying "alive". A negative that can turn positive
#    mid-run is not a negative.
NEVER_PID=999983

# 3. A NATIVE Windows process (pwsh) that itself starts a native child with a
#    parent and an argument this test CHOSE. That is the ground truth bash
#    cannot supply: about a native process it sees no argv, no parent, and no
#    /proc entry at all. Both stay alive while the assertions run, and the
#    child's own output is redirected inside PowerShell so `ping` never writes
#    into a pipe this script's parent is waiting on.
if [ "$IS_WINDOWS" = 1 ]; then
  NATIVE_MARKER='127.0.0.77'
  PIDFILE="$TMP_ROOT/native.pid"
  PIDFILE_N=$(fm_test_native_path "$PIDFILE")
  pwsh -NoProfile -Command "
    \$psi = [System.Diagnostics.ProcessStartInfo]::new()
    \$psi.FileName = 'cmd.exe'
    \$psi.Arguments = '/c ping -n 180 $NATIVE_MARKER > NUL'
    \$psi.UseShellExecute = \$false
    \$psi.RedirectStandardOutput = \$true
    \$psi.RedirectStandardError = \$true
    \$psi.CreateNoWindow = \$true
    \$child = [System.Diagnostics.Process]::Start(\$psi)
    Set-Content -LiteralPath '$PIDFILE_N' -Value \"parent=\$PID\"
    Add-Content -LiteralPath '$PIDFILE_N' -Value \"child=\$(\$child.Id)\"
    Start-Sleep -Seconds 180
  " >/dev/null 2>&1 </dev/null &
  FIXTURE_NATIVE_JOB=$!
  for _ in $(seq 1 60); do
    grep -q '^child=' "$PIDFILE" 2>/dev/null && break
    sleep 0.25
  done
  # Set-Content writes CRLF on Windows; the CR would poison every later pid
  # comparison, so it is stripped at the boundary rather than everywhere after.
  FIXTURE_NATIVE_PARENT=$(sed -n 's/^parent=//p' "$PIDFILE" 2>/dev/null | tr -d '\r')
  FIXTURE_NATIVE_CHILD=$(sed -n 's/^child=//p' "$PIDFILE" 2>/dev/null | tr -d '\r')
  [ -n "$FIXTURE_NATIVE_PARENT" ] && [ -n "$FIXTURE_NATIVE_CHILD" ] ||
    fail "native fixture did not report its pids"
fi

# 4. CLAUDE_PID, when the harness exported one. This is the load-bearing case
#    bin/fm-session-lock-lib.sh depends on: on Windows the harness is a native
#    Windows process, a bash under it reports PPID=1, and identity resolution
#    falls back to this pid (the session lock acquires against it in
#    production). Guarded because only Claude Code publishes it.
CLAUDE_CASE=
case "${CLAUDE_PID:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$IS_WINDOWS" = 1 ] && CLAUDE_CASE=$CLAUDE_PID ;;
esac

# --- snapshot 1: the bash oracle ----------------------------------------------
#
# Deliberately lean. Each bash primitive costs one to three PROCESS SPAWNS, and
# a spawn here is expensive enough to change the design: measured on this host
# under load, `ps -W` takes 2.2s, `tasklist` 3.7s, and fm_proc_comm on a pid
# that does not exist 8.9s, because every miss walks the whole fallback chain.
# So each pid is probed with the fewest calls that still exercise the contract,
# and the counts below are a budget, not an accident.
B_MSYS_COMM=$(fm_bash_call fm_proc_comm "$MSYS_PID")
B_MSYS_ARGS=$(fm_bash_call fm_proc_args "$MSYS_PID")
B_MSYS_PGID=$(fm_bash_call fm_proc_pgid "$MSYS_PID")
B_MSYS_ALIVE=$(fm_bash_alive "$MSYS_PID")
fm_bash_native_pair "$MSYS_WINPID"
B_MSYS_IMAGE=$FM_BN_IMAGE
B_MSYS_PATH=$FM_BN_PATH

# One probe of the impossible pid, not two: fm_proc_alive and
# fm_native_pid_info both end in the same ps -W + tasklist walk for a pid that
# is not there (6s each here), and the aliveness differential is already carried
# by the two LIVE processes below.
fm_bash_native_pair "$NEVER_PID"
B_NEVER_IMAGE=$FM_BN_IMAGE

# The non-numeric guards cost nothing: fm_proc_alive applies _fm_psproc_numeric
# before it spawns anything, which is itself part of the contract under test.
B_ALPHA_ALIVE=$(fm_bash_alive abc)
B_EMPTY_ALIVE=$(fm_bash_alive '')
B_PADDED_ALIVE=$(fm_bash_alive " $MSYS_WINPID ")
B_NEG_ALIVE=$(fm_bash_alive -5)

B_NC_ARGS=''; B_NC_PPID=''; B_NC_COMM=''; B_NC_ALIVE=''
B_NC_IMAGE=''; B_NC_PATH=''; B_NP_IMAGE=''; B_NP_PATH=''
if [ "$IS_WINDOWS" = 1 ]; then
  B_NC_ARGS=$(fm_bash_call fm_proc_args "$FIXTURE_NATIVE_CHILD")
  B_NC_PPID=$(fm_bash_call fm_proc_ppid "$FIXTURE_NATIVE_CHILD")
  B_NC_COMM=$(fm_bash_call fm_proc_comm "$FIXTURE_NATIVE_CHILD")
  B_NC_ALIVE=$(fm_bash_alive "$FIXTURE_NATIVE_CHILD")
  fm_bash_native_pair "$FIXTURE_NATIVE_CHILD"
  B_NC_IMAGE=$FM_BN_IMAGE
  B_NC_PATH=$FM_BN_PATH
  fm_bash_native_pair "$FIXTURE_NATIVE_PARENT"
  B_NP_IMAGE=$FM_BN_IMAGE
  B_NP_PATH=$FM_BN_PATH
fi

B_CL_IMAGE=''; B_CL_PATH=''; B_CL_ALIVE=''; B_CL_ARGS=''; B_CL_PPID=''
if [ -n "$CLAUDE_CASE" ]; then
  fm_bash_native_pair "$CLAUDE_CASE"
  B_CL_IMAGE=$FM_BN_IMAGE
  B_CL_PATH=$FM_BN_PATH
  B_CL_ALIVE=$(fm_bash_alive "$CLAUDE_CASE")
  B_CL_ARGS=$(fm_bash_call fm_proc_args "$CLAUDE_CASE")
  B_CL_PPID=$(fm_bash_call fm_proc_ppid "$CLAUDE_CASE")
fi

# --- snapshot 2: the PowerShell module ----------------------------------------

{
  printf '%s\n' "$MOD"
  printf 'msys=%s\n' "$MSYS_WINPID"
  printf 'never=%s\n' "$NEVER_PID"
  printf 'alpha=abc\n'
  printf 'empty=\n'
  printf 'padded= %s \n' "$MSYS_WINPID"
  printf 'negative=-5\n'
  if [ "$IS_WINDOWS" = 1 ]; then
    printf 'nativeparent=%s\n' "$FIXTURE_NATIVE_PARENT"
    printf 'nativechild=%s\n' "$FIXTURE_NATIVE_CHILD"
  fi
  [ -n "$CLAUDE_CASE" ] && printf 'claude=%s\n' "$CLAUDE_CASE"
} > "$CASES"

PS_OUT=$(pwsh -NoProfile -Command "& '$QUERY_N' -CaseFile '$CASES_N'" 2>&1) ||
  fail "the PowerShell query script failed:"$'\n'"$PS_OUT"

PS_LINES=()
while IFS= read -r ps_line; do
  [ -n "$ps_line" ] && PS_LINES+=("$ps_line")
done <<PSOUT
$PS_OUT
PSOUT

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

# --- 0. no primitive may throw ------------------------------------------------
#
# One .error record means an exception escaped a primitive - the exact failure
# $ErrorActionPreference = 'Stop' makes the DEFAULT for Get-Process on a dead
# pid, and the reason the module pins -ErrorAction on every probe.
ps_errors=''
for ps_line in ${PS_LINES+"${PS_LINES[@]}"}; do
  case "$ps_line" in
    *.error$'\t'*) ps_errors="$ps_errors ${ps_line%%$'\t'*}" ;;
  esac
done
assert_same "no primitive throws for any input" "" "${ps_errors# }"

# --- 1. an MSYS process: both worlds answer, so bash is the oracle -------------

fm_norm_image "$B_MSYS_COMM"; expected=$FM_NORM
psv msys.comm; fm_norm_image "$FM_PSV"
assert_same "comm: same program named for one MSYS process" "$expected" "$FM_NORM"

fm_args_tail "$B_MSYS_ARGS"; expected=$FM_NORM
psv msys.cmdline; fm_args_tail "$FM_PSV"
assert_same "args: same argument tail for one MSYS process" "$expected" "$FM_NORM"

fm_args_program "$B_MSYS_ARGS"; expected=$FM_NORM
psv msys.cmdline; fm_args_program "$FM_PSV"
assert_same "args: same program in argv[0] for one MSYS process" "$expected" "$FM_NORM"

psv msys.alive
assert_same "alive: a live MSYS process" "$B_MSYS_ALIVE" "$FM_PSV"

fm_norm_image "$B_MSYS_IMAGE"; expected=$FM_NORM
psv msys.image; fm_norm_image "$FM_PSV"
assert_same "native info: image of a live process" "$expected" "$FM_NORM"

fm_norm_path "$B_MSYS_PATH"; expected=$FM_NORM
psv msys.path; fm_norm_path "$FM_PSV"
assert_same "native info: path of a live process" "$expected" "$FM_NORM"

# --- 2. negatives: a reaped pid, an unused pid, and non-numeric input ----------

assert_same "native info: bash refuses a pid that cannot exist" "<fail>" "$B_NEVER_IMAGE"
psv never.image
assert_same "native info: PowerShell refuses it too" "" "$FM_PSV"
# Asserted against the contract rather than a second bash probe: fm_proc_alive
# and fm_proc_comm both walk the same ps -W + tasklist chain for a missing pid
# (6s and 8.9s here), and the aliveness differential is carried by the live
# processes above and below.
psv never.alive
assert_same "alive: a pid that cannot exist" "dead" "$FM_PSV"
psv never.comm
assert_same "comm: a pid that cannot exist" "" "$FM_PSV"
psv never.parent
assert_same "parent: a pid that cannot exist" "" "$FM_PSV"

# The _fm_psproc_numeric contract: '', non-digits, a signed value, and a
# whitespace-padded value are all refusals, never errors. Whitespace matters
# because callers read these pids out of record files.
psv alpha.comm
assert_same "guard: non-numeric pid is a refusal, not a throw" "" "$FM_PSV"
psv alpha.alive
assert_same "guard: non-numeric pid is not alive" "$B_ALPHA_ALIVE" "$FM_PSV"
psv empty.comm
assert_same "guard: empty pid is a refusal" "" "$FM_PSV"
psv empty.alive
assert_same "guard: empty pid is not alive" "$B_EMPTY_ALIVE" "$FM_PSV"
psv padded.alive
assert_same "guard: whitespace-padded pid is refused as bash refuses it" "$B_PADDED_ALIVE" "$FM_PSV"
psv negative.alive
assert_same "guard: signed pid is a refusal" "$B_NEG_ALIVE" "$FM_PSV"

# --- 3. process groups: the one primitive Windows cannot answer ----------------
#
# Windows has no POSIX process groups. The nearest concept - the console group a
# child joins under CREATE_NEW_PROCESS_GROUP - is exposed by no query API, and a
# job object has different membership rules, so any value here would be
# invented. bin/fm-watch.sh already degrades on an empty result ("skips the
# group-mismatch abort rather than inventing one"), while a fabricated value
# would NOT match the expected group and would abort a healthy check. Asserted
# in both directions so a later "improvement" that starts returning something
# fails loudly.
if [ "$IS_WINDOWS" = 1 ]; then
  case "$B_MSYS_PGID" in
    ''|*[!0-9]*) pgid_shape="other: $B_MSYS_PGID" ;;
    *) pgid_shape=numeric ;;
  esac
  assert_same "pgid: bash answers on this platform, so the divergence is real" \
    "numeric" "$pgid_shape"
  psv msys.pgid
  assert_same "pgid: PowerShell declines rather than inventing a group" "" "$FM_PSV"
else
  psv msys.pgid
  assert_same "pgid: same process group off Windows" "$B_MSYS_PGID" "$FM_PSV"
fi

# --- 4. native Windows processes: bash is NOT the oracle -----------------------
#
# Each pair asserts the bash refusal FIRST, because the refusal is what makes
# the PowerShell answer worth having. bin/fm-psproc-lib.sh's header states these
# limits outright ("a NATIVE Windows process has no /proc entry ... its argv is
# not observable from Git Bash at all"); this proves they still hold rather than
# trusting the comment.
if [ "$IS_WINDOWS" = 1 ]; then
  assert_same "args: bash cannot see a native process's arguments, so it is no oracle here" \
    "<fail>" "$B_NC_ARGS"
  # Ground truth: this test chose the argument, so its presence is checkable
  # without any second implementation.
  psv nativechild.cmdline
  case "$FM_PSV" in
    *"$NATIVE_MARKER"*) marker_seen=found ;;
    *) marker_seen="missing from: $FM_PSV" ;;
  esac
  assert_same "args: PowerShell returns the argument this test passed" "found" "$marker_seen"

  assert_same "parent: bash cannot see a native process's parent (severed chain)" \
    "<fail>" "$B_NC_PPID"
  # Ground truth: the pwsh that reported this pid is the process that started
  # it, so the correct parent is known exactly - not merely "some number".
  psv nativechild.parent
  assert_same "parent: PowerShell names the process that actually spawned it" \
    "$FIXTURE_NATIVE_PARENT" "$FM_PSV"

  assert_same "comm: bash cannot see a native process's image through /proc or ps -p" \
    "<fail>" "$B_NC_COMM"
  psv nativechild.comm; fm_norm_image "$FM_PSV"
  assert_same "comm: PowerShell names the native image this test launched" "cmd" "$FM_NORM"

  # The one native question bash CAN answer, through `ps -W` WINPID matching and
  # a tasklist fallback - so these stay differential, and they cover both
  # spellings `ps -W` produces (a posixified path for pwsh, a Windows path for
  # cmd).
  fm_norm_image "$B_NC_IMAGE"; expected=$FM_NORM
  psv nativechild.image; fm_norm_image "$FM_PSV"
  assert_same "native info: image agrees for a native child process" "$expected" "$FM_NORM"

  fm_norm_path "$B_NC_PATH"; expected=$FM_NORM
  psv nativechild.path; fm_norm_path "$FM_PSV"
  assert_same "native info: path agrees for a native child process" "$expected" "$FM_NORM"

  fm_norm_image "$B_NP_IMAGE"; expected=$FM_NORM
  psv nativeparent.image; fm_norm_image "$FM_PSV"
  assert_same "native info: image agrees for a native parent process" "$expected" "$FM_NORM"

  fm_norm_path "$B_NP_PATH"; expected=$FM_NORM
  psv nativeparent.path; fm_norm_path "$FM_PSV"
  assert_same "native info: path agrees for a native parent process" "$expected" "$FM_NORM"

  psv nativechild.alive
  assert_same "alive: a live native process" "$B_NC_ALIVE" "$FM_PSV"
fi

# --- 5. CLAUDE_PID: the identity fallback the session lock depends on ----------

if [ -n "$CLAUDE_CASE" ]; then
  fm_norm_image "$B_CL_IMAGE"; expected=$FM_NORM
  psv claude.image; fm_norm_image "$FM_PSV"
  assert_same "CLAUDE_PID: image agrees with the bash resolver" "$expected" "$FM_NORM"

  fm_norm_path "$B_CL_PATH"; expected=$FM_NORM
  psv claude.path; fm_norm_path "$FM_PSV"
  assert_same "CLAUDE_PID: path agrees with the bash resolver" "$expected" "$FM_NORM"

  psv claude.alive
  assert_same "CLAUDE_PID: alive agrees with the bash resolver" "$B_CL_ALIVE" "$FM_PSV"

  # The harness process is exactly the case the bash lib was written around: it
  # is reachable only as a native pid, so its arguments and parent are
  # unreadable from Git Bash while PowerShell answers both.
  assert_same "CLAUDE_PID: bash cannot read the harness command line" "<fail>" "$B_CL_ARGS"
  psv claude.cmdline
  case "$FM_PSV" in
    ''|'<missing>'|'<skipped>'|'<threw>') cl_cmdline=missing ;;
    *) cl_cmdline=found ;;
  esac
  assert_same "CLAUDE_PID: PowerShell reads the harness command line" "found" "$cl_cmdline"

  assert_same "CLAUDE_PID: bash cannot read the harness parent" "<fail>" "$B_CL_PPID"
  psv claude.parent
  case "$FM_PSV" in
    ''|0|1|*[!0-9]*) cl_parent="not-positive: $FM_PSV" ;;
    *) cl_parent=positive ;;
  esac
  assert_same "CLAUDE_PID: PowerShell repairs the severed ancestry chain" "positive" "$cl_parent"
fi

# --- 6. module hygiene --------------------------------------------------------

import_noise=$(pwsh -NoProfile -Command "Import-Module '$MOD' -Force" 2>&1)
assert_same "importing the module emits nothing" "" "$import_noise"

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-psproc-lib.psm1 differs from its contract (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The expected total is built from the fixtures that
# were actually available, which means a fixture that failed to materialize
# cannot quietly shrink the run into a green one.
# 20 unconditional, +12 on Windows (the native-process section plus the second
# process-group case), +7 when the harness published a CLAUDE_PID. These are
# EXACT totals rather than loose floors, so dropping a single case fails the
# run instead of quietly shrinking it.
MIN_ASSERTIONS=20
[ "$IS_WINDOWS" = 1 ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 12))
[ -n "$CLAUDE_CASE" ] && MIN_ASSERTIONS=$((MIN_ASSERTIONS + 7))
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-psproc-lib.psm1 holds its contract across %d assertions\n' "$ASSERTIONS"
printf '# fm-psproc-lib-psm1.test.sh: all assertions passed\n'
