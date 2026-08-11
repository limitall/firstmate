#requires -Version 7.0
<#
    FmWake.ps1 - durable wake queue, portable locks, and the generation-bound
    recovery marker. Native PowerShell 7 port of bin/fm-wake-lib.sh.

    THE QUEUE RECORD IS A HARD CONTRACT. state/.wake-queue holds

        epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload<LF>

    written as UTF-8 with no BOM and LF (never CRLF) line endings, so a Linux
    firstmate reading a queue this code wrote sees byte-identical records. Every
    write in this file goes through Add-FmWakeQueueBytes / Set-FmFileTextLf,
    never Add-Content/Out-File, precisely because the PowerShell defaults would
    emit CRLF on Windows and corrupt that contract.

    Lock shape differs from bash by design and stays reader-compatible. bash
    claims a lock with `ln -s <ownerdir> <lockdir>`; Windows needs elevation (or
    developer mode) for symlinks, so this port claims a plain DIRECTORY holding
    the same files bash readers already cat: pid, fm-home, pid-identity, role,
    watcher-path. bash's own release/steal paths handle the non-symlink
    directory form (fm_lock_release, fm_lock_recheck_stale_owner), so the two
    implementations interoperate on one machine. The atomic claim is
    File.Move(tmp -> <lockdir>/pid, overwrite:$false), which fails when the
    destination exists on both Windows and Linux, giving the same
    exactly-one-winner guarantee `ln -s` gives bash.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Wake kinds accepted on the queue. Anything else is a caller bug, not data.
$script:FmWakeKinds = @('signal', 'stale', 'check', 'heartbeat')

# Mirrors FM_LOCK_STALE_AFTER: seconds a lock directory with no readable pid is
# still assumed to be mid-acquisition rather than abandoned.
function Get-FmLockStaleAfter {
    $raw = [Environment]::GetEnvironmentVariable('FM_LOCK_STALE_AFTER')
    if ($raw -match '^[0-9]+$') { return [int]$raw }
    return 2
}

function Get-FmUnixTime {
    <# Epoch seconds, the `date +%s` this port replaces. #>
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-FmEnvValue {
    param([Parameter(Mandatory)][string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) { return $null }
    return $value
}

function Get-FmWakeContext {
    <#
        .SYNOPSIS
        Resolve this home's roots and durable wake paths.

        .DESCRIPTION
        Same precedence as bin/fm-wake-lib.sh:
          FM_ROOT  = FM_ROOT_OVERRIDE, else FM_ROOT, else the repo root above bin/
          FM_HOME  = FM_HOME, else FM_ROOT_OVERRIDE, else FM_ROOT
          STATE    = FM_STATE_OVERRIDE, else STATE, else <FM_HOME>/state
        The state directory is created if missing, exactly as the bash library
        does at source time.
    #>
    [OutputType([hashtable])]
    param(
        [string]$Root,
        [string]$FmHome,
        [string]$State
    )

    if (-not $Root) {
        $Root = Get-FmEnvValue 'FM_ROOT_OVERRIDE'
        if (-not $Root) { $Root = Get-FmEnvValue 'FM_ROOT' }
    }
    if (-not $Root) {
        # <module>/Firstmate/Private/FmWake.ps1 -> repo root is four levels up.
        $Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    }
    if (-not $FmHome) {
        $FmHome = Get-FmEnvValue 'FM_HOME'
        if (-not $FmHome) { $FmHome = Get-FmEnvValue 'FM_ROOT_OVERRIDE' }
        if (-not $FmHome) { $FmHome = $Root }
    }
    if (-not $State) {
        $State = Get-FmEnvValue 'FM_STATE_OVERRIDE'
        if (-not $State) { $State = Get-FmEnvValue 'STATE' }
        if (-not $State) { $State = Join-Path $FmHome 'state' }
    }

    if (-not (Test-Path -LiteralPath $State)) {
        $null = New-Item -ItemType Directory -Path $State -Force
    }

    $queue = Get-FmEnvValue 'FM_WAKE_QUEUE'
    if (-not $queue) { $queue = Join-Path $State '.wake-queue' }
    $queueLock = Get-FmEnvValue 'FM_WAKE_QUEUE_LOCK'
    if (-not $queueLock) { $queueLock = Join-Path $State '.wake-queue.lock' }

    return @{
        Root            = $Root
        Home            = $FmHome
        State           = $State
        Queue           = $queue
        QueueLock       = $queueLock
        SeqFile         = Join-Path $State '.wake-queue.seq'
        RecoveryMarker  = Join-Path $State '.watcher-down'
        WatchLock       = Join-Path $State '.watch.lock'
        Beacon          = Join-Path $State '.last-watcher-beat'
    }
}

# --- byte-exact file primitives ---------------------------------------------

function Get-FmLfEncoding {
    # UTF-8 without BOM. New-Object so the no-BOM constructor is unambiguous.
    return (New-Object System.Text.UTF8Encoding $false)
}

function Set-FmFileTextLf {
    <#
        Write $Text verbatim (LF preserved, no BOM, no trailing CRLF rewrite) to
        $Path, replacing it atomically. Every state file firstmate shares with
        the bash implementation goes through here.

        Write-then-move rather than write-in-place: a reader either sees the old
        file or the new one, never a half-written state record.
        # WINDOWS-UNVERIFIED: Windows locks open files where POSIX does not, so
        # the replacing move can fail while another process holds the target
        # open. The temporary is removed and the error propagates rather than
        # leaving a partial file behind.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Private
    )
    $dir = Split-Path -Parent $Path
    if (-not $dir) { $dir = '.' }
    $tmp = Join-Path $dir ('.fm-tmp.' + [Guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($tmp, $Text, (Get-FmLfEncoding))
        if ($Private) { Set-FmPrivateFileMode -Path $tmp }
        [System.IO.File]::Move($tmp, $Path, $true)
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Set-FmPrivateFileMode {
    <#
        The bash original chmods recovery-marker and check-output temporaries to
        0600. POSIX modes exist on Linux/macOS only.
        # WINDOWS-UNVERIFIED: on Windows the file inherits the state directory's
        # ACL instead; there is no chmod equivalent to assert here.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($IsWindows) { return }
    try {
        [System.IO.File]::SetUnixFileMode(
            $Path,
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
    }
    catch {
        # Best effort, exactly like the bash `chmod || rm` guard's intent.
    }
}

function Get-FmFileTextOrEmpty {
    <# `cat X 2>/dev/null || true` - never throws, never returns $null. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try {
        if (-not [System.IO.File]::Exists($Path)) { return '' }
        return [System.IO.File]::ReadAllText($Path, (Get-FmLfEncoding))
    }
    catch { return '' }
}

function Get-FmFirstLine {
    <# The single-line reads bash does with `cat`+`$( )`: drop trailing newline. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $text = Get-FmFileTextOrEmpty -Path $Path
    if ($text.Length -eq 0) { return '' }
    $idx = $text.IndexOf("`n")
    if ($idx -ge 0) { $text = $text.Substring(0, $idx) }
    return $text.TrimEnd("`r")
}

function Test-FmNonEmptyFile {
    <# `[ -s FILE ]`. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $info = [System.IO.FileInfo]::new($Path)
        return ($info.Exists -and $info.Length -gt 0)
    }
    catch { return $false }
}

function Update-FmFileTimestamp {
    <# `touch` - create if absent, otherwise bump mtime. #>
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.File]::Exists($Path)) {
        [System.IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow)
    }
    else {
        [System.IO.File]::WriteAllBytes($Path, [byte[]]::new(0))
    }
}

function Get-FmPathMtime {
    <# `stat -c %Y` - epoch seconds, or $null when the path is unreadable. #>
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    try {
        if ([System.IO.File]::Exists($Path)) {
            $t = [System.IO.File]::GetLastWriteTimeUtc($Path)
        }
        elseif ([System.IO.Directory]::Exists($Path)) {
            $t = [System.IO.Directory]::GetLastWriteTimeUtc($Path)
        }
        else { return $null }
        return [DateTimeOffset]::new($t, [TimeSpan]::Zero).ToUnixTimeSeconds()
    }
    catch { return $null }
}

function Get-FmPathAge {
    <# Seconds since mtime; 999999 ("due immediately") when unreadable. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $m = Get-FmPathMtime -Path $Path
    if ($null -eq $m) { return 999999L }
    return ((Get-FmUnixTime) - $m)
}

function Get-FmFileSignature {
    <#
        `stat -c '%s:%Y'` - the size:mtime signature the watcher persists in
        .seen-* markers. Kept byte-identical so a .seen-* file written here and
        one written by bin/fm-watch.sh compare equal.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $info = [System.IO.FileInfo]::new($Path)
        if (-not $info.Exists) { return $null }
        $m = [DateTimeOffset]::new($info.LastWriteTimeUtc, [TimeSpan]::Zero).ToUnixTimeSeconds()
        return ('{0}:{1}' -f $info.Length, $m)
    }
    catch { return $null }
}

