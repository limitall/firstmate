#requires -Version 7.0
# Pester 5+/6 tests for the entry-point bootstrap: bin/fm-*.ps1 working in a
# shell that never loaded a PowerShell profile.
#
# WHY THE CHILD PROCESSES. The defect these tests exist for shipped WITH a green
# suite, because every test ran inside a session that had already imported the
# module and already had FM_HOME set - which is precisely the condition that
# hides it. The install area's own tests could not have caught it either: they
# call Install-FmHome and Invoke-FmDoctor in-process.
#
# So the tests below that matter run a real `pwsh -NoProfile` against a real
# checkout copied to a temporary path, with FM_* and PSModulePath stripped out
# of the child's environment. That is the herdr pane, the Claude hook, the
# scheduled task and the dispatched worker, reproduced.
#
# Each of those tests is paired with its own NEGATIVE CONTROL: delete the
# pointer and assert the old symptom comes back. A regression test whose
# assertion also passes against the broken code is not a regression test, and
# AGENTS.md records that several here did not fail when their code was reverted.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build a disposable temp checkout and home. -WhatIf on a fixture would leave the test asserting against a checkout that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $script:Manifest = Join-Path $script:RepoRoot 'module' 'Firstmate' 'Firstmate.psd1'
    Import-Module -Name $script:Manifest -Force -ErrorAction Stop

    $script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    # A checkout at a path nothing knows about, so "the entry point derives its
    # own root" is actually under test rather than accidentally true.
    function New-TestCheckout {
        param([Parameter(Mandatory)][string]$Destination)
        $null = New-Item -ItemType Directory -Path $Destination -Force
        foreach ($dir in @('bin', 'module')) {
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot $dir) -Destination $Destination -Recurse -Force
        }
        # AGENTS.md too: half these tests are about which directory a Claude
        # session should start in, and a fixture with no memory file could not
        # tell the two directories apart.
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'AGENTS.md') -Destination $Destination -Force
        # And CLAUDE.md exactly as a Windows clone of this repo has it: the repo
        # tracks it as a symlink, and git with core.symlinks=false - the default
        # on Windows - writes the LINK TEXT as an ordinary file. MEASURED on the
        # captain's laptop: 9 bytes, content 'AGENTS.md'. Building the fixture any
        # other way would test a checkout no Windows machine actually has.
        [System.IO.File]::WriteAllText((Join-Path $Destination 'CLAUDE.md'), 'AGENTS.md')
        # A stray pointer copied in from the developer's own checkout would make
        # every test below pass for the wrong reason.
        $stray = Join-Path $Destination '.fm-home'
        if (Test-Path -LiteralPath $stray) { Remove-Item -LiteralPath $stray -Force }
        $Destination
    }

    function New-TestHome {
        param([Parameter(Mandatory)][string]$Path)
        foreach ($sub in @('config', 'data', 'projects', 'state')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $Path $sub) -Force
        }
        $Path
    }

    # A child pwsh with the firstmate environment REMOVED, not merely unset in
    # this session: ProcessStartInfo.Environment starts as a copy of ours, and
    # the suite is routinely run from a session that has FM_HOME.
    function Invoke-BareShell {
        param(
            [Parameter(Mandatory)][string[]]$PwshArgs,
            [hashtable]$Environment = @{}
        )
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:Pwsh
        foreach ($a in (@('-NoProfile', '-NonInteractive') + $PwshArgs)) { $psi.ArgumentList.Add([string]$a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false

        foreach ($key in @($psi.Environment.Keys)) {
            if ($key -like 'FM_*' -or $key -eq 'PSModulePath') { $null = $psi.Environment.Remove($key) }
        }
        foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
    }

    function Invoke-BareEntryPoint {
        param(
            [Parameter(Mandatory)][string]$Checkout,
            [Parameter(Mandatory)][string]$Script,
            [string[]]$CliArgs = @(),
            [hashtable]$Environment = @{}
        )
        Invoke-BareShell -Environment $Environment `
            -PwshArgs (@('-File', (Join-Path $Checkout 'bin' $Script)) + $CliArgs)
    }

    function Get-HomeLine {
        param([Parameter(Mandatory)][string]$Text)
        $line = @($Text -split "`r?`n" | Where-Object { $_ -match '^Home:\s' } | Select-Object -First 1)
        if ($line.Count -eq 0) { return '' }
        ($line[0] -replace '^Home:\s*', '').Trim()
    }
}

Describe 'Get-FmHomePointerPath' {
    It 'sits beside the checkout, so two checkouts can point at two homes' {
        Get-FmHomePointerPath -RepoRoot (Join-Path $TestDrive 'checkout-a') |
            Should -Be (Join-Path $TestDrive 'checkout-a' '.fm-home')
        Get-FmHomePointerPath -RepoRoot (Join-Path $TestDrive 'checkout-b') |
            Should -Be (Join-Path $TestDrive 'checkout-b' '.fm-home')
    }

    It 'defaults to the code root the foundation resolves' {
        Get-FmHomePointerPath | Should -Be (Join-Path (Get-FmRoot) '.fm-home')
    }
}

Describe 'Write-FmHomePointer' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:Root -Force
        $script:Pointer = Join-Path $script:Root '.fm-home'
    }

    It 'creates the pointer and reports created' {
        Write-FmHomePointer -HomePath (Join-Path $TestDrive 'home') -Path $script:Pointer | Should -Be 'created'
        Test-Path -LiteralPath $script:Pointer -PathType Leaf | Should -BeTrue
    }

    It 'is idempotent: the second write changes nothing and reports already' {
        $home_ = Join-Path $TestDrive 'home'
        $null = Write-FmHomePointer -HomePath $home_ -Path $script:Pointer
        $first = [System.IO.File]::ReadAllBytes($script:Pointer)
        Write-FmHomePointer -HomePath $home_ -Path $script:Pointer | Should -Be 'already'
        [System.IO.File]::ReadAllBytes($script:Pointer) | Should -Be $first
    }

    It 'converges rather than appends when the home moves' {
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'old') -Path $script:Pointer
        Write-FmHomePointer -HomePath (Join-Path $TestDrive 'new') -Path $script:Pointer | Should -Be 'updated'
        Read-FmHomePointer -Path $script:Pointer | Should -Be (Join-Path $TestDrive 'new')
        @([System.IO.File]::ReadAllText($script:Pointer) -split "`n" | Where-Object { $_ }).Count | Should -Be 1
    }

    It 'writes UTF-8 without a BOM and LF-only, because a Linux firstmate reads it' {
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'secondmate-a') -Path $script:Pointer
        $bytes = [System.IO.File]::ReadAllBytes($script:Pointer)
        @($bytes[0], $bytes[1], $bytes[2]) | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        $bytes | Should -Not -Contain 13
        $bytes[-1] | Should -Be 10
    }

    It 'writes nothing under -WhatIf' {
        Write-FmHomePointer -HomePath (Join-Path $TestDrive 'home') -Path $script:Pointer -WhatIf | Should -Be 'skipped'
        Test-Path -LiteralPath $script:Pointer | Should -BeFalse
    }
}

