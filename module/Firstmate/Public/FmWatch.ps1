#requires -Version 7.0
<#
    Public/FmWatch.ps1 - Start-FmWatch, the blocking supervision loop.
    Port of the "Main entry" runtime at the bottom of bin/fm-watch.sh.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FmWatchPath {
    <#
        The watcher identity recorded in the singleton lock's watcher-path file.
        A watcher only recognises a lock written by the same implementation, so a
        bash watcher and this one never mistake each other for the live singleton
        in a shared home - which is correct: they are different processes with
        different supervision contracts.
    #>
    [OutputType([string])]
    param([hashtable]$Context)
    if (-not $Context) { $Context = Get-FmWakeContext }
    return (Join-Path $Context.Root 'bin' 'fm-watch.ps1')
}

function Test-FmAfk {
    <#
        afk_present. While state/.afk exists the away-mode daemon owns triage, so
        the watcher must behave ONE-SHOT (enqueue and exit on every wake) and let
        the daemon classify. Absorbing here would hide the wake from the daemon's
        digest and injection layer entirely.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)
    $p = Join-Path $Context.State '.afk'
    return ([System.IO.File]::Exists($p) -or [System.IO.Directory]::Exists($p))
}

function Start-FmWatch {
    <#
        .SYNOPSIS
        Run the firstmate watcher: block, classify supervision wakes, absorb the
        benign ones, and exit on the first actionable one.

        .DESCRIPTION
        One cycle does, in this order and for these reasons:

          1. Self-eviction check. If the singleton lock no longer names this
             process another watcher took over, so stand down rather than double
             every wake.
          2. Beacon touch. state/.last-watcher-beat is the liveness signal every
             guard reads - touched on absorbed cycles too, because absorbing IS
             the watcher working.
          3. Process-event surfacing and post-downtime resurfacing.
          4. Slow authenticated checks, BEFORE the signal scan: an actionable
             wake ends the cycle, so a check placed after the scan would starve
             whenever a chatty crewmate keeps producing signals.
          5. Signal scan with a grace linger, so a crewmate's final status write
             and the same turn's turn-end hook coalesce into ONE wake instead of
             costing a full firstmate turn each.
          6. Pane staleness (layer 1 backbone).
          7. Heartbeat backstop with exponential backoff.
          8. The terminal wait.

        .PARAMETER MaxCycles
        Stop after this many cycles instead of blocking forever. Test seam only;
        0 (the default) is the production blocking loop.

        .OUTPUTS
        A result object carrying ExitCode and the delivered Reason (empty when
        the loop ended without an actionable wake).
    #>
    [CmdletBinding()]
    param(
        [int]$MaxCycles = 0,
        [switch]$SkipTerminalWait
    )

    $ctx = Get-FmWakeContext
    $settings = Get-FmWatchSettings
    $watchPath = Get-FmWatchPath -Context $ctx
    $watchLock = $ctx.WatchLock
    $marker = $ctx.RecoveryMarker

    # Before taking the lock or enumerating any runnable check, let the
    # non-executing legacy check migration have its say. It reads bytes only and
    # never invokes a legacy check; if it refuses, no state check may run.
    $migrationOk = Invoke-FmSeam -Name 'Invoke-FmPrCheckMigration' -Arguments @('--checks-safe') -Default $true
    if (-not $migrationOk) {
        [Console]::Error.WriteLine('watcher: PR check migration blocked; refusing to execute state checks')
        return [pscustomobject]@{ ExitCode = 1; Reason = '' }
    }

    if (-not (Lock-FmPath -LockDir $watchLock)) {
        $held = Get-FmLockHeldPid
        $beat = $ctx.Beacon
        if ($held) {
            if ([System.IO.File]::Exists($beat)) {
                $beatAge = Get-FmPathAge -Path $beat
                if ($beatAge -ge $settings.WatcherStaleGrace) {
                    [Console]::Error.WriteLine("watcher: lock held by live pid $held but heartbeat is stale for ${beatAge}s (>$($settings.WatcherStaleGrace)s); inspect or stop that watcher before re-arming.")
                    return [pscustomobject]@{ ExitCode = 1; Reason = '' }
                }
            }
            elseif ((Get-FmPathAge -Path $watchLock) -ge $settings.WatcherStaleGrace) {
                [Console]::Error.WriteLine("watcher: lock held by live pid $held but no heartbeat exists; inspect or stop that watcher before re-arming.")
                return [pscustomobject]@{ ExitCode = 1; Reason = '' }
            }
            [Console]::Out.WriteLine("watcher: already running pid $held")
        }
        else {
            [Console]::Out.WriteLine('watcher: already running')
        }
        return [pscustomobject]@{ ExitCode = 0; Reason = '' }
    }

    $recoveryPending = [bool](Get-FmLockRecoveredPid)
    if (-not (Test-FmRecoveryArmCheck -Marker $marker)) {
        [Console]::Error.WriteLine('watcher: recovery state could not be consumed safely; retaining stale lock evidence')
        return [pscustomobject]@{ ExitCode = 1; Reason = '' }
    }
    $handlingSuccessor = ((Get-FmEnvValue 'FM_WATCH_HANDLING_SUCCESSOR') -eq '1')
    if ($handlingSuccessor) { $recoveryPending = $false }
    elseif ((Get-FmRecoveryMarkerAction) -eq 'recover') { $recoveryPending = $true }

    $watcherPid = Get-FmCurrentProcessId
    $script:FmWatchDeliveredReason = ''
    $exitCode = 0
    $reason = ''

    try {
        # Lock metadata: the tuple every liveness check compares against.
        try { Set-FmFileTextLf -Path (Join-Path $watchLock 'fm-home') -Text ($ctx.Home + "`n") } catch { }
        try { Set-FmFileTextLf -Path (Join-Path $watchLock 'watcher-path') -Text ($watchPath + "`n") } catch { }
        $script:FmWatchDeliveryPid = [string]$watcherPid
        $identity = Get-FmWakeProcessIdentity -ProcessId $watcherPid
        $script:FmWatchDeliveryIdentity = if ($identity) { $identity } else { '' }
        try { Set-FmFileTextLf -Path (Join-Path $watchLock 'pid-identity') -Text ($script:FmWatchDeliveryIdentity + "`n") } catch { }

        $heartbeatFile = Join-Path $ctx.State '.last-heartbeat'
        if (-not [System.IO.File]::Exists($heartbeatFile)) { Update-FmFileTimestamp -Path $heartbeatFile }

        $null = Start-FmWatchFileNotifier -Context $ctx

        # A merged poll may have queued its terminal wake and then lost the
        # process between receipt publication and fixed-path removal. Finish only
        # identity-bound retirement receipts before any check can run.
        $retire = Invoke-FmSeam -Name 'Repair-FmPrPollRetirementAll' -Arguments @($ctx.State) -Default $null
        if ($null -ne $retire -and -not $retire.Ok) {
            $r = 'check: rejected unauthenticated PR poll retirement receipts:' + $retire.Rejected
            if (-not (Add-FmWakeRecord -Kind check -Key 'pr-poll-retirement' -Payload $r -Context $ctx)) {
                throw 'fm-watch: could not enqueue retirement rejection'
            }
            Update-FmFileTimestamp -Path (Join-Path $ctx.State '.last-check')
            New-FmWakeDelivery -Reason $r -Context $ctx
        }

        if ($handlingSuccessor) {
            # Hand-off from the drain that is presenting the queue right now: wait
            # briefly for it to move the marker out of pending:downtime so this
            # watcher does not resurface records already being handled.
            Update-FmFileTimestamp -Path $ctx.Beacon
            $handlingWait = 0
            while ($handlingWait -lt 600) {
                $null = Get-FmRecoveryMarkerSnapshot -Marker $marker
                if ((Get-FmRecoveryMarkerToken) -notlike 'pending:downtime:*') { break }
                Start-Sleep -Milliseconds 50
                $handlingWait++
            }
            if ($handlingWait -ge 600) { $recoveryPending = $true }
        }

        $cycle = 0
        while ($true) {
            $cycle++

            # 1. Self-eviction. The EXIT cleanup below no-ops when the lock is not
            #    ours, so the rightful singleton's lock stays untouched.
            if ((Get-FmLockPid -LockDir $watchLock) -ne [string]$watcherPid) {
                return [pscustomobject]@{ ExitCode = 0; Reason = '' }
            }

            # 2. Liveness beacon for the guards.
            Update-FmFileTimestamp -Path $ctx.Beacon

            # Parent-owned secondmate pending-reply reconciliation. Cheap when no
            # records exist; never scrapes secondmate conversation.
            $null = Invoke-FmSeam -Name 'Invoke-FmPendingReplyTick' -Arguments @($ctx.State) -Default $null

            # 3. Process-to-event liveness repair, then delivery of any
            #    queued-but-unsurfaced captured result.
            if ([System.IO.Directory]::Exists((Join-Path $ctx.State 'procevent'))) {
                $null = Invoke-FmSeam -Name 'Invoke-FmProceventReconcile' -Arguments @($ctx.State) -Default $null
            }
            Invoke-FmProceventSurface -Context $ctx

            # A process-event result carries richer adapter-owned context than the
            # generic recovery reason, so it gets first refusal above this.
            if ($recoveryPending) {
                New-FmWakeDelivery -Reason 'check: rearm-resurface' -Context $ctx
            }
            else {
                if (-not (Test-FmRecoveryArmCheck -Marker $marker)) {
                    [Console]::Error.WriteLine('watcher: recovery state could not be consumed safely')
                    return [pscustomobject]@{ ExitCode = 1; Reason = '' }
                }
                if ((Get-FmRecoveryMarkerAction) -eq 'recover') {
                    New-FmWakeDelivery -Reason 'check: rearm-resurface' -Context $ctx
                }
            }

            # 4. Slow per-task checks.
            Invoke-FmWatchCheckSweep -Context $ctx -Settings $settings

            # 5. Signal scan.
            Invoke-FmWatchSignalCycle -Context $ctx -Settings $settings

            # 6. Pane staleness.
            Invoke-FmWatchStaleCycle -Context $ctx -Settings $settings

            # 7. Heartbeat backstop.
            Invoke-FmWatchHeartbeat -Context $ctx -Settings $settings

            if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) { break }

            # 8. Terminal wait.
            if (-not $SkipTerminalWait) {
                $null = Wait-FmWatchInterval -Seconds $settings.Poll -Context $ctx
            }
        }
    }
    catch {
        $wakeReason = $null
        if ($_.Exception.Data -and $_.Exception.Data.Contains('FmWakeReason')) {
            $wakeReason = [string]$_.Exception.Data['FmWakeReason']
            $exitCode = [int]$_.Exception.Data['FmWakeExitCode']
            $reason = $wakeReason
        }
        if ($null -eq $wakeReason) {
            [Console]::Error.WriteLine("watcher: $($_.Exception.Message)")
            $exitCode = 1
        }
    }
    finally {
        Stop-FmWatchFileNotifier
        # watcher_cleanup: persist recovery state and release the lock, but only
        # when this process still owns it.
        if ((Get-FmLockPid -LockDir $watchLock) -eq [string]$watcherPid) {
            $transition = 'release-lock'
            if ($recoveryPending -and $script:FmWatchDeliveredReason -eq 'check: rearm-resurface') {
                # This close DELIVERED the resurfacing wake, so the existing
                # generation must survive to be acknowledged - republishing here
                # would start a second generation for the same records.
                $transition = 'release-lock-existing'
            }
            if (-not (Invoke-FmRecoveryTransition -Marker $marker -Action $transition -Target $watchLock -Value 'downtime')) {
                [Console]::Error.WriteLine('watcher: recovery state could not be persisted; retaining stale lock evidence')
                $exitCode = 1
            }
        }
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Reason = $reason }
}

