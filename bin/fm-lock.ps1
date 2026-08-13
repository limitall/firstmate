#requires -Version 7.0
<#
Acquire or inspect this home's firstmate session lock.

Usage: fm-lock.ps1            acquire; exit 1 unless ownership is verified
       fm-lock.ps1 status     print holder and liveness; always exits 0

The lock records the HARNESS (agent) process id found by walking this process's
ancestry, not the transient shell running the acquisition - that one is dead
moments after it is written and its lock would read as stale immediately.

A session that cannot verify lock ownership must operate READ-ONLY: no spawn,
steer, merge, wake-queue drain, or any other fleet mutation. That is what the
nonzero exit means here, and it is a normal outcome rather than a failure.

Exit codes: 0 acquired (or a status read), 1 refused, 2 usage.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmLock'

$mode = if ($args.Count -ge 1) { [string]$args[0] } else { '' }

if ($mode -eq '-h' -or $mode -eq '--help') {
    Get-Help -Full $PSCommandPath
    exit 0
}
if ($mode -eq 'status') {
    # NOT `$null = ...`: without -PassThru the command's only output IS the
    # "lock: free" / "lock: held by live harness pid N" / "lock: stale ..." line
    # bin/fm-lock.sh prints, and swallowing it left `fm-lock.ps1 status`
    # printing nothing at all while still exiting 0 - a status read that
    # reports no status.
    Invoke-FmLock -Status
    exit 0
}
if ($mode -ne '') {
    [Console]::Error.WriteLine('usage: fm-lock.ps1 [status]')
    exit 2
}

# The refusal message is written to the error stream by the command itself, and
# is deliberately NOT suppressed here: "operate read-only until resolved" is the
# whole point of the nonzero exit.
$result = Invoke-FmLock -PassThru
if ($result -and $result.Acquired) {
    Write-Output $result.Message
    exit 0
}
exit 1