Describe 'Read-FmHomePointer' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:Root -Force
        $script:Pointer = Join-Path $script:Root '.fm-home'
    }

    It 'is null when there is no pointer' {
        Read-FmHomePointer -Path $script:Pointer | Should -BeNullOrEmpty
    }

    It 'is null for an empty or whitespace-only pointer rather than an empty home' {
        [System.IO.File]::WriteAllText($script:Pointer, "  `n`n")
        Read-FmHomePointer -Path $script:Pointer | Should -BeNullOrEmpty
    }

    It 'skips comment lines, so the captain can say what the file is for' {
        # An absolute path built for this platform, not a literal: on Windows a
        # POSIX-looking '/srv/firstmate' is drive-relative and resolves to
        # 'C:\srv\firstmate', so a hard-coded expectation passes on Linux and
        # fails on the machine the port is for. That is exactly what it did.
        $expected = Join-Path $TestDrive 'srv' 'firstmate'
        [System.IO.File]::WriteAllText($script:Pointer, "# written by fm-setup.ps1`n$expected`n")
        Read-FmHomePointer -Path $script:Pointer | Should -Be $expected
    }

    It 'resolves a relative home to an absolute path' {
        [System.IO.File]::WriteAllText($script:Pointer, ".`n")
        Read-FmHomePointer -Path $script:Pointer | Should -Be (Resolve-FmFullPath -Path $PWD.ProviderPath)
    }

    It 'degrades to no pointer rather than throwing when the path is unreadable' {
        # A directory where the file should be: Test-Path -PathType Leaf is
        # false, and nothing downstream may see an exception - this runs before
        # anything else an entry point does.
        $null = New-Item -ItemType Directory -Path $script:Pointer -Force
        { Read-FmHomePointer -Path $script:Pointer } | Should -Not -Throw
        Read-FmHomePointer -Path $script:Pointer | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-FmEntryPointHome precedence' {
    BeforeEach {
        $script:SavedHome = $env:FM_HOME
        $script:SavedRoot = $env:FM_ROOT_OVERRIDE
        $env:FM_HOME = ''
        $env:FM_ROOT_OVERRIDE = ''
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:Root -Force
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'persisted') -Path (Join-Path $script:Root '.fm-home')
    }
    AfterEach {
        $env:FM_HOME = $script:SavedHome
        $env:FM_ROOT_OVERRIDE = $script:SavedRoot
    }

    It '1. an explicit -HomePath beats everything' {
        $env:FM_HOME = Join-Path $TestDrive 'from-env'
        Resolve-FmEntryPointHome -HomePath (Join-Path $TestDrive 'explicit') -RepoRoot $script:Root |
            Should -Be (Join-Path $TestDrive 'explicit')
    }

    It '2. FM_HOME beats the persisted value, so an override still works' {
        $env:FM_HOME = Join-Path $TestDrive 'from-env'
        Resolve-FmEntryPointHome -RepoRoot $script:Root | Should -Be (Join-Path $TestDrive 'from-env')
    }

    It '2. FM_ROOT_OVERRIDE beats the persisted value too, matching bash order' {
        $env:FM_ROOT_OVERRIDE = Join-Path $TestDrive 'from-root-override'
        Resolve-FmEntryPointHome -RepoRoot $script:Root | Should -Be (Join-Path $TestDrive 'from-root-override')
    }

    It '3. the persisted value is used when the environment says nothing' {
        Resolve-FmEntryPointHome -RepoRoot $script:Root | Should -Be (Join-Path $TestDrive 'persisted')
    }

    It '4. the documented default is THE CHECKOUT, the layout Linux has' {
        # On Linux the firstmate repo root IS the home. Defaulting anywhere else
        # is what made `cd <home>; claude` - the documented workflow - land in a
        # directory with no AGENTS.md and no hooks.
        $bare = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $bare -Force
        Resolve-FmEntryPointHome -RepoRoot $bare | Should -Be $bare
    }

    It '4. falls back to Get-FmHome when no checkout is named either' {
        $bare = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $bare -Force
        Resolve-FmEntryPointHome -PointerPath (Join-Path $bare '.fm-home') | Should -Be (Get-FmHome)
    }
}

