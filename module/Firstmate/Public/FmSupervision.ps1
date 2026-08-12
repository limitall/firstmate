#requires -Version 7.0
<#
    Public/FmSupervision.ps1 - Get-FmSupervisionInstructions, stage 4 of the
    session-start digest and the source of every guard's repair sentence.
    Private/FmSupervision.ps1 owns the renderers and documents why the emitted
    protocol is selected from the seams present in this build.
#>

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The supervision operating block for this session, or its one repair line.

.DESCRIPTION
    Stage 4 of the session-start digest, and the repair sentence every guard and
    turn-end banner ends with. Two call shapes bind here and both are
    load-bearing - the digest's named form and the guard seam's single positional
    hashtable; Private/FmSupervision.ps1's header records why declaring only one
    of them would fail silently rather than loudly.

    The emitted block is the session's actual supervision contract, so it reports
    only mechanisms that are present in THIS build: an absent automatic arm is
    named as absent and the session is told to keep the cycle itself, rather than
    being pointed at a hook that will do nothing.

.PARAMETER Options
    Positional hashtable form used by the guard seam. Keys: Harness, ReadOnly,
    Afk, XMode, QueuePending, RepairLine. Named parameters override it.

.PARAMETER Harness
    The primary harness. Defaults to Get-FmHarness when not supplied.

.PARAMETER ReadOnly
    This session did not verify fleet-lock ownership. Accepts 0/1 or a bool.

.PARAMETER Afk
    Away mode is active. Accepts 0/1 or a bool. Not available on this port, but
    honoured so a home shared with a Linux firstmate renders the same block.

.PARAMETER XMode
    The relay is active. Accepts 0/1 or a bool.

.PARAMETER QueuePending
    Queued wakes are waiting; the repair line then leads with draining them.

.PARAMETER RepairLine
    Return the single repair sentence instead of the block.

.EXAMPLE
    Get-FmSupervisionInstructions -Harness claude -ReadOnly 0 -Afk 0 -XMode 0

.EXAMPLE
    Get-FmSupervisionInstructions @{ RepairLine = $true; Afk = $false }
#>
function Get-FmSupervisionInstructions {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][hashtable]$Options,
        [AllowNull()][AllowEmptyString()][string]$Harness,
        [AllowNull()][object]$ReadOnly,
        [AllowNull()][object]$Afk,
        [AllowNull()][object]$XMode,
        [AllowNull()][object]$QueuePending,
        [AllowNull()][object]$RepairLine
    )

    $opt = @{}
    if ($Options) { foreach ($key in $Options.Keys) { $opt[[string]$key] = $Options[$key] } }
    foreach ($name in @('Harness', 'ReadOnly', 'Afk', 'XMode', 'QueuePending', 'RepairLine')) {
        if ($PSBoundParameters.ContainsKey($name)) { $opt[$name] = $PSBoundParameters[$name] }
    }

    $harnessName = if ($opt.ContainsKey('Harness') -and $opt['Harness']) { [string]$opt['Harness'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($harnessName)) {
        $harnessName = 'unknown'
        $detector = Get-Command -Name 'Get-FmHarness' -ErrorAction SilentlyContinue
        if ($detector) {
            try { $harnessName = [string](& $detector) } catch { $harnessName = 'unknown' }
        }
        if ([string]::IsNullOrWhiteSpace($harnessName)) { $harnessName = 'unknown' }
    }

    $readOnlyFlag = Get-FmSupervisionFlag -Value $opt['ReadOnly']
    $afkFlag = Get-FmSupervisionFlag -Value $opt['Afk']
    $xModeFlag = Get-FmSupervisionFlag -Value $opt['XMode']
    $queueFlag = Get-FmSupervisionFlag -Value $opt['QueuePending']

    # bash promotes X mode from the config artifact when the caller did not.
    if (-not $xModeFlag) {
        $configRoot = ''
        try { $configRoot = (Get-FmSessionPaths).Config } catch { $configRoot = '' }
        if ($configRoot -and (Test-Path -LiteralPath (Join-Path $configRoot 'x-mode.env') -PathType Leaf)) {
            $xModeFlag = $true
        }
    }

    if (Get-FmSupervisionFlag -Value $opt['RepairLine']) {
        # TurnEnd is accepted and deliberately not branched on: bash has no such
        # flag, and every repair sentence a turn-end banner uses already names
        # the turn boundary. Rendering a second variant would put two spellings
        # of one instruction in front of the captain.
        return (Get-FmSupervisionRepairSentence -Harness $harnessName -ReadOnly $readOnlyFlag `
                -Afk $afkFlag -XMode $xModeFlag -QueuePending $queueFlag)
    }

    $out = @(
        $script:FmSupervisionRule
        "SUPERVISION OPERATING INSTRUCTIONS - primary harness: $harnessName"
        $script:FmSupervisionRule
        'Current state:'
    )
    if ($readOnlyFlag) {
        $out += '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
    } else {
        $out += '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
    }
    if ($afkFlag) {
        $out += '- Away mode: marker present, but away mode is NOT available on this port; nothing will inject an escalation while the captain is gone (AGENTS.md section 14).'
    } else {
        $out += '- Away mode: inactive.'
    }
    if ($xModeFlag) {
        $out += '- X mode: marker present, but the relay is NOT available on this port; nothing here posts anywhere public (AGENTS.md section 14).'
    } else {
        $out += '- X mode: inactive; use the default watcher cadence.'
    }
    if (Test-FmSupervisionAutoArmAvailable) {
        $out += '- Automatic re-arm: available; the arm owner establishes and follows the cycle.'
    } else {
        $out += '- Automatic re-arm: NOT available in this build; this session keeps the cycle itself.'
    }
    $out += (Get-FmSupervisionOrdinaryWakeLine -Harness $harnessName)
    $out += ''

    if ($harnessName -eq 'claude') {
        $out += $(if (Test-FmSupervisionAutoArmAvailable) {
                Get-FmSupervisionClaudeArmedProtocol
            } else {
                Get-FmSupervisionClaudeManualProtocol
            })
    } else {
        $out += (Get-FmSupervisionUnknownProtocol -Harness $harnessName)
    }
    $out += ''
    $out
}
