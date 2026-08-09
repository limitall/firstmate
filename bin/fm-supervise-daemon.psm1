# fm-supervise-daemon.psm1 - the presence-gated sub-supervisor: the FUNCTIONS
# half of a hybrid pair.
#
# Twin: bin/fm-supervise-daemon.sh
#
# This is the away-mode engine. It wraps the watcher, classifies every wake, and
# either SELF-HANDLES the routine majority (costing firstmate no turn at all) or
# ESCALATES a batched digest into the captain's pane. Two properties make it
# unlike any other file in this package, and every divergence below is measured
# against them:
#
#   1. SINGLETON, ABSOLUTELY. Two daemons for one home would double every
#      injection and race the escalation buffer. The lock is the whole guarantee,
#      so anything this file cannot prove it owns, it REFUSES rather than starts.
#   2. PRESENCE-GATED. It injects only while the durable away-mode flag
#      state/.afk exists. Away mode never widens approval authority: this daemon
#      never merges, never answers an ask-user finding, and never acts on a
#      crewmate's behalf - it only relays a distilled digest to the captain's
#      firstmate, which keeps every existing authority boundary.
#
# ---------------------------------------------------------------------------
# THE HYBRID SPLIT
#
# bin/fm-supervise-daemon.sh carries a `[ "${BASH_SOURCE[0]}" = "$0" ]` main
# guard so its classifiers are unit-testable while the file still executes.
# PowerShell has no such file, so the twin is a PAIR
# (docs/powershell-port.md, "Exception - hybrids"), shaped exactly like
# bin/fm-operational-input.psm1 + .ps1:
#
#   bin/fm-supervise-daemon.psm1  every function the bash file defines,
#                                 INCLUDING fm_super_main.
#   bin/fm-supervise-daemon.ps1   import, run main, exit with its code.
#
# `main` lives HERE, not in the .ps1, for the reason the exemplar records: a
# behavior reachable only through a .ps1 can be tested only by spawning a
# process per case, and pwsh startup is ~4.8s on the reference Windows host.
# With main in the module the whole startup-refusal surface is drivable
# in-process by tests/fm-daemon-psm1.test.sh.
#
# The bash file's library-mode footer (`: "${FM_WEDGE_ALARM_EXEC:=discard}"`,
# which makes it structurally impossible for a SOURCED daemon to fire a real
# desktop notification) has no place to live in a module that is always
# "sourced". It is reproduced as a call the CONSUMER makes:
# Set-FmDaemonLibraryMode, which the test suite calls at probe start. Production
# runs through the .ps1, which never calls it - exactly the bash split.
#
# ---------------------------------------------------------------------------
# WINDOWS DIVERGENCES (stated, never silently normalized)
#
#   a. SIGNALS DO NOT EXIST. The bash daemon shuts down through
#      `trap cleanup TERM INT`, and bin/fm-afk-launch.sh's `stop` delivers that
#      TERM. Windows has no SIGTERM to deliver, and a hard Stop-Process would
#      skip the cleanup that FLUSHES buffered escalations while state/.afk is
#      still present - the whole point of the stop ordering. So this twin
#      accepts a COOPERATIVE stop request in addition to a real signal:
#
#        * .NET's PosixSignalRegistration handles SIGINT/SIGTERM where the OS
#          has them (and Ctrl+C / console close on Windows);
#        * the loop also polls state/.supervise-daemon.stop each tick, which is
#          what bin/fm-afk-launch.ps1 writes before it waits.
#
#      Both paths run the SAME cleanup. Nothing else changes: the launcher still
#      waits for the pid to disappear and still refuses to clear away-mode state
#      when it does not, so a daemon that ignores the request is preserved, never
#      killed. The 143/130 exit codes a bash TERM/INT produces are NOT faked;
#      a cooperative stop exits 0, as the bash cleanup path itself does.
#      state/.supervise-daemon.* is already documented as daemon-internal state.
#
#   b. JOB CONTROL IS NOT THE WATCHDOG. wedge_alarm_run_bounded builds a
#      watchdog out of `set -m`, a process group and `kill -0 -$pid`. Invoke-FmTool
#      -TimeoutSeconds is that watchdog natively (it kills the process TREE and
#      reports 124, the same code the bash tree tests against), so the 125
#      "watchdog could not start" return has no reachable cause here.
#
#   c. `uname` IS CONSULTED WHEN PRESENT. Get-FmWedgeAlarmPlatformDefault asks
#      the real `uname` first and falls back to native platform detection only
#      where none exists. Native detection alone would answer identically on
#      every real host, but the bash twin's test seam is a FAKE uname, and a
#      twin that ignored it would diverge under exactly the suite that proves
#      the alarm is never silent.
#
#   d. A MALFORMED NUMERIC KNOB FALLS BACK TO ITS DEFAULT. bash expands
#      `${FM_STALE_ESCALATE_SECS:-240}` straight into `[ ... -ge ... ]`, so a
#      non-numeric value makes that test an arithmetic ERROR the caller reads as
#      false - i.e. the guarded work is skipped for as long as the knob stays
#      broken. Get-FmDaemonNumber instead falls back to the documented default,
#      which keeps the cadence running rather than silently disabling it. The
#      difference is reachable only from a hand-broken environment variable and
#      is recorded here rather than tested into either shape.
#
#   e. `$LOG` IS NOT DYNAMICALLY SCOPED. bash's log() reads a `local LOG` set by
#      fm_super_main - dynamic scope PowerShell does not have. The log path is
#      script-scoped state set by main and cleared by cleanup, so a function
#      called outside a running daemon logs nowhere, which is what the bash
#      twin's `${LOG:-}` guard already produced for the unit tests.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-supervise-daemon.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on any nested import: -Force REMOVES the already-loaded module
# first, and that removal is GLOBAL, so a .ps1 that imported fm-common itself
# would lose Write-FmOut the moment it imported this one (docs/powershell-port.md).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tmux-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-operational-input.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervisor-target-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1')
# The bash twin sources fm-wake-lib.sh inside fm_super_main rather than at the
# top, because only the lock protocol needs it. A PowerShell module cannot
# import conditionally into its own scope at call time without paying the import
# on a hot path, and the lock helpers take explicit paths (they never consult
# the wake context resolved at import), so importing here changes nothing
# observable.
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$script:FmOrdinal = [System.StringComparison]::Ordinal

# --- tunables ----------------------------------------------------------------
# Byte-identical to the bash twin's defaults; a value changed here changes
# away-mode cadence, so they stay in one table rather than at their use sites.

$script:FmDaemonSupportedBackends = 'tmux herdr'
$script:FmDaemonDefaults = @{
    InjectSkip           = 'heartbeat'
    StaleEscalateSecs    = 240
    EscalateBatchSecs    = 90
    HeartbeatScanSecs    = 300
    HousekeepingTick     = 15
    MaxDeferSecs         = 300
    WedgeAlarmTimeout    = 10
    InjectFailSleep      = 30
    InjectConfirmRetries = 3
    InjectConfirmSleep   = 0.5
    CrashThreshold       = 10
    CrashWindow          = 60
    CrashBackoff         = 60
    CrashNormalSleep     = 5
    LogMaxBytes          = 1048576
    LogKeepLines         = 2000
}

$script:FmAfkFlagName = '.afk'

# Mutable daemon-run state. All of it is per-process, exactly like the bash
# globals it replaces; nothing here is durable.
$script:FmDaemonLog = ''
$script:FmDaemonPrimaryHarness = ''
$script:FmWedgeAlarmLastEpoch = 0
$script:FmWedgeAlarmNotifier = $null
$script:FmDaemonStopRequested = $false
$script:FmDaemonSignalRegistrations = @()

<#
.SYNOPSIS
One daemon default, by name (the bash *_DEFAULT constants).
#>
function Get-FmDaemonDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    return [string]$script:FmDaemonDefaults[$Name]
}

<#
.SYNOPSIS
The supervisor backends this daemon has verified injection primitives for.
#>
function Get-FmDaemonSupportedBackend {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Singular already: this returns the one space-separated LIST string the bash twin holds in FM_SUPERVISOR_SUPPORTED_BACKENDS, whose spacing is load-bearing for fm_backend_list_contains.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmDaemonSupportedBackends
}

<#
.SYNOPSIS
Read a daemon knob from the environment, falling back to its default.
.DESCRIPTION
`${FM_X:-$X_DEFAULT}` with bash's `:-` semantics (an empty value is absent),
which fm-common's Get-FmEnv already owns.
#>
function Get-FmDaemonSetting {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Variable,
        [Parameter(Mandatory, Position = 1)][string]$Default
    )
    return (Get-FmEnv -Name $Variable -Default (Get-FmDaemonDefault $Default))
}

# `[ "$x" -ge "$y" ]` on values that are always numeric here. A non-numeric knob
# is a bash arithmetic error the caller reads as false; parsing failure answers
# the same way rather than throwing.
function Get-FmDaemonNumber {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][long]$Default
    )
    [long]$value = 0
    if ([long]::TryParse($Text, [ref]$value)) { return $value }
    return $Default
}

# --- context -----------------------------------------------------------------

<#
.SYNOPSIS
The daemon's resolved script dir, root, home, state and config directories.
.DESCRIPTION
The twin of the resolution block at the top of bin/fm-supervise-daemon.sh, plus
_state_root. Resolved on EVERY call rather than once at import: bash resolves at
source time, but every production invocation is a fresh process, so per-call
resolution is observationally identical there and is what lets one pwsh process
serve many fixtures in the differential suite.
#>
function Get-FmDaemonContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return (Get-FmContext -ScriptRoot $PSScriptRoot)
}

<#
.SYNOPSIS
The effective state directory (_state_root).
#>
function Get-FmDaemonStateRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-FmDaemonContext).State
}

<#
.SYNOPSIS
Now, in whole epoch seconds (_now).
#>
function Get-FmDaemonNow {
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

<#
.SYNOPSIS
Seconds since a path's mtime, or 999999 when it cannot be read (_file_age).
.DESCRIPTION
The 999999 sentinel is load-bearing: an unreadable mtime must read as ancient so
a freshness check cannot protect state nobody can measure. fm-wake-lib owns the
primitive; the daemon does not roll its own stat.
#>
function Get-FmDaemonFileAge {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return (Get-FmPathAge -Path $Path)
}

# `date '+%Y-%m-%dT%H:%M:%S%z'`. .NET's zzz renders "+05:30" where date renders
# "+0530", so the offset is composed by hand - the log lines are compared
# byte-for-byte by the differential harness.
function Get-FmDaemonTimestamp {
    param()
    $now = [DateTimeOffset]::Now
    $offset = $now.Offset
    $sign = if ($offset.Ticks -lt 0) { '-' } else { '+' }
    return ($now.ToString('yyyy-MM-ddTHH:mm:ss') +
        ('{0}{1:00}{2:00}' -f $sign, [Math]::Abs($offset.Hours), [Math]::Abs($offset.Minutes)))
}

<#
.SYNOPSIS
The lowercase MD5 hex of a string (_hash_text).
.DESCRIPTION
The bash twin shells out to md5 or md5sum depending on the platform; both print
lowercase hex of the same digest, so the in-process computation is byte-equal to
either and pays no fork.
#>
function Get-FmDaemonTextHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ($null -eq $Text) { $Text = '' }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    } finally {
        $md5.Dispose()
    }
    $sb = [System.Text.StringBuilder]::new($bytes.Length * 2)
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

# --- logging ------------------------------------------------------------------

<#
.SYNOPSIS
Append one timestamped line to the daemon log (log).
.DESCRIPTION
A no-op when no log path is set, which is the state every unit-tested function
runs in - the same thing the bash twin's `[ -n "${LOG:-}" ]` guard produces.
#>
function Write-FmDaemonLog {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrEmpty($script:FmDaemonLog)) { return }
    try {
        Add-FmFileLine -Path $script:FmDaemonLog -Line ("[{0}] {1}" -f (Get-FmDaemonTimestamp), $Message)
    } catch {
        # `>>` failing is silent in the bash twin (no `set -e`); a log write must
        # never be what takes the daemon down.
        $null = $_
    }
}

<#
.SYNOPSIS
Set (or clear) the log file every subsequent Write-FmDaemonLog appends to.
#>
function Set-FmDaemonLogPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This assigns an in-process variable, never durable state; a -WhatIf surface would be meaningless and would stall a non-interactive daemon.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    $script:FmDaemonLog = if ($null -eq $Path) { '' } else { $Path }
}

