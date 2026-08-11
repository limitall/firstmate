#requires -Version 7.0
<#
    Public/FmWake.ps1 - the exported wake-queue verbs.
    Invoke-FmWakeDrain is the port of bin/fm-wake-drain.sh.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-FmWake {
    <#
        .SYNOPSIS
        Append one durable wake record to state/.wake-queue.

        .DESCRIPTION
        The queue record is a hard cross-implementation contract:

            epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload<LF>

        UTF-8, no BOM, LF terminated. Key and payload have TAB/CR/LF replaced by
        spaces so no value can forge a record boundary. Records survive until a
        handling turn acknowledges them - queueing is what makes a wake durable
        across a watcher restart, a crash, or a supervision gap.

        .PARAMETER Kind
        signal, stale, check, or heartbeat.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('signal', 'stale', 'check', 'heartbeat')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [hashtable]$Context
    )
    return (Add-FmWakeRecord -Kind $Kind -Key $Key -Payload $Payload -Context $Context)
}

function Get-FmWake {
    <#
        .SYNOPSIS
        The queued wake records, deduplicated exactly as a drain presents them.

        .DESCRIPTION
        Read-only inspection: one row per (kind, key) - all heartbeats collapse to
        one - in first-seen order with last-seen content. Does not consume,
        acknowledge, or advance anything.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([hashtable]$Context)
    if (-not $Context) { $Context = Get-FmWakeContext }
    return (Get-FmWakeDedupedRecords -Path $Context.Queue)
}

