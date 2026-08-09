# fm-tmux-lib.psm1 - shared tmux pane primitives for firstmate.
#
# Twin: bin/fm-tmux-lib.sh
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Imported by both the tmux
# session-provider adapter (bin/backends/tmux.psm1) and, for its single tmux
# invocation helper, by the dispatcher (bin/fm-backend.psm1), exactly as the
# bash twin is sourced by the away-mode daemon and bin/fm-send.sh - so the
# composer/submit logic cannot drift between consumers, and now cannot drift
# between the two LANGUAGE trees either.
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-tmux-lib.sh                  this file
#   ---------------------------------   -----------------------------------
#   fm_busy_lines_match                 Test-FmTmuxBusyLine
#   fm_tmux_strip_ghost                 Get-FmTmuxRealText
#   fm_tmux_composer_row_state          Get-FmTmuxComposerRowState
#   fm_tmux_row_has_composer_edge       Test-FmTmuxComposerEdge
#   fm_tmux_composer_geometry_spaces    Get-FmTmuxComposerGeometrySpace
#   fm_tmux_find_composer_box           Find-FmTmuxComposerBox
#   fm_tmux_composer_state              Get-FmTmuxComposerState
#   fm_pane_input_pending               Test-FmTmuxInputPending
#   fm_pane_is_busy                     Test-FmTmuxPaneBusy
#   fm_tmux_submit_enter_core           Send-FmTmuxEnterSubmit
#   fm_tmux_submit_core                 Send-FmTmuxSubmit
#   FM_TMUX_*_BUSY_REGEX_DEFAULT        Get-FmTmuxBusyRegex -Harness <h>
#   (bare `tmux ...`)                   Invoke-FmTmuxCommand
#   (none)                              Get-FmTmuxTrimSet         no (private)
#
# WHY THIS EXISTS (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders, so every idle claude pane read as "pending
# input" and the away-mode daemon deferred 100% of escalations for 9.5 hours
# with no escape. The detector below strips the box borders before deciding.
# The same corrected detector backs the submit acknowledgement (a submit
# "landed" iff the composer is empty afterward), fixing the parallel false
# "Enter swallowed".
#
# Ghost text (incident composer-robust): a harness renders a predicted-next
# prompt as dim/faint text inside an otherwise-empty composer. The composer
# reader captures the visible pane WITH ANSI styling (tmux capture-pane -e),
# locates a bordered composer structurally, and extracts the real typed content
# with the shared, fleet-wide Get-FmComposerRealText (bin/fm-composer-lib.psm1),
# which drops every de-emphasised run. The styled capture is consumed internally
# and parsed into a verdict here; it is NEVER surfaced.
#
# Busy-queued Enter (opencode 1.18.4, tmux backend only): when the agent is
# mid-turn, opencode accepts Enter as a "send when the turn ends" keystroke but
# does NOT clear the composer until then. The submit core falls back to
# Test-FmTmuxPaneBusy once the Enter-retry budget is spent: a busy pane means
# the harness accepted and queued the Enter (report `empty` so the caller does
# not re-send), while an idle pane keeps the `pending` verdict (a genuine
# swallow).
#
# Overrides: FM_COMPOSER_IDLE_RE matches an empty composer after ghost and
# structural border stripping. FM_BUSY_REGEX overrides the rendered busy-footer
# matching used here. Both are read FRESH on every call, exactly as the bash
# twin re-expands them per call.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.psm1's
# semantic contract. The matching below serves only delivery guards.
#
# ---------------------------------------------------------------------------
# WHAT THE POWERSHELL TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. THE `tmux` BINARY IS RESOLVED, NEVER NAMED. Verified on this host:
#    Process.Start with FileName='tmux' does NOT search PATH and throws "The
#    system cannot find the file specified", and an extension-less shebang
#    script cannot be started at all ("not a valid application for this OS
#    platform"). So Invoke-FmTmuxCommand resolves the command through
#    Get-Command -CommandType Application first and hands Invoke-FmTool the
#    resolved .Source. It resolves on EVERY call rather than caching, because
#    the bash twin re-resolves too and a suite that changes PATH between cases
#    (the fake-tmux convention every backend suite uses) must be honoured.
#
# 2. NO SUBPROCESSES FOR STRING WORK. The bash twin shells out to `grep`, `sed`
#    and `tail` on the hottest supervision paths; each costs an MSYS fork here.
#    This module does that work in-process. The only child process left is tmux
#    itself.
#
# 3. TRAILING-NEWLINE CONVENTION. Every bash call site consumes a tmux read
#    through `$( ... )`, which strips ALL trailing newlines. Each read below
#    therefore ends with .TrimEnd([char]10) at exactly the point the bash twin
#    used a command substitution, so the values compared are the values a bash
#    caller ends up holding.
#
# 4. POSIX ERE -> .NET REGEX, AND THE ONE CLASS THAT MATTERS. The busy
#    signatures are grep -E patterns containing [[:space:]], which .NET does not
#    understand. They are rebuilt here against $script:FmTmuxPosixSpaceClass,
#    the six ASCII members of the C-locale [[:space:]]. Everything else in every
#    shipped signature is in the common ERE/.NET subset. grep matches PER LINE,
#    so the matcher splits and tests each line rather than reaching for
#    RegexOptions::Multiline, whose ^/$ semantics differ around a trailing
#    newline.
#
# 5. THE WHITESPACE TRIM IS LOCALE-DEPENDENT, AND STAYS THAT WAY. bash resolves
#    [[:space:]] against LC_CTYPE, so a row holding only a non-breaking space
#    trims to nothing (empty, i.e. safe to inject into) under a UTF-8 locale and
#    survives as pending under C. Get-FmTmuxTrimSet reproduces that decision
#    rather than picking a side. It MIRRORS bin/fm-composer-lib.psm1's private
#    Get-FmComposerTrimSet, which that module does not export; the duplication
#    is deliberate and pinned by tests/fm-backend-core-psm1.test.sh, which
#    drives the same fixtures through both trims under both locales. If the
#    composer owner ever exports its own, delete this copy and import it.
#
# KNOWN DIVERGENCES FROM THE BASH ORACLE (deliberate, not normalized away):
#
#   a. SIGNALS AND set -e. The bash functions are documented as `set -u`/`set -e`
#      safe. PowerShell has neither, and $ErrorActionPreference = 'Stop' plus
#      explicit result checks cover the same ground: no function here throws for
#      a tmux failure, each returns the twin's degraded verdict instead.
#
#   b. CARRIAGE RETURNS ARE STRIPPED from tmux output, because Invoke-FmTool
#      does so by default (the foundation's answer to the native-tool CRLF
#      hazard that cost hours during the Windows bash port). Real tmux emits LF,
#      so the two worlds see identical bytes; a CRLF-emitting shim would be
#      normalized here and not in bash.
#
#   c. A NON-NUMERIC SLEEP VALUE. `sleep abc` prints an error and continues in
#      bash; here it is treated as 0 with no diagnostic. No call site passes one.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-tmux-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on these nested imports, and that is load-bearing rather than a
# style choice: a nested `Import-Module -Force` REMOVES the already-loaded
# module before re-importing it, and the removal is GLOBAL - a consumer that had
# imported fm-common.psm1 itself loses Write-FmOut the moment it imports this
# module (verified live, and the reason bin/fm-composer-lib.psm1 carries the
# same note).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-composer-lib.psm1')

