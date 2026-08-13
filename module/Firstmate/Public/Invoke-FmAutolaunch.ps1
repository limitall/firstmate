#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Type this home's configured startup command into a herdr pane, wait, and submit
it only if the captain has not touched the pane.

.DESCRIPTION
Off unless config/autolaunch says otherwise. The file names the command and,
optionally, the length of the window; there is no built-in command, because the
one the captain uses on their own laptop disables Claude's permission checks for
every session it starts and must never be something this repo does by default.
See docs/autolaunch-windows.md for the file format and the safety argument.

What happens when it is on: the command is typed into the named pane and left
UNSUBMITTED, so the captain sees exactly what is about to run. A grace window
follows. If anything about that pane changes - a keystroke, a repaint, a running
process, a read that fails - firstmate stands down and touches nothing further,
leaving the captain's own input intact. Untouched for the whole window, it sends
one Enter and reports whether the command actually started.

The target is an explicit herdr pane, `<session>:<pane-id>`. A pane this home has
recorded as a worker's endpoint is refused: autolaunch types an interactive
command, and a worker's pane is not a place to type one.

.PARAMETER Target
The herdr pane to arm, as `<session>:<pane-id>`.

.PARAMETER FirstmateHome
The home whose config/autolaunch and state/ apply. Defaults to the resolved
FM_HOME.

.PARAMETER DelaySeconds
Override the configured window, in seconds. Omitted or 0 uses the configured
value (10 by default).

.PARAMETER PollSeconds
How often the window re-checks the pane. The default is one second.

.PARAMETER SettleSeconds
How long the pane is given to repaint before and after typing.

.EXAMPLE
Invoke-FmAutolaunch -Target 'default:w1:p2'

.EXAMPLE
Invoke-FmAutolaunch -Target 'default:w1:p2' -WhatIf
#>
function Invoke-FmAutolaunch {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Declared so -WhatIf reaches Invoke-FmAutolaunchArm, which owns the single ShouldProcess gate immediately before the one state-changing call (typing into the pane). Everything this function does first is reading config and refusing.')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Target,
        [string]$FirstmateHome = '',
        [int]$DelaySeconds = 0,
        [double]$PollSeconds = 1,
        [double]$SettleSeconds = 0.4
    )

    $homeArgs = @{}
    if ($FirstmateHome) { $homeArgs['HomePath'] = $FirstmateHome }
    $configDir = Get-FmConfigRoot @homeArgs
    $stateDir = Get-FmStateRoot @homeArgs

    $config = Read-FmAutolaunchConfig -ConfigDir $configDir
    if ($config.Status -eq 'off') {
        return New-FmAutolaunchResult -Action 'disabled' -Target $Target -Reason $config.Reason
    }
    if ($config.Status -ne 'enabled') {
        # An unusable file is a refusal, never a silent off: the captain who
        # wrote it believes autolaunch is on.
        return New-FmAutolaunchResult -Action 'refused' -Target $Target -Reason $config.Reason
    }

    if (Test-FmAutolaunchWorkerPane -Target $Target -StateDir $stateDir) {
        return New-FmAutolaunchResult -Action 'refused' -Target $Target -Command $config.Command `
            -DelaySeconds $config.DelaySeconds `
            -Reason "'$Target' is a worker's pane in this home; autolaunch never types into one"
    }

    $delay = if ($DelaySeconds -gt 0) { $DelaySeconds } else { $config.DelaySeconds }

    Invoke-FmAutolaunchArm -Target $Target -Command $config.Command -DelaySeconds $delay `
        -PollSeconds $PollSeconds -SettleSeconds $SettleSeconds
}
