#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Differential test for the three away-mode entrypoint twins:
#
#   bin/fm-afk-start.ps1   vs bin/fm-afk-start.sh
#   bin/fm-afk-launch.ps1  vs bin/fm-afk-launch.sh
#   bin/fm-afk-return.ps1  vs bin/fm-afk-return.sh
#
# What these three own is a DURABLE STATE MACHINE, not a computation: entering
# away mode, leaving it, and refusing ordinary captain work until the return
# catch-up clears. So an exit code and a message are only half the evidence -
# every case here also compares the RESULTING STATE TREE, because the failure
# modes that matter are "the flag survived a failed launch", "the exact terminal
# id was dropped before its terminal was confirmed gone", and "the gate cleared
# with a blocker still open". A twin that prints the right sentence while leaving
# the wrong files behind is wrong, and only the state dump catches it.
#
# THE BATCHING RULE (docs/powershell-port.md, "the one rule that decides whether
# a suite finishes"). A bare `pwsh -NoProfile -Command "exit 0"` costs 4.8s on
# the reference host, so a suite that spawns one pwsh per case never finishes -
# it times out at 25-60 minutes with ZERO output and presents as a hang. This
# file therefore writes every PowerShell case to a TSV case file and runs ONE
# pwsh over all of them, joining the two worlds' answers by LABEL. Driving a
# .ps1 ENTRYPOINT that way needs three mechanics:
#
#   - `& script.ps1` runs the script IN-PROCESS and its `exit <n>` terminates
#     only that script, leaving the code in $LASTEXITCODE.
#   - Per-case stdout and stderr come from [Console]::SetOut/SetError over
#     StringWriter. This is exactly why all three converted entrypoints import
#     fm-common WITHOUT -Force: -Force re-runs the module body, whose
#     console-encoding assignment REPLACES [Console]::Out, and every case after
#     the first would then write to the driver's own stdout.
#   - Per-case environment is carried in the case RECORD and applied on the
#     PowerShell side, never as a bash prefix assignment, which would have
#     collapsed to the LAST value by the time the single pwsh ran.
#
# FIXTURES ARE HOMES, NOT TREES. Both worlds run the REAL bin/ - which is the
# point, because it makes the cross-script edges real: bash's fm-afk-return.sh
# invokes bin/fm-afk-launch.sh, while the PowerShell twin resolves the same edge
# through Invoke-FmScript and lands on bin/fm-afk-launch.ps1. Isolation comes
# from FM_HOME alone, one scratch home per world per case, so a case costs one
# mkdir rather than a tree copy (a fork costs 0.36-3.1s on this host under
# load, and this suite would otherwise spend minutes before its first
# assertion).
#
# DECLARED NORMALIZATIONS, applied to messages and to the state dump alike, and
# nowhere else:
#   1. EPOCH SECONDS. state/.afk and the gate's `started` record hold a clock
#      reading; the two worlds cannot produce the same one. Any 9-11 digit run
#      becomes <EPOCH>, so the SHAPE is still compared and an absent or
#      malformed stamp still fails.
#   2. SCRATCH NAMES. mktemp-style suffixes are random by construction; the
#      known scratch prefixes keep their prefix and lose their suffix, so a
#      LEAKED scratch file is still loudly visible in the entry list.
#   3. THE HOME PATH SPELLING. /tmp/fm-afk-psm1.X vs the native AppData Temp
#      path are the SAME LOCATION (MSYS mounts one onto the other), so comparing
#      spellings would test the mount table rather than the twins. Separators
#      are unified FIRST, then the root is matched in its unified spelling -
#      doing it the other way round cannot work, because the PowerShell answer
#      arrives with backslashes.
#
# NOT COVERED, deliberately: the herdr and tmux terminal CREATION paths. Neither
# CLI can be driven here - tmux is not installed on this host, and a fake on
# PATH cannot work on the PowerShell side because Windows cannot execute a
# shebang script - so a differential run would exercise a fake of our own
# construction on both sides and prove the fake consistent rather than the
# adapter correct (the same reasoning docs/powershell-port.md records for the
# zellij/cmux/orca adapters). What IS covered is every path that decides
# durable state: the record's read/validate/refuse rules for all four backends
# including `none`, the launch transaction's rollback, the ordered stop, and the
# whole return gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

