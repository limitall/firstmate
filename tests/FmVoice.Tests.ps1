#requires -Version 7.0
# Pester tests for the voice channel: the spoken alert (fm-say) and the spoken
# question (fm-ask).
#
# NOTHING HERE MAKES A SOUND, NOTHING HERE OPENS A MICROPHONE, and nothing here
# needs an audio device of either kind. The four functions that touch
# System.Speech are mocked in every test that would reach them, so this suite
# passes identically on a developer's machine, on a build host with no speakers,
# on a machine with no microphone, and on Linux. The one place the real engine
# code runs is the "no speech engine" Describe, which mocks Add-Type into failure
# to prove both seams answer instead of throwing - the specific path a
# supervision caller depends on.
#
# The entry-point Describe runs real child processes, which cannot be mocked at
# all - so every one of them is given a home whose voice is off or absent. That
# is what keeps the CLI contract under test and the room quiet at the same time,
# and it is why a config fixture there says `off` rather than being left out.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # CLEARED FOR THIS WHOLE FILE, and restored at the end. FM_VOICE_OFF
    # silences the voice channel for a process tree, and CONTRIBUTING.md tells
    # contributors to set it in their own shell while working on the bridge - so
    # without this, every test here that expects 'off', 'empty' or a spoken
    # message fails on their machine and passes on a clean one. The one Describe
    # that is ABOUT the variable sets it per test and puts it back.
    $script:VoiceOffAtStart = $env:FM_VOICE_OFF
    Remove-Item Env:FM_VOICE_OFF -ErrorAction SilentlyContinue

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmPaths.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmVoice.ps1')
    # Get-FmVoiceSpeechText prepares before it bounds, and the preparation lives
    # here. Without this file the bound would run over text nothing had cleaned.
    . (Join-Path $script:ModuleRoot 'Public' 'ConvertTo-FmSpokenText.ps1')
    . (Join-Path $script:ModuleRoot 'Public' 'Invoke-FmSay.ps1')
    . (Join-Path $script:ModuleRoot 'Public' 'Invoke-FmAsk.ps1')

    # The five voices actually installed on the captain's machine, measured -
    # see docs/windows-e2e-evidence.md section 25. Two of them share a prefix
    # with a third, which is why the matcher is exact rather than clever.
    $script:InstalledVoices = @(
        'Microsoft Hazel Desktop', 'Microsoft Zira Desktop',
        'Microsoft George', 'Microsoft Hazel', 'Microsoft Susan')

    # The one recognizer actually installed on the captain's machine, measured -
    # see docs/windows-e2e-evidence.md section 26.
    $script:InstalledRecognizers = @('Microsoft Speech Recognizer 8.0 for Windows (English - UK)')

    function New-VoiceHome {
        <#
            .SYNOPSIS
            A disposable home, optionally carrying a config/voice file.
        #>
        param([string[]]$ConfigLine)
        $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $home_ 'config') -Force | Out-Null
        if ($PSBoundParameters.ContainsKey('ConfigLine')) {
            [System.IO.File]::WriteAllText(
                (Join-Path $home_ 'config' 'voice'), ((@($ConfigLine) -join "`n") + "`n"))
        }
        return $home_
    }

    function Invoke-VoiceScript {
        <#
            .SYNOPSIS
            Run a voice entry point as a real child process against a given home.

            .DESCRIPTION
            One owner for both entry points: a child process cannot be mocked, so
            every test that uses this must give it a home whose voice is off or
            absent. That is what keeps the CLI contract under test and the room
            quiet - and the microphone shut - at the same time.
        #>
        param([Parameter(Mandatory)][string]$Script, [string[]]$CliArgs = @(), [string]$FmHome = '')
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:Pwsh
        foreach ($a in (@('-NoProfile', '-File', $Script) + $CliArgs)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE')) {
            $psi.Environment.Remove($name) | Out-Null
        }
        if ($FmHome) {
            $psi.Environment['FM_HOME'] = $FmHome
            $psi.Environment['FM_ROOT_OVERRIDE'] = $FmHome
        }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
    }

    $script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:SayScript = Join-Path $script:RepoRoot 'bin' 'fm-say.ps1'
    $script:AskScript = Join-Path $script:RepoRoot 'bin' 'fm-ask.ps1'
}

# Restores what the file's own BeforeAll cleared, because Pester containers share
# one process and a variable left changed here decides another file's behaviour.
AfterAll {
    if ($null -eq $script:VoiceOffAtStart) { Remove-Item Env:FM_VOICE_OFF -ErrorAction SilentlyContinue }
    else { $env:FM_VOICE_OFF = $script:VoiceOffAtStart }
}

