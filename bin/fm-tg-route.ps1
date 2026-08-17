#requires -Version 7.0

# NOTE ON THE BLANK LINES around this help block: PowerShell only attaches
# comment-based help to a SCRIPT when the block is separated from #requires and
# from param() by a blank line. Without them Get-Help prints the syntax line and
# nothing else, and `-h` below silently becomes useless.

<#
.SYNOPSIS
fm-tg-route.ps1 - see which of the captain's phone messages went to which piece of
work, and carry back the answers that have arrived.

.DESCRIPTION
Thin entry point over Get-FmTelegramRoute and Send-FmTelegramWorkerReply, the
second half of the private channel. `fm-tg-poll.ps1` works out which live piece of
work an inbound message is about and records that decision; this reads the record
and, with `-Send`, tells the captain what came back.

READ-ONLY BY DEFAULT. With no switch it prints what is outstanding and sends
nothing, so looking at the record never becomes an action.

THE ANSWER COMES FROM THE WORKER'S OWN STATUS STREAM, and from nothing else. That
is the supported signal in this home; a routed message records how many reports
that worker had already made, and the answer is what it says after that boundary.
No second channel is invented for the phone.

A WORKER'S WORDS NEVER GO OUT AS THE WORKER WROTE THEM. Every report is translated
before it is sent, and the message quotes what the captain asked before giving what
came back - so a wrong match is visible to them in the same breath rather than
discovered later.

YOU STILL HAND THE MESSAGE OVER YOURSELF. This records and reports; it never types
into a worker. Steer with `fm-send.ps1` as usual - all crewmate communication flows
through firstmate, and a phone that could drive a pane directly would not.

A ROUTING IS CLOSED ONLY BY A CONFIRMED SEND, so a message that timed out or found
the channel switched off stays outstanding and is tried again next time rather than
being lost silently.

OFF BY DEFAULT, like the rest of the channel. With no bot token or nobody on the
allowlist, `-Send` says so and changes nothing.

NEVER FATAL. Exit codes: 0 always, 2 usage.

.PARAMETER Send
Carry back every answer that has arrived, then record each one as answered.

.PARAMETER Task
Limit to one piece of work.

.PARAMETER All
Also list the routings already carried back.

.EXAMPLE
pwsh bin/fm-tg-route.ps1

.EXAMPLE
pwsh bin/fm-tg-route.ps1 -Send
#>

[CmdletBinding()]
param(
    [switch]$Send,
    [string]$FirstmateHome = '',
    [string]$Task = '',
    [switch]$All,
    [int]$TimeoutSeconds = 20,
    [int]$Retries = 2,
    [Alias('h')][switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmTelegramRoute'

if ($Send) {
    $carried = Send-FmTelegramWorkerReply -FirstmateHome $FirstmateHome -Task $Task `
        -TimeoutSeconds $TimeoutSeconds -Retries $Retries
    if ($carried.Sent -eq 0 -and $carried.Failed -gt 0) {
        # Not sent is a normal outcome, so this is one plain line and exit 0. The
        # detail is a reason, never the request - which carries the token.
        $why = switch ($carried.Reason) {
            'off' { 'the channel to the captain is not set up (no bot token or nobody on the allowlist)' }
            default { "it could not be sent ($($carried.Detail))" }
        }
        [Console]::Error.WriteLine("fm-tg-route: nothing carried back - $why")
        exit 0
    }
    [Console]::Out.WriteLine(
        "fm-tg-route: $($carried.Sent) answer(s) carried back, " +
        "$($carried.Waiting) still waiting on a worker, $($carried.Failed) not sent")
    exit 0
}

# Assigned before it is wrapped: the list comes back behind a unary comma so an
# empty record cannot unroll away, and wrapping the call directly would make
# "nothing recorded" one nameless element the loop below then reads properties off.
$found = Get-FmTelegramRoute -FirstmateHome $FirstmateHome -IncludeAnswered:$All
$routes = @($found)
if ($Task) { $routes = @($found | Where-Object { $_.Task -eq $Task }) }

if ($routes.Count -eq 0) {
    [Console]::Out.WriteLine('fm-tg-route: no phone message is waiting on a worker')
    exit 0
}

# One line per routing, for firstmate rather than for the captain - so the task id
# IS wanted here, exactly as it is unwanted in anything the channel sends.
foreach ($route in $routes) {
    $state = if ($route.Answered) { 'answered' } elseif ($route.Reported) { 'ready' } else { 'waiting' }
    [Console]::Out.WriteLine("$state`t$($route.Task)`tasked: $($route.Message)")
    if ($route.Answer) { [Console]::Out.WriteLine("        reply: $($route.Answer)") }
}
exit 0
