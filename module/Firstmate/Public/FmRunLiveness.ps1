#requires -Version 7.0
# FmRunLiveness.ps1 (public) - the one reading that separates a crewmate waiting
# on a live background run from a crewmate waiting on one that has already ended.
#
# The area's rationale, the measurement it rests on, and the failure direction
# are in Private/FmRunLiveness.ps1 and docs/finished-run-stall.md. This file owns
# the decision procedure and the verdict vocabulary.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Whether a task has any live process of its own: `processes`, `none`, or
`unknown`.

.DESCRIPTION
Answers the question a stalled worker cannot answer about itself. Discovery uses
two independent passes over ONE process-table read, and their union is the task's
process set:

1. the launcher, found by the brief path firstmate itself put on the launch
   command line, plus everything descended from it - complete by construction
   for anything the agent starts, because a Windows child cannot leave its
   parent;
2. any process naming the task's worktree in its command line or its own image
   path, plus everything descended from THAT - which recovers a run whose
   intermediate parent has already exited and left it orphaned.

The launch spine (the launcher and the harness program itself) is then removed,
because those are alive for as long as the worker is and say nothing about
whether it is running anything.

`none` is returned ONLY after a process table was read successfully and the
remaining set was empty. Every other outcome - the probe disabled, no task
record, an unreadable process table, no launcher process found - is `unknown`.
Callers must treat `unknown` as no information: reporting a run finished while
it is still running is worse than the stall this exists to catch.

A `processes` reading also carries `Activity`, a SEPARATE and positive-only
answer to the different question of whether that process set is getting
anywhere: `advancing` when movement was measured since the last look,
`unobserved` when a comparable earlier sample existed and nothing moved, and
`unknown` when nothing was comparable. `unobserved` is NOT a stall verdict and
nothing may escalate on it - a run awaiting a network reply measures exactly
like a hung one, which is why no negative is available here at all.
Private/FmRunLiveness.ps1 carries the measurement that settles it.

.PARAMETER TaskId
The task id, as in `state/<id>.meta`.

.PARAMETER StatePath
The state directory. Defaults to this home's.

.PARAMETER DataPath
The data directory holding `<id>/brief.md`. Defaults to this home's.

.PARAMETER Table
A process table already read by the caller, so one watcher cycle can classify
every window from a single read. Omit to read one.

.OUTPUTS
[pscustomobject] TaskId, State, ProcessId, AgentProcessId, Detail, Activity,
ActivityDetail.

