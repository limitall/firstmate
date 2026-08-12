# bin/fm-watch-arm.ps1 - safe, home-scoped (re-)arm of the firstmate watcher,
# with honest verification.
#
# Twin: bin/fm-watch-arm.sh
#
# Usage: fm-watch-arm.ps1 [--restart]
#
# The watcher (bin/fm-watch.ps1) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit, so firstmate must run this script as the harness's
# own tracked background task, or - for a Claude primary - inside the Stop
# asyncRewake hook's foreground process tree (bin/fm-claude-stop-autoarm.*).
# Run it as its own standalone background task, never bundled onto the tail of
# another command, and never fire-and-forget behind a shell `&`: that
# backgrounded child is reaped when the call returns, leaving NO watcher running
# and a false "already running" off the dying process. That exact mistake
# silently took supervision down for ~30 minutes.
#
# This script starts the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE, and
# prints exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)
#   watcher: attached pid=<N> (beacon <age>s)
#   watcher: FAILED - no live watcher with a fresh beacon
#   watcher: FAILED - cycle ended without an actionable reason
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused
# pid. On FAILED it exits non-zero so the failure is loud.
#
# ============================================================================
# WHY THIS IS A SINGLE .ps1 AND NOT A HYBRID PAIR
# ============================================================================
# bin/fm-watch.sh carries a `BASH_SOURCE` guard, so its twin is a PAIR
# (docs/powershell-port.md, "Exception - hybrids"). bin/fm-watch-arm.sh carries
# NO such guard - it is a plain program - so its twin stays 1:1, and the
# differential suite reaches the helpers below the same way it reaches the bash
# twin's: by extracting the definition prefix of each file (everything above the
# "--- main" marker) and loading THAT. The two sides are therefore tested by the
# identical technique, and no guard idiom that production never exercises is
# invented here.
#
# ============================================================================
# THE THREE THINGS THAT MUST NOT DRIFT
# ============================================================================
# 1. NEVER BROADLY KILL WATCHERS. --restart stops ONLY the pid recorded in THIS
#    FM_HOME's state/.watch.lock, and only after Test-FmWatcherLockMatchesPid
#    confirms that pid really is this home's watcher (the guard against a
#    recycled pid). There is deliberately no name/pattern/command-line matching
#    anywhere in this file: a pattern like `pkill -f bin/fm-watch` matches EVERY
#    firstmate home's watcher, because secondmate homes run the same script, and
#    would kill siblings (AGENTS.md section 8). That refusal is structural here,
#    exactly as in the bash twin - the only process this script may ever
#    terminate is one integer read out of this home's own lock.
# 2. THE SINGLETON IS ABSOLUTE, AND UNCERTAINTY MEANS "HELD". Nothing here takes
#    or steals a lock; bin/fm-wake-lib.psm1 owns that protocol, including both
#    on-disk representations. This script only ever ASKS whether a healthy
#    watcher exists, and the honesty gate (Test-FmWatcherHealthy) fails closed on
#    a dead pid, a reused pid, or a stale beacon.
# 3. SIGNALS DO NOT EXIST HERE (docs/powershell-port.md). The bash twin installs
#    six traps mapping HUP/TERM/INT to exit codes 129/143/130. Windows has no HUP
#    or TERM at all, so those codes are NOT faked:
#      * Ctrl-C IS reproduced, because it genuinely exists: a CancelKeyPress
#        handler sets a flag, the wait loops observe it, and the arm tears the
#        child down and exits 130 with an arm-interrupted ledger row - the same
#        outcome the INT trap produces.
#      * HUP and TERM have no twin. A hard TerminateProcess of this arm delivers
#        nothing, so the watcher it launched is ORPHANED rather than torn down.
#        That is not a correctness hole: the orphan still holds the singleton
#        lock and still beats, so the next arm recognizes it as healthy and
#        ATTACHES instead of starting a second one. It is recorded here so a
#        later reader does not mistake the missing trap for an oversight.
#      * cycle_signal_name's `kill -l` has no twin either. A Windows process
#        cannot exit via a POSIX signal, so a >128 code is reported by NUMBER -
#        which is precisely the bash twin's own fallback branch when `kill -l`
#        cannot name it, not an invented value.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
# For Resolve-FmWatchSibling: the arm needs the watcher's PATH (to launch it as
# a tracked child and to compare against the lock's watcher-path token), not a
# synchronous run, and fm-watch.psm1 is the single owner of that resolution.
Import-Module (Join-Path $PSScriptRoot 'fm-watch.psm1') -Force

