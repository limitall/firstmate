#requires -Version 7.0
# Pester tests for the sign-in readiness check: the question start.ps1 asks
# before the browser takes the captain away from the terminal.
#
# NOTHING HERE SIGNS ANYTHING IN OR OUT. `claude auth login` is never run and
# `claude auth logout` is never run, on this machine or any other: every case
# that reaches a CLI reaches a stub .cmd built in TestDrive and named through
# the -CommandName parameter, which exists for exactly this reason. The real
# credentials on the seat running this suite are neither read nor written, and a
# developer who is signed in is still signed in afterwards.
#
# NOTHING HERE OPENS A MICROPHONE OR MAKES A SOUND either. This area touches
# neither, and no case starts a bridge, a browser or a session.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'A Pester fixture that writes a stub CLI into TestDrive and puts it on PATH. -WhatIf on it would leave every case below asking a command that was never written.')]
param()

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ModuleRoot = Join-Path $script:RepoRoot 'module' 'Firstmate'
    . (Join-Path $script:ModuleRoot 'Public' 'FmSignIn.ps1')

    # A stand-in for the Claude CLI. It answers `auth status` from a marker file
    # so that `auth login` can be observed to change the machine's state without
    # anything actually signing in anywhere.
    function New-StubCli {
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Body
        )
        $null = New-Item -ItemType Directory -Path $Directory -Force
        $path = Join-Path $Directory "$Name.cmd"
        [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
        # Get-Command resolves a .cmd as an Application exactly as it resolves an
        # .exe, so the directory going on PATH is all the wiring the check needs.
        if (($env:PATH -split ';') -notcontains $Directory) {
            $env:PATH = $Directory + ';' + $env:PATH
        }
        $path
    }

    $script:PathAtStart = $env:PATH
}

AfterAll {
    $env:PATH = $script:PathAtStart
}

Describe 'reading what the CLI said about signing in' {
    It 'reads a signed-in machine, and carries the method and the account back' {
        $json = '{"loggedIn":true,"authMethod":"claude.ai","email":"captain@example.com"}'
        $reading = ConvertFrom-FmSignInStatus -Output $json -ExitCode 0
        $reading.SignedIn | Should -BeTrue
        $reading.Known | Should -BeTrue
        $reading.Method | Should -Be 'claude.ai'
        $reading.Account | Should -Be 'captain@example.com'
    }

    It 'reads a signed-out machine, which is the shape the captain actually hit' {
        # Measured 2026-09-08 with CLAUDE_CONFIG_DIR pointed at an empty
        # directory: this is the body, and exit 1 is the code.
        $json = '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
        $reading = ConvertFrom-FmSignInStatus -Output $json -ExitCode 1
        $reading.SignedIn | Should -BeFalse
        $reading.Known | Should -BeTrue -Because 'a definite no is a verdict, and it is the one that stops a start'
    }

    It 'says it cannot tell, rather than saying signed out, for output it does not understand' -ForEach @(
        @{ Case = 'empty'; Text = '' }
        @{ Case = 'whitespace'; Text = "  `n " }
        @{ Case = 'not JSON at all'; Text = 'claude: command failed' }
        @{ Case = 'an opening brace and nothing else'; Text = 'oh dear {' }
        @{ Case = 'malformed JSON'; Text = '{"loggedIn":' }
        @{ Case = 'JSON with no loggedIn field'; Text = '{"authMethod":"claude.ai"}' }
    ) {
        $reading = ConvertFrom-FmSignInStatus -Output $Text -ExitCode 1
        $reading.Known | Should -BeFalse -Because "$Case is not a signed-out machine"
        $reading.SignedIn | Should -BeFalse
    }

    It 'accepts a null output without throwing, because a caller may have nothing to hand it' {
        { ConvertFrom-FmSignInStatus -Output $null -ExitCode 0 } | Should -Not -Throw
        (ConvertFrom-FmSignInStatus -Output $null -ExitCode 0).Known | Should -BeFalse
    }

    It 'finds the JSON body when the CLI printed a notice beside it' {
        # A version nudge on stdout must not turn a signed-in machine into an
        # unreadable one, which would stop a start that had nothing wrong with it.
        $text = "A new version of Claude Code is available.`n{`"loggedIn`":true,`"authMethod`":`"claude.ai`"}`nBye."
        $reading = ConvertFrom-FmSignInStatus -Output $text -ExitCode 0
        $reading.Known | Should -BeTrue
        $reading.SignedIn | Should -BeTrue
    }

    It 'refuses to rule when the body and the exit code disagree' {
        # loggedIn true beside a failure is a contradiction this cannot resolve,
        # and starting a session on the optimistic half of it is how the captain
        # ends up at a screen that cannot answer.
        $reading = ConvertFrom-FmSignInStatus -Output '{"loggedIn":true}' -ExitCode 1
        $reading.Known | Should -BeFalse
    }

    It 'does not need the exit code to agree in the other direction' {
        # Signed out with exit 0 is still signed out: the body is authoritative,
        # and this direction is safe because it only ever stops a start.
        $reading = ConvertFrom-FmSignInStatus -Output '{"loggedIn":false}' -ExitCode 0
        $reading.Known | Should -BeTrue
        $reading.SignedIn | Should -BeFalse
    }
}

