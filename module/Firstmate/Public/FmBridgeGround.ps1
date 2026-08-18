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
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Ground,
        [string]$Because = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $rows = @($Ground.Rows)
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

    $decisions = @($Ground.Decisions)
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

    if ($Because) {
        $lines.Add('')
        $lines.Add($Because)
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
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Ground,
        [string]$Asked = ''
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Grounded = $true; Unsubstantiated = @() }
    }

    $common = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](Get-FmBridgeCommonModifier), [StringComparer]::OrdinalIgnoreCase)

    # What the captain just said. Both as whole names and as single words, since
    # they may write "payment tests" and the reply answer "the payment work".
    $askedKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $askedWords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Asked) {
        foreach ($w in [regex]::Matches($Asked, '[A-Za-z][A-Za-z0-9]*(?:[-\s]+[A-Za-z][A-Za-z0-9]*)?')) {
            $null = $askedKeys.Add((ConvertTo-FmBridgeWorkKey -Text $w.Value))
        }
        foreach ($w in [regex]::Matches($Asked, '[A-Za-z][A-Za-z0-9]*|\d+')) {
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
        $ungroundedHere = [System.Collections.Generic.List[string]]::new()

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
        foreach ($m in [regex]::Matches($line,
                '(?i)\b((?:[A-Za-z][A-Za-z0-9-]*\s+){1,2})(tests?|task|tasks|work|fix|fixes|job|jobs|run|runs|branch|branches|lane|lanes)\b')) {
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
            for ($w = $words.Count - 1; $w -ge 0; $w--) {
                $word = $words[$w]
                if ($common.Contains($word) -or (Test-FmBridgeDescribingWord -Text $word)) { break }
                $meaningful.Insert(0, $word)
            }
            if (-not $meaningful.Count) { continue }

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

        if (-not $ungroundedHere.Count) { continue }

        # From here down the line mentions something the records do not carry.
        # Mentioning it is allowed - the captain raised it. Reporting on it or
        # acting on it is not.
        if ($percentsHere.Count) {
            $found.Add("reports a figure for '$($ungroundedHere[0])', which the records do not carry at all")
        }
        if ($line -match '(?i)\b(should|shouldn.t|recommend|recommendation|suggest|advise|advice|worth|i.d\s|i\s+would|instead\s+of|in\s+its\s+place|ask\s+(?:there|firstmate|it)|tell\s+(?:firstmate|it))\b' -or
            $line -match '(?i)^\s*(?:\d+[.)]\s*|[-*]\s*|\*\*)?(start|stop|halt|pause|resume|begin|land|merge|kill|switch|swap|replace|take|put|hold|drop|leave|focus|review)\b') {
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
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Ground,
        [string]$Asked = ''
    )

    $verdict = Test-FmBridgeGrounded -Text $Text -Ground $Ground -Asked $Asked
    if ($verdict.Grounded) {
        return [pscustomobject]@{
            Reply           = $Text
            Grounded        = $true
            Unsubstantiated = @()
            At              = $Ground.At
        }
    }

    $because = 'I had more to say than that, but the rest was not in the records I read, ' +
    'so I have left it out rather than guess. Ask me about any one of these and I will ' +
    'tell you what the records say about it.'
    [pscustomobject]@{
        Reply           = (Get-FmBridgeRecordAnswer -Ground $Ground -Because $because)
        Grounded        = $false
        Unsubstantiated = @($verdict.Unsubstantiated)
        At              = $Ground.At
    }
}
