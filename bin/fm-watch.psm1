# fm-watch.psm1 - the Firstmate watcher: the SOURCE-SAFE half of a hybrid pair.
# Twin: bin/fm-watch.sh
#
# bin/fm-watch.sh carries a `[ "${BASH_SOURCE[0]}" != "$0" ] && return 0` main
# guard, so it is both a library of triage functions and a program. PowerShell
# has no file that is simultaneously a module and a program, so - exactly as
# docs/powershell-port.md prescribes for a hybrid - it becomes a PAIR: every
# function lives here, including the runtime (Invoke-FmWatchMain), and
# bin/fm-watch.ps1 holds nothing but the import and the call. Keeping the
# runtime here is what makes the watcher drivable in-process by a batched
# differential suite; behavior that lives only in a .ps1 can be tested only by
# spawning a process per case, and a pwsh spawn costs 4.8s on the reference host.
#
# WHAT THE WATCHER IS
# Classifies supervision wakes. In normal mode it absorbs benign wakes and keeps
# blocking; it queues and exits only for actionable wakes. The no-verb signal and
# stale path is absorb-only-when-provably-working: a wake is absorbed only when
# the crew shows POSITIVE evidence it is still working (an actively-running
# no-mistakes step, or a backend busy signal), and surfaced otherwise, so a crew
# that finishes (or stops and waits) without a current working signal is never
# silently swallowed. A declared external-wait pause is the separate idle absorb
# case and re-surfaces only on its long bounded cadence. While state/.afk exists
# the daemon owns triage and this watcher queues and exits on every wake.
# bin/fm-watch.sh's header owns the full reason-line vocabulary; it is not
# duplicated here so the two cannot drift.
#
# bash -> PowerShell
# ------------------
#   (top-level FM_ROOT/FM_HOME/STATE block)  -> Get-FmWatchContext
#   (top-level knob block)                   -> Get-FmWatchSetting
#   stat_mtime / stat_sig                    -> Get-FmWatchMtime / Get-FmWatchSignature
#   age_of                                   -> Get-FmWatchAge
#   afk_present                              -> Test-FmWatchAfk
#   hash_pane                                -> Get-FmWatchPaneHash
#   window_is_busy                           -> Test-FmWatchWindowBusy
#   window_kind / window_backend             -> Get-FmWatchWindowKind / Get-FmWatchWindowBackend
#   window_harness / window_label            -> Get-FmWatchWindowHarness / Get-FmWatchWindowLabel
#   recorded_windows                         -> Get-FmWatchRecordedWindow
#   wedge_timer_check                        -> Test-FmWatchWedgeTimer
#   busy_turn_over_age                       -> Test-FmWatchBusyTurnOverAge
#   handle_paused_stale                      -> Invoke-FmWatchPausedStale
#   clear_pause_state / clear_pause_tracking -> Clear-FmWatchPauseState / Clear-FmWatchPauseTracking
#   pause_state_class                        -> Get-FmWatchPauseStateClass
#   surface_nonterminal_stale                -> Show-FmWatchNonterminalStale
#   scan_signals                             -> Get-FmWatchChangedSignal
#   run_check_capture                        -> Invoke-FmWatchCheck
#   mark_all_captain_relevant_surfaced       -> Set-FmWatchAllCaptainRelevantSurfaced
#   heartbeat_scan_finds_actionable          -> Test-FmWatchHeartbeatActionable
#   event_wait_or_sleep                      -> Wait-FmWatchEvent
#   (main entry below the source guard)      -> Invoke-FmWatchMain
#
# ============================================================================
# DIVERGENCES FROM THE BASH TWIN - STATED, NOT HIDDEN
# ============================================================================
# 1. SIGNALS. `trap 'exit 1' HUP INT TERM` and the whole process-group dance in
#    run_check_capture (set -m, fm_proc_pgid, `kill -TERM -- -$pgid`, the
#    escalating TERM/KILL loop, the FM_CHECK_SIGNAL_PENDING window) exist to
#    bound a check that ignores its own timeout and to keep a signalled watcher
#    from orphaning it. HUP/TERM do not exist on Windows
#    (docs/powershell-port.md), so those exit codes are NOT faked. The PROPERTY
#    they protect is preserved by a different mechanism: Invoke-FmTool's
#    -TimeoutSeconds kills the child's whole process TREE at expiry, which is
#    what the process group bought bash, and the watcher's cleanup runs from a
#    `finally` rather than an EXIT trap.
# 2. NO PRIVATE TEMP FILE FOR CHECK OUTPUT. The bash twin captures a check
#    through a mktemp'd 0600 file in $STATE because a shell cannot hold a
#    child's stdout without one. Here the output is captured in-process, so the
#    file - and the `chmod 0600` whose enforcement is inert on Windows anyway
#    (the noacl rule) - has nothing to protect and is not created. Every other
#    private-file gate the check path relies on stays exactly where it is, in
#    fm-check-lib and fm-pr-lib.
# 3. `uname`-KEYED stat. The twin picks `stat -f` on Darwin and `stat -c`
#    elsewhere, with a comment warning that the fallback FORM corrupts stdout on
#    Linux. In-process there is no stat(1) and no fallback to get wrong; both
#    branches collapse to one reader that truncates to whole seconds exactly as
#    both stat flavors do.
# 4. THE LOCK IDENTITY TOKENS ARE THE BASH TWIN'S SPELLING, ON PURPOSE. The
#    lock's `watcher-path` and `fm-home` children are not filesystem paths this
#    process opens - they are IDENTITY tokens, compared as literal strings by
#    fm_watcher_lock_matches_pid to answer "is this MY home's watcher, or a
#    recycled pid". THREE separate readers compare them, and two of them are
#    bash scripts with no PowerShell twin: bin/fm-watch-arm.*, bin/fm-guard.sh,
#    and - the one that makes this load-bearing - bin/fm-pr-check-migrate.sh,
#    which every watcher runs as a hard gate BEFORE it even attempts the lock.
#    Publishing "<bin>/fm-watch.ps1" was tried and is WRONG: the migration then
#    cannot attribute the lock, refuses with "watcher ownership is ambiguous",
#    and the watcher exits 1 instead of standing down with "already running" -
#    so the ordinary startup race (fm-watch-arm starting a child while a healthy
#    watcher holds the singleton) turns into a reported FAILURE instead of a
#    clean attach. Verified on this host by the differential suite.
#    So WatchToken is "<bin>/fm-watch.sh" in POSIX form, byte-identical to what
#    bash writes, and HomeToken is the RAW FM_HOME value rather than a
#    normalized native path, for the same reason. WatchPath (the resolved twin)
#    stays separate and is used only where an actual path is needed - launching
#    the watcher from fm-watch-arm.
#    This does NOT make a cross-world healthy-watcher match possible: a Windows
#    pid identity still compares as MISMATCH against an MSYS one (fm-wake-lib's
#    documented divergence 2), which is the safe direction. It makes the
#    SAME-world path work, which is the path that actually runs.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on any nested import: -Force REMOVES the loaded module globally
# before re-importing, and every caller of the removed module silently loses its
# commands (docs/powershell-port.md, "Never -Force a NESTED module import").
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
# The native event fast-path and only its true dependencies have one narrow
# production owner; the Herdr event-wait smoke test consumes that same owner
# without loading the entire watcher graph.
Import-Module (Join-Path $PSScriptRoot 'fm-push-transition-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-check-lib.psm1')
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
Import-Module (Join-Path $PSScriptRoot 'fm-pending-reply-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1')

# --- context -----------------------------------------------------------------
#
# Resolved at import, like the bash twin's top-level block, including the
# `mkdir -p "$STATE"`.

function Resolve-FmWatchSibling {
    # The transition-safe spelling of "the watcher script itself". Invoke-FmScript
    # owns this rule for EXECUTING a sibling, but the lock's watcher-path field
    # and fm-watch-arm's child launch both need the PATH rather than a run, so
    # the rule (prefer the .ps1 twin, fall back to the .sh) is applied here
    # rather than an extension being hard-coded (contract 7).
    param(
        [Parameter(Mandatory)][string]$BinDir,
        [Parameter(Mandatory)][string]$Name
    )
    $ps1 = Join-Path $BinDir "$Name.ps1"
    if ((Test-Path -LiteralPath $ps1) -and ((Get-Item -LiteralPath $ps1).Length -gt 0)) { return $ps1 }
    $sh = Join-Path $BinDir "$Name.sh"
    if (Test-Path -LiteralPath $sh) { return $sh }
    return $ps1
}

$script:FmWatchContext = $null

function Initialize-FmWatchContext {
    $common = Get-FmContext -ScriptRoot $PSScriptRoot
    $state = $common.State
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $state))
    } catch {
        # `mkdir -p` under `set -u` but no `set -e`: a failure here is ignored and
        # the first real write reports it.
        $null = $_
    }
    # HomeToken / WatchToken are the two strings this watcher PUBLISHES into the
    # lock, and they are deliberately NOT the resolved native paths beside them.
    # See "THE LOCK IDENTITY TOKENS ARE THE BASH TWIN'S SPELLING" below.
    $rootOverride = Get-FmEnv -Name 'FM_ROOT_OVERRIDE'
    $homeToken = Get-FmEnv -Name 'FM_HOME'
    if (-not $homeToken) {
        $homeToken = if ($rootOverride) { $rootOverride } else { ConvertTo-FmPosixPath $common.Root }
    }
    $script:FmWatchContext = @{
        ScriptRoot = $PSScriptRoot
        Root       = $common.Root
        Home       = $common.Home
        State      = $state
        WatchLock  = "$state/.watch.lock"
        WatchPath  = (Resolve-FmWatchSibling -BinDir $PSScriptRoot -Name 'fm-watch')
        HomeToken  = $homeToken
        WatchToken = (ConvertTo-FmPosixPath $PSScriptRoot) + '/fm-watch.sh'
    }
}

