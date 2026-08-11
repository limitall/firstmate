#requires -Version 7.0
# FmMerge.ps1 (public) - the approved local merge for a local-only ship task:
# fast-forward the project's default branch to the crewmate's fm/<id> branch.
# Ported from bin/fm-merge-local.sh.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Fast-forward a project's default branch to a local-only task's fm/<id> branch.
.DESCRIPTION
Refuses unless the task is mode=local-only, the branch exists, the project's own
checkout is on its default branch and clean, and the merge is a clean
fast-forward. A diverged branch is refused with instructions to rebase - never
merged, never forced.
.OUTPUTS
An object with ExitCode (0 merged, 1 refused) and the Messages written out.
#>
function Invoke-FmMergeLocal {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id)

    $messages = [System.Collections.Generic.List[string]]::new()
    function local:Fail([string]$text) {
        $messages.Add($text)
        Write-FmLifecycleStdErr $text
        return [pscustomobject]@{ ExitCode = 1; Messages = @($messages) }
    }

    if (-not (Test-FmLifecycleTaskIdPathSafe -Id $Id)) {
        return (Fail 'usage: Invoke-FmMergeLocal <task-id>')
    }
    $paths = Get-FmLifecyclePaths
    $meta = Join-Path $paths.State "$Id.meta"
    if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) {
        return (Fail "error: no meta for task $Id at $meta")
    }

    $project = Get-FmMetaValue -Path $meta -Key 'project'
    $mode = Get-FmMetaValue -Path $meta -Key 'mode'
    if ($mode -ne 'local-only') {
        return (Fail "error: task $Id is mode=$mode, not local-only; merge PR tasks with the PR merge path after approval")
    }
    if (-not $project -or -not (Test-Path -LiteralPath $project -PathType Container)) {
        return (Fail "error: no project checkout recorded for task $Id at '$project'")
    }

    $branch = "fm/$Id"
    if (-not ((Invoke-FmGit -Directory $project -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$branch")).Ok)) {
        return (Fail "error: branch $branch does not exist in $project")
    }

    $default = Get-FmGitDefaultBranch -Directory $project
    if (-not $default) {
        return (Fail "error: cannot determine default branch for $project; expected origin/HEAD, main, or master")
    }

    $ready = Test-FmMergeProjectCheckoutReady -ProjectPath $project -DefaultBranch $default
    if (-not $ready.Ready) { return (Fail $ready.Reason) }

    if (-not (Test-FmMergeIsFastForward -ProjectPath $project -DefaultBranch $default -Branch $branch)) {
        [void](Fail "REFUSED: $branch is not a fast-forward of $default (it has diverged).")
        return (Fail "Have the crewmate rebase $branch onto $default, then retry.")
    }

    if (-not $PSCmdlet.ShouldProcess("$project ($default)", "fast-forward merge $branch")) {
        return [pscustomobject]@{ ExitCode = 0; Messages = @($messages) }
    }

    $before = Get-FmGitFirstLine (Invoke-FmGit -Directory $project -Arguments @('rev-parse', '--short', $default))
    $merge = Invoke-FmGit -Directory $project -Arguments @('merge', '--ff-only', $branch)
    if ($merge.ExitCode -ne 0) {
        $detail = (($merge.StdErr + $merge.StdOut) -replace "`r`n", "`n").Trim("`n")
        if ($detail) { [void](Fail $detail) }
        return (Fail "error: fast-forward merge of $branch into $default failed in $project")
    }
    $after = Get-FmGitFirstLine (Invoke-FmGit -Directory $project -Arguments @('rev-parse', '--short', $default))

    $line = "merged $branch into local $default ($before -> $after) in $project"
    $messages.Add($line)
    [Console]::Out.WriteLine($line)
    return [pscustomobject]@{ ExitCode = 0; Messages = @($messages) }
}