# Every string comparison here is ORDINAL. PowerShell's -eq/-ceq and .NET's
# default String comparisons are culture-sensitive, which makes zero-width
# characters IGNORABLE - so a composer row of ZERO-WIDTH-SPACE + '>' would
# compare equal to '>' and take the shell-glyph arm, i.e. the "safe to inject
# into" verdict, on a row bash refuses. bash compares BYTES.
$script:FmTmuxOrdinal = [System.StringComparison]::Ordinal

# --- the [[:space:]] trim set, which is LOCALE-DEPENDENT ---------------------
#
# Mirror of bin/fm-composer-lib.psm1's private Get-FmComposerTrimSet; see note 5
# in the header for why the copy exists and what pins it. Both sets were
# MEASURED against the bash twin on this host with fixture bytes held fixed and
# only the locale varied:
#
#   LC_ALL/LC_CTYPE/LANG = C, POSIX, or unset -> the six ASCII members only.
#   any UTF-8 locale, C.UTF-8 included        -> the Unicode set below.
#
# The Unicode set is exactly .NET's Char.IsWhiteSpace MINUS U+0085 NEL, which
# .NET calls whitespace and bash does not.
$script:FmTmuxPosixSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)
$script:FmTmuxUnicodeSpace = [char[]]@(
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,
    0x00A0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000
)

# The C-locale [[:space:]] as a .NET character class, for the busy signatures
# and the blank-line filter. Deliberately NOT \s: .NET's \s is Unicode-aware and
# would widen a signature the bash twin resolves against grep's own class.
$script:FmTmuxPosixSpaceClass = '[ \t\n\x0B\f\r]'

function Get-FmTmuxTrimSet {
    [CmdletBinding()]
    [OutputType([char[]])]
    param()

    # bash's own LC_ALL > LC_CTYPE > LANG precedence, with `:-` semantics at
    # each step so an EMPTY variable falls through exactly as bash's does. Read
    # fresh on every call rather than cached at import, because a differential
    # run drives the same process under both locales.
    $locale = Get-FmEnv -Name 'LC_ALL'
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LC_CTYPE' }
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LANG' }
    if ([string]::IsNullOrEmpty($locale) -or
        [string]::Equals($locale, 'C', $script:FmTmuxOrdinal) -or
        [string]::Equals($locale, 'POSIX', $script:FmTmuxOrdinal)) {
        return $script:FmTmuxPosixSpace
    }
    return $script:FmTmuxUnicodeSpace
}

# --- the tmux invocation seam ------------------------------------------------

<#
.SYNOPSIS
Run one tmux command, capturing stdout, stderr and the exit code.
.DESCRIPTION
The twin of a bare `tmux ...` in the bash tree, and the ONE place this tree
starts the tmux binary - bin/backends/tmux.psm1 and bin/fm-backend.psm1's
read-only endpoint probe both route through it, so "how do we invoke tmux" has a
single owner exactly as "how do we classify a composer row" does.

Returns the Invoke-FmTool hashtable (ExitCode, StdOut, StdErr, Ok). A tmux that
is not on PATH returns ExitCode 127 with an empty StdOut, which is precisely
what bash produces for `command not found` - and every caller below already
treats a non-zero status as its degraded verdict, so a host with no tmux
degrades rather than throwing.

