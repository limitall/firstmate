#!/usr/bin/env pwsh
#requires -Version 7.0
<#
    .SYNOPSIS
    Print this instance's resolved firstmate home and layout.

    .DESCRIPTION
    The smallest possible end-to-end proof that the module loads and resolves a
    home: every other bin/ entry point imports Firstmate the same way this one
    does, so when a path, a manifest, or a loader is wrong, this is the command
    that says so first.

    Resolution order is FM_HOME, then FM_ROOT_OVERRIDE, then the code root, with
    FM_STATE_OVERRIDE able to move state/ on its own (AGENTS.md section 2).

    .PARAMETER Initialize
    Create the home's data/, state/, config/ and projects/ directories if they do
    not exist. Idempotent, and it never touches existing contents.

    .PARAMETER Json
    Emit the layout as JSON for a caller that parses it.

    .PARAMETER Path
    Print only one resolved path, unlabelled, for use in a variable assignment.

    .EXAMPLE
    ./bin/fm-home.ps1
    Print the labelled layout.

    .EXAMPLE
    $state = ./bin/fm-home.ps1 -Path State
    Capture one path.

    .EXAMPLE
    FM_HOME=/srv/secondmate-a ./bin/fm-home.ps1 -Initialize
    Create a secondmate home and show what was created.
#>
[CmdletBinding()]
param(
    [switch]$Initialize,
    [switch]$Json,
    [ValidateSet('Root', 'Home', 'State', 'Data', 'Config', 'Projects')]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmHomeLayout'

$layout = if ($Initialize) { Initialize-FmHome } else { Get-FmHomeLayout }

if ($Path) {
    Write-Output $layout.$Path
    return
}
if ($Json) {
    Write-Output ($layout | Select-Object -Property Root, Home, State, Data, Config, Projects | ConvertTo-Json)
    return
}

foreach ($name in @('Root', 'Home', 'State', 'Data', 'Config', 'Projects')) {
    $value = $layout.$name
    $exists = if (Test-Path -LiteralPath $value -PathType Container) { '' } else { '  (absent)' }
    Write-Output ('{0,-10}{1}{2}' -f "$($name):", $value, $exists)
}
