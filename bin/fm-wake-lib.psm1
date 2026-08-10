# fm-wake-lib.psm1 - Shared durable wake queue and portable lock helpers.
# Twin: bin/fm-wake-lib.sh
#
# This is the coordination primitive the whole supervision system stands on. If
# it is wrong, two watchers run for one home, or an actionable wake is lost.
# Every deviation from the bash twin below is deliberate, named, and justified;
# nothing here is "improved" while being converted (docs/powershell-port.md,
# "Things that must NOT be improved", and the R2 entry in
# docs/powershell-port-inventory.md).
#
# bash -> PowerShell
# ------------------
#   (source-time FM_ROOT/FM_HOME/STATE/... block)  -> Get-FmWakeContext
#   fm_current_pid                    -> Get-FmCurrentPid
#   fm_pid_alive                      -> Test-FmPidAlive
#   fm_pid_identity                   -> Get-FmPidIdentity
#   fm_path_mtime                     -> Get-FmPathMtime
#   fm_path_age                       -> Get-FmPathAge
#   fm_watcher_lock_matches_pid       -> Test-FmWatcherLockMatchesPid
#   fm_watcher_healthy                -> Test-FmWatcherHealthy
#   FM_WATCHER_HEALTHY_PID            -> Get-FmWatcherHealthyPid
#   FM_LOCK_OWNER_TOKEN_FILE          -> Get-FmLockOwnerTokenFileName
#   fm_lock_path_dir                  -> Get-FmLockPathDir
#   fm_lock_symlinks_work             -> Test-FmLockSymlinksWork
#   fm_lock_owner_shape_ok            -> Test-FmLockOwnerShapeOk
#   fm_lock_fallback_owner            -> Get-FmLockFallbackOwner
#   fm_lock_clean_known_files         -> Clear-FmLockKnownFile
#   fm_lock_teardown_dir              -> Remove-FmLockDir
#   fm_lock_holder_is_live            -> Test-FmLockHolderIsLive
#   fm_lock_abs_path                  -> Get-FmLockAbsPath
#   fm_lock_owner_dir                 -> New-FmLockOwnerDir
#   fm_lock_prepare_owner             -> Initialize-FmLockOwner
#   fm_lock_link_owner                -> Get-FmLockLinkOwner
#   fm_lock_points_to_owner           -> Test-FmLockPointsToOwner
#   fm_lock_publish_link              -> Publish-FmLock
#   fm_lock_unpublish                 -> Unpublish-FmLock
#   fm_lock_write_claim_pid           -> Write-FmLockClaimPid
#   fm_lock_discard_owner             -> Remove-FmLockOwner
#   fm_lock_remove_stray_owner_link   -> Remove-FmLockStrayOwner
#   fm_lock_claim_blocked_by_steal    -> Test-FmLockClaimBlockedBySteal
#   fm_lock_claim                     -> Invoke-FmLockClaim
#   fm_lock_try_create                -> New-FmLock
#   FM_LOCK_OWNER_DIR                 -> Get-FmLockOwnerDir
#   fm_lock_remove_path               -> Remove-FmLockPath
#   fm_lock_mid_acquire_is_fresh      -> Test-FmLockMidAcquireIsFresh
#   fm_lock_recheck_stale_owner       -> Test-FmLockStaleOwner
#   fm_lock_try_acquire               -> Request-FmLock
#   FM_LOCK_HELD_PID                  -> Get-FmLockHeldPid
#   fm_lock_acquire_wait              -> Wait-FmLock
#   fm_lock_release                   -> Unlock-FmLock
#   fm_wake_clean_field               -> ConvertTo-FmWakeField
#   fm_wake_append                    -> Add-FmWake
#   fm_wake_restore_queue             -> Restore-FmWakeQueue
#   fm_wake_print_deduped             -> Get-FmWakeDeduped / Write-FmWakeDeduped
#   fm_wake_status_key_map            -> Get-FmWakeStatusKeyMap
#   fm_wake_annotation_manifest       -> Get-FmWakeAnnotationManifest
#   fm_wake_latest_event              -> Get-FmWakeLatestEvent
#   fm_wake_print_annotations         -> Get-FmWakeAnnotation / Write-FmWakeAnnotation
#
# ============================================================================
# THE LOCK IS A DIRECTORY, IN BOTH REPRESENTATIONS
# ============================================================================
# The primitive the protocol needs is "publish a uniquely named owner handle at
# a fixed path, atomically, and lose if anyone got there first". There are two
# on-disk representations, chosen by a LIVE probe of the filesystem the lock
# sits on, and this twin reproduces both exactly:
#
#   symlink form  - the lock PATH is a symlink to a "<lockbase>.owner.XXXXXX"
#                   directory, so $lockdir/pid resolves straight through to
#                   $ownerdir/pid: the lock publishes its holder in the same
#                   instant it becomes visible.
#   fallback form - where symlinks do not work (stock Git Bash without
#                   Developer Mode), the lock PATH IS AN ORDINARY DIRECTORY
#                   holding `pid` and a `.fm-lock-owner` token file whose
#                   content is the owner directory's path.
#
# The fallback lock is NOT a regular file. bin/fm-wake-lib.sh lines 129-133 say
# why in as many words: fm-watch.sh and fm-watch-arm.sh read and WRITE
# $lockdir/pid, /fm-home, /pid-identity and /watcher-path directly, so a
# regular-file lock would make all ten of those ENOTDIR and the watcher
# singleton would quietly stop being a singleton. Verified on this host: a lock
# taken through the bash twin in a Git Bash state directory is a DIRECTORY
# containing `pid` and `.fm-lock-owner`.
#
# Atomic claim primitives, and which is which:
#   * the fallback CLAIM GATE is bash's `mkdir "$lockdir"` (the loser gets
#     EEXIST). [System.IO.Directory]::CreateDirectory is NOT that primitive -
#     it silently succeeds on an existing directory (verified), so two
#     contenders would both believe they won. The exclusive-create twin here is
#     "create a uniquely named scratch directory, then Directory.Move it onto
#     the lock path": Move throws IOException when the destination exists
#     (verified), which is the EEXIST signal, and the result is an ordinary
#     directory indistinguishable from one `mkdir` made.
#   * [System.IO.File]::Open(..., FileMode::CreateNew, ...) is the twin of the
#     `set -C` NOCLOBBER pid write inside fm_lock_write_claim_pid - a different
#     step, on a different object. It throws IOException when the file exists
#     (verified), and that throw IS the "somebody else already recorded a pid"
#     signal, caught precisely rather than broadly.
#
# Windows deletion semantics are load-bearing: a file another process holds
# open cannot be deleted (verified - File.Delete throws). Every removal path
# here degrades a refused delete to "still held, retry next poll", never to a
# crash and never to a false acquisition, exactly as the bash twin reasons.
#
# ============================================================================
# CROSS-WORLD DIVERGENCES (stated, not hidden)
# ============================================================================
# 1. PID NAMESPACES. Git Bash records an MSYS pid; PowerShell's $PID is a
#    Windows pid, and they are different namespaces (verified: a live MSYS
#    pid is invisible to [Diagnostics.Process]::GetProcessById, and `kill -0`
#    on a live pwsh's $PID fails). Test-FmPidAlive therefore resolves BOTH
#    namespaces before answering "dead", because answering "dead" is the only
#    answer that lets a live lock be stolen. See Test-FmPidAlive.
#    The reverse gap - the bash twin cannot see a PowerShell holder's pid as
#    alive - cannot be fixed from this file and is reported as a change request
#    against bin/fm-wake-lib.sh.
# 2. PROCESS IDENTITY. On Git Bash the bash twin reads the MSYS /proc, which is
#    a virtual filesystem only MSYS programs can see. Where a /proc IS readable
#    (Linux, or FM_PROC_ROOT_OVERRIDE pointing at a real directory) this twin
#    produces the byte-identical `proc-starttime=`/`linux-starttime=` string.
#    On Windows without one it emits a `win-starttime=` identity instead. A
#    foreign-format identity therefore compares as MISMATCH, which is the safe
#    direction (a mismatch reads as "not this process" and triggers repair,
#    where a false match would bless a reused pid).
# 3. O_NOFOLLOW. The bash twin's bounded status read opens with O_NOFOLLOW so a
#    symlink cannot be followed even under a swap race. .NET rejects
#    FILE_FLAG_OPEN_REPARSE_POINT on FileStream (verified), so
#    Get-FmWakeLatestEvent checks for a reparse point before AND after opening,
#    which narrows the race rather than closing it.
# 4. Paths in durable records stay POSIX. The `.fm-lock-owner` token and the
#    owner directory name are ALWAYS written in POSIX form, whichever form the
#    caller spelled the lock path in, because bash's fm_lock_owner_shape_ok
#    rejects outright any token that does not begin with '/' - and a PowerShell
#    home resolves its own state directory natively, so following the caller's
#    convention would publish a token no bash reader could parse
#    (docs/powershell-port.md contract 3; Get-FmLockAbsPath owns the rule).
#    Readers here accept both forms (the fm_backend_herdr_normalize_host_path
#    precedent).
#
# fm-psproc-lib is the repo's owner of portable process queries; this file
# deliberately does not depend on it, exactly as the bash twin does not, so the
# leaf stays a leaf. Consolidating the two pid-namespace resolvers is follow-up
# work, not conversion work.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# --- module-resolved context -------------------------------------------------
#
# The bash twin resolves these AT SOURCE TIME and creates $STATE there, so the
# same is done at import time. A PowerShell module cannot see a caller's
# non-exported shell variables, so the `${FM_ROOT:-}` / `${STATE:-}` legs read
# the environment only; every firstmate caller that sets them exports them.

$script:FmWakeOwnerTokenFile = '.fm-lock-owner'

# --- path conversion memo ----------------------------------------------------
#
# Declared before the context is resolved because resolving it already converts
# one path.
#
# ConvertTo-FmNativePath resolves a non-drive POSIX path (/tmp/...) through
# cygpath, which is a child process: MEASURED at ~1.2 SECONDS per call on this
# Defender-protected host, against ~3ms for the pure-string MSYS drive form
# (/f/...). The lock protocol converts the same handful of paths dozens of times
# per acquire, so an unmemoized wrapper made a single refused acquire take 14
# seconds - long enough to change the protocol's own timing behavior.
#
# Two multipliers, both handled here rather than by reimplementing any
# conversion (fm-common stays the only owner of the rule):
#   * the same path recurs constantly, so results are cached for the process;
#   * a LEAF inside an already-resolved directory needs no probe of its own,
#     because native(dir + "/" + leaf) is native(dir) + "\" + leaf. That is what
#     makes the uniquely named owner and scratch directories this protocol
#     creates free - a per-path probe would never hit a cache for those.
#
# The parent is resolved by ONE cygpath call on the parent ITSELF, never by
# walking further up. Walking up is unsound and was measured to be: MSYS mounts
# /tmp onto C:\Users\<u>\AppData\Local\Temp while / is C:\Program Files\Git, so
# deriving /tmp from / yields "C:\Program Files\Git\tmp" - a real directory that
# would silently accept lock writes in the wrong place. A leaf inside a resolved
# directory is not a mount point, so one level down is safe where the whole
# chain is not.
#
# The MSYS mount table cannot change inside one process's lifetime, so the memo
# has no invalidation problem.
$script:FmWakeNativeCache = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)

