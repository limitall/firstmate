#requires -Version 7.0
# FmDecisionClose.ps1 - the WRITE side of a decision's lifecycle: the send that
# delivers the captain's answer to a worker is the act that closes the decision
# it answers. Send-FmText -ResolveKey is the one caller; this file owns the
# contract. Ported in shape from bin/fm-send.sh's --resolve-key (upstream #1842,
# #2490), not in code.
#
# WHY THE ANSWER CLOSES IT. A needs-decision or blocked line opens a keyed
# decision in state/<id>.status, and only a resolved or captain-held line naming
# the same key closes it (Public/FmClassify.ps1 owns that fold). Nothing else
# closes one: not a later done:, not the worker acting on the answer, not the
# answer arriving. So a decision answered by chat alone stays listed under OPEN
# DECISIONS, is raised with the captain again, and blocks the teardown gate for
# an investigation that is finished. Making the close a separate step after the
# answer is how it got forgotten; binding it to the send means an answer cannot
# be delivered this way without its close.
#
# THE ORDER, AND WHICH WAY EACH FAILURE GOES.
#   1. Before anything is sent, every key is checked against the task's OWN
#      ledgers (Get-FmDecisionClosurePlan). A key that closes nothing is refused
#      and nothing is typed: delivering the answer while the decision stays open
#      is exactly the defect, and doing it with exit 0 would also claim success.
#   2. The answer is sent. An unconfirmed or failed send closes nothing, so the
#      decision stays open and re-surfaces.
#   3. Only after a confirmed delivery is each close written
#      (Complete-FmDecisionClosure), and the status close is re-folded to prove
#      it took. A close that fails after delivery reports the exact command that
#      finishes it and says not to resend - the answer already landed.
#
# WHY A KEY IS MATCHED WITHIN ONE TASK. A key is only unique inside the stream
# that opened it: two workers can both ask [key=api-shape], and every keyless
# decision is `default`. So a key is looked for in the target task's status file
# and among the captain holds the backlog attributes to that task
# (Get-FmDecisionHoldForTask, the teardown gate's own attribution rule), and
# nowhere else.
#
# THE CAPTAIN HOLD. decision-hold-lifecycle files a captain-held backlog item
# whose id is the decision key. An answer closes it too, in the same act, when
# nothing is blocked by it. When work IS blocked by it, the skill requires the
# decision to be written into that work before the hold closes, which no send
# can do - so the hold is left open and named, and the status close still
# happens. A key that is ONLY such a hold would therefore close nothing, and is
# refused before sending like any other key that closes nothing.
#
# THE WAKE. The close is firstmate's own bookkeeping, written by the turn that
# is reading it, so it goes through Add-FmTaskStatus -SelfAnnounced and does not
# wake that session again; a worker line that landed first still does.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Check -ResolveKey keys against one task's ledgers before an answer is sent.

.DESCRIPTION
Reads only - the backlog resolver's own legacy-location repair aside, which
every backlog reader gets. Returns the plan Complete-FmDecisionClosure carries out after a
confirmed delivery, or throws a refusal naming the key and saying nothing was
sent. See this file's header for the contract.
#>
function Get-FmDecisionClosurePlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FirstmateHome,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Answer
    )

    $flat = ($Answer -replace '\s+', ' ').Trim()
    if (-not $flat) {
        throw 'error: -ResolveKey needs a non-empty answer; the answer is what closes the decision. Nothing was sent.'
    }
    $note = "answered: $flat"

    # The fold compares keys with -eq, so a duplicate is judged the same way.
    $unique = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Key) {
        if ($k -notmatch '^[A-Za-z0-9._-]+$') {
            throw "error: -ResolveKey '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -). Nothing was sent."
        }
        if (@($unique | Where-Object { $_ -eq $k }).Count -gt 0) {
            throw "error: -ResolveKey '$k' is named twice. Nothing was sent."
        }
        $unique.Add($k)
    }

    $stateDir = Join-Path $FirstmateHome 'state'
    $statusPath = Join-Path $stateDir "$TaskId.status"
    # Assigned, never wrapped: the fold returns its list behind a unary comma.
    $open = Get-FmOpenDecision -Path $statusPath

    $backlogPath = ''
    $items = @()
    $holds = @()
    $backlogError = ''
    try {
        $backlogPath = [string](Get-FmBacklogConfig -Root $FirstmateHome).Path
        $items = @(Get-FmBacklog -Path $backlogPath)
        $holds = @(Get-FmDecisionHoldForTask -TaskId $TaskId -Task $items)
    } catch {
        $backlogError = [string]$_.Exception.Message
    }

    $statusKeys = [System.Collections.Generic.List[string]]::new()
    $planHolds = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $unique) {
        $inStatus = @($open | Where-Object { $_.Key -eq $k }).Count -gt 0
        # The task's own backlog item is never a decision hold to close: closing
        # it would mark the work itself done.
        $hold = @($holds | Where-Object { $_.Id -eq $k -and $_.Id -ne $TaskId }) | Select-Object -First 1
        $dependents = @()
        if ($hold) {
            $dependents = @(foreach ($item in $items) {
                    if ($item.State -eq 'done') { continue }
                    foreach ($dep in $item.Deps) {
                        if ($dep.Type -eq 'blocked-by' -and $dep.Id -eq $hold.Id) { $item.Id; break }
                    }
                })
        }

        if ($inStatus) {
            if (-not (Test-FmClassifyReservedKeyTransitionAllowed -Key $k -Note $note)) {
                throw ("error: -ResolveKey '$k' is reserved for the subsystem that opened it, and the status fold " +
                    'ignores a close written by an answer, so it would stay open. Nothing was sent.')
            }
            $statusKeys.Add($k)
        } elseif (-not $hold) {
            if ($backlogError) {
                throw ("error: -ResolveKey '$k' is not open in $statusPath, and this home's backlog could not be read " +
                    "to look for a captain hold with that key ($backlogError). Nothing was sent.")
            }
            throw ("error: -ResolveKey '$k' names no open decision or blocker in $statusPath and no captain hold " +
                "attributed to $TaskId - it is already closed, mistyped, or belongs to another task. Nothing was sent. " +
                'Check the OPEN DECISIONS listing and resend with the right key, or without -ResolveKey if it is ' +
                'already closed.')
        } elseif ($dependents.Count -gt 0) {
            throw ("error: -ResolveKey '$k' names a captain hold that $($dependents -join ', ') is blocked by, and " +
                'decision-hold-lifecycle closes it only once the decision is written into that work, so this send ' +
                'would close nothing. Nothing was sent: send the answer without -ResolveKey and follow that skill.')
        }
        if ($hold) {
            $planHolds.Add([pscustomobject]@{ Id = $hold.Id; Dependents = @($dependents) })
        }
    }

    $warnings = @()
    if ($backlogError -and $statusKeys.Count -gt 0) {
        $warnings = @("this home's backlog could not be read, so no captain hold for $($statusKeys -join ', ') " +
            "was looked for or closed ($backlogError)")
    }

    [pscustomobject]@{
        TaskId      = $TaskId
        StateDir    = $stateDir
        StatusPath  = $statusPath
        BacklogPath = $backlogPath
        Note        = $note
        StatusKeys  = @($statusKeys)
        Holds       = @($planHolds)
        Warnings    = $warnings
    }
}

