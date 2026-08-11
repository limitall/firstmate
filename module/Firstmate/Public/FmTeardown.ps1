#requires -Version 7.0
# FmTeardown.ps1 (public) - tear down a finished task, and REFUSE while the
# worktree holds work that has not landed. Ported from bin/fm-teardown.sh.
#
# Teardown hard-resets and removes the worktree and kills its processes, so a
# refusal here is a stop-and-investigate result, never an obstacle to bypass
# (AGENTS.md hard rule 3). -Force is the ONLY bypass and means exactly one
# thing: the captain has explicitly authorized discarding that work.
#
# Ported scope: local ship and scout tasks on an ordinary task worktree. Task
# shapes whose destructive machinery lives outside this area - a secondmate home
# retirement, a remote-placed secondmate, and the Orca and Herdr endpoint
# lifecycles - are REFUSED rather than half-performed, because each of them owns
# safety checks (child work inventory, remote retirement, focus-preserving pane
# close) this module cannot perform. See docs/lifecycle.md.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
The landed-work test applied to a task's worktree: does teardown refuse?
.DESCRIPTION
Returns Code 0 to proceed, 1 to refuse, and 3 when a git lock made the
inspection impossible (the caller may clear a provably stale lock and retry).
Never returns 0 on an inconclusive answer: an inspection that cannot run refuses
exactly like unlanded work, because cleanup is destructive and irreversible.

Order of the checks, unchanged from the bash original:
  1. -Force, a torn-down worktree, and the scout/secondmate carve-outs skip.
  2. Uncommitted changes are never landed (ignoring only the harness's own
     .claude/ and turn-end marker droppings).
  3. Commits not reachable from any remote-tracking branch are suspect.
  4. local-only additionally accepts work already merged into the local default
     branch; anything dirty or unmerged there refuses.
  5. Otherwise unpushed commits must pass the landed-work test.
