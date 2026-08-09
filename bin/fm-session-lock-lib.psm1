# fm-session-lock-lib.psm1 - shared session-lock harness identity.
#
# Twin: bin/fm-session-lock-lib.sh
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake. No side effects on
# import.
#
# THE STAKES, STATED FIRST BECAUSE THEY SHAPE EVERY DECISION BELOW.
# state/.lock holds the harness pid. If identity resolution fails, firstmate
# does not merely lose a feature - it runs PERMANENTLY READ-ONLY: no spawn, no
# steer, no merge, no wake drain, no supervision repair (AGENTS.md section 3).
# And if the two language trees resolve DIFFERENT pids for one session, a lock
# written by bash is unrecognizable to PowerShell and vice versa, which is the
# same outcome arriving silently. So nothing here is simplified, and the one
# question that mattered was settled by measurement rather than by reading.
#
# bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-session-lock-lib.sh              this file
#   -------------------------------------   ---------------------------------
#   FM_HARNESS_RE                           Get-FmHarnessRegex
#   fm_harness_ancestry_pid                 Get-FmHarnessAncestryPid
#   fm_harness_native_image_matches         Test-FmHarnessNativeImage
#   fm_harness_native_image_is_interpreter  Test-FmHarnessNativeInterpreter
#   fm_harness_native_session_pid           Get-FmHarnessNativeSessionPid
#   fm_harness_pid_alive                    Test-FmHarnessPidAlive
#   fm_session_lock_owned_by_self           Test-FmSessionLockOwnedBySelf
#
# ============================================================================
# 1. WHY CLAUDE_PID IS THE AUTHORITY ON WINDOWS - MEASURED, NOT ASSUMED
# ============================================================================
# The bash twin's comment explains that on Git Bash/MSYS the harness is a NATIVE
# Windows process and a bash whose parent is native reports PPID=1, so the
# ancestry walk stops at its first hop having found nothing and
# fm_harness_native_session_pid gets the last word via CLAUDE_PID.
#
# The obvious "Windows-native win" would be to walk the REAL Win32 parent chain
# here, since PowerShell can see native processes that MSYS cannot. That is
# wrong, and it is wrong in the direction that bricks the fleet. Measured on
# this host, in a live session, walking parents from pwsh with
# bin/fm-psproc-lib.psm1's primitives:
#
#     hop0  pid=1136  image=pwsh.exe     ppid=9288
#     hop1  pid=9288  image=timeout.exe  ppid=1200
#     hop2  pid=1200  image=timeout.exe  ppid=<empty>   -> chain ends
#
# The Win32 parent chain TERMINATES before reaching the harness, because
# Windows keeps no durable ancestry: a parent that exited leaves its child with
# a dangling ParentProcessId. So PowerShell cannot reach the harness either, for
# a different reason than bash, and a twin that trusted the walk would resolve
# nothing and fail closed.
#
# In the same session, both twins agree through the fallback:
#
#     bash  fm_harness_ancestry_pid       -> 44140
#     bash  fm_harness_native_session_pid -> 44140
#           CLAUDE_PID                    =  44140   (claude.exe)
#
# The walk is therefore ported FAITHFULLY - same 16 hops, same claude-extending
# rule, same bare-interpreter rule - because it is the path that works off
# Windows, and CLAUDE_PID remains the last word exactly as in bash. The
# differential suite asserts the two worlds return the SAME pid, which is the
# property that keeps one home's lock readable from both trees.
#
# TWO PID SPACES, ONE ANSWER. bash starts its walk at $$ (an MSYS pid: 1417798
# in the measurement above) and this module starts at $PID (a Windows pid:
# 1136). They are different numbers in different number spaces and they still
# produce the same result, because on this platform both walks find nothing and
# both fall through to the same published CLAUDE_PID. That coincidence is
# load-bearing and is asserted, not assumed.
#
# THE SAFETY PROPERTY IS PRESERVED. Resolving to CLAUDE_PID keeps
# Test-FmSessionLockOwnedBySelf a real identity test rather than a tautology: a
# CONCURRENT session in the same home carries a DIFFERENT CLAUDE_PID and
# correctly FAILS the match, and a session that has exited leaves a pid that
# Get-FmNativeProcessInfo reports dead. The suite asserts the mismatch case
# directly, because an ownership test that always says yes is worse than none.
#
# ============================================================================
# 2. THE TWO IMAGE RULES ARE DIFFERENT ON PURPOSE
# ============================================================================
# Both call sites ask "does this native image look like a verified harness?",
# and they trust the answer differently:
#
#   Get-FmHarnessNativeSessionPid  the pid came from CLAUDE_PID, which the
#                                  harness itself published into this
#                                  environment, so a bare `node` is accepted
#                                  WITHOUT a harness-shaped path - the only way
#                                  a node-launched Claude install resolves at
#                                  all. The image check that remains is a
#                                  pid-reuse guard.
#   Test-FmHarnessPidAlive         the pid came from the lock FILE and may
#                                  belong to another session, so a bare
#                                  interpreter must ALSO carry a harness-shaped
#                                  path, or a recycled pid running some
#                                  unrelated node.exe would keep a dead
#                                  session's lock alive forever.
#
# ============================================================================
# 3. WHAT `kill -0` BECOMES
# ============================================================================
# Test-FmHarnessPidAlive's bash twin tries `kill -0` first and treats FAILURE as
# "this is a native pid MSYS cannot see", falling through to the native process
# table. There is only ONE pid space here, so that two-branch shape collapses:
# every pid this module sees is a Windows pid, and the native table is the right
# observer for all of them. The collapsed branch is the one that actually runs
# on Windows in bash too, so the observable verdict is unchanged; off Windows
# Get-FmNativeProcessInfo declines and the command/args rule answers, matching
# the bash twin's other branch.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-session-lock-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on these nested imports (docs/powershell-port.md, "Never -Force a
# NESTED module import").
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1')