<#
.SYNOPSIS
Truncate the daemon log to its keep-lines tail once it passes its size cap.
#>
function Limit-FmDaemonLog {
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ([string]::IsNullOrEmpty($script:FmDaemonLog)) { return }
    $native = ConvertTo-FmNativePath -Path $script:FmDaemonLog
    if (-not [System.IO.File]::Exists($native)) { return }
    $size = 0L
    try { $size = ([System.IO.FileInfo]::new($native)).Length } catch { return }
    $cap = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_LOG_MAX_BYTES' 'LogMaxBytes') `
        -Default ([long](Get-FmDaemonDefault 'LogMaxBytes'))
    if ($size -lt $cap) { return }
    $keep = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_LOG_KEEP_LINES' 'LogKeepLines') `
        -Default ([long](Get-FmDaemonDefault 'LogKeepLines'))
    $lines = @(Get-FmFileLines -Path $script:FmDaemonLog)
    if ($lines.Count -gt $keep) { $lines = $lines[($lines.Count - $keep)..($lines.Count - 1)] }
    $body = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
    [void](Set-FmFileTextAtomic -Path $script:FmDaemonLog -Text $body -NoNewline)
}

# --- presence gating ----------------------------------------------------------

<#
.SYNOPSIS
True when the durable away-mode flag exists in <State> (afk_active).
#>
function Test-FmAfkActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$State)
    return (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$State/$($script:FmAfkFlagName)"))
}

<#
.SYNOPSIS
Write the durable away-mode flag (afk_enter).
#>
function Enter-FmAfk {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that writes unconditionally; a confirmation surface would diverge from it and could stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $State))
    Set-FmFileText -Path "$State/$($script:FmAfkFlagName)" -Text ([string](Get-FmDaemonNow))
}

<#
.SYNOPSIS
Clear the durable away-mode flag (afk_exit).
#>
function Exit-FmAfk {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f`; a confirmation surface would diverge from it and could strand away mode.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$State)
    Remove-FmDaemonFile -Path "$State/$($script:FmAfkFlagName)"
}

# `rm -f "$p"`: absence is success, and a refused delete is not an error the
# bash twin ever reports either.
function Remove-FmDaemonFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A private `rm -f` twin on the hot path of a polling daemon whose bash twin deletes unconditionally.')]
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath -Path $Path
    try {
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch {
        $null = $_
    }
}

<#
.SYNOPSIS
True when a message is one of firstmate's own injections (message_is_injection).
.DESCRIPTION
The landed leading-U+2063 compatibility predicate, deliberately retained in this
shape: the away-exit contract treats a marker-prefixed message as internal and
EVERYTHING else as the captain returning. Ordinal comparison is required, not
stylistic - a culture-sensitive StartsWith treats zero-width characters as
ignorable, which would let a crafted message forge the marker.
#>
function Test-FmMessageIsInjection {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message = '')

    if ([string]::IsNullOrEmpty($Message)) { return $false }
    return $Message.StartsWith((Get-FmOperationalConstant -Name 'FM_INJECT_MARK'), $script:FmOrdinal)
}

<#
.SYNOPSIS
Should this message end away mode? (should_exit_afk)
.DESCRIPTION
  away mode inactive     -> false (nothing to exit)
  carries the marker     -> false (internal escalation; stay away)
  starts with /afk       -> false (re-entering or extending away mode)
  anything else          -> TRUE  (the captain is back)
Biased toward exit on purpose: a false exit is self-correcting because the
captain simply re-runs /afk, while a false STAY leaves the captain talking to a
daemon.
#>
function Test-FmShouldExitAfk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Message = ''
    )

    if (-not (Test-FmAfkActive -State $State)) { return $false }
    if (Test-FmMessageIsInjection -Message $Message) { return $false }
    if ($null -eq $Message) { $Message = '' }
    if ($Message.StartsWith('/afk', $script:FmOrdinal)) { return $false }
    return $true
}

<#
.SYNOPSIS
Strip a current, landed-untyped, or legacy injection envelope (strip_injection_marker).
.DESCRIPTION
Current grammar is delegated to bin/fm-operational-input.psm1 rather than
re-parsed here; only the two historical prefixes are handled locally, and a
message carrying neither is returned unchanged.
#>
function Remove-FmInjectionMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A pure string transform that changes no state; Remove- is the accurate verb for stripping an envelope and no -WhatIf surface applies.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message = '')

    if ($null -eq $Message) { $Message = '' }
    $body = Get-FmOperationalInputBody -Message $Message
    if ($null -ne $body) { return $body }

    $prefix = Get-FmOperationalConstant -Name 'FM_OPERATIONAL_PREFIX'
    if ($Message.StartsWith($prefix, $script:FmOrdinal)) { return $Message.Substring($prefix.Length) }
    $mark = Get-FmOperationalConstant -Name 'FM_INJECT_MARK'
    if ($Message.StartsWith($mark, $script:FmOrdinal)) { return $Message.Substring($mark.Length) }
    return $Message
}

<#
.SYNOPSIS
Collapse every newline to " - " so a digest is one line (_collapse_newlines).
.DESCRIPTION
Submission is send-keys plus Enter, so an embedded newline would submit a
partial digest or type a stray line, depending on how the target TUI treats it.
#>
function ConvertTo-FmDaemonSingleLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ($null -eq $Text) { $Text = '' }
    return $Text.Replace("`n", ' - ')
}

# --- markers ------------------------------------------------------------------

<#
.SYNOPSIS
The marker-file key for a task or window (_stale_key).
.DESCRIPTION
`tr ':/.' '___'` - a byte-for-byte character map, not a regex, so a key
containing a regex metacharacter cannot behave differently here.
#>
function Get-FmDaemonStaleKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        if ($chars[$i] -eq ':' -or $chars[$i] -eq '/' -or $chars[$i] -eq '.') { $chars[$i] = '_' }
    }
    return [string]::new($chars)
}

# `_now > "$marker"` only when the marker is absent, so a churny idle pane that
# produces many distinct stale hashes keeps ONE stable first-seen timestamp and
# the recheck cadence stays hash-immune.
function New-FmDaemonMarkerIfAbsent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A private marker primitive whose bash twin writes unconditionally on the daemon hot path.')]
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $Path)) { return }
    Set-FmFileText -Path $Path -Text ([string](Get-FmDaemonNow))
}

<#
.SYNOPSIS
Record a wedge-aging marker for a window, if it has none (stale_marker_record).
#>
function New-FmDaemonStaleMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that writes unconditionally on the daemon hot path; a confirmation surface would stall it.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    New-FmDaemonMarkerIfAbsent -Path "$State/.subsuper-stale-$key"
}

<#
.SYNOPSIS
Drop a window's wedge-aging marker (stale_marker_remove).
#>
function Remove-FmDaemonStaleMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f` on the daemon hot path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    Remove-FmDaemonFile -Path "$State/.subsuper-stale-$key"
}

<#
.SYNOPSIS
Record a declared-pause marker for a window, if it has none (pause_marker_record).
#>
function New-FmDaemonPauseMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that writes unconditionally on the daemon hot path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    New-FmDaemonMarkerIfAbsent -Path "$State/.subsuper-paused-$key"
}

<#
.SYNOPSIS
Drop a window's declared-pause marker (pause_marker_remove).
#>
function Remove-FmDaemonPauseMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f` on the daemon hot path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    Remove-FmDaemonFile -Path "$State/.subsuper-paused-$key"
}

<#
.SYNOPSIS
Drop every pause and wedge tracking artifact for a window (clear_pause_tracking).
.DESCRIPTION
Both namespaces are cleared: the daemon's own task-keyed markers AND the
watcher's window-keyed ones, because a pane that resumed must not keep aging in
either.
#>
function Clear-FmDaemonPauseTracking {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash `rm -f` list on the daemon hot path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    $watcherKey = Get-FmDaemonStaleKey $Window
    foreach ($name in @(
            ".subsuper-paused-$key", ".subsuper-stale-$key",
            ".paused-$watcherKey", ".paused-rechecked-$watcherKey", ".paused-resurfaced-$watcherKey",
            ".stale-$watcherKey", ".stale-since-$watcherKey", ".wedge-escalations-$watcherKey")) {
        Remove-FmDaemonFile -Path "$State/$name"
    }
}

<#
.SYNOPSIS
Bring pause and wedge markers in line with a status line (reconcile_pause_tracking).
#>
function Sync-FmDaemonPauseTracking {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash marker reconciler that writes unconditionally on the daemon hot path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$State,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Last = ''
    )

    $key = Get-FmDaemonStaleKey (Get-FmWindowTask -Window $Window -State $State)
    $marker = "$State/.subsuper-paused-$key"
    $watcherKey = Get-FmDaemonStaleKey $Window
    if (Test-FmStatusPaused -Line $Last) {
        Remove-FmDaemonStaleMarker -Window $Window -State $State
        New-FmDaemonPauseMarker -Window $Window -State $State
        return
    }
    if ((Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $marker)) -or
        (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$State/.paused-$watcherKey"))) {
        Clear-FmDaemonPauseTracking -Window $Window -State $State
    }
}

# `for f in "$dir"/<prefix>*` with the `[ -e ]` guard: a directory that does not
# exist, or a pattern that matches nothing, is an empty list. Returned as NAMES
# so a caller composes the path the same way bash does.
function Get-FmDaemonStateFileName {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Matches Get-FmClassifyGlobName, the sibling this mirrors: the plural would read as a set type where this yields one name per pipeline item.')]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter()][AllowEmptyString()][string]$Suffix = ''
    )
    $native = ConvertTo-FmNativePath -Path $State
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($path in [System.IO.Directory]::EnumerateFileSystemEntries($native)) {
        $name = [System.IO.Path]::GetFileName($path)
        if (-not $name.StartsWith($Prefix, $script:FmOrdinal)) { continue }
        if ($Suffix -ne '' -and -not $name.EndsWith($Suffix, $script:FmOrdinal)) { continue }
        $names.Add($name)
    }
    # bash globs expand in collation order; the differential suite compares
    # ordered output, so the enumeration is sorted rather than left to the
    # filesystem.
    $names.Sort([System.StringComparer]::Ordinal)
    return $names.ToArray()
}

<#
.SYNOPSIS
Reconcile pause tracking for every recorded task (migrate_watcher_pause_markers).
#>
function Sync-FmDaemonWatcherPauseMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash marker migration that writes unconditionally at daemon start and every housekeeping tick.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    foreach ($name in @(Get-FmDaemonStateFileName -State $State -Prefix '' -Suffix '.meta')) {
        # A leading-dot name is invisible to a bash `*` glob, so it must stay
        # invisible here too.
        if ($name.StartsWith('.', $script:FmOrdinal)) { continue }
        $meta = "$State/$name"
        $window = Get-FmBackendTargetOfMeta -MetaPath $meta
        if ([string]::IsNullOrEmpty($window)) { continue }
        $task = $name.Substring(0, $name.Length - '.meta'.Length)
        $key = Get-FmDaemonStaleKey $task
        $watcherKey = Get-FmDaemonStaleKey $window
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        if ((Test-FmStatusPaused -Line $last) -or
            (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$State/.subsuper-paused-$key")) -or
            (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$State/.paused-$watcherKey"))) {
            Sync-FmDaemonPauseTracking -Window $window -State $State -Last $last
        }
    }
}

# `read -r -a files <<<"$paths"` - split on IFS whitespace, dropping empties.
function Split-FmDaemonWords {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural matches the return shape and the bash name this must stay greppable against: it yields ALL words of the input as an array, and the singular form would read as split-one-word.')]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @($Text.Split([char[]]" `t`n`r".ToCharArray(), [System.StringSplitOptions]::RemoveEmptyEntries))
}

<#
.SYNOPSIS
Reconcile pause markers for the status files named by a signal wake
(sync_pause_markers_from_signal).
#>
function Sync-FmDaemonSignalPauseMarker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash marker reconciler that writes unconditionally on the daemon wake path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Paths = ''
    )

    foreach ($file in @(Split-FmDaemonWords -Text $Paths)) {
        if (-not $file.EndsWith('.status', $script:FmOrdinal)) { continue }
        if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $file))) { continue }
        $last = Get-FmLastStatusLine -Path $file
        $task = [System.IO.Path]::GetFileName($file)
        $task = $task.Substring(0, $task.Length - '.status'.Length)
        $window = Get-FmDaemonWindowForTask -Key (Get-FmDaemonStaleKey $task) -State $State
        if ([string]::IsNullOrEmpty($window)) { continue }
        Sync-FmDaemonPauseTracking -Window $window -State $State -Last $last
    }
}

<#
.SYNOPSIS
Record that a captain-relevant status line has already been escalated (mark_status_seen).
.DESCRIPTION
The single source of truth shared by the per-wake classifier and the heartbeat
catch-all scan, which is what stops one terminal status appearing twice in one
digest.
#>
function Set-FmDaemonStatusSeen {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash write on the daemon escalate path; a confirmation surface would stall a non-interactive daemon.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Task,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Line = ''
    )
    # `printf '%s' "$line" >` - no trailing newline, so the read-back comparison
    # against a status line is byte-exact.
    Set-FmFileText -Path "$State/.subsuper-seen-status-$(Get-FmDaemonStaleKey $Task)" `
        -Text ([string]$Line) -NoNewline
}

# `[ "$(cat "$seen" 2>/dev/null || true)" = "$last" ]`. Command substitution
# strips trailing newlines, so the comparison is against the trimmed content.
function Get-FmDaemonStatusSeen {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Task
    )
    $text = Get-FmFileText -Path "$State/.subsuper-seen-status-$(Get-FmDaemonStaleKey $Task)"
    return $text.TrimEnd("`n")
}

