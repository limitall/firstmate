#!/usr/bin/env bash
# Behavior test for the W3-backend-core PowerShell twins:
#
#   bin/fm-backend.psm1      <- bin/fm-backend.sh          (the dispatcher)
#   bin/backends/tmux.psm1   <- bin/backends/tmux.sh       (the tmux adapter)
#   bin/fm-tmux-lib.psm1     <- bin/fm-tmux-lib.sh         (composer + submit)
#
# Every assertion names the module it covers with a `backend:`, `tmux:` or
# `lib:` label prefix, so a failure points at one file rather than at "the
# backend package".
#
# This is a DIFFERENTIAL test: every case drives the bash function and the
# PowerShell function with byte-identical input and asserts byte-identical
# output. BASH IS THE ORACLE - no expectation is hard-coded, so a case can never
# quietly encode what the author believed instead of what the shipped code does.
#
# WHY THIS PACKAGE IS WORTH THIS MUCH TEST. Three of the verdicts compared here
# decide whether firstmate recovers a crew or destroys one:
#   - Get-FmBackendTmuxAgentState's missing/unreadable split. tmux silently falls
#     back to the ACTIVE window when a named target is absent, so a transient
#     inventory failure that read as `missing` would license a duplicate spawn
#     against a worker that is still running.
#   - Send-FmTmuxEnterSubmit retries ENTER ONLY. A twin that retyped on retry
#     would deliver a captain instruction twice into a live agent.
#   - Get-FmTmuxComposerState's `empty` verdict is what the away-mode injector
#     reads as "safe to type into". A twin that answered `empty` where bash
#     answers `unknown` would type an escalation into a dead login shell.
#
# ---------------------------------------------------------------------------
# TRANSPORT, and the three traps this pattern has already sprung in this repo.
#
# All cases are written to a FILE and evaluated by ONE pwsh driver, which returns
# one result per record. Fields are separated by 0x01 and records by 0x02 - two
# bytes that appear in no fixture - so every value crosses the boundary as RAW
# BYTES: an ESC, a TAB, an embedded newline and a multibyte glyph all arrive
# unencoded, and the comparison is byte-exact by construction.
#
#   1. PER-CASE ENVIRONMENT DOES NOT SURVIVE THE BATCH. A bash prefix assignment
#      persists in the shell after a FUNCTION call, so by the time the single
#      pwsh runs it holds only the LAST value assigned. Every case that depends
#      on the environment therefore carries its own settings in the RECORD, and
#      the driver applies and clears them per case.
#   2. NEVER KEY A PROBE BY A PATH. The two worlds spell the same location
#      differently (/tmp/x vs C:\Users\...\Temp\x), so a key or an expected VALUE
#      containing one never matches. Every case is keyed by INDEX, and the two
#      functions that RETURN a path are compared by basename.
#   3. NO `( ... )` SUBSHELLS. A failure recorded inside one cannot reach the
#      parent's counters, so it would vanish into a FALSE PASS. Everything below
#      runs in parent scope.
#
# ---------------------------------------------------------------------------
# THE FAKE tmux, AND WHY THERE ARE TWO OF THEM.
#
# tmux does not exist on Windows, so both worlds are driven through a fake on
# PATH - the convention every backend suite in this repo already uses. It cannot
# be ONE file: verified on this host, .NET's Process.Start does not search PATH
# for a bare name and cannot start an extension-less shebang script at all ("not
# a valid application for this OS platform"), while a `.cmd` trampoline into Git
# Bash MANGLES the arguments (MSYS argv conversion eats the braces out of
# `#{cursor_y}`) and costs a second process per call. So the fakebin holds:
#
#     fakebin/tmux       a bash script  - what `command -v tmux` finds
#     fakebin/tmux.cmd   a batch script - what Get-Command -CommandType
#                                         Application resolves first, by PATHEXT
#
# The two implementations are kept honest three ways rather than by review:
#   - they share every RESPONSE FIXTURE, as files in the fakebin directory that
#     each fake locates relative to itself, so no response content is written
#     twice and no fixture path has to cross the MSYS/Windows boundary;
#   - both APPEND THEIR ARGV to a log, and the two logs are compared as a
#     first-class assertion - which is simultaneously the strongest tmux-side
#     check in this file, because it proves the PowerShell twins issue
#     byte-identical tmux command sequences;
#   - any divergence in the tiny dispatch rule shows up as a verdict mismatch.
#
# The batch fake writes its log with CRLF (cmd `echo` has no other mode), so the
# log comparison strips CR. Fixture CONTENT is emitted with `type`/`cat`, which
# are byte-exact, so the bytes that reach the code under test are identical.
#
# Fixtures are selected by the TARGET SESSION, so one fakebin serves every case:
# `alive:fm-x` reads lw-alive/comm-alive, `gone:fm-x` reads lwerr-gone, and so
# on. Arguments in this file avoid cmd metacharacters (& | < > ^ % and quotes),
# which the batch fake could not carry; spaces ARE exercised, because a captain
# instruction has them.
#
# ---------------------------------------------------------------------------
# COST, stated because it decides how this file is shaped. Measured on this host
# while the fleet was busy: a bash fork is ~3s and a child process started from
# pwsh is ~1.8s, an order of magnitude worse than the ~0.36s the port doc
# recorded on an idle machine. So the expensive oracle work is deliberately
# rationed: the bulk of the assertions drive FORK-FREE bash functions (the box
# finder, the edge test, the selector and validation helpers are pure shell),
# the oracle is captured through a redirect plus the `read` builtin rather than
# `$( ... )`, and the tmux-driven phase is a bounded scenario rather than a case
# per shape. Wall time tracks host load; on a quiet machine this is minutes, on
# a loaded one it is longer, and it never spawns pwsh more than three times.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT COVERED HERE, and why - so nobody reads a green run as more than
# it is:
#   - REAL tmux. tests/fm-backend-tmux-smoke.test.sh remains the only
#     real-server authority and it skips on this platform.
#   - The cmux process-ancestry fallback. Its bash twin fakes `ps`; the
#     PowerShell twin reads the native process table through fm-psproc-lib and
#     cannot be faked the same way. The bundle-id fallback and the macOS-only
#     gate ARE covered, through a fake uname.
#   - herdr/zellij/orca/cmux dispatch arms. Their adapters are later packages;
#     what IS asserted is that the dispatcher refuses them fail-closed today.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in bin/fm-backend.psm1 bin/backends/tmux.psm1 bin/fm-tmux-lib.psm1; do
  [ -f "$ROOT/$f" ] || fail "$f is missing"
done

# The oracles. fm-backend.sh brings the dispatcher; fm_backend_source tmux
# brings the adapter, which itself sources fm-tmux-lib.sh and fm-composer-lib.sh.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed (the bash oracle is unusable)"

TMP_ROOT=$(fm_test_tmproot fm-backend-core-psm1)
CAP="$TMP_ROOT/oracle.out"
ERRCAP="$TMP_ROOT/oracle.err"
CASES="$TMP_ROOT/cases.bin"
RESULTS="$TMP_ROOT/results.bin"
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_ERR="$TMP_ROOT/driver.err"

MOD_BACKEND_N=$(fm_test_native_path "$ROOT/bin/fm-backend.psm1")
MOD_TMUXLIB_N=$(fm_test_native_path "$ROOT/bin/fm-tmux-lib.psm1")
MOD_ADAPTER_N=$(fm_test_native_path "$ROOT/bin/backends/tmux.psm1")
MOD_COMMON_N=$(fm_test_native_path "$ROOT/bin/fm-common.psm1")

LF=$'\n'
ESC=$(printf '\033')
# --- FIXTURE BYTES, NEVER printf with a \u code-point escape -----------------
#
# bash's `printf` with a \u escape encodes the code point in the CURRENT
# LOCALE's charset. Under C/POSIX - which is what MSYS2 gives every NON-LOGIN
# shell, because only a login shell runs /etc/profile.d/lang.sh - it emits a
# single 8-bit byte for U+0080..U+00FF and passes anything above U+00FF through
# as the LITERAL SIX CHARACTERS of the escape. So a suite that builds fixtures
# that way builds different bytes depending on how the shell that launched it
# was started, and the resulting differential failures are unattributable: they
# reproduce identically on commits where the suite passed (2026-08, task
# ps-port-locale).
#
# ANSI-C \xNN quoting emits the byte verbatim in every locale - verified here
# under C, C.UTF-8, en_GB.UTF-8 and unset - and keeps this file pure ASCII.
GLYPH_CLAUDE=$'\xE2\x9D\xAF'   # U+276F
SP_NBSP=$'\xC2\xA0'            # U+00A0

# Box-drawing pieces for the pane fixtures, same byte discipline.
BOX_TL=$'\xE2\x95\xAD'         # U+256D
BOX_TR=$'\xE2\x95\xAE'         # U+256E
BOX_BL=$'\xE2\x95\xB0'         # U+2570
BOX_BR=$'\xE2\x95\xAF'         # U+256F
BOX_H=$'\xE2\x94\x80'          # U+2500
BOX_V=$'\xE2\x94\x82'          # U+2502

# Kimi's busy signature. MOON is ASTRAL - four UTF-8 bytes - and that is the
# whole subject of the grep divergence documented at its case, so a fixture that
# had silently degraded to the escape's literal text would have "proved" that
# divergence against nothing at all. Which is precisely what a non-login run did
# before these fixtures were byte-built.
MOON=$'\xF0\x9F\x8C\x91'       # U+1F311 NEW MOON
MIDDOT=$'\xC2\xB7'             # U+00B7

# --- the UTF-8 regime is PINNED, not inherited -------------------------------
#
# The NBSP row cases below assert BOTH [[:space:]] regimes: LC_ALL=C is carried
# per case, and its UTF-8 counterpart used to ride on "the ambient locale",
# which here is UTF-8 only when a login shell exported LANG. Left inherited, a
# non-login run asserts the C rules twice and never exercises the Unicode trim
# set - a coverage hole the differential cannot see, because both sides agree.
#
# The name is PROBED rather than assumed: an uninstallable locale name degrades
# to C in bash while the PowerShell twin matches the NAME, so hard-coding one
# would turn a missing locale into a differential failure that says nothing
# about the code.
fm_test_pick_utf8_locale() {
  local cand had saved
  had=${LC_ALL+set}; saved=${LC_ALL-}
  for cand in C.UTF-8 en_US.UTF-8 en_GB.UTF-8 "${LANG:-}" "${LC_CTYPE:-}"; do
    [ -n "$cand" ] || continue
    export LC_ALL="$cand"
    # All-whitespace under this locale iff the %%-strip removes nothing.
    if [ "${SP_NBSP%%[![:space:]]*}" = "$SP_NBSP" ]; then
      if [ -n "$had" ]; then export LC_ALL="$saved"; else unset LC_ALL; fi
      printf '%s' "$cand"
      return 0
    fi
  done
  if [ -n "$had" ]; then export LC_ALL="$saved"; else unset LC_ALL; fi
  return 0
}

FM_TEST_UTF8_LOCALE=$(fm_test_pick_utf8_locale)
if [ -n "$FM_TEST_UTF8_LOCALE" ]; then
  export LC_ALL="$FM_TEST_UTF8_LOCALE"
else
  echo "# note: no UTF-8 locale on this host - the UTF-8 trim regime is NOT exercised"
fi

# --- assertion bookkeeping ----------------------------------------------------
#
# Plain shell variables in parent scope; see trap 3 in the header.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_same() {  # <label> <expected(bash)> <actual(pwsh)>
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

# --- fork-free oracle capture -------------------------------------------------
#
# `read -d ''` reads to NUL, i.e. the whole file, and returns non-zero at EOF
# while still assigning - hence `|| true`. This costs no fork, where `$( ... )`
# costs one per call and this host charges ~3s for it.
ORACLE=''
ORACLE_ERR=''
ORACLE_RC=0

