#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Merge a direct-PR ship task's pull request, but only when GitHub says it is safe
to, and report it merged only when GitHub says it is.

.DESCRIPTION
The PowerShell port of the GitHub half of bin/fm-pr-merge.sh.

This is firstmate's other merge gate-action, the sibling of Invoke-FmMergeLocal:
the captain's merge authority applied through a pull request instead of to a
local branch. Until it existed, "never merge a red PR" was a sentence in the
contract with nothing behind it - the merge itself was done by hand, nothing
recorded which pull request a task produced, and "merged" was something firstmate
asserted rather than something GitHub confirmed. That matters most under standing
`yolo` authority, where nobody is watching it happen.

WHAT IT REFUSES, AND WHY EACH REFUSAL IS THE POINT
  - a task that is not mode=direct-PR: a local-only task lands through
    Invoke-FmMergeLocal, and merging it here would bypass the gate its mode
    exists to impose.
  - a pull request that is closed, a draft, not MERGEABLE, or conflicted: each
    is read LIVE at merge time, never from the task record, because a record is
    a memory of a state that has since moved. Every failing condition is
    reported at once, not just the first.
  - a check that is not green at the CURRENT head - with a failed run that a
    later green run of the same name replaced treated as green. Without that
    last part the gate refuses correct work, which is how an operator learns to
    go round it.
  - --repo, --match-head-commit and their short forms, always: the repository
    comes from the URL and the head comes from the verified read, and an
    override defeats the binding entirely.
  - --auto, --admin and --delete-branch unless -AttendedOverride says a captain
    asked for that concrete thing.
  - a pull request already bound to a different URL in the task record: a task
    cannot be re-pointed at another pull request here.

WHAT IT GUARANTEES
The verified head is passed to gh as --match-head-commit, so a push that lands
between the read and the merge fails the merge rather than landing commits
nothing reviewed. After gh returns, GitHub is read back, and this command
returns an object only when that read says merged - a queued, refused or
unreadable outcome throws with what GitHub actually said. So `Merged` is never
anything but $true by construction, and the one durable notification per merge
is published only on that path.

WHAT IS NOT PORTED, AND WHY
GitLab, away-mode merge grants, merge-queue retry coaching and the captain-hold
interlock are all absent from this port (AGENTS.md section 14), so none of their
branches are here. A merge queue is still OBSERVED - that is what tells a queued
pull request from a landed one - it is simply not coached through.

.PARAMETER TaskId
The task whose pull request is being landed.

.PARAMETER PrUrl
The canonical https://<host>/<owner>/<repo>/pull/<number> URL. Copy it; never
compose one.

.PARAMETER Method
squash (the default), merge, or rebase. gh's own default is left unused so the
method is always a decision this command recorded, never one inherited.

.PARAMETER AllowRed
Waive named checks, by EXACT name, for this one merge. Requires
-AttendedOverride: waiving a red check is precisely the thing standing `yolo`
authority may not do, so it takes the switch that records a captain asked.

.PARAMETER AttendedOverride
Records that a captain asked for this concrete merge, re-enabling --auto,
--admin and --delete-branch in -ExtraArgument and permitting -AllowRed. It never
skips the live green check and never relaxes the head binding.

.PARAMETER ExtraArgument
Further arguments for `gh pr merge`, after the guarded ones above are refused.

.PARAMETER StateDir
Override the state directory. Defaults to this home's.

