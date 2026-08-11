#requires -Version 7.0
# FmTeardown.ps1 - the landed-work test and the rest of teardown's safety gate,
# ported from bin/fm-teardown.sh.
#
# THE RULE THIS FILE EXISTS FOR (AGENTS.md hard rule 3): firstmate never tears
# down unlanded work. Cleanup hard-resets and removes the worktree and kills its
# processes, so every refusal below is a stop-and-investigate result, never an
# obstacle to bypass. Only an explicit -Force - which means the captain has
# explicitly authorized discarding that work - skips these checks.
#
# Work has LANDED when:
#   * it is committed AND reachable from some remote-tracking branch (a fork
#     counts as a remote, so upstream-contribution PRs satisfy this in any
#     mode), OR
#   * its PR is merged and GitHub reports a PR head that contains the current
#     local work (directly, or by patch-id for commits that only exist locally),
#     OR
#   * its content is already present in the up-to-date default branch - the
#     common squash-merge-then-delete-branch flow, where the branch's own
#     commits live nowhere on a remote yet the change is fully in main.
# local-only tasks additionally accept work merged into the LOCAL default
# branch, for the common case where there is no remote at all.
# Uncommitted changes are NEVER landed.
# A gh lookup error falls back to the content check; if that is also
# inconclusive, teardown refuses rather than risk discarding unlanded work.
#
# Every inconclusive answer refuses. That asymmetry is the whole design: a false
# refusal costs a rerun, a false success destroys work that exists nowhere else.

Set-StrictMode -Version Latest

# Distinct refusal reasons, so the caller can retry after clearing a stale lock
# instead of treating a blocked inspection as a verdict.
$script:FmTeardownSafetyOk = 0
$script:FmTeardownSafetyRefused = 1
$script:FmTeardownSafetyLockBlocked = 3

function Get-FmTeardownStaleLockAgeSeconds {
    if ($env:FM_STALE_WORKTREE_LOCK_AGE_SECS -match '^[0-9]+$') { return [int]$env:FM_STALE_WORKTREE_LOCK_AGE_SECS }
    return 30
}

function Get-FmTeardownLockRetryCount {
    if ($env:FM_TREEHOUSE_RETURN_LOCK_RETRIES -match '^[0-9]+$') { return [int]$env:FM_TREEHOUSE_RETURN_LOCK_RETRIES }
    return 3
}

function Get-FmTeardownLockRetryWaitSeconds {
    foreach ($candidate in @($env:FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS, $env:FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS)) {
        if ($null -eq $candidate -or $candidate -eq '') { continue }
        if ($candidate -match '^([0-9]+(\.[0-9]*)?|\.[0-9]+)$') { return [double]$candidate }
        Write-FmLifecycleStdErr "teardown: invalid treehouse return lock retry wait '$candidate'; using 1s"
        return 1
    }
    return 1
}

# The project's default branch: origin/HEAD when it is set, else main, else
# master. Returns '' when none can be determined - the caller then refuses.
function Get-FmLifecycleDefaultBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RepoPath)
    if (-not $RepoPath) { return '' }
    $ref = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $RepoPath 'symbolic-ref' '--quiet' '--short' 'refs/remotes/origin/HEAD')
    if ($ref) { return ($ref -replace '^origin/', '') }
    foreach ($branch in @('main', 'master')) {
        $result = Invoke-FmGit -RepoPath $RepoPath 'show-ref' '--verify' '--quiet' "refs/heads/$branch"
        if (Test-FmGitSucceeded $result) { return $branch }
    }
    return ''
}

# Resolve a PR number for a worktree branch through gh-axi. Any failure means
# "no PR found" (fail-safe: the caller falls through to the content check).
function Get-FmTeardownPrNumberFromBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch
    )
    if (-not $Branch -or $Branch -eq 'HEAD') { return '' }
    $result = Invoke-FmLifecycleProcess -FilePath 'gh-axi' -Arguments @('pr', 'list', '--state', 'all', '--head', $Branch, '--limit', '1') -WorkingDirectory $WorktreePath
    if ($result.ExitCode -ne 0) { return '' }
    foreach ($line in ($result.StdOut -replace "`r`n", "`n").Split("`n")) {
        if ($line -match '^\s*([0-9]+),') { return $Matches[1] }
    }
    return ''
}

