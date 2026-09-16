#requires -Version 7.0
<#
    FmWatch.ps1 - the firstmate watcher loop. Native PowerShell 7 port of
    bin/fm-watch.sh (and the wake/triage/delivery helpers it takes from
    bin/fm-push-transition-lib.sh).

    The watcher classifies every supervision wake. In normal mode it ABSORBS the
    benign majority - it advances the suppression marker, logs, and keeps
    blocking. It enqueues a durable record and exits only for an ACTIONABLE wake;
    that exit is what wakes firstmate through background-task completion.

    Detection is signature-based, not event-based, and that is the guarantee.
    Each watched file is compared against a persisted "size:mtime" signature in
    state/.seen-*, so a signal that lands while NO watcher is running is caught
    by the next one, and two writes in the same second cannot slip through.
    This port may additionally use a FileSystemWatcher, but only to SHORTEN the
    terminal wait: the signature scan still runs every cycle and remains the
    authority. The contract is that no event is missed, not that delivery is
    push-based, so the polling fallback is never optional
    (see Wait-FmWatchInterval).

    Seams. bin/fm-watch.sh sources the classifier, busy-state, backend, and
    check-validation libraries, which other files in this module own. Every one
    of those is called through Get-Command probing here and every absent seam
    fails CLOSED - an unclassifiable signal is surfaced, an unvalidatable check
    is refused without execution - so a partially assembled module can lose
    latency but never swallow a wake.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FmIntEnv {
    <# Numeric env override with the bash `${VAR:-default}` fallback, including
       its "non-numeric means default" tolerance. #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default
    )
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ($raw -match '^[0-9]+$') { return [int]$raw }
    return $Default
}

function Get-FmWatchSettings {
    <# The tunables at the top of bin/fm-watch.sh, same names, same defaults. #>
    [OutputType([hashtable])]
    param()
    return @{
        Poll                    = Get-FmIntEnv -Name 'FM_POLL' -Default 15
        Heartbeat               = Get-FmIntEnv -Name 'FM_HEARTBEAT' -Default 600
        HeartbeatMax            = Get-FmIntEnv -Name 'FM_HEARTBEAT_MAX' -Default 7200
        CheckInterval           = Get-FmIntEnv -Name 'FM_CHECK_INTERVAL' -Default 300
        CheckTimeout            = Get-FmIntEnv -Name 'FM_CHECK_TIMEOUT' -Default 30
        SignalGrace             = Get-FmIntEnv -Name 'FM_SIGNAL_GRACE' -Default 30
        StaleEscalateSecs       = Get-FmIntEnv -Name 'FM_STALE_ESCALATE_SECS' -Default 240
        BusyTurnMaxSecs         = Get-FmIntEnv -Name 'FM_BUSY_TURN_MAX_SECS' -Default 3600
        PauseResurfaceSecs      = Get-FmIntEnv -Name 'FM_PAUSE_RESURFACE_SECS' -Default 3600
        WedgeDemandInspectCount = Get-FmIntEnv -Name 'FM_WEDGE_DEMAND_INSPECT_COUNT' -Default 3
        WatcherStaleGrace       = Get-FmIntEnv -Name 'FM_WATCHER_STALE_GRACE' -Default (Get-FmGuardGrace)
        TriageLogMaxBytes       = Get-FmIntEnv -Name 'FM_WATCH_TRIAGE_LOG_MAX_BYTES' -Default 262144
        DeliveryMaxBytes        = Get-FmIntEnv -Name 'FM_WATCH_DELIVERY_MAX_BYTES' -Default 65536
        DeliveryKeepLines       = Get-FmIntEnv -Name 'FM_WATCH_DELIVERY_KEEP_LINES' -Default 64
    }
}

function Test-FmSeam {
    <# Is an optional collaborating function (classifier, backend, busy state,
       check validation) present in this session? #>
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-FmSeam {
    <#
        Call a collaborating function if the module supplies it, else return
        $Default. Every caller picks a Default that FAILS CLOSED.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Arguments = @(),
        [object]$Default
    )
    $cmd = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $Default }
    try { return (& $cmd @Arguments) }
    catch { return $Default }
}

function Get-FmWindowKey {
    <#
        The per-window state-file suffix: `tr ':/.' '___'`. Byte-identical to the
        bash key, so .hash-*/.stale-*/.paused-* files are interchangeable.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Window)
    return ($Window -replace '[:/.]', '_')
}

# --- triage log and delivery journal -----------------------------------------

function Write-FmTriageLog {
    <# triage_log: bounded best-effort debug line for an ABSORBED wake. Never
       relied on, safe to delete, and never allowed to fail the cycle. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][hashtable]$Context,
        [hashtable]$Settings
    )
    if (-not $Settings) { $Settings = Get-FmWatchSettings }
    $log = Join-Path $Context.State '.watch-triage.log'
    try {
        $stamp = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:sszz00')
        Add-FmWakeQueueBytes -Path $log -Record ("[{0}] {1}`n" -f $stamp, $Message)
        $info = [System.IO.FileInfo]::new($log)
        if ($info.Exists -and $info.Length -ge $Settings.TriageLogMaxBytes) {
            $lines = @(Get-FmWakeQueueLines -Path $log)
            $keep = if ($lines.Count -gt 2000) { $lines[($lines.Count - 2000)..($lines.Count - 1)] } else { $lines }
            Set-FmFileTextLf -Path $log -Text (($keep -join "`n") + "`n")
        }
    }
    catch { Write-Debug "watch: triage log write failed (absorbed, the log is never relied on): $_" }
}

