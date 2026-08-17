#requires -Version 7.0

# NOTE ON THE BLANK LINES around this help block: PowerShell only attaches
# comment-based help to a SCRIPT when the block is separated from #requires and
# from param() by a blank line. Without them Get-Help prints the syntax line and
# nothing else, and `-h` below silently becomes useless.

<#
.SYNOPSIS
fm-tg-poll.ps1 - take the captain's messages from their phone while this session
is alive.

.DESCRIPTION
Thin entry point over Start-FmTelegramPoll. It holds one outbound long poll at a
time against a private Telegram bot chat and turns what the captain sends into a
durable record firstmate reads on its next turn.

SESSION-SCOPED, AND THAT IS A REAL HOLE RATHER THAN A ROUGH EDGE. This runs while
something runs it and stops when that stops. Telegram holds an unread message for
24 hours and then drops it silently, so a message sent while nothing is running
is lost with no trace. Do not tell the captain firstmate is reachable from their
phone until a long-lived service exists to make that true.

OFF BY DEFAULT, AND INERT UNTIL THE CAPTAIN CREATES A BOT. Same two files as
`fm-tell.ps1`, both under `<home>/config/` and gitignored; with either missing
this exits 0 having done nothing:

    config/telegram-token   the bot token, one line
    config/telegram-allow   the captain's numeric Telegram user id(s), one per
                            line, # comments allowed

WHAT A MESSAGE MAY DO. Three tiers. Asking how things stand is always allowed.
Handing out work, steering it, and answering a waiting question are allowed and
are the point of the channel - every one of them is reversible. Landing work,
throwing work away, deleting, cleaning up for good, and anything touching a login
are REFUSED here and reserved for the captain being at the machine, because a
message from a phone proves far less about who is asking. A refusal is answered
with what it refused and why, never with silence.

That ceiling is in the code, not in a setting. An optional
`config/telegram-authority` carrying `allow-tier=1` narrows the channel to
reporting only; nothing in that file, and no absence of it, can widen it to the
refused set.

ONE POLLER AT A TIME. Two long polls on one token fight, and the loser silently
loses the captain's messages. A second one refuses and exits 0 rather than
double-consuming.

WHAT IT WRITES, AND WHAT IT REFUSES TO. An accepted message becomes one line in
`state/captain-telegram.inbox`, which is its own file kind so an inbound message
never masquerades as a task. An answer to a single waiting question also closes
that question, so it is not asked again. Nothing else is recorded: refusals and
messages from strangers are counted, never described, because a durable copy of
the captain's private chat is the one thing this must not become.

NEVER FATAL. No token, no network, a hung link, and a poller already running are
all outcomes with a reason on stderr. Exit codes: 0 always, 2 usage.

.PARAMETER MaxCycles
Stop after this many long polls instead of running until stopped. Diagnostic
seam.

.PARAMETER PollSeconds
How long the server holds a quiet poll open before answering with nothing.

.PARAMETER MaxAgeSeconds
Drop a message older than this on arrival. Without it, a poller starting after a
day of downtime would replay up to 24 hours of instructions at once, in order,
with no context.

.EXAMPLE
pwsh bin/fm-tg-poll.ps1

.EXAMPLE
pwsh bin/fm-tg-poll.ps1 -MaxCycles 1
#>

[CmdletBinding()]
param(
    [string]$FirstmateHome = '',
    [int]$MaxCycles = 0,
    [int]$PollSeconds = 50,
    [int]$MaxAgeSeconds = 300,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Start-FmTelegramPoll'

$run = Start-FmTelegramPoll -FirstmateHome $FirstmateHome -MaxCycles $MaxCycles `
    -PollSeconds $PollSeconds -MaxAgeSeconds $MaxAgeSeconds

if ($run.Warning) { [Console]::Error.WriteLine("fm-tg-poll: the channel's settings: $($run.Warning)") }

if (-not $run.Started) {
    # Not starting is a normal outcome, so it is one plain line and exit 0 -
    # never an error record, and never a non-zero exit that could end a
    # supervision turn.
    $why = switch ($run.Reason) {
        'off' { 'the channel to the captain is not set up (no bot token or nobody on the allowlist)' }
        'busy' { 'another one is already listening; two would take each other''s messages' }
        default { 'it could not start' }
    }
    [Console]::Error.WriteLine("fm-tg-poll: not listening - $why")
    exit 0
}

# The counts, and only the counts. No message body, no sender, no request.
[Console]::Out.WriteLine(
    "fm-tg-poll: stopped after $($run.Cycles) wait(s) - " +
    "$($run.Accepted) taken, $($run.Closed) question(s) answered, " +
    "$($run.Refused) refused, $($run.Dropped) ignored, $($run.Failed) unanswered call(s)")
exit 0
