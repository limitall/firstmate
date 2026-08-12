# bin/fm-review-diff.ps1 - review a crewmate branch against the authoritative
# base.
#
# Twin: bin/fm-review-diff.sh
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= (URL or number) for an open PR, the compare
# side is ALWAYS a freshly fetched refs/pull/<n>/head by default so review stays
# current after no-mistakes fix rounds push to the PR. A recorded pr_head= is
# only a fallback when fetch fails (stale recorded SHAs must never win over a
# reachable remote PR head). If neither PR head can be resolved, fall back to
# the local branch with a warning. Without pr=, compare the local branch.
#
# CLI:
#   fm-review-diff.ps1 <task-id> [--stat]
#     --stat prints only the stat summary; default prints stat summary plus full
#     diff.
#
# ---------------------------------------------------------------------------
# TWO PATH FORMS, AND BOTH ARE LOAD-BEARING
#
# state/<id>.meta carries worktree= and project= in MSYS form (/f/...) because
# the bash twins write and read the same records during the transition
# (contract 3). git.exe cannot resolve that form - MSYS rewrites it for the bash
# twin, and nothing rewrites it here - so every path handed to git goes through
# ConvertTo-FmNativePath, while every path printed in a DIAGNOSTIC stays exactly
# as the record spells it. A message naming C:\... where the twin names /f/...
# would be a captain-visible divergence for no benefit.
#
# ---------------------------------------------------------------------------
# THE MULTI-VALUE READS ARE NOT THE SAME AS THE LAST-WINS READS
#
# The twin reads worktree= and project= with `grep | cut` and NO `tail -1`, so a
# record holding two worktree= lines yields BOTH values joined by a newline -
# which then fails the directory test and produces a diagnostic naming the
# doubled value. pr= and pr_head= are read with `tail -1`, i.e. last-wins. That
# asymmetry is reproduced rather than tidied: a duplicated worktree= is a
# corrupt record and must not silently pick one.
#
# ---------------------------------------------------------------------------
# EXIT CODES AND STREAMS
#
# The twin runs under `set -e`, so a failing git IS the script's exit status
# (git fetch of the base branch is the case that reaches a caller). Diagnostics
# keep their exact wording, including the `warning: PR head unavailable` line
# that tells a reviewer the diff may lag the open PR. git's own stdout and
# stderr are captured and re-emitted per stream rather than inherited, so their
# interleaving is not preserved and CR is stripped (the port's LF contract).

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

$script:FmGitPath = $null

# Resolved once: Process.Start appends only ".exe" to a bare name, and a
# firstmate script may run from a hook or a pane whose PATH resolution differs
# from the shell's.
function Get-FmGitPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($null -eq $script:FmGitPath) {
        $command = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $command) { return $null }
        $script:FmGitPath = $command.Source
    }
    return $script:FmGitPath
}

# `git -C <dir> ...` with stdout, stderr and exit code kept apart. $Directory is
# converted here so no caller has to remember (see the header).
function Invoke-FmGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string[]]$Argument
    )
    $git = Get-FmGitPath
    if ($null -eq $git) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = 'fm-review-diff.ps1: git: command not found'; Ok = $false }
    }
    return (Invoke-FmTool -FilePath $git -Arguments (@('-C', (ConvertTo-FmNativePath $Directory)) + $Argument))
}

function Write-FmUsage {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    Write-FmErr 'usage: fm-review-diff.sh <task-id> [--stat]'
}

