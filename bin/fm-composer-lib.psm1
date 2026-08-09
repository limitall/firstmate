# bin/fm-composer-lib.psm1 - the ONE fleet-wide owner of composer-content
# classification for the PowerShell tree, shared by every session-provider
# adapter twin exactly as its bash oracle is.
#
# Twin: bin/fm-composer-lib.sh
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-composer-lib.sh           this file
#   ------------------------------   ---------------------------------
#   fm_composer_strip_ansi           Get-FmComposerPlainText
#   fm_composer_strip_ghost          Get-FmComposerRealText
#   fm_composer_idle_matches         Test-FmComposerIdleMatch
#   fm_composer_classify_content     Get-FmComposerContentState
#
# The two strip_* twins are NOT spelled Remove-*, which would read closer to the
# bash names: PSScriptAnalyzer classifies Remove- as a state-changing verb and
# demands SupportsShouldProcess, and bolting -WhatIf onto a pure string
# transform would be a lie (under -WhatIf it would return nothing at all). The
# Get- names come from the bash twin's own comments, which call the outputs
# "plain text" and "real typed content".
#
# Get-FmComposerContentState keeps the CONTENT qualifier the bash name carries:
# this owner classifies content a caller has already extracted, while the
# adapters classify a whole pane (fm_tmux_composer_state and friends). Losing
# that word would collide those two ideas at exactly the layer where they must
# stay distinct.
#
# WHY THIS EXISTS (task fm-composer-shellglyph-safety): the four adapters each
# carried their own copy of the "is this composer row empty / pending / not an
# agent composer" decision, and the copies drifted. The dangerous drift: a BARE
# shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has
# exited to a plain login shell - was treated as an empty, ready-to-inject
# AGENT composer. The away-mode escalation injector reads composer-emptiness to
# decide whether a pane is a safe injection target, so a dead-shell pane misread
# as "empty" meant an escalation could be typed into (and, worst case, executed
# by) that shell. Consolidating the one decision here means the safety rule
# cannot silently drift across adapters again - and now that there are TWO
# language trees, it must not drift across those either, which is what the
# differential suite tests/fm-composer-lib-psm1.test.sh exists to prove.
#
# THE SAFETY RULE this owner enforces: a bare shell prompt glyph is a genuine
# empty agent composer ONLY when it appears INSIDE a real agent-composer
# container - a bordered composer box, where the harness draws its own prompt
# glyph (e.g. claude's older `| > ... |`). On a bare, unstructured row it is a
# dead-shell prompt and is NEVER "empty"; it classifies as `unknown` (not a safe
# injection target). The AGENT prompt glyphs U+276F (claude) and U+203A (codex)
# are a genuine empty agent composer either way, bordered or bare.
#
# GHOST/PLACEHOLDER TEXT is the other half of this owner (task
# afk-herdr-false-pending): a harness fills an otherwise-empty composer with
# de-emphasized ghost text - claude's rotating prompt suggestion, codex's idle
# suggestion, grok's placeholder - which a plain capture cannot tell apart from
# text a human typed, so the away-mode injector reads the idle pane as "pending
# input" and defers every escalation (the overnight wedge that motivated this
# consolidation). Get-FmComposerRealText is the ONE ANSI-aware extractor of
# "real typed content": it drops every de-emphasized run - dim/faint (SGR 2, how
# claude and codex render ghost text) AND a dark/muted TRUECOLOR foreground (how
# grok renders placeholder/hint text) - and keeps only normal-intensity,
# normally-coloured text.
#
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives. Once an adapter has a candidate
# composer row it hands the RAW styled row to Get-FmComposerRealText, strips the
# box borders, trims, and hands the result plus a <bordered> flag to
# Get-FmComposerContentState for the shared empty|pending|unknown verdict.
#
# ---------------------------------------------------------------------------
# WHAT THE POWERSHELL TWIN CHANGES, AND WHAT IT DELIBERATELY DOES NOT
#
# 1. NO SUBPROCESSES. The bash owner shells out to `sed` (strip_ansi), `awk`
#    (strip_ghost) and `grep` (idle match) on every call. Those are the hottest
#    string helpers in the supervision loop and each one costs an MSYS fork
#    here. This module does the same work in-process; that is a large part of
#    why the port is worth doing, and it is the only mechanical difference the
#    verdicts are allowed to have.
#
# 2. THE LOCALE BYTE-COUNTING HAZARD DISAPPEARS - IN ONE DIRECTION ONLY. The
#    bash twin carries a fix worth understanding before touching the glyph
#    arithmetic below: `${content#??}` counts BYTES under a C/POSIX locale (the
#    bash comment records the host it was found on as having LANG unset; note 5
#    covers what the locale still decides here), so stripping the "U+276F SPACE"
#    prefix with `??` removed only 2 bytes and left a mangled tail that missed
#    the idle-placeholder match (verified live: a grok placeholder read
#    'pending' instead of 'empty'). The bash twin therefore strips the
#    multibyte glyphs as LITERAL prefixes. PowerShell strings are UTF-16 code
#    units, so the byte/char confusion cannot happen here - but the same code
#    must still agree with the FIXED bash for BOTH the single-glyph and
#    glyph-plus-space forms, so the strip below is written against
#    `$glyph.Length` rather than a hard-coded 2. Both agent glyphs are BMP
#    (one code unit each) today; a future astral glyph would need a surrogate
#    pair and the Length arithmetic already covers it.
#
# 3. UTF-8 OUTPUT IS INHERITED, NOT REIMPLEMENTED. Without an explicit console
#    encoding PowerShell renders U+276F as '?', which would destroy this
#    module's entire glyph vocabulary. bin/fm-common.psm1 installs UTF-8
#    (no BOM) on both console streams at import; importing it below is what
#    buys that, and nothing here re-solves it.
#
# 4. THE GLYPHS ARE BUILT FROM CODE POINTS, NOT LITERALS. The verdicts turn on
#    exact equality with U+276F and U+203A. Spelling them as [char] code points
#    removes any dependency on how this file's bytes are decoded by a host, an
#    editor, or a patch tool - the one hazard that would silently turn every
#    "empty agent composer" verdict into "unknown".
#
# 5. THE WHITESPACE TRIM IS LOCALE-DEPENDENT, AND STAYS THAT WAY. bash resolves
#    [[:space:]] against LC_CTYPE, so the same composer row trims to nothing
#    (empty, i.e. safe to inject into) under a UTF-8 locale and survives as
#    pending under C. This module reproduces that decision rather than picking
#    one side, because picking C would disagree with every UTF-8 host the fleet
#    actually runs on, and picking Unicode would disagree - in the UNSAFE
#    direction - with anything that pins LC_ALL=C. See Get-FmComposerTrimSet,
#    whose two sets and precedence were measured against the bash twin.
#
# KNOWN DIVERGENCES FROM THE BASH ORACLE (deliberate, and not silently
# normalized away by the differential suite):
#
#   a. RETURN SHAPE. The bash strip helpers are stdin filters whose awk/sed
#      output always ends with a newline, and every bash call site consumes them
#      through `$( ... )`, which strips trailing newlines. These return a STRING
#      with no terminator, i.e. exactly what a bash caller ends up holding.
#
#   b. AN INVALID IDLE REGEX IS SILENT HERE. `grep -qE '['` prints
#      "grep: Invalid regular expression" on stderr and exits non-zero, which
#      the bash twin reads as NO MATCH. This twin also reads it as no match but
#      emits no diagnostic. The VERDICT is identical; only the stderr noise is
#      not reproduced.
#
#   c. POSIX ERE vs .NET REGEX. Idle patterns are matched by grep -E in bash and
#      by System.Text.RegularExpressions here. Every pattern the fleet actually
#      ships ('^Type a message\.\.\.$' in the herdr, orca and cmux adapters, and
#      whatever FM_COMPOSER_IDLE_RE holds for tmux) is in the common subset. A
#      pattern using POSIX bracket expressions ([[:alpha:]]) or relying on
#      GNU-grep's treatment of undefined escapes would differ; none does.
#
#   d. AN UNLOADABLE LOCALE NAME. Get-FmComposerTrimSet matches the locale name
#      rather than resolving it, so a name that is neither C nor POSIX but that
#      the host cannot load falls back to C in bash and to the Unicode set here.
#
#   e. A NON-NUMERIC FM_COMPOSER_GHOST_LUMA_MAX. awk would compare the computed
#      luminance against such a value as STRINGS (making every foreground read
#      "dark", i.e. stripping real text - the unsafe direction). This twin
#      parses the knob with awk's own leading-numeric-prefix rule and treats a
#      wholly non-numeric value as 0, so nothing is treated as dark. That is the
#      safe direction the bash comments argue for ("real text wins:
#      under-stripping merely defers"), and the knob is documented as numeric.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force here, and that is load-bearing rather than a style choice. The port
# convention is `Import-Module <path> -Force` for a top-level CONSUMER, but a
# nested -Force REMOVES the already-loaded module before re-importing it, and
# the removal is global: verified live, a caller that had imported
# fm-common.psm1 itself loses Write-FmOut the moment it imports this module.
# Without -Force the already-loaded instance is reused and the caller keeps its
# own commands, while this module still gets fm-common in its own scope either
# way. The cost is that a stale fm-common stays loaded within one session during
# development; re-importing it explicitly with -Force fixes that and no longer
# breaks anything.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# --- ordinal string comparison -----------------------------------------------
#
# EVERY string comparison in this file goes through StringComparison::Ordinal,
# and that is a correctness requirement, not a style preference. PowerShell's
# -eq / -ceq / -ccontains and .NET's default String.Equals, StartsWith and
# EndsWith are CULTURE-sensitive, which makes zero-width characters IGNORABLE.
# Verified live on this host:
#
#   ([char]0x200B) -ceq ''          -> True
#   (([char]0x200B) + '>') -ceq '>' -> True
#   @('>','$') -ccontains (([char]0x200B) + '>') -> True
#
# bash compares BYTES, so it answers False to all three. The consequences here
# are not academic: a composer row holding only a zero-width space would read
# 'empty' instead of 'pending', and a row of ZERO-WIDTH-SPACE + '>' inside a box
# would take the shell-glyph arm and read 'empty' - both of them the "safe to
# inject into" verdict, on rows bash refuses. The differential suite caught
# exactly this, which is why the U+200B and U+FEFF cases are in it.
$script:FmOrdinal = [System.StringComparison]::Ordinal