# A recorded pr= is either a full URL or a bare number.
function Get-FmTeardownPrNumberFromTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Target)
    if (-not $Target) { return '' }
    if ($Target -match '/pull/([0-9]+)') { return $Matches[1] }
    if ($Target -match '^([0-9]+)') { return $Matches[1] }
    return ''
}

# Make sure a commit object is present locally, fetching refs/pull/<n>/head when
# the PR branch itself was already deleted.
function Confirm-FmTeardownCommitObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Commit
    )
    if (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'cat-file' '-e' "$Commit^{commit}")) { return $true }
    $number = Get-FmTeardownPrNumberFromTarget -Target $Target
    if (-not $number) { return $false }
    if (-not (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'remote' 'get-url' 'origin'))) { return $false }
    if (-not (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'fetch' '--quiet' 'origin' "refs/pull/$number/head"))) { return $false }
    return (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'cat-file' '-e' "$Commit^{commit}"))
}

function Get-FmTeardownPatchId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$Commit
    )
    $show = Invoke-FmGit -RepoPath $WorktreePath 'show' '--pretty=medium' '--no-ext-diff' $Commit
    if ($show.ExitCode -ne 0) { return '' }
    # `git patch-id` reads the diff on stdin; run it with the show output piped in.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in @('-C', $WorktreePath, 'patch-id', '--stable')) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { return '' }
    try {
        $proc.StandardInput.Write($show.StdOut)
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEnd()
        [void]$proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) { return '' }
        $first = ($out -replace "`r`n", "`n").Split("`n")[0].Trim()
        if ($first -eq '') { return '' }
        return ($first -split '\s+')[0]
    } catch {
        return ''
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

# Are the worktree's not-on-any-remote commits all present in the PR head by
# patch identity? This is what recognizes a rebase-merge: the local commits are
# gone from every remote ref, but the same patches are in the merged head.
function Test-FmTeardownUnpushedPatchesInPrHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$PrHead
    )
    $current = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--verify' 'HEAD')
    if (-not $current) { return $false }
    $baseResult = Invoke-FmGit -RepoPath $WorktreePath 'merge-base' $current $PrHead
    if ($baseResult.ExitCode -ne 0) { return $false }
    $base = Get-FmGitOutputLine $baseResult
    if (-not $base) { return $false }

    $prCommits = Invoke-FmGit -RepoPath $WorktreePath 'log' '--format=%H' "$base..$PrHead" '--'
    if ($prCommits.ExitCode -ne 0) { return $false }
    $prPatchIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($commit in ($prCommits.StdOut -replace "`r`n", "`n").Split("`n")) {
        if ($commit.Trim() -eq '') { continue }
        $patchId = Get-FmTeardownPatchId -WorktreePath $WorktreePath -Commit $commit.Trim()
        if ($patchId) { [void]$prPatchIds.Add($patchId) }
    }
    if ($prPatchIds.Count -eq 0) { return $false }

    $unpushed = Invoke-FmGit -RepoPath $WorktreePath 'log' '--format=%H' 'HEAD' '--not' '--remotes' '--'
    if ($unpushed.ExitCode -ne 0) { return $false }
    $unpushedCommits = @(($unpushed.StdOut -replace "`r`n", "`n").Split("`n") | Where-Object { $_.Trim() -ne '' })
    if ($unpushedCommits.Count -eq 0) { return $false }
    foreach ($commit in $unpushedCommits) {
        $patchId = Get-FmTeardownPatchId -WorktreePath $WorktreePath -Commit $commit.Trim()
        if (-not $patchId) { return $false }
        if (-not $prPatchIds.Contains($patchId)) { return $false }
    }
    return $true
}

