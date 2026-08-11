#requires -Version 7.0
# module/Firstmate/Private/FmTeardown.ps1 - the part of firstmate that must
# never destroy work.
#
# Ported from bin/fm-teardown.sh (the landed-work test, the git-lock patience
# protocol, and the worktree return) and bin/fm-lock-lib.sh (the staleness
# proof). Process custody lives next door in FmJobCustody.ps1.
#
# THE ONE THING THIS AREA GUARANTEES: teardown hard-resets a worktree, deletes
# its branch and kills its processes, so it must REFUSE rather than proceed
# whenever it cannot PROVE the work is safe to discard. Every uncertainty -
# a git command that failed, a lock it cannot classify, a GitHub lookup error,
# a missing owner for a check - resolves to a refusal. That direction is the
# whole design; nothing here may be "helpfully" relaxed.
#
# WHAT CHANGED IN THE PORT, AND WHAT DID NOT
#
# Unchanged: the landed-work test itself. Dirty / unpushed-vs-all-remotes /
# unmerged-vs-default / merged-PR containment / patch-id set inclusion /
# merge-tree tree-equality are all git and gh behaviour, and they port as
# argv arrays with no shell anywhere. The refusal wording is preserved because
# operators and the bash side's own tests read it.
#
# Replaced, per the design report (report.md section 4.3 item 2): the stale
# git-lock proof's primitive. The bash proof asks lsof whether anything holds
# the lock file or the worktree open. Windows has no lsof, and does not need
# one for this question: git holds its lock file open for the whole operation,
# so an EXCLUSIVE open (FileShare.None) that succeeds is direct proof that no
# one holds it - a stronger answer than lsof's, since it is the OS's own
# arbitration rather than a snapshot of a table. The companion-directory leg
# and the mtime-age leg are unchanged, and so is the fail-safe rule: any
# uncertainty means NOT stale, and a lock that is not provably stale is never
# removed.
#
# WINDOWS-UNVERIFIED: the exclusive-open probe's verdict on a lock a live
# git.exe holds. The semantics are documented (git opens its lock without
# FILE_SHARE_WRITE) but unmeasured here. On non-Windows the probe reports
# 'unknown' rather than lying: POSIX has no mandatory locking, so a successful
# open there proves nothing at all, and treating it as proof would delete a
# lock a live git is using.

Set-StrictMode -Version Latest

# --- tunables ----------------------------------------------------------------
#
# Same env names as the bash, including the older alias, so an operator's
# muscle memory and the bash side's own test harness both keep working.

function Get-FmTeardownSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][double]$Default,
        [switch]$AllowFraction
    )
    foreach ($candidate in $Name) {
        $raw = [Environment]::GetEnvironmentVariable($candidate)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $pattern = if ($AllowFraction) { '^([0-9]+(\.[0-9]*)?|\.[0-9]+)$' } else { '^[0-9]+$' }
        if ($raw -notmatch $pattern) {
            Write-Warning "teardown: invalid $candidate '$raw'; using $Default"
            return $Default
        }
        return [double]$raw
    }
    $Default
}

function Get-FmTeardownLockAgeSeconds {
    # 'Seconds' is a count of seconds, not a plural of a noun; a singular
    # name would misdescribe it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    Get-FmTeardownSetting -Name @('FM_STALE_WORKTREE_LOCK_AGE_SECS') -Default 30
}

function Get-FmTeardownReturnRetryCount {
    [CmdletBinding()]
    param()
    [int](Get-FmTeardownSetting -Name @('FM_TREEHOUSE_RETURN_LOCK_RETRIES') -Default 3)
}

function Get-FmTeardownReturnRetryWaitSeconds {
    # 'Seconds' is a count of seconds, not a plural of a noun; a singular
    # name would misdescribe it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    Get-FmTeardownSetting -AllowFraction -Default 1 -Name @(
        'FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'
        'FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS'
    )
}

# --- the stale-git-lock proof ------------------------------------------------