See note 1 in the file header for why the command is resolved through
Get-Command instead of being handed to Process.Start by name.
#>
function Invoke-FmTmuxCommand {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    $resolved = Get-Command 'tmux' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $resolved) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = 'fm: tmux not found on PATH'; Ok = $false }
    }
    try {
        return Invoke-FmTool -FilePath $resolved.Source -Arguments @($Arguments)
    } catch {
        # A resolved command that still cannot be started (an unreadable image,
        # a shim of a shape this platform refuses) is "tmux did not answer",
        # never an exception escaping into a caller that expected a verdict.
        return @{ ExitCode = 127; StdOut = ''; StdErr = "fm: tmux failed to start: $($_.Exception.Message)"; Ok = $false }
    }
}

# The `$( ... )` twin: bash command substitution strips ALL trailing newlines.
function Get-FmTmuxSubstituted {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.TrimEnd([char]10)
}

# --- busy signatures ---------------------------------------------------------
#
# Delivery-only rendered busy footers per harness. claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel".
# Claude's current spinner has a rotating glyph and word, but every active-turn
# line has an ellipsis followed by a parenthesized elapsed duration. That
# signature is kept separate from the shared default because the shape is not
# generic enough to classify arbitrary harness output safely.
#
# Kimi's anchored moon-phase spinner is separate because bare moon glyphs in
# ordinary output must not classify another harness as busy. Leading whitespace
# is OPTIONAL; whitespace on both sides of the separator is REQUIRED because
# every captured spinner row had it. A zero-whitespace form has NEVER been
# observed and is deliberately not matched. The line end is intentionally
# unanchored because rotating tip text follows and is not required to be
# present. The full moon-phase set remains locale- and emoji-font-sensitive
# because Kimi exposes no stable ASCII busy token.
#
# The moon glyphs are built from code points rather than literals for the same
# reason bin/fm-composer-lib.psm1 builds its prompt glyphs that way: they are
# ASTRAL (U+1F311..U+1F318, a surrogate pair each in UTF-16), and a file whose
# bytes were re-encoded by an editor or a patch tool would silently turn every
# Kimi busy verdict into "idle" with nothing to see in review.
$script:FmTmuxKimiMoonGlyphs = @(0x1F311, 0x1F312, 0x1F313, 0x1F314, 0x1F315, 0x1F316, 0x1F317, 0x1F318) |
    ForEach-Object { [char]::ConvertFromUtf32($_) }

$script:FmTmuxBusyRegexDefault = 'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
$script:FmTmuxClaudeBusyRegexDefault = 'esc to interrupt|' + [char]0x2026 + $script:FmTmuxPosixSpaceClass + '+\([0-9]+[smh]'
$script:FmTmuxCodexBusyRegexDefault = 'esc to interrupt'
$script:FmTmuxOpencodeBusyRegexDefault = 'esc interrupt'
$script:FmTmuxPiBusyRegexDefault = 'Working\.\.\.'
$script:FmTmuxGrokBusyRegexDefault = 'Ctrl\+c:cancel'
$script:FmTmuxKimiBusyRegexDefault = '^' + $script:FmTmuxPosixSpaceClass + '*(' +
    ($script:FmTmuxKimiMoonGlyphs -join '|') + ')' +
    $script:FmTmuxPosixSpaceClass + '+' + [char]0x00B7 + $script:FmTmuxPosixSpaceClass + '+'

<#
.SYNOPSIS
The busy-footer regex for one harness, or '' when there is none.
.DESCRIPTION
Twin of the `case "$harness"` block inside fm_busy_lines_match, including its
two edges:
  - FM_BUSY_REGEX overrides every harness (read fresh, `:-` semantics, so an
    EMPTY value falls through to the per-harness defaults);
  - an UNRECOGNISED harness name yields '' rather than borrowing another
    harness's signature. That is a safety rule, not an omission: Kimi's idle
    key-tip rotation can render the same cancel token Grok uses to mean busy, so
    a harness must be registered with its own verified signature before it can
    ever be classified busy. An empty harness name is the historical shared
    default and is a real arm, not the unrecognised one.
The comparison is case-SENSITIVE and exact, exactly as the bash `case` arms are.
#>
function Get-FmTmuxBusyRegex {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Harness = '')

    $override = Get-FmEnv -Name 'FM_BUSY_REGEX'
    if (-not [string]::IsNullOrEmpty($override)) { return $override }
    if ($null -eq $Harness) { $Harness = '' }

    if ([string]::Equals($Harness, 'claude', $script:FmTmuxOrdinal)) { return $script:FmTmuxClaudeBusyRegexDefault }
    if ([string]::Equals($Harness, 'codex', $script:FmTmuxOrdinal)) { return $script:FmTmuxCodexBusyRegexDefault }
    if ([string]::Equals($Harness, 'opencode', $script:FmTmuxOrdinal)) { return $script:FmTmuxOpencodeBusyRegexDefault }
    if ([string]::Equals($Harness, 'pi', $script:FmTmuxOrdinal) -or
        [string]::Equals($Harness, 'pi-signed', $script:FmTmuxOrdinal)) { return $script:FmTmuxPiBusyRegexDefault }
    if ([string]::Equals($Harness, 'grok', $script:FmTmuxOrdinal)) { return $script:FmTmuxGrokBusyRegexDefault }
    if ([string]::Equals($Harness, 'kimi', $script:FmTmuxOrdinal)) { return $script:FmTmuxKimiBusyRegexDefault }
    if ([string]::Equals($Harness, '', $script:FmTmuxOrdinal)) { return $script:FmTmuxBusyRegexDefault }
    return ''
}

