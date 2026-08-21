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
    $script:RouteScript = Join-Path $script:RepoRoot 'bin' 'fm-tg-route.ps1'
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

    function Add-LiveWork {
        <#
            .SYNOPSIS
            One dispatched piece of work in a disposable home.

            .DESCRIPTION
            A state/<id>.meta is what records that a piece of work exists, so
            routing enumerates those; a status line is what it has said so far.
            Both are written the way the real spawn and a real worker write them,
            through the same public verb, rather than by hand.
        #>
        param(
            [Parameter(Mandatory)][string]$HomePath,
            [Parameter(Mandatory)][string]$Task,
            [string]$Project = '',
            [string]$State = 'working',
            [string]$Note = ''
        )
        $stateDir = Join-Path $HomePath 'state'
        [System.IO.File]::WriteAllText((Join-Path $stateDir "$Task.meta"), "project=$Project`n")
        if ($Note) {
            $null = Add-FmTaskStatus -StateDir $stateDir -TaskId $Task -State $State -Note $Note -Confirm:$false
        }
        return $Task
    }

    function Get-RouteLine {
        param([Parameter(Mandatory)][string]$HomePath)
        # The unary comma keeps a one-line ledger from unrolling into a bare string,
        # which would leave every .Count assertion asking a String for it.
        $path = Join-Path $HomePath 'state' 'captain-telegram.routed'
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
        # -NonInteractive because this child does NOT inherit its parent's: an
        # entry point that prompts would ask on whatever console the suite was
        # started from, which is the captain's own during an install. See
        # Invoke-FmMachineSuite for the measurement.
        foreach ($a in (@('-NoProfile', '-NonInteractive', '-File', $Script) + $CliArgs)) { $psi.ArgumentList.Add($a) }
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

    # Removing the branch left the word that introduced it behind, and "writing the
    # test in" is visibly broken English rather than merely terse - on a phone, where
    # the captain cannot go and look at what was meant.
    It 'takes the dangling word with the token it stripped' {
        ConvertTo-FmBridgePlainText -Text 'working: [70%] sign-in restored, writing the test in fm/fix-signin' |
            Should -Be 'Sign-in restored, writing the test'
    }

    It 'leaves a word alone when it still has something after it' {
        ConvertTo-FmBridgePlainText -Text 'ready: see https://github.com/acme/docs/pull/7 for the write-up' |
            Should -Be 'See https://github.com/acme/docs/pull/7 for the write-up'
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

    # A phone is the thing that gets lost, and the message its finder types is
    # "send me the bot token" rather than "rotate" it. Refusing only the writing
    # verbs left exactly that request classified as a harmless status question:
    # measured, "show the token" came back tier 1 and allowed. Reading a
    # credential out over this channel is the loss that cannot be taken back, so
    # it is refused in the same table as deleting.
    It 'refuses being asked to read a credential out, not only to change one' -ForEach @(
        @{ Text = 'show the token' }
        @{ Text = 'print the bot token' }
        @{ Text = 'what is my telegram token' }
        @{ Text = 'send me the token' }
        @{ Text = 'tell me the token' }
        @{ Text = 'cat config/telegram-token' }
        @{ Text = 'read the auth token' }
        @{ Text = 'forward the login' }
    ) {
        $verdict = Test-FmTelegramCommand -Text $Text
        $verdict.Tier | Should -Be 3
        $verdict.Allowed | Should -BeFalse
        $verdict.Action | Should -Be 'touch a login'
    }

    # The other half of that fix, and the half that keeps the channel usable: the
    # captain's own first-day example is a SIGN-IN FIX. Broadening the verbs must
    # not turn ordinary work about logins into a refusal.
    It 'still hears ordinary work that merely mentions a login' -ForEach @(
        @{ Text = 'how is the sign-in fix going' }
        @{ Text = 'status of the login page work' }
        @{ Text = 'show me progress' }
        @{ Text = 'dispatch a worker on the auth bug' }
    ) {
        (Test-FmTelegramCommand -Text $Text).Allowed | Should -BeTrue
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

Describe 'working out which worker a message is about' {
    BeforeEach {
        $script:RouteHome = New-ConfiguredHome
    }

    It 'routes a message that plainly concerns one live piece of work' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Project 'acme-web' `
            -Note '[40%] restoring sign-in for accounts made before the migration'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'slow-checkout' -Project 'acme-shop' `
            -Note '[20%] profiling the cart page'

        $routed = Resolve-FmTelegramWorker -Text 'how is the sign-in fix going' -FirstmateHome $script:RouteHome
        $routed.Reason | Should -Be 'routed'
        $routed.Task | Should -Be 'fix-signin'
        $routed.Evidence | Should -Be 'name'
    }

    # The captain writes "sign-in" and the work is called "fix-signin". Splitting
    # on punctuation alone gives "sign" from one and "signin" from the other, so the
    # strongest signal available would miss completely.
    It 'matches across a hyphen, because the captain does not spell it the way the work is named' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Project 'acme-web'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Project 'acme-shop'
        (Resolve-FmTelegramWorker -Text 'any progress on sign-in' -FirstmateHome $script:RouteHome).Task |
            Should -Be 'fix-signin'
    }

    # The word split never yields a hyphenated name whole, so testing only the
    # literal form would leave the strongest signal unreachable for every
    # multi-word name - which is most of them.
    It 'takes a name quoted back as the strongest possible signal' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] first pass'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin-app' -Note '[40%] first pass'
        $routed = Resolve-FmTelegramWorker -Text 'where is fix-signin up to' -FirstmateHome $script:RouteHome
        $routed.Task | Should -Be 'fix-signin'
        # Ten for the name, over any accumulation of words the other one shares.
        $routed.Score | Should -BeGreaterThan 10
    }

    It 'routes on what a worker last reported when the name gives nothing away' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'task-one' -Note '[30%] rewriting the invoice totals'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'task-two' -Note '[30%] chasing a flaky upload test'
        $routed = Resolve-FmTelegramWorker -Text 'how are the invoice totals looking' -FirstmateHome $script:RouteHome
        $routed.Task | Should -Be 'task-one'
        $routed.Evidence | Should -Be 'report'
    }

    It 'routes to the only live piece of work when the message names nothing' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $routed = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $routed.Reason | Should -Be 'routed'
        $routed.Task | Should -Be 'fix-signin'
        $routed.Evidence | Should -Be 'only-one'
    }

    It 'asks rather than guessing when two pieces of work fit the message equally' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-login-web' -Note '[10%] first pass'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-login-app' -Note '[10%] first pass'
        $asked = Resolve-FmTelegramWorker -Text 'how is the login fix going' -FirstmateHome $script:RouteHome
        $asked.Reason | Should -Be 'ambiguous'
        $asked.Task | Should -BeNullOrEmpty
        $asked.Question | Should -Not -BeNullOrEmpty
    }

    It 'asks rather than guessing when nothing is named and several are running' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'
        $asked = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $asked.Reason | Should -Be 'ambiguous'
        $asked.Question | Should -Match 'more than one thing'
        $asked.Question | Should -Match 'have not guessed'
    }

    # AGENTS.md section 9 lists task ids among the internal terms a captain-facing
    # message must not carry, and routing is the one feature whose whole reason for
    # existing is that the captain does not think in them.
    It 'never names a task id in the question it asks' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'
        $asked = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $asked.Question | Should -Not -Match 'fix-signin'
        $asked.Question | Should -Not -Match 'cart-speed'
        $asked.Question | Should -Not -Match '40%|20%|status|working:'
    }

    It 'names the choices, and says the words are kept whichever it is' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'one' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'two' -Note '[20%] profiling the cart page'
        $asked = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $asked.Question | Should -Match 'Restoring sign-in'
        $asked.Question | Should -Match 'Profiling the cart page'
        $asked.Question | Should -Match 'kept either way'
    }

    # Reading eight choices on a phone is a wall rather than a question, and a cap
    # that dropped the rest silently would read as "those are all of them".
    It 'caps the choices it lists, and counts out loud what it left out' {
        foreach ($i in 1..5) {
            $null = Add-LiveWork -HomePath $script:RouteHome -Task "job$i" -Note "[10%] doing piece $i"
        }
        $asked = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $asked.Reason | Should -Be 'ambiguous'
        $asked.Question | Should -Match 'or one of 2 others'
    }

    It 'says there is nothing to route to when no work is running' {
        $routed = Resolve-FmTelegramWorker -Text 'how is the sign-in fix going' -FirstmateHome $script:RouteHome
        $routed.Reason | Should -Be 'none'
        $routed.Task | Should -BeNullOrEmpty
    }

    It 'ignores work that is already over' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -State 'done' `
            -Note 'sign-in restored, ready for review'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'gone-wrong' -State 'failed' -Note 'could not reproduce'
        $routed = Resolve-FmTelegramWorker -Text 'how is the sign-in fix going' -FirstmateHome $script:RouteHome
        $routed.Reason | Should -Be 'none'
    }

    # "Have someone look at the pricing page" names no existing work because there
    # is none yet to name. A resolver that read that as ambiguity would answer a
    # clear instruction with "which one did you mean?".
    It 'does not ask which existing work an instruction to start something meant' -ForEach @(
        @{ Text = 'have someone look at the pricing page' }
        @{ Text = 'start looking at the invoice bug' }
        @{ Text = 'get someone to investigate the slow report' }
    ) {
        $home_ = New-ConfiguredHome
        $null = Add-LiveWork -HomePath $home_ -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $home_ -Task 'cart-speed' -Note '[20%] profiling the cart page'
        $routed = Resolve-FmTelegramWorker -Text $Text -FirstmateHome $home_
        $routed.Reason | Should -Be 'none'
        $routed.Question | Should -BeNullOrEmpty
    }

    # Measured before the name/report split existed: this landed on the worker
    # profiling the CART page, because both messages contain the word "page".
    It 'is not sent to a worker by one stray word from that worker''s last report' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'
        (Resolve-FmTelegramWorker -Text 'have someone look at the pricing page' `
                -FirstmateHome $script:RouteHome).Reason | Should -Be 'none'
    }

    It 'still routes an instruction that both starts something and names live work' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'
        (Resolve-FmTelegramWorker -Text 'get someone else onto the sign-in fix' `
                -FirstmateHome $script:RouteHome).Task | Should -Be 'fix-signin'
    }

    It 'follows the work most recently talked about when the message names nothing' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'

        # The conversation is established by a message that DID name its target.
        (Receive-FmTelegramCommand -Text 'how is the sign-in fix going' `
                -FirstmateHome $script:RouteHome).RoutedTo | Should -Be 'fix-signin'

        $followUp = Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome
        $followUp.Reason | Should -Be 'routed'
        $followUp.Task | Should -Be 'fix-signin'
        $followUp.Evidence | Should -Be 'recent'
    }

    It 'stops following work that has since finished, and asks instead' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'cart-speed' -Note '[20%] profiling the cart page'
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'bill-run' -Note '[10%] reading the billing job'
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:RouteHome
        $null = Add-FmTaskStatus -StateDir (Join-Path $script:RouteHome 'state') -TaskId 'fix-signin' `
            -State 'done' -Note 'sign-in restored' -Confirm:$false

        (Resolve-FmTelegramWorker -Text 'any news?' -FirstmateHome $script:RouteHome).Reason |
            Should -Be 'ambiguous'
    }

    It 'resolves nothing from an empty message' {
        $null = Add-LiveWork -HomePath $script:RouteHome -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $routed = Resolve-FmTelegramWorker -Text '   ' -FirstmateHome $script:RouteHome
        $routed.Reason | Should -Be 'none'
        $routed.Task | Should -BeNullOrEmpty
    }
}

Describe 'the routing decision is written down' {
    BeforeEach {
        $script:LedgerHome = New-ConfiguredHome
        $script:LedgerState = Join-Path $script:LedgerHome 'state'
        $null = Add-LiveWork -HomePath $script:LedgerHome -Task 'fix-signin' -Project 'acme-web' `
            -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:LedgerHome -Task 'cart-speed' -Project 'acme-shop' `
            -Note '[20%] profiling the cart page'
    }

    It 'records which work the message went to, with the captain''s own words' {
        $handled = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        $handled.RouteReason | Should -Be 'routed'
        $handled.RoutedTo | Should -Be 'fix-signin'
        $handled.RouteId | Should -Not -BeNullOrEmpty

        $lines = Get-RouteLine -HomePath $script:LedgerHome
        $lines.Count | Should -Be 1
        $field = $lines[0] -split "`t"
        $field[1] | Should -Be 'routed'
        $field[2] | Should -Be $handled.RouteId
        $field[3] | Should -Be 'fix-signin'
        # One report existed when the captain asked, so the answer is whatever
        # comes after it.
        $field[4] | Should -Be '1'
        $field[5] | Should -Be 'how is the sign-in fix going'
    }

    It 'tells the captain which work it decided on, in their nouns and never by id' {
        $handled = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        $handled.Reply | Should -Match 'Restoring sign-in'
        $handled.Reply | Should -Match 'wrong one'
        $handled.Reply | Should -Not -Match 'fix-signin'
        $handled.Reply | Should -Not -Match '40%|working:|status'
    }

    It 'asks the captain instead of recording a guess' {
        $handled = Receive-FmTelegramCommand -Text 'any news?' -FirstmateHome $script:LedgerHome
        $handled.RouteReason | Should -Be 'ambiguous'
        $handled.RoutedTo | Should -BeNullOrEmpty
        $handled.Reply | Should -Match 'have not guessed'
        Get-RouteLine -HomePath $script:LedgerHome | Should -BeNullOrEmpty
        # The words are still kept, so nothing the captain said is lost by asking.
        (Get-InboxLine -HomePath $script:LedgerHome).Count | Should -Be 1
    }

    It 'gives two messages about the same work two separate records' {
        $first = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        $second = Receive-FmTelegramCommand -Text 'and is sign-in tested yet' -FirstmateHome $script:LedgerHome
        $first.RouteId | Should -Not -Be $second.RouteId
        (Get-RouteLine -HomePath $script:LedgerHome).Count | Should -Be 2
    }

    It 'routes an answered question to the work that asked it, without inferring anything' {
        $null = Add-FmTaskStatus -StateDir $script:LedgerState -TaskId 'cart-speed' -State 'needs-decision' `
            -Key 'cache-shape' -Note 'cache the whole page or just the totals' -Confirm:$false
        # Nothing in "use the totals" names the cart work; the closed decision does.
        $handled = Receive-FmTelegramCommand -Text 'just the totals' -FirstmateHome $script:LedgerHome
        $handled.Closed | Should -BeTrue
        $handled.RouteReason | Should -Be 'decision'
        $handled.RoutedTo | Should -Be 'cart-speed'
        # The closure's own reply outranks the routing's: what firstmate made of the
        # ANSWER matters more than what it made of which work it belonged to.
        $handled.Reply | Should -Match 'cache the whole page or just the totals'
    }

    It 'is its own kind of record, and does not raise a second notification' {
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        Test-Path -LiteralPath (Join-Path $script:LedgerState 'captain-telegram.routed') | Should -BeTrue
        InModuleScope Firstmate -Parameters @{ HomePath = $script:LedgerHome } {
            param($HomePath)
            $context = Get-FmWakeContext -FmHome $HomePath -State (Join-Path $HomePath 'state')
            $changes = @(Get-FmWatchSignalChanges -Context $context)
            # The message itself is news. Where it was routed is bookkeeping written
            # in the same moment, and a second notification about it would be the
            # same message arriving twice.
            @($changes | Where-Object { $_.Path -like '*captain-telegram.inbox' }).Count | Should -Be 1
            @($changes | Where-Object { $_.Path -like '*captain-telegram.routed' }).Count | Should -Be 0
        }
    }

    It 'reads back nothing at all from a home that has never routed a message' {
        $bare = New-ConfiguredHome
        $routes = Get-FmTelegramRoute -FirstmateHome $bare
        @($routes).Count | Should -Be 0
    }

    # The message is already in the inbox by the time routing runs, so a routing
    # that cannot be written has to degrade to "not routed". Letting it fail the
    # whole receive would tell the poller to count a recorded message as ignored and
    # answer the captain with nothing at all.
    It 'keeps a recorded message when the routing itself cannot be written down' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:LedgerHome } {
            param($HomePath)
            Mock Add-FmTelegramRouteRecord { throw 'the record could not be written' }
            $handled = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $HomePath
            $handled.Accepted | Should -BeTrue
            $handled.Recorded | Should -BeTrue
            $handled.Reason | Should -Be 'recorded'
            # Said, not passed off as routed - a RouteId nothing can be looked up by
            # would be worse than none.
            $handled.RouteReason | Should -Be 'unavailable'
            $handled.RoutedTo | Should -BeNullOrEmpty
            $handled.RouteId | Should -BeNullOrEmpty
            # And the captain still gets an answer rather than silence.
            $handled.Reply | Should -Not -BeNullOrEmpty
        }
        (Get-InboxLine -HomePath $script:LedgerHome).Count | Should -Be 1
    }

    # A piece of work can be cleaned up between the captain asking about it and the
    # answer being looked for. That has to read as "still nothing to say", not as an
    # error and not as a false answer.
    It 'says nothing has come back when the work''s record is gone entirely' {
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        Remove-Item -LiteralPath (Join-Path $script:LedgerState 'fix-signin.status') -Force
        $routes = Get-FmTelegramRoute -FirstmateHome $script:LedgerHome
        @($routes).Count | Should -Be 1
        $routes[0].Reported | Should -BeFalse
        $routes[0].Answer | Should -BeNullOrEmpty
        # And the label falls back to the project rather than to an identifier.
        $routes[0].Label | Should -Be 'the work on acme-web'
    }

    It 'survives a garbled line in the record rather than losing every good one' {
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:LedgerHome
        $path = Join-Path $script:LedgerState 'captain-telegram.routed'
        $kept = [System.IO.File]::ReadAllText($path)
        [System.IO.File]::WriteAllText($path, "not a record at all`n$kept")
        $routes = Get-FmTelegramRoute -FirstmateHome $script:LedgerHome
        @($routes).Count | Should -Be 1
        $routes[0].Task | Should -Be 'fix-signin'
    }
}

