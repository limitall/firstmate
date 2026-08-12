#requires -Version 7.0
# FmFleetSync.ps1 - refreshing this home's project clones, ported from
# bin/fm-fleet-sync.sh.
#
# WHAT THE BASH GUARANTEES, AND WHAT IS PRESERVED HERE VERBATIM
#
# Fast-forward the checked-out local default branch to origin/<default> when
# that is safe, and prune local branches whose upstream is gone and that no
# worktree still needs. Nothing is ever forced, stashed, or discarded.
#
# It self-heals exactly ONE drift: a clean, detached HEAD holding no unique
# commits (it is an ancestor of origin/<default>) whose <default> branch is free
# to check out. Re-attaching to an already-published commit strands nothing.
# EVERY other off-default state - a named branch, a detached HEAD with unique
# commits, a dirty tree, a diverged default - may hold real work, so it is left
# untouched and reported as a quantified, loud "STUCK: ... N commits behind ...
# - needs attention" rather than a quiet drift.
#
# The output strings are the contract: a session-start refresh relays these
# lines to the captain and other tooling greps them, so they are byte-for-byte
# the bash strings.
#
# WHAT THE PORT REPLACES
#
# The stale-lock proof. The bash proves a packed-refs.lock stale with lsof (no
# holder) plus mtime age, and treats a missing lsof as "live" - fail-safe.
# Windows has no lsof, and needs none: git holds its lock file OPEN while it
# operates, so an exclusive open succeeding IS direct proof that nobody holds
# it. Combined with the same mtime age that is an equal-or-better proof, and the
# fail-safe direction is preserved - any outcome other than a clean exclusive
# open is read as "live" and the lock is left alone.
#
# WHAT IS DELIBERATELY NOT PORTED
#
# The per-clone timing records (fm-timing-lib.sh). They are inert unless the
# deferred network stage sets FM_TIMING_LOG, and that stage is not in this
# port's scope; recording into a log nothing reads would be shape without
# substance.

Set-StrictMode -Version Latest

# Knob defaults, and the same "an unusable value is not a value" handling the
# bash applies: a non-numeric override falls back rather than removing the bound.
$script:FmFleetSyncLockRetriesDefault = 3
$script:FmFleetSyncLockRetryWaitDefault = 1
$script:FmFleetSyncLockAgeDefault = 30

function Get-FmFleetSyncKnob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][double]$Default,
        [switch]$AllowFraction
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $pattern = if ($AllowFraction) { '^([0-9]+(\.[0-9]*)?|\.[0-9]+)$' } else { '^[0-9]+$' }
    if ($Value -notmatch $pattern) { return $Default }
    [double]$Value
}

# True when git stderr shows the packed-refs.lock "File exists" race. The lock
# path can appear anywhere in the message (git prefixes it with the failed ref
# op), and other "File exists" errors must NOT match.
function Test-FmFleetSyncPackedRefsLockError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match "Unable to create ['`"].*packed-refs\.lock['`"]: File exists")
}

function Get-FmFleetSyncPackedRefsLockPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)

    $lock = Get-FmGitOutput -Directory $Project -Arguments @('rev-parse', '--git-path', 'packed-refs.lock')
    if (-not $lock) { return '' }
    if ([System.IO.Path]::IsPathRooted($lock)) { return $lock }
    $abs = Resolve-FmPhysicalPath -Path $Project
    if (-not $abs) { return '' }
    Join-Path $abs $lock
}

