# bin/fm-guard.ps1 - watcher liveness and worktree-tangle guard, called by
# supervision scripts, by fm-wake-drain after it empties queued wakes, and by
# fm-session-start in read-only advisory mode whenever session-lock ownership
# was not verified.
#
# Twin: bin/fm-guard.sh
#
# First, always warn if the firstmate primary checkout (FM_ROOT) is on a named
# non-default branch, because that means firstmate-on-itself work landed in the
# primary instead of an isolated worktree.
# Then, if any task is in flight (a state/<id>.meta exists) and the watcher's
# liveness beacon (state/.last-watcher-beat, touched every poll cycle) is
# missing or older than FM_GUARD_GRACE seconds, prints a loud, clearly delimited
# banner so the agent cannot skim past it in the tool output of whatever it was
# doing - the one channel every harness has. The full banner is emitted once per
# distinct staleness episode in this FM_HOME (keyed to beacon mtime or absence);
# later guarded commands in the same episode print a one-line reminder instead.
# Episode state lives only under state/.guard-watcher-stale-banner (volatile,
# bounded). Independent alarms (queued wakes, worktree tangle) are never
# suppressed by that dedup. Normal wake handling (watcher briefly down between a
# wake and the next supervision resume) stays inside the grace window and stays
# silent. Always exits 0: the guard warns, it never blocks.
#
# ---------------------------------------------------------------------------
# WHAT IS DIFFERENT HERE, AND WHY EACH DIFFERENCE IS SAFE
#
#   1. NO SIGNAL HANDLING TO REPRODUCE. The bash twin installs no traps, so
#      there is nothing to diverge on; the note exists only because every other
#      file in this package carries one and its absence would read as an
#      omission.
#
#   2. THE BANNER IS BYTE-IDENTICAL, INCLUDING THE GLYPHS. '●' and the heavy
#      rule '━' are non-ASCII, and an unconfigured PowerShell console emits '?'
#      for them (verified during the fm-common work). fm-common pins UTF-8
#      without a BOM at import, and every line here goes through Write-FmErr, so
#      the banner a harness sees is the same banner the bash twin prints.
#
#   3. `printf '●  %s\n' "$fix"` PREFIXES ONLY THE FIRST LINE. When the
#      supervision-instructions repair line is multi-line, bash prefixes the
#      first line and prints the rest bare. That is reproduced literally rather
#      than "fixed", because the emitted text is what an agent reads and a
#      per-line prefix would change it.
#
#   4. THE SPIN YIELD. `sleep 0.02 2>/dev/null || sleep 1` exists because some
#      shells' sleep rejects a fractional argument. Start-Sleep has no such
#      limitation, so the fallback leg is unreachable here and is not written.
#      The spin BUDGET (50 iterations) and the contended fall-through - stay
#      loud rather than dropping the alarm - are unchanged.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOT -Force: see the note in bin/fm-wake-drain.ps1. A -Force import here would
# also re-resolve fm-wake-lib's import-time context, which is exactly the
# source-time snapshot both worlds are supposed to share.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tangle-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervision-lib.psm1')

$FmGuardRule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# Deterministic episode key from beacon state: same continuous stale beacon
# (or continuous absence) shares a key; a recovered-then-restale beacon gets a
# new mtime and therefore a new episode.
function Get-FmGuardStaleEpisodeKey {
    param([Parameter(Mandatory)][string]$State)

    $beat = "$State/.last-watcher-beat"
    $native = ConvertTo-FmNativePath $beat
    # `[ -e ]`: a directory at that path counts as present, exactly as it does
    # in bash, and then reports an mtime like any other entry.
    if ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native)) {
        $m = Get-FmSupervisionMtime -Path $beat
        if ($null -eq $m) { return 'beat:unknown' }
        return "beat:$m"
    }
    return 'beat:absent'
}

# The marker holds one line: the current stale-episode key. Read with a single
# trailing newline stripped so the comparison is line-content based, matching
# `seen=${seen%$'\n'}` on a `$(cat ...)` capture.
function Get-FmGuardStaleBannerSeenKey {
    param([Parameter(Mandatory)][string]$State)

    # `seen=$(cat ...)` strips EVERY trailing newline, and the following
    # `${seen%$'\n'}` is then a no-op on a well-formed marker; TrimEnd
    # reproduces the pair's combined effect rather than only the second half.
    return (Get-FmFileText -Path "$State/.guard-watcher-stale-banner").TrimEnd("`n")
}

function Test-FmGuardStaleBannerSeen {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key
    )
    return ((Get-FmGuardStaleBannerSeenKey -State $State) -eq $Key)
}

