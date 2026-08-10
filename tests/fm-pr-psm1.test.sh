#!/usr/bin/env bash
# Behavior test for the PowerShell PR and review entrypoints:
#   bin/fm-pr-check.ps1  bin/fm-pr-merge.ps1  bin/fm-pr-poll.ps1
#   bin/fm-check-register.ps1  bin/fm-review-diff.ps1
#
# This is a DIFFERENTIAL test: every case drives the bash script and its
# PowerShell twin with byte-identical argv, environment and FIXTURE, then
# compares exit code, stdout, stderr and - for the cases that write - the whole
# resulting state tree. BASH IS THE ORACLE. No verdict is hard-coded here, so a
# case can never quietly encode what the author believed instead of what the
# shipped script does.
#
# WHY THESE FIVE DESERVE A DIFFERENTIAL. Three of them are guards:
#   - fm-pr-merge is the only script in the tree that LANDS a pull request. It
#     refuses anything that is not a canonical GitHub PR URL, refuses --repo/-R
#     overrides (the repository comes only from the URL), and records pr= before
#     merging. Each refusal and its exit code is asserted here.
#   - fm-check-register is what binds a captain-authored check's exact bytes
#     before the watcher may EXECUTE state/<id>.check.sh.
#   - fm-pr-poll decides whether a wake means "merged". It must stay silent on
#     every error, because a silent failure that printed would be read as a
#     merge.
# The other two write durable records that the bash tree keeps reading during
# the transition, so their output must be byte-compatible, not merely correct.
#
# ---------------------------------------------------------------------------
# HOW THE TWO SIDES ARE RUN, AND WHY IT IS SHAPED THIS WAY
#
# A bare `pwsh -NoProfile -Command "exit 0"` costs 4.8s on the reference host,
# so a suite that spawns pwsh per case does not finish (docs/powershell-port.md
# owns that measurement). This suite spawns pwsh EXACTLY ONCE: bash writes every
# case to a file, and one driver runs all of them IN PROCESS with `& script.ps1`.
# Two mechanics make that possible and both were verified here before being
# relied on:
#   - `exit N` inside a script invoked with `&` ends that SCRIPT, not the
#     session, and leaves N in $LASTEXITCODE;
#   - [Console]::SetOut/SetError capture output that Write-FmOut writes through
#     the raw console writer, and a later `Import-Module fm-common -Force`
#     inside the script under test does NOT undo it (.NET only drops the cached
#     writer when OutputEncoding changes and the writer was not redirected).
#
# CHILD PROCESS OUTPUT CANNOT BE CAPTURED THAT WAY, because a child inherits the
# real handle rather than the swapped writer. So the driver writes its RESULTS
# to a file and its own stdout is asserted EMPTY - any leakage from a child is a
# loud failure rather than a corrupted record.
#
# TRANSPORT. Every value crosses hex-encoded under LC_ALL=C, so a fixture byte
# can never be mistaken for structure and no separator is forgeable. Cases are
# keyed by INDEX, never by a path: the two worlds spell the same location
# differently (/tmp/x vs C:\...\Temp\x) and a path key would read as MISSING for
# every case even when the values agree.
#
# PER-CASE ENVIRONMENT IS IN THE RECORD. A bash prefix assignment persists after
# a function call, so by the time the single pwsh runs it would hold only the
# LAST value assigned - every case evaluated against one setting. Environment
# travels in the case record and is applied and cleared per case on the
# PowerShell side.
#
# ---------------------------------------------------------------------------
# WHAT IS NORMALIZED, AND WHY EACH NORMALIZATION IS SAFE
#
# Four things genuinely differ between two runs of the same code, and each is
# normalized EXPLICITLY rather than by a loose comparison:
#   1. device:inode identities in the poll registration. Two publications of the
#      same bytes are two different files, so those lines are replaced with
#      <identity>. The HASHES beside them are content-derived and ARE compared.
#   2. mktemp-style scratch names (.fm-*.XXXXXX, .watch.lock.owner.XXXXXX). The
#      presence of a leftover is compared; the random suffix is not.
#   3. .pr-check-migration.log holds absolute paths, which differ by world.
#      Presence is compared, content is not.
#   4. THE CASE'S OWN WORLD DIRECTORY, wherever it appears in stdout, stderr or
#      a durable record, becomes @W@ (see norm_stream / tree_digest). Two
#      reasons, both structural rather than behavioral:
#        - a WRITING case cannot share one world, because both sides mutate it,
#          so its two fixtures are two directories by construction (arm1b vs
#          arm1p) and the meta record each script rewrites names its own;
#        - even a SHARED world reaches the two runtimes in the two spellings
#          they each need - /tmp/x for bash, C:\...\Temp\x for pwsh - so a
#          diagnostic that quotes its own home differs in spelling alone.
#      Only that root is folded. Where a text carries the native spelling its
#      separators are unified first, so C:\...\x\state\a.meta and
#      /tmp/x/state/a.meta both reduce to @W@/state/a.meta - the message around
#      it, the rest of the path and every other line still compare byte-exactly.
# Nothing else is normalized. Exit codes, stdout, stderr and every durable
# record are compared byte-for-byte.
#
# The gh-axi argv log written by the fake merge tool is compared after stripping
# CR: the PowerShell side reaches the fake through a .cmd shim (Windows
# CreateProcess resolves only PATHEXT names, so a bash-script fake is invisible
# to it) and cmd's `echo` emits CRLF. That is a property of the TEST FAKE, not
# of either script.
#
# ---------------------------------------------------------------------------
# COST. The oracle half is fork-bound and dominates: one full poll publication
# is ~100 MSYS forks, and a fork on this host was measured at 0.36s idle and
# 3.1s with several conversion agents live. The case mix is therefore a BUDGET:
# the fork-free refusals carry most of the assertions, and the four cases that
# actually publish artifacts are spent deliberately. Expect a few minutes idle
# and considerably longer under load; that is the oracle being slow, not the
# suite hanging.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux CI
# until those hosts install PowerShell 7. No bash-4-only syntax beyond arrays,
# which this repo's suites already use.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

