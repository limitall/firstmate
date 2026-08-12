#requires -Version 7.0
<#
    Public/FmGuard.ps1 - the two supervision guards.
    Ports of bin/fm-guard.sh (pull, warns) and bin/fm-turnend-guard.sh (push,
    can block a turn).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-FmGuard {
    <#
        .SYNOPSIS
        Warn - loudly and once per episode - when supervision has lapsed.

        .DESCRIPTION
        Port of bin/fm-guard.sh. Called by supervision scripts, by the wake drain
        after it empties queued wakes, and by session start in read-only advisory
        mode when session-lock ownership was not verified.

        Always returns 0. The guard warns; it never blocks. That is why every
        banner carries the continue line: the guarded operation still runs.

        Health is MODEL-AWARE here (unlike the turn-end guard): under the Claude
        Stop auto-arm model the watcher runs only between turns, so mid-turn a
        fresh beacon with no live watcher is healthy and only a stale beacon is a
        real lapse. The banner names the true failing condition rather than a
        generic "watcher down".

        .PARAMETER ReadOnly
        The calling session could not verify fleet-lock ownership: report the
        lapse, never repair it, and never mutate episode state.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [switch]$ReadOnly,
        [hashtable]$Context
    )
    if (-not $Context) { $Context = Get-FmWakeContext }
    $state = $Context.State
    $config = Get-FmEnvValue 'FM_CONFIG_OVERRIDE'
    if (-not $config) { $config = Join-Path $Context.Home 'config' }
    $grace = Get-FmGuardGrace
    $watchPath = Get-FmWatchPath -Context $Context
    $continueLine = Get-FmEnvValue 'FM_GUARD_CONTINUE_LINE'
    if (-not $continueLine) {
        $continueLine = 'This is a supervision warning only; the guarded operation WILL still run.'
    }
    if (-not $ReadOnly) {
        $env = Get-FmEnvValue 'FM_GUARD_READ_ONLY'
        if ($env -in @('1', 'true', 'TRUE', 'yes', 'YES')) { $ReadOnly = [switch]$true }
    }

    # Worktree tangle first, and independent of in-flight work: if a crewmate's
    # branch landed in the PRIMARY checkout instead of its own worktree, the
    # primary is stranded on a feature branch. Surface it on the very next fleet
    # action. Detached HEAD (linked worktrees, secondmate homes) never trips it.
    $tangleBranch = Invoke-FmSeam -Name 'Get-FmPrimaryTangleBranch' -Arguments @($Context.Root) -Default ''
    if ($tangleBranch) {
        $tangleDefault = Invoke-FmSeam -Name 'Get-FmDefaultBranch' -Arguments @($Context.Root) -Default 'main'
        $lines = @(
            "●$script:FmGuardRule",
            '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH',
            ("●  {0} is on '{1}', not its default branch '{2}'." -f $Context.Root, $tangleBranch, $tangleDefault),
            '●  A crewmate likely branched/committed in the primary instead of its own worktree.',
            ("●  The work is SAFE on the '{0}' ref." -f $tangleBranch))
        if ($ReadOnly) {
            $lines += '●  This read-only session must leave restore work to a session with verified fleet-lock ownership.'
        }
        else {
            $lines += ("●  Restore the primary to '{0}':" -f $tangleDefault)
            $lines += ('●      git -C {0} checkout {1}' -f $Context.Root, $tangleDefault)
            $lines += ("●  then re-validate '{0}' in a proper isolated worktree." -f $tangleBranch)
        }
        $lines += "●$script:FmGuardRule"
        foreach ($l in $lines) { [Console]::Error.WriteLine($l) }
    }

    $status = Get-FmSupervisionStatus -State $state -Grace $grace
    $verdict = Get-FmWatcherSupervisionVerdict -State $state -WatchPath $watchPath -Grace $grace -FmHome $Context.Home

    if (-not $status.Needed) {
        # Nothing rides on the watcher: end the episode so a later work + stale
        # combination is a fresh one even if the beacon is still absent.
        if (-not $ReadOnly) { Clear-FmGuardStaleBanner -State $state }
        return 0
    }

    $queuePending = $status.QueuePending

    if (-not $verdict.Ok) {
        $episodeKey = $verdict.Reason
        $printFull = $false
        if ($ReadOnly) {
            $printFull = -not (Test-FmGuardStaleBannerSeen -State $state -Key $episodeKey)
        }
        elseif (Request-FmGuardStaleBanner -State $state -Key $episodeKey) {
            $printFull = $true
        }

        if ($printFull) {
            $fix = Get-FmSupervisionRepairLine -Options @{
                ReadOnly     = [bool]$ReadOnly
                Afk          = [System.IO.File]::Exists((Join-Path $state '.afk'))
                XMode        = [System.IO.File]::Exists((Join-Path $config 'x-mode.env'))
                QueuePending = [bool]$queuePending
                RepairLine   = $true
            }
            if ($verdict.Reason -eq 'no-watcher') {
                $cause = "no live watcher process holds this home lock (last beat: $($status.BeaconDesc))"
            }
            else {
                $cause = "no watcher has a fresh beacon (last beat: $($status.BeaconDesc), grace ${grace}s)"
            }
            $lines = @("●$script:FmGuardRule", '●  WATCHER DOWN - SUPERVISION IS OFF')
            if ($status.InFlight -gt 0) {
                $lines += ('●  {0} task(s) in flight, but {1}.' -f $status.InFlight, $cause)
            }
            elseif ($status.Sources -gt 0) {
                $lines += ('●  {0} process-event source(s) registered, but {1}.' -f $status.Sources, $cause)
            }
            else {
                $lines += ('●  X-mode relay polling needs supervision, but {0}.' -f $cause)
            }
            if ($ReadOnly) {
                $lines += '●  This read-only session should report the lapse, not repair it.'
            }
            else {
                $lines += '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.'
            }
            $lines += "●  $continueLine"
            $lines += "●  $fix"
            $lines += "●$script:FmGuardRule"
            foreach ($l in $lines) { [Console]::Error.WriteLine($l) }
        }
        else {
            [Console]::Error.WriteLine(
                "WARNING: watcher still down (same stale episode; last beat: $($status.BeaconDesc), grace ${grace}s) - full banner already printed this episode.")
        }
    }
    else {
        # Healthy again while work is still in flight: end the episode so a later
        # restale re-prints the full banner.
        if (-not $ReadOnly) { Clear-FmGuardStaleBanner -State $state }
    }

    # Queued wakes are an INDEPENDENT hazard: warn whenever they are pending,
    # even with a live watcher. The banner dedup never suppresses this.
    if ($queuePending) {
        if ($ReadOnly) {
            [Console]::Error.WriteLine('WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership.')
        }
        else {
            [Console]::Error.WriteLine('WARNING: queued wakes pending - drain them with bin/fm-wake-drain.ps1 before anything else.')
        }
    }
    return 0
}