# Get-FmTeardownGitLockPath: absolute path to a worktree's index.lock, or ''
# when the directory is not an inspectable git worktree at all. `rev-parse
# --git-path` is what resolves a LINKED worktree's lock to
# .git/worktrees/<name>/index.lock rather than to the repo's own.
function Get-FmTeardownGitLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Worktree)

    if (-not $Worktree) { return '' }
    if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) { return '' }
    $result = Invoke-FmGit -Directory $Worktree -Arguments @('rev-parse', '--git-path', 'index.lock')
    if (-not $result.Ok) { return '' }
    $lock = $result.StdOut.Trim()
    if (-not $lock) { return '' }
    if ([System.IO.Path]::IsPathRooted($lock)) { return $lock }
    Join-Path $Worktree $lock
}

# Test-FmTeardownGitLockHeld: does a live process hold this lock file open?
#
# THE WINDOWS PRIMITIVE, replacing `lsof -- <lock>`. Verdicts:
#   'absent'  the file is not there
#   'free'    an exclusive open SUCCEEDED, so provably nothing holds it
#   'held'    a sharing violation, so something holds it
#   'unknown' anything else (access denied, a non-Windows host) - fail safe,
#             which every caller treats exactly like 'held'
function Test-FmTeardownGitLockHeld {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if (-not $Path) { return 'unknown' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'absent' }
    if (-not $IsWindows) {
        # POSIX advisory locking means a successful exclusive open proves
        # nothing. Saying so is the only honest answer; the alternative would
        # delete a lock a live git process is holding.
        return 'unknown'
    }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
        return 'free'
    } catch [System.IO.FileNotFoundException] {
        return 'absent'
    } catch [System.IO.IOException] {
        # ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION arrive as IOException.
        return 'held'
    } catch {
        return 'unknown'
    }
}

# Test-FmTeardownDirectoryHeld: does anything still hold the companion
# directory - the worktree itself?
#
# The bash proof's second leg asks lsof for holders of the worktree directory
# (a live git keeps its cwd there). Windows cannot enumerate cwd holders
# without per-process PEB reads, and report.md section 4.3 settled that we do
# NOT emulate that. What we have instead is CUSTODY: the task's job object
# holds exactly the processes firstmate spawned into that worktree.
#
#   'holders' the custody job has live processes
#   'none'    the custody job exists and is empty
#   'unknown' no custody job, an error, or no TaskId to ask about
#
# 'unknown' is deliberately as strong a refusal as 'holders', matching the
# bash rule that a missing lsof means "assume live".
function Test-FmTeardownDirectoryHeld {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$TaskId)

    if (-not $TaskId) { return 'unknown' }
    $custody = Get-FmTaskJobProcessId -TaskId $TaskId
    switch ($custody.State) {
        'processes' { return 'holders' }
        'empty' { return 'none' }
        default { return 'unknown' }
    }
}

# Test-FmTeardownGitLockStale: THE PROOF. True only when the lock exists, no
# live process holds it, nothing holds the worktree, and its mtime age is at
# least the threshold. Any uncertainty returns false - never remove a lock this
# returns false for.
function Test-FmTeardownGitLockStale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LockPath,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TaskId,
        [double]$MinimumAgeSeconds = -1
    )

    if ($MinimumAgeSeconds -lt 0) { $MinimumAgeSeconds = Get-FmTeardownLockAgeSeconds }
    if (-not $LockPath) { return $false }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $false }

    if ((Test-FmTeardownGitLockHeld -Path $LockPath) -ne 'free') { return $false }
    if ((Test-FmTeardownDirectoryHeld -TaskId $TaskId) -ne 'none') { return $false }

    $written = $null
    try {
        $written = [System.IO.File]::GetLastWriteTimeUtc($LockPath)
    } catch {
        Write-Warning "teardown: cannot read mtime for git lock $LockPath; leaving it in place"
        return $false
    }
    if ($null -eq $written -or $written.Year -le 1601) {
        Write-Warning "teardown: cannot read mtime for git lock $LockPath; leaving it in place"
        return $false
    }
    $age = ([DateTime]::UtcNow - $written).TotalSeconds
    $age -ge $MinimumAgeSeconds
}

