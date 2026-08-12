# fm-control.ps1 - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.ps1 <task-id> interrupt
#        fm-control.ps1 <task-id> exit
#        fm-control.ps1 <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent).
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. With no explicit axis, a secondmate re-resolves its
#              durable config/secondmate-harness pin (harness plus its optional
#              model and effort tokens) exactly as any other respawn does, while
#              a ship or scout keeps the exact adapter already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)

# ---------------------------------------------------------------------------
# CONVERSION NOTES - deliberately BELOW the blank line above, which is what
# ends the block the usage path prints, exactly as `set -eu` ends the bash
# twin's. Nothing from here down reaches --help.
#
# Twin: bin/fm-control.sh
#
# THE HEADER IS THE HELP, IN BOTH LANGUAGES. The bash twin prints it with
# `sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'` - from line 2 (past the
# shebang) until the first non-comment line. This twin re-reads its OWN lines
# from the first one, because a PowerShell script has no shebang to skip, and
# stops at the same place: the blank line above. The ONE token that differs is
# the program's own name (`fm-control.ps1` for `fm-control.sh`), the same
# single-token divergence bin/fm-startup-memory-budget.ps1 documents. Sibling
# scripts keep the spelling the oracle prints, because the help describes an
# architecture both trees share and docs/agent-control.md names those files.
# The Usage block's continuation lines keep the ORACLE's indentation rather
# than being realigned under the one-byte-longer name: realigning would be an
# improvement on the oracle, and it would make the help differ in TWO ways
# instead of one, so a differential normalizer needs exactly one rule.
#
# FIVE MECHANICS THE BASH TWIN GETS FROM ITS SHELL
#
#   1. `die` IS AN EXIT, ALWAYS. Several `die` calls sit inside command
#      substitutions - `cancel=$(deliver_interrupt)`, `proof=$(do_interrupt)` -
#      so they exit a SUBSHELL, whose non-zero status then aborts the parent
#      under `set -e`. The observable result is identical either way: the
#      message on stderr and exit 1 with the EXIT trap run. So this twin exits
#      directly, and no call site has to model the subshell.
#
#   2. THE EXIT TRAP COVERS A REFUSAL RAISED ANYWHERE BELOW THE LOCK, which is
#      why `control_cleanup` is an EXIT trap rather than an explicit call at
#      each return. `exit` unwinds through `finally` in PowerShell, so the whole
#      locked region sits in one try/finally and the rollback plus lock release
#      happen on every path.
#
#   3. THE ROLLBACK IS PART OF THE TRANSACTION, NOT OF THE HAPPY PATH.
#      `relaunch_rollback` runs from the trap and reads the phase the journal
#      last recorded, so a failure deep inside a shared helper still leaves
#      either the pre-relaunch durable record or a concrete, named partial
#      state. bash guards it with `declare -F`; here the function always exists
#      and RelaunchActive alone decides, which is the same condition.
#
#   4. awk IS THE FLOAT COMPARATOR, and its numeric coercion is load-bearing:
#      a non-numeric FM_CONTROL_* value reads as 0, which turns the
#      corresponding wait into a single-shot check rather than an error. That
#      coercion is reproduced (Get-FmControlNumber) instead of "validated",
#      because a captain who exports a typo must get the twin's behavior.
#      `elapsed` also keeps awk's `printf "%.3f"` rounding at every step, so the
#      loop runs the same number of times in both worlds.
#
#   5. `$(cmd 2>/dev/null || true)` CAPTURES STDOUT REGARDLESS OF STATUS. The
#      `|| true` protects the caller from `set -e`; it does not blank the
#      output. So every such call here takes StdOut whether or not the child
#      succeeded, and only trailing newlines are stripped - command
#      substitution's own rule.
#
# DOCUMENTED DIVERGENCES
#
#   THE RELAUNCH LAUNCH CHILD'S STREAMS. bash runs `fm-spawn.sh ... >/dev/null`
#   with stderr inherited, so the launch owner's diagnostics reach the terminal
#   live. Invoke-FmScript either captures BOTH streams or inherits both, so this
#   twin captures and re-emits stderr through Write-FmErr: the same bytes on the
#   same stream, buffered until the child exits rather than interleaved.
#
#   SIGNALS. bash's EXIT trap also fires on HUP/TERM; Windows has neither, so a
#   killed process cannot run the rollback. The durable journal is what makes
#   that recoverable in both worlds, and it is written BEFORE each transition
#   precisely so an unclean death is reconcilable from disk.
#
#   `sleep <non-numeric>` FAILS IN BASH and would abort the loop; an
#   unparseable poll interval is treated as no sleep here rather than
#   fabricating that failure, which is the same direction mechanic 4 takes.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only the two the bash twin sources BEFORE its home checks. The other five are
# imported further down, at the exact point the twin sources them, because that
# ordering is OBSERVABLE - see the note at the deferred import.
#
# NOT -Force: a nested -Force import REMOVES the loaded module globally and
# strips its commands from every session state that had imported it, and
# fm-wake-lib additionally snapshots its context at import time
# (docs/powershell-port.md).
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-gate-refuse-lib.psm1')

# No param() block, and $args captured here: see bin/fm-operational-input.ps1.
$fmArgv = @($args)
$fmSelf = $PSCommandPath

# --- the bash globals, one for one ------------------------------------------
$script:CtlState = ''
$script:CtlData = ''
$script:CtlId = ''
$script:CtlMeta = ''
$script:CtlBackend = ''
$script:CtlTarget = ''
$script:CtlLabel = ''
$script:CtlHarness = ''
$script:CtlRecordedHarness = ''
$script:CtlKind = ''
$script:CtlWorktree = ''

$script:CtlPoll = '0.5'
$script:CtlSettleWait = '5'
$script:CtlExitWait = '30'
$script:CtlLaunchWait = '90'
$script:CtlExitRetries = '3'

$script:CtlControlLock = ''
$script:CtlControlLockHeld = $false
$script:CtlRelaunchActive = $false
$script:CtlRelaunchPhase = 'start'

$script:CtlInterruptAckSource = ''
$script:CtlInterruptAckLog = ''
$script:CtlInterruptAckRun = ''

$script:CtlJournal = ''
$script:CtlMetaPrior = ''
$script:CtlBriefPrior = ''
$script:CtlNoteFile = ''
$script:CtlRelaunchMetaPublished = $false
$script:CtlRelaunchAgentConfirmed = $false
$script:CtlRelaunchTx = ''
$script:CtlRelaunchBrief = ''
$script:CtlPriorHarness = ''
$script:CtlPriorRecordedHarness = ''
$script:CtlPriorModel = ''
$script:CtlPriorEffort = ''
$script:CtlTargetHarness = ''
$script:CtlTargetModel = ''
$script:CtlTargetEffort = ''
$script:CtlCheckpointLines = @()

$script:CtlNote = ''
$script:CtlNoteSet = $false
$script:CtlHarnessSet = $false
$script:CtlModelSet = $false
$script:CtlEffortSet = $false
$script:CtlNewHarness = ''
$script:CtlNewModel = ''
$script:CtlNewEffort = ''

# --- usage ------------------------------------------------------------------

<#
.SYNOPSIS
The leading comment block, ending at the first non-comment line.
.DESCRIPTION
`sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'` - the whole header with
one optional space after the marker removed. Reading from index 0 rather than 1
is the shebang difference and nothing more.
#>
function Get-FmControlUsage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmFileLines $fmSelf)) {
        if (-not $line.StartsWith('#', [System.StringComparison]::Ordinal)) { break }
        $out.Add(($line -replace '^# ?', ''))
    }
    return , @($out.ToArray())
}

