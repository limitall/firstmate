#requires -Version 7.0
# Pester tests for the task dispatch surface: the delivery contract, harness and
# profile resolution, the task record, and the status stream's keyed fold.
#
# Two things here are not ordinary unit tests and are marked where they appear:
#   - the isolation PROOF, which builds a real git repository, hands the spawn a
#     "leased" worktree that IS the primary checkout, and shows the spawn stops
#     before any endpoint exists;
#   - the entry-point tests, which run bin/fm-brief.ps1 and bin/fm-spawn.ps1 as
#     real child processes and assert their exit codes and stderr, because that
#     is the surface a caller actually sees.
# Nothing here starts a real herdr server, a real treehouse pool, or a real agent.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function Reset-DispatchEnvironment {
        foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE',
                'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_CLASSIFY_PAUSED_VERB',
                'FM_CLASSIFY_RESOLVE_VERB', 'FM_CLASSIFY_CAPTAIN_HELD_VERB',
                'FM_CLASSIFY_RESERVED_KEY_PREFIXES', 'FM_CAPTAIN_RE')) {
            Set-Item -Path "env:$name" -Value $null
        }
    }

    function New-DispatchHome {
        Reset-DispatchEnvironment
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'config')) {
            New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null
        }
        $dir
    }

    function New-StatusFile {
        param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)
        $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.status')
        [System.IO.File]::WriteAllText($path, (($Line -join "`n") + "`n"))
        $path
    }

    # A real git repository, so the isolation assertion runs against real
    # `git rev-parse --show-toplevel` output rather than a mock of it.
    function New-GitRepo {
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $Path)
        foreach ($argv in @(
                @('config', 'user.email', 'test@example.invalid'),
                @('config', 'user.name', 'test'),
                @('commit', '-q', '--allow-empty', '-m', 'root'))) {
            $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList (@('-C', $Path) + $argv)
        }
        $Path
    }

    # Run one of the bin/ entry points as a real child process and report its
    # exit code with both streams.
    function Invoke-FmEntryPoint {
        param(
            [Parameter(Mandatory)][string]$Script,
            [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
            [hashtable]$Environment = @{}
        )
        $pwshPath = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrEmpty($pwshPath)) { $pwshPath = 'pwsh' }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwshPath
        foreach ($argument in (@('-NoProfile', '-NonInteractive', '-File',
                    (Join-Path $script:RepoRoot 'bin' $Script)) + $Arguments)) {
            $psi.ArgumentList.Add($argument)
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        foreach ($key in $Environment.Keys) { $psi.Environment[$key] = [string]$Environment[$key] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = $stderr }
    }
}

# The module-assembly check - no function name defined twice across Private/ and
# Public/ - is tests/FmModuleAssembly.Tests.ps1's, and this area's own rebase is
# exactly what it catches: two of my parsers collided with Public/FmClassify.ps1
# and had to go. One owner per rule, so there is no second copy here.

Describe 'The operational-input wire form' {
    It 'encodes a launch brief with the permanent U+2063 prefix' {
        $encoded = ConvertTo-FmOperationalInput -Kind 'launch-brief' -Body 'do the thing'
        $encoded | Should -Be ([char]0x2063 + 'FIRSTMATE_OP: v1 launch-brief: do the thing')
    }

    It 'refuses an unknown kind and an empty body' {
        { ConvertTo-FmOperationalInput -Kind 'gossip' -Body 'x' } | Should -Throw '*not a current firstmate operational-input kind*'
        { ConvertTo-FmOperationalInput -Kind 'launch-brief' -Body '' } | Should -Throw '*needs a body*'
    }
}

