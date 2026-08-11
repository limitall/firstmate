#requires -Version 7.0
# Pester 5+/6 tests for project add / create / remove and the registry writer.
#
# The registry tests assert ROUND-TRIP parity: every line this port writes is
# read back by the same parser that reads a Linux firstmate's registry, because
# a line that writes cleanly but parses differently is worse than a refusal.
#
# The removal preflight is tested against real repositories: "has unlanded
# work" is a property of an actual repository, and a mocked git would only
# prove the mock agrees with itself.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestRepo {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Path,
            [switch]$NoCommit
        )
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        $null = Invoke-FmChildProcess -FilePath 'git' -ArgumentList @('init', '-q', '-b', 'main', $Path)
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.email', 'test@example.invalid')
        $null = Invoke-FmGit -Directory $Path -Arguments @('config', 'user.name', 'Test')
        if (-not $NoCommit) {
            Set-Content -LiteralPath (Join-Path $Path 'README.md') -Value 'seed'
            $null = Invoke-FmGit -Directory $Path -Arguments @('add', '-A')
            $null = Invoke-FmGit -Directory $Path -Arguments @('commit', '-q', '-m', 'seed')
        }
        $Path
    }

    # A fixture home: <root>/{state,data,projects}, plus an upstream repo to
    # clone from so no test reaches the network.
    function New-TestHome {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param()
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'projects')) {
            New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
        }
        [pscustomobject]@{
            Root     = $root
            State    = Join-Path $root 'state'
            Data     = Join-Path $root 'data'
            Projects = Join-Path $root 'projects'
            Registry = Join-Path $root 'data/projects.md'
        }
    }
}

Describe 'the registry writer' {
    It 'writes a line the registry parser reads back identically' {
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'direct-PR' -Yolo 'on' `
            -Description 'the thing service' -Added '2026-08-12'
        $line | Should -Be '- thing [direct-PR +yolo] - the thing service (added 2026-08-12)'
        $parsed = Get-FmProjectRegistryLine -Line $line
        $parsed.Name | Should -Be 'thing'
        $parsed.Mode | Should -Be 'direct-PR'
        $parsed.Yolo | Should -Be 'on'
    }

    It 'omits the yolo marker when yolo is off' {
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'local-only' -Yolo 'off' -Description 'x' -Added '2026-01-01'
        $line | Should -Be '- thing [local-only] - x (added 2026-01-01)'
        (Get-FmProjectRegistryLine -Line $line).Yolo | Should -Be 'off'
    }

    It 'flattens a multi-line description, because a registry entry is one line' {
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'local-only' -Yolo 'off' `
            -Description "first`nsecond" -Added '2026-01-01'
        $line | Should -Be '- thing [local-only] - first second (added 2026-01-01)'
    }

    It 'creates the registry with its heading when the home has none' {
        $home_ = New-TestHome
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'local-only' -Yolo 'off' -Description 'x' -Added '2026-01-01'
        $null = Add-FmProjectRegistryEntry -RegistryPath $home_.Registry -Line $line
        @(Get-FmSessionFileLines -Path $home_.Registry) | Should -Be @('# Projects', '', $line)
    }

    It 'writes the registry LF-only with no BOM' {
        $home_ = New-TestHome
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'local-only' -Yolo 'off' -Description 'x' -Added '2026-01-01'
        $null = Add-FmProjectRegistryEntry -RegistryPath $home_.Registry -Line $line
        $bytes = [System.IO.File]::ReadAllBytes($home_.Registry)
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        ($bytes -contains 13) | Should -BeFalse
    }

    It 'refuses a second line for a project that is already registered' {
        $home_ = New-TestHome
        $line = New-FmProjectRegistryLine -Name 'thing' -Mode 'local-only' -Yolo 'off' -Description 'x' -Added '2026-01-01'
        $null = Add-FmProjectRegistryEntry -RegistryPath $home_.Registry -Line $line
        { Add-FmProjectRegistryEntry -RegistryPath $home_.Registry -Line $line } |
            Should -Throw '*is already in the registry*'
    }

    It 'removes exactly one project line and leaves every other byte alone' {
        $home_ = New-TestHome
        [System.IO.File]::WriteAllText($home_.Registry, (@(
            '# Projects',
            '',
            '- alpha [local-only] - a (added 2026-01-01)',
            '- beta [direct-PR] - b (added 2026-01-02)',
            '',
            'a trailing note'
        ) -join "`n") + "`n")
        Remove-FmProjectRegistryEntry -RegistryPath $home_.Registry -Name 'alpha' | Should -BeTrue
        @(Get-FmSessionFileLines -Path $home_.Registry) | Should -Be @(
            '# Projects', '', '- beta [direct-PR] - b (added 2026-01-02)', '', 'a trailing note')
    }

    It 'reports false rather than rewriting the file when the project has no line' {
        $home_ = New-TestHome
        [System.IO.File]::WriteAllText($home_.Registry, "# Projects`n")
        Remove-FmProjectRegistryEntry -RegistryPath $home_.Registry -Name 'ghost' | Should -BeFalse
    }
}

