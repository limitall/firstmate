#requires -Version 7.0
# FmTelegram.ps1 - the private half of the private Telegram channel: the
# credential, the allowlist, the command-authority tiers, the message bound, the
# durable inbox record, and the ONE function in this port that talks to Telegram.
#
# READ data/tg-bridge/report.md BEFORE CHANGING ANY OF THIS. It measured the
# properties the shape below exists to survive, and none of them are guesses.
# docs/telegram-windows.md is the design note; this comment carries only the
# rules that must not be discovered by editing.
#
# THE TOKEN IS IN THE URL PATH, so anything that logs a request URI logs the
# credential. Measured: `Invoke-RestMethod -Verbose` and `$_.TargetObject.RequestUri`
# both print it verbatim. Therefore, everywhere in this file:
#   - the composed URL never leaves Invoke-FmTelegramApi's caller frame,
#   - no function ever returns, prints, or stores the token or the URL,
#   - a catch reports the exception TYPE and a fixed reason, never its message
#     and never the error record,
#   - and nothing here is ever called with -Verbose.
# Get-FmTelegramCredential is the only reader of the token file, and its result
# is consumed immediately rather than logged, echoed, or passed to an entry point.
#
# THE ALLOWLIST IS A BOUNDARY CONTROL, NOT A CONVENIENCE. Anyone who finds a
# bot's username can message it, so without an allowlist checked before a single
# byte is interpreted as a command, "command firstmate from Telegram" means
# "command firstmate from the internet" - which is exactly the public-mention
# integration AGENTS.md section 14 says this port does not have. It filters on
# the SENDER (message.from.id), never the chat id: a chat identifies a
# conversation, not a person.
#
# THE LINK HANGS ON ABOUT ONE CALL IN TEN. Measured over 49 requests from this
# machine: 5 hung until their timeout while the rest answered in a median 469 ms.
# A failing call is a HANG, not an error, so every request here is bounded and
# retried, and "sent" means the API confirmed it - never that the call returned.

Set-StrictMode -Version Latest

function Get-FmTelegramApiBase {
    <#
        .SYNOPSIS
        The Telegram API root.

        .DESCRIPTION
        FM_TELEGRAM_API_BASE redirects it, and that is a TEST SEAM: the suite
        points it at a loopback address that nothing answers so the entry-point
        tests exercise the real request path without a token, without a network,
        and without one byte leaving the machine. It is deliberately an
        environment variable rather than a config key - a file under config/ that
        could redirect where the captain's messages are posted is a worse thing
        to own than a variable only a process on this machine can already set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $override = [Environment]::GetEnvironmentVariable('FM_TELEGRAM_API_BASE')
    if ($override) { return $override.TrimEnd('/') }
    return 'https://api.telegram.org'
}

function Get-FmTelegramMaxLength {
    <#
        .SYNOPSIS
        The outbound message bound, in characters.

        .DESCRIPTION
        Telegram documents `text` as 1-4096 characters after entities parsing, so
        this is the API's number rather than a house style. It is enforced HERE
        and not by the API on purpose: a rejected message is an escalation that
        silently never arrived.

        Nothing auto-splits at this bound. A message that wants three parts is a
        message that failed AGENTS.md section 9 - summarise it and point at the
        report instead.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 4096
}

function Get-FmTelegramTruncationMarker {
    <# What an over-long message ends with, so the cut is visible. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return ' ... (message truncated)'
}