<#
.SYNOPSIS
Mark every captain-relevant line a wake escalated as seen (mark_escalated_seen).
#>
function Set-FmDaemonEscalatedSeen {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash write on the daemon escalate path.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Kind,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Argument = '',
        [Parameter(Mandatory, Position = 2)][string]$State
    )

    if ([string]::Equals($Kind, 'signal', $script:FmOrdinal)) {
        foreach ($file in @(Split-FmDaemonWords -Text $Argument)) {
            if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $file))) { continue }
            $last = Get-FmLastStatusLine -Path $file
            if ([string]::IsNullOrEmpty($last)) { continue }
            if (-not (Test-FmStatusCaptainRelevant -Line $last)) { continue }
            $task = [System.IO.Path]::GetFileName($file)
            if ($task.EndsWith('.status', $script:FmOrdinal)) {
                $task = $task.Substring(0, $task.Length - '.status'.Length)
            }
            Set-FmDaemonStatusSeen -State $State -Task $task -Line $last
        }
        return
    }
    if ([string]::Equals($Kind, 'stale', $script:FmOrdinal)) {
        $task = Get-FmWindowTask -Window $Argument -State $State
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusCaptainRelevant -Line $last)) {
            Set-FmDaemonStatusSeen -State $State -Task $task -Line $last
        }
    }
}

# --- classification -----------------------------------------------------------
#
# Every classifier answers one string, "<action>|<distilled>", where action is
# self, escalate or pause. The distilled half is informational for self and is
# the pre-read summary firstmate would otherwise have to fetch for escalate.

<#
.SYNOPSIS
Classify a signal wake (classify_signal).
.DESCRIPTION
Escalates when any named status is captain-relevant AND has not already been
escalated by the catch-all scan. all_seen stays true only if EVERY relevant file
was already seen, which is what keeps one terminal event out of two digests.
#>
function Get-FmDaemonSignalDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    $distilled = ''
    $relevant = $false
    $allSeen = $true
    foreach ($file in @(Split-FmDaemonWords -Text $Reason)) {
        if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $file))) { continue }
        $last = Get-FmLastStatusLine -Path $file
        if ([string]::IsNullOrEmpty($last)) { continue }
        $distilled += "$([System.IO.Path]::GetFileName($file)): $last | "
        if (-not (Test-FmStatusCaptainRelevant -Line $last)) { continue }
        $relevant = $true
        $task = [System.IO.Path]::GetFileName($file)
        if ($task.EndsWith('.status', $script:FmOrdinal)) {
            $task = $task.Substring(0, $task.Length - '.status'.Length)
        }
        if ((Get-FmDaemonStatusSeen -State $State -Task $task) -cne $last) { $allSeen = $false }
    }
    if ($distilled.EndsWith(' | ', $script:FmOrdinal)) {
        $distilled = $distilled.Substring(0, $distilled.Length - 3)
    }
    if (-not $relevant) { return "self|routine signal: $distilled" }
    if ($allSeen) { return "self|signal already escalated (catch-all scan): $distilled" }
    return "escalate|$distilled"
}

<#
.SYNOPSIS
Classify a stale wake (classify_stale).
.DESCRIPTION
A DECLARED pause is not a wedge: its pane is idle by design, so it answers
`pause` and gets the long re-surface cadence instead of wedge aging. A
non-terminal progress verb (working / resolved / captain-held) never takes the
terminal path even when its free text looks captain-relevant, because
seen-status dedupe must not permanently suppress genuine wedge aging.
#>
function Get-FmDaemonStaleDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Window = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    $task = Get-FmWindowTask -Window $Window -State $State
    $last = Get-FmLastStatusLine -Path "$State/$task.status"

    if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusPaused -Line $last)) {
        return "pause|paused (awaiting external), rechecked on a long cadence: $last"
    }

    if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusCaptainRelevant -Line $last)) {
        if (-not (Test-FmStatusTerminalVerb -Line $last)) {
            $verb = Get-FmStatusLineVerb -Line $last
            if ($verb -cin @('working', 'resolved', 'captain-held')) {
                return "self|transient stale ($Window): $last"
            }
        }
        if ((Get-FmDaemonStatusSeen -State $State -Task $task) -ceq $last) {
            return "self|stale + terminal (already escalated by signal): $last"
        }
        return "escalate|stale + terminal status: $last"
    }

    $detail = if ([string]::IsNullOrEmpty($last)) { 'no status' } else { $last }
    return "self|transient stale ($Window): $detail"
}

<#
.SYNOPSIS
Classify a check wake (classify_check) - always escalate.
.DESCRIPTION
A registered check prints only when firstmate should wake, so its output is a
decision already made.
#>
function Get-FmDaemonCheckDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '')
    return "escalate|$Reason"
}

<#
.SYNOPSIS
Classify a heartbeat wake (classify_heartbeat) - always self-handle.
#>
function Get-FmDaemonHeartbeatDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'self|heartbeat (catch-all scan runs in housekeeping)'
}

<#
.SYNOPSIS
Classify an unrecognized wake (classify_unknown) - escalate, fail-safe.
#>
function Get-FmDaemonUnknownDecision {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '')
    return "escalate|unknown wake: $Reason"
}

<#
.SYNOPSIS
True when a line from the watcher is a real WAKE rather than a status line
(is_wake_reason).
.DESCRIPTION
Load-bearing: a watcher singleton collision prints "watcher: already running" on
stdout, and treating that as an unknown wake would flood the escalation buffer
and restart the child with no crash backoff.
#>
function Test-FmDaemonWakeReason {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '')

    if ([string]::IsNullOrEmpty($Reason)) { return $false }
    foreach ($prefix in @('signal:', 'stale:', 'check:', 'heartbeat:')) {
        if ($Reason.StartsWith($prefix, $script:FmOrdinal)) { return $true }
    }
    return [string]::Equals($Reason, 'heartbeat', $script:FmOrdinal)
}

<#
.SYNOPSIS
True when FM_INJECT_SKIP forces a wake to self-handle (should_force_self).
.DESCRIPTION
Literal `|`-separated PREFIXES, never a regex - a captain who sets
FM_INJECT_SKIP='check:' must not have it read as a character class.
#>
function Test-FmDaemonForceSelf {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '')

    $skip = Get-FmDaemonSetting 'FM_INJECT_SKIP' 'InjectSkip'
    if ([string]::IsNullOrEmpty($skip)) { return $false }
    if ($null -eq $Reason) { $Reason = '' }
    foreach ($prefix in @($skip.Split('|'))) {
        if ([string]::IsNullOrEmpty($prefix)) { continue }
        if ($Reason.StartsWith($prefix, $script:FmOrdinal)) { return $true }
    }
    return $false
}

# --- pane and task state ------------------------------------------------------

<#
.SYNOPSIS
The detected primary harness, resolved once per process (fm_daemon_primary_harness).
.DESCRIPTION
Harness detection walks process ancestry, which is far too heavy to pay on every
import - the unit tests and the launcher load this module purely for its pure
functions.
#>
function Get-FmDaemonPrimaryHarness {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrEmpty($script:FmDaemonPrimaryHarness)) {
        $harness = 'unknown'
        try {
            $result = Invoke-FmScript -Name 'fm-harness' -BinDir $PSScriptRoot
            if ($result.Ok) { $harness = $result.StdOut.Trim() }
        } catch {
            $harness = 'unknown'
        }
        if ([string]::IsNullOrEmpty($harness)) { $harness = 'unknown' }
        $script:FmDaemonPrimaryHarness = $harness
    }
    return $script:FmDaemonPrimaryHarness
}

<#
.SYNOPSIS
True when the supervisor pane is mid-turn (pane_is_busy).
.DESCRIPTION
The native semantic verdict wins outright; otherwise the last 12 non-blank lines
of a 40-line capture are matched against the DETECTED primary harness's busy
signature, so output from another harness cannot make the primary read busy.
An unreadable pane is not busy - the composer guard downstream is what refuses
an unsafe target.
#>
function Test-FmDaemonPaneBusy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Backend = 'tmux'
    )

    if ([string]::IsNullOrEmpty($Backend)) { $Backend = 'tmux' }
    $harness = Get-FmDaemonPrimaryHarness
    if ([string]::Equals((Get-FmBackendBusyState -Backend $Backend -Target $Target), 'busy', $script:FmOrdinal)) {
        return $true
    }
    $tail = Get-FmBackendCapture -Backend $Backend -Target $Target -Lines '40'
    if ($null -eq $tail) { return $false }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($tail -split "`n")) {
        if ($line.Trim() -eq '') { continue }
        $lines.Add($line)
    }
    if ($lines.Count -gt 12) { $lines = $lines.GetRange($lines.Count - 12, 12) }
    if ($lines.Count -eq 0) { return $false }
    return (Test-FmTmuxBusyLine -Text ($lines -join "`n") -Harness $harness)
}

<#
.SYNOPSIS
True unless the composer is positively proven empty (pane_input_pending).
.DESCRIPTION
Real unsubmitted text, ambiguous structure, an unreadable pane and any future
verdict all count as pending: only an exact `empty` is a safe injection target.
#>
function Test-FmDaemonPaneInputPending {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Backend = 'tmux'
    )

    if ([string]::IsNullOrEmpty($Backend)) { $Backend = 'tmux' }
    return (-not [string]::Equals(
        (Get-FmBackendComposerState -Backend $Backend -Target $Target), 'empty', $script:FmOrdinal))
}

<#
.SYNOPSIS
The recorded backend of the task owning a window (task_window_backend).
#>
function Get-FmDaemonTaskBackend {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Window = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $task = Get-FmWindowTask -Window $Window -State $State
    return (Get-FmBackendOfMeta -MetaPath "$State/$task.meta")
}

<#
.SYNOPSIS
The recorded harness of the task owning a window (task_window_harness).
#>
function Get-FmDaemonTaskHarness {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Window = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $task = Get-FmWindowTask -Window $Window -State $State
    return (Get-FmMetaValue "$State/$task.meta" 'harness')
}

<#
.SYNOPSIS
Is the task behind a stale window provably working? (stale_window_is_busy)
.DESCRIPTION
Returns the bash exit code as an integer:
  0  provably busy through the semantic busy-state contract
  1  not busy
  2  the endpoint could not be read at all
Only an exact `busy` verdict counts as working. An unknown semantic state never
becomes busy and never becomes a silent idle, so a pane whose state cannot be
proven surfaces instead of disappearing.
#>
function Get-FmDaemonStaleWindowBusy {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Window = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    $backend = Get-FmDaemonTaskBackend -Window $Window -State $State
    $harness = Get-FmDaemonTaskHarness -Window $Window -State $State
    $task = Get-FmWindowTask -Window $Window -State $State
    $tail = Get-FmBackendCapture -Backend $backend -Target $Window -Lines '40' -ExpectedLabel "fm-$task"
    if ($null -eq $tail) { return 2 }
    $verdict = Get-FmBusyClassification -Backend $backend -Target $Window -Harness $harness `
        -Id $task -StateDir $State -Tail $tail
    if ($null -eq $verdict) { $verdict = '' }
    $head = ($verdict -split ' ', 2)[0]
    if ([string]::Equals($head, 'busy', $script:FmOrdinal)) { return 0 }
    return 1
}

<#
.SYNOPSIS
The backend target of the task whose marker key matches (window_for_task).
.DESCRIPTION
Recorded metadata first; the live tmux window list is the legacy fallback for
markers written before meta lookup existed. Empty when nothing matches, which
the callers read as "the task is gone, drop the marker".
#>
function Get-FmDaemonWindowForTask {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Key,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State = ''
    )

    if ([string]::IsNullOrEmpty($State)) { $State = Get-FmDaemonStateRoot }
    foreach ($name in @(Get-FmDaemonStateFileName -State $State -Prefix '' -Suffix '.meta')) {
        if ($name.StartsWith('.', $script:FmOrdinal)) { continue }
        $task = $name.Substring(0, $name.Length - '.meta'.Length)
        if ((Get-FmDaemonStaleKey $task) -cne $Key) { continue }
        $window = Get-FmBackendTargetOfMeta -MetaPath "$State/$name"
        if (-not [string]::IsNullOrEmpty($window)) { return $window }
    }

    $result = $null
    try {
        $result = Invoke-FmTool -FilePath 'tmux' `
            -Arguments @('list-windows', '-a', '-F', '#{session_name}:#{window_name}')
    } catch {
        return ''
    }
    if ($null -eq $result -or -not $result.Ok) { return '' }
    foreach ($window in @(Split-FmDaemonWords -Text $result.StdOut)) {
        if ($window.IndexOf(':fm-', $script:FmOrdinal) -lt 0) { continue }
        $task = Get-FmWindowTask -Window $window -State $State
        if ((Get-FmDaemonStaleKey $task) -ceq $Key) { return $window }
    }
    return ''
}