Describe 'Assert-FmProjectName' {
    It 'refuses names that would break the whitespace-delimited registry or escape the projects dir' {
        { Assert-FmProjectName -Name '' } | Should -Throw '*a project name is required*'
        { Assert-FmProjectName -Name 'two words' } | Should -Throw '*contains whitespace*'
        { Assert-FmProjectName -Name '../escape' } | Should -Throw '*contains a path separator*'
        { Assert-FmProjectName -Name '.hidden' } | Should -Throw "*starts with '.'*"
        { Assert-FmProjectName -Name '-' } | Should -Throw "*collides with the registry's own list marker*"
        Assert-FmProjectName -Name 'firstmate-win' | Should -BeTrue
    }
}

Describe 'Resolve-FmProjectPath and Get-FmProjectLabel' {
    It 'prefers this home''s projects dir for a bare name' {
        $home_ = New-TestHome
        $proj = Join-Path $home_.Projects 'thing'
        New-Item -ItemType Directory -Path $proj -Force | Out-Null
        Resolve-FmProjectPath -Argument 'thing' -ProjectsDir $home_.Projects | Should -Be $proj
        Resolve-FmProjectPath -Argument 'projects/thing' -ProjectsDir $home_.Projects | Should -Be $proj
    }

    It 'uses an existing path as-is' {
        $home_ = New-TestHome
        $elsewhere = Join-Path $home_.Root 'elsewhere/thing'
        New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
        Resolve-FmProjectPath -Argument $elsewhere -ProjectsDir $home_.Projects | Should -Be $elsewhere
    }

    It 'hands back an unresolvable argument unchanged, so a bad path still reaches the caller''s own skip' {
        $home_ = New-TestHome
        Resolve-FmProjectPath -Argument 'nope' -ProjectsDir $home_.Projects | Should -Be 'nope'
    }

    It 'labels a clone by its directory name inside the projects dir, and by path outside it' {
        $home_ = New-TestHome
        $proj = Join-Path $home_.Projects 'thing'
        Get-FmProjectLabel -Path $proj -ProjectsDir $home_.Projects | Should -Be 'thing'
        $outside = Join-Path $home_.Root 'elsewhere'
        Get-FmProjectLabel -Path $outside -ProjectsDir $home_.Projects | Should -Be $outside
    }
}