function Get-FmTelegramMessageText {
    <#
        .SYNOPSIS
        One outbound message, translated and bounded.

        .DESCRIPTION
        TWO THINGS HAPPEN HERE AND BOTH ARE REQUIRED.

        First, every line goes through ConvertTo-FmBridgePlainText, the one owner
        of AGENTS.md section 9's stripping. The captain reads these on a phone
        with no context and no quick way to ask what a label meant, so a message
        that needs decoding is worse here than anywhere else. This is a backstop,
        not a translator: the caller still owns writing in outcomes, because only
        the caller knows what the outcome was.

        Second, the result is bounded to Get-FmTelegramMaxLength with a VISIBLE
        marker. A silent cut is worse than a long message - the captain would see
        a sentence stop mid-clause with no way to tell whether the machine was cut
        off or the news simply ended there - and letting the API reject it is
        worse still, because then nothing arrives at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (($Message -replace "`r`n", "`n") -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $lines.Add('')
            continue
        }
        $lines.Add((ConvertTo-FmBridgePlainText -Text $line))
    }
    # Collapse the runs of blank lines a stripped-empty line can leave behind,
    # then trim the ends: a message that opens or closes on white space reads as
    # a glitch on a phone.
    $text = (($lines -join "`n") -replace "`n{3,}", "`n`n").Trim()

    $max = Get-FmTelegramMaxLength
    if ($text.Length -le $max) {
        return [pscustomobject]@{ Text = $text; Truncated = $false }
    }

    $marker = Get-FmTelegramTruncationMarker
    $room = $max - $marker.Length
    $head = $text.Substring(0, $room)
    $break = $head.LastIndexOf(' ')
    # Only honour a word boundary that is not most of the way back up the
    # message; a 4000-character word (a pasted blob, a URL) has no useful one.
    if ($break -ge [int]($room * 0.9)) { $head = $head.Substring(0, $break) }
    return [pscustomobject]@{ Text = ($head.TrimEnd() + $marker); Truncated = $true }
}

function Get-FmTelegramCredential {
    <#
        .SYNOPSIS
        The bot token and the captain's allowlist, or empties when unconfigured.

        .DESCRIPTION
        THE ONLY READER OF config/telegram-token IN THIS PORT. Two files, each
        one small setting, following the existing config/ convention:

            config/telegram-token   the bot token, one line
            config/telegram-allow   the captain's numeric Telegram user id(s),
                                    one per line, # comments allowed

        There is deliberately no third file naming the outbound chat. In a private
        bot chat the chat id IS the captain's user id, so the allowlist is both
        who may command and who may be told - one file, one meaning, and no way
        for the two to drift into a state where firstmate messages somebody it
        would refuse to take orders from.

        NEVER LOG, PRINT, OR RETURN .Token TO AN ENTRY POINT. It is here so
        Send-FmTelegramMessage and Start-FmTelegramPoll can compose one URL and
        drop it; every other use is a leak.

        UNCONFIGURED IS AN ANSWER, NOT A FAILURE. Missing files, an unreadable
        file, and a garbled allowlist all come back as "off" with a warning, so a
        supervision path that calls this cannot be ended by it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $result = [pscustomobject]@{
        Token   = ''
        Allow   = @()
        Warning = ''
    }
    $problems = [System.Collections.Generic.List[string]]::new()

    $pathArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $pathArgs['HomePath'] = $HomePath }

    try {
        $tokenPath = Get-FmTelegramConfigFilePath -Name 'telegram-token' @pathArgs
        if (Test-Path -LiteralPath $tokenPath -PathType Leaf) {
            foreach ($line in [System.IO.File]::ReadAllLines($tokenPath)) {
                $trimmed = "$line".Trim()
                if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
                $result.Token = $trimmed
                break
            }
        }
    } catch {
        # Deliberately not $_.Exception.Message: this reader has the token's path
        # and, on some failures, its contents in scope, and a warning is printed.
        $problems.Add('the token could not be read')
    }

    try {
        $allowPath = Get-FmTelegramConfigFilePath -Name 'telegram-allow' @pathArgs
        if (Test-Path -LiteralPath $allowPath -PathType Leaf) {
            $ids = [System.Collections.Generic.List[long]]::new()
            $number = 0
            foreach ($line in [System.IO.File]::ReadAllLines($allowPath)) {
                $number++
                $trimmed = "$line".Trim()
                if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
                if ($trimmed -notmatch '^[0-9]+$') {
                    # The id itself is never quoted back: config/telegram-allow
                    # holds the captain's Telegram identity, which is not
                    # committable and not printable.
                    $problems.Add("line ${number}: not a numeric Telegram user id, so it is ignored")
                    continue
                }
                $id = [long]$trimmed
                if (-not $ids.Contains($id)) { $ids.Add($id) }
            }
            $result.Allow = @($ids)
        }
    } catch {
        $problems.Add('the allowlist could not be read')
    }

    if ($result.Token -and $result.Allow.Count -eq 0) {
        $problems.Add('there is a bot token but no allowlist, so nothing is authorised to command or be told')
    }
    $result.Warning = ($problems -join '; ')
    return $result
}

