#requires -Version 7.0
<#
Perform the approved local merge for a local-only ship task: fast-forward the
project's default branch to the crewmate's fm/<id> branch.

Usage: fm-merge-local.ps1 <task-id>

This is firstmate's merge gate-action - the captain's merge authority applied
locally instead of through a PR. It runs only for a mode=local-only task, only
after the captain approves (or yolo auto-approves), and only as a clean
fast-forward: a diverged branch is refused, and the crewmate rebases instead.

Exit codes: 0 merged, 1 refused or failed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}
if ($args.Count -lt 1) {
    [Console]::Error.WriteLine('usage: fm-merge-local.ps1 <task-id>')
    exit 1
}

$result = Invoke-FmMergeLocal -Id "$($args[0])" -Confirm:$false
exit $result.ExitCode
