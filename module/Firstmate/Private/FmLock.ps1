<#
    FmLock - the per-home mutexes and the session lock.

    Ported from bin/fm-wake-lib.sh (fm_lock_try_acquire / _acquire_wait /
    _release and their owner-directory machinery) and bin/fm-lock.sh
    (the session lock).

    SEMANTICS PRESERVED
      1. One holder. Two processes racing for the same lock: exactly one wins.
      2. Stale-holder detection. A lock whose holder is gone is recoverable, and
         recovery is itself serialized so two recoverers cannot both "win".
      3. A crash never deadlocks. There is no cleanup handler to miss: a lock is
         held only while its recorded process is alive, so a killed holder's lock
         becomes recoverable by the next caller with no operator action.
      4. Recovery is fail-safe. Every uncertainty - unreadable pid, unreadable
         identity, a claim that might be in flight - reads as HELD. A wrong
         "held" costs a wait; a wrong "stale" steals a live session's lock.

    MECHANISM, AND HOW IT DIFFERS FROM BASH
      The bash version publishes a lock as a SYMLINK to an owner directory,
      because that is the atomic "create and name my ownership in one step"
      primitive on Unix. Windows symlinks need a privilege ordinary sessions do
      not have, so this port uses the primitive Windows does give for free:
      exclusive file creation. The lock is a directory whose 'pid' file is
      created with FileMode.CreateNew, which is atomic on both platforms - the
      OS lets exactly one creator win and raises IOException for everyone else.
      The layout otherwise matches bash (pid, pid-identity, fm-home, role,
      watcher-path children), so a Linux firstmate inspecting the home still
      recognizes what it sees.

      Breaking a stale lock is likewise atomic without a separate steal lock:
      the breaker RENAMES the dead holder's pid file to a name unique to itself.
      Rename of a given source succeeds for exactly one caller, so it decides the
      single breaker; the losers simply re-read and find the lock free or newly
      taken. That replaces bash's recursive <lock>.steal dance with one
      indivisible step - which matters here, because a recursive steal-of-a-steal
      is exactly the sort of thing that has no terminating case on a platform
      where any of those files might briefly refuse to open.

      Named mutexes were the other option the port could have taken. They are
      rejected on purpose: a named mutex is invisible to every other tool, cannot
      say WHICH process holds it, and cannot be inspected after a crash - and
      "who holds this home's lock, and is that process still alive" is a question
      firstmate's operators and its own diagnostics ask constantly.

    Locks are process-scoped, not thread-scoped: they are held by a process id
    and released by that process. A single PowerShell process must therefore not
    take the same lock twice - it would wait for itself forever - so an attempt
    to do that throws immediately with a clear message instead of hanging.
#>

Set-StrictMode -Version Latest

# Grace for a claim that may be in flight. FM_LOCK_STALE_AFTER, default 2s,
# floored at 2s exactly as fm_lock_mid_acquire_is_fresh does: a lock whose pid
# file exists but is not yet readable is treated as held while it is this young,
# because a claimer creates the file and writes it as two steps.
function Get-FmLockStaleAfterSeconds {
    [OutputType([int])]
    param()
    $raw = [System.Environment]::GetEnvironmentVariable('FM_LOCK_STALE_AFTER')
    $value = 2
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed)) { $value = $parsed }
    }
    if ($value -lt 2) { $value = 2 }
    return $value
}

# Locks this process currently holds, keyed by resolved lock path. Purely a
# self-deadlock guard and a diagnostic; the filesystem remains the authority.
$script:FmHeldLocks = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Set by Request-FmLock when it fails, so a caller can report WHO holds the lock
# without racing to re-read it (bash's FM_LOCK_HELD_PID).
$script:FmLastLockHolder = $null

$script:FmLockChildNames = @('pid', 'pid-identity', 'fm-home', 'role', 'watcher-path')

function Get-FmLockKey {
    param([Parameter(Mandatory)][string]$Path)
    # Windows paths are case-insensitive: state\.watch.lock and state\.WATCH.LOCK
    # are one lock and must share one table entry.
    if ($IsWindows) { return $Path.ToLowerInvariant() }
    return $Path
}

