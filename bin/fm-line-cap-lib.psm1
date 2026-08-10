# fm-line-cap-lib.psm1 - shared per-line cap for agent-facing digest lines.
#
# Twin: bin/fm-line-cap-lib.sh
#
# ONE OWNER for the bounded-line shape both digests use. The wake digest's
# OPEN DECISIONS section (bin/fm-wake-drain.ps1) and the session-start digest's
# per-task status tails (bin/fm-session-start.ps1) render the same kind of
# content - an agent-written status line, which AGENTS.md section 8 treats as a
# wake EVENT rather than current state - into a size-bounded view. An agent
# reading both must recognize one truncation marker, and the two caps must not
# drift apart, so the cut and its marker live here.
#
# Callers keep their own composite policy: the wake drain still owns the OPEN
# DECISIONS global byte cap and its "N more omitted" disclosure, and
# session-start still owns how many tail lines it prints per task. This file
# owns only the per-line cut.
#
# The cap counts characters, so a plain-ASCII line - what status lines are in
# practice - is bounded to the same number of bytes, and a multibyte character
# is never cut in half into an invalid sequence.
# Truncation stays recoverable because the session-start digest prints each
# task's full status log path, while every OPEN DECISIONS entry begins with the
# task id that identifies its durable state/<id>.status source.
#
# bash -> PowerShell:
#   FM_LINE_CAP_DEFAULT   -> Get-FmLineCapDefault
#   FM_LINE_CAP_SUFFIX    -> Get-FmLineCapSuffix
#   fm_cap_line_var       -> Limit-FmLine        (RETURNS, see below)
#   fm_cap_line           -> Write-FmCappedLine
#   FM_LINE_CAP_LINE      -> (deleted - Limit-FmLine's return value IS it)
#
# The bash constants become RESOLVER FUNCTIONS rather than exported variables,
# the same upgrade bin/fm-classify-lib.psm1 makes for the same reason: a module
# variable is not visible to an importer, so every consumer would otherwise
# re-type its own fallback.
#
# ---------------------------------------------------------------------------
# DIVERGENCES FROM THE BASH TWIN, STATED RATHER THAN HIDDEN
#
#   1. NO OUT-PARAMETER. `fm_cap_line_var` assigns to the global
#      FM_LINE_CAP_LINE instead of printing precisely because a bash caller
#      would otherwise pay a fork per item on a path that runs at the top of
#      every wake-handling turn ("never pays a command substitution per item").
#      That cost does not exist here - a PowerShell function returns a value
#      in-process - so the out-parameter's whole reason for existing is gone
#      and Limit-FmLine simply RETURNS the capped line. The two bash entry
#      points are still both present because they mean different things to a
#      caller (accumulate vs stream), not because of the assignment trick.
#
#      A caller therefore writes
#          $line = Limit-FmLine -Line $line -Max 219
#      where its bash twin wrote
#          fm_cap_line_var "$line" 219; line=$FM_LINE_CAP_LINE
#
#   2. THE CAP UNIT IS UTF-16 CODE UNITS ON BOTH SIDES, AND THAT IS THE
#      ORACLE'S OWN ANSWER HERE. bash `${#var}` and `${var:0:n}` count
#      CHARACTERS in the current locale, and on Linux (glibc, 32-bit wchar_t)
#      that means code points. On THIS host - MSYS2 bash, where wchar_t is
#      16 bits - a non-BMP character counts as TWO, exactly like .NET's
#      String.Length. Measured: one U+1F600 read from a file gives `${#s}` = 2,
#      `${s:0:2}` is the whole emoji, and `${s:0:1}` cuts the surrogate pair in
#      half. So `.Length`/`.Substring` are not an approximation of the oracle on
#      the platform this port targets; they are the oracle
#      (docs/powershell-port.md: "the differential runs on this Windows machine
#      ARE the authority"). Recorded because the equivalence would NOT hold
#      against a glibc bash, so a later reader does not "fix" this into a
#      code-point or text-element count and break parity.
#
#      THE ONE MEASURED BYTE DIFFERENCE, and why it is not faked. When the cut
#      lands INSIDE a surrogate pair the two runtimes spell the orphaned half
#      differently, both in three bytes:
#
#          bash  f0 9f 98      the first 3 bytes of U+1F600's 4-byte sequence,
#                              i.e. a TRUNCATED, invalid UTF-8 sequence
#          PS    ef bf bd      U+FFFD REPLACEMENT CHARACTER
#
#      Everything measurable around it agrees: the differential's 36 cases x 2
#      entry points are byte-identical except for those three bytes, and the
#      capped LENGTH agrees in every single case including these - so the cap
#      itself, which is the contract, is honored identically. Reproducing
#      bash's spelling would mean emitting a deliberately invalid UTF-8
#      sequence into agent-facing output, and could not be done through a
#      [string] return at all (a lone surrogate in a .NET string encodes as
#      U+FFFD on the way out by definition). It is also a Cygwin artifact that
#      a glibc oracle does not produce either, since glibc bash counts the
#      emoji as one character and never splits it.
#
#      The header sentence above still holds for every real input: a status
#      line is BMP text in practice, where character, code point and code unit
#      all coincide and no character is ever cut in half.
#
#   3. AN ABSENT CAP. bash writes `${2:-$FM_LINE_CAP_DEFAULT}`, so BOTH an
#      omitted and an EMPTY second argument fall back to the default. -Max is a
#      nullable int, so omitted or $null takes the default and any integer -
#      including 0 and negatives - is honored verbatim, exactly as bash's
#      arithmetic does. The empty-STRING spelling of "absent" has no PowerShell
#      equivalent (an integer parameter cannot be empty) and is not accepted;
#      $null is its spelling here. No caller in this repo passes an empty cap.
#
# No side effects on import - definitions only. A module that acts at import
# time runs before its caller's own refusals and can defeat them.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-line-cap-lib.psm1')

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it: a .psm1
# resolves function names in its OWN scope. NOT -Force - a nested -Force REMOVES
# the already-loaded module globally and a caller that had imported fm-common
# itself loses Write-FmOut (docs/powershell-port.md).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmLineCapDefault = 220
$script:FmLineCapSuffix = ' [truncated]'

