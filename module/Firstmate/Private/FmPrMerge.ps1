#requires -Version 7.0
<#
    Private/FmPrMerge.ps1 - the guarded GitHub landing path.

    The bash original is bin/fm-pr-merge.sh. That script is 1200 lines because
    it also carries GitLab, away-mode merge grants, merge-queue retry coaching
    and a captain-hold interlock. None of those four exist on this port
    (AGENTS.md section 14), so what is ported here is the part that makes the
    merge SAFE and the report TRUE, and nothing else:

      1. refuse unless the pull request is open, not a draft, mergeable, free of
         conflicts and green - read LIVE at merge time, never from the task
         record, because a record is a memory of a state that has since moved;
      2. bind the merge to the exact head that was verified, so a push landing
         between the read and the merge fails the merge instead of landing
         commits nothing checked;
      3. treat a red check run that a LATER green run of the same name replaced
         as green, because without that the gate refuses correct work and an
         operator learns to go round it;
      4. read GitHub back afterwards, so "merged" is only ever said when GitHub
         says so.

    Every one of the four is a live-read property. That is the whole design:
    this area holds no opinion it did not just ask GitHub for.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- the pull request's identity ----------------------------------------------

# Get-FmPrMergeUrlParts: a canonical pull-request URL, split.
#
# Teardown hands whole URLs to `gh pr view` and never splits them
# (Private/FmTeardown.ps1), which is the right idiom and is kept for every read
# gh's own URL handling covers. The split exists for the ONE read it does not:
# `gh api graphql` addresses a pull request by owner, name and number, and that
# query is the only way to see the merge queue.
#
# Strict on purpose. The merge is bound to this URL and the task record is
# written from it, so a URL that is nearly right must refuse rather than resolve
# to a neighbouring repository.
function Get-FmPrMergeUrlParts {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Url)

    if (-not $Url) { return $null }
    $trimmed = $Url.Trim().TrimEnd('/')
    $shape = '^https://(?<host>[A-Za-z0-9.-]+)/(?<owner>[A-Za-z0-9._-]+)/(?<repo>[A-Za-z0-9._-]+)/pull/(?<number>[1-9][0-9]*)$'
    if ($trimmed -notmatch $shape) { return $null }
    [pscustomobject]@{
        Url        = $trimmed
        HostName   = $Matches['host']
        Owner      = $Matches['owner']
        Repository = $Matches['repo']
        Number     = [int]$Matches['number']
    }
}

# --- the forge arguments a caller may not supply ------------------------------

# Two tiers, and the difference matters.
#
# NEVER: --repo/-R and --match-head-commit/--sha decide WHICH repository and
# WHICH commit the merge lands. Both come from the verified live read, and a
# caller-supplied override would defeat the exact binding this command exists to
# impose. No flag re-enables them - not even an attended one, because an
# attended caller who wants a different repository wants a different URL.
#
# ATTENDED-ONLY: --auto, --admin and --delete-branch/-d each break a promise
# this command otherwise keeps. --auto lands work at an unknown future head;
# --admin bypasses the branch protection the green check is speaking for;
# --delete-branch destroys the branch teardown verifies landed work against. An
# explicit captain instruction can still ask for one, which is what
# -AttendedOverride records.
#
# ONE TABLE, AND EVERY COMPARISON AGAINST IT IS CASE-SENSITIVE. That is
# load-bearing rather than tidy: gh's short flags are case-sensitive and `-r`
# (rebase) and `-R` (repo) are different flags. Held in a hashtable this guard
# refused an ordinary rebase merge with a message about the repository, because
# a PowerShell hash key matches case-INSENSITIVELY. Rows compared with -ceq
# cannot make that mistake, and the test below pins it.
# `Attended` is $true where -AttendedOverride re-enables the flag and $false
# where nothing does. `Short` is the bundled single letter, or empty.
$script:FmPrMergeGuardedArgs = @(
    [pscustomobject]@{ Long = '--repo'; Short = 'R'; Attended = $false
        Why                 = 'the repository comes from the pull request URL'
    }
    [pscustomobject]@{ Long = '--match-head-commit'; Short = ''; Attended = $false
        Why                 = 'the head comes from the verified live read'
    }
    [pscustomobject]@{ Long = '--sha'; Short = ''; Attended = $false
        Why                 = 'the head comes from the verified live read'
    }
    [pscustomobject]@{ Long = '--auto'; Short = ''; Attended = $true
        Why                 = 'auto-merge lands at a head nothing here verified'
    }
    [pscustomobject]@{ Long = '--admin'; Short = ''; Attended = $true
        Why                 = 'an administrator merge bypasses the protection the green check speaks for'
    }
    [pscustomobject]@{ Long = '--delete-branch'; Short = 'd'; Attended = $true
        Why                 = 'teardown verifies landed work against that branch'
    }
)

