#requires -Version 7.0
<#
    Public/FmTangle.ps1 - the worktree-tangle detector, ported from
    bin/fm-tangle-lib.sh.

    THIS GUARD WAS DEAD ON ARRIVAL WITHOUT IT. Public/FmGuard.ps1 already carries
    the whole alarm - the banner, the read-only wording, the restore command -
    and reaches for `Get-FmPrimaryTangleBranch` through its seam. Private/
    FmBootstrap.ps1 asks for the same name. Nothing in the module published it,
    so the seam's documented degradation ("no worktree-tangle alarm") was the
    only behaviour anyone ever got.

    WHAT IT DETECTS, AND NOTHING ELSE. Firstmate is a pooled git repo of itself:
    crewmate worktrees and secondmate homes are linked worktrees of the same
    repository, while the PRIMARY checkout is a normal checkout on a real branch.
    The failure this names is a crewmate spawned to work on firstmate ITSELF
    branching and committing in the primary instead of its own disposable
    worktree, stranding the primary on a feature branch. Every legitimate state -
    the primary on its default branch, a detached HEAD, a linked worktree, a
    directory that is not a checkout - is silent.

    ONE DIVERGENCE FROM THE BASH RULE, AND WHY. bin/fm-tangle-lib.sh relies on
    detached HEAD to keep linked worktrees quiet, because that is how they sit in
    the bash fleet. This port's crewmates work on NAMED branches in linked
    worktrees (the brief tells them to branch), so the detached-HEAD test alone
    would fire the alarm inside every crewmate. The linked-worktree test below
    (git-dir differs from git-common-dir) is what keeps it accurate here, and it
    is the same test FmBootstrap's own fallback already used - so publishing this
    owner cannot make bootstrap noisier than it was without one.

    Reading git belongs to the worktree area: Invoke-FmGit / Get-FmGitOutput run
    git through an argv array with no shell, and Get-FmGitDefaultBranch already
    owns "what is this repo's default branch". This file adds the tangle rule on
    top of them rather than a second way to ask git anything.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FmDefaultBranch {
    <#
        .SYNOPSIS
        The default branch of the repository at <Root>, or '' when git cannot
        say.

        .DESCRIPTION
        The name the guard and bootstrap seams both ask for, on top of the
        worktree area's Get-FmGitDefaultBranch (origin/HEAD, else the first of
        main/master that exists locally - the bash default_branch order).

        Positional so `Invoke-FmSeam -Arguments @($root)` binds, and named
        -Root so `& $shared -Root $Root` binds: both call styles are live in the
        module today.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Root)

    if ([string]::IsNullOrEmpty($Root)) { return '' }
    try { return [string](Get-FmGitDefaultBranch -Directory $Root) } catch { return '' }
}

function Get-FmPrimaryTangleBranch {
    <#
        .SYNOPSIS
        The offending branch when the checkout at <Root> is tangled, else ''.

        .DESCRIPTION
        Tangled means: a real work tree, NOT a linked worktree, on a NAMED branch
        that is not its default branch. Anything else returns '' and the guard
        stays quiet.

        Returns a string rather than throwing, because its only caller is an
        alarm: a guard that cannot read git must say nothing, not block the
        operation it was guarding.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Root)

    # An empty or missing root is answered, never thrown: the only caller is an
    # alarm, and a guard that throws is a guard that blocks.
    if ([string]::IsNullOrEmpty($Root)) { return '' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '' }

    if ((Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--is-inside-work-tree')) -ne 'true') { return '' }

    # A linked worktree is a crewmate or secondmate checkout, never the primary.
    $gitDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--absolute-git-dir')
    $commonDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $gitDir -or -not $commonDir) { return '' }
    if (-not (Test-FmPathEqual -Left $gitDir -Right $commonDir)) { return '' }

    # Detached HEAD prints nothing here, which is one of the silent states.
    $current = Get-FmGitOutput -Directory $Root -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if ([string]::IsNullOrEmpty($current)) { return '' }

    $default = Get-FmDefaultBranch -Root $Root
    if ([string]::IsNullOrEmpty($default)) { return '' }
    if ($current -eq $default) { return '' }
    return $current
}
