#requires -Version 7.0
<#
    Tests for the gnhf guards.

    What these pin, in priority order:

      1. THE CLEAN-TREE CASE. The bash original refused when the tree was
         completely clean - the normal case - because `grep` exits 1 on no match
         and `set -euo pipefail` turned that into a silent exit indistinguishable
         from a refusal. It is tested first and explicitly here because it is the
         case that actually broke, and it broke invisibly.
      2. THE REFUSALS. A guard that has never been seen to refuse is not known to
         work. Every one of them gets a test: not a repo, non-numeric, out of
         range, empty objective, dirty tree, and an attempt to pass a flag that
         would defeat a guard.
      3. THE AFTER-RUN GUARD FIRING. The whole reason this wrapper exists is that
         gnhf moved a primary checkout while configured not to. The guard is
         exercised by making the invocation actually move the checkout, so the
         failure path is proven rather than assumed.
      4. WHAT IS ALWAYS PASSED. --worktree and --max-iterations on every run, and
         no push flag ever - asserted on the real argument list.
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force

    # A throwaway git repo with one commit. Real git, not a fixture double: the
    # guards read branch and HEAD through git, so a double would test nothing.
    function New-GnhfRepo {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder; writes only under TestDrive.')]
        param()
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $dir -Force
        & git -C $dir init -q -b main
        [System.IO.File]::WriteAllText((Join-Path $dir 'README.md'), "seed`n")
        & git -C $dir add -A
        & git -C $dir -c user.name=t -c user.email=t@l commit -qm 'seed'
        $dir
    }
}

Describe 'the clean-tree case, which is what broke the bash original' {
    It 'reports a clean tree as clean rather than as a refusal' {
        # The exact regression: no dirty lines must mean an EMPTY collection, not
        # a null that throws under StrictMode and not a non-zero count.
        $repo = New-GnhfRepo
        $dirty = @(InModuleScope Firstmate -Parameters @{ Repo = $repo } { Get-FmGnhfDirtyLine -RepoPath $Repo })
        $dirty.Count | Should -Be 0
    }

    It 'proceeds past the dirty-tree guard on a clean tree' {
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess { 0 }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'anything' -Confirm:$false
            $result.Refused | Should -BeFalse
            $result.GuardHeld | Should -BeTrue
            $result.ExitCode | Should -Be 0
        }
    }

    It 'does not count gnhf''s own scratch directory as project dirt' {
        $repo = New-GnhfRepo
        $null = New-Item -ItemType Directory -Path (Join-Path $repo '.gnhf') -Force
        [System.IO.File]::WriteAllText((Join-Path $repo '.gnhf' 'state.json'), "{}`n")
        $dirty = @(InModuleScope Firstmate -Parameters @{ Repo = $repo } { Get-FmGnhfDirtyLine -RepoPath $Repo })
        $dirty.Count | Should -Be 0
    }
}