function Get-FmLockInfo {
    <#
        .SYNOPSIS
        Who holds a lock, and is it free, held, being claimed, or stale?

        .DESCRIPTION
        States:
          free     - no lock directory, or no pid file in it
          held     - the recorded process is alive and still the same process
          claiming - a pid file exists but is not readable yet and is younger
                     than the stale grace: someone is mid-claim, treat as held
          stale    - the recorded process is gone, or the id was recycled by a
                     different process, or an unreadable claim outlived the grace
          invalid  - something that is not a lock directory sits at the path

        Never mutates anything. Recovery decisions are made only by Request-FmLock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FmFullPath -Path $Path
    $pidFile = Join-Path $full 'pid'
    $info = [pscustomobject]@{
        PSTypeName  = 'Firstmate.LockInfo'
        Path        = $full
        State       = 'free'
        ProcessId   = $null
        Identity    = $null
        Home        = $null
        Role        = $null
        WatcherPath = $null
        AgeSeconds  = $null
        IsHeld      = $false
    }

    if ([System.IO.File]::Exists($full)) {
        $info.State = 'invalid'
        return $info
    }
    if (-not [System.IO.Directory]::Exists($full)) { return $info }
    if (-not [System.IO.File]::Exists($pidFile)) { return $info }

    $info.AgeSeconds = Get-FmPathAge -Path $pidFile
    $raw = $null
    try { $raw = Read-FmStateFile -Path $pidFile } catch { $raw = $null }
    $trimmed = if ($null -eq $raw) { '' } else { $raw.Trim() }

    if (-not (Test-FmProcessId -Id $trimmed)) {
        # Unreadable or half-written claim. Fresh means someone is mid-claim.
        if ($info.AgeSeconds -lt (Get-FmLockStaleAfterSeconds)) {
            $info.State = 'claiming'
            $info.IsHeld = $true
        } else {
            $info.State = 'stale'
        }
        return $info
    }

    $info.ProcessId = [int]$trimmed
    $info.Identity = (Read-FmStateFile -Path (Join-Path $full 'pid-identity'))
    if ($info.Identity) { $info.Identity = $info.Identity.Trim() }
    # Not $home: PowerShell's $HOME is read-only and assigning to it fails.
    $recordedHome = Read-FmStateFile -Path (Join-Path $full 'fm-home')
    if ($recordedHome) { $info.Home = $recordedHome.Trim() }
    $role = Read-FmStateFile -Path (Join-Path $full 'role')
    if ($role) { $info.Role = $role.Trim() }
    $watcher = Read-FmStateFile -Path (Join-Path $full 'watcher-path')
    if ($watcher) { $info.WatcherPath = $watcher.Trim() }

    $aliveArgs = @{ Id = $info.ProcessId }
    # No recorded identity (a mid-claim, or a lock written by the bash side)
    # falls back to plain liveness rather than declaring a mismatch.
    if ($info.Identity) { $aliveArgs['Identity'] = $info.Identity }
    if (Test-FmProcessAlive @aliveArgs) {
        $info.State = 'held'
        $info.IsHeld = $true
    } else {
        $info.State = 'stale'
    }
    return $info
}

function Remove-FmLockChildFile {
    # Internal helper called only by functions that have already established
    # ownership; ShouldProcess belongs on those, not on every private step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][string]$LockPath, [string[]]$Name = $script:FmLockChildNames)
    foreach ($child in $Name) {
        $path = Join-Path $LockPath $child
        # Best effort: a sidecar that will not delete is not worth failing a
        # release over, and the pid file alone decides ownership.
        try { [System.IO.File]::Delete($path) } catch { Write-Verbose "firstmate: could not remove $path" }
    }
}

