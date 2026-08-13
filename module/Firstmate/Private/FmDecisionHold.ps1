#requires -Version 7.0
# FmDecisionHold.ps1 - the READ side of the unresolved-decision policy that
# .agents/skills/decision-hold-lifecycle/SKILL.md owns, and the owner of the
# completion gate Invoke-FmTeardown binds by name before it discards a scout.
#
# WHY A SCOUT TEARDOWN ASKS AT ALL. Teardown erases the worktree, the branch,
# the pane and every state record for a task. The report survives under data/,
# but the TASK is what bin/fm-promote.ps1 promotes in place when the captain
# authorises the work an investigation recommended (AGENTS.md section 7:
# "promote the existing scout rather than creating a duplicate task"). So
# discarding a scout while a captain decision it raised is still unanswered
# destroys the very thing the answer would act on. The gate is what makes that
# a refusal instead of a discovery weeks later.
#
# WHAT THIS IS NOT. It does not perform the semantic inventory and cannot: the
# skill is explicit that no script can infer decisions from report prose,
# visual-review artifacts, terminal output or chat, which is why the completion
# attestation stays the agent's. This answers the narrower mechanical question -
# do this home's durable records STILL carry an unresolved decision against this
# task - and refuses both when they do and when it cannot read them.
#
# WHERE IT READS, AND WHY THOSE TWO PLACES. There is no fm-decision-hold command
# and no hold store on this port (AGENTS.md section 14), so the records that
# exist are the ones it reads:
#
#   1. state/<id>.status - the task's own stream. needs-decision/blocked opens a
#      keyed decision and only resolved/captain-held carrying that exact key
#      closes it (docs/lifecycle.md, Public/FmClassify.ps1 owns the fold). An
#      open key is a decision that was raised and never routed anywhere.
#   2. this home's backlog - where the skill requires every unresolved captain
#      decision to become a durable held work item before the investigation may
#      be treated as complete. An ACTIVE hold the backlog attributes to this task
#      is an answer that has not arrived yet.
#
# ATTRIBUTION IS AN EDGE THE BACKLOG STATES, NEVER AN INFERENCE FROM PROSE. A
# held item is this task's when it IS the task's own item, when the task's item
# is blocked-by it, when it carries discovered-from: <task-id>, or when it names
# data/<task-id>/report.md. Every other hold in the backlog belongs to somebody
# else's work and never blocks this teardown - which is also what keeps the
# skill's rule intact that a hold outlives the investigation that filed it: the
# gate never closes a hold, and never reads one it was not pointed at.
#
# A HOLD WITH NO hold-kind COUNTS. captain is the kind the skill prescribes;
# external/load/parked/future are declared dispatch holds and are not decisions.
# An untyped hold is neither, so it is treated as a decision and the refusal says
# to tag it - fail closed, because the alternative is passing something this gate
# never actually established.

Set-StrictMode -Version Latest

# The verdict record. Deliberately NOT a boolean, and this is the whole reason
# Invoke-FmTeardown reads `.Verdict`: a refusal has to name the decision it
# refuses on, and `-not <record>` is always false, so a caller that treats the
# return value as a boolean would pass everything. Same shape and same reasoning
# as New-FmTeardownVerdict.
function New-FmDecisionHoldVerdict {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory verdict record and changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('pass', 'refuse')][string]$Verdict,
        [AllowEmptyCollection()][string[]]$Message = @(),
        [AllowEmptyString()][string]$Detail = ''
    )
    if ($null -eq $Message) { $Message = @() }
    [pscustomobject]@{ Verdict = $Verdict; Message = @($Message); Detail = $Detail }
}

# True when a backlog item's hold is an unresolved DECISION rather than a
# dispatch hold. Activity is the backlog area's own rule (Test-FmBacklogHoldActive:
# not done, and any hold-until date still in the future), so there is one owner
# of what "still held" means.
function Test-FmDecisionHoldItemUnresolved {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Task,
        [AllowEmptyString()][string]$Today = ''
    )

    if (-not (Test-FmBacklogHoldActive -Task $Task -Today $Today)) { return $false }
    $kind = [string]$Task.Hold.Kind
    if ([string]::IsNullOrEmpty($kind)) { return $true }
    ($kind -eq 'captain')
}