# C collation so the bash glob's expansion order is ORDINAL, which is the order
# the PowerShell dump sorts by. Without this the two dumps could disagree about
# entry ORDER on a locale that collates punctuation differently - a difference
# about the locale, not about the twins.
export LC_ALL=C

TMP_ROOT=$(fm_test_tmproot fm-afk-psm1)

# The ambient session may legitimately be inside tmux or herdr, and both are
# read by discover_supervisor_target. A stray FM_* override would silently
# retarget whole phases, so the base state is pinned rather than assumed.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION \
  FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_AFK_LAUNCH_ENTRY FM_AFK_LAUNCH_LABEL \
  FM_AFK_STATE_PREPARED FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_BACKEND

# --- record encoding ---------------------------------------------------------
#
# Case values and answers are TAB-delimited line records, but a message
# legitimately contains newlines and a state dump legitimately contains tabs
# (the terminal record IS tab-separated). So every payload is transport-encoded
# onto the C0 separators, which no case value uses: US separates list items, RS
# stands for LF, GS for CR, FS for TAB.
US=$'\x1f'
RS=$'\x1e'
GS=$'\x1d'
FS=$'\x1c'

# enc <text>: sets ENC. A global out-parameter rather than a command
# substitution, because `$(...)` FORKS and this runs thousands of times.
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

TMP_ROOT_NATIVE=$(to_native "$TMP_ROOT")
TMP_ROOT_FWD=${TMP_ROOT_NATIVE//\\//}
ROOT_NATIVE=$(to_native "$ROOT")

CASE_FILE="$TMP_ROOT/cases.tsv"
: > "$CASE_FILE"

ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""
declare -A ORACLE=()

# --- the state dump ----------------------------------------------------------
#
# The second half of every answer. Two parts: the ENTRY LIST (so a leaked
# scratch file, a surviving lock directory, or a dropped record is visible even
# when no message mentions it) and the CONTENT of the six files that ARE the
# away-mode state machine.

# norm_scratch <name>: sets NORMED. Normalization 2.
NORMED=""
norm_scratch() {
  local n=$1
  case "$n" in
    .afk-launch-backup.*) n=".afk-launch-backup.<RAND>" ;;
    .afk-return-catchup.pending.*) n=".afk-return-catchup.pending.<RAND>" ;;
    .afk-return-evidence.*) n=".afk-return-evidence.<RAND>" ;;
    .afk-return-blockers.*) n=".afk-return-blockers.<RAND>" ;;
    .afk-daemon-terminal.pending.*) n=".afk-daemon-terminal.pending.<RAND>" ;;
    .afk.pending.*) n=".afk.pending.<RAND>" ;;
    *.fm-tmp.*) n="<FM-TMP>" ;;
  esac
  NORMED=$n
}

# norm_epoch_into <var> <text>: normalization 1, via bash regex and parameter
# expansion. ASSIGNS rather than prints, because `$(norm ...)` is a forked
# subshell and this runs once per answer.
# The local is named __ne_s, not s, and that is not style: bash locals are
# DYNAMICALLY scoped, so a local named `s` here would SHADOW the caller's `s` and
# `printf -v s` would write into this function's copy. The caller's value was
# then silently unnormalized, and every epoch-bearing case failed with two
# correct-looking answers that differed only in the clock reading.
norm_epoch_into() {
  local __ne_s=$2
  while [[ $__ne_s =~ ([0-9]{9,11}) ]]; do
    __ne_s=${__ne_s//"${BASH_REMATCH[1]}"/<EPOCH>}
  done
  printf -v "$1" '%s' "$__ne_s"
}

DUMP_FILES=(.afk .afk-daemon-terminal .afk-return-catchup .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged)

# dump_state <home>: sets DUMP.
DUMP=""
dump_state() {
  local home=$1
  local state="$home/state"
  local f name entries="" body="" content
  if [ ! -d "$state" ]; then
    DUMP="state=absent"
    return
  fi
  for f in "$state"/*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    norm_scratch "$name"
    name=$NORMED
    [ -d "$f" ] && name="$name/"
    entries="$entries$name,"
  done
  for f in "$state"/.*; do
    name=${f##*/}
    case "$name" in .|..) continue ;; esac
    [ -e "$f" ] || continue
    norm_scratch "$name"
    name=$NORMED
    [ -d "$f" ] && name="$name/"
    entries="$entries$name,"
  done
  body="entries=$entries"
  for name in "${DUMP_FILES[@]}"; do
    if [ -f "$state/$name" ]; then
      content=""
      IFS= read -r -d '' content < "$state/$name" || true
      body="$body|$name=[$content]"
    else
      body="$body|$name=absent"
    fi
  done
  DUMP=$body
}

