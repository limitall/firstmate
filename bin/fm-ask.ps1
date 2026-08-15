#requires -Version 7.0

# NOTE ON THE BLANK LINES around this help block: PowerShell only attaches
# comment-based help to a SCRIPT when the block is separated from #requires and
# from param() by a blank line. Without them Get-Help prints the syntax line and
# nothing else, and `-h` below silently becomes useless.

<#
.SYNOPSIS
fm-ask.ps1 - ask the captain one short question out loud and listen for which of
the given options they say.

.DESCRIPTION
Thin entry point over Invoke-FmAsk, and the other half of the voice channel:
`fm-say.ps1` tells the captain something, this asks them something.

    ./bin/fm-ask.ps1 "Ready to land?" -Options yes,no

IT PICKS BETWEEN THE OPTIONS YOU GIVE IT. They become a closed grammar, so the
recognizer chooses between known words instead of transcribing a sentence.
Free-form recognition of an arbitrary sentence is far less reliable than picking
between three known words, and this decides actions. At least two distinct
options are required - one option is not a question. `-Options` takes either a
comma-separated string or a list, so the documented form works whether it is
typed in a PowerShell session or passed through `pwsh -File`; an option
therefore may not contain a comma.

OFF BY DEFAULT, and the switch is the same `<home>/config/voice` that `fm-say`
reads; there is not a second one. With no such file this asks nothing, LISTENS TO
NOTHING, and exits 0. The microphone is never opened unless the captain turned
the voice on, and never for a question that could not actually be spoken.

    # config/voice - presence turns the voice on
    voice=Microsoft Hazel Desktop
    rate=1
    confidence=0.75

`confidence` is the floor an answer must reach, 0 to 1, and it defaults to 0.75.
It is high on purpose: a closed-grammar match that only reaches 0.6 is the engine
telling you it guessed, and a refusal costs one repeated word where a wrong
answer acts on something the captain did not say. `-MinimumConfidence` overrides
it for one call. Below the floor there is NO ANSWER - `answer=` comes back empty,
with `reason=unsure` and the text and confidence it did hear.

WHAT IT HEARD AND HOW SURE IT WAS, ALWAYS. Four lines on stdout, on every path:

    answer=yes
    heard=yes
    confidence=0.87
    reason=answered

`answer` is empty unless something cleared the floor. `heard` and `confidence`
are what actually reached the recognizer, kept even when the answer was refused
for being too uncertain - "the captain said yes" and "something sounded a bit
like yes" are different facts. `reason` is one of answered, off, unsure, silence,
unavailable, refused, invalid, unspoken.

A SPOKEN ANSWER IS NOT THE CAPTAIN'S EXPLICIT WORD FOR A MERGE, A DISCARD, A
DELETE, OR ANYTHING DESTRUCTIVE OR IRREVERSIBLE. `AGENTS.md`'s captain-instruction
precedence rule requires the captain to state those explicitly, and a recognizer
that is right most of the time does not clear that bar. A question that would
collect one is REFUSED outright, before anything is spoken: `reason=refused`,
exit 1. Nothing this command returns ever carries that authority, and no option
and no config makes it do so.

SPEAKING IS NEVER DELIVERY. Whatever comes back, the same question must remain
answerable in chat, and the decision's lifecycle is unchanged - a spoken answer is
evidence of what the captain said, never a substitute for their written word and
never the thing that closes a decision.

SAY IT IN THE CAPTAIN'S NOUNS. The question is spoken exactly as passed, so the
caller owns AGENTS.md section 9's translation contract - and more tightly than
for an alert, because the captain cannot re-read a spoken question before
answering it. Long questions are truncated audibly, ending in "message
truncated".

NEVER FATAL, AND NEVER UNBOUNDED. No recognizer, no microphone, no speech engine,
a voice that is off, or silence are all outcomes rather than failures, and each
exits 0 with one line on stderr saying why. The whole call is bounded by
`-SpeakSeconds` plus `-ListenSeconds`.

