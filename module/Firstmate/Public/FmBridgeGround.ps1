#requires -Version 7.0
# FmBridgeGround.ps1 - what the screen is allowed to say about the work.
#
# THE DEFECT THIS AREA EXISTS FOR. The captain asked the screen what was
# happening and it answered, fluently, with percentages:
#
#     "Halting lock-identity at its 75 percent and putting the payment tests in
#      its place is a call you make in the firstmate window on this machine...
#      tg-route stays at 25 percent past the docs, ui-readonly at 55 percent
#      past the bin, and the checks keep running."
#
# There are no payment tests. There never have been. The phrase exists in this
# repository only as placeholder text in a doc and a fixture, and the assistant
# behind the text box read it, mistook it for work, and recommended halting
# genuine work at 75 percent to make room for it. Had the captain agreed, real
# work would have been stopped for something that does not exist.
#
# WHY AN INSTRUCTION IS NOT THE FIX. The same screen already carried an
# instruction not to leak internal jargon, and jargon leaked anyway. A reply is
# generated text; a rule it is asked to follow is a probability, not a
# guarantee. The captain cannot tell the invented sentences from the true ones
# because they arrive in the same voice, in the same reply, so the guarantee has
# to live somewhere the model is not.
#
# WHERE IT LIVES INSTEAD. The courier reads the durable records ONCE per turn
# and uses that one snapshot three times: it grounds the question with it, it
# gates the answer against it, and it hands the same snapshot to the panel. So
# the reply and the panel cannot disagree - they are the same read - and a name,
# state or percentage the records do not carry cannot be delivered at all.
#
# THE CONTRACT, in one sentence:
#
#     A name for work may come only from the durable records or from the
#     captain's own words, and a name the records do not carry may be mentioned
#     but never given a state, a percentage, or a recommended action.
#
# Both halves matter. Names must be allowed to come from the captain, because
# the honest answer to "how are the payment tests going" is "there are no
# payment tests" - and a gate that forbade the phrase outright would forbid the
# denial along with the invention. What it must never do is report progress on
# such a name or suggest acting on it.
#
# WHICH WAY IT FAILS. A reply this cannot substantiate is REPLACED by an answer
# composed from the records - never trimmed, and never delivered with a warning
# attached. Trimming leaves behind the sentence that carried the claim; a
# warning still puts invented text on screen beside true text in one voice,
# which is the defect itself. The cost of a false rejection is a plainer answer
# that is still true and still useful; the cost of a false acceptance is the
# captain stopping real work for fiction. Those are not the same size.

Set-StrictMode -Version Latest

function ConvertTo-FmBridgeWorkKey {
    <#
        .SYNOPSIS
        One spelling for a piece of work, whatever spelling it arrived in.

        .DESCRIPTION
        `lock-identity` is the record's id, "lock identity" is what the panel
        prints, and "Lock Identity" is how a sentence says it. All three compare
        equal here, so a reply is never called invention for spelling a real name
        the way English spells it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-FmBridgeOrdinaryHyphenation {
    <#
        .SYNOPSIS
        Hyphenated English that is a word rather than the name of a piece of work.

        .DESCRIPTION
        A task id in this port is a lowercase hyphenated slug - `lock-identity`,
        `voice-quality`, `finished-run-stall` - and so is `read-only`. Nothing in
        the shape of the token separates a name from an ordinary compound, and
        there is no dictionary here to ask, so the compounds the screen actually
        uses are named instead.

        THIS LIST IS NOT A SAFETY BOUNDARY, which is why it can be incomplete
        without being dangerous. A compound missing from it is treated as an
        unsubstantiated name and the captain gets the record-composed answer
        rather than the assistant's wording: a duller reply, not a false one.
        Adding a word here only ever makes replies richer. It can never make an
        invented name deliverable, because a name still has to clear the records
        or the captain's own words.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@(
        # The shape or state of a thing.
        'read-only', 'write-only', 'up-to-date', 'out-of-date', 'well-formed',
        'half-finished', 'self-directed', 'long-running', 'non-blocking',
        'fast-forward', 'real-time', 'built-in', 'one-off', 'ad-hoc', 'so-called',
        'mid-flight', 'in-flight', 'off-screen', 'on-screen', 'end-to-end',
        'side-by-side', 'step-by-step', 'day-to-day', 'word-for-word',
        'point-to-point', 'first-run', 'best-effort', 'left-hand', 'right-hand',
        'one-line', 'two-line', 'single-line', 'multi-line', 'full-screen',
        'per-run', 'per-turn', 'per-message', 'high-level', 'low-level',
        'second-hand', 'front-matter', 'plain-english', 'so-far', 'as-is',

        # Things a person does.
        'follow-up', 'hand-off', 'back-out', 'sign-in', 'sign-off', 'check-in',
        'log-in', 'opt-in', 'opt-out', 'catch-up', 'knock-on', 're-run', 're-read',
        're-open', 'pre-flight', 'post-fix', 'double-check', 'hands-on',
        'hands-off', 'set-up', 'start-up', 'clean-up', 'close-up', 'roll-back',
        'hold-off', 'take-up',

        # This port's own compounds. They are section 9's business rather than
        # this gate's - jargon, not invention - and the translation seam owns
        # whether they reach the captain at all.
        'no-mistakes', 'local-only', 'direct-pr', 'fail-closed', 'fail-open',
        'needs-decision', 'ask-user', 'task-worktree', 'primary-checkout',
        'local-main', 'end-to-end-evidence', 'x-fm-token'
    )
}