# gh's merge-method flags, in both spellings. -Method already selects one, so a
# second one in the extra arguments is an ambiguity, not an override.
$script:FmPrMergeMethodArgs = @('--squash', '-s', '--merge', '-m', '--rebase', '-r')

# Test-FmPrMergeForgeArgument: every refusal the caller's extra arguments earn.
# Returns the list, not the first one, because a caller fixing an argument list
# should see the whole list at once.
function Test-FmPrMergeForgeArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Argument,
        [switch]$AttendedOverride
    )

    $refusals = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @($Argument)) {
        if (-not $token) { continue }
        # `--repo=owner/name` is the same flag as `--repo owner/name`.
        $flag = $token
        $split = $token.IndexOf('=')
        if ($token.StartsWith('--') -and $split -gt 2) { $flag = $token.Substring(0, $split) }

        $guarded = @($script:FmPrMergeGuardedArgs |
                Where-Object { $_.Long -ceq $flag -or ($_.Short -and "-$($_.Short)" -ceq $flag) })
        if ($guarded.Count -gt 0) {
            $entry = $guarded[0]
            if (-not $entry.Attended) {
                $refusals.Add("error: $flag is not allowed here: $($entry.Why)")
            } elseif (-not $AttendedOverride) {
                $refusals.Add("error: $flag needs -AttendedOverride: $($entry.Why)")
            }
            continue
        }
        # -ccontains, for the same reason the table above is compared with -ceq.
        if ($script:FmPrMergeMethodArgs -ccontains $flag) {
            $refusals.Add("error: $flag is a merge method; pass it as -Method so only one method is ever selected")
            continue
        }
        # A short cluster: -sd is squash AND delete-branch. Only a single dash
        # followed by letters reaches here, so a negative number or a long flag
        # never does.
        if ($token -notmatch '^-[A-Za-z]{2,}$') { continue }
        foreach ($char in $token.Substring(1).ToCharArray()) {
            $letter = [string]$char
            $bundled = @($script:FmPrMergeGuardedArgs | Where-Object { $_.Short -ceq $letter })
            if ($bundled.Count -eq 0) { continue }
            $entry = $bundled[0]
            if (-not $entry.Attended) {
                $refusals.Add("error: $token bundles -$letter ($($entry.Long)), not allowed here: $($entry.Why)")
            } elseif (-not $AttendedOverride) {
                $refusals.Add("error: $token bundles -$letter ($($entry.Long)), which needs -AttendedOverride: $($entry.Why)")
            }
        }
    }
    # Not comma-wrapped: an empty refusal list must unroll to NOTHING, so that
    # `@(Test-FmPrMergeForgeArgument ...).Count` is 0 when there is nothing to
    # refuse. Wrapping it emits the empty array as one object instead, and the
    # caller then reads "no refusals" as one refusal.
    $refusals.ToArray()
}

# --- what makes a check green -------------------------------------------------