.EXAMPLE
(Get-FmTaskRunLiveness -TaskId 'tg-route').State
#>
function Get-FmTaskRunLiveness {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$TaskId,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyString()][string]$StatePath,
        [Parameter(Position = 2)][AllowNull()][AllowEmptyString()][string]$DataPath,
        [Parameter(Position = 3)][AllowNull()][object[]]$Table
    )

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail 'no task id')
    }

    $settings = Get-FmRunLivenessSettings
    if ($settings.Disabled) {
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail 'run-liveness probe disabled (FM_RUN_LIVENESS_DISABLE=1)')
    }

    if (-not $StatePath -or -not $DataPath) {
        try {
            $paths = Get-FmLifecyclePaths
        } catch {
            return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail "home paths unresolved ($($_.Exception.Message))")
        }
        if (-not $StatePath) { $StatePath = [string]$paths.State }
        if (-not $DataPath) { $DataPath = [string]$paths.Data }
    }

    $meta = Join-Path $StatePath "$TaskId.meta"
    if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) {
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail "no metadata for $TaskId")
    }
    $worktree = Get-FmMetaValue -Path $meta -Key 'worktree'
    $harness = Get-FmMetaValue -Path $meta -Key 'harness'
    $brief = Join-Path (Join-Path $DataPath $TaskId) 'brief.md'

    if ($null -eq $Table) { $Table = Get-FmRunLivenessProcessTable }
    if ($null -eq $Table) {
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail 'the process table could not be read')
    }
    $Table = @($Table)

    $launchers = [System.Collections.Generic.List[int]]::new()
    $named = [System.Collections.Generic.List[int]]::new()
    foreach ($row in $Table) {
        $command = [string]$row.CommandLine
        if (Test-FmRunLivenessNamesPath -Text $command -Directory $brief) {
            $launchers.Add([int]$row.ProcessId)
            continue
        }
        if ($worktree) {
            if ((Test-FmRunLivenessNamesPath -Text $command -Directory $worktree) -or
                (Test-FmRunLivenessNamesPath -Text ([string]$row.ExecutablePath) -Directory $worktree)) {
                $named.Add([int]$row.ProcessId)
            }
        }
    }

    if ($launchers.Count -eq 0) {
        # No launcher means the endpoint is gone or the worker was not launched
        # through firstmate. Either way there is no agent whose descendants could
        # be counted, and a dead endpoint has its own owner
        # (Get-FmBackendAgentAlive) - so this reports no information rather than
        # an empty set that would read as "nothing is running".
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'unknown' -Detail "no launcher process names $brief")
    }

    $all = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $launchers) { [void]$all.Add($id) }
    foreach ($id in $named) { [void]$all.Add($id) }
    foreach ($root in @($launchers) + @($named)) {
        foreach ($id in (Get-FmRunLivenessDescendantId -RootId $root -Table $Table)) { [void]$all.Add([int]$id) }
    }

    $spine = @(Get-FmRunLivenessSpineId -LauncherId @($launchers) -CandidateId @($all) -Table $Table -Harness $harness)
    $work = @($all | Where-Object { -not ($spine -contains $_) } | Sort-Object)
    $agent = @($spine | Where-Object { -not ($launchers -contains $_) } | Sort-Object)

    if ($work.Count -eq 0) {
        # The activity sample belongs to a run that no longer exists; leaving it
        # would let the NEXT run of a reused task id compare against a stranger.
        Clear-FmRunActivitySample -TaskId $TaskId -StatePath $StatePath
        return (New-FmRunLivenessRecord -TaskId $TaskId -State 'none' -Detail "no live process for $TaskId beyond its agent" -AgentProcessId $agent)
    }

    # Only here is "is it advancing?" a meaningful question, and only here is a
    # sample worth keeping: with no work set there is nothing to compare.
    $activity = Get-FmRunActivity -TaskId $TaskId -StatePath $StatePath -ProcessId $work -Table $Table
    return (New-FmRunLivenessRecord -TaskId $TaskId -State 'processes' -Detail "$($work.Count) live process(es) for $TaskId" `
            -ProcessId $work -AgentProcessId $agent -Activity $activity.State -ActivityDetail $activity.Detail)
}

<#
.SYNOPSIS
The one-line reading `bin/fm-run-liveness.ps1` prints and a wake reason quotes.

.DESCRIPTION
Stable and parseable, in the shape the rest of this port already uses for a
current-state line:

    liveness: <processes|none|unknown> · task: <id> · <detail>

A `pids:` field is appended only when there are process ids to name, so an
inspection can go straight to the process rather than re-deriving it.

An `activity:` field follows on a reading that measured movement either way, and
carries its own detail, because the two answers are genuinely different
questions and a reader who takes "processes" for "working" is making exactly the
mistake this area exists to prevent. It is omitted on `unknown`, where there is
nothing to report and a clause would only add noise.

.PARAMETER Liveness
A record from Get-FmTaskRunLiveness.
#>
function Format-FmTaskRunLiveness {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][pscustomobject]$Liveness)
    $line = "liveness: $($Liveness.State) · task: $($Liveness.TaskId) · $($Liveness.Detail)"
    if (@($Liveness.ProcessId).Count -gt 0) { $line = "$line · pids: $(@($Liveness.ProcessId) -join ', ')" }
    # Both properties are tested before either is read: StrictMode throws on a
    # missing one, and a record may come from any caller, not only from
    # New-FmRunLivenessRecord.
    $names = $Liveness.PSObject.Properties.Name
    if (($names -contains 'Activity') -and ($names -contains 'ActivityDetail') -and
        (@('advancing', 'unobserved') -contains [string]$Liveness.Activity)) {
        $line = "$line · activity: $($Liveness.Activity) · $($Liveness.ActivityDetail)"
    }
    return $line
}
