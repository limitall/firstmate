#requires -Version 7.0
<#
.SYNOPSIS
fm-project-remove.ps1 - remove a project clone and reconcile its registry entry.

.DESCRIPTION
Project removal is destructive, so this command is built around its preflight.

Two gates, and neither substitutes for the other:

  -Approved is the captain's explicit removal decision. Without it nothing is
  inspected and nothing is removed. This command exists so that once that
  decision is made, firstmate never has to issue a raw recursive delete against
  projects/.

  The preflight runs even with -Approved. It looks for tasks still recorded
  against the clone, second mates provisioned with it, linked worktrees,
  uncommitted changes, and commits that exist nowhere else, and reports ALL
  blockers rather than stopping at the first. Any blocker refuses the removal.

When the clone is already gone and only a registry line remains, that line is
removed so navigation matches reality.

Exit codes: 0 removed or reconciled, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-project-remove.ps1 old-thing -Approved
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)][string]$Name = '',
    [switch]$Approved,
    [string]$ProjectsDir = '',
    [string]$RegistryPath = '',
    [string]$StateDir = '',
    [string]$DataDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

if (-not $Name) {
    [Console]::Error.WriteLine('usage: fm-project-remove.ps1 <name> -Approved')
    exit 2
}

try {
    $result = Remove-FmProject -Name $Name -Approved:$Approved -ProjectsDir $ProjectsDir `
        -RegistryPath $RegistryPath -StateDir $StateDir -DataDir $DataDir -Confirm:$false
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
