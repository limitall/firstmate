#requires -Version 7.0
<#
    Private/FmWatchArm.ps1 - the internals of the watcher arm layer. Native
    PowerShell 7 port of the helper half of bin/fm-watch-arm.sh.

    WHAT THE ARM IS. The watcher (bin/fm-watch.ps1) blocks until it has one
    actionable wake, prints one reason line, and exits. The arm is the layer that
    ESTABLISHES that cycle and then tells the truth about it: it starts one
    watcher as a tracked child and CONFIRMS it, or it attaches to the verified
    healthy cycle that already exists. It never reports a cycle it did not
    verify, and it never returns a clean empty success - docs/supervision.md
    "The arm layer" owns the full contract.

    HOME SCOPE IS A SAFETY BOUNDARY, NOT A DETAIL. Several firstmate homes run
    the same bin/fm-watch.ps1 on one machine, so nothing here may match a watcher
    by process name, image path, or command line: every decision is taken from
    THIS home's state/.watch.lock, whose fm-home, watcher-path and pid-identity
    fields Test-FmWatcherHealthy compares before anything is believed. The forced
    restart therefore stops exactly the pid that lock records and nothing else,
    which is what AGENTS.md section 8 means by never killing watchers by name.

    WHERE THIS DIFFERS FROM BASH, DELIBERATELY.
      - No signal traps. PowerShell has no trap for TERM, so an arm that is
        killed cannot write its own lifecycle row. The child is instead held in a
        kill-on-close Job Object, so a killed arm still takes its watcher down
        with it - the guarantee the bash trap existed to provide.
      - The lifecycle ledger's `signal=` field is always `none`. Windows has no
        signal half to an exit status; the field is kept so a row written here
        and a row written by bash stay the same shape.
      - `--handling-delivered` and FM_WATCH_PREDECESSOR_ARM_PID successor
        back-linking are NOT ported. Both exist for the Pi, omp and OpenCode
        adapters, and this port dispatches only claude (AGENTS.md section 14).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FmWatchArmSettings {
    <#
        The tunables at the top of bin/fm-watch-arm.sh.

        ConfirmTimeout takes bash's msys default rather than its Linux one on
        purpose: confirming a fresh cycle here costs a pwsh cold start plus a
        module import before the watcher can take the lock and beat, which is the
        same class of cost that made the bash script widen this on Git Bash.

        AttachPollMs is bash's FM_ARM_ATTACH_POLL expressed in milliseconds,
        because that knob is fractional seconds (0.5) and every numeric override
        in this port is an integer.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        Grace             = Get-FmGuardGrace
        ConfirmTimeout    = Get-FmIntEnv -Name 'FM_ARM_CONFIRM_TIMEOUT' -Default 30
        AttachPollMs      = Get-FmIntEnv -Name 'FM_ARM_ATTACH_POLL_MS' -Default 500
        RestartWaitMs     = Get-FmIntEnv -Name 'FM_ARM_RESTART_WAIT_MS' -Default 5000
        CycleLogMaxBytes  = Get-FmIntEnv -Name 'FM_WATCH_CYCLE_LOG_MAX_BYTES' -Default 262144
        CycleLogKeepLines = Get-FmIntEnv -Name 'FM_WATCH_CYCLE_LOG_KEEP_LINES' -Default 1000
    }
}

function ConvertTo-FmWatchArmField {
    <# cycle_clean_field: no field may forge a record boundary, and none may grow
       the bounded ledger without limit. #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $clean = ConvertTo-FmWakeField $Value
    if ($clean.Length -gt 512) { $clean = $clean.Substring(0, 512) }
    return $clean
}