#>
function Test-FmTeardownSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProjectPath,
        [Parameter()][AllowEmptyString()][string]$Kind = 'ship',
        [Parameter()][AllowEmptyString()][string]$Mode = 'no-mistakes',
        [Parameter()][AllowEmptyString()][string]$PrUrl = '',
        [switch]$Force
    )
    $messages = [System.Collections.Generic.List[string]]::new()
    function local:Refuse([string]$text) { $messages.Add($text); Write-FmLifecycleStdErr $text }

    if (-not $WorktreePath -or -not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
        return [pscustomobject]@{ Code = 0; Messages = @($messages) }
    }
    if ($Force) { return [pscustomobject]@{ Code = 0; Messages = @($messages) } }
    if ($Kind -eq 'secondmate' -or $Kind -eq 'scout') {
        return [pscustomobject]@{ Code = 0; Messages = @($messages) }
    }

    $blockedByLock = {
        param([string]$reason)
        $lock = Get-FmTeardownWorktreeLockPath -Path $WorktreePath
        if ($lock -and (Test-Path -LiteralPath $lock)) {
            Write-FmLifecycleStdErr "teardown: cannot inspect worktree $WorktreePath for $reason while git lock $lock is present; checking whether the lock is stale"
            return $true
        }
        return $false
    }

    $status = Invoke-FmGit -RepoPath $WorktreePath 'status' '--porcelain'
    if ($status.ExitCode -ne 0) {
        if (& $blockedByLock 'uncommitted changes') {
            return [pscustomobject]@{ Code = $script:FmTeardownSafetyLockBlocked; Messages = @($messages) }
        }
        Refuse "REFUSED: cannot inspect worktree $WorktreePath for uncommitted changes."
        Refuse 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
        return [pscustomobject]@{ Code = 1; Messages = @($messages) }
    }
    $dirty = ''
    foreach ($line in ($status.StdOut -replace "`r`n", "`n").Split("`n")) {
        if ($line -eq '') { continue }
        # Only the harness's own droppings are ignored; every other untracked or
        # modified path counts as uncommitted work.
        if ($line -match '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)') { continue }
        $dirty = $line
        break
    }

    $unpushedResult = Invoke-FmGit -RepoPath $WorktreePath 'log' '--oneline' 'HEAD' '--not' '--remotes' '--'
    if ($unpushedResult.ExitCode -ne 0) {
        if (& $blockedByLock 'commits not on a remote') {
            return [pscustomobject]@{ Code = $script:FmTeardownSafetyLockBlocked; Messages = @($messages) }
        }
        Refuse "REFUSED: cannot inspect worktree $WorktreePath for commits not on a remote."
        Refuse 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
        return [pscustomobject]@{ Code = 1; Messages = @($messages) }
    }
    $unpushed = @(($unpushedResult.StdOut -replace "`r`n", "`n").Split("`n") | Where-Object { $_ -ne '' } | Select-Object -First 5)

    if ($unpushed.Count -gt 0 -and $Mode -eq 'local-only') {
        $default = Get-FmLifecycleDefaultBranch -RepoPath $ProjectPath
        if (-not $default) {
            Refuse "REFUSED: cannot determine default branch for $ProjectPath; expected origin/HEAD, main, or master."
            return [pscustomobject]@{ Code = 1; Messages = @($messages) }
        }
        $unmergedResult = Invoke-FmGit -RepoPath $WorktreePath 'log' '--oneline' 'HEAD' '--not' $default '--'
        if ($unmergedResult.ExitCode -ne 0) {
            if (& $blockedByLock "commits not on $default") {
                return [pscustomobject]@{ Code = $script:FmTeardownSafetyLockBlocked; Messages = @($messages) }
            }
            Refuse "REFUSED: cannot inspect worktree $WorktreePath for commits not on $default."
            Refuse 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
            return [pscustomobject]@{ Code = 1; Messages = @($messages) }
        }
        $unmerged = @(($unmergedResult.StdOut -replace "`r`n", "`n").Split("`n") | Where-Object { $_ -ne '' } | Select-Object -First 5)
        if ($dirty -ne '' -or $unmerged.Count -gt 0) {
            Refuse "REFUSED: local-only worktree $WorktreePath has work not yet merged into $default and not on any remote."
            if ($dirty -ne '') { Refuse 'uncommitted changes present' }
            if ($unmerged.Count -gt 0) { Refuse ("commits not yet on ${default}:`n" + ($unmerged -join "`n")) }
            Refuse "Merge the branch into local $default first (fm-merge-local after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force."
            return [pscustomobject]@{ Code = 1; Messages = @($messages) }
        }
    } elseif ($dirty -ne '') {
        Refuse "REFUSED: worktree $WorktreePath has uncommitted changes."
        Refuse 'uncommitted changes present'
        Refuse 'Commit them (or get the captain''s explicit OK to discard, then --force).'
        return [pscustomobject]@{ Code = 1; Messages = @($messages) }
    } elseif ($unpushed.Count -gt 0) {
        $branch = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--abbrev-ref' 'HEAD')
        if (-not $branch) { $branch = 'HEAD' }
        if (-not (Test-FmWorkIsLanded -WorktreePath $WorktreePath -ProjectPath $ProjectPath -Branch $branch -PrUrl $PrUrl)) {
            Refuse "REFUSED: worktree $WorktreePath has work not on any remote and not landed."
            Refuse ("unpushed commits:`n" + ($unpushed -join "`n"))
            Refuse 'Push the branch, land its PR, or get the captain''s explicit OK to discard, then --force.'
            return [pscustomobject]@{ Code = 1; Messages = @($messages) }
        }
    }
    return [pscustomobject]@{ Code = 0; Messages = @($messages) }
}

