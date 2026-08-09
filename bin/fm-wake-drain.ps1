# bin/fm-wake-drain.ps1 - atomically drain durable watcher wake records,
# optionally annotate validated signal status keys after raw consumption
# commits, then assert liveness.
#
# Twin: bin/fm-wake-drain.sh
#
# CLI: no arguments. Prints the deduped raw wake rows on stdout, exits 0.
#
# ---------------------------------------------------------------------------
# THE ONE ORDERING THIS FILE EXISTS TO PROTECT
#
# Print-before-delete is the deliberate at-least-once no-loss boundary. Between
# printing the rows and removing the drained file there is a micro-gap in which
# a crash replays a wake; that is the safe direction, and everything after the
# lock release (annotations, the liveness assertion) is best-effort and may
# never restore, duplicate, hide, or fail the rows already consumed. The bash
# twin's comment says exactly this and the ordering below is byte-for-byte its
# ordering.
#
# ---------------------------------------------------------------------------
# DIVERGENCES FROM THE BASH TWIN, STATED RATHER THAN HIDDEN
#
#   1. SIGNALS. The bash twin installs `trap 'exit 130' INT` and
#      `trap 'exit 143' TERM` so an interrupted drain restores the queue through
#      its EXIT trap. HUP/INT/TERM do not exist on Windows
#      (docs/powershell-port.md, "Things that must NOT be improved"), so those
#      two exit codes cannot be produced faithfully and are NOT faked. What IS
#      preserved is the property they protect: the restore-on-failure path runs
#      from a `finally`, so any terminating error - the only interruption this
#      runtime can observe - puts the drained records back before the lock is
#      released.
#
#   2. THE LIVENESS ASSERTION IS CAPTURED, NOT INHERITED. The bash twin runs
#      `"$SCRIPT_DIR/fm-guard.sh" || true`, letting the child write straight to
#      this process's stderr. Here the guard is invoked through Invoke-FmScript
#      (which picks the twin that exists, never a hard-coded extension) with its
#      streams CAPTURED and immediately re-emitted through the sanctioned
#      writers. Same bytes, same streams, same position in the output; the
#      reason for capturing is that a re-emitted stream is byte-controlled
#      (contract 1) and observable to an in-process differential driver, where
#      an inherited handle would bypass both.
#
#   3. `exit "$?"` AFTER A FAILED WRITE. Bash propagates whatever printf or rm
#      returned. A .NET write failure is an exception, not a small integer, so
#      those paths exit 1 - the code bash's `mv`/truncate failures already use -
#      and the diagnostic names the real fault.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOT -Force. -Force removes the already-loaded module GLOBALLY before
# re-importing it, which re-runs fm-common's body and with it the console
# encoding assignment that RESETS [Console]::In/Out/Error. A differential driver
# that runs this entrypoint in-process behind redirected console streams would
# lose them on the first case (docs/powershell-port.md, "Never -Force a NESTED
# module import", and the same trap recorded in the wave-4 hook twins).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script happens to run. Reuse fm-guard's
# existing graced, beacon-based alarm (FM_GUARD_GRACE) - do not duplicate the
# beacon math. Called after the queue is emptied so guard never re-prints its own
# queued-wakes notice for the records this run just drained, and never let a
# guard hiccup change the drain's exit status.
function Assert-FmWatcherLiveness {
    $result = $null
    try {
        $result = Invoke-FmScript -Name 'fm-guard'
    } catch {
        # `|| true`: a guard that cannot even be launched must not change the
        # drain's outcome.
        return
    }
    if ($null -eq $result) { return }
    if (-not [string]::IsNullOrEmpty([string]$result.StdOut)) { Write-FmRaw ([string]$result.StdOut) }
    if (-not [string]::IsNullOrEmpty([string]$result.StdErr)) { Write-FmErr (([string]$result.StdErr).TrimEnd("`n")) }
}

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmWakeContext
    $state = $context.State
    $queue = $context.Queue
    $queueLock = $context.QueueLock

    $nativeQueue = ConvertTo-FmNativePath $queue
    $drainTmp = ''
    $lockHeld = $false
    $failed = $true

    try {
        Wait-FmLock -LockPath $queueLock
        $lockHeld = $true

        # `[ ! -s "$FM_WAKE_QUEUE" ]`: absent OR zero-length is "nothing to do",
        # and the truncate is still performed so a stray directory-less state
        # dir ends the turn with a real empty queue file.
        $size = 0
        if ([System.IO.File]::Exists($nativeQueue)) {
            try { $size = (Get-Item -LiteralPath $nativeQueue -Force).Length } catch { $size = 0 }
        }
        if ($size -le 0) {
            Set-FmFileText -Path $nativeQueue -Text '' -NoNewline
            $failed = $false
            Assert-FmWatcherLiveness
            Exit-FmScript 0
        }

        $drainTmp = "$state/.wake-queue.drain.$(Get-FmCurrentPid)"
        $nativeDrain = ConvertTo-FmNativePath $drainTmp
        try { if ([System.IO.File]::Exists($nativeDrain)) { [System.IO.File]::Delete($nativeDrain) } } catch { $null = $_ }
        try {
            [System.IO.File]::Move($nativeQueue, $nativeDrain, $true)
        } catch {
            Write-FmLog "cannot move the wake queue aside: $($_.Exception.Message)"
            Exit-FmScript 1
        }
        try {
            Set-FmFileText -Path $nativeQueue -Text '' -NoNewline
        } catch {
            Write-FmLog "cannot re-create the wake queue: $($_.Exception.Message)"
            Exit-FmScript 1
        }

        # Wrapped in @(): a PowerShell function that returns an empty array
        # yields an empty ENUMERATION, which lands in the caller as $null, and
        # $null.Count throws under StrictMode. An empty queue with only
        # malformed rows is an ordinary state, not a defect.
        $rawRows = @(Get-FmWakeDeduped -Path $drainTmp)

        # Test-only seam for proving that the consumption boundary itself, not
        # the annotation phase, is what commits. Bash `case` guard semantics:
        # 0 and any non-numeric value are no-ops.
        $delay = Get-FmEnv -Name 'FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT' -Default '0'
        if ($delay -ne '0' -and $delay -match '^[0-9]+$') {
            Start-Sleep -Seconds ([int]$delay)
        }

        if ($rawRows.Count -gt 0) {
            # Print-before-delete: the at-least-once boundary described above.
            foreach ($row in $rawRows) { Write-FmOut $row }
        }
        try {
            if ([System.IO.File]::Exists($nativeDrain)) { [System.IO.File]::Delete($nativeDrain) }
        } catch {
            Write-FmLog "cannot remove the drained queue file: $($_.Exception.Message)"
            Exit-FmScript 1
        }
        $drainTmp = ''
        Unlock-FmLock -LockPath $queueLock
        $lockHeld = $false
        $failed = $false

        # Raw output and queue deletion are authoritative. Everything below is
        # best-effort and cannot restore, duplicate, hide, or fail the consumed
        # rows - hence the swallowed failure, the bash `( ... ) || true`.
        try {
            Write-FmWakeAnnotation -Rows ($rawRows -join "`n")
        } catch {
            $null = $_
        }
        Assert-FmWatcherLiveness
        Exit-FmScript 0
    } finally {
        # The EXIT-trap twin. A drain that did not reach its commit point puts
        # the records back BEFORE releasing the lock, so a concurrent appender
        # never observes a queue missing rows this run failed to consume.
        if ($failed -and $lockHeld -and -not [string]::IsNullOrEmpty($drainTmp)) {
            try {
                if ([System.IO.File]::Exists((ConvertTo-FmNativePath $drainTmp))) {
                    $null = Restore-FmWakeQueue -DrainedPath $drainTmp
                }
            } catch {
                $null = $_
            }
        }
        if ($lockHeld) {
            try { Unlock-FmLock -LockPath $queueLock } catch { $null = $_ }
        }
    }
}
