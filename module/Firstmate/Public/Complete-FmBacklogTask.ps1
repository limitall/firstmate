#requires -Version 7.0

<#
.SYNOPSIS
    Close a backlog item, then apply the configured recent-Done retention.

.DESCRIPTION
    The equivalent of `tasks-axi done`. Closed work surfaces at the top of ##
    Done with its closure date, and the closure verb follows the evidence:
    `merged` when the item carries a PR link, `reported` when it carries a report
    link, `done` otherwise.

    Re-running on an already-Done item backfills links and notes WITHOUT changing
    the close date, so a second call after a lost turn is safe.

    Retention then keeps only the configured most recent Done rows (`done_keep`
    in .tasks.toml, default 10) and appends the surplus to the archive. The
    surplus is archived with its ORIGINAL lines, so a historical record is never
    reflowed on its way out. An active public-followup obligation is never
    counted and never archived.

.PARAMETER Id
    The task id.

.PARAMETER Pr
    A pull request URL to record. Must end in /pull/<number>.

.PARAMETER Report
    A report path to record, of the form data/<id>/report.md.

.PARAMETER Note
    A line to append to the item body.

.PARAMETER Keep
    Override how many Done rows to keep. Defaults to done_keep from .tasks.toml.

.PARAMETER NoPrune
    Close the item without applying retention.

.PARAMETER Path
    The backlog file. Defaults to the file .tasks.toml selects for this home.

.PARAMETER Date
    The closure date to stamp. Defaults to today.

.EXAMPLE
    Complete-FmBacklogTask -Id fmwin-backlog -Note 'merged via chain; local main'
#>
function Complete-FmBacklogTask {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$Pr = '',
        [string]$Report = '',
        [string]$Note = '',
        [Nullable[int]]$Keep,
        [switch]$NoPrune,
        [string]$Path,
        [string]$Date = ''
    )

    $config = Get-FmBacklogConfig -Path $Path
    if ([string]::IsNullOrEmpty($Path)) { $Path = $config.Path }
    $keepCount = if ($null -ne $Keep) { [int]$Keep } else { $config.DoneKeep }
    if ($keepCount -lt 0) { throw '-Keep must be a non-negative integer' }

    $current = Get-FmBacklogTask -Id $Id -Path $Path
    if ($null -eq $current) { throw "Task `"$Id`" not found" }

    if (-not $PSCmdlet.ShouldProcess($Path, "done $Id")) { return }

    $already = ($current.State -eq 'done')
    if ($already) {
        # Backfill only: links and notes are added when they are missing, and the
        # close date is left exactly as it was.
        $prUrl = $Pr
        $reportUrl = $Report
        $noteText = $Note
        $action = {
            param($document)

            $found = Find-FmBacklogEntry -Document $document -Id $Id
            if ($null -eq $found) { throw "Task `"$Id`" not found" }
            $task = $found.Entry.Task
            Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'close'

            $changed = $false
            foreach ($link in @(
                    @{ Kind = 'pr'; Url = $prUrl },
                    @{ Kind = 'report'; Url = $reportUrl })) {
                if ([string]::IsNullOrEmpty($link.Url)) { continue }
                $title = Add-FmBacklogTitleLink -Title $task.Title -Kind $link.Kind -Url $link.Url
                if ($title -ne $task.Title) { $task.Title = $title; $changed = $true }
            }
            if (-not [string]::IsNullOrEmpty($noteText)) {
                $bodyLines = @()
                if (-not [string]::IsNullOrEmpty($task.Body)) { $bodyLines = @($task.Body -split "`n") }
                if ($bodyLines -notcontains $noteText) {
                    $task.Body = if ([string]::IsNullOrEmpty($task.Body)) { $noteText } else { "$($task.Body)`n$noteText" }
                    $changed = $true
                }
            }
            if ($changed) {
                $task.Links = @(Get-FmBacklogLink -Text $task.Title)
                $found.Entry.Dirty = $true
            }
            $task
        }

        $task = Invoke-FmBacklogMutation -Path $Path -Action $action
    } else {
        $task = Invoke-FmBacklogTransition -Path $Path -Id $Id -To 'done' -Pr $Pr -Report $Report -Note $Note -Date $Date
    }

    $pruned = 0
    if (-not $NoPrune) {
        $result = Invoke-FmBacklogPrune -Path $Path -Keep $keepCount -ArchivePath $config.ArchivePath -Date $Date
        $pruned = $result.Archived
    }
    New-FmBacklogResult -Action 'done' -Id $Id -Task $task -Already:$already -Pruned $pruned
}
