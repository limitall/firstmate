#requires -Version 7.0
# FmClassify.ps1 (public) - the shared wake classifier: captain-relevant status
# tests, the declared-external-wait vocabulary, and the keyed open-and-resolved
# decision fold. Ported from bin/fm-classify-lib.sh, which both the always-on
# watcher and the away-mode daemon source so the overlapping triage policy has
# one owner.
#
# Everything here is a pure read of a status file except
# Get-FmOpenDecisionIncremental (persists a byte cursor, the documented
# exception) and Get-FmCrewAbsorbClass (reads authoritative current state).

Set-StrictMode -Version Latest

<#
.SYNOPSIS
Leading verb of a status line: the word before the first colon, with any
[key=<slug>] token stripped.
#>
function Get-FmStatusLineVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return '' }
    $colon = $Line.IndexOf(':')
    $verb = if ($colon -ge 0) { $Line.Substring(0, $colon) } else { $Line }
    $keyToken = $verb.IndexOf('[key=')
    if ($keyToken -ge 0) { $verb = $verb.Substring(0, $keyToken) }
    return $verb.Trim()
}

<#
.SYNOPSIS
Text after the first colon of a status line, with leading whitespace trimmed and
a LEADING [key=<slug>] token removed. A line with no colon is its own note.
.DESCRIPTION
The token is metadata, not prose: dropping it here is what keeps the note of
`resolved: [key=api-shape] captain chose flat` equal to the note of
`resolved [key=api-shape]: captain chose flat`, so the reserved-namespace rule
and the recorded summary do not depend on where the writer put the key.
#>
function Get-FmStatusLineNote {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return '' }
    $colon = $Line.IndexOf(':')
    if ($colon -lt 0) { return $Line }
    $note = $Line.Substring($colon + 1).TrimStart()
    if ($note -match '^\[key=[^\]]*\]\s*') { $note = $note.Substring($Matches[0].Length) }
    return $note
}

<#
.SYNOPSIS
Decision key of a status line: the [key=<slug>] token, or "default" when there is
none. Returns $null for a malformed key, which the fold treats as "not a decision
transition".
.DESCRIPTION
The token is read from the text before the colon - the documented grammar - OR
from the LEADING position of the note.

That second position is a deliberate divergence from bin/fm-classify-lib.sh,
which looks before the colon only. bin/fm-brief.sh tells a worker to close with
`resolved: {how it cleared}` "(same [key=<slug>] if you opened it with one)", and
the natural reading of that produces

    resolved: [key=api-shape] captain chose the flat one

which the bash parser folds as the key `default`. That is not a cosmetic parse
difference: it CLOSES whatever unrelated decision holds `default` and leaves
api-shape open forever, defeating the one guarantee this fold exists to make -
that a decision closes only on a line naming it. A key token further inside the
note stays prose (`working: added [key=foo] support` is still `default`), exactly
as bash has it, so no line that parses today changes meaning.
#>
function Get-FmStatusDecisionKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return 'default' }
    $colon = $Line.IndexOf(':')
    $prefix = if ($colon -ge 0) { $Line.Substring(0, $colon) } else { $Line }
    $raw = $null
    $start = $prefix.IndexOf('[key=')
    if ($start -ge 0) {
        $rest = $prefix.Substring($start + '[key='.Length)
        $end = $rest.IndexOf(']')
        if ($end -lt 0) { return 'default' }
        $raw = $rest.Substring(0, $end)
    } elseif ($colon -ge 0) {
        $note = $Line.Substring($colon + 1).TrimStart()
        if ($note -match '^\[key=([^\]]*)\]') { $raw = $Matches[1] }
    }
    if ($null -eq $raw) { return 'default' }
    if ($raw -eq '' -or $raw -notmatch '^[A-Za-z0-9._-]+$') { return $null }
    return $raw
}

<#
.SYNOPSIS
Last non-blank line of a status file, or '' when it is missing or blank.
#>
function Get-FmLastStatusLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $last = ''
    foreach ($line in (Get-FmLifecycleFileLines -Path $Path)) {
        if (($line -replace '\s', '') -ne '') { $last = $line }
    }
    return $last
}

<#
.SYNOPSIS
True when a status line's leading verb is a real terminal captain verb
(done, needs-decision, blocked, failed). Free-text tokens never count here.
#>
function Test-FmStatusIsTerminalVerb {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return ((Get-FmStatusLineVerb -Line $Line) -cin @('done', 'needs-decision', 'blocked', 'failed'))
}

<#
.SYNOPSIS
True when a status line's leading verb is the declared-external-wait verb
(paused: <reason>), matching only the verb so a reason mentioning "paused"
elsewhere never false-matches.
#>
function Test-FmStatusIsPaused {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return ((Get-FmStatusLineVerb -Line $Line) -ceq (Get-FmClassifyPausedVerb))
}