# --- seeds -------------------------------------------------------------------
#
# Each seed writes ONE home; every case applies it to both worlds' homes so the
# two runs start from byte-identical state.

seed_bare() { :; }

seed_state() { mkdir -p "$1/state"; }

seed_afk() {
  mkdir -p "$1/state"
  printf '1700000001\n' > "$1/state/.afk"
}

seed_afk_artifacts() {
  seed_afk "$1"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$1/state/.subsuper-escalations"
  printf '1700000002\n' > "$1/state/.subsuper-escalations.since"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$1/state/.subsuper-inject-wedged"
}

seed_record_none() {
  seed_afk "$1"
  printf 'none\t-\tnative\n' > "$1/state/.afk-daemon-terminal"
}

seed_record_malformed() {
  mkdir -p "$1/state"
  printf 'garbage\n' > "$1/state/.afk-daemon-terminal"
}

seed_record_two_fields() {
  mkdir -p "$1/state"
  printf 'tmux\tfm-afk-daemon-1\n' > "$1/state/.afk-daemon-terminal"
}

seed_record_unknown_backend() {
  mkdir -p "$1/state"
  printf 'zellij\tsome-target\tsome-extra\n' > "$1/state/.afk-daemon-terminal"
}

seed_record_herdr_noextra() {
  mkdir -p "$1/state"
  printf 'herdr\tsess:pane\t\n' > "$1/state/.afk-daemon-terminal"
}

seed_record_two_lines() {
  mkdir -p "$1/state"
  printf 'none\t-\tnative\nnone\t-\tnative\n' > "$1/state/.afk-daemon-terminal"
}

seed_catchup_pending() {
  mkdir -p "$1/state"
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t1700000003\n'
    printf 'phase\tblocked\n'
  } > "$1/state/.afk-return-catchup"
}

# A live task holding an open `blocked:` event - the whole reason the return
# gate exists. Both a metadata record and a status log are required, because a
# torn-down task must never hold the captain's return open.
seed_live_blocker() {
  mkdir -p "$1/state"
  {
    printf 'window=synthetic:fm-repair-task\n'
    printf 'backend=tmux\n'
    printf 'kind=ship\n'
  } > "$1/state/repair-task.meta"
  printf 'blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token\n' \
    > "$1/state/repair-task.status"
}

seed_resolved_blocker() {
  seed_live_blocker "$1"
  printf 'resolved [key=synthetic-dependency]: refreshed the synthetic token\n' \
    >> "$1/state/repair-task.status"
}

seed_blocker_with_evidence() {
  seed_live_blocker "$1"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$1/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$1/state/.subsuper-inject-wedged"
}

# An already-open gate carrying evidence, so `check` proves the preserve-and-
# clear path rather than a fresh begin.
seed_gate_with_evidence() {
  mkdir -p "$1/state"
  {
    printf 'schema\tfm-afk-return.v1\n'
    printf 'started\t1700000004\n'
    printf 'phase\tblocked\n'
    printf 'evidence\twake\tqueued signal for repair-task\n'
    printf 'evidence\twedge\tfm away-mode inject WEDGED: 4555s undelivered\n'
  } > "$1/state/.afk-return-catchup"
  printf 'repair-task.status: blocked synthetic dependency\n' > "$1/state/.subsuper-escalations"
  printf 'fm away-mode inject WEDGED: 4555s undelivered\n' > "$1/state/.subsuper-inject-wedged"
}

