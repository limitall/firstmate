#requires -Version 7.0

# NOTE ON THE BLANK LINES around this help block: PowerShell only attaches
# comment-based help to a SCRIPT when the block is separated from #requires and
# from param() by a blank line. Without them Get-Help prints the syntax line and
# nothing else, and `-h` below silently becomes useless.

<#
.SYNOPSIS
fm-say.ps1 - say one short message out loud, so the captain hears it without
watching the terminal.

.DESCRIPTION
Thin entry point over Invoke-FmSay. Half of the voice channel: this port speaks
but cannot listen, so an escalation that needs an answer still reaches the
captain in chat.

OFF BY DEFAULT. Speech happens only when `<home>/config/voice` exists; with no
such file this command says nothing and exits 0. The file is `key=value`, and
its keys are optional:

    # config/voice - presence turns the voice on
    voice=Microsoft Hazel Desktop
    rate=1

`voice` is one of the installed voice names; an unknown name falls back to the
system default rather than failing. `rate` is -10 (slowest) to 10 (fastest),
default 0, and is clamped rather than rejected. A lone `off` line silences the
machine while keeping those choices.

Unlike `config/autolaunch`, a problem in this file is never a refusal - refusing
to speak is the failure being guarded against. It is reported instead: an
unknown key, a rate out of range, or a voice that is not installed each print
one `config/voice:` line on stderr, and the message is still spoken.

SAY IT IN THE CAPTAIN'S NOUNS. The message is spoken exactly as passed, so the
caller owns AGENTS.md section 9's translation contract: no task ids, no
worktrees, no wake types, no harness names, no status prefixes. A spoken
internal label is worse than a written one - the captain cannot re-read it.

Long messages are truncated audibly, ending in "message truncated".

NEVER FATAL. A missing speech engine, a machine with no audio device, a busy
engine, or the voice being off are all outcomes, not failures: this is called
from supervision paths, where a turn must not end because a speaker is
unplugged. When nothing was said, one line on stderr says why.

Exit codes: 0 spoken or deliberately silent, 2 usage. There is no failure exit
here on purpose.

.EXAMPLE
./bin/fm-say.ps1 "the payments fix is ready for your review"

.EXAMPLE
./bin/fm-say.ps1 -TimeoutSeconds 5 "a decision is waiting"
#>

# THE MESSAGE IS POSITION 0 AND TAKES EVERY REMAINING WORD. Declaring it last
# instead - after two typed parameters, as an ordinary remaining-arguments list -
# binds the message's SECOND word to the next positional parameter, so
# `fm-say.ps1 hello captain` dies converting "captain" to an integer.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Message = @(),
    [string]$FirstmateHome = '',
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Message.Count -ge 1 -and ($Message[0] -eq '-h' -or $Message[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmSay'

$text = ($Message -join ' ').Trim()
if (-not $text) {
    [Console]::Error.WriteLine('usage: fm-say.ps1 <message...>')
    exit 2
}

$said = Invoke-FmSay -Message $text -FirstmateHome $FirstmateHome -TimeoutSeconds $TimeoutSeconds

# A config typo is spoken through, never refused - but never swallowed either,
# or the captain believes a voice or rate is in use that never was.
if ($said.Warning) { [Console]::Error.WriteLine("fm-say: config/voice: $($said.Warning)") }
if ($said.Spoken) { exit 0 }

# Not spoken is a normal outcome, so this is one plain line for whoever is
# watching - never an error record, and never a non-zero exit that could end a
# supervision turn.
$why = switch ($said.Reason) {
    'off' { 'the voice is off (create config/voice to turn it on)' }
    'empty' { 'there was nothing to say' }
    'timeout' { "the utterance did not finish within $TimeoutSeconds seconds" }
    default { 'no speech engine or audio device is available' }
}
[Console]::Error.WriteLine("fm-say: not spoken - $why")
exit 0
