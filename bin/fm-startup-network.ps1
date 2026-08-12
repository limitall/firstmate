# bin/fm-startup-network.ps1 - the deferred network stage of a session start.
# fm-startup-network.sh - the deferred network stage of a session start.
#
# WHY THIS EXISTS. Every external-network call a session start makes used to run
# BEFORE the digest printed, on a hook that blocks session initialization: `gh
# auth status`, the secondmate liveness and convergence sweeps (11 sequential,
# individually unbounded SSH connections per REMOTE secondmate), pending remote
# handoff delivery, and the fleet-sync fetch of every project clone. None of
# those calls is individually bounded, so one unreachable host could consume the
# whole FM_SESSION_START_TIMEOUT budget and truncate the digest outright, turning
# a slow network into a startup that never printed the work queue at all.
# This script runs exactly that work OFF the blocking path: the digest is
# composed from local reads alone while these checks run concurrently in a
# detached worker, and their result is reported back inline when it finishes in
# time, or as a durable wake when it does not.
#
# WHAT IS PRESERVED. Nothing is dropped. bin/fm-bootstrap.sh remains the single
# owner of every one of these sweeps and still runs all of them, unchanged, via
# its FM_BOOTSTRAP_NETWORK=only phase. Deferral changes WHEN they run, not
# WHETHER, and three properties make the later run safe:
#   - The sweeps are idempotent DETECTORS. A run whose report is lost (killed
#     worker, truncated digest, crashed session) loses no finding: the next run
#     re-derives the same dead secondmate, the same stuck clone, the same
#     undelivered handoff. There is no once-only signal to miss.
#   - The result is durable and always surfaces. It lands in
#     state/.startup-network.report and reaches the agent either inline in the
#     digest or as a `check: startup-network` wake. Only a durable acknowledgement
#     written after harvest prints the finished result suppresses that wake, so a
#     claimant that exits first cannot lose the result. While the worker is still
#     running the digest states by name what is not yet confirmed.
#   - Mutation authority is leased. The worker outlives the command that launched
#     it, so it takes the same acquisition lease a new session must hold before
#     replacing a dead owner, re-checks the captured owner under that lease, and
#     holds it through the bounded mutating run. A takeover stays read-only until
#     that run settles, so old and new owners can never sweep concurrently.
#
# Usage: fm-startup-network.sh start --locked <0|1> --harvest-pid <pid>
#          Launch the detached worker and return immediately. Single-flight: a
#          worker already running for the same lock owner is left alone. A new
#          owner gets a distinct generation. --locked 1 asks
#          for the mutating sweeps as well as the read-only probe; --locked 0
#          asks for the probe only. --harvest-pid names the session-start process
#          that will try to print the result inline, so the worker can tell
#          whether a wake is still needed.
#        fm-startup-network.sh run --locked <0|1>
#          Run the checks in the foreground and publish the result. This is what
#          `start` detaches with its private generation reservation; run it
#          directly to redo the stage by hand from the lock-owning harness.
#        fm-startup-network.sh harvest --pid <pid>
#          Print the digest's NETWORK CHECKS section and release the inline-print
#          claim. Called by bin/fm-session-start.sh, not by hand.
#        fm-startup-network.sh report
#          Print the current state and report without changing anything, then the
#          last run's per-step elapsed times. This is the ONLY command that prints
#          those timings: `harvest` composes the session-start digest, and adding
#          diagnostic detail there would make every startup pay for a question
#          only a slow run raises.
#        fm-startup-network.sh wait [<seconds>]
#          Block until the report is published, up to <seconds> (default 120).
#          For operators and tests only; a session start never waits.
#
# STATE, all under this home's state/ and gitignored with it:
#   .startup-network.status   key=value record - generation, lock_pid, state,
#                             pid, started, finished, rc, locked, phases, and
#                             whether the report was published. The single
#                             source of truth for what ran and how it ended.
#   .startup-network.report   the sweep output, byte for byte as
#                             bin/fm-bootstrap.sh produced it, plus a
#                             NETWORK_CHECKS: line whenever the stage itself
#                             could not complete or had to downgrade.
#   .startup-network.claim    the generation and pid of a session start that
#                             intends to print the result inline; a matching live
#                             claimant gives harvest a bounded chance to finish.
#   .startup-network.delivered
#                             a durable acknowledgement that harvest printed the
#                             current finished result; only this suppresses its
#                             wake.
#   .startup-network.timings  per-step elapsed times for the last run, in
#                             bin/fm-timing-lib.sh's tab-separated format: the
#                             stage total, one record per network phase (gh auth,
#                             secondmate liveness, secondmate convergence, handoff
#                             delivery, fleet sync), one per secondmate for the
#                             remote-touching steps (id and host), and one per
#                             project clone. Published for a timed-out or failed
#                             run too, where a partial record is the answer.
#                             Diagnostic only: nothing reads it to make a
#                             decision, and losing it never downgrades a run.
#   .startup-network.lock     serializes publication, harvest acknowledgement,
#                             and the wake decision.
#
# The whole stage is bounded by FM_STARTUP_NETWORK_TIMEOUT (default 120s), one
# aggregate deadline replacing the per-call unboundedness that used to be able to
# wedge a startup. Hitting the bound is reported as an actionable NETWORK_CHECKS:
# line, never as silence.

