#requires -Version 7.0
<#
    FmGuard.ps1 - supervision predicates, the liveness beacon, and the guard
    banner machinery. Port of bin/fm-supervision-lib.sh,
    bin/fm-primary-scope-lib.sh, and the shared parts of bin/fm-guard.sh and
    bin/fm-turnend-guard.sh.

    Two guards, deliberately different questions:

      PULL  (Invoke-FmGuard) fires whenever some other supervision command
            happens to run. It uses the MODEL-AWARE verdict, because under the
            Claude Stop auto-arm model the watcher only runs between turns, so
            mid-turn a fresh beacon with no live watcher is the healthy state.
            It warns, it never blocks.

      PUSH  (Invoke-FmTurnEndGuard) fires at the turn boundary, from a verified
            harness turn-end hook, where the auto-arm brings a fresh watcher up.
            It uses the PID-STRICT predicate and can block the turn (exit 2), so
            a primary session cannot end a turn blind.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FmGuardRule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# Turn-end block accounting, set by Update-FmTurnEndBudget and read by the
# terminal fail-open (the COUNT / BUDGET_INITIALIZED_FAILURE globals of the
# bash original).
$script:FmTurnEndCount = 0
$script:FmTurnEndBudgetInitializedFailure = 0

function Update-FmWatcherBeacon {
    <#
        .SYNOPSIS
        Touch this home's watcher liveness beacon.

        .DESCRIPTION
        state/.last-watcher-beat is touched every poll cycle - INCLUDING cycles
        that only absorb benign wakes, because absorbing is the watcher doing its
        job. Guard scripts read its mtime; a stale beacon with work in flight is
        the alarm condition.
    #>
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context) { $Context = Get-FmWakeContext }
    Update-FmFileTimestamp -Path $Context.Beacon
    return $Context.Beacon
}

function Get-FmSupervisionStatus {
    <#
        .SYNOPSIS
        Does this home need supervision, and is its beacon fresh?

        .DESCRIPTION
        fm_supervision_status. Supervision is needed when there is in-flight work
        (any state/<id>.meta), a registered process-to-event source (a wait on an
        external process, which has no task metadata of its own), or an X-mode
        relay poll. Beacon freshness is reported separately - it is an input to
        the two guards' different verdicts, never a verdict itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [int]$Grace = 0
    )
    if ($Grace -le 0) { $Grace = Get-FmGuardGrace }

    $inFlight = 0
    try { $inFlight = @([System.IO.Directory]::GetFiles($State, '*.meta')).Count } catch { $inFlight = 0 }
    $sources = 0
    try { $sources = @([System.IO.Directory]::GetFiles((Join-Path $State 'procevent'), '*.source')).Count } catch { $sources = 0 }

    $xMode = [System.IO.File]::Exists((Join-Path $State 'x-watch.check.sh'))
    $needed = ($inFlight -gt 0 -or $xMode -or $sources -gt 0)

    $beat = Join-Path $State '.last-watcher-beat'
    $beaconDesc = 'never'
    $fresh = $false
    if ([System.IO.File]::Exists($beat)) {
        $m = Get-FmPathMtime -Path $beat
        if ($null -ne $m) {
            $age = (Get-FmUnixTime) - $m
            $beaconDesc = "${age}s ago"
            $fresh = ($age -lt $Grace)
        }
        else { $beaconDesc = 'unknown' }
    }

    return [pscustomobject]@{
        InFlight     = $inFlight
        Sources      = $sources
        Needed       = $needed
        WatcherFresh = $fresh
        BeaconDesc   = $beaconDesc
        QueuePending = (Test-FmNonEmptyFile -Path (Join-Path $State '.wake-queue'))
    }
}

function Test-FmSecondmateHome {
    <#
        fm_root_is_secondmate_home. A genuine secondmate marker is a regular
        (non-symlink) file whose single line is a safe id.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $marker = Join-Path $Root '.fm-secondmate-home'
    try {
        if (-not [System.IO.File]::Exists($marker)) { return $false }
        if ([System.IO.FileInfo]::new($marker).LinkTarget) { return $false }
        $id = (Get-FmFirstLine -Path $marker) -replace '\s', ''
        if (-not $id) { return $false }
        return ($id -match '^[A-Za-z0-9._-]+$')
    }
    catch { return $false }
}