run_oracle() {  # <fn> <args...>
  ORACLE=''; ORACLE_ERR=''; ORACLE_RC=0
  "$@" > "$CAP" 2> "$ERRCAP" || ORACLE_RC=$?
  IFS= read -r -d '' ORACLE < "$CAP" || true
  IFS= read -r -d '' ORACLE_ERR < "$ERRCAP" || true
}

# The first line of a captured diagnostic, with its terminator removed. Every
# refusal in this package is single-line; taking the first line keeps a future
# multi-line addition from turning one assertion into an unreadable blob.
first_line() {  # <text>
  printf '%s' "${1%%"$LF"*}"
}

# rstrip_oracle: the `$( ... )` convention, applied in place and fork-free.
#
# WHICH CASES NEED IT, and why this is not softening the comparison. A bash
# adapter function that ends in a tmux display-message read, or in a printf
# whose format carries its own newline, emits a trailing newline, and EVERY
# bash call site consumes it through
# `$( ... )`, which strips it; the PowerShell twins document and return the
# value a bash caller ends up holding. Comparing at that convention compares
# what the consumers actually get, and every interior byte still has to match.
# Get-FmBackendTmuxCapture is deliberately NOT rstripped: it is the one function
# documented as returning RAW bytes, because bin/fm-peek.sh prints them straight
# through.
rstrip_oracle() {
  while [ "${ORACLE%"$LF"}" != "$ORACLE" ]; do ORACLE=${ORACLE%"$LF"}; done
}

yesno() {  # <fn> <args...> -> yes when it succeeds
  if "$@" > "$CAP" 2> "$ERRCAP"; then printf 'yes'; else printf 'no'; fi
}

# --- case machinery -----------------------------------------------------------
#
# Field 0 is the op, field 1 the per-case environment (KEY=VALUE entries joined
# by 0x1F; see trap 1), fields 2..7 the arguments. Empty middle fields are
# meaningful, so the driver splits on the separator and asserts the FIELD COUNT
# rather than trusting a regex split.
FS=$(printf '\001')
RS=$(printf '\002')
US=$(printf '\037')

LABELS=()
EXPECT=()

add_case() {  # <label> <expected> <op> <env> <a1..a6>
  LABELS+=("$1")
  EXPECT+=("$2")
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$3" "$FS" "$4" "$FS" "$5" "$FS" "$6" "$FS" "$7" "$FS" "$8" "$FS" "$9" "$FS" "${10}" >> "$CASES"
  printf '%s' "$RS" >> "$CASES"
}

: > "$CASES"

# --- fixtures -----------------------------------------------------------------

STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
STATE_N=$(fm_test_native_path "$STATE")

fm_write_meta "$STATE/task1.meta" "window=firstmate:fm-task1" "worktree=/w/task1" "project=/p/task1" "harness=claude"
fm_write_meta "$STATE/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
fm_write_meta "$STATE/fm-turnend-v9.meta" "window=default:wB:p3" "backend=herdr"
fm_write_meta "$STATE/custom-window-task.meta" "window=custom-window"
fm_write_meta "$STATE/orca-task.meta" "window=fm-orca-task" "terminal=term-orca-task" "backend=orca" \
  "endpoint_task_id=orca-task" "worktree=/w/o" "project=/p/o" "orca_worktree_id=wt7"
fm_write_meta "$STATE/dupwin.meta" "window=a:b" "window=c:d" "worktree=/w" "project=/p"
fm_write_meta "$STATE/eqvalue.meta" "window=sess:fm-eqvalue" "note=a=b=c" "worktree=/w/e" "project=/p/e"
fm_write_meta "$STATE/lastwins.meta" "backend=tmux" "backend=herdr" "window=z:1"
fm_write_meta "$STATE/nobackend.meta" "window=firstmate:fm-nobackend" "worktree=/w/n" "project=/p/n"
fm_write_meta "$STATE/badbinding.meta" "window=firstmate:fm-badbinding" "worktree=/w/b" "project=/p/b" \
  "endpoint_task_id=someoneelse"
fm_write_meta "$STATE/emptywin.meta" "window=" "worktree=/w/x" "project=/p/x"
fm_write_meta "$STATE/badbackend.meta" "window=firstmate:fm-badbackend" "worktree=/w/y" "project=/p/y" \
  "backend=bogus"
fm_write_meta "$STATE/tabmeta.meta" "window=firstmate:fm-tabmeta" "worktree=/w$(printf '\t')z" "project=/p/z"
fm_write_meta "$STATE/herdrok.meta" "window=hsess:hpane" "worktree=/w/h" "project=/p/h" "backend=herdr" \
  "endpoint_task_id=herdrok" "herdr_session=hsess" "herdr_workspace_id=ws1" "herdr_tab_id=t1" "herdr_pane_id=hpane"
fm_write_meta "$STATE/cmuxok.meta" "window=ws9:sf9" "worktree=/w/c" "project=/p/c" "backend=cmux" \
  "endpoint_task_id=cmuxok" "cmux_workspace_id=ws9" "cmux_surface_id=sf9"
fm_write_meta "$STATE/zellijbad.meta" "window=zs:9" "worktree=/w/z" "project=/p/z2" "backend=zellij" \
  "endpoint_task_id=zellijbad" "zellij_session=zs" "zellij_tab_id=xx" "zellij_pane_id=9"

# A SECOND, DELIBERATELY SMALL state dir for every selector case.
#
# fm_backend_meta_for_window scans EVERY *.meta in the directory and calls
# fm_meta_get twice per file, and fm_meta_get is a three-process pipeline. On
# the sixteen-record dir above that is ~130 child processes per call, which at
# this host cost is minutes of wall time for one assertion. The selector cases
# do not need a crowded directory to prove anything - they need an exact hit,
# a terminal= hit, and a miss - so they get their own five-record dir and the
# crowded one stays for the cases that open a single named file.
SEL_STATE="$TMP_ROOT/sel-state"
mkdir -p "$SEL_STATE"
SEL_STATE_N=$(fm_test_native_path "$SEL_STATE")
fm_write_meta "$SEL_STATE/task1.meta" "window=firstmate:fm-task1"
fm_write_meta "$SEL_STATE/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
fm_write_meta "$SEL_STATE/fm-turnend-v9.meta" "window=default:wB:p3" "backend=herdr"
fm_write_meta "$SEL_STATE/orca-task.meta" "window=fm-orca-task" "terminal=term-orca-task" "backend=orca"
fm_write_meta "$SEL_STATE/custom-window-task.meta" "window=custom-window"

CFG_EMPTY="$TMP_ROOT/cfg-empty"; mkdir -p "$CFG_EMPTY"
CFG_TMUX="$TMP_ROOT/cfg-tmux"; mkdir -p "$CFG_TMUX"; printf 'tmux\n' > "$CFG_TMUX/backend"
CFG_PAD="$TMP_ROOT/cfg-pad"; mkdir -p "$CFG_PAD"; printf '\n   \n  herdr  \nzellij\n' > "$CFG_PAD/backend"
CFG_CRLF="$TMP_ROOT/cfg-crlf"; mkdir -p "$CFG_CRLF"; printf 'zellij\r\n' > "$CFG_CRLF/backend"
CFG_EMPTY_N=$(fm_test_native_path "$CFG_EMPTY")
CFG_TMUX_N=$(fm_test_native_path "$CFG_TMUX")
CFG_PAD_N=$(fm_test_native_path "$CFG_PAD")
CFG_CRLF_N=$(fm_test_native_path "$CFG_CRLF")

# A non-Darwin `uname` fake for BOTH worlds, so every "nothing detected" case is
# deterministic no matter what runtime this suite itself executes inside.
make_uname_fakebin() {  # <dir> <answer>
  local fb=$1 answer=$2
  mkdir -p "$fb"
  printf '#!/bin/sh\nprintf %%s\\\\n %s\n' "$answer" > "$fb/uname"
  chmod +x "$fb/uname"
  printf '@echo off\r\necho %s\r\nexit /b 0\r\n' "$answer" > "$fb/uname.cmd"
}
FB_LINUX="$TMP_ROOT/fb-linux"; make_uname_fakebin "$FB_LINUX" Linux
FB_DARWIN="$TMP_ROOT/fb-darwin"; make_uname_fakebin "$FB_DARWIN" Darwin
# lsappinfo must be ABSENT from the Darwin fakebin so the ancestry walk cannot
# resolve an app pid; the bundle-id signal is the one this suite covers.
FB_LINUX_N=$(fm_test_native_path "$FB_LINUX")
FB_DARWIN_N=$(fm_test_native_path "$FB_DARWIN")

