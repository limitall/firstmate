#requires -Version 7.0
<#
.SYNOPSIS
    The Claude Code hook entry point: SessionStart, PreToolUse, and Stop.

.DESCRIPTION
    Registered from .claude/settings.json with a per-hook "shell": "powershell"
    so Claude Code runs it natively on Windows. `Get-FmClaudeHookSettings` emits
    the exact settings block.

    THE PAYLOAD ARRIVES ON STDIN, AND IT CAN ARRIVE TWO WAYS. Claude Code runs
    this hook as

        pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command
            "& \"$env:CLAUDE_PROJECT_DIR/bin/fm-claude-hook.ps1\" -Event ..."

    with the JSON payload on the process's stdin - MEASURED on the captain's
    laptop against Claude Code 2.1.228, which is also where the exact command
    line above came from. In that shape the payload reaches the script only as
    raw console input: PowerShell puts nothing on the script's own pipeline, so
    Invoke-FmClaudeHook reads it with [Console]::In.ReadToEnd().

    But a PowerShell caller that pipes the payload in - `$payload |
    fm-claude-hook.ps1 -Event PreToolUse -Check cd`, `Get-Content p.json | ...`,
    or any host that wraps the hook as `$input | & <script>` - delivers it as
    PIPELINE INPUT instead. Without a pipeline-bound parameter that is not a
    payload the script ignores, it is a PARAMETER BINDING FAILURE:

        The input object cannot be bound to any parameters for the command
        either because the command does not take pipeline input ...

    which happens BEFORE the try below and so cannot be caught there. The script
    then exits non-zero having never run the guard at all. -InputObject exists to
    make that shape impossible: it accepts anything, so no input can fail to
    bind, and the collected lines become the payload.

    ABSENT OR UNPARSEABLE PAYLOAD: FAIL OPEN, deliberately. With no payload there
    is no command to judge - the tool call is named nowhere else - so the only
    honest answers are "allow" and "deny everything", and denying everything is
    the outage this entry point exists to prevent. It is what bash does too
    (`[ -n "$PAYLOAD" ] || exit 0`, and the same for a payload jq cannot read).
    The guards are seatbelts against agent MISTAKES, not a security boundary
    against an agent deliberately withholding its own stdin - such an agent could
    equally not call the hook at all. Failing open never widens what the guard
    catches: a payload that DOES parse is always judged, and only the policy
    owner may decide deny.

    WINDOWS-UNVERIFIED: exit-2 blocking and Stop asyncRewake are written to
    Claude Code's documentation and have not been exercised from this port.
    Payload delivery on stdin, and the invocation shape above, are no longer
    unverified - see docs/claude-hooks-windows.md for what was measured.

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

.PARAMETER InputObject
    The hook payload when a PowerShell caller pipes it in. Never passed by
    Claude Code, which uses raw stdin; it exists so that shape binds instead of
    erroring. Untyped on purpose - anything at all must bind.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidAssignmentToAutomaticVariable', 'Event',
    Justification = 'The name is a published wiring contract: the .claude/settings.json entries this repo writes invoke "fm-claude-hook.ps1 -Event <event>", so renaming it would break every installed hook.')]
param(
    [Parameter(Mandatory)][ValidateSet('SessionStart', 'PreToolUse', 'Stop')][string]$Event,
    [string]$Check,
    [Parameter(ValueFromPipeline)][AllowEmptyString()][AllowNull()]$InputObject
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $piped = [System.Collections.Generic.List[string]]::new()
}

process {
    # Runs once per piped object, and not at all when nothing is piped - which is
    # exactly how the two transports are told apart below.
    if ($null -ne $InputObject) { $piped.Add([string]$InputObject) }
}

end {
    try {
        . (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmClaudeHook'

        $hookArgs = @{ Event = $Event }
        if ($Check) { $hookArgs['Check'] = $Check }
        # Bind -Payload ONLY for the pipeline transport. Leaving it unbound is
        # what tells Invoke-FmClaudeHook to read raw stdin itself, which is the
        # transport Claude Code actually uses; binding an empty string here would
        # look like a genuinely empty payload and suppress that read.
        if ($piped.Count -gt 0) { $hookArgs['Payload'] = ($piped -join "`n") }

        $decision = Invoke-FmClaudeHook @hookArgs

        foreach ($line in $decision.Stdout) { [Console]::Out.WriteLine([string]$line) }
        foreach ($line in $decision.Stderr) { [Console]::Error.WriteLine([string]$line) }
        exit $decision.ExitCode
    } catch {
        # Fail open, loudly enough to be diagnosable but never blocking.
        [Console]::Error.WriteLine("fm-claude-hook: $Event failed open: $_")
        exit 0
    }
}