# Every unresolved decision hold the backlog attributes to one task, with the
# edge that attributes it. Empty means the backlog records none - which is a
# fact about the backlog, not about whether an inventory was ever done.
function Get-FmDecisionHoldForTask {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [AllowEmptyCollection()][object[]]$Task = @(),
        [AllowEmptyString()][string]$Today = ''
    )

    if ($null -eq $Task) { $Task = @() }

    # What the task's OWN item declares itself blocked by. The skill blocks
    # dependent work on the hold's key, so this is the edge that says "this work
    # is waiting on that decision" in the backlog's own grammar.
    $blocker = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($item in $Task) {
        if ($item.Id -ne $TaskId) { continue }
        foreach ($dep in $item.Deps) {
            if ($dep.Type -eq 'blocked-by') { $null = $blocker.Add($dep.Id) }
        }
    }

    $reportLink = "data/$TaskId/report.md"
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Task) {
        if (-not (Test-FmDecisionHoldItemUnresolved -Task $item -Today $Today)) { continue }

        $edge = ''
        if ($item.Id -eq $TaskId) {
            $edge = "it IS $TaskId's own backlog item"
        } elseif ($blocker.Contains($item.Id)) {
            $edge = "$TaskId is blocked-by $($item.Id)"
        } else {
            foreach ($dep in $item.Deps) {
                if ($dep.Type -eq 'discovered-from' -and $dep.Id -eq $TaskId) {
                    $edge = "it carries discovered-from: $TaskId"
                    break
                }
            }
            if ($edge -eq '') {
                # Links are derived from the item's title, so a report path
                # mentioned only in an indented body line does not attribute -
                # the same rule the backlog grammar already applies everywhere.
                foreach ($link in $item.Links) {
                    if ($link.Kind -eq 'report' -and $link.Url -eq $reportLink) {
                        $edge = "it names $reportLink"
                        break
                    }
                }
            }
        }
        if ($edge -eq '') { continue }

        $found.Add([pscustomobject]@{
                Id     = $item.Id
                Title  = $item.Title
                Reason = $item.Hold.Reason
                Kind   = $item.Hold.Kind
                Until  = $item.Hold.Until
                Edge   = $edge
            })
    }
    @($found)
}

# One held item rendered for a refusal message: enough for the captain to
# recognise the decision without opening the backlog.
function Get-FmDecisionHoldLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Hold)

    $kind = if ([string]::IsNullOrEmpty($Hold.Kind)) {
        ' [no hold-kind recorded, so this gate cannot rule it out as a captain decision - tag it with -Kind]'
    } else {
        " [hold-kind: $($Hold.Kind)]"
    }
    $until = if ([string]::IsNullOrEmpty($Hold.Until)) { '' } else { " [in force until $($Hold.Until)]" }
    "  $($Hold.Id) - $($Hold.Title) (hold: $($Hold.Reason))$kind$until - $($Hold.Edge)"
}

<#
.SYNOPSIS
The unresolved-decision completion gate: whether this home's durable records
still carry an unresolved decision against one task.

.DESCRIPTION
Returns a VERDICT RECORD, never a boolean - Verdict ('pass' or 'refuse'),
Message (the refusal lines, already captain-readable), and Detail (what a pass
actually read). Callers must test `.Verdict -eq 'pass'`; coercing the record to a
boolean would pass everything.

It refuses on three different things, and says which: an unresolved decision in
the task's status stream, an unresolved decision hold the backlog attributes to
the task, and - equally loudly - a record it could not read at all. It never
mutates anything, and in particular it never closes a hold.

.PARAMETER TaskId
The task being completed or torn down.

.PARAMETER FirstmateHome
The home whose data/, state/ and backlog answer for that task. Required rather
than resolved ambiently, so this can never answer about a different home than
the caller meant.

.PARAMETER BacklogPath
Read this backlog file instead of the one this home's configuration selects.

.PARAMETER Today
Evaluate hold-until against this date instead of today. Test seam.