Describe 'the voice is off until the captain turns it on' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }

    It 'says nothing, and fails nothing, when there is no config/voice' {
        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome)
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'off'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
    }

    It 'speaks once config/voice exists, even when that file is empty' {
        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Spoken | Should -BeTrue
        $said.Reason | Should -Be 'spoken'
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $Text -eq 'hello captain.' }
    }

    It 'stays silent for a config/voice that says off, keeping the voice choice' {
        $said = Invoke-FmSay -Message 'hello captain' `
            -FirstmateHome (New-VoiceHome -ConfigLine @('off', 'voice=Susan'))
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'off'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
    }

    It 'says nothing for a message with no words in it' {
        $said = Invoke-FmSay -Message "   `t " -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'empty'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
    }
}

# WHAT THIS GUARDS. The browser bridge hosts a real firstmate session, which
# reads the same AGENTS.md and therefore knows fm-say.ps1 exists. On a home whose
# captain has created config/voice, it would speak out of a process the page
# cannot reach. The session is now started with FM_VOICE_OFF set, and this is the
# gate that variable opens. It is NOT what silenced the screen that spoke at the
# captain - that was the page's own speechSynthesis, and this home had no
# config/voice at all; docs/windows-e2e-evidence.md section 34.1 has the check.
Describe 'a process whose parent owns the speaking' {
    BeforeAll {
        # Saved and restored, because Pester containers share one process and a
        # variable left set here would silence every suite that runs after.
        $script:VoiceOffBefore = $env:FM_VOICE_OFF
    }
    AfterAll {
        if ($null -eq $script:VoiceOffBefore) { Remove-Item Env:FM_VOICE_OFF -ErrorAction SilentlyContinue }
        else { $env:FM_VOICE_OFF = $script:VoiceOffBefore }
    }
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }
    AfterEach { Remove-Item Env:FM_VOICE_OFF -ErrorAction SilentlyContinue }

    It 'never reaches an engine, whatever config/voice says' {
        $env:FM_VOICE_OFF = '1'
        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'suppressed'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
    }

    It 'still speaks when the variable says the opposite' {
        foreach ($value in '0', 'false', 'off', 'no', '') {
            $env:FM_VOICE_OFF = $value
            (Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())).Spoken |
                Should -BeTrue -Because "'$value' is not a request for silence"
        }
    }

    It 'speaks again once the variable is gone' {
        $env:FM_VOICE_OFF = '1'
        $null = Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())
        Remove-Item Env:FM_VOICE_OFF
        (Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())).Reason |
            Should -Be 'spoken'
    }
}

