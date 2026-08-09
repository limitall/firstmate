#!/usr/bin/env bash
# tests/fm-install-psm1.test.sh - ONE differential suite for the W5-install
# package: the PowerShell twins of the three PINNED installers plus the vendor
# auth probe and the documentation audience check.
#
#   bin/fm-install-herdr.ps1        <- bin/fm-install-herdr.sh
#   bin/fm-install-treehouse.ps1    <- bin/fm-install-treehouse.sh
#   bin/fm-install-shellcheck.ps1   <- bin/fm-install-shellcheck.sh
#   bin/fm-vendor-auth-probe.ps1    <- bin/fm-vendor-auth-probe.sh
#   bin/fm-doc-audience-check.ps1   <- bin/fm-doc-audience-check.sh
#
# BASH IS THE ORACLE. Every case drives the .sh and the .ps1 with the SAME argv
# strings and the same fake toolchain, then compares exit code, stdout and
# stderr. Nothing here hard-codes what the author believed a twin should print,
# with one deliberate exception described under ANCHORS below.
#
# ---------------------------------------------------------------------------
# NOTHING IS DOWNLOADED. NOT ONCE.
#
# These three scripts exist to fetch a PINNED release asset over the network,
# and a test that actually fetched one would be worthless twice over: it would
# depend on GitHub being up and it would prove nothing about the pin, because a
# successful fetch exercises the HAPPY path only. So `curl` is FAKED on PATH and
# every case asserts the part that is a trust boundary:
#
#   - PLATFORM SELECTION - which asset name, and therefore which SHA-256, a
#     given uname pair selects. Asserted through the "downloading <asset> from
#     <url>" line, which carries the pinned tag, the pinned version and the
#     exact asset in one string.
#   - THE CHECKSUM GATE - the fake writes a known non-asset, so both twins
#     compute the same real SHA-256 and must refuse with the same sentence
#     naming the same EXPECTED pin.
#   - EVERY REFUSAL - unsupported platform, the Herdr Windows refusal, the
#     missing-unzip refusal, the exhausted-retry refusal, the ShellCheck
#     "asset unreachable and winget could not provide that version" refusal.
#
# What this CANNOT reach is the post-install version/protocol gate: making a
# checksum PASS would require fabricating a file with a given SHA-256. Those
# gates are therefore code-reviewed against the twin, not executed - stated
# plainly rather than papered over.
#
# ---------------------------------------------------------------------------
# TRANSPORT: ONE pwsh, EVER
#
# `pwsh -NoProfile -Command "exit 0"` costs ~4.8s on the reference host, so a
# suite that spawned one per case would spend minutes in interpreter startup and
# present as a hang. Every case is written to a FILE; ONE pwsh driver runs all
# of them IN-PROCESS (`& script.ps1` returns to the driver and leaves its code in
# $LASTEXITCODE - verified on this host) with [Console]::SetOut/SetError swapped
# to a StringWriter around each call, and prints one record per case; bash then
# joins the two result sets BY LABEL, never by path.
#
# The bash oracle half is fork-bound and dominates under load, so every helper
# here is builtin-only: parameter expansion instead of sed/cut, `read` instead
# of `cut`, and no `$( ... )` inside any per-assertion helper.
#
# ---------------------------------------------------------------------------
# DECLARED NORMALIZATION (the only differences allowed to survive)
#
#   1. CR is stripped and trailing newlines are trimmed. Native python3 and
#      cmd-based fakes emit CRLF; the twins' own writers emit LF.
#   2. TAB becomes a space and LF becomes the literal token @NL@, because the
#      transport is line/field delimited.
#   3. A twin NAMES ITSELF in its diagnostics, so `fm-install-herdr.sh:` and
#      `fm-install-herdr.ps1:` are both folded to `fm-install-herdr:` for the
#      five package scripts. Nothing else about a message is touched.
#   4. Empty output is carried as `-`.
#
# NOT normalized, deliberately: paths. Both worlds are handed the IDENTICAL argv
# strings (MSYS drive form for the installers' destination, native Windows form
# for the doc check's --root/--inventory), so any path a twin echoes back is the
# same string on both sides and a divergence there is a real defect. PATH itself
# is never compared - only its EFFECT, which is what tool each world resolves.
#
# ---------------------------------------------------------------------------
# ANCHORS
#
# A pure differential passes when both twins are broken the same way, which for
# a PIN is the failure mode that matters. So a handful of cases also assert the
# literal pinned strings - version, tag, asset name, expected SHA-256 - against
# the PowerShell side. If someone softens a pin in both trees at once, those
# anchors fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ;;
  *) echo "skip: the W5-install twins are differentially verified on Windows only"; exit 0 ;;
esac

for name in fm-install-herdr fm-install-treehouse fm-install-shellcheck \
  fm-vendor-auth-probe fm-doc-audience-check; do
  [ -f "$ROOT/bin/$name.ps1" ] || fail "bin/$name.ps1 is missing"
  [ -f "$ROOT/bin/$name.sh" ] || fail "bin/$name.sh is missing (the oracle)"
done

ORIG_PATH=$PATH
# Resolved BEFORE any PATH is narrowed, and used to invoke the oracle EXPLICITLY
# rather than letting its own `#!/usr/bin/env bash` shebang do it: the `min` PATH
# deliberately carries no interpreter for env to find, so every case in that mode
# would die at 127 before reaching the refusal it exists to pin.
BASH_BIN=$(command -v bash)
TMP_ROOT=$(fm_test_tmproot fm-install-psm1)

# PowerShell cannot resolve MSYS paths, and the two worlds must be handed the
# SAME argv strings, so every shared path is expressed in MSYS DRIVE form
# (/c/Users/...). ConvertTo-FmNativePath turns that into C:\Users\... with a
# pure string transform - no cygpath, which matters because several cases run
# with a PATH that has no cygpath on it.
NATIVE_TMP=$(fm_test_native_path "$TMP_ROOT")
WORK=${NATIVE_TMP//\\//}
case "$WORK" in
  [A-Za-z]:*) WORK="/${WORK%%:*}${WORK#*:}" ;;