<#
.SYNOPSIS
Return a task worktree to its pool, tolerating the transient git index.lock a
killed crew process leaves behind.
.DESCRIPTION
Retries the return on the index.lock signature only; every other failure aborts
immediately and loudly. After the patience window a lock is removed and the
return retried only when it is PROVABLY stale, and the caller's safety re-check
must still pass before that final attempt. A lock that cannot be proven dead is
left in place and the teardown fails as loudly as any other return failure.
#>
function Invoke-FmTeardownWorktreeReturn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Label,
        [scriptblock]$PostCleanupCheck
    )
    $waitSecs = Get-FmTeardownLockRetryWaitSeconds
    $maxRetries = Get-FmTeardownLockRetryCount
    $ageSecs = Get-FmTeardownStaleLockAgeSeconds

    $run = {
        $result = Invoke-FmLifecycleProcess -FilePath 'treehouse' -Arguments @('return', '--force', $WorktreePath) -WorkingDirectory $WorkingDirectory
        $text = (($result.StdOut + $result.StdErr) -replace "`r`n", "`n").Trim("`n")
        [pscustomobject]@{ ExitCode = $result.ExitCode; Text = $text }
    }
    $isIndexLockError = { param([string]$text) return ($text -match "Unable to create ['`"].*index\.lock['`"]: File exists") }

    $attemptResult = & $run
    if ($attemptResult.ExitCode -eq 0) {
        if ($attemptResult.Text) { [Console]::Out.WriteLine($attemptResult.Text) }
        return 0
    }
    if ($attemptResult.Text) { Write-FmLifecycleStdErr $attemptResult.Text }
    if (-not (& $isIndexLockError $attemptResult.Text)) { return 1 }

    $lock = Get-FmTeardownWorktreeLockPath -Path $WorktreePath
    $lockDesc = if ($lock) { $lock } else { 'index.lock' }

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-FmLifecycleStdErr "teardown: $Label return failed with transient git lock ($lockDesc); waiting ${waitSecs}s and retrying ($attempt/$maxRetries)"
        Start-Sleep -Seconds $waitSecs
        $attemptResult = & $run
        if ($attemptResult.ExitCode -eq 0) {
            if ($attemptResult.Text) { [Console]::Out.WriteLine($attemptResult.Text) }
            Write-FmLifecycleStdErr "teardown: $Label return succeeded on retry; lock cleared on its own"
            return 0
        }
        if ($attemptResult.Text) { Write-FmLifecycleStdErr $attemptResult.Text }
        if (-not (& $isIndexLockError $attemptResult.Text)) {
            Write-FmLifecycleStdErr "teardown: $Label return failed with a non-lock error after retry; aborting"
            return 1
        }
    }

    $lock = Get-FmTeardownWorktreeLockPath -Path $WorktreePath
    if ($lock -and (Test-Path -LiteralPath $lock)) {
        if (Test-FmTeardownLockProvablyStale -LockPath $lock -AgeSeconds $ageSecs) {
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
            Write-FmLifecycleStdErr "teardown: removed provably-stale git lock $lock (age >= ${ageSecs}s, no live holder) and retrying $Label return"
            if ($PostCleanupCheck) {
                if (-not (& $PostCleanupCheck)) {
                    Write-FmLifecycleStdErr "teardown: $Label return aborted after stale-lock cleanup because safety checks failed"
                    return 1
                }
            }
            $attemptResult = & $run
            if ($attemptResult.ExitCode -eq 0) {
                if ($attemptResult.Text) { [Console]::Out.WriteLine($attemptResult.Text) }
                Write-FmLifecycleStdErr "teardown: $Label return succeeded after stale-lock cleanup"
                return 0
            }
            if ($attemptResult.Text) { Write-FmLifecycleStdErr $attemptResult.Text }
            Write-FmLifecycleStdErr "teardown: $Label return still failing after stale-lock cleanup"
            return 1
        }
        Write-FmLifecycleStdErr "teardown: $Label return failed: git lock $lock persisted across $maxRetries retries (waiting ${waitSecs}s each) and is not provably stale (may belong to a live process); leaving it in place"
        return 2
    }
    Write-FmLifecycleStdErr "teardown: $Label return failed: git index.lock signature persisted across $maxRetries retries (waiting ${waitSecs}s each) even after the lock file disappeared"
    return 1
}

