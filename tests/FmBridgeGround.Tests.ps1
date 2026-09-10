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
        param([switch]$Empty, [switch]$NoCapacity, [string]$Identity = '')
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
                Identity  = $Identity
                At        = '14:02:11'
            })
    }

    # This home's answer to "who are you", as the captain wrote it.
    $script:AditIdentity =
    'I am a firstmate, made for Adit by Dhaval Bhalodia, to help you work on the Adit app products.'
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
        # Long enough to be an answer rather than a refusal.
        $out.Reply.Length | Should -BeGreaterThan 120
        # And it says the records are the source, so the captain can tell this
        # from the reply they would otherwise have read.
        $out.Reply | Should -Match '(?i)from the records'
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

Describe 'an ordinary question gets an ordinary answer' {

    # THE DEFECT, from the captain's own fresh VM on 2026-09-07. They said
    # "hello" and got a fleet report; they asked what day it was and got the
    # identical fleet report again. Neither question was about work at all. The
    # session wrote a real answer to each, the gate judged both ungrounded, and
    # the console said why:
    #
    #     fm-bridge: reply held back - names work the records do not carry: 'Please run'
    #
    # There is no such job and the captain never typed the word. `run` is a verb
    # here and the gate read it as the noun, so the politeness in front of it
    # became the name of invented work.
    #
    # A FRESH VM IS THE WORST CASE AND THE FIRST THING THE CAPTAIN SEES. With
    # nothing dispatched the records carry no words at all, so
    # Test-FmBridgeWordsRecorded - the check that lets a reply quote the record
    # it was handed - can never pass. The gate is at its very tightest on the
    # morning after the install.
    BeforeAll {
        $script:Fresh = script:New-Ground -Empty -NoCapacity
        $script:Board = script:New-Ground
    }

    It 'has no words at all to lean on, which is what made this the worst case' {
        @($script:Fresh.Rows).Count | Should -Be 0
        @($script:Fresh.Words).Count | Should -Be 0
    }

    It 'lets the reply the captain actually lost through' -ForEach @(
        @{ Asked = 'hello'
            Said = 'Hello. Nothing is under way right now. Please run it past me and I will write out what to ask for.'
        }
        @{ Asked = 'whic day today ?'
            Said = 'I cannot read the clock from here, so please run date in your own window and it will tell you.'
        }
    ) {
        $out = Protect-FmBridgeReply -Text $Said -Ground $script:Fresh -Asked $Asked
        $out.Grounded | Should -BeTrue -Because "it was held for: $($out.Unsubstantiated -join '; ')"
        $out.Reply | Should -Be $Said
    }

    # A GREETING, A DATE, A QUESTION ABOUT THIS SCREEN, A REFUSAL AND A ROUTE.
    # None of them claims anything about the fleet, so there is nothing in any of
    # them for the records to substantiate or to contradict. Every one is held to
    # both readings, because the empty board and the busy one give the gate
    # completely different vocabularies to work from.
    It 'says nothing about the fleet, so nothing is held back' -ForEach @(
        @{ Said = 'Hello, captain. Nothing is under way and nothing is waiting on you.' }
        @{ Said = 'Please run date in your own window and it will tell you.' }
        @{ Said = 'I cannot read the clock from here, so please run it in your firstmate window.' }
        @{ Said = 'Let me work through what you want and I will write it out for you.' }
        @{ Said = 'Just run it past me first and I will say what to ask for.' }
        @{ Said = 'Kindly run that in the window you already have open.' }
        @{ Said = 'Now run it and tell me what you see.' }
        @{ Said = 'You can run it there whenever you like.' }
        @{ Said = 'The full checks run in your own window, not on this screen.' }
        @{ Said = 'I will fix that wording for you.' }
        @{ Said = 'Would you like me to work out what to ask for?' }
        @{ Said = 'I am the screen for your fleet. Ask me what is happening and I will tell you.' }
        @{ Said = 'I cannot tell you that from here.' }
        @{ Said = 'Everything I say comes from the records, so I will not guess at a date.' }
        @{ Said = 'Say the word in your firstmate window and it will start.' }
    ) {
        foreach ($ground in @($script:Fresh, $script:Board)) {
            $v = Test-FmBridgeGrounded -Text $Said -Ground $ground -Asked 'hello'
            $v.Grounded | Should -BeTrue -Because "it was held for: $($v.Unsubstantiated -join '; ')"
        }
    }

    # BOTH CHANNELS, TO THE SAME READING. The spoken line is a second sentence
    # the session wrote, and gating it separately is what stops an invention
    # arriving where the captain cannot re-read it. The narrowing has to reach
    # both, or a greeting is delivered on screen and swallowed in the ear.
    It 'lets an ordinary line through on the spoken channel too' {
        $spoken = 'Hello. Please run it past me and I will write out what to ask for.'
        $written = Protect-FmBridgeReply -Text $spoken -Ground $script:Fresh -Asked 'hello'
        $heard = Protect-FmBridgeReply -Text $spoken -Ground $script:Fresh -Asked 'hello'
        $written.Grounded | Should -BeTrue
        $heard.Grounded | Should -Be $written.Grounded
    }
}