Describe 'The delivery contract' {
    It 'requires both mode and yolo on a ship, and never invents either' {
        { Assert-FmDeliveryContract -Kind 'ship' -Mode '' -Yolo 'off' } | Should -Throw '*ship spawns require --mode*'
        { Assert-FmDeliveryContract -Kind 'ship' -Mode 'local-only' -Yolo '' } | Should -Throw '*ship spawns require --yolo*'
    }

    It 'refuses a registry policy used as a task mode' {
        { Assert-FmDeliveryContract -Kind 'ship' -Mode 'no-mistakes-prod-only' -Yolo 'off' } |
            Should -Throw '*registry policy, not a task mode*'
    }

    It 'refuses an unknown mode and an unknown yolo' {
        { Assert-FmDeliveryContract -Kind 'ship' -Mode 'whatever' -Yolo 'off' } |
            Should -Throw '*must be one of no-mistakes, direct-PR, local-only*'
        { Assert-FmDeliveryContract -Kind 'ship' -Mode 'local-only' -Yolo 'sometimes' } |
            Should -Throw '*must be on or off*'
    }

    It 'accepts every valid ship combination' {
        foreach ($mode in @('no-mistakes', 'direct-PR', 'local-only')) {
            foreach ($yolo in @('on', 'off')) {
                { Assert-FmDeliveryContract -Kind 'ship' -Mode $mode -Yolo $yolo } | Should -Not -Throw
            }
        }
    }

    It 'refuses a delivery contract on a kind that has none' {
        foreach ($kind in @('scout', 'secondmate')) {
            { Assert-FmDeliveryContract -Kind $kind -Mode 'local-only' -Yolo '' } |
                Should -Throw '*--mode applies only to ship spawns*'
            { Assert-FmDeliveryContract -Kind $kind -Mode '' -Yolo 'on' } |
                Should -Throw '*--yolo applies only to ship spawns*'
            { Assert-FmDeliveryContract -Kind $kind -Mode '' -Yolo '' } | Should -Not -Throw
        }
    }

    It 'ranks delivery rigor so a deviation from the standing posture can be noticed' {
        (Get-FmDeliveryRigorRank -Mode 'no-mistakes') | Should -BeGreaterThan (Get-FmDeliveryRigorRank -Mode 'direct-PR')
        (Get-FmDeliveryRigorRank -Mode 'direct-PR') | Should -BeGreaterThan (Get-FmDeliveryRigorRank -Mode 'local-only')
        (Get-FmDeliveryRigorRank -Mode 'no-mistakes-prod-only') | Should -Be 0
    }
}

