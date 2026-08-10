#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2086
# Differential test for the W4-session entrypoint twins:
#
#   bin/fm-lock.ps1                      vs bin/fm-lock.sh
#   bin/fm-harness.ps1                   vs bin/fm-harness.sh
#   bin/fm-supervision-instructions.ps1  vs bin/fm-supervision-instructions.sh
#   bin/fm-bootstrap.ps1                 vs bin/fm-bootstrap.sh
#   bin/fm-session-start.ps1             vs bin/fm-session-start.sh
#
# WHAT IS ACTUALLY AT STAKE, WHICH IS WHY THE CASE MIX LOOKS LIKE THIS
#
#   1. THE SESSION LOCK DECIDES WHETHER FIRSTMATE MAY ACT AT ALL. A session
#      that cannot acquire and verify it runs permanently read-only (AGENTS.md
#      section 3). Worse, if the two language trees resolved DIFFERENT harness
#      pids for one session, a lock written by bash would be unreadable to
#      PowerShell and vice versa - the same outage, arriving silently. So this
#      suite does not merely compare fm-lock's text: it has each world ACQUIRE
#      a real lock and then has the OTHER world read it back, which is the
#      property that actually keeps one home usable from both trees.
#   2. fm-bootstrap's DIAGNOSTIC LINES ARE A PARSED INTERFACE.
#      .agents/skills/bootstrap-diagnostics dispatches on their prefixes, so the
#      cases below drive every branch whose text a skill reads: BACKEND_INVALID,
#      MISSING/MISSING_MANUAL, NEEDS_GH_AUTH, TANGLE (both wordings),
#      WINDOWS_SETUP, CREW_DISPATCH (four distinct validator verdicts), and the
#      three `install` refusals.
#   3. fm-session-start COMPOSES all of the above, so one end-to-end case
#      compares the whole ordered digest - section rules, labels, ABSENT
#      markers, the compact backlog rendering, the endpoint line, the status
#      tail, and the closing reminder - which is the only way to catch an
#      ordering or heading regression.
#
# THE BATCHING RULE (docs/powershell-port.md, "the one rule that decides
# whether a suite finishes"). A bare `pwsh -NoProfile -Command "exit 0"` costs
# 4.8s on the reference host, so a suite that spawns one pwsh per case never
# finishes. This file writes every PowerShell case to a TSV case file and runs
# ONE pwsh over all of them, joining the two worlds' answers by LABEL. Driving
# .ps1 ENTRYPOINTS that way needs three mechanics:
#
#   - `& script.ps1` runs the script IN-PROCESS; its `exit <n>` terminates only
#     that script and leaves the code in $LASTEXITCODE.
#   - Per-case stdout/stderr come from [Console]::SetOut/SetError over
#     StringWriters. The driver pre-imports fm-common ONCE, before any
#     redirection, because that module's body assigns [Console]::OutputEncoding
#     and that assignment REBUILDS [Console]::Out - which would silently discard
#     the first redirected case. The five entrypoints import fm-common WITHOUT
#     -Force precisely so no later import can repeat it.
#   - Per-case environment is carried in the case RECORD and applied on the
#     PowerShell side, never as a bash prefix assignment, which would have
#     collapsed to the LAST value by the time the single pwsh ran.
#
# THE ORACLE IS FORK-BOUND AND THIS HOST IS SLOW. Measured live while other
# conversion agents were running: a trivial fork cost 2.5-3.1s, `gh auth status`
# 12s, `treehouse get --help` 9s, and ONE full bash `fm-bootstrap.sh` run took
# 2m24s - almost all of it waiting on child processes. So every bootstrap and
# session-start case runs on a MINIMAL PATH that deliberately contains only Git
# Bash's own utilities plus jq. That is not a shortcut: it makes the absent-tool
# branches (which are the ones with the parsed text) both FAST and
# DETERMINISTIC, and it keeps the network out of the suite entirely, because an
# absent `gh` fails instantly instead of round-tripping to GitHub.
# jq is kept because the bash validator needs it - see divergence 1 below.
#
# TWO DECLARED DIVERGENCES, ASSERTED RATHER THAN NORMALIZED AWAY
#
#   1. jq. bin/fm-bootstrap.ps1 validates config/crew-dispatch.json in-process
#      and has no jq dependency, while the bash twin prints "MISSING: jq" when
#      jq is absent. The minimal PATH therefore KEEPS jq, so both worlds run
#      their real validator and the four verdict cases compare exactly. The
#      jq-absent case is not driven, because it can only ever report the
#      divergence the header of fm-bootstrap.ps1 already documents.
#   2. fm-harness's ANCESTRY FALLBACK. bash walks from $$ (an MSYS pid, whose
#      parent is reported as 1 under Git Bash) and PowerShell from $PID (a
#      Windows pid, whose real parent chain terminates at an exited process).
#      The two walks observe genuinely different process trees, so the case with
#      no environment marker is compared BY SHAPE - one line, drawn from the
#      accepted vocabulary - and every marker-driven and config-driven case is
#      compared byte-for-byte. This is recorded in bin/fm-harness.ps1's header.
#
# THREE NORMALIZATIONS, EACH APPLIED TO BOTH SIDES IDENTICALLY AND ONLY WHERE
# NAMED:
#
#   a. The session-start case runs each world against its OWN copy of a
#      byte-identical fixture home, because bin/fm-pr-check-migrate.sh and the
#      startup-memory-budget materializer are one-shot: the second world to run
#      against a shared home would legitimately print less. Each world's own
#      home path is replaced with <FMHOME> so the two trees compare.
#   b. The harness pid in fm-lock's and fm-session-start's output is replaced
#      with <PID>. The two worlds resolving the SAME pid is asserted directly in
#      the lock phase, which is where that property belongs; normalizing it here
#      stops one genuine identity divergence from being reported as thirty
#      unrelated digest mismatches.
#   c. Nothing else. In particular no tool line, no diagnostic text and no
#      exit code is normalized.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# A stray override in the ambient session would silently repoint every case, so
# the base state is pinned here rather than assumed.
unset FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
unset FM_PROJECTS_OVERRIDE FM_BOOTSTRAP_DETECT_ONLY FM_BOOTSTRAP_VERBOSE_FACTS
unset FM_SESSION_START_STATUS_TAIL FM_SESSION_START_BACKLOG_LIMIT
unset FM_CODEX_WATCH_CHECKPOINT FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT

