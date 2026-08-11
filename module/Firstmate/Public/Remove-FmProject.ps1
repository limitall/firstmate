#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Remove a project clone from this home and reconcile its registry entry.

.DESCRIPTION
Project removal is destructive, so this command is built around its preflight
rather than around the removal.

TWO GATES, AND NEITHER SUBSTITUTES FOR THE OTHER.

  1. -Approved is the captain's explicit removal decision. Without it nothing is
     inspected and nothing is removed. The decision belongs to the captain; this
     command exists so that once it is made, firstmate never has to issue a raw
     recursive delete against projects/.
  2. The preflight is the unlanded-work check, and it runs even with -Approved.
     It looks for tasks still recorded against the clone, second mates that were
     provisioned with it, linked worktrees, uncommitted changes, and commits
     that exist nowhere else, and it reports ALL of them rather than stopping at
     the first - an operator clearing one blocker needs to know about the rest.
     Any blocker refuses the removal.

     What counts as "exists nowhere else" depends on the clone: a remote-backed
     clone's work is landed once it is on a remote, while a clone with no remote
     has nothing to land on, so the test becomes whether its branches are merged
     into its default branch.

STALE REGISTRY RECONCILIATION. When the clone is already gone and only the
registry line remains, that line is removed so navigation matches reality. That
is the one case where this command changes something without a clone present.

.PARAMETER Name
The registered project name.

.PARAMETER Approved
The captain's explicit removal decision. Required.

.EXAMPLE
Remove-FmProject -Name old-thing -Approved
#>
function Remove-FmProject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Approved,
        [string]$ProjectsDir = '',
        [string]$RegistryPath = '',
        [string]$StateDir = '',
        [string]$DataDir = ''
    )

    $null = Assert-FmProjectName -Name $Name

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }
    if (-not $DataDir) { $DataDir = (Get-FmSessionPaths).Data }
    if (-not $StateDir) { $StateDir = (Get-FmSessionPaths).State }
    if (-not $RegistryPath) { $RegistryPath = Join-Path $DataDir 'projects.md' }

    if (-not $Approved) {
        throw ("error: removing project `"$Name`" is destructive and needs the captain's explicit removal " +
            'decision; re-run with -Approved once you have it')
    }

    $path = Join-Path $ProjectsDir $Name
    $isRegistered = @(Get-FmProjectRegistryEntry -RegistryPath $RegistryPath |
        Where-Object { $_.Name -eq $Name }).Count -gt 0
    $exists = Test-Path -LiteralPath $path -PathType Container

    if (-not $exists -and -not $isRegistered) {
        throw "error: project `"$Name`" has no clone at $path and no entry in $RegistryPath; nothing to remove"
    }

    $preflight = Test-FmProjectRemovable -Name $Name -ProjectsDir $ProjectsDir -StateDir $StateDir -DataDir $DataDir
    if (-not $preflight.Removable) {
        $detail = ($preflight.Blockers | ForEach-Object { "  - $_" }) -join "`n"
        throw ("REFUSED: project `"$Name`" still has work or dependencies that removal would destroy:`n$detail`n" +
            'Resolve every line above (or land the work elsewhere) and run this again; nothing was removed.')
    }

    $target = if ($exists) { "clone $path and its registry entry" } else { "the stale registry entry for $Name" }
    if (-not $PSCmdlet.ShouldProcess($Name, "remove $target")) { return $null }

    $removedClone = $false
    if ($exists) {
        # The clone goes first: if the delete is refused (a live handle, a cwd
        # inside it - Windows fails closed here), the registry must still point
        # at what is on disk.
        $removedClone = [bool](Remove-FmProjectDirectory -Path $path -Confirm:$false)
    }
    $removedEntry = [bool](Remove-FmProjectRegistryEntry -RegistryPath $RegistryPath -Name $Name)

    $message = if ($removedClone -and $removedEntry) {
        "removed: clone $path and its registry entry"
    } elseif ($removedClone) {
        "removed: clone $path (it had no registry entry)"
    } elseif ($removedEntry) {
        "reconciled: removed the registry entry for `"$Name`"; its clone was already gone"
    } else {
        "unchanged: nothing to remove for `"$Name`""
    }

    [pscustomobject]@{
        Name         = $Name
        Path         = $path
        RemovedClone = $removedClone
        RemovedEntry = $removedEntry
        RegistryPath = $RegistryPath
        Message      = $message
    }
}
