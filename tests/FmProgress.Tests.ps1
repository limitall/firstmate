#requires -Version 7.0
<#
    Tests for the milestone-to-percentage progress report.

    The captain's bar for this feature is explicit: "I am not expecting hundred
    percent correct statistics and progress report, but at least we have some
    idea." So what these pin is not accuracy - there is nothing to be accurate
    against - but HONESTY:

      1. An absent percentage stays absent. A task that declared none must read
         as unknown, never as 0%. A guess reads exactly like a real figure and is
         worse than no figure at all.
      2. A finished task reads as finished, whatever its last number said.
      3. A malformed or impossible percentage is refused rather than clamped,
         because clamping turns a typo into a confident answer.
      4. The existing status format keeps working. Every line written before this
         convention existed must still parse, just without a number.
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    Import-FmTestModule -TestRoot $PSScriptRoot

    function New-ProgressHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder; writes only under TestDrive.')]
        param()
        $state = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $state -Force
        $state
    }

    function Add-ProgressTask {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder; writes only under TestDrive.')]
        param($State, $Id, [string[]]$StatusLines = @())
        [System.IO.File]::WriteAllText((Join-Path $State "$Id.meta"),
            "window=default:w1:p1`nproject=C:\repos\thing`nkind=ship`n")
        if ($StatusLines.Count -gt 0) {
            [System.IO.File]::WriteAllText((Join-Path $State "$Id.status"), (($StatusLines -join "`n") + "`n"))
        }
    }
}

Describe 'reading a percentage out of a status line' {
    It 'reads the bracket form' {
        InModuleScope Firstmate {
            Get-FmProgressPercent -Line 'working: [40%] doing the thing' | Should -Be 40
        }
    }

    It 'tolerates spacing and a bare note with no state prefix' -ForEach @(
        @{ Line = 'working: [ 7 % ] x'; Expected = 7 }
        @{ Line = '[85%] no state prefix'; Expected = 85 }
        @{ Line = 'needs-decision: [50%] which option'; Expected = 50 }
    ) {
        InModuleScope Firstmate -Parameters @{ Line = $Line; Expected = $Expected } {
            Get-FmProgressPercent -Line $Line | Should -Be $Expected
        }
    }

    It 'returns nothing for a line that carries no percentage' -ForEach @(
        @{ Line = 'working: setup done in worktree' }
        @{ Line = '' }
        @{ Line = '   ' }
    ) {
        InModuleScope Firstmate -Parameters @{ Line = $Line } {
            Get-FmProgressPercent -Line $Line | Should -BeNullOrEmpty
        }
    }

    It 'does NOT mistake a percentage in prose for a progress claim' {
        # "coverage rose to 80%" is the subject matter, not a progress report.
        InModuleScope Firstmate {
            Get-FmProgressPercent -Line 'working: coverage rose to 80% on the parser' |
                Should -BeNullOrEmpty
        }
    }

    It 'refuses an impossible percentage rather than clamping it' -ForEach @(
        @{ Line = 'working: [101%] x' }
        @{ Line = 'working: [999%] x' }
    ) {
        # Clamping would turn a typo into a confident 100.
        InModuleScope Firstmate -Parameters @{ Line = $Line } {
            Get-FmProgressPercent -Line $Line | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-FmProgress' {
    It 'reports the last declared percentage and its note' {
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'alpha' -StatusLines @(
            'working: [10%] setup done'
            'working: [60%] owner implemented, writing coverage'
        )
        $row = Get-FmProgress -StatePath $state -TaskId 'alpha'
        $row.Percent | Should -Be 60
        $row.State | Should -Be 'working'
        $row.Note | Should -BeLike '*writing coverage*'
    }

    It 'reports UNKNOWN, not zero, when no percentage was ever declared' {
        # The regression that matters: a worker predating this convention must
        # not be shown to the captain as stalled at 0%.
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'legacy' -StatusLines @('working: setup done in worktree')
        $row = Get-FmProgress -StatePath $state -TaskId 'legacy'
        $row.Percent | Should -BeNullOrEmpty
        $row.Bar | Should -Match '^\?+$'
    }

    It 'falls back to the last line that HAD a percentage' {
        # A later line without a number must not erase what was already known.
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'beta' -StatusLines @(
            'working: [30%] first stage'
            'working: still grinding'
        )
        (Get-FmProgress -StatePath $state -TaskId 'beta').Percent | Should -Be 30
    }

    It 'reads a finished task as 100, whatever its last number said' {
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'gamma' -StatusLines @(
            'working: [60%] nearly there'
            'done: ready in branch fm/gamma'
        )
        $row = Get-FmProgress -StatePath $state -TaskId 'gamma'
        $row.Percent | Should -Be 100
        $row.State | Should -Be 'done'
    }

    It 'reports a task with no status log at all' {
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'fresh'
        $row = Get-FmProgress -StatePath $state -TaskId 'fresh'
        $row.TaskId | Should -Be 'fresh'
        $row.Percent | Should -BeNullOrEmpty
    }

    It 'reports every task under way, and only tasks that have a record' {
        $state = New-ProgressHome
        Add-ProgressTask -State $state -Id 'one' -StatusLines @('working: [20%] a')
        Add-ProgressTask -State $state -Id 'two' -StatusLines @('working: [80%] b')
        # A stray status log with no metadata is not a task under way.
        [System.IO.File]::WriteAllText((Join-Path $state 'orphan.status'), "working: [50%] ghost`n")
        $rows = @(Get-FmProgress -StatePath $state)
        $rows.Count | Should -Be 2
        ($rows.TaskId | Sort-Object) -join ',' | Should -Be 'one,two'
    }

    It 'returns nothing when nothing is under way' {
        @(Get-FmProgress -StatePath (New-ProgressHome)).Count | Should -Be 0
    }
}

Describe 'the bar' {
    It 'renders proportionally at a fixed width' -ForEach @(
        @{ Percent = 0; Expected = '....................' }
        @{ Percent = 50; Expected = '##########..........' }
        @{ Percent = 100; Expected = '####################' }
    ) {
        InModuleScope Firstmate -Parameters @{ Percent = $Percent; Expected = $Expected } {
            Format-FmProgressBar -Percent $Percent -Width 20 | Should -Be $Expected
        }
    }

    It 'renders unknown as question marks, never as an empty bar' {
        # An empty bar and a 0% bar look identical, and one of them is a lie.
        InModuleScope Firstmate {
            Format-FmProgressBar -Percent $null -Width 8 | Should -Be '????????'
        }
    }
}