# --- process identity --------------------------------------------------------

function Get-FmCurrentProcessId {
    [OutputType([int])]
    param()
    return $PID
}

function Test-FmProcessAlive {
    <# `kill -0` - true only for a numeric pid naming a live process. #>
    param([AllowNull()][AllowEmptyString()]$ProcessId)
    if ($null -eq $ProcessId) { return $false }
    $text = [string]$ProcessId
    if ($text -notmatch '^[0-9]+$') { return $false }
    try {
        $null = Get-Process -Id ([int]$text) -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function ConvertTo-FmHexString {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    if ($Bytes.Length -eq 0) { return '' }
    return [System.Convert]::ToHexString($Bytes).ToLowerInvariant()
}

function Get-FmProcessIdentity {
    <#
        .SYNOPSIS
        A PID-reuse-proof identity string for <ProcessId>, or $null.

        .DESCRIPTION
        Same purpose as fm_pid_identity: pin a lock to one process incarnation so
        a recycled pid can never look like the watcher that took the lock.

        On Linux this reproduces the bash output byte-for-byte
        ("linux-starttime=<field 22> cmdline-hex=<hex>") by reading /proc through
        .NET - no od, no ps, no shelling out - so a lock written by this port and
        one written by bin/fm-wake-lib.sh are interchangeable on the same box.

        On Windows there is no /proc: the process start time (100ns ticks, which
        the OS never rewrites for a live process) plus the full command line play
        the same role.
        # WINDOWS-UNVERIFIED: Win32_Process command-line retrieval and start-time
        # stability can only be exercised on Windows.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()]$ProcessId)

    $text = [string]$ProcessId
    if ($text -notmatch '^[0-9]+$') { return $null }
    $id = [int]$text

    if (-not $IsWindows) {
        $procRoot = Get-FmEnvValue 'FM_PROC_ROOT_OVERRIDE'
        if (-not $procRoot) { $procRoot = '/proc' }
        $statPath = Join-Path $procRoot "$id/stat"
        $cmdPath = Join-Path $procRoot "$id/cmdline"
        try {
            if ([System.IO.File]::Exists($statPath) -and [System.IO.File]::Exists($cmdPath)) {
                $stat = [System.IO.File]::ReadAllText($statPath)
                $tail = $stat.Substring($stat.LastIndexOf(')') + 1)
                $fields = $tail -split '\s+' | Where-Object { $_ -ne '' }
                if ($fields.Count -lt 20) { return $null }
                $starttime = $fields[19]
                if ($starttime -notmatch '^[0-9]+$') { return $null }
                $hex = ConvertTo-FmHexString ([System.IO.File]::ReadAllBytes($cmdPath))
                if (-not $hex) { return $null }
                # bash prints linux-starttime only when uname is Linux; this
                # branch is Linux-only, so the key matches.
                return ('linux-starttime={0} cmdline-hex={1}' -f $starttime, $hex)
            }
        }
        catch { return $null }
        return $null
    }

    try {
        $proc = Get-Process -Id $id -ErrorAction Stop
        $start = $proc.StartTime.Ticks
        $cmdline = $null
        try {
            $cmdline = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop).CommandLine
        }
        catch { $cmdline = $null }
        if ([string]::IsNullOrEmpty($cmdline)) { $cmdline = $proc.Path }
        if ([string]::IsNullOrEmpty($cmdline)) { $cmdline = $proc.ProcessName }
        $hex = ConvertTo-FmHexString ([System.Text.Encoding]::UTF8.GetBytes($cmdline))
        return ('windows-starttime={0} cmdline-hex={1}' -f $start, $hex)
    }
    catch { return $null }
}

# --- portable locks ----------------------------------------------------------

# Populated by Lock-FmPath for callers that inspect the outcome, mirroring the
# FM_LOCK_HELD_PID / FM_LOCK_RECOVERED_PID globals of the bash library.
$script:FmLockHeldPid = ''
$script:FmLockRecoveredPid = ''

function Get-FmLockHeldPid { return $script:FmLockHeldPid }
function Get-FmLockRecoveredPid { return $script:FmLockRecoveredPid }

function Get-FmLockPid {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$LockDir)
    return (Get-FmFirstLine -Path (Join-Path $LockDir 'pid'))
}