# ---------------------------------------------------------------------------
# Twin: bin/fm-startup-network.sh
#
# Everything above this line is the bash twin's header, kept byte-identical so
# `--help` renders the same text in both worlds (the bash `usage()` prints its
# own header; this file prints its own, and they must agree).
#
# ---------------------------------------------------------------------------
# HOW THE WORKER IS DETACHED, AND WHY IT IS NOT A LITERAL TRANSLATION
#
# The bash twin detaches three ways and each closes a different failure. The
# same three failures exist on Windows; two of the three mechanisms do not.
#
#   1. STDIO. `>/dev/null 2>&1 </dev/null`. This is the one that matters most
#      and it is REPRODUCED, not approximated. The digest's stdout is a pipe the
#      harness reads to EOF, so a worker holding a copy of that pipe strands
#      session initialization behind the very work this stage exists to move off
#      the blocking path. On Windows the hazard is worse than in bash, because
#      it is not about which handles the child's stdio POINTS AT: a .NET launch
#      with UseShellExecute=$false calls CreateProcess with bInheritHandles=TRUE
#      and every inheritable handle in this process - including the pipe MSYS
#      handed us - is duplicated into the child whether the child's stdio names
#      it or not. Measured here: a worker launched that way, with stdout and
#      stderr redirected to the null device, STILL held the caller's pipe open
#      and a `$(...)` capture of `start` took 28.7s behind a 25s worker.
#      UseShellExecute=$true goes through ShellExecuteEx, which inherits NO
#      handles at all. The same probe then returned in 1.2s. So the worker is
#      launched with UseShellExecute=$true and a hidden window, which is the
#      only launch shape on this platform that genuinely closes the pipe.
#   2. OUTLIVING THE LAUNCHER. `nohup`. Nothing to do: Windows has no SIGHUP and
#      no parent-death signal, and a .NET Process object does not own the
#      child's lifetime, so a child already outlives its launcher.
#   3. ITS OWN PROCESS GROUP. `set -m`. Windows has no killable process group;
#      the bound in bin/fm-session-start.ps1 is `$proc.Kill($true)`, whose tree
#      walk pairs each process with a LIVE parent by pid and start time. A
#      ShellExecuteEx child gets its own (hidden) console, and this launcher
#      exits within milliseconds of starting it, so by the time the bound fires
#      the worker has no live ancestor left in the tree and the walk cannot
#      reach it. Verified directly: a bounded child killed with Kill($true)
#      after its launcher returned left the worker running, and the worker
#      finished its work afterwards.
#      The residual divergence, recorded rather than papered over: a worker
#      launched from a LONG-LIVED pwsh (someone running `start` by hand from an
#      interactive session) stays reachable from that process's tree, where bash
#      would have put it in a separate process group. No firstmate path launches
#      it that way - fm-session-start.ps1 reaches this script through
#      Invoke-FmScript, whose child exits as soon as `start` returns.
#
# The sibling to re-invoke is resolved the way contract 7 requires - prefer
# bin/fm-startup-network.ps1, fall back to bin/fm-startup-network.sh under Git
# Bash - rather than by hard-coding an extension, exactly as
# Get-FmDaemonWatcherInvocation does for the watcher. This script re-invokes
# ITSELF as the worker, so on a cutover host the worker is this same file.
#
# ---------------------------------------------------------------------------
# WHAT IS PRIVATE HERE AND WHY
#
# bin/fm-timeout-lib.sh and bin/fm-timing-lib.sh have no .psm1 twins yet, so
# their two used surfaces (one bounded runner, four timing helpers) are ported
# PRIVATELY below, marked as such. They are deliberately minimal ports of the
# behavior this stage depends on, not a general library: when the shared twins
# land, these should be deleted in favour of them (docs/powershell-port.md's
# "duplicated helpers do not inherit their original's fixes").
#
# ---------------------------------------------------------------------------
# DIVERGENCES OF RECORD
#
#   (a) `2>&1` is a single file descriptor in bash, so the child's two streams
#       interleave by write order. .NET gives two separate pipes; they are
#       drained CONCURRENTLY here and merged line by line as each line arrives,
#       which reproduces the ordering for the line-at-a-time writers firstmate
#       actually runs, but a child that writes a partial line to one stream and
#       a whole line to the other can still interleave differently. A final
#       unterminated line also gains its LF here.
#   (b) The PowerShell bootstrap twin does not (yet) record per-phase timings,
#       so on a cutover host the published timings artifact holds the stage
#       total this file writes and nothing else. That is a diagnostic-only
#       record by contract; nothing reads it to make a decision.
#   (c) `kill -0 0` succeeds in bash (it signals the caller's process group), so
#       the bash twin would read the `pid=0` placeholder `start` writes as a
#       LIVE worker; Test-FmPidAlive reads 0 as dead. The window is entirely
#       inside the publish lock that `start` holds across the launch, so no
#       reader can observe it in either world.
#   (d) Exit codes are identical, including this script's unconditional `exit 0`
#       for every mode except `wait` (which propagates its own failure) and an
#       unknown mode (2).

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-session-lock-lib.psm1') -Force

# $args is captured before anything else can shadow it, as every converted
# entrypoint does; $PSCommandPath is what usage() reads its own header from.
$fmArgv = @($args)
$fmScriptPath = $PSCommandPath
if ([string]::IsNullOrEmpty($fmScriptPath)) {
    $fmScriptPath = Join-Path $PSScriptRoot 'fm-startup-network.ps1'
}

$FmNetContext = Get-FmContext -ScriptRoot $PSScriptRoot
# POSIX form deliberately: FM_ROOT reaches the reader only inside message text
# ("rerun /f/home/bin/fm-startup-network.sh run --locked 1"), and the bash twin
# prints whatever FM_ROOT_OVERRIDE held or the `cd .. && pwd` it derived - both
# POSIX on this platform. Durable records keep POSIX paths for the same reason
# (contract 3).
$FmNetRoot = $FmNetContext.PosixRoot
$FmNetState = $FmNetContext.State

$FmNetStatusFile = "$FmNetState/.startup-network.status"
$FmNetReportFile = "$FmNetState/.startup-network.report"
$FmNetClaimFile = "$FmNetState/.startup-network.claim"
$FmNetDeliveredFile = "$FmNetState/.startup-network.delivered"
$FmNetTimingsFile = "$FmNetState/.startup-network.timings"
$FmNetPublishLock = "$FmNetState/.startup-network.lock"

# fm-timing-lib.sh's FM_TIMING_DETAIL_MAX, and the run-local recording state the
# bash library keeps in exported variables. Held in script scope rather than in
# the process environment because only ONE child ever needs it, and that child
# receives it explicitly (see Invoke-FmNetBootstrap).
$FmNetTimingDetailMax = 80
$script:FmNetTimingLog = ''
$script:FmNetTimingEpochMs = 0

# --- small primitives --------------------------------------------------------

function Get-FmNetNow {
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# `[ -f "$p" ]`
function Test-FmNetFilePresent {
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return [System.IO.File]::Exists((ConvertTo-FmNativePath -Path $Path))
}

# `[ -s "$p" ]`
function Test-FmNetFileNonEmpty {
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath -Path $Path
    try {
        if (-not [System.IO.File]::Exists($native)) { return $false }
        return ([System.IO.FileInfo]::new($native).Length -gt 0)
    } catch {
        return $false
    }
}

# `$(cat "$p" 2>/dev/null || true)` - command substitution strips trailing
# newlines and a missing file is empty rather than an error.
function Get-FmNetCommandText {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    return (Get-FmFileText -Path $Path).TrimEnd("`n")
}

# `rm -f "$p" 2>/dev/null || true`
function Clear-FmNetFile {
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    try { [System.IO.File]::Delete((ConvertTo-FmNativePath -Path $Path)) } catch { $null = $_ }
}

<#
.SYNOPSIS
status_get: the LAST `<key>=` line's value, or '' when there is none.
.DESCRIPTION
`sed -n "s/^$1=//p" | tail -1`, including the two properties callers rely on:
a missing (or non-regular) status file yields '', and a key written twice
resolves to the last occurrence.
#>
function Get-FmNetStatusValue {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Key)
    if (-not (Test-FmNetFilePresent -Path $FmNetStatusFile)) { return '' }
    $prefix = "$Key="
    $value = ''
    foreach ($line in (Get-FmFileLines -Path $FmNetStatusFile)) {
        if ($line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $value = $line.Substring($prefix.Length)
        }
    }
    return $value
}