Describe 'Initialize-FmEntryPointHome' {
    BeforeEach {
        $script:SavedHome = $env:FM_HOME
        $script:SavedRoot = $env:FM_ROOT_OVERRIDE
        $env:FM_HOME = ''
        $env:FM_ROOT_OVERRIDE = ''
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:Root -Force
    }
    AfterEach {
        $env:FM_HOME = $script:SavedHome
        $env:FM_ROOT_OVERRIDE = $script:SavedRoot
    }

    It 'publishes the persisted home into the environment for this process' {
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'persisted') -Path (Join-Path $script:Root '.fm-home')
        Initialize-FmEntryPointHome -RepoRoot $script:Root -Confirm:$false | Should -Be (Join-Path $TestDrive 'persisted')
        $env:FM_HOME | Should -Be (Join-Path $TestDrive 'persisted')
    }

    It 'leaves an environment that already names a home exactly as it was' {
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'persisted') -Path (Join-Path $script:Root '.fm-home')
        $env:FM_HOME = Join-Path $TestDrive 'from-env'
        $null = Initialize-FmEntryPointHome -RepoRoot $script:Root -Confirm:$false
        $env:FM_HOME | Should -Be (Join-Path $TestDrive 'from-env')
    }

    It 'publishes NOTHING when there is no pointer, so the fallback never becomes sticky' {
        # The first version of this published Get-FmHome's fallback too. A setup
        # run then pinned the checkout as the home for the rest of the session,
        # and the pointer it went on to write was outranked by its own guess.
        Initialize-FmEntryPointHome -RepoRoot $script:Root -Confirm:$false | Should -Be $script:Root
        $env:FM_HOME | Should -BeNullOrEmpty
    }

    It 'is what a later pointer needs in order to win' {
        $null = Initialize-FmEntryPointHome -RepoRoot $script:Root -Confirm:$false
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'written-later') -Path (Join-Path $script:Root '.fm-home')
        Initialize-FmEntryPointHome -RepoRoot $script:Root -Confirm:$false |
            Should -Be (Join-Path $TestDrive 'written-later')
    }

    It 'writes nothing to the environment under -WhatIf' {
        $null = Write-FmHomePointer -HomePath (Join-Path $TestDrive 'persisted') -Path (Join-Path $script:Root '.fm-home')
        $null = Initialize-FmEntryPointHome -RepoRoot $script:Root -WhatIf
        $env:FM_HOME | Should -BeNullOrEmpty
    }
}