function Test-FmLockMidAcquireFresh {
    <#
        A lock directory with no readable pid is either mid-acquisition or
        abandoned. Treat it as held while it is younger than FM_LOCK_STALE_AFTER
        (floor 2s), exactly as fm_lock_mid_acquire_is_fresh does.
    #>
    param(
        [Parameter(Mandatory)][string]$LockDir,
        [AllowEmptyString()][string]$LockPid
    )
    if ($LockPid -match '^[0-9]+$') { return $false }
    $stale = Get-FmLockStaleAfter
    if ($stale -lt 2) { $stale = 2 }
    return ((Get-FmPathAge -Path $LockDir) -lt $stale)
}

function New-FmLockClaim {
    <#
        The atomic claim. Create the lock directory (idempotent), then move a
        fully written pid file into place with overwrite disabled: File.Move
        without overwrite fails when the destination exists on Windows and on
        Linux, so exactly one caller can ever win. Writing the pid content BEFORE
        the move means no reader can observe a half-written holder.
    #>
    param([Parameter(Mandatory)][string]$LockDir)

    $parent = Split-Path -Parent $LockDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { return $false }

    $tmp = $null
    try {
        $null = [System.IO.Directory]::CreateDirectory($LockDir)
        $tmp = Join-Path $LockDir ('.pid.tmp.' + [Guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($tmp, ("{0}`n" -f (Get-FmCurrentProcessId)), (Get-FmLfEncoding))
        [System.IO.File]::Move($tmp, (Join-Path $LockDir 'pid'), $false)
        $tmp = $null
        return $true
    }
    catch {
        if ($tmp -and [System.IO.File]::Exists($tmp)) {
            try { [System.IO.File]::Delete($tmp) } catch { }
        }
        return $false
    }
}

function Remove-FmLockPath {
    <#
        Drop a lock directory: remove the files bash's fm_lock_clean_known_files
        knows about, then rmdir. Unknown files are deliberately left behind so an
        rmdir failure preserves evidence rather than deleting a stranger's data.
    #>
    param([Parameter(Mandatory)][string]$LockDir)

    # A lock claimed by the bash implementation on this machine is a SYMLINK to
    # a private owner directory. Evicting one means dropping the link and the
    # owner dir behind it, or the owner dir leaks into the state directory.
    $owner = $null
    try {
        $info = [System.IO.DirectoryInfo]::new($LockDir)
        if ($info.LinkTarget) {
            $owner = $info.LinkTarget
            if (-not [System.IO.Path]::IsPathRooted($owner)) {
                $owner = Join-Path (Split-Path -Parent $LockDir) $owner
            }
        }
    }
    catch { $owner = $null }
    if ($owner) {
        try { [System.IO.File]::Delete($LockDir) } catch { }
        if ([System.IO.Directory]::Exists($owner)) { $null = Remove-FmLockPath -LockDir $owner }
        return (-not ([System.IO.Directory]::Exists($LockDir) -or [System.IO.File]::Exists($LockDir)))
    }

    foreach ($name in @('pid', 'fm-home', 'pid-identity', 'role', 'watcher-path')) {
        $p = Join-Path $LockDir $name
        try { if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) } } catch { }
    }
    # Sweep abandoned claim temporaries so a crashed claimant cannot pin the dir.
    try {
        foreach ($stray in [System.IO.Directory]::GetFiles($LockDir, '.pid.tmp.*')) {
            try { [System.IO.File]::Delete($stray) } catch { }
        }
    }
    catch { }
    try {
        [System.IO.Directory]::Delete($LockDir, $false)
        return $true
    }
    catch { return $false }
}

function Lock-FmPath {
    <#
        .SYNOPSIS
        Try once to take <LockDir>. $true on success.

        .DESCRIPTION
        Port of fm_lock_try_acquire, including its stale-owner recovery: when the
        recorded holder is provably dead (and past the mid-acquire window) the
        caller takes a nested <LockDir>.steal lock, re-verifies the holder is
        still that same dead pid, publishes watcher downtime when evicting the
        watcher lock specifically, and only then removes and re-creates. Every
        re-check exists so two racing recoverers cannot both conclude they may
        evict.
    #>
    param([Parameter(Mandatory)][string]$LockDir)

    $script:FmLockHeldPid = ''
    $script:FmLockRecoveredPid = ''

    if (New-FmLockClaim -LockDir $LockDir) { return $true }

    $holder = Get-FmLockPid -LockDir $LockDir
    if (Test-FmProcessAlive $holder) {
        $script:FmLockHeldPid = $holder
        return $false
    }
    if (Test-FmLockMidAcquireFresh -LockDir $LockDir -LockPid $holder) {
        $script:FmLockHeldPid = $holder
        return $false
    }

    $steal = "$LockDir.steal"
    if (-not (Lock-FmPath -LockDir $steal)) {
        $script:FmLockHeldPid = Get-FmLockPid -LockDir $LockDir
        return $false
    }

    try {
        $current = Get-FmLockPid -LockDir $LockDir
        if (Test-FmProcessAlive $current) {
            $script:FmLockHeldPid = $current
            return $false
        }
        if (Test-FmLockMidAcquireFresh -LockDir $LockDir -LockPid $current) {
            $script:FmLockHeldPid = $current
            return $false
        }
        # Re-read under the steal lock: the holder must still be the same dead
        # pid we decided to evict, or someone else already recovered it.
        if ((Get-FmLockPid -LockDir $LockDir) -ne $current) {
            $script:FmLockHeldPid = Get-FmLockPid -LockDir $LockDir
            return $false
        }

        $ctx = Get-FmWakeContext
        if ($LockDir -eq $ctx.WatchLock) {
            # Evicting a dead watcher is watcher downtime: record it before the
            # lock disappears, or the queue could be presented as if no
            # supervision gap had happened.
            if (-not (Publish-FmRecoveryMarker -Marker $ctx.RecoveryMarker -Kind downtime)) {
                $script:FmLockHeldPid = $current
                return $false
            }
        }

        $null = Remove-FmLockPath -LockDir $LockDir
        if (New-FmLockClaim -LockDir $LockDir) {
            $script:FmLockRecoveredPid = $current
            return $true
        }
        $script:FmLockHeldPid = Get-FmLockPid -LockDir $LockDir
        return $false
    }
    finally {
        Unlock-FmPath -LockDir $steal
    }
}

