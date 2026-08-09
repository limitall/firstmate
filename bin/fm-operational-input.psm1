# bin/fm-operational-input.psm1 - canonical Firstmate operational-input
# protocol: the FUNCTIONS half of a hybrid pair.
#
# Twin: bin/fm-operational-input.sh
#
# This module owns the WIRE PROTOCOL that lets firstmate tell its own injected
# input apart from a real captain message: the marker bytes, the accepted kinds,
# the serialization grammar, and the narrow pre-protocol transcript parsing kept
# isolated from it. A decoding mistake here is not cosmetic - firstmate would
# read its own session-start digest or its own watcher escalation as the captain
# talking to it, or (the other direction, and worse) read a captain message as
# an internal escalation and never exit away mode.
#
# Current generic wire form:
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
#
# ---------------------------------------------------------------------------
# THE HYBRID SPLIT, stated once here because four later packages copy it
#
# bin/fm-operational-input.sh carries a `[ "${BASH_SOURCE[0]}" = "$0" ]` main
# guard: it is a source-safe library AND an executable CLI in one file.
# PowerShell has no equivalent - a .psm1 is imported and never executed, a .ps1
# is executed and cannot export functions into a caller's scope - so the twin is
# a PAIR (docs/powershell-port.md, "Exception - hybrids"):
#
#   bin/fm-operational-input.psm1  every function the bash file defines,
#                                  INCLUDING its `main`, exported by name.
#   bin/fm-operational-input.ps1   import, hand argv to that `main`, exit with
#                                  the code it returns. Nothing else.
#
# The rule that makes this a pattern rather than a one-off: `main` belongs in
# the MODULE, not in the .ps1. In bash `fm_operational_main` is defined above
# the guard, so a file that merely SOURCES this library can call it; putting it
# in the .ps1 would delete that capability and split the CLI's behavior across
# two files, where only one of them is differentially testable in-process. The
# .ps1 therefore holds no protocol logic at all - it is argv in, exit code out -
# which is also why the whole CLI surface below can be driven from one pwsh
# process by the differential suite instead of one process per case.
#
# Consequence for callers: a PowerShell consumer imports the .psm1 (the twin of
# `. bin/fm-operational-input.sh`), and a cross-language consumer executes the
# .ps1 (the twin of `bin/fm-operational-input.sh <command>`). Both are the same
# code.
#
# ---------------------------------------------------------------------------
# FUNCTION AND CONSTANT MAP, so the pairing is greppable from either side
#
#   bin/fm-operational-input.sh          this file                             exported
#   -----------------------------------  ------------------------------------  --------
#   fm_operational_kind_is_current       Test-FmOperationalKindIsCurrent       yes
#   fm_operational_input_encode          ConvertTo-FmOperationalInput          yes
#   fm_operational_input_construct       ConvertTo-FmOperationalMessage        yes
#   fm_operational_generic_kind          Get-FmOperationalGenericKind          yes
#   fm_operational_input_kind            Get-FmOperationalInputKind            yes
#   fm_operational_input_body            Get-FmOperationalInputBody            yes
#   fm_legacy_operational_input_kind     Get-FmLegacyOperationalInputKind      yes
#   fm_operational_input_classify        Get-FmOperationalInputClassification  yes
#   fm_message_from_firstmate            Test-FmMessageFromFirstmate           yes
#   fm_message_mark_from_firstmate       Add-FmFromFirstmateMark               yes
#   fm_operational_read_stdin            Read-FmOperationalStdin               yes
#   fm_operational_usage                 Get-FmOperationalUsage                yes
#   fm_operational_main                  Invoke-FmOperationalMain              yes
#   $FM_OPERATIONAL_MARK and every       Get-FmOperationalConstant -Name       yes
#   other public protocol variable       '<the bash variable name>'
#
# The bash variables are reachable through ONE accessor rather than exported
# module variables, and the -Name values are the bash names verbatim
# ('FM_FROMFIRST_MARK', not 'FromFirstMark'), so a consumer being ported greps
# for the identifier it is replacing and lands on its call site. Exporting the
# variables themselves would publish fourteen mutable names into every importing
# scope for no gain: nothing in the tree assigns to them.
#
# The two ConvertTo- verbs are not a translation of "encode"/"construct": those
# are not approved PowerShell verbs, and New-/Set- would trip
# PSUseShouldProcessForStateChangingFunctions on what are pure string
# transforms. ConvertTo- is what they actually do. The noun keeps them apart -
# ConvertTo-FmOperationalInput is the STRICT generic encoder (current kinds
# only), ConvertTo-FmOperationalMessage is the one that also knows the
# from-firstmate carrier.
#
# ---------------------------------------------------------------------------
# RETURN SHAPE
#
# The bash functions publish through `printf -v "$result_var"` and return
# 0 / 1 / 2. Here:
#   a string = the bash 0 return, with the value the bash caller's result_var
#              would hold
#   $null    = the bash NON-ZERO return
#
# The 2-vs-1 distinction is not reproduced, and cannot be: every bash `return 2`
# in this file except one means "the caller passed an empty result_var name" -
# an artifact of the printf -v idiom that has no PowerShell counterpart. The one
# exception is fm_operational_input_encode, which returns 2 for an unknown kind
# or an empty body; its CLI arm maps EVERY failure to exit 2 regardless, so the
# distinction is invisible at the only surface that could observe it. The CLI
# exit codes themselves ARE reproduced exactly - see Invoke-FmOperationalMain.
#
# ---------------------------------------------------------------------------
# BYTE EXACTNESS, which is the whole job
#
# 1. THE MARKER IS BUILT FROM ITS CODE POINT. U+2063 INVISIBLE SEPARATOR is, by
#    construction, impossible to see in a source file, so a literal here would
#    depend on how this file's bytes are decoded by a host, an editor, or a
#    patch tool - and a silently mangled marker turns every internal escalation
#    into what firstmate reads as a captain message. [char]0x2063 removes that
#    dependency and keeps this file pure ASCII. Its UTF-8 bytes are E2 81 A3,
#    and the full prefix is e281a346495253544d4154455f4f503a20; the differential
#    suite asserts those bytes rather than the rendering.
#
# 2. EVERY COMPARISON IS ORDINAL. PowerShell's -eq / -ceq and .NET's default
#    String.Equals / StartsWith / IndexOf are CULTURE-sensitive, which makes
#    zero-width characters IGNORABLE: bin/fm-composer-lib.psm1 records
#    (([char]0x200B) + '>') -ceq '>' answering True on this host. bash compares
#    bytes and answers False. Here that difference would be a protocol forgery
#    surface - a message prefixed with a zero-width space would match the marker
#    under a culture-sensitive comparison and be accepted as firstmate's own
#    input. So no comparison in this file uses an operator; every one names
#    StringComparison::Ordinal.
#
# 3. UTF-8 CONSOLE ENCODING IS INHERITED, NOT REIMPLEMENTED. Without it
#    PowerShell writes U+2063 as '?'. bin/fm-common.psm1 installs UTF-8 (no BOM)
#    on both console streams at import; importing it below is what buys that.
#    Stdin is read as RAW BYTES and decoded explicitly regardless, so the
#    decode side does not depend on console state at all.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCES FROM THE BASH ORACLE (deliberate, and not normalized away)
#
#   a. NUL BYTES ON STDIN. `value=$(cat; printf x)` runs inside a command
#      substitution, and bash DROPS NUL bytes there (with a warning on stderr in
#      4.4+). Read-FmOperationalStdin preserves them. No protocol payload
#      contains a NUL - every producer in the tree writes text - and preserving
#      the caller's bytes is the safer direction, so this is recorded rather
#      than emulated.
#
#   b. INVALID UTF-8 ON STDIN. `cat` is byte-transparent; .NET's UTF-8 decoder
#      substitutes U+FFFD for an ill-formed sequence. A payload that was already
#      corrupt decodes to a different (still rejected) string here.
#
#   c. LENGTH IS COUNTED IN UTF-16 CODE UNITS. bash's `${#message}` counts
#      characters under a UTF-8 locale and bytes under C. The only length test
#      in the protocol (the legacy watcher envelope) asks whether anything at
#      all sits between a fixed prefix and a fixed suffix, and all three counts
#      agree on that question for every string; see
#      Get-FmLegacyOperationalInputKind.
#
#   d. THE USAGE TEXT STILL NAMES THE .sh FILE. It is reproduced byte for byte,
#      including `bin/fm-operational-input.sh`, because CLI surfaces are
#      identical during the transition (docs/powershell-port.md contract 4) and
#      the differential harness compares this stdout directly. Flipping the
#      spelling belongs to the wave-5 cutover, in one change, not to a
#      conversion package.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-operational-input.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it: a .psm1
# resolves function names in its OWN scope. NO -Force, which is load-bearing
# rather than stylistic - a nested -Force REMOVES the already-loaded module
# before re-importing it, and the removal is global, so a .ps1 that imported
# fm-common.psm1 itself would lose Write-FmOut the moment it imported this
# module (verified for bin/fm-composer-lib.psm1, whose header records it).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmOrdinal = [System.StringComparison]::Ordinal

