#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Speak one short message aloud, if the captain has turned the voice on.

.DESCRIPTION
Half of the voice channel: the spoken alert. There is no spoken question here -
`fm-ask` is not ported, so nothing this port says can be answered by talking
back, and an escalation that needs an answer still has to reach the captain in
chat.

OFF BY DEFAULT, and the switch is the presence of `config/voice`. Nothing else
turns it on. A machine that starts talking because some other setting changed is
a bug, not a feature.

NEVER THROWS, and never blocks indefinitely. Supervision paths call this, and a
turn must not die because a speaker is unplugged, an audio device is missing, or
the speech engine is busy. Every failure comes back as `Spoken = $false` with a
reason, and the speaking itself is bounded by -TimeoutSeconds.

WHAT IT SPEAKS IS WHAT YOU PASS. This applies AGENTS.md section 9's translation
contract to the caller, not to the message: no task ids, no worktrees, no wake
types, no harness names, no status prefixes. The guard belongs where the message
is written because only there is the outcome known - and a spoken internal label
is worse than a written one, because the captain cannot re-read it to work out
what the machine meant.

A message longer than the utterance bound is truncated audibly, ending in
"message truncated" - see Get-FmVoiceMaxLength for the bound and why one exists.

.PARAMETER Message
What to say, in the captain's nouns.

.PARAMETER FirstmateHome
Read config/voice from this home instead of the resolved one.

.PARAMETER TimeoutSeconds
Hard ceiling on the wait for the utterance to finish. The engine is asked to
speak asynchronously and this is how long the caller is willing to be delayed;
past it, the utterance is cancelled and the result reports `timeout`.

.OUTPUTS
[pscustomobject] with Spoken, Reason (spoken, off, suppressed, empty, unavailable, timeout),
Text (what was actually spoken), Truncated, Voice ('' means the engine default),
Rate, and Warning.

WARNING IS NOT A FAILURE, and it is not optional to surface. It carries what
`config/voice` got wrong - an unknown key, a rate out of range, a voice that is
not installed - while the message is spoken anyway. `config/autolaunch` refuses
such a file outright so a typo cannot silently disable a feature the captain
believes is on; here, refusing WOULD be that silence, so the message goes out
and the problem is reported instead. A caller that drops Warning reintroduces
exactly the failure both readers are shaped to avoid.

.EXAMPLE
Invoke-FmSay -Message 'The payments fix is ready for your review.'

.EXAMPLE
$said = Invoke-FmSay -Message 'A decision is waiting.'
if (-not $said.Spoken) { 'nothing was said aloud; it still has to reach the captain in chat' }
#>
function Invoke-FmSay {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [string]$FirstmateHome = '',
        [int]$TimeoutSeconds = 30
    )

    $result = [pscustomobject]@{
        Spoken    = $false
        Reason    = 'off'
        Text      = ''
        Truncated = $false
        Voice     = ''
        Rate      = 0
        Warning   = ''
    }

    try {
        # BEFORE THE CONFIG, because this outranks it. A process whose parent
        # owns the speaking - the browser bridge - may not reach an engine
        # whatever this home's config/voice says. Test-FmVoiceSuppressed carries
        # what that cost when it was missing.
        if (Test-FmVoiceSuppressed) {
            $result.Reason = 'suppressed'
            return $result
        }

        $configArgs = @{}
        if ($FirstmateHome) { $configArgs['HomePath'] = $FirstmateHome }
        $config = Get-FmVoiceConfig @configArgs
        $result.Warning = $config.Warning
        if (-not $config.Enabled) { return $result }
        $result.Rate = $config.Rate

        $bounded = Get-FmVoiceSpeechText -Message $Message
        $result.Text = $bounded.Text
        $result.Truncated = $bounded.Truncated
        if (-not $bounded.Text) {
            $result.Reason = 'empty'
            return $result
        }

        # Only ask which voices exist when a voice was actually asked for:
        # listing them costs a second synthesizer, and the common config names
        # none at all.
        if ($config.VoiceName) {
            $result.Voice = Resolve-FmVoiceName -Requested $config.VoiceName -Installed (Get-FmInstalledSpeechVoice)
            if (-not $result.Voice) {
                $result.Warning = @($result.Warning,
                    "voice '$($config.VoiceName)' is not installed; using the default voice" |
                        Where-Object { $_ }) -join '; '
            }
        }
        $verdict = Invoke-FmSpeechRequest -Text $bounded.Text -VoiceName $result.Voice `
            -Rate $config.Rate -TimeoutSeconds $TimeoutSeconds
        $result.Spoken = [bool]$verdict.Spoken
        $result.Reason = $verdict.Reason
        return $result
    } catch {
        # The seams already answer instead of throwing; this is the backstop for
        # everything else, because the one thing this function may never do is
        # end its caller's turn.
        $result.Spoken = $false
        $result.Reason = 'unavailable'
        return $result
    }
}