# Get-FmPrMergeSettledAt: a check run's timestamp as an ORDERABLE INSTANT, or
# $null when it is not one. $null makes a run ineligible to supersede anything
# and ineligible to be superseded, which is the fail-safe direction: nothing can
# be ordered against a time nobody can read.
#
# WHY THIS IS NOT A STRING TEST, which is how the bash does it. jq hands that
# script the raw JSON string, so it can test for an exact
# `YYYY-MM-DDTHH:MM:SSZ`. ConvertFrom-Json does not: it recognises an ISO-8601
# timestamp and hands back a [datetime] already, so the same shape test rejects
# EVERY REAL TIMESTAMP and the supersession rule silently never fires. Measured
# here before it shipped - `docs/windows-e2e-evidence.md` has the run.
#
# Sub-second precision is accepted, where the bash refuses it. A real instant is
# orderable whatever its precision, and comparing [datetime] values rather than
# fixed-width strings means the extra digits order correctly instead of having
# to be excluded to keep a string comparison honest.
function Get-FmPrMergeSettledAt {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter()][AllowNull()]$Value)

    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).UtcDateTime }
    # The string path, kept so this does not depend on any one parser having
    # done the conversion. UTC is asserted, not assumed from the machine.
    $text = [string]$Value
    if ($text -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$') { return $null }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
    [System.Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($text, [cultureinfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    $parsed
}

# Get-FmPrMergeCheckVerdict: which checks on this head are not green.
#
# THE SUPERSESSION RULE, which is the whole reason this is not a one-line
# filter. A re-run publishes a NEW check run under the SAME name beside the old
# one, and GitHub's rollup keeps both. Judging every run independently therefore
# reports a check as red for ever once it has failed once, and a gate that
# refuses green work is a gate an operator learns to bypass.
#
# So check runs are grouped by name and each GROUP is judged by its current
# state: a group with red runs is forgiven only when a green run of that name
# started strictly LATER than every one of its red runs. Four things
# deliberately refuse rather than forgive, because each one means "the later run
# is not evidence yet":
#   - no green run in the group carries a usable timestamp;
#   - a red run is still in flight (not COMPLETED), so it may yet be the last word;
#   - a red run carries no usable timestamp, so nothing can be ordered against it;
#   - the newest red is not older than the newest green, so the failure is current.
#
# Unnamed check runs are never grouped together - an empty name is not evidence
# that two runs are the same check - so each is its own group, keyed by position.
# Status contexts (the older commit-status API) have no runs to supersede one
# another and are judged by their single state.
function Get-FmPrMergeCheckVerdict {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$View)

    $rollup = Get-FmJsonValue -InputObject $View -Path 'statusCheckRollup'
    if ($null -eq $rollup -or $rollup -isnot [System.Array]) {
        # Not "no checks" - unreadable. A pull request with no checks at all
        # answers with an empty ARRAY, which is green and reaches the loop below.
        return [pscustomobject]@{ Readable = $false; NotGreen = @() }
    }

    $notGreen = [System.Collections.Generic.List[string]]::new()
    $groups = [ordered]@{}
    $index = -1
    foreach ($entry in $rollup) {
        $index++
        if (([string](Get-FmJsonValue -InputObject $entry -Path '__typename')) -ne 'CheckRun') {
            # A status context, and anything the rollup grows later: one state,
            # no runs, so a state that is not SUCCESS is simply not green.
            if (([string](Get-FmJsonValue -InputObject $entry -Path 'state')) -eq 'SUCCESS') { continue }
            $context = [string](Get-FmJsonValue -InputObject $entry -Path 'context')
            $notGreen.Add($(if ($context) { $context } else { '(unnamed check)' }))
            continue
        }

        $name = [string](Get-FmJsonValue -InputObject $entry -Path 'name')
        $completed = ([string](Get-FmJsonValue -InputObject $entry -Path 'status')) -eq 'COMPLETED'
        $conclusion = [string](Get-FmJsonValue -InputObject $entry -Path 'conclusion')
        $key = if ($name) { "name`u{001c}$name" } else { "index`u{001c}$index" }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{ Name = $name; Runs = [System.Collections.Generic.List[object]]::new() }
        }
        $groups[$key].Runs.Add([pscustomobject]@{
                # NEUTRAL and SKIPPED are green: a check that deliberately did
                # not apply to this change has not failed it.
                Ok        = ($completed -and $conclusion -in @('SUCCESS', 'NEUTRAL', 'SKIPPED'))
                Completed = $completed
                At        = (Get-FmPrMergeSettledAt -Value (Get-FmJsonValue -InputObject $entry -Path 'startedAt'))
            })
    }

    foreach ($key in $groups.Keys) {
        $group = $groups[$key]
        $reds = @($group.Runs | Where-Object { -not $_.Ok })
        if ($reds.Count -eq 0) { continue }

        $newestGreen = $null
        foreach ($run in $group.Runs) {
            if (-not $run.Ok -or $null -eq $run.At) { continue }
            if ($null -eq $newestGreen -or $run.At -gt $newestGreen) { $newestGreen = $run.At }
        }

        $superseded = ($null -ne $newestGreen)
        if ($superseded) {
            foreach ($red in $reds) {
                if (-not $red.Completed -or $null -eq $red.At -or $red.At -ge $newestGreen) {
                    $superseded = $false
                    break
                }
            }
        }
        if ($superseded) { continue }
        $notGreen.Add($(if ($group.Name) { $group.Name } else { '(unnamed check)' }))
    }

    [pscustomobject]@{ Readable = $true; NotGreen = $notGreen.ToArray() }
}

# --- the live pre-merge read --------------------------------------------------

# Get-FmPrMergeLiveView: ONE `gh pr view`, supplying every field the preflight
# judges. One read, not six, so every condition is judged against the same
# instant - a second read could see a different head from the one the checks
# were read for, which is exactly the race the head binding exists to close.
function Get-FmPrMergeLiveView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$WorkingDirectory = ''
    )
    $call = @{
        FilePath     = 'gh'
        ArgumentList = @('pr', 'view', $Url, '--json',
            'state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,statusCheckRollup')
    }
    if ($WorkingDirectory) { $call['WorkingDirectory'] = $WorkingDirectory }
    $result = Invoke-FmChildProcess @call
    if (-not $result.Ok) { return $null }
    ConvertFrom-FmJsonSafe -Text $result.StdOut
}

