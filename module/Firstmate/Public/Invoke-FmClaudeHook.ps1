#requires -Version 7.0

<#
.SYNOPSIS
    The Claude Code hook surface: SessionStart, PreToolUse, and Stop.

.DESCRIPTION
    Port of the tracked Claude hook entrypoints - bin/fm-sessionstart-run.sh,
    bin/fm-arm-pretool-check.sh, bin/fm-cd-pretool-check.sh,
    bin/fm-subagent-pretool-check.sh, bin/fm-turnend-guard.sh --claude, and
    bin/fm-claude-stop-autoarm.sh. docs/turnend-guard.md is the authoritative
    contract; docs/claude-hooks-windows.md records what this port assumes about
    the Windows host.

    WINDOWS-UNVERIFIED: every hook-observable behaviour here - PowerShell-native
    hook execution, payload delivery on stdin, exit-2 blocking, Stop asyncRewake
    background firing, and the systemMessage/hookSpecificOutput response shapes -
    is written to Claude Code's documentation and has not been exercised against
    Claude Code on Windows from this port.

    Returns a decision object (ExitCode, Stdout, Stderr). bin/fm-claude-hook.ps1
    is the one place that turns it into a process exit code.

.PARAMETER Event
    SessionStart, PreToolUse, or Stop.

.PARAMETER Check
    Which hook of that event to run: for PreToolUse one of arm|cd|subagent, for
    Stop one of turnend-guard|autoarm.

.PARAMETER Payload
    The raw hook payload. When omitted it is read from stdin.

.EXAMPLE
    Invoke-FmClaudeHook -Event Stop -Check turnend-guard -Payload $json
#>
function Invoke-FmClaudeHook {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('SessionStart', 'PreToolUse', 'Stop')][string]$Event,
        [string]$Check,
        [AllowEmptyString()][AllowNull()][string]$Payload
    )

    # Keyed on whether the caller BOUND the parameter, not on its value: an
    # unbound [string] parameter arrives as the empty string, not $null, so a
    # null test here silently skipped the stdin read and made every hook fail
    # open on an empty payload.
    if (-not $PSBoundParameters.ContainsKey('Payload')) { $Payload = Read-FmHookStdin }

    switch ($Event) {
        'SessionStart' { return (Invoke-FmClaudeSessionStartHook -Payload $Payload) }
        'PreToolUse' {
            if ([string]::IsNullOrEmpty($Check)) { $Check = 'arm' }
            return (Invoke-FmClaudePreToolUseHook -Payload $Payload -Check $Check)
        }
        'Stop' {
            if ([string]::IsNullOrEmpty($Check)) { $Check = 'turnend-guard' }
            if ($Check -eq 'autoarm') { return (Invoke-FmClaudeStopAutoArm -Payload $Payload) }
            return (Invoke-FmClaudeTurnEndGuard -Payload $Payload -ClaudeMode)
        }
    }
}

# WINDOWS-UNVERIFIED: that Claude Code on Windows delivers the hook payload on
# stdin to a PowerShell-native hook exactly as it does to a POSIX shell hook.
# A terminal stdin is skipped outright, because a hook always pipes its payload
# and an operator running this by hand must not be left waiting on a read.
function Read-FmHookStdin {
    [CmdletBinding()]
    param()

    try {
        if ([Console]::IsInputRedirected) { return [Console]::In.ReadToEnd() }
    } catch { }
    return ''
}

<#
.SYNOPSIS
    SessionStart hook: run the digest, re-emit it, or nudge, by session-open source.
.DESCRIPTION
    Every path exits 0. A Claude SessionStart exit 2 blocks session
    initialization, so a failed session start must reach the agent as digest text
    it can act on, never as a refusal to open the session.

    WINDOWS-UNVERIFIED: that Claude Code on Windows injects SessionStart hook
    stdout into model context, and that it sets CLAUDE_PROJECT_DIR for a
    PowerShell-native hook.
