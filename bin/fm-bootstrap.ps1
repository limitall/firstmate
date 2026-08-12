#requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap detection, and captain-approved installs.

.DESCRIPTION
    Detect: prints one line per actionable problem, or an explicit BOOTSTRAP_INFO
    no-action fact, and exits 0. Silence means all good.

    DETECT FIRST, ASK CONSENT, THEN INSTALL. Detection never installs anything.
    `-Install <tool>...` installs only tools the captain approved in the current
    session, and requires -Approved to say so.

.PARAMETER Install
    Tools to install. Requires -Approved.

.PARAMETER Approved
    Assert that the captain approved these installs in the current session.

.PARAMETER DetectOnly
    Skip the six mutating sweeps while still printing every read-only detect line.

.PARAMETER Locked
    With -DetectOnly, state that the sweeps are skipped because THIS session
    already ran them under the fleet lock, not because it holds no lock.

.PARAMETER Network
    all (default) | skip (local steps only) | only (network steps only).

.PARAMETER VerboseFacts
    Also print BOOTSTRAP_INFO lines that are silent by default.
#>
[CmdletBinding()]
param(
    [string[]]$Install,
    [switch]$Approved,
    [switch]$DetectOnly,
    [switch]$Locked,
    [ValidateSet('all', 'skip', 'only')][string]$Network,
    [switch]$VerboseFacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmBootstrap'

if ($Install) {
    Install-FmTool -Name $Install -Approved:$Approved
    exit 0
}

$bootstrapArgs = @{
    DetectOnly   = $DetectOnly
    Locked       = $Locked
    VerboseFacts = $VerboseFacts
}
if ($PSBoundParameters.ContainsKey('Network')) { $bootstrapArgs['Network'] = $Network }

Invoke-FmBootstrap @bootstrapArgs
exit 0