function Get-FmTelegramConfigFilePath {
    <#
        .SYNOPSIS
        One config/ file belonging to the Telegram channel.

        .DESCRIPTION
        A one-line wrapper so every Telegram config read goes through the
        foundation's resolver with the same -HomePath handling, rather than three
        sites each joining a path their own way.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$HomePath
    )
    $splat = @{ Name = $Name }
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $splat['HomePath'] = $HomePath }
    return (Get-FmConfigPath @splat)
}

function Get-FmTelegramAuthorityCeiling {
    <#
        .SYNOPSIS
        The highest command tier this channel can EVER carry. Always 2.

        .DESCRIPTION
        THIS IS THE REFUSAL, AND IT IS IN THE CODE PATH ON PURPOSE. Tier 3 -
        merge, discard, delete, cleanup that erases work, anything irreversible,
        anything touching a credential - is the exact set where a lost phone or a
        leaked bot token converts into damage that cannot be undone, and the exact
        set AGENTS.md's precedence rule already requires the captain to state
        concretely and explicitly.

        A configuration file that is edited, corrupted, or absent must not be able
        to widen the channel to that set, so the ceiling is a constant here rather
        than a default in a config reader. config/telegram-authority may narrow the
        channel to tier 1; it can never raise it past this. Where the line sits is
        the captain's open decision (tg-command-authority in
        data/tg-bridge/report.md section 16) - and answering it to allow tier 3
        means changing THIS function, deliberately, in a commit, which is the point.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 2
}

function Get-FmTelegramAuthority {
    <#
        .SYNOPSIS
        How much this channel is allowed to carry: MaxTier, plus any warning.

        .DESCRIPTION
        Optional config/telegram-authority, key=value, one key:

            # config/telegram-authority
            allow-tier=1

        1 makes the channel read-only. 2 is the default and adds dispatching,
        steering, and answering a decision - all reversible. Anything higher is
        CLAMPED to the ceiling and reported, never honoured, so a captain who
        edits this file to 3 is told plainly that the file did not do what they
        meant rather than believing the channel widened.

        An unreadable or nonsense file falls back to the default rather than
        refusing: this sits on the path between the captain asking a question and
        firstmate answering, and a typo must not silence the channel. Every
        problem comes back in Warning for the caller to surface.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $ceiling = Get-FmTelegramAuthorityCeiling
    $result = [pscustomobject]@{ MaxTier = $ceiling; Warning = '' }
    $problems = [System.Collections.Generic.List[string]]::new()

    $pathArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $pathArgs['HomePath'] = $HomePath }

    $lines = @()
    try {
        $path = Get-FmTelegramConfigFilePath -Name 'telegram-authority' @pathArgs
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
        $lines = [System.IO.File]::ReadAllLines($path)
    } catch {
        $result.Warning = 'the command-authority setting could not be read; the default is in force'
        return $result
    }

    $number = 0
    foreach ($line in $lines) {
        $number++
        $trimmed = "$line".Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) {
            $problems.Add("line ${number}: expected key=value, got '$trimmed'")
            continue
        }
        $key = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($key -cne 'allow-tier') {
            $problems.Add("line ${number}: unknown key '$key' (the only key is allow-tier)")
            continue
        }
        $parsed = 0
        if (-not [int]::TryParse($value, [ref]$parsed)) {
            $problems.Add("line ${number}: allow-tier '$value' is not a number; the default is in force")
            continue
        }
        if ($parsed -lt 1) {
            $problems.Add("line ${number}: allow-tier $parsed is below 1; using 1, so this channel only reports")
            $result.MaxTier = 1
            continue
        }
        if ($parsed -gt $ceiling) {
            $problems.Add("line ${number}: allow-tier $parsed is refused; this channel never carries anything " +
                'that cannot be undone, whatever this file says')
            $result.MaxTier = $ceiling
            continue
        }
        $result.MaxTier = $parsed
    }

    $result.Warning = ($problems -join '; ')
    return $result
}

