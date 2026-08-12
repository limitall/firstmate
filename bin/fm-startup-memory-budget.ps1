# bin/fm-startup-memory-budget.ps1 - Twin: bin/fm-startup-memory-budget.sh
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.ps1 read
#   fm-startup-memory-budget.ps1 report
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/captain.md, data/captain-shared.md, and data/learnings.md together.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
#
# ---------------------------------------------------------------------------
# THE HEADER IS THE HELP, IN BOTH LANGUAGES
#
# The bash twin prints its usage with `sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"` -
# the header comment IS the help text, so the two can never drift. This twin
# reproduces that literally: it re-reads its OWN first 11 lines and strips the
# comment marker, which is why lines 2-11 above are byte-identical to the bash
# twin's lines 2-11 apart from the `.sh`/`.ps1` command name. Editing the header
# edits the help; there is no second copy to forget.
#
# Every exit code, every stdout field, and every stderr diagnostic is the bash
# twin's: 0 on success, 1 when the configured budget itself is unreadable or
# unsafe, 2 for a usage error or an unmeasurable memory file.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-startup-memory-budget-lib.psm1') -Force

$fmArgv = @($args)
$fmSelf = $PSCommandPath

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $config = $context.Config
    $data = $context.Data
    $fmHome = $context.Home

    # `sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"`: lines 2..11, comment marker off.
    function Get-Usage {
        $lines = Get-FmFileLines $fmSelf
        $out = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -lt 11 -and $i -lt $lines.Count; $i++) {
            $out.Add(($lines[$i] -replace '^# ?', ''))
        }
        return $out
    }
    function Write-Usage([switch]$ToError) {
        foreach ($line in (Get-Usage)) {
            if ($ToError) { Write-FmErr $line } else { Write-FmOut $line }
        }
    }
    function Write-BudgetError([string]$Message) {
        Write-FmErr "startup-memory-budget: $Message"
    }

    # Returns the validated budget string, or $null after reporting. The bash
    # twin's read_budget prints to stdout AND is captured by report through
    # `budget=$(read_budget)`, so the value is returned here and the caller
    # decides whether it is also printed.
    function Get-Budget {
        $budget = Get-FmStartupMemoryBudget -ConfigDir $config
        if ($null -eq $budget) {
            Write-BudgetError ("invalid config/{0} - {1}" -f `
                (Get-FmStartupMemoryBudgetFileName), (Get-FmStartupMemoryBudgetError))
            return $null
        }
        return $budget
    }

    function Invoke-Report {
        $budget = Get-Budget
        if ($null -eq $budget) { return 2 }

        # `[ -e ... ] || [ -L ... ]`: a broken symlink still marks a secondmate
        # home, so presence is tested before regularity.
        $marker = Join-Path $fmHome '.fm-secondmate-home'
        $role = 'primary'
        if ((Test-Path -LiteralPath (ConvertTo-FmNativePath $marker)) -or (Test-FmSymlink $marker)) {
            $role = 'secondmate'
        }

        Write-FmOut 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate'
        Write-FmOut "role=$role"
        Write-FmOut "effective_budget_tokens=$budget"

        [long]$total = 0
        $sharedTokens = '0'
        foreach ($file in @('captain.md', 'captain-shared.md', 'learnings.md')) {
            $measured = Measure-FmStartupMemoryFile -Path (Join-Path $data $file)
            if ($null -eq $measured) {
                Write-BudgetError (Get-FmStartupMemoryBudgetError)
                return 2
            }
            $total += [long]$measured.Tokens
            if ($file -eq 'captain-shared.md') { $sharedTokens = [string]$measured.Tokens }
            Write-FmOut ("file=data/{0} bytes={1} estimated_tokens={2} status={3}" -f `
                $file, $measured.Bytes, $measured.Tokens, $measured.Presence)
        }
        Write-FmOut "total_estimated_tokens=$total"
        if (Test-FmStartupMemoryDecimalLe -Left ([string]$total) -Right $budget) {
            Write-FmOut 'budget_status=within-budget'
        } else {
            Write-FmOut 'budget_status=over-budget'
        }
        if ($role -eq 'secondmate' -and
            -not (Test-FmStartupMemoryDecimalLe -Left $sharedTokens -Right $budget)) {
            Write-FmOut 'exception=primary-owned-shared-file-alone-exceeds-budget'
        }
        return 0
    }

    $verb = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    # -CaseSensitive: PowerShell's switch matches case-insensitively by default,
    # which would accept `READ` where the bash twin falls through to usage.
    switch -CaseSensitive ($verb) {
        'read' {
            if ($fmArgv.Count -ne 1) { Write-Usage -ToError; Exit-FmScript 2 }
            $budget = Get-Budget
            if ($null -eq $budget) { Exit-FmScript 1 }
            Write-FmOut $budget
            Exit-FmScript 0
        }
        'report' {
            if ($fmArgv.Count -ne 1) { Write-Usage -ToError; Exit-FmScript 2 }
            Exit-FmScript (Invoke-Report)
        }
        { $_ -in @('-h', '--help') } {
            Write-Usage
            Exit-FmScript 0
        }
        default {
            Write-Usage -ToError
            Exit-FmScript 2
        }
    }
}
