#requires -Version 7.0
<#
    Pester tests for the watcher loop.

    The load-bearing property under test is "no wake is missed": the signature
    scan catches changes that happened while no watcher was running, markers
    advance only after a durable record exists, and every absent collaborating
    seam fails toward SURFACING rather than absorbing.
#>

# The seam stubs below declare their owner's full published parameter list and
# then ignore it, which is the point of the stub: a stub that dropped a name
# would make the caller's by-name invocation throw and its catch would read that
# as "no owner", and a stub declaring no parameters at all would swallow the
# arguments into $args unnoticed. PSReviewUnusedParameter is inverted here.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Test seam stubs must declare their owner''s full published parameter list without using it; see the comment above.')]
param()
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestHome {
        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-watch-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $env:FM_ROOT_OVERRIDE = $fmHome
        $env:FM_HOME = $fmHome
        $env:FM_STATE_OVERRIDE = (Join-Path $fmHome 'state')
        # Keep every cadence out of the way unless a test opts in.
        $env:FM_SIGNAL_GRACE = '0'
        $env:FM_POLL = '1'
        $env:FM_CHECK_INTERVAL = '999999'
        $env:FM_HEARTBEAT = '999999'
        return $fmHome
    }

    function Remove-TestHome {
        param($Path)
        # Every key any test in this file sets is cleared here, not at the end of
        # the test that set it: Pester containers share one process, so a key left
        # behind decides another FILE's behaviour (CONTRIBUTING.md).
        foreach ($name in @('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_SIGNAL_GRACE',
                'FM_POLL', 'FM_CHECK_INTERVAL', 'FM_HEARTBEAT', 'FM_STALE_ESCALATE_SECS',
                'FM_WEDGE_DEMAND_INSPECT_COUNT', 'FM_WATCH_DISABLE_FSNOTIFY',
                'FM_BUSY_TURN_MAX_SECS', 'FM_PAUSE_RESURFACE_SECS')) {
            Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
        }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Invoke-WatchScript {
        <# Run the real entry point out-of-process, the way a harness arms it. #>
        param([int]$MaxCycles = 1)
        $script = Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1'
        $out = pwsh -NoProfile -File $script -MaxCycles $MaxCycles -SkipTerminalWait 2>$null
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
}

Describe 'Signal signature scan' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'reports a status file that has never been seen' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"

        $changes = @(Get-FmWatchSignalChanges -Context $script:Ctx)
        $changes.Count | Should -Be 1
        $changes[0].Path | Should -BeLike '*alpha.status'
        $changes[0].Signature | Should -Match '^\d+:\d+$'
    }

    It 'reports turn-end markers as well as status files' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "x`n"
        Update-FmFileTimestamp -Path (Join-Path $script:Ctx.State 'alpha.turn-ended')

        @(Get-FmWatchSignalChanges -Context $script:Ctx).Count | Should -Be 2
    }

    It 'goes quiet once the observed signature is persisted' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"
        foreach ($c in @(Get-FmWatchSignalChanges -Context $script:Ctx)) { Set-FmSignalSeen -Change $c }

        @(Get-FmWatchSignalChanges -Context $script:Ctx).Count | Should -Be 0
    }

    It 'catches a same-second rewrite that changes size' {
        # The reason the signature is size:mtime and not mtime alone: a strict
        # newer-than comparison would let this through.
        $path = Join-Path $script:Ctx.State 'alpha.status'
        Set-FmFileTextLf -Path $path -Text "a`n"
        $changes = @(Get-FmWatchSignalChanges -Context $script:Ctx)
        foreach ($c in $changes) { Set-FmSignalSeen -Change $c }

        $stamp = [System.IO.File]::GetLastWriteTimeUtc($path)
        Set-FmFileTextLf -Path $path -Text "a`nbb`n"
        [System.IO.File]::SetLastWriteTimeUtc($path, $stamp)

        @(Get-FmWatchSignalChanges -Context $script:Ctx).Count | Should -Be 1
    }

    It 'catches a signal that landed while no watcher was running' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "a`n"
        foreach ($c in @(Get-FmWatchSignalChanges -Context $script:Ctx)) { Set-FmSignalSeen -Change $c }
        # No watcher process exists at all during this write.
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "blocked: need a decision`n"

        @(Get-FmWatchSignalChanges -Context $script:Ctx).Count | Should -Be 1
    }

    It 'ignores unrelated files in the state directory' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.meta') -Text "window=s:1`n"
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.hash-x') -Text 'abc'

        @(Get-FmWatchSignalChanges -Context $script:Ctx).Count | Should -Be 0
    }
}

