#requires -Version 7.0
<#
    Pester tests for the three owners whose absence made this port undispatchable:
    the session lock (Invoke-FmLock), harness detection (Get-FmHarness), and the
    supervision operating block (Get-FmSupervisionInstructions). Plus the two
    small identity and session-start owners that the Claude hooks bind by name.

    WHAT THESE ARE FOR. 1,452 tests passed on Windows while every session came
    up read-only and emitted no supervision protocol at all, because every test
    that touched those paths either stubbed the owner or asserted the
    degradation. So the assertions here are deliberately about the REAL owners
    being present and correct, and each staged degradation is staged explicitly
    rather than assumed.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    function Reset-SupervisionEnvironment {
        foreach ($name in @('CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT')) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    $script:SavedHarnessEnv = @{}
    foreach ($name in @('CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT')) {
        $script:SavedHarnessEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:SavedHarnessEnv.Keys) {
        $value = $script:SavedHarnessEnv[$name]
        if ($null -eq $value) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "Env:$name" -Value $value }
    }
}

Describe 'Get-FmHarness' {
    BeforeEach { Reset-SupervisionEnvironment }
    AfterEach { Reset-SupervisionEnvironment }

    It 'reads the verified Claude marker first' {
        $env:CLAUDECODE = '1'
        Get-FmHarness | Should -Be 'claude'
    }

    It 'distinguishes pi from pi-signed by the marker that records how it launched' {
        $env:PI_CODING_AGENT = 'true'
        Get-FmHarness | Should -Be 'pi'
        $env:FM_PI_HARNESS = 'pi-signed'
        Get-FmHarness | Should -Be 'pi-signed'
    }

    It 'reads the grok marker' {
        $env:GROK_AGENT = '1'
        Get-FmHarness | Should -Be 'grok'
    }

    It 'puts markers AHEAD of ancestry, which is the documented precedence' {
        # The hazard the bash header records: a marker retained in a
        # multiplexer's stored environment wins over the real process tree.
        $env:CLAUDECODE = '1'
        Mock Get-FmProcessAncestry { @(4242) }
        Mock Get-FmHarnessName { 'codex' }
        Get-FmHarness | Should -Be 'claude'
    }

    It 'walks the parent chain when no marker is set' {
        Mock Get-FmProcessAncestry { @(11, 22, 33) }
        Mock Get-FmHarnessName { if ($Id -eq 33) { 'codex' } else { $null } }
        Get-FmHarness | Should -Be 'codex'
    }

    It 'maps a pi-signed COMMAND back to plain pi, as the bash walk does' {
        Mock Get-FmProcessAncestry { @(11) }
        Mock Get-FmHarnessName { 'pi-signed' }
        Get-FmHarness | Should -Be 'pi'
    }

    It 'answers unknown rather than guessing when nothing identifies a harness' {
        Mock Get-FmProcessAncestry { @(11, 22) }
        Mock Get-FmHarnessName { $null }
        Get-FmHarness | Should -Be 'unknown'
    }

    It 'bounds the walk at 8 hops, as the bash loop does' {
        Mock Get-FmProcessAncestry { @() }
        Get-FmHarness | Should -Be 'unknown'
        Should -Invoke Get-FmProcessAncestry -Times 1 -ParameterFilter { $MaxDepth -eq 8 }
    }
}

