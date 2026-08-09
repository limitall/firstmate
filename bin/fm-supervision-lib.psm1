# fm-supervision-lib.psm1 - the shared "supervision missing" predicate.
#
# Twin: bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home NEEDS supervision because it has in-flight
# work (a state/<id>.meta exists) or an X-mode relay poll
# (state/x-watch.check.sh), and whether its watcher has a fresh liveness beacon
# (state/.last-watcher-beat, touched every poll cycle, within the grace window).
#
# bin/fm-guard.sh keeps its own task-specific grace-based warning predicate;
# bin/fm-turnend-guard.sh uses the status fields here for its banner but performs
# its end-of-turn block decision with the live watcher-lock check in
# bin/fm-wake-lib.sh. Nothing here decides anything on its own - it answers three
# questions and the callers own the policy.
#
# Bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-supervision-lib.sh   this file                       exported
#   -------------------------   -----------------------------   --------
#   fm_sup_stat_mtime           Get-FmSupervisionMtime          yes
#   fm_supervision_status       Get-FmSupervisionStatus         yes
#   fm_supervision_needed       Test-FmSupervisionNeeded        yes
#   fm_supervision_unhealthy    Test-FmSupervisionUnhealthy     yes
#   FM_SUP_IN_FLIGHT            (returned) .InFlight
#   FM_SUP_NEEDED               (returned) .Needed
#   FM_SUP_WATCHER_FRESH        (returned) .WatcherFresh
#   FM_SUP_BEACON_DESC          (returned) .BeaconDescription
#   FM_SUP_QUEUE_PENDING        (returned) .QueuePending
#
# ---------------------------------------------------------------------------
# TWO THINGS THIS TWIN CHANGES, AND WHY EACH IS THE SAME DECISION
#
# 1. THE FIVE GLOBALS BECOME ONE RETURNED OBJECT. fm_supervision_status
#    publishes its answers in FM_SUP_* globals for a reason that does not exist
#    here: a bash function returns through stdout, and a caller capturing stdout
#    runs it in a SUBSHELL where assignments cannot escape, so five values can
#    only be handed back by writing them into the shell. PowerShell has no such
#    boundary, so the five become fields of one hashtable and the globals are
#    gone - the same trade bin/fm-psproc-lib.psm1 makes for
#    FM_NATIVE_PID_IMAGE/PATH. A caller ported from bash reads $s.InFlight where
#    it read $FM_SUP_IN_FLIGHT.
#
#    The booleans are real [bool] here, where bash carries the STRINGS 'true'
#    and 'false' and every caller writes `[ "$FM_SUP_NEEDED" = true ]`. A
#    converted caller writes `if ($s.Needed)`.
#
# 2. THE `uname` BRANCH COLLAPSES, PRESERVING THE DECISION. The bash twin picks
#    between `stat -f %m` and `stat -c %Y` because the two stat binaries
#    disagree about their flags - macOS stat lacks -c and Linux stat lacks -f.
#    The DECISION being made is "what whole-second epoch time was this file last
#    written", and .NET answers that with one API on every platform, so there is
#    no platform question left to ask and Test-FmWindows is not consulted. The
#    branch was never about behavior; it was about which binary to run.
#
#    Truncation is preserved deliberately: `stat` reports whole seconds, and
#    DateTimeOffset.ToUnixTimeSeconds truncates the same way, so an age computed
#    here can never come out one second different from the bash answer.
#
# WHAT IS NOT "IMPROVED":
#
#   a. A NON-NUMERIC GRACE STAYS A FAILURE, NOT A REPAIR. `grace` is expanded
#      straight into `[ "$age" -lt "$grace" ]`, so a malformed value makes the
#      test error and the freshness flag stays false. Parsing it here into a
#      default would silently declare a watcher fresh on a home whose
#      configuration is broken - the unsafe direction for a predicate whose only
#      job is to notice that nothing is watching. -Grace is therefore a [string]
#      and an unparseable value means NOT fresh.
#
#   b. A BEACON IN THE FUTURE STAYS FRESH. A clock skew or a copied state
#      directory can leave the beacon newer than now, making age negative;
#      `-lt` accepts it and so does this. Reproducing it matters because the
#      alternative - clamping to zero - is indistinguishable from a healthy
#      beacon anyway, while a signed age at least shows up in the description.
#
#   c. THE EXISTENCE TESTS KEEP THEIR EXACT SHAPES. `-e` for the beacon (a
#      directory of that name still counts), `-f` for the X-mode relay poll (it
#      must be a regular file), and `-s` for the wake queue (present AND
#      non-empty). Those three are different questions and the bash asks them
#      differently on purpose.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-supervision-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it: a .psm1
# resolves function names in its OWN scope. NOT -Force, because a nested -Force
# REMOVES the already-loaded module before re-importing it and would evict a
# caller own copy of fm-common mid-run.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

<#
.SYNOPSIS
A file last-write time as whole epoch seconds, or $null when it cannot be read.
.DESCRIPTION
Twin of fm_sup_stat_mtime, whose Darwin/Linux `stat` branch collapses here (see
note 2 in the file header). A missing or unreadable path yields $null, matching
the bash twin printing nothing when stat fails - which the caller then treats as
"beacon age unknown" rather than as age zero.