function ConvertTo-FmWakeNative {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $cached = ''
    if ($script:FmWakeNativeCache.TryGetValue($Path, [ref]$cached)) { return $cached }

    $native = $null
    # Only a non-drive absolute POSIX path can reach cygpath; everything else is
    # already a pure string transform inside ConvertTo-FmNativePath.
    if ($Path.StartsWith('/') -and $Path -notmatch '^/[A-Za-z](/|$)') {
        $dir = Get-FmLockPathDir -Path $Path
        $leaf = Get-FmLockPathLeaf -Path $Path
        if ($dir -cne $Path -and $dir.Length -gt 1 -and $dir.StartsWith('/') -and $leaf -ne '') {
            $nativeDir = ''
            if (-not $script:FmWakeNativeCache.TryGetValue($dir, [ref]$nativeDir)) {
                $nativeDir = ConvertTo-FmNativePath $dir
                $script:FmWakeNativeCache[$dir] = $nativeDir
            }
            if (-not [string]::IsNullOrEmpty($nativeDir) -and $nativeDir -cne $dir) {
                $native = $nativeDir.TrimEnd('\') + '\' + $leaf
            }
        }
    }
    if ($null -eq $native) { $native = ConvertTo-FmNativePath $Path }
    $script:FmWakeNativeCache[$Path] = $native
    return $native
}

# The `[ -L "$p" ]` twin, routed through the memo so a repeated probe of the
# same lock path costs nothing.
function Test-FmWakeSymlink {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return (Test-FmSymlink -Path (ConvertTo-FmWakeNative -Path $Path))
}

function Initialize-FmWakeContext {
    $defaultRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $rootOverride = Get-FmEnv -Name 'FM_ROOT_OVERRIDE'
    $root = Get-FmEnv -Name 'FM_ROOT' -Default $defaultRoot
    if ($rootOverride) { $root = $rootOverride }

    $fmHome = Get-FmEnv -Name 'FM_HOME'
    if (-not $fmHome) { $fmHome = if ($rootOverride) { $rootOverride } else { $root } }

    $state = Get-FmEnv -Name 'STATE' -Default (Join-Path $fmHome 'state')
    $stateOverride = Get-FmEnv -Name 'FM_STATE_OVERRIDE'
    if ($stateOverride) { $state = $stateOverride }

    $script:FmWakeContext = @{
        Root       = $root
        Home       = $fmHome
        State      = $state
        Queue      = Get-FmEnv -Name 'FM_WAKE_QUEUE' -Default (Join-Path $state '.wake-queue')
        QueueLock  = Get-FmEnv -Name 'FM_WAKE_QUEUE_LOCK' -Default (Join-Path $state '.wake-queue.lock')
        StaleAfter = Get-FmEnv -Name 'FM_LOCK_STALE_AFTER' -Default '2'
    }

    # `mkdir -p "$STATE"` with the bash twin's error handling: it runs without
    # `set -e`, so a failure is ignored and the first real write reports it.
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmWakeNative -Path $state))
    } catch {
        $null = $_
    }
}

Initialize-FmWakeContext

<#
.SYNOPSIS
The resolved wake-queue context: Root, Home, State, Queue, QueueLock, StaleAfter.
.DESCRIPTION
The twin of the variables the bash library exports at source time. Resolved
once at import, like the bash twin, so a caller that changes FM_STATE_OVERRIDE
after import sees no effect in either world.
#>
function Get-FmWakeContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:FmWakeContext
}

<#
.SYNOPSIS
The filename of a fallback lock's owner token (FM_LOCK_OWNER_TOKEN_FILE).
.DESCRIPTION
Listed in Clear-FmLockKnownFile so a lock directory always stays removable
through the normal removal paths.
#>
function Get-FmLockOwnerTokenFileName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmWakeOwnerTokenFile
}

# --- small file primitives ---------------------------------------------------
#
# Every path reaching a .NET API goes through ConvertTo-FmWakeNative first, and
# a path handed on to an fm-common helper is handed on ALREADY NATIVE, so that
# helper's own conversion is the free drive-letter branch.
#
# Two distinct bash idioms, deliberately kept distinct because the library uses
# each where it means something different:
#   Get-FmWakeText  = $(cat "$f" 2>/dev/null || true)  - whole file, trailing
#                     newlines stripped by the command substitution.
#   Get-FmWakeLine  = IFS= read -r x < "$f"            - the FIRST line only,
#                     verbatim (IFS empty, so nothing is trimmed).

function Get-FmWakeText {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmWakeNative -Path $Path
    try {
        if (-not [System.IO.File]::Exists($native)) { return '' }
        return ([System.IO.File]::ReadAllText($native)).TrimEnd("`n")
    } catch {
        return ''
    }
}

function Get-FmWakeLine {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmWakeNative -Path $Path
    try {
        if (-not [System.IO.File]::Exists($native)) { return '' }
        $text = [System.IO.File]::ReadAllText($native)
    } catch {
        return ''
    }
    $idx = $text.IndexOf("`n")
    if ($idx -ge 0) { return $text.Substring(0, $idx) }
    return $text
}

# `[ -e "$p" ] || [ -L "$p" ]`: a dangling symlink is invisible to Test-Path
# but must still count as "something is already there".
function Test-FmWakePathPresent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmWakeNative -Path $Path
    if (Test-Path -LiteralPath $native) { return $true }
    return (Test-FmWakeSymlink -Path $Path)
}

function Test-FmWakeDirectory {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return [System.IO.Directory]::Exists((ConvertTo-FmWakeNative -Path $Path))
}

# `rm -f "$p" 2>/dev/null || true`: absence is success, a refused delete is not.
function Remove-FmWakeFileQuiet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A private `rm -f` twin on the hot path of a lock protocol whose bash twin deletes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher mid-protocol.')]
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmWakeNative -Path $Path
    try {
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch {
        $null = $_
    }
}

# The exclusive-create twin of `mkdir "$dir"` - see the header for why
# Directory::CreateDirectory cannot be used. The scratch name carries a GUID so
# it needs no exclusivity of its own, and it is created in the DESTINATION's
# own directory so the rename stays same-volume and therefore atomic.
function New-FmWakeExclusiveDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal lock primitive on the hot path of a protocol whose bash twin creates unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $native = ConvertTo-FmWakeNative -Path $Path
    $parent = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    $scratch = Join-Path $parent (".fm-mkdir.{0}" -f [System.Guid]::NewGuid().ToString('N'))
    try {
        [void][System.IO.Directory]::CreateDirectory($scratch)
    } catch {
        return $false
    }
    try {
        [System.IO.Directory]::Move($scratch, $native)
        return $true
    } catch [System.IO.IOException] {
        # The destination already exists (we lost the gate), or Windows refused
        # the rename. Both mean "not ours"; the bash `mkdir || return 1` twin
        # makes no distinction either.
        try { [System.IO.Directory]::Delete($scratch, $false) } catch { $null = $_ }
        return $false
    } catch {
        try { [System.IO.Directory]::Delete($scratch, $false) } catch { $null = $_ }
        return $false
    }
}

# --- process identity and liveness -------------------------------------------

<#
.SYNOPSIS
This process's own pid (fm_current_pid).
#>
function Get-FmCurrentPid {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $PID
}

# `ps -W` is the only complete view of the MSYS pid namespace available to a
# native process, and it costs about a second here, so the table is memoized.
# The TTL is one-directional on purpose: a POSITIVE hit may be up to TTL stale
# (which only DELAYS reclaiming a lock - safe), while a MISS always refreshes
# before concluding "dead", because "dead" is the answer that lets a live lock
# be stolen.
$script:FmMsysPidTable = $null
$script:FmMsysPidTableAt = [datetime]::MinValue
$script:FmMsysPidTableTtl = [timespan]::FromSeconds(5)
$script:FmMsysPs = $null
$script:FmMsysPsResolved = $false

function Get-FmMsysPsPath {
    if ($script:FmMsysPsResolved) { return $script:FmMsysPs }
    $script:FmMsysPsResolved = $true
    $candidates = [System.Collections.Generic.List[string]]::new()
    $bash = Get-FmBash
    if ($bash) {
        $binDir = [System.IO.Path]::GetDirectoryName($bash)
        $gitRoot = [System.IO.Path]::GetDirectoryName($binDir)
        $candidates.Add((Join-Path $gitRoot 'usr\bin\ps.exe'))
        $candidates.Add((Join-Path $binDir 'ps.exe'))
    }
    $candidates.Add('C:\Program Files\Git\usr\bin\ps.exe')
    $candidates.Add('C:\Program Files (x86)\Git\usr\bin\ps.exe')
    foreach ($candidate in $candidates) {
        if ([System.IO.File]::Exists($candidate)) { $script:FmMsysPs = $candidate; break }
    }
    if (-not $script:FmMsysPs) {
        $cmd = Get-Command 'ps' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $script:FmMsysPs = $cmd.Source }
    }
    return $script:FmMsysPs
}

function Update-FmMsysPidTable {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This mutates only an in-process memo, never any durable state, and sits on a liveness path a watcher polls; a confirmation surface would be meaningless and could stall it.')]
    [OutputType([bool])]
    param()

    $exe = Get-FmMsysPsPath
    if (-not $exe) { return $false }
    $result = Invoke-FmTool -FilePath $exe -Arguments @('-W') -TimeoutSeconds 20
    if (-not $result.Ok) { return $false }
    $table = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in ($result.StdOut -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        $first = ($trimmed -split '\s+')[0]
        if ($first -match '^[0-9]+$') { [void]$table.Add($first) }
    }
    # An empty table means ps produced no usable rows; keeping the previous memo
    # (or none) is safer than publishing a table that would call every pid dead.
    if ($table.Count -eq 0) { return $false }
    $script:FmMsysPidTable = $table
    $script:FmMsysPidTableAt = [datetime]::UtcNow
    return $true
}

<#
.SYNOPSIS
True when <Pid> is a live process in the MSYS pid namespace.
.DESCRIPTION
Only consulted after the Windows namespace has already said "not found", and
only where an MSYS runtime actually exists - so on a host with no Git Bash this
answers $false immediately and the native lookup stays authoritative.
#>
function Test-FmMsysPidAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ProcessId)

    if (-not (Test-FmWindows)) { return $false }
    if (-not (Get-FmMsysPsPath)) { return $false }

    $fresh = $false
    if ($null -eq $script:FmMsysPidTable -or
        ([datetime]::UtcNow - $script:FmMsysPidTableAt) -gt $script:FmMsysPidTableTtl) {
        $fresh = Update-FmMsysPidTable
        if (-not $fresh -and $null -eq $script:FmMsysPidTable) {
            # No table at all and none obtainable: this namespace is unreadable,
            # so it cannot contribute a verdict either way.
            return $false
        }
    }
    if ($script:FmMsysPidTable.Contains($ProcessId)) { return $true }
    if ($fresh) { return $false }
    # A miss on a possibly-stale table is never enough to call a pid dead.
    if (-not (Update-FmMsysPidTable)) { return $false }
    return $script:FmMsysPidTable.Contains($ProcessId)
}