# --- the current wire vocabulary ---------------------------------------------

# U+2063 INVISIBLE SEPARATOR. See BYTE EXACTNESS note 1 for why this is a code
# point and not a literal.
$script:FmOperationalMark = [string][char]0x2063
# The landed U+2063 + "FIRSTMATE_OP: " prefix is permanent compatibility.
$script:FmOperationalPrefix = $script:FmOperationalMark + 'FIRSTMATE_OP: '
$script:FmOperationalVersion = 'v1'
# The version and kind header make current inputs structurally typed without
# deriving provenance from body prose.
$script:FmOperationalHeaderPrefix = $script:FmOperationalPrefix + $script:FmOperationalVersion + ' '
# Space-separated exactly as the bash twin holds it, because the membership test
# below is a substring test over this string and its spacing is part of that
# test's semantics.
$script:FmOperationalKinds = 'session-start watcher turn-end-guard away-supervisor launch-brief'

# Compatibility name retained for the away-mode owner and its tests.
$script:FmInjectMark = $script:FmOperationalMark

# The from-firstmate carrier stays byte-compatible with live secondmate charter
# context while this owner supplies its construction and structural kind.
$script:FmFromFirstLabel = '[fm-from-firstmate]'
$script:FmFromFirstSeparator = $script:FmOperationalMark
$script:FmFromFirstMark = $script:FmFromFirstLabel + $script:FmFromFirstSeparator