function Test-FmBridgeDescribingWord {
    <#
        .SYNOPSIS
        Is this word describing something, or naming a piece of work?

        .DESCRIPTION
        A LIST ALONE CANNOT ANSWER THIS, and finding that out is what this
        function is. `read-only` and `one-off` are enumerable; `mis-paired`,
        `half-rebuilt` and plain `active` are not, because English builds a
        describing word whenever it wants one. A gate that treated every
        unlisted one as a name would replace good replies over an adjective -
        measured, on the first live turn: "Active work" was held back as the name
        of work that does not exist.

        SO THE SHAPE IS ASKED ABOUT TOO. Work here is named by nouns -
        `lock-identity`, `voice-quality`, `tg-route`, `payment tests` - while a
        word doing a describing job usually carries English's mark for one:
        `-ed`, `-ing`, `-ly`, `-ive`, `-ous`, `-al`, `-ic`, `-able`, `-ful`,
        `-less`. A word ending that way is read as description. A bare noun is
        read as a name and has to clear the records.

        BY CLASS, NOT BY WORD, and that is the lesson four live turns taught in a
        row - `mis-pairings`, then `Active work`, then `furthest-along`, then
        `mid-build`. Enumerating the compound that just went wrong leaves the
        list permanently one turn behind, because English coins a new one
        whenever it wants. So whole families are named instead: a number or
        comparative in front, an adverb in front, a productive prefix in front, a
        particle at the end.

        IT IS A HEURISTIC AND THE FAILURE DIRECTION IS DELIBERATE. A name that
        happens to end in `-ing` is read as description here and has to be caught
        by one of the other checks instead; a describing word ending in a noun is
        read as a name and costs a duller reply. Neither can put an invented name
        on screen with a figure or an action attached, because that is held by a
        different check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $lower = $Text.ToLowerInvariant()
    if ((Get-FmBridgeOrdinaryHyphenation) -contains $lower) { return $true }

    $parts = @($lower -split '-' | Where-Object { $_ })
    if (-not $parts.Count) { return $true }

    # BY CLASS, NOT BY WORD. Each of these is a whole family of compounds English
    # makes freely, and adding them one at a time is how a list stays permanently
    # one behind - `furthest-along` was the third live turn's false positive
    # after `mis-pairings` and `Active work`.
    $numberWords = @('one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
        'nine', 'ten', 'half', 'quarter', 'twelve', 'twenty', 'thirty')
    $comparatives = @('more', 'most', 'less', 'least', 'best', 'worst', 'better', 'worse',
        'further', 'furthest', 'nearer', 'nearest', 'closer', 'closest', 'earlier',
        'earliest', 'later', 'latest', 'longer', 'longest', 'shorter', 'shortest')
    # A particle at the end is a phrasal verb or a direction, never a name:
    # "furthest-along", "hold-off", "run-through".
    $particles = @('along', 'ahead', 'behind', 'forward', 'forwards', 'back', 'backwards',
        'through', 'over', 'under', 'down', 'up', 'in', 'out', 'off', 'on', 'away', 'apart')
    # A productive prefix in front makes a describing word out of whatever
    # follows, without limit: "mid-build", "mid-flight", "part-written",
    # "re-checked", "cross-checked".
    $prefixes = @('mid', 'pre', 'post', 'non', 'anti', 'semi', 'sub', 'inter', 'intra',
        'multi', 'cross', 'self', 'part', 'ill', 'well', 'near', 'quasi', 'ex', 're',
        'un', 'co', 'over', 'under', 'half', 'all', 'once', 'never', 'ever')

    if ($numberWords -contains $parts[0]) { return $true }
    if ($comparatives -contains $parts[0]) { return $true }
    if ($parts.Count -gt 1 -and $prefixes -contains $parts[0]) { return $true }
    if ($parts[0] -match '^\d+$') { return $true }
    # An adverb in front is describing whatever follows: "barely-used",
    # "newly-added", "hardly-started".
    if ($parts.Count -gt 1 -and $parts[0] -match '^.{2,}ly$') { return $true }
    if ($parts.Count -gt 1 -and $particles -contains $parts[-1]) { return $true }

    # A suffix needs a stem in front of it, or every short word that happens to
    # end in those letters reads as inflected: "led", "ring" and "den" are whole
    # words, and taking them for inflections would let `card-led` pass as
    # description. Two characters is the line - "us-ed" is an inflection, "l-ed"
    # is not.
    $parts[-1] -match '^.{2,}(?:ed|ing|ly|able|ible|ive|ous|ful|less|wise|like)$' -or
    $parts[-1] -match '^.{3,}(?:al|ic)$'
}

function Test-FmBridgeWordsRecorded {
    <#
        .SYNOPSIS
        Is every word in this phrase one the records themselves use?

        .DESCRIPTION
        The difference between describing work and naming work that does not
        exist. "the browser run" and "zero mis-pairings" are built out of words a
        worker wrote into its own record; "the payment tests" is not, because
        nothing in the records has ever said "payment".

        This is what keeps the gate from firing on a reply that is quoting the
        very record it was handed - which it did, live, on the first run after
        the gate went in.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Ground
    )

    $parts = @([regex]::Matches($Text, '[A-Za-z][A-Za-z0-9]*') | ForEach-Object { $_.Value })
    if (-not $parts.Count) { return $true }
    foreach ($part in $parts) {
        if (-not $Ground.Words.Contains($part)) { return $false }
    }
    $true
}

function Get-FmBridgeCommonModifier {
    <#
        .SYNOPSIS
        Words that describe a piece of work without naming one.

        .DESCRIPTION
        "the full checks", "the first run" and "the same fix" each put a word in
        front of a work noun without claiming a piece of work by that name.
        Telling them apart from "the payment tests" is the whole job of this
        list.

        Same failure direction as Get-FmBridgeOrdinaryHyphenation: a word missing
        here costs a duller reply, never a delivered invention.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@(
        'the', 'a', 'an', 'this', 'that', 'these', 'those', 'its', 'his', 'her',
        'their', 'my', 'your', 'our', 'each', 'every', 'some', 'any', 'all', 'no',
        'none', 'more', 'most', 'less', 'fewer', 'few', 'many', 'both', 'other',
        'others', 'another', 'same', 'whole', 'full', 'entire', 'real', 'actual',
        'only', 'just', 'first', 'second', 'third', 'fourth', 'fifth', 'last',
        'next', 'previous', 'earlier', 'later', 'current', 'new', 'old', 'recent',
        'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
        'ten', 'main', 'local', 'remote', 'ready', 'open', 'closed', 'finished',
        'unfinished', 'green', 'red', 'good', 'bad', 'big', 'small', 'long',
        'short', 'quick', 'slow', 'hard', 'easy', 'safe', 'quiet', 'busy',
        'much', 'little', 'own', 'usual', 'ordinary', 'plain', 'right', 'wrong',
        # Function words, which are a closed class and can never be the name of
        # anything. Worth listing in full rather than one at a time: "If payment
        # tests exist..." was read as work called "if payment" on a live turn,
        # purely because `if` was missing from here.
        'is', 'was', 'are', 'were', 'be', 'been', 'being', 'am', 'to', 'of', 'in',
        'on', 'at', 'for', 'with', 'and', 'or', 'but', 'not', 'it', 'they', 'you',
        'i', 'we', 'he', 'she', 'if', 'when', 'whether', 'while', 'since',
        # The rest of the pronouns, because half a closed class is the same
        # trap as no closed class. The subject forms were here and the object
        # forms were not, so "let me work that out" was held back as a job
        # called `me` while "let us work that out" went through.
        'me', 'him', 'us', 'them', 'myself', 'yourself', 'himself', 'herself',
        'itself', 'ourselves', 'yourselves', 'themselves',
        'because', 'unless', 'until', 'though', 'although', 'after', 'before',
        'so', 'then', 'as', 'which', 'who', 'whom', 'whose', 'what',
        'where', 'why', 'how', 'there', 'here', 'now', 'also', 'still', 'yet',
        'even', 'never', 'always', 'often', 'again', 'once', 'per',
        'do', 'does', 'did', 'done', 'have', 'has', 'had', 'will', 'would',
        'shall', 'should', 'can', 'could', 'may', 'might', 'must', 'let',
        'get', 'gets', 'got', 'keep', 'keeps', 'make', 'makes', 'made',
        'say', 'says', 'said', 'show', 'shows', 'showed', 'tell', 'tells',
        'see', 'sees', 'seen', 'think', 'thinks', 'know', 'knows', 'want',
        'wants', 'need', 'needs', 'give', 'gives', 'take', 'takes', 'put',
        'puts', 'leave', 'leaves', 'left', 'went', 'goes', 'go', 'came', 'come'
    )
}

