#requires -Version 7.0
Set-StrictMode -Version Latest

# The browser is the surface the captain actually reads, and until this file
# existed it was the only major area with no tests of its own - 42 test files,
# none for the bridge. That is not a coincidence: the jargon leak these tests
# now pin was found by hand, on screen, months after it shipped, because no
# check ever looked.
#
# SCOPE, STATED HONESTLY. This covers the translation seam, the vocabulary
# table, the reading the assistant answers from, the repetition guard, and the
# two speech-engine seams the fast dictation path is built on.
# The HTTP surface - the token guard, the Origin check, the turn resync - is
# proven by hand against a live bridge and is NOT covered here; those need a
# running listener and a live engine. Neither is the page's own layout: it is
# proven in a real browser at several window sizes and recorded in
# docs/windows-e2e-evidence.md, because a test that reads the stylesheet would
# assert source bytes rather than behaviour. Those gaps are real and are
# recorded rather than papered over.
#
# WHAT A TEST HERE CANNOT PROVE, and section 33 of that same evidence file says
# so plainly: that the panel and the reply agree is a property of a live screen
# with real work on it, not of a function. These tests pin the pieces - the
# reading carries what the panel shows, the translator leaves no machinery
# behind, a repeat is said once - and the browser run is what proves the screen.
#
# ONE THING IS DELIBERATELY NOT TESTED: a real capture. Invoke-FmSpeechCapture
# with a live engine opens the captain's microphone, and a suite that does that
# on every run is a suite nobody should have to trust. Its REFUSALS are tested
# here, which is where the cost lives - the refusal is what keeps it from
# launching a second engine and loading another copy of a 1.7B model.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    # PUT BACK IN AN AfterAll, because this is process-global and every test
    # file that runs after this one inherits it. A child pwsh started by a
    # later suite then AUTOLOADS Firstmate from here, which is how a fixture
    # that had deliberately stubbed the module out ended up running the real
    # installer and hanging the whole suite - docs/windows-e2e-evidence.md
    # section 56.
    $script:SavedModulePath = $env:PSModulePath
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force
    . (Join-Path $PSScriptRoot 'FmUnstartable.TestHelpers.ps1')
}

AfterAll {
    # Restores what the file-level BeforeAll prepended. Placed here, ahead of
    # every Describe, because that is where a top-level AfterAll is actually
    # registered against this file's own container - appended at the end of the
    # file it does not run, and the leak survives. Measured.
    $env:PSModulePath = $script:SavedModulePath
}

Describe 'ConvertTo-FmBridgePlainText' {

    # AGENTS.md section 9 forbids these reaching the captain. The list is the
    # contract; a word added there belongs here the same day.
    #
    # THE SECOND GROUP IS WHAT A SESSION SAYS ABOUT ITSELF, and it is here
    # because all of it reached the captain in one reply: a process number, the
    # controls, "read-only", three internal verbs, and their own local copy
    # having unsaved edits.
    #
    # MATCHED ON WORD BOUNDARIES, not as substrings. "blocker" contains "lock"
    # and is a captain noun section 9 explicitly keeps, so a substring test would
    # forbid the plain English the same section requires.
    BeforeAll {
        $script:Banned = @(
            'worktree', 'checkout', 'crewmate', 'secondmate', 'teardown', 'harness',
            'herdr', 'treehouse', 'orca', 'cmux', 'watcher', 'heartbeat', 'stale',
            'needs-decision', 'ask-user', 'yolo', 'no-mistakes', 'local-only',
            'direct-PR', 'wedged', 'backend', 'adapter', 'fail-closed', 'fails closed',
            'lock', 'locks', 'read-only', 'pid', 'process id', 'uncommitted',
            'dispatch', 'dispatched', 'dispatching', 'steer', 'steering',
            'merge', 'merged', 'merging'
        )
    }

    It 'leaves nothing from the forbidden list on screen' -ForEach @(
        @{ Line = 'done: PR ready in worktree fm/tg-build' }
        @{ Line = 'blocked: crewmate wedged, teardown refused' }
        @{ Line = 'stale: watcher saw no heartbeat, harness=claude backend=herdr' }
        @{ Line = 'working: [40%] spawned crewmate in task worktree, mode=local-only yolo=on' }
        @{ Line = 'done: merged to local-main after no-mistakes passed' }
        @{ Line = 'failed: brief rejected, primary checkout detected' }
        @{ Line = 'paused: waiting on treehouse lease, adapter=herdr' }
        @{ Line = 'done: secondmate torn down, worktree discarded' }
    ) {
        $out = ConvertTo-FmBridgePlainText -Text $Line
        foreach ($word in $script:Banned) {
            $out | Should -Not -Match ('\b' + [regex]::Escape($word) + '\b') -Because "section 9 forbids '$word' reaching the captain, and '$Line' produced '$out'"
        }
    }

    # Stripping the label was never the hard half. This is the exact line whose
    # output - "PR ready in worktree" - proved that removing `done:` and the
    # branch name still left three quarters of the problem on screen.
    It 'translates the vocabulary, not only the labels' {
        ConvertTo-FmBridgePlainText -Text 'done: PR ready in worktree fm/tg-build' |
            Should -Be 'PR ready in local copy'
    }

    It 'keeps the sentence the worker wrote, rather than rewriting it' {
        ConvertTo-FmBridgePlainText -Text 'blocked: crewmate wedged, teardown refused' |
            Should -Be 'Worker stuck, cleanup refused'
    }

    # A panel that says a worker has STOPPED when it has merely gone quiet is a
    # false alarm the captain gets out of a chair for. Section 9 permits either
    # reading; the mild one is the correct default for an automatic rewrite.
    #
    # Note the line below puts `stale` MID-SENTENCE on purpose. As a prefix it is
    # stripped outright and never reaches the table at all, so a test written
    # against `stale: ...` proves nothing about the reading chosen - it passes
    # whatever the table says.
    It 'takes the mild reading of a worker that has gone quiet' {
        $out = ConvertTo-FmBridgePlainText -Text 'blocked: the worker looks stale to me'
        $out | Should -Not -Match 'stale'
        $out | Should -Not -Match 'stopped responding'
        $out | Should -Match 'quiet'
    }

    # Section 9 requires the full https:// URL of a PR in every mention, and on a
    # phone a mangled link is the one thing on screen the captain needed to tap.
    It 'never damages a link' -ForEach @(
        @{ Line = 'done: PR ready https://github.com/limitall/firstmate/pull/12'
            Url  = 'https://github.com/limitall/firstmate/pull/12'
        }
        @{ Line = 'done: see https://github.com/o/r/pull/3 in worktree fm/x'
            Url  = 'https://github.com/o/r/pull/3'
        }
    ) {
        (ConvertTo-FmBridgePlainText -Text $Line) | Should -BeLike "*$Url*"
    }

    It 'drops the machinery pairs whole' {
        $out = ConvertTo-FmBridgePlainText -Text 'working: harness=claude backend=herdr model=opus building'
        $out | Should -Not -Match '='
        $out | Should -Match 'building'
    }

    It 'survives an empty or blank line without inventing text' -ForEach @(
        @{ Line = '' }, @{ Line = '   ' }, @{ Line = "`t" }
    ) {
        ConvertTo-FmBridgePlainText -Text $Line | Should -Be ''
    }

    # A translation that eats the note leaves a panel with a state and no reason,
    # which is worse than the jargon: the captain can ask what a word meant.
    It 'never empties a line that carried a real note' -ForEach @(
        @{ Line = 'done: the sign-in fix is ready for review' }
        @{ Line = 'blocked: the payment provider is rejecting test cards' }
        @{ Line = 'working: [60%] reproduced the crash on the settings page' }
    ) {
        (ConvertTo-FmBridgePlainText -Text $Line).Length | Should -BeGreaterThan 10
    }
}

Describe 'Get-FmBridgeHouseWork' {

    It 'names what is running in the captain nouns, never a script' {
        foreach ($row in (Get-FmBridgeHouseWork)) {
            $row.Name | Should -Not -Match 'fm-|\.ps1|pwsh|Pester'
            $row.Name | Should -Not -BeNullOrEmpty
            $row.Detail | Should -Not -BeNullOrEmpty
        }
    }

    # THE REGRESSION THIS EXISTS FOR. The first cut matched any process whose
    # command line CONTAINED the script name, so two processes that merely
    # mentioned `fm-watch.ps1` inside a long `-Command` string were reported to
    # the captain as monitoring that was running. It was not. A panel built to
    # stop the screen misleading them misled them within the hour, so the rule
    # is pinned: only the argument of `-File` is the script actually executing.
    It 'reports only what is running, never what is merely mentioned' {
        $running = @(Get-FmBridgeHouseWork).Name

        $actual = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'")) {
            if ($p.CommandLine -and $p.CommandLine -match '(?i)-File\s+"?([^"]*?\bfm-[a-z0-9-]+)\.ps1"?') {
                $null = $actual.Add((Split-Path $Matches[1] -Leaf))
            }
        }

        # This suite is itself a pwsh process whose command line names test
        # files, which is exactly the shape that produced the false positive.
        if (-not $actual.Contains('fm-watch')) {
            $running | Should -Not -Contain 'Watching for progress' -Because 'nothing is running that script, whatever mentions it'
        }
        if (-not $actual.Contains('fm-doctor')) {
            $running | Should -Not -Contain 'Health check' -Because 'nothing is running that script, whatever mentions it'
        }
    }

    # Reporting "nothing is running" when the truth is "I could not look" is the
    # precise failure this function was written to end, so it must not be the
    # way this fails either.
    It 'says it does not know rather than saying nothing is running' {
        Mock -CommandName Get-CimInstance -MockWith { throw 'no access' } -ModuleName Firstmate
        $out = @(Get-FmBridgeHouseWork)
        $out.Count | Should -Be 1
        $out[0].Detail | Should -Be 'unknown'
        $out[0].Name | Should -Match 'not'
    }
}

Describe 'a kept name, however the screen spells it' {

    # THE PANEL AND THE RECORD SPELL IT DIFFERENTLY, and only one spelling was
    # protected. `-Keep` masked the id literally, so `lock-identity` survived and
    # "Lock identity" - which is exactly what the panel prints, hyphens replaced
    # by spaces - did not: it reached the captain as "the controls identity"
    # beside a row reading LOCK IDENTITY. That is the disagreement this rule
    # exists to end, surviving in the spelling the panel itself uses.
    It 'keeps a name the panel is showing, in every spelling of it' -ForEach @(
        @{ Said = 'Lock identity is at 75%.' }
        @{ Said = 'lock-identity is at 75%.' }
        @{ Said = 'LOCK IDENTITY is at 75%.' }
        @{ Said = 'lock_identity is at 75%.' }
    ) {
        $out = ConvertTo-FmBridgePlainText -Text $Said -Prose -Keep @('lock-identity')
        $out | Should -Not -Match '(?i)controls'
        $out | Should -Match '(?i)lock[-_ ]identity'
    }

    # And the word on its own is still machinery, or the rule would launder every
    # forbidden term that happens to appear inside some job's name.
    It 'still translates the same word when it is not part of a name' {
        ConvertTo-FmBridgePlainText -Text 'The lock is held by another process.' -Prose -Keep @('lock-identity') |
            Should -Not -Match '(?i)\block\b'
    }
}