# The captain named `##` and `**` being read out. Nothing reaches an engine
# through this path without being prepared first; ConvertTo-FmSpokenText owns
# what preparing means, and tests/FmBridge.Tests.ps1 owns the rules themselves.
Describe 'what fm-say hands the engine' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }

    It 'strips the markup before the engine ever sees it' {
        $null = Invoke-FmSay -Message '**Done** - see `C:\logs\run-1.log`' `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter {
            $Text -eq 'Done, see run 1 dot log.'
        }
    }

    # The bound is measured on the characters that are actually SPOKEN. The
    # other order would cut a reply for being long and then remove the markup
    # that made it long.
    It 'measures its length after the markup has gone, not before' {
        $padding = '**' * 60
        $message = "The payments fix is ready for your review. $padding"
        $bounded = Get-FmVoiceSpeechText -Message $message
        $bounded.Truncated | Should -BeFalse
        $bounded.Text | Should -Be 'The payments fix is ready for your review.'
    }
}

Describe 'the configured voice and rate' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }

    It 'asks the engine for the configured voice by its installed name' {
        $said = Invoke-FmSay -Message 'ready for review' `
            -FirstmateHome (New-VoiceHome -ConfigLine @('voice=Microsoft Zira Desktop'))
        $said.Voice | Should -Be 'Microsoft Zira Desktop'
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly `
            -ParameterFilter { $VoiceName -eq 'Microsoft Zira Desktop' }
    }

    It 'matches an installed voice whatever case and spacing the captain typed' {
        $said = Invoke-FmSay -Message 'ready for review' `
            -FirstmateHome (New-VoiceHome -ConfigLine @('voice=  microsoft susan  '))
        $said.Voice | Should -Be 'Microsoft Susan'
    }

    It 'falls back to the default voice for a name nothing installed matches, and still speaks' {
        $said = Invoke-FmSay -Message 'ready for review' `
            -FirstmateHome (New-VoiceHome -ConfigLine @('voice=Nobody At All'))
        $said.Spoken | Should -BeTrue
        $said.Voice | Should -Be ''
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $VoiceName -eq '' }
    }

    It 'does not guess between two installed voices that share a prefix' {
        # 'Microsoft Hazel' and 'Microsoft Hazel Desktop' are both installed on
        # the captain's machine, and they do not sound alike. A prefix match
        # would pick between them by list order.
        (Resolve-FmVoiceName -Requested 'Microsoft Hazel' -Installed $script:InstalledVoices) |
            Should -Be 'Microsoft Hazel'
        (Resolve-FmVoiceName -Requested 'Microsoft' -Installed $script:InstalledVoices) | Should -Be ''
        (Resolve-FmVoiceName -Requested 'Hazel' -Installed $script:InstalledVoices) | Should -Be ''
    }

    It 'does not construct a second engine when no voice was asked for' {
        $null = Invoke-FmSay -Message 'ready for review' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=1'))
        Should -Invoke Get-FmInstalledSpeechVoice -Times 0 -Exactly
    }

    It 'passes the configured rate through' {
        $said = Invoke-FmSay -Message 'ready for review' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=-3'))
        $said.Rate | Should -Be -3
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $Rate -eq -3 }
    }

    It 'clamps a rate outside the engine range instead of refusing to speak' {
        (Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=99'))).Rate | Should -Be 10
        (Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=-99'))).Rate | Should -Be -10
    }

    It 'treats an unreadable rate as the default rather than an error' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=quickly'))
        $said.Spoken | Should -BeTrue
        $said.Rate | Should -Be 0
    }

    It 'reads through comments and blank lines' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @(
                '# the captain prefers Susan', '', 'voice=Microsoft Susan'))
        $said.Voice | Should -Be 'Microsoft Susan'
        $said.Spoken | Should -BeTrue
        $said.Warning | Should -Be ''
    }
}

Describe 'a config/voice the captain got wrong' {
    # config/autolaunch refuses an unusable file so a typo cannot silently
    # disable a feature the captain believes is on. Here refusing WOULD be that
    # silence, so the message is spoken and the problem is reported instead.
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }

    It 'speaks, and reports the key it did not recognise' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('volume=11'))
        $said.Spoken | Should -BeTrue
        $said.Warning | Should -Match "unknown key 'volume'"
    }

    It 'treats a mis-cased key as the typo it is, rather than as no choice' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('Voice=Microsoft Susan'))
        $said.Spoken | Should -BeTrue
        $said.Voice | Should -Be ''
        $said.Warning | Should -Match "unknown key 'Voice'"
    }

    It 'speaks, and reports a rate it had to clamp or could not read' {
        (Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=99'))).Warning |
            Should -Match 'above the engine'
        (Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('rate=quickly'))).Warning |
            Should -Match 'not a number'
    }

    It 'speaks, and reports a voice that is not installed' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('voice=Nobody At All'))
        $said.Spoken | Should -BeTrue
        $said.Warning | Should -Match "voice 'Nobody At All' is not installed"
    }

    It 'reports a line that is neither key=value nor off' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('on'))
        $said.Spoken | Should -BeTrue
        $said.Warning | Should -Match "line 1: expected key=value or a lone 'off'"
    }

    It 'reports a key set twice, and keeps the last one' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @(
                'voice=Microsoft George', 'voice=Microsoft Susan'))
        $said.Voice | Should -Be 'Microsoft Susan'
        $said.Warning | Should -Match "'voice' is set twice"
    }

    It 'reports every problem in the file, not just the first' {
        $said = Invoke-FmSay -Message 'x' -FirstmateHome (New-VoiceHome -ConfigLine @('volume=11', 'rate=99'))
        $said.Warning | Should -Match 'unknown key'
        $said.Warning | Should -Match 'above the engine'
    }
}

Describe 'the utterance bound' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { @() }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
    }

    It 'speaks a short message exactly as given' {
        # The full stop is added by the preparation this now delegates to: a
        # sentence handed to an engine without a terminator is read with the
        # flat, unfinished cadence of a line that was cut off.
        $bounded = Get-FmVoiceSpeechText -Message 'the payments fix is ready for your review'
        $bounded.Truncated | Should -BeFalse
        $bounded.Text | Should -Be 'the payments fix is ready for your review.'
    }

    It 'collapses newlines and runs of whitespace, which are unspeakable anyway' {
        (Get-FmVoiceSpeechText -Message "two   lines`nof news").Text | Should -Be 'two lines of news.'
    }

    It 'truncates an over-long message audibly, at a word boundary' {
        $long = (1..80 | ForEach-Object { 'sentence' }) -join ' '
        $bounded = Get-FmVoiceSpeechText -Message $long
        $bounded.Truncated | Should -BeTrue
        $bounded.Text | Should -BeLike '*, message truncated'
        $bounded.Text | Should -Not -BeLike '*sentenc, message truncated'
        $bounded.Text.Length | Should -BeLessOrEqual ((Get-FmVoiceMaxLength) + 20)
    }

    It 'still bounds a message with no word boundary to cut at' {
        $bounded = Get-FmVoiceSpeechText -Message ('x' * 500)
        $bounded.Truncated | Should -BeTrue
        $bounded.Text.Length | Should -BeLessOrEqual ((Get-FmVoiceMaxLength) + 20)
    }

    It 'reads the engine the bounded text, not the whole message' {
        $long = (1..80 | ForEach-Object { 'sentence' }) -join ' '
        $said = Invoke-FmSay -Message $long -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Truncated | Should -BeTrue
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter {
            $Text.Length -le ((Get-FmVoiceMaxLength) + 20) -and $Text.EndsWith(', message truncated')
        }
    }
}