# --- the landed-work test ----------------------------------------------------

function Get-FmTeardownPrNumberFromTarget {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Target)

    if (-not $Target) { return '' }
    if ($Target -match '/pull/([0-9]+)') { return $Matches[1] }
    if ($Target -match '^([0-9]+)') { return $Matches[1] }
    ''
}

# Get-FmTeardownPrNumberFromBranch: the "no pr= was ever recorded" path. Any
# lookup failure returns '' so the caller reads it as "no PR found" - fail-safe,
# because a missing PR must never by itself claim work is landed.
function Get-FmTeardownPrNumberFromBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Branch
    )
    if (-not $Branch -or $Branch -eq 'HEAD') { return '' }
    $result = Invoke-FmChildProcess -FilePath 'gh-axi' -WorkingDirectory $Worktree `
        -ArgumentList @('pr', 'list', '--state', 'all', '--head', $Branch, '--limit', '1')
    if (-not $result.Ok) { return '' }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^\s*([0-9]+),') { return $Matches[1] }
    }
    ''
}

# Confirm-FmTeardownCommitObject: make the PR head commit locally readable,
# fetching refs/pull/<n>/head when the PR's branch was deleted after merge.
function Confirm-FmTeardownCommitObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Commit
    )
    if (-not $Commit) { return $false }
    if ((Invoke-FmGit -Directory $Worktree -Arguments @('cat-file', '-e', "$Commit^{commit}")).Ok) {
        return $true
    }
    $number = Get-FmTeardownPrNumberFromTarget -Target $Target
    if (-not $number) { return $false }
    if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('remote', 'get-url', 'origin')).Ok) {
        return $false
    }
    if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('fetch', '--quiet', 'origin', "refs/pull/$number/head")).Ok) {
        return $false
    }
    (Invoke-FmGit -Directory $Worktree -Arguments @('cat-file', '-e', "$Commit^{commit}")).Ok
}

# Get-FmTeardownCommitPatchId: `git show <c> | git patch-id --stable`, without a
# shell pipe - the show output is fed to patch-id's stdin as bytes.
function Get-FmTeardownCommitPatchId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Commit
    )
    $show = Invoke-FmGit -Directory $Worktree -Arguments @('show', '--pretty=medium', '--no-ext-diff', $Commit)
    if (-not $show.Ok) { return '' }
    $patch = Invoke-FmChildProcess -FilePath 'git' -WorkingDirectory $Worktree `
        -ArgumentList @('patch-id', '--stable') -StandardInput $show.StdOut
    if (-not $patch.Ok) { return '' }
    $first = @($patch.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($first.Count -eq 0) { return '' }
    ($first[0].Trim() -split '\s+')[0]
}

# Test-FmTeardownPatchesInPrHead: the squash-and-force-push case. Every commit
# that is on HEAD but on no remote must have a patch-id that also appears in the
# PR head's own commits. One missing patch id means unlanded work.
function Test-FmTeardownPatchesInPrHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$PrHead
    )
    $current = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--verify', 'HEAD')
    if (-not $current) { return $false }
    $base = Get-FmGitOutput -Directory $Worktree -Arguments @('merge-base', $current, $PrHead)
    if (-not $base) { return $false }

    $prCommits = Invoke-FmGit -Directory $Worktree -Arguments @('log', '--format=%H', "$base..$PrHead", '--')
    if (-not $prCommits.Ok) { return $false }
    $prPatchIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($commit in ($prCommits.StdOut -split "`r?`n")) {
        if (-not $commit.Trim()) { continue }
        $id = Get-FmTeardownCommitPatchId -Worktree $Worktree -Commit $commit.Trim()
        if ($id) { $null = $prPatchIds.Add($id) }
    }
    if ($prPatchIds.Count -eq 0) { return $false }

    $unpushed = Invoke-FmGit -Directory $Worktree -Arguments @('log', '--format=%H', 'HEAD', '--not', '--remotes', '--')
    if (-not $unpushed.Ok) { return $false }
    $any = $false
    foreach ($commit in ($unpushed.StdOut -split "`r?`n")) {
        if (-not $commit.Trim()) { continue }
        $any = $true
        $id = Get-FmTeardownCommitPatchId -Worktree $Worktree -Commit $commit.Trim()
        if (-not $id) { return $false }
        if (-not $prPatchIds.Contains($id)) { return $false }
    }
    $any
}

