#requires -Version 7.0
Set-StrictMode -Version Latest

# The browser is the surface the captain actually reads, and until this file
# existed it was the only major area with no tests of its own - 42 test files,
# none for the bridge. That is not a coincidence: the jargon leak these tests
# now pin was found by hand, on screen, months after it shipped, because no
# check ever looked.
#
# SCOPE, STATED HONESTLY. This covers the translation seam and the vocabulary
# table. The HTTP surface - the token guard, the Origin check, the turn
# resync - is proven by hand against a live bridge and is NOT covered here;
# those need a running listener and a live engine. That gap is real and is
# recorded rather than papered over.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force
}

Describe 'ConvertTo-FmBridgePlainText' {

    # AGENTS.md section 9 forbids these reaching the captain. The list is the
    # contract; a word added there belongs here the same day.
    BeforeAll {
        $script:Banned = @(
            'worktree', 'checkout', 'crewmate', 'secondmate', 'teardown', 'harness',
            'herdr', 'treehouse', 'orca', 'cmux', 'watcher', 'heartbeat', 'stale',
            'needs-decision', 'ask-user', 'yolo', 'no-mistakes', 'local-only',
            'direct-PR', 'wedged', 'backend', 'adapter', 'fail-closed', 'fails closed'
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
            $out | Should -Not -Match ([regex]::Escape($word)) -Because "section 9 forbids '$word' reaching the captain, and '$Line' produced '$out'"
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