# =============================================================================
# THE FAKE tmux - two implementations, one set of fixtures. See the header.
# =============================================================================
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
FAKEBIN_N=$(fm_test_native_path "$FAKEBIN")

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# Fake tmux (bash side). Twin: tmux.cmd. Fixtures live beside this file and are
# selected by the target's SESSION, so one fakebin serves every case.
d=${0%/*}
# ONE line per invocation, holding the whole command line rather than one entry
# per argument. Batch has no way to iterate a faithful argv: cmd tokenizes `%1`
# on `=` as well as on space, so `kill-window -t =sess:=win` - the exact-selector
# contract, and the single most important argument this fake ever sees - would
# log as two entries there and one here. `%*` keeps the raw line intact, so the
# bash side reconstructs the same line under .NET's own quoting rule: an
# argument is quoted iff it contains a space (none here carries a quote or a tab,
# which are the only other triggers).
raw=
for a in "$@"; do
  case $a in
    *' '*) raw="$raw \"$a\"" ;;
    *) raw="$raw $a" ;;
  esac
done
printf '[%s]\n' "${raw# }" >> "${FM_TMUX_LOG:?}"
sub=${1:-}
target= fmt= has_e=0 has_dash=0 has_all=0 has_40=0 has_enter=0 prev=
for a in "$@"; do
  [ "$prev" = "-t" ] && target=$a
  case $a in
    -e) has_e=1 ;;
    -) has_dash=1 ;;
    -a) has_all=1 ;;
    -40) has_40=1 ;;
    Enter) has_enter=1 ;;
    '#{cursor_y}') fmt=cursor ;;
    '#{pane_id}') fmt=paneid ;;
    '#{pane_current_command}') fmt=comm ;;
    '#{pane_current_path}') fmt=path ;;
    '#S') fmt=session ;;
  esac
  prev=$a
done
s=${target%%:*}
emit() { [ -f "$1" ] || exit 1; cat "$1"; exit 0; }
case $sub in
  display-message)
    case $fmt in
      cursor) emit "$d/cursor-$s" ;;
      paneid) emit "$d/paneid-$s" ;;
      comm) emit "$d/comm-$s" ;;
      path) emit "$d/path-$s" ;;
      session) emit "$d/session" ;;
    esac
    exit 1 ;;
  capture-pane)
    if [ "$has_e" = 1 ]; then
      if [ "$has_dash" = 1 ]; then emit "$d/pane-$s"; fi
      emit "$d/row-$s"
    fi
    if [ "$has_40" = 1 ]; then emit "$d/tail-$s"; fi
    emit "$d/cap-$s" ;;
  list-windows)
    if [ "$has_all" = 1 ]; then emit "$d/lw-all"; fi
    if [ -f "$d/lwerr-$s" ]; then cat "$d/lwerr-$s" >&2; exit 1; fi
    emit "$d/lw-$s" ;;
  send-keys)
    if [ "$has_enter" = 1 ]; then
      printf 'Enter\n' >> "$d/sent-$s"
      if [ ! -f "$d/swallow-$s" ] && [ -f "$d/cleared-$s" ]; then
        cat "$d/cleared-$s" > "$d/pane-$s"
      fi
      exit 0
    fi
    [ -f "$d/sendfail-$s" ] && exit 1
    exit 0 ;;
  new-window) emit "$d/wid" ;;
  has-session) [ -f "$d/hassession-$s" ] && exit 0; exit 1 ;;
  kill-window|set-window-option) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

# The batch twin. Emitted with `printf '%s\r\n'`, whose format is REUSED for
# every argument, because cmd.exe needs CRLF: an LF-only batch file makes cmd
# mis-seek on `goto`, which is not a syntax error, just wrong behaviour later.
#
# EVERY branch is a `goto` to its own label and NOT a `&`-chained one-liner:
# batch parses `&` at the command-line level, so `if cond a & b` runs `b`
# UNCONDITIONALLY. Written that way the first time, it silently turned every
# list-windows into a failure and every display-message into an empty answer -
# a fake that lies is worse than no fake, so this is spelled out rather than
# left to review.
printf '%s\r\n' \
  '@echo off' \
  'setlocal EnableDelayedExpansion' \
  'set "D=%~dp0"' \
  'set "SUB=%~1"' \
  'set "TARGET="' \
  'set "FMT="' \
  'set "HAS_E=0"' \
  'set "HAS_DASH=0"' \
  'set "HAS_ALL=0"' \
  'set "HAS_40=0"' \
  'set "HAS_ENTER=0"' \
  'set "PREV="' \
  '>>"%FM_TMUX_LOG%" echo [%*]' \
  ':loop' \
  'if "%~1"=="" goto done' \
  'if "!PREV!"=="-t" set "TARGET=%~1"' \
  'if "%~1"=="-e" set "HAS_E=1"' \
  'if "%~1"=="-" set "HAS_DASH=1"' \
  'if "%~1"=="-a" set "HAS_ALL=1"' \
  'if "%~1"=="-40" set "HAS_40=1"' \
  'if "%~1"=="Enter" set "HAS_ENTER=1"' \
  'if "%~1"=="#{cursor_y}" set "FMT=cursor"' \
  'if "%~1"=="#{pane_id}" set "FMT=paneid"' \
  'if "%~1"=="#{pane_current_command}" set "FMT=comm"' \
  'if "%~1"=="#{pane_current_path}" set "FMT=path"' \
  'if "%~1"=="#S" set "FMT=session"' \
  'set "PREV=%~1"' \
  'shift' \
  'goto loop' \
  ':done' \
  'set "S="' \
  'for /f "tokens=1 delims=:" %%a in ("!TARGET!") do set "S=%%a"' \
  'if "%SUB%"=="display-message" goto dm' \
  'if "%SUB%"=="capture-pane" goto cp' \
  'if "%SUB%"=="list-windows" goto lw' \
  'if "%SUB%"=="send-keys" goto sk' \
  'if "%SUB%"=="new-window" goto nw' \
  'if "%SUB%"=="has-session" goto hs' \
  'exit /b 0' \
  ':dm' \
  'set "F="' \
  'if "!FMT!"=="cursor" set "F=!D!cursor-!S!"' \
  'if "!FMT!"=="paneid" set "F=!D!paneid-!S!"' \
  'if "!FMT!"=="comm" set "F=!D!comm-!S!"' \
  'if "!FMT!"=="path" set "F=!D!path-!S!"' \
  'if "!FMT!"=="session" set "F=!D!session"' \
  'if "!F!"=="" exit /b 1' \
  'goto emit' \
  ':cp' \
  'set "F=!D!cap-!S!"' \
  'if "!HAS_40!"=="1" set "F=!D!tail-!S!"' \
  'if "!HAS_E!"=="1" set "F=!D!row-!S!"' \
  'if "!HAS_E!"=="1" if "!HAS_DASH!"=="1" set "F=!D!pane-!S!"' \
  'goto emit' \
  ':lw' \
  'if "!HAS_ALL!"=="1" goto lwall' \
  'if exist "!D!lwerr-!S!" goto lwerr' \
  'set "F=!D!lw-!S!"' \
  'goto emit' \
  ':lwall' \
  'set "F=!D!lw-all"' \
  'goto emit' \
  ':lwerr' \
  'type "!D!lwerr-!S!" 1>&2' \
  'exit /b 1' \
  ':sk' \
  'if not "!HAS_ENTER!"=="1" goto sendliteral' \
  '>>"!D!sent-!S!" echo Enter' \
  'if exist "!D!swallow-!S!" exit /b 0' \
  'if exist "!D!cleared-!S!" copy /y /b "!D!cleared-!S!" "!D!pane-!S!" >nul' \
  'exit /b 0' \
  ':sendliteral' \
  'if exist "!D!sendfail-!S!" exit /b 1' \
  'exit /b 0' \
  ':nw' \
  'set "F=!D!wid"' \
  'goto emit' \
  ':hs' \
  'if exist "!D!hassession-!S!" exit /b 0' \
  'exit /b 1' \
  ':emit' \
  'if not exist "!F!" exit /b 1' \
  'type "!F!"' \
  'exit /b 0' \
  > "$FAKEBIN/tmux.cmd"

# install_tmux_fixtures: the fixture set both worlds run against. Called once
# before the bash scenario and AGAIN before the pwsh run, because the submit
# case mutates the composer through the fake and the second world must start
# from the same bytes.
install_tmux_fixtures() {
  local d=$FAKEBIN
  rm -f "$d"/cursor-* "$d"/paneid-* "$d"/comm-* "$d"/path-* "$d"/pane-* "$d"/row-* \
        "$d"/tail-* "$d"/cap-* "$d"/lw-* "$d"/lwerr-* "$d"/sent-* "$d"/swallow-* \
        "$d"/cleared-* "$d"/sendfail-* "$d"/hassession-* "$d"/session "$d"/wid 2>/dev/null

  printf 'captain on deck\nsecond line\n' > "$d/cap-sess1"
  printf '/work/tree/one\n' > "$d/path-sess1"
  printf 'claude\n' > "$d/comm-sess1"
  printf '%%7\n' > "$d/paneid-sess1"
  printf 'firstmate:adhoc\nother:otherwin\n' > "$d/lw-all"
  printf 'ambient-session\n' > "$d/session"
  printf '@11\n' > "$d/wid"
  printf 'fm-existing\nfm-other\n' > "$d/lw-container"

  # agent-state fixtures, one session per verdict.
  printf 'fm-x\n' > "$d/lw-alive";      printf 'claude\n'   > "$d/comm-alive"
  printf 'fm-x\n' > "$d/lw-deadsh";     printf -- '-bash\n'    > "$d/comm-deadsh"
  printf 'fm-x\n' > "$d/lw-amb";        printf 'vim\n'      > "$d/comm-amb"
  printf 'fm-other\n' > "$d/lw-nowin"
  printf "can't find session: gone\n" > "$d/lwerr-gone"
  printf 'lost server\n' > "$d/lwerr-broke"
  printf 'fm-x\n' > "$d/lw-emptycomm"; printf '\n' > "$d/comm-emptycomm"

  # composer fixtures. cempty is a proven-empty bordered box; cpend holds text.
  printf '1\n' > "$d/cursor-cempty"
  printf '%s\n%s\n%s\n' "$BOX_TL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_TR" "$BOX_V >   $BOX_V" "$BOX_BL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_BR" > "$d/pane-cempty"
  printf '1\n' > "$d/cursor-cpend"
  printf '%s\n%s\n%s\n' "$BOX_TL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_TR" "$BOX_V > fix $BOX_V" "$BOX_BL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_BR" > "$d/pane-cpend"
  # A ghost-only composer: dim text must not read as pending input.
  printf '1\n' > "$d/cursor-cghost"
  printf '%s\n%s\n%s\n' "$BOX_TL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_TR" "$BOX_V >${ESC}[2mgh${ESC}[0m $BOX_V" "$BOX_BL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_BR" > "$d/pane-cghost"

  # busy-footer fixtures for the 40-line tail read.
  printf '\n\nesc to interrupt\n' > "$d/tail-busyc"
  printf '\nWorked for 31s\n' > "$d/tail-idlec"

  # The submit scenario: a composer holding text, an Enter that is always
  # swallowed, and a busy tail - the opencode busy-queued case, where the
  # verdict must convert to `empty` only after the retry budget is spent.
  printf '1\n' > "$d/cursor-swal"
  printf '%s\n%s\n%s\n' "$BOX_TL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_TR" "$BOX_V > fix $BOX_V" "$BOX_BL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_BR" > "$d/pane-swal"
  printf '%s\n%s\n%s\n' "$BOX_TL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_TR" "$BOX_V >     $BOX_V" "$BOX_BL${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}${BOX_H}$BOX_BR" > "$d/cleared-swal"
  : > "$d/swallow-swal"
  printf 'esc to interrupt\n' > "$d/tail-swal"
  : > "$d/sent-swal"
}
install_tmux_fixtures

# =============================================================================
# PHASE 1 - everything that needs no tmux. The bulk of the assertions live here
# because these bash oracles are pure shell: no fork, so the case count is not
# rationed by this host's process cost.
# =============================================================================

# --- backend name sets and validation (backend:) ------------------------------

case_listcontains() {  # <label> <list> <name>
  add_case "backend:list-contains $1" "$(yesno fm_backend_list_contains "$2" "$3")" \
    listcontains '' "$2" "$3" '' '' '' ''
}
case_listcontains 'first member'      'tmux herdr zellij' 'tmux'
case_listcontains 'middle member'     'tmux herdr zellij' 'herdr'
case_listcontains 'last member'       'tmux herdr zellij' 'zellij'
case_listcontains 'absent'            'tmux herdr zellij' 'orca'
case_listcontains 'prefix is not a member' 'tmux herdr' 'tmu'
case_listcontains 'suffix is not a member' 'tmux herdr' 'mux'
case_listcontains 'empty name'        'tmux herdr' ''
case_listcontains 'space-bearing name never matches' 'tmux herdr' 'tmux herdr'
case_listcontains 'tab-bearing name never matches' 'tmux herdr' "$(printf 'tmux\therdr')"
case_listcontains 'empty list'        '' 'tmux'

case_isknown() {  # <label> <name>
  add_case "backend:is-known $1" "$(yesno fm_backend_is_known "$2")" isknown '' "$2" '' '' '' '' ''
}
for b in tmux herdr zellij orca cmux; do case_isknown "$b" "$b"; done
case_isknown 'codex-app stays blocked' 'codex-app'
case_isknown 'bogus' 'bogus'
case_isknown 'empty' ''
case_isknown 'uppercase is a different name' 'TMUX'

case_validate() {  # <label> <name>
  local v e
  v=$(yesno fm_backend_validate "$2")
  e=''
  IFS= read -r -d '' e < "$ERRCAP" || true
  add_case "backend:validate $1" "$v|$(first_line "$e")" validate '' "$2" '' '' '' '' ''
}
case_validate 'tmux accepted' tmux
case_validate 'orca accepted' orca
case_validate 'bogus refused loudly' bogus
case_validate 'codex-app refused loudly' codex-app
case_validate 'multi-token name refused' 'tmux herdr'

case_validatespawn() {  # <label> <name>
  local v e
  v=$(yesno fm_backend_validate_spawn "$2")
  e=''
  IFS= read -r -d '' e < "$ERRCAP" || true
  add_case "backend:validate-spawn $1" "$v|$(first_line "$e")" validatespawn '' "$2" '' '' '' '' ''
}
for b in tmux herdr zellij orca cmux; do case_validatespawn "$b is spawn-capable" "$b"; done
case_validatespawn 'bogus keeps the unknown-backend refusal' bogus
case_validatespawn 'codex-app keeps the blocked contract' codex-app

case_reqtools() {  # <label> <name>
  local out
  run_oracle fm_backend_required_tools "$2"
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<none>'; fi
  add_case "backend:required-tools $1" "$out" reqtools '' "$2" '' '' '' '' ''
}
for b in tmux herdr zellij orca cmux; do case_reqtools "$b" "$b"; done
case_reqtools 'unknown backend has no tool set' bogus

case_reqtool() {  # <label> <name> <tool>
  add_case "backend:required-tool-available $1" "$(yesno fm_backend_required_tool_available "$2" "$3")" \
    reqtool '' "$2" "$3" '' '' '' ''
}
case_reqtool 'tmux does not require jq' tmux jq
case_reqtool 'orca does not require treehouse' orca treehouse
case_reqtool 'unknown backend requires nothing' bogus tmux

# --- endpoint atoms and meta records (backend:) --------------------------------

case_atom() {  # <label> <value>
  add_case "backend:endpoint-atom $1" "$(yesno fm_backend_endpoint_atom_valid "$2")" atom '' "$2" '' '' '' '' ''
}
case_atom 'plain word' 'session1'
case_atom 'every permitted class' 'A.z0_9-x@y%p+q'
case_atom 'empty is rejected' ''
case_atom 'colon is rejected' 'a:b'
case_atom 'slash is rejected' 'a/b'
case_atom 'space is rejected' 'a b'
case_atom 'newline is rejected' "$(printf 'a\nb')"
case_atom 'semicolon is rejected' 'a;rm'
case_atom 'underscore is permitted' 'a_b'

case_ofmeta() {  # <label> <meta-basename>
  run_oracle fm_backend_of_meta "$STATE/$2"
  add_case "backend:of-meta $1" "$ORACLE" ofmeta '' "$STATE_N/$2" '' '' '' '' ''
}
case_ofmeta 'absent backend= means tmux' nobackend.meta
case_ofmeta 'explicit herdr' dotfiles-d6.meta
case_ofmeta 'last backend= line wins' lastwins.meta
case_ofmeta 'missing file means tmux' does-not-exist.meta

case_targetofmeta() {  # <label> <meta-basename>
  run_oracle fm_backend_target_of_meta "$STATE/$2"
  add_case "backend:target-of-meta $1" "$ORACLE" targetofmeta '' "$STATE_N/$2" '' '' '' '' ''
}
case_targetofmeta 'tmux reads window=' task1.meta
case_targetofmeta 'orca prefers terminal= over window=' orca-task.meta
case_targetofmeta 'empty window= yields nothing' emptywin.meta

case_metaexact() {  # <label> <meta-basename> <key>
  local out
  run_oracle fm_backend_meta_exact_value "$STATE/$2" "$3"
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<none>'; fi
  add_case "backend:meta-exact $1" "$out" metaexact '' "$STATE_N/$2" "$3" '' '' '' ''
}
case_metaexact 'single occurrence' task1.meta window
case_metaexact 'duplicate key is ambiguous' dupwin.meta window
case_metaexact 'absent key' task1.meta nosuchkey
case_metaexact 'empty value is rejected' emptywin.meta window
case_metaexact 'value keeps every character after the FIRST equals' eqvalue.meta note

# --- selector helpers (backend:) ----------------------------------------------

case_taskid() {  # <label> <raw>
  local out
  run_oracle fm_backend_task_id_for_selector "$2" "$SEL_STATE"
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<none>'; fi
  add_case "backend:task-id-for-selector $1" "$out" taskid '' "$2" "$SEL_STATE_N" '' '' '' ''
}
case_taskid 'exact task id' task1
case_taskid 'legacy fm-<id> label strips the prefix' fm-task1
case_taskid 'exact id that itself starts with fm- wins over stripping' fm-turnend-v9
case_taskid 'a selector with a colon is never a task id' 'sess:win'
case_taskid 'unknown id' nosuchtask
case_taskid 'unknown fm-<id>' fm-nosuchtask

case_metasel() {  # <label> <raw>
  local out
  run_oracle fm_backend_meta_for_selector "$2" "$SEL_STATE"
  if [ "$ORACLE_RC" -eq 0 ] && [ -n "$ORACLE" ]; then out=${ORACLE##*/}; else out='<none>'; fi
  add_case "backend:meta-for-selector $1" "$out" metasel '' "$2" "$SEL_STATE_N" '' '' '' ''
}
case_metasel 'exact id' task1
case_metasel 'legacy label' fm-task1
case_metasel 'unknown' nosuchtask