function Wait-FmLock {
    <# fm_lock_acquire_wait: spin until the lock is ours. #>
    param(
        [Parameter(Mandatory)][string]$LockDir,
        [int]$TimeoutSeconds = 0
    )
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-FmUnixTime) + $TimeoutSeconds } else { 0 }
    while (-not (Lock-FmPath -LockDir $LockDir)) {
        if ($deadline -gt 0 -and (Get-FmUnixTime) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 100
    }
    return $true
}

function Unlock-FmPath {
    <# fm_lock_release: release only a lock this process actually holds. #>
    param([Parameter(Mandatory)][string]$LockDir)
    $holder = Get-FmLockPid -LockDir $LockDir
    if ($holder -ne [string](Get-FmCurrentProcessId)) { return }
    $null = Remove-FmLockPath -LockDir $LockDir
}

function Set-FmLockRole {
    <# fm_lock_set_role: label a lock this process holds, read back to confirm. #>
    param(
        [Parameter(Mandatory)][string]$LockDir,
        [Parameter(Mandatory)][ValidateSet('autoarm', 'terminal-check')][string]$Role
    )
    if ((Get-FmLockPid -LockDir $LockDir) -ne [string](Get-FmCurrentProcessId)) { return $false }
    try { Set-FmFileTextLf -Path (Join-Path $LockDir 'role') -Text ("$Role`n") }
    catch { return $false }
    return ((Get-FmFirstLine -Path (Join-Path $LockDir 'role')) -eq $Role)
}

function Get-FmLockRole {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$LockDir)
    return (Get-FmFirstLine -Path (Join-Path $LockDir 'role'))
}

# --- generation-bound recovery marker ----------------------------------------
#
# state/.watcher-down couples three things that must not drift apart: watcher
# downtime, presentation of durable wakes, and the post-handling acknowledgement.
# One line, one of:
#     pending:downtime:<generation>   wakes exist / a watcher died; unhandled
#     pending:handling:<generation>   a drain is presenting them right now
#     acked:<kind>:<generation>       the handling turn acknowledged them
# A generation only ever advances, so an acknowledgement carrying a stale
# generation is refused instead of silently consuming a newer episode's wakes.

$script:FmRecoveryMarkerToken = ''
$script:FmRecoveryMarkerAction = 'none'
$script:FmWatcherMatchedIdentity = ''

function Get-FmRecoveryMarkerToken { return $script:FmRecoveryMarkerToken }
function Get-FmRecoveryMarkerAction { return $script:FmRecoveryMarkerAction }

function Read-FmRecoveryMarker {
    <#
        fm_recovery_marker_read: accept exactly a single-line, well-formed token
        from a regular (non-symlink) file. Anything else is invalid, which the
        arm check quarantines rather than trusts.
    #>
    param([Parameter(Mandatory)][string]$Marker)
    $script:FmRecoveryMarkerToken = ''
    try {
        if (-not [System.IO.File]::Exists($Marker)) { return $false }
        $info = [System.IO.FileInfo]::new($Marker)
        if ($info.LinkTarget) { return $false }
        $text = [System.IO.File]::ReadAllText($Marker, (Get-FmLfEncoding))
    }
    catch { return $false }

    # `wc -l` semantics: exactly one terminated line.
    if ($text.Length -eq 0) { return $false }
    $newlines = 0
    foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`n") { $newlines++ } }
    if ($newlines -ne 1) { return $false }
    if (-not $text.EndsWith("`n")) { return $false }
    $line = $text.Substring(0, $text.Length - 1)

    if ($line -notmatch '^(pending|acked):(handling|downtime):') { return $false }
    $generation = $line.Substring($line.LastIndexOf(':') + 1)
    if ($generation -notmatch '^[A-Za-z0-9._-]+$') { return $false }
    $script:FmRecoveryMarkerToken = $line
    return $true
}

function Write-FmRecoveryMarkerLocked {
    <# _fm_recovery_marker_write_locked - caller must already hold the marker lock. #>
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][ValidateSet('handling', 'downtime')][string]$Kind,
        [string]$Generation
    )
    if (-not $Generation) {
        $Generation = '{0}.{1}.{2}' -f (Get-FmCurrentProcessId), (Get-FmUnixTime), [Guid]::NewGuid().ToString('N').Substring(0, 6)
    }
    try {
        Set-FmFileTextLf -Path $Marker -Text ("pending:{0}:{1}`n" -f $Kind, $Generation) -Private
        return $true
    }
    catch { return $false }
}

function Publish-FmRecoveryMarker {
    <# _fm_recovery_marker_publish: start (or restart) a recovery generation. #>
    param(
        [Parameter(Mandatory)][string]$Marker,
        [ValidateSet('handling', 'downtime')][string]$Kind = 'downtime'
    )
    $lock = "$Marker.lock"
    if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return $false }
    try {
        if ([System.IO.Directory]::Exists($Marker)) { return $false }
        return (Write-FmRecoveryMarkerLocked -Marker $Marker -Kind $Kind)
    }
    finally { Unlock-FmPath -LockDir $lock }
}

function Get-FmRecoveryMarkerSnapshot {
    <# fm_recovery_marker_snapshot: read the token under the marker lock. #>
    param([Parameter(Mandatory)][string]$Marker)
    $script:FmRecoveryMarkerToken = ''
    $lock = "$Marker.lock"
    if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return $false }
    try { $null = Read-FmRecoveryMarker -Marker $Marker }
    finally { Unlock-FmPath -LockDir $lock }
    return $true
}

function Start-FmRecoveryHandling {
    <#
        _fm_recovery_marker_begin_handling. Returns:
          0  now (or already) pending:handling
          1  no usable marker
          3  ExpectedGeneration did not match - a newer episode owns the marker
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Marker,
        [string]$ExpectedGeneration
    )
    $lock = "$Marker.lock"
    if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return 1 }
    try {
        if (-not (Read-FmRecoveryMarker -Marker $Marker)) { return 1 }
        $line = $script:FmRecoveryMarkerToken
        $generation = $line.Substring($line.LastIndexOf(':') + 1)
        if ($ExpectedGeneration -and $generation -ne $ExpectedGeneration) { return 3 }
        if ($line -like 'pending:handling:*') { return 0 }
        if ($line -like 'pending:downtime:*') {
            if (-not (Write-FmRecoveryMarkerLocked -Marker $Marker -Kind handling -Generation $generation)) { return 1 }
            $script:FmRecoveryMarkerToken = "pending:handling:$generation"
            return 0
        }
        return 1
    }
    finally { Unlock-FmPath -LockDir $lock }
}