#>
function Invoke-FmClaudeSessionStartHook {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Payload,
        [string]$Source
    )

    $paths = Get-FmSessionPaths

    if ([string]::IsNullOrEmpty($Source)) {
        $parsed = ConvertFrom-FmHookPayload -Payload $Payload
        if ($null -ne $parsed -and $parsed.ContainsKey('source') -and $parsed['source'] -is [string]) {
            $Source = [string]$parsed['source']
        }
    }

    # The same two eligibility owners the nudge wrapper uses, so a gate agent and
    # an unmarked task worktree can never run a session start for a home they do
    # not own.
    $gateAgent = Resolve-FmSessionCommand -Name 'Test-FmGateAgent'
    if ($gateAgent) {
        try { if (& $gateAgent -Root $paths.Root) { return (New-FmHookDecision) } } catch { }
    }
    if (-not (Test-FmHookPrimaryScope -Root $paths.Root -State $paths.State)) {
        return (New-FmHookDecision)
    }

    $route = Get-FmHookSessionStartRoute -Source $Source -StartupCompleted (Test-FmHookStartupCompleted -State $paths.State)
    $entry = Join-Path $paths.Root 'bin' 'fm-session-start.ps1'

    switch ($route) {
        'nudge' {
            $nudge = Resolve-FmSessionCommand -Name 'Invoke-FmSessionStartNudge'
            if (-not $nudge) { return (New-FmHookDecision) }
            try {
                return (New-FmHookDecision -Stdout @(& $nudge 2>&1 | ForEach-Object { [string]$_ }))
            } catch {
                return (New-FmHookDecision)
            }
        }
        'reemit' { return (New-FmHookDecision -Stdout @(Invoke-FmSessionStart -Reemit -Bounded -EntryScript $entry)) }
        default { return (New-FmHookDecision -Stdout @(Invoke-FmSessionStart -Bounded -EntryScript $entry)) }
    }
}

<#
.SYNOPSIS
    PreToolUse hook: deny an unsafe command before it executes.
.DESCRIPTION
    The command policies (watcher-arm protection, the cd guard, the subagent
    guard) are owned by their own areas of this module. This hook only acquires
    the payload, delegates, and renders the established Claude-shaped response.
    It never executes, sources, evaluates, or expands the submitted command.

    ALLOW - exit 0 and no output.
    DENY  - exit 2 with a Claude-shaped deny object on stderr and empty stdout.
    FAIL OPEN - malformed or empty payload, or a missing policy owner.

    WINDOWS-UNVERIFIED: that Claude Code on Windows honours exit 2 from a
    PowerShell-native PreToolUse hook as a deny, and that it still requires
    stdout to stay empty on that deny.
#>
function Invoke-FmClaudePreToolUseHook {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Payload,
        [ValidateSet('arm', 'cd', 'subagent')][string]$Check = 'arm'
    )

    $parsed = ConvertFrom-FmHookPayload -Payload $Payload
    if ($null -eq $parsed) { return (New-FmHookDecision) }

    $policyName = switch ($Check) {
        'arm' { 'Test-FmArmCommandPolicy' }
        'cd' { 'Test-FmCdCommandPolicy' }
        'subagent' { 'Test-FmSubagentPolicy' }
    }
    $policy = Resolve-FmSessionCommand -Name $policyName
    if (-not $policy) { return (New-FmHookDecision) }

    if ($Check -eq 'subagent') {
        # The subagent guard matches every tool, not just Bash, so it is handed
        # the whole payload rather than a command string.
        $verdict = $null
        try { $verdict = & $policy -Payload $parsed } catch { return (New-FmHookDecision) }
        return (Resolve-FmHookPolicyVerdict -Verdict $verdict)
    }

    $command = Get-FmHookToolCommand -Payload $parsed
    if ([string]::IsNullOrEmpty($command)) { return (New-FmHookDecision) }

    $verdict = $null
    try { $verdict = & $policy -Command $command } catch { return (New-FmHookDecision) }
    return (Resolve-FmHookPolicyVerdict -Verdict $verdict)
}