function Get-FmBridgeWorkNoun {
    <#
        .SYNOPSIS
        The nouns that make a phrase in front of them the name of a piece of
        work, and the grammar of each one.

        .DESCRIPTION
        THE DEFECT THIS ENDS. The captain said "hello" to a freshly installed
        screen and got a fleet report; so did "whic day today ?". Both times the
        gate held the reply back for naming work that does not exist, and the
        name it objected to was `Please run`. There is no such job, and the
        captain never typed the word: the session had written "please run it in
        your own window", and the gate read the VERB `run` as the noun `run` and
        the politeness in front of it as what names it.

        NINE OF THESE FIFTEEN WORDS ARE ALSO VERBS, which is the whole of it.
        `run`, `work`, `fix`, `test` and `branch` name a thing and do a thing in
        the same spelling, and the matcher that reads what precedes them as a
        name was written as though only the first reading existed. So every
        ordinary imperative the screen has any reason to write - "please run it
        there", "let me work that out", "I will fix the wording" - arrived
        looking exactly like an invented job.

        WHY THE CLASSIFICATION LIVES HERE RATHER THAN IN A LIST OF PHRASES. The
        list of head nouns is already fixed and already in this file; saying
        which of them English also uses as a verb is a bounded, complete
        judgement about those fifteen words, made once. An allow-list of the
        phrases that went wrong - `please run`, then `let me work`, then
        whatever the next turn writes - is the shape that stays permanently one
        defect behind, which `Test-FmBridgeDescribingWord` already learnt in
        four live turns running.

        WHAT EACH FIELD IS FOR. `Verb` says the word has a verb reading that has
        to be ruled out before the phrase counts as a name. `Plural` and `Mass`
        say what kind of noun phrase it can head, which is what rules that
        reading out: English lets a bare plural or a mass noun stand alone
        ("payment tests", "payment work") but a singular count noun needs a
        determiner in front of it, so a bare "please run" is not a noun phrase
        at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    return [pscustomobject[]]@(
        # Also verbs. A phrase in front of one of these is a name only when the
        # phrase has the shape of a noun phrase.
        [pscustomobject]@{ Word = 'test'; Plural = $false; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'tests'; Plural = $true; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'work'; Plural = $false; Mass = $true; Verb = $true }
        [pscustomobject]@{ Word = 'fix'; Plural = $false; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'fixes'; Plural = $true; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'run'; Plural = $false; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'runs'; Plural = $true; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'branch'; Plural = $false; Mass = $false; Verb = $true }
        [pscustomobject]@{ Word = 'branches'; Plural = $true; Mass = $false; Verb = $true }

        # Nouns only. Nothing about these is relaxed, because there is no verb
        # reading to make room for: "the payments job is green" is a claim about
        # work whatever else is true of the sentence.
        [pscustomobject]@{ Word = 'task'; Plural = $false; Mass = $false; Verb = $false }
        [pscustomobject]@{ Word = 'tasks'; Plural = $true; Mass = $false; Verb = $false }
        [pscustomobject]@{ Word = 'job'; Plural = $false; Mass = $false; Verb = $false }
        [pscustomobject]@{ Word = 'jobs'; Plural = $true; Mass = $false; Verb = $false }
        [pscustomobject]@{ Word = 'lane'; Plural = $false; Mass = $false; Verb = $false }
        [pscustomobject]@{ Word = 'lanes'; Plural = $true; Mass = $false; Verb = $false }
    )
}

function Get-FmBridgeDeterminer {
    <#
        .SYNOPSIS
        The words that introduce a noun phrase.

        .DESCRIPTION
        A CLOSED CLASS, and that is why this can be listed in full rather than
        one word at a time. English has not taken a new determiner in centuries,
        so unlike the describing words - which English coins whenever it wants
        one, and which cost this gate four live false positives before it stopped
        enumerating them - this list is finished the day it is written.

        WHAT IT IS FOR. A singular count noun cannot stand as a noun phrase on
        its own: "the payment run" names something and "please run" does not,
        and the determiner is the difference. So this is the evidence that the
        word in front of a work noun is naming it rather than doing something
        else entirely.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@(
        'the', 'a', 'an', 'this', 'that', 'these', 'those',
        'my', 'your', 'our', 'their', 'its', 'his', 'her', 'whose',
        'each', 'every', 'either', 'neither', 'both', 'another', 'other',
        'some', 'any', 'no', 'all', 'half', 'several', 'enough',
        'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
        'first', 'second', 'third', 'last', 'next', 'previous', 'same'
    )
}

function Test-FmBridgePluralWord {
    <#
        .SYNOPSIS
        Is this word a plural, as far as its spelling can say?

        .DESCRIPTION
        There is no dictionary here, so this reads the one mark English puts on
        a plural and discounts the endings that wear the same letter without
        being one: `-ss` (process), `-us` (status), `-is` (analysis).

        WHAT IT DECIDES. English compounds a noun with a noun in the SINGULAR -
        "payment tests", "branch names", "test run" - never "payments tests".
        So a plural word touching a work noun is not modifying it; it is the
        subject of it, and the word after it is a verb: "the checks run in your
        own window" is a sentence about checks, not a job called `checks`.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $lower = $Text.ToLowerInvariant()
    if ($lower.Length -lt 3) { return $false }
    if ($lower -match '(?:ss|us|is)$') { return $false }
    $lower.EndsWith('s')
}

