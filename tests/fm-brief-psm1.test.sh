#!/usr/bin/env bash
# Differential tests for the W4-brief PowerShell entrypoints:
#
#   bin/fm-brief.ps1             vs bin/fm-brief.sh
#   bin/fm-ensure-agents-md.ps1  vs bin/fm-ensure-agents-md.sh
#   bin/fm-project-mode.ps1      vs bin/fm-project-mode.sh
#
# The bash tree is the ORACLE (docs/powershell-port.md): every case drives both
# implementations with the same fixture and compares exit code, stdout, stderr,
# and every byte of every file written. The generated brief is compared with
# `cmp`, not with landmark greps, because AGENTS.md section 11 makes those bytes
# a safety contract - the worktree-isolation assertion and the status protocol
# are the whole reason the scaffolder exists.
#
# ---------------------------------------------------------------------------
# TWO COST RULES THIS FILE IS BUILT AROUND, both measured on this host
#
#   1. ONE pwsh FOR THE WHOLE SUITE. A bare `pwsh -NoProfile -Command "exit 0"`
#      costs ~5s here (~13x a bash fork), so a suite that spawns one per case
#      never finishes. Every PowerShell case is written to a TAB-delimited case
#      FILE; one driver process runs them all IN-PROCESS and writes per-case
#      out/err/rc files; bash then joins by LABEL.
#
#      Running a .ps1 in-process is possible because `exit` inside a script
#      invoked with `&` returns control to the caller and sets $LASTEXITCODE
#      (verified here), and because [Console]::SetOut/SetError survive
#      fm-common.psm1's console-encoding assignment - so the exit code and the
#      byte-exact streams are both observable without a process per case.
#
#      The ONE exception is deliberate and is real coverage: a ship brief makes
#      fm-brief.ps1 resolve the delivery mode through Invoke-FmScript, which
#      spawns fm-project-mode.ps1 as a child process. That execute edge is the
#      contract-7 mechanism, so it is exercised rather than stubbed.
#
#   2. THE ORACLE HALF IS FORK-BOUND AND DOMINATES UNDER LOAD. A trivial fork
#      measured 0.36s idle and 3.1s with four conversion agents live, so the
#      bash side here uses builtins (parameter expansion, `case`, `$(<file)`)
#      wherever it does not cost coverage, and forks only for the script under
#      test and for `cmp` on artifacts whose exact bytes matter.
#
# ---------------------------------------------------------------------------
# WHY FIXTURES LIVE ON A DRIVE PATH, NOT IN /tmp
#
# Git Bash's /tmp is an MSYS mount-table fiction with no native spelling, so a
# fixture there is /tmp/x to bash and C:\Users\...\Temp\x to .NET - and every
# message that echoes a resolved path would differ for a reason that has nothing
# to do with the port. Rooting TMPDIR on a real drive makes the two spellings
# exact mirrors (/f/x <-> F:\x), so paths can be compared rather than explained
# away. The one place a fixture path still cannot match is fm-ensure-agents-md,
# which MUTATES its directory and therefore needs a separate copy per side; those
# cases substitute each side's own directory with @DIR@ before comparing. That is
# a VALUE normalization, never a key - docs/powershell-port.md's "never key a
# probe by a path" trap.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT IS CARRIED PER CASE, IN THE RECORD
#
# A bash prefix assignment persists in the shell after a function call, so by the
# time the single pwsh runs it would hold only the LAST value assigned - every
# case evaluated against one setting. So each case record carries its own
# environment, the driver applies it per case and clears it afterwards, and the
# oracle applies the same list through `env` on the command itself.
#
# It also keeps MSYS out of the loop: launching a native pwsh.exe from Git Bash
# with FM_HOME=/f/x in the environment silently rewrites it to F:/x on the way
# across, which would make the PowerShell side embed a different (correct but
# different) path in the brief. Values read from the case file cross no such
# boundary.
set -u

# TMPDIR must be set BEFORE lib.sh is sourced: the cleanup registry path is
# computed at source time.
_suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR="$_suite_root/.no-mistakes/ps-brief-tmp"
mkdir -p "$TMPDIR"

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || fail "pwsh is required for the PowerShell differential suite"

# Symmetry: the driver clears exactly these before every case, so the oracle must
# not inherit an ambient value for a case that deliberately sets none. A captain
# running this suite from a live firstmate session has FM_HOME exported.
unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE \
  FM_SECONDMATE_CHARTER FM_SECONDMATE_SCOPE FM_CLASSIFY_PAUSED_VERB CDPATH

TMP_ROOT=$(fm_test_tmproot fm-brief-ps)
OUT="$TMP_ROOT/out"
EA="$TMP_ROOT/ea"
BR="$TMP_ROOT/br"
PM="$TMP_ROOT/pm"
CASE_FILE="$TMP_ROOT/cases.tsv"
mkdir -p "$OUT" "$EA" "$BR" "$PM/home/data" "$PM/empty-home"
: > "$CASE_FILE"

