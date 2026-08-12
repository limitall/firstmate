#requires -Version 7.0
<#
    Pester tests for the worktree-tangle detector.

    These run against REAL git repositories created under the temp directory,
    because the property is about what a real checkout's HEAD and git dirs say. A
    mocked git would only prove the mock agrees with itself - and the one case
    that matters most here (a linked worktree on a named branch) is precisely a
    fact about real git plumbing.

    The alarm itself already lives in Public/FmGuard.ps1; what was missing was
    anything to answer its seam. So the last Describe checks the seam end to end:
    the banner a captain actually sees.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes and repos. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($area in @('Private', 'Public')) {
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'module' 'Firstmate' $area) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }

    function Invoke-TestGit {
        param([string]$Directory, [string[]]$Arguments)
        $null = Invoke-FmBoundedCommand -FilePath 'git' `
            -ArgumentList (@('-C', $Directory) + $Arguments) -TimeoutSeconds 120
    }

    function New-TestRepo {
        <# A primary checkout: its own git dir, on its default branch, with a commit. #>
        param([switch]$NoCommit)
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-tangle-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $path -Force
        $null = Invoke-FmBoundedCommand -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $path) -TimeoutSeconds 120
        Invoke-TestGit -Directory $path -Arguments @('config', 'user.email', 'test@example.invalid')
        Invoke-TestGit -Directory $path -Arguments @('config', 'user.name', 'Test')
        if (-not $NoCommit) {
            Set-FmFileTextLf -Path (Join-Path $path 'README.md') -Text "seed`n"
            Invoke-TestGit -Directory $path -Arguments @('add', '-A')
            Invoke-TestGit -Directory $path -Arguments @('commit', '-q', '-m', 'seed')
        }
        return $path
    }

    function Remove-TestRepo {
        param([string[]]$Path)
        foreach ($p in $Path) {
            if ($p -and (Test-Path -LiteralPath $p)) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Get-FmPrimaryTangleBranch' {
    It 'stays silent for a primary checkout on its default branch' {
        $repo = New-TestRepo
        try { Get-FmPrimaryTangleBranch -Root $repo | Should -Be '' }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'names the branch when the primary is stranded on a feature branch' {
        $repo = New-TestRepo
        try {
            Invoke-TestGit -Directory $repo -Arguments @('checkout', '-q', '-b', 'fm/readme-restructure-d3')
            Get-FmPrimaryTangleBranch -Root $repo | Should -Be 'fm/readme-restructure-d3'
        }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'stays silent on a detached HEAD' {
        $repo = New-TestRepo
        try {
            Invoke-TestGit -Directory $repo -Arguments @('checkout', '-q', '--detach')
            Get-FmPrimaryTangleBranch -Root $repo | Should -Be ''
        }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'stays silent in a LINKED worktree on a named branch' {
        # The case that makes this port differ from the bash rule: a crewmate
        # here works on a named branch inside a linked worktree, which is the
        # correct state, not the tangle. Keying only on detached HEAD would fire
        # the alarm inside every crewmate.
        $repo = New-TestRepo
        $linked = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-tangle-wt-' + [Guid]::NewGuid().ToString('N'))
        try {
            Invoke-TestGit -Directory $repo -Arguments @('worktree', 'add', '-q', '-b', 'fm/crewmate-task', $linked)
            (Get-FmGitOutput -Directory $linked -Arguments @('symbolic-ref', '--short', 'HEAD')) |
                Should -Be 'fm/crewmate-task' -Because 'the fixture must really be on a named branch'

            Get-FmPrimaryTangleBranch -Root $linked | Should -Be ''
        }
        finally {
            Remove-TestRepo -Path @($linked, $repo)
        }
    }

    It 'stays silent for a directory that is not a git work tree' {
        $plain = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-plain-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $plain -Force
        try { Get-FmPrimaryTangleBranch -Root $plain | Should -Be '' }
        finally { Remove-TestRepo -Path $plain }
    }

    It 'stays silent for a fresh repository that has no default branch yet' {
        # git init with no commit: HEAD names a branch that does not exist. There
        # is nothing to compare against, so there is nothing to alarm about.
        $repo = New-TestRepo -NoCommit
        try { Get-FmPrimaryTangleBranch -Root $repo | Should -Be '' }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'stays silent for a path that does not exist at all' {
        Get-FmPrimaryTangleBranch -Root (Join-Path ([System.IO.Path]::GetTempPath()) 'fm-nowhere-at-all') | Should -Be ''
        Get-FmPrimaryTangleBranch -Root '' | Should -Be ''
    }

    It 'binds both ways its two callers use' {
        # Public/FmGuard.ps1 calls the seam positionally; Private/FmBootstrap.ps1
        # calls it with -Root. Both must keep working.
        $repo = New-TestRepo
        try {
            Invoke-TestGit -Directory $repo -Arguments @('checkout', '-q', '-b', 'fm/tangled')
            (Get-FmPrimaryTangleBranch $repo) | Should -Be 'fm/tangled'
            (Get-FmPrimaryTangleBranch -Root $repo) | Should -Be 'fm/tangled'
            (Get-FmDefaultBranch $repo) | Should -Be 'main'
            (Get-FmDefaultBranch -Root $repo) | Should -Be 'main'
        }
        finally { Remove-TestRepo -Path $repo }
    }
}

Describe 'Get-FmDefaultBranch' {
    It 'reports the local default branch' {
        $repo = New-TestRepo
        try { Get-FmDefaultBranch -Root $repo | Should -Be 'main' }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'reports empty when git cannot say, so the guard falls back to its own default' {
        $plain = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-plain-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $plain -Force
        try { Get-FmDefaultBranch -Root $plain | Should -Be '' }
        finally { Remove-TestRepo -Path $plain }
    }
}

Describe 'the guard alarm this owner switches on' {
    It 'raises the WORKTREE TANGLE banner now that the seam has an owner' {
        $repo = New-TestRepo
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $repo 'state') -Force
            Invoke-TestGit -Directory $repo -Arguments @('checkout', '-q', '-b', 'fm/tangled')

            # Out of process, because the banner goes to the real stderr - which
            # is the channel every harness surfaces in tool output.
            $script = Join-Path $repo 'guard.ps1'
            Set-FmFileTextLf -Path $script -Text @"
Import-Module '$(Join-Path $script:RepoRoot 'module' 'Firstmate' 'Firstmate.psd1')' -Force
exit (Invoke-FmGuard)
"@
            $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script) -TimeoutSeconds 120 `
                -Environment @{ FM_ROOT_OVERRIDE = $repo; FM_HOME = $repo; FM_STATE_OVERRIDE = (Join-Path $repo 'state') }

            $r.ExitCode | Should -Be 0 -Because 'the guard warns, it never blocks'
            $r.StdErr | Should -Match 'WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH'
            $r.StdErr | Should -Match "is on 'fm/tangled', not its default branch 'main'"
            $r.StdErr | Should -Match 'git -C .* checkout main'
        }
        finally { Remove-TestRepo -Path $repo }
    }

    It 'stays silent for a healthy primary checkout' {
        $repo = New-TestRepo
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $repo 'state') -Force
            $script = Join-Path $repo 'guard.ps1'
            Set-FmFileTextLf -Path $script -Text @"
Import-Module '$(Join-Path $script:RepoRoot 'module' 'Firstmate' 'Firstmate.psd1')' -Force
exit (Invoke-FmGuard)
"@
            $r = Invoke-FmBoundedCommand -FilePath $script:Pwsh `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script) -TimeoutSeconds 120 `
                -Environment @{ FM_ROOT_OVERRIDE = $repo; FM_HOME = $repo; FM_STATE_OVERRIDE = (Join-Path $repo 'state') }

            $r.ExitCode | Should -Be 0
            $r.StdErr | Should -Not -Match 'WORKTREE TANGLE'
        }
        finally { Remove-TestRepo -Path $repo }
    }
}
