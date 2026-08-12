#!/usr/bin/env bash
# Behavior test for the W3-zellij-cmux-orca PowerShell twins:
#
#   bin/backends/zellij.psm1  <- bin/backends/zellij.sh
#   bin/backends/cmux.psm1    <- bin/backends/cmux.sh
#   bin/backends/orca.psm1    <- bin/backends/orca.sh
#
# Every assertion names the adapter it covers with a `zellij:`, `cmux:` or
# `orca:` label prefix, so a failure points at one file.
#
# DIFFERENTIAL: every case drives the bash function and the PowerShell function
# with byte-identical input and asserts byte-identical output. BASH IS THE
# ORACLE - no expectation is hard-coded, so a case can never quietly encode what
# the author believed instead of what the shipped adapter does.
#
# ---------------------------------------------------------------------------
# WHAT MATTERS MOST HERE, AND WHY THE WEIGHTING IS WHAT IT IS.
#
# NONE of these three CLIs exists on this host: cmux is macOS-only by
# construction, and zellij and orca have no verified Windows path. So the ONE
# path a captain on this platform actually reaches is the MISSING-CLI REFUSAL -
# and that is the cheapest possible thing to test, because `command -v` is a
# shell builtin. It is therefore tested hard and first: every adapter's tool
# gate, its exact refusal text, and the binary-resolution rule underneath it.
#
# Everything past that gate is faithful-by-reading, driven through a fake CLI.
# Those cases are RATIONED, because each one costs a child process in EACH world
# and this host charges seconds for one (see COST below).
#
# The three highest-risk behaviours, each given a dedicated case:
#   - cmux's socket password must be read fresh per call and must NEVER override
#     an operator's ambient CMUX_SOCKET_PASSWORD when no file is configured.
#     Exporting an empty value would replace a working password with nothing.
#   - zellij's bare-title fallback must REFUSE when the bare name is ambiguous.
#     Accepting it would let one firstmate home send to, peek at, or close
#     another home's tab, since every home shares one session's tab bar.
#   - Orca's JSON readers encode JavaScript evaluation rules - `||` is falsy
#     coalescing, `??` is nullish, `String(true)` is lowercase - and a plausible
#     rewrite gets each of them subtly wrong in a way no other case would catch.
#
# ---------------------------------------------------------------------------
# TRANSPORT, and the traps this pattern has already sprung in this repo.
#
# All cases are written to a FILE and evaluated by ONE pwsh driver. Fields are
# separated by 0x01 and records by 0x02 - bytes that appear in no fixture - so
# every value crosses as RAW BYTES and the comparison is byte-exact.
#
#   1. PER-CASE ENVIRONMENT DOES NOT SURVIVE THE BATCH. A bash prefix assignment
#      persists after a function call, so by the time the single pwsh runs the
#      shell holds only the LAST value assigned. Env-dependent cases carry their
#      settings in the RECORD and the driver applies and clears them per case -
#      and the same settings are applied to the BASH oracle too, or the two
#      worlds would be asked different questions.
#   2. NEVER KEY A PROBE BY A PATH. The two worlds spell the same location
#      differently, so a key or expected VALUE holding one never matches. Cases
#      are keyed by INDEX and path-shaped values are normalized on both sides.
#   3. NO `( ... )` SUBSHELLS. A failure recorded inside one cannot reach the
#      parent's counters, so it would vanish into a FALSE PASS.
#   4. A `[string]` PARAMETER COERCES $null TO ''. The driver's absent-value
#      helpers take [object], or a twin that correctly returned $null would be
#      indistinguishable from one that returned an empty string.
#
# TRAILING NEWLINES. Several bash twins end in a `jq | head -1` or a `printf
# '%s\n'`, and EVERY bash call site consumes them through `$( ... )`, which
# strips trailing newlines; the PowerShell twins return the value a bash caller
# ends up holding. Both sides are therefore compared with trailing newlines
# stripped. No value in this file legitimately ends in one, so this softens
# nothing - every interior byte still has to match.
#
# ---------------------------------------------------------------------------
# THE FAKE CLIs. One implementation, six files, three names.
#
# Each backend needs `orca`/`zellij`/`cmux` on PATH, and it cannot be one file
# per CLI: verified on this host, .NET's Process.Start does not search PATH for
# a bare name and cannot start an extension-less shebang script at all, while a
# `.cmd` trampoline into Git Bash MANGLES arguments and costs a second process
# per call. So each name exists twice - a bash script (what `command -v` finds)
# and a `.cmd` batch twin (what Get-Command -CommandType Application resolves
# first, by PATHEXT).
#
# Both are FIXTURE-DRIVEN and share one protocol, so the response logic is data
# rather than code: the fake derives a KEY from its own name plus the first one
# or two arguments (`zellij --session S action list-panes` -> `zellij.action-
# list-panes`), then emits `<key>` on stdout, `<key>.err` on stderr, and exits
# with `<key>.rc` (default 0). An absent fixture is an empty successful reply,
# which is exactly the shape zellij's own always-exit-0 CLI has.
#
# They are kept honest three ways rather than by review: they share every
# fixture file, both APPEND THEIR RAW COMMAND LINE to a log whose two copies are
# compared as a first-class assertion, and any divergence in the tiny dispatch
# rule shows up as a verdict mismatch. The command-line log is the strongest
# CLI-side check in this file, because it proves the PowerShell twins issue
# byte-identical CLI invocations - including argument ORDER, which is what a
# rewrite most easily gets wrong.
#
# The log records the WHOLE command line rather than one entry per argument:
# cmd tokenizes `%1` on `=` as well as on space, so a per-argument log could not
# carry an argument containing `=`. `%*` keeps the raw line, and the bash side
# reconstructs the same line under .NET's own quoting rule (an argument is
# quoted iff it contains a space; none here carries a quote or a tab).
#
# ---------------------------------------------------------------------------
# COST, stated because it shapes this file. Measured on this host while the
# fleet was busy: a bash fork is ~3s and a child process started from pwsh is
# ~1.8s, an order of magnitude worse than the ~0.36s the port doc recorded on an
# idle machine. So the free assertions (shell builtins, pure string work) carry
# the bulk of the coverage, the JSON readers - which cost one `node` fork each
# in bash - are chosen rather than enumerated, and the CLI-driven scenarios are
# bounded. pwsh is spawned exactly TWICE. Wall time tracks host load.
#
# ---------------------------------------------------------------------------
# WHAT IS NOT COVERED HERE, so nobody reads a green run as more than it is:
#   - A REAL zellij, cmux or orca. None is installed and none can be; there is
#     no real-CLI smoke test for these three on this platform at all.
#   - Anything that needs a live GUI app: cmux's launch path (`open -a cmux`),
#     focus behaviour, and the last-workspace-in-window teardown exception are
#     exercised only through fixtures that model the documented replies.
#   - Timing and race behaviour: the poll loops are driven with zero sleeps.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in bin/backends/zellij.psm1 bin/backends/cmux.psm1 bin/backends/orca.psm1; do
  [ -f "$ROOT/$f" ] || fail "$f is missing"