Describe 'Get-FmBridgeCapacity' {

    # "Week left 79%" and "Session 82%" were typed into the page and had read
    # identically in every screenshot the captain sent, hours apart, while the
    # real numbers moved. The rule they set afterwards is the whole of this
    # Describe: a number either came from something real, or it does not appear.
    It 'never gives a figure when nothing could measure one' {
        Mock -CommandName Get-Command -MockWith { $null } -ModuleName Firstmate `
            -ParameterFilter { $Name -eq 'quota-axi' }
        $c = Get-FmBridgeCapacity -MaxAgeSeconds 0
        $c.Measured | Should -BeFalse
        @($c.Windows).Count | Should -Be 0
        # Not "0%", not a last-known value, not an estimate. The words that say
        # there is nothing to show.
        $c.Detail | Should -Match '(?i)not measured'
    }

    # The listener serves one request at a time, so an unbounded read here would
    # freeze the panel, the reply path and the dictation pickup together. A tool
    # that never returns has to become "not measured", not a hung screen.
    It 'says it did not measure rather than waiting forever' {
        Mock -CommandName Invoke-FmChildProcess -ModuleName Firstmate -MockWith {
            [pscustomobject]@{ Ok = $false; ExitCode = -1; StdOut = ''
                StdErr = 'timed out'; Combined = ''; TimedOut = $true
            }
        }
        $c = Get-FmBridgeCapacity -MaxAgeSeconds 0
        $c.Measured | Should -BeFalse
        @($c.Windows).Count | Should -Be 0
        Should -Invoke Invoke-FmChildProcess -ModuleName Firstmate -Times 1 -Exactly
    }

    It 'says it did not measure rather than guessing when the tool will not run' {
        # A real path that is not a quota tool, so the call fails the way a
        # broken install fails rather than by the command being absent.
        $fake = Join-Path ([IO.Path]::GetTempPath()) ('fm-no-quota-' + [guid]::NewGuid().ToString('N') + '.cmd')
        Set-Content -LiteralPath $fake -Value '@echo not json at all' -NoNewline
        try {
            Mock -CommandName Get-Command -ModuleName Firstmate `
                -ParameterFilter { $Name -eq 'quota-axi' } `
                -MockWith { [pscustomobject]@{ Source = $fake } }
            $c = Get-FmBridgeCapacity -MaxAgeSeconds 0
            $c.Measured | Should -BeFalse
            @($c.Windows).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
        }
    }

    # Whatever it reports has to be usable as a reading: a name the panel can
    # print and a whole number between nought and a hundred.
    It 'reports a figure only in the form a reading takes' {
        foreach ($w in @((Get-FmBridgeCapacity).Windows)) {
            $w.Name | Should -Not -BeNullOrEmpty
            $w.Name | Should -Not -Match '(?i)five_hour|seven_day|quota|axi'
            $w.Percent | Should -BeOfType [int]
            $w.Percent | Should -BeGreaterOrEqual 0
            $w.Percent | Should -BeLessOrEqual 100
        }
    }
}

Describe 'Get-FmSpeechEngineStatus' {

    # THE ENGINE IS STAGED HERE, NEVER BORROWED FROM THE MACHINE. Every case
    # below is about what the captain's SETTING says, and Get-FmSpeechEngineStatus
    # answers that question only after it has found an engine at all - with none
    # it returns early with HandsOver false and no Setup line. So the two cases
    # that assert a wired engine passed on this seat, where Handy is installed,
    # and failed on a clean VM where it is not; the three that assert "not wired"
    # passed there for the wrong reason, proving nothing about the setting.
    # Both halves are the same defect, and staging the engine ends both.
    #
    # RUNNING IS STAGED THE SAME WAY. The function decides Running by asking
    # whether a process named after the engine FILE is up, so an engine named
    # after this very process is running by construction on any machine, and one
    # named after a guid is not. No dictation app has to be installed for either
    # answer to be real.
    BeforeAll {
        $script:SpeechTmp = Join-Path ([IO.Path]::GetTempPath()) ("fm-speech-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:SpeechTmp
        $script:Hook = Join-Path $script:SpeechTmp 'fm-dictate.cmd'
        Set-Content -LiteralPath $script:Hook -Value '@echo off' -NoNewline

        $script:LiveEngine = Join-Path $script:SpeechTmp ((Get-Process -Id $PID).ProcessName + '.exe')
        $script:IdleEngine = Join-Path $script:SpeechTmp ('fm-no-such-engine-' + [guid]::NewGuid().ToString('N') + '.exe')

        function script:New-SettingsFixture {
            param([string]$Method, [object]$ScriptPath, [string]$Name)
            $file = Join-Path $script:SpeechTmp "$Name.json"
            $body = [ordered]@{ settings = [ordered]@{
                    paste_method         = $Method
                    external_script_path = $ScriptPath
                }
            } | ConvertTo-Json -Depth 5
            Set-Content -LiteralPath $file -Value $body
            $file
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SpeechTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'says an engine that is set to hand the words over is doing so' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:LiveEngine } -ModuleName Firstmate
        $file = script:New-SettingsFixture -Method 'external_script' -ScriptPath $script:Hook -Name 'wired'
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.Installed | Should -BeTrue
        $s.Running | Should -BeTrue
        $s.HandsOver | Should -BeTrue
        # Nothing left to ask the captain for, so nothing is asked.
        $s.Setup | Should -BeNullOrEmpty
    }

    # THE CASE THAT IS ACTUALLY LIVE ON THE CAPTAIN'S MACHINE, and the reason this
    # reads the setting instead of assuming it: with the app typing where the
    # cursor is, a dictated line only arrives when the right window has focus.
    It 'says an engine that types where the cursor is has not been wired' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:LiveEngine } -ModuleName Firstmate
        $file = script:New-SettingsFixture -Method 'direct' -ScriptPath $null -Name 'direct'
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.Installed | Should -BeTrue
        $s.HandsOver | Should -BeFalse
        # The one step, naming the exact file, because an instruction the captain
        # cannot act on is the same as no instruction.
        $s.Setup | Should -BeLike "*$($script:Hook)*"
    }

    # Both halves or neither: the hook chosen but pointed at something else hands
    # nothing to firstmate, and claiming otherwise would promise words that never
    # come.
    It 'needs both the hook AND the path before it claims the words will arrive' -ForEach @(
        @{ Method = 'external_script'; Path = 'C:\tools\something-else.cmd' }
        @{ Method = 'direct'; Path = 'C:\repo\bin\fm-dictate.cmd' }
    ) {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:LiveEngine } -ModuleName Firstmate
        $file = script:New-SettingsFixture -Method $Method -ScriptPath $Path -Name ('half' + $Method + ($Path -replace '\W', ''))
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        # Installed, so the answer below is the SETTING's and not the early
        # return a machine with no engine takes.
        $s.Installed | Should -BeTrue
        $s.HandsOver | Should -BeFalse
    }

    It 'treats a settings file it cannot read as not wired, rather than throwing' -ForEach @(
        @{ Body = 'not json at all {{{' }
        @{ Body = '' }
        @{ Body = '{"settings":null}' }
    ) {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:LiveEngine } -ModuleName Firstmate
        $file = Join-Path $script:SpeechTmp 'broken.json'
        Set-Content -LiteralPath $file -Value $Body
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.Installed | Should -BeTrue
        $s.HandsOver | Should -BeFalse
        $s.Detail | Should -Not -BeNullOrEmpty
    }

    It 'survives a settings file that is not there' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:LiveEngine } -ModuleName Firstmate
        $s = Get-FmSpeechEngineStatus -SettingsPath (Join-Path $script:SpeechTmp 'absent.json') -HookPath $script:Hook
        $s.Installed | Should -BeTrue
        $s.HandsOver | Should -BeFalse
    }

    It 'says so plainly when no dictation app is installed at all' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { '' } -ModuleName Firstmate
        $s = Get-FmSpeechEngineStatus -HookPath $script:Hook
        $s.Installed | Should -BeFalse
        $s.Running | Should -BeFalse
        $s.Detail | Should -Match 'installed'
    }

    # An engine that is there but not up is its own answer, and the one the
    # captain sees most: the model is unloaded, so nothing can be dictated until
    # they start it. Staged rather than waited for.
    It 'says an installed engine that is not up is not up' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { $script:IdleEngine } -ModuleName Firstmate
        $file = script:New-SettingsFixture -Method 'external_script' -ScriptPath $script:Hook -Name 'idle'
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.Installed | Should -BeTrue
        $s.Running | Should -BeFalse
        # The setting is still read and still believed - not running is not the
        # same fact as not wired.
        $s.HandsOver | Should -BeTrue
    }

    # AGENTS.md section 9 binds on this line exactly as in chat: the bridge prints
    # it and the page shows it. The PATH in Setup is the exception section 9 itself
    # allows - the captain needs it to act - so only Detail is held to the rule.
    #
    # All FOUR states, because the rule is about every sentence this can produce
    # and the machine used to decide which of them was ever reached.
    It 'describes the state in the captain nouns, never in machinery: <Case>' -ForEach @(
        @{ Case = 'running and wired'; Method = 'external_script'; Path = 'fm-dictate.cmd'; Running = $true }
        @{ Case = 'running and typing at the cursor'; Method = 'direct'; Path = $null; Running = $true }
        @{ Case = 'wired but not up'; Method = 'external_script'; Path = 'fm-dictate.cmd'; Running = $false }
        @{ Case = 'not installed'; Method = 'direct'; Path = $null; Running = $false }
    ) {
        $engine = if ($Case -eq 'not installed') { '' } elseif ($Running) { $script:LiveEngine } else { $script:IdleEngine }
        Mock -CommandName Get-FmSpeechEngine -MockWith { $engine }.GetNewClosure() -ModuleName Firstmate
        $file = script:New-SettingsFixture -Method $Method -ScriptPath $Path -Name ('nouns' + ($Case -replace '\W', ''))
        $detail = (Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook).Detail
        $detail | Should -Not -BeNullOrEmpty
        $detail | Should -Not -Match '(?i)\.ps1|\.cmd|pwsh|paste_method|external_script|handy'
        $detail | Should -Not -Match '(?i)transcrib|recognizer'
    }
}

Describe 'New-FmSpeechCaptureState' {

    It 'starts with nothing running, nothing waiting and nothing pending' {
        $s = New-FmSpeechCaptureState
        $s.Recording | Should -BeFalse
        $s.AwaitingPage | Should -BeFalse
        $s.Pending | Should -Be ''
        $s.PendingForPage | Should -BeFalse
    }

    It 'hands out a fresh object each time, so two bridges cannot share one' {
        $a = New-FmSpeechCaptureState
        $b = New-FmSpeechCaptureState
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
    }
}

Describe 'Step-FmSpeechCaptureState' {

    # THE DEFECT THIS FILE EXISTS FOR. The engine's interface is one flag that
    # both starts and stops, and the page used to send it blind on press and on
    # release. The moment those stopped pairing up, every release started a
    # recording and every press stopped one - the microphone open with nobody
    # holding it and the screen's badge saying "closed" over it. The captain's
    # report was "on click/push it stop in 1-2 sec and then after it not workig
    # any time"; docs/windows-e2e-evidence.md section 32 has the measurement.
    Context 'the edge of the engine toggle' {

        It 'a first press starts the engine' {
            $r = Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)
            $r.EngineAction | Should -Be 'Toggle'
            $r.State.Recording | Should -BeTrue
        }

        It 'a release of that press stops it, once' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $r = Step-FmSpeechCaptureState -Step 'Stop' -State $s
            $r.EngineAction | Should -Be 'Toggle'
            $r.State.Recording | Should -BeFalse
        }

        # This is the whole fix. A stop with nothing running used to be passed
        # through as a toggle, which STARTS a recording.
        It 'says nothing to the engine when a stop arrives with nothing running' {
            $r = Step-FmSpeechCaptureState -Step 'Stop' -State (New-FmSpeechCaptureState)
            $r.EngineAction | Should -Be 'None'
            $r.State.Recording | Should -BeFalse
        }

        It 'says nothing to the engine when a second press arrives during a hold' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $r = Step-FmSpeechCaptureState -Step 'Start' -State $s
            $r.EngineAction | Should -Be 'None'
            # and it is still recording, so the release that follows still stops it
            $r.State.Recording | Should -BeTrue
        }

        It 'drops a capture on cancel, and only when one is running' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            (Step-FmSpeechCaptureState -Step 'Cancel' -State $s).EngineAction | Should -Be 'Cancel'
            (Step-FmSpeechCaptureState -Step 'Cancel' -State (New-FmSpeechCaptureState)).EngineAction |
                Should -Be 'None'
        }

        # Ten presses is the captain's own bar for "usable again afterwards".
        It 'alternates for ten consecutive press-release cycles and never drifts' {
            $s = New-FmSpeechCaptureState
            $sent = [System.Collections.Generic.List[string]]::new()
            1..10 | ForEach-Object {
                $r = Step-FmSpeechCaptureState -Step 'Start' -State $s
                $sent.Add("$($r.EngineAction)"); $s = $r.State
                $r = Step-FmSpeechCaptureState -Step 'Stop' -State $s
                $sent.Add("$($r.EngineAction)"); $s = $r.State
            }
            ($sent -join ',') | Should -Be ((, 'Toggle,Toggle') * 10 -join ',')
            $s.Recording | Should -BeFalse
        }

        It 'leaves nothing recording after a release, whatever landed in between' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'a late line').State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s.Recording | Should -BeFalse
        }
    }

    # An engine that refused establishes exactly one fact - it is not recording
    # for us - and the state has to record that fact and no more than it.
    Context 'an engine that did not take the request' {

        It 'stops believing a refused start is recording' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s.Recording | Should -BeTrue
            (Step-FmSpeechCaptureState -Step 'Failed' -State $s).State.Recording | Should -BeFalse
        }

        It 'so the release after a refused start says nothing to the engine' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Failed' -State $s).State
            (Step-FmSpeechCaptureState -Step 'Stop' -State $s).EngineAction | Should -Be 'None'
        }

        # A stop that never reached the engine may still be followed by a
        # transcript, and the page is already polling for one. Clearing that wait
        # would put its line back on the fleet channel, which is the defect this
        # machine exists to end.
        It 'leaves an outstanding wait for words alone' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Failed' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'it arrived anyway').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed | Should -Be ''
            (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).Handed | Should -Be 'it arrived anyway'
        }

        It 'never asks the engine for anything itself' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            (Step-FmSpeechCaptureState -Step 'Failed' -State $s).EngineAction | Should -Be 'None'
            (Step-FmSpeechCaptureState -Step 'Failed' -State (New-FmSpeechCaptureState)).EngineAction |
                Should -Be 'None'
        }
    }

    Context 'a page that does not know start from stop' {

        # A tab left open from before this landed sends one word for both edges.
        # It is resolved against what is running rather than passed through, so
        # a stale page is safer than it used to be rather than merely tolerated.
        It 'reads a bare toggle as a start when nothing is running' {
            $r = Step-FmSpeechCaptureState -Step 'Toggle' -State (New-FmSpeechCaptureState)
            $r.EngineAction | Should -Be 'Toggle'
            $r.State.Recording | Should -BeTrue
        }

        It 'reads a bare toggle as a stop when something is' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $r = Step-FmSpeechCaptureState -Step 'Toggle' -State $s
            $r.EngineAction | Should -Be 'Toggle'
            $r.State.Recording | Should -BeFalse
        }

        It 'cannot be asked for a request the engine does not have' {
            { Step-FmSpeechCaptureState -Step 'Pause' -State (New-FmSpeechCaptureState) } |
                Should -Throw
        }
    }

    # THE SECOND HALF OF THE DEFECT. /api/fleet carries a dictated line so the
    # captain can dictate with their own key while no page asked for anything.
    # It was handing over lines produced by a capture the page WAS holding, two
    # seconds into the hold, so the screen answered a sentence the captain had
    # not finished saying.
    Context 'whose line a transcript is' {

        It 'gives the fleet a line dictated with nobody holding anything' {
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State (New-FmSpeechCaptureState) -Text 'ahoy').State
            $r = Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s
            $r.Handed | Should -Be 'ahoy'
            $r.State.Pending | Should -Be ''
        }

        It 'refuses the fleet a line that landed while a page was holding' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'still speaking').State
            $r = Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s
            $r.Handed | Should -Be ''
            # and it is still there for the page that asked
            $r.State.Pending | Should -Be 'still speaking'
        }

        It 'refuses the fleet a line that landed while a page was waiting for its own' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'the words').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed | Should -Be ''
        }

        It 'gives the page that asked its own line' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'the words').State
            $r = Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s
            $r.Handed | Should -Be 'the words'
            $r.State.Pending | Should -Be ''
        }

        It 'hands one utterance over once, however many tabs are polling' {
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State (New-FmSpeechCaptureState) -Text 'once').State
            $first = Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s
            $first.Handed | Should -Be 'once'
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $first.State).Handed | Should -Be ''
        }

        # The captain's own key still reaches the screen once the page has
        # collected what it was waiting for - the fleet channel is narrowed, not
        # closed.
        It 'goes back to giving the fleet lines once the page has collected' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'mine').State
            $s = (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'dictated with my own key').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed |
                Should -Be 'dictated with my own key'
        }

        # Dropping a line the captain can simply repeat is safe. Asking firstmate
        # a question nobody finished saying is not, and that is what the old
        # broadcast did.
        It 'discards an uncollected page line at the next press rather than broadcasting it' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'never collected').State
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State $s).State
            $s.Pending | Should -Be ''
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed | Should -Be ''
        }

        # THE RACE THIS ALMOST SHIPPED WITH. The page polls /api/heard every
        # 400ms while the engine spends about three seconds transcribing, so the
        # first several polls are empty by design. An empty one used to end the
        # page's claim, and the transcript then went out over the fleet channel
        # the moment it landed - the same defect, one poll later, and further
        # from where anyone would look for it.
        It 'does not end the wait on an empty poll, which is most of them' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            # three empty polls while the engine transcribes
            1..3 | ForEach-Object { $s = (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).State }
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'the words at last').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed | Should -Be ''
            (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).Handed | Should -Be 'the words at last'
        }

        It 'ends the wait when a line actually arrives' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'mine').State
            $s = (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).State
            $s.AwaitingPage | Should -BeFalse
        }

        # Otherwise a page that gave up would pin its line out of everyone's
        # reach for the rest of the run.
        It 'releases the claim when the page says it has given up' {
            $s = (Step-FmSpeechCaptureState -Step 'Start' -State (New-FmSpeechCaptureState)).State
            $s = (Step-FmSpeechCaptureState -Step 'Stop' -State $s).State
            $s = (Step-FmSpeechCaptureState -Step 'Cancel' -State $s).State
            $s.AwaitingPage | Should -BeFalse
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State $s -Text 'dictated with my own key').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed |
                Should -Be 'dictated with my own key'
        }

        It 'takes an empty transcript without pretending it heard something' {
            $s = (Step-FmSpeechCaptureState -Step 'Dictated' -State (New-FmSpeechCaptureState) -Text '').State
            (Step-FmSpeechCaptureState -Step 'TakeForFleet' -State $s).Handed | Should -Be ''
            (Step-FmSpeechCaptureState -Step 'TakeForPage' -State $s).Handed | Should -Be ''
        }
    }

    Context 'the state it is handed' {

        It 'does not mutate the state it was given' {
            $s = New-FmSpeechCaptureState
            $null = Step-FmSpeechCaptureState -Step 'Start' -State $s
            $s.Recording | Should -BeFalse
        }

        It 'requires a state rather than inventing one' {
            { Step-FmSpeechCaptureState -Step 'Start' } | Should -Throw
        }
    }
}

Describe 'Invoke-FmSpeechCapture' {

    # The refusals, which are the load-bearing half. Running the engine binary
    # when no instance is up launches the whole application and loads a second
    # copy of the model - the 10.8s-to-14.8s cost the fast path exists to avoid -
    # so "not now" has to be the answer rather than "start one".
    It 'refuses when no dictation app is installed, without trying to run one' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { '' } -ModuleName Firstmate
        $r = Invoke-FmSpeechCapture
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'installed'
        # The spawn failure would have said "could not reach"; this proves the
        # refusal happened BEFORE anything was started.
        $r.Error | Should -Not -Match 'could not reach'
    }

    It 'refuses when the app is installed but not running, rather than starting one' {
        # A real path that no process is named after, so Running is false for the
        # reason under test rather than because the file is missing.
        # Empty, because only its EXISTENCE is under test here and a .exe with
        # anything in it is read by Windows as an MS-DOS program the moment
        # something does try to launch it. New-FmUnstartableFixture has the
        # measurement; this test does not launch it today, and the next edit
        # that does must not be the one that discovers this.
        $fake = New-FmUnstartableFixture -Path (Join-Path ([IO.Path]::GetTempPath()) `
            ('fm-no-such-engine-' + [guid]::NewGuid().ToString('N') + '.exe'))
        try {
            Mock -CommandName Get-FmSpeechEngine -MockWith { $fake } -ModuleName Firstmate
            $r = Invoke-FmSpeechCapture -Action Toggle
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'not running'
            $r.Error | Should -Not -Match 'could not reach'
        } finally {
            Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports which request it refused, so a caller can tell start from drop' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { '' } -ModuleName Firstmate
        (Invoke-FmSpeechCapture -Action Cancel).Action | Should -Be 'Cancel'
        (Invoke-FmSpeechCapture -Action Toggle).Action | Should -Be 'Toggle'
    }

    # Toggle and Cancel are the only two things the engine's own interface offers;
    # anything else is a caller bug and must not be sent as one of them.
    It 'takes no request it cannot make' {
        { Invoke-FmSpeechCapture -Action 'Start' } | Should -Throw
    }

    It 'never says machinery to the captain when it refuses' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { '' } -ModuleName Firstmate
        (Invoke-FmSpeechCapture).Error | Should -Not -Match '(?i)\.exe|\.ps1|handy|toggle-transcription|exit code'
    }
}