<#
.SYNOPSIS
True when <Pid> names a live process (fm_pid_alive).
.DESCRIPTION
Non-numeric input is false, matching the bash twin's `case` guard. On Windows
both pid namespaces are consulted: a lock written by a Git Bash holder carries
an MSYS pid that [Diagnostics.Process]::GetProcessById cannot see (verified),
and treating that as dead would let this process steal a live lock - the exact
failure the whole protocol exists to prevent.
#>
function Test-FmPidAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProcessId)

    if ([string]::IsNullOrEmpty($ProcessId)) { return $false }
    if ($ProcessId -notmatch '^[0-9]+$') { return $false }
    [long]$numeric = 0
    if (-not [long]::TryParse($ProcessId, [ref]$numeric)) { return $false }
    if ($numeric -le 0 -or $numeric -gt [int]::MaxValue) { return $false }

    try {
        $proc = [System.Diagnostics.Process]::GetProcessById([int]$numeric)
        if ($null -ne $proc) {
            try { if ($proc.HasExited) { return $false } } catch { $null = $_ }
            return $true
        }
    } catch {
        $null = $_
    }
    return (Test-FmMsysPidAlive -ProcessId $ProcessId)
}

# The `od -An -v -tx1 ... | tr -d '[:space:]'` twin: lowercase hex of every byte.
function ConvertTo-FmWakeHex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sb = [System.Text.StringBuilder]::new($Bytes.Length * 2)
    foreach ($b in $Bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

<#
.SYNOPSIS
A stable identity string for <Pid>, or $null when none can be produced.
.DESCRIPTION
Byte-identical to the bash twin wherever the bash twin's own preferred source
is readable:

  * a Linux-compatible /proc (or FM_PROC_ROOT_OVERRIDE pointing at one) gives
    `<key>=<stat field 22> cmdline-hex=<hex of the NUL-separated cmdline>`,
    with <key> = linux-starttime on Linux and proc-starttime elsewhere. Field
    22 is clock ticks since boot, immune to the wall-clock steps that re-render
    the ps fallback, and combining the full cmdline keeps PID reuse a mismatch
    even on a tick collision.
  * otherwise `LC_ALL=C ps -p <pid> -o lstart= -o command=`, with LC_ALL pinned
    exactly as the bash twin pins it: the identity is written under one locale
    and re-read under the machine's ambient locale, and an unpinned lstart would
    mismatch on a non-C locale and reject a live watcher.

On Windows neither is available to a native process - the MSYS /proc is visible
only to MSYS programs, and Git Bash's Cygwin ps rejects the portable -o fields -
so a `win-starttime=<creation ticks> cmdline-hex=<hex of the command line>`
identity is emitted instead. It carries the same two properties (immune to
wall-clock steps, changes on pid reuse) and is deliberately keyed differently so
a cross-world comparison reads as MISMATCH rather than silently matching.
#>
function Get-FmPidIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$ProcessId)

    if ([string]::IsNullOrEmpty($ProcessId)) { return $null }
    if ($ProcessId -notmatch '^[0-9]+$') { return $null }

    $procRootOverride = Get-FmEnv -Name 'FM_PROC_ROOT_OVERRIDE'
    $procRoot = if ($procRootOverride) { $procRootOverride } else { '/proc' }
    # A bare /proc can never resolve for a native Windows process, and probing
    # it would pay a cygpath fork on every call, so it is skipped there. An
    # explicit override is always honored (the suites build a real one).
    $tryProc = $true
    if ((Test-FmWindows) -and -not $procRootOverride) { $tryProc = $false }

    if ($tryProc) {
        $statPath = ConvertTo-FmWakeNative -Path "$procRoot/$ProcessId/stat"
        $cmdPath = ConvertTo-FmWakeNative -Path "$procRoot/$ProcessId/cmdline"
        if ([System.IO.File]::Exists($statPath) -and [System.IO.File]::Exists($cmdPath)) {
            try {
                $statLine = ([System.IO.File]::ReadAllText($statPath)).TrimEnd("`n")
            } catch {
                return $null
            }
            # `${stat_line##*)}` - after the FINAL comm delimiter, so a comm
            # containing ')' and spaces cannot shift the field indices.
            $close = $statLine.LastIndexOf(')')
            $rest = if ($close -ge 0) { $statLine.Substring($close + 1) } else { $statLine }
            $fields = @($rest -split '\s+' | Where-Object { $_ -ne '' })
            if ($fields.Count -lt 20) { return $null }
            $startTime = $fields[19]
            if ($startTime -notmatch '^[0-9]+$') { return $null }
            try {
                $cmdBytes = [System.IO.File]::ReadAllBytes($cmdPath)
            } catch {
                return $null
            }
            $cmdHex = ConvertTo-FmWakeHex -Bytes $cmdBytes
            if ($cmdHex -eq '') { return $null }
            $identityKey = if ($IsLinux) { 'linux-starttime' } else { 'proc-starttime' }
            return "$identityKey=$startTime cmdline-hex=$cmdHex"
        }
    }

    if (-not (Test-FmWindows)) {
        $previous = [Environment]::GetEnvironmentVariable('LC_ALL')
        try {
            [Environment]::SetEnvironmentVariable('LC_ALL', 'C')
            $result = Invoke-FmTool -FilePath 'ps' -Arguments @('-p', $ProcessId, '-o', 'lstart=', '-o', 'command=')
        } catch {
            return $null
        } finally {
            [Environment]::SetEnvironmentVariable('LC_ALL', $previous)
        }
        if (-not $result.Ok) { return $null }
        $out = $result.StdOut.TrimEnd("`n")
        if ($out -eq '') { return $null }
        return (($out -split "`n") | ForEach-Object { $_ -replace '^\s+', '' }) -join "`n"
    }

    try {
        $proc = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
        $ticks = $proc.StartTime.ToUniversalTime().Ticks
    } catch {
        return $null
    }
    $commandLine = ''
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($null -ne $cim -and $null -ne $cim.CommandLine) { $commandLine = [string]$cim.CommandLine }
    } catch {
        $null = $_
    }
    if ($commandLine -eq '') {
        try { $commandLine = [string]$proc.MainModule.FileName } catch { $commandLine = '' }
    }
    $hex = ConvertTo-FmWakeHex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($commandLine))
    if ($hex -eq '') { return $null }
    return "win-starttime=$ticks cmdline-hex=$hex"
}

# --- path age ----------------------------------------------------------------