Describe 'Watcher cycle' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'queues a signal and prints it as the actionable reason' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: finished`n"

        $r = Invoke-WatchScript
        $r.ExitCode | Should -Be 0
        ($r.Output -join "`n") | Should -BeLike '*signal:*alpha.status*'

        $rows = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)
        $rows.Count | Should -Be 1
        $rows[0] | Should -Match "\tsignal\talpha\.status\t"
    }

    It 'surfaces rather than absorbs when no classifier seam is present' {
        # The classifier lives in another area of the module. Its absence must
        # never turn into a swallowed finish.
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "working: still going`n"

        $r = Invoke-WatchScript
        ($r.Output -join "`n") | Should -BeLike '*signal:*'
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'advances the seen marker only for a signal it actually queued' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"
        $null = Invoke-WatchScript

        $seen = Join-Path $script:Ctx.State '.seen-alpha_status'
        [System.IO.File]::Exists($seen) | Should -BeTrue
        (Get-FmFileTextOrEmpty -Path $seen) | Should -Be (Get-FmFileSignature -Path (Join-Path $script:Ctx.State 'alpha.status'))
    }

    It 'coalesces a status write and the same turn s turn-end into one wake' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"
        Update-FmFileTimestamp -Path (Join-Path $script:Ctx.State 'alpha.turn-ended')

        $r = Invoke-WatchScript
        # One printed reason naming both files, two durable records under it.
        @($r.Output | Where-Object { $_ -like 'signal:*' }).Count | Should -Be 1
        ($r.Output -join "`n") | Should -BeLike '*alpha.status*'
        ($r.Output -join "`n") | Should -BeLike '*alpha.turn-ended*'
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 2
    }

    It 'records the liveness beacon and the singleton lock metadata' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"
        $null = Invoke-WatchScript

        [System.IO.File]::Exists($script:Ctx.Beacon) | Should -BeTrue
        # The lock is released on exit, and the recovery state persists.
        [System.IO.Directory]::Exists($script:Ctx.WatchLock) | Should -BeFalse
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:*'
    }

    It 'stays quiet and keeps blocking when nothing changed' {
        $r = Invoke-WatchScript
        $r.ExitCode | Should -Be 0
        @($r.Output | Where-Object { $_ }).Count | Should -Be 0
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }

    It 'refuses to start a second watcher while one holds the lock' {
        $null = Lock-FmPath -LockDir $script:Ctx.WatchLock
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        try {
            $r = Invoke-WatchScript
            $r.ExitCode | Should -Be 0
            ($r.Output -join "`n") | Should -BeLike "watcher: already running pid $PID*"
        }
        finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
    }

    It 'refuses to re-arm behind a live watcher whose heartbeat has gone stale' {
        $null = Lock-FmPath -LockDir $script:Ctx.WatchLock
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        [System.IO.File]::SetLastWriteTimeUtc($script:Ctx.Beacon, [DateTime]::UtcNow.AddSeconds(-1000))
        try {
            (Invoke-WatchScript).ExitCode | Should -Be 1
        }
        finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
    }

    It 'resurfaces durable wakes left behind by a watcher that died' {
        Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "1`t1`tsignal`talpha.status`tsignal: old`n"

        $r = Invoke-WatchScript
        ($r.Output -join "`n") | Should -BeLike '*check: rearm-resurface*'
    }

    It 'refuses every check it cannot authenticate, without executing it' {
        $env:FM_CHECK_INTERVAL = '0'
        $canary = Join-Path $script:Ctx.State 'canary'
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.check.sh') `
            -Text "#!/bin/sh`ntouch '$canary'`n"

        $r = Invoke-WatchScript
        ($r.Output -join "`n") | Should -BeLike '*check: rejected unauthenticated state checks:*alpha.check.sh*'
        [System.IO.File]::Exists($canary) | Should -BeFalse
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\tcheck\tunauthenticated-state-checks\t"
    }

    It 'runs the whole loop against a real durable queue and drain' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "blocked: needs a decision`n"
        $null = Invoke-WatchScript

        $drain = Join-Path $script:RepoRoot 'bin' 'fm-wake-drain.ps1'
        $presented = @(pwsh -NoProfile -File $drain 2>$null)
        $presented | Where-Object { $_ -match "\tsignal\talpha\.status\t" } | Should -Not -BeNullOrEmpty

        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]
        $null = pwsh -NoProfile -File $drain -AckThrough (Get-FmWakeMaxSeq -Path $script:Ctx.Queue) -RecoveryGeneration $gen 2>$null
        $LASTEXITCODE | Should -Be 0
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }
}

