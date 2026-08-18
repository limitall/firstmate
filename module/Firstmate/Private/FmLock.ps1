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
      recognizes what it sees. One child is this port's own and bash does not
      read it: pid-identity.<pid>, the pid-reuse guard's record NAMED BY THE
      PROCESS IT DESCRIBES. Every file bash does read keeps its bytes, exactly
      as state/.lock keeps its one-line contract while its guard rides in a
      state/.lock.identity sidecar. Get-FmLockInfo owns why the guard cannot be
      read from the unkeyed sidecar.

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

# One sidecar of a lock directory, or $null when it cannot be read for ANY
# reason. Separate from Read-FmStateFile on purpose: that owner is a general
# reader and must still report a real IO failure to a caller that is writing
# state. Here the answer to "could not read it" is genuinely $null, because the
# only caller is an inspection that must not throw.
function Read-FmLockSidecar {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $value = $null
    try { $value = Read-FmStateFile -Path $Path } catch {
        Write-Verbose "firstmate: could not read lock metadata '$Path'"
        return $null
    }
    if ($null -eq $value) { return $null }
    $trimmed = $value.Trim()
    if ($trimmed) { return $trimmed }
    return $null
}

# Name of the identity record for one process id, inside a lock directory.
#
# THE PID IS IN THE NAME BECAUSE THAT IS WHAT MAKES THE PAIRING PROVABLE. The
# unkeyed 'pid-identity' sidecar has one name for every holder in turn, so
# reading it answers "the identity of whoever last wrote it", which is not the
# same question as "the identity of the process the pid file names" - and the
# two answers differ exactly when a lock changes hands, which under contention
# is constantly. A record named after its own process can only ever have been
# written by a process with that id, so the pid and the identity come from one
# observation by construction rather than by winning a race.
function Get-FmLockIdentityName {
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$ProcessId)
    return "pid-identity.$ProcessId"
}

