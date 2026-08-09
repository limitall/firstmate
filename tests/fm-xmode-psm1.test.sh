#!/usr/bin/env bash
# tests/fm-xmode-psm1.test.sh - ONE differential behavior test for the six
# PowerShell X-mode / public-followup entrypoints:
#
#   bin/fm-x-poll.ps1        bin/fm-x-reply.ps1      bin/fm-x-link.ps1
#   bin/fm-x-dismiss.ps1     bin/fm-x-followup.ps1   bin/fm-public-followup.ps1
#
# BASH IS THE ORACLE. Every case drives the .sh original and its .ps1 twin with
# byte-identical argv, environment and FIXTURE, then compares exit code, stdout,
# stderr and - for the cases that write - the whole resulting state tree. No
# verdict is hard-coded, so a case can never quietly encode what the author
# believed instead of what the shipped script does.
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE IS WORTH ITS RUNTIME
#
# These six scripts are the only ones in the tree that can post something a
# stranger can read. Two properties therefore carry more weight than everything
# else here, and both are tested first and hardest:
#
#   1. X MODE SHIPS INERT. With no FMX_PAIRING_TOKEN, every one of these must be
#      a hard no-op or a refusal - never a post, never a file. An accidental
#      activation is externally visible and irreversible, so the inertness cases
#      cover an absent .env, a present-but-tokenless .env, an explicitly EMPTY
#      token, and a home that already holds pending work to surface.
#   2. fm-x-reply's EXIT 8 IS A RETRYABLE HOLD, not a failure. When the reply
#      platform or size budget cannot be authoritatively resolved it refuses
#      rather than posting on a locally defaulted budget, and fm-x-followup must
#      KEEP the link on 8 while CLEARING it on 9. Both codes and both link
#      outcomes are asserted.
#
# ---------------------------------------------------------------------------
# HOW THE TWO SIDES ARE RUN
#
# A bare `pwsh -NoProfile -Command "exit 0"` costs 4.8s on the reference host, so
# a suite that spawns pwsh per case does not finish (docs/powershell-port.md owns
# that measurement). This suite spawns pwsh EXACTLY ONCE: bash writes every case
# to a file and one driver runs all of them IN PROCESS with `& script.ps1`. The
# two mechanics that make that work are the ones tests/fm-pr-psm1.test.sh
# verified first: `exit N` inside a script invoked with `&` ends that SCRIPT and
# leaves N in $LASTEXITCODE, and [Console]::SetOut/SetError capture what
# Write-FmOut writes through the raw console writer.
#
# CHILD PROCESS OUTPUT CANNOT BE CAPTURED THAT WAY, because a child inherits the
# real handle. The driver's own stdout is therefore asserted EMPTY - any leakage
# is a loud failure rather than a corrupted record.
#
# TRANSPORT. Every value crosses hex-encoded under LC_ALL=C, and cases are keyed
# by INDEX, never by a path: the two worlds spell the same location differently
# and a path key would read as MISSING for every case even when the values agree.
# Per-case environment travels in the case RECORD and is applied and cleared per
# case on the PowerShell side, because a bash prefix assignment would persist and
# leave the single pwsh run holding only the last value.
#
# ---------------------------------------------------------------------------
# THE FAKES, AND THE ONE THING THAT CANNOT BE FAKED
#
# NO NETWORK PATH RUNS HERE. curl is faked as a PAIR - a bash script for the
# oracle and a .cmd shim for PowerShell - because Windows CreateProcess resolves
# a bare name only through .exe and would otherwise reach the real system curl.
# bin/fm-x-poll.ps1 and bin/fm-x-dismiss.ps1 resolve curl through Get-Command
# precisely so the shim is reachable. tasks-axi is faked the same way.
#
# THE ONE EXCEPTION, STATED RATHER THAN HIDDEN: fm-x-lib.psm1's Send-FmxJson
# invokes curl by BARE NAME, so the PowerShell side of a LIVE POST cannot be
# pointed at a fake. Rather than loosen anything, this suite drives the live-post
# surface only where no post can happen:
#   - every dry-run path (network-free by contract) is covered in full;
#   - the exit-8 fail-safe is covered in both variants, and the variant that
#     consults the relay pins FMX_RELAY_URL at http://127.0.0.1:1 with NO fake on
#     PATH, so BOTH worlds run the same real curl against the loopback discard
#     port, it is refused instantly, and nothing leaves the machine.
# The 2xx and 409 mappings inside fm-x-reply's live POST are therefore NOT
# differentially covered here; tests/fm-x-lib-psm1.test.sh owns Send-FmxJson's
# own contract, and this is recorded as a known gap rather than a passed check.
#
# ---------------------------------------------------------------------------
# WHAT IS NORMALIZED, AND WHY EACH NORMALIZATION IS SAFE
#
#   1. `accepted <rfc3339>` in the consumed-event ledger is a wall-clock stamp
#      taken twice; the LINE is compared, the timestamp is not. Every other
#      timestamp in the trees is pinned with FMX_NOW_OVERRIDE and IS compared.
#   2. mktemp-style scratch names (*.fm-x.*, *.fm-tmp.*) carry a random suffix.
#      Their PRESENCE is compared - a leftover temp is a real failure - and the
#      suffix is not.
#   3. bin/fm-public-followup.sh's --help says "Requires jq and a compatible
#      tasks-axi"; the PowerShell twin needs no jq and says so. That ONE sentence
#      is elided from both sides before comparison and the rest of the help is
#      compared byte-for-byte.
#   4. PATH SPELLINGS in stdout/stderr. Several of these scripts echo a path they
#      were handed, and the two worlds spell the same location differently
#      (/tmp/x vs C:\...\Temp\x vs /c/Users/.../Temp/x). Both sides therefore get
#      the same rewrite: every backslash becomes a forward slash and the temp
#      root in any of its three spellings becomes <T>. The path STRUCTURE after
#      the root is still compared exactly, so a script that echoed the wrong file
#      still fails.
#   5. `cat: ...` lines, which only the ORACLE can emit: bash reads a reply text
#      file with cat, so cat speaks for itself on a missing file, while the twin
#      reads it in-process and has only its own diagnostic. The twin's own line
#      is compared; cat's is dropped.
# Nothing else is normalized. Exit codes, and every durable record in the state
# trees, are compared byte-for-byte with no rewriting at all.
#
# Skips cleanly where pwsh or jq is absent, so the suite stays green on hosts
# that have neither.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the bash oracle needs it)"; exit 0; }

for f in fm-x-poll fm-x-reply fm-x-link fm-x-dismiss fm-x-followup fm-public-followup; do
  [ -f "$ROOT/bin/$f.ps1" ] || fail "bin/$f.ps1 is missing"
  [ -f "$ROOT/bin/$f.sh" ] || fail "bin/$f.sh (the oracle) is missing"
done

# The two separators as VARIABLES, because `${v//\//}` does not mean what it
# looks like: bash parses it as "delete every forward slash" (verified on this
# host). Every separator swap below goes through these quoted names instead.
FM_BS='\'
FM_FS='/'

TMP_ROOT=$(fm_test_tmproot fm-xmode-ps1)
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
# LC_ALL=C makes ${v:i:1} a BYTE, so what crosses is the exact byte sequence bash
# held. %04x then the low two digits, because bash renders a byte >= 0x80 as a
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

