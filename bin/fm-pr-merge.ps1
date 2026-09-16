#requires -Version 7.0
<#
.SYNOPSIS
fm-pr-merge.ps1 - the guarded pull-request merge for a direct-PR ship task.

.DESCRIPTION
Merges a task's pull request only when GitHub says it is safe to, and reports it
merged only when GitHub says it is. Port of the GitHub half of bin/fm-pr-merge.sh;
GitLab, away-mode merge grants and merge-queue retry coaching are not on this
platform (AGENTS.md section 14).

It refuses unless the pull request is open, not a draft, mergeable, free of
conflicts and green at its CURRENT head - all read live, with a failed check run
that a later green run of the same name replaced treated as green. The merge is
then bound to that exact head, so a push racing the merge fails it rather than
landing unreviewed work. Afterwards GitHub is read back: a queued, refused or
unreadable outcome is a failure with GitHub's own words quoted, never a merge.

  -Method squash|merge|rebase   how to land it (default squash)
  -AllowRed <name> ...          waive named checks, exact names, attended only
  -AttendedOverride             record that a captain asked for this concrete
                                merge; re-enables --auto, --admin and
                                --delete-branch in -ExtraArgument
  -ExtraArgument <args>         further `gh pr merge` arguments

Exit codes: 0 merged, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-pr-merge.ps1 my-task https://github.com/owner/repo/pull/12
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [Parameter(Position = 1)][string]$PrUrl = '',
    [ValidateSet('squash', 'merge', 'rebase')][string]$Method = 'squash',
    [string[]]$AllowRed = @(),
    [switch]$AttendedOverride,
    [string[]]$ExtraArgument = @(),
    [string]$StateDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmPrMerge'

if (-not $TaskId -or -not $PrUrl) {
    [Console]::Error.WriteLine('usage: fm-pr-merge.ps1 <task-id> <pr-url> [-Method squash|merge|rebase] [-AllowRed <name>] [-AttendedOverride] [-ExtraArgument <args>]')
    exit 2
}

try {
    # -Confirm:$false: the cmdlet is ConfirmImpact=High so a direct caller is
    # asked first, but reaching this entry point IS the approved action - the
    # captain's merge decision was made before it was run.
    $result = Invoke-FmPrMerge -TaskId $TaskId -PrUrl $PrUrl -Method $Method -AllowRed $AllowRed `
        -AttendedOverride:$AttendedOverride -ExtraArgument $ExtraArgument -StateDir $StateDir -Confirm:$false
    if ($null -eq $result) { exit 0 }
    # The warning goes to stderr and the outcome to stdout, so a caller reading
    # stdout for the merge line never has to parse a caveat out of it.
    if ($result.Warning) { [Console]::Error.WriteLine($result.Warning) }
    [Console]::Out.Write("$($result.Message)`n")
    exit 0
} catch {
    # Straight to stderr, not Write-Error: a refusal is a message for a human or
    # a calling script, not a PowerShell error record with source decoration.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
