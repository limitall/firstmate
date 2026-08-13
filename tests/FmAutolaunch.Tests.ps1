#requires -Version 7.0
# Pester 5+/6 tests for the autolaunch area: the opt-in config, the doctor line,
# and the arm/grace/submit state machine.
#
# No test here talks to a real herdr server: every adapter call is mocked, which
# is the only way these paths can run on a machine with no herdr session, and the
# only way the stand-down paths can be driven deterministically at all.
#
# THE TESTS THAT MATTER MOST ARE THE ONES THAT DO NOT SUBMIT. The failure this
# feature must never have is firstmate typing over the captain, so every way the
# window can be interrupted has its own case, and each one asserts that no Enter
# was sent - not merely that the reported action was 'stood-down'.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmPaths.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmState.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmBackendHerdr.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmInstall.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmAutolaunch.ps1')
    . (Join-Path $script:ModuleRoot 'Public' 'Get-FmTaskRecord.ps1')
    . (Join-Path $script:ModuleRoot 'Public' 'Invoke-FmAutolaunch.ps1')

    # A home whose config/ and state/ are real directories, so the config reader
    # and the worker-pane guard are exercised against files rather than mocks.
    function New-AutolaunchHome {
        param([string]$Content = '')
        # NOT $home: $HOME is read-only, and assigning it fails as Pester's
        # misleading "a 'break' or 'continue' statement escaped from your code".
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force
        if ($Content) {
            [System.IO.File]::WriteAllText((Join-Path $root 'config' 'autolaunch'), $Content)
        }
        $root
    }

    function New-AutolaunchConfigDir {
        param([string]$Content = '')
        Join-Path (New-AutolaunchHome -Content $Content) 'config'
    }

    # The pane every happy-path test drives: readable, live, idle, and showing
    # one stable screen until a test changes $script:Screen.
    function Set-CalmPane {
        Mock Test-FmHerdrTargetReady { $true }
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrBusyState { 'idle' }
        Mock Get-FmHerdrComposerState { 'unknown' }
        Mock Get-FmHerdrCapture { $script:Screen }
        Mock Send-FmHerdrLiteral { $script:Screen = "$($script:Screen)`n> $Text"; $true }
        Mock Send-FmHerdrKey { $script:Enters++; $true }
        Mock Wait-FmHerdrWorking { 'busy' }
        $script:Screen = 'PS C:\Users\ADMIN>'
        $script:Enters = 0
    }
}

Describe 'Read-FmAutolaunchConfig' {
    It 'is off when no config file exists, and says so' {
        $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir)
        $config.Status | Should -Be 'off'
        $config.Enabled | Should -BeFalse
        $config.Command | Should -BeNullOrEmpty
        $config.Reason | Should -Match 'autolaunch is off'
    }

    It 'reads a command and defaults the window to ten seconds' {
        $dir = New-AutolaunchConfigDir -Content "command=claude --dangerously-skip-permissions --continue --chrome`n"
        $config = Read-FmAutolaunchConfig -ConfigDir $dir
        $config.Status | Should -Be 'enabled'
        $config.Enabled | Should -BeTrue
        $config.Command | Should -Be 'claude --dangerously-skip-permissions --continue --chrome'
        $config.DelaySeconds | Should -Be 10
    }

    It 'reads a configured window, and ignores blank and comment lines' {
        $dir = New-AutolaunchConfigDir -Content "# firstmate autolaunch`n`ncommand=pwsh -NoLogo`ndelay=25`n"
        $config = Read-FmAutolaunchConfig -ConfigDir $dir
        $config.Command | Should -Be 'pwsh -NoLogo'
        $config.DelaySeconds | Should -Be 25
    }

    It 'keeps every character of a command that itself contains an equals sign' {
        $dir = New-AutolaunchConfigDir -Content "command=claude --model=opus --continue`n"
        (Read-FmAutolaunchConfig -ConfigDir $dir).Command | Should -Be 'claude --model=opus --continue'
    }

    It 'refuses a file with no command, rather than inventing one' {
        $dir = New-AutolaunchConfigDir -Content "delay=30`n"
        $config = Read-FmAutolaunchConfig -ConfigDir $dir
        $config.Status | Should -Be 'invalid'
        $config.Enabled | Should -BeFalse
        $config.Reason | Should -Match 'no command='
    }

    It 'refuses an empty command' {
        $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir -Content "command=`n")
        $config.Status | Should -Be 'invalid'
        $config.Reason | Should -Match 'empty command'
    }

    It 'refuses an unknown key instead of silently taking the default' {
        # The failure this guards: a typo leaves autolaunch believing it is
        # configured when the captain thinks they set something.
        $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir -Content "command=claude`ndelayy=3`n")
        $config.Status | Should -Be 'invalid'
        $config.Reason | Should -Match "unknown key 'delayy'"
    }

    It 'refuses a key set twice, rather than picking one' {
        $content = "command=claude`ncommand=rm -rf /`n"
        $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir -Content $content)
        $config.Status | Should -Be 'invalid'
        $config.Reason | Should -Match "'command' is set twice"
    }

    It 'refuses a line that is not key=value, naming the line' {
        $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir -Content "command=claude`nnonsense`n")
        $config.Status | Should -Be 'invalid'
        $config.Reason | Should -Match 'line 2: expected key=value'
    }

    It 'refuses a non-numeric, zero, or out-of-range window' {
        foreach ($delay in @('soon', '0', '99999')) {
            $config = Read-FmAutolaunchConfig -ConfigDir (New-AutolaunchConfigDir -Content "command=claude`ndelay=$delay`n")
            $config.Status | Should -Be 'invalid'
        }
    }
}

