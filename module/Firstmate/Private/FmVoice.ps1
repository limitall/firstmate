#requires -Version 7.0
# The voice channel's internals: the opt-in switch, the utterance bound, the
# voice-name fallback, the confidence floor, the authority refusal, and the four
# seams that touch the speech engine.
#
# WHY THE ENGINE IS BEHIND FOUR SMALL FUNCTIONS. Everything else here is pure and
# testable; System.Speech is neither. Get-FmInstalledSpeechVoice,
# Invoke-FmSpeechRequest, Get-FmInstalledSpeechRecognizer and
# Invoke-FmSpeechListenRequest are the only functions in this port that construct
# a synthesizer or a recognizer, so the suite mocks exactly those four and never
# makes a sound or opens a microphone on a developer's machine - and the "no
# speech engine at all" path stays provable on hardware that has one. See
# docs/voice-windows.md.
#
# NOTHING HERE THROWS. fm-say and fm-ask are called from supervision paths, where
# a missing audio device must not end a turn, so every seam answers with a
# verdict object rather than an error and every engine call is wrapped.

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
        Read config/voice: is the voice on, which voice at which rate, and how
        sure a spoken answer has to be.

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
            confidence=0.75

        ONE FILE FOR THE WHOLE CHANNEL, both halves. `confidence` is the floor
        fm-ask needs a spoken answer to clear, and it lives here rather than in a
        second file because the captain who turns the voice on is the same
        captain who decides how sure the machine has to be before it repeats what
        it thinks it heard.

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

    $result = [pscustomobject]@{
        Enabled           = $false
        VoiceName         = ''
        Rate              = 0
        MinimumConfidence = Get-FmVoiceMinimumConfidence
        Warning           = ''
    }

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
        if ($key -cnotin @('voice', 'rate', 'confidence')) {
            $problems.Add("line ${number}: unknown key '$key' (expected voice, rate or confidence)")
            continue
        }
        if (-not $seen.Add($key)) {
            $problems.Add("line ${number}: '$key' is set twice; the last one wins")
        }
        switch -CaseSensitive ($key) {
            'voice' { $result.VoiceName = $value }
            'rate' {
                $rate = ConvertTo-FmVoiceRate -Value $value
                $result.Rate = $rate.Rate
                if ($rate.Problem) { $problems.Add("line ${number}: $($rate.Problem)") }
            }
            'confidence' {
                $floor = ConvertTo-FmVoiceConfidence -Value $value
                $result.MinimumConfidence = $floor.Confidence
                if ($floor.Problem) { $problems.Add("line ${number}: $($floor.Problem)") }
            }
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

function Get-FmVoiceMinimumConfidence {
    <#
        .SYNOPSIS
        The confidence a spoken answer must reach to count as an answer.

        .DESCRIPTION
        0.75 on the engine's 0-to-1 scale, and it is deliberately high.

        The whole reason fm-ask builds a closed grammar from the caller's options
        is that picking between three known words is a far easier problem than
        transcribing a sentence - so an answer that clears a closed grammar and
        still only reaches 0.6 is one the engine is telling you it guessed. The
        cost of the two mistakes is not symmetric: a refusal costs the captain
        one repeated word, and a wrong answer acts on something they did not say.
        So this sits above where a closed-grammar match usually lands rather than
        at the middle of the range, and the captain can lower it with
        `confidence=` in config/voice if their microphone makes it tiresome.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()
    return 0.75
}

function ConvertTo-FmVoiceConfidence {
    <#
        .SYNOPSIS
        A configured confidence floor as a 0-to-1 double.

        .DESCRIPTION
        Out of range is clamped and unparseable is the default, for the same
        reason ConvertTo-FmVoiceRate does neither: a typo in config/voice must
        not be the thing that decides whether the captain is heard. Both are
        reported through Problem.

        The parse is invariant-culture on purpose. `0.75` in a config file is
        `0.75` on a machine whose decimal separator is a comma, and a
        current-culture parse would silently read it as 75.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $default = Get-FmVoiceMinimumConfidence
    $parsed = 0.0
    $styles = [System.Globalization.NumberStyles]::Float
    if (-not [double]::TryParse($Value.Trim(), $styles, [cultureinfo]::InvariantCulture, [ref]$parsed)) {
        return [pscustomobject]@{
            Confidence = $default
            Problem    = "confidence '$Value' is not a number; using $default"
        }
    }
    if ($parsed -lt 0) {
        return [pscustomobject]@{ Confidence = 0.0; Problem = "confidence $parsed is below 0; using 0" }
    }
    if ($parsed -gt 1) {
        return [pscustomobject]@{ Confidence = 1.0; Problem = "confidence $parsed is above 1; using 1" }
    }
    return [pscustomobject]@{ Confidence = $parsed; Problem = '' }
}

function Get-FmVoiceOptionSet {
    <#
        .SYNOPSIS
        The caller's options as the closed set a grammar can be built from.

        .DESCRIPTION
        REFUSES RATHER THAN NORMALISES A DEGENERATE SET, which is the one place
        in this area that refuses at all. Two distinct options are the minimum: a
        one-option grammar has nothing to choose between, so every sound the
        recognizer decides is speech becomes that option and the answer carries
        the caller's own expectation back to them dressed as the captain's.

        Duplicates that differ only in case or surrounding space are the same
        option said twice, and are collapsed rather than refused. Two options
        that are genuinely the same word are refused, because the answer could
        not say which was meant.

        Returns Option (the trimmed, de-duplicated set) and Problem ('' when the
        set is usable).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$Option)

    $clean = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Option)) {
        $text = ("$candidate" -replace '\s+', ' ').Trim()
        if (-not $text) { continue }
        if ($seen.Add($text)) { $clean.Add($text) }
    }

    if ($clean.Count -lt 2) {
        return [pscustomobject]@{
            Option  = [string[]]@()
            Problem = 'a spoken question needs at least two distinct options to choose between'
        }
    }
    return [pscustomobject]@{ Option = [string[]]$clean.ToArray(); Problem = '' }
}