for f in fm-pr-check fm-pr-merge fm-pr-poll fm-check-register fm-review-diff; do
  [ -f "$ROOT/bin/$f.ps1" ] || fail "bin/$f.ps1 is missing"
  [ -f "$ROOT/bin/$f.sh" ] || fail "bin/$f.sh (the oracle) is missing"
done

TMP_ROOT=$(fm_test_tmproot fm-pr-ps1)
TMP_ROOT_N=$(fm_test_native_path "$TMP_ROOT")

# nat <path under TMP_ROOT> -> the Windows spelling, derived from the converted
# root by parameter expansion rather than a second cygpath fork.
FM_NAT=
nat() {
  local rel=${1#"$TMP_ROOT"}
  FM_NAT="$TMP_ROOT_N${rel//\//\\}"
}

# --- assertion bookkeeping ---------------------------------------------------
#
# Plain shell variables, recorded from PARENT scope. Nothing here runs inside a
# `( ... )` subshell: a subshell cannot report a failure back to the parent's
# counters, so a scheme that can LOSE a failure is worse than none.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

assert_case() {  # <label> <expected(bash oracle)> <actual(powershell)>
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
# LC_ALL=C makes ${v:i:1} a BYTE, so what crosses is the exact byte sequence
# bash held. %04x then the low two digits, because bash renders a byte >= 0x80
# as a sign-extended 64-bit value.
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

# --- fixtures shared by every case -------------------------------------------

FAKEROOT="$TMP_ROOT/fakeroot"
mkdir -p "$FAKEROOT/bin"
# A silent fm-guard, and DELIBERATELY only the .sh: Invoke-FmScript prefers a
# .ps1 twin, and a nested pwsh would cost a 4.8s startup per case. The bash
# fallback branch is the one worth exercising here anyway - it is the branch
# every unconverted execute edge takes today.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEROOT/bin/fm-guard.sh"
chmod +x "$FAKEROOT/bin/fm-guard.sh"

# The fake forge CLIs. Each exists TWICE: a bash script for the oracle and a
# .cmd shim for PowerShell, because Windows CreateProcess resolves a bare name
# only through PATHEXT and would never see the extensionless file that
# `command -v` finds. Behavior is driven by FM_FAKE_OUT / FM_FAKE_RC so one pair
# serves both the gh head lookup and the gh/glab state lookups.
make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n "$FM_FAKE_OUT"\nexit "$FM_FAKE_RC"\n' > "$dir/gh"
  chmod +x "$dir/gh"
  printf '@echo off\r\necho %%FM_FAKE_OUT%%\r\nexit %%FM_FAKE_RC%%\r\n' > "$dir/gh.cmd"
  printf '#!/usr/bin/env bash\nprintf "title: t\\nstate: %%s\\n" "$FM_FAKE_OUT"\nexit "$FM_FAKE_RC"\n' > "$dir/glab"
  chmod +x "$dir/glab"
  printf '@echo off\r\necho title: t\r\necho state: %%FM_FAKE_OUT%%\r\nexit %%FM_FAKE_RC%%\r\n' > "$dir/glab.cmd"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n "$@" >> "$FM_FAKE_LOG"\nexit "$FM_FAKE_RC"\n' > "$dir/gh-axi"
  chmod +x "$dir/gh-axi"
  {
    printf '@echo off\r\n'
    printf ':loop\r\n'
    printf 'if "%%~1"=="" goto done\r\n'
    printf '>>"%%FM_FAKE_LOG%%" echo %%~1\r\n'
    printf 'shift\r\n'
    printf 'goto loop\r\n'
    printf ':done\r\n'
    printf 'exit %%FM_FAKE_RC%%\r\n'
  } > "$dir/gh-axi.cmd"
}

# Pre-seed the non-executing migration's completion markers so bin/fm-pr-check
# takes its fast path. Without them every arming case pays a full state scan in
# BOTH worlds - the same work, twice, proving nothing this suite is about.
seed_state() {
  local state=$1
  mkdir -p "$state"
  printf 'fm-pr-check-migration-v1\n' > "$state/.pr-check-migration-v1"
  printf 'fm-pr-check-migration-scan-v1\n' > "$state/.pr-check-migration-scan-v1"
  chmod 0600 "$state/.pr-check-migration-v1" "$state/.pr-check-migration-scan-v1"
}

# --- state-tree digest -------------------------------------------------------
#
# Builtin-only (no fork per file): the oracle side is fork-bound and this runs
# for every world of every writing case. See the normalization note in the
# header for what each rewrite covers and why it is safe.
#
# The world directory is folded to @W@ here for the reason header item 4 gives:
# the two fixtures of a writing case ARE two directories, and the meta record
# under test names the one it was built in. Both worlds' records are written by
# bash, so the POSIX spelling is the one that appears - the two native spellings
# are folded too so that a record which ever DID hold one would still show up as
# a difference against a POSIX-form twin rather than being silently equalized.
FM_NORM=
norm_world() {  # <text> <world-dir>
  local t=$1 w=$2 wn ws
  nat "$w"; wn=$FM_NAT
  ws=${wn//\\//}
  t=${t//"$wn"/@W@}
  t=${t//"$ws"/@W@}
  FM_NORM=${t//"$w"/@W@}
}

# norm_stream <text> <world-dir>: norm_world for a captured STREAM, where the
# native spelling arrives with backslashes and a tail (\state\x.meta) that must
# reduce to the same text as the oracle's /state/x.meta. Separators are unified
# only in a text that actually carries the native world root, so a backslash
# anywhere else still compares as itself.
norm_stream() {
  local t=$1 w=$2 wn
  nat "$w"; wn=$FM_NAT
  case $t in
    *"$wn"*) t=${t//\\//} ;;
  esac
  norm_world "$t" "$w"
}

DIGEST=
tree_digest() {  # <state-dir> <world-dir>
  local d=$1 w=$2 f name line body
  DIGEST=''
  for f in "$d"/* "$d"/.*; do
    name=${f##*/}
    case $name in .|..|'*'|'.*') continue ;; esac
    [ -e "$f" ] || continue
    if [ -d "$f" ]; then DIGEST="${DIGEST}dir ${name}/"$'\n'; continue; fi
    case $name in
      .pr-check-migration.log) DIGEST="${DIGEST}present .pr-check-migration.log"$'\n'; continue ;;
      .fm-*|.watch.lock*|*.fm-tmp.*) DIGEST="${DIGEST}scratch ${name%.*}"$'\n'; continue ;;
    esac
    body=''
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        [0-9]*:[0-9]*) line='<identity>' ;;
      esac
      norm_world "$line" "$w"
      body="$body$FM_NORM"$'\n'
    done < "$f"
    DIGEST="${DIGEST}--- ${name}"$'\n'"$body"
  done
}