function Invoke-FmWakeDrain {
    <#
        .SYNOPSIS
        Present durable watcher wake records, or acknowledge handled ones.

        .DESCRIPTION
        Port of bin/fm-wake-drain.sh. Two modes.

        PRESENT (no -AckThrough). Under the queue lock: adopt or refresh the
        recovery generation, mark it handling, print the deduplicated raw records
        to stdout as the turn's first work queue, then release the lock and print
        the exact acknowledgement command to stderr. Records are NOT consumed
        here - that is the whole point. A turn that dies mid-handling leaves the
        queue intact, so the next drain re-presents it.

        ACKNOWLEDGE (-AckThrough <seq> -RecoveryGeneration <gen>). Consume every
        record at or below <seq>, generation-bound so a stale acknowledgement
        from an older episode cannot silently eat a newer one's wakes.

        The drain also asserts supervision health on the way out. It runs at the
        top of every wake-handling and recovery turn, so a lapsed supervision
        chain surfaces on a plain drain-and-handle turn, not only when some other
        guarded script happens to run. A guard hiccup never changes the exit
        status.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()][string]$AckThrough,
        [AllowEmptyString()][string]$RecoveryGeneration,
        [hashtable]$Context
    )
    if (-not $Context) { $Context = Get-FmWakeContext }
    $marker = $Context.RecoveryMarker

    if ($PSBoundParameters.ContainsKey('AckThrough')) {
        if ($AckThrough -notmatch '^[0-9]+$') {
            [Console]::Error.WriteLine('wake drain: invalid acknowledgement sequence')
            return 2
        }
        if (-not $PSBoundParameters.ContainsKey('RecoveryGeneration')) {
            [Console]::Error.WriteLine('wake drain: acknowledgement requires its recovery generation')
            return 2
        }
        if ($RecoveryGeneration -notmatch '^[A-Za-z0-9._-]+$') {
            [Console]::Error.WriteLine('wake drain: invalid recovery generation')
            return 2
        }
        return (Invoke-FmWakeAcknowledge -Cutoff ([long]$AckThrough) -Generation $RecoveryGeneration -Context $Context)
    }
    if ($PSBoundParameters.ContainsKey('RecoveryGeneration')) {
        [Console]::Error.WriteLine('wake drain: unexpected acknowledgement arguments')
        return 2
    }

    if (-not (Wait-FmPathLock -LockDir $Context.QueueLock -TimeoutSeconds 120)) {
        [Console]::Error.WriteLine('wake drain: could not serialize against the wake queue')
        return 1
    }
    $lockHeld = $true
    try {
        if (-not (Test-FmNonEmptyFile -Path $Context.Queue)) {
            # Empty-queue fast path. Still normalises the file and still honours a
            # recovery generation: the watcher may have died with nothing queued,
            # and that downtime must be acknowledged like any other.
            Set-FmFileTextLf -Path $Context.Queue -Text ''
            $null = Get-FmRecoveryMarkerSnapshot -Marker $marker
            $token = Get-FmRecoveryMarkerToken
            $ackRequired = $false
            if ($token -like 'pending:downtime:*') {
                if ((Start-FmRecoveryHandling -Marker $marker) -ne 0) {
                    [Console]::Error.WriteLine('wake drain: decision recovery could not begin handling safely')
                    return 1
                }
                $token = Get-FmRecoveryMarkerToken
                $ackRequired = $true
            }
            elseif ($token -like 'pending:handling:*') {
                $ackRequired = $true
            }
            Unlock-FmPath -LockDir $Context.QueueLock
            $lockHeld = $false

            Write-FmOpenDecisionsSection -Context $Context
            if ($ackRequired) {
                $gen = $token.Substring($token.LastIndexOf(':') + 1)
                [Console]::Error.WriteLine("WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.ps1 -AckThrough 0 -RecoveryGeneration $gen")
            }
            $null = Invoke-FmGuard -Context $Context
            return 0
        }

        $null = Get-FmRecoveryMarkerSnapshot -Marker $marker
        $token = Get-FmRecoveryMarkerToken
        if (-not $token) {
            if ([System.IO.File]::Exists($marker) -or [System.IO.Directory]::Exists($marker)) {
                [Console]::Error.WriteLine('wake drain: durable wakes have invalid recovery state')
                return 1
            }
            # Legacy wakes queued before the marker existed: adopt them into a
            # fresh generation rather than presenting unacknowledgeable records.
            if (-not (Publish-FmRecoveryMarker -Marker $marker -Kind downtime)) {
                [Console]::Error.WriteLine('wake drain: legacy durable wakes could not be adopted safely')
                return 1
            }
        }
        elseif ($token -like 'acked:*') {
            if (-not (Publish-FmRecoveryMarker -Marker $marker -Kind downtime)) {
                [Console]::Error.WriteLine('wake drain: durable wakes could not enter a fresh recovery generation')
                return 1
            }
        }
        if ((Start-FmRecoveryHandling -Marker $marker) -ne 0) {
            [Console]::Error.WriteLine('wake drain: durable wakes could not begin handling safely')
            return 1
        }

        $rawRows = @(Get-FmWakeDedupedRecords -Path $Context.Queue)
        $ackCutoff = Get-FmWakeMaxSeq -Path $Context.Queue
        foreach ($row in $rawRows) { [Console]::Out.WriteLine($row) }
        [Console]::Out.Flush()

        # Re-read after printing: the records are committed to the caller now, so
        # the generation printed with the acknowledgement command must be the one
        # actually on disk.
        if (-not (Get-FmRecoveryMarkerSnapshot -Marker $marker)) { return 1 }
        $token = Get-FmRecoveryMarkerToken
        if ($token -notlike 'pending:*' -and $token -notlike 'acked:*') {
            [Console]::Error.WriteLine('wake drain: durable wakes have no recovery generation')
            return 1
        }
        Unlock-FmPath -LockDir $Context.QueueLock
        $lockHeld = $false

        $gen = $token.Substring($token.LastIndexOf(':') + 1)
        [Console]::Error.WriteLine("WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.ps1 -AckThrough $ackCutoff -RecoveryGeneration $gen")

        # Best-effort supplemental context, strictly after the commit above.
        foreach ($line in (Get-FmWakeAnnotations -Rows $rawRows -Context $Context)) {
            [Console]::Out.WriteLine($line)
        }
        Write-FmOpenDecisionsSection -Context $Context
        $null = Invoke-FmGuard -Context $Context
        return 0
    }
    finally {
        if ($lockHeld) { Unlock-FmPath -LockDir $Context.QueueLock }
    }
}

