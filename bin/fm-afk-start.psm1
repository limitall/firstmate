# fm-afk-start.psm1 - enter away mode and run the sub-supervisor: the FUNCTIONS
# half of a hybrid pair.
#
# Twin: bin/fm-afk-start.sh
#
# This is the COMMON daemon entry for every backend, and the only file that
# decides whether a NEW daemon may start. Its whole job is the singleton
# question: is a live daemon already holding state/.supervise-daemon.lock?
#
#   yes -> print "afk: daemon already running pid=<pid>" and exit 0. This is a
#          REFRESH, so the prior session's escalation artifacts are deliberately
#          NOT cleared - they belong to the session still running.
#   no  -> clear the previous away session's stale delivery artifacts, then
#          become the daemon.
#
# HOW this becomes a tracked background process differs by harness and is owned
# elsewhere: a harness with a native in-pane background tool (claude, grok) runs
# this directly, and one without (pi) runs it through bin/fm-afk-launch.ps1,
# which manufactures a non-visible terminal and passes the captain pane in as
# FM_SUPERVISOR_TARGET so injection targets the captain, not the daemon's own
# new pane.
#
# ---------------------------------------------------------------------------
# THE HYBRID SPLIT, and one divergence inside it
#
# bin/fm-afk-start.sh is a GENUINE dual-use hybrid: bin/fm-afk-launch.sh SOURCES
# it in production for the daemon-lock helpers and fm_afk_clear_stale_artifacts.
# So the twin is a PAIR (docs/powershell-port.md, "Exception - hybrids") and
# bin/fm-afk-launch.psm1 imports this module exactly where its bash twin sources
# the file.
#
# The divergence is `exec`. The bash main ends with
# `exec "$FM_AFK_DAEMON"` - the daemon REPLACES this process, keeping its pid,
# its terminal and its harness-tracked lifecycle. PowerShell has no exec, and
# spawning a child would break the two properties that matter: the pid the
# harness tracks would no longer be the daemon's, and a fire-and-forget child
# can be reaped when the tool call returns (the exact failure the "do not wrap
# this in nohup ... &" note in the bash header warns about). So the twin does the
# one thing that preserves both: it runs the daemon's main IN THIS PROCESS and
# returns its exit code. Same pid, same terminal, same lifecycle - and the
# daemon module is imported lazily, inside that branch, so a consumer that only
# wants the lock helpers never pays for it.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-afk-start.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on a nested import: the removal it performs first is GLOBAL and
# would strip fm-common from a caller that had already imported it.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1')

$script:FmOrdinal = [System.StringComparison]::Ordinal

<#
.SYNOPSIS
The resolved away-start context: ScriptRoot, Home, State, Lock.
.DESCRIPTION
The twin of the resolution block at the top of bin/fm-afk-start.sh. Resolved on
every call rather than once at import: bash resolves at source time, but every
production invocation is a fresh process, so per-call resolution is
observationally identical and is what lets one process serve many fixtures.
#>
function Get-FmAfkStartContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $context = Get-FmContext -ScriptRoot $PSScriptRoot
    return @{
        ScriptRoot = $context.ScriptRoot
        Root       = $context.Root
        Home       = $context.Home
        State      = $context.State
        Lock       = "$($context.State)/.supervise-daemon.lock"
    }
}

<#
.SYNOPSIS
The CLI usage text, one array element per line.
.DESCRIPTION
The bash twin renders this by re-reading its own comment block
(`sed -n '2,14p' | sed 's/^# \{0,1\}//'`), which has no honest PowerShell
equivalent - a .psm1 comment header is not the CLI's own source. The text is
therefore reproduced literally, and still names the .sh file, because CLI
surfaces stay identical during the transition (docs/powershell-port.md contract
4) and the differential harness compares this stdout directly.
#>
function Get-FmAfkStartUsage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'Enter away mode and run the sub-supervisor daemon in a harness-tracked'
        'foreground process when one is not already alive.'
        ''
        'Usage: fm-afk-start.sh'
        '  Sets state/.afk unless FM_AFK_STATE_PREPARED=1, checks'
        '  state/.supervise-daemon.lock, and:'
        '    - prints "afk: daemon already running pid=<pid>" then exits 0 when that'
        '      lock is held by a live daemon (a REFRESH: no stale-artifact clear);'
        '    - otherwise clears any prior away session''s stale escalation artifacts'
        '      (fm_afk_clear_stale_artifacts) for a direct, non-prepared start, then'
        '      execs bin/fm-supervise-daemon.sh in the foreground. A prepared start was'
        '      already cleared transactionally by bin/fm-afk-launch.sh.'
        # Line 14 of the bash twin is a bare `#`, which its sed range INCLUDES
        # and strips to an empty line. Dropping it here cost one trailing LF and
        # was invisible to the eye - the differential suite caught it as a
        # one-byte stdout mismatch, which is exactly the class of drift the
        # comment-block usage idiom invites.
        ''
    )
}