<#
.SYNOPSIS
A path's mtime in whole epoch seconds, or $null when it cannot be read.
.DESCRIPTION
The `stat -c %Y` / `stat -f %m` twin. Get-Item rather than the File overload
because the argument is frequently a lock DIRECTORY, and the File overload
returns a 1601 sentinel for one instead of failing. In-process, so the uname
branch the bash twin needs disappears; both truncate to whole seconds, so the
two agree.
#>
function Get-FmPathMtime {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    try {
        $item = Get-Item -LiteralPath (ConvertTo-FmWakeNative -Path $Path) -Force -ErrorAction Stop
        return ([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
A path's mtime age in whole seconds, or 999999 when the mtime is unreadable.
.DESCRIPTION
The 999999 sentinel is the bash twin's, and it is load-bearing: an unreadable
mtime must read as ancient so a freshness check cannot protect a lock nobody
can measure.
#>
function Get-FmPathAge {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $mtime = Get-FmPathMtime -Path $Path
    if ($null -eq $mtime) { return 999999 }
    return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime)
}

# --- watcher lock identity ---------------------------------------------------

$script:FmWatcherHealthyPid = ''

<#
.SYNOPSIS
True when the watcher lock in <State> names <Pid> with a matching identity.
#>
function Test-FmWatcherLockMatchesPid {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$WatchPath,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$ProcessId,
        [string]$FmHome
    )

    if (-not $PSBoundParameters.ContainsKey('FmHome')) { $FmHome = $script:FmWakeContext.Home }
    $lockDir = "$State/.watch.lock"
    $lockHome = Get-FmWakeText -Path "$lockDir/fm-home"
    $lockPath = Get-FmWakeText -Path "$lockDir/watcher-path"
    $lockIdentity = Get-FmWakeText -Path "$lockDir/pid-identity"
    if ($lockHome -ne $FmHome) { return $false }
    if ($lockPath -ne $WatchPath) { return $false }
    if ([string]::IsNullOrEmpty($lockIdentity)) { return $false }
    $current = Get-FmPidIdentity -ProcessId $ProcessId
    if ([string]::IsNullOrEmpty($current)) { return $false }
    return ($current -eq $lockIdentity)
}

<#
.SYNOPSIS
True when a live, identity-matched watcher holds <State> with a fresh beacon.
.DESCRIPTION
Get-FmWatcherHealthyPid returns the confirmed pid afterwards, mirroring the
bash twin's FM_WATCHER_HEALTHY_PID out-variable.
#>
<#
.SYNOPSIS
The supervision model for this home: 'autoarm' or 'persistent'.
.DESCRIPTION
Twin of fm_supervision_model. An explicit FM_SUPERVISION_MODEL wins when it
names one of the two models; anything else falls through to the harness, where
claude is autoarm and every other harness is persistent. A harness that cannot
be resolved reports 'unknown', which is not claude, so it lands on persistent -
the STRICTER model, which is the safe direction for a verdict.
#>
function Get-FmSupervisionModel {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $explicit = Get-FmEnv -Name 'FM_SUPERVISION_MODEL'
    if ($explicit -ceq 'autoarm' -or $explicit -ceq 'persistent') { return $explicit }

    $harness = 'unknown'
    try {
        # $PSScriptRoot is the bash's $FM_WAKE_LIB_DIR: the LIBRARY's own
        # directory, not the caller's, so a script invoked from elsewhere still
        # resolves the harness resolver beside this file.
        $result = Invoke-FmScript 'fm-harness' @() -BinDir $PSScriptRoot
        if ($result.Ok) { $harness = $result.StdOut.Trim() }
    } catch {
        $harness = 'unknown'
    }
    if ($harness -ceq 'claude') { return 'autoarm' }
    return 'persistent'
}

<#
.SYNOPSIS
Model-aware "is supervision healthy right now" verdict, with the failing reason.
.DESCRIPTION
Twin of fm_watcher_supervision_verdict. Returns an object with Ok and Reason,
where the bash set two globals. For the pull-warning guard only - NOT the arm
layer and NOT the turn-end guard.

  autoarm     a fresh beacon within grace is healthy EVEN WITH no live watcher,
              because that watcher only runs between turns; only a stale beacon
              is a genuine lapse.
  persistent  a live identity-matched watcher AND a fresh beacon are required;
              a fresh leftover beacon with no live watcher is still down.

Reason is the true failing condition, and the guard keys its alarm episode on
it rather than on the beacon mtime: under autoarm a healthy watcher advances
that mtime every poll, so a mtime-derived key changes every turn and re-prints
the full banner forever.
#>
function Get-FmWatcherSupervisionVerdict {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$WatchPath,
        [Parameter(Position = 2)][AllowEmptyString()][string]$Grace = '',
        [string]$FmHome
    )

    if ([string]::IsNullOrEmpty($Grace)) { $Grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300' }
    $graceValue = 300
    if (-not [int]::TryParse($Grace, [ref]$graceValue)) { $graceValue = 300 }

    # `stale-beacon` is the DEFAULT reason, exactly as the bash initialises it:
    # an unreadable or absent beacon is a genuine supervision lapse.
    $ok = $false
    $reason = 'stale-beacon'

    $fresh = $false
    $age = Get-FmPathAge -Path "$State/.last-watcher-beat"
    if ($age -lt $graceValue) { $fresh = $true }

    if ((Get-FmSupervisionModel) -ceq 'autoarm') {
        if ($fresh) { $ok = $true }
        return [pscustomobject]@{ Ok = $ok; Reason = $reason }
    }

    $healthyArgs = @{ State = $State; WatchPath = $WatchPath; Grace = $Grace }
    if ($PSBoundParameters.ContainsKey('FmHome')) { $healthyArgs['FmHome'] = $FmHome }
    if (Test-FmWatcherHealthy @healthyArgs) {
        $ok = $true
    } elseif ($fresh) {
        # A fresh beacon with no live watcher: the beacon is not the failure,
        # the missing watcher is.
        $reason = 'no-watcher'
    }
    return [pscustomobject]@{ Ok = $ok; Reason = $reason }
}

function Test-FmWatcherHealthy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$WatchPath,
        [Parameter(Position = 2)][AllowEmptyString()][string]$Grace,
        [string]$FmHome
    )

    $script:FmWatcherHealthyPid = ''
    if ([string]::IsNullOrEmpty($Grace)) { $Grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300' }
    if (-not $PSBoundParameters.ContainsKey('FmHome')) { $FmHome = $script:FmWakeContext.Home }

    $lockDir = "$State/.watch.lock"
    $beat = "$State/.last-watcher-beat"
    $lockPid = Get-FmWakeText -Path "$lockDir/pid"
    if (-not (Test-FmPidAlive -ProcessId $lockPid)) { return $false }
    $matchArgs = @{ State = $State; WatchPath = $WatchPath; ProcessId = $lockPid; FmHome = $FmHome }
    if (-not (Test-FmWatcherLockMatchesPid @matchArgs)) { return $false }
    $age = Get-FmPathAge -Path $beat
    [long]$graceValue = 0
    # `[ "$age" -lt "$grace" ]` with a non-numeric grace is a bash arithmetic
    # error, which the caller reads as "not healthy" - reproduced, not softened.
    if (-not [long]::TryParse($Grace, [ref]$graceValue)) { return $false }
    if ($age -ge $graceValue) { return $false }
    $script:FmWatcherHealthyPid = $lockPid
    return $true
}

<#
.SYNOPSIS
The pid confirmed by the last successful Test-FmWatcherHealthy call.
#>
function Get-FmWatcherHealthyPid {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmWatcherHealthyPid
}

# --- lock path helpers -------------------------------------------------------

<#
.SYNOPSIS
The directory part of a path, without forking (fm_lock_path_dir).
.DESCRIPTION
Reached on every poll of a held lock, so it stays pure string work. The bash
twin splits on '/' only; a backslash is accepted here as well because a
PowerShell caller may legitimately hold a native lock path, and no POSIX input
changes meaning as a result.
#>
function Get-FmLockPathDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    $idx = $Path.LastIndexOfAny([char[]]@('/', '\'))
    if ($idx -lt 0) { return '.' }
    if ($idx -eq 0) { return $Path.Substring(0, 1) }
    return $Path.Substring(0, $idx)
}

function Get-FmLockPathLeaf {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $idx = $Path.LastIndexOfAny([char[]]@('/', '\'))
    if ($idx -lt 0) { return $Path }
    return $Path.Substring($idx + 1)
}

# Two paths naming one location. The ordinal compare is first and answers every
# same-form case for free; only a genuine cross-form comparison (/tmp/x against
# C:\Users\...\Temp\x, which is what a bash-written token looks like to this
# side) pays the normalization.
function Test-FmLockPathEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )
    if ($Left -ceq $Right) { return $true }
    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) { return $false }
    return (Test-FmSamePath -Left (ConvertTo-FmWakeNative -Path $Left) -Right (ConvertTo-FmWakeNative -Path $Right))
}

# `cd "$dir" 2>/dev/null && pwd -P`, answering in POSIX form, or $null where
# that cd would fail. Both halves are load bearing; see Get-FmLockAbsPath.
function Resolve-FmLockDirPosix {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Dir)

    # A bare drive ("F:") is drive-RELATIVE to .NET, which would resolve against
    # a per-drive current directory nothing here ever set. `cd F:/` is what the
    # caller meant.
    if ($Dir -match '^[A-Za-z]:$') { $Dir = "$Dir/" }

    if ($Dir.StartsWith('/')) {
        $posix = $Dir
    } elseif ([System.IO.Path]::IsPathRooted($Dir)) {
        $posix = ConvertTo-FmPosixPath $Dir
    } else {
        # `cd` on a relative directory resolves against the process's cwd, and
        # `pwd -P` then prints it in POSIX form.
        $posix = (ConvertTo-FmPosixPath (Get-Location).Path).TrimEnd('/') + '/' + ($Dir -replace '\\', '/')
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ($posix -split '/')) {
        if ($part -eq '' -or $part -eq '.') { continue }
        if ($part -eq '..') {
            # bash canonicalizes with PATH_CHECKDOTDOT, so the path BEFORE a
            # '..' has to exist even when the canonical result does: `cd
            # <state>/sub/..` FAILS while <state> is present and `sub` is not
            # (verified against the bash twin on this host). Dropping the check
            # would hand back an owner handle where bash reported a failure.
            if (-not (Test-FmWakeDirectory -Path ('/' + ($segments -join '/')))) { return $null }
            if ($segments.Count -gt 0) { $segments.RemoveAt($segments.Count - 1) }
            continue
        }
        $segments.Add($part)
    }
    $resolved = '/' + ($segments -join '/')
    if (-not (Test-FmWakeDirectory -Path $resolved)) { return $null }
    return $resolved
}

<#
.SYNOPSIS
The absolute POSIX form of a lock path, or $null when the directory is absent.
.DESCRIPTION
The twin of `dir=$(dirname "$p"); base=$(basename "$p"); dir=$(cd "$dir"
2>/dev/null && pwd -P) || return 1; printf '%s/%s'`. Three properties of that
line are reproduced deliberately.

FORM. Under MSYS `pwd -P` prints the POSIX spelling of wherever it landed, so
the bash twin answers `/f/x/state/.watch.lock` even when it was handed
`F:/x/state/.watch.lock` (verified on this host). That matters because this
result becomes the `.fm-lock-owner` TOKEN and the owner directory's own name -
durable records the bash twins keep reading during the transition - and bash's
fm_lock_owner_shape_ok rejects outright any token that does not begin with '/'.
A PowerShell home resolves its state directory natively (`F:\...`, because the
.NET file APIs need that), so returning the caller's own convention published a
native token no bash reader could parse: the lock then read as a legacy
pid-only directory to the other world, which is risk R2 in
docs/powershell-port-inventory.md. So the answer is ALWAYS POSIX
(docs/powershell-port.md contract 3), converted through fm-common's
ConvertTo-FmPosixPath rather than re-derived here.

ONLY THE DIRECTORY IS CANONICALIZED. bash appends the basename verbatim after
resolving the directory, so a lock at the filesystem root answers `//x.lock`
and a lock literally named `..` is not collapsed. Reproduced rather than
tidied.

EXISTENCE. `cd` fails when the directory is not there, which is why a caller
sees a failure instead of a plausible path - see Resolve-FmLockDirPosix for the
'..' rule that comes with it.

Symlinks in the directory chain are not resolved here, where `pwd -P` would
resolve them. On the platform that needs the fallback representation there are
no symlinks to resolve, and on a platform that has them the lock is a symlink
form whose owner handle is published atomically instead.
#>
function Get-FmLockAbsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    # `dirname` / `basename`, which strip trailing separators first: "<x>/state/"
    # splits as "<x>" + "state", not as "<x>/state" + "".
    $trimmed = $Path
    while ($trimmed.Length -gt 1 -and ($trimmed[-1] -eq '/' -or $trimmed[-1] -eq '\')) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }
    $idx = $trimmed.LastIndexOfAny([char[]]@('/', '\'))
    if ($idx -lt 0) {
        $dir = '.'
        $base = $trimmed
    } elseif ($idx -eq 0) {
        $dir = '/'
        $base = $trimmed.Substring(1)
    } else {
        $dir = $trimmed.Substring(0, $idx)
        $base = $trimmed.Substring($idx + 1)
    }
    # `basename /` is `/` in both worlds; nothing else yields an empty base.
    if ($base -eq '') { $base = $trimmed }

    $resolved = Resolve-FmLockDirPosix -Dir $dir
    if ([string]::IsNullOrEmpty($resolved)) { return $null }
    return "$resolved/$base"
}

# --- symlink capability probe ------------------------------------------------
#
# Memoized per DIRECTORY, not per process: the verdict is a property of the
# filesystem the lock sits on, and callers (tests especially) hand this library
# lock paths outside the state dir. Verified rather than assumed from the OS
# name, because the same host answers differently with Developer Mode on.

$script:FmLockSymlinkDir = $null
$script:FmLockSymlinkOk = $false

<#
.SYNOPSIS
True when symlinks genuinely work in the directory holding <LockPath>.
.DESCRIPTION
Probes with a deliberately DANGLING target: where symlinks really link, a
dangling link is still a link and survives the create + read-back round trip;
where the platform cannot make one, the attempt fails outright and leaves no
debris that could later be mistaken for a lock or an owner directory.
#>
function Test-FmLockSymlinksWork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    $target = 'fm-lock-symlink-probe'
    $dir = Get-FmLockPathDir -Path $LockPath
    if ($null -ne $script:FmLockSymlinkDir -and $dir -ceq $script:FmLockSymlinkDir) {
        return $script:FmLockSymlinkOk
    }

    $ok = $false
    $probe = "$dir/.fm-lock-symprobe.$PID.$(Get-Random)"
    if (Test-FmWakePathPresent -Path $probe) { Remove-FmWakeFileQuiet -Path $probe }
    $created = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path (ConvertTo-FmWakeNative -Path $probe) -Value $target -ErrorAction Stop
        $created = $true
    } catch {
        $null = $_
    }
    if ($created) {
        if (Test-FmWakeSymlink -Path $probe) {
            $readBack = ''
            try {
                $item = Get-Item -LiteralPath (ConvertTo-FmWakeNative -Path $probe) -Force -ErrorAction Stop
                if ($null -ne $item.Target) { $readBack = [string]$item.Target }
            } catch {
                $readBack = ''
            }
            if ($readBack -ceq $target) { $ok = $true }
        }
        try { Remove-Item -LiteralPath (ConvertTo-FmWakeNative -Path $probe) -Force -ErrorAction Stop } catch { $null = $_ }
    } elseif (-not (Test-FmWakeDirectory -Path $dir)) {
        # No verdict to cache: nothing can be locked here yet, and memoizing "no
        # symlinks" off a directory that merely does not exist would strand a
        # real symlink host in fallback mode for the rest of its life.
        return $false
    }

    $script:FmLockSymlinkDir = $dir
    $script:FmLockSymlinkOk = $ok
    return $ok
}

# --- owner handles -----------------------------------------------------------

<#
.SYNOPSIS
True when <Candidate> has the exact shape this library writes for an owner dir.
.DESCRIPTION
A fallback lock is a plain directory, so its owner token is ordinary file
content - never trust it as a path unless it looks like something this library
would have written: absolute, in the lock's own directory, and named
"<lockbase>.owner.<random suffix>". Anything else is somebody else's file.

Both absolute forms are accepted, because a token written by the bash twin is
POSIX and a token written here on a host with no POSIX form is native; the bash
twin needs only the POSIX leg and this one needs both.
#>
function Test-FmLockOwnerShapeOk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Candidate
    )

    if ([string]::IsNullOrEmpty($Candidate)) { return $false }
    $absolute = $Candidate.StartsWith('/') -or ($Candidate -match '^[A-Za-z]:[\\/]')
    if (-not $absolute) { return $false }

    $base = Get-FmLockPathLeaf -Path $LockPath
    $prefix = "$base.owner."
    $rest = Get-FmLockPathLeaf -Path $Candidate
    if (-not $rest.StartsWith($prefix, [System.StringComparison]::Ordinal)) { return $false }
    if ($rest.Length -le $prefix.Length) { return $false }

    $candidateDir = Get-FmLockPathDir -Path $Candidate
    $lockDir = Get-FmLockPathDir -Path $LockPath
    if (Test-FmLockPathEqual -Left $candidateDir -Right $lockDir) { return $true }
    # The token was written from the resolved directory, so a caller that passed
    # a relative or unresolved lock path still matches - just not for free.
    $abs = Get-FmLockAbsPath -Path $LockPath
    if ([string]::IsNullOrEmpty($abs)) { return $false }
    return (Test-FmLockPathEqual -Left $candidateDir -Right (Get-FmLockPathDir -Path $abs))
}