case_label() {  # <label> <raw>
  run_oracle fm_backend_expected_label_of_selector "$2" "$SEL_STATE"
  add_case "backend:expected-label $1" "$ORACLE" label '' "$2" "$SEL_STATE_N" '' '' '' ''
}
case_label 'exact id gets fm-<id>' task1
case_label 'legacy label keeps its own id' fm-task1
case_label 'exact fm-* id doubles the prefix' fm-turnend-v9
case_label 'unknown selector has no label' nosuchtask

case_metaforwindow() {  # <label> <target>
  local out
  run_oracle fm_backend_meta_for_window "$2" "$SEL_STATE"
  if [ "$ORACLE_RC" -eq 0 ] && [ -n "$ORACLE" ]; then out=${ORACLE##*/}; else out='<none>'; fi
  add_case "backend:meta-for-window $1" "$out" metaforwindow '' "$2" "$SEL_STATE_N" '' '' '' ''
}
case_metaforwindow 'matches window=' 'firstmate:fm-task1'
case_metaforwindow 'matches terminal=' 'term-orca-task'
case_metaforwindow 'no match' 'nobody:here'

case_ofselector() {  # <label> <raw> <resolved>
  run_oracle fm_backend_of_selector "$2" "$3" "$SEL_STATE"
  add_case "backend:of-selector $1" "$ORACLE" ofselector '' "$2" "$3" "$SEL_STATE_N" '' '' ''
}
case_ofselector 'bare task id uses its recorded backend' dotfiles-d6 'default:wA:p2'
case_ofselector 'exact fm-* id resolves before stripping' fm-turnend-v9 'default:wB:p3'
case_ofselector 'explicit target matching metadata inherits its backend' 'default:wA:p2' 'default:wA:p2'
case_ofselector 'tmux-shaped target with no backend= defaults to tmux' 'firstmate:fm-task1' 'firstmate:fm-task1'
case_ofselector 'a target outside this home keeps the tmux default' 'manual:outside' 'manual:outside'
case_ofselector 'orca terminal handle inherits orca' 'term-orca-task' 'term-orca-task'

# --- endpoint validation, the refusal surface (backend:) -----------------------

# NOT through the `yesno` helper, and that is the whole point of this case.
# fm_backend_validate_task_endpoint publishes its second and third values in
# FM_BACKEND_VALIDATED_BACKEND / FM_BACKEND_VALIDATED_TARGET, and a bash
# function called inside `$( ... )` runs in a SUBSHELL where those assignments
# cannot escape - the exact limitation the PowerShell twin removes by returning
# one hashtable. So the oracle is invoked directly, in this shell.
case_endpoint() {  # <label> <meta-basename> <id>
  local v e
  FM_BACKEND_VALIDATED_BACKEND=''
  FM_BACKEND_VALIDATED_TARGET=''
  if fm_backend_validate_task_endpoint "$STATE/$2" "$3" > "$CAP" 2> "$ERRCAP"; then v=yes; else v=no; fi
  e=''
  IFS= read -r -d '' e < "$ERRCAP" || true
  add_case "backend:validate-endpoint $1" \
    "$v|$FM_BACKEND_VALIDATED_BACKEND|$FM_BACKEND_VALIDATED_TARGET|$(first_line "$e")" \
    endpoint '' "$STATE_N/$2" "$3" '' '' '' ''
}
case_endpoint 'a well-formed tmux record validates' task1.meta task1
case_endpoint 'a herdr record validates through its bound ids' herdrok.meta herdrok
case_endpoint 'a cmux record validates' cmuxok.meta cmuxok
case_endpoint 'an orca record reports the TERMINAL as the target' orca-task.meta orca-task
case_endpoint 'a zellij record with a non-numeric tab id is refused' zellijbad.meta zellijbad
case_endpoint 'a binding for another task is refused' badbinding.meta badbinding
case_endpoint 'an unknown backend identity is refused' badbackend.meta badbackend
case_endpoint 'an ambiguous window is refused' dupwin.meta dupwin
case_endpoint 'a tmux window that does not carry the task id is refused' task1.meta othertask
case_endpoint 'a TAB in the metadata is refused as malformed' tabmeta.meta tabmeta
case_endpoint 'a missing metadata file is refused' nosuch.meta nosuch
case_endpoint 'an invalid task id is refused' task1.meta 'bad id'

# --- push capability and adapter loading (backend:) ----------------------------

case_haspush() {  # <label> <name>
  add_case "backend:has-push $1" "$(yesno fm_backend_has_push "$2")" haspush '' "$2" '' '' '' '' ''
}
case_haspush 'herdr pushes' herdr
case_haspush 'tmux does not' tmux
case_haspush 'unknown does not' bogus

# fm_backend_source vs Import-FmBackendAdapter. tmux agrees outright; bogus is
# refused identically. The four unconverted adapters are asserted separately
# below, because that is exactly where the two worlds MUST differ and the
# difference has to be a loud refusal rather than a silent success.
add_case 'backend:adapter-load tmux loads' "$(yesno fm_backend_source tmux)" adapter '' tmux '' '' '' '' ''
add_case 'backend:adapter-load bogus is refused' "$(yesno fm_backend_source bogus)" adapter '' bogus '' '' '' '' ''

# --- composer structure, the fork-free half of fm-tmux-lib (lib:) --------------

case_edge() {  # <label> <row>
  add_case "lib:composer-edge $1" "$(yesno fm_tmux_row_has_composer_edge "$2")" edge '' "$2" '' '' '' '' ''
}
case_edge 'left vertical bar' "$(printf '│ text')"
case_edge 'right vertical bar' "$(printf 'text │')"
case_edge 'rounded top-left' "$(printf '╭──')"
case_edge 'rounded bottom-right' "$(printf '──╯')"
case_edge 'heavy vertical' "$(printf '┃ x')"
case_edge 'double vertical' "$(printf '║ x')"
case_edge 'horizontal rule' "$(printf '───')"
case_edge 'ascii pipe' '| x'
case_edge 'ascii plus' '+---+'
case_edge 'plain text is not structural' 'just some output'
case_edge 'a bare prompt glyph is not structural' '> '
case_edge 'empty row is not structural' ''
case_edge 'whitespace-only row is not structural' '    '
case_edge 'indentation does not hide an edge' "$(printf '   │ x  ')"
case_edge 'an interior bar is not an edge' 'a | b'

case_findbox() {  # <label> <cy> <pane>
  local out
  run_oracle fm_tmux_find_composer_box "$2" "$3"
  if [ "$ORACLE_RC" -eq 0 ]; then out="0 $ORACLE"; else out="$ORACLE_RC"; fi
  add_case "lib:find-composer-box $1" "$out" findbox '' "$2" "$3" '' '' '' ''
}
BOX_TOP=$(printf '╭─────╮')
BOX_MID=$(printf '│ >   │')
BOX_BOT=$(printf '╰─────╯')
BOX_MID_NARROW=$(printf '│ > │')
BOX_TOP_HEAVY=$(printf '┏━━━━━┓')
BOX_MID_HEAVY=$(printf '┃ >   ┃')
BOX_BOT_HEAVY=$(printf '┗━━━━━┛')
case_findbox 'cursor on the content row of a clean box' 1 "$BOX_TOP$LF$BOX_MID$LF$BOX_BOT"
case_findbox 'cursor on the bottom border' 2 "$BOX_TOP$LF$BOX_MID$LF$BOX_BOT"
case_findbox 'cursor on the top border is structurally unsafe' 0 "$BOX_TOP$LF$BOX_MID$LF$BOX_BOT"
case_findbox 'cursor above the box finds nothing' 0 "plain$LF$BOX_TOP$LF$BOX_MID$LF$BOX_BOT"
case_findbox 'cursor below a closed box finds nothing' 3 "$BOX_TOP$LF$BOX_MID$LF$BOX_BOT${LF}after"
case_findbox 'a mismatched content width is ambiguous' 1 "$BOX_TOP$LF$BOX_MID_NARROW$LF$BOX_BOT"
case_findbox 'a heavy box is recognised' 1 "$BOX_TOP_HEAVY$LF$BOX_MID_HEAVY$LF$BOX_BOT_HEAVY"
case_findbox 'a mixed-family box is not a box' 1 "$BOX_TOP$LF$BOX_MID_HEAVY$LF$BOX_BOT"
case_findbox 'a box with no content rows is not a box' 1 "$BOX_TOP$LF$BOX_BOT"
case_findbox 'an unclosed box over the cursor is unsafe' 1 "$BOX_TOP$LF$BOX_MID$LF$BOX_MID"
case_findbox 'an ascii box is recognised' 1 "+---+$LF| > |$LF+---+"
case_findbox 'indented content makes the geometry ambiguous' 1 "$BOX_TOP$LF  $BOX_MID$LF$BOX_BOT"
case_findbox 'two boxes: the one containing the cursor wins' 4 "$BOX_TOP$LF$BOX_MID$LF$BOX_BOT$LF$BOX_TOP$LF$BOX_MID$LF$BOX_BOT"
case_findbox 'an empty pane has no box' 0 ''
case_findbox 'plain output has no box' 0 "line one${LF}line two"
case_findbox 'a stray bottom border on the cursor row is unsafe' 1 "plain$LF$BOX_BOT"

case_geom() {  # <label> <content>
  local out
  run_oracle fm_tmux_composer_geometry_spaces "$2"
  if [ "$ORACLE_RC" -eq 0 ]; then out="0|$ORACLE"; else out="1|"; fi
  add_case "lib:geometry-spaces $1" "$out" geom '' "$2" '' '' '' '' ''
}
case_geom 'a leading ascii prompt blanks out' ' >   '
case_geom 'a claude glyph prompt blanks out' " $GLYPH_CLAUDE   "
case_geom 'all spaces' '     '
case_geom 'real text does not blank out' ' > deploy'
case_geom 'a surviving box glyph fails' "$(printf ' │ ')"
case_geom 'empty content' ''

# --- composer row classification (lib:) ----------------------------------------
#
# Rationed: each oracle call forks sed AND awk. These are the shapes where a
# reimplementation would plausibly differ from the shared classifier.
# The per-case environment is applied to the ORACLE as well, not only carried
# in the record. Carrying it only to PowerShell would ask the two worlds
# different questions and read the answer as a conversion bug.
apply_case_env() {  # <KEY=VALUE or empty>
  CASE_ENV_KEY=
  [ -n "$1" ] || return 0
  CASE_ENV_KEY=${1%%=*}
  export "$CASE_ENV_KEY=${1#*=}"
}
clear_case_env() {
  [ -n "$CASE_ENV_KEY" ] || return 0
  unset "$CASE_ENV_KEY"
  CASE_ENV_KEY=
}
CASE_ENV_KEY=

case_rowstate() {  # <label> <raw> <bordered> <allowbusy> [env]
  apply_case_env "${5:-}"
  run_oracle fm_tmux_composer_row_state "$2" "$3" "$4"
  clear_case_env
  add_case "lib:composer-row-state $1" "$ORACLE" rowstate "${5:-}" "$2" "$3" "$4" '' '' ''
}
case_rowstate 'a bordered empty row is empty' "$(printf '│ >   │')" 1 0
case_rowstate 'a bordered row with text is pending' "$(printf '│ > fix now │')" 1 0
case_rowstate 'a dim ghost run does not count as input' "$(printf '│ > \033[2mghost\033[0m │')" 1 0
case_rowstate 'a bare shell glyph is unknown, never empty' '>' 0 0
case_rowstate 'a bare agent glyph is empty' "$GLYPH_CLAUDE" 0 0
case_rowstate 'a busy footer converts to empty when allowed' 'esc to interrupt' 0 1
case_rowstate 'the same footer stays pending when busy is not allowed' 'esc to interrupt' 0 0
case_rowstate 'an FM_BUSY_REGEX override is honoured' 'brewing tea' 0 1 'FM_BUSY_REGEX=brewing'
case_rowstate 'an FM_COMPOSER_IDLE_RE placeholder reads as empty' "$(printf '│ > Type a message... │')" 1 0 'FM_COMPOSER_IDLE_RE=^Type a message'

# --- busy-footer matching (lib:) -----------------------------------------------

case_busyline() {  # <label> <text> <harness> [env]
  local v
  apply_case_env "${4:-}"
  if printf '%s' "$2" | fm_busy_lines_match "$3" >/dev/null 2>&1; then v=yes; else v=no; fi
  clear_case_env
  add_case "lib:busy-lines $1" "$v" busyline "${4:-}" "$2" "$3" '' '' '' ''
}
case_busyline 'claude spinner with elapsed time' "$(printf '✦ Pollinating… (16s · thought for 1s)')" claude
case_busyline 'claude idle Worked-for line is not busy' "$(printf '✻ Worked for 31s')" claude
case_busyline 'claude ignores the grok cancel footer' 'Ctrl+c:cancel' claude
case_busyline 'claude ignores the opencode footer' 'esc interrupt' claude
case_busyline 'codex escape footer is busy' 'esc to interrupt' codex
case_busyline 'opencode interrupt footer is busy' 'esc interrupt' opencode
case_busyline 'pi Working footer is busy' 'Working...' pi
case_busyline 'pi-signed shares the pi footer' 'Working...' pi-signed
case_busyline 'grok cancel footer is busy' 'Ctrl+c:cancel' grok
case_busyline 'kimi ignores the pi footer' 'Working...' kimi
case_busyline 'kimi ignores the grok footer' 'Ctrl+c:cancel' kimi
# KIMI IS THE ONE CASE WHERE BASH IS NOT THE ORACLE, and the reason is a
# platform defect rather than a design choice. Kimi has no stable ASCII busy
# token, so its signature is an anchored moon-phase spinner - and those glyphs
# are ASTRAL (U+1F311.., four UTF-8 bytes each). GNU grep 3.0 as shipped with
# Git Bash cannot match a four-byte UTF-8 sequence at all: verified on this host
# that even a bare-glyph `grep -E` fails against a line containing exactly those
# bytes, under LANG=en_GB.UTF-8 and under C.UTF-8 alike. So the bash twin reports
# every Kimi pane IDLE on Windows, while the PowerShell twin - whose regex engine
# is UTF-16-native - reports busy, which is what a Linux bash also reports.
#
# The twin is deliberately NOT taught to reproduce the defect: a busy Kimi read
# as idle is a supervision error, and porting a platform bug forward would make
# the PowerShell tree wrong everywhere to keep one host self-consistent. The
# divergence is asserted in BOTH directions instead, so it stays visible and so
# a future grep that fixes this fails here rather than passing silently.
ASSERTIONS=$((ASSERTIONS + 1))
KIMI_SPIN="$MOON $MIDDOT thinking"
if printf '%s' "$KIMI_SPIN" | fm_busy_lines_match kimi >/dev/null 2>&1; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}lib:busy-lines kimi: the bash twin now MATCHES the astral moon spinner on this host
  (MSYS grep appears to have gained four-byte UTF-8 support; the documented divergence above is stale)
