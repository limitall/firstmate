#requires -Version 7.0
# The voice channel's internals: the opt-in switch, the utterance bound, the
# voice-name fallback, and the two seams that touch the speech engine.
#
# WHY THE ENGINE IS BEHIND TWO SMALL FUNCTIONS. Everything else here is pure and
# testable; System.Speech is neither. Get-FmInstalledSpeechVoice and
# Invoke-FmSpeechRequest are the only functions in this port that construct a
# synthesizer, so the suite mocks exactly those two and never makes a sound on a
# developer's machine - and the "no speech engine at all" path stays provable on
# hardware that has one. See docs/voice-windows.md.
#
# NOTHING HERE THROWS. fm-say is called from supervision paths, where a missing
# audio device must not end a turn, so both seams answer with a verdict object
# rather than an error and every engine call is wrapped.

function Get-FmVoiceMaxLength {
    <#
        .SYNOPSIS
        The utterance bound, in characters.

        .DESCRIPTION
        200 characters is roughly 15 seconds at the default rate. The cap exists
        because a paragraph read aloud is unusable, not to save time: the
        captain cannot re-read a spoken sentence, so a spoken message has to be
        one they can hold in their head at first hearing.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return 200
}

function Get-FmVoiceSpeechText {
    <#
        .SYNOPSIS
        Bound one message to a speakable length, audibly.

        .DESCRIPTION
        A silent truncation is worse than a long message: the captain would hear
        a sentence stop mid-clause and have no way to tell whether the machine
        was cut off or the news simply ended there. An over-long message is cut
        at a word boundary where one is near enough, and always ends with a
        spoken marker saying so.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    $text = ($Message -replace '\s+', ' ').Trim()
    $max = Get-FmVoiceMaxLength
    if ($text.Length -le $max) {
        return [pscustomobject]@{ Text = $text; Truncated = $false }
    }

    $head = $text.Substring(0, $max)
    $break = $head.LastIndexOf(' ')
    # Only honour a word boundary that is not most of the way back up the
    # message; a 200-character word (a path, a URL) has no useful boundary.
    if ($break -ge [int]($max * 0.6)) { $head = $head.Substring(0, $break) }
    return [pscustomobject]@{
        Text      = ($head.TrimEnd() + ', message truncated')
        Truncated = $true
    }
}

function Get-FmVoiceConfig {
    <#
        .SYNOPSIS
        Read config/voice: is the voice on, and which voice at which rate.

        .DESCRIPTION
        OFF BY DEFAULT, and the default is the absence of the file - a machine
        that starts talking without being asked is a bug, so there is no value
        of any other config that turns speech on. Present means on, unless its
        first meaningful line is `off`, which lets the captain silence the
        machine without losing their voice and rate choice.

        The format is config/autolaunch's: `#` comments and blank lines are
        ignored, and the rest is key=value. A voice name contains spaces
        ("Microsoft Hazel Desktop"), which is why this is key=value rather than
        the space-separated token line config/secondmate-harness uses.

            # config/voice
            voice=Microsoft Hazel Desktop
            rate=1

        WHERE THIS DIVERGES FROM config/autolaunch, and why. That reader refuses
        an unusable file outright, because a typo must not silently disable a
        feature the captain believes is on. The same principle applies here and
        reaches the opposite answer on the refusal: staying silent is the very
        failure being guarded against, so an unusable line is REPORTED and the
        message is still spoken. Every problem the file has comes back in
        Warning for the caller to surface - what must never happen is that it
        goes unmentioned.

        An unreadable file is off rather than an error: this is called from
        supervision paths.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $result = [pscustomobject]@{ Enabled = $false; VoiceName = ''; Rate = 0; Warning = '' }

    $pathArgs = @{ Name = 'voice' }
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $pathArgs['HomePath'] = $HomePath }
    try {
        $path = Get-FmConfigPath @pathArgs
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
        $lines = [System.IO.File]::ReadAllLines($path)
    } catch {
        return $result
    }

    $enabled = $true
    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $number = 0
    foreach ($line in $lines) {
        $number++
        $trimmed = "$line".Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) {
            if ($trimmed -eq 'off') { $enabled = $false } else {
                $problems.Add("line ${number}: expected key=value or a lone 'off', got '$trimmed'")
            }
            continue
        }
        # Keys are case-sensitive, as config/autolaunch's are: 'Voice=' is a
        # typo that would otherwise be indistinguishable from no choice at all.
        $key = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($key -cnotin @('voice', 'rate')) {
            $problems.Add("line ${number}: unknown key '$key' (expected voice or rate)")
            continue
        }
        if (-not $seen.Add($key)) {
            $problems.Add("line ${number}: '$key' is set twice; the last one wins")
        }
        if ($key -ceq 'voice') {
            $result.VoiceName = $value
        } else {
            $rate = ConvertTo-FmVoiceRate -Value $value
            $result.Rate = $rate.Rate
            if ($rate.Problem) { $problems.Add("line ${number}: $($rate.Problem)") }
        }
    }

    $result.Enabled = $enabled
    $result.Warning = ($problems -join '; ')
    return $result
}