esac
WORK=${WORK//\/\//\/}
# Lowercase the drive letter so the form matches what the bash tree writes.
WORK_DRIVE=${WORK:1:1}
case "$WORK_DRIVE" in
  [A-Z]) WORK="/$(printf '%s' "$WORK_DRIVE" | tr 'A-Z' 'a-z')${WORK:2}" ;;
esac
[ -d "$WORK" ] || fail "could not express the temp root in MSYS drive form: $WORK"

CASES="$TMP_ROOT/cases"
PS_RESULTS="$TMP_ROOT/ps-results"
DRIVER="$TMP_ROOT/driver.ps1"
: > "$CASES"

export FM_ROOT_OVERRIDE="$ROOT"
export FM_HOME="$WORK/home"
mkdir -p "$FM_HOME"

FS=$'\001'
UNITSEP=$'\037'

ASSERTIONS=0

# A stdin payload neither twin may leak into a probed vendor CLI.
STDIN_SENTINEL='SENTINEL-STDIN-MUST-NOT-REACH-VENDOR-CLI'

# --- the fake toolchain -----------------------------------------------------
#
# Each fake exists TWICE in the same directory: an extensionless bash script the
# oracle resolves through `command -v`, and a .cmd twin PowerShell's
# Get-Command resolves through PATHEXT. CreateProcess runs a .cmd directly, so
# Invoke-FmTool drives it exactly as it would a real tool (verified on this
# host). Both spellings read the SAME FM_FAKE_* environment, so one case record
# configures both worlds.
#
# The bash halves use an ABSOLUTE `#!/bin/bash` rather than `/usr/bin/env bash`:
# the `min` PATH deliberately carries no interpreter, so an env-based shebang
# would make every fake fail with "env: 'bash': No such file or directory" and
# the missing-extractor refusals would never be reached. It also saves one fork
# per fake invocation, which on this host is not a rounding error.
#
# curl COPIES a prepared fixture rather than echoing a string, because `echo`
# writes CRLF under cmd and LF under bash - and a one-byte difference in the
# fetched file would give the two worlds different SHA-256 values and make the
# checksum-mismatch sentences differ for a reason that has nothing to do with
# the code under test.
build_fakes() {  # <dir> <with-grok:yes|no>
  local dir=$1 with_grok=$2
  mkdir -p "$dir"

  cat > "$dir/uname" <<'SH'
#!/bin/bash
case "${1:-}" in
  -m) printf '%s\n' "${FM_FAKE_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_FAKE_UNAME_S:-Linux}" ;;
esac
SH
  cat > "$dir/uname.cmd" <<'CMD'
@echo off
if "%~1"=="-m" echo %FM_FAKE_UNAME_M%
if not "%~1"=="-m" echo %FM_FAKE_UNAME_S%
CMD

  cat > "$dir/curl" <<'SH'
#!/bin/bash
out= ; prev=
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  prev=$a
done
[ "${FM_FAKE_CURL_MODE:-fail}" = "ok" ] || exit 22
cp "$FM_FAKE_ASSET_SRC" "$out"
SH
  cat > "$dir/curl.cmd" <<'CMD'
@echo off
set "OUT="
:loop
if "%~1"=="" goto after
if "%~1"=="-o" goto grab
shift
goto loop
:grab
shift
set "OUT=%~1"
:after
if not "%FM_FAKE_CURL_MODE%"=="ok" exit /b 22
copy /y "%FM_FAKE_ASSET_SRC%" "%OUT%" >nul
CMD

  if [ "$with_grok" = yes ]; then
    # Records every invocation's argv and anything readable on stdin, so "the
    # argv is fixed" and "stdin stays closed" are observable facts rather than
    # comments. grok 0.2.117 exits 0 whether or not the session authenticates;
    # both fakes keep that property so a regression to exit-status reading fails.
    cat > "$dir/grok" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FM_FAKE_GROK_LOG"
if IFS= read -r -t 2 leaked; then
  printf '%s\n' "$leaked" >> "$FM_FAKE_GROK_STDIN"
fi
if [ "${1:-}" = --version ]; then
  printf 'grok %s (fakebuild) [stable]\n' "${FM_FAKE_GROK_VERSION:-0.2.117}"
  exit 0
fi
case "${FM_FAKE_GROK_MODE:-authenticated}" in
  authenticated) printf '%s\n' 'You are logged in with grok.com.' ;;
  unauthenticated) printf '%s\n' 'You are not authenticated.' ;;
  garbage) printf '%s\n' 'Session status: unknown (0.9.0 rewrote this line)' ;;
  leading-blank) printf '\n%s\n' 'You are logged in with grok.com.' ;;
  empty) : ;;
  hang) sleep 30 ;;
esac
exit 0
SH
    cat > "$dir/grok.cmd" <<'CMD'
@echo off
if "%FM_FAKE_GROK_VERSION%"=="" set "FM_FAKE_GROK_VERSION=0.2.117"
if "%FM_FAKE_GROK_MODE%"=="" set "FM_FAKE_GROK_MODE=authenticated"
>>"%FM_FAKE_GROK_LOG%" echo %*
set "LEAKED="
set /p LEAKED=
if not "%LEAKED%"=="" >>"%FM_FAKE_GROK_STDIN%" echo %LEAKED%
if "%~1"=="--version" (
  echo grok %FM_FAKE_GROK_VERSION% ^(fakebuild^) [stable]
  exit /b 0
)
if "%FM_FAKE_GROK_MODE%"=="authenticated" echo You are logged in with grok.com.
if "%FM_FAKE_GROK_MODE%"=="unauthenticated" echo You are not authenticated.
if "%FM_FAKE_GROK_MODE%"=="garbage" echo Session status: unknown (0.9.0 rewrote this line)
if "%FM_FAKE_GROK_MODE%"=="leading-blank" echo.
if "%FM_FAKE_GROK_MODE%"=="leading-blank" echo You are logged in with grok.com.
if "%FM_FAKE_GROK_MODE%"=="hang" ping -n 31 127.0.0.1 >nul
exit /b 0
CMD
    chmod +x "$dir/grok"
  fi
  chmod +x "$dir/uname" "$dir/curl"
}

