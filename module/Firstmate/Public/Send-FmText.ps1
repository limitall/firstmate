#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Steer a worker: send one line of literal text and submit it, or send one named
key.

.DESCRIPTION
The PowerShell port of bin/fm-send.sh's core contract.

THE GUARANTEE: a steer either lands or reports that it did not. The line is
typed ONCE, then Enter is sent and retried - Enter only, never retyped - until
the backend confirms a submit or reports it inconclusive. Only an exact
`empty` verdict is delivery; every other verdict throws, so a caller never
believes an unsubmitted instruction was delivered. The retry never retypes,
so a confirmed-late submit cannot become a duplicate message.

Resolution refuses unresolved guesses. A target is an exact task id, a legacy
fm-<id> label resolved through this home's state/<id>.meta, or an explicit
well-formed backend target whose endpoint can be verified live. There is no
fallback window search: a "successful" send to the wrong endpoint is worse than
a loud failure.

FM_HOME must be explicit (-FirstmateHome or the environment variable), so a
steer cannot silently resolve against another home.

ANSWERING A DECISION CLOSES IT. -ResolveKey names the open decision (or
blocker) this text answers, in the target task's own records. Every key is
checked BEFORE anything is typed, and one that would close nothing is refused
with nothing sent. After a confirmed delivery the send appends
`resolved [key=<key>]: answered: <text>` to state/<task>.status without waking
this session, and closes the captain hold decision-hold-lifecycle filed under
that key when no work is blocked by it. An unconfirmed send closes nothing.
Private/FmDecisionClose.ps1 owns the contract; a decision listed without
[key=...] has the key `default`.

NOT PORTED: the from-firstmate routing marker, the parent-owned pending-reply
expectation, and remote secondmate delivery. Those are marker and
remote-transport contracts, not send mechanics (AGENTS.md section 14).

.EXAMPLE
Send-FmText -Target my-task -Text 'push the branch and open the PR'

.EXAMPLE
Send-FmText -Target my-task -Key Escape