# Is the worktree's PR merged, with the local work contained in that PR head?
# Resolves the PR from the recorded pr= first, then from the branch name, so a
# missing pr= (a yolo-authorized merge on a repo with no PR CI, where the usual
# "checks green" trigger never fires) never by itself causes a false refusal.
# Any gh error, unmerged state, or uncontained work returns false and the caller
# falls back to the content check.
function Test-FmTeardownPrIsMerged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrUrl
    )
    $target = if ($PrUrl) { $PrUrl } else { Get-FmTeardownPrNumberFromBranch -WorktreePath $WorktreePath -Branch $Branch }
    if (-not $target) { return $false }
    $view = Invoke-FmLifecycleProcess -FilePath 'gh' -Arguments @('pr', 'view', $target, '--json', 'state,headRefOid', '-q', '.state + "\t" + .headRefOid') -WorkingDirectory $WorktreePath
    if ($view.ExitCode -ne 0) { return $false }
    $line = ($view.StdOut -replace "`r`n", "`n").Trim("`n")
    if ($line -eq '') { return $false }
    $line = $line.Split("`n")[0]
    $parts = $line.Split("`t", 2)
    if ($parts.Count -ne 2) { return $false }
    $state = $parts[0]
    $head = $parts[1].Trim()
    if ($state -ne 'MERGED' -and $state -ne 'merged') { return $false }
    if (-not $head) { return $false }
    if (-not (Confirm-FmTeardownCommitObject -WorktreePath $WorktreePath -Target $target -Commit $head)) { return $false }
    $current = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--verify' 'HEAD')
    if (-not $current) { return $false }
    if (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'merge-base' '--is-ancestor' $current $head)) { return $true }
    return (Test-FmTeardownUnpushedPatchesInPrHead -WorktreePath $WorktreePath -PrHead $head)
}

# Is the branch's content already present in the up-to-date default branch?
# Fetches first, then 3-way merges the default branch with HEAD: when HEAD
# introduces nothing the default branch does not already contain (its change
# landed via squash) the merged tree equals the default branch's tree. This
# isolates branch-only changes, so unrelated commits the default branch gained
# past the merge-base do not count as "added". False when inconclusive (no
# default ref, or a merge conflict), so the caller refuses rather than guesses.
function Test-FmTeardownContentInDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectPath
    )
    $name = Get-FmLifecycleDefaultBranch -RepoPath $ProjectPath
    if (-not $name) { return $false }
    $ref = ''
    if (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'remote' 'get-url' 'origin')) {
        if (-not (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'fetch' '--quiet' 'origin' "+refs/heads/${name}:refs/remotes/origin/$name"))) { return $false }
        $ref = "refs/remotes/origin/$name"
    } elseif (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--quiet' '--verify' "refs/heads/$name")) {
        $ref = "refs/heads/$name"
    } else {
        return $false
    }
    $defaultTree = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--quiet' '--verify' "$ref^{tree}")
    if (-not $defaultTree) { return $false }
    $mergeResult = Invoke-FmGit -RepoPath $WorktreePath 'merge-tree' '--write-tree' $ref 'HEAD'
    if ($mergeResult.ExitCode -ne 0) { return $false }
    $mergedTree = Get-FmGitOutputLine $mergeResult
    if (-not $mergedTree) { return $false }
    return ($mergedTree -eq $defaultTree)
}

<#
.SYNOPSIS
Has the worktree's committed work actually LANDED, though its commits are not
reachable from any remote-tracking branch?
.DESCRIPTION
True when a merged PR proves the current local work is contained in the PR head,
OR the content is already in the default branch (the fallback that also covers
the no-PR and gh-error paths). False only for genuinely unlanded work - and
false is what makes teardown refuse.
#>
function Test-FmWorkIsLanded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Branch,
        [Parameter()][AllowEmptyString()][string]$PrUrl = ''
    )
    if (Test-FmTeardownPrIsMerged -WorktreePath $WorktreePath -Branch $Branch -PrUrl $PrUrl) { return $true }
    return (Test-FmTeardownContentInDefault -WorktreePath $WorktreePath -ProjectPath $ProjectPath)
}