FAKEBIN="$TMP_ROOT/fake"
FAKEBIN_NOGROK="$TMP_ROOT/fake-nogrok"
build_fakes "$FAKEBIN" yes
build_fakes "$FAKEBIN_NOGROK" no

# The `min` PATH exists for exactly one property: unzip and winget must be
# ABSENT so the missing-extractor refusals are reachable. PowerShell needs
# nothing on it; the ORACLE still needs its own runtime (mktemp, rm, sleep, ...),
# and those are MSYS binaries that break when copied away from msys-2.0.dll -
# so they are exposed through lib.sh's exec-wrapper helper, which is the
# portable spelling for exactly this situation.
TOOLBOX="$TMP_ROOT/toolbox"
mkdir -p "$TOOLBOX"
# `env` and `bash` are on the list because fm-install-shellcheck resolves its
# pinned version through bin/fm-lint.sh, whose own `#!/usr/bin/env bash` shebang
# must still work in this mode. Neither unzip nor winget is here, which is the
# whole point of the mode.
for tool in mktemp rm sleep sed head cat tr find install mkdir awk dirname \
  basename cygpath grep cut expr chmod ls date env bash; do
  fm_fakebin_tool "$TOOLBOX" "$tool"
done

BASE_FULL="/usr/bin:/bin"
BASE_FULL_NATIVE="C:\\Program Files\\Git\\usr\\bin;C:\\Windows\\System32;C:\\Windows"
# The PowerShell side of `min` still carries the toolbox, because
# fm-install-shellcheck resolves its pinned version through a bash child that
# needs a runtime. The toolbox holds only extensionless exec wrappers, which
# PATHEXT-driven Get-Command does not resolve, and it holds no unzip and no
# winget - so PowerShell still sees exactly the absences this mode exists for.
BASE_MIN_NATIVE="$(fm_test_native_path "$TOOLBOX");C:\\Windows\\System32"

