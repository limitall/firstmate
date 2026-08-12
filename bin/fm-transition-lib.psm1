# fm-transition-lib.psm1 - the shared, backend-neutral agent-state transition
# shape and the single-owner status -> supervision-action policy table.
#
# Twin: bin/fm-transition-lib.sh
#
# This library owns the same TWO contracts its bash twin does, deliberately
# backend-independent so any push-capable session backend (herdr today, others
# later) reuses them instead of re-deriving a private, per-status escalation
# hack:
#
#   1. The NORMALIZED TRANSITION RECORD - the ONE shape every backend event
#      stream is normalized into before any policy runs. A single TAB-separated
#      line:
#          <pane_id>\t<workspace_id>\t<from_status>\t<to_status>\t<agent>
#      Only `to_status` is authoritative for the policy; the other fields are
#      identity/telemetry and MAY be empty when a backend cannot supply them.
#      `from_status` in particular is empty for backends whose event carries
#      only the new status (herdr's `pane.agent_status_changed` does not report
#      the previous status, and its stream is edge-triggered, so each
#      `to_status` IS itself a fresh edge). Statuses use the shared agent-state
#      vocabulary (idle|working|blocked|done|unknown).
#
#   2. The STATUS -> ACTION POLICY TABLE (Get-FmTransitionPolicy) - the SINGLE
#      OWNER of the mapping from a normalized `to_status` to the supervision
#      action a consumer must take. Every consumer READS this table; no
#      consumer re-encodes the mapping.
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-transition-lib.sh        this file                          exported
#   -----------------------------   --------------------------------   --------
#   fm_transition_record            New-FmTransitionRecord             yes
#   fm_transition_clean_field       Get-FmTransitionCleanField         yes
#   fm_transition_field             Get-FmTransitionField              yes
#   fm_transition_pane_id           Get-FmTransitionPaneId             yes
#   fm_transition_workspace_id      Get-FmTransitionWorkspaceId        yes
#   fm_transition_from_status       Get-FmTransitionFromStatus         yes
#   fm_transition_to_status         Get-FmTransitionToStatus           yes
#   fm_transition_agent             Get-FmTransitionAgent              yes
#   fm_transition_policy            Get-FmTransitionPolicy             yes
#   FM_TRANSITION_FIELD_SEP         Get-FmTransitionFieldSeparator     yes
#
# ---------------------------------------------------------------------------
# THE HAZARD THIS FILE IS BUILT AROUND: EMPTY FIELDS ARE MEANINGFUL.
#
# The record is five columns and three of them are routinely EMPTY - the
# reconcile path builds `<pane>\t\t\tworking\t` - so any parser that collapses
# adjacent separators reads `working` out of column 2 and the whole policy
# decision moves to the wrong field. The bash twin is written against exactly
# this: it uses `cut`, never `read`, because a TAB is IFS whitespace and `read`
# collapses empty fields.
#
# PowerShell has the same trap wearing different clothes. The `-split` operator
# takes a REGEX and drops nothing, but `[string]::Split()` with
# StringSplitOptions::RemoveEmptyEntries drops empties, and a regex delimiter
# with a metacharacter behaves differently again. So every split here is
# `.Split("`t")` on the RAW string with no options, and the field COUNT is what
# indexing is bounded by - never a "however many non-empty pieces came back".
#
# `cut` SEMANTICS, REPRODUCED RATHER THAN APPROXIMATED. Get-FmTransitionField
# is the twin of `printf '%s' "$rec" | cut -d<TAB> -f<n>`, and cut has three
# behaviors a naive index would get wrong. All three were verified against this
# host's cut before being written down:
#   - a line containing NO delimiter is passed through WHOLE for any field
#     number ("abc" -f3 -> "abc", not "");
#   - a field number past the end yields an empty result, not an error;
#   - cut works per LINE, so a multi-line argument yields one result per line.
# The last one is unreachable for a well-formed record (fields are scrubbed of
# newlines by the constructor) but reachable for a caller that hands this
# function arbitrary text, which is precisely when a silent difference would be
# hardest to find.
#
# RETURN SHAPE. Bash accessors are used exclusively through `$( ... )`, which
# strips trailing newlines, so these return the value a bash caller ends up
# HOLDING: no terminator. Interior newlines in a multi-line result are
# preserved exactly as cut emits them.
#
# ORDINAL COMPARISON, EVERYWHERE. bash `case` compares BYTES and is
# case-sensitive. PowerShell's `switch`, `-eq` and even `-ceq` are
# culture-sensitive, which makes zero-width characters IGNORABLE: verified on
# this host, (([char]0x200B) + 'blocked') -ceq 'blocked' is True. A status
# carrying a stray U+200B would then be classified `actionable` here and
# `fallback` in bash - the policy table disagreeing across the two trees on the
# one field that decides whether the supervisor is woken. Every comparison below
# therefore goes through [string]::Equals with StringComparison::Ordinal.
#
# WHY THERE IS NO Import-Module HERE. This module is pure string work: no
# console output, no files, no environment, no external processes. Importing
# fm-common would buy nothing and would make the dependency graph read as
# though it did. A CONSUMER still imports fm-common for its own output
# discipline; nothing in this file needs it.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-transition-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Field separator for the normalized record. A literal TAB; every field is
# scrubbed of TAB/CR/LF by the constructor so the record is exactly five fields.
$script:FmTransitionFieldSep = "`t"

