# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# Twin: bin/fm-turnend-guard.sh
#
# fm-guard is pull-based: it only warns when some other supervision script
# happens to run. A primary session that ends a turn without resuming its
# harness supervision protocol, and then never runs another fleet-touching
# command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (state/.claude-autoarm.lock owner
#      alive) or to record a fresh rewake outcome (state/.claude-autoarm-epoch)
#      for this event epoch - either proof allows without consuming a
#      continuation, so one event epoch yields exactly one recovery turn;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow degraded with a visible
#      systemMessage so the session can always end.
# Any allow resets the consecutive-block budget.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES
#
# THE EXIT CODE IS THE WHOLE INTERFACE. 2 BLOCKS the turn ending and 0 allows
# it, and the two failure directions are not symmetric: a wrong 2 can wedge a
# captain's session, a wrong 0 lets the fleet run unsupervised. So every path
# below returns an explicit code, the block budget keeps its exact numbers
# (3 consecutive blocks, deliberately below Claude Code's hard 8-block
# override), and the banner bytes are reproduced rather than paraphrased -
# tests/fm-turnend-guard.test.sh matches on them.
#
# NO param() BLOCK, for the reason bin/fm-operational-input.ps1 records: the
# bash CLI takes bare positional words and a declared param block would make
# PowerShell try to BIND them before the script runs.
#
# IMPORTS CARRY NO -Force. -Force re-runs a module body, and fm-common's body
# re-applies the console encoding, which RESETS [Console]::In/Out - so a batched
# differential driver that redirects the console per case would have every case
# after the first read the driver's own stdin (tests/fm-hooks-psm1.test.sh
# records the debugging cycle that cost). It is also the nested-import rule in
# docs/powershell-port.md.
#
# DECLARED DIVERGENCE 1 - jq. The bash twin needs jq to read the loop-guard
# field and exits 0 when jq is missing, because without it the field cannot be
# read safely. This twin parses JSON in-process, so there is nothing to be
# missing: on a jq-less host it still classifies and still guards. The
# divergence is strictly in the guarding direction and is asserted explicitly in
# tests/fm-turnend-psm1.test.sh rather than normalized away.
#
# DECLARED DIVERGENCE 2 - a MULTI-DOCUMENT payload. `jq` reads a stream, so
# `{"a":1}{"b":2}` makes the bash twin emit one loop-guard answer per document;
# the concatenation is never the literal "true", so bash proceeds as though the
# loop guard were false. ConvertFrom-Json parses exactly one document and
# throws on trailing content, so this twin treats that payload as unreadable and
# allows (exit 0), which is what bash already does for every other unparseable
# payload. No verified harness emits one, and the Grok adapter rejects
# multi-document payloads outright before the guard is ever reached.
#
# THE WATCHER-PATH TOKEN IS PAIRED WITH bin/fm-watch.psm1, not with the bash
# watcher. The lock's watcher-path field is compared as a raw string, so this
# twin resolves the watcher the same way bin/fm-watch.psm1 does (prefer the
# .ps1 twin, fall back to the .sh) and reads a PowerShell watcher's lock.
# Cross-world healthy-watcher recognition is already impossible for a deeper
# reason - fm-wake-lib's documented divergence 2, where a Windows-native pid
# identity compares as MISMATCH against an MSYS one - so nothing is lost.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on any of these: see the conversion notes above.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervision-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-primary-scope-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$fmArgv = @($args)

# The 71-character rule the banner is drawn with, byte-identical to the bash
# twin's `rule=` assignment.
$script:FmGuardRule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# The reason printed when bin/fm-supervision-instructions cannot be run at all.
$script:FmGuardFallbackReason = 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

<#
.SYNOPSIS
The watcher script this home's lock would name (the WATCH variable).
.DESCRIPTION
Deliberately the same rule bin/fm-watch.psm1's Resolve-FmWatchSibling applies,
because the lock's watcher-path field is compared as a RAW STRING and a guard
that spelled it differently would never recognize its own watcher. Not
Invoke-FmScript: that owns RUNNING a sibling, and what is needed here is the
path (contract 7 in docs/powershell-port.md).
#>
function Get-FmGuardWatchPath {
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
Read a `${VAR:-<default>}` knob that must be a non-negative integer.
.DESCRIPTION
The twin of the three `case "$VALUE" in ''|*[!0-9]*) VALUE=<default> ;; esac`
guards. -RejectZero adds the `|0` alternative two of the three carry, because a
zero epoch-freshness window or a zero block budget would disable the very bound
the knob exists to impose.
#>
function Get-FmGuardNumericKnob {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][long]$Default,
        [switch]$RejectZero
    )
    $raw = Get-FmEnv -Name $Name
    if ($raw -notmatch '^[0-9]+$') { return $Default }
    [long]$value = 0
    if (-not [long]::TryParse($raw, [ref]$value)) { return $Default }
    if ($RejectZero -and $value -eq 0) { return $Default }
    return $value
}