# grep's per-line matching, reproduced. An empty pattern never matches (the
# bash guard skips grep entirely), empty content is ZERO lines and so can never
# match, and a single trailing newline TERMINATES the last line rather than
# adding an empty one.
function Test-FmTmuxRegexLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Pattern = ''
    )

    if ([string]::IsNullOrEmpty($Pattern)) { return $false }
    if ([string]::IsNullOrEmpty($Text)) { return $false }

    $rx = $null
    try {
        $rx = [System.Text.RegularExpressions.Regex]::new(
            $Pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    } catch {
        # `grep -qiE '['` prints a diagnostic and exits non-zero, which the bash
        # twin reads as NO MATCH. Same verdict here; the stderr noise is not
        # reproduced.
        return $false
    }

    $body = $Text
    if ($body.EndsWith("`n", $script:FmTmuxOrdinal)) { $body = $body.Substring(0, $body.Length - 1) }
    foreach ($line in $body.Split("`n")) {
        if ($rx.IsMatch($line)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Do these rendered pane lines show a busy footer for this harness?
.DESCRIPTION
Twin of fm_busy_lines_match, whose bash form reads the lines from STDIN; here
they are a parameter, because PowerShell has no pipeline-into-a-shell-function
idiom that preserves bytes as faithfully as passing the string.
#>
function Test-FmTmuxBusyLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Harness = ''
    )

    return Test-FmTmuxRegexLine -Text $Text -Pattern (Get-FmTmuxBusyRegex -Harness $Harness)
}

# --- composer row classification ---------------------------------------------

<#
.SYNOPSIS
Drop de-emphasised ghost/placeholder runs from one captured, styled row.
.DESCRIPTION
Twin of fm_tmux_strip_ghost, which is itself a thin adapter over the shared,
fleet-wide extractor. Owns no logic of its own - it exists so the tmux and herdr
adapters cannot drift apart on what counts as ghost text - and is kept as a
named tmux entry point for the same reason the bash twin keeps one.
#>
function Get-FmTmuxRealText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    return Get-FmComposerRealText $Text
}

# The composer-edge vocabulary, built from code points so no editor or patch
# tool can silently re-encode a border glyph and turn "this row is structural"
# into "this row is content". Order matches the bash `case` arm.
$script:FmTmuxComposerEdgeChars = [char[]]@(
    0x2502, 0x2503, 0x2551,                     # vertical: light, heavy, double
    0x256D, 0x256E, 0x250C, 0x2510,             # top corners: rounded, light
    0x2554, 0x2557, 0x250F, 0x2513,             # top corners: double, heavy
    0x2570, 0x256F, 0x2514, 0x2518,             # bottom corners: rounded, light
    0x255A, 0x255D, 0x2517, 0x251B,             # bottom corners: double, heavy
    0x2500, 0x2501, 0x2550,                     # horizontal: light, heavy, double
    0x007C, 0x002B                              # ascii: pipe, plus
)

<#
.SYNOPSIS
Is this plain row structural - does it start or end with a composer border?
.DESCRIPTION
Twin of fm_tmux_row_has_composer_edge. The bash `case` patterns are all
`'<glyph>'*|*'<glyph>'`, i.e. "first non-whitespace character is this glyph OR
last non-whitespace character is". A fully blank row has neither and is not
structural.
#>
function Test-FmTmuxComposerEdge {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Row = '')

    if ([string]::IsNullOrEmpty($Row)) { return $false }
    $trimmed = $Row.Trim((Get-FmTmuxTrimSet))
    if ([string]::IsNullOrEmpty($trimmed)) { return $false }
    if ([Array]::IndexOf($script:FmTmuxComposerEdgeChars, $trimmed[0]) -ge 0) { return $true }
    if ([Array]::IndexOf($script:FmTmuxComposerEdgeChars, $trimmed[$trimmed.Length - 1]) -ge 0) { return $true }
    return $false
}

<#
.SYNOPSIS
The blank-geometry projection of one content row, or $null when it has content.
.DESCRIPTION
Twin of fm_tmux_composer_geometry_spaces, which answers "if every printable
character on this row became a space, is what remains ALL whitespace?" - the
check that proves a box's content rows are the same width as its borders.

Two details reproduced exactly rather than tidied:
  - a LEADING prompt glyph is replaced first, and the replacement targets the
    FIRST occurrence of that glyph anywhere in the row (bash `${content/>/ }`),
    not only the leading one. Every real row has the glyph at the front, so the
    two readings coincide, but the literal one is what the oracle does.
  - the printable sweep is `sed 's/[!-~]/ /g'` under LC_ALL=C, i.e. exactly the
    ASCII range U+0021..U+007E. Multibyte glyphs are all >= 0x80 and survive it,
    which is precisely why a surviving box glyph makes this fail.
$null is the twin of the bash non-zero return.
#>
function Get-FmTmuxComposerGeometrySpace {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Content = '')

    if ($null -eq $Content) { $Content = '' }
    $trimSet = Get-FmTmuxTrimSet
    $probe = $Content.TrimStart($trimSet)

    foreach ($glyph in @('>', [string][char]0x276F, [string][char]0x203A)) {
        if ($probe.StartsWith($glyph, $script:FmTmuxOrdinal)) {
            $at = $Content.IndexOf($glyph, $script:FmTmuxOrdinal)
            if ($at -ge 0) {
                $Content = $Content.Substring(0, $at) + ' ' + $Content.Substring($at + $glyph.Length)
            }
            break
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Content.ToCharArray()) {
        if ([int]$ch -ge 0x21 -and [int]$ch -le 0x7E) { [void]$sb.Append(' ') }
        else { [void]$sb.Append($ch) }
    }
    $swept = $sb.ToString()

    foreach ($ch in $swept.ToCharArray()) {
        if ([Array]::IndexOf($trimSet, $ch) -lt 0) { return $null }
    }
    return $swept
}