# Claim the full banner for this episode. $true = print the full banner (this
# call owns the first announcement). $false = the same episode was already
# announced (print the reminder). The shared wake lock helper owns the
# race-safety mechanics; the re-check under the lock makes concurrent claims
# idempotent.
function Request-FmGuardStaleBanner {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A best-effort episode marker on a warn-only path whose bash twin writes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive supervision command.')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key
    )

    $marker = "$State/.guard-watcher-stale-banner"
    $lock = "$State/.guard-watcher-stale-banner.lock"

    if ((Get-FmGuardStaleBannerSeenKey -State $State) -eq $Key) { return $false }

    for ($i = 0; $i -lt 50; $i++) {
        if (Request-FmLock -LockPath $lock) {
            $claimed = $true
            if ((Get-FmGuardStaleBannerSeenKey -State $State) -eq $Key) {
                $claimed = $false
            } else {
                # Bounded write: one line, no growth across episodes (overwrite).
                try { Set-FmFileText -Path $marker -Text $Key } catch { $null = $_ }
            }
            try { Unlock-FmLock -LockPath $lock } catch { $null = $_ }
            return $claimed
        }
        if ((Get-FmGuardStaleBannerSeenKey -State $State) -eq $Key) { return $false }
        Start-Sleep -Milliseconds 20
    }
    # Contended past the spin budget: stay loud rather than dropping the alarm.
    return $true
}