function Confirm-FmRecoveryMarker {
    <#
        _fm_recovery_marker_ack: flip pending -> acked, but only for the exact
        generation the handling turn was told to acknowledge.
        Returns 0 ok, 1 write failure, 2 no generation supplied, 3 stale.
    #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Marker,
        [AllowEmptyString()][string]$ExpectedGeneration
    )
    if (-not $ExpectedGeneration) { return 2 }
    $lock = "$Marker.lock"
    if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return 1 }
    try {
        if (-not (Read-FmRecoveryMarker -Marker $Marker)) { return 3 }
        $line = $script:FmRecoveryMarkerToken
        if ($line.Substring($line.LastIndexOf(':') + 1) -ne $ExpectedGeneration) { return 3 }
        if ($line -like 'acked:*') { return 0 }
        $line = 'acked:' + $line.Substring('pending:'.Length)
        try { Set-FmFileTextLf -Path $Marker -Text ("$line`n") -Private }
        catch { return 1 }
        $script:FmRecoveryMarkerToken = $line
        return 0
    }
    finally { Unlock-FmPath -LockDir $lock }
}

function Test-FmRecoveryArmCheck {
    <#
        _fm_recovery_marker_arm_check, run by a watcher as it arms. Decides what
        the newly armed watcher owes the fleet:
          none     nothing queued, nothing pending
          recover  durable wakes exist that nobody is presenting - resurface them
          wait     another drain is mid-handling - stay quiet
        Takes the queue lock first, then the marker lock, in that order
        everywhere, so the two locks can never deadlock against each other.
        An unreadable marker is quarantined, never trusted and never deleted.
    #>
    param([Parameter(Mandatory)][string]$Marker)
    $script:FmRecoveryMarkerAction = 'none'
    $ctx = Get-FmWakeContext
    $lock = "$Marker.lock"

    if (-not (Wait-FmLock -LockDir $ctx.QueueLock -TimeoutSeconds 30)) { return $false }
    try {
        if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return $false }
        try {
            $exists = [System.IO.File]::Exists($Marker) -or [System.IO.Directory]::Exists($Marker)
            if (-not $exists) {
                if (Test-FmNonEmptyFile -Path $ctx.Queue) {
                    if (-not (Write-FmRecoveryMarkerLocked -Marker $Marker -Kind downtime)) { return $false }
                    $script:FmRecoveryMarkerAction = 'recover'
                }
                return $true
            }

            if (-not (Read-FmRecoveryMarker -Marker $Marker)) {
                $quarantine = "$Marker.invalid." + [Guid]::NewGuid().ToString('N').Substring(0, 6)
                try {
                    $null = [System.IO.Directory]::CreateDirectory($quarantine)
                    [System.IO.File]::Move($Marker, (Join-Path $quarantine 'marker'), $false)
                }
                catch { return $false }
                if (-not (Write-FmRecoveryMarkerLocked -Marker $Marker -Kind downtime)) { return $false }
                $script:FmRecoveryMarkerAction = 'recover'
                return $true
            }

            $line = $script:FmRecoveryMarkerToken
            if ($line -like 'pending:handling:*') {
                $script:FmRecoveryMarkerAction = 'wait'
                return $true
            }
            if ($line -like 'pending:downtime:*') {
                $script:FmRecoveryMarkerAction = 'recover'
                return $true
            }
            if ($line -like 'acked:*') {
                if (Test-FmNonEmptyFile -Path $ctx.Queue) {
                    if (-not (Write-FmRecoveryMarkerLocked -Marker $Marker -Kind downtime)) { return $false }
                    $script:FmRecoveryMarkerAction = 'recover'
                }
            }
            return $true
        }
        finally { Unlock-FmPath -LockDir $lock }
    }
    finally { Unlock-FmPath -LockDir $ctx.QueueLock }
}

function Invoke-FmRecoveryTransition {
    <#
        fm_recovery_transition. The single owner of every coupled
        marker-plus-lock move, so recovery state and lock ownership can never be
        updated in the wrong order:
          publish               start a recovery generation
          acknowledge           consume one, generation-bound
          arm-check             what a newly armed watcher owes the fleet
          release-lock          publish downtime, THEN release <Target>
          release-lock-existing require a valid marker, then release <Target>
                                without republishing (the resurfaced case)
          clear-stale-lock      publish downtime, THEN delete the stale <Target>
    #>
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][ValidateSet('publish', 'acknowledge', 'arm-check', 'release-lock', 'release-lock-existing', 'clear-stale-lock')][string]$Action,
        [AllowEmptyString()][string]$Target,
        [AllowEmptyString()][string]$Value
    )
    switch ($Action) {
        'publish' {
            $kind = if ($Target) { $Target } else { 'downtime' }
            return (Publish-FmRecoveryMarker -Marker $Marker -Kind $kind)
        }
        'acknowledge' {
            return ((Confirm-FmRecoveryMarker -Marker $Marker -ExpectedGeneration $Target) -eq 0)
        }
        'arm-check' {
            return (Test-FmRecoveryArmCheck -Marker $Marker)
        }
        'release-lock' {
            if (-not $Target) { return $false }
            $kind = if ($Value) { $Value } else { 'downtime' }
            if (-not (Publish-FmRecoveryMarker -Marker $Marker -Kind $kind)) { return $false }
            Unlock-FmPath -LockDir $Target
            return $true
        }
        'release-lock-existing' {
            if (-not $Target) { return $false }
            $lock = "$Marker.lock"
            if (-not (Wait-FmLock -LockDir $lock -TimeoutSeconds 30)) { return $false }
            try {
                if (-not (Read-FmRecoveryMarker -Marker $Marker)) { return $false }
                Unlock-FmPath -LockDir $Target
                return $true
            }
            finally { Unlock-FmPath -LockDir $lock }
        }
        'clear-stale-lock' {
            if (-not $Target) { return $false }
            $kind = if ($Value) { $Value } else { 'downtime' }
            if (-not (Publish-FmRecoveryMarker -Marker $Marker -Kind $kind)) { return $false }
            return (Remove-FmLockPath -LockDir $Target)
        }
    }
    return $false
}

