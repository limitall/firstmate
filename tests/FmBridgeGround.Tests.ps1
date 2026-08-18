#requires -Version 7.0
Set-StrictMode -Version Latest

# The screen invented work and recommended acting on it. Not a leak of internal
# wording - a fabricated piece of work, named, with a percentage, with a course
# of action attached:
#
#     "Halting lock-identity at its 75 percent and putting the payment tests in
#      its place is a call you make in the firstmate window on this machine...
#      tg-route stays at 25 percent past the docs, ui-readonly at 55 percent
#      past the bin, and the checks keep running."
#
# There are no payment tests. Every one of those figures was wrong. The panel
# beside that reply was reading the durable records and was right the whole
# time.
#
# WHAT THESE TESTS ARE FOR, and it is not "the assistant behaves". They pin the
# COURIER: the reply is checked against the records after the session produces
# it and before the captain sees it, so nothing here depends on a model having
# chosen to follow an instruction. Every case below drives the gate with text
# directly, which is exactly the point - a gate that only worked on well-behaved
# input would guarantee nothing.
#
# ONE THING IS DELIBERATELY NOT TESTED HERE: whether a live session invents.
# That is a property of a model on a given day, not of this code, and a suite
# that asserted it would be flaky by construction. What is provable is that
# invention cannot be DELIVERED, and that is what every case here asserts. The
# live run with fixture text present is in docs/windows-e2e-evidence.md.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $env:PSModulePath = "$(Join-Path $script:Root 'module')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Import-Module Firstmate -Force

    # The records as they actually stood the day the screen invented work, so
    # every name and figure below is the real one rather than a convenient one.
    function script:New-Ground {
        param([switch]$Empty, [switch]$NoCapacity)
        $tasks = if ($Empty) { @() } else {
            @(
                [pscustomobject]@{ Id = 'finished-run-stall'; Percent = 100; State = 'done'; Note = 'Ready' }
                [pscustomobject]@{ Id = 'lock-identity'; Percent = 75; State = 'working'
                    Note = 'Fix corrected and proven: 4800 increments, zero mis-pairings, back-out confirmed, full suite running'
                }
                [pscustomobject]@{ Id = 'ui-invents'; Percent = 5; State = 'working'
                    Note = 'Local copy verified, reading the bridge reply path'
                }
                [pscustomobject]@{ Id = 'ui-readonly'; Percent = 65; State = 'working'
                    Note = 'Fix implemented, panel and reply now agree in a real browser'
                }
                [pscustomobject]@{ Id = 'voice-quality'; Percent = 20; State = 'working'
                    Note = 'Reproduced on the real screen, building the listening-mode setting'
                }
            )
        }
        $capacity = if ($NoCapacity) {
            [pscustomobject]@{ Measured = $false; Detail = 'not measured'; Windows = @() }
        } else {
            [pscustomobject]@{ Measured = $true; Detail = ''; Windows = @(
                    [pscustomobject]@{ Name = 'Session'; Percent = 58 }
                    [pscustomobject]@{ Name = 'Week left'; Percent = 53 }
                )
            }
        }
        Get-FmBridgeGround -Fleet ([pscustomobject]@{
                Tasks     = $tasks
                Decisions = @()
                Activity  = @()
                House     = @()
                Capacity  = $capacity
                At        = '14:02:11'
            })
    }
}

Describe 'ConvertTo-FmBridgeWorkKey' {

    # The record spells it with hyphens, the panel prints it with spaces, and a
    # sentence capitalises it. Three spellings of one piece of work, and a gate
    # that treated them as three would call two of them invention.
    It 'reads every spelling of one name as the same name' -ForEach @(
        @{ Spelling = 'lock-identity' }, @{ Spelling = 'lock identity' }
        @{ Spelling = 'Lock Identity' }, @{ Spelling = 'LOCK IDENTITY' }
        @{ Spelling = 'lock_identity' }
    ) {
        ConvertTo-FmBridgeWorkKey -Text $Spelling | Should -Be 'lock-identity'
    }

    It 'has nothing to say about nothing' -ForEach @(
        @{ Text = '' }, @{ Text = '   ' }, @{ Text = '---' }
    ) {
        ConvertTo-FmBridgeWorkKey -Text $Text | Should -Be ''
    }
}