<#
.SYNOPSIS
The loop-guard field, as a tri-state: $true, $false, or $null for "unreadable".
.DESCRIPTION
Byte-compatible with the bash twin's jq filter, including which shapes are an
ERROR (the `|| exit 0` fail-open) rather than a false:

  * a payload that is not a JSON object            -> unreadable
  * stopHookActive present but not a boolean       -> unreadable
  * stop_hook_active present but not a boolean     -> unreadable (only consulted
                                                     when the camel-case
                                                     spelling is absent, which
                                                     is the typed precedence)
  * neither key present                            -> $false

ConvertFrom-Json -AsHashtable resolves a duplicated key to the LAST occurrence,
which is what jq's `has`/`.field` pair does too, so a duplicated spelling reads
identically in both worlds.
#>
function Get-FmGuardStopHookActive {
    [CmdletBinding()]
    [OutputType([System.Nullable[bool]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $parsed = $null
    try {
        $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable
    } catch {
        return $null
    }
    if ($parsed -isnot [System.Collections.IDictionary]) { return $null }

    foreach ($key in @('stopHookActive', 'stop_hook_active')) {
        if (-not $parsed.Contains($key)) { continue }
        $value = $parsed[$key]
        if ($value -isnot [bool]) { return $null }
        return [bool]$value
    }
    return $false
}

<#
.SYNOPSIS
The payload's session id, or 'unknown' (the `.session_id // "unknown"` twin).
.DESCRIPTION
jq's `//` treats both null and false as absent, so both fall through to the
literal default; every other type is rendered the way `jq -r` renders it, with a
container printed as compact JSON.
#>
function Get-FmGuardSessionId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $parsed = $null
    try {
        $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable
    } catch {
        return 'unknown'
    }
    if ($parsed -isnot [System.Collections.IDictionary]) { return 'unknown' }
    if (-not $parsed.Contains('session_id')) { return 'unknown' }
    $value = $parsed['session_id']
    if ($null -eq $value) { return 'unknown' }
    if ($value -is [bool]) { if (-not $value) { return 'unknown' }; return 'true' }
    if ($value -is [string]) { return $value }
    if ($value -is [System.Collections.IDictionary] -or $value -is [System.Collections.IEnumerable]) {
        try { return (ConvertTo-Json -InputObject $value -Depth 20 -Compress) } catch { return 'unknown' }
    }
    return [string]$value
}

<#
.SYNOPSIS
True when the Stop-owned auto-arm already owns recovery for this event epoch.
.DESCRIPTION
Twin of autoarm_owns_recovery. Three independent proofs, in the bash twin's
order: a healthy watcher, a live owner-lock holder, or a rewake outcome recorded
within the freshness window. Any one of them means a continuation would be a
DUPLICATE, and the whole point of the cooperative path is not to spend one.
#>
function Test-FmGuardAutoarmOwnsRecovery {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$WatchPath,
        [Parameter(Mandatory, Position = 2)][string]$Grace,
        [Parameter(Mandatory, Position = 3)][string]$FmHome,
        [Parameter(Mandatory, Position = 4)][long]$EpochFresh
    )

    if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) {
        return $true
    }
    $ownerPid = (Get-FmFileText "$State/.claude-autoarm.lock/pid").TrimEnd("`r", "`n")
    if (Test-FmPidAlive -ProcessId $ownerPid) { return $true }

    # `sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p'`: every line that carries a
    # lower-case outcome word FOLLOWED BY A SPACE contributes one line of output,
    # and the leading `.*` is greedy, so the LAST `outcome=` on a line wins.
    # `$(...)` then joins those lines, which is why a multi-line ledger can only
    # equal "rewake" when it produced exactly one such line.
    $outcomes = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmFileLines "$State/.claude-autoarm-epoch")) {
        $m = [regex]::Match($line, '^.*outcome=([a-z][a-z]*) .*$')
        if ($m.Success) { $outcomes.Add($m.Groups[1].Value) }
    }
    if (($outcomes -join "`n") -ceq 'rewake') {
        $age = Get-FmPathAge -Path "$State/.claude-autoarm-epoch"
        if ($age -lt $EpochFresh) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Print the blind-turn banner on stderr. The caller then exits 2.
.DESCRIPTION
Twin of block_stop, including that the repair line comes from
bin/fm-supervision-instructions (through Invoke-FmScript, so the transition
picks whichever twin exists) and that a failure to run it degrades to the
literal fallback rather than to silence - a block with no instruction would be a
wedge with no way out.
#>
function Write-FmGuardBlockBanner {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$BinDir,
        [Parameter(Mandatory, Position = 1)][string]$State,
        [Parameter(Mandatory, Position = 2)][string]$ConfigDir,
        [Parameter(Mandatory, Position = 3)][int]$InFlight,
        [Parameter(Mandatory, Position = 4)][string]$BeaconDescription,
        [Parameter(Mandatory, Position = 5)][bool]$ClaudeMode
    )

    # `[ -e ... ]` and `[ -f ... ]`, kept distinct exactly as the bash twin has
    # them: an away-mode flag counts whatever kind of entry it is, while the
    # X-mode cadence must be a regular file.
    $afk = 0
    $afkPath = ConvertTo-FmNativePath "$State/.afk"
    if ([System.IO.File]::Exists($afkPath) -or [System.IO.Directory]::Exists($afkPath)) { $afk = 1 }
    $xMode = 0
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath "$ConfigDir/x-mode.env"))) { $xMode = 1 }

    $reason = $script:FmGuardFallbackReason
    try {
        $result = Invoke-FmScript -Name 'fm-supervision-instructions' -BinDir $BinDir -Arguments @(
            '--afk', [string]$afk, '--x-mode', [string]$xMode, '--repair-line'
        )
        if ($result.Ok) {
            $text = $result.StdOut.TrimEnd("`n")
            if (-not [string]::IsNullOrEmpty($text)) { $reason = $text }
        }
    } catch {
        # `|| printf '%s\n' '<fallback>'`: an unrunnable instruction renderer
        # must never turn a block into a silent one.
        $null = $_
    }

    $rule = $script:FmGuardRule
    Write-FmErr "●$rule"
    Write-FmErr '●  TURN WOULD END BLIND - SUPERVISION IS OFF'
    if ($InFlight -gt 0) {
        Write-FmErr "●  $InFlight task(s) in flight, but no live watcher holds this home lock (last beat: $BeaconDescription)."
    } else {
        Write-FmErr "●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: $BeaconDescription)."
    }
    if ($ClaudeMode) {
        Write-FmErr '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.'
    }
    Write-FmErr "●  $reason"
    Write-FmErr "●$rule"
}

