#requires -Version 7.0
<#
.SYNOPSIS
fm-progress.ps1 - how far along every task under way is, at a glance.

.DESCRIPTION
Thin entry point over Get-FmProgress. One line per task: a bar, a percentage,
and the milestone the worker last declared.

The percentage is the WORKER'S OWN claim, not a measurement. A task that has
declared none shows `????` and no number, because an invented figure reads
exactly like a real one and would be worse than nothing.

.PARAMETER TaskId
Limit to one task.

.PARAMETER Watch
Redraw every few seconds until interrupted, so it can be left open beside the
work.

.EXAMPLE
bin/fm-progress.ps1

.EXAMPLE
bin/fm-progress.ps1 -Watch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [switch]$Watch,
    [ValidateRange(2, 60)][int]$IntervalSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmProgress'

function Write-ProgressReport {
    param([string]$Task)

    $rows = @(if ($Task) { Get-FmProgress -TaskId $Task } else { Get-FmProgress })
    if ($rows.Count -eq 0) {
        [Console]::Out.WriteLine('no tasks under way')
        return
    }
    foreach ($row in $rows) {
        $percent = if ($null -eq $row.Percent) { '  ? ' } else { '{0,3}%' -f $row.Percent }
        $note = [string]$row.Note
        # Bounded so one long milestone cannot wrap the whole report into noise.
        if ($note.Length -gt 78) { $note = $note.Substring(0, 75) + '...' }
        [Console]::Out.WriteLine(('{0,-14} [{1}] {2}  {3}' -f $row.TaskId, $row.Bar, $percent, $note))
    }
}

if (-not $Watch) {
    Write-ProgressReport -Task $TaskId
    exit 0
}

# -Watch is a foreground redraw on purpose. It is a viewer, never a supervisor:
# it does not drain the wake queue, does not touch the watcher lock, and running
# it is not a substitute for the supervision cycle.
while ($true) {
    Clear-Host
    [Console]::Out.WriteLine("firstmate progress - $(Get-Date -Format 'HH:mm:ss') - Ctrl+C to stop")
    [Console]::Out.WriteLine('')
    Write-ProgressReport -Task $TaskId
    Start-Sleep -Seconds $IntervalSeconds
}
