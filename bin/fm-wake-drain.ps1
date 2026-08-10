# bin/fm-wake-drain.ps1 - atomically drain durable watcher wake records,
# optionally annotate validated signal status keys after raw consumption
# commits, print the consolidated OPEN DECISIONS section, then assert liveness.
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
#
#   4. NOT a divergence, recorded because it looks like one: the OPEN DECISIONS
#      hint below names `bin/fm-send.sh` with a hard-coded extension, which
#      contract 7 (docs/powershell-port.md) otherwise forbids. That contract
#      governs one script EXECUTING another, where a wrong extension breaks the
#      call; this is agent-facing TEXT the differential compares byte for byte
#      against the oracle's, so it must stay exactly what the bash twin prints
#      and it is cutover's job to change both at once.

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
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-line-cap-lib.psm1')

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script happens to run. Reuse fm-guard's
# model-aware alarm and FM_GUARD_GRACE instead of duplicating its supervision
# verdict. Under Claude's between-turns auto-arm model, a normal fire leaves a
# recent beacon well inside grace and stays silent mid-turn. Under
# persistent-watcher models, the guard also requires the live identity-matched
# watcher. Called after the queue is emptied so guard never re-prints its own
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

# The `IFS=$(printf '\t') read -r task key verb note` twin, and it has to be
# hand-rolled: a plain .Split("`t") would produce a different field set for
# three inputs this record shape actually reaches.
#
# Because a TAB is IFS WHITESPACE even when IFS holds nothing else, bash `read`
# (verified on this host):
#   * skips LEADING tabs before the first field,
#   * collapses a RUN of tabs into one delimiter, and
#   * gives the LAST name the whole remainder, tabs included, with TRAILING
#     tabs removed - so a decision with an empty note ("t\tk\tv\t") yields an
#     empty note, not a fifth field, and a note containing a tab survives whole.
# docs/powershell-port.md calls this out as a class of bug ("TAB record
# parsing"); the difference from the records that section warns about is that
# HERE the collapsing behavior is the oracle's, so reproducing it - not
# defeating it - is what parity means.
#
# Always returns exactly four strings; missing fields come back empty, the way
# `read` leaves unfilled names.
function Split-FmDrainDecisionRecord {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Record)

    $tab = [char]9
    $fields = [string[]]@('', '', '', '')
    $len = $Record.Length
    $i = 0

    while ($i -lt $len -and $Record[$i] -ceq $tab) { $i++ }
    for ($f = 0; $f -lt 3 -and $i -lt $len; $f++) {
        $start = $i
        while ($i -lt $len -and $Record[$i] -cne $tab) { $i++ }
        $fields[$f] = $Record.Substring($start, $i - $start)
        while ($i -lt $len -and $Record[$i] -ceq $tab) { $i++ }
    }
    if ($i -lt $len) { $fields[3] = $Record.Substring($i).TrimEnd($tab) }

    # `, $fields`: a bare `return $fields` writes the array through the output
    # stream, which unrolls it (docs/powershell-port.md). The caller assigns the
    # result directly and must NOT re-wrap it in @().
    return , $fields
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, fleet-wide, folded from the durable status logs by
# fm-classify-lib's status-fold (via its cursor-backed incremental wrapper)
# rather than from the latest-line annotations above, so a decision buried under
# later unrelated appends cannot be silently missed. Runs on every drain -
# including the empty-queue fast path - because the decision can still be open
# even when nothing new is queued for its task this turn. The incremental
# wrapper bounds this scan's cost to bytes appended to each task's status log
# since the LAST drain, not that log's whole lifetime, while still never
# dropping an old buried decision (see fm-classify-lib.psm1's "incremental
# (cursor-backed) open-decisions fold"). Bounded and silent: prints nothing when
# no decision is open, which is the common case.
function Write-FmOpenDecisionsSection {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    $itemBytes = 220
    $globalBytes = 4000

    $open = Get-FmOpenDecisionsScanIncremental -State $State
    # `open=$(scan_open_decisions_incremental "$STATE")`: the scan is newline-
    # TERMINATED and command substitution eats every trailing newline, so the
    # here-doc bash feeds its read loop has no trailing blank record. TrimEnd is
    # that same strip; without it the split below would yield a phantom empty
    # record on every call.
    if ($null -eq $open) { return }
    $open = $open.TrimEnd("`n")
    if ($open -ceq '') { return }

    $output = [System.Text.StringBuilder]::new()
    $used = 0
    $shown = 0
    $omitted = 0

    foreach ($record in @($open.Split("`n"))) {
        $fields = Split-FmDrainDecisionRecord -Record $record
        $task = $fields[0]
        if ($task -ceq '') { continue }
        $key = $fields[1]
        $verb = $fields[2]
        $note = $fields[3]

        $line = $task
        # -cne: bash `[ "$key" = default ]` compares BYTES, and PowerShell's
        # -ne is culture-sensitive (fm-classify-lib.psm1 note 6).
        if ($key -cne 'default') { $line = "$line [key=$key]" }
        # ${verb}, braced: a bare "$verb:" would be read as a scope/drive
        # qualifier ($env:PATH) and swallow the colon this line needs.
        $line = "$line ${verb}: $note"

        # The shared cut counts the item's own characters; the trailing newline
        # this section's global budget also pays for is this caller's, so the
        # per-item allowance passed down is one short of the cap.
        $line = Limit-FmLine -Line $line -Max ($itemBytes - 1)
        $bytes = $line.Length + 1
        if (($used + $bytes) -gt $globalBytes) {
            $omitted++
            continue
        }
        [void]$output.Append($line).Append("`n")
        $used += $bytes
        $shown++
    }

    if ($shown -le 0 -and $omitted -le 0) { return }
    Write-FmOut 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):'
    # Write-FmRaw, not Write-FmOut: each item already carries its own newline,
    # matching bash's `printf '%s' "$output"`.
    Write-FmRaw ($output.ToString())
    if ($omitted -gt 0) {
        Write-FmOut "OPEN DECISIONS: $omitted more omitted (byte cap)"
    }
    # Answerer-closes hint, printed at exactly the moment an answer gets written:
    # the send that answers a listed decision also closes it, so closure never
    # depends on the busy worker writing a matching resolved line (contract:
    # bin/fm-send.sh header). The literal `.sh` is the oracle's own text - see
    # divergence note 4 in this file's header.
    Write-FmOut "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'"
}

# The `(print_open_decisions_section) || true` twin: the section is best-effort
# and may never fail the drain, and bash's subshell also means a failure part
# way through leaves whatever was already printed, which is what the swallow
# reproduces.
function Write-FmOpenDecisionsSectionBestEffort {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    try {
        Write-FmOpenDecisionsSection -State $State
    } catch {
        $null = $_
    }
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
            # The lock is released HERE, before the section and the liveness
            # assertion, exactly where the bash twin releases it. Both of those
            # read the state directory and fm-guard reports on the queue, so
            # holding the queue lock across them would serialize a concurrent
            # appender behind work that has nothing left to consume.
            Unlock-FmLock -LockPath $queueLock
            $lockHeld = $false
            Write-FmOpenDecisionsSectionBestEffort -State $state
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
        Write-FmOpenDecisionsSectionBestEffort -State $state
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