# Test-FmTeardownPrMerged: is the worktree's PR merged AND does its head contain
# the current local work? Non-zero on any doubt, so the caller falls through to
# the content check rather than concluding "landed".
function Test-FmTeardownPrMerged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Branch,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PrUrl
    )

    $target = if ($PrUrl) { $PrUrl } else { Get-FmTeardownPrNumberFromBranch -Worktree $Worktree -Branch $Branch }
    if (-not $target) { return $false }

    $view = Invoke-FmChildProcess -FilePath 'gh' -WorkingDirectory $Worktree `
        -ArgumentList @('pr', 'view', $target, '--json', 'state,headRefOid')
    if (-not $view.Ok) { return $false }
    $json = ConvertFrom-FmJsonSafe -Text $view.StdOut
    if ($null -eq $json) { return $false }
    $state = [string](Get-FmJsonValue -InputObject $json -Path 'state')
    $head = [string](Get-FmJsonValue -InputObject $json -Path 'headRefOid')
    if ($state -notin @('MERGED', 'merged')) { return $false }
    if (-not $head) { return $false }
    if (-not (Confirm-FmTeardownCommitObject -Worktree $Worktree -Target $target -Commit $head)) { return $false }

    $current = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--verify', 'HEAD')
    if (-not $current) { return $false }
    if ((Invoke-FmGit -Directory $Worktree -Arguments @('merge-base', '--is-ancestor', $current, $head)).Ok) {
        return $true
    }
    Test-FmTeardownPatchesInPrHead -Worktree $Worktree -PrHead $head
}

# Test-FmTeardownContentInDefault: is this branch's content already in the
# up-to-date default branch? A 3-way merge of the default branch with HEAD that
# produces the default branch's own tree means HEAD introduces nothing new -
# the squash-merge signature. Inconclusive (no default ref, a conflict) is
# false, so the caller refuses rather than guesses.
function Test-FmTeardownContentInDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project
    )
    $name = Get-FmGitDefaultBranch -Directory $Project
    if (-not $name) { return $false }

    $ref = ''
    if ((Invoke-FmGit -Directory $Worktree -Arguments @('remote', 'get-url', 'origin')).Ok) {
        if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('fetch', '--quiet', 'origin', "+refs/heads/$name`:refs/remotes/origin/$name")).Ok) {
            return $false
        }
        $ref = "refs/remotes/origin/$name"
    } elseif ((Invoke-FmGit -Directory $Worktree -Arguments @('rev-parse', '--quiet', '--verify', "refs/heads/$name")).Ok) {
        $ref = "refs/heads/$name"
    } else {
        return $false
    }

    $defaultTree = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--quiet', '--verify', "$ref^{tree}")
    if (-not $defaultTree) { return $false }
    $merged = Invoke-FmGit -Directory $Worktree -Arguments @('merge-tree', '--write-tree', $ref, 'HEAD')
    if (-not $merged.Ok) { return $false }
    $lines = @($merged.StdOut -split "`r?`n")
    if ($lines.Count -eq 0) { return $false }
    $lines[0].Trim() -eq $defaultTree
}

# Test-FmTeardownWorkLanded: has committed work that is on no remote actually
# LANDED? A merged PR that contains it, or content already in the default
# branch. False only for genuinely unlanded work.
function Test-FmTeardownWorkLanded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Branch,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PrUrl
    )
    if (Test-FmTeardownPrMerged -Worktree $Worktree -Branch $Branch -PrUrl $PrUrl) { return $true }
    Test-FmTeardownContentInDefault -Worktree $Worktree -Project $Project
}

