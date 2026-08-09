# fm-supervisor-target-lib.psm1 - the single owner of supervisor-pane discovery.
# Twin: bin/fm-supervisor-target-lib.sh
#
# The away-mode daemon (bin/fm-supervise-daemon) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal,
# would auto-discover its OWN pane and inject there instead of into the
# captain's).
#
# Because both callers need the identical resolution, it lives here once.
#
# bash -> PowerShell:
#   FM_SUPERVISOR_TARGET_DEFAULT  -> Get-FmSupervisorTargetDefault
#   FM_SUPERVISOR_BACKEND_DEFAULT -> Get-FmSupervisorBackendDefault
#   discover_supervisor_target    -> Get-FmSupervisorTarget
#   discover_supervisor_backend   -> Get-FmSupervisorBackend
#
# ---------------------------------------------------------------------------
# Why these two return an object instead of a string
# ---------------------------------------------------------------------------
# Both bash functions ALWAYS print a value and use their exit status to say
# something else entirely: 0 means "this was really discovered", 1 means "I
# fell back to the legacy default, which may not resolve - warn the operator".
# Callers depend on that second channel (bin/fm-afk-launch treats non-zero as
# a warning path; bin/fm-supervise-daemon validates the target before using
# it). Collapsing it into a bare string would silently turn every unconfigured
# host into a confident answer, so the twins return @{ Value; Detected } and
# the caller reads Detected where the bash reads `if target=$(...)`.
#
# This is the general idiom for a bash function whose exit status carries
# meaning BEYOND "no value": return the value plus a named boolean. A function
# whose status only means "no value" returns $null instead (see
# bin/fm-tangle-lib.psm1).

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
$script:FmSupervisorTargetDefault = 'firstmate:0'
$script:FmSupervisorBackendDefault = 'tmux'

<#
.SYNOPSIS
The legacy tmux target used when nothing is configured or detected.
#>
function Get-FmSupervisorTargetDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmSupervisorTargetDefault
}

<#
.SYNOPSIS
The backend assumed when nothing is configured or detected.
#>
function Get-FmSupervisorBackendDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmSupervisorBackendDefault
}

<#
.SYNOPSIS
Resolve the pane running firstmate. Returns @{ Value; Detected }.
.DESCRIPTION
Priority, unchanged from the bash:
  1. FM_SUPERVISOR_TARGET (explicit override) - may be a tmux target or a
     herdr "<session>:<pane-id>" target; pair with Get-FmSupervisorBackend to
     know which.
  2. TMUX_PANE - tmux sets this in every pane's environment, and it is
     inherited by a process launched from firstmate's own pane.
  3. HERDR_ENV=1 plus HERDR_PANE_ID - herdr injects both into every process it
     manages a pane for; the target is "<session>:<pane-id>" with HERDR_SESSION
     defaulting to "default", mirroring the herdr adapter's own session
     resolution. Checked AFTER TMUX_PANE so a tmux pane nested inside herdr
     still resolves to tmux, matching fm_backend_detect's innermost-first rule.
  4. The legacy tmux default, with Detected = $false so the caller can warn -
     it may not resolve if the session is named differently.

Every read uses Get-FmEnv's `${VAR:-}` semantics, so an exported-but-empty
variable falls through exactly as it does in bash rather than being taken as a
configured empty target.
#>
function Get-FmSupervisorTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $explicit = Get-FmEnv -Name 'FM_SUPERVISOR_TARGET'
    if ($explicit -ne '') { return @{ Value = $explicit; Detected = $true } }

    $tmuxPane = Get-FmEnv -Name 'TMUX_PANE'
    if ($tmuxPane -ne '') { return @{ Value = $tmuxPane; Detected = $true } }

    $herdrPane = Get-FmEnv -Name 'HERDR_PANE_ID'
    if ((Get-FmEnv -Name 'HERDR_ENV') -eq '1' -and $herdrPane -ne '') {
        $session = Get-FmEnv -Name 'HERDR_SESSION' -Default 'default'
        return @{ Value = "${session}:${herdrPane}"; Detected = $true }
    }

    return @{ Value = $script:FmSupervisorTargetDefault; Detected = $false }
}

<#
.SYNOPSIS
Resolve the supervisor pane's BACKEND. Returns @{ Value; Detected }.
.DESCRIPTION
Resolved independently of the target string so an explicit FM_SUPERVISOR_TARGET
override still knows which primitives (tmux vs herdr) to dispatch through -
the override names a pane, not a mechanism. Priority mirrors
Get-FmSupervisorTarget and fm_backend_detect.
#>
function Get-FmSupervisorBackend {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $explicit = Get-FmEnv -Name 'FM_SUPERVISOR_BACKEND'
    if ($explicit -ne '') { return @{ Value = $explicit; Detected = $true } }

    if ((Get-FmEnv -Name 'TMUX_PANE') -ne '') { return @{ Value = 'tmux'; Detected = $true } }

    if ((Get-FmEnv -Name 'HERDR_ENV') -eq '1' -and (Get-FmEnv -Name 'HERDR_PANE_ID') -ne '') {
        return @{ Value = 'herdr'; Detected = $true }
    }

    return @{ Value = $script:FmSupervisorBackendDefault; Detected = $false }
}

Export-ModuleMember -Function @(
    'Get-FmSupervisorTargetDefault',
    'Get-FmSupervisorBackendDefault',
    'Get-FmSupervisorTarget',
    'Get-FmSupervisorBackend'
)
