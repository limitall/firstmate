#requires -Version 7.0

<#
.SYNOPSIS
    Bootstrap detection: one line per actionable problem, silence when all good.

.DESCRIPTION
    Port of bin/fm-bootstrap.sh's detect path. Prints one line per actionable
    problem, or an explicit BOOTSTRAP_INFO no-action fact, and always returns
    successfully. Silence means all good.

    THIS COMMAND NEVER INSTALLS ANYTHING. AGENTS.md section 3 requires bootstrap
    to detect first, ask for consent, and install only after the captain approves
    in the current session. Installation is Install-FmTool -Approved.

    Line shapes are byte-for-byte with the bash original because the
    bootstrap-diagnostics skill matches on them.

.PARAMETER DetectOnly
    Skip the MUTATING sweeps (PR-check migration, secondmate convergence,
    secondmate liveness, pending remote handoff retry, X-mode artifact writes,
    fleet sync) while still printing every read-only detect line. The TANGLE line
    switches to advisory-only wording with no checkout command. Used by the
    session-start read-only path when another live session holds the fleet lock.

.PARAMETER Locked
    Pass alongside -DetectOnly when the sweeps are skipped because THIS session
    already ran them while holding the fleet lock, rather than because it has no
    lock at all. The two cases differ in exactly one place: repair ownership.

.PARAMETER Network
    Split this run by whether a step talks to the network:
      all  (default) everything, exactly as before. Unrecognized values fall back
           here on purpose: a typo must never silently skip a safety sweep.
      skip every LOCAL step and none of the network ones.
      only ONLY the network steps and nothing else.

.PARAMETER VerboseFacts
    Also print BOOTSTRAP_INFO lines for completed benign facts that are silent by
    default.

.EXAMPLE
    Invoke-FmBootstrap

.EXAMPLE
    Invoke-FmBootstrap -DetectOnly -Network skip
#>
function Invoke-FmBootstrap {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$DetectOnly,
        [switch]$Locked,
        [ValidateSet('all', 'skip', 'only')]
        [string]$Network,
        [switch]$VerboseFacts
    )

    if (-not $PSBoundParameters.ContainsKey('Network')) {
        $Network = switch ($env:FM_BOOTSTRAP_NETWORK) {
            'skip' { 'skip' }
            'only' { 'only' }
            default { 'all' }
        }
    }
    if (-not $DetectOnly -and $env:FM_BOOTSTRAP_DETECT_ONLY -eq '1') { $DetectOnly = [switch]$true }
    if (-not $Locked -and $env:FM_BOOTSTRAP_LOCKED -eq '1') { $Locked = [switch]$true }
    if (-not $VerboseFacts -and $env:FM_BOOTSTRAP_VERBOSE_FACTS -eq '1') { $VerboseFacts = [switch]$true }

    $localPhase = ($Network -ne 'only')
    $networkPhase = ($Network -ne 'skip')
    $paths = Get-FmSessionPaths
    $out = @()

    # This is the first mutating sweep at a locked session boundary: it
    # neutralizes legacy PR checks before any later bootstrap mutation can leave
    # old artifacts runnable.
    if (-not $DetectOnly -and $localPhase) {
        $out += Invoke-FmBootstrapSweep -CommandName 'Invoke-FmPrCheckMigrate'
        $out += Set-FmBootstrapStartupMemoryBudget -Paths $paths
    }

    # The order below is the order the diagnostics have always printed in, so a
    # `skip` run is the same output with the network lines removed.
    if ($localPhase) {
        $out += Get-FmBootstrapLocalToolDiagnostic -ConfigDir $paths.Config
    }
    if ($networkPhase) {
        $gh = Invoke-FmSessionCommandLine -Command 'gh' -Arguments @('auth', 'status')
        if ($gh.ExitCode -ne 0) { $out += 'NEEDS_GH_AUTH' }
    }
    if ($localPhase) {
        $out += Get-FmBootstrapLocalConfigDiagnostic -Paths $paths -DetectOnly:$DetectOnly -Locked:$Locked -VerboseFacts:$VerboseFacts
    }

    if (-not $DetectOnly) {
        if ($networkPhase) {
            # The convergence sweep consumes the liveness sweep's respawn list, so
            # those two always run together in the same phase.
            $out += Invoke-FmBootstrapSweep -CommandName 'Invoke-FmSecondmateLivenessSweep'
            $out += Invoke-FmBootstrapSweep -CommandName 'Invoke-FmSecondmateSync'
            $out += Invoke-FmBootstrapSweep -CommandName 'Invoke-FmSecondmateHandoffResume'
        }
        # X-mode setup writes local relay artifacts only and never leaves the machine.
        if ($localPhase) { $out += Invoke-FmBootstrapSweep -CommandName 'Set-FmXModeArtifact' }
        if ($networkPhase) { $out += Invoke-FmBootstrapSweep -CommandName 'Invoke-FmFleetSync' }
    }
    if ($localPhase) { $out += Get-FmBootstrapHandoffDiagnostic -Paths $paths }

    $out | Where-Object { $null -ne $_ -and $_ -ne '' }
}