function Invoke-FmTurnEndGuard {
    <#
        .SYNOPSIS
        Turn-end guard for a firstmate PRIMARY session. Returns the hook exit
        code: 0 allow, 2 block.

        .DESCRIPTION
        Port of bin/fm-turnend-guard.sh. bin/fm-guard.sh is pull-based - it only
        warns when some other supervision script happens to run, so a primary
        that ends a turn without resuming supervision and then runs nothing else
        can sit blind for hours. This one is push-based: verified harness
        turn-end hooks invoke it every time the primary is about to end a turn.

        Scope. The tracked hook file is checked out into EVERY worktree of this
        repo, so this must act only in a genuine primary checkout - the main home
        or a genuinely marked secondmate home, which runs its own primary
        session - and stay a silent fast no-op inside child crew/scout worktrees.

        Loop-guard, default mode: never block twice in the same turn.
        stop_hook_active / stopHookActive true means the current stop already
        follows a block, so allow it.

        Loop-guard, -Claude mode: Claude Code marks EVERY stop after ANY
        stop-hook-driven continuation active, including turns the auto-arm itself
        started, so honouring that flag would re-open the exact blind window this
        guard exists to close. In -Claude mode the flag is ignored and the guard
        instead cooperates with the Stop-owned auto-arm firing on the same event:
          1. a live identity-matched watcher with a fresh beacon allows at once;
          2. otherwise wait briefly for the auto-arm to claim this home or record
             a fresh actionable outcome for this event epoch - either proof
             allows WITHOUT consuming a continuation, so one event epoch yields
             exactly one recovery turn;
          3. only when neither materialises is the auto-arm genuinely absent:
             re-block with the repair banner, bounded to BlockBudget consecutive
             blocks per session (safely below Claude Code's hard 8-consecutive
             override), then allow one loud attended fail-open - and only for an
             already verified failure episode.

        .PARAMETER Payload
        The turn-end hook's JSON payload. An absent, unreadable, or unparseable
        payload FAILS OPEN (return 0): a guard that cannot read its input must
        never block a session.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Payload,
        [switch]$Claude,
        [hashtable]$Context
    )

    if (-not $Context) { $Context = Get-FmWakeContext }
    $state = $Context.State
    $config = Get-FmEnvValue 'FM_CONFIG_OVERRIDE'
    if (-not $config) { $config = Join-Path $Context.Home 'config' }
    $grace = Get-FmGuardGrace
    $watchPath = Get-FmWatchPath -Context $Context

    $syncWaitMs = Get-FmIntEnv -Name 'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS' -Default 800
    $epochFresh = Get-FmIntEnv -Name 'FM_CLAUDE_AUTOARM_EPOCH_FRESH' -Default 15
    if ($epochFresh -eq 0) { $epochFresh = 15 }
    $blockBudget = Get-FmIntEnv -Name 'FM_CLAUDE_TURNEND_BLOCK_BUDGET' -Default 3
    if ($blockBudget -eq 0) { $blockBudget = 3 }

    if ([string]::IsNullOrEmpty($Payload)) { return 0 }

    $json = $null
    try { $json = $Payload | ConvertFrom-Json -ErrorAction Stop }
    catch { return 0 }
    if ($null -eq $json -or $json -isnot [psobject]) { return 0 }

    # Typed camel-case takes precedence when both spellings are present.
    $stopHookActive = $false
    $names = @($json.PSObject.Properties.Name)
    if ($names -contains 'stopHookActive') {
        if ($json.stopHookActive -isnot [bool]) { return 0 }
        $stopHookActive = $json.stopHookActive
    }
    elseif ($names -contains 'stop_hook_active') {
        if ($json.stop_hook_active -isnot [bool]) { return 0 }
        $stopHookActive = $json.stop_hook_active
    }
    if (-not $Claude -and $stopHookActive) { return 0 }

    if (-not (Test-FmPrimaryScope -Root $Context.Root -State $state)) { return 0 }

    $sessionId = 'unknown'
    if ($names -contains 'session_id' -and $json.session_id) { $sessionId = [string]$json.session_id }

    $budgetFile = Join-Path $state '.turnend-claude-blocks'
    $budgetLock = Join-Path $state '.turnend-claude-blocks.lock'
    $ownerLock = Join-Path $state '.claude-autoarm.lock'
    $failureNotice = Join-Path $state '.claude-autoarm-failure-notified'
    $failureAlarm = Join-Path $state '.claude-autoarm-failure-alarmed'
    $epochFile = Join-Path $state '.claude-autoarm-epoch'

    $status = Get-FmSupervisionStatus -State $state -Grace $grace
    if (-not $status.Needed) {
        if (-not [System.IO.File]::Exists($failureNotice) -and $Claude) {
            if (Lock-FmPath -LockDir $budgetLock) {
                try { Remove-FmStateFile -Path $budgetFile }
                finally { Unlock-FmPath -LockDir $budgetLock }
            }
        }
        return 0
    }

    if (Test-FmWatcherHealthy -State $state -WatchPath $watchPath -Grace $grace -FmHome $Context.Home) {
        if (-not $Claude) { return 0 }
        if (Reset-FmFailureEpisode -State $state) { return 0 }
        return 2
    }

    if (-not $Claude) {
        return (Write-FmTurnEndBlock -Status $status -State $state -Config $config -Claude:$false)
    }

    # --- the -Claude cooperative path -------------------------------------
    $script:FmTurnEndCount = 0
    $script:FmTurnEndBudgetInitializedFailure = 0

    $slices = [int][Math]::Floor($syncWaitMs / 100)
    for ($i = 0; $i -le $slices; $i++) {
        if (Test-FmAutoarmOwnsRecovery -State $state -WatchPath $watchPath -FmHome $Context.Home -Grace $grace `
                -OwnerLock $ownerLock -EpochFile $epochFile -FailureNotice $failureNotice `
                -EpochFresh $epochFresh -BudgetFile $budgetFile -BudgetLock $budgetLock -SessionId $sessionId) {
            if (Test-FmWatcherHealthy -State $state -WatchPath $watchPath -Grace $grace -FmHome $Context.Home) {
                if (-not (Reset-FmFailureEpisode -State $state)) { return 2 }
            }
            return 0
        }
        if ($i -lt $slices) { Start-Sleep -Milliseconds 100 }
    }

    # The auto-arm genuinely failed to establish: consume the bounded re-block
    # budget before considering the verified one-time attended fail-open.
    if (-not (Update-FmTurnEndBudget -BudgetFile $budgetFile -BudgetLock $budgetLock `
                -EpochFile $epochFile -FailureNotice $failureNotice -SessionId $sessionId)) {
        return (Write-FmTurnEndBlock -Status $status -State $state -Config $config -Claude:$true)
    }

    $terminal = Test-FmTerminalFailOpen -State $state -WatchPath $watchPath -FmHome $Context.Home -Grace $grace `
        -OwnerLock $ownerLock -BudgetFile $budgetFile -BudgetLock $budgetLock -EpochFile $epochFile `
        -FailureNotice $failureNotice -FailureAlarm $failureAlarm -SessionId $sessionId -BlockBudget $blockBudget
    if ($terminal -eq 0) {
        if ($status.InFlight -gt 0) { $need = "$($status.InFlight) task(s) in flight" }
        elseif ($status.Sources -gt 0) { $need = "$($status.Sources) process-event source(s) registered" }
        else { $need = 'X-mode relay polling active' }
        $message = "FIRSTMATE SUPERVISION IS GENUINELY DOWN: $need, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."
        [Console]::Out.WriteLine((@{ systemMessage = $message } | ConvertTo-Json -Compress))
        return 0
    }
    if ($terminal -eq 2) { return 0 }
    return (Write-FmTurnEndBlock -Status $status -State $state -Config $config -Claude:$true)
}

function Write-FmTurnEndBlock {
    <# block_stop: the bordered banner plus exit status 2. The banner goes to
       stderr because that is the one channel every harness preserves. #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][object]$Status,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Config,
        [switch]$Claude
    )
    $reason = Get-FmSupervisionRepairLine -Options @{
        Afk        = [System.IO.File]::Exists((Join-Path $State '.afk'))
        XMode      = [System.IO.File]::Exists((Join-Path $Config 'x-mode.env'))
        RepairLine = $true
        TurnEnd    = $true
    }
    if ($reason -eq 'Repair missing watcher supervision according to the session-start operating block.') {
        $reason = 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
    }

    $lines = @("●$script:FmGuardRule", '●  TURN WOULD END BLIND - SUPERVISION IS OFF')
    if ($Status.InFlight -gt 0) {
        $lines += ('●  {0} task(s) in flight, but no live watcher holds this home lock (last beat: {1}).' -f $Status.InFlight, $Status.BeaconDesc)
    }
    elseif ($Status.Sources -gt 0) {
        $lines += ('●  {0} process-event source(s) registered, but no live watcher holds this home lock (last beat: {1}).' -f $Status.Sources, $Status.BeaconDesc)
    }
    else {
        $lines += ('●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: {0}).' -f $Status.BeaconDesc)
    }
    if ($Claude) {
        $lines += '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.'
    }
    $lines += "●  $reason"
    $lines += "●$script:FmGuardRule"
    foreach ($l in $lines) { [Console]::Error.WriteLine($l) }
    return 2
}

function Get-FmAutoarmEpochField {
    <#
        Read one field of state/.claude-autoarm-epoch. Matches the bash sed
        forms, including their requirement of a trailing space after the value,
        so a truncated record is not mistaken for a complete one.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$EpochFile,
        [Parameter(Mandatory)][ValidateSet('epoch', 'outcome')][string]$Field
    )
    $text = Get-FmFileTextOrEmpty -Path $EpochFile
    if (-not $text) { return '' }
    $pattern = if ($Field -eq 'epoch') { '^epoch=([0-9]+) ' } else { '^.*outcome=([a-z][a-z-]*) ' }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`n")) {
        $m = [regex]::Match($line, $pattern)
        if ($m.Success) { $found.Add($m.Groups[1].Value) }
    }
    return ($found -join "`n")
}

