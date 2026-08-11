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
    Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force
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