function Publish-FmWatchDelivery {
    <#
        watch_delivery_publish: journal "<pid>\t<identity>\t<reason>" so the next
        arm can tell an ordinary delivered close from an interruption that leaves
        a recovery gap. Bounded, lock-guarded, and never fatal.
    #>
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][hashtable]$Context,
        [hashtable]$Settings
    )
    if (-not $Settings) { $Settings = Get-FmWatchSettings }
    if (-not $script:FmWatchDeliveryPid) { return }
    if (-not $script:FmWatchDeliveryIdentity) { return }

    $log = Join-Path $Context.State '.watch-deliveries.log'
    $lock = Join-Path $Context.State '.watch-deliveries.lock'
    $i = 0
    while (-not (Lock-FmPath -LockDir $lock)) {
        if ($i -ge 20) { return }
        Start-Sleep -Milliseconds 20
        $i++
    }
    try {
        $identity = ConvertTo-FmWakeField $script:FmWatchDeliveryIdentity
        $clean = ConvertTo-FmWakeField $Reason
        if ($clean.Length -gt 4096) { $clean = $clean.Substring(0, 4096) }
        Add-FmWakeQueueBytes -Path $log -Record ("{0}`t{1}`t{2}`n" -f $script:FmWatchDeliveryPid, $identity, $clean)

        $info = [System.IO.FileInfo]::new($log)
        if ($info.Exists -and $info.Length -ge $Settings.DeliveryMaxBytes) {
            $lines = @(Get-FmWakeQueueLines -Path $log)
            $keepCount = [Math]::Min($Settings.DeliveryKeepLines, $lines.Count)
            $keep = @($lines[($lines.Count - $keepCount)..($lines.Count - 1)]) | Where-Object { $_ -match '^[0-9]+\t' }
            Set-FmFileTextLf -Path $log -Text (($keep -join "`n") + "`n")
        }
    }
    catch { Write-Debug "watch: delivery journal write failed (absorbed, never fatal to the cycle): $_" }
    finally { Unlock-FmPath -LockDir $lock }
}

# --- the actionable exit -----------------------------------------------------

$script:FmWatchDeliveryPid = ''
$script:FmWatchDeliveryIdentity = ''
$script:FmWatchDeliveredReason = ''

function New-FmWakeDelivery {
    <#
        wake(): report exactly one actionable reason and leave the loop.

        The reason goes to real stdout (a single line, as bash `echo` does) and
        the loop unwinds through an exception rather than `exit`, so Start-FmWatch
        can always run its cleanup - releasing the singleton lock and persisting
        the recovery state - before the process ends. That cleanup ordering is
        the whole reason this is not a plain `exit`.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reports one actionable reason and unwinds the supervision loop; declining it would swallow the wake the whole watcher exists to surface.')]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $streakFile = Join-Path $Context.State '.heartbeat-streak'
    if ($Reason.StartsWith('heartbeat')) {
        $streak = Get-FmFirstLine -Path $streakFile
        if ($streak -notmatch '^[0-9]+$') { $streak = '0' }
        Set-FmFileTextLf -Path $streakFile -Text (([int]$streak + 1).ToString() + "`n")
    }
    else {
        Set-FmFileTextLf -Path $streakFile -Text "0`n"
    }

    $outputStatus = 0
    try { [Console]::Out.WriteLine($Reason); [Console]::Out.Flush() }
    catch { $outputStatus = 1 }

    if ($outputStatus -eq 0) {
        Publish-FmWatchDelivery -Reason $Reason -Context $Context
        $script:FmWatchDeliveredReason = $Reason
    }

    $signal = [System.Exception]::new('fm-watch: actionable wake delivered')
    $signal.Data['FmWakeReason'] = $Reason
    $signal.Data['FmWakeExitCode'] = $outputStatus
    throw $signal
}

# --- layer 2 + 3: status and turn-end signal scan ----------------------------