# Unit/record separators keep argv and environment lists unambiguous inside one
# TAB-delimited line; no fixture value contains either byte.
ES=$'\037'
AS=$'\036'

# Progress goes to stderr, not stdout: the oracle half of this suite is
# fork-bound (one bash script invocation measured between 12s and 60s on a
# contended host), so a run legitimately spends minutes before the first `ok -`
# line. Without these markers a slow run is indistinguishable from a wedged one,
# which is exactly the failure mode docs/powershell-port.md warns about.
progress() { printf '# %s\n' "$1" >&2; }

ASSERTIONS=0
# Observed on a green run; a suite that silently stops exercising cases must
# fail rather than report success on a handful of assertions.
MIN_ASSERTIONS=170

# --- assertions --------------------------------------------------------------

assert_eq() { # actual expected label
  ASSERTIONS=$((ASSERTIONS + 1))
  [ "$1" = "$2" ] || fail "$3"$'\n'"--- powershell ---"$'\n'"$1"$'\n'"--- bash oracle ---"$'\n'"$2"
}

assert_same_bytes() { # ps_file sh_file label
  ASSERTIONS=$((ASSERTIONS + 1))
  [ -f "$1" ] || fail "$3: PowerShell wrote no file at $1"
  [ -f "$2" ] || fail "$3: bash oracle wrote no file at $2"
  cmp -s "$1" "$2" || fail "$3 (bytes differ)"$'\n'"$(diff "$2" "$1" | head -30)"
}

# --- case runner -------------------------------------------------------------
#
# add_case runs the BASH oracle immediately (capturing out/err/rc) and appends
# the PowerShell half to the case file for the single driver run.

add_case() { # label sh-script ps-script cwd envspec argspec
  local label=$1 sh=$2 ps=$3 cwd=$4 envspec=$5 argspec=$6 rc=0 prev
  local -a envpairs=() argv=()
  [ "$envspec" = "-" ] || IFS=$ES read -r -a envpairs <<< "$envspec"
  [ "$argspec" = "-" ] || IFS=$AS read -r -a argv <<< "$argspec"
  prev=$PWD
  if [ "$cwd" != "-" ]; then cd "$cwd" || fail "$label: cannot enter $cwd"; fi
  env ${envpairs[@]+"${envpairs[@]}"} "$_suite_root/bin/$sh" \
    ${argv[@]+"${argv[@]}"} > "$OUT/$label.sh.out" 2> "$OUT/$label.sh.err" || rc=$?
  cd "$prev" || fail "$label: cannot return to $prev"
  printf '%s\n' "$rc" > "$OUT/$label.sh.rc"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$ps" "$cwd" "$envspec" "$argspec" >> "$CASE_FILE"
}

