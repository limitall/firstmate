#requires -Version 7.0
<#
    Pester tests for the durable wake queue, the portable locks, and the
    generation-bound recovery marker.

    The queue-format tests assert BYTES, not parsed fields: this file is the
    regression guard for the cross-implementation contract, so it must fail if a
    future change emits CRLF, a BOM, or a different separator.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestHome {
        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-test-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $env:FM_ROOT_OVERRIDE = $fmHome
        $env:FM_HOME = $fmHome
        $env:FM_STATE_OVERRIDE = (Join-Path $fmHome 'state')
        return $fmHome
    }

    function Set-HealthyWatcherLock {
        param($Ctx, $WatchPath)
        $null = Lock-FmPath -LockDir $Ctx.WatchLock
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'fm-home') -Text ($Ctx.Home + "`n")
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'watcher-path') -Text ($WatchPath + "`n")
        Set-FmFileTextLf -Path (Join-Path $Ctx.WatchLock 'pid-identity') -Text ((Get-FmWakeProcessIdentity -ProcessId $PID) + "`n")
        Update-FmFileTimestamp -Path $Ctx.Beacon
    }

    function Remove-TestHome {
        param($Path)
        foreach ($name in @('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE')) {
            Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
        }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Wake queue record format' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'writes tab-separated epoch, seq, kind, key and payload terminated by a bare LF' {
        Add-FmWakeRecord -Kind signal -Key 'alpha.status' -Payload 'signal: x' | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($script:Ctx.Queue)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)

        $text | Should -Match '^\d+\t1\tsignal\talpha\.status\tsignal: x\n$'
        # No BOM, no CR anywhere.
        $bytes[0] | Should -Not -Be 0xEF
        $bytes | Should -Not -Contain 13
        @($bytes | Where-Object { $_ -eq 9 }).Count | Should -Be 4
        $bytes[-1] | Should -Be 10
    }

    It 'appends further records without rewriting earlier bytes' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'one'
        $first = [System.IO.File]::ReadAllBytes($script:Ctx.Queue)
        $null = Add-FmWakeRecord -Kind stale -Key 'sess:1' -Payload 'two'
        $second = [System.IO.File]::ReadAllBytes($script:Ctx.Queue)

        $second.Length | Should -BeGreaterThan $first.Length
        for ($i = 0; $i -lt $first.Length; $i++) { $second[$i] | Should -Be $first[$i] }
    }

    It 'replaces TAB, CR and LF in key and payload so a field cannot forge a record' {
        $null = Add-FmWakeRecord -Kind signal -Key "a`tb`nc" -Payload "one`r`ntwo`tthree"
        $line = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0]
        $parts = $line -split "`t"

        $parts.Count | Should -Be 5
        $parts[3] | Should -Be 'a b c'
        $parts[4] | Should -Be 'one  two three'
    }

    It 'allocates strictly increasing sequences that survive across calls' {
        1..3 | ForEach-Object { $null = Add-FmWakeRecord -Kind check -Key "c$_" -Payload "p$_" }
        $seqs = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue | ForEach-Object { [int](($_ -split "`t")[1]) })

        $seqs | Should -Be @(1, 2, 3)
        (Get-FmFirstLine -Path $script:Ctx.SeqFile) | Should -Be '3'
    }

    It 'continues the sequence from a persisted counter after a restart' {
        Set-FmFileTextLf -Path $script:Ctx.SeqFile -Text "41`n"
        $null = Add-FmWakeRecord -Kind heartbeat -Key heartbeat -Payload heartbeat

        ((@(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0]) -split "`t")[1] | Should -Be '42'
    }

    It 'treats a corrupt sequence counter as zero rather than refusing to queue' {
        Set-FmFileTextLf -Path $script:Ctx.SeqFile -Text "garbage`n"
        Add-FmWakeRecord -Kind heartbeat -Key heartbeat -Payload heartbeat | Should -BeTrue

        ((@(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0]) -split "`t")[1] | Should -Be '1'
    }

    It 'rejects an unknown wake kind without touching the queue' {
        Add-FmWakeRecord -Kind bogus -Key k -Payload p 2>$null | Should -BeFalse
        [System.IO.File]::Exists($script:Ctx.Queue) | Should -BeFalse
    }

    It 'publishes a recovery generation before the record exists' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'x'
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -Match '^pending:downtime:[A-Za-z0-9._-]+\n$'
    }
}