<#
.SYNOPSIS
The owner handle a FALLBACK lock names, or $null when this path is not one.
.DESCRIPTION
Returns $null for a legacy pid-only directory lock, a symlink, or nothing at
all - all three are "not a fallback lock", and the callers branch on that.
#>
function Get-FmLockFallbackOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    if (-not (Test-FmWakeDirectory -Path $LockPath)) { return $null }
    if (Test-FmWakeSymlink -Path $LockPath) { return $null }
    $token = Get-FmWakeLine -Path "$LockPath/$($script:FmWakeOwnerTokenFile)"
    if ([string]::IsNullOrEmpty($token)) { return $null }
    if (-not (Test-FmLockOwnerShapeOk -LockPath $LockPath -Candidate $token)) { return $null }
    return $token
}

<#
.SYNOPSIS
Remove every filename this library ever writes inside a lock or owner directory.
.DESCRIPTION
Keeps a lock directory removable through the normal paths, which is what makes
the never-`rm -rf` rule affordable.
#>
function Clear-FmLockKnownFile {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    foreach ($name in @('pid', 'fm-home', 'pid-identity', 'watcher-path', $script:FmWakeOwnerTokenFile)) {
        Remove-FmWakeFileQuiet -Path "$Path/$name"
    }
}

<#
.SYNOPSIS
Tear down a fallback lock directory, pid file FIRST.
.DESCRIPTION
Removing the owner token while the holder pid survives leaves the one shape
nothing in this protocol can ever reclaim: a directory that reads as a legacy
lock held by a live process, so the liveness check answers "held" forever. If
the pid will not go - Windows can refuse a delete another process holds open -
the lock is left whole and still attributed to its holder, and the failure reads
as "still held, retry", which resolves by itself once that holder exits.
#>
function Remove-FmLockDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A lock-protocol primitive whose bash twin removes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher mid-protocol.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    Remove-FmWakeFileQuiet -Path "$LockPath/pid"
    if (Test-FmWakePathPresent -Path "$LockPath/pid") { return $false }
    Clear-FmLockKnownFile -Path $LockPath
    try {
        [System.IO.Directory]::Delete((ConvertTo-FmWakeNative -Path $LockPath), $false)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
True when <Pid> holds <LockPath> in a way this process must respect.
.DESCRIPTION
A lock recording our OWN pid cannot: the protocol never re-enters an acquire
for a lock this process already holds, so our own pid in a lock we are trying to
take is a leftover from an earlier iteration of ours that a torn removal could
not finish. Treating it as a live holder is a self-deadlock - the acquire loop
waits on itself for the life of the process, which is exactly how a wedged wake
queue stops forever instead of retrying. Fallback mode only: a symlinked lock
has no half-published state that can strand our pid.
#>
function Test-FmLockHolderIsLive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ProcessId
    )

    if (-not (Test-FmPidAlive -ProcessId $ProcessId)) { return $false }
    if ($ProcessId -ne [string]$PID) { return $true }
    return (Test-FmLockSymlinksWork -LockPath $LockPath)
}

<#
.SYNOPSIS
Create a fresh, uniquely named owner directory for <LockPath>.
.DESCRIPTION
The `mktemp -d "${lock_abs}.owner.XXXXXX"` twin, including the six-character
suffix from mktemp's own alphabet, so a bash reader sees the shape it expects.
Created exclusively rather than idempotently: two processes sharing one owner
handle would make the ownership proof meaningless.
#>
function New-FmLockOwnerDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The mktemp -d twin inside a lock protocol; its bash twin creates unconditionally and a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    $abs = Get-FmLockAbsPath -Path $LockPath
    if ([string]::IsNullOrEmpty($abs)) { return $null }
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    for ($attempt = 0; $attempt -lt 32; $attempt++) {
        $suffix = -join (1..6 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
        $candidate = "$abs.owner.$suffix"
        if (New-FmWakeExclusiveDirectory -Path $candidate) { return $candidate }
    }
    return $null
}

<#
.SYNOPSIS
Record this process's pid inside a freshly made owner directory.
#>
function Initialize-FmLockOwner {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$OwnerDir)

    try {
        Set-FmFileText -Path (ConvertTo-FmWakeNative -Path "$OwnerDir/pid") -Text ([string]$PID)
    } catch {
        return $false
    }
    return ((Get-FmWakeText -Path "$OwnerDir/pid") -eq [string]$PID)
}

<#
.SYNOPSIS
Delete an owner directory this process created and no longer needs.
#>
function Remove-FmLockOwner {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A lock-protocol primitive whose bash twin removes unconditionally; a confirmation surface would diverge from the twin and could strand an owner directory.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$OwnerDir)

    if ([string]::IsNullOrEmpty($OwnerDir)) { return }
    Clear-FmLockKnownFile -Path $OwnerDir
    try { [System.IO.Directory]::Delete((ConvertTo-FmWakeNative -Path $OwnerDir), $false) } catch { $null = $_ }
}

<#
.SYNOPSIS
The owner handle a published lock names, in whichever representation is in use.
.DESCRIPTION
Symlink first, always: where symlinks work this is the readlink path unchanged,
so nothing about macOS/Linux behavior moves.
#>
function Get-FmLockLinkOwner {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    if (Test-FmWakeSymlink -Path $LockPath) {
        $target = $null
        try {
            $item = Get-Item -LiteralPath (ConvertTo-FmWakeNative -Path $LockPath) -Force -ErrorAction Stop
            if ($null -ne $item.Target) { $target = [string]$item.Target }
        } catch {
            return $null
        }
        if ([string]::IsNullOrEmpty($target)) { return $null }
        if ($target.StartsWith('/') -or ($target -match '^[A-Za-z]:[\\/]')) { return $target }
        return (Get-FmLockPathDir -Path $LockPath) + '/' + $target
    }
    if (Test-FmLockSymlinksWork -LockPath $LockPath) { return $null }
    return (Get-FmLockFallbackOwner -LockPath $LockPath)
}

<#
.SYNOPSIS
True when <LockPath> currently names <OwnerDir> as its holder.
#>
function Test-FmLockPointsToOwner {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$OwnerDir
    )

    if (Test-FmWakeSymlink -Path $LockPath) {
        $target = $null
        try {
            $item = Get-Item -LiteralPath (ConvertTo-FmWakeNative -Path $LockPath) -Force -ErrorAction Stop
            if ($null -ne $item.Target) { $target = [string]$item.Target }
        } catch {
            return $false
        }
        if ([string]::IsNullOrEmpty($target)) { return $false }
        return (Test-FmLockPathEqual -Left $target -Right $OwnerDir)
    }
    if (Test-FmLockSymlinksWork -LockPath $LockPath) { return $false }
    $owner = Get-FmLockFallbackOwner -LockPath $LockPath
    if ([string]::IsNullOrEmpty($owner)) { return $false }
    return (Test-FmLockPathEqual -Left $owner -Right $OwnerDir)
}

<#
.SYNOPSIS
Publish <OwnerDir> at <LockPath>, atomically, losing to whoever got there first.
.DESCRIPTION
In fallback mode the write order is load bearing. A publication torn between
the two writes must never leave a pid without a token: that is the
unreclaimable shape Remove-FmLockDir describes. Torn the other way it is a
tokened lock that has not named its holder yet - an ordinary mid-acquire, which
the freshness window already covers and the stale path reclaims one grace period
later.
#>
function Publish-FmLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$OwnerDir
    )

    if (Test-FmLockSymlinksWork -LockPath $LockPath) {
        try {
            $value = if (Test-FmWindows) { ConvertTo-FmWakeNative -Path $OwnerDir } else { $OwnerDir }
            $null = New-Item -ItemType SymbolicLink -Path (ConvertTo-FmWakeNative -Path $LockPath) -Value $value -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }

    if (-not (New-FmWakeExclusiveDirectory -Path $LockPath)) { return $false }

    try {
        Set-FmFileText -Path (ConvertTo-FmWakeNative -Path "$LockPath/$($script:FmWakeOwnerTokenFile)") -Text $OwnerDir
    } catch {
        $null = Remove-FmLockDir -LockPath $LockPath
        return $false
    }
    # Mirroring the prepared owner's pid is what makes a fallback lock
    # self-describing the way a symlinked one is: a contender that loses the
    # gate can name the holder instead of reporting an anonymous mid-acquire.
    $ownerPid = Get-FmWakeLine -Path "$OwnerDir/pid"
    if (-not [string]::IsNullOrEmpty($ownerPid)) {
        try {
            Set-FmFileText -Path (ConvertTo-FmWakeNative -Path "$LockPath/pid") -Text $ownerPid
        } catch {
            $null = Remove-FmLockDir -LockPath $LockPath
            return $false
        }
    }
    return $true
}

# `rm -f` on a symlink removes the LINK. On Windows a directory symlink is a
# directory reparse point, which File::Delete refuses and Directory::Delete
# removes without touching the target.
function Remove-FmLinkPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A private `rm -f <symlink>` twin inside the lock protocol; its bash twin removes unconditionally and a confirmation surface would diverge from the twin mid-release.')]
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmWakeNative -Path $Path
    try {
        [System.IO.File]::Delete($native)
        return $true
    } catch {
        $null = $_
    }
    try {
        [System.IO.Directory]::Delete($native, $false)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Withdraw a lock this process published, and only while it still names <OwnerDir>.
.DESCRIPTION
A failure here has to read as "still held, retry next poll", never as a crash
and never as a silent takeover.
#>
function Unpublish-FmLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$OwnerDir
    )

    if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $OwnerDir)) { return $false }
    if (Test-FmWakeSymlink -Path $LockPath) { return (Remove-FmLinkPath -Path $LockPath) }
    return (Remove-FmLockDir -LockPath $LockPath)
}