# An invalid policy response fails open: the policy owner is the only thing
# allowed to decide deny, so an unreadable verdict is not one.
function Resolve-FmHookPolicyVerdict {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Verdict)

    if (-not (Get-FmHookVerdictField -Verdict $Verdict -Field 'Deny')) { return (New-FmHookDecision) }
    $code = [string](Get-FmHookVerdictField -Verdict $Verdict -Field 'Code')
    $reason = [string](Get-FmHookVerdictField -Verdict $Verdict -Field 'Reason')
    if ([string]::IsNullOrEmpty($code) -or [string]::IsNullOrEmpty($reason)) { return (New-FmHookDecision) }
    return (New-FmHookDenyDecision -Code $code -Reason $reason)
}

<#
.SYNOPSIS
    Stop hook: block a turn that would end with supervision off.
.DESCRIPTION
    Port of bin/fm-turnend-guard.sh. In --claude mode the guard IGNORES
    stop_hook_active, because Claude Code marks EVERY stop after ANY stop-hook
    continuation - including asyncRewake rewakes - which would re-open the exact
    blind window this guard exists to close. Instead it cooperates with the
    Stop-owned auto-arm that fires on the same Stop event:
      1. a live identity-matched watcher with a fresh beacon allows immediately;
      2. otherwise wait briefly for the auto-arm to claim this home or to record a
         fresh actionable outcome for this event epoch - either proof allows
         without consuming a continuation;
      3. only when neither materializes is the auto-arm genuinely absent: re-block
         with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
         consecutive blocks, then allow one loud attended fail-open for an already
         verified failure episode.

    WINDOWS-UNVERIFIED: that Claude Code on Windows honours exit 2 plus stderr
    from a PowerShell-native Stop hook as a block-with-feedback.