# --- historical payload literals, deliberately isolated -----------------------
#
# These exist only for persisted pre-protocol transcripts and must never be used
# by current producers or current-path tests. Single-quoted where they contain a
# backtick: PowerShell's escape character is the backtick, and the session-start
# literal carries two of them as literal historical prompt markup.
$script:FmLegacySessionStart = 'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
$script:FmLegacyWatcherPrefix = 'FIRSTMATE WATCHER WAKE: '
$script:FmLegacyWatcherSuffix = "`n`nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned."
$script:FmLegacyTurnendPrefix = "TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.`n`n"
$script:FmLegacyAwayPrefix = $script:FmOperationalMark + 'Supervisor escalate ('

# One table, keyed by the bash variable name, so Get-FmOperationalConstant is a
# lookup rather than a switch that could drift from the definitions above.
$script:FmOperationalConstants = [ordered]@{
    'FM_OPERATIONAL_MARK'          = $script:FmOperationalMark
    'FM_OPERATIONAL_PREFIX'        = $script:FmOperationalPrefix
    'FM_OPERATIONAL_VERSION'       = $script:FmOperationalVersion
    'FM_OPERATIONAL_HEADER_PREFIX' = $script:FmOperationalHeaderPrefix
    'FM_OPERATIONAL_KINDS'         = $script:FmOperationalKinds
    'FM_INJECT_MARK'               = $script:FmInjectMark
    'FM_FROMFIRST_LABEL'           = $script:FmFromFirstLabel
    'FM_FROMFIRST_SEPARATOR'       = $script:FmFromFirstSeparator
    'FM_FROMFIRST_MARK'            = $script:FmFromFirstMark
    'FM_LEGACY_SESSIONSTART'       = $script:FmLegacySessionStart
    'FM_LEGACY_WATCHER_PREFIX'     = $script:FmLegacyWatcherPrefix
    'FM_LEGACY_WATCHER_SUFFIX'     = $script:FmLegacyWatcherSuffix
    'FM_LEGACY_TURNEND_PREFIX'     = $script:FmLegacyTurnendPrefix
    'FM_LEGACY_AWAY_PREFIX'        = $script:FmLegacyAwayPrefix
}

