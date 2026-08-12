# fm-gate-refuse-lib.psm1 - refusal that keeps a no-mistakes GATE agent out of
# firstmate's fleet lifecycle, stopping rather than proceeding when either
# signal fires.
# Twin: bin/fm-gate-refuse-lib.sh
#
# The hazard (data/nm-gate-ambient-authority-containment-c3/report.md): a
# no-mistakes gate agent runs inside a firstmate checkout with a free shell, so
# it auto-loads firstmate's AGENTS.md, adopts the captain identity, and -
# seeing crew "in flight" - reaches for fm-spawn/fm-send/fm-teardown to
# "delegate" and "reconcile" the shared worktree. It has real capability
# because those entrypoints self-locate their home and never knew a gate
# context existed.
#
# no-mistakes owns the authority-removal half (it neutralizes the project
# instructions and stamps NO_MISTAKES_GATE into the gate agent's environment).
# THIS is the firstmate capability-removal half: an enforceable script refusal,
# not a prose rule the neutralized agent would never read. It is imported at
# the top of the fleet-lifecycle entrypoints and called before any fleet
# mutation, so a gate agent that still reaches for the fleet is stopped cold.
#
# Two independent signals, either of which refuses:
#
#   1. NO_MISTAKES_GATE set - the durable env marker no-mistakes stamps into
#      every gate agent. This is the primary signal and covers a relocated
#      NM_HOME.
#   2. The current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the UNSPOOFABLE backstop. It
#      derives from the checkout's real filesystem location, which the agent
#      cannot relocate without breaking the gate's own git operations, so it
#      still refuses even if the agent tampered NO_MISTAKES_GATE away. Its
#      limit: the literal-path match only fires for the default NM_HOME
#      (~/.no-mistakes); a relocated NM_HOME is covered by signal 1.
#
# A NORMAL firstmate session - a real primary checkout, a real treehouse/Orca
# crew worktree - has NEITHER signal and is COMPLETELY unaffected.
#
# TEST-HARNESS ESCAPE HATCH (FM_GATE_REFUSE_BYPASS=1): firstmate's own test
# suite must exercise the REAL fm-spawn/fm-send/fm-teardown, but the
# no-mistakes gate runs that suite FROM a gate worktree - the exact environment
# this guard refuses - so both signals would fire during firstmate's own
# validation. FM_GATE_REFUSE_BYPASS=1 makes the guard a no-op; the shared test
# helpers export it. This does NOT weaken the boundary against the real
# hazard: the threat is a CONFUSED-not-adversarial gate agent that runs the
# entrypoints directly after adopting firstmate's identity - it never sources
# firstmate's test helpers, so it never carries the bypass; and the adversarial
# case is covered by no-mistakes' neutral-execution-context and HEAD-continuity
# guard. tests/fm-gate-refuse.test.sh strips the bypass so it still verifies
# real refusal.
#
# No side effects on import. The refusal is a hard process exit, not a return,
# because there is no safe way to continue a fleet mutation from a gate
# context.
#
# bash -> PowerShell:
#   FM_GATE_REFUSE_EXIT       -> Get-FmGateRefuseExitCode
#   FM_GATE_REFUSE_REASON     -> Get-FmGateRefuseReason
#   FM_GATE_REFUSE_COMMON     -> Get-FmGateRefuseCommonDir
#   fm_is_gate_agent          -> Test-FmGateAgent
#   fm_refuse_if_gate_agent   -> Assert-FmNotGateAgent
#
# Three translation details that decide whether this still refuses:
#   - `${NO_MISTAKES_GATE+x}` is SET-even-if-empty, not `:-`. Get-FmEnv cannot
#     express that distinction (it collapses unset and empty), so the raw .NET
#     lookup is used and a $null result is the only "unset".
#   - The bash `case` glob is CASE-SENSITIVE; PowerShell's -like is not, so
#     -clike is what preserves the match. A case-insensitive match would refuse
#     inside a legitimate directory named .NO-MISTAKES.
#   - `pwd -P` yields POSIX form, so the resolved dir is converted to POSIX
#     before both the glob test and the operator-facing message - which keeps
#     the refusal text byte-identical to the bash twin's.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# Distinct enough to recognize in a caller or test as "the gate refusal fired"
# rather than an ordinary usage error.
$script:FmGateRefuseExit = 3
$script:FmGateRefuseReason = ''
$script:FmGateRefuseCommon = ''

<#
.SYNOPSIS
The exit code every gate refusal uses.
#>
function Get-FmGateRefuseExitCode {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:FmGateRefuseExit
}

<#
.SYNOPSIS
Which signal fired on the most recent Test-FmGateAgent: 'env', 'path', or ''.
#>
function Get-FmGateRefuseReason {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmGateRefuseReason
}

<#
.SYNOPSIS
The gate repo path that fired the unspoofable signal, or ''.
#>
function Get-FmGateRefuseCommonDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmGateRefuseCommon
}

<#
.SYNOPSIS
Resolve every symlink and junction in a directory path, the `pwd -P` twin.
.DESCRIPTION
Components are walked from the root and each accumulated prefix is resolved,
because `pwd -P` resolves EVERY component - and the signal this file tests for
is a MIDDLE component (.no-mistakes/repos/), so resolving only the leaf would
miss a gate repo reached through a linked parent.