Describe 'Get-FmAutolaunchCheck' {
    It 'prints the exact command whenever autolaunch is on' {
        $dir = New-AutolaunchConfigDir -Content "command=claude --dangerously-skip-permissions --continue --chrome`n"
        $check = @(Get-FmAutolaunchCheck -ConfigDir $dir)[0]
        $check.Name | Should -Be 'autolaunch'
        $check.Status | Should -Be 'ok'
        $check.Detail | Should -Match 'claude --dangerously-skip-permissions --continue --chrome'
        $check.Detail | Should -Match '10s'
    }

    It 'reports an unconfigured home as off and healthy' {
        $check = @(Get-FmAutolaunchCheck -ConfigDir (New-AutolaunchConfigDir))[0]
        $check.Status | Should -Be 'ok'
        $check.Detail | Should -Match '^off'
    }

    It 'warns, with the fix, when the file is present but unusable' {
        $check = @(Get-FmAutolaunchCheck -ConfigDir (New-AutolaunchConfigDir -Content "delay=10`n"))[0]
        $check.Status | Should -Be 'warn'
        $check.Detail | Should -Match 'no command='
        $check.Fix | Should -Match 'command=<command>'
    }
}

Describe 'Test-FmAutolaunchWorkerPane' {
    It 'recognises a pane this home recorded as a worker endpoint' {
        $root = New-AutolaunchHome
        $state = Join-Path $root 'state'
        [System.IO.File]::WriteAllText((Join-Path $state 'demo.meta'),
            "window=default:w1:p7`nendpoint_task_id=demo`nbackend=herdr`nherdr_pane_id=w1:p7`n")
        Test-FmAutolaunchWorkerPane -Target 'default:w1:p7' -StateDir $state | Should -BeTrue
    }

    It 'matches on the recorded pane id even when the session spelling differs' {
        $root = New-AutolaunchHome
        $state = Join-Path $root 'state'
        [System.IO.File]::WriteAllText((Join-Path $state 'demo.meta'),
            "window=fmlab:w1:p7`nbackend=herdr`nherdr_pane_id=w1:p7`n")
        Test-FmAutolaunchWorkerPane -Target 'default:w1:p7' -StateDir $state | Should -BeTrue
    }

    It 'leaves an unrelated pane alone' {
        $root = New-AutolaunchHome
        $state = Join-Path $root 'state'
        [System.IO.File]::WriteAllText((Join-Path $state 'demo.meta'), "window=default:w1:p7`nherdr_pane_id=w1:p7`n")
        Test-FmAutolaunchWorkerPane -Target 'default:w1:p2' -StateDir $state | Should -BeFalse
    }

    It 'is false, not an error, when the home has no state directory' {
        Test-FmAutolaunchWorkerPane -Target 'default:w1:p2' -StateDir (Join-Path $TestDrive 'no-such-state') |
            Should -BeFalse
    }
}