Describe 'a missing or broken speech engine' {
    It 'answers instead of throwing when the speech assembly is not there' {
        # The real seam code runs here: only Add-Type is replaced, so this is
        # what a machine with no System.Speech actually does.
        Mock Add-Type { throw 'Cannot find assembly System.Speech.' }

        $verdict = Invoke-FmSpeechRequest -Text 'hello captain'
        $verdict.Spoken | Should -BeFalse
        $verdict.Reason | Should -Be 'unavailable'
        Get-FmInstalledSpeechVoice | Should -HaveCount 0
    }

    It 'reports a failure to the caller without failing the caller' {
        Mock Get-FmInstalledSpeechVoice { @() }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $false; Reason = 'unavailable' } }

        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'unavailable'
    }

    It 'does not throw even when the engine seam itself throws' {
        # The seams are written not to throw; this proves the caller survives
        # one that does anyway - a device driver raising from a constructor, say.
        Mock Get-FmInstalledSpeechVoice { throw 'the audio endpoint was removed' }
        Mock Invoke-FmSpeechRequest { throw 'the audio endpoint was removed' }

        $home_ = New-VoiceHome -ConfigLine @()
        { Invoke-FmSay -Message 'hello captain' -FirstmateHome $home_ } | Should -Not -Throw

        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome $home_
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'unavailable'
    }

    It 'reports an utterance that outran its bounded wait' {
        Mock Get-FmInstalledSpeechVoice { @() }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $false; Reason = 'timeout' } }

        $said = Invoke-FmSay -Message 'hello captain' -TimeoutSeconds 1 `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'timeout'
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 1 }
    }

    It 'is off, not broken, when the home cannot be read at all' {
        $said = Invoke-FmSay -Message 'hello captain' -FirstmateHome (Join-Path $TestDrive 'no-such-home')
        $said.Spoken | Should -BeFalse
        $said.Reason | Should -Be 'off'
    }
}

Describe 'bin/fm-say.ps1' {
    BeforeAll {
        function Invoke-Say {
            param([string[]]$CliArgs = @(), [string]$FmHome = '')
            return Invoke-VoiceScript -Script $script:SayScript -CliArgs $CliArgs -FmHome $FmHome
        }
    }

    It 'exits 2 with a usage line when given nothing to say' {
        $run = Invoke-Say -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 2
        $run.StdErr | Should -Match 'usage: fm-say\.ps1'
    }

    It 'is silent and non-fatal with the voice off, and says which' {
        # No config/voice in this home, so the child never reaches the engine.
        $run = Invoke-Say -CliArgs @('hello', 'captain') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'not spoken'
        $run.StdErr | Should -Match 'config/voice'
    }

    # THE GATE, THROUGH A REAL CHILD PROCESS, which is the shape that actually
    # failed: the browser bridge starts one, and it spoke to a closed browser.
    # The home's voice is left OFF here on purpose - a suite that switches the
    # voice ON to prove a guard is a suite that makes a noise on the captain's
    # machine every time the guard regresses. What is asserted is the REASON,
    # which is 'suppressed' only if the gate ran before the config was read.
    It 'says nothing when its parent owns the speaking, and says which' {
        $before = $env:FM_VOICE_OFF
        try {
            $env:FM_VOICE_OFF = '1'
            $run = Invoke-Say -CliArgs @('hello', 'captain') -FmHome (New-VoiceHome)
            $run.ExitCode | Should -Be 0
            $run.StdErr | Should -Match 'not spoken'
            $run.StdErr | Should -Match 'browser screen owns speaking'
        } finally {
            if ($null -eq $before) { Remove-Item Env:FM_VOICE_OFF -ErrorAction SilentlyContinue }
            else { $env:FM_VOICE_OFF = $before }
        }
    }

    It 'prints what config/voice got wrong, and still exits 0' {
        # `off` keeps this child silent - the point here is that a typo is
        # reported even in the config that produced no sound.
        $run = Invoke-Say -CliArgs @('hello', 'captain') -FmHome (New-VoiceHome -ConfigLine @('off', 'volume=11'))
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match "config/voice: line 2: unknown key 'volume'"
        $run.StdErr | Should -Match 'not spoken'
    }

    It 'documents that the caller owns what gets spoken' {
        $run = Invoke-Say -CliArgs @('-h') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 0
        # Help output is wrapped to the console width, so compare it flattened.
        $help = ($run.StdOut -replace '\s+', ' ')
        $help | Should -Match 'section 9'
        $help | Should -Match 'config/voice'
    }
}

# ---------------------------------------------------------------------------
# fm-ask: the spoken question. Everything below mocks the recognizer seams, so
# no test here opens a microphone or needs one to exist.
# ---------------------------------------------------------------------------

Describe 'asking the captain a question out loud' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.87; Reason = 'heard' }
        }
    }

    It 'speaks the question and returns what it heard, with a confidence' {
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Answered | Should -BeTrue
        $heard.Answer | Should -Be 'yes'
        $heard.Heard | Should -Be 'yes'
        $heard.Confidence | Should -Be 0.87
        $heard.Reason | Should -Be 'answered'
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $Text -eq 'Ready to land?' }
    }

    It 'gives the recognizer the caller options as a closed set, not free dictation' {
        # The whole reason a spoken answer is worth acting on: picking between
        # known words, not transcribing a sentence.
        $null = Invoke-FmAsk -Question 'Which one first?' -Option payments, checkout, neither `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        Should -Invoke Invoke-FmSpeechListenRequest -Times 1 -Exactly -ParameterFilter {
            (@($Option) -join ',') -eq 'payments,checkout,neither'
        }
    }

    It 'returns the option as the caller spelled it, whatever case came back' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'YES'; Confidence = 0.91; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option Yes, No `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Answered | Should -BeTrue
        $heard.Answer | Should -Be 'Yes'
        $heard.Heard | Should -Be 'YES'
    }

    It 'collapses two spellings of one option rather than refusing the question' {
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option 'yes', ' YES ', 'no' `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        (@($heard.Option) -join ',') | Should -Be 'yes,no'
        $heard.Answered | Should -BeTrue
    }

    It 'never hands back an answer that was not on the list it was given' {
        # A closed grammar should not produce one. The recognizer is another
        # component's reading of that grammar, so the caller is protected anyway.
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'maybe'; Confidence = 0.99; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Answered | Should -BeFalse
        $heard.Answer | Should -Be ''
        $heard.Reason | Should -Be 'unsure'
        $heard.Heard | Should -Be 'maybe'
    }
}

