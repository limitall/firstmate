#requires -Version 7.0
<#
.SYNOPSIS
    Tear down a finished task, refusing rather than discarding unlanded work.

.DESCRIPTION
    Thin entry point over Invoke-FmTeardown. Exit codes follow the repo
    convention: 0 success, 1 refusal or failure, 2 usage. Refusals go straight
    to stderr so a CLI message is not wrapped in a PowerShell error record.

    --force skips the landed-work test and the scout report gate, which is to
    say it DISCARDS work, so it requires --approved-by "<who authorized it>".
    A bare --force is a usage error, not a slightly harder retry.

.EXAMPLE
    bin/fm-teardown.ps1 fmwin-teardown

.EXAMPLE
    bin/fm-teardown.ps1 fmwin-teardown --force --approved-by "captain, 2026-08-12"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$TaskId,
    [Parameter(ValueFromRemainingArguments)][string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$usage = 'usage: fm-teardown.ps1 <task-id> [--force --approved-by "<authority>"]'

$force = $false
$approvedBy = ''
$expectApproval = $false
# PowerShell routes a leading `-h`/`--help` into RemainingArguments rather than
# into $TaskId, so both places are checked. The text is written out rather than
# read back through Get-Help: comment-based help does not reliably attach to a
# script that opens with #requires, and a help flag that prints only a syntax
# line is worse than no help flag.
if ($TaskId -in @('-h', '--help') -or
    @($RemainingArguments | Where-Object { $_ -in @('-h', '--help') }).Count -gt 0) {
    @(
        $usage
        ''
        'Tear down a finished task: REFUSE while its worktree holds work that has not'
        'landed, then take custody of its processes, return the worktree to its pool,'
        'and clear the task''s volatile state.'
        ''
        'Work has landed when it is reachable from a remote-tracking branch, or its PR'
        'is merged and contains the current local work, or its content is already in the'
        'up-to-date default branch. local-only tasks also accept work merged into the'
        'local default branch. Uncommitted changes are never landed, and an inspection'
        'that cannot run refuses exactly like unlanded work.'
        ''
        '  --force          skip the landed-work test and the scout report gate. This'
        '                   DISCARDS work, so it requires --approved-by.'
        '  --approved-by S  who authorized the discard. Recorded with the teardown.'
        ''
        'Exit codes: 0 complete, 1 refused or failed, 2 invalid request.'
        'Details: docs/teardown-windows.md'
    ) | ForEach-Object { Write-Output $_ }
    exit 0
}
foreach ($arg in @($RemainingArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
    if ($expectApproval) {
        $approvedBy = $arg
        $expectApproval = $false
        continue
    }
    switch ($arg) {
        '--force' { $force = $true }
        '-Force' { $force = $true }
        '--approved-by' { $expectApproval = $true }
        default {
            [Console]::Error.WriteLine("fm-teardown: unknown argument: $arg")
            [Console]::Error.WriteLine($usage)
            exit 2
        }
    }
}
if ($expectApproval) {
    [Console]::Error.WriteLine('fm-teardown: --approved-by needs the authority that approved the discard')
    [Console]::Error.WriteLine($usage)
    exit 2
}
if (-not $TaskId) {
    [Console]::Error.WriteLine('error: invalid teardown request')
    [Console]::Error.WriteLine($usage)
    exit 2
}
if ($force -and -not $approvedBy) {
    [Console]::Error.WriteLine('fm-teardown: --force discards work that has not landed, so it requires --approved-by "<who approved it>"')
    [Console]::Error.WriteLine($usage)
    exit 2
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmTeardown'

try {
    $result = Invoke-FmTeardown -TaskId $TaskId -Force:$force -DiscardApprovedBy $approvedBy -Confirm:$false
} catch {
    foreach ($line in ([string]$_.Exception.Message -split "`r?`n")) {
        [Console]::Error.WriteLine($line)
    }
    exit 1
}
if ($null -eq $result) { exit 1 }

foreach ($step in $result.Steps) {
    if ($step.Outcome -in @('did-not-run', 'unconfirmed', 'failed')) {
        $detail = if ($step.Detail) { ": $($step.Detail)" } else { '' }
        [Console]::Error.WriteLine("teardown: step $($step.Step) did NOT run [$($step.Outcome)]$detail")
    }
}
Write-Output $result.Summary
if ($result.Reminder) { Write-Output $result.Reminder }
exit 0