# The fetched-but-wrong asset. Written once, byte-identical for both worlds.
ASSET_SRC="$WORK/not-the-pinned-asset.bin"
printf 'this is not the pinned release asset\n' > "$ASSET_SRC"
ASSET_SHA=$(sha256sum "$ASSET_SRC" | awk '{print $1}')
[ ${#ASSET_SHA} -eq 64 ] || fail "could not hash the fixture asset"

EMPTY_ROOT="$WORK/empty-root"
mkdir -p "$EMPTY_ROOT"
EMPTY_ROOT_NATIVE=$(fm_test_native_path "$TMP_ROOT")/empty-root
MISSING_INVENTORY_NATIVE=$(fm_test_native_path "$TMP_ROOT")/no-such-inventory.json

# --- case table -------------------------------------------------------------

FAKE_VARS="FM_FAKE_UNAME_S FM_FAKE_UNAME_M FM_FAKE_CURL_MODE FM_FAKE_ASSET_SRC"
FAKE_VARS="$FAKE_VARS FM_FAKE_GROK_MODE FM_FAKE_GROK_VERSION FM_VENDOR_AUTH_PROBE_TIMEOUT"

CASE_LABELS=""

# add_case <label> <script> <pathmode> <envspec|-> [argv...]
add_case() {
  local label=$1 script=$2 mode=$3 envspec=$4
  shift 4
  local argv= arg
  for arg in "$@"; do
    if [ -z "$argv" ]; then argv=$arg; else argv="$argv$UNITSEP$arg"; fi
  done
  [ -n "$argv" ] || argv='-'
  printf '%s%s%s%s%s%s%s%s%s\n' \
    "$label" "$FS" "$script" "$FS" "$mode" "$FS" "$envspec" "$FS" "$argv" >> "$CASES"
  CASE_LABELS="$CASE_LABELS $label"
}

H=fm-install-herdr
T=fm-install-treehouse
S=fm-install-shellcheck
V=fm-vendor-auth-probe
D=fm-doc-audience-check

# Platform selection: each arm must pick its own asset, and the download-failure
# sentence carries the asset name, the pinned tag and the bound.
add_case h-linux-x86_64 "$H" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-h1"
add_case h-linux-aarch64 "$H" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=aarch64;FM_FAKE_CURL_MODE=fail" "$WORK/d-h2"
add_case h-linux-arm64 "$H" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=arm64;FM_FAKE_CURL_MODE=fail" "$WORK/d-h3"
add_case h-darwin-arm64 "$H" full "FM_FAKE_UNAME_S=Darwin;FM_FAKE_UNAME_M=arm64;FM_FAKE_CURL_MODE=fail" "$WORK/d-h4"
add_case h-darwin-x86_64 "$H" full "FM_FAKE_UNAME_S=Darwin;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-h5"
add_case h-windows "$H" full "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=x86_64" "$WORK/d-h6"
add_case h-msys "$H" full "FM_FAKE_UNAME_S=MSYS_NT-10.0;FM_FAKE_UNAME_M=x86_64" "$WORK/d-h7"
add_case h-unsupported "$H" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=riscv64" "$WORK/d-h8"
add_case h-checksum "$H" full \
  "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=ok;FM_FAKE_ASSET_SRC=$ASSET_SRC" "$WORK/d-h9"
add_case h-no-destination "$H" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64" -

add_case t-linux-x86_64 "$T" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t1"
add_case t-linux-aarch64 "$T" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=aarch64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t2"
add_case t-darwin-arm64 "$T" full "FM_FAKE_UNAME_S=Darwin;FM_FAKE_UNAME_M=arm64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t3"
add_case t-darwin-x86_64 "$T" full "FM_FAKE_UNAME_S=Darwin;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t4"
add_case t-windows-amd64 "$T" full "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t5"
add_case t-windows-arm64 "$T" full "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=aarch64;FM_FAKE_CURL_MODE=fail" "$WORK/d-t6"
add_case t-unsupported "$T" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=riscv64" "$WORK/d-t7"
add_case t-no-unzip "$T" min "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=x86_64" "$WORK/d-t8"
add_case t-checksum "$T" full \
  "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=ok;FM_FAKE_ASSET_SRC=$ASSET_SRC" "$WORK/d-t9"
add_case t-no-destination "$T" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64" -

add_case s-unix-retries "$S" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=fail" "$WORK/d-s1"
add_case s-unix-checksum "$S" full \
  "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=ok;FM_FAKE_ASSET_SRC=$ASSET_SRC" "$WORK/d-s2"
add_case s-windows-checksum "$S" full \
  "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=x86_64;FM_FAKE_CURL_MODE=ok;FM_FAKE_ASSET_SRC=$ASSET_SRC" "$WORK/d-s3"
add_case s-windows-unreachable "$S" min "FM_FAKE_UNAME_S=MINGW64_NT-10.0;FM_FAKE_UNAME_M=x86_64" "$WORK/d-s4"
add_case s-no-destination "$S" full "FM_FAKE_UNAME_S=Linux;FM_FAKE_UNAME_M=x86_64" -

add_case v-no-args "$V" full - -
add_case v-unregistered "$V" full - openai
add_case v-unknown-flag "$V" full - --harness pi
add_case v-two-probes "$V" full - grok extra
add_case v-help "$V" full - --help
add_case v-unavailable "$V" nogrok - grok
add_case v-authenticated "$V" full "FM_FAKE_GROK_MODE=authenticated" grok
add_case v-unauthenticated "$V" full "FM_FAKE_GROK_MODE=unauthenticated" grok
add_case v-garbage "$V" full "FM_FAKE_GROK_MODE=garbage" grok
add_case v-leading-blank "$V" full "FM_FAKE_GROK_MODE=leading-blank" grok
add_case v-empty-output "$V" full "FM_FAKE_GROK_MODE=empty" grok
add_case v-version-drift "$V" full "FM_FAKE_GROK_MODE=authenticated;FM_FAKE_GROK_VERSION=0.9.0" grok
add_case v-timeout "$V" full "FM_FAKE_GROK_MODE=hang;FM_VENDOR_AUTH_PROBE_TIMEOUT=2" grok
add_case v-malformed-bound "$V" full "FM_FAKE_GROK_MODE=authenticated;FM_VENDOR_AUTH_PROBE_TIMEOUT=abc" grok
add_case v-zero-bound "$V" full "FM_FAKE_GROK_MODE=hang;FM_VENDOR_AUTH_PROBE_TIMEOUT=0" grok

add_case d-repo "$D" real - -
add_case d-help "$D" real - --help
add_case d-missing-inventory "$D" real - --inventory "$MISSING_INVENTORY_NATIVE"
add_case d-empty-root "$D" real - --root "$EMPTY_ROOT_NATIVE"

# --- oracle -----------------------------------------------------------------

# enc <text> -> ENC. Builtin-only; see DECLARED NORMALIZATION above.
ENC=
enc() {
  local s=$1 n
  s=${s//$'\r'/}
  s=${s//$'\t'/ }
  s=${s//$'\n'/@NL@}
  for n in fm-install-herdr fm-install-treehouse fm-install-shellcheck \
    fm-vendor-auth-probe fm-doc-audience-check; do
    s=${s//"$n.ps1"/"$n"}
    s=${s//"$n.sh"/"$n"}
  done
  while [ "${s: -4}" = '@NL@' ]; do s=${s:0:${#s}-4}; done
  [ -n "$s" ] || s='-'
  ENC=$s
}

declare -A BASH_RC BASH_OUT BASH_ERR PS_RC PS_OUT PS_ERR

run_oracle() {
  local label script mode envspec argvs rec rest pair key value d rc out err
  local -a argv
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    label=${rec%%"$FS"*}; rest=${rec#*"$FS"}
    script=${rest%%"$FS"*}; rest=${rest#*"$FS"}
    mode=${rest%%"$FS"*}; rest=${rest#*"$FS"}
    envspec=${rest%%"$FS"*}; argvs=${rest#*"$FS"}

    for key in $FAKE_VARS; do unset "$key"; done
    if [ "$envspec" != '-' ]; then
      rest=$envspec
      while [ -n "$rest" ]; do
        pair=${rest%%;*}
        if [ "$pair" = "$rest" ]; then rest=; else rest=${rest#*;}; fi
        key=${pair%%=*}; value=${pair#*=}
        export "$key=$value"
      done
    fi

    case $mode in
      full) export PATH="$FAKEBIN:$BASE_FULL" ;;
      min) export PATH="$FAKEBIN:$TOOLBOX" ;;
      nogrok) export PATH="$FAKEBIN_NOGROK:$BASE_FULL" ;;
      real) export PATH="$ORIG_PATH" ;;
    esac

    d="$TMP_ROOT/case/$label"
    mkdir -p "$d"
    export RUNNER_TEMP="$d"
    export FM_FAKE_GROK_LOG="$d/bash-grok.log"
    export FM_FAKE_GROK_STDIN="$d/bash-grok.stdin"
    : > "$FM_FAKE_GROK_LOG"
    : > "$FM_FAKE_GROK_STDIN"

    argv=()
    if [ "$argvs" != '-' ]; then
      IFS=$UNITSEP read -r -a argv <<<"$argvs"
    fi

    rc=0
    # Caller stdin the probe must never leak into a vendor CLI.
    "$BASH_BIN" "$ROOT/bin/$script.sh" ${argv[@]+"${argv[@]}"} \
      <<<"$STDIN_SENTINEL" \
      >"$d/bash.out" 2>"$d/bash.err" || rc=$?
    out=$(<"$d/bash.out")
    err=$(<"$d/bash.err")
    enc "$out"; BASH_OUT[$label]=$ENC
    enc "$err"; BASH_ERR[$label]=$ENC
    BASH_RC[$label]=$rc
  done < "$CASES"
  export PATH="$ORIG_PATH"
}

run_oracle

# --- the ONE pwsh driver ----------------------------------------------------

cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$casesPath = $args[0]
$resultPath = $args[1]
$binDir = $args[2]
$caseRoot = $args[3]
$fullBase = $args[4]
$minBase = $args[5]
$fakeBin = $args[6]
$fakeBinNoGrok = $args[7]

# `real` is the ambient PATH this driver INHERITED, never a spelling the suite
# composed: the two worlds spell the same PATH differently, and a composed one
# would be comparing spellings instead of effects.
$realPath = $env:PATH

$names = @('fm-install-herdr', 'fm-install-treehouse', 'fm-install-shellcheck',
    'fm-vendor-auth-probe', 'fm-doc-audience-check')
$fakeVars = @('FM_FAKE_UNAME_S', 'FM_FAKE_UNAME_M', 'FM_FAKE_CURL_MODE', 'FM_FAKE_ASSET_SRC',
    'FM_FAKE_GROK_MODE', 'FM_FAKE_GROK_VERSION', 'FM_VENDOR_AUTH_PROBE_TIMEOUT')

# The MSYS-drive transform, spelled here rather than borrowed from fm-common:
# the driver must not import the module under test's foundation, or a child's
# `Import-Module -Force` would pull the driver's own bindings out from under it.
function ConvertTo-CaseNative([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    if ($p -match '^/([A-Za-z])(/|$)') {
        return ($Matches[1].ToUpperInvariant() + ':' + $p.Substring(2).Replace('/', '\'))
    }
    return $p
}

function Format-CasePayload([string]$s) {
    if ($null -eq $s) { return '-' }
    $s = $s.Replace("`r", '')
    $s = $s.Replace("`t", ' ')
    $s = $s.Replace("`n", '@NL@')
    foreach ($n in $names) {
        $s = $s.Replace("$n.ps1", $n)
        $s = $s.Replace("$n.sh", $n)
    }
    while ($s.EndsWith('@NL@')) { $s = $s.Substring(0, $s.Length - 4) }
    if ($s -eq '') { return '-' }
    return $s
}

$sb = [System.Text.StringBuilder]::new()
foreach ($line in [System.IO.File]::ReadAllLines($casesPath)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    $f = @($line.Split([char]1))
    $label = $f[0]
    $script = $f[1]
    $mode = $f[2]
    $envSpec = $f[3]
    $argvSpec = $f[4]

    foreach ($v in $fakeVars) { [Environment]::SetEnvironmentVariable($v, $null) }
    if ($envSpec -ne '-') {
        foreach ($pair in @($envSpec.Split(';'))) {
            if (-not $pair) { continue }
            $idx = $pair.IndexOf('=')
            if ($idx -lt 1) { continue }
            [Environment]::SetEnvironmentVariable($pair.Substring(0, $idx),
                (ConvertTo-CaseNative $pair.Substring($idx + 1)))
        }
    }

    $fake = if ($mode -eq 'nogrok') { $fakeBinNoGrok } else { $fakeBin }
    switch ($mode) {
        'full' { $env:PATH = "$fake;$fullBase" }
        'min' { $env:PATH = "$fake;$minBase" }
        'nogrok' { $env:PATH = "$fake;$fullBase" }
        'real' { $env:PATH = $realPath }
    }

    $caseDir = Join-Path $caseRoot $label
    [void][System.IO.Directory]::CreateDirectory($caseDir)
    $env:RUNNER_TEMP = $caseDir
    $env:FM_FAKE_GROK_LOG = Join-Path $caseDir 'ps-grok.log'
    $env:FM_FAKE_GROK_STDIN = Join-Path $caseDir 'ps-grok.stdin'
    [System.IO.File]::WriteAllText($env:FM_FAKE_GROK_LOG, '')
    [System.IO.File]::WriteAllText($env:FM_FAKE_GROK_STDIN, '')

    $argv = @()
    if ($argvSpec -ne '-') { $argv = @($argvSpec.Split([char]31)) }

    # Console.Out/Error are swapped for a StringWriter around the call, because
    # the twins write through [Console] by contract and an in-process run would
    # otherwise interleave their output with this driver's own records.
    $swOut = [System.IO.StringWriter]::new()
    $swErr = [System.IO.StringWriter]::new()
    $oldOut = [Console]::Out
    $oldErr = [Console]::Error
    $rc = 0
    try {
        [Console]::SetOut($swOut)
        [Console]::SetError($swErr)
        $global:LASTEXITCODE = 0
        & (Join-Path $binDir "$script.ps1") @argv
        $rc = $LASTEXITCODE
    } catch {
        $rc = 'THREW'
        $swErr.Write($_.Exception.Message)
    } finally {
        [Console]::SetOut($oldOut)
        [Console]::SetError($oldErr)
    }

    [void]$sb.Append($label).Append([char]1).Append($rc).Append([char]1)
    [void]$sb.Append((Format-CasePayload $swOut.ToString())).Append([char]1)
    [void]$sb.Append((Format-CasePayload $swErr.ToString())).Append("`n")
}
[System.IO.File]::WriteAllText($resultPath, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
PS1

CASE_ROOT_NATIVE=$(fm_test_native_path "$TMP_ROOT/case")
mkdir -p "$TMP_ROOT/case"
pwsh -NoProfile -File "$(fm_test_native_path "$DRIVER")" \
  "$(fm_test_native_path "$CASES")" \
  "$(fm_test_native_path "$PS_RESULTS")" \
  "$(fm_test_native_path "$ROOT/bin")" \
  "$CASE_ROOT_NATIVE" \
  "$BASE_FULL_NATIVE" \
  "$BASE_MIN_NATIVE" \
  "$(fm_test_native_path "$FAKEBIN")" \
  "$(fm_test_native_path "$FAKEBIN_NOGROK")" \
  <<<"$STDIN_SENTINEL" >"$TMP_ROOT/driver.out" 2>"$TMP_ROOT/driver.err" \
  || fail "the pwsh driver failed: $(cat "$TMP_ROOT/driver.err")"

[ -s "$PS_RESULTS" ] || fail "the pwsh driver produced no results: $(cat "$TMP_ROOT/driver.err")"

while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  label=${rec%%"$FS"*}; rest=${rec#*"$FS"}
  rc=${rest%%"$FS"*}; rest=${rest#*"$FS"}
  out=${rest%%"$FS"*}; err=${rest#*"$FS"}
  PS_RC[$label]=$rc
  PS_OUT[$label]=$out
  PS_ERR[$label]=$err
done < "$PS_RESULTS"

# --- assertions -------------------------------------------------------------

note() { ASSERTIONS=$((ASSERTIONS + 1)); }

# lib.sh's expect_code does not count toward the assertion floor; this does.
expect_rc() { note; expect_code "$1" "$2" "$3"; }

# Divergences ACCUMULATE rather than aborting at the first one. A run of this
# suite costs minutes on this host (it is fork-bound, and every oracle case
# spawns a shell plus its fakes), so a fail-fast comparison would make a
# multi-case regression take one full run per case to diagnose.
FAILURES=0
DIVERGENCES=

same() {  # <label> <what> <bash> <ps>
  note
  [ "$3" = "$4" ] && return 0
  FAILURES=$((FAILURES + 1))
  DIVERGENCES="$DIVERGENCES
$1: $2 differs
  bash: $3
  pwsh: $4"
}

# The ONE stream the twins are allowed to differ on, and only for these three
# cases: bash's `${1:?usage: ...}` emits the SHELL's diagnostic, which carries a
# script line number ("bin/fm-install-herdr.sh: line 31: 1: usage: ..."). That is
# a bash artifact, not a contract, so the twins are compared on exit code and
# stdout here and the PowerShell usage line is asserted directly below.
SHELL_USAGE_CASES=" h-no-destination t-no-destination s-no-destination "

check_case() {  # <label>
  local label=$1
  [ -n "${PS_RC[$label]+set}" ] || fail "$label: the pwsh driver returned no record"
  same "$label" 'exit code' "${BASH_RC[$label]}" "${PS_RC[$label]}"
  same "$label" 'stdout' "${BASH_OUT[$label]}" "${PS_OUT[$label]}"
  case "$SHELL_USAGE_CASES" in
    *" $label "*) note ;;
    *) same "$label" 'stderr' "${BASH_ERR[$label]}" "${PS_ERR[$label]}" ;;
  esac
}

# ps_has <label> <stream:out|err> <needle> <why>: an ANCHOR - a literal pinned
# string the PowerShell twin must emit, so a pin softened in BOTH trees at once
# still fails here.
ps_has() {
  local hay
  if [ "$2" = out ]; then hay=${PS_OUT[$1]}; else hay=${PS_ERR[$1]}; fi
  note
  case "$hay" in
    *"$3"*) : ;;
    *) fail "$1: $4 (missing '$3') in pwsh $2: $hay" ;;
  esac
}

ps_lacks() {
  local hay
  if [ "$2" = out ]; then hay=${PS_OUT[$1]}; else hay=${PS_ERR[$1]}; fi
  note
  case "$hay" in
    *"$3"*) fail "$1: $4 (unexpected '$3') in pwsh $2: $hay" ;;
    *) : ;;
  esac
}

# Every case, unconditionally: the twins agree on all three observable channels.
test_every_case_matches_the_oracle() {
  local label
  for label in $CASE_LABELS; do
    check_case "$label"
  done
  [ "$FAILURES" -eq 0 ] || fail "$FAILURES twin divergence(s):$DIVERGENCES"
  pass "every W5-install case matches the bash oracle on exit code, stdout and stderr"
}

# --- anchored pin assertions ------------------------------------------------

HERDR_URL=https://github.com/ogulcancelik/herdr/releases/download/v0.7.4
TREEHOUSE_URL=https://github.com/kunchenguid/treehouse/releases/download/v2.0.1
SC_URL=https://github.com/koalaman/shellcheck/releases/download/v0.11.0

test_herdr_platform_selection_is_pinned() {
  ps_has h-linux-x86_64 err "downloading herdr-linux-x86_64 from $HERDR_URL/herdr-linux-x86_64" \
    'the linux/x86_64 arm must select its own pinned asset'
  ps_has h-linux-aarch64 err "downloading herdr-linux-aarch64 from $HERDR_URL/herdr-linux-aarch64" \
    'the linux/aarch64 arm must select its own pinned asset'
  ps_has h-linux-arm64 err 'herdr-linux-aarch64' 'arm64 is an alias of aarch64 on linux'
  ps_has h-darwin-arm64 err "downloading herdr-macos-aarch64 from $HERDR_URL/herdr-macos-aarch64" \
    'the darwin/arm64 arm must select its own pinned asset'
  ps_has h-darwin-x86_64 err "downloading herdr-macos-x86_64 from $HERDR_URL/herdr-macos-x86_64" \
    'the darwin/x86_64 arm must select its own pinned asset'
  ps_has h-linux-x86_64 err 'bounded at 25000000 bytes' 'the download ceiling must stay bounded'
  pass "each Herdr platform selects its own pinned v0.7.4 asset from the official release URL"
}

test_herdr_refuses_windows_and_unknown_platforms() {
  expect_rc 1 "${PS_RC[h-windows]}" 'the Herdr Windows refusal exits 1'
  ps_has h-windows err 'no stable Herdr release carries a Windows asset yet' \
    'Windows must be refused before any download'
  ps_has h-windows err 'the pinned v0.7.4 is linux/macos only' 'the refusal must name the pin'
  ps_lacks h-windows err 'downloading' 'the Windows refusal must precede any download'
  ps_has h-msys err 'no stable Herdr release carries a Windows asset yet' \
    'MSYS is the same Windows refusal'
  ps_has h-unsupported err \
    'unsupported platform Linux-riscv64; official Herdr assets are linux/macos x86_64 and aarch64' \
    'an unknown platform must be refused by name'
  ps_lacks h-unsupported err 'downloading' 'an unsupported platform must never reach a download'
  pass "Herdr refuses Windows and unknown platforms before any download, naming the pin"
}

test_herdr_checksum_gate_names_the_expected_pin() {
  expect_rc 1 "${PS_RC[h-checksum]}" 'a checksum mismatch exits 1'
  ps_has h-checksum err \
    'checksum mismatch for herdr-linux-x86_64 (expected bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059' \
    'the mismatch must name the pinned SHA-256'
  ps_has h-checksum err "got $ASSET_SHA" 'the mismatch must name the SHA-256 actually fetched'
  assert_absent "$WORK/d-h9/herdr" 'a checksum mismatch must install nothing'
  note
  pass "a fetched asset that is not the pin is refused by SHA-256 and never installed"
}

test_treehouse_platform_selection_is_pinned() {
  ps_has t-linux-x86_64 err \
    "downloading treehouse-v2.0.1-linux-amd64.tar.gz from $TREEHOUSE_URL/treehouse-v2.0.1-linux-amd64.tar.gz" \
    'the linux/x86_64 arm must select its own pinned archive'
  ps_has t-linux-aarch64 err 'treehouse-v2.0.1-linux-arm64.tar.gz' 'the linux/aarch64 arm maps to linux-arm64'
  ps_has t-darwin-arm64 err 'treehouse-v2.0.1-darwin-arm64.tar.gz' 'the darwin/arm64 arm maps to darwin-arm64'
  ps_has t-darwin-x86_64 err 'treehouse-v2.0.1-darwin-amd64.tar.gz' 'the darwin/x86_64 arm maps to darwin-amd64'
  ps_has t-windows-amd64 err 'treehouse-v2.0.1-windows-amd64.zip' 'the MINGW/x86_64 arm maps to windows-amd64'
  ps_has t-windows-arm64 err 'treehouse-v2.0.1-windows-arm64.zip' 'the MINGW/aarch64 arm maps to windows-arm64'
  ps_has t-linux-x86_64 err 'bounded at 15000000 bytes' 'the download ceiling must stay bounded'
  ps_has t-unsupported err \
    'unsupported platform Linux-riscv64; official Treehouse assets are linux/darwin/windows amd64 and arm64' \
    'an unknown platform must be refused by name'
  pass "each Treehouse platform selects its own pinned v2.0.1 archive from the official release URL"
}

test_treehouse_refuses_a_missing_extractor_and_a_bad_checksum() {
  expect_rc 1 "${PS_RC[t-no-unzip]}" 'a missing extractor exits 1'
  ps_has t-no-unzip err \
    'need unzip to extract treehouse-v2.0.1-windows-amd64.zip (MSYS2: pacman -S unzip)' \
    'a Windows zip with no unzip must be refused, not silently unpacked another way'
  ps_lacks t-no-unzip err 'downloading' 'the extractor check must precede the download'
  ps_has t-checksum err \
    'checksum mismatch for treehouse-v2.0.1-linux-amd64.tar.gz (expected 1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2' \
    'the mismatch must name the pinned SHA-256'
  assert_absent "$WORK/d-t9/treehouse" 'a checksum mismatch must install nothing'
  note
  pass "Treehouse refuses a missing extractor and a non-pinned archive"
}

test_shellcheck_pins_version_asset_and_retries() {
  ps_has s-unix-retries err 'download attempt 1 failed; retrying' 'the first retry must be reported'
  ps_has s-unix-retries err 'download attempt 2 failed; retrying' 'the second retry must be reported'
  ps_has s-unix-retries err 'download failed after 3 attempts' 'the retry budget must be bounded at 3'
  ps_lacks s-unix-retries err 'download attempt 3 failed' 'the third failure exhausts the budget'
  expect_rc 1 "${PS_RC[s-unix-retries]}" 'an exhausted retry budget exits 1'
  ps_has s-unix-checksum err 'checksum mismatch for shellcheck-v0.11.0.linux.x86_64.tar.xz' \
    'the Unix asset is pinned to the version fm-lint requires'
  ps_has s-windows-checksum err 'checksum mismatch for shellcheck-v0.11.0.zip' \
    'the Windows asset comes from the same pinned release'
  pass "ShellCheck pins the fm-lint-required version, both release assets, and a 3-attempt budget"
}

test_shellcheck_refuses_rather_than_floating_to_a_package_manager() {
  expect_rc 1 "${PS_RC[s-windows-unreachable]}" 'an unreachable asset with no winget exits 1'
  ps_has s-windows-unreachable err \
    'could not install pinned ShellCheck v0.11.0: the release asset was unreachable (needs curl and unzip) and winget could not provide that version' \
    'an unavailable pinned asset must refuse, never fall through to a floating latest'
  ps_has s-windows-unreachable err "install ShellCheck v0.11.0 manually into $WORK/d-s4" \
    'the refusal must tell the caller exactly what to place where'
  assert_absent "$WORK/d-s4/shellcheck.exe" 'a refused install must leave the destination empty'
  note
  pass "ShellCheck refuses when the pinned asset is unreachable instead of accepting a floating latest"
}

test_installers_refuse_without_a_destination() {
  local label
  for label in h-no-destination t-no-destination s-no-destination; do
    expect_rc 1 "${PS_RC[$label]}" "$label must exit 1 without a destination"
    ps_has "$label" err 'usage:' "$label must print its usage line"
    ps_lacks "$label" err 'downloading' "$label must not fetch anything without a destination"
  done
  pass "every installer refuses with a usage line, and fetches nothing, when given no destination"
}

# --- the vendor probe envelope ----------------------------------------------

grok_log_is_safe() {  # <label> <world:bash|ps>
  local file="$TMP_ROOT/case/$1/$2-grok.log" line
  note
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    case "$line" in
      models|--version) : ;;
      *) fail "$1 ($2): unexpected Grok CLI invocation 'grok $line'" ;;
    esac
  done < "$file"
}

grok_never_ran() {  # <label> <world>
  local file="$TMP_ROOT/case/$1/$2-grok.log"
  note
  [ ! -s "$file" ] || fail "$1 ($2): no vendor CLI may run, but grok was invoked"
}

test_probe_usage_errors_never_start_a_vendor_process() {
  local label
  for label in v-no-args v-unregistered v-unknown-flag v-two-probes; do
    expect_rc 2 "${PS_RC[$label]}" "$label must be a usage error"
    same "$label" 'usage exit code' "${BASH_RC[$label]}" "${PS_RC[$label]}"
    grok_never_ran "$label" bash
    grok_never_ran "$label" ps
    note
    [ "${PS_OUT[$label]}" = '-' ] || fail "$label must not emit a fact line: ${PS_OUT[$label]}"
  done
  pass "no candidate identity, unknown flag, or unregistered name reaches a vendor CLI"
}

test_probe_classifies_every_outcome_alike() {
  ps_has v-authenticated out 'probe=grok status=authenticated version=0.2.117 versionVerified=yes' \
    'an authenticated first line is ground truth'
  ps_has v-unauthenticated out 'status=unauthenticated' 'an unauthenticated first line is ground truth'
  ps_has v-garbage out 'status=indeterminate' 'rewritten output must never read as authenticated'
  ps_has v-leading-blank out 'status=indeterminate' 'a blank first line must never read as authenticated'
  ps_has v-empty-output out 'status=indeterminate' 'silent output must never read as authenticated'
  ps_has v-unavailable out 'probe=grok status=unavailable version=none versionVerified=none' \
    'an absent vendor CLI is reported, never assumed'
  ps_has v-version-drift out 'version=0.9.0 versionVerified=no' \
    'an unverified vendor version must be disclosed'
  local label
  for label in v-authenticated v-unauthenticated v-garbage v-empty-output v-version-drift; do
    expect_rc 0 "${PS_RC[$label]}" "$label must not encode its result in the exit status"
  done
  pass "every probe outcome is classified identically and none is encoded in the exit status"
}

test_probe_envelope_is_fixed_argv_closed_stdin_and_bounded() {
  local label
  for label in v-authenticated v-unauthenticated v-garbage; do
    grok_log_is_safe "$label" bash
    grok_log_is_safe "$label" ps
    note
    [ ! -s "$TMP_ROOT/case/$label/ps-grok.stdin" ] \
      || fail "$label: the PowerShell probe inherited caller stdin"
    note
    [ ! -s "$TMP_ROOT/case/$label/bash-grok.stdin" ] \
      || fail "$label: the bash probe inherited caller stdin"
  done
  ps_has v-timeout out 'status=timeout' 'a hit bound must be reported as a timeout'
  ps_has v-zero-bound out 'status=timeout' \
    'a zero bound must fall back to the default bound, not remove the bound'
  ps_has v-malformed-bound out 'status=authenticated' \
    'a malformed bound must be replaced by the default, not forwarded'
  pass "the probe keeps its fixed argv, closed stdin, and hard bound in both trees"
}

test_probe_fact_line_leaks_nothing() {
  ps_lacks v-authenticated out 'You are logged in' 'the fact line must not echo raw vendor output'
  ps_lacks v-authenticated out 'grok.com' 'the fact line must not echo raw vendor output'
  ps_lacks v-authenticated out 'SENTINEL-STDIN-MUST-NOT-REACH-VENDOR-CLI' \
    'the fact line must not echo caller stdin'
  ps_lacks v-authenticated out '@NL@' 'the fact line must be exactly one line'
  ps_has v-help out 'fm-vendor-auth-probe <probe>' '--help must name its own usage'
  expect_rc 0 "${PS_RC[v-help]}" '--help must succeed'
  pass "the fact line stays one sanitized line and --help names the registered probes"
}

# --- the documentation audience check ---------------------------------------

test_doc_audience_check_matches_the_oracle() {
  expect_rc 0 "${PS_RC[d-repo]}" 'the repository inventory must pass'
  ps_has d-repo out 'fm-doc-audience-check: ok surfaces=' 'the check must report surface coverage'
  ps_has d-repo out 'local_links=' 'the check must report local-link validation'
  expect_rc 1 "${PS_RC[d-missing-inventory]}" 'a missing inventory must fail'
  ps_has d-missing-inventory err 'inventory is missing:' 'a missing inventory must say so'
  expect_rc 1 "${PS_RC[d-empty-root]}" 'a root with no inventory must fail'
  expect_rc 0 "${PS_RC[d-help]}" '--help must succeed'
  ps_has d-help out '[--root ROOT] [--inventory INVENTORY]' \
    'the embedded checker keeps its argparse surface, so the program name stays "-"'
  pass "the documentation audience check reports the same verdicts through either wrapper"
}

test_every_case_matches_the_oracle
test_herdr_platform_selection_is_pinned
test_herdr_refuses_windows_and_unknown_platforms
test_herdr_checksum_gate_names_the_expected_pin
test_treehouse_platform_selection_is_pinned
test_treehouse_refuses_a_missing_extractor_and_a_bad_checksum
test_shellcheck_pins_version_asset_and_retries
test_shellcheck_refuses_rather_than_floating_to_a_package_manager
test_installers_refuse_without_a_destination
test_probe_usage_errors_never_start_a_vendor_process
test_probe_classifies_every_outcome_alike
test_probe_envelope_is_fixed_argv_closed_stdin_and_bounded
test_probe_fact_line_leaks_nothing
test_doc_audience_check_matches_the_oracle

# From an OBSERVED green run; a drop below this means cases stopped being
# evaluated rather than that the suite got faster.
MIN_ASSERTIONS=243
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d assertions ran, expected at least %d\n' "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the W5-install twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
