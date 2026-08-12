#requires -Version 7.0
<#
    .SYNOPSIS
    The firstmate watcher: block, classify supervision wakes, absorb the benign
    majority, and exit on the first actionable one.

    .DESCRIPTION
    Thin entry point for Start-FmWatch. Native Windows PowerShell port of
    bin/fm-watch.sh.

    Printed reason lines (stdout, one line, then exit):
      signal: <file>...      status/turn-end signals, surfaced when a listed
                             status has a captain-relevant verb OR a no-verb
                             signal's crew is not provably working
      stale: <window>        a pane gone quiet; a provably-working stale is
                             absorbed with a wedge timer, a declared pause uses
                             its own long re-surface cadence
      check: <script>: <out> authenticated check output, always actionable
      heartbeat              fleet-scan backstop found an unsurfaced
                             captain-relevant status
    For normal supervision, resume the session-start primary-harness protocol
    after each printed reason. Duplicate invocations no-op through the watcher
    singleton lock.

    .PARAMETER MaxCycles
    Stop after this many cycles instead of blocking. Diagnostic seam only.

    .EXAMPLE
    pwsh bin/fm-watch.ps1
#>
[CmdletBinding()]
param(
    [int]$MaxCycles = 0,
    [switch]$SkipTerminalWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Start-FmWatch'

$result = Start-FmWatch -MaxCycles $MaxCycles -SkipTerminalWait:$SkipTerminalWait
exit $result.ExitCode