<#
.SYNOPSIS
Drop the previous away session's leftover escalation-delivery artifacts
(fm_afk_clear_stale_artifacts).
.DESCRIPTION
Called ONLY on a fresh entry, never on a refresh, so a running session's own
buffered escalations are preserved. These artifacts are session-scoped by
timing: a fresh entry owns a new supervision session and its daemon has produced
nothing yet, so anything present belongs to a PRIOR session.

This never drops a genuinely pending escalation. The delivery buffer is a
transient cache, and any condition still true - a crew still blocked, a check
still firing - is re-derived and re-escalated by the daemon's heartbeat
catch-all scan and the durable wake-queue replay.
#>
function Clear-FmAfkStaleArtifact {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f` list run at away-mode entry; a confirmation surface would diverge from the twin and could stall an unattended entry.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    $ok = $true
    foreach ($name in @('.subsuper-escalations', '.subsuper-escalations.since', '.subsuper-inject-wedged')) {
        $native = ConvertTo-FmNativePath -Path "$State/$name"
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            # `rm -f` reports a failure it could not perform; the caller treats
            # that as a failed clear and rolls back rather than proceeding.
            $ok = $false
        }
    }
    return $ok
}

<#
.SYNOPSIS
The owner directory a daemon lock names, or $null when it holds none
(daemon_lock_owner).
.DESCRIPTION
Both published lock representations are read, exactly as fm-wake-lib writes
them: a symlink to an owner directory, or the lock directory itself. A relative
symlink target is resolved against the lock's own directory, as readlink's
caller does.
#>
function Get-FmAfkDaemonLockOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$LockPath = '')

    if ([string]::IsNullOrEmpty($LockPath)) { $LockPath = (Get-FmAfkStartContext).Lock }
    $native = ConvertTo-FmNativePath -Path $LockPath
    if (Test-FmSymlink -Path $native) {
        $target = ''
        try {
            $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
            if ($null -ne $item.Target) { $target = [string]$item.Target }
        } catch {
            return $null
        }
        if ([string]::IsNullOrEmpty($target)) { return $null }
        if ($target.StartsWith('/', $script:FmOrdinal) -or ($target -match '^[A-Za-z]:[\\/]')) { return $target }
        return (Get-FmLockPathDir -Path $LockPath) + '/' + $target
    }
    if (-not [System.IO.Directory]::Exists($native)) { return $null }
    return $LockPath
}

<#
.SYNOPSIS
The pid recorded in the daemon lock, or '' (daemon_lock_pid).
#>
function Get-FmAfkDaemonLockPid {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$LockPath = '')

    $owner = Get-FmAfkDaemonLockOwner -LockPath $LockPath
    if ([string]::IsNullOrEmpty($owner)) { return '' }
    return (Get-FmFileText -Path "$owner/pid").TrimEnd("`n")
}

<#
.SYNOPSIS
True when <Pid> really is the daemon this lock belongs to (daemon_pid_matches).
.DESCRIPTION
The recorded pid-identity file is the PRIMARY evidence, because a pid alone can
be reused. Only when no identity was recorded does this fall back to matching
the daemon's script path inside the process argument vector - the pre-identity
compatibility path.
#>
function Test-FmAfkDaemonPidMatches {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Matches is a verb here, not a plural noun: the name reads as "test that the daemon pid matches", and it is the greppable twin of the bash daemon_pid_matches. Renaming to a singular noun would both misread and break the pairing this module''s function map documents.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProcessId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$OwnerDir = ''
    )

    $identity = (Get-FmFileText -Path "$OwnerDir/pid-identity").TrimEnd("`n")
    if (-not [string]::IsNullOrEmpty($identity)) {
        $current = Get-FmPidIdentity -ProcessId $ProcessId
        if ([string]::IsNullOrEmpty($current)) { return $false }
        return [string]::Equals($current, $identity, $script:FmOrdinal)
    }
    $command = ''
    try { $command = Get-FmProcCommandLine -ProcessId $ProcessId } catch { $command = '' }
    if ([string]::IsNullOrEmpty($command)) { return $false }
    if ($command.IndexOf('fm-supervise-daemon.sh', $script:FmOrdinal) -ge 0) { return $true }
    # The PowerShell daemon's argv names the .ps1 twin, and the bash arm cannot
    # see it. Both spellings are accepted here so a mixed tree never mistakes a
    # live daemon for a dead one - which is the only direction that would let a
    # SECOND daemon start.
    return ($command.IndexOf('fm-supervise-daemon.ps1', $script:FmOrdinal) -ge 0)
}