<#
.SYNOPSIS
Record the claiming pid where readers of this lock will look for it.
.DESCRIPTION
Under a symlink the lock IS the owner directory, so writing $ownerdir/pid
publishes through the lock in one step. In fallback mode they are two
directories and the lock's own pid file is the one every consumer reads, so the
claim has to write there - carefully. It must refuse to write into a lock that
is no longer ours, and never replace a pid already recorded there: a claimant
that stalled past the mid-acquire grace can find its lock reclaimed and
recreated, and overwriting the new holder's pid would hand the lock to a process
that does not hold it. The exclusive create makes the write itself the check -
it can create the pid file, never clobber one.
#>
function Write-FmLockClaimPid {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$OwnerDir,
        [Parameter(Mandatory, Position = 2)][string]$ClaimPid
    )

    if ((Test-FmWakeSymlink -Path $LockPath) -or (Test-FmLockSymlinksWork -LockPath $LockPath)) {
        try {
            Set-FmFileText -Path (ConvertTo-FmWakeNative -Path "$OwnerDir/pid") -Text $ClaimPid
            return $true
        } catch {
            return $false
        }
    }

    if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $OwnerDir)) { return $false }

    $created = $false
    try {
        $native = ConvertTo-FmWakeNative -Path "$LockPath/pid"
        $stream = [System.IO.File]::Open($native, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("$ClaimPid`n")
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
        $created = $true
    } catch [System.IO.IOException] {
        # Precisely the "somebody already recorded a pid" signal, and nothing
        # else: any other failure class falls through to the generic catch.
        $created = $false
    } catch {
        $created = $false
    }

    if ($created) {
        # Exclusive create succeeding means WE made that pid file, so we are
        # free to withdraw it - and must, if the lock stopped being ours between
        # the check above and the write. A reclaim that removed the token but
        # could not finish its removal leaves an orphaned directory here, and
        # dropping our live pid into it would manufacture the unreclaimable
        # shape out of a race we already lost.
        if (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $OwnerDir) { return $true }
        Remove-FmWakeFileQuiet -Path "$LockPath/pid"
        return $false
    }

    # Publication already mirrored our own prepared pid into the lock; any other
    # value belongs to another claimant and is not ours to take over.
    return ((Get-FmWakeLine -Path "$LockPath/pid") -eq $ClaimPid)
}

<#
.SYNOPSIS
Remove copy-mode debris left inside a lock directory by a losing publish.
.DESCRIPTION
Where `ln -s` copies, aiming it at an existing lock directory copies the owner
directory INTO it recursively, leaving $lockdir/<owner basename> with a pid file
in it. This library stops taking that path once the probe says so, but a
concurrent process still running the old path can leave the shape behind. Only
this attempt could own that name, so removing it cannot touch another holder's
state, and clearing known filenames plus an empty-directory delete keeps the
never-recursive-delete rule intact.
#>
function Remove-FmLockStrayOwner {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Debris cleanup inside a lock protocol whose bash twin removes unconditionally; a confirmation surface would diverge from the twin.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$OwnerDir
    )

    $stray = "$LockPath/$(Get-FmLockPathLeaf -Path $OwnerDir)"
    if (Test-FmWakeSymlink -Path $stray) {
        $target = ''
        try {
            $item = Get-Item -LiteralPath (ConvertTo-FmWakeNative -Path $stray) -Force -ErrorAction Stop
            if ($null -ne $item.Target) { $target = [string]$item.Target }
        } catch {
            $target = ''
        }
        if (Test-FmLockPathEqual -Left $target -Right $OwnerDir) {
            $null = Remove-FmLinkPath -Path $stray
            return
        }
    }
    if (-not (Test-FmLockSymlinksWork -LockPath $LockPath) -and
        (Test-FmWakeDirectory -Path $stray) -and -not (Test-FmWakeSymlink -Path $stray)) {
        Clear-FmLockKnownFile -Path $stray
        try { [System.IO.Directory]::Delete((ConvertTo-FmWakeNative -Path $stray), $false) } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
True when an active steal mutex forbids this claim.
.DESCRIPTION
Representation-agnostic: presence covers a symlink steal lock and a fallback
steal directory alike, and the owner comparison goes through the generalized
Test-FmLockPointsToOwner.
#>
function Test-FmLockClaimBlockedBySteal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$AllowedStealOwner
    )

    $steal = "$LockPath.steal"
    if (-not (Test-FmWakePathPresent -Path $steal)) { return $false }
    if (-not [string]::IsNullOrEmpty($AllowedStealOwner) -and
        (Test-FmLockPointsToOwner -LockPath $steal -OwnerDir $AllowedStealOwner)) {
        return $false
    }
    return $true
}

# --- acquire / release -------------------------------------------------------

$script:FmLockOwnerDir = ''
$script:FmLockHeldPid = ''

<#
.SYNOPSIS
The owner directory of the lock the last successful acquire took.
#>
function Get-FmLockOwnerDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmLockOwnerDir
}

<#
.SYNOPSIS
The holder pid reported by the last refused acquire.
#>
function Get-FmLockHeldPid {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmLockHeldPid
}

<#
.SYNOPSIS
Finish taking a lock this process just published, or back out cleanly.
#>
function Invoke-FmLockClaim {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$OwnerDir,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$AllowedStealOwner
    )

    $myPid = [string]$PID
    if (-not (Write-FmLockClaimPid -LockPath $LockPath -OwnerDir $OwnerDir -ClaimPid $myPid)) {
        Remove-FmLockOwner -OwnerDir $OwnerDir
        return $false
    }
    $back = if ((Test-FmWakeSymlink -Path $LockPath) -or (Test-FmLockSymlinksWork -LockPath $LockPath)) {
        Get-FmWakeText -Path "$OwnerDir/pid"
    } else {
        Get-FmWakeText -Path "$LockPath/pid"
    }
    if ($back -ne $myPid) {
        Remove-FmLockOwner -OwnerDir $OwnerDir
        return $false
    }
    if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $OwnerDir)) {
        Remove-FmLockOwner -OwnerDir $OwnerDir
        return $false
    }
    if (Test-FmLockClaimBlockedBySteal -LockPath $LockPath -AllowedStealOwner $AllowedStealOwner) {
        $null = Unpublish-FmLock -LockPath $LockPath -OwnerDir $OwnerDir
        Remove-FmLockOwner -OwnerDir $OwnerDir
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Create and take <LockPath> when it is genuinely free (fm_lock_try_create).
.DESCRIPTION
Get-FmLockOwnerDir returns the owner handle afterwards on success, and an empty
string on failure, mirroring the bash twin's FM_LOCK_OWNER_DIR.
#>
function New-FmLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The lock-acquire primitive itself; its bash twin takes the lock unconditionally and a -WhatIf/-Confirm surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$AllowedStealOwner
    )

    $script:FmLockOwnerDir = ''
    $ownerDir = New-FmLockOwnerDir -LockPath $LockPath
    if ([string]::IsNullOrEmpty($ownerDir)) { return $false }
    if (Test-FmWakePathPresent -Path $LockPath) {
        Remove-FmLockOwner -OwnerDir $ownerDir
        return $false
    }
    if (-not (Initialize-FmLockOwner -OwnerDir $ownerDir)) {
        Remove-FmLockOwner -OwnerDir $ownerDir
        return $false
    }
    if ((Publish-FmLock -LockPath $LockPath -OwnerDir $ownerDir) -and
        (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $ownerDir)) {
        if (Invoke-FmLockClaim -LockPath $LockPath -OwnerDir $ownerDir -AllowedStealOwner $AllowedStealOwner) {
            $script:FmLockOwnerDir = $ownerDir
            return $true
        }
        $null = Unpublish-FmLock -LockPath $LockPath -OwnerDir $ownerDir
    } else {
        Remove-FmLockStrayOwner -LockPath $LockPath -OwnerDir $ownerDir
    }
    Remove-FmLockOwner -OwnerDir $ownerDir
    return $false
}

<#
.SYNOPSIS
Remove a lock path in whichever representation it uses, owner handle included.
.DESCRIPTION
A fallback lock is a directory too, so its owner handle is read BEFORE the
directory goes away - otherwise the owner directory behind it leaks. A legacy
pid-only directory lock yields nothing here and takes the original path.
#>
function Remove-FmLockPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A lock-protocol primitive whose bash twin removes unconditionally; a confirmation surface would diverge from the twin mid-steal.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    if (Test-FmWakeSymlink -Path $LockPath) {
        $ownerDir = Get-FmLockLinkOwner -LockPath $LockPath
        if (-not (Remove-FmLinkPath -Path $LockPath)) { return $false }
        if (-not [string]::IsNullOrEmpty($ownerDir)) { Remove-FmLockOwner -OwnerDir $ownerDir }
        return $true
    }
    if (-not (Test-FmLockSymlinksWork -LockPath $LockPath)) {
        $ownerDir = Get-FmLockFallbackOwner -LockPath $LockPath
        if (-not [string]::IsNullOrEmpty($ownerDir)) {
            if (-not (Remove-FmLockDir -LockPath $LockPath)) { return $false }
            Remove-FmLockOwner -OwnerDir $ownerDir
            return $true
        }
    }
    Clear-FmLockKnownFile -Path $LockPath
    try {
        [System.IO.Directory]::Delete((ConvertTo-FmWakeNative -Path $LockPath), $false)
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
True while an anonymous mid-acquire lock is still inside its minimum grace.
.DESCRIPTION
Only a lock that names NO pid can be mid-acquire; one that names a pid is
answered by the liveness check instead. The two-second floor is what covers the
fallback representation's publish window, so a caller cannot configure it away
with FM_LOCK_STALE_AFTER=0.
#>
function Test-FmLockMidAcquireIsFresh {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ProcessId
    )

    if (-not [string]::IsNullOrEmpty($ProcessId) -and $ProcessId -match '^[0-9]+$') { return $false }
    [long]$stale = 0
    # A non-numeric FM_LOCK_STALE_AFTER makes the bash comparison an arithmetic
    # error the caller reads as "not fresh"; reproduced rather than softened.
    if (-not [long]::TryParse($script:FmWakeContext.StaleAfter, [ref]$stale)) { return $false }
    if ($stale -lt 2) { $stale = 2 }
    return ((Get-FmPathAge -Path $LockPath) -lt $stale)
}

<#
.SYNOPSIS
True when the lock is provably the same stale instance the caller measured.
#>
function Test-FmLockStaleOwner {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ExpectedOwner,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedPid
    )

    if (-not [string]::IsNullOrEmpty($ExpectedOwner)) {
        if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $ExpectedOwner)) { return $false }
    } elseif (Test-FmWakePathPresent -Path $LockPath) {
        if (-not (Test-FmWakeDirectory -Path $LockPath) -or (Test-FmWakeSymlink -Path $LockPath)) { return $false }
        # A fallback lock is a directory as well, so this legacy branch must not
        # swallow one. Reaching here with no expected owner means the caller read
        # the lock before any token existed; if a token is there now, the lock
        # was published underneath us and is not a stale legacy directory.
        if (-not (Test-FmLockSymlinksWork -LockPath $LockPath)) {
            if (-not [string]::IsNullOrEmpty((Get-FmLockFallbackOwner -LockPath $LockPath))) { return $false }
        }
    }
    $actualPid = Get-FmWakeText -Path "$LockPath/pid"
    if ($actualPid -ne $ExpectedPid) { return $false }
    if (Test-FmLockHolderIsLive -LockPath $LockPath -ProcessId $actualPid) { return $false }
    if (Test-FmLockMidAcquireIsFresh -LockPath $LockPath -ProcessId $actualPid) { return $false }
    return $true
}

