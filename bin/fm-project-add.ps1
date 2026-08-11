#requires -Version 7.0
<#
.SYNOPSIS
fm-project-add.ps1 - clone an existing project into this home and register it.

.DESCRIPTION
The mechanical half of the project-management procedure's add/clone step. The
decisions above it - which project, which local name, which delivery posture,
and whether an existing second mate already owns that domain - are made before
this runs; what this owns is performing the resolved operation without leaving
the clone and the registry disagreeing.

It refuses an existing destination, a name already registered, a posture this
port cannot deliver (no-mistakes and no-mistakes-prod-only both require the
no-mistakes pipeline, which has no established Windows support), and a
direct-PR clone with no origin remote. When a step after the clone fails, the
clone this command created is removed - and only that.

Exit codes: 0 added, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-project-add.ps1 thing https://github.com/acme/thing.git -Mode direct-PR -Description 'the thing service'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Name = '',
    [Parameter(Position = 1)][string]$Source = '',
    [string]$Mode = '',
    [ValidateSet('on', 'off')][string]$Yolo = 'off',
    [string]$Description = '',
    [string]$ProjectsDir = '',
    [string]$RegistryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

if (-not $Name -or -not $Source -or -not $Mode) {
    [Console]::Error.WriteLine('usage: fm-project-add.ps1 <name> <source> -Mode <direct-PR|local-only> ' +
        '[-Yolo on|off] -Description <text>')
    exit 2
}
if (-not $Description) {
    [Console]::Error.WriteLine('error: -Description is required; a registry line with no description cannot be ' +
        'used to identify the project it names')
    exit 1
}

try {
    $result = Add-FmProject -Name $Name -Source $Source -Mode $Mode -Yolo $Yolo -Description $Description `
        -ProjectsDir $ProjectsDir -RegistryPath $RegistryPath
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