"
fi
add_case 'lib:busy-lines kimi moon spinner is busy (PowerShell side of the documented grep divergence)' yes busyline '' "$KIMI_SPIN" kimi '' '' '' ''
case_busyline 'a bare moon glyph without the separator is not busy' "$MOON thinking" kimi
case_busyline 'an unregistered harness borrows no signature' 'esc to interrupt' someharness
case_busyline 'the no-harness default keeps the shared signature' 'Working...' ''
case_busyline 'an FM_BUSY_REGEX override wins' 'custom marker' claude 'FM_BUSY_REGEX=custom marker'
case_busyline 'match is per line, not per blob' "quiet${LF}esc to interrupt" codex
case_busyline 'empty input is never busy' '' claude

# --- runtime auto-detection (backend:) ----------------------------------------
#
# Every case pins TMUX, HERDR_ENV, CMUX_WORKSPACE_ID and __CFBundleIdentifier
# explicitly, and points PATH at a uname fake, so a result never depends on the
# runtime this suite itself happens to be executing inside - a real herdr pane
# and a real tmux pane are both normal cases for a captain.
# GNU env takes its OPTIONS BEFORE any assignment: `env FOO=1 -u BAR cmd`
# treats -u as the UTILITY and fails with "-u: No such file or directory"
# (verified on this host). So every -u below precedes every assignment.
case_detect() {  # <label> <env-spec> <bash-env-assignments...>
  local label=$1 spec=$2
  shift 2
  run_oracle env "$@" bash -c 'set -u; . "$0"; if fm_backend_detect >/dev/null; then printf "%s|%s" "$FM_BACKEND_DETECTED" "$FM_BACKEND_DETECT_SIGNAL"; else printf "|"; fi' "$ROOT/bin/fm-backend.sh"
  add_case "backend:detect $label" "$ORACLE" detect "$spec" '' '' '' '' '' ''
}
ENV_CLEAR="TMUX=${US}HERDR_ENV=${US}CMUX_WORKSPACE_ID=${US}__CFBundleIdentifier="
case_detect 'no markers on a non-Darwin host is undetected' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N" \
  -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH"
case_detect 'TMUX alone selects tmux' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}TMUX=fake,1,0" \
  -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" TMUX=fake,1,0
case_detect 'HERDR_ENV=1 alone selects herdr' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}HERDR_ENV=1" \
  -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" HERDR_ENV=1
case_detect 'HERDR_ENV=0 is not the marker' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}HERDR_ENV=0" \
  -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" HERDR_ENV=0
case_detect 'CMUX_WORKSPACE_ID alone selects cmux' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}CMUX_WORKSPACE_ID=fake-uuid" \
  -u TMUX -u HERDR_ENV -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" CMUX_WORKSPACE_ID=fake-uuid
case_detect 'nesting resolves innermost-first: tmux over herdr' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}TMUX=fake,1,0${US}HERDR_ENV=1" \
  -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" TMUX=fake,1,0 HERDR_ENV=1
case_detect 'nesting resolves innermost-first: herdr over cmux' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}HERDR_ENV=1${US}CMUX_WORKSPACE_ID=fake-uuid" \
  -u TMUX -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" HERDR_ENV=1 CMUX_WORKSPACE_ID=fake-uuid
case_detect 'all three markers still resolve to tmux' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}TMUX=fake,1,0${US}HERDR_ENV=1${US}CMUX_WORKSPACE_ID=fake-uuid" \
  -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" TMUX=fake,1,0 HERDR_ENV=1 CMUX_WORKSPACE_ID=fake-uuid
case_detect 'the bundle-id fallback fires only on Darwin' \
  "${ENV_CLEAR}${US}PATH=$FB_DARWIN_N${US}__CFBundleIdentifier=com.cmuxterm.app" \
  -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID PATH="$FB_DARWIN:$PATH" __CFBundleIdentifier=com.cmuxterm.app
case_detect 'the same bundle id is inert on a non-Darwin host' \
  "${ENV_CLEAR}${US}PATH=$FB_LINUX_N${US}__CFBundleIdentifier=com.cmuxterm.app" \
  -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID PATH="$FB_LINUX:$PATH" __CFBundleIdentifier=com.cmuxterm.app
case_detect 'a foreign bundle id never detects cmux' \
  "${ENV_CLEAR}${US}PATH=$FB_DARWIN_N${US}__CFBundleIdentifier=com.apple.Terminal" \
  -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID PATH="$FB_DARWIN:$PATH" __CFBundleIdentifier=com.apple.Terminal