function ConvertTo-FmVoiceRate {
    <#
        .SYNOPSIS
        A configured rate as the engine's -10..10 integer.

        .DESCRIPTION
        Out of range is clamped and unparseable is the default, and neither
        refuses: the same reason an unknown voice name falls back rather than
        failing. A typo in config/voice must not be the thing that stops an
        escalation being heard - but it is reported through Problem, so it is
        not silent either.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $parsed = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$parsed)) {
        return [pscustomobject]@{ Rate = 0; Problem = "rate '$Value' is not a number; using the default rate" }
    }
    if ($parsed -lt -10) {
        return [pscustomobject]@{ Rate = -10; Problem = "rate $parsed is below the engine's range; using -10" }
    }
    if ($parsed -gt 10) {
        return [pscustomobject]@{ Rate = 10; Problem = "rate $parsed is above the engine's range; using 10" }
    }
    return [pscustomobject]@{ Rate = $parsed; Problem = '' }
}

function Resolve-FmVoiceName {
    <#
        .SYNOPSIS
        A configured voice name matched against the installed voices.

        .DESCRIPTION
        Returns '' - meaning "the engine's own default" - for a name nothing
        installed matches, so a voice renamed by a Windows update degrades to a
        different voice rather than to silence. Matching is case-insensitive and
        exact: the installed set here holds both "Hazel" and "Microsoft Hazel
        Desktop", so a prefix match would pick between them arbitrarily.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Requested,
        [string[]]$Installed = @()
    )

    $name = $Requested.Trim()
    if (-not $name) { return '' }
    foreach ($candidate in @($Installed)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([string]::Equals($candidate.Trim(), $name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $candidate.Trim()
        }
    }
    return ''
}

function Get-FmInstalledSpeechVoice {
    <#
        .SYNOPSIS
        The names of the installed speech voices, or nothing at all.

        .DESCRIPTION
        Engine seam. An empty result means "could not ask" as well as "none
        installed"; the caller treats both the same way, by asking for the
        engine's default voice and letting the speak attempt report the
        outcome.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $synth = $null
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        return [string[]]@($synth.GetInstalledVoices() |
                Where-Object { $_.Enabled } |
                ForEach-Object { $_.VoiceInfo.Name })
    } catch {
        return [string[]]@()
    } finally {
        if ($null -ne $synth) { Clear-FmSpeechSynthesizer -Synthesizer $synth }
    }
}

function Invoke-FmSpeechRequest {
    <#
        .SYNOPSIS
        Speak one bounded message. Engine seam; never throws.

        .DESCRIPTION
        SpeakAsync with a bounded wait, not Speak. Speak() blocks for as long as
        the engine decides to take, and an engine waiting on a device that will
        never answer never returns at all - which in a supervision path is a
        wedged turn. The async form gives both a deadline and a cancel, so the
        worst case is a caller delayed by TimeoutSeconds rather than a caller
        that never comes back.

        Returns Spoken=$false with a reason for every failure: no engine, no
        audio device, a busy engine, or the deadline.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$VoiceName = '',
        [int]$Rate = 0,
        [int]$TimeoutSeconds = 30
    )

    $synth = $null
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $synth.SetOutputToDefaultAudioDevice()
        $synth.Rate = $Rate
        if ($VoiceName) {
            # Already matched against the installed set, so this is the narrow
            # race where a voice disappeared in between - still not a reason to
            # stay silent.
            try {
                $synth.SelectVoice($VoiceName)
            } catch {
                Write-Verbose "fm-say: voice '$VoiceName' could not be selected; using the default"
            }
        }

        $prompt = $synth.SpeakAsync($Text)
        $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
        while (-not $prompt.IsCompleted -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not $prompt.IsCompleted) {
            try {
                $synth.SpeakAsyncCancelAll()
            } catch {
                Write-Verbose "fm-say: the engine did not accept a cancel: $($_.Exception.Message)"
            }
            return [pscustomobject]@{ Spoken = $false; Reason = 'timeout' }
        }
        return [pscustomobject]@{ Spoken = $true; Reason = 'spoken' }
    } catch {
        return [pscustomobject]@{ Spoken = $false; Reason = 'unavailable' }
    } finally {
        if ($null -ne $synth) { Clear-FmSpeechSynthesizer -Synthesizer $synth }
    }
}

function Clear-FmSpeechSynthesizer {
    <#
        .SYNOPSIS
        Release a synthesizer, whatever state it is in.

        .DESCRIPTION
        Disposing an engine that is mid-utterance, or whose device has gone
        away, can raise - in a finally block, where a raised error would replace
        the verdict the caller is waiting for with an exception. One owner for
        that, so neither seam has to repeat it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)]$Synthesizer)

    try {
        $Synthesizer.Dispose()
    } catch {
        Write-Verbose "fm-say: releasing the speech engine failed: $($_.Exception.Message)"
    }
}