Describe 'refusing rather than guessing' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
    }

    It 'returns no answer at all below the confidence floor, and says what it heard' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'no'; Confidence = 0.41; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Answered | Should -BeFalse
        $heard.Answer | Should -Be ''
        $heard.Reason | Should -Be 'unsure'
        # The uncertainty is the point: a caller must be able to tell "the
        # captain said no" from "something sounded a bit like no".
        $heard.Heard | Should -Be 'no'
        $heard.Confidence | Should -Be 0.41
        $heard.MinimumConfidence | Should -Be (Get-FmVoiceMinimumConfidence)
    }

    It 'answers at the floor exactly, and refuses just below it' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.75; Reason = 'heard' }
        }
        $home_ = New-VoiceHome -ConfigLine @()
        (Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_).Answered |
            Should -BeTrue

        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.7499; Reason = 'heard' }
        }
        (Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_).Answered |
            Should -BeFalse
    }

    It 'takes the floor from config/voice' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.6; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @('confidence=0.5'))
        $heard.MinimumConfidence | Should -Be 0.5
        $heard.Answered | Should -BeTrue
    }

    It 'lets one call override the configured floor' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.8; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -MinimumConfidence 0.95 `
            -FirstmateHome (New-VoiceHome -ConfigLine @('confidence=0.5'))
        $heard.MinimumConfidence | Should -Be 0.95
        $heard.Answered | Should -BeFalse
        $heard.Reason | Should -Be 'unsure'
    }

    It 'clamps and reports a configured floor outside 0 to 1, rather than refusing to ask' {
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.99; Reason = 'heard' }
        }
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @('confidence=7'))
        $heard.MinimumConfidence | Should -Be 1
        $heard.Warning | Should -Match 'above 1'
    }

    It 'reads a configured floor the same way whatever the decimal separator is' {
        # A machine whose culture writes 0,75 must still read 0.75 out of the
        # file as three quarters rather than as seventy five.
        $culture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            (ConvertTo-FmVoiceConfidence -Value '0.5').Confidence | Should -Be 0.5
        } finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
        }
    }

    It 'treats an unreadable floor as the default rather than an error' {
        $floor = ConvertTo-FmVoiceConfidence -Value 'quite sure'
        $floor.Confidence | Should -Be (Get-FmVoiceMinimumConfidence)
        $floor.Problem | Should -Match 'not a number'
    }

    It 'refuses a call whose own floor is outside 0 to 1, without asking anything' {
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -MinimumConfidence 4 `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'invalid'
        $heard.Warning | Should -Match 'outside 0 to 1'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
    }
}