function Invoke-FmWakeAcknowledge {
    <#
        The generation-bound acknowledgement. Records at or below <Cutoff> are
        consumed; malformed rows and rows with a higher sequence are preserved,
        so a wake queued DURING handling survives into the next turn.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][long]$Cutoff,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][hashtable]$Context
    )
    $marker = $Context.RecoveryMarker
    if (-not (Wait-FmPathLock -LockDir $Context.QueueLock -TimeoutSeconds 120)) {
        [Console]::Error.WriteLine('wake drain: could not serialize against the wake queue')
        return 1
    }
    try {
        $null = Get-FmRecoveryMarkerSnapshot -Marker $marker
        $token = Get-FmRecoveryMarkerToken
        if (-not $token -or $token.Substring($token.LastIndexOf(':') + 1) -ne $Generation) {
            [Console]::Error.WriteLine('wake drain: recovery generation is stale or could not be acknowledged safely')
            return 1
        }

        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($raw in (Get-FmWakeQueueLines -Path $Context.Queue)) {
            $parts = $raw -split "`t"
            if ($parts.Count -lt 5 -or $parts[1] -notmatch '^[0-9]+$' -or [long]$parts[1] -gt $Cutoff) {
                $kept.Add($raw)
            }
        }
        $text = if ($kept.Count -gt 0) { ($kept -join "`n") + "`n" } else { '' }

        if ($kept.Count -eq 0) {
            # Nothing left: this generation is fully handled, so close it. A
            # non-empty remainder deliberately keeps the generation open.
            if ((Confirm-FmRecoveryMarker -Marker $marker -ExpectedGeneration $Generation) -ne 0) {
                [Console]::Error.WriteLine('wake drain: recovery generation is stale or could not be acknowledged safely')
                return 1
            }
        }
        try { Set-FmFileTextLf -Path $Context.Queue -Text $text }
        catch {
            [Console]::Error.WriteLine('wake drain: acknowledged wakes could not be consumed safely')
            return 1
        }
        return 0
    }
    finally { Unlock-FmPath -LockDir $Context.QueueLock }
}

function Write-FmOpenDecisionsSection {
    <#
        The consolidated OPEN DECISIONS section: every still-open
        needs-decision/blocked, fleet-wide, folded from the durable status logs
        rather than from the latest-line annotations, so a decision buried under
        later unrelated appends cannot be silently missed.

        Runs on EVERY drain, including the empty-queue fast path, because a
        decision can still be open when nothing new is queued for its task.
        Bounded and silent: prints nothing when nothing is open, the common case.

        The fold itself is owned by the classifier elsewhere in the module; when
        that seam is absent this prints nothing rather than guessing.
    #>
    param([Parameter(Mandatory)][hashtable]$Context)

    $open = @(Invoke-FmSeam -Name 'Get-FmOpenDecisions' -Arguments @($Context.State) -Default @())
    if ($open.Count -eq 0) { return }

    $itemBytes = 220
    $globalBytes = 4000
    $used = 0
    $shown = 0
    $omitted = 0
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($d in $open) {
        if (-not $d -or -not $d.Task) { continue }
        $line = [string]$d.Task
        if ($d.Key -ne 'default') { $line += " [key=$($d.Key)]" }
        $line += " $($d.Verb): $($d.Note)"
        # The item allowance is one short of the cap: the trailing newline the
        # global budget also pays for belongs to this caller.
        if ($line.Length -gt ($itemBytes - 1)) { $line = $line.Substring(0, $itemBytes - 1) }
        $bytes = $line.Length + 1
        if (($used + $bytes) -gt $globalBytes) { $omitted++; continue }
        $out.Add($line)
        $used += $bytes
        $shown++
    }

    if ($shown -eq 0 -and $omitted -eq 0) { return }
    [Console]::Out.WriteLine('OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):')
    foreach ($l in $out) { [Console]::Out.WriteLine($l) }
    if ($omitted -gt 0) {
        [Console]::Out.WriteLine("OPEN DECISIONS: $omitted more omitted (byte cap)")
    }
    # Answerer-closes hint, printed exactly when an answer gets written: the send
    # that answers a listed decision also closes it, so closure never depends on
    # the busy worker writing a matching resolved line.
    [Console]::Out.WriteLine("OPEN DECISIONS: close one by answering it: bin/fm-send.ps1 <task> -ResolveKey <key> '<answer>'")
}