function Get-FmWatchArmWatcherState {
    <#
        The single honesty gate, and the only reading anything in this area acts
        on: a dead pid, a recycled pid, a lock belonging to another home or
        another watcher implementation, and a stale beacon all fail it.
        Test-FmWatcherHealthy owns that predicate - this only adds the identity
        and pid the arm has to keep, which it reads back from the same lock the
        predicate just accepted.

        THE READING MUST BE CONSISTENT, NOT MERELY TRUE. The predicate and this
        read-back are two separate looks at a lock the watcher may release
        between them, and a torn read is not hypothetical: an attached arm
        observed `watcher: attached pid=` with an empty pid, adopted that as its
        cycle, and then could not resolve the delivery record of the cycle it had
        just overwritten - so it reported a failure for a wake that had really
        been delivered. An unreadable pid or identity therefore reports NOT
        healthy. The caller polls, so a lock mid-change costs one more poll; the
        alternative costs a wake.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][int]$Grace
    )

    $healthy = $false
    try {
        $healthy = [bool](Test-FmWatcherHealthy -State $Context.State -WatchPath $WatchPath `
                -Grace $Grace -FmHome $Context.Home)
    }
    catch {
        Write-Debug "watch-arm: the watcher health predicate could not be evaluated, so the cycle counts as unverified: $_"
        $healthy = $false
    }

    $age = Get-FmPathAge -Path $Context.Beacon
    $down = [pscustomobject]@{ Healthy = $false; ProcessId = ''; Identity = ''; BeaconAge = $age }
    if (-not $healthy) { return $down }

    $recorded = Get-FmLockPid -LockDir $Context.WatchLock
    $identity = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'pid-identity')
    if ($recorded -notmatch '^[0-9]+$' -or -not $identity) { return $down }

    return [pscustomobject]@{
        Healthy   = $true
        ProcessId = $recorded
        Identity  = $identity
        BeaconAge = $age
    }
}

function Wait-FmWatchArmWatcherState {
    <#
        wait_for_healthy_successor. Give a successor the same bounded window a
        fresh child gets: an adapter-owned continuation normally wins at once,
        but process close and lock publication can cross, and a false failure
        there would report a healthy fleet as unsupervised.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][int]$Grace,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    # One extra second, as bash adds, so a one-second budget cannot collapse to
    # milliseconds when the call lands just before a boundary.
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds + 1)
    while ($true) {
        $state = Get-FmWatchArmWatcherState -Context $Context -WatchPath $WatchPath -Grace $Grace
        if ($state.Healthy) { return $state }
        if ([datetime]::UtcNow -ge $deadline) { return $state }
        Start-Sleep -Milliseconds 200
    }
}

function Get-FmWatchArmLockSnapshot {
    <# lock_snapshot: who the lock names right now, for the lifecycle ledger. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $recorded = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'pid')
    $identity = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'pid-identity')
    if (-not $recorded) { $recorded = 'none' }
    if (-not $identity) { $identity = 'none' }
    return ('pid:{0}|identity:{1}' -f (ConvertTo-FmWatchArmField $recorded), (ConvertTo-FmWatchArmField $identity))
}

function New-FmWatchArmCycle {
    <# cycle_begin: open one observed cycle for the lifecycle ledger. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory bookkeeping record for the caller; it changes nothing outside the returned hashtable.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherPid,
        [Parameter(Mandatory)][ValidateSet('started', 'attached')][string]$Origin,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Identity
    )
    $recorded = if ([string]::IsNullOrEmpty($WatcherPid)) { 'none' } else { $WatcherPid }
    $recordedIdentity = if ([string]::IsNullOrEmpty($Identity)) { 'none' } else { $Identity }
    return @{
        Active     = $true
        WatcherPid = $recorded
        Identity   = $recordedIdentity
        Origin     = $Origin
        StartedAt  = Get-FmUnixTime
        LockBefore = Get-FmWatchArmLockSnapshot -Context $Context
    }
}

function Add-FmWatchArmCycleRecord {
    <#
        cycle_log_append. One tab-separated row per OBSERVED cycle in
        state/.watch-cycle-exits.log, the arm layer's own bounded ledger.

        This is diagnostic evidence, never a supervision dependency: every write
        is bounded and best-effort, because an observability failure must not
        stall an otherwise healthy watcher cycle. state/.watch-triage.log is the
        watcher's absorbed-wake log and is never written here.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cycle,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Successor
    )
    if (-not $Cycle.Active) { return }
    $Cycle.Active = $false

    $log = Join-Path $Context.State '.watch-cycle-exits.log'
    $lock = Join-Path $Context.State '.watch-cycle-exits.lock'
    $attempt = 0
    while (-not (Lock-FmPath -LockDir $lock)) {
        if ($attempt -ge 20) { return }
        Start-Sleep -Milliseconds 20
        $attempt++
    }
    try {
        $code = if ([string]::IsNullOrEmpty($ExitCode)) { 'unknown' } else { $ExitCode }
        $next = if ([string]::IsNullOrEmpty($Successor)) { 'none' } else { $Successor }
        $fields = @(
            'arm_pid=' + (Get-FmCurrentProcessId)
            'watcher_pid=' + (ConvertTo-FmWatchArmField $Cycle.WatcherPid)
            'origin=' + (ConvertTo-FmWatchArmField $Cycle.Origin)
            'started_at=' + $Cycle.StartedAt
            'ended_at=' + (Get-FmUnixTime)
            'exit_code=' + (ConvertTo-FmWatchArmField $code)
            # Windows has no signal half to an exit status. The field is kept so
            # a row written here and one written by bash have the same shape.
            'signal=none'
            'reason=' + (ConvertTo-FmWatchArmField $Reason)
            'beacon_age=' + (Get-FmPathAge -Path $Context.Beacon)
            'lock_before=' + (ConvertTo-FmWatchArmField $Cycle.LockBefore)
            'lock_after=' + (ConvertTo-FmWatchArmField (Get-FmWatchArmLockSnapshot -Context $Context))
            'successor=' + (ConvertTo-FmWatchArmField $next)
        )
        Add-FmWakeQueueBytes -Path $log -Record (($fields -join "`t") + "`n")

        $info = [System.IO.FileInfo]::new($log)
        if ($info.Exists -and $info.Length -ge $Settings.CycleLogMaxBytes) {
            $lines = @(Get-FmWakeQueueLines -Path $log)
            $keepCount = [Math]::Min($Settings.CycleLogKeepLines, $lines.Count)
            $keep = @($lines[($lines.Count - $keepCount)..($lines.Count - 1)]) |
                Where-Object { $_ -like 'arm_pid=*' }
            Set-FmFileTextLf -Path $log -Text (($keep -join "`n") + "`n")
        }
    }
    catch { Write-Debug "watch-arm: lifecycle ledger write failed (absorbed, the ledger is never relied on): $_" }
    finally { Unlock-FmPath -LockDir $lock }
}

function Get-FmWatchArmDeliveredReason {
    <#
        close_unobserved_cycle's read half. An arm that attached holds no handle
        on the watcher's stdout, so when that cycle ends it cannot have read the
        reason line itself. The watcher records every delivered reason with its
        pid AND its process identity before releasing the lock
        (Publish-FmWatchDelivery), so a matching record lets this arm report the
        wake that really was delivered. The identity half is what stops a
        recycled pid or an unrelated producer from satisfying the match.

        Returns '' when nothing matches, which is the only case that may be
        reported as a failed cycle.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WatcherPid,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Identity
    )
    if (-not $WatcherPid -or $WatcherPid -eq 'none') { return '' }
    if (-not $Identity -or $Identity -eq 'none') { return '' }

    $log = Join-Path $Context.State '.watch-deliveries.log'
    $lock = Join-Path $Context.State '.watch-deliveries.lock'
    $attempt = 0
    while (-not (Lock-FmPath -LockDir $lock)) {
        if ($attempt -ge 20) { return '' }
        Start-Sleep -Milliseconds 20
        $attempt++
    }
    try {
        if (-not [System.IO.File]::Exists($log)) { return '' }
        $wanted = ConvertTo-FmWakeField $Identity
        $reason = ''
        $lines = Get-FmWakeQueueLines -Path $log
        foreach ($line in $lines) {
            $parts = $line -split "`t"
            if ($parts.Count -lt 3) { continue }
            if ($parts[0] -ne [string]$WatcherPid) { continue }
            if ($parts[1] -ne $wanted) { continue }
            # Last record wins, exactly as the bash reader's loop does.
            $reason = ($parts[2..($parts.Count - 1)] -join "`t")
        }
        return $reason
    }
    catch {
        Write-Debug "watch-arm: the delivery ledger could not be read, so this cycle stays unexplained: $_"
        return ''
    }
    finally { Unlock-FmPath -LockDir $lock }
}

