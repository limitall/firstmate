#requires -Version 7.0
# FmBrief.ps1 (public) - scaffold a crewmate brief or a persistent secondmate
# charter at data/<task-id>/brief.md under the active firstmate home. Ported
# from bin/fm-brief.sh.
#
# Firstmate then replaces the {TASK} placeholder with the task description,
# acceptance criteria, and context. The generated sections are the contract:
# alter them only when the task genuinely deviates from the standard shape.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Scaffold data/<task-id>/brief.md for a ship task, a scout, or a secondmate charter.
.DESCRIPTION
Ship briefs require an explicit -Mode, resolved per task at intake; the scaffold
never guesses one, and it records the choice as the fixed machine-readable
"Delivery contract: mode=<mode>" line the spawn path checks against its own
explicit mode so an adjusted brief and the task metadata cannot drift apart.

-HerdrLab is mandatory when the task will issue Herdr lifecycle commands. It
must be explicit because {TASK} is filled in after scaffolding, so briefs made
without it carry a loud declaration rather than a silently missing contract.

There is no yolo input here: the worker never owns approval decisions, so yolo
is a spawn-time and firstmate-side input only.

Refuses to overwrite an existing brief.
.OUTPUTS
An object with ExitCode (0 written, 1 refused), Path, and the Messages written out.
#>
function New-FmBrief {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Ship')]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Ship')]
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Scout')]
        [AllowEmptyString()][string]$Repo,

        [Parameter(Mandatory, ParameterSetName = 'Ship')][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory, ParameterSetName = 'Scout')][switch]$Scout,
        [Parameter(Mandatory, ParameterSetName = 'Secondmate')][switch]$Secondmate,
        [Parameter(ParameterSetName = 'Secondmate')][string[]]$Project = @(),
        [Parameter(ParameterSetName = 'Secondmate')][switch]$NoProjects,
        [Parameter(ParameterSetName = 'Secondmate')][AllowEmptyString()][string]$Charter,
        [Parameter(ParameterSetName = 'Secondmate')][AllowEmptyString()][string]$Scope,

        [Parameter(ParameterSetName = 'Ship')]
        [Parameter(ParameterSetName = 'Scout')]
        [switch]$HerdrLab
    )
    $messages = [System.Collections.Generic.List[string]]::new()
    function local:Fail([string]$text) {
        $messages.Add($text)
        Write-FmLifecycleStdErr $text
        return [pscustomobject]@{ ExitCode = 1; Path = ''; Messages = @($messages) }
    }

    $kind = switch ($PSCmdlet.ParameterSetName) {
        'Scout' { 'scout' }
        'Secondmate' { 'secondmate' }
        default { 'ship' }
    }

    if (-not (Test-FmLifecycleTaskIdPathSafe -Id $Id)) {
        return (Fail "error: invalid task id '$Id'")
    }

    # Ship delivery mode is an explicit per-task decision: a missing or invalid
    # value stops the scaffold rather than silently defaulting.
    if ($kind -eq 'ship') {
        switch ($Mode) {
            'no-mistakes' { }
            'direct-PR' { }
            'local-only' { }
            'no-mistakes-prod-only' {
                return (Fail 'error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task''s surface and resolve it to no-mistakes or direct-PR at intake')
            }
            default {
                return (Fail "error: -Mode must be one of no-mistakes, direct-PR, local-only (got '$Mode')")
            }
        }
    }
    if ($kind -eq 'secondmate') {
        if ($NoProjects -and $Project.Count -gt 0) {
            return (Fail 'error: -NoProjects cannot be combined with a project list')
        }
        if (-not $NoProjects -and $Project.Count -eq 0) {
            return (Fail 'error: -Secondmate requires at least one project, or -NoProjects for a project-less home')
        }
    }

    $paths = Get-FmLifecyclePaths
    $briefDir = Join-Path $paths.Data $Id
    $brief = Join-Path $briefDir 'brief.md'
    if (Test-Path -LiteralPath $brief) {
        return (Fail "error: $brief already exists")
    }

    $pausedVerb = Get-FmClassifyPausedVerb
    $statusFile = ConvertTo-FmBriefQuotedPath -Path (Join-Path $paths.State "$Id.status")

    if ($kind -eq 'secondmate') {
        $charterText = if ($PSBoundParameters.ContainsKey('Charter') -and $Charter) { $Charter } elseif ($env:FM_SECONDMATE_CHARTER) { $env:FM_SECONDMATE_CHARTER } else { '{TASK}' }
        $scopeText = if ($PSBoundParameters.ContainsKey('Scope') -and $Scope) { $Scope } elseif ($env:FM_SECONDMATE_SCOPE) { $env:FM_SECONDMATE_SCOPE } else { $charterText }
        if ($NoProjects) {
            $projectsBody = 'None. This is a project-less domain: its subject is the firstmate repo this home lives in, so it needs no separate clones under `projects/`; its crews take pooled worktrees of that firstmate repo.'
            $projectNote = 'This domain has no separate project clones: its subject is the firstmate repo this home lives in, and its crews take pooled worktrees of that repo.'
        } else {
            $projectsBody = (($Project | ForEach-Object { "- $_" }) -join "`n")
            $projectNote = 'The projects above are local clones for work you supervise; they are not an exclusive ownership claim.'
        }
        $text = Expand-FmBriefTemplate -Template $script:FmBriefSecondmateTemplate -Values @{
            '__FM_CHARTER__'      = $charterText
            '__FM_SCOPE__'        = $scopeText
            '__FM_PROJECTS__'     = $projectsBody
            '__FM_PROJECT_NOTE__' = $projectNote
            '__FM_FROMFIRST__'    = $script:FmBriefFromFirstLabel
            '__FM_STATUS_FILE__'  = $statusFile
            '__FM_PAUSED__'       = $pausedVerb
        }
        if (-not $PSCmdlet.ShouldProcess($brief, 'scaffold secondmate charter')) {
            return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
        }
        [void][System.IO.Directory]::CreateDirectory($briefDir)
        Write-FmTextFileLf -Path $brief -Text ($text + "`n")
        $note = if ($charterText -eq '{TASK}') { "scaffolded: $brief (secondmate charter; replace {TASK})" } else { "scaffolded: $brief (secondmate charter)" }
        $messages.Add($note)
        [Console]::Out.WriteLine($note)
        return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
    }

    # The Herdr section is present in EVERY crewmate brief: either the hard
    # isolation contract, or the loud declaration that it was not enabled.
    if ($HerdrLab) {
        $herdr = Expand-FmBriefTemplate -Template $script:FmBriefHerdrLab -Values @{
            '__FM_HERDR_HELPER__' = (ConvertTo-FmBriefQuotedPath -Path (Join-Path (Join-Path $paths.Root 'bin') 'fm-herdr-lab.sh'))
            '__FM_ID__'           = $Id
        }
    } else {
        $herdr = $script:FmBriefHerdrDeclaration
    }
    $herdr = $herdr.TrimEnd("`n")

    if ($kind -eq 'scout') {
        $text = Expand-FmBriefTemplate -Template $script:FmBriefScoutTemplate -Values @{
            '__FM_HERDR__'       = $herdr
            '__FM_REPO__'        = $Repo
            '__FM_STATUS_FILE__' = $statusFile
            '__FM_PAUSED__'      = $pausedVerb
            '__FM_DATA__'        = $paths.Data
            '__FM_ROOT__'        = $paths.Root
            '__FM_ID__'          = $Id
        }
        if (-not $PSCmdlet.ShouldProcess($brief, 'scaffold scout brief')) {
            return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
        }
        [void][System.IO.Directory]::CreateDirectory($briefDir)
        Write-FmTextFileLf -Path $brief -Text ($text + "`n")
        $note = "scaffolded: $brief (scout; replace {TASK})"
        $messages.Add($note)
        [Console]::Out.WriteLine($note)
        return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
    }

    $sections = Get-FmBriefModeSections -Mode $Mode -Id $Id
    $dod = (Expand-FmBriefTemplate -Template $sections.Dod -Values @{ '__FM_ID__' = $Id }).TrimEnd("`n")
    $text = Expand-FmBriefTemplate -Template $script:FmBriefShipTemplate -Values @{
        '__FM_HERDR__'       = $herdr
        '__FM_REPO__'        = $Repo
        '__FM_SETUP2__'      = $sections.Setup2
        '__FM_RULE1__'       = $sections.Rule1
        '__FM_STATUS_FILE__' = $statusFile
        '__FM_PAUSED__'      = $pausedVerb
        '__FM_ROOT__'        = $paths.Root
        '__FM_DOD__'         = $dod
        '__FM_ID__'          = $Id
    }
    if (-not $PSCmdlet.ShouldProcess($brief, 'scaffold ship brief')) {
        return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
    }
    [void][System.IO.Directory]::CreateDirectory($briefDir)
    Write-FmTextFileLf -Path $brief -Text ($text + "`n")
    $note = "scaffolded: $brief (ship, mode=$Mode; replace {TASK})"
    $messages.Add($note)
    [Console]::Out.WriteLine($note)
    return [pscustomobject]@{ ExitCode = 0; Path = $brief; Messages = @($messages) }
}