# --- escalation buffer --------------------------------------------------------

<#
.SYNOPSIS
Append one distilled item to the escalation buffer (escalate_add).
.DESCRIPTION
The `.since` sidecar records when the OLDEST currently-buffered item arrived,
and is written only when the buffer was empty, so the batch window measures the
age of the batch rather than of its newest member.
#>
function Add-FmDaemonEscalation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash append on the daemon escalate path; a confirmation surface would stall a non-interactive daemon and could drop an escalation.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Item = ''
    )

    $buffer = "$State/.subsuper-escalations"
    if (-not (Test-FmDaemonFileNonEmpty -Path $buffer)) {
        Set-FmFileText -Path "$buffer.since" -Text ([string](Get-FmDaemonNow))
    }
    Add-FmFileLine -Path $buffer -Line ([string]$Item)
}

# `[ -s "$f" ]`: exists and is larger than zero bytes.
function Test-FmDaemonFileNonEmpty {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath -Path $Path
    if (-not [System.IO.File]::Exists($native)) { return $false }
    try { return (([System.IO.FileInfo]::new($native)).Length -gt 0) } catch { return $false }
}

<#
.SYNOPSIS
Seconds since the oldest buffered escalation arrived (_oldest_line_age).
.DESCRIPTION
999999 for an empty buffer or a missing sidecar, so an unmeasurable batch reads
as overdue rather than as fresh.
#>
function Get-FmDaemonOldestEscalationAge {
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-FmDaemonFileNonEmpty -Path $Path)) { return 999999 }
    $since = "$Path.since"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath -Path $since))) { return 999999 }
    $text = (Get-FmFileText -Path $since).Trim()
    return ((Get-FmDaemonNow) - (Get-FmDaemonNumber -Text $text -Default 0))
}

<#
.SYNOPSIS
Flush the whole buffer as ONE batched single-line digest (escalate_flush).
.DESCRIPTION
Returns true on a confirmed inject (or an empty buffer) and false when the
inject could not be confirmed - in which case the buffer is PRESERVED, so the
escalation survives for the next cycle or the return catch-up.
#>
function Send-FmDaemonEscalationDigest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash flush on the daemon delivery path; a confirmation surface would stall a non-interactive daemon.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    $buffer = "$State/.subsuper-escalations"
    if (-not (Test-FmDaemonFileNonEmpty -Path $buffer)) { return $true }
    $text = Get-FmFileText -Path $buffer
    # `wc -l` counts NEWLINES, which is what the digest's "<n> event(s)" reports -
    # deliberately not the record count, so an unterminated final line reads the
    # same here as it does there.
    $count = 0
    foreach ($ch in $text.ToCharArray()) { if ($ch -eq "`n") { $count++ } }
    # The awk join keeps EVERY record, including an empty one, so the line list
    # comes from the reader that drops only the trailing-newline artifact.
    $joined = @(Get-FmFileLines -Path $buffer) -join ' | '
    $message = "Supervisor escalate ($count event(s)): $joined (pre-read; re-arm not needed " +
        [char]0x2014 + " watcher daemon-managed)"
    if (-not (Send-FmDaemonInjection -Message $message -State $State)) { return $false }
    Set-FmFileText -Path $buffer -Text '' -NoNewline
    Remove-FmDaemonFile -Path "$buffer.since"
    Remove-FmDaemonFile -Path "$State/.subsuper-inject-wedged"
    return $true
}

# --- wedge alarm --------------------------------------------------------------
#
# The daemon must NEVER wedge silently. The durable marker plus the log line are
# the primary signal; these channels add a BACKEND-INDEPENDENT active alert that
# reaches a captain whose primary pane and its status line are both unreadable -
# the gap a real overnight incident fell through, where 20 escalations sat
# buffered for 8.5 hours behind a passive marker nothing surfaced.

<#
.SYNOPSIS
The configured active-alert channel directives, one per line
(wedge_alarm_configured_channels).
.DESCRIPTION
FM_WEDGE_ALARM_CHANNEL wins as a single directive; otherwise every non-empty,
non-comment line of config/wedge-alarm; otherwise `auto`. An ABSENT config means
auto, i.e. default-ON where the platform has an OS channel, because the alarm's
whole purpose is to never be silent.
#>
function Get-FmWedgeAlarmChannel {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the return shape: this yields every configured directive. The singular would read as fetch-the-one-channel, which is exactly the misreading that would drop a captain-configured fallback.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $override = Get-FmEnv -Name 'FM_WEDGE_ALARM_CHANNEL'
    if ($override -ne '') { return @($override) }

    $config = (Get-FmDaemonContext).Config
    $channels = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-FmFileLines -Path "$config/wedge-alarm")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        if ($trimmed.StartsWith('#', $script:FmOrdinal)) { continue }
        $channels.Add($trimmed)
    }
    if ($channels.Count -eq 0) { return @('auto') }
    return $channels.ToArray()
}

<#
.SYNOPSIS
True when Windows has a reachable notifier transport
(wedge_alarm_windows_notifier_available).
.DESCRIPTION
Windows has no single always-present notifier the way macOS has osascript, so
`auto` resolves as long as either transport exists.
#>
function Test-FmWedgeAlarmWindowsNotifier {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Test-FmCommand -Name 'powershell.exe') { return $true }
    return (Test-FmCommand -Name 'msg.exe')
}

<#
.SYNOPSIS
The platform's default OS-level channel for `auto` (wedge_alarm_platform_default).
.DESCRIPTION
macOS reaches the captain through a Notification Center banner and Windows
through a desktop toast; every other platform has none built in and returns ''
so wedge_alarm_notify can say the durable marker is the only signal.

`uname` is consulted FIRST where it exists, and native platform detection is the
fallback. Both answer identically on every real host, but the bash twin's test
seam is a FAKE uname, and a twin that ignored it would diverge under exactly the
suite that proves this alarm is never silent (divergence (c) in the header).
#>
function Get-FmWedgeAlarmPlatformDefault {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $kernel = ''
    if (Test-FmCommand -Name 'uname') {
        try {
            $result = Invoke-FmTool -FilePath 'uname' -Arguments @() -TimeoutSeconds 10
            if ($result.Ok) { $kernel = $result.StdOut.Trim() }
        } catch {
            $kernel = ''
        }
    }
    if ($kernel -eq '') {
        if ($IsMacOS) { $kernel = 'Darwin' }
        elseif (Test-FmWindows) { $kernel = 'MINGW64_NT-native' }
        else { $kernel = 'Linux' }
    }

    if ([string]::Equals($kernel, 'Darwin', $script:FmOrdinal)) {
        if (Test-FmCommand -Name 'osascript') { return 'osascript' }
        return ''
    }
    foreach ($prefix in @('MINGW', 'MSYS', 'CYGWIN')) {
        if ($kernel.StartsWith($prefix, $script:FmOrdinal)) {
            if (Test-FmWedgeAlarmWindowsNotifier) { return 'powershell' }
            return ''
        }
    }
    return ''
}

# The `uname` spelling used in the "no OS-level channel" diagnostic, so the
# message names the same platform string the bash twin would print.
function Get-FmDaemonKernelName {
    param()
    if (Test-FmCommand -Name 'uname') {
        try {
            $result = Invoke-FmTool -FilePath 'uname' -Arguments @() -TimeoutSeconds 10
            if ($result.Ok) { return $result.StdOut.Trim() }
        } catch {
            $null = $_
        }
    }
    if ($IsMacOS) { return 'Darwin' }
    if (Test-FmWindows) { return 'Windows_NT' }
    return 'Linux'
}

<#
.SYNOPSIS
Run one notifier under a watchdog (wedge_alarm_run_bounded).
.DESCRIPTION
Returns the notifier's exit code, or 124 when it exceeded
FM_WEDGE_ALARM_TIMEOUT_SECS and its process tree was killed - the same code the
bash `timeout` convention uses. Invoke-FmTool IS the watchdog here, so the bash
twin's 125 "watchdog could not start" return has no reachable cause
(divergence (b)).