# Ordinal membership. [Array]::IndexOf over a typed [string[]] uses
# EqualityComparer<string>.Default, which IS ordinal - unlike -ccontains.
function Test-FmComposerGlyphIs {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Glyphs = @(),
        [AllowEmptyString()][AllowNull()][string]$Value = ''
    )
    return ([Array]::IndexOf($Glyphs, $Value) -ge 0)
}

# --- glyph vocabulary --------------------------------------------------------

# U+276F HEAVY RIGHT-POINTING ANGLE QUOTATION MARK ORNAMENT - claude's prompt.
$script:FmComposerGlyphClaude = [string][char]0x276F
# U+203A SINGLE RIGHT-POINTING ANGLE QUOTATION MARK - codex's prompt.
$script:FmComposerGlyphCodex = [string][char]0x203A
# The AGENT glyphs: an empty agent composer bordered or bare. Typed [string[]]
# so the ordinal [Array]::IndexOf above applies.
$script:FmComposerAgentGlyphs = [string[]]@($script:FmComposerGlyphClaude, $script:FmComposerGlyphCodex)
# The SHELL glyphs: empty only inside a bordered composer box (see THE SAFETY
# RULE above); bare, they are a dead shell and never a safe injection target.
$script:FmComposerShellGlyphs = [string[]]@('>', '$', '%', '#')
# Every prompt glyph, agent first, matching the bash `case` arm order.
$script:FmComposerAllGlyphs = [string[]]($script:FmComposerAgentGlyphs + $script:FmComposerShellGlyphs)