<#
.SYNOPSIS
One public protocol constant, by its bash variable name.
.DESCRIPTION
The twin of reading `$FM_OPERATIONAL_PREFIX` and friends after sourcing the bash
library. -Name takes the bash identifier verbatim so a consumer being ported
greps for the name it is replacing and lands here.

FM_OPERATIONAL_KINDS is returned as the same SPACE-SEPARATED string bash holds,
not as an array: its spacing is load-bearing for the membership test in
Test-FmOperationalKindIsCurrent, and a caller that wants the list can split it.
#>
function Get-FmOperationalConstant {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet(
            'FM_OPERATIONAL_MARK', 'FM_OPERATIONAL_PREFIX', 'FM_OPERATIONAL_VERSION',
            'FM_OPERATIONAL_HEADER_PREFIX', 'FM_OPERATIONAL_KINDS', 'FM_INJECT_MARK',
            'FM_FROMFIRST_LABEL', 'FM_FROMFIRST_SEPARATOR', 'FM_FROMFIRST_MARK',
            'FM_LEGACY_SESSIONSTART', 'FM_LEGACY_WATCHER_PREFIX', 'FM_LEGACY_WATCHER_SUFFIX',
            'FM_LEGACY_TURNEND_PREFIX', 'FM_LEGACY_AWAY_PREFIX')]
        [string]$Name
    )
    return [string]$script:FmOperationalConstants[$Name]
}

# --- current construction -----------------------------------------------------

<#
.SYNOPSIS
Is this one of the kinds a current producer may construct?
.DESCRIPTION
Twin of fm_operational_kind_is_current, reproduced as the SUBSTRING test bash
performs rather than as the set membership it looks like:

    case " $FM_OPERATIONAL_KINDS " in *" $1 "*) return 0 ;; esac

Two consequences of that spelling are real behavior, so they are kept:
  - an EMPTY kind tests for two adjacent spaces, which the padded list does not
    contain, so it is correctly rejected;
  - a kind that is itself a space-separated RUN of adjacent list members
    ('watcher turn-end-guard') is ACCEPTED, because that run is a substring of
    the padded list. Nothing constructs such a kind, but a twin that reached for
    real set membership would answer differently on input the bash owner
    accepts, and the differential suite pins it.
#>
function Test-FmOperationalKindIsCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Kind = '')

    if ($null -eq $Kind) { $Kind = '' }
    return (' ' + $script:FmOperationalKinds + ' ').Contains(' ' + $Kind + ' ', $script:FmOrdinal)
}

<#
.SYNOPSIS
Build a current GENERIC operational input: header, kind, body.
.DESCRIPTION
Twin of fm_operational_input_encode. Returns
`U+2063 FIRSTMATE_OP: v1 <kind>: <body>`, or $null when the kind is not a
current construction kind or the body is empty - the two refusals that keep a
legacy kind and an empty payload off the current wire.

