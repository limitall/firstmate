# bin/fm-pr-merge.ps1 - merge a task's PR after recording pr= and any available
# pr_head= through bin/fm-pr-check.ps1, so teardown can verify landed work after
# squash merges.
#
# Twin: bin/fm-pr-merge.sh
#
# CLI:
#   fm-pr-merge.ps1 <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
#
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.psm1 and the
# derived owner/repository and PR number are passed to gh-axi as separate
# arguments. Merge method defaults to --squash when the caller passes none of
# --squash, --merge, --rebase, or --method after the optional -- separator.
#
# ---------------------------------------------------------------------------
# EVERY REFUSAL HERE IS A MERGE GUARD, SO EVERY ONE IS REPRODUCED EXACTLY
#
# This is the only script in the tree that lands a PR, and three of its rules
# are what keep that from being redirectable:
#
#   1. The URL must parse as a CANONICAL GitHub pull request URL. A GitLab merge
#      request parses (the watcher follows those) but is refused here with the
#      same exit 2, because this path still addresses GitHub by owner/repository
#      only. Merge parity for GitLab is a separate change.
#   2. --repo / --repo=x / -R / -Rx in the extra arguments is refused outright.
#      The repository comes ONLY from the URL that was just validated; an extra
#      argument that could re-point it would make the validation decorative.
#      Note that -R with anything attached is refused too, which is why the
#      check is a prefix test and not an equality test.
#   3. pr= is recorded and re-read from the metadata BEFORE gh-axi is invoked. A
#      merge whose provenance was not durably recorded is refused rather than
#      performed, because teardown verifies landed work against that record.
#
# Exit codes: 2 for an invalid request, 1 for a refusal, otherwise gh-axi's own
# exit code - the bash twin's `set -e` makes gh-axi the last command, so its
# status IS the script's status, and callers branch on it.
#
# ---------------------------------------------------------------------------
# ONE DELIBERATE STREAM DIVERGENCE
#
# The bash twin lets gh-axi inherit its streams, so its output interleaves live.
# Invoke-FmTool captures both streams separately and this script re-emits them,
# which keeps stdout and stderr byte-correct per stream and keeps the exit code
# unambiguous, but does not preserve the INTERLEAVING between them, and strips
# CR (the port's LF contract). That is the same trade every converted caller of
# an external tool makes.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force

$fmArgv = @($args)

<#
.SYNOPSIS
Did the caller already choose a merge method? Twin of caller_has_merge_method.
#>
function Test-FmMergeMethodArgument {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Argument = @())

    foreach ($arg in $Argument) {
        if ((Test-FmPrOrdinalEqual -Left $arg -Right '--squash') -or
            (Test-FmPrOrdinalEqual -Left $arg -Right '--merge') -or
            (Test-FmPrOrdinalEqual -Left $arg -Right '--rebase') -or
            (Test-FmPrOrdinalEqual -Left $arg -Right '--method') -or
            $arg.StartsWith('--method=', [System.StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
Does any extra argument try to re-point the repository? Twin of
reject_repo_overrides (inverted: $true here means "an override was found").
.DESCRIPTION
The bash `-R?*` pattern means "-R followed by at least one character", so bare
-R and -Rowner/repo are both refused while an unrelated flag is not.
#>
function Test-FmRepoOverrideArgument {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Argument = @())

    foreach ($arg in $Argument) {
        if ((Test-FmPrOrdinalEqual -Left $arg -Right '--repo') -or
            $arg.StartsWith('--repo=', [System.StringComparison]::Ordinal) -or
            (Test-FmPrOrdinalEqual -Left $arg -Right '-R') -or
            ($arg.StartsWith('-R', [System.StringComparison]::Ordinal) -and $arg.Length -gt 2)) {
            return $true
        }
    }
    return $false
}

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $state = $context.State

    if ($fmArgv.Count -lt 2) {
        Write-FmErr 'error: invalid PR merge request'
        Exit-FmScript 2
    }
    $id = [string]$fmArgv[0]
    $rawUrl = [string]$fmArgv[1]

    $identity = $null
    if (Test-FmPrTaskId -Id $id) { $identity = Get-FmPrUrlIdentity -Url $rawUrl }
    if (-not (Test-FmPrTaskId -Id $id) -or $null -eq $identity -or
        -not (Test-FmPrOrdinalEqual -Left ([string]$identity.Provider) -Right 'github')) {
        Write-FmErr 'error: invalid PR merge request'
        Exit-FmScript 2
    }
    $url = [string]$identity.Url
    $prOwner = [string]$identity.Owner
    $prRepo = [string]$identity.Repo
    $prNumber = [string]$identity.Number

    $extra = @()
    if ($fmArgv.Count -gt 2) { $extra = @($fmArgv[2..($fmArgv.Count - 1)] | ForEach-Object { [string]$_ }) }
    if ($extra.Count -gt 0 -and (Test-FmPrOrdinalEqual -Left $extra[0] -Right '--')) {
        $extra = @($extra | Select-Object -Skip 1)
    }

    if (Test-FmRepoOverrideArgument -Argument $extra) {
        Write-FmErr 'error: extra merge arguments must not override the repository'
        Exit-FmScript 1
    }

    # Task-derived paths are constructed only after the canonical ID validation.
    $meta = Join-Path $state "$id.meta"
    if (-not (Test-FmPrRegularFile -Path $meta)) {
        Write-FmErr 'error: task metadata is unavailable'
        Exit-FmScript 1
    }

    # `set -e` in the twin means a failing fm-pr-check aborts with ITS exit code,
    # not with a code of this script's choosing.
    $check = Invoke-FmScript -Name 'fm-pr-check' -Arguments @($id, $url) -Stream
    if (-not $check.Ok) { Exit-FmScript $check.ExitCode }

    # `grep -qxF "pr=$URL"`: a WHOLE-LINE fixed-string match, so a line that
    # merely contains the URL cannot satisfy it.
    $recorded = $false
    foreach ($line in (Split-FmPrReadLine -Text ([System.Text.Encoding]::Latin1.GetString(
                    [System.IO.File]::ReadAllBytes((ConvertTo-FmNativePath $meta)))))) {
        if (Test-FmPrOrdinalEqual -Left ([string]$line.Value) -Right "pr=$url") { $recorded = $true }
    }
    if (-not $recorded) {
        Write-FmErr 'error: PR metadata recording failed'
        Exit-FmScript 1
    }

    $mergeArgs = @()
    if (-not (Test-FmMergeMethodArgument -Argument $extra)) { $mergeArgs = @('--squash') }

    $ghAxi = Get-Command 'gh-axi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $ghAxi) {
        # The twin's own diagnostic for this is bash's "command not found" on
        # stderr plus exit 127; that shape is reproduced rather than improved on.
        Write-FmErr 'fm-pr-merge.ps1: gh-axi: command not found'
        Exit-FmScript 127
    }
    $argv = @('pr', 'merge', $prNumber, '--repo', "$prOwner/$prRepo") + $mergeArgs + $extra
    $result = Invoke-FmTool -FilePath $ghAxi.Source -Arguments $argv
    if (-not [string]::IsNullOrEmpty($result.StdOut)) { Write-FmRaw $result.StdOut }
    if (-not [string]::IsNullOrEmpty($result.StdErr)) { [Console]::Error.Write($result.StdErr) }
    Exit-FmScript $result.ExitCode
}
