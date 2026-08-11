#requires -Version 7.0
<#
.SYNOPSIS
fm-merge-local.ps1 - the approved local merge for a local-only ship task.

.DESCRIPTION
Fast-forwards the project's default branch to the crewmate's fm/<task-id>
branch. Port of bin/fm-merge-local.sh.

This is firstmate's merge gate-action: the captain's merge authority applied
locally instead of through a GitHub PR. It only runs for mode=local-only tasks,
only after the captain approves (or yolo=on auto-approves), and only as a clean
fast-forward - it refuses a diverged branch and tells you to have the crewmate
rebase. Nothing is ever forced, stashed, or discarded.

Exit codes: 0 merged, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-merge-local.ps1 my-task
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [string]$StateDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

if (-not $TaskId) {
    [Console]::Error.WriteLine('usage: fm-merge-local.ps1 <task-id>')
    exit 2
}

try {
    # -Confirm:$false: the cmdlet is ConfirmImpact=High so a direct caller is
    # asked first, but reaching this entry point IS the approved action - the
    # captain's merge decision was made before it was run.
    $result = Invoke-FmMergeLocal -TaskId $TaskId -StateDir $StateDir -Confirm:$false
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    # Straight to stderr, not Write-Error: a refusal is a message for a human or
    # a calling script, not a PowerShell error record with source decoration.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
