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
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force
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

    BeforeAll {
        $script:SpeechTmp = Join-Path ([IO.Path]::GetTempPath()) ("fm-speech-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:SpeechTmp
        $script:Hook = Join-Path $script:SpeechTmp 'fm-dictate.cmd'
        Set-Content -LiteralPath $script:Hook -Value '@echo off' -NoNewline

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
        $file = script:New-SettingsFixture -Method 'external_script' -ScriptPath $script:Hook -Name 'wired'
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.HandsOver | Should -BeTrue
        # Nothing left to ask the captain for, so nothing is asked.
        $s.Setup | Should -BeNullOrEmpty
    }

    # THE CASE THAT IS ACTUALLY LIVE ON THE CAPTAIN'S MACHINE, and the reason this
    # reads the setting instead of assuming it: with the app typing where the
    # cursor is, a dictated line only arrives when the right window has focus.
    It 'says an engine that types where the cursor is has not been wired' {
        $file = script:New-SettingsFixture -Method 'direct' -ScriptPath $null -Name 'direct'
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
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
        $file = script:New-SettingsFixture -Method $Method -ScriptPath $Path -Name ('half' + $Method + ($Path -replace '\W', ''))
        (Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook).HandsOver | Should -BeFalse
    }

    It 'treats a settings file it cannot read as not wired, rather than throwing' -ForEach @(
        @{ Body = 'not json at all {{{' }
        @{ Body = '' }
        @{ Body = '{"settings":null}' }
    ) {
        $file = Join-Path $script:SpeechTmp 'broken.json'
        Set-Content -LiteralPath $file -Value $Body
        $s = Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook
        $s.HandsOver | Should -BeFalse
        $s.Detail | Should -Not -BeNullOrEmpty
    }

    It 'survives a settings file that is not there' {
        $s = Get-FmSpeechEngineStatus -SettingsPath (Join-Path $script:SpeechTmp 'absent.json') -HookPath $script:Hook
        $s.HandsOver | Should -BeFalse
    }

    It 'says so plainly when no dictation app is installed at all' {
        Mock -CommandName Get-FmSpeechEngine -MockWith { '' } -ModuleName Firstmate
        $s = Get-FmSpeechEngineStatus -HookPath $script:Hook
        $s.Installed | Should -BeFalse
        $s.Running | Should -BeFalse
        $s.Detail | Should -Match 'installed'
    }

    # AGENTS.md section 9 binds on this line exactly as in chat: the bridge prints
    # it and the page shows it. The PATH in Setup is the exception section 9 itself
    # allows - the captain needs it to act - so only Detail is held to the rule.
    It 'describes the state in the captain nouns, never in machinery' -ForEach @(
        @{ Method = 'external_script'; Path = 'fm-dictate.cmd' }
        @{ Method = 'direct'; Path = $null }
    ) {
        $file = script:New-SettingsFixture -Method $Method -ScriptPath $Path -Name ('nouns' + $Method)
        $detail = (Get-FmSpeechEngineStatus -SettingsPath $file -HookPath $script:Hook).Detail
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
        $fake = Join-Path ([IO.Path]::GetTempPath()) ('fm-no-such-engine-' + [guid]::NewGuid().ToString('N') + '.exe')
        Set-Content -LiteralPath $fake -Value 'not an engine' -NoNewline
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

Describe 'Test-FmBridgeSessionCanAct' {

    BeforeAll {
        $script:CanActHome = Join-Path $TestDrive 'home'
        New-Item -ItemType Directory -Path (Join-Path $script:CanActHome 'state') -Force | Out-Null
    }

    It 'says no when nothing holds this home' {
        Test-FmBridgeSessionCanAct -HomePath $script:CanActHome -SessionProcessId 4242 | Should -BeFalse
    }

    It 'says no when it was given no session at all' {
        Test-FmBridgeSessionCanAct -HomePath $script:CanActHome | Should -BeFalse
    }

    It 'says yes only when the session this bridge hosts is the holder' {
        Mock -CommandName Get-FmSessionLockStatus -ModuleName Firstmate -MockWith {
            [pscustomobject]@{ State = 'held'; ProcessId = 4242; Text = '' }
        }
        Test-FmBridgeSessionCanAct -HomePath $script:CanActHome -SessionProcessId 4242 | Should -BeTrue
        Test-FmBridgeSessionCanAct -HomePath $script:CanActHome -SessionProcessId 25876 | Should -BeFalse
    }

    # Promising the captain an action this cannot deliver is worse than
    # understating what it can do, so anything it could not read counts as no.
    It 'says no rather than guessing when it cannot read who holds this home' {
        Mock -CommandName Get-FmSessionLockStatus -ModuleName Firstmate -MockWith { throw 'unreadable' }
        Test-FmBridgeSessionCanAct -HomePath $script:CanActHome -SessionProcessId 4242 | Should -BeFalse
    }
}

Describe 'Get-FmBridgeRoute' {

    # THE CAPTAIN THREW OUT THE SENTENCE THIS REPLACES. What used to be here was
    # a limitation stated plainly - "I can see the work but cannot start or stop
    # anything from here" - and their ruling was that a system worth talking to
    # never says that at all; it gives the way to get the thing done. A softer
    # phrasing of the same confession would have been the same mistake.
    It 'says nothing at all when the screen can act' {
        Get-FmBridgeRoute -CanAct $true | Should -Be ''
    }

    It 'gives a route, never a refusal' {
        $route = Get-FmBridgeRoute -CanAct $false
        $route | Should -Match '(?i)firstmate window'
        $route | Should -Not -Match "(?i)\bcan(?:not|n't)\b"
        $route | Should -Not -Match '(?i)\bunable\b'
        $route | Should -Not -Match '(?i)\bsorry\b'
    }

    It 'keeps machinery out of the route as well' {
        $route = Get-FmBridgeRoute -CanAct $false
        foreach ($word in @('lock', 'read-only', 'pid', 'dispatch', 'merge', 'checkout', 'worktree')) {
            $route | Should -Not -Match ('\b' + [regex]::Escape($word) + '\b')
        }
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
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -CanAct $false
        $prompt | Should -Match '(?i)NEVER answer with something you cannot do'
        $prompt | Should -Match '(?i)answer with how it gets done'
        $prompt | Should -Match '(?i)say what IS'
    }

    # "can you do it yourself? yes or no" came back as "No." on screen -
    # responsive to the letter, and still a limitation standing alone as the
    # whole reply. A yes-or-no is the captain asking for brevity, not for a dead
    # end.
    It 'holds the rule even when the captain asks for a yes or a no' {
        $prompt = New-FmBridgeTurnPrompt -Text 'can you do it yourself? yes or no.' -Fleet $script:EmptyFleet -CanAct $false
        $prompt | Should -Match '(?i)even when the captain asks for a yes or a no'
        $prompt | Should -Match '(?i)bare no'
    }

    It 'carries the real route, not a polite deferral' {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -CanAct $false
        $prompt | Should -Match ([regex]::Escape((Get-FmBridgeRoute -CanAct $false)))
    }

    It 'leaves the route out entirely when the screen can act' {
        $prompt = New-FmBridgeTurnPrompt -Text 'start the payment tests' -Fleet $script:EmptyFleet -CanAct $true
        $prompt | Should -Not -Match '(?i)firstmate window the captain'
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