Describe 'the line the narrowing must not cross' {

    # THE POINT OF THIS BLOCK. The gate above was narrowed because it was firing
    # on English that claims nothing. Every case here fails the moment that
    # narrowing is taken one step further, and each one names the step it
    # guards, so a later change that looks harmless has to argue with a named
    # defect rather than with a passing suite.
    BeforeAll {
        $script:Fresh = script:New-Ground -Empty -NoCapacity
        $script:Board = script:New-Ground
    }

    It 'still holds back a reply that invents work' -ForEach @(
        # Fails if a noun with no verb reading were relaxed along with the ones
        # that have one. `job`, `task` and `lane` are nouns and nothing else.
        @{ Why = 'a job the records do not carry'; Said = 'The payments job is green.' }
        @{ Why = 'a task the records do not carry'; Said = 'The payment task finished overnight.' }
        @{ Why = 'a lane the records do not carry'; Said = 'The payment lane is blocked.' }
        # Fails if the determiner rule were applied to a bare plural or to a mass
        # noun, neither of which needs one in English.
        @{ Why = 'a bare plural name'; Said = 'Payment tests are green and nothing is left to do.' }
        @{ Why = 'a mass-noun name'; Said = 'Payment work finished overnight.' }
        # Fails if a determiner stopped counting as evidence of a noun phrase.
        @{ Why = 'a branch the records do not carry'; Said = 'The auth branch is ready to merge.' }
        @{ Why = 'a run the records do not carry'; Said = 'The payment run came back clean.' }
        @{ Why = 'a fix the records do not carry'; Said = 'A payment fix has landed.' }
        # Fails if bare naming stopped being a finding on its own - the guard
        # would then only catch what it could also read a claim out of.
        @{ Why = 'a state the records do not carry'; Said = 'The payment tests are running.' }
        @{ Why = 'an outcome the records do not carry'; Said = 'I have finished the payment tests.' }
        # The founding defect itself, whole.
        @{ Why = 'the reply this gate was built for'
            Said = 'Halting lock-identity at its 75 percent and putting the payment tests in its place is your call.'
        }
    ) {
        foreach ($ground in @($script:Fresh, $script:Board)) {
            $out = Protect-FmBridgeReply -Text $Said -Ground $ground -Asked 'what is happening?'
            $out.Grounded | Should -BeFalse -Because "it names $Why"
            $out.Reply | Should -Not -Match '(?i)payment|auth'
        }
    }

    # A figure never consults the grammar above at all, so the narrowing cannot
    # reach it however far it is taken.
    It 'still holds back an invented figure whatever the sentence around it is' -ForEach @(
        @{ Said = 'Please run it: 1730 pass, 0 failed, 25 not run.' }
        @{ Said = 'Let me work on it. Capacity is 79% of the week left.' }
    ) {
        (Test-FmBridgeGrounded -Text $Said -Ground $script:Fresh -Asked 'hello').Grounded |
            Should -BeFalse
    }
}

Describe 'what the captain reads when a reply is held back' {

    # THE DEFECT. The captain said "hello", the gate fired, and what came back
    # opened "The records show no work at all right now" and reached the reason
    # four lines later. They had asked nothing about work. A fleet report is a
    # fine answer to "what is happening" and an incoherent one to a greeting, so
    # the reason leads now and the records follow it as what is on offer instead.
    #
    # AND IT IS ONE LINE, not four. The paragraph that used to lead - an apology
    # about an answer the captain could not see - read, twice in a row, as a
    # machine reporting its own fault, which is the one thing the screen's own
    # rule forbids. It still marks the reply as coming from the records; it no
    # longer explains itself at length.
    It 'opens by saying it held something back, not with a fleet report' {
        $out = Protect-FmBridgeReply -Text 'The payment tests are at 40 percent.' `
            -Ground (script:New-Ground) -Asked 'hello'
        $first = @($out.Reply -split "`n")[0]
        $first | Should -Match '(?i)from the records'
        $first | Should -Not -Match '(?i)pieces of work|no work at all'
        # Short enough not to read as a confession.
        $first.Length | Should -BeLessThan 100
    }

    # An empty board substantiates nothing, so there is nothing to offer in the
    # reply's place and saying so in one line is the whole of the honest answer.
    It 'does not pad a held-back reply with a report of an empty board' {
        $out = Protect-FmBridgeReply -Text 'The payment tests are at 40 percent.' `
            -Ground (script:New-Ground -Empty -NoCapacity) -Asked 'hello'
        $out.Grounded | Should -BeFalse
        $out.Reply | Should -Match '(?i)from the records'
        $out.Reply | Should -Not -Match '(?i)nothing is waiting on a decision'
        $out.Reply | Should -Not -Match '(?i)the records show no work at all'
        # An empty board still offers the captain a next move rather than
        # ending on what this screen could not do.
        $out.Reply | Should -Match '(?i)ask me again'
    }

    # The reason is new prose rather than a field the translator has already
    # been through, so section 9 binds on it directly and on the real wording
    # rather than on a stub.
    It 'gives the reason in the captain nouns, never in machinery' {
        foreach ($ground in @((script:New-Ground), (script:New-Ground -Empty -NoCapacity))) {
            $out = Protect-FmBridgeReply -Text 'The payment tests are at 40 percent.' `
                -Ground $ground -Asked 'hello'
            # The same words the standalone answer is held to. A second, wider
            # list here would drift from that one and would also trip over
            # `lock identity`, which is a job the panel shows rather than jargon.
            $out.Reply |
                Should -Not -Match '(?i)worktree|crewmate|harness|status file|task id|\.ps1|state/'
        }
    }

    # Asked for on its own rather than as a replacement, this is still the plain
    # answer to "what is happening" and says both halves of it.
    It 'still reports the whole board when it is not standing in for anything' {
        $out = Get-FmBridgeRecordAnswer -Ground (script:New-Ground -Empty -NoCapacity)
        $out | Should -Match '(?i)no work'
        $out | Should -Match '(?i)nothing is waiting'
    }
}

