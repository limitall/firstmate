#requires -Version 7.0
<#
    Private/FmTestRun.ps1 - internals of the per-file test runner.

    Ported from the isolation half of bin/fm-test-run.sh: one child per test
    script, a per-script bound, a scrubbed environment and a private temp
    directory. What is NOT ported is the rest of that file - its changed-file
    selection, its shard planner, its retry ladder and its CI reporters. Those
    belong to a machine with 392 test scripts and a CI fleet; this port has 54
    test files and one seat, so the runner here is the isolation and nothing
    else.

    WHY THE ISOLATION IS THE WHOLE POINT. Pester containers share ONE process,
    so every process-global a test file touches is a message to the file that
    runs after it. Three of those have already cost this repo real runs:

      - $env:PSModulePath, prepended by one file and not put back, let a fixture
        that had deliberately stubbed the module out AUTOLOAD the real one, run
        the real install.ps1 and hang the suite for 11.6 hours, twice, on main
        as well as on a branch (docs/windows-e2e-evidence.md section 56).
      - A missed `pwsh` stub sent the same fixture into the real installer,
        which took Confirm-SpeechModel's documented default - yes - and spent
        thirty-nine minutes on a 1.4 GB download inside a test.
      - An operator pane's own FM_* overrides reached the suite and were read as
        the machine's answer, so a fixture's settings went to live homes.

    Per-leak patches for all three exist and are correct. This file replaces the
    CLASS: with one process per file none of them can reach the next file at
    all, and with a bound none of them can cost more than one file's limit.

    THE COST IS ONE PROCESS START PER FILE, AND IT IS NOT HALF A SECOND HERE.
    Measured on this seat: pwsh starts in 0.67 s, importing Pester adds 1.6 s,
    and Pester's FIRST Invoke-Pester in a process adds 5.5 s more before it runs
    a test - about seven seconds a child, or six minutes across the suite. That
    5.5 s IS the fresh engine this file exists to buy, so there is nothing to
    optimise; docs/test-isolation.md states the figure rather than an estimate.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# THE VARIABLE THAT SAYS A SUITE IS CONDUCTING THIS PROCESS, and it holds the
# RUNNER'S process id rather than a bare flag.
#
# That is the same discipline CONTRIBUTING.md states for FM_SHELL_RELAUNCHED,
# and for the same reason: a marker handed to a child through the environment
# outlives whatever set it, so it has to say WHICH run it describes and be
# believed only while that run is still there. A bare '1' left in a window would
# go on refusing the captain's installs in that window for as long as it stayed
# open - which is exactly the defect section 50 records against the other
# marker, and there is no reason to reintroduce it under a new name.
#
# This runner never sets it on ITSELF, only on the children it starts, so the
# window the captain typed in cannot pick it up at all.
$script:FmTestModeVariable = 'FM_TEST_MODE'

# The per-file summary the child prints on its last line, and the only thing the
# parent reads counts from. A file that does not print it is reported as a file
# that did NOT run - never as one that passed. CONTRIBUTING.md's "say when a step
# did not run" is the rule; a missing marker is that case.
$script:FmTestRunSummaryMarker = 'FM_TEST_FILE_SUMMARY'

# WHAT THE CHILD MUST NOT INHERIT.
#
# FM_* IS THE WHOLE FAMILY ON PURPOSE. This module reads 54 distinct FM_
# variables and every one of them changes an answer - timeouts, retry counts,
# path overrides, the wake queue's location, which backend is used. Naming them
# one at a time is a list that goes stale the first time an area adds a knob,
# and the failure when it does is silent. The family is the honest unit.
#
# PSModulePath IS THE OTHER DOOR INTO THE MODULE. Removing it entirely - rather
# than setting it to something - is deliberate: a pwsh child with no
# PSModulePath in its environment computes the DEFAULT, which carries the user
# and system module directories (so Pester still resolves) and carries no
# checkout. Pinning a value here would have to name Pester's home, which is a
# per-machine fact this runner has no business knowing.
$script:FmTestRunScrubPattern = @(
    'FM_*'
    'PSModulePath'
)