Describe 'Brief and spawn must agree on delivery' {
    BeforeEach {
        $script:briefFile = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($script:briefFile, "# brief`nDelivery contract: mode=local-only`nmore`n")
    }

    It 'reads the recorded contract line' {
        Get-FmBriefDeliveryMode -Path $script:briefFile | Should -Be 'local-only'
    }

    It 'accepts agreement and refuses a mismatch' {
        { Assert-FmBriefDeliveryAgreement -TaskId 't' -BriefPath $script:briefFile -Mode 'local-only' } |
            Should -Not -Throw
        { Assert-FmBriefDeliveryAgreement -TaskId 't' -BriefPath $script:briefFile -Mode 'direct-PR' } |
            Should -Throw '*delivery mismatch for t*'
    }

    It 'warns once and launches when the brief predates the contract line' {
        $old = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($old, "# brief`n")
        $warnings = @()
        Assert-FmBriefDeliveryAgreement -TaskId 't' -BriefPath $old -Mode 'direct-PR' `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 1
        [string]$warnings[0] | Should -BeLike '*records no delivery contract line*'
    }
}

Describe 'Harness adapters' {
    It 'knows claude as verified and every other adapter as known but unverified' {
        (Get-FmHarnessAdapter -Harness 'claude').Verified | Should -BeTrue
        foreach ($name in @('codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'muse')) {
            (Get-FmHarnessAdapter -Harness $name).Verified | Should -BeFalse
        }
        Get-FmHarnessAdapter -Harness 'nonesuch' | Should -BeNullOrEmpty
    }

    It 'refuses an unknown harness and names the escape hatch' {
        { Get-FmHarnessLaunchCommand -Harness 'nonesuch' -BriefPath 'b.md' } |
            Should -Throw '*unknown harness*raw launch command*'
    }

    It 'refuses an unverified adapter instead of silently choosing another' {
        { Get-FmHarnessLaunchCommand -Harness 'codex' -BriefPath 'b.md' } |
            Should -Throw "*no verified launch adapter*"
    }

    It 'refuses before an endpoint exists when the executable is missing' {
        # A pane opened onto a shell error looks to supervision like a wedged
        # worker, not a missing dependency, so this must fail closed first.
        Mock Get-Command { $null } -ParameterFilter { $CommandType -contains 'Application' }
        { Assert-FmHarnessExecutable -Harness 'claude' } | Should -Throw "*'claude' executable was not found on PATH*"
    }

    Context 'the launch command' {
        BeforeEach { Mock Assert-FmHarnessExecutable { 'C:\tools\claude.exe' } }

        It 'has the pane read the brief itself rather than typing it' {
            $launch = Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath 'C:\fm\data\t\brief.md'
            $launch | Should -Match ([regex]::Escape("Get-Content -Raw -LiteralPath 'C:\fm\data\t\brief.md'"))
            $launch | Should -Match ([regex]::Escape([char]0x2063 + 'FIRSTMATE_OP: v1 launch-brief: '))
            $launch | Should -Match ([regex]::Escape('--dangerously-skip-permissions'))
        }

        It 'quotes a path containing a quote instead of breaking out of the string' {
            $launch = Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath "C:\it's\brief.md"
            $launch | Should -Match ([regex]::Escape("'C:\it''s\brief.md'"))
        }

        It 'threads model and effort only where the axis is verified' {
            $both = Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath 'b.md' -Model 'opus' -Effort 'high'
            $both | Should -Match ([regex]::Escape("--model 'opus'"))
            $both | Should -Match ([regex]::Escape("--effort 'high'"))

            $default = Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath 'b.md' -Model 'default' -Effort 'default'
            $default | Should -Not -Match '--model'
            $default | Should -Not -Match '--effort'
        }

        It 'omits an effort level the adapter was never verified to accept' {
            Get-FmHarnessEffortFlag -Harness 'claude' -Effort 'ultra' | Should -Be ''
            Get-FmHarnessEffortFlag -Harness 'claude' -Effort 'max' | Should -Be "--effort 'max' "
            # An unverified adapter never receives an axis at all.
            Get-FmHarnessModelFlag -Harness 'nonesuch' -Model 'opus' | Should -Be ''
        }

        It 'disables the predicted-prompt ghost text every launch' {
            Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath 'b.md' |
                Should -Match ([regex]::Escape("`$env:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false'"))
        }

        It "forwards firstmate's own claude store, which a herdr-created pane does not inherit" {
            $env:CLAUDE_CONFIG_DIR = 'C:\work\claude'
            try {
                Get-FmHarnessLaunchCommand -Harness 'claude' -BriefPath 'b.md' |
                    Should -Match ([regex]::Escape("`$env:CLAUDE_CONFIG_DIR='C:\work\claude'"))
            } finally {
                $env:CLAUDE_CONFIG_DIR = $null
            }
        }
    }
}

