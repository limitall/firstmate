#requires -Version 7.0
# Pester tests for the project registry and delivery-posture parsing.
# Every expected string here was produced by running bin/fm-project-mode.sh in the
# reference implementation against the same fixture registry, so these tests pin
# byte-for-byte parity with it and not merely internal consistency.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestRegistry {
        param([string[]]$Lines)
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'projects.md'
        [System.IO.File]::WriteAllText($path, (($Lines -join "`n") + "`n"))
        $path
    }
}

Describe 'Get-FmProjectMode' {
    BeforeAll {
        $script:Registry = New-TestRegistry -Lines @(
            '# Projects',
            '',
            '- alpha [direct-PR +yolo] - the alpha project (added 2026-01-01)',
            '- beta - legacy default (added 2026-01-02)',
            '- gamma [no-mistakes-prod-only] - conditional (added 2026-01-03)',
            '- delta [bogus-mode] - typo (added 2026-01-04)',
            '- epsilon [local-only] - local (added 2026-01-05)',
            '- zeta [+yolo] - yolo only (added 2026-01-06)'
        )
    }

    It 'reads a bracketed mode and the orthogonal yolo flag' {
        $posture = Get-FmProjectMode -Name alpha -RegistryPath $script:Registry
        $posture.Mode | Should -Be 'direct-PR'
        $posture.Yolo | Should -Be 'on'
        $posture.Registered | Should -BeTrue
    }

    It 'treats an unannotated line as the legacy no-mistakes default' {
        $posture = Get-FmProjectMode -Name beta -RegistryPath $script:Registry
        $posture.Mode | Should -Be 'no-mistakes'
        $posture.Yolo | Should -Be 'off'
    }

    It 'maps the conditional policy to its most rigorous leg for mechanical callers' {
        (Get-FmProjectMode -Name gamma -RegistryPath $script:Registry).Mode | Should -Be 'no-mistakes'
    }

    It 'returns the conditional policy unmapped with -Raw' {
        (Get-FmProjectMode -Name gamma -RegistryPath $script:Registry -Raw).Mode | Should -Be 'no-mistakes-prod-only'
    }

    It 'reads yolo on a line that carries no mode' {
        $posture = Get-FmProjectMode -Name zeta -RegistryPath $script:Registry
        $posture.Mode | Should -Be 'no-mistakes'
        $posture.Yolo | Should -Be 'on'
    }

    It 'reads local-only' {
        (Get-FmProjectMode -Name epsilon -RegistryPath $script:Registry).Mode | Should -Be 'local-only'
    }

    It 'falls back to no-mistakes off and warns on an unknown mode, so a typo never drops the gate' {
        $warnings = $null
        $posture = Get-FmProjectMode -Name delta -RegistryPath $script:Registry -WarningVariable warnings -WarningAction SilentlyContinue
        $posture.Mode | Should -Be 'no-mistakes'
        $posture.Yolo | Should -Be 'off'
        $warnings[0].Message | Should -Be 'unknown mode "bogus-mode" for delta; defaulting to no-mistakes off'
    }

    It 'falls back and warns for a project that is not registered' {
        $warnings = $null
        $posture = Get-FmProjectMode -Name missing -RegistryPath $script:Registry -WarningVariable warnings -WarningAction SilentlyContinue
        $posture.Mode | Should -Be 'no-mistakes'
        $posture.Registered | Should -BeFalse
        $warnings[0].Message | Should -Be 'project "missing" not in registry; defaulting to no-mistakes off'
    }

    It 'falls back and warns when the registry itself is absent' {
        $absent = Join-Path $TestDrive 'no-such-registry.md'
        $warnings = $null
        $posture = Get-FmProjectMode -Name alpha -RegistryPath $absent -WarningVariable warnings -WarningAction SilentlyContinue
        $posture.Mode | Should -Be 'no-mistakes'
        $posture.Yolo | Should -Be 'off'
        $warnings[0].Message | Should -Be "no registry at $absent; defaulting alpha to no-mistakes off"
    }
}

Describe 'Get-FmProjectRegistryLine' {
    It 'ignores a line that is not a registry entry' {
        Get-FmProjectRegistryLine -Line '## Projects' | Should -BeNullOrEmpty
        Get-FmProjectRegistryLine -Line '' | Should -BeNullOrEmpty
        Get-FmProjectRegistryLine -Line 'alpha - not a bullet' | Should -BeNullOrEmpty
    }

    It 'keeps the annotation together when the mode and +yolo are separate fields' {
        $parsed = Get-FmProjectRegistryLine -Line '- alpha [direct-PR +yolo] - desc'
        $parsed.Mode | Should -Be 'direct-PR'
        $parsed.Yolo | Should -Be 'on'
    }
}

Describe 'Get-FmProjectRegistryEntry' {
    It 'returns every registered project in registry order' {
        $registry = New-TestRegistry -Lines @(
            '- one - first (added 2026-01-01)',
            'noise',
            '- two [local-only] - second (added 2026-01-02)'
        )
        $entries = @(Get-FmProjectRegistryEntry -RegistryPath $registry)
        $entries.Count | Should -Be 2
        $entries[0].Name | Should -Be 'one'
        $entries[1].Mode | Should -Be 'local-only'
    }

    It 'returns nothing for an absent registry' {
        @(Get-FmProjectRegistryEntry -RegistryPath (Join-Path $TestDrive 'nope.md')).Count | Should -Be 0
    }
}