# Test-FmPrMergeReady: every pre-merge condition, read live, reported together.
#
# Returned as a verdict rather than thrown, so the same checks can be reported
# (a preflight, a test) and enforced (the merge) - the shape
# Test-FmMergeLocalReady already established for the local path.
#
# TWO OUTCOMES, NOT ONE. `Unreadable` says the state could not be read at all;
# `Refusals` says it was read and is wrong. The operator's next action differs -
# fix the network or the token, versus fix the pull request - and collapsing
# them sends half of them to the wrong place.
#
# Every failing condition is reported, not just the first, because a pull
# request that is both a draft and red costs two round trips to learn that way.
function Test-FmPrMergeReady {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$AllowRed = @(),
        [string]$WorkingDirectory = ''
    )

    $unreadable = {
        param($Detail)
        [pscustomobject]@{
            Ready      = $false
            Unreadable = $true
            Refusals   = @("error: could not read the GitHub pull request state before merging $Url ($Detail)")
            NotGreen   = @()
            Waived     = @()
            Head       = ''
            Base       = ''
        }
    }

    $view = Get-FmPrMergeLiveView -Url $Url -WorkingDirectory $WorkingDirectory
    if ($null -eq $view) { return & $unreadable 'gh could not report it' }

    $head = [string](Get-FmJsonValue -InputObject $view -Path 'headRefOid')
    $base = [string](Get-FmJsonValue -InputObject $view -Path 'baseRefName')
    # The head and the base branch are not conditions to refuse over - they are
    # what the refusal and the merge are ABOUT. Without either, nothing was read
    # well enough to judge, let alone to bind a merge to.
    if ($head -notmatch '^[0-9a-f]{7,64}$') { return & $unreadable 'no usable head commit in the answer' }
    if (-not $base) { return & $unreadable 'no base branch in the answer' }

    $checks = Get-FmPrMergeCheckVerdict -View $view
    if (-not $checks.Readable) { return & $unreadable 'no check rollup in the answer' }

    $refusals = [System.Collections.Generic.List[string]]::new()
    $state = [string](Get-FmJsonValue -InputObject $view -Path 'state')
    if ($state.ToUpperInvariant() -ne 'OPEN') {
        $refusals.Add("  - state is `"$(if ($state) { $state } else { 'unreadable' })`", not open")
    }
    $draft = Get-FmJsonValue -InputObject $view -Path 'isDraft'
    if ($draft -isnot [bool]) {
        $refusals.Add('  - isDraft is unreadable, so whether this is a draft is unknown')
    } elseif ($draft) {
        $refusals.Add('  - the pull request is a draft')
    }
    $mergeable = [string](Get-FmJsonValue -InputObject $view -Path 'mergeable')
    if ($mergeable -ne 'MERGEABLE') {
        $refusals.Add("  - mergeable is `"$(if ($mergeable) { $mergeable } else { 'unreadable' })`", not MERGEABLE")
    }
    if (([string](Get-FmJsonValue -InputObject $view -Path 'mergeStateStatus')) -eq 'DIRTY') {
        $refusals.Add('  - mergeStateStatus is DIRTY (conflicts)')
    }

    $uncovered = [System.Collections.Generic.List[string]]::new()
    $waived = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $checks.NotGreen) {
        # Exact name only. A prefix or a pattern would waive checks nobody
        # named, which is how one waiver becomes a standing one.
        if (@($AllowRed) -contains $name) { $waived.Add($name); continue }
        $uncovered.Add($name)
        $refusals.Add("  - check '$name' is not green")
    }

    [pscustomobject]@{
        Ready      = ($refusals.Count -eq 0)
        Unreadable = $false
        Refusals   = $refusals.ToArray()
        NotGreen   = $uncovered.ToArray()
        Waived     = $waived.ToArray()
        Head       = $head
        Base       = $base
    }
}