function Start-FmWatchArmChild {
    <#
        Fork the watcher as a TRACKED child: this arm waits on it, and it is
        assigned to a kill-on-close Job Object so killing the arm tears the
        watcher down with it rather than orphaning a second cycle. That is the
        whole reason the arm never backgrounds the watcher and detaches.

        The child is started -NonInteractive with its stdin closed. A hook
        collects output through a pipe, so a child that stopped to ask something
        would ask it where nobody can answer.

        Returns a record whose Started says whether the process exists; Error
        carries the reason when it does not, and nothing is ever reported as
        running on the strength of a failed start.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starting the watcher IS the arm''s question; a declined start would be indistinguishable from a watcher that failed to come up.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][hashtable]$Settings
    )

    $result = [pscustomobject]@{
        Started = $false
        Process = $null
        Job     = [IntPtr]::Zero
        OutTask = $null
        ErrTask = $null
        Error   = ''
    }

    if (-not [System.IO.File]::Exists($WatchPath)) {
        $result.Error = "the watcher entry point is missing at $WatchPath"
        return $result
    }

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($pwshPath)) { $pwshPath = 'pwsh' }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $WatchPath)) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.WorkingDirectory = $Context.Root
    # Pin what this arm resolved rather than letting the child re-resolve it: the
    # lock's watcher-path and fm-home fields are compared byte for byte, and the
    # grace the child judges its own staleness by must be the grace the arm just
    # judged the fleet by (docs/turnend-guard.md, "Guard grace and the poll cadence").
    $psi.Environment['FM_ROOT'] = $Context.Root
    $psi.Environment['FM_HOME'] = $Context.Home
    $psi.Environment['FM_STATE_OVERRIDE'] = $Context.State
    $psi.Environment['FM_GUARD_GRACE'] = [string]$Settings.Grace

    $useJob = Test-FmJobObjectSupport
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        if ($useJob) {
            $result.Job = New-FmBoundedJob
            if ($result.Job -eq [IntPtr]::Zero) { $useJob = $false }
        }
        $null = $proc.Start()
    }
    catch {
        $proc.Dispose()
        if ($result.Job -ne [IntPtr]::Zero) { $null = [Firstmate.JobCustody]::Close($result.Job); $result.Job = [IntPtr]::Zero }
        $result.Error = "the watcher could not be started: $($_.Exception.Message)"
        return $result
    }

    if ($useJob -and $result.Job -ne [IntPtr]::Zero) {
        # Assigned immediately after start, so anything the watcher spawns is
        # inside the job and shares its fate.
        if (-not [Firstmate.JobCustody]::Assign($result.Job, $proc.Id)) {
            $null = [Firstmate.JobCustody]::Close($result.Job)
            $result.Job = [IntPtr]::Zero
        }
    }

    # Both pipes are read asynchronously before any wait: a child that filled a
    # pipe buffer would otherwise block for ever and hang this arm with it.
    $result.OutTask = $proc.StandardOutput.ReadToEndAsync()
    $result.ErrTask = $proc.StandardError.ReadToEndAsync()
    try { $proc.StandardInput.Close() } catch { Write-Debug "watch-arm: closing the child's stdin failed: $_" }

    $result.Process = $proc
    $result.Started = $true
    return $result
}

