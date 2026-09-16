#requires -Version 7.0
<#
.SYNOPSIS
    Run this repo's Pester suite with one process per test file.

.DESCRIPTION
    The gate for this repository. Each *.Tests.ps1 runs in a fresh
    `pwsh -NoProfile -NonInteractive` child with a per-file time limit, a
    scrubbed environment and its own temp directory, so nothing one file leaves
    behind can decide what the next file does - and nothing a file starts can
    outlive its own bound.

    `Invoke-Pester -Path ./tests` still works and is still a correct thing to
    type; it just shares one process across fifty-four files, which is how this
    repo lost 11.6 hours to a leaked PSModulePath and thirty-nine minutes to a
    missed stub. docs/test-isolation.md has both.

    This process waits on every child, so it is also the anchor the suite needs:
    a run whose launching shell has exited fails five FmIdentity and FmLock cases
    for a reason that is nothing to do with the tree.

    Exit codes: 0 every file passed, 1 something did not, 2 usage.

.PARAMETER Path
    The directory of test files. Defaults to <checkout>/tests.

.PARAMETER TimeoutSeconds
    The bound on ONE file. 1800 by default; Invoke-FmTestRun's help says why
    that is twice what the bash original uses.

.PARAMETER Filter
    Wildcard patterns matched against file names, e.g. -Filter FmLock*.
    Several are separated by commas: -Filter FmLock*,FmState*.

.PARAMETER Verbosity
    Pester's verbosity inside each child. 'None' reports only this runner's own
    per-file lines.

.PARAMETER KeepTemp
    Keep every file's temp directory. A FAILING file's is kept either way.

.EXAMPLE
    pwsh -NoProfile -NonInteractive -File .\bin\fm-test-run.ps1

.EXAMPLE
    pwsh -NoProfile -NonInteractive -File .\bin\fm-test-run.ps1 -Filter FmLock*,FmState* -Verbosity Detailed
#>
[CmdletBinding()]
param(
    [string]$Path,
    [double]$TimeoutSeconds = 1800,
    [string[]]$Filter = @(),
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Verbosity = 'Normal',
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmTestRun'

if ($TimeoutSeconds -le 0) {
    [Console]::Error.WriteLine('fm-test-run: -TimeoutSeconds must be greater than zero; a bound of 0 is not a bound')
    exit 2
}

# SPLIT ON COMMAS, because `pwsh -File` cannot hand a script an array. Every
# argument arrives as one string there - MEASURED: `-Filter FmLock*,FmState*`
# binds as the single pattern `FmLock*,FmState*`, which matches no file, so the
# run refuses with "no *.Tests.ps1 matched" instead of running the two areas
# that were asked for. A wildcard pattern never legitimately contains a comma,
# so splitting here is unambiguous.
$patterns = @($Filter | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

$runArgs = @{
    RepoRoot       = (Split-Path -Parent $PSScriptRoot)
    TimeoutSeconds = $TimeoutSeconds
    Filter         = $patterns
    Verbosity      = $Verbosity
    KeepTemp       = $KeepTemp
}
if ($PSBoundParameters.ContainsKey('Path')) { $runArgs['Path'] = $Path }

try {
    $report = Invoke-FmTestRun @runArgs
} catch {
    [Console]::Error.WriteLine("fm-test-run: $_")
    exit 1
}

if ($report.Ok) { exit 0 }
exit 1