$script:FmLockOrdinal = [System.StringComparison]::Ordinal

# Known harness command names; extend when a new adapter is verified. Kept as
# the bash twin's ERE verbatim, including the anchored `^pi$`/`^pi-signed$`
# alternatives, because those anchors are what stop "pip" or "pilot" from
# reading as the Pi harness. .NET and POSIX ERE agree on every construct used.
$script:FmHarnessRegex = 'claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

<#
.SYNOPSIS
The verified-harness command-name pattern (FM_HARNESS_RE).
#>
function Get-FmHarnessRegex {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmHarnessRegex
}

# grep -qE with the harness pattern. Case-SENSITIVE, because grep -E is and
# PowerShell's -match is not: a case-insensitive test would let "CLAUDE.EXE" or
# an unrelated "Kimi" string match where bash refuses.
function Test-FmHarnessMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [regex]::IsMatch($Text, $script:FmHarnessRegex)
}

<#
.SYNOPSIS
True when a native image is a bare interpreter a harness may run under.
.DESCRIPTION
Twin of fm_harness_native_image_is_interpreter - an exact-name allow list, not a
pattern, so "nodemon" or "python-config" cannot pass as an interpreter.
#>
function Test-FmHarnessNativeInterpreter {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Image)

    if ([string]::IsNullOrEmpty($Image)) { return $false }
    $known = @('node', 'node.exe', 'python', 'python.exe', 'python3', 'python3.exe', 'py', 'py.exe')
    foreach ($k in $known) {
        if ([string]::Equals($Image, $k, $script:FmLockOrdinal)) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
True when a NATIVE Windows process image looks like a verified harness.
.DESCRIPTION
Twin of fm_harness_native_image_matches: the same two-layer rule the ancestry
walk applies to comm/args - the image name itself, or a bare interpreter
carrying the harness name in its PATH - except that the native process table
exposes only the executable path, never the arguments. A harness launched as
`node <somewhere>/claude/cli.js` is therefore recognizable only when the harness
name is in the interpreter's own path; that gap is why the two callers decide
how much to trust a bare interpreter (see note 2 in the header).
#>
function Test-FmHarnessNativeImage {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Image,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Path
    )

    if (Test-FmHarnessMatch $Image) { return $true }
    if (-not (Test-FmHarnessNativeInterpreter $Image)) { return $false }
    return (Test-FmHarnessMatch $Path)
}

<#
.SYNOPSIS
The harness pid published into this environment, or $null.
.DESCRIPTION
Twin of fm_harness_native_session_pid: the post-walk fallback for an ancestry
chain that is SEVERED rather than merely unmatched. See note 1 in the header for
the measurement that makes this the authoritative path on Windows.

