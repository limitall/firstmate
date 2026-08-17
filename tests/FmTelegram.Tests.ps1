#requires -Version 7.0
# Pester tests for the private Telegram channel: the outbound message (fm-tell)
# and the inbound poller (fm-tg-poll).
#
# NOTHING HERE NEEDS A BOT, A TOKEN, OR A NETWORK, and nothing here sends a real
# message. Invoke-FmTelegramApi is the one function in the area that opens a
# socket, so every test that would reach it mocks it - the same discipline the
# voice channel applies to the four functions that touch the speech engine, and
# for the same reason: this suite must pass identically on a build host with no
# route to the internet and on a laptop that has one.
#
# The tokens written into fixtures below are literal nonsense. If one of them
# ever matches a real credential, that is the defect, not the test.
#
# THE ENTRY-POINT DESCRIBE RUNS REAL CHILD PROCESSES, which cannot be mocked at
# all. Every one of them is given either a home with no token, or a home whose
# API root points at a loopback port nothing listens on - so the request path
# runs for real, refuses for real, and never leaves this machine.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'The values an InModuleScope block takes are used inside a Mock body or a Should -Invoke -ParameterFilter, which the analyzer does not trace into. Removing one would break the assertion it feeds.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    . (Join-Path $PSScriptRoot 'FmModule.TestHelpers.ps1')
    Import-FmTestModule -TestRoot $PSScriptRoot

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:TellScript = Join-Path $script:RepoRoot 'bin' 'fm-tell.ps1'
    $script:PollScript = Join-Path $script:RepoRoot 'bin' 'fm-tg-poll.ps1'
    $script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

    # Two halves so a leak assertion can look for the secret half on its own: a
    # message that quoted only the part after the colon would still be a leak.
    $script:FakeTokenId = '9988776655'
    $script:FakeTokenSecret = 'AAF-NOT-A-REAL-TOKEN-DO-NOT-USE'
    $script:FakeToken = "$($script:FakeTokenId):$($script:FakeTokenSecret)"
    $script:CaptainId = 424242

    # A loopback port nothing listens on. A connect here is refused instantly and
    # goes nowhere, which is what lets an entry-point test exercise the real
    # request path with no network and no risk of touching Telegram.
    $script:DeadApi = 'http://127.0.0.1:9'

    # Every environment key this suite touches, saved so one file cannot decide
    # another file's behaviour - Pester containers share one process.
    $script:SavedEnv = @{}
    foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
            'FM_TELEGRAM_API_BASE')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }

    function New-TelegramHome {
        <#
            .SYNOPSIS
            A disposable home, optionally carrying the channel's config files.
        #>
        param(
            [switch]$WithToken,
            [switch]$WithAllow,
            [string[]]$AllowLine,
            [string[]]$AuthorityLine
        )
        $root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force
        if ($WithToken) {
            [System.IO.File]::WriteAllText((Join-Path $root 'config' 'telegram-token'),
                "$($script:FakeToken)`n")
        }
        if ($PSBoundParameters.ContainsKey('AllowLine')) {
            [System.IO.File]::WriteAllText((Join-Path $root 'config' 'telegram-allow'),
                ((@($AllowLine) -join "`n") + "`n"))
        } elseif ($WithAllow) {
            [System.IO.File]::WriteAllText((Join-Path $root 'config' 'telegram-allow'),
                "$($script:CaptainId)`n")
        }
        if ($PSBoundParameters.ContainsKey('AuthorityLine')) {
            [System.IO.File]::WriteAllText((Join-Path $root 'config' 'telegram-authority'),
                ((@($AuthorityLine) -join "`n") + "`n"))
        }
        return $root
    }

    function New-ConfiguredHome {
        <# A home the channel considers switched on. #>
        param([string[]]$AuthorityLine)
        $splat = @{ WithToken = $true; WithAllow = $true }
        if ($PSBoundParameters.ContainsKey('AuthorityLine')) { $splat['AuthorityLine'] = $AuthorityLine }
        return (New-TelegramHome @splat)
    }

    function Get-InboxLine {
        param([Parameter(Mandatory)][string]$HomePath)
        # The unary comma keeps a one-line inbox from unrolling into a bare
        # string on the way out, which would leave every .Count assertion below
        # asking a String for a property it does not have.
        $path = Join-Path $HomePath 'state' 'captain-telegram.inbox'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return , @() }
        return , @([System.IO.File]::ReadAllLines($path) | Where-Object { $_ })
    }

    function Invoke-TelegramScript {
        <#
            .SYNOPSIS
            Run an entry point as a real child process against a given home.

            .DESCRIPTION
            A child process cannot be mocked, so every caller must give it either
            a home with no token or an API root pointing at the dead loopback
            port. That is what keeps the CLI contract under test and no request
            reaching Telegram at the same time.
        #>
        param(
            [Parameter(Mandatory)][string]$Script,
            [string[]]$CliArgs = @(),
            [string]$FmHome = '',
            [string]$ApiBase = ''
        )
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:Pwsh
        foreach ($a in (@('-NoProfile', '-File', $Script) + $CliArgs)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE',
                'FM_TELEGRAM_API_BASE')) {
            $psi.Environment.Remove($name) | Out-Null
        }
        if ($FmHome) {
            $psi.Environment['FM_HOME'] = $FmHome
            $psi.Environment['FM_ROOT_OVERRIDE'] = $FmHome
        }
        # Deliberately set even when empty is not wanted: an entry-point test that
        # forgot this would talk to the real api.telegram.org.
        $psi.Environment['FM_TELEGRAM_API_BASE'] = $(if ($ApiBase) { $ApiBase } else { $script:DeadApi })
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) {
        if ($null -eq $script:SavedEnv[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:$name" -Value $script:SavedEnv[$name]
        }
    }
}