Describe 'Queue reading and deduplication' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'keeps first-seen order with last-seen content per kind and key' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'first'
        $null = Add-FmWakeRecord -Kind stale -Key 'sess:1' -Payload 'stale one'
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'second'

        $rows = @(Get-FmWakeDedupedRecords -Path $script:Ctx.Queue)
        $rows.Count | Should -Be 2
        $rows[0] | Should -Match "\tsignal\ta\.status\tsecond$"
        $rows[1] | Should -Match "\tstale\tsess:1\tstale one$"
    }

    It 'collapses every heartbeat into a single row regardless of key' {
        $null = Add-FmWakeRecord -Kind heartbeat -Key heartbeat -Payload heartbeat
        $null = Add-FmWakeRecord -Kind heartbeat -Key other -Payload heartbeat

        @(Get-FmWakeDedupedRecords -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'ignores structurally invalid rows' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'ok'
        Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "not a record`n"

        @(Get-FmWakeDedupedRecords -Path $script:Ctx.Queue).Count | Should -Be 1
    }

    It 'reports the highest numeric sequence as the acknowledgement cutoff' {
        1..4 | ForEach-Object { $null = Add-FmWakeRecord -Kind check -Key "c$_" -Payload 'p' }
        Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "x`tnotnumeric`tcheck`tk`tp`n"

        Get-FmWakeMaxSeq -Path $script:Ctx.Queue | Should -Be 4
    }

    It 'lists distinct queued keys for one kind, oldest first' {
        $null = Add-FmWakeRecord -Kind check -Key 'procevent:one' -Payload 'p'
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'p'
        $null = Add-FmWakeRecord -Kind check -Key 'procevent:two' -Payload 'p'
        $null = Add-FmWakeRecord -Kind check -Key 'procevent:one' -Payload 'p'

        @(Get-FmWakeQueuedKeys -Kind check) | Should -Be @('procevent:one', 'procevent:two')
    }
}

Describe 'Signal key mapping' {
    It 'maps a status key to its own status file' {
        $m = Get-FmWakeStatusKeyMap -Key 'alpha.status'
        $m.StatusKey | Should -Be 'alpha.status'
        $m.Historical | Should -BeFalse
    }

    It 'maps a turn-end key to the task status file and flags it historical' {
        $m = Get-FmWakeStatusKeyMap -Key 'alpha.turn-ended'
        $m.StatusKey | Should -Be 'alpha.status'
        $m.Historical | Should -BeTrue
    }

    It 'refuses traversal, dotfiles, over-long ids, and unrelated keys' {
        Get-FmWakeStatusKeyMap -Key '../../etc/passwd.status' | Should -BeNullOrEmpty
        Get-FmWakeStatusKeyMap -Key '.hidden.status' | Should -BeNullOrEmpty
        Get-FmWakeStatusKeyMap -Key (('a' * 65) + '.status') | Should -BeNullOrEmpty
        Get-FmWakeStatusKeyMap -Key 'sess:1' | Should -BeNullOrEmpty
        Get-FmWakeStatusKeyMap -Key '.status' | Should -BeNullOrEmpty
    }
}

