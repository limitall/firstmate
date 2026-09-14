#requires -Version 7.0
<#
    Public/FmWatchArm.ps1 - Invoke-FmWatchArm, the safe home-scoped (re-)arm of
    this home's watcher. Native PowerShell 7 port of bin/fm-watch-arm.sh.

    Private/FmWatchArm.ps1 holds the internals and the list of what this port
    leaves out on purpose; docs/supervision.md "The arm layer" owns the contract
    and why each refusal is shaped the way it is.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-FmWatchArm {
    <#
        .SYNOPSIS
        Establish exactly one verified watcher cycle for THIS home, or say
        plainly that it could not.

        .DESCRIPTION
        The watcher (bin/fm-watch.ps1) blocks until it has one actionable wake,
        prints one reason line, and exits. This is the layer that establishes
        that cycle and then tells the truth about it. It prints exactly one
        classification line and then, when a cycle delivers a wake, that wake:

          watcher: started pid=<N> (beacon fresh)     it launched one and confirmed it
          watcher: attached pid=<N> (beacon <age>s)   a verified live successor already
                                                      holds the lock; this arm follows it
          watcher: FAILED - <cause>                   it could not confirm a cycle

        IT NEVER REPORTS A CYCLE IT DID NOT VERIFY. A dead pid, a recycled pid, a
        lock belonging to another home, and a stale beacon all fail the same
        honesty gate (Test-FmWatcherHealthy), so a leftover beacon can never be
        reported as supervision. A cycle that ends with no reason line and no
        healthy successor is resolved against the watcher's own identity-bound
        delivery record: a matching record reports that wake and succeeds, and
        only a cycle that delivered nothing is the typed failure. Neither is ever
        a clean empty success, because an empty success is what an auto-arm would
        read as "supervision is fine".

        ONE CYCLE PER HOME. A healthy cycle is ATTACHED to, never doubled, and
        the attach follows verified identity-matched successors instead of
        returning the moment the first cycle ends.

        HOME SCOPE. Every decision comes from this home's state/.watch.lock and
        its fm-home, watcher-path and pid-identity fields. Nothing here ever
        enumerates or matches processes by name, so a sibling firstmate home's
        watcher can be neither attached to, nor signalled, nor stopped -
        AGENTS.md section 8.

        WHO CALLS THIS. Invoke-FmClaudeStopAutoArm, inside the Stop hook's own
        process tree, which is what makes the arm survive the call and notify on
        exit. bin/fm-watch-arm.ps1 is the same thing for a person at a prompt.
        Never start it as a detached background job: a child reaped when the call
        returns leaves no watcher running and a false "already running" read off
        the dying process.

        .PARAMETER Restart
        Forced restart. Stop ONLY the watcher pid this home's lock records - and
        only after proving that pid is still this home's watcher - then own a
        fresh cycle. bin/fm-watch-arm.ps1 also accepts bash's `--restart`
        spelling for this.

        .PARAMETER PassThru
        Return a record carrying ExitCode and Lines instead of emitting the lines
        on the pipeline, and stream each line to the console as it happens. The
        entry point uses this because it needs the exit status; every by-name
        caller wants the lines.

        .PARAMETER AttachTimeoutSeconds
        Stop following an attached cycle after this many seconds. Diagnostic and
        test seam only: 0, the default, is the production behaviour of following
        the cycle until it ends.

        .OUTPUTS
        The classification and reason lines as strings, or one record with
        ExitCode (0 success, 1 refusal or failure) and Lines under -PassThru.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Establishing the cycle IS the command, exactly as it is for Start-FmWatch; a declined arm would be indistinguishable from an arm that failed, which is the one thing this layer may never blur.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$Restart,
        [switch]$PassThru,
        [int]$AttachTimeoutSeconds = 0
    )

    $ctx = Get-FmWakeContext
    $settings = Get-FmWatchArmSettings
    $watchPath = Get-FmWatchPath -Context $ctx

    $lines = [System.Collections.Generic.List[string]]::new()
    $emit = {
        param([string]$Text)
        $lines.Add($Text)
        if ($PassThru) { [Console]::Out.WriteLine($Text) }
    }

    $exit = $null
    $cycle = $null
    $attachedPid = ''

    # --- 1. Forced restart ---------------------------------------------------
    # Home-scoped by construction: Stop-FmWatchArmRecordedWatcher resolves and
    # stops exactly the pid this home's lock records, and reports Foreign for a
    # live pid that is not this home's watcher rather than signalling it.
    if ($Restart) {
        $verdict = Stop-FmWatchArmRecordedWatcher -Context $ctx -WatchPath $watchPath -Settings $settings
        if ($verdict -eq 'Foreign') {
            $stale = Clear-FmWatchArmStaleLock -Context $ctx -WatchPath $watchPath
            if ($stale.Attempted -and -not $stale.Cleared) {
                & $emit 'watcher: FAILED - stale watcher recovery state could not be persisted'
                $exit = 1
            }
        }
    }

    # --- 2. Singleton: attach rather than start a second cycle ---------------
    # --restart skips this: it has just stopped this home's watcher and wants a
    # fresh one.
    if ($null -eq $exit -and -not $Restart) {
        $existing = Get-FmWatchArmWatcherState -Context $ctx -WatchPath $watchPath -Grace $settings.Grace
        if ($existing.Healthy) {
            $cycle = New-FmWatchArmCycle -Context $ctx -WatcherPid $existing.ProcessId -Origin 'attached' -Identity $existing.Identity
            $attachedPid = $existing.ProcessId
            & $emit ('watcher: attached pid={0} (beacon {1}s)' -f $existing.ProcessId, $existing.BeaconAge)
        }
    }

    # --- 3. Start one as a tracked child, and CONFIRM it ---------------------
    if ($null -eq $exit -and $null -eq $cycle) {
        $child = Start-FmWatchArmChild -Context $ctx -WatchPath $watchPath -Settings $settings
        if (-not $child.Started) {
            # The cause goes to the triage log rather than into the reported
            # lines: the classification is what a caller acts on, and an
            # unfiltered child message is exactly what must not be mistaken for
            # a wake reason.
            Write-FmTriageLog -Context $ctx -Message ("watch-arm: no watcher could be started: " + $child.Error)
            $failed = New-FmWatchArmCycle -Context $ctx -WatcherPid '' -Origin 'started' -Identity ''
            Add-FmWatchArmCycleRecord -Cycle $failed -Context $ctx -Settings $settings `
                -ExitCode 'unknown' -Reason 'start-failed' -Successor 'none'
            & $emit 'watcher: FAILED - no live watcher with a fresh beacon'
            $exit = 1
        }
        else {
            try {
                $childPid = [string]$child.Process.Id
                $cycle = New-FmWatchArmCycle -Context $ctx -WatcherPid $childPid -Origin 'started' `
                    -Identity (Get-FmWakeProcessIdentity -ProcessId $childPid)

                # Verify the outcome: poll until this child is the confirmed
                # healthy watcher, until another watcher legitimately holds the
                # singleton (a startup race our child stands down from), or until
                # the child gives up. Only then is any line printed.
                $deadline = [datetime]::UtcNow.AddSeconds($settings.ConfirmTimeout + 1)
                $confirmed = $null
                $exited = $false
                while ($true) {
                    $state = Get-FmWatchArmWatcherState -Context $ctx -WatchPath $watchPath -Grace $settings.Grace
                    if ($state.Healthy) { $confirmed = $state; break }
                    if ($child.Process.HasExited) { $exited = $true; break }
                    if ([datetime]::UtcNow -ge $deadline) { break }
                    Start-Sleep -Milliseconds 200
                }

                if ($null -eq $confirmed -and -not $exited) {
                    # Neither confirmed nor closed inside the budget. Take the
                    # unconfirmed child down rather than leave an unverified
                    # process behind claiming to be supervision - and stop it
                    # BEFORE reading its streams, because a redirected stream is
                    # only readable to the end once the writer has gone.
                    Stop-FmWatchArmChild -Child $child
                    $captured = Get-FmWatchArmChildOutput -Child $child
                    foreach ($line in $captured.Lines) { & $emit $line }
                    Add-FmWatchArmCycleRecord -Cycle $cycle -Context $ctx -Settings $settings `
                        -ExitCode 'unknown' -Reason 'confirmation-timeout' -Successor 'none'
                    & $emit 'watcher: FAILED - no live watcher with a fresh beacon'
                    $exit = 1
                }
                else {
                    if ($null -ne $confirmed -and $confirmed.ProcessId -eq $childPid) {
                        $cycle.Identity = $confirmed.Identity
                        $cycle.LockBefore = Get-FmWatchArmLockSnapshot -Context $ctx
                        & $emit ('watcher: started pid={0} (beacon fresh)' -f $childPid)
                    }
                    # Either our child is the confirmed watcher and we wait out
                    # its cycle, or someone else won the singleton and our child
                    # is already standing down. Both end by waiting on the child
                    # we own, so it is never orphaned.
                    $null = $child.Process.WaitForExit()
                    $code = 1
                    try { $code = $child.Process.ExitCode } catch { $code = 1 }
                    $closed = Resolve-FmWatchArmOwnedClose -Child $child -Cycle $cycle -Context $ctx `
                        -WatchPath $watchPath -Settings $settings -ExitCode $code
                    foreach ($line in $closed.Lines) { & $emit $line }
                    if ($closed.Attach) {
                        $cycle = $closed.Cycle
                        $attachedPid = $closed.Cycle.WatcherPid
                    }
                    else { $exit = $closed.ExitCode }
                }
            }
            finally { Close-FmWatchArmChild -Child $child }
        }
    }

    # --- 4. Follow the cycle we attached to ----------------------------------
    # Stay alive across identity-matched healthy holders: when one cycle ends,
    # attach to a verified successor. With no successor, report the wake that
    # cycle durably delivered, or fail loudly.
    if ($null -eq $exit -and $null -ne $cycle -and $attachedPid) {
        $attachDeadline = $null
        if ($AttachTimeoutSeconds -gt 0) { $attachDeadline = [datetime]::UtcNow.AddSeconds($AttachTimeoutSeconds) }

        while ($true) {
            $state = Get-FmWatchArmWatcherState -Context $ctx -WatchPath $watchPath -Grace $settings.Grace
            if ($state.Healthy) {
                if ($state.ProcessId -ne $attachedPid -or $state.Identity -ne $cycle.Identity) {
                    Add-FmWatchArmCycleRecord -Cycle $cycle -Context $ctx -Settings $settings `
                        -ExitCode 'unknown' -Reason 'lock-replaced' -Successor ('attached:' + $state.ProcessId)
                    $attachedPid = $state.ProcessId
                    $cycle = New-FmWatchArmCycle -Context $ctx -WatcherPid $state.ProcessId -Origin 'attached' -Identity $state.Identity
                    & $emit ('watcher: attached pid={0} (beacon {1}s)' -f $state.ProcessId, $state.BeaconAge)
                }
                if ($attachDeadline -and [datetime]::UtcNow -ge $attachDeadline) { $exit = 0; break }
                Start-Sleep -Milliseconds $settings.AttachPollMs
                continue
            }

            $successor = Wait-FmWatchArmWatcherState -Context $ctx -WatchPath $watchPath `
                -Grace $settings.Grace -TimeoutSeconds $settings.ConfirmTimeout
            if ($successor.Healthy) {
                Add-FmWatchArmCycleRecord -Cycle $cycle -Context $ctx -Settings $settings `
                    -ExitCode 'unknown' -Reason 'attached-cycle-ended' -Successor ('attached:' + $successor.ProcessId)
                $attachedPid = $successor.ProcessId
                $cycle = New-FmWatchArmCycle -Context $ctx -WatcherPid $successor.ProcessId -Origin 'attached' -Identity $successor.Identity
                & $emit ('watcher: attached pid={0} (beacon {1}s)' -f $successor.ProcessId, $successor.BeaconAge)
                continue
            }

            # This arm holds no handle on the watcher's stdout, so the reason
            # line is read from the identity-bound delivery record instead.
            $delivered = Get-FmWatchArmDeliveredReason -Context $ctx -WatcherPid $cycle.WatcherPid -Identity $cycle.Identity
            if ($delivered) {
                Add-FmWatchArmCycleRecord -Cycle $cycle -Context $ctx -Settings $settings `
                    -ExitCode 'unknown' -Reason 'attached-delivered-wake' -Successor 'none'
                & $emit $delivered
                $exit = 0
                break
            }
            Add-FmWatchArmCycleRecord -Cycle $cycle -Context $ctx -Settings $settings `
                -ExitCode 'unknown' -Reason 'attached-cycle-ended' -Successor 'none'
            & $emit 'watcher: FAILED - cycle ended without an actionable reason'
            $exit = 1
            break
        }
    }

    if ($null -eq $exit) {
        # Unreachable by construction: every path above settles. Reported rather
        # than assumed, because a silent empty return is the one outcome an
        # auto-arm would read as healthy supervision.
        & $emit 'watcher: FAILED - the arm reached no verdict'
        $exit = 1
    }

    if ($PassThru) {
        return [pscustomobject]@{ ExitCode = $exit; Lines = $lines.ToArray() }
    }
    return $lines.ToArray()
}
