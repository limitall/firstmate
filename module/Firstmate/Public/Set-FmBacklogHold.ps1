#requires -Version 7.0

<#
.SYNOPSIS
    Record a structured dispatch hold on a backlog item (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi hold`. A hold takes the item out of the ready
    projection without taking it out of the queue, which is how a captain-gated
    thread stays durably tracked instead of being silently dropped.

    -Until is a date gate: the hold stops being active ON that date, so
    `-Until 2026-07-10` is inactive from 2026-07-10 onwards.

    An identical hold is reported as already held and nothing is written.

.PARAMETER Id
    The task id.

.PARAMETER Reason
    Required single-line reason. Parentheses are reserved for the markdown hold
    tags themselves, so a reason may not contain them.

.PARAMETER Kind
    One of captain, external, load, parked, future.

.PARAMETER Until
    Date gate, YYYY-MM-DD.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.EXAMPLE
    Set-FmBacklogHold -Id fmwin-chain -Reason 'captain decision pending' -Kind captain
#>
function Set-FmBacklogHold {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Kind = '',
        [string]$Until = '',
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $hold = Assert-FmBacklogHold -Reason $Reason -Kind $Kind -Until $Until
    if (-not $PSCmdlet.ShouldProcess($Path, "hold $Id")) { return }

    $action = {
        param($document)

        $found = Find-FmBacklogEntry -Document $document -Id $Id
        if ($null -eq $found) { throw "Task `"$Id`" not found" }
        $task = $found.Entry.Task
        Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'hold'

        if ($null -ne $task.Hold -and
            $task.Hold.Reason -eq $hold.Reason -and
            $task.Hold.Kind -eq $hold.Kind -and
            $task.Hold.Until -eq $hold.Until) {
            return [pscustomobject]@{ Task = $task; Changed = $false }
        }
        $task.Hold = $hold
        $found.Entry.Dirty = $true
        [pscustomobject]@{ Task = $task; Changed = $true }
    }

    $result = Invoke-FmBacklogMutation -Path $Path -Action $action
    New-FmBacklogResult -Action 'hold' -Id $Id -Task $result.Task -Already:(-not $result.Changed)
}

<#
.SYNOPSIS
    Clear a structured dispatch hold (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi unhold`. An item with no hold is reported as
    already not held and nothing is written.

.PARAMETER Id
    The task id.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.
#>
function Clear-FmBacklogHold {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    if (-not $PSCmdlet.ShouldProcess($Path, "unhold $Id")) { return }

    $action = {
        param($document)

        $found = Find-FmBacklogEntry -Document $document -Id $Id
        if ($null -eq $found) { throw "Task `"$Id`" not found" }
        $task = $found.Entry.Task
        Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'unhold'

        if ($null -eq $task.Hold) { return [pscustomobject]@{ Task = $task; Changed = $false } }
        $task.Hold = $null
        $found.Entry.Dirty = $true
        [pscustomobject]@{ Task = $task; Changed = $true }
    }

    $result = Invoke-FmBacklogMutation -Path $Path -Action $action
    New-FmBacklogResult -Action 'unhold' -Id $Id -Task $result.Task -Already:(-not $result.Changed)
}
