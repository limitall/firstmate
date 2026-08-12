#requires -Version 7.0
<#
.SYNOPSIS
    The manual backlog backend as a command: read and mutate data/backlog.md.

.DESCRIPTION
    Entry point for the manual backlog path firstmate uses when
    config/backlog-backend is `manual`, or when compatible tasks-axi is not
    available. The file format is identical either way - this writes the same
    canonical markdown tasks-axi writes, and leaves every item it did not touch
    byte for byte as it found it.

    Verbs: list, ready, held, blocked, show, add, start, done, reopen, block,
    unblock, hold, unhold, prune, backend.

    Exit codes follow the repo convention: 0 success, 1 refusal or failure,
    2 usage. Refusals go to stderr as a plain line, not a PowerShell error record.

.PARAMETER Command
    The verb to run.

.PARAMETER Id
    The task id the verb acts on.

.PARAMETER Title
    Title for `add`.

.PARAMETER By
    Blocker id for `block` and `unblock`.

.PARAMETER Reason
    Hold reason for `hold`.

.PARAMETER Kind
    Kind tag for `add`, or hold kind for `hold`.

.PARAMETER Repo
    Repo tag for `add`, or repo filter for `list` and `ready`.

.PARAMETER Body
    Body text for `add`.

.PARAMETER Note
    Note line for `done`.

.PARAMETER Pr
    Pull request URL for `done`.

.PARAMETER Report
    Report path for `done`.

.PARAMETER Until
    Hold-until date for `hold`.

.PARAMETER State
    State filter for `list`.

.PARAMETER Priority
    Priority 0-4 for `add`.

.PARAMETER Keep
    Retention count for `done` and `prune`.

.PARAMETER BlockedBy
    Blocker ids for `add`.

.PARAMETER Start
    Create an `add` item directly in flight.

.PARAMETER IncludeHeld
    Include held work in `ready`.

.PARAMETER NoPrune
    Skip retention on `done`.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.EXAMPLE
    bin/fm-backlog.ps1 ready
.EXAMPLE
    bin/fm-backlog.ps1 done fmwin-backlog -Note 'merged via chain; local main'
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Id,
    [Parameter(Position = 2)][string]$Title,
    [string]$By,
    [string]$Reason,
    [string]$Kind,
    [string]$Repo,
    [string]$Body,
    [string]$Note,
    [string]$Pr,
    [string]$Report,
    [string]$Until,
    [string]$State,
    [Nullable[int]]$Priority,
    [Nullable[int]]$Keep,
    [string[]]$BlockedBy = @(),
    [switch]$Start,
    [switch]$IncludeHeld,
    [switch]$NoPrune,
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmBacklog'

$usage = @(
    'usage: fm-backlog.ps1 <command> [args]',
    'commands:',
    '  list [-State queued|in_flight|done] [-Repo <name>]   title lines',
    '  ready [-Repo <name>] [-IncludeHeld]                  dispatchable now',
    '  held                                                 active dispatch holds',
    '  blocked                                              blocked by unfinished work',
    '  show <id>                                            one item in full',
    '  add <id> "<title>" [-Kind|-Repo|-Body|-Priority|-BlockedBy|-Start]',
    '  start <id>',
    '  done <id> [-Pr <url>] [-Report <path>] [-Note "<text>"] [-Keep <n>] [-NoPrune]',
    '  reopen <id>',
    '  block <id> -By <other> [-Reason "<text>"]',
    '  unblock <id> -By <other>',
    '  hold <id> -Reason "<text>" [-Kind captain|external|load|parked|future] [-Until YYYY-MM-DD]',
    '  unhold <id>',
    '  prune [-Keep <n>]',
    '  backend                                              which backend this home uses'
)

function Write-FmBacklogUsage {
    foreach ($line in $usage) { [Console]::Error.WriteLine($line) }
}

function Format-FmBacklogTaskLine {
    param($Task)
    $flags = @()
    if ($null -ne $Task.Hold) {
        $flags += "hold: $($Task.Hold.Reason)"
        if (-not [string]::IsNullOrEmpty($Task.Hold.Kind)) { $flags += "hold-kind: $($Task.Hold.Kind)" }
        if (-not [string]::IsNullOrEmpty($Task.Hold.Until)) { $flags += "hold-until: $($Task.Hold.Until)" }
    }
    foreach ($dep in $Task.Deps) { $flags += "$($dep.Type): $($dep.Id)" }
    $suffix = if ($flags.Count -gt 0) { ' (' + ($flags -join '; ') + ')' } else { '' }
    "$($Task.State)`t$($Task.Id)`t$($Task.Title)$suffix"
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-FmBacklogUsage
    exit 2
}

$needsId = @('show', 'add', 'start', 'done', 'reopen', 'block', 'unblock', 'hold', 'unhold')
if ($needsId -contains $Command -and [string]::IsNullOrWhiteSpace($Id)) {
    [Console]::Error.WriteLine("usage: fm-backlog.ps1 $Command <id>")
    exit 2
}