Describe 'Harness resolution from config' {
    BeforeEach {
        $script:dispatchHome = New-DispatchHome
        $script:configDir = Join-Path $script:dispatchHome 'config'
    }

    It 'uses config/crew-harness for a crewmate' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'crew-harness'), "codex`n")
        $resolved = Get-FmConfiguredHarness -ConfigDir $script:configDir -Kind 'ship'
        $resolved.Harness | Should -Be 'codex'
        $resolved.Source | Should -Be 'config/crew-harness'
    }

    It 'refuses to resolve a crewmate harness while a dispatch profile is active' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'crew-dispatch.json'), "{}`n")
        { Get-FmConfiguredHarness -ConfigDir $script:configDir -Kind 'ship' } |
            Should -Throw '*crew-dispatch.json is active*'
    }

    It 'lets a secondmate resolve past an active dispatch profile through its own chain' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'crew-dispatch.json'), "{}`n")
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'), "claude opus high`n")
        $resolved = Get-FmConfiguredHarness -ConfigDir $script:configDir -Kind 'secondmate'
        $resolved.Harness | Should -Be 'claude'
        $resolved.Source | Should -Be 'config/secondmate-harness'
    }

    It 'falls back secondmate-harness -> crew-harness -> own' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'), "default`n")
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'crew-harness'), "grok`n")
        (Get-FmConfiguredHarness -ConfigDir $script:configDir -Kind 'secondmate').Harness | Should -Be 'grok'

        Remove-Item -LiteralPath (Join-Path $script:configDir 'crew-harness')
        Mock Get-FmOwnHarness { 'claude' }
        (Get-FmConfiguredHarness -ConfigDir $script:configDir -Kind 'secondmate').Source | Should -Be 'own harness'
    }

    It 'reads the optional model and effort tokens only from secondmate-harness' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'),
            "# a comment`n`nclaude opus xhigh`n")
        Get-FmSecondmateHarnessToken -ConfigDir $script:configDir -Field 'Harness' | Should -Be 'claude'
        Get-FmSecondmateHarnessToken -ConfigDir $script:configDir -Field 'Model' | Should -Be 'opus'
        Get-FmSecondmateHarnessToken -ConfigDir $script:configDir -Field 'Effort' | Should -Be 'xhigh'
    }

    It 'reports no tokens for a bare harness line' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'), "claude`n")
        Get-FmSecondmateHarnessToken -ConfigDir $script:configDir -Field 'Model' | Should -Be ''
        Get-FmSecondmateHarnessToken -ConfigDir $script:configDir -Field 'Effort' | Should -Be ''
    }
}

Describe 'Resolve-FmSpawnPlan' {
    BeforeEach {
        $script:dispatchHome = New-DispatchHome
        $script:configDir = Join-Path $script:dispatchHome 'config'
        $script:planBrief = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($script:planBrief, "# brief`nDelivery contract: mode=local-only`n")
        Mock Assert-FmHarnessExecutable { 'claude' }
        Mock Write-FmDeliveryPostureNotice { }
    }

    It 'resolves harness, launch command, and the profile axes for a ship' {
        $plan = Resolve-FmSpawnPlan -TaskId 't' -Kind 'ship' -BriefPath $script:planBrief -Project '/proj' `
            -ConfigDir $script:configDir -Harness 'claude' -Mode 'local-only' -Yolo 'off' -Model 'opus' -Effort 'high'
        $plan.Harness | Should -Be 'claude'
        $plan.HarnessSource | Should -Be 'explicit'
        $plan.LaunchCommand | Should -Match ([regex]::Escape("--model 'opus'"))
    }

    It 'refuses the spawn when the brief and the flag disagree' {
        { Resolve-FmSpawnPlan -TaskId 't' -Kind 'ship' -BriefPath $script:planBrief -Project '/proj' `
                -ConfigDir $script:configDir -Harness 'claude' -Mode 'direct-PR' -Yolo 'off' } |
            Should -Throw '*delivery mismatch*'
    }

    It 'takes a raw launch command as the unverified-adapter escape hatch, deriving the harness name' {
        $plan = Resolve-FmSpawnPlan -TaskId 't' -Kind 'scout' -BriefPath $script:planBrief -Project '/proj' `
            -ConfigDir $script:configDir -LaunchCommand '$env:X=''1''; /usr/local/bin/codex --go'
        $plan.Harness | Should -Be 'codex'
        $plan.HarnessSource | Should -Be 'raw launch command'
        $plan.LaunchCommand | Should -Be '$env:X=''1''; /usr/local/bin/codex --go'
    }

    It 'applies the secondmate config tokens only when the harness came from that file' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'), "claude opus xhigh`n")
        $resolved = Resolve-FmSpawnPlan -TaskId 't' -Kind 'secondmate' -BriefPath $script:planBrief `
            -Project '/proj' -ConfigDir $script:configDir
        $resolved.Model | Should -Be 'opus'
        $resolved.Effort | Should -Be 'xhigh'

        $explicit = Resolve-FmSpawnPlan -TaskId 't' -Kind 'secondmate' -BriefPath $script:planBrief `
            -Project '/proj' -ConfigDir $script:configDir -Harness 'claude'
        $explicit.Model | Should -Be ''
        $explicit.Effort | Should -Be ''
    }

    It 'ignores an out-of-vocabulary effort token loudly, and lets an explicit flag win' {
        [System.IO.File]::WriteAllText((Join-Path $script:configDir 'secondmate-harness'), "claude opus turbo`n")
        $warnings = @()
        $plan = Resolve-FmSpawnPlan -TaskId 't' -Kind 'secondmate' -BriefPath $script:planBrief `
            -Project '/proj' -ConfigDir $script:configDir -Model 'sonnet' `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $plan.Effort | Should -Be ''
        $plan.Model | Should -Be 'sonnet'
        [string]$warnings[0] | Should -BeLike "*'turbo' is not one of low, medium, high, xhigh, max*"
    }
}