function Clear-FmLockBreakResidue {
    <#
        .SYNOPSIS
        Remove pid.stale.* files left by a breaker that died mid-recovery.

        .DESCRIPTION
        Called only by the process that currently holds the lock, so it can never
        race a live breaker. Anything younger than the grace is left alone.
    #>
    param([Parameter(Mandatory)][string]$LockPath)
    try {
        $residue = [System.IO.Directory]::GetFiles($LockPath, 'pid.stale.*')
    } catch {
        return
    }
    foreach ($file in $residue) {
        if ((Get-FmPathAge -Path $file) -lt (Get-FmLockStaleAfterSeconds)) { continue }
        try { [System.IO.File]::Delete($file) } catch { Write-Verbose "firstmate: could not sweep $file" }
    }
}

function Invoke-FmLockBreak {
    <#
        .SYNOPSIS
        Make one atomic attempt to remove a proven-stale holder. True when this
        caller is the one that removed it.

        .DESCRIPTION
        The dead holder's sidecars go first - nobody can claim while its pid file
        still exists - and then the pid file is RENAMED to a name unique to this
        process. Rename of one source file succeeds for exactly one caller, so
        exactly one breaker proceeds and the rest fall back to re-reading the
        lock. The renamed file is then deleted; a crash between the two leaves an
        inert pid.stale.* file that the next holder sweeps up.
    #>
    param([Parameter(Mandatory)][string]$LockPath)

    $pidFile = Join-Path $LockPath 'pid'
    Remove-FmLockChildFile -LockPath $LockPath -Name ($script:FmLockChildNames | Where-Object { $_ -ne 'pid' })

    $ticks = [datetime]::UtcNow.Ticks
    $claimed = Join-Path $LockPath "pid.stale.$PID.$ticks"
    try {
        [System.IO.File]::Move($pidFile, $claimed, $false)
    } catch {
        return $false
    }
    # A crash before this delete leaves an inert pid.stale.* file that the next
    # holder sweeps up, so failing to remove it now costs nothing.
    try { [System.IO.File]::Delete($claimed) } catch { Write-Verbose "firstmate: could not remove $claimed" }
    return $true
}