function Test-FmBridgeNamingPhrase {
    <#
        .SYNOPSIS
        Is this phrase NAMING a piece of work, or is it an ordinary sentence
        that happens to use one of the same words?

        .DESCRIPTION
        THE NARROWING THIS IS. The gate's job is to stop the screen asserting
        facts about work the records do not carry. It was doing something wider
        than that: any word in front of `run`, `work`, `fix`, `test` or `branch`
        was read as the name of a job, and those five spellings are verbs as
        readily as they are nouns. A greeting, a date, a refusal and a routing
        sentence are not claims about the fleet, and all four were being held
        back and answered with a fleet report instead - measured on the
        captain's own fresh VM, where `Please run` was called the name of work
        that does not exist.

        AND THE SAME DEFECT CAME BACK ONE STEP ALONG. The narrowing below
        removed the verb reading and left the DETERMINER reading standing, so
        the captain's screen went on holding "each on a different task", "a
        harder task", "a smaller job" and "what I do is set work going" - 20
        ordinary replies in 38, measured. One of those two families is answered
        here; the other is the indefinite article, which is not a question about
        the phrase's SHAPE but about how strong a claim it makes, so it is
        handled where mentions are weighed in Test-FmBridgeGrounded.

        SO THE QUESTION ASKED IS GRAMMATICAL, NOT LEXICAL. Not "have we seen
        this phrase before" - that list is always one turn behind - but "does
        this have the shape of a noun phrase". Four answers, in order:

        AFTER A COPULA THE WORDS ARE A COMPLEMENT. "what I do is set work going"
        says what kind of thing this is; naming a particular one would take a
        determiner, and a determiner would have stopped the walk instead. This
        is first because it disqualifies the phrase outright, whatever head noun
        it ends in.

        A NOUN THAT IS ONLY A NOUN IS UNTOUCHED. `job`, `task` and `lane` have
        no verb reading to make room for, so nothing about them is relaxed and
        an invention wearing one is caught exactly as before.

        A PLURAL TOUCHING THE NOUN IS A SUBJECT, not a modifier, because English
        compounds nouns in the singular. "the checks run" is checks doing
        something; "the payment tests" is work with a name.

        A SINGULAR COUNT NOUN NEEDS A DETERMINER. This is the one that catches
        the reported defect and its whole family at once. "the payment run",
        "a billing fix" and "your auth branch" are noun phrases; "please run",
        "just fix" and "kindly test" are not noun phrases at all, whatever word
        happens to precede them, because English does not let a bare singular
        count noun stand alone. A bare plural and a mass noun can - "payment
        tests", "payment work" - so those two are exempt and stay checked.

        THE FAILURE DIRECTION, deliberately. What this can now let through is an
        invented name that is a bare singular with no determiner in front of it
        ("started payment run"), or one whose modifier is a plural ("the docs
        work"). Both are English the screen does not write, and both are still
        caught the moment they carry a figure, because the percentage and number
        rules never consult this at all. What it can no longer do is call the
        word `please` a job.

        .PARAMETER Head
        The work noun the phrase ends in, as it was written.

        .PARAMETER Modifier
        The words read as naming it, nearest the noun last.

        .PARAMETER Introducer
        The words standing in front of that phrase, any one of which may be the
        determiner that makes it a noun phrase.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Head,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Modifier,
        [string[]]$Introducer = @()
    )

    # THE WORD THAT INTRODUCES THE PHRASE, whichever end it came from. The
    # caller offers the word that stopped its walk first and the word standing
    # in front of the match second; the first one there is the one actually
    # touching the phrase.
    $leading = ''
    foreach ($word in @($Introducer)) { if ($word) { $leading = $word.ToLowerInvariant(); break } }

    # AFTER `IS`, THE WORDS ARE THE VERB'S COMPLEMENT, not a name. "What I do is
    # set work going for you" was held on the captain's screen as work called
    # `set` - the copula's complement read as though it named something. A bare
    # noun phrase after `to be` says what kind of thing this is; naming a
    # particular one takes a determiner, and a determiner would have stopped the
    # walk here instead.
    if (@('is', 'are', 'was', 'were', 'be', 'been', 'being', 'am') -contains $leading) { return $false }

    $noun = @(Get-FmBridgeWorkNoun) | Where-Object { $_.Word -eq $Head.ToLowerInvariant() } |
        Select-Object -First 1
    # A head this does not know is not this function's to judge, and refusing it
    # here would be a silent second opinion on the caller's own match.
    if (-not $noun) { return $true }
    if (-not $noun.Verb) { return $true }

    $touching = @($Modifier | Where-Object { $_ })
    if (-not $touching.Count) { return $false }
    if (Test-FmBridgePluralWord -Text $touching[-1]) { return $false }

    if ($noun.Plural -or $noun.Mass) { return $true }

    $determiners = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](Get-FmBridgeDeterminer), [StringComparer]::OrdinalIgnoreCase)
    foreach ($word in @($Introducer)) {
        if ($word -and $determiners.Contains($word)) { return $true }
    }
    $false
}

function Get-FmBridgeGround {
    <#
        .SYNOPSIS
        Everything about the work that the durable records substantiate.

        .DESCRIPTION
        Built from ONE fleet read, and every use in a turn takes it from here:
        the question is grounded with it, the answer is gated against it, and the
        panel is painted from it. A second read would let the reply and the panel
        describe two different moments, which is exactly the disagreement the
        captain has no way to detect.

        NOTHING ELSE IS A SOURCE. This reads the fleet object and nothing but -
        not the repository, not the process table, not a session's memory. That
        is what makes "the records say so" a property of the code rather than a
        claim about it.

        .PARAMETER Fleet
        The object Get-FmBridgeFleet returned.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Fleet)

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $words = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $percents = [System.Collections.Generic.HashSet[int]]::new()
    $percentOf = @{}
    $rows = [System.Collections.Generic.List[object]]::new()

    # Everything the records say, in one bag, so a word the assistant uses can be
    # traced back to a record rather than to its own reading of something else.
    $prose = [System.Collections.Generic.List[string]]::new()

    foreach ($task in @($Fleet.Tasks)) {
        $id = [string]$task.Id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $key = ConvertTo-FmBridgeWorkKey -Text $id
        $null = $names.Add($key)
        $prose.Add(($id -replace '[-_]+', ' '))
        $prose.Add([string]$task.Note)
        $prose.Add([string]$task.State)

        $pct = $null
        if ($null -ne $task.Percent) {
            $pct = [int]$task.Percent
            $null = $percents.Add($pct)
            $percentOf[$key] = $pct
        }
        $rows.Add([pscustomobject]@{
                Key     = $key
                # Spelt the way the panel spells it. A reply that says
                # `lock-identity` while the panel says "lock identity" puts two
                # names for one thing on one screen.
                Label   = ($id -replace '[-_]+', ' ')
                Percent = $pct
                State   = [string]$task.State
                Note    = [string]$task.Note
            })
    }

    foreach ($d in @($Fleet.Decisions)) {
        $prose.Add([string]$d.Question)
        $prose.Add((([string]$d.Task) -replace '[-_]+', ' '))
    }
    foreach ($a in @($Fleet.Activity)) {
        $prose.Add([string]$a.Text)
        # The time a line landed is a measurement like any other, and a reply is
        # allowed to repeat one the records made.
        $prose.Add([string]$a.At)
    }
    $prose.Add([string]$Fleet.At)
    foreach ($h in @($Fleet.House)) {
        $prose.Add([string]$h.Name)
        $prose.Add([string]$h.Detail)
    }

    # The capacity windows are measured too - `quota-axi` reads the provider's
    # real five-hour and seven-day windows - so their figures are quotable on the
    # same terms as a task's. Folded in rather than kept apart because the rule
    # is about what was measured, not about which panel shows it.
    $capacity = @()
    if ($Fleet.PSObject.Properties['Capacity'] -and $Fleet.Capacity -and $Fleet.Capacity.Measured) {
        $capacity = @($Fleet.Capacity.Windows)
        foreach ($w in $capacity) {
            if ($null -ne $w.Percent) { $null = $percents.Add([int]$w.Percent) }
            $prose.Add([string]$w.Name)
        }
    }

    # EVERY NUMBER THE RECORDS ACTUALLY CONTAIN. "1730 pass, 0 failed, 25 not
    # run" was not a percentage and so slipped past a check that only looked at
    # percentages - and it was the longest-standing invented figure on the whole
    # screen. A count is a measurement too.
    $numbers = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in $percents) { $null = $numbers.Add($p) }
    foreach ($text in $prose) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($w in [regex]::Matches($text, '[A-Za-z][A-Za-z0-9]*')) {
            $null = $words.Add($w.Value.ToLowerInvariant())
        }
        foreach ($n in [regex]::Matches($text, '\d+')) {
            $value = 0
            if ([int]::TryParse($n.Value, [ref]$value)) { $null = $numbers.Add($value) }
        }
        # A percentage a record WROTE is quotable like any other figure it wrote.
        # A decision the panel is showing may well ask "ship at 80% coverage or
        # wait?", and refusing the reply that repeats the question back would be
        # refusing the records to protect them.
        foreach ($n in [regex]::Matches($text, '(?i)(\d{1,3})\s*(?:%|per\s?cent)')) {
            $value = [int]$n.Groups[1].Value
            if ($value -ge 0 -and $value -le 100) { $null = $percents.Add($value) }
        }
    }
    # WHO THIS HOME'S FIRSTMATE IS, and its WORDS ONLY. The identity is a record
    # of this home like any other - the captain wrote it, not the model - so a
    # reply repeating it back is quoting a record rather than inventing one. It
    # has to be here or the gate holds the identity answer back: measured on a
    # fresh board, "I look after the Adit app work" is read as work called `Adit
    # app`, because `Adit` appears in no record.
    #
    # NO FIGURES FROM IT, DELIBERATELY, and this is the whole of the care taken
    # here. Folding it into the prose bag above would make any number written in
    # that file a number the reply may state, which is the exact defect
    # `1730 pass, 0 failed` came from. The identity widens the vocabulary and
    # cannot widen the arithmetic. Get-FmHomeIdentity bounds its length for the
    # same reason: a vocabulary is a few sentences, not a document.
    $identity = ''
    if ($Fleet.PSObject.Properties['Identity']) { $identity = [string]$Fleet.Identity }
    if ($identity) {
        foreach ($w in [regex]::Matches($identity, '[A-Za-z][A-Za-z0-9]*')) {
            $null = $words.Add($w.Value.ToLowerInvariant())
        }
    }

    # Counts of what is in front of it. These are the records' own arithmetic
    # rather than a reading of anything, so a reply may state them.
    $null = $numbers.Add($rows.Count)
    $null = $numbers.Add(@($Fleet.Decisions).Count)
    $null = $numbers.Add(@($Fleet.House).Count)

    [pscustomobject]@{
        PSTypeName = 'Firstmate.BridgeGround'
        Rows       = $rows.ToArray()
        Names      = $names
        Words      = $words
        Percents   = $percents
        Numbers    = $numbers
        PercentOf  = $percentOf
        Decisions  = @($Fleet.Decisions)
        House      = @($Fleet.House)
        Capacity   = $capacity
        Identity   = $identity
        At         = [string]$Fleet.At
    }
}

