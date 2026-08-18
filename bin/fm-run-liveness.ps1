#requires -Version 7.0
<#
Is anything actually running for a task?

Usage: fm-run-liveness.ps1 <task-id>

Answers the one question that separates a crewmate waiting on a live background
run from a crewmate waiting on one that has already ended. A worker whose run
ends without its harness noticing looks healthy from every other angle - live
endpoint, plausible pane, ordinary non-terminal status - so this reading is the
only thing that tells the two apart. docs/finished-run-stall.md owns the why.

Prints one line:
  liveness: <processes|none|unknown> · task: <id> · <detail> [· pids: <n, n>]

`none` means a process table WAS read and the task has nothing of its own alive.
`unknown` means the question could not be answered and must never be read as
"nothing is running".

Read-only and side-effect free. Exits 0 on any answered reading, including
`unknown`; exit 2 only on a usage error.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmTaskRunLiveness'

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}
if ($args.Count -lt 1 -or -not "$($args[0])") {
    [Console]::Error.WriteLine('usage: fm-run-liveness.ps1 <task-id>')
    exit 2
}

[Console]::Out.WriteLine((Format-FmTaskRunLiveness -Liveness (Get-FmTaskRunLiveness -TaskId "$($args[0])")))
exit 0
