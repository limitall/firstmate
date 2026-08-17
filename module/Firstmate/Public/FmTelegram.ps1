#requires -Version 7.0
# Public/FmTelegram.ps1 - the private Telegram channel's exported verbs.
#
# WHAT THIS IS. A private bot chat between firstmate and the captain: outbound,
# so an escalation reaches their phone instead of waiting for them to be at the
# machine, and inbound while a session is alive, so they can ask how things stand
# and hand out work from anywhere. Private/FmTelegram.ps1 owns the mechanics and
# the rules that must not be discovered by editing; docs/telegram-windows.md owns
# the design and what it deliberately does not do.
#
# THE CHANNEL IS A COURIER, NOT A PIPE. A message about a specific piece of work is
# resolved to that work and the decision is written down; firstmate hands it over
# through the ordinary steer path, and the answer comes back from the worker's own
# status stream, translated, quoted against the question that asked for it. Nothing
# here types into a worker's pane and nothing here lets a worker's words reach the
# captain as the worker wrote them - crewmates never address the captain, and every
# message in both directions passes through firstmate.
#
# THIS SHIPS INERT. There is no bot and no token, so every verb here answers
# "off" and changes nothing. Creating the bot mints a credential on a third-party
# service and accepts that firstmate's outbound messages rest on Telegram's
# servers, which is the captain's decision to make and theirs alone.
#
# NOTHING HERE IS WIRED INTO THE ESCALATION PATH, deliberately. Turning this on
# must be a thing the captain does, not a thing that happens to them.

Set-StrictMode -Version Latest

function Send-FmTelegramMessage {
    <#
        .SYNOPSIS
        Send one message to the captain's phone. Never throws.

        .DESCRIPTION
        One HTTPS POST. No service, no poller, no queue.

        SILENT WHEN UNCONFIGURED. With no bot token or no allowlist this returns
        `Sent = $false, Reason = 'off'` and does nothing else, so a home that has
        never set the channel up carries no cost for it existing.

        SENT MEANS THE API CONFIRMED IT. About one call in ten from this machine
        hangs until its timeout rather than failing, so a call that merely
        returned proves nothing; only `ok: true` is delivery. Transport failures
        and timeouts are retried within the bound, an API refusal is not - a 400
        or a 401 will refuse identically however many times it is asked.

        NEVER THROWS AND NEVER EXITS NON-ZERO. This is called from supervision
        paths, where a turn must not end because a laptop is on a train.

        PLAIN TEXT, NO parse_mode. MarkdownV2 needs arbitrary characters escaped -
        a branch name with an underscore returns 400 - and an escalation that
        returns 400 is an escalation that never arrived. Plain text cannot fail
        that way, and section 9 wants prose rather than decoration anyway.

        THE MESSAGE IS TRANSLATED AND BOUNDED before it goes: see
        Get-FmTelegramMessageText. Over-long is truncated visibly, never silently
        and never by the API rejecting it.

        .PARAMETER Message
        What to say, in the captain's nouns - the outcome, the consequence, the
        decision. Full https:// URLs, never a bare PR number: a number is not
        tappable on a phone.

        .PARAMETER FirstmateHome
        Read the channel's configuration from this home instead of the resolved
        one.

        .PARAMETER TimeoutSeconds
        Hard bound on one attempt. A failing call to this API is a hang, not an
        error, so this is what stops a wedge.

        .PARAMETER Retries
        Extra attempts after the first, for a timeout or an unreachable endpoint
        only.

        .OUTPUTS
        [pscustomobject] with Sent, Reason (sent, off, empty, timeout,
        unreachable, refused, unavailable), Truncated, Attempts, Detail and
        Warning. Detail carries only the API's error_code and description - never
        the request, which holds the token.

        .EXAMPLE
        Send-FmTelegramMessage 'Captain, the sign-in fix is ready for your review. https://github.com/acme/app/pull/482'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [string]$FirstmateHome = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20,
        [ValidateRange(0, 10)][int]$Retries = 2
    )

    $result = [pscustomobject]@{
        Sent      = $false
        Reason    = 'off'
        Truncated = $false
        Attempts  = 0
        Detail    = ''
        Warning   = ''
    }

    try {
        $homeArgs = @{}
        if ($FirstmateHome) { $homeArgs['HomePath'] = $FirstmateHome }
        $credential = Get-FmTelegramCredential @homeArgs
        $result.Warning = $credential.Warning
        if (-not $credential.Token -or $credential.Allow.Count -eq 0) { return $result }

        $bounded = Get-FmTelegramMessageText -Message $Message
        $result.Truncated = $bounded.Truncated
        if (-not $bounded.Text) {
            $result.Reason = 'empty'
            return $result
        }

        # The composed URL carries the token and never leaves this scope.
        $url = '{0}/bot{1}/sendMessage' -f (Get-FmTelegramApiBase), $credential.Token
        $body = [ordered]@{
            chat_id                  = $credential.Allow[0]
            text                     = $bounded.Text
            disable_web_page_preview = $true
        } | ConvertTo-Json -Compress

        $attempts = $Retries + 1
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            $answer = Invoke-FmTelegramApi -Url $url -BodyJson $body -TimeoutSeconds $TimeoutSeconds
            $result.Attempts = $attempt
            $result.Reason = $answer.Reason
            $result.Detail = $(if ($answer.ErrorCode) { "$($answer.ErrorCode) $($answer.Description)" }
                else { $answer.Description })
            if ($answer.Ok) {
                $result.Sent = $true
                $result.Reason = 'sent'
                $result.Detail = ''
                return $result
            }
            # An answered refusal is permanent for this message; only a call that
            # never got an answer is worth asking again.
            if ($answer.Reason -notin @('timeout', 'unreachable')) { return $result }
            if ($attempt -lt $attempts) { Start-Sleep -Milliseconds 700 }
        }
        return $result
    } catch {
        # The backstop. Every seam below already answers instead of throwing, and
        # the one thing this function may never do is end its caller's turn.
        # The error record is NOT reported: it can carry the request URI, and the
        # request URI carries the bot token.
        $result.Sent = $false
        $result.Reason = 'unavailable'
        $result.Detail = "the message could not be sent ($($_.Exception.GetType().Name))"
        return $result
    }
}