function Stop-FmWatchArmChild {
    <# Tear down a child this arm owns. Absent, already-exited, and unkillable
       all resolve to the same thing here: nothing is reported as supervised. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Cleanup for a process this function''s caller started and owns; the decision to stop was already taken by that caller.')]
    param([Parameter(Mandatory)][pscustomobject]$Child)

    if ($Child.Process) {
        try {
            if (-not $Child.Process.HasExited) {
                if ($Child.Job -ne [IntPtr]::Zero) { $null = [Firstmate.JobCustody]::Terminate($Child.Job) }
                else { $Child.Process.Kill($true) }
                $null = $Child.Process.WaitForExit(5000)
            }
        }
        catch { Write-Debug "watch-arm: stopping the watcher child failed (it had probably already exited): $_" }
    }
}

function Close-FmWatchArmChild {
    <# Release the handles. Closing the job handle is also what reaps anything
       still inside it, so this runs only once the child has been waited on. #>
    param([Parameter(Mandatory)][pscustomobject]$Child)
    if ($Child.Process) {
        try { $Child.Process.Dispose() } catch { Write-Debug "watch-arm: disposing the watcher child failed: $_" }
        $Child.Process = $null
    }
    if ($Child.Job -ne [IntPtr]::Zero) {
        $null = [Firstmate.JobCustody]::Close($Child.Job)
        $Child.Job = [IntPtr]::Zero
    }
}

function Get-FmWatchArmChildOutput {
    <#
        Split a finished child's captured streams into what the arm may REPORT
        and what only belongs in the triage log.

        Stdout is the watcher's reason line and is passed through verbatim.
        Stderr is diagnostic, and only its `watcher:` lines are surfaced - the
        watcher writes every diagnosis it owns with that prefix, and passing
        anything else through could let unrelated child noise be read as a wake
        reason, which is the one mistake this layer must never make.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Child)

    $out = ''
    $err = ''
    try { if ($Child.OutTask) { $out = $Child.OutTask.GetAwaiter().GetResult() } } catch { Write-Debug "watch-arm: reading the child's stdout failed: $_" }
    try { if ($Child.ErrTask) { $err = $Child.ErrTask.GetAwaiter().GetResult() } } catch { Write-Debug "watch-arm: reading the child's stderr failed: $_" }

    $stdout = @(($out -split "`r?`n") | Where-Object { $_ -ne '' })
    $stderrAll = @(($err -split "`r?`n") | Where-Object { $_ -ne '' })
    return [pscustomobject]@{
        Lines    = @($stdout) + @($stderrAll | Where-Object { $_ -like 'watcher:*' })
        Absorbed = @($stderrAll | Where-Object { $_ -notlike 'watcher:*' })
    }
}