Describe 'Heartbeat backstop' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'absorbs a due heartbeat when nothing captain-relevant is unsurfaced' {
        $env:FM_HEARTBEAT = '0'
        $settings = Get-FmWatchSettings
        Update-FmFileTimestamp -Path (Join-Path $script:Ctx.State '.last-heartbeat')

        Invoke-FmWatchHeartbeat -Context $script:Ctx -Settings $settings
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.heartbeat-streak')) | Should -Be '1'
    }

    It 'backs the interval off as the streak grows and caps it' {
        $env:FM_HEARTBEAT = '600'
        $env:FM_HEARTBEAT_MAX = '7200'
        $settings = Get-FmWatchSettings
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.heartbeat-streak') -Text "3`n"
        Update-FmFileTimestamp -Path (Join-Path $script:Ctx.State '.last-heartbeat')
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $script:Ctx.State '.last-heartbeat'), [DateTime]::UtcNow.AddSeconds(-4000))

        # 600 * 2^3 = 4800s, so a 4000s-old heartbeat is not due yet.
        Invoke-FmWatchHeartbeat -Context $script:Ctx -Settings $settings
        (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.heartbeat-streak')) | Should -Be '3'
        Remove-Item -Path 'env:FM_HEARTBEAT_MAX' -ErrorAction SilentlyContinue
    }

    It 'queues and exits on every heartbeat while away mode owns triage' {
        $env:FM_HEARTBEAT = '0'
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.afk') -Text ''
        $settings = Get-FmWatchSettings

        { Invoke-FmWatchHeartbeat -Context $script:Ctx -Settings $settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\theartbeat\theartbeat\theartbeat$"
    }
}