# Absolute path of a worktree's git index lock, or '' when it cannot be resolved.
function Get-FmTeardownWorktreeLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return '' }
    $lock = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $Path 'rev-parse' '--git-path' 'index.lock')
    if (-not $lock) { return '' }
    if ([System.IO.Path]::IsPathRooted($lock)) { return $lock }
    return (Join-Path (Resolve-Path -LiteralPath $Path).ProviderPath $lock)
}

# A killed crew process can leave an index.lock behind. That lock is usually
# transient - the dying process finishes within seconds - and must never be
# force-deleted while a live git process might still own it. The fix is
# patience, not rm: a lock is provably stale only when it is older than the age
# threshold and no live process holds it. Anything unprovable is treated as NOT
# stale (fail safe) and left in place.
function Test-FmTeardownLockProvablyStale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [Parameter(Mandatory)][int]$AgeSeconds
    )
    $item = Get-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if ($item.LinkTarget) { return $false }
    $age = (Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc
    if ($age.TotalSeconds -lt $AgeSeconds) { return $false }
    # A live holder is proof it is NOT stale. Windows answers this by simply
    # refusing an exclusive open on a file another process still holds; on Linux
    # an advisory-locked file opens fine, so this check can only ever add
    # refusals there, never remove them.
    # WINDOWS-UNVERIFIED: the exclusive-open probe is the Windows-specific half
    # and cannot be exercised on this Linux box.
    try {
        $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
    } catch [System.IO.IOException] {
        return $false
    } catch {
        return $false
    }
    return $true
}

# The safety-check half of the lock recovery: wait once, and clear the lock only
# when it is provably stale, so the checks can be re-run before any destructive
# return. Returns $true when the checks may be retried.
function Clear-FmTeardownStaleSafetyLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorktreePath)
    $lock = Get-FmTeardownWorktreeLockPath -Path $WorktreePath
    if (-not $lock -or -not (Test-Path -LiteralPath $lock)) { return $true }
    $waitSecs = Get-FmTeardownLockRetryWaitSeconds
    $ageSecs = Get-FmTeardownStaleLockAgeSeconds
    Write-FmLifecycleStdErr "teardown: worktree safety check blocked by git lock $lock; waiting ${waitSecs}s and retrying (owning process may be exiting)"
    Start-Sleep -Seconds $waitSecs
    if (-not (Test-Path -LiteralPath $lock)) {
        Write-FmLifecycleStdErr 'teardown: worktree safety check lock cleared on its own; retrying safety checks'
        return $true
    }
    if (Test-FmTeardownLockProvablyStale -LockPath $lock -AgeSeconds $ageSecs) {
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        Write-FmLifecycleStdErr "teardown: removed provably-stale git lock $lock (age >= ${ageSecs}s, no live holder) and retrying worktree safety checks"
        return $true
    }
    Write-FmLifecycleStdErr "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place"
    return $false
}

# --- per-task lifecycle lock ------------------------------------------------
# A directory plus a `pid` file, the same on-disk shape bin/fm-wake-lib.sh's
# fm_lock_try_acquire creates, so the two implementations recognise each other's
# held lock. Directory creation is atomic on both platforms. The bash library's
# full steal protocol (owner symlinks, mid-acquire freshness) belongs to the
# wake-queue area; this narrower port refuses while the recorded owner is alive
# and reclaims an ownerless lock, which is what teardown's "another lifecycle
# action is already running" guard needs.

function Test-FmTeardownLockOwnerAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    $pidFile = Join-Path $LockPath 'pid'
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return $false }
    $raw = ''
    try { $raw = ([System.IO.File]::ReadAllText($pidFile)).Trim() } catch { return $true }
    if ($raw -notmatch '^[0-9]+$') { return $false }
    return ($null -ne (Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue))
}

function Enter-FmTeardownLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    $pidFile = Join-Path $LockPath 'pid'
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $LockPath))
            [void][System.IO.Directory]::CreateDirectory($LockPath)
            # CreateNew is the atomic primitive: exactly one racing acquirer can
            # create the pid file, so the lock cannot be held twice.
            $stream = [System.IO.File]::Open($pidFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("$PID`n")
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
            return $true
        } catch [System.IO.IOException] {
            if (Test-FmTeardownLockOwnerAlive -LockPath $LockPath) { return $false }
            # Ownerless: the previous holder died without releasing. Reclaim once.
            Remove-Item -LiteralPath $LockPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            return $false
        }
    }
    return $false
}

