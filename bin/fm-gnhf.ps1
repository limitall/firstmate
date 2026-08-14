#requires -Version 7.0
<#
.SYNOPSIS
fm-gnhf.ps1 - the only way firstmate runs gnhf on this machine.

.DESCRIPTION
Thin entry point over Invoke-FmGnhf. All mechanics live in the module; this
script resolves it, forwards arguments, prints the report and maps outcomes onto
exit codes.

  0  gnhf's own exit code, guard verified
  1  refused (not a repo, bad iteration count, empty objective, dirty tree)
  2  usage
  3  GUARD FAILED - the primary checkout moved; restore it before anything else

Always applied and not overridable: --worktree, --max-iterations, and no push.
docs/GNHF-GUARDS.md records why: gnhf's config file was measured to be
decorative, so the guards are applied where they demonstrably take effect and
the important one is verified after the run rather than trusted.

.EXAMPLE
bin/fm-gnhf.ps1 C:\repos\thing 20 "raise branch coverage in the parser"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$RepoPath = '',
    [Parameter(Position = 1)][string]$MaxIterations = '',
    [Parameter(Position = 2, ValueFromRemainingArguments)][string[]]$Objective = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RepoPath -in @('-h', '--help')) {
    [Console]::Out.Write("usage: fm-gnhf.ps1 <repo-path> <max-iterations> <objective>`n")
    [Console]::Out.Write("`n  repo-path        the project to work in; must be a git repo with a clean tree`n")
    [Console]::Out.Write("  max-iterations   1-100; always bounded, never open-ended`n")
    [Console]::Out.Write("  objective        what to grind at, quoted`n")
    [Console]::Out.Write("`nAlways applied and not overridable: --worktree, --max-iterations, and no push.`n")
    [Console]::Out.Write("The primary checkout's branch and commit are recorded before the run and`n")
    [Console]::Out.Write("verified after; any change is a hard failure (exit 3) with a restore command.`n")
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmGnhf'

$objectiveText = (@($Objective) -join ' ').Trim()
if (-not $RepoPath -or -not $MaxIterations -or -not $objectiveText) {
    [Console]::Error.WriteLine('usage: fm-gnhf.ps1 <repo-path> <max-iterations> <objective>')
    exit 2
}

$result = Invoke-FmGnhf -RepoPath $RepoPath -MaxIterations $MaxIterations -Objective $objectiveText -Confirm:$false

foreach ($line in @($result.Lines)) {
    if ($result.ExitCode -eq 0 -and $result.GuardHeld -ne $false) {
        [Console]::Out.WriteLine($line)
    } else {
        [Console]::Error.WriteLine($line)
    }
}

exit $result.ExitCode
