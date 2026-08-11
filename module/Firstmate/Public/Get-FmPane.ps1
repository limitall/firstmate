#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Read a worker's pane: a bounded capture of what the endpoint is showing, plus
its native state.

.DESCRIPTION
The PowerShell port of the read half of bin/fm-peek.sh and
bin/fm-crew-state.sh's pane primitives, on the herdr session provider.

Two things are returned together because on herdr they are genuinely different
sources and callers need to know which one they are trusting:
  Capture    - the pane's recent rendered text, bounded to -Lines.
  BusyState  - herdr's NATIVE agent state (busy|idle|unknown). This is the
               backend where that reading has real semantics rather than a
               pane-tail regex, so it is reported rather than re-derived.
  AgentState - the recovery-grade classifier (alive|dead|missing|unreadable).
               Only dead and missing license recovery.

-Lines is a bound on the returned text, not on what is fetched: herdr's
`pane read --lines N` returns COMPLETELY EMPTY output when N is below the
pane's viewport height, so the adapter always fetches generously and trims.

This is a READ. It never starts a herdr server when only presence is being
checked, and it never sends anything to the pane.
#>
function Get-FmPane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Target,
        [int]$Lines = 120,
        [string]$FirstmateHome = '',
        [switch]$Ansi,
        [switch]$TextOnly
    )

    if (-not $FirstmateHome) { $FirstmateHome = $env:FM_HOME }
    if (-not $FirstmateHome) {
        throw 'error: FM_HOME is not set; fm-peek refuses to resolve targets without an explicit firstmate home'
    }
    $stateDir = Join-Path $FirstmateHome 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw "error: state dir '$stateDir' is missing; fm-peek cannot resolve targets for FM_HOME '$FirstmateHome'"
    }

    $resolved = Resolve-FmTaskSelector -Selector $Target -StateDir $stateDir
    if (-not $resolved.Resolved) { throw $resolved.Reason }
    if ($resolved.Backend -ne 'herdr') {
        throw ("error: target '$Target' records backend '$($resolved.Backend)'; this PowerShell port reads the herdr " +
            'session provider only')
    }

    $capture = Get-FmHerdrCapture -Target $resolved.Target -Lines $Lines -Ansi:$Ansi
    if ($TextOnly) { return $capture }

    [pscustomobject]@{
        Target     = $resolved.Target
        TaskId     = $resolved.TaskId
        Backend    = $resolved.Backend
        Harness    = $resolved.Harness
        Capture    = $capture
        BusyState  = (Get-FmHerdrBusyState -Target $resolved.Target)
        AgentState = (Get-FmHerdrAgentState -Target $resolved.Target)
        Lines      = $Lines
    }
}