Describe 'Invoke-FmLock' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'acquires the home lock and records the harness pid, LF-only' {
        Mock Get-FmHarnessAncestryPid { $PID }
        $out = @(Invoke-FmLock)
        $out | Should -Contain "lock acquired: harness pid $PID"
        [System.IO.File]::ReadAllText((Join-Path $script:TestHome.State '.lock')) | Should -Be "$PID`n"
    }

    It 'emits TEXT only, so the digest never prints a stringified object' {
        # The digest prints whatever this returns verbatim under its LOCK
        # heading; an object emitted by default lands there as a hashtable.
        Mock Get-FmHarnessAncestryPid { $PID }
        foreach ($item in @(Invoke-FmLock)) { $item | Should -BeOfType [string] }
    }

    It 'returns the result object only on -PassThru' {
        Mock Get-FmHarnessAncestryPid { $PID }
        # -PassThru ADDS the object to the text line rather than replacing it,
        # so a caller that wants the verdict picks it out.
        $result = @(Invoke-FmLock -PassThru) | Where-Object { $_ -isnot [string] }
        $result.Acquired | Should -BeTrue
        $result.ProcessId | Should -Be $PID
        $result.Status | Should -Be 'held'
    }

    It 'REFUSES rather than throwing when another live session holds it' {
        # A refusal is a normal outcome whose correct handling is read-only, so
        # it is reported, not raised. The message is the bash one verbatim.
        Mock Get-FmHarnessAncestryPid { $PID }
        Mock Test-FmProcessAlive { $true }
        Mock Test-FmHarnessProcess { $true }
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State '.lock'), "999999`n")

        $errors = @()
        $result = @(Invoke-FmLock -PassThru -ErrorVariable errors -ErrorAction SilentlyContinue) |
            Where-Object { $_ -isnot [string] }
        $result.Acquired | Should -BeFalse
        $result.Status | Should -Be 'held'
        ($errors -join ' ') | Should -BeLike '*another live firstmate session holds the lock (pid 999999)*'
        ($errors -join ' ') | Should -BeLike '*operate read-only until resolved*'
    }

    It 'refuses when no harness can be located in the ancestry' {
        Mock Get-FmHarnessAncestryPid { $null }
        $errors = @()
        $result = @(Invoke-FmLock -PassThru -ErrorVariable errors -ErrorAction SilentlyContinue) |
            Where-Object { $_ -isnot [string] }
        $result.Acquired | Should -BeFalse
        ($errors -join ' ') | Should -BeLike '*cannot locate harness process in ancestry*'
    }

    It 'reports free, held and stale on -Status, and never fails' {
        (Invoke-FmLock -Status) | Should -Be 'lock: free'

        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State '.lock'), "4242`n")
        Mock Test-FmProcessAlive { $true }
        Mock Test-FmHarnessProcess { $true }
        (Invoke-FmLock -Status) | Should -Be 'lock: held by live harness pid 4242'

        Mock Test-FmHarnessProcess { $false }
        (Invoke-FmLock -Status) | Should -Be 'lock: stale (pid 4242 dead or not a harness)'
    }

    It 'takes the fast path when the lock is already ours' {
        Mock Get-FmHarnessAncestryPid { $PID }
        [System.IO.File]::WriteAllText((Join-Path $script:TestHome.State '.lock'), "$PID`n")
        @(Invoke-FmLock) | Should -Contain "lock acquired: harness pid $PID"
    }
}

Describe 'Test-FmHarnessPidAlive' {
    It 'requires BOTH liveness and harness identity' {
        Mock Test-FmProcessAlive { $true }
        Mock Test-FmHarnessProcess { $true }
        Test-FmHarnessPidAlive -ProcessId 4242 | Should -BeTrue

        # The recycled-id case: alive, but no longer an agent. Reporting it as a
        # holder would strand every later session behind a lock nobody owns.
        Mock Test-FmHarnessProcess { $false }
        Test-FmHarnessPidAlive -ProcessId 4242 | Should -BeFalse

        Mock Test-FmHarnessProcess { $true }
        Mock Test-FmProcessAlive { $false }
        Test-FmHarnessPidAlive -ProcessId 4242 | Should -BeFalse
    }

    It 'rejects a value that is not a process id at all' {
        Test-FmHarnessPidAlive -ProcessId 'nonsense' | Should -BeFalse
        Test-FmHarnessPidAlive -ProcessId $null | Should -BeFalse
        Test-FmHarnessPidAlive -ProcessId 0 | Should -BeFalse
    }
}