$fmArgv = @($args)

# --- context and knobs -------------------------------------------------------

$FmArmContext = Get-FmContext -ScriptRoot $PSScriptRoot
$FmArmState = $FmArmContext.State
# The RAW home value, matching what the lock records (fm-watch.psm1 note 4).
$FmArmHome = (Get-FmWatchContext).HomeToken
# TWO spellings of "the watcher", and the distinction is load-bearing.
# $FmArmWatch is a real PATH, used only to LAUNCH the child. $FmArmWatchToken is
# the identity string the watcher publishes into the lock, which every reader -
# including the bash-only bin/fm-pr-check-migrate.sh - compares literally. Asking
# the honesty gate with the launch path instead of the token would make every
# healthy watcher read as unrecognized, so this arm would start a second one.
# fm-watch.psm1 owns both (see its divergence note 4).
$FmArmWatch = Resolve-FmWatchSibling -BinDir $PSScriptRoot -Name 'fm-watch'
$FmArmWatchToken = (Get-FmWatchContext).WatchToken
$FmArmWatchLock = "$FmArmState/.watch.lock"
$FmArmBeat = "$FmArmState/.last-watcher-beat"

# "Fresh" reuses the guard's threshold so there is one definition of liveness.
$FmArmGrace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300'

# How long to wait for a freshly started watcher to acquire the lock and beat.
# The platform-conditional default is a real accommodation, not a rounding: this
# host pays a far higher process-start cost while the watcher completes its
# required pre-lock migration, so 10s times out on a cold start that is working
# perfectly well. The bash twin keys this on OSTYPE being msys/mingw/cygwin;
# a PowerShell process has no OSTYPE, and $IsWindows selects the same machines.
$FmArmConfirmDefault = if (Test-FmWindows) { '30' } else { '10' }
$FmArmConfirmTimeout = Get-FmEnv -Name 'FM_ARM_CONFIRM_TIMEOUT' -Default $FmArmConfirmDefault
$FmArmAttachPoll = Get-FmEnv -Name 'FM_ARM_ATTACH_POLL' -Default '0.5'

$FmArmCycleLog = "$FmArmState/.watch-cycle-exits.log"
$FmArmCycleLogLock = "$FmArmState/.watch-cycle-exits.lock"
$FmArmPid = [string]$PID

function Get-FmArmPositiveInt {
    # `case "$v" in ''|*[!0-9]*|0) v=<default> ;; esac` - a non-numeric or zero
    # knob falls back rather than aborting arithmetic mid-cycle.
    param([AllowEmptyString()][AllowNull()][string]$Value, [long]$Default)
    [long]$parsed = 0
    if ([string]::IsNullOrEmpty($Value)) { return $Default }
    if ($Value -notmatch '^[0-9]+$') { return $Default }
    if (-not [long]::TryParse($Value, [ref]$parsed) -or $parsed -eq 0) { return $Default }
    return $parsed
}

$FmArmCycleLogMaxBytes = Get-FmArmPositiveInt (Get-FmEnv -Name 'FM_WATCH_CYCLE_LOG_MAX_BYTES') 262144
$FmArmCycleLogKeepLines = Get-FmArmPositiveInt (Get-FmEnv -Name 'FM_WATCH_CYCLE_LOG_KEEP_LINES') 1000