Initialize-FmWatchContext

<#
.SYNOPSIS
The watcher's resolved context: ScriptRoot, Root, Home, State, WatchLock, WatchPath.
#>
function Get-FmWatchContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return $script:FmWatchContext
}

# --- knobs -------------------------------------------------------------------
#
# Read on demand rather than snapshotted at import. The bash twin reads them once
# at the top of the process, and a production run behaves identically either way
# because nothing changes its own environment mid-loop; reading on demand is what
# lets a batched suite drive many cases through one loaded module without the
# first case's environment deciding every later one.

<#
.SYNOPSIS
One watcher tuning knob, with the bash twin's exact `${VAR:-default}` semantics.
#>
function Get-FmWatchSetting {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $raw = switch -CaseSensitive ($Name) {
        'Poll' { Get-FmEnv -Name 'FM_POLL' -Default '15' }
        'Heartbeat' { Get-FmEnv -Name 'FM_HEARTBEAT' -Default '600' }
        'HeartbeatMax' { Get-FmEnv -Name 'FM_HEARTBEAT_MAX' -Default '7200' }
        'CheckInterval' { Get-FmEnv -Name 'FM_CHECK_INTERVAL' -Default '300' }
        'CheckTimeout' { Get-FmEnv -Name 'FM_CHECK_TIMEOUT' -Default '30' }
        'SignalGrace' { Get-FmEnv -Name 'FM_SIGNAL_GRACE' -Default '30' }
        'StaleEscalateSecs' { Get-FmEnv -Name 'FM_STALE_ESCALATE_SECS' -Default '240' }
        'BusyTurnMaxSecs' { Get-FmEnv -Name 'FM_BUSY_TURN_MAX_SECS' -Default '3600' }
        'EventCapFailMax' { Get-FmEnv -Name 'FM_EVENT_CAP_FAIL_MAX' -Default '3' }
        'WedgeDemandInspectCount' { Get-FmEnv -Name 'FM_WEDGE_DEMAND_INSPECT_COUNT' -Default '3' }
        # `${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}`, where the
        # default is the classifier's own constant - which is exactly what
        # Get-FmClassifyPauseResurfaceInterval already resolves.
        'PauseResurfaceSecs' { Get-FmClassifyPauseResurfaceInterval }
        # `${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}` - two levels, and
        # the inner one is the guard's single definition of liveness.
        'WatcherStaleGrace' {
            Get-FmEnv -Name 'FM_WATCHER_STALE_GRACE' -Default (Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300')
        }
        default { throw "unknown watcher setting: $Name" }
    }
    [long]$value = 0
    if ([long]::TryParse([string]$raw, [ref]$value)) { return $value }
    # A non-numeric knob is a bash arithmetic error mid-loop, which kills the
    # watcher. Refusing to start on it is the same outcome reached sooner and
    # with a diagnostic that names the knob.
    throw "watcher setting $Name is not an integer: $raw"
}

# --- small primitives --------------------------------------------------------

<#
.SYNOPSIS
A path's mtime in whole epoch seconds, or $null (the `stat` failure twin).
#>
function Get-FmWatchMtime {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    try {
        $item = Get-Item -LiteralPath (ConvertTo-FmNativePath $Path) -Force -ErrorAction Stop
        return ([System.DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
A file's "<size>:<mtime>" change signature, or '' when it cannot be read.
.DESCRIPTION
Twin of stat_sig. The signature - not an mtime comparison - is what lets a
signal written while no watcher ran still be caught by the next one, and what
keeps two same-second writes from slipping through a strict `-nt` test.
#>
function Get-FmWatchSignature {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try {
        $item = Get-Item -LiteralPath (ConvertTo-FmNativePath $Path) -Force -ErrorAction Stop
        $size = 0
        if ($item -is [System.IO.FileInfo]) { $size = $item.Length }
        return "$($size):$(([System.DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds())"
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
Seconds since a path's mtime; 999999 ("due immediately") when it cannot be read.
.DESCRIPTION
Twin of age_of. Check and heartbeat cadence must survive actionable exits and
restarts, so the schedule is persisted as file mtimes rather than in-memory
counters, and an unreadable mtime must read as ancient rather than as fresh.
#>
function Get-FmWatchAge {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    $m = Get-FmWatchMtime -Path $Path
    if ($null -eq $m) { return 999999 }
    return ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $m)
}

function Get-FmWatchNow {
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# `touch "$f"`: create when absent, otherwise bump the mtime. Best-effort
# throughout, exactly as the twin's unchecked `touch` calls are.
function Update-FmWatchTouch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The `touch` twin on the watcher hot path; its bash twin touches unconditionally and a -WhatIf/-Confirm surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    try {
        if ([System.IO.File]::Exists($native)) {
            [System.IO.File]::SetLastWriteTimeUtc($native, [datetime]::UtcNow)
        } else {
            [System.IO.File]::WriteAllText($native, '', [System.Text.UTF8Encoding]::new($false))
        }
    } catch {
        $null = $_
    }
}

function Remove-FmWatchFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The `rm -f` twin on the watcher hot path; its bash twin removes unconditionally and a -WhatIf/-Confirm surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0, ValueFromRemainingArguments = $true)][string[]]$Path)

    foreach ($p in $Path) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        $native = ConvertTo-FmNativePath $p
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $null = $_
        }
    }
}

# `[ -e "$p" ]`: a directory counts, and so does anything else that exists.
function Test-FmWatchPathPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath $Path
    return ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native))
}

# `printf '%s' "$v" > "$f"` - no trailing newline, which matters: the readers
# below compare the CONTENT of these markers to a hash or a count.
function Set-FmWatchMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A volatile watcher marker whose bash twin writes unconditionally; a -WhatIf/-Confirm surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Value,
        [switch]$Newline
    )
    try {
        Set-FmFileText -Path $Path -Text $Value -NoNewline:(-not $Newline)
    } catch {
        $null = $_
    }
}

# `$(cat "$f" 2>/dev/null || true)` - trailing newlines stripped by the capture.
function Get-FmWatchMarker {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return (Get-FmFileText -Path $Path).TrimEnd("`n")
}

# `$(cat "$f" 2>/dev/null || echo 0)` folded to a number, with a non-numeric
# body reading as 0 rather than aborting the cycle.
function Get-FmWatchCounter {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $raw = Get-FmWatchMarker -Path $Path
    [long]$value = 0
    if ([long]::TryParse($raw, [ref]$value)) { return $value }
    return 0
}

<#
.SYNOPSIS
The per-window marker key: ':' '/' and '.' each become '_' (the `tr ':/.' '___'`
and `${w//:/_}` twin, which the bash spells both ways for the same result).
#>
function Get-FmWatchWindowKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window)

    if ([string]::IsNullOrEmpty($Window)) { return '' }
    return ($Window -replace '[:/.]', '_')
}

<#
.SYNOPSIS
True while the away-mode flag exists (afk_present).
.DESCRIPTION
When set, the daemon wraps this watcher and owns triage, so the watcher must
behave one-shot - enqueue and exit on every wake - and let the daemon classify.
Absorbing here would mean the daemon's digest/injection layer never sees the wake.
#>
function Test-FmWatchAfk {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    return (Test-FmWatchPathPresent -Path "$State/.afk")
}

<#
.SYNOPSIS
The lowercase MD5 hex of a captured pane tail (hash_pane).
.DESCRIPTION
The bash twin pipes the tail into md5/md5sum and keeps the first field. Hashing
the UTF-8 bytes in-process yields the identical digest for identical bytes, and
removes the per-poll-per-window fork the twin pays.
#>
function Get-FmWatchPaneHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ($null -eq $Text) { $Text = '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $digest = $md5.ComputeHash($bytes)
    } finally {
        $md5.Dispose()
    }
    $sb = [System.Text.StringBuilder]::new($digest.Length * 2)
    foreach ($b in $digest) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# --- window attributes -------------------------------------------------------

<#
.SYNOPSIS
The kind recorded for a window's task, or 'unknown' when no meta matches.
.DESCRIPTION
Twin of window_kind. A meta with no kind= line defaults to ship; only the
absence of a matching meta at all is 'unknown'.
#>
function Get-FmWatchWindowKind {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $meta = ''
    try { $meta = [string](Get-FmBackendMetaForWindow -Target $Window -StateDir $State) } catch { $meta = '' }
    if ([string]::IsNullOrEmpty($meta)) { return 'unknown' }
    $kind = Get-FmMetaValue -MetaPath $meta -Key 'kind'
    if ([string]::IsNullOrEmpty($kind)) { return 'ship' }
    return $kind
}

<#
.SYNOPSIS
The backend recorded for a window's task, defaulting to tmux.
.DESCRIPTION
Twin of window_backend. An absent backend= means tmux (the P1 compatibility
contract), and so does no matching meta at all.
#>
function Get-FmWatchWindowBackend {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $meta = ''
    try { $meta = [string](Get-FmBackendMetaForWindow -Target $Window -StateDir $State) } catch { $meta = '' }
    if ([string]::IsNullOrEmpty($meta)) { return 'tmux' }
    $backend = Get-FmMetaValue -MetaPath $meta -Key 'backend'
    if ([string]::IsNullOrEmpty($backend)) { return 'tmux' }
    return $backend
}

