#!/usr/bin/env bash
# Behavior test for bin/fm-pr-lib.psm1 and bin/fm-check-lib.psm1 - the
# PowerShell twins of the merge-poll validation lib and the custom-check
# hash/trust binding.
#
# This is a DIFFERENTIAL test: every case drives the bash function and the
# PowerShell function with byte-identical input and asserts an identical
# result. BASH IS THE ORACLE - no verdict is hard-coded here, so a case can
# never quietly encode what the author believed instead of what the shipped
# lib does.
#
# WHY THESE TWO LIBS DESERVE A DIFFERENTIAL AND NOT A UNIT TEST. The watcher
# EXECUTES state/<id>.check.sh. These libs are what stands between "a file
# exists at that path" and "firstmate runs it": the private-artifact gates, the
# single-hard-link rule, the device binding, the registration hashes, the
# custom-check trust record - and, one layer up, the URL parser that decides
# whether a watch is armed at all and whether bin/fm-pr-merge.sh will treat a
# link as a mergeable GitHub pull request. A PowerShell twin that ACCEPTED
# something bash refuses would run an unvalidated file; one that REFUSED
# something bash accepts would silently stop polling a captain's merges while
# the bash tree kept saying everything was armed. Both worlds are live against
# one state directory during the transition, so the two must not drift.
#
# THE REFUSALS ARE THE POINT. The URL matrix below is the same adversarial
# corpus tests/fm-pr-check-security.test.sh drives through the bash parser -
# percent-encodings, embedded control bytes, homograph hosts, wrong schemes,
# userinfo, ports - plus cases that only a .NET regex could get wrong (a
# trailing newline, which `$` matches in .NET and POSIX ERE does not).
#
# TRANSPORT. Every value crosses the boundary HEX-ENCODED, and that is not
# decoration: the corpus deliberately contains ESC, CR, LF, DEL and 0x01 bytes,
# so any printable field separator would be forgeable by a fixture. Bytes are
# encoded under LC_ALL=C, so what the PowerShell side reconstructs is exactly
# the byte sequence bash held. Cases go over in ONE file and come back from ONE
# pwsh process, so a ~360ms spawn is paid twice rather than three hundred times
# while failures stay individually attributable.
#
# RUNTIME. The bash side dominates, and not by a little: every fm_pr_file_*
# call is `uname` plus `stat`, i.e. two MSYS forks, and a fork on this host was
# measured at ~1.6s while several agents were working in the tree (~0.1s on an
# idle machine). One fm_pr_poll_artifacts_valid call is ~65 forks - 1m43
# measured. So the case mix here is a BUDGET, not an accident: the fork-free
# surfaces (URL parsing, task IDs, and the three fixed-record parsers, which
# use only builtins) carry most of the assertions, the stat-backed gates carry
# a bounded matrix, and the full artifact validation is spent exactly three
# times. Expect a couple of minutes idle and up to ~15 under load; that is the
# oracle being slow, not the suite hanging.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7. No bash-4-only syntax.
#
# Every path handed to pwsh, INCLUDING the Import-Module paths, is converted
# with fm_test_native_path: PowerShell cannot resolve MSYS paths (.NET reads
# /tmp/x as C:\tmp\x - verified). Paths BELOW an already-converted root are
# derived from that converted prefix by parameter expansion rather than a
# second cygpath fork; it is the same conversion, paid once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

PR_PSM1="$ROOT/bin/fm-pr-lib.psm1"
CHECK_PSM1="$ROOT/bin/fm-check-lib.psm1"
COMMON_PSM1="$ROOT/bin/fm-common.psm1"
[ -f "$PR_PSM1" ] || fail "bin/fm-pr-lib.psm1 is missing"
[ -f "$CHECK_PSM1" ] || fail "bin/fm-check-lib.psm1 is missing"
[ -f "$COMMON_PSM1" ] || fail "bin/fm-common.psm1 is missing (both modules build on it)"

# The oracles. fm-check-lib.sh is sourced AFTER fm-pr-lib.sh on purpose: it
# calls five fm_pr_* functions it never sources, which is the undeclared
# dependency the PowerShell package exists to make explicit.
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-libs-psm1)
TMP_ROOT_N=$(fm_test_native_path "$TMP_ROOT")
PR_PSM1_N=$(fm_test_native_path "$PR_PSM1")
CHECK_PSM1_N=$(fm_test_native_path "$CHECK_PSM1")
COMMON_PSM1_N=$(fm_test_native_path "$COMMON_PSM1")

# nat <path under TMP_ROOT> -> the Windows spelling, from the converted root.
FM_NAT=
nat() {
  local rel=${1#"$TMP_ROOT"}
  FM_NAT="$TMP_ROOT_N${rel//\//\\}"
}

# --- assertion bookkeeping ---------------------------------------------------
#
# Plain shell variables, and every case is recorded from PARENT scope. Nothing
# below runs inside a `( ... )` subshell: a subshell cannot report a failure
# back to the parent's counters, so a scheme that can LOSE a failure is worse
# than none - the suite would certify work it never checked. The assertion
# COUNT is itself asserted at the end for the same reason.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# assert_case <label> <expected(bash oracle)> <actual(powershell)>
assert_case() {
  local label=$1 expected=$2 actual=$3
  ASSERTIONS=$((ASSERTIONS + 1))
  if [ "$expected" != "$actual" ]; then
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): $(printf '%q' "$expected")
  actual(pwsh)  : $(printf '%q' "$actual")
"
  fi
}