# compare_case <label> [sh-substitution ps-substitution]
# The optional substitutions replace each side's own fixture directory with a
# placeholder, for the mutating fm-ensure-agents-md cases that cannot share one.
compare_case() {
  local label=$1 shsub=${2:-} pssub=${3:-} shout sherr shrc psout pserr psrc
  [ -f "$OUT/$label.ps.rc" ] || fail "$label: the PowerShell driver produced no result"
  shrc=$(<"$OUT/$label.sh.rc"); psrc=$(<"$OUT/$label.ps.rc")
  shout=$(<"$OUT/$label.sh.out"); psout=$(<"$OUT/$label.ps.out")
  sherr=$(<"$OUT/$label.sh.err"); pserr=$(<"$OUT/$label.ps.err")
  if [ -n "$shsub" ]; then
    shout=${shout//$shsub/@DIR@}; sherr=${sherr//$shsub/@DIR@}
    psout=${psout//$pssub/@DIR@}; pserr=${pserr//$pssub/@DIR@}
  fi
  assert_eq "$psrc" "$shrc" "$label: exit code differs"
  assert_eq "$psout" "$shout" "$label: stdout differs"
  assert_eq "$pserr" "$sherr" "$label: stderr differs"
}

# =============================================================================
# PHASE 1 - fixtures and oracle runs
# =============================================================================

# --- fm-project-mode ---------------------------------------------------------
#
# One shared read-only registry: the resolver never writes, so both languages can
# read the same fixture and every path in every message is identical with no
# normalization at all.

cat > "$PM/home/data/projects.md" <<'EOF'
- alpha - legacy line with no bracket (added 2026-07-01)
- beta [direct-PR] - explicit mode (added 2026-07-01)
- gamma [local-only] - explicit mode (added 2026-07-01)
- delta [direct-PR +yolo] - mode plus yolo (added 2026-07-01)
- eps [+yolo] - yolo only, mode defaults (added 2026-07-01)
- zeta [bogus-mode] - unknown mode falls back (added 2026-07-01)
- eta [] - empty bracket (added 2026-07-01)
- iota [direct-PR - unclosed bracket (added 2026-07-01)
  - kappa [local-only] - indented registry line (added 2026-07-01)
- lam [local-only +yolo extra] - extra bracket token (added 2026-07-01)
- dup [direct-PR] - first match wins (added 2026-07-01)
- dup [local-only] - later duplicate ignored (added 2026-07-01)
- alphabet [local-only] - name that another name prefixes (added 2026-07-01)
EOF
mkdir -p "$PM/data-override"
cp "$PM/home/data/projects.md" "$PM/data-override/projects.md"

pm_case() { # name [extra-env]
  local name=$1 extra=${2:-}
  local envspec="FM_HOME=$PM/home"
  [ -z "$extra" ] || envspec="$envspec$ES$extra"
  add_case "pm-$name" fm-project-mode.sh fm-project-mode.ps1 - "$envspec" "$name"
}

progress 'phase 1: fm-project-mode oracle runs'
for _p in alpha beta gamma delta eps zeta eta iota kappa lam dup alphabet; do
  pm_case "$_p"
done
add_case pm-absent fm-project-mode.sh fm-project-mode.ps1 - "FM_HOME=$PM/home" nosuchproject
add_case pm-noregistry fm-project-mode.sh fm-project-mode.ps1 - "FM_HOME=$PM/empty-home" beta
add_case pm-dataoverride fm-project-mode.sh fm-project-mode.ps1 - \
  "FM_HOME=$PM/empty-home${ES}FM_DATA_OVERRIDE=$PM/data-override" gamma
# Extra positional arguments are ignored by the bash twin; only $1 is read.
add_case pm-extra-args fm-project-mode.sh fm-project-mode.ps1 - "FM_HOME=$PM/home" "beta${AS}gamma"
# No argument at all: bash aborts through ${1:?...}, whose message carries its own
# "line N:" prefix. Only the exit code and the usage suffix are comparable.
add_case pm-noarg fm-project-mode.sh fm-project-mode.ps1 - "FM_HOME=$PM/home" -

# --- fm-ensure-agents-md -----------------------------------------------------
#
# This script MUTATES its directory, so each case gets one fixture per side built
# by the same builder, and the comparison substitutes each side's own path.

MAINT_BODY='## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.'

# The alias form this host can actually sustain. Both twins probe for real (bash
# because `ln -s` silently copies, PowerShell because New-Item throws without
# Developer Mode), so a fixture must be built in whichever form they produce or
# it would not be recognized as an existing correct alias.
SYMLINKS_WORK=no
mkdir -p "$TMP_ROOT/slprobe"
printf 'probe\n' > "$TMP_ROOT/slprobe/target"
if ln -s target "$TMP_ROOT/slprobe/link" 2>/dev/null && [ -L "$TMP_ROOT/slprobe/link" ]; then
  SYMLINKS_WORK=yes
fi

make_alias() { # dir
  if [ "$SYMLINKS_WORK" = yes ]; then
    ln -s AGENTS.md "$1/CLAUDE.md"
  else
    printf '@AGENTS.md\n' > "$1/CLAUDE.md"
  fi
}

fx_empty() { :; }
fx_promote() { printf '# Existing agent memory\n\nRun tests with `make test`.\n' > "$1/CLAUDE.md"; }
fx_promote_nonl() { printf '# Existing agent memory\n\nRun tests with make test.' > "$1/CLAUDE.md"; }
fx_existing_alias() {
  printf '# Existing agent memory\n\nBuild with make.\n' > "$1/AGENTS.md"
  make_alias "$1"
}
fx_existing_complete() {
  printf '# Existing agent memory\n\nBuild with make.\n\n%s\n' "$MAINT_BODY" > "$1/AGENTS.md"
  make_alias "$1"
}
fx_existing_noclaude() { printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$1/AGENTS.md"; }
fx_agents_empty() { : > "$1/AGENTS.md"; }
fx_agents_nonl() { printf '# Existing agent memory\n\nNo trailing newline here.' > "$1/AGENTS.md"; }
fx_crlf_complete() {
  printf '%s\r\n' '# Existing agent memory' '' '## Maintaining this file' '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$1/AGENTS.md"
  make_alias "$1"
}
fx_crlf_inject() {
  printf '%s\r\n' '# Existing agent memory' '' 'Run tests with make test.' > "$1/AGENTS.md"
  make_alias "$1"
}
fx_lowercase() { printf '# project memory\n' > "$1/agents.md"; }
fx_agents_dir() { mkdir -p "$1/AGENTS.md"; }
fx_claude_dir() { printf '# real memory\n' > "$1/AGENTS.md"; mkdir -p "$1/CLAUDE.md"; }
fx_both_real() { printf '# agents\n' > "$1/AGENTS.md"; printf '# claude\n' > "$1/CLAUDE.md"; }
fx_import_with_agents() {
  printf '# Existing agent memory\n\nBuild with make.\n' > "$1/AGENTS.md"
  printf '@AGENTS.md\n' > "$1/CLAUDE.md"
}
fx_import_no_agents() { printf '@AGENTS.md\n' > "$1/CLAUDE.md"; }

ea_case() { # label builder [argspec-override]
  local label=$1 builder=$2 override=${3:-}
  mkdir -p "$EA/$label/sh" "$EA/$label/ps"
  "$builder" "$EA/$label/sh"
  "$builder" "$EA/$label/ps"
  local rc=0
  if [ -n "$override" ]; then
    "$_suite_root/bin/fm-ensure-agents-md.sh" "${override/@DIR@/$EA/$label/sh}" \
      > "$OUT/$label.sh.out" 2> "$OUT/$label.sh.err" || rc=$?
    printf '%s\n' "$rc" > "$OUT/$label.sh.rc"
    printf '%s\t%s\t%s\t%s\t%s\n' "$label" fm-ensure-agents-md.ps1 - - \
      "${override/@DIR@/$EA/$label/ps}" >> "$CASE_FILE"
  else
    "$_suite_root/bin/fm-ensure-agents-md.sh" "$EA/$label/sh" \
      > "$OUT/$label.sh.out" 2> "$OUT/$label.sh.err" || rc=$?
    printf '%s\n' "$rc" > "$OUT/$label.sh.rc"
    printf '%s\t%s\t%s\t%s\t%s\n' "$label" fm-ensure-agents-md.ps1 - - "$EA/$label/ps" >> "$CASE_FILE"
  fi
}

progress 'phase 1: fm-ensure-agents-md oracle runs'
ea_case ea-empty fx_empty
ea_case ea-promote fx_promote
ea_case ea-promote-nonl fx_promote_nonl
ea_case ea-existing-alias fx_existing_alias
ea_case ea-existing-complete fx_existing_complete
ea_case ea-existing-noclaude fx_existing_noclaude
ea_case ea-agents-empty fx_agents_empty
ea_case ea-agents-nonl fx_agents_nonl
ea_case ea-crlf-complete fx_crlf_complete
ea_case ea-crlf-inject fx_crlf_inject
ea_case ea-lowercase fx_lowercase
ea_case ea-agents-dir fx_agents_dir
ea_case ea-claude-dir fx_claude_dir
ea_case ea-both-real fx_both_real
ea_case ea-import-with-agents fx_import_with_agents
ea_case ea-import-no-agents fx_import_no_agents
ea_case ea-missing-dir fx_empty '@DIR@/nope'

# Argument-shape cases carry no path, so they need no normalization.
add_case ea-help fm-ensure-agents-md.sh fm-ensure-agents-md.ps1 - - '-h'
add_case ea-help-long fm-ensure-agents-md.sh fm-ensure-agents-md.ps1 - - '--help'
add_case ea-two-args fm-ensure-agents-md.sh fm-ensure-agents-md.ps1 - - "a${AS}b"

# --- fm-brief ----------------------------------------------------------------
#
# Ship, scout, and charter briefs are compared byte for byte, which means both
# sides must scaffold into the SAME home (the brief embeds its own status path).
# So the oracle runs first, its brief is moved aside, and the task directory is
# removed so the "refuses to overwrite" guard does not fire on the second run.

br_home() { # label -> creates and echoes the shared home
  local home="$BR/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s' "$home"
}

br_case() { # label id envspec argspec
  local label=$1 envspec=$2 argspec=$3
  add_case "$label" fm-brief.sh fm-brief.ps1 - "$envspec" "$argspec"
}

# Snapshot and clear the oracle's brief so the PowerShell run writes to the same
# path. Called immediately after each generating case.
br_snapshot() { # label data-dir id
  local label=$1 datadir=$2 id=$3
  if [ -f "$datadir/$id/brief.md" ]; then
    mv "$datadir/$id/brief.md" "$OUT/$label.oracle.brief"
    rmdir "$datadir/$id" 2>/dev/null || true
  fi
  printf '%s\n' "$datadir/$id/brief.md" > "$OUT/$label.briefpath"
}

BR_REG=$(br_home registry)
cat > "$BR_REG/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF

progress 'phase 1: fm-brief oracle runs'
add_case br-help fm-brief.sh fm-brief.ps1 - - '--help'

br_case br-ship-nomistakes "FM_HOME=$BR_REG" "ship-nm${AS}unregistered-proj"
br_snapshot br-ship-nomistakes "$BR_REG/data" ship-nm
br_case br-ship-directpr "FM_HOME=$BR_REG" "ship-dp${AS}direct-proj"
br_snapshot br-ship-directpr "$BR_REG/data" ship-dp
br_case br-ship-localonly "FM_HOME=$BR_REG" "ship-lo${AS}local-proj"
br_snapshot br-ship-localonly "$BR_REG/data" ship-lo
br_case br-ship-pauseverb \
  "FM_HOME=$BR_REG${ES}FM_CLASSIFY_PAUSED_VERB=awaiting" "ship-pv${AS}local-proj"
br_snapshot br-ship-pauseverb "$BR_REG/data" ship-pv

# The guarded Herdr contract on a SHIP brief, against the real firstmate root:
# a ship brief resolves its delivery mode through the sibling resolver, and
# pointing FM_ROOT_OVERRIDE at a root with no bin/ would test how each language
# reports a MISSING resolver (bash: the OS error; PowerShell: Invoke-FmScript's
# "no twin found") rather than the Herdr contract. The apostrophe-quoting half of
# the contract is covered by br-scout-herdr below, which needs no resolver - the
# same split bin/fm-brief.sh's own suite makes.
br_case br-ship-herdr "FM_HOME=$BR_REG" "ship-hl${AS}firstmate${AS}--herdr-lab"
br_snapshot br-ship-herdr "$BR_REG/data" ship-hl

# --herdr-lab on a FM_ROOT_OVERRIDE containing an apostrophe: the helper path must
# come back shell-quoted with the '\'' escape, in both languages.
BR_FOREIGN="$BR/firstmate helper's root"
mkdir -p "$BR_FOREIGN/bin"

br_case br-scout "FM_HOME=$BR_REG" "scout-a${AS}alpha${AS}--scout"
br_snapshot br-scout "$BR_REG/data" scout-a
br_case br-scout-herdr \
  "FM_HOME=$BR_REG${ES}FM_ROOT_OVERRIDE=$BR_FOREIGN" "scout-hl${AS}alpha${AS}--scout${AS}--herdr-lab"
br_snapshot br-scout-herdr "$BR_REG/data" scout-hl
br_case br-scout-pauseverb \
  "FM_HOME=$BR_REG${ES}FM_CLASSIFY_PAUSED_VERB=awaiting" "scout-pv${AS}alpha${AS}--scout"
br_snapshot br-scout-pauseverb "$BR_REG/data" scout-pv

br_case br-mate-projects \
  "FM_HOME=$BR_REG${ES}FM_SECONDMATE_CHARTER=Supervise the alpha domain.${ES}FM_SECONDMATE_SCOPE=alpha and beta work" \
  "mate-p${AS}--secondmate${AS}alpha${AS}beta"
br_snapshot br-mate-projects "$BR_REG/data" mate-p
br_case br-mate-noprojects \
  "FM_HOME=$BR_REG${ES}FM_SECONDMATE_CHARTER=firstmate self-development" \
  "mate-np${AS}--secondmate${AS}--no-projects"
br_snapshot br-mate-noprojects "$BR_REG/data" mate-np
br_case br-mate-default "FM_HOME=$BR_REG" "mate-def${AS}--secondmate${AS}alpha"
br_snapshot br-mate-default "$BR_REG/data" mate-def
br_case br-mate-pauseverb \
  "FM_HOME=$BR_REG${ES}FM_CLASSIFY_PAUSED_VERB=awaiting${ES}FM_SECONDMATE_CHARTER=Handle routed domain work." \
  "mate-pv${AS}--secondmate${AS}--no-projects"
br_snapshot br-mate-pauseverb "$BR_REG/data" mate-pv

# Split state/data overrides: the charter's status path must follow STATE while
# the brief itself lands under DATA.
BR_SPLIT=$(br_home split)
mkdir -p "$BR_SPLIT/data-override" "$BR_SPLIT/state-override"
br_case br-mate-overrides \
  "FM_HOME=$BR_SPLIT${ES}FM_DATA_OVERRIDE=$BR_SPLIT/data-override${ES}FM_STATE_OVERRIDE=$BR_SPLIT/state-override${ES}FM_SECONDMATE_CHARTER=Split overrides." \
  "mate-ov${AS}--secondmate${AS}--no-projects"
br_snapshot br-mate-overrides "$BR_SPLIT/data-override" mate-ov

# A RELATIVE FM_HOME must resolve to the same absolute path in both worlds and
# must ignore CDPATH. The runner's cwd argument carries to BOTH sides, so this is
# the one case where the two implementations are driven from a directory other
# than the suite's own.
BR_REL=$(br_home relative)
mkdir -p "$BR/cdpath/relative/data"
add_case br-relative-home fm-brief.sh fm-brief.ps1 "$BR" \
  "CDPATH=$BR/cdpath${ES}FM_HOME=relative${ES}FM_SECONDMATE_CHARTER=Relative home." \
  "rel-a${AS}--secondmate${AS}--no-projects"
br_snapshot br-relative-home "$BR_REL/data" rel-a

# --- refusals ----------------------------------------------------------------

BR_ERR=$(br_home refusals)
add_case br-err-mate-herdr fm-brief.sh fm-brief.ps1 - \
  "FM_HOME=$BR_ERR${ES}FM_SECONDMATE_CHARTER=ops" "e1${AS}--secondmate${AS}alpha${AS}--herdr-lab"
add_case br-err-noprojects-ship fm-brief.sh fm-brief.ps1 - \
  "FM_HOME=$BR_ERR" "e2${AS}somerepo${AS}--no-projects"
add_case br-err-mate-no-list fm-brief.sh fm-brief.ps1 - \
  "FM_HOME=$BR_ERR${ES}FM_SECONDMATE_CHARTER=x" "e3${AS}--secondmate"
add_case br-err-noprojects-with-list fm-brief.sh fm-brief.ps1 - \
  "FM_HOME=$BR_ERR${ES}FM_SECONDMATE_CHARTER=x" "e4${AS}--secondmate${AS}--no-projects${AS}alpha"
mkdir -p "$BR_ERR/data/e5"
printf 'already here\n' > "$BR_ERR/data/e5/brief.md"
add_case br-err-exists fm-brief.sh fm-brief.ps1 - "FM_HOME=$BR_ERR" "e5${AS}somerepo"
_prev=$PWD
cd "$BR_ERR" || fail "cannot enter $BR_ERR"
add_case br-err-unresolved-home fm-brief.sh fm-brief.ps1 "$BR_ERR" \
  "FM_HOME=missing-home${ES}FM_SECONDMATE_CHARTER=x" "e6${AS}--secondmate${AS}--no-projects"
add_case br-err-unresolved-state fm-brief.sh fm-brief.ps1 "$BR_ERR" \
  "FM_HOME=$BR_ERR${ES}FM_STATE_OVERRIDE=missing-state${ES}FM_SECONDMATE_CHARTER=x" \
  "e7${AS}--secondmate${AS}--no-projects"
add_case br-err-unresolved-data fm-brief.sh fm-brief.ps1 "$BR_ERR" \
  "FM_HOME=$BR_ERR${ES}FM_DATA_OVERRIDE=missing-data${ES}FM_SECONDMATE_CHARTER=x" \
  "e8${AS}--secondmate${AS}--no-projects"
cd "$_prev" || fail "cannot return to $_prev"
# No task id at all: bash aborts on POS[0] under set -u, the twin refuses with its
# own message. Only the exit code and the empty stdout are comparable.
add_case br-err-no-id fm-brief.sh fm-brief.ps1 - "FM_HOME=$BR_ERR" -

# =============================================================================
# PHASE 2 - one pwsh for every PowerShell case
# =============================================================================

progress 'phase 2: one pwsh driver for every PowerShell case'

cat > "$TMP_ROOT/driver.ps1" <<'PSEOF'
# One process, every case. See the suite header for why this shape is mandatory.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$caseFile = $args[0]
$outDir = $args[1]
$binDir = $args[2]

# Deliberately NOT importing fm-common: each entrypoint imports it with -Force,
# which REMOVES the loaded copy before re-importing, and the driver must not
# depend on a binding that disappears mid-run. The one conversion needed here is
# the MSYS drive form, inlined.
function ToNative([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    if ($p -match '^/([A-Za-z])(/|$)') { return ($Matches[1].ToUpperInvariant() + ':' + ($p.Substring(2) -replace '/', '\')) }
    return ($p -replace '/', '\')
}

$clearNames = @(
    'FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE',
    'FM_SECONDMATE_CHARTER', 'FM_SECONDMATE_SCOPE', 'FM_CLASSIFY_PAUSED_VERB', 'CDPATH'
)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$unit = [char]0x1F
$record = [char]0x1E
$startDir = (Get-Location).Path

foreach ($line in [System.IO.File]::ReadAllLines($caseFile)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $fields = @($line.Split("`t"))
    if ($fields.Count -ne 5) { throw "malformed case record: $line" }
    $label = $fields[0]
    $script = $fields[1]
    $cwd = $fields[2]
    $envSpec = $fields[3]
    $argSpec = $fields[4]

    foreach ($name in $clearNames) { Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue }
    if ($envSpec -ne '-') {
        foreach ($pair in @($envSpec.Split($unit))) {
            $eq = $pair.IndexOf('=')
            if ($eq -lt 1) { continue }
            Set-Item -Path ('Env:' + $pair.Substring(0, $eq)) -Value $pair.Substring($eq + 1)
        }
    }
    # Assigned in STATEMENT form, never as `$argv = if (...) { @(...) }`.
    # An if used as an expression writes its result through the output stream,
    # and the stream UNROLLS a single-element array into a bare string - so a
    # one-argument case splatted the string itself and the script under test saw
    # a mangled argument (observed live: `fm-project-mode.ps1 alpha` resolving
    # the project name "a"). The [string[]] cast pins the type on top.
    $argv = @()
    if ($argSpec -ne '-') { $argv = [string[]]@($argSpec.Split($record)) }

    if ($cwd -ne '-') { Set-Location -LiteralPath (ToNative $cwd) }

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
        Set-Location -LiteralPath $startDir
    }

    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.out"), $so.ToString(), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.err"), $se.ToString(), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $outDir "$label.ps.rc"), "$rc`n", $utf8)
}
PSEOF

pwsh -NoProfile -File "$(fm_test_native_path "$TMP_ROOT/driver.ps1")" \
  "$(fm_test_native_path "$CASE_FILE")" \
  "$(fm_test_native_path "$OUT")" \
  "$(fm_test_native_path "$_suite_root/bin")" \
  || fail "the PowerShell driver exited non-zero"

# =============================================================================
# PHASE 3 - join by label and compare
# =============================================================================

test_project_mode_parity() {
  local p
  for p in alpha beta gamma delta eps zeta eta iota kappa lam dup alphabet; do
    compare_case "pm-$p"
  done
  compare_case pm-absent
  compare_case pm-noregistry
  compare_case pm-dataoverride
  compare_case pm-extra-args
  pass "fm-project-mode.ps1: registry parsing, fallbacks and warnings match the bash oracle"
}

test_project_mode_missing_argument() {
  local shrc psrc sherr pserr
  shrc=$(<"$OUT/pm-noarg.sh.rc"); psrc=$(<"$OUT/pm-noarg.ps.rc")
  sherr=$(<"$OUT/pm-noarg.sh.err"); pserr=$(<"$OUT/pm-noarg.ps.err")
  assert_eq "$psrc" "$shrc" "pm-noarg: exit code differs"
  assert_eq "$(<"$OUT/pm-noarg.ps.out")" "$(<"$OUT/pm-noarg.sh.out")" "pm-noarg: stdout differs"
  # Divergence of record: bash prefixes its own "<script>: line N: 1: ".
  case "$sherr" in
    *"usage: fm-project-mode.sh [--raw] <project-name>") ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "pm-noarg: bash oracle did not end with the usage text (got: $sherr)" ;;
  esac
  case "$pserr" in
    *"usage: fm-project-mode.sh [--raw] <project-name>") ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "pm-noarg: PowerShell twin did not end with the usage text (got: $pserr)" ;;
  esac
  pass "fm-project-mode.ps1: a missing project name refuses with the same code and usage text"
}

test_ensure_agents_md_parity() {
  local label
  for label in ea-empty ea-promote ea-promote-nonl ea-existing-alias ea-existing-complete \
    ea-existing-noclaude ea-agents-empty ea-agents-nonl ea-crlf-complete ea-crlf-inject \
    ea-lowercase ea-agents-dir ea-claude-dir ea-both-real ea-import-with-agents \
    ea-import-no-agents ea-missing-dir; do
    compare_case "$label" "$EA/$label/sh" "$EA/$label/ps"
    # Every byte of the resulting memory file, including CRLF preservation and the
    # blank-line separator before the injected section. Asserting when EITHER side
    # produced one also catches "one language wrote it and the other did not".
    if [ -f "$EA/$label/sh/AGENTS.md" ] || [ -f "$EA/$label/ps/AGENTS.md" ]; then
      assert_same_bytes "$EA/$label/ps/AGENTS.md" "$EA/$label/sh/AGENTS.md" \
        "$label: AGENTS.md content differs"
    fi
    # The alias: same kind, and for the import form the same bytes.
    assert_eq "$(alias_kind "$EA/$label/ps")" "$(alias_kind "$EA/$label/sh")" \
      "$label: CLAUDE.md alias form differs"
  done
  compare_case ea-help
  compare_case ea-help-long
  compare_case ea-two-args
  pass "fm-ensure-agents-md.ps1: all three alias states, CRLF handling and refusals match the bash oracle"
}

# alias_kind <dir>: symlink / import / file / dir / absent, with the import form's
# bytes folded in so a differently spelled directive is not reported as equal.
alias_kind() {
  local d=$1
  if [ -L "$d/CLAUDE.md" ]; then printf 'symlink:%s\n' "$(readlink "$d/CLAUDE.md")"; return 0; fi
  if [ -d "$d/CLAUDE.md" ]; then printf 'dir\n'; return 0; fi
  if [ -f "$d/CLAUDE.md" ]; then printf 'file:%s\n' "$(<"$d/CLAUDE.md")"; return 0; fi
  printf 'absent\n'
}

test_brief_help_is_byte_identical() {
  compare_case br-help
  pass "fm-brief.ps1: --help renders its header byte-identically to the bash twin"
}

test_generated_briefs_are_byte_identical() {
  local label briefpath
  for label in br-ship-nomistakes br-ship-directpr br-ship-localonly br-ship-pauseverb \
    br-ship-herdr br-scout br-scout-herdr br-scout-pauseverb br-mate-projects \
    br-mate-noprojects br-mate-default br-mate-pauseverb br-mate-overrides br-relative-home; do
    compare_case "$label"
    briefpath=$(<"$OUT/$label.briefpath")
    assert_same_bytes "$briefpath" "$OUT/$label.oracle.brief" \
      "$label: generated brief differs from the bash oracle"
  done
  pass "fm-brief.ps1: every ship, scout and charter variant generates a byte-identical brief"
}

# The safety contract in AGENTS.md section 11, asserted on the PowerShell output
# directly rather than only through equality with the oracle: a shared regression
# that removed the assertion from BOTH twins would still pass a pure diff.
test_safety_contract_survives_in_powershell_output() {
  local brief
  brief=$(<"$OUT/br-ship-nomistakes.briefpath")
  assert_grep "**Verify isolation before anything else.**" "$brief" \
    "ship brief lost the worktree-isolation assertion"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "ship brief lost the primary-checkout refusal"
  assert_grep "States: working, needs-decision, blocked, paused, done, failed." "$brief" \
    "ship brief lost the status protocol vocabulary"
  assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
    "ship brief lost the nonterminal working: gate"
  assert_grep "{TASK}" "$brief" "ship brief lost the {TASK} placeholder"
  assert_no_grep "@@" "$brief" "ship brief leaked an unexpanded template slot"
  ASSERTIONS=$((ASSERTIONS + 6))

  brief=$(<"$OUT/br-ship-herdr.briefpath")
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "--herdr-lab ship brief lost the hard safety contract"
  assert_grep 'Forbidden commands: direct `herdr server stop`' "$brief" \
    "--herdr-lab ship brief lost the forbidden server-global command list"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "--herdr-lab ship brief retained the unguarded declaration"
  ASSERTIONS=$((ASSERTIONS + 3))

  # The quoting half of the contract, on the root whose path carries an apostrophe.
  local helper
  helper=$(printf '%s' "$BR_FOREIGN/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  brief=$(<"$OUT/br-scout-herdr.briefpath")
  assert_grep "HERDR_LAB_HELPER='$helper'" "$brief" \
    "--herdr-lab brief lost the shell-quoted absolute helper path"
  ASSERTIONS=$((ASSERTIONS + 1))

  brief=$(<"$OUT/br-scout.briefpath")
  assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "unguarded scout brief lost the loud Herdr declaration"
  assert_grep "SCOUT task" "$brief" "scout brief lost its scout declaration"
  ASSERTIONS=$((ASSERTIONS + 2))

  brief=$(<"$OUT/br-mate-noprojects.briefpath")
  assert_grep "You are a persistent second mate managed by the main firstmate." "$brief" \
    "charter lost its role declaration"
  assert_grep "[fm-from-firstmate]" "$brief" "charter lost the from-firstmate marker label"
  ASSERTIONS=$((ASSERTIONS + 2))
  pass "fm-brief.ps1: the isolation assertion, status protocol and Herdr contract survive in the PowerShell output"
}

test_brief_refusals_parity() {
  local label
  for label in br-err-mate-herdr br-err-noprojects-ship br-err-mate-no-list \
    br-err-noprojects-with-list br-err-exists br-err-unresolved-home \
    br-err-unresolved-state br-err-unresolved-data; do
    compare_case "$label"
  done
  # A refusal must leave nothing behind.
  assert_eq "$([ -e "$BR_ERR/data/e1/brief.md" ] && printf present || printf absent)" absent \
    "a rejected secondmate --herdr-lab wrote a brief"
  assert_eq "$([ -e "$BR_ERR/data/e3/brief.md" ] && printf present || printf absent)" absent \
    "a rejected project-less secondmate wrote a brief"
  assert_eq "$(<"$BR_ERR/data/e5/brief.md")" 'already here' \
    "the overwrite refusal clobbered the existing brief"
  pass "fm-brief.ps1: every refusal matches the oracle and writes nothing"
}

test_brief_missing_id_refuses() {
  local shrc psrc
  shrc=$(<"$OUT/br-err-no-id.sh.rc"); psrc=$(<"$OUT/br-err-no-id.ps.rc")
  assert_eq "$psrc" "$shrc" "br-err-no-id: exit code differs"
  assert_eq "$(<"$OUT/br-err-no-id.ps.out")" "$(<"$OUT/br-err-no-id.sh.out")" \
    "br-err-no-id: stdout differs"
  # Divergence of record: bash reports its own unbound-variable text.
  case "$(<"$OUT/br-err-no-id.ps.err")" in
    *error*) ASSERTIONS=$((ASSERTIONS + 1)) ;;
    *) fail "br-err-no-id: the PowerShell twin refused silently" ;;
  esac
  pass "fm-brief.ps1: a missing task id refuses with the oracle's exit code"
}

test_assertion_floor() {
  [ "$ASSERTIONS" -ge "$MIN_ASSERTIONS" ] \
    || fail "only $ASSERTIONS assertions ran; expected at least $MIN_ASSERTIONS (cases stopped being exercised)"
  pass "fm-brief differential: $ASSERTIONS assertions compared against the bash oracle"
}

progress 'phase 3: joining and comparing'
test_project_mode_parity
test_project_mode_missing_argument
test_ensure_agents_md_parity
test_brief_help_is_byte_identical
test_generated_briefs_are_byte_identical
test_safety_contract_survives_in_powershell_output
test_brief_refusals_parity
test_brief_missing_id_refuses
test_assertion_floor