Describe 'Get-FmBridgeWorkNoun' {

    # The gate builds its own matcher out of this, so a head it matches and a
    # head it can reason about are the same list by construction rather than by
    # anyone remembering to edit both.
    It 'classifies every noun exactly once' {
        $nouns = @(Get-FmBridgeWorkNoun)
        @($nouns.Word | Select-Object -Unique).Count | Should -Be $nouns.Count
        foreach ($n in $nouns) { $n.Word | Should -Be $n.Word.ToLowerInvariant() }
    }

    # Both halves have to be populated or the classification is decorative: if
    # nothing were a verb the reported defect returns, and if everything were one
    # the gate stops catching an invented job.
    It 'holds both a verb-capable and a noun-only class' {
        $nouns = @(Get-FmBridgeWorkNoun)
        @($nouns | Where-Object { $_.Verb }).Count | Should -BeGreaterThan 0
        @($nouns | Where-Object { -not $_.Verb }).Count | Should -BeGreaterThan 0
    }

    It 'reads run, work, fix, test and branch as words that are also verbs' -ForEach @(
        @{ Word = 'run' }, @{ Word = 'work' }, @{ Word = 'fix' }, @{ Word = 'test' }, @{ Word = 'branch' }
    ) {
        (@(Get-FmBridgeWorkNoun) | Where-Object { $_.Word -eq $Word }).Verb | Should -BeTrue
    }

    It 'reads job, task and lane as nouns and nothing else' -ForEach @(
        @{ Word = 'job' }, @{ Word = 'task' }, @{ Word = 'lane' }
    ) {
        (@(Get-FmBridgeWorkNoun) | Where-Object { $_.Word -eq $Word }).Verb | Should -BeFalse
    }
}

Describe 'Test-FmBridgePluralWord' {

    It 'reads the plural mark English actually writes' -ForEach @(
        @{ Word = 'checks' }, @{ Word = 'tests' }, @{ Word = 'fixes' }, @{ Word = 'docs' }
    ) {
        Test-FmBridgePluralWord -Text $Word | Should -BeTrue
    }

    # The endings that wear the same letter without being a plural. Reading
    # `status` as plural would let a real name through unchecked.
    It 'does not mistake a singular ending in s for one' -ForEach @(
        @{ Word = 'status' }, @{ Word = 'process' }, @{ Word = 'analysis' }
        @{ Word = 'payment' }, @{ Word = 'auth' }, @{ Word = '' }, @{ Word = 'is' }
    ) {
        Test-FmBridgePluralWord -Text $Word | Should -BeFalse
    }
}

Describe 'Test-FmBridgeNamingPhrase' {

    # A noun with no verb reading is judged exactly as it was before any of this,
    # which is what keeps the narrowing off the cases the gate exists for.
    It 'reads a noun-only head as naming, whatever stands in front of it' -ForEach @(
        @{ Head = 'job'; Modifier = @('payments') }
        @{ Head = 'job'; Modifier = @('payment') }
        @{ Head = 'lanes'; Modifier = @('payment') }
    ) {
        Test-FmBridgeNamingPhrase -Head $Head -Modifier $Modifier | Should -BeTrue
    }

    # English compounds a noun with a noun in the singular, so a plural touching
    # the head is its subject: "the checks run" is checks doing something.
    It 'reads a plural touching a verb-capable head as a subject, not a name' {
        Test-FmBridgeNamingPhrase -Head 'run' -Modifier @('checks') -Introducer @('the') |
            Should -BeFalse
    }

    # The rule that ends the reported defect: a singular count noun cannot stand
    # as a noun phrase without a determiner, so "please run" names nothing.
    It 'refuses a bare singular count noun' -ForEach @(
        @{ Head = 'run'; Modifier = @('please') }
        @{ Head = 'fix'; Modifier = @('just') }
        @{ Head = 'test'; Modifier = @('kindly') }
    ) {
        Test-FmBridgeNamingPhrase -Head $Head -Modifier $Modifier -Introducer @('', '') |
            Should -BeFalse
    }

    It 'accepts the same head once a determiner introduces it' -ForEach @(
        @{ Intro = 'the' }, @{ Intro = 'a' }, @{ Intro = 'your' }, @{ Intro = 'every' }
    ) {
        Test-FmBridgeNamingPhrase -Head 'run' -Modifier @('payment') -Introducer @($Intro) |
            Should -BeTrue
    }

    # A bare plural and a mass noun are noun phrases on their own, so neither is
    # asked for a determiner and both stay checked.
    It 'needs no determiner for a bare plural or a mass noun' -ForEach @(
        @{ Head = 'tests' }, @{ Head = 'branches' }, @{ Head = 'work' }
    ) {
        Test-FmBridgeNamingPhrase -Head $Head -Modifier @('payment') -Introducer @('') |
            Should -BeTrue
    }

    # The refusal paths. A head this does not classify is not its to judge, and
    # a phrase with nothing in front of the noun names nothing at all.
    It 'declines to overrule a caller on a head it does not classify' {
        Test-FmBridgeNamingPhrase -Head 'pull-request' -Modifier @('payment') | Should -BeTrue
    }

    It 'names nothing when there is no modifier left' -ForEach @(
        @{ Modifier = @() }, @{ Modifier = @('') }
    ) {
        Test-FmBridgeNamingPhrase -Head 'run' -Modifier $Modifier -Introducer @('the') |
            Should -BeFalse
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
        # A determiner is compared as one word. A two-word entry would never
        # match anything and would read as coverage it does not give.
        foreach ($word in (Get-FmBridgeDeterminer)) {
            $word | Should -Be $word.ToLowerInvariant()
            $word | Should -Match '^[a-z]+$'
        }
    }

    It 'lists nothing twice' {
        $h = @(Get-FmBridgeOrdinaryHyphenation)
        @($h | Select-Object -Unique).Count | Should -Be $h.Count
        $m = @(Get-FmBridgeCommonModifier)
        @($m | Select-Object -Unique).Count | Should -Be $m.Count
        $d = @(Get-FmBridgeDeterminer)
        @($d | Select-Object -Unique).Count | Should -Be $d.Count
    }
}

