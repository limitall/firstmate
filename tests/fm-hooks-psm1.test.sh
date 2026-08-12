#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Differential test for the four wave-4 hook/event entrypoint twins:
#
#   bin/fm-arm-pretool-check.ps1       vs bin/fm-arm-pretool-check.sh
#   bin/fm-cd-pretool-check.ps1        vs bin/fm-cd-pretool-check.sh
#   bin/fm-subagent-pretool-check.ps1  vs bin/fm-subagent-pretool-check.sh
#   bin/fm-busy-event.ps1              vs bin/fm-busy-event.sh
#
# The three PreToolUse guards have an interface no other converted file has:
# Claude, Codex, Grok, OpenCode and Pi all parse the EXIT CODE and the shape of
# a deny object, and a guard that answers wrongly blocks the captain's shell.
# So this suite compares the exact triple (exit code, stdout, stderr) rather
# than a summarized verdict, and it spends most of its cases on the FAIL-OPEN
# paths, because those are the ones that decide whether a broken environment
# is inert or catastrophic.
#
# THE BATCHING RULE (docs/powershell-port.md, "the one rule that decides
# whether a suite finishes"). A bare `pwsh -NoProfile -Command "exit 0"` costs
# 4.8s on the reference host, so a suite that spawns one pwsh per case never
# finishes. This file therefore writes every PowerShell case to a TSV case
# file and runs ONE pwsh over all of them, joining the two worlds' answers by
# LABEL. Driving a .ps1 ENTRYPOINT that way needs three mechanics that a module
# suite does not:
#
#   - `& script.ps1` runs the script IN-PROCESS and its `exit <n>` terminates
#     only that script, leaving the code in $LASTEXITCODE. Verified on this
#     host: the driver survives 200 hook invocations that all "exit".
#   - Per-case stdin, stdout and stderr come from [Console]::SetIn/SetOut/
#     SetError over StringReader/StringWriter. This is exactly why the four
#     converted entrypoints import fm-common WITHOUT -Force: -Force re-runs the
#     module body, whose console-encoding assignment RESETS [Console]::In and
#     [Console]::Out, and every case after the first would then read the
#     driver's own stdin. That trap cost a full debugging cycle here and is
#     recorded in each entrypoint's header.
#   - Per-case environment is carried in the case RECORD and applied on the
#     PowerShell side, never as a bash prefix assignment, which would have
#     collapsed to the LAST value by the time the single pwsh ran.
#
# Bash is the ORACLE for every case except the two documented divergences,
# which are asserted EXPLICITLY rather than normalized away:
#
#   1. jq. The bash guards fail open when jq is missing, because jq is their
#      only JSON reader; the PowerShell guards parse in-process and have
#      nothing to be missing, so on a jq-less host they still classify. The
#      divergence is strictly in the guarding direction.
#   2. Signals and umask have no Windows twin (docs/powershell-port.md), so the
#      bash `umask 077` on the busy-state record has no assertion here beyond
#      the record CONTENT, which is what both worlds actually read.
#
# Nondeterminism is normalized at exactly two points and nowhere else: the
# minted busy-state generation token and the record timestamp. Both are
# replaced with placeholders AFTER being captured, so a later case can still
# present the real gen back to the writer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (the policy owners are Node)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (used to build harness payloads)"; exit 0; }

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-hooks-psm1)

# A stray FM_ALLOW_SUBAGENT (the subagent guard's escape hatch) or a stray
# FM_ROOT_OVERRIDE in the ambient session would silently disarm whole phases,
# so the base state is pinned here rather than assumed.
unset FM_ALLOW_SUBAGENT FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_BUSY_LOCK_STALE_SECS

# --- record encoding ---------------------------------------------------------
#
# The case file and both worlds' answer buffers are TAB-delimited line records,
# but a hook's INPUT legitimately contains newlines (the multi-line command
# `cd projects/foo\necho done` is a real deny case) and its OUTPUT is JSON that
# may carry tabs. So every payload is transport-encoded onto the C0 separators,
# which no case value uses: US separates list items, RS stands for LF, GS for
# CR, and FS for TAB.
US=$'\x1f'
RS=$'\x1e'
GS=$'\x1d'
FS=$'\x1c'