function Test-FmTelegramCommand {
    <#
        .SYNOPSIS
        May this channel carry that message? A verdict, never a boolean.

        .DESCRIPTION
        Three tiers, from data/tg-bridge/report.md section 9:

          1. Read and report - how things stand, what is waiting. Always allowed.
          2. Dispatch, steer, answer a decision. Allowed by default; every one is
             reversible and the worst case is wasted work in a disposable copy.
          3. Land work, throw work away, delete, clean up for good, anything
             irreversible, anything touching a login. REFUSED, and the refusal
             is in the code path.

        WHY THE CEILING CANNOT BE CONFIGURED UP. Tier 3 is the exact set where a
        lost phone or a leaked token becomes damage nobody can undo, and the exact
        set AGENTS.md's precedence rule already requires the captain to state
        concretely and in person. config/telegram-authority can narrow this
        channel to tier 1; a file that is missing, corrupted, or edited to say 3
        cannot widen it, because Get-FmTelegramAuthorityCeiling is a constant in
        the code rather than a default in the reader.

        A REFUSAL IS ALWAYS SPOKEN. Message carries what was refused and why, in
        the captain's nouns - a refusal they never see is indistinguishable from a
        channel that broke.

        .PARAMETER Text
        The inbound message, as sent.

        .PARAMETER MaxTier
        The highest tier to allow. Clamped to the ceiling regardless.

        .OUTPUTS
        [pscustomobject] with Allowed, Tier, Action, Reason and Message.

        .EXAMPLE
        (Test-FmTelegramCommand -Text 'merge the payments branch').Allowed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [int]$MaxTier = 2
    )

    # THE CLAMP IS HERE, in the path every caller goes through, and not in the
    # config reader alone. A second caller that read the file itself, or one that
    # passed a number straight through, would otherwise be able to widen what the
    # configuration file is not allowed to widen.
    $ceiling = Get-FmTelegramAuthorityCeiling
    $limit = $MaxTier
    if ($limit -gt $ceiling) { $limit = $ceiling }
    if ($limit -lt 1) { $limit = 1 }

    $tier = Get-FmTelegramCommandTier -Text $Text
    $allowed = ($tier.Tier -le $limit)
    return [pscustomobject]@{
        Allowed = $allowed
        Tier    = $tier.Tier
        Action  = $tier.Action
        Reason  = $tier.Reason
        Message = $(if ($allowed) { '' } else { Get-FmTelegramRefusalMessage -Tier $tier.Tier -Action $tier.Action })
    }
}