Describe 'the identity this home carries' {

    # THE DEFECT. The captain asked "who are you and what you can do ?" and the
    # screen answered as the model behind it. The identity they wrote is a
    # record of this home like any other, so a reply repeating it back is
    # quoting a record - but only if the gate has been told that.
    It 'lets the reply say who it is' -ForEach @(
        @{ Said = 'I am a firstmate made for Adit by Dhaval Bhalodia, here to help you with the Adit app products.' }
        @{ Said = 'I am your firstmate for Adit. I look after the Adit app work.' }
        @{ Said = 'Dhaval Bhalodia made me for Adit, and the Adit app work is what I help you with.' }
        @{ Said = 'I am the Adit firstmate. Dhaval Bhalodia built me for the Adit app products.' }
    ) {
        $ground = script:New-Ground -Empty -NoCapacity -Identity $script:AditIdentity
        $out = Protect-FmBridgeReply -Text $Said -Ground $ground -Asked 'who are you and what you can do ?'
        $out.Grounded | Should -BeTrue -Because "the records carry this home's identity"
        $out.Reply | Should -Be $Said
    }

    # WITHOUT THE IDENTITY IT IS INVENTION, and this is what says the fix is the
    # identity rather than some accident of the wording. Same words, same empty
    # board, no identity set: `Adit app` is a name nothing substantiates, so
    # reporting a state for it is invention.
    #
    # THE SENTENCE REPORTS, WHERE IT USED TO ONLY NAME. The gate no longer holds
    # a reply back for putting a determined noun phrase on screen, because four
    # live turns proved it cannot tell one from ordinary English - "your
    # software work", "the dry run". What still separates the two boards is what
    # the reply is allowed to SAY about those words, which is the thing the
    # identity was ever evidence for.
    It 'still calls those words invention when no identity is set' {
        $ground = script:New-Ground -Empty -NoCapacity
        $out = Test-FmBridgeGrounded -Text 'The Adit app work is blocked.' `
            -Ground $ground -Asked 'who are you'
        $out.Grounded | Should -BeFalse

        # And the identity is what turns it, rather than the wording.
        $with = script:New-Ground -Empty -NoCapacity -Identity $script:AditIdentity
        (Test-FmBridgeGrounded -Text 'I look after the Adit app work.' `
                -Ground $with -Asked 'who are you').Grounded | Should -BeTrue
    }

    # THE WORDS, NOT THE ARITHMETIC. A figure written into the identity file is
    # still a figure nothing measured, and the defect "1730 pass, 0 failed" came
    # from exactly this: a number read off a page and repeated back.
    It 'does not let a figure in the identity become quotable' {
        $ground = script:New-Ground -Empty -NoCapacity `
            -Identity 'I am the firstmate for Adit, and I look after 47 products across 12 teams.'
        $ground.Numbers.Contains(47) | Should -BeFalse
        $ground.Numbers.Contains(12) | Should -BeFalse
        (Test-FmBridgeGrounded -Text 'There are 47 products.' -Ground $ground -Asked 'how many').Grounded |
            Should -BeFalse
    }

    # An identity cannot conjure work into existence either. It widens what may
    # be SAID, never what is on the board.
    It 'does not let the identity put work on the board' {
        $ground = script:New-Ground -Empty -NoCapacity -Identity $script:AditIdentity
        @($ground.Rows).Count | Should -Be 0
        $ground.Names.Count | Should -Be 0
        (Test-FmBridgeGrounded -Text 'The Adit app work is at 40% and I would land it next.' `
                -Ground $ground -Asked 'status').Grounded | Should -BeFalse
    }

    # A home that has set nothing is not a home with a blank on its screen.
    It 'carries no identity when none was set, and nothing breaks' {
        $ground = script:New-Ground -Empty -NoCapacity
        $ground.Identity | Should -Be ''
        { Test-FmBridgeGrounded -Text 'Good morning.' -Ground $ground -Asked 'hello' } | Should -Not -Throw
    }
}

