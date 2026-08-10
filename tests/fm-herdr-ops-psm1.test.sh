#!/usr/bin/env bash
# Differential tests for the W4-herdr-ops PowerShell entrypoints:
#
#   bin/fm-herdr-lab.ps1              vs bin/fm-herdr-lab.sh
#   bin/fm-herdr-ci-cleanup.ps1       vs bin/fm-herdr-ci-cleanup.sh
#   bin/fm-herdr-session-cleanup.ps1  vs bin/fm-herdr-session-cleanup.sh
#
# The bash tree is the ORACLE (docs/powershell-port.md): every case drives both
# implementations with the same fixture and compares exit code, stdout, stderr,
# the exact sequence of Herdr commands each one issued, and every state file
# written.
#
# ---------------------------------------------------------------------------
# NOTHING HERE TOUCHES A REAL HERDR SERVER
#
# This package's whole reason to exist is that a bare `herdr server stop` killed
# a captain's live default session TWICE in production. So every case below runs
# against a FAKE herdr on PATH, no case names the `default` session, and
# HERDR_SESSION is pinned to a non-default value in every fixture. The real
# 0.7.5-preview binary installed on this host is never reached: the fakebin is
# PREFIXED to PATH, and for the one case that must prove the missing-herdr
# no-op, PATH is replaced by an empty directory outright.
#
# ---------------------------------------------------------------------------
# THE FAKE herdr, AND WHY THERE ARE TWO OF THEM
#
# It cannot be one file: .NET's Process.Start does not search PATH for a bare
# name and cannot start an extension-less shebang script at all, while bash will
# not run a batch file. So each scenario's fakebin holds
#
#     fakebin/herdr       a bash script  - what `command -v herdr` finds
#     fakebin/herdr.cmd   a batch script - what Get-Command -CommandType
#                                          Application resolves first, by PATHEXT
#
# and the two are kept honest by construction rather than by review: they SHARE
# every response fixture, they both append their argv to a per-world log, and
# those two logs are compared as a first-class assertion. Any divergence in the
# dispatch rule shows up as a log mismatch even when the verdict agrees.
#
# The dispatch rule is pure data, so neither fake carries scenario logic:
#
#     key   = "<arg1>-<arg2>"                  e.g. session-list, status---json
#     body  = resp/<key>.<N>.out               N = per-key call ordinal
#           | resp/<key>.<state>.out           state = resp-driven state machine
#           | resp/<key>.out
#           | resp/default.out
#     code  = resp/<key>.<N>.exit | <state>.exit | <key>.exit, else 0
#     state := contents of resp/<key>.act, when that file exists
#
# The ordinal layer is what makes "the fleet changed between two identical
# calls" testable at all - the refuse-default check re-reads the session list
# immediately before each destructive call, and only a per-call response can
# prove that the SECOND read is the one that decides.
#
# ---------------------------------------------------------------------------
# COST RULES THIS FILE IS BUILT AROUND, both measured on this host
#
#   1. ONE pwsh FOR THE WHOLE SUITE. A bare `pwsh -NoProfile -Command "exit 0"`
#      costs ~5s here (~13x a bash fork), so a suite that spawns one per case
#      never finishes - it presents as a 30-60 minute hang with zero output.
#      Every PowerShell case is written to a TAB-delimited case FILE; ONE driver
#      process runs them all in-process and writes per-case out/err/rc files;
#      bash then joins by LABEL.
#   2. THE ORACLE HALF IS FORK-BOUND AND DOMINATES UNDER LOAD (a trivial fork
#      measured 0.36s idle and 3.1s with four conversion agents live). So the
#      bash side uses builtins - parameter expansion, `case`, `read`, `$(<file)`
#      - and no per-assertion helper ever contains `$( )`, which would fork a
#      subshell per call. Helpers ASSIGN through `printf -v` instead.
#
# ---------------------------------------------------------------------------
# THREE NORMALIZATIONS, EACH DECLARED RATHER THAN QUIETLY APPLIED
#
#   1. GENERATED SESSION NAMES. `fm-herdr-lab name <label>` appends the pid and
#      a random number, so the two worlds can never print the same string. The
#      LABEL half is deterministic and IS compared byte for byte; the suffix is
#      only checked for shape. That is the whole sanitizer under test.
#   2. THE PROVISION POLL. The lab server is started in the background and
#      polled, so the NUMBER of `status --json` calls depends on scheduling.
#      Adjacent duplicate log lines are collapsed before the two logs are
#      compared; every other line, and their order, must match exactly.
#   3. CARRIAGE RETURNS. cmd's `echo` has no LF-only mode, so the batch fake's
#      log is CRLF. CR is stripped from both logs before comparison; fixture
#      BODIES are emitted with `type`/`cat` and are byte-exact, so no response
#      content is normalized.
#
# Paths are never used as probe keys (docs/powershell-port.md): every case is
# keyed by a stable label, and each world owns its own directories.
set -u

# TMPDIR must be set BEFORE lib.sh is sourced (the cleanup registry path is
# computed at source time), and must live on a real drive so /f/x and F:\x are
# exact mirrors rather than MSYS mount-table fictions.
_suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR="$_suite_root/.no-mistakes/ps-herdr-ops-tmp"
mkdir -p "$TMPDIR"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the bash oracle)"; exit 0; }

# A Herdr pane identity leaked in from the developer's own terminal would make
# the session resolver pick a session this suite never models.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_HERDR_LAB_STATE_DIR FM_BACKEND FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY CDPATH

TMP_ROOT=$(fm_test_tmproot fm-herdr-ops)
OUT="$TMP_ROOT/out"
LAB="$TMP_ROOT/lab"
CI="$TMP_ROOT/ci"
SC="$TMP_ROOT/sc"
CASES_B="$TMP_ROOT/cases-b.tsv"
CASES_C="$TMP_ROOT/cases-c.tsv"
mkdir -p "$OUT" "$LAB" "$CI" "$SC/cases"
: > "$CASES_B"
: > "$CASES_C"

US=$'\037'   # unit separator: environment pairs
RS=$'\036'   # record separator: argv elements
EMPTY='@EMPTY@'

progress() { printf '# %s\n' "$1" >&2; }

# Absolute, because one case replaces PATH outright.
BASH_BIN=$(command -v bash)

ASSERTIONS=0
# Observed on a green run. A suite that silently stops exercising cases must
# fail rather than report success on a handful of assertions.
MIN_ASSERTIONS=310

# --- assertions --------------------------------------------------------------
#
# No `$( )` anywhere in these: a command substitution here would fork a subshell
# per assertion, and at ~3s a fork under load that alone would take the suite
# past an hour.

assert_eq() { # actual expected label
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- powershell ---"$'\n'"$1"$'\n'"--- bash oracle ---"$'\n'"$2"
}

# read_file <var> <path>: the `$(<file)` twin with no fork. Missing file = ''.
read_file() {
  local -n _dst=$1
  _dst=''
  [ -f "$2" ] || return 0
  local _line _acc=''
  while IFS= read -r _line || [ -n "$_line" ]; do
    _acc="$_acc$_line"$'\n'
  done < "$2"
  _dst=${_acc%$'\n'}
}

# normalize_log <var> <path>: strip CR, then collapse adjacent duplicate lines
# (normalization 2 and 3 in the header).
normalize_log() {
  local -n _dst=$1
  _dst=''
  [ -f "$2" ] || return 0
  local _line _prev='' _acc='' _first=1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line=${_line%$'\r'}
    if [ "$_first" = 1 ] || [ "$_line" != "$_prev" ]; then
      _acc="$_acc$_line"$'\n'
      _prev=$_line
      _first=0
    fi
  done < "$2"
  _dst=${_acc%$'\n'}
}

exists_word() { # <var> <path>
  local -n _dst=$1
  if [ -e "$2" ]; then _dst=present; else _dst=absent; fi
}

# =============================================================================
# THE FAKE herdr PAIR
# =============================================================================