<#
.SYNOPSIS
Try once to take <LockPath>, reclaiming it only when provably abandoned.
.DESCRIPTION
The full protocol: take it outright when free; refuse while a live holder or a
fresh mid-acquire owns it; otherwise take the `.steal` mutex, re-verify
everything under it, remove the abandoned lock and recreate it. Every refusal
records the holder pid, readable through Get-FmLockHeldPid, and every success
records the owner handle, readable through Get-FmLockOwnerDir.
#>
function Request-FmLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    $script:FmLockHeldPid = ''
    $script:FmLockOwnerDir = ''

    if (New-FmLock -LockPath $LockPath) { return $true }

    $holder = Get-FmWakeText -Path "$LockPath/pid"
    if (Test-FmLockHolderIsLive -LockPath $LockPath -ProcessId $holder) {
        $script:FmLockHeldPid = $holder
        return $false
    }
    if (Test-FmLockMidAcquireIsFresh -LockPath $LockPath -ProcessId $holder) {
        $script:FmLockHeldPid = $holder
        return $false
    }

    $steal = "$LockPath.steal"
    if (-not (Request-FmLock -LockPath $steal)) {
        $script:FmLockHeldPid = Get-FmWakeText -Path "$LockPath/pid"
        $script:FmLockOwnerDir = ''
        return $false
    }
    $stealOwner = $script:FmLockOwnerDir

    $current = Get-FmWakeText -Path "$LockPath/pid"
    if (Test-FmLockHolderIsLive -LockPath $LockPath -ProcessId $current) {
        Unlock-FmLock -LockPath $steal
        $script:FmLockHeldPid = $current
        $script:FmLockOwnerDir = ''
        return $false
    }
    if (Test-FmLockMidAcquireIsFresh -LockPath $LockPath -ProcessId $current) {
        Unlock-FmLock -LockPath $steal
        $script:FmLockHeldPid = $current
        $script:FmLockOwnerDir = ''
        return $false
    }
    if (-not (Test-FmLockPointsToOwner -LockPath $steal -OwnerDir $stealOwner)) {
        Unlock-FmLock -LockPath $steal
        $script:FmLockHeldPid = Get-FmWakeText -Path "$LockPath/pid"
        $script:FmLockOwnerDir = ''
        return $false
    }

    $primaryOwner = ''
    if ((Test-FmWakeSymlink -Path $LockPath) -or -not (Test-FmLockSymlinksWork -LockPath $LockPath)) {
        $primaryOwner = Get-FmLockLinkOwner -LockPath $LockPath
        if ($null -eq $primaryOwner) { $primaryOwner = '' }
    }
    $current = Get-FmWakeText -Path "$LockPath/pid"
    if (-not (Test-FmLockStaleOwner -LockPath $LockPath -ExpectedOwner $primaryOwner -ExpectedPid $current)) {
        Unlock-FmLock -LockPath $steal
        $script:FmLockHeldPid = Get-FmWakeText -Path "$LockPath/pid"
        $script:FmLockOwnerDir = ''
        return $false
    }

    $null = Remove-FmLockPath -LockPath $LockPath
    $acquired = New-FmLock -LockPath $LockPath -AllowedStealOwner $stealOwner
    if (-not $acquired) {
        $script:FmLockHeldPid = Get-FmWakeText -Path "$LockPath/pid"
        $script:FmLockOwnerDir = ''
    }
    Unlock-FmLock -LockPath $steal
    return $acquired
}

<#
.SYNOPSIS
Block until <LockPath> is taken (fm_lock_acquire_wait).
#>
function Wait-FmLock {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    while (-not (Request-FmLock -LockPath $LockPath)) {
        Start-Sleep -Milliseconds 100
    }
}

<#
.SYNOPSIS
Release a lock this process holds, in whichever representation it uses.
.DESCRIPTION
Same sequence in both branches - owner handle, then holder pid, then a
re-verification that the lock is still the instance we published - because
between those reads it could have been reclaimed. Without a token the path is a
plain legacy directory lock and falls through unchanged. A teardown Windows
refuses leaves the lock held rather than half-released: it then reads as held by
this process until this process exits, which is the truth, and the ordinary
stale path reclaims it after that.
#>
function Unlock-FmLock {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    $current = [string]$PID

    if (Test-FmWakeSymlink -Path $LockPath) {
        $ownerDir = Get-FmLockLinkOwner -LockPath $LockPath
        if ([string]::IsNullOrEmpty($ownerDir)) { return }
        if ((Get-FmWakeText -Path "$ownerDir/pid") -ne $current) { return }
        if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $ownerDir)) { return }
        if (-not (Remove-FmLinkPath -Path $LockPath)) { return }
        Remove-FmLockOwner -OwnerDir $ownerDir
        return
    }

    if (-not (Test-FmLockSymlinksWork -LockPath $LockPath)) {
        $ownerDir = Get-FmLockFallbackOwner -LockPath $LockPath
        if (-not [string]::IsNullOrEmpty($ownerDir)) {
            if ((Get-FmWakeText -Path "$LockPath/pid") -ne $current) { return }
            if (-not (Test-FmLockPointsToOwner -LockPath $LockPath -OwnerDir $ownerDir)) { return }
            if (-not (Remove-FmLockDir -LockPath $LockPath)) { return }
            Remove-FmLockOwner -OwnerDir $ownerDir
            return
        }
    }

    if ((Get-FmWakeText -Path "$LockPath/pid") -ne $current) { return }
    Clear-FmLockKnownFile -Path $LockPath
    try { [System.IO.Directory]::Delete((ConvertTo-FmWakeNative -Path $LockPath), $false) } catch { $null = $_ }
}

# --- wake queue --------------------------------------------------------------

<#
.SYNOPSIS
Flatten a wake field so it cannot break the TAB record (fm_wake_clean_field).
.DESCRIPTION
TAB, CR and LF each become one space. Nothing else is touched, and the length
is preserved, so the record stays exactly five TAB-separated fields.
#>
function ConvertTo-FmWakeField {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text -replace "[`t`r`n]", ' ')
}

<#
.SYNOPSIS
Append one durable wake record. Returns 0 on success, 2 for an invalid kind.
.DESCRIPTION
The record is `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`, written under the
queue lock so the sequence number and the append stay ordered together. The
integer return is the bash twin's exit status, kept as an integer because
callers branch on 2 (invalid kind) separately from a write failure.

The diagnostic text stays `fm_wake_append: ...` verbatim: it is an observable
contract that the differential harness compares, not a name to translate.
#>
function Add-FmWake {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Kind,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Key,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Payload
    )

    if ($Kind -cnotin @('signal', 'stale', 'check', 'heartbeat')) {
        Write-FmErr "fm_wake_append: invalid wake kind: $Kind"
        return 2
    }

    $cleanKey = ConvertTo-FmWakeField -Text $Key
    $cleanPayload = ConvertTo-FmWakeField -Text $Payload
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $seqFile = "$($script:FmWakeContext.State)/.wake-queue.seq"
    $status = 0

    Wait-FmLock -LockPath $script:FmWakeContext.QueueLock
    try {
        $seqText = Get-FmWakeText -Path $seqFile
        [long]$seq = 0
        if ($seqText -notmatch '^[0-9]+$' -or -not [long]::TryParse($seqText, [ref]$seq)) { $seq = 0 }
        $seq = $seq + 1
        try {
            Set-FmFileText -Path (ConvertTo-FmWakeNative -Path $seqFile) -Text ([string]$seq)
        } catch {
            $status = 1
        }
        if ($status -eq 0) {
            try {
                $record = "$epoch`t$seq`t$Kind`t$cleanKey`t$cleanPayload"
                Add-FmFileLine -Path (ConvertTo-FmWakeNative -Path $script:FmWakeContext.Queue) -Line $record
            } catch {
                $status = 1
            }
        }
    } finally {
        Unlock-FmLock -LockPath $script:FmWakeContext.QueueLock
    }
    return $status
}

<#
.SYNOPSIS
Put a drained queue file back in front of whatever arrived meanwhile.
.DESCRIPTION
Ordering is the whole point: the restored rows go BEFORE the concurrent
arrivals, so an interrupted drain replays in the order the wakes were queued.
#>
function Restore-FmWakeQueue {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$DrainedPath)

    $queue = $script:FmWakeContext.Queue
    $restore = "$($script:FmWakeContext.State)/.wake-queue.restore.$PID"
    $nativeDrained = ConvertTo-FmWakeNative -Path $DrainedPath
    $nativeQueue = ConvertTo-FmWakeNative -Path $queue
    $nativeRestore = ConvertTo-FmWakeNative -Path $restore
    try {
        if (Test-FmWakePathPresent -Path $queue) {
            $head = if ([System.IO.File]::Exists($nativeDrained)) { [System.IO.File]::ReadAllBytes($nativeDrained) } else { [byte[]]::new(0) }
            $tail = if ([System.IO.File]::Exists($nativeQueue)) { [System.IO.File]::ReadAllBytes($nativeQueue) } else { [byte[]]::new(0) }
            $joined = [byte[]]::new($head.Length + $tail.Length)
            [System.Array]::Copy($head, 0, $joined, 0, $head.Length)
            [System.Array]::Copy($tail, 0, $joined, $head.Length, $tail.Length)
            [System.IO.File]::WriteAllBytes($nativeRestore, $joined)
            [System.IO.File]::Move($nativeRestore, $nativeQueue, $true)
        } else {
            [System.IO.File]::Move($nativeDrained, $nativeQueue, $true)
        }
        return $true
    } catch {
        return $false
    }
}

# Split file text into records exactly as awk does: on LF only, with no phantom
# record after a trailing newline, and a final unterminated line still counting.
function Split-FmWakeRecord {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -eq '') { return @() }
    $lines = $Text -split "`n"
    if ($lines.Length -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Length - 2)] }
    return @($lines)
}

<#
.SYNOPSIS
The deduped raw rows of a drained queue file, in first-seen order.
.DESCRIPTION
Rows with fewer than five TAB-separated fields are dropped, exactly as the awk
twin's `NF >= 5` guard drops them. Splitting is `.Split("`t")` on the raw string
and a COUNT check, never a regex split, because EMPTY MIDDLE FIELDS ARE
MEANINGFUL here: `epoch<TAB>seq<TAB>signal<TAB><TAB>payload` is a five-field
record with an empty key, and a splitter that collapsed it would silently
reclassify the row.

Deduplication keeps the FIRST occurrence's position and the LAST occurrence's
content, so a repeated signal keeps its place in the queue while carrying the
newest payload. Every heartbeat collapses onto one key regardless of its own
key and payload. The composite key uses awk's own SUBSEP (U+001C) so a payload
containing that byte collides identically in both worlds.
#>
function Get-FmWakeDeduped {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmWakeNative -Path $Path
    if (-not [System.IO.File]::Exists($native)) { return @() }
    try {
        $text = [System.IO.File]::ReadAllText($native)
    } catch {
        return @()
    }

    $subsep = [string][char]28
    $order = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $line = @{}
    foreach ($record in (Split-FmWakeRecord -Text $text)) {
        $fields = $record.Split("`t")
        if ($fields.Count -lt 5) { continue }
        $kind = $fields[2]
        $dedupe = if ($kind -ceq 'heartbeat') { 'heartbeat' } else { $kind + $subsep + $fields[3] }
        if ($seen.Add($dedupe)) { $order.Add($dedupe) }
        $line[$dedupe] = $record
    }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $order) { $out.Add([string]$line[$key]) }
    return @($out)
}