# --- hex transport -----------------------------------------------------------
#
# LC_ALL=C makes ${v:i:1} a BYTE rather than a character, so what crosses is the
# exact byte sequence bash held - which is what the parsers under test consume.
# %04x then the low two digits, because bash renders a byte >= 0x80 as a
# sign-extended 64-bit value.
FM_HEX=
hex_encode() {
  local LC_ALL=C v=$1 i n c h out=''
  n=${#v}
  for (( i = 0; i < n; i++ )); do
    c=${v:i:1}
    printf -v h '%04x' "'$c"
    out="$out${h: -2}"
  done
  FM_HEX=$out
}

# Only ever used to render a failure, so it costs nothing on the passing path.
FM_UNHEX=
hex_decode() {
  local h=$1 c out=''
  while [ -n "$h" ]; do
    printf -v c '\x'"${h:0:2}"
    out="$out$c"
    h=${h:2}
  done
  FM_UNHEX=$out
}

# --- case batching -----------------------------------------------------------

CASES="$TMP_ROOT/cases.txt"
nat "$CASES"; CASES_N=$FM_NAT
RESULTS="$TMP_ROOT/results.txt"
DRIVER="$TMP_ROOT/driver.ps1"
nat "$DRIVER"; DRIVER_N=$FM_NAT
DRIVER_ERR="$TMP_ROOT/driver.err"

LABELS=()
EXPECT=()

# add_case <label> <expected-raw> <op> <arg>...
# The expectation is the bash oracle's own answer, already computed by the
# caller; args are hex-encoded here so no fixture byte can be mistaken for
# structure.
add_case() {
  local label=$1 expected=$2 op=$3 a record
  shift 3
  LABELS+=("$label")
  hex_encode "$expected"; EXPECT+=("$FM_HEX")
  record=$op
  for a in "$@"; do
    hex_encode "$a"
    record="$record|$FM_HEX"
  done
  printf '%s\n' "$record" >> "$CASES"
}

# --- bash oracle helpers (each publishes through a global: no subshell, no fork)

ORACLE=
oracle_bool() {  # <fn> <arg>...
  local fn=$1
  shift
  if "$fn" "$@" >/dev/null 2>&1; then ORACLE=ok; else ORACLE=no; fi
}

oracle_url() {
  if fm_pr_url_parse "$1" 2>/dev/null; then
    ORACLE="$FM_PR_PROVIDER|$FM_PR_URL|$FM_PR_HOST|$FM_PR_PATH|$FM_PR_OWNER|$FM_PR_REPO|$FM_PR_NUMBER"
  else
    ORACLE='<refused>'
  fi
}

oracle_value() {  # <fn> <arg>... : stdout when it succeeded, else <refused>
  local fn=$1 out rc
  shift
  out=$("$fn" "$@" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then ORACLE='<refused>'; else ORACLE=$out; fi
}

# The two path predicates the libs spell inline rather than as functions.
oracle_regular_file() {
  if [ -f "$1" ] && [ ! -L "$1" ]; then ORACLE=ok; else ORACLE=no; fi
}

oracle_regular_dir() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then ORACLE=ok; else ORACLE=no; fi
}

oracle_meta() {
  if fm_pr_metadata_identity_parse "$1" 2>/dev/null; then
    ORACLE="$FM_PR_META_PROVIDER|$FM_PR_META_URL|$FM_PR_META_HOST|$FM_PR_META_PATH|$FM_PR_META_NUMBER"
  else
    ORACLE='<refused>'
  fi
}

oracle_polldata() {
  if fm_pr_poll_data_parse "$1" 2>/dev/null; then
    ORACLE="$FM_PR_DATA_PROVIDER|$FM_PR_DATA_URL|$FM_PR_DATA_HOST|$FM_PR_DATA_PATH|$FM_PR_DATA_NUMBER"
  else
    ORACLE='<refused>'
  fi
}

oracle_registration() {
  if fm_pr_poll_registration_parse "$1" 2>/dev/null; then
    ORACLE="$FM_PR_REG_ID|$FM_PR_REG_PROVIDER|$FM_PR_REG_URL|$FM_PR_REG_HOST|$FM_PR_REG_PATH|$FM_PR_REG_NUMBER|$FM_PR_REG_DATA_HASH|$FM_PR_REG_TEMPLATE_HASH|$FM_PR_REG_DATA_IDENTITY|$FM_PR_REG_CHECK_IDENTITY"
  else
    ORACLE='<refused>'
  fi
}

oracle_retirement() {
  if fm_pr_poll_retirement_parse "$1" 2>/dev/null; then
    ORACLE="$FM_PR_RETIRE_ID|$FM_PR_RETIRE_PROVIDER|$FM_PR_RETIRE_URL|$FM_PR_RETIRE_HOST|$FM_PR_RETIRE_PATH|$FM_PR_RETIRE_NUMBER|$FM_PR_RETIRE_DATA_HASH|$FM_PR_RETIRE_TEMPLATE_HASH|$FM_PR_RETIRE_DATA_IDENTITY|$FM_PR_RETIRE_CHECK_IDENTITY|$FM_PR_RETIRE_REG_HASH|$FM_PR_RETIRE_REG_IDENTITY"
  else
    ORACLE='<refused>'
  fi
}

oracle_trust() {
  if fm_custom_check_trust_read "$1" "$2" 2>/dev/null; then
    ORACLE=$FM_CUSTOM_CHECK_HASH
  else
    ORACLE='<refused>'
  fi
}

# =============================================================================
# Fixtures
# =============================================================================

FIX="$TMP_ROOT/fix"
STATE="$TMP_ROOT/xw/state"          # cross-world: PowerShell publishes here
BSTATE="$TMP_ROOT/bw/state"         # bash hand-builds a valid artifact set here
CSTATE="$TMP_ROOT/ck/state"         # custom-check trust fixtures
RSTATE="$TMP_ROOT/rec/state"        # record-parser fixtures
mkdir -p "$FIX" "$STATE" "$BSTATE" "$CSTATE" "$RSTATE"

TEMPLATE="$ROOT/bin/fm-pr-poll.sh"
[ -f "$TEMPLATE" ] || fail "bin/fm-pr-poll.sh (the poll template) is missing"
cp "$TEMPLATE" "$FIX/template.sh"
TEMPLATE="$FIX/template.sh"
nat "$TEMPLATE"; TEMPLATE_N=$FM_NAT

# The mode matrix. Each of these was chosen because Git Bash derives its mode
# from a DIFFERENT Windows fact, and the PowerShell twin has to reproduce every
# one of them: content magic, extension, the read-only attribute, directory-ness.
printf 'x\n' > "$FIX/plain"
printf '#!/bin/sh\n' > "$FIX/shebang"
printf 'MZ\220\000' > "$FIX/mz.bin"
printf ':\n' > "$FIX/colon-lf"
: > "$FIX/empty"
printf 'x\n' > "$FIX/prog.exe"
printf 'x\n' > "$FIX/prog.bat"
printf 'x\n' > "$FIX/readonly"; chmod 0444 "$FIX/readonly"
printf '#!/bin/sh\n' > "$FIX/readonly-exec"; chmod 0444 "$FIX/readonly-exec"
mkdir -p "$FIX/adir"
printf 'x\n' > "$FIX/linked"; ln "$FIX/linked" "$FIX/linked.alias"

# =============================================================================
# The PowerShell driver
# =============================================================================
# Quoted here-doc: bash expands nothing, so the PowerShell source is byte-exact.
# Paths arrive through the environment rather than through interpolation, which
# keeps every quoting hazard out of the file.
cat > "$DRIVER" <<'PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_PR_PSM1 -Force
Import-Module $env:FM_CHECK_PSM1 -Force

function ConvertFrom-FmHex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Hex)
    if ($Hex -eq '') { return '' }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [System.Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function ConvertTo-FmHex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [System.Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Get-Bool {
    param([Parameter(Mandatory)][bool]$Value)
    if ($Value) { return 'ok' }
    return 'no'
}

# A refusal is the literal <refused>, never an empty string: the bash contract
# distinguishes "answered with nothing" from "returned non-zero", and flattening
# the two would let a broken twin pass by staying silent.
function Get-Or {
    param([AllowNull()][AllowEmptyString()]$Value)
    if ($null -eq $Value) { return '<refused>' }
    return [string]$Value
}

$out = [System.Text.StringBuilder]::new()
$index = -1
foreach ($line in [System.IO.File]::ReadAllLines($env:FM_CASES)) {
    if ($line -eq '') { continue }
    $index++
    $f = $line.Split('|')
    $op = $f[0]
    $result = ''
    # Argument decoding lives INSIDE the try with the call it feeds: outside it,
    # $ErrorActionPreference = 'Stop' turns one malformed case into a dead run
    # that emits no records at all, so every other case would be lost with it
    # and the failure would be attributable to nothing.
    try {
        $a = @()
        for ($i = 1; $i -lt $f.Length; $i++) { $a += (ConvertFrom-FmHex -Hex $f[$i]) }
        switch ($op) {
            'url' {
                $id = Get-FmPrUrlIdentity -Url $a[0]
                if ($null -eq $id) {
                    $result = '<refused>'
                } else {
                    $result = @($id.Provider, $id.Url, $id.Host, $id.Path, $id.Owner, $id.Repo, $id.Number) -join '|'
                }
            }
            'idsafe'   { $result = Get-Bool -Value (Test-FmTaskIdPathSafe -Id $a[0]) }
            'idvalid'  { $result = Get-Bool -Value (Test-FmPrTaskId -Id $a[0]) }
            'idcreate' { $result = Get-Bool -Value (Test-FmTaskIdCreationValid -Id $a[0]) }
            'head'     { $result = Get-Bool -Value (Test-FmPrHead -Head $a[0]) }
            'glhost'   { $result = Get-Bool -Value (Test-FmPrGitlabHost -HostName $a[0]) }
            'glpath'   { $result = Get-Bool -Value (Test-FmPrGitlabPath -ProjectPath $a[0]) }
            'mode'     { $result = Get-Or -Value (Get-FmPrFileMode -Path $a[0]) }
            'device'   { $result = Get-Or -Value (Get-FmPrFileDevice -Path $a[0]) }
            'inode'    { $result = Get-Or -Value (Get-FmPrFileInode -Path $a[0]) }
            'links'    { $result = Get-Or -Value (Get-FmPrFileLinkCount -Path $a[0]) }
            'identity' { $result = Get-Or -Value (Get-FmPrFileIdentity -Path $a[0]) }
            'sha'      { $result = Get-FmPrSha256 -Path $a[0] }
            'private'  { $result = Get-Bool -Value (Test-FmPrPrivateFile -Path $a[0] -Mode $a[1] -Device $a[2]) }
            'inert'    { $result = Get-Bool -Value (Test-FmPrModeEnforcementInert -Directory $a[0]) }
            'dest'     { $result = Get-Bool -Value (Test-FmPrRegularDestination -Path $a[0]) }
            'destdev'  { $result = Get-Bool -Value (Test-FmPrRegularDestinationOnDevice -Path $a[0] -Device $a[1]) }
            'regfile'  { $result = Get-Bool -Value (Test-FmPrRegularFile -Path $a[0]) }
            'regdir'   { $result = Get-Bool -Value (Test-FmPrRegularDirectory -Path $a[0]) }
            'meta' {
                $m = Get-FmPrMetadataIdentity -Path $a[0]
                if ($null -eq $m) {
                    $result = '<refused>'
                } else {
                    $result = @($m.Provider, $m.Url, $m.Host, $m.Path, $m.Number) -join '|'
                }
            }
            'polldata' {
                $d = Get-FmPrPollData -Path $a[0]
                if ($null -eq $d) {
                    $result = '<refused>'
                } else {
                    $result = @($d.Provider, $d.Url, $d.Host, $d.Path, $d.Number) -join '|'
                }
            }
            'reg' {
                $r = Get-FmPrPollRegistration -Path $a[0]
                if ($null -eq $r) {
                    $result = '<refused>'
                } else {
                    $result = @($r.Id, $r.Provider, $r.Url, $r.Host, $r.Path, $r.Number,
                        $r.DataHash, $r.TemplateHash, $r.DataIdentity, $r.CheckIdentity) -join '|'
                }
            }
            'retire' {
                $r = Get-FmPrPollRetirement -Path $a[0]
                if ($null -eq $r) {
                    $result = '<refused>'
                } else {
                    $result = @($r.Id, $r.Provider, $r.Url, $r.Host, $r.Path, $r.Number,
                        $r.DataHash, $r.TemplateHash, $r.DataIdentity, $r.CheckIdentity,
                        $r.RegHash, $r.RegIdentity) -join '|'
                }
            }
            'trust'      { $result = Get-Or -Value (Get-FmCustomCheckTrustHash -State $a[0] -Id $a[1]) }
            'registered' { $result = Get-Bool -Value (Test-FmCustomCheckRegistered -State $a[0] -Id $a[1]) }
            'snapprep' {
                $snapshot = New-FmCustomCheckSnapshot -State $a[0] -Id $a[1]
                $result = Get-Bool -Value ($null -ne $snapshot)
                Remove-FmCustomCheckSnapshot
            }
            'artifacts'  { $result = Get-Bool -Value (Test-FmPrPollArtifacts -State $a[0] -Id $a[1] -Template $a[2]) }
            'recoverone' { $result = Get-Bool -Value (Restore-FmPrPollRetirementOne -State $a[0] -Id $a[1] -Template $a[2]) }
            'recoverall' { $result = Get-Bool -Value ((Restore-FmPrPollRetirementAll -State $a[0] -Template $a[1]).Ok) }
            default      { $result = "UNKNOWN-OP:$op" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    }
    [void]$out.Append($index).Append('|').Append((ConvertTo-FmHex -Text ([string]$result))).Append("`n")
}
[Console]::Out.Write($out.ToString())
PS1

export FM_PR_PSM1="$PR_PSM1_N" FM_CHECK_PSM1="$CHECK_PSM1_N" FM_CASES="$CASES_N"
: > "$CASES"

# =============================================================================
# 1. URL parsing - fork-free, and the largest security surface in the pair
# =============================================================================

# shellcheck disable=SC2016 # Literal rejected URL bytes are parser test data.
CANONICAL_URLS=(
  'https://github.com/a/b/pull/1'
  'https://github.com/my-org/repo/pull/42'
  'https://github.com/Owner/repo-name_with.parts/pull/123456'
  'https://github.com/a/.hidden/pull/7'
  'https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r/pull/1'
  'https://gitlab.com/group/project/-/merge_requests/1'
  'https://gitlab.com/group/sub/deep/project/-/merge_requests/42'
  'https://gitlab.example.co.uk/g/p/-/merge_requests/7'
  'https://code.internal/team/tools/ci-runner/-/merge_requests/123456'
)

# The adversarial corpus tests/fm-pr-check-security.test.sh drives through the
# bash parser, verbatim, plus four cases that only a .NET regex could get wrong.
# shellcheck disable=SC2016 # Literal rejected URL bytes are parser test data.
INVALID_URLS=(
  # The GitLab match is greedy to the LAST "/-/merge_requests/", so this one
  # captures "g/p/-/merge_requests/9" as the project path - where the reserved
  # "-" segment refuses it. That greediness is why an earlier separator cannot
  # be smuggled past the path validator.
  'https://gitlab.com/g/p/-/merge_requests/9/-/merge_requests/3'
  'https://gitlab.com/single/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/0'
  'https://gitlab.com/g/p/-/merge_requests/01'
  'https://GitLab.com/g/p/-/merge_requests/1'
  'https://gitlab.com:443/g/p/-/merge_requests/1'
  'https://user@gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1/'
  'https://gitlab.com/-/p/-/merge_requests/1'
  'https://gitlab.com/g/p.git/-/merge_requests/1'
  'https://gitlab.com/g/p.atom/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1?x=1'
  'https://gitlab.com/g/p/-/merge_requests/1#note'
  'https://gitlab.com/g/p/-/issues/1'
  'https://gitlab.com//p/-/merge_requests/1'
  'https://.gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com./g/p/-/merge_requests/1'
  'http://gitlab.com/g/p/-/merge_requests/1'
  'https://github.com/o/r/-/merge_requests/1'
  'https://github.com/o/r/pull/1/'
  ' https://github.com/o/r/pull/1'
  'https://github.com/o/r/pull/1 '
  'https://github.com/o /r/pull/1'
  'https://user@github.com/o/r/pull/1'
  'https://user:pass@github.com/o/r/pull/1'
  'https://github.com:443/o/r/pull/1'
  'https://github.com/o%2Fr/pull/1'
  'https://github.com/o/r%2Fz/pull/1'
  'https://github.com/o/r/pull/1%3Fq'
  'https://github.com/o/r/pull/1%23f'
  'https://github.com/o/r/pull/1%24x'
  'https://github.com/o/r/pull/1%28x%29'
  'https://github.com/o/r/pull/1%60x'
  'https://github.com/o/r/pull/1%0D'
  'https://github.com/o/r/pull/1%0A'
  'https://github.com/o/r/pull/1%252Fz'
  'https://github.com//r/pull/1'
  'https://github.com/o//pull/1'
  'https://github.com/o/r//1'
  'https://github.com/o/r/1'
  'https://github.com/o/r/pull/'
  'https://github.com/-owner/r/pull/1'
  'https://github.com/owner-/r/pull/1'
  'https://github.com/owner--name/r/pull/1'
  'https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r/pull/1'
  'https://github.com/o/./pull/1'
  'https://github.com/o/../pull/1'
  'https://github.com/o/r+z/pull/1'
  'https://github.com/o/r/pull/+1'
  'https://github.com/o/r/pull/0'
  'https://github.com/o/r/pull/-1'
  'https://github.com/o/r/pull/01'
  'https://github.com/o/r/pull/0x1'
  'https://github.com/o/r/pull/1e2'
  'https://github.com/o/r/pull/1.0'
  'https://github.com/o/r/issues/1'
  'https://github.com/o/r/x/pull/1'
  'https://github.com/o/r/pull/1/files'
  'https://github.com/o/r/pull/1?q=x'
  'https://github.com/o/r/pull/1#f'
  'https://github.com.evil/o/r/pull/1'
  'https://evilgithub.com/o/r/pull/1'
  'https://gıthub.com/o/r/pull/1'
  'https://xn--gthub-3va.com/o/r/pull/1'
  'http://github.com/o/r/pull/1'
  'ssh://github.com/o/r/pull/1'
  'git://github.com/o/r/pull/1'
  'file://github.com/o/r/pull/1'
  '//github.com/o/r/pull/1'
  'HTTPS://github.com/o/r/pull/1'
  'https://GitHub.com/o/r/pull/1'
  'https://github.com/o$/r/pull/1'
  'https://github.com/o(/r/pull/1'
  'https://github.com/o)/r/pull/1'
  'https://github.com/o`/r/pull/1'
  'https://github.com/o/r`/pull/1'
  'https://github.com/o/r/pull/1`'
  "https://github.com/o/'r'/pull/1"
  'https://github.com/o/"r"/pull/1'
  "https://github.com/o/r/pull/1'"
  'https://github.com/o/r/pull/1"'
  ''
)

# The control-byte and trailing-newline cases are appended through a SCALAR
# variable rather than written as $'...' literals inside the array above, and
# that is not style: on this host a $'...' literal inside a COMPOUND ARRAY
# ASSIGNMENT silently loses its CR. Measured on bash 5.2.37(1)-release / msys:
#   arr=( $'x\r' )        -> element length 1, the CR is gone
#   v=$'x\r'; arr=( "$v" ) -> element length 2, the CR survives
# A fixture that quietly loses its terminator stops testing anything - it
# becomes the plain, VALID URL - so these are built the way that keeps the byte.
# (tests/fm-pr-check-security.test.sh writes its own corpus the first way and
# is currently failing on this host for exactly that reason; see the report.)
url_add() {
  INVALID_URLS+=("$1")
}
url_add "$(printf 'https://github.com/o/r/pull/1\t')"
url_add "$(printf 'https://github.com/o/r/pull/1\001')"
url_add "$(printf 'https://github.com/o/r/pull/1\033')"
url_add "$(printf 'https://github.com/o/r/pull/1\177')"
CR=$'\r'
LF=$'\n'
url_add "https://github.com/o/r/pull/1$CR"
url_add "https://github.com/o/r/pull/1${CR}${LF}next"
url_add "https://github.com/o/r/pull/1${LF}next"
# The four .NET-specific hazards. A regex anchored with ^...$ instead of
# \A...\z accepts the first two, because .NET's `$` ALSO matches immediately
# before a final newline while POSIX ERE's means end of string and nothing else.
url_add "https://github.com/o/r/pull/1$LF"
url_add "https://gitlab.com/g/p/-/merge_requests/1$LF"
url_add "${LF}https://github.com/o/r/pull/1"
url_add "https://github.com/o/r/pull/1${LF}${LF}"

for u in "${CANONICAL_URLS[@]}"; do
  oracle_url "$u"
  add_case "url accepts: $u" "$ORACLE" url "$u"
done
url_index=0
for u in "${INVALID_URLS[@]}"; do
  oracle_url "$u"
  add_case "url refuses [#$url_index]: $(printf '%q' "$u")" "$ORACLE" url "$u"
  url_index=$((url_index + 1))
done

# =============================================================================
# 2. Task IDs and head revisions - fork-free
# =============================================================================

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
TASK_IDS=(
  'task-a' '-task' 'task-' 'task--a' 'Task-a' 'task_a' 'task.a' '_noncanonical'
  '' '.' '..' '.task' '../escape' 'a/b' 'task a' $'task\ta' $'task\na' 'task*'
  "task'a" 'task"a' 'task;a' 'task$a' 'task\a' 'täsk'
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
)
for id in "${TASK_IDS[@]}"; do
  oracle_bool fm_task_id_path_safe "$id"
  add_case "task id path-safe: $(printf '%q' "$id")" "$ORACLE" idsafe "$id"
  oracle_bool fm_pr_task_id_valid "$id"
  add_case "task id operational: $(printf '%q' "$id")" "$ORACLE" idvalid "$id"
  oracle_bool fm_task_id_creation_valid "$id"
  add_case "task id creation: $(printf '%q' "$id")" "$ORACLE" idcreate "$id"
done

HEADS=(
  '0123456789abcdef0123456789abcdef01234567'
  '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  '0123456789ABCDEF0123456789abcdef01234567'
  '0123456789abcdef0123456789abcdef0123456'
  '0123456789abcdef0123456789abcdef012345678'
  ''
  'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
  $'0123456789abcdef0123456789abcdef01234567\n'
  ' 0123456789abcdef0123456789abcdef01234567'
)
for h in "${HEADS[@]}"; do
  oracle_bool fm_pr_head_valid "$h"
  add_case "head revision: $(printf '%q' "$h")" "$ORACLE" head "$h"
done

GL_HOSTS=(
  'gitlab.com' 'code.internal' 'gitlab.example.co.uk' 'a' 'a-b.c'
  'github.com' 'GitLab.com' '.gitlab.com' 'gitlab.com.' 'git..lab.com'
  '-gitlab.com' 'gitlab-.com' 'gitlab.com:443' 'user@gitlab.com' ''
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com'
)
for h in "${GL_HOSTS[@]}"; do
  oracle_bool fm_pr_gitlab_host_valid "$h"
  add_case "gitlab host: $(printf '%q' "$h")" "$ORACLE" glhost "$h"
done

GL_PATHS=(
  'g/p' 'group/sub/deep/project' 'a/b.c' 'a/b_c-d' 'g' '' '/g/p' 'g/p/'
  'g//p' 'g/-/p' 'g/-x/p' 'g/p.git' 'g/p.atom' 'g/./p' 'g/../p' 'g/p+q'
  'a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t'
  'a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u'
)
for p in "${GL_PATHS[@]}"; do
  oracle_bool fm_pr_gitlab_path_valid "$p"
  add_case "gitlab path: $(printf '%q' "$p")" "$ORACLE" glpath "$p"
done

# =============================================================================
# 3. The fixed-record parsers - also fork-free, and where the bash `read`
#    failure modes live
# =============================================================================

REG_HASH_A='1111111111111111111111111111111111111111111111111111111111111111'
REG_HASH_B='2222222222222222222222222222222222222222222222222222222222222222'
REG_HASH_C='3333333333333333333333333333333333333333333333333333333333333333'
REG_ID_A='12:34'
REG_ID_B='56:78'
REG_ID_C='90:12'
GH_URL='https://github.com/o/r/pull/10'
GL_URL='https://gitlab.com/g/p/-/merge_requests/10'

# --- sidecars ---
printf 'github\n%s\ngithub.com\no/r\n10\n' "$GH_URL" > "$RSTATE/d-valid"
printf 'gitlab\n%s\ngitlab.com\ng/p\n10\n' "$GL_URL" > "$RSTATE/d-gitlab"
printf 'github\n%s\ngithub.com\no/r\n10' "$GH_URL" > "$RSTATE/d-untermlast"
printf 'github\n%s\ngithub.com\no/r\n10\nextra\n' "$GH_URL" > "$RSTATE/d-extraline"
printf 'github\n%s\ngithub.com\no/r\n10\nextra' "$GH_URL" > "$RSTATE/d-extrapartial"
printf 'github\n%s\ngithub.com\no/r\n10\n\n' "$GH_URL" > "$RSTATE/d-extrablank"
printf '%s\ngithub.com\no/r\n10\n' "$GH_URL" > "$RSTATE/d-legacy4"
printf 'gitlab\n%s\ngithub.com\no/r\n10\n' "$GH_URL" > "$RSTATE/d-provmismatch"
printf 'github\n%s\nevil.example\no/r\n10\n' "$GH_URL" > "$RSTATE/d-hostmismatch"
printf 'github\n%s\ngithub.com\no/other\n10\n' "$GH_URL" > "$RSTATE/d-pathmismatch"
printf 'github\n%s\ngithub.com\no/r\n11\n' "$GH_URL" > "$RSTATE/d-nummismatch"
printf 'github\r\n%s\r\ngithub.com\r\no/r\r\n10\r\n' "$GH_URL" > "$RSTATE/d-crlf"
printf 'github\nhttps://github.com/o/r/pull/1x\ngithub.com\no/r\n1\n' > "$RSTATE/d-badurl"
: > "$RSTATE/d-empty"
for f in d-valid d-gitlab d-untermlast d-extraline d-extrapartial d-extrablank \
         d-legacy4 d-provmismatch d-hostmismatch d-pathmismatch d-nummismatch \
         d-crlf d-badurl d-empty d-missing; do
  oracle_polldata "$RSTATE/$f"
  nat "$RSTATE/$f"
  add_case "sidecar parse: $f" "$ORACLE" polldata "$FM_NAT"
done

# --- registrations ---
reg_write() {  # <file> <version> <id> <provider> <url> <host> <path> <number> <dh> <th> <di> <ci>
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" > "$1"
}
reg_write "$RSTATE/r-valid" fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-v1" fm-pr-poll-registration-v1 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-badid" fm-pr-poll-registration-v2 ../escape github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-badurl" fm-pr-poll-registration-v2 task-a github 'https://github.com/o/r/pull/01' github.com o/r 1 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-provmismatch" fm-pr-poll-registration-v2 task-a gitlab "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-shorthash" fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 111 "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-uphash" fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-badident" fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" '12:x' "$REG_ID_B"
reg_write "$RSTATE/r-gitlab" fm-pr-poll-registration-v2 task-a gitlab "$GL_URL" gitlab.com g/p 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
reg_write "$RSTATE/r-extra" fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B"
printf 'trailing\n' >> "$RSTATE/r-extra"
# The last field carries no newline, so bash's `read` hits EOF before a
# delimiter and returns non-zero - which refuses the whole record.
printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  fm-pr-poll-registration-v2 task-a github "$GH_URL" github.com o/r 10 \
  "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" > "$RSTATE/r-unterm"
for f in r-valid r-v1 r-badid r-badurl r-provmismatch r-shorthash r-uphash \
         r-badident r-gitlab r-extra r-unterm r-missing; do
  oracle_registration "$RSTATE/$f"
  nat "$RSTATE/$f"
  add_case "registration parse: $f" "$ORACLE" reg "$FM_NAT"
done

# --- retirement receipts ---
ret_write() {  # <file> <version> <id> <provider> <url> <host> <path> <number> <dh> <th> <di> <ci> <rh> <ri> <result>
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" > "$1"
}
ret_write "$RSTATE/t-valid" fm-pr-poll-retirement-v1 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" "$REG_HASH_C" "$REG_ID_C" merged
ret_write "$RSTATE/t-closed" fm-pr-poll-retirement-v1 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" "$REG_HASH_C" "$REG_ID_C" closed
ret_write "$RSTATE/t-v2" fm-pr-poll-retirement-v2 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" "$REG_HASH_C" "$REG_ID_C" merged
ret_write "$RSTATE/t-badreghash" fm-pr-poll-retirement-v1 task-a github "$GH_URL" github.com o/r 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" nope "$REG_ID_C" merged
ret_write "$RSTATE/t-gitlab" fm-pr-poll-retirement-v1 task-a gitlab "$GL_URL" gitlab.com g/p 10 "$REG_HASH_A" "$REG_HASH_B" "$REG_ID_A" "$REG_ID_B" "$REG_HASH_C" "$REG_ID_C" merged
for f in t-valid t-closed t-v2 t-badreghash t-gitlab t-missing; do
  oracle_retirement "$RSTATE/$f"
  nat "$RSTATE/$f"
  add_case "retirement parse: $f" "$ORACLE" retire "$FM_NAT"
done

# --- task metadata (one stat fork per case for the link-count gate) ---
printf 'window=x\npr=%s\n' "$GH_URL" > "$RSTATE/m-valid"
printf 'window=x\npr=%s\n' "$GL_URL" > "$RSTATE/m-gitlab"
printf 'window=x\n' > "$RSTATE/m-nopr"
printf 'pr=%s\npr=%s\n' "$GH_URL" "$GH_URL" > "$RSTATE/m-twopr"
printf 'pr=https://github.com/o/r/pull/01\n' > "$RSTATE/m-badurl"
printf 'pr=%s\npr_head=0123456789abcdef0123456789abcdef01234567\n' "$GH_URL" > "$RSTATE/m-goodhead"
printf 'pr=%s\npr_head=zz\n' "$GH_URL" > "$RSTATE/m-badhead"
printf 'pr_head=zz\npr=%s\n' "$GH_URL" > "$RSTATE/m-headbefore"
printf 'pr=%s\nx_request=1\nx_followups=2\n' "$GH_URL" > "$RSTATE/m-xkeys"
printf 'pr=%s\nwindow=after\n' "$GH_URL" > "$RSTATE/m-keyafter"
printf 'pr=%s\n\n' "$GH_URL" > "$RSTATE/m-blankafter"
printf 'window=a\nkind=ship\npr=%s\n' "$GH_URL" > "$RSTATE/m-keysbefore"
printf 'window=x\npr=%s' "$GH_URL" > "$RSTATE/m-unterm"
printf 'window=x\r\npr=%s\r\n' "$GH_URL" > "$RSTATE/m-crlf"
for f in m-valid m-gitlab m-nopr m-twopr m-badurl m-goodhead m-badhead \
         m-headbefore m-xkeys m-keyafter m-blankafter m-keysbefore m-unterm \
         m-crlf m-missing; do
  oracle_meta "$RSTATE/$f"
  nat "$RSTATE/$f"
  add_case "metadata parse: $f" "$ORACLE" meta "$FM_NAT"
done

# =============================================================================
# 4. File facts - the device/inode/link-count identity and the mode emulation
# =============================================================================
#
# The identity is what binds an artifact across the publish rename and into the
# durable registration, so the two worlds have to produce the SAME numbers, not
# merely equivalent ones. On Windows they do: MSYS reports the NTFS volume
# serial as st_dev and the 64-bit file index as st_ino, which is exactly what
# GetFileInformationByHandle returns.
for f in plain shebang adir linked; do
  oracle_value fm_pr_file_device "$FIX/$f"
  nat "$FIX/$f"; p_n=$FM_NAT
  add_case "device number: $f" "$ORACLE" device "$p_n"
  oracle_value fm_pr_file_inode "$FIX/$f"
  add_case "inode number: $f" "$ORACLE" inode "$p_n"
  oracle_value fm_pr_file_link_count "$FIX/$f"
  add_case "hard-link count: $f" "$ORACLE" links "$p_n"
  oracle_value fm_pr_file_identity "$FIX/$f"
  add_case "device:inode identity: $f" "$ORACLE" identity "$p_n"
done
oracle_value fm_pr_file_identity "$FIX/missing"
nat "$FIX/missing"
add_case "device:inode identity: a path that does not exist" "$ORACLE" identity "$FM_NAT"

# The mode matrix. Each entry lands on a different arm of the rule Git Bash
# applies on a noacl mount, and the PowerShell twin reproduces that rule rather
# than reading a POSIX mode that does not exist on NTFS.
for f in plain shebang mz.bin colon-lf empty prog.exe prog.bat readonly \
         readonly-exec adir linked missing; do
  oracle_value fm_pr_file_mode "$FIX/$f"
  nat "$FIX/$f"
  add_case "file mode: $f" "$ORACLE" mode "$FM_NAT"
done

# sha256: the lowercase-hex contract, and the empty-output-on-failure shape a
# missing file produces (the bash pipeline exits with awk's status, not the
# hasher's, so callers see success plus an empty string).
for f in plain empty shebang missing; do
  oracle_value fm_pr_sha256 "$FIX/$f"
  nat "$FIX/$f"
  add_case "sha256: $f" "$ORACLE" sha "$FM_NAT"
done

# --- regular-file and regular-directory predicates ---
for f in plain adir missing; do
  oracle_regular_file "$FIX/$f"
  nat "$FIX/$f"; p_n=$FM_NAT
  add_case "ordinary file predicate: $f" "$ORACLE" regfile "$p_n"
  oracle_regular_dir "$FIX/$f"
  add_case "ordinary directory predicate: $f" "$ORACLE" regdir "$p_n"
done

# =============================================================================
# 5. The private-artifact gates (R6) - the inert-filesystem fallback in action
# =============================================================================
#
# On a Git Bash noacl mount chmod is accepted and provably changes nothing, so
# the bash twin substitutes an OWNERSHIP check for the mode-bit check. The
# PowerShell twin could enforce real NTFS ACLs and deliberately does not: it
# would refuse artifacts the bash path accepts while both worlds are live
# against the same state directory. These cases are the evidence that the two
# reach the same verdict, whichever arm the platform takes.
PSTATE="$TMP_ROOT/priv"
mkdir -p "$PSTATE"
printf 'private\n' > "$PSTATE/ok"; chmod 0600 "$PSTATE/ok"
printf 'private\n' > "$PSTATE/aliased"; chmod 0600 "$PSTATE/aliased"
ln "$PSTATE/aliased" "$PSTATE/aliased.elsewhere"
printf '#!/bin/sh\n' > "$PSTATE/exec"; chmod 0700 "$PSTATE/exec"
printf 'ro\n' > "$PSTATE/ro"; chmod 0400 "$PSTATE/ro"
mkdir -p "$PSTATE/adir"
PSTATE_DEVICE=$(fm_pr_file_device "$PSTATE")
[ -n "$PSTATE_DEVICE" ] || fail "could not read the fixture directory device number"
OTHER_DEVICE="${PSTATE_DEVICE}0"

nat "$PSTATE"; PSTATE_N=$FM_NAT
oracle_bool fm_pr_mode_enforcement_inert "$PSTATE"
add_case "inert-chmod probe: the fixture directory" "$ORACLE" inert "$PSTATE_N"
oracle_bool fm_pr_mode_enforcement_inert "$PSTATE/ok"
nat "$PSTATE/ok"
add_case "inert-chmod probe: a file is not a directory" "$ORACLE" inert "$FM_NAT"
oracle_bool fm_pr_mode_enforcement_inert "$PSTATE/nowhere"
nat "$PSTATE/nowhere"
add_case "inert-chmod probe: a missing directory" "$ORACLE" inert "$FM_NAT"

priv_case() {  # <label> <path> <mode> <device>
  local label=$1 path=$2 mode=$3 device=$4
  oracle_bool fm_pr_private_file_valid "$path" "$mode" "$device"
  nat "$path"
  add_case "private gate: $label" "$ORACLE" private "$FM_NAT" "$mode" "$device"
}
priv_case "a 0600 artifact on the state device" "$PSTATE/ok" 600 "$PSTATE_DEVICE"
priv_case "a 0700 artifact on the state device" "$PSTATE/exec" 700 "$PSTATE_DEVICE"
priv_case "the same artifact against a foreign device" "$PSTATE/ok" 600 "$OTHER_DEVICE"
priv_case "a hard-linked artifact is refused" "$PSTATE/aliased" 600 "$PSTATE_DEVICE"
priv_case "a directory is not a private file" "$PSTATE/adir" 600 "$PSTATE_DEVICE"
priv_case "a path that does not exist" "$PSTATE/nowhere" 600 "$PSTATE_DEVICE"
priv_case "a read-only artifact" "$PSTATE/ro" 600 "$PSTATE_DEVICE"
priv_case "an empty expected device" "$PSTATE/ok" 600 ''

dest_case() {  # <label> <path>
  local label=$1 path=$2
  oracle_bool fm_pr_regular_destination_or_absent "$path"
  nat "$path"; local p_n=$FM_NAT
  add_case "publish destination: $label" "$ORACLE" dest "$p_n"
  oracle_bool fm_pr_regular_destination_on_device_or_absent "$path" "$PSTATE_DEVICE"
  add_case "publish destination on device: $label" "$ORACLE" destdev "$p_n" "$PSTATE_DEVICE"
  oracle_bool fm_pr_regular_destination_on_device_or_absent "$path" "$OTHER_DEVICE"
  add_case "publish destination on a foreign device: $label" "$ORACLE" destdev "$p_n" "$OTHER_DEVICE"
}
dest_case "an ordinary existing file" "$PSTATE/ok"
dest_case "a hard-linked file" "$PSTATE/aliased"
dest_case "an absent path" "$PSTATE/nowhere"
dest_case "a directory" "$PSTATE/adir"

# =============================================================================
# 6. The custom-check trust binding (fm-check-lib)
# =============================================================================
#
# state/<id>.check-trust is the only authority for running a captain-authored
# check, so a tampered check, an aliased check and a malformed trust record must
# all read as "not registered" in both worlds.
mk_check() {  # <id> <content>
  printf '%s' "$2" > "$CSTATE/$1.check.sh"
  chmod 0700 "$CSTATE/$1.check.sh"
}
CHECK_BODY='#!/usr/bin/env bash
printf "custom-ready\n"
'
mk_check good "$CHECK_BODY"
GOOD_HASH=$(fm_custom_check_sha256 "$CSTATE/good.check.sh")
[ -n "$GOOD_HASH" ] || fail "could not hash the custom-check fixture"
printf 'fm-custom-check-v1\n%s\n' "$GOOD_HASH" > "$CSTATE/good.check-trust"
chmod 0600 "$CSTATE/good.check-trust"

mk_check tampered "$CHECK_BODY"
printf 'fm-custom-check-v1\n%s\n' "$GOOD_HASH" > "$CSTATE/tampered.check-trust"
chmod 0600 "$CSTATE/tampered.check-trust"
printf '# appended\n' >> "$CSTATE/tampered.check.sh"

mk_check aliased "$CHECK_BODY"
printf 'fm-custom-check-v1\n%s\n' "$GOOD_HASH" > "$CSTATE/aliased.check-trust"
chmod 0600 "$CSTATE/aliased.check-trust"
ln "$CSTATE/aliased.check.sh" "$CSTATE/aliased.elsewhere"

mk_check badversion "$CHECK_BODY"
printf 'fm-custom-check-v2\n%s\n' "$GOOD_HASH" > "$CSTATE/badversion.check-trust"
chmod 0600 "$CSTATE/badversion.check-trust"

mk_check threeline "$CHECK_BODY"
printf 'fm-custom-check-v1\n%s\nextra\n' "$GOOD_HASH" > "$CSTATE/threeline.check-trust"
chmod 0600 "$CSTATE/threeline.check-trust"

mk_check unterm "$CHECK_BODY"
printf 'fm-custom-check-v1\n%s' "$GOOD_HASH" > "$CSTATE/unterm.check-trust"
chmod 0600 "$CSTATE/unterm.check-trust"

mk_check notrust "$CHECK_BODY"

nat "$CSTATE"; CSTATE_N=$FM_NAT
for id in good tampered aliased badversion threeline unterm notrust ../escape; do
  oracle_trust "$CSTATE" "$id"
  add_case "custom check trust record: $id" "$ORACLE" trust "$CSTATE_N" "$id"
  oracle_bool fm_custom_check_registered "$CSTATE" "$id"
  add_case "custom check registered: $id" "$ORACLE" registered "$CSTATE_N" "$id"
done

# The snapshot gate compares the COPY's mode to 600 with NO inert fallback, so
# on a noacl mount it can never pass. That is a real degradation of the bash
# tree on Windows, and the twin reproduces it rather than repairing it - which
# is exactly what this differential is for.
for id in good notrust; do
  oracle_bool fm_custom_check_snapshot_prepare "$CSTATE" "$id"
  fm_custom_check_snapshot_cleanup
  add_case "custom check snapshot prepare: $id" "$ORACLE" snapprep "$CSTATE_N" "$id"
done

# =============================================================================
# 7. Cross-world artifacts: PowerShell publishes, bash validates, and back
# =============================================================================
#
# Contract 2 of docs/powershell-port.md: durable state written by bash must be
# readable by PowerShell and vice versa, so a captain's home survives cutover
# with no migration. For these libs that means a merge poll armed by one world
# has to validate in the other, hashes and device:inode identities included.
#
# These are the expensive cases - one fm_pr_poll_artifacts_valid is ~65 MSYS
# forks - so exactly three are spent: PowerShell-published and valid,
# PowerShell-published and byte-tampered, and bash-built and valid.
#
# The tampered poll gets its OWN state directory rather than being produced by
# mutating the good one. The PowerShell cases are all evaluated by a single
# driver at the END of this file, so a fixture that a later line mutates would
# be judged in its mutated form against an oracle taken before the mutation -
# a false failure, or worse, a false pass.
TSTATE="$TMP_ROOT/xt/state"
mkdir -p "$TSTATE"
nat "$STATE"; STATE_N=$FM_NAT
nat "$TSTATE"; TSTATE_N=$FM_NAT
XW_URL='https://github.com/o/r/pull/4242'
printf 'window=firstmate:fm-task-a\npr=%s\n' "$XW_URL" > "$STATE/task-a.meta"
printf 'window=firstmate:fm-task-a\npr=%s\n' "$XW_URL" > "$TSTATE/task-a.meta"

PUBLISH="$TMP_ROOT/publish.ps1"
nat "$PUBLISH"; PUBLISH_N=$FM_NAT
cat > "$PUBLISH" <<'PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $env:FM_PR_PSM1 -Force
$identity = Get-FmPrUrlIdentity -Url $env:FM_XW_URL
if ($null -eq $identity) { [Console]::Out.Write("parse-failed`n"); exit 1 }
foreach ($state in @($env:FM_XW_STATE, $env:FM_XW_TAMPER_STATE)) {
    $prepared = New-FmPrPollPreparation -State $state -Id 'task-a' `
        -Provider $identity.Provider -Url $identity.Url -ForgeHost $identity.Host `
        -ProjectPath $identity.Path -Number $identity.Number -Template $env:FM_XW_TEMPLATE
    if ($null -eq $prepared) { [Console]::Out.Write("prepare-failed`n"); exit 1 }
    if (-not (Publish-FmPrPollPreparation -Preparation $prepared)) {
        [Console]::Out.Write("publish-failed`n")
        exit 1
    }
}
[Console]::Out.Write("published`n")
PS1

PUBLISH_OUT=$(FM_XW_STATE="$STATE_N" FM_XW_TAMPER_STATE="$TSTATE_N" \
  FM_XW_TEMPLATE="$TEMPLATE_N" FM_XW_URL="$XW_URL" \
  pwsh -NoProfile -File "$PUBLISH_N" 2>&1)
assert_case "PowerShell arms a merge poll end to end" "published" "$PUBLISH_OUT"

oracle_bool fm_pr_poll_artifacts_valid "$STATE" task-a "$TEMPLATE"
assert_case "bash accepts the poll PowerShell published" "ok" "$ORACLE"
add_case "PowerShell accepts its own published poll" "$ORACLE" artifacts "$STATE_N" task-a "$TEMPLATE_N"

# The identity and hash fields PowerShell wrote have to be the ones bash reads
# back out of the very same file - this is where a "good enough" inode
# substitute would surface.
oracle_registration "$STATE/task-a.pr-poll-registration"
nat "$STATE/task-a.pr-poll-registration"
add_case "the published registration reads identically in both worlds" "$ORACLE" reg "$FM_NAT"
oracle_polldata "$STATE/task-a.pr-poll"
nat "$STATE/task-a.pr-poll"
add_case "the published sidecar reads identically in both worlds" "$ORACLE" polldata "$FM_NAT"
XW_DATA_IDENTITY=$(fm_pr_file_identity "$STATE/task-a.pr-poll")
fm_pr_poll_registration_parse "$STATE/task-a.pr-poll-registration" 2>/dev/null
assert_case "the recorded sidecar identity is the one bash stats on disk" \
  "$XW_DATA_IDENTITY" "$FM_PR_REG_DATA_IDENTITY"

# No receipt present is a clean success in both worlds, and a sweep of a
# receipt-free directory is too. Both are fork-free on the bash side.
oracle_bool fm_pr_poll_retirement_recover_one "$STATE" task-a "$TEMPLATE"
add_case "retirement recovery with nothing to finish" "$ORACLE" recoverone "$STATE_N" task-a "$TEMPLATE_N"
oracle_bool fm_pr_poll_retirement_recover_one "$STATE" '../escape' "$TEMPLATE"
add_case "retirement recovery refuses an unsafe task id" "$ORACLE" recoverone "$STATE_N" '../escape' "$TEMPLATE_N"
oracle_bool fm_pr_poll_retirement_recover_all "$STATE" "$TEMPLATE"
add_case "retirement sweep of a receipt-free directory" "$ORACLE" recoverall "$STATE_N" "$TEMPLATE_N"

# --- bash builds the artifact set, PowerShell reads it ---
cp "$TEMPLATE" "$BSTATE/task-b.check.sh"
chmod 0600 "$BSTATE/task-b.check.sh"
printf 'github\n%s\ngithub.com\no/r\n77\n' 'https://github.com/o/r/pull/77' > "$BSTATE/task-b.pr-poll"
chmod 0600 "$BSTATE/task-b.pr-poll"
printf 'window=firstmate:fm-task-b\npr=%s\n' 'https://github.com/o/r/pull/77' > "$BSTATE/task-b.meta"
B_DATA_HASH=$(fm_pr_sha256 "$BSTATE/task-b.pr-poll")
B_TEMPLATE_HASH=$(fm_pr_sha256 "$BSTATE/task-b.check.sh")
B_DATA_IDENTITY=$(fm_pr_file_identity "$BSTATE/task-b.pr-poll")
B_CHECK_IDENTITY=$(fm_pr_file_identity "$BSTATE/task-b.check.sh")
reg_write "$BSTATE/task-b.pr-poll-registration" fm-pr-poll-registration-v2 task-b github \
  'https://github.com/o/r/pull/77' github.com o/r 77 \
  "$B_DATA_HASH" "$B_TEMPLATE_HASH" "$B_DATA_IDENTITY" "$B_CHECK_IDENTITY"
chmod 0600 "$BSTATE/task-b.pr-poll-registration"
nat "$BSTATE"; BSTATE_N=$FM_NAT
oracle_bool fm_pr_poll_artifacts_valid "$BSTATE" task-b "$TEMPLATE"
assert_case "bash accepts the artifact set bash built" "ok" "$ORACLE"
add_case "PowerShell accepts the artifact set bash built" "$ORACLE" artifacts "$BSTATE_N" task-b "$TEMPLATE_N"

# --- the retirement receipt: PowerShell writes it, bash honours it ---
#
# state/<id>.pr-poll-retirement is the record that AUTHORISES deleting a merged
# poll's artifacts, and it is written by whichever world observed the merge and
# consumed by whichever world runs next. So the strongest statement available
# here is the split one: PowerShell captures the snapshot and publishes the
# receipt, and bash - with no knowledge that PowerShell was involved - validates
# it, parses it identically, and finishes the removal by exact identity.
RTSTATE="$TMP_ROOT/rt/state"
mkdir -p "$RTSTATE"
nat "$RTSTATE"; RTSTATE_N=$FM_NAT
printf 'window=firstmate:fm-task-a\npr=%s\n' "$XW_URL" > "$RTSTATE/task-a.meta"

RETIRE="$TMP_ROOT/retire.ps1"
nat "$RETIRE"; RETIRE_N=$FM_NAT
cat > "$RETIRE" <<'PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module $env:FM_PR_PSM1 -Force
$identity = Get-FmPrUrlIdentity -Url $env:FM_XW_URL
if ($null -eq $identity) { [Console]::Out.Write("parse-failed`n"); exit 1 }
$prepared = New-FmPrPollPreparation -State $env:FM_RT_STATE -Id 'task-a' `
    -Provider $identity.Provider -Url $identity.Url -ForgeHost $identity.Host `
    -ProjectPath $identity.Path -Number $identity.Number -Template $env:FM_XW_TEMPLATE
if ($null -eq $prepared) { [Console]::Out.Write("prepare-failed`n"); exit 1 }
if (-not (Publish-FmPrPollPreparation -Preparation $prepared)) {
    [Console]::Out.Write("publish-failed`n"); exit 1
}
$snapshot = Get-FmPrPollSnapshot -State $env:FM_RT_STATE -Id 'task-a' -Template $env:FM_XW_TEMPLATE
if ($null -eq $snapshot) { [Console]::Out.Write("snapshot-failed`n"); exit 1 }
if (-not (Test-FmPrPollSnapshotMatch -Snapshot $snapshot -State $env:FM_RT_STATE -Id 'task-a' `
            -Template $env:FM_XW_TEMPLATE)) {
    [Console]::Out.Write("snapshot-mismatch`n"); exit 1
}
# A result other than merged is the one a receipt may never carry.
if (Publish-FmPrPollRetirement -Snapshot $snapshot -State $env:FM_RT_STATE -Id 'task-a' `
        -Template $env:FM_XW_TEMPLATE -Result 'closed') {
    [Console]::Out.Write("closed-was-accepted`n"); exit 1
}
if (-not (Publish-FmPrPollRetirement -Snapshot $snapshot -State $env:FM_RT_STATE -Id 'task-a' `
            -Template $env:FM_XW_TEMPLATE -Result 'merged')) {
    [Console]::Out.Write("retire-failed`n"); exit 1
}
# A second receipt over the same artifacts would be a second authority.
if (Publish-FmPrPollRetirement -Snapshot $snapshot -State $env:FM_RT_STATE -Id 'task-a' `
        -Template $env:FM_XW_TEMPLATE -Result 'merged') {
    [Console]::Out.Write("second-receipt-was-accepted`n"); exit 1
}
[Console]::Out.Write("retired`n")
PS1

RETIRE_OUT=$(FM_RT_STATE="$RTSTATE_N" FM_XW_TEMPLATE="$TEMPLATE_N" FM_XW_URL="$XW_URL" \
  pwsh -NoProfile -File "$RETIRE_N" 2>&1)
assert_case "PowerShell snapshots a poll and publishes exactly one merged receipt" \
  "retired" "$RETIRE_OUT"

# Copied before the recovery below consumes the original, so the driver - which
# runs at the END of this file - still has a receipt to parse.
cp "$RTSTATE/task-a.pr-poll-retirement" "$RSTATE/t-fromps"
oracle_retirement "$RSTATE/t-fromps"
nat "$RSTATE/t-fromps"
add_case "the receipt PowerShell wrote parses identically in both worlds" "$ORACLE" retire "$FM_NAT"

oracle_bool fm_pr_poll_retirement_receipt_valid "$RTSTATE" task-a
assert_case "bash validates the retirement receipt PowerShell wrote" "ok" "$ORACLE"

oracle_bool fm_pr_poll_retirement_recover_one "$RTSTATE" task-a "$TEMPLATE"
assert_case "bash finishes the retirement PowerShell authorised" "ok" "$ORACLE"
for artifact in task-a.check.sh task-a.pr-poll task-a.pr-poll-registration task-a.pr-poll-retirement; do
  if [ -e "$RTSTATE/$artifact" ] || [ -L "$RTSTATE/$artifact" ]; then leftover=present; else leftover=absent; fi
  assert_case "retirement recovery removed $artifact" "absent" "$leftover"
done

# --- and the tamper both worlds must refuse ---
# One appended byte in the runnable check is the whole point of the template
# hash and the cmp: the watcher must not execute a file that is no longer the
# one that was registered.
printf '# tampered\n' >> "$TSTATE/task-a.check.sh"
oracle_bool fm_pr_poll_artifacts_valid "$TSTATE" task-a "$TEMPLATE"
assert_case "bash refuses a poll whose check bytes changed" "no" "$ORACLE"
add_case "PowerShell refuses a poll whose check bytes changed" "$ORACLE" artifacts "$TSTATE_N" task-a "$TEMPLATE_N"

# =============================================================================
# Run the PowerShell side - one process, every case
# =============================================================================

if ! pwsh -NoProfile -File "$DRIVER_N" > "$RESULTS" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero:"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A clean run is also a SILENT run: a module warning (an unapproved verb, a
# shadowed command) would surface here and must not be tolerated.
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr:"$'\n'"$(cat "$DRIVER_ERR")"

SEEN=0
while IFS='|' read -r idx got; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$idx" -lt "${#LABELS[@]}" ] || fail "driver returned an out-of-range case index: $idx"
  if [ "${EXPECT[$idx]}" != "$got" ]; then
    hex_decode "${EXPECT[$idx]}"; expected_raw=$FM_UNHEX
    hex_decode "$got"; actual_raw=$FM_UNHEX
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${LABELS[$idx]}
  expected(bash): $(printf '%q' "$expected_raw")
  actual(pwsh)  : $(printf '%q' "$actual_raw")
"
  else
    ASSERTIONS=$((ASSERTIONS + 1))
  fi
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] \
  || fail "driver returned $SEEN results for ${#LABELS[@]} cases"

# =============================================================================
# Import hygiene - what a batch driver cannot observe about itself
# =============================================================================

import_out=$(pwsh -NoProfile -Command \
  "Import-Module '$PR_PSM1_N' -Force; Import-Module '$CHECK_PSM1_N' -Force" 2>&1)
import_rc=$?
assert_case "importing both modules is silent" '' "$import_out"
assert_case "importing both modules succeeds" 0 "$import_rc"

# fm-check-lib.sh calls five fm_pr_* functions it never sources. A .psm1 cannot
# inherit its caller's imports, so this proves the PowerShell twin stands alone
# in a fresh session - the exact failure mode inventory R4 predicts, and one the
# existing bash tests cannot catch because their harness sources both files.
standalone_out=$(pwsh -NoProfile -Command \
  "Import-Module '$CHECK_PSM1_N' -Force; [Console]::Out.Write([string](Test-FmCustomCheckRegistered -State '$CSTATE_N' -Id 'good'))" 2>&1)
oracle_bool fm_custom_check_registered "$CSTATE" good
case $ORACLE in ok) standalone_expected=True ;; *) standalone_expected=False ;; esac
assert_case "fm-check-lib.psm1 works imported alone, with no caller-side imports" \
  "$standalone_expected" "$standalone_out"

coexist_out=$(pwsh -NoProfile -Command \
  "Import-Module '$COMMON_PSM1_N' -Force; Import-Module '$PR_PSM1_N' -Force; Import-Module '$CHECK_PSM1_N' -Force; [Console]::Out.Write([string][bool](Get-Command Write-FmOut -ErrorAction SilentlyContinue))" 2>&1)
assert_case "importing these modules leaves a caller's fm-common loaded" 'True' "$coexist_out"

# =============================================================================
# Report
# =============================================================================

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell PR libs differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. Dropping cases - by deleting them, or through a
# bookkeeping regression that stops recording them - fails loudly instead of
# certifying an empty run.
MIN_ASSERTIONS=365
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-pr-lib.psm1 and fm-check-lib.psm1 match their bash oracles across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-pr-libs-psm1.test.sh: all assertions passed\n'