function Get-FmWatchSignalChanges {
    <#
        scan_signals. Compare every state/*.status, state/*.turn-ended and
        state/*.inbox against its persisted size:mtime signature. PURE READ - the
        .seen-* marker is advanced only after the wake is surfaced or deliberately
        absorbed, so a watcher killed mid-cycle never swallows a signal.

        *.inbox is a message the captain sent from outside this machine (see
        Public/FmTelegram.ps1). It gets its own file kind rather than borrowing a
        status file because a status file's verbs carry lifecycle meaning: written
        as one, an inbound message would open keyed decisions nobody raised and
        read as a phantom task to every future reader of this home. It carries no
        verb, so it is never captain-relevant on its own and never names a crew
        that could be provably working - which is exactly the "not provably
        working" case the triage below surfaces rather than absorbs.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in @('*.status', '*.turn-ended', '*.inbox')) {
        $files = @()
        try { $files = [System.IO.Directory]::GetFiles($Context.State, $pattern) }
        catch { $files = @() }
        foreach ($file in ($files | Sort-Object)) {
            $sig = Get-FmFileSignature -Path $file
            if (-not $sig) { continue }
            $seenFile = Get-FmSignalSeenPath -StateDir $Context.State -SignalFile $file
            if ($sig -ne (Get-FmFileTextOrEmpty -Path $seenFile)) {
                $results.Add([pscustomobject]@{ SeenFile = $seenFile; Signature = $sig; Path = $file })
            }
        }
    }
    return $results.ToArray()
}

function Set-FmSignalSeen {
    <# Persist the observed signature; the wake for it is now accounted for. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Persisting the observed signature is what accounts for a wake already delivered; skipping it would redeliver forever.')]
    param([Parameter(Mandatory)][object]$Change)
    Set-FmFileTextLf -Path $Change.SeenFile -Text $Change.Signature
}

function Get-FmSignalSeenPath {
    <# The .seen-* marker for one signal file: state/.seen-<name with dots as underscores>. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$SignalFile
    )
    $base = [System.IO.Path]::GetFileName($SignalFile)
    return (Join-Path $StateDir ('.seen-' + ($base -replace '\.', '_')))
}

function Add-FmStatusLineSelfAnnounced {
    <#
        Append one line to a status file on behalf of the session that is going to
        read it anyway, and account for exactly those bytes so the watcher does not
        wake that session with its own write. Returns $true when the line was
        accounted for, $false when it was appended and left for the watcher; a
        failed append throws.

        The case this exists for is firstmate answering a decision: the send that
        delivers the answer also appends its `resolved` line, and without this the
        next watcher run reports that line back to the very turn that wrote it.
        Port of fm_wake_status_append_self_announced (bin/fm-wake-lib.sh).

        The marker advances ONLY when it already matched the file as it stood
        before the append - every earlier byte was presented or absorbed - and the
        file grew by exactly this line. Anything else means bytes somebody else
        wrote are in play, so the marker is left alone and the watcher wakes on the
        whole span: a spurious wake costs one turn, a swallowed worker line costs a
        missed decision. The append lock is held throughout so no writer using
        Add-FmStateLine can land between the two readings; one that bypasses it
        changes the size and falls back the same way.

        A watcher already mid-scan when this runs can still capture the new bytes
        before the marker moves and wake once. That is the safe direction, and the
        emitted protocol runs the watcher in the foreground between turns, so the
        session appending here is not also watching.
    #>
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper; its one caller (Add-FmTaskStatus -SelfAnnounced) owns ShouldProcess for the append.')]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$StatusFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    $statusFull = Resolve-FmFullPath -Path $StatusFile
    $seenFile = Get-FmSignalSeenPath -StateDir $StateDir -SignalFile $statusFull
    $lineBytes = [System.Text.UTF8Encoding]::new($false).GetByteCount($Line) + 1

    Invoke-FmWithLock -Path (Get-FmAppendLockPath -Path $statusFull) -ScriptBlock {
        # The signature is size:mtime, so its first field is the size it describes.
        $before = Get-FmFileSignature -Path $statusFull
        Add-FmStateLine -Path $statusFull -Line $Line -NoLock -Confirm:$false

        if (-not $before) { return $false }
        if ((Get-FmFileTextOrEmpty -Path $seenFile) -ne $before) { return $false }
        $after = Get-FmFileSignature -Path $statusFull
        if (-not $after) { return $false }
        if ([long]$after.Split(':')[0] -ne ([long]$before.Split(':')[0] + $lineBytes)) { return $false }
        try {
            Set-FmFileTextLf -Path $seenFile -Text $after
            return $true
        } catch {
            # The watcher may hold the marker open for a moment; leaving it
            # unmoved wakes the session once, which is the safe failure.
            return $false
        }
    }
}

# --- process-event surfacing -------------------------------------------------

function Get-FmProceventSurfacedMarker {
    <# procevent_surfaced_marker: hex-encoded queue key, so no key text can ever
       escape into a path. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $hex = ConvertTo-FmHexString ([System.Text.Encoding]::UTF8.GetBytes($Key))
    return (Join-Path $Context.State ".seen-procevent-$hex")
}

function Invoke-FmProceventSurface {
    <#
        procevent_surface_queued. Never discovers a result by polling: it only
        reports a result already captured durably on the queue and not yet
        surfaced. The surfaced markers are written AFTER the reason reaches
        stdout, so a delivery that fails to print is retried next cycle.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    if (-not (Test-FmNonEmptyFile -Path $Context.Queue)) { return }
    if (-not (Wait-FmPathLock -LockDir $Context.QueueLock -TimeoutSeconds 60)) { return }

    $surfaced = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($key in (Get-FmWakeQueuedKeysLocked -Kind check -Context $Context)) {
            if (-not $key.StartsWith('procevent:')) { continue }
            $marker = Get-FmProceventSurfacedMarker -Key $key -Context $Context
            if ([System.IO.File]::Exists($marker)) { continue }
            $surfaced.Add($key)
        }
        if ($surfaced.Count -eq 0) { return }

        $reason = 'check: process-event result captured:' + (($surfaced | ForEach-Object { " $_" }) -join '')
        try {
            New-FmWakeDelivery -Reason $reason -Context $Context
        }
        catch {
            # The delivery unwinds by design. Write the surfaced markers only
            # once the reason actually reached stdout, so a failed print is
            # retried on the next cycle instead of being suppressed forever.
            if ($_.Exception.Data.Contains('FmWakeExitCode') -and [int]$_.Exception.Data['FmWakeExitCode'] -eq 0) {
                foreach ($key in $surfaced) {
                    try { Set-FmFileTextLf -Path (Get-FmProceventSurfacedMarker -Key $key -Context $Context) -Text '' }
                    catch { Write-Debug "watch: could not mark process-event '$key' surfaced; it re-surfaces next cycle: $_" }
                }
            }
            throw
        }
    }
    finally { Unlock-FmPath -LockDir $Context.QueueLock }
}

# --- wedge timer and pause cadence -------------------------------------------

function Test-FmResurfaceThrottleHolds {
    <#
        Does a re-surface throttle marker still suppress a recheck? It holds while
        it exists, is younger than PauseResurfaceSecs, and - when -Scope names a
        declaration - was written for THAT declaration.

        The scope is what stops a replacement wait inheriting the old one's
        silence. A worker that appends a new `paused:` line has declared a new
        wait, and a throttle a previous declaration earned must not quiet it.
        Get-FmPathAge reads a missing marker as 999999, so "never re-surfaced"
        never holds.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Throttle,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Scope,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if ((Get-FmPathAge -Path $Throttle) -ge $Settings.PauseResurfaceSecs) { return $false }
    if ($Scope -and (Get-FmFileTextOrEmpty -Path $Throttle) -ne $Scope) { return $false }
    return $true
}

function Invoke-FmAbsorbedResurface {
    <#
        resurface_absorbed. One bounded re-surface for a pane the watcher is
        deliberately absorbing, so no absorb can rot invisibly. <Age> is how long
        the current absorb has held and <Throttle> is the per-window marker
        recording the last re-surface, so once past PauseResurfaceSecs the pane
        wakes once per window rather than every poll.

        Shared by the declared-pause absorb and the in-flight wedge deferral so
        the two cadences cannot drift apart; each caller owns its own marker and
        reason. A -Scope binds the throttle to one declaration (see
        Test-FmResurfaceThrottleHolds) and is what the marker then holds, so the
        non-terminal surface can read the same marker for the same wait.

        Returns without waking while either the absorb or the throttle is inside
        the window; otherwise it enqueues, advances the throttle, and unwinds
        through New-FmWakeDelivery exactly as an inline wake does.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$Throttle,
        [Parameter(Mandatory)][long]$Age,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyString()][string]$Scope = '',
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    if ($Age -lt $Settings.PauseResurfaceSecs) { return }
    if (Test-FmResurfaceThrottleHolds -Throttle $Throttle -Scope $Scope -Settings $Settings) { return }
    if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload $Reason -Context $Context)) {
        throw 'fm-watch: could not enqueue an absorbed-pane recheck'
    }
    $marker = if ($Scope) { $Scope } else { (Get-FmUnixTime).ToString() + "`n" }
    Set-FmFileTextLf -Path $Throttle -Text $marker
    New-FmWakeDelivery -Reason $Reason -Context $Context
}

function Get-FmStaleWaitDeclaration {
    <#
        The declaration a parked worker's re-surface throttle is bound to:
        `declared:<size:mtime>` of its status file while the last line declares a
        wait (`paused:` or `captain-held`), and '' otherwise.

        The status file's signature identifies the declaration because a new
        declaration is a new append: the same wait keeps its signature for as
        long as it stands, and a replacement changes it. The pane cannot be the
        key - an idle parked pane still ticks a clock or a token counter, which
        changes its hash without changing what is being waited on.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Task) { return '' }
    $statusFile = Join-Path $Context.State "$Task.status"
    $last = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @($statusFile) -Default ''
    if (-not (Invoke-FmSeam -Name 'Test-FmStatusIsPausedOrCaptainHeld' -Arguments @($last) -Default $false)) { return '' }
    $sig = Get-FmFileSignature -Path $statusFile
    if (-not $sig) { return '' }
    return "declared:$sig"
}

function Clear-FmInflightDeferral {
    <#
        Drop a window's in-flight deferral chain wherever its idle timer starts
        over, so the chain's age - and with it the recheck cadence - is measured
        from the CURRENT quiet stretch. A chain left over from an earlier stretch
        would make the next deferral recheck at once: noise, never silence, but
        still wrong.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $key = Get-FmWindowKey -Window $Window
    foreach ($name in @(".inflight-since-$key", ".inflight-resurfaced-$key")) {
        $p = Join-Path $Context.State $name
        try { Remove-FmStateFile -Path $p } catch { Write-Debug "watch: could not clear state marker $p; the next deferral may recheck early: $_" }
    }
}

function Invoke-FmWedgeInflightDeferral {
    <#
        Defer ONE wedge escalation for a quiet pane whose task has live processes
        of its own - a worker waiting on its background run. That is the shape
        behind 81 of 92 alerts one live home delivered: each escalated while its
        own liveness clause said work was in flight, deleted its timer, and was
        re-armed by the next poll, every StaleEscalateSecs, for hours.

        Deliberately a DEFERRAL, not a cancellation, because live processes do
        not prove progress: a run can hang on a prompt nobody will answer, and
        docs/finished-run-stall.md is why the reading is trusted for "something is
        running" and for nothing more. So:
          - the idle timer restarts, and the next window takes a fresh reading;
            the moment it answers `none` or `unknown`, the ordinary escalation
            fires on the ordinary schedule;
          - .inflight-since-<key> holds when the first deferred window opened,
            and ages the whole chain, so the pane still re-surfaces once every
            PauseResurfaceSecs through Invoke-FmAbsorbedResurface - worded as a
            recheck, never as a new alarm;
          - the escalation counter is neither advanced (this is not an
            escalation) nor reset (a later genuine wedge keeps the
            demand-deep-inspection history it had already earned).
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$SinceFile,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][long]$Since,
        [Parameter(Mandatory)][string]$Note,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $key = Get-FmWindowKey -Window $Window
    $now = Get-FmUnixTime
    $chainFile = Join-Path $Context.State ".inflight-since-$key"
    $chainStart = Get-FmFirstLine -Path $chainFile
    if ($chainStart -notmatch '^[0-9]+$' -or [long]$chainStart -gt $now) {
        $chainStart = [string]$Since
        Set-FmFileTextLf -Path $chainFile -Text "$chainStart`n"
    }
    $quiet = $now - [long]$chainStart
    $idle = $now - $Since
    Set-FmFileTextLf -Path $SinceFile -Text ("$now`n")

    $reason = "stale: $Window (quiet ${quiet}s with work in flight, rechecked on a long cadence not a wedge; live processes do not prove progress - confirm the run is still advancing)$Note"
    Invoke-FmAbsorbedResurface -Window $Window -Throttle (Join-Path $Context.State ".inflight-resurfaced-$key") `
        -Age $quiet -Reason $reason -Context $Context -Settings $Settings
    Write-FmTriageLog -Message "absorbed $Label (work in flight, idle ${idle}s, quiet ${quiet}s; escalation deferred): $Window" -Context $Context -Settings $Settings
}

function Invoke-FmWedgeTimerCheck {
    <#
        wedge_timer_check. Repeat-poll bookkeeping for a stale hash already
        absorbed as provably-working: repair a missing timer (self-healing a
        watcher restart between recording the hash and the timer), or escalate
        once StaleEscalateSecs have elapsed. Never re-reads crew state - the
        costly read already happened at classification time.

        At the threshold, and only there, it takes ONE run-liveness reading. A
        task with live processes of its own defers the escalation
        (Invoke-FmWedgeInflightDeferral); `none`, `unknown` and a build with no
        reading at all escalate exactly as before, because only positive evidence
        may quiet an alarm. The same reading supplies the escalation's clause, so
        the decision and the words a supervisor reads cannot disagree.

        At WedgeDemandInspectCount consecutive escalations on the SAME pane the
        reason itself carries a demand-deep-inspection marker, so the wake
        payload - not just repetition a supervisor has to notice unaided - forces
        a closer look instead of another routine supervision resume.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$SinceFile,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$EscalationFile,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $since = Get-FmFirstLine -Path $SinceFile
    if ($since -notmatch '^[0-9]+$') {
        # A new idle window: its deferral chain, if any, belonged to the old one.
        Clear-FmInflightDeferral -Window $Window -Context $Context
        Set-FmFileTextLf -Path $SinceFile -Text ((Get-FmUnixTime).ToString() + "`n")
        Write-FmTriageLog -Message "absorbed $Label timer reset: $Window" -Context $Context -Settings $Settings
        return
    }

    $age = (Get-FmUnixTime) - [long]$since
    if ($age -lt $Settings.StaleEscalateSecs) { return }

    $liveness = Get-FmWatchRunLiveness `
        -Task (Invoke-FmSeam -Name 'Convert-FmWindowToTask' -Arguments @($Window, $Context.State) -Default '') `
        -Context $Context
    if ($liveness.State -eq 'processes') {
        Invoke-FmWedgeInflightDeferral -Window $Window -SinceFile $SinceFile -Label $Label -Since ([long]$since) `
            -Note $liveness.Note -Context $Context -Settings $Settings
        return
    }

    $prev = Get-FmFirstLine -Path $EscalationFile
    if ($prev -notmatch '^[0-9]+$') { $prev = '0' }
    $n = [int]$prev + 1
    Set-FmFileTextLf -Path $EscalationFile -Text ("$n`n")

    $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n)"
    if ($n -ge $Settings.WedgeDemandInspectCount) {
        $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
    }
    $reason = $reason + $liveness.Note
    if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload $reason -Context $Context)) {
        throw 'fm-watch: could not enqueue wedge escalation'
    }
    try { Remove-FmStateFile -Path $SinceFile } catch { Write-Debug "watch: could not clear wedge timer $SinceFile; the next cycle re-reads the old start time: $_" }
    Clear-FmInflightDeferral -Window $Window -Context $Context
    New-FmWakeDelivery -Reason $reason -Context $Context
}

function Clear-FmPauseState {
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $key = Get-FmWindowKey -Window $Window
    foreach ($name in @(".paused-$key", ".paused-rechecked-$key", ".paused-resurfaced-$key")) {
        $p = Join-Path $Context.State $name
        try { Remove-FmStateFile -Path $p } catch { Write-Debug "watch: could not clear state marker $p; the watcher may re-read a stale verdict: $_" }
    }
}

function Clear-FmStaleHashTracking {
    <#
        clear_stale_hash_tracking: the hash-scoped half of Clear-FmPauseTracking -
        the stale suppressor, its wedge timer and escalation count, and the
        in-flight deferral chain. Split out so a caller that must keep a window's
        DECLARATION-scoped pause state (its .paused-* flag, recheck and re-surface
        throttle) can still reset the per-hash half alone.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $key = Get-FmWindowKey -Window $Window
    foreach ($name in @(".stale-$key", ".stale-since-$key", ".wedge-escalations-$key")) {
        $p = Join-Path $Context.State $name
        try { Remove-FmStateFile -Path $p } catch { Write-Debug "watch: could not clear state marker $p; the watcher may re-read a stale verdict: $_" }
    }
    Clear-FmInflightDeferral -Window $Window -Context $Context
}

function Clear-FmPauseTracking {
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][hashtable]$Context
    )
    Clear-FmPauseState -Window $Window -Context $Context
    Clear-FmStaleHashTracking -Window $Window -Context $Context
}

function Invoke-FmPausedStale {
    <#
        handle_paused_stale. A crew that declared an external wait (paused:), or
        a captain-held transfer whose agent is confidently gone, is idling on
        purpose: absorb its stale pane instead of wedge-escalating it, but
        re-surface once every PauseResurfaceSecs so a forgotten hold cannot rot
        invisibly.

        The re-surface age is anchored on the STATUS FILE mtime, not a per-hash
        marker, so a churny idle pane (a ticking clock, a token counter) cannot
        keep resetting the cadence the way a hash-tied timer would. The throttle
        is bound to the current declaration (Get-FmStaleWaitDeclaration), which
        is how the non-terminal surface reads the same marker for the same wait.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][string]$Hash,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $key = Get-FmWindowKey -Window $Window
    Set-FmFileTextLf -Path (Join-Path $Context.State ".stale-$key") -Text $Hash
    Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-$key") -Text ''
    foreach ($name in @(".stale-since-$key", ".wedge-escalations-$key")) {
        $p = Join-Path $Context.State $name
        try { Remove-FmStateFile -Path $p } catch { Write-Debug "watch: could not clear state marker $p; the watcher may re-read a stale verdict: $_" }
    }
    Clear-FmInflightDeferral -Window $Window -Context $Context

    $statusFile = Join-Path $Context.State "$Task.status"
    # The foundation's Get-FmPathMtime returns a [datetime], not epoch seconds.
    # An unreadable status file still reads as age 0, NOT as Get-FmPathAge's
    # 999999: this decides whether a DECLARED pause has gone quiet long enough to
    # resurface, and a missing status must not resurface it on the spot.
    $mtime = Get-FmPathMtime -Path $statusFile
    $age = if ($null -eq $mtime) { 0L } else { [long][Math]::Floor(([datetime]::UtcNow - $mtime).TotalSeconds) }

    Invoke-FmAbsorbedResurface -Window $Window -Throttle (Join-Path $Context.State ".paused-resurfaced-$key") -Age $age `
        -Reason "stale: $Window (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)" `
        -Scope (Get-FmStaleWaitDeclaration -Task $Task -Context $Context) -Context $Context -Settings $Settings
    Write-FmTriageLog -Message "absorbed stale (paused, awaiting external, age ${age}s): $Window" -Context $Context -Settings $Settings
}

function Get-FmWatchRunLiveness {
    <#
        One run-liveness reading for a stale decision, as {State, Note}: State is
        `processes`, `none`, `unknown`, or '' when this build has no owner for
        the reading; Note is the clause a stale reason carries, '' when there is
        no owner. Deciding and describing from ONE reading is the point - the
        wedge deferral and the words a supervisor reads must never disagree.

        WHY A STALE REASON CARRIES THIS AT ALL. A quiet pane is the same shape
        whether the worker is waiting on a run that is still going or on one that
        has already ended, and the difference decides what a supervisor should
        do. Without the reading in the payload the supervisor has to derive it by
        hand, and the ad-hoc derivation used before this existed was WRONG in
        every recorded instance - it declared nine genuinely-running suites
        finished (docs/finished-run-stall.md). So the clause states what was
        MEASURED and never what it implies, and the `processes` wording exists
        specifically to stop the false "your run finished" steer.

        An absent, throwing or inconclusive reading says the check did NOT run,
        which is this repo's rule for a step with no answer - never silence,
        which would read as "nothing is running". For the same reason only a
        `processes` State may defer anything; every other State escalates.

        The clause also carries the reading's Activity when it has one, and that
        is REPORTING ONLY: `unobserved` changes no timer and defers exactly as
        `advancing` does, because a run awaiting a network reply and a hung one
        measure identically (Private/FmRunLiveness.ps1 has the measurement). A
        supervisor gets the extra evidence; nothing escalates on its absence.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Task -or -not (Test-FmSeam -Name 'Get-FmTaskRunLiveness')) {
        return [pscustomobject]@{ State = ''; Note = '' }
    }
    $dataPath = Join-Path $Context.Home 'data'
    $reading = Invoke-FmSeam -Name 'Get-FmTaskRunLiveness' -Arguments @($Task, $Context.State, $dataPath) -Default $null
    if ($null -eq $reading -or -not ($reading.PSObject.Properties.Name -contains 'State')) {
        return [pscustomobject]@{ State = 'unknown'; Note = ' [run-liveness: unknown - the reading did NOT run]' }
    }
    switch ([string]$reading.State) {
        'none' {
            return [pscustomobject]@{
                State = 'none'
                Note  = ' [run-liveness: none - no live process for this task beyond its agent, so nothing it could be waiting on is still running]'
            }
        }
        'processes' {
            $ids = @($reading.ProcessId)
            # What was measured is that processes EXIST. Whether they are getting
            # anywhere is the separate Activity reading, and the clause states
            # whichever of the two it actually has - it used to say "work IS in
            # flight" off the process set alone, which is a claim about progress
            # that no process count can support.
            $note = " [run-liveness: $($ids.Count) live process(es) for this task - pids $($ids -join ', ')"
            $activity = 'unknown'
            if ($reading.PSObject.Properties.Name -contains 'Activity') { $activity = [string]$reading.Activity }
            $detail = ''
            if ($reading.PSObject.Properties.Name -contains 'ActivityDetail') { $detail = [string]$reading.ActivityDetail }
            switch ($activity) {
                'advancing' { $note = "$note - and $detail" }
                'unobserved' { $note = "$note - but $detail" }
                default { $note = "$note - whether it is ADVANCING was not measured" }
            }
            return [pscustomobject]@{
                State = 'processes'
                Note  = "$note; do not tell this worker its run has finished]"
            }
        }
        default {
            $detail = ''
            if ($reading.PSObject.Properties.Name -contains 'Detail') { $detail = [string]$reading.Detail }
            return [pscustomobject]@{ State = 'unknown'; Note = " [run-liveness: unknown - $detail; this check did NOT run]" }
        }
    }
}

function Invoke-FmNonTerminalStaleSurface {
    <#
        surface_nonterminal_stale. Surface a stale pane no classifier could
        resolve, so firstmate inspects it: it may have finished through an
        interactive menu that wrote no status, be waiting on a decision, or be
        wedged.

        Get-FmPauseStateClass deliberately answers `none` for a still-LIVE agent
        even under a declared wait, so a worker genuinely waiting on a decision is
        never silenced - which routes every parked-but-live worker here, on first
        sight of each distinct stale hash. An idle parked pane still churns its
        hash (a clock, a token counter), so without a bound one declared wait
        re-alarms firstmate for its whole duration.

        So a declared wait holds this path to the same once-per-PauseResurfaceSecs
        cadence Invoke-FmAbsorbedResurface owns, through the same
        .paused-resurfaced-<key> marker bound to the same declaration. The FIRST
        sight of a declaration still wakes, and the throttle is read BEFORE
        anything is queued and advanced only by a wake that really fires: a
        throttle written by the wake it should have prevented bounds nothing,
        which is what this path used to do. An undeclared stale is never
        throttled here.
    #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$Hash,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    $key = Get-FmWindowKey -Window $Window
    $task = Invoke-FmSeam -Name 'Convert-FmWindowToTask' -Arguments @($Window, $Context.State) -Default ''
    $declaration = Get-FmStaleWaitDeclaration -Task $task -Context $Context
    $throttle = Join-Path $Context.State ".paused-resurfaced-$key"
    $throttled = $declaration -and (Test-FmResurfaceThrottleHolds -Throttle $throttle -Scope $declaration -Settings $Settings)

    $reason = ''
    if (-not $throttled) {
        # Read once and reuse: the queued record and the delivered reason must not
        # disagree about what was measured, and one process-table read per surface
        # is the whole cost of this evidence - which a throttled sight never pays.
        $reason = "stale: $Window" + (Get-FmWatchRunLiveness -Task $task -Context $Context).Note
        if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload $reason -Context $Context)) {
            throw 'fm-watch: could not enqueue non-terminal stale'
        }
    }
    Set-FmFileTextLf -Path (Join-Path $Context.State ".stale-$key") -Text $Hash
    $sinceFile = Join-Path $Context.State ".stale-since-$key"
    try { Remove-FmStateFile -Path $sinceFile } catch { Write-Debug "watch: could not clear wedge timer $sinceFile; the next cycle re-reads the old start time: $_" }
    Clear-FmInflightDeferral -Window $Window -Context $Context

    if ($declaration) {
        Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-$key") -Text ''
        Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-rechecked-$key") -Text ((Get-FmUnixTime).ToString() + "`n")
        if (-not $throttled) { Set-FmFileTextLf -Path $throttle -Text $declaration }
    }
    else {
        Clear-FmPauseState -Window $Window -Context $Context
    }
    if ($throttled) {
        Write-FmTriageLog -Message "absorbed non-terminal stale (declared wait already re-surfaced this window): $Window" -Context $Context -Settings $Settings
        return
    }
    New-FmWakeDelivery -Reason $reason -Context $Context
}

# --- heartbeat backstop ------------------------------------------------------

function Get-FmHeartbeatSurfacedPath {
    <# _hb_surfaced_path. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory)][hashtable]$Context
    )
    return (Join-Path $Context.State ('.hb-surfaced-' + ($Task -replace '[:/.]', '_')))
}

function Set-FmStatusSurfaced {
    <#
        mark_status_surfaced: record ONE status file's current last line as
        already surfaced, so the heartbeat backstop does not raise a second wake
        for a line the signal or stale path has just enqueued.

        This was reached by name as if it belonged to another area, and no area
        owned it - so every wake the per-wake paths raised stayed unmarked and
        the backstop could surface it again. It is a write into this area's own
        marker namespace (Get-FmHeartbeatSurfacedPath, three lines up), so it
        lives here and is called directly.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal marker write inside a poll cycle that has already enqueued the durable wake.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if ([string]::IsNullOrEmpty($Path)) { return }
    $name = [System.IO.Path]::GetFileName($Path)
    if (-not $name.EndsWith('.status')) { return }
    $task = $name.Substring(0, $name.Length - '.status'.Length)
    $last = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @($Path) -Default ''
    Set-FmFileTextLf -Path (Get-FmHeartbeatSurfacedPath -Task $task -Context $Context) -Text ([string]$last)
}

function Test-FmHeartbeatFindsActionable {
    <#
        heartbeat_scan_finds_actionable. Pure detect, no side effects: the caller
        enqueues first and marks surfaced after (enqueue-before-suppress). This
        normally finds nothing - it is the fail-safe backstop for a
        captain-relevant status the per-wake path absorbed by mistake.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)
    $statuses = @(Invoke-FmSeam -Name 'Get-FmCaptainRelevantStatus' -Arguments @($Context.State) -Default @())
    foreach ($s in $statuses) {
        if (-not $s) { continue }
        $surfaced = Get-FmFileTextOrEmpty -Path (Get-FmHeartbeatSurfacedPath -Task $s.Task -Context $Context)
        if ($surfaced -ne $s.Line) { return $true }
    }
    return $false
}

function Set-FmAllCaptainRelevantSurfaced {
    <# mark_all_captain_relevant_surfaced. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal marker write inside a poll cycle that has already classified the wake.')]
    param([Parameter(Mandatory)][hashtable]$Context)
    $statuses = @(Invoke-FmSeam -Name 'Get-FmCaptainRelevantStatus' -Arguments @($Context.State) -Default @())
    foreach ($s in $statuses) {
        if (-not $s) { continue }
        Set-FmFileTextLf -Path (Get-FmHeartbeatSurfacedPath -Task $s.Task -Context $Context) -Text $s.Line
    }
}

# --- terminal wait: FileSystemWatcher with the polling fallback --------------

$script:FmWatchFsw = $null
$script:FmWatchFswSource = 'FmWatchStateChange'
$script:FmWatchFswFailures = 0
# One-shot notice that this module build has no backend/pane seams.
$script:FmWatchStaleSeamWarned = $false

function Start-FmWatchFileNotifier {
    <#
        Optional latency shortener. A FileSystemWatcher on the state directory
        turns the terminal POLL sleep into an early wake when a status file or
        turn-end marker changes.

        It is explicitly NOT a source of truth. Events are only ever used to end
        the sleep early; the next cycle still re-reads every size:mtime signature
        from disk. If registration fails - or fails repeatedly at runtime - the
        watcher drops to the pure sleep and behaves exactly like bin/fm-watch.sh.

        # WINDOWS-UNVERIFIED: on Windows this sits on ReadDirectoryChangesW,
        # whose kernel buffer silently DROPS events under a burst. That is
        # precisely why the signature scan, not this notifier, decides what
        # happened - a dropped event costs latency, never a wake.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts a process-local FileSystemWatcher; it holds no durable state and only ever shortens a sleep.')]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ((Get-FmEnvValue 'FM_WATCH_DISABLE_FSNOTIFY') -eq '1') { return $false }
    if ($script:FmWatchFsw) { return $true }
    try {
        $fsw = [System.IO.FileSystemWatcher]::new($Context.State)
        $fsw.IncludeSubdirectories = $false
        $fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite `
            -bor [System.IO.NotifyFilters]::FileName `
            -bor [System.IO.NotifyFilters]::Size `
            -bor [System.IO.NotifyFilters]::CreationTime
        # Registered without -Action: events queue on the session event queue, so
        # a change that lands while this process is between waits is still seen
        # by the next Wait-Event instead of being dropped.
        foreach ($name in @('Changed', 'Created', 'Renamed')) {
            $null = Register-ObjectEvent -InputObject $fsw -EventName $name -SourceIdentifier "$script:FmWatchFswSource-$name"
        }
        $fsw.EnableRaisingEvents = $true
        $script:FmWatchFsw = $fsw
        return $true
    }
    catch {
        $script:FmWatchFsw = $null
        return $false
    }
}

function Stop-FmWatchFileNotifier {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes a process-local FileSystemWatcher; it holds no durable state.')]
    param()
    if (-not $script:FmWatchFsw) { return }
    foreach ($name in @('Changed', 'Created', 'Renamed')) {
        Unregister-Event -SourceIdentifier "$script:FmWatchFswSource-$name" -ErrorAction SilentlyContinue
    }
    try { $script:FmWatchFsw.EnableRaisingEvents = $false; $script:FmWatchFsw.Dispose() }
    catch { Write-Debug "watch: file notifier dispose failed; the poll loop is the backstop either way: $_" }
    $script:FmWatchFsw = $null
}

function Wait-FmWatchInterval {
    <#
        .SYNOPSIS
        The terminal wait of each supervision cycle.

        .DESCRIPTION
        Sleeps up to <Seconds>, returning early when the file notifier reports
        state-directory activity. Returning early only ever SHORTENS latency: the
        poll loop above re-scans every signature next cycle and is the permanent
        fail-closed backstop, so an event this misses costs latency, never a
        dropped wake.

        Waking is done in bounded slices so a notifier failure degrades into
        ordinary polling within one slice rather than hanging the watcher.

        Takes no context: the notifier and the directory it watches are fixed by
        Start-FmWatchFileNotifier, and this wait only consumes its events.
    #>
    param(
        [Parameter(Mandatory)][int]$Seconds
    )
    if ($Seconds -le 0) { return $false }

    if (-not $script:FmWatchFsw) {
        Start-Sleep -Seconds $Seconds
        return $false
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        $slice = [Math]::Min([Math]::Ceiling($remaining), 5)
        try {
            $evt = Wait-Event -Timeout $slice
            if ($evt -and $evt.SourceIdentifier -like "$script:FmWatchFswSource-*") {
                # Drain the burst: one write typically raises several events.
                Get-Event | Where-Object { $_.SourceIdentifier -like "$script:FmWatchFswSource-*" } |
                    ForEach-Object { Remove-Event -EventIdentifier $_.EventIdentifier -ErrorAction SilentlyContinue }
                return $true
            }
            if ($evt) { Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue }
        }
        catch {
            $script:FmWatchFswFailures++
            if ($script:FmWatchFswFailures -ge 3) { Stop-FmWatchFileNotifier }
            $left = ($deadline - [DateTime]::UtcNow).TotalSeconds
            if ($left -gt 0) { Start-Sleep -Seconds ([Math]::Ceiling($left)) }
            return $false
        }
    }
    return $false
}
