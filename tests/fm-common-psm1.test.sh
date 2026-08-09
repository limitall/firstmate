#!/usr/bin/env bash
# Behavior test for bin/fm-common.psm1 - the PowerShell foundation module.
#
# This is a DIFFERENTIAL test: it drives the bash contract and its PowerShell
# twin with the same inputs and asserts they agree. Bash is the oracle. During
# the PowerShell conversion (docs/powershell-port.md) both worlds read and
# write the same durable records, so the interop assertions here - a meta file
# written by PowerShell read back through bin/fm-backend.sh's own fm_meta_get -
# are as load-bearing as the unit assertions.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7.
#
# Windows note for later conversion authors: PowerShell cannot resolve MSYS
# paths (verified - [System.IO.File] reads /tmp/x as C:\tmp\x), so every path
# handed to pwsh here, INCLUDING the module path for Import-Module, is
# converted with cygpath -w first. That is the same rule bin/fm-common.psm1
# enforces internally through ConvertTo-FmNativePath.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-common-psm1)

# Path handoff to pwsh needs native form; cygpath provides it on Windows and
# the paths are already native everywhere else.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

MOD=$(to_native "$ROOT/bin/fm-common.psm1")
[ -f "$ROOT/bin/fm-common.psm1" ] || fail "bin/fm-common.psm1 is missing"

ps_run() {  # <powershell-body>; the module is pre-imported
  pwsh -NoProfile -Command "Import-Module '$MOD' -Force; $1" 2>&1
}

# assert_same <label> <expected(bash oracle)> <actual(powershell)>
#
# Results are recorded in plain shell variables and the environment-scoped
# cases below use PREFIX ASSIGNMENTS (`FM_HOME=x case ...`) rather than
# `( ... )` subshells. Both choices are deliberate: a subshell cannot report a
# failure back to the parent's counters, and it also fires the inherited EXIT
# trap from tests/lib.sh. A bookkeeping scheme that can lose a failure is
# worse than no bookkeeping, because the suite then certifies work it never
# checked.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""
assert_same() {
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

# --- fm_meta_get contract (bin/fm-backend.sh) --------------------------------
# Last matching line wins; value is everything after the FIRST '='; a missing
# file yields empty with exit 0. All three are relied on by callers.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh" >/dev/null 2>&1 || true

META="$TMP_ROOT/sample.meta"
printf 'window=first\nharness=claude\nwindow=second\nweird=a=b=c\nempty=\nnoequals\n' > "$META"
META_N=$(to_native "$META")
for key in window harness weird empty missing; do
  assert_same "fm_meta_get($key)" \
    "$(fm_meta_get "$META" "$key")" \
    "$(ps_run "Write-FmRaw (Get-FmMetaValue '$META_N' '$key')")"
done

absent_value=$(fm_meta_get "$TMP_ROOT/no-such.meta" window); absent_rc=$?
assert_same "fm_meta_get(absent) value" "$absent_value" \
  "$(ps_run "Write-FmRaw (Get-FmMetaValue '$(to_native "$TMP_ROOT/no-such.meta")' 'window')")"
assert_same "fm_meta_get(absent) exit status" "0" "$absent_rc"

# --- home/state/data resolution contract -------------------------------------
# The exact block every bash entrypoint opens with, including the two
# subtleties: FM_HOME beats FM_ROOT_OVERRIDE which beats the derived root, and
# every override uses `:-` semantics so an EMPTY value falls through.
BIN_N=$(to_native "$ROOT/bin")

resolve_bash() {
  local script_dir="$ROOT/bin" fm_root fm_home state data
  fm_root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  fm_home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$fm_root}}"
  state="${FM_STATE_OVERRIDE:-$fm_home/state}"
  data="${FM_DATA_OVERRIDE:-$fm_home/data}"
  printf '%s|%s|%s|%s' "$fm_root" "$fm_home" "$state" "$data"
}

resolve_ps() {
  ps_run "\$c = Get-FmContext '$BIN_N'; Write-FmRaw ((ConvertTo-FmPosixPath \$c.Root) + '|' + (ConvertTo-FmPosixPath \$c.Home) + '|' + (ConvertTo-FmPosixPath \$c.State) + '|' + (ConvertTo-FmPosixPath \$c.Data))"
}