function Write-FmControlUsage {
    [CmdletBinding()]
    param([switch]$ToError)
    foreach ($line in (Get-FmControlUsage)) {
        if ($ToError) { Write-FmErr $line } else { Write-FmOut $line }
    }
}

# --- reporters --------------------------------------------------------------

<#
.SYNOPSIS
`die`: one "error: <message>" line on stderr, then exit 1.
.DESCRIPTION
See mechanic 1: every bash `die` ends the process with 1, including the ones
nested inside a command substitution, so this exits directly. The EXIT trap
equivalent (the try/finally around the locked region) still runs.
#>
function Exit-FmControlError {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message)
    Write-FmErr "error: $Message"
    Exit-FmScript 1
}

# --- numeric helpers --------------------------------------------------------

<#
.SYNOPSIS
awk's numeric coercion for a seconds knob: a non-numeric value is 0.
#>
function Get-FmControlNumber {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value = '')

    [double]$parsed = 0
    if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return [double]0
}

<#
.SYNOPSIS
One `elapsed=$(awk 'BEGIN{printf "%.3f", e + p}')` step, rounding included.
#>
function Get-FmControlNextElapsed {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Position = 0)][double]$Elapsed,
        [Parameter(Position = 1)][double]$Poll
    )
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return [double]::Parse((($Elapsed + $Poll).ToString('F3', $invariant)), $invariant)
}

# --- cleanup ----------------------------------------------------------------

function Invoke-FmControlCleanup {
    [CmdletBinding()]
    param()

    if ($script:CtlRelaunchActive) {
        try { Invoke-FmControlRelaunchRollback } catch { $null = $_ }
    }
    if ($script:CtlControlLockHeld) {
        $script:CtlControlLockHeld = $false
        try { Unlock-FmLock -LockPath $script:CtlControlLock } catch { $null = $_ }
    }
}

# --- shared helpers ---------------------------------------------------------

function Get-FmControlAgentState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string](Get-FmBackendAgentState $script:CtlBackend $script:CtlTarget)
}

function Get-FmControlBusyVerdict {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string](Get-FmBusyMetaClassification $script:CtlMeta $script:CtlId $script:CtlState)
}

<#
.SYNOPSIS
Poll until the agent state is one of <Wanted>, or the timeout expires.
.DESCRIPTION
Twin of wait_agent_state, which prints the final observed state and returns 0
only on a match. Returned as @{ State; Ok } because PowerShell has one channel.
The state is read BEFORE the first sleep, so a timeout of 0 is one immediate
check - exactly what `awk 'BEGIN{exit !(0 < 0)}'` produces.
#>
function Wait-FmControlAgentState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Timeout,
        [Parameter(Mandatory, Position = 1)][string[]]$Wanted
    )

    $limit = Get-FmControlNumber $Timeout
    $poll = Get-FmControlNumber $script:CtlPoll
    [double]$elapsed = 0
    $state = ''
    while ($true) {
        $state = Get-FmControlAgentState
        foreach ($want in $Wanted) {
            if ($state -ceq $want) { return @{ State = $state; Ok = $true } }
        }
        if (-not ($elapsed -lt $limit)) { break }
        if ($poll -gt 0) { Start-Sleep -Seconds $poll }
        $elapsed = Get-FmControlNextElapsed $elapsed $poll
    }
    return @{ State = $state; Ok = $false }
}

function Assert-FmControlStateVerifiedBackend {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Verb)

    if (Test-FmControlBackendStateVerified $script:CtlBackend) { return }
    Exit-FmControlError ("task $($script:CtlId) runs on the $($script:CtlBackend) backend, which has no " +
        "recovery-grade agent-state classifier, so '$Verb' cannot prove the agent actually stopped; " +
        'refusing rather than reporting an unproven transition as done')
}

<#
.SYNOPSIS
Deliver the harness's interrupt key the verified number of times, then the
composer-clear key when the adapter needs one.
.DESCRIPTION
Twin of send_interrupt_keys. Refuses BEFORE sending anything when the backend
cannot deliver either key, because an interrupt that cancels the turn but leaves
the restored prompt in the composer would make the next submitted line
concatenate onto it.
#>
function Send-FmControlInterruptKey {
    [CmdletBinding()]
    param()

    $key = Get-FmControlInterruptKey $script:CtlHarness
    $repeat = Get-FmControlInterruptRepeat $script:CtlHarness
    $clear = Get-FmControlInterruptClearKey $script:CtlHarness
    if (-not (Test-FmControlBackendSupportsKey $script:CtlBackend $key)) {
        Exit-FmControlError ("harness $($script:CtlHarness) interrupts with $key, which the " +
            "$($script:CtlBackend) backend cannot deliver; refusing to send a different key")
    }
    if (-not [string]::IsNullOrEmpty($clear) -and
        -not (Test-FmControlBackendSupportsKey $script:CtlBackend $clear)) {
        Exit-FmControlError ("harness $($script:CtlHarness) needs $clear to clear its composer after an " +
            "interrupt, which the $($script:CtlBackend) backend cannot deliver; refusing to leave the " +
            'cancelled prompt where the next submitted line would concatenate onto it')
    }
    $i = 0
    while ($i -lt $repeat) {
        if (-not (Send-FmBackendKey -Backend $script:CtlBackend -Target $script:CtlTarget -Key $key `
                    -ExpectedLabel $script:CtlLabel)) {
            Exit-FmControlError ("interrupt key $key was not delivered to task $($script:CtlId) on " +
                "$($script:CtlBackend)")
        }
        $i++
        if ($i -lt $repeat) { Start-Sleep -Seconds 0.2 }
    }
    if (-not [string]::IsNullOrEmpty($clear)) {
        if (-not (Send-FmBackendKey -Backend $script:CtlBackend -Target $script:CtlTarget -Key $clear `
                    -ExpectedLabel $script:CtlLabel)) {
            Exit-FmControlError ("interrupt key $key reached task $($script:CtlId), but $clear did not, " +
                'so its composer still holds the cancelled prompt; clear it before the next lifecycle action')
        }
    }
}

function Initialize-FmControlInterruptAck {
    [CmdletBinding()]
    param()

    $source = Get-FmControlInterruptAckSource $script:CtlHarness
    if ($null -eq $source) { $source = '' }
    $script:CtlInterruptAckSource = $source
    $script:CtlInterruptAckLog = ''
    $script:CtlInterruptAckRun = ''
    if ($script:CtlInterruptAckSource -cne 'muse-session-terminal') { return }

    $log = ''
    try { $log = [string](Get-FmBusyMuseSessionLog $script:CtlState $script:CtlId) } catch { $log = '' }
    if ([string]::IsNullOrEmpty($log)) { return }
    $script:CtlInterruptAckLog = $log
    $run = ''
    try { $run = [string](Get-FmBusyMuseActiveRunId $log) } catch { $run = '' }
    $script:CtlInterruptAckRun = $run
}

<#
.SYNOPSIS
The strongest adapter-owned cancellation claim available: 'confirmed' or
'unconfirmed'.
.DESCRIPTION
Twin of interrupt_cancel_claim. Only a muse run whose terminal disposition reads
exactly `cancelled` confirms; any OTHER terminal value is a settled run that was
not cancelled, so it answers unconfirmed immediately rather than waiting out the
settle window.
#>
function Get-FmControlCancelClaim {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:CtlInterruptAckSource -cne 'muse-session-terminal' -or
        [string]::IsNullOrEmpty($script:CtlInterruptAckRun)) {
        return 'unconfirmed'
    }

    $limit = Get-FmControlNumber $script:CtlSettleWait
    $poll = Get-FmControlNumber $script:CtlPoll
    [double]$elapsed = 0
    while ($true) {
        $terminal = ''
        try {
            $terminal = [string](Get-FmBusyMuseRunTerminal $script:CtlInterruptAckLog $script:CtlInterruptAckRun)
        } catch {
            $terminal = ''
        }
        if ($terminal -ceq 'cancelled') { return 'confirmed' }
        if (-not [string]::IsNullOrEmpty($terminal)) { return 'unconfirmed' }
        if (-not ($elapsed -lt $limit)) { break }
        if ($poll -gt 0) { Start-Sleep -Seconds $poll }
        $elapsed = Get-FmControlNextElapsed $elapsed $poll
    }
    return 'unconfirmed'
}