case_detect 'TMUX absorbs an inherited cmux bundle id' \
  "${ENV_CLEAR}${US}PATH=$FB_DARWIN_N${US}TMUX=fake,1,0${US}__CFBundleIdentifier=com.cmuxterm.app" \
  -u HERDR_ENV -u CMUX_WORKSPACE_ID PATH="$FB_DARWIN:$PATH" TMUX=fake,1,0 __CFBundleIdentifier=com.cmuxterm.app

# --- resolved backend name and its notices (backend:) --------------------------

case_backendname() {  # <label> <config-posix> <config-native> <env-spec> <bash-env...>
  local label=$1 cfgn=$3 spec=$4
  local cfg=$2
  shift 4
  run_oracle env "$@" FM_BACKEND_CONFIG_DIR="$cfg" bash -c 'set -u; . "$0"; FM_BACKEND_CONFIG_DIR="$1" fm_backend_name' "$ROOT/bin/fm-backend.sh" "$cfg"
  add_case "backend:name $label" "$ORACLE|$(first_line "$ORACLE_ERR")" backendname "$spec" "$cfgn" '' '' '' '' ''
}
case_backendname 'no env, no config, no markers -> tmux, silently' \
  "$CFG_EMPTY" "$CFG_EMPTY_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH"
case_backendname 'FM_BACKEND wins outright' \
  "$CFG_TMUX" "$CFG_TMUX_N" "${ENV_CLEAR}${US}FM_BACKEND=zellij${US}PATH=$FB_LINUX_N" \
  -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" FM_BACKEND=zellij
case_backendname 'config/backend is read when FM_BACKEND is empty' \
  "$CFG_TMUX" "$CFG_TMUX_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH"
case_backendname 'blank and indented config lines are skipped' \
  "$CFG_PAD" "$CFG_PAD_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH"
case_backendname 'a CRLF config file still resolves' \
  "$CFG_CRLF" "$CFG_CRLF_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH"
case_backendname 'config beats an ambient herdr marker' \
  "$CFG_TMUX" "$CFG_TMUX_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}HERDR_ENV=1${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" HERDR_ENV=1
case_backendname 'auto-detected herdr prints the experimental notice' \
  "$CFG_EMPTY" "$CFG_EMPTY_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}HERDR_ENV=1${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" HERDR_ENV=1
case_backendname 'auto-detected tmux stays silent' \
  "$CFG_EMPTY" "$CFG_EMPTY_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}TMUX=fake,1,0${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u HERDR_ENV -u CMUX_WORKSPACE_ID -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" TMUX=fake,1,0
case_backendname 'the primary cmux marker names itself in the notice' \
  "$CFG_EMPTY" "$CFG_EMPTY_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}CMUX_WORKSPACE_ID=fake-uuid${US}PATH=$FB_LINUX_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u __CFBundleIdentifier PATH="$FB_LINUX:$PATH" CMUX_WORKSPACE_ID=fake-uuid
case_backendname 'a fallback-detected cmux names the FALLBACK signal' \
  "$CFG_EMPTY" "$CFG_EMPTY_N" "${ENV_CLEAR}${US}FM_BACKEND=${US}__CFBundleIdentifier=com.cmuxterm.app${US}PATH=$FB_DARWIN_N" \
  -u FM_BACKEND -u TMUX -u HERDR_ENV -u CMUX_WORKSPACE_ID PATH="$FB_DARWIN:$PATH" __CFBundleIdentifier=com.cmuxterm.app

# =============================================================================
# PHASE 2 - the tmux-driven cases, through the fake on PATH.
#
# Rationed hard: each case below costs one child process per tmux invocation in
# EACH world, and this host charges seconds for one. What is here is what cannot
# be reached without a process: the command SHAPES, the exit-status handling, the
# recovery-grade agent-state classification, and the retry-Enter submit loop.
# =============================================================================

BASH_TMUX_LOG="$TMP_ROOT/tmux-bash.log"
PS_TMUX_LOG="$TMP_ROOT/tmux-ps.log"
PS_TMUX_LOG_N=$(fm_test_native_path "$PS_TMUX_LOG")
: > "$BASH_TMUX_LOG"
: > "$PS_TMUX_LOG"

TMUX_ENV="PATH=$FAKEBIN_N${US}FM_TMUX_LOG=$PS_TMUX_LOG_N${US}TMUX="

SAVED_PATH=$PATH
PATH="$FAKEBIN:$PATH"
export PATH
export FM_TMUX_LOG="$BASH_TMUX_LOG"
SAVED_TMUX=${TMUX-}
SAVED_HAD_TMUX=${TMUX+set}
unset TMUX

case_capture() {  # <label> <target> <lines>
  local out
  run_oracle fm_backend_tmux_capture "$2" "$3"
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<null>'; fi
  add_case "tmux:capture $1" "$out" capture "$TMUX_ENV" "$2" "$3" '' '' '' ''
}
case_capture 'a readable pane returns its raw bytes' 'sess1:fm-x' 25
case_capture 'an unreadable pane fails rather than returning empty' 'nofix:fm-x' 25

run_oracle fm_backend_tmux_current_path 'sess1:fm-x'
rstrip_oracle
add_case 'tmux:current-path a readable pane reports its cwd' "$ORACLE" curpath "$TMUX_ENV" 'sess1:fm-x' '' '' '' '' ''
run_oracle fm_backend_tmux_current_path 'nofix:fm-x'
rstrip_oracle
add_case 'tmux:current-path an unreadable pane reports empty' "$ORACLE" curpath "$TMUX_ENV" 'nofix:fm-x' '' '' '' '' ''

case_curcomm() {  # <label> <target>
  local out
  run_oracle fm_backend_tmux_current_command "$2"
  rstrip_oracle
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<null>'; fi
  add_case "tmux:current-command $1" "$out" curcomm "$TMUX_ENV" "$2" '' '' '' '' ''
}
case_curcomm 'a readable pane reports its foreground command' 'sess1:fm-x'
case_curcomm 'an unreadable pane fails' 'nofix:fm-x'

add_case 'tmux:send-key a verified target is keyed' \
  "$(yesno fm_backend_tmux_send_key 'sess1:fm-x' Escape)" sendkey "$TMUX_ENV" 'sess1:fm-x' Escape '' '' '' ''
# Driven under `set -e`, which is the contract every real caller runs with
# (bin/fm-send.sh and bin/fm-spawn.sh both open with `set -eu`). The BARE bash
# function does not abort on a failed target probe - it falls through and sends
# the key anyway - so comparing the bare call would assert that a PowerShell
# twin must key an UNVERIFIED target. The probe exists precisely because tmux
# silently falls back to the active window, i.e. to whatever the captain is
# looking at, so the twin refuses and the oracle is asked the same question the
# production caller asks.
run_oracle bash -c 'set -eu; . "$0"; fm_backend_source tmux; fm_backend_tmux_send_key "$1" "$2"' "$ROOT/bin/fm-backend.sh" 'nofix:fm-x' Escape
if [ "$ORACLE_RC" -eq 0 ]; then SENDKEY_FAIL=yes; else SENDKEY_FAIL=no; fi
add_case 'tmux:send-key an unverifiable target refuses before sending' \
  "$SENDKEY_FAIL" sendkey "$TMUX_ENV" 'nofix:fm-x' Escape '' '' '' ''
add_case 'tmux:send-text-line sends the line and Enter' \
  "$(yesno fm_backend_tmux_send_text_line 'sess1:fm-x' 'treehouse get fm-x')" \
  textline "$TMUX_ENV" 'sess1:fm-x' 'treehouse get fm-x' '' '' '' ''
add_case 'tmux:send-literal sends text with no submission' \
  "$(yesno fm_backend_tmux_send_literal 'sess1:fm-x' 'hello captain fix findings 1 and 3')" \
  literal "$TMUX_ENV" 'sess1:fm-x' 'hello captain fix findings 1 and 3' '' '' '' ''

case_kill() {  # <label> <target>
  add_case "tmux:kill $1" "$(yesno fm_backend_tmux_kill "$2")" kill "$TMUX_ENV" "$2" '' '' '' '' ''
}
case_kill 'a well-formed target is killed' 'sess1:fm-x'
case_kill 'a target with no colon is refused' 'nocolon'
case_kill 'a target with two colons is refused' 'a:b:c'
case_kill 'an empty session is refused' ':fm-x'
case_kill 'an empty window is refused' 'sess1:'
case_kill 'an empty target is refused' ''

case_bareselector() {  # <label> <name>
  local out
  run_oracle fm_backend_tmux_resolve_bare_selector "$2"
  rstrip_oracle
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<none>'; fi
  add_case "tmux:bare-selector $1" "$out|$(first_line "$ORACLE_ERR")" bareselector "$TMUX_ENV" "$2" '' '' '' '' ''
}
case_bareselector 'a live window is found by name' 'adhoc'
case_bareselector 'an absent window is refused loudly' 'no-such-window-xyz'

# The recovery-grade classifier. Only `dead` and `missing` license recovery, so
# every one of these verdicts is load-bearing.
case_agentstate() {  # <label> <target>
  run_oracle fm_backend_tmux_agent_state "$2"
  add_case "tmux:agent-state $1" "$ORACLE" agentstate "$TMUX_ENV" "$2" '' '' '' '' ''
}
case_agentstate 'a harness in a listed window is alive' 'alive:fm-x'
case_agentstate 'a login shell in a listed window is dead' 'deadsh:fm-x'
case_agentstate 'an unrecognised command is ambiguous, never dead' 'amb:fm-x'
case_agentstate 'a window absent from a readable inventory is missing' 'nowin:fm-x'
case_agentstate 'a definitive missing-session response is missing' 'gone:fm-x'
case_agentstate 'any other inventory failure is unreadable, never missing' 'broke:fm-x'
case_agentstate 'an empty foreground command is unreadable' 'emptycomm:fm-x'
case_agentstate 'a malformed target is unreadable' 'nocolon'
case_agentstate 'a three-part target is unreadable' 'a:b:c'

run_oracle fm_backend_tmux_agent_alive 'gone:fm-x'
add_case 'tmux:agent-alive a missing endpoint collapses to dead' "$ORACLE" agentalive "$TMUX_ENV" 'gone:fm-x' '' '' '' '' ''
run_oracle fm_backend_tmux_agent_alive 'amb:fm-x'
add_case 'tmux:agent-alive an ambiguous endpoint collapses to unknown' "$ORACLE" agentalive "$TMUX_ENV" 'amb:fm-x' '' '' '' '' ''

# Container and window creation.
run_oracle fm_backend_tmux_container_ensure
add_case 'tmux:container-ensure with no ambient session it ensures firstmate' "$ORACLE" container "$TMUX_ENV" '' '' '' '' '' ''

case_createtask() {  # <label> <session> <window> <path>
  local out
  run_oracle fm_backend_tmux_create_task "$2" "$3" "$4"
  rstrip_oracle
  if [ "$ORACLE_RC" -eq 0 ]; then out=$ORACLE; else out='<none>'; fi
  add_case "tmux:create-task $1" "$out|$(first_line "$ORACLE_ERR")" createtask "$TMUX_ENV" "$2" "$3" "$4" '' '' ''
}
case_createtask 'an existing window name is refused with its session prefix' container fm-existing '/proj/alpha'
case_createtask 'a fresh window returns its stable window id' container fm-fresh '/proj/alpha'

# Composer state through real tmux reads.
case_composerstate() {  # <label> <target>
  run_oracle fm_tmux_composer_state "$2"
  add_case "lib:composer-state $1" "$ORACLE" composerstate "$TMUX_ENV" "$2" '' '' '' '' ''
}
case_composerstate 'a proven-empty bordered composer is empty' 'cempty:fm-x'
case_composerstate 'a bordered composer holding text is pending' 'cpend:fm-x'
case_composerstate 'a ghost-only composer is still empty' 'cghost:fm-x'
case_composerstate 'an unreadable pane is unknown' 'nofix:fm-x'