# --- case batching -----------------------------------------------------------

CASES="$TMP_ROOT/cases.txt"
: > "$CASES"
nat "$CASES"; CASES_N=$FM_NAT
RESULTS="$TMP_ROOT/results.txt"
nat "$RESULTS"; RESULTS_N=$FM_NAT
DRIVER="$TMP_ROOT/driver.ps1"
nat "$DRIVER"; DRIVER_N=$FM_NAT
DRIVER_OUT="$TMP_ROOT/driver.out"
DRIVER_ERR="$TMP_ROOT/driver.err"

LABELS=()
BRC=()
BOUT=()
BERR=()
PWORLD=()
BWORLD=()
WANT_DIGEST=()
BDIGEST=()

# A NESTED FIRSTMATE SCRIPT IS A CHILD PROCESS, AND A CHILD CANNOT BE CAPTURED
# PER CASE. bin/fm-pr-merge runs bin/fm-pr-check, which prints its own
# "armed: ..." line. On the bash side that line lands in the case's captured
# stdout; on the PowerShell side the child inherits the driver's REAL handle, so
# it lands in the driver's stdout instead - [Console]::SetOut only redirects
# managed writes. Rather than loosening the stdout comparison, the expected
# child line is subtracted from the oracle's stdout and accumulated here, and
# the driver's own stdout is then asserted to be EXACTLY those lines. So the
# child's output is still fully compared, just against a different sink.
LEAK_ALL=''

# Per-case inputs, set by the caller immediately before run_case. Globals rather
# than parameters so a value holding spaces or a leading dash needs no quoting
# gymnastics at 70 call sites.
CASE_BWORLD=''   # POSIX world dir the bash side runs against
CASE_PWORLD=''   # POSIX world dir the PowerShell side runs against
CASE_ENV=''      # newline-separated NAME=VALUE; @W@ becomes the world dir
CASE_FAKEBIN=''  # POSIX fakebin dir to prepend to PATH, or empty
CASE_DIGEST=0    # 1 to compare the two worlds' state trees afterwards
CASE_LEAK=''     # stdout a NESTED firstmate script prints (see LEAK_ALL above)