function Test-FmWatchArmActionable {
    <# The reason-line grammar bin/fm-watch.ps1 exits on, and the same one the
       Stop auto-arm classifies its close by. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line)
    foreach ($text in $Line) {
        if ($text -match '^(signal:|stale:|check:|heartbeat($|:))') { return $true }
    }
    return $false
}

function Get-FmWatchArmReasonType {
    <# watch_output_reason_type, for the lifecycle ledger's reason field. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Line)
    foreach ($text in $Line) {
        if ($text -like 'signal:*') { return 'actionable-signal' }
        if ($text -like 'stale:*') { return 'actionable-stale' }
        if ($text -like 'check:*') { return 'actionable-check' }
        if ($text -match '^heartbeat($|:)') { return 'actionable-heartbeat' }
    }
    return 'none'
}

function Clear-FmWatchArmStaleLock {
    <#
        clear_stale_recorded_watcher_lock. A forced restart found a LIVE pid on
        this home's watch lock that is not this home's watcher: the pid was
        recycled onto something else, or the lock was left by another
        implementation.

        Three fields must agree before anything is removed - the lock must name
        THIS home, THIS watcher path, and some recorded identity - so a lock
        belonging to a sibling home is left exactly as it was found, and the pid
        behind it is never signalled either way. The removal publishes watcher
        downtime first, because a lock disappearing with no recovery generation
        would let the queue be presented as if no supervision gap had happened.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal step of the forced restart the caller already decided on; Invoke-FmWatchArm owns that decision.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath
    )
    $lockHome = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'fm-home')
    $lockPath = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'watcher-path')
    $lockIdentity = Get-FmFirstLine -Path (Join-Path $Context.WatchLock 'pid-identity')
    if ($lockHome -ne $Context.Home) { return [pscustomobject]@{ Attempted = $false; Cleared = $false } }
    if ($lockPath -ne $WatchPath) { return [pscustomobject]@{ Attempted = $false; Cleared = $false } }
    if (-not $lockIdentity) { return [pscustomobject]@{ Attempted = $false; Cleared = $false } }

    $cleared = [bool](Invoke-FmRecoveryTransition -Marker $Context.RecoveryMarker -Action 'clear-stale-lock' `
            -Target $Context.WatchLock -Value 'downtime')
    return [pscustomobject]@{ Attempted = $true; Cleared = $cleared }
}

function Stop-FmWatchArmRecordedWatcher {
    <#
        The forced restart's stop half, and the narrowest thing that can work:
        it reads the pid THIS home's lock records, proves through
        Test-FmWatcherLockMatchesPid that the pid is still this home's watcher,
        and stops only that. A broad match on the process name or command line
        would find every sibling home's watcher on this machine and take them
        down too - AGENTS.md section 8 forbids exactly that, and it is why no
        enumeration of processes happens anywhere in this area.

        Returns Stopped when a matched watcher was stopped, Foreign when a live
        pid held the lock but was not this home's watcher, and None otherwise.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The forced restart IS the caller''s decision; Invoke-FmWatchArm owns it and a declined stop would silently degrade --restart into an attach.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $recorded = Get-FmLockPid -LockDir $Context.WatchLock
    if ($recorded -notmatch '^[0-9]+$') { return 'None' }
    if (-not (Test-FmProcessAlive $recorded)) { return 'None' }
    if (-not (Test-FmWatcherLockMatchesPid -State $Context.State -WatchPath $WatchPath `
                -ProcessId $recorded -FmHome $Context.Home)) {
        return 'Foreign'
    }

    try {
        $target = Get-Process -Id ([int]$recorded) -ErrorAction Stop
        # Windows has no TERM. The watcher's own cleanup therefore does not run,
        # which is safe by construction: the lock it leaves names a dead pid, and
        # Lock-FmPath's stale-owner recovery publishes downtime before evicting
        # it, so the replacement cycle still starts from a recorded gap.
        $target.Kill($true)
    }
    catch {
        Write-Debug "watch-arm: stopping this home's recorded watcher failed; the wait below reports the real verdict: $_"
    }

    # Wait for it to actually go, so the fresh watcher either takes a released
    # lock or reclaims a now-dead-pid one instead of reading the dying holder as
    # live and standing down.
    $waited = 0
    while ($waited -lt $Settings.RestartWaitMs -and (Test-FmProcessAlive $recorded)) {
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    return 'Stopped'
}