function Resolve-FmTelegramDecision {
    <#
        .SYNOPSIS
        Close an open decision with the captain's answer. The closure the wake
        drain has always printed a command for and never had.

        .DESCRIPTION
        THE PROBLEM THIS SOLVES. The drain tells firstmate to close a decision
        with a flag bin/fm-send.ps1 does not have, and that entry point ends its
        parameter block with a remaining-arguments list, so the flag is not
        refused - it is absorbed into the message body. Run as printed, it sends
        the worker the literal text of the flag and closes nothing. Answering a
        decision is the most valuable thing the captain can do from a phone, and
        it routed through exactly that.

        WHAT CLOSING MEANS. A needs-decision or blocked line OPENS a keyed
        decision in a task's own durable stream, and only a resolved line carrying
        the SAME key closes it. So this appends

            resolved [key=<key>]: <the captain's answer, verbatim>

        through Add-FmTaskStatus, which is the one owner of that grammar. That
        append is also a status write, so firstmate is notified and reads the
        answer on its next turn - the answer is never only a closure.

        WHEN IT WILL NOT GUESS. With -Key, it closes exactly that key or reports
        that it is not open. Without one, it closes the single open decision when
        there is exactly one, and REFUSES when there are several: closing the
        wrong question would be a silent, wrong answer, and a captain told "there
        is more than one waiting" can settle it in one more message.

        .PARAMETER Answer
        The captain's words, recorded verbatim as the resolution note.

        .PARAMETER FirstmateHome
        Fold this home's decisions instead of the resolved one's.

        .PARAMETER Key
        Close this exact decision key.

        .OUTPUTS
        [pscustomobject] with Closed, Task, Key, Reason (closed, none, ambiguous,
        unknown-key, empty, unavailable), Question (the closed or ambiguous
        question in plain English) and Open (the still-open questions when
        ambiguous).

        .EXAMPLE
        Resolve-FmTelegramDecision -Answer 'use the flat one' -Key api-shape
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Answer,
        [string]$FirstmateHome = '',
        [AllowEmptyString()][string]$Key = ''
    )

    $result = [pscustomobject]@{
        Closed   = $false
        Task     = ''
        Key      = ''
        Reason   = 'none'
        Question = ''
        Open     = @()
    }

    $note = ("$Answer" -replace '\s+', ' ').Trim()
    if (-not $note) {
        $result.Reason = 'empty'
        return $result
    }

    try {
        $stateArgs = @{}
        if ($FirstmateHome) { $stateArgs['HomePath'] = $FirstmateHome }
        $stateDir = Get-FmStateRoot @stateArgs
        # NOT @(Get-FmOpenDecisionScan ...): the scan returns its list behind a
        # unary comma so an empty result cannot unroll away, and wrapping it again
        # turns "nothing is open" into one nameless record - which this function
        # would then try to close.
        $open = Get-FmOpenDecisionScan -StatePath $stateDir
        if ($open.Count -eq 0) { return $result }

        $target = $null
        if ($Key) {
            $target = @($open | Where-Object { $_.Key -eq $Key }) | Select-Object -First 1
            if (-not $target) {
                $result.Reason = 'unknown-key'
                $result.Key = $Key
                $result.Open = @($open | ForEach-Object { ConvertTo-FmBridgePlainText -Text $_.Note })
                return $result
            }
        } elseif ($open.Count -eq 1) {
            $target = $open[0]
        } else {
            $result.Reason = 'ambiguous'
            $result.Open = @($open | ForEach-Object { ConvertTo-FmBridgePlainText -Text $_.Note })
            return $result
        }

        $null = Add-FmTaskStatus -StateDir $stateDir -TaskId $target.Task -State 'resolved' `
            -Key $target.Key -Note $note -Confirm:$false
        $result.Closed = $true
        $result.Task = $target.Task
        $result.Key = $target.Key
        $result.Reason = 'closed'
        $result.Question = ConvertTo-FmBridgePlainText -Text $target.Note
        return $result
    } catch {
        $result.Closed = $false
        $result.Reason = 'unavailable'
        return $result
    }
}

function Resolve-FmTelegramWorker {
    <#
        .SYNOPSIS
        Which piece of live work one phone message is about. Asks rather than
        guesses.

        .DESCRIPTION
        A PHONE MESSAGE DOES NOT NAME AN IDENTIFIER, AND SHOULD NOT HAVE TO. The
        captain writes "how is the sign-in fix going", so this resolves against
        what actually exists: every dispatched piece of work that is not over, what
        each of them last said, and which one was most recently talked about.

        WHAT COUNTS AS EVIDENCE, strongest first.

          1. The message names the work outright. Worth ten, because a captain who
             quoted the name back means that one.
          2. A word shared with the work's own name or its project. Worth three.
          3. A word shared with its last report. Worth one - a report is whatever
             the worker typed this minute, not what the work is called.

          A hyphen is not a boundary here: "sign-in" and a piece of work named
          "fix-signin" match, because each side also offers its joined-up form.

        WHEN IT REFUSES TO PICK. A tie between the best two candidates is
        ambiguous, and so is a message that matches nothing while several pieces of
        work are running. Both come back with Reason 'ambiguous' and a Question
        already written in the captain's nouns, because a steer delivered to the
        wrong worker is worse than a question asked - and worse invisibly, since the
        captain gets a confident acknowledgement either way.

        THE TWO CASES THAT ARE NOT AMBIGUITY.

          A message that asks for work to START names nothing because there is
          nothing yet to name. It comes back 'none' rather than asking which
          existing work "have someone look at the checkout page" meant.

          A message that matches nothing while exactly ONE piece of work is running
          is about that one; there is nothing else it could be.

        THE RECENCY FALLBACK. "Any news?" identifies nothing on its own, so where
        the durable routing record shows the last message went somewhere that is
        still live, this follows it. That is what makes a conversation possible at
        all, and it is used ONLY when nothing matched by name.

        This decides; it delivers nothing. Handing the message to the worker is
        firstmate's, through the ordinary steer path, because all crewmate
        communication flows through firstmate.

        .PARAMETER Text
        The inbound message, as sent.

        .PARAMETER FirstmateHome
        Resolve against this home's live work instead of the resolved one's.

        .OUTPUTS
        [pscustomobject] with Task (the id, for firstmate - never for the captain),
        Label (the plain-English name), Reason (routed, ambiguous, none,
        unavailable), Evidence (name, report, only-one, recent), Score, Question
        and Candidate.

        .EXAMPLE
        (Resolve-FmTelegramWorker -Text 'how is the sign-in fix going').Label
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [string]$FirstmateHome = ''
    )

    $result = [pscustomobject]@{
        Task      = ''
        Label     = ''
        Reason    = 'none'
        Evidence  = ''
        Score     = 0
        Question  = ''
        Candidate = @()
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $result }

        $stateArgs = @{}
        if ($FirstmateHome) { $stateArgs['HomePath'] = $FirstmateHome }
        $stateDir = Get-FmStateRoot @stateArgs

        $live = Get-FmTelegramLiveWork -StateDir $stateDir
        if ($live.Count -eq 0) { return $result }
        $result.Candidate = @($live | ForEach-Object { [pscustomobject]@{ Task = $_.Task; Label = $_.Label } })

        $said = Get-FmTelegramRouteWord -Text $Text
        $newWork = Test-FmTelegramAsksForNewWork -Text $Text
        $scored = @()
        foreach ($work in $live) {
            $score = 0
            $named = 0
            foreach ($word in $said) {
                if (-not $work.Weight.ContainsKey($word)) { continue }
                $score += $work.Weight[$word]
                # Tracked apart from the total because the two answer different
                # questions. A word shared with the work's NAME says the captain
                # means this work; a word shared with its last report only says the
                # two are talking about similar things - and "look at the pricing
                # page" shares "page" with a worker profiling the cart page while
                # naming nothing at all.
                if ($work.Weight[$word] -ge 3) { $named += $work.Weight[$word] }
            }
            # Naming the work outright outranks every accumulation of shared words:
            # a captain who quoted the name back has told us which one. Both forms
            # are checked, because the word split never yields a hyphenated name
            # whole - it offers the joined-up form instead, and testing only the
            # literal one would leave the strongest signal unreachable for every
            # multi-word name, which is most of them.
            $whole = $work.Task.ToLowerInvariant()
            $joined = ($whole -replace '[-_]+', '')
            if ($said -contains $whole -or $said -contains $joined) {
                $score += 10
                $named += 10
            }
            $scored += [pscustomobject]@{ Work = $work; Score = $score; Named = $named }
        }
        $ranked = @($scored | Sort-Object -Property Score -Descending)
        $best = $ranked[0]
        $runnerUp = if ($ranked.Count -gt 1) { $ranked[1].Score } else { -1 }

        # An instruction to begin something needs the work named, not merely
        # brushed against. Otherwise "have someone look at the pricing page" lands
        # on whichever running worker last mentioned a page.
        $strong = if ($newWork) { $best.Named -gt 0 } else { $best.Score -gt 0 }

        if ($strong -and $best.Score -gt $runnerUp) {
            $result.Task = $best.Work.Task
            $result.Label = $best.Work.Label
            $result.Score = $best.Score
            $result.Reason = 'routed'
            $result.Evidence = $(if ($best.Named -gt 0) { 'name' } else { 'report' })
            return $result
        }

        if ($best.Score -le 0 -or -not $strong) {
            # Nothing was named. An instruction to begin something has no existing
            # target to resolve, so there is nothing to ask about either.
            if ($newWork) { return $result }

            if ($live.Count -eq 1) {
                $result.Task = $live[0].Task
                $result.Label = $live[0].Label
                $result.Reason = 'routed'
                $result.Evidence = 'only-one'
                return $result
            }

            $recent = Get-FmTelegramRecentRoute -StateDir $stateDir
            if ($recent) {
                $match = @($live | Where-Object { $_.Task -eq $recent }) | Select-Object -First 1
                if ($match) {
                    $result.Task = $match.Task
                    $result.Label = $match.Label
                    $result.Reason = 'routed'
                    $result.Evidence = 'recent'
                    return $result
                }
            }
        }

        $result.Reason = 'ambiguous'
        $result.Question = Get-FmTelegramAmbiguityQuestion -Candidate $result.Candidate
        return $result
    } catch {
        # This sits between the captain asking something and firstmate answering,
        # so it answers with a reason rather than ending its caller.
        $result.Task = ''
        $result.Reason = 'unavailable'
        return $result
    }
}

function Get-FmTelegramRoute {
    <#
        .SYNOPSIS
        The routing record, folded: which phone messages went where, and which of
        them their worker has since answered.

        .DESCRIPTION
        WHY THIS IS RECORDED AT ALL. A reply arriving with no memory of what it
        answers is how a captain gets told the wrong thing - confidently, and with
        no way to see it happened. So the moment a message is resolved to a piece of
        work, that decision is written down along with how many reports that worker
        had already made; the answer is whatever it says after that boundary.

        THE FOLD. A `routed` record opens one routing and an `answered` record
        carrying the same id closes it, the same shape a keyed decision uses in a
        status stream. Nothing is rewritten in place, so the record is a history
        rather than a current value.

        PURE READ. It sends nothing and closes nothing, so firstmate can look at
        what is outstanding without that look becoming an action.

        ASSIGN THE RESULT BEFORE WRAPPING IT. The list comes back behind a unary
        comma so an empty record cannot unroll away; `@(Get-FmTelegramRoute)` on an
        empty one yields a single nameless element that the next property read
        throws on under strict mode. Assign, then filter or wrap.

        .PARAMETER FirstmateHome
        Read this home's record instead of the resolved one's.

        .PARAMETER IncludeAnswered
        Also return the routings already carried back, oldest first.

        .OUTPUTS
        [pscustomobject] per routing, with RouteId, Task, At, Message, Baseline,
        Answered, Reported, Reports, Answer (the worker's report, translated) and
        Label.

        .EXAMPLE
        Get-FmTelegramRoute | Where-Object Reported
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$FirstmateHome = '',
        [switch]$IncludeAnswered
    )

    $routes = @()
    try {
        $stateArgs = @{}
        if ($FirstmateHome) { $stateArgs['HomePath'] = $FirstmateHome }
        $stateDir = Get-FmStateRoot @stateArgs

        $records = Get-FmTelegramRouteRecord -StateDir $stateDir
        if ($records.Count -eq 0) { return , $routes }

        $closed = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($record in $records) {
            if ($record.Kind -eq 'answered') { $null = $closed.Add($record.RouteId) }
        }

        foreach ($record in $records) {
            if ($record.Kind -ne 'routed') { continue }
            $answered = $closed.Contains($record.RouteId)
            if ($answered -and -not $IncludeAnswered) { continue }

            $report = Get-FmTelegramWorkerReport -StateDir $stateDir -Task $record.Task -Baseline $record.Baseline
            $project = Get-FmMetaValue -Path (Join-Path $stateDir "$($record.Task).meta") -Key 'project'
            $routes += [pscustomobject]@{
                RouteId  = $record.RouteId
                Task     = $record.Task
                At       = $record.At
                Message  = $record.Text
                Baseline = $record.Baseline
                Answered = $answered
                Reported = $report.Reported
                Reports  = $report.Count
                # Translated HERE rather than at the send, so nothing downstream
                # can hold a worker's raw line and be tempted to forward it.
                Answer   = $(if ($report.Reported) { ConvertTo-FmBridgePlainText -Text $report.Line } else { '' })
                Label    = Get-FmTelegramWorkLabel -Note $report.Line -Project $project
            }
        }
        return , $routes
    } catch {
        return , @()
    }
}

function Send-FmTelegramWorkerReply {
    <#
        .SYNOPSIS
        Carry back the answers that have arrived: one message to the captain per
        routed question a worker has since reported on. Never throws.

        .DESCRIPTION
        THE ANSWER IS MATCHED TO THE QUESTION, NOT MERELY SENT. Each message quotes
        what the captain asked before giving what came back, so a wrong match is
        visible to them in the same breath rather than being discovered later.

        THE WORKER'S WORDS NEVER GO OUT AS THE WORKER WROTE THEM. The report is
        translated by ConvertTo-FmBridgePlainText when the record is read, and then
        every line goes through Send-FmTelegramMessage, which strips again on the
        way out. There is no path here that composes a message from a raw status
        line - that mistake is the easiest one available and the one AGENTS.md
        section 9 forbids by name.

        A ROUTING IS CLOSED ONLY BY A CONFIRMED SEND. A message that timed out, was
        declined, or found the channel switched off leaves its routing open, so the
        next call tries it again rather than losing the answer silently.

        NOTHING CALLS THIS BY ITSELF, deliberately. Wiring the channel into the
        escalation path is a separate decision, so firstmate runs this when it means
        to and the captain is never surprised by a machine that started messaging
        them.

        .PARAMETER FirstmateHome
        Work against this home instead of the resolved one.

        .PARAMETER Task
        Carry back only the answers belonging to this piece of work.

        .PARAMETER TimeoutSeconds
        Hard bound on one send attempt.

        .PARAMETER Retries
        Extra attempts after the first, for a timeout or an unreachable endpoint.

        .OUTPUTS
        [pscustomobject] with Sent, Waiting, Failed, Reason (sent, nothing, off,
        unavailable), Detail and Route (one record per answer carried back).

        .EXAMPLE
        Send-FmTelegramWorkerReply
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$FirstmateHome = '',
        [AllowEmptyString()][string]$Task = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20,
        [ValidateRange(0, 10)][int]$Retries = 2
    )

    $result = [pscustomobject]@{
        Sent    = 0
        Waiting = 0
        Failed  = 0
        Reason  = 'nothing'
        Detail  = ''
        Route   = @()
    }

    try {
        $stateArgs = @{}
        if ($FirstmateHome) { $stateArgs['HomePath'] = $FirstmateHome }
        $stateDir = Get-FmStateRoot @stateArgs

        $routeArgs = @{}
        if ($FirstmateHome) { $routeArgs['FirstmateHome'] = $FirstmateHome }
        # Assigned, not wrapped: see Get-FmTelegramRoute's help.
        $found = Get-FmTelegramRoute @routeArgs
        $open = @($found)
        if ($Task) { $open = @($found | Where-Object { $_.Task -eq $Task }) }

        $carried = @()
        foreach ($route in $open) {
            if (-not $route.Reported) {
                $result.Waiting++
                continue
            }

            $message = @(
                "Captain, you asked: $($route.Message)"
                ''
                $route.Answer
            )
            if ($route.Reports -gt 1) {
                $message += ''
                $message += "That is where it stands now; it moved on $($route.Reports) times since you asked."
            }

            $sendArgs = @{
                Message        = ($message -join "`n")
                TimeoutSeconds = $TimeoutSeconds
                Retries        = $Retries
            }
            if ($FirstmateHome) { $sendArgs['FirstmateHome'] = $FirstmateHome }
            $sent = Send-FmTelegramMessage @sendArgs

            if (-not $sent.Sent) {
                $result.Failed++
                if (-not $result.Detail) { $result.Detail = $sent.Reason }
                continue
            }

            # Closed AFTER the send, in the same direction and for the same reason
            # Start-FmTelegramPoll confirms an update last: a failure between the
            # two tells the captain twice, and the other order loses the answer with
            # no trace. That comment owns the reasoning; this is the same choice.
            $null = Add-FmTelegramRouteRecord -StateDir $stateDir -Kind 'answered' -RouteId $route.RouteId `
                -Task $route.Task -Baseline $route.Baseline -Text $route.Answer
            $result.Sent++
            $carried += $route
        }

        $result.Route = @($carried)
        if ($result.Sent -gt 0) { $result.Reason = 'sent' }
        elseif ($result.Failed -gt 0) { $result.Reason = $(if ($result.Detail -eq 'off') { 'off' } else { 'unavailable' }) }
        return $result
    } catch {
        # The error record is not reported: it can carry the request URI, and the
        # request URI carries the bot token.
        $result.Reason = 'unavailable'
        return $result
    }
}

function Receive-FmTelegramCommand {
    <#
        .SYNOPSIS
        Decide what one inbound message may do, do the part this channel owns,
        and say what to reply. Sends nothing itself.

        .DESCRIPTION
        THE COURIER MODEL. This channel is not a second firstmate. An allowed
        message becomes a durable inbox record; firstmate reads it on its next
        turn and does the work with everything it knows and this poller does not.
        The one action taken here is closing a decision the captain answered,
        because an answer that has to wait to be recognised gets re-asked - which
        is the whole failure the closure exists to prevent.

        WHAT IT DOES, IN ORDER. Empty messages are dropped. Then the authority
        tiers decide: a refused message is recorded nowhere and answered with a
        refusal that names what and why. An allowed message is written to the
        durable inbox verbatim, and - if it is an instruction rather than a
        question, and it identifies a single open decision - closes that decision.
        Last, it works out which piece of live work the message is about and
        records that decision durably.

        ROUTING RUNS AFTER THE TIER CLASSIFICATION AND NEVER AROUND IT. The refusal
        returns before any of it, so a message that is refused is refused whoever it
        was about, and nothing routing does can widen what the tiers allow. Putting
        the resolution first - to "know what they meant before deciding" - would
        have exactly that effect, which is why the order is stated here rather than
        left to be read off the code.

        WHY IT DECIDES BUT DOES NOT DELIVER. The routing decision is written down;
        handing the message to the worker is firstmate's, through the ordinary steer
        path. A poller that typed into a worker's pane itself would be a pipe
        between a phone and a crewmate, and all crewmate communication flows through
        firstmate.

        SEPARATED FROM SENDING ON PURPOSE, so the whole decision surface is
        testable with no token, no network, and no endpoint of any kind. The
        caller sends .Reply.

        .PARAMETER Text
        The inbound message, as sent.

        .PARAMETER FirstmateHome
        Record into this home instead of the resolved one.

        .PARAMETER MaxTier
        Override the configured ceiling. Clamped either way.

        .OUTPUTS
        [pscustomobject] with Accepted, Tier, Action, Reason (recorded, answered,
        refused, empty, unavailable), Reply, Recorded, Closed, Task, Key, Warning,
        and the routing: RouteId, RoutedTo (the id, for firstmate - never for the
        captain), RouteReason (routed, decision, ambiguous, none, unavailable) and
        RouteLabel.

        .EXAMPLE
        $verdict = Receive-FmTelegramCommand -Text 'how is the sign-in fix going'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [string]$FirstmateHome = '',
        [int]$MaxTier = 0
    )

    $result = [pscustomobject]@{
        Accepted    = $false
        Tier        = 0
        Action      = ''
        Reason      = 'empty'
        Reply       = ''
        Recorded    = $false
        Closed      = $false
        Task        = ''
        Key         = ''
        Warning     = ''
        RouteId     = ''
        RoutedTo    = ''
        RouteReason = 'none'
        RouteLabel  = ''
    }

    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $result }

        $homeArgs = @{}
        if ($FirstmateHome) { $homeArgs['HomePath'] = $FirstmateHome }
        $limit = $MaxTier
        if ($limit -le 0) {
            $authority = Get-FmTelegramAuthority @homeArgs
            $result.Warning = $authority.Warning
            $limit = $authority.MaxTier
        }

        $verdict = Test-FmTelegramCommand -Text $Text -MaxTier $limit
        $result.Tier = $verdict.Tier
        $result.Action = $verdict.Action
        if (-not $verdict.Allowed) {
            $result.Reason = 'refused'
            $result.Reply = $verdict.Message
            return $result
        }

        $stateArgs = @{}
        if ($FirstmateHome) { $stateArgs['HomePath'] = $FirstmateHome }
        $stateDir = Get-FmStateRoot @stateArgs
        $null = Add-FmTelegramInboxRecord -StateDir $stateDir -Text $Text
        $result.Accepted = $true
        $result.Recorded = $true
        $result.Reason = 'recorded'
        $result.Reply = 'Captain, got it. I will pick that up on my next turn.'

        # Only an instruction can be an answer. A question about how things stand
        # must never close a question the captain was asked.
        #
        # DECIDED IS NOT SPOKEN. $decisionSpoke records whether the closure already
        # replaced the reply, because what firstmate made of an ANSWER outranks what
        # it made of which work the answer was about - and the routing below would
        # otherwise overwrite the more important of the two.
        $decisionTask = ''
        $decisionSpoke = $false
        if ($verdict.Tier -ge 2) {
            $closureArgs = @{ Answer = $Text }
            if ($FirstmateHome) { $closureArgs['FirstmateHome'] = $FirstmateHome }
            $named = Get-FmTelegramAnswerKey -Text $Text
            if ($named) { $closureArgs['Key'] = $named }
            $decision = Resolve-FmTelegramDecision @closureArgs

            if ($decision.Closed) {
                $result.Closed = $true
                $result.Task = $decision.Task
                $result.Key = $decision.Key
                $result.Reason = 'answered'
                $result.Reply = @(
                    "Captain, noted - I have taken that as your answer to: $($decision.Question)"
                    ''
                    'Tell me if I have that wrong.'
                ) -join "`n"
                $decisionTask = $decision.Task
                $decisionSpoke = $true
            } elseif ($decision.Reason -eq 'ambiguous') {
                $result.Reply = @(
                    'Captain, more than one question is waiting, so I have not assumed which one that answers.'
                    ''
                    'I have passed your words on and I will come back to you with them lined up.'
                ) -join "`n"
                $decisionSpoke = $true
            } elseif ($decision.Reason -eq 'unknown-key') {
                $result.Reply = 'Captain, that question is not waiting on you any more. ' +
                'I have passed your words on anyway.'
                $decisionSpoke = $true
            }
        }

        # ---- which worker this is about --------------------------------------
        # Reached only by a message the tiers already allowed.
        #
        # IN ITS OWN try, and that is the point: the message is already recorded by
        # here, so a routing that cannot be written must degrade to "not routed"
        # rather than un-accept a message firstmate will read anyway. Reporting the
        # whole receive as failed would tell the poller to count a recorded message
        # as ignored and answer the captain with nothing.
        try {
            $target = ''
            $label = ''
            if ($decisionTask) {
                # A closed decision names its own work exactly. Nothing inferred
                # from prose beats it.
                $target = $decisionTask
                $result.RouteReason = 'decision'
            } else {
                $resolveArgs = @{ Text = $Text }
                if ($FirstmateHome) { $resolveArgs['FirstmateHome'] = $FirstmateHome }
                $resolved = Resolve-FmTelegramWorker @resolveArgs
                $result.RouteReason = $resolved.Reason
                if ($resolved.Reason -eq 'routed') {
                    $target = $resolved.Task
                    $label = $resolved.Label
                } elseif ($resolved.Reason -eq 'ambiguous' -and -not $decisionSpoke) {
                    $result.Reply = $resolved.Question
                }
            }

            if ($target) {
                $routeId = New-FmTelegramRouteId
                $null = Add-FmTelegramRouteRecord -StateDir $stateDir -Kind 'routed' -RouteId $routeId `
                    -Task $target -Baseline (Get-FmTelegramStatusLineCount -StateDir $stateDir -Task $target) `
                    -Text $Text
                # Reported only after the record exists. A RouteId the caller could
                # look up and not find would be worse than none at all.
                $result.RouteId = $routeId
                $result.RoutedTo = $target
                $result.RouteLabel = $label
                if (-not $decisionSpoke -and $label) {
                    $result.Reply = @(
                        "Captain, got it. I have taken that as being about this: $label"
                        ''
                        'I will pass it on and come back to you with what they say. Tell me if I have the wrong one.'
                    ) -join "`n"
                }
            }
        } catch {
            $result.RouteId = ''
            $result.RoutedTo = ''
            $result.RouteLabel = ''
            $result.RouteReason = 'unavailable'
        }
        return $result
    } catch {
        $result.Accepted = $false
        $result.Reason = 'unavailable'
        $result.Reply = ''
        return $result
    }
}