function Invoke-FmWatchCheckSweep {
    <#
        The *.check.sh sweep, time-based on state/.last-check so the cadence
        survives watcher restarts and actionable exits.

        Fail-closed by construction: a check runs ONLY through a validating seam
        that binds it to trusted repository code or a hash-validated private
        snapshot. Every check this watcher cannot authenticate is REJECTED
        WITHOUT EXECUTION and reported as an actionable wake - which is also
        exactly what happens when the validation seam is absent from the module.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if ((Get-FmPathAge -Path (Join-Path $Context.State '.last-check')) -lt $Settings.CheckInterval) { return }

    $rejected = ''
    $checks = @()
    try { $checks = [System.IO.Directory]::GetFiles($Context.State, '*.check.sh') | Sort-Object }
    catch { $checks = @() }

    foreach ($check in $checks) {
        $result = Invoke-FmSeam -Name 'Invoke-FmValidatedCheck' `
            -Arguments @($check, $Context.State, $Settings.CheckTimeout) -Default $null
        if ($null -eq $result -or -not $result.Authorized) {
            $rejected += " $check"
            continue
        }
        if (-not $result.Output) { continue }

        $reason = "check: ${check}: $($result.Output)"
        if (-not (Add-FmWakeRecord -Kind check -Key $check -Payload $reason -Context $Context)) {
            throw 'fm-watch: could not enqueue check result'
        }
        if ($result.PSObject.Properties.Name -contains 'RetirementAction' -and $result.RetirementAction) {
            $null = Invoke-FmSeam -Name 'Publish-FmPrPollRetirement' -Arguments @($Context.State, $result) -Default $null
        }
        Update-FmFileTimestamp -Path (Join-Path $Context.State '.last-check')
        New-FmWakeDelivery -Reason $reason -Context $Context
    }

    if ($rejected) {
        $reason = "check: rejected unauthenticated state checks:$rejected"
        if (-not (Add-FmWakeRecord -Kind check -Key 'unauthenticated-state-checks' -Payload $reason -Context $Context)) {
            throw 'fm-watch: could not enqueue check rejection'
        }
        Update-FmFileTimestamp -Path (Join-Path $Context.State '.last-check')
        New-FmWakeDelivery -Reason $reason -Context $Context
    }
    Update-FmFileTimestamp -Path (Join-Path $Context.State '.last-check')
}

function Invoke-FmWatchSignalCycle {
    <#
        Layer 2 + 3: status files and turn-end markers.

        On the first changed signature, linger one grace period and re-scan
        before classifying: a crewmate's final status write and the same turn's
        turn-end hook land seconds apart, and reporting them as two actionable
        wakes costs a full firstmate turn each. The re-scan also picks up a newer
        signature for an already-pending file - last write wins.

        Triage, cheapest test first. Actionable when:
          - the away-mode daemon owns triage (afk) and wants every wake; or
          - any status file carries a captain-relevant verb; or
          - it is a no-verb wake (a bare turn-end, a working: note) whose crew is
            NOT provably working - the crew stopped its turn with no running
            pipeline and no busy pane, so it may be done (even via an interactive
            menu that wrote no done: status), waiting on a decision, or wedged.
        Absorbing that last case is exactly the swallowed-finish this guards
        against, so both classifier seams fail closed toward surfacing.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $pending = @(Get-FmWatchSignalChanges -Context $Context)
    if ($pending.Count -eq 0) { return }

    Start-Sleep -Seconds $Settings.SignalGrace
    $second = @(Get-FmWatchSignalChanges -Context $Context)
    # Last write wins per seen-file: the re-scan's signature supersedes.
    $byMarker = [ordered]@{}
    foreach ($change in @($pending) + @($second)) { $byMarker[$change.SeenFile] = $change }
    $all = @($byMarker.Values)

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($change in $all) {
        if (-not $files.Contains($change.Path)) { $files.Add($change.Path) }
    }
    $reason = 'signal:' + (($files | ForEach-Object { " $_" }) -join '')

    $actionable = $false
    if (Test-FmAfk -Context $Context) { $actionable = $true }
    if (-not $actionable) {
        $actionable = [bool](Invoke-FmSeam -Name 'Test-FmSignalActionable' -Arguments @(, $files.ToArray()) -Default $true)
    }
    if (-not $actionable) {
        # The only costly test, so it runs ONLY for a non-afk, no-captain-verb
        # signal. Absent seam -> "not provably working" -> surface.
        $working = [bool](Invoke-FmSeam -Name 'Test-FmSignalCrewProvablyWorking' -Arguments @(, $files.ToArray()) -Default $false)
        $actionable = -not $working
    }

    if ($actionable) {
        foreach ($change in $all) {
            $key = [System.IO.Path]::GetFileName($change.Path)
            if (-not (Add-FmWakeRecord -Kind signal -Key $key -Payload $reason -Context $Context)) {
                throw 'fm-watch: could not enqueue signal'
            }
        }
        # Enqueue-before-suppress: markers advance only after the durable records
        # exist, so a crash between the two re-surfaces rather than swallows.
        foreach ($change in $all) {
            Set-FmSignalSeen -Change $change
            $null = Invoke-FmSeam -Name 'Set-FmStatusSurfaced' -Arguments @($change.Path, $Context.State) -Default $null
        }
        New-FmWakeDelivery -Reason $reason -Context $Context
    }
    else {
        foreach ($change in $all) { Set-FmSignalSeen -Change $change }
        Write-FmTriageLog -Message "absorbed benign $reason" -Context $Context -Settings $Settings
    }
}

function Invoke-FmWatchStaleCycle {
    <#
        Layer 1 backbone: pane staleness. Two consecutive identical pane hashes
        with no busy signature means the crewmate finished, is waiting, or is
        wedged. Each distinct stale hash is surfaced, absorbed, or timed toward
        escalation exactly once - .stale-<key> remembers the hash already
        classified, so the costly crew-state reads happen on first sight only.

        The pane layer (backend capture, busy-state contract, crew state) is
        owned elsewhere in the module. When those seams are absent this cycle is
        skipped and says so once per watcher: signal, check and heartbeat
        detection are unaffected, so no durable wake is lost - only pane-derived
        staleness is unavailable.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if (-not (Test-FmSeam -Name 'Get-FmRecordedWindows') -or -not (Test-FmSeam -Name 'Get-FmBackendCapture')) {
        if (-not $script:FmWatchStaleSeamWarned) {
            $script:FmWatchStaleSeamWarned = $true
            Write-FmTriageLog -Context $Context -Settings $Settings `
                -Message 'pane staleness skipped: no backend capture seam available in this module build'
        }
        return
    }

    foreach ($window in @(Invoke-FmSeam -Name 'Get-FmRecordedWindows' -Arguments @($Context.State) -Default @())) {
        if (-not $window) { continue }
        $kind = Invoke-FmSeam -Name 'Get-FmWindowKind' -Arguments @($window, $Context.State) -Default 'unknown'
        $task = Invoke-FmSeam -Name 'Get-FmWindowTask' -Arguments @($window, $Context.State) -Default ''
        $key = Get-FmWindowKey -Window $window
        $last = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$task.status")) -Default ''
        $pausedFlag = Join-Path $Context.State ".paused-$key"

        $heldNow = [bool](Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' -Arguments @($last) -Default $false)
        if (-not $heldNow -and [System.IO.File]::Exists($pausedFlag)) {
            Clear-FmPauseTracking -Window $window -Context $Context
        }
        # A secondmate endpoint is supervised through its status writes, not its
        # pane: an idle or blocked secondmate agent pane is healthy by design.
        if ($kind -eq 'secondmate' -and -not (Invoke-FmSeam -Name 'Test-FmStatusPaused' -Arguments @($last) -Default $false)) {
            continue
        }

        $tail40 = Invoke-FmSeam -Name 'Get-FmBackendCapture' -Arguments @($window, $Context.State, 40) -Default $null
        if ($null -eq $tail40) { continue }
        $hash = Get-FmPaneHash -Text ([string]$tail40)

        $hashFile = Join-Path $Context.State ".hash-$key"
        $countFile = Join-Path $Context.State ".count-$key"
        $staleFile = Join-Path $Context.State ".stale-$key"
        $sinceFile = Join-Path $Context.State ".stale-since-$key"
        $escalationFile = Join-Path $Context.State ".wedge-escalations-$key"
        $prev = Get-FmFileTextOrEmpty -Path $hashFile
        $busyNow = [bool](Invoke-FmSeam -Name 'Test-FmWindowBusy' -Arguments @($window, $Context.State, $tail40) -Default $false)

        if ($hash -eq $prev) {
            $count = Get-FmFirstLine -Path $countFile
            if ($count -notmatch '^[0-9]+$') { $count = '0' }
            $n = [int]$count + 1
            Set-FmFileTextLf -Path $countFile -Text ("$n`n")

            if ($n -ge 2 -and -not $busyNow) {
                Invoke-FmWatchStaleTriage -Window $window -Task $task -Kind $kind -Hash $hash `
                    -StaleFile $staleFile -SinceFile $sinceFile -EscalationFile $escalationFile `
                    -PausedFlag $pausedFlag -Context $Context -Settings $Settings
            }
            else {
                # Busy or not yet stably stale: clear pending escalation
                # bookkeeping, UNLESS a genuinely busy pane has gone too long with
                # no completed turn - then route it through the same wedge timer
                # rather than erasing the evidence.
                if ($busyNow -and (Test-FmBusyTurnOverAge -Task $task -Context $Context -Settings $Settings)) {
                    Invoke-FmWedgeTimerCheck -Window $window -SinceFile $sinceFile -Label 'busy (no completed turn)' `
                        -EscalationFile $escalationFile -Context $Context -Settings $Settings
                }
                else {
                    Remove-FmStateFile -Path $sinceFile
                    Remove-FmStateFile -Path $escalationFile
                }
                $stillHeld = [bool](Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' `
                        -Arguments @((Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$task.status")) -Default '')) -Default $false)
                if ([System.IO.File]::Exists($pausedFlag) -and ($n -ge 2 -or -not $stillHeld)) {
                    Clear-FmPauseTracking -Window $window -Context $Context
                }
            }
        }
        else {
            Set-FmFileTextLf -Path $hashFile -Text $hash
            Set-FmFileTextLf -Path $countFile -Text "0`n"
            if ($busyNow -and (Test-FmBusyTurnOverAge -Task $task -Context $Context -Settings $Settings)) {
                Invoke-FmWedgeTimerCheck -Window $window -SinceFile $sinceFile -Label 'busy (no completed turn)' `
                    -EscalationFile $escalationFile -Context $Context -Settings $Settings
            }
            else {
                Remove-FmStateFile -Path $sinceFile
                Remove-FmStateFile -Path $escalationFile
            }
            $lastNow = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$task.status")) -Default ''
            $heldNow = [bool](Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' -Arguments @($lastNow) -Default $false)
            if (-not (Test-FmAfk -Context $Context) -and $heldNow -and -not $busyNow) {
                if ((Get-FmPauseStateClass -Window $window -Task $task -Context $Context -Settings $Settings) -eq 'paused') {
                    Invoke-FmPausedStale -Window $window -Task $task -Hash $hash -Context $Context -Settings $Settings
                }
                else {
                    Clear-FmPauseTracking -Window $window -Context $Context
                }
            }
            elseif ([System.IO.File]::Exists($pausedFlag)) {
                Clear-FmPauseTracking -Window $window -Context $Context
            }
        }
    }
}

function Invoke-FmWatchStaleTriage {
    <#
        The stale-hash decision, split out of the pane loop for legibility.

        A provably-working stale is ALWAYS absorbed (with a wedge timer)
        regardless of what the status log says: an active run-step or busy pane
        outranks even a captain-relevant log line, because a crew's own log gets
        no new entry once firstmate hands it to a no-mistakes validation. That
        stale-leftover line is what caused the 2026-07 false-surface incidents.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kind,
        [Parameter(Mandatory)][string]$Hash,
        [Parameter(Mandatory)][string]$StaleFile,
        [Parameter(Mandatory)][string]$SinceFile,
        [Parameter(Mandatory)][string]$EscalationFile,
        [Parameter(Mandatory)][string]$PausedFlag,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $alreadyClassified = ((Get-FmFileTextOrEmpty -Path $StaleFile) -eq $Hash)

    if ($Kind -eq 'secondmate') {
        if ((Get-FmPauseStateClass -Window $Window -Task $Task -Context $Context -Settings $Settings) -eq 'paused') {
            Invoke-FmPausedStale -Window $Window -Task $Task -Hash $Hash -Context $Context -Settings $Settings
        }
        else {
            Clear-FmPauseTracking -Window $Window -Context $Context
        }
        return
    }

    if (Test-FmAfk -Context $Context) {
        # Daemon owns triage: one-shot per distinct stale hash.
        if (-not $alreadyClassified) {
            if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload "stale: $Window" -Context $Context)) {
                throw 'fm-watch: could not enqueue afk stale'
            }
            Set-FmFileTextLf -Path $StaleFile -Text $Hash
            New-FmWakeDelivery -Reason "stale: $Window" -Context $Context
        }
        return
    }

    if (Invoke-FmSeam -Name 'Test-FmStaleIsTerminal' -Arguments @($Window, $Context.State) -Default $false) {
        if (-not $alreadyClassified) {
            if (Invoke-FmSeam -Name 'Test-FmCrewProvablyWorking' -Arguments @($Task) -Default $false) {
                Set-FmFileTextLf -Path $StaleFile -Text $Hash
                Set-FmFileTextLf -Path $SinceFile -Text ((Get-FmUnixTime).ToString() + "`n")
                Write-FmTriageLog -Context $Context -Settings $Settings `
                    -Message "absorbed stale (provably working, overriding a stale captain-relevant status): $Window"
            }
            else {
                if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload "stale: $Window" -Context $Context)) {
                    throw 'fm-watch: could not enqueue terminal stale'
                }
                Set-FmFileTextLf -Path $StaleFile -Text $Hash
                Remove-FmStateFile -Path $SinceFile
                $null = Invoke-FmSeam -Name 'Set-FmStatusSurfaced' -Arguments @((Join-Path $Context.State "$Task.status"), $Context.State) -Default $null
                New-FmWakeDelivery -Reason "stale: $Window" -Context $Context
            }
        }
        elseif ([System.IO.File]::Exists($SinceFile)) {
            # This exact hash was already overridden as provably-working: keep
            # treating it that way without re-reading crew state every poll, and
            # without letting the still-captain-relevant log line re-surface it.
            Invoke-FmWedgeTimerCheck -Window $Window -SinceFile $SinceFile -Label 'stale (overridden terminal status)' `
                -EscalationFile $EscalationFile -Context $Context -Settings $Settings
        }
        return
    }

    # Non-terminal stale: a crew gone quiet without a captain-relevant status.
    if (-not $alreadyClassified) {
        switch (Get-FmPauseStateClass -Window $Window -Task $Task -Context $Context -Settings $Settings) {
            'working' {
                # An actively-running pipeline legitimately sits on a static pane
                # (waiting on CI): absorb, but start the wedge timer so a
                # genuinely frozen run still escalates.
                Clear-FmPauseTracking -Window $Window -Context $Context
                Set-FmFileTextLf -Path $StaleFile -Text $Hash
                Set-FmFileTextLf -Path $SinceFile -Text ((Get-FmUnixTime).ToString() + "`n")
                Write-FmTriageLog -Message "absorbed non-terminal stale (provably working): $Window" -Context $Context -Settings $Settings
            }
            'paused' {
                Invoke-FmPausedStale -Window $Window -Task $Task -Hash $Hash -Context $Context -Settings $Settings
            }
            default {
                # No running pipeline, no exact busy verdict, no declared pause:
                # surface now so firstmate inspects the inconclusive state rather
                # than leaving a finish to wait out the timer.
                Invoke-FmNonTerminalStaleSurface -Window $Window -Hash $Hash -Context $Context -Settings $Settings
            }
        }
        return
    }

    $lastNow = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$Task.status")) -Default ''
    $heldNow = [bool](Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' -Arguments @($lastNow) -Default $false)
    if ([System.IO.File]::Exists($PausedFlag) -or $heldNow) {
        switch (Get-FmPauseStateClass -Window $Window -Task $Task -Context $Context -Settings $Settings) {
            'working' {
                Clear-FmPauseState -Window $Window -Context $Context
                Set-FmFileTextLf -Path $StaleFile -Text $Hash
                Invoke-FmWedgeTimerCheck -Window $Window -SinceFile $SinceFile `
                    -Label 'non-terminal stale (provably working after a declared pause)' `
                    -EscalationFile $EscalationFile -Context $Context -Settings $Settings
                Write-FmTriageLog -Message "absorbed non-terminal stale (provably working): $Window" -Context $Context -Settings $Settings
            }
            default {
                Invoke-FmPausedStale -Window $Window -Task $Task -Hash $Hash -Context $Context -Settings $Settings
            }
        }
    }
    else {
        Invoke-FmWedgeTimerCheck -Window $Window -SinceFile $SinceFile -Label 'non-terminal stale' `
            -EscalationFile $EscalationFile -Context $Context -Settings $Settings
    }
}

function Invoke-FmWatchHeartbeat {
    <#
        The heartbeat backstop. Time-based on state/.last-heartbeat so the
        cadence survives restarts; the interval doubles per consecutive no-change
        heartbeat (idle fleet) up to HeartbeatMax and resets on any surfaced
        non-heartbeat wake.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $streakFile = Join-Path $Context.State '.heartbeat-streak'
    $streakText = Get-FmFirstLine -Path $streakFile
    if ($streakText -notmatch '^[0-9]+$') { $streakText = '0' }
    $streak = [int]$streakText
    if ($streak -gt 12) { $streak = 12 }
    $hb = $Settings.Heartbeat * [Math]::Pow(2, $streak)
    if ($hb -gt $Settings.HeartbeatMax) { $hb = $Settings.HeartbeatMax }

    $heartbeatFile = Join-Path $Context.State '.last-heartbeat'
    if ((Get-FmPathAge -Path $heartbeatFile) -lt $hb) { return }

    if (Test-FmAfk -Context $Context) {
        if (-not (Add-FmWakeRecord -Kind heartbeat -Key heartbeat -Payload heartbeat -Context $Context)) {
            throw 'fm-watch: could not enqueue afk heartbeat'
        }
        Update-FmFileTimestamp -Path $heartbeatFile
        New-FmWakeDelivery -Reason 'heartbeat' -Context $Context
    }
    elseif (Test-FmHeartbeatFindsActionable -Context $Context) {
        # Enqueue first, THEN mark every captain-relevant status surfaced, so the
        # next heartbeat does not re-fire them.
        if (-not (Add-FmWakeRecord -Kind heartbeat -Key heartbeat -Payload heartbeat -Context $Context)) {
            throw 'fm-watch: could not enqueue heartbeat backstop'
        }
        Update-FmFileTimestamp -Path $heartbeatFile
        Set-FmAllCaptainRelevantSurfaced -Context $Context
        New-FmWakeDelivery -Reason 'heartbeat' -Context $Context
    }
    else {
        Update-FmFileTimestamp -Path $heartbeatFile
        Set-FmFileTextLf -Path $streakFile -Text (([int]$streakText + 1).ToString() + "`n")
        Write-FmTriageLog -Message 'absorbed heartbeat (no captain-relevant change)' -Context $Context -Settings $Settings
    }
}

function Get-FmPaneHash {
    <# hash_pane: a stable digest of the captured pane tail. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        return (ConvertTo-FmHexString ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))))
    }
    finally { $md5.Dispose() }
}

# Remove-FmStateFile is the foundation's (Private/FmState.ps1): same contract -
# absent is success - plus its retry-on-a-held-file discipline. This area's copy
# is gone rather than kept as a second owner, and it mattered more than the rest:
# it sat in a Public file, so the loader exported THIS one under the foundation's
# name to every caller in the module.

function Test-FmBusyTurnOverAge {
    <#
        busy_turn_over_age. A busy pane is unconditional proof of liveness with
        no built-in duration bound, so a hung foreground call can hide behind a
        busy footer that redraws every poll. This bounds how long any busy pane
        may go with no COMPLETED TURN: age the harness-neutral
        state/<id>.turn-ended marker, or - before any turn has completed - the
        task's spawn record. The caller routes a crossed bound through the same
        wedge timer, for human inspection only: never an interrupt, signal, or
        restart of the worker.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if (-not $Task) { return $false }
    $f = Join-Path $Context.State "$Task.turn-ended"
    if (-not [System.IO.File]::Exists($f)) { $f = Join-Path $Context.State "$Task.meta" }
    return ((Get-FmPathAge -Path $f) -ge $Settings.BusyTurnMaxSecs)
}

function Get-FmPauseStateClass {
    <#
        pause_state_class. Reconcile a declared pause or captain hold with
        authoritative crew state. Only a CONFIDENTLY DEAD ordinary crew may
        recover paused classification after crew state has fallen back to stopped
        or unknown - a live or ambiguously read agent still surfaces once, so a
        declared pause can never become a permanent excuse for silence.
        Returns: working | paused | none.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $key = Get-FmWindowKey -Window $Window
    $recheckFile = Join-Path $Context.State ".paused-rechecked-$key"
    $last = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$Task.status")) -Default ''

    if (-not (Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' -Arguments @($last) -Default $false)) {
        Remove-FmStateFile -Path $recheckFile
        return [string](Invoke-FmSeam -Name 'Get-FmCrewAbsorbClass' -Arguments @($Task) -Default 'none')
    }

    $pausedFlag = Join-Path $Context.State ".paused-$key"
    $agentAlive = 'unknown'
    if ([System.IO.File]::Exists($pausedFlag) -and (Get-FmPathAge -Path $recheckFile) -lt $Settings.StaleEscalateSecs) {
        if ((Invoke-FmSeam -Name 'Get-FmWindowKind' -Arguments @($Window, $Context.State) -Default 'unknown') -ne 'secondmate') {
            $agentAlive = [string](Invoke-FmSeam -Name 'Get-FmBackendAgentAlive' -Arguments @($Window, $Context.State) -Default 'unknown')
            if ($agentAlive -ne 'dead') {
                Remove-FmStateFile -Path $recheckFile
                return 'none'
            }
        }
        return 'paused'
    }

    $class = [string](Invoke-FmSeam -Name 'Get-FmCrewAbsorbClass' -Arguments @($Task) -Default 'none')
    if ($class -eq 'working') {
        Remove-FmStateFile -Path $recheckFile
        return 'working'
    }
    if ((Invoke-FmSeam -Name 'Get-FmWindowKind' -Arguments @($Window, $Context.State) -Default 'unknown') -ne 'secondmate') {
        $agentAlive = [string](Invoke-FmSeam -Name 'Get-FmBackendAgentAlive' -Arguments @($Window, $Context.State) -Default 'unknown')
        if ($agentAlive -ne 'dead') {
            Remove-FmStateFile -Path $recheckFile
            return 'none'
        }
    }
    if ($class -eq 'none' -and $agentAlive -eq 'dead') { $class = 'paused' }
    if ($class -eq 'paused') {
        Set-FmFileTextLf -Path $recheckFile -Text ((Get-FmUnixTime).ToString() + "`n")
    }
    else {
        Remove-FmStateFile -Path $recheckFile
    }
    return $class
}