<#
.SYNOPSIS
Classify one raw styled candidate row as empty, pending or unknown.
.DESCRIPTION
Twin of fm_tmux_composer_row_state. A structural caller forces -Bordered 1; the
compatibility fallback passes 0 and may recognise a busy footer.

The order below is the bash order and it matters: the row is ghost-stripped and
trimmed, then a MATCHED border pair is removed and it is trimmed again, then -
only when the caller allowed it - a busy footer converts the row to `empty`,
and only then is the shared classifier asked. Doing the busy check before border
removal would miss a footer drawn inside a box; doing it after the classifier
would let a busy footer read as pending input.
#>
function Get-FmTmuxComposerRowState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Raw = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Bordered = '0',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$AllowBusy = '1'
    )

    if ($null -eq $Raw) { $Raw = '' }
    if ([string]::IsNullOrEmpty($Bordered)) { $Bordered = '0' }
    if ([string]::IsNullOrEmpty($AllowBusy)) { $AllowBusy = '1' }
    $trimSet = Get-FmTmuxTrimSet

    # `printf '%s\n' "$raw" | filter` inside `$( ... )`: the filter sees one
    # terminated record and the substitution strips the terminator back off.
    $plain = (Get-FmComposerPlainText ($Raw + "`n")).TrimEnd([char]10).Trim($trimSet)
    $stripped = (Get-FmComposerRealText ($Raw + "`n")).TrimEnd([char]10).Trim($trimSet)

    # A MATCHED pair only, first arm wins, exactly as the bash `case` does.
    foreach ($pair in @([char]0x2502, [char]0x2503, [char]0x2551, [char]0x007C)) {
        if ($stripped.Length -ge 2 -and $stripped[0] -eq $pair -and $stripped[$stripped.Length - 1] -eq $pair) {
            $stripped = $stripped.Substring(1, $stripped.Length - 2)
            break
        }
    }
    $stripped = $stripped.Trim($trimSet)

    if ([string]::Equals($AllowBusy, '1', $script:FmTmuxOrdinal) -and
        -not [string]::IsNullOrEmpty($stripped)) {
        $busyPattern = Get-FmEnv -Name 'FM_BUSY_REGEX'
        if ([string]::IsNullOrEmpty($busyPattern)) { $busyPattern = $script:FmTmuxBusyRegexDefault }
        if (Test-FmTmuxRegexLine -Text $stripped -Pattern $busyPattern) { return 'empty' }
    }

    return Get-FmComposerContentState `
        -Bordered $Bordered `
        -Content $stripped `
        -IdleRegex (Get-FmEnv -Name 'FM_COMPOSER_IDLE_RE') `
        -IdleCase 'insensitive' `
        -PlainContent $plain
}

# --- structural box finding --------------------------------------------------

# The five recognised border families, each with its corner glyphs, the
# horizontal rule it draws, and the vertical side a content row must use. Built
# from code points for the same reason the edge set is.
$script:FmTmuxBoxFamily = @{
    rounded = @{ Top = [char]0x256D; TopEnd = [char]0x256E; Bottom = [char]0x2570; BottomEnd = [char]0x256F; Rule = [char]0x2500; Side = 'single' }
    light   = @{ Top = [char]0x250C; TopEnd = [char]0x2510; Bottom = [char]0x2514; BottomEnd = [char]0x2518; Rule = [char]0x2500; Side = 'single' }
    double  = @{ Top = [char]0x2554; TopEnd = [char]0x2557; Bottom = [char]0x255A; BottomEnd = [char]0x255D; Rule = [char]0x2550; Side = 'double' }
    heavy   = @{ Top = [char]0x250F; TopEnd = [char]0x2513; Bottom = [char]0x2517; BottomEnd = [char]0x251B; Rule = [char]0x2501; Side = 'heavy' }
    ascii   = @{ Top = [char]0x002B; TopEnd = [char]0x002B; Bottom = [char]0x002B; BottomEnd = [char]0x002B; Rule = [char]0x002D; Side = 'ascii' }
}

# The vertical sides a content row may be drawn with, and the family each
# belongs to. `$current_family:$side_family` must be one of the pairs the bash
# `case` allows: rounded:single, light:single, heavy:heavy, double:double,
# ascii:ascii - note that a ROUNDED or LIGHT box takes a SINGLE side, so those
# two families share one side glyph while heavy and double do not.
$script:FmTmuxSideChar = @{
    single = [char]0x2502
    heavy  = [char]0x2503
    double = [char]0x2551
    ascii  = [char]0x007C
}

# `${line%%[![:space:]]*}` and friends: the leading whitespace run, and the
# fully trimmed line. An ALL-whitespace line yields the whole line as its indent
# and an empty trimmed value, which is what bash's non-matching `%%` produces.
function Get-FmTmuxLeadingSpace {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Line,
        [Parameter(Position = 1)][char[]]$TrimSet
    )
    $i = 0
    while ($i -lt $Line.Length -and [Array]::IndexOf($TrimSet, $Line[$i]) -ge 0) { $i++ }
    return $Line.Substring(0, $i)
}

<#
.SYNOPSIS
Locate the complete bordered box that structurally contains the cursor.
.DESCRIPTION
Twin of fm_tmux_find_composer_box. Returns a hashtable:

  Code       0 = a box was found (Top, Bottom, Ambiguous are meaningful)
             1 = no box contains the cursor
             2 = the pane is structurally UNSAFE to judge
  Top        zero-based row of the box's top border
  Bottom     zero-based row of its bottom border
  Ambiguous  '1' when the geometry does not prove the box, '0' when it does

The bash twin returns those three codes as an exit status and the three values
as a single space-separated line; PowerShell has no subshell boundary forcing a
one-channel return, so they travel together (the same collapse
bin/fm-psproc-lib.psm1 applied to FM_NATIVE_PID_IMAGE/PATH).

Code 2 is the load-bearing one. It fires when the cursor sits ON a structural
row, or when an unclosed box straddles it, and the caller must answer `unknown`
- never `empty` - because a pane whose structure cannot be read is not a proven
injection target.

The cursor may be on any content row or on the bottom border; no fixed cursor
offset is used.
#>
function Find-FmTmuxComposerBox {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][int]$CursorY,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Pane = ''
    )

    if ($null -eq $Pane) { $Pane = '' }
    $trimSet = Get-FmTmuxTrimSet

    # The bash twin feeds the pane through `<<EOF\n$pane\nEOF`, so the lines are
    # exactly ($pane + "\n") split on LF with the terminator dropped. An EMPTY
    # pane is therefore ONE empty line, not zero.
    # @() around the slice: PowerShell unrolls a single-element array into a
    # bare string, and a one-line pane must still iterate as one LINE.
    $split = ($Pane + "`n").Split("`n")
    $lines = @($split[0..($split.Length - 2)])

    $row = 0
    $top = -1
    $valid = 0
    $contentRows = 0
    $unsafe = 0
    $cursorStructural = 0
    $currentFamily = ''
    $currentIndent = ''
    $topSpaces = ''
    $geometryCheck = 0
    $geometryAmbiguous = 0

    foreach ($line in $lines) {
        $indent = Get-FmTmuxLeadingSpace -Line $line -TrimSet $trimSet
        $trimmed = $line.Trim($trimSet)

        # The bash `case` arms in their exact order: every TOP pattern, then
        # every BOTTOM pattern, then the ascii box. The glyph sets are disjoint
        # so the order cannot change a verdict, but it is kept literal so a
        # reader can diff this against the oracle arm for arm.
        $kind = ''
        $family = ''
        $paired = ($trimmed.Length -ge 2)
        foreach ($name in @('rounded', 'light', 'double', 'heavy')) {
            $f = $script:FmTmuxBoxFamily[$name]
            if ($paired -and $trimmed[0] -eq $f.Top -and $trimmed[$trimmed.Length - 1] -eq $f.TopEnd) {
                $kind = 'top'; $family = $name; break
            }
        }
        if ($kind -eq '') {
            foreach ($name in @('rounded', 'light', 'double', 'heavy')) {
                $f = $script:FmTmuxBoxFamily[$name]
                if ($paired -and $trimmed[0] -eq $f.Bottom -and $trimmed[$trimmed.Length - 1] -eq $f.BottomEnd) {
                    $kind = 'bottom'; $family = $name; break
                }
            }
        }
        if ($kind -eq '') {
            $a = $script:FmTmuxBoxFamily['ascii']
            if ($paired -and $trimmed[0] -eq $a.Top -and $trimmed[$trimmed.Length - 1] -eq $a.TopEnd) {
                $kind = 'ascii'; $family = 'ascii'
            }
        }

        if ($row -eq $CursorY -and (Test-FmTmuxComposerEdge $trimmed)) { $cursorStructural = 1 }

        if ($kind -eq 'top' -or ($kind -eq 'ascii' -and $top -lt 0)) {
            if ($top -ge 0 -and $top -lt $CursorY -and $CursorY -le $row) { $unsafe = 1 }
            $top = $row
            $currentFamily = $family
            $currentIndent = $indent
            $valid = 1
            $contentRows = 0
            $geometryAmbiguous = 0
            $geometryCheck = 1
            $f = $script:FmTmuxBoxFamily[$family]
            $inner = $trimmed.Substring(1, $trimmed.Length - 2)
            # [string] casts pin the Replace(string,string) overload: passing a
            # [char] and a [string] leaves the overload ambiguous.
            $topSpaces = $inner.Replace([string]$f.Rule, ' ')
            foreach ($ch in $topSpaces.ToCharArray()) {
                if ([Array]::IndexOf($trimSet, $ch) -lt 0) { $geometryCheck = 0; $geometryAmbiguous = 1; break }
            }
        } elseif ($kind -eq 'bottom' -or ($kind -eq 'ascii' -and $top -ge 0)) {
            if ($top -ge 0 -and $family -eq $currentFamily -and $valid -eq 1 -and $contentRows -gt 0 -and
                $top -lt $CursorY -and $CursorY -le $row) {
                if ($indent -ne $currentIndent) { $geometryAmbiguous = 1 }
                if ($geometryCheck -eq 1) {
                    $f = $script:FmTmuxBoxFamily[$family]
                    $inner = $trimmed.Substring(1, $trimmed.Length - 2)
                    $bottomSpaces = $inner.Replace([string]$f.Rule, ' ')
                    if (-not [string]::Equals($bottomSpaces, $topSpaces, $script:FmTmuxOrdinal)) { $geometryAmbiguous = 1 }
                }
                return @{ Code = 0; Top = $top; Bottom = $row; Ambiguous = [string]$geometryAmbiguous }
            }
            if (($top -ge 0 -and $top -lt $CursorY -and $CursorY -le $row) -or $row -eq $CursorY) { $unsafe = 1 }
            $top = -1
            $currentFamily = ''
            $currentIndent = ''
            $valid = 0
            $contentRows = 0
        } elseif ($top -ge 0) {
            $sideFamily = ''
            foreach ($name in @('single', 'heavy', 'double', 'ascii')) {
                $side = $script:FmTmuxSideChar[$name]
                if ($trimmed.Length -ge 2 -and $trimmed[0] -eq $side -and $trimmed[$trimmed.Length - 1] -eq $side) {
                    $sideFamily = $name; break
                }
            }
            $pairOk = (
                ($currentFamily -eq 'rounded' -and $sideFamily -eq 'single') -or
                ($currentFamily -eq 'light' -and $sideFamily -eq 'single') -or
                ($currentFamily -eq 'heavy' -and $sideFamily -eq 'heavy') -or
                ($currentFamily -eq 'double' -and $sideFamily -eq 'double') -or
                ($currentFamily -eq 'ascii' -and $sideFamily -eq 'ascii')
            )
            if ($pairOk) {
                $contentRows++
                if ($indent -ne $currentIndent) { $geometryAmbiguous = 1 }
                if ($geometryCheck -eq 1) {
                    $contentInner = $trimmed.Substring(1, $trimmed.Length - 2)
                    $contentSpaces = Get-FmTmuxComposerGeometrySpace $contentInner
                    if ($null -eq $contentSpaces) { $geometryAmbiguous = 1 }
                    elseif (-not [string]::Equals($contentSpaces, $topSpaces, $script:FmTmuxOrdinal)) { $geometryAmbiguous = 1 }
                }
            } else {
                $valid = 0
            }
        }
        $row++
    }

    if ($top -ge 0 -and $top -lt $CursorY) { $unsafe = 1 }
    if ($unsafe -eq 1 -or $cursorStructural -eq 1) {
        return @{ Code = 2; Top = -1; Bottom = -1; Ambiguous = '0' }
    }
    return @{ Code = 1; Top = -1; Bottom = -1; Ambiguous = '0' }
}

# --- pane-level composer state -----------------------------------------------

<#
.SYNOPSIS
The proof-carrying composer verdict for one tmux target.
.DESCRIPTION
Twin of fm_tmux_composer_state, and the classification contract it carries:

A row is structural only when its first or last non-whitespace character is a
composer edge. A complete box has matching border families and bounded top and
bottom rows. The verdict is `empty` for proven emptiness, `pending` for proven
text in established structure, `pending-unproven` for text in ambiguous
structure, and `unknown` for unreadable state. Consumers that can overwrite
input or confirm delivery must accept only the exact positive proof they
require, so unrecognised future verdicts fail safe by default. Empty requires
positive proof: a genuinely empty composer, an all-empty unambiguous box, an
empty non-bordered fallback row, or the submit core's proven busy-queued Enter
conversion.

Every tmux read is guarded: a failed cursor read, a failed styled capture, or a
non-numeric cursor row all answer `unknown`, never a guess.
#>
function Get-FmTmuxComposerState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')

    $cyResult = Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{cursor_y}')
    if (-not $cyResult.Ok) { return 'unknown' }
    $cy = Get-FmTmuxSubstituted $cyResult.StdOut
    if ($cy -notmatch '^[0-9]+$') { return 'unknown' }
    $cursorY = [int]$cy

    $paneResult = Invoke-FmTmuxCommand @('capture-pane', '-e', '-p', '-t', $Target, '-S', '0', '-E', '-')
    if (-not $paneResult.Ok) { return 'unknown' }
    $pane = Get-FmTmuxSubstituted $paneResult.StdOut
    $plain = (Get-FmComposerPlainText ($pane + "`n")).TrimEnd([char]10)

    $box = Find-FmTmuxComposerBox -CursorY $cursorY -Pane $plain
    if ($box.Code -eq 0) {
        # `sed -n "Np"` over `printf '%s\n' "$pane"`: the STYLED pane's Nth line,
        # 1-based. Indices line up with $plain because the ANSI strip is
        # per-line and cannot merge or drop a row.
        $paneLines = ($pane + "`n").Split("`n")
        $unknownSeen = 0
        for ($r = $box.Top + 1; $r -lt $box.Bottom; $r++) {
            $rowRaw = if ($r -ge 0 -and $r -lt $paneLines.Length) { $paneLines[$r] } else { '' }
            $state = Get-FmTmuxComposerRowState -Raw $rowRaw -Bordered '1' -AllowBusy '0'
            if ($state -ceq 'pending') {
                if ($box.Ambiguous -ceq '1') { return 'pending-unproven' }
                return 'pending'
            }
            if ($state -ceq 'unknown') { $unknownSeen = 1 }
        }
        if ($unknownSeen -eq 1 -or $box.Ambiguous -ceq '1') { return 'unknown' }
        return 'empty'
    }
    if ($box.Code -eq 2) { return 'unknown' }

    $rawResult = Invoke-FmTmuxCommand @('capture-pane', '-e', '-p', '-t', $Target, '-S', $cy, '-E', $cy)
    if (-not $rawResult.Ok) { return 'unknown' }
    $raw = Get-FmTmuxSubstituted $rawResult.StdOut
    if (Test-FmTmuxComposerEdge ((Get-FmComposerPlainText ($raw + "`n")).TrimEnd([char]10))) {
        return 'unknown'
    }
    return Get-FmTmuxComposerRowState -Raw $raw -Bordered '0'
}