make_fakebin() { # <dir> -> creates <dir>/fakebin with both fakes
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
# Fake herdr (bash side). Twin: herdr.cmd. See the suite header for the dispatch
# rule; neither fake carries scenario logic, only this lookup.
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
key="${1:-}-${2:-}"
state=initial
if [ -f "$FM_HERDR_STATE/st" ]; then
  IFS= read -r state < "$FM_HERDR_STATE/st" || true
  state=${state%$'\r'}
fi
n=0
if [ -f "$FM_HERDR_STATE/c-$key" ]; then
  IFS= read -r n < "$FM_HERDR_STATE/c-$key" || true
  n=${n%$'\r'}
fi
n=$((n + 1))
printf '%s\r\n' "$n" > "$FM_HERDR_STATE/c-$key"
if [ -f "$FM_HERDR_RESP/$key.act" ]; then
  IFS= read -r act < "$FM_HERDR_RESP/$key.act" || true
  act=${act%$'\r'}
  printf '%s\r\n' "$act" > "$FM_HERDR_STATE/st"
fi
body="$FM_HERDR_RESP/$key.$n.out"
[ -f "$body" ] || body="$FM_HERDR_RESP/$key.$state.out"
[ -f "$body" ] || body="$FM_HERDR_RESP/$key.out"
[ -f "$body" ] || body="$FM_HERDR_RESP/default.out"
[ ! -f "$body" ] || cat "$body"
code="$FM_HERDR_RESP/$key.$n.exit"
[ -f "$code" ] || code="$FM_HERDR_RESP/$key.$state.exit"
[ -f "$code" ] || code="$FM_HERDR_RESP/$key.exit"
if [ -f "$code" ]; then
  IFS= read -r rc < "$code" || true
  rc=${rc%$'\r'}
  exit "$rc"
fi
exit 0
SH
  chmod +x "$fb/herdr"
  # Batch twin. `%*` keeps the raw command line intact; `set /p` needs CRLF, so
  # every control file this reads is written CRLF and the bash twin strips the CR.
  {
    printf '@echo off\r\n'
    printf 'setlocal enabledelayedexpansion\r\n'
    printf '>>"%%FM_HERDR_LOG%%" echo %%*\r\n'
    printf 'set "key=%%~1-%%~2"\r\n'
    printf 'set "state=initial"\r\n'
    printf 'if exist "%%FM_HERDR_STATE%%\\st" set /p state=<"%%FM_HERDR_STATE%%\\st"\r\n'
    printf 'set "n=0"\r\n'
    printf 'if exist "%%FM_HERDR_STATE%%\\c-!key!" set /p n=<"%%FM_HERDR_STATE%%\\c-!key!"\r\n'
    printf 'set /a n=!n!+1\r\n'
    printf '>"%%FM_HERDR_STATE%%\\c-!key!" echo !n!\r\n'
    printf 'if exist "%%FM_HERDR_RESP%%\\!key!.act" (\r\n'
    printf '  set /p act=<"%%FM_HERDR_RESP%%\\!key!.act"\r\n'
    printf '  >"%%FM_HERDR_STATE%%\\st" echo !act!\r\n'
    printf ')\r\n'
    printf 'set "body=%%FM_HERDR_RESP%%\\!key!.!n!.out"\r\n'
    printf 'if not exist "!body!" set "body=%%FM_HERDR_RESP%%\\!key!.!state!.out"\r\n'
    printf 'if not exist "!body!" set "body=%%FM_HERDR_RESP%%\\!key!.out"\r\n'
    printf 'if not exist "!body!" set "body=%%FM_HERDR_RESP%%\\default.out"\r\n'
    printf 'if exist "!body!" type "!body!"\r\n'
    printf 'set "code=%%FM_HERDR_RESP%%\\!key!.!n!.exit"\r\n'
    printf 'if not exist "!code!" set "code=%%FM_HERDR_RESP%%\\!key!.!state!.exit"\r\n'
    printf 'if not exist "!code!" set "code=%%FM_HERDR_RESP%%\\!key!.exit"\r\n'
    printf 'if exist "!code!" (\r\n'
    printf '  set /p rc=<"!code!"\r\n'
    printf '  exit /b !rc!\r\n'
    printf ')\r\n'
    printf 'exit /b 0\r\n'
  } > "$fb/herdr.cmd"
}

# =============================================================================
# PHASE B - entrypoint cases (fm-herdr-lab, fm-herdr-ci-cleanup)
# =============================================================================
#
# Record: label \t ps-script \t fakebin \t pathmode \t envspec \t argspec
# Each world owns its own scenario tree, built by the same builder, so the two
# runs cannot interfere through the fake's counters or state file.

B_SH=''
B_PS=''
B_FB_SH=''
B_FB_PS=''

# new_scenario <name>: creates <name>/sh and <name>/ps under $1's root, each with
# resp/, fkstate/ and a fakebin. Returns through B_* (no subshell - a failure
# inside one could not reach the parent's counters).
new_scenario() { # <root> <name>
  B_SH="$1/$2/sh"
  B_PS="$1/$2/ps"
  local w
  for w in "$B_SH" "$B_PS"; do
    mkdir -p "$w/resp" "$w/fkstate" "$w/tripwires"
    make_fakebin "$w"
    : > "$w/herdr.log"
  done
  B_FB_SH="$B_SH/fakebin"
  B_FB_PS="$B_PS/fakebin"
}

# resp <relative-name> <<'EOF' ... : writes the same fixture into both worlds.
resp() { # <name>  (body on stdin)
  local name=$1 body
  body=$(cat)
  printf '%s\n' "$body" > "$B_SH/resp/$name"
  printf '%s\n' "$body" > "$B_PS/resp/$name"
}

resp_line() { # <name> <text>   (control files the fakes read with `set /p`)
  printf '%s\r\n' "$2" > "$B_SH/resp/$1"
  printf '%s\r\n' "$2" > "$B_PS/resp/$1"
}

both() { # <relative path under the world root> <content>   plain LF file
  printf '%s\n' "$2" > "$B_SH/$1"
  printf '%s\n' "$2" > "$B_PS/$1"
}

# add_case <label> <sh-script> <ps-script> <pathmode> <extra-envspec> <argspec>
# Runs the bash oracle immediately and appends the PowerShell half.
add_case() {
  local label=$1 sh=$2 ps=$3 pathmode=$4 extra=$5 argspec=$6 rc=0
  local envspec_sh envspec_ps common_sh common_ps
  common_sh="FM_HERDR_LOG=$B_SH/herdr.log${US}FM_HERDR_RESP=$B_SH/resp${US}FM_HERDR_STATE=$B_SH/fkstate${US}FM_HERDR_LAB_STATE_DIR=$B_SH/tripwires${US}FM_ROOT_OVERRIDE=$B_SH${US}FM_HOME=$B_SH"
  common_ps="FM_HERDR_LOG=$B_PS/herdr.log${US}FM_HERDR_RESP=$B_PS/resp${US}FM_HERDR_STATE=$B_PS/fkstate${US}FM_HERDR_LAB_STATE_DIR=$B_PS/tripwires${US}FM_ROOT_OVERRIDE=$B_PS${US}FM_HOME=$B_PS"
  envspec_sh=$common_sh
  envspec_ps=$common_ps
  if [ -n "$extra" ]; then
    envspec_sh="$envspec_sh${US}${extra//@W@/$B_SH}"
    envspec_ps="$envspec_ps${US}${extra//@W@/$B_PS}"
  fi

  local argspec_sh=${argspec//@W@/$B_SH}
  local argspec_ps=${argspec//@W@/$B_PS}

  local -a envpairs=() argv=()
  IFS=$US read -r -a envpairs <<< "$envspec_sh"
  if [ "$argspec_sh" != "-" ]; then
    IFS=$RS read -r -a argv <<< "$argspec_sh"
    local i
    for i in "${!argv[@]}"; do
      [ "${argv[$i]}" != "$EMPTY" ] || argv[$i]=''
    done
  fi

  local path_sh
  case "$pathmode" in
    prefix) path_sh="$B_FB_SH:$PATH" ;;
    only) path_sh="$B_SH/emptybin" ; mkdir -p "$path_sh" ;;
    *) fail "unknown pathmode: $pathmode" ;;
  esac

  # BASH_BIN is absolute: the `only` path mode replaces PATH outright, so a bare
  # `bash` would not resolve through `env`.
  env PATH="$path_sh" "${envpairs[@]}" "$BASH_BIN" "$_suite_root/bin/$sh" \
    ${argv[@]+"${argv[@]}"} > "$OUT/$label.sh.out" 2> "$OUT/$label.sh.err" || rc=$?
  printf '%s\n' "$rc" > "$OUT/$label.sh.rc"

  local fb_ps="$B_FB_PS"
  [ "$pathmode" != only ] || { fb_ps="$B_PS/emptybin"; mkdir -p "$fb_ps"; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$ps" "$fb_ps" "$pathmode" "$envspec_ps" "$argspec_ps" >> "$CASES_B"
}

compare_case() { # <label>
  local shout sherr shrc psout pserr psrc
  [ -f "$OUT/$1.ps.rc" ] || fail "$1: the PowerShell driver produced no result"
  read_file shrc "$OUT/$1.sh.rc"; read_file psrc "$OUT/$1.ps.rc"
  read_file shout "$OUT/$1.sh.out"; read_file psout "$OUT/$1.ps.out"
  read_file sherr "$OUT/$1.sh.err"; read_file pserr "$OUT/$1.ps.err"
  # The two worlds run in SEPARATE scratch directories (.../sh vs .../ps) so
  # they cannot interfere, and @W@ expands to each world's own. A message that
  # reports the path it just wrote therefore differs by that segment ALONE.
  # Fold both back to the placeholder so the assertion tests the message, not
  # the directory the case happened to run in. Anything else that differs -
  # including a path the twin got genuinely wrong - still fails.
  shout=${shout//$B_SH/@W@}; psout=${psout//$B_PS/@W@}
  sherr=${sherr//$B_SH/@W@}; pserr=${pserr//$B_PS/@W@}
  assert_eq "$psrc" "$shrc" "$1: exit code differs"
  assert_eq "$psout" "$shout" "$1: stdout differs"
  assert_eq "$pserr" "$sherr" "$1: stderr differs"
}

compare_logs() { # <label-for-message>
  local a b
  normalize_log a "$B_PS/herdr.log"
  normalize_log b "$B_SH/herdr.log"
  assert_eq "$a" "$b" "$1: the two worlds issued different Herdr commands"
}

# Normalization 2, strong form: provision starts the lab server in the
# BACKGROUND and then polls, so neither the number of `status --json` calls nor
# their position relative to the `server` call is deterministic in either world.
# Those scenarios compare the SET of distinct commands issued, which still
# catches any call one twin makes and the other does not.
compare_log_sets() { # <label-for-message>
  local a b
  a=$(tr -d '\r' < "$B_PS/herdr.log" | sort -u)
  b=$(tr -d '\r' < "$B_SH/herdr.log" | sort -u)
  assert_eq "$a" "$b" "$1: the two worlds issued different Herdr commands"
}

compare_world_file() { # <relative path> <label>
  local a b
  read_file a "$B_PS/$1"
  read_file b "$B_SH/$1"
  assert_eq "$a" "$b" "$2"
}

compare_world_presence() { # <relative path> <label>
  local a b
  exists_word a "$B_PS/$1"
  exists_word b "$B_SH/$1"
  assert_eq "$a" "$b" "$2"
}

# --- shared session-list fixtures --------------------------------------------

LAB_NAME=fm-lab-diff
DEFAULT_SOCK=/home/test/.config/herdr/herdr.sock
# The exact `jq -c` spelling the tripwire is written in, restated here so the
# comparison is against an INDEPENDENT expectation and not just PS-vs-PS.
TRIPWIRE_JSON="{\"name\":\"default\",\"default\":true,\"running\":true,\"socket_path\":\"$DEFAULT_SOCK\"}"

lab_fixtures() { # writes the standard lab response set into the current scenario
  resp session-list.initial.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"}]}
EOF
  resp session-list.deleted.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"}]}
EOF
  resp session-list.running.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"$LAB_NAME","running":true,"socket_path":"/tmp/$LAB_NAME.sock"}]}