#>
function Invoke-FmClaudeTurnEndGuard {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Payload,
        [switch]$ClaudeMode
    )

    $paths = Get-FmSessionPaths
    $state = $paths.State
    $grace = Get-FmHookGrace

    $syncWaitMs = 800
    if ($env:FM_CLAUDE_AUTOARM_SYNC_WAIT_MS -match '^\d+$') { $syncWaitMs = [int]$env:FM_CLAUDE_AUTOARM_SYNC_WAIT_MS }
    $epochFresh = 15
    if ($env:FM_CLAUDE_AUTOARM_EPOCH_FRESH -match '^\d+$' -and [int]$env:FM_CLAUDE_AUTOARM_EPOCH_FRESH -gt 0) {
        $epochFresh = [int]$env:FM_CLAUDE_AUTOARM_EPOCH_FRESH
    }
    $blockBudget = 3
    if ($env:FM_CLAUDE_TURNEND_BLOCK_BUDGET -match '^\d+$' -and [int]$env:FM_CLAUDE_TURNEND_BLOCK_BUDGET -gt 0) {
        $blockBudget = [int]$env:FM_CLAUDE_TURNEND_BLOCK_BUDGET
    }

    # Never block on unreadable or absent input, and never block when the
    # loop-guard field cannot be read: fail open, not noisy.
    if ([string]::IsNullOrWhiteSpace($Payload)) { return (New-FmHookDecision) }
    $parsed = ConvertFrom-FmHookPayload -Payload $Payload
    if ($null -eq $parsed) { return (New-FmHookDecision) }
    $stopHookActive = Get-FmHookStopHookActive -Payload $parsed
    if ($null -eq $stopHookActive) { return (New-FmHookDecision) }
    if (-not $ClaudeMode -and $stopHookActive) { return (New-FmHookDecision) }

    if (-not (Test-FmHookPrimaryScope -Root $paths.Root -State $state)) { return (New-FmHookDecision) }

    $sessionId = 'unknown'
    if ($parsed.ContainsKey('session_id') -and $parsed['session_id'] -is [string]) { $sessionId = [string]$parsed['session_id'] }

    $failureNotice = Join-Path $state '.claude-autoarm-failure-notified'
    $failureAlarm = Join-Path $state '.claude-autoarm-failure-alarmed'

    $status = Get-FmHookSupervisionStatus -State $state -Grace $grace
    if (-not $status.Needed) {
        if ($ClaudeMode -and -not (Test-Path -LiteralPath $failureNotice)) {
            $lock = Join-Path $state '.turnend-claude-blocks.lock'
            if (New-FmHookLock -Path $lock) {
                Remove-Item -LiteralPath (Join-Path $state '.turnend-claude-blocks') -Force -ErrorAction SilentlyContinue
                Remove-FmHookLock -Path $lock
            }
        }
        return (New-FmHookDecision)
    }

    $healthy = Test-FmHookWatcherHealthy -State $state -Grace $grace
    # The watcher predicate's owner is not loaded: the guard cannot evaluate its
    # own condition, so it must not block. Same rule the bash guard applies to a
    # missing jq.
    if ($null -eq $healthy) { return (New-FmHookDecision) }

    if ($healthy) {
        if (-not $ClaudeMode) { return (New-FmHookDecision) }
        if (Reset-FmHookFailureEpisode -State $state) { return (New-FmHookDecision) }
        return (New-FmHookDecision -ExitCode 2)
    }

    if (-not $ClaudeMode) { return (New-FmHookBlockDecision -Paths $paths -Status $status -ClaudeMode:$false) }

    # --- the cooperative path -------------------------------------------------
    $ownsRecovery = {
        (Test-FmHookAutoArmOwnsRecovery -State $state -SessionId $sessionId -Grace $grace `
                -EpochFresh $epochFresh -FailureNotice $failureNotice).Owns
    }

    $waited = 0
    $owns = $false
    while ($waited -lt [math]::Floor($syncWaitMs / 100)) {
        if (& $ownsRecovery) { $owns = $true; break }
        Start-Sleep -Milliseconds 100
        $waited++
    }
    if (-not $owns) { $owns = & $ownsRecovery }

    if ($owns) {
        if (Test-FmHookWatcherHealthy -State $state -Grace $grace) {
            if (-not (Reset-FmHookFailureEpisode -State $state)) { return (New-FmHookDecision -ExitCode 2) }
        }
        return (New-FmHookDecision)
    }

    # The auto-arm genuinely failed to establish: consume the bounded re-block
    # budget before considering the verified one-time attended fail-open.
    $budget = Update-FmHookBlockBudget -State $state -SessionId $sessionId -FailureNotice $failureNotice
    if (-not $budget.Ok) { return (New-FmHookBlockDecision -Paths $paths -Status $status -ClaudeMode) }

    $terminal = Invoke-FmHookTerminalFailOpen -State $state -SessionId $sessionId -Count $budget.Count `
        -BlockBudget $blockBudget -Grace $grace -FailureNotice $failureNotice -FailureAlarm $failureAlarm
    if ($terminal -eq 'alarm') {
        $needDesc = if ($status.InFlight -gt 0) {
            "$($status.InFlight) task(s) in flight"
        } elseif ($status.Sources -gt 0) {
            "$($status.Sources) process-event source(s) registered"
        } else {
            'X-mode relay polling active'
        }
        $message = [ordered]@{
            systemMessage = "FIRSTMATE SUPERVISION IS GENUINELY DOWN: $needDesc, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."
        }
        return (New-FmHookDecision -Stdout @(($message | ConvertTo-Json -Compress -Depth 4)))
    }
    if ($terminal -eq 'allow') { return (New-FmHookDecision) }
    return (New-FmHookBlockDecision -Paths $paths -Status $status -ClaudeMode)
}

function New-FmHookBlockDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$Status,
        [switch]$ClaudeMode
    )

    $afk = if (Test-Path -LiteralPath (Join-Path $Paths.State '.afk')) { 1 } else { 0 }
    $xMode = if (Test-Path -LiteralPath (Join-Path $Paths.Config 'x-mode.env') -PathType Leaf) { 1 } else { 0 }

    $reason = 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'
    $repair = Resolve-FmSessionCommand -Name 'Get-FmSupervisionRepairLine'
    if ($repair) {
        try {
            $line = [string](& $repair -Afk $afk -XMode $xMode)
            if (-not [string]::IsNullOrWhiteSpace($line)) { $reason = $line }
        } catch { }
    }

    $rule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    $stderr = @("●$rule", '●  TURN WOULD END BLIND - SUPERVISION IS OFF')
    if ($Status.InFlight -gt 0) {
        $stderr += "●  $($Status.InFlight) task(s) in flight, but no live watcher holds this home lock (last beat: $($Status.BeaconDesc))."
    } elseif ($Status.Sources -gt 0) {
        $stderr += "●  $($Status.Sources) process-event source(s) registered, but no live watcher holds this home lock (last beat: $($Status.BeaconDesc))."
    } else {
        $stderr += "●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: $($Status.BeaconDesc))."
    }
    if ($ClaudeMode) {
        $stderr += '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.'
    }
    $stderr += "●  $reason"
    $stderr += "●$rule"

    New-FmHookDecision -ExitCode 2 -Stderr $stderr
}