function Get-FmTestModeVariableName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:FmTestModeVariable
}

function Get-FmTestRunSummaryMarker {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:FmTestRunSummaryMarker
}

function Get-FmTestRunScrubPattern {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return , @($script:FmTestRunScrubPattern)
}

function Get-FmTestRunFile {
    <#
        .SYNOPSIS
        Every *.Tests.ps1 under a directory, in the order they will be run.

        .DESCRIPTION
        Sorted by name so two runs of the same tree run the same files in the
        same order - a runner whose order came from the filesystem would make
        an ordering-dependent failure unreproducible, which is the one thing
        per-file isolation is supposed to make impossible.

        -Filter takes wildcard patterns matched against the file NAME, so
        `-Filter FmLock*` is the short way to re-run one area.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Filter = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "'$Path' is not a directory of tests"
    }
    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -File | Sort-Object Name)
    if ($Filter.Count -gt 0) {
        $files = @($files | Where-Object {
                $name = $_.Name
                @($Filter | Where-Object { $name -like $_ }).Count -gt 0
            })
    }
    return , @($files)
}

# The script each child runs. Written once per run into the run's own temp root
# and invoked with -File, never -Command: CONTRIBUTING.md states that a child
# `pwsh -Command` discards the exit code the tool returned, and the exit code is
# how this runner tells "the bound was hit" from "tests failed" from "Pester
# could not be loaded at all".
#
# THE TEST PATH ARRIVES AS A PARAMETER, not spliced into the text. A path with a
# quote in it would otherwise be a way to change what the child runs, and a
# generated script that interpolates is a generated script somebody has to keep
# checking.
$script:FmTestRunChildScript = @'
#requires -Version 7.0
# Generated by Invoke-FmTestRun. One test file, one process, nothing else.
param(
    [Parameter(Mandatory)][string]$TestPath,
    [Parameter(Mandatory)][string]$Marker,
    [string]$Verbosity = 'Normal'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 2 is "the run could not be conducted", and it is distinct from 1 on purpose: a
# machine with no Pester has not proved the file green and must never be counted
# as though it had.
try {
    Import-Module -Name 'Pester' -MinimumVersion '5.0.0' -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("fm-test-run: Pester 5+ could not be loaded: $($_.Exception.Message)")
    exit 2
}

try {
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $TestPath
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = $Verbosity
    $result = Invoke-Pester -Configuration $configuration
} catch {
    [Console]::Error.WriteLine("fm-test-run: Pester did not finish: $($_.Exception.Message)")
    exit 2
}

[Console]::Out.WriteLine(("{0} total={1} passed={2} failed={3} skipped={4}" -f
    $Marker, $result.TotalCount, $result.PassedCount, $result.FailedCount, $result.SkippedCount))
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
'@

function Write-FmTestRunChildScript {
    <#
        .SYNOPSIS
        Write the one-file-per-process child script and return its path.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one generated script into the run''s own private temp root. -WhatIf would leave the runner with nothing to launch, which is not a safer outcome, it is a broken one.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Directory -Force
    }
    $path = Join-Path $Directory 'fm-test-one.ps1'
    # LF and no BOM, like every other file this repo writes: a BOM in front of
    # `#requires` is read as content and the requirement stops applying.
    [System.IO.File]::WriteAllText($path, ($script:FmTestRunChildScript -replace "`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    $path
}

function Read-FmTestRunSummary {
    <#
        .SYNOPSIS
        The counts a child printed, or $null when it printed none.

        .DESCRIPTION
        $null is the answer for "this file did not report", and the caller turns
        that into a failure with a reason rather than into a silent zero. A
        runner that defaulted the counts to 0 would report a file that died
        before its first test as a clean file with nothing in it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = ('^{0}\s+total=(\d+)\s+passed=(\d+)\s+failed=(\d+)\s+skipped=(\d+)\s*$' -f
        [regex]::Escape($script:FmTestRunSummaryMarker))
    # The LAST marker, not the first: a test file that prints the marker itself
    # (this area's own cases do, from a fixture) must not be able to speak for
    # the run that contains it.
    $match = $null
    foreach ($line in ($Text -split "`r?`n")) {
        $candidate = [regex]::Match($line, $pattern)
        if ($candidate.Success) { $match = $candidate }
    }
    if (-not $match) { return $null }
    [pscustomobject]@{
        Total   = [int]$match.Groups[1].Value
        Passed  = [int]$match.Groups[2].Value
        Failed  = [int]$match.Groups[3].Value
        Skipped = [int]$match.Groups[4].Value
    }
}

function Get-FmTestRunVerdict {
    <#
        .SYNOPSIS
        What one child's exit code, bound and counts amount to.

        .DESCRIPTION
        Four outcomes, and the two failure shapes are kept apart because the
        answer to each is different: `timeout` says which file to look at and
        that nothing about it was proved, `unreported` says the child never got
        far enough to say anything, and both are failures. `empty` is the third:
        a file that ran and contained no tests at all, which is what a second
        top-level AfterAll does to a Pester file - it reports zero tests rather
        than failing, and `Invoke-Pester -Path ./tests` counts that as nothing
        wrong. Here it is named.

        .OUTPUTS
        [pscustomobject] Outcome, Ok, Detail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][bool]$TimedOut,
        [AllowNull()]$Summary,
        [Parameter(Mandatory)][double]$TimeoutSeconds
    )

    if ($TimedOut -or $ExitCode -eq 124) {
        return [pscustomobject]@{
            Outcome = 'timeout'
            Ok      = $false
            Detail  = ("did not finish within $TimeoutSeconds s and its whole process tree was killed; " +
                'nothing in this file was proved')
        }
    }
    if (-not $Summary) {
        return [pscustomobject]@{
            Outcome = 'unreported'
            Ok      = $false
            Detail  = "exited $ExitCode without reporting any counts, so it ran no tests this runner can vouch for"
        }
    }
    if ($Summary.Total -eq 0) {
        return [pscustomobject]@{
            Outcome = 'empty'
            Ok      = $false
            Detail  = 'ran and contained no tests; a Pester file that reports zero tests is broken, not clean'
        }
    }
    if ($Summary.Failed -gt 0 -or $ExitCode -ne 0) {
        # THE EXIT CODE IS REPORTED EVEN WHEN THE COUNTS LOOK CLEAN, and that
        # combination is the one worth naming: a file whose counts say nothing
        # failed and whose process still ended badly has done something Pester
        # did not count, and "0 failed of 83" on its own would read as a runner
        # bug rather than as the fact it is. CONTRIBUTING.md's rule is that a
        # failed step is reported with the code the TOOL returned.
        $detail = "$($Summary.Failed) failed of $($Summary.Total)"
        if ($ExitCode -ne 0 -and $Summary.Failed -eq 0) {
            $detail = "reported $($Summary.Total) tests and none failed, then exited $ExitCode"
        }
        return [pscustomobject]@{
            Outcome = 'failed'
            Ok      = $false
            Detail  = $detail
        }
    }
    [pscustomobject]@{
        Outcome = 'passed'
        Ok      = $true
        Detail  = "$($Summary.Passed) passed, $($Summary.Skipped) skipped"
    }
}

function Format-FmTestRunFileLine {
    <#
        .SYNOPSIS
        One line describing what happened to one file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$File)

    '  {0,-11} {1,7:0.0}s  {2,-32} {3}' -f $File.Outcome, $File.DurationSeconds, $File.Name, $File.Detail
}