EOF
  resp session-list.stopped.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"$LAB_NAME","running":false,"socket_path":"/tmp/$LAB_NAME.sock"}]}
EOF
  resp status---json.initial.out <<'EOF'
{"client":{"version":"0.7.5","protocol":18},"server":{"running":false}}
EOF
  resp status---json.stopped.out <<'EOF'
{"client":{"version":"0.7.5","protocol":18},"server":{"running":false}}
EOF
  resp status---json.deleted.out <<'EOF'
{"client":{"version":"0.7.5","protocol":18},"server":{"running":false}}
EOF
  resp status---json.running.out <<'EOF'
{"client":{"version":"0.7.5","protocol":18},"server":{"running":true}}
EOF
  resp workspace-list.out <<'EOF'
{"result":{"workspaces":[]}}
EOF
  resp default.out <<'EOF'
{"ok":true}
EOF
  resp_line 'server---session.act' running
  resp_line 'session-stop.act' stopped
  resp_line 'session-delete.act' deleted
  resp session-stop.out <<'EOF'
{"ok":true}
EOF
  resp session-delete.out <<'EOF'
{"ok":true}
EOF
}

lab_case() { # <label> <argspec>
  add_case "$1" fm-herdr-lab.sh fm-herdr-lab.ps1 prefix '' "$2"
}

set_state() { # <state>   seed the fake's state machine in both worlds
  printf '%s\r\n' "$1" > "$B_SH/fkstate/st"
  printf '%s\r\n' "$1" > "$B_PS/fkstate/st"
}

write_tripwire() { # <content>
  printf '%s\n' "$1" > "$B_SH/tripwires/$LAB_NAME.fleet-state.json"
  printf '%s\n' "$1" > "$B_PS/tripwires/$LAB_NAME.fleet-state.json"
}

progress 'phase 1: fm-herdr-lab oracle runs'

# --- usage and argument shape (no Herdr call at all) -------------------------
new_scenario "$LAB" usage
lab_fixtures
lab_case lab-help '--help'
lab_case lab-h '-h'
lab_case lab-help-word 'help'
lab_case lab-bogus 'bogus'
lab_case lab-noargs '-'
lab_case lab-name-noarg 'name'
lab_case lab-run-short "run${RS}$LAB_NAME"
LAB_USAGE_SH=$B_SH
LAB_USAGE_PS=$B_PS

# --- name generation ---------------------------------------------------------
new_scenario "$LAB" names
lab_fixtures
lab_case name-plain "name${RS}fm-autodetect-smoke-concurrency-h3"
lab_case name-punct "name${RS}--weird..label--"
lab_case name-allpunct "name${RS}!!!"
lab_case name-underscores "name${RS}___"
lab_case name-dashes "name${RS}----"
lab_case name-cap "name${RS}abcdefghijklmno-pqrst"
lab_case name-short "name${RS}a"
NAMES_SH=$B_SH
NAMES_PS=$B_PS

# --- name refusals -----------------------------------------------------------
new_scenario "$LAB" refuse
lab_fixtures
lab_case refuse-default "prepare${RS}default"
lab_case refuse-empty "prepare${RS}$EMPTY"
lab_case refuse-arbitrary "prepare${RS}arbitrary-session"
lab_case refuse-badchars "prepare${RS}fm-lab-bad.name"
lab_case refuse-prefix-only "prepare${RS}fm-lab-"
REFUSE_SH=$B_SH
REFUSE_PS=$B_PS

# --- prepare -----------------------------------------------------------------
new_scenario "$LAB" prepare
lab_fixtures
lab_case prepare-ok "prepare${RS}$LAB_NAME"
lab_case prepare-twice "prepare${RS}$LAB_NAME"
PREPARE_SH=$B_SH
PREPARE_PS=$B_PS

new_scenario "$LAB" prepare-exists
lab_fixtures
set_state running
lab_case prepare-adopt "prepare${RS}$LAB_NAME"
PREPARE_EXISTS_SH=$B_SH
PREPARE_EXISTS_PS=$B_PS

# The fleet-state tripwire refuses a fleet it cannot recognize: two default
# sessions, or a default that is not running, are both "not exactly one".
new_scenario "$LAB" prepare-nofleet
lab_fixtures
resp session-list.initial.out <<EOF
{"sessions":[{"default":true,"name":"default","running":false,"socket_path":"$DEFAULT_SOCK"}]}
EOF
lab_case prepare-nofleet "prepare${RS}$LAB_NAME"
NOFLEET_SH=$B_SH
NOFLEET_PS=$B_PS

new_scenario "$LAB" prepare-twodefaults
lab_fixtures
resp session-list.initial.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":true,"name":"other","running":true,"socket_path":"/tmp/other.sock"}]}
EOF
lab_case prepare-twodefaults "prepare${RS}$LAB_NAME"
TWODEF_SH=$B_SH
TWODEF_PS=$B_PS

# A session-list call that fails outright.
new_scenario "$LAB" prepare-listfail
lab_fixtures
printf '1\r\n' > "$B_SH/resp/session-list.exit"
printf '1\r\n' > "$B_PS/resp/session-list.exit"
lab_case prepare-listfail "prepare${RS}$LAB_NAME"
LISTFAIL_SH=$B_SH
LISTFAIL_PS=$B_PS

# --- the run allowlist -------------------------------------------------------
new_scenario "$LAB" run
lab_fixtures
resp workspace-list.out <<'EOF'
{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}
EOF
lab_case run-ok "run${RS}$LAB_NAME${RS}workspace${RS}list"
lab_case run-server "run${RS}$LAB_NAME${RS}server"
lab_case run-server-stop "run${RS}$LAB_NAME${RS}server${RS}stop"
lab_case run-session-delete "run${RS}$LAB_NAME${RS}session${RS}delete${RS}$LAB_NAME"
lab_case run-session-stop "run${RS}$LAB_NAME${RS}session${RS}stop${RS}$LAB_NAME"
lab_case run-session-list "run${RS}$LAB_NAME${RS}session${RS}list"
lab_case run-session-flag "run${RS}$LAB_NAME${RS}status${RS}--session${RS}default"
lab_case run-session-equals "run${RS}$LAB_NAME${RS}status${RS}--session=default"
lab_case run-leading-option "run${RS}$LAB_NAME${RS}--handoff${RS}server${RS}stop"
lab_case run-leading-nosession "run${RS}$LAB_NAME${RS}--no-session${RS}session${RS}delete${RS}$LAB_NAME"
lab_case run-leading-remote "run${RS}$LAB_NAME${RS}--remote${RS}host${RS}workspace${RS}list"
lab_case run-bad-name "run${RS}default${RS}workspace${RS}list"
RUN_SH=$B_SH
RUN_PS=$B_PS

# --- provision ---------------------------------------------------------------
new_scenario "$LAB" provision
lab_fixtures
lab_case provision-fresh "provision${RS}$LAB_NAME"
PROVISION_SH=$B_SH
PROVISION_PS=$B_PS

new_scenario "$LAB" reprovision
lab_fixtures
set_state stopped
write_tripwire "$TRIPWIRE_JSON"
lab_case provision-owned-stopped "provision${RS}$LAB_NAME"
REPROV_SH=$B_SH
REPROV_PS=$B_PS

new_scenario "$LAB" provision-running
lab_fixtures
set_state running
write_tripwire "$TRIPWIRE_JSON"
lab_case provision-not-stopped "provision${RS}$LAB_NAME"
PROVRUN_SH=$B_SH
PROVRUN_PS=$B_PS

new_scenario "$LAB" provision-unowned
lab_fixtures
set_state running
lab_case provision-unowned "provision${RS}$LAB_NAME"
PROVUNOWNED_SH=$B_SH
PROVUNOWNED_PS=$B_PS

# --- guarded stop ------------------------------------------------------------
new_scenario "$LAB" stop
lab_fixtures
set_state running
write_tripwire "$TRIPWIRE_JSON"
lab_case stop-ok "stop${RS}$LAB_NAME"
STOP_SH=$B_SH
STOP_PS=$B_PS

new_scenario "$LAB" stop-notripwire
lab_fixtures
set_state running
lab_case stop-no-tripwire "stop${RS}$LAB_NAME"
STOPNT_SH=$B_SH
STOPNT_PS=$B_PS

# --- teardown ----------------------------------------------------------------
new_scenario "$LAB" teardown
lab_fixtures
set_state running
write_tripwire "$TRIPWIRE_JSON"
lab_case teardown-ok "teardown${RS}$LAB_NAME"
TEARDOWN_SH=$B_SH
TEARDOWN_PS=$B_PS

new_scenario "$LAB" teardown-notripwire
lab_fixtures
set_state running
lab_case teardown-no-tripwire "teardown${RS}$LAB_NAME"
TDNT_SH=$B_SH
TDNT_PS=$B_PS

new_scenario "$LAB" teardown-absent
lab_fixtures
write_tripwire "$TRIPWIRE_JSON"
lab_case teardown-absent "teardown${RS}$LAB_NAME"
TDABS_SH=$B_SH
TDABS_PS=$B_PS