# The two worlds can name one location differently and both be right: MSYS
# mounts /tmp onto C:\Users\<u>\AppData\Local\Temp, so bash keeps the /tmp
# alias while the module resolves the physical path. Canonicalizing both sides
# to native form before comparison is therefore comparing LOCATIONS, which is
# what the contract is about - and it deliberately does not soften what these
# cases actually prove, because WHICH directory each override selects still has
# to match exactly. Declared here rather than applied silently.
canon_paths() {  # <a|b|c|d> -> same list, each element in native form
  local field out=''
  local IFS='|'
  for field in $1; do
    out="${out}|$(to_native "$field")"
  done
  printf '%s' "${out#|}"
}

resolution_case() {
  assert_same "resolve: $1" "$(canon_paths "$(resolve_bash)")" "$(canon_paths "$(resolve_ps)")"
}

# Prefix assignments scope each override to exactly one call and are exported
# to the pwsh child for that call only, with no subshell (see assert_same).
# The base state is unset, asserted here so a leaked variable from the ambient
# environment cannot quietly change what these cases prove.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

resolution_case "no overrides"
FM_HOME="$TMP_ROOT/h1" resolution_case "FM_HOME only"
FM_ROOT_OVERRIDE="$TMP_ROOT/r1" resolution_case "FM_ROOT_OVERRIDE only"
FM_HOME="$TMP_ROOT/h2" FM_ROOT_OVERRIDE="$TMP_ROOT/r2" resolution_case "FM_HOME beats FM_ROOT_OVERRIDE"
FM_HOME="$TMP_ROOT/h3" FM_STATE_OVERRIDE="$TMP_ROOT/s3" FM_DATA_OVERRIDE="$TMP_ROOT/d3" resolution_case "STATE and DATA overrides win"
FM_HOME= resolution_case "empty FM_HOME falls through"

# --- file primitives: LF and UTF-8 discipline --------------------------------
FILES="$TMP_ROOT/files"; mkdir -p "$FILES"
FILES_N=$(to_native "$FILES")

ps_run "Set-FmFileText '$FILES_N\\a.txt' 'line1'; Add-FmFileLine '$FILES_N\\a.txt' 'line2'" >/dev/null
assert_same "Set-FmFileText + Add-FmFileLine emit LF" \
  "$(printf 'line1\nline2\n' | od -c)" "$(od -c "$FILES/a.txt")"

ps_run "[void](Set-FmFileTextAtomic '$FILES_N\\b.txt' ('x' + [char]10 + 'y'))" >/dev/null
assert_same "Set-FmFileTextAtomic emits LF" \
  "$(printf 'x\ny\n' | od -c)" "$(od -c "$FILES/b.txt")"

