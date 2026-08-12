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
#      MISSING/MISSING_MANUAL (absent AND below-floor), NEEDS_GH_AUTH, TANGLE
#      (both wordings, and both of the lock states that SELECT between them),
#      WINDOWS_SETUP, CREW_DISPATCH (four distinct validator verdicts),
#      SECONDMATE_LIVENESS / SECONDMATE_SYNC / NUDGE_SECONDMATES on a remote
#      route, and the three `install` refusals.
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
unset FM_SESSION_START_QUEUED_LIMIT FM_SESSION_START_TIMEOUT FM_SESSION_START_STAGE_FILE
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

# --- axi-family version-floor fakebins ----------------------------------------
#
# The version FLOORS (no-mistakes, gh-axi, lavish-axi) are a different branch
# from the absent-tool one every other bootstrap case drives: the tool is
# PRESENT and reports a version, and the diagnostic is an upgrade demand rather
# than an install. Driving it needs a tool on PATH that both worlds can run, and
# the two worlds resolve differently: bash finds an extensionless script with a
# shebang, while PowerShell resolves through PATHEXT and cannot execute one. So
# each stem is published TWICE in the same directory - `<tool>` for bash and
# `<tool>.cmd` for PowerShell - which is the only shape that gives both worlds a
# runnable fake of the same name. (Verified on this host: Get-Command returns
# the .cmd first, and fm-common's Invoke-FmTool runs a resolved .cmd through
# cmd.exe /c.)
#
# The versions are chosen against the floors the bash twin declares - GH_AXI_MIN
# 0.1.29 and LAVISH_AXI_MIN 0.1.46 - so the pair of cases pins the CONSTANTS and
# not merely the comparison: one build below each floor must report, and a build
# exactly AT each floor must stay silent. A floor bump therefore fails this
# suite until both twins are bumped together, which is the point.
mk_axi_fakebin() {  # <dir> <gh-axi version> <lavish-axi version>
  local dir=$1 gv=$2 lv=$3 tool ver
  mkdir -p "$dir"
  for tool in gh-axi lavish-axi; do
    if [ "$tool" = gh-axi ]; then ver=$gv; else ver=$lv; fi
    printf '#!/usr/bin/env bash\nprintf "%s %s\\n"\n' "$tool" "$ver" > "$dir/$tool"
    chmod +x "$dir/$tool"
    printf '@echo off\r\necho %s %s\r\n' "$tool" "$ver" > "$dir/$tool.cmd"
  done
}
mk_axi_fakebin "$TMP_ROOT/axi-below" 0.1.28 0.1.45
mk_axi_fakebin "$TMP_ROOT/axi-at" 0.1.29 0.1.46

axi_path_pair() {  # <dir> - appends it to both worlds' minimal PATH spellings
  AXI_BASH_PATH="$MIN_BASH_PATH:$1"
  if command -v cygpath >/dev/null 2>&1; then
    AXI_PS_PATH="$MIN_PS_PATH;$(cygpath -w "$1")"
  else
    AXI_PS_PATH="$MIN_PS_PATH:$1"
  fi
}
axi_path_pair "$TMP_ROOT/axi-below"
MIN_BASH_PATH_AXI_BELOW=$AXI_BASH_PATH
MIN_PS_PATH_AXI_BELOW=$AXI_PS_PATH
axi_path_pair "$TMP_ROOT/axi-at"
MIN_BASH_PATH_AXI_AT=$AXI_BASH_PATH
MIN_PS_PATH_AXI_AT=$AXI_PS_PATH
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