# --- case runner -------------------------------------------------------------
#
# case_run <label> <base> <seed-fn> <env-list> [args...]
#
# Builds one scratch home per world, seeds both identically, runs the bash twin
# now, and queues the PowerShell twin for the single batched pwsh. Results live
# in plain shell variables and every case is a direct call, never a `( ... )`
# subshell: a subshell cannot report a failure back to the parent's counters, so
# a scheme built on one can lose a failure and certify work it never checked.
case_run() {
  local label=$1 base=$2 seedfn=$3 envs=$4
  shift 4
  local bhome="$TMP_ROOT/$label/b" phome="$TMP_ROOT/$label/p"
  local rc out err o="$TMP_ROOT/$label.o" e="$TMP_ROOT/$label.e"
  local -a envarr=()

  mkdir -p "$bhome" "$phome"
  "$seedfn" "$bhome"
  "$seedfn" "$phome"

  if [ -n "$envs" ]; then
    IFS=$US read -ra envarr <<< "$envs"
  fi
  if [ ${#envarr[@]} -gt 0 ]; then
    env FM_HOME="$bhome" "${envarr[@]}" "$ROOT/bin/$base.sh" "$@" >"$o" 2>"$e"
  else
    env FM_HOME="$bhome" "$ROOT/bin/$base.sh" "$@" >"$o" 2>"$e"
  fi
  rc=$?
  out=""; err=""
  IFS= read -r -d '' out < "$o" || true
  IFS= read -r -d '' err < "$e" || true
  dump_state "$bhome"

  enc "$out"; local eout=$ENC
  enc "$err"; local eerr=$ENC
  enc "$DUMP"; local edump=$ENC
  ORACLE[$label]="$rc$US$eout$US$eerr$US$edump"

  local args="" a
  for a in "$@"; do
    enc "$a"
    if [ -z "$args" ]; then args=$ENC; else args="$args$US$ENC"; fi
  done
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$base" "$(to_native "$phome")" "$args" "$envs" >> "$CASE_FILE"
}

# --- phase 1: fm-afk-start's argument surface --------------------------------
#
# Only the paths that do NOT become the daemon: a bare invocation execs
# bin/fm-supervise-daemon on the bash side and BECOMES it on the PowerShell
# side, which is a supervision loop, not a test case.
case_run start-help-h fm-afk-start seed_state "" -h
case_run start-help-long fm-afk-start seed_state "" --help
case_run start-bad-arg fm-afk-start seed_state "" bogus
# FM_AFK_STATE_PREPARED without the launcher's own transaction behind it: the
# refusal that stops a prepared start from entering away mode with no durable
# flag underneath it.
case_run start-prepared-missing fm-afk-start seed_state "FM_AFK_STATE_PREPARED=1"

# --- phase 2: fm-afk-launch's argument surface -------------------------------
case_run launch-help-h fm-afk-launch seed_state "" -h
case_run launch-help-long fm-afk-launch seed_state "" --help
case_run launch-help-word fm-afk-launch seed_state "" help
case_run launch-bad-arg fm-afk-launch seed_state "" bogus

# --- phase 3: the terminal record's read/validate/refuse rules ---------------
#
# The record is the ONLY thing that lets a leaked terminal be closed by its
# exact id, so every way of being unreadable must REFUSE rather than sweep.
case_run reconcile-no-record fm-afk-launch seed_state "" reconcile
case_run reconcile-none-record fm-afk-launch seed_record_none "" reconcile
case_run reconcile-malformed fm-afk-launch seed_record_malformed "" reconcile
case_run reconcile-two-fields fm-afk-launch seed_record_two_fields "" reconcile
case_run reconcile-two-lines fm-afk-launch seed_record_two_lines "" reconcile
case_run reconcile-unknown-backend fm-afk-launch seed_record_unknown_backend "" reconcile
case_run reconcile-herdr-no-extra fm-afk-launch seed_record_herdr_noextra "" reconcile
case_run stop-malformed-record fm-afk-launch seed_record_malformed "" stop

# --- phase 4: the ordered stop -----------------------------------------------
#
# state/.afk is cleared LAST, after the terminal is confirmed gone. The `none`
# backend is the one that can be confirmed here without a terminal CLI, which is
# exactly what a harness-native away session records.
case_run stop-native-record fm-afk-launch seed_record_none "" stop
case_run stop-no-record fm-afk-launch seed_afk "" stop
case_run stop-nothing fm-afk-launch seed_state "" stop

# --- phase 5: the launch transaction and its rollback ------------------------
case_run start-catchup-pending fm-afk-launch seed_catchup_pending "" start
# No supervisor pane resolvable: capture-first refuses before anything is made.
case_run start-no-target fm-afk-launch seed_state "" start
case_run launch-default-command fm-afk-launch seed_state ""
# A backend with no non-visible launch primitive. The launch FAILS after the
# away-mode flag and the stale-artifact clear have already run, so this is the
# rollback case: the previous session's flag and artifacts must come back
# byte-for-byte and no new terminal record may survive.
case_run start-unsupported-backend fm-afk-launch seed_afk_artifacts \
  "FM_SUPERVISOR_TARGET=%1${US}FM_SUPERVISOR_BACKEND=zellij" start

# --- phase 6: the harness-native start --------------------------------------
case_run start-native-clean fm-afk-launch seed_state "" start-native
case_run start-native-clears-artifacts fm-afk-launch seed_afk_artifacts "" start-native
case_run start-native-catchup-pending fm-afk-launch seed_catchup_pending "" start-native
case_run start-native-malformed-record fm-afk-launch seed_record_malformed "" start-native

# --- phase 7: fm-afk-return's argument surface and the read-only guard -------
#
# guard-clean also proves the read-only claim literally: the home has NO state
# directory, and asking the question must not create one.
case_run return-help-h fm-afk-return seed_bare "" -h
case_run return-help-long fm-afk-return seed_bare "" --help
case_run return-help-word fm-afk-return seed_bare "" help
case_run return-bad-arg fm-afk-return seed_bare "" bogus
case_run return-guard-clean fm-afk-return seed_bare "" guard
case_run return-guard-away fm-afk-return seed_afk "" guard
case_run return-guard-gate fm-afk-return seed_catchup_pending "" guard

# --- phase 8: the return catch-up gate ---------------------------------------
#
# These drive the REAL cross-script edges: bash's fm-afk-return.sh runs
# bin/fm-afk-launch.sh and bin/fm-wake-drain.sh, and the PowerShell twin
# resolves the same two edges through Invoke-FmScript onto their .ps1 twins.
case_run return-begin-clean fm-afk-return seed_state "" begin
case_run return-begin-stops-away fm-afk-return seed_afk "" begin
case_run return-begin-stops-native fm-afk-return seed_record_none "" begin
case_run return-begin-blocked fm-afk-return seed_live_blocker "" begin
case_run return-begin-blocked-evidence fm-afk-return seed_blocker_with_evidence "" begin
case_run return-check-resolved fm-afk-return seed_resolved_blocker "" check
case_run return-check-clears-gate fm-afk-return seed_gate_with_evidence "" check
case_run return-default-command fm-afk-return seed_state ""

# --- run the PowerShell half: ONE pwsh for every case ------------------------
DRIVER="$TMP_ROOT/driver.ps1"
cat > "$DRIVER" <<PSEOF
Set-StrictMode -Version Latest
\$ErrorActionPreference = 'Stop'

\$US = [char]0x1f
\$RS = [char]0x1e
\$GS = [char]0x1d
\$FS = [char]0x1c
\$CaseFile = '$(to_native "$CASE_FILE")'
\$OutFile  = '$(to_native "$TMP_ROOT/ps-answers.tsv")'
\$BinDir   = '$ROOT_NATIVE\bin'
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

# Normalization 2, in the same order the bash half applies it: most specific
# first, so `.afk-return-catchup.pending.X` is never mistaken for the gate.
function Get-NormalizedName([string]$Name) {
    if ($Name -like '.afk-launch-backup.*') { return '.afk-launch-backup.<RAND>' }
    if ($Name -like '.afk-return-catchup.pending.*') { return '.afk-return-catchup.pending.<RAND>' }
    if ($Name -like '.afk-return-evidence.*') { return '.afk-return-evidence.<RAND>' }
    if ($Name -like '.afk-return-blockers.*') { return '.afk-return-blockers.<RAND>' }
    if ($Name -like '.afk-daemon-terminal.pending.*') { return '.afk-daemon-terminal.pending.<RAND>' }
    if ($Name -like '.afk.pending.*') { return '.afk.pending.<RAND>' }
    if ($Name -like '*.fm-tmp.*') { return '<FM-TMP>' }
    return $Name
}

$DumpFiles = @('.afk', '.afk-daemon-terminal', '.afk-return-catchup',
    '.subsuper-escalations', '.subsuper-escalations.since', '.subsuper-inject-wedged')

# The dump, matching the bash half field for field. Entries are emitted in TWO
# ordinal groups - non-dot first, then dot - because that is exactly what the
# bash glob pair `"$state"/*` then `"$state"/.*` produces under LC_ALL=C.
function Get-StateDump([string]$HomeDir) {
    $state = Join-Path $HomeDir 'state'
    if (-not [System.IO.Directory]::Exists($state)) { return 'state=absent' }
    $plain = @()
    $dotted = @()
    foreach ($entry in @([System.IO.Directory]::GetFileSystemEntries($state))) {
        $leaf = [System.IO.Path]::GetFileName($entry)
        $name = Get-NormalizedName $leaf
        if ([System.IO.Directory]::Exists($entry)) { $name = "$name/" }
        if ($leaf.StartsWith('.')) { $dotted += $name } else { $plain += $name }
    }
    $plain = @($plain | Sort-Object -CaseSensitive)
    $dotted = @($dotted | Sort-Object -CaseSensitive)
    $entries = ''
    foreach ($n in (@($plain) + @($dotted))) { $entries += "$n," }
    $body = "entries=$entries"
    foreach ($name in $DumpFiles) {
        $path = Join-Path $state $name
        if ([System.IO.File]::Exists($path)) {
            $content = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n")
            $body += "|$name=[$content]"
        } else {
            $body += "|$name=absent"
        }
    }
    return $body
}

# Every environment name any case may set, cleared before each case so a value
# from one case can never leak into the next.
$TouchedNames = @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_ROOT_OVERRIDE', 'FM_BACKEND',
    'FM_SUPERVISOR_TARGET', 'FM_SUPERVISOR_BACKEND', 'FM_AFK_STATE_PREPARED',
    'FM_AFK_LAUNCH_ENTRY', 'FM_AFK_LAUNCH_LABEL',
    'TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SESSION')
foreach ($n in $TouchedNames) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }

