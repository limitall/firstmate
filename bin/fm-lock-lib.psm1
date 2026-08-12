# fm-lock-lib.psm1 - the "is this git lock file provably abandoned?" decision.
# Twin: bin/fm-lock-lib.sh
#
# ONE owner for the staleness proof that fm-teardown (a worktree index.lock)
# and fm-fleet-sync (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and none holds a companion
#      directory (the worktree, or the repo's .git dir) open as cwd or an fd -
#      a live git process keeps its own lock open for the whole operation, so
#      an empty lsof result means the file was abandoned, not that no one held
#      it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly
#      created lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - answers
# NOT STALE: fail safe, never remove a lock that cannot be proven dead.
#
# bash -> PowerShell:
#   fm_lock_log               -> Write-FmLockLog
#   fm_lock_path_mtime        -> Get-FmLockPathMtime
#   fm_lock_lsof_holder       -> Get-FmLockHolderVerdict
#   fm_lock_has_live_holder   -> Test-FmLockHasLiveHolder
#   fm_lock_age               -> Get-FmLockAge
#   fm_lock_is_provably_stale -> Test-FmLockProvablyStale
#
# ============================================================================
# THE HOLDER CHECK: what this twin deliberately does NOT do
# ============================================================================
# PowerShell can answer "does a live process hold this file open" natively -
# through a handle enumeration, or by attempting an exclusive open. This twin
# does NOT use that capability, and the reason is worth the paragraph.
#
# The bash twin's authority for "no one holds this" is lsof. lsof DOES NOT
# EXIST on Git Bash, so on this platform `command -v lsof` fails, the bash
# answers "cannot prove no holder", and the proof therefore NEVER concludes
# stale here - it leaves every git lock in place. That is the behavior the
# captain's tree has today.
#
# A native holder probe could only move a case from "uncertain" to "provably
# held". It cannot move one to "provably free": failing to open a file
# exclusively proves a holder exists, but SUCCEEDING proves only that no one
# held it during that instant, which is not the same claim and is exactly the
# race the mtime threshold in step 3 exists to cover. And "uncertain" already
# behaves as "held" - so a native probe cannot change a single verdict this
# module produces. Adding one would be inert code that LOOKS authoritative,
# and the next author to touch this file would reasonably wire it into the
# free direction, turning a fail-safe guard into a lock remover.
#
# So: lsof is consulted exactly as the bash consults it, with the identical
# three-way verdict, which makes the two worlds agree on EVERY host - on Linux
# and macOS, where lsof exists, both use it and reach the same conclusion; on
# Windows, where it does not, both refuse to conclude. Hardening this into a
# real Windows holder check is a deliberate behavior change and belongs in its
# own authorized work, not inside a conversion.
#
# One other divergence, stated rather than hidden: the bash reads mtime by
# shelling out to stat(1) (`stat -f %m` on Darwin, `stat -c %Y` elsewhere).
# Here that is an in-process filesystem read, so the uname branch disappears
# and no child process is spawned. Both produce whole epoch seconds by
# truncation, so the ages agree.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

<#
.SYNOPSIS
Write one lock diagnostic to stderr, prefixed so each caller stays recognizable.
.DESCRIPTION
The bash twin reads ${FM_LOCK_LOG_PREFIX:-fm-lock}, a plain SHELL variable its
callers set before sourcing (fm-teardown sets 'teardown', fm-fleet-sync sets
'fleet-sync'). A PowerShell module cannot see its caller's variables, so the
prefix is a real parameter here, defaulting to the environment variable of the
same name so a caller that exports it still works and the two worlds can be
driven identically from a test.
#>
function Write-FmLockLog {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [string]$LogPrefix
    )
    if (-not $PSBoundParameters.ContainsKey('LogPrefix') -or [string]::IsNullOrEmpty($LogPrefix)) {
        $LogPrefix = Get-FmEnv -Name 'FM_LOCK_LOG_PREFIX' -Default 'fm-lock'
    }
    Write-FmErr "${LogPrefix}: $Message"
}