.EXAMPLE
Send-FmText -Target my-task -Text 'use the flat shape' -ResolveKey api-shape
#>
function Send-FmText {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Target,
        [Parameter(Mandatory, ParameterSetName = 'Text', Position = 1)][string]$Text,
        [Parameter(Mandatory, ParameterSetName = 'Key')][string]$Key,
        [string]$FirstmateHome = '',
        [int]$Retries = 3,
        [double]$SleepSeconds = 0.4,
        [double]$PostSubmitSettleSeconds = 1,
        [AllowEmptyCollection()][string[]]$ResolveKey = @()
    )

    if (-not $FirstmateHome) { $FirstmateHome = $env:FM_HOME }
    if (-not $FirstmateHome) {
        throw 'error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home'
    }
    if (-not (Test-Path -LiteralPath $FirstmateHome -PathType Container)) {
        throw "error: FM_HOME '$FirstmateHome' is not a directory; fm-send cannot resolve this home's state"
    }
    $stateDir = Join-Path $FirstmateHome 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        throw "error: state dir '$stateDir' is missing; fm-send cannot resolve targets for FM_HOME '$FirstmateHome'"
    }

    $resolved = Resolve-FmTaskSelector -Selector $Target -StateDir $stateDir
    if (-not $resolved.Resolved) { throw $resolved.Reason }
    if ($resolved.Backend -ne 'herdr') {
        throw ("error: task target '$Target' records backend '$($resolved.Backend)'; this PowerShell port drives the " +
            'herdr session provider only, and refuses to send into a backend it cannot verify')
    }
    $endpoint = $resolved.Target

    # Checked before anything is typed: a key that closes nothing is refused
    # with nothing sent, never discovered after the answer has landed.
    $closure = $null
    if ($ResolveKey.Count -gt 0) {
        if ($PSCmdlet.ParameterSetName -eq 'Key') {
            throw 'error: -ResolveKey cannot accompany -Key; answering a decision takes a text answer. Nothing was sent.'
        }
        if (-not $resolved.TaskId) {
            throw ("error: -ResolveKey needs a task recorded in this home; an explicit backend target has no decision " +
                'records here. Nothing was sent.')
        }
        $closure = Get-FmDecisionClosurePlan -FirstmateHome $FirstmateHome -TaskId $resolved.TaskId `
            -Key $ResolveKey -Answer $Text
    }

    if ($PSCmdlet.ParameterSetName -eq 'Key') {
        if (-not (Test-FmControlBackendSupportsKey -Backend $resolved.Backend -Key $Key)) {
            throw "error: the $($resolved.Backend) backend cannot deliver key '$Key'"
        }
        if (-not $PSCmdlet.ShouldProcess($endpoint, "send key $Key")) { return $null }
        if (-not (Send-FmHerdrKey -Target $endpoint -Key $Key)) {
            throw "error: key '$Key' not sent to $endpoint ($($resolved.Backend) send failed)"
        }
        # An interrupt is not complete until the adapter's composer-clear key
        # has followed it, where the harness restores the cancelled prompt.
        if ($Key -in @('Escape', 'escape', 'Esc', 'esc') -and $resolved.Harness) {
            $family = Get-FmControlHarnessFamily -RecordedHarness $resolved.Harness
            if ($family) {
                $clear = Get-FmControlInterruptClearKey -Harness $family
                if ($clear -and -not (Send-FmHerdrKey -Target $endpoint -Key $clear)) {
                    throw ("error: Escape reached $endpoint, but the $family composer could not be cleared; it still " +
                        'holds the restored prompt. Clear it before sending the next message.')
                }
            }
        }
        return [pscustomobject]@{
            Target = $endpoint; TaskId = $resolved.TaskId; Delivered = $true; Key = $Key; Verdict = 'key-sent'
        }
    }

    # Slash commands open a completion popup in some TUIs; submitting too fast
    # selects nothing, so the popup gets time to settle before the (retried)
    # Enter. Codex opens the same popup for a `$<skill>` invocation, so a `$`
    # message to a codex target gets the same settle - scoped to codex on
    # purpose, because a leading `$` commonly starts ordinary text.
    $settle = 0.3
    if ($Text.StartsWith('/')) {
        $settle = 1.2
    } elseif ($Text.StartsWith('$') -and (Get-FmControlHarnessFamily -RecordedHarness $resolved.Harness) -eq 'codex') {
        $settle = 1.2
    }

    if (-not $PSCmdlet.ShouldProcess($endpoint, 'send text and submit')) { return $null }
    $verdict = Send-FmHerdrTextSubmit -Target $endpoint -Text $Text -Retries $Retries `
        -EnterSleepSeconds $SleepSeconds -SettleSeconds $settle

    switch ($verdict) {
        'empty' { }
        'send-failed' {
            throw "error: text not sent to $endpoint ($($resolved.Backend) send failed)"
        }
        default {
            throw "error: text not submitted to $endpoint (delivery unconfirmed; verdict=$verdict)"
        }
    }

    $closed = [pscustomobject]@{ Resolved = @(); HoldsClosed = @(); HoldsLeftOpen = @() }
    if ($closure) {
        $closed = Complete-FmDecisionClosure -Plan $closure -DeliveredTo "$($resolved.TaskId) ($endpoint)"
    }

    # Submit confirmation only proves the text was accepted; the harness needs
    # a beat to spin up the turn before its busy state shows, so an immediate
    # peek would otherwise catch the stale idle pane.
    if ($PostSubmitSettleSeconds -gt 0) { Start-Sleep -Seconds $PostSubmitSettleSeconds }

    [pscustomobject]@{
        Target        = $endpoint
        TaskId        = $resolved.TaskId
        Delivered     = $true
        Verdict       = $verdict
        Text          = $Text
        Resolved      = $closed.Resolved
        HoldsClosed   = $closed.HoldsClosed
        HoldsLeftOpen = $closed.HoldsLeftOpen
        Warnings      = @(if ($closure) { $closure.Warnings })
    }
}