# --- the [[:space:]] trim set, which is LOCALE-DEPENDENT ---------------------
#
# The bash twin trims with `${content#"${content%%[![:space:]]*}"}`, and bash
# resolves [[:space:]] against the process's LC_CTYPE. That makes the trim the
# ONE genuinely locale-dependent decision in this owner, and getting it wrong is
# not cosmetic: a row holding only a non-breaking space is 'empty' (safe to
# inject into) under one locale and 'pending' (leave it alone) under the other.
#
# Both sets below were MEASURED against the bash twin on this host with the
# fixture bytes held fixed and only the classifier's locale varied, rather than
# assumed from any standard:
#
#   LC_ALL/LC_CTYPE/LANG = C, POSIX, or unset -> the six ASCII members only.
#   any UTF-8 locale, C.UTF-8 included        -> the Unicode set below.
#
# The Unicode set is exactly .NET's Char.IsWhiteSpace MINUS U+0085 NEL, which
# .NET calls whitespace and bash does not. U+200B ZERO WIDTH SPACE and U+FEFF
# are whitespace to neither. Using String.Trim() with no arguments would
# therefore be wrong by exactly one code point - and using the ASCII set
# unconditionally would be wrong by fifteen on every UTF-8 host, which is what
# the fleet actually runs.
$script:FmComposerPosixSpace = [char[]]@(0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20)
$script:FmComposerUnicodeSpace = [char[]]@(
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20,
    0x00A0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
    0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000
)

