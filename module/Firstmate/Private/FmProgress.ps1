#requires -Version 7.0
# FmProgress.ps1 - turning the milestones a worker already reports into a
# percentage the captain can see without asking.
#
# WHY THIS EXISTS. The captain's standing complaint: "I don't have to ask the
# progress for anything each and every time." Before this, the only ways to learn
# how far along a worker was were to ask firstmate, read its status log, or
# attach to its pane - all pull, never push, and all of them cost the captain a
# question.
#
# WHAT IT DELIBERATELY IS NOT. This is not instrumentation and it does not
# measure anything. It reads the percentage the worker itself declares alongside
# its milestone. The captain set the bar explicitly: "I am not expecting hundred
# percent correct statistics and progress report, but at least we have some
# idea." So a coarse figure that is usually roughly right is the goal, and a
# missing figure is reported as unknown rather than guessed at - an invented
# number is worse than no number, because it reads exactly like a real one.
#
# THE WIRE FORMAT is a bracketed percent at the front of a status note:
#
#     working: [40%] retirement owner implemented, writing coverage
#
# It is optional on purpose. Every existing status line stays valid and simply
# reports no percentage, so nothing that already works breaks, and a worker that
# never learned the convention is not misreported as stalled at 0%.

Set-StrictMode -Version Latest

# A status line's percentage, or $null when it carries none. Accepts the bracket
# form at the start of the note and nothing else: a bare "40%" inside prose is
# far more likely to be the subject matter than a progress claim.
function Get-FmProgressPercent {
    # Both are declared because both are real answers: an int when the line
    # carries a percentage, and $null when it does not. Declaring only [object]
    # hides the int from the analyzer; declaring only [int] would misreport the
    # absent case, which is the one this whole file exists to keep honest.
    [OutputType([int], [object])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    # <state>: [NN%] note   - the state prefix is optional so a raw note works too.
    if ($Line -notmatch '^\s*(?:[a-z-]+:\s*)?\[\s*(\d{1,3})\s*%\s*\]') { return $null }
    $value = [int]$Matches[1]
    # A percentage outside 0-100 is a typo, not a measurement. Refuse it rather
    # than clamping: clamping would silently turn 1000 into a confident 100.
    if ($value -lt 0 -or $value -gt 100) { return $null }
    $value
}

# The last percentage a task declared, plus the note that carried it. Reads the
# status log backwards, because the newest claim is the only one that matters and
# a long log should not be parsed in full to answer one question.
function Get-FmProgressFromStatus {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{
        Percent = $null
        Note    = ''
        State   = ''
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    $lines = @([System.IO.File]::ReadAllLines($Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return $result }

    $last = [string]$lines[-1]
    if ($last -match '^\s*([a-z-]+)\s*:') { $result.State = $Matches[1] }
    $result.Note = $last

    # A terminal state is 100% whether or not the worker said so: "done" IS the
    # whole job, and reporting a finished task as 60% because its last numbered
    # line said 60 would be wrong in the one place it matters most.
    if ($result.State -eq 'done') {
        $result.Percent = 100
        return $result
    }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $percent = Get-FmProgressPercent -Line ([string]$lines[$i])
        if ($null -ne $percent) {
            $result.Percent = $percent
            break
        }
    }
    $result
}

# A fixed-width bar. Text, not colour: this has to survive a pane capture, a log
# file and a copy-paste into chat, none of which keep styling.
function Format-FmProgressBar {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Percent,
        [ValidateRange(4, 60)][int]$Width = 20
    )

    if ($null -eq $Percent) { return ('?' * $Width) }
    $value = [Math]::Max(0, [Math]::Min(100, [int]$Percent))
    $filled = [int][Math]::Round(($value / 100.0) * $Width)
    ('#' * $filled) + ('.' * ($Width - $filled))
}
