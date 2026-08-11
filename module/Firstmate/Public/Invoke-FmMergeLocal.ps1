#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Perform the approved local merge for a local-only ship task: fast-forward the
project's default branch to the crewmate's fm/<id> branch.

.DESCRIPTION
The PowerShell port of bin/fm-merge-local.sh.

This is firstmate's merge gate-action - the captain's merge authority applied
locally instead of via a GitHub PR. It is the one sanctioned exception to hard
rule #1 "never run state-changing git in projects/", and it is narrow: it only
runs for mode=local-only tasks, only after the captain approves (or yolo=on
auto-approves), and only as a clean fast-forward.

WHAT IT REFUSES, AND WHY EACH REFUSAL IS THE POINT
  - a task that is not mode=local-only: a PR task lands through its PR, and
    merging it here would bypass the gate its mode exists to impose.
  - a missing fm/<id> branch: there is nothing to land, and guessing another
    branch would land work nobody approved.
  - a project checkout that is not on its default branch, or is dirty: the
    fast-forward would land somewhere unpredictable, on top of changes
    firstmate never wrote and must not disturb.
  - a diverged branch: it is sent back to the crewmate to rebase. The merge is
    --ff-only, so nothing is ever forced, stashed, or discarded.

.PARAMETER TaskId
The task whose fm/<id> branch is being landed.

.PARAMETER StateDir
Override the state directory. Defaults to this home's, resolved from the same
environment contract the bash scripts use.

.EXAMPLE
Invoke-FmMergeLocal -TaskId my-task
#>
function Invoke-FmMergeLocal {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TaskId,
        [string]$StateDir = ''
    )

    $null = Invoke-FmDeliveryGuard

    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id (allowed: A-Z a-z 0-9 . _ -, not starting with '.')"
    }
    if (-not $StateDir) { $StateDir = (Get-FmSessionPaths).State }
    $metaPath = Get-FmMetaPath -StateDir $StateDir -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw "error: no meta for task $TaskId at $metaPath"
    }

    $project = Get-FmMetaValue -Path $metaPath -Key 'project'
    $mode = Get-FmMetaValue -Path $metaPath -Key 'mode'
    if ($mode -ne 'local-only') {
        # The bash names bin/fm-pr-merge.sh here. This port has no PR-merge
        # command, so it names what a Windows captain can actually do instead of
        # pointing at a script that is not on this platform.
        throw ("error: task $TaskId is mode=$mode, not local-only; a PR task lands through its PR after " +
            'approval (this port has no PR-merge command - merge it with gh-axi, or from a Linux firstmate home)')
    }
    if (-not $project) {
        throw "error: task $TaskId records no project in $metaPath; refusing to guess where to merge"
    }

    $branch = "fm/$TaskId"
    $verdict = Test-FmMergeLocalReady -Project $project -Branch $branch
    if (-not $verdict.Ready) { throw $verdict.Reason }

    $default = $verdict.DefaultBranch
    if (-not $PSCmdlet.ShouldProcess($project, "merge --ff-only $branch into $default")) { return $null }

    $before = Get-FmGitOutput -Directory $project -Arguments @('rev-parse', '--short', $default)
    $merge = Invoke-FmGit -Directory $project -Arguments @('merge', '--ff-only', $branch)
    if (-not $merge.Ok) {
        $detail = ($merge.StdErr, $merge.StdOut | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
        throw "error: fast-forward of $default to $branch failed in $project`: $detail"
    }
    $after = Get-FmGitOutput -Directory $project -Arguments @('rev-parse', '--short', $default)

    [pscustomobject]@{
        Merged        = $true
        TaskId        = $TaskId
        Project       = $project
        Branch        = $branch
        DefaultBranch = $default
        Before        = $before
        After         = $after
        Message       = "merged $branch into local $default ($before -> $after) in $project"
    }
}