function Invoke-FmControlDeliverInterrupt {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Initialize-FmControlInterruptAck
    Send-FmControlInterruptKey
    return (Get-FmControlCancelClaim)
}

function Get-FmControlInterruptProof {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-FmBackendTargetExists -Backend $script:CtlBackend -Target $script:CtlTarget `
                -ExpectedLabel $script:CtlLabel)) {
        Exit-FmControlError ("task $($script:CtlId)'s endpoint disappeared while interrupting it; " +
            'no further control action is safe')
    }
    $proof = 'endpoint'
    if (Test-FmControlBackendStateVerified $script:CtlBackend) {
        # An interrupt cancels a turn; it must never have stopped the agent.
        # This is the postcondition that separates a landed interrupt from an
        # accident.
        $after = Get-FmControlAgentState
        if ($after -cne 'alive') {
            Exit-FmControlError ("task $($script:CtlId)'s agent is '$after' after its interrupt key; " +
                'an interrupt must leave the agent running')
        }
        $proof = 'agent-alive'
    }
    return $proof
}

function Invoke-FmControlInterrupt {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $cancel = Invoke-FmControlDeliverInterrupt
    $proof = Get-FmControlInterruptProof
    return "$proof cancel=$cancel"
}

function Invoke-FmControlRetireBusy {
    [CmdletBinding()]
    param()

    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath "$($script:CtlState)/$($script:CtlId).busy-gen"))) {
        return
    }
    try {
        $null = Invoke-FmScript -Name 'fm-busy-event' -Arguments @(
            'retire', $script:CtlState, $script:CtlId, '--current-gen')
    } catch {
        # `|| true`: retiring the busy wiring is best effort and never decides
        # whether the agent stopped.
        $null = $_
    }
}

<#
.SYNOPSIS
Stop the running agent, preserving endpoint and worktree. Prints
`already-stopped` or `stopped`.
.DESCRIPTION
Twin of do_exit.
#>
function Invoke-FmControlExit {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $interruptResult = 'not-needed'
    Assert-FmControlStateVerifiedBackend 'exit'
    $state = Get-FmControlAgentState
    switch -CaseSensitive ($state) {
        'dead' { return 'already-stopped' }
        'alive' { }
        'missing' {
            Exit-FmControlError ("task $($script:CtlId)'s recorded endpoint is gone, so there is no agent " +
                'to stop; reconcile the task before any further control action')
        }
        default {
            Exit-FmControlError ("task $($script:CtlId)'s endpoint reads '$state' rather than a positively " +
                'classified state; refusing to send a lifecycle command into an unattributed endpoint')
        }
    }

    # A busy agent is interrupted first before the exit command is submitted.
    if ((Get-FmControlBusyVerdict).StartsWith('busy', [System.StringComparison]::Ordinal)) {
        $cancel = Invoke-FmControlDeliverInterrupt
        $state = Get-FmControlAgentState
        switch -CaseSensitive ($state) {
            'dead' {
                Invoke-FmControlRetireBusy
                return 'stopped'
            }
            'alive' { $interruptResult = "delivered verified=agent-alive cancel=$cancel" }
            'missing' {
                Exit-FmControlError ("task $($script:CtlId)'s recorded endpoint disappeared after interrupt " +
                    'delivery, so exit cannot prove whether the agent stopped')
            }
            default {
                Exit-FmControlError ("task $($script:CtlId)'s endpoint reads '$state' after interrupt " +
                    'delivery rather than a positively classified state; exit cannot prove whether the ' +
                    'agent stopped')
            }
        }
    }

    $cmd = Get-FmControlExitCommand $script:CtlHarness
    # The submit verdict is NOT the postcondition here: a successful exit command
    # destroys the composer the verdict is read from, so a post-exit read can
    # legitimately report anything. Only a hard transport failure aborts; the
    # authoritative proof is the agent-state wait below. The retried Enter still
    # matters, because a slash command opens a completion popup on some TUIs that
    # swallows the first Enter.
    $verdict = Send-FmBackendTextSubmit -Backend $script:CtlBackend -Target $script:CtlTarget -Text $cmd `
        -Retries $script:CtlExitRetries -EnterSleep $script:CtlPoll -Settle '1.2' `
        -ExpectedLabel $script:CtlLabel
    if ($null -eq $verdict) {
        Exit-FmControlError ("the exit command could not be sent to task $($script:CtlId) on " +
            "$($script:CtlBackend)")
    }
    if ($verdict -ceq 'send-failed') {
        Exit-FmControlError ("the exit command could not be sent to task $($script:CtlId) on " +
            "$($script:CtlBackend)")
    }
    $waited = Wait-FmControlAgentState $script:CtlExitWait @('dead')
    if (-not $waited.Ok) {
        Exit-FmControlError ("exit-delivered $($script:CtlId) interrupt=$interruptResult " +
            "exit-command=delivered agent-state=$($waited.State) exit=unconfirmed; the agent did not stop " +
            "within $($script:CtlExitWait)s")
    }
    # The incarnation is over: retire its busy wiring so no stale record or
    # orphaned generation survives the agent that produced it.
    Invoke-FmControlRetireBusy
    return 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# Invoke-FmControlRelaunchRollback (from the cleanup that the try/finally always
# reaches, so a refusal raised deep inside a shared helper is covered too) and
# leaves either the pre-relaunch durable record or a concrete, named partial
# state - never a task whose record claims an agent that is not running.

function Get-FmControlStamp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Format = 'yyyy-MM-ddTHH:mm:ssZ')
    return [DateTime]::UtcNow.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-FmControlJournal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Phase,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Extra = @()
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("v1`n")
    [void]$sb.Append("task=$($script:CtlId)`n")
    [void]$sb.Append("phase=$Phase`n")
    [void]$sb.Append("ts=$(Get-FmControlStamp)`n")
    [void]$sb.Append("backend=$($script:CtlBackend)`n")
    [void]$sb.Append("endpoint=$($script:CtlTarget)`n")
    [void]$sb.Append("worktree=$($script:CtlWorktree)`n")
    [void]$sb.Append("kind=$($script:CtlKind)`n")
    [void]$sb.Append("from_harness=$($script:CtlPriorRecordedHarness)`n")
    [void]$sb.Append("from_model=$($script:CtlPriorModel)`n")
    [void]$sb.Append("from_effort=$($script:CtlPriorEffort)`n")
    [void]$sb.Append("to_harness=$($script:CtlTargetHarness)`n")
    [void]$sb.Append("to_model=$($script:CtlTargetModel)`n")
    [void]$sb.Append("to_effort=$($script:CtlTargetEffort)`n")
    foreach ($line in $Extra) { [void]$sb.Append("$line`n") }

    # `{ ... } > "$JOURNAL.tmp" && mv -f`: the publish is the atomic half, and a
    # failure at either step leaves the phase unchanged.
    if (Set-FmFileTextAtomic -Path $script:CtlJournal -Text $sb.ToString() -NoNewline) {
        $script:CtlRelaunchPhase = $Phase
        return $true
    }
    return $false
}