# The Windows replacement for fm-lock-lib.sh's fm_lock_is_provably_stale,
# applied to fleet-sync's one caller. Provably stale means BOTH: old enough, AND
# proof that nothing holds it. This owns only the AGE half; the holder question
# belongs to the teardown area, which published Test-FmTeardownGitLockHeld for
# exactly this - one owner per rule.
#
# THE PLATFORM CAVEAT IS THE WHOLE POINT, and it is why delegating matters
# rather than keeping a local copy. Windows locks open files, so a successful
# exclusive open IS proof that nobody holds the lock. POSIX locking is advisory,
# so the same successful open proves NOTHING - a live git process holding an
# advisory lock lets the open through, and deleting its lock on that basis
# corrupts the ref rewrite the lock exists to protect. The owner answers
# 'unknown' there, and unknown is treated exactly like held. That preserves the
# bash rule: no lsof, no proof, leave it alone.
#
# When the owner is not loaded, the fallback below reaches the SAME verdicts,
# because a fleet refresh must not become more willing to delete a lock just
# because another area is absent.
function Test-FmFleetSyncStaleLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$AgeSeconds
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (([datetime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds -lt $AgeSeconds) { return $false }

    $holderProbe = Resolve-FmSessionCommand -Name 'Test-FmTeardownGitLockHeld'
    if ($holderProbe) {
        $verdict = 'unknown'
        try { $verdict = [string](& $holderProbe -Path $Path) } catch { $verdict = 'unknown' }
        # 'free' is the only verdict that proves staleness. 'held' and 'unknown'
        # both mean leave it; 'absent' means there is nothing left to remove.
        return ($verdict -eq 'free')
    }

    if (-not $IsWindows) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $true
    } catch {
        return $false
    }
}

# Run `git fetch origin --prune --quiet`, tolerating an orphaned
# packed-refs.lock left by a killed ref rewrite. Returns a record carrying Ok,
# the git Output, and any Recovered lines - which go to STDOUT in the bash
# because a session-start refresh discards fleet-sync stderr and would otherwise
# never see that a recovery happened.
function Invoke-FmFleetSyncFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Label
    )

    $retries = [int](Get-FmFleetSyncKnob -Value $env:FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES -Default $script:FmFleetSyncLockRetriesDefault)
    $wait = Get-FmFleetSyncKnob -Value $env:FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS -Default $script:FmFleetSyncLockRetryWaitDefault -AllowFraction
    $age = Get-FmFleetSyncKnob -Value $env:FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS -Default $script:FmFleetSyncLockAgeDefault

    $recovered = @()
    $fetch = { Invoke-FmGit -Directory $Project -Arguments @('fetch', 'origin', '--prune', '--quiet') }

    $result = & $fetch
    if ($result.Ok) {
        return [pscustomobject]@{ Ok = $true; Output = ''; Recovered = @() }
    }
    $output = ($result.StdErr + $result.StdOut)
    if (-not (Test-FmFleetSyncPackedRefsLockError -Text $output)) {
        return [pscustomobject]@{ Ok = $false; Output = $output; Recovered = @() }
    }

    $lock = Get-FmFleetSyncPackedRefsLockPath -Project $Project
    $lockDesc = if ($lock) { $lock } else { 'packed-refs.lock' }
    $attempt = 0
    while ($attempt -lt $retries) {
        $attempt++
        Write-Verbose "$Label`: fetch blocked by packed-refs lock ($lockDesc); waiting ${wait}s and retrying ($attempt/$retries) (owning process may be exiting)"
        Start-Sleep -Seconds $wait
        $result = & $fetch
        if ($result.Ok) {
            $recovered += "$Label`: recovered: packed-refs lock cleared on its own during retry"
            return [pscustomobject]@{ Ok = $true; Output = ''; Recovered = $recovered }
        }
        $output = ($result.StdErr + $result.StdOut)
        if (-not (Test-FmFleetSyncPackedRefsLockError -Text $output)) {
            return [pscustomobject]@{ Ok = $false; Output = $output; Recovered = @() }
        }
    }

    # Retries exhausted and still the lock signature. Clear ONLY if provably stale.
    $lock = Get-FmFleetSyncPackedRefsLockPath -Project $Project
    if ($lock -and (Test-Path -LiteralPath $lock)) {
        if (Test-FmFleetSyncStaleLock -Path $lock -AgeSeconds $age) {
            try {
                Remove-Item -LiteralPath $lock -Force -ErrorAction Stop
            } catch {
                Write-Verbose "$Label`: failed to remove provably-stale packed-refs lock $lock; leaving it in place"
                return [pscustomobject]@{ Ok = $false; Output = $output; Recovered = @() }
            }
            $result = & $fetch
            if ($result.Ok) {
                $recovered += "$Label`: recovered: removed a stale packed-refs lock (no live holder)"
                return [pscustomobject]@{ Ok = $true; Output = ''; Recovered = $recovered }
            }
            return [pscustomobject]@{ Ok = $false; Output = ($result.StdErr + $result.StdOut); Recovered = @() }
        }
        Write-Verbose "$Label`: fetch blocked by packed-refs lock $lock that persisted across $retries retries and is not provably stale (may belong to a live process); leaving it in place"
        return [pscustomobject]@{ Ok = $false; Output = $output; Recovered = @() }
    }
    Write-Verbose "$Label`: fetch packed-refs lock signature persisted across $retries retries even after the lock file disappeared"
    [pscustomobject]@{ Ok = $false; Output = $output; Recovered = @() }
}

