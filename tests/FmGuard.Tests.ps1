#requires -Version 7.0
<#
    Pester tests for the liveness beacon, the pull guard, and the turn-end guard.

    Two properties matter most and are tested from both directions: the pull
    guard never blocks (it always returns 0), and the turn-end guard never blocks
    when it cannot read its own input (a guard that fails open is annoying; one
    that blocks on a parse error wedges a session).
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestHome {
        <# A home that also passes the primary-scope test: its own git repo, an
           AGENTS.md and a bin/ directory. #>
        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-guard-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'bin') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'config') -Force
        Set-Content -LiteralPath (Join-Path $fmHome 'AGENTS.md') -Value '# test home'
        & git -C $fmHome init --quiet 2>$null
        $env:FM_ROOT_OVERRIDE = $fmHome
        $env:FM_HOME = $fmHome
        $env:FM_STATE_OVERRIDE = (Join-Path $fmHome 'state')
        $env:FM_SUPERVISION_MODEL = 'persistent'
        return $fmHome
    }

    function Remove-TestHome {
        param($Path)
        foreach ($name in @('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_SUPERVISION_MODEL',
                'FM_GUARD_GRACE', 'FM_GUARD_READ_ONLY', 'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS',
                'FM_CLAUDE_TURNEND_BLOCK_BUDGET', 'FM_CLAUDE_AUTOARM_EPOCH_FRESH')) {
            Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
        }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Set-InFlightTask {
        param($Ctx, $Id = 'alpha')
        Set-FmFileTextLf -Path (Join-Path $Ctx.State "$Id.meta") -Text "window=s:1`nkind=ship`n"
    }

    function Set-HealthyWatcherLock {
        param($Ctx)
        $null = Lock-FmPath -LockDir $Ctx.WatchLock
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'fm-home') -Text ($Ctx.Home + "`n")
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'watcher-path') -Text ((Get-FmWatchPath -Context $Ctx) + "`n")
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'pid-identity') -Text ((Get-FmProcessIdentity -ProcessId $PID) + "`n")
        Update-FmFileTimestamp -Path $Ctx.Beacon
    }
}

Describe 'Liveness beacon' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'creates the beacon when it does not exist' {
        $path = Update-FmWatcherBeacon -Context $script:Ctx
        $path | Should -Be $script:Ctx.Beacon
        [System.IO.File]::Exists($script:Ctx.Beacon) | Should -BeTrue
        (Get-FmPathAge -Path $script:Ctx.Beacon) | Should -BeLessThan 5
    }

    It 'refreshes a stale beacon' {
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        [System.IO.File]::SetLastWriteTimeUtc($script:Ctx.Beacon, [DateTime]::UtcNow.AddSeconds(-900))
        (Get-FmPathAge -Path $script:Ctx.Beacon) | Should -BeGreaterThan 800

        $null = Update-FmWatcherBeacon -Context $script:Ctx
        (Get-FmPathAge -Path $script:Ctx.Beacon) | Should -BeLessThan 5
    }
}

