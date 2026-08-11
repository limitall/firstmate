#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Refresh this home's project clones: fast-forward each checked-out default
branch to origin's when that is safe, and prune landed branches.

.DESCRIPTION
The PowerShell port of bin/fm-fleet-sync.sh. Private/FmFleetSync.ps1 carries
the full statement of what is preserved and what the port replaces; the short
version is that nothing is ever forced, stashed, or discarded, exactly one
unambiguously safe drift self-heals, and every other off-default state is
reported as a quantified STUCK line and left alone.

This is also the name bootstrap's network sweep resolves
(docs/session-start.md), so it must stay callable with no arguments.

.PARAMETER Project
Sync one clone instead of all of them. Accepts a path (absolute, or relative to
the caller's cwd) or a bare "<name>" / "projects/<name>" form resolved against
this home's projects dir. Bare names prefer this home's projects dir before
falling back to an explicit path.

.EXAMPLE
Invoke-FmFleetSync

.EXAMPLE
Invoke-FmFleetSync -Project dotfiles-private
#>
function Invoke-FmFleetSync {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][string]$Project = '',
        [string]$ProjectsDir = '',
        [string]$RegistryPath = ''
    )

    $null = Invoke-FmDeliveryGuard

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }

    # One gate for the whole refresh rather than one per clone: a captain
    # confirming a fleet refresh is answering about the refresh, not about each
    # of a dozen repositories in turn.
    $target = if ($Project) { $Project } else { $ProjectsDir }
    if (-not $PSCmdlet.ShouldProcess($target, 'refresh project clones')) { return @() }

    if ($Project) {
        $resolved = Resolve-FmProjectPath -Argument $Project -ProjectsDir $ProjectsDir
        return Sync-FmProjectClone -Path $resolved -ProjectsDir $ProjectsDir -RegistryPath $RegistryPath -Confirm:$false
    }

    if (-not (Test-Path -LiteralPath $ProjectsDir -PathType Container)) { return @() }
    $out = @()
    foreach ($dir in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $out += Sync-FmProjectClone -Path $dir.FullName -ProjectsDir $ProjectsDir -RegistryPath $RegistryPath -Confirm:$false
    }
    $out
}
