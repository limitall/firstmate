#requires -Version 7.0
<#
.SYNOPSIS
fm-promote.ps1 - promote a scout task to a ship task in place.

.DESCRIPTION
Port of bin/fm-promote.sh. The crewmate keeps its window, worktree, and loaded
context; only the contract changes. kind= is flipped to ship in
state/<task-id>.meta so teardown applies the full ship-task protection again.

A scout records no delivery posture, so promotion is where this task's delivery
contract is decided: -Mode and -Yolo are REQUIRED and written into the meta
alongside the kind= flip. Firstmate resolves both at promotion time, having just
read the scout's report; data/projects.md holds the captain's standing posture
as context, and this command never looks it up.

After promoting, send the crewmate the printed "next:" line - its ship
instructions, which require it to inventory its scratch state, return to a clean
default-branch base, and leave scratch commits behind, carrying over only the
changes it intends to ship.

Exit codes: 0 promoted, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-promote.ps1 my-scout -Mode local-only -Yolo off
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [string]$Mode = '',
    [string]$Yolo = '',
    [string]$StateDir = '',
    [string]$FirstmateHome = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmPromote'

if (-not $TaskId) {
    [Console]::Error.WriteLine('usage: fm-promote.ps1 <task-id> -Mode <no-mistakes|direct-PR|local-only> -Yolo <on|off>')
    exit 2
}
# Refused here rather than by a mandatory parameter, because a mandatory
# parameter PROMPTS - and a lifecycle command that stops to ask in a
# non-interactive session wedges whatever ran it.
if (-not $Mode) {
    [Console]::Error.WriteLine('error: promotion requires -Mode <no-mistakes|direct-PR|local-only>; decide it now ' +
        "from the scout's findings and the project's registered posture in data/projects.md")
    exit 1
}
if (-not $Yolo) {
    [Console]::Error.WriteLine('error: promotion requires -Yolo <on|off>; it is this task''s routine approval ' +
        'authority, not a project lookup')
    exit 1
}

try {
    $result = Invoke-FmPromote -TaskId $TaskId -Mode $Mode -Yolo $Yolo -StateDir $StateDir -FirstmateHome $FirstmateHome
    if ($null -eq $result) { exit 0 }
    [Console]::Out.Write("$($result.Message)`n")
    [Console]::Out.Write("$($result.NextStep)`n")
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
