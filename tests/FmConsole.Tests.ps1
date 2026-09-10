#requires -Version 7.0
# Pester 5+/6 tests for firstmate's own window: where it opens, and what happens
# when it cannot.
#
# NOTHING HERE DRIVES A REAL HERDR SERVER. Every backend call is mocked, exactly
# as tests/FmBackendHerdr.Tests.ps1 and tests/FmWorker.Tests.ps1 do, so this file
# runs on a machine with no herdr on it at all - which is also one of the cases
# it has to pin.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    foreach ($private in (Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' | Sort-Object Name)) {
        . $private.FullName
    }
    foreach ($public in (Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' | Sort-Object Name)) {
        . $public.FullName
    }

    function New-TestConsoleHome {
        param([Parameter(Mandatory)][string]$Path, [string[]]$Projects = @())
        New-Item -ItemType Directory -Path (Join-Path $Path 'state') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Path 'projects') -Force | Out-Null
        foreach ($p in $Projects) {
            New-Item -ItemType Directory -Path (Join-Path (Join-Path $Path 'projects') $p) -Force | Out-Null
        }
        $Path
    }
}

Describe 'Get-FmConsoleDirectory' {

    BeforeEach {
        $script:checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:checkout -Force | Out-Null
    }

    # THE CAPTAIN'S OWN MACHINE. A fresh install has no home at all until the
    # browser asks where it goes, so this is the FIRST case rather than an edge,
    # and it has to be a directory rather than a refusal.
    It 'opens where firstmate lives when this machine has no home yet' {
        $d = Get-FmConsoleDirectory -HomePath '' -CheckoutPath $script:checkout
        $d.Path | Should -Be $script:checkout
        $d.Kind | Should -Be 'checkout'
    }

    It 'does the same when the home is there but has never held a project' {
        $home_ = New-TestConsoleHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        $d = Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout
        $d.Path | Should -Be $script:checkout
        $d.Kind | Should -Be 'checkout'
    }

    It 'does the same when the home has no projects folder at all' {
        $home_ = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path (Join-Path $home_ 'state') -Force | Out-Null
        (Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout).Kind | Should -Be 'checkout'
    }

    It 'opens in the project when there is exactly one' {
        $home_ = New-TestConsoleHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) -Projects @('payments')
        $d = Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout
        $d.Kind | Should -Be 'project'
        $d.Detail | Should -Be 'payments'
        (Split-Path $d.Path -Leaf) | Should -Be 'payments'
    }

    # CHOOSING ONE OF THE CAPTAIN'S PROJECTS FOR THEM WOULD BE A GUESS, and the
    # folder holding all of them is a real answer that is true of every one.
    It 'opens at the folder holding them when there are several, and picks none' {
        $home_ = New-TestConsoleHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) `
            -Projects @('alpha', 'beta', 'gamma')
        $d = Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout
        $d.Kind | Should -Be 'projects'
        (Split-Path $d.Path -Leaf) | Should -Be 'projects'
        $d.Detail | Should -Match '3'
    }

    It 'reads the clones rather than the registry, because a registry line is not a directory' {
        $home_ = New-TestConsoleHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString()))
        New-Item -ItemType Directory -Path (Join-Path $home_ 'data') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $home_ 'data\projects.md'),
            "# Projects`n- ghost [no-mistakes] - never cloned here (added 2026-01-01)`n")
        (Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout).Kind | Should -Be 'checkout'
    }

    It 'never returns an empty path' -ForEach @(
        @{ Projects = @() }, @{ Projects = @('one') }, @{ Projects = @('one', 'two') }
    ) {
        $home_ = New-TestConsoleHome -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) -Projects $Projects
        $d = Get-FmConsoleDirectory -HomePath $home_ -CheckoutPath $script:checkout
        $d.Path | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $d.Path -PathType Container | Should -BeTrue
    }
}

Describe 'ConvertTo-FmPaneCommand' {

    # The pane's shell is Windows PowerShell 5.1 and its legacy quoting cannot
    # escape a double quote inside an argument. The owner's header carries the
    # measurement; these pin the two things every caller depends on.
    It 'runs the command through PowerShell 7 rather than the shell the pane opens' {
        ConvertTo-FmPaneCommand -Inner "& 'C:\fm\bin\fm-bridge.ps1' -Port 7433" |
            Should -BeLike 'pwsh -NoProfile -Command *'
    }

    It 'escapes the single quotes mechanically rather than by hand' {
        $out = ConvertTo-FmPaneCommand -Inner "& 'C:\fm\o''brien\fm-bridge.ps1'"
        $out | Should -Match "o''''brien"
    }

    It 'refuses a double quote rather than typing a command that arrives mangled' {
        { ConvertTo-FmPaneCommand -Inner '& "C:\fm\bin\fm-bridge.ps1"' } | Should -Throw '*double quote*'
    }

    It 'refuses to build a command out of nothing' {
        { ConvertTo-FmPaneCommand -Inner '' } | Should -Throw
    }

    # The worker launch path and the console path are the same wrapping now, and
    # a second copy of it is what this extraction exists to prevent.
    It 'is what a worker launch command is built with too' {
        Mock Assert-FmHarnessExecutable { $true }
        $launch = Get-FmHarnessLaunchCommand -Harness claude -BriefPath 'C:\fm\data\t\brief.md'
        $launch | Should -BeLike 'pwsh -NoProfile -Command *'
        $launch | Should -Match '--dangerously-skip-permissions'
    }
}

Describe 'Start-FmConsole' {

    BeforeEach {
        $script:cwd = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $script:cwd -Force | Out-Null
        $script:sent = @()
        Mock New-FmHerdrContainer {
            [pscustomobject]@{ Session = 'default'; WorkspaceId = 'w1'; SeededTabId = 't0'; Container = 'default:w1' }
        }
        Mock New-FmHerdrTask {
            [pscustomobject]@{ Session = 'default'; TabId = 't1'; PaneId = 'w1:p2'; Target = 'default:w1:p2' }
        }
        Mock Send-FmHerdrTextLine { $script:sent += $Text; $true }
        Mock Set-FmHerdrTabFocus { $true }
        Mock Remove-FmHerdrPane { $true }
    }

    It 'opens a window at the given directory and starts firstmate in it' {
        $c = Start-FmConsole -Cwd $script:cwd -Command "& 'C:\fm\bin\fm-bridge.ps1' -Port 7433" -Confirm:$false
        $c.Ok | Should -BeTrue
        $c.Target | Should -Be 'default:w1:p2'
        Should -Invoke New-FmHerdrContainer -Times 1 -ParameterFilter { $Cwd -eq $script:cwd }
        Should -Invoke New-FmHerdrTask -Times 1 -ParameterFilter { $Cwd -eq $script:cwd -and $Label -eq 'firstmate' }
        $script:sent.Count | Should -Be 1
        $script:sent[0] | Should -BeLike 'pwsh -NoProfile -Command *'
        $script:sent[0] | Should -Match 'fm-bridge'
    }

    # Get-FmHerdrLiveTask reads every fm-* tab in the workspace as a worker, so
    # a console labelled that way would be reconciled as a crewmate that has
    # gone missing the moment the captain closes it.
    It "never gives firstmate's own window a worker's name" {
        $c = Start-FmConsole -Cwd $script:cwd -Command 'x' -Label 'fm-firstmate' -Confirm:$false
        $c.Ok | Should -BeFalse
        $c.Reason | Should -Match 'fm-'
        Should -Invoke New-FmHerdrContainer -Times 0
    }

    It 'brings the window forward, and only after the command is already running' {
        $null = Start-FmConsole -Cwd $script:cwd -Command 'x' -Confirm:$false
        Should -Invoke Set-FmHerdrTabFocus -Times 1 -ParameterFilter { $TabId -eq 't1' }
    }

    # A MISSING WINDOW MUST NOT BE A MISSING FIRSTMATE. Every other herdr caller
    # in this port is a spawn and throws; this one is the captain's own start,
    # and start.ps1 needs a decision rather than an exception so it can run the
    # engine where they typed instead.
    It 'answers rather than throwing when there is no session provider on the machine' {
        Mock New-FmHerdrContainer { throw "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev)" }
        { $script:answer = Start-FmConsole -Cwd $script:cwd -Command 'x' -Confirm:$false } | Should -Not -Throw
        $script:answer.Ok | Should -BeFalse
        $script:answer.Reason | Should -Match 'not installed'
    }

    It 'answers rather than throwing when a window is already open for this home' {
        Mock New-FmHerdrTask { throw "herdr tab 'firstmate' already exists in workspace w1 (session default)" }
        { $script:answer = Start-FmConsole -Cwd $script:cwd -Command 'x' -Confirm:$false } | Should -Not -Throw
        $script:answer.Ok | Should -BeFalse
        $script:answer.Reason | Should -Match 'already exists'
    }

    It 'leaves no empty window behind when firstmate could not be started in it' {
        Mock Send-FmHerdrTextLine { $false }
        $c = Start-FmConsole -Cwd $script:cwd -Command 'x' -Confirm:$false
        $c.Ok | Should -BeFalse
        Should -Invoke Remove-FmHerdrPane -Times 1 -ParameterFilter { $Target -eq 'default:w1:p2' }
    }

    # firstmate IS running in that window whether or not it came forward, and
    # reporting a refusal here would send start.ps1 off to start a SECOND one.
    It 'is still a success when the window would not come forward' {
        Mock Set-FmHerdrTabFocus { $false }
        (Start-FmConsole -Cwd $script:cwd -Command 'x' -Confirm:$false).Ok | Should -BeTrue
    }

    It 'refuses a directory that is not there without touching the session provider' {
        $c = Start-FmConsole -Cwd (Join-Path $TestDrive 'nowhere') -Command 'x' -Confirm:$false
        $c.Ok | Should -BeFalse
        $c.Reason | Should -Match 'no directory'
        Should -Invoke New-FmHerdrContainer -Times 0
    }

    It 'refuses a command the pane shell cannot carry, before anything is created' {
        $c = Start-FmConsole -Cwd $script:cwd -Command '& "C:\fm\bin\fm-bridge.ps1"' -Confirm:$false
        $c.Ok | Should -BeFalse
        $c.Reason | Should -Match 'double quote'
        Should -Invoke New-FmHerdrContainer -Times 0
    }

    It 'creates nothing under -WhatIf' {
        $c = Start-FmConsole -Cwd $script:cwd -Command 'x' -WhatIf
        $c.Ok | Should -BeFalse
        Should -Invoke New-FmHerdrContainer -Times 0
        Should -Invoke New-FmHerdrTask -Times 0
    }
}