<#
.SYNOPSIS
True when the composer is NOT proven empty.
.DESCRIPTION
Twin of fm_pane_input_pending. Pending text, ambiguous structure, unreadable
state, and any future verdict all defer - only the exact string `empty` is
treated as a safe injection target.
#>
function Test-FmTmuxInputPending {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')
    return (-not [string]::Equals((Get-FmTmuxComposerState $Target), 'empty', $script:FmTmuxOrdinal))
}

<#
.SYNOPSIS
Is an agent mid-turn in this pane, judged from its rendered busy footer?
.DESCRIPTION
Twin of fm_pane_is_busy: capture a 40-line tail, drop blank rows, keep the last
12, and match the harness's own busy signature. A failed capture is not busy.
This is a DELIVERY guard, not a task-state source (bin/fm-busy-lib.psm1 owns
that contract).
#>
function Test-FmTmuxPaneBusy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Harness = ''
    )

    $result = Invoke-FmTmuxCommand @('capture-pane', '-p', '-t', $Target, '-S', '-40')
    if (-not $result.Ok) { return $false }
    $tail40 = Get-FmTmuxSubstituted $result.StdOut
    if ([string]::IsNullOrEmpty($tail40)) { return Test-FmTmuxBusyLine -Text '' -Harness $Harness }

    $blank = [System.Text.RegularExpressions.Regex]::new('^' + $script:FmTmuxPosixSpaceClass + '*$')
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $tail40.Split("`n")) {
        if (-not $blank.IsMatch($line)) { [void]$kept.Add($line) }
    }
    if ($kept.Count -gt 12) { $kept.RemoveRange(0, $kept.Count - 12) }
    return Test-FmTmuxBusyLine -Text ($kept -join "`n") -Harness $Harness
}