<#
.SYNOPSIS
The [[:space:]] set the bash twin would use for the current locale.
.DESCRIPTION
Reproduces bash's own LC_ALL > LC_CTYPE > LANG precedence, with `:-` semantics
at each step so an EMPTY variable falls through exactly as bash's does (measured,
not assumed: `LC_ALL= LC_CTYPE=en_US.UTF-8 LANG=C` resolves to the UTF-8 set).

Read fresh on every call rather than cached at import, because the differential
suite drives the same process under both locales and a cached answer would make
the second run silently report the first one's verdicts.

One simplification, stated rather than hidden: this matches the locale NAME
rather than resolving it. A name that is neither 'C' nor 'POSIX' but that the
host cannot actually load (a typo, or a locale that is not installed) makes bash
fall back to C while this returns the Unicode set. Every real firstmate
environment names a valid locale or none at all.
#>
function Get-FmComposerTrimSet {
    [CmdletBinding()]
    [OutputType([char[]])]
    param()

    $locale = Get-FmEnv -Name 'LC_ALL'
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LC_CTYPE' }
    if ([string]::IsNullOrEmpty($locale)) { $locale = Get-FmEnv -Name 'LANG' }
    if ([string]::IsNullOrEmpty($locale) -or
        [string]::Equals($locale, 'C', $script:FmOrdinal) -or
        [string]::Equals($locale, 'POSIX', $script:FmOrdinal)) {
        return $script:FmComposerPosixSpace
    }
    return $script:FmComposerUnicodeSpace
}

# --- awk-compatible numeric coercion -----------------------------------------

<#
.SYNOPSIS
Coerce a string to a number the way awk's `str + 0` does.
.DESCRIPTION
awk converts a string to a number by taking its leading numeric prefix and
yielding 0 when there is none ("37m" -> 37, "abc" -> 0). The SGR parser below
depends on that exact rule for its `code + 0 >= 30 && code + 0 <= 37` range
tests, and .NET's parsers all reject trailing garbage instead, so the rule is
reproduced here rather than approximated.
#>
function ConvertTo-FmAwkNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return [double]0 }
    $m = [regex]::Match($Text, '^[ \t\n\r\f\v]*[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?')
    if (-not $m.Success) { return [double]0 }
    [double]$value = 0
    $ok = [double]::TryParse(
        $m.Value.Trim(),
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$value)
    if (-not $ok) { return [double]0 }
    return $value
}

# --- SGR parameter helpers (private) -----------------------------------------

<#
.SYNOPSIS
The bash twin's awk `sgr_code`: an SGR parameter's leading code.
.DESCRIPTION
An ITU colon-form parameter carries its whole colour in one field
("38:2::224:222:244"), so the code is everything before the first ':'. An empty
field reads as "0", which is why "ESC[;m" and "ESC[2;m" both reset.

The comparisons that consume this result are STRING comparisons, exactly as
awk performs them on split() output against string constants - verified live
against the bash twin: "ESC[00m" does NOT end a dim run and "ESC[02m" does NOT
start one, because "00" != "0" and "02" != "2" as strings.
#>
function Get-FmSgrCode {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Parameter)

    $code = $Parameter
    $colon = $code.IndexOf(':')
    if ($colon -ge 0) { $code = $code.Substring(0, $colon) }
    if ([string]::IsNullOrEmpty($code)) { $code = '0' }
    return $code
}

<#
.SYNOPSIS
The bash twin's awk `skip_color_payload`: index of an extended colour's last
parameter.
.DESCRIPTION
SGR 38/48/58 are followed by a selector and its payload, and those payload
digits must NOT be re-read as attributes - the whole point of the helper is that
the `2` in "ESC[38;2;R;G;B" is a truecolor SELECTOR, not the dim attribute. The
colon form keeps everything in one field and consumes nothing extra.