Describe 'Get-FmBridgeFleet' {

    BeforeAll {
        $script:FleetHome = Join-Path ([IO.Path]::GetTempPath()) ("fm-fleet-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:FleetHome 'state') -Force
        $state = Join-Path $script:FleetHome 'state'
        Set-Content -LiteralPath (Join-Path $state 'fire-drill.meta') -Value 'kind=ship'
        Set-Content -LiteralPath (Join-Path $state 'fire-drill.status') -Value @(
            'working: [10%] first thing'
            'working: [40%] second thing'
            'working: [70%] third thing'
        )
        Set-Content -LiteralPath (Join-Path $state 'no-figure.meta') -Value 'kind=ship'
        Set-Content -LiteralPath (Join-Path $state 'no-figure.status') -Value 'working: getting on with it'
    }

    AfterAll { Remove-Item -LiteralPath $script:FleetHome -Recurse -Force -ErrorAction SilentlyContinue }

    # THE RECORD HAS ONE WRITE TIME, NOT ONE PER LINE. Stamping all of the last
    # four lines with the file's write time told the captain that four things
    # happened at one moment; three of them happened at times nothing here can
    # know. A borrowed timestamp is an invented measurement in the same way a
    # borrowed percentage is.
    It 'gives a time only to the line whose time it knows' {
        $activity = @((Get-FmBridgeFleet -HomePath $script:FleetHome).Activity |
                Where-Object { $_.Task -eq 'fire-drill' })
        $activity.Count | Should -Be 3
        @($activity | Where-Object { $_.At }).Count | Should -Be 1
        # And it is the newest line that has it, not whichever one sorted first.
        $activity[0].Text | Should -Match 'third thing'
        $activity[0].At | Should -Match '^\d{2}:\d{2}:\d{2}$'
    }

    It 'still orders a line that has no time' {
        $activity = @((Get-FmBridgeFleet -HomePath $script:FleetHome).Activity |
                Where-Object { $_.Task -eq 'fire-drill' })
        $activity[1].Text | Should -Match 'second thing'
        $activity[2].Text | Should -Match 'first thing'
    }

    # Every line needs an identity of its own now that most of them share the
    # empty string for a time, or the page folds them into one row.
    It 'gives every line an identity that is not its time' {
        $activity = @((Get-FmBridgeFleet -HomePath $script:FleetHome).Activity)
        $orders = @($activity.Order)
        @($orders | Select-Object -Unique).Count | Should -Be $orders.Count
        foreach ($o in $orders) { $o | Should -Not -BeNullOrEmpty }
    }

    # The standard the captain named for every other figure on the screen: a
    # task that declared no percentage reports null, never a plausible zero.
    It 'reports no figure rather than a zero when none was claimed' {
        $task = @((Get-FmBridgeFleet -HomePath $script:FleetHome).Tasks |
                Where-Object { $_.Id -eq 'no-figure' })[0]
        $task.Percent | Should -BeNullOrEmpty
        $task.Percent | Should -Not -Be 0
    }

    It 'carries the capacity read alongside the work, measured or not' {
        $c = (Get-FmBridgeFleet -HomePath $script:FleetHome).Capacity
        $c | Should -Not -BeNullOrEmpty
        $c.Measured | Should -BeOfType [bool]
    }
}

Describe 'Get-FmBridgeVocabulary' {

    It 'gives every entry a pattern and a plain word' {
        foreach ($rule in (Get-FmBridgeVocabulary)) {
            $rule.Pattern | Should -Not -BeNullOrEmpty
            $rule.Plain | Should -Not -BeNullOrEmpty
        }
    }

    # "primary checkout" translated a word at a time becomes "primary local
    # copy", which reads as a distinction the captain is meant to understand.
    # The multi-word entries must therefore be reachable before the single ones.
    It 'puts the longer phrase before the word it contains' {
        $patterns = (Get-FmBridgeVocabulary).Pattern
        $primary = [array]::FindIndex($patterns, [Predicate[string]] { $args[0] -match 'primary' })
        $bare = [array]::FindIndex($patterns, [Predicate[string]] { $args[0] -match 'worktrees\?\\b\|' })
        $primary | Should -BeGreaterOrEqual 0
        if ($bare -ge 0) { $primary | Should -BeLessThan $bare }
    }

    # A replacement that itself contains a forbidden word would launder the term
    # rather than remove it, and every test above would still pass.
    It 'never replaces one forbidden word with another' {
        $banned = 'worktree', 'crewmate', 'teardown', 'harness', 'herdr', 'watcher', 'yolo'
        foreach ($rule in (Get-FmBridgeVocabulary)) {
            foreach ($word in $banned) {
                $rule.Plain | Should -Not -Match ([regex]::Escape($word)) -Because "'$($rule.Plain)' still carries '$word'"
            }
        }
    }
}

Describe 'ConvertTo-FmBridgePlainText -Prose' {

    # THE REPLY THAT PUT THIS FILE'S SECOND HALF HERE. Copied from the screen,
    # beside a panel that was at that moment listing three jobs with live
    # percentages. Every internal term in AGENTS.md section 9's list that a
    # session reaches for when it describes its own limits is in these two
    # sentences, and all of it reached the captain because the reply was the one
    # surface that never went through the translator.
    BeforeAll {
        $script:Leak = @'
Captain, nothing is under way - no active work, an empty queue, and no held or
blocked items. This session opened read-only: another firstmate session (pid
25876) holds the fleet lock, so I can't dispatch, steer, or merge from here.
Your checkout has uncommitted changes.
'@
    }

    It 'leaves no process number, no lock and no read-only on screen' {
        $out = ConvertTo-FmBridgePlainText -Text $script:Leak -Prose
        foreach ($word in @('read-only', 'lock', 'pid', '25876', 'dispatch', 'steer', 'merge', 'checkout', 'uncommitted')) {
            $out | Should -Not -Match ('\b' + [regex]::Escape($word) + '\b') -Because "the captain saw '$word' and it produced '$out'"
        }
    }

    # A translation that eats the answer is the failure the panel path already
    # learned: the captain can ask what a word meant, but not what a blank box
    # meant.
    It 'still says something, rather than deleting the answer' {
        (ConvertTo-FmBridgePlainText -Text $script:Leak -Prose).Length | Should -BeGreaterThan 60
    }

    # A reply is paragraphs, bullets and blank lines; a status line is one line
    # with a label on it. Flattening the first into the second is what a single
    # shared rule set would have done, so the shape is pinned.
    It 'keeps the shape of an answer rather than flattening it to one line' {
        $answer = @'
Two things are running.

- the sign-in fix, at 40%
- the payment tests, at 10%

Neither needs you yet.
'@
        $out = ConvertTo-FmBridgePlainText -Text $answer -Prose
        @($out -split "`n").Count | Should -BeGreaterThan 4
        $out | Should -Match '(?m)^- the sign-in fix'
        $out | Should -Match '(?m)^$'
    }

    It 'keeps a nested bullet indented under its parent' {
        $out = ConvertTo-FmBridgePlainText -Text "- the fix`n    - and its test" -Prose
        $out | Should -Match '(?m)^    - and its test'
    }

    # The panel path is the one this seam already shipped, and a reply-shaped
    # change must not move it a character.
    It 'leaves the status-line path exactly as it was' -ForEach @(
        @{ Line = 'done: PR ready in worktree fm/tg-build'; Want = 'PR ready in local copy' }
        @{ Line = 'blocked: crewmate wedged, teardown refused'; Want = 'Worker stuck, cleanup refused' }
    ) {
        ConvertTo-FmBridgePlainText -Text $Line | Should -Be $Want
    }

    # An assistant quoting a worker's line back at the captain is the same leak
    # by a longer route, so the known state words go in prose too - but only
    # those. A sentence that merely ends a clause in a colon must survive.
    It 'strips a quoted state label without eating an ordinary sentence' {
        ConvertTo-FmBridgePlainText -Text 'blocked: the card provider is refusing' -Prose |
            Should -Be 'the card provider is refusing'
        ConvertTo-FmBridgePlainText -Text 'here is where it stands: two jobs are running' -Prose |
            Should -Be 'here is where it stands: two jobs are running'
    }

    It 'never damages a link in an answer either' {
        $out = ConvertTo-FmBridgePlainText -Text "It is ready to review:`nhttps://github.com/o/r/pull/3" -Prose
        $out | Should -BeLike '*https://github.com/o/r/pull/3*'
    }

    It 'survives an empty answer without inventing text' -ForEach @(
        @{ Line = '' }, @{ Line = '   ' }, @{ Line = "`n`n" }
    ) {
        ConvertTo-FmBridgePlainText -Text $Line -Prose | Should -Be ''
    }
}

Describe 'Remove-FmBridgeRepetition' {

    # THE EIGHT MESSAGES. One internal event re-fired while nothing could be done
    # about it, the session was continued after each one, and every near-identical
    # answer landed on the captain's screen. A screen that repeats itself while
    # nothing changes trains them to stop reading it.
    It 'says a repeated point once' {
        $stack = @'
Captain, the guard is firing again and nothing has changed since the last time.
Captain, the guard is firing again and nothing has changed since last time.
Captain, the guard is firing again, and nothing has changed since the last time.
Captain the guard is firing again and nothing has changed since the last time
'@
        $out = Remove-FmBridgeRepetition -Text $stack
        @($out -split "`n" | Where-Object { $_ }).Count | Should -Be 1
        $out | Should -Match 'firing again'
    }

    # The cure must not be worse than the disease: two lines about the same task
    # are not the same line, and cutting the second loses the captain real work.
    It 'keeps two different lines about the same job' {
        $out = Remove-FmBridgeRepetition -Text "The sign-in fix is at 40 percent.`nThe payment tests have not started."
        @($out -split "`n" | Where-Object { $_ }).Count | Should -Be 2
    }

    It 'keeps a list whose items only share their shape' {
        $list = "- the sign-in fix passed its checks`n- the payment tests passed their checks`n- the search work passed its checks"
        @((Remove-FmBridgeRepetition -Text $list) -split "`n" | Where-Object { $_ }).Count | Should -Be 3
    }

    # Adjacency is what separates stammering from an argument that returns to a
    # theme, so a repeat three paragraphs later is left alone unless it is word
    # for word the same.
    It 'leaves a developed answer alone' {
        $answer = "Two jobs are running.`nThe first is the sign-in fix at 40 percent.`nThe second has not started.`nNeither of the two jobs needs you yet."
        @((Remove-FmBridgeRepetition -Text $answer) -split "`n" | Where-Object { $_ }).Count | Should -Be 4
    }

    # A NUMBER IS OFTEN THE ONLY DIFFERENCE, and the first cut normalised digits
    # away: "Step 1 complete." and "Step 2 complete." became one line, and the
    # captain lost a step of a real answer to a rule meant to remove a stammer.
    It 'keeps two lines that differ only by a number' {
        $out = Remove-FmBridgeRepetition -Text "Step 1 complete.`nStep 2 complete.`nStep 3 complete."
        @($out -split "`n" | Where-Object { $_ }).Count | Should -Be 3
    }

    It 'survives an empty answer' -ForEach @(
        @{ Line = '' }, @{ Line = '   ' }
    ) {
        Remove-FmBridgeRepetition -Text $Line | Should -Be ''
    }
}

Describe 'New-FmBridgeSession' {

    # THE DEFECT THIS WHOLE DESCRIBE EXISTS FOR. The captain typed `firstmate`
    # on a fresh VM and got a general assistant: it introduced itself as Claude,
    # said it could not start work, and sent them to a firstmate window that did
    # not exist. The session was being started in the HOME - `config/ data/
    # projects/ state/` and nothing else - so it had no AGENTS.md, no CLAUDE.md,
    # no skills and no `.claude/settings.json`, which is also the file whose
    # SessionStart hook takes the home's lock. One wrong directory, both halves.
    #
    # DRIVEN THROUGH A STUB, not the real CLI. What is being asserted is where
    # this function puts a process and what it tells it about the home, and a
    # stub that records both answers those exactly. Nothing here starts a real
    # engine, opens a browser, or speaks.
    BeforeAll {
        $script:SessTmp = Join-Path ([IO.Path]::GetTempPath()) ('fm-sess-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:SessTmp
        $script:SessCheckout = Join-Path $script:SessTmp 'checkout'
        $script:SessHome = Join-Path $script:SessTmp 'home'
        $null = New-Item -ItemType Directory -Path $script:SessCheckout
        $null = New-Item -ItemType Directory -Path (Join-Path $script:SessHome 'state')
        $script:SessRecord = Join-Path $script:SessTmp 'started.txt'
        $script:SessStub = Join-Path $script:SessTmp 'claude.cmd'
        # THE REDIRECT COMES FIRST ON PURPOSE. Written the natural way round,
        # `echo voice=%FM_VOICE_OFF%>>"file"` expands to `echo voice=1>>"file"`
        # and cmd reads that trailing `1` as the stdout file descriptor, so the
        # value silently disappears from what it wrote and the stub reports an
        # unset variable that is in fact set. Cost one wrong diagnosis already.
        Set-Content -LiteralPath $script:SessStub -Value @(
            '@echo off'
            ">`"$script:SessRecord`" echo cwd=%CD%"
            ">>`"$script:SessRecord`" echo home=%FM_HOME%"
            ">>`"$script:SessRecord`" echo voice=%FM_VOICE_OFF%"
        )
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SessTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:SessRecord -Force -ErrorAction SilentlyContinue
        Mock -CommandName Get-Command -ModuleName Firstmate `
            -ParameterFilter { $Name -eq 'claude' } `
            -MockWith { [pscustomobject]@{ Source = $script:SessStub } }
    }

    It 'starts the session in the checkout, where the contract and the hooks are' {
        $s = New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath $script:SessCheckout
        $s | Should -Not -BeNullOrEmpty
        try { $s.Process.WaitForExit(20000) | Out-Null } finally { $s.Process.Dispose() }

        $record = Get-Content -LiteralPath $script:SessRecord -Raw
        # THE HOME IS NOT AN ACCEPTABLE ANSWER HERE. That was the defect.
        $record | Should -Match ('(?m)^cwd=' + [regex]::Escape($script:SessCheckout) + '\s*$')
        $record | Should -Not -Match ('(?m)^cwd=' + [regex]::Escape($script:SessHome) + '\s*$')
    }

    # Running in the checkout is only half an answer: the checkout resolves its
    # home from `.fm-home` or the environment, and the bridge already knows
    # which home this is. Saying so leaves nothing to infer, and it is inherited
    # by everything the session starts.
    It 'tells that session which home it operates on' {
        $s = New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath $script:SessCheckout
        try { $s.Process.WaitForExit(20000) | Out-Null } finally { $s.Process.Dispose() }
        Get-Content -LiteralPath $script:SessRecord -Raw |
            Should -Match ('(?m)^home=' + [regex]::Escape($script:SessHome) + '\s*$')
    }

    # Unchanged by this fix and pinned so it stays that way: a home that has
    # turned config/voice on must not talk out of a process the page cannot
    # reach. The session is now a full firstmate, so it knows bin/fm-say.ps1
    # exists - which makes this gate matter more than it did before, not less.
    It 'still refuses that session the machine voice' {
        $s = New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath $script:SessCheckout
        try { $s.Process.WaitForExit(20000) | Out-Null } finally { $s.Process.Dispose() }
        Get-Content -LiteralPath $script:SessRecord -Raw | Should -Match '(?m)^voice=1\s*$'
    }

    It 'records the checkout on the handle, so the bridge is not left guessing' {
        $s = New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath $script:SessCheckout
        try {
            $s.Checkout | Should -Be $script:SessCheckout
            $s.Home | Should -Be $script:SessHome
            $s.Process.WaitForExit(20000) | Out-Null
        } finally { $s.Process.Dispose() }
    }

    # A bridge with no checkout to host the session in cannot produce a
    # firstmate, and starting one anyway is exactly how this defect shipped.
    It 'refuses to start a session with no checkout to run it in' {
        { New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath '' } | Should -Throw
    }

    It 'answers with nothing at all when the CLI is not installed' {
        Mock -CommandName Get-Command -ModuleName Firstmate `
            -ParameterFilter { $Name -eq 'claude' } -MockWith { $null }
        New-FmBridgeSession -HomePath $script:SessHome -CheckoutPath $script:SessCheckout |
            Should -BeNullOrEmpty
    }
}

Describe 'Get-FmBridgeHomeHolder' {

    BeforeAll {
        $script:CanActHome = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path (Join-Path $script:CanActHome 'state') -Force | Out-Null
    }

    It 'says nobody holds this home when nothing does' {
        $h = Get-FmBridgeHomeHolder -HomePath $script:CanActHome -SessionProcessId 4242
        $h.Holder | Should -Be 'none'
        $h.CanAct | Should -BeFalse
    }

    It 'says nobody rather than inventing a session when it was given none' {
        (Get-FmBridgeHomeHolder -HomePath $script:CanActHome).Holder | Should -Be 'none'
    }

    It 'says self only when the session this bridge hosts is the holder' {
        Mock -CommandName Get-FmSessionLockStatus -ModuleName Firstmate -MockWith {
            [pscustomobject]@{ State = 'held'; ProcessId = 4242; Text = '' }
        }
        $mine = Get-FmBridgeHomeHolder -HomePath $script:CanActHome -SessionProcessId 4242
        $mine.Holder | Should -Be 'self'
        $mine.CanAct | Should -BeTrue

        $theirs = Get-FmBridgeHomeHolder -HomePath $script:CanActHome -SessionProcessId 25876
        $theirs.Holder | Should -Be 'elsewhere'
        $theirs.CanAct | Should -BeFalse
    }

    # THE DISTINCTION THE CAPTAIN PAID FOR. A window that is not there is not
    # the same fact as a window that is, and the two used to collapse into one
    # boolean - which is what sent them to a window they had never opened.
    It 'tells a dead holder apart from a live one, because only one is a window' -ForEach @(
        @{ State = 'stale'; Because = 'a dead holder is nobody to send the captain to' }
        @{ State = 'free'; Because = 'nothing holds it' }
        @{ State = 'unreadable'; Because = 'a record it could not read is not a window' }
        @{ State = 'invalid'; Because = 'a record it could not read is not a window' }
    ) {
        Mock -CommandName Get-FmSessionLockStatus -ModuleName Firstmate -MockWith {
            [pscustomobject]@{ State = $State; ProcessId = 25876; Text = '' }
        }
        (Get-FmBridgeHomeHolder -HomePath $script:CanActHome -SessionProcessId 4242).Holder |
            Should -Be 'none' -Because $Because
    }

    # Promising the captain an action this cannot deliver is worse than
    # understating what it can do, so anything it could not read counts as no.
    It 'says nobody rather than guessing when it cannot read who holds this home' {
        Mock -CommandName Get-FmSessionLockStatus -ModuleName Firstmate -MockWith { throw 'unreadable' }
        $h = Get-FmBridgeHomeHolder -HomePath $script:CanActHome -SessionProcessId 4242
        $h.Holder | Should -Be 'none'
        $h.CanAct | Should -BeFalse
    }
}

Describe 'Get-FmBridgeRoute' {

    # THE CAPTAIN THREW OUT THE SENTENCE THIS REPLACES. What used to be here was
    # a limitation stated plainly - "I can see the work but cannot start or stop
    # anything from here" - and their ruling was that a system worth talking to
    # never says that at all; it gives the way to get the thing done. A softer
    # phrasing of the same confession would have been the same mistake.
    It 'says nothing at all when the screen can act' {
        Get-FmBridgeRoute -Holder 'self' | Should -Be ''
    }

    It 'gives a route, never a refusal' -ForEach @(
        @{ Holder = 'elsewhere' }, @{ Holder = 'none' }
    ) {
        $route = Get-FmBridgeRoute -Holder $Holder
        $route | Should -Not -BeNullOrEmpty
        $route | Should -Not -Match "(?i)\bcan(?:not|n't)\b"
        $route | Should -Not -Match '(?i)\bunable\b'
        $route | Should -Not -Match '(?i)\bsorry\b'
    }

    It 'keeps machinery out of the route as well' -ForEach @(
        @{ Holder = 'elsewhere' }, @{ Holder = 'none' }
    ) {
        $route = Get-FmBridgeRoute -Holder $Holder
        foreach ($word in @('lock', 'read-only', 'pid', 'dispatch', 'merge', 'checkout', 'worktree')) {
            $route | Should -Not -Match ('\b' + [regex]::Escape($word) + '\b')
        }
    }

    It 'names the other window only when there really is one' {
        Get-FmBridgeRoute -Holder 'elsewhere' | Should -Match '(?i)another firstmate window is open'
    }

    # ACCEPTANCE CRITERION 2, AND THE WHOLE POINT OF THE THREE-WAY ANSWER. The
    # captain typed `firstmate` at a bare command prompt on a fresh VM, which IS
    # this screen, and was told to ask "in the firstmate window you already have
    # open". There was none. No answer this can give may assert one except the
    # single case where the record says a live session holds the home.
    It 'never claims the captain already has a window open' -ForEach @(
        @{ Holder = 'self' }, @{ Holder = 'none' }
    ) {
        $route = Get-FmBridgeRoute -Holder $Holder
        $route | Should -Not -Match '(?i)window (the captain |you )?already ha'
        $route | Should -Not -Match '(?i)(you|the captain) (already )?ha(ve|s) open'
    }

    It 'tells the session outright not to invent one when nothing holds the home' {
        $route = Get-FmBridgeRoute -Holder 'none'
        $route | Should -Match '(?i)NO other'
        $route | Should -Match '(?i)never send the captain to one'
        # And it still carries a step that exists. `\s+` rather than a space:
        # the route is wrapped for reading, so any phrase in it can fall across
        # a line break.
        $route | Should -Match '(?i)running firstmate\s+again'
    }

    # A three-way answer with only two shapes would be the boolean back again.
    It 'answers the two cannot-act cases differently' {
        Get-FmBridgeRoute -Holder 'none' | Should -Not -Be (Get-FmBridgeRoute -Holder 'elsewhere')
    }

    It 'refuses a holder it does not recognise rather than guessing a route' {
        { Get-FmBridgeRoute -Holder 'maybe' } | Should -Throw
    }
}

Describe 'New-FmBridgeTurnPrompt' {

    # The panel's own object, built the way Get-FmBridgeFleet builds it, because
    # the whole point of this seam is that both halves of the screen are two
    # renderings of ONE reading rather than two reads that agree by convention.
    BeforeAll {
        $script:Reading = [pscustomobject]@{
            At        = '14:22:05'
            Tasks     = @(
                [pscustomobject]@{ Id = 'ui-readonly'; Percent = 40; State = 'working'; Note = 'Reproduced the two answers' }
                [pscustomobject]@{ Id = 'tg-route'; Percent = 10; State = 'working'; Note = 'Reading the route' }
                [pscustomobject]@{ Id = 'lock-identity'; Percent = $null; State = 'working'; Note = 'Started' }
            )
            Decisions = @([pscustomobject]@{ Task = 'tg-route'; Key = 'carrier'; Question = 'Which provider should the test use?' })
            Activity  = @()
            House     = @([pscustomobject]@{ Name = 'This screen'; Detail = 'ready' })
        }
    }

    # THE CONTRADICTION, PINNED. Three jobs on the panel and "nothing is under
    # way" in the reply beside it, at the same moment, both honest. The reply can
    # only disagree with the panel if it is answering from something else, so it
    # is handed the panel's reading and told that is the answer.
    It 'carries every job the panel is showing, with the panel percentage' {
        $prompt = New-FmBridgeTurnPrompt -Text 'what is happening?' -Fleet $script:Reading
        foreach ($t in $script:Reading.Tasks) { $prompt | Should -Match ([regex]::Escape($t.Id)) }
        $prompt | Should -Match '40%'
        $prompt | Should -Match '10%'
        $prompt | Should -Match 'under way \(3\)'
    }

    It 'says a job claimed no percentage rather than calling it zero' {
        $prompt = New-FmBridgeTurnPrompt -Text 'and?' -Fleet $script:Reading
        $prompt | Should -Match 'no percentage given'
        $prompt | Should -Not -Match 'lock-identity: 0%'
    }

    It 'forbids the answer the captain actually got' {
        $prompt = New-FmBridgeTurnPrompt -Text 'what is happening?' -Fleet $script:Reading
        $prompt | Should -Match 'never say nothing'
        $prompt | Should -Match 'never give a count or a percentage that differs'
    }

    It 'carries the captain question and puts it last, after the reading' {
        $prompt = New-FmBridgeTurnPrompt -Text 'is the sign-in fix done?' -Fleet $script:Reading
        $prompt | Should -Match ([regex]::Escape('is the sign-in fix done?'))
        ($prompt.LastIndexOf('is the sign-in fix done?')) |
            Should -BeGreaterThan ($prompt.IndexOf('under way'))
    }

    # DO NOT SEND WHAT THE CAPTAIN MUST NOT READ. The reading used to carry each
    # decision's record handle so the session could close it, and the session
    # said "still held up on the carrier question" straight back to the captain -
    # `carrier` being the handle, a word on no panel and in no vocabulary.
    # Anything in this prompt can end up in the answer.
    It 'carries the question but never the record handle behind it' {
        $prompt = New-FmBridgeTurnPrompt -Text 'answer it' -Fleet $script:Reading
        $prompt | Should -Match 'Which provider should the test use\?'
        $prompt | Should -Match 'tg-route'
        $prompt | Should -Not -Match 'carrier'
        $prompt | Should -Not -Match 'key='
    }

    It 'names an empty fleet as empty rather than leaving it unsaid' {
        $empty = [pscustomobject]@{ At = '09:00:00'; Tasks = @(); Decisions = @(); Activity = @(); House = @() }
        $prompt = New-FmBridgeTurnPrompt -Text 'anything?' -Fleet $empty
        $prompt | Should -Match 'under way: nothing'
        $prompt | Should -Match 'waiting on the captain: nothing'
    }

    # The limit is the bridge's sentence, said once by the bridge. The session is
    # told to leave it alone, because the session repeating it every time the
    # same event re-fired is what stacked eight messages on the screen.
    It 'asks for the names the panel shows, so the captain can match the two' {
        $prompt = New-FmBridgeTurnPrompt -Text 'what is happening?' -Fleet $script:Reading
        $prompt | Should -Match '(?i)by the name the reading gives it'
    }

    It 'asks for plain sentences, because the screen shows text and the voice reads it' {
        $prompt = New-FmBridgeTurnPrompt -Text 'what is happening?' -Fleet $script:Reading
        $prompt | Should -Match '(?i)No markdown'
    }

    It 'carries a change of address along with the turn' {
        $prompt = New-FmBridgeTurnPrompt -Text 'hello' -Fleet $script:Reading -Address 'skipper'
        $prompt | Should -Match "Address me as 'skipper'"
    }
}

Describe 'ConvertTo-FmBridgePlainText -Keep' {

    # CAUGHT IN THE BROWSER, and by the cure rather than the disease. With the
    # panel row reading LOCK IDENTITY, the reply beside it called the same job
    # "controls-identity" - the vocabulary had translated a word inside a job's
    # own NAME. That is this whole seam's defect, two halves of one screen
    # disagreeing about one thing, reintroduced by the fix for it.
    It 'never translates a word inside a name the screen is showing' {
        $said = 'lock-identity is at 90% and the merge-tool work has not started.'
        $out = ConvertTo-FmBridgePlainText -Text $said -Prose -Keep @('lock-identity', 'merge-tool')
        $out | Should -Match 'lock-identity'
        $out | Should -Match 'merge-tool'
    }

    It 'still translates the same word when it is the session own, not a name' {
        ConvertTo-FmBridgePlainText -Text 'another session holds the lock' -Prose -Keep @('lock-identity') |
            Should -Not -Match '\block\b'
    }

    # A job called `lock` must not mask half of a job called `lock-identity` and
    # leave "-identity" behind to be translated on its own.
    It 'protects the longer name first' {
        $out = ConvertTo-FmBridgePlainText -Text 'lock-identity and lock are both running' -Prose -Keep @('lock', 'lock-identity')
        $out | Should -Match 'lock-identity'
    }

    It 'keeps a name the session wrote in its own case' {
        ConvertTo-FmBridgePlainText -Text 'LOCK-IDENTITY is at 90%' -Prose -Keep @('lock-identity') |
            Should -Match 'LOCK-IDENTITY'
    }

    # The panel translates a worker's note, and that note names its own job.
    It 'leaves a job name alone in the note the panel paints' {
        ConvertTo-FmBridgePlainText -Text 'working: [45%] starting on the checks for lock-identity' -Keep 'lock-identity' |
            Should -Be 'Starting on the checks for lock-identity'
    }

    It 'behaves exactly as before when it is given no names' {
        ConvertTo-FmBridgePlainText -Text 'done: PR ready in worktree fm/tg-build' -Keep @() |
            Should -Be 'PR ready in local copy'
    }
}

Describe 'Get-FmBridgeVocabulary, and the rule below it' {

    # THE TRAP THIS PINS. The dangling-preposition rule at the end of
    # ConvertTo-FmBridgePlainText exists to tidy up after a REMOVAL, and it
    # cannot tell a leftover from a word the table meant. So a plain word ending
    # in one of those prepositions gets its own tail eaten: "merge" translated to
    # "bring the work in" turned "it was merged." into "it was brought."
    It 'never ends a plain word in a preposition the translator strips' {
        $stripped = 'in', 'on', 'at', 'to', 'from', 'into', 'under', 'via', 'see'
        foreach ($rule in (Get-FmBridgeVocabulary)) {
            $last = @($rule.Plain -split '\s+')[-1]
            $last | Should -Not -BeIn $stripped -Because "'$($rule.Plain)' would lose its last word to the tidy-up rule"
        }
    }

    # The same trap, driven through the function rather than read off the table,
    # because the table is only half the contract.
    It 'leaves a translated sentence whole when it ends on the translated word' -ForEach @(
        @{ Line = 'done: it was merged' }
        @{ Line = 'working: waiting to merge' }
        @{ Line = 'blocked: cannot dispatch' }
    ) {
        $out = ConvertTo-FmBridgePlainText -Text $Line
        $out | Should -Not -Match '\b(?:brought|bring|start|land)\s*$'
        $out.Length | Should -BeGreaterThan 8
    }
}

Describe 'the reply never answers with a limitation' {

    # The captain's ruling, as a check on the instruction the session is given:
    # a limitation is never the reply, softened or otherwise, and the route is
    # what goes in its place.
    BeforeAll {
        $script:EmptyFleet = [pscustomobject]@{ At = '09:00:00'; Tasks = @(); Decisions = @(); Activity = @(); House = @() }
    }

    It 'tells the session to answer with the route instead' {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -Holder 'none'
        $prompt | Should -Match '(?i)NEVER answer with something you cannot do'
        $prompt | Should -Match '(?i)answer with how it gets done'
        $prompt | Should -Match '(?i)say what IS'
    }

    # "can you do it yourself? yes or no" came back as "No." on screen -
    # responsive to the letter, and still a limitation standing alone as the
    # whole reply. A yes-or-no is the captain asking for brevity, not for a dead
    # end.
    It 'holds the rule even when the captain asks for a yes or a no' {
        $prompt = New-FmBridgeTurnPrompt -Text 'can you do it yourself? yes or no.' -Fleet $script:EmptyFleet -Holder 'none'
        $prompt | Should -Match '(?i)even when the captain asks for a yes or a no'
        $prompt | Should -Match '(?i)bare no'
    }

    It 'carries the real route, not a polite deferral' -ForEach @(
        @{ Holder = 'none' }, @{ Holder = 'elsewhere' }
    ) {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -Holder $Holder
        $prompt | Should -Match ([regex]::Escape((Get-FmBridgeRoute -Holder $Holder)))
    }

    It 'leaves the route out entirely when the screen can act' {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -Holder 'self'
        $prompt | Should -Not -Match '(?i)firstmate window'
    }

    # ACCEPTANCE CRITERION 2, ON THE TEXT THAT ACTUALLY REACHES THE SESSION.
    # Get-FmBridgeRoute is pinned on its own above; this is the guarantee that
    # nothing ELSE in the composed prompt puts the sentence back, and that the
    # default a caller gets by saying nothing is not the claiming one.
    It 'never tells the session the captain already has a window open' -ForEach @(
        @{ Holder = 'self' }, @{ Holder = 'none' }
    ) {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -Holder $Holder
        $prompt | Should -Not -Match '(?i)window (the captain |you )?already ha'
        $prompt | Should -Not -Match '(?i)(you|the captain) (already )?ha(ve|s) open'
    }

    It 'assumes the screen is in charge when no holder is named, so no window is invented' {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet
        $prompt | Should -Not -Match '(?i)firstmate window'
    }

    It 'refuses a holder it does not recognise rather than composing a guessed route' {
        { New-FmBridgeTurnPrompt -Text 'go' -Fleet $script:EmptyFleet -Holder 'maybe' } | Should -Throw
    }

    # The append that produced the same statement twice in one reply is gone, so
    # nothing but the session writes the reply. This pins that: the entry point
    # must not be putting a canned sentence under the answer again.
    It 'has no canned sentence left to append under an answer' {
        $entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/fm-bridge.ps1'
        $loaded = @(Get-Command -Name 'Get-FmBridgeStandingNote' -ErrorAction SilentlyContinue)
        $loaded.Count | Should -Be 0 -Because 'the standing note was replaced by a route in the prompt'
        Test-Path -LiteralPath $entry | Should -BeTrue
    }
}

Describe 'Remove-FmBridgeRepetition, within one breath' {

    # THE CAPTAIN'S SECOND POINT, from their screen: one reply, one paragraph,
    # the same statement twice in slightly different words. A line-by-line pass
    # could not see it, because both sentences were on one line.
    It 'says a point once when it was made twice in the same paragraph' {
        $said = 'Three are under way. I can see this work but cannot start or stop any of it from here. I can see the work but cannot start or stop anything from here.'
        $out = Remove-FmBridgeRepetition -Text $said
        ([regex]::Matches($out, '(?i)cannot start or stop')).Count | Should -Be 1
        $out | Should -Match 'Three are under way'
    }

    It 'keeps a sentence that only shares a subject with the one before it' {
        $said = 'The sign-in fix is at 40 percent. The payment tests have not started yet.'
        $out = Remove-FmBridgeRepetition -Text $said
        $out | Should -Match 'sign-in fix'
        $out | Should -Match 'payment tests'
    }

    It 'puts the sentences back on the line they came from' {
        $said = "First line here. Still the first line.`nSecond line here."
        $out = Remove-FmBridgeRepetition -Text $said
        @($out -split "`n").Count | Should -Be 2
    }
}

Describe 'ConvertTo-FmBridgePlainText -Prose, on markdown' {

    # The page sets a reply as TEXT and the voice reads it aloud, so markdown
    # arrives as literal asterisks in both. Seen on screen, in a headed browser:
    # "- **lock-identity** - 75%, working".
    It 'leaves no emphasis markers on a screen that cannot render them' {
        $out = ConvertTo-FmBridgePlainText -Text "- **lock-identity** - 75%, working`n- __tg-route__ - 25%" -Prose -Keep @('lock-identity', 'tg-route')
        $out | Should -Not -Match '\*'
        $out | Should -Not -Match '__'
        $out | Should -Match 'lock-identity'
        $out | Should -Match 'tg-route'
    }

    It 'drops a heading marker but keeps the heading' {
        ConvertTo-FmBridgePlainText -Text '## Where things stand' -Prose | Should -Be 'Where things stand'
    }

    # A bullet reads as a list either way, and the shape of an answer is worth
    # keeping - the emphasis markers are the part that cannot render.
    It 'keeps the bullet itself' {
        ConvertTo-FmBridgePlainText -Text '- the sign-in fix is ready' -Prose | Should -Match '^- the sign-in fix'
    }
}

Describe 'ConvertTo-FmBridgePlainText, when the removal takes the subject' {

    # THE CAPTAIN ASKED WHY THE WORK SUMMARIES READ AS NONSENSE, and checking
    # each panel line against the record it came from turned up two kinds. Three
    # of the lines they cited were faithful - the evidence run's own worker wrote
    # them ungrammatically and this function only removed the label. These are
    # the other kind, and they are real: a removal at the HEAD of a line takes
    # the sentence's subject with it and leaves a fragment.
    #
    # A summary mangled into nonsense is worse than one carrying a little jargon:
    # jargon can be decoded, nonsense cannot, and the captain cannot tell a
    # mangled note from a worker that wrote nonsense.
    It 'leaves a noun where the name was, rather than a headless fragment' -ForEach @(
        @{ Line = 'working: [90%] FmLock.Tests.ps1 is through'; Want = 'That file is through' }
        @{ Line = 'working: [10%] tests/FmBridge.Tests.ps1 needs another case'; Want = 'That file needs another case' }
        @{ Line = 'working: [40%] fm/fix-signin is rebased'; Want = 'That branch is rebased' }
    ) {
        ConvertTo-FmBridgePlainText -Text $Line | Should -Be $Want
    }

    # "report at <path>" reads as a finished report when the path ends the line
    # and as a subject when the sentence carries on. One answer for both produced
    # "Report ready is ready".
    It 'reads a report path as a subject when the sentence carries on' {
        ConvertTo-FmBridgePlainText -Text 'done: report at docs/windows-e2e-evidence.md is ready' |
            Should -Be 'The report is ready'
    }

    It 'still reads a report path that ends the line as a finished report' {
        ConvertTo-FmBridgePlainText -Text 'done: report at data/scouts/auth.md' |
            Should -Be 'Report ready'
    }

    # A line that is nothing but a path has no sentence worth saving, so the
    # placeholder must not invent one.
    It 'does not invent a sentence for a line that was only a path' {
        ConvertTo-FmBridgePlainText -Text 'done: docs/foundation.md' | Should -Be ''
    }

    # A name in the MIDDLE of a line was never the problem, and giving it a
    # placeholder would add noise where the sentence already reads.
    It 'leaves a name mid-sentence removed rather than replaced' {
        ConvertTo-FmBridgePlainText -Text 'done: PR ready in worktree fm/tg-build' |
            Should -Be 'PR ready in local copy'
    }
}

Describe 'Test-FmBridgeVoiceAllowed' {

    # CAPTAIN IMPACT, AND THE REASON THIS FUNCTION EXISTS. The browser page called
    # speech synthesis on every reply, unconditionally. Copies of it driven for a
    # check have no window on screen, so the captain's machine spoke aloud twice
    # with no browser they could find and nothing to silence. AGENTS.md section 9
    # is explicit: the voice channel is off until the captain turns it on, and
    # nothing calls it by itself.
    #
    # THE FILE THIS READS CHANGED, and the properties below did not. It first
    # asked config/voice, which is the MACHINE's voice for fm-say and fm-ask and
    # has no control on the screen; the captain asked twice for a mute they can
    # see and press, so the page now owns config/bridge-voice and the two
    # channels stay separate. Off by default, absence means off, and a file that
    # says off is off - the same three assertions, against the switch the captain
    # can actually reach.
    BeforeAll {
        $script:VoiceHome = Join-Path $TestDrive 'voicehome'
        New-Item -ItemType Directory -Path (Join-Path $script:VoiceHome 'config') -Force | Out-Null
    }

    It 'is silent in a home that never switched the voice on' {
        Test-FmBridgeVoiceAllowed -HomePath $script:VoiceHome | Should -BeFalse
    }

    It 'speaks only once the captain has switched it on' {
        $gate = Join-Path (Join-Path $script:VoiceHome 'config') 'bridge-voice'
        try {
            $null = Set-FmBridgeVoice -State 'on' -HomePath $script:VoiceHome
            Test-FmBridgeVoiceAllowed -HomePath $script:VoiceHome | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $gate -Force -ErrorAction SilentlyContinue
        }
    }

    # Switching it back off must silence an open screen, not merely stop the next
    # one, so the stored word is read rather than the file's mere existence.
    It 'stays silent when the file is there but says off' {
        $gate = Join-Path (Join-Path $script:VoiceHome 'config') 'bridge-voice'
        try {
            $null = Set-FmBridgeVoice -State 'off' -HomePath $script:VoiceHome
            Test-FmBridgeVoiceAllowed -HomePath $script:VoiceHome | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $gate -Force -ErrorAction SilentlyContinue
        }
    }

    # Being wrong towards silence is a quiet screen; being wrong the other way is
    # the defect this exists for, on a machine whose owner cannot find the source.
    It 'stays silent rather than guessing when it cannot read the gate' {
        Mock -CommandName Get-FmBridgeVoice -ModuleName Firstmate -MockWith { throw 'unreadable' }
        Test-FmBridgeVoiceAllowed -HomePath $script:VoiceHome | Should -BeFalse
    }

    It 'stays silent when asked about a home that does not exist' {
        Test-FmBridgeVoiceAllowed -HomePath (Join-Path $TestDrive 'no-such-home') | Should -BeFalse
    }
}

# ---------------------------------------------------------------------------
# THE SPOKEN CHANNEL. The captain reported this screen sounding like "a robot
# without a brain" and named `##` and `**` being read out; then reported it
# still speaking with no browser they could see, which turned out to be a page
# driven headless. Everything below is the part of that which is ordinary text
# and file work, and it is tested here rather than left to a listen-and-see.
# ---------------------------------------------------------------------------

Describe 'ConvertTo-FmSpokenText' {

    # Every character an engine will happily pronounce out of text that was
    # written for a screen. The list is the contract.
    It 'leaves no markup or bare symbol in the result' {
        $written = @"
## Migration complete

**Two things** worth naming, and a ``code span``:

- The reporting view was pinned for ~90 seconds.
- Older rows carried local time - the import normalises them now.

| Window | Radar |
|--------|-------|
| 1366x768 | 442px |

Log: C:\Users\ADMIN\firstmate-win\state\run-2026-08-18.log
Diff: https://github.example.com/fleet/pull/1284/files
"@
        $spoken = ConvertTo-FmSpokenText -Text $written
        foreach ($mark in '#', '*', '_', '`', '|', '\', '<', '>', '[', ']', '{', '}', '~', '^', '=') {
            $spoken.Contains($mark) | Should -BeFalse -Because "'$mark' has no spoken form and an engine will say its name"
        }
        $spoken | Should -Not -Match 'https?:'
    }

    It 'keeps the words the markup was wrapped around' {
        $spoken = ConvertTo-FmSpokenText -Text '**Screen test passed** and the `checks` are green.'
        $spoken | Should -BeLike '*Screen test passed*'
        $spoken | Should -BeLike '*checks*'
    }

    # A path read out in full is the single most mechanical thing on this screen:
    # measured, a recognizer listening to the old output heard
    # "c: users admin firstmate state voicequality status".
    It 'says a path as its own name and nothing above it' {
        $spoken = ConvertTo-FmSpokenText -Text 'The log is at C:\Users\ADMIN\firstmate-win\state\voice-quality.status now.'
        $spoken | Should -BeLike '*voice quality dot status*'
        $spoken | Should -Not -BeLike '*Users*'
        $spoken | Should -Not -BeLike '*ADMIN*'
    }

    It 'says a slash path the same way' {
        (ConvertTo-FmSpokenText -Text 'See docs/windows-e2e-evidence.md for that.') |
            Should -BeLike '*windows e2e evidence dot md*'
        (ConvertTo-FmSpokenText -Text 'Run bin/fm-say.ps1 twice.') | Should -BeLike '*fm say dot ps1*'
    }

    # The other half of the same measurement: "https: double forward slash
    # github. com forward slash anthropic forward slash claude dash code".
    It 'says a URL as a link on a host' {
        $spoken = ConvertTo-FmSpokenText -Text 'Diff at https://github.com/anthropics/claude-code/pull/12.'
        $spoken | Should -BeLike '*a link on github dot com*'
        $spoken | Should -Not -BeLike '*slash*'
    }

    # The sentence AFTER a URL used to run straight on from it, because the
    # trailing full stop was eaten as part of the address.
    It 'leaves the full stop that ended the sentence, not the address' {
        (ConvertTo-FmSpokenText -Text 'Diff at https://example.com/x. Radar is fine.') |
            Should -BeLike '*dot com. Radar is fine.'
    }

    It 'is not fooled into reading and/or as a path' {
        (ConvertTo-FmSpokenText -Text 'Pick one and/or the other.') | Should -Be 'Pick one and or the other.'
    }

    It 'says the symbols that do mean something aloud' {
        (ConvertTo-FmSpokenText -Text 'A & B, 100% done, 1366x768, 442px, cost + tax, a -> b') |
            Should -Be 'A and B, 100 percent done, 1366 by 768, 442 pixels, cost plus tax, a to b.'
    }

    It 'drops a fenced code block whole' {
        $fenced = "It worked.`n`n" + '```powershell' + "`nGet-Thing -Force`n" + '```'
        (ConvertTo-FmSpokenText -Text $fenced) | Should -Be 'It worked.'
    }

    # A list read as one clause is the other half of sounding mechanical, so
    # each item ends as a sentence - and ONLY an item does. A soft-wrapped line
    # is not a sentence boundary and must not be given one.
    It 'ends a bullet as a sentence and a wrapped line as neither' {
        (ConvertTo-FmSpokenText -Text "- one`n- two") | Should -Be 'one. two.'
        (ConvertTo-FmSpokenText -Text "two   lines`nof news") | Should -Be 'two lines of news.'
    }

    # Measured on a real reply: "Path: voice quality dot status" ran straight
    # into "URL: a link on github dot com" with no pause at all.
    It 'separates two statements that only a line break divided' {
        (ConvertTo-FmSpokenText -Text "Path: run.log`nURL: https://example.com/a") |
            Should -BeLike '*run dot log. URL*'
    }

    It 'answers empty for empty, and never throws on one' {
        (ConvertTo-FmSpokenText -Text '') | Should -Be ''
        (ConvertTo-FmSpokenText -Text "   `n  ") | Should -Be ''
    }

    It 'ends with a full stop so the engine finishes the sentence' {
        (ConvertTo-FmSpokenText -Text 'Nothing is waiting on you') | Should -BeLike '*you.'
    }
}

Describe 'Split-FmBridgeReply' {

    It 'takes the marked line as the spoken form and keeps it off the screen' {
        $split = Split-FmBridgeReply -Reply "Four are running.`n`nSPOKEN: Four jobs, nothing waiting."
        $split.Marked | Should -BeTrue
        $split.Spoken | Should -Be 'Four jobs, nothing waiting.'
        $split.Written | Should -Be 'Four are running.'
        $split.Written | Should -Not -BeLike '*SPOKEN*'
    }

    # THE MARKER MUST SURVIVE UNTIL IT IS READ. The translator strips a leading
    # `word:` state prefix and its match is case-insensitive, so a reply
    # translated before it was split would have lost the line naming what to say
    # and fallen back to a derived lead every time.
    It 'reads the marker before the translator could eat it' {
        $split = Split-FmBridgeReply -Reply "done: the fix is ready`nSPOKEN: The fix is ready for review."
        $split.Marked | Should -BeTrue
        $split.Spoken | Should -Be 'The fix is ready for review.'
    }

    # Both halves go through the panel's translator, and the spoken one obeys it
    # harder - AGENTS.md section 9 - because the captain cannot re-read a spoken
    # sentence to work out what a word meant.
    It 'translates what is read and what is said, not just what is read' {
        $split = Split-FmBridgeReply -Reply "done: PR ready in worktree fm/x`nSPOKEN: The crewmate finished in its worktree."
        $split.Written | Should -Not -Match '\bworktree\b'
        $split.Spoken | Should -Not -Match '\bworktree\b'
        $split.Spoken | Should -Not -Match '\bcrewmate\b'
    }

    It 'prepares the marked line too, because a model still reaches for a path' {
        $split = Split-FmBridgeReply -Reply "Done.`nSPOKEN: **Done** - see C:\logs\run-1.log"
        $split.Spoken | Should -Be 'Done, see run 1 dot log.'
    }

    It 'takes the last marker when a reply carries two' {
        (Split-FmBridgeReply -Reply "x`nSPOKEN: first`nSPOKEN: second").Spoken | Should -Be 'second.'
    }

    # An older session, a resumed one, or a turn that simply forgot still has to
    # be speakable - and reading the whole reply aloud is the thing being fixed.
    It 'derives a spoken form when the reply carries no marker' {
        $split = Split-FmBridgeReply -Reply "**Migration complete.** The checks are green.`n`n- one`n- two"
        $split.Marked | Should -BeFalse
        $split.Spoken | Should -Be 'Migration complete. The checks are green.'
        $split.Written | Should -BeLike '*Migration complete*'
    }

    It 'bounds a derived form to what can be heard at one hearing' {
        $long = 'This sentence is quite long and says a great deal about very little indeed. ' * 6
        $split = Split-FmBridgeReply -Reply $long
        # Get-FmVoiceMaxLength owns the number and is internal, so this asserts
        # the outcome it exists for: short enough to hold in your head at first
        # hearing, rather than a paragraph read at you.
        $split.Spoken.Length | Should -BeLessOrEqual 220
    }

    It 'answers empty for an empty turn' {
        $split = Split-FmBridgeReply -Reply ''
        $split.Written | Should -Be ''
        $split.Spoken | Should -Be ''
    }
}

Describe 'Get-FmBridgeSpeechContract' {

    It 'asks for the marker Split-FmBridgeReply reads' {
        Get-FmBridgeSpeechContract | Should -BeLike '*SPOKEN:*'
    }

    # One owner: what a spoken message may SAY is AGENTS.md section 9's rule,
    # and two copies of it would drift the moment one was edited.
    It 'points at the rule rather than restating it' {
        Get-FmBridgeSpeechContract | Should -BeLike '*section 9*'
    }

    # The soft half of the guard over the machine's own voice.
    It 'tells the session the machine voice is not its to use' {
        Get-FmBridgeSpeechContract | Should -BeLike '*fm-say*'
    }
}

Describe 'the bridge screen settings' {

    BeforeEach {
        $script:SettingsHome = Join-Path ([IO.Path]::GetTempPath()) ("fm-bridge-cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:SettingsHome 'config') -Force
    }
    AfterEach {
        if (Test-Path -LiteralPath $script:SettingsHome) {
            Remove-Item -LiteralPath $script:SettingsHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # PUSH AND OFF ARE NOT ARBITRARY DEFAULTS. One holds the microphone shut
    # until a hand is on it; the other keeps the machine quiet until it is
    # asked. Both are the state the captain has to opt OUT of.
    It 'defaults to push to talk with no file at all' {
        Get-FmListenMode -HomePath $script:SettingsHome | Should -Be 'push'
    }

    It 'defaults to a silent screen with no file at all' {
        Get-FmBridgeVoice -HomePath $script:SettingsHome | Should -Be 'off'
    }

    It 'remembers the mode the captain chose' {
        (Set-FmListenMode -Mode 'continuous' -HomePath $script:SettingsHome).Ok | Should -BeTrue
        Get-FmListenMode -HomePath $script:SettingsHome | Should -Be 'continuous'
    }

    It 'remembers that the screen was told to speak' {
        (Set-FmBridgeVoice -State 'on' -HomePath $script:SettingsHome).Ok | Should -BeTrue
        Get-FmBridgeVoice -HomePath $script:SettingsHome | Should -Be 'on'
    }

    It 'writes the file the shared contract requires: no BOM, LF only' {
        $null = Set-FmListenMode -Mode 'continuous' -HomePath $script:SettingsHome
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:SettingsHome 'config/listen-mode'))
        $bytes[0] | Should -Not -Be 0xEF
        $bytes | Should -Not -Contain 13
        $bytes[-1] | Should -Be 10
    }

    # A word the reader does not know is treated as the safe default, so writing
    # it would leave the screen saying one thing and the machine doing another.
    It 'refuses a mode it does not know rather than recording it' {
        $verdict = Set-FmListenMode -Mode 'always' -HomePath $script:SettingsHome
        $verdict.Ok | Should -BeFalse
        $verdict.Error | Should -Not -BeNullOrEmpty
        $verdict.Mode | Should -Be 'push'
        Test-Path -LiteralPath (Join-Path $script:SettingsHome 'config/listen-mode') | Should -BeFalse
    }

    It 'refuses a voice setting it does not know rather than recording it' {
        $verdict = Set-FmBridgeVoice -State 'maybe' -HomePath $script:SettingsHome
        $verdict.Ok | Should -BeFalse
        $verdict.State | Should -Be 'off'
    }

    It 'reads a damaged file as the safe default, never as the other one' {
        Set-Content -LiteralPath (Join-Path $script:SettingsHome 'config/listen-mode') -Value 'contnuous'
        Set-Content -LiteralPath (Join-Path $script:SettingsHome 'config/bridge-voice') -Value 'oon'
        Get-FmListenMode -HomePath $script:SettingsHome | Should -Be 'push'
        Get-FmBridgeVoice -HomePath $script:SettingsHome | Should -Be 'off'
    }

    It 'allows the comments and blank lines every other config file allows' {
        Set-Content -LiteralPath (Join-Path $script:SettingsHome 'config/listen-mode') `
            -Value "# how the microphone listens`n`ncontinuous"
        Get-FmListenMode -HomePath $script:SettingsHome | Should -Be 'continuous'
    }
}

Describe 'Get-FmStableCheckout' {

    # The bridge told the captain to point their dictation app at a file inside a
    # WORKER's copy of the checkout - a directory deleted when that work
    # finishes. Observed on their screen.
    It 'names a checkout that carries the file the instruction is about' {
        $answer = Get-FmStableCheckout -Root $script:Root -RequiredFile 'bin/fm-dictate.cmd'
        $answer | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $answer 'bin/fm-dictate.cmd') | Should -BeTrue
    }

    # A guess at a directory that does not exist is worse than a path that is
    # merely short-lived, so the required file has to actually be there.
    It 'keeps the checkout it was given when the file it needs is not there' {
        Get-FmStableCheckout -Root $script:Root -RequiredFile 'bin/no-such-thing.cmd' |
            Should -Be $script:Root
    }

    It 'answers instead of throwing for a path that is not a checkout at all' {
        $notARepo = Join-Path ([IO.Path]::GetTempPath()) ("fm-not-a-repo-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $notARepo -Force
        try { Get-FmStableCheckout -Root $notARepo | Should -Be $notARepo }
        finally { Remove-Item -LiteralPath $notARepo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'answers empty for empty rather than guessing' {
        Get-FmStableCheckout -Root '' | Should -Be ''
    }
}

Describe 'the identity the turn prompt carries' {

    BeforeAll {
        $script:IdReading = [pscustomobject]@{
            At        = '09:15:00'
            Tasks     = @()
            Decisions = @()
            Activity  = @()
            House     = @()
            Identity  = 'I am a firstmate, made for Adit by Dhaval Bhalodia, to help you work on the Adit app products.'
        }
    }

    # THE DEFECT. Asked who it was, the screen answered with the vendor of the
    # model behind it. The fix is not a reply to that question - it is a fact the
    # session is holding before the question arrives.
    It 'puts this home identity in the prompt' {
        $prompt = New-FmBridgeTurnPrompt -Text 'who are you and what you can do ?' -Fleet $script:IdReading
        $prompt | Should -Match 'made for Adit by Dhaval Bhalodia'
        $prompt | Should -Match '(?i)who you are'
    }

    # NO TRIGGER, AND THAT IS THE DESIGN. The identity is there whatever the
    # captain typed, so every phrasing of the question reaches it - including
    # the ones nobody has thought of. A prompt that only carried it when it
    # recognised the question would be a phrase list, and this file has watched
    # a phrase list fall one defect behind twice.
    It 'carries it whatever the captain asked' -ForEach @(
        @{ Asked = 'who are you and what you can do ?' }
        @{ Asked = 'what are you' }
        @{ Asked = 'what can you do' }
        @{ Asked = 'what do you do' }
        @{ Asked = 'who made you?' }
        @{ Asked = 'whose assistant are you' }
        @{ Asked = 'tell me about yourself' }
        @{ Asked = 'hello' }
        @{ Asked = 'what is happening' }
    ) {
        $prompt = New-FmBridgeTurnPrompt -Text $Asked -Fleet $script:IdReading
        $prompt | Should -Match 'made for Adit by Dhaval Bhalodia'
    }

    # BOTH HALVES. The answer that prompted this got the capabilities right and
    # the identity wrong; swapping one wrong half for one right half would still
    # be half an answer to a question that plainly asked for two.
    It 'asks for the capability half as well as the identity half' {
        $prompt = New-FmBridgeTurnPrompt -Text 'who are you and what you can do ?' -Fleet $script:IdReading
        $prompt | Should -Match '(?i)what you can do for them'
    }

    # And it says which answer is wrong, since that is the one the screen gave.
    It 'rules out answering as the model behind it' {
        $prompt = New-FmBridgeTurnPrompt -Text 'who are you' -Fleet $script:IdReading
        $prompt | Should -Match '(?i)never with the name of a model'
    }

    # A HOME THAT SET NOTHING gets a prompt with no identity block rather than a
    # prompt with a hole in it, and everything else about the turn is unchanged.
    It 'leaves no blank behind when the home carries no identity' {
        $bare = [pscustomobject]@{
            At = '09:15:00'; Tasks = @(); Decisions = @(); Activity = @(); House = @(); Identity = ''
        }
        $prompt = New-FmBridgeTurnPrompt -Text 'who are you' -Fleet $bare
        $prompt | Should -Not -Match '(?i)WHO YOU ARE'
        $prompt | Should -Not -Match '\[\s*\]'
        $prompt | Should -Match '(?i)THE SCREEN BESIDE YOUR REPLY'
        $prompt | Should -Match 'who are you'
    }

    # A reading from before this existed has no Identity property at all, and
    # the prompt must not throw under Set-StrictMode when it looks.
    It 'survives a reading that carries no identity property' {
        $old = [pscustomobject]@{
            At = '09:15:00'; Tasks = @(); Decisions = @(); Activity = @(); House = @()
        }
        { New-FmBridgeTurnPrompt -Text 'who are you' -Fleet $old } | Should -Not -Throw
    }
}

Describe 'Initialize-FmBridgeWorkspace' {
    # THE FIRST-RUN PANEL RENDERS `Error` VERBATIM (ui/bridge.html,
    # `setupErr.textContent = r.error`), so every refusal here is a sentence
    # written for the captain. What sent this area to a fresh VM and back was
    # the one refusal that was not:
    #
    #     Exception calling "WriteAllText" with "3" argument(s): "Access to the
    #     path 'C:\Users\Adit\firstmate\.fm-home' is denied."
    #
    # in red, on the panel, naming a path the captain had never typed - it is
    # where firstmate itself was installed, not the home they asked for.

    BeforeEach {
        $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("fm-ws-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:Checkout = Join-Path $script:Sandbox 'checkout'
        $script:Home_ = Join-Path $script:Sandbox 'firstmate'
        $null = New-Item -ItemType Directory -Path $script:Checkout -Force
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'creates the home layout and both records the entry points read' {
        $result = Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path $script:Home_ -Confirm:$false
        $result.Ok | Should -BeTrue
        $result.Error | Should -BeNullOrEmpty
        foreach ($d in @('config', 'data', 'projects', 'state')) {
            Test-Path -LiteralPath (Join-Path $script:Home_ $d) -PathType Container | Should -BeTrue
        }
        # The contract these two carry is what lets an entry point resolve the
        # home with no profile and no environment. Neither may drift.
        [System.IO.File]::ReadAllText((Join-Path $script:Checkout '.fm-home')) | Should -Be $script:Home_
        ([System.IO.File]::ReadAllText((Join-Path $script:Checkout '.fm-workspace'))).Trim() | Should -Be $script:Home_
        Get-FmBridgeWorkspace -RepoRoot $script:Checkout | Should -Be $script:Home_
        Test-FmBridgeConfigured -RepoRoot $script:Checkout | Should -BeTrue
    }

    It 'names a fresh workspace with a backend this port can actually drive' {
        $null = Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path $script:Home_ -Confirm:$false
        ([System.IO.File]::ReadAllText((Join-Path $script:Home_ 'config' 'backend'))).Trim() | Should -Be 'herdr'
    }

    Context 'when the checkout itself cannot be written to' {
        # The captain's shape, reproduced without needing a second Windows
        # account: a DIRECTORY standing where the record's file goes makes .NET
        # raise the identical UnauthorizedAccessException, wrapped in the
        # identical MethodInvocationException, with the identical message.
        BeforeEach {
            $null = New-Item -ItemType Directory -Path (Join-Path $script:Checkout '.fm-home') -Force
            $script:Refused = Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path $script:Home_ -Confirm:$false
        }

        It 'refuses, rather than reporting a setup that did not happen' {
            $script:Refused.Ok | Should -BeFalse
        }

        It 'never puts a .NET exception on the panel' {
            $script:Refused.Error | Should -Not -Match 'Exception calling'
            $script:Refused.Error | Should -Not -Match 'WriteAllText'
            $script:Refused.Error | Should -Not -Match 'argument\(s\)'
        }

        It 'names the folder that is actually wrong, and a way forward' {
            # The captain typed the home; the folder that refused the write is
            # the OTHER one, and saying so is the whole difference between a
            # message they can act on and one they cannot.
            #
            # THE NEXT STEP DIFFERS BY WHOSE FOLDER IT IS - move it, or allow
            # firstmate in the one they already own - and the two cases are
            # pinned separately below. What EVERY refusal here owes them is one:
            # this fixture sits under TEMP, inside this account's own profile.
            $script:Refused.Error | Should -Match ([regex]::Escape($script:Checkout))
            $script:Refused.Error | Should -Match '(?i)install\.ps1|press SET IT UP'
        }

        It 'does not answer with the workaround, which installs for the wrong account' {
            $script:Refused.Error | Should -Not -Match '(?i)as administrator'
        }

        It 'keeps the raw text for whoever has to diagnose it, off the panel' {
            # Plain for the captain is not the same as lost. bin/fm-bridge.ps1
            # writes this to its own window.
            $script:Refused.Detail | Should -Match 'is denied'
        }

        It 'does not blame another account for a folder that is the captain''s own' {
            # SECTION 34 OF THE EVIDENCE FILE IS WHY THIS EXISTS. A refused
            # write was once read as a permission problem between two users,
            # briefed as a task, and disproved by the captain running the whole
            # thing as ONE user. "Access is denied" gets completed with the most
            # familiar explanation that fits, and this is the one place that
            # completion would now be written down for them to read.
            $inMine = Join-Path $env:USERPROFILE ("fm-own-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $inMine '.fm-home') -Force
            try {
                $result = Initialize-FmBridgeWorkspace -RepoRoot $inMine -Path $script:Home_ -Confirm:$false
                $result.Ok | Should -BeFalse
                $result.Error | Should -Match '(?i)already yours'
                $result.Error | Should -Not -Match '(?i)move that folder'
            } finally { Remove-Item -LiteralPath $inMine -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'tells a captain whose checkout is NOT theirs to move it' {
            # C:\Users\Public is writable and is nobody's profile, which is the
            # shape the captain reported without needing a second account.
            $notMine = Join-Path $env:PUBLIC ("fm-other-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path (Join-Path $notMine '.fm-home') -Force
            try {
                $result = Initialize-FmBridgeWorkspace -RepoRoot $notMine -Path $script:Home_ -Confirm:$false
                $result.Ok | Should -BeFalse
                $result.Error | Should -Match '(?i)move that folder'
                $result.Error | Should -Not -Match '(?i)already yours'
            } finally { Remove-Item -LiteralPath $notMine -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'is honest that the workspace itself was made' {
            Test-Path -LiteralPath (Join-Path $script:Home_ 'state') -PathType Container | Should -BeTrue
            $script:Refused.Error | Should -Match '(?i)workspace is ready'
        }
    }

    Context 'the refusals it already made, which must keep their sentences' {
        It 'refuses an empty path' {
            (Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path '  ' -Confirm:$false).Error |
                Should -Be 'no path given'
        }

        It 'refuses a relative path, and says what a full one looks like' {
            $result = Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path 'firstmate' -Confirm:$false
            $result.Ok | Should -BeFalse
            $result.Error | Should -Match 'full path'
        }

        It 'refuses a path that is a file' {
            $file = Join-Path $script:Sandbox 'a-file'
            [System.IO.File]::WriteAllText($file, 'x')
            (Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path $file -Confirm:$false).Error |
                Should -Be 'that path is a file'
        }

        It 'carries Detail on every answer, so a strict-mode caller can read it' {
            # bin/fm-bridge.ps1 runs under Set-StrictMode -Version Latest and
            # reads .Detail on whatever comes back; a shape that only sometimes
            # has the field would throw there instead of answering the captain.
            foreach ($path in @('  ', 'firstmate', $script:Home_)) {
                $result = Initialize-FmBridgeWorkspace -RepoRoot $script:Checkout -Path $path -Confirm:$false
                { $result.Detail } | Should -Not -Throw
            }
        }
    }
}
