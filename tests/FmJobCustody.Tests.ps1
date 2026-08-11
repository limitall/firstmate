#requires -Version 7.0
# Pester 5+/6 tests for process custody.
#
# WHAT CAN AND CANNOT BE PROVEN HERE. Job objects are a Win32 kernel facility;
# there is no Linux equivalent and this port deliberately does not emulate one.
# So the tests split in two:
#   - the DEGRADATION contract runs everywhere, and it is the part that
#     protects work: on a host without job objects, every entry point reports
#     "not proven" rather than "nothing to kill". That distinction is the whole
#     safety property, and it is fully covered below.
#   - the real terminate-and-verify path runs only on Windows, where it spawns a
#     real child, assigns it, kills the job, and proves the child is gone.
#     Those tests are Skipped elsewhere - never silently passed.

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmBackendHerdr.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmJobCustody.ps1')
}

Describe 'Get-FmTaskJobName' {
    It 'names one job per task in the per-session namespace' {
        Get-FmTaskJobName -TaskId 'fmwin-teardown' | Should -Be 'Local\firstmate-task-fmwin-teardown'
    }

    It 'refuses a task id that is not a valid task id' {
        # The job name is a kernel object name; a task id with a separator in it
        # would name a different object than the one teardown later opens.
        { Get-FmTaskJobName -TaskId 'bad id' } | Should -Throw '*not a valid task id*'
        { Get-FmTaskJobName -TaskId '.hidden' } | Should -Throw '*not a valid task id*'
    }
}

Describe 'Test-FmJobCustodySupported' {
    It 'is true only on Windows' {
        Test-FmJobCustodySupported | Should -Be ([bool]$IsWindows)
    }
}

Describe 'custody degradation on a host without job objects' -Skip:([bool]$IsWindows) {
    It 'reports Stop-FmTaskJob as unsupported, never as "nothing to kill"' {
        $result = Stop-FmTaskJob -TaskId 'alpha' -Confirm:$false
        $result.Outcome | Should -Be 'unsupported'
        $result.Outcome | Should -Not -Be 'terminated'
        $result.Detail | Should -Match 'only on Windows'
    }

    It 'reports the process list as unsupported rather than empty' {
        $result = Get-FmTaskJobProcessId -TaskId 'alpha'
        $result.State | Should -Be 'unsupported'
        $result.State | Should -Not -Be 'empty'
    }

    It 'returns null from the Restart Manager diagnostic, which is not "nobody"' {
        Get-FmFileHolderProcess -Path @((Join-Path $TestDrive 'anything')) | Should -BeNullOrEmpty
    }

    It 'refuses to create or assign' {
        $job = New-FmTaskJob -TaskId 'alpha' -Confirm:$false
        $job.Ok | Should -BeFalse
        $job.Reason | Should -Match 'unavailable'
        Add-FmTaskJobProcess -JobHandle ([IntPtr]::Zero) -ProcessId 1 -Confirm:$false | Should -BeFalse
    }
}

Describe 'Stop-FmTaskJob honours ShouldProcess' {
    It 'does not terminate anything under -WhatIf' {
        $result = Stop-FmTaskJob -TaskId 'alpha' -WhatIf
        $result.Outcome | Should -BeIn @('skipped', 'unsupported')
    }
}

Describe 'real job-object custody' -Skip:(-not $IsWindows) {
    It 'terminates every process in the job and proves the job is empty' {
        $taskId = 'custody-alpha'
        $job = New-FmTaskJob -TaskId $taskId -Confirm:$false
        $job.Ok | Should -BeTrue
        try {
            $child = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'pause' -PassThru -WindowStyle Hidden
            (Add-FmTaskJobProcess -JobHandle $job.Handle -ProcessId $child.Id -Confirm:$false) | Should -BeTrue
            (Get-FmTaskJobProcessId -TaskId $taskId).State | Should -Be 'processes'

            $result = Stop-FmTaskJob -TaskId $taskId -TimeoutSeconds 10 -Confirm:$false
            $result.Outcome | Should -Be 'terminated'
            $child.HasExited | Should -BeTrue
        } finally {
            $null = Close-FmTaskJob -JobHandle $job.Handle
        }
    }

    It 'reports not-found for a task that never registered custody' {
        $result = Stop-FmTaskJob -TaskId 'custody-never-registered' -Confirm:$false
        $result.Outcome | Should -Be 'not-found'
        $result.Detail | Should -Match 'indistinguishable'
    }

    It 'names the process holding a file open' {
        $file = Join-Path $TestDrive 'held.txt'
        Set-Content -LiteralPath $file -Value 'x'
        $stream = [System.IO.File]::Open($file, 'Open', 'ReadWrite', [System.IO.FileShare]::None)
        try {
            $holders = Get-FmFileHolderProcess -Path @($file)
            $holders | Should -Not -BeNullOrEmpty
        } finally {
            $stream.Dispose()
        }
    }
}