# --- the safety verdict ------------------------------------------------------

# New-FmTeardownVerdict: verdicts are RETURNED, never thrown - a refusal is a
# normal outcome of this function, and `throw` under $ErrorActionPreference =
# 'Stop' would make callers unable to tell a refusal from a bug.
function New-FmTeardownVerdict {
    # Constructs an in-memory record and changes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('allow', 'refuse', 'lock-blocked')][string]$Verdict,
        [string[]]$Message = @()
    )
    [pscustomobject]@{ Verdict = $Verdict; Message = @($Message) }
}

# The bash dirty filter: firstmate's own dropped-in hook files are not the
# crew's work, so an untracked .claude/ or turn-end marker never counts as
# uncommitted changes.
function Test-FmTeardownIgnorableStatusLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $Line -match '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)'
}

# Test-FmTeardownWorktreeSafety: THE COMPLETE LANDED-WORK TEST.
#
# Every branch of it exists because it caught a real way to lose work:
#   - a git command that FAILS is not "clean"; when a lock explains the failure
#     the verdict is 'lock-blocked' so the caller can try the staleness proof
#     and re-run this, and otherwise it is a flat refusal,
#   - local-only mode has no remote to land on, so "merged into the local
#     default branch" is the accepted proof and dirty-or-unmerged refuses,
#   - a dirty worktree refuses before anything else is even considered:
#     uncommitted changes are NEVER landed,
#   - unpushed commits refuse unless the landed-work test proves otherwise.
# scout and secondmate kinds carve out (their gates are elsewhere), and -Force
# skips the whole thing - which is why -Force needs explicit authority.
function Test-FmTeardownWorktreeSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Project,
        [string]$Kind = 'ship',
        [string]$Mode = '',
        [string]$PrUrl = '',
        [switch]$Force
    )

    $restore = 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
    if (-not $Worktree -or -not (Test-Path -LiteralPath $Worktree -PathType Container)) {
        return New-FmTeardownVerdict -Verdict 'allow'
    }
    if ($Force) { return New-FmTeardownVerdict -Verdict 'allow' }
    if ($Kind -in @('secondmate', 'scout')) { return New-FmTeardownVerdict -Verdict 'allow' }

    $lockPresent = {
        $lock = Get-FmTeardownGitLockPath -Worktree $Worktree
        if ($lock -and (Test-Path -LiteralPath $lock -PathType Leaf)) { $lock } else { '' }
    }

    $status = Invoke-FmGit -Directory $Worktree -Arguments @('status', '--porcelain')
    if (-not $status.Ok) {
        $lock = & $lockPresent
        if ($lock) {
            return New-FmTeardownVerdict -Verdict 'lock-blocked' -Message @(
                "teardown: cannot inspect worktree $Worktree for uncommitted changes while git lock $lock is present; checking whether the lock is stale")
        }
        return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
            "REFUSED: cannot inspect worktree $Worktree for uncommitted changes.", $restore)
    }
    $dirty = @($status.StdOut -split "`r?`n" |
        Where-Object { $_.Trim() } |
        Where-Object { -not (Test-FmTeardownIgnorableStatusLine -Line $_) })

    $unpushedResult = Invoke-FmGit -Directory $Worktree -Arguments @('log', '--oneline', 'HEAD', '--not', '--remotes', '--')
    if (-not $unpushedResult.Ok) {
        $lock = & $lockPresent
        if ($lock) {
            return New-FmTeardownVerdict -Verdict 'lock-blocked' -Message @(
                "teardown: cannot inspect worktree $Worktree for commits not on a remote while git lock $lock is present; checking whether the lock is stale")
        }
        return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
            "REFUSED: cannot inspect worktree $Worktree for commits not on a remote.", $restore)
    }
    $unpushed = @($unpushedResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 5)

    if ($unpushed.Count -gt 0 -and $Mode -eq 'local-only') {
        $default = Get-FmGitDefaultBranch -Directory $Project
        if (-not $default) {
            return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
                "REFUSED: cannot determine default branch for $Project; expected origin/HEAD, main, or master.")
        }
        $unmergedResult = Invoke-FmGit -Directory $Worktree -Arguments @('log', '--oneline', 'HEAD', '--not', $default, '--')
        if (-not $unmergedResult.Ok) {
            $lock = & $lockPresent
            if ($lock) {
                return New-FmTeardownVerdict -Verdict 'lock-blocked' -Message @(
                    "teardown: cannot inspect worktree $Worktree for commits not on $default while git lock $lock is present; checking whether the lock is stale")
            }
            return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
                "REFUSED: cannot inspect worktree $Worktree for commits not on $default.", $restore)
        }
        $unmerged = @($unmergedResult.StdOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 5)
        if ($dirty.Count -gt 0 -or $unmerged.Count -gt 0) {
            $message = [System.Collections.Generic.List[string]]::new()
            $message.Add("REFUSED: local-only worktree $Worktree has work not yet merged into $default and not on any remote.")
            if ($dirty.Count -gt 0) { $message.Add('uncommitted changes present') }
            if ($unmerged.Count -gt 0) {
                $message.Add("commits not yet on ${default}:")
                foreach ($line in $unmerged) { $message.Add($line) }
            }
            $message.Add(("Merge the branch into local $default first (the local-merge path, after the captain approves), " +
                'or push to a fork/remote, or get the captain''s explicit OK to discard, then --force.'))
            return New-FmTeardownVerdict -Verdict 'refuse' -Message $message
        }
        return New-FmTeardownVerdict -Verdict 'allow'
    }

    if ($dirty.Count -gt 0) {
        return New-FmTeardownVerdict -Verdict 'refuse' -Message @(
            "REFUSED: worktree $Worktree has uncommitted changes.",
            'uncommitted changes present',
            'Commit them (or get the captain''s explicit OK to discard, then --force).')
    }

    if ($unpushed.Count -gt 0) {
        $branch = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
        if (-not $branch) { $branch = 'HEAD' }
        if (-not (Test-FmTeardownWorkLanded -Worktree $Worktree -Project $Project -Branch $branch -PrUrl $PrUrl)) {
            $message = [System.Collections.Generic.List[string]]::new()
            $message.Add("REFUSED: worktree $Worktree has work not on any remote and not landed.")
            $message.Add('unpushed commits:')
            foreach ($line in $unpushed) { $message.Add($line) }
            $message.Add('Push the branch, land its PR, or get the captain''s explicit OK to discard, then --force.')
            return New-FmTeardownVerdict -Verdict 'refuse' -Message $message
        }
    }

    New-FmTeardownVerdict -Verdict 'allow'
}