# --- verify-and-retry submit -------------------------------------------------

# `sleep 0.05`. Parsed with the invariant culture so a comma-decimal host cannot
# reinterpret the value, and a value that is not a number sleeps zero (see
# divergence (c) in the header).
function Wait-FmTmuxInterval {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds = '')
    if ([string]::IsNullOrEmpty($Seconds)) { return }
    [double]$value = 0
    $ok = [double]::TryParse($Seconds, [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)
    if (-not $ok -or $value -le 0) { return }
    Start-Sleep -Milliseconds ([int][Math]::Round($value * 1000))
}

<#
.SYNOPSIS
Submit with Enter, retried, verifying the composer cleared. Never retypes.
.DESCRIPTION
Twin of fm_tmux_submit_enter_core. Returns the final proof-carrying verdict so a
caller can require exact `empty` before treating submission as confirmed.

Retries Enter ONLY. A swallowed Enter leaves our text in the composer, and
retyping would DUPLICATE a captain instruction into a live agent - which is why
the text send lives in Send-FmTmuxSubmit and is never reached from here.

Busy-queued Enter (opencode 1.18.4): once the retry budget is spent and a
structurally proven composer still reads `pending`, a busy pane means the
harness accepted and queued the Enter, so `empty` is reported and the caller
does not re-send; an idle pane keeps `pending` as a genuine swallow.
`pending-unproven` receives the same retry budget but never reaches this
exception, and any unrecognised verdict is returned untouched.
#>
function Send-FmTmuxEnterSubmit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0'
    )

    [int]$budget = 0
    if (-not [int]::TryParse($Retries, [ref]$budget)) { $budget = 0 }

    $i = 0
    $state = ''
    while ($true) {
        # `|| true`: a failed Enter is not fatal here, because the verdict comes
        # from reading the composer afterwards, not from the send's status.
        $null = Invoke-FmTmuxCommand @('send-keys', '-t', $Target, 'Enter')
        Wait-FmTmuxInterval $EnterSleep
        $state = Get-FmTmuxComposerState $Target
        if (-not ([string]::Equals($state, 'pending', $script:FmTmuxOrdinal) -or
                  [string]::Equals($state, 'pending-unproven', $script:FmTmuxOrdinal))) {
            return $state
        }
        $i++
        if ($i -ge $budget) { break }
    }

    if (-not [string]::Equals($state, 'pending', $script:FmTmuxOrdinal)) { return $state }
    if (Test-FmTmuxPaneBusy $Target) { return 'empty' }
    return 'pending'
}