function Update-FmTurnEndBudget {
    <#
        budget_account_current_epoch. Accounts ONE block against this session's
        bounded budget, but only once per auto-arm event epoch: repeated stops
        inside the same epoch must not burn the budget, or the guard would exhaust
        itself before the auto-arm had a fair chance.

        The first fresh exhausted-failure epoch preserves the bounded progression
        (count 0, flagged initialized); later fresh failed epochs consume it.

        Takes no state directory: like the bash original it reaches every file it
        needs through the explicit budget, lock, epoch and notice paths.
    #>
    param(
        [Parameter(Mandatory)][string]$BudgetFile,
        [Parameter(Mandatory)][string]$BudgetLock,
        [Parameter(Mandatory)][string]$EpochFile,
        [Parameter(Mandatory)][string]$FailureNotice,
        [Parameter(Mandatory)][string]$SessionId
    )
    if (-not (Lock-FmPath -LockDir $BudgetLock)) { return $false }
    try {
        $currentEpoch = Get-FmAutoarmEpochField -EpochFile $EpochFile -Field epoch
        $outcome = Get-FmAutoarmEpochField -EpochFile $EpochFile -Field outcome
        $initialized = 0
        $count = 0
        $oldSession = $null

        if ([System.IO.File]::Exists($BudgetFile)) {
            $lines = @((Get-FmFileTextOrEmpty -Path $BudgetFile) -split "`n")
            $oldSession = if ($lines.Count -ge 1 -and $lines[0].StartsWith('session=')) { $lines[0].Substring(8) } else { $null }
            $oldCount = if ($lines.Count -ge 2 -and $lines[1].StartsWith('count=')) { $lines[1].Substring(6) } else { '' }
            $oldEpoch = if ($lines.Count -ge 3 -and $lines[2].StartsWith('epoch=')) { $lines[2].Substring(6) } else { '' }
            if ($oldCount -notmatch '^[0-9]+$') { $oldCount = '0' }
            if ($oldSession -eq $SessionId) {
                $count = [int]$oldCount
                if (-not ($currentEpoch -and $oldEpoch -eq $currentEpoch)) { $count++ }
            }
        }

        if (-not [System.IO.File]::Exists($BudgetFile) -or $oldSession -ne $SessionId) {
            if ($outcome -in @('failed', 'failed-suppressed') -and [System.IO.File]::Exists($FailureNotice)) {
                $initialized = 1
                $count = 0
            }
            else { $count = 1 }
        }

        try {
            Set-FmFileTextLf -Path $BudgetFile -Text ("session={0}`ncount={1}`nepoch={2}`n" -f $SessionId, $count, $currentEpoch)
        }
        catch { return $false }

        $script:FmTurnEndCount = $count
        $script:FmTurnEndBudgetInitializedFailure = $initialized
        return $true
    }
    finally { Unlock-FmPath -LockDir $BudgetLock }
}

