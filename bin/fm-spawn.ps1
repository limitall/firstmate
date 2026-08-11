#requires -Version 7.0
<#
.SYNOPSIS
fm-spawn.ps1 - spawn a direct report: a worker in a leased, isolated worktree
on the herdr session provider.

.DESCRIPTION
Thin entry point over Start-FmWorker. All mechanics live in the module; this
script only resolves the module, forwards arguments, and maps outcomes onto
exit codes (0 success, 1 refusal or failure, 2 usage).

.EXAMPLE
./bin/fm-spawn.ps1 -TaskId my-task -Project C:\repos\thing -BriefPath C:\fm\data\my-task\brief.md -Harness claude -LaunchCommand claude
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$BriefPath,
    [Parameter(Mandatory)][string]$Harness,
    [string]$LaunchCommand = '',
    [ValidateSet('ship', 'scout', 'secondmate')][string]$Kind = 'ship',
    [string]$Mode = '',
    [string]$Yolo = '',
    [string]$Model = '',
    [string]$Effort = '',
    [string]$FirstmateHome = '',
    [switch]$SkipBaseRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module resolution. The manifest is the real entry point; the dot-source
# fallback exists so these scripts run before the module loader lands and is
# harmless once it has.
$fmManifest = Join-Path $PSScriptRoot '../module/Firstmate/Firstmate.psd1'
if (Test-Path -LiteralPath $fmManifest) {
    Import-Module $fmManifest -Force
} else {
    $fmModule = Join-Path $PSScriptRoot '../module/Firstmate'
    foreach ($fmFile in @(Get-ChildItem -Path (Join-Path $fmModule 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -Path (Join-Path $fmModule 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        . $fmFile.FullName
    }
}

try {
    $worker = Start-FmWorker -TaskId $TaskId -Project $Project -BriefPath $BriefPath -Harness $Harness `
        -LaunchCommand $LaunchCommand -Kind $Kind -Mode $Mode -Yolo $Yolo -Model $Model -Effort $Effort `
        -FirstmateHome $FirstmateHome -SkipBaseRefresh:$SkipBaseRefresh
    if ($null -eq $worker) { exit 0 }
    $worker | Format-List | Out-String | Write-Output
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