Describe 'asking the CLI, without a network and without a hang' {
    It 'reports a signed-in machine' {
        $stub = New-StubCli -Directory (Join-Path $TestDrive 'in') -Name 'fm-stub-in' -Body @"
@echo off
echo {"loggedIn":true,"authMethod":"claude.ai","email":"c@example.com"}
exit /b 0
"@
        $stub | Should -Exist
        $reading = Get-FmSignInStatus -CommandName 'fm-stub-in'
        $reading.SignedIn | Should -BeTrue
        $reading.Known | Should -BeTrue
    }

    It 'reports a signed-out machine' {
        $null = New-StubCli -Directory (Join-Path $TestDrive 'out') -Name 'fm-stub-out' -Body @"
@echo off
echo {"loggedIn":false,"authMethod":"none"}
exit /b 1
"@
        $reading = Get-FmSignInStatus -CommandName 'fm-stub-out'
        $reading.SignedIn | Should -BeFalse
        $reading.Known | Should -BeTrue
    }

    It 'says it cannot tell when there is no CLI at all, and names what it looked for' {
        $reading = Get-FmSignInStatus -CommandName 'fm-stub-that-does-not-exist'
        $reading.Known | Should -BeFalse
        $reading.SignedIn | Should -BeFalse
        $reading.Detail | Should -BeLike '*fm-stub-that-does-not-exist*'
    }

    It 'gives up on a CLI that never answers, instead of hanging the start' {
        # THE POINT OF THIS CASE. A machine that is offline or slow must get a
        # start, not a frozen terminal. The stub blocks for far longer than the
        # bound, and the bound is what has to win.
        $null = New-StubCli -Directory (Join-Path $TestDrive 'hang') -Name 'fm-stub-hang' -Body @"
@echo off
ping -n 30 127.0.0.1 >nul
echo {"loggedIn":true}
exit /b 0
"@
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $reading = Get-FmSignInStatus -CommandName 'fm-stub-hang' -TimeoutSeconds 2
        $sw.Stop()

        $reading.Known | Should -BeFalse -Because 'a check that timed out has not proved anything'
        $reading.Detail | Should -BeLike '*in time*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20 -Because 'the bound has to be the thing that ends it'
    }

    It 'does not deadlock on a CLI that prints more than a pipe buffer holds' {
        # Waiting for exit and reading afterwards deadlocks here, because the
        # child blocks writing into a full pipe while the parent blocks waiting
        # for the child. The filler carries no braces, so the JSON below is
        # still the only object in the stream.
        $bigDir = Join-Path $TestDrive 'big'
        $null = New-Item -ItemType Directory -Path $bigDir -Force
        $filler = Join-Path $bigDir 'filler.txt'
        [System.IO.File]::WriteAllText($filler, ('x' * 200000))
        $null = New-StubCli -Directory $bigDir -Name 'fm-stub-big' -Body @"
@echo off
type "$filler"
echo {"loggedIn":true,"authMethod":"claude.ai"}
exit /b 0
"@
        $reading = Get-FmSignInStatus -CommandName 'fm-stub-big' -TimeoutSeconds 30
        $reading.Known | Should -BeTrue
        $reading.SignedIn | Should -BeTrue
    }

    It 'reads it as a verdict it cannot reach when the CLI prints nothing at all' {
        $null = New-StubCli -Directory (Join-Path $TestDrive 'mute') -Name 'fm-stub-mute' -Body @"
@echo off
exit /b 1
"@
        (Get-FmSignInStatus -CommandName 'fm-stub-mute').Known | Should -BeFalse
    }
}