Describe 'Drain-time annotations' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'reports the last non-blank line of the mapped status file' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "working: one`ndone: two`n`n"
        $null = Add-FmWakeRecord -Kind signal -Key 'alpha.status' -Payload 'signal: x'

        $rows = Get-FmWakeDedupedRecords -Path $script:Ctx.Queue
        $ann = @(Get-FmWakeAnnotations -Rows $rows -Context $script:Ctx)
        $ann.Count | Should -Be 1
        $ann[0] | Should -BeLike '*alpha.status: done: two'
        $ann[0] | Should -BeLike 'wake annotation: latest wake-EVENT observed at drain, not current state*'
    }

    It 'labels a turn-end derived annotation as historical' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "working: one`n"
        $null = Add-FmWakeRecord -Kind signal -Key 'alpha.turn-ended' -Payload 'signal: x'

        $ann = @(Get-FmWakeAnnotations -Rows (Get-FmWakeDedupedRecords -Path $script:Ctx.Queue) -Context $script:Ctx)
        $ann[0] | Should -BeLike '*historical / not necessarily the triggering event*'
    }

    It 'caps how many status files one drain will read' {
        1..12 | ForEach-Object {
            Set-FmFileTextLf -Path (Join-Path $script:Ctx.State "task$_.status") -Text "done: $_`n"
            $null = Add-FmWakeRecord -Kind signal -Key "task$_.status" -Payload 'signal: x'
        }
        $ann = @(Get-FmWakeAnnotations -Rows (Get-FmWakeDedupedRecords -Path $script:Ctx.Queue) -Context $script:Ctx)

        @($ann | Where-Object { $_ -like 'wake annotation: latest*' }).Count | Should -Be 8
        $ann[-1] | Should -Be 'wake annotation: 4 annotations omitted (enrichment read cap)'
    }

    It 'marks a line that the bounded tail read may itself have cut' {
        $long = ('x' * 20000)
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text $long
        $null = Add-FmWakeRecord -Kind signal -Key 'alpha.status' -Payload 'signal: x'

        $ann = @(Get-FmWakeAnnotations -Rows (Get-FmWakeDedupedRecords -Path $script:Ctx.Queue) -Context $script:Ctx)
        # -BeLike would read [truncated] as a character class, so compare the suffix.
        $ann[0].EndsWith(' [truncated]') | Should -BeTrue
    }

    It 'ignores a status key that maps to nothing readable' {
        $null = Add-FmWakeRecord -Kind signal -Key 'missing.status' -Payload 'signal: x'
        Get-FmWakeAnnotations -Rows (Get-FmWakeDedupedRecords -Path $script:Ctx.Queue) -Context $script:Ctx |
            Should -BeNullOrEmpty
    }

    It 'ignores non-signal records entirely' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.status') -Text "done: x`n"
        $null = Add-FmWakeRecord -Kind stale -Key 'alpha.status' -Payload 'stale: x'
        Get-FmWakeAnnotations -Rows (Get-FmWakeDedupedRecords -Path $script:Ctx.Queue) -Context $script:Ctx |
            Should -BeNullOrEmpty
    }
}