function Get-FmTelegramAnswerKey {
    <#
        .SYNOPSIS
        The decision key a message names, or '' when it names none.

        .DESCRIPTION
        Recognises `key=<slug>` and `[key=<slug>]`, which is the same token the
        durable status grammar uses, so a key firstmate quoted in an escalation
        can be quoted straight back from a phone. Nothing is inferred from prose:
        an unrecognised message names no key and the caller falls back to the
        single-open-decision rule rather than guessing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ("$Text" -match '\bkey=([A-Za-z0-9._-]+)') { return $Matches[1] }
    return ''
}

function Start-FmTelegramPoll {
    <#
        .SYNOPSIS
        Take the captain's messages while this session is alive. Never throws.

        .DESCRIPTION
        SESSION-SCOPED, AND THAT IS A REAL HOLE RATHER THAN A ROUGH EDGE. This
        runs while something runs it and stops when that stops. Telegram holds an
        unread message for 24 hours and then drops it silently, so a message sent
        while nothing is running is lost with no trace. Nobody should be told this
        channel means firstmate is reachable from a phone until the long-lived
        service exists to make that true.

        LONG POLLING, NEVER A WEBHOOK. A webhook needs an inbound listener on one
        of four well-known ports on the machine that dispatches the fleet and
        holds its credentials, in exchange for latency that is already sub-second.
        Long polling costs one outbound connection held at a time and needs no
        port, no certificate, no public name, and no third party.

        ONE POLLER AT A TIME, ENFORCED. Two loops on one token fight, and the
        loser silently loses the captain's messages. A second poller refuses and
        returns rather than double-consuming - which is why this takes a singleton
        lock the same way the watcher does.

        WHAT IT DOES WITH AN UPDATE. Anything not from the allowlist is dropped
        before a byte of it is read as a command. Anything older than -MaxAgeSeconds
        is dropped too: a poller starting after a day of downtime would otherwise
        replay up to 24 hours of instructions at once, in order, with no context.
        What survives goes to Receive-FmTelegramCommand, and its reply - including
        a refusal - is sent back.

        WHAT IT REFUSES TO LOG. A count and a reason, never a message body and
        never a sender. The one thing a durable record of this channel must not
        become is a copy of the captain's private chat.

        NEVER THROWS. Unconfigured, no network, a refused request and a held lock
        are all outcomes with reasons, because this is started from a supervision
        path.

        .PARAMETER FirstmateHome
        Poll on behalf of this home instead of the resolved one.

        .PARAMETER MaxCycles
        Stop after this many long polls. 0 runs until the process is stopped;
        the suite uses a small number.

        .PARAMETER PollSeconds
        How long the server holds a poll open with nothing to say.

        .PARAMETER MaxAgeSeconds
        Drop an update older than this at the moment it is received.

        .OUTPUTS
        [pscustomobject] with Started, Reason (stopped, off, busy, unavailable),
        Cycles, Accepted, Refused, Dropped, Closed, Failed and Warning.

        .EXAMPLE
        Start-FmTelegramPoll -MaxCycles 1
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Running the loop IS the command, exactly as Start-FmWatch is; a -WhatIf poller would take the singleton lock and consume nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$FirstmateHome = '',
        [ValidateRange(0, 100000)][int]$MaxCycles = 0,
        [ValidateRange(1, 300)][int]$PollSeconds = 50,
        [ValidateRange(1, 86400)][int]$MaxAgeSeconds = 300
    )

    $result = [pscustomobject]@{
        Started  = $false
        Reason   = 'off'
        Cycles   = 0
        Accepted = 0
        Refused  = 0
        Dropped  = 0
        Closed   = 0
        Failed   = 0
        Warning  = ''
    }

    $lockDir = ''
    try {
        $homeArgs = @{}
        if ($FirstmateHome) { $homeArgs['HomePath'] = $FirstmateHome }
        $credential = Get-FmTelegramCredential @homeArgs
        $result.Warning = $credential.Warning
        if (-not $credential.Token -or $credential.Allow.Count -eq 0) { return $result }

        $stateDir = Get-FmStateRoot @homeArgs
        if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $stateDir -Force
        }

        $lockDir = Get-FmTelegramPollLockPath -StateDir $stateDir
        if (-not (Lock-FmPath -LockDir $lockDir)) {
            $result.Reason = 'busy'
            $lockDir = ''
            return $result
        }

        $allow = [System.Collections.Generic.HashSet[long]]::new([long[]]$credential.Allow)
        $offset = Get-FmTelegramOffset -StateDir $stateDir
        $result.Started = $true
        $result.Reason = 'stopped'

        while ($MaxCycles -le 0 -or $result.Cycles -lt $MaxCycles) {
            $result.Cycles++

            # The composed URL carries the token and never leaves this scope.
            $url = '{0}/bot{1}/getUpdates?timeout={2}&allowed_updates=%5B%22message%22%5D' -f
                (Get-FmTelegramApiBase), $credential.Token, $PollSeconds
            if ($offset -gt 0) { $url = "$url&offset=$offset" }

            # The HTTP bound must outlast the server's hold, or every quiet poll
            # would read as a timeout and the loop would spin instead of waiting.
            $answer = Invoke-FmTelegramApi -Url $url -TimeoutSeconds ($PollSeconds + 20)
            if (-not $answer.Ok) {
                $result.Failed++
                # A hang is this link's ordinary failure, not an emergency: wait a
                # beat and ask again. A refusal is not retried in a tight loop
                # either - the same pause keeps a wrong token from becoming a
                # request storm.
                Start-Sleep -Seconds 2
                continue
            }

            $now = Get-FmUnixTime
            # A quiet poll answers `result: []`, which @() would turn into one
            # null "update" and the counters would report an ignored message that
            # nobody ever sent.
            $updates = @()
            if ($null -ne $answer.Result) { $updates = @($answer.Result) | Where-Object { $null -ne $_ } }
            # An if/else chain rather than early `continue`s, so the confirmation
            # below cannot be skipped for one branch and not another.
            foreach ($update in $updates) {
                $flat = Get-FmTelegramUpdateField -Update $update

                if ($flat.FromId -le 0 -or -not $allow.Contains($flat.FromId)) {
                    # Not the captain. Counted, never described: recording who
                    # else found the bot would put a stranger's identity into
                    # this home's durable records - and answering them would
                    # confirm the bot is live and who is behind it.
                    $result.Dropped++
                } elseif ($flat.Date -gt 0 -and ($now - $flat.Date) -gt $MaxAgeSeconds) {
                    $result.Dropped++
                } elseif ([string]::IsNullOrWhiteSpace($flat.Text)) {
                    $result.Dropped++
                } else {
                    $receiveArgs = @{ Text = $flat.Text }
                    if ($FirstmateHome) { $receiveArgs['FirstmateHome'] = $FirstmateHome }
                    $handled = Receive-FmTelegramCommand @receiveArgs
                    if ($handled.Reason -eq 'refused') { $result.Refused++ }
                    elseif ($handled.Accepted) { $result.Accepted++ }
                    else { $result.Dropped++ }
                    if ($handled.Closed) { $result.Closed++ }

                    if ($handled.Reply) {
                        $replyArgs = @{ Message = $handled.Reply }
                        if ($FirstmateHome) { $replyArgs['FirstmateHome'] = $FirstmateHome }
                        $null = Send-FmTelegramMessage @replyArgs
                    }
                }

                # CONFIRM LAST, and the order is the point. Asking for a higher
                # offset is what tells Telegram to stop holding this message, so
                # it must not happen until the durable record exists. A crash
                # between the two re-delivers the captain's message; a crash the
                # other way round loses it with no trace, which is the failure
                # this whole channel exists to avoid.
                if ($flat.UpdateId -ge $offset) {
                    $offset = $flat.UpdateId + 1
                    $null = Set-FmTelegramOffset -StateDir $stateDir -Offset $offset
                }
            }
        }
        return $result
    } catch {
        # The error record is not reported: it can carry the request URI, and the
        # request URI carries the bot token.
        $result.Reason = 'unavailable'
        return $result
    } finally {
        if ($lockDir) { Unlock-FmPath -LockDir $lockDir }
    }
}
