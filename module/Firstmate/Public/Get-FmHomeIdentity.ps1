#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Who the firstmate of this home is, in this home's own words.

.DESCRIPTION
    THE DEFECT THIS ENDS. Asked "who are you and what you can do ?" the screen
    answered as the model behind it - "Claude is the model behind me, built by
    Anthropic" - and only then said what it could do. The capability half was
    right. The identity half answered a question nobody asked: the captain
    wanted to know who it IS, and got the vendor of the machinery.

    WHY THIS IS A FACT RATHER THAN AN ANSWER. The obvious shape is a fixed reply
    the screen returns whenever it recognises an identity question, which needs
    something at the door deciding which questions those are. That is a phrase
    list, and this repository has now watched a phrase list fall one defect
    behind twice - `Test-FmBridgeDescribingWord` across four live turns, then
    the naming grammar again in section 51. The captain will ask "what are you",
    "who made you", "whose are you", or ask it in the middle of a sentence about
    something else, and a list will not have that phrasing.

    So nothing here recognises anything. The identity is handed to the session
    on EVERY turn, the way the fleet reading and the route already are, and the
    session answers whatever was actually asked out of a truth it always holds.
    There is no trigger to keep current because there is no trigger.

    WHY IT IS PER-HOME AND NOT IN THE CONTRACT. This is one home's answer. The
    captain's firstmate was made for Adit by Dhaval Bhalodia; the next home's
    was not, and `AGENTS.md` travels to every home. `config/` is where this port
    already keeps a standing choice that is the captain's to make and nobody
    else's - `config/captain-name` is the same shape, the same lifetime and the
    same privacy - so the identity sits beside it and is gitignored with it.

    NOT data/captain.md, which is the neighbouring near-miss. That file is about
    the CAPTAIN: their preferences and working style. This is about the
    firstmate. One file answering both questions would have two owners the first
    time either changed.

    WHAT AN UNSET HOME GETS. Not a blank and not a placeholder, but the sentence
    that is true of every firstmate there has ever been. A home that never
    writes the file still answers the question properly; it just answers it
    generically, which is the honest answer when nobody has said otherwise.

.PARAMETER ConfigDir
    The home's config directory. Defaults to this home's.

.EXAMPLE
    Get-FmHomeIdentity
    I am your firstmate: the hand that runs your work on this machine and reports back to you.

.EXAMPLE
    Set-Content config/identity 'I am a firstmate, made for Adit by Dhaval Bhalodia, to help you work on the Adit app products.'
    Get-FmHomeIdentity
    I am a firstmate, made for Adit by Dhaval Bhalodia, to help you work on the Adit app products.
#>
function Get-FmHomeIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ConfigDir)

    # True of every firstmate, so a home that has set nothing still answers the
    # captain's first question rather than showing them a gap.
    $default = 'I am your firstmate: the hand that runs your work on this machine and reports back to you.'

    if (-not $ConfigDir) { $ConfigDir = Get-FmConfigRoot }
    $file = Join-Path $ConfigDir 'identity'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $default }

    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($file) } catch { return $default }

    # Prose rather than one line, because "made for Adit by Dhaval Bhalodia to
    # help with the Adit app products" does not fit on the single line an
    # address does. Comments and blank lines are dropped so the file can carry a
    # note to whoever edits it next, and the rest is joined into one paragraph
    # because that is how it is handed to the session.
    $body = @($raw -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }) -join ' '

    if ([string]::IsNullOrWhiteSpace($body)) { return $default }

    # BOUNDED, and this bound is load-bearing rather than tidiness. The words of
    # this file are handed to the reply gate as words the records use, exactly
    # as a worker's own status note is, so a home that pasted a document here
    # would be widening the gate's vocabulary by a document. A few sentences is
    # an identity; a page is something else, and is cut.
    if ($body.Length -gt 600) {
        $body = $body.Substring(0, 600)
        # Cut at a word rather than through one, since this is read aloud.
        $lastSpace = $body.LastIndexOf(' ')
        if ($lastSpace -gt 400) { $body = $body.Substring(0, $lastSpace) }
        $body = $body.TrimEnd() + '...'
    }
    $body
}