Describe 'the entry points in a bare -NoProfile shell' {
    BeforeAll {
        # NOT $script:BareHome. $HOME is a read-only automatic variable, and the
        # assignment fails inside a Pester block in a way Pester reports as a
        # stray 'break' - which is the same hazard AGENTS.md records for a
        # parameter named -Home.
        $script:Checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'checkout')
        $script:BareHome = New-TestHome -Path (Join-Path $TestDrive 'bare-home')

        # -SkipProfile on purpose: this install is deliberately the one the
        # defect report describes - correct in every way except that no profile
        # carries the wiring. Everything below must work anyway.
        $script:Setup = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-setup.ps1' `
            -CliArgs @('-FirstmateHome', $script:BareHome, '-SkipProfile')
        $script:PointerPath = Join-Path $script:Checkout '.fm-home'
    }

    It 'fm-setup.ps1 runs to a healthy install from a bare shell' {
        $script:Setup.ExitCode | Should -Be 0 -Because ($script:Setup.StdOut + $script:Setup.StdErr)
        $script:Setup.StdOut | Should -Match '\[created\]\s+home pointer'
    }

    It 'persists the home beside the checkout it was run from' {
        Test-Path -LiteralPath $script:PointerPath -PathType Leaf | Should -BeTrue
        [System.IO.File]::ReadAllText($script:PointerPath).Trim() | Should -Be $script:BareHome
    }

    It 'fm-home.ps1 resolves the installed home, not the checkout' {
        $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-home.ps1'
        $run.ExitCode | Should -Be 0 -Because $run.StdErr
        Get-HomeLine -Text $run.StdOut | Should -Be $script:BareHome
    }

    It 'fm-home.ps1 without the pointer resolves the CHECKOUT - the bug, and the proof this test can see it' {
        $saved = [System.IO.File]::ReadAllText($script:PointerPath)
        Remove-Item -LiteralPath $script:PointerPath -Force
        try {
            $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-home.ps1'
            Get-HomeLine -Text $run.StdOut | Should -Be $script:Checkout
        } finally {
            [System.IO.File]::WriteAllText($script:PointerPath, $saved)
        }
    }

    It 'fm-doctor.ps1 is healthy and exits 0' {
        $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-doctor.ps1'
        $run.ExitCode | Should -Be 0 -Because ($run.StdOut + $run.StdErr)
        $run.StdOut | Should -Match 'healthy'
        $run.StdOut | Should -Not -Match '\[missing\]'
    }

    It 'fm-doctor.ps1 reports the absent profile as a warning, not as missing' {
        # The profile this install was pointed at was never written, so this is
        # the no-profile-wiring case - and it must cost a warning, not health.
        $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-doctor.ps1'
        $run.StdOut | Should -Match '(?m)^\s*\[warn\]\s+profile wiring'
        $run.ExitCode | Should -Be 0
    }

    It 'fm-doctor.ps1 without the pointer says so, by name, and exits 1' {
        $saved = [System.IO.File]::ReadAllText($script:PointerPath)
        Remove-Item -LiteralPath $script:PointerPath -Force
        try {
            $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-doctor.ps1'
            $run.ExitCode | Should -Be 1
            $run.StdOut | Should -Match '(?m)^\s*\[missing\]\s+FM_HOME'
            $run.StdOut | Should -Match '\.fm-home'
        } finally {
            [System.IO.File]::WriteAllText($script:PointerPath, $saved)
        }
    }

    It 'FM_HOME in the child environment still overrides the persisted home' {
        $other = New-TestHome -Path (Join-Path $TestDrive 'override-home')
        $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-home.ps1' -Environment @{ FM_HOME = $other }
        Get-HomeLine -Text $run.StdOut | Should -Be $other
    }

    It 'fm-crew-state.ps1 reads through the persisted home, still sees its own $args, and exits 0' {
        # The $args half is not incidental. The prelude is DOT-SOURCED with a
        # named parameter now, and fm-brief.ps1 and fm-crew-state.ps1 read $args
        # after that line. If dot-sourcing a script that declares param() reset
        # the caller's $args, both would silently lose their arguments - the
        # exact silent-break shape this whole area exists to remove. So one
        # entry point that takes a positional argument through $args asserts the
        # argument actually arrived, not merely that the command ran.
        $run = Invoke-BareEntryPoint -Checkout $script:Checkout -Script 'fm-crew-state.ps1' -CliArgs @('nobody')
        $run.ExitCode | Should -Be 0 -Because $run.StdErr
        $run.StdOut | Should -Match 'state:'
        $run.StdOut | Should -Match 'nobody'
    }

    It 'every entry point resolves the function it declares, and sees the persisted home' {
        # ENUMERATED FROM THE TREE, so a new entry point is covered the moment it
        # exists. Running each one for real is not an option - fm-watch.ps1
        # blocks and fm-fleet-sync.ps1 mutates - so this asserts the thing that
        # actually broke: the prelude alone, in a bare shell, makes that entry
        # point's own command reachable and the home resolvable.
        $harness = @'
param([string]$Checkout, [string]$ExpectedHome)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failures = @()
$seen = 0
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $Checkout 'bin') -Filter 'fm-*.ps1' -File | Sort-Object Name)) {
    if ($file.Name -eq 'fm-module-load.ps1') { continue }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $m = [regex]::Match($text, "fm-module-load\.ps1'\)\s+-RequiredCommand\s+'([A-Za-z]+-Fm[A-Za-z]+)'")
    if (-not $m.Success) { $failures += "$($file.Name): does not dot-source the prelude with -RequiredCommand"; continue }
    $seen++
    $name = $m.Groups[1].Value
    . (Join-Path $Checkout 'bin' 'fm-module-load.ps1') -RequiredCommand $name
    if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) { $failures += "$($file.Name): $name is unreachable" }
    if ($env:FM_HOME -ne $ExpectedHome) { $failures += "$($file.Name): FM_HOME is '$env:FM_HOME', expected '$ExpectedHome'" }
}
Write-Output "SEEN=$seen"
foreach ($f in $failures) { Write-Output "FAIL=$f" }
'@
        $harnessPath = Join-Path $TestDrive 'entry-point-harness.ps1'
        [System.IO.File]::WriteAllText($harnessPath, $harness)

        $run = Invoke-BareShell -PwshArgs @('-File', $harnessPath, '-Checkout', $script:Checkout, '-ExpectedHome', $script:BareHome)
        $run.ExitCode | Should -Be 0 -Because $run.StdErr

        $seen = [int](($run.StdOut -split "`r?`n" | Where-Object { $_ -match '^SEEN=' } | Select-Object -First 1) -replace '^SEEN=', '')
        $seen | Should -BeGreaterThan 20 -Because 'the sweep must be enumerating the real entry points, not an empty directory'

        $failures = @($run.StdOut -split "`r?`n" | Where-Object { $_ -match '^FAIL=' })
        ($failures -join '; ') | Should -Be ''
    }
}

