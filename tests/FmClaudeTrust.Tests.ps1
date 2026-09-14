#requires -Version 7.0
# Pester tests for pre-registering Claude Code's workspace trust
# (Private/FmClaudeTrust.ps1).
#
# Every case runs against real git repositories and a STAGED store under
# TestDrive. CLAUDE_CONFIG_DIR is pointed at TestDrive for the whole file, so
# even a call that forgets -StorePath cannot reach the captain's own
# ~/.claude.json - and BeforeAll proves that before any case runs.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable repositories and stores. -WhatIf on a fixture would leave the test asserting against a store that was never staged.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' 'Private') -Filter '*.ps1' |
                Sort-Object Name)) {
        . $file.FullName
    }

    $script:SavedConfigDir = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = Join-Path $TestDrive 'claude-config'
    if (-not (Get-FmClaudeStorePath).StartsWith($TestDrive)) {
        throw 'the staged Claude store is not under TestDrive; refusing to run cases that write a store'
    }

    function Invoke-TestGit {
        param([Parameter(Mandatory)][string[]]$Arguments)
        $result = Invoke-FmChildProcess -FilePath 'git' -ArgumentList $Arguments
        if (-not $result.Ok) { throw "git $($Arguments -join ' ') failed: $($result.StdErr)" }
    }

    # A primary checkout with one commit and a linked worktree of it: the shape
    # treehouse leases.
    function New-TrustFixture {
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $checkout = Join-Path $root 'project'
        $worktree = Join-Path $root 'pool' 'slot-1' 'project'
        Invoke-TestGit @('init', '-q', '-b', 'main', $checkout)
        Invoke-TestGit @('-C', $checkout, '-c', 'user.email=t@example.invalid', '-c', 'user.name=t',
            'commit', '-q', '--allow-empty', '-m', 'root')
        Invoke-TestGit @('-C', $checkout, 'worktree', 'add', '-q', '-b', 'slot', $worktree)
        [pscustomobject]@{
            Checkout = $checkout
            Worktree = $worktree
            Key      = ConvertTo-FmClaudeProjectKey -Path (Resolve-FmPhysicalPath -Path $checkout)
            Store    = Join-Path $root 'store' '.claude.json'
        }
    }

    function Write-StoreText {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
    }

    function Read-StoreText {
        param([Parameter(Mandatory)][string]$Path)
        [System.Text.UTF8Encoding]::new($false).GetString([System.IO.File]::ReadAllBytes($Path))
    }

    # A store in the format Claude writes: two-space indentation, LF, no
    # trailing newline, and values a careless round trip would reformat.
    function New-VendorStoreText {
        param([Parameter(Mandatory)][string]$Key, [string]$TrustValue = 'false')
        $escaped = $Key -replace '\\', '\\'
        (@(
                '{'
                '  "numStartups": 428,'
                '  "firstStartTime": "2026-07-01T09:15:30.123Z",'
                '  "costRatio": 1.50,'
                '  "tipsHistory": {},'
                '  "note": "caf' + [char]0xE9 + ' <b> & \u0007",'
                '  "projects": {'
                '    "C:/Users/someone/other": {'
                '      "allowedTools": [],'
                '      "hasTrustDialogAccepted": true'
                '    },'
                "    `"$escaped`": {"
                '      "allowedTools": [],'
                '      "lastCost": 0.0421,'
                "      `"hasTrustDialogAccepted`": $TrustValue,"
                '      "hasClaudeMdExternalIncludesApproved": false'
                '    }'
                '  },'
                '  "userID": "abc"'
                '}'
            ) -join "`n")
    }
}

AfterAll {
    $env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
}