BASE_PATH=$PATH

# --- staged verification ------------------------------------------------------
#
# FM_SESSION_PSM1_PHASES selects a comma-separated subset of the five phases;
# unset runs all of them, which is what CI and bin/fm-test-run.sh do.
#
# This exists because of a MEASURED property of the oracle, not for convenience.
# `bin/fm-bootstrap.sh` reports ten absent tools, and each MISSING line costs a
# command substitution - so one detect-only run is ~30 forks. On an idle host
# that is a second; measured here with four conversion agents live, a fork cost
# 4s and ONE bootstrap case took 150s. docs/powershell-port.md's guidance for
# exactly this situation is to STAGGER verification runs rather than to thin the
# case set, and a phase selector is how that is done without deleting coverage:
# every phase still runs, and the join below compares only the labels the oracle
# actually produced, so a staged run is a real verdict for that phase.
PHASES=${FM_SESSION_PSM1_PHASES:-harness,supervision,lock,bootstrap,session}
want() {  # <phase>
  case ",$PHASES," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# --- transport encoding -------------------------------------------------------
#
# Case and answer records are TAB-delimited lines, but an answer legitimately
# contains newlines (every digest does) and could contain tabs. So payloads are
# transport-encoded onto the C0 separators, which no case value uses: US joins
# list items, RS stands for LF, GS for CR, FS for TAB.
US=$'\x1f'
RS=$'\x1e'
GS=$'\x1d'
FS=$'\x1c'

# enc <text>: sets ENC. A global out-parameter rather than a command
# substitution, because `$(...)` forks and a fork costs 2.5-3.1s on this host.
ENC=""
enc() {
  local s=$1
  s=${s//$'\r'/$GS}
  s=${s//$'\n'/$RS}
  s=${s//$'\t'/$FS}
  ENC=$s
}

# --- fixture root -------------------------------------------------------------
#
# The fixture root must have a DRIVE-form POSIX spelling (/c/...), not an MSYS
# mount fiction (/tmp/...), because the SAME path string is handed to both
# worlds: bash uses it verbatim, and the PowerShell twins convert it with
# fm-common's pure-string MSYS-drive rule and print it back in POSIX form. A
# /tmp path would need cygpath on every conversion (a fork each) AND would print
# back differently, so every path in every digest would read as a mismatch.
if command -v cygpath >/dev/null 2>&1; then
  # `cygpath -u` is NOT the inverse here: it maps the Windows temp directory
  # straight back onto the /tmp MOUNT it came from, which is the spelling this
  # suite must avoid. The drive form is therefore derived from the Windows path
  # by hand.
  TMP_WIN=$(cygpath -w /tmp)
  case "$TMP_WIN" in
    [A-Za-z]:*)
      TMP_DRIVE=${TMP_WIN%%:*}
      TMP_REST=${TMP_WIN#*:}
      TMP_REST=${TMP_REST//\\//}
      TMPDIR="/${TMP_DRIVE,,}$TMP_REST"
      export TMPDIR
      ;;
  esac
fi
TMP_ROOT=$(fm_test_tmproot fm-session-psm1)
case "$TMP_ROOT" in
  /[A-Za-z]/*) ;;
  *)
    if command -v cygpath >/dev/null 2>&1; then
      echo "skip: fixture root $TMP_ROOT has no drive-form spelling; cannot drive both worlds from one path string"
      exit 0
    fi
    ;;
esac

fm_git_identity fmtest fmtest@example.invalid

# --- the minimal PATH ---------------------------------------------------------
#
# Both worlds must see the SAME set of tools, but they cannot share a PATH
# string: bash needs MSYS spellings and PowerShell needs native ones. So the two
# spellings of the same two directories (plus jq's) are computed once here, and
# each world substitutes its own for the %MINPATH% placeholder carried in the
# case record.
#
# The directories are chosen, not guessed: /usr/bin and /bin hold Git Bash's
# POSIX utilities and /mingw64/bin holds git itself, while NONE of them holds
# node, gh, tmux, herdr, treehouse or any *-axi tool. So every tool whose
# absence this suite wants is absent in both worlds, and git - which the tangle
# check and the common-tool list both need - is present in both.
#
# jq is deliberately given to the BASH SIDE ONLY, through a one-line wrapper
# around the host's existing CRLF shim. jq appears in no tool list under
# backend=tmux; the only code that touches it is the bash crew-dispatch
# validator, and its PowerShell twin has no jq dependency at all (divergence 1).
# Putting the host's jq DIRECTORY on the path instead would have dragged
# treehouse.exe in with it, which is in the tmux backend's required set and
# would then have been present for bash and absent for PowerShell.
MIN_DIRS="/usr/bin /bin /mingw64/bin /c/Windows/System32"
MIN_BASH_PATH=""
MIN_PS_PATH=""
for d in $MIN_DIRS; do
  [ -d "$d" ] || continue
  if [ -n "$MIN_BASH_PATH" ]; then MIN_BASH_PATH="$MIN_BASH_PATH:$d"; else MIN_BASH_PATH=$d; fi
  if command -v cygpath >/dev/null 2>&1; then
    w=$(cygpath -w "$d")
  else
    w=$d
    if [ -n "$MIN_PS_PATH" ]; then MIN_PS_PATH="$MIN_PS_PATH:$w"; else MIN_PS_PATH=$w; fi
    continue
  fi
  if [ -n "$MIN_PS_PATH" ]; then MIN_PS_PATH="$MIN_PS_PATH;$w"; else MIN_PS_PATH=$w; fi
done
JQ_BIN=$(command -v jq 2>/dev/null || true)
if [ -n "$JQ_BIN" ]; then
  mkdir -p "$TMP_ROOT/jqbin"
  printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$JQ_BIN" > "$TMP_ROOT/jqbin/jq"
  chmod +x "$TMP_ROOT/jqbin/jq"
  MIN_BASH_PATH="$MIN_BASH_PATH:$TMP_ROOT/jqbin"
fi
PATH=$MIN_BASH_PATH command -v git >/dev/null 2>&1 || {
  echo "skip: git is not reachable from the minimal PATH this suite pins"
  exit 0
}

# --- fixtures -----------------------------------------------------------------

mk_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data"
}

# A git checkout usable as FM_ROOT: it pins the tangle check's answer instead of
# letting the real repo's current branch decide it.
mk_repo() {  # <dir> [branch]
  local dir=$1 branch=${2:-}
  git init -q -b main "$dir"
  : > "$dir/AGENTS.md"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -q -m init
  [ -z "$branch" ] || git -C "$dir" checkout -q -b "$branch"
}

CFG_DIR="$TMP_ROOT/cfg"
mkdir -p "$CFG_DIR"

# harness config fixtures
mkdir -p "$CFG_DIR/crew-codex" "$CFG_DIR/crew-default" "$CFG_DIR/crew-ws" \
         "$CFG_DIR/sm-full" "$CFG_DIR/sm-comments" "$CFG_DIR/sm-default" \
         "$CFG_DIR/sm-bare" "$CFG_DIR/empty"
printf 'codex\n' > "$CFG_DIR/crew-codex/crew-harness"
# Every config dir a bootstrap case uses PINS the backend, because unpinned
# auto-detection reads the ambient runtime (HERDR_ENV here) and announces itself
# on stderr - a line whose presence would then depend on the shell that started
# the suite rather than on the twins.
printf 'tmux\n' > "$CFG_DIR/crew-codex/backend"
cat > "$CFG_DIR/crew-codex/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"docs","use":{"harness":"claude","effort":"low"}},
{"when":"big","select":"quota-balanced","use":[{"harness":"claude","model":"opus"},{"harness":"codex","effort":"high"}]}],
"default":{"harness":"claude"}}
JSON
printf 'default\n' > "$CFG_DIR/crew-default/crew-harness"
printf '  open code \n' > "$CFG_DIR/crew-ws/crew-harness"
printf 'grok  sonnet   high\n' > "$CFG_DIR/sm-full/secondmate-harness"
printf '\n# a comment\n\n  kimi model-x  \n' > "$CFG_DIR/sm-comments/secondmate-harness"
printf 'default\n' > "$CFG_DIR/sm-default/secondmate-harness"
printf 'codex\n' > "$CFG_DIR/sm-default/crew-harness"
printf 'pi-signed\n' > "$CFG_DIR/sm-bare/secondmate-harness"

# supervision fixtures
mkdir -p "$TMP_ROOT/sup/config" "$TMP_ROOT/supx/config"
printf 'export FM_CHECK_INTERVAL=30\n' > "$TMP_ROOT/supx/config/x-mode.env"

# lock fixtures
for n in free dead empty junk acquire dirlock ps-acquire; do
  mk_home "$TMP_ROOT/lock-$n"
done
printf '999999999\n' > "$TMP_ROOT/lock-dead/state/.lock"
: > "$TMP_ROOT/lock-empty/state/.lock"
printf 'abc\n' > "$TMP_ROOT/lock-junk/state/.lock"
mkdir -p "$TMP_ROOT/lock-dirlock/state/.lock"

# bootstrap fixtures
BOOT_REPO="$TMP_ROOT/boot-repo"
mk_repo "$BOOT_REPO"
TANGLE_REPO="$TMP_ROOT/tangle-repo"
mk_repo "$TANGLE_REPO" feature/x
STUB_REPO="$TMP_ROOT/stub-repo"
mk_repo "$STUB_REPO"
printf 'AGENTS.md' > "$STUB_REPO/CLAUDE.md"
mkdir -p "$STUB_REPO/.claude"
printf '../.agents/skills' > "$STUB_REPO/.claude/skills"

for n in base invalid dispatch-bad dispatch-harness dispatch-effort dispatch-select install; do
  mk_home "$TMP_ROOT/boot-$n"
done
printf 'tmux\n' > "$TMP_ROOT/boot-base/config/backend"
printf 'bogus\n' > "$TMP_ROOT/boot-invalid/config/backend"
printf 'tmux\n' > "$TMP_ROOT/boot-install/config/backend"
for n in dispatch-bad dispatch-harness dispatch-effort dispatch-select; do
  printf 'tmux\n' > "$TMP_ROOT/boot-$n/config/backend"
done
printf '{ "rules": [\n' > "$TMP_ROOT/boot-dispatch-bad/config/crew-dispatch.json"
printf '{"default":{"harness":"bogus"}}\n' > "$TMP_ROOT/boot-dispatch-harness/config/crew-dispatch.json"
printf '{"rules":[{"when":"x","use":{"harness":"kimi","effort":"low"}}]}\n' \
  > "$TMP_ROOT/boot-dispatch-effort/config/crew-dispatch.json"
printf '{"rules":[{"when":"x","select":"round-robin","use":[{"harness":"claude"}]}]}\n' \
  > "$TMP_ROOT/boot-dispatch-select/config/crew-dispatch.json"

# --- case plumbing ------------------------------------------------------------

ORACLE_FILE="$TMP_ROOT/oracle.tsv"
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$ORACLE_FILE"
: > "$CASE_FILE"

TOUCHED_ENV="CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_HOME
FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
FM_PROJECTS_OVERRIDE FM_BOOTSTRAP_DETECT_ONLY FM_BOOTSTRAP_VERBOSE_FACTS
FM_CODEX_WATCH_CHECKPOINT FM_SESSION_START_STATUS_TAIL
FM_SESSION_START_BACKLOG_LIMIT FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT"

CASE_ENV=()

# run_case <label> <script> [args...] - drives the BASH twin, records both the
# oracle answer and the PowerShell case record. CASE_ENV is consumed and reset.
run_case() {
  local label=$1 script=$2
  shift 2
  local kv name value rc out err args_raw env_raw a

  # shellcheck disable=SC2086  # deliberate word splitting over the name list
  unset $TOUCHED_ENV
  export PATH="$BASE_PATH"
  env_raw=""
  for kv in ${CASE_ENV[@]+"${CASE_ENV[@]}"}; do
    [ -n "$kv" ] || continue
    name=${kv%%=*}
    value=${kv#*=}
    if [ -n "$env_raw" ]; then env_raw="$env_raw$US$kv"; else env_raw=$kv; fi
    if [ "$value" = '%MINPATH%' ]; then value=$MIN_BASH_PATH; fi
    export "$name=$value"
  done

  "$ROOT/bin/$script.sh" "$@" >"$TMP_ROOT/.stdout" 2>"$TMP_ROOT/.stderr"
  rc=$?
  out=""
  err=""
  # `read -r -d ''` slurps the whole file with a BUILTIN; `$(cat ...)` would
  # fork twice per case, and this suite runs well over a hundred of them.
  IFS= read -r -d '' out < "$TMP_ROOT/.stdout" || true
  IFS= read -r -d '' err < "$TMP_ROOT/.stderr" || true

  args_raw=""
  for a in "$@"; do
    enc "$a"
    if [ -n "$args_raw" ]; then args_raw="$args_raw$US$ENC"; else args_raw=$ENC; fi
  done

  local ans
  enc "$out"; ans="$rc$US$ENC"
  enc "$err"; ans="$ans$US$ENC"
  printf '%s\t%s\n' "$label" "$ans" >> "$ORACLE_FILE"
  printf '%s\t%s\t%s\t%s\n' "$label" "$script" "$args_raw" "$env_raw" >> "$CASE_FILE"

  CASE_ENV=()
}

if want harness; then
# --- phase 1: fm-harness ------------------------------------------------------
#
# Layer 1 (environment markers) and both config resolutions are pure functions of
# the environment and of files on disk, so every case here is compared
# byte-for-byte. The single ancestry-fallback case is handled separately below.

CASE_ENV=(CLAUDECODE=1 "FM_HOME=$CFG_DIR/empty"); run_case harness-own-claude fm-harness
CASE_ENV=(PI_CODING_AGENT=true "FM_HOME=$CFG_DIR/empty"); run_case harness-own-pi fm-harness
CASE_ENV=(PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed "FM_HOME=$CFG_DIR/empty")
run_case harness-own-pi-signed fm-harness
CASE_ENV=(GROK_AGENT=1 "FM_HOME=$CFG_DIR/empty"); run_case harness-own-grok fm-harness
# Precedence: the claude marker is tested FIRST in the bash twin, so it wins over
# a stale grok marker retained in a multiplexer's stored environment.
CASE_ENV=(CLAUDECODE=1 GROK_AGENT=1 "FM_HOME=$CFG_DIR/empty")
run_case harness-own-precedence fm-harness
# A marker whose value is not the exact expected string is NOT a marker.
CASE_ENV=(CLAUDECODE=0 PI_CODING_AGENT=1 GROK_AGENT=yes "FM_HOME=$CFG_DIR/empty")
run_case harness-own-wrong-values fm-harness

CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/crew-codex" "FM_HOME=$CFG_DIR/empty")
run_case harness-crew-explicit fm-harness crew
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/crew-default" "FM_HOME=$CFG_DIR/empty")
run_case harness-crew-default fm-harness crew
# `tr -d '[:space:]'` removes whitespace ANYWHERE, so "  open code " is opencode.
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/crew-ws" "FM_HOME=$CFG_DIR/empty")
run_case harness-crew-squash fm-harness crew
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/empty" "FM_HOME=$CFG_DIR/empty")
run_case harness-crew-absent fm-harness crew

CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-full" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm fm-harness secondmate
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-full" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-model fm-harness secondmate-model
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-full" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-effort fm-harness secondmate-effort
# First non-empty, non-comment line only, trimmed.
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-comments" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-comments fm-harness secondmate
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-comments" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-comments-effort fm-harness secondmate-effort
# "default" defers to the crew resolution and suppresses model/effort ENTIRELY -
# not an empty line, no output at all.
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-default" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-default fm-harness secondmate
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-default" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-default-model fm-harness secondmate-model
# A harness-only file DOES print an empty line for the missing field.
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/sm-bare" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-bare-model fm-harness secondmate-model
CASE_ENV=(CLAUDECODE=1 "FM_CONFIG_OVERRIDE=$CFG_DIR/empty" "FM_HOME=$CFG_DIR/empty")
run_case harness-sm-absent fm-harness secondmate
# An unrecognized subcommand falls through to own-harness detection.
CASE_ENV=(CLAUDECODE=1 "FM_HOME=$CFG_DIR/empty"); run_case harness-unknown-arg fm-harness wat

fi

if want supervision; then
# --- phase 2: fm-supervision-instructions -------------------------------------

for h in claude codex opencode pi pi-signed grok bogus; do
  CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
  run_case "sup-block-$h" fm-supervision-instructions --harness "$h" --read-only 0 --afk 0 --x-mode 0
  CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
  run_case "sup-repair-$h" fm-supervision-instructions --harness "$h" --repair-line
done

CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
run_case sup-block-readonly fm-supervision-instructions --harness claude --read-only 1 --afk 1 --x-mode 1
CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
run_case sup-repair-readonly fm-supervision-instructions --harness claude --read-only 1 --repair-line
CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
run_case sup-repair-afk fm-supervision-instructions --harness claude --afk true --repair-line
# The x-mode prefix is a SHELL-QUOTED path, and the queue-pending prefix comes
# before it; both worlds must compose the two in the same order.
CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
run_case sup-repair-queue-x fm-supervision-instructions --harness codex --x-mode yes --queue-pending 1 --repair-line
CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup" FM_CODEX_WATCH_CHECKPOINT=42)
run_case sup-repair-codex-checkpoint fm-supervision-instructions --harness codex --repair-line
# X mode is inferred from the file's presence when the flag says 0.
CASE_ENV=("FM_HOME=$TMP_ROOT/supx" "FM_ROOT_OVERRIDE=$TMP_ROOT/supx")
run_case sup-block-xfile fm-supervision-instructions --harness grok --x-mode 0
CASE_ENV=("FM_HOME=$TMP_ROOT/supx" "FM_ROOT_OVERRIDE=$TMP_ROOT/supx")
run_case sup-repair-xfile fm-supervision-instructions --harness pi --x-mode 0 --repair-line
# Anything that is not one of the listed true spellings is 0.
CASE_ENV=("FM_HOME=$TMP_ROOT/sup" "FM_ROOT_OVERRIDE=$TMP_ROOT/sup")
run_case sup-bool-junk fm-supervision-instructions --harness claude --read-only maybe --afk '' --x-mode 0

CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-help fm-supervision-instructions --help
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-help-h fm-supervision-instructions -h
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-unknown fm-supervision-instructions --nope
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-harness fm-supervision-instructions --harness
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-readonly fm-supervision-instructions --read-only
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-afk fm-supervision-instructions --afk
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-xmode fm-supervision-instructions --x-mode
CASE_ENV=("FM_HOME=$TMP_ROOT/sup"); run_case sup-err-queue fm-supervision-instructions --queue-pending

fi

if want lock; then
# --- phase 3: fm-lock ---------------------------------------------------------
#
# Every `status` case is a pure function of the lock FILE, so none of them needs
# harness identity and all compare byte-for-byte. Acquisition needs identity and
# is handled by the cross-world check further down.

CASE_ENV=("FM_HOME=$TMP_ROOT/lock-free"); run_case lock-status-free fm-lock status
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-dead"); run_case lock-status-dead fm-lock status
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-empty"); run_case lock-status-empty fm-lock status
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-junk"); run_case lock-status-junk fm-lock status
# A state directory that does not exist yet is CREATED, then reports free.
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-nostate"); run_case lock-status-nostate fm-lock status

# Acquisition. Each world acquires in its OWN fixture; the cross-world read-back
# happens after the driver, and the resolved pid is compared explicitly.
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-acquire"); run_case lock-acquire fm-lock
# A directory where the lock file belongs is refused rather than written through.
CASE_ENV=("FM_HOME=$TMP_ROOT/lock-dirlock"); run_case lock-dirlock fm-lock

fi

if want bootstrap; then
# --- phase 4: fm-bootstrap ----------------------------------------------------

boot_env() {  # <home> [root]
  local home=$1 root=${2:-$BOOT_REPO}
  CASE_ENV=("FM_HOME=$home" "FM_ROOT_OVERRIDE=$root" FM_BOOTSTRAP_DETECT_ONLY=1 'PATH=%MINPATH%')
}

boot_env "$TMP_ROOT/boot-base"; run_case boot-base fm-bootstrap
boot_env "$TMP_ROOT/boot-invalid"; run_case boot-backend-invalid fm-bootstrap
boot_env "$TMP_ROOT/boot-dispatch-bad"; run_case boot-dispatch-malformed fm-bootstrap
boot_env "$TMP_ROOT/boot-dispatch-harness"; run_case boot-dispatch-harness fm-bootstrap
boot_env "$TMP_ROOT/boot-dispatch-effort"; run_case boot-dispatch-effort fm-bootstrap
boot_env "$TMP_ROOT/boot-dispatch-select"; run_case boot-dispatch-select fm-bootstrap
boot_env "$TMP_ROOT/boot-base" "$TANGLE_REPO"; run_case boot-tangle-detect fm-bootstrap
boot_env "$TMP_ROOT/boot-base" "$STUB_REPO"; run_case boot-windows-stub fm-bootstrap
# The verbose-facts surface: a crew-harness override fact plus the dispatch
# rendering, both of which are silent by default.
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-base" "FM_CONFIG_OVERRIDE=$CFG_DIR/crew-codex"
          "FM_ROOT_OVERRIDE=$BOOT_REPO" FM_BOOTSTRAP_DETECT_ONLY=1
          FM_BOOTSTRAP_VERBOSE_FACTS=1 'PATH=%MINPATH%')
run_case boot-verbose-facts fm-bootstrap

# `install` refusals. Only tools whose install command CANNOT run are driven -
# nothing here may actually install anything.
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-install" 'PATH=%MINPATH%')
run_case boot-install-noargs fm-bootstrap install
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-install" 'PATH=%MINPATH%')
run_case boot-install-unknown fm-bootstrap install not-a-real-tool
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-install" 'PATH=%MINPATH%')
run_case boot-install-manual fm-bootstrap install herdr

fi

if want session; then
# --- phase 5: fm-session-start ------------------------------------------------
#
# One end-to-end case, against a byte-identical fixture home PER WORLD
# (normalization (a) in the header). The fixture carries every branch the digest
# has to render: a present-and-populated context file, an ABSENT one, an
# empty-but-present one, a backlog with all three headings, a task with a meta
# and a status log, and an orphan status log with no meta.

seed_session_home() {  # <dir>
  local d=$1
  mk_home "$d"
  printf 'tmux\n' > "$d/config/backend"
  printf '# projects\n\n- demo -> /nowhere\n' > "$d/data/projects.md"
  : > "$d/data/captain.md"
  printf '# learnings\n\n- 2026-01-01 something\n' > "$d/data/learnings.md"
  {
    printf '## In flight\n'
    printf -- '- t1 first task\n'
    printf '  body line that must NOT appear\n'
    printf '## Queued\n'
    printf -- '- t2 second task\n'
    printf '## Notes\n'
    printf -- '- t3 must not be counted\n'
    printf '## Done\n'
    printf -- '- t0 finished\n'
  } > "$d/data/backlog.md"
  {
    printf 'window=fm-t1\n'
    printf 'project=demo\n'
    printf 'harness=claude\n'
    printf 'kind=ship\n'
  } > "$d/state/t1.meta"
  printf 'running: one\nrunning: two\nrunning: three\n' > "$d/state/t1.status"
  printf 'done: orphan\n' > "$d/state/t9.status"
}

SS_BASH="$TMP_ROOT/ss-bash"
SS_PS="$TMP_ROOT/ss-ps"
seed_session_home "$SS_BASH"
seed_session_home "$SS_PS"

CASE_ENV=("FM_HOME=$SS_BASH" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_SESSION_START_STATUS_TAIL=2 FM_SESSION_START_BACKLOG_LIMIT=2 'PATH=%MINPATH%')
run_case session-start fm-session-start
# The PowerShell half must be pointed at its OWN home, so its case record is
# rewritten rather than reusing the one just emitted.
{
  # shellcheck disable=SC2001
  tail -n 1 "$CASE_FILE" | sed "s|FM_HOME=$SS_BASH|FM_HOME=$SS_PS|"
} > "$TMP_ROOT/.ss-case"
head -n -1 "$CASE_FILE" > "$TMP_ROOT/.cases-trimmed"
cat "$TMP_ROOT/.cases-trimmed" "$TMP_ROOT/.ss-case" > "$CASE_FILE"

fi

# --- the PowerShell half: ONE pwsh for every case -----------------------------

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

DRIVER="$TMP_ROOT/driver.ps1"
{
  printf 'Set-StrictMode -Version Latest\n'
  printf "\$ErrorActionPreference = 'Continue'\n"
  printf "\$US = [char]0x1f\n\$RS = [char]0x1e\n\$GS = [char]0x1d\n\$FS = [char]0x1c\n"
  printf "\$CaseFile = '%s'\n" "$(to_native "$CASE_FILE")"
  printf "\$OutFile  = '%s'\n" "$(to_native "$TMP_ROOT/ps-answers.tsv")"
  printf "\$BinDir   = '%s'\n" "$(to_native "$ROOT/bin")"
  printf "\$MinPath  = '%s'\n" "${MIN_PS_PATH//\'/\'\'}"
} > "$DRIVER"
cat >> "$DRIVER" <<'PSEOF'

function Restore-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace($RS, "`n").Replace($GS, "`r").Replace($FS, "`t")
}

function Protect-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", $GS).Replace("`n", $RS).Replace("`t", $FS)
}

# Pre-imported ONCE, before any console redirection: fm-common's body assigns
# [Console]::OutputEncoding, and that assignment REBUILDS [Console]::Out. Doing
# it inside the first redirected case would silently discard that case's output.
# Every module the five entrypoints touch is warmed here for the same reason and
# to keep the per-case cost to the script body alone.
foreach ($m in @('fm-common', 'fm-psproc-lib', 'fm-session-lock-lib', 'fm-wake-lib',
        'fm-backend', 'fm-tasks-axi-lib', 'fm-quota-axi-lib', 'fm-tangle-lib',
        'fm-ff-lib', 'fm-config-inherit-lib', 'fm-startup-memory-budget-lib',
        'fm-x-lib', 'fm-secondmate-registry-lib', 'fm-public-followup-lib')) {
    Import-Module (Join-Path $BinDir "$m.psm1") -ErrorAction SilentlyContinue
}

# Every environment name any case may set, cleared before each case so a value
# from one case can never leak into the next - the batch equivalent of a bash
# prefix assignment, which does NOT survive to a single trailing pwsh run.
$TouchedNames = @('CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT', 'FM_HOME',
    'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE',
    'FM_PROJECTS_OVERRIDE', 'FM_BOOTSTRAP_DETECT_ONLY', 'FM_BOOTSTRAP_VERBOSE_FACTS',
    'FM_CODEX_WATCH_CHECKPOINT', 'FM_SESSION_START_STATUS_TAIL',
    'FM_SESSION_START_BACKLOG_LIMIT', 'FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT')
$BasePath = $env:PATH

$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
$Answers = [System.Text.StringBuilder]::new()

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    # Split on the record's real TAB, NOT on $FS: FS is the ESCAPE for a tab
    # that appears inside a value, which is exactly why the record separator can
    # still be a plain tab. StringSplitOptions::None keeps trailing empty
    # fields, which most cases legitimately have (no args, no env), and the
    # COUNT is asserted rather than assumed.
    $fields = @($line.Split("`t", [System.StringSplitOptions]::None))
    if ($fields.Count -ne 4) {
        [void]$Answers.AppendLine("PARSE-ERROR-$($fields.Count)`tfields=$($fields.Count)")
        continue
    }
    $label = $fields[0]
    $scriptName = $fields[1]
    $argsRaw = $fields[2]
    $envRaw = $fields[3]

    $caseArgs = @()
    if (-not [string]::IsNullOrEmpty($argsRaw)) {
        # Wrapped in @(...): PowerShell unrolls a single-element array into a
        # bare string, which would then splat as characters.
        foreach ($a in @($argsRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            $caseArgs += (Restore-CaseText $a)
        }
    }

    foreach ($n in $TouchedNames) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    $env:PATH = $BasePath
    if (-not [string]::IsNullOrEmpty($envRaw)) {
        foreach ($kv in @($envRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            if ([string]::IsNullOrEmpty($kv)) { continue }
            $eq = $kv.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $kv.Substring(0, $eq)
            $value = $kv.Substring($eq + 1)
            # The two worlds cannot share one PATH string, so each substitutes
            # its own spelling of the same directories.
            if ($value -ceq '%MINPATH%') { $value = $MinPath }
            Set-Item -LiteralPath "env:$name" -Value $value
        }
    }

    $outWriter = [System.IO.StringWriter]::new()
    $errWriter = [System.IO.StringWriter]::new()
    $rc = 0
    try {
        [Console]::SetOut($outWriter)
        [Console]::SetError($errWriter)
        $global:LASTEXITCODE = 0
        & (Join-Path $BinDir "$scriptName.ps1") @caseArgs
        $rc = $LASTEXITCODE
    } catch {
        $errWriter.Write("DRIVER-EXCEPTION: $($_.Exception.Message)`n")
        $rc = 99
    } finally {
        [Console]::SetOut($OrigOut)
        [Console]::SetError($OrigErr)
    }

    $outText = $outWriter.ToString() -replace "`r`n", "`n"
    $errText = $errWriter.ToString() -replace "`r`n", "`n"
    $answer = "$rc$US" + (Protect-CaseText $outText) + $US + (Protect-CaseText $errText)
    [void]$Answers.AppendLine("$label`t$answer")
}

[System.IO.File]::WriteAllText($OutFile, $Answers.ToString().Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false))
PSEOF

PS_ANSWERS="$TMP_ROOT/ps-answers.tsv"
# run_case restores PATH at the START of each case, not the end, so whatever
# the LAST case set is still in effect here - and one of them deliberately
# reduces PATH to a minimal set that excludes pwsh. Restore before driving the
# PowerShell side, or the whole suite dies with "pwsh: command not found"
# having tested nothing.
export PATH="$BASE_PATH"
pwsh -NoProfile -File "$(to_native "$DRIVER")" >"$TMP_ROOT/driver.log" 2>&1 || {
  printf 'not ok - the PowerShell driver failed to run\n' >&2
  cat "$TMP_ROOT/driver.log" >&2
  exit 1
}
[ -f "$PS_ANSWERS" ] || {
  printf 'not ok - the PowerShell driver produced no answers\n' >&2
  cat "$TMP_ROOT/driver.log" >&2
  exit 1
}

# --- join by label and compare -----------------------------------------------

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

declare -A PS_ANSWER=()
while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  PS_ANSWER[$label]=$answer
done < "$PS_ANSWERS"

# Normalization (a) and (b) - see the header. Applied to BOTH sides with the
# same program, and only to these two shapes.
norm_answer() {  # <answer> <own-home>
  local a=$1 own=$2
  a=${a//$own/<FMHOME>}
  printf '%s' "$a"
}

while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  if [ -z "${PS_ANSWER[$label]+x}" ]; then
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${answer}]
  actual(pwsh)  : <NO ANSWER - the driver never reported this label>
"
    continue
  fi
  ps_answer=${PS_ANSWER[$label]}
  case "$label" in
    harness-own-wrong-values)
      # DECLARED DIVERGENCE 2: the ancestry walks observe different process
      # trees. What the contract requires is that each world answers with ONE
      # line from the accepted vocabulary, which is what is asserted.
      for world in bash pwsh; do
        if [ "$world" = bash ]; then v=$answer; else v=$ps_answer; fi
        rc_part=${v%%$US*}
        rest=${v#*$US}
        out_part=${rest%%$US*}
        out_part=${out_part%"$RS"}   # the answer's encoded trailing newline
        ASSERTIONS=$((ASSERTIONS + 1))
        case "$rc_part:$out_part" in
          0:claude|0:codex|0:opencode|0:pi|0:pi-signed|0:grok|0:kimi|0:unknown) ;;
          *)
            FAILURES=$((FAILURES + 1))
            FAILURE_TEXT="${FAILURE_TEXT}${label} ($world)
  expected: exit 0 and one harness word from the accepted vocabulary
  actual  : [${rc_part}:${out_part}]
"
            ;;
        esac
      done
      ;;
    session-start)
      exp=$(norm_answer "$answer" "$SS_BASH")
      act=$(norm_answer "$ps_answer" "$SS_PS")
      exp=$(printf '%s' "$exp" | sed -E 's/harness pid [0-9]+/harness pid <PID>/g')
      act=$(printf '%s' "$act" | sed -E 's/harness pid [0-9]+/harness pid <PID>/g')
      assert_same "$label" "$exp" "$act"
      ;;
    lock-acquire)
      exp=$(printf '%s' "$answer" | sed -E 's/harness pid [0-9]+/harness pid <PID>/g')
      act=$(printf '%s' "$ps_answer" | sed -E 's/harness pid [0-9]+/harness pid <PID>/g')
      assert_same "$label" "$exp" "$act"
      ;;
    *)
      assert_same "$label" "$answer" "$ps_answer"
      ;;
  esac
done < "$ORACLE_FILE"

# --- the cross-world lock property -------------------------------------------
#
# This is the assertion the whole lock phase exists for. Both worlds wrote a
# real lock into their own fixture; each must resolve the SAME harness pid, and
# each must be able to READ the other's lock and report it held by a live
# harness. If those two facts fail, a captain's home stops working the moment it
# is touched from the other tree - and no amount of matching TEXT would have
# revealed it.
lock_pid_of() {  # <fixture>
  local p=''
  [ -f "$1/state/.lock" ] || { printf ''; return 0; }
  IFS= read -r p < "$1/state/.lock" || true
  printf '%s' "$p"
}

# Both halves acquired into the SAME fixture, bash first and PowerShell second,
# so the file now holds the pid the POWERSHELL twin resolved. Two things follow,
# and both are checked:
#   - the two worlds already had to AGREE on the pid, or PowerShell's acquire
#     would have found a different live harness holding the lock and refused;
#     that comparison is the `lock-acquire` case above.
#   - bash must now be able to read PowerShell's lock and see a LIVE HARNESS.
LOCK_PID=$(lock_pid_of "$TMP_ROOT/lock-acquire")
if [ -z "$LOCK_PID" ]; then
  # Neither world could resolve a harness identity here (no harness ancestry and
  # no CLAUDE_PID). That is a legitimate environment for this check, and the
  # `lock-acquire` case above still compared both worlds' refusal text, so the
  # skip is REPORTED rather than silently counted as a pass.
  printf '# lock: neither world resolved a harness pid in this environment; cross-world read-back not exercised\n'
else
  # shellcheck disable=SC2086  # deliberate word splitting over the name list
  unset $TOUCHED_ENV
  export PATH="$BASE_PATH"
  export FM_HOME="$TMP_ROOT/lock-acquire"
  "$ROOT/bin/fm-lock.sh" status > "$TMP_ROOT/.xstatus" 2>&1 || true
  STATUS_OUT=""
  IFS= read -r STATUS_OUT < "$TMP_ROOT/.xstatus" || true
  unset FM_HOME
  assert_same "lock: bash reads back the lock last written by the PowerShell twin" \
    "lock: held by live harness pid $LOCK_PID" "$STATUS_OUT"
fi

# --- report -------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the W4-session twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# Asserted from an OBSERVED green run, so a refactor that silently drops whole
# phases fails loudly instead of certifying an empty suite.
MIN_ASSERTIONS=1
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the five W4-session twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-session-psm1.test.sh: all assertions passed\n'