Describe 'Get-FmBridgeGround' {

    It 'carries every name and every figure the records carry' {
        $g = script:New-Ground
        foreach ($name in @('lock-identity', 'ui-readonly', 'voice-quality', 'ui-invents', 'finished-run-stall')) {
            $g.Names.Contains($name) | Should -BeTrue -Because "the records carry $name"
        }
        foreach ($pct in @(100, 75, 65, 20, 5)) { $g.Percents.Contains($pct) | Should -BeTrue }
        $g.PercentOf['lock-identity'] | Should -Be 75
    }

    # The name the whole task is about. It has to be absent for the right
    # reason: not filtered out, never present.
    It 'carries nothing the records do not carry' {
        $g = script:New-Ground
        $g.Names.Contains('payment-tests') | Should -BeFalse
        $g.Names.Contains('tg-route') | Should -BeFalse
        $g.Words.Contains('payment') | Should -BeFalse
        $g.Percents.Contains(25) | Should -BeFalse
        $g.Percents.Contains(55) | Should -BeFalse
    }

    # A measured figure is quotable wherever it was measured. An unmeasured one
    # is not quotable anywhere, which is the same rule stated twice.
    It 'takes the capacity figures when they were measured' {
        (script:New-Ground).Percents.Contains(58) | Should -BeTrue
    }

    It 'takes no capacity figure when nothing measured one' {
        $g = script:New-Ground -NoCapacity
        @($g.Capacity).Count | Should -Be 0
        $g.Percents.Contains(58) | Should -BeFalse
    }

    It 'survives records with no work in them at all' {
        $g = script:New-Ground -Empty
        @($g.Rows).Count | Should -Be 0
        @($g.Names).Count | Should -Be 0
    }
}

