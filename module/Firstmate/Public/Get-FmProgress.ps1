#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    How far along every task under way is, without asking anyone.

.DESCRIPTION
    Reads each task's own last declared milestone and percentage from its status
    log and returns one record per task. Private/FmProgress.ps1 documents the
    wire format and, more importantly, what this is not: it measures nothing, it
    reports what the worker declared, and a task that declared no percentage
    comes back with Percent = $null rather than a guess.

    A task whose last line is a terminal `done:` reads as 100 regardless of the
    last number it published, because finished is finished.

.PARAMETER StatePath
    The home's state directory. Defaults to this home's.

.PARAMETER TaskId
    Limit to one task. Without it, every task with a metadata record is reported.

.OUTPUTS
    One record per task: TaskId, Percent (0-100 or $null), State, Note, Project,
    Kind and Bar.

.EXAMPLE
    Get-FmProgress | Format-Table TaskId, Bar, Percent, Note
#>
function Get-FmProgress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$StatePath,
        [string]$TaskId,
        [ValidateRange(4, 60)][int]$BarWidth = 20
    )

    if (-not $StatePath) { $StatePath = Get-FmStateRoot }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { return }

    $metaFiles = @(Get-ChildItem -LiteralPath $StatePath -Filter '*.meta' -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
    if ($TaskId) { $metaFiles = @($metaFiles | Where-Object { $_.BaseName -eq $TaskId }) }

    foreach ($meta in $metaFiles) {
        $id = $meta.BaseName
        $status = Get-FmProgressFromStatus -Path (Join-Path $StatePath "$id.status")

        # Metadata is read defensively: a task whose record is being written as
        # this runs must not take the whole listing down with it.
        $project = ''
        $kind = ''
        try { $project = [string](Get-FmMetaValue -Path $meta.FullName -Key 'project') } catch { $project = '' }
        try { $kind = [string](Get-FmMetaValue -Path $meta.FullName -Key 'kind') } catch { $kind = '' }

        [pscustomobject]@{
            PSTypeName = 'Firstmate.TaskProgress'
            TaskId     = $id
            Percent    = $status.Percent
            State      = $status.State
            Note       = $status.Note
            Project    = if ($project) { Split-Path -Leaf $project } else { '' }
            Kind       = $kind
            Bar        = Format-FmProgressBar -Percent $status.Percent -Width $BarWidth
        }
    }
}
