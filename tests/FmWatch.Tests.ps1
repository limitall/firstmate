#requires -Version 7.0
<#
    Pester tests for the watcher loop.

    The load-bearing property under test is "no wake is missed": the signature
    scan catches changes that happened while no watcher was running, markers
    advance only after a durable record exists, and every absent collaborating
    seam fails toward SURFACING rather than absorbing.
#>

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
        foreach ($name in @('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_SIGNAL_GRACE',
                'FM_POLL', 'FM_CHECK_INTERVAL', 'FM_HEARTBEAT', 'FM_STALE_ESCALATE_SECS',
                'FM_WEDGE_DEMAND_INSPECT_COUNT', 'FM_WATCH_DISABLE_FSNOTIFY')) {
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

        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -BeLike '*possible wedge, escalation 1)'
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
        Wait-FmWatchInterval -Seconds 1 -Context $script:Ctx | Should -BeFalse
        $sw.Stop()
        $sw.Elapsed.TotalMilliseconds | Should -BeGreaterThan 900
    }

    It 'returns early when the state directory changes' {
        Start-FmWatchFileNotifier -Context $script:Ctx | Should -BeTrue
        Start-Sleep -Milliseconds 200
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $early = Wait-FmWatchInterval -Seconds 20 -Context $script:Ctx
        $sw.Stop()

        $early | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'still waits the full interval when nothing happens' {
        Start-FmWatchFileNotifier -Context $script:Ctx | Should -BeTrue
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-FmWatchInterval -Seconds 2 -Context $script:Ctx | Should -BeFalse
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
        try { Invoke-FmProceventSurface -Context $script:Ctx } catch { }

        Lock-FmPath -LockDir $script:Ctx.QueueLock | Should -BeTrue
        Unlock-FmPath -LockDir $script:Ctx.QueueLock
    }
}