# Clear-FmTeardownStaleLock: the safety-check side of the patience protocol.
# Wait once (the owning process may be exiting), then remove the lock ONLY if
# the shared proof says it is provably stale. Returns 'cleared' (retry the
# safety checks) or 'refused' (leave everything intact).
function Clear-FmTeardownStaleLock {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TaskId
    )
    $lock = Get-FmTeardownGitLockPath -Worktree $Worktree
    if (-not $lock -or -not (Test-Path -LiteralPath $lock -PathType Leaf)) { return 'cleared' }

    $wait = Get-FmTeardownReturnRetryWaitSeconds
    Write-Warning ("teardown: worktree safety check blocked by git lock $lock; waiting ${wait}s and retrying " +
        '(owning process may be exiting)')
    Start-Sleep -Seconds $wait

    if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) {
        Write-Warning 'teardown: worktree safety check lock cleared on its own; retrying safety checks'
        return 'cleared'
    }
    if (Test-FmTeardownGitLockStale -LockPath $lock -TaskId $TaskId) {
        if (-not $PSCmdlet.ShouldProcess($lock, 'remove a provably stale git lock')) { return 'refused' }
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        Write-Warning ("teardown: removed provably-stale git lock $lock (age >= " +
            "$(Get-FmTeardownLockAgeSeconds)s, no live holder) and retrying worktree safety checks")
        return 'cleared'
    }
    Write-Warning ("teardown: worktree safety check blocked by git lock $lock that is not provably stale " +
        '(may belong to a live process); leaving it in place')
    'refused'
}