Describe 'Portable locks' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'grants the lock once and records the holder pid where bash readers look' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        Lock-FmPath -LockDir $lock | Should -BeTrue
        Get-FmLockPid -LockDir $lock | Should -Be ([string]$PID)
        [System.IO.File]::ReadAllText((Join-Path $lock 'pid')) | Should -Be ("$PID`n")
    }

    It 'refuses a second claim while the holder is alive' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = Lock-FmPath -LockDir $lock
        Lock-FmPath -LockDir $lock | Should -BeFalse
        Get-FmLockHeldPid | Should -Be ([string]$PID)
    }

    It 'releases only a lock this process holds' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force
        Set-FmFileTextLf -Path (Join-Path $lock 'pid') -Text "999999999`n"

        Unlock-FmPath -LockDir $lock
        [System.IO.Directory]::Exists($lock) | Should -BeTrue
    }

    It 'recovers a lock whose holder is provably dead' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force
        Set-FmFileTextLf -Path (Join-Path $lock 'pid') -Text "999999999`n"
        # Age it past the mid-acquire window so it cannot be mistaken for a claim
        # still in progress.
        [System.IO.Directory]::SetLastWriteTimeUtc($lock, [DateTime]::UtcNow.AddMinutes(-5))

        Lock-FmPath -LockDir $lock | Should -BeTrue
        Get-FmLockPid -LockDir $lock | Should -Be ([string]$PID)
        Get-FmLockRecoveredPid | Should -Be '999999999'
    }

    It 'claims an empty lock directory, which records no holder at all' {
        # Our claim writes a fully formed pid file into place with File.Move, so
        # a directory with no pid is a crashed claim, not a held lock. The bash
        # implementation never produces one: it writes the pid into a private
        # owner directory BEFORE linking it into place.
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force

        Lock-FmPath -LockDir $lock | Should -BeTrue
        Get-FmLockPid -LockDir $lock | Should -Be ([string]$PID)
    }

    It 'treats a fresh pid-less lock left by the bash implementation as still acquiring' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force

        Test-FmLockMidAcquireFresh -LockDir $lock -LockPid '' | Should -BeTrue
        [System.IO.Directory]::SetLastWriteTimeUtc($lock, [DateTime]::UtcNow.AddMinutes(-5))
        Test-FmLockMidAcquireFresh -LockDir $lock -LockPid '' | Should -BeFalse
    }

    It 'labels a held lock with a role and reads it back' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = Lock-FmPath -LockDir $lock
        Set-FmLockRole -LockDir $lock -Role autoarm | Should -BeTrue
        Get-FmLockRole -LockDir $lock | Should -Be 'autoarm'
    }

    It 'refuses to label a lock this process does not hold' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force
        Set-FmFileTextLf -Path (Join-Path $lock 'pid') -Text "999999999`n"

        Set-FmLockRole -LockDir $lock -Role autoarm | Should -BeFalse
    }

    It 'serialises two processes against the same lock' {
        $lock = Join-Path $script:Ctx.State '.demo.lock'
        # A REAL second process, not a runspace: the guarantee under test is that
        # the OS admits one creator. It loads the whole Private set rather than
        # FmWake.ps1 alone, because the wake area now takes its process, path and
        # env helpers from the foundation instead of carrying its own copies.
        $privateDir = Join-Path $script:RepoRoot 'module' 'Firstmate' 'Private'
        $load = "Get-ChildItem -Path '$privateDir' -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . `$_.FullName }"
        $null = Lock-FmPath -LockDir $lock
        $out = pwsh -NoProfile -Command "$load; if (Lock-FmPath -LockDir '$lock') { 'stole' } else { 'blocked' }"
        Unlock-FmPath -LockDir $lock

        $out | Should -Be 'blocked'
    }
}