function Restore-FmControlPriorBrief {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ([string]::IsNullOrEmpty($script:CtlRelaunchBrief)) { return $false }
    $prior = ConvertTo-FmNativePath $script:CtlBriefPrior
    if (-not [System.IO.File]::Exists($prior)) { return $false }
    try {
        [System.IO.File]::Copy($prior, (ConvertTo-FmNativePath $script:CtlRelaunchBrief), $true)
    } catch {
        # `cp -p ... || true`: a failed restore never replaces the diagnostic
        # the rollback is about to print.
        $null = $_
    }
    return $true
}

function Invoke-FmControlRelaunchRollback {
    [CmdletBinding()]
    param()

    if (-not $script:CtlRelaunchActive) { return }
    if ($script:CtlRelaunchPhase -ceq 'complete') { return }
    $script:CtlRelaunchActive = $false

    switch -CaseSensitive ($script:CtlRelaunchPhase) {
        { $_ -ceq 'checkpoint' -or $_ -ceq 'noted' } {
            # The old agent was never touched. Restore the instructions
            # byte-exact so a refused relaunch leaves nothing behind.
            $null = Restore-FmControlPriorBrief
            $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" @('rollback=instructions-restored')
            Write-FmErr ("error: relaunch of $($script:CtlId) was refused before its agent was touched; " +
                'nothing changed')
        }
        'stopping' {
            $state = 'unknown'
            try { $state = Get-FmControlAgentState } catch { $state = 'unknown' }
            switch -CaseSensitive ($state) {
                'alive' {
                    $null = Restore-FmControlPriorBrief
                    $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" `
                        @('rollback=instructions-restored-agent-alive')
                    Write-FmErr ("error: relaunch of $($script:CtlId) failed while stopping the old agent, " +
                        'which is still running; its original instructions were restored')
                }
                'dead' {
                    $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" `
                        @('rollback=prior-record-kept-agent-dead')
                    Write-FmErr ("error: $($script:CtlId)'s agent stopped but relaunch did not reach " +
                        'replacement launch; no agent is running, and its work plus progress note are ' +
                        "preserved at $($script:CtlWorktree)")
                }
                default {
                    $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" `
                        @("rollback=none-agent-state-$state")
                    Write-FmErr ("error: relaunch of $($script:CtlId) failed while stopping the old agent " +
                        "and its state is '$state'; the durable record and progress note were retained " +
                        'for recovery')
                }
            }
        }
        { $_ -ceq 'exited' -or $_ -ceq 'launching' } {
            $published = $script:CtlRelaunchMetaPublished
            if (-not $published -and -not [string]::IsNullOrEmpty($script:CtlRelaunchTx)) {
                $published = ((Get-FmMetaValue $script:CtlMeta 'control_relaunch_tx') -ceq $script:CtlRelaunchTx)
            }
            if ($script:CtlRelaunchAgentConfirmed) {
                $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" `
                    @('rollback=none-new-agent-confirmed')
                Write-FmErr ("error: $($script:CtlId)'s replacement is running on " +
                    "$($script:CtlTargetHarness), but transaction completion could not be persisted; " +
                    'its published record was retained for reconciliation')
            } elseif ($published) {
                # The launch owner published the new incarnation's record.
                # Leaving it in place is the honest state: the task is now
                # recorded on the new harness with no agent confirmed, which is
                # exactly what recovery reconciles. Rewriting it back to the old
                # harness would be a second, worse inaccuracy.
                $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" `
                    @('rollback=none-new-record-kept')
                Write-FmErr ("error: $($script:CtlId) was relaunched on $($script:CtlTargetHarness) but no " +
                    "running agent could be confirmed; its work is preserved at $($script:CtlWorktree)")
            } else {
                $null = Write-FmControlJournal "failed:$($script:CtlRelaunchPhase)" @('rollback=prior-record-kept')
                Write-FmErr ("error: $($script:CtlId)'s agent was stopped but the replacement did not " +
                    'launch; no agent is running, and its work plus the recorded progress note are ' +
                    "preserved at $($script:CtlWorktree)")
            }
        }
    }
}

<#
.SYNOPSIS
`$(cmd 2>/dev/null || true)` over a sibling firstmate script: stdout regardless
of exit status, trailing newlines stripped.
#>
function Get-FmControlScriptValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string[]]$Arguments = @()
    )

    try {
        $result = Invoke-FmScript -Name $Name -Arguments $Arguments
        if ($null -eq $result) { return '' }
        return ([string]$result.StdOut).TrimEnd("`n")
    } catch {
        return ''
    }
}

function Resolve-FmControlRelaunchProfile {
    [CmdletBinding()]
    param()

    $script:CtlPriorHarness = $script:CtlHarness
    $script:CtlPriorRecordedHarness = $script:CtlRecordedHarness
    $script:CtlPriorModel = Get-FmMetaValue $script:CtlMeta 'model'
    $script:CtlPriorEffort = Get-FmMetaValue $script:CtlMeta 'effort'
    if ([string]::IsNullOrEmpty($script:CtlPriorModel)) { $script:CtlPriorModel = 'default' }
    if ([string]::IsNullOrEmpty($script:CtlPriorEffort)) { $script:CtlPriorEffort = 'default' }
    if (-not $script:CtlHarnessSet -and
        $script:CtlPriorRecordedHarness -cne $script:CtlPriorHarness) {
        Exit-FmControlError ("task $($script:CtlId) records harness '$($script:CtlPriorRecordedHarness)', " +
            'whose original launch command cannot be reconstructed from its recorded basename; relaunching ' +
            "without --harness would substitute the canonical adapter '$($script:CtlPriorHarness)' for the " +
            'command actually running. Pass an explicit --harness to choose the replacement runtime ' +
            'deliberately')
    }

    $configHarness = ''
    $configModel = ''
    $configEffort = ''
    if ($script:CtlKind -ceq 'secondmate') {
        # A secondmate's harness, model, and effort are a durable configured pin
        # that every respawn re-resolves (the secondmate-provisioning contract),
        # so a relaunch with no explicit harness picks up a newly configured one
        # instead of freezing whatever this incarnation happens to run. Crewmates
        # and scouts deliberately do NOT resolve config here: their harness comes
        # from firstmate's own dispatch-profile judgment at intake, and silently
        # re-resolving it would bypass that consultation.
        $configHarness = Get-FmControlScriptValue 'fm-harness' @('secondmate')
        $configModel = Get-FmControlScriptValue 'fm-harness' @('secondmate-model')
        $configEffort = Get-FmControlScriptValue 'fm-harness' @('secondmate-effort')
        if (-not [string]::IsNullOrEmpty($configEffort) -and
            $configEffort -cne 'low' -and $configEffort -cne 'medium' -and $configEffort -cne 'high' -and
            $configEffort -cne 'xhigh' -and $configEffort -cne 'max') {
            Write-FmErr ("warning: config/secondmate-harness effort token '$configEffort' is not one of " +
                'low, medium, high, xhigh, max; ignoring')
            $configEffort = ''
        }
    }

    if ($script:CtlHarnessSet) {
        if (-not (Test-FmControlHarnessSupported $script:CtlNewHarness)) {
            Exit-FmControlError ("'$($script:CtlNewHarness)' is not a verified harness; fm-control refuses " +
                'to relaunch onto an adapter with no verified control or launch mechanics')
        }
        $script:CtlTargetHarness = $script:CtlNewHarness
    } elseif (-not [string]::IsNullOrEmpty($configHarness)) {
        if (-not (Test-FmControlHarnessSupported $configHarness)) {
            Exit-FmControlError ("the configured secondmate harness '$configHarness' is not verified; " +
                'fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics')
        }
        $script:CtlTargetHarness = $configHarness
    } else {
        $script:CtlTargetHarness = $script:CtlPriorHarness
    }

    # The launch owner refuses an adapter that cannot run this task's kind, but
    # it is only reached after the old agent has been stopped. Asking the same
    # capability table here keeps that refusal on the pre-stop side of the
    # transaction, where nothing has changed yet.
    if (-not (Test-FmControlHarnessSupportsKind $script:CtlTargetHarness $script:CtlKind)) {
        Exit-FmControlError ("'$($script:CtlTargetHarness)' is not verified to run a $($script:CtlKind) " +
            "task, so relaunching $($script:CtlId) onto it would stop the running agent for a launch that " +
            'must be refused; choose an adapter verified for this kind')
    }

    # A model or effort chosen for the previous harness does not transfer to a
    # different one, so an explicit harness change resets both axes unless the
    # caller names them too.
    if ($script:CtlModelSet) {
        $script:CtlTargetModel = $script:CtlNewModel
    } elseif (-not $script:CtlHarnessSet -and -not [string]::IsNullOrEmpty($configHarness)) {
        $script:CtlTargetModel = if ([string]::IsNullOrEmpty($configModel)) { 'default' } else { $configModel }
    } elseif ($script:CtlTargetHarness -ceq $script:CtlPriorHarness) {
        $script:CtlTargetModel = $script:CtlPriorModel
    } else {
        $script:CtlTargetModel = 'default'
    }
    if ($script:CtlEffortSet) {
        $script:CtlTargetEffort = $script:CtlNewEffort
    } elseif (-not $script:CtlHarnessSet -and -not [string]::IsNullOrEmpty($configHarness)) {
        $script:CtlTargetEffort = if ([string]::IsNullOrEmpty($configEffort)) { 'default' } else { $configEffort }
    } elseif ($script:CtlTargetHarness -ceq $script:CtlPriorHarness) {
        $script:CtlTargetEffort = $script:CtlPriorEffort
    } else {
        $script:CtlTargetEffort = 'default'
    }
}

