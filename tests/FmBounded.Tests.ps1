#requires -Version 7.0
<#
    Pester tests for bounded execution and the watcher's check seam.

    Two properties carry the weight here, and both are tested from the failing
    side as well as the passing one:

      * the bound is HARD - exit 124 means the bound was hit, the process is
        gone, and so is everything it spawned;
      * a check runs only when something authenticated it. Every other path is a
        refusal WITHOUT EXECUTION, and each refusal below proves the check never
        ran by watching for a canary the check would have written.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }

    function New-TestHome {
        $fmHome = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-bounded-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fmHome 'state') -Force
        $env:FM_ROOT_OVERRIDE = $fmHome
        $env:FM_HOME = $fmHome
        $env:FM_STATE_OVERRIDE = (Join-Path $fmHome 'state')
        $env:FM_CHECK_INTERVAL = '0'
        $env:FM_SIGNAL_GRACE = '0'
        $env:FM_HEARTBEAT = '999999'
        return $fmHome
    }

    function Remove-TestHome {
        param($Path)
        foreach ($name in @('FM_ROOT_OVERRIDE', 'FM_HOME', 'FM_STATE_OVERRIDE', 'FM_CHECK_INTERVAL',
                'FM_SIGNAL_GRACE', 'FM_HEARTBEAT', 'FM_BOUNDED_FORCE_FALLBACK', 'FM_POLL')) {
            Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue
        }
        if ($Path -and (Test-Path -LiteralPath $Path)) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-FmBoundedCommand' {
    It 'returns the command own exit code and output when it finishes in time' {
        $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', 'Write-Output hello; exit 3') -TimeoutSeconds 60
        $r.ExitCode | Should -Be 3
        $r.StdOut.Trim() | Should -Be 'hello'
        $r.TimedOut | Should -BeFalse
    }

    It 'keeps stderr separate from stdout' {
        $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', '[Console]::Error.WriteLine("boom"); Write-Output fine') -TimeoutSeconds 60
        $r.StdOut.Trim() | Should -Be 'fine'
        $r.StdErr.Trim() | Should -Be 'boom'
    }

    It 'reports exit 124 - and only 124 - when the bound is hit' {
        $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 2
        $r.ExitCode | Should -Be 124
        $r.TimedOut | Should -BeTrue
    }

    It 'kills what the bounded command spawned, not just the command' {
        # The guarantee the bash process group gave and the job object gives
        # here: a grandchild cannot outlive the bound.
        $home_ = New-TestHome
        try {
            $survivor = Join-Path $home_ 'grandchild-survived'
            $child = Join-Path $home_ 'child.ps1'
            Set-FmFileTextLf -Path $child -Text @"
Start-Process -FilePath '$($script:Pwsh)' -ArgumentList '-NoProfile','-Command',"Start-Sleep -Seconds 6; Set-Content -LiteralPath '$survivor' -Value alive"
Start-Sleep -Seconds 60
"@
            $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
                -ArgumentList @('-NoProfile', '-File', $child) -TimeoutSeconds 2
            $r.ExitCode | Should -Be 124

            Start-Sleep -Seconds 9
            [System.IO.File]::Exists($survivor) | Should -BeFalse -Because 'the bound must take the whole tree with it'
        }
        finally { Remove-TestHome -Path $home_ }
    }

    It 'refuses a non-positive bound, because that is not a bound' {
        foreach ($budget in @(0, -5)) {
            $r = Invoke-FmBoundedCommand -FilePath 'anything' -TimeoutSeconds $budget
            $r.ExitCode | Should -Be 124
            $r.Mechanism | Should -Be 'refused'
            $r.StdErr | Should -Match 'not a bound'
        }
    }

    It 'reports a missing binary instead of throwing' {
        $r = Invoke-FmBoundedCommand -FilePath 'fm-no-such-binary-anywhere' -TimeoutSeconds 5
        $r.ExitCode | Should -Be 127
        $r.StdErr | Should -Match 'could not start'
        $r.TimedOut | Should -BeFalse
    }

    It 'names the mechanism it used, so a Windows job object and the fallback are distinguishable' {
        $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
            -ArgumentList @('-NoProfile', '-Command', 'exit 0') -TimeoutSeconds 60
        if ($IsWindows) { $r.Mechanism | Should -Be 'job-object' } else { $r.Mechanism | Should -Be 'process-tree' }
    }

    It 'still bounds through the fallback when job objects are unavailable' {
        # The Windows shim is not the guarantee, only the strongest way to keep
        # it: with job objects forced off, the bound still holds.
        $env:FM_BOUNDED_FORCE_FALLBACK = '1'
        try {
            Test-FmJobObjectSupport | Should -BeFalse
            $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
                -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 2
            $r.Mechanism | Should -Be 'process-tree'
            $r.ExitCode | Should -Be 124
        }
        finally { Remove-Item -Path 'env:FM_BOUNDED_FORCE_FALLBACK' -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-FmValidatedCheck refusals' {
    BeforeEach { $script:TestHome = New-TestHome; $script:State = Join-Path $script:TestHome 'state' }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'refuses a bash check outright: this port has no bash and never invents one' {
        $canary = Join-Path $script:State 'canary'
        $check = Join-Path $script:State 'alpha.check.sh'
        Set-FmFileTextLf -Path $check -Text "#!/bin/sh`ntouch '$canary'`n"

        $r = Invoke-FmValidatedCheck $check $script:State 10
        $r.Authorized | Should -BeFalse
        $r.Reason | Should -Be 'not a .check.ps1'
        [System.IO.File]::Exists($canary) | Should -BeFalse
    }

    It 'refuses a .check.ps1 that no registry authenticates, without executing it' {
        $canary = Join-Path $script:State 'canary'
        $check = Join-Path $script:State 'alpha.check.ps1'
        Set-FmFileTextLf -Path $check -Text "Set-Content -LiteralPath '$canary' -Value ran`n"

        $r = Invoke-FmValidatedCheck $check $script:State 10
        $r.Authorized | Should -BeFalse
        $r.Reason | Should -Match 'no registry entry authenticates'
        [System.IO.File]::Exists($canary) | Should -BeFalse
    }

    It 'refuses a check that lives outside the state directory' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $outside = Join-Path $script:TestHome 'elsewhere.check.ps1'
        Set-FmFileTextLf -Path $outside -Text "Write-Output nope`n"

        $r = Invoke-FmValidatedCheck $outside $script:State 10
        $r.Authorized | Should -BeFalse
        $r.Reason | Should -Match 'not directly inside the state directory'
    }

    It 'refuses a check that is a link, because a link points somewhere nobody authenticated' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $real = Join-Path $script:TestHome 'real.ps1'
        Set-FmFileTextLf -Path $real -Text "Write-Output linked`n"
        $link = Join-Path $script:State 'linked.check.ps1'
        New-Item -ItemType SymbolicLink -Path $link -Target $real -ErrorAction SilentlyContinue | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'symlinks are not available here' }

        $r = Invoke-FmValidatedCheck $link $script:State 10
        $r.Authorized | Should -BeFalse
        $r.Reason | Should -Match 'may not be a link'
    }

    It 'refuses a check that has since disappeared' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $r = Invoke-FmValidatedCheck (Join-Path $script:State 'ghost.check.ps1') $script:State 10
        $r.Authorized | Should -BeFalse
        $r.Reason | Should -Be 'absent'
    }
}