# --- remote-secondmate fixtures -----------------------------------------------
#
# The remote route is the one secondmate placement bootstrap reconciles WITHOUT
# a local backend probe and without a local fast-forward: readiness, endpoint
# state, tracked-file sync and inherited-material push all happen on the
# configured host, reached through bin/fm-on.sh. The remote subsystem stays bash
# in both worlds (there is no PowerShell twin of fm-on or of any fm-remote-*
# script), so what these two cases compare is the BRANCHING and the reported
# text, which is what the PowerShell twin owns.
#
# NO NETWORK IS INVOLVED, deliberately. FM_ROOT_OVERRIDE points at the scratch
# fixture repo, so fm-on refuses the hop before it ever dials - "remote command
# is not a genuine tracked executable in this Firstmate checkout" - which drives
# the readiness-failure and sync-failure arms deterministically and instantly.
#
# The homes are SHARED between the two worlds, unlike the session-start case,
# because every write these paths perform is idempotent: the generation counter
# is not printed, and the remote retry marker is rewritten every run and only
# removed on a converged one, which this fixture never is. Verified directly by
# running the twin a second time against the home the bash oracle had already
# written and getting byte-identical output.
#
# The meta deliberately carries NO home= field. bin/fm-ff-lib.psm1's sweep does
# not yet skip remote metas the way sweep_live_secondmate_metas does in bash
# (an open gap in a file this change does not own), so a remote meta carrying a
# home= would draw an extra local "unsafe home" line from the PowerShell side
# alone. With no home=, both worlds' LOCAL sweep is silent and the case isolates
# the remote branches it exists to test.
mk_home "$TMP_ROOT/boot-remote"
printf 'tmux\n' > "$TMP_ROOT/boot-remote/config/backend"
{
  printf 'window=fm-sm1\n'
  printf 'kind=secondmate\n'
  printf 'harness=claude\n'
  printf 'remote_host=example.invalid\n'
  printf 'backend=herdr\n'
} > "$TMP_ROOT/boot-remote/state/sm1.meta"

# The retry-marker placement gate. A durable nudge marker records which
# PLACEMENT it was written for, and the legal message differs between them; a
# marker whose placement is unrecognized is refused rather than defaulted, and a
# well-formed REMOTE marker is skipped silently here because the remote
# convergence sweep owns it. All four are driven at once, in one run, because
# the loop is ordered and each arm is a `continue`:
#   sm2 remote=1 carrying the LOCAL message  -> remote message mismatch
#   sm3 remote=2                             -> placement is invalid
#   sm4 remote=1 carrying the REMOTE message -> silent (owned by the remote sweep)
#   sm5 remote=0 carrying the LOCAL message  -> reaches the live-metadata check
# sm4 is the control that proves the remote guard actually short-circuits: with
# it absent, sm4 would produce sm5's line too.
mk_home "$TMP_ROOT/boot-remote-markers"
printf 'tmux\n' > "$TMP_ROOT/boot-remote-markers/config/backend"
mkdir -p "$TMP_ROOT/boot-remote-markers/state/.secondmate-nudge-pending"
LOCAL_NUDGE_MSG='firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
REMOTE_NUDGE_MSG='Firstmate instructions or inherited config changed on this host. Re-read AGENTS.md and the inherited config files before further work.'
mk_nudge_marker() {  # <id> <remote> <message>
  {
    printf 'id=%s\n' "$1"
    printf 'selector=fm-%s\n' "$1"
    printf 'home=/nowhere\n'
    printf 'commit=\n'
    printf 'instructions=remote\n'
    printf 'message=%s\n' "$3"
    printf 'remote=%s\n' "$2"
  } > "$TMP_ROOT/boot-remote-markers/state/.secondmate-nudge-pending/$1.pending"
}
mk_nudge_marker sm2 1 "$LOCAL_NUDGE_MSG"
mk_nudge_marker sm3 2 "$REMOTE_NUDGE_MSG"
mk_nudge_marker sm4 1 "$REMOTE_NUDGE_MSG"
mk_nudge_marker sm5 0 "$LOCAL_NUDGE_MSG"

# --- case plumbing ------------------------------------------------------------

ORACLE_FILE="$TMP_ROOT/oracle.tsv"
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$ORACLE_FILE"
: > "$CASE_FILE"

