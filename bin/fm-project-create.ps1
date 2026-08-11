#requires -Version 7.0
<#
.SYNOPSIS
fm-project-create.ps1 - create a new LOCAL project repository and register it.

.DESCRIPTION
Creates a local git repository under projects/<name> and adds its registry
entry. It makes no network call and never creates a GitHub repository.

Creating a remote repository is outward-facing: it needs the captain's explicit
consent for the exact name, owner, visibility, and posture, and a stated default
never replaces that consent. That consent is obtained above this command, the
repository is created with gh-axi, and the result is brought in with
fm-project-add.ps1. So this command refuses any posture that would require a
remote it is not allowed to create.

Exit codes: 0 created, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-project-create.ps1 notes -Description 'captain-private notes and scratch tooling'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Name = '',
    [string]$Mode = 'local-only',
    [ValidateSet('on', 'off')][string]$Yolo = 'off',
    [string]$Description = '',
    [string]$DefaultBranch = 'main',
    [string]$ProjectsDir = '',
    [string]$RegistryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

if (-not $Name) {
    [Console]::Error.WriteLine('usage: fm-project-create.ps1 <name> [-Mode local-only] [-Yolo on|off] ' +
        '-Description <text> [-DefaultBranch main]')
    exit 2
}
if (-not $Description) {
    [Console]::Error.WriteLine('error: -Description is required; a registry line with no description cannot be ' +
        'used to identify the project it names')
    exit 1
}

try {
    $result = New-FmProject -Name $Name -Mode $Mode -Yolo $Yolo -Description $Description `
        -DefaultBranch $DefaultBranch -ProjectsDir $ProjectsDir -RegistryPath $RegistryPath
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