Describe 'the gag on determiner-led phrases' {

    # THE DEFECT, from the captain's own screen on 2026-09-09. b94f179 stopped
    # `run` and `work` being read as nouns when they were verbs and left every
    # DETERMINER-led phrase standing, so four real replies were swallowed and
    # the captain read a paragraph about an answer they could not see.
    It 'delivers the replies the captain actually lost' -ForEach @(
        @{ Asked = 'who are you ?'
            Said = 'I am your firstmate on this machine. What I do is set work going for you and tell you how it stands.'
        }
        @{ Asked = 'can you start multiple teammates and test whether they can work in parallel'
            Said = 'Yes. I can put several crewmates out at once, each on a different task, and they run side by side.'
        }
        @{ Asked = 'create one dummy task in which you start multiple crewmates'
            Said = 'That one is small enough to finish quickly. If you want a real measurement I would give them a harder task.'
        }
        # The whole family, not only the four that were reported.
        @{ Asked = 'can you do more than one thing'
            Said = 'I can, and each crewmate takes a separate task so they never wait on one another.'
        }
        @{ Asked = 'what next'; Said = 'I would rather give you a smaller job first so you can see it finish.' }
        @{ Asked = 'is that all'; Said = 'There is a slower run available if you want more detail from it.' }
        @{ Asked = 'how do I try it'; Said = 'Give me a simple task and I will show you how it goes.' }
    ) {
        foreach ($ground in @((script:New-Ground -Empty -NoCapacity), (script:New-Ground))) {
            (Test-FmBridgeGrounded -Text $Said -Ground $ground -Asked $Asked).Grounded |
                Should -BeTrue -Because 'nothing in it claims anything about work'
        }
    }

    # THE LINE THIS NARROWING MUST NOT CROSS EITHER. An indefinite article
    # demotes a phrase to a mention; it does not excuse it. Each of these gives
    # the mention a state or a figure, and each must still be held.
    It 'still holds an indefinite phrase that is given a state or a figure' -ForEach @(
        @{ Said = 'A payment fix has landed.' }
        @{ Said = 'A payment run is green.' }
        @{ Said = 'A payment task is done.' }
        @{ Said = 'A payment run finished overnight.' }
        @{ Said = 'A payment run is at 40%.' }
    ) {
        foreach ($ground in @((script:New-Ground -Empty -NoCapacity), (script:New-Ground))) {
            $out = Protect-FmBridgeReply -Text $Said -Ground $ground -Asked 'what is happening?'
            $out.Grounded | Should -BeFalse -Because 'it reports on work that does not exist'
            $out.Reply | Should -Not -Match '(?i)payment'
        }
    }

    # SHAPED LIKE A REAL ID, which is the invention this gate is likeliest to be
    # handed and the one the captain is likeliest to believe. Their own records
    # name work `bridge-gag`, `login-before-start`, `install-test-noise` - a
    # lowercase hyphenated slug - so an invented name wearing that shape is
    # indistinguishable from a real one to everybody but the records. Nothing in
    # the narrowing above is allowed to reach these.
    It 'still holds an invented name shaped exactly like a real one' -ForEach @(
        @{ Said = 'payment-gateway is at 60% and should land before the others.' }
        @{ Said = 'The billing-migration job is green.' }
        @{ Said = 'I would stop lock-identity and start customer-import instead.' }
        @{ Said = 'A payment-gateway fix has landed.' }
        # A name the captain used is mentionable, never reportable, and this
        # reports on it.
        @{ Said = 'payment-gateway is done and nothing else is waiting.' }
    ) {
        foreach ($ground in @((script:New-Ground -Empty -NoCapacity), (script:New-Ground))) {
            $out = Protect-FmBridgeReply -Text $Said -Ground $ground -Asked 'what is happening?' `
                -AlsoAsked @('how is payment-gateway going')
            $out.Grounded | Should -BeFalse -Because 'the records carry no such name'
            $out.Reply | Should -Not -Match '(?i)payment-gateway|billing-migration|customer-import'
        }
    }

    # THE STATE RULE ITSELF, which is the third thing the contract has always
    # named and the code never checked. Driven through a name the captain used,
    # because that is a mention rather than a hard finding - so a failure here
    # is this rule failing and nothing else.
    It 'holds back a state given to a name only the captain has used' -ForEach @(
        @{ Said = 'The dummy job is green.' }
        @{ Said = 'The dummy job has failed.' }
        @{ Said = 'The dummy job is done.' }
        @{ Said = 'The dummy job finished overnight.' }
    ) {
        (Test-FmBridgeGrounded -Text $Said -Ground (script:New-Ground) -Asked 'and now ?' `
                -AlsoAsked @('make me a dummy task')).Grounded |
            Should -BeFalse -Because 'a name they used may be mentioned, never reported on'
    }

    # AND THE SAME NAME WITH NO STATE ON IT STILL SHIPS, which is what says the
    # rule above is reading the state rather than the name.
    It 'still delivers the same name when nothing is claimed about it' {
        (Test-FmBridgeGrounded -Text 'The dummy job is the one you asked me to make.' `
                -Ground (script:New-Ground) -Asked 'and now ?' `
                -AlsoAsked @('make me a dummy task')).Grounded | Should -BeTrue
    }

    # A copula's complement is not a name. "What I do is set work going" was
    # held as work called `set`.
    It 'reads the words after a copula as a complement, not a name' -ForEach @(
        @{ Head = 'work'; Intro = 'is' }, @{ Head = 'work'; Intro = 'was' }
        @{ Head = 'tests'; Intro = 'are' }, @{ Head = 'run'; Intro = 'be' }
    ) {
        Test-FmBridgeNamingPhrase -Head $Head -Modifier @('set') -Introducer @($Intro) |
            Should -BeFalse
    }
}

