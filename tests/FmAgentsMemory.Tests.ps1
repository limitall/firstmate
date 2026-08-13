#requires -Version 7.0
# Pester 5+/6 tests for the project agent-memory file convention.
#
# The created-file bytes are pinned, not just their shape: the skeleton and the
# maintenance section this port writes were diffed against
# bin/fm-ensure-agents-md.sh's output on the same empty directory and are
# byte-identical, so a project memory file written by a Windows crewmate and one
# written by a Linux crewmate are the same file.
#
# Every conflict is tested. These refusals are the reason the command is safe to
# run in any worktree at any time.

BeforeAll {
    . (Join-Path $PSScriptRoot 'FmSymlink.TestHelpers.ps1')

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:ModuleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestDir {
        # A Pester fixture builder: it writes only into TestDrive.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'A Pester fixture builder: it writes only into TestDrive.')]
        [CmdletBinding()]
        param()
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Resolve-FmPhysicalPath -Path $dir
    }

    # THE CONTRACT, not the mechanism that satisfies it: after Set-FmAgentsMemory
    # both names must resolve to the same content. Which mechanism produced that
    # is the host's business - a symlink where the privilege is held, a hardlink
    # on a stock non-elevated Windows shell, a copy where neither works - and
    # New-FmAgentsClaudeLink deliberately falls through all three.
    #
    # Two tests here asserted Test-FmAgentsClaudeLink, which is TRUE ONLY FOR A
    # SYMLINK. They were red on the captain's laptop for the same reason the six
    # gated ones were, but they are not fixture-privilege tests: their subject is
    # what the command produces, and skipping them would stop checking the
    # command on exactly the machine it has to work on. So they assert the
    # contract instead, by READING both names: a read follows a symlink, a
    # hardlink and a copy alike, which is precisely the property that makes all
    # three acceptable. (Test-FmAgentsMirror is not the check to reuse here - it
    # compares FileInfo.Length, and a symlink's own length is its target string,
    # so it answers a narrower question about two real files.)
    function Test-FmAgentsPairResolves {
        [OutputType([bool])]
        param([Parameter(Mandatory)][string]$Directory)
        try {
            $agents = [System.IO.File]::ReadAllBytes((Join-Path $Directory 'AGENTS.md'))
            $claude = [System.IO.File]::ReadAllBytes((Join-Path $Directory 'CLAUDE.md'))
        } catch {
            return $false
        }
        if ($agents.Length -ne $claude.Length) { return $false }
        for ($i = 0; $i -lt $agents.Length; $i++) {
            if ($agents[$i] -ne $claude[$i]) { return $false }
        }
        $true
    }

    # The exact bytes bin/fm-ensure-agents-md.sh writes for a fresh skeleton.
    $script:ExpectedSkeleton = @(
        '# Project agent memory',
        '',
        "This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.",
        '',
        '- Add durable project-specific notes here as they are discovered through real work.',
        '',
        '## Maintaining this file',
        '',
        'Keep this file for knowledge useful to almost every future agent session in this project.',
        'Do not repeat what the codebase already shows; point to the authoritative file or command instead.',
        'Prefer rewriting or pruning existing entries over appending new ones.',
        'When updating this file, preserve this bar for all agents and keep entries concise.',
        ''
    ) -join "`n"
}

