#requires -Version 7.0
# Pester 5+/6 tests that hold the WHOLE repository to one analyzer bar.
#
# WHY THIS FILE EXISTS. Every area was clean in its own files and nobody owned
# the whole, so the repository accumulated 814 findings across areas that each
# believed they were passing. Per-area discipline does not compose; a repo-wide
# check does. This is that check, and it lives in the suite so it runs on every
# `Invoke-Pester -Path ./tests` rather than only when someone remembers the
# analyzer command.
#
# PSScriptAnalyzerSettings.psd1 at the repo root is the single agreed bar. A new
# finding is a defect to fix, not a number to re-baseline: there is deliberately
# no allowance here for "known" findings, because a tolerated count is how the
# 814 accumulated in the first place.

# Resolved at DISCOVERY time, not in BeforeAll: Pester evaluates -Skip: while it
# builds the tree, so a value set in BeforeAll arrives too late and would skip
# the whole sweep silently - the one outcome this file exists to prevent.
# A missing analyzer is reported as NOT RUN rather than passed, which is this
# repo's rule for a missing owner.
$script:HasAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SettingsPath = Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1'

    # Re-tested here rather than reusing the discovery-time value above: the two
    # phases have separate script scopes, and reading the discovery one from the
    # run phase yields $null - which left the sweep unrun and every assertion
    # below passing against an empty result.
    $script:Findings = @()
    $script:SweepErrors = @()
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $sweepErrors = $null
        $script:Findings = @(Invoke-ScriptAnalyzer -Path $script:RepoRoot -Recurse `
                -Settings $script:SettingsPath -ErrorVariable sweepErrors -ErrorAction SilentlyContinue)
        $script:SweepErrors = @($sweepErrors | ForEach-Object { [string]$_ })
    }

    function Format-FmFinding {
        param($Findings)
        return (($Findings | Sort-Object ScriptName, Line | ForEach-Object {
                    '{0}:{1} [{2}] {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message
                }) -join "`n")
    }
}

Describe 'repository analyzer bar' {
    It 'ships the settings file every area is held to' {
        Test-Path -LiteralPath $script:SettingsPath -PathType Leaf | Should -BeTrue
        # Import-PowerShellDataFile also proves it parses as the analyzer will read it.
        $settings = Import-PowerShellDataFile -LiteralPath $script:SettingsPath
        @($settings.Keys).Count | Should -BeGreaterThan 0
    }

    It 'completes the sweep without an analyzer error' -Skip:(-not $script:HasAnalyzer) {
        # An empty result is only evidence of a clean repository if the sweep
        # actually finished. A non-terminating analyzer error would otherwise
        # leave the assertions below passing against a partial result.
        ($script:SweepErrors -join '; ') | Should -Be ''
    }

    # Split by severity so a new Information finding cannot hide behind a
    # Warning that someone is already looking at.
    #
    # -ForEach, not a plain foreach: a discovery-time loop variable is $null by
    # the time the It body runs, which made every severity compare against $null
    # and pass on an empty match. The check silently could not fail.
    It 'reports no <_> finding anywhere in the repository' -ForEach @('Error', 'Warning', 'Information') -Skip:(-not $script:HasAnalyzer) {
        # Captured before the pipeline, because Where-Object rebinds $_.
        $severity = $_
        $hits = @($script:Findings | Where-Object { $_.Severity -eq $severity })
        (Format-FmFinding -Findings $hits) | Should -Be '' -Because 'the whole repository is held to PSScriptAnalyzerSettings.psd1, and a new finding is fixed rather than re-baselined'
    }

    It 'actually reaches bin/, module/ and tests/' {
        # A clean result proves nothing if the sweep matched no files. The sweep
        # is rooted at the repo, so assert each area still has PowerShell in it.
        foreach ($dir in @('bin', 'module', 'tests')) {
            @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot $dir) -Recurse -Filter '*.ps1' -File).Count |
                Should -BeGreaterThan 0 -Because "$dir must contain PowerShell for a clean sweep to mean anything"
        }
    }
}

Describe 'analyzer suppressions' {
    It 'gives every SuppressMessageAttribute a written justification' {
        # A suppression without a reason is indistinguishable from a suppression
        # that was wrong, and neither the rule nor the reviewer can tell later.
        $bare = [System.Collections.Generic.List[string]]::new()
        foreach ($dir in @('bin', 'module', 'tests')) {
            foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot $dir) -Recurse -Filter '*.ps1' -File)) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $predicate = { param($node) $node -is [System.Management.Automation.Language.AttributeAst] }
                foreach ($attr in $ast.FindAll($predicate, $true)) {
                    if ($attr.TypeName.Name -notmatch 'SuppressMessage') { continue }
                    $justification = @($attr.NamedArguments | Where-Object { $_.ArgumentName -eq 'Justification' })
                    if ($justification.Count -eq 0) {
                        $bare.Add("$($file.Name):$($attr.Extent.StartLineNumber)")
                        continue
                    }
                    if ($justification[0].Argument.Extent.Text.Trim("'`" ").Length -lt 20) {
                        $bare.Add("$($file.Name):$($attr.Extent.StartLineNumber) (justification too short to be a reason)")
                    }
                }
            }
        }
        ($bare -join ', ') | Should -Be '' -Because 'each suppression must say why the rule is wrong for that code'
    }
}