Describe 'the message that goes out' {
    It 'says nothing, and fails nothing, when the channel is not set up' {
        $home_ = New-TelegramHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'the network must not be reached when the channel is off' }
            $sent = Send-FmTelegramMessage -Message 'Captain, something happened.' -FirstmateHome $HomePath
            $sent.Sent | Should -BeFalse
            $sent.Reason | Should -Be 'off'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    It 'stays off, and says why, when there is a token but nobody on the allowlist' {
        $home_ = New-TelegramHome -WithToken
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'the network must not be reached with an empty allowlist' }
            $sent = Send-FmTelegramMessage -Message 'Captain, something happened.' -FirstmateHome $HomePath
            $sent.Reason | Should -Be 'off'
            $sent.Warning | Should -Match 'no allowlist'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    It 'sends when it is set up, as plain text, to the allowlisted captain' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $sent = Send-FmTelegramMessage -Message 'Captain, the sign-in fix is ready for your review.' `
                -FirstmateHome $HomePath
            $sent.Sent | Should -BeTrue
            $sent.Reason | Should -Be 'sent'
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $body = $BodyJson | ConvertFrom-Json
                $Url -like '*/sendMessage' -and
                $body.chat_id -eq $Captain -and
                $body.text -eq 'Captain, the sign-in fix is ready for your review.' -and
                $body.disable_web_page_preview -eq $true -and
                # No parse_mode, ever: MarkdownV2 needs arbitrary characters
                # escaped, and an escalation that returns 400 never arrives.
                $BodyJson -notmatch 'parse_mode'
            }
        }
    }

    It 'strips the machinery a status line would carry, and leaves the PR link alone' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $null = Send-FmTelegramMessage -FirstmateHome $HomePath `
                -Message 'done: [90%] [key=api-shape] sign-in restored https://github.com/acme/app/pull/482'
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text -notmatch 'done:' -and $text -notmatch '90%' -and $text -notmatch 'key=' -and
                $text -match 'Sign-in restored' -and
                $text -match 'https://github\.com/acme/app/pull/482'
            }
        }
    }

    It 'truncates an over-long message visibly, rather than silently or by being rejected' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $sent = Send-FmTelegramMessage -Message ('sentence ' * 900) -FirstmateHome $HomePath
            $sent.Sent | Should -BeTrue
            $sent.Truncated | Should -BeTrue
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text.Length -le (Get-FmTelegramMaxLength) -and $text.EndsWith('(message truncated)')
            }
        }
    }

    It 'leaves a message that fits exactly at the bound alone' {
        InModuleScope Firstmate {
            $bounded = Get-FmTelegramMessageText -Message ('x' * (Get-FmTelegramMaxLength))
            $bounded.Truncated | Should -BeFalse
            $bounded.Text.Length | Should -Be (Get-FmTelegramMaxLength)
        }
    }

    It 'sends nothing when stripping the machinery leaves nothing to say' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'an empty message must not become a request' }
            $sent = Send-FmTelegramMessage -Message 'working: [40%] state/thing.status' -FirstmateHome $HomePath
            $sent.Sent | Should -BeFalse
            $sent.Reason | Should -Be 'empty'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    It 'calls it sent only when the API confirmed it' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{
                    Ok = $false; Reason = 'refused'; ErrorCode = 400
                    Description = 'Bad Request: chat not found'; Result = $null
                }
            }
            $sent = Send-FmTelegramMessage -Message 'Captain, a decision is waiting.' -FirstmateHome $HomePath
            $sent.Sent | Should -BeFalse
            $sent.Reason | Should -Be 'refused'
            $sent.Detail | Should -Match 'chat not found'
            # An answered refusal is permanent for this message; asking again
            # would only be a second identical 400.
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly
        }
    }

    It 'retries a hung call, because a failing call to this API is a hang and not an error' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{
                    Ok = $false; Reason = 'timeout'; ErrorCode = 0
                    Description = 'the request did not complete (TaskCanceledException)'; Result = $null
                }
            }
            Mock Start-Sleep { }
            $sent = Send-FmTelegramMessage -Message 'Captain, a decision is waiting.' `
                -FirstmateHome $HomePath -Retries 2
            $sent.Sent | Should -BeFalse
            $sent.Reason | Should -Be 'timeout'
            $sent.Attempts | Should -Be 3
            Should -Invoke Invoke-FmTelegramApi -Times 3 -Exactly
        }
    }

    It 'stops retrying the moment one attempt is confirmed' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            $script:TelegramAttempt = 0
            Mock Invoke-FmTelegramApi {
                $script:TelegramAttempt++
                if ($script:TelegramAttempt -lt 2) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'unreachable'; ErrorCode = 0
                        Description = ''; Result = $null
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            Mock Start-Sleep { }
            $sent = Send-FmTelegramMessage -Message 'Captain, ready for review.' -FirstmateHome $HomePath -Retries 5
            $sent.Sent | Should -BeTrue
            $sent.Attempts | Should -Be 2
            Should -Invoke Invoke-FmTelegramApi -Times 2 -Exactly
        }
    }

    It 'never puts the token in anything it hands back' {
        $home_ = New-ConfiguredHome
        InModuleScope Firstmate -Parameters @{
            HomePath = $home_; Token = $script:FakeToken; Secret = $script:FakeTokenSecret
        } {
            param($HomePath, $Token, $Secret)
            # The URL is where Telegram carries the credential, so the seam is
            # given one that contains it - and the result must still be clean.
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{
                    Ok = $false; Reason = 'unreachable'; ErrorCode = 0
                    Description = 'the request did not complete (HttpRequestException)'; Result = $null
                }
            }
            Mock Start-Sleep { }
            $sent = Send-FmTelegramMessage -Message 'Captain, ready for review.' -FirstmateHome $HomePath
            # It really did use the token, so the assertion below is about
            # discipline rather than about the token being unused.
            Should -Invoke Invoke-FmTelegramApi -ParameterFilter { $Url -like "*$Token*" }
            $rendered = ($sent | Format-List | Out-String) + ($sent | ConvertTo-Json -Depth 5)
            $rendered | Should -Not -Match ([regex]::Escape($Token))
            $rendered | Should -Not -Match ([regex]::Escape($Secret))
        }
    }
}

Describe 'the shared plain-text stripper, which the channel leans on' {
    It 'leaves a PR link intact, because a mangled link is the one thing a phone needed' {
        ConvertTo-FmBridgePlainText -Text 'https://github.com/acme/app/pull/482' |
            Should -Be 'https://github.com/acme/app/pull/482'
    }

    It 'leaves a link intact even when its path spells a directory this repo also has' {
        ConvertTo-FmBridgePlainText -Text 'ready: see https://github.com/acme/docs/pull/7 for the write-up' |
            Should -Match 'https://github\.com/acme/docs/pull/7'
    }

    It 'still strips the machinery it was written to strip' {
        $plain = ConvertTo-FmBridgePlainText -Text 'needs-decision: [40%] [key=api-shape] flat or nested'
        $plain | Should -Be 'Flat or nested'
    }
}

Describe 'what a message from a phone is allowed to do' {
    It 'always allows asking how things stand' -ForEach @(
        @{ Text = 'what is running' }
        @{ Text = 'show me the backlog' }
        @{ Text = 'how far along is the sign-in fix' }
        @{ Text = 'anything waiting on me' }
    ) {
        $verdict = Test-FmTelegramCommand -Text $Text
        $verdict.Tier | Should -Be 1
        $verdict.Allowed | Should -BeTrue
    }

    It 'allows work that can be undone' -ForEach @(
        @{ Text = 'start looking at the sign-in bug' }
        @{ Text = 'use the flat one' }
        @{ Text = 'have someone investigate the slow checkout page' }
    ) {
        $verdict = Test-FmTelegramCommand -Text $Text
        $verdict.Tier | Should -Be 2
        $verdict.Allowed | Should -BeTrue
    }

    It 'refuses what cannot be undone, and names it' -ForEach @(
        @{ Text = 'merge the payments branch'; Expected = 'land that work' }
        @{ Text = 'go ahead and land it'; Expected = 'land that work' }
        @{ Text = 'delete the old copy'; Expected = 'delete that' }
        @{ Text = 'discard that work'; Expected = 'throw that work away' }
        @{ Text = 'tear down the payments investigation'; Expected = 'clean that up for good' }
        @{ Text = 'rotate the token'; Expected = 'touch a login' }
        @{ Text = 'change the deploy password'; Expected = 'touch a login' }
        @{ Text = 'revoke the deploy key'; Expected = 'change a login' }
    ) {
        $verdict = Test-FmTelegramCommand -Text $Text
        $verdict.Tier | Should -Be 3
        $verdict.Allowed | Should -BeFalse
        $verdict.Action | Should -Be $Expected
    }

    It 'says what it refused and why, rather than failing silently' {
        $verdict = Test-FmTelegramCommand -Text 'merge the payments branch'
        $verdict.Message | Should -Not -BeNullOrEmpty
        $verdict.Message | Should -Match 'land that work'
        $verdict.Message | Should -Match 'cannot be undone'
        $verdict.Message | Should -Match 'at the machine'
    }

    It 'keeps machinery out of the refusal it sends' {
        $verdict = Test-FmTelegramCommand -Text 'delete the worktree'
        $verdict.Message | Should -Not -Match 'worktree|crewmate|wake|watcher|teardown|status file|task id'
    }

    It 'reads a request to land work as a merge however it is worded, not as a question' {
        # A message that asks AND instructs is the instruction.
        (Test-FmTelegramCommand -Text 'what is the status - and merge it when green').Tier | Should -Be 3
    }

    It 'hears about a sign-in fix without mistaking it for touching a login' {
        # The captain's own example message is about a sign-in fix. A channel
        # that refused to discuss one would be useless on its first day.
        (Test-FmTelegramCommand -Text 'how is the sign-in fix going').Tier | Should -Be 1
        (Test-FmTelegramCommand -Text 'get someone on the sign-in bug').Tier | Should -Be 2
    }
}

Describe 'the refusal cannot be widened' {
    It 'refuses a caller that asks for a higher ceiling than the code allows' {
        foreach ($asked in @(3, 4, 99, [int]::MaxValue)) {
            $verdict = Test-FmTelegramCommand -Text 'merge the payments branch' -MaxTier $asked
            $verdict.Allowed | Should -BeFalse
            $verdict.Tier | Should -Be 3
        }
    }

    It 'refuses a config file that tries to widen it, and says the file did not do what it says' {
        $home_ = New-ConfiguredHome -AuthorityLine @('allow-tier=3')
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            $authority = Get-FmTelegramAuthority -HomePath $HomePath
            $authority.MaxTier | Should -Be 2
            $authority.Warning | Should -Match 'refused'
        }
        $handled = Receive-FmTelegramCommand -Text 'merge the payments branch' -FirstmateHome $home_
        $handled.Accepted | Should -BeFalse
        $handled.Reason | Should -Be 'refused'
        Get-InboxLine -HomePath $home_ | Should -BeNullOrEmpty
    }

    It 'refuses an absurd config value the same way' {
        $home_ = New-ConfiguredHome -AuthorityLine @('allow-tier=99')
        (Receive-FmTelegramCommand -Text 'delete the old branch' -FirstmateHome $home_).Reason |
            Should -Be 'refused'
    }

    It 'refuses just as firmly with no config file at all' {
        $home_ = New-ConfiguredHome
        (Receive-FmTelegramCommand -Text 'merge it' -FirstmateHome $home_).Reason | Should -Be 'refused'
    }

    It 'refuses just as firmly when the config file is unreadable nonsense' {
        $home_ = New-ConfiguredHome -AuthorityLine @('%%%not a setting%%%', 'allow-tier=yes')
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            (Get-FmTelegramAuthority -HomePath $HomePath).MaxTier | Should -Be 2
        }
        (Receive-FmTelegramCommand -Text 'tear it all down' -FirstmateHome $home_).Reason | Should -Be 'refused'
    }

    It 'still lets the captain ask how things stand, however far a config file narrows it' {
        $home_ = New-ConfiguredHome -AuthorityLine @('allow-tier=0')
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            (Get-FmTelegramAuthority -HomePath $HomePath).MaxTier | Should -Be 1
        }
        (Receive-FmTelegramCommand -Text 'what is waiting on me' -FirstmateHome $home_).Accepted |
            Should -BeTrue
    }

    It 'lets the config file NARROW the channel to reporting only' {
        $home_ = New-ConfiguredHome -AuthorityLine @('allow-tier=1')
        $asking = Receive-FmTelegramCommand -Text 'what is running' -FirstmateHome $home_
        $asking.Accepted | Should -BeTrue
        $steering = Receive-FmTelegramCommand -Text 'start looking at the checkout bug' -FirstmateHome $home_
        $steering.Accepted | Should -BeFalse
        $steering.Reason | Should -Be 'refused'
        $steering.Reply | Should -Match 'how things stand'
    }
}

Describe 'taking one message in' {
    It 'records an allowed message verbatim, in its own kind of file' {
        $home_ = New-ConfiguredHome
        $handled = Receive-FmTelegramCommand -Text 'have someone look at the slow checkout page' -FirstmateHome $home_
        $handled.Accepted | Should -BeTrue
        $handled.Recorded | Should -BeTrue
        $lines = Get-InboxLine -HomePath $home_
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'have someone look at the slow checkout page'
        # Its own file kind, so an inbound message never masquerades as a task.
        Test-Path -LiteralPath (Join-Path $home_ 'state' 'captain-telegram.status') | Should -BeFalse
    }

    It 'records nothing at all for a message it refuses' {
        $home_ = New-ConfiguredHome
        $handled = Receive-FmTelegramCommand -Text 'merge the payments branch' -FirstmateHome $home_
        $handled.Recorded | Should -BeFalse
        $handled.Reply | Should -Match 'land that work'
        Get-InboxLine -HomePath $home_ | Should -BeNullOrEmpty
    }

    It 'ignores an empty message without recording or answering it' {
        $home_ = New-ConfiguredHome
        $handled = Receive-FmTelegramCommand -Text '   ' -FirstmateHome $home_
        $handled.Accepted | Should -BeFalse
        $handled.Reason | Should -Be 'empty'
        $handled.Reply | Should -BeNullOrEmpty
        Get-InboxLine -HomePath $home_ | Should -BeNullOrEmpty
    }
}

Describe 'answering a waiting question closes it' {
    BeforeEach {
        $script:AnswerHome = New-ConfiguredHome
        $script:AnswerState = Join-Path $script:AnswerHome 'state'
    }

    It 'closes the one waiting question and stops it being asked again' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 1

        $handled = Receive-FmTelegramCommand -Text 'use the flat one' -FirstmateHome $script:AnswerHome
        $handled.Closed | Should -BeTrue
        $handled.Task | Should -Be 'payments'
        $handled.Key | Should -Be 'api-shape'
        $handled.Reason | Should -Be 'answered'

        # The closure is a durable resolved line carrying the SAME key, which is
        # the only thing that closes a decision - and the captain's words survive
        # in it, so an answer is never only a closure.
        $lines = [System.IO.File]::ReadAllLines((Join-Path $script:AnswerState 'payments.status'))
        $lines[-1] | Should -Be 'resolved [key=api-shape]: use the flat one'
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 0
    }

    It 'tells the captain what it took the answer to be, so a wrong reading is visible' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $handled = Receive-FmTelegramCommand -Text 'use the flat one' -FirstmateHome $script:AnswerHome
        $handled.Reply | Should -Match 'flat or nested response'
        $handled.Reply | Should -Match 'wrong'
    }

    It 'closes the question the captain names when several are waiting' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'checkout' -State 'blocked' `
            -Key 'vendor' -Note 'wait for the vendor or work round it' -Confirm:$false

        $handled = Receive-FmTelegramCommand -Text 'key=vendor work round it' -FirstmateHome $script:AnswerHome
        $handled.Closed | Should -BeTrue
        $handled.Key | Should -Be 'vendor'
        $open = Get-FmOpenDecisionScan -StatePath $script:AnswerState
        $open.Count | Should -Be 1
        $open[0].Key | Should -Be 'api-shape'
    }

    It 'refuses to guess when several are waiting and none is named' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'checkout' -State 'blocked' `
            -Key 'vendor' -Note 'wait for the vendor or work round it' -Confirm:$false

        $handled = Receive-FmTelegramCommand -Text 'go with the second one' -FirstmateHome $script:AnswerHome
        $handled.Closed | Should -BeFalse
        $handled.Reply | Should -Match 'more than one'
        # It still passed the words on rather than dropping them.
        $handled.Recorded | Should -BeTrue
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 2
    }

    It 'never lets a question about how things stand close a waiting decision' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $handled = Receive-FmTelegramCommand -Text 'what is waiting on me' -FirstmateHome $script:AnswerHome
        $handled.Closed | Should -BeFalse
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 1
    }

    It 'says so when the named question is not waiting any more' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $handled = Receive-FmTelegramCommand -Text 'key=long-gone whatever' -FirstmateHome $script:AnswerHome
        $handled.Closed | Should -BeFalse
        $handled.Reply | Should -Match 'not waiting on you any more'
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 1
    }

    It 'answers nothing, and writes nothing, when no question is waiting' {
        $decision = Resolve-FmTelegramDecision -Answer 'use the flat one' -FirstmateHome $script:AnswerHome
        $decision.Closed | Should -BeFalse
        $decision.Reason | Should -Be 'none'
    }

    It 'refuses an empty answer rather than closing a question with nothing' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'payments' -State 'needs-decision' `
            -Key 'api-shape' -Note 'flat or nested response' -Confirm:$false
        $decision = Resolve-FmTelegramDecision -Answer '   ' -FirstmateHome $script:AnswerHome
        $decision.Closed | Should -BeFalse
        $decision.Reason | Should -Be 'empty'
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 1
    }

    It 'closes a named question directly, without going through a message' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerState -TaskId 'checkout' -State 'blocked' `
            -Key 'vendor' -Note 'wait for the vendor or work round it' -Confirm:$false
        $decision = Resolve-FmTelegramDecision -Answer 'work round it' -Key 'vendor' `
            -FirstmateHome $script:AnswerHome
        $decision.Closed | Should -BeTrue
        $decision.Task | Should -Be 'checkout'
        $decision.Question | Should -Be 'Wait for the vendor or work round it'
        (Get-FmOpenDecisionScan -StatePath $script:AnswerState).Count | Should -Be 0
    }
}