<#
.SYNOPSIS
The harness recorded for a window's task, or '' (window_harness).
#>
function Get-FmWatchWindowHarness {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $meta = ''
    try { $meta = [string](Get-FmBackendMetaForWindow -Target $Window -StateDir $State) } catch { $meta = '' }
    if ([string]::IsNullOrEmpty($meta)) { return '' }
    return (Get-FmMetaValue -MetaPath $meta -Key 'harness')
}

<#
.SYNOPSIS
The expected pane label for a window ("fm-<task>"), or '' (window_label).
#>
function Get-FmWatchWindowLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $task = Get-FmWindowTask -Window $Window -State $State
    if ([string]::IsNullOrEmpty($task)) { return '' }
    return "fm-$task"
}

<#
.SYNOPSIS
Every distinct endpoint recorded by a state/<id>.meta, in first-seen order.
.DESCRIPTION
Twin of recorded_windows, including the deduplication: two tasks recorded
against one endpoint are polled once. The `"$STATE"/*.meta` glob never matches a
leading dot, which matters because state/ is full of dot-prefixed records.
#>
function Get-FmWatchRecordedWindow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The name reads as the bash twin does (recorded_windows) and the return shape is a set; the singular form would read as get-one-window.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $native = ConvertTo-FmNativePath $State
    if (-not [System.IO.Directory]::Exists($native)) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($name.StartsWith('.', [System.StringComparison]::Ordinal)) { continue }
        # An ordinal suffix test rather than a search pattern: Windows pattern
        # matching still honours 8.3 short names, so "*.meta" can match a longer
        # extension.
        if (-not $name.EndsWith('.meta', [System.StringComparison]::Ordinal)) { continue }
        $names.Add($name)
    }
    # A bash glob expands in collating order; sorting reproduces the twin's
    # deterministic poll order, which the dedupe below depends on.
    $sorted = @($names | Sort-Object -CaseSensitive)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $sorted) {
        $target = ''
        try { $target = [string](Get-FmBackendTargetOfMeta -MetaPath "$State/$name") } catch { $target = '' }
        if ([string]::IsNullOrEmpty($target)) { continue }
        if ($seen.Add($target)) { $out.Add($target) }
    }
    return @($out)
}

<#
.SYNOPSIS
True when a window's harness is PROVABLY working (window_is_busy).
.DESCRIPTION
Only an exact busy verdict is true: idle, unknown, and dead are all false, so a
converted adapter whose semantic state is missing, malformed, stale, or
unverified is treated as not-provably-working and surfaces rather than being
absorbed. <Tail> is the same bounded capture already read for hashing and is
consumed only by the Grok-scoped fallback inside the busy contract.
#>
function Test-FmWatchWindowBusy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Tail = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $task = Get-FmWindowTask -Window $Window -State $State
    $meta = "$State/$task.meta"
    $verdict = ''
    if (-not [string]::IsNullOrEmpty($task) -and [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        $verdict = [string](Get-FmBusyMetaClassification -MetaPath $meta -Id $task -StateDir $State -Tail $Tail)
    } else {
        $id = if ([string]::IsNullOrEmpty($task)) { 'unknown' } else { $task }
        $verdict = [string](Get-FmBusyClassification `
                -Backend (Get-FmWatchWindowBackend -Window $Window -State $State) `
                -Target $Window `
                -Harness (Get-FmWatchWindowHarness -Window $Window -State $State) `
                -Id $id -StateDir $State -Tail $Tail)
    }
    # `${verdict%% *}` - the first SPACE-delimited word, which is the verdict;
    # the rest is the source attribution.
    $space = $verdict.IndexOf(' ', [System.StringComparison]::Ordinal)
    $head = if ($space -ge 0) { $verdict.Substring(0, $space) } else { $verdict }
    return ($head -ceq 'busy')
}

<#
.SYNOPSIS
True when a task's latest completed-turn marker is at least
FM_BUSY_TURN_MAX_SECS old (busy_turn_over_age).
.DESCRIPTION
A busy pane is unconditional proof of liveness with no built-in duration bound,
so a hung foreground call can stay hidden while its rendered busy footer changes
every poll. This ages the harness-neutral turn-ended marker every verified
harness's turn-end hook touches; before any turn has completed it ages the task's
spawn record instead, so a fresh task still gets a bound. The caller routes a
crossed bound through the ordinary wedge timer - never anything that touches the
worker itself.
#>
function Test-FmWatchBusyTurnOverAge {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Task,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $f = "$State/$Task.turn-ended"
    if (-not (Test-FmWatchPathPresent -Path $f)) { $f = "$State/$Task.meta" }
    return ((Get-FmWatchAge -Path $f) -ge (Get-FmWatchSetting 'BusyTurnMaxSecs'))
}

# --- stale bookkeeping -------------------------------------------------------

<#
.SYNOPSIS
Clear the bounded-pause cadence flags for a window (clear_pause_state).
#>
function Clear-FmWatchPauseState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Volatile watcher bookkeeping whose bash twin removes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $key = Get-FmWatchWindowKey -Window $Window
    Remove-FmWatchFile -Path "$State/.paused-$key", "$State/.paused-rechecked-$key", "$State/.paused-resurfaced-$key"
}

<#
.SYNOPSIS
Clear pause cadence AND stale/wedge bookkeeping for a window
(clear_pause_tracking).
#>
function Clear-FmWatchPauseTracking {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Volatile watcher bookkeeping whose bash twin removes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    Clear-FmWatchPauseState -Window $Window -State $State
    $key = Get-FmWatchWindowKey -Window $Window
    Remove-FmWatchFile -Path "$State/.stale-$key", "$State/.stale-since-$key", "$State/.wedge-escalations-$key"
}

<#
.SYNOPSIS
Repeat-poll wedge-timer bookkeeping for an already-classified stale hash that
was absorbed as provably-working (wedge_timer_check).
.DESCRIPTION
Repairs a missing or corrupt timer - which self-heals a watcher restart between
recording the hash and recording the timer - or escalates once
FM_STALE_ESCALATE_SECS have elapsed. NEVER re-reads the crew state: the costly
check already ran once, at classification time. Shared by both places a hash can
be absorbed this way: the plain non-terminal path, and the stale_is_terminal
path where an active run or busy pane outranked a captain-relevant log line.

At FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane the
reason carries a demand-deep-inspection marker, so the wake payload itself - not
just repetition a supervisor has to notice unaided - forces a closer look
instead of another routine supervision resume.

-WakeAction and -SleepAction exist only so a differential driver can observe the
wake instead of being terminated by it; production leaves them unset and gets
the bash twin's exact behavior, which is that a wake ENDS the process.
#>
function Test-FmWatchWedgeTimer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Volatile watcher bookkeeping whose bash twin writes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$SinceFile,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory, Position = 3)][string]$EscalationFile,
        [Parameter(Position = 4)][AllowEmptyString()][AllowNull()][string]$State,
        [scriptblock]$WakeAction
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $since = Get-FmWatchMarker -Path $SinceFile
    if ([string]::IsNullOrEmpty($since) -or $since -notmatch '^[0-9]+$') {
        Set-FmWatchMarker -Path $SinceFile -Value ([string](Get-FmWatchNow)) -Newline
        Write-FmPushTriageLog -Message "absorbed $Label timer reset: $Window" -State $State
        return $false
    }

    $age = (Get-FmWatchNow) - [long]$since
    if ($age -lt (Get-FmWatchSetting 'StaleEscalateSecs')) { return $false }

    $n = (Get-FmWatchCounter -Path $EscalationFile) + 1
    Set-FmWatchMarker -Path $EscalationFile -Value ([string]$n) -Newline
    $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n)"
    if ($n -ge (Get-FmWatchSetting 'WedgeDemandInspectCount')) {
        $reason = "stale: $Window (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
    }
    if ((Add-FmWake -Kind 'stale' -Key $Window -Payload $reason) -ne 0) { Exit-FmScript -Code 1 }
    Remove-FmWatchFile -Path $SinceFile
    if ($WakeAction) { & $WakeAction $reason } else { Invoke-FmPushWake -Reason $reason -State $State }
    return $true
}