<#
.SYNOPSIS
Tear down a finished task: refuse on unlanded work, then release the worktree,
close the endpoint, and clear the task's volatile state.
.PARAMETER Force
Skips the dirty and landed-work checks and the scout report gate. Use it ONLY
when the captain has explicitly said to discard the work.
.OUTPUTS
An object with ExitCode (0 complete, 1 refused or failed, 2 usage or contention)
and the human-readable Messages that were written to the console.
#>
function Invoke-FmTeardown {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id,
        [switch]$Force
    )
    $messages = [System.Collections.Generic.List[string]]::new()
    function local:Fail([int]$code, [string]$text) {
        $messages.Add($text)
        Write-FmLifecycleStdErr $text
        return [pscustomobject]@{ ExitCode = $code; Messages = @($messages) }
    }
    function local:Say([string]$text) {
        $messages.Add($text)
        [Console]::Out.WriteLine($text)
    }

    if (-not (Test-FmLifecycleTaskIdPathSafe -Id $Id)) {
        return (Fail 2 'error: invalid teardown request')
    }
    $paths = Get-FmLifecyclePaths
    $state = $paths.State
    $meta = Join-Path $state "$Id.meta"
    $controlLock = Join-Path $state ".control-$Id.lock"

    if (-not (Enter-FmTeardownLock -LockPath $controlLock)) {
        return (Fail 1 "error: another lifecycle action is already running for task $Id; nothing was changed")
    }
    try {
        if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) {
            return (Fail 1 "error: no meta for task $Id at $meta")
        }

        $kind = Get-FmLifecycleMetaValue -Path $meta -Key 'kind'
        if (-not $kind) { $kind = 'ship' }
        $mode = Get-FmLifecycleMetaValue -Path $meta -Key 'mode'
        if (-not $mode) { $mode = 'no-mistakes' }
        $backend = Get-FmLifecycleMetaValue -Path $meta -Key 'backend'
        if (-not $backend) { $backend = 'tmux' }
        $worktree = Get-FmLifecycleMetaValue -Path $meta -Key 'worktree'
        $project = Get-FmLifecycleMetaValue -Path $meta -Key 'project'
        $prUrl = Get-FmLifecycleMetaValue -Path $meta -Key 'pr'
        $taskTmp = Get-FmLifecycleMetaValue -Path $meta -Key 'tasktmp'
        $target = Get-FmLifecycleMetaValue -Path $meta -Key 'window'
        if (-not $target) { $target = Get-FmLifecycleMetaValue -Path $meta -Key 'terminal' }

        # Fail closed on every task shape whose destructive machinery is not in
        # this module: refusing preserves the work and the records for a rerun
        # under the POSIX firstmate, while a partial teardown would not.
        if (Get-FmLifecycleMetaValue -Path $meta -Key 'remote_host') {
            return (Fail 1 "REFUSED: task $Id is a remote-placed secondmate; its retirement is not part of the Windows lifecycle module. Retire it from the home that owns its route.")
        }
        if ($kind -eq 'secondmate') {
            return (Fail 1 "REFUSED: task $Id is a secondmate home; retiring a home (child work inventory, home removal, registry entry) is not part of the Windows lifecycle module.")
        }
        if ($backend -eq 'orca' -or $backend -eq 'herdr') {
            return (Fail 1 "REFUSED: task $Id runs on the $backend backend, whose worktree and pane lifecycle is not part of the Windows lifecycle module; nothing was changed.")
        }

        # Scout carve-out: the worktree is declared scratch and the report is the
        # work product, so teardown proceeds only once the report exists AND the
        # shared unresolved-decision completion gate passes.
        if ($kind -eq 'scout' -and -not $Force) {
            $report = Join-Path (Join-Path $paths.Data $Id) 'report.md'
            if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
                [void](Fail 1 "REFUSED: scout task $Id has no report at $report.")
                return (Fail 1 'The report is the work product. Have the crewmate write it, or use -Force after explicit discard approval.')
            }
            $verifier = Get-Command -Name 'Test-FmDecisionHoldVerified' -ErrorAction SilentlyContinue
            if (-not $verifier) {
                [void](Fail 1 "REFUSED: scout task $Id cannot be checked against the unresolved-decision completion gate; no decision-hold verifier is available in this module.")
                return (Fail 1 'Inventory its report and any visual review through the decision-hold gate, or use -Force after explicit discard approval.')
            }
            if (-not (& $verifier -Id $Id)) {
                [void](Fail 1 "REFUSED: scout task $Id has not passed the unresolved-decision completion gate.")
                return (Fail 1 'Inventory its report and any visual review before teardown.')
            }
        }

        # The landed-work test. Everything below this point is destructive.
        if ($worktree -and (Test-Path -LiteralPath $worktree -PathType Container) -and -not $Force) {
            $safetyArgs = @{
                WorktreePath = $worktree
                ProjectPath  = $project
                Kind         = $kind
                Mode         = $mode
                PrUrl        = $prUrl
            }
            $safety = Test-FmTeardownSafety @safetyArgs
            if ($safety.Code -eq $script:FmTeardownSafetyLockBlocked) {
                $cleared = Clear-FmTeardownStaleSafetyLock -WorktreePath $worktree
                if (-not $cleared) {
                    foreach ($m in $safety.Messages) { $messages.Add($m) }
                    return [pscustomobject]@{ ExitCode = 1; Messages = @($messages) }
                }
                $safety = Test-FmTeardownSafety @safetyArgs
            }
            foreach ($m in $safety.Messages) { $messages.Add($m) }
            if ($safety.Code -ne 0) {
                return [pscustomobject]@{ ExitCode = 1; Messages = @($messages) }
            }
        }

        if (-not $PSCmdlet.ShouldProcess("task $Id", 'tear down')) {
            return [pscustomobject]@{ ExitCode = 0; Messages = @($messages) }
        }

        # Every landed-work refusal has now passed (or -Force skipped it).
        # Conclude a run this task's own worktree still owns before the worktree
        # goes away, so it cannot sit parked at a gate no worker will ever answer.
        Stop-FmTaskNoMistakesRun -WorktreePath $worktree

        if ($worktree -and (Test-Path -LiteralPath $worktree -PathType Container)) {
            if (-not (Get-Command -Name 'treehouse' -CommandType Application -ErrorAction SilentlyContinue)) {
                return (Fail 1 "error: treehouse is not available; worktree $worktree was left in place and no task record was removed")
            }
            $branch = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $worktree 'rev-parse' '--abbrev-ref' 'HEAD')
            if ($branch -and $branch -ne 'HEAD') {
                if (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $worktree -Arguments @('checkout', '--detach', '-q'))) {
                    # -Arguments explicitly: a bare -D would bind to the -Debug common parameter.
                    [void](Invoke-FmGit -RepoPath $worktree -Arguments @('branch', '-D', $branch))
                }
            }
            # Drop our hook files so a reused pool worktree cannot fire signals
            # for a dead task.
            foreach ($hook in @('.claude/settings.local.json', '.opencode/plugins/fm-turn-end.js', '.fm-grok-turnend', '.fm-kimi-turnend')) {
                $hookPath = Join-Path $worktree $hook
                Remove-Item -LiteralPath $hookPath -Force -ErrorAction SilentlyContinue
            }
            $postCheck = $null
            if (-not $Force -and $kind -ne 'scout') {
                $postCheck = {
                    (Test-FmTeardownSafety -WorktreePath $worktree -ProjectPath $project -Kind $kind -Mode $mode -PrUrl $prUrl).Code -eq 0
                }.GetNewClosure()
            }
            $returnCode = Invoke-FmTeardownWorktreeReturn -WorktreePath $worktree -WorkingDirectory $project -Label 'worktree' -PostCleanupCheck $postCheck
            if ($returnCode -ne 0) {
                return (Fail 1 "error: treehouse return failed for worktree $worktree; teardown aborted")
            }
        }

        Close-FmTaskEndpointIfAvailable -Backend $backend -Target $target -Id $Id

        if ($taskTmp) { Remove-Item -LiteralPath $taskTmp -Recurse -Force -ErrorAction SilentlyContinue }

        if (-not (Remove-FmTaskPrPollArtifact -StatePath $state -Id $Id)) {
            return [pscustomobject]@{ ExitCode = 1; Messages = @($messages) }
        }

        foreach ($leaf in @(
                "$Id.status", "$Id.turn-ended", "$Id.meta", "$Id.pi-ext.ts",
                "$Id.grok-turnend-token", "$Id.kimi-turnend-token",
                "$Id.muse-session", "$Id.muse-session-current",
                ".$Id.open-decisions-cursor",
                "$Id.control-relaunch", "$Id.control-relaunch.meta-prior",
                "$Id.control-relaunch.brief-prior", "$Id.control-relaunch.note")) {
            Remove-Item -LiteralPath (Join-Path $state $leaf) -Force -ErrorAction SilentlyContinue
        }

        Say "teardown $Id complete (window $target, worktree $worktree)"
        Say (Get-FmBacklogRefreshReminder -Id $Id -Kind $kind -Mode $mode -PrUrl $prUrl -DataPath $paths.Data -ConfigPath $paths.Config)
        return [pscustomobject]@{ ExitCode = 0; Messages = @($messages) }
    } finally {
        Exit-FmTeardownLock -LockPath $controlLock
    }
}