Describe 'Invoke-FmValidatedCheck execution' {
    BeforeEach { $script:TestHome = New-TestHome; $script:State = Join-Path $script:TestHome 'state' }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'runs an authenticated check and returns its output' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $check = Join-Path $script:State 'alpha.check.ps1'
        Set-FmFileTextLf -Path $check -Text "Write-Output merged`n"

        $r = Invoke-FmValidatedCheck $check $script:State 30
        $r.Authorized | Should -BeTrue
        $r.Output | Should -Be 'merged'
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be 0
    }

    It 'executes a private snapshot, never the authenticated file itself' {
        # The window between "this file was authenticated" and "this file ran" is
        # where a swap would land, so what runs is a copy taken under the hash.
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $check = Join-Path $script:State 'alpha.check.ps1'
        Set-FmFileTextLf -Path $check -Text "Write-Output `$PSCommandPath`n"

        $r = Invoke-FmValidatedCheck $check $script:State 30
        $r.Authorized | Should -BeTrue
        $r.Output | Should -Not -Be $check
        $r.Output | Should -BeLike '*.fm-check-snapshot.*'
        # ...and the snapshot does not outlive the run.
        @(Get-ChildItem -Path $script:State -Filter '.fm-check-snapshot.*' -Force).Count | Should -Be 0
    }

    It 'kills a check that outruns its bound and reports the 124 convention' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $check = Join-Path $script:State 'slow.check.ps1'
        Set-FmFileTextLf -Path $check -Text "Start-Sleep -Seconds 60`n"

        $r = Invoke-FmValidatedCheck $check $script:State 2
        $r.Authorized | Should -BeTrue
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be 124
        # No output means no wake, exactly as in bash - so the timeout is
        # recorded where a silent one can still be found.
        $r.Output | Should -Be ''
        (Get-FmFileTextOrEmpty -Path (Join-Path $script:State '.watch-triage.log')) |
            Should -Match 'check hit its 2s bound and was killed with its whole tree \(exit 124\)'
    }

    It 'reports a check that says nothing as authorized with no output' {
        function Test-FmCheckRegistered { param($Path, $State) $true }
        $check = Join-Path $script:State 'quiet.check.ps1'
        Set-FmFileTextLf -Path $check -Text "exit 0`n"

        $r = Invoke-FmValidatedCheck $check $script:State 30
        $r.Authorized | Should -BeTrue
        $r.Output | Should -Be ''
    }
}

