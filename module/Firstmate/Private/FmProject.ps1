#requires -Version 7.0
# FmProject.ps1 - the project registry and delivery-posture parsing, ported from
# bin/fm-project-mode.sh.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to the brief,
# spawn, and promote commands (AGENTS.md section 7).
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake. Mechanical
#                          output maps it to its most rigorous leg, no-mistakes,
#                          so sync, seeding, and init treat such a project as the
#                          remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and
# warns, so a typo never silently drops the gate.

$script:FmProjectKnownModes = @('no-mistakes', 'direct-PR', 'local-only', 'no-mistakes-prod-only')

# Parse ONE registry line into its registered posture, or $null when the line is
# not a registry entry at all. The bash original matches on the first two
# whitespace-separated fields being "-" and the project name.
function Get-FmProjectRegistryLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $fields = @($Line -split '\s+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 2) { return $null }
    if ($fields[0] -ne '-') { return $null }

    $name = $fields[1]
    $mode = 'no-mistakes'
    $yolo = 'off'

    if ($fields.Count -ge 3 -and $fields[2].StartsWith('[')) {
        # Accumulate fields until one ends with the closing bracket, exactly as
        # the awk original does, so "[direct-PR +yolo]" is read as one annotation.
        $parts = @()
        for ($i = 2; $i -lt $fields.Count; $i++) {
            $parts += $fields[$i]
            if ($fields[$i].EndsWith(']')) { break }
        }
        $annotation = ($parts -join ' ') -replace '^\[', '' -replace '\]$', ''
        $tokens = @($annotation -split ' ' | Where-Object { $_ -ne '' })
        if ($tokens.Count -ge 1 -and $tokens[0] -ne '+yolo') { $mode = $tokens[0] }
        if ($tokens -contains '+yolo') { $yolo = 'on' }
    }

    [pscustomobject]@{ Name = $name; Mode = $mode; Yolo = $yolo }
}

# Every registered project, in registry order. Used by callers that need the
# whole navigation registry rather than one project's posture.
function Get-FmProjectRegistryEntry {
    [CmdletBinding()]
    param([string]$RegistryPath)

    if ([string]::IsNullOrEmpty($RegistryPath)) {
        $RegistryPath = Join-Path (Get-FmSessionPaths).Data 'projects.md'
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return @() }

    $entries = @()
    foreach ($line in (Get-FmSessionFileLines -Path $RegistryPath)) {
        $parsed = Get-FmProjectRegistryLine -Line $line
        if ($null -ne $parsed) { $entries += $parsed }
    }
    $entries
}