Describe 'deciding whether the screen may open' {
    BeforeAll {
        $script:SignedIn = [pscustomobject]@{ SignedIn = $true; Known = $true; Method = 'claude.ai'; Account = 'c@example.com'; Detail = '' }
        $script:SignedOut = [pscustomobject]@{ SignedIn = $false; Known = $true; Method = 'none'; Account = ''; Detail = '' }
        $script:Unknown = [pscustomobject]@{ SignedIn = $false; Known = $false; Method = ''; Account = ''; Detail = 'no claude on PATH' }
    }

    It 'is SILENT on a machine that is signed in' {
        # A start that prints a paragraph of green ticks before every session
        # teaches the captain to read past it, which is how the one line that
        # mattered gets missed.
        $decision = Get-FmSignInDecision -Status $script:SignedIn -CaptainPresent
        $decision.Proceed | Should -BeTrue
        $decision.SignIn | Should -BeFalse
        @($decision.Lines).Count | Should -Be 0
    }

    It 'is silent and starts anyway when it could not reach a verdict' {
        # A readiness check must not invent its own new way to be unable to
        # start. Only a definite signed-out answer stops anything.
        $decision = Get-FmSignInDecision -Status $script:Unknown -CaptainPresent
        $decision.Proceed | Should -BeTrue
        @($decision.Lines).Count | Should -Be 0
    }

    It 'is silent and starts anyway when handed nothing, or something of the wrong shape' -ForEach @(
        @{ Case = 'null'; Status = $null }
        @{ Case = 'an object from somewhere else'; Status = [pscustomobject]@{ Something = 'else' } }
    ) {
        $decision = Get-FmSignInDecision -Status $Status -CaptainPresent
        $decision.Proceed | Should -BeTrue -Because "$Case must not stop a captain"
        @($decision.Lines).Count | Should -Be 0
    }

    It 'asks a captain who is standing there, rather than opening a screen that cannot answer' {
        $decision = Get-FmSignInDecision -Status $script:SignedOut -CaptainPresent
        $decision.Proceed | Should -BeFalse
        $decision.SignIn | Should -BeTrue -Because 'the unanswered state is the one that means "ask"'
    }

    It 'carries the explanation to the captain it is about to ask, rather than leaving the caller to write its own' {
        # The prompt and the nobody-home refusal describe one machine, so they
        # say one thing. A caller printing its own version is the second copy
        # that drifts the first time either is reworded.
        $asking = @((Get-FmSignInDecision -Status $script:SignedOut -CaptainPresent).Lines)
        $telling = @((Get-FmSignInDecision -Status $script:SignedOut).Lines)
        $asking | Should -Not -BeNullOrEmpty -Because 'a bare prompt does not say why it is asking'
        ($asking -join ' ') | Should -Match 'not signed in'
        # The refusal adds the command; the sentences that explain are the same.
        foreach ($line in $asking) {
            $telling | Should -Contain $line -Because 'both paths explain the machine in the same words'
        }
    }

    It 'treats pressing Enter as yes, because this finishes what they already asked for' -ForEach @(
        @{ Answer = '' }, @{ Answer = ' ' }, @{ Answer = 'y' }, @{ Answer = 'Y' }, @{ Answer = 'yes' }, @{ Answer = ' yes ' }
    ) {
        (Get-FmSignInDecision -Status $script:SignedOut -CaptainPresent -Answer $Answer).SignIn |
            Should -BeTrue -Because "'$Answer' is not a refusal"
    }

    It 'takes no for an answer, and still leaves the way in' -ForEach @(
        @{ Answer = 'n' }, @{ Answer = 'N' }, @{ Answer = 'no' }, @{ Answer = ' no ' }
    ) {
        $decision = Get-FmSignInDecision -Status $script:SignedOut -CaptainPresent -Answer $Answer
        $decision.SignIn | Should -BeFalse
        $decision.Proceed | Should -BeFalse -Because 'a screen that cannot answer is not a start'
        ($decision.Lines -join ' ') | Should -Match 'claude auth login'
    }

    It 'never prompts when nobody is at the keyboard, and names the command instead' {
        # A redirected stdin is a script, a test or a scheduled run. Read-Host
        # there is a hang, not a question.
        $decision = Get-FmSignInDecision -Status $script:SignedOut
        $decision.SignIn | Should -BeFalse -Because 'there is nobody to answer'
        $decision.Proceed | Should -BeFalse
        ($decision.Lines -join ' ') | Should -Match 'claude auth login'
    }

    It 'says what is wrong before it says what to type' {
        $lines = @((Get-FmSignInDecision -Status $script:SignedOut).Lines) | Where-Object { $_.Trim() }
        $lines[0] | Should -Match 'not signed in'
        ($lines -join ' ') | Should -Not -Match '/login' -Because 'the captain cannot type a slash command at a terminal'
    }
}