Describe 'the refusals' {
    It 'refuses a path that is not a git repo' {
        $plain = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $plain -Force
        $result = Invoke-FmGnhf -RepoPath $plain -MaxIterations '5' -Objective 'x' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.ExitCode | Should -Be 1
        $result.Lines -join ' ' | Should -BeLike '*not a git repo*'
    }

    It 'refuses a path that does not exist at all' {
        $result = Invoke-FmGnhf -RepoPath (Join-Path $TestDrive 'no-such-dir') -MaxIterations '5' `
            -Objective 'x' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.Lines -join ' ' | Should -BeLike '*not a directory*'
    }

    It 'refuses a max-iterations that is not a whole number' -ForEach @(
        @{ Value = 'abc' }, @{ Value = '3.5' }, @{ Value = '20abc' }, @{ Value = '-4' }
    ) {
        $repo = New-GnhfRepo
        $result = Invoke-FmGnhf -RepoPath $repo -MaxIterations $Value -Objective 'x' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.ExitCode | Should -Be 1
        # The value is quoted back, so the caller can see what was actually read.
        $result.Lines -join ' ' | Should -BeLike "*'$Value'*"
    }

    It 'refuses a max-iterations outside 1-100' -ForEach @(@{ Value = '0' }, @{ Value = '101' }) {
        $repo = New-GnhfRepo
        $result = Invoke-FmGnhf -RepoPath $repo -MaxIterations $Value -Objective 'x' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.Lines -join ' ' | Should -BeLike '*must be 1-100*'
    }

    It 'accepts the boundaries, because an off-by-one here silently narrows the range' -ForEach @(
        @{ Value = '1' }, @{ Value = '100' }
    ) {
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo; Value = $Value } {
            Mock Invoke-FmGnhfProcess { 0 }
            (Invoke-FmGnhf -RepoPath $Repo -MaxIterations $Value -Objective 'x' -Confirm:$false).Refused |
                Should -BeFalse
        }
    }

    It 'refuses an empty objective' {
        $repo = New-GnhfRepo
        $result = Invoke-FmGnhf -RepoPath $repo -MaxIterations '5' -Objective '   ' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.Lines -join ' ' | Should -BeLike '*empty objective*'
    }

    It 'refuses a dirty tree AND prints what is dirty, because "it is dirty" is not actionable' {
        $repo = New-GnhfRepo
        [System.IO.File]::WriteAllText((Join-Path $repo 'changed.txt'), "uncommitted`n")
        $result = Invoke-FmGnhf -RepoPath $repo -MaxIterations '5' -Objective 'x' -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.ExitCode | Should -Be 1
        $result.Lines -join ' ' | Should -BeLike '*uncommitted change(s); refusing*'
        $result.Lines -join ' ' | Should -BeLike '*changed.txt*'
    }

    It 'refuses a caller flag that would defeat a guard, rather than silently dropping it' -ForEach @(
        @{ Flag = '--push' }, @{ Flag = '--current-branch' }
    ) {
        $repo = New-GnhfRepo
        $result = Invoke-FmGnhf -RepoPath $repo -MaxIterations '5' -Objective 'x' `
            -ExtraArgument @($Flag) -Confirm:$false
        $result.Refused | Should -BeTrue
        $result.Lines -join ' ' | Should -BeLike "*refusing '$Flag'*"
    }
}

Describe 'what is always passed to gnhf' {
    It 'always passes --worktree and --max-iterations, and never a push flag' {
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            $script:Captured = $null
            Mock Invoke-FmGnhfProcess {
                $script:Captured = @{ Max = $MaxIterations; Extra = @($ExtraArgument) }
                0
            }
            $null = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '7' -Objective 'grind' -Confirm:$false
            $script:Captured.Max | Should -Be 7
            # The push flag is never forwarded, and the caller passed none here.
            (@($script:Captured.Extra) -join ' ') | Should -Not -BeLike '*--push*'
        }
    }

    It 'builds an argument list carrying --worktree and the bound' {
        # Asserted on the real builder rather than on a mock's parameters, so the
        # flags that reach gnhf are the ones under test.
        InModuleScope Firstmate {
            $captured = $null
            Mock Set-Location { }
            Mock Get-Location { 'C:\somewhere' }
            # gnhf itself is replaced for this assertion; only the argument list matters.
            function script:gnhf { $script:GnhfArgs = $args; $global:LASTEXITCODE = 0 }
            $null = Invoke-FmGnhfProcess -RepoPath 'C:\repo' -Objective 'do a thing' -MaxIterations 9
            $captured = @($script:GnhfArgs)
            $captured | Should -Contain '--worktree'
            $captured | Should -Contain '--max-iterations'
            $captured | Should -Contain '9'
            $captured | Should -Contain 'do a thing'
            $captured | Should -Not -Contain '--push'
        }
    }
}

Describe 'the after-run guard, which is the reason this wrapper exists' {
    It 'FIRES when the run moved the primary checkout, and names the restore command' {
        # This is the defect that was actually observed: gnhf checked its own
        # branch out in the primary checkout while configured not to. The
        # invocation here does the same thing on purpose, so the guard's failure
        # path is proven rather than assumed.
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess {
                & git -C $RepoPath checkout -q -b 'gnhf/pretend-branch'
                0
            }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'x' -Confirm:$false
            $result.GuardHeld | Should -BeFalse
            $result.ExitCode | Should -Be 3
            $joined = $result.Lines -join "`n"
            $joined | Should -BeLike '*GUARD FAILED*'
            $joined | Should -BeLike '*gnhf/pretend-branch*'
            $joined | Should -BeLike '*checkout main*'
        }
    }

    It 'FIRES when only the commit moved, not the branch' {
        # A guard that only compared branch names would miss a commit landing in
        # the primary checkout, which is equally not allowed.
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess {
                [System.IO.File]::WriteAllText((Join-Path $RepoPath 'snuck-in.txt'), "x`n")
                & git -C $RepoPath add -A
                & git -C $RepoPath -c user.name=t -c user.email=t@l commit -qm 'snuck in'
                0
            }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'x' -Confirm:$false
            $result.GuardHeld | Should -BeFalse
            $result.ExitCode | Should -Be 3
            $result.Before.Branch | Should -Be $result.After.Branch
            $result.Before.Head | Should -Not -Be $result.After.Head
        }
    }

    It 'HOLDS when the checkout is untouched, and reports gnhf''s own exit code' {
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess { 42 }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'x' -Confirm:$false
            $result.GuardHeld | Should -BeTrue
            # gnhf's own failure is passed through, NOT rewritten as success.
            $result.ExitCode | Should -Be 42
            ($result.Lines -join ' ') | Should -BeLike '*guard held*'
        }
    }

    It 'still checks the checkout when gnhf itself failed' {
        # A failing run that moved the checkout is exactly the case that must be
        # seen, so the guard must not be skipped on a non-zero exit.
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess {
                & git -C $RepoPath checkout -q -b 'gnhf/failed-run'
                1
            }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'x' -Confirm:$false
            # Exit 3 wins over gnhf's 1: the moved checkout is the more urgent fact.
            $result.ExitCode | Should -Be 3
            $result.GuardHeld | Should -BeFalse
        }
    }

    It 'writes nothing and runs nothing under -WhatIf' {
        $repo = New-GnhfRepo
        InModuleScope Firstmate -Parameters @{ Repo = $repo } {
            Mock Invoke-FmGnhfProcess { throw 'must not run under -WhatIf' }
            $result = Invoke-FmGnhf -RepoPath $Repo -MaxIterations '5' -Objective 'x' -WhatIf
            $result.After | Should -BeNullOrEmpty
        }
    }
}
