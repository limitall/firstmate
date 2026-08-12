#requires -Version 7.0

<#
.SYNOPSIS
    Read data/backlog.md through the manual backlog backend.

.DESCRIPTION
    Parses the backlog into task records: Id, Title, State, Kind, Repo, Body,
    Deps, Links, Created, Closed, Priority and Hold. The grammar is tasks-axi's
    markdown backend, so this reads a file either tool wrote.

    Reading never rewrites the file, and never normalises it: an untouched item
    keeps its original bytes.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.PARAMETER State
    Only tasks in this state (queued, in_flight, done).

.PARAMETER Repo
    Only tasks tagged with this repo.

.PARAMETER Kind
    Only tasks tagged with this kind.

.EXAMPLE
    Get-FmBacklog -State queued | Select-Object Id, Title
#>
function Get-FmBacklog {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [string]$Path,
        [ValidateSet('queued', 'in_flight', 'done')][string]$State,
        [string]$Repo,
        [string]$Kind
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $source = Get-FmBacklogSource -Path $Path
    if ($null -eq $source) { return @() }

    $tasks = @(Get-FmBacklogDocumentTask -Document (ConvertFrom-FmBacklogMarkdown -Text $source))
    if ($PSBoundParameters.ContainsKey('State')) { $tasks = @($tasks | Where-Object { $_.State -eq $State }) }
    if (-not [string]::IsNullOrEmpty($Repo)) { $tasks = @($tasks | Where-Object { $_.Repo -eq $Repo }) }
    if (-not [string]::IsNullOrEmpty($Kind)) { $tasks = @($tasks | Where-Object { $_.Kind -eq $Kind }) }
    @($tasks)
}

<#
.SYNOPSIS
    One backlog task by id, or $null when there is no such task.

.PARAMETER Id
    The task id.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.
#>
function Get-FmBacklogTask {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$Path
    )

    foreach ($task in (Get-FmBacklog -Path $Path)) {
        if ($task.Id -eq $Id) { return $task }
    }
    $null
}

<#
.SYNOPSIS
    Queued work that is dispatchable right now: unblocked and unheld.

.DESCRIPTION
    The same derivation tasks-axi's `ready` applies - a queued task is ready when
    no blocked-by edge points at a task that exists and is not done, and no
    structured hold is active. A hold with an until date stops being active ON
    that date. Public-followup obligations are never dispatchable work and are
    excluded.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.PARAMETER Repo
    Only tasks tagged with this repo.

.PARAMETER IncludeHeld
    Also return queued work whose hold is still active.

.PARAMETER Today
    Evaluate hold-until against this date instead of today. Test seam.
#>
function Get-FmBacklogReady {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [string]$Path,
        [string]$Repo,
        [switch]$IncludeHeld,
        [string]$Today = ''
    )

    $tasks = @(Get-FmBacklog -Path $Path)
    $ready = @(Get-FmBacklogReadyTask -Task $tasks -IncludeHeld:$IncludeHeld -Today $Today)
    if (-not [string]::IsNullOrEmpty($Repo)) { $ready = @($ready | Where-Object { $_.Repo -eq $Repo }) }
    @($ready)
}

<#
.SYNOPSIS
    Queued work whose structured dispatch hold is still active.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.PARAMETER Today
    Evaluate hold-until against this date instead of today. Test seam.
#>
function Get-FmBacklogHeld {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [string]$Path,
        [string]$Today = ''
    )

    @(Get-FmBacklogHeldTask -Task @(Get-FmBacklog -Path $Path) -Today $Today)
}

<#
.SYNOPSIS
    Tasks that are blocked by an unfinished blocker.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.
#>
function Get-FmBacklogBlocked {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param([string]$Path)

    $tasks = @(Get-FmBacklog -Path $Path)
    $blocked = @(Get-FmBacklogBlockedId -Task $tasks)
    @($tasks | Where-Object { $blocked -contains $_.Id })
}