function Resolve-FmVoiceAnswer {
    <#
        .SYNOPSIS
        Recognized text matched back to the option the caller offered.

        .DESCRIPTION
        Returns '' for text that is not one of the options. The grammar is closed,
        so that should not happen - but the recognizer is another process's idea
        of what a grammar means, and a caller must never be handed an "answer"
        that was not on the list it supplied.

        Matching is exact and case-insensitive, never a prefix match, for the same
        reason Resolve-FmVoiceName is: a prefix match between two options the
        caller chose to distinguish would pick between them by list order.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Heard,
        [string[]]$Option = @()
    )

    $text = ("$Heard" -replace '\s+', ' ').Trim()
    if (-not $text) { return '' }
    foreach ($candidate in @($Option)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([string]::Equals($candidate.Trim(), $text, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $candidate.Trim()
        }
    }
    return ''
}

function Get-FmVoiceAuthorityRefusal {
    <#
        .SYNOPSIS
        The reason a question may not be asked by voice at all, or '' when it may.

        .DESCRIPTION
        THE AUTHORITY BOUNDARY, applied before anything is spoken. AGENTS.md's
        captain-instruction precedence rule requires the captain to state a
        destructive, irreversible, security-sensitive, discard or merge action
        explicitly, and a recognizer that is right most of the time does not
        clear that bar - so a question that would collect one is refused here
        rather than asked and then discounted afterwards.

        The word list is derived from those five categories and nothing else, so
        it has one owner and does not drift into a general profanity filter for
        risky-sounding work. It is matched on stems against the question AND the
        options, because "shall I do it?" with an option of "delete" is the same
        question as "shall I delete it?".

        THIS IS A GUARD AGAINST AN ACCIDENT, NOT A PROOF. A question phrased
        around the list ("shall I land it?") passes, which is why the boundary is
        also carried by Invoke-FmAsk's constant SufficientAuthority = $false:
        there is no wording, and no configuration, that makes a spoken answer the
        captain's explicit word.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Question,
        [string[]]$Option = @()
    )

    $text = (@(@($Question) + @($Option)) -join ' ')
    # Stems, so "deleting" and "merged" are caught with their roots. Ordered as
    # AGENTS.md orders the categories: destructive, irreversible,
    # security-sensitive, discard, merge.
    $stems = @(
        # 'wipe' rather than a 'wip' stem: the shorter one also matches WIP,
        # which is ordinary work rather than a destructive action.
        'destroy', 'destruct', 'delet', 'remov', 'eras', 'wipe', 'purg', 'truncat',
        'overwrit', 'uninstall', 'irreversib', 'unrecoverab', 'permanent',
        'credential', 'password', 'secret', 'token', 'api key',
        'discard', 'revert', 'rollback', 'roll back', 'abandon', 'throw away',
        'merg', 'squash', 'rebas', 'force push', 'force-push', 'reset --hard', 'hard reset',
        'drop'
    )
    foreach ($stem in $stems) {
        # Report the word the CALLER wrote, not the stem that matched it: the
        # message is read by whoever has to rephrase the question, and 'merg'
        # tells them less than 'merge' about what this refused.
        $match = [regex]::Match($text, '\b' + [regex]::Escape($stem) + '\w*',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return "a spoken answer is not the captain's explicit word for '$($match.Value)'"
        }
    }
    return ''
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
        if ($null -ne $synth) { Clear-FmSpeechEngine -Engine $synth }
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
        if ($null -ne $synth) { Clear-FmSpeechEngine -Engine $synth }
    }
}