# --- reading GitHub back ------------------------------------------------------

# The GraphQL query is the only read that can tell a LANDED pull request from
# one sitting in a merge queue: `gh pr view --json` publishes no isInMergeQueue
# field (checked against gh 2.97). That distinction is the point - a queued pull
# request has not merged, and reporting it as merged is the exact untruth this
# whole command exists to prevent.
$script:FmPrMergeOutcomeQuery = 'query($owner:String!,$repo:String!,$number:Int!)' +
'{repository(owner:$owner,name:$repo){pullRequest(number:$number){state merged isInMergeQueue}}}'

function Get-FmPrMergeOutcomeWithGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Parts,
        [string]$WorkingDirectory = ''
    )
    $call = @{
        FilePath     = 'gh'
        ArgumentList = @('api', 'graphql', '--hostname', $Parts.HostName,
            '-f', "query=$($script:FmPrMergeOutcomeQuery)",
            '-F', "owner=$($Parts.Owner)", '-F', "repo=$($Parts.Repository)", '-F', "number=$($Parts.Number)")
    }
    if ($WorkingDirectory) { $call['WorkingDirectory'] = $WorkingDirectory }
    $result = Invoke-FmChildProcess @call
    if (-not $result.Ok) { return $null }

    $pr = Get-FmJsonValue -InputObject (ConvertFrom-FmJsonSafe -Text $result.StdOut) -Path 'data.repository.pullRequest'
    if ($null -eq $pr) { return $null }
    $merged = Get-FmJsonValue -InputObject $pr -Path 'merged'
    $queued = Get-FmJsonValue -InputObject $pr -Path 'isInMergeQueue'
    $state = [string](Get-FmJsonValue -InputObject $pr -Path 'state')
    # A partial answer is no answer: an absent `merged` read as $false would turn
    # a landed merge into a refusal, and the queue flag decides which of two very
    # different reports the caller gives.
    if ($merged -isnot [bool] -or $queued -isnot [bool] -or -not $state) { return $null }

    [pscustomobject]@{
        Merged        = $merged
        Queued        = $queued
        QueueObserved = $true
        State         = $state
        Source        = 'graphql'
    }
}

# The degradation path, and it degrades in one direction only. `gh pr view`
# reaches a different endpoint, so it can answer when the GraphQL call is
# blocked - but it cannot see the merge queue, so a "not merged" from it is an
# INCOMPLETE answer, not a negative one. It is therefore accepted only when it
# proves a merge, and every other result falls through to the caller's refusal.
#
# gh-axi is deliberately not a third read. It is the same question asked of a
# wrapper around the same binary, in a text format this port would have to parse
# by shape, and it covers no failure the two reads above do not.
function Get-FmPrMergeOutcomeWithView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Parts,
        [string]$WorkingDirectory = ''
    )
    $call = @{ FilePath = 'gh'; ArgumentList = @('pr', 'view', $Parts.Url, '--json', 'state') }
    if ($WorkingDirectory) { $call['WorkingDirectory'] = $WorkingDirectory }
    $result = Invoke-FmChildProcess @call
    if (-not $result.Ok) { return $null }

    $state = [string](Get-FmJsonValue -InputObject (ConvertFrom-FmJsonSafe -Text $result.StdOut) -Path 'state')
    if ($state.ToUpperInvariant() -ne 'MERGED') { return $null }
    [pscustomobject]@{
        Merged        = $true
        Queued        = $false
        QueueObserved = $false
        State         = 'MERGED'
        Source        = 'view'
    }
}