Describe 'the captain own words, for as long as the conversation lasts' {

    # THE DEFECT. The captain typed "create one dummy task in which you start
    # multiple crewmates" and the reply naming it back one turn later was held
    # for inventing `the dummy job`. Their own word, from their own screen.
    # THE NAME IS BARE, and that is now what makes this test able to tell the
    # two turns apart. A determined phrase - "the dummy job" - is a mention
    # whoever introduced it, because four live turns proved the gate cannot tell
    # one from "the dry run" or "your software work". A BARE one is how this
    # system writes an id, so it still has to have a source, and the captain's
    # earlier words are still one.
    It 'counts a name the captain introduced on an earlier turn' {
        $ground = script:New-Ground -Empty -NoCapacity
        $said = 'Not yet. Dummy tests are what you asked me to set up, and I will say when they land.'

        # As it was: their word is gone the instant the turn ends.
        (Test-FmBridgeGrounded -Text $said -Ground $ground -Asked 'is it finished ?').Grounded |
            Should -BeFalse

        # As it is: the conversation is the unit, not the message.
        (Test-FmBridgeGrounded -Text $said -Ground $ground -Asked 'is it finished ?' `
                -AlsoAsked @('create one dummy task in which you start multiple crewmates')).Grounded |
            Should -BeTrue
    }

    # Carried through the one call the courier actually makes.
    It 'carries earlier words through Protect-FmBridgeReply' {
        $out = Protect-FmBridgeReply -Text 'The dummy job is still going.' `
            -Ground (script:New-Ground -Empty -NoCapacity) -Asked 'and now ?' `
            -AlsoAsked @('make me a dummy task')
        $out.Grounded | Should -BeTrue
        $out.Reply | Should -Match '(?i)dummy'
    }

    # AND IT IS STILL ONLY A MENTION. A word of theirs makes a name sayable, not
    # reportable - which is the half of the contract that keeps this from being
    # a way to talk the gate into anything.
    It 'still refuses to report on a name the captain merely used' -ForEach @(
        @{ Said = 'The dummy job is at 40%.' }
        @{ Said = 'I would stop the dummy job and start something real.' }
        @{ Said = 'The dummy job has failed.' }
    ) {
        (Test-FmBridgeGrounded -Text $Said -Ground (script:New-Ground) -Asked 'and now ?' `
                -AlsoAsked @('make me a dummy task')).Grounded | Should -BeFalse
    }
}