Describe 'Invoke-FmAutolaunchArm - the untouched path' {
    BeforeEach { Set-CalmPane }

    It 'types the command, waits, and submits it once' {
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude --continue' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'submitted'
        $result.Armed | Should -BeTrue
        $result.Submitted | Should -BeTrue
        $script:Enters | Should -Be 1
        Should -Invoke Send-FmHerdrLiteral -Times 1 -Exactly
    }

    It 'types the command exactly once, and never retypes it' {
        $null = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude --continue' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        Should -Invoke Send-FmHerdrLiteral -Times 1 -Exactly
    }

    It 'holds the pane for the whole window before submitting' {
        # Measured, not asserted about: a window that returned early would be a
        # grace period the captain never actually gets.
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.05 -SettleSeconds 0
        $clock.Stop()
        $result.Action | Should -Be 'submitted'
        $clock.Elapsed.TotalSeconds | Should -BeGreaterThan 0.95
    }

    It 'reports an unconfirmed submit rather than claiming the command started' {
        Mock Wait-FmHerdrWorking { 'unknown' }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'unconfirmed'
        $result.Submitted | Should -BeFalse
        $result.Reason | Should -Match 'did not confirm'
    }

    It 'types nothing under -WhatIf' {
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0 -WhatIf
        $result.Action | Should -Be 'skipped'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
        $script:Enters | Should -Be 0
    }
}

Describe 'Invoke-FmAutolaunchArm - the captain wins' {
    BeforeEach { Set-CalmPane }

    It 'stands down when the pane changes during the window, and submits nothing' {
        # The one that matters: the captain types while the window is running.
        $script:Polls = 0
        Mock Get-FmHerdrCapture {
            $script:Polls++
            if ($script:Polls -ge 4) { return "$($script:Screen) and the captain's own words" }
            $script:Screen
        }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 5 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'stood-down'
        $result.Armed | Should -BeTrue
        $result.Reason | Should -Match 'captain is using it'
        $script:Enters | Should -Be 0
    }

    It 'never sends any key at all once it has stood down' {
        # Standing down must not "tidy up" either: no Enter, no Escape, no clear.
        $script:Polls = 0
        Mock Get-FmHerdrCapture {
            $script:Polls++
            if ($script:Polls -ge 4) { return 'the captain typed something else entirely' }
            $script:Screen
        }
        $null = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 5 -PollSeconds 0.01 -SettleSeconds 0
        Should -Invoke Send-FmHerdrKey -Times 0 -Exactly
    }

    It 'stands down when the pane starts running something during the window' {
        $script:Reads = 0
        Mock Get-FmHerdrBusyState { $script:Reads++; if ($script:Reads -ge 3) { 'busy' } else { 'idle' } }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 5 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'stood-down'
        $result.Reason | Should -Match 'running something'
        $script:Enters | Should -Be 0
    }

    It 'stands down when the pane becomes unreadable during the window' {
        $script:Polls = 0
        Mock Get-FmHerdrCapture { $script:Polls++; if ($script:Polls -ge 4) { $null } else { $script:Screen } }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 5 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'stood-down'
        $result.Reason | Should -Match 'stopped being readable'
        $script:Enters | Should -Be 0
    }

    It 'stands down when the typed command never appears in the pane' {
        Mock Send-FmHerdrLiteral { $true }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 5 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'stood-down'
        $result.Reason | Should -Match 'never appeared'
        $script:Enters | Should -Be 0
    }

    It 'reports the command as still unsubmitted when Enter itself fails' {
        Mock Send-FmHerdrKey { $script:Enters++; $false }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'stood-down'
        $result.Reason | Should -Match 'still unsubmitted'
    }
}