<#
.SYNOPSIS
age_of: seconds since <epoch>, or '' when the stamp is unreadable.
.DESCRIPTION
The empty answer is load-bearing in two places: worker_alive treats it as
ALIVE (an unparseable age must not retire a running worker) and print_pending
SKIPS its "Started Ns ago" line entirely.
#>
function Get-FmNetAge {
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Epoch)
    if ([string]::IsNullOrEmpty($Epoch) -or $Epoch -cnotmatch '^[0-9]+$') { return '' }
    [long]$then = 0
    if (-not [long]::TryParse($Epoch, [ref]$then)) { return '' }
    return [string]((Get-FmNetNow) - $then)
}

function Get-FmNetBudget {
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][long]$Fallback
    )
    $raw = Get-FmEnv -Name $Name -Default ([string]$Fallback)
    if ($raw -cnotmatch '^[0-9]+$') { return $Fallback }
    [long]$value = 0
    if (-not [long]::TryParse($raw, [ref]$value)) { return $Fallback }
    if ($value -eq 0) { return $Fallback }
    return $value
}

function Get-FmNetStageBudget {
    [OutputType([long])]
    param()
    return (Get-FmNetBudget -Name 'FM_STARTUP_NETWORK_TIMEOUT' -Fallback 120)
}

function Get-FmNetDeliveryBudget {
    [OutputType([long])]
    param()
    return (Get-FmNetBudget -Name 'FM_SESSION_START_TIMEOUT' -Fallback 120)
}

<#
.SYNOPSIS
worker_alive: is a `running` record a stage that is genuinely still in flight?
.DESCRIPTION
Two independent proofs, because either alone can lie: a recorded pid can be
reused, and a worker killed with its process group leaves the record untouched.
A record that outlives the stage's own aggregate bound is abandoned no matter
what its pid says, which keeps "in progress" from becoming permanent. An
unparseable age reads as ALIVE.
#>
function Test-FmNetWorkerAlive {
    [OutputType([bool])]
    param()
    $workerPid = Get-FmNetStatusValue -Key 'pid'
    if ($workerPid -cnotmatch '^[0-9]+$') { return $false }
    if (-not (Test-FmPidAlive -ProcessId $workerPid)) { return $false }
    $age = Get-FmNetAge -Epoch (Get-FmNetStatusValue -Key 'started')
    if ($age -cnotmatch '^[0-9]+$') { return $true }
    [long]$ageValue = 0
    if (-not [long]::TryParse($age, [ref]$ageValue)) { return $true }
    return ($ageValue -le ((Get-FmNetStageBudget) + 30))
}

# The exact phase names the digest and the report use, so "what has not been
# confirmed yet" is always answerable from the status record alone.
function Get-FmNetPhaseLabel {
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Phases)
    if ($Phases -ceq 'probe') { return 'GitHub authentication' }
    if ($Phases -ceq 'probe,sweeps') {
        return ('GitHub authentication, dead-secondmate relaunch, secondmate convergence, ' +
            'pending handoff delivery, and project clone refresh with its drift reporting')
    }
    return 'the deferred network checks'
}

# The twin of the bash `usage()` sed program: this file's own header, from the
# second line to the first line that is not a comment, with a leading '#' plus
# at most one space stripped.
function Get-FmNetUsage {
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $lines = Get-FmFileLines -Path $Path
    $out = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
        $body = $line.Substring(1)
        if ($body.StartsWith(' ', [System.StringComparison]::Ordinal)) { $body = $body.Substring(1) }
        $out.Add($body)
    }
    return , $out.ToArray()
}

# --- private port of bin/fm-timing-lib.sh ------------------------------------
#
# Delete in favour of a shared fm-timing-lib.psm1 when one exists.

function Get-FmNetNowMillisecond {
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

<#
.SYNOPSIS
fm_timing_sanitize: an identity, or the literal 'unrecordable'.
.DESCRIPTION
A detail carrying ANY whitespace is not a truncated identity, it is free text
that arrived from somewhere it should not have, so it is dropped entirely
rather than cleaned up - cleaning would leave the token in `KEY=secret` behind.
What remains is narrowed to [A-Za-z0-9._@:/+-] and truncated, which is what
stops a detail from forging extra tab-separated records. The whitespace class
is the C locale's [[:space:]] spelled out, not .NET's `\s`, which also matches
Unicode spaces the bash twin would keep.
#>
function Get-FmNetTimingDetail {
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    if ($Text -cmatch "[ `t`n`v`f`r]") { return 'unrecordable' }
    $clean = $Text -creplace '[^A-Za-z0-9._@:/+-]', '_'
    if ($clean.Length -gt $FmNetTimingDetailMax) { $clean = $clean.Substring(0, $FmNetTimingDetailMax) }
    return $clean
}

# fm_timing_start: point recording at <file> and stamp the shared origin. The
# file is created empty so a run that dies before its first record still
# publishes an empty-but-present artifact.
function Initialize-FmNetTiming {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        Set-FmFileText -Path $Path -Text '' -NoNewline
    } catch {
        $null = $_
        return
    }
    $script:FmNetTimingLog = $Path
    $script:FmNetTimingEpochMs = Get-FmNetNowMillisecond
}

# fm_timing_record: never fails the caller. A missing log, an unwritable path,
# or a malformed start stamp all resolve to "no record", never an error.
function Add-FmNetTimingRecord {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Scope,
        [Parameter(Mandatory, Position = 1)][string]$Name,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Start,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$Detail = ''
    )
    if ([string]::IsNullOrEmpty($script:FmNetTimingLog)) { return }
    if ([string]::IsNullOrEmpty($Start) -or $Start -cnotmatch '^[0-9]+$') { return }
    [long]$startMs = 0
    if (-not [long]::TryParse($Start, [ref]$startMs)) { return }
    $now = Get-FmNetNowMillisecond
    if ($script:FmNetTimingEpochMs -le 0) { $script:FmNetTimingEpochMs = $now }
    $offset = $startMs - $script:FmNetTimingEpochMs
    if ($offset -lt 0) { $offset = 0 }
    $elapsed = $now - $startMs
    if ($elapsed -lt 0) { $elapsed = 0 }
    $record = "v1`t$(Get-FmNetTimingDetail -Text $Scope)`t$(Get-FmNetTimingDetail -Text $Name)`t$offset`t$elapsed`t$(Get-FmNetTimingDetail -Text $Detail)"
    try {
        Add-FmFileLine -Path $script:FmNetTimingLog -Line $record
    } catch {
        $null = $_
    }
}

