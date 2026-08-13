#requires -Version 7.0

<#
.SYNOPSIS
    Record a blocked-by dependency edge (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi block`. The blocker named by -By must already
    exist, because a dangling edge would silently read as "resolved" to every
    consumer of the ready projection. A task cannot block itself, and an edge
    that is already recorded is reported as already blocked rather than
    duplicated.

.PARAMETER Id
    The task that is blocked.

.PARAMETER By
    The task that blocks it.

.PARAMETER Reason
    Optional free-text reason, recorded after the edge.

.PARAMETER Path
    The backlog file. Defaults to this home's data/backlog.md, or the file .tasks.toml pins.
#>
function Block-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory)][string]$By,
        [string]$Reason = '',
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $dep = Assert-FmBacklogDependency -OwnerId $Id -Type 'blocked-by' -Id $By -Reason $Reason
    if (-not $PSCmdlet.ShouldProcess($Path, "block $Id by $By")) { return }

    $action = {
        param($document)

        $found = Find-FmBacklogEntry -Document $document -Id $Id
        if ($null -eq $found) { throw "Task `"$Id`" not found" }
        $task = $found.Entry.Task
        Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'block'

        foreach ($existing in $task.Deps) {
            if ($existing.Type -eq $dep.Type -and $existing.Id -eq $dep.Id) {
                return [pscustomobject]@{ Task = $task; Added = $false }
            }
        }
        Assert-FmBacklogDependencyExists -Document $document -Dependency @($dep)
        $task.Deps = @($task.Deps) + @($dep)
        $found.Entry.Dirty = $true
        [pscustomobject]@{ Task = $task; Added = $true }
    }

    $result = Invoke-FmBacklogMutation -Path $Path -Action $action
    New-FmBacklogResult -Action 'block' -Id $Id -Task $result.Task -Already:(-not $result.Added)
}

<#
.SYNOPSIS
    Clear a blocked-by dependency edge (idempotent).

.DESCRIPTION
    The equivalent of `tasks-axi unblock`. An edge that is not there is reported
    as already cleared, and nothing is written.

.PARAMETER Id
    The task that was blocked.

.PARAMETER By
    The blocker to clear.

.PARAMETER Path
    The backlog file. Defaults to this home's data/backlog.md, or the file .tasks.toml pins.
#>
function Unblock-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory)][string]$By,
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $blocker = Assert-FmBacklogId -Id $By
    if (-not $PSCmdlet.ShouldProcess($Path, "unblock $Id by $By")) { return }

    $action = {
        param($document)

        $found = Find-FmBacklogEntry -Document $document -Id $Id
        if ($null -eq $found) { throw "Task `"$Id`" not found" }
        $task = $found.Entry.Task
        Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'unblock'

        $kept = @($task.Deps | Where-Object { -not ($_.Type -eq 'blocked-by' -and $_.Id -eq $blocker) })
        if ($kept.Count -eq @($task.Deps).Count) {
            return [pscustomobject]@{ Task = $task; Removed = $false }
        }
        $task.Deps = @($kept)
        $found.Entry.Dirty = $true
        [pscustomobject]@{ Task = $task; Removed = $true }
    }

    $result = Invoke-FmBacklogMutation -Path $Path -Action $action
    New-FmBacklogResult -Action 'unblock' -Id $Id -Task $result.Task -Already:(-not $result.Removed)
}