Describe 'The task record' {
    BeforeEach {
        $script:dispatchHome = New-DispatchHome
        $script:stateDir = Join-Path $script:dispatchHome 'state'
    }

    It 'writes the bash field set and order for a ship' {
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window 'default:w1:p5' -Worktree '/wt' -Project '/proj' `
            -Harness 'claude' -Kind 'ship' -Mode 'direct-PR' -Yolo 'on' -TaskTmp '/tmp/fm-t' -Model 'opus' `
            -Effort 'high' -Backend 'herdr' -HerdrSession 'default' -HerdrWorkspaceId 'w1' -HerdrTabId 't1' `
            -HerdrPaneId 'w1:p5' -LeaseId 'L-7'
        @($fields.Keys) | Should -Be @(
            'window', 'endpoint_task_id', 'worktree', 'project', 'harness', 'kind', 'mode', 'yolo',
            'tasktmp', 'model', 'effort', 'backend', 'herdr_session', 'herdr_workspace_id',
            'herdr_tab_id', 'herdr_pane_id', 'treehouse_lease_id')
    }

    It 'defaults model and effort rather than omitting them' {
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window 'w' -Worktree '/wt' -Project '/proj' `
            -Harness 'claude' -Kind 'scout' -TaskTmp '/tmp/fm-t'
        $fields['model'] | Should -Be 'default'
        $fields['effort'] | Should -Be 'default'
    }

    It 'omits backend for the default tmux, because absent backend= MEANS tmux' {
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window 'w' -Worktree '/wt' -Project '/proj' `
            -Harness 'claude' -Kind 'ship' -Mode 'local-only' -Yolo 'off' -TaskTmp '/tmp/fm-t' -Backend 'tmux'
        $fields.Contains('backend') | Should -BeFalse
        $fields.Contains('herdr_session') | Should -BeFalse
    }

    It 'records home and projects for a secondmate, and busy_gen when one is known' {
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window 'w' -Worktree '/wt' -Project '/homes/sm' `
            -Harness 'claude' -Kind 'secondmate' -TaskTmp '/tmp/fm-t' -Backend 'herdr' -HerdrSession 'default' `
            -HerdrWorkspaceId 'w1' -HerdrTabId 't1' -HerdrPaneId 'w1:p5' -ProjectList 'projects/a projects/b' `
            -BusyGeneration '3'
        $fields['home'] | Should -Be '/homes/sm'
        $fields['projects'] | Should -Be 'projects/a projects/b'
        @($fields.Keys) | Should -Be @(
            'window', 'endpoint_task_id', 'worktree', 'project', 'harness', 'kind', 'tasktmp',
            'model', 'effort', 'busy_gen', 'backend', 'herdr_session', 'herdr_workspace_id',
            'herdr_tab_id', 'herdr_pane_id', 'home', 'projects')
    }

    It 'publishes atomically with LF-only, BOM-free bytes' {
        $path = Join-Path $script:stateDir 't.meta'
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window 'w' -Worktree '/wt' -Project '/proj' `
            -Harness 'claude' -Kind 'scout' -TaskTmp '/tmp/fm-t'
        Write-FmTaskRecord -Path $path -Fields $fields -Confirm:$false
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes | Should -Not -Contain 13
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        @(Get-ChildItem -LiteralPath $script:stateDir -Force | Where-Object { $_.Name -like '*.tmp.*' }).Count |
            Should -Be 0
    }

    It 'publishes through the foundation, so a value that would corrupt the record is refused' {
        # Write-FmKeyValueFile is the owner of what a key=value record may hold;
        # this surface must not re-implement (or bypass) that check.
        $fields = ConvertTo-FmTaskRecordField -TaskId 't' -Window "one`ntwo" -Worktree '/wt' -Project '/proj' `
            -Harness 'claude' -Kind 'scout' -TaskTmp '/tmp/fm-t'
        { Write-FmTaskRecord -Path (Join-Path $script:stateDir 'bad.meta') -Fields $fields -Confirm:$false } |
            Should -Throw '*carriage return or line feed*'
    }

    It 'reads every field back, including the ones this port does not name' {
        $path = Join-Path $script:stateDir 't.meta'
        [System.IO.File]::WriteAllText($path, @(
                'window=default:w1:p5', 'endpoint_task_id=t', 'worktree=/wt', 'project=/proj',
                'harness=claude', 'kind=ship', 'mode=local-only', 'yolo=off', 'tasktmp=/tmp/fm-t',
                'model=opus', 'effort=high', 'backend=herdr', 'herdr_session=default',
                'herdr_workspace_id=w1', 'herdr_tab_id=t1', 'herdr_pane_id=w1:p5',
                'treehouse_lease_id=L-7', 'traceparent=00-abc-def-01', 'exotic=value') -join "`n")
        $record = Get-FmTaskRecord -Path $path
        $record.Window | Should -Be 'default:w1:p5'
        $record.Kind | Should -Be 'ship'
        $record.Mode | Should -Be 'local-only'
        $record.Backend | Should -Be 'herdr'
        $record.LeaseId | Should -Be 'L-7'
        $record.Traceparent | Should -Be '00-abc-def-01'
        $record.Field['exotic'] | Should -Be 'value'
    }

    It 'reports tmux for a record with no backend line, and nothing for a missing record' {
        $path = Join-Path $script:stateDir 'legacy.meta'
        [System.IO.File]::WriteAllText($path, "window=fm-legacy`nkind=ship`n")
        (Get-FmTaskRecord -Path $path).Backend | Should -Be 'tmux'
        Get-FmTaskRecord -Path (Join-Path $script:stateDir 'ghost.meta') | Should -BeNullOrEmpty
    }

    It 'tolerates a CRLF record an operator edited, and takes the last value per key' {
        $path = Join-Path $script:stateDir 'crlf.meta'
        [System.IO.File]::WriteAllText($path, "window=one`r`nwindow=two`r`nkind=scout`r`n")
        $record = Get-FmTaskRecord -Path $path
        $record.Window | Should -Be 'two'
        $record.Kind | Should -Be 'scout'
    }
}