# awk's `$n + 0`: the longest numeric prefix, or 0.
function Get-FmNetAwkNumber {
    [OutputType([long])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $m = [regex]::Match($Text, '^[ \t]*[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)')
    if (-not $m.Success) { return 0 }
    [double]$value = 0
    if (-not [double]::TryParse($m.Value.Trim(), [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return 0
    }
    return [long][Math]::Truncate($value)
}

<#
.SYNOPSIS
fm_timing_render: a recorded run, for a human. Nothing at all when there is none.
.DESCRIPTION
The awk program's rules in order: skip any line whose first field is not `v1`
or which has fewer than 5 fields; print one aligned line per record; then order
by elapsed DESCENDING with the awk program's own swap loop (only a strictly
greater value swaps, so ties keep their recorded order) and name the three
slowest.
#>
function Format-FmNetTimingReport {
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $out = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-FmNetFileNonEmpty -Path $Path)) {
        return , $out.ToArray()
    }
    $scope = [System.Collections.Generic.List[string]]::new()
    $name = [System.Collections.Generic.List[string]]::new()
    $offset = [System.Collections.Generic.List[long]]::new()
    $elapsed = [System.Collections.Generic.List[long]]::new()
    $detail = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmFileLines -Path $Path)) {
        $fields = @($line.Split("`t"))
        if ($fields.Count -lt 5 -or $fields[0] -cne 'v1') { continue }
        $scope.Add($fields[1])
        $name.Add($fields[2])
        $offset.Add((Get-FmNetAwkNumber -Text $fields[3]))
        $elapsed.Add((Get-FmNetAwkNumber -Text $fields[4]))
        if ($fields.Count -ge 6) { $detail.Add($fields[5]) } else { $detail.Add('') }
    }
    $records = $scope.Count
    if ($records -eq 0) { return , $out.ToArray() }
    $out.Add('TIMINGS - where the deferred network checks spent their time (ms):')
    for ($i = 0; $i -lt $records; $i++) {
        $label = $name[$i]
        if ($detail[$i] -cne '') { $label = "$label $($detail[$i])" }
        $out.Add('  ' + $scope[$i].PadRight(11) + ' ' + $label.PadRight(42) +
            ' start=+' + ([string]$offset[$i]).PadRight(7) + ' elapsed=' + $elapsed[$i])
    }
    for ($i = 0; $i -lt $records; $i++) {
        for ($j = $i + 1; $j -lt $records; $j++) {
            if ($elapsed[$j] -gt $elapsed[$i]) {
                $t = $scope[$i]; $scope[$i] = $scope[$j]; $scope[$j] = $t
                $t = $name[$i]; $name[$i] = $name[$j]; $name[$j] = $t
                $n = $offset[$i]; $offset[$i] = $offset[$j]; $offset[$j] = $n
                $n = $elapsed[$i]; $elapsed[$i] = $elapsed[$j]; $elapsed[$j] = $n
                $t = $detail[$i]; $detail[$i] = $detail[$j]; $detail[$j] = $t
            }
        }
    }
    $top = if ($records -lt 3) { $records } else { 3 }
    $line = ''
    for ($i = 0; $i -lt $top; $i++) {
        $label = $name[$i]
        if ($detail[$i] -cne '') { $label = "$label $($detail[$i])" }
        if ($line -cne '') { $line = "$line, " }
        $line = "$line$($scope[$i]) $label $($elapsed[$i])ms"
    }
    $out.Add("  slowest: $line")
    return , $out.ToArray()
}

# --- private port of bin/fm-timeout-lib.sh -----------------------------------
#
# fm_run_timed's one used shape: a hard bound, exit 124 when it is hit, the
# whole process TREE terminated (Kill($true) is the Windows analogue of the
# negative-pid process-group kill every bash mechanism performs), and the
# child's merged output captured even when the bound cut it off. Delete in
# favour of a shared fm-timeout-lib.psm1 when one exists.
function Invoke-FmNetBounded {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][long]$Seconds,
        [Parameter(Mandatory)][hashtable]$Command,
        [Parameter(Mandatory)][hashtable]$Environment,
        [Parameter(Mandatory)][string]$OutFile
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Command.FilePath
    foreach ($a in $Command.Arguments) { $psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }

    $text = [System.Text.StringBuilder]::new()
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $rc = 0
    try {
        try {
            [void]$proc.Start()
        } catch {
            $null = $_
            # `env <cmd>` with an unrunnable command: 127, the same code the
            # bash twin's caller sees and reports as "the worker exited 127".
            Set-FmFileText -Path $OutFile -Text '' -NoNewline
            return 127
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        $timedOut = $false
        $outTask = $proc.StandardOutput.ReadLineAsync()
        $errTask = $proc.StandardError.ReadLineAsync()
        while ($null -ne $outTask -or $null -ne $errTask) {
            $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
            if ($null -ne $outTask) { $pending.Add($outTask) }
            if ($null -ne $errTask) { $pending.Add($errTask) }
            [void][System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), 200)
            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $line = $null
                try { $line = $outTask.GetAwaiter().GetResult() } catch { $line = $null }
                if ($null -eq $line) {
                    $outTask = $null
                } else {
                    [void]$text.Append($line).Append("`n")
                    $outTask = $proc.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $line = $null
                try { $line = $errTask.GetAwaiter().GetResult() } catch { $line = $null }
                if ($null -eq $line) {
                    $errTask = $null
                } else {
                    [void]$text.Append($line).Append("`n")
                    $errTask = $proc.StandardError.ReadLineAsync()
                }
            }
            if (-not $timedOut -and [DateTime]::UtcNow -gt $deadline) {
                $timedOut = $true
                try { $proc.Kill($true) } catch { $null = $_ }
            }
        }
        try { $proc.WaitForExit() } catch { $null = $_ }
        if ($timedOut) {
            $rc = 124
        } else {
            try { $rc = $proc.ExitCode } catch { $rc = 124 }
        }
    } finally {
        $proc.Dispose()
    }
    Set-FmFileText -Path $OutFile -Text $text.ToString() -NoNewline
    return $rc
}

# --- sibling resolution ------------------------------------------------------

<#
.SYNOPSIS
The invocation for a sibling firstmate script, PowerShell twin preferred.
.DESCRIPTION
Contract 7's resolution rule, applied the way Get-FmDaemonWatcherInvocation
applies it: Invoke-FmScript is the sanctioned way to RUN a sibling and is not
usable at either call site here - one needs a hard bound with merged output
into a file, and the other must not wait for its child at all - so the RULE is
reused rather than an extension hard-coded. Returns $null when neither twin
exists.
#>
function Resolve-FmNetSibling {
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $psTwin = Join-Path $PSScriptRoot "$Name.ps1"
    if ((Test-Path -LiteralPath $psTwin) -and ((Get-Item -LiteralPath $psTwin).Length -gt 0)) {
        # The running pwsh, so the child inherits this exact version.
        $self = (Get-Process -Id $PID).Path
        if (-not $self) { $self = 'pwsh' }
        return @{ FilePath = $self; Arguments = @('-NoProfile', '-File', $psTwin); IsPowerShell = $true }
    }
    $shTwin = Join-Path $PSScriptRoot "$Name.sh"
    if (Test-Path -LiteralPath $shTwin) {
        $bash = Get-FmBash
        if (-not $bash) { return $null }
        # Bash receives a POSIX path: it cannot be relied on to accept a Windows
        # drive path as a script argument.
        return @{ FilePath = $bash; Arguments = @((ConvertTo-FmPosixPath -Path $shTwin)); IsPowerShell = $false }
    }
    return $null
}