function Request-FmLock {
    <#
        .SYNOPSIS
        Try once to acquire a lock. Returns the lock object, or $null when held.

        .DESCRIPTION
        Non-blocking, like fm_lock_try_acquire. On failure the holder is available
        from Get-FmLastLockHolder, so the caller can report it without a second
        racing read.

        A stale holder is recovered in place - the reason a crashed session never
        deadlocks the home - and the recovered process id is reported on the
        returned lock's RecoveredProcessId (bash's FM_LOCK_RECOVERED_PID) so a
        caller that cares about a crash having happened can see it.

        Release with Unlock-FmLock, or use Invoke-FmWithLock, which releases even
        when the body throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Role,
        [string]$WatcherPath,
        [string]$HomePath,
        [ValidateRange(1, 16)][int]$MaxBreakAttempts = 3
    )

    $full = Resolve-FmFullPath -Path $Path
    $key = Get-FmLockKey -Path $full
    $script:FmLastLockHolder = $null

    if ($script:FmHeldLocks.ContainsKey($key)) {
        throw [System.InvalidOperationException]::new(
            "firstmate: this process already holds the lock '$full'. " +
            'A lock is held per process, so taking it twice would wait forever; ' +
            'release it or restructure the call.')
    }
    if ([System.IO.File]::Exists($full)) {
        throw [System.IO.IOException]::new(
            "firstmate: lock path '$full' exists but is a file, not a lock directory; refusing to touch it")
    }

    # The lock DIRECTORY is created once and then kept forever; only the pid file
    # inside it is created and destroyed. That is not tidiness, it is the
    # correctness property: while release also removed the directory, a releaser
    # could unlink it just as a new claimer was creating its pid file inside,
    # and the claim would evaporate with no error - two processes then each
    # believed they held the lock. Measured before this change: three processes
    # taking one lock 40 times each produced repeated double-claims. With a
    # permanent directory the only contended operation left is the atomic
    # CreateNew of one file, which the OS decides for exactly one winner.
    New-FmDirectory -Path $full
    $pidFile = Join-Path $full 'pid'
    $identity = Get-FmProcessIdentity -Id $PID
    $recovered = $null

    for ($attempt = 0; $attempt -le $MaxBreakAttempts; $attempt++) {
        $claimed = $false
        try {
            $stream = [System.IO.File]::Open(
                $pidFile,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read)
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes("$PID`n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush($true)
                $claimed = $true
            } finally { $stream.Dispose() }
        } catch [System.IO.IOException] {
            # Someone else owns the pid file. Ordinary contention: look and decide.
            $claimed = $false
        } catch [System.UnauthorizedAccessException] {
            $claimed = $false
        }

        if ($claimed) {
            # Publish the ownership details, then verify the pid file still says
            # us. Nothing can legitimately overwrite it, so a mismatch means
            # something outside this module removed our claim - report the lock
            # as unavailable and touch NOTHING, because whatever is in there now
            # may be a live holder's.
            $identityValue = if ($identity) { $identity } else { '' }
            Write-FmStateFile -Path (Join-Path $full 'pid-identity') -Content $identityValue
            if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) {
                Write-FmStateFile -Path (Join-Path $full 'fm-home') -Content $HomePath
            }
            if ($Role) { Write-FmStateFile -Path (Join-Path $full 'role') -Content $Role }
            if ($WatcherPath) { Write-FmStateFile -Path (Join-Path $full 'watcher-path') -Content $WatcherPath }

            $readback = Read-FmStateFile -Path $pidFile
            if ($null -eq $readback -or $readback.Trim() -ne [string]$PID) {
                $null = $script:FmHeldLocks.Remove($key)
                $script:FmLastLockHolder = Get-FmLockInfo -Path $full
                return $null
            }

            Clear-FmLockBreakResidue -LockPath $full
            $lock = [pscustomobject]@{
                PSTypeName         = 'Firstmate.Lock'
                Path               = $full
                ProcessId          = $PID
                Identity           = $identity
                Role               = $Role
                WatcherPath        = $WatcherPath
                Home               = $HomePath
                AcquiredUtc        = [datetime]::UtcNow
                RecoveredProcessId = $recovered
            }
            $script:FmHeldLocks[$key] = $lock
            return $lock
        }

        # if/elseif rather than switch: `continue` inside a PowerShell switch
        # continues the SWITCH, not the enclosing loop, which would silently turn
        # every retry into a fall-through.
        $info = Get-FmLockInfo -Path $full
        if ($info.State -eq 'stale') {
            $recovered = $info.ProcessId
            $null = Invoke-FmLockBreak -LockPath $full
            continue                        # win or lose the break, re-attempt
        }
        if ($info.State -ne 'free') {       # held, claiming, or invalid
            $script:FmLastLockHolder = $info
            return $null
        }
        # 'free' - released under us; go round and claim it.
    }

    $script:FmLastLockHolder = Get-FmLockInfo -Path $full
    return $null
}

function Get-FmLastLockHolder {
    <#
        .SYNOPSIS
        Holder information from the most recent failed Request-FmLock.
    #>
    [OutputType([pscustomobject])]
    param()
    return $script:FmLastLockHolder
}

