#requires -Version 7.0

<#
.SYNOPSIS
    Acquire or inspect this home's session lock - the digest's stage 1 owner.

.DESCRIPTION
    Port of bin/fm-lock.sh, and the name the session-start area and the Claude
    Stop auto-arm resolve. The foundation already publishes the mechanics
    (Request-FmSessionLock, Get-FmSessionLockStatus); this is the ENTRY-POINT
    shape those two callers ask for, and nothing else. It adds no locking policy
    of its own, so acquisition keeps exactly one owner.

    Why the name exists at all rather than the callers calling the foundation
    directly: both callers bind by name at call time and must tolerate the owner
    being absent, so the name they resolve is part of the contract published in
    docs/session-start.md. It was the missing half of that contract - the reason
    every session on this port came up READ-ONLY while the machinery underneath
    worked - so it is now a real function with the bash exit and output contract,
    not an alias.

    Output contract, kept from bin/fm-lock.sh:
      acquire  writes "lock acquired: harness pid <N>" to the output stream on
               success, and "error: ..." to the ERROR stream on refusal, which
               is where bash sends it. The digest merges both streams into its
               LOCK subsection, so the captain reads the reason verbatim.
      -Status  writes one "lock: ..." line and always succeeds, whatever it
               finds - a status read is a report, never a gate.

    TEXT ONLY on the pipeline unless -PassThru. The digest prints whatever this
    returns verbatim, so an object emitted by default would land in the captain's
    startup output as a stringified hashtable. Refusal is still legible to the
    digest without one: it reads an error record as "not acquired", which is the
    same evidence bash's nonzero exit carries.

    Refusal is REPORTED, never thrown: "another session holds the lock" is a
    normal outcome whose correct handling is to go read-only, not to fail.

.PARAMETER PassThru
    Also return the result object (Acquired, Status, ProcessId, Path, Message)
    for a caller that needs to branch on it rather than print it.

.PARAMETER Status
    Report the current holder and its liveness instead of acquiring. Always
    succeeds, matching `fm-lock.sh status`, which always exits 0.

.PARAMETER StatePath
    The state directory to lock. Defaults to this home's.

.PARAMETER ProcessId
    Record this pid as the holder instead of resolving the harness ancestry.
    Test seam only: production always resolves the harness process, because a
    lock naming a transient shell reads as stale moments after it is written.

.PARAMETER TimeoutSeconds
    How long to wait for the acquisition claim lock before reporting contention.

.EXAMPLE
    Invoke-FmLock

.EXAMPLE
    Invoke-FmLock -Status
#>
function Invoke-FmLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The acquisition IS the command, exactly as bin/fm-lock.sh has no dry-run mode; -Status is the read-only form.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$Status,
        [switch]$PassThru,
        [string]$StatePath,
        [int]$ProcessId = 0,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 30
    )

    if ($Status) {
        $report = Get-FmSessionLockStatus -StatePath $StatePath
        Write-Output $report.Text
        if (-not $PassThru) { return }
        return [pscustomobject]@{
            PSTypeName = 'Firstmate.LockResult'
            Acquired   = ($report.State -eq 'held')
            Status     = $report.State
            ProcessId  = $report.ProcessId
            Path       = $report.Path
            Message    = $report.Text
        }
    }

    $result = Request-FmSessionLock -StatePath $StatePath -ProcessId $ProcessId -TimeoutSeconds $TimeoutSeconds

    if ($result.Acquired) {
        Write-Output $result.Message
    } else {
        Write-Error -Message $result.Message -Category PermissionDenied -ErrorAction Continue
    }

    if (-not $PassThru) { return }
    return [pscustomobject]@{
        PSTypeName = 'Firstmate.LockResult'
        Acquired   = [bool]$result.Acquired
        Status     = $(if ($result.Acquired) { 'held' } else { [string]$result.Reason })
        ProcessId  = $result.ProcessId
        Path       = $result.Path
        Message    = $result.Message
    }
}