# Give the Stop-owned auto-arm a brief bounded window to prove it owns recovery
# for this event epoch before consuming one of Claude's bounded continuations.
function Test-FmHookAutoArmOwnsRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$Grace,
        [Parameter(Mandatory)][int]$EpochFresh,
        [Parameter(Mandatory)][string]$FailureNotice
    )

    $budget = $null
    $result = { param($owns) [pscustomobject]@{ Owns = $owns; Budget = $budget } }

    if (Test-FmHookWatcherHealthy -State $State -Grace $Grace) { return (& $result $true) }

    $ownerLock = Join-Path $State '.claude-autoarm.lock'
    $ownerPid = Get-FmHookLockField -Path $ownerLock -Field 'pid'
    $role = Get-FmHookLockRole -Path $ownerLock
    if ((Test-FmHookPidAlive -ProcessId $ownerPid) -and $role -eq 'autoarm') {
        if (Test-Path -LiteralPath $FailureNotice) {
            $budget = Update-FmHookBlockBudget -State $State -SessionId $SessionId -FailureNotice $FailureNotice
        }
        return (& $result $true)
    }

    $epoch = Get-FmHookEpochRecord -State $State
    switch ($epoch.Outcome) {
        'rewake' {
            if ($epoch.Age -lt $EpochFresh) {
                if (Test-Path -LiteralPath $FailureNotice) {
                    $budget = Update-FmHookBlockBudget -State $State -SessionId $SessionId -FailureNotice $FailureNotice
                }
                return (& $result $true)
            }
        }
        'failed' {
            # The FIRST fresh exhausted-failure epoch preserves its handoff
            # without consuming a blocked-stop count; later fresh failed epochs
            # advance the same monotonic progression instead of resetting it.
            if ($epoch.Age -lt $EpochFresh -and (Test-Path -LiteralPath $FailureNotice)) {
                $budget = Update-FmHookBlockBudget -State $State -SessionId $SessionId -FailureNotice $FailureNotice
                if ($budget.Ok -and $budget.InitializedFailure) { return (& $result $true) }
            }
        }
        'failed-suppressed' {
            if ($epoch.Age -lt $EpochFresh -and (Test-Path -LiteralPath $FailureNotice)) {
                $budget = Update-FmHookBlockBudget -State $State -SessionId $SessionId -FailureNotice $FailureNotice
            }
        }
    }
    return (& $result $false)
}

# Account this event epoch against the bounded block budget, under the budget
# lock. One epoch identity is counted at most once.
function Update-FmHookBlockBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$FailureNotice
    )

    $failed = [pscustomobject]@{ Ok = $false; Count = 0; InitializedFailure = $false }
    $lock = Join-Path $State '.turnend-claude-blocks.lock'
    if (-not (New-FmHookLock -Path $lock)) { return $failed }

    try {
        $epoch = Get-FmHookEpochRecord -State $State
        $existing = Get-FmHookBudgetRecord -State $State
        $count = 0
        $initialized = $false

        if ($existing.Present -and $existing.Session -eq $SessionId) {
            $count = $existing.Count
            if (-not ([string]::IsNullOrEmpty($epoch.Epoch)) -and $existing.Epoch -eq $epoch.Epoch) {
                # Same epoch already accounted: do not consume another block.
            } else {
                $count++
            }
        } else {
            switch ($epoch.Outcome) {
                { $_ -in 'failed', 'failed-suppressed' } {
                    if (Test-Path -LiteralPath $FailureNotice) {
                        $initialized = $true
                        $count = 0
                    } else {
                        $count = 1
                    }
                }
                default { $count = 1 }
            }
        }

        if (-not (Write-FmHookBudgetRecord -State $State -Session $SessionId -Count $count -Epoch $epoch.Epoch)) {
            return $failed
        }
        return [pscustomobject]@{ Ok = $true; Count = $count; InitializedFailure = $initialized }
    } finally {
        Remove-FmHookLock -Path $lock
    }
}