Describe 'The status stream: appending' {
    BeforeEach {
        $script:dispatchHome = New-DispatchHome
        $script:stateDir = Join-Path $script:dispatchHome 'state'
    }

    It 'appends one LF-terminated event' {
        Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'working' -Note 'started' -Confirm:$false | Out-Null
        Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'done' -Note 'finished' -Confirm:$false | Out-Null
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:stateDir 't.status'))
        $raw | Should -Be "working: started`ndone: finished`n"
    }

    It 'writes the keyed grammar the fold reads' {
        Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'needs-decision' -Key 'api-shape' `
            -Note 'flat or nested' -Confirm:$false | Out-Null
        [System.IO.File]::ReadAllText((Join-Path $script:stateDir 't.status')) |
            Should -Be "needs-decision [key=api-shape]: flat or nested`n"
    }

    It 'refuses a key the fold could not parse, instead of writing a line that is silently dropped' {
        { Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'blocked' -Key 'bad key' `
                -Note 'x' -Confirm:$false } | Should -Throw '*not a valid decision key*'
    }

    It 'refuses a verb that would not parse as one' {
        { Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'needs decision' -Note 'x' -Confirm:$false } |
            Should -Throw '*is not a status verb*'
    }

    It 'flattens a multi-line note, because one append is exactly one event' {
        Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'blocked' -Note "line one`nline two" -Confirm:$false | Out-Null
        @([System.IO.File]::ReadAllLines((Join-Path $script:stateDir 't.status'))).Count | Should -Be 1
    }

    It 'appends through the foundation, whose append is lock-serialized' {
        # Not a style point: .NET's FileMode.Append writes at a remembered
        # offset, so an unlocked appender silently loses concurrent lines. The
        # foundation owns that lock; this surface must go through it.
        Mock Add-FmStateLine { }
        Add-FmTaskStatus -StateDir $script:stateDir -TaskId 't' -State 'working' -Note 'x' -Confirm:$false | Out-Null
        Should -Invoke Add-FmStateLine -Times 1 -ParameterFilter { $Line -eq 'working: x' }
    }

    It 'is the one owner: the backend area appends through it' {
        Add-FmStatusEvent -StateDir $script:stateDir -TaskId 't' -State 'working' -Note 'via the backend area'
        [System.IO.File]::ReadAllText((Join-Path $script:stateDir 't.status')) |
            Should -Be "working: via the backend area`n"
    }
}