function Exit-FmTeardownLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)
    $pidFile = Join-Path $LockPath 'pid'
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return }
    $raw = ''
    try { $raw = ([System.IO.File]::ReadAllText($pidFile)).Trim() } catch { return }
    if ($raw -ne "$PID") { return }
    Remove-Item -LiteralPath $LockPath -Recurse -Force -ErrorAction SilentlyContinue
}

# --- pre-teardown run conclusion (Fix 1 in the bash header) -----------------
# A ship task's worktree can be torn down while its no-mistakes run is still
# PARKED at a gate with no worker left to ever answer it - the run then holds a
# fleet slot indefinitely. A run with an autonomous step still under way is left
# alone: no-mistakes drives those against its own clone, not this worktree, so
# removing the worktree does not orphan them. The run is attributed to THIS task
# only when its branch AND code identity both match this worktree - never a guess.
function Stop-FmTaskNoMistakesRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$WorktreePath)
    if (-not $WorktreePath -or -not (Test-Path -LiteralPath $WorktreePath -PathType Container)) { return }
    if (-not (Get-Command -Name 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue)) { return }
    $timeout = 10
    if ($env:FM_TEARDOWN_NM_TIMEOUT -match '^[0-9]+$') { $timeout = [int]$env:FM_TEARDOWN_NM_TIMEOUT }

    $status = Invoke-FmNoMistakes -WorktreePath $WorktreePath -TimeoutSeconds $timeout -Arguments @('axi', 'status')
    $runId = Get-FmTaskParkedRunId -WorktreePath $WorktreePath -StatusOutput $status
    if (-not $runId) { return }
    Write-FmLifecycleStdErr "teardown: concluding this task's parked no-mistakes run $runId before removing its worktree"
    [void](Invoke-FmNoMistakes -WorktreePath $WorktreePath -TimeoutSeconds $timeout -Arguments @('axi', 'abort', '--run', $runId))
}

# Run id when the active-or-most-recent run belongs to THIS worktree and is
# parked at a gate; '' otherwise (including a terminal run, which needs nothing).
function Get-FmTaskParkedRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatusOutput
    )
    if (-not $StatusOutput) { return '' }
    $branch = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'symbolic-ref' '--quiet' '--short' 'HEAD')
    if (-not $branch) { return '' }
    $runId = Get-FmNmField -Output $StatusOutput -Key 'id'
    if (-not $runId) { return '' }
    $runBranch = Get-FmNmField -Output $StatusOutput -Key 'branch'
    if (-not $runBranch -or $runBranch -ne $branch) { return '' }
    if (-not (Test-FmNmHeadMatchesWorktree -WorktreePath $WorktreePath -RunHead (Get-FmNmField -Output $StatusOutput -Key 'head'))) { return '' }
    if (Get-FmNmField -Output $StatusOutput -Key 'outcome') { return '' }
    $status = Get-FmNmField -Output $StatusOutput -Key 'status'
    if ($status -eq 'awaiting_approval' -or $status -eq 'fix_review') { return $runId }
    if ($StatusOutput -match '(?m)^\s*awaiting_agent:') { return $runId }
    if ($StatusOutput -match '(?m)^\s*gate:\s*') { return $runId }
    return ''
}

# Closing the runtime endpoint belongs to the backend area. The bash teardown
# already treats the kill as best effort (`|| true`), so a missing closer warns
# and continues rather than stranding a task whose work is already landed.
function Close-FmTaskEndpointIfAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Backend,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $Target) { return }
    $closer = Get-Command -Name 'Stop-FmBackendEndpoint' -ErrorAction SilentlyContinue
    if (-not $closer) {
        Write-FmLifecycleStdErr "teardown: no backend endpoint closer is available; endpoint $Target was not closed"
        return
    }
    try {
        & $closer -Backend $Backend -Target $Target -Label "fm-$Id" | Out-Null
    } catch {
        Write-FmLifecycleStdErr "teardown: closing endpoint $Target failed: $($_.Exception.Message)"
    }
}