# --- fakes -------------------------------------------------------------------
#
# Each tool exists TWICE: a bash script for the oracle and a .cmd shim for
# PowerShell. curl's argv is fixed by both callers (-m N -s -o <file> -w ...), so
# the body destination is positional parameter 5 in either shell.
make_fakebin() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'out=$5\n'
    printf 'if [ -n "${FM_FAKE_BODY:-}" ] && [ "$out" != /dev/null ] && [ "$out" != NUL ]; then\n'
    printf '  cp "$FM_FAKE_BODY" "$out" 2>/dev/null || true\n'
    printf 'fi\n'
    printf 'printf %%s "${FM_FAKE_CODE:-200}"\n'
    printf 'exit "${FM_FAKE_CURL_RC:-0}"\n'
  } > "$dir/curl"
  chmod +x "$dir/curl"
  {
    printf '@echo off\r\n'
    printf 'if "%%FM_FAKE_BODY%%"=="" goto code\r\n'
    printf 'if "%%~5"=="NUL" goto code\r\n'
    printf 'if "%%~5"=="/dev/null" goto code\r\n'
    printf 'copy /y "%%FM_FAKE_BODY%%" "%%~5" >nul\r\n'
    printf ':code\r\n'
    printf '<nul set /p=%%FM_FAKE_CODE%%\r\n'
    printf 'exit %%FM_FAKE_CURL_RC%%\r\n'
  } > "$dir/curl.cmd"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${2:-}" = list ]; then\n'
    printf '  [ -z "${FM_TASKS_LIST:-}" ] || cat "$FM_TASKS_LIST"\n'
    printf '  exit "${FM_TASKS_LIST_RC:-0}"\n'
    printf 'fi\n'
    printf '[ -z "${FM_TASKS_RESP:-}" ] || cat "$FM_TASKS_RESP"\n'
    printf 'exit "${FM_TASKS_RC:-0}"\n'
  } > "$dir/tasks-axi"
  chmod +x "$dir/tasks-axi"
  {
    printf '@echo off\r\n'
    printf 'if "%%~2"=="list" goto list\r\n'
    printf 'if not "%%FM_TASKS_RESP%%"=="" type "%%FM_TASKS_RESP%%"\r\n'
    printf 'exit %%FM_TASKS_RC%%\r\n'
    printf ':list\r\n'
    printf 'if not "%%FM_TASKS_LIST%%"=="" type "%%FM_TASKS_LIST%%"\r\n'
    printf 'exit %%FM_TASKS_LIST_RC%%\r\n'
  } > "$dir/tasks-axi.cmd"
}

# The sibling scripts a case must NOT really run. Only the .sh exists,
# DELIBERATELY: Invoke-FmScript prefers a .ps1 twin and a nested pwsh would cost
# a 4.8s startup per case, while the bash fallback is the branch every
# unconverted execute edge takes today. The fake prints a FIXED line rather than
# its argv, because the argv carries world-specific paths.
FAKEROOT="$TMP_ROOT/fakeroot"
mkdir -p "$FAKEROOT/bin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "fake fm-x-reply invoked\\n" >&2\n'
  printf 'receipt=\n'
  printf 'while [ "$#" -gt 0 ]; do\n'
  printf '  case "$1" in --receipt-file) shift; receipt=${1:-} ;; esac\n'
  printf '  shift\n'
  printf 'done\n'
  printf 'if [ -n "$receipt" ] && [ -n "${FM_FAKE_RECEIPT:-}" ]; then\n'
  printf '  cat "$FM_FAKE_RECEIPT" > "$receipt"\n'
  printf 'fi\n'
  printf 'exit "${FM_FAKE_REPLY_RC:-0}"\n'
} > "$FAKEROOT/bin/fm-x-reply.sh"
chmod +x "$FAKEROOT/bin/fm-x-reply.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'exit "${FM_FAKE_FOLLOWUP_RC:-0}"\n'
} > "$FAKEROOT/bin/fm-x-followup.sh"
chmod +x "$FAKEROOT/bin/fm-x-followup.sh"

FAKEBIN="$TMP_ROOT/fakebin"
make_fakebin "$FAKEBIN"

# --- state-tree digest -------------------------------------------------------
#
# Recursive and builtin-only (no fork per file): the oracle side is fork-bound
# and this runs for every world of every writing case. See the normalization note
# in the header for what each rewrite covers and why it is safe.
DIGEST=
tree_digest() {
  DIGEST=''
  digest_dir "$1" ''
}
digest_dir() {
  local d=$1 prefix=$2 f name line body
  for f in "$d"/* "$d"/.*; do
    name=${f##*/}
    case $name in .|..|'*'|'.*') continue ;; esac
    [ -e "$f" ] || continue
    if [ -d "$f" ]; then
      DIGEST="${DIGEST}dir ${prefix}${name}/"$'\n'
      digest_dir "$f" "${prefix}${name}/"
      continue
    fi
    case $name in
      *.fm-x.*|*.fm-tmp.*) DIGEST="${DIGEST}scratch ${prefix}"$'\n'; continue ;;
    esac
    body=''
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
        'accepted '*) line='accepted <ts>' ;;
      esac
      body="$body$line"$'\n'
    done < "$f"
    DIGEST="${DIGEST}--- ${prefix}${name}"$'\n'"$body"
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
WANT_DIGEST=()
BDIGEST=()

# Per-case inputs, set by the caller immediately before run_case. Globals rather
# than parameters so a value holding spaces or a leading dash needs no quoting
# gymnastics at every call site.
CASE_BWORLD=''   # POSIX world dir the bash side runs against
CASE_ENV=''      # newline-separated NAME=VALUE; @W@ becomes the world dir
CASE_FAKEBIN=''  # POSIX fakebin dir to prepend to PATH, or empty
CASE_DIGEST=0    # 1 to compare the two worlds' state trees afterwards

