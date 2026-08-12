# fm-backend-hometag-lib.psm1 - shared per-installation home-tag derivation.
# Twin: bin/fm-backend-hometag-lib.sh
#
# For session-provider backends whose container has ONE namespace shared by
# every firstmate home on the machine, with no native per-home split (cmux's
# one app-global workspace list, zellij's one shared "firstmate" session's tab
# bar). Without a per-home discriminator embedded in the actual title/name, two
# firstmate homes (two secondmates, a primary plus a secondmate, or two
# independent primary installations) whose task ids happen to collide can
# send/peek/close each other's tabs - the gap a captain-directed no-mistakes
# review gate caught for cmux (docs/cmux-backend.md) and this same tag
# mechanism was later ported to zellij to close for the same reason
# (docs/zellij-backend.md "Home-scoped tab titles").
#
# Get-FmBackendHomeTag derives a short, stable tag: a readable prefix
# ("firstmate" for the primary home, "2ndmate-<id>" for a secondmate home
# carrying .fm-secondmate-home) plus a short hash of the resolved root path, so
# distinct installations - including multiple primaries on one machine - never
# collide even though they share one backend-global namespace.
#
# Moving/relocating a firstmate installation changes its root path and
# therefore its tag; titles created under the old tag simply stop matching - an
# accepted limitation, no worse than the existing fact that a task's recorded
# absolute worktree path does not survive a move either.
#
# bash -> PowerShell:
#   FM_BACKEND_HOMETAG_SECONDMATE_MARKER -> Get-FmBackendHometagMarkerName
#   fm_backend_hometag                   -> Get-FmBackendHomeTag
#
# ---------------------------------------------------------------------------
# FM_HOME/FM_ROOT become parameters, not ambient state
# ---------------------------------------------------------------------------
# The bash reads $FM_HOME and $FM_ROOT as SHELL variables its callers set
# before sourcing ("callers source this file AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks"). A PowerShell module cannot see its caller's
# variables, so both are real parameters here, defaulting to Get-FmContext -
# which applies the identical FM_HOME / FM_ROOT_OVERRIDE precedence. A
# converted adapter that has already resolved its own values passes them in
# explicitly, which is strictly clearer than the ambient version.
#
# ---------------------------------------------------------------------------
# THE HASH INPUT IS A CROSS-WORLD CONTRACT
# ---------------------------------------------------------------------------
# A bash cmux adapter and a PowerShell one may address the SAME app-global
# workspace list during the transition, so both must derive the SAME tag for
# one installation or each becomes blind to the other's tabs. The hashed
# string is therefore the POSIX physical path (`cd "$FM_ROOT" && pwd -P`), not
# the native one: /f/Plotex_projects/firstmate, never F:\Plotex_projects\...
#
# One consequence, stated rather than discovered later: under an MSYS MOUNT
# ALIAS - /tmp, which maps onto C:\Users\<u>\AppData\Local\Temp - bash's
# `pwd -P` keeps the alias (/tmp/x) while this resolves the physical location
# (/c/Users/<u>/AppData/Local/Temp/x), so the two derive different tags for
# such a root. Real firstmate homes live under drive paths where the two
# spellings coincide; only a fixture rooted in /tmp can hit it.
#
# The bash's third hash fallback (`cksum`, used only when neither shasum nor
# sha256sum exists) has no twin: .NET always has SHA-256, and every host in
# scope ships one of the two SHA tools, so this always takes the SHA path the
# bash takes first.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmBackendHometagSecondmateMarker = '.fm-secondmate-home'

<#
.SYNOPSIS
The marker file name that identifies a secondmate home.
#>
function Get-FmBackendHometagMarkerName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmBackendHometagSecondmateMarker
}

<#
.SYNOPSIS
The short, stable per-installation tag: "<prefix>-<8 hex>".
.DESCRIPTION
Prefix is "2ndmate-<id>" when the home carries a non-empty .fm-secondmate-home
marker, else "firstmate". The suffix is the first 8 lowercase hex digits of the
SHA-256 of the root's POSIX physical path.

Note what is NOT checked, deliberately: the marker's id is used verbatim after
whitespace removal, with no character validation. bin/fm-primary-scope-lib
validates the same marker strictly because it gates whether a HOOK fires;
here the id only decorates a tab title, and adding validation would make a
home that the bash tags one way get tagged another way here - the one outcome
this file exists to prevent.
#>
function Get-FmBackendHomeTag {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$FmHome,
        [string]$FmRoot
    )

    if (-not $PSBoundParameters.ContainsKey('FmHome') -or [string]::IsNullOrEmpty($FmHome) -or
        -not $PSBoundParameters.ContainsKey('FmRoot') -or [string]::IsNullOrEmpty($FmRoot)) {
        $context = Get-FmContext $PSScriptRoot
        if ([string]::IsNullOrEmpty($FmHome)) { $FmHome = $context.Home }
        if ([string]::IsNullOrEmpty($FmRoot)) { $FmRoot = $context.Root }
    }

    $marker = Join-Path (ConvertTo-FmNativePath $FmHome) $script:FmBackendHometagSecondmateMarker
    $prefix = 'firstmate'
    if ([System.IO.File]::Exists($marker)) {
        # `tr -d '[:space:]'` over the WHOLE file, not just its first line, and
        # the C-locale class rather than .NET's `\s` so an id differing only by
        # an NBSP is tagged identically in both worlds.
        $id = (Get-FmFileText $marker) -replace '[ \t\n\v\f\r]', ''
        if ($id -ne '') { $prefix = "2ndmate-$id" }
    }

    # `cd "$FM_ROOT" 2>/dev/null && pwd -P || root=$FM_ROOT`: an unresolvable
    # root falls back to the given spelling rather than failing, so a tag is
    # always produced.
    $nativeRoot = ConvertTo-FmNativePath $FmRoot
    $physical = $null
    try {
        if (Test-Path -LiteralPath $nativeRoot -PathType Container) {
            $resolved = [System.IO.Directory]::ResolveLinkTarget($nativeRoot, $true)
            $physical = if ($null -ne $resolved) { $resolved.FullName } else { [System.IO.Path]::GetFullPath($nativeRoot) }
        }
    } catch {
        $physical = $null
    }
    $root = if ($null -ne $physical) { ConvertTo-FmPosixPath $physical } else { $FmRoot }

    $digest = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($root))
    $hash = [System.Convert]::ToHexString($digest).ToLowerInvariant().Substring(0, 8)
    return "$prefix-$hash"
}

Export-ModuleMember -Function @(
    'Get-FmBackendHometagMarkerName',
    'Get-FmBackendHomeTag'
)
