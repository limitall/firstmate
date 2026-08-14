#requires -Version 7.0
# Pester tests for the voice channel (fm-say).
#
# NOTHING HERE MAKES A SOUND, and nothing here needs an audio device. The two
# functions that touch System.Speech are mocked in every test that would reach
# them, so this suite passes identically on a developer's machine, on a build
# host with no speakers, and on Linux. The one place the real engine code runs
# is the "no speech engine" Describe, which mocks Add-Type into failure to prove
# the seam answers instead of throwing - the specific path a supervision caller
# depends on.
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

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Private' 'FmPaths.ps1')
    . (Join-Path $script:ModuleRoot 'Private' 'FmVoice.ps1')
    . (Join-Path $script:ModuleRoot 'Public' 'Invoke-FmSay.ps1')

    # The five voices actually installed on the captain's machine, measured -
    # see docs/windows-e2e-evidence.md section 25. Two of them share a prefix
    # with a third, which is why the matcher is exact rather than clever.
    $script:InstalledVoices = @(
        'Microsoft Hazel Desktop', 'Microsoft Zira Desktop',
        'Microsoft George', 'Microsoft Hazel', 'Microsoft Susan')

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
        Should -Invoke Invoke-FmSpeechRequest -Times 1 -Exactly -ParameterFilter { $Text -eq 'hello captain' }
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
        $bounded = Get-FmVoiceSpeechText -Message 'the payments fix is ready for your review'
        $bounded.Truncated | Should -BeFalse
        $bounded.Text | Should -Be 'the payments fix is ready for your review'
    }

    It 'collapses newlines and runs of whitespace, which are unspeakable anyway' {
        (Get-FmVoiceSpeechText -Message "two   lines`nof news").Text | Should -Be 'two lines of news'
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
        $script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script:SayScript = Join-Path $script:RepoRoot 'bin' 'fm-say.ps1'

        function Invoke-Say {
            <#
                .SYNOPSIS
                Run the entry point as a real child process against a given home.
            #>
            param([string[]]$CliArgs = @(), [string]$FmHome = '')
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:Pwsh
            foreach ($a in (@('-NoProfile', '-File', $script:SayScript) + $CliArgs)) { $psi.ArgumentList.Add($a) }
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