Describe 'Set-FmAgentsMemory in an empty worktree' {
    It 'creates AGENTS.md with the byte-for-byte bash skeleton and links CLAUDE.md to it' {
        $dir = New-TestDir
        $result = Set-FmAgentsMemory -Path $dir
        $result.Message | Should -BeLike "created: AGENTS.md and*CLAUDE.md -> AGENTS.md in $dir"
        [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md')) | Should -Be $script:ExpectedSkeleton
        Test-FmAgentsPairResolves -Directory $dir | Should -BeTrue
    }

    It 'writes the skeleton LF-only with no BOM' {
        $dir = New-TestDir
        $null = Set-FmAgentsMemory -Path $dir
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir 'AGENTS.md'))
        $bytes[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        ($bytes -contains 13) | Should -BeFalse
    }

    It 'is idempotent: a second run reports unchanged and rewrites nothing' {
        $dir = New-TestDir
        $null = Set-FmAgentsMemory -Path $dir
        $before = [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md'))
        $result = Set-FmAgentsMemory -Path $dir
        $result.Action | Should -Be 'unchanged'
        # The message names the link kind the host actually produced, which is
        # the honest-reporting rule this command is built on: where symlinks
        # are unavailable the second name is a hardlink or a copy, and calling
        # that "CLAUDE.md -> AGENTS.md" would claim a link that is not there.
        # Asserting one wording regardless is what made a stock, non-elevated
        # Windows run look like a defect.
        $expected = if ((Get-Item -LiteralPath (Join-Path $dir 'CLAUDE.md') -Force).LinkTarget) {
            "unchanged: AGENTS.md with CLAUDE.md -> AGENTS.md in $dir"
        } else {
            "unchanged: AGENTS.md with a CLAUDE.md mirror of it in $dir"
        }
        $result.Message | Should -Be $expected
        [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md')) | Should -Be $before
    }

    It 'creates nothing under -WhatIf' {
        $dir = New-TestDir
        Set-FmAgentsMemory -Path $dir -WhatIf | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $dir 'AGENTS.md') | Should -BeFalse
    }

    It 'refuses a path that is not a directory' {
        { Set-FmAgentsMemory -Path (Join-Path $TestDrive 'no-such-dir') } | Should -Throw '*not a directory*'
    }
}

Describe 'Set-FmAgentsMemory with an existing AGENTS.md' {
    It 'injects the maintenance section into a file that lacks it, and links CLAUDE.md' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Notes`n`nsomething the project already knew`n")
        $result = Set-FmAgentsMemory -Path $dir
        $result.Action | Should -Be 'updated'
        $result.Message | Should -BeLike '*added ## Maintaining this file to AGENTS.md and*CLAUDE.md -> AGENTS.md*'
        $text = [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md'))
        $text | Should -BeLike '*something the project already knew*'
        $text | Should -BeLike '*## Maintaining this file*'
    }

    It 'injects the section into an existing pair without touching the link' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Notes`n")
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'CLAUDE.md') -Value 'AGENTS.md'
        $result = Set-FmAgentsMemory -Path $dir
        $result.Message | Should -Be "updated: added ## Maintaining this file to AGENTS.md in $dir"
        (Get-Item -LiteralPath (Join-Path $dir 'CLAUDE.md') -Force).LinkTarget | Should -Be 'AGENTS.md'
    }

    It 'preserves a CRLF file''s own line endings when it injects the section' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Notes`r`n`r`nwindows-edited`r`n")
        $null = Set-FmAgentsMemory -Path $dir
        $text = [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md'))
        $text | Should -BeLike "*## Maintaining this file`r`n*"
        $text | Should -Not -Match "(?<!`r)`n"
    }

    It 'separates the section with a blank line when the file has no trailing newline' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), '# Notes')
        $null = Set-FmAgentsMemory -Path $dir
        [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md')) |
            Should -BeLike "# Notes`n`n## Maintaining this file*"
    }

    It 'refuses when both AGENTS.md and CLAUDE.md are distinct real files' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), "# Claude, different content`n")
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*both AGENTS.md and CLAUDE.md are real files*'
        [System.IO.File]::ReadAllText((Join-Path $dir 'CLAUDE.md')) | Should -Be "# Claude, different content`n"
    }

    It 'refuses a CLAUDE.md symlink that points somewhere else' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'OTHER.md'), "# Other`n")
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'CLAUDE.md') -Value 'OTHER.md'
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*does not point to AGENTS.md*'
    }

    It 'refuses when AGENTS.md is itself a symlink' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'REAL.md'), "# Real`n")
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'AGENTS.md') -Value 'REAL.md'
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*AGENTS.md is a symlink*'
    }

    It 'refuses when AGENTS.md is not a regular file' {
        $dir = New-TestDir
        New-Item -ItemType Directory -Path (Join-Path $dir 'AGENTS.md') | Out-Null
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*is not a regular file*'
    }
}