$Params is a 1-BASED array (index 0 unused) so this reads against the awk
original line for line; $Index and $Count are awk's `p` and `k`.
#>
function Get-FmSgrColorPayloadEnd {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        # Not Mandatory: PowerShell's mandatory binding rejects a [string[]]
        # whose elements include an empty string, and an SGR run legitimately
        # carries empty parameters ("ESC[2;m"). Every call site passes it by
        # name, so the guard would buy nothing anyway.
        [string[]]$Params = @(),
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Count
    )

    if ($Params[$Index].IndexOf(':') -ge 0) { return $Index }
    if ($Index -ge $Count) { return $Index }
    $mode = $Params[$Index + 1]
    $code = Get-FmSgrCode -Parameter $mode
    if ($mode.IndexOf(':') -ge 0) { return $Index + 1 }
    if ([string]::Equals($code, '5', $script:FmOrdinal)) { return $Index + 2 }
    if ([string]::Equals($code, '2', $script:FmOrdinal)) { return $Index + 4 }
    return $Index + 1
}

<#
.SYNOPSIS
The bash twin's awk `fg38_is_dark`: is this SGR 38 foreground a dark truecolor?
.DESCRIPTION
True only for a TRUECOLOR foreground (38;2;R;G;B or the colon form 38:2::R:G:B)
whose perceived luminance (0.299R + 0.587G + 0.114B) is below $LumaMax - how
grok renders placeholder and hint text. A 256-colour foreground (38;5;n) is
deliberately NOT luminance-tested: it is palette-dependent and no fleet harness
uses it for ghost text, so it is kept. Real text wins, because under-stripping
merely defers an escalation (which the max-defer alarm surfaces) while
over-stripping would inject over real input.

This assumes a DARK terminal theme, the firstmate fleet reality, where real
typed input is bright and only de-emphasised UI is dark; the SGR-2 signal is
theme-independent and covers the rest.
#>
function Test-FmSgrFg38Dark {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Not Mandatory, for the empty-parameter reason in
        # Get-FmSgrColorPayloadEnd.
        [string[]]$Params = @(),
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][double]$LumaMax
    )

    $spec = $Params[$Index]
    if ($spec.IndexOf(':') -ge 0) {
        # Colon form: the whole colour lives in this one field. Split on ':'
        # with String.Split, which PRESERVES empty fields - "38:2::224:222:244"
        # must stay 6 fields, because the colours are read from the END.
        $f = $spec.Split(':')
        $nf = $f.Count
        if (-not [string]::Equals($f[1], '2', $script:FmOrdinal) -or $nf -lt 5) { return $false }
        $r = ConvertTo-FmAwkNumber $f[$nf - 3]
        $g = ConvertTo-FmAwkNumber $f[$nf - 2]
        $b = ConvertTo-FmAwkNumber $f[$nf - 1]
        return ((299 * $r + 587 * $g + 114 * $b) / 1000) -lt $LumaMax
    }
    # Semicolon form: the selector and three channels follow as separate
    # parameters, and a truncated run ("ESC[38;2m") is not a colour at all.
    if (((($Index + 1) -gt $Count)) -or
        (-not [string]::Equals($Params[$Index + 1], '2', $script:FmOrdinal)) -or
        (($Index + 4) -gt $Count)) {
        return $false
    }
    $r = ConvertTo-FmAwkNumber $Params[$Index + 2]
    $g = ConvertTo-FmAwkNumber $Params[$Index + 3]
    $b = ConvertTo-FmAwkNumber $Params[$Index + 4]
    return ((299 * $r + 587 * $g + 114 * $b) / 1000) -lt $LumaMax
}

<#
.SYNOPSIS
Strip de-emphasized runs from ONE styled row (the awk main block).
.DESCRIPTION
Walks the row left to right, tracking two independent de-emphasis states (dim
and dark-foreground) that both reset at the start of every row exactly as awk
resets them per record. Codes are processed left to right WITHIN a sequence, so
"ESC[0;2m" reads as dim.

Three escape shapes the bash twin handles and this must too, each verified
against it:
  - a complete CSI whose final byte is 'm' updates the de-emphasis state and is
    consumed;
  - a complete CSI with any other final byte ("ESC[2K", "ESC[?25h") is consumed
    whole and changes nothing;
  - an ESC that is not followed by '[', or a CSI that never reaches a final byte
    before end of row, drops ONLY the ESC byte and leaves the rest as literal
    text ("ESC[2" at end of row emits "[2").

