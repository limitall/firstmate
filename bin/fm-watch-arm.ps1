#requires -Version 7.0
<#
    .SYNOPSIS
    Safe, home-scoped (re-)arm of this home's watcher, with honest verification.

    .DESCRIPTION
    Thin entry point for Invoke-FmWatchArm. Native Windows PowerShell port of
    bin/fm-watch-arm.sh.

    Usage: fm-watch-arm.ps1 [--restart]

    The watcher (bin/fm-watch.ps1) blocks until it has an actionable wake, prints
    one reason line, and exits. This starts one as a TRACKED CHILD and verifies
    it before settling in, or attaches to the verified healthy cycle that already
    exists. It prints exactly one classification line, then the wake when the
    cycle delivers one:

      watcher: started pid=<N> (beacon fresh)     launched and confirmed
      watcher: attached pid=<N> (beacon <age>s)   a live successor already holds the
                                                  lock; this arm follows it
      watcher: FAILED - <cause>                   no cycle could be confirmed

    It never reports started or attached off a stale beacon or a dead or recycled
    pid, and a cycle that ends with no reason and no healthy successor is
    resolved against the watcher's own identity-bound delivery record rather than
    being reported as a clean no-op. On FAILED it exits 1 so the failure is loud.

    Routine re-arm for a Claude primary is owned by the Stop hook
    (`fm-claude-hook.ps1 -Event Stop -Check autoarm`), which calls the same
    Invoke-FmWatchArm inside the hook's own process tree. Run this by hand only
    for the manual recovery path, and run it in the FOREGROUND: a child reaped
    when a tool call returns leaves no watcher running and a false "already
    running" read off the dying process. The lines print when the cycle closes,
    because this entry point has to map the outcome onto an exit status.

    --restart stops ONLY the watcher pid recorded in THIS home's
    state/.watch.lock, and only after proving that pid is still this home's
    watcher, then owns a fresh cycle. Nothing here ever matches a watcher by
    process name: that pattern finds every firstmate home's watcher on the
    machine and would take siblings down with it (AGENTS.md section 8).

    .EXAMPLE
    pwsh bin/fm-watch-arm.ps1

    .EXAMPLE
    pwsh bin/fm-watch-arm.ps1 --restart
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmWatchArm'

$restart = $false
foreach ($arg in $args) {
    switch ([string]$arg) {
        '-h' { Get-Help -Full $PSCommandPath; exit 0 }
        '--help' { Get-Help -Full $PSCommandPath; exit 0 }
        # Both spellings on purpose: bash callers and captains' notes say
        # --restart, and a PowerShell prompt says -Restart.
        '--restart' { $restart = $true }
        '-Restart' { $restart = $true }
        'arm' { }
        '--arm' { }
        default {
            [Console]::Error.WriteLine('usage: fm-watch-arm.ps1 [--restart]')
            exit 2
        }
    }
}

$result = Invoke-FmWatchArm -Restart:$restart -PassThru
exit $result.ExitCode