<#
.SYNOPSIS
Type text into a target ONCE, settle, then submit and verify.
.DESCRIPTION
Twin of fm_tmux_submit_core. A failed literal send short-circuits to
`send-failed` without ever pressing Enter, so a target that refused the text can
never be told to submit whatever it already held.
#>
function Send-FmTmuxSubmit {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Text = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Retries = '0',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$EnterSleep = '0',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$Settle = '0'
    )

    $sent = Invoke-FmTmuxCommand @('send-keys', '-t', $Target, '-l', $Text)
    if (-not $sent.Ok) { return 'send-failed' }
    Wait-FmTmuxInterval $Settle
    return Send-FmTmuxEnterSubmit -Target $Target -Retries $Retries -EnterSleep $EnterSleep
}

Export-ModuleMember -Function @(
    'Invoke-FmTmuxCommand',
    'Get-FmTmuxBusyRegex', 'Test-FmTmuxBusyLine',
    'Get-FmTmuxRealText',
    'Test-FmTmuxComposerEdge', 'Get-FmTmuxComposerGeometrySpace',
    'Get-FmTmuxComposerRowState', 'Find-FmTmuxComposerBox',
    'Get-FmTmuxComposerState', 'Test-FmTmuxInputPending', 'Test-FmTmuxPaneBusy',
    'Send-FmTmuxEnterSubmit', 'Send-FmTmuxSubmit'
)
