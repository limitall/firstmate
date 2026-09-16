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
        <# CpuMs is added ONLY when a test asks for it, so every existing
           fabricated table keeps exercising the no-CPU-column path - the one a
           real caller hits when it hands in a table of its own. #>
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [int]$ParentProcessId = 0,
            [string]$Name = 'pwsh.exe',
            [string]$ExecutablePath = '',
            [string]$CommandLine = '',
            [AllowNull()][System.Nullable[double]]$CpuMs = $null
        )
        $row = [pscustomobject]@{
            ProcessId       = $ProcessId
            ParentProcessId = $ParentProcessId
            Name            = $Name
            ExecutablePath  = $ExecutablePath
            CommandLine     = $CommandLine
        }
        if ($null -ne $CpuMs) { $row | Add-Member -NotePropertyName 'CpuMs' -NotePropertyValue ([double]$CpuMs) }
        return $row
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

    It 'names the activity separately from the state, so the two are not conflated' {
        foreach ($activity in @('advancing', 'unobserved')) {
            $record = New-FmRunLivenessRecord -TaskId 'alpha' -State 'processes' -Detail '1 live process(es)' `
                -ProcessId @(7) -Activity $activity -ActivityDetail 'what was measured'
            $line = Format-FmTaskRunLiveness -Liveness $record
            $line | Should -BeLike 'liveness: processes*'
            $line | Should -Match "activity: $activity"
            $line | Should -Match 'what was measured'
        }
    }

    It 'omits the activity field when movement was never measured' {
        # An `unknown` clause on every line would be noise, and the state field
        # already carries the answer that governs what a supervisor does.
        $record = New-FmRunLivenessRecord -TaskId 'alpha' -State 'processes' -Detail '1 live process(es)' -ProcessId @(7)
        (Format-FmTaskRunLiveness -Liveness $record) | Should -Not -Match 'activity:'
    }

    It 'formats a record that predates the activity fields instead of throwing on them' {
        # StrictMode throws on a missing property, and this takes whatever record
        # a caller hands it - including one built before the fields existed.
        $bare = [pscustomobject]@{ TaskId = 'alpha'; State = 'processes'; ProcessId = @(7); Detail = 'd' }
        { Format-FmTaskRunLiveness -Liveness $bare } | Should -Not -Throw
        (Format-FmTaskRunLiveness -Liveness $bare) | Should -Not -Match 'activity:'

        $half = [pscustomobject]@{ TaskId = 'alpha'; State = 'processes'; ProcessId = @(7); Detail = 'd'; Activity = 'advancing' }
        { Format-FmTaskRunLiveness -Liveness $half } | Should -Not -Throw
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

Describe 'the activity reading answers only the positive' {
    <#
        The dimension is deliberately unable to say "stalled", so these tests are
        weighted the opposite way to the liveness ones above: `advancing` is
        asserted only where movement was positively measured, and every gap,
        missing column and unreadable sample lands on `unknown` rather than on a
        verdict. `unobserved` is asserted to be reachable AND to be worded as a
        non-verdict, because the whole risk here is a reader shortening it to
        "the run has stopped".
    #>
    BeforeAll {
        # A table whose work process carries a CPU total the test chooses.
        function New-ActivityTable {
            param([Parameter(Mandatory)][double]$Cpu, [int]$WorkId = 300)
            return @(
                New-Row -ProcessId 100 -ParentProcessId 1 -CpuMs 10 -CommandLine "pwsh -Command `"$($script:Task.Brief)`""
                New-Row -ProcessId $WorkId -ParentProcessId 100 -CpuMs $Cpu -CommandLine 'the run'
            )
        }

        function Set-Sample {
            param([Parameter(Mandatory)][int]$AgoSecs, [Parameter(Mandatory)][double]$Cpu, [string]$Ids = '300')
            Set-FmFileTextLf -Path (Join-Path $script:State '.run-activity-act') `
                -Text ("{0} {1:F0} {2}`n" -f ((Get-FmUnixTime) - $AgoSecs), $Cpu, $Ids)
        }

        function Get-Reading {
            return Get-FmTaskRunLiveness -TaskId 'act' -StatePath $script:State -DataPath $script:Data -Table (New-ActivityTable -Cpu $script:Cpu)
        }
    }
    AfterAll {
        foreach ($n in @('New-ActivityTable', 'Set-Sample', 'Get-Reading')) {
            Remove-Item -Path "function:$n" -ErrorAction SilentlyContinue
        }
    }
    BeforeEach {
        $script:FmHome = New-LivenessHome
        $script:State = Join-Path $script:FmHome 'state'
        $script:Data = Join-Path $script:FmHome 'data'
        $script:Task = New-LivenessTask -FmHome $script:FmHome -TaskId 'act' -Harness 'none'
    }
    AfterEach {
        Remove-Item -LiteralPath $script:FmHome -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'says unknown on the first look, because there is nothing to compare against' {
        $script:Cpu = 5000
        $reading = Get-Reading
        $reading.State | Should -Be 'processes'
        $reading.Activity | Should -Be 'unknown'
        $reading.ActivityDetail | Should -Match 'first look'
    }

    It 'records that first look so the next one can compare' {
        $script:Cpu = 5000
        $null = Get-Reading
        $sample = Read-FmRunActivitySample -Path (Join-Path $script:State '.run-activity-act')
        $sample | Should -Not -BeNullOrEmpty
        $sample.CpuMs | Should -Be 5000
        @($sample.ProcessId) | Should -Be @(300)
    }

    It 'says advancing when CPU was burned since the last look' {
        Set-Sample -AgoSecs 120 -Cpu 5000
        $script:Cpu = 9000
        $reading = Get-Reading
        $reading.Activity | Should -Be 'advancing'
        $reading.ActivityDetail | Should -Match 'burned 4\.0s of CPU in the last 120s'
    }

    It 'says advancing when the process set changed, even with no CPU burned at all' {
        # A per-file test runner spends its life here: each file is a new pid and
        # the parent burns nothing while it waits.
        Set-Sample -AgoSecs 120 -Cpu 5000 -Ids '300,999'
        $script:Cpu = 5000
        $reading = Get-Reading
        $reading.Activity | Should -Be 'advancing'
        $reading.ActivityDetail | Should -Match 'set of live processes changed'
    }

    It 'says unobserved when nothing moved, and says so as a non-verdict' {
        Set-Sample -AgoSecs 120 -Cpu 5000
        $script:Cpu = 5000
        $reading = Get-Reading
        $reading.Activity | Should -Be 'unobserved'
        # The wording is load-bearing: this is the reading that a supervisor is
        # most tempted to act on, and it is the one that licenses nothing.
        $reading.ActivityDetail | Should -Match 'does NOT mean it is stalled'
        $reading.ActivityDetail | Should -Match 'awaiting a network reply'
        # And the run is still reported as live, which is what governs behaviour.
        $reading.State | Should -Be 'processes'
    }

    It 'treats CPU movement under the noise floor as unobserved rather than advancing' {
        Set-Sample -AgoSecs 120 -Cpu 5000
        $script:Cpu = 5010
        (Get-Reading).Activity | Should -Be 'unobserved'
    }

    It 'scales the floor with the window, so a long quiet window cannot be tick noise' {
        # A settled idle process burns up to one scheduler tick a minute, so a
        # FIXED floor would eventually be cleared by housekeeping alone on a long
        # enough window. 250 ms over 600 s is under the floor; over 30 s it is not.
        Set-Sample -AgoSecs 600 -Cpu 5000
        $script:Cpu = 5250
        (Get-Reading).Activity | Should -Be 'unobserved'

        Set-Sample -AgoSecs 40 -Cpu 5000
        $script:Cpu = 5250
        (Get-Reading).Activity | Should -Be 'advancing'
    }

    It 'says unknown when the gap is too short to read movement from' {
        # Two looks seconds apart say nothing about a run: it can sit between two
        # scheduler slices. Answering `unobserved` there would be manufactured.
        Set-Sample -AgoSecs 2 -Cpu 5000
        $script:Cpu = 5000
        $reading = Get-Reading
        $reading.Activity | Should -Be 'unknown'
        $reading.ActivityDetail | Should -Match 'too short'
    }

    It 'leaves the baseline alone on a too-short gap, so frequent looks still reach an answer' {
        # Rewriting the sample on every look would mean anything polling faster
        # than the minimum gap - a supervisor running fm-crew-state a few times a
        # minute - reset the window forever and never got an answer at all.
        Set-Sample -AgoSecs 5 -Cpu 5000
        $before = Read-FmRunActivitySample -Path (Join-Path $script:State '.run-activity-act')
        $script:Cpu = 9000
        (Get-Reading).Activity | Should -Be 'unknown'
        $after = Read-FmRunActivitySample -Path (Join-Path $script:State '.run-activity-act')
        $after.Time | Should -Be $before.Time
        $after.CpuMs | Should -Be 5000
    }

    It 'restarts the baseline when the recorded sample is dated in the future' {
        # A clock correction, or a sample carried in from another home. Measuring
        # against it would produce a negative window.
        Set-Sample -AgoSecs -600 -Cpu 5000
        $script:Cpu = 9000
        $reading = Get-Reading
        $reading.Activity | Should -Be 'unknown'
        $reading.ActivityDetail | Should -Match 'dated in the future'
        [long](Read-FmRunActivitySample -Path (Join-Path $script:State '.run-activity-act')).Time |
            Should -BeLessOrEqual (Get-FmUnixTime)
    }

    It 'says unknown when the table carries no CPU column at all' {
        # The shape every caller that fabricates its own table hands in. A missing
        # column must never read as CPU that was not burned.
        Set-Sample -AgoSecs 120 -Cpu 5000
        $table = @(
            New-Row -ProcessId 100 -ParentProcessId 1 -CommandLine "pwsh -Command `"$($script:Task.Brief)`""
            New-Row -ProcessId 300 -ParentProcessId 100 -CommandLine 'the run'
        )
        $reading = Get-FmTaskRunLiveness -TaskId 'act' -StatePath $script:State -DataPath $script:Data -Table $table
        $reading.State | Should -Be 'processes'
        $reading.Activity | Should -Be 'unknown'
        $reading.ActivityDetail | Should -Match 'no CPU time'
    }

    It 'does not overwrite a usable sample with one it could not measure' {
        # Otherwise a single caller passing a CPU-less table would blind the
        # watcher's next real reading too.
        Set-Sample -AgoSecs 120 -Cpu 5000
        $table = @(
            New-Row -ProcessId 100 -ParentProcessId 1 -CommandLine "pwsh -Command `"$($script:Task.Brief)`""
            New-Row -ProcessId 300 -ParentProcessId 100 -CommandLine 'the run'
        )
        $null = Get-FmTaskRunLiveness -TaskId 'act' -StatePath $script:State -DataPath $script:Data -Table $table
        (Read-FmRunActivitySample -Path (Join-Path $script:State '.run-activity-act')).CpuMs | Should -Be 5000
    }

    It 'says unknown on an unreadable sample instead of treating it as a zero baseline' {
        # A zero baseline would make the next reading claim the run burned its
        # whole lifetime's CPU in one window - a fabricated `advancing`.
        Set-FmFileTextLf -Path (Join-Path $script:State '.run-activity-act') -Text "not a sample`n"
        $script:Cpu = 5000
        (Get-Reading).Activity | Should -Be 'unknown'
    }

    It 'drops the sample once the task has no work left, so a later run starts clean' {
        Set-Sample -AgoSecs 120 -Cpu 5000
        $table = @(New-Row -ProcessId 100 -ParentProcessId 1 -CpuMs 10 -CommandLine "pwsh -Command `"$($script:Task.Brief)`"")
        (Get-FmTaskRunLiveness -TaskId 'act' -StatePath $script:State -DataPath $script:Data -Table $table).State | Should -Be 'none'
        [System.IO.File]::Exists((Join-Path $script:State '.run-activity-act')) | Should -BeFalse
    }

    It 'carries an activity of unknown on every verdict that never measured movement' {
        # StrictMode: a caller reading .Activity must always find it.
        foreach ($id in @('act', 'no-such-task')) {
            $reading = Get-FmTaskRunLiveness -TaskId $id -StatePath $script:State -DataPath $script:Data -Table @()
            $reading.PSObject.Properties.Name | Should -Contain 'Activity'
            $reading.Activity | Should -Be 'unknown'
        }
    }
}

Describe 'the activity reading against a REAL process' {
    <#
        The fabricated tables above prove the decision procedure. This proves the
        thing a fabricated table cannot: that Win32_Process on this machine
        actually reports CPU that MOVES for a working process and stands still
        for an idle one. If that stopped being true the whole dimension would be
        silently useless, and every test above would still pass.
    #>
    It 'reads rising CPU for a busy process and a flat total for an idle one' {
        $busy = $null
        $idle = $null
        try {
            $busy = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-Command', 'Set-StrictMode -Version Latest; $x=0.0; while($true){ $x += [math]::Sqrt($x+1) }')
            $idle = Start-Process -FilePath 'pwsh' -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-NonInteractive', '-Command', 'Set-StrictMode -Version Latest; Start-Sleep -Seconds 120')
            # pwsh takes about 10s to settle: measured, an idle process still
            # burns ~300ms in a window opened 5s after launch and 0-15.6ms in one
            # opened at 10s. Sampling earlier reads startup as work.
            Start-Sleep -Seconds 12

            function Get-Cpu {
                param([int]$Id)
                $row = @(Get-FmRunLivenessProcessTable) | Where-Object { $_.ProcessId -eq $Id }
                if (-not $row) { return $null }
                return (Get-FmRunLivenessRowCpuMs -Row @($row)[0])
            }
            $busyBefore = Get-Cpu -Id $busy.Id
            $idleBefore = Get-Cpu -Id $idle.Id
            $busyBefore | Should -Not -BeNullOrEmpty
            $idleBefore | Should -Not -BeNullOrEmpty
            Start-Sleep -Seconds 6

            # Measured margins, not guesses: a spinning process burns about
            # 900ms per 6s, a settled idle one 0-15.6ms per MINUTE. The bounds sit
            # far either side of that gap so the test is not a coin flip.
            ((Get-Cpu -Id $busy.Id) - $busyBefore) | Should -BeGreaterThan 300
            ((Get-Cpu -Id $idle.Id) - $idleBefore) | Should -BeLessThan 100
        }
        finally {
            foreach ($p in @($busy, $idle)) {
                if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}