# --- start -------------------------------------------------------------------

<#
.SYNOPSIS
Launch the detached worker and return immediately.
.DESCRIPTION
See this file's header for why this launch shape and no other. The publish lock
is held ACROSS the launch on purpose: the worker's first act is to take that
same lock and confirm the status record names IT, so releasing early would let
the worker read the `pid=0` placeholder and retire itself.
#>
function Start-FmNetWorker {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Launches the detached stage worker, which IS the job of this command; its bash twin launches unconditionally and a confirmation surface would leave the deferred network checks unstarted on every session open.')]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Locked,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LockPid,
        [Parameter(Mandatory)][string]$Generation
    )
    $self = Resolve-FmNetSibling -Name 'fm-startup-network'
    if ($null -eq $self) { return 0 }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $self.FilePath
    foreach ($a in $self.Arguments) { $psi.ArgumentList.Add([string]$a) }
    foreach ($a in @('run', '--locked', $Locked, '--lock-pid', $LockPid, '--generation', $Generation)) {
        # ArgumentList, never a joined string: Start-Process and a hand-joined
        # command line both DROP an empty argument and SPLIT one containing a
        # space (measured), and --lock-pid is legitimately empty when the home
        # holds no lock - which would silently shift every argument after it.
        $psi.ArgumentList.Add([string]$a)
    }
    # UseShellExecute: the only launch shape that inherits no handles (header).
    $psi.UseShellExecute = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        return $proc.Id
    } catch {
        $null = $_
        return 0
    }
}

function Invoke-FmNetStart {
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Locked,
        [Parameter(Mandatory, Position = 1)][string]$HarvestPid
    )
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $FmNetState))
    } catch {
        return 1
    }
    # Captured HERE, at the moment the caller still holds the lock, and carried
    # to the worker: re-reading the lock later would only prove that SOME
    # session holds it, which is exactly the case this guard exists to reject.
    $lockPid = Get-FmNetCommandText -Path "$FmNetState/.lock"
    if ($Locked -ceq '1' -and -not (Test-FmSessionLockOwnedBySelf -State $FmNetState)) {
        return 1
    }

    Wait-FmLock -LockPath $FmNetPublishLock
    try {
        if ((Get-FmNetStatusValue -Key 'state') -ceq 'running' -and (Test-FmNetWorkerAlive) -and
            ($Locked -cne '1' -or (Get-FmNetStatusValue -Key 'lock_pid') -ceq $lockPid)) {
            # A worker from this or a previous session is still going. Starting a
            # second one would run the same mutating sweeps concurrently, so leave
            # it alone and let the harvest report its real state.
            $generation = Get-FmNetStatusValue -Key 'generation'
            try {
                Set-FmFileText -Path $FmNetClaimFile -Text "$generation`t$HarvestPid`n" -NoNewline
            } catch {
                $null = $_
            }
            return 0
        }

        $generation = "$(Get-FmNetNow).$PID.$HarvestPid"
        $started = Get-FmNetNow
        $phases = 'probe'
        if ($Locked -ceq '1') { $phases = 'probe,sweeps' }
        $record = "state=running`npid=0`nstarted=$started`nlocked=$Locked`nphases=$phases`n" +
            "generation=$generation`nlock_pid=$lockPid`n"
        if (-not (Set-FmFileTextAtomic -Path $FmNetStatusFile -Text $record -NoNewline)) {
            return 1
        }

        $workerPid = Start-FmNetWorker -Locked $Locked -LockPid $lockPid -Generation $generation
        $record = "state=running`npid=$workerPid`nstarted=$started`nlocked=$Locked`nphases=$phases`n" +
            "generation=$generation`nlock_pid=$lockPid`n"
        if (-not (Set-FmFileTextAtomic -Path $FmNetStatusFile -Text $record -NoNewline)) {
            if ($workerPid -gt 0) {
                try { [System.Diagnostics.Process]::GetProcessById($workerPid).Kill($true) } catch { $null = $_ }
            }
            return 1
        }
        try {
            Set-FmFileText -Path $FmNetClaimFile -Text "$generation`t$HarvestPid`n" -NoNewline
        } catch {
            $null = $_
        }
    } finally {
        Unlock-FmLock -LockPath $FmNetPublishLock
    }
    return 0
}

# --- run ---------------------------------------------------------------------

<#
.SYNOPSIS
lock_unchanged: does the fleet lock still name the session that asked for this?
.DESCRIPTION
Deliberately NOT "is that session still alive". The hazard being closed is a
SECOND session sweeping concurrently, and taking the lock is exactly what
rewrites this value, so an unchanged value proves no one else owns the sweeps.
A missing, unreadable, or replaced lock all fail closed to the read-only probe.
#>
function Test-FmNetLockUnchanged {
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Expected)
    if ([string]::IsNullOrEmpty($Expected) -or $Expected -cnotmatch '^[0-9]+$') { return $false }
    $lock = "$FmNetState/.lock"
    if (-not (Test-FmNetFilePresent -Path $lock)) { return $false }
    if (Test-FmSymlink -Path $lock) { return $false }
    return ((Get-FmNetCommandText -Path $lock) -ceq $Expected)
}

# The claim record: generation<TAB>pid, first line only.
function Get-FmNetClaimRecord {
    [OutputType([hashtable])]
    param()
    $text = Get-FmNetCommandText -Path $FmNetClaimFile
    $newline = $text.IndexOf("`n")
    if ($newline -ge 0) { $text = $text.Substring(0, $newline) }
    $tab = $text.IndexOf("`t")
    if ($tab -lt 0) { return @{ Generation = $text; ProcessId = '' } }
    return @{ Generation = $text.Substring(0, $tab); ProcessId = $text.Substring($tab + 1) }
}

function Get-FmNetWakePayload {
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$State)
    return ("check: startup-network: deferred startup network checks finished ($State); " +
        "read them with $FmNetRoot/bin/fm-startup-network.sh report")
}