<#
.SYNOPSIS
`cd "$p" && pwd -P`: the absolute path with every reparse point resolved, or ''
when the path cannot be reached at all.
#>
function Get-FmControlRealPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return '' }
    try {
        $item = Get-Item -LiteralPath (ConvertTo-FmNativePath $Path) -Force -ErrorAction Stop
        $resolved = $item.ResolveLinkTarget($true)
        if ($null -ne $resolved) { return $resolved.FullName }
        return $item.FullName
    } catch {
        return ''
    }
}

<#
.SYNOPSIS
git in the recorded worktree, with the two streams kept apart.
#>
function Invoke-FmControlGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string[]]$GitArgs)
    return (Invoke-FmTool -FilePath 'git' `
            -Arguments (@('-C', (ConvertTo-FmNativePath $script:CtlWorktree)) + $GitArgs))
}

<#
.SYNOPSIS
Prove, before anything is stopped, that the work a relaunch must preserve is
actually there and recoverable afterwards.
.DESCRIPTION
Twin of safe_checkpoint. Fills CtlCheckpointLines with the journal lines
describing what it proved, and refuses outright when any of it cannot be
established.
#>
function Invoke-FmControlSafeCheckpoint {
    [CmdletBinding()]
    param()

    $script:CtlCheckpointLines = @()
    $wt = $script:CtlWorktree
    if ([string]::IsNullOrEmpty($wt)) {
        Exit-FmControlError ("task $($script:CtlId) has no recorded worktree; refusing to relaunch without " +
            'a recorded local copy to preserve')
    }
    $wtNative = ConvertTo-FmNativePath $wt
    if (-not [System.IO.Directory]::Exists($wtNative)) {
        Exit-FmControlError ("task $($script:CtlId)'s recorded worktree $wt is missing; refusing to " +
            'relaunch and lose track of its work')
    }
    $wtReal = Get-FmControlRealPath $wt
    if ([string]::IsNullOrEmpty($wtReal)) {
        Exit-FmControlError "task $($script:CtlId)'s recorded worktree $wt cannot be resolved"
    }

    $topResult = Invoke-FmControlGit @('rev-parse', '--show-toplevel')
    if (-not $topResult.Ok) {
        Exit-FmControlError ("task $($script:CtlId)'s recorded worktree $wt is not a git worktree; " +
            'refusing to relaunch without a checkout whose unlanded work can be accounted for')
    }
    $wtTop = ([string]$topResult.StdOut).TrimEnd("`n")
    # `wt_top_real=$(cd "$wt_top" && pwd -P) || wt_top_real=$wt_top`: an
    # unreachable toplevel falls back to the reported path rather than refusing.
    $wtTopReal = Get-FmControlRealPath $wtTop
    if ([string]::IsNullOrEmpty($wtTopReal)) { $wtTopReal = $wtTop }
    if (-not (Test-FmSamePath $wtReal $wtTopReal)) {
        Exit-FmControlError ("task $($script:CtlId)'s recorded worktree $wt is not a worktree root " +
            "(root is $wtTop); refusing to relaunch against an ambiguous checkout")
    }

    $head = ''
    $headResult = Invoke-FmControlGit @('rev-parse', '--verify', 'HEAD')
    if ($headResult.Ok) {
        $head = ([string]$headResult.StdOut).TrimEnd("`n")
    } else {
        $symResult = Invoke-FmControlGit @('symbolic-ref', '-q', 'HEAD')
        if ($symResult.Ok) {
            $headRef = ([string]$symResult.StdOut).TrimEnd("`n")
            $showRef = Invoke-FmControlGit @('show-ref', '--verify', '--quiet', $headRef)
            if ($showRef.Ok) {
                Exit-FmControlError ("task $($script:CtlId)'s worktree HEAD exists but cannot be resolved; " +
                    'refusing to relaunch from an unreadable checkout')
            }
            # `$?` inside the else branch is show-ref's status: 1 means the ref
            # is simply absent (an unborn branch), anything else is an error.
            if ($showRef.ExitCode -ne 1) {
                Exit-FmControlError ("task $($script:CtlId)'s worktree HEAD cannot be inspected; refusing " +
                    'to relaunch from an unreadable checkout')
            }
            $head = 'unborn'
        } else {
            Exit-FmControlError ("task $($script:CtlId)'s worktree HEAD cannot be inspected; refusing to " +
                'relaunch from an unreadable checkout')
        }
    }

    $statusResult = Invoke-FmControlGit @('status', '--porcelain')
    if (-not $statusResult.Ok) {
        Exit-FmControlError ("task $($script:CtlId)'s worktree status cannot be inspected; refusing to " +
            'relaunch without accounting for local changes')
    }
    # `$(...)` strips trailing newlines, so a clean tree is the EMPTY string.
    $statusOutput = ([string]$statusResult.StdOut).TrimEnd("`n")
    $dirty = if ([string]::IsNullOrEmpty($statusOutput)) { 'no' } else { 'yes' }
    $script:CtlCheckpointLines = @("worktree_head=$head", "worktree_dirty=$dirty")

    if ($script:CtlKind -cne 'secondmate') { return }

    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child work
    # behind an unreadable home.
    $marker = (Get-FmFileText "$wt/.fm-secondmate-home").TrimEnd("`n")
    if ($marker -cne $script:CtlId) {
        $shown = if ([string]::IsNullOrEmpty($marker)) { 'none' } else { $marker }
        Exit-FmControlError ("task $($script:CtlId)'s home $wt is not marked as its own seeded secondmate " +
            "home (marker: $shown); refusing to relaunch")
    }
    $childState = "$wt/state"
    $childStateNative = ConvertTo-FmNativePath $childState
    if (-not [System.IO.Directory]::Exists($childStateNative)) {
        Exit-FmControlError ("secondmate $($script:CtlId)'s home has no readable state directory, so its " +
            'child work cannot be accounted for; refusing to relaunch')
    }
    try {
        $null = @([System.IO.Directory]::EnumerateFileSystemEntries($childStateNative))
    } catch {
        Exit-FmControlError ("secondmate $($script:CtlId)'s child records cannot be traversed; refusing " +
            'to relaunch')
    }
    $children = 0
    foreach ($childMeta in @([System.IO.Directory]::EnumerateFileSystemEntries($childStateNative, '*.meta'))) {
        # The bash loop skips a glob that matched nothing; an enumeration simply
        # yields no entries, which is the same state.
        if (-not [System.IO.File]::Exists($childMeta) -or (Test-FmSymlink $childMeta)) {
            Exit-FmControlError ("secondmate $($script:CtlId)'s child record $childMeta is not a readable " +
                'regular file; refusing to relaunch')
        }
        try {
            $stream = [System.IO.File]::OpenRead($childMeta)
            $stream.Dispose()
        } catch {
            Exit-FmControlError ("secondmate $($script:CtlId)'s child record $childMeta is not a readable " +
                'regular file; refusing to relaunch')
        }
        $children++
    }
    $script:CtlCheckpointLines = @($script:CtlCheckpointLines) + @("children=$children")
}