Describe 'Register-FmClaudeWorkspaceTrust' {
    BeforeEach {
        Mock Start-Sleep { }
        $script:fx = New-TrustFixture
    }

    It "records the flag on the checkout's entry, the key Claude files a worktree session under" {
        $result = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false
        $result.Outcome | Should -Be 'registered'
        $result.ProjectKey | Should -Be $script:fx.Key
        if ($IsWindows) { $result.ProjectKey | Should -Not -Match '\\' }

        $store = Read-StoreText -Path $script:fx.Store | ConvertFrom-Json -AsHashtable
        $store.projects.Keys | Should -Be @($script:fx.Key)
        $store.projects[$script:fx.Key].hasTrustDialogAccepted | Should -BeTrue
    }

    It 'changes that one value and not another byte of a store Claude wrote' {
        Write-StoreText -Path $script:fx.Store -Text (New-VendorStoreText -Key $script:fx.Key)
        $null = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false
        Read-StoreText -Path $script:fx.Store | Should -BeExactly (New-VendorStoreText -Key $script:fx.Key -TrustValue 'true')
    }

    It 'keeps a trailing newline when the store had one' {
        Write-StoreText -Path $script:fx.Store -Text ((New-VendorStoreText -Key $script:fx.Key) + "`n")
        $null = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false
        Read-StoreText -Path $script:fx.Store |
            Should -BeExactly ((New-VendorStoreText -Key $script:fx.Key -TrustValue 'true') + "`n")
    }

    It 'adds the entry beside the others when the checkout has none yet' {
        Write-StoreText -Path $script:fx.Store -Text "{`n  `"projects`": {`n    `"C:/elsewhere`": {`n      `"x`": 1`n    }`n  }`n}"
        $null = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false
        $store = Read-StoreText -Path $script:fx.Store | ConvertFrom-Json -AsHashtable
        $store.projects['C:/elsewhere'].x | Should -Be 1
        $store.projects[$script:fx.Key].hasTrustDialogAccepted | Should -BeTrue
    }

    It 'never writes a store whose entry is already trusted' {
        $text = New-VendorStoreText -Key $script:fx.Key -TrustValue 'true'
        Write-StoreText -Path $script:fx.Store -Text $text
        $stamp = [datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($script:fx.Store, $stamp)
        (Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false).Outcome |
            Should -Be 'already-trusted'
        Read-StoreText -Path $script:fx.Store | Should -BeExactly $text
        [System.IO.File]::GetLastWriteTimeUtc($script:fx.Store) | Should -Be $stamp
    }

    It 'never writes or reads the external-imports consent upstream carries' {
        # On this machine every entry holds that flag at false; upstream reads
        # false as a decline and refuses the spawn, which would refuse them all.
        Write-StoreText -Path $script:fx.Store -Text (New-VendorStoreText -Key $script:fx.Key)
        (Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false).Outcome |
            Should -Be 'registered'
        $entry = (Read-StoreText -Path $script:fx.Store | ConvertFrom-Json -AsHashtable).projects[$script:fx.Key]
        $entry.hasClaudeMdExternalIncludesApproved | Should -BeFalse
        $entry.ContainsKey('hasClaudeMdExternalIncludesWarningShown') | Should -BeFalse
    }

    It 'writes the store CLAUDE_CONFIG_DIR names when no path is given, because the launch forwards it' {
        $result = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -Confirm:$false
        $result.Store | Should -Be (Join-Path $env:CLAUDE_CONFIG_DIR '.claude.json')
        Test-Path -LiteralPath $result.Store | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
        $text = New-VendorStoreText -Key $script:fx.Key
        Write-StoreText -Path $script:fx.Store -Text $text
        $null = Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -WhatIf
        Read-StoreText -Path $script:fx.Store | Should -BeExactly $text
    }

    Context 'the scope test' {
        BeforeEach {
            $script:seed = New-VendorStoreText -Key $script:fx.Key
            Write-StoreText -Path $script:fx.Store -Text $script:seed
        }

        It 'refuses <Name> and leaves the store untouched' -ForEach @(
            @{ Name = 'the primary checkout'; Pick = { $script:fx.Checkout }; Reason = '*is a primary checkout*' }
            @{ Name = 'a subdirectory of the worktree'; Reason = '*is not a worktree root*'
                Pick = { $d = Join-Path $script:fx.Worktree 'sub'; $null = New-Item -ItemType Directory $d -Force; $d } }
            @{ Name = 'a plain directory'; Reason = '*is not inside a git repository*'
                Pick = { $d = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName()); $null = New-Item -ItemType Directory $d; $d } }
            @{ Name = 'a path that does not exist'; Pick = { Join-Path $TestDrive 'nowhere' }; Reason = '*not an accessible directory*' }
        ) {
            $target = & $Pick
            { Register-FmClaudeWorkspaceTrust -Worktree $target -StorePath $script:fx.Store -Confirm:$false } |
                Should -Throw $Reason
            Read-StoreText -Path $script:fx.Store | Should -BeExactly $script:seed
        }

        It 'refuses a worktree of a bare repository, which has no checkout for Claude to map it to' {
            $bare = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName() + '.git')
            Invoke-TestGit @('clone', '-q', '--bare', $script:fx.Checkout, $bare)
            $linked = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            Invoke-TestGit @('-C', $bare, 'worktree', 'add', '-q', $linked, 'main')
            { Register-FmClaudeWorkspaceTrust -Worktree $linked -StorePath $script:fx.Store -Confirm:$false } |
                Should -Throw "*which is not a checkout's .git directory*"
            Read-StoreText -Path $script:fx.Store | Should -BeExactly $script:seed
        }

        It 'refuses a checkout that is the Claude config directory itself' {
            $saved = $env:CLAUDE_CONFIG_DIR
            try {
                $env:CLAUDE_CONFIG_DIR = Resolve-FmPhysicalPath -Path $script:fx.Checkout
                { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false } |
                    Should -Throw '*is the Claude config directory*'
            } finally {
                $env:CLAUDE_CONFIG_DIR = $saved
            }
        }

        It 'refuses a relative CLAUDE_CONFIG_DIR, which would name a different store inside the pane' {
            $saved = $env:CLAUDE_CONFIG_DIR
            try {
                $env:CLAUDE_CONFIG_DIR = 'relative\claude'
                { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -Confirm:$false } |
                    Should -Throw '*is a relative path*'
            } finally {
                $env:CLAUDE_CONFIG_DIR = $saved
            }
        }
    }

    Context 'a store that is not safe to rewrite' {
        It 'refuses a store that is not a JSON object, without rewriting it' {
            Write-StoreText -Path $script:fx.Store -Text '{ "projects": { truncated'
            { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Attempts 2 -Confirm:$false } |
                Should -Throw '*is not a JSON object*'
            Read-StoreText -Path $script:fx.Store | Should -BeExactly '{ "projects": { truncated'
        }

        It "refuses a store whose 'projects' is not an object" {
            Write-StoreText -Path $script:fx.Store -Text '{"projects":[]}'
            { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false } |
                Should -Throw "*'projects' value that is not an object*"
            Read-StoreText -Path $script:fx.Store | Should -BeExactly '{"projects":[]}'
        }
    }

    Context 'a store another Claude session is writing' {
        BeforeEach {
            $script:seed = New-VendorStoreText -Key $script:fx.Key
            Write-StoreText -Path $script:fx.Store -Text $script:seed
            $script:reads = 0
        }

        It 'keeps a vendor write that lands mid-registration, and records the flag on top of it' {
            # Read 1 is the edit's source; read 2 is the check before the rename,
            # and a live session rewrites the store just before it.
            Mock Read-FmClaudeStoreBytes {
                $script:reads++
                if ($script:reads -eq 2) {
                    Write-StoreText -Path $Path -Text ($script:seed -replace '"numStartups": 428', '"numStartups": 429')
                }
                , [System.IO.File]::ReadAllBytes($Path)
            }
            (Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Confirm:$false).Outcome |
                Should -Be 'registered'
            Read-StoreText -Path $script:fx.Store |
                Should -BeExactly ((New-VendorStoreText -Key $script:fx.Key -TrustValue 'true') -replace '"numStartups": 428', '"numStartups": 429')
        }

        It 'refuses rather than overwrite a store that keeps moving' {
            Mock Read-FmClaudeStoreBytes {
                $script:reads++
                if ($script:reads % 2 -eq 0) {
                    Write-StoreText -Path $Path -Text ($script:seed -replace '"numStartups": 428', "`"numStartups`": $($script:reads)")
                }
                , [System.IO.File]::ReadAllBytes($Path)
            }
            { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Attempts 3 -Confirm:$false } |
                Should -Throw '*was rewritten by another process*refusing to launch*'
            Read-StoreText -Path $script:fx.Store | Should -BeExactly ($script:seed -replace '"numStartups": 428', '"numStartups": 6')
            @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:fx.Store) -Force -Filter '*.fm-trust.*').Count | Should -Be 0
        }

        It 'refuses when a session rewrites the flag away straight after the rename' {
            Mock Read-FmClaudeStoreBytes {
                $script:reads++
                if ($script:reads % 3 -eq 0) { Write-StoreText -Path $Path -Text $script:seed }
                , [System.IO.File]::ReadAllBytes($Path)
            }
            { Register-FmClaudeWorkspaceTrust -Worktree $script:fx.Worktree -StorePath $script:fx.Store -Attempts 2 -Confirm:$false } |
                Should -Throw '*did not retain the trust flag*'
        }
    }
}