<#
.SYNOPSIS
Absorb a stale pane under a declared external-wait pause or a dead-agent
captain-held transfer, re-surfacing it on the long bounded cadence
(handle_paused_stale).
.DESCRIPTION
Called on any stale poll once the pause class permits the bounded cadence, so it
must be cheap: it NEVER re-reads crew state. The re-surface age is anchored on
the status file mtime, not a per-hash marker, so a churny idle pane - a ticking
clock, a token counter - cannot keep resetting the cadence the way a hash-tied
timer would. A .paused-resurfaced-<key> throttle marker records the last
re-surface epoch so, once past the window, it fires once per window rather than
every poll.
#>
function Invoke-FmWatchPausedStale {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Volatile watcher bookkeeping whose bash twin writes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Task,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Hash,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$State,
        [scriptblock]$WakeAction
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $key = Get-FmWatchWindowKey -Window $Window
    Set-FmWatchMarker -Path "$State/.stale-$key" -Value $Hash
    Set-FmWatchMarker -Path "$State/.paused-$key" -Value ''
    Remove-FmWatchFile -Path "$State/.stale-since-$key", "$State/.wedge-escalations-$key"

    $statusFile = "$State/$Task.status"
    $mtime = Get-FmWatchMtime -Path $statusFile
    if ($null -eq $mtime) { $mtime = Get-FmWatchNow }
    $age = (Get-FmWatchNow) - $mtime
    $rf = "$State/.paused-resurfaced-$key"
    $rfAge = Get-FmWatchAge -Path $rf   # 999999 when no prior re-surface
    $interval = Get-FmWatchSetting 'PauseResurfaceSecs'

    $woke = $false
    if ($age -ge $interval -and $rfAge -ge $interval) {
        $reason = "stale: $Window (paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)"
        if ((Add-FmWake -Kind 'stale' -Key $Window -Payload $reason) -ne 0) { Exit-FmScript -Code 1 }
        Set-FmWatchMarker -Path $rf -Value ([string](Get-FmWatchNow)) -Newline
        $woke = $true
        if ($WakeAction) {
            & $WakeAction $reason
        } else {
            # The bash twin logs AFTER wake() - which never returns - so the
            # triage line is unreachable on this leg in both worlds.
            Invoke-FmPushWake -Reason $reason -State $State
        }
    }
    Write-FmPushTriageLog -Message "absorbed stale (paused, awaiting external, age ${age}s): $Window" -State $State
    return $woke
}

<#
.SYNOPSIS
Reconcile a declared pause or captain-held status with authoritative crew state
(pause_state_class). Returns working, paused, none, or ''.
.DESCRIPTION
Only a confidently dead ordinary crew may RECOVER paused classification after
fm-crew-state has fallen back to stopped or unknown; a live or unreadable agent
means 'none' so the wake surfaces. Secondmate endpoints skip the agent probe
entirely, because an idle secondmate agent pane is healthy by design.

The '' return is the bash twin's: when the last status line is not a declared
pause or captain hold, it delegates straight to crew_absorb_class, whose own
value is printed - so 'none'/'working'/'paused' come back from there.
#>
function Get-FmWatchPauseStateClass {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The recheck marker is volatile watcher bookkeeping whose bash twin writes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Task,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $key = Get-FmWatchWindowKey -Window $Window
    $last = Get-FmLastStatusLine -Path "$State/$Task.status"
    $recheckFile = "$State/.paused-rechecked-$key"

    if (-not (Test-FmStatusPausedOrHeld -Line $last)) {
        Remove-FmWatchFile -Path $recheckFile
        return (Get-FmCrewAbsorbClass -Id $Task)
    }

    $agentAlive = 'unknown'
    if ((Test-FmWatchPathPresent -Path "$State/.paused-$key") -and
        ((Get-FmWatchAge -Path $recheckFile) -lt (Get-FmWatchSetting 'StaleEscalateSecs'))) {
        if ((Get-FmWatchWindowKind -Window $Window -State $State) -ne 'secondmate') {
            try {
                $agentAlive = [string](Get-FmBackendAgentAlive -Backend (Get-FmWatchWindowBackend -Window $Window -State $State) -Target $Window)
            } catch {
                $agentAlive = 'unknown'
            }
            if ([string]::IsNullOrEmpty($agentAlive)) { $agentAlive = 'unknown' }
            if ($agentAlive -ne 'dead') {
                Remove-FmWatchFile -Path $recheckFile
                return 'none'
            }
        }
        return 'paused'
    }

    $class = Get-FmCrewAbsorbClass -Id $Task
    if ($class -ceq 'working') {
        Remove-FmWatchFile -Path $recheckFile
        return 'working'
    }
    if ((Get-FmWatchWindowKind -Window $Window -State $State) -ne 'secondmate') {
        try {
            $agentAlive = [string](Get-FmBackendAgentAlive -Backend (Get-FmWatchWindowBackend -Window $Window -State $State) -Target $Window)
        } catch {
            $agentAlive = 'unknown'
        }
        if ([string]::IsNullOrEmpty($agentAlive)) { $agentAlive = 'unknown' }
        if ($agentAlive -ne 'dead') {
            Remove-FmWatchFile -Path $recheckFile
            return 'none'
        }
    }
    # `${agent_alive:-unknown}`: on the secondmate leg the probe never ran, so
    # the variable is unset and this reads 'unknown' - which is why a secondmate
    # can never be promoted to paused here.
    if ($class -ceq 'none' -and $agentAlive -ceq 'dead') { $class = 'paused' }
    if ($class -ceq 'paused') {
        Set-FmWatchMarker -Path $recheckFile -Value ([string](Get-FmWatchNow)) -Newline
    } else {
        Remove-FmWatchFile -Path $recheckFile
    }
    return $class
}

<#
.SYNOPSIS
Surface a non-terminal stale pane (surface_nonterminal_stale).
#>
function Show-FmWatchNonterminalStale {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Volatile watcher bookkeeping whose bash twin writes unconditionally on the poll path; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Hash,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$State,
        [scriptblock]$WakeAction
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $key = Get-FmWatchWindowKey -Window $Window
    if ((Add-FmWake -Kind 'stale' -Key $Window -Payload "stale: $Window") -ne 0) { Exit-FmScript -Code 1 }
    Set-FmWatchMarker -Path "$State/.stale-$key" -Value $Hash
    Remove-FmWatchFile -Path "$State/.stale-since-$key"

    $task = Get-FmWindowTask -Window $Window -State $State
    $last = Get-FmLastStatusLine -Path "$State/$task.status"
    if (Test-FmStatusPausedOrHeld -Line $last) {
        Set-FmWatchMarker -Path "$State/.paused-$key" -Value ''
        Set-FmWatchMarker -Path "$State/.paused-rechecked-$key" -Value ([string](Get-FmWatchNow)) -Newline
        Set-FmWatchMarker -Path "$State/.paused-resurfaced-$key" -Value ([string](Get-FmWatchNow)) -Newline
    } else {
        Remove-FmWatchFile -Path "$State/.paused-$key", "$State/.paused-rechecked-$key", "$State/.paused-resurfaced-$key"
    }
    if ($WakeAction) { & $WakeAction "stale: $Window" } else { Invoke-FmPushWake -Reason "stale: $Window" -State $State }
}

# --- signal scan -------------------------------------------------------------

<#
.SYNOPSIS
Every status file or turn-end marker whose change signature has moved.
.DESCRIPTION
Twin of scan_signals: layers 2 and 3 of the wake detection. Each file is
compared against a persisted size:mtime signature (.seen-*) rather than
mtime-vs-a-startup-touch, so signals that land while no watcher is running are
caught by the next one, and same-second writes cannot slip through a strict `-nt`
comparison. PURE READ - .seen-* is updated only after the wake is either
surfaced or intentionally absorbed, so a watcher killed mid-cycle never swallows
a signal.

Returns one "<seen-file>`t<signature>`t<file>" record per changed file, status
files first and then turn-end markers, each group in collating order, exactly as
the twin's two globs expand.
#>
function Get-FmWatchChangedSignal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The return shape is the whole changed set, and the singular form would read as get-one-signal.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $native = ConvertTo-FmNativePath $State
    if (-not [System.IO.Directory]::Exists($native)) { return @() }

    $status = [System.Collections.Generic.List[string]]::new()
    $turnEnded = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
        $name = [System.IO.Path]::GetFileName($entry)
        if ($name.StartsWith('.', [System.StringComparison]::Ordinal)) { continue }
        if ($name.EndsWith('.status', [System.StringComparison]::Ordinal)) { $status.Add($name); continue }
        if ($name.EndsWith('.turn-ended', [System.StringComparison]::Ordinal)) { $turnEnded.Add($name) }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($name in (@($status | Sort-Object -CaseSensitive) + @($turnEnded | Sort-Object -CaseSensitive))) {
        $file = "$State/$name"
        $sig = Get-FmWatchSignature -Path $file
        # `sig=$(stat_sig "$f") || continue`: an unreadable entry is skipped,
        # never reported as changed-to-empty.
        if ([string]::IsNullOrEmpty($sig)) { continue }
        $seenFile = "$State/.seen-$($name -replace '\.', '_')"
        if ($sig -ne (Get-FmWatchMarker -Path $seenFile)) {
            $out.Add("$seenFile`t$sig`t$file")
        }
    }
    return @($out)
}

# --- checks ------------------------------------------------------------------

<#
.SYNOPSIS
Run one bounded state check and return its trimmed stdout, or $null on a
failure the bash twin treats as fatal to the cycle.
.DESCRIPTION
The run_check / run_check_capture twin, collapsed to one function because the
whole reason the bash pair exists - a temp file to hold the child's stdout, a
process group to bound a check that ignores its timeout, and the signal window
around both - has no Windows counterpart (divergences 1 and 2 in the header).
What is preserved exactly: FM_CHECK_TIMEOUT bounds the child, expiry kills its
whole process tree, stderr is discarded, and the returned value is stdout with
trailing newlines stripped by the `$(cat ...)` capture.

