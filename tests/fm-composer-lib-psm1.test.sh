#!/usr/bin/env bash
# Behavior test for bin/fm-composer-lib.psm1 - the PowerShell twin of the ONE
# fleet-wide composer-content classifier (bin/fm-composer-lib.sh).
#
# This is a DIFFERENTIAL test: every case drives the bash function and the
# PowerShell function with byte-identical input and asserts byte-identical
# output. BASH IS THE ORACLE - no expectation is hard-coded here, so a case can
# never quietly encode what the author believed instead of what the shipped
# classifier does.
#
# Why this file matters more than a routine port test: the verdicts it compares
# gate the away-mode escalation injector. A PowerShell twin that answers "empty"
# where bash answers "unknown" would type an escalation into a dead login shell.
# The two language trees must not be allowed to drift apart the way the four
# adapters drifted before bin/fm-composer-lib.sh consolidated them.
#
# Fixtures are built from printf escapes rather than literal glyphs so this file
# stays pure ASCII: the whole point of several cases is that U+276F and U+203A
# survive intact, and a fixture that had itself been mangled by an editor or a
# patch tool would silently weaken exactly those cases.
#
# TRANSPORT. All cases of a batch are written to a file, evaluated by ONE pwsh
# driver, and returned one result per record - so failures stay individually
# attributable while a ~360ms process spawn is paid three times instead of a
# hundred. Fields are separated by 0x01 and records by 0x02, two bytes that
# appear in no fixture, which means every value crosses the boundary as RAW
# BYTES: an ESC, a TAB, an embedded newline and a multibyte glyph all arrive
# unencoded, so the comparison is byte-exact by construction AND the results
# coming back through pwsh's stdout prove the UTF-8 console encoding at the same
# time. It is also fork-free on the bash side, where `printf` and `read` are
# builtins - see the ORACLE COST note below for why that matters here.
#
# ORACLE COST. An MSYS fork on this host costs orders of magnitude more than any
# work in this file, so the oracle is captured through a redirect plus the
# `read` builtin rather than `$( ... )`, and the two line-filter oracles
# (strip_ghost, strip_ansi) are computed for every single-line fixture in ONE
# awk/sed pass. That is a speed decision only: the values compared are exactly
# the values a bash caller would hold.
#
# Skips cleanly where pwsh is absent, so the suite stays green on macOS/Linux
# CI until those hosts install PowerShell 7.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pwsh >/dev/null 2>&1 || { echo "skip: pwsh not found (PowerShell 7 required)"; exit 0; }

# The oracle.
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-composer-psm1)

MOD="$ROOT/bin/fm-composer-lib.psm1"
COMMON="$ROOT/bin/fm-common.psm1"
[ -f "$MOD" ] || fail "bin/fm-composer-lib.psm1 is missing"
[ -f "$COMMON" ] || fail "bin/fm-common.psm1 is missing (this module builds on it)"

# PowerShell cannot resolve MSYS paths (.NET reads /tmp/x as C:\tmp\x), so every
# path handed to pwsh - INCLUDING the module path for Import-Module - is
# converted first. fm_test_native_path is a no-op off Windows.
MOD_N=$(fm_test_native_path "$MOD")
COMMON_N=$(fm_test_native_path "$COMMON")
CASES="$TMP_ROOT/cases.bin"
CASES_N=$(fm_test_native_path "$CASES")
DRIVER="$TMP_ROOT/driver.ps1"
DRIVER_N=$(fm_test_native_path "$DRIVER")
RESULTS="$TMP_ROOT/results.bin"
DRIVER_ERR="$TMP_ROOT/driver.err"
CAP="$TMP_ROOT/oracle.out"
GHOST_IN="$TMP_ROOT/ghost.in"
GHOST_OUT="$TMP_ROOT/ghost.out"
ANSI_IN="$TMP_ROOT/ansi.in"
ANSI_OUT="$TMP_ROOT/ansi.out"

LF=$'\n'
ESC=$(printf '\033')
GLYPH_CLAUDE=$(printf '\u276F')   # claude's agent prompt
GLYPH_CODEX=$(printf '\u203A')    # codex's agent prompt
IDLE_RE='^Type a message\.\.\.$'  # the pattern the herdr, orca and cmux adapters ship

# Whitespace boundary fixtures. Built ONCE here, in the ambient locale, so the
# BYTES are fixed for every batch below: the C-locale batch must reclassify the
# same bytes, not rebuild them under a locale that would encode them
# differently. The trim these probe is the one locale-dependent decision in this
# owner (bin/fm-composer-lib.psm1, Get-FmComposerTrimSet), and it is the
# difference between "empty, safe to inject into" and "pending, leave alone".
SP_NBSP=$(printf '\u00A0')      # trims under UTF-8, survives under C
SP_EM=$(printf '\u2003')        # trims under UTF-8, survives under C
SP_OGHAM=$(printf '\u1680')     # trims under UTF-8, survives under C
SP_NNBSP=$(printf '\u202F')     # trims under UTF-8, survives under C
SP_IDEO=$(printf '\u3000')      # trims under UTF-8, survives under C
SP_NEL=$(printf '\u0085')       # whitespace to .NET, NOT to bash, under EITHER
SP_ZWSP=$(printf '\u200B')      # whitespace to neither
SP_BOM=$(printf '\uFEFF')       # whitespace to neither