.EXAMPLE
(Test-FmDecisionHoldComplete -TaskId my-scout -FirstmateHome $env:FM_HOME).Verdict
#>
function Test-FmDecisionHoldComplete {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FirstmateHome,
        [AllowEmptyString()][string]$BacklogPath = '',
        [AllowEmptyString()][string]$Today = ''
    )

    $forced = 'or use --force after explicit discard approval.'

    if ([string]::IsNullOrEmpty($TaskId)) {
        return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
            'REFUSED: the unresolved-decision completion gate was given no task id, so it did NOT run.')
    }
    if ([string]::IsNullOrEmpty($FirstmateHome) -or -not (Test-Path -LiteralPath $FirstmateHome -PathType Container)) {
        return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
            "REFUSED: the unresolved-decision completion gate cannot read home '$FirstmateHome' for task $TaskId, so it did NOT run.",
            'A gate that could not look cannot report a pass; every record is preserved.')
    }

    # The report first, because it is what the rest of this gate reads AROUND:
    # an investigation with no work product has nothing to have inventoried.
    # Teardown's own scout-report gate runs before this one and owns its message;
    # this is the same refusal for any other caller.
    $report = Join-Path $FirstmateHome 'data' $TaskId 'report.md'
    if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
        return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
            "REFUSED: task $TaskId has no report at $report, so the unresolved-decision completion gate has nothing to complete.",
            "Have the crewmate write the report, $forced")
    }

    # 1. The task's own status stream.
    $statusPath = Join-Path $FirstmateHome 'state' "$TaskId.status"
    # An absent status file is reported as absent rather than as clean: the
    # backlog is the durable owner of a filed hold, so this is not a refusal,
    # but a pass that called it clean would be claiming it read something it
    # never opened.
    $statusRead = "no status file at $statusPath"
    if (Test-Path -LiteralPath $statusPath) {
        if (-not (Test-FmLifecycleRegularFile -Path $statusPath)) {
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
                "REFUSED: task $TaskId's status file $statusPath is not an ordinary file, so its open decisions cannot be folded.",
                'The gate did NOT run and cannot report a pass; every record is preserved.')
        }
        $open = @()
        try {
            # NOT @(Get-FmOpenDecision ...): the fold returns its list behind a
            # unary comma so an empty result cannot unroll away, and wrapping it
            # again turns "nothing is open" into one nameless record.
            $open = Get-FmOpenDecision -Path $statusPath
        } catch {
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
                "REFUSED: task $TaskId's status file $statusPath could not be read, so the gate did NOT run.",
                [string]$_.Exception.Message)
        }
        if ($open.Count -gt 0) {
            $message = [System.Collections.Generic.List[string]]::new()
            $message.Add("REFUSED: task $TaskId still has an unresolved decision recorded in its own status stream.")
            foreach ($record in $open) {
                $message.Add("  [key=$($record.Key)] $($record.Verb): $($record.Note)")
            }
            $message.Add("$statusPath opened it and no resolved/captain-held line carrying the same key ever closed it.")
            $message.Add('Route it as decision-hold-lifecycle requires and append the closing line for its key, ' +
                $forced)
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message $message
        }
        $statusRead = "$statusPath carries no open decision"
    }

    # 2. This home's backlog.
    $path = $BacklogPath
    if ([string]::IsNullOrEmpty($path)) {
        try {
            $path = [string](Get-FmBacklogConfig -Root $FirstmateHome).Path
        } catch {
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
                "REFUSED: this home's backlog configuration could not be read, so the unresolved-decision completion gate did NOT run for $TaskId.",
                [string]$_.Exception.Message)
        }
    }
    $items = @()
    $backlogRead = "no backlog file at $path"
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-FmLifecycleRegularFile -Path $path)) {
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
                "REFUSED: the backlog at $path is not an ordinary file, so the unresolved-decision completion gate cannot read it for $TaskId.",
                'The gate did NOT run and cannot report a pass; every record is preserved.')
        }
        try {
            $items = @(Get-FmBacklog -Path $path)
        } catch {
            return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message @(
                "REFUSED: the backlog at $path could not be parsed, so the unresolved-decision completion gate did NOT run for $TaskId.",
                [string]$_.Exception.Message,
                'Repair the backlog and rerun; every record is preserved.')
        }
        $backlogRead = "$($items.Count) backlog item(s) in $path"
    }

    $holds = @(Get-FmDecisionHoldForTask -TaskId $TaskId -Task $items -Today $Today)
    if ($holds.Count -gt 0) {
        $message = [System.Collections.Generic.List[string]]::new()
        $message.Add("REFUSED: task $TaskId has an unresolved decision hold in this home's backlog.")
        foreach ($hold in $holds) { $message.Add((Get-FmDecisionHoldLine -Hold $hold)) }
        $message.Add("That decision is still the captain's to answer, and $TaskId is what bin/fm-promote.ps1 promotes " +
            'once it is answered - tearing it down now discards what the answer would act on.')
        $message.Add("Record the captain's answer and close the hold, $forced")
        return New-FmDecisionHoldVerdict -Verdict 'refuse' -Message $message
    }

    New-FmDecisionHoldVerdict -Verdict 'pass' -Detail "report $report; $statusRead; $backlogRead"
}
