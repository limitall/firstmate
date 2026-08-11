#requires -Version 7.0

<#
.SYNOPSIS
    Add a work item to data/backlog.md through the manual backlog backend.

.DESCRIPTION
    The equivalent of `tasks-axi add`, writing the same canonical bullet. New
    in-flight work goes to the top of ## In flight; new queued work appends to
    the bottom of ## Queued. Every other item in the file keeps its original
    bytes.

    Refuses a duplicate id, an unknown blocker, a title that would parse back as
    canonical tags, and kind=public-followup - obligations are created by their
    own command family, never here.

.PARAMETER Id
    The task id. Must match [A-Za-z0-9][A-Za-z0-9._-]*, because that is what the
    markdown grammar can round-trip.

.PARAMETER Title
    The one-line title, without canonical tags.

.PARAMETER Kind
    Optional kind tag (for example captain, scout, secondmate).

.PARAMETER Repo
    Optional repo tag.

.PARAMETER Body
    Optional indented body. Blank lines between paragraphs are preserved.

.PARAMETER Priority
    Optional priority 0-4.

.PARAMETER BlockedBy
    Ids this item is blocked by. Each must already exist.

.PARAMETER Start
    Create the item directly in ## In flight.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.PARAMETER Date
    The `since` date to stamp. Defaults to today.

.EXAMPLE
    Add-FmBacklogTask -Id fmwin-backlog -Title 'Port the backlog surface' -Repo firstmate-win
#>
function Add-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$Title,
        [string]$Kind = '',
        [string]$Repo = '',
        [string]$Body = '',
        [Nullable[int]]$Priority,
        [string[]]$BlockedBy = @(),
        [switch]$Start,
        [string]$Path,
        [string]$Date = ''
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = (Get-FmBacklogConfig).Path }
    $state = if ($Start) { 'in_flight' } else { 'queued' }

    $null = Assert-FmBacklogId -Id $Id
    $cleanTitle = Assert-FmBacklogTitle -Title $Title
    $cleanKind = Assert-FmBacklogTagValue -Value $Kind -Field 'kind'
    $cleanRepo = Assert-FmBacklogTagValue -Value $Repo -Field 'repo'
    if ($cleanKind -eq 'public-followup') {
        throw 'refusing to add a public-followup obligation: they are owned by the public-followup command family'
    }
    $priorityValue = $null
    if ($null -ne $Priority) { $priorityValue = Assert-FmBacklogPriority -Priority ([int]$Priority) }
    $created = if ([string]::IsNullOrEmpty($Date)) { Get-FmBacklogToday } else { Assert-FmBacklogDate -Value $Date -Field 'created date' }
    $deps = @(foreach ($blocker in $BlockedBy) {
            Assert-FmBacklogDependency -OwnerId $Id -Type 'blocked-by' -Id $blocker
        })

    if (-not $PSCmdlet.ShouldProcess($Path, "add $Id")) { return }

    $action = {
        param($document)

        Initialize-FmBacklogSection -Document $document
        if (Find-FmBacklogEntry -Document $document -Id $Id) { throw "Task `"$Id`" already exists" }

        $task = [pscustomobject]@{
            Id                     = $Id
            Title                  = $cleanTitle
            State                  = $state
            Kind                   = $cleanKind
            Repo                   = $cleanRepo
            Body                   = $Body
            Deps                   = @($deps)
            Links                  = @(Get-FmBacklogLink -Text $cleanTitle)
            Created                = $created
            Closed                 = ''
            Priority               = $priorityValue
            Hold                   = $null
            PublicFollowupMetadata = ''
        }
        Assert-FmBacklogDependencyExists -Document $document -Dependency $task.Deps

        $entry = [pscustomobject]@{ Kind = 'task'; Lines = @(); Task = $task; Raw = @(); Dirty = $true }
        Add-FmBacklogSectionEntry -Section (Get-FmBacklogSection -Document $document -State $state) `
            -Entry $entry -AtTop:($state -eq 'in_flight')
        $task
    }

    $task = Invoke-FmBacklogMutation -Path $Path -Action $action
    New-FmBacklogResult -Action 'add' -Id $Id -Task $task
}