function Get-FmTelegramTierThreePattern {
    <#
        .SYNOPSIS
        The refused actions, as ordered (pattern, plain-English action) pairs.

        .DESCRIPTION
        The action strings are what a refusal names back to the captain, so they
        are written in their nouns rather than in verbs from this repository.

        DELIBERATELY BROAD, and the direction is the point. Over-refusing costs a
        message saying so and a walk to the machine; under-refusing costs work
        that cannot be recovered. Where this line sits is the captain's decision
        (tg-command-authority), not an engineering preference, and this table is
        the conservative reading of it that the brief asked for.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        [pscustomobject]@{ Pattern = '\bmerg(?:e|es|ed|ing)\b'; Action = 'land that work' }
        # "land it" and "ship it" are what a captain actually types for a merge.
        # Scoped to a following object so "the landing page" stays ordinary work.
        [pscustomobject]@{
            Pattern = '\bland(?:s|ed|ing)?\s+(?:it|this|that|them|the|my|his|her|their)\b|\bship\s+(?:it|this|that|them)\b'
            Action  = 'land that work'
        }
        [pscustomobject]@{ Pattern = '\bdiscard(?:s|ed|ing)?\b'; Action = 'throw that work away' }
        [pscustomobject]@{ Pattern = '\bdelet(?:e|es|ed|ing|ion)\b'; Action = 'delete that' }
        [pscustomobject]@{ Pattern = '\bremov(?:e|es|ed|ing)\b'; Action = 'remove that' }
        [pscustomobject]@{ Pattern = '\bdrop(?:s|ped|ping)?\b'; Action = 'drop that' }
        [pscustomobject]@{ Pattern = '\b(?:wipe|purge|destroy|nuke|erase)\w*\b'; Action = 'erase that' }
        # "tear it all down" is the same instruction as "teardown", so the two
        # halves are allowed an object between them.
        [pscustomobject]@{ Pattern = '\bteardown\b|\btear\b[^.!?]{0,20}?\bdown\b'; Action = 'clean that up for good' }
        [pscustomobject]@{ Pattern = '\brm\s+-[rf]'; Action = 'delete that' }
        [pscustomobject]@{ Pattern = '\bforce[\s-]*push\b|\bpush\s+--force\b|\b--force-with-lease\b'
            Action = 'overwrite what is already published'
        }
        [pscustomobject]@{ Pattern = '\breset\s+--hard\b|\bhard\s+reset\b'; Action = 'throw that work away' }
        [pscustomobject]@{ Pattern = '\brevok\w*\b'; Action = 'change a login' }
        # The strong credential nouns, bare. None of these is ever incidental in a
        # message to firstmate: a sentence that says "password" is about one.
        [pscustomobject]@{
            Pattern = '\b(?:passwords?|credentials?|secrets?|api[\s-]*keys?|ssh[\s-]*keys?|private[\s-]*keys?)\b|\.env\b'
            Action  = 'touch a login'
        }
        # The weak ones need a verb, because they are ordinary project words. The
        # captain's own example message is about a SIGN-IN FIX, and a channel that
        # refused to hear about it would be useless on the first day; "token" and
        # "account" are the same. So these refuse an act on a credential, not a
        # mention of one.
        #
        # BOTH DIRECTIONS, and the reading one matters more here than the writing
        # one. A phone is the thing that gets lost, and the message a finder types
        # is "send me the bot token" - not "rotate" it. Refusing only the writing
        # verbs would leave the one request this channel most needs to refuse
        # classified as a harmless question, because "show" reads like a status
        # ask. Measured before the fix: "show the token" -> tier 1, allowed.
        [pscustomobject]@{
            Pattern = '\b(?:creat|mak|chang|reset|updat|add|rotat|revok|regenerat|renew|store|storing|paste|pasting|' +
            'show|send|print|reveal|display|echo|cat|read|repeat|forward|expos|leak|dump|copy|what\s+is|what.?s|tell\s+me)\w*\b' +
            '[^.!?]{0,30}?\b(?:tokens?|logins?|log\s*ins?|sign[\s-]*ins?|accounts?|auth\w*)\b'
            Action  = 'touch a login'
        }
    )
}