function Wait-FmNetDelivery {
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Generation,
        [Parameter(Mandatory, Position = 1)][string]$State
    )
    $limit = (Get-FmNetDeliveryBudget) * 10
    $waited = 0
    while ($waited -lt $limit) {
        $claimLive = $false
        $settled = $false
        Wait-FmLock -LockPath $FmNetPublishLock
        try {
            if ((Get-FmNetStatusValue -Key 'generation') -cne $Generation) {
                $settled = $true
            } elseif (Test-FmNetFilePresent -Path $FmNetDeliveredFile) {
                $settled = $true
            } else {
                if (Test-FmNetFilePresent -Path $FmNetClaimFile) {
                    $claim = Get-FmNetClaimRecord
                    if ($claim.Generation -ceq $Generation -and $claim.ProcessId -cmatch '^[0-9]+$' -and
                        (Test-FmPidAlive -ProcessId $claim.ProcessId)) {
                        $claimLive = $true
                    }
                    if (-not $claimLive) { Clear-FmNetFile -Path $FmNetClaimFile }
                }
                if (-not $claimLive) {
                    [void](Add-FmWake -Kind 'check' -Key 'startup-network' -Payload (Get-FmNetWakePayload -State $State))
                    $settled = $true
                }
            }
        } finally {
            Unlock-FmLock -LockPath $FmNetPublishLock
        }
        if ($settled) { return }
        Start-Sleep -Milliseconds 100
        $waited++
    }
    Wait-FmLock -LockPath $FmNetPublishLock
    try {
        if ((Get-FmNetStatusValue -Key 'generation') -cne $Generation) { return }
        if (Test-FmNetFilePresent -Path $FmNetDeliveredFile) { return }
        [void](Add-FmWake -Kind 'check' -Key 'startup-network' -Payload (Get-FmNetWakePayload -State $State))
    } finally {
        Unlock-FmLock -LockPath $FmNetPublishLock
    }
}

function Publish-FmNetResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Publishes the finished stage result; its bash twin publishes unconditionally and a confirmation surface would strand the result the whole stage exists to deliver.')]
    param(
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Phases,
        [Parameter(Mandatory)][string]$Locked,
        [Parameter(Mandatory)][string]$Started,
        [Parameter(Mandatory)][string]$Rc,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Timings
    )
    $state = $State
    $rc = $Rc
    $reportPublished = 1
    $settled = $false
    Wait-FmLock -LockPath $FmNetPublishLock
    try {
        if ((Get-FmNetStatusValue -Key 'generation') -cne $Generation) {
            $settled = $true
        } else {
            # Timings are published for EVERY outcome, including timeout and
            # failure: a run that hit the bound is exactly the run whose per-step
            # record is worth having. A timing record is diagnostic only, so a
            # failure to publish it is discarded rather than downgrading the run.
            if (-not [string]::IsNullOrEmpty($Timings) -and (Test-FmNetFilePresent -Path $Timings)) {
                [void](Set-FmFileTextAtomic -Path $FmNetTimingsFile `
                        -Text (Get-FmFileText -Path $Timings) -NoNewline)
            }
            if (-not (Set-FmFileTextAtomic -Path $FmNetReportFile `
                        -Text (Get-FmFileText -Path $OutFile) -NoNewline)) {
                $state = 'failed'
                $rc = '1'
                $reportPublished = 0
            }
            Clear-FmNetFile -Path $FmNetDeliveredFile
            $record = "state=$state`npid=$PID`nstarted=$Started`nfinished=$(Get-FmNetNow)`nrc=$rc`n" +
                "locked=$Locked`nphases=$Phases`ngeneration=$Generation`n" +
                "lock_pid=$(Get-FmNetStatusValue -Key 'lock_pid')`nreport_published=$reportPublished`n"
            [void](Set-FmFileTextAtomic -Path $FmNetStatusFile -Text $record -NoNewline)
        }
    } finally {
        Unlock-FmLock -LockPath $FmNetPublishLock
    }
    if ($settled) { return }
    Wait-FmNetDelivery -Generation $Generation -State $state
}

# `mktemp "${TMPDIR:-/tmp}/<prefix>.XXXXXX"`, or '' when the directory refuses.
function New-FmNetTempFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a private scratch file, the mktemp twin; its bash twin creates unconditionally and a confirmation surface would stall a detached worker with no terminal.')]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Prefix)
    $base = Get-FmEnv -Name 'TMPDIR' -Default ''
    if ([string]::IsNullOrEmpty($base)) {
        $dir = [System.IO.Path]::GetTempPath()
    } else {
        $dir = ConvertTo-FmNativePath -Path $base
    }
    try {
        $candidate = Join-Path $dir ("$Prefix." + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($candidate, '', [System.Text.UTF8Encoding]::new($false))
        return $candidate
    } catch {
        $null = $_
        return ''
    }
}

function Invoke-FmNetBootstrap {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][long]$Budget,
        [Parameter(Mandatory)][bool]$SweepLocked,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LockPid,
        [Parameter(Mandatory)][string]$OutFile
    )
    $bootstrap = Resolve-FmNetSibling -Name 'fm-bootstrap'
    if ($null -eq $bootstrap) {
        Set-FmFileText -Path $OutFile -Text '' -NoNewline
        return 127
    }
    $environment = @{ FM_BOOTSTRAP_NETWORK = 'only' }
    if ($SweepLocked) {
        $environment['FM_BOOTSTRAP_NETWORK_LOCK_PID'] = $LockPid
    } else {
        $environment['FM_BOOTSTRAP_DETECT_ONLY'] = '1'
    }
    # FM_TIMING_LOG reaches the sweeps as an exported variable in bash; here it
    # is handed to the one child that needs it, spelled the way THAT child reads
    # paths. FM_TIMING_EPOCH_MS travels with it so every record carries an offset
    # from ONE origin even though several processes write them.
    if (-not [string]::IsNullOrEmpty($script:FmNetTimingLog)) {
        if ($bootstrap.IsPowerShell) {
            $environment['FM_TIMING_LOG'] = ConvertTo-FmNativePath -Path $script:FmNetTimingLog
        } else {
            $environment['FM_TIMING_LOG'] = ConvertTo-FmPosixPath -Path $script:FmNetTimingLog
        }
        $environment['FM_TIMING_EPOCH_MS'] = [string]$script:FmNetTimingEpochMs
    }
    return (Invoke-FmNetBounded -Seconds $Budget -Command $bootstrap -Environment $environment -OutFile $OutFile)
}

