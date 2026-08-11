#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Append one wake event to state/<id>.status.

.DESCRIPTION
A status line is an append-only wake EVENT, never current-state truth: each
append wakes firstmate, and the durable meaning of the stream comes from folding
it (Get-FmOpenDecision), not from its last line.

The optional key is the decision grammar that fold reads:

    needs-decision [key=api-shape]: which shape do we ship
    resolved       [key=api-shape]: captain chose the flat one

A needs-decision or blocked line OPENS that key; only a resolved or captain-held
line naming the SAME key closes it. A malformed key is refused HERE rather than
written, because Get-FmStatusDecisionKey returns $null for one and the fold then
drops the whole line - so a bad key would look like a report that silently never
landed.

The append itself is the foundation's (Add-FmStateLine): it is LF-only, BOM-free,
and serialized on a sibling lock, which this port measured to matter - .NET's
FileMode.Append writes at a remembered offset, so concurrent appends without that
lock silently overwrite each other's lines.
#>
function Add-FmTaskStatus {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Note,
        [Parameter()][AllowEmptyString()][string]$Key = ''
    )
    if ($State -match '[\s:\[\]]') {
        throw "error: '$State' is not a status verb (a verb carries no whitespace, colon, or key token)"
    }
    if ($Key -and $Key -ne 'default' -and $Key -notmatch '^[A-Za-z0-9._-]+$') {
        throw ("error: '$Key' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -); the fold drops a line " +
            'whose key it cannot parse, so it is refused here instead')
    }
    $path = Join-Path $StateDir "$TaskId.status"
    # One append is exactly one event, so a note that carries a newline is
    # flattened here rather than splitting into two events for every reader.
    $flat = ($Note -replace "`r`n", ' ') -replace "[`r`n]", ' '
    $line = if ($Key -and $Key -ne 'default') { "$State [key=$Key]: $flat" } else { "${State}: $flat" }
    if (-not $PSCmdlet.ShouldProcess($path, "append '$line'")) { return $null }
    Add-FmStateLine -Path $path -Line $line -Confirm:$false
    $line
}