Describe 'Test-FmBridgeGrounded' {

    BeforeAll { $script:G = script:New-Ground }

    # THE REPLY THIS AREA EXISTS FOR, refused in full, with each of its four
    # untrue claims named separately rather than the whole thing rejected as
    # generally suspect.
    It 'refuses the reply that started this, and says which claims it could not back' {
        $incident = 'Halting lock-identity at its 75 percent and putting the payment tests in its ' +
        'place is a call you make in the firstmate window on this machine - ask there to stop ' +
        'lock-identity and to begin the payment tests. Nothing else changes: tg-route stays at ' +
        '25 percent past the docs, ui-readonly at 55 percent past the bin.'
        $v = Test-FmBridgeGrounded -Text $incident -Ground $script:G -Asked 'What is happening?'

        $v.Grounded | Should -BeFalse
        ($v.Unsubstantiated -join ' | ') | Should -Match 'payment tests'
        ($v.Unsubstantiated -join ' | ') | Should -Match 'tg-route'
        ($v.Unsubstantiated -join ' | ') | Should -Match '25%'
        ($v.Unsubstantiated -join ' | ') | Should -Match '55%'
    }

    # The other half, and the half that decides whether this is usable: a true
    # answer must pass untouched, including the table shape a real reply used.
    It 'passes a reply that says only what the records say' {
        $good = @'
Five runs are under way and nothing is waiting on you.

| Run | % | Where it stands |
|---|---|---|
| FINISHED RUN STALL | 100% | Ready |
| LOCK IDENTITY | 75% | Fix corrected and proven |
| UI READONLY | 65% | Panel and reply now agree in a real browser |
| VOICE QUALITY | 20% | Reproduced on the real screen |
| UI INVENTS | 5% | Reading the bridge reply path |
'@
        (Test-FmBridgeGrounded -Text $good -Ground $script:G -Asked 'What is happening?').Grounded |
            Should -BeTrue
    }

    # These read as measurements and were literals typed into the page. The
    # assistant read them off the screen and repeated them back as fact. The
    # first is the one a percentage-only check misses: "1730 pass" is a count,
    # and it had been on that screen unchanged since the day it was built.
    It 'refuses a figure nothing measured' -ForEach @(
        @{ Reply = 'The suite is green: 1730 pass, 0 failed, 25 not run.'; Bad = '1730' }
        @{ Reply = 'The suite is green: 1730 pass, 0 failed, 25 not run.'; Bad = ': 25' }
        @{ Reply = 'Capacity: 79% of the week left.'; Bad = '79%' }
        @{ Reply = 'You are 82 percent through this session.'; Bad = '82%' }
        @{ Reply = 'The radar dropped from 442px to 241px at that width.'; Bad = '442' }
    ) {
        $v = Test-FmBridgeGrounded -Text $Reply -Ground $script:G -Asked 'How much is left?'
        $v.Grounded | Should -BeFalse
        ($v.Unsubstantiated -join ' | ') | Should -Match ([regex]::Escape($Bad))
    }

    # The other side of the number rule. A worker measured 4800 increments and
    # wrote it into its own record; repeating that back is reporting, not
    # inventing, and a gate that refused it would make the screen useless.
    It 'passes a figure a worker measured and recorded' {
        (Test-FmBridgeGrounded -Ground $script:G -Asked 'How is the lock work?' `
                -Text 'Lock identity is at 75% - 4800 increments, zero mis-pairings.').Grounded |
            Should -BeTrue
    }

    # English counts in small numbers and a numbered list numbers its own items.
    # Holding those to a record would refuse "1." at the start of a line, and an
    # invented measurement is never 3 - it is 1730.
    It 'lets a reply count and number things' {
        $listed = "Three things:`n1. Lock identity, at 75%.`n2. Ui readonly, at 65%.`n3. Nothing else."
        (Test-FmBridgeGrounded -Text $listed -Ground $script:G -Asked 'What is happening?').Grounded |
            Should -BeTrue
    }

    # A decision the panel is SHOWING is a record like any other. Refusing the
    # reply that reads its question back would be refusing the records in order
    # to protect them.
    It 'passes a figure that a decision on the panel is asking about' {
        $ground = Get-FmBridgeGround -Fleet ([pscustomobject]@{
                Tasks     = @([pscustomobject]@{ Id = 'lock-identity'; Percent = 75
                        State = 'working'; Note = 'proven'
                    })
                Decisions = @([pscustomobject]@{ Task = 'lock-identity'; Key = 'cover'
                        Question = 'ship at 80% coverage or wait for the rest?'
                    })
                Activity  = @(); House = @(); Capacity = $null; At = '14:02:11'
            })
        $v = Test-FmBridgeGrounded -Ground $ground -Asked 'What is waiting on me?' `
            -Text 'Lock identity wants to know whether to ship at 80% coverage or wait.'
        $v.Grounded | Should -BeTrue -Because ($v.Unsubstantiated -join '; ')
    }

    It 'passes a capacity figure that was actually measured' {
        (Test-FmBridgeGrounded -Text 'You have 53% of the week left and 58% of this session.' `
                -Ground $script:G -Asked 'How much is left?').Grounded | Should -BeTrue
    }

    # A figure that exists somewhere in the records but not against the run it is
    # put against. This is the one the captain can catch by looking left at the
    # panel, so it is the one that must never reach them.
    It 'refuses a real figure attached to the wrong work' {
        $v = Test-FmBridgeGrounded -Text 'Lock identity is at 65% and going well.' `
            -Ground $script:G -Asked 'How is it going?'
        $v.Grounded | Should -BeFalse
        ($v.Unsubstantiated -join ' | ') | Should -Match 'lock-identity'
        ($v.Unsubstantiated -join ' | ') | Should -Match '75'
    }

    # A name the captain raised is theirs to raise, and the honest answer needs
    # to say it back. A gate that blocked the phrase outright would block the
    # denial too, and then the screen could not say "that does not exist".
    It 'lets the screen deny work the captain asked about' {
        (Test-FmBridgeGrounded -Ground $script:G `
                -Asked 'How are the payment tests going?' `
                -Text 'There are no payment tests. Nothing under way touches payments.').Grounded |
            Should -BeTrue
    }

    # Mentioning it is allowed. Reporting on it is not - that is the difference
    # between answering the captain and inventing an answer for them.
    It 'refuses to give work the captain named a state it does not have' {
        (Test-FmBridgeGrounded -Ground $script:G `
                -Asked 'How are the payment tests going?' `
                -Text 'The payment tests are at 40% and still on the card fixtures.').Grounded |
            Should -BeFalse
    }

    It 'refuses to recommend acting on work it cannot substantiate' -ForEach @(
        @{ Reply = 'You should stop lock identity and start the payment tests instead.' }
        @{ Reply = 'I would put the payment tests first.' }
        @{ Reply = 'Start the payment tests before anything else.' }
        @{ Reply = 'Ask there to begin the payment tests in its place.' }
    ) {
        $v = Test-FmBridgeGrounded -Text $Reply -Ground $script:G -Asked 'Should I start the payment tests?'
        $v.Grounded | Should -BeFalse
        ($v.Unsubstantiated -join ' | ') | Should -Match 'payment tests'
    }

    # The captain never said it, so there is no source for it at all. A name the
    # screen introduced by itself cannot appear even in a sentence denying it -
    # putting it on screen is what does the damage, whatever the verb around it.
    It 'refuses a name the screen introduced by itself' -ForEach @(
        @{ Reply = 'Nothing is happening with the payment tests.' }
        @{ Reply = 'tg-route is quiet.' }
        @{ Reply = 'The checkout flow work has not started.' }
    ) {
        (Test-FmBridgeGrounded -Text $Reply -Ground $script:G -Asked 'What is happening?').Grounded |
            Should -BeFalse
    }

    # If ordinary English tripped this, the gate would fire on almost every good
    # reply and the screen would be duller than it needs to be for no gain.
    It 'does not mistake ordinary English for the name of a piece of work' -ForEach @(
        @{ Reply = 'The page is read-only until the engine is up.' }
        @{ Reply = 'That is a one-off, and the branch is up-to-date.' }
        @{ Reply = 'I will do a follow-up once the full checks finish.' }
        @{ Reply = 'It is mid-flight and self-directed; leave it be.' }
        @{ Reply = 'Lock identity is at 75%, and the back-out is confirmed.' }
        # None of these are in any list. English makes a compound whenever it
        # wants one, so the shape has to answer for the ones nobody enumerated.
        @{ Reply = 'It is half-rebuilt and not yet re-checked.' }
        @{ Reply = 'A five-hour window, and the panel is barely-used.' }
    ) {
        (Test-FmBridgeGrounded -Text $Reply -Ground $script:G -Asked 'What is happening?').Grounded |
            Should -BeTrue
    }

    # A described piece of work is not a named one: the words are the records'
    # own, so there is nothing invented to catch.
    #
    # THE LAST TWO WERE FOUND LIVE, on the first real turn after the gate went
    # in. A worker had written "zero mis-pairings" and "the listening-mode
    # setting" into its own record; the reply quoted the record it had just been
    # handed, and the gate held it back for naming work that does not exist. A
    # gate that refuses the records' own wording is not protecting anyone.
    It 'does not mistake the records own words for a name' -ForEach @(
        @{ Reply = 'The browser run is finished.' }
        @{ Reply = 'The reply path work is under way.' }
        @{ Reply = 'The suite run is still going.' }
        @{ Reply = 'Lock identity is at 75%, with zero mis-pairings.' }
        @{ Reply = 'Voice quality is at 20% and is on the listening-mode setting.' }
        # A describing word in front of a work noun does not name work, and
        # reading it as one held back a whole good reply over a heading.
        @{ Reply = 'Active work: five runs, and none of them is waiting on you.' }
        @{ Reply = 'The remaining work is all mid-flight.' }
        # A preposition in between means the words in front are not naming the
        # noun after them. The gate held back its own replacement over this one.
        @{ Reply = '5 pieces of work, and this is all of it.' }
        @{ Reply = 'There is a fair amount of work left.' }
    ) {
        (Test-FmBridgeGrounded -Text $Reply -Ground $script:G -Asked 'What is happening?').Grounded |
            Should -BeTrue
    }

    # Section 9 requires the full https:// URL of a PR in every mention, and a
    # path segment inside one has exactly the shape of a name. Reading a link as
    # a claim would refuse the one thing on screen the captain needed to tap.
    It 'does not read a link as a claim about work' {
        (Test-FmBridgeGrounded -Ground $script:G -Asked 'Where is it?' `
                -Text 'Ready for you at https://github.com/limitall/fire-drill/pull/12').Grounded |
            Should -BeTrue
    }

    It 'has no complaint about an empty reply' -ForEach @(
        @{ Reply = '' }, @{ Reply = '   ' }
    ) {
        (Test-FmBridgeGrounded -Text $Reply -Ground $script:G).Grounded | Should -BeTrue
    }

    # With no work at all, EVERY name is invention. The empty case is where a
    # gate built around "compare with the list" quietly stops comparing.
    It 'refuses every name when the records carry no work at all' {
        (Test-FmBridgeGrounded -Ground (script:New-Ground -Empty) -Asked 'What is happening?' `
                -Text 'Lock identity is at 75%.').Grounded | Should -BeFalse
    }
}

Describe 'Protect-FmBridgeReply' {

    BeforeAll { $script:G = script:New-Ground }

    It 'hands a substantiated reply through exactly as it was written' {
        $said = 'Lock identity is at 75% and nothing is waiting on you.'
        $out = Protect-FmBridgeReply -Text $said -Ground $script:G -Asked 'What is happening?'
        $out.Grounded | Should -BeTrue
        $out.Reply | Should -Be $said
    }

    # THE ACCEPTANCE CRITERION, stated as a test: the invented name cannot reach
    # the captain. Not de-emphasised, not footnoted - absent from what is
    # delivered.
    It 'lets no part of an unsubstantiated reply through' {
        $incident = 'Halting lock-identity at its 75 percent and putting the payment tests in its ' +
        'place is your call - ask there to stop lock-identity and begin the payment tests. ' +
        'tg-route stays at 25 percent past the docs.'
        $out = Protect-FmBridgeReply -Text $incident -Ground $script:G -Asked 'What is happening?'

        $out.Grounded | Should -BeFalse
        $out.Reply | Should -Not -Match '(?i)payment'
        $out.Reply | Should -Not -Match '(?i)tg.route'
        $out.Reply | Should -Not -Match '25 percent'
        $out.Reply | Should -Not -Match '25%'
    }

    # A screen whose answer to a hard question is "I cannot say" has replaced one
    # useless surface with another. The replacement has to be worth reading.
    It 'answers from the records rather than refusing' {
        $out = Protect-FmBridgeReply -Ground $script:G -Asked 'What is happening?' `
            -Text 'The payment tests are at 40 percent.'
        $out.Reply | Should -Match '(?i)lock identity'
        $out.Reply | Should -Match '75%'
        $out.Reply | Should -Match '(?i)nothing is waiting'
        # Long enough to be an answer, and it offers the captain a next move
        # rather than ending on what it would not do.
        $out.Reply.Length | Should -BeGreaterThan 120
        $out.Reply | Should -Match '(?i)ask me'
    }

    # Every figure in the replacement is one the panel is showing from the same
    # read, because both come from the one snapshot.
    It 'gives the captain the same figures the panel has' {
        $out = Protect-FmBridgeReply -Ground $script:G -Asked 'What is happening?' `
            -Text 'tg-route is at 25 percent.'
        foreach ($row in $script:G.Rows) {
            $out.Reply | Should -Match ([regex]::Escape("$($row.Percent)%"))
            $out.Reply | Should -Match ([regex]::Escape($row.Label))
        }
        $out.At | Should -Be $script:G.At
    }

    # THE INVARIANT, and the sharpest test in this file: whatever reaches the
    # captain has to clear the same gate the assistant's wording had to clear.
    # Anything less means the replacement is trusted for being ours rather than
    # for being true - and this caught a real defect the moment it was written,
    # because the replacement said "5 pieces of work" and the gate read that as
    # naming work that does not exist.
    It 'delivers nothing its own gate would refuse' -ForEach @(
        @{ Bad = 'The payment tests are at 40 percent.' }
        @{ Bad = 'tg-route is at 25 percent past the docs.' }
        @{ Bad = 'The suite is green: 1730 pass.' }
    ) {
        foreach ($ground in @($script:G, (script:New-Ground -Empty), (script:New-Ground -NoCapacity))) {
            $out = Protect-FmBridgeReply -Text $Bad -Ground $ground -Asked 'What is happening?'
            (Test-FmBridgeGrounded -Text $out.Reply -Ground $ground -Asked 'What is happening?').Grounded |
                Should -BeTrue -Because "what it delivered was: $($out.Reply)"
        }
    }

    It 'says what it could not back, on the console side, without putting it on screen' {
        $out = Protect-FmBridgeReply -Ground $script:G -Asked 'What is happening?' `
            -Text 'tg-route is at 25 percent.'
        @($out.Unsubstantiated).Count | Should -BeGreaterThan 0
        ($out.Unsubstantiated -join ' ') | Should -Match 'tg-route'
    }
}