case_panebusy() {  # <label> <target> <harness>
  add_case "lib:pane-busy $1" "$(yesno fm_pane_is_busy "$2" "$3")" panebusy "$TMUX_ENV" "$2" "$3" '' '' '' ''
}
case_panebusy 'a busy footer in the tail reads busy' 'busyc:fm-x' codex
case_panebusy 'an idle tail does not' 'idlec:fm-x' claude
case_panebusy 'an unreadable pane is not busy' 'nofix:fm-x' claude

# Dispatch through fm-backend, so the dispatcher's own arms are covered too.
run_oracle fm_backend_capture tmux 'sess1:fm-x' 25 'fm-x'
add_case 'backend:dispatch-capture routes tmux with its label argument' "$ORACLE" \
  dispatchcapture "$TMUX_ENV" tmux 'sess1:fm-x' 25 'fm-x' '' ''
run_oracle fm_backend_composer_state tmux 'cpend:fm-x'
add_case 'backend:dispatch-composer routes tmux to the shared classifier' "$ORACLE" \
  composerdispatch "$TMUX_ENV" tmux 'cpend:fm-x' '' '' '' ''
run_oracle fm_backend_busy_state tmux 'sess1:fm-x'
add_case 'backend:dispatch-busy tmux has no native busy primitive' "$ORACLE" \
  busystate "$TMUX_ENV" tmux 'sess1:fm-x' '' '' '' ''
run_oracle fm_backend_agent_state tmux 'gone:fm-x'
add_case 'backend:dispatch-agent-state routes tmux' "$ORACLE" \
  dispatchagent "$TMUX_ENV" tmux 'gone:fm-x' '' '' '' ''
add_case 'backend:dispatch-target-exists a readable pane exists' \
  "$(yesno fm_backend_target_exists tmux 'sess1:fm-x' 'fm-x')" exists "$TMUX_ENV" tmux 'sess1:fm-x' 'fm-x' '' '' ''
add_case 'backend:dispatch-target-exists an unreadable pane does not' \
  "$(yesno fm_backend_target_exists tmux 'nofix:fm-x' 'fm-x')" exists "$TMUX_ENV" tmux 'nofix:fm-x' 'fm-x' '' '' ''
add_case 'backend:dispatch-kill refuses an empty target before loading an adapter' \
  "$(yesno fm_backend_kill tmux '')" killdispatch "$TMUX_ENV" tmux '' '' '' '' ''
add_case 'backend:dispatch-kill kills a well-formed target' \
  "$(yesno fm_backend_kill tmux 'sess1:fm-x')" killdispatch "$TMUX_ENV" tmux 'sess1:fm-x' '' '' '' ''

# The ad hoc bare-name fallback, end to end through the dispatcher.
run_oracle fm_backend_resolve_selector 'adhoc' "$SEL_STATE"
rstrip_oracle
add_case 'backend:resolve-selector an ad hoc bare name falls back to the live inventory' \
  "$ORACLE|$(first_line "$ORACLE_ERR")" resolvesel "$TMUX_ENV" 'adhoc' "$SEL_STATE_N" '' '' '' ''
run_oracle fm_backend_resolve_selector 'fm-nosuchtask' "$SEL_STATE"
rstrip_oracle
# The REFUSAL path, so the oracle is recorded with the same absent-value marker
# the driver emits: bash signals it by returning non-zero with empty stdout, the
# twin by returning $null, and the two must not be compared as '' against
# '<none>' - that would read as a divergence in a case that agrees.
if [ "$ORACLE_RC" -eq 0 ]; then RESOLVE_MISS=$ORACLE; else RESOLVE_MISS='<none>'; fi
add_case 'backend:resolve-selector an fm-* selector with no record is refused, never searched' \
  "$RESOLVE_MISS|$(first_line "$ORACLE_ERR")" resolvesel "$TMUX_ENV" 'fm-nosuchtask' "$SEL_STATE_N" '' '' '' ''
run_oracle fm_backend_resolve_selector 'sess:win' "$SEL_STATE"
rstrip_oracle
add_case 'backend:resolve-selector an explicit target is used literally' \
  "$ORACLE|$(first_line "$ORACLE_ERR")" resolvesel "$TMUX_ENV" 'sess:win' "$SEL_STATE_N" '' '' '' ''

# THE SUBMIT CORE. The composer keeps reading `pending` because the fake always
# swallows the Enter, so the retry budget is spent and the busy tail converts the
# verdict to `empty` - the opencode busy-queued case. What must NOT happen is a
# retyped instruction, which is why the argv log comparison below is the real
# assertion here: exactly ONE `-l` send may appear.
run_oracle fm_tmux_submit_core 'swal:fm-x' 'fix findings 1 and 3' 2 0 0
add_case 'lib:submit busy pane plus swallowed Enter reports empty after the budget' "$ORACLE" \
  submit "$TMUX_ENV" 'swal:fm-x' 'fix findings 1 and 3' 2 0 0 ''
BASH_ENTER_COUNT=$(grep -c '^Enter$' "$FAKEBIN/sent-swal" 2>/dev/null || printf '0')

unset FM_TMUX_LOG
PATH=$SAVED_PATH
export PATH
if [ -n "$SAVED_HAD_TMUX" ]; then export TMUX="$SAVED_TMUX"; fi

# =============================================================================
# PHASE 3 - the same whitespace bytes under LC_ALL=C.
#
# bash resolves [[:space:]] against LC_CTYPE, so the trim inside the composer
# row classifier is the one genuinely locale-dependent decision in this package,
# and it is the difference between "empty, safe to inject into" and "pending,
# leave alone". The fixtures were built above from FIXED BYTES so only the
# CLASSIFIER's locale varies here; rebuilding them under C would change the
# bytes and prove nothing.
# =============================================================================
# The locale is carried PER CASE, not exported around the block. A block-level
# export cannot survive here: clear_case_env unsets the variable it applied, so
# the first case would tear the block setting down and every later case would
# run under the ambient locale while still claiming to be a C-locale case.

case_rowstate 'C locale: a NBSP-only bordered row is not empty' \
  "$(printf '│ %s │' "$SP_NBSP")" 1 0 'LC_ALL=C'
case_rowstate 'C locale: an ASCII-space-only bordered row is still empty' \
  "$(printf '│   │')" 1 0 'LC_ALL=C'
case_geomlocale() {  # <label> <content> <env>
  local out
  apply_case_env "$3"
  run_oracle fm_tmux_composer_geometry_spaces "$2"
  clear_case_env
  if [ "$ORACLE_RC" -eq 0 ]; then out="0|$ORACLE"; else out="1|"; fi
  add_case "lib:geometry-spaces $1" "$out" geom "$3" "$2" '' '' '' '' ''
}
case_geomlocale 'C locale: a NBSP survives the blank-geometry sweep' " > $SP_NBSP" 'LC_ALL=C'


# The same two rows under the UTF-8 locale PINNED at the top of this file, so
# the pair proves the trim actually MOVES with the locale rather than being
# hard-coded either way. These carry no per-case locale, so they inherit that
# pin - which is exactly why it is a pin and not an inherited ambient value: a
# non-login MSYS2 shell leaves every locale variable unset, and these two cases
# would then silently re-assert the C rules the block above already covers.
case_rowstate 'pinned UTF-8 locale: a NBSP-only bordered row' "$(printf '│ %s │' "$SP_NBSP")" 1 0
case_geom 'pinned UTF-8 locale: a NBSP in the blank-geometry sweep' " > $SP_NBSP"

# =============================================================================
# THE POWERSHELL DRIVER
#
# One process for every case above. Quoted here-doc: bash expands nothing, so
# the PowerShell source is byte-exact; paths arrive through the environment.
# =============================================================================
cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_MOD_COMMON -Force
Import-Module $env:FM_MOD_TMUXLIB -Force
Import-Module $env:FM_MOD_ADAPTER -Force
Import-Module $env:FM_MOD_BACKEND -Force

$FS = [char]1
$RS = [char]2
$US = [char]31
$NONE = '<none>'
$NULLMARK = '<null>'

# Every environment variable any case touches, snapshotted so a per-case setting
# cannot leak into the next case (the batch trap the port doc names first).
$managed = @('TMUX', 'HERDR_ENV', 'CMUX_WORKSPACE_ID', '__CFBundleIdentifier',
    'FM_BACKEND', 'FM_BACKEND_CONFIG_DIR', 'FM_BUSY_REGEX', 'FM_COMPOSER_IDLE_RE',
    'FM_TMUX_LOG', 'LC_ALL', 'LC_CTYPE', 'LANG')
$original = @{}
foreach ($k in $managed) { $original[$k] = [Environment]::GetEnvironmentVariable($k) }
$originalPath = $env:PATH

function Get-Yesno {
    param([bool]$Value)
    if ($Value) { return 'yes' }
    return 'no'
}