# --- the durable wake queue --------------------------------------------------

function ConvertTo-FmWakeField {
    <#
        fm_wake_clean_field: TAB, CR and LF each become one space, so no field
        value can ever forge a record boundary. Nothing else is altered - the
        payload is display text and must survive verbatim otherwise.
    #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace "[`t`r`n]", ' ')
}

function Add-FmWakeQueueBytes {
    <#
        Append one record. UTF-8, no BOM, LF terminator, opened for append with
        FileShare.ReadWrite so a concurrent bash reader is never locked out.
        # WINDOWS-UNVERIFIED: Windows file locking is stricter than POSIX; the
        # explicit share mode is what keeps a concurrent reader working there.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Record
    )
    $bytes = (Get-FmLfEncoding).GetBytes($Record)
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Add-FmWakeRecord {
    <#
        .SYNOPSIS
        Append one durable wake record. The queue-format owner.

        .DESCRIPTION
        fm_wake_append. Under the queue lock: publish watcher downtime (so a wake
        can never exist without a recovery generation to acknowledge it),
        allocate the next sequence, then append

            epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload<LF>

        Key and payload are field-cleaned first. This ordering is why an
        interrupted append can lose a record but never produce one that no
        acknowledgement covers.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Payload,
        [hashtable]$Context
    )
    if ($script:FmWakeKinds -notcontains $Kind) {
        [Console]::Error.WriteLine("fm_wake_append: invalid wake kind: $Kind")
        return $false
    }
    if (-not $Context) { $Context = Get-FmWakeContext }

    $cleanKey = ConvertTo-FmWakeField $Key
    $cleanPayload = ConvertTo-FmWakeField $Payload
    $epoch = Get-FmUnixTime

    if (-not (Wait-FmLock -LockDir $Context.QueueLock -TimeoutSeconds 60)) { return $false }
    try {
        if (-not (Publish-FmRecoveryMarker -Marker $Context.RecoveryMarker -Kind downtime)) { return $false }

        $seqText = (Get-FmFirstLine -Path $Context.SeqFile)
        $seq = 0L
        if ($seqText -match '^[0-9]+$') { $seq = [long]$seqText }
        $seq += 1
        Set-FmFileTextLf -Path $Context.SeqFile -Text ("$seq`n")

        Add-FmWakeQueueBytes -Path $Context.Queue -Record ("{0}`t{1}`t{2}`t{3}`t{4}`n" -f $epoch, $seq, $Kind, $cleanKey, $cleanPayload)
        return $true
    }
    catch { return $false }
    finally { Unlock-FmPath -LockDir $Context.QueueLock }
}

function Get-FmWakeQueueLines {
    <# Queue rows as strings, LF-split, trailing empty element dropped. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-FmFileTextOrEmpty -Path $Path
    if ($text.Length -eq 0) { return @() }
    return @($text -split "`n" | Where-Object { $_ -ne '' })
}

function Split-FmWakeRecord {
    <# Tab-split one record; $null when it is not a well-formed 5+ field row. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    $parts = $Line -split "`t"
    if ($parts.Count -lt 5) { return $null }
    return [pscustomobject]@{
        Epoch   = $parts[0]
        Seq     = $parts[1]
        Kind    = $parts[2]
        Key     = $parts[3]
        Payload = ($parts[4..($parts.Count - 1)] -join "`t")
        Line    = $Line
    }
}

function Get-FmWakeQueuedKeysLocked {
    <# fm_wake_queued_keys_locked: distinct keys for <Kind>, oldest first. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Context
    )
    if (-not $Context) { $Context = Get-FmWakeContext }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmWakeQueueLines -Path $Context.Queue)) {
        $rec = Split-FmWakeRecord -Line $line
        if (-not $rec) { continue }
        if ($rec.Kind -ne $Kind) { continue }
        if ($seen.Add($rec.Key)) { $out.Add($rec.Key) }
    }
    return $out.ToArray()
}

function Get-FmWakeQueuedKeys {
    <#
        fm_wake_queued_keys. The durable queue stays the authority: a key is
        listed exactly while an unacknowledged record for it is queued.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [hashtable]$Context
    )
    if ($script:FmWakeKinds -notcontains $Kind) {
        [Console]::Error.WriteLine("fm_wake_queued_keys: invalid wake kind: $Kind")
        return @()
    }
    if (-not $Context) { $Context = Get-FmWakeContext }
    if (-not (Wait-FmLock -LockDir $Context.QueueLock -TimeoutSeconds 60)) { return @() }
    try { return (Get-FmWakeQueuedKeysLocked -Kind $Kind -Context $Context) }
    finally { Unlock-FmPath -LockDir $Context.QueueLock }
}

function Get-FmWakeDedupedRecords {
    <#
        fm_wake_print_deduped. One row per (kind, key) - all heartbeats collapse
        to a single row - keeping FIRST-seen order but LAST-seen content, so the
        newest payload for a key is what the handling turn reads.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $order = [System.Collections.Generic.List[string]]::new()
    $line = @{}
    foreach ($raw in (Get-FmWakeQueueLines -Path $Path)) {
        $rec = Split-FmWakeRecord -Line $raw
        if (-not $rec) { continue }
        $dedupe = if ($rec.Kind -eq 'heartbeat') { 'heartbeat' } else { $rec.Kind + "`u{001c}" + $rec.Key }
        if (-not $line.ContainsKey($dedupe)) { $order.Add($dedupe) }
        $line[$dedupe] = $raw
    }
    return @($order | ForEach-Object { $line[$_] })
}

function Get-FmWakeMaxSeq {
    <# The acknowledgement cutoff: highest numeric seq currently queued. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$Path)
    $max = 0L
    foreach ($raw in (Get-FmWakeQueueLines -Path $Path)) {
        $parts = $raw -split "`t"
        if ($parts.Count -lt 2) { continue }
        if ($parts[1] -notmatch '^[0-9]+$') { continue }
        $v = [long]$parts[1]
        if ($v -gt $max) { $max = $v }
    }
    return $max
}