Claude Code exports CLAUDE_PID (its own Windows pid) into every process it
launches, hooks included, so the SAME value is visible to the bin/fm-lock.sh
writer and to every later checker in that session. The value is trusted because
the harness itself published it, so a bare `node` image is accepted here without
a harness-shaped path; the image check that remains is a pid-reuse guard.

Everywhere else this is a no-op: CLAUDE_PID is unset and the function declines
before touching the process table.
#>
function Get-FmHarnessNativeSessionPid {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # `case "${CLAUDE_PID:-}" in ''|*[!0-9]*) return 1` - empty or non-numeric
    # declines, and an all-digit value proceeds.
    $claudePid = Get-FmEnv -Name 'CLAUDE_PID'
    if ([string]::IsNullOrEmpty($claudePid)) { return $null }
    if ($claudePid -notmatch '^[0-9]+$') { return $null }

    $info = Get-FmNativeProcessInfo -ProcessId $claudePid
    if (-not $info) { return $null }

    if (-not ((Test-FmHarnessNativeImage $info.Image $info.Path) -or
              (Test-FmHarnessNativeInterpreter $info.Image))) {
        return $null
    }
    return $claudePid
}

<#
.SYNOPSIS
Walk the current process ancestry (up to 16 hops) and return a harness pid.
.DESCRIPTION
Twin of fm_harness_ancestry_pid, including the asymmetry that makes it correct
for two differently shaped harness process trees:

  * For every harness EXCEPT Claude the FIRST match wins (the innermost pid),
    which is where Pi's shared signed-wrapper ancestry actually holds the
    session: a "pi-signed" launcher can be the direct parent of the inner "pi"
    engine pid that owns the lock, and the wrapper above it is not that owner.
  * Claude Code's bg-spare hook worker chain is the OPPOSITE shape - several
    claude-named processes nested directly parent-child with no non-harness
    process between them - and the lock is held by the OUTERMOST pid of that
    run. So once a claude-named match is found the walk keeps going, looking for
    a still-more-ancestral claude-named match, and stops the instant a
    non-match follows. It never walks PAST that gap to an unrelated
    claude-named process further up the real tree (for example the live session
    that launched a test as its own subprocess).

The harness pid lives as long as the session, unlike the transient pid of any
one tool call.

When the walk finds nothing at all, Get-FmHarnessNativeSessionPid gets the last
word - on Windows that is the path that always runs (header note 1).