Describe 'Wedge timer' {
    BeforeEach {
        $script:TestHome = New-TestHome
        $script:Ctx = Get-FmWakeContext
        $env:FM_STALE_ESCALATE_SECS = '240'
        $script:Settings = Get-FmWatchSettings
        $script:Since = Join-Path $script:Ctx.State '.stale-since-s_1'
        $script:Esc = Join-Path $script:Ctx.State '.wedge-escalations-s_1'
    }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'starts the timer when none exists, self-healing a watcher restart' {
        Invoke-FmWedgeTimerCheck -Window 's:1' -SinceFile $script:Since -Label 'non-terminal stale' `
            -EscalationFile $script:Esc -Context $script:Ctx -Settings $script:Settings

        (Get-FmFirstLine -Path $script:Since) | Should -Match '^\d+$'
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }

    It 'stays quiet while the pane is still inside the escalation window' {
        Set-FmFileTextLf -Path $script:Since -Text (((Get-FmUnixTime) - 10).ToString() + "`n")

        Invoke-FmWedgeTimerCheck -Window 's:1' -SinceFile $script:Since -Label 'non-terminal stale' `
            -EscalationFile $script:Esc -Context $script:Ctx -Settings $script:Settings
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }

    It 'escalates once past the threshold and resets its own timer' {
        Set-FmFileTextLf -Path $script:Since -Text (((Get-FmUnixTime) - 300).ToString() + "`n")

        { Invoke-FmWedgeTimerCheck -Window 's:1' -SinceFile $script:Since -Label 'non-terminal stale' `
                -EscalationFile $script:Esc -Context $script:Ctx -Settings $script:Settings } | Should -Throw

        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -BeLike '*possible wedge, escalation 1)*'
        [System.IO.File]::Exists($script:Since) | Should -BeFalse
        (Get-FmFirstLine -Path $script:Esc) | Should -Be '1'
    }

    It 'demands deep inspection once the same pane keeps re-wedging' {
        Set-FmFileTextLf -Path $script:Esc -Text "2`n"
        Set-FmFileTextLf -Path $script:Since -Text (((Get-FmUnixTime) - 300).ToString() + "`n")

        { Invoke-FmWedgeTimerCheck -Window 's:1' -SinceFile $script:Since -Label 'non-terminal stale' `
                -EscalationFile $script:Esc -Context $script:Ctx -Settings $script:Settings } | Should -Throw

        $row = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0]
        $row | Should -BeLike '*demand-deep-inspection*'
        $row | Should -BeLike '*wedge-escalated 3 times in a row*'
    }

    It 'treats a corrupt timer as a fresh one rather than escalating blindly' {
        Set-FmFileTextLf -Path $script:Since -Text "not-a-timestamp`n"

        Invoke-FmWedgeTimerCheck -Window 's:1' -SinceFile $script:Since -Label 'non-terminal stale' `
            -EscalationFile $script:Esc -Context $script:Ctx -Settings $script:Settings
        (Get-FmFirstLine -Path $script:Since) | Should -Match '^\d+$'
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }
}

Describe 'Window keys and pane hashing' {
    It 'maps a window to the same state-file key the bash watcher uses' {
        Get-FmWindowKey -Window 'fm:1.2' | Should -Be 'fm_1_2'
        Get-FmWindowKey -Window 'sess:0' | Should -Be 'sess_0'
        Get-FmWindowKey -Window 'a/b.c:d' | Should -Be 'a_b_c_d'
    }

    It 'hashes identical pane captures identically and different ones differently' {
        Get-FmPaneHash -Text 'same' | Should -Be (Get-FmPaneHash -Text 'same')
        Get-FmPaneHash -Text 'a' | Should -Not -Be (Get-FmPaneHash -Text 'b')
        Get-FmPaneHash -Text 'a' | Should -Match '^[0-9a-f]{32}$'
    }
}

Describe 'Terminal wait' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Stop-FmWatchFileNotifier; Remove-TestHome -Path $script:TestHome }

    It 'falls back to a plain sleep when the file notifier is unavailable' {
        $env:FM_WATCH_DISABLE_FSNOTIFY = '1'
        Start-FmWatchFileNotifier -Context $script:Ctx | Should -BeFalse

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-FmWatchInterval -Seconds 1 | Should -BeFalse
        $sw.Stop()
        $sw.Elapsed.TotalMilliseconds | Should -BeGreaterThan 900
    }

    It 'returns early when the state directory changes' {
        Start-FmWatchFileNotifier -Context $script:Ctx | Should -BeTrue
        Start-Sleep -Milliseconds 200
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $early = Wait-FmWatchInterval -Seconds 20
        $sw.Stop()

        $early | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'still waits the full interval when nothing happens' {
        Start-FmWatchFileNotifier -Context $script:Ctx | Should -BeTrue
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-FmWatchInterval -Seconds 2 | Should -BeFalse
        $sw.Stop()
        $sw.Elapsed.TotalMilliseconds | Should -BeGreaterThan 1800
    }
}

Describe 'Process-event surfacing' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'surfaces a queued but unsurfaced captured result exactly once' {
        $null = Add-FmWakeRecord -Kind check -Key 'procevent:build' -Payload 'check: captured'

        { Invoke-FmProceventSurface -Context $script:Ctx } | Should -Throw
        [System.IO.File]::Exists((Get-FmProceventSurfacedMarker -Key 'procevent:build' -Context $script:Ctx)) |
            Should -BeTrue

        # Already surfaced: the second pass must stay silent.
        { Invoke-FmProceventSurface -Context $script:Ctx } | Should -Not -Throw
    }

    It 'ignores queued check records that are not process-event results' {
        $null = Add-FmWakeRecord -Kind check -Key 'alpha.check.sh' -Payload 'check: something'
        { Invoke-FmProceventSurface -Context $script:Ctx } | Should -Not -Throw
    }

    It 'releases the queue lock whether or not it surfaced anything' {
        $null = Add-FmWakeRecord -Kind check -Key 'procevent:build' -Payload 'check: captured'
        # The delivery unwinds by design; this case asserts the lock release, not the throw.
        try { Invoke-FmProceventSurface -Context $script:Ctx } catch { Write-Debug "expected delivery unwind: $_" }

        Lock-FmPath -LockDir $script:Ctx.QueueLock | Should -BeTrue
        Unlock-FmPath -LockDir $script:Ctx.QueueLock
    }
}

Describe 'Signal triage with the classifier present' {
    <#
        The absorb side of triage only exists when the classifier seam is
        available. These stubs stand in for it so both outcomes are covered:
        fail-closed surfacing is tested above, deliberate absorption here.
    #>
    BeforeAll {
        # The names are the classifier's real ones. They used to be spelled
        # Test-FmSignalActionable here, which no owner has ever defined, so
        # these stubs stood in for nothing and the triage under test ran
        # against the real classifier while the assertions described the stub.
        function Test-FmSignalReasonIsActionable { param($Path) return $script:StubActionable }
        function Test-FmSignalCrewProvablyWorking { param($Path) return $script:StubWorking }
    }
    AfterAll {
        foreach ($n in @('Test-FmSignalReasonIsActionable', 'Test-FmSignalCrewProvablyWorking')) {
            Remove-Item -Path "function:$n" -ErrorAction SilentlyContinue
        }
    }
    BeforeEach {
        $script:TestHome = New-TestHome
        $script:Ctx = Get-FmWakeContext
        $script:Settings = Get-FmWatchSettings
        $script:StubActionable = $false
        $script:StubWorking = $true
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "working: still going`n"
    }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'absorbs a no-verb signal whose crew is provably working' {
        Invoke-FmWatchSignalCycle -Context $script:Ctx -Settings $script:Settings

        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        # The marker still advances, so the absorbed wake does not re-fire.
        (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.seen-alpha_status')) |
            Should -Be (Get-FmFileSignature -Path (Join-Path $script:Ctx.State 'alpha.status'))
        (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.watch-triage.log')) |
            Should -BeLike '*absorbed benign signal:*'
    }

    It 'surfaces a captain-relevant signal without consulting the costly crew read' {
        $script:StubActionable = $true
        $script:StubWorking = $true   # would absorb, if it were even asked

        { Invoke-FmWatchSignalCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
        # The surfaced marker is what stops the heartbeat backstop raising a
        # second wake for the line this cycle just enqueued.
        (Get-FmFileTextOrEmpty -Path (Get-FmHeartbeatSurfacedPath -Task 'alpha' -Context $script:Ctx)) |
            Should -Be 'working: still going'
    }

    It 'surfaces a no-verb signal whose crew stopped without a captain-relevant status' {
        $script:StubWorking = $false

        { Invoke-FmWatchSignalCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\tsignal\talpha\.status\t"
    }

    It 'hands every wake to the daemon while away mode is on, absorbing nothing' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.afk') -Text ''

        { Invoke-FmWatchSignalCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
    }
}

Describe 'Pane staleness with the backend present' {
    BeforeAll {
        function Get-FmRecordedWindows { param($State) return @('sess:1') }
        function Get-FmBackendCapture { param($Window, $State, $Lines) return $script:StubPane }
        function Get-FmWindowKind { param($Window, $State) return 'ship' }
        function Get-FmWindowTask { param($Window, $State) return 'alpha' }
        function Test-FmWindowBusy { param($Window, $State, $Tail) return $script:StubBusy }
        function Test-FmStaleIsTerminal { param($Window, $State) return $script:StubTerminal }
        function Test-FmCrewProvablyWorking { param($Task) return $script:StubCrewWorking }
        function Get-FmCrewAbsorbClass { param($Task) return $script:StubAbsorbClass }
        function Get-FmLastStatusLine { param($Path) return $script:StubLastLine }
        function Test-FmStatusPaused { param($Line) return $script:StubPaused }
        function Test-FmStatusPausedOrCaptainHeld { param($Line) return $script:StubPaused }
        function Get-FmBackendAgentAlive { param($Window, $State) return $script:StubAgentAlive }

        function New-StaleTaskMeta {
            <# Give sess:1 a real task record, so Convert-FmWindowToTask resolves
               it to alpha and the busy bound reads alpha's own evidence. #>
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.meta') -Text "window=sess:1`n"
        }

        function Set-EvidenceAge {
            <# Age every progress anchor the busy bound consults. -SkipPaneHash
               leaves the watcher's own pane-hash marker alone, which is how a
               worker that is silent but still producing pane output looks. #>
            param([Parameter(Mandatory)][int]$Seconds, [switch]$SkipPaneHash)
            $names = @('alpha.meta', 'alpha.status', 'alpha.turn-ended')
            if (-not $SkipPaneHash) { $names += '.hash-sess_1' }
            foreach ($name in $names) {
                $p = Join-Path $script:Ctx.State $name
                if ([System.IO.File]::Exists($p)) {
                    [System.IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddSeconds(-$Seconds))
                }
            }
        }
    }
    AfterAll {
        foreach ($n in @('Get-FmRecordedWindows', 'Get-FmBackendCapture', 'Get-FmWindowKind', 'Get-FmWindowTask',
                'Test-FmWindowBusy', 'Test-FmStaleIsTerminal', 'Test-FmCrewProvablyWorking', 'Get-FmCrewAbsorbClass',
                'Get-FmLastStatusLine', 'Test-FmStatusPaused', 'Test-FmStatusPausedOrCaptainHeld', 'Get-FmBackendAgentAlive',
                'New-StaleTaskMeta', 'Set-EvidenceAge')) {
            Remove-Item -Path "function:$n" -ErrorAction SilentlyContinue
        }
    }
    BeforeEach {
        $script:TestHome = New-TestHome
        $script:Ctx = Get-FmWakeContext
        $script:Settings = Get-FmWatchSettings
        $script:StubPane = 'pane contents'
        $script:StubBusy = $false
        $script:StubTerminal = $false
        $script:StubCrewWorking = $false
        $script:StubAbsorbClass = 'none'
        $script:StubLastLine = 'working: going'
        $script:StubPaused = $false
        $script:StubAgentAlive = 'dead'
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "working: going`n"
    }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'needs two consecutive identical hashes before calling a pane stale' {
        # First sight records the hash and zeroes the counter; the first matching
        # poll only takes the counter to 1. Two matches are required.
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings
        (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.hash-sess_1')) | Should -Not -BeNullOrEmpty
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings
        (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.count-sess_1')) | Should -Be '1'
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse

        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        # The reason now carries the run-liveness clause; the stale verdict itself
        # is still the whole of the payload before it.
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\tstale\tsess:1\tstale: sess:1 "
    }

    It 'resets the count when the pane changes again' {
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings
        $script:StubPane = 'something new'
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings

        (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.count-sess_1')) | Should -Be '0'
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }

    It 'never calls a busy pane stale' {
        $script:StubBusy = $true
        1..3 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
    }

    It 'absorbs a provably-working stale and starts its wedge timer instead' {
        $script:StubAbsorbClass = 'working'
        1..3 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }

        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.stale-since-sess_1')) | Should -Match '^\d+$'
    }

    It 'lets an active run override a stale captain-relevant status line' {
        # The exact 2026-07 false-surface case: the log still reads done: from
        # before a validation started, but the pipeline is genuinely running.
        $script:StubTerminal = $true
        $script:StubCrewWorking = $true
        1..3 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }

        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.watch-triage.log')) |
            Should -BeLike '*overriding a stale captain-relevant status*'
    }

    It 'surfaces a terminal stale when the crew is not provably working' {
        $script:StubTerminal = $true
        1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }

        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'absorbs a declared pause on the long recheck cadence rather than wedging it' {
        $script:StubPaused = $true
        $script:StubAbsorbClass = 'paused'
        1..3 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }

        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        [System.IO.File]::Exists((Join-Path $script:Ctx.State '.paused-sess_1')) | Should -BeTrue
        [System.IO.File]::Exists((Join-Path $script:Ctx.State '.stale-since-sess_1')) | Should -BeFalse
    }

    It 're-surfaces a long-standing pause once, so a forgotten hold cannot rot invisibly' {
        $env:FM_PAUSE_RESURFACE_SECS = '60'
        $settings = Get-FmWatchSettings
        $status = Join-Path $script:Ctx.State 'alpha.status'
        [System.IO.File]::SetLastWriteTimeUtc($status, [DateTime]::UtcNow.AddSeconds(-600))

        { Invoke-FmPausedStale -Window 'sess:1' -Task 'alpha' -Hash 'abc' -Context $script:Ctx -Settings $settings } |
            Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -BeLike '*awaiting external - declared pause*'

        # Throttled: the next poll inside the same window stays quiet.
        Invoke-FmPausedStale -Window 'sess:1' -Task 'alpha' -Hash 'abc' -Context $script:Ctx -Settings $settings
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'queues one wake per distinct stale hash while away mode owns triage' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.afk') -Text ''
        1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }

        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
        # Same hash again: already classified, so nothing more is queued.
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'carries the run-liveness reading into the surfaced stale reason' {
        # The whole point of the clause: a supervisor reading the wake must not
        # have to derive this by hand. The ad-hoc derivation that preceded it was
        # wrong in every recorded instance (docs/finished-run-stall.md).
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'none'; ProcessId = @(); AgentProcessId = @(9); Detail = 'x' }
        }
        try {
            1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }
            { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
            @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match 'run-liveness: none - no live process'
        }
        finally { Remove-Item -Path 'function:Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue }
    }

    It 'names the live processes, and warns off the false "your run finished" steer' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'processes'; ProcessId = @(4242, 4243); AgentProcessId = @(9); Detail = 'x' }
        }
        try {
            1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }
            { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
            $record = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0]
            $record | Should -Match 'run-liveness: 2 live process'
            $record | Should -Match '4242, 4243'
            $record | Should -Match 'do not tell this worker its run has finished'
        }
        finally { Remove-Item -Path 'function:Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue }
    }

    It 'says the reading did NOT run rather than staying silent about it' {
        # Silence would read as "nothing is running", which is the direction this
        # whole area exists to refuse.
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            throw 'no process table here'
        }
        try {
            1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings }
            { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $script:Settings } | Should -Throw
            @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match 'run-liveness: unknown.*did NOT run'
        }
        finally { Remove-Item -Path 'function:Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue }
    }

    It 'carries the reading into a wedge escalation too' {
        function Get-FmTaskRunLiveness {
            param($TaskId, $StatePath, $DataPath, $Table)
            return [pscustomobject]@{ TaskId = $TaskId; State = 'processes'; ProcessId = @(555); AgentProcessId = @(9); Detail = 'x' }
        }
        try {
            $env:FM_STALE_ESCALATE_SECS = '1'
            $settings = Get-FmWatchSettings
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.stale-since-sess_1') -Text (((Get-FmUnixTime) - 300).ToString() + "`n")
            { Invoke-FmWedgeTimerCheck -Window 'sess:1' -SinceFile (Join-Path $script:Ctx.State '.stale-since-sess_1') `
                    -Label 'test' -EscalationFile (Join-Path $script:Ctx.State '.wedge-escalations-sess_1') `
                    -Context $script:Ctx -Settings $settings } | Should -Throw
            @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match 'run-liveness: 1 live process'
        }
        finally {
            Remove-Item -Path 'function:Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue
            Remove-Item -Path 'env:FM_STALE_ESCALATE_SECS' -ErrorAction SilentlyContinue
        }
    }

    It 'bounds a busy pane that has gone too long with no observed progress' {
        $script:StubBusy = $true
        $env:FM_BUSY_TURN_MAX_SECS = '600'
        $env:FM_STALE_ESCALATE_SECS = '240'
        $settings = Get-FmWatchSettings
        New-StaleTaskMeta
        # Settle a hash first: the bound governs a pane that is BUSY AND UNCHANGED.
        1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings }
        Set-EvidenceAge -Seconds 7200
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.stale-since-sess_1') -Text (((Get-FmUnixTime) - 300).ToString() + "`n")

        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -BeLike '*possible wedge, escalation 1)*'
    }

    It 'keeps escalating a busy pane whose evidence stays stale' {
        # Escalation must still climb for a genuinely stuck worker: a busy footer
        # that redraws nothing buys one absorption, not permanent silence.
        $script:StubBusy = $true
        $env:FM_BUSY_TURN_MAX_SECS = '600'
        $env:FM_STALE_ESCALATE_SECS = '240'
        $settings = Get-FmWatchSettings
        New-StaleTaskMeta
        1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings }
        $since = Join-Path $script:Ctx.State '.stale-since-sess_1'

        foreach ($expected in 1..3) {
            Set-EvidenceAge -Seconds 7200
            Set-FmFileTextLf -Path $since -Text (((Get-FmUnixTime) - 300).ToString() + "`n")
            { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings } | Should -Throw
            (Get-FmFirstLine -Path (Join-Path $script:Ctx.State '.wedge-escalations-sess_1')) | Should -Be "$expected"
        }
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[2] | Should -BeLike '*demand-deep-inspection*'
    }

    It 'does not wedge-alarm a pane that is silent while its agent is demonstrably working' {
        # The 2026-08-14 false alarm, in the shape it was measured: a crewmate
        # blocking on a 23-minute test suite. herdr reads the agent busy, the pane
        # emits nothing, and the spawn record is hours past the bound - the only
        # thing saying work is happening is that the pane changed recently.
        # Escalation is set to 0 so a crossed bound alarms on the very next cycle
        # rather than depending on wall-clock inside the test.
        $script:StubBusy = $true
        $env:FM_BUSY_TURN_MAX_SECS = '3600'
        $env:FM_STALE_ESCALATE_SECS = '0'
        $settings = Get-FmWatchSettings
        New-StaleTaskMeta
        Set-EvidenceAge -Seconds 7200 -SkipPaneHash

        { 1..6 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings } } |
            Should -Not -Throw
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        [System.IO.File]::Exists((Join-Path $script:Ctx.State '.wedge-escalations-sess_1')) | Should -BeFalse
    }

    It 'still wedge-alarms a pane that is silent while its agent is NOT working' {
        # The case the alarm exists for, and the one that must not get slower: an
        # idle agent behind a frozen pane surfaces once, then escalates on the
        # unchanged 240s cadence. Recent pane-change evidence is no defence here -
        # only a positive busy reading is.
        $script:StubBusy = $false
        $env:FM_BUSY_TURN_MAX_SECS = '3600'
        $env:FM_STALE_ESCALATE_SECS = '240'
        $settings = Get-FmWatchSettings
        New-StaleTaskMeta

        1..2 | ForEach-Object { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings }
        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\tstale\tsess:1\tstale: sess:1 "

        # Already classified: the wedge timer arms, then escalates one threshold
        # later. Nothing about the pane has changed since the surface above.
        Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings
        $since = Join-Path $script:Ctx.State '.stale-since-sess_1'
        (Get-FmFirstLine -Path $since) | Should -Match '^\d+$'

        Set-FmFileTextLf -Path $since -Text (((Get-FmUnixTime) - 240).ToString() + "`n")
        { Invoke-FmWatchStaleCycle -Context $script:Ctx -Settings $settings } | Should -Throw
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[1] | Should -BeLike '*possible wedge, escalation 1)*'
    }
}