# Get-FmPrMergeOutcome: what GitHub says happened. $null means it would not say,
# which the caller must report as loudly as a failure - the merge may well have
# landed, and an unread outcome is the one case where saying nothing is worse
# than saying too much.
function Get-FmPrMergeOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Parts,
        [string]$WorkingDirectory = ''
    )
    $outcome = Get-FmPrMergeOutcomeWithGraph -Parts $Parts -WorkingDirectory $WorkingDirectory
    if ($null -ne $outcome) { return $outcome }
    Get-FmPrMergeOutcomeWithView -Parts $Parts -WorkingDirectory $WorkingDirectory
}

# --- one durable notification per verified merge ------------------------------

# state/<id>.pr-merge-notified: the pull request URLs this task has already
# reported as merged, one per line.
#
# THE WAKE QUEUE IS NOT ENOUGH BY ITSELF. Its own de-duplication is by
# (kind, key) among records still QUEUED (Get-FmWakeDedupedRecords), so once a
# handling turn acknowledges the record the key is free again and a second
# publication would wake the captain a second time for the same merge. The
# marker is what makes "once" mean once for good.
function Get-FmPrMergeNotifyPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir "$TaskId.pr-merge-notified"
}

function Get-FmPrMergeNotifyLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    Join-Path $StateDir ".pr-merge-notified-$TaskId.lock"
}

# Publish-FmPrMergeOutcome: tell the captain, once, that this merge landed.
#
# PUBLISHED BEFORE THE MARKER IS WRITTEN, deliberately. A crash between the two
# leaves the merge eligible to be reported again, which costs a duplicate line;
# the other order would leave a landed merge silent for ever. Between a
# duplicate and a silence, the duplicate is the one a captain can correct.
function Publish-FmPrMergeOutcome {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    # PrUrl and Context are both read, but only from inside the script block
    # handed to Invoke-FmWithLock, which this rule does not follow into. Taking
    # the lock by hand to satisfy it would trade the owner's release-on-throw
    # guarantee for a warning.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PrUrl',
        Justification = 'Read inside the Invoke-FmWithLock script block, which the rule does not follow into.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Context',
        Justification = 'Read inside the Invoke-FmWithLock script block, which the rule does not follow into.')]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$PrUrl,
        [ValidateSet('attended', 'yolo')][string]$Authority = 'attended',
        [hashtable]$Context
    )

    $marker = Get-FmPrMergeNotifyPath -StateDir $StateDir -TaskId $TaskId
    # Only a standing authority is tagged. An attended merge needs no tag: the
    # captain who authorized it is the one reading the line.
    $suffix = if ($Authority -eq 'attended') { '' } else { " $Authority" }

    return (Invoke-FmWithLock -Path (Get-FmPrMergeNotifyLockPath -StateDir $StateDir -TaskId $TaskId) `
            -Role 'pr-merge-notify' -ScriptBlock {
            if ((Test-Path -LiteralPath $marker -PathType Leaf) -and
                (@([System.IO.File]::ReadAllLines($marker)) -contains $PrUrl)) {
                return [pscustomobject]@{ Published = $false; AlreadyRecorded = $true; Reason = '' }
            }

            $wake = @{
                Kind    = 'check'
                Key     = "merged-$TaskId-$PrUrl"
                Payload = "check: merge landed: $TaskId $PrUrl$suffix"
            }
            if ($Context) { $wake['Context'] = $Context }
            if (-not (Add-FmWake @wake)) {
                return [pscustomobject]@{
                    Published = $false; AlreadyRecorded = $false
                    Reason    = "error: the merge landed but its wake record could not be queued for task $TaskId"
                }
            }
            try {
                Add-FmTextLineLf -Path $marker -Line $PrUrl
            } catch {
                # The captain HAS been told. A failed marker only risks telling
                # them twice, so it is a warning, never a failed merge.
                return [pscustomobject]@{
                    Published = $true; AlreadyRecorded = $false
                    Reason    = "warning: merge reported but not marked as reported ($($_.Exception.Message)); it may be reported again"
                }
            }
            [pscustomobject]@{ Published = $true; AlreadyRecorded = $false; Reason = '' }
        })
}
