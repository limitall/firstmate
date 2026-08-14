#requires -Version 7.0
# FmGnhf.ps1 - the guards that make gnhf safe to run from firstmate, ported from
# docs/fm-gnhf.reference.sh.
#
# WHY THESE EXIST, AND WHY THEY ARE HERE RATHER THAN IN A CONFIG FILE.
# gnhf's ~/.gnhf/config.yml was written with worktree: true, push: false and
# maxIterations: 40, and gnhf ignored every line of it. The first real run on the
# Linux side checked its own branch out in the PRIMARY checkout - the one
# firstmate's crew uses as reference - which is the single thing those settings
# existed to prevent. docs/GNHF-GUARDS.md records the measurement.
#
# So every guard is applied on the COMMAND LINE, where it was proven to take
# effect, and the one that matters is verified AFTER the run rather than trusted:
# the primary checkout's branch and commit are recorded before, compared after,
# and a mismatch is a hard failure carrying the exact restore command.
#
# THE SECOND DEFECT IS ALSO PORTED, AS A LESSON RATHER THAN AS CODE. The bash
# original refused when the tree was completely CLEAN, because `grep` exits 1 on
# no match and `set -euo pipefail` turned that into a silent exit that looked
# exactly like a refusal. PowerShell has no pipefail, but it has the same trap in
# a different shape: an empty pipeline yields $null, and $null.Count is not 0
# under StrictMode - it throws. Every count here is forced to an array first, and
# tests/FmGnhf.Tests.ps1 asserts the clean-tree case explicitly, because that is
# the normal case and it is the one that broke.

Set-StrictMode -Version Latest

# Lines of `git status --porcelain` that count as dirty. gnhf's own .gnhf
# scratch directory is ignored: it is gnhf's, not the project's, and its presence
# is not a reason to refuse a run.
function Get-FmGnhfDirtyLine {
    [OutputType([string[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $raw = @(& git -C $RepoPath status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "error: git status failed in '$RepoPath': $($raw -join ' ')"
    }
    # Forced to an array BEFORE anything reads .Count - see the header note about
    # the clean-tree trap. A clean tree must produce an empty array, never $null.
    @($raw |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Where-Object { [string]$_ -notmatch '^\?\?\s+\.gnhf' } |
            ForEach-Object { [string]$_ })
}

# The pair that the after-run guard compares against. Recorded before the run and
# again after; any difference means gnhf moved the primary checkout.
function Get-FmGnhfCheckoutState {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $branch = (& git -C $RepoPath branch --show-current 2>&1 | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "error: cannot read branch in '$RepoPath'" }
    $head = (& git -C $RepoPath rev-parse HEAD 2>&1 | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "error: cannot read HEAD in '$RepoPath'" }

    [pscustomobject]@{
        # A detached HEAD reports an empty branch; that is a real state, not a
        # failure, and it still compares correctly against itself.
        Branch = [string]$branch
        Head   = [string]$head
        Short  = if ([string]$head) { ([string]$head).Substring(0, [Math]::Min(9, ([string]$head).Length)) } else { '' }
    }
}

# The external call, isolated so the suite can exercise every guard - including
# the one that only fires when gnhf misbehaves - without running gnhf for real.
# Returns the exit code; output is left on the host's streams deliberately, so a
# long run is visible while it happens rather than buffered to the end.
function Invoke-FmGnhfProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The public cmdlet owns the ShouldProcess gate; this is the raw invocation it guards.')]
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Objective,
        [Parameter(Mandatory)][int]$MaxIterations,
        [string[]]$ExtraArgument = @()
    )

    # --worktree and --max-iterations are ALWAYS passed and are not caller
    # overridable, and no push flag is ever passed. That is the whole point of
    # this wrapper: the config file proved decorative, the command line did not.
    $arguments = @($Objective, '--worktree', '--max-iterations', [string]$MaxIterations) + $ExtraArgument

    $previous = Get-Location
    try {
        # gnhf resolves the repo from the working directory, so this runs IN the
        # repo rather than passing a path it does not accept.
        Set-Location -LiteralPath $RepoPath
        & gnhf @arguments
        return [int]$LASTEXITCODE
    } finally {
        Set-Location -LiteralPath $previous
    }
}