Describe 'Set-FmAgentsMemory promoting a lone CLAUDE.md' {
    It 'moves it to AGENTS.md, injects the section, and links CLAUDE.md back' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), "# Existing project knowledge`n")
        $result = Set-FmAgentsMemory -Path $dir
        $result.Action | Should -Be 'promoted'
        $result.Message | Should -BeLike '*promoted: moved CLAUDE.md to AGENTS.md and*CLAUDE.md -> AGENTS.md*'
        $text = [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md'))
        $text | Should -BeLike '*# Existing project knowledge*'
        $text | Should -BeLike '*## Maintaining this file*'
        Test-FmAgentsPairResolves -Directory $dir | Should -BeTrue
    }

    It 'creates AGENTS.md and keeps an already-correct dangling link' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'CLAUDE.md') -Value 'AGENTS.md'
        $result = Set-FmAgentsMemory -Path $dir
        $result.Message | Should -Be "created: AGENTS.md and kept CLAUDE.md -> AGENTS.md in $dir"
        [System.IO.File]::ReadAllText((Join-Path $dir 'AGENTS.md')) | Should -Be $script:ExpectedSkeleton
    }

    It 'refuses a dangling CLAUDE.md symlink that points elsewhere' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'CLAUDE.md') -Value 'SOMEWHERE.md'
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*AGENTS.md is missing and the link does not point to AGENTS.md*'
    }
}

Describe 'the case-variant guard' {
    It 'refuses a lowercase agents.md rather than emitting a link whose target would dangle' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'agents.md'), "# lowercase`n")
        Test-FmAgentsCaseVariant -Directory $dir | Should -Be 'agents.md'
        { Set-FmAgentsMemory -Path $dir } | Should -Throw '*memory file is named agents.md*rename it to AGENTS.md*'
    }

    It 'accepts the exact AGENTS.md spelling' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        Test-FmAgentsCaseVariant -Directory $dir | Should -Be ''
    }
}

Describe 'the link strategies' {
    It 'creates a real symlink when one is allowed' {
        Set-FmTestSymlinkSkip
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        New-FmAgentsClaudeLink -Directory $dir -Strategy Symlink | Should -Be 'symlink'
        (Get-Item -LiteralPath (Join-Path $dir 'CLAUDE.md') -Force).LinkTarget | Should -Be 'AGENTS.md'
    }

    It 'creates a hardlink - the stock-Windows fallback - as one file under two names' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        New-FmAgentsClaudeLink -Directory $dir -Strategy HardLink | Should -Be 'hardlink'
        # One file: writing through one name is visible through the other.
        [System.IO.File]::AppendAllText((Join-Path $dir 'AGENTS.md'), "more`n")
        [System.IO.File]::ReadAllText((Join-Path $dir 'CLAUDE.md')) | Should -Be "# Agents`nmore`n"
    }

    It 'falls back to a copy, and the copy is reported as a copy - never as a link' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        New-FmAgentsClaudeLink -Directory $dir -Strategy Copy | Should -Be 'copy'
        Get-FmAgentsLinkVerb -Kind 'copy' | Should -Be 'copied'
        Get-FmAgentsLinkVerb -Kind 'hardlink' | Should -Be 'hardlinked'
        Get-FmAgentsLinkVerb -Kind 'symlink' | Should -Be 'symlinked'
    }
}

