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
        refused, empty, unavailable), Reply, Recorded, Closed, Task, Key and
        Warning.

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
        Accepted = $false
        Tier     = 0
        Action   = ''
        Reason   = 'empty'
        Reply    = ''
        Recorded = $false
        Closed   = $false
        Task     = ''
        Key      = ''
        Warning  = ''
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
        if ($verdict.Tier -lt 2) { return $result }

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
        } elseif ($decision.Reason -eq 'ambiguous') {
            $result.Reply = @(
                'Captain, more than one question is waiting, so I have not assumed which one that answers.'
                ''
                'I have passed your words on and I will come back to you with them lined up.'
            ) -join "`n"
        } elseif ($decision.Reason -eq 'unknown-key') {
            $result.Reply = 'Captain, that question is not waiting on you any more. I have passed your words on anyway.'
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