<#
.SYNOPSIS
Put the required progress note somewhere durable, and into the instructions the
replacement actually reads.
.DESCRIPTION
Twin of record_note. For a ship or scout - whose only record of the interrupted
reasoning is the conversation about to be discarded - the note is appended to
the brief. A secondmate's charter is a durable standing document and is never
rewritten: a secondmate reconciles its own home's records at startup, so the
note stays parent-side audit evidence.
#>
function Write-FmControlNote {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrEmpty($script:CtlNote)) { return }
    $stamp = Get-FmControlStamp
    # `printf '%s\n' "$NOTE"`: exactly one terminator, whatever the note ends in.
    Set-FmFileText -Path $script:CtlNoteFile -Text ($script:CtlNote + "`n") -NoNewline
    if ($script:CtlKind -cne 'ship' -and $script:CtlKind -cne 'scout') { return }

    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath $script:CtlRelaunchBrief),
            (ConvertTo-FmNativePath $script:CtlBriefPrior), $true)
    } catch {
        Exit-FmControlError ("could not preserve task $($script:CtlId)'s instructions before recording " +
            'the progress note')
    }
    try {
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line ''
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line "## Progress note ($stamp)"
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line ''
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line `
            'This task was relaunched. Continue from here; the local copy and every'
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line `
            'uncommitted change are exactly as the previous worker left them.'
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line ''
        Add-FmFileLine -Path $script:CtlRelaunchBrief -Line $script:CtlNote
    } catch {
        Exit-FmControlError "could not append the progress note to task $($script:CtlId)'s instructions"
    }
}