function Get-FmBridgeRecordAnswer {
    <#
        .SYNOPSIS
        The answer the records themselves support, in the captain's nouns.

        .DESCRIPTION
        What the captain gets when a reply cannot be substantiated. It is not a
        refusal: a screen whose answer to a hard question is "I cannot say" has
        replaced one useless surface with another. It says what IS known, from
        the same read the panel is painted from, and says plainly that the rest
        was left out - without repeating the part that was left out, because
        repeating it is delivering it.

        .PARAMETER Ground
        The snapshot from Get-FmBridgeGround.

        .PARAMETER Because
        One short clause naming why the assistant's own wording was not used.
        Omitted when this is asked for on its own rather than as a replacement.

        WHEN IT IS GIVEN, IT GOES FIRST, and the defect that moved it there was
        the captain's own fresh VM: they said "hello", the gate fired, and what
        came back opened "The records show no work at all right now" and got to
        the reason four lines later. A fleet report is a fine answer to "what is
        happening" and an incoherent one to a greeting. Leading with what
        happened means the captain can always tell a held-back reply from an
        answer, whatever they asked - and the records that follow read as what
        is on offer instead, rather than as a reply to a question nobody asked.

        AND WHEN THERE ARE NO RECORDS EITHER, this says so in one line and stops.
        A board with nothing on it substantiates nothing, so printing "no work,
        nothing waiting" under a held-back greeting adds a paragraph that is
        true, irrelevant, and reads like the screen misunderstood the question.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Ground,
        [string]$Because = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $rows = @($Ground.Rows)
    $decisions = @($Ground.Decisions)

    if ($Because) {
        $lines.Add($Because)
        $lines.Add('')
    }

    if ($Because -and -not $rows.Count -and -not $decisions.Count) {
        # Nothing to offer instead, so one line and stop. Everything below would
        # be true and none of it would be an answer.
        $lines.Add('Nothing is under way and nothing is waiting on you. Ask me again in other words and I will tell you what I find.')
    } else {
        if ($rows.Count) {
            $count = $rows.Count
            $word = if ($count -eq 1) { 'One piece of work' } else { "$count pieces of work" }
            $lines.Add("$word, and this is all of it:")
            foreach ($row in $rows) {
                $where = if ($null -ne $row.Percent) { "$($row.Percent)%" } else { 'no figure given yet' }
                $tail = if ($row.Note) { " - $($row.Note)" } else { '' }
                $lines.Add("- $($row.Label), $where$tail")
            }
        } else {
            $lines.Add('The records show no work at all right now.')
        }

        if ($decisions.Count) {
            $lines.Add('')
            $lines.Add('Waiting on you:')
            foreach ($d in $decisions) {
                $lines.Add("- $(($d.Task -replace '[-_]+', ' ')): $($d.Question)")
            }
        } else {
            $lines.Add('')
            $lines.Add('Nothing is waiting on a decision from you.')
        }
    }
    ($lines -join "`n").Trim()
}