# run_case <label> <script-basename> [arg...]
# Runs the bash oracle NOW and records the PowerShell case for the single driver
# run. @W@ in an argument or an environment value is replaced with the world dir
# - POSIX form for bash, native form for PowerShell.
run_case() {
  local label=$1 script=$2
  shift 2
  local i=${#LABELS[@]} kv a pa pv rec envblock='' pw_native fb_native
  local CASE_PWORLD=''
  local -a envargs=() bargs=()

  LABELS+=("$label")
  # THE WORLD-PAIR CONVENTION, and why it is derived rather than passed: the
  # per-case environment is baked into the case RECORD at this moment, in the
  # PowerShell world's own spelling, so a case that names the wrong world would
  # silently run BOTH sides against the bash tree and every digest would agree
  # for the wrong reason. A mutating fixture is therefore always built as the
  # pair <name>-b / <name>-p, and this one line is the only place that mapping
  # lives. A read-only world (any name not ending in -b) is shared by both.
  case $CASE_BWORLD in
    *-b) CASE_PWORLD="${CASE_BWORLD%-b}-p" ;;
    *) CASE_PWORLD=$CASE_BWORLD ;;
  esac
  PWORLD+=("$CASE_PWORLD")
  WANT_DIGEST+=("$CASE_DIGEST")

  nat "$CASE_PWORLD"; pw_native=$FM_NAT

  # A @W@ value is always a PATH, and on the PowerShell side several are handed
  # to a .cmd shim. cmd.exe cannot read "C:\dir/sub/file" - a forward slash there
  # reads as a switch introducer and `type`/`copy` answer "The system cannot find
  # the file specified" - so the separators are unified after substitution. This
  # cost a whole suite run: every fake looked broken while the scripts were fine.
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    envargs+=("${kv//@W@/$CASE_BWORLD}")
    pv=${kv//@W@/$pw_native}
    case $kv in *=@W@*) pv=${pv//"$FM_FS"/"$FM_BS"} ;; esac
    envblock="$envblock$pv"$'\n'
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
  BRC+=("$rc")
  BOUT+=("$out")
  BERR+=("$err")

  if [ "$CASE_DIGEST" = 1 ]; then
    tree_digest "$CASE_BWORLD/state"
    BDIGEST+=("$DIGEST")
  else
    BDIGEST+=('')
  fi

  hex_encode "$envblock"
  rec="$script|$FM_HEX"
  for a in "$@"; do
    pa=${a//@W@/$pw_native}
    case $a in *@W@*) pa=${pa//"$FM_FS"/"$FM_BS"} ;; esac
    hex_encode "$pa"
    rec="$rec|$FM_HEX"
  done
  printf '%s\n' "$rec" >> "$CASES"
}

# --- output normalization ----------------------------------------------------
#
# Two worlds spell the same location differently, and several of these scripts
# ECHO a path they were handed. Comparing raw spellings would fail for the wrong
# reason, so the rule is declared once and applied to both sides identically:
# every backslash becomes a forward slash, the temp root in any of its three
# spellings becomes <T>, and a `cat:` diagnostic - which only the oracle can
# emit, because the twin reads the file in-process and has no external tool to
# speak for it - is dropped. Nothing else is touched.
TMP_ROOT_FN=${TMP_ROOT_N//"$FM_BS"/"$FM_FS"}
FM_DRIVE=${TMP_ROOT_FN%%:*}
FM_DRIVE=$(printf '%s' "$FM_DRIVE" | tr 'A-Z' 'a-z')
TMP_ROOT_P="/$FM_DRIVE${TMP_ROOT_FN#*:}"

FM_NORM=
normalize_out() {  # <text> -> FM_NORM
  local t=$1 line out=''
  t=${t//"$FM_BS"/"$FM_FS"}
  t=${t//"$TMP_ROOT_FN"/<T>}
  t=${t//"$TMP_ROOT_P"/<T>}
  t=${t//"$TMP_ROOT"/<T>}
  while IFS= read -r line; do
    case $line in 'cat: '*) continue ;; esac
    out="$out$line"$'
'
  done <<< "$t"
  FM_NORM=${out%$'
'}
}

# --- fixture builders --------------------------------------------------------

# A home with X mode ON. FMX_NOW_OVERRIDE pins every recorded timestamp, so two
# worlds writing the same record produce the same bytes.
NOW=1700000000

seed_home() {  # <world> [token]
  local w=$1 token=${2-fake-token}
  mkdir -p "$w/state"
  if [ -n "$token" ]; then
    printf 'FMX_PAIRING_TOKEN=%s\nFMX_RELAY_URL=https://relay.invalid\n' "$token" > "$w/.env"
  fi
}

seed_context() {  # <world> <request> <platform> <max>
  local w=$1
  mkdir -p "$w/state/x-context"
  chmod 700 "$w/state/x-context"
  jq -cn --arg r "$2" --arg p "$3" --arg m "$4" --argjson t "$NOW" \
    '{request_id:$r, platform:$p, reply_max_chars:$m, recorded_at:$t}' \
    > "$w/state/x-context/$2.json"
  chmod 600 "$w/state/x-context/$2.json"
}

seed_meta() {  # <world> <id> <extra-lines...>
  local w=$1 id=$2
  shift 2
  mkdir -p "$w/state"
  {
    printf 'window=firstmate:%s\nharness=claude\n' "$id"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$w/state/$id.meta"
}

seed_registration() {  # <world> <obligation> <work-home> <work-id> [platform] [request]
  local w=$1 id=$2 home=$3 work=$4 platform=${5:-x} request=${6:-req-1}
  mkdir -p "$w/state/public-followup/registry"
  chmod 700 "$w/state/public-followup" "$w/state/public-followup/registry"
  printf 'obligation_id=%s\nrelation_id=rel-1\nwork_home=%s\nwork_id=%s\ngeneration=1\nplatform=%s\nrequest_id=%s\n' \
    "$id" "$home" "$work" "$platform" "$request" > "$w/state/public-followup/registry/$id"
  chmod 600 "$w/state/public-followup/registry/$id"
}

# =============================================================================
# 1. INERTNESS - the safety property. No token anywhere: nothing may post, and
#    nothing may be written.
# =============================================================================

INERT_B="$TMP_ROOT/inert-b"; INERT_P="$TMP_ROOT/inert-p"
for w in "$INERT_B" "$INERT_P"; do
  seed_home "$w" ''
  mkdir -p "$w/state/public-followup/events"
  chmod 700 "$w/state/public-followup" "$w/state/public-followup/events"
  printf '{"event_id":"ev-1"}\n' > "$w/state/public-followup/events/ev-1.json"
  chmod 600 "$w/state/public-followup/events/ev-1.json"
done
CASE_BWORLD=$INERT_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'inert: poll with no .env writes nothing and says nothing' fm-x-poll

# A .env that exists but carries no token, and one that sets it EMPTY, are both
# "off" - the two shapes a half-configured home actually takes.
INERT2_B="$TMP_ROOT/inert2-b"; INERT2_P="$TMP_ROOT/inert2-p"
for w in "$INERT2_B" "$INERT2_P"; do
  seed_home "$w" ''
  printf 'FMX_RELAY_URL=https://relay.invalid\nFMX_PAIRING_TOKEN=\n' > "$w/.env"
done
CASE_BWORLD=$INERT2_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'inert: poll with an empty token in .env stays a no-op' fm-x-poll

INERT_RO="$TMP_ROOT/inert-ro"
seed_home "$INERT_RO" ''
seed_meta "$INERT_RO" t1
seed_registration "$INERT_RO" ob-1 main t1

inert_case() {  # <label> <script> [arg...]
  local label=$1 script=$2
  shift 2
  CASE_BWORLD=$INERT_RO CASE_DIGEST=0 CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0
FM_TASKS_RC=0
FM_TASKS_LIST_RC=0"
  run_case "$label" "$script" "$@"
}

inert_case 'inert: reply refuses a live post with no token'   fm-x-reply req-1 'hello there'
inert_case 'inert: dismiss refuses with no token'             fm-x-dismiss req-1
inert_case 'inert: public-followup active reports inactive'   fm-public-followup active
inert_case 'inert: public-followup consume is silent'         fm-public-followup consume
inert_case 'inert: public-followup pending is silent'         fm-public-followup pending
inert_case 'inert: public-followup guard-work is silent'      fm-public-followup guard-work main t1
inert_case 'inert: public-followup retire is silent'          fm-public-followup retire ob-1
inert_case 'inert: public-followup brief refuses'             fm-public-followup brief ob-1
inert_case 'inert: public-followup register refuses'          fm-public-followup register ob-1 --relation rel-1 --work-home main --work-id t1 --generation 1
inert_case 'inert: public-followup deliver refuses'           fm-public-followup deliver ob-1
inert_case 'inert: public-followup record-posted refuses'     fm-public-followup record-posted ob-1 --attempt 1 --chunks 1

# =============================================================================
# 2. bin/fm-x-poll - the relay short poll
# =============================================================================

POLL_RO="$TMP_ROOT/poll-ro"
seed_home "$POLL_RO"
mkdir -p "$POLL_RO/bodies"
printf '' > "$POLL_RO/bodies/empty.json"
printf '{not json\n' > "$POLL_RO/bodies/malformed.json"
jq -cn '{text:"hello"}' > "$POLL_RO/bodies/norequest.json"
jq -cn '{request_id:"req-1", text:"   "}' > "$POLL_RO/bodies/emptytext.json"
jq -cn '{request_id:"../evil", text:"hi"}' > "$POLL_RO/bodies/unsafeid.json"
jq -n '{request_id:"req-1", text:"  Ahoy   captain  ", platform:"discord", reply_max_chars:1900, in_reply_to:null}' \
  > "$POLL_RO/bodies/good.json"

poll_case() {  # <label> <world> <code> <body-or-empty> <digest>
  local label=$1 world=$2 code=$3 body=$4 digest=$5
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=$code
FM_FAKE_CURL_RC=0
FM_FAKE_BODY=$body"
  run_case "$label" fm-x-poll
}

poll_case 'poll: HTTP 204 is silent'              "$POLL_RO" 204 '' 0
poll_case 'poll: HTTP 500 is silent'              "$POLL_RO" 500 '' 0
poll_case 'poll: an empty 200 body is silent'     "$POLL_RO" 200 '@W@/bodies/empty.json' 0
poll_case 'poll: a malformed 200 body is silent'  "$POLL_RO" 200 '@W@/bodies/malformed.json' 0
poll_case 'poll: a 200 with no request_id is silent' "$POLL_RO" 200 '@W@/bodies/norequest.json' 0
poll_case 'poll: a 200 with blank text is silent' "$POLL_RO" 200 '@W@/bodies/emptytext.json' 0
poll_case 'poll: an unsafe request_id is silent'  "$POLL_RO" 200 '@W@/bodies/unsafeid.json' 0

# The error diagnostic is rate-limited: the first 401 wakes firstmate, an
# identical second one does not, and a 204 clears the record.
POLLERR_B="$TMP_ROOT/pollerr-b"; POLLERR_P="$TMP_ROOT/pollerr-p"
for w in "$POLLERR_B" "$POLLERR_P"; do seed_home "$w"; done
CASE_BWORLD=$POLLERR_B CASE_DIGEST=0 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=401
FM_FAKE_CURL_RC=0"
run_case 'poll: HTTP 401 reports once and records the diagnostic' fm-x-poll
# Intermediate cases in a sequence carry no digest: the PowerShell tree is read
# only after EVERY case has run, so only the last case against a world can have
# its tree compared.
CASE_BWORLD=$POLLERR_B CASE_DIGEST=0 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=401
FM_FAKE_CURL_RC=0"
run_case 'poll: the same HTTP 401 does not wake firstmate twice' fm-x-poll
CASE_BWORLD=$POLLERR_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=204
FM_FAKE_CURL_RC=0"
run_case 'poll: a later 204 clears the recorded diagnostic' fm-x-poll

POLLERR2_B="$TMP_ROOT/pollerr2-b"; POLLERR2_P="$TMP_ROOT/pollerr2-p"
for w in "$POLLERR2_B" "$POLLERR2_P"; do seed_home "$w"; done
CASE_BWORLD=$POLLERR2_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=403
FM_FAKE_CURL_RC=0"
run_case 'poll: the recorded diagnostic is byte-identical in both worlds' fm-x-poll

# A transport failure is "no wake this cycle", never a diagnostic.
CASE_BWORLD=$POLL_RO CASE_DIGEST=0 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=000
FM_FAKE_CURL_RC=7"
run_case 'poll: a curl transport failure is silent' fm-x-poll

# The whole offer path: stash, context record, one-wake claim, and the silent
# re-offer that must not recreate a drained inbox.
POLLOK_B="$TMP_ROOT/pollok-b"; POLLOK_P="$TMP_ROOT/pollok-p"
for w in "$POLLOK_B" "$POLLOK_P"; do
  seed_home "$w"
  mkdir -p "$w/bodies"
  cp "$POLL_RO/bodies/good.json" "$w/bodies/good.json"
done
poll_case 'poll: a fresh mention stashes it and prints one wake line' "$POLLOK_B" 200 '@W@/bodies/good.json' 0
CASE_BWORLD=$POLLOK_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0
FM_FAKE_BODY=@W@/bodies/good.json"
run_case 'poll: an already offered mention is silent' fm-x-poll

# The public-followup surfacing line rides on this poll, once per new event set.
POLLPF_B="$TMP_ROOT/pollpf-b"; POLLPF_P="$TMP_ROOT/pollpf-p"
for w in "$POLLPF_B" "$POLLPF_P"; do
  seed_home "$w"
  mkdir -p "$w/state/public-followup/events"
  chmod 700 "$w/state/public-followup" "$w/state/public-followup/events"
  printf '{"event_id":"ev-1"}\n' > "$w/state/public-followup/events/ev-1.json"
  chmod 600 "$w/state/public-followup/events/ev-1.json"
done
poll_case 'poll: a new terminal-result set is surfaced once' "$POLLPF_B" 204 '' 0
poll_case 'poll: the same terminal-result set is not surfaced again' "$POLLPF_B" 204 '' 1

# =============================================================================
# 3. bin/fm-x-dismiss
# =============================================================================

DISMISS_RO="$TMP_ROOT/dismiss-ro"
seed_home "$DISMISS_RO"

dismiss_case() {  # <label> <world> <code> <digest> <extra-env> [arg...]
  local label=$1 world=$2 code=$3 digest=$4 extra=$5
  shift 5
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=$code
FM_FAKE_CURL_RC=0$extra"
  run_case "$label" fm-x-dismiss "$@"
}

dismiss_case 'dismiss: no arguments'        "$DISMISS_RO" 200 0 ''
dismiss_case 'dismiss: two arguments'       "$DISMISS_RO" 200 0 '' req-1 extra
dismiss_case 'dismiss: an unsafe id'        "$DISMISS_RO" 200 0 '' ../evil
dismiss_case 'dismiss: a dotfile id'        "$DISMISS_RO" 200 0 '' .hidden
dismiss_case 'dismiss: a relay 500 fails'   "$DISMISS_RO" 500 0 '' req-1
dismiss_case 'dismiss: a transport failure fails' "$DISMISS_RO" 000 0 '
FM_FAKE_CURL_RC=7' req-1

DIS_OK_B="$TMP_ROOT/dis-ok-b"; DIS_OK_P="$TMP_ROOT/dis-ok-p"
for w in "$DIS_OK_B" "$DIS_OK_P"; do seed_home "$w"; seed_context "$w" req-1 x 280; done
CASE_BWORLD=$DIS_OK_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=204
FM_FAKE_CURL_RC=0"
run_case 'dismiss: a 2xx clears the durable reply context' fm-x-dismiss req-1

DIS_DRY_B="$TMP_ROOT/dis-dry-b"; DIS_DRY_P="$TMP_ROOT/dis-dry-p"
for w in "$DIS_DRY_B" "$DIS_DRY_P"; do seed_home "$w"; seed_context "$w" req-1 x 280; done
CASE_BWORLD=$DIS_DRY_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FMX_DRY_RUN=1
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'dismiss: a dry run records the preview and posts nothing' fm-x-dismiss req-1

# =============================================================================
# 4. bin/fm-x-reply - argument handling, the dry-run surface, and the exit-8 hold
# =============================================================================

REPLY_RO="$TMP_ROOT/reply-ro"
seed_home "$REPLY_RO"
seed_context "$REPLY_RO" req-1 x 280
seed_context "$REPLY_RO" req-disc discord 1900
mkdir -p "$REPLY_RO/text"
printf 'Aye captain, all shipshape.' > "$REPLY_RO/text/short.txt"
printf 'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu' \
  > "$REPLY_RO/text/long.txt"
printf '' > "$REPLY_RO/text/empty.txt"

reply_case() {  # <label> <world> <digest> <extra-env> [arg...]
  local label=$1 world=$2 digest=$3 extra=$4
  shift 4
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0$extra"
  run_case "$label" fm-x-reply "$@"
}

reply_case 'reply: --help prints usage and succeeds' "$REPLY_RO" 0 '' --help
reply_case 'reply: -h prints usage and succeeds'     "$REPLY_RO" 0 '' -h
reply_case 'reply: no arguments'                     "$REPLY_RO" 0 ''
reply_case 'reply: only a request id'                "$REPLY_RO" 0 '' req-1
reply_case 'reply: --image with no path'             "$REPLY_RO" 0 '' req-1 --image
reply_case 'reply: --receipt-file with no path'      "$REPLY_RO" 0 '' req-1 --receipt-file
reply_case 'reply: --text-file with no path'         "$REPLY_RO" 0 '' req-1 --text-file
reply_case 'reply: --text-file that does not exist'  "$REPLY_RO" 0 '' req-1 --text-file '@W@/text/absent.txt'
reply_case 'reply: an empty text file'               "$REPLY_RO" 0 '' req-1 --text-file '@W@/text/empty.txt'
reply_case 'reply: empty positional text'            "$REPLY_RO" 0 '' req-1 ''
reply_case 'reply: an unsafe request id'             "$REPLY_RO" 0 '' ../evil hello
reply_case 'reply: a dotfile request id'             "$REPLY_RO" 0 '' .hidden hello
reply_case 'reply: an image that does not exist'     "$REPLY_RO" 0 '' req-1 --image '@W@/text/absent.png' hello
reply_case 'reply: an unsupported image type'        "$REPLY_RO" 0 '' req-1 --image '@W@/text/short.txt' hello

# The fail-safe. Without an authoritative platform AND budget a follow-up is
# HELD with exit 8, never posted on a local default.
reply_case 'reply: a follow-up with no resolvable context holds with exit 8' \
  "$REPLY_RO" 0 '' req-unknown --followup --text-file '@W@/text/short.txt'
# An answer (not a follow-up) is not held: the same unresolved context falls back
# to the platform default, which is exactly the asymmetry the hold protects.
reply_case 'reply: an answer with no resolvable context is not held' \
  "$REPLY_RO" 0 '
FMX_DRY_RUN=1' req-unknown --text-file '@W@/text/short.txt'

# The relay-consulting variant of the hold. NO fake is on PATH here and the relay
# is the loopback discard port, so both worlds run the same real curl, it is
# refused instantly, and the message gains its "and the relay did not supply"
# clause. Nothing leaves the machine.
RELAY_RO="$TMP_ROOT/relay-ro"
seed_home "$RELAY_RO"
mkdir -p "$RELAY_RO/text"
printf 'Aye captain.' > "$RELAY_RO/text/short.txt"
CASE_BWORLD=$RELAY_RO CASE_DIGEST=0 CASE_FAKEBIN=''
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FMX_RELAY_URL=http://127.0.0.1:1"
run_case 'reply: a live follow-up that the relay cannot resolve holds with exit 8' \
  fm-x-reply req-none --followup --text-file '@W@/text/short.txt'

# Dry runs write the outbox record and post nothing.
DRY1_B="$TMP_ROOT/dry1-b"; DRY1_P="$TMP_ROOT/dry1-p"
for w in "$DRY1_B" "$DRY1_P"; do
  seed_home "$w"; seed_context "$w" req-1 x 280
  mkdir -p "$w/text"; cp "$REPLY_RO/text/short.txt" "$w/text/short.txt"
done
CASE_BWORLD=$DRY1_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FMX_DRY_RUN=1
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'reply: a single-message dry run records the would-be post' \
  fm-x-reply req-1 --text-file '@W@/text/short.txt'

DRY2_B="$TMP_ROOT/dry2-b"; DRY2_P="$TMP_ROOT/dry2-p"
for w in "$DRY2_B" "$DRY2_P"; do
  seed_home "$w"; seed_context "$w" req-1 x 280
  mkdir -p "$w/text"; cp "$REPLY_RO/text/long.txt" "$w/text/long.txt"
done
CASE_BWORLD=$DRY2_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FMX_DRY_RUN=1
FMX_X_REPLY_MAX_CHARS=60
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'reply: a long reply splits into a numbered thread in the dry-run record' \
  fm-x-reply req-1 --text-file '@W@/text/long.txt'

DRY3_B="$TMP_ROOT/dry3-b"; DRY3_P="$TMP_ROOT/dry3-p"
for w in "$DRY3_B" "$DRY3_P"; do
  seed_home "$w"; seed_context "$w" req-disc discord 1900
  mkdir -p "$w/text"; cp "$REPLY_RO/text/short.txt" "$w/text/short.txt"
done
CASE_BWORLD=$DRY3_B CASE_DIGEST=1 CASE_FAKEBIN=$FAKEBIN
CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FMX_DRY_RUN=1
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0"
run_case 'reply: a follow-up dry run marks the endpoint and writes a receipt' \
  fm-x-reply req-disc --followup --receipt-file '@W@/state/receipt.json' --text-file '@W@/text/short.txt'

# =============================================================================
# 5. bin/fm-x-link
# =============================================================================

LINK_RO="$TMP_ROOT/link-ro"
seed_home "$LINK_RO"
seed_meta "$LINK_RO" t1
seed_context "$LINK_RO" req-1 x 280

link_case() {  # <label> <world> <digest> [arg...]
  local label=$1 world=$2 digest=$3
  shift 3
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=404
FM_FAKE_CURL_RC=0"
  run_case "$label" fm-x-link "$@"
}

link_case 'link: no arguments'                  "$LINK_RO" 0
link_case 'link: only a task id'                "$LINK_RO" 0 t1
link_case 'link: an unsafe task id'             "$LINK_RO" 0 ../evil req-1
link_case 'link: an unsafe request id'          "$LINK_RO" 0 t1 ../evil
link_case 'link: an unknown flag'               "$LINK_RO" 0 t1 req-1 --nope
link_case 'link: --carry-count without --carry-ts' "$LINK_RO" 0 t1 req-1 --carry-count 1
link_case 'link: --carry-ts without --carry-count' "$LINK_RO" 0 t1 req-1 --carry-ts 1700000000
link_case 'link: a non-numeric --carry-count'   "$LINK_RO" 0 t1 req-1 --carry-count x --carry-ts 1
link_case 'link: a bad --carry-platform'        "$LINK_RO" 0 t1 req-1 --carry-count 1 --carry-ts 1 --carry-platform mastodon
link_case 'link: a too-small --carry-max'       "$LINK_RO" 0 t1 req-1 --carry-count 1 --carry-ts 1 --carry-max 10
link_case 'link: --carry-platform without the required pair' "$LINK_RO" 0 t1 req-1 --carry-platform x
link_case 'link: an unknown task'               "$LINK_RO" 0 nosuch req-1
link_case 'link: a relink with no carried context' "$LINK_RO" 0 t1 req-1 --carry-count 1 --carry-ts 1700000000

LINK1_B="$TMP_ROOT/link1-b"; LINK1_P="$TMP_ROOT/link1-p"
for w in "$LINK1_B" "$LINK1_P"; do seed_home "$w"; seed_meta "$w" t1; seed_context "$w" req-1 x 280; done
link_case 'link: a fresh link records the resolved reply context' "$LINK1_B" 1 t1 req-1

LINK2_B="$TMP_ROOT/link2-b"; LINK2_P="$TMP_ROOT/link2-p"
for w in "$LINK2_B" "$LINK2_P"; do seed_home "$w"; seed_meta "$w" t1; done
link_case 'link: a fresh link with no resolvable context warns loudly' "$LINK2_B" 1 t1 req-none

LINK3_B="$TMP_ROOT/link3-b"; LINK3_P="$TMP_ROOT/link3-p"
for w in "$LINK3_B" "$LINK3_P"; do
  seed_home "$w"
  seed_meta "$w" t2 'x_request=req-old' 'x_request_ts=1600000000' 'x_followups=1' 'x_platform=x' 'x_reply_max_chars=280'
done
link_case 'link: a relink carries the consumed count and window forward' "$LINK3_B" 1 \
  t2 req-1 --carry-count 2 --carry-ts 1690000000 --carry-platform discord --carry-max 1900

# =============================================================================
# 6. bin/fm-x-followup - the window, the cap, and the 8-vs-9 link outcomes
# =============================================================================

FUP_RO="$TMP_ROOT/fup-ro"
seed_home "$FUP_RO"
seed_meta "$FUP_RO" plain
seed_meta "$FUP_RO" linked 'x_request=req-1' "x_request_ts=$NOW" 'x_followups=0' 'x_platform=x' 'x_reply_max_chars=280'
mkdir -p "$FUP_RO/text"
printf 'shipped' > "$FUP_RO/text/note.txt"

fup_case() {  # <label> <world> <digest> <extra-env> [arg...]
  local label=$1 world=$2 digest=$3 extra=$4
  shift 4
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_FAKE_CODE=200
FM_FAKE_CURL_RC=0$extra"
  run_case "$label" fm-x-followup "$@"
}

fup_case 'followup: --help prints usage and succeeds' "$FUP_RO" 0 '' --help
fup_case 'followup: no arguments'                     "$FUP_RO" 0 ''
fup_case 'followup: --check with an extra argument'   "$FUP_RO" 0 '' --check linked extra
fup_case 'followup: an unsafe task id'                "$FUP_RO" 0 '' --check ../evil
fup_case 'followup: --check on an unlinked task'      "$FUP_RO" 0 '' --check plain
fup_case 'followup: --check on a linked task in window' "$FUP_RO" 0 '' --check linked
fup_case 'followup: --clear on a task with no meta'   "$FUP_RO" 0 '' --clear nosuch
fup_case 'followup: a post on an unlinked task is a no-op' "$FUP_RO" 0 '' plain --text-file '@W@/text/note.txt'

fup_world() {  # <world> <followups> [ts]
  local w=$1 count=$2 ts=${3:-$NOW}
  seed_home "$w"
  seed_meta "$w" t1 "x_request=req-1" "x_request_ts=$ts" "x_followups=$count" 'x_platform=x' 'x_reply_max_chars=280'
  mkdir -p "$w/text"
  printf 'shipped' > "$w/text/note.txt"
}

FUPC_B="$TMP_ROOT/fupc-b"; FUPC_P="$TMP_ROOT/fupc-p"
for w in "$FUPC_B" "$FUPC_P"; do fup_world "$w" 0; done
fup_case 'followup: --clear removes only the link lines' "$FUPC_B" 1 '' --clear t1

FUPE_B="$TMP_ROOT/fupe-b"; FUPE_P="$TMP_ROOT/fupe-p"
for w in "$FUPE_B" "$FUPE_P"; do fup_world "$w" 0 1600000000; done
fup_case 'followup: an elapsed window prunes the link and skips' "$FUPE_B" 1 '' t1 --text-file '@W@/text/note.txt'

FUPX_B="$TMP_ROOT/fupx-b"; FUPX_P="$TMP_ROOT/fupx-p"
for w in "$FUPX_B" "$FUPX_P"; do fup_world "$w" 3; done
fup_case 'followup: a reached cap prunes the link and skips' "$FUPX_B" 1 '' --check t1

FUP0_B="$TMP_ROOT/fup0-b"; FUP0_P="$TMP_ROOT/fup0-p"
for w in "$FUP0_B" "$FUP0_P"; do fup_world "$w" 0; done
fup_case 'followup: a successful post increments the counter and keeps the link' \
  "$FUP0_B" 1 '
FM_FAKE_REPLY_RC=0' t1 --text-file '@W@/text/note.txt'

FUPF_B="$TMP_ROOT/fupf-b"; FUPF_P="$TMP_ROOT/fupf-p"
for w in "$FUPF_B" "$FUPF_P"; do fup_world "$w" 0; done
fup_case 'followup: --final clears the link after a successful post' \
  "$FUPF_B" 1 '
FM_FAKE_REPLY_RC=0' t1 --final --text-file '@W@/text/note.txt'

FUPL_B="$TMP_ROOT/fupl-b"; FUPL_P="$TMP_ROOT/fupl-p"
for w in "$FUPL_B" "$FUPL_P"; do fup_world "$w" 2; done
fup_case 'followup: reaching the cap on this post clears the link' \
  "$FUPL_B" 1 '
FM_FAKE_REPLY_RC=0' t1 --text-file '@W@/text/note.txt'

FUP8_B="$TMP_ROOT/fup8-b"; FUP8_P="$TMP_ROOT/fup8-p"
for w in "$FUP8_B" "$FUP8_P"; do fup_world "$w" 0; done
fup_case 'followup: exit 8 is a retryable hold that KEEPS the link' \
  "$FUP8_B" 1 '
FM_FAKE_REPLY_RC=8' t1 --text-file '@W@/text/note.txt'

FUP9_B="$TMP_ROOT/fup9-b"; FUP9_P="$TMP_ROOT/fup9-p"
for w in "$FUP9_B" "$FUP9_P"; do fup_world "$w" 0; done
fup_case 'followup: exit 9 is an exhausted binding that clears the link' \
  "$FUP9_B" 1 '
FM_FAKE_REPLY_RC=9' t1 --text-file '@W@/text/note.txt'

FUP1_B="$TMP_ROOT/fup1-b"; FUP1_P="$TMP_ROOT/fup1-p"
for w in "$FUP1_B" "$FUP1_P"; do fup_world "$w" 0; done
fup_case 'followup: any other post failure leaves the link to retry' \
  "$FUP1_B" 1 '
FM_FAKE_REPLY_RC=1' t1 --text-file '@W@/text/note.txt'

# =============================================================================
# 7. bin/fm-public-followup
# =============================================================================

PF_RO="$TMP_ROOT/pf-ro"
seed_home "$PF_RO"
seed_meta "$PF_RO" t1
seed_registration "$PF_RO" ob-1 main t1
mkdir -p "$PF_RO/listings"
jq -n '{public_followups: [
  {id:"ob-1", state:"in-progress",
   public_followup:{
     request:{request_id:"req-1", platform:"x", public_safe_summary:"a  bounded   summary"},
     delivery:{state:"pending-work", attempt_count:0},
     work_relations:[{relation_id:"rel-1", work_ref:{home_id:"main", task_id:"t1"}, accepted_events:[]}]}}]}' \
  > "$PF_RO/listings/pending-work.json"
jq -n '{public_followups: [
  {id:"ob-1", state:"in-progress",
   public_followup:{
     request:{request_id:"req-1", platform:"x", public_safe_summary:"ready to go"},
     delivery:{state:"delivery-posting", attempt_count:2},
     work_relations:[{relation_id:"rel-1", work_ref:{home_id:"main", task_id:"t1"}, accepted_events:[]}]}}]}' \
  > "$PF_RO/listings/posting.json"
jq -n '{public_followups: [
  {id:"ob-1", state:"done",
   public_followup:{
     request:{request_id:"req-1", platform:"x", public_safe_summary:"done"},
     delivery:{state:"posted", attempt_count:1},
     work_relations:[{relation_id:"rel-1", work_ref:{home_id:"main", task_id:"t1"}, accepted_events:[]}]}}]}' \
  > "$PF_RO/listings/done.json"
jq -n '{public_followups: []}' > "$PF_RO/listings/none.json"
printf 'not json\n' > "$PF_RO/listings/broken.json"

pf_case() {  # <label> <world> <digest> <list-file> <list-rc> <resp-file> <resp-rc> [arg...]
  local label=$1 world=$2 digest=$3 list=$4 listrc=$5 resp=$6 resprc=$7
  shift 7
  CASE_BWORLD=$world CASE_DIGEST=$digest CASE_FAKEBIN=$FAKEBIN
  CASE_ENV="FM_HOME=@W@
FM_ROOT_OVERRIDE=$FAKEROOT
FMX_NOW_OVERRIDE=$NOW
FM_TASKS_LIST=$list
FM_TASKS_LIST_RC=$listrc
FM_TASKS_RESP=$resp
FM_TASKS_RC=$resprc
FM_FAKE_FOLLOWUP_RC=0"
  run_case "$label" fm-public-followup "$@"
}

pf_case 'public-followup: --help prints the header'      "$PF_RO" 0 '' 0 '' 0 --help
pf_case 'public-followup: no subcommand'                 "$PF_RO" 0 '' 0 '' 0
pf_case 'public-followup: an unknown subcommand'         "$PF_RO" 0 '' 0 '' 0 bogus
pf_case 'public-followup: active with a registration'    "$PF_RO" 0 '' 0 '' 0 active
pf_case 'public-followup: brief prints the emit command' "$PF_RO" 0 '' 0 '' 0 brief ob-1
pf_case 'public-followup: brief for an unknown id'       "$PF_RO" 0 '' 0 '' 0 brief ob-none
pf_case 'public-followup: brief with an unsafe id'       "$PF_RO" 0 '' 0 '' 0 brief ../evil
pf_case 'public-followup: register with no id'           "$PF_RO" 0 '' 0 '' 0 register
pf_case 'public-followup: register with an unknown flag' "$PF_RO" 0 '' 0 '' 0 register ob-1 --nope x
pf_case 'public-followup: register with a bad work home' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 \
  register ob-1 --relation rel-1 --work-home elsewhere --work-id t1 --generation 1
pf_case 'public-followup: register with a bad generation' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 \
  register ob-1 --relation rel-1 --work-home main --work-id t1 --generation zero
pf_case 'public-followup: register for an unbound relation' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 \
  register ob-1 --relation rel-9 --work-home main --work-id t1 --generation 1
pf_case 'public-followup: register with an unreadable backlog' "$PF_RO" 0 '@W@/listings/broken.json' 1 '' 0 \
  register ob-1 --relation rel-1 --work-home main --work-id t1 --generation 1
pf_case 'public-followup: deliver with an unsafe id'     "$PF_RO" 0 '' 0 '' 0 deliver ../evil
pf_case 'public-followup: deliver an unknown obligation' "$PF_RO" 0 '@W@/listings/none.json' 0 '' 0 deliver ob-1
pf_case 'public-followup: deliver work that is still pending' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 deliver ob-1
pf_case 'public-followup: deliver refuses a crashed mid-delivery' "$PF_RO" 0 '@W@/listings/posting.json' 0 '' 0 deliver ob-1
pf_case 'public-followup: deliver with an unknown flag'  "$PF_RO" 0 '' 0 '' 0 deliver ob-1 --nope
pf_case 'public-followup: record-posted without --attempt' "$PF_RO" 0 '' 0 '' 0 record-posted ob-1 --chunks 1
pf_case 'public-followup: record-posted with zero chunks' "$PF_RO" 0 '' 0 '' 0 record-posted ob-1 --attempt 1 --chunks 0
pf_case 'public-followup: guard-work with no work id'    "$PF_RO" 0 '' 0 '' 0 guard-work main
pf_case 'public-followup: guard-work on unbound work'    "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 guard-work main t9
pf_case 'public-followup: guard-work blocks on an open promise' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 guard-work main t1
pf_case 'public-followup: guard-work passes once the promise is posted' "$PF_RO" 0 '@W@/listings/done.json' 0 '' 0 guard-work main t1
pf_case 'public-followup: guard-work blocks when the backlog cannot be read' "$PF_RO" 0 '@W@/listings/broken.json' 1 '' 0 guard-work main t1
pf_case 'public-followup: pending lists an unresolved commitment' "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 pending
pf_case 'public-followup: pending reports an unreadable backlog' "$PF_RO" 0 '@W@/listings/broken.json' 1 '' 0 pending
pf_case 'public-followup: retire refuses an open promise'  "$PF_RO" 0 '@W@/listings/pending-work.json' 0 '' 0 retire ob-1

PFREG_B="$TMP_ROOT/pfreg-b"; PFREG_P="$TMP_ROOT/pfreg-p"
for w in "$PFREG_B" "$PFREG_P"; do
  seed_home "$w"; seed_meta "$w" t1
  mkdir -p "$w/listings"; cp "$PF_RO/listings/pending-work.json" "$w/listings/pending-work.json"
done
pf_case 'public-followup: register writes the private registration record' \
  "$PFREG_B" 1 '@W@/listings/pending-work.json' 0 '' 0 \
  register ob-1 --relation rel-1 --work-home main --work-id t1 --generation 1

PFRET_B="$TMP_ROOT/pfret-b"; PFRET_P="$TMP_ROOT/pfret-p"
for w in "$PFRET_B" "$PFRET_P"; do
  seed_home "$w"; seed_meta "$w" t1; seed_registration "$w" ob-1 main t1
  mkdir -p "$w/listings"; cp "$PF_RO/listings/done.json" "$w/listings/done.json"
done
pf_case 'public-followup: retire drops a closed registration' \
  "$PFRET_B" 1 '@W@/listings/done.json' 0 '' 0 retire ob-1

PFPRU_B="$TMP_ROOT/pfpru-b"; PFPRU_P="$TMP_ROOT/pfpru-p"
for w in "$PFPRU_B" "$PFPRU_P"; do
  seed_home "$w"; seed_meta "$w" t1; seed_registration "$w" ob-1 main t1
  mkdir -p "$w/listings"; cp "$PF_RO/listings/done.json" "$w/listings/done.json"
done
pf_case 'public-followup: pending prunes a settled registration' \
  "$PFPRU_B" 1 '@W@/listings/done.json' 0 '' 0 pending

# --- consume: the quarantine paths -------------------------------------------

# The derived event id is computed with the SAME library both twins use, so the
# accepted fixture is built from it rather than hard-coded.
. "$ROOT/bin/fm-public-followup-lib.sh"
GOOD_EVENT_ID=$(fm_pf_event_id ob-1 rel-1 main t1 1 pr-merged "$(jq -Sc -n '{pr:"https://example.invalid/pr/1"}')")
[ -n "$GOOD_EVENT_ID" ] || fail "could not derive the accepted event id"

seed_events() {  # <world>
  local w=$1
  mkdir -p "$w/state/public-followup/events" "$w/state/public-followup/consumed"
  chmod 700 "$w/state/public-followup" "$w/state/public-followup/events" \
    "$w/state/public-followup/consumed"
  printf '{broken\n' > "$w/state/public-followup/events/ev-broken.json"
  jq -cn '{event_id:"ev-mismatch", obligation_id:"ob-1"}' \
    > "$w/state/public-followup/events/ev-mismatch.json"
  jq -cn --arg id "$GOOD_EVENT_ID" \
    '{event_id:$id, obligation_id:"ob-1", relation_id:"rel-1", source_home_id:"main",
      work_id:"t1", generation:1, outcome_type:"pr-merged",
      deliverables:{pr:"https://example.invalid/pr/1"}}' \
    > "$w/state/public-followup/events/$GOOD_EVENT_ID.json"
  jq -cn '{event_id:"ev-dupe", obligation_id:"ob-1"}' \
    > "$w/state/public-followup/events/ev-dupe.json"
  printf 'accepted 2023-11-14T22:13:20Z\n' > "$w/state/public-followup/consumed/ev-dupe"
  chmod 600 "$w/state/public-followup/events/"*.json "$w/state/public-followup/consumed/ev-dupe"
}

PFCON_B="$TMP_ROOT/pfcon-b"; PFCON_P="$TMP_ROOT/pfcon-p"
for w in "$PFCON_B" "$PFCON_P"; do
  seed_home "$w"; seed_meta "$w" t1; seed_registration "$w" ob-1 main t1
  seed_events "$w"
  mkdir -p "$w/listings"
  jq -n '{task:{public_followup:{delivery:{state:"ready"}, request:{request_id:"req-1", platform:"x"}}}}' \
    > "$w/listings/work-event.json"
done
pf_case 'public-followup: consume accepts one event and quarantines the rest' \
  "$PFCON_B" 1 '' 0 '@W@/listings/work-event.json' 0 consume

PFREF_B="$TMP_ROOT/pfref-b"; PFREF_P="$TMP_ROOT/pfref-p"
for w in "$PFREF_B" "$PFREF_P"; do
  seed_home "$w"; seed_meta "$w" t1; seed_registration "$w" ob-1 main t1
  mkdir -p "$w/state/public-followup/events"
  chmod 700 "$w/state/public-followup" "$w/state/public-followup/events"
  jq -cn --arg id "$GOOD_EVENT_ID" \
    '{event_id:$id, obligation_id:"ob-1", relation_id:"rel-1", source_home_id:"main",
      work_id:"t1", generation:1, outcome_type:"pr-merged",
      deliverables:{pr:"https://example.invalid/pr/1"}}' \
    > "$w/state/public-followup/events/$GOOD_EVENT_ID.json"
  chmod 600 "$w/state/public-followup/events/$GOOD_EVENT_ID.json"
  mkdir -p "$w/listings"
  printf 'tasks-axi: refused: generation 1 is superseded\n' > "$w/listings/refusal.txt"