function Get-FmTelegramTierOnePattern {
    <#
        .SYNOPSIS
        The read-and-report shapes: asking, never changing.

        .DESCRIPTION
        Matched only after the refused set has been ruled out, so a message that
        asks for a status AND a merge is a merge. Anything matching neither table
        is treated as tier 2 - an instruction - which is the safe default,
        because mistaking an instruction for a question would silently do nothing.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    return @(
        '\bstatus\b'
        '\bprogress\b'
        '\bbearings\b'
        '\bupdate me\b'
        "\bwhat(?:'s|s| is| are| does| do)?\b"
        '\bwho(?:\b|se)'
        '\bwhere\b'
        '\bwhen\b'
        '\bhow (?:far|much|many|is|are|goes|going|do|does)\b'
        '\b(?:show|list|report|summar(?:y|ise|ize|ised|ized))\b'
        '\bwaiting\b'
        '\banything\b'
        '\bany news\b'
        '\bstill (?:running|going|working)\b'
    )
}

function Get-FmTelegramCommandTier {
    <#
        .SYNOPSIS
        Which of the three tiers one inbound message falls in.

        .DESCRIPTION
        1 - read and report. 2 - dispatch, steer, answer a decision. 3 - refused.
        Returns Tier, Action (the plain-English thing a tier 3 message asked for,
        for the refusal to name) and Reason.

        The refused table is checked FIRST and unconditionally, so no phrasing,
        ordering, or padding gets a tier 3 request read as anything else.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $text = "$Text"
    foreach ($rule in (Get-FmTelegramTierThreePattern)) {
        if ($text -imatch $rule.Pattern) {
            return [pscustomobject]@{
                Tier   = 3
                Action = $rule.Action
                Reason = 'this cannot be undone'
            }
        }
    }
    foreach ($pattern in (Get-FmTelegramTierOnePattern)) {
        if ($text -imatch $pattern) {
            return [pscustomobject]@{ Tier = 1; Action = ''; Reason = 'this only asks how things stand' }
        }
    }
    return [pscustomobject]@{ Tier = 2; Action = ''; Reason = 'this asks for work that can be undone' }
}

function Get-FmTelegramInboxPath {
    <#
        .SYNOPSIS
        The durable record of what the captain sent from their phone.

        .DESCRIPTION
        Its own file kind, not a state/<pseudo-task>.status. A status file's verbs
        carry lifecycle meaning - a needs-decision line would open a keyed decision
        somebody then has to close, and a done line is read by the fleet-wide
        captain-relevant scan - so an inbound message written as one would read as
        a phantom task to every future reader of this home. Private/FmWatch.ps1
        scans *.inbox alongside *.status and *.turn-ended, so this record still
        becomes an actionable notification with no verb abuse at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StateDir)
    return (Join-Path $StateDir 'captain-telegram.inbox')
}

function Add-FmTelegramInboxRecord {
    <#
        .SYNOPSIS
        Append one inbound message to the durable inbox.

        .DESCRIPTION
        The record is `epoch<TAB>text`, UTF-8 without BOM and LF only, appended
        under the foundation's per-file lock exactly as a status line is.

        THE TEXT IS THE CAPTAIN'S OWN WORDS, VERBATIM. Nothing strips or
        rewrites it: AGENTS.md section 9 governs what firstmate SAYS, and
        editing what the captain ASKED would change the instruction on its way in.
        Only tabs and newlines are flattened, so no message can forge a record
        boundary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $flat = (("$Text" -replace "`r`n", ' ') -replace "[`r`n`t]", ' ').Trim()
    $line = "{0}`t{1}" -f (Get-FmUnixTime), $flat
    Add-FmStateLine -Path (Get-FmTelegramInboxPath -StateDir $StateDir) -Line $line -Confirm:$false
    return $line
}