Describe 'the watcher check sweep' {
    BeforeEach { $script:TestHome = New-TestHome; $script:Ctx = Get-FmWakeContext }
    AfterEach { Remove-TestHome -Path $script:TestHome }

    It 'enumerates a .check.ps1 and refuses it while no registry authenticates it' {
        # Before this area, a .check.ps1 was not enumerated at all: the sweep
        # looked only for .check.sh, so a Windows check was invisible rather
        # than refused. Invisible is the one outcome a fail-closed sweep must
        # never have.
        $canary = Join-Path $script:Ctx.State 'canary'
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.check.ps1') `
            -Text "Set-Content -LiteralPath '$canary' -Value ran`n"

        $script = Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1'
        $out = @(pwsh -NoProfile -File $script -MaxCycles 1 -SkipTerminalWait 2>$null)

        ($out -join "`n") | Should -BeLike '*check: rejected unauthenticated state checks:*alpha.check.ps1*'
        [System.IO.File]::Exists($canary) | Should -BeFalse
        @(Get-FmWakeQueueLines -Path $script:Ctx.Queue)[0] | Should -Match "\tcheck\tunauthenticated-state-checks\t"
    }

    It 'still refuses a .check.sh in the same sweep' {
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'legacy.check.sh') -Text "#!/bin/sh`necho merged`n"
        Set-FmFileTextLf -Path (Join-Path $script:Ctx.State 'alpha.check.ps1') -Text "Write-Output x`n"

        $script = Join-Path $script:RepoRoot 'bin' 'fm-watch.ps1'
        $out = @(pwsh -NoProfile -File $script -MaxCycles 1 -SkipTerminalWait 2>$null)

        ($out -join "`n") | Should -BeLike '*legacy.check.sh*'
        ($out -join "`n") | Should -BeLike '*alpha.check.ps1*'
    }
}