function Wait-FmLock {
    <#
        .SYNOPSIS
        Acquire a lock, waiting for the current holder.

        .DESCRIPTION
        fm_lock_acquire_wait waits forever. This waits for -TimeoutSeconds (0
        waits forever) and then throws, naming the holder. The bounded default is
        deliberate: an unattended agent process that blocks forever on a lock is
        indistinguishable from a wedge, and a timeout with the holder's pid in
        the message is a diagnosis rather than a mystery.

        Polling starts tight and backs off (5ms growing to 150ms), so a lock held
        for a millisecond - an appended status line - costs a millisecond, while a
        lock held for a minute costs almost no wasted wakeups. Each interval is
        jittered so two waiters do not resynchronize into lockstep collisions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 60,
        [string]$Role,
        [string]$WatcherPath,
        [string]$HomePath
    )

    $request = @{ Path = $Path }
    foreach ($name in @('Role', 'WatcherPath', 'HomePath')) {
        if ($PSBoundParameters.ContainsKey($name)) { $request[$name] = $PSBoundParameters[$name] }
    }

    $deadline = if ($TimeoutSeconds -gt 0) { [datetime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [datetime]::MaxValue }
    $poll = 5.0
    while ($true) {
        $lock = Request-FmLock @request
        if ($lock) { return $lock }
        if ([datetime]::UtcNow -ge $deadline) {
            $holder = Get-FmLastLockHolder
            $who = if ($holder -and $holder.ProcessId) { "process $($holder.ProcessId)" } else { 'another process' }
            throw [System.TimeoutException]::new(
                "firstmate: timed out after ${TimeoutSeconds}s waiting for lock '$Path'; held by $who")
        }
        Start-Sleep -Milliseconds ([int][Math]::Max(1, (Get-Random -Minimum ($poll / 2) -Maximum $poll)))
        $poll = [Math]::Min(150.0, $poll * 1.5)
    }
}

function Unlock-FmLock {
    <#
        .SYNOPSIS
        Release a lock this process holds. True when it was released.

        .DESCRIPTION
        Refuses to touch a lock whose pid file no longer names this process: by
        then it belongs to someone else, and removing it would hand a third
        process a lock two others believe they hold.

        The sidecars go first and the pid file LAST, because the pid file is the
        lock: while it exists nobody else can claim, so every other file can be
        cleaned up unhurried, and the single delete that hands the lock on is the
        last thing that happens. The lock directory itself is left in place - see
        Request-FmLock for why removing it is what broke mutual exclusion.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Lock', ValueFromPipeline)]
        [PSTypeName('Firstmate.Lock')]$Lock,

        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path
    )

    process {
        $full = if ($PSCmdlet.ParameterSetName -eq 'Lock') { $Lock.Path } else { Resolve-FmFullPath -Path $Path }
        $key = Get-FmLockKey -Path $full
        if (-not $PSCmdlet.ShouldProcess($full, 'Release lock')) { return $false }

        $pidFile = Join-Path $full 'pid'
        $raw = $null
        try { $raw = Read-FmStateFile -Path $pidFile } catch { $raw = $null }
        if ($null -eq $raw -or $raw.Trim() -ne [string]$PID) {
            $null = $script:FmHeldLocks.Remove($key)
            return $false
        }

        Clear-FmLockBreakResidue -LockPath $full
        Remove-FmLockChildFile -LockPath $full -Name ($script:FmLockChildNames | Where-Object { $_ -ne 'pid' })
        try { [System.IO.File]::Delete($pidFile) } catch { Write-Verbose "firstmate: could not remove $pidFile" }
        $null = $script:FmHeldLocks.Remove($key)
        return $true
    }
}

function Get-FmHeldLock {
    <#
        .SYNOPSIS
        Locks this process currently holds.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)

    if ($PSBoundParameters.ContainsKey('Path')) {
        $key = Get-FmLockKey -Path (Resolve-FmFullPath -Path $Path)
        if ($script:FmHeldLocks.ContainsKey($key)) { return $script:FmHeldLocks[$key] }
        return $null
    }
    return @($script:FmHeldLocks.Values)
}

function Invoke-FmWithLock {
    <#
        .SYNOPSIS
        Run a script block while holding a lock, releasing it whatever happens.

        .DESCRIPTION
        The form every caller should prefer. The release is in a finally block,
        so a throw inside the body cannot leave the home locked - the failure
        mode that turns one broken operation into a wedged fleet.

        .EXAMPLE
        Invoke-FmWithLock -Path (Get-FmMetaLockPath -MetaPath $meta) -ScriptBlock {
            Set-FmKeyValueField -Path $meta -Name 'pr' -Value $url
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 60,
        [string]$Role,
        [string]$HomePath
    )

    $wait = @{ Path = $Path; TimeoutSeconds = $TimeoutSeconds }
    foreach ($name in @('Role', 'HomePath')) {
        if ($PSBoundParameters.ContainsKey($name)) { $wait[$name] = $PSBoundParameters[$name] }
    }
    $lock = Wait-FmLock @wait
    try {
        return & $ScriptBlock
    } finally {
        $null = Unlock-FmLock -Lock $lock
    }
}

