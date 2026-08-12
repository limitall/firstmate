#requires -Version 7.0
<#
    Pester tests for the backend area's WINDOW contract - the generic
    per-endpoint reads the watcher's pane layer and the crew-state reader ask
    for by name.

    WHY THIS FILE EXISTS. Every one of these names was bound by name and defined
    nowhere, while the herdr primitives underneath them had already landed. The
    consequences were invisible and total: the watcher skipped its whole layer-1
    staleness backbone, so a dispatched crewmate could wedge with no wake ever
    raised, and `fm-crew-state.ps1` answered "no backend state reader available"
    for every task. Nothing failed; there was simply no answer anywhere.

    No herdr server is started here. The adapter primitives are mocked, which is
    also what pins the ONE property this layer must not lose: it reads, and never
    resurrects anything it is only observing.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    . (Join-Path $PSScriptRoot 'FmLifecycle.TestHelpers.ps1')
    foreach ($file in Get-FmLifecycleSourceFile) { . $file }

    function New-WindowMeta {
        param(
            [Parameter(Mandatory)]$TestHome,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][hashtable]$Fields
        )
        $lines = @($Fields.Keys | Sort-Object | ForEach-Object { "$_=$($Fields[$_])" })
        [System.IO.File]::WriteAllText((Join-Path $TestHome.State "$Id.meta"), (($lines -join "`n") + "`n"))
    }
}

Describe 'Get-FmRecordedWindows' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'lists every recorded endpoint in task-id order' {
        New-WindowMeta -TestHome $script:TestHome -Id 'bravo' -Fields @{ backend = 'herdr'; window = 'fleet:w2:p2' }
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
        @(Get-FmRecordedWindows -StatePath $script:TestHome.State) | Should -Be @('fleet:w1:p1', 'fleet:w2:p2')
    }

    It 'walks a shared endpoint once, not twice' {
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
        New-WindowMeta -TestHome $script:TestHome -Id 'bravo' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
        @(Get-FmRecordedWindows -StatePath $script:TestHome.State).Count | Should -Be 1
    }

    It 'skips a task record that carries no endpoint at all' {
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; worktree = '/tmp/x' }
        @(Get-FmRecordedWindows -StatePath $script:TestHome.State).Count | Should -Be 0
    }

    It 'returns an empty list for a state directory that does not exist' {
        @(Get-FmRecordedWindows -StatePath (Join-Path $script:TestHome.Path 'nope')).Count | Should -Be 0
    }
}

Describe 'Get-FmWindowKind and Get-FmWindowBackend' {
    BeforeEach { $script:TestHome = New-FmTestHome }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'reports the recorded kind' {
        New-WindowMeta -TestHome $script:TestHome -Id 'sm' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1'; kind = 'secondmate' }
        Get-FmWindowKind -Window 'fleet:w1:p1' -StatePath $script:TestHome.State | Should -Be 'secondmate'
    }

    It 'defaults a record with no kind to ship, and only an UNRECORDED window to unknown' {
        # The watcher treats a secondmate endpoint as healthy when idle and
        # surfaces everything else, so these two must not collapse together.
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
        Get-FmWindowKind -Window 'fleet:w1:p1' -StatePath $script:TestHome.State | Should -Be 'ship'
        Get-FmWindowKind -Window 'fleet:nope:p9' -StatePath $script:TestHome.State | Should -Be 'unknown'
    }

    It 'keeps the meta compatibility contract: an absent backend field means tmux' {
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ window = 'fleet:w1:p1' }
        Get-FmWindowBackend -Window 'fleet:w1:p1' -StatePath $script:TestHome.State | Should -Be 'tmux'
    }
}

Describe 'Get-FmBackendCapture' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'returns the pane tail for a live herdr endpoint' {
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrCapture { "line one`nline two" }
        Get-FmBackendCapture -Window 'fleet:w1:p1' -StatePath $script:TestHome.State -Lines 40 |
            Should -Be "line one`nline two"
    }

    It 'never STARTS a session server: it probes existence, not readiness' {
        # Readiness starts a stopped server. The watcher runs this every cycle,
        # so a read here must never resurrect an endpoint it is observing.
        Mock Test-FmHerdrTargetExists { $false }
        Mock Test-FmHerdrTargetReady { $true }
        Mock Get-FmHerdrCapture { 'should not be reached' }
        Get-FmBackendCapture -Window 'fleet:w1:p1' -StatePath $script:TestHome.State | Should -BeNullOrEmpty
        Should -Invoke Test-FmHerdrTargetReady -Times 0
        Should -Invoke Get-FmHerdrCapture -Times 0
    }

    It 'reports no pane evidence for a backend this port does not drive' {
        New-WindowMeta -TestHome $script:TestHome -Id 'bravo' -Fields @{ backend = 'tmux'; window = 'sess:fm-bravo' }
        Get-FmBackendCapture -Window 'sess:fm-bravo' -StatePath $script:TestHome.State | Should -BeNullOrEmpty
    }
}