function Get-FmFleetSyncFirstLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    $first = @($Text -split "`r?`n")[0]
    ($first -replace '\s+', ' ').Trim()
}

# The branches some worktree of this clone has checked out, as short names.
function Get-FmFleetSyncWorktreeBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)
    @((Get-FmGitOutput -Directory $Project -Arguments @('worktree', 'list', '--porcelain')) -split "`r?`n" |
        Where-Object { $_ -like 'branch refs/heads/*' } |
        ForEach-Object { $_ -replace '^branch refs/heads/', '' })
}

# Delete local branches whose upstream tracking branch is gone - the remote
# branch was deleted, which in this fleet means its PR merged - as long as
# nothing still needs them. Never the checked-out branch, and never a branch
# that still has a worktree (a live or not-yet-torn-down task). "Gone" plus "no
# worktree" already proves the work landed: teardown removes a branch's worktree
# only after confirming the work reached the remote. Deliberately NOT also
# requiring ancestry of origin/<default>: PRs here are squash-merged, so a
# merged branch is never an ancestor and such a check would prune nothing. The
# no-worktree guard is the real safety net.
function Remove-FmFleetSyncGoneBranch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Label
    )

    if ($env:FM_FLEET_PRUNE -eq '0') { return @() }
    if (-not $PSCmdlet.ShouldProcess($Project, 'prune local branches whose upstream is gone')) { return @() }

    $worktreeBranches = Get-FmFleetSyncWorktreeBranch -Project $Project
    $current = Get-FmGitOutput -Directory $Project -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $refs = @((Get-FmGitOutput -Directory $Project -Arguments @('for-each-ref', '--format=%(refname:short) %(upstream:track)', 'refs/heads')) -split "`r?`n")

    $out = @()
    foreach ($refline in $refs) {
        if (-not $refline.Trim()) { continue }
        $parts = $refline.Split(' ', 2)
        $branch = $parts[0]
        $track = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        if ($track -ne '[gone]') { continue }
        if (-not $branch) { continue }
        if ($branch -eq $current) { continue }
        if ($worktreeBranches -contains $branch) { continue }
        if ((Invoke-FmGit -Directory $Project -Arguments @('branch', '-D', '--', $branch)).Ok) {
            $out += "$Label`: pruned $branch"
        }
    }
    $out
}

# Human-readable name for the unsafe state a clone is in, used in the STUCK
# warning: the most informative description available, in the bash's own order.
function Get-FmFleetSyncStuckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentBranch,
        [Parameter(Mandatory)][bool]$Dirty,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$Base
    )

    $state = ''
    if ($CurrentBranch) {
        $state = "branch $CurrentBranch"
    } elseif ($Dirty) {
        $state = 'detached HEAD'
    } elseif (-not (Invoke-FmGit -Directory $Project -Arguments @('merge-base', '--is-ancestor', 'HEAD', $Base)).Ok) {
        $state = 'detached HEAD with unique commits'
    } elseif (Test-FmFleetSyncDefaultCheckedOutElsewhere -Project $Project -DefaultBranch $DefaultBranch) {
        $state = "detached HEAD ($DefaultBranch checked out in another worktree)"
    } elseif (-not (Test-FmFleetSyncLocalDefaultRecoverable -Project $Project -DefaultBranch $DefaultBranch -Base $Base)) {
        $state = "detached HEAD (local $DefaultBranch diverged from $Base)"
    } else {
        $state = 'detached HEAD'
    }
    if ($Dirty) { $state = "$state with uncommitted changes" }
    $state
}