new_scenario "$LAB" teardown-stale
lab_fixtures
set_state running
write_tripwire "{\"name\":\"default\",\"default\":true,\"running\":true,\"socket_path\":\"/changed/default.sock\"}"
lab_case teardown-stale-tripwire "teardown${RS}$LAB_NAME"
TDSTALE_SH=$B_SH
TDSTALE_PS=$B_PS

new_scenario "$LAB" teardown-deletefail
lab_fixtures
set_state running
write_tripwire "$TRIPWIRE_JSON"
rm -f "$B_SH/resp/session-delete.act" "$B_PS/resp/session-delete.act"
printf '93\r\n' > "$B_SH/resp/session-delete.exit"
printf '93\r\n' > "$B_PS/resp/session-delete.exit"
lab_case teardown-delete-failed "teardown${RS}$LAB_NAME"
TDFAIL_SH=$B_SH
TDFAIL_PS=$B_PS

# The refuse-default check is re-read immediately before each destructive call,
# so a session that becomes default between the stop and the delete must stop
# the delete. Only per-call responses can prove that.
new_scenario "$LAB" teardown-becomes-default
lab_fixtures
resp session-list.1.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"$LAB_NAME","running":true,"socket_path":"/tmp/$LAB_NAME.sock"}]}
EOF
resp session-list.2.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"$LAB_NAME","running":true,"socket_path":"/tmp/$LAB_NAME.sock"}]}
EOF
resp session-list.3.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":true,"name":"$LAB_NAME","running":true,"socket_path":"/tmp/$LAB_NAME.sock"}]}
EOF
set_state running
write_tripwire "$TRIPWIRE_JSON"
lab_case teardown-becomes-default "teardown${RS}$LAB_NAME"
TDDEF_SH=$B_SH
TDDEF_PS=$B_PS

# =============================================================================
# fm-herdr-ci-cleanup
# =============================================================================

progress 'phase 1: fm-herdr-ci-cleanup oracle runs'

ci_case() { # <label> <pathmode> <argspec>
  add_case "$1" fm-herdr-ci-cleanup.sh fm-herdr-ci-cleanup.ps1 "$2" '' "$3"
}

ci_fixtures() {
  resp session-list.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"fm-lab-known","running":true,"socket_path":"/tmp/a.sock"},{"default":false,"name":"fm-lab-owned","running":true,"socket_path":"/tmp/b.sock"},{"default":false,"name":"scratch","running":true,"socket_path":"/tmp/c.sock"}]}
EOF
  resp default.out <<'EOF'
{"ok":true}
EOF
}

new_scenario "$CI" shape
ci_fixtures
ci_case ci-noargs prefix '-'
ci_case ci-oneargs prefix 'snapshot'
ci_case ci-unknown prefix "bogus${RS}@W@/snap.json"
CI_SHAPE_SH=$B_SH
CI_SHAPE_PS=$B_PS

new_scenario "$CI" noherdr
ci_fixtures
ci_case ci-no-herdr only "snapshot${RS}@W@/snap.json"
CI_NOHERDR_SH=$B_SH
CI_NOHERDR_PS=$B_PS

new_scenario "$CI" snapshot
ci_fixtures
ci_case ci-snapshot prefix "snapshot${RS}@W@/snap.json"
CI_SNAP_SH=$B_SH
CI_SNAP_PS=$B_PS

new_scenario "$CI" snapshot-empty
ci_fixtures
resp session-list.out <<'EOF'
{"sessions":[]}
EOF
ci_case ci-snapshot-empty prefix "snapshot${RS}@W@/snap.json"
CI_SNAPEMPTY_SH=$B_SH
CI_SNAPEMPTY_PS=$B_PS

new_scenario "$CI" teardown-missing
ci_fixtures
ci_case ci-teardown-missing prefix "teardown${RS}@W@/nope.json"
CI_TDMISS_SH=$B_SH
CI_TDMISS_PS=$B_PS

new_scenario "$CI" teardown-none
ci_fixtures
both snap.json '["default","fm-lab-known","fm-lab-owned","scratch"]'
ci_case ci-teardown-none prefix "teardown${RS}@W@/snap.json"
CI_TDNONE_SH=$B_SH
CI_TDNONE_PS=$B_PS

new_scenario "$CI" teardown-clean
ci_fixtures
both snap.json '["default","fm-lab-known","scratch"]'
ci_case ci-teardown-clean prefix "teardown${RS}@W@/snap.json"
CI_TDCLEAN_SH=$B_SH
CI_TDCLEAN_PS=$B_PS

new_scenario "$CI" teardown-becomes-default
ci_fixtures
both snap.json '["default","fm-lab-known","scratch"]'
resp session-list.2.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":true,"name":"fm-lab-owned","running":true,"socket_path":"/tmp/b.sock"}]}
EOF
ci_case ci-teardown-becomes-default prefix "teardown${RS}@W@/snap.json"
CI_TDDEF_SH=$B_SH
CI_TDDEF_PS=$B_PS

new_scenario "$CI" teardown-default-after-stop
ci_fixtures
both snap.json '["default","fm-lab-known","scratch"]'
resp session-list.3.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":true,"name":"fm-lab-owned","running":true,"socket_path":"/tmp/b.sock"}]}
EOF
ci_case ci-teardown-default-after-stop prefix "teardown${RS}@W@/snap.json"
CI_TDAFTER_SH=$B_SH
CI_TDAFTER_PS=$B_PS

new_scenario "$CI" teardown-delete-failed
ci_fixtures
both snap.json '["default","fm-lab-known","scratch"]'
printf '7\r\n' > "$B_SH/resp/session-delete.exit"
printf '7\r\n' > "$B_PS/resp/session-delete.exit"
ci_case ci-teardown-delete-failed prefix "teardown${RS}@W@/snap.json"
CI_TDDELFAIL_SH=$B_SH
CI_TDDELFAIL_PS=$B_PS

new_scenario "$CI" teardown-already-absent
ci_fixtures
both snap.json '["default","fm-lab-known","scratch"]'
printf '7\r\n' > "$B_SH/resp/session-delete.exit"
printf '7\r\n' > "$B_PS/resp/session-delete.exit"
resp session-list.4.out <<EOF
{"sessions":[{"default":true,"name":"default","running":true,"socket_path":"$DEFAULT_SOCK"},{"default":false,"name":"fm-lab-known","running":true,"socket_path":"/tmp/a.sock"}]}
EOF
ci_case ci-teardown-already-absent prefix "teardown${RS}@W@/snap.json"
CI_TDABSENT_SH=$B_SH
CI_TDABSENT_PS=$B_PS

# =============================================================================
# PHASE C - fm-herdr-session-cleanup
# =============================================================================
#
# Driven through the same fake herdr, plus three overrides installed on BOTH
# sides for the parts a fake CLI genuinely cannot model:
#
#   presentation lock path  - the real one hashes a socket path into a
#                             machine-private namespace shared by every home on
#                             the box; a suite must not write there.
#   idle-shell proof        - a process-identity read against real pids.
#   focus-preserving close  - owned (and covered) by the backend adapter's own
#                             suite; here it is a recorder that also flips the
#                             fake's state so the pane reads as gone.
#
# Everything else - discovery, the journal grammar, the locked snapshot filter,
# revalidation, the warnings, and the journal retirement - is the real code on
# both sides.

progress 'phase 2: fm-herdr-session-cleanup oracle runs'

SC_SH="$SC/sh"
SC_PS="$SC/ps"
mkdir -p "$SC_SH" "$SC_PS"
for w in "$SC_SH" "$SC_PS"; do
  mkdir -p "$w/home/state" "$w/home/config" "$w/resp" "$w/fkstate" "$w/fixture"
  make_fakebin "$w"
  : > "$w/herdr.log"
  printf 'herdr\n' > "$w/home/config/backend"
  touch "$w/home/config/herdr-presentation-spaces"
done

SC_TOKEN=AbCdEfGhIjKlMnOpQrStUv
SC_ID=task
SC_WS=w2
SC_TAB=w2:t1
SC_PANE=w2:p1
SC_TITLE="└ task · p:$SC_TOKEN"

# --- the case template builder -----------------------------------------------
#
# Each case writes a self-contained template under $SC/cases/<label>/{state,resp}
# which BOTH worlds copy in before running. That is what lets the PowerShell
# driver replay a case the oracle already consumed: no fixture is mutated in
# place between the two runs.

CT=''
sc_begin() { # <label>
  CT="$SC/cases/$1"
  rm -rf "$CT"
  mkdir -p "$CT/state" "$CT/resp" "$CT/fixture"
  sc_default_resp
}

sc_resp() { # <name>  (body on stdin)
  cat > "$CT/resp/$1"
}

sc_workspaces() { # <label-for-w2> [extra]
  printf '[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},'
  printf '{"workspace_id":"%s","label":"%s","focused":false,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}' \
    "$SC_WS" "$1" "$SC_TAB" "${2:-1}" "${3:-1}"
  [ -z "${4:-}" ] || printf ',%s' "$4"
  printf ']'
}