The row is walked as CHARS while awk (under LC_ALL=C) walks BYTES. That is
equivalent here and not a shortcut: ESC and every CSI byte are ASCII, and a
UTF-8 multibyte glyph's continuation bytes are all >= 0x80, so no glyph can
straddle a state change - its bytes are kept or dropped together either way.
#>
function Get-FmComposerRealTextLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][double]$LumaMax
    )

    $dim = $false
    $darkFg = $false
    $n = $Line.Length
    $i = 0
    $out = [System.Text.StringBuilder]::new()

    while ($i -lt $n) {
        if ([int]$Line[$i] -eq 0x1B) {          # ESC
            $j = $i + 1
            if ($j -lt $n -and [int]$Line[$j] -eq 0x5B) {   # '[' : a CSI
                $j++
                $paramStart = $j
                while ($j -lt $n) {
                    $byte = [int]$Line[$j]
                    if ($byte -ge 0x40 -and $byte -le 0x7E) { break }   # CSI final byte
                    $j++
                }
                $params = $Line.Substring($paramStart, $j - $paramStart)
                if ($j -lt $n -and [int]$Line[$j] -eq 0x6D) {           # 'm' : SGR
                    if ([string]::IsNullOrEmpty($params)) { $params = '0' }
                    # String.Split preserves empty fields; "ESC[2;m" must stay
                    # two parameters so the empty one still reads as a reset.
                    $fields = $params.Split(';')
                    $count = $fields.Count
                    $a = [string[]]::new($count + 1)
                    $a[0] = ''
                    for ($t = 0; $t -lt $count; $t++) { $a[$t + 1] = $fields[$t] }

                    $p = 1
                    while ($p -le $count) {
                        $code = Get-FmSgrCode -Parameter $a[$p]
                        if ([string]::Equals($code, '38', $script:FmOrdinal)) {
                            $darkFg = Test-FmSgrFg38Dark -Params $a -Index $p -Count $count -LumaMax $LumaMax
                            $p = Get-FmSgrColorPayloadEnd -Params $a -Index $p -Count $count
                        } elseif ([string]::Equals($code, '48', $script:FmOrdinal) -or [string]::Equals($code, '58', $script:FmOrdinal)) {
                            $p = Get-FmSgrColorPayloadEnd -Params $a -Index $p -Count $count
                        } elseif ([string]::Equals($code, '2', $script:FmOrdinal)) {
                            $dim = $true
                        } elseif ([string]::Equals($code, '0', $script:FmOrdinal)) {
                            $dim = $false
                            $darkFg = $false
                        } elseif ([string]::Equals($code, '22', $script:FmOrdinal)) {
                            $dim = $false
                        } elseif ([string]::Equals($code, '39', $script:FmOrdinal)) {
                            $darkFg = $false
                        } else {
                            # Any base foreground colour ends a dark-foreground
                            # run. awk's numeric coercion, not .NET's parser:
                            # see ConvertTo-FmAwkNumber.
                            $num = ConvertTo-FmAwkNumber $code
                            if (($num -ge 30 -and $num -le 37) -or ($num -ge 90 -and $num -le 97)) {
                                $darkFg = $false
                            }
                        }
                        $p++
                    }
                }
                if ($j -lt $n) { $i = $j + 1; continue }
            }
            $i = $i + 1                 # lone/other/unterminated ESC: drop the ESC only
            continue
        }
        if (-not $dim -and -not $darkFg) { [void]$out.Append($Line[$i]) }
        $i++
    }
    return $out.ToString()
}

# --- public surface ----------------------------------------------------------

<#
.SYNOPSIS
Drop every CSI escape sequence, leaving plain text.
.DESCRIPTION
Twin of fm_composer_strip_ansi. Used for STRUCTURAL row/shape detection, where
ghost text must be KEPT so the composer box border or bare prompt glyph is still
visible; content extraction uses Get-FmComposerRealText instead.

The character class includes ':' so an ITU colon-form SGR (38:2::r:g:b) is
stripped whole, not left with a dangling tail. [A-Za-z] is [[:alpha:]] under the
C locale the bash twin's sed runs in - deliberately NOT .NET's \p{L}, which
would also consume letters from other scripts that a real terminal never emits
as a CSI final byte.

Unlike Get-FmComposerRealText, a LONE ESC is preserved: the bash twin's sed
pattern requires a complete "ESC [ params final" run, so an incomplete one is
left alone byte for byte.
#>
function Get-FmComposerPlainText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '\x1b\[[0-9;:?]*[A-Za-z]', '')
}

