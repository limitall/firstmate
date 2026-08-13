#requires -Version 7.0
<#
.SYNOPSIS
fm-autolaunch.ps1 - type this home's configured startup command into a herdr
pane, wait, and submit it only if the captain has not touched the pane.

.DESCRIPTION
Thin entry point over Invoke-FmAutolaunch. Off unless config/autolaunch names a
command; docs/autolaunch-windows.md owns the file format and the reason the
feature is opt-in.

The command is typed UNSUBMITTED, so the captain sees what is about to run, and
then a grace window (10 seconds by default) runs. Any change to the pane during
that window - a keystroke, a running process, a read that fails - stands the
whole thing down without submitting and without disturbing what the captain
typed. Untouched, one Enter is sent and the result says whether the command
actually started.

Exit codes: 0 the command started, or there was deliberately nothing to do (no
config, stood down, -WhatIf); 1 refused, or submitted without confirmation; 2
usage. Every non-started outcome prints its reason.

.PARAMETER Target
The herdr pane to arm, as `<session>:<pane-id>`.

.PARAMETER FirstmateHome
The home whose config/autolaunch applies. Defaults to the resolved FM_HOME.

.PARAMETER DelaySeconds
Override the configured window, in seconds.

.PARAMETER PollSeconds
How often the window re-checks the pane.

.EXAMPLE
./bin/fm-autolaunch.ps1 default:w1:p2

.EXAMPLE
./bin/fm-autolaunch.ps1 default:w1:p2 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Target = '',
    [string]$FirstmateHome = '',
    [int]$DelaySeconds = 0,
    [double]$PollSeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmAutolaunch'

if (-not $Target) {
    [Console]::Error.WriteLine('usage: fm-autolaunch.ps1 <session>:<pane-id> [-DelaySeconds <n>] [-WhatIf]')
    exit 2
}
# Refusing the pane this command is itself running in, by name, rather than
# typing into a pane whose keyboard input is currently going to this script.
if ($env:HERDR_PANE_ID -and $Target -like "*$($env:HERDR_PANE_ID)") {
    [Console]::Error.WriteLine("error: '$Target' is the pane this command is running in; arm another pane")
    exit 1
}

try {
    $result = Invoke-FmAutolaunch -Target $Target -FirstmateHome $FirstmateHome `
        -DelaySeconds $DelaySeconds -PollSeconds $PollSeconds
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

if ($result.Action -eq 'submitted') {
    [Console]::Out.WriteLine("autolaunch: $($result.Reason)")
    exit 0
}
[Console]::Error.WriteLine("autolaunch $($result.Action): $($result.Reason)")
if ($result.Action -in @('disabled', 'stood-down', 'skipped')) { exit 0 }
exit 1