Note that 'from-firstmate' is NOT a current generic kind and is refused here by
design; ConvertTo-FmOperationalMessage is the entry point that knows its
carrier.
#>
function ConvertTo-FmOperationalInput {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Kind = '',
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$Body = ''
    )

    if (-not (Test-FmOperationalKindIsCurrent -Kind $Kind)) { return $null }
    if ([string]::IsNullOrEmpty($Body)) { return $null }
    return ($script:FmOperationalHeaderPrefix + $Kind + ': ' + $Body)
}

<#
.SYNOPSIS
Build any current operational input, including the from-firstmate carrier.
.DESCRIPTION
Twin of fm_operational_input_construct, and the function every producer should
call. An empty body is refused before the kind is even looked at, exactly as
bash's `[ -n "$result_var" ] && [ -n "$body" ] || return 2` does - which is why
`encode from-firstmate` with empty stdin fails rather than emitting a bare
carrier.

'from-firstmate' routes to the established live-charter-compatible carrier
instead of the generic envelope, because already-running secondmates carry its
leading label in their charter context. Every other kind goes through the strict
generic encoder.
#>
function ConvertTo-FmOperationalMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Kind = '',
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$Body = ''
    )

    if ([string]::IsNullOrEmpty($Body)) { return $null }
    if ([string]::Equals($Kind, 'from-firstmate', $script:FmOrdinal)) {
        return (Add-FmFromFirstmateMark -Message $Body)
    }
    return (ConvertTo-FmOperationalInput -Kind $Kind -Body $Body)
}

# --- current parsing ----------------------------------------------------------

<#
.SYNOPSIS
The structured kind of a current GENERIC envelope, or $null.
.DESCRIPTION
Twin of fm_operational_generic_kind. The message must start with the exact
header prefix, the text up to the FIRST ': ' after it must be a current kind,
and the remainder must be non-empty.

The bash twin opens with a glob pre-filter,

    case "$message" in "$HEADER"*': '?*) ;; *) return 1 ;; esac

which asks whether SOME ': ' is followed by at least one character. That test is
subsumed by the two checks below rather than dropped: if the first ': ' has a
non-empty tail the pre-filter passes, and if it has an empty tail it sits at the
end of the string, so no later ': ' can exist and the pre-filter fails - exactly
when the body check below fails. Reproducing it separately would add a second
scan that can never disagree.

Ordinal throughout: a culture-sensitive StartsWith would accept a message whose
marker is preceded by a zero-width character (BYTE EXACTNESS note 2).
#>
function Get-FmOperationalGenericKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    $header = $script:FmOperationalHeaderPrefix
    if (-not $Message.StartsWith($header, $script:FmOrdinal)) { return $null }

    $remainder = $Message.Substring($header.Length)
    # ${remainder%%': '*} - everything before the FIRST ': '.
    $separator = $remainder.IndexOf(': ', $script:FmOrdinal)
    if ($separator -lt 0) { return $null }

    $parsedKind = $remainder.Substring(0, $separator)
    if (-not (Test-FmOperationalKindIsCurrent -Kind $parsedKind)) { return $null }

    # [ -n "$body" ]: an envelope whose body is empty is not a valid input.
    if (($separator + 2) -ge $remainder.Length) { return $null }
    return $parsedKind
}

<#
.SYNOPSIS
The kind of any CURRENT operational input, or $null.
.DESCRIPTION
Twin of fm_operational_input_kind. The generic envelope is tried first; failing
that, a message carrying the from-firstmate mark AND at least one character
after it is 'from-firstmate'. A bare mark with nothing following is NOT an
operational input - that trailing `?*` in the bash glob is the difference
between a routed message and a stray label.

This is the CURRENT-path parser only. Historical transcripts are the separate
concern of Get-FmLegacyOperationalInputKind, and keeping the two apart is what
stops a captain quoting an old prompt from being read as firstmate's own input.
#>
function Get-FmOperationalInputKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    $currentKind = Get-FmOperationalGenericKind -Message $Message
    if ($null -ne $currentKind) { return $currentKind }

    if ($Message.StartsWith($script:FmFromFirstMark, $script:FmOrdinal) -and
        $Message.Length -gt $script:FmFromFirstMark.Length) {
        return 'from-firstmate'
    }
    return $null
}