Describe 'where do I start Claude, end to end in a bare shell' {
    # THE SECOND SILENT FAILURE. On Linux the firstmate repo root IS the home, so
    # `cd <firstmate>; claude` gives a session the instructions, the hooks and
    # the state at once - and that is what every doc in the fleet says to do.
    # This port put the home somewhere else, so the captain followed the docs
    # into a directory with no AGENTS.md and no .claude/, and the agent came up
    # with nothing at all and no indication anything was wrong.

    It 'a setup that names no home makes the home the checkout, as on Linux' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'coincident')
        $setup = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' -CliArgs @('-SkipProfile')
        $setup.ExitCode | Should -Be 0 -Because ($setup.StdOut + $setup.StdErr)

        $run = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-home.ps1'
        Get-HomeLine -Text $run.StdOut | Should -Be $checkout

        # The whole point: everything the documented workflow needs is in the
        # ONE directory the captain would cd into.
        foreach ($needed in @('AGENTS.md', 'CLAUDE.md', '.claude/settings.json',
                'config', 'data', 'projects', 'state')) {
            Test-Path -LiteralPath (Join-Path $checkout $needed) |
                Should -BeTrue -Because "cd $checkout; claude must find $needed"
        }
    }

    It 'reports the coincident layout as ok, and names the directory to use' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'coincident-doctor')
        $null = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' -CliArgs @('-SkipProfile')

        $run = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-doctor.ps1'
        $run.ExitCode | Should -Be 0 -Because ($run.StdOut + $run.StdErr)
        $run.StdOut | Should -Match '(?m)^\s*\[ok\]\s+start Claude in'
        $run.StdOut | Should -Match ([regex]::Escape($checkout))
    }

    It 'a separate home stops a session started in it, and names the checkout' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'split-checkout')
        $away = New-TestHome -Path (Join-Path $TestDrive 'split-home')
        $setup = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' `
            -CliArgs @('-FirstmateHome', $away, '-SkipProfile')
        $setup.ExitCode | Should -Be 0 -Because ($setup.StdOut + $setup.StdErr)

        # Both names, because a session may read either one.
        foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
            $text = [System.IO.File]::ReadAllText((Join-Path $away $name))
            $text | Should -BeLike '*STOP*'
            $text | Should -BeLike "*$checkout*" -Because 'it must name the directory to use'
        }
    }

    It 'a separate home with NOTHING to stop a session is reported as missing - the captain''s install' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'silent-checkout')
        $away = New-TestHome -Path (Join-Path $TestDrive 'silent-home')
        $null = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' `
            -CliArgs @('-FirstmateHome', $away, '-SkipProfile')

        # Exactly the state the captain was in: home and code apart, and the home
        # saying nothing. This is the negative control for the two tests above.
        foreach ($name in @('AGENTS.md', 'CLAUDE.md')) {
            Remove-Item -LiteralPath (Join-Path $away $name) -Force
        }

        $run = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-doctor.ps1' `
            -CliArgs @('-FirstmateHome', $away)
        $run.ExitCode | Should -Be 1
        $run.StdOut | Should -Match '(?m)^\s*\[missing\]\s+start Claude in'
        $run.StdOut | Should -Match 'no instructions and no hooks'
    }
}