function Get-FmTelegramOffsetPath {
    <# Where the confirmed getUpdates offset survives a restart. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StateDir)
    return (Join-Path $StateDir '.telegram-offset')
}

function Get-FmTelegramOffset {
    <#
        .SYNOPSIS
        The next update id to ask for, or 0 when there has never been one.

        .DESCRIPTION
        Telegram confirms an update only when getUpdates is called with an offset
        above its update_id, so this file is what stops a restarted poller
        replaying everything the server still holds. An unreadable or nonsense
        file reads as 0 rather than refusing: the stale-age guard is what keeps a
        replay harmless, and refusing to start is worse than starting from the
        beginning.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][string]$StateDir)
    try {
        $text = Read-FmStateFile -Path (Get-FmTelegramOffsetPath -StateDir $StateDir)
        if ($null -eq $text) { return [long]0 }
        $trimmed = "$text".Trim()
        if ($trimmed -notmatch '^[0-9]+$') { return [long]0 }
        return [long]$trimmed
    } catch { return [long]0 }
}

function Set-FmTelegramOffset {
    <# Persist the confirmed offset. Best effort: a failure re-reads, never loses. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Bookkeeping inside a poll cycle that has already consumed the update; -WhatIf would replay it forever.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][long]$Offset
    )
    try {
        Write-FmStateFile -Path (Get-FmTelegramOffsetPath -StateDir $StateDir) -Content ([string]$Offset) -Confirm:$false
        return $true
    } catch { return $false }
}

function Get-FmTelegramPollLockPath {
    <#
        .SYNOPSIS
        The poller's singleton lock.

        .DESCRIPTION
        Two getUpdates loops on one token fight, and the loser silently loses the
        captain's messages - a failure that would be very hard to diagnose from
        the symptom. A leftover poller, or a second firstmate home on this
        machine, is exactly how that happens, so the second one refuses instead.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StateDir)
    return (Join-Path $StateDir '.telegram-poll.lock')
}

function Invoke-FmTelegramApi {
    <#
        .SYNOPSIS
        THE ONLY FUNCTION IN THIS PORT THAT TALKS TO TELEGRAM.

        .DESCRIPTION
        Everything else in this area is pure and testable; this is not, so the
        suite mocks exactly this one function and never opens a socket, needs a
        token, or leaves the machine. The same shape as the voice channel's four
        engine seams, and for the same reason.

        NEVER THROWS. It answers with a verdict:

          ok          the API confirmed it (`ok: true`)
          refused     the API answered and said no - a 400, a 401, a 429. Carries
                      error_code and description, which are the ONLY two fields
                      of a failure that are safe to log.
          timeout     the request was still open when the bound expired. About one
                      call in ten does this from this machine; the caller retries.
          unreachable no answer at all - DNS, TCP, TLS.
          malformed   an answer that was not the documented JSON envelope.

        WHAT IT DELIBERATELY NEVER RETURNS: the URL, the token, the exception
        message, or the error record. Telegram carries the token in the URL path,
        and both `-Verbose` and `$_.TargetObject.RequestUri` print it verbatim, so
        a catch that reported what it caught would write the credential to
        whatever the caller logs. Only a fixed reason and the exception's TYPE
        name escape this function.

        -SkipHttpErrorCheck is what makes the token-safe path possible at all:
        without it a 401 throws, and the only place the description lives is
        inside the error record this function must not touch.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [AllowEmptyString()][string]$BodyJson = '',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20
    )

    $verdict = [pscustomobject]@{
        Ok          = $false
        Reason      = 'unreachable'
        ErrorCode   = 0
        Description = ''
        Result      = $null
    }

    $status = 0
    $response = $null
    try {
        $params = @{
            Uri                = $Url
            Method             = $(if ($BodyJson) { 'Post' } else { 'Get' })
            TimeoutSec         = $TimeoutSeconds
            SkipHttpErrorCheck = $true
            StatusCodeVariable = 'status'
            ErrorAction        = 'Stop'
        }
        if ($BodyJson) {
            $params['Body'] = $BodyJson
            $params['ContentType'] = 'application/json; charset=utf-8'
        }
        $response = Invoke-RestMethod @params
    } catch {
        # The exception TYPE only. Its message may carry the request URI, and the
        # request URI carries the bot token.
        $type = $_.Exception.GetType().Name
        if ($type -match 'TaskCanceled|OperationCanceled|Timeout') {
            $verdict.Reason = 'timeout'
        } else {
            $verdict.Reason = 'unreachable'
        }
        $verdict.Description = "the request did not complete ($type)"
        return $verdict
    }

    if ($null -eq $response) {
        $verdict.Reason = 'malformed'
        $verdict.Description = "the answer was empty (HTTP $status)"
        return $verdict
    }
    if (-not ($response.PSObject.Properties['ok'])) {
        $verdict.Reason = 'malformed'
        $verdict.Description = "the answer was not the documented shape (HTTP $status)"
        return $verdict
    }

    if ([bool]$response.ok) {
        $verdict.Ok = $true
        $verdict.Reason = 'ok'
        if ($response.PSObject.Properties['result']) { $verdict.Result = $response.result }
        return $verdict
    }

    $verdict.Reason = 'refused'
    if ($response.PSObject.Properties['error_code']) { $verdict.ErrorCode = [int]$response.error_code }
    if ($response.PSObject.Properties['description']) { $verdict.Description = [string]$response.description }
    if (-not $verdict.Description) { $verdict.Description = "the API declined it (HTTP $status)" }
    return $verdict
}