# True when some worktree of this clone has <default> checked out, so we cannot
# attach to it here. The current worktree is detached when this is consulted, so
# any match is necessarily another worktree.
function Test-FmFleetSyncDefaultCheckedOutElsewhere {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$DefaultBranch
    )
    (Get-FmFleetSyncWorktreeBranch -Project $Project) -contains $DefaultBranch
}

function Test-FmFleetSyncLocalDefaultRecoverable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter(Mandatory)][string]$Base
    )
    if (-not (Invoke-FmGit -Directory $Project -Arguments @('rev-parse', '--verify', '--quiet', "$DefaultBranch^{commit}")).Ok) {
        return $true
    }
    (Invoke-FmGit -Directory $Project -Arguments @('merge-base', '--is-ancestor', $DefaultBranch, $Base)).Ok
}

# Loud, quantified report for a clone deliberately left untouched. It states how
# far behind origin/<default> the clone is, so a chronically-stuck clone is
# visibly distinct from a benign one-off skip.
function Get-FmFleetSyncStuckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Base
    )
    $behind = Get-FmGitOutput -Directory $Project -Arguments @('rev-list', '--count', "HEAD..$Base")
    if (-not $behind) { $behind = '?' }
    "$Label`: STUCK: on $State, $behind commits behind $Base - needs attention"
}