Describe 'the checkout''s own CLAUDE.md, as a Windows clone actually has it' {
    # Making the home the checkout is only half the answer. git with
    # core.symlinks=false writes this repo's CLAUDE.md symlink out as a 9-byte
    # file containing the string 'AGENTS.md', so `cd <checkout>; claude` reads
    # one filename and comes up with no instructions - the same silent failure,
    # one directory over. Measured on the captain's laptop, not imagined.

    It 'setup replaces the git placeholder with the real instructions' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'placeholder-checkout')
        [System.IO.File]::ReadAllText((Join-Path $checkout 'CLAUDE.md')) |
            Should -Be 'AGENTS.md' -Because 'the fixture must start in the broken state'

        $setup = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' -CliArgs @('-SkipProfile')
        $setup.ExitCode | Should -Be 0 -Because ($setup.StdOut + $setup.StdErr)

        $claude = [System.IO.File]::ReadAllText((Join-Path $checkout 'CLAUDE.md'))
        $claude | Should -Not -Be 'AGENTS.md'
        $claude | Should -BeLike '*Project agent memory*' -Because 'it must carry the real instructions'
        $claude | Should -Be ([System.IO.File]::ReadAllText((Join-Path $checkout 'AGENTS.md')))
    }

    It 'the doctor calls the placeholder missing rather than letting it pass' {
        $checkout = New-TestCheckout -Destination (Join-Path $TestDrive 'placeholder-doctor')
        $null = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-setup.ps1' -CliArgs @('-SkipProfile')
        # Put the broken state back, exactly as a fresh `git checkout` would.
        [System.IO.File]::WriteAllText((Join-Path $checkout 'CLAUDE.md'), 'AGENTS.md')

        $run = Invoke-BareEntryPoint -Checkout $checkout -Script 'fm-doctor.ps1'
        $run.ExitCode | Should -Be 1
        $run.StdOut | Should -Match '(?m)^\s*\[missing\]\s+start Claude in'
        $run.StdOut | Should -Match 'symlink'
    }
}