function Test-FmPrimaryScope {
    <#
        fm_primary_scope_matches. Tracked hooks are checked out into EVERY
        worktree of this repo, so the turn-end guard must scope itself at runtime
        to a real primary checkout and stay a silent fast no-op inside child
        crew/scout worktrees.

        A genuinely-marked secondmate home runs its OWN primary firstmate
        session, so it is force-INCLUDED whether it is a linked worktree or a
        plain clone. Only an unmarked checkout falls through to the
        linked-worktree exemption: a task worktree's git-dir lives under the
        parent's .git/worktrees/<name> and differs from the common git-dir, while
        a main checkout has the two equal.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$State
    )
    if (-not (Test-FmSecondmateHome -Root $Root)) {
        # Get-FmGitOutput is the worktree area's shell-free git runner. It
        # reports failure as an EMPTY string, so the emptiness check below is
        # load-bearing: without it two failed reads would compare equal and a
        # non-checkout would scope in as a primary. bash returns 1 here.
        $gitDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--git-dir')
        $commonDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--git-common-dir')
        if (-not $gitDir -or -not $commonDir) { return $false }
        if ($gitDir -ne $commonDir) { return $false }
    }
    if (-not [System.IO.File]::Exists((Join-Path $Root 'AGENTS.md'))) { return $false }
    if (-not [System.IO.Directory]::Exists((Join-Path $Root 'bin'))) { return $false }
    if (-not [System.IO.Directory]::Exists($State)) { return $false }
    return $true
}

# Reading git is the worktree area's job: Get-FmGitOutput / Invoke-FmGit in
# FmWorktree.ps1 run git through Invoke-FmChildProcess with an argv array and no
# shell. This area used to carry its own `& git ... 2>$null` copy under the same
# name, which the dot-source order silently shadowed - see docs/supervision.md.

# --- guard-banner episode dedup ---------------------------------------------

function Get-FmGuardBannerMarkerPath {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$State)
    return (Join-Path $State '.guard-watcher-stale-banner')
}

function Request-FmGuardStaleBanner {
    <#
        fm_guard_claim_stale_banner. $true = this call owns the first
        announcement of the episode and should print the full banner; $false =
        the same episode already announced, so print the one-line reminder.

        The episode key is the qualitative FAILING CONDITION, never the beacon
        mtime: under the auto-arm model a healthy between-turns watcher advances
        that mtime every poll, which used to change the key every turn and
        re-print the full banner.

        Contended past the spin budget deliberately returns $true - staying loud
        beats dropping an alarm.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Key
    )
    $marker = Get-FmGuardBannerMarkerPath -State $State
    $lock = "$marker.lock"

    if ((Get-FmFirstLine -Path $marker) -eq $Key) { return $false }
    for ($i = 0; $i -lt 50; $i++) {
        if (Lock-FmPath -LockDir $lock) {
            try {
                if ((Get-FmFirstLine -Path $marker) -eq $Key) { return $false }
                try { Set-FmFileTextLf -Path $marker -Text ("$Key`n") } catch { }
                return $true
            }
            finally { Unlock-FmPath -LockDir $lock }
        }
        if ((Get-FmFirstLine -Path $marker) -eq $Key) { return $false }
        Start-Sleep -Milliseconds 20
    }
    return $true
}

function Test-FmGuardStaleBannerSeen {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Key
    )
    return ((Get-FmFirstLine -Path (Get-FmGuardBannerMarkerPath -State $State)) -eq $Key)
}

function Clear-FmGuardStaleBanner {
    param([Parameter(Mandatory)][string]$State)
    $marker = Get-FmGuardBannerMarkerPath -State $State
    try { if ([System.IO.File]::Exists($marker)) { [System.IO.File]::Delete($marker) } } catch { }
}

function Get-FmSupervisionRepairLine {
    <#
        The harness-specific repair instruction. Owned by the supervision
        instruction renderer elsewhere in the module; this is the same fallback
        sentence the bash guards use when that renderer cannot be reached, so the
        banner is never emitted without a next action.
    #>
    [OutputType([string])]
    param([hashtable]$Options = @{})
    $line = Invoke-FmSeam -Name 'Get-FmSupervisionInstructions' -Arguments @($Options) -Default $null
    if ($line) { return [string]$line }
    return 'Repair missing watcher supervision according to the session-start operating block.'
}
