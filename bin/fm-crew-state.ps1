#requires -Version 7.0
<#
Deterministic read of a crew's CURRENT state.

Usage: fm-crew-state.ps1 <task-id>

state/<id>.status is an append-only EVENT log, so its last line reports the last
event, not the current state. This never infers current state from that tail: it
reads the authoritative source - a no-mistakes run-step attributed to this crew's
branch AND current code identity, else the endpoint's busy signature - and
reconciles the possibly-stale log against it.

Prints one line:
  state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>

Read-only and side-effect free. Exits 0 on any successful read regardless of
state; exit 2 only on a usage error.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmCrewState'

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}
if ($args.Count -lt 1 -or -not "$($args[0])") {
    [Console]::Error.WriteLine('usage: fm-crew-state.ps1 <id>')
    exit 2
}

[Console]::Out.WriteLine((Get-FmCrewState -Id "$($args[0])"))
exit 0