Describe 'Recovery marker' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'publishes a well-formed single-line pending token' {
        Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime | Should -BeTrue
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -Match '^pending:downtime:[A-Za-z0-9._-]+\n$'
    }

    It 'moves downtime to handling while keeping the generation' {
        $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime
        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]

        Start-FmRecoveryHandling -Marker $script:Ctx.RecoveryMarker | Should -Be 0
        Get-FmRecoveryMarkerToken | Should -Be "pending:handling:$gen"
    }

    It 'refuses to begin handling for a generation that is not current' {
        $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime
        Start-FmRecoveryHandling -Marker $script:Ctx.RecoveryMarker -ExpectedGeneration 'someone.elses.gen' | Should -Be 3
    }

    It 'acknowledges only the exact generation it was handed' {
        $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime
        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]

        Confirm-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -ExpectedGeneration 'stale.gen.1' | Should -Be 3
        Confirm-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -ExpectedGeneration $gen | Should -Be 0
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -Be "acked:downtime:$gen`n"
    }

    It 'rejects a marker that is not exactly one well-formed line' {
        foreach ($bad in @("pending:downtime:a`npending:downtime:b`n", "pending:downtime:a", "garbage`n", "pending:bogus:a`n", "pending:downtime:has space`n")) {
            Set-FmFileTextLf -Path $script:Ctx.RecoveryMarker -Text $bad
            Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker | Should -BeFalse
        }
    }

    Context 'arm check' {
        It 'asks for nothing when the queue is empty and no marker exists' {
            Test-FmRecoveryArmCheck -Marker $script:Ctx.RecoveryMarker | Should -BeTrue
            Get-FmRecoveryMarkerAction | Should -Be 'none'
        }

        It 'asks a fresh watcher to recover when durable wakes exist with no marker' {
            Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "1`t1`tsignal`ta.status`tp`n"
            Test-FmRecoveryArmCheck -Marker $script:Ctx.RecoveryMarker | Should -BeTrue
            Get-FmRecoveryMarkerAction | Should -Be 'recover'
            [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:downtime:*'
        }

        It 'stands down while another drain is mid-handling' {
            $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind handling
            Test-FmRecoveryArmCheck -Marker $script:Ctx.RecoveryMarker | Should -BeTrue
            Get-FmRecoveryMarkerAction | Should -Be 'wait'
        }

        It 're-opens a generation when wakes remain after an acknowledgement' {
            $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime
            $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
            $null = Confirm-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -ExpectedGeneration (Get-FmRecoveryMarkerToken).Split(':')[-1]
            Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "1`t1`tsignal`ta.status`tp`n"

            Test-FmRecoveryArmCheck -Marker $script:Ctx.RecoveryMarker | Should -BeTrue
            Get-FmRecoveryMarkerAction | Should -Be 'recover'
        }

        It 'quarantines an unreadable marker instead of trusting or deleting it' {
            Set-FmFileTextLf -Path $script:Ctx.RecoveryMarker -Text "corrupt`n"
            Test-FmRecoveryArmCheck -Marker $script:Ctx.RecoveryMarker | Should -BeTrue
            Get-FmRecoveryMarkerAction | Should -Be 'recover'

            $quarantined = @(Get-ChildItem -Path $script:Ctx.State -Filter '.watcher-down.invalid.*' -Force -Directory)
            $quarantined.Count | Should -Be 1
            [System.IO.File]::ReadAllText((Join-Path $quarantined[0].FullName 'marker')) | Should -Be "corrupt`n"
        }
    }
}

Describe 'Watcher liveness predicates' {
    BeforeEach {
        $script:TestHome = New-TestHome
        $script:Ctx = Get-FmWakeContext
        $script:WatchPath = Join-Path $script:Ctx.Root 'bin' 'fm-watch.ps1'
        $env:FM_SUPERVISION_MODEL = 'persistent'
    }
    AfterEach {
        Remove-Item -Path 'env:FM_SUPERVISION_MODEL' -ErrorAction SilentlyContinue
        Remove-TestHome -Path $script:TestHome
    }

    It 'is healthy for a live identity-matched watcher with a fresh beacon' {
        Set-HealthyWatcherLock -Ctx $script:Ctx -WatchPath $script:WatchPath
        Test-FmWatcherHealthy -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home |
            Should -BeTrue
    }

    It 'is unhealthy when the beacon has gone stale beyond grace' {
        Set-HealthyWatcherLock -Ctx $script:Ctx -WatchPath $script:WatchPath
        [System.IO.File]::SetLastWriteTimeUtc($script:Ctx.Beacon, [DateTime]::UtcNow.AddSeconds(-600))

        Test-FmWatcherHealthy -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home |
            Should -BeFalse
    }

    It 'is unhealthy when the lock names a different home or watcher path' {
        Set-HealthyWatcherLock -Ctx $script:Ctx -WatchPath $script:WatchPath
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.WatchLock 'fm-home') -Text "/somewhere/else`n"

        Test-FmWatcherHealthy -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home |
            Should -BeFalse
    }

    It 'is unhealthy when the identity does not match the live process' {
        Set-HealthyWatcherLock -Ctx $script:Ctx -WatchPath $script:WatchPath
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.WatchLock 'pid-identity') -Text "linux-starttime=1 cmdline-hex=00`n"

        Test-FmWatcherHealthy -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home |
            Should -BeFalse
    }

    It 'calls a fresh beacon with no live watcher down under the persistent model' {
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        $v = Get-FmWatcherSupervisionVerdict -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home

        $v.Ok | Should -BeFalse
        $v.Reason | Should -Be 'no-watcher'
    }

    It 'calls the same fresh beacon healthy under the autoarm model' {
        $env:FM_SUPERVISION_MODEL = 'autoarm'
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        (Get-FmWatcherSupervisionVerdict -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home).Ok |
            Should -BeTrue
    }

    It 'reports a stale beacon as the failing condition under the autoarm model' {
        $env:FM_SUPERVISION_MODEL = 'autoarm'
        Update-FmFileTimestamp -Path $script:Ctx.Beacon
        [System.IO.File]::SetLastWriteTimeUtc($script:Ctx.Beacon, [DateTime]::UtcNow.AddSeconds(-600))
        $v = Get-FmWatcherSupervisionVerdict -State $script:Ctx.State -WatchPath $script:WatchPath -Grace 300 -FmHome $script:Ctx.Home

        $v.Ok | Should -BeFalse
        $v.Reason | Should -Be 'stale-beacon'
    }
}