<#
.SYNOPSIS
Print the deduped raw rows of a drained queue file, LF-terminated.
#>
function Write-FmWakeDeduped {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    foreach ($row in (Get-FmWakeDeduped -Path $Path)) { Write-FmOut $row }
}

<#
.SYNOPSIS
Map one structurally valid signal key to its home-local status filename.
.DESCRIPTION
Returns @{ Key = '<id>.status'; Historical = $bool } or $null. Queue payload
text is intentionally ignored: it is display data, not a path authority, and the
caller still verifies the resulting regular file immediately before its bounded
read. A `.turn-ended` key maps to the same status file but is marked historical,
because the turn-end event is not necessarily the event that triggered the wake.
#>
function Get-FmWakeStatusKeyMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Key)

    if ([string]::IsNullOrEmpty($Key)) { return $null }
    $historical = $false
    $id = $null
    if ($Key.EndsWith('.status', [System.StringComparison]::Ordinal)) {
        $id = $Key.Substring(0, $Key.Length - '.status'.Length)
    } elseif ($Key.EndsWith('.turn-ended', [System.StringComparison]::Ordinal)) {
        $id = $Key.Substring(0, $Key.Length - '.turn-ended'.Length)
        $historical = $true
    } else {
        return $null
    }
    if ([string]::IsNullOrEmpty($id)) { return $null }
    if ($id.StartsWith('.')) { return $null }
    if ($id -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    if ($id.Length -gt 64) { return $null }
    return @{ Key = "$id.status"; Historical = $historical }
}

<#
.SYNOPSIS
The "<status file><TAB>direct|historical" manifest for a set of raw rows.
.DESCRIPTION
Field extraction here reproduces a bash SUBTLETY rather than the idealised
record: the twin parses these rows with `IFS=<TAB> read -r epoch seq kind key
payload`, and TAB is IFS WHITESPACE, so bash COLLAPSES runs of tabs and drops
empty fields (verified). A row with an empty key therefore shifts its payload
into the key position in both worlds, and the resulting key simply fails the
status-key mapping. Splitting-then-dropping-empties is that behavior exactly.

This is deliberately NOT the parser Get-FmWakeDeduped uses: the raw rows are
authoritative and keep their empty fields, while this best-effort annotation
pass inherits the twin's looser read.
#>
function Get-FmWakeAnnotationManifest {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Rows)

    $out = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Rows)) { return @($out) }
    foreach ($record in (Split-FmWakeRecord -Text $Rows)) {
        $tokens = @($record.Split("`t") | Where-Object { $_ -ne '' })
        if ($tokens.Count -lt 4) { continue }
        if ($tokens[2] -cne 'signal') { continue }
        $mapped = Get-FmWakeStatusKeyMap -Key $tokens[3]
        if ($null -eq $mapped) { continue }
        $mode = if ($mapped.Historical) { 'historical' } else { 'direct' }
        $out.Add("$($mapped.Key)`t$mode")
    }
    return @($out)
}

<#
.SYNOPSIS
The latest wake EVENT line in a validated status file, bounded by <TailBytes>.
.DESCRIPTION
Returns @{ Line = '<event>'; Truncated = $bool } or $null. Only the last
non-blank line of the bounded tail is returned, with TAB and CR flattened to
spaces so one annotation stays one line. Truncated is true only when the file
was larger than the cap AND the surviving line is the first line of the tail,
i.e. the line itself was cut.

The bash twin opens with O_NOFOLLOW so a status path swapped for a symlink
cannot be followed. .NET rejects FILE_FLAG_OPEN_REPARSE_POINT on a FileStream
(verified), so the reparse check runs immediately before AND after the open,
which narrows that race rather than closing it - stated here rather than
papered over. Everything else the twin refuses is refused identically: a
missing path, a directory, an unreadable file, and an empty result.
#>
function Get-FmWakeLatestEvent {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][int]$TailBytes
    )

    $native = ConvertTo-FmWakeNative -Path $Path
    if (Test-FmWakeSymlink -Path $Path) { return $null }
    if (-not [System.IO.File]::Exists($native)) { return $null }

    $bytes = $null
    $size = 0L
    try {
        $stream = [System.IO.File]::Open($native, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $size = $stream.Length
            $start = if ($size -gt $TailBytes) { $size - $TailBytes } else { 0 }
            [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
            $remaining = [int]($size - $start)
            $bytes = [byte[]]::new($remaining)
            $read = 0
            while ($read -lt $remaining) {
                $n = $stream.Read($bytes, $read, $remaining - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            if ($read -lt $remaining) { $bytes = $bytes[0..([Math]::Max($read - 1, 0))] }
            if ($read -eq 0) { $bytes = [byte[]]::new(0) }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }
    if (Test-FmWakeSymlink -Path $Path) { return $null }

    $chunk = ([System.Text.Encoding]::UTF8.GetString($bytes)).TrimEnd("`n")
    if ($chunk -eq '') { return $null }

    $lineNumber = 0
    $found = ''
    $index = 0
    foreach ($candidate in ($chunk -split "`n")) {
        $index++
        if ($candidate -match '\S') { $found = $candidate; $lineNumber = $index }
    }
    if ($lineNumber -eq 0) { return $null }

    return @{
        Line      = ($found -replace "[`t`r]", ' ')
        Truncated = ($size -gt $TailBytes -and $lineNumber -eq 1)
    }
}

<#
.SYNOPSIS
The bounded, deduped annotation block for a set of deduped raw rows.
.DESCRIPTION
Best-effort supplemental context, printed only after the caller has committed
the raw queue consumption and released the append lock. The limits are
constants, so status-file volume cannot turn a drain into an unbounded context
read: at most 8 status reads, at most 2048 bytes per annotation, at most 8192
bytes of annotations in total, and an explicit marker whenever either cap
omitted something.

Lengths are counted in BYTES, matching the twin's `${#line}` under LC_ALL=C, so
a multibyte status line is budgeted the same way in both worlds.
#>
function Get-FmWakeAnnotation {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Rows)

    $tailBytes = 8192
    $itemBytes = 2048
    $globalBytes = 8192
    $readCap = 8
    $markerReserve = 192

    $order = [System.Collections.Generic.List[string]]::new()
    $mode = @{}
    foreach ($entry in (Get-FmWakeAnnotationManifest -Rows $Rows)) {
        $parts = $entry.Split("`t")
        if ($parts.Count -lt 2) { continue }
        $key = $parts[0]
        if (-not $mode.ContainsKey($key)) {
            $order.Add($key)
            $mode[$key] = $parts[1]
        } elseif ($parts[1] -ceq 'direct') {
            $mode[$key] = 'direct'
        }
    }

    # Test-only latency seam for proving that queue appends remain independent
    # of a slow best-effort annotation phase.
    $delay = Get-FmEnv -Name 'FM_WAKE_ENRICH_TEST_DELAY' -Default '0'
    if ($delay -ne '0' -and $delay -match '^[0-9]+$') {
        Start-Sleep -Seconds ([int]$delay)
    }

    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    $omitted = 0
    $readOmitted = 0
    $reads = 0
    foreach ($statusKey in $order) {
        if ([string]::IsNullOrEmpty($statusKey)) { continue }
        if ($reads -ge $readCap) {
            $readOmitted++
            continue
        }
        $reads++
        $path = "$($script:FmWakeContext.State)/$statusKey"
        # Named $latest, not $event: $event is a PowerShell automatic variable.
        $latest = Get-FmWakeLatestEvent -Path $path -TailBytes $tailBytes
        if ($null -eq $latest) { continue }
        $prefix = 'wake annotation: latest wake-EVENT observed at drain, not current state'
        if ($mode[$statusKey] -ceq 'historical') {
            $prefix = "$prefix; historical / not necessarily the triggering event"
        }
        $line = "${prefix}: ${statusKey}: $($latest.Line)"
        if ($latest.Truncated) { $line = "$line [truncated]" }
        $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line)
        if (($lineBytes + 1) -gt $itemBytes) {
            $suffix = ' [truncated]'
            $keep = $itemBytes - $suffix.Length - 1
            $raw = [System.Text.Encoding]::UTF8.GetBytes($line)
            $line = [System.Text.Encoding]::UTF8.GetString($raw, 0, [Math]::Min($keep, $raw.Length)) + $suffix
            $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line)
        }
        $bytes = $lineBytes + 1
        if (($used + $bytes + $markerReserve) -gt $globalBytes) {
            $omitted++
            continue
        }
        [void]$builder.Append($line).Append("`n")
        $used += $bytes
    }

    if ($omitted -gt 0) {
        [void]$builder.Append("wake annotation: $omitted annotations omitted (global enrichment byte cap)`n")
    }
    if ($readOmitted -gt 0) {
        [void]$builder.Append("wake annotation: $readOmitted annotations omitted (enrichment read cap)`n")
    }
    return $builder.ToString()
}

<#
.SYNOPSIS
Print the bounded annotation block for a set of deduped raw rows.
#>
function Write-FmWakeAnnotation {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Rows)

    Write-FmRaw (Get-FmWakeAnnotation -Rows $Rows)
}

Export-ModuleMember -Function @(
    'Get-FmWakeContext', 'Get-FmLockOwnerTokenFileName',
    'Get-FmCurrentPid', 'Test-FmPidAlive', 'Test-FmMsysPidAlive', 'Get-FmPidIdentity',
    'Get-FmPathMtime', 'Get-FmPathAge',
    'Test-FmWatcherLockMatchesPid', 'Test-FmWatcherHealthy', 'Get-FmWatcherHealthyPid',
    'Get-FmSupervisionModel', 'Get-FmWatcherSupervisionVerdict',
    'Get-FmLockPathDir', 'Get-FmLockAbsPath', 'Test-FmLockSymlinksWork',
    'Test-FmLockOwnerShapeOk', 'Get-FmLockFallbackOwner', 'Clear-FmLockKnownFile',
    'Remove-FmLockDir', 'Test-FmLockHolderIsLive', 'New-FmLockOwnerDir',
    'Initialize-FmLockOwner', 'Remove-FmLockOwner', 'Get-FmLockLinkOwner',
    'Test-FmLockPointsToOwner', 'Publish-FmLock', 'Unpublish-FmLock',
    'Write-FmLockClaimPid', 'Remove-FmLockStrayOwner', 'Test-FmLockClaimBlockedBySteal',
    'Invoke-FmLockClaim', 'New-FmLock', 'Get-FmLockOwnerDir', 'Get-FmLockHeldPid',
    'Remove-FmLockPath', 'Test-FmLockMidAcquireIsFresh', 'Test-FmLockStaleOwner',
    'Request-FmLock', 'Wait-FmLock', 'Unlock-FmLock',
    'ConvertTo-FmWakeField', 'Add-FmWake', 'Restore-FmWakeQueue',
    'Get-FmWakeDeduped', 'Write-FmWakeDeduped', 'Get-FmWakeStatusKeyMap',
    'Get-FmWakeAnnotationManifest', 'Get-FmWakeLatestEvent',
    'Get-FmWakeAnnotation', 'Write-FmWakeAnnotation'
)