Describe 'The busy bound reads observed progress, not time since spawn' {
    BeforeEach {
        $script:TestHome = New-TestHome
        $script:Ctx = Get-FmWakeContext
        $env:FM_BUSY_TURN_MAX_SECS = '600'
        $script:Settings = Get-FmWatchSettings
        foreach ($name in @('alpha.meta', 'alpha.status', 'alpha.turn-ended', '.hash-sess_1')) {
            $p = Join-Path $script:Ctx.State $name
            Set-FmFileTextLf -Path $p -Text "x`n"
            [System.IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddSeconds(-7200))
        }
    }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'crosses the bound when every anchor is stale' {
        Test-FmBusyTurnOverAge -Task 'alpha' -Window 'sess:1' -Context $script:Ctx -Settings $script:Settings |
            Should -BeTrue
    }

    It 'crosses the bound when the endpoint has no evidence at all' {
        # Get-FmPathAge reads an unreadable path as 999999, so absence of evidence
        # stays LOUD rather than reading as brand new.
        Test-FmBusyTurnOverAge -Task 'ghost' -Window 'sess:9' -Context $script:Ctx -Settings $script:Settings |
            Should -BeTrue
    }

    It 'is reset by any one fresh anchor' {
        foreach ($name in @('alpha.turn-ended', 'alpha.status', '.hash-sess_1', 'alpha.meta')) {
            $p = Join-Path $script:Ctx.State $name
            [System.IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow)
            Test-FmBusyTurnOverAge -Task 'alpha' -Window 'sess:1' -Context $script:Ctx -Settings $script:Settings |
                Should -BeFalse -Because "$name is fresh evidence of progress"
            [System.IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddSeconds(-7200))
        }
    }

    It 'reads the pane-hash marker of the window it was asked about, not another' {
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $script:Ctx.State '.hash-sess_1'), [DateTime]::UtcNow)

        Test-FmBusyTurnOverAge -Task 'alpha' -Window 'sess:2' -Context $script:Ctx -Settings $script:Settings |
            Should -BeTrue
    }

    It 'bounds nothing for a window whose task could not be resolved' {
        Test-FmBusyTurnOverAge -Task '' -Window 'sess:1' -Context $script:Ctx -Settings $script:Settings |
            Should -BeFalse
    }
}