function Get-FirstLine {
    param([AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $i = $Text.IndexOf("`n")
    if ($i -ge 0) { return $Text.Substring(0, $i) }
    return $Text
}

# [object], NOT [string]: binding $null to a [string] parameter COERCES it to
# the empty string, so a typed helper can never tell "no answer" from "an empty
# answer" - which is precisely the distinction these two markers exist to keep.
function Get-OrNone {
    param([AllowNull()][object]$Text)
    if ($null -eq $Text) { return $NONE }
    return [string]$Text
}

# Two absent-value markers, kept visibly distinct: `<none>` means the function
# had no answer, `<null>` means the underlying tmux call failed. Collapsing them
# would let a broken tmux read pass as a legitimate empty result.
function Get-OrNoneNull {
    param([AllowNull()][object]$Text)
    if ($null -eq $Text) { return $NULLMARK }
    return [string]$Text
}

$text = [System.IO.File]::ReadAllText($env:FM_CASES, [System.Text.Encoding]::UTF8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++
    $f = @($record.Split($FS))
    if ($f.Count -ne 8) {
        [void]$out.Append($index).Append($FS).Append("BAD-FIELD-COUNT:$($f.Count)").Append($RS)
        continue
    }

    foreach ($k in $managed) { [Environment]::SetEnvironmentVariable($k, $original[$k]) }
    $env:PATH = $originalPath
    foreach ($entry in @($f[1].Split($US))) {
        if ($entry -ceq '') { continue }
        $eq = $entry.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $entry.Substring(0, $eq)
        $v = $entry.Substring($eq + 1)
        if ($k -ceq 'PATH') { $env:PATH = $v + ';' + $originalPath }
        else { [Environment]::SetEnvironmentVariable($k, $v) }
    }

    # stderr is captured per case rather than for the whole run, so a refusal
    # stays attributable to the case that produced it.
    $sw = [System.IO.StringWriter]::new()
    $oldErr = [Console]::Error
    [Console]::SetError($sw)
    $result = ''
    try {
        switch -CaseSensitive ($f[0]) {
            'listcontains' { $result = Get-Yesno (Test-FmBackendListContains -List $f[2] -Name $f[3]) }
            'isknown' { $result = Get-Yesno (Test-FmBackendKnown $f[2]) }
            'validate' { $result = Get-Yesno (Test-FmBackendValid $f[2]) }
            'validatespawn' { $result = Get-Yesno (Test-FmBackendSpawnValid $f[2]) }
            'reqtools' { $result = Get-OrNone (Get-FmBackendRequiredTool $f[2]) }
            'reqtool' { $result = Get-Yesno (Test-FmBackendRequiredTool -Name $f[2] -Tool $f[3]) }
            'atom' { $result = Get-Yesno (Test-FmBackendEndpointAtom $f[2]) }
            'ofmeta' { $result = Get-FmBackendOfMeta $f[2] }
            'targetofmeta' { $result = Get-FmBackendTargetOfMeta $f[2] }
            'metaexact' { $result = Get-OrNone (Get-FmBackendMetaExactValue -MetaPath $f[2] -Key $f[3]) }
            'taskid' { $result = Get-OrNone (Get-FmBackendTaskIdForSelector -Raw $f[2] -StateDir $f[3]) }
            'metasel' {
                $p = Get-FmBackendMetaForSelector -Raw $f[2] -StateDir $f[3]
                # Compared by BASENAME: the two worlds spell the directory
                # differently, so the full path could never match.
                if ([string]::IsNullOrEmpty($p)) { $result = $NONE }
                else { $result = [System.IO.Path]::GetFileName($p) }
            }
            'label' { $result = Get-FmBackendExpectedLabelOfSelector -Raw $f[2] -StateDir $f[3] }
            'metaforwindow' {
                $p = Get-FmBackendMetaForWindow -Target $f[2] -StateDir $f[3]
                if ([string]::IsNullOrEmpty($p)) { $result = $NONE }
                else { $result = [System.IO.Path]::GetFileName($p) }
            }
            'ofselector' { $result = Get-FmBackendOfSelector -Raw $f[2] -Resolved $f[3] -StateDir $f[4] }
            'endpoint' {
                $v = Get-FmBackendValidatedEndpoint -MetaPath $f[2] -TaskId $f[3]
                $result = '{0}|{1}|{2}' -f (Get-Yesno $v.Ok), $v.Backend, $v.Target
            }
            'haspush' { $result = Get-Yesno (Test-FmBackendHasPush $f[2]) }
            'adapter' { $result = Get-Yesno (Import-FmBackendAdapter $f[2]) }
            'edge' { $result = Get-Yesno (Test-FmTmuxComposerEdge $f[2]) }
            'findbox' {
                $b = Find-FmTmuxComposerBox -CursorY ([int]$f[2]) -Pane $f[3]
                if ($b.Code -eq 0) { $result = '0 {0} {1} {2}' -f $b.Top, $b.Bottom, $b.Ambiguous }
                else { $result = [string]$b.Code }
            }
            'geom' {
                $g = Get-FmTmuxComposerGeometrySpace $f[2]
                if ($null -eq $g) { $result = '1|' } else { $result = '0|' + $g }
            }
            'rowstate' { $result = Get-FmTmuxComposerRowState -Raw $f[2] -Bordered $f[3] -AllowBusy $f[4] }
            'busyline' { $result = Get-Yesno (Test-FmTmuxBusyLine -Text $f[2] -Harness $f[3]) }
            'detect' {
                $d = Get-FmBackendDetected
                $result = '{0}|{1}' -f $d.Backend, $d.Signal
            }
            'backendname' { $result = Get-FmBackendName $f[2] }
            'capture' { $result = Get-OrNoneNull (Get-FmBackendTmuxCapture -Target $f[2] -Lines $f[3]) }
            'curpath' { $result = Get-FmBackendTmuxCurrentPath $f[2] }
            'curcomm' { $result = Get-OrNoneNull (Get-FmBackendTmuxCurrentCommand $f[2]) }
            'sendkey' { $result = Get-Yesno (Send-FmBackendTmuxKey -Target $f[2] -Key $f[3]) }
            'textline' { $result = Get-Yesno (Send-FmBackendTmuxTextLine -Target $f[2] -Text $f[3]) }
            'literal' { $result = Get-Yesno (Send-FmBackendTmuxLiteral -Target $f[2] -Text $f[3]) }
            'kill' { $result = Get-Yesno (Remove-FmBackendTmuxTarget $f[2]) }
            'bareselector' { $result = Get-OrNone (Resolve-FmBackendTmuxBareSelector $f[2]) }
            'agentstate' { $result = Get-FmBackendTmuxAgentState $f[2] }
            'agentalive' { $result = Get-FmBackendTmuxAgentAlive $f[2] }
            'container' { $result = Get-OrNoneNull (Initialize-FmBackendTmuxContainer) }
            'createtask' {
                $result = Get-OrNone (New-FmBackendTmuxTask -Session $f[2] -WindowName $f[3] -ProjectPath $f[4])
            }
            'composerstate' { $result = Get-FmTmuxComposerState $f[2] }
            'panebusy' { $result = Get-Yesno (Test-FmTmuxPaneBusy -Target $f[2] -Harness $f[3]) }
            'submit' {
                $result = Send-FmTmuxSubmit -Target $f[2] -Text $f[3] -Retries $f[4] -EnterSleep $f[5] -Settle $f[6]
            }
            'dispatchcapture' { $result = Get-OrNoneNull (Get-FmBackendCapture -Backend $f[2] -Target $f[3] -Lines $f[4] -ExpectedLabel $f[5]) }
            'composerdispatch' { $result = Get-FmBackendComposerState -Backend $f[2] -Target $f[3] }
            'busystate' { $result = Get-FmBackendBusyState -Backend $f[2] -Target $f[3] }
            'dispatchagent' { $result = Get-FmBackendAgentState -Backend $f[2] -Target $f[3] }
            'exists' { $result = Get-Yesno (Test-FmBackendTargetExists -Backend $f[2] -Target $f[3] -ExpectedLabel $f[4]) }
            'killdispatch' { $result = Get-Yesno (Remove-FmBackendTarget -Backend $f[2] -Target $f[3]) }
            'resolvesel' { $result = Get-OrNone (Resolve-FmBackendSelector -Raw $f[2] -StateDir $f[3]) }
            default { $result = "UNKNOWN-OP:$($f[0])" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    } finally {
        [Console]::SetError($oldErr)
    }
    $errText = $sw.ToString()

    # The ops whose bash twin publishes a diagnostic alongside its value carry
    # the first stderr line in the same field, so a refusal that changed wording
    # fails as loudly as one that changed verdict.
    switch -CaseSensitive ($f[0]) {
        'validate' { $result = $result + '|' + (Get-FirstLine $errText) }
        'validatespawn' { $result = $result + '|' + (Get-FirstLine $errText) }
        'endpoint' { $result = $result + '|' + (Get-FirstLine $errText) }
        'bareselector' { $result = $result + '|' + (Get-FirstLine $errText) }
        'createtask' { $result = $result + '|' + (Get-FirstLine $errText) }
        'resolvesel' { $result = $result + '|' + (Get-FirstLine $errText) }
        'backendname' { $result = $result + '|' + (Get-FirstLine $errText) }
        default { }
    }

    [void]$out.Append($index).Append($FS).Append($result).Append($RS)
}

[Console]::Out.Write($out.ToString())
PS1

# =============================================================================
# RUN
# =============================================================================
install_tmux_fixtures
: > "$PS_TMUX_LOG"

export FM_MOD_COMMON="$MOD_COMMON_N" FM_MOD_TMUXLIB="$MOD_TMUXLIB_N" \
       FM_MOD_ADAPTER="$MOD_ADAPTER_N" FM_MOD_BACKEND="$MOD_BACKEND_N" \
       FM_CASES="$(fm_test_native_path "$CASES")"

if ! pwsh -NoProfile -File "$(fm_test_native_path "$DRIVER")" > "$RESULTS" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A clean run is also a SILENT run. Every diagnostic a case produces is captured
# per case, so anything reaching the real stderr is a module warning (an
# unapproved verb, a shadowed command) and a real finding.
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr"$'\n'"$(cat "$DRIVER_ERR")"

# norm_paths: the ONE place a path may legitimately appear in a compared value.
#
# Several refusals name the record they refused ("no regular endpoint metadata
# at <meta>", "no metadata for <sel> in <state>"), and the two worlds spell that
# directory differently - the trap the port doc names second. Replacing the
# directory with a token on BOTH sides keeps the rest of the message, including
# the leaf file name and the separator, under comparison.
norm_paths() {
  NORMALIZED=$1
  NORMALIZED=${NORMALIZED//"$SEL_STATE_N"/<SEL>}
  NORMALIZED=${NORMALIZED//"$SEL_STATE"/<SEL>}
  NORMALIZED=${NORMALIZED//"$STATE_N"/<STATE>}
  NORMALIZED=${NORMALIZED//"$STATE"/<STATE>}
}

SEEN=0
while IFS=$'\001' read -r -d $'\002' idx got; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  norm_paths "${EXPECT[$idx]}"; want=$NORMALIZED
  norm_paths "$got"; have=$NORMALIZED
  assert_same "${LABELS[$idx]}" "$want" "$have"
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] \
  || fail "driver returned $SEEN results for ${#LABELS[@]} cases (a driver that died halfway returns fewer, which must not read as a shorter passing run)"

# --- the tmux command-sequence differential ----------------------------------
#
# The strongest tmux-side assertion in this file: both worlds ran the same
# scenario through their own fake, and every argument vector must match. This is
# what proves the retry-Enter contract structurally - a twin that RETYPED on
# retry would show extra `-l` sends here even if its verdict happened to agree.
# CR is stripped because cmd `echo` has no LF-only mode.
tr -d '\r' < "$BASH_TMUX_LOG" > "$TMP_ROOT/tmux-bash.norm"
tr -d '\r' < "$PS_TMUX_LOG" > "$TMP_ROOT/tmux-ps.norm"
ASSERTIONS=$((ASSERTIONS + 1))
if ! diff -u "$TMP_ROOT/tmux-bash.norm" "$TMP_ROOT/tmux-ps.norm" > "$TMP_ROOT/tmux-log.diff" 2>&1; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}tmux:command-sequence the two worlds issued different tmux commands
$(cat "$TMP_ROOT/tmux-log.diff")
"
fi
ASSERTIONS=$((ASSERTIONS + 1))
if [ ! -s "$TMP_ROOT/tmux-bash.norm" ]; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}tmux:command-sequence the bash scenario issued no tmux commands at all
"
fi

# The Enter retry budget, counted on both sides. `fix findings 1 and 3` is typed
# ONCE and Enter is retried; a twin that retyped would duplicate a captain
# instruction into a live agent.
PS_ENTER_COUNT=$(grep -c '^Enter$' "$FAKEBIN/sent-swal" 2>/dev/null || printf '0')
assert_same 'lib:submit the Enter retry budget is spent identically' "$BASH_ENTER_COUNT" "$PS_ENTER_COUNT"
ASSERTIONS=$((ASSERTIONS + 1))
if [ "$BASH_ENTER_COUNT" -ne 2 ]; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}lib:submit the bash oracle did not spend the configured 2-Enter budget (got $BASH_ENTER_COUNT)
"
fi

# =============================================================================
# IMPORT HYGIENE - the two things a batch driver cannot observe about itself.
# =============================================================================
import_out=$(pwsh -NoProfile -Command "Import-Module '$MOD_BACKEND_N' -Force; Import-Module '$MOD_ADAPTER_N' -Force" 2>&1)
import_rc=$?
assert_same 'backend:import importing the modules is silent' '' "$import_out"
assert_same 'backend:import importing the modules succeeds' 0 "$import_rc"

# fm_meta_get has NO twin in fm-backend.psm1 on purpose: fm-common owns
# Get-FmMetaValue and a second implementation is exactly the drift this port
# exists to prevent. This asserts the ownership rather than trusting the comment.
meta_owner=$(pwsh -NoProfile -Command \
  "Import-Module '$MOD_BACKEND_N' -Force; \$c = Get-Command Get-FmMetaValue -ErrorAction SilentlyContinue; [Console]::Out.Write(\$(if (\$null -eq \$c) { 'unexported' } else { \$c.ModuleName }))" 2>&1)
assert_same 'backend:meta-get has no competing implementation in fm-backend' 'unexported' "$meta_owner"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W3-backend-core PowerShell twins differ from their bash oracles (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# COUNT is itself asserted. Set from an OBSERVED green run, never a guess.
MIN_ASSERTIONS=245
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-backend.psm1, backends/tmux.psm1 and fm-tmux-lib.psm1 match their bash oracles across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-backend-core-psm1.test.sh: all assertions passed\n'