function Test-FmAutoarmOwnsRecovery {
    <#
        autoarm_owns_recovery. Proof that recovery for THIS event epoch is
        already under way, so blocking would consume a continuation for nothing:
        a healthy watcher, a live auto-arm holding the owner lock, or a fresh
        actionable epoch outcome.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][string]$FmHome,
        [Parameter(Mandatory)][int]$Grace,
        [Parameter(Mandatory)][string]$OwnerLock,
        [Parameter(Mandatory)][string]$EpochFile,
        [Parameter(Mandatory)][string]$FailureNotice,
        [Parameter(Mandatory)][int]$EpochFresh,
        [Parameter(Mandatory)][string]$BudgetFile,
        [Parameter(Mandatory)][string]$BudgetLock,
        [Parameter(Mandatory)][string]$SessionId
    )
    if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) { return $true }

    $account = {
        if ([System.IO.File]::Exists($FailureNotice)) {
            $null = Update-FmTurnEndBudget -BudgetFile $BudgetFile -BudgetLock $BudgetLock `
                -EpochFile $EpochFile -FailureNotice $FailureNotice -SessionId $SessionId
        }
    }

    $ownerPid = Get-FmLockPid -LockDir $OwnerLock
    if ((Test-FmProcessAlive $ownerPid) -and (Get-FmLockRole -LockDir $OwnerLock) -eq 'autoarm') {
        & $account
        return $true
    }

    $outcome = Get-FmAutoarmEpochField -EpochFile $EpochFile -Field outcome
    $age = Get-FmPathAge -Path $EpochFile
    switch ($outcome) {
        'rewake' {
            if ($age -lt $EpochFresh) { & $account; return $true }
        }
        'failed' {
            if ($age -lt $EpochFresh -and [System.IO.File]::Exists($FailureNotice)) {
                if (Update-FmTurnEndBudget -BudgetFile $BudgetFile -BudgetLock $BudgetLock `
                        -EpochFile $EpochFile -FailureNotice $FailureNotice -SessionId $SessionId) {
                    if ($script:FmTurnEndBudgetInitializedFailure -eq 1) { return $true }
                }
            }
        }
        'failed-suppressed' {
            if ($age -lt $EpochFresh -and [System.IO.File]::Exists($FailureNotice)) {
                $null = Update-FmTurnEndBudget -BudgetFile $BudgetFile -BudgetLock $BudgetLock `
                    -EpochFile $EpochFile -FailureNotice $FailureNotice -SessionId $SessionId
            }
        }
    }
    return $false
}

function Test-FmTerminalFailOpen {
    <#
        terminal_fail_open. The single, loud, attended fail-open. Returns:
          0  fail open now and print the systemMessage (alarm claimed)
          1  do not fail open - block instead
          2  allow silently (a live auto-arm, or the watcher recovered under us)

        Everything is re-verified under BOTH locks before the alarm is claimed,
        and the alarm file is created exclusively, so a session can announce
        genuine supervision death exactly once.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][string]$FmHome,
        [Parameter(Mandatory)][int]$Grace,
        [Parameter(Mandatory)][string]$OwnerLock,
        [Parameter(Mandatory)][string]$BudgetFile,
        [Parameter(Mandatory)][string]$BudgetLock,
        [Parameter(Mandatory)][string]$EpochFile,
        [Parameter(Mandatory)][string]$FailureNotice,
        [Parameter(Mandatory)][string]$FailureAlarm,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$BlockBudget
    )
    if ($script:FmTurnEndCount -le $BlockBudget) { return 1 }
    if (-not (Test-FmFailureEpisodeVerified -State $State -EpochFile $EpochFile -FailureNotice $FailureNotice)) { return 1 }
    if ([System.IO.File]::Exists($FailureAlarm)) { return 1 }

    if (-not (Lock-FmPath -LockDir $OwnerLock)) {
        $ownerPid = Get-FmLockPid -LockDir $OwnerLock
        if ((Test-FmProcessAlive $ownerPid) -and (Get-FmLockRole -LockDir $OwnerLock) -eq 'autoarm') { return 2 }
        return 1
    }
    try {
        if (-not (Set-FmLockRole -LockDir $OwnerLock -Role terminal-check)) { return 1 }
        if (-not (Lock-FmPath -LockDir $BudgetLock)) { return 1 }
        try {
            $lines = @((Get-FmFileTextOrEmpty -Path $BudgetFile) -split "`n")
            $oldSession = if ($lines.Count -ge 1 -and $lines[0].StartsWith('session=')) { $lines[0].Substring(8) } else { '' }
            $oldCount = if ($lines.Count -ge 2 -and $lines[1].StartsWith('count=')) { $lines[1].Substring(6) } else { '' }
            if ($oldCount -notmatch '^[0-9]+$') { $oldCount = '0' }

            if ((Get-FmLockRole -LockDir $OwnerLock) -ne 'terminal-check') { return 1 }
            if ($oldSession -ne $SessionId) { return 1 }
            if ([int]$oldCount -le $BlockBudget) { return 1 }
            if (-not (Test-FmFailureEpisodeVerified -State $State -EpochFile $EpochFile -FailureNotice $FailureNotice)) { return 1 }
            if ([System.IO.File]::Exists($FailureAlarm)) { return 1 }

            if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) {
                if (-not (Reset-FmFailureEpisode -State $State -Mode held)) { return 1 }
                return 2
            }

            try {
                $stream = [System.IO.File]::Open($FailureAlarm, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                $stream.Dispose()
            }
            catch { return 1 }
            return 0
        }
        finally { Unlock-FmPath -LockDir $BudgetLock }
    }
    finally { Unlock-FmPath -LockDir $OwnerLock }
}

function Test-FmFailureEpisodeVerified {
    <#
        failure_episode_verified. A fail-open is only ever allowed for an
        ALREADY VERIFIED failure episode, and never while away-mode is on: an
        unattended session must keep blocking rather than announce and continue.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$EpochFile,
        [Parameter(Mandatory)][string]$FailureNotice
    )
    if ([System.IO.File]::Exists((Join-Path $State '.afk'))) { return $false }
    if (-not [System.IO.File]::Exists($FailureNotice)) { return $false }
    $outcome = Get-FmAutoarmEpochField -EpochFile $EpochFile -Field outcome
    return ($outcome -in @('failed', 'failed-suppressed'))
}