-Name runs a SIBLING firstmate script through Invoke-FmScript, so the twin that
exists is the one that runs. -Path runs an arbitrary file (a validated custom
check snapshot), which is a bash script in both worlds and therefore goes
through Git Bash.
#>
function Invoke-FmWatchCheck {
    [CmdletBinding(DefaultParameterSetName = 'Sibling')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Sibling')][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [string[]]$CheckArguments = @(),
        [string]$BinDir
    )

    $timeout = [int](Get-FmWatchSetting 'CheckTimeout')
    $result = $null
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Sibling') {
            $invokeArgs = @{ Name = $Name; Arguments = $CheckArguments; TimeoutSeconds = $timeout }
            if (-not [string]::IsNullOrEmpty($BinDir)) { $invokeArgs['BinDir'] = $BinDir }
            $result = Invoke-FmScript @invokeArgs
        } else {
            $bash = Get-FmBash
            if (-not $bash) { return $null }
            $argv = @((ConvertTo-FmPosixPath (ConvertTo-FmNativePath $Path))) + @($CheckArguments)
            $result = Invoke-FmTool -FilePath $bash -Arguments $argv -TimeoutSeconds $timeout
        }
    } catch {
        return $null
    }
    if ($null -eq $result) { return $null }
    if ([int]$result.ExitCode -eq 127 -and [string]::IsNullOrEmpty([string]$result.StdOut)) {
        # No twin at all is an infrastructure failure, the leg on which
        # run_check_capture returns non-zero and the watcher exits 1.
        if (([string]$result.StdErr).StartsWith('fm: no ')) { return $null }
    }
    return ([string]$result.StdOut).TrimEnd("`n")
}

# --- heartbeat backstop ------------------------------------------------------

# The captain-relevant fleet scan, as (file, task, last) triples. The classifier
# renders them as one newline-terminated TSV block; splitting here keeps the
# `while IFS=$'\t' read -r f task last` shape both consumers use.
function Get-FmWatchCaptainRelevantTriple {
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)

    $text = [string](Get-FmCaptainRelevantStatus -State $State)
    $out = [System.Collections.Generic.List[hashtable]]::new()
    if ([string]::IsNullOrEmpty($text)) { return @($out) }
    foreach ($line in ($text -split "`n")) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        # .Split on the raw string with an asserted field COUNT, never a regex
        # split: a status note legitimately contains empty fields and a regex
        # split silently drops them (docs/powershell-port.md, TAB records).
        $fields = @($line.Split("`t"))
        if ($fields.Count -lt 3) { continue }
        if ([string]::IsNullOrEmpty($fields[0])) { continue }
        # `read -r f task last` puts every REMAINING tab-joined field into the
        # last variable, so a note containing a tab is not truncated.
        $out.Add(@{ File = $fields[0]; Task = $fields[1]; Last = ($fields[2..($fields.Count - 1)] -join "`t") })
    }
    return @($out)
}

<#
.SYNOPSIS
Mark every current captain-relevant status as surfaced
(mark_all_captain_relevant_surfaced).
.DESCRIPTION
Called AFTER the heartbeat backstop enqueues its wake, so the same statuses are
not re-surfaced by the next heartbeat.
#>
function Set-FmWatchAllCaptainRelevantSurfaced {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Suppression markers whose bash twin writes unconditionally after the wake is enqueued; a confirmation surface would stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    foreach ($entry in (Get-FmWatchCaptainRelevantTriple -State $State)) {
        Set-FmWatchMarker -Path (Get-FmPushSurfacedPath -Task $entry.Task -State $State) -Value $entry.Last
    }
}

<#
.SYNOPSIS
True when a captain-relevant status has NOT already been surfaced
(heartbeat_scan_finds_actionable).
.DESCRIPTION
Pure detect, no side effects: the caller enqueues first, then marks surfaced.
Because every captain-relevant signal or stale already marks itself surfaced when
it wakes firstmate, this normally finds nothing and the heartbeat is absorbed; it
surfaces only a captain-relevant status the per-wake path absorbed by mistake -
the backstop.
#>
function Test-FmWatchHeartbeatActionable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    foreach ($entry in (Get-FmWatchCaptainRelevantTriple -State $State)) {
        $surfaced = Get-FmWatchMarker -Path (Get-FmPushSurfacedPath -Task $entry.Task -State $State)
        if ($surfaced -eq $entry.Last) { continue }
        return $true
    }
    return $false
}

# --- terminal wait -----------------------------------------------------------

# Per-process memo for the push-capability probe (Test-FmBackendEventsCapable
# runs a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed
# by "<backend>:<session>"; re-probed only when that key changes.
$script:FmWatchEventCapKey = ''
$script:FmWatchEventCapOk = $false
$script:FmWatchEventCapFails = 0

<#
.SYNOPSIS
The terminal wait of each supervision cycle (event_wait_or_sleep).
.DESCRIPTION
For a home with push-capable windows (herdr) this replaces the blind poll sleep
with a bounded wait on the backend's native transition stream, so a crew going
blocked wakes the supervisor sub-second instead of after the stale-pane wedge
timer. For every other home - no push-capable window, backend not capable, or the
event path proven unreliable this process - it sleeps the poll budget, exactly as
before. The poll loop above still runs every cycle, so this only ever SHORTENS
latency; it can never drop an escalation, because the poll loop is the permanent
backstop that refuses rather than proceeds. The single live supervision cycle is
preserved: the reader is a short-lived subprocess of THIS watcher, not a second
watcher.
#>
function Wait-FmWatchEvent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'SleepAction',
        Justification = 'A false positive: SleepAction IS used, but only from inside the nested $sleep scriptblock below, and the analyzer does not follow a closure into a nested scriptblock. Removing the parameter would delete the seam the differential suite uses to keep a poll budget from actually sleeping.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State,
        [scriptblock]$SleepAction
    )

    if ([string]::IsNullOrEmpty($State)) { $State = $script:FmWatchContext.State }
    $poll = Get-FmWatchSetting 'Poll'
    $sleep = {
        param([long]$Seconds)
        if ($SleepAction) { & $SleepAction $Seconds } else { Start-Sleep -Seconds $Seconds }
    }

    $firstBackend = ''
    $firstSession = ''
    $windows = [System.Collections.Generic.List[string]]::new()
    foreach ($w in (Get-FmWatchRecordedWindow -State $State)) {
        $b = Get-FmWatchWindowBackend -Window $w -State $State
        if (-not (Test-FmBackendHasPush -Backend $b)) { continue }
        # Secondmate endpoints are supervised via status writes, not pane or
        # agent state (an idle or blocked secondmate agent pane is healthy by
        # design), so they are excluded here exactly as the stale loop skips them.
        if ((Get-FmWatchWindowKind -Window $w -State $State) -eq 'secondmate') { continue }
        # `${w%%:*}` - up to the FIRST colon.
        $colon = $w.IndexOf(':', [System.StringComparison]::Ordinal)
        $session = if ($colon -ge 0) { $w.Substring(0, $colon) } else { $w }
        if ([string]::IsNullOrEmpty($firstBackend)) { $firstBackend = $b; $firstSession = $session }
        # One socket connection covers one backend+session; a home normally has
        # a single herdr session. A window in a different backend or session
        # stays on the poll path this cycle.
        if ($b -ne $firstBackend -or $session -ne $firstSession) { continue }
        $windows.Add($w)
    }

    if ($windows.Count -eq 0) { & $sleep $poll; return }

    if ($script:FmWatchEventCapKey -ne "${firstBackend}:${firstSession}") {
        $script:FmWatchEventCapKey = "${firstBackend}:${firstSession}"
        $script:FmWatchEventCapOk = [bool](Test-FmBackendEventsCapable -Backend $firstBackend -Session $firstSession)
        $script:FmWatchEventCapFails = 0
    }
    if (-not $script:FmWatchEventCapOk) { & $sleep $poll; return }

    $previous = [Environment]::GetEnvironmentVariable('FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED')
    $transition = $null
    try {
        [Environment]::SetEnvironmentVariable('FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED', '1')
        $transition = Wait-FmBackendTransition -Backend $firstBackend -Session $firstSession `
            -TimeoutSeconds ([string]$poll) -StateDir $State -PaneWindow @($windows)
    } finally {
        [Environment]::SetEnvironmentVariable('FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED', $previous)
    }

    $code = if ($null -eq $transition) { 1 } else { [int]$transition.Code }
    if ($code -eq 0) {
        $script:FmWatchEventCapFails = 0
        $null = Invoke-FmPushTransition -Backend $firstBackend -Session $firstSession `
            -Record ([string]$transition.Record) -State $State
    } elseif ($code -eq 2) {
        # Event path unusable this cycle (connect or subscribe failure). Sleep the
        # budget and count toward the runtime-disable threshold; past it, drop to
        # pure polling for the rest of this watcher process.
        $script:FmWatchEventCapFails++
        if ($script:FmWatchEventCapFails -ge (Get-FmWatchSetting 'EventCapFailMax')) {
            $script:FmWatchEventCapOk = $false
        }
        & $sleep $poll
    } else {
        # 1: a clean full-budget wait with no actionable edge - the reader already
        # blocked ~POLL, so just continue; the next cycle re-scans.
        $script:FmWatchEventCapFails = 0
    }
}

# --- the runtime -------------------------------------------------------------

# Everything below the bash twin's `[ "${BASH_SOURCE[0]}" != "$0" ]` guard.