Describe 'Invoke-FmAutolaunchArm - panes it will not type into' {
    BeforeEach { Set-CalmPane }

    It 'refuses a pane that is already running something' {
        Mock Get-FmHerdrBusyState { 'busy' }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Armed | Should -BeFalse
        $result.Reason | Should -Match 'running something'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses a pane whose state cannot be read, rather than assuming it is free' {
        Mock Get-FmHerdrBusyState { 'unknown' }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'could not be read'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses a pane it cannot capture at all' {
        Mock Get-FmHerdrCapture { $null }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses a pane that is repainting under it, before typing anything' {
        $script:Reads = 0
        Mock Get-FmHerdrCapture { $script:Reads++; "screen $($script:Reads)" }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'already in use'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses when a loaded composer classifier reports a draft in the composer' {
        # This port reports 'unknown' (no classifier), which the unchanged-bytes
        # test covers. If one is ever loaded, a non-empty verdict must refuse.
        Mock Get-FmHerdrComposerState { 'pending' }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'composer is not empty'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses a malformed target without calling the backend' {
        $result = Invoke-FmAutolaunchArm -Target 'not-a-pane' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match '<session>:<pane-id>'
        Should -Invoke Test-FmHerdrTargetReady -Times 0 -Exactly
    }

    It 'refuses a pane that does not exist' {
        Mock Test-FmHerdrTargetExists { $false }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'no live pane'
    }

    It 'refuses when the session cannot be reached' {
        Mock Test-FmHerdrTargetReady { $false }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'could not be reached'
    }

    It 'refuses when the command cannot be typed' {
        Mock Send-FmHerdrLiteral { $false }
        $result = Invoke-FmAutolaunchArm -Target 'default:w1:p2' -Command 'claude' `
            -DelaySeconds 1 -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match 'could not be typed'
        $script:Enters | Should -Be 0
    }
}

Describe 'Invoke-FmAutolaunch' {
    BeforeEach { Set-CalmPane }

    It 'does nothing at all in a home that has not opted in' {
        $result = Invoke-FmAutolaunch -Target 'default:w1:p2' -FirstmateHome (New-AutolaunchHome) `
            -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'disabled'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
        Should -Invoke Send-FmHerdrKey -Times 0 -Exactly
        Should -Invoke Test-FmHerdrTargetReady -Times 0 -Exactly
    }

    It 'runs the configured command, with the configured window' {
        $root = New-AutolaunchHome -Content "command=claude --continue`ndelay=1`n"
        $result = Invoke-FmAutolaunch -Target 'default:w1:p2' -FirstmateHome $root `
            -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'submitted'
        $result.Command | Should -Be 'claude --continue'
        $result.DelaySeconds | Should -Be 1
    }

    It 'refuses a home whose config file is unusable, rather than treating it as off' {
        $root = New-AutolaunchHome -Content "commnd=claude`n"
        $result = Invoke-FmAutolaunch -Target 'default:w1:p2' -FirstmateHome $root `
            -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'refuses a pane this home records as a worker endpoint' {
        $root = New-AutolaunchHome -Content "command=claude`ndelay=1`n"
        [System.IO.File]::WriteAllText((Join-Path $root 'state' 'demo.meta'),
            "window=default:w1:p2`nbackend=herdr`nherdr_pane_id=w1:p2`n")
        $result = Invoke-FmAutolaunch -Target 'default:w1:p2' -FirstmateHome $root `
            -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'refused'
        $result.Reason | Should -Match "worker's pane"
        Should -Invoke Send-FmHerdrLiteral -Times 0 -Exactly
    }

    It 'lets an explicit window override the configured one' {
        $root = New-AutolaunchHome -Content "command=claude`ndelay=600`n"
        $result = Invoke-FmAutolaunch -Target 'default:w1:p2' -FirstmateHome $root -DelaySeconds 1 `
            -PollSeconds 0.01 -SettleSeconds 0
        $result.Action | Should -Be 'submitted'
        $result.DelaySeconds | Should -Be 1
    }
}
