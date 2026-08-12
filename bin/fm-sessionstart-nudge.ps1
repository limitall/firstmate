# bin/fm-sessionstart-nudge.ps1 - print the one-line session-start instruction
# only for a genuine firstmate primary whose current harness session has not
# already acquired the home lock.
#
# Twin: bin/fm-sessionstart-nudge.sh
#
# CLI: no arguments, no flags. Prints at most ONE line to stdout and always
# exits 0.
#
# ---------------------------------------------------------------------------
# EVERY PATH EXITS 0, INCLUDING THE FAILURES
#
# This runs as a Claude SessionStart hook, where a non-zero exit BLOCKS session
# initialization. So a missing dependency, an unreadable lock, a refused probe,
# or an encoder that declines are all silence-and-exit-0, never a diagnostic and
# never a non-zero code. That is why there is no Exit-FmScript 1 anywhere below
# and why Invoke-FmMain is given UnexpectedCode 0: even a defect in this file
# must not be able to stop the captain's session from opening.
#
# ---------------------------------------------------------------------------
# IT NUDGES; IT NEVER STARTS THE SESSION
#
# The output is an ENCODED INSTRUCTION for the agent to run session start
# itself. This script never invokes fm-session-start, never acquires the home
# lock, never drains the wake queue, and never writes to state/. It reads three
# things - the gate-agent marker, the primary scope, and the existing lock - and
# then either says nothing or prints one sentence.
#
# The instruction text names `bin/fm-session-start.sh` exactly as the bash twin
# does, deliberately: both trees are live during the conversion, both scripts
# exist, and diverging the text here would mean the two hooks tell the agent to
# do two different things at the same moment. The name flips repo-wide at
# cutover, with the hook rewiring, not in this file alone.
#
# ---------------------------------------------------------------------------
# WHY THE ANCESTRY WALK IS TRIED FIRST AND IS EXPECTED TO FAIL HERE
#
# The raw walk answers "did MY session acquire the lock" only where the harness
# is reachable as an ancestor and visible as a live process. Under a native
# Windows harness neither holds - the pid the lock records is a native process
# this interpreter is not descended from - so an already locked session would be
# nudged to lock again on every SessionStart. The shared session-lock owner
# resolves the same identity the lock was written with and answers correctly.
# The walk still runs first, exactly as in the bash twin, so a platform where it
# DOES work never pays for the second resolution.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-gate-refuse-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-primary-scope-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-operational-input.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-session-lock-lib.psm1') -Force

# UnexpectedCode 0: see the header. A SessionStart hook may not fail loudly.
Invoke-FmMain -UnexpectedCode 0 {
    $context = Get-FmContext $PSScriptRoot
    $root = $context.Root
    $state = $context.State

    # `[ -f "$STATE/.lock" ]` then a bounded 8-step parent walk. A lock pid of 1,
    # an empty first line, or any non-digit content is not an ancestry answer.
    function Test-LockInAncestry {
        $lock = Join-Path $state '.lock'
        $native = ConvertTo-FmNativePath $lock
        if (-not [System.IO.File]::Exists($native)) { return $false }
        if (Test-FmSymlink $native) { return $false }
        $lines = Get-FmFileLines $native
        if ($lines.Count -lt 1) { return $false }
        $lockPid = $lines[0]
        if ($lockPid -notmatch '^[0-9]+$') { return $false }
        if ($lockPid -eq '1') { return $false }
        if (-not (Test-FmProcAlive -ProcessId $lockPid)) { return $false }

        $walk = [string]$PID
        for ($step = 0; $step -lt 8; $step++) {
            if ($walk -eq $lockPid) { return $true }
            $parent = Get-FmProcParentId -ProcessId $walk
            if ($null -eq $parent) { return $false }
            if ([int]$parent -le 1) { return $false }
            $walk = [string][int]$parent
        }
        return $false
    }

    if (Test-FmGateAgent $root) { Exit-FmScript 0 }
    if (-not (Test-FmPrimaryScopeMatch -Root $root -State $state)) { Exit-FmScript 0 }

    if (Test-LockInAncestry) { Exit-FmScript 0 }
    if (Test-FmSessionLockOwnedBySelf $state) { Exit-FmScript 0 }

    $nudge = ConvertTo-FmOperationalInput 'session-start' `
        'Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
    if ([string]::IsNullOrEmpty($nudge)) { Exit-FmScript 0 }
    Write-FmOut $nudge
    Exit-FmScript 0
}