function Get-FmTelegramUpdateField {
    <#
        .SYNOPSIS
        One inbound update, flattened to the four fields that matter.

        .DESCRIPTION
        Returns UpdateId, FromId, Date and Text, with 0 or '' for anything the
        payload does not carry. Under Set-StrictMode a missing property THROWS, so
        every read here is guarded - a malformed or unfamiliar update must be
        dropped, never allowed to end the poll loop.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowNull()]$Update)

    $flat = [pscustomobject]@{ UpdateId = [long]0; FromId = [long]0; Date = [long]0; Text = '' }
    if ($null -eq $Update) { return $flat }
    try {
        if ($Update.PSObject.Properties['update_id']) { $flat.UpdateId = [long]$Update.update_id }
        $message = $null
        foreach ($name in @('message', 'edited_message', 'channel_post')) {
            if ($Update.PSObject.Properties[$name] -and $null -ne $Update.$name) {
                $message = $Update.$name
                break
            }
        }
        if ($null -eq $message) { return $flat }
        if ($message.PSObject.Properties['date']) { $flat.Date = [long]$message.date }
        if ($message.PSObject.Properties['text']) { $flat.Text = [string]$message.text }
        if ($message.PSObject.Properties['from'] -and $null -ne $message.from -and
            $message.from.PSObject.Properties['id']) {
            $flat.FromId = [long]$message.from.id
        }
    } catch {
        return $flat
    }
    return $flat
}

function Get-FmTelegramRefusalMessage {
    <#
        .SYNOPSIS
        What the captain is told when this channel will not do what they asked.

        .DESCRIPTION
        A refusal that says nothing is indistinguishable from a channel that
        broke, and the captain would repeat themselves into silence. So it names
        the action it refused, why, and what to do instead - in their nouns, with
        no machinery in it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Tier,
        [AllowEmptyString()][string]$Action = ''
    )

    if ($Tier -ge 3) {
        $what = if ($Action) { $Action } else { 'that' }
        return @(
            "Captain, I will not $what from here."
            ''
            'Anything that cannot be undone - landing work, throwing work away, deleting, or touching a login - ' +
            'I only do with you at the machine, because a message from a phone proves far less about who is asking ' +
            'than you being there does.'
            ''
            'Ask me again there and I will do it. Everything short of that I can still do from here.'
        ) -join "`n"
    }
    return @(
        'Captain, I can only tell you how things stand from here.'
        ''
        'That message asks me to change something, and you have this channel set to reporting only. ' +
        'Ask me at the machine, or widen it there.'
    ) -join "`n"
}
