#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Stop a worker's agent with a proven postcondition, and optionally release the
endpoint and the leased worktree.

.DESCRIPTION
The PowerShell port of bin/fm-control.sh's `exit` verb (plus the optional
endpoint and lease release this port owns because it acquired the lease).

WHAT IS PROVEN, NOT ASSUMED
  - The target is resolved EXACTLY: only a bare task id with a record in this
    home, and that record must pass the shared endpoint-identity validation
    (Test-FmTaskEndpoint), which binds task id, backend, target, project and
    worktree together. A lifecycle command delivered to the wrong endpoint is
    far worse than a loud refusal.
  - The backend must have a recovery-grade agent-state classifier. herdr does;
    a backend that does not is refused rather than reported as successfully
    stopped, because "the agent stopped" would be unprovable.
  - A busy agent is interrupted before the exit command is submitted.
  - The postcondition is the agent-state wait, NOT the submit verdict: a
    successful exit destroys the composer the verdict is read from, so only a
    hard transport failure aborts early.
  - Already-stopped is success, idempotently.

WHAT IS PRESERVED FROM THE BASH CONTRACT
  Stopping an agent preserves its endpoint, its worktree and every uncommitted
  change. -ClosePane and -ReleaseWorktree are opt-in and are still not a
  teardown: neither discards work, and the landed-work test stays with the
  teardown owner. -ReleaseWorktree releases only a lease recorded by this
  port's own spawn, conditionally on that exact lease id.

-Interrupt IS THE CONTROL PLANE'S OTHER VERB, and it deliberately does NOT
stop anything: it delivers the harness's verified interrupt sequence and then
proves the agent is STILL RUNNING, which is the postcondition that separates a
landed interrupt from an accident. It lives on this function because this port
exposes exactly four public verbs; bin/fm-control.ps1 routes `interrupt` here.