Describe 'Test-FmWindowBusy' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'is busy ONLY on a positive working verdict' {
        Mock Test-FmHerdrTargetExists { $true }
        foreach ($case in @(
                @{ State = 'busy'; Expected = $true }
                @{ State = 'idle'; Expected = $false }
                @{ State = 'unknown'; Expected = $false })) {
            Mock Get-FmHerdrBusyState { $case.State }.GetNewClosure()
            Test-FmWindowBusy -Window 'fleet:w1:p1' -StatePath $script:TestHome.State -Tail 'whatever' |
                Should -Be $case.Expected -Because "agent state $($case.State)"
        }
    }

    It 'is not busy when the endpoint is gone, so the pane goes stale and surfaces' {
        Mock Test-FmHerdrTargetExists { $false }
        Test-FmWindowBusy -Window 'fleet:w1:p1' -StatePath $script:TestHome.State -Tail '' | Should -BeFalse
    }
}

Describe 'Get-FmBackendAgentAlive' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'collapses the recovery-grade state to the three words the triage reads' {
        foreach ($case in @(
                @{ Agent = 'alive'; Expected = 'alive' }
                @{ Agent = 'dead'; Expected = 'dead' }
                @{ Agent = 'missing'; Expected = 'dead' }
                @{ Agent = 'unreadable'; Expected = 'unknown' })) {
            Mock Get-FmHerdrAgentState { $case.Agent }.GetNewClosure()
            Get-FmBackendAgentAlive -Window 'fleet:w1:p1' -StatePath $script:TestHome.State |
                Should -Be $case.Expected -Because "agent state $($case.Agent)"
        }
    }
}

Describe 'Get-FmBackendBusyVerdict' {
    BeforeEach {
        $script:TestHome = New-FmTestHome
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{ backend = 'herdr'; window = 'fleet:w1:p1' }
    }
    AfterEach { Remove-FmTestHome -TestHome $script:TestHome }

    It 'leads with the verdict word and names its source' {
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrBusyState { 'busy' }
        $verdict = Get-FmBackendBusyVerdict -Backend 'herdr' -Target 'fleet:w1:p1' -Id 'alpha' `
            -Harness 'claude' -StatePath $script:TestHome.State
        $verdict | Should -Be 'busy herdr-native'
        ($verdict -split ' ')[0] | Should -Be 'busy'
    }

    It 'reports a gone endpoint as dead before anything else is consulted' {
        Mock Test-FmHerdrTargetExists { $false }
        Mock Get-FmHerdrBusyState { 'busy' }
        Get-FmBackendBusyVerdict -Backend 'herdr' -Target 'fleet:w1:p1' -Id 'alpha' `
            -Harness 'claude' -StatePath $script:TestHome.State | Should -Be 'dead endpoint-gone'
        Should -Invoke Get-FmHerdrBusyState -Times 0
    }

    It 'refuses to assert anything for a backend this port has not verified' {
        Get-FmBackendBusyVerdict -Backend 'tmux' -Target 'sess:fm-a' -Id 'alpha' `
            -Harness 'claude' -StatePath $script:TestHome.State | Should -BeLike 'unknown backend-unverified*'
    }

    It 'reports no target as unknown, never as idle' {
        Get-FmBackendBusyVerdict -Backend 'herdr' -Target '' -Id 'alpha' `
            -Harness 'claude' -StatePath $script:TestHome.State | Should -Be 'unknown no-target'
    }

    It 'gives Get-FmCrewState a real answer instead of "no backend state reader available"' {
        # The end-to-end point of this file: the reader exists, so a crew's
        # state can actually be read back.
        $project = New-FmTestProject -Root $script:TestHome.Path -Id 'alpha'
        New-WindowMeta -TestHome $script:TestHome -Id 'alpha' -Fields @{
            backend = 'herdr'; window = 'fleet:w1:p1'; kind = 'ship'; harness = 'claude'
            worktree = $project.Worktree
        }
        Mock Test-FmHerdrTargetExists { $true }
        Mock Get-FmHerdrBusyState { 'busy' }

        $line = Get-FmCrewState -Id 'alpha'
        $line | Should -BeLike 'state: working*'
        $line | Should -BeLike '*source: pane*'
        $line | Should -Not -BeLike '*no backend state reader available*'
    }
}