# See the ORDINAL COMPARISON note in the header for why this is not optional.
$script:FmOrdinal = [System.StringComparison]::Ordinal

<#
.SYNOPSIS
The record field separator, a literal TAB.
.DESCRIPTION
Twin of the FM_TRANSITION_FIELD_SEP constant. Exposed as a function rather than
an exported variable so a consumer cannot reassign the separator out from under
the accessors - the bash constant is a plain shell variable and has the same
hazard, it simply has no way to prevent it.

Nothing in the bash tree reads the constant outside its own library today; it is
carried across so a backend twin writing its own normalizer has one place to ask
what the layout is.
#>
function Get-FmTransitionFieldSeparator {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmTransitionFieldSep
}

<#
.SYNOPSIS
Collapse any TAB/CR/LF in a field value to spaces.
.DESCRIPTION
Twin of fm_transition_clean_field:

    printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '

so a stray control character can never desync the fixed five-field record. The
three characters are ASCII, and LC_ALL=C makes tr operate on BYTES, which is why
walking UTF-16 chars here is equivalent rather than merely close: a multibyte
glyph's UTF-8 continuation bytes are all >= 0x80 and can never be one of these
three.

String.Replace(String, String) is ORDINAL in .NET, so a zero-width character
adjacent to a TAB cannot make the comparison miss it.

One consequence worth stating because it is easy to read as a bug: a value
ending in a newline becomes a value ending in a SPACE, and that space survives.
The bash twin behaves identically - tr rewrites the newline before `$( )` ever
sees it, so there is no trailing newline left to strip.
#>
function Get-FmTransitionCleanField {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value = '')

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}

<#
.SYNOPSIS
THE constructor for a normalized transition record.
.DESCRIPTION
Twin of fm_transition_record, with the same positional argument order. Both a
backend stream normalizer and its level-reconcile read MUST build records
through this one function, so the field order and separator have a single owner.
Fields are TAB/CR/LF-scrubbed here.

Every parameter accepts null and empty, because the bash twin reads each as
`${n:-}` and three of the five fields are routinely absent. The result is always
exactly four separators, whatever the inputs were.
#>
function New-FmTransitionRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'New- is the natural verb for a constructor and keeps the pairing with fm_transition_record obvious, but this one only formats five strings into one line and touches nothing outside its own scope. Adding SupportsShouldProcess would be a lie: under -WhatIf it would return nothing and every caller would go on to parse an empty record.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$PaneId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$WorkspaceId = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$FromStatus = '',
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$ToStatus = '',
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$Agent = ''
    )

    $sep = $script:FmTransitionFieldSep
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((Get-FmTransitionCleanField -Value $PaneId)).Append($sep)
    [void]$sb.Append((Get-FmTransitionCleanField -Value $WorkspaceId)).Append($sep)
    [void]$sb.Append((Get-FmTransitionCleanField -Value $FromStatus)).Append($sep)
    [void]$sb.Append((Get-FmTransitionCleanField -Value $ToStatus)).Append($sep)
    [void]$sb.Append((Get-FmTransitionCleanField -Value $Agent))
    return $sb.ToString()
}

<#
.SYNOPSIS
Read one 1-based field out of a normalized record.
.DESCRIPTION
Twin of fm_transition_field, i.e. of `printf '%s' "$rec" | cut -d<TAB> -f<n>`,
whose three non-obvious behaviors are reproduced rather than approximated (see
the `cut` SEMANTICS note in the file header):

  - a line with NO TAB is passed through whole for any field number;
  - a field number past the last field yields '';
  - input is processed per LINE and the results are rejoined with LF.

Empty input is ZERO lines to cut, not one empty line, so it yields '' - the same
distinction Test-FmComposerIdleMatch documents for grep.