Describe 'Add-FmProject' {
    It 'clones the source and registers the posture' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        $result = Add-FmProject -Name 'thing' -Source $upstream -Mode 'local-only' -Description 'the thing' `
            -ProjectsDir $home_.Projects -RegistryPath $home_.Registry
        $result.Path | Should -Be (Join-Path $home_.Projects 'thing')
        Test-Path -LiteralPath (Join-Path $result.Path '.git') | Should -BeTrue
        (Get-FmProjectMode -Name 'thing' -RegistryPath $home_.Registry).Mode | Should -Be 'local-only'
    }

    It 'refuses a posture this port cannot deliver, before touching the disk' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        foreach ($mode in @('no-mistakes', 'no-mistakes-prod-only')) {
            { Add-FmProject -Name 'thing' -Source $upstream -Mode $mode -Description 'x' `
                    -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
                Should -Throw '*Windows port*'
        }
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
        Test-Path -LiteralPath $home_.Registry | Should -BeFalse
    }

    It 'refuses to overwrite or repurpose an existing destination' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        $occupied = Join-Path $home_.Projects 'thing'
        New-Item -ItemType Directory -Path $occupied -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $occupied 'keepme.txt') -Value 'precious'
        { Add-FmProject -Name 'thing' -Source $upstream -Mode 'local-only' -Description 'x' `
                -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*already exists; refusing to overwrite or repurpose it*'
        Test-Path -LiteralPath (Join-Path $occupied 'keepme.txt') | Should -BeTrue
    }

    It 'refuses a name that is already registered' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        [System.IO.File]::WriteAllText($home_.Registry, "# Projects`n`n- thing [local-only] - x (added 2026-01-01)`n")
        { Add-FmProject -Name 'thing' -Source $upstream -Mode 'local-only' -Description 'x' `
                -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*already in the registry*'
    }

    It 'rolls back the clone it created when registration fails' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        Mock Add-FmProjectRegistryEntry { throw 'registry write failed' }
        { Add-FmProject -Name 'thing' -Source $upstream -Mode 'local-only' -Description 'x' `
                -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*registry write failed*'
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
    }

    It 'refuses a direct-PR clone that has no origin remote, and rolls it back' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        Mock Invoke-FmGit {
            [pscustomobject]@{ Ok = $false; ExitCode = 2; StdOut = ''; StdErr = 'no origin'; Combined = ''; TimedOut = $false }
        } -ParameterFilter { $Arguments -contains 'get-url' }
        { Add-FmProject -Name 'thing' -Source $upstream -Mode 'direct-PR' -Description 'x' `
                -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*direct-PR project must have an origin remote*'
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
    }

    It 'reports the clone failure and leaves no partial destination' {
        $home_ = New-TestHome
        { Add-FmProject -Name 'thing' -Source (Join-Path $home_.Root 'not-a-repo') -Mode 'local-only' `
                -Description 'x' -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*could not clone*'
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
    }

    It 'changes nothing under -WhatIf' {
        $home_ = New-TestHome
        $upstream = New-TestRepo -Path (Join-Path $home_.Root 'upstream')
        Add-FmProject -Name 'thing' -Source $upstream -Mode 'local-only' -Description 'x' `
            -ProjectsDir $home_.Projects -RegistryPath $home_.Registry -WhatIf | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
        Test-Path -LiteralPath $home_.Registry | Should -BeFalse
    }
}

Describe 'New-FmProject' {
    It 'creates a local repository and registers it' {
        $home_ = New-TestHome
        $result = New-FmProject -Name 'notes' -Description 'captain notes' `
            -ProjectsDir $home_.Projects -RegistryPath $home_.Registry
        Test-Path -LiteralPath (Join-Path $result.Path '.git') | Should -BeTrue
        (Get-FmProjectMode -Name 'notes' -RegistryPath $home_.Registry).Mode | Should -Be 'local-only'
        Get-FmGitOutput -Directory $result.Path -Arguments @('symbolic-ref', '--short', 'HEAD') | Should -Be 'main'
    }

    It 'never creates a remote repository: any posture needing one is refused with the consent path' {
        $home_ = New-TestHome
        { New-FmProject -Name 'thing' -Mode 'direct-PR' -Description 'x' `
                -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw "*only creates local-only projects*"
        Test-Path -LiteralPath (Join-Path $home_.Projects 'thing') | Should -BeFalse
    }

    It 'refuses an existing destination and an already-registered name' {
        $home_ = New-TestHome
        New-Item -ItemType Directory -Path (Join-Path $home_.Projects 'taken') -Force | Out-Null
        { New-FmProject -Name 'taken' -Description 'x' -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*already exists*'
        [System.IO.File]::WriteAllText($home_.Registry, "# Projects`n`n- listed [local-only] - x (added 2026-01-01)`n")
        { New-FmProject -Name 'listed' -Description 'x' -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*already in the registry*'
    }

    It 'rolls back the directory it created when registration fails' {
        $home_ = New-TestHome
        Mock Add-FmProjectRegistryEntry { throw 'registry write failed' }
        { New-FmProject -Name 'notes' -Description 'x' -ProjectsDir $home_.Projects -RegistryPath $home_.Registry } |
            Should -Throw '*registry write failed*'
        Test-Path -LiteralPath (Join-Path $home_.Projects 'notes') | Should -BeFalse
    }
}

Describe 'Test-FmProjectRemovable' {
    BeforeEach {
        $script:fixture = New-TestHome
        $script:clone = New-TestRepo -Path (Join-Path $script:fixture.Projects 'thing')
    }

    It 'clears a clean clone whose work is all merged' {
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeTrue
        $verdict.Blockers | Should -BeNullOrEmpty
    }

    It 'blocks on a task still recorded against the clone' {
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.State 'live.meta'),
            "id=live`nproject=$($script:clone)`nkind=ship`n")
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        $verdict.Blockers | Should -Contain "task live is still recorded against this project ($(Join-Path $script:fixture.State 'live.meta')); tear it down first"
    }

    It 'blocks on a second mate that still references the project' {
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.Data 'secondmates.md'),
            "# Second mates`n`n- mate-1 - scope: everything about thing`n")
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        ($verdict.Blockers -join ' ') | Should -BeLike '*secondmates.md still references this project*'
    }

    It 'blocks on a linked worktree' {
        $wt = Join-Path $script:fixture.Root 'linked'
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('worktree', 'add', '-q', '-b', 'side', $wt)
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        ($verdict.Blockers -join ' ') | Should -BeLike '*linked worktree(s) still exist*'
    }

    It 'blocks on uncommitted changes' {
        Set-Content -LiteralPath (Join-Path $script:clone 'scratch.txt') -Value 'work in progress'
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Blockers | Should -Contain 'uncommitted changes present in the clone'
    }

    It 'blocks a remote-backed clone on commits that are on no remote' {
        $upstream = New-TestRepo -Path (Join-Path $script:fixture.Root 'upstream')
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('remote', 'add', 'origin', $upstream)
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('fetch', '-q', 'origin')
        Set-Content -LiteralPath (Join-Path $script:clone 'local.txt') -Value 'local only'
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('commit', '-q', '-m', 'unpushed')
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        ($verdict.Blockers -join ' ') | Should -BeLike '*commits not on any remote*'
    }

    It 'blocks a clone with no remote on branches not merged into its default branch' {
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('checkout', '-q', '-b', 'unlanded')
        Set-Content -LiteralPath (Join-Path $script:clone 'work.txt') -Value 'unlanded work'
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('add', '-A')
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('commit', '-q', '-m', 'unlanded')
        $null = Invoke-FmGit -Directory $script:clone -Arguments @('checkout', '-q', 'main')
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        ($verdict.Blockers -join ' ') | Should -BeLike '*not merged into main: unlanded*'
    }

    It 'does not report work for a repository that has no commits at all' {
        $null = New-TestRepo -Path (Join-Path $script:fixture.Projects 'fresh') -NoCommit
        $verdict = Test-FmProjectRemovable -Name 'fresh' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeTrue
    }

    It 'blocks a directory that is not a git repository at all' {
        New-Item -ItemType Directory -Path (Join-Path $script:fixture.Projects 'notrepo') -Force | Out-Null
        $verdict = Test-FmProjectRemovable -Name 'notrepo' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        $verdict.Removable | Should -BeFalse
        ($verdict.Blockers -join ' ') | Should -BeLike '*is not a git repository*'
    }

    It 'reports every blocker at once rather than stopping at the first' {
        Set-Content -LiteralPath (Join-Path $script:clone 'scratch.txt') -Value 'dirty'
        [System.IO.File]::WriteAllText((Join-Path $script:fixture.State 'live.meta'),
            "id=live`nproject=$($script:clone)`n")
        $verdict = Test-FmProjectRemovable -Name 'thing' -ProjectsDir $script:fixture.Projects `
            -StateDir $script:fixture.State -DataDir $script:fixture.Data
        @($verdict.Blockers).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'Remove-FmProject' {
    BeforeEach {
        $script:fixture = New-TestHome
        $script:clone = New-TestRepo -Path (Join-Path $script:fixture.Projects 'thing')
        [System.IO.File]::WriteAllText($script:fixture.Registry,
            "# Projects`n`n- thing [local-only] - the thing (added 2026-01-01)`n")
    }

    It 'refuses without the captain''s explicit removal decision' {
        { Remove-FmProject -Name 'thing' -ProjectsDir $script:fixture.Projects -RegistryPath $script:fixture.Registry `
                -StateDir $script:fixture.State -DataDir $script:fixture.Data -Confirm:$false } |
            Should -Throw '*needs the captain*explicit removal decision*'
        Test-Path -LiteralPath $script:clone | Should -BeTrue
    }

    It 'removes the clone and its registry entry once approved and clear' {
        $result = Remove-FmProject -Name 'thing' -Approved -ProjectsDir $script:fixture.Projects `
            -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State -DataDir $script:fixture.Data -Confirm:$false
        $result.RemovedClone | Should -BeTrue
        $result.RemovedEntry | Should -BeTrue
        Test-Path -LiteralPath $script:clone | Should -BeFalse
        @(Get-FmProjectRegistryEntry -RegistryPath $script:fixture.Registry).Count | Should -Be 0
    }

    It 'refuses when the preflight finds unlanded work, even with -Approved' {
        Set-Content -LiteralPath (Join-Path $script:clone 'scratch.txt') -Value 'work in progress'
        { Remove-FmProject -Name 'thing' -Approved -ProjectsDir $script:fixture.Projects `
                -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State `
                -DataDir $script:fixture.Data -Confirm:$false } |
            Should -Throw '*REFUSED*uncommitted changes present*'
        Test-Path -LiteralPath $script:clone | Should -BeTrue
        @(Get-FmProjectRegistryEntry -RegistryPath $script:fixture.Registry).Count | Should -Be 1
    }

    It 'reconciles a stale registry entry when the clone is already gone' {
        Remove-Item -LiteralPath $script:clone -Recurse -Force
        $result = Remove-FmProject -Name 'thing' -Approved -ProjectsDir $script:fixture.Projects `
            -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State -DataDir $script:fixture.Data -Confirm:$false
        $result.RemovedClone | Should -BeFalse
        $result.RemovedEntry | Should -BeTrue
        $result.Message | Should -BeLike '*its clone was already gone*'
    }

    It 'refuses when there is neither a clone nor a registry entry' {
        { Remove-FmProject -Name 'ghost' -Approved -ProjectsDir $script:fixture.Projects `
                -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State `
                -DataDir $script:fixture.Data -Confirm:$false } |
            Should -Throw '*no clone at*and no entry in*'
    }

    It 'keeps the registry pointing at what is on disk when the delete is refused' {
        Mock Remove-FmProjectDirectory { throw 'error: could not remove; a process holds a handle in it' }
        { Remove-FmProject -Name 'thing' -Approved -ProjectsDir $script:fixture.Projects `
                -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State `
                -DataDir $script:fixture.Data -Confirm:$false } |
            Should -Throw '*holds a handle*'
        @(Get-FmProjectRegistryEntry -RegistryPath $script:fixture.Registry).Count | Should -Be 1
    }

    It 'changes nothing under -WhatIf' {
        Remove-FmProject -Name 'thing' -Approved -ProjectsDir $script:fixture.Projects `
            -RegistryPath $script:fixture.Registry -StateDir $script:fixture.State `
            -DataDir $script:fixture.Data -WhatIf | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:clone | Should -BeTrue
        @(Get-FmProjectRegistryEntry -RegistryPath $script:fixture.Registry).Count | Should -Be 1
    }
}