Describe 'handing the terminal to the CLI to sign in' {
    It 'runs nothing under -WhatIf' {
        $marker = Join-Path $TestDrive 'whatif-marker.txt'
        $env:FM_STUB_STATE = $marker
        $null = New-StubCli -Directory (Join-Path $TestDrive 'whatif') -Name 'fm-stub-whatif' -Body @"
@echo off
if "%2"=="login" (
  echo done> "%FM_STUB_STATE%"
  exit /b 0
)
echo {"loggedIn":false}
exit /b 1
"@
        $result = Invoke-FmSignIn -CommandName 'fm-stub-whatif' -WhatIf
        $marker | Should -Not -Exist -Because '-WhatIf must not sign anybody in'
        $result.Known | Should -BeFalse
        Remove-Item Env:FM_STUB_STATE -ErrorAction SilentlyContinue
    }

    It 'reports the state the sign-in actually left behind, rather than that it ran' {
        $marker = Join-Path $TestDrive 'login-marker.txt'
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        $env:FM_STUB_STATE = $marker
        $null = New-StubCli -Directory (Join-Path $TestDrive 'login') -Name 'fm-stub-login' -Body @"
@echo off
if "%2"=="login" (
  echo done> "%FM_STUB_STATE%"
  exit /b 0
)
if exist "%FM_STUB_STATE%" (
  echo {"loggedIn":true,"authMethod":"claude.ai","email":"c@example.com"}
  exit /b 0
)
echo {"loggedIn":false,"authMethod":"none"}
exit /b 1
"@
        (Get-FmSignInStatus -CommandName 'fm-stub-login').SignedIn | Should -BeFalse

        $after = Invoke-FmSignIn -CommandName 'fm-stub-login' -Confirm:$false
        $after.SignedIn | Should -BeTrue
        $after.Known | Should -BeTrue
        Remove-Item Env:FM_STUB_STATE -ErrorAction SilentlyContinue
    }

    It 'reports the machine as it is when the captain abandons the sign-in half way' {
        # THE CASE THAT MATTERS. A sign-in that was started and not finished
        # leaves the machine exactly as it was, and a start that assumed it
        # worked lands the captain back at a screen that cannot answer.
        $env:FM_STUB_STATE = Join-Path $TestDrive 'never-written.txt'
        $null = New-StubCli -Directory (Join-Path $TestDrive 'abandon') -Name 'fm-stub-abandon' -Body @"
@echo off
if "%2"=="login" exit /b 1
echo {"loggedIn":false,"authMethod":"none"}
exit /b 1
"@
        $after = Invoke-FmSignIn -CommandName 'fm-stub-abandon' -Confirm:$false
        $after.SignedIn | Should -BeFalse
        $after.Known | Should -BeTrue

        # And the decision built on it refuses the start rather than opening a
        # mute screen, without asking a second time.
        $decision = Get-FmSignInDecision -Status $after -CaptainPresent -Answer 'n'
        $decision.Proceed | Should -BeFalse
        $decision.SignIn | Should -BeFalse
        Remove-Item Env:FM_STUB_STATE -ErrorAction SilentlyContinue
    }

    It 'does not throw when there is no CLI to hand the terminal to' {
        { Invoke-FmSignIn -CommandName 'fm-stub-absent-entirely' -Confirm:$false } | Should -Not -Throw
        (Invoke-FmSignIn -CommandName 'fm-stub-absent-entirely' -Confirm:$false).Known | Should -BeFalse
    }
}