<#
.SYNOPSIS
True when a status line declares either an external-wait pause or a verified
captain-held transfer - both intentionally leave an exited crew's endpoint idle.
#>
function Test-FmStatusIsPausedOrCaptainHeld {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if (Test-FmStatusIsPaused -Line $Line) { return $true }
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    return ((Get-FmStatusLineVerb -Line $Line) -ceq (Get-FmClassifyCaptainHeldVerb))
}

<#
.SYNOPSIS
True when a status line is work firstmate must see.
.DESCRIPTION
Verb-aware: terminal verbs always match; the nonterminal progress verbs
(working, resolved, captain-held) and the pause verb never match, so
"working: rebased onto merged #76" stays absorbed. Only a line with no such
leading verb may still match the legacy free-text tokens (PR ready, checks
green, ready in branch, merged). FM_CAPTAIN_RE replaces the whole token set.
#>
function Test-FmStatusIsCaptainRelevant {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $false }
    if (Test-FmStatusIsPaused -Line $Line) { return $false }
    $verb = Get-FmStatusLineVerb -Line $Line
    if ($verb -cin @('working', 'resolved', 'captain-held', (Get-FmClassifyPausedVerb))) { return $false }
    if (-not (Test-FmClassifyCaptainRegexOverridden)) {
        if ($verb -cin @('done', 'needs-decision', 'blocked', 'failed')) { return $true }
    }
    return ($Line -match (Get-FmClassifyCaptainRegex))
}

<#
.SYNOPSIS
Fold a whole status stream into the decisions still open.
.DESCRIPTION
Prints one record per still-open decision in most-recently-opened-last order.
A needs-decision/blocked line opens a keyed decision and only an explicit
resolved/captain-held line carrying that exact key closes it: a later unrelated
terminal line never clears an open captain decision. Re-reads the file's whole
lifetime; use Get-FmOpenDecisionIncremental on the per-drain path.
#>
function Get-FmOpenDecision {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if (-not (Test-FmLifecycleRegularFile -Path $Path)) { return , @() }
    $open = New-FmClassifyOpenSet
    foreach ($line in (Get-FmLifecycleFileLines -Path $Path)) {
        Add-FmClassifyDecisionFoldLine -OpenSet $open -Line $line
    }
    return , @($open.ToArray())
}

<#
.SYNOPSIS
Cursor-backed sibling of Get-FmOpenDecision: folds only the bytes appended
since the last call, so a per-drain fleet scan stays bounded by new appends
instead of total lifetime log size.
.DESCRIPTION
Persists state/.<task>.open-decisions-cursor as a side effect - the documented
exception to this library's pure-read rule. An open decision is dropped ONLY by
an explicit resolved/captain-held line for its exact key, never by cursor
advancement, age, or being buried under later appends. A fold-version mismatch,
a shrink, or a changed file identity rebuilds from byte 0; an I/O failure
reports the already-trusted persisted set unchanged rather than wiping it.
#>
function Get-FmOpenDecisionIncremental {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if (-not (Test-FmLifecycleRegularFile -Path $Path)) { return , @() }
    $cursorPath = Get-FmClassifyCursorPath -StatusFile $Path
    $cursor = Read-FmClassifyCursor -CursorPath $cursorPath

    $trusted = @()
    foreach ($line in $cursor.OpenLines) {
        $parts = $line.Split("`t", 3)
        if ($parts.Count -eq 3) { $trusted += (New-FmClassifyOpenRecord -Key $parts[0] -Verb $parts[1] -Note $parts[2]) }
    }

    $size = 0L
    try { $size = ([System.IO.FileInfo]::new($Path)).Length } catch { return , @($trusted) }
    # The identity covers the bytes this cursor already consumed, which an
    # append-only file never rewrites. A read failure here is a genuine I/O
    # error, not "nothing is open": report the trusted set unchanged rather than
    # risking a silent invalidation that would wipe it.
    $recordedIdent = ''
    if ($cursor.Offset -gt 0 -and $cursor.Offset -le $size) {
        $recordedIdent = Get-FmClassifyFileIdent -Path $Path -Length $cursor.Offset
        if ($recordedIdent -eq '') { return , @($trusted) }
    }

    $open = New-FmClassifyOpenSet
    $offset = $cursor.Offset
    $dirty = $false
    if ($cursor.Ident -ne $recordedIdent -or $offset -gt $size) {
        $offset = 0
        $trusted = @()
        $dirty = $true
    } else {
        foreach ($record in $trusted) { $open.Add($record) }
    }

    if ($offset -lt $size) {
        $chunk = Read-FmClassifyStatusChunk -Path $Path -Offset $offset -Size $size
        if ($null -eq $chunk) { return , @($trusted) }
        if ($env:FM_OPEN_DECISIONS_READ_PROBE) {
            # Test-only observability seam: records exactly how many bytes this
            # call folded, so a test can assert the incremental path stays
            # bounded by new appends without relying on timing.
            [System.IO.File]::AppendAllText($env:FM_OPEN_DECISIONS_READ_PROBE, "$Path`t$($chunk.Bytes)`n")
        }
        $text = $chunk.Text -replace "`r`n", "`n"
        foreach ($line in $text.Split("`n")) {
            Add-FmClassifyDecisionFoldLine -OpenSet $open -Line $line
        }
        $offset = $size
        $dirty = $true
    }

    if ($dirty) {
        $newIdent = Get-FmClassifyFileIdent -Path $Path -Length $offset
        if ($newIdent -ne '') {
            Write-FmClassifyCursor -CursorPath $cursorPath -Offset $offset -Ident $newIdent -OpenSet $open
        }
    }
    return , @($open.ToArray())
}