The running process is published so Stop-FmWedgeAlarmNotifier can end it from
the shutdown path, which is the only thing that stops a slow notifier delaying
the daemon's own exit.
#>
function Invoke-FmWedgeAlarmBounded {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Channel,
        [Parameter(Mandatory, Position = 1)][string]$FilePath,
        [Parameter(Position = 2)][AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter()][AllowEmptyString()][AllowNull()][string]$StdIn
    )

    $timeout = Get-FmDaemonNumber -Text (Get-FmEnv -Name 'FM_WEDGE_ALARM_TIMEOUT_SECS') `
        -Default ([long](Get-FmDaemonDefault 'WedgeAlarmTimeout'))
    if ($timeout -le 0) { $timeout = [long](Get-FmDaemonDefault 'WedgeAlarmTimeout') }

    $invokeArgs = @{
        FilePath       = $FilePath
        Arguments      = $Arguments
        TimeoutSeconds = [int]$timeout
    }
    if ($PSBoundParameters.ContainsKey('StdIn')) { $invokeArgs['StdIn'] = [string]$StdIn }

    $script:FmWedgeAlarmNotifier = $Channel
    try {
        $result = Invoke-FmTool @invokeArgs
    } catch {
        $script:FmWedgeAlarmNotifier = $null
        Write-FmDaemonLog "wedge alarm: ${Channel} notifier could not be started"
        return 127
    } finally {
        $script:FmWedgeAlarmNotifier = $null
    }
    if ($result.ExitCode -eq 124) {
        Write-FmDaemonLog "wedge alarm: ${Channel} notifier timed out (limit ${timeout}s)"
    }
    return $result.ExitCode
}

<#
.SYNOPSIS
End a notifier still running at shutdown (wedge_alarm_stop_active_notifier).
.DESCRIPTION
Invoke-FmTool owns its child's lifetime and kills the whole tree on timeout, so
there is no orphan for this to reap; it clears the published channel so a
shutdown that races a notifier leaves no stale record. Kept as a named function
because the bash cleanup path calls it first and a reader comparing the two
files must find it.
#>
function Stop-FmWedgeAlarmNotifier {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A shutdown-path primitive whose bash twin kills unconditionally; a confirmation surface would stall the daemon exit it exists to make prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()
    $script:FmWedgeAlarmNotifier = $null
}

# The FM_WEDGE_ALARM_EXEC seam and the `command:` channel both name a program
# the CAPTAIN chose, which on this platform is usually a shell script. MSYS bash
# honors a shebang; .NET does not, and would refuse the file outright. So a
# script-shaped target is routed through Git Bash, which is what the bash twin's
# own exec would have done. Anything else runs directly.
function Get-FmDaemonProgramInvocation {
    param(
        [Parameter(Mandatory)][string]$Program,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    $extension = ''
    try { $extension = [System.IO.Path]::GetExtension($Program) } catch { $extension = '' }
    $directExtensions = @('.exe', '.com', '.bat', '.cmd', '.ps1')
    $isDirect = (-not (Test-FmWindows)) -or ($extension -ne '' -and $directExtensions -contains $extension.ToLowerInvariant())
    if ($isDirect) { return @{ FilePath = $Program; Arguments = $Arguments } }
    $bash = Get-FmBash
    if (-not $bash) { return @{ FilePath = $Program; Arguments = $Arguments } }
    return @{
        FilePath  = $bash
        Arguments = @((ConvertTo-FmPosixPath -Path $Program)) + $Arguments
    }
}

<#
.SYNOPSIS
The FM_WEDGE_ALARM_EXEC notifier seam (wedge_alarm_os_notifier_override).
.DESCRIPTION
Returns 2 when no override is set (the caller then runs the real notifier), 0
when the override is `discard` or ran cleanly, and 1 when it failed. This is the
one injection point the test harness forces to a recorder, and
Set-FmDaemonLibraryMode defaults it to `discard` so no test can post a real
desktop notification.
#>
function Invoke-FmWedgeAlarmOverride {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Channel,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Summary = ''
    )

    $override = Get-FmEnv -Name 'FM_WEDGE_ALARM_EXEC'
    if ($override -eq '') { return 2 }
    if ([string]::Equals($override, 'discard', $script:FmOrdinal)) { return 0 }
    $invocation = Get-FmDaemonProgramInvocation -Program $override -Arguments @($Channel, [string]$Summary)
    $rc = Invoke-FmWedgeAlarmBounded -Channel $Channel -FilePath $invocation.FilePath -Arguments $invocation.Arguments
    if ($rc -eq 0) { return 0 }
    Write-FmDaemonLog "wedge alarm: notifier override exited $rc for channel '$Channel'"
    return 1
}

<#
.SYNOPSIS
Post a macOS Notification Center banner (wedge_alarm_via_osascript).
.DESCRIPTION
OS-level and independent of any pane or multiplexer status line. The summary is
an argv item, never interpolated into the AppleScript source, so its text can
never break the script.
#>
function Send-FmWedgeAlarmOsascript {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Summary = '')

    $rc = Invoke-FmWedgeAlarmOverride -Channel 'osascript' -Summary $Summary
    if ($rc -eq 0) { return $true }
    if ($rc -eq 1) { return $false }
    if (-not (Test-FmCommand -Name 'osascript')) {
        Write-FmDaemonLog 'wedge alarm: osascript not found; cannot post a macOS notification'
        return $false
    }
    $script = @(
        '-e', 'on run argv'
        '-e', 'display notification (item 1 of argv) with title "firstmate: away-mode escalations WEDGED" sound name "Basso"'
        '-e', 'end run'
        [string]$Summary
    )
    if ((Invoke-FmWedgeAlarmBounded -Channel 'osascript' -FilePath 'osascript' -Arguments $script) -eq 0) {
        return $true
    }
    Write-FmDaemonLog 'wedge alarm: osascript notification failed'
    return $false
}

# The toast script, as ONE PowerShell line, byte-identical to the bash twin's
# WEDGE_ALARM_PS_TOAST. Stock Windows.UI.Notifications only - no third-party
# module is assumed - and a notifier that is not `Enabled` exits 3 rather than
# posting a toast nobody will see, which is what lets the msg.exe transport take
# over instead of reporting a false success.
$script:FmWedgeAlarmToast = '$ErrorActionPreference = "Stop"; ' +
'try { ' +
'$body = $env:FM_WEDGE_ALARM_SUMMARY; if (-not $body) { $body = "(no detail)" }; ' +
'[void][Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]; ' +
'[void][Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom,ContentType=WindowsRuntime]; ' +
'$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(' +
'"{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"); ' +
'if ($notifier.Setting -ne "Enabled") { exit 3 }; ' +
'$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(' +
'[Windows.UI.Notifications.ToastTemplateType]::ToastText02); ' +
'$text = $xml.GetElementsByTagName("text"); ' +
'[void]$text.Item(0).AppendChild($xml.CreateTextNode("firstmate: away-mode escalations WEDGED")); ' +
'[void]$text.Item(1).AppendChild($xml.CreateTextNode($body)); ' +
'$notifier.Show((New-Object Windows.UI.Notifications.ToastNotification $xml)); ' +
'exit 0 } catch { exit 4 }'

<#
.SYNOPSIS
The Windows toast script text, for a caller that needs to assert on it.
#>
function Get-FmWedgeAlarmToastScript {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmWedgeAlarmToast
}

<#
.SYNOPSIS
Post a Windows desktop notification (wedge_alarm_via_powershell).
.DESCRIPTION
Two stock-only transports in order, each under the same watchdog every channel
uses: a Windows.UI.Notifications toast (which also lands in the Action Center,
so it survives an unattended desktop), then msg.exe.

The summary crosses into the notifier through the ENVIRONMENT and is never
interpolated into the script source. The bash twin additionally sets
MSYS2_ARG_CONV_EXCL to stop MSYS rewriting the script text; there is no MSYS
layer between this process and powershell.exe, so that guard has nothing to do
here and is dropped rather than carried as cargo.
#>
function Send-FmWedgeAlarmPowershell {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Summary = '')

    $rc = Invoke-FmWedgeAlarmOverride -Channel 'powershell' -Summary $Summary
    if ($rc -eq 0) { return $true }
    if ($rc -eq 1) { return $false }

    if (Test-FmCommand -Name 'powershell.exe') {
        $previous = [Environment]::GetEnvironmentVariable('FM_WEDGE_ALARM_SUMMARY')
        try {
            [Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_SUMMARY', [string]$Summary)
            $rc = Invoke-FmWedgeAlarmBounded -Channel 'powershell' -FilePath 'powershell.exe' `
                -Arguments @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
                    '-Command', $script:FmWedgeAlarmToast)
        } finally {
            [Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_SUMMARY', $previous)
        }
        if ($rc -eq 0) { return $true }
        Write-FmDaemonLog 'wedge alarm: powershell toast not delivered; trying msg.exe'
    }

    if (Test-FmCommand -Name 'msg.exe') {
        $user = Get-FmEnv -Name 'USERNAME' -Default (Get-FmEnv -Name 'USER' -Default '*')
        $rc = Invoke-FmWedgeAlarmBounded -Channel 'powershell' -FilePath 'msg.exe' `
            -Arguments @($user, '/TIME:60', "firstmate: away-mode escalations WEDGED - $Summary")
        if ($rc -eq 0) { return $true }
        Write-FmDaemonLog 'wedge alarm: msg.exe notification failed'
        return $false
    }
    Write-FmDaemonLog 'wedge alarm: neither powershell.exe nor msg.exe found; cannot post a Windows notification'
    return $false
}

<#
.SYNOPSIS
Post a herdr UI notification (wedge_alarm_via_herdr).
#>
function Send-FmWedgeAlarmHerdr {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Summary = '')

    $rc = Invoke-FmWedgeAlarmOverride -Channel 'herdr' -Summary $Summary
    if ($rc -eq 0) { return $true }
    if ($rc -eq 1) { return $false }
    if (-not (Test-FmCommand -Name 'herdr')) {
        Write-FmDaemonLog 'wedge alarm: herdr not found; cannot post a herdr notification'
        return $false
    }
    $rc = Invoke-FmWedgeAlarmBounded -Channel 'herdr' -FilePath 'herdr' -Arguments @(
        'notification', 'show', 'firstmate: away-mode escalations WEDGED',
        '--body', [string]$Summary, '--sound', 'request')
    if ($rc -eq 0) { return $true }
    Write-FmDaemonLog 'wedge alarm: herdr notification failed'
    return $false
}

<#
.SYNOPSIS
Run a captain-supplied alert command (wedge_alarm_via_command).
.DESCRIPTION
The summary arrives both as $1 and on stdin, so an alert can reach a phone or
pager even when the captain is away from the machine entirely. The command text
is never logged - it may carry a token.
#>
function Send-FmWedgeAlarmCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Command = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Summary = ''
    )

    if ([string]::IsNullOrEmpty($Command)) {
        Write-FmDaemonLog 'wedge alarm: empty command: channel; nothing to run'
        return $false
    }
    $shell = Get-FmBash
    if (-not $shell) {
        Write-FmDaemonLog 'wedge alarm: no shell available to run the command channel'
        return $false
    }
    $rc = Invoke-FmWedgeAlarmBounded -Channel 'command' -FilePath $shell `
        -Arguments @('-c', $Command, 'fm-wedge-alarm', [string]$Summary) -StdIn ([string]$Summary)
    if ($rc -eq 0) { return $true }
    Write-FmDaemonLog "wedge alarm: command channel exited $rc (command redacted)"
    return $false
}

<#
.SYNOPSIS
Fire one resolved channel through the notifier seam (wedge_alarm_emit).
.DESCRIPTION
FM_WEDGE_ALARM_EXEC short-circuits EVERY channel before the real notifier is
reached; `discard` fires nothing at all.
#>
function Send-FmWedgeAlarm {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Channel,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Summary = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Command = ''
    )

    $rc = Invoke-FmWedgeAlarmOverride -Channel $Channel -Summary $Summary
    if ($rc -eq 0) { return $true }
    if ($rc -eq 1) { return $false }

    switch ($Channel) {
        'osascript' { return (Send-FmWedgeAlarmOsascript -Summary $Summary) }
        'powershell' { return (Send-FmWedgeAlarmPowershell -Summary $Summary) }
        'herdr' { return (Send-FmWedgeAlarmHerdr -Summary $Summary) }
        'command' { return (Send-FmWedgeAlarmCommand -Command $Command -Summary $Summary) }
    }
    # An unrecognized channel never reaches here (wedge_alarm_notify filters
    # first) and answers like an empty bash `case`, which is success.
    return $true
}