UTC is used deliberately: LastWriteTime is local and would shift the computed age
by the offset, while `stat` reports epoch seconds directly.
#>
function Get-FmSupervisionMtime {
    [CmdletBinding()]
    [OutputType([System.Nullable[long]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $native = ConvertTo-FmNativePath $Path
    try {
        $item = Get-Item -LiteralPath $native -Force -ErrorAction Stop
        return [System.DateTimeOffset]::new($item.LastWriteTimeUtc).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
The supervision picture for one state directory.
.DESCRIPTION
Twin of fm_supervision_status. Returns a hashtable with the five fields the bash
twin publishes as FM_SUP_* globals:

  InFlight          [int]    count of state/*.meta, i.e. in-flight tasks
  Needed            [bool]   in-flight work OR an X-mode relay poll exists
  WatcherFresh      [bool]   a watcher beacon within the grace window
  BeaconDescription [string] human-readable beacon age for banners; 'never' when
                             the beacon is absent, 'unknown' when it exists but
                             its time cannot be read, otherwise "<n>s ago"
  QueuePending      [bool]   state/.wake-queue exists and is non-empty

-Grace defaults to FM_GUARD_GRACE, then 300, matching bin/fm-guard.sh, and is a
STRING for the reason in note (a) of the file header. This never throws for a
missing directory: an absent state/ is simply a home with nothing in flight,
which is the normal state of an idle home.

DOTFILES ARE NOT TASKS. The meta count reproduces the `"$state"/*.meta` glob,
and a bash `*` never matches a leading dot - which matters here because state/
is full of dot-prefixed records.
#>
function Get-FmSupervisionStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Grace = ''
    )

    if ([string]::IsNullOrEmpty($Grace)) { $Grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300' }

    $inFlight = 0
    $needed = $false
    $watcherFresh = $false
    $beaconDesc = 'never'
    $queuePending = $false

    $nativeState = ConvertTo-FmNativePath $State
    if (-not [string]::IsNullOrEmpty($State) -and [System.IO.Directory]::Exists($nativeState)) {
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($nativeState)) {
            $name = [System.IO.Path]::GetFileName($entry)
            if ($name.StartsWith('.', [System.StringComparison]::Ordinal)) { continue }
            # An ordinal suffix test rather than a search pattern: Windows
            # pattern matching still honours 8.3 short names, so "*.meta" can
            # match a longer extension.
            if (-not $name.EndsWith('.meta', [System.StringComparison]::Ordinal)) { continue }
            $inFlight++
        }
    }

    if ($inFlight -gt 0 -or [System.IO.File]::Exists((ConvertTo-FmNativePath "$State/x-watch.check.sh"))) {
        $needed = $true
    }

    $beacon = "$State/.last-watcher-beat"
    $nativeBeacon = ConvertTo-FmNativePath $beacon
    if ([System.IO.File]::Exists($nativeBeacon) -or [System.IO.Directory]::Exists($nativeBeacon)) {
        $mtime = Get-FmSupervisionMtime -Path $beacon
        if ($null -eq $mtime) {
            $beaconDesc = 'unknown'
        } else {
            $age = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime
            $beaconDesc = "${age}s ago"
            [long]$graceSeconds = 0
            if ([long]::TryParse($Grace, [ref]$graceSeconds) -and $age -lt $graceSeconds) {
                $watcherFresh = $true
            }
        }
    }

    $queue = ConvertTo-FmNativePath "$State/.wake-queue"
    if ([System.IO.File]::Exists($queue)) {
        try {
            if ((Get-Item -LiteralPath $queue -Force -ErrorAction Stop).Length -gt 0) { $queuePending = $true }
        } catch {
            # An unreadable queue file is not a pending queue: `-s` fails the
            # same way when stat cannot answer.
            $queuePending = $false
        }
    }

    return @{
        InFlight          = $inFlight
        Needed            = $needed
        WatcherFresh      = $watcherFresh
        BeaconDescription = $beaconDesc
        QueuePending      = $queuePending
    }
}

<#
.SYNOPSIS
True exactly when in-flight work or an X-mode relay poll needs a watcher.
.DESCRIPTION
Twin of fm_supervision_needed. False for an idle home - which is a healthy
state, not a problem: an empty fleet has nothing to supervise.
#>
function Test-FmSupervisionNeeded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Grace = ''
    )
    return (Get-FmSupervisionStatus -State $State -Grace $Grace).Needed
}

<#
.SYNOPSIS
True exactly in the dangerous state: in-flight work exists and no watcher has a
fresh beacon.
.DESCRIPTION
Twin of fm_supervision_unhealthy. Note what it does NOT say: an X-mode relay
poll alone makes supervision NEEDED but never makes a home UNHEALTHY, because
the count that gates this is the in-flight task count. That asymmetry is in the
bash and is preserved - a home with no crew and a stale beacon is idle, not
wedged.
#>
function Test-FmSupervisionUnhealthy {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$State,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Grace = ''
    )
    $status = Get-FmSupervisionStatus -State $State -Grace $Grace
    return ($status.InFlight -gt 0 -and -not $status.WatcherFresh)
}

Export-ModuleMember -Function @(
    'Get-FmSupervisionMtime',
    'Get-FmSupervisionStatus',
    'Test-FmSupervisionNeeded',
    'Test-FmSupervisionUnhealthy'
)