Describe 'the symlink git checked out as text' {
    # MEASURED on the captain's Windows 11 laptop. This repo tracks CLAUDE.md as
    # a symlink to AGENTS.md; git with core.symlinks=false - the default for a
    # non-elevated Windows git - writes a 9-byte regular file whose whole content
    # is 'AGENTS.md'. A Claude session started in that checkout reads one
    # filename and comes up with NO project instructions, and nothing says so.
    #
    # It is a link the host failed to materialize, not a second memory file, so
    # it must be repaired rather than refused as a conflict.

    It 'recognises the placeholder' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), 'AGENTS.md')
        Test-FmAgentsLinkPlaceholder -ClaudePath (Join-Path $dir 'CLAUDE.md') | Should -BeTrue
    }

    It 'recognises it with a trailing newline or a ./ prefix' -ForEach @(
        @{ Content = "AGENTS.md`n" }
        @{ Content = './AGENTS.md' }
    ) {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), $Content)
        Test-FmAgentsLinkPlaceholder -ClaudePath (Join-Path $dir 'CLAUDE.md') | Should -BeTrue
    }

    It 'does NOT mistake a real memory file for a placeholder' -ForEach @(
        @{ Case = 'multi-line'; Content = "# notes`nAGENTS.md is the other file`n" }
        @{ Case = 'names something else'; Content = 'README.md' }
        @{ Case = 'empty'; Content = '' }
    ) {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), $Content)
        Test-FmAgentsLinkPlaceholder -ClaudePath (Join-Path $dir 'CLAUDE.md') |
            Should -BeFalse -Because "a $Case CLAUDE.md is a real file"
    }

    It 'is false for a file that does not exist' {
        Test-FmAgentsLinkPlaceholder -ClaudePath (Join-Path (New-TestDir) 'CLAUDE.md') | Should -BeFalse
    }

    It 'materializes it instead of refusing, and the content becomes the real one' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# real instructions`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), 'AGENTS.md')

        $result = Set-FmAgentsMemory -Path $dir -Confirm:$false
        $result.Message | Should -BeLike '*symlink git checked out as text*'
        (Get-Content -LiteralPath (Join-Path $dir 'CLAUDE.md') -Raw) |
            Should -BeLike '*real instructions*'
    }

    It 'still REFUSES two real, different memory files' {
        # The placeholder rule must not become a licence to clobber.
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# one`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), "# a genuinely different file`n")
        { Set-FmAgentsMemory -Path $dir -Confirm:$false } | Should -Throw '*reconcile them manually*'
    }

    It 'writes nothing under -WhatIf' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# real instructions`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), 'AGENTS.md')
        $null = Set-FmAgentsMemory -Path $dir -WhatIf
        [System.IO.File]::ReadAllText((Join-Path $dir 'CLAUDE.md')) | Should -Be 'AGENTS.md'
    }
}

Describe 'Test-FmAgentsMirror' {
    It 'recognizes a materialized link: two real names with identical bytes' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        $null = New-FmAgentsClaudeLink -Directory $dir -Strategy Copy
        Test-FmAgentsMirror -AgentsPath (Join-Path $dir 'AGENTS.md') -ClaudePath (Join-Path $dir 'CLAUDE.md') |
            Should -BeTrue
    }

    It 'reports drift, which is what makes a copy fallback detectable' {
        $dir = New-TestDir
        [System.IO.File]::WriteAllText((Join-Path $dir 'AGENTS.md'), "# Agents`n")
        [System.IO.File]::WriteAllText((Join-Path $dir 'CLAUDE.md'), "# Diverged`n")
        Test-FmAgentsMirror -AgentsPath (Join-Path $dir 'AGENTS.md') -ClaudePath (Join-Path $dir 'CLAUDE.md') |
            Should -BeFalse
    }

    It 'reports false when either file is missing' {
        $dir = New-TestDir
        Test-FmAgentsMirror -AgentsPath (Join-Path $dir 'AGENTS.md') -ClaudePath (Join-Path $dir 'CLAUDE.md') |
            Should -BeFalse
    }
}

Describe 'Add-FmAgentsMaintenanceSection' {
    It 'appends exactly once, however many times it runs' {
        $dir = New-TestDir
        $path = Join-Path $dir 'AGENTS.md'
        [System.IO.File]::WriteAllText($path, "# Notes`n")
        Add-FmAgentsMaintenanceSection -Path $path | Should -BeTrue
        Add-FmAgentsMaintenanceSection -Path $path | Should -BeFalse
        @([System.IO.File]::ReadAllText($path) -split "`n" | Where-Object { $_ -eq '## Maintaining this file' }).Count |
            Should -Be 1
    }

    It 'recognizes the heading in a CRLF file and does not append a second copy' {
        $dir = New-TestDir
        $path = Join-Path $dir 'AGENTS.md'
        [System.IO.File]::WriteAllText($path, "# Notes`r`n`r`n## Maintaining this file`r`n`r`nkeep it short`r`n")
        Add-FmAgentsMaintenanceSection -Path $path | Should -BeFalse
    }
}