function Get-FmLockInfo {
    <#
        .SYNOPSIS
        Who holds a lock, and is it free, held, being claimed, or stale?

        .DESCRIPTION
        States:
          free     - no lock directory, no pid file in it, or a pid file that
                     was gone by the time this inspection read it
          held     - the recorded process is alive and still the same process
          claiming - a pid file exists but is not readable yet and is younger
                     than the stale grace: someone is mid-claim, treat as held
          stale    - the recorded process is gone, or the id was recycled by a
                     different process, or an unreadable claim outlived the grace
          invalid  - something that is not a lock directory sits at the path

        .HolderRecord carries the EXACT text this inspection read out of the pid
        file, or $null when it read nothing at all. That is what a break must be
        conditional on, and it is not the same thing as .ProcessId: a stale
        verdict reached because the pid could not be parsed has no ProcessId to
        name, and a break with nothing to match against is a break of whatever
        happens to be there - see Invoke-FmLockBreak.

        Never mutates anything. Recovery decisions are made only by Request-FmLock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FmFullPath -Path $Path
    $pidFile = Join-Path $full 'pid'
    $info = [pscustomobject]@{
        PSTypeName   = 'Firstmate.LockInfo'
        Path         = $full
        State        = 'free'
        ProcessId    = $null
        HolderRecord = $null
        Identity     = $null
        Home         = $null
        Role         = $null
        WatcherPath  = $null
        AgeSeconds   = $null
        IsHeld       = $false
    }

    if ([System.IO.File]::Exists($full)) {
        $info.State = 'invalid'
        return $info
    }
    if (-not [System.IO.Directory]::Exists($full)) { return $info }
    if (-not [System.IO.File]::Exists($pidFile)) { return $info }

    # THE PID FILE IS READ BEFORE ITS AGE IS TAKEN, AND THAT ORDER IS THE
    # CORRECTNESS. A release is exactly one delete, so the pid file can vanish
    # between the existence check above and this line. Get-FmPathAge answers its
    # documented 999999 sentinel for a path it cannot read - "very old", so that
    # no caller ever mistakes an unreadable path for a brand new one - and taking
    # the age FIRST fed that sentinel into the grace comparison below. A lock
    # that had just been released then read as a holder that was unreadable and
    # 999999 seconds old, which is to say STALE, and Request-FmLock went on to
    # break a lock the next process was already legitimately holding.
    #
    # Measured under contention, not inferred: docs/windows-e2e-evidence.md
    # section 18 has the runs, the captured eviction and the rate.
    #
    # Reading the content first removes the sentinel from the decision entirely:
    # a pid file that is not there when it is read is the same answer as a pid
    # file that was not there one statement earlier, which is FREE. A read that
    # THREW is a different thing - something is there and cannot be read - and
    # keeps the grace treatment below, but records no holder, so the break has
    # nothing to match and refuses.
    $raw = $null
    $unreadable = $false
    try { $raw = Read-FmStateFile -Path $pidFile } catch { $unreadable = $true }
    if ($null -eq $raw -and -not $unreadable) { return $info }

    $info.AgeSeconds = Get-FmPathAge -Path $pidFile
    if (-not $unreadable) { $info.HolderRecord = $raw.Trim() }
    $trimmed = if ($null -eq $info.HolderRecord) { '' } else { $info.HolderRecord }

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
    # EVERY sidecar read is wrapped, exactly as the pid read above is, because
    # THIS FUNCTION MUST NOT THROW. It is an inspection: its callers are
    # Request-FmLock deciding whether to wait, and reporters naming a holder.
    # An exception here does not degrade, it propagates - out of Request-FmLock,
    # out of Wait-FmLock, out of Invoke-FmWithLock, and out of the
    # Add-FmStateLine that was only trying to append one status line. The worker
    # then dies with the line unwritten, and a status line is how a crewmate
    # reports done or blocked.
    #
    # WINDOWS IS WHY THIS IS NOT BELT AND BRACES. A releasing holder deletes
    # these sidecars while a competitor is reading them. On POSIX the unlink is
    # immediate, the next File.Exists is false, and Read-FmStateFile answers
    # null - which is what the read-path fix in this same tree handles, and why
    # this never fires on Linux.
    #
    # WINDOWS-UNVERIFIED: no Windows box here. What IS measured on Windows 11 is
    # the symptom - a writer job in the concurrent-append test died while every
    # writer survived on Linux, and the run could only report "13:Failed". The
    # mechanism below is inferred from that plus the platform's documented
    # semantics, not observed: a delete against handles opened with
    # FileShare.Delete leaves the name in DELETE-PENDING, so opens keep failing
    # with UnauthorizedAccessException until the last handle closes. That IS
    # retried (Test-FmTransientIOException), but the budget is finite - 12
    # attempts, ~200ms cap - and an exhausted retry is rethrown by
    # Invoke-FmFileRetry as an IOException at whoever asked.
    #
    # The fix does not depend on that inference being right. Whatever the read
    # throws and for whatever reason, an inspection answering instead of
    # throwing is correct, and the concurrent-append test on Windows is the
    # thing that says whether it was the whole cause.
    #
    # A lock whose sidecars cannot be read is answered as a lock with no
    # recorded identity, which the liveness check below already treats as
    # "cannot prove anything" and resolves to plain liveness - held, never
    # stealable. Failing quiet in that direction is the safe one.
    #
    # THE IDENTITY COMES FROM THE RECORD THIS PID NAMED AFTER ITSELF, AND THAT
    # IS THE OTHER HALF OF THE CORRECTNESS. Reading 'pid' and then reading the
    # unkeyed 'pid-identity' is two observations of a lock that can change hands
    # between them, so the identity compared could belong to a DIFFERENT holder
    # than the pid it was compared against - and a mismatch is reported stale,
    # with a process id in it, so the break's guard passes and a live holder is
    # evicted. Measured under contention with the eviction captured:
    # docs/windows-e2e-evidence.md section 28.4.
    #
    # Re-reading cannot fix that - pid, identity, pid can return the same pair
    # through an A-B-A handover - so the pairing is made structural instead, and
    # it rests on two properties of the pid-keyed record:
    #
    #   published BEFORE the claim, so there is no instant at which the pid file
    #   names a holder whose record has not been written yet;
    #
    #   RETAINED FOR AS LONG AS THAT PROCESS LIVES - not removed on release, not
    #   removed by a break - so a read of it cannot come back empty just because
    #   the holder let go between this function's two reads. It describes a
    #   PROCESS, not a claim. Only Clear-FmLockResidue removes one, and only once
    #   its process is gone.
    #
    # Together those make the answer independent of when this read happens: a
    # record named .<pid> can only have been written by a process holding that
    # id, and it is there whenever that process is.
    $info.Identity = Read-FmLockSidecar -Path (Join-Path $full (Get-FmLockIdentityName -ProcessId $info.ProcessId))
    if ($null -eq $info.Identity) {
        # No pid-keyed record at all. That is what a claim written by bash, or by
        # the version of this code before the keyed record existed, looks like -
        # the unkeyed sidecar is the only identity such a record carries, so it
        # is read and an old record keeps its pid-reuse guard instead of becoming
        # a holder nothing can ever prove stale.
        $info.Identity = Read-FmLockSidecar -Path (Join-Path $full 'pid-identity')
    }
    # Not $home: PowerShell's $HOME is read-only and assigning to it fails.
    $info.Home = Read-FmLockSidecar -Path (Join-Path $full 'fm-home')
    $info.Role = Read-FmLockSidecar -Path (Join-Path $full 'role')
    $info.WatcherPath = Read-FmLockSidecar -Path (Join-Path $full 'watcher-path')

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper called only by functions that have already established ownership; ShouldProcess belongs on those, not on every private step.')]
    param([Parameter(Mandatory)][string]$LockPath, [string[]]$Name = $script:FmLockChildNames)
    foreach ($child in $Name) {
        $path = Join-Path $LockPath $child
        # Best effort: a sidecar that will not delete is not worth failing a
        # release over, and the pid file alone decides ownership.
        try { [System.IO.File]::Delete($path) } catch { Write-Verbose "firstmate: could not remove $path" }
    }
}