Describe 'Supervision status' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'needs no supervision for an idle home' {
        $s = Get-FmSupervisionStatus -State $script:Ctx.State
        $s.Needed | Should -BeFalse
        $s.InFlight | Should -Be 0
        $s.BeaconDesc | Should -Be 'never'
    }

    It 'needs supervision once a task is in flight' {
        Set-InFlightTask -Ctx $script:Ctx
        Set-InFlightTask -Ctx $script:Ctx -Id 'beta'
        $s = Get-FmSupervisionStatus -State $script:Ctx.State

        $s.Needed | Should -BeTrue
        $s.InFlight | Should -Be 2
    }

    It 'needs supervision for a registered process-event source with no task at all' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Ctx.State 'procevent') -Force
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'procevent' 'build.source') -Text "pid=1`n"
        $s = Get-FmSupervisionStatus -State $script:Ctx.State

        $s.Needed | Should -BeTrue
        $s.InFlight | Should -Be 0
        $s.Sources | Should -Be 1
    }

    It 'needs supervision for an X-mode relay poll' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'x-watch.check.sh') -Text "#!/bin/sh`n"
        (Get-FmSupervisionStatus -State $script:Ctx.State).Needed | Should -BeTrue
    }

    It 'reports beacon freshness against the grace window' {
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        (Get-FmSupervisionStatus -State $script:Ctx.State -Grace 300).WatcherFresh | Should -BeTrue

        [System.IO.File]::SetLastWriteTimeUtc($script:Ctx.Beacon, [DateTime]::UtcNow.AddSeconds(-600))
        $s = Get-FmSupervisionStatus -State $script:Ctx.State -Grace 300
        $s.WatcherFresh | Should -BeFalse
        $s.BeaconDesc | Should -Match '^\d+s ago$'
    }

    It 'reports pending queued wakes' {
        (Get-FmSupervisionStatus -State $script:Ctx.State).QueuePending | Should -BeFalse
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'x'
        (Get-FmSupervisionStatus -State $script:Ctx.State).QueuePending | Should -BeTrue
    }
}

Describe 'Primary scope' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'matches a plain primary checkout' {
        Test-FmPrimaryScope -Root $script:Ctx.Root -State $script:Ctx.State | Should -BeTrue
    }

    It 'refuses a checkout without AGENTS.md or bin' {
        Remove-Item -LiteralPath (Join-Path $script:Ctx.Root 'AGENTS.md') -Force
        Test-FmPrimaryScope -Root $script:Ctx.Root -State $script:Ctx.State | Should -BeFalse
    }

    It 'refuses a directory that is not a git checkout at all' {
        $plain = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-plain-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $plain 'bin') -Force
        Set-Content -LiteralPath (Join-Path $plain 'AGENTS.md') -Value 'x'
        try { Test-FmPrimaryScope -Root $plain -State $script:Ctx.State | Should -BeFalse }
        finally { Remove-Item -LiteralPath $plain -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts a genuinely marked secondmate home' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.Root '.fm-secondmate-home') -Text "some-id`n"
        Test-FmSecondmateHome -Root $script:Ctx.Root | Should -BeTrue
        Test-FmPrimaryScope -Root $script:Ctx.Root -State $script:Ctx.State | Should -BeTrue
    }

    It 'rejects a secondmate marker whose id is empty or unsafe' {
        foreach ($bad in @("`n", "  `n", "bad/id`n", "bad:id`n")) {
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.Root '.fm-secondmate-home') -Text $bad
            Test-FmSecondmateHome -Root $script:Ctx.Root | Should -BeFalse
        }
    }

    It 'strips whitespace from the marker id before validating, as the bash predicate does' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.Root '.fm-secondmate-home') -Text "  some-id  `n"
        Test-FmSecondmateHome -Root $script:Ctx.Root | Should -BeTrue
    }
}

Describe 'Guard banner episode dedup' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'claims the first announcement of an episode and only that one' {
        Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher' | Should -BeTrue
        Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher' | Should -BeFalse
    }

    It 'treats a different failing condition as a new episode' {
        $null = Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher'
        Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'stale-beacon' | Should -BeTrue
    }

    It 're-arms after the episode is cleared by recovery' {
        $null = Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher'
        Clear-FmGuardStaleBanner -State $script:Ctx.State
        Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher' | Should -BeTrue
    }

    It 'lets a read-only session observe an episode without claiming it' {
        Test-FmGuardStaleBannerSeen -State $script:Ctx.State -Key 'no-watcher' | Should -BeFalse
        $null = Request-FmGuardStaleBanner -State $script:Ctx.State -Key 'no-watcher'
        Test-FmGuardStaleBannerSeen -State $script:Ctx.State -Key 'no-watcher' | Should -BeTrue
    }
}