function Restore-FmWakeQueue {
    <#
        fm_wake_restore_queue: put drained records back in front of whatever was
        appended since. Order matters - restored records are older.
    #>
    param(
        [Parameter(Mandatory)][string]$DrainedPath,
        [hashtable]$Context
    )
    if (-not $Context) { $Context = Get-FmWakeContext }
    if ([System.IO.File]::Exists($Context.Queue)) {
        $restore = Join-Path $Context.State (".wake-queue.restore." + (Get-FmCurrentProcessId))
        $drained = [System.IO.File]::ReadAllBytes($DrainedPath)
        $current = [System.IO.File]::ReadAllBytes($Context.Queue)
        $stream = [System.IO.File]::Create($restore)
        try {
            $stream.Write($drained, 0, $drained.Length)
            $stream.Write($current, 0, $current.Length)
        }
        finally { $stream.Dispose() }
        [System.IO.File]::Move($restore, $Context.Queue, $true)
    }
    else {
        [System.IO.File]::Move($DrainedPath, $Context.Queue, $true)
    }
}

# --- signal-key mapping and drain-time annotation ----------------------------

function Get-FmWakeStatusKeyMap {
    <#
        fm_wake_status_key_map. Map one structurally valid signal key to its
        home-local status filename. Queue payload text is deliberately ignored:
        it is display data, never a path authority. Returns $null for anything
        that is not a plain <id>.status / <id>.turn-ended with a safe id.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Key)
    $historical = $false
    if ($Key.EndsWith('.status')) {
        $id = $Key.Substring(0, $Key.Length - '.status'.Length)
    }
    elseif ($Key.EndsWith('.turn-ended')) {
        $id = $Key.Substring(0, $Key.Length - '.turn-ended'.Length)
        $historical = $true
    }
    else { return $null }

    if ($id -eq '' -or $id.StartsWith('.')) { return $null }
    if ($id -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    if ($id.Length -gt 64) { return $null }
    return [pscustomobject]@{ StatusKey = "$id.status"; Historical = $historical }
}

function Get-FmWakeLatestEvent {
    <#
        fm_wake_latest_event: the last non-blank line of a status file, read from
        a bounded tail. Refuses symlinks and non-regular files (the O_NOFOLLOW in
        the bash original) so a status key can never be aimed at something else.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TailBytes = 8192
    )
    try {
        $info = [System.IO.FileInfo]::new($Path)
        if (-not $info.Exists) { return $null }
        if ($info.LinkTarget) { return $null }
        $size = $info.Length
        $start = if ($size -gt $TailBytes) { $size - $TailBytes } else { 0 }
        $stream = [System.IO.FileStream]::new(
            $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
            $buffer = [byte[]]::new($size - $start)
            $read = 0
            while ($read -lt $buffer.Length) {
                $n = $stream.Read($buffer, $read, $buffer.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $chunk = (Get-FmLfEncoding).GetString($buffer, 0, $read)
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }

    if ([string]::IsNullOrEmpty($chunk)) { return $null }
    $lines = $chunk -split "`n"
    $lineNumber = 0
    $line = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '\S') { $line = $lines[$i]; $lineNumber = $i + 1 }
    }
    if ($null -eq $line) { return $null }
    return [pscustomobject]@{
        Line      = ($line -replace "[`t`r]", ' ')
        # A tail that starts mid-line means the reported line may itself be cut.
        Truncated = (($size -gt $TailBytes) -and ($lineNumber -eq 1))
    }
}

function Get-FmWakeAnnotationManifest {
    <# fm_wake_annotation_manifest, then the awk fold: distinct status keys in
       first-seen order, "direct" winning over "historical". #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows)
    $order = [System.Collections.Generic.List[string]]::new()
    $mode = @{}
    foreach ($raw in $Rows) {
        $rec = Split-FmWakeRecord -Line $raw
        if (-not $rec) { continue }
        if ($rec.Kind -ne 'signal') { continue }
        $map = Get-FmWakeStatusKeyMap -Key $rec.Key
        if (-not $map) { continue }
        $thisMode = if ($map.Historical) { 'historical' } else { 'direct' }
        if (-not $mode.ContainsKey($map.StatusKey)) {
            $order.Add($map.StatusKey)
            $mode[$map.StatusKey] = $thisMode
        }
        elseif ($thisMode -eq 'direct') {
            $mode[$map.StatusKey] = 'direct'
        }
    }
    return @($order | ForEach-Object { [pscustomobject]@{ StatusKey = $_; Mode = $mode[$_] } })
}

function Get-FmWakeAnnotations {
    <#
        fm_wake_print_annotations. Best-effort supplemental context, emitted only
        AFTER the caller has committed the raw queue consumption and released the
        append lock, so a slow status read can never delay an append. Every limit
        is a constant, so status-file volume cannot turn a drain into an unbounded
        context read.
        Lengths are counted in characters rather than LC_ALL=C bytes; annotations
        are stdout display text, not a file contract, and character counting
        cannot split a UTF-8 codepoint mid-truncation.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Rows,
        [hashtable]$Context
    )
    if (-not $Context) { $Context = Get-FmWakeContext }
    $tailBytes = 8192
    $itemBytes = 2048
    $globalBytes = 8192
    $markerReserve = 192
    $readCap = 8

    $out = [System.Collections.Generic.List[string]]::new()
    $used = 0
    $omitted = 0
    $readOmitted = 0
    $reads = 0

    foreach ($entry in (Get-FmWakeAnnotationManifest -Rows $Rows)) {
        if ($reads -ge $readCap) { $readOmitted++; continue }
        $reads++
        $event = Get-FmWakeLatestEvent -Path (Join-Path $Context.State $entry.StatusKey) -TailBytes $tailBytes
        if (-not $event) { continue }

        $prefix = 'wake annotation: latest wake-EVENT observed at drain, not current state'
        if ($entry.Mode -eq 'historical') {
            $prefix += '; historical / not necessarily the triggering event'
        }
        $line = "{0}: {1}: {2}" -f $prefix, $entry.StatusKey, $event.Line
        if ($event.Truncated) { $line += ' [truncated]' }
        if (($line.Length + 1) -gt $itemBytes) {
            $suffix = ' [truncated]'
            $keep = $itemBytes - $suffix.Length - 1
            $line = $line.Substring(0, $keep) + $suffix
        }
        $bytes = $line.Length + 1
        if (($used + $bytes + $markerReserve) -gt $globalBytes) { $omitted++; continue }
        $out.Add($line)
        $used += $bytes
    }

    if ($omitted -gt 0) {
        $out.Add("wake annotation: $omitted annotations omitted (global enrichment byte cap)")
    }
    if ($readOmitted -gt 0) {
        $out.Add("wake annotation: $readOmitted annotations omitted (enrichment read cap)")
    }
    return $out.ToArray()
}