# Every name any case may set. run_case unsets the whole list before each case,
# so a value set by one can never leak into the next. FM_BOOTSTRAP_NETWORK and
# FM_BOOTSTRAP_LOCKED belong here for a concrete reason: the network cases
# already set the first one, and without the unset the LAST value assigned
# ("SKIP") stayed exported for every later bash case. That was harmless only
# because an unrecognized value resolves to `all`, which is also the default -
# the moment a case sets `only`, as the remote cases do, the leak would silently
# put every case after it into the network-only phase.
TOUCHED_ENV="CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT FM_HOME
FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
FM_PROJECTS_OVERRIDE FM_BOOTSTRAP_DETECT_ONLY FM_BOOTSTRAP_VERBOSE_FACTS
FM_BOOTSTRAP_NETWORK FM_BOOTSTRAP_LOCKED
FM_CODEX_WATCH_CHECKPOINT FM_SESSION_START_STATUS_TAIL
FM_SESSION_START_BACKLOG_LIMIT FM_SESSION_START_QUEUED_LIMIT
FM_SESSION_START_TIMEOUT FM_SESSION_START_STAGE_FILE
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT"

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
    case "$value" in
      '%MINPATH%') value=$MIN_BASH_PATH ;;
      '%MINPATH_AXI_BELOW%') value=$MIN_BASH_PATH_AXI_BELOW ;;
      '%MINPATH_AXI_AT%') value=$MIN_BASH_PATH_AXI_AT ;;
    esac
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
# The NETWORK-PHASE split, which had no differential coverage at all until the
# defect it hides was found by hand: bin/fm-session-start.sh passes
# FM_BOOTSTRAP_NETWORK=skip on EVERY path, because the network half is what the
# deferred stage is running right now and doing it twice both re-blocks the
# digest and races that worker's sweeps against themselves. The PowerShell
# bootstrap ignored the variable outright - it had no phase concept - so the
# native digest did the network work inline and printed a NEEDS_GH_AUTH the
# oracle does not. Nothing in this suite noticed, because nothing set the
# variable. These three cases pin the whole gate:
#   skip -> the local half only, no network line;
#   only -> the network half only, no local MISSING lines;
#   SKIP -> an UNRECOGNIZED value, which must fall back to `all` rather than
#           silently dropping a safety sweep. bash's `case` is case-sensitive,
#           so the twin's switch must be too - that asymmetry is the whole
#           point of the case and is invisible to a lowercase-only test.
boot_env "$TMP_ROOT/boot-base"; CASE_ENV+=(FM_BOOTSTRAP_NETWORK=skip)
run_case boot-network-skip fm-bootstrap
boot_env "$TMP_ROOT/boot-base"; CASE_ENV+=(FM_BOOTSTRAP_NETWORK=only)
run_case boot-network-only fm-bootstrap
boot_env "$TMP_ROOT/boot-base"; CASE_ENV+=(FM_BOOTSTRAP_NETWORK=SKIP)
run_case boot-network-unrecognized fm-bootstrap

boot_env "$TMP_ROOT/boot-base" "$TANGLE_REPO"; run_case boot-tangle-detect fm-bootstrap
# TANGLE has TWO wordings and detect-only alone does not choose between them:
# FM_BOOTSTRAP_LOCKED does. Detect-only alone means "this session holds no
# lock", so the restore belongs to whoever does and the line carries no command;
# detect-only PLUS locked means "this session already swept while holding the
# lock", so it owns the restore and the line names the exact checkout command.
# The PowerShell twin emitted only the advisory form and ignored the variable
# outright, so a locked read-only session was told to defer to itself. The
# no-flag case above and this one pin both halves of that selector.
boot_env "$TMP_ROOT/boot-base" "$TANGLE_REPO"; CASE_ENV+=(FM_BOOTSTRAP_LOCKED=1)
run_case boot-tangle-locked fm-bootstrap
boot_env "$TMP_ROOT/boot-base" "$STUB_REPO"; run_case boot-windows-stub fm-bootstrap

# The axi-family VERSION FLOORS. An installed build below its floor reports
# MISSING exactly like an absent tool, so the operator is asked to upgrade
# rather than silently running an older tool - and the PowerShell twin checked
# no-mistakes, quota-axi and tasks-axi but neither gh-axi nor lavish-axi, so
# those two upgrade demands were simply never made on Windows. The pair below
# pins both the branch and the constants: below the floor must report, exactly
# at it must not.
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-base" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_BOOTSTRAP_DETECT_ONLY=1 'PATH=%MINPATH_AXI_BELOW%')
run_case boot-axi-floor-below fm-bootstrap
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-base" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_BOOTSTRAP_DETECT_ONLY=1 'PATH=%MINPATH_AXI_AT%')
run_case boot-axi-floor-at fm-bootstrap