Describe 'the key a message names' {
    It 'reads a key the captain quoted back, in either shape' -ForEach @(
        @{ Text = 'key=api-shape use the flat one'; Expected = 'api-shape' }
        @{ Text = 'use the flat one [key=api-shape]'; Expected = 'api-shape' }
        @{ Text = 'go with [key=vendor_2.1] the workaround'; Expected = 'vendor_2.1' }
    ) {
        Get-FmTelegramAnswerKey -Text $Text | Should -Be $Expected
    }

    It 'infers nothing from prose, so an ordinary message names no question' -ForEach @(
        @{ Text = 'use the flat one' }
        @{ Text = 'the key thing is speed' }
        @{ Text = '' }
    ) {
        Get-FmTelegramAnswerKey -Text $Text | Should -Be ''
    }
}

Describe 'listening for the captain' {
    BeforeEach {
        $script:PollHome = New-ConfiguredHome
        $script:PollState = Join-Path $script:PollHome 'state'
    }

    It 'does not listen at all when the channel is not set up' {
        $bare = New-TelegramHome
        InModuleScope Firstmate -Parameters @{ HomePath = $bare } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'the network must not be reached when the channel is off' }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            $run.Started | Should -BeFalse
            $run.Reason | Should -Be 'off'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    It 'refuses to be the second listener, rather than taking half the messages' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; StateDir = $script:PollState } {
            param($HomePath, $StateDir)
            Mock Invoke-FmTelegramApi { throw 'a refused second poller must not reach the network' }
            $lockDir = Get-FmTelegramPollLockPath -StateDir $StateDir
            # Taken by THIS process, which is unarguably alive, so the refusal
            # under test is the singleton and not stale-owner recovery.
            (Lock-FmPath -LockDir $lockDir) | Should -BeTrue
            try {
                $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
                $run.Started | Should -BeFalse
                $run.Reason | Should -Be 'busy'
                Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
                # And it did not take the lock away from the holder on its way out.
                (Get-FmLockPid -LockDir $lockDir) | Should -Be ([string](Get-FmCurrentProcessId))
            } finally { Unlock-FmPath -LockDir $lockDir }
        }
    }

    It 'releases the lock when it stops, so the next one can start' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; StateDir = $script:PollState } {
            param($HomePath, $StateDir)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = @() }
            }
            (Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1).Started | Should -BeTrue
            $lockDir = Get-FmTelegramPollLockPath -StateDir $StateDir
            Test-Path -LiteralPath $lockDir | Should -BeFalse
        }
    }

    It 'takes a message from the captain and records it, then confirms it' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 11
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'have someone look at the checkout page'
                                    from = [pscustomobject]@{ id = $Captain }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            $run.Accepted | Should -Be 1
            $run.Dropped | Should -Be 0
            $run.Refused | Should -Be 0
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter { $Url -match 'sendMessage' }
        }
        $lines = Get-InboxLine -HomePath $script:PollHome
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'have someone look at the checkout page'
    }

    It 'confirms the update so a restart does not replay it' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 11
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'what is running'
                                    from = [pscustomobject]@{ id = $Captain }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $null = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            Get-FmTelegramOffset -StateDir (Join-Path $HomePath 'state') | Should -Be 12
        }
    }

    It 'drops a message from anyone who is not the captain, and says nothing back' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 5
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'what is running'
                                    from = [pscustomobject]@{ id = 111111 }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            $run.Dropped | Should -Be 1
            $run.Accepted | Should -Be 0
            # Not even a refusal goes back: answering a stranger confirms the bot
            # is live and who is behind it.
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly -ParameterFilter { $Url -match 'sendMessage' }
        }
        Get-InboxLine -HomePath $script:PollHome | Should -BeNullOrEmpty
    }

    It 'drops a message that has been sitting on the server, rather than replaying a day of orders' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 7
                                message   = [pscustomobject]@{
                                    date = ((Get-FmUnixTime) - 86000); text = 'have someone look at the checkout page'
                                    from = [pscustomobject]@{ id = $Captain }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1 -MaxAgeSeconds 300
            $run.Dropped | Should -Be 1
            $run.Accepted | Should -Be 0
        }
        Get-InboxLine -HomePath $script:PollHome | Should -BeNullOrEmpty
    }

    It 'answers a refused message instead of going quiet on it' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 21
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'merge the payments branch'
                                    from = [pscustomobject]@{ id = $Captain }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            $run.Refused | Should -Be 1
            $run.Accepted | Should -Be 0
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $Url -match 'sendMessage' -and ($BodyJson | ConvertFrom-Json).text -match 'land that work'
            }
        }
        Get-InboxLine -HomePath $script:PollHome | Should -BeNullOrEmpty
    }

    It 'survives a call that never answered, and keeps its own counters straight' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:PollHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $false; Reason = 'timeout'; ErrorCode = 0; Description = ''; Result = $null }
            }
            Mock Start-Sleep { }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 2
            $run.Started | Should -BeTrue
            $run.Failed | Should -Be 2
            $run.Accepted | Should -Be 0
        }
    }
}