# --- watcher liveness --------------------------------------------------------

function Test-FmWatcherLockMatchesPid {
    <#
        fm_watcher_lock_matches_pid: the watch lock must name THIS home, THIS
        watcher path, and an identity that still matches the live process.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$WatchPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ProcessId,
        [Parameter(Mandatory)][string]$FmHome
    )
    $script:FmWatcherMatchedIdentity = ''
    $lockDir = Join-Path $State '.watch.lock'
    $lockHome = Get-FmFirstLine -Path (Join-Path $lockDir 'fm-home')
    $lockPath = Get-FmFirstLine -Path (Join-Path $lockDir 'watcher-path')
    $lockIdentity = Get-FmFirstLine -Path (Join-Path $lockDir 'pid-identity')
    if ($lockHome -ne $FmHome) { return $false }
    if ($lockPath -ne $WatchPath) { return $false }
    if (-not $lockIdentity) { return $false }
    $current = Get-FmProcessIdentity -ProcessId $ProcessId
    if (-not $current) { return $false }
    if ($current -ne $lockIdentity) { return $false }
    $script:FmWatcherMatchedIdentity = $lockIdentity
    return $true
}

function Test-FmWatcherHealthy {
    <#
        fm_watcher_healthy - the PID-STRICT primitive. True only when a live,
        identity-matched watcher PROCESS holds this home's lock AND the beacon is
        fresh. The arm layer and the turn-end guard need exactly this: a leftover
        beacon must never satisfy them.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$WatchPath,
        [int]$Grace = 0,
        [string]$FmHome
    )
    if ($Grace -le 0) { $Grace = Get-FmGuardGrace }
    if (-not $FmHome) { $FmHome = (Get-FmWakeContext).Home }
    $lockDir = Join-Path $State '.watch.lock'
    $watcherPid = Get-FmLockPid -LockDir $lockDir
    if (-not (Test-FmProcessAlive $watcherPid)) { return $false }
    if (-not (Test-FmWatcherLockMatchesPid -State $State -WatchPath $WatchPath -ProcessId $watcherPid -FmHome $FmHome)) { return $false }
    return ((Get-FmPathAge -Path (Join-Path $State '.last-watcher-beat')) -lt $Grace)
}

function Get-FmGuardGrace {
    [OutputType([int])]
    param()
    $raw = [Environment]::GetEnvironmentVariable('FM_GUARD_GRACE')
    if ($raw -match '^[0-9]+$') { return [int]$raw }
    return 300
}

function Get-FmSupervisionModel {
    <#
        fm_supervision_model. Which liveness question is the right one here:
          autoarm     Claude Stop-hook auto-arm - the watcher is armed at turn end
                      and exits on its wake, so it runs only BETWEEN turns.
                      Mid-turn, a fresh beacon with no live watcher is HEALTHY.
          persistent  every other harness - the watcher is a tracked live process,
                      so a live identity-matched pid is the real signal.
        FM_SUPERVISION_MODEL overrides detection; otherwise the harness detector
        (owned elsewhere in the module) decides, so this stays consistent with the
        harness-specific repair line the guards emit.
    #>
    [OutputType([string])]
    param()
    $override = Get-FmEnvValue 'FM_SUPERVISION_MODEL'
    if ($override -in @('autoarm', 'persistent')) { return $override }
    $harness = 'unknown'
    $detector = Get-Command -Name 'Get-FmHarness' -ErrorAction SilentlyContinue
    if ($detector) {
        try { $harness = [string](& $detector) } catch { $harness = 'unknown' }
    }
    if ($harness.Trim() -eq 'claude') { return 'autoarm' }
    return 'persistent'
}

function Get-FmWatcherSupervisionVerdict {
    <#
        fm_watcher_supervision_verdict - the MODEL-AWARE verdict used by the
        pull-warning guard (never by the arm layer or the turn-end guard).
        Reason, when not ok, names the TRUE failing condition:
          no-watcher    a live watcher is the real signal for this model but none
                        holds the lock (the beacon is still fresh)
          stale-beacon  the beacon is stale beyond grace, or absent
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$WatchPath,
        [int]$Grace = 0,
        [string]$FmHome
    )
    if ($Grace -le 0) { $Grace = Get-FmGuardGrace }
    if (-not $FmHome) { $FmHome = (Get-FmWakeContext).Home }

    $age = Get-FmPathAge -Path (Join-Path $State '.last-watcher-beat')
    $fresh = ($age -lt $Grace)

    if ((Get-FmSupervisionModel) -eq 'autoarm') {
        return [pscustomobject]@{ Ok = $fresh; Reason = 'stale-beacon' }
    }
    if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) {
        return [pscustomobject]@{ Ok = $true; Reason = 'stale-beacon' }
    }
    if ($fresh) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no-watcher' }
    }
    return [pscustomobject]@{ Ok = $false; Reason = 'stale-beacon' }
}

function Reset-FmFailureEpisode {
    <#
        fm_failure_episode_reset: clear the Claude auto-arm failure episode.
        Mode 'acquire' takes the budget lock itself; 'held' requires the caller to
        already hold it. Refuses when any target is a directory rather than
        blindly removing it.
    #>
    param(
        [Parameter(Mandatory)][string]$State,
        [ValidateSet('acquire', 'held')][string]$Mode = 'acquire'
    )
    $lock = Join-Path $State '.turnend-claude-blocks.lock'
    $acquired = $false
    if ($Mode -eq 'acquire') {
        if (-not (Lock-FmPath -LockDir $lock)) { return $false }
        $acquired = $true
    }
    else {
        if ((Get-FmLockPid -LockDir $lock) -ne [string](Get-FmCurrentProcessId)) { return $false }
    }
    try {
        $paths = @(
            (Join-Path $State '.turnend-claude-blocks'),
            (Join-Path $State '.claude-autoarm-failure-notified'),
            (Join-Path $State '.claude-autoarm-failure-alarmed'))
        foreach ($p in $paths) {
            if ([System.IO.Directory]::Exists($p)) { return $false }
        }
        foreach ($p in $paths) {
            try { if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) } }
            catch { return $false }
        }
        return $true
    }
    finally {
        if ($acquired) { Unlock-FmPath -LockDir $lock }
    }
}