function Clear-FmLockResidue {
    <#
        .SYNOPSIS
        Sweep what a lock outlives: pid.stale.* from a breaker that died
        mid-recovery, and pid-identity.<pid> records whose process is gone.

        .DESCRIPTION
        Called only by the process that currently holds the lock, so it can never
        race a live breaker. Anything younger than the grace is left alone.

        THIS IS THE ONLY THING THAT REMOVES AN IDENTITY RECORD, and it removes
        one only when that process is gone - which is what lets every reader
        treat the record as present for as long as its process is (see
        Get-FmLockInfo). An identity record whose process is still ALIVE is never
        swept, whether it holds the lock, is waiting for it, or has released it
        and may take it again.

        Nothing's correctness depends on the sweep RUNNING: a record left behind
        by a dead process is only ever consulted while the pid file names that
        same id, and then it is the honest answer - that holder is gone.
    #>
    param([Parameter(Mandatory)][string]$LockPath)
    $grace = Get-FmLockStaleAfterSeconds
    $residue = @()
    try { $residue = [System.IO.Directory]::GetFiles($LockPath, 'pid.stale.*') } catch {
        Write-Verbose "firstmate: could not enumerate break residue under $LockPath"
    }
    foreach ($file in $residue) {
        if ((Get-FmPathAge -Path $file) -lt $grace) { continue }
        try { [System.IO.File]::Delete($file) } catch { Write-Verbose "firstmate: could not sweep $file" }
    }

    $orphans = @()
    try { $orphans = [System.IO.Directory]::GetFiles($LockPath, 'pid-identity.*') } catch {
        Write-Verbose "firstmate: could not enumerate identity records under $LockPath"
        return
    }
    $prefix = 'pid-identity.'
    foreach ($file in $orphans) {
        # A Windows search pattern ending in '.*' also matches a name with NO
        # extension, so this enumeration returns the unkeyed 'pid-identity'
        # sidecar as well. Deleting that would take the guard off every record
        # written by bash or by the previous version of this code.
        $name = [System.IO.Path]::GetFileName($file)
        if (-not $name.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
        $owner = $name.Substring($prefix.Length)
        if (-not (Test-FmProcessId -Id $owner)) { continue }
        if ([int]$owner -eq $PID) { continue }
        # Age first because it is the cheaper test, and because a record younger
        # than the grace belongs to a claim that may still be in flight.
        if ((Get-FmPathAge -Path $file) -lt $grace) { continue }
        if (Test-FmProcessAlive -Id $owner) { continue }
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

        -HolderRecord IS NOT OPTIONAL BOOKKEEPING, IT IS THE WHOLE SAFETY.
        The caller judges staleness with Get-FmLockInfo and breaks in a separate
        step, and between those two steps another process can legitimately
        recover the same lock and claim it. This function used to rename
        whatever 'pid' file it found, so the late breaker evicted the LIVE
        holder that had just recovered it - two processes then held one lock,
        and the loser's Unlock-FmLock reported false and said nothing, because
        the pid file no longer named it. Measured: reproducible on demand, and
        silent every time.

        So the break is conditional on the victim still being the holder the
        caller proved stale. It is checked TWICE, because a rename cannot carry
        a precondition: once before anything is destroyed, and again after the
        rename has arbitrated, when the file this caller now owns can be read
        without a race. A late breaker that grabbed a live holder's pid file
        puts it straight back and reports failure.

        THE HOLDER IS THE PID FILE'S TEXT, NOT A PID. The guard used to take a
        process id and skip itself whenever it got none, and a stale verdict
        reached because the pid could not be PARSED has no process id to give
        it - so exactly the verdicts with the least evidence behind them broke
        unconditionally, which is how a live holder lost its critical section
        under contention. Matching the exact text covers every stale verdict
        with one rule: when the text is a pid it is the pid, when it is blank or
        malformed the break still only removes the same blank or malformed claim
        that was judged, and a verdict that read NOTHING - $null - names no
        victim and is refused outright.
    #>
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [AllowNull()][object]$HolderRecord = $null
    )

    # Nothing was observed, so there is nothing this call can prove stale.
    if ($null -eq $HolderRecord) { return $false }
    $pidFile = Join-Path $LockPath 'pid'
    $expected = ([string]$HolderRecord).Trim()

    # Before: do not destroy a live holder's sidecars over an outdated verdict.
    $current = $null
    try { $current = Read-FmStateFile -Path $pidFile } catch { $current = $null }
    if ($null -eq $current -or $current.Trim() -ne $expected) { return $false }

    # The dead holder's pid-keyed identity record is left alone, like the release
    # path leaves its own: a break that loses its after-check puts the pid file
    # back, and having removed the live holder's identity record on the way past
    # would have taken the pid-reuse guard off a lock that still has one.
    # Clear-FmLockResidue sweeps it once that process is gone.
    Remove-FmLockChildFile -LockPath $LockPath -Name ($script:FmLockChildNames | Where-Object { $_ -ne 'pid' })

    $ticks = [datetime]::UtcNow.Ticks
    $claimed = Join-Path $LockPath "pid.stale.$PID.$ticks"
    try {
        [System.IO.File]::Move($pidFile, $claimed, $false)
    } catch {
        return $false
    }

    # After: the rename decided one winner, so this file is now ours alone to
    # read. If it is not the holder we proved stale, we took a live holder's
    # lock - put it back and stand down. Move without overwrite, so a process
    # that has already claimed the freed slot is never clobbered by the undo.
    $taken = $null
    try { $taken = Read-FmStateFile -Path $claimed } catch { $taken = $null }
    if ($null -eq $taken -or $taken.Trim() -ne $expected) {
        try { [System.IO.File]::Move($claimed, $pidFile, $false) } catch {
            Write-Verbose "firstmate: could not restore $pidFile after an out-of-date lock break"
        }
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
    # The rule infers [bool] from `$null = $script:FmHeldLocks.Remove($key)`,
    # a discarded assignment. This returns the lock object or $null, never a bool.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The rule infers [bool] from "$null = $script:FmHeldLocks.Remove($key)", a discarded assignment. This returns the lock object or $null, never a bool.')]
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
    $identityValue = if ($identity) { $identity } else { '' }
    $identityRecord = Join-Path $full (Get-FmLockIdentityName -ProcessId $PID)
    $recovered = $null

    for ($attempt = 0; $attempt -le $MaxBreakAttempts; $attempt++) {
        $claimed = $false

        # PUBLISHED BEFORE THE CLAIM, AND THAT ORDER IS THE CORRECTNESS. The pid
        # file is the lock: the instant it names this process, an inspection may
        # read it and go looking for that pid's identity record. Publishing after
        # winning would leave a window where the pid file names a live holder
        # whose record is not there yet, and an inspection falling back in that
        # window reads the UNKEYED sidecar - whatever the previous holder left
        # behind, which is the exact mis-pairing this record exists to remove.
        #
        # ONLY WHEN THE LOCK LOOKS FREE, because CreateNew can only win then, and
        # because publishing over an existing claim would be actively wrong: a
        # lock recorded by a DEAD process whose id this process has since been
        # given would gain a matching, live identity record and read as held by
        # us for ever. Nothing else recovers it either - it names our own pid, so
        # the guard would have proved a lock stale and then removed the proof.
        $published = $false
        if (-not [System.IO.File]::Exists($pidFile)) {
            Write-FmStateFile -Path $identityRecord -Content $identityValue
            $published = $true
        }

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
            # The pre-claim publication above is skipped when the pid file was
            # there a moment earlier; winning anyway means its holder released in
            # between, so publish now rather than hold a lock whose identity
            # record is missing. The window that leaves is inert: the releasing
            # holder removes the unkeyed sidecar BEFORE the pid file, so an
            # inspection landing in it has no identity to mis-pair and falls back
            # to plain liveness, which is held.
            if (-not $published) { Write-FmStateFile -Path $identityRecord -Content $identityValue }
            # The unkeyed sidecar stays, byte for byte, because it is one of the
            # files a bash reader cats. It is no longer what this port's own
            # pid-reuse guard reads - see Get-FmLockInfo.
            Write-FmStateFile -Path (Join-Path $full 'pid-identity') -Content $identityValue
            if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) {
                Write-FmStateFile -Path (Join-Path $full 'fm-home') -Content $HomePath
            }
            if ($Role) { Write-FmStateFile -Path (Join-Path $full 'role') -Content $Role }
            if ($WatcherPath) { Write-FmStateFile -Path (Join-Path $full 'watcher-path') -Content $WatcherPath }

            # Read-FmLockSidecar, so a readback that cannot be PERFORMED lands in
            # the same branch as a readback that disagrees. Both mean the same
            # thing - this process cannot confirm it owns the lock - and the
            # branch below is already the safe answer to that: drop the claim and
            # report the lock unavailable. Letting the read throw instead turns
            # "cannot confirm" into a crash in the caller, and this read races a
            # concurrent breaker's rename of the very file it is reading, which
            # is the delete-pending shape Windows raises on.
            $readback = Read-FmLockSidecar -Path $pidFile
            if ($null -eq $readback -or $readback -ne [string]$PID) {
                $null = $script:FmHeldLocks.Remove($key)
                $script:FmLastLockHolder = Get-FmLockInfo -Path $full
                return $null
            }

            Clear-FmLockResidue -LockPath $full
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
            # Name the holder this verdict is ABOUT. By the time the break runs,
            # the lock may already have been recovered by someone else and be
            # live again; passing what we READ - which is not always a pid, and
            # is $null when the pid file was gone by the time we looked - is what
            # stops this call evicting that new holder.
            $null = Invoke-FmLockBreak -LockPath $full -HolderRecord $info.HolderRecord
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

        Clear-FmLockResidue -LockPath $full
        # THE PID-KEYED IDENTITY RECORD IS NOT REMOVED HERE, and that is
        # deliberate - see Get-FmLockInfo. It describes this PROCESS, not this
        # claim, so it outlives the release and Clear-FmLockResidue sweeps it
        # once the process is gone. Removing it here reopened the very defect
        # this record closes: an inspection that read the pid file just before
        # the release then found no record for that pid, fell back to the
        # unkeyed sidecar - by then the NEXT holder's - and mis-paired again.
        # Measured, with the eviction reproduced: section 28.7.
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
    [OutputType([pscustomobject], [object[]])]
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
    # Read-FmLockSidecar, not Read-FmStateFile: this is a REPORTER. AGENTS.md's
    # rule for it is that a session which cannot verify lock ownership falls
    # back to READ-ONLY, and a throw here is not that fallback - it escapes and
    # takes the caller with it.
    $identity = Read-FmLockSidecar -Path "$lockPath.identity"
    if ($identity) { $aliveArgs['Identity'] = $identity }
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

        The hook and session areas resolve this by name and call it as `-State`,
        the spelling published in the cross-area table in docs/session-start.md.
        That binds today only because `-State` is an unambiguous PREFIX of
        `-StatePath`; adding any second `State*` parameter here would make it
        ambiguous and break both callers at once. The alias pins the published
        spelling so it survives that, without renaming the parameter the rest of
        the session-lock family uses.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Alias('State')][string]$StatePath)

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
                # Same reason as the reporter above, and it matters more here:
                # the enclosing block is try/FINALLY with no catch, so a throw
                # on this read leaves Request-FmSessionLock entirely instead of
                # returning the read-only refusal it documents.
                $identity = Read-FmLockSidecar -Path "$lockPath.identity"
                $aliveArgs = @{ Id = $held }
                if ($identity) { $aliveArgs['Identity'] = $identity }
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