<#
.SYNOPSIS
A path's mtime in whole epoch seconds, or $null when it cannot be read.
.DESCRIPTION
Get-Item rather than [System.IO.File]::GetLastWriteTimeUtc because the lock
argument may legitimately be a directory (a lock dir), and the File overload
returns a 1601 sentinel for one instead of failing. -Force so a hidden lock
file is still visible.
#>
function Get-FmLockPathMtime {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        return ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
lsof's verdict for one target: 0 held, 1 provably none, 2 cannot tell.
.DESCRIPTION
The integer codes are the bash function's exit statuses, kept as-is because
the caller branches on all three and collapsing them to a boolean would erase
the distinction between "provably free" and "could not find out" - the whole
point of the proof.

lsof's contract, relied on here: exit 1 with NO output means "no process holds
this". Exit 1 WITH output, or any other non-zero exit, is an error, and the
error text is logged line by line so an operator sees the real reason rather
than a bare "not stale".
#>
function Get-FmLockHolderVerdict {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Target,
        [string]$LogPrefix
    )

    $logArgs = @{}
    if ($PSBoundParameters.ContainsKey('LogPrefix')) { $logArgs['LogPrefix'] = $LogPrefix }

    # lsof takes a filesystem path; on a host that has lsof at all, that host's
    # own path convention is what it expects, so the value is passed through
    # unconverted exactly as bash passes it.
    $result = Invoke-FmTool -FilePath 'lsof' -Arguments @('--', $Target)
    # The bash merges 2>&1 into one capture and tests THAT for emptiness, so
    # the two streams are joined here before the emptiness test rather than
    # after - a warning on stderr with an empty stdout is an ERROR case, not a
    # "provably none" case.
    $output = $result.StdOut + $result.StdErr
    if ($result.Ok) { return 0 }

    if ($result.ExitCode -eq 1 -and $output -eq '') { return 1 }

    if ($output -ne '') {
        foreach ($line in ($output.TrimEnd("`n") -split "`n")) {
            Write-FmLockLog -Message "lsof check failed: $line" @logArgs
        }
    } else {
        Write-FmLockLog -Message "lsof check failed for $Target with exit $($result.ExitCode)" @logArgs
    }
    return 2
}

<#
.SYNOPSIS
True when a live process holds the lock or its companion directory - OR when
the answer is uncertain.
.DESCRIPTION
"Uncertain" and "held" deliberately share one return value, because every
caller uses this to decide whether it may DELETE something. A missing lsof or
an lsof error is treated as "cannot prove no holder", i.e. assume live. Only a
provably-empty lsof result on BOTH targets returns $false.

On Windows there is no lsof, so this returns $true unconditionally - see the
header for why that is preserved rather than replaced with a native probe.
#>
function Test-FmLockHasLiveHolder {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Lock = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Directory = '',
        [string]$LogPrefix
    )

    if (-not (Test-FmCommand 'lsof')) { return $true }

    $verdictArgs = @{}
    if ($PSBoundParameters.ContainsKey('LogPrefix')) { $verdictArgs['LogPrefix'] = $LogPrefix }

    foreach ($target in @($Lock, $Directory)) {
        if ([string]::IsNullOrEmpty($target)) { continue }
        $verdict = Get-FmLockHolderVerdict -Target $target @verdictArgs
        # 0 = a holder exists; 2 = lsof could not tell. Both mean "do not
        # touch it". Only 1 - provably nobody - lets the loop continue.
        if ($verdict -ne 1) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
The lock's mtime age in whole seconds, or $null when it cannot be determined.
#>
function Get-FmLockAge {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory, Position = 0)][string]$Lock)

    $mtime = Get-FmLockPathMtime -Path $Lock
    if ($null -eq $mtime) { return $null }
    return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime)
}

<#
.SYNOPSIS
THE proof: true only when the lock exists, has no live holder, and is at least
MinimumAgeSeconds old.
.DESCRIPTION
Never remove a lock this returns $false for. Every uncertainty answers $false:
a lock that does not exist, an unprovable holder, an unreadable mtime, or a
threshold that is not a non-negative integer.

That last case is the twin of a bash quirk worth naming: `[ "$age" -ge "abc" ]`
prints an arithmetic error and exits 2, which the caller reads as "not stale".
Refusing on a malformed threshold is therefore the faithful answer, not added
strictness.
#>
function Test-FmLockProvablyStale {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Lock,
        [Parameter(Position = 1)][AllowEmptyString()][string]$Directory = '',
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$MinimumAgeSeconds,
        [string]$LogPrefix
    )

    $logArgs = @{}
    if ($PSBoundParameters.ContainsKey('LogPrefix')) { $logArgs['LogPrefix'] = $LogPrefix }

    if ([string]::IsNullOrEmpty($Lock)) { return $false }
    # `[ -e ]` is true for a directory too, so Test-Path with no -PathType.
    if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath $Lock))) { return $false }

    if (Test-FmLockHasLiveHolder -Lock $Lock -Directory $Directory @logArgs) { return $false }

    $age = Get-FmLockAge -Lock $Lock
    if ($null -eq $age) {
        Write-FmLockLog -Message "cannot read mtime for git lock $Lock; leaving it in place" @logArgs
        return $false
    }

    [long]$threshold = 0
    if (-not [long]::TryParse($MinimumAgeSeconds, [ref]$threshold)) { return $false }
    return ($age -ge $threshold)
}

Export-ModuleMember -Function @(
    'Write-FmLockLog',
    'Get-FmLockPathMtime',
    'Get-FmLockHolderVerdict',
    'Test-FmLockHasLiveHolder',
    'Get-FmLockAge',
    'Test-FmLockProvablyStale'
)