function Get-FmArmInterval {
    param([AllowEmptyString()][AllowNull()][string]$Value, [double]$Default)
    [double]$parsed = 0
    $styles = [System.Globalization.NumberStyles]::Float
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ([double]::TryParse([string]$Value, $styles, $culture, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    return $Default
}

function Get-FmArmNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# --- interruption ------------------------------------------------------------
#
# The INT trap's twin (see header note 3). The handler cannot unwind the main
# thread, so it records the request and the wait loops - which all poll rather
# than block indefinitely - observe it and exit through the ordinary path, which
# is what keeps the ledger row and the child teardown intact.
$script:FmArmInterrupted = $false
try {
    [Console]::add_CancelKeyPress({
            param($fmSender, $fmEventArgs)
            $null = $fmSender
            $fmEventArgs.Cancel = $true
            $script:FmArmInterrupted = $true
        })
} catch {
    # A redirected or absent console refuses the handler; the arm still works,
    # it simply has no Ctrl-C twin in that configuration.
    $null = $_
}

# --- lifecycle ledger --------------------------------------------------------
#
# Diagnostic evidence, not a supervision dependency: every write is bounded and
# best-effort so an observability failure can never stall an otherwise healthy
# watcher cycle. state/.watch-triage.log stays exclusively the WATCHER's
# absorbed-wake debug log and is never written here.

function Format-FmArmField {
    # `tr '\t\r\n' '   ' | cut -c1-512`. Characters, not bytes: MSYS `cut -c`
    # counts characters in a UTF-8 locale too, and a record field here is only
    # ever a pid, an identity string, or a reason word.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text = [string]$Value -replace "[`t`r`n]", ' '
    if ($text.Length -gt 512) { $text = $text.Substring(0, 512) }
    return $text
}

function Get-FmArmLockSnapshot {
    $lockPid = Get-FmArmFileValue "$FmArmWatchLock/pid"
    $identity = Get-FmArmFileValue "$FmArmWatchLock/pid-identity"
    if ([string]::IsNullOrEmpty($lockPid)) { $lockPid = 'none' }
    if ([string]::IsNullOrEmpty($identity)) { $identity = 'none' }
    return ('pid:{0}|identity:{1}' -f (Format-FmArmField $lockPid), (Format-FmArmField $identity))
}

function Get-FmArmFileValue {
    # `cat "$f" 2>/dev/null || true` inside `$( )`: absent is empty, and the
    # command substitution strips trailing newlines.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $native = ConvertTo-FmNativePath $Path
        if (-not [System.IO.File]::Exists($native)) { return '' }
        return ([System.IO.File]::ReadAllText($native)).TrimEnd("`n")
    } catch {
        return ''
    }
}

$script:FmArmCycleActive = $false
$script:FmArmCycleWatcherPid = 'none'
$script:FmArmCycleOrigin = 'unknown'
$script:FmArmCycleStartedAt = 0
$script:FmArmCycleLockBefore = 'pid:none|identity:none'

function Start-FmArmCycle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens one in-process ledger cycle; it mutates only script-scope variables and never durable state, so a -WhatIf/-Confirm surface would be meaningless and would stall a non-interactive arm.')]
    param([AllowEmptyString()][string]$WatcherPid, [AllowEmptyString()][string]$Origin)
    $script:FmArmCycleWatcherPid = $WatcherPid
    $script:FmArmCycleOrigin = $Origin
    $script:FmArmCycleStartedAt = Get-FmArmNow
    $script:FmArmCycleLockBefore = Get-FmArmLockSnapshot
    $script:FmArmCycleActive = $true
}

function Update-FmArmCycleLockBefore {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Refreshes one in-process ledger field and never touches durable state; a confirmation surface would be meaningless and would stall a non-interactive arm.')]
    param()
    if (-not $script:FmArmCycleActive) { return }
    $script:FmArmCycleLockBefore = Get-FmArmLockSnapshot
}

function Get-FmArmSignalName {
    # `kill -l $((rc-128))`, with the bash twin's own numeric fallback. See
    # header note 3: a Windows process cannot exit via a POSIX signal, so the
    # fallback branch is the only reachable one here.
    param([AllowEmptyString()][AllowNull()][string]$Code)
    if ([string]::IsNullOrEmpty($Code) -or $Code -notmatch '^-?[0-9]+$') { return 'unknown' }
    [long]$rc = 0
    if (-not [long]::TryParse($Code, [ref]$rc)) { return 'unknown' }
    if ($rc -le 128) { return 'none' }
    return [string]($rc - 128)
}

