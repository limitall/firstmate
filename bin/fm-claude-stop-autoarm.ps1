# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Twin: bin/fm-claude-stop-autoarm.sh
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session's harness ancestor holds state/.lock.
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while work is in flight (state/*.meta) or X mode has a
#     relay poll to run (state/x-watch.check.sh); an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so a home-scoped owner
#     lock (state/.claude-autoarm.lock) admits exactly one owner; every other
#     concurrent firing exits 0 without translating, which keeps one event
#     epoch on exactly one recovery turn.
#   - Foreground arm: the owner runs bin/fm-watch-arm in the FOREGROUND of this
#     hook-owned process tree (never a detached child); Claude owns the process
#     group, so its timeout/session teardown kills arm and watcher together.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). A close that reports no actionable reason is
#     benign when a live identity-matched watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim and
# outcome so the synchronous Stop guard (bin/fm-turnend-guard --claude) can
# allow a stop whose recovery this hook already owns, instead of forcing a
# duplicate continuation for the same event epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# This hook never blocks the Stop decision itself and never prints to stdout:
# exit 0 is always silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES
#
# THE INERTNESS GATES ARE THE SAFETY, AND THEY RUN IN THE BASH TWIN'S ORDER.
# Scope, then identity, then AFK, then need, and only THEN the mutating
# session-lock recovery and the owner claim. An idle or away home must stay
# byte-for-byte inert - it writes nothing, not even an epoch record - and
# reordering a single gate would break that.
#
# PROVING THIS IS THE LOCK-OWNING PRIMARY SESSION IS NOT REINVENTED HERE.
# bin/fm-session-lock-lib.psm1 owns the whole question, and on Windows its
# answer comes from CLAUDE_PID: the Win32 parent chain TERMINATES before
# reaching the harness (measured, and recorded in that module's header), so a
# twin that walked native parents would resolve nothing and this hook would
# never arm. Test-FmSessionLockOwnedBySelf and Test-FmHarnessPidAlive are used
# exactly as the bash twin uses their originals.
#
# IMPORTS CARRY NO -Force, for the reason bin/fm-turnend-guard.ps1's header
# records (a re-run fm-common body resets [Console]::In/Out under a batched
# differential driver) and because it is the nested-import rule in
# docs/powershell-port.md.
#
# THE LOCK-ROLE AND FAILURE-EPISODE HELPERS ARE LOCAL ON PURPOSE, FOR NOW.
# fm_lock_set_role, fm_lock_role and fm_failure_episode_reset live in
# bin/fm-wake-lib.sh, and bin/fm-wake-lib.psm1 has not yet gained their twins.
# Set-FmHookLockRole / Get-FmHookLockRole / Reset-FmHookFailureEpisode below are
# byte-faithful ports of those three and are character-identical to the copies
# in bin/fm-turnend-guard.ps1, the only other caller; they MOVE into
# fm-wake-lib.psm1 as Set-FmLockRole / Get-FmLockRole / Reset-FmFailureEpisode
# as soon as that module's owner lands them. Unlock-FmHookLock is the third
# piece of the same debt and carries its own note.
#
# DECLARED DIVERGENCE - THE ARM'S OUTPUT FILE IS CONCATENATED, NOT INTERLEAVED.
# The bash twin runs `fm-watch-arm >"$OUT" 2>&1`, so both streams land in one
# file in real time order. Invoke-FmScript captures the two streams separately
# (PowerShell's own redirection merges native stderr into the output stream,
# which would corrupt any parsed field), so this twin writes stdout followed by
# stderr. Nothing downstream depends on the interleaving: classification is a
# per-line prefix match, and the banner excerpt is the first eight matching
# lines, which the arm emits on one stream. There is likewise no temp file per
# attempt - the buffer is in memory - and it is cleared between attempts for the
# same reason bash removes and re-creates OUT: only the LAST attempt's output
# may reach a banner.
#
# SIGNALS. `trap ... EXIT` becomes try/finally, which covers a normal return
# and a thrown exception but NOT a hard kill - Windows has no signal to catch
# (docs/powershell-port.md). A killed hook therefore leaves the owner lock for
# the lock protocol's own stale-owner recovery to reclaim, which is the same
# outcome bash has for SIGKILL.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on any of these: see the conversion notes above.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-primary-scope-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervision-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-session-lock-lib.psm1')

<#
.SYNOPSIS
The `[ -e <path> ]` twin: present as a file OR as a directory.
#>
function Test-FmHookPathPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    return ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native))
}

<#
.SYNOPSIS
The watcher script this home's lock would name (the bash twin's WATCH argument).
.DESCRIPTION
Same rule bin/fm-turnend-guard.ps1 and bin/fm-watch.psm1 apply: the lock's
watcher-path field is compared as a RAW STRING, so a hook that spelled it
differently would never recognize its own watcher.
#>
function Get-FmHookWatchPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$BinDir)

    $ps1 = Join-Path $BinDir 'fm-watch.ps1'
    if ((Test-Path -LiteralPath $ps1) -and ((Get-Item -LiteralPath $ps1).Length -gt 0)) { return $ps1 }
    $sh = Join-Path $BinDir 'fm-watch.sh'
    if (Test-Path -LiteralPath $sh) { return $sh }
    return $ps1
}

<#
.SYNOPSIS
The role token published beside a lock's pid (fm_lock_role).
#>
function Get-FmHookLockRole {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    return (Get-FmFileText "$LockPath/role").TrimEnd("`r", "`n")
}

<#
.SYNOPSIS
Publish this process's role into a lock it already holds (fm_lock_set_role).
.DESCRIPTION
Twin of fm_lock_set_role, including all three of its refusals: an unknown role
word, a lock whose published pid is not ours, and a write that does not read
back. The read-back is the point - the lock's owner directory may be published
as a symlink or as a plain file holding the owner path (docs/powershell-port.md,
"Locks"), and a write that landed somewhere else must not be reported as a role
this process holds.

Failing it is why this hook releases the owner lock and exits 0 rather than
arming: the synchronous guard reads that role to tell an auto-arm holding the
lock from its own terminal check, so an unlabelled claim would let the guard
credit recovery to a holder that is not doing any.
#>
function Set-FmHookLockRole {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal lock-protocol primitive whose bash twin writes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive background hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$Role
    )

    if ($Role -cne 'autoarm' -and $Role -cne 'terminal-check') { return $false }
    $current = [string]$PID
    $holder = (Get-FmFileText "$LockPath/pid").TrimEnd("`r", "`n")
    if ($holder -cne $current) { return $false }
    try {
        Set-FmFileText -Path "$LockPath/role" -Text $Role
    } catch {
        $null = $_
        return $false
    }
    return ((Get-FmHookLockRole -LockPath $LockPath) -ceq $Role)
}

<#
.SYNOPSIS
Release a lock this hook labelled with a role, clearing the label first.
.DESCRIPTION
COMPENSATES FOR A GAP IN fm-wake-lib.psm1, and is not an embellishment. Bash's
fm_lock_clean_known_files lists `role` among the filenames a lock directory may
contain, so fm_lock_release removes it and the directory then rmdir's. The
PowerShell Clear-FmLockKnownFile does NOT list `role` yet, so a lock this hook
labelled cannot be emptied: measured on this host, releasing such a lock leaves
its whole owner directory behind on every single firing, where the bash twin
leaves nothing. Clearing the label here - and only the label this hook itself
wrote - restores the twin's observable filesystem result.

Remove the compensation when fm-wake-lib.psm1's Clear-FmLockKnownFile gains
'role' (see the LOCK-ROLE note in the conversion header); until then every
release of a labelled lock must go through this, never Unlock-FmLock directly.
#>
function Unlock-FmHookLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal lock-protocol primitive whose bash twin releases unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive background hook.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    try {
        $native = ConvertTo-FmNativePath "$LockPath/role"
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch {
        # `rm -f` semantics: a label that will not go must not stop the release.
        $null = $_
    }
    Unlock-FmLock -LockPath $LockPath
}

<#
.SYNOPSIS
Clear a whole failure episode's durable markers (fm_failure_episode_reset).
.DESCRIPTION
Twin of fm_failure_episode_reset, both modes. `acquire` takes the budget lock
itself and releases it; `held` asserts that THIS process already holds it and
leaves it held.

A marker that is a real DIRECTORY refuses the whole reset rather than being
removed: `rm -f` cannot remove one either, and silently succeeding would report
an episode as cleared while its markers still gate every later decision.
#>
function Reset-FmHookFailureEpisode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal `rm -f` twin whose bash original deletes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive background hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][string]$Mode = 'acquire'
    )

    $lock = "$State/.turnend-claude-blocks.lock"
    $acquired = $false
    if ($Mode -ceq 'acquire') {
        if (-not (Request-FmLock -LockPath $lock)) { return $false }
        $acquired = $true
    } elseif ($Mode -ceq 'held') {
        $holder = (Get-FmFileText "$lock/pid").TrimEnd("`r", "`n")
        if ($holder -cne [string]$PID) { return $false }
    } else {
        return $false
    }

    $paths = @(
        "$State/.turnend-claude-blocks"
        "$State/.claude-autoarm-failure-notified"
        "$State/.claude-autoarm-failure-alarmed"
    )
    foreach ($path in $paths) {
        $native = ConvertTo-FmNativePath $path
        if ([System.IO.Directory]::Exists($native) -and -not (Test-FmSymlink -Path $path)) {
            if ($acquired) { Unlock-FmLock -LockPath $lock }
            return $false
        }
    }
    foreach ($path in $paths) {
        $native = ConvertTo-FmNativePath $path
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $null = $_
            if ($acquired) { Unlock-FmLock -LockPath $lock }
            return $false
        }
    }
    if ($acquired) { Unlock-FmLock -LockPath $lock }
    return $true
}

<#
.SYNOPSIS
The bounded number of arm attempts this firing may make.
.DESCRIPTION
The `case "$AUTOARM_ATTEMPTS" in 1|2|3) : ;; *) AUTOARM_ATTEMPTS=2 ;; esac` twin:
an ALLOW-LIST, not a range check, so anything else - including 0, a huge number,
or a non-numeric word - falls back to 2 rather than turning one Stop into an
unbounded arm loop.
#>
function Get-FmAutoarmAttemptBound {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $raw = Get-FmEnv -Name 'FM_CLAUDE_AUTOARM_ATTEMPTS' -Default '2'
    if ($raw -ceq '1') { return 1 }
    if ($raw -ceq '3') { return 3 }
    return 2
}

<#
.SYNOPSIS
Append one epoch record to the ledger the synchronous Stop guard reads.
.DESCRIPTION
Twin of write_epoch. The sequence number is read back from the existing record
and incremented, so a reader can tell a new claim from a repeat, and the publish
is atomic (write a sibling temp, rename over) exactly as the bash twin's
`printf > tmp && mv -f` is - a half-written ledger line would be read by the
guard as a missing outcome and cost a duplicate continuation.

Every failure is swallowed, as in the bash twin: the ledger is an optimization
for the guard, never a precondition for arming.
#>
function Write-FmAutoarmEpoch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A hook-internal ledger write whose bash twin writes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive background hook.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$EpochPath,
        [Parameter(Mandatory, Position = 1)][string]$Outcome
    )

    # `sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p'` - a leading epoch= field
    # followed by a space; anything else contributes nothing and leaves seq 0.
    [long]$seq = 0
    foreach ($line in (Get-FmFileLines $EpochPath)) {
        $m = [regex]::Match($line, '^epoch=([0-9][0-9]*) .*')
        if ($m.Success) {
            [long]$parsed = 0
            if ([long]::TryParse($m.Groups[1].Value, [ref]$parsed)) { $seq = $parsed }
        }
    }
    $seq = $seq + 1
    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        [void](Set-FmFileTextAtomic -Path $EpochPath -Text "epoch=$seq owner_pid=$PID outcome=$Outcome updated_at=$now`n" -NoNewline)
    } catch {
        $null = $_
    }
}

<#
.SYNOPSIS
Apply the generated X-mode cadence file to this process's environment.
.DESCRIPTION
The `. "$CONFIG/x-mode.env"` twin, restricted on purpose. That file has exactly
one writer - bin/fm-bootstrap's x_mode_setup - and one shape: comment lines and
`export NAME=value`. Sourcing it in bash means executing it; there is no
executing it here, and inventing a general shell evaluator to read a
five-line generated file would add an attack surface the bash twin only has
because `.` is the only tool it had. So this reads assignments and ignores
everything else, which is byte-equivalent for every file bootstrap can write.
#>
function Import-FmAutoarmXModeEnv {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Applies a generated cadence file to this process environment, exactly as the bash twin sources it; a confirmation surface would stall a non-interactive background hook.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    foreach ($line in (Get-FmFileLines $Path)) {
        $m = [regex]::Match($line, '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
        if (-not $m.Success) { continue }
        $value = $m.Groups[2].Value
        if ($value.Length -ge 2 -and
            (($value.StartsWith("'") -and $value.EndsWith("'")) -or
             ($value.StartsWith('"') -and $value.EndsWith('"')))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        [Environment]::SetEnvironmentVariable($m.Groups[1].Value, $value)
    }
}

<#
.SYNOPSIS
The first <Limit> lines of <Text> matching <Pattern> (the `grep | head` twin).
#>
function Select-FmAutoarmLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, Position = 1)][string]$Pattern,
        [Parameter(Position = 2)][int]$Limit = 8
    )
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`n")) {
        $clean = $line.TrimEnd("`r")
        if ($clean -cmatch $Pattern) {
            $hits.Add($clean)
            if ($hits.Count -ge $Limit) { break }
        }
    }
    return @($hits)
}

<#
.SYNOPSIS
The whole hook, returning the process exit code instead of taking it.
#>
function Invoke-FmClaudeStopAutoarm {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $context = Get-FmContext -ScriptRoot $PSScriptRoot
    $state = $context.State
    $configDir = $context.Config
    $grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300'
    $ownerLock = "$state/.claude-autoarm.lock"
    $epoch = "$state/.claude-autoarm-epoch"
    $failureNotice = "$state/.claude-autoarm-failure-notified"
    $failureAlarm = "$state/.claude-autoarm-failure-alarmed"
    $watch = Get-FmHookWatchPath -BinDir $PSScriptRoot
    $armAttempts = Get-FmAutoarmAttemptBound

    # Consume the Stop payload once. The decisions below are state-based; the
    # payload is read so a slow writer can never wedge on a full pipe.
    try { $null = [Console]::In.ReadToEnd() } catch { $null = $_ }

    # --- scope: genuine primary checkout only --------------------------------
    if (-not (Test-FmPrimaryScopeMatch -Root $context.Root -State $state)) { return 0 }

    # --- identity: only the lock-owning session's hooks may arm --------------
    # A prior session may have died after leaving its numeric harness pid in
    # .lock. Use the shared liveness predicate to recognize only that
    # stale-owner case. Defer the mutating claim until after the unchanged AFK
    # and need gates, so an idle or away home remains byte-for-byte inert.
    # Missing or malformed locks are uncertainty rather than stale-owner
    # evidence and remain inert.
    $recoverSessionLock = $false
    if (-not (Test-FmSessionLockOwnedBySelf -State $state)) {
        $lockPid = (Get-FmFileText "$state/.lock").TrimEnd("`r", "`n")
        if ($lockPid -notmatch '^[0-9]+$') { return 0 }
        if (Test-FmHarnessPidAlive -ProcessId $lockPid) { return 0 }
        $recoverSessionLock = $true
    }

    # --- AFK: the away daemon owns the watcher and triage; never rewake ------
    if (Test-FmHookPathPresent "$state/.afk") { return 0 }

    # --- need: in-flight work or an X-mode relay poll ------------------------
    if (-not (Test-FmSupervisionNeeded -State $state -Grace $grace)) { return 0 }

    # --- stale session-lock recovery -----------------------------------------
    # Delegate the claim to fm-lock so its live-owner refusal and write
    # semantics remain the single acquisition owner, then re-verify
    # current-session identity before touching any auto-arm state.
    if ($recoverSessionLock) {
        $lockRun = Invoke-FmScript -Name 'fm-lock' -BinDir $PSScriptRoot
        if (-not $lockRun.Ok) { return 0 }
        if (-not (Test-FmSessionLockOwnedBySelf -State $state)) { return 0 }
    }

    # --- single-flight owner claim -------------------------------------------
    # Claude runs one background process per firing with no dedupe. Exactly one
    # owner foregrounds the arm and translates its close; every other firing
    # exits 0 so one watcher cycle maps to at most one exit-2 rewake.
    if (-not (Request-FmLock -LockPath $ownerLock)) { return 0 }
    # The role is published INSIDE the claim, before the try/finally, exactly
    # where the bash twin sets it and before its EXIT trap is armed: a claim this
    # hook cannot label is released immediately and this firing stays inert.
    if (-not (Set-FmHookLockRole -LockPath $ownerLock -Role 'autoarm')) {
        Unlock-FmHookLock -LockPath $ownerLock
        return 0
    }

    try {
        Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'arming'

        # X mode cadence: apply the generated config so an X instance polls at
        # its 30s cadence (fm-bootstrap x_mode_setup contract).
        $cadence = "$configDir/x-mode.env"
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $cadence))) {
            Import-FmAutoarmXModeEnv -Path $cadence
        }

        # --- foreground the real arm wrapper ---------------------------------
        # NO detached child: this hook process tree is the harness-owned
        # lifecycle. The arm forks the watcher as its own tracked child exactly
        # as it does for the model-driven background-task path, and propagates
        # the wake reason on close.
        # Every non-actionable close is checked against the same
        # identity-matched live watcher and fresh-beacon predicate used by the
        # turn-end guard before it is retried or translated into an
        # operator-visible failure.
        $armOutput = ''
        $actionable = $false
        $healthy = $false
        $attempt = 0
        while ($attempt -lt $armAttempts) {
            $attempt = $attempt + 1
            $armRun = Invoke-FmScript -Name 'fm-watch-arm' -BinDir $PSScriptRoot
            $armOutput = $armRun.StdOut + $armRun.StdErr

            # AFK may have appeared mid-cycle: the daemon owns triage now, so
            # suppress every subsequent classification and handoff.
            if (Test-FmHookPathPresent "$state/.afk") {
                Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'afk'
                return 0
            }

            $actionable = @(Select-FmAutoarmLine -Text $armOutput `
                -Pattern '^(signal:|stale:|check:|heartbeat($|:))' -Limit 1).Count -gt 0
            if ($actionable) { break }

            # A non-actionable close is benign when another verified watcher
            # already owns this home and is still beating within the shared
            # grace window.
            if (Test-FmWatcherHealthy -State $state -WatchPath $watch -Grace $grace -FmHome $context.Home) {
                $healthy = $true
                break
            }
            if (-not ($attempt -lt $armAttempts)) { break }
            $armOutput = ''
        }

        # The need may have vanished mid-cycle (fleet torn down, X opted out):
        # nothing left to supervise, so close quietly instead of waking the
        # model.
        if (-not (Test-FmSupervisionNeeded -State $state -Grace $grace)) {
            Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'clean'
            return 0
        }

        if ($healthy) {
            if (Reset-FmHookFailureEpisode -State $state) {
                Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'clean'
                return 0
            }
            Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'failed-suppressed'
            if (Test-FmHookPathPresent $failureAlarm) { return 0 }
            return 2
        }

        # After the synchronous guard has consumed the episode's attended
        # fail-open, do not create another exit-2 continuation that could
        # defeat it.
        if (Test-FmHookPathPresent $failureAlarm) {
            Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'failed-suppressed'
            return 0
        }

        if ($actionable) {
            Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'rewake'
            Write-FmErr 'firstmate watcher wake - one supervision event needs a handling turn now.'
            foreach ($line in (Select-FmAutoarmLine -Text $armOutput -Pattern '^(signal:|stale:|check:|heartbeat)')) {
                Write-FmErr $line
            }
            Write-FmErr 'Run bin/fm-wake-drain.sh first and handle the wake. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.'
            return 2
        }

        # Notify only once for this continuous failure episode; every later
        # invocation still exits 2 so Claude must continue into another
        # Stop-owned retry without creating a repeated operator notice or
        # manual-arm loop.
        if (-not (Test-FmHookPathPresent $failureNotice)) {
            Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'failed'
            Write-FmErr ("firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after $attempt bounded attempts," +
                ' and no live watcher with a fresh beacon was verified.')
            foreach ($line in (Select-FmAutoarmLine -Text $armOutput -Pattern '^(watcher:|signal:|stale:|check:|heartbeat)')) {
                Write-FmErr $line
            }
            Write-FmErr 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.'
            try {
                # `: > "$FAILURE_NOTICE" 2>/dev/null || true` - a truncating
                # create, not an exclusive one: the marker's meaning is presence.
                Set-FmFileText -Path $failureNotice -Text '' -NoNewline
            } catch {
                $null = $_
            }
            return 2
        }
        Write-FmAutoarmEpoch -EpochPath $epoch -Outcome 'failed-suppressed'
        return 2
    } finally {
        # The `trap 'fm_lock_release "$OWNER_LOCK"' EXIT` twin.
        Unlock-FmHookLock -LockPath $ownerLock
    }
}

# Not Invoke-FmMain: this hook documents exactly 0 and 2, and 2 is a REWAKE
# request that costs the captain a turn. An escaped exception must therefore
# resolve to 0 - "leave continuity to the synchronous guard and the model" is
# the bash twin's own stated posture for every uncertainty.
$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmClaudeStopAutoarm)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