$OrigOut = [Console]::Out
$OrigErr = [Console]::Error
$Answers = [System.Text.StringBuilder]::new()

foreach ($line in [System.IO.File]::ReadAllLines($CaseFile)) {
    if ([string]::IsNullOrEmpty($line)) { continue }
    # Split on the record's real TAB, NOT on $FS: FS is the ESCAPE for a tab
    # that appears inside a value, which is why the record separator can still
    # be a plain tab. StringSplitOptions::None keeps trailing empty fields,
    # which several cases legitimately have, and the COUNT is asserted rather
    # than assumed.
    $fields = @($line.Split("`t", [System.StringSplitOptions]::None))
    if ($fields.Count -ne 5) {
        [void]$Answers.AppendLine("PARSE-ERROR`tfields=$($fields.Count) line=$line")
        continue
    }
    $label = $fields[0]
    $base = $fields[1]
    $homeDir = $fields[2]
    $argsRaw = $fields[3]
    $envRaw = $fields[4]

    $caseArgs = @()
    if (-not [string]::IsNullOrEmpty($argsRaw)) {
        foreach ($a in @($argsRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            $caseArgs += (Restore-CaseText $a)
        }
    }

    foreach ($n in $TouchedNames) { Remove-Item -LiteralPath "env:$n" -ErrorAction SilentlyContinue }
    $env:FM_HOME = $homeDir
    if (-not [string]::IsNullOrEmpty($envRaw)) {
        foreach ($pair in @($envRaw.Split($US.ToString(), [System.StringSplitOptions]::None))) {
            if ([string]::IsNullOrEmpty($pair)) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            Set-Item -LiteralPath "env:$($pair.Substring(0, $eq))" -Value (Restore-CaseText $pair.Substring($eq + 1))
        }
    }

    $script = Join-Path $BinDir "$base.ps1"
    $so = [System.IO.StringWriter]::new()
    $se = [System.IO.StringWriter]::new()
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

    $outText = $so.ToString()
    $errText = $se.ToString()
    if ($threw -ne '') { $errText = $errText + "DRIVER-EXCEPTION: $threw`n" }
    $dump = Get-StateDump $homeDir

    $answer = "$rc$US" + (Protect-CaseText $outText) + $US + (Protect-CaseText $errText) +
        $US + (Protect-CaseText $dump)
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

# normalize_into <target-var> <text>: normalizations 1 and 3, in that order.
# ASSIGNS rather than prints, because `$(...)` is a forked subshell and this runs
# twice per assertion; on a host where a fork costs 0.36-4s that alone decides
# whether the suite finishes.
normalize_into() {
  local s=$2 label
  norm_epoch_into s "$s"
  # Separators are unified FIRST, then the root is matched in its unified
  # spelling. The other order cannot work: the PowerShell answer arrives with
  # backslashes, so a forward-slash root would never match.
  s=${s//\\//}
  s=${s//"$TMP_ROOT_FWD"/<ROOT>}
  s=${s//"$TMP_ROOT"/<ROOT>}
  # Each world names its own home under the shared root; both collapse to the
  # same token so a message that legitimately quotes a path still compares.
  s=${s//<ROOT>\/b\//<HOME>/}
  s=${s//<ROOT>\/p\//<HOME>/}
  for label in b p; do
    s=${s//<ROOT>\/$label/<HOME>}
  done
  printf -v "$1" '%s' "$s"
}

declare -A PS_ANSWER=()
while IFS=$'\t' read -r label answer; do
  [ -n "$label" ] || continue
  PS_ANSWER[$label]=$answer
done < "$PS_ANSWERS"

for label in "${!ORACLE[@]}"; do
  if [ -z "${PS_ANSWER[$label]+x}" ]; then
    ASSERTIONS=$((ASSERTIONS + 1))
    FAILURES=$((FAILURES + 1))
    FAILURE_TEXT="${FAILURE_TEXT}${label}
  expected(bash): [${ORACLE[$label]}]
  actual(pwsh)  : <NO ANSWER - the driver never reported this label>
"
    continue
  fi
  normalize_into NORM_EXPECTED "${ORACLE[$label]}"
  normalize_into NORM_ACTUAL "${PS_ANSWER[$label]}"
  assert_same "$label" "$NORM_EXPECTED" "$NORM_ACTUAL"
done

# --- facts that are asserted directly, not through the label join ------------
#
# The differential join proves the two worlds AGREE. These prove they agree on
# the RIGHT answer, so a shared misunderstanding cannot pass as a match.

# The record a PowerShell start-native writes must be readable by the bash
# reader, and vice versa - contract 2 in docs/powershell-port.md, and the reason
# an away session survives cutover with no migration.
ps_native_record=""
IFS= read -r -d '' ps_native_record < "$TMP_ROOT/start-native-clean/p/state/.afk-daemon-terminal" 2>/dev/null || true
assert_same "interop: the PowerShell start-native record is the exact three-field line" \
  "none$(printf '\t')-$(printf '\t')native" "${ps_native_record%$'\n'}"

# The rollback restored the PREVIOUS away session's flag, not a fresh one.
rolled_back=""
IFS= read -r -d '' rolled_back < "$TMP_ROOT/start-unsupported-backend/p/state/.afk" 2>/dev/null || true
assert_same "rollback: a failed launch restores the prior away-mode flag verbatim" \
  "1700000001" "${rolled_back%$'\n'}"

# The read-only guard is read-only in the strongest sense available: it did not
# even create the state directory it was asked about.
guard_state="present"
[ -d "$TMP_ROOT/return-guard-clean/p/state" ] || guard_state="absent"
assert_same "guard: asking the read-only question creates no state directory" "absent" "$guard_state"

# An open blocker must SURVIVE the gate rather than being cleared by it.
gate_after_block="missing"
[ -s "$TMP_ROOT/return-begin-blocked/p/state/.afk-return-catchup" ] && gate_after_block="present"
assert_same "gate: a live blocker leaves a durable gate behind" "present" "$gate_after_block"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - the away-mode twins differ from their bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# Asserted from an OBSERVED green run, so a refactor that silently drops whole
# phases fails loudly instead of certifying an empty suite.
MIN_ASSERTIONS=46
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - the three away-mode twins match the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-afk-psm1.test.sh: all assertions passed\n'