<#
.SYNOPSIS
Fleet-wide wrapper: every task's still-open decisions under a state directory,
each tagged with its owning task id, in task-id order.
#>
function Get-FmOpenDecisionScan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StatePath,
        [switch]$Incremental
    )
    $results = @()
    if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { return , $results }
    foreach ($file in (Get-ChildItem -LiteralPath $StatePath -Filter '*.status' -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $task = $file.Name.Substring(0, $file.Name.Length - '.status'.Length)
        $open = if ($Incremental) { Get-FmOpenDecisionIncremental -Path $file.FullName } else { Get-FmOpenDecision -Path $file.FullName }
        foreach ($record in $open) {
            $results += [pscustomobject]@{
                Task = $task
                Key  = $record.Key
                Verb = $record.Verb
                Note = $record.Note
                Line = "$task`t$($record.Line)"
            }
        }
    }
    return , $results
}

<#
.SYNOPSIS
Fold the material routed-work phases still open in a status stream.
.DESCRIPTION
A working or declared-pause event opens or replaces one phase per key; a later
done/failed/needs-decision/blocked/resolved event carrying that key closes it.
This is evidence about whether a parent event was explicitly superseded - never
authoritative current crew state, and it must not outrank Get-FmCrewState.
#>
function Get-FmOpenActivity {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Path,
        [Parameter(ValueFromPipeline)][AllowEmptyString()][string[]]$InputLine
    )
    begin {
        $open = New-FmClassifyOpenSet
        $piped = $false
    }
    process {
        if ($PSBoundParameters.ContainsKey('InputLine')) {
            foreach ($line in $InputLine) {
                $piped = $true
                Add-FmClassifyActivityFoldLine -OpenSet $open -Line $line
            }
        }
    }
    end {
        if (-not $piped -and $Path) {
            foreach ($line in (Get-FmLifecycleFileLines -Path $Path)) {
                Add-FmClassifyActivityFoldLine -OpenSet $open -Line $line
            }
        }
        return , @($open.ToArray())
    }
}

<#
.SYNOPSIS
Task id for a recorded endpoint target, resolved from state metadata when
available and otherwise from the tmux-shaped "<session>:fm-<id>" form.
#>
function Convert-FmWindowToTask {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Position = 1)][AllowEmptyString()][string]$StatePath
    )
    if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Container)) {
        foreach ($meta in (Get-ChildItem -LiteralPath $StatePath -Filter '*.meta' -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $recordedWindow = Get-FmMetaValue -Path $meta.FullName -Key 'window'
            $recordedTerminal = Get-FmMetaValue -Path $meta.FullName -Key 'terminal'
            if ($recordedWindow -eq $Window -or $recordedTerminal -eq $Window) {
                return $meta.Name.Substring(0, $meta.Name.Length - '.meta'.Length)
            }
        }
    }
    $task = $Window
    $colon = $task.LastIndexOf(':')
    if ($colon -ge 0) { $task = $task.Substring($colon + 1) }
    if ($task.StartsWith('fm-')) { $task = $task.Substring(3) }
    return $task
}

<#
.SYNOPSIS
True when any status file named by a "signal:" wake carries a captain-relevant
last line. A false result is not "benign" on its own - a no-verb signal is
benign only when the crew is also provably working.
#>
function Test-FmSignalReasonIsActionable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Path)
    foreach ($file in $Path) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        if (-not $file.EndsWith('.status')) { continue }
        $last = Get-FmLastStatusLine -Path $file
        if ($last -eq '') { continue }
        if (Test-FmStatusIsCaptainRelevant -Line $last) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Why an idle or stale crew MIGHT be safely absorbed instead of surfaced:
