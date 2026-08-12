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
        scan_signals. Compare every state/*.status and state/*.turn-ended against
        its persisted size:mtime signature. PURE READ - the .seen-* marker is
        advanced only after the wake is surfaced or deliberately absorbed, so a
        watcher killed mid-cycle never swallows a signal.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($pattern in @('*.status', '*.turn-ended')) {
        $files = @()
        try { $files = [System.IO.Directory]::GetFiles($Context.State, $pattern) }
        catch { $files = @() }
        foreach ($file in ($files | Sort-Object)) {
            $sig = Get-FmFileSignature -Path $file
            if (-not $sig) { continue }
            $base = [System.IO.Path]::GetFileName($file)
            $seenFile = Join-Path $Context.State ('.seen-' + ($base -replace '\.', '_'))
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

function Invoke-FmWedgeTimerCheck {
    <#
        wedge_timer_check. Repeat-poll bookkeeping for a stale hash already
        absorbed as provably-working: repair a missing timer (self-healing a
        watcher restart between recording the hash and the timer), or escalate
        once StaleEscalateSecs have elapsed. Never re-reads crew state - the
        costly read already happened at classification time.

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
        Set-FmFileTextLf -Path $SinceFile -Text ((Get-FmUnixTime).ToString() + "`n")
        Write-FmTriageLog -Message "absorbed $Label timer reset: $Window" -Context $Context -Settings $Settings
        return
    }

    $age = (Get-FmUnixTime) - [long]$since
    if ($age -lt $Settings.StaleEscalateSecs) { return }

    $prev = Get-FmFirstLine -Path $EscalationFile
    if ($prev -notmatch '^[0-9]+$') { $prev = '0' }
    $n = [int]$prev + 1
    Set-FmFileTextLf -Path $EscalationFile -Text ("$n`n")

    $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n)"
    if ($n -ge $Settings.WedgeDemandInspectCount) {
        $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
    }
    if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload $reason -Context $Context)) {
        throw 'fm-watch: could not enqueue wedge escalation'
    }
    try { Remove-FmStateFile -Path $SinceFile } catch { Write-Debug "watch: could not clear wedge timer $SinceFile; the next cycle re-reads the old start time: $_" }
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

function Clear-FmPauseTracking {
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][hashtable]$Context
    )
    Clear-FmPauseState -Window $Window -Context $Context
    $key = Get-FmWindowKey -Window $Window
    foreach ($name in @(".stale-$key", ".stale-since-$key", ".wedge-escalations-$key")) {
        $p = Join-Path $Context.State $name
        try { Remove-FmStateFile -Path $p } catch { Write-Debug "watch: could not clear state marker $p; the watcher may re-read a stale verdict: $_" }
    }
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
        keep resetting the cadence the way a hash-tied timer would.
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

    $statusFile = Join-Path $Context.State "$Task.status"
    # The foundation's Get-FmPathMtime returns a [datetime], not epoch seconds.
    # An unreadable status file still reads as age 0, NOT as Get-FmPathAge's
    # 999999: this decides whether a DECLARED pause has gone quiet long enough to
    # resurface, and a missing status must not resurface it on the spot.
    $mtime = Get-FmPathMtime -Path $statusFile
    $age = if ($null -eq $mtime) { 0L } else { [long][Math]::Floor(([datetime]::UtcNow - $mtime).TotalSeconds) }

    $resurfacedFile = Join-Path $Context.State ".paused-resurfaced-$key"
    $resurfacedAge = Get-FmPathAge -Path $resurfacedFile
    if ($age -ge $Settings.PauseResurfaceSecs -and $resurfacedAge -ge $Settings.PauseResurfaceSecs) {
        $reason = "stale: $Window (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
        if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload $reason -Context $Context)) {
            throw 'fm-watch: could not enqueue paused-stale recheck'
        }
        Set-FmFileTextLf -Path $resurfacedFile -Text ((Get-FmUnixTime).ToString() + "`n")
        New-FmWakeDelivery -Reason $reason -Context $Context
    }
    Write-FmTriageLog -Message "absorbed stale (paused, awaiting external, age ${age}s): $Window" -Context $Context -Settings $Settings
}

function Invoke-FmNonTerminalStaleSurface {
    <# surface_nonterminal_stale. Takes no settings: like the bash original it
       surfaces unconditionally and writes no triage line, so there is no bound
       or cadence to read. #>
    param(
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$Hash,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $key = Get-FmWindowKey -Window $Window
    if (-not (Add-FmWakeRecord -Kind stale -Key $Window -Payload "stale: $Window" -Context $Context)) {
        throw 'fm-watch: could not enqueue non-terminal stale'
    }
    Set-FmFileTextLf -Path (Join-Path $Context.State ".stale-$key") -Text $Hash
    $sinceFile = Join-Path $Context.State ".stale-since-$key"
    try { Remove-FmStateFile -Path $sinceFile } catch { Write-Debug "watch: could not clear wedge timer $sinceFile; the next cycle re-reads the old start time: $_" }

    $task = Invoke-FmSeam -Name 'Get-FmWindowTask' -Arguments @($Window, $Context.State) -Default ''
    $last = Invoke-FmSeam -Name 'Get-FmLastStatusLine' -Arguments @((Join-Path $Context.State "$task.status")) -Default ''
    $held = Invoke-FmSeam -Name 'Test-FmStatusPausedOrCaptainHeld' -Arguments @($last) -Default $false
    if ($held) {
        Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-$key") -Text ''
        Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-rechecked-$key") -Text ((Get-FmUnixTime).ToString() + "`n")
        Set-FmFileTextLf -Path (Join-Path $Context.State ".paused-resurfaced-$key") -Text ((Get-FmUnixTime).ToString() + "`n")
    }
    else {
        Clear-FmPauseState -Window $Window -Context $Context
    }
    New-FmWakeDelivery -Reason "stale: $Window" -Context $Context
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

function Test-FmHeartbeatFindsActionable {
    <#
        heartbeat_scan_finds_actionable. Pure detect, no side effects: the caller
        enqueues first and marks surfaced after (enqueue-before-suppress). This
        normally finds nothing - it is the fail-safe backstop for a
        captain-relevant status the per-wake path absorbed by mistake.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)
    $statuses = @(Invoke-FmSeam -Name 'Get-FmCaptainRelevantStatuses' -Arguments @($Context.State) -Default @())
    foreach ($s in $statuses) {
        if (-not $s) { continue }
        $surfaced = Get-FmFileTextOrEmpty -Path (Get-FmHeartbeatSurfacedPath -Task $s.Task -Context $Context)
        if ($surfaced -ne $s.Last) { return $true }
    }
    return $false
}

function Set-FmAllCaptainRelevantSurfaced {
    <# mark_all_captain_relevant_surfaced. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal marker write inside a poll cycle that has already classified the wake.')]
    param([Parameter(Mandatory)][hashtable]$Context)
    $statuses = @(Invoke-FmSeam -Name 'Get-FmCaptainRelevantStatuses' -Arguments @($Context.State) -Default @())
    foreach ($s in $statuses) {
        if (-not $s) { continue }
        Set-FmFileTextLf -Path (Get-FmHeartbeatSurfacedPath -Task $s.Task -Context $Context) -Text $s.Last
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