function Add-FmArmCycleRecord {
    param(
        [AllowEmptyString()][string]$ExitCode,
        [AllowEmptyString()][string]$Signal,
        [AllowEmptyString()][string]$Reason,
        [AllowEmptyString()][string]$Successor
    )
    if (-not $script:FmArmCycleActive) { return }
    $endedAt = Get-FmArmNow
    $beaconAge = Get-FmPathAge -Path $FmArmBeat
    $lockAfter = Get-FmArmLockSnapshot

    $i = 0
    while (-not (Request-FmLock -LockPath $FmArmCycleLogLock)) {
        if ($i -ge 20) { return }
        Start-Sleep -Milliseconds 20
        $i++
    }
    try {
        # Joined explicitly on a TAB rather than embedded in a format string: a
        # backtick-t inside SINGLE quotes is two literal characters in
        # PowerShell, and this record is TAB-delimited by contract.
        $record = @(
            "arm_pid=$FmArmPid",
            ('watcher_pid=' + (Format-FmArmField $script:FmArmCycleWatcherPid)),
            ('origin=' + (Format-FmArmField $script:FmArmCycleOrigin)),
            "started_at=$($script:FmArmCycleStartedAt)",
            "ended_at=$endedAt",
            ('exit_code=' + (Format-FmArmField $ExitCode)),
            ('signal=' + (Format-FmArmField $Signal)),
            ('reason=' + (Format-FmArmField $Reason)),
            "beacon_age=$beaconAge",
            ('lock_before=' + (Format-FmArmField $script:FmArmCycleLockBefore)),
            ('lock_after=' + (Format-FmArmField $lockAfter)),
            ('successor=' + (Format-FmArmField $Successor))
        ) -join "`t"
        try { Add-FmFileLine -Path $FmArmCycleLog -Line $record } catch { $null = $_ }
        Limit-FmArmCycleLog
    } finally {
        Unlock-FmLock -LockPath $FmArmCycleLogLock
        $script:FmArmCycleActive = $false
    }
}

function Limit-FmArmCycleLog {
    # `tail -n KEEP | tail -c MAX`, then `awk 'NR > 1 || /^arm_pid=/'` to drop
    # the partial first line `tail -c` can leave mid-record. Done in-process,
    # so the temp file and its rename have no twin here - but the DROP rule
    # does, because a truncated first record would poison every later parse.
    $native = ConvertTo-FmNativePath $FmArmCycleLog
    try {
        if (-not [System.IO.File]::Exists($native)) { return }
        $size = (Get-Item -LiteralPath $native -Force).Length
        if ($size -lt $FmArmCycleLogMaxBytes) { return }
        $lines = (Get-FmFileLines $FmArmCycleLog)
        if ($lines.Count -gt $FmArmCycleLogKeepLines) {
            $lines = @($lines[($lines.Count - $FmArmCycleLogKeepLines)..($lines.Count - 1)])
        }
        # The byte cap, applied from the END exactly as `tail -c` does.
        $kept = [System.Collections.Generic.List[string]]::new()
        [long]$bytes = 0
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $bytes += [System.Text.Encoding]::UTF8.GetByteCount($lines[$i]) + 1
            if ($bytes -gt $FmArmCycleLogMaxBytes) { break }
            $kept.Insert(0, $lines[$i])
        }
        if ($kept.Count -gt 0 -and -not $kept[0].StartsWith('arm_pid=', [System.StringComparison]::Ordinal)) {
            $kept.RemoveAt(0)
        }
        $text = if ($kept.Count -eq 0) { '' } else { ($kept -join "`n") + "`n" }
        [void](Set-FmFileTextAtomic -Path $FmArmCycleLog -Text $text -NoNewline)
    } catch {
        # Trimming is best-effort; an oversized ledger is never a reason to fail
        # a healthy watcher cycle.
        $null = $_
    }
}

function Update-FmArmPredecessorSuccessor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A bounded, best-effort diagnostic ledger write whose bash twin rewrites unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive arm.')]
    # A persistent adapter passes the arm pid that just closed. Once this new arm
    # verifies its watcher, update that predecessor's final record in place, so
    # the one-record-per-cycle ledger captures the actual successor outcome
    # without an extra synthetic lifecycle row.
    param([AllowEmptyString()][string]$Successor)
    $predecessor = Get-FmEnv -Name 'FM_WATCH_PREDECESSOR_ARM_PID'
    if ([string]::IsNullOrEmpty($predecessor) -or $predecessor -notmatch '^[0-9]+$') { return }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $FmArmCycleLog))) { return }

    $i = 0
    while (-not (Request-FmLock -LockPath $FmArmCycleLogLock)) {
        if ($i -ge 20) { return }
        Start-Sleep -Milliseconds 20
        $i++
    }
    try {
        $target = "arm_pid=$predecessor"
        $replacement = "`tsuccessor=" + (Format-FmArmField $Successor)
        $lines = (Get-FmFileLines $FmArmCycleLog)
        $last = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            # Split on TAB with a field-count check, never a regex split: a
            # record's reason field can legitimately be empty and a collapsing
            # split would shift every later column.
            $fields = @($lines[$i].Split("`t"))
            if ($fields.Count -lt 1 -or $fields[0] -cne $target) { continue }
            if ($fields -contains 'successor=none') { $last = $i }
        }
        if ($last -lt 0) { return }
        if ($lines[$last].EndsWith("`tsuccessor=none", [System.StringComparison]::Ordinal)) {
            $lines[$last] = $lines[$last].Substring(0, $lines[$last].Length - "`tsuccessor=none".Length) + $replacement
        }
        $text = if ($lines.Count -eq 0) { '' } else { ($lines -join "`n") + "`n" }
        [void](Set-FmFileTextAtomic -Path $FmArmCycleLog -Text $text -NoNewline)
    } catch {
        $null = $_
    } finally {
        Unlock-FmLock -LockPath $FmArmCycleLogLock
    }
}

