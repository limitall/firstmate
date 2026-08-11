#requires -Version 7.0
# FmMerge.ps1 - guards for the approved local merge, ported from
# bin/fm-merge-local.sh.
#
# This is firstmate's merge gate-action: the captain's merge authority applied
# locally instead of through a PR. It is the one sanctioned exception to "never
# run state-changing git in a project", and it is deliberately narrow - it runs
# only for a mode=local-only task, only after approval, and only as a clean
# fast-forward. A diverged branch is refused, never merged, never forced.

Set-StrictMode -Version Latest

# Is the project's own checkout in a state where a fast-forward lands
# predictably? It must be ON its default branch and clean - firstmate never
# writes there otherwise, and a merge into a dirty or detached checkout could
# entangle work that is not ours.
function Test-FmMergeProjectCheckoutReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$DefaultBranch
    )
    $current = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $ProjectPath 'symbolic-ref' '--short' 'HEAD')
    if ($current -ne $DefaultBranch) {
        return [pscustomobject]@{
            Ready  = $false
            Reason = "error: $ProjectPath is on '$current', expected default branch '$DefaultBranch'; cannot merge safely"
        }
    }
    $status = Invoke-FmGit -RepoPath $ProjectPath 'status' '--porcelain'
    if ($status.ExitCode -ne 0) {
        return [pscustomobject]@{
            Ready  = $false
            Reason = "error: cannot read the working tree state of $ProjectPath; refusing to merge into it"
        }
    }
    $firstLine = @(($status.StdOut -replace "`r`n", "`n").Split("`n") | Where-Object { $_ -ne '' } | Select-Object -First 1)
    if ($firstLine.Count -gt 0) {
        return [pscustomobject]@{
            Ready  = $false
            Reason = "error: $ProjectPath has a dirty working tree; refusing to merge into it"
        }
    }
    return [pscustomobject]@{ Ready = $true; Reason = '' }
}

# Clean fast-forward only: the default branch must be an ancestor of the task
# branch. A diverged branch is refused - the crewmate rebases, firstmate never
# rewrites or force-merges a project's history.
function Test-FmMergeIsFastForward {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$Branch
    )
    return (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $ProjectPath 'merge-base' '--is-ancestor' $DefaultBranch $Branch))
}