function Invoke-FmWatchCheckSweep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The check sweep is the watcher hot path; its bash twin writes cadence markers unconditionally and a confirmation surface would stall a non-interactive watcher.')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$FmHome,
        [Parameter(Mandatory)][string]$FmRoot
    )

    $native = ConvertTo-FmNativePath $State
    $names = [System.Collections.Generic.List[string]]::new()
    if ([System.IO.Directory]::Exists($native)) {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', [System.StringComparison]::Ordinal)) { continue }
            if ($name.EndsWith('.check.sh', [System.StringComparison]::Ordinal)) { $names.Add($name) }
        }
    }

    $rejected = ''
    foreach ($name in (@($names | Sort-Object -CaseSensitive))) {
        $c = "$State/$name"
        $isPrPoll = $false
        $out = $null
        $id = ''

        if ($name -ceq 'x-watch.check.sh') {
            # The shim's TARGET is named literally in both worlds: this gate is a
            # data check on the exact file the published shim invokes, not a
            # sibling dispatch, so it is not routed through Invoke-FmScript.
            $target = "$FmRoot/bin/fm-x-poll.sh"
            $nativeTarget = ConvertTo-FmNativePath $target
            if ((Test-FmxPollShim -Path $c -HomePath $FmHome -Root $FmRoot) -and
                [System.IO.File]::Exists($nativeTarget) -and -not (Test-FmSymlink -Path $nativeTarget)) {
                $previousHome = [Environment]::GetEnvironmentVariable('FM_HOME')
                try {
                    [Environment]::SetEnvironmentVariable('FM_HOME', $FmHome)
                    $out = Invoke-FmWatchCheck -Name 'fm-x-poll' -BinDir "$FmRoot/bin"
                } finally {
                    [Environment]::SetEnvironmentVariable('FM_HOME', $previousHome)
                }
                if ($null -eq $out) { Exit-FmScript -Code 1 }
            } else {
                $rejected = "$rejected $c"
                continue
            }
        } else {
            $id = $name.Substring(0, $name.Length - '.check.sh'.Length)
            $snapshot = $null
            try {
                $snapshot = Get-FmPrPollSnapshot -State $State -Id $id -Template 'fm-pr-poll'
            } catch {
                $snapshot = $null
            }
            if ($null -ne $snapshot) {
                $isPrPoll = $true
                $out = Invoke-FmWatchCheck -Name 'fm-pr-poll' -CheckArguments @(
                    '--validated', [string]$snapshot.Provider, [string]$snapshot.Url,
                    [string]$snapshot.Host, [string]$snapshot.Path, [string]$snapshot.Number)
                if ($null -eq $out) { Exit-FmScript -Code 1 }
            } else {
                $custom = $null
                try { $custom = New-FmCustomCheckSnapshot -State $State -Id $id } catch { $custom = $null }
                if (-not [string]::IsNullOrEmpty($custom)) {
                    $out = Invoke-FmWatchCheck -Path $custom
                    Remove-FmCustomCheckSnapshot
                    if ($null -eq $out) { Exit-FmScript -Code 1 }
                } else {
                    Remove-FmCustomCheckSnapshot
                    $rejected = "$rejected $c"
                    continue
                }
            }
        }

        if (-not [string]::IsNullOrEmpty($out)) {
            $reason = "check: ${c}: $out"
            if ((Add-FmWake -Kind 'check' -Key $c -Payload $reason) -ne 0) { Exit-FmScript -Code 1 }
            if ($isPrPoll -and $out -ceq 'merged') {
                $published = $false
                try {
                    $published = Publish-FmPrPollRetirement -Snapshot $snapshot -State $State -Id $id `
                        -Template 'fm-pr-poll' -Result $out
                } catch {
                    $published = $false
                }
                if ($published) {
                    $recovered = $false
                    try {
                        $recovered = Restore-FmPrPollRetirementOne -State $State -Id $id -Template 'fm-pr-poll'
                    } catch {
                        $recovered = $false
                    }
                    if (-not $recovered) {
                        Write-FmPushTriageLog -Message "merged PR poll retirement remains recoverable for $id" -State $State
                    }
                } else {
                    Write-FmPushTriageLog -Message "merged PR poll retirement deferred because its canonical snapshot changed for $id" -State $State
                }
            }
            Update-FmWatchTouch -Path "$State/.last-check"
            Invoke-FmPushWake -Reason $reason -State $State
        }
    }

    if (-not [string]::IsNullOrEmpty($rejected)) {
        $reason = "check: rejected unauthenticated state checks:$rejected"
        if ((Add-FmWake -Kind 'check' -Key 'unauthenticated-state-checks' -Payload $reason) -ne 0) { Exit-FmScript -Code 1 }
        Update-FmWatchTouch -Path "$State/.last-check"
        Invoke-FmPushWake -Reason $reason -State $State
    }
    Update-FmWatchTouch -Path "$State/.last-check"
}

function Invoke-FmWatchSignalSweep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The signal sweep is the watcher hot path; its bash twin advances suppression markers unconditionally and a confirmation surface would stall a non-interactive watcher.')]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$State)

    $pending = @(Get-FmWatchChangedSignal -State $State)
    if ($pending.Count -eq 0) { return }

    # On the first changed signal, linger one grace period and re-scan before
    # classifying: a crewmate's final status write and the same turn's turn-end
    # hook land seconds apart, and reporting them as separate actionable wakes
    # costs a full firstmate turn each. The re-scan also picks up a newer
    # signature for an already-pending file (last write wins below).
    Start-Sleep -Seconds (Get-FmWatchSetting 'SignalGrace')
    $pending = @($pending) + @(Get-FmWatchChangedSignal -State $State)

    $files = [System.Collections.Generic.List[string]]::new()
    $records = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($record in $pending) {
        if ([string]::IsNullOrEmpty($record)) { continue }
        $fields = @($record.Split("`t"))
        if ($fields.Count -lt 3) { continue }
        if ([string]::IsNullOrEmpty($fields[0])) { continue }
        $records.Add(@{ SeenFile = $fields[0]; Signature = $fields[1]; File = $fields[2] })
        if (-not $files.Contains($fields[2])) { $files.Add($fields[2]) }
    }
    if ($records.Count -eq 0) { return }

    $reason = 'signal:' + (($files | ForEach-Object { " $_" }) -join '')

    # Triage, cheapest test first:
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew
    #     is NOT provably working - the crew stopped its turn with no
    #     actively-running pipeline and no busy pane, so it may be done (even via
    #     an interactive menu that wrote no done: status), waiting on a decision,
    #     or wedged. Absorbing such a turn-end is exactly the swallowed finish
    #     this triage exists to prevent.
    # The provably-working check is the only costly one (it may run a bounded
    # no-mistakes call), so the ordering evaluates it ONLY for a non-afk,
    # no-captain-verb signal.
    $fileList = @($files)
    $actionable = (Test-FmWatchAfk -State $State) -or
        (Test-FmSignalActionable -Path $fileList) -or
        -not (Test-FmSignalCrewProvablyWorking -Path $fileList)

    if ($actionable) {
        foreach ($record in $records) {
            if ((Add-FmWake -Kind 'signal' -Key ([System.IO.Path]::GetFileName($record.File)) -Payload $reason) -ne 0) {
                Exit-FmScript -Code 1
            }
        }
        # Enqueue-before-suppress: the markers advance only once every record is
        # durably queued.
        foreach ($record in $records) {
            Set-FmWatchMarker -Path $record.SeenFile -Value $record.Signature
            $null = Set-FmPushSurfaced -StatusPath $record.File -State $State
        }
        Invoke-FmPushWake -Reason $reason -State $State
    } else {
        foreach ($record in $records) {
            Set-FmWatchMarker -Path $record.SeenFile -Value $record.Signature
        }
        Write-FmPushTriageLog -Message "absorbed benign $reason" -State $State
    }
}

function Invoke-FmWatchStaleSweep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The stale sweep is the watcher hot path; its bash twin writes hash and counter markers unconditionally and a confirmation surface would stall a non-interactive watcher.')]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$State)

    foreach ($w in (Get-FmWatchRecordedWindow -State $State)) {
        $kind = Get-FmWatchWindowKind -Window $w -State $State
        $task = Get-FmWindowTask -Window $w -State $State
        $key = Get-FmWatchWindowKey -Window $w
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        if (-not (Test-FmStatusPausedOrHeld -Line $last) -and (Test-FmWatchPathPresent -Path "$State/.paused-$key")) {
            Clear-FmWatchPauseTracking -Window $w -State $State
        }
        if ($kind -eq 'secondmate' -and -not (Test-FmStatusPaused -Line $last)) { continue }

        $tail40 = $null
        try {
            $tail40 = [string](Get-FmBackendCapture -Backend (Get-FmWatchWindowBackend -Window $w -State $State) `
                    -Target $w -Lines '40' -ExpectedLabel (Get-FmWatchWindowLabel -Window $w -State $State))
        } catch {
            # `|| continue`: an endpoint that cannot be captured is skipped this
            # poll rather than being read as a stale pane.
            continue
        }
        if ($null -eq $tail40) { continue }

        $h = Get-FmWatchPaneHash -Text $tail40
        $hf = "$State/.hash-$key"
        $cf = "$State/.count-$key"
        $sf = "$State/.stale-$key"
        $ssf = "$State/.stale-since-$key"
        $ewf = "$State/.wedge-escalations-$key"
        $pf = "$State/.paused-$key"   # this key's stale is on the bounded pause cadence
        $prev = Get-FmWatchMarker -Path $hf

        # Busy match: a backend's native semantic state when available (herdr),
        # else the last few non-blank lines only - the TUI footer area, where
        # every verified harness renders its busy indicator - so busy-looking
        # strings in displayed CONTENT cannot suppress stale detection. Read once
        # per window per poll and reused below so a busy verdict is consistent
        # within one cycle.
        $busyNow = Test-FmWatchWindowBusy -Window $w -Tail $tail40 -State $State

        if ($h -ceq $prev) {
            $n = (Get-FmWatchCounter -Path $cf) + 1
            Set-FmWatchMarker -Path $cf -Value ([string]$n) -Newline
            if ($n -ge 2 -and -not $busyNow) {
                # The pane is idle/stale at hash $h. Triage decides whether this
                # wakes firstmate; detection itself is unchanged.
                if ($kind -eq 'secondmate') {
                    if ((Get-FmWatchPauseStateClass -Window $w -Task $task -State $State) -ceq 'paused') {
                        $null = Invoke-FmWatchPausedStale -Window $w -Task $task -Hash $h -State $State
                    } else {
                        Clear-FmWatchPauseTracking -Window $w -State $State
                    }
                } elseif (Test-FmWatchAfk -State $State) {
                    # Daemon owns triage: one-shot per distinct stale hash.
                    if ((Get-FmWatchMarker -Path $sf) -cne $h) {
                        if ((Add-FmWake -Kind 'stale' -Key $w -Payload "stale: $w") -ne 0) { Exit-FmScript -Code 1 }
                        Set-FmWatchMarker -Path $sf -Value $h
                        Invoke-FmPushWake -Reason "stale: $w" -State $State
                    }
                } elseif (Test-FmStaleTerminal -Window $w -State $State) {
                    # The log's last line is captain-relevant - but that alone is
                    # not proof the crew is done: a crew's own status log gets no
                    # new entry once firstmate hands it to a no-mistakes
                    # validation, so the log can keep showing a leftover
                    # done:/needs-decision/blocked line from BEFORE that
                    # validation for the run's entire duration. On a NEW hash,
                    # give an active run or busy pane - the same authoritative
                    # source fm-crew-state already prioritizes over the log - a
                    # chance to override before trusting the log.
                    if ((Get-FmWatchMarker -Path $sf) -cne $h) {
                        if (Test-FmCrewProvablyWorking -Id (Get-FmWindowTask -Window $w -State $State)) {
                            Set-FmWatchMarker -Path $sf -Value $h
                            Set-FmWatchMarker -Path $ssf -Value ([string](Get-FmWatchNow)) -Newline
                            Write-FmPushTriageLog -State $State `
                                -Message "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
                        } else {
                            if ((Add-FmWake -Kind 'stale' -Key $w -Payload "stale: $w") -ne 0) { Exit-FmScript -Code 1 }
                            Set-FmWatchMarker -Path $sf -Value $h
                            Remove-FmWatchFile -Path $ssf
                            $null = Set-FmPushSurfaced -State $State `
                                -StatusPath "$State/$(Get-FmWindowTask -Window $w -State $State).status"
                            Invoke-FmPushWake -Reason "stale: $w" -State $State
                        }
                    } elseif (Test-FmWatchPathPresent -Path $ssf) {
                        # This exact hash was already overridden as
                        # provably-working (a wedge timer is running for it) -
                        # keep treating it that way without re-reading the crew
                        # state every poll, and without letting the still
                        # captain-relevant log line re-surface it.
                        $null = Test-FmWatchWedgeTimer -Window $w -SinceFile $ssf -State $State `
                            -Label 'stale (overridden terminal status)' -EscalationFile $ewf
                    }
                    # else: already surfaced as genuinely terminal on a prior poll
                    # of this same hash - nothing left to do.
                } else {
                    # Non-terminal stale: a crew gone quiet without a
                    # captain-relevant status. Decided once per distinct stale
                    # hash (the costly state reads run only on first sight) via
                    # the pause class:
                    #   working - an actively-running pipeline legitimately sits
                    #     on a static pane (waiting on CI), so absorb and start
                    #     the wedge timer so a genuinely frozen run still
                    #     escalates past FM_STALE_ESCALATE_SECS;
                    #   paused - the crew declared an external wait, or a
                    #     declared pause/captain hold is paired with a
                    #     confidently dead agent, so absorb on the long cadence
                    #     instead of wedge-escalating;
                    #   none - no running pipeline, no exact busy verdict, no
                    #     declared pause. Surface immediately so firstmate
                    #     inspects the inconclusive state instead of leaving a
                    #     finish to wait out the timer.
                    if ((Get-FmWatchMarker -Path $sf) -cne $h) {
                        $task = Get-FmWindowTask -Window $w -State $State
                        $class = Get-FmWatchPauseStateClass -Window $w -Task $task -State $State
                        if ($class -ceq 'working') {
                            Clear-FmWatchPauseTracking -Window $w -State $State
                            Set-FmWatchMarker -Path $sf -Value $h
                            Set-FmWatchMarker -Path $ssf -Value ([string](Get-FmWatchNow)) -Newline
                            Write-FmPushTriageLog -Message "absorbed non-terminal stale (provably working): $w" -State $State
                        } elseif ($class -ceq 'paused') {
                            $null = Invoke-FmWatchPausedStale -Window $w -Task $task -Hash $h -State $State
                        } else {
                            Show-FmWatchNonterminalStale -Window $w -Hash $h -State $State
                        }
                    } else {
                        $task = Get-FmWindowTask -Window $w -State $State
                        if ((Test-FmWatchPathPresent -Path $pf) -or
                            (Test-FmStatusPausedOrHeld -Line (Get-FmLastStatusLine -Path "$State/$task.status"))) {
                            $class = Get-FmWatchPauseStateClass -Window $w -Task $task -State $State
                            if ($class -ceq 'working') {
                                Clear-FmWatchPauseState -Window $w -State $State
                                Set-FmWatchMarker -Path $sf -Value $h
                                $null = Test-FmWatchWedgeTimer -Window $w -SinceFile $ssf -State $State `
                                    -Label 'non-terminal stale (provably working after a declared pause)' -EscalationFile $ewf
                                Write-FmPushTriageLog -Message "absorbed non-terminal stale (provably working): $w" -State $State
                            } else {
                                # Both 'paused' and anything else take the
                                # bounded pause cadence here, exactly as the
                                # twin's `paused)` and `*)` arms do.
                                $null = Invoke-FmWatchPausedStale -Window $w -Task $task -Hash $h -State $State
                            }
                        } else {
                            $null = Test-FmWatchWedgeTimer -Window $w -SinceFile $ssf -State $State `
                                -Label 'non-terminal stale' -EscalationFile $ewf
                        }
                    }
                }
            } else {
                # Pane busy or not yet stably stale: reset pending escalation
                # bookkeeping, unless a genuinely busy pane has gone too long
                # with no completed turn - then route it through the same wedge
                # timer instead of erasing it.
                if ($busyNow -and (Test-FmWatchBusyTurnOverAge -Task $task -State $State)) {
                    $null = Test-FmWatchWedgeTimer -Window $w -SinceFile $ssf -State $State `
                        -Label 'busy (no completed turn)' -EscalationFile $ewf
                } else {
                    Remove-FmWatchFile -Path $ssf, $ewf
                }
                if ((Test-FmWatchPathPresent -Path $pf) -and
                    ($n -ge 2 -or -not (Test-FmStatusPausedOrHeld -Line (Get-FmLastStatusLine -Path "$State/$(Get-FmWindowTask -Window $w -State $State).status")))) {
                    Clear-FmWatchPauseTracking -Window $w -State $State
                }
            }
        } else {
            Set-FmWatchMarker -Path $hf -Value $h
            Set-FmWatchMarker -Path $cf -Value '0' -Newline
            if ($busyNow -and (Test-FmWatchBusyTurnOverAge -Task $task -State $State)) {
                $null = Test-FmWatchWedgeTimer -Window $w -SinceFile $ssf -State $State `
                    -Label 'busy (no completed turn)' -EscalationFile $ewf
            } else {
                Remove-FmWatchFile -Path $ssf, $ewf
            }
            $task = Get-FmWindowTask -Window $w -State $State
            if (-not (Test-FmWatchAfk -State $State) -and
                (Test-FmStatusPausedOrHeld -Line (Get-FmLastStatusLine -Path "$State/$task.status")) -and
                -not $busyNow) {
                if ((Get-FmWatchPauseStateClass -Window $w -Task $task -State $State) -ceq 'paused') {
                    $null = Invoke-FmWatchPausedStale -Window $w -Task $task -Hash $h -State $State
                } else {
                    Clear-FmWatchPauseTracking -Window $w -State $State
                }
            } elseif (Test-FmWatchPathPresent -Path $pf) {
                Clear-FmWatchPauseTracking -Window $w -State $State
            }
        }
    }
}

