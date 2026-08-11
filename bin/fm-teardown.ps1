#requires -Version 7.0
<#
Tear down a finished task: REFUSE while its worktree holds work that has not
landed, then release the worktree, close the recorded endpoint, and clear the
task's volatile state.

Usage: fm-teardown.ps1 <task-id> [--force]

  --force skips the dirty and landed-work checks and the scout report gate.
  Use it ONLY when the captain has explicitly said to discard the work.

Work has landed when it is reachable from a remote-tracking branch, or its PR is
merged and contains the current local work, or its content is already in the
up-to-date default branch. local-only tasks also accept work merged into the
local default branch. Uncommitted changes are never landed, and an inspection
that cannot run refuses exactly like unlanded work.

Exit codes: 0 complete, 1 refused or failed, 2 invalid request.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}
if ($args.Count -lt 1) {
    [Console]::Error.WriteLine('error: invalid teardown request')
    exit 2
}

$teardownArgs = @{ Id = "$($args[0])"; Confirm = $false }
for ($i = 1; $i -lt $args.Count; $i++) {
    switch ("$($args[$i])") {
        '--force' { $teardownArgs['Force'] = $true }
        default {
            [Console]::Error.WriteLine("error: invalid teardown option: $($args[$i])")
            exit 2
        }
    }
}

$result = Invoke-FmTeardown @teardownArgs
exit $result.ExitCode