function Test-FmBridgeGrounded {
    <#
        .SYNOPSIS
        Can the records back every claim this reply makes about the work?

        .DESCRIPTION
        The guarantee. It asks the model for nothing and reads only the reply,
        the record snapshot, and what the captain actually said, so its answer
        does not depend on the reply having tried to behave.

        FOUR THINGS ARE CHECKED, and each is one half of a claim the captain
        would act on.

        A NAME. Work is named here by a hyphenated slug - `lock-identity`,
        `tg-route` - or by the same words with spaces, which is how the panel
        prints it and how a sentence says it. Every such name must be a name the
        records carry, or a name the captain themselves used in the question they
        just asked. Nothing else can put a name on the screen.

        A PERCENTAGE. Every percentage must be one the records carry, and when a
        known name shares the line with it, it must be THAT name's percentage.
        This is the criterion the captain can check by looking left at the panel,
        so a reply that fails it is a reply the panel contradicts.

        ANY OTHER FIGURE. A count is a measurement too, and the longest-standing
        invented number on this screen - "1730 pass, 0 failed, 25 not run" - had
        no percent sign anywhere near it. Every number above ten must be one the
        records contain; below eleven is how English counts and how a list
        numbers its own items, and a percentage of any size is held exactly by
        the rule above regardless.

        A RECOMMENDATION. A name the records do not carry may be mentioned - the
        captain asked about it and deserves an answer - but never given a state,
        a percentage, or an action to take. "There are no payment tests" is the
        honest answer. "Stop lock-identity and start the payment tests" is the
        defect.

        WHY THE CAPTAIN'S OWN WORDS COUNT AS A SOURCE. Not as a courtesy: without
        it the gate would block the denial as readily as the invention, and a
        screen that cannot say "that does not exist" has to say something else.

        WHAT IS CHECKED LINE BY LINE, not reply by reply, because the reply this
        exists for was a table - and a table row is a claim whether or not it
        ends in a full stop.

        .PARAMETER Text
        The reply as the session produced it.

        .PARAMETER Ground
        The snapshot from Get-FmBridgeGround.

        .PARAMETER Asked
        What the captain said this turn. Names they used are quotable; names they
        did not are not.

        .PARAMETER AlsoAsked
        What the captain said EARLIER IN THE SAME CONVERSATION, and it counts for
        exactly as much as this turn's words.

        THE DEFECT THIS ENDS. The captain typed "create one dummy task in which
        you start multiple crewmates", and the reply naming it back was held for
        naming work the records do not carry: `the dummy job`. Their own word,
        from their own screen, one turn earlier. The contract says a name may
        come from "the captain's own words" and nothing in it says those words
        expire at the end of the turn - but the code read only the current
        question, so every name the captain introduced became an invention again
        the moment they asked a follow-up.

        A conversation is the unit here, not a message. The caller decides how
        far back that reaches; this only says the words count when they arrive.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Ground,
        [string]$Asked = '',
        [string[]]$AlsoAsked = @()
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Grounded = $true; Unsubstantiated = @() }
    }

    $common = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](Get-FmBridgeCommonModifier), [StringComparer]::OrdinalIgnoreCase)
    # Longest first, so `tests` is not matched as `test` with a stray `s` after
    # it and read as a singular where the grammar below turns on the plural.
    $workNouns = ((Get-FmBridgeWorkNoun).Word | Sort-Object -Property Length -Descending |
        ForEach-Object { [regex]::Escape($_) }) -join '|'

    # What the captain just said. Both as whole names and as single words, since
    # they may write "payment tests" and the reply answer "the payment work".
    $askedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $askedWords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # This turn and everything they said before it in the same conversation. A
    # word of theirs does not stop being theirs when they press return.
    foreach ($said in (@($Asked) + @($AlsoAsked))) {
        if ([string]::IsNullOrWhiteSpace($said)) { continue }
        foreach ($w in [regex]::Matches($said, '[A-Za-z][A-Za-z0-9]*(?:[-\s]+[A-Za-z][A-Za-z0-9]*)?')) {
            $null = $askedKeys.Add((ConvertTo-FmBridgeWorkKey -Text $w.Value))
        }
        foreach ($w in [regex]::Matches($said, '[A-Za-z][A-Za-z0-9]*|\d+')) {
            $null = $askedWords.Add($w.Value.ToLowerInvariant())
        }
    }

    # A URL is not prose and must not be read as one: a path segment inside it
    # has exactly the shape of a name, and the whole of it is the captain's to
    # tap. Masked before anything looks at the text.
    $fence = ([char]1).ToString()
    $body = [regex]::Replace($Text, 'https?://\S+', $fence)

    foreach ($line in ($body -split '(?:\r?\n)|(?<=[.!?])\s+')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $namesAt = [System.Collections.Generic.List[object]]::new()
        # Two kinds of mention, because they are not exposed to the same rules.
        # A DEFINITE one - "the payment tests", or a name the captain used -
        # points at a particular piece of work, so recommending action on it is
        # recommending action on that work. An INDEFINITE one cannot point at
        # anything, so there is nothing to act on; only a state or a figure can
        # turn it into a claim.
        $ungroundedHere = [System.Collections.Generic.List[string]]::new()
        $indefiniteHere = [System.Collections.Generic.List[string]]::new()

        # Which real work this line is about, however it chose to spell it. The
        # panel prints "lock identity" and a reply may write "LOCK IDENTITY" or
        # `lock-identity`; all three have to bind the same percentage, or the
        # cross-check below is looking at the wrong row.
        foreach ($known in $Ground.Names) {
            $spelt = ($known -split '-' | ForEach-Object { [regex]::Escape($_) }) -join '[\s_-]+'
            foreach ($hit in [regex]::Matches($line, "(?i)(?<![A-Za-z0-9])$spelt(?![A-Za-z0-9])")) {
                # WHERE it was said, not only that it was. A reply that lists
                # five runs and five figures in one sentence has to pair them the
                # way a reader pairs them - each figure with the name beside it.
                # Comparing every name against every figure reported twenty
                # mismatches for a sentence that was entirely correct.
                $namesAt.Add([pscustomobject]@{
                        Key = $known; At = $hit.Index; End = $hit.Index + $hit.Length
                    })
            }
        }

        # A name as this system writes one: two or more words joined by hyphens.
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9-])[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+(?![A-Za-z0-9-])')) {
            $raw = $m.Value
            $key = ConvertTo-FmBridgeWorkKey -Text $raw
            if ($Ground.Names.Contains($key)) { continue }
            # A compound the records themselves use is not invention, whatever
            # shape it has. Caught live: a worker wrote "zero mis-pairings" and
            # "the listening-mode setting" into its own record, and the reply
            # repeating those words back was held for naming work that does not
            # exist. It was quoting the record it was given.
            if (Test-FmBridgeWordsRecorded -Text $raw -Ground $Ground) { continue }
            if (Test-FmBridgeDescribingWord -Text $raw) { continue }
            if ($askedKeys.Contains($key)) { $ungroundedHere.Add($raw); continue }
            $found.Add("names work the records do not carry: '$raw'")
        }

        # A name as the panel prints one and as a sentence says one: the same
        # words with spaces, in front of the noun that makes it a piece of work.
        # The nouns come from Get-FmBridgeWorkNoun rather than being spelt out
        # again here, because which of them are also verbs is the thing
        # Test-FmBridgeNamingPhrase below has to know, and two copies of the
        # list would answer that question differently the first time one moved.
        foreach ($m in [regex]::Matches($line, "(?i)\b((?:[A-Za-z][A-Za-z0-9-]*\s+){1,2})($workNouns)\b")) {
            $modifier = $m.Groups[1].Value.Trim()
            # A preposition in the span means the head noun is not being named by
            # what comes before it: "5 pieces OF work", "a lot OF tests". Caught
            # live, and by the sharpest possible witness - the gate held back its
            # own replacement text for naming work that does not exist.
            if ($modifier -match '(?i)\b(?:of|in|on|at|for|to|with|from|by|about|than|and|or)\b') { continue }
            $words = @([regex]::Matches($modifier, '[A-Za-z][A-Za-z0-9-]*') | ForEach-Object { $_.Value })
            if (-not $words.Count) { continue }

            # THE NAME IS THE WORD TOUCHING THE NOUN, not any word before it.
            # "the payment tests" names with "payment"; "the records show no
            # work" names with nothing at all, because what touches "work" is a
            # determiner. Reading the whole span instead made the gate hold back
            # its own replacement for naming work called "show".
            #
            # A determiner, a count and a describing word all sit in front of a
            # work noun without claiming a piece of work by that name - which is
            # what held back "Active work" on a live turn.
            $meaningful = [System.Collections.Generic.List[string]]::new()
            # WHAT STOPPED THE WALK IS EVIDENCE, not just a boundary. The word
            # the walk refused is the one introducing the phrase, and whether it
            # is a determiner is what says a bare singular noun is being named
            # rather than done.
            $stopper = ''
            for ($w = $words.Count - 1; $w -ge 0; $w--) {
                $word = $words[$w]
                if ($common.Contains($word) -or (Test-FmBridgeDescribingWord -Text $word)) {
                    $stopper = $word; break
                }
                $meaningful.Insert(0, $word)
            }
            if (-not $meaningful.Count) { continue }

            # The determiner may sit outside the two words this match reaches
            # back over - "a full test run" puts it three words in front of the
            # noun - so the word before the match counts as an introducer too.
            $ahead = @([regex]::Matches($line.Substring(0, $m.Index), '[A-Za-z][A-Za-z0-9-]*') |
                ForEach-Object { $_.Value })
            $introducer = @($stopper) + @(if ($ahead.Count) { $ahead[-1] } else { '' })

            # AND IS IT A NAME AT ALL. Nine of these nouns are also verbs, and
            # the gate used to read every one of them as a noun: "please run it
            # in your own window" was held back on the captain's fresh VM as
            # work called `Please run`.
            if (-not (Test-FmBridgeNamingPhrase -Head $m.Groups[2].Value `
                        -Modifier @($meaningful) -Introducer $introducer)) {
                continue
            }

            $key = ConvertTo-FmBridgeWorkKey -Text ($meaningful -join '-')
            if ($Ground.Names.Contains($key)) { continue }
            # A whole phrase is not in the records, but its words may be: "the
            # browser run" is describing work the records describe in those very
            # words, and calling that invention would be wrong.
            if (Test-FmBridgeWordsRecorded -Text ($meaningful -join ' ') -Ground $Ground) { continue }

            $phrase = "$modifier $($m.Groups[2].Value)"
            $askedAll = $true
            foreach ($w in $meaningful) { if (-not $askedWords.Contains($w)) { $askedAll = $false; break } }
            if ($askedAll) { $ungroundedHere.Add($phrase); continue }

            # AN INDEFINITE ARTICLE IS A MENTION, NOT A CLAIM, and this is the
            # second half of the defect section 48 got the first half of. That
            # fix stopped `run` and `work` being read as nouns when they were
            # verbs; it left every DETERMINER-led phrase standing, and the
            # captain's screen went on holding "each on a different task", "a
            # harder task", "a smaller job" and "a slower run" - 20 ordinary
            # replies in 38, measured.
            #
            # ENGLISH SETTLES IT WITHOUT A DICTIONARY. `a` and `an` mark
            # indefinite reference: they introduce SOME member of a kind, never
            # a particular named one. "a different task" is any task that
            # differs; "a lock-identity" is not English at all. So this cannot
            # be claiming a named piece of work - whatever adjective sits in the
            # middle, and without any rule here having to know that `different`,
            # `harder` and `separate` are adjectives, which none of them can.
            #
            # A CLOSED CLASS OF TWO, which is why it cannot fall behind the way
            # the describing-word list did four times running.
            #
            # AND IT IS DEMOTED, NOT EXCUSED. "A payment fix has landed" is an
            # invention and stays one: dropping it here entirely turned `the
            # line the narrowing must not cross` red, which is exactly what that
            # test is for. It joins the captain's own words as something that
            # may be MENTIONED and may not be reported on, and the three rules
            # below decide which it is.
            $leadsIndefinite = $false
            foreach ($word in @($introducer)) {
                if ($word) { $leadsIndefinite = @('a', 'an') -contains $word.ToLowerInvariant(); break }
            }
            if ($leadsIndefinite) { $indefiniteHere.Add($phrase); continue }

            $found.Add("names work the records do not carry: '$phrase'")
        }

        # Every percentage is checkable against the panel by looking left, so
        # every percentage has to survive that look.
        $percentHits = @([regex]::Matches($line, '(?i)(\d{1,3})\s*(?:%|per\s?cent)'))
        $percentsHere = @($percentHits | ForEach-Object { [int]$_.Groups[1].Value })
        foreach ($hit in $percentHits) {
            $p = [int]$hit.Groups[1].Value
            if (-not $Ground.Percents.Contains($p)) {
                $found.Add("gives a figure the records do not carry: $p%")
                continue
            }
            # ONLY A PROGRESS FIGURE IS PAIRED WITH A NAME. A record may write a
            # percentage that is not anybody's progress - a decision asking
            # "ship at 80% coverage or wait?" is on the panel in those words -
            # and binding that to whichever run is named beside it would call a
            # correct sentence a mismatch. A figure that is some task's
            # percentage is a progress claim and is checked; one that only ever
            # appears inside a record's prose is quoted, not claimed.
            if (@($Ground.PercentOf.Values) -notcontains $p) { continue }

            # THE NAME BESIDE IT, not every name in the line, and the one in
            # FRONT wins however close the next one is. English writes "lock
            # identity, 75%", so a figure belongs to what precedes it. Both
            # halves of that were learnt the hard way on one live sentence
            # listing five runs and five figures: pairing every name with every
            # figure called it twenty mismatches, and then measuring from the
            # start of each name bound each figure to the NEXT row and called it
            # four. The sentence was right both times.
            $nearest = $null
            $best = [int]::MaxValue
            foreach ($n in $namesAt) {
                if ($n.End -gt $hit.Index) { continue }
                $gap = $hit.Index - $n.End
                if ($gap -lt $best) { $best = $gap; $nearest = $n.Key }
            }
            if (-not $nearest) {
                foreach ($n in $namesAt) {
                    $gap = $n.At - $hit.Index
                    if ($gap -ge 0 -and $gap -lt $best) { $best = $gap; $nearest = $n.Key }
                }
            }
            if ($nearest -and $Ground.PercentOf.ContainsKey($nearest) -and $Ground.PercentOf[$nearest] -ne $p) {
                $found.Add("puts $p% against '$nearest', which the records have at $($Ground.PercentOf[$nearest])%")
            }
        }

        # ANY OTHER FIGURE, not only a percentage. "1730 pass, 0 failed, 25 not
        # run" carried no percent sign and was the oldest invented number on the
        # screen; the captain's rule is that a number either came from something
        # real or does not appear, and a count is a number.
        #
        # ELEVEN AND UP. English counts in small numbers and lists number their
        # own items, so holding those to a record would refuse "1." at the start
        # of a line. A fabricated measurement is not 3 or 7 - it is 1730, or 442
        # pixels, or 79 per cent - and a percentage of any size is already held
        # exactly by the rule above.
        foreach ($m in [regex]::Matches($line, '(?<![\d.,])(\d+)(?![\d.,])')) {
            if ($m.Value.Length -gt 9) { continue }
            $value = [int]$m.Value
            if ($value -le 10) { continue }
            # Left to the percentage rule, which says something more useful
            # about it than this can.
            $after = $line.Substring($m.Index + $m.Length)
            if ($after -match '^\s*(?:%|per\s?cent)') { continue }
            if ($Ground.Numbers.Contains($value)) { continue }
            if ($askedWords.Contains($m.Value)) { continue }
            $found.Add("gives a figure the records do not carry: $value")
        }

        if (-not $ungroundedHere.Count -and -not $indefiniteHere.Count) { continue }

        # From here down the line mentions something the records do not carry.
        # Mentioning it is allowed - the captain raised it, or English only ever
        # raised it as a kind. Reporting on it or acting on it is not.
        $mentioned = @($ungroundedHere) + @($indefiniteHere)
        if ($percentsHere.Count) {
            $found.Add("reports a figure for '$($mentioned[0])', which the records do not carry at all")
        }
        # A STATE, which the contract has named since the day it was written and
        # the code has never checked. "a state, a percentage, or a recommended
        # action" - the figure was checked, the action was checked, and the
        # state was not, which is why section 48.8 had to record `The billing
        # job is green.` as a fabrication that got through and stayed through.
        #
        # It is what tells a mention from a claim. "each on a different task" is
        # the captain being told how crewmates are put out; "A payment fix has
        # landed" is a piece of work being reported finished. Only the second
        # one is something they would act on, and only the second one is here.
        #
        # THE VOCABULARY IS THE RECORDS' OWN - the states a status line actually
        # carries, plus the handful of words English reports an outcome with. A
        # word missing from it costs a mention that should have been held, never
        # a true reply held back, because a line has to be naming unrecorded
        # work before this is consulted at all.
        if ($line -match ('(?i)\b(?:is|are|was|were|has|have|had|came\s+back)\s+(?:been\s+|still\s+|now\s+)?' +
                '(?:green|red|ready|done|finished|failed|blocked|running|landed|merged|passed|passing|' +
                'stalled|paused|complete|completed|clean|broken|under\s+way|in\s+flight|out\s+of\s+date)\b') -or
            $line -match '(?i)\b(?:finished|landed|merged|completed|failed|stalled)\s+(?:overnight|already|today|yesterday|just\s+now)\b') {
            $found.Add("gives a state to '$($mentioned[0])', which the records do not carry at all")
        }
        # DEFINITE REFERENCE ONLY, because acting on something means acting on a
        # PARTICULAR something. "Stop lock-identity and start the payment tests"
        # points at a piece of work and tells the captain to move it; "I would
        # give them a harder task" points at nothing and proposes a kind. Both
        # were being held, and only the first is the defect this rule is for.
        if ($ungroundedHere.Count -and (
                $line -match '(?i)\b(should|shouldn.t|recommend|recommendation|suggest|advise|advice|worth|i.d\s|i\s+would|instead\s+of|in\s+its\s+place|ask\s+(?:there|firstmate|it)|tell\s+(?:firstmate|it))\b' -or
                $line -match '(?i)^\s*(?:\d+[.)]\s*|[-*]\s*|\*\*)?(start|stop|halt|pause|resume|begin|land|merge|kill|switch|swap|replace|take|put|hold|drop|leave|focus|review)\b')) {
            $found.Add("recommends acting on '$($ungroundedHere[0])', which the records do not carry at all")
        }
    }

    [pscustomobject]@{
        Grounded        = ($found.Count -eq 0)
        Unsubstantiated = @($found | Select-Object -Unique)
    }
}