function Resolve-FmWatchArmOwnedClose {
    <#
        owned_child_finished. Classify the close of a watcher THIS arm started,
        and never let a zero exit with nothing to show for it read as success.

        Three outcomes, in the order they are tested:
          - an actionable reason line on the child's own stdout, which is the
            ordinary case and is passed straight through;
          - a clean exit with a verified healthy successor, which is a handover:
            the caller attaches and keeps following;
          - a clean exit with neither, resolved against the watcher's
            identity-bound delivery record. A matching record reports that wake;
            no record is the typed failure.

        A nonzero close reports the watcher's own FAILED line when it wrote one,
        and otherwise says plainly that the cycle exited without a reason.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Child,
        [Parameter(Mandatory)][hashtable]$Cycle,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][int]$ExitCode
    )

    $captured = Get-FmWatchArmChildOutput -Child $Child
    foreach ($noise in $captured.Absorbed) {
        Write-FmTriageLog -Context $Context -Message ('watch-arm: watcher child said: ' + $noise)
    }
    $out = @($captured.Lines)

    if ($ExitCode -eq 0 -and (Test-FmWatchArmActionable -Line $out)) {
        Add-FmWatchArmCycleRecord -Cycle $Cycle -Context $Context -Settings $Settings `
            -ExitCode ([string]$ExitCode) -Reason (Get-FmWatchArmReasonType -Line $out) -Successor 'none'
        return [pscustomobject]@{ Lines = $out; ExitCode = 0; Attach = $false; Cycle = $null }
    }

    if ($ExitCode -eq 0) {
        $successor = Wait-FmWatchArmWatcherState -Context $Context -WatchPath $WatchPath `
            -Grace $Settings.Grace -TimeoutSeconds $Settings.ConfirmTimeout
        if ($successor.Healthy) {
            Add-FmWatchArmCycleRecord -Cycle $Cycle -Context $Context -Settings $Settings `
                -ExitCode ([string]$ExitCode) -Reason 'unexpected-clean-exit' -Successor ('attached:' + $successor.ProcessId)
            $next = New-FmWatchArmCycle -Context $Context -WatcherPid $successor.ProcessId -Origin 'attached' -Identity $successor.Identity
            $out += ('watcher: attached pid={0} (beacon {1}s)' -f $successor.ProcessId, $successor.BeaconAge)
            return [pscustomobject]@{ Lines = $out; ExitCode = 0; Attach = $true; Cycle = $next }
        }

        $delivered = Get-FmWatchArmDeliveredReason -Context $Context -WatcherPid $Cycle.WatcherPid -Identity $Cycle.Identity
        if ($delivered) {
            Add-FmWatchArmCycleRecord -Cycle $Cycle -Context $Context -Settings $Settings `
                -ExitCode ([string]$ExitCode) -Reason 'clean-exit-delivered-wake' -Successor 'none'
            $out += $delivered
            return [pscustomobject]@{ Lines = $out; ExitCode = 0; Attach = $false; Cycle = $null }
        }

        Add-FmWatchArmCycleRecord -Cycle $Cycle -Context $Context -Settings $Settings `
            -ExitCode ([string]$ExitCode) -Reason 'unexpected-clean-exit' -Successor 'none'
        $out += 'watcher: FAILED - cycle ended without an actionable reason'
        return [pscustomobject]@{ Lines = $out; ExitCode = 1; Attach = $false; Cycle = $null }
    }

    Add-FmWatchArmCycleRecord -Cycle $Cycle -Context $Context -Settings $Settings `
        -ExitCode ([string]$ExitCode) -Reason 'nonzero-exit' -Successor 'none'
    if (-not (@($out | Where-Object { $_ -like 'watcher: FAILED*' }).Count)) {
        $out += ('watcher: FAILED - watcher cycle exited {0} without an actionable reason' -f $ExitCode)
    }
    return [pscustomobject]@{ Lines = $out; ExitCode = 1; Attach = $false; Cycle = $null }
}
