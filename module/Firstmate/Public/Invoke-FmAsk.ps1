#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Speak one short question aloud and listen for the captain's spoken answer.

.DESCRIPTION
The other half of the voice channel. `Invoke-FmSay` tells the captain something;
this asks them something and reports what it heard.

A CLOSED GRAMMAR, NOT DICTATION. The caller supplies the options, and the
recognizer is given exactly those words to choose between. Transcribing an
arbitrary spoken sentence is a far harder and far less reliable problem than
picking one of three known words, and this decides actions - so the easy problem
is the only one asked.

WHAT IT HEARD AND HOW SURE IT WAS, ALWAYS, whatever the verdict. `Heard` and
`Confidence` are populated on every path where a sound reached the recognizer,
including the path where the answer was refused for being too uncertain. A caller
must be able to tell "the captain said yes" from "something sounded a bit like
yes", and it cannot do that from a bare option with the uncertainty thrown away.

IT REFUSES RATHER THAN GUESSES. Below `MinimumConfidence` there is no answer at
all - `Answered` is `$false`, `Answer` is empty, and `Reason` is `unsure`. A
misheard answer acts on something the captain did not say, and one repeated word
is a much cheaper mistake than that.

NEVER THROWS, AND NEVER WAITS FOREVER, exactly as `Invoke-FmSay` does not. No
recognizer, no microphone, no speech engine, a voice that is off, silence, a
degenerate option set: each is a verdict with a reason, never an error and never
an unbounded wait. A supervision path must not die because a microphone is
unplugged.

THE MICROPHONE IS NEVER OPENED UNLESS THE CAPTAIN TURNED THE VOICE ON, and never
for a question that was not actually spoken. `config/voice` is the whole switch,
the same one `fm-say` reads; with the voice off this returns `off` having
listened to nothing. And when the question could not be spoken - no engine, the
utterance outran its deadline, or this process's parent owns the speaking
(`FM_VOICE_OFF`) - this returns `unspoken` rather than listening for the answer
to a question nobody was asked.

.PARAMETER Question
What to ask, in the captain's nouns. `AGENTS.md` section 9's translation contract
binds the caller here exactly as it does for `Invoke-FmSay`, and more tightly: the
captain cannot re-read a spoken question before answering it.

.PARAMETER Option
The answers to choose between - at least two distinct ones. One option is not a
question: every sound the recognizer decides is speech would become that option,
and the caller would get its own expectation back dressed as the captain's.

.PARAMETER FirstmateHome
Read config/voice from this home instead of the resolved one.

.PARAMETER MinimumConfidence
The floor a spoken answer must reach, 0 to 1. Defaults to `confidence=` in
config/voice, and to `Get-FmVoiceMinimumConfidence` when that is not set.

.PARAMETER SpeakSeconds
Hard ceiling on the wait for the question to finish being spoken.

.PARAMETER ListenSeconds
Hard ceiling on the wait for an answer. Past it there is no answer and `Reason`
is `silence`. The worst case for the whole call is SpeakSeconds + ListenSeconds.

.OUTPUTS
[pscustomobject] with Answered, Answer, Heard, Confidence, MinimumConfidence,
Reason, SufficientAuthority, Spoken, Question, Option and Warning.

Reason is one of: answered, off, unsure, silence, unavailable, refused, invalid,
unspoken.

Warning carries what config/voice got wrong while the question was asked anyway -
Invoke-FmSay's contract, unchanged and equally not optional to surface. On the
two Reasons that ARE a refusal, `refused` and `invalid`, it leads with that
refusal's reason instead - one field, because a caller that surfaces it is
correct either way and a second field would be one more thing to drop.

SUFFICIENTAUTHORITY IS ALWAYS $false, and no input makes it true. AGENTS.md's
captain-instruction precedence rule requires the captain to state a destructive,
irreversible, security-sensitive, discard or merge action explicitly, and a
recognizer that is right most of the time does not clear that bar. A question
that would collect one is refused outright before anything is spoken - see
Get-FmVoiceAuthorityRefusal - and this constant is what says the same thing about
every answer that was not refused, so a caller reading the result finds the
boundary rather than having to already know it.

SPEAKING IS NEVER DELIVERY. Whatever this returns, the same question must remain
answerable in chat, and `decision-hold-lifecycle` still owns the decision's
lifecycle. A spoken answer is evidence of what the captain said; it never closes
a hold and never substitutes for their written word.

.EXAMPLE
$heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no
if ($heard.Answered) { "the captain said $($heard.Answer) at $($heard.Confidence)" }