<#
.SYNOPSIS
The payload of a current operational input, or $null.
.DESCRIPTION
Twin of fm_operational_input_body. Strips the exact envelope its own parse
identified - the header plus the parsed kind plus ': ' for a generic input, or
the from-firstmate mark for a routed one - so the returned bytes are the body
the producer passed in, with no trimming of any kind.

A successful result is never empty: both parse paths require a non-empty tail,
which is why $null unambiguously means "not a current operational input" rather
than "an input whose body happened to be blank".
#>
function Get-FmOperationalInputBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    $currentKind = Get-FmOperationalGenericKind -Message $Message
    if ($null -ne $currentKind) {
        $envelope = $script:FmOperationalHeaderPrefix + $currentKind + ': '
        return $Message.Substring($envelope.Length)
    }

    if ($Message.StartsWith($script:FmFromFirstMark, $script:FmOrdinal) -and
        $Message.Length -gt $script:FmFromFirstMark.Length) {
        return $Message.Substring($script:FmFromFirstMark.Length)
    }
    return $null
}

# --- isolated historical parsing ---------------------------------------------

<#
.SYNOPSIS
The kind of a PRE-PROTOCOL transcript payload, or $null.
.DESCRIPTION
Twin of fm_legacy_operational_input_kind. Exists only for persisted transcripts
written before the typed header landed; no current producer may use it, and it
is reached only after the current parser has already declined.

Four historical shapes, in the bash twin's own order:

  - The untyped FIRSTMATE_OP prefix that PR 899 landed. Its subtype cannot be
    recovered without reading body prose, so it is explicitly 'legacy-operational'
    rather than guessed at. A CURRENT message also starts with this prefix,
    which is exactly why Get-FmOperationalInputClassification tries the typed
    parser first.
  - The session-start instruction, matched by EXACT equality. A message that
    merely contains or extends it is a captain quoting it, not an injection.
  - The away-supervisor escalation prefix (which carries the marker but not the
    FIRSTMATE_OP prefix, so the first arm cannot claim it).
  - The watcher envelope: a fixed prefix AND a fixed suffix with something
    between them. bash tests `${#message} -gt prefix+suffix` after the glob
    match; .NET counts UTF-16 code units where bash counts characters or bytes,
    and all three agree on this question, because the test only distinguishes an
    empty middle from a non-empty one and every non-empty middle is at least one
    unit in every count. That length test also does the work of proving the
    prefix and suffix do not overlap.
  - The turn-end-guard prefix with at least one character after it.

The watcher arm returns $null on a length failure rather than falling through:
bash's `case` commits to the first matching arm, and the `|| return 1` inside it
means a bare prefix+suffix envelope is unclassified, not re-tested against the
turn-end arm.
#>
function Get-FmLegacyOperationalInputKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }

    if ($Message.StartsWith($script:FmOperationalPrefix, $script:FmOrdinal) -and
        $Message.Length -gt $script:FmOperationalPrefix.Length) {
        return 'legacy-operational'
    }

    if ([string]::Equals($Message, $script:FmLegacySessionStart, $script:FmOrdinal)) {
        return 'session-start'
    }

    if ($Message.StartsWith($script:FmLegacyAwayPrefix, $script:FmOrdinal)) {
        return 'away-supervisor'
    }

    if ($Message.StartsWith($script:FmLegacyWatcherPrefix, $script:FmOrdinal) -and
        $Message.EndsWith($script:FmLegacyWatcherSuffix, $script:FmOrdinal)) {
        $envelopeLength = $script:FmLegacyWatcherPrefix.Length + $script:FmLegacyWatcherSuffix.Length
        if ($Message.Length -gt $envelopeLength) { return 'watcher' }
        return $null
    }

    if ($Message.StartsWith($script:FmLegacyTurnendPrefix, $script:FmOrdinal) -and
        $Message.Length -gt $script:FmLegacyTurnendPrefix.Length) {
        return 'turn-end-guard'
    }

    return $null
}