# Validate then remove the task's PR-check artifacts. Anything that is not an
# ordinary, non-symlinked file in the state directory refuses and preserves task
# state rather than following a link out of the home.
function Remove-FmTaskPrPollArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not (Test-FmLifecycleTaskIdPathSafe -Id $Id)) { return $true }
    $artifacts = @("$Id.check.sh", "$Id.pr-poll", "$Id.pr-poll-registration", "$Id.pr-poll-retirement", "$Id.check-trust") |
        ForEach-Object { Join-Path $StatePath $_ }
    $quarantine = Join-Path $StatePath '.pr-check-quarantine'
    $present = @($artifacts | Where-Object { Test-Path -LiteralPath $_ })
    $quarantinePresent = Test-Path -LiteralPath $quarantine
    if ($present.Count -eq 0 -and -not $quarantinePresent) { return $true }

    if (-not (Test-FmLifecycleRegularDirectory -Path $StatePath)) {
        Write-FmLifecycleStdErr 'REFUSED: unsafe task state directory; preserving task state.'
        return $false
    }
    foreach ($artifact in $present) {
        if (-not (Test-FmLifecycleRegularFile -Path $artifact)) {
            Write-FmLifecycleStdErr 'REFUSED: unsafe task PR-check artifact; preserving task state.'
            return $false
        }
    }
    $quarantineEntries = @()
    if ($quarantinePresent) {
        if (-not (Test-FmLifecycleRegularDirectory -Path $quarantine)) {
            Write-FmLifecycleStdErr "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state."
            return $false
        }
        $quarantineEntries = @(Get-ChildItem -LiteralPath $quarantine -Filter "$Id.*" -Force -ErrorAction SilentlyContinue)
        foreach ($entry in $quarantineEntries) {
            if (-not (Test-FmLifecycleRegularFile -Path $entry.FullName)) {
                Write-FmLifecycleStdErr 'REFUSED: unsafe task quarantine entry; preserving task state.'
                return $false
            }
        }
    }
    foreach ($artifact in $present) { Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue }
    foreach ($entry in $quarantineEntries) { Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue }
    if ($quarantinePresent -and @(Get-ChildItem -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# The post-teardown backlog line. Not a safety gate - it is the reminder text
# firstmate acts on after cleanup.
function Get-FmBacklogRefreshReminder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrUrl,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    if ($Kind -eq 'secondmate') { return '' }
    if (Test-FmTasksAxiBacklogBackend -ConfigPath $ConfigPath) {
        if ($Kind -eq 'scout') {
            $doneCmd = "tasks-axi done $Id --report data/$Id/report.md"
        } elseif ($Mode -eq 'local-only') {
            $doneCmd = "tasks-axi done $Id --note ""local main"""
        } elseif ($PrUrl) {
            $doneCmd = "tasks-axi done $Id --pr $PrUrl"
        } else {
            $doneCmd = "tasks-axi done $Id --pr PR_URL"
        }
        return "Backlog: $Id just finished. Run $doneCmd, then run tasks-axi ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
    }
    return "Backlog: $Id just finished. Update data/backlog.md - move $Id to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
}

# config/backlog-backend selects the backend; "manual" forces hand-editing.
# The full tasks-axi version-floor probe lives in the backlog area, so this port
# checks the configured choice and the CLI's presence only.
function Test-FmTasksAxiBacklogBackend {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $backendFile = Join-Path $ConfigPath 'backlog-backend'
    $value = 'tasks-axi'
    if (Test-Path -LiteralPath $backendFile -PathType Leaf) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($backendFile) } catch { $raw = '' }
        $raw = ($raw -replace '\s', '')
        if ($raw) { $value = $raw }
    }
    if ($value -eq 'manual') { return $false }
    $probe = Get-Command -Name 'Test-FmTasksAxiCompatible' -ErrorAction SilentlyContinue
    if ($probe) { return [bool](& $probe) }
    return ($null -ne (Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue))
}