Describe 'carrying the worker''s answer back' {
    BeforeEach {
        $script:AnswerBackHome = New-ConfiguredHome
        $script:AnswerBackState = Join-Path $script:AnswerBackHome 'state'
        $null = Add-LiveWork -HomePath $script:AnswerBackHome -Task 'fix-signin' -Project 'acme-web' `
            -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $script:AnswerBackHome -Task 'cart-speed' -Project 'acme-shop' `
            -Note '[20%] profiling the cart page'
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $script:AnswerBackHome
    }

    It 'says nothing at all while the worker has not reported since' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'nothing must be sent before there is an answer' }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 0
            $carried.Waiting | Should -Be 1
            $carried.Reason | Should -Be 'nothing'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    It 'matches the answer to the message that asked for it, and quotes the question' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again for accounts made before the migration' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 1
            $carried.Reason | Should -Be 'sent'
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $Url -like '*/sendMessage' -and
                $text -match 'you asked: how is the sign-in fix going' -and
                $text -match 'Sign-in works again for accounts made before the migration'
            }
        }
    }

    It 'does not answer a question with another worker''s report' {
        # The cart worker speaks; the captain asked about sign-in.
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'cart-speed' -State 'working' `
            -Note '[50%] the cart query was the slow part' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'an unrelated worker must not answer this' }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 0
            $carried.Waiting | Should -Be 1
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
    }

    # The whole point of the record: a reply arriving with no memory of what it
    # answers is how a captain gets told the wrong thing, confidently.
    It 'answers each of two questions with its own worker''s report' {
        $null = Receive-FmTelegramCommand -Text 'and how is the cart page coming along' `
            -FirstmateHome $script:AnswerBackHome
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'cart-speed' -State 'working' `
            -Note '[50%] the cart query was the slow part' -Confirm:$false

        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 2
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text -match 'how is the sign-in fix going' -and $text -match 'Sign-in works again'
            }
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text -match 'how is the cart page coming along' -and $text -match 'cart query was the slow part'
            }
        }
    }

    # AGENTS.md section 9 binds harder on a phone than anywhere else, and the
    # easiest possible mistake here is forwarding the status line that is right
    # there and already written.
    It 'lets no worker''s raw words reach the captain' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'done' `
            -Key 'api-shape' -Note ('[95%] sign-in restored, landed in branch fm/fix-signin, ' +
            'see docs/telegram-windows.md and state/fix-signin.status') -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $null = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text -notmatch 'done:' -and $text -notmatch '95%' -and $text -notmatch 'key=' -and
                $text -notmatch 'fm/fix-signin' -and $text -notmatch 'docs/' -and
                $text -notmatch 'state/' -and $text -notmatch '\.md|\.status' -and
                # And it still says what happened, which is the whole point of
                # stripping rather than refusing.
                $text -match 'Sign-in restored'
            }
        }
    }

    # The stripper is the ONE owner of section 9's translation, vocabulary table
    # included, and this path reuses it rather than carrying a second copy. So the
    # words that table exists to replace have to arrive replaced, and this test is
    # what would notice if the carry-back ever grew a translator of its own.
    It 'gets the shared vocabulary, not a second copy of it' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note 'crewmate wedged in its worktree, the harness went stale after teardown' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $null = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $text = ($BodyJson | ConvertFrom-Json).text
                $text -notmatch 'crewmate' -and $text -notmatch 'worktree' -and
                $text -notmatch 'harness' -and $text -notmatch 'teardown' -and $text -notmatch 'stale' -and
                $text -match 'worker' -and $text -match 'local copy' -and $text -match 'cleanup'
            }
        }
    }

    It 'marks a carried answer answered, so the captain is not told twice' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            (Send-FmTelegramWorkerReply -FirstmateHome $HomePath).Sent | Should -Be 1
            $again = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $again.Sent | Should -Be 0
            $again.Waiting | Should -Be 0
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter { $Url -match 'sendMessage' }
        }
        # The closure is a second record carrying the same id, not a rewrite: the
        # ledger stays a history rather than becoming a current value.
        $lines = Get-RouteLine -HomePath $script:AnswerBackHome
        $lines.Count | Should -Be 2
        ($lines[1] -split "`t")[1] | Should -Be 'answered'
        ($lines[1] -split "`t")[2] | Should -Be (($lines[0] -split "`t")[2])
    }

    It 'leaves the question open when the send did not get through' {
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $false; Reason = 'timeout'; ErrorCode = 0; Description = ''; Result = $null }
            }
            Mock Start-Sleep { }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 0
            $carried.Failed | Should -Be 1
            $carried.Reason | Should -Be 'unavailable'
        }
        # Still open, so the next call carries it rather than losing it silently.
        (Get-RouteLine -HomePath $script:AnswerBackHome).Count | Should -Be 1
        $routes = Get-FmTelegramRoute -FirstmateHome $script:AnswerBackHome
        @($routes).Count | Should -Be 1
        $routes[0].Reported | Should -BeTrue
    }

    It 'says so, and carries nothing, when the channel is not set up' {
        $bare = New-TelegramHome
        $null = Add-LiveWork -HomePath $bare -Task 'fix-signin' -Note '[40%] restoring sign-in'
        # Recorded with the channel off is still a real routing decision; only the
        # sending half is switched off.
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $bare
        $null = Add-FmTaskStatus -StateDir (Join-Path $bare 'state') -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $bare } {
            param($HomePath)
            Mock Invoke-FmTelegramApi { throw 'the network must not be reached when the channel is off' }
            $carried = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            $carried.Sent | Should -Be 0
            $carried.Reason | Should -Be 'off'
            Should -Invoke Invoke-FmTelegramApi -Times 0 -Exactly
        }
        (Get-RouteLine -HomePath $bare).Count | Should -Be 1
    }

    It 'says where things stand now rather than implying one report was the whole of it' {
        foreach ($note in @('[50%] found the cause', '[60%] fixing it', '[70%] sign-in works again')) {
            $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
                -Note $note -Confirm:$false
        }
        $routes = Get-FmTelegramRoute -FirstmateHome $script:AnswerBackHome
        $routes[0].Reports | Should -Be 3
        # The current word is the answer; the superseded ones are counted, not sent.
        $routes[0].Answer | Should -Match 'Sign-in works again'
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $null = Send-FmTelegramWorkerReply -FirstmateHome $HomePath
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                ($BodyJson | ConvertFrom-Json).text -match 'moved on 3 times since you asked'
            }
        }
    }

    It 'carries back only the work it was asked for' {
        $null = Receive-FmTelegramCommand -Text 'and how is the cart page coming along' `
            -FirstmateHome $script:AnswerBackHome
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false
        $null = Add-FmTaskStatus -StateDir $script:AnswerBackState -TaskId 'cart-speed' -State 'working' `
            -Note '[50%] the cart query was the slow part' -Confirm:$false
        InModuleScope Firstmate -Parameters @{ HomePath = $script:AnswerBackHome } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            (Send-FmTelegramWorkerReply -FirstmateHome $HomePath -Task 'cart-speed').Sent | Should -Be 1
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                ($BodyJson | ConvertFrom-Json).text -match 'cart query was the slow part'
            }
        }
    }
}