done

TMP_ROOT=$(fm_test_tmproot fm-backends-other-psm1)
CAP="$TMP_ROOT/oracle.out"
ERRCAP="$TMP_ROOT/oracle.err"
CASES="$TMP_ROOT/cases.bin"
RESULTS="$TMP_ROOT/results.bin"
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_ERR="$TMP_ROOT/driver.err"

MOD_ZELLIJ_N=$(fm_test_native_path "$ROOT/bin/backends/zellij.psm1")
MOD_CMUX_N=$(fm_test_native_path "$ROOT/bin/backends/cmux.psm1")
MOD_ORCA_N=$(fm_test_native_path "$ROOT/bin/backends/orca.psm1")

LF=$'\n'

# --- assertion bookkeeping ----------------------------------------------------
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
# `read -d ''` reads to NUL, i.e. the whole file, returning non-zero at EOF while
# still assigning - hence `|| true`. Costs no fork, where `$( ... )` costs one.
ORACLE=''
ORACLE_ERR=''
ORACLE_RC=0

run_oracle() {  # <fn> <args...>
  ORACLE=''; ORACLE_ERR=''; ORACLE_RC=0
  "$@" > "$CAP" 2> "$ERRCAP" || ORACLE_RC=$?
  IFS= read -r -d '' ORACLE < "$CAP" || true
  IFS= read -r -d '' ORACLE_ERR < "$ERRCAP" || true
}

first_line() {  # <text>
  printf '%s' "${1%%"$LF"*}"
}

yesno() {  # <fn> <args...>
  if "$@" > "$CAP" 2> "$ERRCAP"; then printf 'yes'; else printf 'no'; fi
}

# The per-case environment must reach the ORACLE as well as the record; see
# trap 1. Carries at most one KEY=VALUE, which is all any case here needs.
CASE_ENV_KEY=
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

# --- case machinery -----------------------------------------------------------
FS=$(printf '\001')
RS=$(printf '\002')

LABELS=()
EXPECT=()

: > "$CASES"

add_case() {  # <label> <expected> <op> <env> <a1..a5>
  LABELS+=("$1")
  EXPECT+=("$2")
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$3" "$FS" "$4" "$FS" "$5" "$FS" "$6" "$FS" "$7" "$FS" "$8" "$FS" "$9" >> "$CASES"
  printf '%s' "$RS" >> "$CASES"
}

# =============================================================================
# THE FAKE CLIs
# =============================================================================
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
FAKEBIN_N=$(fm_test_native_path "$FAKEBIN")
FIX="$FAKEBIN"

cat > "$FAKEBIN/.fake-cli" <<'SH'
#!/usr/bin/env bash
# Fixture-driven fake CLI (bash side). Twin: .fake-cli.cmd, copied to each
# backend's own name. Fixtures live beside this file, keyed by "<cli>.<key>".
d=${0%/*}
n=${0##*/}
raw=
for a in "$@"; do
  # .NET quotes an argument iff it is EMPTY or contains a space or a quote.
  # The empty case matters here: `--text ''` is a real Orca argument, and
  # dropping its quotes would make the two logs differ over a value both
  # worlds actually sent identically.
  case $a in
    ''|*' '*) raw="$raw \"$a\"" ;;
    *) raw="$raw $a" ;;
  esac
done
printf '[%s %s]\n' "$n" "${raw# }" >> "${FM_CLI_LOG:?}"
# zellij's session flag is GLOBAL and comes before the subcommand; skip it so
# the key is derived from the real subcommand.
[ "${1:-}" = "--session" ] && shift 2
k=${1:-}
k=${k#--}
case ${2:-} in
  -*|'') : ;;
  *) k="$k-$2" ;;
esac
f="$d/fx-$n.$k"
# A per-case variant fixture, so cases that must model DIFFERENT server
# replies for the same command can each pick their own without the two
# worlds needing the file to change between them.
[ -n "${FM_FAKE_VARIANT:-}" ] && [ -f "$f.$FM_FAKE_VARIANT" ] && f="$f.$FM_FAKE_VARIANT"
[ -f "$f.err" ] && cat "$f.err" >&2
rc=0
[ -f "$f.rc" ] && { IFS= read -r rc < "$f.rc" || true; }
[ -f "$f" ] && cat "$f"
exit "$rc"
SH
chmod +x "$FAKEBIN/.fake-cli"

# The batch twin. `printf '%s\r\n'` because cmd needs CRLF (an LF-only batch
# file makes cmd mis-seek on `goto`), and EVERY branch is its own label rather
# than a `&`-chained one-liner: batch parses `&` at the command-line level, so
# `if cond a & b` runs `b` UNCONDITIONALLY.
printf '%s\r\n' \
  '@echo off' \
  'setlocal EnableDelayedExpansion' \
  'set "D=%~dp0"' \
  'set "N=%~n0"' \
  '>>"%FM_CLI_LOG%" echo [%N% %*]' \
  'set "A1=%~1"' \
  'set "A2=%~2"' \
  'if not "%A1%"=="--session" goto keyed' \
  'shift' \
  'shift' \
  'set "A1=%~1"' \
  'set "A2=%~2"' \
  ':keyed' \
  'set "K=%A1%"' \
  'if "!K:~0,2!"=="--" set "K=!K:~2!"' \
  'if "%A2%"=="" goto haskey' \
  'if "!A2:~0,1!"=="-" goto haskey' \
  'set "K=!K!-%A2%"' \
  ':haskey' \
  'set "F=!D!fx-!N!.!K!"' \
  'if "%FM_FAKE_VARIANT%"=="" goto novariant' \
  'if exist "!F!.%FM_FAKE_VARIANT%" set "F=!F!.%FM_FAKE_VARIANT%"' \
  ':novariant' \
  'if exist "!F!.err" type "!F!.err" 1>&2' \
  'set "RC=0"' \
  'if exist "!F!.rc" set /p RC=<"!F!.rc"' \
  'if exist "!F!" type "!F!"' \
  'exit /b !RC!' \
  > "$FAKEBIN/.fake-cli.cmd"

for cli in zellij cmux orca; do
  cp "$FAKEBIN/.fake-cli" "$FAKEBIN/$cli"
  chmod +x "$FAKEBIN/$cli"
  cp "$FAKEBIN/.fake-cli.cmd" "$FAKEBIN/$cli.cmd"
done