Describe 'Invoke-FmWakeDrain' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'presents deduplicated records without consuming them' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'signal: a'
        $before = [System.IO.File]::ReadAllBytes($script:Ctx.Queue)

        Invoke-FmWakeDrain -Context $script:Ctx | Should -Be 0
        [System.IO.File]::ReadAllBytes($script:Ctx.Queue) | Should -Be $before
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:handling:*'
    }

    It 'consumes acknowledged records and closes the generation when nothing is left' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'signal: a'
        $null = Invoke-FmWakeDrain -Context $script:Ctx
        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]

        Invoke-FmWakeDrain -AckThrough '1' -RecoveryGeneration $gen -Context $script:Ctx | Should -Be 0
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeFalse
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'acked:*'
    }

    It 'refuses the acknowledgement when a wake arrived during handling, keeping every record' {
        # Appending a wake opens a NEW recovery generation, so the generation the
        # handling turn was handed is no longer current. Failing the
        # acknowledgement is the fail-closed outcome: nothing is consumed and the
        # next drain re-presents everything, including the wake that raced in.
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'signal: a'
        $null = Invoke-FmWakeDrain -Context $script:Ctx
        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]
        $null = Add-FmWakeRecord -Kind stale -Key 'sess:1' -Payload 'stale: sess:1'

        Invoke-FmWakeDrain -AckThrough '1' -RecoveryGeneration $gen -Context $script:Ctx 2>$null | Should -Be 1
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue).Count | Should -Be 2
    }

    It 'consumes only records at or below the cutoff' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'signal: a'
        $null = Add-FmWakeRecord -Kind stale -Key 'sess:1' -Payload 'stale: sess:1'
        $null = Invoke-FmWakeDrain -Context $script:Ctx
        $null = Read-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker
        $gen = (Get-FmRecoveryMarkerToken).Split(':')[-1]

        Invoke-FmWakeDrain -AckThrough '1' -RecoveryGeneration $gen -Context $script:Ctx | Should -Be 0
        $rows = @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)
        $rows.Count | Should -Be 1
        $rows[0] | Should -BeLike "*`tstale`tsess:1`t*"
        # Records remain, so the generation stays open for the next drain.
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:*'
    }

    It 'refuses an acknowledgement carrying a stale generation' {
        $null = Add-FmWakeRecord -Kind signal -Key 'a.status' -Payload 'signal: a'
        $null = Invoke-FmWakeDrain -Context $script:Ctx

        Invoke-FmWakeDrain -AckThrough '1' -RecoveryGeneration 'not.the.gen' -Context $script:Ctx 2>$null | Should -Be 1
        Test-FmNonEmptyFile -Path $script:Ctx.Queue | Should -BeTrue
    }

    It 'rejects malformed acknowledgement arguments' {
        Invoke-FmWakeDrain -AckThrough 'abc' -RecoveryGeneration 'g' -Context $script:Ctx 2>$null | Should -Be 2
        Invoke-FmWakeDrain -AckThrough '1' -RecoveryGeneration 'bad gen' -Context $script:Ctx 2>$null | Should -Be 2
        Invoke-FmWakeDrain -RecoveryGeneration 'g' -Context $script:Ctx 2>$null | Should -Be 2
    }

    It 'still honours a pending recovery generation when the queue is empty' {
        $null = Publish-FmRecoveryMarker -Marker $script:Ctx.RecoveryMarker -Kind downtime

        Invoke-FmWakeDrain -Context $script:Ctx | Should -Be 0
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:handling:*'
    }

    It 'adopts legacy wakes that predate the recovery marker' {
        Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "1`t1`tsignal`ta.status`tsignal: a`n"

        Invoke-FmWakeDrain -Context $script:Ctx | Should -Be 0
        [System.IO.File]::ReadAllText($script:Ctx.RecoveryMarker) | Should -BeLike 'pending:handling:*'
    }

    It 'refuses to present durable wakes sitting on invalid recovery state' {
        Add-FmWakeQueueBytes -Path $script:Ctx.Queue -Record "1`t1`tsignal`ta.status`tsignal: a`n"
        Set-FmFileTextLf -Path $script:Ctx.RecoveryMarker -Text "corrupt`n"

        Invoke-FmWakeDrain -Context $script:Ctx 2>$null | Should -Be 1
    }
}