# `$(...)` strips every trailing newline and nothing else.
function Get-FmGitValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Result)
    if (-not $Result.Ok) { return '' }
    return ([string]$Result.StdOut).TrimEnd("`n")
}

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State
    [void](Invoke-FmScript -Name 'fm-guard' -BinDir (Join-Path $context.Root 'bin') -Stream)

    $first = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    if ($first -eq '--help' -or $first -eq '-h') {
        Write-FmUsage
        Exit-FmScript 0
    }

    $id = $first
    if ([string]::IsNullOrEmpty($id)) {
        Write-FmUsage
        Exit-FmScript 1
    }
    $second = if ($fmArgv.Count -ge 2) { [string]$fmArgv[1] } else { '' }
    $statOnly = $false
    if ($second -eq '') {
        # no second argument
    } elseif ($second -eq '--stat') {
        $statOnly = $true
    } else {
        Write-FmUsage
        Exit-FmScript 1
    }
    if ($fmArgv.Count -gt 2) {
        Write-FmUsage
        Exit-FmScript 1
    }

    $meta = Join-Path $state "$id.meta"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        Write-FmErr "error: no meta for task $id at $meta"
        Exit-FmScript 1
    }

    # `grep '^key=' | cut -d= -f2-` with no tail: EVERY match, newline-joined.
    $lines = Get-FmFileLines $meta
    $worktree = (@($lines | Where-Object { $_.StartsWith('worktree=', [System.StringComparison]::Ordinal) } |
                ForEach-Object { $_.Substring(9) }) -join "`n")
    $project = (@($lines | Where-Object { $_.StartsWith('project=', [System.StringComparison]::Ordinal) } |
                ForEach-Object { $_.Substring(8) }) -join "`n")

    if ([string]::IsNullOrEmpty($worktree)) {
        Write-FmErr "error: meta for task $id is missing worktree="
        Exit-FmScript 1
    }
    if ([string]::IsNullOrEmpty($project)) {
        Write-FmErr "error: meta for task $id is missing project="
        Exit-FmScript 1
    }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $worktree))) {
        Write-FmErr "error: worktree for task $id is missing: $worktree"
        Exit-FmScript 1
    }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $project))) {
        Write-FmErr "error: project for task $id is missing: $project"
        Exit-FmScript 1
    }

    # --- default branch (twin: default_branch) -------------------------------
    $default = ''
    $ref = Get-FmGitValue (Invoke-FmGit $project @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD'))
    if (-not [string]::IsNullOrEmpty($ref)) {
        # ${ref#origin/}: one leading occurrence only.
        $default = if ($ref.StartsWith('origin/', [System.StringComparison]::Ordinal)) { $ref.Substring(7) } else { $ref }
    } else {
        foreach ($candidate in @('main', 'master')) {
            if ((Invoke-FmGit $project @('show-ref', '--verify', '--quiet', "refs/heads/$candidate")).Ok) {
                $default = $candidate
                break
            }
        }
    }
    if ([string]::IsNullOrEmpty($default)) {
        Write-FmErr "error: cannot determine default branch for $project; expected origin/HEAD, main, or master"
        Exit-FmScript 1
    }

    # --- the branch under review ---------------------------------------------
    $branch = "fm/$id"
    if (-not (Invoke-FmGit $worktree @('rev-parse', '--verify', '--quiet', "refs/heads/$branch")).Ok) {
        $branch = Get-FmGitValue (Invoke-FmGit $worktree @('symbolic-ref', '--quiet', '--short', 'HEAD'))
        if ([string]::IsNullOrEmpty($branch)) {
            Write-FmErr "error: branch fm/$id does not exist and worktree $worktree is detached"
            Exit-FmScript 1
        }
        if (-not (Invoke-FmGit $worktree @('rev-parse', '--verify', '--quiet', "refs/heads/$branch")).Ok) {
            Write-FmErr "error: branch $branch does not exist in $worktree"
            Exit-FmScript 1
        }
    }

    # --- PR head resolution (twins: pr_number_from_target, fetch_pull_head,
    #     resolve_pr_head) -------------------------------------------------
    $prUrl = Get-FmMetaValue $meta 'pr'
    $prHeadRecorded = Get-FmMetaValue $meta 'pr_head'
    $compareRef = $branch

    if (-not [string]::IsNullOrEmpty($prUrl)) {
        # pr_number_from_target: after the LAST "/pull/", or a leading run of
        # digits, and nothing else parses.
        $number = ''
        $marker = $prUrl.LastIndexOf('/pull/', [System.StringComparison]::Ordinal)
        if ($marker -ge 0) {
            $number = $prUrl.Substring($marker + 6)
        } elseif ([char]::IsAsciiDigit($prUrl[0])) {
            $number = $prUrl
        }
        if (-not [string]::IsNullOrEmpty($number)) {
            # ${n%%[!0-9]*}: the leading digit run, which may be empty.
            $digits = [regex]::Match($number, '\A[0-9]*').Value
            $number = $digits
        }

        $resolved = ''
        if (-not [string]::IsNullOrEmpty($number)) {
            # Fetch into a private ref so a later base-branch fetch cannot
            # clobber the compare tip via FETCH_HEAD, and so we never review a
            # stale local object.
            if ((Invoke-FmGit $worktree @('remote', 'get-url', 'origin')).Ok -and
                (Invoke-FmGit $worktree @('fetch', '--quiet', 'origin',
                        "+refs/pull/$number/head:refs/fm-review/pull/$number/head")).Ok) {
                $resolved = Get-FmGitValue (Invoke-FmGit $worktree @('rev-parse', '--verify',
                        "refs/fm-review/pull/$number/head^{commit}"))
            }
        }
        # Offline / unreachable remote: recorded pr_head is better than the local
        # branch, but never preferred over a successful pull-head fetch above.
        if ([string]::IsNullOrEmpty($resolved) -and -not [string]::IsNullOrEmpty($prHeadRecorded) -and
            (Invoke-FmGit $worktree @('cat-file', '-e', "$prHeadRecorded^{commit}")).Ok) {
            $resolved = $prHeadRecorded
        }
        if (-not [string]::IsNullOrEmpty($resolved)) {
            $compareRef = $resolved
        } else {
            Write-FmErr "warning: PR head unavailable; diff may lag the open PR (using local branch $branch)"
        }
    }

    # --- base ----------------------------------------------------------------
    $base = $default
    if ((Invoke-FmGit $project @('remote', 'get-url', 'origin')).Ok) {
        # Update the remote-tracking ref itself; a bare single-branch fetch can
        # leave origin/<default> stale on some Git versions and only refresh
        # FETCH_HEAD.
        $fetch = Invoke-FmGit $worktree @('fetch', 'origin', "+refs/heads/${default}:refs/remotes/origin/$default", '--quiet')
        if (-not $fetch.Ok) {
            # `set -e`: the twin aborts here with git's own status.
            if (-not [string]::IsNullOrEmpty($fetch.StdErr)) { [Console]::Error.Write($fetch.StdErr) }
            Exit-FmScript $fetch.ExitCode
        }
        $base = "origin/$default"
    }

    if (-not (Invoke-FmGit $worktree @('rev-parse', '--verify', '--quiet', "$base^{commit}")).Ok) {
        Write-FmErr "error: base $base does not exist in $worktree"
        Exit-FmScript 1
    }
    if (-not (Invoke-FmGit $worktree @('rev-parse', '--verify', '--quiet', "$compareRef^{commit}")).Ok) {
        Write-FmErr "error: compare ref $compareRef does not resolve in $worktree"
        Exit-FmScript 1
    }

    Write-FmOut "diff base: $base"
    if ((Invoke-FmGit $worktree @('diff', '--quiet', "$base...$compareRef", '--')).Ok) {
        Write-FmOut "no changes vs $base"
        Exit-FmScript 0
    }

    $stat = Invoke-FmGit $worktree @('diff', '--stat', "$base...$compareRef", '--')
    if (-not [string]::IsNullOrEmpty($stat.StdOut)) { Write-FmRaw $stat.StdOut }
    if (-not [string]::IsNullOrEmpty($stat.StdErr)) { [Console]::Error.Write($stat.StdErr) }
    if (-not $statOnly) {
        Write-FmOut ''
        $full = Invoke-FmGit $worktree @('diff', "$base...$compareRef", '--')
        if (-not [string]::IsNullOrEmpty($full.StdOut)) { Write-FmRaw $full.StdOut }
        if (-not [string]::IsNullOrEmpty($full.StdErr)) { [Console]::Error.Write($full.StdErr) }
        Exit-FmScript $full.ExitCode
    }
    Exit-FmScript $stat.ExitCode
}