Deliberately duplicated from bin/fm-secondmate-registry-lib.psm1 rather than
cross-imported: a fleet-lifecycle guard must not take a dependency on a
registry parser to answer whether it may run. The reporting note for this wave
asks for this helper to move into bin/fm-common.psm1, which is the real home
for it.

Returns $null for a path that does not exist or cannot be inspected, matching
`cd` failing.
#>
function Resolve-FmPhysicalDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $native = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($native)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { return $null }
        $current = $root
        foreach ($segment in ($full.Substring($root.Length) -split '[\\/]')) {
            if ($segment -eq '') { continue }
            $current = Join-Path $current $segment
            $target = [System.IO.Directory]::ResolveLinkTarget($current, $true)
            if ($null -ne $target) { $current = $target.FullName }
        }
        return [System.IO.Path]::GetFullPath($current)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
True when this process looks like a no-mistakes gate agent.
.DESCRIPTION
-Anchor anchors the git-common-dir check; callers that omit it retain the
historical current-directory behavior.

The bypass is checked FIRST, before either signal, so firstmate's own suite
never pays for a git call it will ignore.
#>
function Test-FmGateAgent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Anchor = '.')

    $script:FmGateRefuseReason = ''
    $script:FmGateRefuseCommon = ''

    if ((Get-FmEnv -Name 'FM_GATE_REFUSE_BYPASS') -eq '1') { return $false }

    # `${NO_MISTAKES_GATE+x}`: SET, even to the empty string, is the signal.
    if ($null -ne [Environment]::GetEnvironmentVariable('NO_MISTAKES_GATE')) {
        $script:FmGateRefuseReason = 'env'
        return $true
    }

    if ([string]::IsNullOrEmpty($Anchor)) { $Anchor = '.' }
    $anchorNative = ConvertTo-FmNativePath $Anchor
    # The whole bash chain is `cd ... && cd ... && pwd -P || true`, so every
    # failure - a missing anchor, no git, not a repo, a git-common-dir that no
    # longer exists - lands on an EMPTY common and answers "not a gate agent".
    if (-not (Test-Path -LiteralPath $anchorNative -PathType Container)) { return $false }
    if (-not (Test-FmCommand 'git')) { return $false }

    $result = Invoke-FmTool -FilePath 'git' -Arguments @('rev-parse', '--git-common-dir') -WorkingDirectory $anchorNative
    if (-not $result.Ok) { return $false }
    $gitCommon = $result.StdOut.TrimEnd("`n")
    if ($gitCommon -eq '') { return $false }

    # git may answer relatively ('.git'); the bash resolves it by cd'ing there
    # FROM the anchor, so a relative answer is joined to the anchor here.
    $candidate = if ([System.IO.Path]::IsPathRooted((ConvertTo-FmNativePath $gitCommon))) {
        ConvertTo-FmNativePath $gitCommon
    } else {
        Join-Path $anchorNative $gitCommon
    }

    $physical = Resolve-FmPhysicalDirectory -Directory $candidate
    if ($null -eq $physical) { return $false }
    $common = ConvertTo-FmPosixPath $physical

    # -clike, not -like: the bash `case` glob is case-sensitive, and a
    # case-insensitive match would refuse inside a directory merely named
    # .NO-MISTAKES.
    if ($common -clike '*/.no-mistakes/repos/*.git') {
        $script:FmGateRefuseReason = 'path'
        $script:FmGateRefuseCommon = $common
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Exit with the gate refusal code and a clear stderr message when this process
looks like a no-mistakes gate agent; otherwise return.
.DESCRIPTION
Call before any fleet mutation. A no-op for a normal firstmate session, or
when firstmate's own test harness sets FM_GATE_REFUSE_BYPASS=1.

The exit is a real process exit, not a thrown error: `exit` inside a module
function unwinds through the importing script and sets the process code
(verified), which is what makes this the same hard stop the bash `exit "$FM_
GATE_REFUSE_EXIT"` performs. Exit-FmScript is used so both console streams are
flushed first - a refusal message lost to an abrupt exit would leave the
operator with a bare exit code.
#>
function Assert-FmNotGateAgent {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Anchor = '.')

    if (-not (Test-FmGateAgent -Anchor $Anchor)) { return }

    if ($script:FmGateRefuseReason -eq 'env') {
        Write-FmErr 'error: no-mistakes gate agent must not drive the fleet (NO_MISTAKES_GATE set)'
    } else {
        Write-FmErr "error: refusing fleet lifecycle from inside a no-mistakes gate worktree ($script:FmGateRefuseCommon)"
    }
    Exit-FmScript $script:FmGateRefuseExit
}

Export-ModuleMember -Function @(
    'Get-FmGateRefuseExitCode',
    'Get-FmGateRefuseReason',
    'Get-FmGateRefuseCommonDir',
    'Resolve-FmPhysicalDirectory',
    'Test-FmGateAgent',
    'Assert-FmNotGateAgent'
)
