#requires -Version 7.0

<#
.SYNOPSIS
    Resolve a project's REGISTERED delivery posture from data/projects.md.

.DESCRIPTION
    Port of bin/fm-project-mode.sh. Returns an object carrying Mode
    (no-mistakes|direct-PR|local-only) and Yolo (on|off); bin/fm-project-mode.ps1
    renders it as the same two words the bash command prints.

    MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain
    register for this project", never "how does this task ship".

    An unknown or missing project, and an unknown mode, fall back to
    "no-mistakes off" with a warning, so a typo never silently drops the gate.

.PARAMETER Name
    The registered project name.

.PARAMETER Raw
    Return the registered annotation unmapped, so a caller that must tell a
    conditional policy apart from a flat mode sees "no-mistakes-prod-only"
    itself instead of its most rigorous leg.

.PARAMETER RegistryPath
    Override the registry location. Defaults to <data>/projects.md.

.EXAMPLE
    (Get-FmProjectMode -Name firstmate-win).Mode
#>
function Get-FmProjectMode {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [switch]$Raw,
        [string]$RegistryPath
    )

    if ([string]::IsNullOrEmpty($RegistryPath)) {
        $RegistryPath = Join-Path (Get-FmSessionPaths).Data 'projects.md'
    }

    $fallback = [pscustomobject]@{ Name = $Name; Mode = 'no-mistakes'; Yolo = 'off'; Registered = $false }

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        Write-Warning "no registry at $RegistryPath; defaulting $Name to no-mistakes off"
        return $fallback
    }

    $entry = Get-FmProjectRegistryEntry -RegistryPath $RegistryPath | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $entry) {
        Write-Warning "project `"$Name`" not in registry; defaulting to no-mistakes off"
        return $fallback
    }

    $mode = $entry.Mode
    $yolo = $entry.Yolo
    if ($script:FmProjectKnownModes -notcontains $mode) {
        Write-Warning "unknown mode `"$mode`" for $Name; defaulting to no-mistakes off"
        $mode = 'no-mistakes'
        $yolo = 'off'
    }
    if ($yolo -ne 'on' -and $yolo -ne 'off') { $yolo = 'off' }

    # A conditional policy is not a task mode. Mechanical callers get its most
    # rigorous leg; -Raw callers get the annotation itself.
    if (-not $Raw -and $mode -eq 'no-mistakes-prod-only') { $mode = 'no-mistakes' }

    [pscustomobject]@{ Name = $Name; Mode = $mode; Yolo = $yolo; Registered = $true }
}