.EXAMPLE
$heard = Invoke-FmAsk -Question 'Shall I merge this?' -Option yes, no
$heard.Reason   # refused - that answer has to be the captain's written word
#>
function Invoke-FmAsk {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Question,
        [Parameter(Position = 1)][Alias('Options')][AllowEmptyCollection()][AllowNull()]
        [string[]]$Option = @(),
        [string]$FirstmateHome = '',
        [double]$MinimumConfidence = -1,
        [int]$SpeakSeconds = 30,
        [int]$ListenSeconds = 15
    )

    $result = [pscustomobject]@{
        Answered            = $false
        Answer              = ''
        Heard               = ''
        Confidence          = 0.0
        MinimumConfidence   = Get-FmVoiceMinimumConfidence
        Reason              = 'off'
        SufficientAuthority = $false
        Spoken              = $false
        Question            = "$Question"
        Option              = [string[]]@()
        Warning             = ''
    }

    try {
        # THE AUTHORITY REFUSAL COMES FIRST, before the config is read and before
        # anything is spoken. A question this port may not collect by voice is not
        # asked at all - asking it and then discounting the answer would still put
        # the words in the room.
        $refusal = Get-FmVoiceAuthorityRefusal -Question $Question -Option $Option
        if ($refusal) {
            $result.Reason = 'refused'
            $result.Warning = $refusal
            return $result
        }

        $options = Get-FmVoiceOptionSet -Option $Option
        if ($options.Problem) {
            $result.Reason = 'invalid'
            $result.Warning = $options.Problem
            return $result
        }
        $result.Option = $options.Option

        if ($PSBoundParameters.ContainsKey('MinimumConfidence') -and
            ($MinimumConfidence -lt 0 -or $MinimumConfidence -gt 1)) {
            $result.Reason = 'invalid'
            $result.Warning = "MinimumConfidence $MinimumConfidence is outside 0 to 1"
            return $result
        }

        $configArgs = @{}
        if ($FirstmateHome) { $configArgs['HomePath'] = $FirstmateHome }
        $config = Get-FmVoiceConfig @configArgs
        $result.Warning = $config.Warning
        $result.MinimumConfidence = if ($PSBoundParameters.ContainsKey('MinimumConfidence')) {
            $MinimumConfidence
        } else {
            $config.MinimumConfidence
        }
        if (-not $config.Enabled) { return $result }

        # Ask the question through the same entry the alert uses, so the voice,
        # the rate, the utterance bound and the config warnings have exactly one
        # owner rather than a second copy that drifts.
        $sayArgs = @{ Message = $Question; TimeoutSeconds = $SpeakSeconds }
        if ($FirstmateHome) { $sayArgs['FirstmateHome'] = $FirstmateHome }
        $said = Invoke-FmSay @sayArgs
        $result.Spoken = [bool]$said.Spoken
        $result.Question = $said.Text
        if ($said.Warning) { $result.Warning = $said.Warning }
        if (-not $said.Spoken) {
            # 'empty' is a caller bug (no question), the rest is the machine.
            $result.Reason = if ($said.Reason -eq 'empty') { 'invalid' } else { 'unspoken' }
            if ($result.Reason -eq 'invalid') {
                $result.Warning = @($result.Warning, 'there was no question to ask' |
                        Where-Object { $_ }) -join '; '
            }
            return $result
        }

        # Ask whether this machine can hear at all before opening a listening
        # window against an engine that was never going to answer.
        if (@(Get-FmInstalledSpeechRecognizer).Count -eq 0) {
            $result.Reason = 'unavailable'
            return $result
        }

        $verdict = Invoke-FmSpeechListenRequest -Option $result.Option -TimeoutSeconds $ListenSeconds
        if ($verdict.Reason -ne 'heard') {
            $result.Reason = $verdict.Reason
            return $result
        }

        $result.Heard = [string]$verdict.Heard
        $result.Confidence = [double]$verdict.Confidence

        # A closed grammar should not produce a word that was not offered, but the
        # recognizer is another component's idea of what that grammar meant, and a
        # caller may never be handed an answer it did not put on the list.
        $matched = Resolve-FmVoiceAnswer -Heard $result.Heard -Option $result.Option
        if (-not $matched -or $result.Confidence -lt $result.MinimumConfidence) {
            $result.Reason = 'unsure'
            return $result
        }

        $result.Answer = $matched
        $result.Answered = $true
        $result.Reason = 'answered'
        return $result
    } catch {
        # The seams already answer instead of throwing; this is the backstop for
        # everything else, because the one thing this function may never do is end
        # its caller's turn.
        $result.Answered = $false
        $result.Answer = ''
        $result.Reason = 'unavailable'
        return $result
    }
}