function Invoke-FmNetRun {
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Locked,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$LockPid,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$Generation
    )
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $FmNetState))
    } catch {
        return 1
    }
    $locked = $Locked
    $lockPid = $LockPid
    $generation = $Generation
    $started = [string](Get-FmNetNow)
    $budget = Get-FmNetStageBudget
    $phases = 'probe'
    $sweepLocked = $false
    $downgraded = $false
    $internal = $false

    if (-not [string]::IsNullOrEmpty($generation)) {
        Wait-FmLock -LockPath $FmNetPublishLock
        try {
            if ((Get-FmNetStatusValue -Key 'generation') -ceq $generation -and
                (Get-FmNetStatusValue -Key 'pid') -ceq ([string]$PID)) {
                $internal = $true
                $started = Get-FmNetStatusValue -Key 'started'
            }
        } finally {
            Unlock-FmLock -LockPath $FmNetPublishLock
        }
        if (-not $internal) { return 1 }
    } elseif ($locked -ceq '1' -and -not (Test-FmSessionLockOwnedBySelf -State $FmNetState)) {
        $downgraded = $true
        $locked = '0'
    }
    if ($locked -ceq '1') {
        if (-not $internal) { $lockPid = Get-FmNetCommandText -Path "$FmNetState/.lock" }
        if (Test-FmNetLockUnchanged -Expected $lockPid) {
            $sweepLocked = $true
            $phases = 'probe,sweeps'
        } else {
            $downgraded = $true
        }
    }

    if (-not $internal) {
        $generation = "$(Get-FmNetNow).$PID.manual"
        Wait-FmLock -LockPath $FmNetPublishLock
        $refused = $false
        try {
            if ((Get-FmNetStatusValue -Key 'state') -ceq 'running' -and (Test-FmNetWorkerAlive)) {
                $refused = $true
            } else {
                $sweepFlag = if ($sweepLocked) { '1' } else { '0' }
                $record = "state=running`npid=$PID`nstarted=$started`nlocked=$sweepFlag`n" +
                    "phases=$phases`ngeneration=$generation`nlock_pid=$lockPid`n"
                [void](Set-FmFileTextAtomic -Path $FmNetStatusFile -Text $record -NoNewline)
            }
        } finally {
            Unlock-FmLock -LockPath $FmNetPublishLock
        }
        if ($refused) { return 1 }
    }

    # Recorded into a temp file rather than straight into state/ so a run that is
    # killed mid-sweep cannot leave a half-written artifact where the previous
    # run's complete one used to be; publish promotes it atomically at the end.
    $out = New-FmNetTempFile -Prefix 'fm-startup-network'
    if ([string]::IsNullOrEmpty($out)) { return 1 }
    $timings = New-FmNetTempFile -Prefix 'fm-startup-network-timings'
    if (-not [string]::IsNullOrEmpty($timings)) { Initialize-FmNetTiming -Path $timings }
    $stageStarted = [string](Get-FmNetNowMillisecond)
    $rc = 0
    $leaseHeld = $false
    try {
        if ($sweepLocked) {
            Wait-FmLock -LockPath "$FmNetState/.lock.acquire"
            $leaseHeld = $true
            if (-not (Test-FmNetLockUnchanged -Expected $lockPid)) {
                $sweepLocked = $false
                $phases = 'probe'
                $downgraded = $true
            }
        }
        $rc = Invoke-FmNetBootstrap -Budget $budget -SweepLocked $sweepLocked -LockPid $lockPid -OutFile $out
    } finally {
        if ($leaseHeld) { Unlock-FmLock -LockPath "$FmNetState/.lock.acquire" }
    }
    # The bounded run as a whole, so the per-phase records can be read against
    # the total even when the bound cut some of them off.
    Add-FmNetTimingRecord -Scope 'stage' -Name 'network-checks' -Start $stageStarted -Detail $phases

    if ($downgraded) {
        Add-FmFileLine -Path $out -Line ('NETWORK_CHECKS: the fleet lock was no longer held by the session that ' +
            'requested these, so dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and ' +
            'project clone refresh were skipped; they belong to whichever session holds the lock now')
    }
    $sweepFlag = if ($sweepLocked) { '1' } else { '0' }
    if ($rc -eq 0) {
        Publish-FmNetResult -Generation $generation -State 'done' -Phases $phases -Locked $sweepFlag `
            -Started $started -Rc ([string]$rc) -OutFile $out -Timings $timings
    } elseif ($rc -eq 124) {
        Add-FmFileLine -Path $out -Line ("NETWORK_CHECKS: hit the ${budget}s bound before finishing, so " +
            "$(Get-FmNetPhaseLabel -Phases $phases) may be incomplete; rerun " +
            "$FmNetRoot/bin/fm-startup-network.sh run --locked $sweepFlag")
        Publish-FmNetResult -Generation $generation -State 'timeout' -Phases $phases -Locked $sweepFlag `
            -Started $started -Rc ([string]$rc) -OutFile $out -Timings $timings
    } else {
        Add-FmFileLine -Path $out -Line ("NETWORK_CHECKS: the deferred check worker exited $rc, so " +
            "$(Get-FmNetPhaseLabel -Phases $phases) may be incomplete; rerun " +
            "$FmNetRoot/bin/fm-startup-network.sh run --locked $sweepFlag")
        Publish-FmNetResult -Generation $generation -State 'failed' -Phases $phases -Locked $sweepFlag `
            -Started $started -Rc ([string]$rc) -OutFile $out -Timings $timings
    }
    Clear-FmNetFile -Path $out
    if (-not [string]::IsNullOrEmpty($timings)) { Clear-FmNetFile -Path $timings }
    return 0
}

# --- harvest / report --------------------------------------------------------

function Write-FmNetFinished {
    param([Parameter(Mandatory, Position = 0)][string]$State)
    $phases = Get-FmNetStatusValue -Key 'phases'
    $started = Get-FmNetStatusValue -Key 'started'
    $finished = Get-FmNetStatusValue -Key 'finished'
    $reportPublished = Get-FmNetStatusValue -Key 'report_published'
    $took = 'unknown'
    $joined = "$started$finished"
    if ($joined -cmatch '^[0-9]+$') {
        # `$((finished - started))` with either side empty treats it as 0, which
        # is how a half-written record still renders a number here.
        [long]$startedValue = 0
        [long]$finishedValue = 0
        [void][long]::TryParse($started, [ref]$startedValue)
        [void][long]::TryParse($finished, [ref]$finishedValue)
        $took = [string]($finishedValue - $startedValue)
    }
    Write-FmOut -Text "completed off the startup path in ${took}s: $(Get-FmNetPhaseLabel -Phases $phases)."
    if ($State -cne 'done') {
        Write-FmOut -Text ("The stage itself did not finish cleanly ($State) - the NETWORK_CHECKS line below " +
            'names what to rerun.')
    }
    if ($reportPublished -ceq '0') {
        Write-FmOut -Text ('NETWORK_CHECKS: could not publish the deferred check report, so ' +
            "$(Get-FmNetPhaseLabel -Phases $phases) results are unavailable; rerun " +
            "$FmNetRoot/bin/fm-startup-network.sh run --locked $(Get-FmNetStatusValue -Key 'locked')")
    } elseif (Test-FmNetFileNonEmpty -Path $FmNetReportFile) {
        Write-FmRaw -Text (Get-FmFileText -Path $FmNetReportFile)
        Write-FmOut -Text ('These ran AFTER the sections above were composed, so re-read any record a line ' +
            'here names.')
    } else {
        Write-FmOut -Text '(silent - no problems found)'
    }
}

# Deliberately NOT part of print_state, and so deliberately not part of harvest:
# harvest composes the digest's NETWORK CHECKS section, and this record is
# diagnostic detail nobody needs on an ordinary session start.
function Write-FmNetTimingReport {
    param()
    foreach ($line in (Format-FmNetTimingReport -Path $FmNetTimingsFile)) { Write-FmOut -Text $line }
}

function Write-FmNetPending {
    param()
    $phases = Get-FmNetStatusValue -Key 'phases'
    $age = Get-FmNetAge -Epoch (Get-FmNetStatusValue -Key 'started')
    Write-FmOut -Text 'IN PROGRESS - the deferred network checks have not finished yet.'
    Write-FmOut -Text "NOT yet confirmed: $(Get-FmNetPhaseLabel -Phases $phases)."
    if (-not [string]::IsNullOrEmpty($age)) {
        Write-FmOut -Text "Started ${age}s ago, bounded at $(Get-FmNetStageBudget)s."
    }
    # Single-quoted: the backticked wake name is literal digest text, and a
    # backtick is PowerShell's escape character.
    Write-FmOut -Text 'The result is durable in state/.startup-network.report and arrives as a `check: startup-network` wake.'
    Write-FmOut -Text "Read it now with $FmNetRoot/bin/fm-startup-network.sh report; until it lands, treat none of it as confirmed."
}

function Write-FmNetState {
    param()
    $state = Get-FmNetStatusValue -Key 'state'
    if ($state -ceq 'done' -or $state -ceq 'timeout' -or $state -ceq 'failed') {
        Write-FmNetFinished -State $state
    } elseif ($state -ceq 'running') {
        if (Test-FmNetWorkerAlive) {
            Write-FmNetPending
        } else {
            Write-FmOut -Text ('NETWORK_CHECKS: the deferred check worker stopped before publishing, so ' +
                "$(Get-FmNetPhaseLabel -Phases (Get-FmNetStatusValue -Key 'phases')) did not complete; rerun " +
                "$FmNetRoot/bin/fm-startup-network.sh run --locked $(Get-FmNetStatusValue -Key 'locked')")
        }
    } else {
        Write-FmOut -Text 'not started - no deferred network checks have run for this home yet.'
    }
}

function Invoke-FmNetHarvest {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$HarvestPid)
    Wait-FmLock -LockPath $FmNetPublishLock
    try {
        $generation = Get-FmNetStatusValue -Key 'generation'
        # Another session's live claim is left alone; the worker reaps a dead one.
        if (Test-FmNetFilePresent -Path $FmNetClaimFile) {
            $claim = Get-FmNetClaimRecord
            if ($claim.Generation -ceq $generation -and
                ([string]::IsNullOrEmpty($HarvestPid) -or $claim.ProcessId -ceq $HarvestPid)) {
                Clear-FmNetFile -Path $FmNetClaimFile
            }
        }
        $state = Get-FmNetStatusValue -Key 'state'
        Write-FmNetState
        if ($state -ceq 'done' -or $state -ceq 'timeout' -or $state -ceq 'failed') {
            if ((Get-FmNetStatusValue -Key 'report_published') -cne '0') {
                [void](Set-FmFileTextAtomic -Path $FmNetDeliveredFile -Text "delivered`n" -NoNewline)
            }
        }
    } finally {
        Unlock-FmLock -LockPath $FmNetPublishLock
    }
}