function Get-FmInstalledSpeechRecognizer {
    <#
        .SYNOPSIS
        The names of the installed speech recognizers, or nothing at all.

        .DESCRIPTION
        Engine seam, and the one fm-ask asks FIRST. An empty result means "could
        not ask" as well as "none installed", and the caller treats both the same
        way: no answer, no microphone opened, and a reason saying so.

        Asking this before listening is what makes "this machine cannot hear"
        cost nothing rather than cost the caller a full listening window against
        an engine that was never going to answer.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        # Description, not Name: Name is the engine id (MS-2057-80-DESK), and
        # this is the list a person reads when asked what this machine can hear.
        return [string[]]@([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
                ForEach-Object { $_.Description })
    } catch {
        return [string[]]@()
    }
}

function Invoke-FmSpeechListenRequest {
    <#
        .SYNOPSIS
        Listen once for one of a closed set of options. Engine seam; never throws.

        .DESCRIPTION
        A CLOSED GRAMMAR, NOT DICTATION. The options become a Choices set, so the
        recognizer is deciding between known words rather than transcribing an
        arbitrary sentence. That is a different and far more reliable problem, and
        it is the only reason a spoken answer is worth acting on at all.

        RecognizeAsync with a bounded wait, for the same reason Invoke-FmSpeechRequest
        uses SpeakAsync: the synchronous form hands the deadline to the engine, and
        an engine listening to a device that will never answer never returns. The
        async form gives both a deadline and a cancel, so silence costs the caller
        TimeoutSeconds and never the turn.

        BOTH OUTCOMES ARE COLLECTED, accepted and rejected. A rejection carries
        text and a confidence too, and discarding it would turn "the engine heard
        something it was not sure of" into "the captain said nothing" - two
        different facts a caller may want to act on differently.

        The engine is built from an explicitly named installed recognizer rather
        than the default constructor, which picks by the current input language
        and throws when nothing installed matches it. The grammar is built in that
        recognizer's own culture for the same reason.

        Returns Heard, Confidence and Reason (heard, silence, unavailable).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Option,
        [int]$TimeoutSeconds = 15
    )

    $engine = $null
    $sources = [System.Collections.Generic.List[string]]::new()
    $silent = [pscustomobject]@{ Heard = ''; Confidence = 0.0; Reason = 'silence' }
    try {
        Add-Type -AssemblyName System.Speech -ErrorAction Stop
        # Select-Object, never [0]. Under Set-StrictMode -Version Latest indexing
        # an EMPTY array throws "Index was outside the bounds of the array"
        # rather than answering $null, so the [0] form turns both "no recognizer
        # installed" and "nobody said anything" into the catch below - which
        # reports a machine that cannot hear when the truth was silence. Only a
        # real run finds this: every mocked test replaces this whole function.
        $recognizer = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
            Select-Object -First 1
        if ($null -eq $recognizer) {
            return [pscustomobject]@{ Heard = ''; Confidence = 0.0; Reason = 'unavailable' }
        }
        $engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine -ArgumentList $recognizer
        # Throws on a machine with no microphone, which is the path a supervision
        # caller most needs to survive; the catch below turns it into a verdict.
        $engine.SetInputToDefaultAudioDevice()

        $choices = New-Object System.Speech.Recognition.Choices
        $choices.Add([string[]]$Option)
        $builder = New-Object System.Speech.Recognition.GrammarBuilder
        $builder.Culture = $recognizer.Culture
        $builder.Append($choices)
        $engine.LoadGrammar((New-Object System.Speech.Recognition.Grammar -ArgumentList $builder))

        # One identifier per call: two listening callers in one process must not
        # read each other's events.
        $token = "FmVoiceAsk-$([guid]::NewGuid().ToString('n'))"
        foreach ($name in @('SpeechRecognized', 'SpeechRecognitionRejected')) {
            $source = "$token-$name"
            Register-ObjectEvent -InputObject $engine -EventName $name -SourceIdentifier $source | Out-Null
            $sources.Add($source)
        }

        $engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Single)
        $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))
        $received = $null
        while ($null -eq $received -and [datetime]::UtcNow -lt $deadline) {
            $received = Get-Event | Where-Object { $sources.Contains($_.SourceIdentifier) } |
                Select-Object -First 1
            if ($null -eq $received) { Start-Sleep -Milliseconds 50 }
        }
        if ($null -eq $received) { return $silent }

        $recognition = $received.SourceEventArgs.Result
        if ($null -eq $recognition) { return $silent }
        return [pscustomobject]@{
            Heard      = [string]$recognition.Text
            Confidence = [double]$recognition.Confidence
            Reason     = 'heard'
        }
    } catch {
        return [pscustomobject]@{ Heard = ''; Confidence = 0.0; Reason = 'unavailable' }
    } finally {
        if ($null -ne $engine) {
            try {
                $engine.RecognizeAsyncCancel()
            } catch {
                Write-Verbose "fm-ask: the engine did not accept a cancel: $($_.Exception.Message)"
            }
        }
        foreach ($source in $sources) {
            try {
                Unregister-Event -SourceIdentifier $source -ErrorAction Stop
                @(Get-Event | Where-Object { $_.SourceIdentifier -eq $source }) | Remove-Event
            } catch {
                Write-Verbose "fm-ask: releasing the event subscription failed: $($_.Exception.Message)"
            }
        }
        if ($null -ne $engine) { Clear-FmSpeechEngine -Engine $engine }
    }
}

function Clear-FmSpeechEngine {
    <#
        .SYNOPSIS
        Release a synthesizer or a recognizer, whatever state it is in.

        .DESCRIPTION
        Disposing an engine that is mid-utterance, or still listening, or whose
        device has gone away, can raise - in a finally block, where a raised error
        would replace the verdict the caller is waiting for with an exception. One
        owner for that, so no seam has to repeat it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)]$Engine)

    try {
        $Engine.Dispose()
    } catch {
        Write-Verbose "voice: releasing the speech engine failed: $($_.Exception.Message)"
    }
}
