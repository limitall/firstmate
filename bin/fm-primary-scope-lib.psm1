# fm-primary-scope-lib.psm1 - marker-or-plain-checkout predicate for tracked
# hooks that must act only in a genuine firstmate primary home.
# Twin: bin/fm-primary-scope-lib.sh
#
# This module has no side effects on import, matching the bash twin's contract
# for a file that hook entrypoints source at their very top.
#
# bash -> PowerShell:
#   fm_root_is_secondmate_home -> Test-FmRootIsSecondmateHome
#   fm_primary_scope_matches   -> Test-FmPrimaryScopeMatch
#
# Two bash behaviors here are subtle enough that a "cleaner" PowerShell would
# quietly change what the hooks fire on. Both are preserved deliberately:
#
#   1. `IFS= read -r id < "$marker" || return 1` REQUIRES a terminating
#      newline. read(1) returns non-zero at EOF without a delimiter, so a
#      marker written as `printf '%s' alpha` (no newline) is NOT a valid
#      secondmate marker in bash, even though it holds a perfectly good id.
#      The twin reproduces that: content before the first LF, and no LF at all
#      means no match.
#   2. The whitespace strip is the C-locale POSIX class - space, tab, LF, VT,
#      FF, CR - not .NET's `\s`, which also strips NBSP and the Unicode space
#      separators. A marker whose id differs only by an invisible NBSP must
#      fail the character check in BOTH worlds rather than being normalized
#      into validity by one of them.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$script:FmPrimaryScopeMarkerName = '.fm-secondmate-home'

<#
.SYNOPSIS
True when a root carries a genuine secondmate-home marker.
.DESCRIPTION
Genuine means: the marker is a regular file (never a symlink - a link is how a
non-home would borrow another home's identity), its first line terminates with
a newline, and after whitespace removal it holds a non-empty id made only of
[A-Za-z0-9._-]. Anything else is not a secondmate home.
#>
function Test-FmRootIsSecondmateHome {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)

    $marker = Join-Path (ConvertTo-FmNativePath $Root) $script:FmPrimaryScopeMarkerName

    if (Test-FmSymlink $marker) { return $false }
    if (-not [System.IO.File]::Exists($marker)) { return $false }

    $text = Get-FmFileText $marker
    # The `read` twin: no delimiter anywhere means read(1) failed, so no id.
    $lf = $text.IndexOf("`n")
    if ($lf -lt 0) { return $false }
    $id = $text.Substring(0, $lf) -replace '[ \t\n\v\f\r]', ''

    if ($id -eq '') { return $false }
    # bash: case "$id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    if ($id -match '[^A-Za-z0-9._\-]') { return $false }
    return $true
}

<#
.SYNOPSIS
True when a root is a genuine primary root whose effective state dir is State.
.DESCRIPTION
A valid secondmate marker force-includes a linked secondmate home - a
secondmate's home IS a linked worktree, so the git-layout test below would
otherwise exclude exactly the homes that must be included. Without that
marker, only a PLAIN checkout is primary: a linked task worktree has its own
per-worktree git dir under the common one, so --git-dir and --git-common-dir
disagree there and agree only in a plain checkout.

The three structural checks that follow (AGENTS.md, bin/, and the effective
state dir) are what stop a hook from firing inside some unrelated repo that
happens to be a plain checkout.
#>
function Test-FmPrimaryScopeMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    $nativeRoot = ConvertTo-FmNativePath $Root

    if (-not (Test-FmRootIsSecondmateHome -Root $Root)) {
        # A missing git is "not a primary scope", not an exception: the bash
        # `|| return 1` on a failed git swallows that case the same way.
        if (-not (Test-FmCommand 'git')) { return $false }
        $gitDir = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $nativeRoot, 'rev-parse', '--git-dir')
        if (-not $gitDir.Ok) { return $false }
        $commonDir = Invoke-FmTool -FilePath 'git' -Arguments @('-C', $nativeRoot, 'rev-parse', '--git-common-dir')
        if (-not $commonDir.Ok) { return $false }
        # Compared as raw strings, exactly as bash compares them: whichever
        # form git chooses (relative '.git' in a plain checkout, absolute in a
        # linked worktree) it uses the SAME form for both, so string equality
        # is the real test and normalizing the paths first would only invent
        # ways for the two to look equal when git says they are not.
        if ($gitDir.StdOut.TrimEnd("`n") -ne $commonDir.StdOut.TrimEnd("`n")) { return $false }
    }

    if (-not [System.IO.File]::Exists((Join-Path $nativeRoot 'AGENTS.md'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $nativeRoot 'bin') -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath $State) -PathType Container)) { return $false }
    return $true
}

Export-ModuleMember -Function @(
    'Test-FmRootIsSecondmateHome',
    'Test-FmPrimaryScopeMatch'
)