Describe 'the inbound record is a notification the watcher already understands' {
    It 'is scanned alongside the status files, so a message wakes the monitoring' {
        $home_ = New-ConfiguredHome
        $null = Receive-FmTelegramCommand -Text 'what is running' -FirstmateHome $home_
        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            $context = Get-FmWakeContext -FmHome $HomePath -State (Join-Path $HomePath 'state')
            $changes = @(Get-FmWatchSignalChanges -Context $context)
            @($changes | Where-Object { $_.Path -like '*captain-telegram.inbox' }).Count | Should -Be 1
        }
    }
}

Describe 'the entry points, run as real processes' {
    It 'fm-tell.ps1 says nothing and exits cleanly when the channel is not set up' {
        $bare = New-TelegramHome
        $run = Invoke-TelegramScript -Script $script:TellScript -FmHome $bare -CliArgs @('Captain, ready for review.')
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'not set up'
    }

    It 'fm-tell.ps1 refuses an empty invocation as usage' {
        $run = Invoke-TelegramScript -Script $script:TellScript -FmHome (New-TelegramHome)
        $run.ExitCode | Should -Be 2
        $run.StdErr | Should -Match 'usage:'
    }

    It 'fm-tell.ps1 answers -h with its own help' {
        $run = Invoke-TelegramScript -Script $script:TellScript -FmHome (New-TelegramHome) -CliArgs @('-h')
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'fm-tell'
    }

    It 'fm-tell.ps1 never prints the token, even when the send fails' {
        $home_ = New-ConfiguredHome
        $run = Invoke-TelegramScript -Script $script:TellScript -FmHome $home_ `
            -CliArgs @('-TimeoutSeconds', '2', '-Retries', '0', 'Captain, ready for review.')
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'not sent'
        $everything = $run.StdOut + $run.StdErr
        $everything | Should -Not -Match ([regex]::Escape($script:FakeToken))
        $everything | Should -Not -Match ([regex]::Escape($script:FakeTokenSecret))
        # Nor into the durable records, which is the other place a logged request
        # would land.
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $home_ 'state') -File -Recurse -Force)) {
            [System.IO.File]::ReadAllText($file.FullName) |
                Should -Not -Match ([regex]::Escape($script:FakeTokenSecret))
        }
    }

    It 'fm-tg-poll.ps1 says nothing and exits cleanly when the channel is not set up' {
        $run = Invoke-TelegramScript -Script $script:PollScript -FmHome (New-TelegramHome)
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'not listening'
    }

    It 'fm-tg-poll.ps1 refuses to start while another process is already listening' {
        $home_ = New-ConfiguredHome
        $state = Join-Path $home_ 'state'
        # Held by the Pester process, which the child can see is alive, so what
        # the child refuses on is the singleton and not a stale lock.
        $lockDir = InModuleScope Firstmate -Parameters @{ StateDir = $state } {
            param($StateDir)
            $dir = Get-FmTelegramPollLockPath -StateDir $StateDir
            if (-not (Lock-FmPath -LockDir $dir)) { throw 'test fixture could not take the poller lock' }
            $dir
        }
        try {
            $run = Invoke-TelegramScript -Script $script:PollScript -FmHome $home_ -CliArgs @('-MaxCycles', '1')
            $run.ExitCode | Should -Be 0
            $run.StdErr | Should -Match 'already listening'
            $run.StdErr | Should -Not -Match ([regex]::Escape($script:FakeTokenSecret))
        } finally {
            InModuleScope Firstmate -Parameters @{ LockDir = $lockDir } {
                param($LockDir)
                Unlock-FmPath -LockDir $LockDir
            }
        }
    }

    It 'fm-tg-poll.ps1 answers -h with its own help' {
        $run = Invoke-TelegramScript -Script $script:PollScript -FmHome (New-TelegramHome) -CliArgs @('-h')
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'fm-tg-poll'
    }
}