<#
.SYNOPSIS
The kind of a current OR historical operational input, or $null.
.DESCRIPTION
Twin of fm_operational_input_classify. Current first, historical second, and the
order is load-bearing: every current generic envelope also begins with the
untyped FIRSTMATE_OP prefix the legacy parser claims, so trying the legacy
parser first would flatten every typed input to 'legacy-operational'.
#>
function Get-FmOperationalInputClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    $classifiedKind = Get-FmOperationalInputKind -Message $Message
    if ($null -ne $classifiedKind) { return $classifiedKind }
    return (Get-FmLegacyOperationalInputKind -Message $Message)
}

# --- from-firstmate routing ---------------------------------------------------

<#
.SYNOPSIS
True when this message already carries the from-firstmate routing carrier.
.DESCRIPTION
Twin of fm_message_from_firstmate.
#>
function Test-FmMessageFromFirstmate {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    $kind = Get-FmOperationalInputKind -Message $Message
    return ($null -ne $kind -and [string]::Equals($kind, 'from-firstmate', $script:FmOrdinal))
}

<#
.SYNOPSIS
Mark a message as routed from firstmate, idempotently.
.DESCRIPTION
Twin of fm_message_mark_from_firstmate. A message that already carries the
carrier is returned unchanged, so marking twice cannot double the label.

This never fails - the bash twin's only `return 2` is its empty-result_var
guard. In particular an EMPTY message yields the bare carrier, which is not a
valid operational input; that is faithful, and it is why
ConvertTo-FmOperationalMessage refuses an empty body before reaching here rather
than relying on this function to.
#>
function Add-FmFromFirstmateMark {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    if (Test-FmMessageFromFirstmate -Message $Message) { return $Message }
    return ($script:FmFromFirstMark + $Message)
}

# --- CLI ----------------------------------------------------------------------

<#
.SYNOPSIS
Read all of stdin as text, byte-transparently.
.DESCRIPTION
Twin of fm_operational_read_stdin, whose `value=$(cat; printf x); value=${value%x}`
exists to keep TRAILING NEWLINES: command substitution strips them, and the
sentinel 'x' is what stops it. A protocol body may legitimately end in a
newline, so that fidelity is the point of the function.

Raw bytes are read from the standard input HANDLE and decoded as UTF-8
explicitly, rather than through [Console]::In, so the decode does not depend on
console state that a redirected or detached stdin can refuse to set. Divergences
(a) and (b) in the file header record where this is more byte-faithful than the
bash twin.
#>
function Read-FmOperationalStdin {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $stdin = [Console]::OpenStandardInput()
    $buffer = [System.IO.MemoryStream]::new()
    try {
        $stdin.CopyTo($buffer)
        return [System.Text.UTF8Encoding]::new($false).GetString($buffer.ToArray())
    } finally {
        $buffer.Dispose()
    }
}

<#
.SYNOPSIS
The CLI usage text, one array element per line.
.DESCRIPTION
Twin of fm_operational_usage. Returned as LINES rather than one blob because the
bash twin writes it to stdout for --help and to stderr for an invalid command,
and Write-FmOut / Write-FmErr are the only sanctioned writers - each appends
exactly one LF, so both destinations receive the heredoc's bytes unchanged.

The text still names bin/fm-operational-input.sh; see divergence (d).
#>
function Get-FmOperationalUsage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'Usage:'
        '  bin/fm-operational-input.sh encode <kind>  # body on stdin'
        '  bin/fm-operational-input.sh kind           # current input on stdin'
        '  bin/fm-operational-input.sh classify       # current or legacy input on stdin'
        '  bin/fm-operational-input.sh body           # current input on stdin'
        ''
        'Current construction kinds:'
        '  session-start watcher turn-end-guard away-supervisor from-firstmate launch-brief'
        ''
        'The from-firstmate kind uses its established live-charter-compatible carrier.'
    )
}