<#
.SYNOPSIS
The default per-line cap, in characters.
.DESCRIPTION
Twin of FM_LINE_CAP_DEFAULT. A consumer that needs the shared cap as a NUMBER -
bin/fm-session-start.ps1 hands it to its tail renderer - calls this instead of
re-typing 220.
#>
function Get-FmLineCapDefault {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:FmLineCapDefault
}

<#
.SYNOPSIS
The marker that replaces the tail of a line the cut shortened.
.DESCRIPTION
Twin of FM_LINE_CAP_SUFFIX. Exported so a consumer or a test can name the one
marker rather than spelling ' [truncated]' again; its LENGTH is part of the
cut's arithmetic, which is why the two must never be typed separately.
#>
function Get-FmLineCapSuffix {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmLineCapSuffix
}

<#
.SYNOPSIS
One line, cut to -Max characters with the shared truncation marker in place of
the tail when it is longer.
.DESCRIPTION
Twin of fm_cap_line_var, and THE rule itself - every other entry point here is
a wrapper around this one cut.

A line at or under the cap is returned unchanged, marker and all bytes intact:
the cut is the only thing that ever alters a status line's text, so a line that
fits must survive verbatim or an agent cannot tell truncation from content.

Over the cap, the kept prefix is (cap - marker length) characters and the marker
takes the rest, so the RESULT is exactly the cap. A cap smaller than the marker
clamps the kept prefix to zero rather than going negative - bash's
`[ "$keep" -ge 0 ] || keep=0` - and the marker alone is returned, which is
longer than that (nonsensical) cap on purpose: the marker is never itself cut,
because a half-written marker would read as content.
#>
function Limit-FmLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line,
        [Parameter(Position = 1)][AllowNull()][System.Nullable[int]]$Max = $null
    )

    # A [string] parameter binds $null as '', but an explicit guard keeps the
    # contract readable and StrictMode-safe if that binding ever changes.
    if ($null -eq $Line) { $Line = '' }

    # A cast, not $Max.Value: PowerShell's binder UNWRAPS a [Nullable[T]]
    # parameter into a bare T once a value is bound, so the nullable's own
    # property does not exist at runtime and StrictMode makes reading it fatal.
    # $null stays $null when the parameter is omitted, which is the whole point
    # of declaring it nullable.
    $cap = $script:FmLineCapDefault
    if ($null -ne $Max) { $cap = [int]$Max }

    if ($Line.Length -le $cap) { return $Line }

    $keep = $cap - $script:FmLineCapSuffix.Length
    if ($keep -lt 0) { $keep = 0 }
    return ($Line.Substring(0, $keep) + $script:FmLineCapSuffix)
}

<#
.SYNOPSIS
The same cut, written to stdout as one LF-terminated line.
.DESCRIPTION
Twin of fm_cap_line, for a caller that is STREAMING lines rather than
accumulating them and weighing each against a further budget. Goes through
Write-FmOut so the byte-controlled, LF-only stdout contract holds.
#>
function Write-FmCappedLine {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line,
        [Parameter(Position = 1)][AllowNull()][System.Nullable[int]]$Max = $null
    )

    Write-FmOut (Limit-FmLine -Line $Line -Max $Max)
}

Export-ModuleMember -Function @(
    'Get-FmLineCapDefault',
    'Get-FmLineCapSuffix',
    'Limit-FmLine',
    'Write-FmCappedLine'
)