NOT PORTED: the `relaunch` verb. It is a durable transaction (checkpoint
journal, note capture, staged rollback) whose replacement launch belongs to the
spawn path; half of it is worse than none, so bin/fm-control.ps1 refuses it by
name and points at the two steps.
#>
function Stop-FmWorker {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TaskId,
        [string]$FirstmateHome = '',
        [switch]$Interrupt,
        [switch]$ClosePane,
        [switch]$ReleaseWorktree,
        [double]$ExitWaitSeconds = 30,
        [double]$PollSeconds = 0.5,
        [int]$ExitRetries = 3
    )

    if (-not $FirstmateHome) { $FirstmateHome = $env:FM_HOME }
    if (-not $FirstmateHome) {
        throw 'error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home'
    }
    $stateDir = Join-Path $FirstmateHome 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw "error: state dir '$stateDir' is missing; fm-control cannot resolve tasks for FM_HOME '$FirstmateHome'"
    }
    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id; fm-control targets an exact task id only"
    }
    $metaPath = Get-FmMetaPath -StateDir $stateDir -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw ("error: task $TaskId has no record at $metaPath; fm-control targets an exact task id in this home only " +
            '(a legacy label or an explicit endpoint is refused)')
    }
    if (Get-FmMetaValue -Path $metaPath -Key 'remote_host') {
        throw ("error: task $TaskId is a remotely placed secondmate; its agent runs outside this home, so no lifecycle " +
            'action here could verify that it stopped')
    }

    $endpoint = Test-FmTaskEndpoint -MetaPath $metaPath -TaskId $TaskId
    if (-not $endpoint.Valid) { throw $endpoint.Reason }
    $backend = $endpoint.Backend
    $target = $endpoint.Target
    if (-not (Test-FmControlBackendStateVerified -Backend $backend)) {
        throw ("error: task $TaskId runs on the $backend backend, which has no recovery-grade agent-state classifier, " +
            "so 'exit' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done")
    }
    if ($backend -ne 'herdr') {
        throw "error: task $TaskId records backend '$backend'; this PowerShell port drives the herdr session provider only"
    }

    $recordedHarness = Get-FmMetaValue -Path $metaPath -Key 'harness'
    $harness = Get-FmControlHarnessFamily -RecordedHarness $recordedHarness
    if (-not $harness) {
        $shown = if ($recordedHarness) { $recordedHarness } else { 'none' }
        throw ("error: task $TaskId records harness '$shown', which has no verified control mechanics; fm-control " +
            'refuses to guess an interrupt key or exit command')
    }
    $exitCommand = Get-FmControlExitCommand -Harness $harness
    if (-not $Interrupt -and -not $exitCommand) {
        throw "error: harness '$harness' has no verified exit command; fm-control refuses to guess one"
    }

    if ($Interrupt) {
        if ($ClosePane -or $ReleaseWorktree) {
            throw 'error: -Interrupt leaves the agent running, so it cannot be combined with -ClosePane or -ReleaseWorktree'
        }
        if (-not $PSCmdlet.ShouldProcess("task $TaskId ($target)", 'interrupt the running turn')) { return $null }
        $cancel = Send-FmControlInterrupt -Backend $backend -Target $target -Harness $harness
        if (-not (Test-FmHerdrTargetExists -Target $target)) {
            throw "error: task $TaskId's endpoint disappeared while interrupting it; no further control action is safe"
        }
        # An interrupt cancels a turn; it must never have stopped the agent.
        # This is the postcondition that separates a landed interrupt from an
        # accident.
        $after = Get-FmHerdrAgentState -Target $target
        if ($after -ne 'alive') {
            throw "error: task $TaskId's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
        }
        return [pscustomobject]@{
            TaskId  = $TaskId
            Target  = $target
            Backend = $backend
            Harness = $harness
            Outcome = 'interrupted'
            Proof   = 'agent-alive'
            Cancel  = $cancel
        }
    }

    if (-not $PSCmdlet.ShouldProcess("task $TaskId ($target)", 'stop the agent')) { return $null }

    $result = [ordered]@{
        TaskId          = $TaskId
        Target          = $target
        Backend         = $backend
        Harness         = $harness
        Outcome         = ''
        Interrupt       = 'not-needed'
        PaneClosed      = $false
        WorktreeRelease = 'not-requested'
    }

    $state = Get-FmHerdrAgentState -Target $target
    switch ($state) {
        'dead' { $result['Outcome'] = 'already-stopped' }
        'alive' { }
        'missing' {
            throw ("error: task $TaskId's recorded endpoint is gone, so there is no agent to stop; reconcile the task " +
                'before any further control action')
        }
        default {
            throw ("error: task $TaskId's endpoint reads '$state' rather than a positively classified state; refusing " +
                'to send a lifecycle command into an unattributed endpoint')
        }
    }

    if ($result['Outcome'] -ne 'already-stopped') {
        if ((Get-FmHerdrBusyState -Target $target) -eq 'busy') {
            $cancel = Send-FmControlInterrupt -Backend $backend -Target $target -Harness $harness
            $state = Get-FmHerdrAgentState -Target $target
            switch ($state) {
                'dead' { $result['Outcome'] = 'stopped' }
                'alive' { $result['Interrupt'] = "delivered verified=agent-alive cancel=$cancel" }
                'missing' {
                    throw ("error: task $TaskId's recorded endpoint disappeared after interrupt delivery, so exit " +
                        'cannot prove whether the agent stopped')
                }
                default {
                    throw ("error: task $TaskId's endpoint reads '$state' after interrupt delivery rather than a " +
                        'positively classified state; exit cannot prove whether the agent stopped')
                }
            }
        }
    }

    if (-not $result['Outcome']) {
        # The submit verdict is NOT the postcondition: a successful exit
        # destroys the composer the verdict is read from, so a post-exit read
        # can legitimately report anything. Only a hard transport failure
        # aborts here. The retried Enter still matters, because the exit
        # command is a slash command and some TUIs open a completion popup that
        # swallows the first Enter.
        $verdict = Send-FmHerdrTextSubmit -Target $target -Text $exitCommand -Retries $ExitRetries `
            -EnterSleepSeconds $PollSeconds -SettleSeconds 1.2
        if ($verdict -eq 'send-failed') {
            throw "error: the exit command could not be sent to task $TaskId on $backend"
        }
        $state = Wait-FmWorkerAgentState -Target $target -Wanted @('dead') -TimeoutSeconds $ExitWaitSeconds -PollSeconds $PollSeconds
        if ($state -ne 'dead') {
            throw ("error: exit-delivered $TaskId interrupt=$($result['Interrupt']) exit-command=delivered " +
                "agent-state=$state exit=unconfirmed; the agent did not stop within ${ExitWaitSeconds}s")
        }
        $result['Outcome'] = 'stopped'
    }

    if ($ClosePane) {
        $result['PaneClosed'] = [bool](Remove-FmHerdrPane -Target $target -Confirm:$false)
        if (-not $result['PaneClosed']) {
            Write-Warning "task $TaskId's pane close was not confirmed gone; its endpoint record is preserved"
        }
    }

    if ($ReleaseWorktree) {
        $leaseId = Get-FmMetaValue -Path $metaPath -Key 'treehouse_lease_id'
        $worktree = Get-FmMetaValue -Path $metaPath -Key 'worktree'
        if (-not $worktree) {
            $result['WorktreeRelease'] = 'no-worktree-recorded'
        } elseif (-not $leaseId) {
            # A record with no lease id was not leased by this port. Returning
            # it would be a guess about who owns it, so it is left alone.
            $result['WorktreeRelease'] = 'refused-no-lease-id'
        } elseif (Remove-FmWorktreeLease -Path $worktree -IfLeaseId $leaseId -Confirm:$false) {
            $result['WorktreeRelease'] = 'released'
        } else {
            $result['WorktreeRelease'] = 'release-failed'
        }
    }

    [pscustomobject]$result
}

# Wait-FmWorkerAgentState: poll until the endpoint reports one of the wanted
# recovery-grade states, or the budget runs out. Returns the last observed
# state either way, so a caller reports what it actually saw rather than a
# generic timeout.
function Wait-FmWorkerAgentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$Wanted,
        [double]$TimeoutSeconds = 30,
        [double]$PollSeconds = 0.5
    )
    $elapsed = 0.0
    while ($true) {
        $state = Get-FmHerdrAgentState -Target $Target
        if ($state -in $Wanted) { return $state }
        if ($elapsed -ge $TimeoutSeconds) { return $state }
        Start-Sleep -Seconds $PollSeconds
        $elapsed += $PollSeconds
    }
}