# install_cli_fixtures: the reply set both worlds run against. Called before the
# bash scenario and AGAIN before the pwsh run, so the second world starts from
# the same bytes even if a fake mutated something.
install_cli_fixtures() {
  # `fx-` prefix, and the sweep is scoped to it. Without that the glob
  # `$FIX/zellij.*` also matches zellij.cmd and DELETES the batch
  # trampoline, which leaves PowerShell with no CLI at all while bash keeps
  # working through the extension-less script - a failure that looks like a
  # conversion bug in every CLI-driven case at once.
  rm -f "$FIX"/fx-* 2>/dev/null

  # --- zellij ---------------------------------------------------------------
  printf 'zellij 0.44.0\n' > "$FIX/fx-zellij.version"
  printf 'firstmate\nother\n' > "$FIX/fx-zellij.list-sessions"
  # tab 7 carries this home's SCOPED title; tab 8 and tab 9 share one bare
  # title, which is the ambiguity the label check must refuse.
  printf '[{"tab_id":7,"name":"%s","active":true},{"tab_id":8,"name":"fm-dup","active":false},{"tab_id":9,"name":"fm-dup","active":false},{"tab_id":11,"name":"fm-solo","active":false}]\n' \
    "$ZELLIJ_SCOPED" > "$FIX/fx-zellij.action-list-tabs"
  printf '[{"id":3,"tab_id":7,"is_plugin":false},{"id":4,"tab_id":7,"is_plugin":true},{"id":5,"tab_id":11,"is_plugin":false}]\n' \
    > "$FIX/fx-zellij.action-list-panes"
  printf 'pane line one\npane line two\npane line three\n' > "$FIX/fx-zellij.action-dump-screen"
  printf '12\n' > "$FIX/fx-zellij.action-new-tab"

  # --- cmux -----------------------------------------------------------------
  printf 'cmux 0.64.17\n' > "$FIX/fx-cmux.version"
  printf 'PONG\n' > "$FIX/fx-cmux.ping"
  printf '{"workspaces":[{"id":"ws-1","title":"%s"},{"id":"ws-2","title":"other"}]}\n' \
    "$CMUX_SCOPED" > "$FIX/fx-cmux.workspace-list"
  printf '{"panes":[{"selected_surface_id":"sf-9","surface_ids":["sf-9","sf-8"]}]}\n' \
    > "$FIX/fx-cmux.list-panes"
  printf '{"text":"cmux line one\\ncmux line two\\n| > fix |\\n"}\n' > "$FIX/fx-cmux.read-screen"
  printf '[{"id":"win-1"}]\n' > "$FIX/fx-cmux.list-windows"

  # --- orca -----------------------------------------------------------------
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$FIX/fx-orca.status"
  printf '{"ok":true,"result":{"worktree":{"path":"/work/orca/one"}}}\n' > "$FIX/fx-orca.worktree-show"
  printf '{"ok":true,"result":{"terminal":{"tail":["orca line one","| > fix |"]}}}\n' > "$FIX/fx-orca.terminal-read"
  printf '{"ok":true}\n' > "$FIX/fx-orca.worktree-rm"
  printf '{"ok":true}\n' > "$FIX/fx-orca.terminal-send"
  printf '{"ok":true}\n' > "$FIX/fx-orca.terminal-close"

  # --- VARIANT fixtures -----------------------------------------------------
  # Defined HERE, not at their case sites. install_cli_fixtures runs a SECOND
  # time before the pwsh run so both worlds start from the same bytes, and its
  # sweep deletes any fixture a case created inline - which does not fail, it
  # silently answers every variant case from the DEFAULT reply instead.
  printf 'Access denied - only processes started inside cmux can connect\n' > "$FIX/fx-cmux.ping.denied"
  printf 'Authentication required\n' > "$FIX/fx-cmux.ping.unauth"
  printf 'Socket not found\n' > "$FIX/fx-cmux.ping.down"
  printf 'something else entirely\n' > "$FIX/fx-cmux.ping.weird"
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$FIX/fx-orca.status.notready"
  printf '{"ok":true,"result":{"runtime":{"state":"ready"}}}\n' > "$FIX/fx-orca.status.noreach"
}

# =============================================================================
# THE ORACLES
# =============================================================================
# shellcheck source=/dev/null
. "$ROOT/bin/backends/zellij.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/cmux.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/orca.sh"

ZELLIJ_SCOPED=$(fm_backend_zellij_scoped_title 'fm-alpha')
CMUX_SCOPED=$(fm_backend_cmux_scoped_title 'fm-alpha')
install_cli_fixtures

# =============================================================================
# PHASE A - everything reachable with NO CLI on PATH.
#
# This is where the coverage lives, for two reasons: it is the ONLY behaviour a
# captain on this host actually reaches, and its bash oracles are shell builtins
# and pure string work, so the case count is not rationed by process cost.
# =============================================================================

