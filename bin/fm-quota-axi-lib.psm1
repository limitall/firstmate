# fm-quota-axi-lib.psm1 - quota-axi compatibility floor for the bootstrap
# diagnostic.
# Twin: bin/fm-quota-axi-lib.sh
#
# 0.1.16 is the floor because it is the first build that reports each
# provider's credential sources independently and exposes Grok
# `state.authStatus`. Without those fields a dispatch candidate cannot be
# checked against the authentication surface it actually uses, which is how one
# harness's expired CLI token used to produce a captain-facing sign-out claim
# for a candidate that never read it.
#
# This file is the single owner of that version number on the PowerShell side,
# exactly as its bash twin is on the bash side. bin/fm-bootstrap turns a
# failing check into the operator-facing MISSING diagnostic, which is what
# keeps an older build from reaching a dispatch intake at all.
#
# bash -> PowerShell:
#   FM_QUOTA_AXI_MIN         -> Get-FmQuotaAxiMinimumVersion
#   fm_quota_axi_compatible  -> Test-FmQuotaAxiCompatible
#
# The bash exposes the floor as a shell variable a sourcing caller can read;
# a PowerShell module has its own scope, so the floor is published as a
# function instead. Both worlds still have ONE place to edit when it moves.
#
# DELIBERATE DIVERGENCE - the timeout fallback chain.
# The bash needs an external stopwatch and tries `timeout`, then `gtimeout`,
# then a hand-rolled fork/alarm perl one-liner, and reports INCOMPATIBLE when
# none of the three exists - a host with no stopwatch fails a perfectly good
# quota-axi. PowerShell bounds a child in-process (Invoke-FmTool's
# -TimeoutSeconds), so that whole chain disappears and the "no stopwatch"
# refusal has no twin here. Consequence, stated rather than hidden: on a host
# lacking all three tools this returns the TRUE answer where bash returns
# "incompatible". Every Git Bash and macOS/Linux host in scope ships
# `timeout`, and quota-axi is absent on this machine, so both worlds answer
# "incompatible" here for the same reason - the tool is not installed.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# The single owner of the floor. Kept as a private module variable with a
# published accessor rather than a bare global: PSAvoidGlobalVars, and a
# module-scoped value cannot be silently rewritten by a caller the way an
# exported shell variable can.
$script:FmQuotaAxiMin = '0.1.16'

# Same expression as bin/fm-tasks-axi-lib's, and same reason: it is the exact
# twin of the sed program both bash libs use, greedy leading `.*` included.
$script:FmQuotaAxiVersionRe = [regex]::new('.*([0-9][0-9]*)\.([0-9][0-9]*)\.([0-9][0-9]*)')

<#
.SYNOPSIS
The full executable path of an external tool, or $null when it is not on PATH.
.DESCRIPTION
The `command -v` twin, returning the PATH rather than a boolean. quota-axi is a
Node-style CLI, which on Windows installs as a `quota-axi.cmd` shim. Get-Command
resolves that shim from the bare name because it honors PATHEXT - but
CreateProcess does NOT: it appends only `.exe`, so starting a process named
'quota-axi' fails with "cannot find the file specified" even though the tool is
plainly installed (verified on this host). Detecting the tool and then failing
to run it would turn a healthy install into a bootstrap MISSING diagnostic, so
the invocation below uses the RESOLVED path.

Duplicated in bin/fm-tasks-axi-lib.psm1 for the same reason. The wave report
asks for this to move into bin/fm-common.psm1 as the natural home.
#>
function Resolve-FmQuotaAxiToolPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $found = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    return $found[0].Source
}

<#
.SYNOPSIS
The quota-axi version floor this firstmate requires.
#>
function Get-FmQuotaAxiMinimumVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmQuotaAxiMin
}

<#
.SYNOPSIS
True when the installed quota-axi meets the compatibility floor.
.DESCRIPTION
-TimeoutSeconds mirrors the bash twin's optional first argument, including its
input validation: an empty value, any non-digit character, or the exact string
'0' is itself a refusal (returns $false) rather than being treated as "no
timeout". That is not defensive noise - bootstrap passes an operator-supplied
value, and silently reinterpreting a malformed one as "wait forever" is how a
diagnostic hangs a session start.

An unparseable version is incompatible, never assumed current, so a
development or vendored build cannot pass a floor it was never checked
against. The parse demands exactly three integer fields and nothing after
them, matching the bash `[ -z "$extra" ]` guard on both the reported version
and the floor.
#>
function Test-FmQuotaAxiCompatible {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$TimeoutSeconds = '')

    $tool = Resolve-FmQuotaAxiToolPath 'quota-axi'
    if ($null -eq $tool) { return $false }

    $timeout = 0
    if ($TimeoutSeconds -ne '') {
        # bash: case "$timeout" in ''|*[!0-9]*|0) return 1 ;; esac
        if ($TimeoutSeconds -notmatch '^[0-9]+$') { return $false }
        if ($TimeoutSeconds -eq '0') { return $false }
        # '00' passes the bash guard and then means "no timeout" to the
        # timeout(1) command; -TimeoutSeconds 0 means the same here.
        $timeout = [int]$TimeoutSeconds
    }

    # -StdIn '' is the `</dev/null` twin: stdin is redirected and immediately
    # closed, so a build that would prompt gets EOF instead of blocking a
    # bootstrap probe forever.
    $invoke = @{ FilePath = $tool; Arguments = @('--version'); StdIn = '' }
    if ($timeout -gt 0) { $invoke['TimeoutSeconds'] = $timeout }
    $result = Invoke-FmTool @invoke
    if (-not $result.Ok) { return $false }

    $parts = $null
    foreach ($line in ($result.StdOut -split "`n")) {
        $m = $script:FmQuotaAxiVersionRe.Match($line)
        if ($m.Success) {
            $parts = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
            break
        }
    }
    if ($null -eq $parts) { return $false }

    $floor = $script:FmQuotaAxiMin.Split('.')
    if ($floor.Length -ne 3) { return $false }

    # Explicit [long] casts, not PowerShell's implicit coercion: '0.9' vs
    # '0.10' compared as STRINGS would rank 9 above 10 and quietly accept a
    # build below the floor. The bash `-gt`/`-eq`/`-ge` were always integer.
    [long]$major = 0; [long]$minor = 0; [long]$patch = 0
    [long]$minMajor = 0; [long]$minMinor = 0; [long]$minPatch = 0
    if (-not [long]::TryParse($parts[0], [ref]$major)) { return $false }
    if (-not [long]::TryParse($parts[1], [ref]$minor)) { return $false }
    if (-not [long]::TryParse($parts[2], [ref]$patch)) { return $false }
    if (-not [long]::TryParse($floor[0], [ref]$minMajor)) { return $false }
    if (-not [long]::TryParse($floor[1], [ref]$minMinor)) { return $false }
    if (-not [long]::TryParse($floor[2], [ref]$minPatch)) { return $false }

    if ($major -gt $minMajor) { return $true }
    if ($major -ne $minMajor) { return $false }
    if ($minor -gt $minMinor) { return $true }
    if ($minor -ne $minMinor) { return $false }
    return ($patch -ge $minPatch)
}

Export-ModuleMember -Function @(
    'Get-FmQuotaAxiMinimumVersion',
    'Test-FmQuotaAxiCompatible'
)