function Wait-FmNetPublication {
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Seconds)
    [long]$limit = 120
    if ($Seconds -cmatch '^[0-9]+$') {
        [long]$parsed = 0
        if ([long]::TryParse($Seconds, [ref]$parsed)) { $limit = $parsed }
    }
    $waited = 0
    while ($waited -lt $limit) {
        $state = Get-FmNetStatusValue -Key 'state'
        if ($state -ceq 'done' -or $state -ceq 'timeout' -or $state -ceq 'failed') { return 0 }
        if ($state -ceq 'running' -and -not (Test-FmNetWorkerAlive)) { return 1 }
        Start-Sleep -Seconds 1
        $waited++
    }
    return 1
}

# --- entry -------------------------------------------------------------------

Invoke-FmMain -UnexpectedCode 70 {
    $locked = '0'
    $harvestPid = ''
    $lockPid = ''
    $generation = ''
    $mode = ''
    if ($fmArgv.Count -gt 0) { $mode = [string]$fmArgv[0] }
    if ($fmArgv.Count -gt 1) { $rest = @($fmArgv[1..($fmArgv.Count - 1)]) } else { $rest = @() }

    # The bash flag loop, argument for argument: a flag consumes its value when
    # one is present, a missing value leaves the default, and the FIRST
    # non-flag argument breaks the loop and stays available as a positional.
    $index = 0
    while ($index -lt $rest.Count) {
        $flag = [string]$rest[$index]
        $value = ''
        if ($index + 1 -lt $rest.Count) { $value = [string]$rest[$index + 1] }
        if ($flag -ceq '--locked') {
            $locked = $value
            if ($index + 1 -lt $rest.Count) { $index += 2 } else { $index += 1 }
        } elseif ($flag -ceq '--harvest-pid' -or $flag -ceq '--pid') {
            $harvestPid = $value
            if ($index + 1 -lt $rest.Count) { $index += 2 } else { $index += 1 }
        } elseif ($flag -ceq '--lock-pid') {
            $lockPid = $value
            if ($index + 1 -lt $rest.Count) { $index += 2 } else { $index += 1 }
        } elseif ($flag -ceq '--generation') {
            $generation = $value
            if ($index + 1 -lt $rest.Count) { $index += 2 } else { $index += 1 }
        } elseif ($flag -ceq '-h' -or $flag -ceq '--help') {
            foreach ($line in (Get-FmNetUsage -Path $fmScriptPath)) { Write-FmOut -Text $line }
            Exit-FmScript 0
        } else {
            break
        }
    }
    if ($index -lt $rest.Count) { $positional = @($rest[$index..($rest.Count - 1)]) } else { $positional = @() }
    if ($locked -cne '0' -and $locked -cne '1') { $locked = '0' }

    if ($mode -ceq 'start') {
        [void](Invoke-FmNetStart -Locked $locked -HarvestPid $(if ([string]::IsNullOrEmpty($harvestPid)) { '0' } else { $harvestPid }))
    } elseif ($mode -ceq 'run') {
        [void](Invoke-FmNetRun -Locked $locked -LockPid $lockPid -Generation $generation)
    } elseif ($mode -ceq 'harvest') {
        Invoke-FmNetHarvest -HarvestPid $harvestPid
    } elseif ($mode -ceq 'report') {
        Write-FmNetState
        Write-FmNetTimingReport
    } elseif ($mode -ceq 'wait') {
        $seconds = '120'
        if ($positional.Count -gt 0) { $seconds = [string]$positional[0] }
        $rc = Wait-FmNetPublication -Seconds $seconds
        if ($rc -ne 0) { Exit-FmScript $rc }
    } elseif ($mode -ceq '-h' -or $mode -ceq '--help') {
        foreach ($line in (Get-FmNetUsage -Path $fmScriptPath)) { Write-FmOut -Text $line }
    } else {
        $shown = $mode
        if ([string]::IsNullOrEmpty($shown)) { $shown = '<none>' }
        Write-FmErr -Text "fm-startup-network: unknown mode: $shown"
        Write-FmErr -Text 'usage: fm-startup-network.sh start|run|harvest|report|wait'
        Exit-FmScript 2
    }
}