SAVED_PATH=$PATH
# A PATH with no fake on it, so every tool gate below genuinely misses. The
# fakebin is added back for phase B and removed again afterwards.
case ":$PATH:" in
  *":$FAKEBIN:"*) PATH=${PATH//":$FAKEBIN"/} ;;
esac
export PATH

# --- the missing-CLI refusals, the live Windows path --------------------------

case_toolgate() {  # <label> <op> <fn>
  local v e
  v=$(yesno "$3")
  e=''
  IFS= read -r -d '' e < "$ERRCAP" || true
  add_case "$1" "$v|$(first_line "$e")" "$2" '' '' '' '' '' ''
}
case_toolgate 'zellij:tool-gate refuses loudly with no zellij installed' ztool fm_backend_zellij_tool_check
case_toolgate 'cmux:tool-gate refuses loudly with no cmux installed' ctool fm_backend_cmux_tool_check
case_toolgate 'orca:tool-gate refuses loudly with no orca installed' otool fm_backend_orca_tool_check

# The binary-resolution rule underneath cmux's gate: PATH wins, then the bundle
# path, then nothing. With neither present this must resolve to nothing rather
# than to a path that does not exist.
run_oracle fm_backend_cmux_bin
if [ "$ORACLE_RC" -eq 0 ]; then CBIN=$ORACLE; else CBIN='<none>'; fi
add_case 'cmux:binary resolves to nothing when neither PATH nor the bundle has it' \
  "$CBIN" cbin '' '' '' '' '' ''

# --- the socket password: the most delicate behaviour in the package ----------

PWDIR_NONE="$TMP_ROOT/cfg-nopw"; mkdir -p "$PWDIR_NONE"
PWDIR_ONE="$TMP_ROOT/cfg-pw"; mkdir -p "$PWDIR_ONE"; printf 'hunter2\n' > "$PWDIR_ONE/cmux-socket-password"
PWDIR_BLANK="$TMP_ROOT/cfg-pw-blank"; mkdir -p "$PWDIR_BLANK"; printf '\n\n' > "$PWDIR_BLANK/cmux-socket-password"
PWDIR_SKIP="$TMP_ROOT/cfg-pw-skip"; mkdir -p "$PWDIR_SKIP"; printf '\n  spaced  \nsecond\n' > "$PWDIR_SKIP/cmux-socket-password"
PWDIR_NONL="$TMP_ROOT/cfg-pw-nonl"; mkdir -p "$PWDIR_NONL"; printf 'nonewline' > "$PWDIR_NONL/cmux-socket-password"

case_password() {  # <label> <config-dir-posix> <config-dir-native>
  apply_case_env "FM_CONFIG_OVERRIDE=$2"
  run_oracle fm_backend_cmux_password
  clear_case_env
  add_case "cmux:password $1" "$ORACLE" cpass "FM_CONFIG_OVERRIDE=$3" '' '' '' '' ''
}
case_password 'an absent file yields nothing' "$PWDIR_NONE" "$(fm_test_native_path "$PWDIR_NONE")"
case_password 'a configured password is read' "$PWDIR_ONE" "$(fm_test_native_path "$PWDIR_ONE")"
case_password 'a file of blank lines yields nothing' "$PWDIR_BLANK" "$(fm_test_native_path "$PWDIR_BLANK")"
case_password 'blank lines are skipped and whitespace is NOT trimmed' "$PWDIR_SKIP" "$(fm_test_native_path "$PWDIR_SKIP")"
case_password 'a final line with no newline still counts' "$PWDIR_NONL" "$(fm_test_native_path "$PWDIR_NONL")"

# --- target parsing -----------------------------------------------------------

case_zparse() {  # <label> <target>
  local v
  v=$(yesno fm_backend_zellij_parse_target "$2")
  add_case "zellij:parse-target $1" "$v" zparse '' "$2" '' '' '' ''
}
case_zparse 'a well-formed target' 'firstmate:3'
case_zparse 'a target with no colon' 'nocolon'
case_zparse 'an empty session half' ':3'
case_zparse 'an empty pane half' 'firstmate:'
case_zparse 'an empty target' ''
case_zparse 'a second colon lands in the pane half' 'a:b:c'

case_cparse() {  # <label> <target>
  local v
  v=$(yesno fm_backend_cmux_parse_target "$2")
  add_case "cmux:parse-target $1" "$v" cparse '' "$2" '' '' '' ''
}
case_cparse 'a well-formed target' 'ws-1:sf-9'
case_cparse 'a target with no colon' 'nocolon'
case_cparse 'an empty workspace half' ':sf-9'
case_cparse 'an empty surface half' 'ws-1:'
case_cparse 'an empty target' ''

# --- key vocabulary -----------------------------------------------------------

case_zkey() {  # <key>
  run_oracle fm_backend_zellij_normalize_key "$1"
  add_case "zellij:normalize-key $1" "$ORACLE" zkey '' "$1" '' '' '' ''
}
for k in Enter enter Escape escape Esc esc C-c c-c ctrl+c Ctrl+C 'Ctrl c' Tab ''; do case_zkey "$k"; done

case_ckey() {  # <key>
  run_oracle fm_backend_cmux_normalize_key "$1"
  add_case "cmux:normalize-key $1" "$ORACLE" ckey '' "$1" '' '' '' ''
}
for k in Enter enter Escape escape Esc esc C-c ctrl-c ctrl+c Ctrl+C Tab ''; do case_ckey "$k"; done

# --- home-scoped titles -------------------------------------------------------

case_ztitle() {  # <label>
  run_oracle fm_backend_zellij_scoped_title "$1"
  add_case "zellij:scoped-title $1" "$ORACLE" ztitle '' "$1" '' '' '' ''
}
case_ztitle 'fm-alpha'
case_ztitle 'alpha'
case_ztitle 'fm-fm-nested'
case_ztitle ''

case_ctitle() {  # <label>
  run_oracle fm_backend_cmux_scoped_title "$1"
  add_case "cmux:scoped-title $1" "$ORACLE" ctitle '' "$1" '' '' '' ''
}
case_ctitle 'fm-alpha'
case_ctitle 'alpha'
case_ctitle ''

# The two adapters share one home tag, which is what makes a cross-backend
# collision impossible for the same installation.
add_case 'zellij:scoped-title agrees with cmux on the shared home tag' \
  "$(if [ "$ZELLIJ_SCOPED" = "$CMUX_SCOPED" ]; then printf same; else printf differ; fi)" \
  ztitlesame '' 'fm-alpha' '' '' '' ''

run_oracle fm_backend_zellij_session
add_case 'zellij:session defaults to firstmate' "$ORACLE" zsession '' '' '' '' '' ''
apply_case_env 'FM_ZELLIJ_SESSION=isolated'
run_oracle fm_backend_zellij_session
clear_case_env
add_case 'zellij:session honours FM_ZELLIJ_SESSION' "$ORACLE" zsession 'FM_ZELLIJ_SESSION=isolated' '' '' '' '' ''

# --- Orca's JSON readers, where JavaScript evaluation rules live --------------

case_ojson() {  # <label> <field> <json>
  local out e
  run_oracle fm_backend_orca_json_get "$2" <<EOF_JSON
$3
EOF_JSON
  out="$ORACLE_RC|$ORACLE|$(first_line "$ORACLE_ERR")"
  add_case "orca:json-get $1" "$out" ojson '' "$2" "$3" '' '' ''
}
case_ojson 'a plain worktree id' worktree-id '{"ok":true,"result":{"worktree":{"id":"w1"}}}'
case_ojson 'a FALSY id 0 falls through to worktreeId' worktree-id '{"ok":true,"result":{"worktree":{"id":0,"worktreeId":"w7"}}}'
case_ojson 'the string 0 is TRUTHY and is kept' worktree-id '{"ok":true,"result":{"worktree":{"id":"0","worktreeId":"w7"}}}'
case_ojson 'an empty id falls through' worktree-id '{"ok":true,"result":{"worktree":{"id":"","worktreeId":"w8"}}}'
case_ojson 'a nested git path' worktree-path '{"ok":true,"result":{"worktree":{"git":{"path":"/g/p"}}}}'
case_ojson 'a root path fallback' worktree-path '{"ok":true,"result":{"path":"/r/p"}}'
case_ojson 'a terminal handle from an explicit terminal object' terminal-handle '{"ok":true,"result":{"terminal":{"handle":"t1"}}}'
case_ojson 'a bare-string terminal is its own handle' terminal-handle '{"ok":true,"result":{"terminal":"t2"}}'
case_ojson 'an undocumented result.id is NOT a terminal handle' terminal-handle '{"ok":true,"result":{"id":"t3"}}'
case_ojson 'a worktree terminal handle needs an explicit terminal' worktree-terminal-handle '{"ok":true,"result":{"handle":"t4"}}'
case_ojson 'a repo id' repo-id '{"ok":true,"result":{"repo":{"id":"r1"}}}'
case_ojson 'an ok:false payload reports its message and exits 2' repo-id '{"ok":false,"error":{"message":"boom"}}'
case_ojson 'an ok:false payload falls back to its code' repo-id '{"ok":false,"error":{"code":"E_CODE"}}'
# The ONE json-get case whose stderr is deliberately not compared: an
# uncaught JSON.parse throw makes node print its own stack trace and exit 1,
# and that dump is node's, not firstmate's. The VERDICT - code 1, no value -
# is what the callers branch on and is still compared exactly.
run_oracle fm_backend_orca_json_get worktree-id <<EOF_JSON
not json at all
EOF_JSON
add_case 'orca:json-get unparseable JSON is a no-value, not an ok:false' \
  "$ORACLE_RC|$ORACLE" ojsonquiet '' worktree-id 'not json at all' '' '' ''
case_ojson 'a numeric id renders as a string' worktree-id '{"ok":true,"result":{"worktree":{"id":42}}}'
case_ojson 'an unknown field yields nothing' nosuchfield '{"ok":true,"result":{"worktree":{"id":"w1"}}}'

case_ojsonok() {  # <label> <json>
  local out e
  run_oracle fm_backend_orca_json_ok <<EOF_JSON
$2
EOF_JSON
  out="$ORACLE_RC|$(first_line "$ORACLE_ERR")"
  add_case "orca:json-ok $1" "$out" ojsonok '' "$2" '' '' '' ''
}
case_ojsonok 'an accepted payload' '{"ok":true}'
case_ojsonok 'a rejected payload reports its message' '{"ok":false,"error":{"message":"nope"}}'
case_ojsonok 'a payload with no ok field is accepted' '{"result":{}}'

case_ojsontext() {  # <label> <json>
  run_oracle fm_backend_orca_json_text "$2"
  add_case "orca:json-text $1" "$ORACLE_RC|$ORACLE" ojsontext '' "$2" '' '' '' ''
}
case_ojsontext 'a terminal tail array wins over text' '{"ok":true,"result":{"terminal":{"tail":["a","b"]},"text":"ignored"}}'
case_ojsontext 'a root tail array' '{"ok":true,"result":{"tail":["x","y"]}}'
case_ojsontext 'a text field' '{"ok":true,"result":{"text":"hello"}}'
case_ojsontext 'an output field fallback' '{"ok":true,"result":{"output":"out"}}'
case_ojsontext 'nothing at all yields empty' '{"ok":true,"result":{}}'
case_ojsontext 'an empty tail array is still a tail' '{"ok":true,"result":{"tail":[],"text":"ignored"}}'

case_ojsonfield() {  # <label> <field> <json>
  run_oracle fm_backend_orca_json_field "$2" "$3"
  add_case "orca:json-field $1" "$ORACLE_RC|$ORACLE" ojsonfield '' "$2" "$3" '' '' ''
}
case_ojsonfield 'limited true' limited '{"ok":true,"result":{"limited":true}}'
case_ojsonfield 'limited FALSE stays false (nullish, not falsy)' limited '{"ok":true,"result":{"limited":false,"terminal":{"limited":true}}}'
case_ojsonfield 'limited falls through only when absent' limited '{"ok":true,"result":{"terminal":{"limited":true}}}'
case_ojsonfield 'an oldest cursor' oldestCursor '{"ok":true,"result":{"oldestCursor":"c1"}}'
case_ojsonfield 'an EMPTY oldest cursor falls through (falsy, not nullish)' oldestCursor '{"ok":true,"result":{"oldestCursor":"","terminal":{"oldestCursor":"c2"}}}'
case_ojsonfield 'a missing field yields nothing' latestCursor '{"ok":true,"result":{}}'

# =============================================================================
# PHASE B - the fake-CLI scenarios. Rationed: each case costs a child process in
# EACH world.
# =============================================================================
BASH_CLI_LOG="$TMP_ROOT/cli-bash.log"
PS_CLI_LOG="$TMP_ROOT/cli-ps.log"
PS_CLI_LOG_N=$(fm_test_native_path "$PS_CLI_LOG")
: > "$BASH_CLI_LOG"
: > "$PS_CLI_LOG"

CLI_ENV="PATH=$FAKEBIN_N"
PATH="$FAKEBIN:$SAVED_PATH"
export PATH
export FM_CLI_LOG="$BASH_CLI_LOG"

cli_env() {  # [extra KEY=VALUE]
  if [ -n "${1:-}" ]; then printf '%s\037%s\037FM_CLI_LOG=%s' "$CLI_ENV" "$1" "$PS_CLI_LOG_N"
  else printf '%s\037FM_CLI_LOG=%s' "$CLI_ENV" "$PS_CLI_LOG_N"; fi
}

# --- zellij -------------------------------------------------------------------

run_oracle fm_backend_zellij_version_check
add_case 'zellij:version accepts the verified minimum' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  zversion "$(cli_env)" '' '' '' '' ''

add_case 'zellij:session-exists finds a listed session' \
  "$(yesno fm_backend_zellij_session_exists firstmate)" zsessex "$(cli_env)" firstmate '' '' '' ''
add_case 'zellij:session-exists refuses an unlisted session' \
  "$(yesno fm_backend_zellij_session_exists nosuch)" zsessex "$(cli_env)" nosuch '' '' '' ''

run_oracle fm_backend_zellij_pane_for_tab firstmate 7
add_case 'zellij:pane-for-tab skips the plugin pane' "$ORACLE" zpanefortab "$(cli_env)" firstmate 7 '' '' ''
run_oracle fm_backend_zellij_tab_for_pane firstmate 5
add_case 'zellij:tab-for-pane reverse lookup' "$ORACLE" ztabforpane "$(cli_env)" firstmate 5 '' '' ''
run_oracle fm_backend_zellij_tab_for_pane firstmate 4
add_case 'zellij:tab-for-pane ignores a plugin pane' "$ORACLE" ztabforpane "$(cli_env)" firstmate 4 '' '' ''

add_case 'zellij:tab-label the home-scoped title matches' \
  "$(yesno fm_backend_zellij_tab_matches_label firstmate 7 fm-alpha)" ztablabel "$(cli_env)" firstmate 7 fm-alpha '' ''
add_case 'zellij:tab-label an UNAMBIGUOUS legacy bare title matches' \
  "$(yesno fm_backend_zellij_tab_matches_label firstmate 11 fm-solo)" ztablabel "$(cli_env)" firstmate 11 fm-solo '' ''
add_case 'zellij:tab-label an AMBIGUOUS bare title is refused' \
  "$(yesno fm_backend_zellij_tab_matches_label firstmate 8 fm-dup)" ztablabel "$(cli_env)" firstmate 8 fm-dup '' ''
add_case 'zellij:tab-label a tab that carries neither title is refused' \
  "$(yesno fm_backend_zellij_tab_matches_label firstmate 7 fm-other)" ztablabel "$(cli_env)" firstmate 7 fm-other '' ''

run_oracle fm_backend_zellij_capture 'firstmate:3' 2
add_case 'zellij:capture trims to the last N lines' "$ORACLE" zcapture "$(cli_env)" 'firstmate:3' 2 '' '' ''
run_oracle fm_backend_zellij_capture 'nosuch:3' 2
if [ "$ORACLE_RC" -eq 0 ]; then ZCAP=$ORACLE; else ZCAP='<null>'; fi
add_case 'zellij:capture refuses a dead session' "$ZCAP" zcapture "$(cli_env)" 'nosuch:3' 2 '' '' ''

run_oracle fm_backend_zellij_create_task firstmate fm-alpha /proj
if [ "$ORACLE_RC" -eq 0 ]; then ZCREATE=$ORACLE; else ZCREATE='<none>'; fi
add_case 'zellij:create-task refuses a duplicate scoped title' \
  "$ZCREATE|$(first_line "$ORACLE_ERR")" zcreate "$(cli_env)" firstmate fm-alpha /proj '' ''

run_oracle fm_backend_zellij_list_live firstmate
add_case 'zellij:list-live reports only this home tagged tabs' "$ORACLE" zlistlive "$(cli_env)" firstmate '' '' '' ''

add_case 'zellij:kill closes the resolved tab' \
  "$(yesno fm_backend_zellij_kill 'firstmate:5' '' fm-solo)" zkill "$(cli_env)" 'firstmate:5' '' fm-solo '' ''
add_case 'zellij:kill on a dead session is a no-op' \
  "$(yesno fm_backend_zellij_kill 'nosuch:5' '' '')" zkill "$(cli_env)" 'nosuch:5' '' '' '' ''

# --- cmux ---------------------------------------------------------------------

run_oracle fm_backend_cmux_version_check
add_case 'cmux:version accepts the verified minimum' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  cversion "$(cli_env)" '' '' '' '' ''


case_cping() {  # <label> <variant>
  apply_case_env "FM_FAKE_VARIANT=$2"
  run_oracle fm_backend_cmux_ping_state
  clear_case_env
  add_case "cmux:ping-state $1" "$ORACLE" cping "$(cli_env "FM_FAKE_VARIANT=$2")" '' '' '' '' ''
}
case_cping 'PONG is ok' ''
case_cping 'a cmuxOnly rejection is denied' denied
case_cping 'an auth-shaped reply is unauth' unauth
case_cping 'a missing socket is down' down
case_cping 'anything else is error' weird

run_oracle fm_backend_cmux_workspace_id_for_label "$CMUX_SCOPED"
add_case 'cmux:workspace-for-label finds the scoped title' "$ORACLE" cwsforlabel "$(cli_env)" "$CMUX_SCOPED" '' '' '' ''
run_oracle fm_backend_cmux_workspace_id_for_label 'fm-nosuch'
add_case 'cmux:workspace-for-label misses an unknown title' "$ORACLE" cwsforlabel "$(cli_env)" 'fm-nosuch' '' '' '' ''

run_oracle fm_backend_cmux_surface_id_for_workspace 'ws-1'
add_case 'cmux:surface-for-workspace prefers the selected surface' "$ORACLE" csurfforws "$(cli_env)" 'ws-1' '' '' '' ''

add_case 'cmux:surface-exists finds a listed surface' \
  "$(yesno fm_backend_cmux_surface_exists 'ws-1' 'sf-8')" csurfexists "$(cli_env)" 'ws-1' 'sf-8' '' '' ''
add_case 'cmux:surface-exists refuses an unlisted surface' \
  "$(yesno fm_backend_cmux_surface_exists 'ws-1' 'sf-nope')" csurfexists "$(cli_env)" 'ws-1' 'sf-nope' '' '' ''

run_oracle fm_backend_cmux_capture 'ws-1:sf-9' 2
if [ "$ORACLE_RC" -eq 0 ]; then CCAP=$ORACLE; else CCAP='<null>'; fi
add_case 'cmux:capture trims to the last N lines' "$CCAP" ccapture "$(cli_env)" 'ws-1:sf-9' 2 '' '' ''

run_oracle fm_backend_cmux_composer_state 'ws-1:sf-9'
add_case 'cmux:composer-state reads the bordered row' "$ORACLE" ccomposer "$(cli_env)" 'ws-1:sf-9' '' '' '' ''

run_oracle fm_backend_cmux_window_of_workspace 'ws-1'
add_case 'cmux:window-of-workspace reports the window and its count' "$ORACLE" cwindow "$(cli_env)" 'ws-1' '' '' '' ''

run_oracle fm_backend_cmux_list_live
add_case 'cmux:list-live reports only this home tagged workspaces' "$ORACLE" clistlive "$(cli_env)" '' '' '' '' ''

add_case 'cmux:kill closes the workspace' \
  "$(yesno fm_backend_cmux_kill 'ws-1:sf-9' '' '')" ckill "$(cli_env)" 'ws-1:sf-9' '' '' '' ''

# --- orca ---------------------------------------------------------------------

run_oracle fm_backend_orca_runtime_check
add_case 'orca:runtime accepts a ready runtime' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  oruntime "$(cli_env)" '' '' '' '' ''

apply_case_env 'FM_FAKE_VARIANT=notready'
run_oracle fm_backend_orca_runtime_check
clear_case_env
add_case 'orca:runtime refuses an unready runtime and names both fields' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  oruntime "$(cli_env 'FM_FAKE_VARIANT=notready')" '' '' '' '' ''

apply_case_env 'FM_FAKE_VARIANT=noreach'
run_oracle fm_backend_orca_runtime_check
clear_case_env
add_case 'orca:runtime an ABSENT reachable renders as undefined' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  oruntime "$(cli_env 'FM_FAKE_VARIANT=noreach')" '' '' '' '' ''

run_oracle fm_backend_orca_capture 'term-1' 40
if [ "$ORACLE_RC" -eq 0 ]; then OCAP=$ORACLE; else OCAP='<null>'; fi
add_case 'orca:capture joins the terminal tail' "$OCAP" ocapture "$(cli_env)" 'term-1' 40 '' '' ''

run_oracle fm_backend_orca_composer_state 'term-1'
add_case 'orca:composer-state reads the bordered row' "$ORACLE" ocomposer "$(cli_env)" 'term-1' '' '' '' ''

run_oracle fm_backend_orca_worktree_path 'wt-1'
if [ "$ORACLE_RC" -eq 0 ]; then OWT=$ORACLE; else OWT='<none>'; fi
add_case 'orca:worktree-path reads the path' "$OWT|$(first_line "$ORACLE_ERR")" owtpath "$(cli_env)" 'wt-1' '' '' '' ''

run_oracle fm_backend_orca_worktree_path ''
if [ "$ORACLE_RC" -eq 0 ]; then OWT=$ORACLE; else OWT='<none>'; fi
add_case 'orca:worktree-path refuses an empty id before any CLI call' \
  "$OWT|$(first_line "$ORACLE_ERR")" owtpath "$(cli_env)" '' '' '' '' ''

# ORACLE_ERR belongs to the last run_oracle, not to `yesno` - reading it here
# would record the PREVIOUS case's diagnostic. The capture file is re-read
# instead, which is what yesno actually wrote to.
case_ormwt() {  # <label> <worktree-id>
  local v e
  v=$(yesno fm_backend_orca_remove_worktree "$2")
  e=''
  IFS= read -r -d '' e < "$ERRCAP" || true
  add_case "orca:remove-worktree $1" "$v|$(first_line "$e")" ormwt "$(cli_env)" "$2" '' '' '' ''
}
case_ormwt 'accepts an ok payload' 'wt-1'
case_ormwt 'refuses an empty id before any CLI call' ''

run_oracle fm_backend_orca_send_key 'term-1' Escape
add_case 'orca:send-key refuses an unsupported Escape rather than typing it' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  osendkey "$(cli_env)" 'term-1' Escape '' '' ''
run_oracle fm_backend_orca_send_key 'term-1' Enter
add_case 'orca:send-key sends Enter as an empty submitted line' \
  "$(if [ "$ORACLE_RC" -eq 0 ]; then printf yes; else printf no; fi)|$(first_line "$ORACLE_ERR")" \
  osendkey "$(cli_env)" 'term-1' Enter '' '' ''

unset FM_CLI_LOG
PATH=$SAVED_PATH
export PATH

# =============================================================================
# THE POWERSHELL DRIVER - one process for every case above.
# =============================================================================
cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_MOD_ZELLIJ -Force
Import-Module $env:FM_MOD_CMUX -Force
Import-Module $env:FM_MOD_ORCA -Force

$FS = [char]1
$RS = [char]2
$US = [char]31
$NONE = '<none>'
$NULLMARK = '<null>'

# Every environment variable any case touches, snapshotted so a per-case
# setting cannot leak into the next case.
$managed = @('FM_CONFIG_OVERRIDE', 'FM_ZELLIJ_SESSION', 'FM_CLI_LOG', 'FM_FAKE_VARIANT',
    'FM_BACKEND_ORCA_COMPOSER_LINES', 'FM_BACKEND_ORCA_IDLE_RE',
    'FM_BACKEND_CMUX_COMPOSER_LINES', 'FM_BACKEND_CMUX_IDLE_RE',
    'FM_BACKEND_CMUX_BUNDLE_BIN', 'CMUX_SOCKET_PASSWORD')
$original = @{}
foreach ($k in $managed) { $original[$k] = [Environment]::GetEnvironmentVariable($k) }
$originalPath = $env:PATH

function Get-Yesno { param([bool]$Value) if ($Value) { return 'yes' } return 'no' }

function Get-FirstLine {
    param([AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $i = $Text.IndexOf("`n")
    if ($i -ge 0) { return $Text.Substring(0, $i) }
    return $Text
}

# [object], NOT [string]: binding $null to a [string] parameter COERCES it to
# the empty string, so a typed helper could never tell "no answer" from "an
# empty answer" - the exact distinction these markers exist to keep.
function Get-OrNone {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $NONE }
    return [string]$Value
}
function Get-OrNoneNull {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $NULLMARK }
    return [string]$Value
}

$text = [System.IO.File]::ReadAllText($env:FM_CASES, [System.Text.Encoding]::UTF8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++
    $f = @($record.Split($FS))
    if ($f.Count -ne 7) {
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

    $sw = [System.IO.StringWriter]::new()
    $oldErr = [Console]::Error
    [Console]::SetError($sw)
    $result = ''
    try {
        switch -CaseSensitive ($f[0]) {
            'ztool' { $result = Get-Yesno (Test-FmBackendZellijTool) }
            'ctool' { $result = Get-Yesno (Test-FmBackendCmuxTool) }
            'otool' { $result = Get-Yesno (Test-FmBackendOrcaTool) }
            'cbin' { $result = Get-OrNone (Get-FmBackendCmuxBinary) }
            'cpass' { $result = Get-FmBackendCmuxPassword }
            'zparse' { $result = Get-Yesno ((Split-FmBackendZellijTarget $f[2]).Ok) }
            'cparse' { $result = Get-Yesno ((Split-FmBackendCmuxTarget $f[2]).Ok) }
            'zkey' { $result = ConvertTo-FmBackendZellijKey $f[2] }
            'ckey' { $result = ConvertTo-FmBackendCmuxKey $f[2] }
            'ztitle' { $result = Get-FmBackendZellijScopedTitle $f[2] }
            'ctitle' { $result = Get-FmBackendCmuxScopedTitle $f[2] }
            'ztitlesame' {
                if ((Get-FmBackendZellijScopedTitle $f[2]) -ceq (Get-FmBackendCmuxScopedTitle $f[2])) {
                    $result = 'same'
                } else { $result = 'differ' }
            }
            'zsession' { $result = Get-FmBackendZellijSession }
            'ojson' {
                $r = Get-FmBackendOrcaJsonValue $f[2] $f[3]
                $result = '{0}|{1}' -f $r.Code, $r.Value
            }
            'ojsonquiet' {
                $r = Get-FmBackendOrcaJsonValue $f[2] $f[3]
                $result = '{0}|{1}' -f $r.Code, $r.Value
            }
            'ojsonok' { $result = [string](Test-FmBackendOrcaJsonOk $f[2]).Code }
            'ojsontext' {
                $r = Get-FmBackendOrcaJsonText $f[2]
                $result = '{0}|{1}' -f $r.Code, $r.Value
            }
            'ojsonfield' {
                $r = Get-FmBackendOrcaJsonField $f[2] $f[3]
                $result = '{0}|{1}' -f $r.Code, $r.Value
            }
            'zversion' { $result = Get-Yesno (Test-FmBackendZellijVersion) }
            'zsessex' { $result = Get-Yesno (Test-FmBackendZellijSessionExists $f[2]) }
            'zpanefortab' { $result = Get-FmBackendZellijPaneForTab $f[2] $f[3] }
            'ztabforpane' { $result = Get-FmBackendZellijTabForPane $f[2] $f[3] }
            'ztablabel' { $result = Get-Yesno (Test-FmBackendZellijTabLabel $f[2] $f[3] $f[4]) }
            'zcapture' { $result = Get-OrNoneNull (Get-FmBackendZellijCapture $f[2] $f[3]) }
            'zcreate' { $result = Get-OrNone (New-FmBackendZellijTask $f[2] $f[3] $f[4]) }
            'zlistlive' { $result = (@(Get-FmBackendZellijLiveTask $f[2]) -join "`n") }
            'zkill' { $result = Get-Yesno (Remove-FmBackendZellijTarget $f[2] $f[3] $f[4]) }
            'cversion' { $result = Get-Yesno (Test-FmBackendCmuxVersion) }
            'cping' { $result = Get-FmBackendCmuxPingState }
            'cwsforlabel' { $result = Get-FmBackendCmuxWorkspaceForLabel $f[2] }
            'csurfforws' { $result = Get-FmBackendCmuxSurfaceForWorkspace $f[2] }
            'csurfexists' { $result = Get-Yesno (Test-FmBackendCmuxSurfaceExists $f[2] $f[3]) }
            'ccapture' { $result = Get-OrNoneNull (Get-FmBackendCmuxCapture $f[2] $f[3]) }
            'ccomposer' { $result = Get-FmBackendCmuxComposerState $f[2] }
            'cwindow' {
                $w = Get-FmBackendCmuxWindowOfWorkspace $f[2]
                if ($w.Window -ceq '') { $result = '' } else { $result = '{0} {1}' -f $w.Window, $w.Count }
            }
            'clistlive' { $result = (@(Get-FmBackendCmuxLiveTask) -join "`n") }
            'ckill' { $result = Get-Yesno (Remove-FmBackendCmuxTarget $f[2] $f[3] $f[4]) }
            'oruntime' { $result = Get-Yesno (Test-FmBackendOrcaRuntime) }
            'ocapture' { $result = Get-OrNoneNull (Get-FmBackendOrcaCapture $f[2] $f[3]) }
            'ocomposer' { $result = Get-FmBackendOrcaComposerState $f[2] }
            'owtpath' { $result = Get-OrNone (Get-FmBackendOrcaWorktreePath $f[2]) }
            'ormwt' { $result = Get-Yesno (Remove-FmBackendOrcaWorktree $f[2]) }
            'osendkey' { $result = Get-Yesno (Send-FmBackendOrcaKey $f[2] $f[3]) }
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
        'ztool' { $result = $result + '|' + (Get-FirstLine $errText) }
        'ctool' { $result = $result + '|' + (Get-FirstLine $errText) }
        'otool' { $result = $result + '|' + (Get-FirstLine $errText) }
        'ojson' { $result = $result + '|' + (Get-FirstLine $errText) }
        'ojsonok' { $result = $result + '|' + (Get-FirstLine $errText) }
        'zversion' { $result = $result + '|' + (Get-FirstLine $errText) }
        'zcreate' { $result = $result + '|' + (Get-FirstLine $errText) }
        'cversion' { $result = $result + '|' + (Get-FirstLine $errText) }
        'oruntime' { $result = $result + '|' + (Get-FirstLine $errText) }
        'owtpath' { $result = $result + '|' + (Get-FirstLine $errText) }
        'ormwt' { $result = $result + '|' + (Get-FirstLine $errText) }
        'osendkey' { $result = $result + '|' + (Get-FirstLine $errText) }
        default { }
    }

    [void]$out.Append($index).Append($FS).Append($result).Append($RS)
}

[Console]::Out.Write($out.ToString())
PS1

# =============================================================================
# RUN
# =============================================================================
install_cli_fixtures
: > "$PS_CLI_LOG"

export FM_MOD_ZELLIJ="$MOD_ZELLIJ_N" FM_MOD_CMUX="$MOD_CMUX_N" FM_MOD_ORCA="$MOD_ORCA_N" \
       FM_CASES="$(fm_test_native_path "$CASES")"

if ! pwsh -NoProfile -File "$(fm_test_native_path "$DRIVER")" > "$RESULTS" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A clean run is also a SILENT run: every diagnostic a case produces is captured
# per case, so anything reaching the real stderr is a module warning and a real
# finding.
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr"$'\n'"$(cat "$DRIVER_ERR")"

# rstrip_value: the `$( ... )` convention, applied to BOTH sides. Several bash
# twins end in a `jq | head -1` or a `printf '%s\n'`, and every bash call site
# strips those trailing newlines; the PowerShell twins return what a caller ends
# up holding. No value here legitimately ends in a newline, so this softens
# nothing - every interior byte still has to match.
rstrip_value() {  # <text>
  RSTRIPPED=$1
  while [ "${RSTRIPPED%"$LF"}" != "$RSTRIPPED" ]; do RSTRIPPED=${RSTRIPPED%"$LF"}; done
}

# norm_paths: the one place a path may legitimately appear in a compared value.
# The cmux tool-gate refusal names the bundle path it looked at, and a config
# dir reaches a couple of diagnostics; the two worlds spell those differently.
norm_paths() {  # <text>
  NORMALIZED=$1
  NORMALIZED=${NORMALIZED//"$TMP_ROOT_N"/<TMP>}
  NORMALIZED=${NORMALIZED//"$TMP_ROOT"/<TMP>}
}

TMP_ROOT_N=$(fm_test_native_path "$TMP_ROOT")

SEEN=0
while IFS=$'\001' read -r -d $'\002' idx got; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  rstrip_value "${EXPECT[$idx]}"; norm_paths "$RSTRIPPED"; want=$NORMALIZED
  rstrip_value "$got"; norm_paths "$RSTRIPPED"; have=$NORMALIZED
  assert_same "${LABELS[$idx]}" "$want" "$have"
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] \
  || fail "driver returned $SEEN results for ${#LABELS[@]} cases (a driver that died halfway returns fewer, which must not read as a shorter passing run)"

# --- the CLI command-sequence differential ------------------------------------
#
# The strongest CLI-side assertion in this file: both worlds ran the same
# scenario through their own fake, and every command line must match - including
# argument ORDER, which is what a rewrite most easily gets wrong. CR is stripped
# because cmd `echo` has no LF-only mode.
tr -d '\r' < "$BASH_CLI_LOG" > "$TMP_ROOT/cli-bash.norm"
tr -d '\r' < "$PS_CLI_LOG" > "$TMP_ROOT/cli-ps.norm"
ASSERTIONS=$((ASSERTIONS + 1))
if ! diff -u "$TMP_ROOT/cli-bash.norm" "$TMP_ROOT/cli-ps.norm" > "$TMP_ROOT/cli.diff" 2>&1; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}cli:command-sequence the two worlds issued different CLI commands
$(cat "$TMP_ROOT/cli.diff")
"
fi
ASSERTIONS=$((ASSERTIONS + 1))
if [ ! -s "$TMP_ROOT/cli-bash.norm" ]; then
  FAILURES=$((FAILURES + 1))
  FAILURE_TEXT="${FAILURE_TEXT}cli:command-sequence the bash scenario issued no CLI commands at all
"
fi

# --- import hygiene -----------------------------------------------------------
import_out=$(pwsh -NoProfile -Command "Import-Module '$MOD_ZELLIJ_N' -Force; Import-Module '$MOD_CMUX_N' -Force; Import-Module '$MOD_ORCA_N' -Force" 2>&1)
import_rc=$?
assert_same 'adapters:import importing all three is silent' '' "$import_out"
assert_same 'adapters:import importing all three succeeds' 0 "$import_rc"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the zellij/cmux/orca PowerShell twins differ from their bash oracles (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# COUNT is itself asserted. Set from an OBSERVED green run, never a guess.
MIN_ASSERTIONS=128
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - backends/zellij.psm1, backends/cmux.psm1 and backends/orca.psm1 match their bash oracles across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-backends-other-psm1.test.sh: all assertions passed\n'