# --- returning the worktree to the pool --------------------------------------

# Test-FmTeardownIndexLockError: the ONE failure signature that earns patience.
# Every other treehouse failure aborts immediately and loudly.
function Test-FmTeardownIndexLockError {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $false }
    $Text -match 'Unable to create ([''"]).*index\.lock\1: File exists'
}

# Invoke-FmTeardownWorktreeReturn: return the worktree to the treehouse pool,
# tolerating the transient index.lock a killed crew process leaves behind.
#
# THE LEASE RULES, which are the part that must not be got wrong:
#   - the return is CONDITIONAL on the lease this task was given
#     (`--if-lease-id`), so a return can never recycle a lease that the pool has
#     since handed to someone else. A record with no lease id is returned
#     unconditionally, exactly as the bash does, because there is no identity to
#     condition on - and that is reported, not hidden.
#   - `--force` here is treehouse's own flag meaning "return even though the
#     worktree is dirty". It is safe ONLY because the landed-work test has
#     already passed above it; it is never how a refusal gets bypassed.
#   - a FAILED return leaves the worktree and every state file in place. The
#     bash rule is exact: never hide a still-held lease by deleting the record
#     that points at it.
#
# MERGE POINT: the conditional release itself is owned by
# Remove-FmWorktreeLease. This calls treehouse directly because the patience
# protocol has to match on the CLI's error TEXT, which that helper does not
# surface. If it grows a pass-through form, delegate to it and delete this
# invocation - not the protocol.
function Invoke-FmTeardownWorktreeReturn {
    # Project is used inside the $attempt scriptblock, which the analyzer
    # cannot see through.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Project')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [string]$Label = 'worktree',
        [string]$LeaseId = '',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TaskId,
        [scriptblock]$PostCleanupCheck
    )

    $argv = @('return', $Worktree)
    if ($LeaseId) { $argv += @('--if-lease-id', $LeaseId) }
    $argv += '--force'
    $attempt = {
        Invoke-FmChildProcess -FilePath 'treehouse' -ArgumentList $argv -WorkingDirectory $Project
    }
    $describe = {
        param($result)
        (@($result.StdOut, $result.StdErr) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
    }

    if (-not $PSCmdlet.ShouldProcess($Worktree, "treehouse return ($Label)")) {
        return [pscustomobject]@{ Outcome = 'skipped'; Detail = 'not confirmed' }
    }

    $result = & $attempt
    if ($result.Ok) {
        return [pscustomobject]@{ Outcome = 'returned'; Detail = (& $describe $result) }
    }
    $detail = & $describe $result
    if (-not (Test-FmTeardownIndexLockError -Text $result.Combined)) {
        return [pscustomobject]@{ Outcome = 'failed'; Detail = $detail }
    }

    $retries = Get-FmTeardownReturnRetryCount
    $wait = Get-FmTeardownReturnRetryWaitSeconds
    $lock = Get-FmTeardownGitLockPath -Worktree $Worktree
    $lockDesc = if ($lock) { $lock } else { 'index.lock' }

    for ($i = 1; $i -le $retries; $i++) {
        Write-Warning ("teardown: $Label return failed with transient git lock ($lockDesc); waiting ${wait}s " +
            "and retrying ($i/$retries)")
        Start-Sleep -Seconds $wait
        $result = & $attempt
        if ($result.Ok) {
            Write-Warning "teardown: $Label return succeeded on retry; lock cleared on its own"
            return [pscustomobject]@{ Outcome = 'returned'; Detail = (& $describe $result) }
        }
        $detail = & $describe $result
        if (-not (Test-FmTeardownIndexLockError -Text $result.Combined)) {
            Write-Warning "teardown: $Label return failed with a non-lock error after retry; aborting"
            return [pscustomobject]@{ Outcome = 'failed'; Detail = $detail }
        }
    }

    # The lock may have appeared, moved, or cleared while we waited.
    $lock = Get-FmTeardownGitLockPath -Worktree $Worktree
    if ($lock -and (Test-Path -LiteralPath $lock -PathType Leaf)) {
        if (Test-FmTeardownGitLockStale -LockPath $lock -TaskId $TaskId) {
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
            Write-Warning ("teardown: removed provably-stale git lock $lock (age >= " +
                "$(Get-FmTeardownLockAgeSeconds)s, no live holder) and retrying $Label return")
            if ($PostCleanupCheck) {
                # The safety checks could not run while the lock was there. They
                # run NOW, before the destructive return - a lock is not a reason
                # to skip the landed-work test.
                if (-not (& $PostCleanupCheck)) {
                    return [pscustomobject]@{
                        Outcome = 'refused'
                        Detail  = "teardown: $Label return aborted after stale-lock cleanup because safety checks failed"
                    }
                }
            }
            $result = & $attempt
            if ($result.Ok) {
                Write-Warning "teardown: $Label return succeeded after stale-lock cleanup"
                return [pscustomobject]@{ Outcome = 'returned'; Detail = (& $describe $result) }
            }
            return [pscustomobject]@{
                Outcome = 'failed'
                Detail  = "teardown: $Label return still failing after stale-lock cleanup: $(& $describe $result)"
            }
        }
        # @() around the call: a single holder unrolls to a bare string, and
        # $null means Restart Manager could not answer - both must read as
        # "no names to show", never as an error.
        $holders = @(Get-FmFileHolderProcess -Path @($lock))
        $named = if ($holders.Count -gt 0) { " Held by: $($holders -join '; ')." } else { '' }
        return [pscustomobject]@{
            Outcome = 'lock-refused'
            Detail  = ("teardown: $Label return failed: git lock $lockDesc persisted across $retries retries " +
                "(waiting ${wait}s each) and is not provably stale (may belong to a live process); leaving it in place.$named")
        }
    }

    [pscustomobject]@{
        Outcome = 'failed'
        Detail  = ("teardown: $Label return failed: git index.lock signature persisted across $retries retries " +
            "(waiting ${wait}s each) even after the lock file disappeared")
    }
}