Field 0 or negative: cut REFUSES ("fields are numbered from 1"), exiting
non-zero with no output, which a bash caller inside `$( )` sees as an empty
value. This returns '' for the same inputs. That is the one place the twins
differ in KIND rather than in value - bash also writes a diagnostic to stderr
and fails - and no caller in the tree passes anything but 1..5.
#>
function Get-FmTransitionField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record,
        [Parameter(Mandatory, Position = 1)][int]$Index
    )

    if ($Index -lt 1) { return '' }
    if ([string]::IsNullOrEmpty($Record)) { return '' }

    # cut reads LINES: a trailing newline TERMINATES the last line rather than
    # starting an empty one, so exactly one trailing empty is dropped.
    $lines = $Record.Split("`n")
    $count = $lines.Count
    if ($count -gt 1 -and $lines[$count - 1] -eq '') { $count-- }

    $out = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -gt 0) { [void]$out.Append("`n") }
        $line = $lines[$i]
        if ($line.IndexOf($script:FmTransitionFieldSep, $script:FmOrdinal) -lt 0) {
            # No delimiter on this line: cut passes it through whole.
            [void]$out.Append($line)
            continue
        }
        # .Split with no options PRESERVES empty fields, which is the entire
        # point - see the EMPTY FIELDS note in the header.
        $fields = $line.Split($script:FmTransitionFieldSep)
        if ($Index -le $fields.Count) { [void]$out.Append($fields[$Index - 1]) }
    }

    # The `$( )` convention: a bash caller never sees cut's trailing newline.
    return $out.ToString().TrimEnd("`n")
}

# Field accessors (1-based), so consumers never hardcode the column layout.
# Each is the direct twin of the same-named bash one-liner.

<#
.SYNOPSIS
Field 1: the backend pane identity.
#>
function Get-FmTransitionPaneId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record)
    return (Get-FmTransitionField -Record $Record -Index 1)
}

<#
.SYNOPSIS
Field 2: the backend workspace identity, empty when a backend cannot supply one.
#>
function Get-FmTransitionWorkspaceId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record)
    return (Get-FmTransitionField -Record $Record -Index 2)
}

<#
.SYNOPSIS
Field 3: the previous status, empty for an edge-triggered backend.
#>
function Get-FmTransitionFromStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record)
    return (Get-FmTransitionField -Record $Record -Index 3)
}

<#
.SYNOPSIS
Field 4: the new status. The ONLY field the policy table reads.
#>
function Get-FmTransitionToStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record)
    return (Get-FmTransitionField -Record $Record -Index 4)
}

<#
.SYNOPSIS
Field 5: the agent name, empty when a backend cannot supply one.
#>
function Get-FmTransitionAgent {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Record)
    return (Get-FmTransitionField -Record $Record -Index 5)
}

<#
.SYNOPSIS
THE single-owner status -> supervision-action table.
.DESCRIPTION
Twin of fm_transition_policy. Given a normalized `to_status`, returns exactly one
action token:

  actionable - escalate to the supervisor IMMEDIATELY (a fresh edge here is a
               durable wake now). `blocked` is the only immediately-actionable
               status today: herdr reports it precisely when a harness is
               waiting on the human (a permission/trust dialog, an interactive
               menu, a wedged prompt) - the cases that write no status file and
               otherwise sit until the stale-pane wedge timer.
  absorb     - do NOT wake, but CLEAR this pane's per-pane escalation dedupe
               marker so a later `->blocked` edge re-escalates. `working` (a
               crew resumed or started a turn) is the clearing edge.
  defer      - do NOTHING on the fast path; leave it to the existing
               status/turn-end completion semantics and the poll backstop.
               `idle`/`done` blip transiently between tool calls, so
               fast-pathing them would be a false-positive firehose.
  fallback   - the status is unknown or unrecognized: fall back to polling for
               this pane, taking no fast action from an ambiguous read.

Adding or changing a status is a one-line edit here and it changes every backend
at once - which is exactly why this must NOT be reimplemented in a consumer, in
either language.

The comparison chain is ordinal and case-SENSITIVE, matching bash `case`.
`switch` would have been the natural PowerShell spelling and is wrong twice
over: it is case-insensitive by default, and even `-CaseSensitive` compares
culture-sensitively, so a status carrying a zero-width character would take a
named arm here and the default arm in bash.
#>
function Get-FmTransitionPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ToStatus = '')

    if ($null -eq $ToStatus) { $ToStatus = '' }
    if ([string]::Equals($ToStatus, 'blocked', $script:FmOrdinal)) { return 'actionable' }
    if ([string]::Equals($ToStatus, 'working', $script:FmOrdinal)) { return 'absorb' }
    if ([string]::Equals($ToStatus, 'idle', $script:FmOrdinal)) { return 'defer' }
    if ([string]::Equals($ToStatus, 'done', $script:FmOrdinal)) { return 'defer' }
    return 'fallback'
}

Export-ModuleMember -Function @(
    'Get-FmTransitionFieldSeparator',
    'Get-FmTransitionCleanField',
    'New-FmTransitionRecord',
    'Get-FmTransitionField',
    'Get-FmTransitionPaneId',
    'Get-FmTransitionWorkspaceId',
    'Get-FmTransitionFromStatus',
    'Get-FmTransitionToStatus',
    'Get-FmTransitionAgent',
    'Get-FmTransitionPolicy'
)