<#
.SYNOPSIS
True when the daemon lock is held by a live daemon
(daemon_lock_held_by_live_daemon).
.DESCRIPTION
The singleton predicate the whole away-mode lifecycle turns on. It answers true
only when a lock owner exists, its recorded pid is ALIVE, and that pid's
identity matches - so a stale lock, a reused pid and an unreadable owner all
answer false, and a false answer never starts a second daemon by itself: the
caller still reclaims the lock through the wake-lib protocol.
#>
function Test-FmAfkDaemonLockLive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$LockPath = '')

    if ([string]::IsNullOrEmpty($LockPath)) { $LockPath = (Get-FmAfkStartContext).Lock }
    $owner = Get-FmAfkDaemonLockOwner -LockPath $LockPath
    if ([string]::IsNullOrEmpty($owner)) { return $false }
    $daemonPid = (Get-FmFileText -Path "$owner/pid").TrimEnd("`n")
    if (-not (Test-FmPidAlive -ProcessId $daemonPid)) { return $false }
    return (Test-FmAfkDaemonPidMatches -ProcessId $daemonPid -OwnerDir $owner)
}

<#
.SYNOPSIS
The CLI body: enter away mode and become the daemon, returning an exit code.
.DESCRIPTION
Twin of fm_afk_start_main. Exit codes are the interface:

    0   the daemon is already running (a refresh), or usage was requested
    1   FM_AFK_STATE_PREPARED was set but the launcher-prepared state is missing
    2   invalid use
    *   otherwise: the daemon's own exit code, because this process BECOMES the
        daemon (see the exec divergence in the file header)
#>
function Invoke-FmAfkStartMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }
    $argv = @($Arguments)
    $command = if ($argv.Count -ge 1) { [string]$argv[0] } else { '' }
    if ($command -cin @('-h', '--help')) {
        foreach ($line in @(Get-FmAfkStartUsage)) { Write-FmOut -Text $line }
        return 0
    }
    if ($command -cne '') {
        Write-FmErr 'usage: fm-afk-start.sh'
        return 2
    }

    $context = Get-FmAfkStartContext
    $state = $context.State
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $state))

    $prepared = [string]::Equals((Get-FmEnv -Name 'FM_AFK_STATE_PREPARED' -Default '0'), '1', $script:FmOrdinal)
    if ($prepared) {
        # A prepared start trusts the launcher's transaction; if that state is
        # gone, something else cleared it and starting anyway would enter away
        # mode with no durable flag behind it.
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath -Path "$state/.afk"))) {
            Write-FmErr 'afk: launcher-prepared state is missing'
            return 1
        }
    } else {
        Set-FmFileText -Path "$state/.afk" -Text ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }

    $lockPid = Get-FmAfkDaemonLockPid -LockPath $context.Lock
    if (Test-FmAfkDaemonLockLive -LockPath $context.Lock) {
        Write-FmOut -Text "afk: daemon already running pid=$lockPid"
        return 0
    }

    # A live pid that is NOT this daemon means the lock is misattributed: drop it
    # through the wake-lib protocol (never by hand) so the claim below can win.
    if ((Test-FmPidAlive -ProcessId $lockPid) -and -not [string]::IsNullOrEmpty($lockPid)) {
        try { [void](Remove-FmLockPath -LockPath $context.Lock) } catch { $null = $_ }
    }

    if (-not $prepared) {
        [void](Clear-FmAfkStaleArtifact -State $state)
    }

    Write-FmOut -Text 'afk: starting supervise daemon in foreground; keep this command as a tracked background session'
    # The exec twin: BECOME the daemon in this process (file header). Imported
    # here, not at the top, so a consumer that only wants the lock helpers -
    # bin/fm-afk-launch.psm1, and every test - never loads the daemon.
    Import-Module (Join-Path $PSScriptRoot 'fm-supervise-daemon.psm1')
    return (Invoke-FmSuperviseDaemonMain)
}

Export-ModuleMember -Function @(
    'Get-FmAfkStartContext', 'Get-FmAfkStartUsage', 'Clear-FmAfkStaleArtifact',
    'Get-FmAfkDaemonLockOwner', 'Get-FmAfkDaemonLockPid',
    'Test-FmAfkDaemonPidMatches', 'Test-FmAfkDaemonLockLive',
    'Invoke-FmAfkStartMain'
)