function Invoke-FmControlRelaunch {
    [CmdletBinding()]
    param()

    Assert-FmControlStateVerifiedBackend 'relaunch'
    Resolve-FmControlRelaunchProfile

    if ($script:CtlKind -ceq 'ship' -or $script:CtlKind -ceq 'scout') {
        $script:CtlRelaunchBrief = "$($script:CtlData)/$($script:CtlId)/brief.md"
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $script:CtlRelaunchBrief))) {
            Exit-FmControlError ("task $($script:CtlId) has no instructions at " +
                "$($script:CtlRelaunchBrief); refusing to relaunch a worker with nothing to work from")
        }
        if (-not $script:CtlNoteSet -or [string]::IsNullOrEmpty($script:CtlNote)) {
            Exit-FmControlError ("relaunch of a $($script:CtlKind) task requires --note (or --note-file): " +
                'the replacement worker inherits the local copy but none of the conversation, so it must ' +
                'be told what happened')
        }
    } elseif ($script:CtlKind -ceq 'secondmate') {
        # The charter in the secondmate's own home is its instruction source and
        # stays untouched.
        $script:CtlRelaunchBrief = ''
    } else {
        Exit-FmControlError ("task $($script:CtlId) records kind '$($script:CtlKind)', which has no " +
            'defined relaunch shape')
    }

    $noteLine = if ([string]::IsNullOrEmpty($script:CtlNote)) {
        'note=none'
    } else {
        "note_file=$($script:CtlNoteFile)"
    }
    Invoke-FmControlSafeCheckpoint
    try {
        [System.IO.File]::Copy((ConvertTo-FmNativePath $script:CtlMeta),
            (ConvertTo-FmNativePath $script:CtlMetaPrior), $true)
    } catch {
        Exit-FmControlError ("could not preserve task $($script:CtlId)'s durable record before relaunching")
    }
    $script:CtlRelaunchActive = $true
    $null = Write-FmControlJournal 'checkpoint' (@($script:CtlCheckpointLines) + @($noteLine))

    Write-FmControlNote
    $null = Write-FmControlJournal 'noted' (@($script:CtlCheckpointLines) + @($noteLine))

    $null = Write-FmControlJournal 'stopping' (@($script:CtlCheckpointLines) + @($noteLine))
    $exitResult = Invoke-FmControlExit
    $null = Write-FmControlJournal 'exited' `
        (@($script:CtlCheckpointLines) + @($noteLine, "exit_result=$exitResult"))

    # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
    # per-task harness wiring before arming the new one, so nothing to do here.
    $script:CtlRelaunchTx = "$PID.$(Get-FmControlStamp 'yyyyMMddTHHmmssZ').$(Get-Random -Minimum 0 -Maximum 32768)"
    $null = Write-FmControlJournal 'launching' `
        (@($script:CtlCheckpointLines) + @($noteLine, "relaunch_tx=$($script:CtlRelaunchTx)"))

    $spawnArgs = [System.Collections.Generic.List[string]]::new()
    $spawnArgs.Add($script:CtlId)
    $spawnArgs.Add('--relaunch')
    $spawnArgs.Add('--harness')
    $spawnArgs.Add($script:CtlTargetHarness)
    if ($script:CtlTargetModel -cne 'default') {
        $spawnArgs.Add('--model'); $spawnArgs.Add($script:CtlTargetModel)
    }
    if ($script:CtlTargetEffort -cne 'default') {
        $spawnArgs.Add('--effort'); $spawnArgs.Add($script:CtlTargetEffort)
    }

    # One-command prefix assignment: restored afterwards rather than leaked.
    $priorTx = [Environment]::GetEnvironmentVariable('FM_CONTROL_RELAUNCH_TX')
    $spawn = $null
    try {
        [Environment]::SetEnvironmentVariable('FM_CONTROL_RELAUNCH_TX', $script:CtlRelaunchTx)
        $spawn = Invoke-FmScript -Name 'fm-spawn' -Arguments $spawnArgs.ToArray()
    } finally {
        [Environment]::SetEnvironmentVariable('FM_CONTROL_RELAUNCH_TX', $priorTx)
    }
    # `>/dev/null` with stderr inherited: the launch owner's diagnostics are the
    # captain's, its stdout is not (see the divergence note in the header).
    if ($null -ne $spawn -and -not [string]::IsNullOrEmpty([string]$spawn.StdErr)) {
        foreach ($line in (([string]$spawn.StdErr).TrimEnd("`n") -split "`n")) { Write-FmErr $line }
    }
    if ($null -ne $spawn -and $spawn.Ok) {
        $script:CtlRelaunchMetaPublished = $true
    } else {
        if ((Get-FmMetaValue $script:CtlMeta 'control_relaunch_tx') -ceq $script:CtlRelaunchTx) {
            $script:CtlRelaunchMetaPublished = $true
        }
        Exit-FmControlError ("the replacement agent for $($script:CtlId) could not be launched on " +
            "$($script:CtlTargetHarness)")
    }

    $waited = Wait-FmControlAgentState $script:CtlLaunchWait @('alive')
    if (-not $waited.Ok) {
        Exit-FmControlError ("the replacement agent for $($script:CtlId) did not come up within " +
            "$($script:CtlLaunchWait)s (endpoint reads '$($waited.State)')")
    }
    $script:CtlRelaunchAgentConfirmed = $true

    $null = Write-FmControlJournal 'complete' `
        (@($script:CtlCheckpointLines) + @($noteLine, "exit_result=$exitResult"))
    $script:CtlRelaunchActive = $false
    Write-FmOut ("relaunched $($script:CtlId) harness=$($script:CtlTargetHarness) " +
        "from=$($script:CtlPriorRecordedHarness) model=$($script:CtlTargetModel) " +
        "effort=$($script:CtlTargetEffort) backend=$($script:CtlBackend) endpoint=$($script:CtlTarget) " +
        "worktree=$($script:CtlWorktree)")
}

# --- main -------------------------------------------------------------------

Invoke-FmMain -UnexpectedCode 70 {
    if ($fmArgv.Count -ge 1) {
        $first = [string]$fmArgv[0]
        if ($first -ceq '-h' -or $first -ceq '--help') {
            Write-FmControlUsage
            Exit-FmScript 0
        }
    }

    # Fail closed before any fleet mutation: a no-mistakes gate agent must never
    # drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.psm1).
    Assert-FmNotGateAgent

    # `${FM_HOME+x}` / `${FM_HOME:-}`: unset and set-but-empty both refuse, so a
    # lifecycle command can never silently resolve against another home.
    $fmHome = [Environment]::GetEnvironmentVariable('FM_HOME')
    if ($null -eq $fmHome -or $fmHome -eq '') {
        Write-FmErr ('error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit ' +
            'firstmate home')
        Exit-FmScript 1
    }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $fmHome))) {
        Write-FmErr "error: FM_HOME '$fmHome' is not a directory"
        Exit-FmScript 1
    }
    # Paths keep the caller's spelling: every diagnostic below embeds them, and
    # the bash twins print the MSYS form.
    $script:CtlState = Get-FmEnv -Name 'FM_STATE_OVERRIDE' -Default "$fmHome/state"
    $script:CtlData = Get-FmEnv -Name 'FM_DATA_OVERRIDE' -Default "$fmHome/data"
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $script:CtlState))) {
        Write-FmErr ("error: state dir '$($script:CtlState)' is missing; fm-control cannot resolve tasks " +
            "for FM_HOME '$fmHome'")
        Exit-FmScript 1
    }

    # THE REMAINING LIBRARIES LOAD HERE, NOT AT THE TOP, AND THE PLACEMENT IS A
    # BEHAVIOR CONTRACT.
    #
    # bin/fm-wake-lib runs `mkdir -p "$STATE"` at LOAD time in both languages.
    # The bash twin sources it AFTER the two refusals above, so a home that does
    # not exist - or whose state dir is missing - is refused with nothing
    # created. PowerShell's conventional top-of-file Import-Module would run
    # that mkdir FIRST, which silently CREATES the missing directory and then
    # walks straight past both refusals into "no task '<id>' in <state>".
    # Measured exactly that way on this host before the imports were moved: the
    # two twins disagreed on the message, and the PowerShell side left a
    # directory tree behind in a home it was supposed to refuse.
    #
    # So these five sit where their `.` lines sit in the twin. Import-Module is
    # a statement, not a declaration; the commands land in the script's session
    # state and every function defined above resolves them at CALL time, which
    # is verified on this host under both `pwsh -File` and a `& script` driver.
    Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
    Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1')
    Import-Module (Join-Path $PSScriptRoot 'fm-control-lib.psm1')
    Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1')
    Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

    $script:CtlPoll = Get-FmEnv -Name 'FM_CONTROL_POLL' -Default '0.5'
    $script:CtlSettleWait = Get-FmEnv -Name 'FM_CONTROL_SETTLE_WAIT' -Default '5'
    $script:CtlExitWait = Get-FmEnv -Name 'FM_CONTROL_EXIT_WAIT' -Default '30'
    $script:CtlLaunchWait = Get-FmEnv -Name 'FM_CONTROL_LAUNCH_WAIT' -Default '90'
    $script:CtlExitRetries = Get-FmEnv -Name 'FM_CONTROL_EXIT_RETRIES' -Default '3'

    # --- argument parsing ---------------------------------------------------

    $rawId = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    $verb = if ($fmArgv.Count -ge 2) { [string]$fmArgv[1] } else { '' }
    if ([string]::IsNullOrEmpty($rawId) -or [string]::IsNullOrEmpty($verb)) {
        Write-FmControlUsage -ToError
        Exit-FmScript 2
    }
    $rest = @($fmArgv | Select-Object -Skip 2)

    if (-not (Test-FmControlVerbAllowed $verb)) {
        if ($verb -ceq 'resume') {
            Write-FmErr ("error: 'resume' is not a control verb: resuming an exited agent is not " +
                'deterministic across the verified adapters (codex and grok need a session id printed at ' +
                'exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, ' +
                "and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief " +
                'plus a progress note into a fresh agent on any adapter.')
        } else {
            Write-FmErr "error: '$verb' is not a control verb"
        }
        Write-FmErr 'allowed verbs:'
        foreach ($allowed in (Get-FmControlVerb)) { Write-FmErr "  $allowed" }
        Exit-FmScript 2
    }

    $wantValue = ''
    foreach ($rawArg in $rest) {
        $a = [string]$rawArg
        if ($wantValue -ne '') {
            if ($a.StartsWith('--', [System.StringComparison]::Ordinal)) {
                Exit-FmControlError "--$wantValue requires a value"
            }
            switch -CaseSensitive ($wantValue) {
                'harness' { $script:CtlNewHarness = $a; $script:CtlHarnessSet = $true }
                'model' { $script:CtlNewModel = $a; $script:CtlModelSet = $true }
                'effort' { $script:CtlNewEffort = $a; $script:CtlEffortSet = $true }
                'note' { $script:CtlNote = $a; $script:CtlNoteSet = $true }
                'note-file' {
                    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $a))) {
                        Exit-FmControlError "--note-file '$a' is not a readable file"
                    }
                    # `$(cat f)` strips trailing newlines.
                    $script:CtlNote = (Get-FmFileText $a).TrimEnd("`n")
                    $script:CtlNoteSet = $true
                }
            }
            $wantValue = ''
            continue
        }
        if ($a -ceq '--harness') { $wantValue = 'harness' }
        elseif ($a.StartsWith('--harness=', [System.StringComparison]::Ordinal)) {
            $script:CtlNewHarness = $a.Substring(10); $script:CtlHarnessSet = $true
        } elseif ($a -ceq '--model') { $wantValue = 'model' }
        elseif ($a.StartsWith('--model=', [System.StringComparison]::Ordinal)) {
            $script:CtlNewModel = $a.Substring(8); $script:CtlModelSet = $true
        } elseif ($a -ceq '--effort') { $wantValue = 'effort' }
        elseif ($a.StartsWith('--effort=', [System.StringComparison]::Ordinal)) {
            $script:CtlNewEffort = $a.Substring(9); $script:CtlEffortSet = $true
        } elseif ($a -ceq '--note') { $wantValue = 'note' }
        elseif ($a.StartsWith('--note=', [System.StringComparison]::Ordinal)) {
            $script:CtlNote = $a.Substring(7); $script:CtlNoteSet = $true
        } elseif ($a -ceq '--note-file') { $wantValue = 'note-file' }
        elseif ($a.StartsWith('--note-file=', [System.StringComparison]::Ordinal)) {
            $value = $a.Substring(12)
            if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $value))) {
                Exit-FmControlError "--note-file '$value' is not a readable file"
            }
            $script:CtlNote = (Get-FmFileText $value).TrimEnd("`n")
            $script:CtlNoteSet = $true
        } else {
            Exit-FmControlError "unexpected argument '$a'"
        }
    }
    if ($wantValue -ne '') { Exit-FmControlError "--$wantValue requires a value" }

    if ($verb -cne 'relaunch') {
        if ($script:CtlHarnessSet -or $script:CtlModelSet -or $script:CtlEffortSet -or $script:CtlNoteSet) {
            Exit-FmControlError "--harness, --model, --effort, and --note apply to 'relaunch' only"
        }
    }
    if ($script:CtlHarnessSet -and [string]::IsNullOrEmpty($script:CtlNewHarness)) {
        Exit-FmControlError '--harness requires a non-empty value'
    }
    if ($script:CtlModelSet -and [string]::IsNullOrEmpty($script:CtlNewModel)) {
        Exit-FmControlError '--model requires a non-empty value'
    }
    if ($script:CtlEffortSet -and [string]::IsNullOrEmpty($script:CtlNewEffort)) {
        Exit-FmControlError '--effort requires a non-empty value'
    }
    if (-not [string]::IsNullOrEmpty($script:CtlNewEffort) -and
        $script:CtlNewEffort -cne 'low' -and $script:CtlNewEffort -cne 'medium' -and
        $script:CtlNewEffort -cne 'high' -and $script:CtlNewEffort -cne 'xhigh' -and
        $script:CtlNewEffort -cne 'max') {
        Exit-FmControlError '--effort must be one of low, medium, high, xhigh, max'
    }

    # --- exact task-id resolution -------------------------------------------

    if ($rawId.Contains(':')) {
        Exit-FmControlError ("'$rawId' is an explicit backend endpoint; fm-control accepts an exact task " +
            'id only, so a lifecycle command can never land on an endpoint this home does not own')
    }
    if (-not (Test-FmTaskIdCreationValid -Id $rawId)) {
        Exit-FmControlError "'$rawId' is not a valid task id"
    }
    $script:CtlId = $rawId
    $script:CtlControlLock = "$($script:CtlState)/.control-$($script:CtlId).lock"

    try {
        if (-not (Request-FmLock -LockPath $script:CtlControlLock)) {
            Exit-FmControlError "another lifecycle action is already running for task $($script:CtlId)"
        }
        $script:CtlControlLockHeld = $true

        $script:CtlMeta = "$($script:CtlState)/$($script:CtlId).meta"
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $script:CtlMeta))) {
            if ($rawId.StartsWith('fm-', [System.StringComparison]::Ordinal)) {
                $legacy = "$($script:CtlState)/$($rawId.Substring(3)).meta"
                if ([System.IO.File]::Exists((ConvertTo-FmNativePath $legacy))) {
                    Exit-FmControlError ("'$rawId' is a window label, not a task id; pass the exact task " +
                        "id '$($rawId.Substring(3))'")
                }
            }
            Exit-FmControlError ("no task '$($script:CtlId)' in $($script:CtlState) (fm-control resolves " +
                'an exact task id only)')
        }

        # A remotely placed secondmate records its endpoint on ANOTHER host, so
        # every postcondition this plane verifies - the agent-state
        # classification, the busy verdict, the endpoint's existence - would be
        # read here for an endpoint that does not live here. Endpoint validation
        # already refuses such a record, since `window=remote:<id>` can never
        # match a local backend's required shape, so nothing can be delivered to
        # a wrong endpoint either way. What that refusal cannot say is WHY, and
        # "malformed metadata" is the wrong thing to tell an operator about a
        # correctly configured remote route. Name the placement instead, using
        # the same `remote_host` signal bin/fm-send routes on.
        $remoteHost = Get-FmMetaValue $script:CtlMeta 'remote_host'
        if (-not [string]::IsNullOrEmpty($remoteHost)) {
            Exit-FmControlError ("task $($script:CtlId) is a remotely placed secondmate on $remoteHost; " +
                'its agent runs outside this home, so no lifecycle action here could verify that it ' +
                'interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it ' +
                'through the secondmate recovery path rather than this plane')
        }

        $validated = Get-FmBackendValidatedEndpoint $script:CtlMeta $script:CtlId
        if (-not $validated.Ok) { Exit-FmScript 1 }
        $script:CtlBackend = [string]$validated.Backend
        $script:CtlTarget = [string]$validated.Target
        $script:CtlLabel = "fm-$($script:CtlId)"
        $script:CtlRecordedHarness = Get-FmMetaValue $script:CtlMeta 'harness'
        $script:CtlKind = Get-FmMetaValue $script:CtlMeta 'kind'
        $script:CtlWorktree = Get-FmMetaValue $script:CtlMeta 'worktree'
        if ([string]::IsNullOrEmpty($script:CtlKind)) { $script:CtlKind = 'ship' }

        $family = Get-FmControlHarnessFamily $script:CtlRecordedHarness
        $shownHarness = if ([string]::IsNullOrEmpty($script:CtlRecordedHarness)) {
            'none'
        } else {
            $script:CtlRecordedHarness
        }
        if ([string]::IsNullOrEmpty($family)) {
            Exit-FmControlError ("task $($script:CtlId) records harness '$shownHarness', which has no " +
                'verified control mechanics; fm-control refuses to guess an interrupt key or exit command')
        }
        $script:CtlHarness = $family
        if (-not (Test-FmControlHarnessSupported $script:CtlHarness)) {
            Exit-FmControlError ("task $($script:CtlId) records harness '$shownHarness', which has no " +
                'verified control mechanics; fm-control refuses to guess an interrupt key or exit command')
        }

        if (-not (Test-FmBackendValid $script:CtlBackend)) { Exit-FmScript 1 }

        # The relaunch transaction's durable record, resolved once the task id
        # is known so the rollback can always name it.
        $script:CtlJournal = "$($script:CtlState)/$($script:CtlId).control-relaunch"
        $script:CtlMetaPrior = "$($script:CtlJournal).meta-prior"
        $script:CtlBriefPrior = "$($script:CtlJournal).brief-prior"
        $script:CtlNoteFile = "$($script:CtlJournal).note"
        $script:CtlPriorHarness = $script:CtlHarness
        $script:CtlPriorRecordedHarness = $script:CtlRecordedHarness
        $script:CtlTargetHarness = $script:CtlHarness

        # --- verbs ----------------------------------------------------------

        switch -CaseSensitive ($verb) {
            'interrupt' {
                $state = Get-FmControlAgentState
                switch -CaseSensitive ($state) {
                    'alive' { }
                    'unverified' {
                        # No recovery-grade classifier on this backend. Interrupt
                        # is non-destructive and its endpoint-existence
                        # postcondition is still real, so it proceeds - the
                        # printed proof names exactly what was verified rather
                        # than implying more.
                    }
                    { $_ -ceq 'dead' -or $_ -ceq 'missing' } {
                        Exit-FmControlError ("no agent is running at task $($script:CtlId)'s recorded " +
                            "endpoint (state: $state); there is nothing to interrupt")
                    }
                    default {
                        Exit-FmControlError ("task $($script:CtlId)'s endpoint reads '$state' rather than " +
                            'a positively classified state; refusing to send a lifecycle key into an ' +
                            'unattributed endpoint')
                    }
                }
                $proof = Invoke-FmControlInterrupt
                Write-FmOut ("interrupt-delivered $($script:CtlId) harness=$($script:CtlHarness) " +
                    "backend=$($script:CtlBackend) verified=$proof")
            }
            'exit' {
                $result = Invoke-FmControlExit
                Write-FmOut ("$result $($script:CtlId) harness=$($script:CtlHarness) " +
                    "backend=$($script:CtlBackend) endpoint=$($script:CtlTarget) " +
                    "worktree=$($script:CtlWorktree)")
            }
            'relaunch' {
                Invoke-FmControlRelaunch
            }
        }
        Exit-FmScript 0
    } finally {
        Invoke-FmControlCleanup
    }
}
