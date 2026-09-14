#requires -Version 7.0
<#
    Pester tests for the watcher arm layer.

    The load-bearing property under test is HONESTY: the arm reports a cycle only
    when it has verified one, it attaches to a healthy cycle instead of doubling
    it, it follows that cycle rather than returning the moment it ends, and it
    can neither attach to nor stop a sibling firstmate home's watcher.

    These cases run REAL watcher processes against disposable homes on purpose.
    Every defect this layer can have - a lock that is never taken, a beacon that
    is never written, a child that is reaped when the call returns, a confirmed
    cycle nobody waited on - is invisible to a test that stubs the child out, and
    several of them are exactly what the bash original was written to catch.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes and start disposable watcher processes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # Every key any test in this file sets, cleared in one place: Pester
    # containers share one process, so a key left behind decides another FILE's
    # behaviour (CONTRIBUTING.md).
    $script:ArmEnvKeys = @(
        'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_ROOT', 'FM_ROOT_OVERRIDE', 'FM_SIGNAL_GRACE',
        'FM_POLL', 'FM_CHECK_INTERVAL', 'FM_HEARTBEAT', 'FM_WATCH_DISABLE_FSNOTIFY',
        'FM_ARM_CONFIRM_TIMEOUT', 'FM_ARM_ATTACH_POLL_MS', 'FM_ARM_RESTART_WAIT_MS',
        'FM_GUARD_GRACE'
    )
    $script:ArmSavedEnv = @{}
    foreach ($name in $script:ArmEnvKeys) {
        $script:ArmSavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    # Declared up front so a case that fails before it builds its fixtures still
    # reaches its AfterEach under Set-StrictMode instead of dying there.
    $script:ArmHome = ''
    $script:ArmOtherHome = ''
    $script:ArmPeer = $null
    $script:ArmForeign = $null

    function New-ArmTestHome {
        <#
            A disposable home. FM_ROOT_OVERRIDE is deliberately NOT set: the arm
            starts the checkout's real bin/fm-watch.ps1, and the lock's
            watcher-path field is compared against exactly that. Only the HOME
            and the state directory are disposable.
        #>
        param([switch]$NoWatcherEntryPoint)

        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-watch-arm-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $env:FM_HOME = $fmHome
        $env:FM_STATE_OVERRIDE = (Join-Path $fmHome 'state')
        # No watcher may reach a real cadence in a test: every clock is pushed out
        # of the way and the only wake a case gets is the one it seeds.
        $env:FM_POLL = '30'
        $env:FM_SIGNAL_GRACE = '10'
        $env:FM_CHECK_INTERVAL = '999999'
        $env:FM_HEARTBEAT = '999999'
        $env:FM_WATCH_DISABLE_FSNOTIFY = '1'
        $env:FM_ARM_CONFIRM_TIMEOUT = '25'
        $env:FM_ARM_ATTACH_POLL_MS = '200'
        if ($NoWatcherEntryPoint) {
            # A home that is not a checkout: there is no bin/fm-watch.ps1 to
            # start, which is the shape of every "it could not start" failure.
            $env:FM_ROOT_OVERRIDE = $fmHome
        }
        return $fmHome
    }

    function Remove-ArmTestHome {
        param([string]$Path)
        foreach ($name in $script:ArmEnvKeys) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-ArmPwshPath {
        $path = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrEmpty($path)) { $path = 'pwsh' }
        return $path
    }

    function Start-ArmPeerWatcher {
        <#
            A watcher this file owns, standing in for the cycle another arm (or
            another session) already established. Started exactly as the arm
            starts one, so the lock it writes is the real thing.
        #>
        param(
            [Parameter(Mandatory)][string]$FmHome,
            [int]$SignalGraceSeconds = 10
        )
        $stateDir = Join-Path $FmHome 'state'
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = Get-ArmPwshPath
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1'))) {
            $psi.ArgumentList.Add($a)
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $script:RepoRoot
        $psi.Environment['FM_HOME'] = $FmHome
        $psi.Environment['FM_STATE_OVERRIDE'] = $stateDir
        $psi.Environment['FM_POLL'] = '30'
        $psi.Environment['FM_SIGNAL_GRACE'] = [string]$SignalGraceSeconds
        $psi.Environment['FM_CHECK_INTERVAL'] = '999999'
        $psi.Environment['FM_HEARTBEAT'] = '999999'
        $psi.Environment['FM_WATCH_DISABLE_FSNOTIFY'] = '1'
        # $null =: Remove() answers a bool, and an unassigned one would join this
        # function's output and make the returned record an array.
        $null = $psi.Environment.Remove('FM_ROOT_OVERRIDE')
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $null = $proc.Start()
        # Drained asynchronously so a peer that writes its reason line can never
        # block on a full pipe while a case is waiting for it to close.
        $null = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        return [pscustomobject]@{ Process = $proc }
    }

    function Wait-ArmPeerHealthy {
        param(
            [Parameter(Mandatory)][string]$FmHome,
            [int]$TimeoutSeconds = 40
        )
        $stateDir = Join-Path $FmHome 'state'
        $watchPath = Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1'
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([datetime]::UtcNow -lt $deadline) {
            if (Test-FmWatcherHealthy -State $stateDir -WatchPath $watchPath -Grace 300 -FmHome $FmHome) {
                # The lock and the beacon are published in the watcher's first
                # cycle, before its signal scan. A short settle keeps a case that
                # seeds a signal AFTER this point from racing that same scan.
                Start-Sleep -Milliseconds 1200
                return $true
            }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }

    function Stop-ArmPeerWatcher {
        param([pscustomobject]$Peer)
        if (-not $Peer) { return }
        try {
            if (-not $Peer.Process.HasExited) { $Peer.Process.Kill($true) }
            $null = $Peer.Process.WaitForExit(5000)
        }
        catch { Write-Verbose "peer watcher had already exited: $_" }
        finally { $Peer.Process.Dispose() }
    }

    function Start-ArmForeignProcess {
        <# A live process that is NOT a watcher, used to pin a lock this home
           must refuse to act on. #>
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = Get-ArmPwshPath
        foreach ($a in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120')) {
            $psi.ArgumentList.Add($a)
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        $null = $proc.Start()
        return $proc
    }

    function Get-ArmLockPid {
        param([Parameter(Mandatory)][string]$FmHome)
        return (Get-FmFirstLine -Path (Join-Path $FmHome 'state' '.watch.lock' 'pid'))
    }
}

AfterAll {
    foreach ($name in $script:ArmSavedEnv.Keys) {
        $value = $script:ArmSavedEnv[$name]
        if ($null -eq $value) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "env:$name" -Value $value }
    }
}

Describe 'The arm owner the Stop auto-arm binds by name' {
    It 'resolves from the imported module, not only from a dot-sourced session' {
        # The shape the hook actually asks the question in: Resolve-FmSessionCommand
        # is Get-Command against an IMPORTED module. A test that only proved the
        # dot-sourced session has the function would pass over an owner the
        # manifest never exports, which is the whole failure mode here.
        $manifest = Join-Path $script:RepoRoot 'module' 'Firstmate' 'Firstmate.psd1'
        $probe = "`$ErrorActionPreference = 'Stop'; Import-Module -Name '$manifest' -Force; " +
        "'arm-resolves=' + [bool](Get-Command -Name 'Invoke-FmWatchArm' -ErrorAction SilentlyContinue)"
        $out = @(pwsh -NoProfile -NonInteractive -Command $probe)
        $out | Should -Contain 'arm-resolves=True'
    }

    It 'makes the supervision probe answer that this build HAS an automatic arm' {
        # The probe and the hook resolve the same name on purpose, so this answer
        # and the hook's behaviour cannot disagree (Private/FmSupervision.ps1).
        Test-FmSupervisionAutoArmAvailable | Should -BeTrue
    }
}

Describe 'Invoke-FmWatchArm starting a cycle' {
    AfterEach { Remove-ArmTestHome -Path $script:ArmHome }

    It 'starts one watcher, confirms it, and reports the wake that cycle delivered' {
        $script:ArmHome = New-ArmTestHome
        $state = Join-Path $script:ArmHome 'state'
        # Seeded before the watcher exists, so the cycle has something actionable
        # to close on. The signal grace is what keeps the fresh cycle alive long
        # enough for the confirmation to be a real observation rather than a race.
        Set-FmFileTextLf -Path (Join-Path $state 'alpha.status') -Text "blocked: need a decision`n"

        $result = Invoke-FmWatchArm -PassThru
        $result.ExitCode | Should -Be 0
        $result.Lines[0] | Should -Match '^watcher: started pid=\d+ \(beacon fresh\)$'
        $result.Lines[-1] | Should -BeLike 'signal:*alpha.status'

        # Classified the way the Stop auto-arm classifies it: that caller decides
        # "actionable" with this exact grammar (Invoke-FmClaudeHook.ps1), so a
        # classification line that accidentally matched it would turn an ordinary
        # arm close into a rewake of an idle session.
        $grammar = '^(signal:|stale:|check:|heartbeat($|:))'
        $result.Lines[0] | Should -Not -Match $grammar
        @($result.Lines | Where-Object { $_ -match $grammar }).Count | Should -Be 1

        # The cycle really ran: the watcher wrote its own liveness beacon, and the
        # arm wrote one lifecycle row for the cycle it observed.
        Test-Path -LiteralPath (Join-Path $state '.last-watcher-beat') | Should -BeTrue
        $ledger = @(Get-FmWakeQueueLines -Path (Join-Path $state '.watch-cycle-exits.log'))
        $ledger.Count | Should -Be 1
        $ledger[0] | Should -BeLike '*origin=started*'
        $ledger[0] | Should -BeLike '*reason=actionable-signal*'

        # And it released the singleton on the way out, so the next arm is free
        # to establish the next cycle rather than attaching to a corpse.
        Test-FmWatcherHealthy -State $state -WatchPath (Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1') `
            -Grace 300 -FmHome $script:ArmHome | Should -BeFalse
    }

    It 'refuses to name a cycle it could only half read' {
        # A real race, caught by the full suite on the second run: the health
        # predicate and the pid read-back are two separate looks at a lock the
        # watcher may release between them. The arm printed `watcher: attached
        # pid=` with no pid, adopted that as its cycle, and then could not
        # resolve the delivery record of the cycle it had just overwritten - so
        # it reported a failure for a wake that had really been delivered.
        # An unreadable holder is now simply not healthy.
        $script:ArmHome = New-ArmTestHome -NoWatcherEntryPoint
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ArmHome 'state' '.watch.lock') -Force
        Mock Test-FmWatcherHealthy { $true }

        $result = Invoke-FmWatchArm -PassThru -AttachTimeoutSeconds 2
        @($result.Lines | Where-Object { $_ -match '^watcher: attached pid=(\s|$|\()' }).Count | Should -Be 0
        $result.ExitCode | Should -Be 1
        $result.Lines | Should -Contain 'watcher: FAILED - no live watcher with a fresh beacon'
    }

    It 'refuses rather than reporting a watcher it could not start' {
        $script:ArmHome = New-ArmTestHome -NoWatcherEntryPoint

        $result = Invoke-FmWatchArm -PassThru
        $result.ExitCode | Should -Be 1
        $result.Lines | Should -Contain 'watcher: FAILED - no live watcher with a fresh beacon'
        # The whole point of the refusal: nothing may read as an established cycle.
        @($result.Lines | Where-Object { $_ -like 'watcher: started*' -or $_ -like 'watcher: attached*' }).Count |
            Should -Be 0
        @($result.Lines).Count | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-FmWatchArm attaching to an existing cycle' {
    AfterEach {
        Stop-ArmPeerWatcher -Peer $script:ArmPeer
        $script:ArmPeer = $null
        Remove-ArmTestHome -Path $script:ArmHome
    }

    It 'attaches to the healthy cycle that already exists instead of starting a second' {
        $script:ArmHome = New-ArmTestHome
        $script:ArmPeer = Start-ArmPeerWatcher -FmHome $script:ArmHome
        Wait-ArmPeerHealthy -FmHome $script:ArmHome | Should -BeTrue
        $peerPid = Get-ArmLockPid -FmHome $script:ArmHome

        $result = Invoke-FmWatchArm -PassThru -AttachTimeoutSeconds 2
        $result.ExitCode | Should -Be 0
        $result.Lines[0] | Should -Match "^watcher: attached pid=$peerPid \(beacon \d+s\)$"

        # The singleton is intact: the lock still names the cycle that was already
        # running, and that process is still the one holding it.
        Get-ArmLockPid -FmHome $script:ArmHome | Should -Be $peerPid
        $script:ArmPeer.Process.HasExited | Should -BeFalse
    }

    It 'follows that cycle to its close and reports the wake it delivered' {
        # An attached arm holds no handle on the watcher's stdout, so this is the
        # path that proves the identity-bound delivery record is what lets it
        # report a real wake instead of a clean empty success.
        $script:ArmHome = New-ArmTestHome
        $state = Join-Path $script:ArmHome 'state'
        Set-FmFileTextLf -Path (Join-Path $state 'alpha.status') -Text "blocked: need a decision`n"
        $script:ArmPeer = Start-ArmPeerWatcher -FmHome $script:ArmHome -SignalGraceSeconds 12
        Wait-ArmPeerHealthy -FmHome $script:ArmHome | Should -BeTrue
        $env:FM_ARM_CONFIRM_TIMEOUT = '2'

        $result = Invoke-FmWatchArm -PassThru
        $result.ExitCode | Should -Be 0
        $result.Lines[0] | Should -BeLike 'watcher: attached pid=*'
        $result.Lines[-1] | Should -BeLike 'signal:*alpha.status'
        @($result.Lines | Where-Object { $_ -like 'watcher: FAILED*' }).Count | Should -Be 0
    }
}

Describe 'Invoke-FmWatchArm home scope' {
    AfterEach {
        Stop-ArmPeerWatcher -Peer $script:ArmPeer
        $script:ArmPeer = $null
        if ($script:ArmForeign) {
            try { if (-not $script:ArmForeign.HasExited) { $script:ArmForeign.Kill($true) } } catch { Write-Verbose "foreign fixture already gone: $_" }
            $script:ArmForeign.Dispose()
            $script:ArmForeign = $null
        }
        Remove-ArmTestHome -Path $script:ArmHome
        if ($script:ArmOtherHome -and (Test-Path -LiteralPath $script:ArmOtherHome)) {
            Remove-Item -LiteralPath $script:ArmOtherHome -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:ArmOtherHome = $null
    }

    It 'leaves another home''s running watcher alone, even on a forced restart' {
        # The failure this refuses is the one AGENTS.md section 8 names: several
        # homes run the same bin/fm-watch.ps1, so anything that matched a watcher
        # by name would take the siblings down with it.
        $script:ArmOtherHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-watch-arm-other-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:ArmOtherHome 'state') -Force
        $script:ArmPeer = Start-ArmPeerWatcher -FmHome $script:ArmOtherHome
        Wait-ArmPeerHealthy -FmHome $script:ArmOtherHome | Should -BeTrue
        $otherPid = Get-ArmLockPid -FmHome $script:ArmOtherHome
        $otherBeacon = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $script:ArmOtherHome 'state' '.last-watcher-beat'))

        $script:ArmHome = New-ArmTestHome
        # This home gets its own actionable wake so its own fresh cycle closes;
        # without one it would block on a healthy watcher for the whole poll.
        Set-FmFileTextLf -Path (Join-Path $script:ArmHome 'state' 'alpha.status') -Text "blocked: need a decision`n"
        $result = Invoke-FmWatchArm -Restart -PassThru
        $result.ExitCode | Should -Be 0

        # The sibling's cycle is untouched: same process, same lock, and its
        # recovery marker was never published into.
        $script:ArmPeer.Process.HasExited | Should -BeFalse
        Get-ArmLockPid -FmHome $script:ArmOtherHome | Should -Be $otherPid
        [System.IO.File]::GetLastWriteTimeUtc((Join-Path $script:ArmOtherHome 'state' '.last-watcher-beat')) |
            Should -BeGreaterOrEqual $otherBeacon
        Test-Path -LiteralPath (Join-Path $script:ArmOtherHome 'state' '.watch-cycle-exits.log') | Should -BeFalse
    }

    It 'never signals a live process that is not this home''s watcher' {
        # A lock naming a live pid that belongs to another home: the pid may not
        # be signalled, and the lock may not be cleared either, because neither
        # is this home's to decide.
        $script:ArmHome = New-ArmTestHome
        $script:ArmForeign = Start-ArmForeignProcess
        $lock = Join-Path $script:ArmHome 'state' '.watch.lock'
        $null = New-Item -ItemType Directory -Path $lock -Force
        Set-FmFileTextLf -Path (Join-Path $lock 'pid') -Text ("{0}`n" -f $script:ArmForeign.Id)
        Set-FmFileTextLf -Path (Join-Path $lock 'fm-home') -Text "C:\some\other\firstmate`n"
        Set-FmFileTextLf -Path (Join-Path $lock 'watcher-path') -Text "C:\some\other\firstmate\bin\fm-watch.ps1`n"
        Set-FmFileTextLf -Path (Join-Path $lock 'pid-identity') -Text "some-other-homes-identity`n"
        $env:FM_ARM_CONFIRM_TIMEOUT = '2'

        $result = Invoke-FmWatchArm -Restart -PassThru

        $script:ArmForeign.HasExited | Should -BeFalse
        Get-ArmLockPid -FmHome $script:ArmHome | Should -Be ([string]$script:ArmForeign.Id)
        (Get-FmFirstLine -Path (Join-Path $lock 'fm-home')) | Should -Be 'C:\some\other\firstmate'
        # And it says so rather than claiming a cycle it never got.
        $result.ExitCode | Should -Be 1
        $result.Lines | Should -Contain 'watcher: FAILED - cycle ended without an actionable reason'
    }
}

Describe 'Invoke-FmWatchArm forced restart' {
    AfterEach {
        Stop-ArmPeerWatcher -Peer $script:ArmPeer
        $script:ArmPeer = $null
        Remove-ArmTestHome -Path $script:ArmHome
    }

    It 'stops this home''s own recorded watcher and owns a fresh cycle' {
        $script:ArmHome = New-ArmTestHome
        $script:ArmPeer = Start-ArmPeerWatcher -FmHome $script:ArmHome
        Wait-ArmPeerHealthy -FmHome $script:ArmHome | Should -BeTrue
        $oldPid = Get-ArmLockPid -FmHome $script:ArmHome

        $result = Invoke-FmWatchArm -Restart -PassThru

        Test-FmProcessAlive $oldPid | Should -BeFalse
        # The replacement inherits a lock whose pid is now dead, so it steals it,
        # publishes the downtime that eviction created, and closes at once on the
        # resurfacing wake that downtime owes the fleet. That is the honest close
        # of a restarted cycle, and it is why no `started` line is asserted here.
        $result.ExitCode | Should -Be 0
        $result.Lines | Should -Contain 'check: rearm-resurface'
    }
}