# --- the honesty gate --------------------------------------------------------

$script:FmArmHealthyPid = ''

function Test-FmArmHealthyWatcher {
    # A watcher is "healthy" iff the lock names a live process that is genuinely
    # THIS home's watcher (the identity match guards a recycled pid) AND the
    # beacon is fresh within GRACE. A dead pid, a reused pid, or a stale beacon
    # all fail it, which is what makes it impossible for this script to report a
    # watcher that is not really there.
    $script:FmArmHealthyPid = ''
    if (-not (Test-FmWatcherHealthy -State $FmArmState -WatchPath $FmArmWatchToken -Grace $FmArmGrace -FmHome $FmArmHome)) {
        return $false
    }
    $script:FmArmHealthyPid = Get-FmWatcherHealthyPid
    return $true
}

function Write-FmArmAttached {
    $age = Get-FmPathAge -Path $FmArmBeat
    Write-FmOut "watcher: attached pid=$($script:FmArmHealthyPid) (beacon ${age}s)"
}

function Wait-FmArmHealthySuccessor {
    # The same bounded confirmation window a fresh child gets. Adapter-owned
    # continuations normally win immediately, but the bound avoids a false
    # failure when process-close delivery and lock publication cross briefly.
    # The `+ 1` is the bash twin's rounding second: date(1) exposes whole
    # seconds, so a one-second budget could otherwise collapse to milliseconds
    # when the call lands just before a boundary.
    $deadline = (Get-FmArmNow) + (Get-FmArmPositiveInt $FmArmConfirmTimeout 30) + 1
    while ($true) {
        if (Test-FmArmHealthyWatcher) { return $true }
        if ($script:FmArmInterrupted) { return $false }
        if ((Get-FmArmNow) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 200
    }
}

function Write-FmArmUnexplainedCycle {
    Write-FmOut 'watcher: FAILED - cycle ended without an actionable reason'
}

function Invoke-FmArmAttachAndWait {
    # Stay alive across identity-matched healthy holders. If one cycle ends,
    # attach to a verified successor. With no successor, fail LOUDLY rather than
    # returning a clean empty completion an adapter could mistake for a no-op.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AttachedPid)
    $attached = $AttachedPid
    $poll = Get-FmArmInterval $FmArmAttachPoll 0.5
    while ($true) {
        if ($script:FmArmInterrupted) { return (Stop-FmArmInterrupted) }
        if (Test-FmArmHealthyWatcher) {
            if ($script:FmArmHealthyPid -cne $attached) {
                Add-FmArmCycleRecord 'unknown' 'unknown' 'lock-replaced' "attached:$($script:FmArmHealthyPid)"
                $attached = $script:FmArmHealthyPid
                Start-FmArmCycle $attached 'attached'
                Write-FmArmAttached
            }
            Start-Sleep -Seconds $poll
            continue
        }
        if (Wait-FmArmHealthySuccessor) {
            Add-FmArmCycleRecord 'unknown' 'unknown' 'attached-cycle-ended' "attached:$($script:FmArmHealthyPid)"
            $attached = $script:FmArmHealthyPid
            Start-FmArmCycle $attached 'attached'
            Write-FmArmAttached
            continue
        }
        if ($script:FmArmInterrupted) { return (Stop-FmArmInterrupted) }
        Add-FmArmCycleRecord 'unknown' 'unknown' 'attached-cycle-ended' 'none'
        Write-FmArmUnexplainedCycle
        return 1
    }
}

function Stop-FmArmInterrupted {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The INT-trap twin: it records one ledger row and returns the exit code. Its bash twin runs from a signal handler, where no confirmation is possible.')]
    param()
    # The INT-trap twin's tail: one arm-interrupted ledger row and exit 130.
    Add-FmArmCycleRecord '130' 'INT' 'arm-interrupted' 'none'
    return 130
}

# --- watcher output ----------------------------------------------------------

$script:FmArmReasonPattern = '^(signal:|stale:|check:|heartbeat($|:))'

function Test-FmArmOutputHasWake {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in (Get-FmFileLines $Path)) {
        if ($line -cmatch $script:FmArmReasonPattern) { return $true }
    }
    return $false
}