done
pf_case 'public-followup: consume quarantines what tasks-axi refuses' \
  "$PFREF_B" 1 '' 0 '@W@/listings/refusal.txt' 1 consume

# =============================================================================
# The PowerShell driver - one process, every case
# =============================================================================
# Quoted here-doc: bash expands nothing, so the PowerShell source is byte-exact.
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
            # [NullString]::Value, not $null: PowerShell binds a $null argument
            # to a [string] parameter as the EMPTY STRING, which leaves the
            # variable SET-BUT-EMPTY. fm-x-lib's config reader treats set-empty
            # as an explicit override that beats the .env, so one case's
            # FMX_RELAY_URL silently changed every later case's relay to the
            # built-in default. Verified: this spelling removes it.
            if ($null -eq $applied[$name]) {
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value)
            } else {
                [Environment]::SetEnvironmentVariable($name, $applied[$name])
            }
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
[ ! -s "$DRIVER_OUT" ] || fail "the PowerShell driver leaked child stdout:"$'\n'"$(cat "$DRIVER_OUT")"
[ ! -s "$DRIVER_ERR" ] || fail "the PowerShell driver wrote to stderr:"$'\n'"$(cat "$DRIVER_ERR")"

# The one declared help divergence: the bash twin requires jq, the PowerShell
# twin does not and says so. That sentence is elided from BOTH sides and the rest
# of the help is compared byte-for-byte.
strip_requires() {  # <text> -> FM_STRIPPED
  local line out='' skipping=0
  FM_STRIPPED=''
  while IFS= read -r line; do
    case $line in
      'Requires '*) skipping=1; continue ;;
      'FM_PF_RETRY_BACKOFF_SECS'*) skipping=0 ;;
    esac
    [ "$skipping" = 1 ] && continue
    out="$out$line"$'\n'
  done <<< "$1"
  FM_STRIPPED=$out
}