Starts at $PID, the Windows pid of this process, where the bash twin starts at
$$, its MSYS pid. Different number spaces, same answer on this platform,
because both walks come up empty and both fall through to CLAUDE_PID.
#>
function Get-FmHarnessAncestryPid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$StartPid)

    $current = if ([string]::IsNullOrEmpty($StartPid)) { [string]$PID } else { $StartPid }
    $best = ''
    $extending = $false

    for ($hop = 0; $hop -lt 16; $hop++) {
        $comm = Get-FmProcCommand -ProcessId $current
        # `comm=$(fm_proc_comm "$pid") || break` - a pid the process table
        # cannot name ends the walk.
        if ([string]::IsNullOrEmpty($comm)) { break }
        $procArgs = Get-FmProcCommandLine -ProcessId $current
        if ($null -eq $procArgs) { $procArgs = '' }

        # `basename -- "$comm"`, for either separator: a Windows image path
        # carries backslashes and MSYS reports forward ones.
        $leaf = $comm
        $cut = [Math]::Max($leaf.LastIndexOf('/'), $leaf.LastIndexOf('\'))
        if ($cut -ge 0) { $leaf = $leaf.Substring($cut + 1) }

        $hit = $false
        $isClaude = $false
        if (Test-FmHarnessMatch $leaf) {
            $hit = $true
            if ($leaf -clike '*claude*') { $isClaude = $true }
        } elseif (($comm -clike '*node*') -or ($comm -clike '*python*')) {
            # A bare interpreter: match the harness name in its script path.
            if (Test-FmHarnessMatch $procArgs) {
                $hit = $true
                if ($procArgs -clike '*claude*') { $isClaude = $true }
            }
        }

        if ($hit) {
            $best = $current
            if ($isClaude) { $extending = $true } else { break }
        } elseif ($extending) {
            break
        }

        $parent = Get-FmProcParentId -ProcessId $current
        if ($null -ne $parent) { $parent = ([string]$parent).Trim() }
        # `[ -n "$pid" ] && [ "$pid" -gt 1 ] || break`
        if ([string]::IsNullOrEmpty($parent)) { break }
        if ($parent -notmatch '^[0-9]+$') { break }
        if ([long]$parent -le 1) { break }
        $current = $parent
    }

    if (-not [string]::IsNullOrEmpty($best)) { return $best }
    return (Get-FmHarnessNativeSessionPid)
}

<#
.SYNOPSIS
True when <ProcessId> is a live process that looks like a verified harness.
.DESCRIPTION
Twin of fm_harness_pid_alive, with the `kill -0` two-branch shape collapsed as
header note 3 explains. The pid comes from the lock FILE and may belong to
another session, so a bare interpreter must ALSO carry a harness-shaped path:
a recycled pid running an unrelated node.exe must not keep a dead session's lock
alive forever.
#>
function Test-FmHarnessPidAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProcessId)

    if ([string]::IsNullOrEmpty($ProcessId)) { return $false }
    if ($ProcessId -notmatch '^[0-9]+$') { return $false }

    # The native table is the only observer that can tell "still running" from
    # "gone" for a native harness pid - what Get-FmHarnessNativeSessionPid
    # records in the lock.
    $info = Get-FmNativeProcessInfo -ProcessId $ProcessId
    if ($info) { return (Test-FmHarnessNativeImage $info.Image $info.Path) }

    # Off Windows, or for a pid the native table cannot describe: the bash
    # twin's other branch - the process must be alive, and its command name or
    # (for a bare interpreter) its arguments must name a harness.
    if (-not (Test-FmProcAlive -ProcessId $ProcessId)) { return $false }
    $comm = Get-FmProcCommand -ProcessId $ProcessId
    if ([string]::IsNullOrEmpty($comm)) { return $false }
    $leaf = $comm
    $cut = [Math]::Max($leaf.LastIndexOf('/'), $leaf.LastIndexOf('\'))
    if ($cut -ge 0) { $leaf = $leaf.Substring($cut + 1) }
    if (Test-FmHarnessMatch $leaf) { return $true }
    if (($comm -clike '*node*') -or ($comm -clike '*python*')) {
        $procArgs = Get-FmProcCommandLine -ProcessId $ProcessId
        if ($null -eq $procArgs) { $procArgs = '' }
        return (Test-FmHarnessMatch $procArgs)
    }
    return $false
}

<#
.SYNOPSIS
True when <State> holds a session lock owned by THIS session's harness.
.DESCRIPTION
Twin of fm_session_lock_owned_by_self. A missing lock, a lock whose contents are
not a bare pid, a lock held by another live harness, or an ancestry that cannot
be resolved ALL FAIL CLOSED - the caller then stays read-only, which is the safe
direction (AGENTS.md section 3).

The comparison is a string equality on two all-digit values, exactly as the bash
twin's `[ "$my_pid" = "$lock_pid" ]` is, so a lock written "0044140" would not
match 44140 in either world.
#>
function Test-FmSessionLockOwnedBySelf {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { return $false }
    # `cat "$state/.lock" 2>/dev/null || true` - a missing lock is empty, not
    # an error. Command substitution strips trailing newlines, so the pid is
    # compared without the terminator the writer appended.
    $lockPid = (Get-FmFileText "$State/.lock").TrimEnd("`r", "`n")
    if ([string]::IsNullOrEmpty($lockPid)) { return $false }
    if ($lockPid -notmatch '^[0-9]+$') { return $false }

    $myPid = Get-FmHarnessAncestryPid
    if ([string]::IsNullOrEmpty($myPid)) { return $false }
    return [string]::Equals($myPid, $lockPid, $script:FmLockOrdinal)
}

Export-ModuleMember -Function @(
    'Get-FmHarnessRegex', 'Test-FmHarnessMatch',
    'Test-FmHarnessNativeInterpreter', 'Test-FmHarnessNativeImage',
    'Get-FmHarnessNativeSessionPid', 'Get-FmHarnessAncestryPid',
    'Test-FmHarnessPidAlive', 'Test-FmSessionLockOwnedBySelf'
)