sc_default_resp() {
  local ws
  ws=$(sc_workspaces "$SC_TITLE")
  printf '{"result":{"workspaces":%s}}\n' "$ws" > "$CT/resp/workspace-list.out"
  printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s","focused":false,"active_tab_id":"%s","tab_count":1,"pane_count":1}}}\n' \
    "$SC_WS" "$SC_TITLE" "$SC_TAB" > "$CT/resp/workspace-get.out"
  printf '{"result":{"tabs":[{"tab_id":"%s","workspace_id":"%s","focused":false,"label":"fm-task"}]}}\n' \
    "$SC_TAB" "$SC_WS" > "$CT/resp/tab-list.out"
  printf '{"result":{"panes":[{"pane_id":"%s","tab_id":"%s","workspace_id":"%s","agent_status":"unknown"}]}}\n' \
    "$SC_PANE" "$SC_TAB" "$SC_WS" > "$CT/resp/pane-list.out"
  printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' \
    "$SC_PANE" "$SC_TAB" "$SC_WS" > "$CT/resp/pane-get.out"
  printf '{"error":{"code":"pane_not_found"}}\n' > "$CT/resp/pane-get.closed.out"
  printf '1\r\n' > "$CT/resp/pane-get.closed.exit"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$CT/resp/agent-get.out"
  printf '1\r\n' > "$CT/resp/agent-get.exit"
  printf '{"client":{"version":"0.7.5","protocol":18},"server":{"running":true}}\n' > "$CT/resp/status---json.out"
  printf '{"ok":true}\n' > "$CT/resp/default.out"
  sc_snapshot "$SC_TITLE" w1:t1
}

sc_snapshot() { # <w2-label> <focused-tab> [tabs] [panes] [extra-workspace]
  local label=$1 focused=$2 tabs=${3:-1} panes=${4:-1} extra=${5:-} ws tabjson panejson i
  ws=$(sc_workspaces "$label" "$tabs" "$panes" "$extra")
  tabjson='['
  i=1
  while [ "$i" -le "$tabs" ]; do
    [ "$i" -eq 1 ] || tabjson="$tabjson,"
    tabjson="$tabjson{\"tab_id\":\"$SC_WS:t$i\",\"workspace_id\":\"$SC_WS\",\"focused\":false,\"label\":\"fm-task\"}"
    i=$((i + 1))
  done
  tabjson="$tabjson]"
  panejson='['
  i=1
  while [ "$i" -le "$panes" ]; do
    [ "$i" -eq 1 ] || panejson="$panejson,"
    panejson="$panejson{\"pane_id\":\"$SC_WS:p$i\",\"tab_id\":\"$SC_WS:t$i\",\"workspace_id\":\"$SC_WS\",\"agent_status\":\"unknown\"}"
    i=$((i + 1))
  done
  panejson="$panejson]"
  printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"w1:p1","workspaces":%s,"tabs":%s,"panes":%s}}}\n' \
    "$focused" "$ws" "$tabjson" "$panejson" > "$CT/resp/api-snapshot.out"
}

sc_journal_v1() { # <id> [token]
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$1"
    printf 'projection_id=%s\n' "${2:-$SC_TOKEN}"
  } > "$CT/state/$1.herdr-presentation"
}

sc_journal_v2() { # <home> <workspace> <tab> <pane>
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$SC_ID"
    printf 'projection_id=%s\n' "$SC_TOKEN"
    printf 'home=%s\n' "$1"
    printf 'session=fmdiff\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$2" "$3" "$4"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' \
      "$SC_TITLE" "$SC_ID"
  } > "$CT/state/$SC_ID.herdr-presentation"
}

# A version 2 journal names its home, and each world has a different one, so the
# home field is a per-world SUBSTITUTION rather than a literal. @HOME@ is
# replaced with that world's own home path when the template is copied.
sc_journal_v2_home() { sc_journal_v2 '@HOME@' "$SC_WS" "$SC_TAB" "$SC_PANE"; }

SC_LABELS=()
sc_run() { # <label>
  local label=$1
  SC_LABELS+=("$label")
  printf '%s\n' "$label" >> "$CASES_C"
  sc_oracle "$label"
}

progress 'phase 2: building fm-herdr-session-cleanup cases'

# =============================================================================
# PHASE 3 - one pwsh for every PowerShell case
# =============================================================================
# (declared here; invoked after the oracle half below)

# --- the bash oracle runner --------------------------------------------------
#
# Sourced ONCE with the source-only guard, exactly as tests/fm-herdr-session-
# cleanup.test.sh does, then driven per case. Sourcing per case would re-source
# the backend adapter every time, and the oracle half is already fork-bound.

export FM_HOME="$SC_SH/home"
export FM_ROOT_OVERRIDE="$SC_SH/home"
export FM_STATE_OVERRIDE="$SC_SH/home/state"
export FM_CONFIG_OVERRIDE="$SC_SH/home/config"
export HERDR_SESSION=fmdiff
export FM_SC_FIXTURE="$SC_SH/fixture"
export FM_HERDR_LOG="$SC_SH/herdr.log"
export FM_HERDR_RESP="$SC_SH/resp"
export FM_HERDR_STATE="$SC_SH/fkstate"
export PATH="$SC_SH/fakebin:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$_suite_root/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

# The three overrides. Each is the bash half of a pair whose PowerShell half
# lives in the driver below; they must agree in behavior, not in spelling.
# shellcheck disable=SC2329 # invoked indirectly by the code under test.
fm_backend_herdr_presentation_session_lock_path() {
  printf '%s/presentation.lock' "$FM_SC_FIXTURE"
}
# shellcheck disable=SC2329 # invoked indirectly by the code under test.
fm_backend_herdr_pane_idle_shell_pid() {
  [ ! -e "$FM_SC_FIXTURE/process-unsafe" ] && printf '67\n'
}
# shellcheck disable=SC2329 # invoked indirectly by the code under test.
fm_backend_herdr_projection_close_pane_focus_preserving() {
  [ ! -e "$FM_SC_FIXTURE/focus-refuse" ] || return 1
  [ "${3:-}" = no-agent ] || return 1
  printf '%s\n' "$*" >> "$FM_SC_FIXTURE/closes.log"
  [ -e "$FM_SC_FIXTURE/close-unconfirmed" ] || printf 'closed\r\n' > "$FM_HERDR_STATE/st"
  return 0
}

sc_oracle() { # <label>   resets the bash world, copies the template, runs
  local label=$1
  rm -rf "$SC_SH/home/state" "$SC_SH/resp" "$SC_SH/fkstate" "$SC_SH/fixture"
  mkdir -p "$SC_SH/home/state" "$SC_SH/resp" "$SC_SH/fkstate" "$SC_SH/fixture"
  : > "$SC_SH/herdr.log"
  : > "$SC_SH/fixture/closes.log"
  cp -R "$SC/cases/$label/resp/." "$SC_SH/resp/" 2>/dev/null || true
  cp -R "$SC/cases/$label/state/." "$SC_SH/home/state/" 2>/dev/null || true
  cp -R "$SC/cases/$label/fixture/." "$SC_SH/fixture/" 2>/dev/null || true
  sc_substitute_home "$SC_SH/home/state" "$SC_SH/home"
  fm_herdr_session_cleanup > "$OUT/sc-$label.sh.out" 2> "$OUT/sc-$label.sh.err"
  read_file _sc_journal_state ''
  if [ -e "$SC_SH/home/state/$SC_ID.herdr-presentation" ]; then
    printf 'present\n' > "$OUT/sc-$label.sh.journal"
  else
    printf 'absent\n' > "$OUT/sc-$label.sh.journal"
  fi
  cp "$SC_SH/fixture/closes.log" "$OUT/sc-$label.sh.closes"
  cp "$SC_SH/herdr.log" "$OUT/sc-$label.sh.log"
}

