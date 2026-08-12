#requires -Version 7.0
<#
.SYNOPSIS
    The one setup command: bare PowerShell 7 machine -> working firstmate home.

.DESCRIPTION
    Idempotent. Creates the home layout, wires this checkout into the user's
    PowerShell profile (Import-Module Firstmate, bin/ on PATH, FM_HOME), and
    registers the Claude hooks. Prints what it did and then a doctor report.

    Refuses without installing anything when a hard prerequisite is missing.

    Exit codes: 0 installed and healthy, 1 refused or unhealthy, 2 usage.

.PARAMETER FirstmateHome
    Where the home lives. Defaults to $env:FM_HOME, then <userprofile>/firstmate.

.PARAMETER RepoRoot
    The checkout to wire in. Defaults to the one holding this script.

.PARAMETER ProfilePath
    Profile to write the managed block into. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER HookSettingsPath
    Claude settings file to register hooks in. Defaults to
    <RepoRoot>/.claude/settings.json.

.PARAMETER SkipProfile
    Leave the profile alone.

.PARAMETER SkipHooks
    Leave the Claude hooks alone.
#>
[CmdletBinding()]
param(
    [string]$FirstmateHome,
    [string]$RepoRoot,
    [string]$ProfilePath,
    [string]$HookSettingsPath,
    [switch]$SkipProfile,
    [switch]$SkipHooks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

$setupArgs = @{
    SkipProfile = $SkipProfile
    SkipHooks   = $SkipHooks
}
foreach ($name in @('FirstmateHome', 'RepoRoot', 'ProfilePath', 'HookSettingsPath')) {
    if ($PSBoundParameters.ContainsKey($name)) { $setupArgs[$name] = $PSBoundParameters[$name] }
}
if (-not $setupArgs.ContainsKey('RepoRoot')) { $setupArgs['RepoRoot'] = (Split-Path -Parent $PSScriptRoot) }

try {
    $report = Install-FmHome @setupArgs
} catch {
    [Console]::Error.WriteLine("fm-setup: $_")
    exit 1
}

foreach ($line in $report.Lines) { [Console]::Out.WriteLine([string]$line) }

if (-not $report.Installed) { exit 1 }
if (-not $report.Healthy) { exit 1 }
exit 0