SEEN=0
while IFS='|' read -r idx rc outhex errhex; do
  case $idx in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$idx" -lt "${#LABELS[@]}" ] || fail "driver returned an out-of-range case index: $idx"
  label=${LABELS[$idx]}
  assert_case "$label [exit code]" "${BRC[$idx]}" "$rc"
  hex_decode "$outhex"
  case $label in
    'public-followup: --help prints the header')
      strip_requires "${BOUT[$idx]}"; b_help=$FM_STRIPPED
      strip_requires "$FM_UNHEX";     p_help=$FM_STRIPPED
      assert_case "$label [stdout]" "$b_help" "$p_help"
      ;;
    *)
      normalize_out "${BOUT[$idx]}"; b_out=$FM_NORM
      normalize_out "$FM_UNHEX";     p_out=$FM_NORM
      assert_case "$label [stdout]" "$b_out" "$p_out"
      ;;
  esac
  hex_decode "$errhex"
  normalize_out "${BERR[$idx]}"; b_err=$FM_NORM
  normalize_out "$FM_UNHEX";     p_err=$FM_NORM
  assert_case "$label [stderr]" "$b_err" "$p_err"
  if [ "${WANT_DIGEST[$idx]}" = 1 ]; then
    tree_digest "${PWORLD[$idx]}/state"
    assert_case "$label [state tree]" "${BDIGEST[$idx]}" "$DIGEST"
  fi
  SEEN=$((SEEN + 1))
done < "$RESULTS"
[ "$SEEN" -eq "${#LABELS[@]}" ] || fail "driver returned $SEEN results for ${#LABELS[@]} cases"

# No separate parse or import-hygiene phase: the driver already ran all six
# entrypoints in ONE session, so a parse error, a bad module import or a -Force
# import that removed a caller's fm-common would have surfaced as a THREW result
# above.

# =============================================================================
# Report
# =============================================================================

if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the PowerShell X-mode entrypoints differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. The floor is taken from an OBSERVED green run.
MIN_ASSERTIONS=397
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the PowerShell X-mode entrypoints match their bash oracles across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-xmode-psm1.test.sh: all assertions passed\n'