Describe 'the gate stops parsing English' {

    # THE DEFECT, from the captain's live session on 2026-09-10. Three commits
    # had narrowed this gate by grammar - the verb reading, the determiner
    # reading, the copula reading - and each time the next phrasing broke it
    # again. Four of eight turns were swallowed, and what the gate called "work
    # the records do not carry" was: a possessive noun phrase, two spelt-out
    # NUMBERS, an ordinary definite noun phrase, and two HYPHENATED WORDS.
    #
    # Not one of them is the name of anything. The approach was the defect: the
    # gate was deciding, from grammar alone, whether an arbitrary English noun
    # phrase is the NAME of a piece of work, and English is open, so there was
    # always another phrasing.
    BeforeAll {
        $script:Fresh = script:New-Ground -Empty -NoCapacity
        $script:Board = script:New-Ground
    }

    It 'delivers every reply the captain lost on 2026-09-10' -ForEach @(
        # 'your software work' - a possessive noun phrase.
        @{ Why = 'a possessive noun phrase'; Asked = 'who are you ?'
            Said = 'I am a firstmate, made for Adit by Dhaval Bhalodia, to help you with your software work.'
        }
        # 'eighty-four', 'ninety-six' - the reply was doing arithmetic, because
        # the captain had asked for a sum.
        @{ Why = 'spelt-out numbers'; Asked = 'start a dummy process with several workers'
            Said = 'Eighty-four and ninety-six make one hundred and eighty.'
        }
        # 'the dry run' - an ordinary definite noun phrase.
        @{ Why = 'an ordinary definite noun phrase'; Asked = 'what is currently running ?'
            Said = 'Nothing is dispatched at the moment, so the dry run is all there is to look at.'
        }
        # 'demo-rest-api', 'copy-paste' - a name for a thing being made, and an
        # ordinary hyphenated word.
        @{ Why = 'an id-shaped name for a thing being made'; Asked = 'create a simple node js api'
            Said = 'I will put it in a folder called demo-rest-api so it is easy to find.'
        }
        @{ Why = 'a hyphenated ordinary word'; Asked = 'create a simple node js api'
            Said = 'You can copy-paste that straight into the terminal.'
        }
    ) {
        foreach ($ground in @($script:Fresh, $script:Board)) {
            (Test-FmBridgeGrounded -Text $Said -Ground $ground -Asked $Asked).Grounded |
                Should -BeTrue -Because "$Why claims nothing about the fleet"
        }
    }

    # THE FAMILIES NOBODY HAS REPORTED YET, and the reason a fourth narrowing
    # was not the answer. Every one of these was held back by the shipped gate
    # before this change, and none of them was in anyone's list of phrases to
    # fix - they were found by writing down more English of the same kind. That
    # is four more phrase families on one line, on top of the captain's four.
    It 'delivers the families the next live turn would have found' -ForEach @(
        @{ Asked = 'what is forty two plus fifty seven ?'; Said = 'Forty-two plus fifty-seven is ninety-nine.' }
        @{ Asked = 'how many ?'; Said = 'Seventy-three of them, give or take.' }
        @{ Asked = 'how do I move it ?'; Said = 'A copy-paste is enough; there is no drag-and-drop here.' }
        @{ Asked = 'what shape is it in ?'; Said = 'It is a stop-gap, best-guess, rough-and-ready answer for now.' }
        @{ Asked = 'how do I hand it over ?'; Said = 'A hand-over note and a walk-through is usually enough.' }
        @{ Asked = 'can you check it ?'; Said = 'I can do the quick test first and the slow one after.' }
    ) {
        foreach ($ground in @($script:Fresh, $script:Board)) {
            (Test-FmBridgeGrounded -Text $Said -Ground $ground -Asked $Asked).Grounded |
                Should -BeTrue -Because 'it is prose, whatever shape its words have'
        }
    }

    # THE OTHER DIRECTION, and the reason this is not a loosening. The gate
    # catches MORE than it did, because the question it asks is now about what
    # the reply CLAIMS rather than about how the reply is worded - and a claim
    # can be found wherever it is made, including in a sentence whose head noun
    # is not one the old matcher knew.
    It 'holds back a state attached to work the records do not carry' -ForEach @(
        # `retry` is not one of the fifteen work nouns and there is no hyphen to
        # notice, so every earlier version of this gate delivered this one.
        @{ Why = 'a bare name the work-noun list never covered'
            Said = 'billing retry is blocked on the same thing.'
        }
        @{ Why = 'an id-shaped name with a state'; Said = 'payment-tests is green and ready to merge.' }
        @{ Why = 'an id-shaped name with a figure'; Said = 'billing-retry is at 40 percent.' }
        @{ Why = 'an id-shaped name with an action'
            Said = 'Stop lock-identity and start auth-rewrite instead.'
        }
        @{ Why = 'a name reported on in the panel spelling'; Said = 'checkout flow work has not started.' }
    ) {
        foreach ($ground in @($script:Fresh, $script:Board)) {
            (Test-FmBridgeGrounded -Text $Said -Ground $ground -Asked 'what is happening?').Grounded |
                Should -BeFalse -Because "it attaches a claim to $Why"
        }
    }

    # A STATE ON A REAL ID THAT HAS NO SUCH STATE. The name is real, so no
    # naming rule can catch it; the figure has to.
    It 'holds back a figure attached to a real id that does not carry it' -ForEach @(
        @{ Said = 'lock-identity is at 30 percent.' }
        @{ Said = 'ui-readonly is at 90 percent and voice-quality at 80 percent.' }
    ) {
        (Test-FmBridgeGrounded -Text $Said -Ground $script:Board -Asked 'what is happening?').Grounded |
            Should -BeFalse
    }

    # THE DETERMINER IS THE WHOLE RULE, so it is worth more than one case. Each
    # of these puts an invented modifier in front of a work noun and claims
    # nothing about it; the gate held every one of them back before this change,
    # and English has an unbounded supply of them.
    It 'delivers a determined phrase that claims nothing' -ForEach @(
        @{ Said = 'The payment tests can wait until you say otherwise.' }
        @{ Said = 'That was the billing run, not a dispatch.' }
        @{ Said = 'I have not touched your checkout work.' }
        @{ Said = 'This payment task is one you would have to start yourself.' }
        @{ Said = 'Every billing job goes through the same window.' }
        @{ Said = 'I look after your software work and I keep the records straight.' }
    ) {
        (Test-FmBridgeGrounded -Text $Said -Ground $script:Board -Asked 'what is happening?').Grounded |
            Should -BeTrue -Because 'a determiner picks a thing out of a kind rather than naming one'
    }

    # WHERE A SLUG STANDS DECIDES WHETHER IT IS A NAME. Heading its own clause
    # is the screen putting work up; anywhere else it is a word some other word
    # gave a job to. Nothing in the SHAPE of `demo-rest-api` separates it from
    # `install-test-noise`, so the shape is not what is asked.
    It 'reads a slug heading its clause as a name and one inside a clause as a word' {
        (Test-FmBridgeGrounded -Text 'auth-rewrite covers the login path.' `
                -Ground $script:Board -Asked 'what is happening?').Grounded |
            Should -BeFalse -Because 'nothing introduced it, so it is standing as an id'

        (Test-FmBridgeGrounded -Text 'You can copy-paste that straight into the terminal.' `
                -Ground $script:Board -Asked 'how do I move it ?').Grounded |
            Should -BeTrue -Because 'a verb gave it its job, so it is a word in a sentence'
    }

    # WHAT THE RULE IS, asserted rather than described. A determiner marks a
    # common noun; a name is bare. Same head noun, same invented modifier, same
    # board - only the determiner differs, and it decides whether the phrase can
    # be a name at all.
    It 'reads a determined phrase as a mention and a bare one as a name' {
        $mention = Test-FmBridgeGrounded -Text 'The payment tests can wait.' `
            -Ground $script:Board -Asked 'what is happening?'
        $mention.Grounded | Should -BeTrue -Because 'a determiner picks a thing out of a kind'

        $name = Test-FmBridgeGrounded -Text 'Payment tests are green.' `
            -Ground $script:Board -Asked 'what is happening?'
        $name.Grounded | Should -BeFalse -Because 'a bare noun phrase is how this system writes an id'
    }
}

