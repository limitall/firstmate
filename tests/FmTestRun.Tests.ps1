#requires -Version 7.0
# Pester tests for the per-file test runner and the marker that goes with it.
#
# WHAT THESE PIN, in priority order:
#
#   1. A FILE CANNOT REACH THE NEXT FILE. The environment one child gets is
#      asserted directly, and then asserted again from inside a real child the
#      runner started - with the leak staged hostile in this process, because a
#      runner that only clears what it happens to have inherited passes for the
#      wrong reason on a seat where nothing set it.
#   2. A FILE CANNOT RUN FOR EVER. The bound is exercised against a file that
#      really does hang, and the verdict says the file proved nothing rather
#      than that it passed.
#   3. NOTHING IS COUNTED AS A PASS THAT WAS NOT ONE. A file that reports no
#      counts, and a file that contains no tests, are failures with names.
#   4. THE THREE REAL ACTIONS REFUSE. install.ps1 is run for real with the
#      marker set, and refuses. The speech model and the administrator prompt
#      are covered in their own areas' files, where their subjects live.
#   5. AN ABSENT TOOL IS ABSENT. Get-FmTestPathSans is proved both ways: the
#      tool is unreachable on the PATH it returns, and reachable on the one it
#      was given - without that second half this file would pass against a
#      helper that did nothing on a machine where the tool was never there.
#
# WHAT IS DELIBERATELY NOT TESTED: the runner against this repository's own
# tests/ directory. That is the gate, not a unit under test, and running it from
# inside itself would be a fifty-three file suite inside one test.
#
# STAGING THE MARKER IS NOT OPTIONAL HERE. This suite runs under the runner as
# well as by hand, so FM_TEST_MODE is set on some correct runs and unset on
# others. Every case below states it, and puts back what it found.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'FmToolAbsence.TestHelpers.ps1')
    . (Join-Path $PSScriptRoot 'FmUnstartable.TestHelpers.ps1')
    Import-FmTestModule $PSScriptRoot

    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
    $script:Pwsh = Join-Path $PSHOME 'pwsh.exe'

    # A test file that answers a question about the process it is running in,
    # phrased as a Pester case so a failure is reported as one. The runner's
    # whole claim is about that process, so this is the shape that can check it.
    function New-FixtureTest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A Pester fixture builder that writes only into TestDrive; -WhatIf would leave the case running a file that was never written.')]
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Body
        )
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force
        }
        $path = Join-Path $Directory "$Name.Tests.ps1"
        [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
        $path
    }

    # A FAILING FILE'S TEMP DIRECTORY IS KEPT ON PURPOSE - it is the evidence,
    # and the runner's report names where it is. The cases below manufacture
    # failures deliberately, so they are the one caller that has to sweep up
    # after itself: without this, running this file BY HAND leaves a directory
    # per failing case in the machine's temp. Run through the runner there is
    # nothing to sweep, because the whole run root is inside this file's own
    # private temp.
    function Remove-FmRunTemp {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Removes only the disposable run root this file just created. -WhatIf would leave the litter this exists to clear.')]
        param([Parameter(Mandatory)]$Report)
        if ($Report.TempRoot -and (Test-Path -LiteralPath $Report.TempRoot)) {
            Remove-Item -LiteralPath $Report.TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the marker that says a test run is conducting this process' {
    BeforeEach {
        $script:AmbientTestMode = $env:FM_TEST_MODE
    }
    AfterEach {
        if ($null -eq $script:AmbientTestMode) {
            Remove-Item -LiteralPath 'Env:\FM_TEST_MODE' -ErrorAction SilentlyContinue
        } else {
            $env:FM_TEST_MODE = $script:AmbientTestMode
        }
    }

    It 'believes a marker that names a process which is still there' {
        # This process is one, and it is the shape a child gets: the runner's
        # own id, set on the child and never on itself.
        Test-FmTestMode -Marker "$PID" | Should -BeTrue
    }

    It 'reads a marker that names nothing as the leftover it is' {
        # THE DEFECT THIS AVOIDS HAS ALREADY HAPPENED TO THE OTHER MARKER.
        # FM_SHELL_RELAUNCHED was a literal '1', a captain's window kept carrying
        # it after the install that wrote it had finished, and start.ps1 in that
        # window told them their PowerShell 7 was not PowerShell 7. A flag that
        # only says "a test run happened" cannot tell a live run from a stale
        # export, and the cost here would be refusing a real captain's install.
        foreach ($leftover in @('1', '0', '-4', 'yes', 'true', ' ', '')) {
            Test-FmTestMode -Marker $leftover | Should -BeFalse -Because "'$leftover' names no live process"
        }
    }

    It 'reads the environment when it is not handed a marker' {
        $env:FM_TEST_MODE = "$PID"
        Test-FmTestMode | Should -BeTrue

        Remove-Item -LiteralPath 'Env:\FM_TEST_MODE'
        Test-FmTestMode | Should -BeFalse
    }

    It 'says what was refused, who is refusing and how to get out of it' {
        $env:FM_TEST_MODE = "$PID"
        $refusal = Get-FmTestModeRefusal -Action 'install onto this machine'

        $refusal | Should -Match 'REFUSED'
        $refusal | Should -Match 'install onto this machine' -Because 'a refusal that does not name the action is not a diagnosis'
        $refusal | Should -Match ([regex]::Escape("process $PID")) -Because 'the run doing the refusing is nameable, so it is named'
        $refusal | Should -Match 'FM_TEST_MODE' -Because 'a captain who meets this needs the thing to clear'
    }
}

Describe 'what a test child inherits, and what it does not' {
    BeforeAll {
        # The leak, staged in THIS process. Both halves of it: an operator's own
        # override, and the checkout on PSModulePath - the second is what let a
        # fixture autoload the module it had deliberately stubbed out and hang
        # the suite for 11.6 hours (docs/windows-e2e-evidence.md section 56).
        $script:SavedOverride = $env:FM_STATE_OVERRIDE
        $script:SavedModulePath = $env:PSModulePath
        $env:FM_STATE_OVERRIDE = 'C:\an-operator-pane-set-this'
        $env:PSModulePath = "$(Join-Path $script:RepoRoot 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"

        # What a child says about its own environment, run through the bounded
        # runner because that is the one this port starts children with.
        function Get-ChildReading {
            param([string[]]$Exclude = @(), [hashtable]$Set = @{})
            $command = ('[Console]::Out.WriteLine("OVERRIDE=[" + $env:FM_STATE_OVERRIDE + "]"); ' +
                '[Console]::Out.WriteLine("FIRSTMATE=[" + @(Get-Module -ListAvailable -Name Firstmate).Count + "]"); ' +
                '[Console]::Out.WriteLine("TESTMODE=[" + $env:FM_TEST_MODE + "]")')
            $run = Invoke-FmBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 120 `
                -ExcludeEnvironment $Exclude -Environment $Set `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-NoLogo', '-Command', $command)
            $run.StdOut
        }
    }
    AfterAll {
        if ($null -eq $script:SavedOverride) {
            Remove-Item -LiteralPath 'Env:\FM_STATE_OVERRIDE' -ErrorAction SilentlyContinue
        } else {
            $env:FM_STATE_OVERRIDE = $script:SavedOverride
        }
        $env:PSModulePath = $script:SavedModulePath
    }

    It 'names the family, the module path and the private places, and nothing else' {
        $environment = Get-FmTestRunEnvironment -TempPath 'C:\fixture\t' -HomePath 'C:\fixture\h' -RunnerProcessId 4242

        $environment.Remove | Should -Contain 'FM_*'
        $environment.Remove | Should -Contain 'PSModulePath'
        $environment.Set['FM_TEST_MODE'] | Should -Be '4242'
        $environment.Set['FM_HOME'] | Should -Be 'C:\fixture\h' -Because 'unset means the CHECKOUT here, which is the captain''s own records in the primary'
        $environment.Set['FM_VOICE_OFF'] | Should -Be '1' -Because 'nothing this repo starts may speak, and inheriting that would be luck'
        $environment.Set['TEMP'] | Should -Be 'C:\fixture\t'
        $environment.Set['TMP'] | Should -Be 'C:\fixture\t'
    }

    It 'still carries the leak when nothing is excluded, which is what makes the case above mean something' {
        # THE NEGATIVE CONTROL. Without it this file would pass on a seat where
        # neither variable was ever set, and would have proved nothing about
        # either. Both halves are staged hostile above; this reads them back out
        # of a real child.
        $reading = Get-ChildReading

        $reading | Should -Match ([regex]::Escape('OVERRIDE=[C:\an-operator-pane-set-this]'))
        $reading | Should -Not -Match ([regex]::Escape('FIRSTMATE=[0]')) -Because 'a leaked PSModulePath is how a stubbed-out module comes back'
    }

    It 'drops the whole family and the module path, and puts back only what was asked for' {
        $environment = Get-FmTestRunEnvironment -TempPath (Join-Path $TestDrive 't') -HomePath (Join-Path $TestDrive 'h') `
            -RunnerProcessId $PID
        $reading = Get-ChildReading -Exclude $environment.Remove -Set $environment.Set

        $reading | Should -Match ([regex]::Escape('OVERRIDE=[]')) -Because 'an operator pane''s override is not a fact about the code under test'
        $reading | Should -Match ([regex]::Escape('FIRSTMATE=[0]')) -Because 'a child that can autoload this checkout has the door the 11.6 hour hang came through'
        # Removals run before additions, so a caller can drop a family and set
        # one member of it back. FM_TEST_MODE is that member, every time.
        $reading | Should -Match ([regex]::Escape("TESTMODE=[$PID]"))
    }
}

Describe 'one process per test file' {
    BeforeAll {
        $script:SavedOverride = $env:FM_STATE_OVERRIDE
        $env:FM_STATE_OVERRIDE = 'C:\an-operator-pane-set-this'
    }
    AfterAll {
        if ($null -eq $script:SavedOverride) {
            Remove-Item -LiteralPath 'Env:\FM_STATE_OVERRIDE' -ErrorAction SilentlyContinue
        } else {
            $env:FM_STATE_OVERRIDE = $script:SavedOverride
        }
    }

    It 'reports a pass, a failure and an empty file each as what it is' {
        $dir = Join-Path $TestDrive 'three'
        $null = New-FixtureTest -Directory $dir -Name 'AGood' -Body @'
Describe 'good' { It 'passes' { 1 | Should -Be 1 } }
'@
        $null = New-FixtureTest -Directory $dir -Name 'BBad' -Body @'
Describe 'bad' { It 'passes' { 1 | Should -Be 1 }; It 'does not' { 1 | Should -Be 2 } }
'@
        # A FILE WITH NO TESTS IS NOT A CLEAN FILE. Pester reports zero tests
        # rather than failing, and `Invoke-Pester -Path ./tests` counts that as
        # nothing wrong - which is exactly what a second top-level AfterAll does
        # to a file here, silently.
        $null = New-FixtureTest -Directory $dir -Name 'CEmpty' -Body @'
# deliberately contains no Describe at all
'@
        $report = Invoke-FmTestRun -Path $dir -RepoRoot $script:RepoRoot -TimeoutSeconds 300 -Verbosity None -Quiet

        $report.Ok | Should -BeFalse
        $report.FileCount | Should -Be 3
        @($report.Files | Where-Object { $_.Name -eq 'AGood.Tests.ps1' }).Outcome | Should -Be 'passed'
        @($report.Files | Where-Object { $_.Name -eq 'BBad.Tests.ps1' }).Outcome | Should -Be 'failed'
        @($report.Files | Where-Object { $_.Name -eq 'CEmpty.Tests.ps1' }).Outcome | Should -Be 'empty'
        $report.Failed | Should -Be 1
        $report.Passed | Should -Be 2

        # A failing file's leftovers are evidence and stay; a passing one's are
        # noise and do not.
        $good = @($report.Files | Where-Object { $_.Name -eq 'AGood.Tests.ps1' })
        $bad = @($report.Files | Where-Object { $_.Name -eq 'BBad.Tests.ps1' })
        Test-Path -LiteralPath $good.TempRoot | Should -BeFalse
        Test-Path -LiteralPath $bad.TempRoot | Should -BeTrue
        Remove-FmRunTemp -Report $report
    }

    It 'kills a file that will not finish, and says it proved nothing' {
        # THE DEFECT THIS REPLACES. A fixture reached a question nobody was there
        # to answer, in a child with no console, and the run never came back:
        # 11.6 hours before it was killed, twice, on main as well as on a branch.
        # With a bound the same file costs its limit and names itself.
        $dir = Join-Path $TestDrive 'hang'
        $null = New-FixtureTest -Directory $dir -Name 'Hangs' -Body @'
Describe 'hangs' { It 'never finishes' { Start-Sleep -Seconds 300; 1 | Should -Be 1 } }
'@
        $report = Invoke-FmTestRun -Path $dir -RepoRoot $script:RepoRoot -TimeoutSeconds 5 -Verbosity None -Quiet

        $report.Ok | Should -BeFalse
        $report.TimedOutFiles | Should -Be 1
        $file = @($report.Files)[0]
        $file.Outcome | Should -Be 'timeout'
        $file.Detail | Should -Match 'nothing in this file was proved' -Because 'a killed file is not a file that passed'
        $file.DurationSeconds | Should -BeLessThan 120 -Because 'the bound is the point'
        Remove-FmRunTemp -Report $report
    }

    It 'hands each file a clean environment, a private home and a private temp' {
        # ASSERTED FROM INSIDE THE CHILD, because that is the only process whose
        # environment the claim is about. The leak is staged hostile in this
        # process by the BeforeAll above, so a runner that stopped scrubbing
        # would fail here rather than pass for want of anything to scrub.
        $dir = Join-Path $TestDrive 'isolated'
        $null = New-FixtureTest -Directory $dir -Name 'Isolation' -Body @'
Describe 'what this child was given' {
    It 'was not handed the operator pane''s override' {
        $env:FM_STATE_OVERRIDE | Should -BeNullOrEmpty
    }
    It 'cannot autoload the checkout''s module by name' {
        @(Get-Module -ListAvailable -Name Firstmate).Count | Should -Be 0
    }
    It 'knows a test run is conducting it' {
        $env:FM_TEST_MODE | Should -Not -BeNullOrEmpty
    }
    It 'was told nothing may speak' {
        $env:FM_VOICE_OFF | Should -Be '1'
    }
    It 'has a home of its own that is not the checkout' {
        $env:FM_HOME | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $env:FM_HOME -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $env:FM_HOME -Force).Count | Should -Be 0
    }
    It 'has a temp of its own, and Pester''s TestDrive is inside it' {
        [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar) |
            Should -Be $env:TEMP.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $TestDrive | Should -BeLike "$env:TEMP*"
    }
}
'@
        $report = Invoke-FmTestRun -Path $dir -RepoRoot $script:RepoRoot -TimeoutSeconds 300 -Verbosity None -Quiet

        $report.Ok | Should -BeTrue -Because ($report.Lines -join "`n")
        $report.Total | Should -Be 6
    }

    It 'runs the files a filter selects, in name order' {
        # ORDER IS PART OF THE CONTRACT. Per-file isolation is what makes an
        # ordering-dependent failure impossible; an order taken from the
        # filesystem would make one unreproducible instead.
        $dir = Join-Path $TestDrive 'ordered'
        foreach ($name in @('Charlie', 'Alpha', 'Bravo')) {
            $null = New-FixtureTest -Directory $dir -Name $name -Body "Describe '$name' { It 'is here' { 1 | Should -Be 1 } }"
        }
        $report = Invoke-FmTestRun -Path $dir -RepoRoot $script:RepoRoot -TimeoutSeconds 300 `
            -Filter @('Alpha*', 'Charlie*') -Verbosity None -Quiet

        $report.Ok | Should -BeTrue -Because ($report.Lines -join "`n")
        @($report.Files | ForEach-Object { $_.Name }) | Should -Be @('Alpha.Tests.ps1', 'Charlie.Tests.ps1')
    }

    It 'counts a file that died before it could report as a file that did not run' {
        # NEVER A SILENT ZERO. A runner that defaulted the counts would report a
        # file that crashed on load as a clean file with nothing in it - which is
        # the same mistake as calling a missing owner a passing step.
        $dir = Join-Path $TestDrive 'crash'
        $null = New-FixtureTest -Directory $dir -Name 'Crashes' -Body @'
[Environment]::Exit(3)
'@
        $report = Invoke-FmTestRun -Path $dir -RepoRoot $script:RepoRoot -TimeoutSeconds 300 -Verbosity None -Quiet

        $report.Ok | Should -BeFalse
        $file = @($report.Files)[0]
        $file.Outcome | Should -Be 'unreported'
        $file.Detail | Should -Match 'no tests this runner can vouch for'
        $file.ExitCode | Should -Be 3 -Because 'what the child returned is reported, not distilled into a phrase'
        Remove-FmRunTemp -Report $report
    }

    It 'takes several filters from the command line, where an array cannot survive' {
        # THE ENTRY POINT, RUN AS A REAL CHILD, because this behaviour only
        # exists at a process boundary. `pwsh -File` hands a script every
        # argument as ONE STRING - measured: `-Filter A*,B*` binds as the single
        # pattern `A*,B*`, which matches no file - so the split lives in
        # bin/fm-test-run.ps1 and is proved here rather than assumed.
        $dir = Join-Path $TestDrive 'cli'
        foreach ($name in @('Alpha', 'Bravo', 'Charlie')) {
            $null = New-FixtureTest -Directory $dir -Name $name -Body "Describe '$name' { It 'is here' { 1 | Should -Be 1 } }"
        }
        $run = Invoke-FmBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 300 -WorkingDirectory $script:RepoRoot `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-NoLogo', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:RepoRoot 'bin' 'fm-test-run.ps1'),
            '-Path', $dir, '-Filter', 'Alpha*,Charlie*', '-Verbosity', 'None')

        $run.ExitCode | Should -Be 0 -Because "the entry point reports 0 when every file passed; it said: $($run.StdOut)$($run.StdErr)"
        $run.StdOut | Should -Match ([regex]::Escape('[1/2] Alpha.Tests.ps1'))
        $run.StdOut | Should -Match ([regex]::Escape('[2/2] Charlie.Tests.ps1'))
        $run.StdOut | Should -Not -Match 'Bravo' -Because 'a filter that selects two files must not run the third'
    }

    It 'refuses a bound that is not a bound, and a directory with nothing in it' {
        { Invoke-FmTestRun -Path $TestDrive -TimeoutSeconds 0 } | Should -Throw '*not a bound*'
        $empty = Join-Path $TestDrive 'nothing-here'
        $null = New-Item -ItemType Directory -Path $empty -Force
        { Invoke-FmTestRun -Path $empty -TimeoutSeconds 60 } | Should -Throw '*no *.Tests.ps1 matched*'
    }
}

Describe 'a fixture cannot fall through to the real tool' {
    BeforeAll {
        # A machine of this file's own making, so the case does not depend on
        # what happens to be installed on the seat running it. Two directories,
        # because the hazard is exactly that a directory carries BOTH the tool
        # being hidden and tools the fixture still needs.
        function New-ToolMachine {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'A Pester fixture builder that writes only into TestDrive; -WhatIf would leave the case asserting against a machine that was never built.')]
            param([Parameter(Mandatory)][string]$Directory)
            $first = Join-Path $Directory 'one'
            $second = Join-Path $Directory 'two'
            foreach ($d in @($first, $second)) { $null = New-Item -ItemType Directory -Path $d -Force }
            # fmfixturetool lives in BOTH, which is the usr-merge shape: hiding
            # it must not cost the neighbours in either directory.
            foreach ($d in @($first, $second)) {
                [System.IO.File]::WriteAllText((Join-Path $d 'fmfixturetool.cmd'), "@echo off`r`necho real`r`n")
            }
            [System.IO.File]::WriteAllText((Join-Path $first 'fmfixturekeep.cmd'), "@echo off`r`necho keep`r`n")
            # A second executable in the same directory as the hidden one, so the
            # mirror is proved to carry its neighbours. Through
            # New-FmUnstartableFixture because it ends in .exe: anything at all
            # behind an executable extension is read by 64-bit Windows as an
            # MS-DOS program and raises a modal dialog on the captain's desktop
            # that no test can see. tests/FmUnstartable.TestHelpers.ps1 owns that
            # measurement, and a lint in tests/FmModuleAssembly.Tests.ps1 fails
            # any file that writes these bytes by hand.
            $null = New-FmUnstartableFixture -Path (Join-Path $second 'fmfixtureother.exe')
            # A file that is not a command at all, to pin that the mirror carries
            # what PATH can resolve rather than everything it finds.
            [System.IO.File]::WriteAllText((Join-Path $first 'notes.txt'), 'not a command')
            ($first + [IO.Path]::PathSeparator + $second)
        }
    }

    It 'resolves the tool on the PATH it was given, which is what makes the next case mean something' {
        $base = New-ToolMachine -Directory (Join-Path $TestDrive 'machine-control')
        $hits = Resolve-FmTestPathCommand $base 'fmfixturetool'
        $hits.Count | Should -Be 2 -Because 'a helper that hides a tool nothing had is a helper that does nothing'
    }

    It 'hands back a PATH the tool is not on, and keeps everything else' {
        $base = New-ToolMachine -Directory (Join-Path $TestDrive 'machine-sans')
        $sans = Get-FmTestPathSans -Tool 'fmfixturetool' -Directory (Join-Path $TestDrive 'sans-out') -BasePath $base

        (Resolve-FmTestPathCommand $sans 'fmfixturetool').Count | Should -Be 0
        (Resolve-FmTestPathCommand $sans 'fmfixturekeep').Count | Should -Be 1 -Because 'dropping the directory would take the neighbours with it'
        (Resolve-FmTestPathCommand $sans 'fmfixtureother').Count | Should -Be 1
    }

    It 'hides every spelling PATHEXT gives a name, not only the one asked for' {
        # THE WINDOWS HALF, and the reason the Linux helper this is modelled on
        # does not need it: one bare name resolves through half a dozen
        # extensions here, so removing `foo` and removing what `foo` resolves to
        # are different statements.
        $dir = Join-Path $TestDrive 'pathext'
        $null = New-Item -ItemType Directory -Path $dir -Force
        [System.IO.File]::WriteAllText((Join-Path $dir 'fmfixturemulti.cmd'), "@echo off`r`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'fmfixturemulti.bat'), "@echo off`r`n")
        (Resolve-FmTestPathCommand $dir 'fmfixturemulti').Count | Should -Be 2

        $sans = Get-FmTestPathSans -Tool 'fmfixturemulti' -Directory (Join-Path $TestDrive 'pathext-out') -BasePath $dir
        (Resolve-FmTestPathCommand $sans 'fmfixturemulti').Count | Should -Be 0
    }

    It 'makes the real shell unreachable, which is the case that cost thirty-nine minutes' {
        # NOT A SYNTHETIC TOOL. `pwsh` is the one this repo actually stubs, in
        # the two cases that run the shipped entry points, and it is the one
        # whose stub was missed.
        $sans = Get-FmTestPathSans -Tool 'pwsh' -Directory (Join-Path $TestDrive 'sans-pwsh')

        (Resolve-FmTestPathCommand $sans 'pwsh').Count | Should -Be 0
        (Resolve-FmTestPathCommand $env:PATH 'pwsh').Count | Should -BeGreaterThan 0 -Because 'this machine has one, or the case above proves nothing'
    }
}

Describe 'what the installer does while a test run names itself' {
    It 'refuses to run at all, and changes nothing' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'install.ps1 is the Windows entry point'
            return
        }
        # THE SHIPPED FILE, NOT A COPY, because the thing being proved is that
        # the guard is in the script the captain and the fixtures actually run.
        #
        # -DetectOnly -Offline IS THE SAFETY, and it is deliberate belt as well
        # as brace: if this guard were ever removed, the worst this case could
        # then do is print a plan and delete its own probe directory. The
        # assertion still means what it says, because a refusal and a plan do
        # not look remotely alike.
        $run = Invoke-FmBoundedCommand -FilePath $script:Pwsh -TimeoutSeconds 300 `
            -WorkingDirectory $script:RepoRoot `
            -Environment @{ FM_TEST_MODE = "$PID" } `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-NoLogo', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:RepoRoot 'install.ps1'), '-DetectOnly', '-Offline')

        $combined = $run.StdOut + "`n" + $run.StdErr
        $combined | Should -Match 'REFUSED' -Because 'an installer inside a suite stops rather than warns'
        $combined | Should -Match ([regex]::Escape("process $PID"))
        $combined | Should -Match 'Nothing was installed and nothing was changed'
        $combined | Should -Not -Match 'what this machine has' -Because 'the refusal comes before the plan, not after it'
        $run.ExitCode | Should -Be 1
        $run.TimedOut | Should -BeFalse
    }
}