# --- cross-area binding ------------------------------------------------------

# Resolve-FmTeardownOwner: areas bind to each other by NAME at call time, so a
# missing owner must be a step that explicitly did NOT run - never a step that
# silently passed. Returns $null when the owner is absent.
function Resolve-FmTeardownOwner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Get-Command -Name $Name -CommandType Function, Cmdlet -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

# Get-FmTeardownBacklogReminder: the one line teardown prints so the backlog
# gets updated. Ported from backlog_refresh_reminder; a secondmate teardown
# prints none, since secondmates are not backlog items.
function Get-FmTeardownBacklogReminder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Kind = 'ship',
        [string]$Mode = '',
        [string]$PrUrl = '',
        [switch]$TasksAxiAvailable
    )
    if ($Kind -eq 'secondmate') { return '' }
    if (-not $TasksAxiAvailable) {
        return ("Backlog: $TaskId just finished. Update data/backlog.md - move $TaskId to Done, keep Done to the 10 " +
            'most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.')
    }
    $doneCommand = if ($Kind -eq 'scout') {
        "tasks-axi done $TaskId --report data/$TaskId/report.md"
    } elseif ($Mode -eq 'local-only') {
        "tasks-axi done $TaskId --note ""local main"""
    } elseif ($PrUrl) {
        "tasks-axi done $TaskId --pr $PrUrl"
    } else {
        "tasks-axi done $TaskId --pr PR_URL"
    }
    ("Backlog: $TaskId just finished. Run $doneCommand, then run tasks-axi ready for dependency-cleared candidates, " +
        'check date gates, and dispatch only work whose blockers are gone and date is due.')
}