Describe 'Invoke-FmGuard' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'returns 0 and stays silent for an idle home' {
        $err = $( Invoke-FmGuard -Context $script:Ctx | Should -Be 0 ) 2>&1
        $err | Should -BeNullOrEmpty
    }

    It 'returns 0 even when it has an alarm to raise - it warns, it never blocks' {
        Set-InFlightTask -Ctx $script:Ctx
        Invoke-FmGuard -Context $script:Ctx | Should -Be 0
    }

    It 'opens exactly one episode for a continuing lapse' {
        Set-InFlightTask -Ctx $script:Ctx
        $null = Invoke-FmGuard -Context $script:Ctx
        (Get-FmFirstLine -Path (Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -Be 'stale-beacon'

        # A second call in the same episode must not re-claim it.
        $null = Invoke-FmGuard -Context $script:Ctx
        Test-FmGuardStaleBannerSeen -State $script:Ctx.State -Key 'stale-beacon' | Should -BeTrue
    }

    It 'names a missing watcher process, not a stale beacon, when the beacon is fresh' {
        Set-InFlightTask -Ctx $script:Ctx
        Update-FmFileTimestamp -Path $script:Ctx.Beacon

        $null = Invoke-FmGuard -Context $script:Ctx
        (Get-FmFirstLine -Path (Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -Be 'no-watcher'
    }

    It 'ends the episode when supervision recovers' {
        Set-InFlightTask -Ctx $script:Ctx
        $null = Invoke-FmGuard -Context $script:Ctx
        [System.IO.File]::Exists((Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -BeTrue

        Set-HealthyWatcherLock -Ctx $script:Ctx
        try {
            $null = Invoke-FmGuard -Context $script:Ctx
            [System.IO.File]::Exists((Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -BeFalse
        }
        finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
    }

    It 'ends the episode when nothing rides on the watcher any more' {
        Set-InFlightTask -Ctx $script:Ctx
        $null = Invoke-FmGuard -Context $script:Ctx
        Remove-Item -LiteralPath (Join-Path $script:Ctx.State 'alpha.meta') -Force

        $null = Invoke-FmGuard -Context $script:Ctx
        [System.IO.File]::Exists((Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -BeFalse
    }

    It 'leaves episode state untouched in a read-only session' {
        Set-InFlightTask -Ctx $script:Ctx
        $null = Invoke-FmGuard -Context $script:Ctx -ReadOnly
        [System.IO.File]::Exists((Get-FmGuardBannerMarkerPath -State $script:Ctx.State)) | Should -BeFalse
    }

    It 'warns about queued wakes independently of the watcher banner' {
        Set-InFlightTask -Ctx $script:Ctx
        Set-HealthyWatcherLock -Ctx $script:Ctx
        try {
            $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'x'
            (Get-FmSupervisionStatus -State $script:Ctx.State).QueuePending | Should -BeTrue
            Invoke-FmGuard -Context $script:Ctx | Should -Be 0
        }
        finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
    }
}

Describe 'Invoke-FmTurnEndGuard' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    Context 'fail-open paths' {
        It 'allows the turn when the payload is empty' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '' -Context $script:Ctx | Should -Be 0
        }

        It 'allows the turn when the payload is not parseable JSON' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload 'not json at all' -Context $script:Ctx | Should -Be 0
        }

        It 'allows the turn when the loop-guard field has the wrong type' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":"yes"}' -Context $script:Ctx | Should -Be 0
        }

        It 'allows the turn when nothing needs supervision' {
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":false}' -Context $script:Ctx | Should -Be 0
        }

        It 'allows the turn outside a primary checkout' {
            Set-InFlightTask -Ctx $script:Ctx
            Remove-Item -LiteralPath (Join-Path $script:Ctx.Root 'AGENTS.md') -Force
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":false}' -Context $script:Ctx | Should -Be 0
        }
    }

    Context 'default (non-Claude) mode' {
        It 'blocks a turn that would end blind' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":false}' -Context $script:Ctx | Should -Be 2
        }

        It 'never blocks twice in the same turn' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true}' -Context $script:Ctx | Should -Be 0
        }

        It 'honours the typed camel-case spelling over the snake-case one' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '{"stopHookActive":true,"stop_hook_active":false}' -Context $script:Ctx |
                Should -Be 0
        }

        It 'allows the turn when a live identity-matched watcher holds the lock' {
            Set-InFlightTask -Ctx $script:Ctx
            Set-HealthyWatcherLock -Ctx $script:Ctx
            try {
                Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":false}' -Context $script:Ctx | Should -Be 0
            }
            finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
        }

        It 'blocks on a fresh beacon with no live watcher, unlike the pull guard' {
            Set-InFlightTask -Ctx $script:Ctx
            Update-FmFileTimestamp -Path $script:Ctx.Beacon
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":false}' -Context $script:Ctx | Should -Be 2
        }
    }

    Context 'Claude cooperative mode' {
        BeforeEach { $env:FM_CLAUDE_AUTOARM_SYNC_WAIT_MS = '200' }

        It 'ignores stop_hook_active, because Claude sets it on every auto-armed stop' {
            Set-InFlightTask -Ctx $script:Ctx
            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 2
        }

        It 'allows the turn while a live auto-arm holds the owner lock' {
            Set-InFlightTask -Ctx $script:Ctx
            $ownerLock = Join-Path $script:Ctx.State '.claude-autoarm.lock'
            $null = Lock-FmPath -LockDir $ownerLock
            $null = Set-FmLockRole -LockDir $ownerLock -Role autoarm
            try {
                Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                    Should -Be 0
            }
            finally { Unlock-FmPath -LockDir $ownerLock }
        }

        It 'allows the turn on a fresh rewake outcome for this event epoch' {
            Set-InFlightTask -Ctx $script:Ctx
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') `
                -Text ("epoch={0} outcome=rewake done`n" -f (Get-FmUnixTime))

            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 0
        }

        It 'blocks again once that outcome has gone stale' {
            Set-InFlightTask -Ctx $script:Ctx
            $epochFile = Join-Path $script:Ctx.State '.claude-autoarm-epoch'
            Set-FmFileTextLf -Path $epochFile -Text ("epoch={0} outcome=rewake done`n" -f (Get-FmUnixTime))
            [System.IO.File]::SetLastWriteTimeUtc($epochFile, [DateTime]::UtcNow.AddSeconds(-600))

            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 2
        }

        It 'counts one block per event epoch, not one per stop' {
            Set-InFlightTask -Ctx $script:Ctx
            $payload = '{"stop_hook_active":true,"session_id":"s1"}'
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') -Text "epoch=100 outcome=armed done`n"

            $null = Invoke-FmTurnEndGuard -Payload $payload -Claude -Context $script:Ctx
            $budget = Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks')
            $budget | Should -BeLike "*count=1*"

            # Same epoch: the count must not move.
            $null = Invoke-FmTurnEndGuard -Payload $payload -Claude -Context $script:Ctx
            (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks')) | Should -BeLike "*count=1*"

            # New epoch: one more block accounted.
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') -Text "epoch=101 outcome=armed done`n"
            $null = Invoke-FmTurnEndGuard -Payload $payload -Claude -Context $script:Ctx
            (Get-FmFileTextOrEmpty -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks')) | Should -BeLike "*count=2*"
        }

        It 'fails open once, loudly, only for a verified exhausted failure episode' {
            Set-InFlightTask -Ctx $script:Ctx
            $env:FM_CLAUDE_TURNEND_BLOCK_BUDGET = '1'
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-failure-notified') -Text ''
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') -Text "epoch=100 outcome=failed done`n"
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks') `
                -Text "session=s1`ncount=5`nepoch=99`n"

            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 0
            [System.IO.File]::Exists((Join-Path $script:Ctx.State '.claude-autoarm-failure-alarmed')) | Should -BeTrue
        }

        It 'keeps blocking instead of failing open while away mode is on' {
            Set-InFlightTask -Ctx $script:Ctx
            $env:FM_CLAUDE_TURNEND_BLOCK_BUDGET = '1'
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.afk') -Text ''
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-failure-notified') -Text ''
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') -Text "epoch=100 outcome=failed done`n"
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks') `
                -Text "session=s1`ncount=5`nepoch=99`n"

            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 2
            [System.IO.File]::Exists((Join-Path $script:Ctx.State '.claude-autoarm-failure-alarmed')) | Should -BeFalse
        }

        It 'refuses to fail open twice for the same episode' {
            Set-InFlightTask -Ctx $script:Ctx
            $env:FM_CLAUDE_TURNEND_BLOCK_BUDGET = '1'
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-failure-notified') -Text ''
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-failure-alarmed') -Text ''
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-epoch') -Text "epoch=100 outcome=failed done`n"
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks') `
                -Text "session=s1`ncount=5`nepoch=99`n"

            Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                Should -Be 2
        }

        It 'clears the failure episode when the watcher is healthy again' {
            Set-InFlightTask -Ctx $script:Ctx
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State '.claude-autoarm-failure-notified') -Text ''
            Set-HealthyWatcherLock -Ctx $script:Ctx
            try {
                Invoke-FmTurnEndGuard -Payload '{"stop_hook_active":true,"session_id":"s1"}' -Claude -Context $script:Ctx |
                    Should -Be 0
                [System.IO.File]::Exists((Join-Path $script:Ctx.State '.claude-autoarm-failure-notified')) | Should -BeFalse
            }
            finally { Unlock-FmPath -LockDir $script:Ctx.WatchLock }
        }
    }
}

Describe 'Auto-arm epoch parsing' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'reads the epoch and outcome fields' {
        $f = Join-Path $script:Ctx.State '.claude-autoarm-epoch'
        Set-FmFileTextLf -Path $f -Text "epoch=1234 outcome=rewake extra`n"

        Get-FmAutoarmEpochField -EpochFile $f -Field epoch | Should -Be '1234'
        Get-FmAutoarmEpochField -EpochFile $f -Field outcome | Should -Be 'rewake'
    }

    It 'reads nothing from a truncated record with no trailing field' {
        $f = Join-Path $script:Ctx.State '.claude-autoarm-epoch'
        Set-FmFileTextLf -Path $f -Text "epoch=1234 outcome=rewake`n"

        Get-FmAutoarmEpochField -EpochFile $f -Field outcome | Should -Be ''
    }

    It 'reads nothing from a missing file' {
        Get-FmAutoarmEpochField -EpochFile (Join-Path $script:Ctx.State 'nope') -Field outcome | Should -Be ''
    }
}

Describe 'Failure episode reset' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'removes the whole episode under its own lock' {
        foreach ($n in @('.turnend-claude-blocks', '.claude-autoarm-failure-notified', '.claude-autoarm-failure-alarmed')) {
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State $n) -Text ''
        }

        Reset-FmFailureEpisode -State $script:Ctx.State | Should -BeTrue
        foreach ($n in @('.turnend-claude-blocks', '.claude-autoarm-failure-notified', '.claude-autoarm-failure-alarmed')) {
            [System.IO.File]::Exists((Join-Path $script:Ctx.State $n)) | Should -BeFalse
        }
    }

    It 'refuses when a target has been replaced by a directory' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Ctx.State '.turnend-claude-blocks') -Force
        Reset-FmFailureEpisode -State $script:Ctx.State | Should -BeFalse
    }

    It 'refuses held mode unless this process owns the budget lock' {
        Reset-FmFailureEpisode -State $script:Ctx.State -Mode held | Should -BeFalse

        $lock = Join-Path $script:Ctx.State '.turnend-claude-blocks.lock'
        $null = Lock-FmPath -LockDir $lock
        try { Reset-FmFailureEpisode -State $script:Ctx.State -Mode held | Should -BeTrue }
        finally { Unlock-FmPath -LockDir $lock }
    }
}
