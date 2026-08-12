# fm-lock.ps1 - acquire or inspect the per-home firstmate session lock.
#
# Twin: bin/fm-lock.sh
#
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.ps1           acquire; exit 1 unless ownership is verified
#        fm-lock.ps1 status    print holder and liveness; always exits 0
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT IS WORTH READING TWICE
#
# This is the gate on everything. AGENTS.md section 3: a session that cannot
# acquire AND VERIFY this lock runs permanently read-only - no spawn, no steer,
# no merge, no wake drain, no supervision repair. So every failure path here
# exits 1 with a message that names the concrete missing requirement, and NO
# path exits 0 without having read the lock back and confirmed it holds this
# session's own harness pid. The verification re-read is not belt-and-braces: a
# write that lands on a symlink, on a full volume, or on a path another process
# replaced between write and read would otherwise be reported as ownership.
#
# Harness identity (the pattern, the ancestry walk, holder liveness) is owned by
# bin/fm-session-lock-lib.psm1 so the Claude Stop auto-arm applies the exact same
# identity contract. On Windows that resolves through CLAUDE_PID, which is why a
# lock written by the bash twin is readable by this one and vice versa - the
# measurement and its consequences are recorded in that module's header.
#
# TWO DOCUMENTED DIVERGENCES (docs/powershell-port.md):
#
#   1. SIGNALS. The bash twin carries `trap 'exit 1' HUP INT TERM` so an
#      interrupted acquisition releases the claim lock and reports failure.
#      Windows has no HUP/TERM, so those exit codes cannot be reproduced; the
#      claim-lock release is instead guaranteed by a `finally`, which covers
#      every path PowerShell actually has, including Ctrl-C.
#   2. mktemp's PUBLICATION PROBE. The bash creates and immediately removes a
#      temp file under state/ to prove the directory is writable before it
#      claims anything. Reproduced exactly, including treating a failure to
#      CLEAN UP the probe as its own refusal - a directory that accepts a file
#      but will not let it be removed cannot host a lock that must be replaced.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-session-lock-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $state = $ctx.State
    $lock = Join-Path $state '.lock'

    # `mkdir -p "$STATE" 2>/dev/null || { ...; exit 1; }`
    try {
        $null = [System.IO.Directory]::CreateDirectory($state)
    } catch {
        Write-FmErr "error: cannot create session-lock state directory $state; operate read-only until resolved"
        Exit-FmScript 1
    }

    if ($fmArgv.Count -gt 0 -and ([string]$fmArgv[0]) -ceq 'status') {
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $lock))) {
            Write-FmOut 'lock: free'
            Exit-FmScript 0
        }
        $old = $null
        try {
            $old = [System.IO.File]::ReadAllText((ConvertTo-FmNativePath $lock))
        } catch {
            Write-FmOut 'lock: unreadable'
            Exit-FmScript 0
        }
        # Command substitution strips trailing newlines.
        $old = $old.TrimEnd("`r", "`n")
        if (Test-FmHarnessPidAlive $old) {
            Write-FmOut "lock: held by live harness pid $old"
        } else {
            Write-FmOut "lock: stale (pid $old dead or not a harness)"
        }
        Exit-FmScript 0
    }

    $me = Get-FmHarnessAncestryPid
    if ([string]::IsNullOrEmpty($me)) {
        Write-FmErr 'error: cannot locate harness process in ancestry'
        Exit-FmScript 1
    }

    # The publication probe: prove the state directory both accepts and releases
    # a file before anything is claimed.
    $probe = Join-Path $state ('.lock-write.' + [System.IO.Path]::GetRandomFileName())
    try {
        [System.IO.File]::WriteAllText((ConvertTo-FmNativePath $probe), '',
            [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-FmErr 'error: cannot write session lock; operate read-only until resolved'
        Exit-FmScript 1
    }
    try {
        [System.IO.File]::Delete((ConvertTo-FmNativePath $probe))
    } catch {
        Write-FmErr 'error: cannot clean session-lock publication probe; operate read-only until resolved'
        Exit-FmScript 1
    }

    $claimLock = Join-Path $state '.lock.acquire'
    $claimHeld = $false
    try {
        $null = Wait-FmLock -LockPath $claimLock
        $claimHeld = $true

        $lockNative = ConvertTo-FmNativePath $lock
        # `[ -e "$LOCK" ] || [ -L "$LOCK" ]` - the second half catches a DANGLING
        # link, which -e alone reports as absent and which would otherwise be
        # written straight through.
        if ([System.IO.File]::Exists($lockNative) -or
            [System.IO.Directory]::Exists($lockNative) -or
            (Test-FmSymlink $lockNative)) {
            if ((-not [System.IO.File]::Exists($lockNative)) -or (Test-FmSymlink $lockNative)) {
                Write-FmErr 'error: session lock is not a regular file; operate read-only until resolved'
                Exit-FmScript 1
            }
            $old = $null
            try {
                $old = [System.IO.File]::ReadAllText($lockNative)
            } catch {
                Write-FmErr 'error: session lock is unreadable; operate read-only until resolved'
                Exit-FmScript 1
            }
            $old = $old.TrimEnd("`r", "`n")
            if (($old -cne $me) -and (Test-FmHarnessPidAlive $old)) {
                Write-FmErr "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved"
                Exit-FmScript 1
            }
        }

        try {
            Set-FmFileText -Path $lock -Text $me
        } catch {
            Write-FmErr 'error: cannot write session lock; operate read-only until resolved'
            Exit-FmScript 1
        }

        $written = $null
        try {
            $written = [System.IO.File]::ReadAllText($lockNative)
        } catch {
            Write-FmErr 'error: cannot verify session lock ownership; operate read-only until resolved'
            Exit-FmScript 1
        }
        $written = $written.TrimEnd("`r", "`n")
        if ((-not [System.IO.File]::Exists($lockNative)) -or (Test-FmSymlink $lockNative) -or ($written -cne $me)) {
            Write-FmErr 'error: session lock ownership verification failed; operate read-only until resolved'
            Exit-FmScript 1
        }
    } finally {
        # The `trap release_claim_lock EXIT` twin. A `finally` covers every exit
        # PowerShell has, including the ExitException Exit-FmScript raises.
        if ($claimHeld) {
            try { $null = Unlock-FmLock -LockPath $claimLock } catch { $null = $_ }
            $claimHeld = $false
        }
    }

    Write-FmOut "lock acquired: harness pid $me"
    Exit-FmScript 0
}