Describe 'Get-FmSupervisionInstructions' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'emits a block with the harness named in its heading' {
        $block = @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 0 -Afk 0 -XMode 0)
        $block | Should -Contain 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude'
        $block | Should -Contain 'Current state:'
        ($block -join "`n") | Should -BeLike '*Mode: Claude*'
    }

    It 'reads 0/1 ints from the digest and bools from the guards identically' {
        # The two callers spell these differently. A silent [bool]"0" -> $true
        # would invert read-only and away-mode handling.
        $fromInt = @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 1 -Afk 0 -XMode 0)
        $fromBool = @(Get-FmSupervisionInstructions @{ Harness = 'claude'; ReadOnly = $true })
        $fromInt | Should -Contain '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
        $fromBool | Should -Contain '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'

        @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 0 -Afk 0 -XMode 0) |
            Should -Contain '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
    }

    It 'tells the truth about the automatic arm this build does not have' {
        $block = @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 0 -Afk 0 -XMode 0)
        $block | Should -Contain '- Automatic re-arm: NOT available in this build; this session keeps the cycle itself.'
        # .Contains, not a double-quoted wildcard: these lines are full of
        # backticks, which PowerShell would read as escape sequences.
        ($block -join "`n").Contains('in the FOREGROUND') | Should -BeTrue
        ($block -join "`n") | Should -Not -BeLike '*Stop-hook-owned supervision*'
    }

    It 'switches to the Stop-owned protocol the moment an arm owner exists' {
        # Probed, not constant: the day the arm lands, the emitted protocol
        # changes with it instead of waiting for someone to remember.
        function Invoke-FmWatchArm { 'watcher: started pid=1 (beacon fresh)' }
        try {
            $block = @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 0 -Afk 0 -XMode 0)
            $block | Should -Contain '- Automatic re-arm: available; the arm owner establishes and follows the cycle.'
            ($block -join "`n") | Should -BeLike '*Mode: Claude Stop-hook-owned supervision.*'
            ($block -join "`n") | Should -BeLike '*do not arm another cycle yourself*'
        } finally {
            Remove-Item -Path 'function:Invoke-FmWatchArm' -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gives an unverified harness the generic protocol and names it as unverified' {
        $block = @(Get-FmSupervisionInstructions -Harness 'codex' -ReadOnly 0 -Afk 0 -XMode 0)
        ($block -join "`n") | Should -BeLike '*Mode: unverified harness fallback.*'
        ($block -join "`n") | Should -BeLike "*no verified watcher wake adapter for 'codex'*"
    }

    It 'says plainly that away mode and the relay are not available here' {
        $block = @(Get-FmSupervisionInstructions -Harness 'claude' -ReadOnly 0 -Afk 1 -XMode 1)
        ($block -join "`n") | Should -BeLike '*away mode is NOT available on this port*'
        ($block -join "`n") | Should -BeLike '*nothing here posts anywhere public*'
    }

    It 'returns ONE repair sentence in the guards'' positional-hashtable shape' {
        $line = Get-FmSupervisionInstructions @{ RepairLine = $true; Harness = 'claude' }
        $line | Should -BeOfType [string]
        $line | Should -BeLike '*FOREGROUND*'
    }

    It 'gives read-only and away mode precedence over the harness sentence' {
        (Get-FmSupervisionInstructions @{ RepairLine = $true; ReadOnly = $true; Afk = $true }) |
            Should -BeLike 'Watcher repair belongs to the session holding the fleet lock*'
        (Get-FmSupervisionInstructions @{ RepairLine = $true; Afk = $true }) |
            Should -BeLike 'Away mode owns watcher supervision*'
    }

    It 'leads the repair line with draining when wakes are queued' {
        (Get-FmSupervisionInstructions @{ RepairLine = $true; QueuePending = $true; Harness = 'claude' }) |
            Should -BeLike 'After draining queued wakes, *'
    }

    It 'is reachable through the guard seam, which passes ONE positional hashtable' {
        # Get-FmSupervisionRepairLine binds this through Invoke-FmSeam. A
        # named-only signature would throw there and the guard would keep its
        # generic fallback sentence for ever, silently.
        $line = Get-FmSupervisionRepairLine -Options @{ RepairLine = $true; Afk = $false; XMode = $false }
        $line | Should -Not -Be 'Repair missing watcher supervision according to the session-start operating block.'
    }

    It 'resolves the harness itself when the caller names none' {
        Mock Get-FmHarness { 'claude' }
        @(Get-FmSupervisionInstructions -ReadOnly 0) |
            Should -Contain 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: claude'
    }
}

Describe 'Invoke-FmSessionStartNudge' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        $env:FM_ROOT_OVERRIDE = $script:TestHome.Path
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'tells a resumed session to take the helm, in the operational-input wire form' {
        Mock Test-FmHookPrimaryScope { $true }
        Mock Test-FmSessionLockOwnedBySelf { $false }
        $nudge = Invoke-FmSessionStartNudge
        $nudge | Should -BeLike "$([char]0x2063)FIRSTMATE_OP: v1 session-start: *"
        $nudge | Should -BeLike '*bin/fm-session-start.ps1*'
    }

    It 'stays silent for a session that already holds the lock' {
        Mock Test-FmHookPrimaryScope { $true }
        Mock Test-FmSessionLockOwnedBySelf { $true }
        Invoke-FmSessionStartNudge | Should -BeNullOrEmpty
    }

    It 'stays silent outside the primary scope, so a task worktree never nudges' {
        Mock Test-FmHookPrimaryScope { $false }
        Invoke-FmSessionStartNudge | Should -BeNullOrEmpty
    }

    It 'never throws, because a SessionStart failure blocks session initialization' {
        Mock Test-FmHookPrimaryScope { throw 'boom' }
        { Invoke-FmSessionStartNudge } | Should -Not -Throw
    }
}