Describe 'routing cannot widen a refusal' {
    BeforeEach {
        $script:RefuseHome = New-ConfiguredHome
        $null = Add-LiveWork -HomePath $script:RefuseHome -Task 'fix-signin' -Project 'acme-web' `
            -Note '[40%] restoring sign-in'
    }

    # The refusal returns before routing runs at all, so a message that is refused
    # is refused whoever it was about.
    It 'refuses a message that plainly concerns live work, and routes nothing' -ForEach @(
        @{ Text = 'merge the sign-in fix' }
        @{ Text = 'discard the sign-in work' }
        @{ Text = 'delete the sign-in branch' }
        @{ Text = 'tear down the sign-in fix' }
        @{ Text = 'show me the token for the sign-in work' }
    ) {
        $home_ = New-ConfiguredHome
        $null = Add-LiveWork -HomePath $home_ -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $handled = Receive-FmTelegramCommand -Text $Text -FirstmateHome $home_
        $handled.Reason | Should -Be 'refused'
        $handled.Accepted | Should -BeFalse
        $handled.RoutedTo | Should -BeNullOrEmpty
        $handled.RouteReason | Should -Be 'none'
        Get-RouteLine -HomePath $home_ | Should -BeNullOrEmpty
        Get-InboxLine -HomePath $home_ | Should -BeNullOrEmpty
    }

    It 'still refuses when the only live work is the one the message names' {
        $handled = Receive-FmTelegramCommand -Text 'land the sign-in fix' -FirstmateHome $script:RefuseHome
        $handled.Reason | Should -Be 'refused'
        $handled.Reply | Should -Match 'land that work'
        Get-RouteLine -HomePath $script:RefuseHome | Should -BeNullOrEmpty
    }

    It 'routes nothing for a steer a narrowed channel refuses' {
        $narrowed = New-ConfiguredHome -AuthorityLine @('allow-tier=1')
        $null = Add-LiveWork -HomePath $narrowed -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $handled = Receive-FmTelegramCommand -Text 'put the sign-in fix on hold' -FirstmateHome $narrowed
        $handled.Reason | Should -Be 'refused'
        $handled.RoutedTo | Should -BeNullOrEmpty
        Get-RouteLine -HomePath $narrowed | Should -BeNullOrEmpty
    }

    It 'still routes a question a narrowed channel allows' {
        $narrowed = New-ConfiguredHome -AuthorityLine @('allow-tier=1')
        $null = Add-LiveWork -HomePath $narrowed -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $handled = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $narrowed
        $handled.Accepted | Should -BeTrue
        $handled.RoutedTo | Should -Be 'fix-signin'
    }

    It 'refuses a message the poller took, without recording where it would have gone' {
        InModuleScope Firstmate -Parameters @{ HomePath = $script:RefuseHome; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 31
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'merge the sign-in fix'
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
        }
        Get-RouteLine -HomePath $script:RefuseHome | Should -BeNullOrEmpty
    }
}

Describe 'the whole way round, from the phone and back to it' {
    It 'takes a message, routes it, waits for the worker, then answers the captain' {
        $home_ = New-ConfiguredHome
        $state = Join-Path $home_ 'state'
        $null = Add-LiveWork -HomePath $home_ -Task 'fix-signin' -Project 'acme-web' `
            -Note '[40%] restoring sign-in'
        $null = Add-LiveWork -HomePath $home_ -Task 'cart-speed' -Project 'acme-shop' `
            -Note '[20%] profiling the cart page'

        InModuleScope Firstmate -Parameters @{ HomePath = $home_; Captain = $script:CaptainId } {
            param($HomePath, $Captain)
            Mock Invoke-FmTelegramApi {
                if ($Url -match 'getUpdates') {
                    return [pscustomobject]@{
                        Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''
                        Result = @([pscustomobject]@{
                                update_id = 41
                                message   = [pscustomobject]@{
                                    date = (Get-FmUnixTime); text = 'how is the sign-in fix going'
                                    from = [pscustomobject]@{ id = $Captain }
                                }
                            })
                    }
                }
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            $run = Start-FmTelegramPoll -FirstmateHome $HomePath -MaxCycles 1
            $run.Accepted | Should -Be 1
            # It told the captain which work it decided on, by what that work is
            # doing rather than by any identifier.
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $Url -match 'sendMessage' -and
                ($BodyJson | ConvertFrom-Json).text -match 'Restoring sign-in'
            }
        }

        $routes = Get-FmTelegramRoute -FirstmateHome $home_
        @($routes).Count | Should -Be 1
        $routes[0].Task | Should -Be 'fix-signin'
        $routes[0].Reported | Should -BeFalse

        # The worker reports through its own status stream. That is the only signal.
        $null = Add-FmTaskStatus -StateDir $state -TaskId 'fix-signin' -State 'done' `
            -Note 'sign-in works again for accounts made before the migration, ready for review' -Confirm:$false

        InModuleScope Firstmate -Parameters @{ HomePath = $home_ } {
            param($HomePath)
            Mock Invoke-FmTelegramApi {
                [pscustomobject]@{ Ok = $true; Reason = 'ok'; ErrorCode = 0; Description = ''; Result = $null }
            }
            (Send-FmTelegramWorkerReply -FirstmateHome $HomePath).Sent | Should -Be 1
            # Guarded on the URL first, and it has to be: this It also ran the
            # poller, whose getUpdates calls carry no body at all, and a filter that
            # parsed the body before checking would die on the first of them.
            Should -Invoke Invoke-FmTelegramApi -Times 1 -Exactly -ParameterFilter {
                $Url -match 'sendMessage' -and
                ($BodyJson | ConvertFrom-Json).text -match 'you asked: how is the sign-in fix going' -and
                ($BodyJson | ConvertFrom-Json).text -match 'Sign-in works again for accounts' -and
                $BodyJson -notmatch 'done:' -and $BodyJson -notmatch 'fix-signin'
            }
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

    It 'fm-tg-route.ps1 answers -h with its own help' {
        $run = Invoke-TelegramScript -Script $script:RouteScript -FmHome (New-TelegramHome) -CliArgs @('-h')
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'fm-tg-route'
    }

    It 'fm-tg-route.ps1 says plainly that nothing is waiting, rather than printing nothing' {
        $run = Invoke-TelegramScript -Script $script:RouteScript -FmHome (New-ConfiguredHome)
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'no phone message is waiting'
    }

    It 'fm-tg-route.ps1 lists what is outstanding without sending anything' {
        $home_ = New-ConfiguredHome
        $null = Add-LiveWork -HomePath $home_ -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $home_
        $null = Add-FmTaskStatus -StateDir (Join-Path $home_ 'state') -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false

        # The API root points at a dead loopback port, so a send would be visible as
        # a refusal on stderr. Listing must not attempt one at all.
        $run = Invoke-TelegramScript -Script $script:RouteScript -FmHome $home_
        $run.ExitCode | Should -Be 0
        $run.StdOut | Should -Match 'ready\s+fix-signin'
        $run.StdOut | Should -Match 'how is the sign-in fix going'
        $run.StdErr | Should -Not -Match 'not carried back'
        # Still open, because listing is a read.
        (Get-RouteLine -HomePath $home_).Count | Should -Be 1
    }

    It 'fm-tg-route.ps1 -Send says nothing was carried back when the channel is not set up' {
        $bare = New-TelegramHome
        $null = Add-LiveWork -HomePath $bare -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $bare
        $null = Add-FmTaskStatus -StateDir (Join-Path $bare 'state') -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false

        $run = Invoke-TelegramScript -Script $script:RouteScript -FmHome $bare -CliArgs @('-Send')
        $run.ExitCode | Should -Be 0
        $run.StdErr | Should -Match 'not set up'
    }

    It 'fm-tg-route.ps1 never prints the token, even when the send fails' {
        $home_ = New-ConfiguredHome
        $null = Add-LiveWork -HomePath $home_ -Task 'fix-signin' -Note '[40%] restoring sign-in'
        $null = Receive-FmTelegramCommand -Text 'how is the sign-in fix going' -FirstmateHome $home_
        $null = Add-FmTaskStatus -StateDir (Join-Path $home_ 'state') -TaskId 'fix-signin' -State 'working' `
            -Note '[70%] sign-in works again' -Confirm:$false

        $run = Invoke-TelegramScript -Script $script:RouteScript -FmHome $home_ `
            -CliArgs @('-Send', '-TimeoutSeconds', '2', '-Retries', '0')
        $run.ExitCode | Should -Be 0
        $everything = $run.StdOut + $run.StdErr
        $everything | Should -Not -Match ([regex]::Escape($script:FakeToken))
        $everything | Should -Not -Match ([regex]::Escape($script:FakeTokenSecret))
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $home_ 'state') -File -Recurse -Force)) {
            [System.IO.File]::ReadAllText($file.FullName) |
                Should -Not -Match ([regex]::Escape($script:FakeTokenSecret))
        }
    }
}
