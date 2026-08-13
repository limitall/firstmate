#requires -Version 7.0
<#
    Tests for Private/FmLock.ps1 - the per-home mutexes and the session lock.

    The four properties the port must preserve from the bash originals, each
    tested directly rather than inferred:

      1. ONE HOLDER. Proven by real processes competing, not by reading the code:
         a counter incremented under the lock by several processes must land on
         exactly the number of increments.
      2. STALE-HOLDER DETECTION. A dead holder's lock is recoverable, including
         when its process id has been recycled by an unrelated live process.
      3. NO DEADLOCK AFTER A CRASH. A holder killed outright leaves a lock the
         next caller can take, with no cleanup step in between.
      4. FAIL-SAFE RECOVERY. Every uncertain state reads as held, never as
         stealable.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    Import-FmTestModule -TestRoot $PSScriptRoot
    $script:ModulePath = (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1')
    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fmlock-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force
    $script:DeadPid = 2147483600

    function Get-LockPath {
        Join-Path $script:TempRoot ("lock-" + [guid]::NewGuid().ToString('N'))
    }

    # A lock directory whose recorded holder is whatever the caller says, used to
    # stage dead holders, recycled ids and half-written claims.
    function Write-LockHolder {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyString()][string]$HolderPid,
            [string]$Identity
        )
        $null = New-Item -ItemType Directory -Path $Path -Force
        [System.IO.File]::WriteAllText((Join-Path $Path 'pid'), "$HolderPid`n")
        if ($PSBoundParameters.ContainsKey('Identity')) {
            [System.IO.File]::WriteAllText((Join-Path $Path 'pid-identity'), "$Identity`n")
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Acquire and release' {
    It 'acquires a free lock and reports itself as the holder' {
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path
        try {
            $lock | Should -Not -BeNullOrEmpty
            $lock.ProcessId | Should -Be $PID
            $info = Get-FmLockInfo -Path $path
            $info.State | Should -Be 'held'
            $info.ProcessId | Should -Be $PID
            $info.IsHeld | Should -BeTrue
        } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'records the role, home and watcher path a caller supplies' {
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path -Role 'terminal-check' -HomePath '/srv/home-a' -WatcherPath '/x/fm-watch.ps1'
        try {
            $info = Get-FmLockInfo -Path $path
            $info.Role | Should -Be 'terminal-check'
            $info.Home | Should -Be '/srv/home-a'
            $info.WatcherPath | Should -Be '/x/fm-watch.ps1'
        } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'reports a free lock as free' {
        (Get-FmLockInfo -Path (Get-LockPath)).State | Should -Be 'free'
    }

    It 'releases the lock so the next caller can take it' {
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path
        Unlock-FmLock -Lock $lock | Should -BeTrue
        (Get-FmLockInfo -Path $path).State | Should -Be 'free'
        $again = Request-FmLock -Path $path
        $again | Should -Not -BeNullOrEmpty
        $null = Unlock-FmLock -Lock $again
    }

    It 'refuses a second acquisition by the same process instead of waiting for itself' {
        # A lock is held per process, so a second take inside one process would
        # block forever. Failing loudly beats a wedged agent.
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path
        try {
            { Request-FmLock -Path $path } | Should -Throw '*already holds the lock*'
        } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'lists the locks this process holds' {
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path
        try {
            (Get-FmHeldLock -Path $path).ProcessId | Should -Be $PID
            @(Get-FmHeldLock).Path | Should -Contain $lock.Path
        } finally { $null = Unlock-FmLock -Lock $lock }
        Get-FmHeldLock -Path $path | Should -BeNullOrEmpty
    }

    It 'refuses a lock path occupied by a plain file' {
        $path = Get-LockPath
        [System.IO.File]::WriteAllText($path, 'not a lock')
        { Request-FmLock -Path $path } | Should -Throw '*not a lock directory*'
    }
}

Describe 'Mutual exclusion against another live holder' {
    BeforeEach {
        # The parent process is genuinely alive and is not us: a stand-in for
        # another session holding the lock.
        $script:LivePid = Get-FmParentProcessId -Id $PID
        $script:Path = Get-LockPath
        Write-LockHolder -Path $script:Path -HolderPid $script:LivePid `
            -Identity (Get-FmProcessIdentity -Id $script:LivePid)
    }

    It 'does not acquire a lock held by a live process' {
        Request-FmLock -Path $script:Path | Should -BeNullOrEmpty
    }

    It 'reports who holds it, without a second racing read' {
        $null = Request-FmLock -Path $script:Path
        (Get-FmLastLockHolder).ProcessId | Should -Be $script:LivePid
    }

    It 'leaves the holder untouched after a refused acquisition' {
        $null = Request-FmLock -Path $script:Path
        (Get-FmLockInfo -Path $script:Path).ProcessId | Should -Be $script:LivePid
    }

    It 'times out rather than waiting forever, and names the holder' {
        # fm_lock_acquire_wait waits forever; an unattended agent blocked forever
        # is indistinguishable from a wedge, so this bounds the wait instead.
        { Wait-FmLock -Path $script:Path -TimeoutSeconds 1 } |
            Should -Throw "*timed out after 1s*held by process $($script:LivePid)*"
    }
}

Describe 'Stale-holder recovery' {
    It 'recovers a lock whose holder is gone, and says whose it was' {
        $path = Get-LockPath
        Write-LockHolder -Path $path -HolderPid $script:DeadPid -Identity 'proc-starttime=1 name=ghost'
        (Get-FmLockInfo -Path $path).State | Should -Be 'stale'

        $lock = Request-FmLock -Path $path
        try {
            $lock | Should -Not -BeNullOrEmpty
            $lock.RecoveredProcessId | Should -Be $script:DeadPid
        } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'recovers a lock whose process id was recycled by an unrelated process' {
        # THE reason identity is recorded at all: this process id is genuinely
        # alive, but it is not the process that took the lock. Without the
        # identity check the home would stay locked by a ghost forever.
        $path = Get-LockPath
        Write-LockHolder -Path $path -HolderPid $PID -Identity 'proc-starttime=1 name=ghost'
        (Get-FmLockInfo -Path $path).State | Should -Be 'stale'
        $lock = Request-FmLock -Path $path
        try { $lock | Should -Not -BeNullOrEmpty } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'clears the dead holder sidecars rather than attributing them to the new holder' {
        $path = Get-LockPath
        Write-LockHolder -Path $path -HolderPid $script:DeadPid -Identity 'proc-starttime=1 name=ghost'
        [System.IO.File]::WriteAllText((Join-Path $path 'role'), "autoarm`n")
        $lock = Request-FmLock -Path $path
        try {
            $info = Get-FmLockInfo -Path $path
            $info.ProcessId | Should -Be $PID
            $info.Role | Should -BeNullOrEmpty
            $info.Identity | Should -Be (Get-FmProcessIdentity -Id $PID)
        } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'treats a half-written claim as held while it is fresh' {
        # A claimer creates the pid file and writes it as two steps; an empty pid
        # file that young means someone is mid-claim, not that the lock is free.
        $path = Get-LockPath
        Write-LockHolder -Path $path -HolderPid ''
        $info = Get-FmLockInfo -Path $path
        $info.State | Should -Be 'claiming'
        $info.IsHeld | Should -BeTrue
        Request-FmLock -Path $path | Should -BeNullOrEmpty
    }

    It 'recovers a half-written claim that outlived the grace' {
        $path = Get-LockPath
        Write-LockHolder -Path $path -HolderPid ''
        [System.IO.File]::SetLastWriteTimeUtc((Join-Path $path 'pid'), [datetime]::UtcNow.AddSeconds(-60))
        (Get-FmLockInfo -Path $path).State | Should -Be 'stale'
        $lock = Request-FmLock -Path $path
        try { $lock | Should -Not -BeNullOrEmpty } finally { $null = Unlock-FmLock -Lock $lock }
    }

    It 'treats an unreadable identity as still held, never as stealable' {
        InModuleScope Firstmate {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("failsafe-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $path -Force
            [System.IO.File]::WriteAllText((Join-Path $path 'pid'), "$PID`n")
            [System.IO.File]::WriteAllText((Join-Path $path 'pid-identity'), "recorded-earlier`n")
            Mock Get-FmProcessIdentity { $null }
            try {
                # Cannot prove the id was recycled, so it must read as held.
                (Get-FmLockInfo -Path $path).State | Should -Be 'held'
            } finally { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }

    It 'answers a lock whose sidecars cannot be read, instead of throwing at its caller' {
        # THE WINDOWS DEFECT THIS PINS, reported from a Windows 11 run where
        # every writer in the concurrent-append test survives on Linux and one
        # died on Windows with the suite only able to say "13:Failed".
        #
        # Get-FmLockInfo wrapped its pid read but not its four sidecar reads. A
        # releasing holder deletes those sidecars while a competitor inspects
        # them; on POSIX the unlink is immediate and the read answers null, but
        # on Windows the name sits in DELETE-PENDING and opens keep failing
        # until the last handle closes. That is retried, but the budget is
        # finite, and an exhausted retry is rethrown as an IOException - which
        # escaped Get-FmLockInfo, then Request-FmLock, then Wait-FmLock, and
        # killed the Add-FmStateLine that was only appending one status line.
        #
        # Mocked rather than staged: the platform-specific window cannot be
        # opened reliably on Linux, and the property under test is not "Windows
        # throws this particular exception" but "an inspection answers whatever
        # its reads do". That holds on both platforms and is what the caller
        # actually depends on.
        InModuleScope Firstmate {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("sidecar-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $path -Force
            [System.IO.File]::WriteAllText((Join-Path $path 'pid'), "$PID`n")
            [System.IO.File]::WriteAllText((Join-Path $path 'pid-identity'), "recorded-earlier`n")
            # Exactly what an exhausted retry against a delete-pending file
            # raises by the time it reaches this caller.
            Mock Read-FmStateFile {
                if ($Path -like '*pid-identity' -or $Path -like '*fm-home' -or
                    $Path -like '*role' -or $Path -like '*watcher-path') {
                    throw [System.IO.IOException]::new(
                        "firstmate: read state file failed after 12 attempts on '$Path': access denied")
                }
                "$PID`n"
            }
            try {
                # Called directly, not through a { } | Should -Not -Throw: the
                # scriptblock has its own scope, so the result would not come
                # back out and the verdict below could not be checked at all. A
                # throw fails the test here just as loudly.
                $info = Get-FmLockInfo -Path $path
                # And it still reaches a usable verdict: no provable identity
                # means fall back to plain liveness, which is HELD, never
                # stealable.
                $info.State | Should -Be 'held'
                $info.Identity | Should -BeNullOrEmpty
            } finally { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'gives up a claim it cannot read back, rather than throwing at the caller' {
        # The last bare read in the append's hot path. After winning the pid
        # file, Request-FmLock reads it back to confirm nothing displaced the
        # claim - and that read races a concurrent breaker renaming the very
        # file being read, which is the same delete-pending shape Windows
        # raises on. A read that cannot be PERFORMED means exactly what a read
        # that DISAGREES means: this process cannot confirm it owns the lock.
        # So it must take the same branch - drop the claim, report unavailable -
        # not crash the Add-FmStateLine three frames up.
        InModuleScope Firstmate {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("readback-" + [guid]::NewGuid().ToString('N'))
            $realRead = Get-Command Read-FmStateFile
            Mock Read-FmStateFile {
                if ($Path -like '*[\\/]pid') {
                    throw [System.IO.IOException]::new(
                        "firstmate: read state file failed after 12 attempts on '$Path': access denied")
                }
                & $realRead -Path $Path
            }
            try {
                $lock = Request-FmLock -Path $path
                $lock | Should -BeNullOrEmpty -Because 'a claim it cannot confirm is given up, not held'
                # And the self-deadlock table must not be left believing this
                # process holds it, or the next honest attempt would throw
                # "already holds the lock" forever.
                @(Get-FmHeldLock | Where-Object { $_.Path -eq (Resolve-FmFullPath -Path $path) }).Count |
                    Should -Be 0
            } finally { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'refuses a break whose stale verdict the lock has already outlived' {
        # THE DEFECT THIS PINS. Request-FmLock judges staleness with
        # Get-FmLockInfo and breaks in a SEPARATE step. Between the two, another
        # process can legitimately recover the same lock and be holding it for
        # real. The break used to rename whatever 'pid' file it found, so the
        # late breaker evicted that live holder: two processes then held one
        # lock, and the loser found out only when Unlock-FmLock quietly returned
        # false, because the pid file no longer named it. Nothing threw, so a
        # worker lost its critical section without a single error to show for
        # it - which is exactly what a lost increment looks like downstream.
        InModuleScope Firstmate {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("latebreak-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $path -Force
            try {
                # A genuinely dead holder: the verdict the late breaker carries.
                $deadPid = 2147483600
                [System.IO.File]::WriteAllText((Join-Path $path 'pid'), "$deadPid`n")
                (Get-FmLockInfo -Path $path).State | Should -Be 'stale'

                # ...and then the lock is recovered for real by a live holder,
                # before the breaker acts on that now-outdated verdict.
                $live = Request-FmLock -Path $path
                $live | Should -Not -BeNullOrEmpty -Because 'the stale lock is legitimately recoverable'
                try {
                    Invoke-FmLockBreak -LockPath $path -HolderProcessId $deadPid |
                        Should -BeFalse -Because 'the holder it proved stale is no longer the holder'
                    $after = Get-FmLockInfo -Path $path
                    $after.State | Should -Be 'held' -Because 'the live holder must survive an out-of-date break'
                    $after.ProcessId | Should -Be $PID

                    # The whole point: nobody else can now take a lock this
                    # process still believes it holds.
                    $script:FmHeldLocks.Remove((Get-FmLockKey -Path $path)) | Out-Null
                    $thief = Request-FmLock -Path $path
                    if ($thief) { $null = Unlock-FmLock -Lock $thief -Confirm:$false }
                    $thief | Should -BeNullOrEmpty -Because 'two processes must never hold one lock'
                } finally {
                    $script:FmHeldLocks[(Get-FmLockKey -Path $path)] = $live
                    $null = Unlock-FmLock -Lock $live -Confirm:$false
                }
            } finally { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'still recovers a lock whose recorded holder really is the dead one' {
        # The guard above must not have turned stale recovery off: a break that
        # names the holder it proved stale still succeeds. Without this, the fix
        # could "pass" by refusing every break and deadlocking the home.
        InModuleScope Firstmate {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("okbreak-" + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $path -Force
            try {
                $deadPid = 2147483600
                [System.IO.File]::WriteAllText((Join-Path $path 'pid'), "$deadPid`n")
                Invoke-FmLockBreak -LockPath $path -HolderProcessId $deadPid | Should -BeTrue
                (Get-FmLockInfo -Path $path).State | Should -Be 'free'
            } finally { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Release safety' {
    It 'refuses to release a lock that now names another process' {
        $path = Get-LockPath
        $lock = Request-FmLock -Path $path
        # Someone else legitimately owns it now.
        [System.IO.File]::WriteAllText((Join-Path $path 'pid'), "$($script:DeadPid)`n")
        Unlock-FmLock -Lock $lock | Should -BeFalse
        (Get-FmLockInfo -Path $path).ProcessId | Should -Be $script:DeadPid
    }

    It 'releases by path as well as by lock object' {
        $path = Get-LockPath
        $null = Request-FmLock -Path $path
        Unlock-FmLock -Path $path | Should -BeTrue
        (Get-FmLockInfo -Path $path).State | Should -Be 'free'
    }

    It 'is a no-op on a lock nobody holds' {
        Unlock-FmLock -Path (Get-LockPath) | Should -BeFalse
    }
}

Describe 'Invoke-FmWithLock' {
    It 'runs the body while holding the lock and releases afterwards' {
        $path = Get-LockPath
        $state = Invoke-FmWithLock -Path $path -ScriptBlock { (Get-FmLockInfo -Path $path).State }
        $state | Should -Be 'held'
        (Get-FmLockInfo -Path $path).State | Should -Be 'free'
    }

    It 'releases the lock when the body throws - one failure must not wedge the home' {
        $path = Get-LockPath
        { Invoke-FmWithLock -Path $path -ScriptBlock { throw 'boom' } } | Should -Throw 'boom'
        (Get-FmLockInfo -Path $path).State | Should -Be 'free'
    }

    It 'returns the body result' {
        Invoke-FmWithLock -Path (Get-LockPath) -ScriptBlock { 'result' } | Should -Be 'result'
    }
}

Describe 'Lock path contracts' {
    It 'puts a task meta lock beside its record' {
        $meta = Join-Path $script:TempRoot 'state' 'task-1.meta'
        Get-FmMetaLockPath -MetaPath $meta |
            Should -Be (Join-Path $script:TempRoot 'state' '.meta-task-1.lock')
    }

    It 'refuses a meta lock path for something that is not a .meta record' {
        { Get-FmMetaLockPath -MetaPath (Join-Path $script:TempRoot 'task-1.status') } | Should -Throw '*not a .meta*'
    }

    It 'refuses a meta lock path with an invalid task id' {
        { Get-FmMetaLockPath -MetaPath (Join-Path $script:TempRoot 'a b.meta') } | Should -Throw '*invalid task id*'
    }

    It 'names the per-home task-set lock' {
        Get-FmTaskSetLockPath -StatePath $script:TempRoot |
            Should -Be (Join-Path $script:TempRoot '.task-set.lock')
    }
}

Describe 'One holder, proven with real processes' {
    It 'never lets two processes increment a counter at once' {
        # The honest test of mutual exclusion: each worker reads, pauses, and
        # writes back under the lock. Without exclusion the counter loses
        # increments; with it, the total is exact.
        $lockPath = Get-LockPath
        $counter = Join-Path $script:TempRoot ('counter-' + [guid]::NewGuid().ToString('N'))
        Write-FmStateFile -Path $counter -Content '0'
        $workers = 3
        $perWorker = 12

        $jobs = 1..$workers | ForEach-Object {
            Start-Job -ArgumentList $script:ModulePath, $lockPath, $counter, $perWorker -ScriptBlock {
                param($ModulePath, $LockPath, $Counter, $Count)
                Import-Module $ModulePath -Force
                $counterPath = $Counter
                for ($i = 1; $i -le $Count; $i++) {
                    Invoke-FmWithLock -Path $LockPath -TimeoutSeconds 120 -ScriptBlock {
                        $value = [int](Read-FmStateFile -Path $counterPath).Trim()
                        Start-Sleep -Milliseconds 5
                        Write-FmStateFile -Path $counterPath -Content ([string]($value + 1))
                    }
                }
            }
        }
        $null = $jobs | Wait-Job -Timeout 300
        # Read the workers' own outcome BEFORE the counter, for the same reason
        # the cross-process append test does: Invoke-FmWithLock gives up on the
        # lock after its timeout and throws, and a worker that threw - or that
        # was still running at the deadline - leaves exactly the same evidence
        # downstream as a lost increment. Only one of those is a mutual-exclusion
        # defect. `State -eq 'Failed'` alone does not tell them apart, because a
        # worker still Running at the deadline is neither Failed nor finished.
        $unfinished = @($jobs | Where-Object { $_.State -ne 'Completed' } |
            ForEach-Object { "$($_.Id):$($_.State)" })
        $workerErrors = @($jobs | ForEach-Object { $_.ChildJobs[0].Error } |
            ForEach-Object { [string]$_ })
        $jobs | Remove-Job -Force
        $unfinished | Should -BeNullOrEmpty -Because 'every worker must finish before the counter is judged'
        $workerErrors | Should -BeNullOrEmpty -Because 'a worker that threw did not lose an increment, it never made one'

        [int](Read-FmStateFile -Path $counter).Trim() | Should -Be ($workers * $perWorker)
    }

    It 'hands the lock on when a holder is killed outright, with no cleanup step' {
        # Property 3: a crash must not deadlock the home. The holder is killed
        # with no chance to release; the next caller recovers the lock itself.
        $lockPath = Get-LockPath
        $ready = Join-Path $script:TempRoot ('ready-' + [guid]::NewGuid().ToString('N'))
        $holder = Start-Job -ArgumentList $script:ModulePath, $lockPath, $ready -ScriptBlock {
            param($ModulePath, $LockPath, $Ready)
            Import-Module $ModulePath -Force
            $null = Request-FmLock -Path $LockPath
            Write-FmStateFile -Path $Ready -Content 'held'
            Start-Sleep -Seconds 120
        }
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath $ready) -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            Test-Path -LiteralPath $ready | Should -BeTrue
            $holderPid = (Get-FmLockInfo -Path $lockPath).ProcessId
            $holderPid | Should -Not -BeNullOrEmpty
            Request-FmLock -Path $lockPath | Should -BeNullOrEmpty   # genuinely held

            Stop-Process -Id $holderPid -Force
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            while ((Test-FmProcessAlive -Id $holderPid) -and [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }

            $lock = Wait-FmLock -Path $lockPath -TimeoutSeconds 30
            try {
                $lock.RecoveredProcessId | Should -Be $holderPid
            } finally { $null = Unlock-FmLock -Lock $lock }
        } finally {
            $holder | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Session lock' {
    BeforeEach {
        $script:StatePath = Join-Path $script:TempRoot ('state-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:StatePath -Force
    }

    It 'writes exactly the bash contract: the pid, one line, LF, no BOM' {
        # A Linux firstmate reads this file. The bytes are the interface.
        $result = Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID
        $result.Acquired | Should -BeTrue
        $result.Message | Should -Be "lock acquired: harness pid $PID"
        $bytes = [System.IO.File]::ReadAllBytes((Get-FmSessionLockPath -StatePath $script:StatePath))
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be "$PID`n"
    }

    It 'is idempotent for the session that already holds it' {
        $null = Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID
        (Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID).Acquired | Should -BeTrue
    }

    It 'refuses when another live harness session holds it' {
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            # The holder is a live process that the module is told is a harness.
            $otherPid = Get-FmParentProcessId -Id $PID
            Mock Test-FmHarnessProcess { $true }
            $null = Request-FmSessionLock -StatePath $StatePath -ProcessId $otherPid

            $result = Request-FmSessionLock -StatePath $StatePath -ProcessId $PID
            $result.Acquired | Should -BeFalse
            $result.Reason | Should -Be 'held'
            $result.HolderProcessId | Should -Be $otherPid
            $result.Message | Should -BeLike '*another live firstmate session holds the lock*read-only*'
        }
    }

    It 'takes over a lock whose session is gone' {
        Write-FmStateFile -Path (Get-FmSessionLockPath -StatePath $script:StatePath) -Content ([string]$script:DeadPid)
        (Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID).Acquired | Should -BeTrue
    }

    It 'reports no harness in the ancestry rather than locking the home to a shell' {
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            Mock Get-FmHarnessAncestryPid { $null }
            $result = Request-FmSessionLock -StatePath $StatePath
            $result.Acquired | Should -BeFalse
            $result.Reason | Should -Be 'no-harness'
            $result.Message | Should -Be 'error: cannot locate harness process in ancestry'
        }
    }

    It 'refuses a session lock that is not a regular file' {
        $null = New-Item -ItemType Directory -Path (Get-FmSessionLockPath -StatePath $script:StatePath) -Force
        $result = Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID
        $result.Acquired | Should -BeFalse
        $result.Reason | Should -Be 'not-regular-file'
    }

    # Each wording is its own It: a Pester mock lives until the end of the It
    # that created it, so checking "held" and "stale" in one block would leave
    # the harness mock in force for the stale case and prove nothing.
    It 'says "lock: free" when nobody holds it' {
        (Get-FmSessionLockStatus -StatePath $script:StatePath).Text | Should -Be 'lock: free'
    }

    It 'says "lock: held by live harness pid N" for a live session' {
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            Mock Test-FmHarnessProcess { $true }
            $null = Request-FmSessionLock -StatePath $StatePath -ProcessId $PID
            (Get-FmSessionLockStatus -StatePath $StatePath).Text |
                Should -Be "lock: held by live harness pid $PID"
        }
    }

    It 'still reports, and still refuses, when the identity sidecar cannot be read' {
        # Same class as the Get-FmLockInfo defect the Windows run exposed, in the
        # session-lock path. AGENTS.md's rule for this one is explicit: a session
        # that cannot verify lock ownership falls back to READ-ONLY. A throw is
        # not that fallback - it escapes the caller. Request-FmSessionLock is the
        # sharper case, because its enclosing block is try/FINALLY with no catch,
        # so an exception here leaves the function rather than returning the
        # refusal it documents.
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            $other = Get-FmParentProcessId -Id $PID
            Mock Test-FmHarnessProcess { $true }
            $null = Request-FmSessionLock -StatePath $StatePath -ProcessId $other

            # Mock the INNER read, not Read-FmLockSidecar itself: the guard under
            # test is that function's own catch, and replacing it would remove
            # the very thing being verified. Only the identity sidecar throws;
            # everything else calls through, via a reference captured BEFORE the
            # mock is installed. A -ParameterFilter alone will not do it - Pester
            # 6 raises "no mock matched the call" rather than falling back to the
            # real command, so the lock file's own read has to be handled here.
            $realRead = Get-Command Read-FmStateFile
            Mock Read-FmStateFile {
                if ($Path -like '*.identity') {
                    throw [System.IO.IOException]::new(
                        "firstmate: read state file failed after 12 attempts on '$Path': access denied")
                }
                & $realRead -Path $Path
            }

            # The reporter answers rather than throwing, and a holder it cannot
            # prove recycled still reads as held - never as stealable.
            $status = Get-FmSessionLockStatus -StatePath $StatePath
            $status.State | Should -Be 'held'
            $status.Text | Should -Be "lock: held by live harness pid $other"

            # And the acquirer returns its documented read-only refusal.
            $result = Request-FmSessionLock -StatePath $StatePath -ProcessId $PID
            $result.Acquired | Should -BeFalse
            $result.Reason | Should -Be 'held'
            $result.Message | Should -BeLike '*read-only*'
        }
    }

    It 'says "lock: stale (pid N dead or not a harness)" for a dead session' {
        Write-FmStateFile -Path (Get-FmSessionLockPath -StatePath $script:StatePath) -Content ([string]$script:DeadPid)
        (Get-FmSessionLockStatus -StatePath $script:StatePath).Text |
            Should -Be "lock: stale (pid $($script:DeadPid) dead or not a harness)"
    }

    It 'says a live non-harness holder is stale, because only a harness is a session' {
        $null = Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID
        # This pwsh process is alive but is not a verified harness.
        (Get-FmSessionLockStatus -StatePath $script:StatePath).State | Should -Be 'stale'
    }

    It 'recognizes ownership through the harness ancestry, not by exact pid' {
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            # The lock owner sits at an unknown depth in a contiguous Claude run,
            # so membership - not equality - is the honest test.
            Mock Get-FmHarnessAncestry { , @(11, 22, 33) }
            Write-FmStateFile -Path (Get-FmSessionLockPath -StatePath $StatePath) -Content '22'
            Test-FmSessionLockOwnedBySelf -StatePath $StatePath | Should -BeTrue
            Write-FmStateFile -Path (Get-FmSessionLockPath -StatePath $StatePath) -Content '99'
            Test-FmSessionLockOwnedBySelf -StatePath $StatePath | Should -BeFalse
        }
    }

    It 'fails closed when there is no lock or no resolvable ancestry' {
        Test-FmSessionLockOwnedBySelf -StatePath $script:StatePath | Should -BeFalse
        InModuleScope Firstmate -Parameters @{ StatePath = $script:StatePath } {
            Write-FmStateFile -Path (Get-FmSessionLockPath -StatePath $StatePath) -Content '22'
            Mock Get-FmHarnessAncestry { , @() }
            Test-FmSessionLockOwnedBySelf -StatePath $StatePath | Should -BeFalse
        }
    }

    It 'releases only when the lock names the given session' {
        $null = Request-FmSessionLock -StatePath $script:StatePath -ProcessId $PID
        Unlock-FmSessionLock -StatePath $script:StatePath -ProcessId $script:DeadPid | Should -BeFalse
        Unlock-FmSessionLock -StatePath $script:StatePath -ProcessId $PID | Should -BeTrue
        (Get-FmSessionLockStatus -StatePath $script:StatePath).State | Should -Be 'free'
    }
}