function Get-FmArmOutputReasonType {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in (Get-FmFileLines $Path)) {
        if ($line -cnotmatch $script:FmArmReasonPattern) { continue }
        if ($line.StartsWith('signal:', [System.StringComparison]::Ordinal)) { return 'actionable-signal' }
        if ($line.StartsWith('stale:', [System.StringComparison]::Ordinal)) { return 'actionable-stale' }
        if ($line.StartsWith('check:', [System.StringComparison]::Ordinal)) { return 'actionable-check' }
        if ($line.StartsWith('heartbeat', [System.StringComparison]::Ordinal)) { return 'actionable-heartbeat' }
        return 'none'
    }
    return 'none'
}

function Write-FmArmOutput {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-FmFileText $Path
    if ([string]::IsNullOrEmpty($text)) { return }
    Write-FmRaw $text
}

function Test-FmArmOutputHasFailure {
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in (Get-FmFileLines $Path)) {
        if ($line.StartsWith('watcher: FAILED', [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# --- the tracked child -------------------------------------------------------

function Start-FmArmWatcher {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts the tracked watcher child, which IS the job of this script; its bash twin launches unconditionally and a confirmation surface would leave supervision unarmed.')]
    # `"$WATCH" >"$child_out" &` with a handle we can wait on and terminate.
    #
    # Invoke-FmScript is the sanctioned way to RUN a sibling and is not usable
    # here for one reason: it is synchronous by construction and returns a
    # result, while this script's whole contract is to hold the child for its
    # lifetime. So the resolution rule (prefer the .ps1 twin, fall back to the
    # .sh under Git Bash) is applied through Resolve-FmWatchSibling - fm-watch's
    # own owner of it - rather than by hard-coding an extension (contract 7).
    param([Parameter(Mandatory)][string]$OutputPath)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($FmArmWatch.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        # The running pwsh, so the child inherits this exact version.
        $self = (Get-Process -Id $PID).Path
        if (-not $self) { $self = 'pwsh' }
        $psi.FileName = $self
        $psi.ArgumentList.Add('-NoProfile')
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add((ConvertTo-FmNativePath $FmArmWatch))
    } else {
        $bash = Get-FmBash
        if (-not $bash) { return $null }
        $psi.FileName = $bash
        # Bash receives a POSIX path: it cannot be relied on to accept a Windows
        # drive path as a script argument.
        $psi.ArgumentList.Add((ConvertTo-FmPosixPath $FmArmWatch))
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        $proc.Dispose()
        return $null
    }
    # Drained on a background task so the child can never block on a full pipe
    # while this arm is polling; the text lands in the same file the bash twin
    # redirects into, so every downstream reader is unchanged.
    $reader = $proc.StandardOutput.ReadToEndAsync()
    return @{ Process = $proc; Reader = $reader; OutputPath = $OutputPath }
}

function Complete-FmArmWatcherOutput {
    param([Parameter(Mandatory)][hashtable]$Child)
    try {
        $text = $Child.Reader.GetAwaiter().GetResult()
        Set-FmFileText -Path $Child.OutputPath -Text ($text -replace "`r", '') -NoNewline
    } catch {
        $null = $_
    }
}

function Test-FmArmChildAlive {
    param([Parameter(Mandatory)][hashtable]$Child)
    try { return -not $Child.Process.HasExited } catch { return $false }
}

function Stop-FmArmChild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Tears down the child this arm started, on the interruption and timeout paths; its bash twin kills unconditionally and a confirmation surface would orphan the watcher.')]
    param([AllowNull()][hashtable]$Child)
    if ($null -eq $Child) { return }
    try {
        if (-not $Child.Process.HasExited) { $Child.Process.Kill($true) }
    } catch {
        $null = $_
    }
}

# --- main --------------------------------------------------------------------

function Invoke-FmWatchArmMain {
    param([AllowEmptyCollection()][string[]]$Arguments = @())

    $mode = 'arm'
    $first = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
    switch -CaseSensitive ($first) {
        '' { $mode = 'arm' }
        'arm' { $mode = 'arm' }
        '--arm' { $mode = 'arm' }
        '--restart' { $mode = 'restart' }
        default {
            Write-FmErr "usage: fm-watch-arm.ps1 [--restart]"
            return 2
        }
    }

    if ($mode -ceq 'restart') {
        # Home-scoped stop: ONLY the watcher pid recorded in THIS home's lock,
        # and only once the identity check confirms it is really this home's
        # watcher. See header note 1 - there is no pattern matching here by
        # construction.
        $lockPid = Get-FmArmFileValue "$FmArmWatchLock/pid"
        if (Test-FmPidAlive -ProcessId $lockPid) {
            if (Test-FmWatcherLockMatchesPid -State $FmArmState -WatchPath $FmArmWatchToken -ProcessId $lockPid -FmHome $FmArmHome) {
                try {
                    # TerminateProcess is the only stop Windows offers; there is
                    # no SIGTERM to send (header note 3). It is aimed at exactly
                    # one integer, read out of this home's own lock.
                    Stop-Process -Id ([int]$lockPid) -Force -ErrorAction Stop
                } catch {
                    # A pid this process cannot address - most often an MSYS pid
                    # belonging to a bash-launched watcher, which lives in a
                    # different namespace - is left ALONE. The fresh watcher then
                    # meets a live holder and stands down through the singleton,
                    # and this arm reports a loud FAILED rather than running two.
                    $null = $_
                }
                # Wait for it to actually exit before relaunching, so the fresh
                # watcher either takes a released lock or reclaims a now-dead-pid
                # stale lock, instead of seeing the dying one as a live holder.
                $i = 0
                while ($i -lt 50 -and (Test-FmPidAlive -ProcessId $lockPid)) {
                    Start-Sleep -Milliseconds 100
                    $i++
                }
            } else {
                # A recorded lock for this home and this watcher path whose pid
                # is NOT identity-matched is stale; clear it rather than
                # signalling a pid that may now be someone else's process.
                $lockHome = Get-FmArmFileValue "$FmArmWatchLock/fm-home"
                $lockPath = Get-FmArmFileValue "$FmArmWatchLock/watcher-path"
                $lockIdentity = Get-FmArmFileValue "$FmArmWatchLock/pid-identity"
                if ($lockHome -ceq $FmArmHome -and $lockPath -ceq $FmArmWatchToken -and -not [string]::IsNullOrEmpty($lockIdentity)) {
                    [void](Remove-FmLockPath -LockPath $FmArmWatchLock)
                }
            }
        }
    }

    # If a genuinely live+fresh watcher already holds the lock, do NOT start a
    # second one - attach to that cycle and wait until it ends, so the harness
    # notify fires then rather than as an immediate empty wake. (--restart skips
    # this: it just stopped this home's watcher and wants a fresh one.)
    if ($mode -ceq 'arm' -and (Test-FmArmHealthyWatcher)) {
        Update-FmArmPredecessorSuccessor "attached:$($script:FmArmHealthyPid)"
        Start-FmArmCycle $script:FmArmHealthyPid 'attached'
        Write-FmArmAttached
        return (Invoke-FmArmAttachAndWait -AttachedPid $script:FmArmHealthyPid)
    }

    # Start a watcher as a tracked child and confirm it before settling in.
    $childOut = "$FmArmState/.watch-arm-output.$FmArmPid"
    $child = $null
    try {
        try {
            Set-FmFileText -Path $childOut -Text '' -NoNewline
        } catch {
            Write-FmOut 'watcher: FAILED - no live watcher with a fresh beacon'
            return 1
        }
        $child = Start-FmArmWatcher -OutputPath $childOut
        if ($null -eq $child) {
            Write-FmOut 'watcher: FAILED - no live watcher with a fresh beacon'
            return 1
        }
        $childPid = [string]$child.Process.Id
        Start-FmArmCycle $childPid 'started'

        # Verify the outcome: poll until this child is the confirmed healthy
        # watcher, until some other watcher legitimately holds the singleton (a
        # startup race), or until the child gives up. Only then print the honest
        # line. The `+ 1` is the same rounding second as above.
        $deadline = (Get-FmArmNow) + (Get-FmArmPositiveInt $FmArmConfirmTimeout 30) + 1
        while ($true) {
            if ($script:FmArmInterrupted) {
                Stop-FmArmChild $child
                Complete-FmArmWatcherOutput $child
                return (Stop-FmArmInterrupted)
            }
            if (Test-FmArmHealthyWatcher) {
                if ($script:FmArmHealthyPid -ceq $childPid) {
                    Update-FmArmCycleLockBefore
                    Update-FmArmPredecessorSuccessor "started:$childPid"
                    Write-FmOut "watcher: started pid=$childPid (beacon fresh)"
                }
                # Either this child is the confirmed singleton, or another
                # watcher won it and this child stood down. Both are settled by
                # waiting the child out.
                return (Complete-FmArmOwnedChild -Child $child -OutputPath $childOut)
            }
            if (-not (Test-FmArmChildAlive -Child $child)) {
                return (Complete-FmArmOwnedChild -Child $child -OutputPath $childOut)
            }
            if ((Get-FmArmNow) -ge $deadline) { break }
            Start-Sleep -Milliseconds 200
        }

        Complete-FmArmWatcherOutput $child
        Write-FmArmOutput $childOut
        Stop-FmArmChild $child
        $rc = 1
        try { $child.Process.WaitForExit(2000) | Out-Null; $rc = $child.Process.ExitCode } catch { $rc = 1 }
        Add-FmArmCycleRecord ([string]$rc) (Get-FmArmSignalName ([string]$rc)) 'confirmation-timeout' 'none'
        Write-FmOut 'watcher: FAILED - no live watcher with a fresh beacon'
        return 1
    } finally {
        if ($null -ne $child) {
            try { $child.Process.Dispose() } catch { $null = $_ }
        }
        try {
            $native = ConvertTo-FmNativePath $childOut
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $null = $_
        }
    }
}

function Complete-FmArmOwnedChild {
    # The owned_child_finished twin: classify how this cycle ended, record ONE
    # ledger row for it, and print the honest line.
    param(
        [Parameter(Mandatory)][hashtable]$Child,
        [Parameter(Mandatory)][string]$OutputPath
    )
    while (-not $Child.Process.WaitForExit(200)) {
        if (-not $script:FmArmInterrupted) { continue }
        Stop-FmArmChild $Child
        Complete-FmArmWatcherOutput $Child
        return (Stop-FmArmInterrupted)
    }
    Complete-FmArmWatcherOutput $Child
    $rc = $Child.Process.ExitCode
    $signal = Get-FmArmSignalName ([string]$rc)

    if ($rc -eq 0 -and (Test-FmArmOutputHasWake -Path $OutputPath)) {
        Add-FmArmCycleRecord ([string]$rc) $signal (Get-FmArmOutputReasonType -Path $OutputPath) 'none'
        Write-FmArmOutput $OutputPath
        return 0
    }

    if ($rc -eq 0) {
        if (Wait-FmArmHealthySuccessor) {
            Add-FmArmCycleRecord ([string]$rc) $signal 'unexpected-clean-exit' "attached:$($script:FmArmHealthyPid)"
            Write-FmArmOutput $OutputPath
            Update-FmArmPredecessorSuccessor "attached:$($script:FmArmHealthyPid)"
            Write-FmArmAttached
            Start-FmArmCycle $script:FmArmHealthyPid 'attached'
            return (Invoke-FmArmAttachAndWait -AttachedPid $script:FmArmHealthyPid)
        }
        Add-FmArmCycleRecord ([string]$rc) $signal 'unexpected-clean-exit' 'none'
        Write-FmArmOutput $OutputPath
        Write-FmArmUnexplainedCycle
        return 1
    }

    $reasonType = if ($signal -ceq 'none') { 'nonzero-exit' } else { 'signal-exit' }
    Add-FmArmCycleRecord ([string]$rc) $signal $reasonType 'none'
    Write-FmArmOutput $OutputPath
    if (-not (Test-FmArmOutputHasFailure -Path $OutputPath)) {
        Write-FmOut "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
    }
    if ($rc -gt 0) { return $rc }
    return 1
}

# UnexpectedCode 70 rather than 1 or 2: this CLI documents 0 (a propagated wake),
# 1 (every FAILED line), 2 (usage) and the child's own nonzero code. An escaped
# exception is a DEFECT, and giving it a code the bash twin can never produce
# means an adapter branching on 1 or 2 cannot silently absorb one.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmWatchArmMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