# enc <text>: sets ENC. A function with a global out-parameter rather than a
# command substitution, because `$(...)` forks, a fork costs 0.36-3.1s on this
# host under load, and this runs thousands of times.
ENC=""
enc() {
  local s=$1
  s=${s//$'\r'/$GS}
  s=${s//$'\n'/$RS}
  s=${s//$'\t'/$FS}
  ENC=$s
}

to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Both spellings of the fixture root, precomputed once for the normalizer.
TMP_ROOT_NATIVE=$(to_native "$TMP_ROOT")
TMP_ROOT_FWD=${TMP_ROOT_NATIVE//\\//}

# --- fixtures ----------------------------------------------------------------
#
# Every fixture carries BOTH twins plus the modules and policy owners they
# need, so the two worlds run against byte-identical trees and a scoping
# difference can only come from the code under test.
# ONE cp per fixture, not one per file. Seven fixtures x fifteen files is 105
# forks, and a fork costs 0.36-3.8s on this host depending on contention -
# measured live at over seven minutes of pure fixture setup before a single case
# ran. Multiple sources into one destination directory is the same result for
# one fork.
HOOK_FILES=(
  fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh fm-busy-event.sh
  fm-arm-pretool-check.ps1 fm-cd-pretool-check.ps1 fm-subagent-pretool-check.ps1 fm-busy-event.ps1
  fm-primary-scope-lib.sh fm-busy-lib.sh
  fm-common.psm1 fm-primary-scope-lib.psm1 fm-busy-lib.psm1
  fm-arm-command-policy.mjs fm-cd-command-policy.mjs
)
HOOK_SOURCES=()
for hook_file in "${HOOK_FILES[@]}"; do
  [ -f "$ROOT/bin/$hook_file" ] || fail "missing source file bin/$hook_file"
  HOOK_SOURCES+=("$ROOT/bin/$hook_file")
done

install_hook_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "${HOOK_SOURCES[@]}" "$dir/bin/"
  chmod +x "$dir/bin"/*.sh "$dir/bin"/*.mjs
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/state"
  install_hook_scripts "$dir"
}

PRIMARY="$TMP_ROOT/primary"
make_primary_fixture "$PRIMARY"
PRIMARY_N=$(to_native "$PRIMARY")

# A secondmate's own primary session: the cd-guard fires here, and so does the
# subagent guard, because a secondmate operates a fleet of its own.
SECONDMATE="$TMP_ROOT/secondmate"
make_primary_fixture "$SECONDMATE"
printf 'sm-hooks-1\n' > "$SECONDMATE/.fm-secondmate-home"
SECONDMATE_N=$(to_native "$SECONDMATE")

# A genuine linked worktree - the shape bin/fm-spawn.sh hands every crewmate.
# git-dir and git-common-dir differ here, so both guards must be inert.
WT_BASE="$TMP_ROOT/wt-base"
CHILD_WT="$TMP_ROOT/child-wt"
fm_git_worktree "$WT_BASE" "$CHILD_WT" fm/hooks-test-branch
: > "$CHILD_WT/AGENTS.md"
mkdir -p "$CHILD_WT/state"
install_hook_scripts "$CHILD_WT"
CHILD_WT_N=$(to_native "$CHILD_WT")

# bin/ present, AGENTS.md absent: some other repo entirely.
NOT_FM="$TMP_ROOT/not-firstmate"
git init -q "$NOT_FM"
git -C "$NOT_FM" commit -q --allow-empty -m init
mkdir -p "$NOT_FM/state"
install_hook_scripts "$NOT_FM"
NOT_FM_N=$(to_native "$NOT_FM")

# AGENTS.md and bin/ but no git repo at all.
NO_GIT="$TMP_ROOT/no-git"
mkdir -p "$NO_GIT/state"
: > "$NO_GIT/AGENTS.md"
install_hook_scripts "$NO_GIT"
NO_GIT_N=$(to_native "$NO_GIT")

# A primary whose bin/ has no policy owners: the "missing classifier" fail-open.
NO_POLICY="$TMP_ROOT/no-policy"
make_primary_fixture "$NO_POLICY"
rm -f "$NO_POLICY/bin/fm-arm-command-policy.mjs" "$NO_POLICY/bin/fm-cd-command-policy.mjs"
NO_POLICY_N=$(to_native "$NO_POLICY")

# A primary whose cd policy is REPLACED by an instrumented stand-in that
# records having run. This is how the prefilter fast path is proven in both
# worlds with the REAL node: a fake `node` on PATH cannot work on the
# PowerShell side (Windows cannot exec a shebang script), but a fake POLICY
# can, and it is the thing whose invocation the prefilter actually controls.
PROBE="$TMP_ROOT/probe"
make_primary_fixture "$PROBE"
PROBE_MARK="$TMP_ROOT/probe-marker"
PROBE_MARK_N=$(to_native "$PROBE_MARK")
cat > "$PROBE/bin/fm-cd-command-policy.mjs" <<EOF
import fs from "node:fs";
fs.appendFileSync(String.raw\`$PROBE_MARK_N\`, "ran\n");
process.stdout.write("deny\tprobe-code\tprobe reason\n");
EOF
PROBE_N=$(to_native "$PROBE")

# A PATH with git but deliberately no node, in each world's own spelling. The
# two strings name different directories on purpose: a PATH is the one fixture
# that cannot be shared, since MSYS and Windows disagree about what a path is.
# What the case asserts is identical in both - node absent, guard inert.
NODELESS_BASH_PATH="/usr/bin:/bin:/mingw64/bin"
NODELESS_PS_PATH=""
if command -v git >/dev/null 2>&1; then
  git_native=$(to_native "$(command -v git)")
  NODELESS_PS_PATH=${git_native%\\*}
fi

# --- oracle / case bookkeeping ----------------------------------------------
#
# Results live in plain shell variables and every case is a direct call, never
# a `( ... )` subshell: a subshell cannot report a failure back to the parent's
# counters, so a bookkeeping scheme built on one can lose a failure and certify
# work it never checked.
CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$CASE_FILE"
ORACLE_FILE="$TMP_ROOT/oracle.tsv"
: > "$ORACLE_FILE"

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# One file per label rather than one shared append log, because the oracle half
# runs CONCURRENTLY (see run_oracle_async): concurrent appends to one file are
# not a race worth reasoning about when a per-label file has none at all. The
# labels are already index- or name-keyed, never path-keyed, so they are legal
# filenames by construction.
ORACLE_DIR="$TMP_ROOT/oracle.d"
mkdir -p "$ORACLE_DIR"

record_expectation() {  # <label> <encoded-answer>
  printf '%s\t%s\n' "$1" "$2" > "$ORACLE_DIR/$1.rec"
}

# run_oracle <label> <base> <fixture> <stdin> <env-list> [args...]
#
# Runs the BASH twin and records label -> "rc<US>stdout<US>stderr", all encoded.
# stdout/stderr come back through `read -d ''`, a builtin, rather than
# `$(cat ...)`: two fewer forks per case, and this runs ~130 times.
run_oracle() {
  local label=$1 base=$2 fixture=$3 stdin=$4 envs=$5
  shift 5
  local rc out err o="$ORACLE_DIR/$label.o" e="$ORACLE_DIR/$label.e"
  local -a envarr=()
  if [ -n "$envs" ]; then
    IFS=$US read -ra envarr <<< "$envs"
  fi
  if [ ${#envarr[@]} -gt 0 ]; then
    printf '%s' "$stdin" | env "${envarr[@]}" "$fixture/bin/$base.sh" "$@" >"$o" 2>"$e"
  else
    printf '%s' "$stdin" | "$fixture/bin/$base.sh" "$@" >"$o" 2>"$e"
  fi
  rc=$?
  out=""; err=""
  IFS= read -r -d '' out < "$o" || true
  IFS= read -r -d '' err < "$e" || true
  enc "$out"; local eout=$ENC
  enc "$err"; local eerr=$ENC
  record_expectation "$label" "$rc$US$eout$US$eerr"
}

# run_oracle_async: the same case, run concurrently under a small cap.
#
# THIS IS THE ONE PLACE THIS SUITE USES A SUBSHELL, AND IT IS SAFE FOR THE ONE
# REASON THAT MATTERS: the job produces a FILE, never a counter. The rule the
# repo learned the hard way is that a `( ... )` cannot report a FAILURE back to
# the parent, so an assertion inside one can vanish as a false pass. Nothing is
# asserted in here - every comparison happens in the parent after `wait`, over
# files that are either present or conspicuously missing.
#
# Why concurrency at all, when docs/powershell-port.md warns that verification
# on this host is fork-bound and does not parallelise: that warning is about
# running whole SUITES side by side, and it was measured on CPU-bound
# contention. These cases are not CPU-bound - a timed cd case showed 44s real
# against 0.3s user and 4s sys, so 90% of the wall time is a fork WAITING (image
# load and antivirus scan). Overlapping six of those recovered a suite that was
# otherwise projected at 1.7 HOURS on a loaded host, measured before and after.
ORACLE_MAX=6
ORACLE_JOBS=0
run_oracle_async() {
  run_oracle "$@" &
  ORACLE_JOBS=$((ORACLE_JOBS + 1))
  if [ "$ORACLE_JOBS" -ge "$ORACLE_MAX" ]; then
    wait -n 2>/dev/null || true
    ORACLE_JOBS=$((ORACLE_JOBS - 1))
  fi
}

# emit_case <label> <base> <fixture-native> <stdin> <env-list> [args...]
#
# Writes the PowerShell half of the same case. Six TAB fields, fixed arity, so
# the driver can assert the field COUNT rather than trusting a split.
emit_case() {
  local label=$1 base=$2 fixture=$3 stdin=$4 envs=$5
  shift 5
  local args="" a
  for a in "$@"; do
    enc "$a"
    if [ -z "$args" ]; then args=$ENC; else args="$args$US$ENC"; fi
  done
  enc "$stdin"; local estdin=$ENC
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$base" "$fixture" "$args" "$estdin" "$envs" >> "$CASE_FILE"
}

# both <label> <base> <bash-fixture> <ps-fixture> <stdin> <env-bash> <env-ps> [args...]
#
# The common shape: drive both worlds with the same argv and stdin. The two
# fixture and env arguments exist only for the cases where the two worlds
# legitimately spell a location or a PATH differently.
both() {
  local label=$1 base=$2 bfix=$3 pfix=$4 stdin=$5 benv=$6 penv=$7
  shift 7
  run_oracle_async "$label" "$base" "$bfix" "$stdin" "$benv" "$@"
  emit_case "$label" "$base" "$pfix" "$stdin" "$penv" "$@"
}

# plain <label> <base> <stdin> [args...] - the primary fixture, no environment.
plain() {
  local label=$1 base=$2 stdin=$3
  shift 3
  both "$label" "$base" "$PRIMARY" "$PRIMARY_N" "$stdin" "" "" "$@"
}

# --- phase 1: the cd-guard decision matrix across three harness entry forms --
#
# A representative slice of the full matrix in tests/fm-cd-pretool-check.test.sh
# rather than all 63 commands: that suite already owns the POLICY's decision
# surface. What this phase owns is that the TRANSPORT renders whatever the
# policy said identically - deny code, stdout/stderr split, and the --claude
# suppression.
#
# The slice size is a MEASURED budget, not an oversight. Each case costs a bash
# fork plus a node spawn in the ORACLE, timed at 44s on this host with four
# conversion agents live - verification here is fork-bound and, as
# docs/powershell-port.md records, does not parallelise. So the commands kept
# are one per distinct TRANSPORT path: a plain deny, a deny with no argument, a
# deny only the quoting-decoder marker reaches, a deny only the prefilter's byte
# strip reaches, an allow that still consults the policy, and an allow the
# prefilter answers by itself.
CD_COMMANDS=(
  'cd projects/foo'
  'popd'
  "\$'\\143d' projects/foo"
  'c\d projects/foo'
  'git -C projects/foo status'
  'abcd project'
)
CD_COMMANDS+=("$(printf 'cd projects/foo\necho done')")

cd_i=0
for cmd in "${CD_COMMANDS[@]}"; do
  cd_i=$((cd_i + 1))
  # Keyed by INDEX, never by the command text or a path: the two worlds spell
  # paths differently, and a key that differs reads as a missing case rather
  # than as a disagreement.
  plain "cd-cli-$cd_i" fm-cd-pretool-check "" --command "$cmd"
  plain "cd-claude-$cd_i" fm-cd-pretool-check "" --claude --command "$cmd"
  # Grok's stdin shape. jq builds the payload so the JSON escaping of a
  # multi-line command is the harness's own, not this suite's.
  payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
  plain "cd-grok-$cd_i" fm-cd-pretool-check "$payload"
done

# --- phase 2: the arm-guard prefilter and decision rendering ------------------
#
# Same measured budget as phase 1: one command per transport path rather than a
# second copy of the policy owner's own suite.
ARM_COMMANDS=(
  'git status'
  'bash bin/fm-watch.sh --arm'
  'pkill -f bin/fm-watch.sh'
  'fm-"watch"-arm.sh'
  "\$'fm-watch'"
)
arm_i=0
for cmd in "${ARM_COMMANDS[@]}"; do
  arm_i=$((arm_i + 1))
  plain "arm-cli-$arm_i" fm-arm-pretool-check "" --command "$cmd"
  payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
  plain "arm-codex-$arm_i" fm-arm-pretool-check "$payload"
done
# --background is accepted for transport parity and must change nothing.
plain "arm-bg-allow" fm-arm-pretool-check "" --command 'git status' --background true
plain "arm-bg-deny" fm-arm-pretool-check "" --claude --command 'bash bin/fm-watch.sh --arm' --background true

# --- phase 3: the subagent guard's tool-shape classification ------------------
#
# No node on this path at all, so these are cheap: the whole classification is
# the normalizer plus three name lists.
SUBAGENT_TOOLS=(
  'Task' 'Agent' 'TaskCreate' 'TaskUpdate' 'TaskStop' 'TaskList'
  'BashOutput' 'KillShell' 'CronList' 'CronCreate'
  'mcp__jira__create_task' 'Read' 'Bash' 'SendMessage'
  'worktree_create' 'schedule_job' 'monitor_fleet' 'TASK'
)
sub_i=0
for tool in "${SUBAGENT_TOOLS[@]}"; do
  sub_i=$((sub_i + 1))
  plain "sub-claude-$sub_i" fm-subagent-pretool-check "" --claude --tool "$tool"
  payload=$(jq -cn --arg tool "$tool" '{tool_name:$tool,tool_input:{}}')
  plain "sub-stdin-$sub_i" fm-subagent-pretool-check "$payload"
done

# The escape hatch, and the fact that it is EXACTLY "1".
plain "sub-escape-on" fm-subagent-pretool-check "" --claude --tool Task
both "sub-escape-1" fm-subagent-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_ALLOW_SUBAGENT=1" "FM_ALLOW_SUBAGENT=1" --claude --tool Task
both "sub-escape-yes" fm-subagent-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_ALLOW_SUBAGENT=yes" "FM_ALLOW_SUBAGENT=yes" --claude --tool Task
both "sub-escape-empty" fm-subagent-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_ALLOW_SUBAGENT=" "FM_ALLOW_SUBAGENT=" --claude --tool Task
# Grok's key, and the alternate CLI spelling.
plain "sub-grok" fm-subagent-pretool-check '{"toolName":"Task"}'
plain "sub-tool-eq" fm-subagent-pretool-check "" --claude --tool=Task

# --- phase 4: argument-surface parity ----------------------------------------
plain "arm-help-h" fm-arm-pretool-check "" -h
plain "arm-help-long" fm-arm-pretool-check "" --help
plain "arm-unknown" fm-arm-pretool-check "" --nope
plain "arm-command-novalue" fm-arm-pretool-check "" --command
plain "arm-background-novalue" fm-arm-pretool-check "" --background
plain "arm-command-eq" fm-arm-pretool-check "" --command=git status
plain "arm-background-eq" fm-arm-pretool-check "" --command=ls --background=true
plain "cd-help-h" fm-cd-pretool-check "" -h
plain "cd-help-long" fm-cd-pretool-check "" --help
plain "cd-unknown" fm-cd-pretool-check "" --background true
plain "cd-command-novalue" fm-cd-pretool-check "" --command
plain "cd-command-eq" fm-cd-pretool-check "" --claude --command=cd
plain "sub-help-h" fm-subagent-pretool-check "" -h
plain "sub-help-long" fm-subagent-pretool-check "" --help
plain "sub-unknown" fm-subagent-pretool-check "" --command x
plain "sub-tool-novalue" fm-subagent-pretool-check "" --tool

# --- phase 5: fail-open transport --------------------------------------------
plain "arm-stdin-empty" fm-arm-pretool-check ""
plain "cd-stdin-empty" fm-cd-pretool-check ""
plain "sub-stdin-empty" fm-subagent-pretool-check ""
plain "arm-stdin-garbage" fm-arm-pretool-check "not json at all"
plain "cd-stdin-garbage" fm-cd-pretool-check "not json at all"
plain "sub-stdin-garbage" fm-subagent-pretool-check "not json at all"
plain "arm-stdin-noshape" fm-arm-pretool-check '{"tool_name":"Bash"}'
plain "cd-stdin-noshape" fm-cd-pretool-check '{"tool_input":{}}'
plain "sub-stdin-noshape" fm-subagent-pretool-check '{"tool_input":{"command":"x"}}'
plain "arm-stdin-null" fm-arm-pretool-check '{"tool_input":{"command":null}}'
plain "cd-stdin-empty-cmd" fm-cd-pretool-check '{"tool_input":{"command":""}}'
plain "sub-stdin-empty-tool" fm-subagent-pretool-check '{"tool_name":""}'
plain "arm-stdin-scalar" fm-arm-pretool-check '"just a string"'
plain "cd-stdin-array" fm-cd-pretool-check '[1,2,3]'
# Grok's key wins when both are present, exactly as `//` orders them.
plain "arm-stdin-both-keys" fm-arm-pretool-check \
  '{"toolInput":{"command":"bin/fm-watch.sh"},"tool_input":{"command":"ls"}}'
plain "cd-stdin-both-keys" fm-cd-pretool-check \
  '{"toolInput":{"command":"cd projects/foo"},"tool_input":{"command":"ls"}}'

# Missing policy owner: the guard must be inert, not broken.
both "arm-nopolicy" fm-arm-pretool-check "$NO_POLICY" "$NO_POLICY_N" "" "" "" \
  --claude --command 'bash bin/fm-watch.sh --arm'
both "cd-nopolicy" fm-cd-pretool-check "$NO_POLICY" "$NO_POLICY_N" "" "" "" \
  --claude --command 'cd projects/foo'

# Missing node: the same, through a PATH with git but no node in each world's
# own spelling.
if [ -n "$NODELESS_PS_PATH" ]; then
  both "arm-nonode" fm-arm-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
    "PATH=$NODELESS_BASH_PATH" "PATH=$NODELESS_PS_PATH" \
    --claude --command 'bash bin/fm-watch.sh --arm'
  both "cd-nonode" fm-cd-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
    "PATH=$NODELESS_BASH_PATH" "PATH=$NODELESS_PS_PATH" \
    --claude --command 'cd projects/foo'
fi

# --- phase 6: scoping --------------------------------------------------------
both "cd-secondmate" fm-cd-pretool-check "$SECONDMATE" "$SECONDMATE_N" "" "" "" \
  --claude --command 'cd projects/foo'
both "cd-childwt" fm-cd-pretool-check "$CHILD_WT" "$CHILD_WT_N" "" "" "" \
  --claude --command 'cd projects/foo'
both "cd-notfm" fm-cd-pretool-check "$NOT_FM" "$NOT_FM_N" "" "" "" \
  --claude --command 'cd projects/foo'
both "cd-nogit" fm-cd-pretool-check "$NO_GIT" "$NO_GIT_N" "" "" "" \
  --claude --command 'cd projects/foo'
both "sub-secondmate" fm-subagent-pretool-check "$SECONDMATE" "$SECONDMATE_N" "" "" "" \
  --claude --tool Task
both "sub-childwt" fm-subagent-pretool-check "$CHILD_WT" "$CHILD_WT_N" "" "" "" \
  --claude --tool Task
both "sub-notfm" fm-subagent-pretool-check "$NOT_FM" "$NOT_FM_N" "" "" "" \
  --claude --tool Task
both "sub-nogit" fm-subagent-pretool-check "$NO_GIT" "$NO_GIT_N" "" "" "" \
  --claude --tool Task
# FM_ROOT_OVERRIDE is what points a guard at a scope other than its own tree.
both "cd-rootoverride-wt" fm-cd-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_ROOT_OVERRIDE=$CHILD_WT" "FM_ROOT_OVERRIDE=$CHILD_WT_N" \
  --claude --command 'cd projects/foo'
both "sub-rootoverride-wt" fm-subagent-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_ROOT_OVERRIDE=$CHILD_WT" "FM_ROOT_OVERRIDE=$CHILD_WT_N" \
  --claude --tool Task
# A state dir that does not exist takes the subagent guard out of scope.
both "sub-nostate" fm-subagent-pretool-check "$PRIMARY" "$PRIMARY_N" "" \
  "FM_STATE_OVERRIDE=$TMP_ROOT/absent-state" "FM_STATE_OVERRIDE=$(to_native "$TMP_ROOT")\\absent-state" \
  --claude --tool Task

# --- phase 7: the prefilter actually skips the policy owner -------------------
#
# Proven with the REAL node against an instrumented policy: the marker file is
# the evidence, and it is checked per world in phase 9 below.
: > "$PROBE_MARK"
probe_after_skip=""
probe_after_run=""
"$PROBE/bin/fm-cd-pretool-check.sh" --claude --command 'git status' >/dev/null 2>&1
IFS= read -r -d '' probe_after_skip < "$PROBE_MARK" || true
"$PROBE/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' >/dev/null 2>&1
IFS= read -r -d '' probe_after_run < "$PROBE_MARK" || true
: > "$PROBE_MARK"
emit_case "probe-ps-skip" fm-cd-pretool-check "$PROBE_N" "" "" --claude --command 'git status'
emit_case "probe-ps-marker-1" __marker "$PROBE_MARK_N" "" ""
emit_case "probe-ps-run" fm-cd-pretool-check "$PROBE_N" "" "" --claude --command 'cd projects/foo'
emit_case "probe-ps-marker-2" __marker "$PROBE_MARK_N" "" ""

# --- phase 8: fm-busy-event --------------------------------------------------
#
# Every concurrent oracle job is drained FIRST. This phase is a stateful
# sequence run serially, and letting it overlap the async pool would both muddy
# the `wait -n` bookkeeping and put unrelated forks between an `arm` and the
# step that must observe it.
#
# A SEQUENCE, not independent cases: each step observes what the previous one
# wrote. The minted gen differs per world by construction (it embeds a pid and
# a random), so it is captured per world and substituted into later steps
# through %GEN%, then normalized away before comparison. %OLDGEN% is a
# well-formed token that was never armed - the stale-incarnation input.
wait
ORACLE_JOBS=0

BUSY_BASH="$TMP_ROOT/busy-bash"
BUSY_PS_DIR="$TMP_ROOT/busy-ps"
mkdir -p "$BUSY_BASH" "$BUSY_PS_DIR"
BUSY_PS_N=$(to_native "$BUSY_PS_DIR")
BUSY_ABSENT="$TMP_ROOT/busy-absent"
BUSY_ABSENT_N=$(to_native "$BUSY_ABSENT")

# Each step is a '|'-separated argv (no case value contains '|'), or a DUMP
# pseudo-step naming a task id.
BUSY_STEPS=(
  'b01|'
  'b02|bogus'
  'b03|arm|%STATE%'
  'b04|arm|%STATE%|bad/id'
  'b05|arm|%ABSENT%|t1'
  'b06|arm|%STATE%|t1'
  'b07|DUMP|t1'
  'b08|apply|%STATE%|t1|idle|--gen|%OLDGEN%|--source|claude-hook|--event|stop'
  'b09|apply|%STATE%|t1|idle|--current-gen|--source|claude-hook|--event|stop'
  'b10|DUMP|t1'
  'b11|apply|%STATE%|t1|busy|--gen|%GEN%|--source|claude-hook|--event|prompt'
  'b12|DUMP|t1'
  'b13|apply|%STATE%|t1|sideways|--gen|%GEN%|--source|claude-hook|--event|x'
  'b14|apply|%STATE%|t1|busy|--gen|%GEN%|--source|bad source|--event|x'
  'b15|apply|%STATE%|t1|busy|--gen|%GEN%|--source|claude-hook|--event'
  'b16|apply|%STATE%|t1|busy|--gen|%GEN%|--source|claude-hook|--event|bad/event'
  'b17|apply|%STATE%|t2|busy|--gen|%GEN%|--source|claude-hook|--event|x'
  'b18|retire|%STATE%|t2|--current-gen'
  'b19|retire|%STATE%|t1|--gen|%OLDGEN%'
  'b20|arm|%STATE%|t3|--bogus'
  'b21|DUMP|t1'
  'b22|arm|%STATE%|t1|--state|idle|--source|fm-recovery|--event|relaunch'
  'b23|DUMP|t1'
  'b24|apply|%STATE%|t1|unknown|--gen|%GEN%|--source|fm-interrupt|--event|interrupt'
  'b25|DUMP|t1'
  'b26|retire|%STATE%|t1|--current-gen'
  'b27|DUMP|t1'
  'b28|apply|%STATE%|t1|busy|--gen|%GEN%|--source|claude-hook|--event|prompt'
)
BUSY_OLDGEN='g1700000000.4242.777'

# normalize_busy_line: replace the two nondeterministic fields with
# placeholders. Field-split with `read`, not sed: builtin, and the format has a
# fixed seven-token shape whose positions ARE the contract.
NORMALIZED=""
normalize_busy_record() {
  local line=$1 f1 f2 f3 f4 f5 f6 f7 rest
  if [ -z "$line" ]; then NORMALIZED="absent"; return; fi
  IFS=' ' read -r f1 f2 f3 f4 f5 f6 f7 rest <<< "$line"
  NORMALIZED="$f1 gen=<GEN> $f3 $f4 $f5 $f6 ts=<TS>"
  # A record whose shape is NOT the expected seven tokens must not be
  # normalized into looking correct.
  case "$f2" in gen=*) : ;; *) NORMALIZED="unexpected:$line" ;; esac
  case "$f7" in ts=*) : ;; *) NORMALIZED="unexpected:$line" ;; esac
  [ -z "$rest" ] || NORMALIZED="unexpected:$line"
}

BUSY_GEN=""
for step in "${BUSY_STEPS[@]}"; do
  IFS='|' read -ra parts <<< "$step"
  label=${parts[0]}
  argv=("${parts[@]:1}")
  if [ "${argv[0]:-}" = DUMP ]; then
    id=${argv[1]}
    rec=""; gen_present=absent
    [ -f "$BUSY_BASH/$id.busy-state" ] && IFS= read -r rec < "$BUSY_BASH/$id.busy-state"
    [ -e "$BUSY_BASH/$id.busy-gen" ] && gen_present=present
    normalize_busy_record "$rec"
    enc "record=$NORMALIZED gen-file=$gen_present"
    record_expectation "$label" "0$US$ENC$US"
    emit_case "$label" __busydump "$BUSY_PS_N" "" "" "$id"
    continue
  fi
  # Substitute the per-world tokens. The bash side substitutes here; the
  # PowerShell side carries the placeholders through and substitutes its OWN
  # captured gen, because the two worlds never share one.
  bargv=()
  pargv=()
  for a in "${argv[@]}"; do
    b=$a
    b=${b//%STATE%/$BUSY_BASH}
    b=${b//%ABSENT%/$BUSY_ABSENT}
    b=${b//%OLDGEN%/$BUSY_OLDGEN}
    b=${b//%GEN%/$BUSY_GEN}
    bargv+=("$b")
    p=$a
    p=${p//%STATE%/$BUSY_PS_N}
    p=${p//%ABSENT%/$BUSY_ABSENT_N}
    p=${p//%OLDGEN%/$BUSY_OLDGEN}
    pargv+=("$p")
  done
  if [ ${#bargv[@]} -eq 0 ]; then
    run_oracle "$label" fm-busy-event "$PRIMARY" "" ""
    emit_case "$label" fm-busy-event "$PRIMARY_N" "" ""
  else
    run_oracle "$label" fm-busy-event "$PRIMARY" "" "" "${bargv[@]}"
    emit_case "$label" fm-busy-event "$PRIMARY_N" "" "" "${pargv[@]}"
  fi
  # Capture a freshly minted gen for later steps, then normalize the recorded
  # stdout so the comparison never sees it.
  if [ "${bargv[0]:-}" = arm ]; then
    IFS= read -r -d '' armed_out < "$ORACLE_DIR/$label.o" || true
    armed_out=${armed_out%$'\n'}
    case "$armed_out" in
      g*) BUSY_GEN=$armed_out ;;
    esac
  fi
done

# --- run the PowerShell half: ONE pwsh for every case ------------------------
DRIVER="$TMP_ROOT/driver.ps1"
# The driver is written as a here-doc with the separators and paths injected,
# rather than hard-coded escapes, so the two halves can never drift apart.
cat > "$DRIVER" <<PSEOF
Set-StrictMode -Version Latest
\$ErrorActionPreference = 'Stop'

\$US = [char]0x1f
\$RS = [char]0x1e
\$GS = [char]0x1d
\$FS = [char]0x1c
\$CaseFile = '$(to_native "$CASE_FILE")'
\$OutFile  = '$(to_native "$TMP_ROOT/ps-answers.tsv")'
PSEOF
cat >> "$DRIVER" <<'PSEOF'

function Restore-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace($RS, "`n").Replace($GS, "`r").Replace($FS, "`t")
}

function Protect-CaseText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace("`r", $GS).Replace("`n", $RS).Replace("`t", $FS)
}

# Every environment name any case may set. Cleared before each case so a value
# from one case can never leak into the next - the batch equivalent of a bash
# prefix assignment, which does NOT survive to a single trailing pwsh run.
$TouchedNames = @('FM_ALLOW_SUBAGENT', 'FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE',
    'FM_BUSY_LOCK_STALE_SECS', 'PATH')
$BasePath = $env:PATH
foreach ($n in $TouchedNames) {
    if ($n -ne 'PATH') { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
}

$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
$OrigIn = [Console]::In
$Answers = [System.Text.StringBuilder]::new()

# The gen minted by THIS world's last `arm`. The bash side captured its own and
# substituted it before writing the case file; the placeholder that survives
# here is deliberately substituted with the PowerShell-side value.
$CurrentGen = ''

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    # Split on the record's real TAB, NOT on $FS: FS is the ESCAPE for a tab
    # that appears inside a value, which is exactly why the record separator can
    # still be a plain tab. Confusing the two produced one field per line, every
    # case read as a parse error, and a suite that reported 153 "no answer"
    # failures against a perfectly good PowerShell half.
    #
    # StringSplitOptions::None keeps trailing empty fields, which several cases
    # legitimately have (no args, no stdin, no env), and the COUNT is asserted
    # rather than assumed.
    $fields = @($line.Split("`t", [System.StringSplitOptions]::None))
    if ($fields.Count -ne 6) {
        [void]$Answers.AppendLine("PARSE-ERROR-$($fields.Count)`tfields=$($fields.Count) line=$line")
        continue
    }
    $label = $fields[0]
    $base = $fields[1]
    $fixture = $fields[2]
    $argsRaw = $fields[3]
    $stdin = Restore-CaseText $fields[4]
    $envRaw = $fields[5]

    $caseArgs = @()
    if (-not [string]::IsNullOrEmpty($argsRaw)) {
        foreach ($a in @($argsRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            $caseArgs += (Restore-CaseText $a)
        }
    }
    # %GEN% reaches this side only when the bash half had no gen to substitute
    # OR the placeholder is meant for this world; either way it binds to the
    # generation THIS world minted.
    $caseArgs = @($caseArgs | ForEach-Object { $_.Replace('%GEN%', $CurrentGen) })

    # --- pseudo-cases: filesystem observations, not script runs --------------
    if ($base -eq '__marker') {
        $seen = 'absent'
        if ([System.IO.File]::Exists($fixture)) {
            $text = [System.IO.File]::ReadAllText($fixture)
            $seen = if ($text -eq '') { 'empty' } else { 'ran' }
        }
        [void]$Answers.AppendLine("$label`t$seen")
        continue
    }
    if ($base -eq '__busydump') {
        $id = $argsRaw
        $recordPath = Join-Path $fixture "$id.busy-state"
        $genPath = Join-Path $fixture "$id.busy-gen"
        $normalized = 'absent'
        if ([System.IO.File]::Exists($recordPath)) {
            $text = [System.IO.File]::ReadAllText($recordPath)
            $nl = $text.IndexOf("`n")
            $recLine = if ($nl -ge 0) { $text.Substring(0, $nl) } else { $text }
            $tok = @($recLine.Split(' ', [System.StringSplitOptions]::None))
            if ($tok.Count -eq 7 -and $tok[1].StartsWith('gen=') -and $tok[6].StartsWith('ts=')) {
                $normalized = "$($tok[0]) gen=<GEN> $($tok[2]) $($tok[3]) $($tok[4]) $($tok[5]) ts=<TS>"
            } else {
                $normalized = "unexpected:$recLine"
            }
        }
        $genSeen = if ([System.IO.File]::Exists($genPath) -or [System.IO.Directory]::Exists($genPath)) { 'present' } else { 'absent' }
        $answer = "0$US" + (Protect-CaseText "record=$normalized gen-file=$genSeen") + $US
        [void]$Answers.AppendLine("$label`t$answer")
        continue
    }

    # --- environment for exactly this case -----------------------------------
    foreach ($n in $TouchedNames) {
        if ($n -eq 'PATH') { $env:PATH = $BasePath }
        else { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    }
    if (-not [string]::IsNullOrEmpty($envRaw)) {
        foreach ($pair in @($envRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            if ([string]::IsNullOrEmpty($pair)) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $pair.Substring(0, $eq)
            $value = Restore-CaseText $pair.Substring($eq + 1)
            Set-Item -LiteralPath "env:$name" -Value $value
        }
    }

    $script = Join-Path (Join-Path $fixture 'bin') "$base.ps1"
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
    [Console]::SetIn([System.IO.StringReader]::new($stdin))
    [Console]::SetOut($so)
    [Console]::SetError($se)
    $global:LASTEXITCODE = 0
    $threw = ''
    try {
        & $script @caseArgs
    } catch {
        $threw = $_.Exception.Message
    }
    $rc = $LASTEXITCODE
    [Console]::SetOut($OrigOut)
    [Console]::SetError($OrigErr)
    [Console]::SetIn($OrigIn)

    $outText = $so.ToString()
    $errText = $se.ToString()
    if ($threw -ne '') { $errText = $errText + "DRIVER-EXCEPTION: $threw`n" }

    # Capture and then normalize a freshly minted busy generation, exactly as
    # the bash half does, so the comparison never sees a value that cannot match.
    if ($base -eq 'fm-busy-event' -and $caseArgs.Count -ge 1 -and $caseArgs[0] -eq 'arm') {
        $candidate = $outText.TrimEnd("`n")
        if ($candidate -cmatch '\Ag[0-9]+\.[0-9]+\.[0-9]+\z') { $CurrentGen = $candidate }
    }

    $answer = "$rc$US" + (Protect-CaseText $outText) + $US + (Protect-CaseText $errText)
    [void]$Answers.AppendLine("$label`t$answer")
}

[System.IO.File]::WriteAllText($OutFile, $Answers.ToString().Replace("`r`n", "`n"),
    [System.Text.UTF8Encoding]::new($false))
PSEOF

PS_ANSWERS="$TMP_ROOT/ps-answers.tsv"
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

# --- join by label and compare ----------------------------------------------
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

# Assemble the per-label oracle records into one file: a single cat over a glob,
# not one per label, for the same fork-cost reason the fixtures use one cp.
# DECLARED NORMALIZATION - the busy-event generation token.
#
# `fm-busy-event arm` mints a gen shaped g<epoch>.<pid>.<random>, so the two
# worlds CANNOT produce the same one: different clock reading, different pid,
# different random. Comparing it raw asserted that two independent
# nondeterministic values coincide - impossible, and no evidence about the twin.
# The contract is that BOTH worlds mint a token of the right SHAPE, which is
# what survives normalization; a malformed or absent token still fails.
#
# Implemented with bash regex and parameter expansion rather than `printf | sed`
# because this runs once PER ASSERTION and a fork costs 0.36-4s on this host -
# the sed form turned a passing suite into an hour-long timeout.
# ASSIGNS to the named variable rather than printing, because `$(norm ...)` is
# a COMMAND SUBSTITUTION - a forked subshell - and this runs twice per
# assertion. On a host where a fork costs 0.36-4s that alone is the difference
# between a suite that finishes and one that times out at an hour.
norm_gen_into() {  # <target-var> <text>
  local s=$2
  while [[ $s =~ (g[0-9]+[.][0-9]+[.][0-9]+) ]]; do
    s=${s//"${BASH_REMATCH[1]}"/g<GEN>}
  done
  # SECOND DECLARED NORMALIZATION - the fixture root path SPELLING.
  #
  # A diagnostic naming a path is emitted by each world in its own form: bash
  # says /tmp/fm-hooks-psm1.X/y, the twin says the native AppData Temp path.
  # Those are the SAME LOCATION (MSYS mounts /tmp onto it), so comparing the
  # spellings tests the mount table rather than the twin. Both roots collapse
  # to <ROOT> and separators unify, leaving the wording, the exit code and the
  # trailing component of every message fully compared.
  # Separators are unified FIRST, then the root is matched in its unified
  # spelling. Doing it the other way round cannot work: the PowerShell answer
  # arrives with backslashes, so a forward-slash root never matches, and the
  # backslash root did not match either once the value had been encoded.
  s=${s//\\//}
  s=${s//"$TMP_ROOT_FWD"/<ROOT>}
  s=${s//"$TMP_ROOT"/<ROOT>}
  printf -v "$1" '%s' "$s"
}

cat "$ORACLE_DIR"/*.rec > "$ORACLE_FILE"

declare -A PS_ANSWER=()
while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  PS_ANSWER[$label]=$answer
done < "$PS_ANSWERS"

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
  norm_gen_into NORM_EXPECTED "$answer"
  norm_gen_into NORM_ACTUAL "${PS_ANSWER[$label]}"
  assert_same "$label" "$NORM_EXPECTED" "$NORM_ACTUAL"
done < "$ORACLE_FILE"

# --- the prefilter evidence, per world ---------------------------------------
#
# Compared as facts rather than through the label join, because the bash half's
# marker readings were taken inline while the PowerShell half's are pseudo-cases.
assert_same "probe-bash: prefilter skipped the policy owner" "" "$probe_after_skip"
assert_same "probe-bash: a cd command reached the policy owner" "ran" "${probe_after_run%$'\n'}"
assert_same "probe-ps: prefilter skipped the policy owner" "empty" "${PS_ANSWER[probe-ps-marker-1]:-<missing>}"
assert_same "probe-ps: a cd command reached the policy owner" "ran" "${PS_ANSWER[probe-ps-marker-2]:-<missing>}"

# --- the two documented divergences, asserted rather than normalized ---------
#
# 1. jq. With jq removed from PATH the bash stdin transport cannot extract a
#    command and allows; the PowerShell transport parses in-process and still
#    classifies. Asserted as a DIFFERENCE so the day it changes is loud.
NOJQ=$(fm_fakebin "$TMP_ROOT/nojq")
for tool in bash sh git dirname cat printf sed tr node; do
  tool_path=$(command -v "$tool") || continue
  fm_fakebin_tool "$NOJQ" "$tool" "$tool_path"
done
nojq_rc=0
printf '%s' '{"tool_input":{"command":"cd projects/foo"}}' \
  | PATH="$NOJQ" "$PRIMARY/bin/fm-cd-pretool-check.sh" --claude >"$TMP_ROOT/.nojq.out" 2>/dev/null || nojq_rc=$?
assert_same "divergence: the bash stdin transport fails open without jq" "0" "$nojq_rc"
assert_same "divergence: the PowerShell transport needs no jq and still denies" \
  "2" "$(printf '%s' "${PS_ANSWER[cd-grok-1]:-}" | cut -d"$US" -f1)"

# 2. The busy-state record written by one world must be readable by the other.
#    This is contract 2 in docs/powershell-port.md, and it is the whole reason
#    the gen/ts normalization above is applied only to the COMPARISON.
CROSS="$TMP_ROOT/cross"
mkdir -p "$CROSS"
"$PRIMARY/bin/fm-busy-event.sh" arm "$CROSS" xtask >"$TMP_ROOT/.cross.out" 2>/dev/null
cross_gen=""
IFS= read -r -d '' cross_gen < "$TMP_ROOT/.cross.out" || true
cross_gen=${cross_gen%$'\n'}
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh" >/dev/null 2>&1 || true
cross_read=$(fm_busy_record_read "$CROSS" xtask 2>/dev/null || printf 'READ-FAILED')
assert_same "interop: the bash writer's record parses under the bash reader" \
  "busy fm-spawn launch-brief 1" "$cross_read"
assert_same "interop: the bash writer minted a well-formed gen" "yes" \
  "$(case "$cross_gen" in g*.*.*) printf yes ;; *) printf "no:$cross_gen" ;; esac)"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the hook twins differ from their bash oracle (%d of %d assertions):\n' \
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

printf 'ok - the four hook/event twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-hooks-psm1.test.sh: all assertions passed\n'