try {
    switch ($Command) {
        'list' {
            $listArgs = @{}
            if ($Path) { $listArgs['Path'] = $Path }
            if ($State) { $listArgs['State'] = $State }
            if ($Repo) { $listArgs['Repo'] = $Repo }
            foreach ($task in (Get-FmBacklog @listArgs)) {
                [Console]::Out.Write((Format-FmBacklogTaskLine -Task $task) + "`n")
            }
        }
        'ready' {
            foreach ($task in (Get-FmBacklogReady -Path $Path -Repo $Repo -IncludeHeld:$IncludeHeld)) {
                [Console]::Out.Write((Format-FmBacklogTaskLine -Task $task) + "`n")
            }
        }
        'held' {
            foreach ($task in (Get-FmBacklogHeld -Path $Path)) {
                [Console]::Out.Write((Format-FmBacklogTaskLine -Task $task) + "`n")
            }
        }
        'blocked' {
            foreach ($task in (Get-FmBacklogBlocked -Path $Path)) {
                [Console]::Out.Write((Format-FmBacklogTaskLine -Task $task) + "`n")
            }
        }
        'show' {
            $task = Get-FmBacklogTask -Id $Id -Path $Path
            if ($null -eq $task) {
                [Console]::Error.WriteLine("Task `"$Id`" not found")
                exit 1
            }
            [Console]::Out.Write((Format-FmBacklogTaskLine -Task $task) + "`n")
            if (-not [string]::IsNullOrEmpty($task.Body)) {
                foreach ($line in ($task.Body -split "`n")) { [Console]::Out.Write("  $line`n") }
            }
        }
        'add' {
            if ([string]::IsNullOrWhiteSpace($Title)) {
                [Console]::Error.WriteLine('usage: fm-backlog.ps1 add <id> "<title>"')
                exit 2
            }
            $result = Add-FmBacklogTask -Id $Id -Title $Title -Kind $Kind -Repo $Repo -Body $Body `
                -Priority $Priority -BlockedBy $BlockedBy -Start:$Start -Path $Path
            [Console]::Out.Write("add $($result.Id) -> $($result.Task.State)`n")
        }
        'start' {
            $result = Start-FmBacklogTask -Id $Id -Path $Path
            $suffix = if ($result.Already) { ' (already in flight)' } else { '' }
            [Console]::Out.Write("start $($result.Id) -> in_flight$suffix`n")
        }
        'done' {
            $result = Complete-FmBacklogTask -Id $Id -Pr $Pr -Report $Report -Note $Note `
                -Keep $Keep -NoPrune:$NoPrune -Path $Path
            $suffix = if ($result.Already) { ' (already done)' } else { '' }
            $pruned = if ($result.Pruned -gt 0) { "; pruned $($result.Pruned)" } else { '' }
            [Console]::Out.Write("done $($result.Id) -> done$suffix$pruned`n")
        }
        'reopen' {
            $result = Reset-FmBacklogTask -Id $Id -Path $Path
            $suffix = if ($result.Already) { ' (already queued)' } else { '' }
            [Console]::Out.Write("reopen $($result.Id) -> queued$suffix`n")
        }
        'block' {
            if ([string]::IsNullOrWhiteSpace($By)) {
                [Console]::Error.WriteLine('usage: fm-backlog.ps1 block <id> -By <other>')
                exit 2
            }
            $result = Block-FmBacklogTask -Id $Id -By $By -Reason $Reason -Path $Path
            $suffix = if ($result.Already) { ' (already)' } else { '' }
            [Console]::Out.Write("block $($result.Id) -> blocked-by $By$suffix`n")
        }
        'unblock' {
            if ([string]::IsNullOrWhiteSpace($By)) {
                [Console]::Error.WriteLine('usage: fm-backlog.ps1 unblock <id> -By <other>')
                exit 2
            }
            $result = Unblock-FmBacklogTask -Id $Id -By $By -Path $Path
            $suffix = if ($result.Already) { ' (already)' } else { '' }
            [Console]::Out.Write("unblock $($result.Id) -> cleared $By$suffix`n")
        }
        'hold' {
            if ([string]::IsNullOrWhiteSpace($Reason)) {
                [Console]::Error.WriteLine('usage: fm-backlog.ps1 hold <id> -Reason "<text>"')
                exit 2
            }
            $result = Set-FmBacklogHold -Id $Id -Reason $Reason -Kind $Kind -Until $Until -Path $Path
            $suffix = if ($result.Already) { ' (already held)' } else { '' }
            [Console]::Out.Write("hold $($result.Id) -> held$suffix`n")
        }
        'unhold' {
            $result = Clear-FmBacklogHold -Id $Id -Path $Path
            $suffix = if ($result.Already) { ' (already not held)' } else { '' }
            [Console]::Out.Write("unhold $($result.Id) -> cleared$suffix`n")
        }
        'prune' {
            $config = Get-FmBacklogConfig -Path $Path
            $target = if ($Path) { $Path } else { $config.Path }
            $keepCount = if ($null -ne $Keep) { [int]$Keep } else { $config.DoneKeep }
            $result = Invoke-FmBacklogPrune -Path $target -Keep $keepCount -ArchivePath $config.ArchivePath
            [Console]::Out.Write("prune -> archived $($result.Archived)`n")
        }
        'backend' {
            $configDir = Get-FmConfigRoot
            $backend = Get-FmBacklogBackend -ConfigDir $configDir
            $effective = if (Test-FmTasksAxiBackendAvailable -ConfigDir $configDir) { 'tasks-axi' } else { 'manual' }
            [Console]::Out.Write("$backend $effective $((Get-FmBacklogConfig -Path $Path).Path)`n")
        }
        default {
            Write-FmBacklogUsage
            exit 2
        }
    }
} catch {
    [Console]::Error.WriteLine([string]$_.Exception.Message)
    exit 1
}

exit 0