function Clear-FmGuardStaleBanner {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The `rm -f` twin on a warn-only path whose bash twin removes unconditionally; a confirmation surface would diverge from the twin and could stall a non-interactive supervision command.')]
    param([Parameter(Mandatory)][string]$State)

    $native = ConvertTo-FmNativePath "$State/.guard-watcher-stale-banner"
    try {
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch {
        $null = $_
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext -ScriptRoot $PSScriptRoot
    $fmRoot = $context.Root
    # The banner prints the root the way the BASH prints $FM_ROOT, which is the
    # override verbatim when one is set and otherwise `pwd` - MSYS form. The
    # context's Root is deliberately NATIVE (the .NET file APIs need it), so a
    # separate display spelling is kept for anything a human reads or copies:
    # the remediation line below is meant to be pasted, and docs contract 3
    # keeps path text in POSIX form through the transition.
    $rootOverrideRaw = Get-FmEnv -Name 'FM_ROOT_OVERRIDE'
    $fmRootDisplay = if ([string]::IsNullOrEmpty($rootOverrideRaw)) {
        ConvertTo-FmPosixPath $fmRoot
    } else {
        $rootOverrideRaw
    }
    $state = $context.State
    $config = $context.Config
    $grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300'

    # `case "$READ_ONLY" in 1|true|TRUE|yes|YES) 1 ;; *) 0 ;; esac` - an exact
    # token list, not a truthiness test: "Yes" and "on" are FALSE in the twin.
    $readOnlyRaw = Get-FmEnv -Name 'FM_GUARD_READ_ONLY' -Default '0'
    $readOnly = ($readOnlyRaw -cin @('1', 'true', 'TRUE', 'yes', 'YES'))

    $continueLine = Get-FmEnv -Name 'FM_GUARD_CONTINUE_LINE' `
        -Default 'This is a supervision warning only; the guarded operation WILL still run.'

    # Worktree-tangle alarm, checked FIRST and independent of in-flight tasks:
    # the firstmate PRIMARY checkout (FM_ROOT) must stay on its default branch.
    # If a crewmate's branch/commits landed here instead of in its own isolated
    # worktree, the primary is stranded on a feature branch - surface it loudly
    # on the very next fleet action, the same way the watcher-down banner does.
    # Scoped to the primary only: detached HEAD (linked worktrees, secondmate
    # homes) never trips this.
    $tangleBranch = ''
    try {
        $probe = Get-FmPrimaryTangleBranch -Root $fmRoot
        if ($null -ne $probe) { $tangleBranch = [string]$probe }
    } catch {
        # `|| true`: a git that cannot answer is not a tangle.
        $tangleBranch = ''
    }
    if (-not [string]::IsNullOrEmpty($tangleBranch)) {
        $tangleDefault = 'main'
        try {
            $resolved = Get-FmDefaultBranch -Directory $fmRoot
            if (-not [string]::IsNullOrEmpty($resolved)) { $tangleDefault = [string]$resolved }
        } catch {
            $tangleDefault = 'main'
        }
        Write-FmErr "●$FmGuardRule"
        Write-FmErr '●  WORKTREE TANGLE - PRIMARY CHECKOUT IS ON A FEATURE BRANCH'
        Write-FmErr "●  $fmRootDisplay is on '$tangleBranch', not its default branch '$tangleDefault'."
        Write-FmErr '●  A crewmate likely branched/committed in the primary instead of its own worktree.'
        Write-FmErr "●  The work is SAFE on the '$tangleBranch' ref."
        if ($readOnly) {
            Write-FmErr '●  This read-only session must leave restore work to a session with verified fleet-lock ownership.'
        } else {
            Write-FmErr "●  Restore the primary to '$tangleDefault':"
            Write-FmErr "●      git -C $fmRootDisplay checkout $tangleDefault"
            Write-FmErr "●  then re-validate '$tangleBranch' in a proper isolated worktree."
        }
        Write-FmErr "●$FmGuardRule"
    }

    # Compute in-flight count and watcher-beacon freshness via the shared
    # grace-based predicate (bin/fm-supervision-lib.psm1). Only act with tasks in
    # flight; count them so the banner can say how much is riding on an absent
    # watcher.
    $status = Get-FmSupervisionStatus -State $state -Grace $grace
    $inFlight = [int]$status.InFlight
    $beaconDesc = [string]$status.BeaconDescription

    if ($inFlight -eq 0) {
        # Leave the unhealthy state (no work riding on the watcher): clear so a
        # later in-flight + stale combination is a fresh episode even if the
        # beacon is still absent with the same key string.
        if (-not $readOnly) { Clear-FmGuardStaleBanner -State $state }
        Exit-FmScript 0
    }

    # `[ -s "$FM_WAKE_QUEUE" ]` against the SAME path the wake library resolved
    # at import, which is what the bash twin's sourced $FM_WAKE_QUEUE is.
    $queuePending = $false
    $nativeQueue = ConvertTo-FmNativePath (Get-FmWakeContext).Queue
    if ([System.IO.File]::Exists($nativeQueue)) {
        try { $queuePending = ((Get-Item -LiteralPath $nativeQueue -Force).Length -gt 0) } catch { $queuePending = $false }
    }

    # No fresh watcher with tasks in flight is the dangerous state: emit a
    # prominent, bordered banner FIRST so it reads as an alarm, not a buried
    # stderr line. Later calls in the same episode get a one-line reminder only.
    # The verdict is MODEL-AWARE, and both halves of it matter here. Beacon
    # freshness alone is the autoarm rule; under the persistent model a fresh
    # leftover beacon with NO live watcher is still down, and treating it as
    # healthy is a false all-clear on every harness except claude.
    $watchPath = Join-Path $PSScriptRoot 'fm-watch.sh'
    $verdict = Get-FmWatcherSupervisionVerdict -State $state -WatchPath $watchPath `
        -Grace $grace -FmHome $($context.Home)
    if (-not $verdict.Ok) {
        # Keyed on the qualitative failing CONDITION, never on the beacon
        # mtime: under autoarm a healthy between-turns watcher advances that
        # mtime every poll, so a mtime-derived key changes every turn and
        # re-prints the whole banner forever instead of once per episode.
        $episodeKey = $verdict.Reason
        $printFullBanner = $false
        if ($readOnly) {
            $printFullBanner = -not (Test-FmGuardStaleBannerSeen -State $state -Key $episodeKey)
        } else {
            $printFullBanner = Request-FmGuardStaleBanner -State $state -Key $episodeKey
        }

        if ($printFullBanner) {
            $afkNative = ConvertTo-FmNativePath "$state/.afk"
            $afk = if ([System.IO.File]::Exists($afkNative) -or [System.IO.Directory]::Exists($afkNative)) { '1' } else { '0' }
            $queueArg = if ($queuePending) { '1' } else { '0' }
            $xModeNative = ConvertTo-FmNativePath "$config/x-mode.env"
            $xMode = if ([System.IO.File]::Exists($xModeNative)) { '1' } else { '0' }

            $fix = 'Repair missing watcher supervision according to the session-start operating block.'
            try {
                $instructions = Invoke-FmScript -Name 'fm-supervision-instructions' -Arguments @(
                    '--read-only', $(if ($readOnly) { '1' } else { '0' }),
                    '--afk', $afk,
                    '--x-mode', $xMode,
                    '--queue-pending', $queueArg,
                    '--repair-line')
                # `$( ... || printf ... )` strips trailing newlines from the
                # capture and falls back only when the command FAILED; a
                # successful run that printed nothing yields an empty fix line
                # in both worlds.
                if ($null -ne $instructions -and $instructions.Ok) {
                    $fix = ([string]$instructions.StdOut).TrimEnd("`n")
                }
            } catch {
                $null = $_
            }

            Write-FmErr "●$FmGuardRule"
            Write-FmErr '●  WATCHER DOWN - SUPERVISION IS OFF'
            Write-FmErr "●  $inFlight task(s) in flight, but no watcher has a fresh beacon (last beat: $beaconDesc, grace ${grace}s)."
            if ($readOnly) {
                Write-FmErr '●  This read-only session should report the lapse, not repair it.'
            } else {
                Write-FmErr '●  Trust the emitted supervision protocol for this harness; do not use shell & for watcher repair.'
            }
            Write-FmErr "●  $continueLine"
            # One prefix for the whole (possibly multi-line) repair line - see
            # divergence note 3 in the header.
            Write-FmErr "●  $fix"
            Write-FmErr "●$FmGuardRule"
        } else {
            Write-FmErr "WARNING: watcher still down (same stale episode; last beat: $beaconDesc, grace ${grace}s) - full banner already printed this episode."
        }
    } else {
        # Healthy again while work is still in flight: end the episode so a later
        # restale re-prints the full banner.
        if (-not $readOnly) { Clear-FmGuardStaleBanner -State $state }
    }

    # Queued wakes are an independent hazard; warn whenever they are pending,
    # even if a watcher is alive. Kept after the banner so the no-watcher alarm
    # reads first. Dedup of the watcher-down banner never suppresses this.
    if ($queuePending) {
        if ($readOnly) {
            Write-FmErr 'WARNING: queued wakes pending - left untouched because this session lacks verified fleet-lock ownership.'
        } else {
            Write-FmErr 'WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.'
        }
    }
    Exit-FmScript 0
}
