#requires -Version 7.0
<#
.SYNOPSIS
    The Claude Code hook entry point: SessionStart, PreToolUse, and Stop.

.DESCRIPTION
    Registered from .claude/settings.json with a per-hook "shell": "powershell"
    so Claude Code runs it natively on Windows. `Get-FmClaudeHookSettings` emits
    the exact settings block.

    WINDOWS-UNVERIFIED: every hook-observable behaviour here - native PowerShell
    hook execution, payload delivery on stdin, exit-2 blocking, and Stop
    asyncRewake - is written to Claude Code's documentation and has not been
    exercised against Claude Code on Windows from this port.

    Exit contract:
      0  allow, and for SessionStart the digest on stdout
      2  block, with the reason on stderr (Stop) or a deny object on stderr
         (PreToolUse; stdout stays empty because Claude requires that on deny)

    Any unexpected failure inside a hook exits 0. A hook that crashes must never
    take a session with it.

.PARAMETER Event
    SessionStart, PreToolUse, or Stop.

.PARAMETER Check
    PreToolUse: arm|cd|subagent. Stop: turnend-guard|autoarm.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event',
    Justification = 'The name is a published wiring contract: the .claude/settings.json entries this repo writes invoke "fm-claude-hook.ps1 -Event <event>", so renaming it would break every installed hook.')]
param(
    [Parameter(Mandatory)][ValidateSet('SessionStart', 'PreToolUse', 'Stop')][string]$Event,
    [string]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'fm-module-load.ps1')

    $hookArgs = @{ Event = $Event }
    if ($Check) { $hookArgs['Check'] = $Check }
    $decision = Invoke-FmClaudeHook @hookArgs

    foreach ($line in $decision.Stdout) { [Console]::Out.WriteLine([string]$line) }
    foreach ($line in $decision.Stderr) { [Console]::Error.WriteLine([string]$line) }
    exit $decision.ExitCode
} catch {
    # Fail open, loudly enough to be diagnosable but never blocking.
    [Console]::Error.WriteLine("fm-claude-hook: $Event failed open: $_")
    exit 0
}