<#
.SYNOPSIS
Fire every configured active-alert channel, best-effort (wedge_alarm_notify).
.DESCRIPTION
Always succeeds: a channel failure can never abort the wedge alarm or the daemon
loop. An `off` directive anywhere disables the alert regardless of position, and
an unresolvable `auto` logs that the durable marker is the only signal.
#>
function Send-FmWedgeAlarmNotification {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Summary = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Marker = ''
    )

    $channels = @(Get-FmWedgeAlarmChannel)
    foreach ($channel in $channels) {
        if ([string]::Equals($channel, 'off', $script:FmOrdinal)) { return }
    }
    foreach ($configured in $channels) {
        $channel = $configured
        if ([string]::Equals($channel, 'auto', $script:FmOrdinal) -or
            [string]::Equals($channel, 'default', $script:FmOrdinal)) {
            $channel = Get-FmWedgeAlarmPlatformDefault
        }
        if ([string]::IsNullOrEmpty($channel)) {
            Write-FmDaemonLog ("wedge alarm: no OS-level alert channel on $(Get-FmDaemonKernelName); " +
                "durable marker $Marker is the only signal - set config/wedge-alarm (e.g. a command: directive)")
            continue
        }
        if ($channel -cin @('osascript', 'powershell', 'herdr')) {
            [void](Send-FmWedgeAlarm -Channel $channel -Summary $Summary)
            continue
        }
        if ($channel.StartsWith('command:', $script:FmOrdinal)) {
            [void](Send-FmWedgeAlarm -Channel 'command' -Summary $Summary `
                    -Command $channel.Substring('command:'.Length))
            continue
        }
        Write-FmDaemonLog 'wedge alarm: unrecognized active-alert channel directive (redacted); marker still written'
    }
}

<#
.SYNOPSIS
Raise the rate-limited undelivered-escalation alarm (inject_wedge_alarm).
.DESCRIPTION
Writes the durable marker, logs an ERROR, flashes the tmux status line where
that applies, and fires the backend-independent active alert. Nothing is lost -
the buffer and the durable wake queue both survive - but the stall stops being
invisible. Re-alarms at most once per max-defer window so a long wedge cannot
spam the captain.
#>
function Invoke-FmDaemonWedgeAlarm {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Age = ''
    )

    $marker = "$State/.subsuper-inject-wedged"
    $maxDefer = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_MAX_DEFER_SECS' 'MaxDeferSecs') `
        -Default ([long](Get-FmDaemonDefault 'MaxDeferSecs'))
    if ((Get-FmDaemonFileAge -Path $marker) -lt $maxDefer) { return }

    $now = Get-FmDaemonNow
    $notify = $true
    if ($script:FmWedgeAlarmLastEpoch -gt 0 -and ($now - $script:FmWedgeAlarmLastEpoch) -lt $maxDefer) {
        $notify = $false
    } else {
        $script:FmWedgeAlarmLastEpoch = $now
        Write-FmDaemonLog ("ERROR: away-mode escalation undelivered ${Age}s; inject could not confirm a submit " +
            '(supervisor pane busy or wedged). Buffer + wake-queue preserved; alarm marker written.')
    }

    $body = "fm away-mode inject WEDGED: ${Age}s undelivered as of $(Get-FmDaemonTimestamp)`n" +
        "The supervisor pane could not accept an escalation. Buffered items:`n" +
        (Get-FmFileText -Path "$State/.subsuper-escalations")
    try {
        Set-FmFileText -Path $marker -Text $body -NoNewline
    } catch {
        # `> "$marker" || true` - a marker that cannot be written must not take
        # the daemon down; the log line above is already recorded.
        $null = $_
    }

    $target = Get-FmEnv -Name 'FM_SUPERVISOR_TARGET' -Default (Get-FmSupervisorTargetDefault)
    $backend = Get-FmEnv -Name 'FM_SUPERVISOR_BACKEND' -Default (Get-FmSupervisorBackendDefault)
    # Best-effort status-line flash. tmux's display-message is a client-side OSD
    # with no cross-backend equivalent, and the log line plus durable marker are
    # already the primary backend-independent signal, so a non-tmux backend skips
    # the cosmetic extra rather than attempting an unsupported call.
    if ([string]::Equals($backend, 'tmux', $script:FmOrdinal)) {
        try {
            [void](Invoke-FmTool -FilePath 'tmux' -Arguments @(
                    'display-message', '-t', $target,
                    "fm: away-mode escalations WEDGED ${Age}s " + [char]0x2014 + " see $marker"))
        } catch {
            $null = $_
        }
    }
    if ($notify) {
        Send-FmWedgeAlarmNotification -Summary "away-mode escalations WEDGED ${Age}s undelivered - see $marker" `
            -Marker $marker
    }
}

# --- injection ----------------------------------------------------------------

<#
.SYNOPSIS
Send one escalation digest to the supervisor pane (inject_msg).
.DESCRIPTION
Returns false - and the caller then PRESERVES the buffer - when away mode is
off, the pane is gone, the supervisor is busy, the composer is not confirmed
empty, or the submit cannot be confirmed.

Submit model, unchanged from the bash twin because each rule fixes a real
failure:
  * TYPE ONCE, then submit with Enter, retrying only the Enter. Retyping a
    swallowed digest would concatenate two marker-prefixed digests into one
    corrupted turn.
  * SUBMIT ACK is the backend's own `empty` verdict after Enter. Pending means
    the Enter was swallowed; unknown is undelivered as far as this strict path
    is concerned.
  * COMPOSER GUARD before typing: anything that is not affirmatively `empty` -
    a human's half-typed line, a dead-shell prompt, an unreadable pane - defers
    entirely, because typing an escalation into a shell could execute it.
#>
function Send-FmDaemonInjection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of the bash inject path; a confirmation surface would stall a non-interactive daemon whose whole job is unattended delivery.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Message = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State = ''
    )

    if ([string]::IsNullOrEmpty($State)) { $State = Get-FmDaemonStateRoot }
    # (1) Presence gate: inject ONLY in away mode. Otherwise the daemon stays
    # quiet and the escalation buffers for the next catch-up flush.
    if (-not (Test-FmAfkActive -State $State)) {
        Write-FmDaemonLog 'inject deferred: afk inactive'
        return $false
    }
    # (2) One line, then the canonical typed envelope, so a consumer keeps the
    # exact away-supervisor kind without interpreting the payload's prose.
    $single = ConvertTo-FmDaemonSingleLine -Text $Message
    $encoded = ConvertTo-FmOperationalInput -Kind 'away-supervisor' -Body $single
    if ($null -eq $encoded) { return $false }

    $target = Get-FmEnv -Name 'FM_SUPERVISOR_TARGET' -Default (Get-FmSupervisorTargetDefault)
    $backend = Get-FmEnv -Name 'FM_SUPERVISOR_BACKEND' -Default 'tmux'
    if (-not (Test-FmBackendTargetExists -Backend $backend -Target $target)) { return $false }
    # (3) Busy guard: never inject into an in-use supervisor pane.
    if (Test-FmDaemonPaneBusy -Target $target -Backend $backend) {
        Write-FmDaemonLog 'inject deferred: supervisor pane busy (agent mid-turn)'
        return $false
    }
    $composer = Get-FmBackendComposerState -Backend $backend -Target $target
    if (-not [string]::Equals($composer, 'empty', $script:FmOrdinal)) {
        $shown = if ([string]::IsNullOrEmpty($composer)) { 'unknown' } else { $composer }
        Write-FmDaemonLog ("inject deferred: supervisor composer not confirmed-empty (state=${shown}: " +
            'pending input, dead-shell prompt, or unreadable pane)')
        return $false
    }
    # (4) Type once, submit with Enter, retry only the Enter.
    $retries = Get-FmDaemonSetting 'FM_INJECT_CONFIRM_RETRIES' 'InjectConfirmRetries'
    $sleep = Get-FmDaemonSetting 'FM_INJECT_CONFIRM_SLEEP' 'InjectConfirmSleep'
    $verdict = Send-FmBackendTextSubmit -Backend $backend -Target $target -Text $encoded `
        -Retries $retries -EnterSleep $sleep -Settle $sleep
    if ([string]::Equals($verdict, 'empty', $script:FmOrdinal)) { return $true }
    Write-FmDaemonLog "inject failed: submit unconfirmed after $retries retries (verdict=$verdict, text may be in composer)"
    return $false
}

# --- wake dispatch ------------------------------------------------------------

<#
.SYNOPSIS
Dispatch one watcher wake to self-handle, pause, or escalate (handle_wake).
.DESCRIPTION
Side effects only: logging, marker records, and escalation-buffer appends.
#>
function Invoke-FmDaemonWake {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason = '',
        [Parameter(Mandatory, Position = 1)][string]$State
    )

    if ($null -eq $Reason) { $Reason = '' }
    if (Test-FmDaemonForceSelf -Reason $Reason) {
        Write-FmDaemonLog "wake force-self (FM_INJECT_SKIP): $Reason"
        return
    }

    $kind = ''
    $argument = ''
    $decision = ''
    if ($Reason.StartsWith('signal:', $script:FmOrdinal)) {
        $kind = 'signal'
        $argument = Remove-FmDaemonPrefix -Text $Reason -Prefix 'signal: '
        $decision = Get-FmDaemonSignalDecision -Reason $argument -State $State
    } elseif ($Reason.StartsWith('stale:', $script:FmOrdinal)) {
        $kind = 'stale'
        $argument = Remove-FmDaemonPrefix -Text $Reason -Prefix 'stale: '
        $detail = ''
        # `${arg#*" ("}` / `${arg%% \(*}` - both cut at the FIRST " (", so a
        # detail suffix that itself contains parentheses cannot shift the split.
        $open = $argument.IndexOf(' (', $script:FmOrdinal)
        if ($open -ge 0) {
            $detail = $argument.Substring($open + 2)
            $argument = $argument.Substring(0, $open)
        }
        $decision = Get-FmDaemonStaleDecision -Window $argument -State $State
        # The watcher's own already-aged wedge detail is authoritative: it has
        # already done the persistence work, so it escalates verbatim rather
        # than being re-classified as a first sighting.
        if ($detail -cmatch '^idle .*s, possible wedge, escalation ') {
            $decision = 'escalate|' + (Remove-FmDaemonPrefix -Text $Reason -Prefix 'stale: ')
        }
    } elseif ($Reason.StartsWith('check:', $script:FmOrdinal)) {
        $decision = Get-FmDaemonCheckDecision -Reason $Reason
    } elseif ([string]::Equals($Reason, 'heartbeat', $script:FmOrdinal) -or
        $Reason.StartsWith('heartbeat:', $script:FmOrdinal)) {
        $decision = Get-FmDaemonHeartbeatDecision
    } else {
        $decision = Get-FmDaemonUnknownDecision -Reason $Reason
    }

    $bar = $decision.IndexOf('|', $script:FmOrdinal)
    $action = if ($bar -ge 0) { $decision.Substring(0, $bar) } else { $decision }
    $distilled = if ($bar -ge 0) { $decision.Substring($bar + 1) } else { $decision }

    if ([string]::Equals($kind, 'signal', $script:FmOrdinal)) {
        Sync-FmDaemonSignalPauseMarker -State $State -Paths $argument
    }

    if ([string]::Equals($action, 'escalate', $script:FmOrdinal)) {
        Write-FmDaemonLog "escalate: $Reason -> $distilled"
        Add-FmDaemonEscalation -State $State -Item $distilled
        # A terminal-stale escalate must not leave a persistence marker behind,
        # or housekeeping re-escalates the same pane later as a false wedge.
        if ([string]::Equals($kind, 'stale', $script:FmOrdinal)) {
            Remove-FmDaemonStaleMarker -Window $argument -State $State
        }
        Set-FmDaemonEscalatedSeen -Kind $kind -Argument $argument -State $State
        $batch = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_ESCALATE_BATCH_SECS' 'EscalateBatchSecs') `
            -Default ([long](Get-FmDaemonDefault 'EscalateBatchSecs'))
        if ($batch -le 0) { [void](Send-FmDaemonEscalationDigest -State $State) }
        return
    }

    if ([string]::Equals($action, 'pause', $script:FmOrdinal)) {
        # Only a stale wake produces this action: record the long-cadence pause
        # marker and drop any wedge marker, so a pane that went working->paused
        # is not still being aged as a wedge.
        if ([string]::Equals($kind, 'stale', $script:FmOrdinal)) {
            Remove-FmDaemonStaleMarker -Window $argument -State $State
            New-FmDaemonPauseMarker -Window $argument -State $State
        }
        Write-FmDaemonLog "self-handle (paused): $Reason -> $distilled"
        return
    }

    if ([string]::Equals($kind, 'stale', $script:FmOrdinal)) {
        $task = Get-FmWindowTask -Window $argument -State $State
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        # Wedge aging is cleared only for a terminal (or legacy free-text)
        # captain line. A non-terminal progress verb keeps its possible-wedge
        # marker even if the prose once looked captain-relevant.
        $clearWedge = $false
        if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusCaptainRelevant -Line $last)) {
            if (Test-FmStatusTerminalVerb -Line $last) {
                $clearWedge = $true
            } else {
                $verb = Get-FmStatusLineVerb -Line $last
                $clearWedge = -not ($verb -cin @('working', 'resolved', 'captain-held'))
            }
        }
        if ($clearWedge) {
            Remove-FmDaemonStaleMarker -Window $argument -State $State
        } else {
            Remove-FmDaemonPauseMarker -Window $argument -State $State
            New-FmDaemonStaleMarker -Window $argument -State $State
        }
    }
    Write-FmDaemonLog "self-handle: $Reason -> $distilled"
}

# `${text#prefix}` - strip the prefix only when it is actually there.
function Remove-FmDaemonPrefix {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This removes a PREFIX from a string and touches no system state at all; the Remove verb describes the text operation. Adding a confirmation surface would diverge from the bash twin and could stall a non-interactive daemon.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Prefix
    )
    if ($Text.StartsWith($Prefix, $script:FmOrdinal)) { return $Text.Substring($Prefix.Length) }
    return $Text
}

# --- housekeeping -------------------------------------------------------------

<#
.SYNOPSIS
One housekeeping pass (housekeeping).
.DESCRIPTION
Four cheap jobs, each guarded so a quiet fleet costs almost nothing:
  1)  batch flush once the buffer's oldest item passes FM_ESCALATE_BATCH_SECS;
  1b) max-defer escape - a buffer still undelivered past FM_MAX_DEFER_SECS gets
      one more normal delivery attempt and, failing that, the wedge alarm. It
      never silently defers forever;
  2)  stale recheck - a pending wedge marker past FM_STALE_ESCALATE_SECS is
      re-peeked: still idle escalates, resumed or unreadable clears;
  2b) pause re-surface - a declared pause past FM_PAUSE_RESURFACE_SECS re-surfaces
      as a recheck digest and resets its window, so a forgotten pause cannot rot
      invisibly, and is never escalated as a wedge;
  3)  heartbeat catch-all scan for a captain-relevant status the per-wake
      classifier may have missed.
