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

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that write disposable stub sweep scripts into a temp directory. -WhatIf on a fixture would leave the test asserting against a script that was never written.')]
param()

# Resolved at DISCOVERY time, not in BeforeAll: Pester evaluates -Skip: while it
# builds the tree, so a value set in BeforeAll arrives too late and would skip
# the whole sweep silently - the one outcome this file exists to prevent.
# A missing analyzer is reported as NOT RUN rather than passed, which is this
# repo's rule for a missing owner.
$script:HasAnalyzer = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:SettingsPath = Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1'
    $script:SweepAttempts = 3

    # THE SWEEP RUNS OUT OF PROCESS, and that is not incidental.
    #
    # PSScriptAnalyzer's Helper.GetExportedFunction resolves the names an
    # Export-ModuleMember call exports, and raises a NullReferenceException from
    # CommandInfo.ResolveParameter when it cannot build a resolved command's
    # parameter metadata. Firstmate.psm1 is the only file in the repo that calls
    # Export-ModuleMember, so it is the only file that trips it. Several rules
    # use that helper - AvoidReservedCharInCmdlet and ProvideCommentHelp both
    # do - so excluding one rule only moves the crash to the next.
    #
    # Measured here: roughly 1 sweep in 40 from a clean session, but 3 in 10
    # when the Firstmate module is loaded in the session doing the analysing -
    # which is exactly what a Pester session looks like, since the other suites
    # dot-source and import the module. Running the sweep in a child process
    # keeps the analyzer away from that state. The retry below covers what is
    # left, because the fault is inside the analyzer and cannot be configured
    # away from here.
    # THE SWEPT SET IS ENUMERATED HERE, not left to -Recurse.
    #
    # A clean result is only worth anything if it covered everything, and
    # "-Recurse found nothing to complain about" and "-Recurse looked at four
    # files" produce the identical empty list. Driving the sweep from an explicit
    # file list makes the swept set a value the tests can assert on, so covering
    # a subset is a failure rather than a pass. Costs about the same as -Recurse.
    function Get-FmAnalysableFile {
        param([Parameter(Mandatory)][string]$Root)
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
                Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
                Where-Object { $_.FullName -notmatch '[/\\]\.git[/\\]' } |
                ForEach-Object { $_.FullName } | Sort-Object)
    }

    $script:SweepScript = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-analyzer-sweep-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($script:SweepScript, @'
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Settings)
$ErrorActionPreference = 'Continue'
Import-Module PSScriptAnalyzer -ErrorAction Stop
# $Root is a file holding one path per line - the list the caller enumerated.
$targets = @([System.IO.File]::ReadAllLines($Root) | Where-Object { $_ })
$findings = @()
$sweepErrors = @()
$analysed = @()
foreach ($target in $targets) {
    $fileErrors = $null
    $findings += @(Invoke-ScriptAnalyzer -Path $target -Settings $Settings -ErrorVariable fileErrors -ErrorAction SilentlyContinue)
    if (@($fileErrors).Count -gt 0) { $sweepErrors += @($fileErrors) } else { $analysed += $target }
}
[pscustomobject]@{
    Analysed = @($analysed)
    Findings = @($findings | ForEach-Object {
            [pscustomobject]@{
                ScriptName = [string]$_.ScriptName
                Line       = [int]$_.Line
                RuleName   = [string]$_.RuleName
                Severity   = [string]$_.Severity
                Message    = [string]$_.Message
            }
        })
    Errors   = @($sweepErrors | ForEach-Object {
            $trace = [string]$_.Exception.StackTrace
            # The rule that crashed is only recoverable from the stack; the error
            # record itself says no more than RULE_ERROR.
            $rule = if ($trace -match 'BuiltinRules\.(?<r>[A-Za-z0-9_]+)\.AnalyzeScript') { $Matches['r'] } else { 'unknown-rule' }
            [pscustomobject]@{
                Target  = [string]$_.TargetObject
                Rule    = $rule
                Message = [string]$_.Exception.Message
            }
        })
} | ConvertTo-Json -Depth 6 -Compress
'@, [System.Text.UTF8Encoding]::new($false))

    function Invoke-FmAnalyzerSweep {
        <#
            One repo-wide sweep in a child process, retried only when the
            ANALYZER itself failed on a file. A retry never re-reads a finding:
            findings are deterministic, and a sweep that reported no rule error
            is used exactly as it came back.
        #>
        param(
            [Parameter(Mandatory)][int]$Attempts,
            [string]$ScriptPath,
            [string]$ListPath
        )
        if (-not $ScriptPath) { $ScriptPath = $script:SweepScript }
        if (-not $ListPath) { $ListPath = $script:ListPath }
        $result = $null
        for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
            $raw = (& pwsh -NoProfile -File $ScriptPath -Root $ListPath -Settings $script:SettingsPath) -join ''
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $result = [pscustomobject]@{
                    Analysed = @()
                    Findings = @()
                    Errors   = @([pscustomobject]@{ Target = '(whole sweep)'; Rule = 'none'; Message = "the sweep process produced no output (exit code $LASTEXITCODE)" })
                    Attempts = $attempt
                }
                continue
            }
            $parsed = $raw | ConvertFrom-Json
            $result = [pscustomobject]@{
                Analysed = @($parsed.Analysed)
                Findings = @($parsed.Findings)
                Errors   = @($parsed.Errors)
                Attempts = $attempt
            }
            if ($result.Errors.Count -eq 0) { return $result }
        }
        return $result
    }

    $script:Expected = Get-FmAnalysableFile -Root $script:RepoRoot
    $script:ListPath = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-analyzer-list-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllLines($script:ListPath, $script:Expected)

    $script:Findings = @()
    $script:SweepErrors = @()
    $script:Analysed = @()
    $script:SweepAttemptsUsed = 0
    # Re-tested here rather than reusing the discovery-time value above: the two
    # phases have separate script scopes, and reading the discovery one from the
    # run phase yields $null - which left the sweep unrun and every assertion
    # below passing against an empty result.
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        $sweep = Invoke-FmAnalyzerSweep -Attempts $script:SweepAttempts
        $script:Findings = @($sweep.Findings)
        $script:SweepErrors = @($sweep.Errors)
        $script:Analysed = @($sweep.Analysed)
        $script:SweepAttemptsUsed = $sweep.Attempts
    }

    function Format-FmFinding {
        param($Findings)
        return (($Findings | Sort-Object ScriptName, Line | ForEach-Object {
                    '{0}:{1} [{2}] {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message
                }) -join "`n")
    }
}