Exit codes: 0 answered or cleanly unanswered, 1 refused or unusable options,
2 usage.

.EXAMPLE
./bin/fm-ask.ps1 "Ready to land?" -Options yes,no

.EXAMPLE
./bin/fm-ask.ps1 -ListenSeconds 30 -MinimumConfidence 0.9 "Which one first?" -Options payments,checkout
#>

# THE QUESTION IS POSITION 0 AND TAKES EVERY REMAINING WORD, for the reason
# fm-say.ps1 records: declaring it last binds the question's SECOND word to the
# next positional parameter.
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Question = @(),
    [Alias('Option')][string[]]$Options = @(),
    [string]$FirstmateHome = '',
    [double]$MinimumConfidence = -1,
    [int]$SpeakSeconds = 30,
    [int]$ListenSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Question.Count -ge 1 -and ($Question[0] -eq '-h' -or $Question[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Invoke-FmAsk'

$text = ($Question -join ' ').Trim()

# `-Options yes,no` REACHES THIS SCRIPT TWO DIFFERENT WAYS, and both have to
# work. Typed in a PowerShell session that is an array literal and arrives as two
# elements; run through `pwsh -File` from a herdr pane, a Claude hook or any
# non-PowerShell caller it is one string, `yes,no`, and binding that unsplit
# would leave a one-option grammar - the exact degenerate set Invoke-FmAsk
# refuses, discovered only at run time by whoever typed the documented form. So
# the comma is split here, which is also why an option may not contain one.
$choice = @(@($Options) | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ })
if (-not $text -or $choice.Count -eq 0) {
    [Console]::Error.WriteLine('usage: fm-ask.ps1 <question...> -Options <a>,<b>[,<c>...]')
    exit 2
}

$askArgs = @{
    Question      = $text
    Option        = $choice
    FirstmateHome = $FirstmateHome
    SpeakSeconds  = $SpeakSeconds
    ListenSeconds = $ListenSeconds
}
if ($PSBoundParameters.ContainsKey('MinimumConfidence')) { $askArgs['MinimumConfidence'] = $MinimumConfidence }
$heard = Invoke-FmAsk @askArgs

# Invariant culture on purpose: `0.87` must not become `0,87` on a machine whose
# decimal separator is a comma, or every caller parsing this line breaks there
# and nowhere else.
$confidence = ([double]$heard.Confidence).ToString('0.00', [cultureinfo]::InvariantCulture)
Write-Output "answer=$($heard.Answer)"
Write-Output "heard=$($heard.Heard)"
Write-Output "confidence=$confidence"
Write-Output "reason=$($heard.Reason)"

# A config typo is asked through, never refused - but never swallowed either. The
# refusal reasons travel in the same field and are printed by the line below
# instead, so they are not said twice.
if ($heard.Warning -and $heard.Reason -notin @('refused', 'invalid')) {
    [Console]::Error.WriteLine("fm-ask: config/voice: $($heard.Warning)")
}

if ($heard.Answered) { exit 0 }

# Not answered is a normal outcome for most of these reasons, so they get one
# plain line and exit 0 - a supervision turn must not end because nobody was at
# the microphone. A refusal and an unusable option set are the caller's mistakes,
# not the room's, and those exit 1.
$why = switch ($heard.Reason) {
    'off' { 'the voice is off (create config/voice to turn it on)' }
    'unsure' { "'$($heard.Heard)' was only $confidence sure, below the $($heard.MinimumConfidence) floor" }
    'silence' { "nothing was said within $ListenSeconds seconds" }
    'unspoken' { 'the question could not be spoken, so nothing was listened for' }
    'refused' { $heard.Warning }
    'invalid' { $heard.Warning }
    default { 'no speech recognizer, microphone or audio device is available' }
}
[Console]::Error.WriteLine("fm-ask: no answer - $why")
if ($heard.Reason -in @('refused', 'invalid')) { exit 1 }
exit 0