Describe 'PROOF: a spawn whose resolved worktree IS the primary checkout stops' {
    BeforeEach {
        Reset-DispatchEnvironment
        $script:proofHome = New-DispatchHome
        $script:proofState = Join-Path $script:proofHome 'state'
        $script:primary = New-GitRepo -Path (Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName()))
        $script:proofBrief = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($script:proofBrief, "# brief`nDelivery contract: mode=local-only`n")

        # The pool hands back the PRIMARY CHECKOUT. Everything else on the spawn
        # path is real: the isolation assertion runs `git rev-parse
        # --show-toplevel` against a real repository and compares real resolved
        # paths.
        Mock New-FmWorktreeLease {
            [pscustomobject]@{ Path = $script:primary; LeaseId = 'L-9'; LeaseHolder = 'fm-proof'
                Name = 'pool-0'; Project = $script:primary }
        }
        Mock Remove-FmWorktreeLease { $true }
        Mock Update-FmWorktreeBase { throw 'the base must never be refreshed after a failed isolation check' }
        Mock New-FmHerdrContainer { throw 'no container may be created for a tangled spawn' }
        Mock New-FmHerdrTask { throw 'no endpoint may be created for a tangled spawn' }
        Mock Send-FmHerdrTextLine { throw 'no agent may be launched for a tangled spawn' }
        Mock Assert-FmHarnessExecutable { 'claude' }
    }

    It 'refuses at acquisition, naming both paths' {
        { New-FmIsolatedWorktree -Project $script:primary -LeaseHolder 'fm-proof' -Confirm:$false } |
            Should -Throw '*did not yield an isolated worktree*it IS the primary checkout*'
    }

    It 'stops the whole spawn: no endpoint, no record, and the lease released' {
        { Start-FmWorker -TaskId 'proof' -Project $script:primary -BriefPath $script:proofBrief `
                -Harness 'claude' -Mode 'local-only' -Yolo 'off' -FirstmateHome $script:proofHome -Confirm:$false } |
            Should -Throw '*refusing to launch to avoid tangling the primary checkout*'

        Should -Invoke New-FmHerdrContainer -Times 0
        Should -Invoke New-FmHerdrTask -Times 0
        Should -Invoke Send-FmHerdrTextLine -Times 0
        Should -Invoke Remove-FmWorktreeLease -Times 1 -ParameterFilter { $IfLeaseId -eq 'L-9' }
        Test-Path -LiteralPath (Join-Path $script:proofState 'proof.meta') | Should -BeFalse
    }

    It 'also refuses a subdirectory of the primary checkout, which is not a worktree root' {
        $inside = Join-Path $script:primary 'sub'
        New-Item -ItemType Directory -Path $inside -Force | Out-Null
        $verdict = Test-FmWorktreeIsolation -Worktree $inside -PrimaryCheckout $script:primary
        $verdict.Isolated | Should -BeFalse
        $verdict.Reason | Should -BeLike '*not a worktree root*'
    }

    It 'accepts a genuine second worktree of the same repository' {
        $other = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $added = Invoke-FmChildProcess -FilePath 'git' `
            -ArgumentList @('-C', $script:primary, 'worktree', 'add', '-q', '--detach', $other)
        $added.Ok | Should -BeTrue
        (Test-FmWorktreeIsolation -Worktree $other -PrimaryCheckout $script:primary).Isolated | Should -BeTrue
    }
}

