#requires -Version 7.0
<#
.SYNOPSIS
    Check the environment and print exactly what is missing and how to fix it.

.DESCRIPTION
    Checks the PowerShell version, Pester, git, herdr, treehouse, the Claude
    CLI, the home layout, the module and PATH wiring, and the Claude hook
    registration. Every check is printed, whether it passed or not.

    Exit codes: 0 healthy (no missing check), 1 unhealthy, 2 usage.
    A warning alone does not make the environment unhealthy; the line says what
    the warning costs.

.PARAMETER FirstmateHome
    The home to check. Defaults to $env:FM_HOME, then <userprofile>/firstmate.

.PARAMETER RepoRoot
    The checkout to check. Defaults to the one holding this script.

.PARAMETER ProfilePath
    Profile expected to carry the managed block.

.PARAMETER HookSettingsPath
    Claude settings file expected to carry the hooks.

.PARAMETER HomePointerPath
    File expected to carry the home that resolves without the environment.
    Defaults to <RepoRoot>/.fm-home.
#>
[CmdletBinding()]
param(
    [string]$FirstmateHome,
    [string]$RepoRoot,
    [string]$ProfilePath,
    [string]$HookSettingsPath,
    [string]$HomePointerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmDoctor'

$doctorArgs = @{}
foreach ($name in @('FirstmateHome', 'RepoRoot', 'ProfilePath', 'HookSettingsPath', 'HomePointerPath')) {
    if ($PSBoundParameters.ContainsKey($name)) { $doctorArgs[$name] = $PSBoundParameters[$name] }
}
if (-not $doctorArgs.ContainsKey('RepoRoot')) { $doctorArgs['RepoRoot'] = (Split-Path -Parent $PSScriptRoot) }

try {
    $report = Invoke-FmDoctor @doctorArgs
} catch {
    [Console]::Error.WriteLine("fm-doctor: $_")
    exit 1
}

foreach ($line in $report.Lines) { [Console]::Out.WriteLine([string]$line) }

if ($report.Healthy) { exit 0 }
exit 1