# REWRITE over an existing file, asserted separately from the create case
# because they took different code paths and only the create path was covered
# here originally. That gap hid a real defect: the rewrite branch called
# [System.IO.File]::Replace with a $null backup argument, which PowerShell binds
# as the empty string, so every write to an already-existing path failed - and
# failed SILENTLY, returning $false instead of throwing. It was found in
# production use (a state machine whose every transition rewrites its record was
# completely inert), not by this suite. A fresh-fixture test cannot see it, so
# the second and third writes below are the point.
rewrite_result=$(ps_run "
  \$p = '$FILES_N\\rewrite.txt'
  \$r1 = Set-FmFileTextAtomic -Path \$p -Text 'one'
  \$r2 = Set-FmFileTextAtomic -Path \$p -Text 'two'
  \$r3 = Set-FmFileTextAtomic -Path \$p -Text 'three'
  Write-FmRaw ((\$r1.ToString()) + ',' + (\$r2.ToString()) + ',' + (\$r3.ToString()))")
assert_same "Set-FmFileTextAtomic succeeds when rewriting an existing file" \
  "True,True,True" "$rewrite_result"
assert_same "Set-FmFileTextAtomic actually replaces the content on rewrite" \
  "three" "$(cat "$FILES/rewrite.txt" 2>/dev/null | tr -d '\n')"
assert_same "atomic rewrite leaves no temp files behind" \
  "" "$(find "$FILES" -name '.*fm-tmp*' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
# Checks for TEMP files specifically rather than listing the whole directory:
# the original compared the full listing, so it broke the moment a legitimate
# new fixture file appeared. An assertion that fails for the wrong reason
# teaches nothing and trains the reader to edit it instead of read it.
assert_same "atomic publish leaves no temp files behind" \
  "" "$(find "$FILES" -maxdepth 1 -name '.*fm-tmp*' 2>/dev/null | tr '\n' ' ')"

ps_run "Set-FmFileText '$FILES_N\\crlf.txt' ('p' + [char]13 + [char]10 + 'q')" >/dev/null
assert_same "CRLF in input is normalized to LF on write" \
  "$(printf 'p\nq\n' | od -c)" "$(od -c "$FILES/crlf.txt")"

# The composer glyph vocabulary and the U+2063 operational-input marker must
# survive a PowerShell write; without an explicit UTF-8 console encoding they
# degrade to '?' (verified on a real Windows host).
ps_run "Set-FmFileText '$FILES_N\\utf8.txt' ([char]0x276F + ' ' + [char]0x2063 + 'x')" >/dev/null
assert_same "multibyte glyphs survive a PowerShell write" \
  "$(printf '\xe2\x9d\xaf \xe2\x81\xa3x\n' | od -c)" "$(od -c "$FILES/utf8.txt")"

# --- cross-world interop -----------------------------------------------------
# A meta record written by PowerShell must read identically through the bash
# reader, because both worlds address the same durable state during the port.
ps_run "\$m=[ordered]@{window='fm:w1';harness='claude';worktree='/f/wt/x'}; [void](Set-FmMeta '$FILES_N\\r.meta' \$m)" >/dev/null
assert_same "PS-written meta reads under bash: window" "fm:w1" "$(fm_meta_get "$FILES/r.meta" window)"
assert_same "PS-written meta reads under bash: worktree" "/f/wt/x" "$(fm_meta_get "$FILES/r.meta" worktree)"
assert_same "PS-written meta reads under bash: key order preserved" \
  "window harness worktree" "$(cut -d= -f1 "$FILES/r.meta" | tr '\n' ' ' | sed 's/ $//')"

# --- external process handling ------------------------------------------------
# PowerShell's own operator merges native stderr into stdout under redirection;
# Invoke-FmTool must keep all three channels distinct.
if command -v cmd >/dev/null 2>&1 || [ -x /c/Windows/System32/cmd.exe ]; then
  assert_same "Invoke-FmTool separates stdout, stderr, and exit code" "7|OUT|ERR" \
    "$(ps_run "\$r = Invoke-FmTool 'cmd.exe' @('/c','echo OUT& echo ERR 1>&2& exit 7'); Write-FmRaw (\$r.ExitCode.ToString() + '|' + \$r.StdOut.Trim() + '|' + \$r.StdErr.Trim())")"
fi

# --- exit-code discipline ------------------------------------------------------
# Distinct non-zero codes are interface, not noise (docs/powershell-port.md).
ps_run "Exit-FmScript 8" >/dev/null 2>&1
assert_same "Exit-FmScript propagates its code" "8" "$?"

ps_run "Invoke-FmMain { throw 'boom' } -UnexpectedCode 70" >/dev/null 2>&1
assert_same "Invoke-FmMain converts an escaped exception to its declared code" "70" "$?"

ps_run "Invoke-FmMain { Exit-FmScript 3 }" >/dev/null 2>&1
assert_same "Invoke-FmMain lets an explicit exit through unchanged" "3" "$?"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-common.psm1 differs from its bash contract (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass: the assertion
# count is itself asserted, so a future refactor that drops cases (or a
# bookkeeping regression like the one this file's history records) fails loudly
# instead of certifying an empty run.
MIN_ASSERTIONS=28
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-common.psm1 matches the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-common-psm1.test.sh: all assertions passed\n'