Describe 'The entry points, run as real processes' {
    BeforeEach {
        Reset-DispatchEnvironment
        $script:cliHome = New-DispatchHome
        $script:cliProject = New-GitRepo -Path (Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName()))
    }

    It 'exits 2 with usage when the required positionals are missing' {
        $spawn = Invoke-FmEntryPoint -Script 'fm-spawn.ps1' -Arguments @() -Environment @{ FM_HOME = $script:cliHome }
        $spawn.ExitCode | Should -Be 2
        $spawn.StdErr | Should -BeLike '*usage: fm-spawn.ps1*'
    }

    It 'scaffolds a brief, then refuses the spawn whose mode contradicts it' {
        $env = @{ FM_HOME = $script:cliHome }
        # The brief entry point is the lifecycle area's and speaks the bash flag
        # spelling; the spawn has to agree with whatever it wrote.
        $scaffold = Invoke-FmEntryPoint -Script 'fm-brief.ps1' `
            -Arguments @('e2e', 'my-service', '--mode', 'local-only') -Environment $env
        $scaffold.ExitCode | Should -Be 0
        $briefPath = Join-Path $script:cliHome 'data' 'e2e' 'brief.md'
        Test-Path -LiteralPath $briefPath | Should -BeTrue

        $mismatch = Invoke-FmEntryPoint -Script 'fm-spawn.ps1' `
            -Arguments @('e2e', $script:cliProject, '-Mode', 'direct-PR', '-Yolo', 'off') -Environment $env
        $mismatch.ExitCode | Should -Be 1
        $mismatch.StdErr | Should -BeLike '*delivery mismatch for e2e*'
        # A refusal is a plain message, not a PowerShell error record.
        $mismatch.StdErr | Should -Not -BeLike '*At line*'
        Test-Path -LiteralPath (Join-Path $script:cliHome 'state' 'e2e.meta') | Should -BeFalse
    }

    It 'refuses a ship spawn that names no delivery mode' {
        $env = @{ FM_HOME = $script:cliHome }
        $null = Invoke-FmEntryPoint -Script 'fm-brief.ps1' `
            -Arguments @('nomode', 'my-service', '--mode', 'local-only') -Environment $env
        $spawn = Invoke-FmEntryPoint -Script 'fm-spawn.ps1' `
            -Arguments @('nomode', $script:cliProject) -Environment $env
        $spawn.ExitCode | Should -Be 1
        $spawn.StdErr | Should -BeLike '*ship spawns require --mode*'
    }

    It 'refuses a spawn whose brief was never scaffolded' {
        $spawn = Invoke-FmEntryPoint -Script 'fm-spawn.ps1' `
            -Arguments @('ghost', $script:cliProject, '-Mode', 'local-only', '-Yolo', 'off') `
            -Environment @{ FM_HOME = $script:cliHome }
        $spawn.ExitCode | Should -Be 1
        $spawn.StdErr | Should -BeLike '*never launched without its instructions*'
    }
}