<#
.SYNOPSIS
The ONE fleet-wide ANSI-aware extractor of "real typed content" from a captured,
styled composer row.
.DESCRIPTION
Twin of fm_composer_strip_ghost. Takes the styled text (from `tmux capture-pane
-e` or `herdr pane read --format ansi`) and returns the plain, non-ghost text,
dropping:

  - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
    A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
  - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
    38:2::r:g:b) whose perceived luminance is below FM_COMPOSER_GHOST_LUMA_MAX
    (default 128): how grok renders its placeholder and hint text. A reset
    (SGR 0), a default-foreground (SGR 39), any base foreground colour (30-37 /
    90-97), or a lighter 38;2 foreground ends the dark-foreground run.

Multi-line input is processed per line, with de-emphasis state reset at each
line boundary, matching awk's per-record state. The result carries no trailing
newline: awk's `print` adds one per record and every bash call site strips it
through `$( ... )`, so this returns what a bash caller ends up holding.

The luminance knob is read fresh on every call, exactly as the bash twin passes
`-v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}"` into a fresh awk each time, so
a test or adapter can change it between calls.
#>
function Get-FmComposerRealText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ($null -eq $Text) { $Text = '' }
    $lumaMax = ConvertTo-FmAwkNumber (Get-FmEnv -Name 'FM_COMPOSER_GHOST_LUMA_MAX' -Default '128')

    # awk reads RECORDS: a trailing newline TERMINATES the last record rather
    # than starting an empty one, so exactly one is dropped before splitting.
    $body = $Text
    if ($body.EndsWith("`n", $script:FmOrdinal)) { $body = $body.Substring(0, $body.Length - 1) }

    $lines = $body.Split("`n")
    $out = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -gt 0) { [void]$out.Append("`n") }
        [void]$out.Append((Get-FmComposerRealTextLine -Line $lines[$i] -LumaMax $lumaMax))
    }
    return $out.ToString()
}

<#
.SYNOPSIS
Does this composer content match a harness's known idle placeholder?
.DESCRIPTION
Twin of fm_composer_idle_matches. An empty $Pattern never matches, mirroring the
bash guard that skips grep entirely when no idle regex was supplied.

Three grep behaviours are reproduced exactly, each pinned by the differential
suite:
  - grep matches PER LINE, so a multi-line content matches when ANY line does.
  - EMPTY content is zero lines, which grep can never match - not even with
    '^$'. A single trailing newline still terminates one line rather than
    adding an empty one, so 'a\n' has one line and '\n' has one EMPTY line.
  - An invalid pattern makes grep exit non-zero, which the bash twin reads as
    NO MATCH. Here the regex constructor throws and is caught to the same
    verdict (see divergence (b) in the file header: no stderr diagnostic).