# --- assertion bookkeeping ---------------------------------------------------
#
# Results are recorded in plain shell variables, and every case is added from
# PARENT scope - never from inside a `( ... )` subshell, whose counter updates
# could not reach the parent and whose failures would therefore vanish into a
# false pass. The assertion COUNT is itself asserted at the end, so a suite that
# silently ran nothing cannot read as a pass either.
ASSERTIONS=0
FAILURES=0
FAILURE_TEXT=""

# assert_case <label> <expected(bash oracle)> <actual(powershell)>
# %q renders the invisible bytes these values are full of ($'\E[2m'), and is a
# builtin, so a failure message costs nothing on the passing path.
assert_case() {
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

# --- fork-free oracle capture ------------------------------------------------

ORACLE=''

# read_cap: slurp $CAP into ORACLE. `read -d ''` reads to NUL, i.e. the whole
# file, and returns non-zero at EOF while still assigning - hence `|| true`.
read_cap() {
  ORACLE=''
  IFS= read -r -d '' ORACLE < "$CAP" || true
}

# rstrip_lf: the call-site convention, stated rather than applied silently. The
# bash strip helpers are stdin filters whose awk/sed output always ends with a
# newline, and EVERY bash call site consumes them through `$( ... )`, which
# strips trailing newlines. The PowerShell twins return a string with no
# terminator. Comparing at that convention compares what the adapters actually
# hold, and it softens nothing else: every interior byte, ESC bytes and
# multibyte glyphs included, still has to match exactly.
rstrip_lf() {
  while [ "${ORACLE%"$LF"}" != "$ORACLE" ]; do ORACLE=${ORACLE%"$LF"}; done
}

# --- batch machinery ---------------------------------------------------------

LABELS=()
EXPECT=()
GHOST_IDX=()
ANSI_IDX=()

batch_reset() {
  : > "$CASES"
  : > "$GHOST_IN"
  : > "$ANSI_IN"
  LABELS=()
  EXPECT=()
  GHOST_IDX=()
  ANSI_IDX=()
}

# add_classify <label> <bordered> <content> <idle_re> <idle_case> <plain>
#
# All five arguments always reach the bash oracle, which is exactly equivalent
# to omitting the trailing ones: `${3:-}`, `${4:-sensitive}` and `${5:-$content}`
# each treat an EMPTY argument as an absent one. add_arity separately proves the
# PowerShell parameter defaults agree when arguments are genuinely omitted.
add_classify() {
  LABELS+=("$1")
  fm_composer_classify_content "$2" "$3" "$4" "$5" "$6" > "$CAP" 2>/dev/null
  read_cap
  EXPECT+=("$ORACLE")
  printf 'classify\001%s\001%s\001%s\001%s\001%s\002' "$2" "$3" "$4" "$5" "$6" >> "$CASES"
}

# add_arity <label> <arg>...: the same function with only the arguments a real
# caller would pass, so the PowerShell parameter defaults are exercised rather
# than bypassed by always-explicit empties.
add_arity() {
  local label=$1 a
  shift
  LABELS+=("$label")
  fm_composer_classify_content "$@" > "$CAP" 2>/dev/null
  read_cap
  EXPECT+=("$ORACLE")
  printf 'arity' >> "$CASES"
  for a in "$@"; do printf '\001%s' "$a" >> "$CASES"; done
  printf '\002' >> "$CASES"
}

# add_ghost / add_ansi <label> <styled-text>
#
# A single-line fixture is queued for the one bulk pass (see ORACLE COST); a
# fixture containing its own newline cannot share that pass, because the filter
# treats newlines as record separators, so it pays for its own call.
add_ghost() {
  LABELS+=("$1")
  EXPECT+=('')
  printf 'ghost\001%s\002' "$2" >> "$CASES"
  case $2 in
    *"$LF"*)
      printf '%s\n' "$2" | fm_composer_strip_ghost > "$CAP"
      read_cap
      rstrip_lf
      EXPECT[$(( ${#EXPECT[@]} - 1 ))]=$ORACLE
      ;;
    *)
      printf '%s\n' "$2" >> "$GHOST_IN"
      GHOST_IDX+=("$(( ${#EXPECT[@]} - 1 ))")
      ;;
  esac
}

add_ansi() {
  LABELS+=("$1")
  EXPECT+=('')
  printf 'ansi\001%s\002' "$2" >> "$CASES"
  case $2 in
    *"$LF"*)
      printf '%s\n' "$2" | fm_composer_strip_ansi > "$CAP"
      read_cap
      rstrip_lf
      EXPECT[$(( ${#EXPECT[@]} - 1 ))]=$ORACLE
      ;;
    *)
      printf '%s\n' "$2" >> "$ANSI_IN"
      ANSI_IDX+=("$(( ${#EXPECT[@]} - 1 ))")
      ;;
  esac
}

# add_idle <label> <content> <idle_re> <idle_case>
add_idle() {
  local res
  if fm_composer_idle_matches "$2" "$3" "$4" 2>/dev/null; then res=match; else res=no-match; fi
  LABELS+=("$1")
  EXPECT+=("$res")
  printf 'idle\001%s\001%s\001%s\002' "$2" "$3" "$4" >> "$CASES"
}

# add_codepoint <label> <space-separated hex code points> <bash-built expected>
# Proves the PowerShell side BUILDS and WRITES the glyph vocabulary correctly,
# not merely that it echoes back what bash sent it.
add_codepoint() {
  LABELS+=("$1")
  EXPECT+=("$3")
  printf 'codepoint\001%s\002' "$2" >> "$CASES"
}

# resolve_bulk: fill in the queued line-filter expectations with one pass each.
resolve_bulk() {
  local i line
  if [ "${#GHOST_IDX[@]}" -gt 0 ]; then
    fm_composer_strip_ghost < "$GHOST_IN" > "$GHOST_OUT"
    i=0
    while IFS= read -r line; do
      EXPECT[${GHOST_IDX[$i]}]=$line
      i=$((i + 1))
    done < "$GHOST_OUT"
    [ "$i" -eq "${#GHOST_IDX[@]}" ] \
      || fail "ghost bulk oracle returned $i lines for ${#GHOST_IDX[@]} single-line fixtures"
  fi
  if [ "${#ANSI_IDX[@]}" -gt 0 ]; then
    fm_composer_strip_ansi < "$ANSI_IN" > "$ANSI_OUT"
    i=0
    while IFS= read -r line; do
      EXPECT[${ANSI_IDX[$i]}]=$line
      i=$((i + 1))
    done < "$ANSI_OUT"
    [ "$i" -eq "${#ANSI_IDX[@]}" ] \
      || fail "ansi bulk oracle returned $i lines for ${#ANSI_IDX[@]} single-line fixtures"
  fi
}

# batch_run <run-label>: drive every queued case through ONE pwsh, then assert
# each result against its oracle. A driver that died halfway would return fewer
# records than there are cases, which is why the count is asserted too -
# otherwise a crash would read as a shorter, still-passing run.
batch_run() {
  local run=$1 idx got seen=0
  resolve_bulk
  if ! pwsh -NoProfile -File "$DRIVER_N" > "$RESULTS" 2> "$DRIVER_ERR"; then
    fail "$run: the PowerShell case driver exited non-zero"$'\n'"$(cat "$DRIVER_ERR")"
  fi
  # A clean run is also a SILENT run: a module warning (an unapproved verb, a
  # shadowed command) would surface here and must not be tolerated.
  [ ! -s "$DRIVER_ERR" ] || fail "$run: the PowerShell driver wrote to stderr"$'\n'"$(cat "$DRIVER_ERR")"
  while IFS=$'\001' read -r -d $'\002' idx got; do
    case $idx in
      ''|*[!0-9]*) continue ;;
    esac
    assert_case "$run: ${LABELS[$idx]}" "${EXPECT[$idx]}" "$got"
    seen=$((seen + 1))
  done < "$RESULTS"
  [ "$seen" -eq "${#LABELS[@]}" ] \
    || fail "$run: driver returned $seen results for ${#LABELS[@]} cases"
}

# --- the PowerShell driver ---------------------------------------------------
# Quoted here-doc: bash expands nothing in it, so the PowerShell source is
# byte-exact. The module and case paths arrive through the environment rather
# than through interpolation, which keeps every quoting hazard out of the file.
cat > "$DRIVER" <<'PS1'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module $env:FM_PSM1 -Force

$FS = [char]1
$RS = [char]2

$text = [System.IO.File]::ReadAllText($env:FM_CASES, [System.Text.Encoding]::UTF8)
$out = [System.Text.StringBuilder]::new()
$index = -1

foreach ($record in $text.Split($RS)) {
    if ($record -ceq '') { continue }
    $index++
    $f = $record.Split($FS)
    $result = ''
    try {
        switch ($f[0]) {
            'classify' {
                $result = Get-FmComposerContentState `
                    -Bordered $f[1] -Content $f[2] -IdleRegex $f[3] `
                    -IdleCase $f[4] -PlainContent $f[5]
            }
            'arity' {
                # Positional, with only the arguments the case supplied: this is
                # what proves the PowerShell parameter defaults reproduce bash's
                # ${n:-default} arms rather than being papered over by callers
                # that always pass explicit empties.
                switch ($f.Count) {
                    3 { $result = Get-FmComposerContentState $f[1] $f[2] }
                    4 { $result = Get-FmComposerContentState $f[1] $f[2] $f[3] }
                    5 { $result = Get-FmComposerContentState $f[1] $f[2] $f[3] $f[4] }
                    6 { $result = Get-FmComposerContentState $f[1] $f[2] $f[3] $f[4] $f[5] }
                    default { $result = "BAD-ARITY:$($f.Count)" }
                }
            }
            'ghost' { $result = (Get-FmComposerRealText $f[1]).TrimEnd([char]10) }
            'ansi'  { $result = (Get-FmComposerPlainText $f[1]).TrimEnd([char]10) }
            'idle'  {
                if (Test-FmComposerIdleMatch -Content $f[1] -Pattern $f[2] -Case $f[3]) {
                    $result = 'match'
                } else {
                    $result = 'no-match'
                }
            }
            'codepoint' {
                $built = [System.Text.StringBuilder]::new()
                foreach ($cp in $f[1].Split(' ')) {
                    [void]$built.Append([char][Convert]::ToInt32($cp, 16))
                }
                $result = $built.ToString()
            }
            default { $result = "UNKNOWN-OP:$($f[0])" }
        }
    } catch {
        $result = "THREW:$($_.Exception.Message)"
    }
    [void]$out.Append($index).Append($FS).Append($result).Append($RS)
}

[Console]::Out.Write($out.ToString())
PS1

export FM_PSM1="$MOD_N" FM_CASES="$CASES_N"

# =============================================================================
# Batch 1 - the whole classifier surface at default settings.
# =============================================================================
batch_reset

# --- Safety fix: a bare shell prompt is NOT an empty agent composer ----------
# The load-bearing contract (task fm-composer-shellglyph-safety). A pane whose
# agent exited to a login shell must never read as a ready-to-inject composer.
for g in '>' '$' '%' '#'; do
  add_classify "bare shell glyph '$g' is unknown" 0 "$g" '' '' ''
done
add_classify "bare shell prompt carrying a command is not empty" 0 '$ ls -la' '' '' ''
add_classify "bare 'user@host \$' prompt is not empty" 0 'user@host $' '' '' ''

# --- Preserved: the same glyph inside a composer box is the harness prompt ---
for g in '>' '$' '%' '#'; do
  add_classify "bordered shell glyph '$g' is empty" 1 "$g" '' '' ''
done

# --- Agent glyphs are empty either way --------------------------------------
add_classify "bare claude glyph is empty" 0 "$GLYPH_CLAUDE" '' '' ''
add_classify "bare codex glyph is empty" 0 "$GLYPH_CODEX" '' '' ''
add_classify "bordered claude glyph is empty" 1 "$GLYPH_CLAUDE" '' '' ''
add_classify "bordered codex glyph is empty" 1 "$GLYPH_CODEX" '' '' ''

# --- The ghost-stripped-to-nothing route judges on plain_content ------------
for p in '$' 'user@host $' 'Working...'; do
  add_classify "stripped unbordered '$p' stays unknown" 0 '' '' sensitive "$p"
done
add_classify "stripped unbordered claude glyph stays empty" 0 '' '' sensitive "$GLYPH_CLAUDE"
add_classify "stripped unbordered codex glyph stays empty" 0 '' '' sensitive "$GLYPH_CODEX"
add_classify "stripped unbordered glyph WITH a trailing space is unknown" 0 '' '' sensitive "$GLYPH_CLAUDE "
add_classify "empty plain_content falls back to content" 0 '' '' sensitive ''
add_classify "plain_content is ignored when bordered" 1 '' '' sensitive '$'
add_classify "plain_content is ignored when content is non-empty" 0 "$GLYPH_CLAUDE" '' sensitive 'zzz'

# --- Empty, whitespace, and absent are three different verdicts --------------
add_classify "empty bare content is empty" 0 '' '' '' ''
add_classify "empty bordered content is empty" 1 '' '' '' ''
add_classify "all-whitespace bare content is empty" 0 '   ' '' '' ''
add_classify "all-whitespace bordered content is empty" 1 '   ' '' '' ''
add_classify "a TAB-only row is empty" 0 "$(printf '\t')" '' '' ''
add_classify "whitespace-padded claude glyph is pending, not empty" 0 "  $GLYPH_CLAUDE  " '' '' ''
add_classify "whitespace-padded glyph stays pending when bordered" 1 "  $GLYPH_CLAUDE  " '' '' ''

# --- The [[:space:]] trim boundary, at the ambient (UTF-8) locale ------------
# bash resolves [[:space:]] against LC_CTYPE, so these verdicts are locale
# decisions, not constants - which is exactly why they are asserted rather than
# assumed. NEL, ZWSP and BOM are the near-misses: .NET calls U+0085 whitespace
# and bash does not, so a twin that reached for String.Trim() with no arguments
# would pass every other case here and fail this one.
add_classify "U+00A0 NBSP alone" 1 "$SP_NBSP" '' '' ''
add_classify "U+2003 EM SPACE alone" 1 "$SP_EM" '' '' ''
add_classify "U+1680 OGHAM SPACE MARK alone" 1 "$SP_OGHAM" '' '' ''
add_classify "U+202F NARROW NBSP alone" 1 "$SP_NNBSP" '' '' ''
add_classify "U+3000 IDEOGRAPHIC SPACE alone" 1 "$SP_IDEO" '' '' ''
add_classify "U+0085 NEL alone (not bash whitespace)" 1 "$SP_NEL" '' '' ''
add_classify "U+200B ZWSP alone (whitespace to neither)" 1 "$SP_ZWSP" '' '' ''
add_classify "U+FEFF alone (whitespace to neither)" 1 "$SP_BOM" '' '' ''
add_classify "claude glyph then NBSP" 0 "$GLYPH_CLAUDE$SP_NBSP" '' '' ''
add_classify "claude glyph then NEL" 0 "$GLYPH_CLAUDE$SP_NEL" '' '' ''
add_classify "NBSP-padded real text" 1 "$SP_NBSP deploy now$SP_NBSP" '' '' ''
add_classify "NBSP around the idle placeholder" 1 "${SP_NBSP}Type a message...$SP_NBSP" "$IDLE_RE" '' ''

# --- Zero-width characters must not be IGNORED by a comparison --------------
# .NET's culture-sensitive comparison treats U+200B and U+FEFF as ignorable, so
# under -ceq / -ccontains a zero-width prefix would make these rows equal to the
# bare glyph they are not - taking the shell-glyph arm and answering 'empty',
# i.e. "safe to inject", on rows bash calls pending. These pin the ordinal
# comparison discipline that prevents it.
for zw_label in ZWSP BOM; do
  case $zw_label in ZWSP) zw=$SP_ZWSP ;; *) zw=$SP_BOM ;; esac
  add_classify "$zw_label before a bordered shell glyph is not the glyph" 1 "$zw>" '' '' ''
  add_classify "$zw_label before a bare shell glyph is not the glyph" 0 "$zw>" '' '' ''
  add_classify "$zw_label before an agent glyph is not the glyph" 0 "$zw$GLYPH_CLAUDE" '' '' ''
  add_classify "$zw_label as stripped-row plain content is not an agent glyph" 0 '' '' sensitive "$zw$GLYPH_CLAUDE"
  add_classify "$zw_label after an agent glyph still reads as content" 0 "$GLYPH_CLAUDE$zw" '' '' ''
done

# --- Glyph stripping: the two tiers, and the boundary between them -----------
# '>' alone is a dead shell (unknown), but '> ' loses BOTH characters to the
# glyph-plus-space arm and reads empty. That asymmetry is real, and a twin that
# collapsed the two tiers would silently change it.
add_classify "bare '> ' (glyph plus space) is empty" 0 '> ' '' '' ''
add_classify "bare '\$ ' (glyph plus space) is empty" 0 '$ ' '' '' ''
add_classify "claude glyph plus space is empty" 0 "$GLYPH_CLAUDE " '' '' ''
add_classify "codex glyph plus space is empty" 0 "$GLYPH_CODEX " '' '' ''
add_classify "claude glyph plus TAB is empty" 0 "$(printf '\u276F\t')" '' '' ''
add_classify "doubled shell glyph '>>' is pending" 0 '>>' '' '' ''
add_classify "doubled claude glyph is pending" 0 "$GLYPH_CLAUDE$GLYPH_CLAUDE" '' '' ''

# --- The bordered flag is a STRING comparison against "1" -------------------
add_classify "bordered='' reads as not bordered" '' '>' '' '' ''
add_classify "bordered='yes' reads as not bordered" 'yes' '>' '' '' ''
add_classify "bordered='01' reads as not bordered" '01' '>' '' '' ''
add_classify "bordered='' still leaves an agent glyph empty" '' "$GLYPH_CLAUDE" '' '' ''

# --- Idle placeholder, before and after glyph stripping ---------------------
add_classify "grok idle placeholder is empty" 1 'Type a message...' "$IDLE_RE" '' ''
add_classify "idle placeholder after an agent glyph is empty" 0 "$GLYPH_CLAUDE Type a message..." "$IDLE_RE" '' ''
add_classify "idle placeholder without a regex is just text" 1 'Type a message...' '' '' ''
add_classify "unbordered idle placeholder is empty" 0 'Type a message...' "$IDLE_RE" '' ''
add_classify "case-variant placeholder stays pending by default" 1 'type a message...' "$IDLE_RE" '' ''
add_classify "explicitly insensitive placeholder is empty" 1 'type a message...' "$IDLE_RE" insensitive ''
add_classify "idle_case 'SENSITIVE' falls through to sensitive" 1 'Type a message...' "$IDLE_RE" SENSITIVE ''
add_classify "idle_case 'INSENSITIVE' falls through to sensitive" 1 'type a message...' "$IDLE_RE" INSENSITIVE ''
add_classify "insensitive placeholder after a glyph is empty" 0 "$GLYPH_CLAUDE TYPE A MESSAGE..." "$IDLE_RE" insensitive ''
add_classify "an invalid idle regex reads as no match" 1 'x' '[' '' ''

# --- Real text is pending ---------------------------------------------------
add_classify "claude glyph plus text is pending" 0 "$GLYPH_CLAUDE fix findings 1 and 3" '' '' ''
add_classify "bordered '> text' is pending" 1 '> deploy staging now' '' '' ''
add_classify "a popup argument-hint fill is pending" 1 '/compact compaction instructions' '' '' ''
add_classify "CJK text is pending" 1 "$(printf '\u4fee\u590d\u767b\u5f55\u95ee\u9898')" '' '' ''
add_classify "emoji text is pending" 1 "$(printf 'fix the bug \U0001F527')" '' '' ''
add_classify "multi-line content is pending" 0 "$(printf 'a\nb')" '' '' ''
add_classify "a multi-line idle match on the second line is empty" 1 "$(printf 'a\n$')" '^\$$' '' ''
add_classify "raw ESC bytes in content are pending" 1 "${ESC}[2mx" '' '' ''

# --- Arity: the PowerShell defaults reproduce bash's ${n:-default} arms ------
add_arity "arity 2: bare shell glyph" 0 '>'
add_arity "arity 3: idle regex only" 1 'Type a message...' "$IDLE_RE"
add_arity "arity 4: explicit idle case" 1 'type a message...' "$IDLE_RE" insensitive
add_arity "arity 5: plain_content" 0 '' '' sensitive "$GLYPH_CLAUDE"

# --- Get-FmComposerRealText: dim/faint (claude, codex) ----------------------
add_ghost "dim run is dropped, prompt glyph survives" \
  "$GLYPH_CLAUDE ${ESC}[2mWhat is the largest country by area?${ESC}[0m"
add_ghost "normal-intensity text is kept verbatim" "$GLYPH_CLAUDE real human text"
add_ghost "bold (SGR 1) is normal intensity, not dim" "${ESC}[1mbold typed${ESC}[0m"
add_ghost "dim combined with a colour in one sequence" "$GLYPH_CLAUDE ${ESC}[2;37mpredicted${ESC}[0m"
add_ghost "ESC[22m ends a dim run mid-row" "${ESC}[2mghost${ESC}[22mREALTAIL"
add_ghost "reset-then-dim reads as dim" "keep${ESC}[0;2mdrop${ESC}[0m"
add_ghost "real text plus a trailing ghost completion" \
  "$GLYPH_CLAUDE deploy${ESC}[2m the staging environment now${ESC}[0m"
add_ghost "a multibyte glyph inside a dim run drops whole" "${ESC}[2m$GLYPH_CLAUDE ghost${ESC}[0mX"
add_ghost "CJK and emoji survive around a dim run" \
  "${ESC}[2m$(printf '\u4fee\u590d')${ESC}[0m$(printf ' fix \U0001F527')"

# --- Get-FmComposerRealText: the `2` payload selector is not the dim attribute
add_ghost "8-bit colour payload 2 is kept" "${ESC}[38;5;2mgreen typed${ESC}[0m"
add_ghost "bright truecolor payload 2 is kept" "${ESC}[38;2;224;222;244mtruecolor typed${ESC}[0m"
add_ghost "background truecolor payload is kept" "${ESC}[48;2;4;5;6mbackground typed${ESC}[0m"
add_ghost "underline colour payload 2 is kept" "${ESC}[58;5;2munderline-color typed${ESC}[0m"
add_ghost "bright colon truecolor is kept" "${ESC}[38:2::224:222:244mcolon truecolor typed${ESC}[0m"
add_ghost "colon underline SGR neither leaks nor dims" "${ESC}[58::5::2mcolon underline typed${ESC}[0m"
add_ghost "a colon subparameter 2 is not dim" "${ESC}[4:2mnot dim underline${ESC}[0m"
add_ghost "a dark 256-colour foreground is NOT luminance-tested" "${ESC}[38;5;236mpalette${ESC}[0m"

# --- Get-FmComposerRealText: dark truecolor foreground (grok placeholder) ----
add_ghost "dark truecolor ghost is dropped" \
  "$GLYPH_CLAUDE ${ESC}[38;2;50;47;70mType a message...${ESC}[0m"
add_ghost "dark truecolor hint ended by SGR 39 is dropped" \
  "${ESC}[38;2;110;106;134mplaceholder hint text${ESC}[39m"
add_ghost "dark colon-truecolor ghost is dropped" \
  "$GLYPH_CLAUDE ${ESC}[38:2::86:82:110mmuted${ESC}[0m"
add_ghost "a base foreground colour ends a dark run" "${ESC}[38;2;10;10;10mD${ESC}[037mT"
add_ghost "a bright foreground (90-97) ends a dark run" "${ESC}[38;2;10;10;10mD${ESC}[92mT"
add_ghost "a dark truecolor run swallows the agent glyph too" \
  "${ESC}[38;2;50;47;70m$GLYPH_CLAUDE dark${ESC}[0m"
# The threshold test is `< lumamax`, so exactly 128 is NOT dark. Grey 128 has
# luminance exactly 128.000 because the coefficients sum to 1000.
add_ghost "luminance exactly at the threshold is kept" "${ESC}[38;2;128;128;128mgrey128${ESC}[0m"
add_ghost "luminance one below the threshold is dropped" "${ESC}[38;2;127;127;127mgrey127${ESC}[0m"

# --- Get-FmComposerRealText: malformed and boundary escape shapes -----------
# Every one of these was verified against the bash oracle before being written
# down; they are the shapes where a "reasonable" reimplementation quietly
# differs from awk.
add_ghost "ESC[00m does NOT end a dim run (string comparison)" "a${ESC}[2mghost${ESC}[00mtail"
add_ghost "ESC[022m does NOT end a dim run" "${ESC}[2mghost${ESC}[022mtail"
add_ghost "ESC[02m does NOT start a dim run" "a${ESC}[02mb"
add_ghost "ESC[m (no parameters) resets" "a${ESC}[2mghost${ESC}[mtail"
add_ghost "ESC[2;m resets on the empty parameter" "${ESC}[2mg${ESC}[2;mT"
add_ghost "ESC[;m resets on the empty parameter" "${ESC}[2mg${ESC}[;mT"
add_ghost "an unterminated CSI drops only the ESC byte" "a${ESC}[2"
add_ghost "an ESC not followed by [ drops only the ESC byte" "a${ESC}Xb"
add_ghost "a non-m final byte consumes the whole sequence" "a${ESC}[2Kb"
add_ghost "a private-parameter sequence is consumed" "a${ESC}[?25hb"
add_ghost "ESC[[2m: '[' is itself a CSI final byte" "a${ESC}[[2mb"
add_ghost "a truncated truecolor run (38;2 with no channels)" "${ESC}[38;2mX${ESC}[0mY"
add_ghost "SGR 38 with nothing after it" "${ESC}[38mX"
add_ghost "de-emphasis state resets at every row boundary" \
  "$(printf 'a\033[2mg\033[0m\nb\033[2mh')"
add_ghost "plain text with no escapes is unchanged" "just typed text"
add_ghost "empty input" ''

# --- Get-FmComposerPlainText: structural stripping keeps ghost text -----------
add_ansi "colon-form SGR and a private sequence are stripped whole" \
  "x${ESC}[38:2::1:2:3my${ESC}[0m${ESC}[?25hz"
add_ansi "ghost text is KEPT (structure, not content)" "$GLYPH_CLAUDE ${ESC}[2mghost${ESC}[0m"
add_ansi "box-drawing borders are untouched" "$(printf '\u256D\u2500\u2500\u256E')"
add_ansi "a non-m final byte is stripped too" "a${ESC}[2Kb"
add_ansi "an incomplete CSI is LEFT ALONE, ESC included" "a${ESC}["
add_ansi "a lone ESC is LEFT ALONE (unlike the ghost stripper)" "a${ESC}Xb"
add_ansi "8-bit colour is stripped" "${ESC}[38;5;2mgreen${ESC}[0m"
add_ansi "multi-row input is stripped per row" "$(printf 'a\033[1mb\033[0m\n\033[2mc\033[0md')"
add_ansi "empty input" ''

# --- Test-FmComposerIdleMatch: grep's per-line, zero-line semantics ---------
add_idle "an empty pattern never matches" 'abc' '' sensitive
add_idle "an empty pattern never matches empty content" '' '' sensitive
add_idle "empty content is ZERO lines, so ^\$ cannot match" '' '^$' sensitive
add_idle "a lone newline is ONE empty line, so ^\$ matches" "$LF" '^$' sensitive
add_idle "a trailing newline terminates rather than adds a line" "a$LF" '^$' sensitive
add_idle "the fleet idle pattern matches" 'Type a message...' "$IDLE_RE" sensitive
add_idle "the fleet idle pattern is case sensitive by default" 'TYPE A MESSAGE...' "$IDLE_RE" sensitive
add_idle "insensitive matching is opt-in" 'TYPE A MESSAGE...' "$IDLE_RE" insensitive
add_idle "ERE '.' matches one character" 'aXb' 'a.b' sensitive
add_idle "ERE '+' is a repetition operator" 'ab' 'a+b' sensitive
add_idle "ERE '{2}' is an interval, not a literal" 'aa' 'a{2}' sensitive
add_idle "an interval does not match its own literal spelling" 'a{2}' 'a{2}' sensitive
add_idle "an invalid pattern reads as no match" 'x' '[' sensitive
add_idle "a multi-line content matches on any line" "a$LF\$" '^\$$' sensitive
add_idle "a glyph-prefixed placeholder matches an unanchored pattern" \
  "$GLYPH_CLAUDE Type a message..." 'Type a message' sensitive

# --- The console encoding, proven end to end --------------------------------
# Every result above already crosses pwsh's stdout as raw UTF-8, so a broken
# console encoding would fail dozens of cases. This one names the contract
# explicitly and proves the PowerShell side BUILDS the glyphs correctly, rather
# than merely echoing bytes bash handed it: without fm-common's UTF-8 console
# encoding, [Console]::Out.Write of U+276F emits '?'.
add_codepoint "console encoding: PowerShell writes U+276F and U+203A intact" \
  "276F 203A" "$GLYPH_CLAUDE$GLYPH_CODEX"
add_codepoint "console encoding: the U+2063 operational marker survives too" \
  "2063 78" "$(printf '\u2063x')"

batch_run "default"

# =============================================================================
# Batch 2 - FM_COMPOSER_GHOST_LUMA_MAX, the one knob this owner reads.
#
# Both worlds inherit the same exported value: the bash twin passes it to awk
# with -v on every call and the PowerShell twin reads it per call, so a fixture
# that is ghost at one threshold and real text at another has to flip in both.
# =============================================================================
batch_reset
export FM_COMPOSER_GHOST_LUMA_MAX=250

add_ghost "luma 250: a normally-bright foreground now reads as ghost" \
  "${ESC}[38;2;224;222;244mbright typed${ESC}[0m"
add_ghost "luma 250: an even brighter foreground is still kept" \
  "${ESC}[38;2;254;254;254mwhite typed${ESC}[0m"
add_ghost "luma 250: the dim signal is unaffected by the threshold" \
  "keep${ESC}[2mdrop${ESC}[0m"
add_ghost "luma 250: the colon form honours the raised threshold" \
  "$GLYPH_CLAUDE ${ESC}[38:2::224:222:244mbright${ESC}[0m"

batch_run "luma=250"
unset FM_COMPOSER_GHOST_LUMA_MAX

batch_reset
export FM_COMPOSER_GHOST_LUMA_MAX=1

add_ghost "luma 1: even near-black stops reading as ghost" \
  "${ESC}[38;2;1;1;1mnear black typed${ESC}[0m"
add_ghost "luma 1: the dim signal still drops" "keep${ESC}[2mdrop${ESC}[0m"

batch_run "luma=1"
unset FM_COMPOSER_GHOST_LUMA_MAX

# =============================================================================
# Batch 4 - the SAME whitespace bytes under LC_ALL=C.
#
# Every one of these fixtures was built above, in the ambient UTF-8 locale, so
# only the classifier's locale changes here; rebuilding them under C would
# change the bytes and prove nothing. bash's [[:space:]] narrows to the six
# ASCII members, so the verdicts that read 'empty' in batch 1 must flip to
# 'pending' on BOTH sides. A PowerShell twin that hard-coded either set would
# pass one batch and fail the other.
#
# LC_ALL is exported so the bash oracle and the pwsh child see the same locale.
# It is set AFTER every fixture exists, and the ambient value is restored below.
# =============================================================================
batch_reset
FM_TEST_SAVED_LC_ALL=${LC_ALL-}
FM_TEST_HAD_LC_ALL=${LC_ALL+set}
export LC_ALL=C

add_classify "C locale: U+00A0 NBSP survives the trim" 1 "$SP_NBSP" '' '' ''
add_classify "C locale: U+2003 EM SPACE survives the trim" 1 "$SP_EM" '' '' ''
add_classify "C locale: U+1680 OGHAM SPACE survives the trim" 1 "$SP_OGHAM" '' '' ''
add_classify "C locale: U+202F NARROW NBSP survives the trim" 1 "$SP_NNBSP" '' '' ''
add_classify "C locale: U+3000 IDEOGRAPHIC SPACE survives the trim" 1 "$SP_IDEO" '' '' ''
add_classify "C locale: U+0085 NEL survives the trim" 1 "$SP_NEL" '' '' ''
add_classify "C locale: ASCII space still trims" 1 '   ' '' '' ''
add_classify "C locale: ASCII TAB still trims" 1 "$(printf '\t')" '' '' ''
add_classify "C locale: claude glyph then NBSP" 0 "$GLYPH_CLAUDE$SP_NBSP" '' '' ''
add_classify "C locale: claude glyph plus ASCII space still empty" 0 "$GLYPH_CLAUDE " '' '' ''
add_classify "C locale: the safety rule is unchanged" 0 '>' '' '' ''
add_classify "C locale: an agent glyph is still empty" 0 "$GLYPH_CLAUDE" '' '' ''

batch_run "LC_ALL=C"

# POSIX must resolve identically to C - the bash twin treats them as the same
# locale, and a twin that special-cased only 'C' would silently widen the trim.
batch_reset
export LC_ALL=POSIX
add_classify "POSIX locale: U+00A0 NBSP survives the trim" 1 "$SP_NBSP" '' '' ''
add_classify "POSIX locale: U+3000 IDEOGRAPHIC SPACE survives the trim" 1 "$SP_IDEO" '' '' ''
batch_run "LC_ALL=POSIX"

# An EMPTY LC_ALL falls through to LC_CTYPE, then to LANG - bash's own
# precedence, measured rather than assumed.
batch_reset
export LC_ALL='' LC_CTYPE='en_US.UTF-8'
add_classify "empty LC_ALL falls through to a UTF-8 LC_CTYPE" 1 "$SP_NBSP" '' '' ''
batch_run "LC_ALL= LC_CTYPE=en_US.UTF-8"
unset LC_CTYPE

if [ -n "$FM_TEST_HAD_LC_ALL" ]; then export LC_ALL="$FM_TEST_SAVED_LC_ALL"; else unset LC_ALL; fi

# =============================================================================
# Import hygiene - the two things a batch driver cannot observe about itself.
# =============================================================================

# A clean import is part of the contract: a warning here (an unapproved verb, a
# shadowed command) is a real finding, not noise.
import_out=$(pwsh -NoProfile -Command "Import-Module '$MOD_N' -Force" 2>&1)
import_rc=$?
assert_case "importing the module is silent" '' "$import_out"
assert_case "importing the module succeeds" 0 "$import_rc"

# The module must not evict a caller's own fm-common. A nested `Import-Module
# -Force` does exactly that - verified live - and the consumers this module
# exists for (fm-tmux-lib, the herdr adapter) import both.
coexist_out=$(pwsh -NoProfile -Command \
  "Import-Module '$COMMON_N' -Force; Import-Module '$MOD_N' -Force; [Console]::Out.Write([string][bool](Get-Command Write-FmOut -ErrorAction SilentlyContinue))" 2>&1)
assert_case "importing this module leaves a caller's fm-common loaded" 'True' "$coexist_out"

# --- report -------------------------------------------------------------------
if [ "$FAILURES" -ne 0 ]; then
  printf 'not ok - fm-composer-lib.psm1 differs from its bash oracle (%d of %d assertions):\n' \
    "$FAILURES" "$ASSERTIONS" >&2
  printf '%s' "$FAILURE_TEXT" >&2
  exit 1
fi

# A suite that silently ran nothing must not read as a pass, so the assertion
# count is itself asserted. Dropping cases - by deleting them, or through a
# bookkeeping regression that stops recording them - fails loudly instead of
# certifying an empty run.
MIN_ASSERTIONS=165
if [ "$ASSERTIONS" -lt "$MIN_ASSERTIONS" ]; then
  printf 'not ok - only %d differential assertions ran, expected at least %d\n' \
    "$ASSERTIONS" "$MIN_ASSERTIONS" >&2
  exit 1
fi

printf 'ok - fm-composer-lib.psm1 matches the bash oracle across %d differential assertions\n' "$ASSERTIONS"
printf '# fm-composer-lib-psm1.test.sh: all assertions passed\n'