# run_case <label> <script-basename> [arg...]
# Runs the bash oracle NOW and records the PowerShell case for the single
# driver run. @W@ in an argument or an environment value is replaced with the
# world dir - POSIX form for bash, native form for PowerShell.
run_case() {
  local label=$1 script=$2
  shift 2
  local i=${#LABELS[@]} kv a rec envblock='' pw_native fb_native
  local -a envargs=() bargs=()

  LABELS+=("$label")
  BWORLD+=("$CASE_BWORLD")
  PWORLD+=("$CASE_PWORLD")
  WANT_DIGEST+=("$CASE_DIGEST")

  nat "$CASE_PWORLD"; pw_native=$FM_NAT

  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    envargs+=("${kv//@W@/$CASE_BWORLD}")
    envblock="$envblock${kv//@W@/$pw_native}"$'\n'
  done <<< "$CASE_ENV"

  if [ -n "$CASE_FAKEBIN" ]; then
    nat "$CASE_FAKEBIN"; fb_native=$FM_NAT
    envargs+=("PATH=$CASE_FAKEBIN:$PATH")
    envblock="${envblock}FM_TEST_FAKEBIN=$fb_native"$'\n'
  fi

  for a in "$@"; do bargs+=("${a//@W@/$CASE_BWORLD}"); done

  local errfile="$TMP_ROOT/case.$i.err" out rc err
  out=$(env ${envargs[0]+"${envargs[@]}"} bash "$ROOT/bin/$script.sh" ${bargs[0]+"${bargs[@]}"} 2>"$errfile")
  rc=$?
  err=$(<"$errfile")
  if [ -n "$CASE_LEAK" ]; then
    out=${out#"$CASE_LEAK"$'\n'}
    out=${out#"$CASE_LEAK"}
    LEAK_ALL="$LEAK_ALL$CASE_LEAK"$'\n'
  fi
  BRC+=("$rc")
  norm_stream "$out" "$CASE_BWORLD"; BOUT+=("$FM_NORM")
  norm_stream "$err" "$CASE_BWORLD"; BERR+=("$FM_NORM")

  if [ "$CASE_DIGEST" = 1 ]; then
    tree_digest "$CASE_BWORLD/state" "$CASE_BWORLD"
    BDIGEST+=("$DIGEST")
  else
    BDIGEST+=('')
  fi

  hex_encode "$envblock"
  rec="$script|$FM_HEX"
  for a in "$@"; do
    hex_encode "${a//@W@/$pw_native}"
    rec="$rec|$FM_HEX"
  done
  printf '%s\n' "$rec" >> "$CASES"
}

# =============================================================================
# bin/fm-pr-poll - the byte-static merge poll. Cheap: no state, no lib.
# =============================================================================

POLLW="$TMP_ROOT/poll"
FAKE_POLL="$POLLW/fakebin"
mkdir -p "$POLLW"
make_fakebin "$FAKE_POLL"

GH_URL='https://github.com/octo/repo/pull/12'
GL_URL='https://gitlab.example.com/grp/sub/proj/-/merge_requests/5'

poll_case() {  # <label> <fake-out> <fake-rc> [arg...]
  local label=$1 out=$2 rc=$3
  shift 3
  CASE_BWORLD=$POLLW CASE_PWORLD=$POLLW CASE_DIGEST=0 CASE_LEAK=''
  CASE_FAKEBIN=$FAKE_POLL
  CASE_ENV="FM_FAKE_OUT=$out
FM_FAKE_RC=$rc"
  run_case "$label" fm-pr-poll "$@"
}

poll_case 'poll: no arguments is silent'            MERGED 0
poll_case 'poll: five arguments is silent'          MERGED 0 --validated github "$GH_URL" github.com octo/repo
poll_case 'poll: seven arguments is silent'         MERGED 0 --validated github "$GH_URL" github.com octo/repo 12 extra
poll_case 'poll: first argument must be --validated' MERGED 0 --unvalidated github "$GH_URL" github.com octo/repo 12
poll_case 'poll: github merged wakes'               MERGED 0 --validated github "$GH_URL" github.com octo/repo 12
poll_case 'poll: github open is silent'             OPEN 0 --validated github "$GH_URL" github.com octo/repo 12
poll_case 'poll: a failing gh is silent'            MERGED 1 --validated github "$GH_URL" github.com octo/repo 12
poll_case 'poll: number 0 is refused'               MERGED 0 --validated github 'https://github.com/octo/repo/pull/0' github.com octo/repo 0
poll_case 'poll: number with a letter is refused'   MERGED 0 --validated github 'https://github.com/octo/repo/pull/1a' github.com octo/repo 1a
poll_case 'poll: leading-zero number is refused'    MERGED 0 --validated github 'https://github.com/octo/repo/pull/01' github.com octo/repo 01
poll_case 'poll: github on another host is refused' MERGED 0 --validated github "$GH_URL" example.com octo/repo 12
poll_case 'poll: url that does not reconstruct is refused' MERGED 0 --validated github 'https://github.com/octo/repo/pull/13' github.com octo/repo 12
poll_case 'poll: owner with a double hyphen is refused' MERGED 0 --validated github 'https://github.com/oc--to/repo/pull/12' github.com oc--to/repo 12
poll_case 'poll: owner with a leading hyphen is refused' MERGED 0 --validated github 'https://github.com/-octo/repo/pull/12' github.com -octo/repo 12
poll_case 'poll: repository named .. is refused'    MERGED 0 --validated github 'https://github.com/octo/../pull/12' github.com octo/.. 12
poll_case 'poll: a path with no slash is refused'   MERGED 0 --validated github 'https://github.com/octorepo/pull/12' github.com octorepo 12
poll_case 'poll: an unknown provider is refused'    MERGED 0 --validated bogus "$GH_URL" github.com octo/repo 12
poll_case 'poll: gitlab merged wakes'               merged 0 --validated gitlab "$GL_URL" gitlab.example.com grp/sub/proj 5
poll_case 'poll: gitlab opened is silent'           opened 0 --validated gitlab "$GL_URL" gitlab.example.com grp/sub/proj 5
poll_case 'poll: a failing glab is silent'          merged 1 --validated gitlab "$GL_URL" gitlab.example.com grp/sub/proj 5
poll_case 'poll: gitlab on github.com is refused'   merged 0 --validated gitlab 'https://github.com/grp/proj/-/merge_requests/5' github.com grp/proj 5
poll_case 'poll: a single-segment gitlab path is refused' merged 0 --validated gitlab 'https://gitlab.example.com/proj/-/merge_requests/5' gitlab.example.com proj 5
poll_case 'poll: a gitlab segment ending .git is refused' merged 0 --validated gitlab 'https://gitlab.example.com/grp/proj.git/-/merge_requests/5' gitlab.example.com grp/proj.git 5
poll_case 'poll: a gitlab segment starting - is refused' merged 0 --validated gitlab 'https://gitlab.example.com/grp/-proj/-/merge_requests/5' gitlab.example.com grp/-proj 5
poll_case 'poll: a gitlab .. segment is refused'    merged 0 --validated gitlab 'https://gitlab.example.com/grp/../-/merge_requests/5' gitlab.example.com grp/.. 5
poll_case 'poll: a gitlab host with a doubled dot is refused' merged 0 --validated gitlab 'https://gitlab..example.com/grp/proj/-/merge_requests/5' gitlab..example.com grp/proj 5
poll_case 'poll: an uppercase gitlab host is refused' merged 0 --validated gitlab 'https://GitLab.example.com/grp/proj/-/merge_requests/5' GitLab.example.com grp/proj 5
poll_case 'poll: a gitlab url that does not reconstruct is refused' merged 0 --validated gitlab "$GL_URL" gitlab.example.com grp/sub/proj 6

# =============================================================================
# bin/fm-pr-check - refusals (no state is written on any of these paths)
# =============================================================================

CHKW="$TMP_ROOT/chk"
mkdir -p "$CHKW/wt"
seed_state "$CHKW/state"
printf 'window=w\nworktree=%s/wt\nproject=%s/wt\n' "$CHKW" "$CHKW" > "$CHKW/state/t1.meta"

check_refusal() {  # <label> [arg...]
  local label=$1
  shift
  CASE_BWORLD=$CHKW CASE_PWORLD=$CHKW CASE_DIGEST=0 CASE_FAKEBIN='' CASE_LEAK=''
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
  run_case "$label" fm-pr-check "$@"
}

check_refusal 'pr-check: no arguments'
check_refusal 'pr-check: one argument' t1
check_refusal 'pr-check: three arguments' t1 "$GH_URL" extra
check_refusal 'pr-check: a dotfile task id' .hidden "$GH_URL"
check_refusal 'pr-check: a task id with a slash' a/b "$GH_URL"
check_refusal 'pr-check: a task id with a space' 'a b' "$GH_URL"
check_refusal 'pr-check: an http url' t1 'http://github.com/octo/repo/pull/12'
check_refusal 'pr-check: a url with a trailing newline' t1 "$GH_URL"$'\n'
check_refusal 'pr-check: a url with a trailing slash' t1 "$GH_URL/"
check_refusal 'pr-check: an unknown task' nosuch "$GH_URL"
# Only meaningful where the host genuinely has no glab, and both worlds search
# the same PATH, so bash's answer decides for both.
if ! command -v glab >/dev/null 2>&1; then
  check_refusal 'pr-check: a gitlab url with no glab on PATH' t1 "$GL_URL"
fi

# =============================================================================
# bin/fm-pr-check - the two cases that actually publish artifacts
# =============================================================================

# The stale pr= / pr_head= lines and the FINAL LINE WITH NO NEWLINE are the
# point of this fixture: the twin rewrites the record with `read || [ -n ]` plus
# `printf '%s\n'`, so the unterminated line survives AND gains a terminator,
# and both pr keys are replaced rather than appended to.
arm_world() {  # <world> <id>
  local w=$1 id=$2
  mkdir -p "$w/wt"
  seed_state "$w/state"
  printf 'window=w\nworktree=%s/wt\nproject=%s/wt\npr=https://github.com/old/old/pull/1\npr_head=%s\nharness=claude' \
    "$w" "$w" '0123456789012345678901234567890123456789' > "$w/state/$id.meta"
}

FAKE_ARM="$TMP_ROOT/arm-fakebin"; make_fakebin "$FAKE_ARM"

# gh is FAKED even where the head is not wanted: a real gh on this host would
# otherwise be asked about a pull request that does not exist, over the network,
# and the two worlds would be comparing two different failures.
ARM1B="$TMP_ROOT/arm1b"; ARM1P="$TMP_ROOT/arm1p"
arm_world "$ARM1B" t1; arm_world "$ARM1P" t1
CASE_BWORLD=$ARM1B CASE_PWORLD=$ARM1P CASE_DIGEST=1 CASE_FAKEBIN=$FAKE_ARM CASE_LEAK=''
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_OUT=not-a-head
FM_FAKE_RC=0"
run_case 'pr-check: arms a github poll and rewrites the pr keys' fm-pr-check t1 "$GH_URL"

ARM2B="$TMP_ROOT/arm2b"; ARM2P="$TMP_ROOT/arm2p"
arm_world "$ARM2B" t2; arm_world "$ARM2P" t2
CASE_BWORLD=$ARM2B CASE_PWORLD=$ARM2P CASE_DIGEST=1 CASE_FAKEBIN=$FAKE_ARM CASE_LEAK=''
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_OUT=abcdef0123456789abcdef0123456789abcdef01
FM_FAKE_RC=0"
run_case 'pr-check: records the forge head when gh supplies one' fm-pr-check t2 "$GH_URL"

# =============================================================================
# bin/fm-pr-merge - every refusal is a merge guard
# =============================================================================

MRGW="$TMP_ROOT/mrg"
mkdir -p "$MRGW/wt"
seed_state "$MRGW/state"
printf 'window=w\nworktree=%s/wt\nproject=%s/wt\n' "$MRGW" "$MRGW" > "$MRGW/state/t1.meta"

merge_refusal() {  # <label> [arg...]
  local label=$1
  shift
  CASE_BWORLD=$MRGW CASE_PWORLD=$MRGW CASE_DIGEST=0 CASE_FAKEBIN='' CASE_LEAK=''
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
  run_case "$label" fm-pr-merge "$@"
}

merge_refusal 'pr-merge: no arguments'
merge_refusal 'pr-merge: one argument' t1
merge_refusal 'pr-merge: an unsafe task id' ../evil "$GH_URL"
merge_refusal 'pr-merge: a gitlab merge request is not mergeable here' t1 "$GL_URL"
merge_refusal 'pr-merge: a non-canonical url' t1 'https://github.com/octo/repo/pulls/12'
merge_refusal 'pr-merge: --repo is refused' t1 "$GH_URL" --repo other/repo
merge_refusal 'pr-merge: --repo= is refused' t1 "$GH_URL" --repo=other/repo
merge_refusal 'pr-merge: bare -R is refused' t1 "$GH_URL" -R
merge_refusal 'pr-merge: attached -R is refused' t1 "$GH_URL" -Rother/repo
merge_refusal 'pr-merge: --repo after the -- separator is refused' t1 "$GH_URL" -- --repo other/repo
merge_refusal 'pr-merge: an unknown task' nosuch "$GH_URL"

MRG1B="$TMP_ROOT/mrg1b"; MRG1P="$TMP_ROOT/mrg1p"
arm_world "$MRG1B" t1; arm_world "$MRG1P" t1
FAKE_MRG="$TMP_ROOT/mrg-fakebin"; make_fakebin "$FAKE_MRG"
CASE_BWORLD=$MRG1B CASE_PWORLD=$MRG1P CASE_DIGEST=1 CASE_FAKEBIN=$FAKE_MRG
CASE_LEAK='armed: state/t1.check.sh'
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_OUT=not-a-head
FM_FAKE_RC=0
FM_FAKE_LOG=@W@/ghaxi.log"
run_case 'pr-merge: default method is --squash and the repo comes from the url' fm-pr-merge t1 "$GH_URL"

MRG2B="$TMP_ROOT/mrg2b"; MRG2P="$TMP_ROOT/mrg2p"
arm_world "$MRG2B" t1; arm_world "$MRG2P" t1
CASE_BWORLD=$MRG2B CASE_PWORLD=$MRG2P CASE_DIGEST=1 CASE_FAKEBIN=$FAKE_MRG
CASE_LEAK='armed: state/t1.check.sh'
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_OUT=not-a-head
FM_FAKE_RC=0
FM_FAKE_LOG=@W@/ghaxi.log"
run_case 'pr-merge: an explicit method suppresses --squash' fm-pr-merge t1 "$GH_URL" -- --merge --admin

# =============================================================================
# bin/fm-check-register - the custom-check trust binding
# =============================================================================

CRW="$TMP_ROOT/cr"
seed_state "$CRW/state"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CRW/state/have.check.sh"
chmod 0700 "$CRW/state/have.check.sh"
mkdir -p "$CRW/state/isdir.check.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CRW/state/dirtrust.check.sh"
chmod 0700 "$CRW/state/dirtrust.check.sh"
mkdir -p "$CRW/state/dirtrust.check-trust"

register_refusal() {  # <label> [arg...]
  local label=$1
  shift
  CASE_BWORLD=$CRW CASE_PWORLD=$CRW CASE_DIGEST=0 CASE_FAKEBIN='' CASE_LEAK=''
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
  run_case "$label" fm-check-register "$@"
}

register_refusal 'check-register: no arguments'
register_refusal 'check-register: two arguments' have extra
register_refusal 'check-register: a dotfile task id' .hidden
register_refusal 'check-register: an unknown check' missing
register_refusal 'check-register: a check that is a directory' isdir
register_refusal 'check-register: a trust path that is a directory' dirtrust

REG1B="$TMP_ROOT/reg1b"; REG1P="$TMP_ROOT/reg1p"
for w in "$REG1B" "$REG1P"; do
  seed_state "$w/state"
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n merged\n' > "$w/state/c1.check.sh"
  chmod 0700 "$w/state/c1.check.sh"
done
CASE_BWORLD=$REG1B CASE_PWORLD=$REG1P CASE_DIGEST=1 CASE_FAKEBIN='' CASE_LEAK=''
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
run_case 'check-register: binds a custom check to its exact bytes' fm-check-register c1

# =============================================================================
# bin/fm-review-diff
# =============================================================================

RVW="$TMP_ROOT/rv"
seed_state "$RVW/state"
mkdir -p "$RVW/nowt"
printf 'window=w\n' > "$RVW/state/nokeys.meta"
printf 'window=w\nproject=%s/nowt\n' "$RVW" > "$RVW/state/nowt.meta"
printf 'window=w\nworktree=%s/nowt\n' "$RVW" > "$RVW/state/noproj.meta"
printf 'window=w\nworktree=%s/gone\nproject=%s/nowt\n' "$RVW" "$RVW" > "$RVW/state/gonewt.meta"
printf 'window=w\nworktree=%s/nowt\nproject=%s/gone\n' "$RVW" "$RVW" > "$RVW/state/goneproj.meta"

review_case() {  # <label> [arg...]
  local label=$1
  shift
  CASE_BWORLD=$RVW CASE_PWORLD=$RVW CASE_DIGEST=0 CASE_FAKEBIN='' CASE_LEAK=''
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
  run_case "$label" fm-review-diff "$@"
}

review_case 'review-diff: --help prints usage and succeeds' --help
review_case 'review-diff: -h prints usage and succeeds' -h
review_case 'review-diff: no arguments'
review_case 'review-diff: an unknown flag' nokeys --oops
review_case 'review-diff: three arguments' nokeys --stat extra
review_case 'review-diff: an unknown task' nosuch
review_case 'review-diff: meta with no worktree=' nokeys
review_case 'review-diff: meta with no project=' nowt
review_case 'review-diff: a worktree that is gone' gonewt
review_case 'review-diff: a project that is gone' goneproj

# A real repository per case is a fork storm, so ONE pair is built and shared by
# every read-only review case. Nothing below writes to it: with no origin there
# is no fetch, and `git diff` never mutates.
fm_git_identity
build_review_repo() {  # <world>
  local w=$1
  fm_git_init_commit "$w/proj"
  git -C "$w/proj" worktree add --quiet -b fm/r1 "$w/wt1"
  printf 'changed\n' > "$w/wt1/README.md"
  git -C "$w/wt1" add README.md
  git -C "$w/wt1" -c user.name=t -c user.email=t@x commit -qm change
  git -C "$w/proj" worktree add --quiet -b other "$w/wt2"
  seed_state "$w/state"
  printf 'window=w\nworktree=%s/wt1\nproject=%s/proj\n' "$w" "$w" > "$w/state/r1.meta"
  printf 'window=w\nworktree=%s/wt2\nproject=%s/proj\n' "$w" "$w" > "$w/state/r2.meta"
  printf 'window=w\nworktree=%s/wt1\nproject=%s/proj\npr=https://github.com/o/r/pull/9\n' "$w" "$w" \
    > "$w/state/r3.meta"
}
RVGB="$TMP_ROOT/rvgb"; RVGP="$TMP_ROOT/rvgp"
build_review_repo "$RVGB"
build_review_repo "$RVGP"

git_review_case() {  # <label> [arg...]
  local label=$1
  shift
  CASE_BWORLD=$RVGB CASE_PWORLD=$RVGP CASE_DIGEST=0 CASE_FAKEBIN='' CASE_LEAK=''
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT"
  run_case "$label" fm-review-diff "$@"
}

git_review_case 'review-diff: a local branch diff' r1
git_review_case 'review-diff: --stat prints only the summary' r1 --stat
git_review_case 'review-diff: an unchanged branch reports no changes' r2
git_review_case 'review-diff: an unreachable PR head warns and uses the local branch' r3

# =============================================================================
# The PowerShell driver - one process, every case
# =============================================================================
# Quoted here-doc: bash expands nothing, so the PowerShell source is byte-exact.
# Paths arrive through the environment rather than through interpolation, which
# keeps every quoting hazard out of the file.
cat > "$DRIVER" <<'PS1'
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$bin = $env:FM_BIN
$basePath = $env:PATH
$records = [System.Text.StringBuilder]::new()
$index = -1

foreach ($line in [System.IO.File]::ReadAllLines($env:FM_CASES)) {
    if ($line -eq '') { continue }
    $index++
    $fields = @($line.Split('|'))
    $script = $fields[0]
    $entry = Join-Path $bin "$script.ps1"

    $applied = @{}
    $rc = -1
    $stdout = ''
    $stderr = ''
    $savedOut = [Console]::Out
    $savedErr = [Console]::Error
    try {
        # Environment first, and recorded so it can be removed again: a value
        # left behind would evaluate every later case against this one's setting.
        $envBlock = ConvertFrom-FmHex -Hex $fields[1]
        foreach ($entryLine in $envBlock.Split("`n")) {
            if ($entryLine -eq '') { continue }
            $eq = $entryLine.IndexOf('=')
            if ($eq -lt 1) { continue }
            $name = $entryLine.Substring(0, $eq)
            $value = $entryLine.Substring($eq + 1)
            if (-not $applied.ContainsKey($name)) {
                $applied[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            if ($name -eq 'FM_TEST_FAKEBIN') {
                $env:PATH = $value + ';' + $basePath
                continue
            }
            [Environment]::SetEnvironmentVariable($name, $value)
        }

        $callArgs = @()
        for ($i = 2; $i -lt $fields.Length; $i++) {
            $callArgs += (ConvertFrom-FmHex -Hex $fields[$i])
        }

        $outWriter = [System.IO.StringWriter]::new()
        $errWriter = [System.IO.StringWriter]::new()
        [Console]::SetOut($outWriter)
        [Console]::SetError($errWriter)
        try {
            $global:LASTEXITCODE = 0
            & $entry @callArgs
            $rc = $LASTEXITCODE
        } catch {
            $rc = "THREW:$($_.Exception.Message)"
        } finally {
            [Console]::SetOut($savedOut)
            [Console]::SetError($savedErr)
            $stdout = $outWriter.ToString()
            $stderr = $errWriter.ToString()
        }
    } catch {
        $rc = "HARNESS:$($_.Exception.Message)"
    } finally {
        [Console]::SetOut($savedOut)
        [Console]::SetError($savedErr)
        $env:PATH = $basePath
        foreach ($name in $applied.Keys) {
            [Environment]::SetEnvironmentVariable($name, $applied[$name])
        }
    }

    # $( ) in bash strips every trailing newline; the oracle's captures are
    # spelled that way, so the same trimming is applied here.
    $stdout = $stdout -replace "`r", ''
    $stderr = $stderr -replace "`r", ''
    [void]$records.Append($index).Append('|').Append($rc).Append('|').
        Append((ConvertTo-FmHex -Text $stdout.TrimEnd("`n"))).Append('|').
        Append((ConvertTo-FmHex -Text $stderr.TrimEnd("`n"))).Append("`n")
}

[System.IO.File]::WriteAllText($env:FM_RESULTS, $records.ToString(),
    [System.Text.UTF8Encoding]::new($false))
PS1

BIN_N=$(fm_test_native_path "$ROOT/bin")
if ! FM_BIN="$BIN_N" FM_CASES="$CASES_N" FM_RESULTS="$RESULTS_N" \
  pwsh -NoProfile -File "$DRIVER_N" > "$DRIVER_OUT" 2> "$DRIVER_ERR"; then
  fail "the PowerShell case driver exited non-zero:"$'\n'"$(cat "$DRIVER_ERR")"
fi
# A child process inherits the REAL console handle rather than the swapped
# writer, so the driver's own stdout holds exactly the lines nested firstmate
# scripts printed - no more and no less. Asserting it against LEAK_ALL is what
# keeps the subtraction in run_case honest: an unexpected extra line, or a
# missing one, fails here rather than silently vanishing from the comparison.
assert_case 'nested scripts printed exactly the expected lines' \
  "$LEAK_ALL" "$(cat "$DRIVER_OUT")"$'\n'
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr:"$'\n'"$(cat "$DRIVER_ERR")"

SEEN=0
while IFS='|' read -r idx rc outhex errhex; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$idx" -lt "${#LABELS[@]}" ] || fail "driver returned an out-of-range case index: $idx"
  label=${LABELS[$idx]}
  assert_case "$label [exit code]" "${BRC[$idx]}" "$rc"
  hex_decode "$outhex"; norm_stream "$FM_UNHEX" "${PWORLD[$idx]}"
  assert_case "$label [stdout]" "${BOUT[$idx]}" "$FM_NORM"
  hex_decode "$errhex"; norm_stream "$FM_UNHEX" "${PWORLD[$idx]}"
  assert_case "$label [stderr]" "${BERR[$idx]}" "$FM_NORM"
  if [ "${WANT_DIGEST[$idx]}" = 1 ]; then
    tree_digest "${PWORLD[$idx]}/state" "${PWORLD[$idx]}"
    assert_case "$label [state tree]" "${BDIGEST[$idx]}" "$DIGEST"
  fi
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] || fail "driver returned $SEEN results for ${#LABELS[@]} cases"

# The merge argv is the whole point of fm-pr-merge, so it is compared directly
# rather than inferred from an exit code. CR is stripped because the PowerShell
# side reaches the fake through a cmd shim whose `echo` writes CRLF - a property
# of the fake, not of either script.
for pair in "$MRG1B $MRG1P default-squash" "$MRG2B $MRG2P explicit-method"; do
  set -- $pair
  b=$(tr -d '\r' < "$1/ghaxi.log" 2>/dev/null)
  p=$(tr -d '\r' < "$2/ghaxi.log" 2>/dev/null)
  assert_case "pr-merge: gh-axi argv ($3)" "$b" "$p"
  [ -n "$b" ] || fail "the bash oracle never invoked gh-axi for the $3 case"
done

# The published check must be the SHIPPED TEMPLATE, byte for byte, in both
# worlds - that identity is what bin/fm-watch.sh re-verifies before polling, and
# it is why bin/fm-pr-check.ps1 arms with fm-pr-poll.sh rather than its own .ps1.
for w in "$ARM1B" "$ARM1P" "$ARM2B" "$ARM2P"; do
  cmp -s "$ROOT/bin/fm-pr-poll.sh" "$w/state"/*.check.sh \
    || fail "the armed check in $w is not byte-identical to bin/fm-pr-poll.sh"
  ASSERTIONS=$((ASSERTIONS + 1))
done

# No separate parse/import-hygiene phase: the driver already ran all five
# entrypoints in ONE session, so a parse error, a bad module import or a
# -Force import that removed a caller's fm-common would have surfaced as a
# THREW result above. A second pwsh spawn per file would cost ~25s to re-prove
# what the batch already proved.

# =============================================================================
# Report
# =============================================================================

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell PR entrypoints differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The floor is taken from an OBSERVED green run.
MIN_ASSERTIONS=1
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the PowerShell PR entrypoints match their bash oracles across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-pr-psm1.test.sh: all assertions passed\n'