function Get-FmMetaLockPath {
    <#
        .SYNOPSIS
        Lock guarding one task's state/<id>.meta record.

        .DESCRIPTION
        Port of fm_meta_lock_path: state/.meta-<id>.lock beside the record.
        Rejects anything that is not a validly named .meta path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MetaPath)

    $full = Resolve-FmFullPath -Path $MetaPath
    $directory = [System.IO.Path]::GetDirectoryName($full)
    $name = [System.IO.Path]::GetFileName($full)
    if (-not $name.EndsWith('.meta')) {
        throw [System.ArgumentException]::new("firstmate: not a .meta record: '$MetaPath'", 'MetaPath')
    }
    $id = $name.Substring(0, $name.Length - '.meta'.Length)
    if (-not (Test-FmTaskId -TaskId $id)) {
        throw [System.ArgumentException]::new("firstmate: invalid task id in meta path: '$MetaPath'", 'MetaPath')
    }
    return (Join-Path $directory ".meta-$id.lock")
}

function Get-FmTaskSetLockPath {
    <#
        .SYNOPSIS
        Lock guarding WHICH tasks exist in a home (state/.task-set.lock).

        .DESCRIPTION
        Port of fm_task_set_lock_path. Distinct from the per-task meta lock: a
        per-task lock cannot protect a task that does not exist yet, so
        enumerate-then-mutate flows hold this across the whole operation and a
        concurrent spawn either publishes first or refuses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$StatePath)

    if (-not $StatePath) { $StatePath = Get-FmStateRoot }
    return (Join-Path (Resolve-FmFullPath -Path $StatePath) '.task-set.lock')
}

#region session lock

function Get-FmSessionLockPath {
    <#
        .SYNOPSIS
        Path of the per-home session lock (state/.lock).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$StatePath)
    if (-not $StatePath) { $StatePath = Get-FmStateRoot }
    return (Join-Path (Resolve-FmFullPath -Path $StatePath) '.lock')
}

function Test-FmSessionLockFileSane {
    <#
        .SYNOPSIS
        False when state/.lock exists but is not a plain regular file.

        .DESCRIPTION
        bin/fm-lock.sh refuses a lock that is a directory or a symlink rather
        than following it. The Windows equivalent of that check is a reparse
        point (junction, symlink, or an OneDrive-style placeholder).
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Directory]::Exists($Path)) { return $false }
    if (-not [System.IO.File]::Exists($Path)) { return $true }
    try {
        $attributes = [System.IO.File]::GetAttributes($Path)
    } catch {
        return $false
    }
    return -not ($attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))
}

function Get-FmSessionLockStatus {
    <#
        .SYNOPSIS
        Who holds this home's session lock, and is that session alive?

        .DESCRIPTION
        Read-only, and never fails - matching `fm-lock.sh status`, which always
        exits 0. .Text carries the same wording the bash version prints.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$StatePath)

    $lockPath = Get-FmSessionLockPath -StatePath $StatePath
    $status = [pscustomobject]@{
        PSTypeName = 'Firstmate.SessionLockStatus'
        Path       = $lockPath
        State      = 'free'
        ProcessId  = $null
        Text       = 'lock: free'
    }

    if (-not (Test-FmSessionLockFileSane -Path $lockPath)) {
        $status.State = 'invalid'
        $status.Text = 'lock: not a regular file'
        return $status
    }
    if (-not [System.IO.File]::Exists($lockPath)) { return $status }

    $raw = $null
    try { $raw = Read-FmStateFile -Path $lockPath } catch { $raw = $null }
    if ($null -eq $raw) {
        $status.State = 'unreadable'
        $status.Text = 'lock: unreadable'
        return $status
    }
    $trimmed = $raw.Trim()
    if (-not (Test-FmProcessId -Id $trimmed)) {
        $status.State = 'stale'
        $status.Text = "lock: stale (pid $trimmed dead or not a harness)"
        return $status
    }

    $status.ProcessId = [int]$trimmed
    # Liveness is checked explicitly rather than left to Test-FmHarnessProcess to
    # imply: a session is held only by a process that is BOTH alive and a
    # harness, and each half must be stated.
    $aliveArgs = @{ Id = $status.ProcessId }
    $identity = Read-FmStateFile -Path "$lockPath.identity"
    if ($identity -and $identity.Trim()) { $aliveArgs['Identity'] = $identity.Trim() }
    if ((Test-FmProcessAlive @aliveArgs) -and (Test-FmHarnessProcess -Id $status.ProcessId)) {
        $status.State = 'held'
        $status.Text = "lock: held by live harness pid $($status.ProcessId)"
    } else {
        $status.State = 'stale'
        $status.Text = "lock: stale (pid $($status.ProcessId) dead or not a harness)"
    }
    return $status
}