function Protect-FmBridgeReply {
    <#
        .SYNOPSIS
        Deliver the reply, or deliver the records instead. Never both.

        .DESCRIPTION
        The one call the courier makes. A reply the records substantiate goes
        through untouched; one they do not is replaced whole by
        Get-FmBridgeRecordAnswer.

        WHOLE, AND THAT IS THE POINT. The obvious kinder shape - keep the reply
        and append a caution - recreates the defect exactly: true sentences and
        invented ones, in one voice, in one reply, with nothing on screen telling
        the captain which is which. There is no wording of a caution that fixes
        that, so the invented text does not go out at all.

        WHAT THE CAPTAIN LOSES is the assistant's phrasing, and only when the
        gate fires. What they get instead is the same work, the same states and
        the same figures the panel is showing, from the same read.

        .PARAMETER Text
        The reply as the session produced it.

        .PARAMETER Ground
        The snapshot from Get-FmBridgeGround.

        .PARAMETER Asked
        What the captain said this turn.

        .PARAMETER AlsoAsked
        What the captain said earlier in the same conversation. Handed straight
        to Test-FmBridgeGrounded, which owns why it counts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Ground,
        [string]$Asked = '',
        [string[]]$AlsoAsked = @()
    )

    $verdict = Test-FmBridgeGrounded -Text $Text -Ground $Ground -Asked $Asked -AlsoAsked $AlsoAsked
    if ($verdict.Grounded) {
        return [pscustomobject]@{
            Reply           = $Text
            Grounded        = $true
            Unsubstantiated = @()
            At              = $Ground.At
        }
    }

    # SAID FIRST, AND SAID AS SOMETHING THAT HAPPENED. The captain has to be able
    # to tell a held-back reply from an answer, in their own language, without
    # being handed a summary of something they did not ask about. What used to
    # sit at the END of a fleet report - after "the records show no work at all
    # right now", under a greeting - told them nothing until they had already
    # read a page that had nothing to do with what they said.
    # SHORT, AND NOT A CONFESSION. What used to stand here was four lines about
    # an answer the captain could not see, and twice in a row it read as a
    # machine reporting its own fault - which is the one thing the screen's own
    # rule forbids: never answer with something you cannot do. It still says
    # plainly that this is the records rather than the reply, because the
    # captain must be able to tell those apart, and then it gets out of the way.
    $because = 'Let me give you that from the records rather than from memory.'
    [pscustomobject]@{
        Reply           = (Get-FmBridgeRecordAnswer -Ground $Ground -Because $because)
        Grounded        = $false
        Unsubstantiated = @($verdict.Unsubstantiated)
        At              = $Ground.At
    }
}