# The one loud attended fail-open. Available ONLY when the auto-arm has recorded
# an exhausted failure, its one notice is already consumed, the block budget is
# exhausted, and a final check finds neither a healthy watcher nor an automatic
# continuation. Returns 'alarm', 'allow', or 'none'.
function Invoke-FmHookTerminalFailOpen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$BlockBudget,
        [Parameter(Mandatory)][int]$Grace,
        [Parameter(Mandatory)][string]$FailureNotice,
        [Parameter(Mandatory)][string]$FailureAlarm
    )

    if ($Count -le $BlockBudget) { return 'none' }
    if (-not (Test-FmHookFailureEpisodeVerified -State $State -FailureNotice $FailureNotice)) { return 'none' }
    if (Test-Path -LiteralPath $FailureAlarm) { return 'none' }

    $ownerLock = Join-Path $State '.claude-autoarm.lock'
    # Whenever both coordination locks are needed, the owner lock is acquired
    # before the budget lock, in that order, everywhere.
    if (-not (New-FmHookLock -Path $ownerLock)) {
        $ownerPid = Get-FmHookLockField -Path $ownerLock -Field 'pid'
        $role = Get-FmHookLockRole -Path $ownerLock
        if ((Test-FmHookPidAlive -ProcessId $ownerPid) -and $role -eq 'autoarm') { return 'allow' }
        return 'none'
    }

    try {
        if (-not (Set-FmHookLockRole -Path $ownerLock -Role 'terminal-check')) { return 'none' }

        $budgetLock = Join-Path $State '.turnend-claude-blocks.lock'
        if (-not (New-FmHookLock -Path $budgetLock)) { return 'none' }
        try {
            $record = Get-FmHookBudgetRecord -State $State
            if ((Get-FmHookLockRole -Path $ownerLock) -ne 'terminal-check' -or
                $record.Session -ne $SessionId -or
                $record.Count -le $BlockBudget -or
                -not (Test-FmHookFailureEpisodeVerified -State $State -FailureNotice $FailureNotice) -or
                (Test-Path -LiteralPath $FailureAlarm)) {
                return 'none'
            }
            if (Test-FmHookWatcherHealthy -State $State -Grace $Grace) {
                if (-not (Reset-FmHookFailureEpisode -State $State -Mode held)) { return 'none' }
                return 'allow'
            }
            try {
                $stream = [System.IO.File]::Open($FailureAlarm, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                $stream.Dispose()
            } catch {
                return 'none'
            }
            return 'alarm'
        } finally {
            Remove-FmHookLock -Path $budgetLock
        }
    } finally {
        Remove-FmHookLock -Path $ownerLock
    }
}

function Test-FmHookFailureEpisodeVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$FailureNotice
    )

    if (Test-Path -LiteralPath (Join-Path $State '.afk')) { return $false }
    if (-not (Test-Path -LiteralPath $FailureNotice)) { return $false }
    $epoch = Get-FmHookEpochRecord -State $State
    return ($epoch.Outcome -in @('failed', 'failed-suppressed'))
}

<#
.SYNOPSIS
    Stop-owned watcher auto-arm (the asyncRewake hook).
.DESCRIPTION
    Port of bin/fm-claude-stop-autoarm.sh. Claude Code fires this in the
    background on EVERY Stop of a Claude primary session with no deduplication,
    so a home-scoped owner lock admits exactly one owner and every other
    concurrent firing exits 0 without translating. It never blocks the Stop
    decision itself and never prints to stdout: exit 0 is always silent, and
    exit 2 carries the rewake banner on stderr.

    WINDOWS-UNVERIFIED: that Claude Code on Windows fires an asyncRewake Stop
    hook in the background, honours its multi-hour timeout, and treats its exit 2
    as a rewake of an idle session.