# The REMOTE secondmate placement. These two are the only bootstrap cases that
# are NOT detect-only, because the liveness and convergence sweeps are mutating
# ones; FM_BOOTSTRAP_NETWORK=only confines them to the network half, so no
# PR-check migration, no startup-memory-budget materialization and no X-mode
# write happens and the fixture homes stay comparable. See the fixture block
# above for why no network is reached and why the homes may be shared.
# Before this, the PowerShell twin had no remote branch at all: it ran a remote
# endpoint through the LOCAL backend classifier and reported "endpoint probe
# unreadable", losing every readiness, route and convergence diagnostic.
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-remote" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_BOOTSTRAP_NETWORK=only 'PATH=%MINPATH%')
run_case boot-remote-sweep fm-bootstrap
CASE_ENV=("FM_HOME=$TMP_ROOT/boot-remote-markers" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_BOOTSTRAP_NETWORK=only 'PATH=%MINPATH%')
run_case boot-remote-markers fm-bootstrap
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
  # The queued group drives every branch of the compact renderer's bound: two
  # gated title lines (a "(hold: ...)" marker and a "blocked-by:" marker) that
  # must ALWAYS print regardless of the limit, and three plain queued lines of
  # which FM_SESSION_START_QUEUED_LIMIT=2 shows two and discloses one.
  {
    printf '## In flight\n'
    printf -- '- t1 first task\n'
    printf '  body line that must NOT appear\n'
    printf '## Queued\n'
    printf -- '- t2 second task\n'
    printf -- '- t3 third task (hold: captain decision)\n'
    printf -- '- t4 fourth task blocked-by: t1\n'
    printf -- '- t5 fifth task\n'
    printf -- '- t6 sixth task\n'
    printf '## Notes\n'
    printf -- '- t7 must not be counted\n'
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

# The digest now launches the deferred network stage (fm-startup-network.sh
# start) right after the lock and harvests it at the end - and a LIVE stage is
# nondeterministic by construction: its harvest text embeds elapsed seconds
# ("completed off the startup path in 47s"), and whether it reads "completed"
# or "IN PROGRESS" depends on how long the digest between start and harvest
# took, which differs by minutes between the fork-bound oracle and the twin.
# So both fixture homes are pinned to the SAME deterministic in-flight state:
#   - state=running plus a live pid (this test's own shell, alive in both
#     worlds' checks) makes `start` take its single-flight branch - the real
#     production branch for "a worker is already going" - so no real worker is
#     ever launched and no background bootstrap runs during the suite;
#   - lock_pid must equal what fm-lock will write into each home, or
#     single-flight would be refused and a REAL worker launched, so it is
#     probed from a scratch home with the same resolver first;
#   - started=pinned is deliberately non-numeric: worker_alive treats an
#     unparseable age as alive, and print_pending SKIPS its "Started Ns ago"
#     line, removing the last timing-dependent byte from the compared text.
# Harvest then prints the stable IN PROGRESS section in both worlds. If no
# harness identity resolves here, fm-lock refuses in both worlds, the digest
# runs read-only, and this pin is inert (the read-only section is static).
SS_PROBE="$TMP_ROOT/ss-probe"
mk_home "$SS_PROBE"
(
  # A subshell, so the probe's environment never leaks into the case plumbing.
  # shellcheck disable=SC2086  # deliberate word splitting over the name list
  unset $TOUCHED_ENV
  export PATH="$BASE_PATH" FM_HOME="$SS_PROBE"
  "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1 || true
)
SS_LOCK_PID=""
if [ -f "$SS_PROBE/state/.lock" ]; then
  IFS= read -r SS_LOCK_PID < "$SS_PROBE/state/.lock" || true
fi
case "$SS_LOCK_PID" in *[!0-9]*) SS_LOCK_PID="" ;; esac