function Test-FmSessionLockOwnedBySelf {
    <#
        .SYNOPSIS
        True when this process runs INSIDE the session that holds the home's lock.

        .DESCRIPTION
        Port of fm_session_lock_owned_by_self. Membership of the lock's pid in
        this process's harness ancestry is the honest test: the owner sits at an
        unknown depth in a contiguous Claude run. A missing lock, a malformed
        lock, a lock held by a harness outside this ancestry, or an ancestry that
        cannot be resolved all fail closed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$StatePath)

    $lockPath = Get-FmSessionLockPath -StatePath $StatePath
    $raw = $null
    try { $raw = Read-FmStateFile -Path $lockPath } catch { return $false }
    if ($null -eq $raw) { return $false }
    $trimmed = $raw.Trim()
    if (-not (Test-FmProcessId -Id $trimmed)) { return $false }

    $ancestry = Get-FmHarnessAncestry
    if ($null -eq $ancestry -or $ancestry.Count -eq 0) { return $false }
    return $ancestry -contains [int]$trimmed
}

function Request-FmSessionLock {
    <#
        .SYNOPSIS
        Acquire this home's session lock, or report who already holds it.

        .DESCRIPTION
        Port of bin/fm-lock.sh's acquire path. The lock records the HARNESS
        (agent) process id found by walking this process's ancestry, not the id of
        the transient shell running the acquisition - that one is dead moments
        after it is written and its lock would read as stale immediately.

        state/.lock keeps its bash contract exactly: one line, the pid, LF. The
        pid-reuse guard rides in a state/.lock.identity sidecar, which the bash
        side does not read and is unaffected by.

        Acquisition is serialized on state/.lock.acquire, so two sessions racing
        cannot both conclude they own the home. Returns an object rather than
        throwing on contention, because "another session holds it" is a normal
        outcome whose correct handling is to go read-only, not to fail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$StatePath,
        [int]$ProcessId = 0,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 30
    )

    if (-not $StatePath) { $StatePath = Get-FmStateRoot }
    $StatePath = Resolve-FmFullPath -Path $StatePath
    $lockPath = Get-FmSessionLockPath -StatePath $StatePath

    $result = [pscustomobject]@{
        PSTypeName      = 'Firstmate.SessionLockResult'
        Path            = $lockPath
        Acquired        = $false
        ProcessId       = $null
        HolderProcessId = $null
        Reason          = $null
        Message         = ''
    }

    try {
        New-FmDirectory -Path $StatePath
    } catch {
        $result.Reason = 'state-unwritable'
        $result.Message = "error: cannot create session-lock state directory $StatePath; operate read-only until resolved"
        return $result
    }

    $me = if ($ProcessId -gt 0) { $ProcessId } else { Get-FmHarnessAncestryPid }
    if (-not $me) {
        $result.Reason = 'no-harness'
        $result.Message = 'error: cannot locate harness process in ancestry'
        return $result
    }
    $result.ProcessId = $me

    if (-not (Test-FmSessionLockFileSane -Path $lockPath)) {
        $result.Reason = 'not-regular-file'
        $result.Message = 'error: session lock is not a regular file; operate read-only until resolved'
        return $result
    }

    # Fast path: already ours, no claim lock needed (fm-lock.sh does the same).
    $current = $null
    try { $current = Read-FmStateFile -Path $lockPath } catch { $current = $null }
    if ($null -ne $current -and $current.Trim() -eq [string]$me) {
        $result.Acquired = $true
        $result.Message = "lock acquired: harness pid $me"
        return $result
    }

    $claimPath = "$lockPath.acquire"
    try {
        $claim = Wait-FmLock -Path $claimPath -TimeoutSeconds $TimeoutSeconds -HomePath $StatePath
    } catch [System.TimeoutException] {
        $holder = Get-FmLastLockHolder
        $result.Reason = 'claim-contended'
        $result.HolderProcessId = if ($holder) { $holder.ProcessId } else { $null }
        $result.Message = 'error: another session is acquiring the fleet lock; operate read-only until it releases'
        return $result
    }

    try {
        $current = $null
        try { $current = Read-FmStateFile -Path $lockPath } catch { $current = $null }
        if ($null -ne $current) {
            $held = $current.Trim()
            if ($held -ne [string]$me -and (Test-FmProcessId -Id $held)) {
                $identity = Read-FmStateFile -Path "$lockPath.identity"
                $aliveArgs = @{ Id = $held }
                if ($identity -and $identity.Trim()) { $aliveArgs['Identity'] = $identity.Trim() }
                if ((Test-FmProcessAlive @aliveArgs) -and (Test-FmHarnessProcess -Id $held)) {
                    $result.Reason = 'held'
                    $result.HolderProcessId = [int]$held
                    $result.Message = "error: another live firstmate session holds the lock (pid $held); operate read-only until resolved"
                    return $result
                }
            }
        }

        Write-FmStateFile -Path $lockPath -Content ([string]$me)
        $identityToken = Get-FmProcessIdentity -Id $me
        Write-FmStateFile -Path "$lockPath.identity" -Content ($(if ($identityToken) { $identityToken } else { '' }))

        $written = $null
        try { $written = Read-FmStateFile -Path $lockPath } catch { $written = $null }
        if ($null -eq $written -or $written.Trim() -ne [string]$me -or -not (Test-FmSessionLockFileSane -Path $lockPath)) {
            $result.Reason = 'verify-failed'
            $result.Message = 'error: session lock ownership verification failed; operate read-only until resolved'
            return $result
        }

        $result.Acquired = $true
        $result.Message = "lock acquired: harness pid $me"
        return $result
    } finally {
        $null = Unlock-FmLock -Lock $claim
    }
}

function Unlock-FmSessionLock {
    <#
        .SYNOPSIS
        Release this home's session lock when it is ours. True when removed.

        .DESCRIPTION
        The bash version never releases: the lock dies with the session, and the
        next session recovers it by liveness. This exists for the cases bash
        cannot express - a clean shutdown, and test cleanup - and it still
        refuses to remove a lock that names anyone but the given session.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [string]$StatePath,
        [int]$ProcessId = 0
    )

    $lockPath = Get-FmSessionLockPath -StatePath $StatePath
    if (-not [System.IO.File]::Exists($lockPath)) { return $false }

    $me = if ($ProcessId -gt 0) { $ProcessId } else { Get-FmHarnessAncestryPid }
    if (-not $me) { return $false }

    $raw = $null
    try { $raw = Read-FmStateFile -Path $lockPath } catch { return $false }
    if ($null -eq $raw -or $raw.Trim() -ne [string]$me) { return $false }
    if (-not $PSCmdlet.ShouldProcess($lockPath, 'Release session lock')) { return $false }

    Remove-FmStateFile -Path $lockPath
    Remove-FmStateFile -Path "$lockPath.identity"
    return $true
}

#endregion session lock
