#requires -Version 7.0

<#
.SYNOPSIS
    Move a backlog item to ## In flight (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi start`. An item already in flight is left
    untouched and reported as already started, so a re-run after a lost pane
    never rewrites the file. An item with no `since` date gets one on the way in.

.PARAMETER Id
    The task id.

.PARAMETER Path
    The backlog file. Defaults to this home's data/backlog.md, or the file .tasks.toml pins.

.PARAMETER Date
    The date to stamp when one is needed. Defaults to today.
#>
function Start-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$Path,
        [string]$Date = ''
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $current = Get-FmBacklogTask -Id $Id -Path $Path
    if ($null -eq $current) { throw "Task `"$Id`" not found" }
    if ($current.State -eq 'in_flight') {
        return New-FmBacklogResult -Action 'start' -Id $Id -Task $current -Already
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "start $Id")) { return }
    $task = Invoke-FmBacklogTransition -Path $Path -Id $Id -To 'in_flight' -Date $Date
    New-FmBacklogResult -Action 'start' -Id $Id -Task $task
}

<#
.SYNOPSIS
    Move a Done or In flight item back to ## Queued (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi reopen`. Reopened work appends to the bottom of
    ## Queued and loses its closure date, because it is no longer closed.

.PARAMETER Id
    The task id.

.PARAMETER Path
    The backlog file. Defaults to this home's data/backlog.md, or the file .tasks.toml pins.

.PARAMETER Date
    The date to stamp when one is needed. Defaults to today.
#>
function Reset-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$Path,
        [string]$Date = ''
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $current = Get-FmBacklogTask -Id $Id -Path $Path
    if ($null -eq $current) { throw "Task `"$Id`" not found" }
    if ($current.State -eq 'queued') {
        return New-FmBacklogResult -Action 'reopen' -Id $Id -Task $current -Already
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "reopen $Id")) { return }
    $task = Invoke-FmBacklogTransition -Path $Path -Id $Id -To 'queued' -Date $Date
    New-FmBacklogResult -Action 'reopen' -Id $Id -Task $task
}