#>
function Invoke-FmDaemonHousekeeping {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    $now = Get-FmDaemonNow
    Sync-FmDaemonWatcherPauseMarker -State $State
    $buffer = "$State/.subsuper-escalations"

    # (1) batch flush
    $batch = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_ESCALATE_BATCH_SECS' 'EscalateBatchSecs') `
        -Default ([long](Get-FmDaemonDefault 'EscalateBatchSecs'))
    if ($batch -le 0) {
        [void](Send-FmDaemonEscalationDigest -State $State)
    } elseif ((Get-FmDaemonOldestEscalationAge -Path $buffer) -ge $batch) {
        [void](Send-FmDaemonEscalationDigest -State $State)
    }

    # (1b) max-defer escape, throttled by the wedge marker's own age.
    $maxDefer = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_MAX_DEFER_SECS' 'MaxDeferSecs') `
        -Default ([long](Get-FmDaemonDefault 'MaxDeferSecs'))
    if ((Test-FmAfkActive -State $State) -and $maxDefer -gt 0 -and (Test-FmDaemonFileNonEmpty -Path $buffer)) {
        $oldest = Get-FmDaemonOldestEscalationAge -Path $buffer
        if ($oldest -ge $maxDefer -and
            (Get-FmDaemonFileAge -Path "$State/.subsuper-inject-wedged") -ge $maxDefer) {
            if (Send-FmDaemonEscalationDigest -State $State) {
                Write-FmDaemonLog "inject recovered: max-defer flush succeeded after ${oldest}s undelivered"
                Remove-FmDaemonFile -Path "$State/.subsuper-inject-wedged"
            } else {
                Invoke-FmDaemonWedgeAlarm -State $State -Age ([string]$oldest)
            }
        }
    }

    # (2) stale persistence recheck
    $staleSecs = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_STALE_ESCALATE_SECS' 'StaleEscalateSecs') `
        -Default ([long](Get-FmDaemonDefault 'StaleEscalateSecs'))
    foreach ($name in @(Get-FmDaemonStateFileName -State $State -Prefix '.subsuper-stale-')) {
        $marker = "$State/$name"
        $key = $name.Substring('.subsuper-stale-'.Length)
        $window = Get-FmDaemonWindowForTask -Key $key -State $State
        if ([string]::IsNullOrEmpty($window)) {
            # The task is gone: drop the marker, there is nothing to escalate.
            Remove-FmDaemonFile -Path $marker
            continue
        }
        $task = Get-FmWindowTask -Window $window -State $State
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusPaused -Line $last)) {
            Sync-FmDaemonPauseTracking -Window $window -State $State -Last $last
            continue
        }
        $age = $now - (Get-FmDaemonNumber -Text (Get-FmFileText -Path $marker).Trim() -Default $now)
        if ($age -lt $staleSecs) { continue }
        switch (Get-FmDaemonStaleWindowBusy -Window $window -State $State) {
            0 { Remove-FmDaemonFile -Path $marker }
            2 { Remove-FmDaemonFile -Path $marker }
            default {
                Add-FmDaemonEscalation -State $State -Item "stale persisted ${age}s (possible wedge): $window"
                Remove-FmDaemonStaleMarker -Window $window -State $State
            }
        }
    }

    # (2b) pause re-surface recheck
    # fm-classify-lib owns this cadence for BOTH consumers, and already applies
    # the FM_PAUSE_RESURFACE_SECS override, so it is read once rather than
    # re-derived here.
    $pauseSecs = Get-FmDaemonNumber -Text (Get-FmClassifyPauseResurfaceInterval) -Default 3600
    foreach ($name in @(Get-FmDaemonStateFileName -State $State -Prefix '.subsuper-paused-')) {
        $marker = "$State/$name"
        $key = $name.Substring('.subsuper-paused-'.Length)
        $window = Get-FmDaemonWindowForTask -Key $key -State $State
        if ([string]::IsNullOrEmpty($window)) {
            Remove-FmDaemonFile -Path $marker
            continue
        }
        $task = Get-FmWindowTask -Window $window -State $State
        $last = Get-FmLastStatusLine -Path "$State/$task.status"
        if ([string]::IsNullOrEmpty($last) -or -not (Test-FmStatusPaused -Line $last)) {
            Sync-FmDaemonPauseTracking -Window $window -State $State -Last $last
            continue
        }
        $age = $now - (Get-FmDaemonNumber -Text (Get-FmFileText -Path $marker).Trim() -Default $now)
        if ($age -lt $pauseSecs) { continue }
        switch (Get-FmDaemonStaleWindowBusy -Window $window -State $State) {
            0 { Remove-FmDaemonFile -Path $marker }
            2 { Remove-FmDaemonFile -Path $marker }
            default {
                $last = Get-FmLastStatusLine -Path "$State/$task.status"
                if (-not [string]::IsNullOrEmpty($last) -and (Test-FmStatusPaused -Line $last)) {
                    Add-FmDaemonEscalation -State $State `
                        -Item "paused ${age}s (awaiting external, recheck whether the wait still holds): $window"
                    Set-FmFileText -Path $marker -Text ([string](Get-FmDaemonNow))
                } else {
                    Remove-FmDaemonFile -Path $marker
                }
            }
        }
    }

    # (3) heartbeat catch-all scan: status files only, no backend calls. The
    # captain-relevant filtering is the shared classifier's; only the digest
    # dedup on top of it belongs to the daemon.
    $scanSecs = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_HEARTBEAT_SCAN_SECS' 'HeartbeatScanSecs') `
        -Default ([long](Get-FmDaemonDefault 'HeartbeatScanSecs'))
    if ((Get-FmDaemonFileAge -Path "$State/.subsuper-last-scan") -ge $scanSecs) {
        Set-FmFileText -Path "$State/.subsuper-last-scan" -Text ([string](Get-FmDaemonNow))
        foreach ($row in ((Get-FmCaptainRelevantStatus -State $State) -split "`n")) {
            if ($row -eq '') { continue }
            # A TAB record with three fields; .Split keeps an empty middle field
            # where a regex split could drop it.
            $fields = @($row.Split("`t"))
            if ($fields.Count -lt 3) { continue }
            $file = $fields[0]
            $task = $fields[1]
            $last = $fields[2]
            if ([string]::IsNullOrEmpty($file)) { continue }
            if ((Get-FmDaemonStatusSeen -State $State -Task $task) -ceq $last) { continue }
            Add-FmDaemonEscalation -State $State `
                -Item "$([System.IO.Path]::GetFileName($file)): $last (catch-all scan)"
            Set-FmDaemonStatusSeen -State $State -Task $task -Line $last
        }
    }
}

# --- library mode -------------------------------------------------------------

<#
.SYNOPSIS
Apply the bash twin's library-mode safety default.
.DESCRIPTION
bin/fm-supervise-daemon.sh's else-branch sets FM_WEDGE_ALARM_EXEC=discard
whenever it is SOURCED rather than executed, which makes it structurally
impossible for a test to post a real desktop notification. A module is always
"sourced", so the equivalent cannot be a top-level statement here without also
disarming production; instead the CONSUMER declares library mode, exactly as the
bash consumer declares it by sourcing. The .ps1 entrypoint never calls this.
#>
function Set-FmDaemonLibraryMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets one environment default for the current process, exactly as the bash twin does at source time; a confirmation surface would defeat the safety default it exists to install.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if ((Get-FmEnv -Name 'FM_WEDGE_ALARM_EXEC') -eq '') {
        [Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_EXEC', 'discard')
    }
}

# --- daemon lifecycle ---------------------------------------------------------

<#
.SYNOPSIS
The path of the cooperative stop request this daemon honors.
.DESCRIPTION
Windows has no SIGTERM to deliver, and a hard kill would skip the cleanup that
flushes buffered escalations while away mode is still active. See divergence (a).
#>
function Get-FmDaemonStopRequestPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$State)
    return "$State/.supervise-daemon.stop"
}

<#
.SYNOPSIS
Ask a running daemon to shut down cooperatively.
.DESCRIPTION
Written by bin/fm-afk-launch.ps1's stop path before it waits for the pid to
disappear. It is a REQUEST, never a kill: a daemon that ignores it stays alive
and the launcher preserves away-mode lifecycle state for retry, exactly as the
bash twin does when a daemon survives its SIGTERM.
#>
function Request-FmDaemonStop {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The stand-in for delivering a signal; a confirmation surface would make an unattended away-mode exit impossible.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$ProcessId = ''
    )
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $State))
        Set-FmFileText -Path (Get-FmDaemonStopRequestPath -State $State) -Text ([string]$ProcessId)
        return $true
    } catch {
        return $false
    }
}

# True once a stop has been asked for, by signal or by request file. The request
# is consumed here so a stale one cannot stop the NEXT daemon.
function Test-FmDaemonStopRequested {
    param([Parameter(Mandatory)][string]$State)
    if ($script:FmDaemonStopRequested) { return $true }
    $request = Get-FmDaemonStopRequestPath -State $State
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path $request)) {
        Remove-FmDaemonFile -Path $request
        $script:FmDaemonStopRequested = $true
        return $true
    }
    return $false
}

# SIGINT/SIGTERM where the platform has them; on Windows .NET raises these for
# Ctrl+C and console close, so a captain closing the daemon's terminal still
# gets the flush. Cancel=$true keeps the runtime from terminating us before
# cleanup runs.
function Register-FmDaemonSignalHandler {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Installs in-process handlers only; a confirmation surface would be meaningless for a background daemon.')]
    param()
    $script:FmDaemonSignalRegistrations = @()
    foreach ($signal in @([System.Runtime.InteropServices.PosixSignal]::SIGINT,
            [System.Runtime.InteropServices.PosixSignal]::SIGTERM)) {
        try {
            $script:FmDaemonSignalRegistrations += [System.Runtime.InteropServices.PosixSignalRegistration]::Create(
                $signal,
                {
                    param($context)
                    $context.Cancel = $true
                    Set-FmDaemonStopFlag
                })
        } catch {
            # A host that refuses the registration simply relies on the
            # cooperative request file; losing a handler must not stop startup.
            $null = $_
        }
    }
}

<#
.SYNOPSIS
Mark the running daemon as asked to stop (the signal handler's whole body).
#>
function Set-FmDaemonStopFlag {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets one in-process flag from a signal handler, where a confirmation prompt is impossible by construction.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()
    $script:FmDaemonStopRequested = $true
}

function Unregister-FmDaemonSignalHandler {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes in-process handlers only.')]
    param()
    foreach ($registration in $script:FmDaemonSignalRegistrations) {
        try { $registration.Dispose() } catch { $null = $_ }
    }
    $script:FmDaemonSignalRegistrations = @()
}

# The watcher is started as a NON-BLOCKING child, so Invoke-FmScript (which
# waits) cannot be used - but its resolution rule must still hold, or the daemon
# would hard-code a sibling's extension and break the moment fm-watch's own twin
# lands (docs/powershell-port.md contract 7). This applies the identical rule
# and returns the argv for Start-Process instead of running it.
function Get-FmDaemonWatcherInvocation {
    param([Parameter(Mandatory)][string]$BinDir)
    $psTwin = Join-Path $BinDir 'fm-watch.ps1'
    if ((Test-Path -LiteralPath $psTwin) -and ((Get-Item -LiteralPath $psTwin).Length -gt 0)) {
        $self = (Get-Process -Id $PID).Path
        if (-not $self) { $self = 'pwsh' }
        return @{ FilePath = $self; Arguments = @('-NoProfile', '-File', $psTwin) }
    }
    $shTwin = Join-Path $BinDir 'fm-watch.sh'
    if (Test-Path -LiteralPath $shTwin) {
        $bash = Get-FmBash
        if (-not $bash) { return $null }
        return @{ FilePath = $bash; Arguments = @((ConvertTo-FmPosixPath -Path $shTwin)) }
    }
    return $null
}

<#
.SYNOPSIS
The daemon body: the CLI half of the hybrid, returning its exit code.
.DESCRIPTION
Twin of fm_super_main. Startup order is load-bearing and unchanged:

  1. resolve state, find the watcher twin (missing = exit 1);
  2. take the SINGLE-INSTANCE lock; a held lock is a refusal, never a steal,
     and never a second daemon;
  3. discover the supervisor backend and REFUSE an unsupported one loudly,
     before any tmux/herdr primitive is aimed at a pane that is not one;
  4. discover and validate the supervisor target;
  5. loop: guard the pane, run the watcher child, classify its wake, and tick
     housekeeping.

Every refusal after the lock releases it and removes the pid file, so a refused
start leaves nothing behind for the next attempt to trip over.
#>
function Invoke-FmSuperviseDaemonMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @())

    $null = $Arguments
    $context = Get-FmDaemonContext
    $state = $context.State
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $state))

    $watcher = Get-FmDaemonWatcherInvocation -BinDir $context.ScriptRoot
    if ($null -eq $watcher) {
        Write-FmErr "error: watcher not found or not executable: $($context.ScriptRoot)/fm-watch.sh"
        return 1
    }

    $log = "$state/.supervise-daemon.log"
    $watchErr = "$state/.supervise-daemon.watcher.err"
    $lock = "$state/.supervise-daemon.lock"
    $pidFile = "$state/.supervise-daemon.pid"
    Set-FmDaemonLogPath -Path $log
    $script:FmDaemonStopRequested = $false
    Remove-FmDaemonFile -Path (Get-FmDaemonStopRequestPath -State $state)

    $injectFailSleep = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_INJECT_FAIL_SLEEP' 'InjectFailSleep') `
        -Default ([long](Get-FmDaemonDefault 'InjectFailSleep'))
    $crashThreshold = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_CRASH_THRESHOLD' 'CrashThreshold') `
        -Default ([long](Get-FmDaemonDefault 'CrashThreshold'))
    $crashWindow = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_CRASH_WINDOW' 'CrashWindow') `
        -Default ([long](Get-FmDaemonDefault 'CrashWindow'))
    $crashBackoff = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_CRASH_BACKOFF' 'CrashBackoff') `
        -Default ([long](Get-FmDaemonDefault 'CrashBackoff'))
    $crashNormalSleep = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_CRASH_NORMAL_SLEEP' 'CrashNormalSleep') `
        -Default ([long](Get-FmDaemonDefault 'CrashNormalSleep'))

    # --- single instance ------------------------------------------------------
    if (-not (Request-FmLock -LockPath $lock)) {
        $held = Get-FmLockHeldPid
        if (-not [string]::IsNullOrEmpty($held)) {
            Write-FmErr "error: another fm-supervise-daemon is already running (pid $held, lock $lock held)"
        } else {
            Write-FmErr "error: another fm-supervise-daemon is already running (lock $lock held)"
        }
        return 1
    }
    Set-FmFileText -Path $pidFile -Text ([string]$PID)
    $identity = Get-FmPidIdentity -ProcessId ([string]$PID)
    if (-not [string]::IsNullOrEmpty($identity)) {
        try { Set-FmFileText -Path "$lock/pid-identity" -Text $identity } catch { $null = $_ }
    }

    # --- supervisor backend ---------------------------------------------------
    $backendSource = 'FM_SUPERVISOR_BACKEND'
    if ((Get-FmEnv -Name 'FM_SUPERVISOR_BACKEND') -eq '') {
        if ((Get-FmEnv -Name 'TMUX_PANE') -ne '') {
            $backendSource = 'TMUX_PANE'
        } elseif ((Get-FmEnv -Name 'HERDR_ENV') -eq '1' -and (Get-FmEnv -Name 'HERDR_PANE_ID') -ne '') {
            $backendSource = 'HERDR_ENV'
        } else {
            $backendSource = "FALLBACK($(Get-FmSupervisorBackendDefault))"
        }
    }
    $backend = (Get-FmSupervisorBackend).Value
    [Environment]::SetEnvironmentVariable('FM_SUPERVISOR_BACKEND', $backend)

    if (-not (Test-FmBackendListContains -List (Get-FmDaemonSupportedBackend) -Name $backend)) {
        Write-FmErr ("error: away-mode daemon does not support supervisor backend '$backend' yet " +
            "(supported: $(Get-FmDaemonSupportedBackend)); set FM_SUPERVISOR_BACKEND=tmux|herdr and " +
            "FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend")
        Write-FmDaemonLog "startup failed: unsupported supervisor backend '$backend' (source=$backendSource)"
        Unlock-FmLock -LockPath $lock
        Remove-FmDaemonFile -Path $pidFile
        return 1
    }

    # --- supervisor target ----------------------------------------------------
    $targetSource = 'FM_SUPERVISOR_TARGET'
    if ((Get-FmEnv -Name 'FM_SUPERVISOR_TARGET') -eq '') {
        if ((Get-FmEnv -Name 'TMUX_PANE') -ne '') {
            $targetSource = 'TMUX_PANE'
        } elseif ((Get-FmEnv -Name 'HERDR_ENV') -eq '1' -and (Get-FmEnv -Name 'HERDR_PANE_ID') -ne '') {
            $targetSource = 'HERDR_ENV(HERDR_PANE_ID)'
        } else {
            $targetSource = 'FALLBACK(firstmate:0)'
        }
    }
    $discovered = Get-FmSupervisorTarget
    $target = $discovered.Value
    if (-not $discovered.Detected) {
        Write-FmErr ('warn: could not auto-discover supervisor pane (no FM_SUPERVISOR_TARGET, TMUX_PANE, ' +
            "or HERDR_ENV/HERDR_PANE_ID); falling back to '$target' " + [char]0x2014 + ' verify this is firstmate''s pane')
    }
    [Environment]::SetEnvironmentVariable('FM_SUPERVISOR_TARGET', $target)

    if (-not (Test-FmBackendTargetExists -Backend $backend -Target $target)) {
        Write-FmErr "error: supervisor target '$target' does not resolve to a $backend pane; set FM_SUPERVISOR_TARGET"
        Write-FmDaemonLog "startup failed: target '$target' not found (backend=$backend)"
        Unlock-FmLock -LockPath $lock
        Remove-FmDaemonFile -Path $pidFile
        return 1
    }

    $afkStatus = if (Test-FmAfkActive -State $state) { 'on' } else { 'off' }
    Write-FmDaemonLog ("daemon starting (pid $PID); target=$target; target_source=$targetSource; " +
        "backend=$backend; backend_source=$backendSource; afk=$afkStatus; " +
        "inject_skip='$(Get-FmDaemonSetting 'FM_INJECT_SKIP' 'InjectSkip')'; " +
        "stale_escalate=$(Get-FmDaemonSetting 'FM_STALE_ESCALATE_SECS' 'StaleEscalateSecs')s; " +
        "batch=$(Get-FmDaemonSetting 'FM_ESCALATE_BATCH_SECS' 'EscalateBatchSecs')s")
    Sync-FmDaemonWatcherPauseMarker -State $state

    Register-FmDaemonSignalHandler

    $watcherProcess = $null
    $currentTemp = ''
    $watcherErrTemp = ''
    $crashTimes = [System.Collections.Generic.List[long]]::new()
    $backoff = $crashNormalSleep
    $housekeepingTick = Get-FmDaemonNumber -Text (Get-FmDaemonSetting 'FM_HOUSEKEEPING_TICK' 'HousekeepingTick') `
        -Default ([long](Get-FmDaemonDefault 'HousekeepingTick'))

    try {
        while ($true) {
            if (Test-FmDaemonStopRequested -State $state) { break }

            # --- pane-gone guard: self-handling needs no pane, but an escalation
            # has nowhere to go, and the queued wakes persist, so this DELAYS
            # rather than loses work.
            if (-not (Test-FmBackendTargetExists -Backend $backend -Target $target)) {
                Write-FmDaemonLog "warn: supervisor target '$target' gone; backing off ${injectFailSleep}s, will retry"
                Start-Sleep -Seconds $injectFailSleep
                continue
            }

            $running = $false
            if ($null -ne $watcherProcess) {
                try { $running = -not $watcherProcess.HasExited } catch { $running = $false }
            }
            if (-not $running) {
                if ($null -ne $watcherProcess) {
                    $rc = 0
                    try { $rc = $watcherProcess.ExitCode } catch { $rc = 1 }
                    $reason = ''
                    if ($currentTemp -ne '') { $reason = (Get-FmFileText -Path $currentTemp).TrimEnd("`n") }
                    if ($watcherErrTemp -ne '') {
                        $errText = Get-FmFileText -Path $watcherErrTemp
                        if ($errText -ne '') { Add-FmFileLine -Path $watchErr -Line $errText.TrimEnd("`n") }
                        Remove-FmDaemonFile -Path $watcherErrTemp
                        $watcherErrTemp = ''
                    }
                    if ($currentTemp -ne '') { Remove-FmDaemonFile -Path $currentTemp; $currentTemp = '' }
                    try { $watcherProcess.Dispose() } catch { $null = $_ }
                    $watcherProcess = $null

                    if ($rc -ne 0 -or $reason -eq '') {
                        # Crash-loop guard: count crashes inside the window and
                        # back off hard once they exceed the threshold, so a
                        # watcher that cannot start cannot spin the daemon.
                        $now = Get-FmDaemonNow
                        $kept = [System.Collections.Generic.List[long]]::new()
                        foreach ($t in $crashTimes) { if (($now - $t) -lt $crashWindow) { $kept.Add($t) } }
                        $kept.Add($now)
                        $crashTimes = $kept
                        if ($crashTimes.Count -gt $crashThreshold) {
                            Write-FmDaemonLog ("ERROR: watcher crashed $($crashTimes.Count) times within " +
                                "${crashWindow}s; backing off ${crashBackoff}s")
                            $crashTimes = [System.Collections.Generic.List[long]]::new()
                            $backoff = $crashBackoff
                        } else {
                            $backoff = $crashNormalSleep
                        }
                        Write-FmDaemonLog "watcher exited rc=$rc reason='$reason'; restarting after ${backoff}s"
                        Start-Sleep -Seconds $backoff
                        continue
                    }
                    if (-not (Test-FmDaemonWakeReason -Reason $reason)) {
                        # Non-wake stdout (a watcher singleton collision, say) is
                        # NOT a crash: idling here prevents an escalation flood
                        # and a backoff-less restart.
                        Write-FmDaemonLog "watcher non-wake stdout, idling: $reason"
                        Start-Sleep -Seconds $housekeepingTick
                        continue
                    }
                    Write-FmDaemonLog "wake: $reason"
                    Invoke-FmDaemonWake -Reason $reason -State $state
                    Limit-FmDaemonLog
                }

                $currentTemp = "$state/.supervise-daemon.watch.$PID.$([System.IO.Path]::GetRandomFileName())"
                $watcherErrTemp = "$currentTemp.err"
                Set-FmFileText -Path $currentTemp -Text '' -NoNewline
                Set-FmFileText -Path $watcherErrTemp -Text '' -NoNewline
                try {
                    $watcherProcess = Start-Process -FilePath $watcher.FilePath `
                        -ArgumentList $watcher.Arguments -PassThru -NoNewWindow `
                        -RedirectStandardOutput (ConvertTo-FmNativePath -Path $currentTemp) `
                        -RedirectStandardError (ConvertTo-FmNativePath -Path $watcherErrTemp)
                } catch {
                    Write-FmDaemonLog 'error: watcher could not be started; retrying in 5s'
                    Remove-FmDaemonFile -Path $currentTemp
                    Remove-FmDaemonFile -Path $watcherErrTemp
                    $currentTemp = ''
                    $watcherErrTemp = ''
                    $watcherProcess = $null
                    Start-Sleep -Seconds 5
                    continue
                }
            }

            # One housekeeping tick, gated so a large fleet stays cheap between
            # ticks; the watcher child runs on its own cadence internally.
            Start-Sleep -Seconds 1
            if ((Get-FmDaemonFileAge -Path "$state/.subsuper-last-housekeep") -ge $housekeepingTick) {
                Set-FmFileText -Path "$state/.subsuper-last-housekeep" -Text ([string](Get-FmDaemonNow))
                Invoke-FmDaemonHousekeeping -State $state
            }
        }
    } finally {
        # --- cleanup: flush buffered escalations WHILE away mode is still
        # present, reap the child, release the lock. This is what the stop
        # ordering in bin/fm-afk-launch exists to protect.
        Unregister-FmDaemonSignalHandler
        Stop-FmWedgeAlarmNotifier
        try { [void](Send-FmDaemonEscalationDigest -State $state) } catch { $null = $_ }
        if ($null -ne $watcherProcess) {
            try { if (-not $watcherProcess.HasExited) { $watcherProcess.Kill($true) } } catch { $null = $_ }
            try { $watcherProcess.WaitForExit(5000) } catch { $null = $_ }
            try { $watcherProcess.Dispose() } catch { $null = $_ }
        }
        if ($currentTemp -ne '') { Remove-FmDaemonFile -Path $currentTemp }
        if ($watcherErrTemp -ne '') { Remove-FmDaemonFile -Path $watcherErrTemp }
        Unlock-FmLock -LockPath $lock
        Remove-FmDaemonFile -Path $pidFile
        Remove-FmDaemonFile -Path (Get-FmDaemonStopRequestPath -State $state)
        Write-FmDaemonLog 'daemon shutting down'
        Set-FmDaemonLogPath -Path ''
    }
    return 0
}

Export-ModuleMember -Function @(
    'Get-FmDaemonDefault', 'Get-FmDaemonSupportedBackend', 'Get-FmDaemonSetting',
    'Get-FmDaemonContext', 'Get-FmDaemonStateRoot', 'Get-FmDaemonNow',
    'Get-FmDaemonFileAge', 'Get-FmDaemonTextHash',
    'Write-FmDaemonLog', 'Set-FmDaemonLogPath', 'Limit-FmDaemonLog',
    'Test-FmAfkActive', 'Enter-FmAfk', 'Exit-FmAfk',
    'Test-FmMessageIsInjection', 'Test-FmShouldExitAfk', 'Remove-FmInjectionMarker',
    'ConvertTo-FmDaemonSingleLine',
    'Get-FmDaemonStaleKey',
    'New-FmDaemonStaleMarker', 'Remove-FmDaemonStaleMarker',
    'New-FmDaemonPauseMarker', 'Remove-FmDaemonPauseMarker',
    'Clear-FmDaemonPauseTracking', 'Sync-FmDaemonPauseTracking',
    'Sync-FmDaemonWatcherPauseMarker', 'Sync-FmDaemonSignalPauseMarker',
    'Set-FmDaemonStatusSeen', 'Set-FmDaemonEscalatedSeen',
    'Get-FmDaemonSignalDecision', 'Get-FmDaemonStaleDecision', 'Get-FmDaemonCheckDecision',
    'Get-FmDaemonHeartbeatDecision', 'Get-FmDaemonUnknownDecision',
    'Test-FmDaemonWakeReason', 'Test-FmDaemonForceSelf',
    'Get-FmDaemonPrimaryHarness', 'Test-FmDaemonPaneBusy', 'Test-FmDaemonPaneInputPending',
    'Get-FmDaemonTaskBackend', 'Get-FmDaemonTaskHarness', 'Get-FmDaemonStaleWindowBusy',
    'Get-FmDaemonWindowForTask',
    'Add-FmDaemonEscalation', 'Get-FmDaemonOldestEscalationAge', 'Send-FmDaemonEscalationDigest',
    'Get-FmWedgeAlarmChannel', 'Test-FmWedgeAlarmWindowsNotifier', 'Get-FmWedgeAlarmPlatformDefault',
    'Invoke-FmWedgeAlarmBounded', 'Stop-FmWedgeAlarmNotifier', 'Invoke-FmWedgeAlarmOverride',
    'Send-FmWedgeAlarmOsascript', 'Send-FmWedgeAlarmPowershell', 'Send-FmWedgeAlarmHerdr',
    'Send-FmWedgeAlarmCommand', 'Send-FmWedgeAlarm', 'Send-FmWedgeAlarmNotification',
    'Get-FmWedgeAlarmToastScript', 'Invoke-FmDaemonWedgeAlarm',
    'Send-FmDaemonInjection', 'Invoke-FmDaemonWake', 'Invoke-FmDaemonHousekeeping',
    'Set-FmDaemonLibraryMode',
    'Get-FmDaemonStopRequestPath', 'Request-FmDaemonStop', 'Set-FmDaemonStopFlag',
    'Invoke-FmSuperviseDaemonMain'
)
