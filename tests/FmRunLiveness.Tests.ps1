#requires -Version 7.0
<#
    Pester tests for the run-liveness reading.

    The load-bearing property is ASYMMETRIC and the tests are weighted to match
    it. Answering `processes` when nothing runs costs a supervisor one wasted
    look. Answering `none` while a run is still going produces a false "your run
    has finished" steer, and that is what cost nine genuinely-running suites
    (docs/finished-run-stall.md). So every ambiguity, every unreadable input and
    every partial discovery is asserted to land on `processes` or `unknown`, and
    `none` is asserted only where the process table positively holds nothing.

    The process table is supplied directly in most tests: the decision procedure
    is what is under test, and a fabricated table exercises shapes - an orphan, a
    recycled pid, a run whose command line names nothing - that cannot be staged
    reliably with real processes. The two tests that DO spawn real processes
    cover the part a fabricated table cannot prove: that a real background child
    of this process is discovered, and that the real reader answers at all.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes and fabricated process rows. -WhatIf on a fixture would leave the test asserting against a home or a table that was never created.')]
param()
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-LivenessHome {
        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-liveness-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'data') -Force
        return $fmHome
    }

    function New-LivenessTask {
        <# A task record and brief the reading can resolve, plus the worktree
           directory it names. #>
        param(
            [Parameter(Mandatory)][string]$FmHome,
            [Parameter(Mandatory)][string]$TaskId,
            [string]$Harness = 'claude'
        )
        $worktree = Join-Path $FmHome ('wt-' + $TaskId)
        $null = New-Item -ItemType Directory -Path $worktree -Force
        $null = New-Item -ItemType Directory -Path (Join-Path (Join-Path $FmHome 'data') $TaskId) -Force
        $brief = Join-Path (Join-Path (Join-Path $FmHome 'data') $TaskId) 'brief.md'
        Set-Content -LiteralPath $brief -Value 'brief' -NoNewline
        $meta = Join-Path (Join-Path $FmHome 'state') "$TaskId.meta"
        Set-Content -LiteralPath $meta -Value @(
            "window=default:w1:pA"
            "worktree=$worktree"
            "harness=$Harness"
            "kind=ship"
        )
        return [pscustomobject]@{ Worktree = $worktree; Brief = $brief; Meta = $meta }
    }

    function New-Row {
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [int]$ParentProcessId = 0,
            [string]$Name = 'pwsh.exe',
            [string]$ExecutablePath = '',
            [string]$CommandLine = ''
        )
        [pscustomobject]@{
            ProcessId       = $ProcessId
            ParentProcessId = $ParentProcessId
            Name            = $Name
            ExecutablePath  = $ExecutablePath
            CommandLine     = $CommandLine
        }
    }

    # The measured real shape: a launcher pwsh whose command line names the
    # brief, a claude.exe child, and whatever the agent starts under that.
    function New-WorkerTable {
        param(
            [Parameter(Mandatory)][string]$Brief,
            [object[]]$Extra = @()
        )
        $rows = @(
            New-Row -ProcessId 100 -ParentProcessId 1 -CommandLine "pwsh -NoProfile -Command `"claude ... (Get-Content -Raw -LiteralPath '$Brief')`""
            New-Row -ProcessId 200 -ParentProcessId 100 -Name 'claude.exe' -ExecutablePath 'C:\bin\claude.exe' -CommandLine 'claude.exe --dangerously-skip-permissions'
        )
        return @($rows + @($Extra))
    }
}

Describe 'Get-FmTaskRunLiveness discovers what the worker is running' {
    BeforeEach {
        $script:FmHome = New-LivenessHome
        $script:State = Join-Path $script:FmHome 'state'
        $script:Data = Join-Path $script:FmHome 'data'
        $script:Task = New-LivenessTask -FmHome $script:FmHome -TaskId 'alpha'
    }
    AfterEach {
        if ($script:FmHome -and (Test-Path -LiteralPath $script:FmHome)) {
            Remove-Item -LiteralPath $script:FmHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports none when the agent has no descendant at all' {
        $table = New-WorkerTable -Brief $script:Task.Brief
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table
        $result.State | Should -Be 'none'
        @($result.ProcessId).Count | Should -Be 0
        # The agent itself is still named, so an inspection can reach the pane.
        @($result.AgentProcessId) | Should -Contain 200
    }

    It 'reports processes for a background run whose OWN command line names nothing' {
        # This is the exact shape the supervisor's ad-hoc check missed: the
        # harness runs a background command as `pwsh -Command "<script>"` with
        # the worktree only as its working directory, so no path appears on the
        # command line. It is found because it descends from the agent.
        $run = New-Row -ProcessId 300 -ParentProcessId 200 -CommandLine 'pwsh -NoProfile -Command "Invoke-Pester -Path ./tests"'
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra @($run)
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table
        $result.State | Should -Be 'processes'
        @($result.ProcessId) | Should -Contain 300
    }

    It 'finds a run nested several levels below the agent' {
        $extra = @(
            New-Row -ProcessId 300 -ParentProcessId 200 -Name 'bash.exe' -CommandLine 'bash -c "..."'
            New-Row -ProcessId 301 -ParentProcessId 300 -Name 'bash.exe' -CommandLine 'bash -c "..."'
            New-Row -ProcessId 302 -ParentProcessId 301 -CommandLine 'pwsh -Command "Invoke-Pester"'
        )
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra $extra
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table
        $result.State | Should -Be 'processes'
        @($result.ProcessId) | Should -Contain 302
    }

    It 'finds an ORPHANED run through the worktree pass when its parent chain is broken' {
        # The intermediate shell exited, so the run no longer descends from the
        # agent. The second discovery pass - anything naming the worktree - is
        # what keeps this from reading as "nothing is running".
        $orphan = New-Row -ProcessId 900 -ParentProcessId 4 -CommandLine "pwsh -Command `"Set-Location '$($script:Task.Worktree)'; Invoke-Pester`""
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra @($orphan)
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table
        $result.State | Should -Be 'processes'
        @($result.ProcessId) | Should -Contain 900
    }

    It 'matches a worktree path spelled with forward slashes' {
        # A Bash-tool command line carries C:/a/b where PowerShell carries C:\a\b.
        $forward = ($script:Task.Worktree -replace '\\', '/')
        $orphan = New-Row -ProcessId 901 -ParentProcessId 4 -Name 'bash.exe' -CommandLine "bash -c `"cd '$forward' && pwsh -c Invoke-Pester`""
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra @($orphan)
        (Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table).State |
            Should -Be 'processes'
    }

    It 'counts a process whose IMAGE lives in the worktree even with an empty command line' {
        $built = New-Row -ProcessId 902 -ParentProcessId 4 -Name 'tool.exe' -ExecutablePath (Join-Path $script:Task.Worktree 'tool.exe') -CommandLine ''
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra @($built)
        (Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table).State |
            Should -Be 'processes'
    }

    It 'does not count another task running in a different worktree' {
        $other = New-Row -ProcessId 903 -ParentProcessId 4 -CommandLine 'pwsh -Command "cd C:\somewhere\else; Invoke-Pester"'
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra @($other)
        (Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table).State |
            Should -Be 'none'
    }

    It 'keeps the launch spine out of the work set for an unverified harness too' {
        # An adapter this port does not verify still has an Executable name, so
        # its agent process is spine rather than work.
        $task = New-LivenessTask -FmHome $script:FmHome -TaskId 'codexer' -Harness 'codex'
        $rows = @(
            New-Row -ProcessId 110 -ParentProcessId 1 -CommandLine "pwsh -Command `"codex ... '$($task.Brief)'`""
            New-Row -ProcessId 210 -ParentProcessId 110 -Name 'codex.exe' -CommandLine 'codex.exe'
        )
        (Get-FmTaskRunLiveness -TaskId 'codexer' -StatePath $script:State -DataPath $script:Data -Table $rows).State |
            Should -Be 'none'
    }

    It 'reports processes rather than none when the harness has no adapter at all' {
        # No adapter means no way to tell the agent apart from its work, so the
        # agent counts as work - the safe direction.
        $task = New-LivenessTask -FmHome $script:FmHome -TaskId 'mystery' -Harness 'no-such-harness'
        $rows = @(
            New-Row -ProcessId 120 -ParentProcessId 1 -CommandLine "pwsh -Command `"x ... '$($task.Brief)'`""
            New-Row -ProcessId 220 -ParentProcessId 120 -Name 'mystery.exe' -CommandLine 'mystery.exe'
        )
        (Get-FmTaskRunLiveness -TaskId 'mystery' -StatePath $script:State -DataPath $script:Data -Table $rows).State |
            Should -Be 'processes'
    }

    It 'terminates on a parent cycle instead of walking for ever' {
        # A recycled pid can make a process its own ancestor. Adding an unrelated
        # process is safe; not returning is not.
        $extra = @(
            New-Row -ProcessId 300 -ParentProcessId 200
            New-Row -ProcessId 301 -ParentProcessId 300
            New-Row -ProcessId 200 -ParentProcessId 301 -Name 'claude.exe'
        )
        $table = New-WorkerTable -Brief $script:Task.Brief -Extra $extra
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table
        $result.State | Should -Be 'processes'
    }
}

Describe 'Get-FmTaskRunLiveness refuses to invent a negative' {
    BeforeEach {
        $script:FmHome = New-LivenessHome
        $script:State = Join-Path $script:FmHome 'state'
        $script:Data = Join-Path $script:FmHome 'data'
        $script:Task = New-LivenessTask -FmHome $script:FmHome -TaskId 'alpha'
    }
    AfterEach {
        Remove-Item -Path 'env:FM_RUN_LIVENESS_DISABLE' -ErrorAction SilentlyContinue
        if ($script:FmHome -and (Test-Path -LiteralPath $script:FmHome)) {
            Remove-Item -LiteralPath $script:FmHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'is unknown, never none, when the process table cannot be read' {
        # $null is the reader's "could not answer". An empty array would be a
        # claim that the box has no processes, which is why the reader never
        # produces one.
        Mock -CommandName Get-FmRunLivenessProcessTable -MockWith { return $null }
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data
        $result.State | Should -Be 'unknown'
        $result.Detail | Should -Match 'could not be read'
    }

    It 'is unknown when no launcher process names the task brief' {
        $stranger = @(New-Row -ProcessId 400 -ParentProcessId 1 -CommandLine 'pwsh -Command "unrelated"')
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $stranger
        $result.State | Should -Be 'unknown'
        $result.Detail | Should -Match 'no launcher process'
    }

    It 'is unknown for a task with no record' {
        $result = Get-FmTaskRunLiveness -TaskId 'never-spawned' -StatePath $script:State -DataPath $script:Data
        $result.State | Should -Be 'unknown'
        $result.Detail | Should -Match 'no metadata'
    }

    It 'is unknown for an empty task id' {
        (Get-FmTaskRunLiveness -TaskId '' -StatePath $script:State -DataPath $script:Data).State | Should -Be 'unknown'
    }

    It 'is unknown, and says so, when the probe is switched off' {
        $env:FM_RUN_LIVENESS_DISABLE = '1'
        $result = Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data
        $result.State | Should -Be 'unknown'
        $result.Detail | Should -Match 'disabled'
    }

    It 'reads none only from a table it actually got' {
        # The negative control for the whole area: with the launcher present and
        # a real table the answer is none, and the SAME call with an unreadable
        # table must not keep saying none.
        $table = New-WorkerTable -Brief $script:Task.Brief
        (Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data -Table $table).State |
            Should -Be 'none'
        Mock -CommandName Get-FmRunLivenessProcessTable -MockWith { return $null }
        (Get-FmTaskRunLiveness -TaskId 'alpha' -StatePath $script:State -DataPath $script:Data).State |
            Should -Be 'unknown'
    }
}

Describe 'Get-FmRunLivenessProcessTable reads the real machine' {
    It 'returns this process, with a parent and a command line' {
        $table = Get-FmRunLivenessProcessTable
        $table | Should -Not -BeNullOrEmpty
        $self = @($table | Where-Object { $_.ProcessId -eq $PID })
        $self.Count | Should -Be 1
        $self[0].ParentProcessId | Should -BeGreaterThan 0
        $self[0].CommandLine | Should -Not -BeNullOrEmpty
    }

    It 'never returns an empty array, because "no processes" is not an answer' {
        @(Get-FmRunLivenessProcessTable).Count | Should -BeGreaterThan 1
    }
}

Describe 'the reading finds a REAL background run' {
    BeforeEach {
        $script:FmHome = New-LivenessHome
        $script:State = Join-Path $script:FmHome 'state'
        $script:Data = Join-Path $script:FmHome 'data'
        $script:Task = New-LivenessTask -FmHome $script:FmHome -TaskId 'realrun'
        $script:Child = $null
    }
    AfterEach {
        if ($script:Child -and -not $script:Child.HasExited) {
            $script:Child | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        if ($script:FmHome -and (Test-Path -LiteralPath $script:FmHome)) {
            Remove-Item -LiteralPath $script:FmHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sees a live child of the launcher, and stops seeing it once it exits' {
        # This process stands in for the launcher: the table is real, and the
        # only fabrication is one row pointing the launcher at $PID. That is what
        # makes the descendant walk a real measurement rather than a fixture.
        $exe = (Get-Process -Id $PID).Path
        $script:Child = Start-Process -FilePath $exe `
            -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 45' `
            -PassThru -WindowStyle Hidden

        $table = @(Get-FmRunLivenessProcessTable)
        $table | Should -Not -BeNullOrEmpty
        # Re-label this process as the task's launcher; every other row is real.
        $relabelled = @($table | ForEach-Object {
                if ($_.ProcessId -eq $PID) {
                    New-Row -ProcessId $_.ProcessId -ParentProcessId $_.ParentProcessId -Name $_.Name `
                        -ExecutablePath $_.ExecutablePath -CommandLine "launcher for '$($script:Task.Brief)'"
                }
                else { $_ }
            })

        $result = Get-FmTaskRunLiveness -TaskId 'realrun' -StatePath $script:State -DataPath $script:Data -Table $relabelled
        $result.State | Should -Be 'processes'
        @($result.ProcessId) | Should -Contain $script:Child.Id

        $script:Child | Stop-Process -Force
        $script:Child.WaitForExit(20000) | Out-Null

        $after = @(Get-FmRunLivenessProcessTable | ForEach-Object {
                if ($_.ProcessId -eq $PID) {
                    New-Row -ProcessId $_.ProcessId -ParentProcessId $_.ParentProcessId -Name $_.Name `
                        -ExecutablePath $_.ExecutablePath -CommandLine "launcher for '$($script:Task.Brief)'"
                }
                else { $_ }
            })
        @((Get-FmTaskRunLiveness -TaskId 'realrun' -StatePath $script:State -DataPath $script:Data -Table $after).ProcessId) |
            Should -Not -Contain $script:Child.Id
    }
}