function Invoke-FmWatchHeartbeat {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The heartbeat cadence marker is written unconditionally by the bash twin on the watcher hot path; a confirmation surface would stall a non-interactive watcher.')]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$State)

    # Interval doubles per consecutive no-change heartbeat (idle fleet) up to the
    # cap, and resets on any surfaced non-heartbeat wake.
    $streak = Get-FmWatchCounter -Path "$State/.heartbeat-streak"
    if ($streak -gt 12) { $streak = 12 }
    $hb = (Get-FmWatchSetting 'Heartbeat') * [long][Math]::Pow(2, $streak)
    $max = Get-FmWatchSetting 'HeartbeatMax'
    if ($hb -gt $max) { $hb = $max }
    if ((Get-FmWatchAge -Path "$State/.last-heartbeat") -lt $hb) { return }

    if (Test-FmWatchAfk -State $State) {
        if ((Add-FmWake -Kind 'heartbeat' -Key 'heartbeat' -Payload 'heartbeat') -ne 0) { Exit-FmScript -Code 1 }
        Update-FmWatchTouch -Path "$State/.last-heartbeat"
        Invoke-FmPushWake -Reason 'heartbeat' -State $State
    } elseif (Test-FmWatchHeartbeatActionable -State $State) {
        # Backstop: a captain-relevant status the per-wake path absorbed by
        # mistake. Enqueue first, then mark every captain-relevant status
        # surfaced so the next heartbeat does not re-fire them.
        if ((Add-FmWake -Kind 'heartbeat' -Key 'heartbeat' -Payload 'heartbeat') -ne 0) { Exit-FmScript -Code 1 }
        Update-FmWatchTouch -Path "$State/.last-heartbeat"
        Set-FmWatchAllCaptainRelevantSurfaced -State $State
        Invoke-FmPushWake -Reason 'heartbeat' -State $State
    } else {
        Update-FmWatchTouch -Path "$State/.last-heartbeat"
        Set-FmWatchMarker -Path "$State/.heartbeat-streak" `
            -Value ([string]((Get-FmWatchCounter -Path "$State/.heartbeat-streak") + 1)) -Newline
        Write-FmPushTriageLog -Message 'absorbed heartbeat (no captain-relevant change)' -State $State
    }
}

<#
.SYNOPSIS
The watcher runtime: everything below the bash twin's source guard.
.DESCRIPTION
Acquires the singleton lock, publishes this watcher's identity into it, and runs
the blocking supervision loop until a wake exits the process. Never returns in
normal operation; a documented refusal exits with the bash twin's code.
#>
function Invoke-FmWatchMain {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This IS the watcher runtime; a -WhatIf/-Confirm surface on it would be meaningless and would stall supervision.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $context = Get-FmWatchContext
    $state = $context.State
    $fmHome = $context.Home
    $fmRoot = $context.Root
    $watchLock = $context.WatchLock

    # Before acquiring the watcher lock or enumerating any runnable check,
    # replace or quarantine checks created by older versions. The migration
    # compares bytes and reads data only; it never invokes legacy check files.
    $migration = $null
    try {
        # -Stream, not a capture: the bash twin runs this inline, so the
        # migration's own PR_CHECK_MIGRATION: diagnostic reaches the operator
        # and names WHY it refused. Capturing it would leave only the generic
        # "migration blocked" line, which is not actionable - and this gate is
        # reached precisely when something about the lock needs a human look.
        $migration = Invoke-FmScript -Name 'fm-pr-check-migrate' -Arguments @('--checks-safe') -Stream
    } catch {
        $migration = $null
    }
    if ($null -eq $migration -or -not $migration.Ok) {
        Write-FmErr 'watcher: PR check migration blocked; refusing to execute state checks'
        Exit-FmScript -Code 1
    }

    if (-not (Request-FmLock -LockPath $watchLock)) {
        $beat = "$state/.last-watcher-beat"
        $heldPid = Get-FmLockHeldPid
        $staleGrace = Get-FmWatchSetting 'WatcherStaleGrace'
        if (-not [string]::IsNullOrEmpty($heldPid)) {
            if (Test-FmWatchPathPresent -Path $beat) {
                $beatAge = Get-FmPathAge -Path $beat
                if ($beatAge -ge $staleGrace) {
                    Write-FmErr "watcher: lock held by live pid $heldPid but heartbeat is stale for ${beatAge}s (>${staleGrace}s); inspect or stop that watcher before re-arming."
                    Exit-FmScript -Code 1
                }
            } elseif ((Get-FmPathAge -Path $watchLock) -ge $staleGrace) {
                Write-FmErr "watcher: lock held by live pid $heldPid but no heartbeat exists; inspect or stop that watcher before re-arming."
                Exit-FmScript -Code 1
            }
            Write-FmOut "watcher: already running pid $heldPid"
        } else {
            Write-FmOut 'watcher: already running'
        }
        Exit-FmScript -Code 0
    }

    try {
        # This watcher's own pid, as recorded in the lock by the claim. Read from
        # $PID directly, never through a child, so it matches the stored holder
        # pid for the self-eviction check below.
        $watcherPid = [string]$PID
        Set-FmWatchMarker -Path "$watchLock/fm-home" -Value $context.HomeToken -Newline
        Set-FmWatchMarker -Path "$watchLock/watcher-path" -Value $context.WatchToken -Newline
        $identity = Get-FmPidIdentity -ProcessId $watcherPid
        if ([string]::IsNullOrEmpty($identity)) {
            # `fm_pid_identity ... > file || true` truncates the file even when
            # the command fails, and an EMPTY identity is what makes
            # Test-FmWatcherLockMatchesPid answer "not this watcher".
            Set-FmWatchMarker -Path "$watchLock/pid-identity" -Value ''
        } else {
            Set-FmWatchMarker -Path "$watchLock/pid-identity" -Value $identity -Newline
        }

        if (-not (Test-FmWatchPathPresent -Path "$state/.last-heartbeat")) {
            Update-FmWatchTouch -Path "$state/.last-heartbeat"
        }

        # A merged poll may have queued its terminal wake and then lost the
        # process between receipt publication and fixed-path removal. Finish only
        # identity-bound retirement receipts before any check can run.
        $recovery = $null
        try {
            $recovery = Restore-FmPrPollRetirementAll -State $state -Template 'fm-pr-poll'
        } catch {
            $recovery = $null
        }
        if ($null -ne $recovery -and -not $recovery.Ok) {
            $reason = "check: rejected unauthenticated PR poll retirement receipts:$($recovery.Rejected)"
            if ((Add-FmWake -Kind 'check' -Key 'pr-poll-retirement' -Payload $reason) -ne 0) { Exit-FmScript -Code 1 }
            Update-FmWatchTouch -Path "$state/.last-check"
            Invoke-FmPushWake -Reason $reason -State $state
        }

        while ($true) {
            # Self-eviction: if the singleton lock no longer names this process, a
            # second watcher has taken over (a transient duplicate from a racy
            # arm). Stand down so the rightful singleton continues alone. The
            # cleanup's release no-ops because the lock pid is not ours, so the
            # survivor's lock is untouched. Any duplicate self-resolves within one
            # poll instead of persisting and doubling every wake.
            if ((Get-FmWatchMarker -Path "$watchLock/pid") -ne $watcherPid) { Exit-FmScript -Code 0 }

            # Liveness beacon for fm-guard: a fresh mtime here means a watcher is
            # alive. Supervision scripts warn when this goes stale with tasks in
            # flight.
            Update-FmWatchTouch -Path "$state/.last-watcher-beat"

            # Parent-owned secondmate pending-reply reconciliation: resolve
            # correlated parent reports, observe backend busy/idle turn
            # completion, send one recovery repost after grace, and escalate once
            # if the recovery turn is also missed. No conversation scraping;
            # unresolved records are never silently expired.
            try { $null = Update-FmPendingReply -State $state } catch { $null = $_ }

            # Slow per-task checks (firstmate writes these, e.g. a merged-PR
            # poll). Time-based via .last-check mtime so the cadence survives
            # watcher restarts. Evaluated BEFORE the signal scan: a wake ENDS the
            # cycle, so a check placed after the signal scan would be starved
            # whenever a chatty sibling crewmate keeps producing signals.
            if ((Get-FmWatchAge -Path "$state/.last-check") -ge (Get-FmWatchSetting 'CheckInterval')) {
                Invoke-FmWatchCheckSweep -State $state -FmHome $fmHome -FmRoot $fmRoot
            }

            Invoke-FmWatchSignalSweep -State $state

            # Layer 1 backbone: pane staleness. Two consecutive identical hashes
            # with no busy signature means the crewmate finished, is waiting, or
            # is wedged.
            Invoke-FmWatchStaleSweep -State $state

            Invoke-FmWatchHeartbeat -State $state

            # Terminal wait: a bounded native-event wait for push-capable homes,
            # else the blind poll sleep.
            Wait-FmWatchEvent -State $state
        }
    } finally {
        # The EXIT-trap twin. Order matters: the private check snapshot is
        # removed before the lock, so a torn shutdown never leaves a readable
        # copy of a check behind an unheld lock.
        try { Remove-FmCustomCheckSnapshot } catch { $null = $_ }
        try { Unlock-FmLock -LockPath $watchLock } catch { $null = $_ }
    }
}

Export-ModuleMember -Function @(
    'Get-FmWatchContext', 'Get-FmWatchSetting',
    'Get-FmWatchMtime', 'Get-FmWatchSignature', 'Get-FmWatchAge', 'Get-FmWatchNow',
    'Get-FmWatchWindowKey', 'Test-FmWatchAfk', 'Get-FmWatchPaneHash',
    'Get-FmWatchWindowKind', 'Get-FmWatchWindowBackend', 'Get-FmWatchWindowHarness',
    'Get-FmWatchWindowLabel', 'Get-FmWatchRecordedWindow',
    'Test-FmWatchWindowBusy', 'Test-FmWatchBusyTurnOverAge',
    'Clear-FmWatchPauseState', 'Clear-FmWatchPauseTracking',
    'Test-FmWatchWedgeTimer', 'Invoke-FmWatchPausedStale', 'Get-FmWatchPauseStateClass',
    'Show-FmWatchNonterminalStale', 'Get-FmWatchChangedSignal', 'Invoke-FmWatchCheck',
    'Set-FmWatchAllCaptainRelevantSurfaced', 'Test-FmWatchHeartbeatActionable',
    'Wait-FmWatchEvent', 'Invoke-FmWatchMain', 'Resolve-FmWatchSibling'
)
