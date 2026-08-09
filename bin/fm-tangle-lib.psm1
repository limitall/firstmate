# fm-tangle-lib.psm1 - worktree-tangle guard for the firstmate-on-itself case.
# Twin: bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# Get-FmPrimaryTangleBranch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent
# for every legitimate state - the primary on its default branch, and detached
# HEAD, which is how every linked worktree and secondmate home legitimately
# sits on the default branch. Detached HEAD on the default is fine; a feature
# branch in a primary checkout is the alarm.
#
# bash -> PowerShell:
#   fm_default_branch         -> Get-FmDefaultBranch
#   fm_primary_tangle_branch  -> Get-FmPrimaryTangleBranch
#
# Both bash functions print a name and return 0, or print nothing and return 1.
# The PowerShell twins return the name or $null - one value carrying both
# halves, which is why callers here read `if ($null -ne $branch)` where the
# bash reads `if branch=$(...)`.
#
# Two Windows details this file exists to get right:
#   - git.exe is called through Invoke-FmTool, not by re-reading .git files.
#     The layout of a linked worktree's .git (a `gitdir:` pointer file) versus
#     a plain checkout's .git directory is git's business, and hand-parsing it
#     is how a guard starts disagreeing with the tool it is guarding.
#   - git on Windows accepts a native drive path for -C but not an MSYS one,
#     and the durable records this guard is fed from carry MSYS form. Every
#     directory therefore goes through ConvertTo-FmNativePath first. The branch
#     NAMES that come back are plain refs and need no conversion.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

<#
.SYNOPSIS
Run git in a directory, returning Invoke-FmTool's result hashtable.
.DESCRIPTION
The `git -C "$dir" ... 2>/dev/null` twin, in one place so the four call sites
below cannot drift. The full result comes back rather than just stdout,
because two of those call sites answer by EXIT CODE alone (`show-ref
--verify --quiet` prints nothing on success) and collapsing that into a string
would make success indistinguishable from failure.

Three behaviors are load-bearing:
  - A missing git is "not a repo", not an exception. Invoke-FmTool lets
    Process.Start throw for an executable that is not on PATH, and with
    $ErrorActionPreference = 'Stop' that would abort a caller whose bash twin
    merely answered "no". The Test-FmCommand guard keeps the answer shaped
    like the bash one, spelled as a 127 result so callers read one field.
  - git on Windows accepts a native drive path for -C but not an MSYS one.
  - Trailing newlines are stripped from Value the way `$(...)` strips them,
    and Invoke-FmTool has already removed CR, so a native git.exe emitting
    CRLF cannot leak a stray \r into a branch-name comparison - the exact
    failure the jq CRLF shim was written for during the Windows bash port.
#>
function Invoke-FmTangleGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string[]]$GitArguments
    )
    if (-not (Test-FmCommand 'git')) {
        return @{ ExitCode = 127; Ok = $false; Value = '' }
    }
    $native = ConvertTo-FmNativePath $Directory
    $result = Invoke-FmTool -FilePath 'git' -Arguments (@('-C', $native) + $GitArguments)
    return @{ ExitCode = $result.ExitCode; Ok = $result.Ok; Value = $result.StdOut.TrimEnd("`n") }
}

<#
.SYNOPSIS
The default branch name of the git repo at a directory, or $null.
.DESCRIPTION
Prefers origin/HEAD - the remote's own declaration - and falls back to a local
main, then master. The fallback order matters for a fixture repo with no
remote, which is most of the test tree.
#>
function Get-FmDefaultBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $head = Invoke-FmTangleGit -Directory $Directory `
        -GitArguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    # The bash tests the captured TEXT, not the exit code, so a command that
    # succeeded with empty output falls through to the local-branch probe here
    # exactly as it does there.
    $ref = if ($head.Ok) { $head.Value } else { '' }
    if (-not [string]::IsNullOrEmpty($ref)) {
        # bash ${ref#origin/}: strip the prefix only when it is actually there.
        if ($ref.StartsWith('origin/')) { return $ref.Substring('origin/'.Length) }
        return $ref
    }

    foreach ($branch in @('main', 'master')) {
        # show-ref --verify --quiet prints nothing and answers by exit code
        # alone, so success here is the whole result - an empty Value from a
        # command that SUCCEEDED is not the same as a failure.
        $probe = Invoke-FmTangleGit -Directory $Directory `
            -GitArguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($probe.Ok) { return $branch }
    }
    return $null
}

<#
.SYNOPSIS
The offending branch name when the checkout at a root is tangled, else $null.
.DESCRIPTION
Returns a name ONLY for a named, non-default branch in a real work tree. Every
healthy state - not a git work tree at all, detached HEAD, or already on the
default branch - returns $null, because detached HEAD is exactly how linked
worktrees and secondmate homes legitimately sit and they must never trip this.
#>
function Get-FmPrimaryTangleBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)

    $inside = Invoke-FmTangleGit -Directory $Root -GitArguments @('rev-parse', '--is-inside-work-tree')
    if (-not $inside.Ok) { return $null }

    # symbolic-ref --quiet exits non-zero on a detached HEAD, which is why a
    # detached worktree is silent here rather than being reported as tangled.
    $head = Invoke-FmTangleGit -Directory $Root -GitArguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $current = if ($head.Ok) { $head.Value } else { '' }
    if ([string]::IsNullOrEmpty($current)) { return $null }

    $default = Get-FmDefaultBranch -Directory $Root
    if ([string]::IsNullOrEmpty($default)) { return $null }
    if ($current -eq $default) { return $null }
    return $current
}

Export-ModuleMember -Function @(
    'Get-FmDefaultBranch',
    'Get-FmPrimaryTangleBranch'
)