Describe 'Module assembly' {
    <#
        Cross-area integrity, not a wake-queue concern - parked here until the
        foundation area claims it. Every Private/*.ps1 and Public/*.ps1 is
        dot-sourced into one scope, so two areas defining the same function name
        do not collide loudly: the later file silently WINS, and the earlier
        area's callers start passing arguments to a stranger. That is exactly how
        a duplicate Get-FmGitOutput broke this area's primary-scope test on the
        first rebase onto a main carrying the backend port.
    #>
    It 'defines every function name exactly once across all areas' {
        $defs = @{}
        Get-ChildItem -Recurse -Path (Join-Path $script:RepoRoot 'module') -Filter '*.ps1' | ForEach-Object {
            $file = $_.Name
            foreach ($m in [regex]::Matches((Get-Content -Raw $_.FullName), '(?m)^function\s+([A-Za-z]+-[A-Za-z0-9]+)')) {
                $name = $m.Groups[1].Value
                if (-not $defs.ContainsKey($name)) { $defs[$name] = [System.Collections.Generic.List[string]]::new() }
                if (-not $defs[$name].Contains($file)) { $defs[$name].Add($file) }
            }
        }
        $duplicates = @($defs.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } |
                ForEach-Object { "$($_.Key) in $($_.Value -join ', ')" })

        $duplicates | Should -BeNullOrEmpty -Because 'a name defined twice is silently shadowed by dot-source order'
    }

    It 'uses only approved PowerShell verbs' {
        $approved = (Get-Verb).Verb
        $bad = @()
        Get-ChildItem -Recurse -Path (Join-Path $script:RepoRoot 'module') -Filter '*.ps1' | ForEach-Object {
            foreach ($m in [regex]::Matches((Get-Content -Raw $_.FullName), '(?m)^function\s+([A-Za-z]+)-([A-Za-z0-9]+)')) {
                if ($m.Groups[1].Value -notin $approved) { $bad += "$($m.Groups[0].Value.Substring(9)) in $($_.Name)" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }
}