Describe 'the spoken line is gated too' {

    BeforeAll { $script:GS = script:New-Ground }

    # TWO CHANNELS NOW, AND ONLY ONE WAS CHECKED. The reply the captain READS and
    # the line the page SPEAKS are two different sentences the session writes, so
    # gating the written one alone would let an invention out through the speaker
    # while the screen stayed clean - the same fabrication, arriving where the
    # captain cannot re-read it to check.
    It 'refuses a spoken line that names work the records do not carry' {
        $spoken = 'Stop lock identity and start the payment tests instead.'
        (Test-FmBridgeGrounded -Text $spoken -Ground $script:GS -Asked 'What is happening?').Grounded |
            Should -BeFalse
    }

    It 'passes a spoken line that says only what the records say' {
        (Test-FmBridgeGrounded -Ground $script:GS -Asked 'What is happening?' `
                -Text 'Five runs, nothing waiting on you, and lock identity is furthest along at 75%.').Grounded |
            Should -BeTrue
    }

    # The written half and the spoken half are checked against ONE reading, so a
    # reply cannot be refused on screen and permitted in the ear, or the reverse.
    It 'holds both halves to the same reading' {
        $bad = 'The payment tests are at 40%.'
        $written = Protect-FmBridgeReply -Text $bad -Ground $script:GS -Asked 'What is happening?'
        $spoken = Test-FmBridgeGrounded -Text $bad -Ground $script:GS -Asked 'What is happening?'
        $written.Grounded | Should -Be $spoken.Grounded
    }
}

Describe 'Get-FmBridgeRecordAnswer' {

    It 'says there is no work rather than leaving a blank where work would be' {
        $out = Get-FmBridgeRecordAnswer -Ground (script:New-Ground -Empty)
        $out | Should -Match '(?i)no work'
        $out | Should -Not -BeNullOrEmpty
    }

    It 'names every piece of work the records carry, and no others' {
        $g = script:New-Ground
        $out = Get-FmBridgeRecordAnswer -Ground $g
        foreach ($row in $g.Rows) { $out | Should -Match ([regex]::Escape($row.Label)) }
        $out | Should -Not -Match '(?i)payment'
    }

    # It is read out loud as well as shown, so AGENTS.md section 9 binds on it
    # exactly as on anything else the captain hears.
    It 'speaks in the captain nouns, never in machinery' {
        $out = Get-FmBridgeRecordAnswer -Ground (script:New-Ground) -Because 'x'
        $out | Should -Not -Match '(?i)worktree|crewmate|harness|status file|task id|\.ps1|state/'
    }
}

Describe 'replies a live session actually produced' {

    # NOT INVENTED FOR THIS FILE. Every reply below came off a real hosted
    # session answering through /api/say against the real records of the day,
    # with the placeholder text this task is about sitting in the home where the
    # session could read it. They are kept because each one is a case no amount
    # of writing tests at a desk produced: the first four are good replies that
    # an over-eager check held back, and holding back a true answer is its own
    # way of making the screen useless.
    #
    # The records they were measured against are script:New-Ground's, which is
    # that day's fleet.
    BeforeAll { $script:Live = script:New-Ground }

    # THE FABRICATION, CAUGHT IN THE WILD. Not the reply the captain reported
    # months ago and not one written to make a point - this came off a real
    # hosted session on 2026-08-18, on the first turn it was asked, with the
    # placeholder text this task is about sitting in the home it was reading.
    # Every one of those figures is a literal typed into ui/bridge.html: the
    # session read them off the screen and handed them back as measurements.
    It 'stops the fabrication a live session actually produced' {
        $fabricated = 'Five runs are under way, nothing is waiting on you, and the suite is green ' +
        '(1730 pass, 0 failed, 25 not run). Capacity: 79% of the week left, 82% session.'
        $out = Protect-FmBridgeReply -Text $fabricated -Ground $script:Live -Asked 'What is happening right now?'

        $out.Grounded | Should -BeFalse
        foreach ($invented in @('1730', '79%', '82%')) {
            $out.Reply | Should -Not -Match ([regex]::Escape($invented)) -Because 'nothing measured it'
        }
        # And what went out instead is the records, in full.
        foreach ($row in $script:Live.Rows) { $out.Reply | Should -Match ([regex]::Escape($row.Label)) }
    }

    It 'passes the reply a live session gave to "what is happening"' {
        $real = @'
Right now, five pieces of work are on the board:

- **finished run stall** - done, ready.
- **lock identity** (75%, working) - fix corrected and proven; back-out confirmed; full suite running.
- **ui readonly** (65%, working) - fix implemented; panel and reply agree in a real browser with work running.
- **voice quality** (20%, working) - reproduced on the real screen; captain addendum read; building the one-line reply plus overlay, the listening-mode setting, and the speech preparation.
- **ui invents** (5%, working) - local copy verified, branch rebased onto main, reading the bridge reply path.

Nothing is waiting on a decision. Allowance: 58% left this session, 53% left for the week.
'@
        $v = Test-FmBridgeGrounded -Text $real -Ground $script:Live -Asked 'What is happening right now?'
        $v.Grounded | Should -BeTrue -Because ($v.Unsubstantiated -join '; ')
    }

    # FIVE NAMES AND FIVE FIGURES IN ONE SENTENCE. Comparing every name against
    # every figure called this twenty things at once, all of them wrong; a
    # reader pairs each figure with the name beside it and so does the check.
    It 'pairs each figure with the name beside it, not with all of them' {
        $oneLine = 'finished run stall 100%, lock identity 75%, ui readonly 65%, ' +
        'voice quality 20%, ui invents 5%.'
        $v = Test-FmBridgeGrounded -Text $oneLine -Ground $script:Live -Asked 'Where is everything?'
        $v.Grounded | Should -BeTrue -Because ($v.Unsubstantiated -join '; ')
    }

    # And it still catches a swap inside that same shape, which is the whole
    # reason the pairing exists rather than being dropped.
    It 'still catches two figures swapped between neighbours' {
        $swapped = 'lock identity 65%, ui readonly 75%.'
        (Test-FmBridgeGrounded -Text $swapped -Ground $script:Live -Asked 'Where is everything?').Grounded |
            Should -BeFalse
    }

    # EVERY CASE CARRIES EVERY KEY, and the three that did not are why this note
    # exists. The body used to read `$Asked` and fall back when it was absent,
    # which is an undefined variable under this file's `Set-StrictMode -Version
    # Latest` - so the three cases without that key threw. It passed run after
    # run in isolation, because a value left behind by an earlier test happened
    # to still be in scope, and failed only in the whole-directory run where the
    # scoping differs. A -ForEach case that depends on what another test left
    # behind is not a test; give every case the same shape.
    It 'passes replies whose wording an over-eager check held back' -ForEach @(
        @{ Asked = 'What is happening?'; Reply = 'Lock identity is the furthest-along at 75%.' }
        @{ Asked = 'What is happening?'; Reply = 'Voice quality is mid-build at 20%.' }
        @{ Asked = 'What is happening?'; Reply = 'The records show no work matching that.' }
        @{ Asked = 'How are the payment tests going?'
            Reply = 'If payment tests exist, they are not in these records.'
        }
    ) {
        $v = Test-FmBridgeGrounded -Text $Reply -Ground $script:Live -Asked $Asked
        $v.Grounded | Should -BeTrue -Because ($v.Unsubstantiated -join '; ')
    }
}

Describe 'Test-FmBridgeWordsRecorded' {

    BeforeAll { $script:GW = script:New-Ground }

    It 'traces a phrase built out of the records own words' -ForEach @(
        @{ Phrase = 'mis-pairings' }, @{ Phrase = 'lock identity' }
        @{ Phrase = 'browser run' }, @{ Phrase = 'listening-mode' }
    ) {
        Test-FmBridgeWordsRecorded -Text $Phrase -Ground $script:GW | Should -BeTrue
    }

    It 'traces nothing to records that never said it' -ForEach @(
        @{ Phrase = 'payment' }, @{ Phrase = 'tg-route' }
        @{ Phrase = 'checkout flow' }, @{ Phrase = 'card fixtures' }
    ) {
        Test-FmBridgeWordsRecorded -Text $Phrase -Ground $script:GW | Should -BeFalse
    }
}

Describe 'Test-FmBridgeDescribingWord' {

    # The discriminator that stops the gate firing on a describing word nobody
    # enumerated, without letting a noun-shaped name through as English. The
    # last three were found live: "Active work" was held back as the name of
    # work that does not exist.
    It 'reads a word doing a describing job as description' -ForEach @(
        @{ Word = 'mis-paired' }, @{ Word = 'half-rebuilt' }, @{ Word = 'long-running' }
        @{ Word = 'self-directed' }, @{ Word = 'barely-used' }, @{ Word = 'five-hour' }
        @{ Word = 'two-thirds' }, @{ Word = 'read-only' }, @{ Word = 'well-formed' }
        @{ Word = 'active' }, @{ Word = 'remaining' }, @{ Word = 'critical' }
        # Whole families rather than single words: a comparative in front, an
        # adverb in front, a particle at the end. Enumerating one at a time is
        # how the list stays permanently one live turn behind.
        @{ Word = 'furthest-along' }, @{ Word = 'most-recent' }, @{ Word = 'newly-added' }
        @{ Word = 'run-through' }, @{ Word = 'latest-first' }, @{ Word = 'mid-build' }
        @{ Word = 'part-written' }, @{ Word = 'cross-checked' }, @{ Word = 'non-blocking' }
    ) {
        Test-FmBridgeDescribingWord -Text $Word | Should -BeTrue
    }

    # Every one of these is the shape work is named in here, and the last three
    # are the names that were invented.
    It 'reads a noun as a name that must be substantiated' -ForEach @(
        @{ Word = 'lock-identity' }, @{ Word = 'voice-quality' }, @{ Word = 'finished-run-stall' }
        @{ Word = 'tg-route' }, @{ Word = 'payment' }, @{ Word = 'checkout-flow' }
    ) {
        Test-FmBridgeDescribingWord -Text $Word | Should -BeFalse
    }

    # A short last word ending in those letters is not an inflection: "led",
    # "ring" and "only" are whole words, and reading them as suffixes would let
    # a name like `card-led` pass as description.
    It 'does not read a short word as an inflected one' {
        Test-FmBridgeDescribingWord -Text 'card-led' | Should -BeFalse
    }
}

Describe 'the lists the gate leans on' {

    # Each entry is compared lowercased, so an entry that is not lowercase is an
    # entry that never matches - dead weight that reads as coverage.
    It 'keeps every entry in the form it is compared in' {
        foreach ($word in (Get-FmBridgeOrdinaryHyphenation)) {
            $word | Should -Be $word.ToLowerInvariant()
            $word | Should -Match '^[a-z0-9]+(-[a-z0-9]+)+$' -Because 'it stands in for a hyphenated name'
        }
        foreach ($word in (Get-FmBridgeCommonModifier)) {
            $word | Should -Be $word.ToLowerInvariant()
        }
    }

    It 'lists nothing twice' {
        $h = @(Get-FmBridgeOrdinaryHyphenation)
        @($h | Select-Object -Unique).Count | Should -Be $h.Count
        $m = @(Get-FmBridgeCommonModifier)
        @($m | Select-Object -Unique).Count | Should -Be $m.Count
    }
}