#>
function Invoke-FmClaudeStopAutoArm {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][AllowNull()][string]$Payload)

    $paths = Get-FmSessionPaths
    $state = $paths.State
    $grace = Get-FmHookGrace
    $attempts = 2
    if ($env:FM_CLAUDE_AUTOARM_ATTEMPTS -in @('1', '2', '3')) { $attempts = [int]$env:FM_CLAUDE_AUTOARM_ATTEMPTS }

    $ownerLock = Join-Path $state '.claude-autoarm.lock'
    $failureNotice = Join-Path $state '.claude-autoarm-failure-notified'
    $failureAlarm = Join-Path $state '.claude-autoarm-failure-alarmed'

    # Scope: only a genuine primary checkout. Child crew/scout worktrees stay inert.
    if (-not (Test-FmHookPrimaryScope -Root $paths.Root -State $state)) { return (New-FmHookDecision) }

    # Identity: only the lock-owning session's hooks may arm. A live owner,
    # missing lock, malformed lock, or unresolved ancestry remains inert, so a
    # competing session never arms or rewakes.
    $recoverSessionLock = $false
    $ownedBySelf = Resolve-FmSessionCommand -Name 'Test-FmSessionLockOwnedBySelf'
    if ($ownedBySelf) {
        $owned = $false
        try { $owned = [bool](& $ownedBySelf -State $state) } catch { $owned = $false }
        if (-not $owned) {
            $lockLines = @(Get-FmSessionFileLines -Path (Join-Path $state '.lock'))
            $lockPid = if ($lockLines.Count -ge 1) { $lockLines[0] } else { '' }
            if ($lockPid -notmatch '^\d+$') { return (New-FmHookDecision) }
            $harnessAlive = Resolve-FmSessionCommand -Name 'Test-FmHarnessPidAlive'
            if ($harnessAlive) {
                $alive = $true
                try { $alive = [bool](& $harnessAlive -ProcessId $lockPid) } catch { $alive = $true }
                if ($alive) { return (New-FmHookDecision) }
            } elseif (Test-FmHookPidAlive -ProcessId $lockPid) {
                return (New-FmHookDecision)
            }
            $recoverSessionLock = $true
        }
    }

    # AFK: the away daemon owns the watcher and triage; never rewake.
    if (Test-Path -LiteralPath (Join-Path $state '.afk')) { return (New-FmHookDecision) }

    # Need: in-flight work or an X-mode relay poll.
    if (-not (Get-FmHookSupervisionStatus -State $state -Grace $grace).Needed) { return (New-FmHookDecision) }

    # Stale session-lock recovery is delegated to the lock owner so its
    # live-owner refusal and write semantics remain the single acquisition owner.
    if ($recoverSessionLock) {
        $lockCmd = Resolve-FmSessionCommand -Name 'Invoke-FmLock'
        if (-not $lockCmd) { return (New-FmHookDecision) }
        try { & $lockCmd | Out-Null } catch { return (New-FmHookDecision) }
        $owned = $false
        try { $owned = [bool](& $ownedBySelf -State $state) } catch { $owned = $false }
        if (-not $owned) { return (New-FmHookDecision) }
    }

    $arm = Resolve-FmSessionCommand -Name 'Invoke-FmWatchArm'
    if (-not $arm) {
        # The arm's owner is not loaded, so this hook cannot establish
        # supervision. Stay silent and inert; continuity falls to the
        # synchronous guard and the model, exactly as any other uncertainty here.
        return (New-FmHookDecision)
    }

    # Single-flight: exactly one owner foregrounds the arm and translates its
    # close, which keeps one event epoch on exactly one recovery turn.
    if (-not (New-FmHookLock -Path $ownerLock)) { return (New-FmHookDecision) }
    if (-not (Set-FmHookLockRole -Path $ownerLock -Role 'autoarm')) {
        Remove-FmHookLock -Path $ownerLock
        return (New-FmHookDecision)
    }

    try {
        Write-FmHookEpochRecord -State $state -Outcome 'arming'

        $armOutput = @()
        $actionable = $false
        $healthy = $false
        $attempt = 0
        while ($attempt -lt $attempts) {
            $attempt++
            try {
                $armOutput = @(& $arm 2>&1 | ForEach-Object { [string]$_ })
            } catch {
                $armOutput = @()
            }

            # AFK may have appeared mid-cycle: the daemon owns triage now, so
            # suppress every subsequent classification and handoff.
            if (Test-Path -LiteralPath (Join-Path $state '.afk')) {
                Write-FmHookEpochRecord -State $state -Outcome 'afk'
                return (New-FmHookDecision)
            }

            $actionable = [bool](@($armOutput | Where-Object { $_ -match '^(signal:|stale:|check:|heartbeat($|:))' }).Count)
            if ($actionable) { break }

            # A non-actionable close is benign when another verified watcher
            # already owns this home and is still beating within grace.
            if (Test-FmHookWatcherHealthy -State $state -Grace $grace) { $healthy = $true; break }
        }

        # The need may have vanished mid-cycle (fleet torn down, X opted out):
        # close quietly instead of waking the model.
        if (-not (Get-FmHookSupervisionStatus -State $state -Grace $grace).Needed) {
            Write-FmHookEpochRecord -State $state -Outcome 'clean'
            return (New-FmHookDecision)
        }

        if ($healthy) {
            if (Reset-FmHookFailureEpisode -State $state) {
                Write-FmHookEpochRecord -State $state -Outcome 'clean'
                return (New-FmHookDecision)
            }
            Write-FmHookEpochRecord -State $state -Outcome 'failed-suppressed'
            if (Test-Path -LiteralPath $failureAlarm) { return (New-FmHookDecision) }
            return (New-FmHookDecision -ExitCode 2)
        }

        # After the synchronous guard has consumed the episode's attended
        # fail-open, do not create another exit-2 continuation that could defeat it.
        if (Test-Path -LiteralPath $failureAlarm) {
            Write-FmHookEpochRecord -State $state -Outcome 'failed-suppressed'
            return (New-FmHookDecision)
        }

        if ($actionable) {
            Write-FmHookEpochRecord -State $state -Outcome 'rewake'
            $stderr = @('firstmate watcher wake - one supervision event needs a handling turn now.')
            $stderr += @($armOutput | Where-Object { $_ -match '^(signal:|stale:|check:|heartbeat)' } | Select-Object -First 8)
            $stderr += 'Run the wake drain first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT arm the watcher by hand after an ordinary wake.'
            return (New-FmHookDecision -ExitCode 2 -Stderr $stderr)
        }

        # Notify only once for this continuous failure episode; every later
        # invocation still exits 2 so Claude must continue into another
        # Stop-owned retry without creating a repeated operator notice.
        if (-not (Test-Path -LiteralPath $failureNotice)) {
            Write-FmHookEpochRecord -State $state -Outcome 'failed'
            $stderr = @("firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after $attempt bounded attempts, and no live watcher with a fresh beacon was verified.")
            $stderr += @($armOutput | Where-Object { $_ -match '^(watcher:|signal:|stale:|check:|heartbeat)' } | Select-Object -First 8)
            $stderr += 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.'
            try { Write-FmSessionTextFile -Path $failureNotice -Content '' } catch { }
            return (New-FmHookDecision -ExitCode 2 -Stderr $stderr)
        }

        Write-FmHookEpochRecord -State $state -Outcome 'failed-suppressed'
        return (New-FmHookDecision -ExitCode 2)
    } finally {
        Remove-FmHookLock -Path $ownerLock
    }
}

<#
.SYNOPSIS
    Emit the tracked .claude/settings.json content for PowerShell-native hooks.
.DESCRIPTION
    WINDOWS-UNVERIFIED: the per-hook "shell": "powershell" field is documented by
    Claude Code for Windows and has not been exercised from this port.
#>
function Get-FmClaudeHookSettings {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$AsObject)

    $settings = Get-FmClaudeHookSettingsObject
    if ($AsObject) { return $settings }
    return ($settings | ConvertTo-Json -Depth 8)
}