<#
.SYNOPSIS
Write the closes a plan names, after its answer was delivered.

.DESCRIPTION
Closes every status key (self-announced, then re-folded to prove it took) and
every captain hold nothing is blocked by. Attempts them all before reporting,
and throws one message naming each close that did not happen, the command that
finishes it, and that the answer must not be resent.
#>
function Complete-FmDecisionClosure {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Runs only after Send-FmText''s own ShouldProcess approved and delivered the answer; a second prompt here could leave a delivered answer with its decision open.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Plan,
        [Parameter(Mandatory)][string]$DeliveredTo
    )

    $closed = [System.Collections.Generic.List[string]]::new()
    $holdsClosed = [System.Collections.Generic.List[string]]::new()
    $holdsOpen = [System.Collections.Generic.List[string]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $quotedNote = $Plan.Note.Replace("'", "''")
    $manifest = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'Firstmate.psd1'))

    foreach ($k in $Plan.StatusKeys) {
        $manual = "Import-Module '$manifest'; Add-FmTaskStatus -StateDir '$($Plan.StateDir)' -TaskId '$($Plan.TaskId)' " +
        "-State resolved -Key '$k' -Note '$quotedNote'"
        try {
            $null = Add-FmTaskStatus -StateDir $Plan.StateDir -TaskId $Plan.TaskId -State 'resolved' -Key $k `
                -Note $Plan.Note -SelfAnnounced -Confirm:$false
        } catch {
            $failures.Add("decision key '$k' could not be closed in $($Plan.StatusPath) ($($_.Exception.Message)); close it with: $manual")
            continue
        }
        $still = Get-FmOpenDecision -Path $Plan.StatusPath
        if (@($still | Where-Object { $_.Key -eq $k }).Count -gt 0) {
            $failures.Add("decision key '$k' is still open in $($Plan.StatusPath) after its close was written, so a later line reopened it or the fold refused the close; close it with: $manual")
            continue
        }
        $closed.Add($k)
    }

    foreach ($hold in $Plan.Holds) {
        if ($hold.Dependents.Count -gt 0) {
            $holdsOpen.Add("captain hold '$($hold.Id)' stays open: $($hold.Dependents -join ', ') is blocked by it, and decision-hold-lifecycle closes it once the decision is written into that work")
            continue
        }
        try {
            $null = Complete-FmBacklogTask -Id $hold.Id -Path $Plan.BacklogPath -Note $Plan.Note -Confirm:$false
            $holdsClosed.Add($hold.Id)
        } catch {
            $failures.Add("captain hold '$($hold.Id)' could not be closed ($($_.Exception.Message)); close it with: bin/fm-backlog.ps1 done $($hold.Id) -Note '$quotedNote'")
        }
    }

    if ($failures.Count -gt 0) {
        throw ("error: the answer was delivered to $DeliveredTo, but " + ($failures -join '; ') + '. Do not resend the answer.')
    }

    [pscustomobject]@{
        Resolved      = @($closed)
        HoldsClosed   = @($holdsClosed)
        HoldsLeftOpen = @($holdsOpen)
    }
}