AfterAll {
    foreach ($temp in @($script:SweepScript, $script:ListPath)) {
        if ($temp -and (Test-Path -LiteralPath $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
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
        # An empty finding list is only evidence of a clean repository if the
        # sweep finished. A rule that crashes analyses that file no further, so
        # its findings are simply absent - and the severity assertions below
        # would pass on the gap. This says so instead, and says it in enough
        # detail to act on: which file, which rule, and how to see it again.
        $detail = ($script:SweepErrors | ForEach-Object {
                '{0} was NOT fully analysed: rule {1} failed with "{2}"' -f $_.Target, $_.Rule, $_.Message
            }) -join '; '
        $detail | Should -Be '' -Because (
            "the analyzer crashed on a file in all $script:SweepAttempts attempts, so that file's findings are missing " +
            'rather than clean. This is a fault in the analyzer, not in the repository: reproduce it with ' +
            "'Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -ErrorVariable e' and read " +
            '$e[0].Exception.StackTrace for the rule. Fix or exclude that rule - do not delete this check')
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

    It 'analyses EVERY analysable file in the repository, not a subset' -Skip:(-not $script:HasAnalyzer) {
        # The assertions above cannot tell "nothing to report" from "almost
        # nothing was read". This one can: the sweep reports back which files it
        # actually analysed, and that set must equal the set on disk exactly.
        # A file the sweep skipped is a hole in the bar, so it is a failure here
        # rather than an invisible pass above.
        $missed = @($script:Expected | Where-Object { $_ -notin $script:Analysed })
        ($missed -join "`n") | Should -Be '' -Because 'every .ps1, .psm1 and .psd1 in the repository is held to the bar'

        $extra = @($script:Analysed | Where-Object { $_ -notin $script:Expected })
        ($extra -join "`n") | Should -Be '' -Because 'the sweep must analyse the repository, not something else'
        $script:Analysed.Count | Should -Be $script:Expected.Count
    }

    It 'covers every area, including ones added after this check was written' -Skip:(-not $script:HasAnalyzer) {
        # Named by DIRECTORY, never by file list: an area that lands tomorrow is
        # covered the moment its files exist, with nothing here to update. The
        # counts are asserted from the swept set, not from a fresh enumeration,
        # so this cannot pass while the sweep quietly read nothing.
        foreach ($area in @('bin', 'module/Firstmate/Private', 'module/Firstmate/Public', 'tests')) {
            $prefix = Join-Path $script:RepoRoot ($area -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            @($script:Analysed | Where-Object { $_.StartsWith($prefix) }).Count |
                Should -BeGreaterThan 0 -Because "$area must be inside the swept set"
        }
        # The module manifest and loader are the two files most likely to be
        # skipped by an extension filter that only thought about .ps1.
        @($script:Analysed | Where-Object { $_ -like '*Firstmate.psd1' }).Count | Should -Be 1
        @($script:Analysed | Where-Object { $_ -like '*Firstmate.psm1' }).Count | Should -Be 1
    }

    It 'picks up a file that did not exist when the sweep list was built' {
        # Proves the enumeration is live rather than a snapshot someone has to
        # remember to extend - the property that makes the two tests above hold
        # for an area that lands later. The file is created inside the repo and
        # removed in the same test, so nothing is left behind for the next run.
        $planted = Join-Path $script:RepoRoot 'tests' ('fm-coverage-canary-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [System.IO.File]::WriteAllText($planted, "function Get-FmCanary { 'x' }`n")
            $refreshed = Get-FmAnalysableFile -Root $script:RepoRoot
            $refreshed | Should -Contain $planted -Because 'a newly added file must be swept without anyone editing this test'
        } finally {
            Remove-Item -LiteralPath $planted -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'the sweep runner itself' {
    # The check above is only trustworthy if its own failure handling works.
    # A sweep that cannot complete must be reported, never quietly treated as a
    # clean result, so the not-completing paths are exercised here with stub
    # sweeps rather than left to be discovered on a bad night.
    BeforeAll {
        $script:StubDir = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-sweep-stub-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:StubDir -Force

        function New-FmStubSweep {
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Body)
            $path = Join-Path $script:StubDir "$Name.ps1"
            $header = 'param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Settings)' + "`n"
            [System.IO.File]::WriteAllText($path, $header + $Body, [System.Text.UTF8Encoding]::new($false))
            return $path
        }
    }

    AfterAll {
        if ($script:StubDir -and (Test-Path -LiteralPath $script:StubDir)) {
            Remove-Item -LiteralPath $script:StubDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gives up after the full attempt budget when every sweep crashes' {
        $stub = New-FmStubSweep -Name 'always-fails' -Body @'
[pscustomobject]@{
    Findings = @()
    Errors   = @([pscustomobject]@{ Target = 'X.psm1'; Rule = 'ProvideCommentHelp'; Message = 'Object reference not set to an instance of an object.' })
} | ConvertTo-Json -Depth 6 -Compress
'@
        $result = Invoke-FmAnalyzerSweep -Attempts 3 -ScriptPath $stub
        $result.Attempts | Should -Be 3 -Because 'a crashing sweep is retried up to the budget before it is believed'
        $result.Errors.Count | Should -Be 1
        # The reported detail must name the file AND the rule, or nobody can act on it.
        $result.Errors[0].Target | Should -Be 'X.psm1'
        $result.Errors[0].Rule | Should -Be 'ProvideCommentHelp'
    }

    It 'recovers when a later attempt completes, and keeps that attempt s findings' {
        # First run crashes, second succeeds - the real fault's shape.
        $marker = Join-Path $script:StubDir 'attempted.txt'
        $stub = New-FmStubSweep -Name 'fails-once' -Body @"
if (-not (Test-Path -LiteralPath '$marker')) {
    Set-Content -LiteralPath '$marker' -Value 'x'
    [pscustomobject]@{ Findings = @(); Errors = @([pscustomobject]@{ Target = 'X.psm1'; Rule = 'ProvideCommentHelp'; Message = 'boom' }) } | ConvertTo-Json -Depth 6 -Compress
} else {
    [pscustomobject]@{ Findings = @([pscustomobject]@{ ScriptName = 'a.ps1'; Line = 1; RuleName = 'PSFake'; Severity = 'Warning'; Message = 'm' }); Errors = @() } | ConvertTo-Json -Depth 6 -Compress
}
"@
        $result = Invoke-FmAnalyzerSweep -Attempts 3 -ScriptPath $stub
        $result.Attempts | Should -Be 2
        $result.Errors.Count | Should -Be 0
        # The recovered attempt's findings are the ones asserted on, so a real
        # finding cannot be lost to a retry.
        $result.Findings.Count | Should -Be 1
        $result.Findings[0].RuleName | Should -Be 'PSFake'
    }

    It 'reports a sweep that produced no output at all as an error, not as clean' {
        $stub = New-FmStubSweep -Name 'silent' -Body 'exit 1'
        $result = Invoke-FmAnalyzerSweep -Attempts 2 -ScriptPath $stub
        $result.Findings.Count | Should -Be 0
        $result.Errors.Count | Should -BeGreaterThan 0 -Because 'no output is a failed sweep, and an empty finding list would otherwise read as a clean repository'
        $result.Errors[0].Message | Should -BeLike '*produced no output*'
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
