#requires -Version 7.0
<#
    Tests for Private/FmPaths.ps1 - home resolution and the layout.

    The precedence rules here are the ones every other area inherits, so they are
    tested against the bash originals rather than against what the code happens
    to do: FM_HOME then FM_ROOT_OVERRIDE then the code root, with
    FM_STATE_OVERRIDE able to move state/ alone.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force

    $script:EnvNames = @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE')
    $script:SavedEnv = @{}
    foreach ($name in $script:EnvNames) {
        $script:SavedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, $null)
    }

    $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fmpaths-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force
}

AfterAll {
    foreach ($name in $script:EnvNames) {
        [System.Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name])
    }
    if (Test-Path -LiteralPath $script:TempRoot) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Pester 6 forbids a teardown directly in the container root, so every block
# that touches the environment starts from a known-clean one instead.
Describe 'Resolve-FmFullPath' {
    It 'makes a relative path absolute against the real filesystem location' {
        Resolve-FmFullPath -Path 'state' | Should -Be (Join-Path $PWD.ProviderPath 'state')
    }

    It 'normalizes traversal segments' {
        $expected = Join-Path (Split-Path -Parent $script:TempRoot) 'sibling'
        Resolve-FmFullPath -Path (Join-Path $script:TempRoot '..' 'sibling') | Should -Be $expected
    }

    It 'trims a trailing separator so two spellings of one directory compare equal' {
        $withSeparator = $script:TempRoot + [System.IO.Path]::DirectorySeparatorChar
        Resolve-FmFullPath -Path $withSeparator | Should -Be (Resolve-FmFullPath -Path $script:TempRoot)
    }

    It 'keeps the separator on a filesystem root' {
        $root = [System.IO.Path]::GetPathRoot($script:TempRoot)
        Resolve-FmFullPath -Path $root | Should -Be $root
    }

    It 'resolves a path that does not exist yet' {
        $missing = Join-Path $script:TempRoot 'not-created-yet' 'file.meta'
        Resolve-FmFullPath -Path $missing | Should -Be $missing
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'rejects an empty path' {
        { Resolve-FmFullPath -Path '  ' } | Should -Throw
    }
}

Describe 'Get-FmHome precedence' {
    BeforeEach { foreach ($name in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($name, $null) } }

    It 'uses FM_HOME when set' {
        $env:FM_HOME = $script:TempRoot
        $env:FM_ROOT_OVERRIDE = Join-Path $script:TempRoot 'other'
        Get-FmHome | Should -Be $script:TempRoot
    }

    It 'falls back to FM_ROOT_OVERRIDE when FM_HOME is unset' {
        $env:FM_ROOT_OVERRIDE = $script:TempRoot
        Get-FmHome | Should -Be $script:TempRoot
    }

    It 'falls back to the code root when neither is set' {
        Get-FmHome | Should -Be (Get-FmRoot)
    }

    It 'treats an empty environment variable as unset, like ${VAR:-default} in bash' {
        $env:FM_HOME = ''
        $env:FM_ROOT_OVERRIDE = $script:TempRoot
        Get-FmHome | Should -Be $script:TempRoot
    }

    It 'resolves a relative FM_HOME to an absolute path' {
        $env:FM_HOME = '.'
        Get-FmHome | Should -Be $PWD.ProviderPath
    }
}

Describe 'Get-FmRoot' {
    BeforeEach { foreach ($name in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($name, $null) } }

    It 'is the repository containing the module, not the module directory' {
        $root = Get-FmRoot
        Test-Path -LiteralPath (Join-Path $root 'module' 'Firstmate' 'Firstmate.psd1') | Should -BeTrue
    }

    It 'honours FM_ROOT_OVERRIDE' {
        $env:FM_ROOT_OVERRIDE = $script:TempRoot
        Get-FmRoot | Should -Be $script:TempRoot
    }

    It 'stays the code root even when FM_HOME points elsewhere' {
        $expected = Get-FmRoot
        $env:FM_HOME = $script:TempRoot
        Get-FmRoot | Should -Be $expected
    }
}

Describe 'Layout directories' {
    BeforeEach {
        foreach ($name in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($name, $null) }
        $env:FM_HOME = $script:TempRoot
    }

    It 'derives state, data, config and projects from the home' {
        Get-FmStateRoot | Should -Be (Join-Path $script:TempRoot 'state')
        Get-FmDataRoot | Should -Be (Join-Path $script:TempRoot 'data')
        Get-FmConfigRoot | Should -Be (Join-Path $script:TempRoot 'config')
        Get-FmProjectsRoot | Should -Be (Join-Path $script:TempRoot 'projects')
    }

    It 'lets FM_STATE_OVERRIDE move state/ on its own' {
        $elsewhere = Join-Path $script:TempRoot 'elsewhere-state'
        $env:FM_STATE_OVERRIDE = $elsewhere
        Get-FmStateRoot | Should -Be $elsewhere
        # data/, config/ and projects/ still follow the home.
        Get-FmDataRoot | Should -Be (Join-Path $script:TempRoot 'data')
    }

    It 'ignores FM_STATE_OVERRIDE when a specific home is named' {
        # An explicit home is a request for THAT home's state - a secondmate
        # home, a test home - and an ambient override must not redirect it.
        $env:FM_STATE_OVERRIDE = Join-Path $script:TempRoot 'elsewhere-state'
        $other = Join-Path $script:TempRoot 'home-b'
        Get-FmStateRoot -HomePath $other | Should -Be (Join-Path $other 'state')
    }

    It 'reports every directory in one layout object' {
        $layout = Get-FmHomeLayout
        $layout.Home | Should -Be $script:TempRoot
        $layout.State | Should -Be (Join-Path $script:TempRoot 'state')
        $layout.Projects | Should -Be (Join-Path $script:TempRoot 'projects')
        $layout.Root | Should -Be (Get-FmRoot)
    }
}

Describe 'Get-FmPath' {
    BeforeEach {
        foreach ($name in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($name, $null) }
        $env:FM_HOME = $script:TempRoot
    }

    It 'returns the bare directory with no child path' {
        Get-FmPath -Kind State | Should -Be (Join-Path $script:TempRoot 'state')
    }

    It 'composes child segments' {
        Get-FmPath -Kind State -ChildPath '.wake-queue' |
            Should -Be (Join-Path $script:TempRoot 'state' '.wake-queue')
        Get-FmPath -Kind Data -ChildPath @('task-1', 'brief.md') |
            Should -Be (Join-Path $script:TempRoot 'data' 'task-1' 'brief.md')
    }

    It 'refuses an absolute child segment rather than silently escaping the home' {
        $absolute = Join-Path $script:TempRoot 'escape'
        { Get-FmPath -Kind State -ChildPath $absolute } | Should -Throw '*absolute*'
    }

    It 'exposes the same answers as the per-kind helpers' {
        Get-FmStatePath -Name 'x.meta' | Should -Be (Get-FmPath -Kind State -ChildPath 'x.meta')
        Get-FmDataPath -Name 'backlog.md' | Should -Be (Get-FmPath -Kind Data -ChildPath 'backlog.md')
        Get-FmConfigPath -Name 'crew-harness' | Should -Be (Get-FmPath -Kind Config -ChildPath 'crew-harness')
        Get-FmProjectPath -Name 'firstmate-win' | Should -Be (Get-FmPath -Kind Projects -ChildPath 'firstmate-win')
    }
}

Describe 'Test-FmTaskId' {
    It 'accepts the bash charset [A-Za-z0-9._-]' -ForEach @(
        @{ Id = 'fmwin-foundation' }
        @{ Id = 'task1' }
        @{ Id = 'a.b_c-d' }
        @{ Id = '2026-08-12.run' }
    ) {
        Test-FmTaskId -TaskId $Id | Should -BeTrue
    }

    It 'rejects <Id> because <Reason>' -ForEach @(
        @{ Id = ''; Reason = 'it is empty' }
        @{ Id = '.'; Reason = 'it is the current directory' }
        @{ Id = '..'; Reason = 'it is directory traversal' }
        @{ Id = 'task.'; Reason = 'Windows silently strips a trailing dot, aliasing two ids onto one file' }
        @{ Id = 'a/b'; Reason = 'it contains a path separator' }
        @{ Id = 'a\b'; Reason = 'it contains a Windows path separator' }
        @{ Id = 'a b'; Reason = 'it contains a space' }
        @{ Id = 'a:b'; Reason = 'a colon is an alternate data stream on Windows' }
        @{ Id = 'tache-lettré'; Reason = 'it is outside the ASCII charset bash validates' }
    ) {
        Test-FmTaskId -TaskId $Id | Should -BeFalse
    }
}

Describe 'Get-FmTaskStatePath' {
    BeforeEach {
        foreach ($name in $script:EnvNames) { [System.Environment]::SetEnvironmentVariable($name, $null) }
        $env:FM_HOME = $script:TempRoot
    }

    It 'composes state/<id>.<suffix>' {
        Get-FmTaskStatePath -TaskId 'task-1' -Suffix 'meta' |
            Should -Be (Join-Path $script:TempRoot 'state' 'task-1.meta')
    }

    It 'accepts a suffix written with a leading dot' {
        Get-FmTaskStatePath -TaskId 'task-1' -Suffix '.status' |
            Should -Be (Join-Path $script:TempRoot 'state' 'task-1.status')
    }

    It 'refuses an invalid task id' {
        { Get-FmTaskStatePath -TaskId '../escape' -Suffix 'meta' } | Should -Throw '*invalid task id*'
    }

    It 'refuses a suffix that is a path' {
        { Get-FmTaskStatePath -TaskId 'task-1' -Suffix 'meta/../../etc' } | Should -Throw '*suffix*'
    }
}

Describe 'Initialize-FmHome' {
    # $home is deliberately not used as a local here: PowerShell's $HOME is
    # read-only, which is the same reason the parameter is spelled -HomePath.
    It 'creates the four layout directories and is idempotent' {
        $homeDir = Join-Path $script:TempRoot ('init-' + [guid]::NewGuid().ToString('N'))
        $layout = Initialize-FmHome -HomePath $homeDir
        foreach ($dir in @($layout.State, $layout.Data, $layout.Config, $layout.Projects)) {
            Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
        }

        $marker = Join-Path $layout.State 'keep.txt'
        Set-Content -LiteralPath $marker -Value 'keep' -NoNewline
        $null = Initialize-FmHome -HomePath $homeDir
        Get-Content -LiteralPath $marker -Raw | Should -Be 'keep'
    }

    It 'creates nothing under -WhatIf' {
        $homeDir = Join-Path $script:TempRoot ('whatif-' + [guid]::NewGuid().ToString('N'))
        $null = Initialize-FmHome -HomePath $homeDir -WhatIf
        Test-Path -LiteralPath $homeDir | Should -BeFalse
    }
}