# @HOME@ substitution without sed: journals are three to twelve short lines.
sc_substitute_home() { # <state-dir> <home>
  local f line acc
  for f in "$1"/*.herdr-presentation; do
    [ -f "$f" ] || continue
    acc=''
    while IFS= read -r line || [ -n "$line" ]; do
      acc="$acc${line//@HOME@/$2}"$'\n'
    done < "$f"
    printf '%s' "$acc" > "$f"
  done
}

# --- the cases ---------------------------------------------------------------

sc_begin sc-positive-v1;      sc_journal_v1 "$SC_ID";                       sc_run sc-positive-v1
sc_begin sc-no-journal;                                                     sc_run sc-no-journal
sc_begin sc-malformed-title
sc_default_resp
printf '{"result":{"workspaces":%s}}\n' "$(sc_workspaces "└ malformed p:$SC_TOKEN")" > "$CT/resp/workspace-list.out"
sc_journal_v1 "$SC_ID";                                                     sc_run sc-malformed-title
sc_begin sc-missing-token
printf '{"result":{"workspaces":%s}}\n' "$(sc_workspaces '└ missing-token')" > "$CT/resp/workspace-list.out"
sc_journal_v1 "$SC_ID";                                                     sc_run sc-missing-token
sc_begin sc-double-token
printf '{"result":{"workspaces":%s}}\n' "$(sc_workspaces "└ task · p:$SC_TOKEN p:$SC_TOKEN")" > "$CT/resp/workspace-list.out"
sc_journal_v1 "$SC_ID";                                                     sc_run sc-double-token
sc_begin sc-short-token
printf 'version=1\ntask_id=%s\nprojection_id=short\n' "$SC_ID" > "$CT/state/$SC_ID.herdr-presentation"
sc_run sc-short-token
sc_begin sc-zero-journal;                                                   :
sc_journal_v1 other-task;                                                   sc_run sc-zero-journal
sc_begin sc-two-journals
sc_journal_v1 "$SC_ID"; sc_journal_v1 "fm-$SC_ID";                          sc_run sc-two-journals
sc_begin sc-duplicate-token
sc_snapshot "$SC_TITLE" w1:t1 1 1 "{\"workspace_id\":\"w3\",\"label\":\"└ copy · p:$SC_TOKEN\",\"focused\":false,\"active_tab_id\":\"w3:t1\",\"tab_count\":1,\"pane_count\":1}"
printf '{"result":{"workspaces":%s}}\n' \
  "$(sc_workspaces "$SC_TITLE" 1 1 "{\"workspace_id\":\"w3\",\"label\":\"└ copy · p:$SC_TOKEN\",\"focused\":false,\"active_tab_id\":\"w3:t1\",\"tab_count\":1,\"pane_count\":1}")" \
  > "$CT/resp/workspace-list.out"
sc_journal_v1 "$SC_ID";                                                     sc_run sc-duplicate-token
sc_begin sc-cross-home
sc_journal_v2 "$SC/other-home" "$SC_WS" "$SC_TAB" "$SC_PANE";                sc_run sc-cross-home
sc_begin sc-v2-match;         sc_journal_v2_home;                            sc_run sc-v2-match
sc_begin sc-v2-workspace-mismatch
sc_journal_v2 '@HOME@' w9 "$SC_TAB" "$SC_PANE";                              sc_run sc-v2-workspace-mismatch
sc_begin sc-v2-tab-mismatch
sc_journal_v2 '@HOME@' "$SC_WS" w9:t1 "$SC_PANE";                            sc_run sc-v2-tab-mismatch
sc_begin sc-v2-pane-mismatch
sc_journal_v2 '@HOME@' "$SC_WS" "$SC_TAB" w9:p1;                             sc_run sc-v2-pane-mismatch
sc_begin sc-task-meta
sc_journal_v1 "$SC_ID"; : > "$CT/state/$SC_ID.meta";                         sc_run sc-task-meta
sc_begin sc-agent-live
sc_journal_v1 "$SC_ID"
printf '{"result":{"agent":{"agent_status":"idle"}}}\n' > "$CT/resp/agent-get.out"
rm -f "$CT/resp/agent-get.exit";                                             sc_run sc-agent-live
sc_begin sc-agent-unknown
sc_journal_v1 "$SC_ID"
printf '{"error":{"code":"internal_error"}}\n' > "$CT/resp/agent-get.out";    sc_run sc-agent-unknown
sc_begin sc-multiple-tabs
sc_journal_v1 "$SC_ID"; sc_snapshot "$SC_TITLE" w1:t1 2 2;                   sc_run sc-multiple-tabs
sc_begin sc-multiple-panes
sc_journal_v1 "$SC_ID"; sc_snapshot "$SC_TITLE" w1:t1 1 2;                   sc_run sc-multiple-panes
sc_begin sc-process-unsafe
sc_journal_v1 "$SC_ID"; : > "$CT/fixture/process-unsafe";                     sc_run sc-process-unsafe
sc_begin sc-snapshot-error
sc_journal_v1 "$SC_ID"; printf '1\r\n' > "$CT/resp/api-snapshot.exit";        sc_run sc-snapshot-error
sc_begin sc-workspace-get-error
sc_journal_v1 "$SC_ID"; printf '1\r\n' > "$CT/resp/workspace-get.exit";       sc_run sc-workspace-get-error
sc_begin sc-revalidation-race
sc_journal_v1 "$SC_ID"
printf '{"result":{"workspaces":%s}}\n' "$(sc_workspaces renamed)" > "$CT/resp/workspace-list.2.out"
sc_run sc-revalidation-race
sc_begin sc-active-target
sc_journal_v1 "$SC_ID"; sc_snapshot "$SC_TITLE" "$SC_TAB";                   sc_run sc-active-target
sc_begin sc-discovery-error
sc_journal_v1 "$SC_ID"; printf '1\r\n' > "$CT/resp/workspace-list.exit";      sc_run sc-discovery-error
sc_begin sc-focus-refuse
sc_journal_v1 "$SC_ID"; : > "$CT/fixture/focus-refuse";                       sc_run sc-focus-refuse
sc_begin sc-close-unconfirmed
sc_journal_v1 "$SC_ID"; : > "$CT/fixture/close-unconfirmed";                  sc_run sc-close-unconfirmed

# =============================================================================
# PHASE 3 - one pwsh driver for every PowerShell case
# =============================================================================

progress 'phase 3: one pwsh driver for every PowerShell case'

cat > "$TMP_ROOT/driver.ps1" <<'PSEOF'
# One process, every case. See the suite header for why this shape is mandatory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$caseFileB = $args[0]
$caseFileC = $args[1]
$outDir    = $args[2]
$binDir    = $args[3]
$casesDir  = $args[4]
$scRoot    = $args[5]
$basePath  = $args[6]

# Deliberately NOT importing fm-common here: every entrypoint imports it with
# -Force, which REMOVES the loaded copy before re-importing, and the driver must
# not depend on a binding that can disappear mid-run. The one conversion needed
# is the MSYS drive form, inlined.
function ToNative([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    if ($p -match '^/([A-Za-z])(/|$)') { return ($Matches[1].ToUpperInvariant() + ':' + ($p.Substring(2) -replace '/', '\')) }
    return ($p -replace '/', '\')
}

$utf8 = [System.Text.UTF8Encoding]::new($false)
$unit = [char]0x1F
$record = [char]0x1E
$clearNames = @(
    'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
    'FM_CONFIG_OVERRIDE', 'FM_HERDR_LAB_STATE_DIR', 'FM_HERDR_LOG', 'FM_HERDR_RESP',
    'FM_HERDR_STATE', 'HERDR_SESSION', 'FM_BACKEND', 'CDPATH'
)

function Write-Result([string]$label, [string]$so, [string]$se, [string]$rc) {
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.out"), $so, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.err"), $se, $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.rc"), "$rc`n", $utf8)
}

# ---------------------------------------------------------------------------
# PHASE B - entrypoint cases, run FIRST.
#
# Order is load-bearing: each `&` invocation re-runs its script top to bottom,
# including `Import-Module fm-common.psm1 -Force`, and -Force REMOVES the loaded
# module globally before re-importing it. Doing all of those before phase C's
# single dot-source means no already-bound command can be pulled out from under
# a caller mid-run.
foreach ($line in [System.IO.File]::ReadAllLines($caseFileB)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = @($line.Split("`t"))
    if ($fields.Count -ne 6) { throw "malformed case record: $line" }
    $label = $fields[0]
    $script = $fields[1]
    $fakebin = ToNative $fields[2]
    $pathmode = $fields[3]
    $envSpec = $fields[4]
    $argSpec = $fields[5]

    foreach ($name in $clearNames) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
    if ($envSpec -ne '-') {
        foreach ($pair in @($envSpec.Split($unit))) {
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            # Every value in this suite is a path or a bare token; ToNative is a
            # no-op on the latter and the required conversion on the former.
            Set-Item -Path ('Env:' + $pair.Substring(0, $eq)) -Value (ToNative $pair.Substring($eq + 1))
        }
    }
    if ($pathmode -eq 'only') { $env:PATH = $fakebin } else { $env:PATH = "$fakebin;$basePath" }

    # Assigned in STATEMENT form: an `if` used as an expression writes through
    # the output stream, and the stream unrolls a single-element array into a
    # bare string, which then splats as one mangled argument.
    $argv = @()
    if ($argSpec -ne '-') {
        $argv = [string[]]@(@($argSpec.Split($record)) | ForEach-Object {
                if ($_ -eq '@EMPTY@') { '' } else { $_ } })
    }

    $oldOut = [Console]::Out
    $oldErr = [Console]::Error
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $global:LASTEXITCODE = -1
    $rc = -1
    try {
        & (Join-Path $binDir $script) @argv
        $rc = $LASTEXITCODE
    } catch {
        $rc = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        [Console]::SetOut($oldOut)
        [Console]::SetError($oldErr)
    }
    Write-Result $label $so.ToString() $se.ToString() $rc
}

# ---------------------------------------------------------------------------
# PHASE C - fm-herdr-session-cleanup, dot-sourced ONCE.
#
# The script resolves its state directory at LOAD time, exactly as the bash twin
# does, so the home is fixed for the whole phase and each case resets it - the
# same shape tests/fm-herdr-session-cleanup.test.sh uses.
$env:FM_HOME = ToNative "$scRoot/home"
$env:FM_ROOT_OVERRIDE = ToNative "$scRoot/home"
$env:FM_STATE_OVERRIDE = ToNative "$scRoot/home/state"
$env:FM_CONFIG_OVERRIDE = ToNative "$scRoot/home/config"
$env:HERDR_SESSION = 'fmdiff'
$env:FM_HERDR_LOG = ToNative "$scRoot/herdr.log"
$env:FM_HERDR_RESP = ToNative "$scRoot/resp"
$env:FM_HERDR_STATE = ToNative "$scRoot/fkstate"
$env:FM_SC_FIXTURE = ToNative "$scRoot/fixture"
$env:PATH = (ToNative "$scRoot/fakebin") + ';' + $basePath
$env:FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY = '1'

. (Join-Path $binDir 'fm-herdr-session-cleanup.ps1')

# The three overrides. Defined AFTER the dot-source and in the same scope, so
# they shadow the module-exported commands for every call the script makes.
function Get-FmBackendHerdrPresentationSessionLockPath {
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')
    return ((ToNative $env:FM_SC_FIXTURE) + '\presentation.lock')
}
function Get-FmBackendHerdrPaneIdleShellPid {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneId
    )
    if (Test-Path -LiteralPath (Join-Path (ToNative $env:FM_SC_FIXTURE) 'process-unsafe')) { return $null }
    return '67'
}
function Close-FmBackendHerdrProjectionPane {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$PaneId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$RequiredAgentState = ''
    )
    $fixture = ToNative $env:FM_SC_FIXTURE
    if (Test-Path -LiteralPath (Join-Path $fixture 'focus-refuse')) { return @{ Code = 1; AgentState = '' } }
    if ($RequiredAgentState -cne 'no-agent') { return @{ Code = 1; AgentState = '' } }
    [System.IO.File]::AppendAllText((Join-Path $fixture 'closes.log'),
        "$Session $PaneId $RequiredAgentState`n", $utf8)
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'close-unconfirmed'))) {
        [System.IO.File]::WriteAllText((Join-Path (ToNative $env:FM_HERDR_STATE) 'st'), "closed`r`n", $utf8)
    }
    return @{ Code = 0; AgentState = 'dead' }
}

$scHome = ToNative "$scRoot/home"
$scState = ToNative "$scRoot/home/state"
$scResp = ToNative "$scRoot/resp"
$scFake = ToNative "$scRoot/fkstate"
$scFixture = ToNative "$scRoot/fixture"
$scLog = ToNative "$scRoot/herdr.log"

foreach ($label in [System.IO.File]::ReadAllLines($caseFileC)) {
    if ([string]::IsNullOrWhiteSpace($label)) { continue }
    foreach ($dir in @($scState, $scResp, $scFake, $scFixture)) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    [System.IO.File]::WriteAllText($scLog, '', $utf8)
    [System.IO.File]::WriteAllText((Join-Path $scFixture 'closes.log'), '', $utf8)
    $template = Join-Path (ToNative $casesDir) $label
    foreach ($part in @(@('resp', $scResp), @('state', $scState), @('fixture', $scFixture))) {
        $src = Join-Path $template $part[0]
        if (Test-Path -LiteralPath $src) {
            Get-ChildItem -LiteralPath $src -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $part[1] -Force
            }
        }
    }
    # @HOME@ in a version 2 journal is this world's own home.
    Get-ChildItem -LiteralPath $scState -Filter '*.herdr-presentation' -File |
        ForEach-Object {
            $text = [System.IO.File]::ReadAllText($_.FullName)
            if ($text.Contains('@HOME@')) {
                [System.IO.File]::WriteAllText($_.FullName, $text.Replace('@HOME@', $scHome), $utf8)
            }
        }

    $oldOut = [Console]::Out
    $oldErr = [Console]::Error
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $rc = 0
    try {
        Invoke-FmHerdrSessionCleanup
    } catch {
        $rc = "EXCEPTION: $($_.Exception.Message)"
    } finally {
        [Console]::SetOut($oldOut)
        [Console]::SetError($oldErr)
    }
    Write-Result "sc-$label" $so.ToString() $se.ToString() $rc
    $journal = Join-Path $scState 'task.herdr-presentation'
    $present = if (Test-Path -LiteralPath $journal) { 'present' } else { 'absent' }
    [System.IO.File]::WriteAllText((Join-Path $outDir "sc-$label.ps.journal"), "$present`n", $utf8)
    Copy-Item -LiteralPath (Join-Path $scFixture 'closes.log') `
        -Destination (Join-Path $outDir "sc-$label.ps.closes") -Force
    Copy-Item -LiteralPath $scLog -Destination (Join-Path $outDir "sc-$label.ps.log") -Force
}
PSEOF

pwsh -NoProfile -File "$(fm_test_native_path "$TMP_ROOT/driver.ps1")" \
  "$(fm_test_native_path "$CASES_B")" \
  "$(fm_test_native_path "$CASES_C")" \
  "$(fm_test_native_path "$OUT")" \
  "$(fm_test_native_path "$_suite_root/bin")" \
  "$(fm_test_native_path "$SC/cases")" \
  "$(fm_test_native_path "$SC_PS")" \
  "$(fm_test_native_path "$_suite_root")" \
  || fail "the PowerShell driver exited non-zero"

# =============================================================================
# PHASE 4 - join by label and compare
# =============================================================================

progress 'phase 4: joining and comparing'

set_worlds() { B_SH=$1; B_PS=$2; }

test_lab_usage_surface() {
  local l
  for l in lab-help lab-h lab-help-word lab-bogus lab-noargs lab-name-noarg lab-run-short; do
    compare_case "$l"
  done
  # The usage text is the file's own header, printed back. Asserting on the
  # PowerShell output directly catches a shared regression a pure diff would not.
  local body
  read_file body "$OUT/lab-help.ps.out"
  case "$body" in
    *'Session names must begin with "fm-lab-" and can never be "default".'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "lab --help lost the name-safety line" ;;
  esac
  case "$body" in
    *'fm-herdr-lab.sh teardown <session>'*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "lab --help lost the teardown usage line" ;;
  esac
  set_worlds "$LAB_USAGE_SH" "$LAB_USAGE_PS"
  compare_logs 'lab usage'
  pass "fm-herdr-lab.ps1: help, unknown commands and argument-count refusals match the bash oracle"
}

# Normalization 1: the pid/random suffix cannot match, the sanitized LABEL must.
strip_suffix() { # <var> <name>
  local -n _dst=$1
  _dst=${2%-*}
  _dst=${_dst%-*}
}

test_lab_name_generation() {
  local l shname psname shlabel pslabel shrc psrc
  for l in name-plain name-punct name-allpunct name-underscores name-dashes name-cap name-short; do
    read_file shrc "$OUT/$l.sh.rc"; read_file psrc "$OUT/$l.ps.rc"
    assert_eq "$psrc" "$shrc" "$l: exit code differs"
    read_file shname "$OUT/$l.sh.out"
    read_file psname "$OUT/$l.ps.out"
    strip_suffix shlabel "$shname"
    strip_suffix pslabel "$psname"
    assert_eq "$pslabel" "$shlabel" "$l: the sanitized label differs"
    case "$psname" in
      fm-lab-?*-[0-9]*-[0-9]*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
      *) fail "$l: the generated name is not <lab prefix>-<pid>-<random>: $psname" ;;
    esac
    [ "${#psname}" -le 40 ] || fail "$l: generated name too long for a Herdr socket path: $psname"
    ASSERTIONS=$((ASSERTIONS + 1))
  done
  pass "fm-herdr-lab.ps1: the label sanitizer, 16-character cap and lab prefix match the bash oracle"
}

test_lab_name_refusals() {
  local l
  for l in refuse-default refuse-empty refuse-arbitrary refuse-badchars refuse-prefix-only; do
    compare_case "$l"
  done
  set_worlds "$REFUSE_SH" "$REFUSE_PS"
  compare_logs 'lab name refusals'
  # A refused name must never have reached Herdr at all.
  local log
  read_file log "$REFUSE_PS/herdr.log"
  assert_eq "$log" '' 'a refused lab name reached the Herdr CLI'
  pass "fm-herdr-lab.ps1: every unsafe session name is refused with the oracle's message, before any Herdr call"
}

test_lab_prepare() {
  compare_case prepare-ok
  compare_case prepare-twice
  set_worlds "$PREPARE_SH" "$PREPARE_PS"
  compare_logs 'lab prepare'
  compare_world_file "tripwires/$LAB_NAME.fleet-state.json" 'prepare: the recorded tripwire differs'
  local tw
  read_file tw "$PREPARE_PS/tripwires/$LAB_NAME.fleet-state.json"
  assert_eq "$tw" "$TRIPWIRE_JSON" 'prepare: the tripwire is not the jq -c snapshot spelling'

  compare_case prepare-adopt
  set_worlds "$PREPARE_EXISTS_SH" "$PREPARE_EXISTS_PS"
  compare_logs 'lab prepare adopt'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'prepare: an unowned existing session left a tripwire'

  compare_case prepare-nofleet
  set_worlds "$NOFLEET_SH" "$NOFLEET_PS"
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'prepare: a non-running default left a tripwire'
  compare_case prepare-twodefaults
  set_worlds "$TWODEF_SH" "$TWODEF_PS"
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'prepare: two default sessions left a tripwire'
  compare_case prepare-listfail
  set_worlds "$LISTFAIL_SH" "$LISTFAIL_PS"
  compare_logs 'lab prepare list failure'
  pass "fm-herdr-lab.ps1: ownership recording, adoption refusal and the fleet-state tripwire match the bash oracle"
}

test_lab_run_allowlist() {
  local l
  for l in run-ok run-server run-server-stop run-session-delete run-session-stop \
    run-session-list run-session-flag run-session-equals run-leading-option \
    run-leading-nosession run-leading-remote run-bad-name; do
    compare_case "$l"
  done
  set_worlds "$RUN_SH" "$RUN_PS"
  compare_logs 'lab run allowlist'
  # Only the two ALLOWED commands may appear, and each carries the trailing
  # lab session. This is asserted on the PowerShell log directly: a shared
  # regression that opened the allowlist in both twins would pass a pure diff.
  local line count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    count=$((count + 1))
    case "$line" in
      *" --session $LAB_NAME") : ;;
      *) fail "a Herdr call lacked the trailing lab session: $line" ;;
    esac
    case "$line" in
      "workspace list --session $LAB_NAME"|"session list --session $LAB_NAME") : ;;
      *) fail "the run allowlist admitted a forbidden command: $line" ;;
    esac
  done < "$RUN_PS/herdr.log"
  assert_eq "$count" '2' 'the run allowlist admitted the wrong number of Herdr calls'
  pass "fm-herdr-lab.ps1: run forbids leading options, caller sessions, server and session lifecycle exactly as the oracle does"
}

test_lab_provision() {
  compare_case provision-fresh
  set_worlds "$PROVISION_SH" "$PROVISION_PS"
  compare_logs 'lab provision'
  compare_world_file 'fkstate/st' 'provision: the lab session state differs'
  compare_world_file "tripwires/$LAB_NAME.fleet-state.json" 'provision: the recorded tripwire differs'

  compare_case provision-owned-stopped
  set_worlds "$REPROV_SH" "$REPROV_PS"
  compare_logs 'lab re-provision'
  compare_world_file 'fkstate/st' 're-provision: the lab session state differs'

  compare_case provision-not-stopped
  set_worlds "$PROVRUN_SH" "$PROVRUN_PS"
  compare_logs 'lab provision of a running lab'
  compare_case provision-unowned
  set_worlds "$PROVUNOWNED_SH" "$PROVUNOWNED_PS"
  compare_logs 'lab provision of an unowned session'
  pass "fm-herdr-lab.ps1: provisioning, adoption of an owned stopped lab, and both refusals match the bash oracle"
}

test_lab_stop_and_teardown() {
  compare_case stop-ok
  set_worlds "$STOP_SH" "$STOP_PS"
  compare_logs 'lab stop'
  compare_world_file 'fkstate/st' 'stop: the lab session state differs'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" 'stop: the ownership tripwire differs'

  compare_case stop-no-tripwire
  set_worlds "$STOPNT_SH" "$STOPNT_PS"
  compare_logs 'lab stop without ownership'
  local log
  read_file log "$STOPNT_PS/herdr.log"
  assert_eq "$log" '' 'a stop without a tripwire reached the Herdr CLI'

  compare_case teardown-ok
  set_worlds "$TEARDOWN_SH" "$TEARDOWN_PS"
  compare_logs 'lab teardown'
  compare_world_file 'fkstate/st' 'teardown: the lab session state differs'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" 'teardown: the tripwire was not retired'
  # The safety sequence itself: stop and delete must EACH be immediately
  # preceded by a fresh session list (the refuse-default check).
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    lines+=("$line")
  done < "$TEARDOWN_PS/herdr.log"
  local i seen_stop=0 seen_delete=0
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in
      "session stop $LAB_NAME --json --session $LAB_NAME")
        seen_stop=1
        [ "$i" -gt 0 ] || fail 'stop was the first Herdr call, with no refuse-default check before it'
        assert_eq "${lines[$((i - 1))]}" "session list --json --session $LAB_NAME" \
          'stop was not immediately preceded by a fresh refuse-default session list'
        ;;
      "session delete $LAB_NAME --json --session $LAB_NAME")
        seen_delete=1
        [ "$i" -gt 0 ] || fail 'delete was the first Herdr call, with no refuse-default check before it'
        assert_eq "${lines[$((i - 1))]}" "session list --json --session $LAB_NAME" \
          'delete was not immediately preceded by a fresh refuse-default session list'
        ;;
    esac
  done
  assert_eq "$seen_stop$seen_delete" '11' 'teardown did not issue both the guarded stop and delete'

  compare_case teardown-no-tripwire
  set_worlds "$TDNT_SH" "$TDNT_PS"
  read_file log "$TDNT_PS/herdr.log"
  assert_eq "$log" '' 'a teardown without a tripwire reached the Herdr CLI'
  compare_logs 'lab teardown without ownership'

  compare_case teardown-absent
  set_worlds "$TDABS_SH" "$TDABS_PS"
  compare_logs 'lab teardown of an absent session'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'teardown of an absent session did not retire the tripwire'

  compare_case teardown-stale-tripwire
  set_worlds "$TDSTALE_SH" "$TDSTALE_PS"
  compare_logs 'lab teardown with a changed fleet'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'a failed tripwire check did not retain its evidence'

  compare_case teardown-delete-failed
  set_worlds "$TDFAIL_SH" "$TDFAIL_PS"
  compare_logs 'lab teardown with a failed delete'
  compare_world_presence "tripwires/$LAB_NAME.fleet-state.json" \
    'a failed delete released ownership'

  compare_case teardown-becomes-default
  set_worlds "$TDDEF_SH" "$TDDEF_PS"
  compare_logs 'lab teardown of a session that became default'
  read_file log "$TDDEF_PS/herdr.log"
  case "$log" in
    *"session delete"*) fail 'a session that became default between stop and delete was still deleted' ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac
  pass "fm-herdr-lab.ps1: guarded stop, teardown, the fleet tripwire and the fresh refuse-default checks match the bash oracle"
}

test_ci_cleanup() {
  local l
  for l in ci-noargs ci-oneargs ci-unknown; do compare_case "$l"; done
  set_worlds "$CI_SHAPE_SH" "$CI_SHAPE_PS"
  compare_logs 'ci argument shape'

  compare_case ci-no-herdr
  compare_case ci-snapshot
  set_worlds "$CI_SNAP_SH" "$CI_SNAP_PS"
  compare_logs 'ci snapshot'
  compare_world_file snap.json 'ci snapshot: the written snapshot differs'
  local snap
  read_file snap "$CI_SNAP_PS/snap.json"
  assert_eq "$snap" '["default","fm-lab-known","fm-lab-owned","scratch"]' \
    'ci snapshot: not the sorted unique jq -c spelling'

  compare_case ci-snapshot-empty
  set_worlds "$CI_SNAPEMPTY_SH" "$CI_SNAPEMPTY_PS"
  compare_world_file snap.json 'ci snapshot: an empty fleet differs'

  compare_case ci-teardown-missing
  compare_case ci-teardown-none
  set_worlds "$CI_TDNONE_SH" "$CI_TDNONE_PS"
  compare_logs 'ci teardown with nothing owned'

  compare_case ci-teardown-clean
  set_worlds "$CI_TDCLEAN_SH" "$CI_TDCLEAN_PS"
  compare_logs 'ci teardown of a job-owned session'
  compare_world_file 'fkstate/st' 'ci teardown: the session state differs'

  compare_case ci-teardown-becomes-default
  set_worlds "$CI_TDDEF_SH" "$CI_TDDEF_PS"
  compare_logs 'ci teardown of a session that became default'
  local log
  read_file log "$CI_TDDEF_PS/herdr.log"
  case "$log" in
    *"session stop"*|*"session delete"*)
      fail 'a session reported default was still stopped or deleted' ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac

  compare_case ci-teardown-default-after-stop
  set_worlds "$CI_TDAFTER_SH" "$CI_TDAFTER_PS"
  compare_logs 'ci teardown of a session that became default after the stop'
  read_file log "$CI_TDAFTER_PS/herdr.log"
  case "$log" in
    *"session delete"*) fail 'a session that became default after the stop was still deleted' ;;
    *) ASSERTIONS=$((ASSERTIONS + 1)) ;;
  esac

  compare_case ci-teardown-delete-failed
  set_worlds "$CI_TDDELFAIL_SH" "$CI_TDDELFAIL_PS"
  compare_logs 'ci teardown with a failed delete'
  compare_case ci-teardown-already-absent
  set_worlds "$CI_TDABSENT_SH" "$CI_TDABSENT_PS"
  compare_logs 'ci teardown of a session that vanished after the stop'
  pass "fm-herdr-ci-cleanup.ps1: snapshot spelling, ownership selection and every refuse-default path match the bash oracle"
}

test_session_cleanup() {
  local label sherr pserr shj psj shc psc shl psl
  for label in "${SC_LABELS[@]}"; do
    [ -f "$OUT/sc-$label.ps.rc" ] || fail "sc-$label: the PowerShell driver produced no result"
    read_file sherr "$OUT/sc-$label.sh.err"; read_file pserr "$OUT/sc-$label.ps.err"
    assert_eq "$pserr" "$sherr" "sc-$label: the warnings differ"
    read_file shj "$OUT/sc-$label.sh.journal"; read_file psj "$OUT/sc-$label.ps.journal"
    assert_eq "$psj" "$shj" "sc-$label: the journal outcome differs"
    read_file shc "$OUT/sc-$label.sh.closes"; read_file psc "$OUT/sc-$label.ps.closes"
    assert_eq "$psc" "$shc" "sc-$label: the pane closures differ"
    normalize_log shl "$OUT/sc-$label.sh.log"; normalize_log psl "$OUT/sc-$label.ps.log"
    assert_eq "$psl" "$shl" "sc-$label: the two worlds issued different Herdr commands"
  done
  pass "fm-herdr-session-cleanup.ps1: ${#SC_LABELS[@]} scenarios agree with the bash oracle on warnings, closures, journals and Herdr calls"
}

# The safety contract asserted on the PowerShell side directly, so a shared
# regression in BOTH twins is still caught.
test_session_cleanup_safety_contract() {
  local closes journal
  read_file closes "$OUT/sc-positive-v1.ps.closes"
  assert_eq "$closes" "fmdiff $SC_PANE no-agent" \
    'the positive case did not close exactly one pane with the no-agent requirement'
  read_file journal "$OUT/sc-positive-v1.ps.journal"
  assert_eq "$journal" absent 'the positive case did not retire its journal'

  local label
  for label in sc-agent-live sc-agent-unknown sc-process-unsafe sc-multiple-tabs \
    sc-multiple-panes sc-active-target sc-duplicate-token sc-snapshot-error \
    sc-workspace-get-error sc-revalidation-race sc-cross-home sc-v2-workspace-mismatch \
    sc-v2-tab-mismatch sc-v2-pane-mismatch sc-task-meta sc-two-journals; do
    read_file closes "$OUT/$label.ps.closes"
    assert_eq "$closes" '' "$label: a pane was closed on a refusal path"
    read_file journal "$OUT/$label.ps.journal"
    assert_eq "$journal" present "$label: a journal was retired on a refusal path"
  done
  pass "fm-herdr-session-cleanup.ps1: every refusal path preserves both the pane and the journal"
}

test_assertion_floor() {
  [ "$ASSERTIONS" -ge "$MIN_ASSERTIONS" ] \
    || fail "only $ASSERTIONS assertions ran; expected at least $MIN_ASSERTIONS (cases stopped being exercised)"
  pass "fm-herdr-ops differential: $ASSERTIONS assertions compared against the bash oracle"
}

test_lab_usage_surface
test_lab_name_generation
test_lab_name_refusals
test_lab_prepare
test_lab_run_allowlist
test_lab_provision
test_lab_stop_and_teardown
test_ci_cleanup
test_session_cleanup
test_session_cleanup_safety_contract
test_assertion_floor