<#
.SYNOPSIS
The CLI body: run one command and return its exit code.
.DESCRIPTION
Twin of fm_operational_main, and the reason this lives in the MODULE rather than
in bin/fm-operational-input.ps1 - see THE HYBRID SPLIT in the file header.

Exit codes are the interface, and are reproduced exactly:

    0   a data command succeeded, or usage was requested
    1   a data command found no match (kind / classify / body)
    2   invalid use: an unknown command, the wrong argument count, or a
        construction the current protocol refuses (a legacy kind, an empty body)

All successful data commands print exactly one value and no diagnostics.
`encode` and `body` print WITHOUT a trailing newline (`printf '%s'`) because
their output is a protocol payload a caller composes further; `kind` and
`classify` print a bare token WITH one (`printf '%s\n'`). That asymmetry is not
cosmetic - .opencode/plugins/lib/fm-operational-input.js pipes the `encode`
result straight into a harness message, and an extra newline would ride along
inside the envelope.

Commands are compared with StringComparison::Ordinal rather than a `switch`,
which is culture-sensitive even under -CaseSensitive and would let a zero-width
character in argv select a command bash would reject.
#>
function Invoke-FmOperationalMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }
    $argv = @($Arguments)
    $count = $argv.Count
    $command = if ($count -ge 1) { [string]$argv[0] } else { '' }
    $argument = if ($count -ge 2) { [string]$argv[1] } else { '' }

    if ([string]::Equals($command, '-h', $script:FmOrdinal) -or
        [string]::Equals($command, '--help', $script:FmOrdinal) -or
        [string]::Equals($command, 'help', $script:FmOrdinal)) {
        foreach ($line in @(Get-FmOperationalUsage)) { Write-FmOut -Text $line }
        return 0
    }

    if ([string]::Equals($command, 'encode', $script:FmOrdinal)) {
        if ($count -ne 2) { return 2 }
        $payload = Read-FmOperationalStdin
        $output = ConvertTo-FmOperationalMessage -Kind $argument -Body $payload
        if ($null -eq $output) { return 2 }
        Write-FmRaw -Text $output
        return 0
    }

    if ([string]::Equals($command, 'kind', $script:FmOrdinal)) {
        if ($count -ne 1) { return 2 }
        $payload = Read-FmOperationalStdin
        $output = Get-FmOperationalInputKind -Message $payload
        if ($null -eq $output) { return 1 }
        Write-FmOut -Text $output
        return 0
    }

    if ([string]::Equals($command, 'classify', $script:FmOrdinal)) {
        if ($count -ne 1) { return 2 }
        $payload = Read-FmOperationalStdin
        $output = Get-FmOperationalInputClassification -Message $payload
        if ($null -eq $output) { return 1 }
        Write-FmOut -Text $output
        return 0
    }

    if ([string]::Equals($command, 'body', $script:FmOrdinal)) {
        if ($count -ne 1) { return 2 }
        $payload = Read-FmOperationalStdin
        $output = Get-FmOperationalInputBody -Message $payload
        if ($null -eq $output) { return 1 }
        Write-FmRaw -Text $output
        return 0
    }

    foreach ($line in @(Get-FmOperationalUsage)) { Write-FmErr -Text $line }
    return 2
}

Export-ModuleMember -Function @(
    'Get-FmOperationalConstant',
    'Test-FmOperationalKindIsCurrent',
    'ConvertTo-FmOperationalInput',
    'ConvertTo-FmOperationalMessage',
    'Get-FmOperationalGenericKind',
    'Get-FmOperationalInputKind',
    'Get-FmOperationalInputBody',
    'Get-FmLegacyOperationalInputKind',
    'Get-FmOperationalInputClassification',
    'Test-FmMessageFromFirstmate',
    'Add-FmFromFirstmateMark',
    'Read-FmOperationalStdin',
    'Get-FmOperationalUsage',
    'Invoke-FmOperationalMain'
)