.EXAMPLE
Invoke-FmPrMerge -TaskId my-task -PrUrl https://github.com/o/r/pull/12
#>
function Invoke-FmPrMerge {
    # ConfirmImpact = 'High', the same as Invoke-FmMergeLocal: a captain calling
    # this directly is asked before anything lands on a default branch. The entry
    # point passes -Confirm:$false, because the approval that authorizes the
    # merge happened before the command was ever run.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TaskId,
        [Parameter(Mandatory, Position = 1)][string]$PrUrl,
        [ValidateSet('squash', 'merge', 'rebase')][string]$Method = 'squash',
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$AllowRed = @(),
        [switch]$AttendedOverride,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$ExtraArgument = @(),
        [string]$StateDir = ''
    )

    $null = Invoke-FmDeliveryGuard

    # Everything that can be judged without touching GitHub or the home is
    # judged first, so a mistyped argument costs no network call and writes
    # nothing.
    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id (allowed: A-Z a-z 0-9 . _ -, not starting with '.')"
    }
    $parts = Get-FmPrMergeUrlParts -Url $PrUrl
    if (-not $parts) {
        throw ("error: '$PrUrl' is not a canonical pull request URL " +
            '(expected https://<host>/<owner>/<repo>/pull/<number>); copy it from the worker or the task record rather than composing one')
    }
    $argumentRefusals = @(Test-FmPrMergeForgeArgument -Argument $ExtraArgument -AttendedOverride:$AttendedOverride)
    if ($argumentRefusals.Count -gt 0) { throw ($argumentRefusals -join "`n") }
    $waivers = @(@($AllowRed) | Where-Object { $_ })
    if ($waivers.Count -gt 0 -and -not $AttendedOverride) {
        throw ("error: -AllowRed needs -AttendedOverride: waiving a red check is the one thing standing yolo authority " +
            'cannot do, so it takes the switch that records a captain asked for this concrete merge')
    }

    # gh is a hard prerequisite, checked before any state is recorded: a merge
    # that cannot read GitHub must stop before it half-starts.
    if (-not (Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw ('error: gh is not on PATH, so the pull request state cannot be read; ' +
            'install it with ./install.ps1 or `winget install GitHub.cli`, then run `gh auth login`')
    }

    if (-not $StateDir) { $StateDir = (Get-FmSessionPaths).State }
    $metaPath = Get-FmMetaPath -StateDir $StateDir -TaskId $TaskId
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw "error: no meta for task $TaskId at $metaPath"
    }

    $mode = Get-FmMetaValue -Path $metaPath -Key 'mode'
    if ($mode -ne 'direct-PR') {
        throw ("error: task $TaskId is mode=$mode, not direct-PR; a local-only task lands with " +
            'bin/fm-merge-local.ps1 after approval, never through a pull request')
    }
    # The project checkout is not required - a pull request is merged on GitHub,
    # not in a working tree - but when the task records one, gh runs there so it
    # resolves the same host and credentials the project itself uses.
    $project = Get-FmMetaValue -Path $metaPath -Key 'project'
    $workingDirectory = if ($project -and (Test-Path -LiteralPath $project -PathType Container)) { $project } else { '' }
    # Standing authority is read from the task's own record rather than taken as
    # a parameter, so the notification cannot claim an authority the task never had.
    $authority = if ((Get-FmMetaValue -Path $metaPath -Key 'yolo') -eq 'on') { 'yolo' } else { 'attended' }

    # The control lock, exactly as Invoke-FmPromote takes it: two lifecycle
    # actions must never run against one task. Request-, not Wait-, so a second
    # one is REFUSED rather than silently queued behind the first.
    $controlLockPath = Get-FmDeliveryControlLockPath -StateDir $StateDir -TaskId $TaskId
    $control = $null
    try {
        $control = Request-FmLock -Path $controlLockPath -Role 'pr-merge'
    } catch {
        # The owner refuses re-entry by throwing, because a lock is per PROCESS.
        # For this command that IS the refusal; anything else is a real failure
        # and is rethrown, because "already running" must never stand in for
        # "the state directory is unwritable".
        if ($_.Exception.Message -notlike '*already holds the lock*') { throw }
    }
    if (-not $control) {
        throw "error: another lifecycle action is already running for task $TaskId; nothing was changed"
    }

    try {
        $recorded = Get-FmMetaValue -Path $metaPath -Key 'pr'
        if ($recorded -and $recorded -ne $parts.Url) {
            throw ("error: task $TaskId is already recorded against $recorded; " +
                "it cannot be re-pointed at $($parts.Url) here")
        }

        # The live read. Its two failure shapes are kept apart deliberately:
        # unreadable means fix the token or the network, refused means fix the
        # pull request, and one message for both sends half of them to the wrong
        # place.
        $verdict = Test-FmPrMergeReady -Url $parts.Url -AllowRed $waivers -WorkingDirectory $workingDirectory
        if ($verdict.Unreadable) { throw ($verdict.Refusals -join "`n") }

        # Recorded only once the pull request has been read, even when the read
        # refuses. A readable pull request is one that exists, so binding the
        # task to it is safe and makes the record useful to teardown whether or
        # not this merge goes ahead; an unreadable one could be a typo, and a
        # typo must not bind a task for good.
        if (-not $recorded) {
            $null = Invoke-FmWithLock -Path (Get-FmMetaLockPath -MetaPath $metaPath) -Role 'pr-merge' -ScriptBlock {
                Set-FmKeyValueField -Path $metaPath -Name 'pr' -Value $parts.Url -Confirm:$false
            }
        }

        if (-not $verdict.Ready) {
            $message = "error: refusing to merge $($parts.Url)`n" + ($verdict.Refusals -join "`n")
            if ($verdict.NotGreen.Count -gt 0) {
                $message += "`nerror: these checks are not green: " + ($verdict.NotGreen -join ', ')
            }
            throw $message
        }

        $target = "$($parts.Url) into $($verdict.Base) at head $($verdict.Head)"
        if (-not $PSCmdlet.ShouldProcess($target, "gh pr merge --$Method")) { return $null }

        # --match-head-commit is the whole point: between the read above and this
        # call a push can move the head, and gh then fails the merge instead of
        # landing commits nothing verified.
        $mergeArguments = @('pr', 'merge', $parts.Url, "--$Method", '--match-head-commit', $verdict.Head) + @($ExtraArgument | Where-Object { $_ })
        $call = @{ FilePath = 'gh'; ArgumentList = $mergeArguments }
        if ($workingDirectory) { $call['WorkingDirectory'] = $workingDirectory }
        $merge = Invoke-FmChildProcess @call
        $forgeText = (($merge.StdErr, $merge.StdOut) | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join "`n"

        if (-not $merge.Ok) {
            # gh's own words, kept raw and first. A merge refused by the forge is
            # a fact about the forge, and distilling it into a phrase of ours is
            # how the real reason gets lost.
            throw ("error: gh refused the merge of $($parts.Url) (exit $($merge.ExitCode))" +
                $(if ($forgeText) { "`n--- gh said ---`n$forgeText" } else { '' }))
        }

        # gh returning success is NOT the merge landing - it is also how an
        # accepted merge-queue entry and an armed auto-merge return. Only GitHub
        # can settle which happened.
        $outcome = Get-FmPrMergeOutcome -Parts $parts -WorkingDirectory $workingDirectory
        if ($null -eq $outcome) {
            throw ("error: gh accepted the merge of $($parts.Url) but GitHub's state could not be read back, " +
                'so whether it landed is unknown - check the pull request before doing anything else. ' +
                "The pull request is recorded against task $TaskId." +
                $(if ($forgeText) { "`n--- gh said ---`n$forgeText" } else { '' }))
        }
        if (-not $outcome.Merged) {
            $what = if ($outcome.Queued) {
                "it is in the merge queue, not merged - nothing has landed yet"
            } else {
                "GitHub reports state=$($outcome.State) and merged=false - nothing has landed"
            }
            throw ("error: gh accepted the merge of $($parts.Url) but $what." +
                $(if ($forgeText) { "`n--- gh said ---`n$forgeText" } else { '' }))
        }

        # Past this line GitHub has confirmed the merge, so the notification is
        # published and the object is returned - and both happen only here.
        #
        # The wake context is pinned to the SAME state directory the marker and
        # the task record live in. Without that the marker and the wake could
        # land in two different homes whenever -StateDir names one the ambient
        # environment does not, and the de-duplication would silently stop
        # de-duplicating anything.
        $notice = Publish-FmPrMergeOutcome -StateDir $StateDir -TaskId $TaskId -PrUrl $parts.Url `
            -Authority $authority -Context (Get-FmWakeContext -State $StateDir)
        $notified = if ($notice.AlreadyRecorded) { 'already-recorded' } elseif ($notice.Published) { 'published' } else { 'failed' }

        [pscustomobject]@{
            Merged        = $true
            TaskId        = $TaskId
            PrUrl         = $parts.Url
            Head          = $verdict.Head
            BaseBranch    = $verdict.Base
            Method        = $Method
            Waived        = $verdict.Waived
            Authority     = $authority
            Notified      = $notified
            Warning       = $notice.Reason
            QueueObserved = $outcome.QueueObserved
            Message       = ("merged $($parts.Url) into $($verdict.Base) by $Method at head $($verdict.Head); " +
                "GitHub confirms state=$($outcome.State)" +
                $(if ($verdict.Waived.Count -gt 0) { " (waived: $($verdict.Waived -join ', '))" } else { '' }))
        }
    } finally {
        # Released whatever happened, including a throw from the checks above: a
        # refused merge must never leave the task locked.
        $null = Unlock-FmLock -Lock $control -Confirm:$false
    }
}
