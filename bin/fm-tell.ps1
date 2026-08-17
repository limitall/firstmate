#requires -Version 7.0

# NOTE ON THE BLANK LINES around this help block: PowerShell only attaches
# comment-based help to a SCRIPT when the block is separated from #requires and
# from param() by a blank line. Without them Get-Help prints the syntax line and
# nothing else, and `-h` below silently becomes useless.

<#
.SYNOPSIS
fm-tell.ps1 - send one message to the captain's phone, so an escalation reaches
them without them being at the machine.

.DESCRIPTION
Thin entry point over Send-FmTelegramMessage. One HTTPS POST to a private
Telegram bot chat: no service, no poller, nothing left running.

OFF BY DEFAULT, AND INERT UNTIL THE CAPTAIN CREATES A BOT. Two files under
`<home>/config/`, both gitignored, and with either missing this command says
nothing and exits 0:

    config/telegram-token   the bot token, one line
    config/telegram-allow   the captain's numeric Telegram user id(s), one per
                            line, # comments allowed

There is no third file naming who to message. In a private bot chat the chat id
IS the captain's user id, so the first allowlist entry is the recipient - one
file, one meaning, and no way for "who may command firstmate" and "who firstmate
tells things to" to drift apart.

NOTHING CALLS THIS BY ITSELF. It is not wired into the escalation path, so
turning the channel on can never surprise the captain with a machine that
suddenly starts messaging them. Every escalation still reaches them in chat
whether or not it was also sent here.

SAY IT IN THE CAPTAIN'S NOUNS. `AGENTS.md` section 9 binds here exactly as in
chat, and harder: they read this on a phone with no context and no quick way to
ask what a label meant, so a message that needs decoding is worse here than
anywhere else. The message is stripped of the obvious machinery on the way out -
status prefixes, decision keys, percentages, repository paths, branch names - but
that is a backstop, not a translation. Write the outcome. Include the full
https:// URL of a PR, never a bare number: a number is not tappable.

Long messages are truncated visibly, ending in "(message truncated)". Nothing is
auto-split: a message that wants three parts is a message that needed
summarising.

THE TOKEN NEVER APPEARS IN OUTPUT. Telegram carries it in the request path, so
an error that quoted the request would write the credential to whatever is
logging. Failures are reported as a reason and, where the API answered, its own
error code and description - never the request, never the error record.

NEVER FATAL. No token, no network, a hung link, or an API refusal are all
outcomes rather than failures: this is called from supervision paths, where a
turn must not end because a laptop is on a train. When nothing was sent, one line
on stderr says why.

Exit codes: 0 sent or deliberately silent, 2 usage. There is no failure exit here
on purpose.

.EXAMPLE
./bin/fm-tell.ps1 "Captain, the sign-in fix is ready for your review. https://github.com/acme/app/pull/482"

.EXAMPLE
./bin/fm-tell.ps1 -TimeoutSeconds 10 "Captain, a decision is waiting on you."
#>

# THE MESSAGE IS POSITION 0 AND TAKES EVERY REMAINING WORD. Declaring it last
# instead - after the typed parameters, as an ordinary remaining-arguments list -
# binds the message's SECOND word to the next positional parameter, so
# `fm-tell.ps1 hello captain` dies converting "captain" to an integer.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Message = @(),
    [string]$FirstmateHome = '',
    [int]$TimeoutSeconds = 20,
    [int]$Retries = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Message.Count -ge 1 -and ($Message[0] -eq '-h' -or $Message[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Send-FmTelegramMessage'

$text = ($Message -join ' ').Trim()
if (-not $text) {
    [Console]::Error.WriteLine('usage: fm-tell.ps1 <message...>')
    exit 2
}

$sent = Send-FmTelegramMessage -Message $text -FirstmateHome $FirstmateHome `
    -TimeoutSeconds $TimeoutSeconds -Retries $Retries

# A configuration problem is reported and sent through, never refused - refusing
# to reach the captain is the failure being guarded against - but never swallowed
# either, or nobody learns why half the channel is not working.
if ($sent.Warning) { [Console]::Error.WriteLine("fm-tell: the channel's settings: $($sent.Warning)") }

if ($sent.Sent) {
    if ($sent.Truncated) {
        [Console]::Error.WriteLine('fm-tell: the message was too long and was cut short; it says so where it stops')
    }
    exit 0
}

# Not sent is a normal outcome, so this is one plain line for whoever is watching
# - never an error record, and never a non-zero exit that could end a supervision
# turn. The detail is the API's own error code and description where it answered;
# it is NEVER the request, which carries the token.
$why = switch ($sent.Reason) {
    'off' { 'the channel to the captain is not set up (no bot token or nobody on the allowlist)' }
    'empty' { 'there was nothing to say' }
    'timeout' { "the link did not answer within $TimeoutSeconds seconds, after $($sent.Attempts) attempt(s)" }
    'unreachable' { "the link could not be reached, after $($sent.Attempts) attempt(s)" }
    'refused' { "it was declined: $($sent.Detail)" }
    default { "it could not be sent: $($sent.Detail)" }
}
[Console]::Error.WriteLine("fm-tell: not sent - $why")
exit 0