Describe 'Get-FmBridgeNumberWord' {

    # THE DEFECT. The captain asked for a sum, the reply did the arithmetic, and
    # the gate held it back for naming work called `eighty-four` and
    # `ninety-six`. The class was half here - one to ten, then twelve, twenty,
    # thirty and nothing after - so forty through ninety read as the first word
    # of a compound name. Half a closed class is the same trap as no closed
    # class, which this file had already paid for once over the pronouns.
    It 'carries every ten English hyphenates a unit to' -ForEach @(
        @{ Word = 'twenty' }, @{ Word = 'thirty' }, @{ Word = 'forty' }, @{ Word = 'fifty' }
        @{ Word = 'sixty' }, @{ Word = 'seventy' }, @{ Word = 'eighty' }, @{ Word = 'ninety' }
    ) {
        (Get-FmBridgeNumberWord) | Should -Contain $Word
    }

    It 'reads a compound number as description rather than as a name' -ForEach @(
        @{ Word = 'eighty-four' }, @{ Word = 'ninety-six' }, @{ Word = 'forty-two' }
        @{ Word = 'fifty-seven' }, @{ Word = 'ninety-nine' }, @{ Word = 'seventy-three' }
        @{ Word = 'twenty-first' }, @{ Word = 'three-quarters' }
    ) {
        Test-FmBridgeDescribingWord -Text $Word | Should -BeTrue
    }

    It 'is lowercase, single words, and lists nothing twice' {
        $n = @(Get-FmBridgeNumberWord)
        foreach ($word in $n) { $word | Should -Match '^[a-z]+$' }
        @($n | Select-Object -Unique).Count | Should -Be $n.Count
    }
}

Describe 'Get-FmBridgeReportedState' {

    # WHICH SIDE OF THE GATE A LIST MAY LIVE ON. This is the only list left
    # whose gaps cost the captain anything, and what they cost is a mention that
    # should have been held - never a true reply held back, because a line has
    # to be mentioning unrecorded work before this is consulted at all. That is
    # the opposite failure direction from the naming lists, which swallowed real
    # answers four times running.
    It 'carries the states a status line actually writes' -ForEach @(
        @{ Word = 'working' }, @{ Word = 'done' }, @{ Word = 'failed' }
        @{ Word = 'blocked' }, @{ Word = 'paused' }, @{ Word = 'ready' }
    ) {
        (Get-FmBridgeReportedState) | Should -Contain $Word
    }

    It 'is lowercase and lists nothing twice' {
        $s = @(Get-FmBridgeReportedState)
        foreach ($word in $s) { $word | Should -Match '^[a-z ]+$' }
        @($s | Select-Object -Unique).Count | Should -Be $s.Count
    }

    # A DENIAL IS STILL A CLAIM. "the checkout flow work has not started" reports
    # on invented work exactly as firmly as "has started" does.
    It 'reads a negated state as a state' {
        (Test-FmBridgeGrounded -Text 'The checkout flow work has not started.' `
                -Ground (script:New-Ground) -Asked 'what is happening?').Grounded | Should -BeFalse
    }

    # THE SOFT WORDS ARE ONLY SAFE AFTER A PERCEPTION VERB, which is the whole
    # reason they sit behind a switch. `looks fine` reports on a piece of work;
    # `that is fine` is ordinary agreement, and English says it constantly.
    It 'carries the soft words only when they are perceived' {
        (Get-FmBridgeReportedState) | Should -Not -Contain 'fine'
        (Get-FmBridgeReportedState -Perceived) | Should -Contain 'fine'
    }

    It 'reads a perceived report as a claim and ordinary agreement as neither' {
        (Test-FmBridgeGrounded -Text 'The payment tests look fine to me.' `
                -Ground (script:New-Ground) -Asked 'what is happening?').Grounded |
            Should -BeFalse -Because 'looks fine reports on a piece of work'

        (Test-FmBridgeGrounded -Text 'The payment tests can wait, and that is fine by me.' `
                -Ground (script:New-Ground) -Asked 'what is happening?').Grounded |
            Should -BeTrue -Because 'that is fine is agreement, not a report'
    }
}