seed_network_pin() {  # <dir>
  {
    printf 'state=running\n'
    printf 'pid=%s\n' "$$"
    printf 'started=pinned\n'
    printf 'locked=1\n'
    printf 'phases=probe,sweeps\n'
    printf 'generation=fmtest-pinned\n'
    printf 'lock_pid=%s\n' "$SS_LOCK_PID"
  } > "$1/state/.startup-network.status"
}
seed_network_pin "$SS_BASH"
seed_network_pin "$SS_PS"

# FM_SESSION_START_TIMEOUT is pinned HIGH for BOTH worlds, deliberately: the
# bash oracle is fork-bound and genuinely exceeds the default 120s budget on
# this host, so an unpinned run compares a TRUNCATED oracle (digest cut at the
# bound, banner appended) against a complete twin - which is exactly the
# failure this case once produced. The truncation arm itself cannot be driven
# differentially, because which stage the bound lands in depends on host
# speed; it is verified manually with FM_SESSION_START_TIMEOUT=1 instead.
# FM_SESSION_START_QUEUED_LIMIT is the bound the current bash actually reads
# (it replaced FM_SESSION_START_BACKLOG_LIMIT, now inert in both worlds).
CASE_ENV=("FM_HOME=$SS_BASH" "FM_ROOT_OVERRIDE=$BOOT_REPO"
          FM_SESSION_START_STATUS_TAIL=2 FM_SESSION_START_QUEUED_LIMIT=2
          FM_SESSION_START_TIMEOUT=900 'PATH=%MINPATH%')
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
  printf "\$MinPathAxiBelow = '%s'\n" "${MIN_PS_PATH_AXI_BELOW//\'/\'\'}"
  printf "\$MinPathAxiAt    = '%s'\n" "${MIN_PS_PATH_AXI_AT//\'/\'\'}"
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
    'FM_BOOTSTRAP_NETWORK', 'FM_BOOTSTRAP_LOCKED',
    'FM_CODEX_WATCH_CHECKPOINT', 'FM_SESSION_START_STATUS_TAIL',
    'FM_SESSION_START_BACKLOG_LIMIT', 'FM_SESSION_START_QUEUED_LIMIT',
    'FM_SESSION_START_TIMEOUT', 'FM_SESSION_START_STAGE_FILE',
    'FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT')
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
            switch -CaseSensitive ($value) {
                '%MINPATH%' { $value = $MinPath }
                '%MINPATH_AXI_BELOW%' { $value = $MinPathAxiBelow }
                '%MINPATH_AXI_AT%' { $value = $MinPathAxiAt }
            }
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
        if ($scriptName -ceq 'fm-session-start') {
            # OUT OF PROCESS, unlike every other case. The twin now mirrors its
            # bash oracle's runtime bound: the parent re-executes ITSELF as a
            # bounded child pwsh whose stdio is INHERITED, never redirected, so
            # the digest streams. [Console]::SetOut is a .NET-level redirect
            # that a real child process cannot see - an in-process `&` here
            # would stream the whole digest into the driver's log and this case
            # would compare an empty answer. A spawned child whose pipes the
            # driver owns captures the parent AND its bounded grandchild (which
            # inherits those same pipe handles), and drives the true production
            # entry shape (`pwsh -NoProfile -File`). Costs one extra pwsh
            # startup for the whole suite, within the batching rule's
            # once-per-phase budget.
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = [Environment]::ProcessPath
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-File')
            $psi.ArgumentList.Add((Join-Path $BinDir "$scriptName.ps1"))
            foreach ($a in $caseArgs) { $psi.ArgumentList.Add([string]$a) }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            try {
                [void]$proc.Start()
                # Drain both pipes concurrently while waiting: reading one to
                # completion first deadlocks when the child fills the other.
                $outTask = $proc.StandardOutput.ReadToEndAsync()
                $errTask = $proc.StandardError.ReadToEndAsync()
                $proc.WaitForExit()
                $outWriter.Write($outTask.GetAwaiter().GetResult())
                $errWriter.Write($errTask.GetAwaiter().GetResult())
                $rc = $proc.ExitCode
            } finally {
                $proc.Dispose()
            }
        } else {
            & (Join-Path $BinDir "$scriptName.ps1") @caseArgs
            $rc = $LASTEXITCODE
        }
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