Describe 'a question that is not a question' {
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.9; Reason = 'heard' }
        }
    }

    It 'refuses a single option, because there would be nothing to choose between' {
        # Every sound the recognizer decided was speech would become that option,
        # so the caller would get its own expectation back as the captain's word.
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'invalid'
        $heard.Answered | Should -BeFalse
        $heard.Warning | Should -Match 'at least two distinct options'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }

    It 'refuses two options that are the same word said twice' {
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option 'yes', ' Yes ' `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'invalid'
    }

    It 'refuses no options at all' {
        (Invoke-FmAsk -Question 'Ready to land?' -Option @() `
                -FirstmateHome (New-VoiceHome -ConfigLine @())).Reason | Should -Be 'invalid'
        (Invoke-FmAsk -Question 'Ready to land?' -Option $null `
                -FirstmateHome (New-VoiceHome -ConfigLine @())).Reason | Should -Be 'invalid'
    }

    It 'listens for nothing when there was no question to ask' {
        $heard = Invoke-FmAsk -Question "  `t " -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'invalid'
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }
}

Describe 'the authority boundary on a spoken answer' {
    # AGENTS.md's captain-instruction precedence rule requires the captain to
    # state a destructive, irreversible, security-sensitive, discard or merge
    # action explicitly. A recognizer that is right most of the time does not
    # clear that bar, so fm-ask refuses to collect one at all.
    BeforeEach {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.99; Reason = 'heard' }
        }
    }

    It 'refuses a merge confirmation without speaking it or listening for it' {
        $heard = Invoke-FmAsk -Question 'Shall I merge this?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'refused'
        $heard.Answered | Should -BeFalse
        $heard.Answer | Should -Be ''
        $heard.Warning | Should -Match "not the captain's explicit word for 'merge'"
        # Refused BEFORE anything is spoken: asking it and then discounting the
        # answer would still have put the words in the room.
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }

    It 'refuses every category the precedence rule names' {
        $home_ = New-VoiceHome -ConfigLine @()
        foreach ($question in @(
                'Shall I merge this?', 'Shall I delete the branch?', 'Shall I discard those changes?',
                'Shall I overwrite the local copy?', 'Shall I revert it?', 'Shall I drop the table?',
                'Is this change irreversible?', 'Shall I use the stored password?',
                'Shall I force push?', 'Shall I remove the worker?')) {
            (Invoke-FmAsk -Question $question -Option yes, no -FirstmateHome $home_).Reason |
                Should -Be 'refused' -Because "'$question' collects an answer only the captain may give"
        }
    }

    It 'refuses when the destructive word is in an option rather than the question' {
        # "Shall I do it?" with an option of "delete" is the same question.
        $heard = Invoke-FmAsk -Question 'What next?' -Option 'delete it', 'leave it' `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'refused'
    }

    It 'still asks an ordinary readiness question' {
        # The boundary is about who authorises the action, not about work that
        # sounds risky. "Ready to land?" asks readiness; it does not merge.
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Reason | Should -Be 'answered'
    }

    It 'never reports sufficient authority, on any path, including a clean answer' {
        # A constant, so there is no wording and no configuration that makes a
        # spoken answer the captain's explicit word. The word-list refusal above
        # catches the accident; this is what holds when a question is phrased
        # around it.
        $home_ = New-VoiceHome -ConfigLine @()
        $paths = @(
            (Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_),
            (Invoke-FmAsk -Question 'Shall I merge this?' -Option yes, no -FirstmateHome $home_),
            (Invoke-FmAsk -Question 'Ready to land?' -Option yes -FirstmateHome $home_),
            (Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome (New-VoiceHome))
        )
        foreach ($heard in $paths) { $heard.SufficientAuthority | Should -BeFalse }
        $paths[0].Answered | Should -BeTrue -Because 'the clean-answer path must be one of the four'
    }
}

Describe 'a machine that cannot hear' {
    It 'asks nothing and listens to nothing while the voice is off' {
        # The microphone is never opened without the captain turning the voice
        # on. That is a stronger rule than fm-say's, and it is the same switch.
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.99; Reason = 'heard' }
        }

        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome (New-VoiceHome)
        $heard.Answered | Should -BeFalse
        $heard.Reason | Should -Be 'off'
        Should -Invoke Invoke-FmSpeechRequest -Times 0 -Exactly
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }

    It 'returns no answer, and does not throw, when no recognizer is installed' {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { [string[]]@() }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.99; Reason = 'heard' }
        }

        $home_ = New-VoiceHome -ConfigLine @()
        { Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_ } | Should -Not -Throw
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_
        $heard.Answered | Should -BeFalse
        $heard.Reason | Should -Be 'unavailable'
        # No listening window against an engine that was never going to answer.
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }

    It 'returns no answer, and does not throw, when there is no microphone' {
        # SetInputToDefaultAudioDevice raises on a machine with no capture
        # device; the seam turns that into a verdict, and this is the caller
        # surviving it.
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = ''; Confidence = 0.0; Reason = 'unavailable' }
        }

        $home_ = New-VoiceHome -ConfigLine @()
        { Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_ } | Should -Not -Throw
        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_
        $heard.Answered | Should -BeFalse
        $heard.Reason | Should -Be 'unavailable'
    }

    It 'returns no answer within the bounded wait when nobody says anything' {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = ''; Confidence = 0.0; Reason = 'silence' }
        }

        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -ListenSeconds 3 `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Answered | Should -BeFalse
        $heard.Reason | Should -Be 'silence'
        $heard.Heard | Should -Be ''
        $heard.Confidence | Should -Be 0
        Should -Invoke Invoke-FmSpeechListenRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 3 }
    }

    It 'does not listen for the answer to a question that was never asked' {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $false; Reason = 'unavailable' } }
        Mock Get-FmInstalledSpeechRecognizer { $script:InstalledRecognizers }
        Mock Invoke-FmSpeechListenRequest {
            [pscustomobject]@{ Heard = 'yes'; Confidence = 0.99; Reason = 'heard' }
        }

        $heard = Invoke-FmAsk -Question 'Ready to land?' -Option yes, no `
            -FirstmateHome (New-VoiceHome -ConfigLine @())
        $heard.Spoken | Should -BeFalse
        $heard.Reason | Should -Be 'unspoken'
        Should -Invoke Invoke-FmSpeechListenRequest -Times 0 -Exactly
    }

    It 'does not throw even when the listening seam itself throws' {
        Mock Get-FmInstalledSpeechVoice { $script:InstalledVoices }
        Mock Invoke-FmSpeechRequest { [pscustomobject]@{ Spoken = $true; Reason = 'spoken' } }
        Mock Get-FmInstalledSpeechRecognizer { throw 'the capture endpoint was removed' }
        Mock Invoke-FmSpeechListenRequest { throw 'the capture endpoint was removed' }

        $home_ = New-VoiceHome -ConfigLine @()
        { Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_ } | Should -Not -Throw
        (Invoke-FmAsk -Question 'Ready to land?' -Option yes, no -FirstmateHome $home_).Reason |
            Should -Be 'unavailable'
    }

    It 'answers instead of throwing when the speech assembly is not there' {
        # The real seam code runs here: only Add-Type is replaced, so this is
        # what a machine with no System.Speech actually does. It is also the one
        # test in this file that reaches the recognizer seam's own body.
        Mock Add-Type { throw 'Cannot find assembly System.Speech.' }

        $verdict = Invoke-FmSpeechListenRequest -Option @('yes', 'no') -TimeoutSeconds 1
        $verdict.Reason | Should -Be 'unavailable'
        $verdict.Heard | Should -Be ''
        $verdict.Confidence | Should -Be 0
        Get-FmInstalledSpeechRecognizer | Should -HaveCount 0
    }
}

Describe 'bin/fm-ask.ps1' {
    BeforeAll {
        function Invoke-Ask {
            param([string[]]$CliArgs = @(), [string]$FmHome = '')
            return Invoke-VoiceScript -Script $script:AskScript -CliArgs $CliArgs -FmHome $FmHome
        }
    }

    It 'exits 2 with a usage line when given no question or no options' {
        (Invoke-Ask -CliArgs @('-Options', 'yes,no') -FmHome (New-VoiceHome)).ExitCode | Should -Be 2
        $run = Invoke-Ask -CliArgs @('Ready', 'to', 'land?') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 2
        $run.StdErr | Should -Match 'usage: fm-ask\.ps1'
    }

    It 'is silent, deaf and non-fatal with the voice off, and says which' {
        # No config/voice in this home, so the child never reaches either engine.
        $run = Invoke-Ask -CliArgs @('Ready to land?', '-Options', 'yes,no') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'no answer'
        $run.StdErr | Should -Match 'config/voice'
    }

    It 'prints what it heard and how sure it was on every path' {
        $run = Invoke-Ask -CliArgs @('Ready to land?', '-Options', 'yes,no') -FmHome (New-VoiceHome)
        $run.StdOut | Should -Match '(?m)^answer=\r?$'
        $run.StdOut | Should -Match '(?m)^heard=\r?$'
        $run.StdOut | Should -Match '(?m)^confidence=0\.00\r?$'
        $run.StdOut | Should -Match '(?m)^reason=off\r?$'
    }

    It 'refuses a merge confirmation with a non-zero exit, even with the voice off' {
        # The refusal is not a property of the room: it holds before the config
        # is read, so a caller cannot discover it only on a machine that talks.
        $run = Invoke-Ask -CliArgs @('Shall I merge this?', '-Options', 'yes,no') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 1
        $run.StdOut | Should -Match '(?m)^reason=refused\r?$'
        $run.StdErr | Should -Match "not the captain's explicit word"
    }

    It 'reads -Options yes,no as two options, not as one word called yes,no' {
        # Every test here runs the script through `pwsh -File`, which is how a
        # herdr pane, a Claude hook, or any non-PowerShell caller reaches it -
        # and there `yes,no` arrives as ONE string. Unsplit it is a one-option
        # grammar, which Invoke-FmAsk refuses, so the documented invocation
        # would have failed for everyone who was not already in PowerShell.
        $run = Invoke-Ask -CliArgs @('Ready to land?', '-Options', 'yes, no') -FmHome (New-VoiceHome)
        $run.StdOut | Should -Match '(?m)^reason=off\r?$'
        $run.ExitCode | Should -Be 0
    }

    It 'exits 1 for an option set with nothing to choose between' {
        $run = Invoke-Ask -CliArgs @('Ready to land?', '-Options', 'yes') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 1
        $run.StdOut | Should -Match '(?m)^reason=invalid\r?$'
        $run.StdErr | Should -Match 'at least two distinct options'
    }

    It 'prints what config/voice got wrong, and still exits 0' {
        $run = Invoke-Ask -CliArgs @('Ready to land?', '-Options', 'yes,no') `
            -FmHome (New-VoiceHome -ConfigLine @('off', 'volume=11'))
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match "config/voice: line 2: unknown key 'volume'"
    }

    It 'documents the confidence floor, that it is configurable, and the authority boundary' {
        $run = Invoke-Ask -CliArgs @('-h') -FmHome (New-VoiceHome)
        $run.ExitCode | Should -Be 0
        # Help output is wrapped to the console width, so compare it flattened.
        $help = ($run.StdOut -replace '\s+', ' ')
        $help | Should -Match '0\.75'
        $help | Should -Match 'confidence='
        $help | Should -Match 'MinimumConfidence'
        $help | Should -Match "(?i)not the captain's explicit word"
        $help | Should -Match '(?i)answerable in chat'
        $help | Should -Match 'section 9'
    }
}