# Sync ONE clone. Returns the lines the bash prints on stdout for it, in order.
function Sync-FmProjectClone {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ProjectsDir = '',
        [string]$RegistryPath = ''
    )

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }
    $label = Get-FmProjectLabel -Path $Path -ProjectsDir $ProjectsDir

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @("$label`: skipped: not a directory") }
    if (-not (Invoke-FmGit -Directory $Path -Arguments @('rev-parse', '--is-inside-work-tree')).Ok) {
        return @("$label`: skipped: not a git repo")
    }

    # A local-only project has no remote to refresh from, and its registered
    # posture is the authority on that - not the presence of a remote.
    $mode = 'no-mistakes'
    try {
        $posture = Get-FmProjectMode -Name $label -RegistryPath $RegistryPath -WarningAction SilentlyContinue
        $mode = $posture.Mode
    } catch {
        $mode = 'no-mistakes'
    }
    if ($mode -eq 'local-only') { return @("$label`: skipped: local-only project") }

    if (-not (Invoke-FmGit -Directory $Path -Arguments @('remote', 'get-url', 'origin')).Ok) {
        return @("$label`: skipped: no origin remote")
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'fetch, prune, and fast-forward the default branch')) { return @() }

    $out = @()
    $fetch = Invoke-FmFleetSyncFetch -Project $Path -Label $label
    $out += $fetch.Recovered
    if (-not $fetch.Ok) {
        $reason = 'fetch failed'
        $first = Get-FmFleetSyncFirstLine -Text $fetch.Output
        if ($first) { $reason = "$reason`: $first" }
        return ($out + "$label`: skipped: $reason")
    }

    $out += Remove-FmFleetSyncGoneBranch -Project $Path -Label $label -Confirm:$false

    $default = Get-FmGitDefaultBranch -Directory $Path
    if (-not $default) { return ($out + "$label`: skipped: cannot determine default branch") }
    $base = "origin/$default"
    if (-not (Invoke-FmGit -Directory $Path -Arguments @('rev-parse', '--verify', '--quiet', "$base^{commit}")).Ok) {
        return ($out + "$label`: skipped: $base does not exist")
    }

    $current = Get-FmGitOutput -Directory $Path -Arguments @('symbolic-ref', '--short', 'HEAD')
    $status = Invoke-FmGit -Directory $Path -Arguments @('status', '--porcelain')
    $dirty = (-not $status.Ok) -or [bool]$status.StdOut.Trim()
    $recovered = $false

    if ($current -ne $default) {
        # Off the default branch. Auto-recover only the one unambiguously safe
        # drift; anything else may hold real work and is reported loudly.
        $ancestor = (Invoke-FmGit -Directory $Path -Arguments @('merge-base', '--is-ancestor', 'HEAD', $base)).Ok
        if ((-not $current) -and (-not $dirty) -and $ancestor -and
            (-not (Test-FmFleetSyncDefaultCheckedOutElsewhere -Project $Path -DefaultBranch $default)) -and
            (Test-FmFleetSyncLocalDefaultRecoverable -Project $Path -DefaultBranch $default -Base $base)) {
            if (-not (Invoke-FmGit -Directory $Path -Arguments @('checkout', '--quiet', $default)).Ok) {
                $state = Get-FmFleetSyncStuckState -Project $Path -CurrentBranch $current -Dirty $dirty -DefaultBranch $default -Base $base
                return ($out + (Get-FmFleetSyncStuckReport -Project $Path -Label $label -State $state -Base $base))
            }
            $recovered = $true
            $current = $default
        } else {
            $state = Get-FmFleetSyncStuckState -Project $Path -CurrentBranch $current -Dirty $dirty -DefaultBranch $default -Base $base
            return ($out + (Get-FmFleetSyncStuckReport -Project $Path -Label $label -State $state -Base $base))
        }
    } elseif ($dirty) {
        # On the default branch but with uncommitted changes we must not disturb.
        $state = Get-FmFleetSyncStuckState -Project $Path -CurrentBranch $current -Dirty $dirty -DefaultBranch $default -Base $base
        return ($out + (Get-FmFleetSyncStuckReport -Project $Path -Label $label -State $state -Base $base))
    }

    if (-not (Invoke-FmGit -Directory $Path -Arguments @('rev-parse', '--verify', '--quiet', "$default^{commit}")).Ok) {
        return ($out + "$label`: skipped: local $default does not exist")
    }
    $localRev = Get-FmGitOutput -Directory $Path -Arguments @('rev-parse', $default)
    if (-not $localRev) { return ($out + "$label`: skipped: cannot read local $default") }
    $remoteRev = Get-FmGitOutput -Directory $Path -Arguments @('rev-parse', $base)
    if (-not $remoteRev) { return ($out + "$label`: skipped: cannot read $base") }
    if ($localRev -eq $remoteRev) {
        if ($recovered) { return ($out + "$label`: recovered: re-attached $default (already current)") }
        return ($out + "$label`: already current")
    }
    if (-not (Invoke-FmGit -Directory $Path -Arguments @('merge-base', '--is-ancestor', $default, $base)).Ok) {
        return ($out + (Get-FmFleetSyncStuckReport -Project $Path -Label $label -State "diverged $default" -Base $base))
    }

    $before = Get-FmGitOutput -Directory $Path -Arguments @('rev-parse', '--short', $default)
    if (-not $before) { return ($out + "$label`: skipped: cannot read local $default") }
    $merge = Invoke-FmGit -Directory $Path -Arguments @('merge', '--ff-only', $base)
    if (-not $merge.Ok) {
        $reason = 'fast-forward failed'
        $first = Get-FmFleetSyncFirstLine -Text ($merge.StdErr + $merge.StdOut)
        if ($first) { $reason = "$reason`: $first" }
        return ($out + "$label`: skipped: $reason")
    }
    $after = Get-FmGitOutput -Directory $Path -Arguments @('rev-parse', '--short', $default)
    if (-not $after) {
        return ($out + "$label`: skipped: fast-forward completed but cannot read local $default")
    }
    if ($recovered) { return ($out + "$label`: recovered: re-attached $default, synced $before..$after") }
    $out + "$label`: synced $before..$after"
}