Describe 'Format-FmTaskRunLiveness' {
    It 'names the state, the task and the pids' {
        $record = New-FmRunLivenessRecord -TaskId 'alpha' -State 'processes' -Detail '2 live process(es)' -ProcessId @(7, 9)
        $line = Format-FmTaskRunLiveness -Liveness $record
        $line | Should -BeLike 'liveness: processes*'
        $line | Should -Match 'task: alpha'
        $line | Should -Match 'pids: 7, 9'
    }

    It 'omits the pid field when there are none' {
        $line = Format-FmTaskRunLiveness -Liveness (New-FmRunLivenessRecord -TaskId 'alpha' -State 'none' -Detail 'nothing')
        $line | Should -Not -Match 'pids:'
    }
}

Describe 'bin/fm-run-liveness.ps1' {
    BeforeAll {
        $script:Entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin' 'fm-run-liveness.ps1'
    }

    It 'exits 2 on a usage error and says so on stderr' {
        $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.err')
        try {
            $null = pwsh -NoProfile -File $script:Entry 2>$errFile
            $LASTEXITCODE | Should -Be 2
            (Get-Content -Raw -LiteralPath $errFile) | Should -Match 'usage: fm-run-liveness'
        }
        finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    }

    It 'exits 0 and prints an answered reading for a task it knows nothing about' {
        # `unknown` is an answered reading, not a failure: the caller must be able
        # to tell "no information" from "the command broke".
        $out = pwsh -NoProfile -File $script:Entry 'no-such-task-here'
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'liveness: unknown'
    }
}