$Case is compared case-SENSITIVELY against the literal 'insensitive', exactly as
the bash `case` arm is: 'INSENSITIVE' falls through to the default, sensitive
branch.
#>
function Test-FmComposerIdleMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Content = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Pattern = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Case = ''
    )

    if ([string]::IsNullOrEmpty($Pattern)) { return $false }
    if ([string]::IsNullOrEmpty($Content)) { return $false }

    $options = [System.Text.RegularExpressions.RegexOptions]::None
    if ([string]::Equals($Case, 'insensitive', $script:FmOrdinal)) {
        $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                   [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    }

    $rx = $null
    try {
        $rx = [System.Text.RegularExpressions.Regex]::new($Pattern, $options)
    } catch {
        return $false
    }

    $body = $Content
    if ($body.EndsWith("`n", $script:FmOrdinal)) { $body = $body.Substring(0, $body.Length - 1) }
    foreach ($line in $body.Split("`n")) {
        if ($rx.IsMatch($line)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
The single shared composer-content verdict: empty, pending, or unknown.
.DESCRIPTION
Twin of fm_composer_classify_content, with the same positional argument order.

  -Bordered      '1' when the content came from a genuine agent-composer
                 container (a bordered composer box, or a structurally
                 identified bare AGENT prompt row); anything else means a bare,
                 unstructured row (e.g. tmux's raw cursor line that carried no
                 box border). Compared as a STRING against '1', exactly as
                 `[ "$bordered" = 1 ]` is, so '01', 'yes' and '' are all "not
                 bordered".
  -Content       the candidate composer content, already border-stripped and
                 whitespace-trimmed by the caller.
  -IdleRegex     optional per-harness idle-placeholder regex (e.g. grok's
                 "Type a message...") that reads as empty; matched both before
                 and after a leading prompt glyph is stripped, so a pattern
                 written with or without the glyph both land.
  -IdleCase      'insensitive' to match the idle regex case-insensitively;
                 anything else (including the default) is case-sensitive.
  -PlainContent  the same row with ANSI stripped but ghost text KEPT, so a row
                 whose only content was ghost styling can still be told apart
                 from a genuinely blank one.

The three optional parameters reproduce bash's `:-` defaults, where an EMPTY
argument is indistinguishable from an absent one: an empty -IdleCase means
'sensitive' and an empty -PlainContent falls back to -Content, exactly as
`${4:-sensitive}` and `${5:-$content}` do.
#>
function Get-FmComposerContentState {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Bordered = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Content = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$IdleRegex = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$IdleCase = '',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$PlainContent = ''
    )

    if ($null -eq $Bordered) { $Bordered = '' }
    if ($null -eq $Content) { $Content = '' }
    if ($null -eq $IdleRegex) { $IdleRegex = '' }
    if ([string]::IsNullOrEmpty($IdleCase)) { $IdleCase = 'sensitive' }
    if ([string]::IsNullOrEmpty($PlainContent)) { $PlainContent = $Content }

    # Ghost-stripping emptied the row, but the row was NOT blank: judge it on
    # what was actually on screen. Only a verified AGENT glyph survives this as
    # 'empty'; everything else (a dead shell's prompt, a styled banner) is
    # unknown and therefore not an injection target.
    if ((-not [string]::Equals($Bordered, '1', $script:FmOrdinal)) -and
        [string]::IsNullOrEmpty($Content) -and
        (-not [string]::IsNullOrEmpty($PlainContent))) {
        if (Test-FmComposerGlyphIs -Glyphs $script:FmComposerAgentGlyphs -Value $PlainContent) { return 'empty' }
        return 'unknown'
    }

    # A bare prompt glyph on its own row.
    if (Test-FmComposerGlyphIs -Glyphs $script:FmComposerAgentGlyphs -Value $Content) {
        # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
        return 'empty'
    }
    if (Test-FmComposerGlyphIs -Glyphs $script:FmComposerShellGlyphs -Value $Content) {
        # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
        # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
        if ([string]::Equals($Bordered, '1', $script:FmOrdinal)) { return 'empty' }
        return 'unknown'
    }

    # Nothing on the row = empty composer.
    if ([string]::IsNullOrEmpty($Content)) { return 'empty' }

    # Known idle placeholder (matched before a leading glyph is stripped).
    if (Test-FmComposerIdleMatch -Content $Content -Pattern $IdleRegex -Case $IdleCase) {
        return 'empty'
    }

    # Strip a leading prompt glyph, then re-judge the remainder. The two tiers
    # match the bash `case` order: EVERY glyph-plus-space form is tried before
    # any bare-glyph form, so "> " loses both characters while ">" alone was
    # already answered above. Ordinal comparison and $glyph.Length arithmetic
    # keep this locale- and encoding-independent (see note 2 in the header).
    $work = $Content
    $stripped = $false
    foreach ($glyph in $script:FmComposerAllGlyphs) {
        if ($work.StartsWith($glyph + ' ', [System.StringComparison]::Ordinal)) {
            $work = $work.Substring($glyph.Length + 1)
            $stripped = $true
            break
        }
    }
    if (-not $stripped) {
        foreach ($glyph in $script:FmComposerAllGlyphs) {
            if ($work.StartsWith($glyph, [System.StringComparison]::Ordinal)) {
                $work = $work.Substring($glyph.Length)
                break
            }
        }
    }
    $work = $work.Trim((Get-FmComposerTrimSet))

    if ([string]::IsNullOrEmpty($work)) { return 'empty' }

    # Known idle placeholder (matched again after the leading glyph was stripped,
    # e.g. "<agent glyph> Type a message...").
    if (Test-FmComposerIdleMatch -Content $work -Pattern $IdleRegex -Case $IdleCase) {
        return 'empty'
    }

    # Real, unsubmitted content remains.
    return 'pending'
}

Export-ModuleMember -Function @(
    'Get-FmComposerPlainText',
    'Get-FmComposerRealText',
    'Test-FmComposerIdleMatch',
    'Get-FmComposerContentState'
)