"working", "paused", or "none".
.DESCRIPTION
Reads the one authoritative current-state line rather than the status log, so a
crew that appended paused: but then started a run reports working, never paused.
NOT a pure read - callers run it only on no-verb signal and first-sighting stale
paths, never on every wake.
#>
function Get-FmCrewAbsorbClass {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id,
        [scriptblock]$StateLineProvider
    )
    if ([string]::IsNullOrEmpty($Id)) { return 'none' }
    $line = ''
    try {
        if ($StateLineProvider) {
            $line = [string](& $StateLineProvider $Id)
        } elseif ($env:FM_CREW_STATE_BIN -and (Test-Path -LiteralPath $env:FM_CREW_STATE_BIN -PathType Leaf)) {
            $line = [string](& $env:FM_CREW_STATE_BIN $Id)
        } else {
            $line = [string](Get-FmCrewState -Id $Id)
        }
    } catch {
        return 'none'
    }
    if ([string]::IsNullOrEmpty($line)) { return 'none' }
    $line = $line.Split("`n")[0].Trim()
    if (-not $line.StartsWith('state:')) { return 'none' }
    $state = ($line.Substring('state: '.Length) -split ' ')[0]
    if ($state -eq 'paused') { return 'paused' }
    if ($state -eq 'working') {
        $sourceIndex = $line.IndexOf('source: ')
        if ($sourceIndex -ge 0) {
            $source = ($line.Substring($sourceIndex + 'source: '.Length) -split ' ')[0]
            if ($source -in @('run-step', 'pane')) { return 'working' }
        }
    }
    return 'none'
}

<#
.SYNOPSIS
True when a crew shows POSITIVE evidence it is still working. A no-verb
turn-end or stale wake is absorbed only on this evidence, and surfaced
otherwise.
#>
function Test-FmCrewProvablyWorking {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id,
        [scriptblock]$StateLineProvider
    )
    return ((Get-FmCrewAbsorbClass @PSBoundParameters) -eq 'working')
}

<#
.SYNOPSIS
True when a crew's authoritative current state is a declared external-wait pause.
#>
function Test-FmCrewIsPaused {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id,
        [scriptblock]$StateLineProvider
    )
    return ((Get-FmCrewAbsorbClass @PSBoundParameters) -eq 'paused')
}

<#
.SYNOPSIS
True when EVERY task referenced by a no-verb "signal:" wake is provably
working. An empty or unresolvable list is not benign and returns false.
#>
function Test-FmSignalCrewProvablyWorking {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Path,
        [scriptblock]$StateLineProvider
    )
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Path) {
        $base = Split-Path -Leaf $file
        $task = $null
        if ($base.EndsWith('.status')) { $task = $base.Substring(0, $base.Length - '.status'.Length) }
        elseif ($base.EndsWith('.turn-ended')) { $task = $base.Substring(0, $base.Length - '.turn-ended'.Length) }
        else { continue }
        if (-not $task) { continue }
        if ($seen.Contains($task)) { continue }
        $seen.Add($task)
        $callArgs = @{ Id = $task }
        if ($StateLineProvider) { $callArgs['StateLineProvider'] = $StateLineProvider }
        if (-not (Test-FmCrewProvablyWorking @callArgs)) { return $false }
    }
    return ($seen.Count -gt 0)
}

<#
.SYNOPSIS
True when a stale endpoint's last status line is captain-relevant. A false
result only means "non-terminal"; the caller then applies its own
provably-working or persistence recheck.
#>
function Test-FmStaleIsTerminal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Window,
        [Parameter(Mandatory, Position = 1)][string]$StatePath
    )
    $task = Convert-FmWindowToTask -Window $Window -StatePath $StatePath
    $last = Get-FmLastStatusLine -Path (Join-Path $StatePath "$task.status")
    if ($last -eq '') { return $false }
    return (Test-FmStatusIsCaptainRelevant -Line $last)
}

<#
.SYNOPSIS
Every state/*.status whose last line is captain-relevant - the cheap fleet scan
both supervisors run as a backstop. No dedup: each consumer dedupes against its
own seen-state.
#>
function Get-FmCaptainRelevantStatus {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory, Position = 0)][string]$StatePath)
    $results = @()
    if (-not (Test-Path -LiteralPath $StatePath -PathType Container)) { return , $results }
    foreach ($file in (Get-ChildItem -LiteralPath $StatePath -Filter '*.status' -File -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $last = Get-FmLastStatusLine -Path $file.FullName
        if (-not (Test-FmStatusIsCaptainRelevant -Line $last)) { continue }
        $task = $file.Name.Substring(0, $file.Name.Length - '.status'.Length)
        $results += [pscustomobject]@{
            Path = $file.FullName
            Task = $task
            Line = $last
        }
    }
    return , $results
}