<#
.SYNOPSIS
The whole guard, returning the process exit code instead of taking it.
#>
function Invoke-FmTurnendGuard {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $context = Get-FmContext -ScriptRoot $PSScriptRoot
    $state = $context.State
    $configDir = $context.Config
    $grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300'
    $watch = Get-FmGuardWatchPath -BinDir $PSScriptRoot
    $syncWaitMs = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS' -Default 800
    $epochFresh = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_AUTOARM_EPOCH_FRESH' -Default 15 -RejectZero
    $blockBudget = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_TURNEND_BLOCK_BUDGET' -Default 3 -RejectZero

    $claudeMode = $false
    foreach ($arg in $Arguments) {
        if ($arg -ceq '--claude') {
            $claudeMode = $true
            continue
        }
        # The usage line still names the .sh twin: it is the documented CLI
        # surface (contract 4) and both files must print the same bytes while
        # both exist.
        Write-FmErr 'usage: fm-turnend-guard.sh [--claude]'
        return 2
    }

    # Read the whole turn-end hook payload once; never block on unreadable or
    # absent stdin. `$(cat)` strips trailing newlines, so a payload of nothing
    # but newlines is empty in both worlds.
    $payload = ''
    try { $payload = [Console]::In.ReadToEnd() } catch { $payload = '' }
    if ($null -eq $payload) { $payload = '' }
    $payload = $payload.TrimEnd("`n")
    if ($payload -eq '') { return 0 }

    $stopHookActive = Get-FmGuardStopHookActive -Payload $payload
    if ($null -eq $stopHookActive) { return 0 }
    if (-not $claudeMode -and $stopHookActive) { return 0 }

    # --- scope precisely to a PRIMARY checkout -------------------------------
    # A genuinely-marked secondmate home runs its OWN primary firstmate session,
    # so force-INCLUDE it as a guarded primary whether treehouse leased it as a
    # linked worktree (git-dir != git-common-dir) or it is a git-cloned plain
    # checkout. Only an UNMARKED checkout (or one with an invalid marker) falls
    # through to the linked-worktree exemption: firstmate hands out
    # crewmate/scout task worktrees as genuine linked worktrees, and those never
    # carry the gitignored marker.
    if (-not (Test-FmPrimaryScopeMatch -Root $context.Root -State $state)) { return 0 }

    # --- the actual predicate ------------------------------------------------
    $budgetFile = "$state/.turnend-claude-blocks"
    $resetBudget = {
        if ($claudeMode) {
            try {
                $native = ConvertTo-FmNativePath $budgetFile
                if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
            } catch {
                # `rm -f ... || true`.
                $null = $_
            }
        }
    }

    $status = Get-FmSupervisionStatus -State $state -Grace $grace
    if ($claudeMode) {
        if (-not $status.Needed) { & $resetBudget; return 0 }
    } else {
        if ($status.InFlight -eq 0) { & $resetBudget; return 0 }
    }
    if (Test-FmWatcherHealthy -State $state -WatchPath $watch -Grace $grace -FmHome $context.Home) {
        & $resetBudget
        return 0
    }

    $blockArgs = @{
        BinDir            = $PSScriptRoot
        State             = $state
        ConfigDir         = $configDir
        InFlight          = $status.InFlight
        BeaconDescription = $status.BeaconDescription
        ClaudeMode        = $claudeMode
    }

    if (-not $claudeMode) {
        Write-FmGuardBlockBanner @blockArgs
        return 2
    }

    # --- --claude cooperative path -------------------------------------------
    # The Stop-owned auto-arm fires on the same Stop event. Give it a brief
    # bounded window to prove it owns recovery for this event epoch before
    # consuming one of Claude's bounded continuations.
    $ownsArgs = @{
        State      = $state
        WatchPath  = $watch
        Grace      = $grace
        FmHome     = $context.Home
        EpochFresh = $epochFresh
    }
    $iterations = [long][Math]::Floor($syncWaitMs / 100)
    for ($i = 0; $i -lt $iterations; $i++) {
        if (Test-FmGuardAutoarmOwnsRecovery @ownsArgs) { & $resetBudget; return 0 }
        Start-Sleep -Milliseconds 100
    }
    if (Test-FmGuardAutoarmOwnsRecovery @ownsArgs) { & $resetBudget; return 0 }

    # The auto-arm genuinely failed to establish: re-block, but never past the
    # budget so the session can always end and Claude's 8-block override is
    # never approached.
    $sessionId = Get-FmGuardSessionId -Payload $payload
    $count = 0
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $budgetFile))) {
        # `sed -n '1s/^session=//p'` and `sed -n '2s/^count=//p'`: the `p` is
        # attached to the substitution, so a line that does not carry the prefix
        # contributes NOTHING rather than contributing itself.
        $lines = @(Get-FmFileLines $budgetFile)
        $oldSession = ''
        if ($lines.Count -ge 1 -and $lines[0].StartsWith('session=', [System.StringComparison]::Ordinal)) {
            $oldSession = $lines[0].Substring('session='.Length)
        }
        $oldCount = ''
        if ($lines.Count -ge 2 -and $lines[1].StartsWith('count=', [System.StringComparison]::Ordinal)) {
            $oldCount = $lines[1].Substring('count='.Length)
        }
        if ($oldCount -notmatch '^[0-9]+$') { $oldCount = '0' }
        if ($oldSession -ceq $sessionId) { $count = [long]$oldCount }
    }
    $count = $count + 1
    if ($count -gt $blockBudget) {
        & $resetBudget
        $needDesc = if ($status.InFlight -gt 0) {
            "$($status.InFlight) task(s) in flight"
        } else {
            'X-mode relay polling active'
        }
        Write-FmOut ('{"systemMessage":"firstmate turn-end guard: ' + $needDesc +
            ' with no live watcher and no Stop auto-arm claim; block budget exhausted, allowing this stop.' +
            ' Repair supervision (bin/fm-watch-arm.sh as a Claude Code background task) or investigate why' +
            ' bin/fm-claude-stop-autoarm.sh is not claiming this home."}')
        return 0
    }
    try {
        Set-FmFileText -Path $budgetFile -Text "session=$sessionId`ncount=$count"
    } catch {
        # `> "$BUDGET_FILE" 2>/dev/null || true`: an unwritable budget file must
        # not change the block decision, only the bound's memory.
        $null = $_
    }
    Write-FmGuardBlockBanner @blockArgs
    return 2
}

# Not Invoke-FmMain: an escaped exception must NOT become a nonzero code here,
# because 2 is the BLOCK signal and a defect that blocked every turn end would
# wedge the captain's session. A guard that cannot decide allows, exactly as
# every documented failure path in the bash twin does.
$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmTurnendGuard -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
