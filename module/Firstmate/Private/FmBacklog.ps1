#requires -Version 7.0
# FmBacklog.ps1 - the manual backlog backend, and the backend-selection probe
# ported from bin/fm-tasks-axi-lib.sh.
#
# WHY A REAL BACKEND, NOT A STUB. `config/backlog-backend manual` is firstmate's
# own documented fallback: with it set, firstmate hand-edits data/backlog.md
# instead of calling tasks-axi for routine mutations. docs/configuration.md is
# explicit that "the file format is unchanged in both modes; tasks-axi and manual
# edits produce the same ## In flight, ## Queued, and ## Done sections", so the
# manual path is not a lesser format - it is the SAME format, written by hand.
# This file is that hand, mechanised: the same grammar, the same canonical
# rendering, the same idempotent verbs, the same retention.
#
# THE FORMAT OWNER IS TASKS-AXI. Its markdown backend
# (dist/src/backends/markdown-grammar.js and markdown.js of tasks-axi 0.2.5) is
# the specification this port was written against, function by function:
# the three bullet shapes, the trailing tag region, link derivation, the
# canonical prose order, the two-space body continuation, byte-exact re-emit of
# untouched entries, and the advisory `<path>.lock` protocol. A file this port
# writes must stay readable and re-writable by tasks-axi on a Linux firstmate, so
# nothing here may "improve" the format.
#
# BYTE-EXACT ROUND TRIP. Parsing keeps every entry's original lines; rendering
# re-emits those lines verbatim unless the entry was mutated. So editing one
# queued item can never reflow another item's prose, reorder its tags, or drop a
# hand-written note - the property tasks-axi calls "byte-exact markdown round
# trip", and the reason a firstmate can safely alternate between the two tools.
#
# WHAT IS DELIBERATELY REFUSED. Public-followup obligations carry typed metadata
# in an HTML comment and have their own dedicated command family. This port
# never creates one, and refuses every generic mutation on one - exactly as
# tasks-axi refuses "Public-followup state cannot change through generic
# transitions". They still round-trip byte-exact, and retention never archives an
# active one. Refusing is the safe direction: a corrupted public obligation is a
# broken promise to someone outside the fleet.
#
# TASKS-AXI ON WINDOWS. tasks-axi is a pure-JavaScript npm package (`type:
# module`, `engines: node >= 20`, dependencies @toon-format/toon and axi-sdk-js,
# no native addons, no postinstall, no POSIX-only API in the markdown backend),
# so there is no structural reason it would not run under node.exe. That is
# evidence of portability, not a measurement: nothing here was run on Windows.
# The design report's port map lists tasks-axi's platform support as unknown and
# settles v1 on the manual backend, so this port ships the manual backend as a
# first-class implementation and still prefers a compatible tasks-axi when one is
# selected and present - the same precedence bin/fm-session-start.sh uses.

# --- backend selection (port of bin/fm-tasks-axi-lib.sh) ----------------------

# The axi-family floor. This file is the single owner of the constant, exactly as
# the bash library is on the other side.
$script:FmTasksAxiMinimumVersion = '0.2.4'

function Test-FmBacklogBackendManual {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ConfigDir)

    (Get-FmBacklogBackend -ConfigDir $ConfigDir) -eq 'manual'
}

# Compatible means tasks-axi --version reports the floor or newer, `update
# --help` exposes --archive-body for recoverable note rewrites, and `mv --help`
# exposes [<id>...] for the atomic multi-ID moves secondmate handoffs require.
# The feature probes stay as defense in depth for stripped or forked builds that
# advertise a current version without those flags.
#
# The verdict is memoised for the process and can be handed across ONE process
# hop in FM_TASKS_AXI_COMPATIBLE, so a session start and its bootstrap child pay
# the three subprocesses once. Both layers are bounded by process lifetime, so an
# install or upgrade is picked up by the next process rather than cached to disk.
$script:FmTasksAxiCompatibleMemo = $null

function Test-FmTasksAxiCompatible {
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Force)

    if ($Force) { $script:FmTasksAxiCompatibleMemo = $null }
    # A verdict handed in by a parent process wins over anything this process
    # probed earlier, matching the bash library, which consumes the variable at
    # source time before any probe can run. Only exactly 0 or 1 is honoured.
    if (-not $Force) {
        if ($env:FM_TASKS_AXI_COMPATIBLE -eq '1') { return $true }
        if ($env:FM_TASKS_AXI_COMPATIBLE -eq '0') { return $false }
    }
    if ($null -ne $script:FmTasksAxiCompatibleMemo) { return $script:FmTasksAxiCompatibleMemo }

    $verdict = Test-FmTasksAxiCompatibleProbe
    $script:FmTasksAxiCompatibleMemo = $verdict
    $verdict
}

function Test-FmTasksAxiCompatibleProbe {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)) { return $false }

    $version = Invoke-FmSessionCommandLine -Command 'tasks-axi' -Arguments @('--version')
    if ($version.ExitCode -ne 0) { return $false }
    $parsed = ''
    foreach ($line in $version.Output) {
        if ($line -match '(\d+)\.(\d+)\.(\d+)') { $parsed = $Matches[0]; break }
    }
    # An unparseable version is incompatible, never assumed current, so a
    # development or vendored build cannot pass a floor it was never checked
    # against.
    if ([string]::IsNullOrEmpty($parsed)) { return $false }
    if (-not (Test-FmBacklogVersionAtLeast -Version $parsed -Minimum $script:FmTasksAxiMinimumVersion)) { return $false }

    $update = Invoke-FmSessionCommandLine -Command 'tasks-axi' -Arguments @('update', '--help')
    if (-not (($update.Output -join "`n").Contains('--archive-body'))) { return $false }
    $mv = Invoke-FmSessionCommandLine -Command 'tasks-axi' -Arguments @('mv', '--help')
    (($mv.Output -join "`n").Contains('[<id>...]'))
}

function Test-FmBacklogVersionAtLeast {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Minimum
    )

    $left = @($Version -split '\.')
    $right = @($Minimum -split '\.')
    if ($left.Count -ne 3 -or $right.Count -ne 3) { return $false }
    for ($i = 0; $i -lt 3; $i++) {
        if ($left[$i] -notmatch '^\d+$' -or $right[$i] -notmatch '^\d+$') { return $false }
        if ([int]$left[$i] -gt [int]$right[$i]) { return $true }
        if ([int]$left[$i] -lt [int]$right[$i]) { return $false }
    }
    $true
}

# --- .tasks.toml ---------------------------------------------------------------
#
# The same deliberately tiny reader tasks-axi ships: a top-level `backend` key
# and a `[markdown]` table with `path`, `archive` and `done_keep`. Not a general
# TOML parser, on purpose - the config surface is three keys and a general parser
# would be a second thing to keep correct.

function ConvertFrom-FmBacklogConfigToml {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $config = [pscustomobject]@{ Backend = ''; Path = ''; Archive = ''; DoneKeep = $null }
    $table = 'root'
    foreach ($raw in (($Text -replace "`r`n", "`n") -split "`n")) {
        $line = (Remove-FmBacklogTomlComment -Text $raw).Trim()
        if ($line -eq '') { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $table = if ($Matches[1].Trim() -eq 'markdown') { 'markdown' } else { 'unsupported' }
            continue
        }
        if ($table -eq 'unsupported') { continue }
        if ($line -notmatch '^([A-Za-z0-9_]+)\s*=\s*(.*)$') {
            throw 'Invalid config line: expected `key = value`'
        }
        $key = $Matches[1]
        $value = $Matches[2]
        if ($table -eq 'root') {
            if ($key -eq 'backend') { $config.Backend = Get-FmBacklogTomlString -Value $value -Source 'backend' }
            continue
        }
        switch ($key) {
            'path' { $config.Path = Get-FmBacklogTomlString -Value $value -Source 'markdown.path' }
            'archive' { $config.Archive = Get-FmBacklogTomlString -Value $value -Source 'markdown.archive' }
            'done_keep' {
                if ($value.Trim() -notmatch '^-?\d+$') { throw 'markdown.done_keep must be an integer' }
                $config.DoneKeep = [int]$value.Trim()
            }
        }
    }
    $config
}

function Remove-FmBacklogTomlComment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Trims a comment off a TOML string in memory and changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $quote = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($quote -ne '') {
            if ($ch -eq $quote) { $quote = '' }
            continue
        }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; continue }
        if ($ch -eq '#') { return $Text.Substring(0, $i) }
    }
    $Text
}

function Get-FmBacklogTomlString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Source
    )

    $trimmed = $Value.Trim()
    if ($trimmed.StartsWith('"') -or $trimmed.StartsWith("'")) {
        $quote = $trimmed[0]
        if ($trimmed.Length -lt 2 -or -not $trimmed.EndsWith($quote)) {
            throw "$Source has an unterminated quoted value"
        }
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    throw "$Source must be a quoted string"
}

# --- grammar -------------------------------------------------------------------

$script:FmBacklogIdPattern = '[A-Za-z0-9][A-Za-z0-9._-]*'
$script:FmBacklogDatePattern = '\d{4}-\d{2}-\d{2}'
$script:FmBacklogHoldKinds = @('captain', 'external', 'load', 'parked', 'future')
$script:FmBacklogDepTypes = @('blocked-by', 'parent', 'discovered-from')
$script:FmBacklogStateOrder = @('in_flight', 'queued', 'done')
$script:FmBacklogSectionHeaders = @{ in_flight = '## In flight'; queued = '## Queued'; done = '## Done' }
$script:FmBacklogPublicFollowupKind = 'public-followup'
$script:FmBacklogPublicFollowupMarker = 'tasks-axi:public-followup'

function Get-FmBacklogToday {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Local date, not UTC: firstmate's dates are local, and a UTC stamp would
    # disagree with the dates a Linux firstmate writes on the same evening.
    (Get-Date).ToString('yyyy-MM-dd')
}

function Test-FmBacklogId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id)
    [bool]($Id -match "^$($script:FmBacklogIdPattern)$")
}

function Assert-FmBacklogId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id)

    if (-not (Test-FmBacklogId -Id $Id)) {
        throw "invalid task id `"$Id`": ids match $($script:FmBacklogIdPattern)"
    }
    $Id
}

# Derive typed links by scanning prose. Links live in the prose, not as tags, so
# they are never duplicated or relocated on re-render.
function Get-FmBacklogLink {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $links = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $add = {
        param($kind, $raw)
        $url = $raw -replace '[).,;]+$', ''
        if (-not $seen.Add($url)) { return }
        $links.Add([pscustomobject]@{ Kind = $kind; Url = $url })
    }
    foreach ($m in [regex]::Matches($Text, 'https?://\S+?/pull/\d+')) { & $add 'pr' $m.Value }
    foreach ($m in [regex]::Matches($Text, '\bdata/\S+?/report\.md\b')) { & $add 'report' $m.Value }
    foreach ($m in [regex]::Matches($Text, 'https?://\S+')) {
        if ($m.Value -match '/pull/\d+') { continue }
        & $add 'doc' $m.Value
    }
    @($links)
}

# The kind implied by a leading prose word (legacy display), or ''.
function Get-FmBacklogLeadingKind {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

    if ($Title -match '^PERSISTENT SECONDMATE\b') { return 'secondmate' }
    if ($Title -match '^SHIP\b') { return 'ship' }
    if ($Title -match '^SCOUT\b') { return 'scout' }
    if ($Title -match '^DOCS-ONLY\b') { return 'docs' }
    ''
}

# Pull the canonical inline tags off the TRAILING tag region of a bullet's
# content, returning the clean prose title plus the structured fields. Only the
# trailing region is consumed, so a mid-sentence parenthetical (for example
# "report.md (reported 2026-06-22): ...") stays verbatim in the prose and is
# never duplicated or relocated on re-render.
function Get-FmBacklogTaskTag {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Rest)

    $id = $script:FmBacklogIdPattern
    $date = $script:FmBacklogDatePattern
    $dep = '(?:' + ($script:FmBacklogDepTypes -join '|') + ')'
    $holdKind = ($script:FmBacklogHoldKinds -join '|')

    $tailDep = "\s*($dep):\s*($id)(?:\s+-\s+((?:(?!\s+${dep}:\s).)+?))?\s*$"
    $tailRepo = '\s*\((?:[^()]*\+\s*)?repo:\s*([^)]+)\)\s*$'
    $tailKind = '\s*\(kind:\s*([^)]+)\)\s*$'
    $tailPriority = '\s*\(priority:\s*([0-4])\)\s*$'
    $tailSince = "\s*\(since\s+($date)\)\s*$"
    $tailClosed = "\s*\((?:merged|reported|done|closed)\s+($date)\)\s*$"
    $tailHold = '\s*\(hold:\s*([^()]+)\)\s*$'
    $tailHoldKind = "\s*\(hold-kind:\s*($holdKind)\)\s*$"
    $tailHoldUntil = "\s*\(hold-until:\s*($date)\)\s*$"

    $deps = [System.Collections.Generic.List[object]]::new()
    $title = $Rest
    $repo = ''; $kindTag = ''; $created = ''; $closed = ''
    $priority = $null; $holdReason = ''; $holdKindValue = ''; $holdUntil = ''

    $stripping = $true
    while ($stripping) {
        $stripping = $false

        $m = [regex]::Match($title, $tailDep)
        if ($m.Success) {
            $record = [pscustomobject]@{ Type = $m.Groups[1].Value; Id = $m.Groups[2].Value; Reason = '' }
            if ($m.Groups[3].Success) { $record.Reason = $m.Groups[3].Value }
            $deps.Insert(0, $record)
            $title = $title.Substring(0, $m.Index)
            $stripping = $true
            continue
        }
        $m = [regex]::Match($title, $tailRepo)
        if ($m.Success) {
            if ($repo -eq '') { $repo = $m.Groups[1].Value.Trim() }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailKind)
        if ($m.Success) {
            if ($kindTag -eq '') { $kindTag = $m.Groups[1].Value.Trim() }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailPriority)
        if ($m.Success) {
            if ($null -eq $priority) { $priority = [int]$m.Groups[1].Value }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailSince)
        if ($m.Success) {
            if ($created -eq '') { $created = $m.Groups[1].Value }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailClosed)
        if ($m.Success) {
            if ($closed -eq '') { $closed = $m.Groups[1].Value }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailHoldUntil)
        if ($m.Success) {
            if ($holdUntil -eq '') { $holdUntil = $m.Groups[1].Value }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailHoldKind)
        if ($m.Success) {
            if ($holdKindValue -eq '') { $holdKindValue = $m.Groups[1].Value }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
        $m = [regex]::Match($title, $tailHold)
        if ($m.Success) {
            if ($holdReason -eq '') { $holdReason = $m.Groups[1].Value.Trim() }
            $title = $title.Substring(0, $m.Index); $stripping = $true; continue
        }
    }

    $title = $title.Trim()
    $kind = if ($kindTag -ne '') { $kindTag } else { Get-FmBacklogLeadingKind -Title $title }
    $hold = $null
    if ($holdReason -ne '') {
        $hold = [pscustomobject]@{ Reason = $holdReason; Kind = $holdKindValue; Until = $holdUntil }
    }

    [pscustomobject]@{
        Title    = $title
        Kind     = $kind
        Repo     = $repo
        Deps     = @($deps)
        Created  = $created
        Closed   = $closed
        Priority = $priority
        Hold     = $hold
        Links    = @(Get-FmBacklogLink -Text $title)
    }
}

function Get-FmBacklogClosureVerb {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Task)

    foreach ($link in $Task.Links) { if ($link.Kind -eq 'pr') { return 'merged' } }
    foreach ($link in $Task.Links) { if ($link.Kind -eq 'report') { return 'reported' } }
    'done'
}

# Build the canonical single-line prose: clean title, then canonical tags in a
# fixed order. A bare dependency edge sits right after the title; an edge that
# carries a free-text reason runs to the end of the line and is therefore emitted
# after the parenthetical tags, so a re-parse strips the parentheticals first and
# the reason never swallows a trailing tag.
function New-FmBacklogTaskProse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Formats a task line in memory and changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Task)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($Task.Title.Trim())
    foreach ($dep in $Task.Deps) {
        if ([string]::IsNullOrEmpty($dep.Reason)) { $parts.Add("$($dep.Type): $($dep.Id)") }
    }
    if (-not [string]::IsNullOrEmpty($Task.Repo)) { $parts.Add("(repo: $($Task.Repo))") }
    if (-not [string]::IsNullOrEmpty($Task.Kind) -and
        (Get-FmBacklogLeadingKind -Title $Task.Title) -ne $Task.Kind) {
        $parts.Add("(kind: $($Task.Kind))")
    }
    if ($null -ne $Task.Priority) { $parts.Add("(priority: $($Task.Priority))") }
    if ($Task.State -ne 'done' -and -not [string]::IsNullOrEmpty($Task.Created)) {
        $parts.Add("(since $($Task.Created))")
    }
    if ($Task.State -eq 'done' -and -not [string]::IsNullOrEmpty($Task.Closed)) {
        $parts.Add("($(Get-FmBacklogClosureVerb -Task $Task) $($Task.Closed))")
    }
    if ($null -ne $Task.Hold) {
        $parts.Add("(hold: $($Task.Hold.Reason))")
        if (-not [string]::IsNullOrEmpty($Task.Hold.Kind)) { $parts.Add("(hold-kind: $($Task.Hold.Kind))") }
        if (-not [string]::IsNullOrEmpty($Task.Hold.Until)) { $parts.Add("(hold-until: $($Task.Hold.Until))") }
    }
    foreach ($dep in $Task.Deps) {
        if (-not [string]::IsNullOrEmpty($dep.Reason)) { $parts.Add("$($dep.Type): $($dep.Id) - $($dep.Reason)") }
    }
    (@($parts | Where-Object { $_.Length -gt 0 }) -join ' ')
}

# Both in-flight and queued render as the GitHub-style unchecked checkbox, which
# is firstmate's real backlog format; the section header carries the state. A
# legacy `- **<id>**` line is still parsed, and normalises to `- [ ]` when its
# entry is rewritten - never the other way round.
function Get-FmBacklogBulletPrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Id
    )
    if ($State -eq 'done') { return "- [x] $Id - " }
    "- [ ] $Id - "
}

# Render a task to its canonical source lines: bullet, typed metadata, body.
function Get-FmBacklogTaskLine {
    [CmdletBinding()]
    [OutputType([string[]], [array])]
    param([Parameter(Mandatory)]$Task)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-FmBacklogBulletPrefix -State $Task.State -Id $Task.Id) + (New-FmBacklogTaskProse -Task $Task))
    if (-not [string]::IsNullOrEmpty($Task.PublicFollowupMetadata)) {
        $lines.Add("  $($Task.PublicFollowupMetadata)")
    }
    if (-not [string]::IsNullOrEmpty($Task.Body)) {
        foreach ($bodyLine in ($Task.Body -split "`n")) {
            # A blank body paragraph stays blank, not two spaces; indented content
            # keeps the two-space continuation prefix used throughout the grammar.
            $lines.Add($(if ($bodyLine -eq '') { '' } else { "  $bodyLine" }))
        }
    }
    @($lines)
}

function Get-FmBacklogSectionState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$HeaderLine)

    $line = $HeaderLine.TrimEnd("`r")
    if ($line -notmatch '^##\s+(.*?)\s*$') { return '' }
    $text = $Matches[1].ToLowerInvariant()
    if ($text -eq 'in flight') { return 'in_flight' }
    if ($text -eq 'queued') { return 'queued' }
    if ($text.StartsWith('done')) { return 'done' }
    ''
}

function Get-FmBacklogTaskBullet {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$State
    )

    $id = $script:FmBacklogIdPattern
    $patterns = switch ($State) {
        'done' { @("^- \[x\] ($id) - (.*)$") }
        'queued' { @("^- \[ \] ($id) - (.*)$") }
        # In flight accepts both the checkbox firstmate writes and the older
        # `- **<id>**` bullet, so a file either tool wrote is readable by the other.
        default { @("^- \*\*($id)\*\* - (.*)$", "^- \[ \] ($id) - (.*)$") }
    }
    foreach ($pattern in $patterns) {
        $m = [regex]::Match($Line, $pattern)
        if ($m.Success) {
            return [pscustomobject]@{ Id = $m.Groups[1].Value; Rest = $m.Groups[2].Value }
        }
    }
    $null
}

# Structured body drops trailing blank lines (section and item separators that
# still belong to the item block in Raw for byte-exact emit and removal).
# Internal blank lines between paragraphs are kept.
function Get-FmBacklogStructuredBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][AllowEmptyString()][string[]]$BodyLine = @())

    # An explicitly passed @() binds as $null, so normalise before reading it.
    if ($null -eq $BodyLine) { $BodyLine = @() }
    $end = $BodyLine.Count
    while ($end -gt 0 -and $BodyLine[$end - 1] -eq '') { $end-- }
    if ($end -eq 0) { return '' }
    ($BodyLine[0..($end - 1)] -join "`n")
}

function New-FmBacklogTask {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory task record and changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Rest,
        [Parameter(Mandatory)][string]$State,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$BodyLine = @()
    )

    if ($null -eq $BodyLine) { $BodyLine = @() }
    $tags = Get-FmBacklogTaskTag -Rest $Rest

    # Public-followup metadata is a single HTML comment that must be the first
    # body line. It is kept verbatim and never decoded for rendering; only the
    # delivery state is read, and only to decide whether the obligation is still
    # active.
    $metadata = ''
    $body = @($BodyLine)
    $markerIndexes = @()
    for ($i = 0; $i -lt $body.Count; $i++) {
        if ($body[$i].Contains($script:FmBacklogPublicFollowupMarker)) { $markerIndexes += $i }
    }
    if ($markerIndexes.Count -gt 0) {
        if ($markerIndexes.Count -ne 1 -or $markerIndexes[0] -ne 0) {
            throw "Task `"$Id`" has malformed or misplaced public-followup metadata"
        }
        if ($body[0] -notmatch '^<!-- tasks-axi:public-followup/v1:([A-Za-z0-9_-]+) -->$') {
            throw "Task `"$Id`" has unsupported public-followup metadata"
        }
        $metadata = $body[0]
        $body = if ($body.Count -gt 1) { @($body[1..($body.Count - 1)]) } else { @() }
    } elseif ($tags.Kind -eq $script:FmBacklogPublicFollowupKind) {
        throw "Task `"$Id`" is missing public-followup metadata"
    }

    [pscustomobject]@{
        Id                     = $Id
        Title                  = $tags.Title
        State                  = $State
        Kind                   = $tags.Kind
        Repo                   = $tags.Repo
        Body                   = (Get-FmBacklogStructuredBody -BodyLine $body)
        Deps                   = @($tags.Deps)
        Links                  = @($tags.Links)
        Created                = $tags.Created
        Closed                 = $tags.Closed
        Priority               = $tags.Priority
        Hold                   = $tags.Hold
        PublicFollowupMetadata = $metadata
    }
}

function ConvertFrom-FmBacklogEntry {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Line = @(),
        [Parameter(Mandatory)][AllowEmptyString()][string]$State
    )

    if ($null -eq $Line) { $Line = @() }
    $entries = [System.Collections.Generic.List[object]]::new()
    $rawRun = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($rawRun.Count -gt 0) {
            $entries.Add([pscustomobject]@{ Kind = 'raw'; Lines = @($rawRun); Task = $null; Raw = @(); Dirty = $false })
            $rawRun.Clear()
        }
    }

    for ($i = 0; $i -lt $Line.Count; $i++) {
        $bullet = $null
        if (-not [string]::IsNullOrEmpty($State)) {
            $bullet = Get-FmBacklogTaskBullet -Line ($Line[$i].TrimEnd("`r")) -State $State
        }
        if ($null -eq $bullet) { $rawRun.Add($Line[$i]); continue }

        & $flush
        $raw = [System.Collections.Generic.List[string]]::new()
        $raw.Add($Line[$i])
        $bodyLines = [System.Collections.Generic.List[string]]::new()
        # An item block is its header plus every following indented OR blank line,
        # up to the next item header or free-form column-0 content. Membership is
        # by position, not content: an indented line that looks like a markdown
        # heading is body, never a section boundary. A trailing blank before the
        # next item or section belongs to this block, so it moves with it.
        while ($i + 1 -lt $Line.Count) {
            $next = $Line[$i + 1].TrimEnd("`r")
            if ($next.Trim().Length -eq 0) {
                $i++; $raw.Add($Line[$i]); $bodyLines.Add(''); continue
            }
            if ($next.StartsWith('  ')) {
                $i++; $raw.Add($Line[$i]); $bodyLines.Add($next.Substring(2)); continue
            }
            break
        }
        $entries.Add([pscustomobject]@{
                Kind  = 'task'
                Lines = @()
                Task  = (New-FmBacklogTask -Id $bullet.Id -Rest $bullet.Rest -State $State -BodyLine @($bodyLines))
                Raw   = @($raw)
                Dirty = $false
            })
    }
    & $flush
    @($entries)
}

function ConvertFrom-FmBacklogMarkdown {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text -eq '') {
        return [pscustomobject]@{
            FinalNewline = $false
            Preamble     = [System.Collections.Generic.List[string]]::new()
            Sections     = [System.Collections.Generic.List[object]]::new()
        }
    }

    $finalNewline = $Text.EndsWith("`n")
    $body = if ($finalNewline) { $Text.Substring(0, $Text.Length - 1) } else { $Text }
    $lines = $body -split "`n"

    $preamble = [System.Collections.Generic.List[string]]::new()
    $sections = [System.Collections.Generic.List[object]]::new()
    $current = $null
    $buffer = [System.Collections.Generic.List[string]]::new()

    # The buffer is CLEARED, never reassigned: a scriptblock runs in a child
    # scope, so assigning to $buffer there would create a local copy and silently
    # keep appending to the old one.
    $close = {
        if ($null -ne $current) {
            $current.Entries = @(ConvertFrom-FmBacklogEntry -Line @($buffer) -State $current.State)
            $sections.Add($current)
        }
        $buffer.Clear()
    }

    foreach ($line in $lines) {
        if ($line.TrimEnd("`r") -match '^##\s+') {
            & $close
            $current = [pscustomobject]@{
                HeaderLine = $line
                State      = (Get-FmBacklogSectionState -HeaderLine $line)
                Entries    = @()
            }
            continue
        }
        if ($null -ne $current) { $buffer.Add($line) } else { $preamble.Add($line) }
    }
    & $close

    [pscustomobject]@{ FinalNewline = $finalNewline; Preamble = $preamble; Sections = $sections }
}

function ConvertTo-FmBacklogMarkdown {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Document)

    if ($Document.Preamble.Count -eq 0 -and $Document.Sections.Count -eq 0) { return '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Document.Preamble) { $lines.Add($line) }
    foreach ($section in $Document.Sections) {
        $lines.Add($section.HeaderLine)
        foreach ($entry in $section.Entries) {
            if ($entry.Kind -eq 'raw') {
                foreach ($line in $entry.Lines) { $lines.Add($line) }
                continue
            }
            # An untouched entry re-emits its ORIGINAL lines byte for byte; only a
            # mutated entry is re-rendered canonically.
            $source = if ($entry.Dirty) { Get-FmBacklogTaskLine -Task $entry.Task } else { $entry.Raw }
            foreach ($line in $source) { $lines.Add($line) }
        }
    }
    ($lines -join "`n") + $(if ($Document.FinalNewline) { "`n" } else { '' })
}

# --- document helpers ----------------------------------------------------------

function Get-FmBacklogDocumentTask {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param([Parameter(Mandatory)]$Document)

    $tasks = [System.Collections.Generic.List[object]]::new()
    foreach ($section in $Document.Sections) {
        foreach ($entry in $section.Entries) {
            if ($entry.Kind -eq 'task') { $tasks.Add($entry.Task) }
        }
    }
    @($tasks)
}

function Find-FmBacklogEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Id
    )

    foreach ($section in $Document.Sections) {
        for ($i = 0; $i -lt $section.Entries.Count; $i++) {
            $entry = $section.Entries[$i]
            if ($entry.Kind -eq 'task' -and $entry.Task.Id -eq $Id) {
                return [pscustomobject]@{ Section = $section; Index = $i; Entry = $entry }
            }
        }
    }
    $null
}

function Initialize-FmBacklogSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)

    if ($Document.Preamble.Count -eq 0 -and $Document.Sections.Count -eq 0) {
        $Document.Preamble = [System.Collections.Generic.List[string]]::new()
        $Document.Preamble.Add('# Backlog')
        $Document.Preamble.Add('')
        $Document.FinalNewline = $true
    }
    foreach ($state in $script:FmBacklogStateOrder) {
        $present = $false
        foreach ($section in $Document.Sections) { if ($section.State -eq $state) { $present = $true; break } }
        if ($present) { continue }
        $Document.Sections.Add([pscustomobject]@{
                HeaderLine = $script:FmBacklogSectionHeaders[$state]
                State      = $state
                Entries    = @()
            })
    }
}

function Get-FmBacklogSection {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$State
    )

    foreach ($section in $Document.Sections) { if ($section.State -eq $State) { return $section } }
    throw "missing backlog section: $State"
}

function Add-FmBacklogSectionEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)]$Entry,
        [switch]$AtTop
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Section.Entries) { $entries.Add($item) }
    if ($AtTop) {
        $entries.Insert(0, $Entry)
        $Section.Entries = @($entries)
        return
    }
    # Insert after the last content entry, before any trailing blank lines.
    $index = $entries.Count
    while ($index -gt 0) {
        $prev = $entries[$index - 1]
        $blank = ($prev.Kind -eq 'raw')
        if ($blank) {
            foreach ($line in $prev.Lines) { if ($line.Trim() -ne '') { $blank = $false; break } }
        }
        if (-not $blank) { break }
        $index--
    }
    $entries.Insert($index, $Entry)
    $Section.Entries = @($entries)
}

function Remove-FmBacklogSectionEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes an entry from the in-memory document; the file is written later by Save-FmBacklogDocument, which is where the decision belongs.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Section,
        [Parameter(Mandatory)][int]$Index
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Section.Entries) { $entries.Add($item) }
    $entries.RemoveAt($Index)
    $Section.Entries = @($entries)
}

# --- validation ----------------------------------------------------------------

function Assert-FmBacklogTitle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)

    if ($Title -match "[`r`n]") { throw 'Task title must be a single line' }
    $trimmed = $Title.Trim()
    if ($trimmed -eq '') { throw 'Task title must not be empty' }
    if ((Get-FmBacklogTaskTag -Rest $trimmed).Title -ne $trimmed) {
        throw 'Task title must not end with canonical task tags'
    }
    $trimmed
}

function Assert-FmBacklogTagValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Field
    )

    if ($Value -match "[()`r`n]") { throw "Task $Field must be a single line without parentheses" }
    $Value.Trim()
}

function Assert-FmBacklogDate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Field
    )

    if ($Value -notmatch "^$($script:FmBacklogDatePattern)$") { throw "Task $Field must be YYYY-MM-DD" }
    $Value
}

function Assert-FmBacklogHold {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        [AllowEmptyString()][string]$Kind = '',
        [AllowEmptyString()][string]$Until = ''
    )

    if ($Reason -match "[`r`n()]") { throw 'Task hold reason must be a single line without parentheses' }
    $trimmed = $Reason.Trim()
    if ($trimmed -eq '') { throw 'Task hold reason must not be empty' }
    if ($Kind -ne '' -and $script:FmBacklogHoldKinds -notcontains $Kind) {
        throw "Task hold kind must be one of $($script:FmBacklogHoldKinds -join ', ')"
    }
    if ($Until -ne '') { $null = Assert-FmBacklogDate -Value $Until -Field 'hold-until date' }
    [pscustomobject]@{ Reason = $trimmed; Kind = $Kind; Until = $Until }
}

function Assert-FmBacklogPriority {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$Priority)

    if ($Priority -lt 0 -or $Priority -gt 4) { throw 'Task priority must be an integer 0-4' }
    $Priority
}

function Assert-FmBacklogDependency {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OwnerId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$Reason = ''
    )

    if ($script:FmBacklogDepTypes -notcontains $Type) {
        throw "Task dependency type must be one of $($script:FmBacklogDepTypes -join ', ')"
    }
    $null = Assert-FmBacklogId -Id $Id
    if ($Id -eq $OwnerId) { throw 'A task cannot block itself' }
    $trimmed = $Reason
    if ($trimmed -match "[`r`n]") { throw 'Task dependency reason must be a single line' }
    $trimmed = $trimmed.Trim()
    if ($trimmed -match '(?:^|\s)(?:blocked-by|parent|discovered-from):\s') {
        throw 'Task dependency reason must not contain dependency markers'
    }
    [pscustomobject]@{ Type = $Type; Id = $Id; Reason = $trimmed }
}

# A public-followup obligation has its own command family and its own delivery
# state machine. Every generic mutation here refuses one rather than risking a
# public promise, exactly as tasks-axi does.
function Assert-FmBacklogNotPublicFollowup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Operation
    )

    if ([string]::IsNullOrEmpty($Task.PublicFollowupMetadata) -and $Task.Kind -ne $script:FmBacklogPublicFollowupKind) {
        return
    }
    throw "refusing to $Operation `"$($Task.Id)`": public-followup obligations are owned by the public-followup command family"
}

# Terminal means posted or waived. A payload that cannot be decoded is treated as
# ACTIVE - fail closed, so an unreadable public obligation is never archived out
# of the active backlog.
function Test-FmBacklogPublicFollowupTerminal {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Task)

    if ([string]::IsNullOrEmpty($Task.PublicFollowupMetadata)) { return $true }
    if ($Task.PublicFollowupMetadata -notmatch '^<!-- tasks-axi:public-followup/v1:([A-Za-z0-9_-]+) -->$') { return $false }
    $encoded = $Matches[1]
    $padded = $encoded.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
        1 { return $false }
    }
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded)) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $false
    }
    $state = [string](Get-FmJsonValue -InputObject $json -Path 'delivery.state')
    ($state -eq 'posted' -or $state -eq 'waived')
}

# --- file I/O and the advisory lock --------------------------------------------
#
# The lock protocol is tasks-axi's, because both tools write the same file: an
# exclusively-created `<path>.lock` holding a unique token, released only when
# the file still holds THAT token, with a 2.5s acquisition budget. Corruption
# safety does not depend on it - every write is a temp file replaced over the
# destination - so this only reduces lost updates in the low-contention
# single-supervisor model, exactly as documented on the other side.
#
# A stale lock is NOT broken automatically here either: the refusal names the
# lock path so an operator can decide. Removing another process's lock on a guess
# is how two writers end up interleaved.

$script:FmBacklogLockTimeoutMs = 2500
$script:FmBacklogLockRetryMs = 25
$script:FmBacklogLockStaleMs = 30000

function Enter-FmBacklogLock {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    $lockPath = "$Path.lock"
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir)) { New-FmDirectory -Path $dir }

    $token = "$PID`:$([guid]::NewGuid().ToString('N')):$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())`n"
    $deadline = [datetime]::UtcNow.AddMilliseconds($script:FmBacklogLockTimeoutMs)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($token)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
            return [pscustomobject]@{ Path = $lockPath; Token = $token }
        } catch [System.IO.IOException] {
            if ([datetime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds $script:FmBacklogLockRetryMs
        }
    }

    $age = $null
    try { $age = ([datetime]::UtcNow - (Get-Item -LiteralPath $lockPath -Force).LastWriteTimeUtc).TotalMilliseconds }
    catch { Write-Debug "backlog: could not age the lock at $lockPath; reporting it as contended rather than stale: $_" }
    if ($null -ne $age -and $age -gt $script:FmBacklogLockStaleMs) {
        throw "backlog lock looks stale: $lockPath (if no tasks-axi process is running, remove it and retry)"
    }
    throw "backlog is locked by another process: $lockPath"
}

function Exit-FmBacklogLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lock)

    $observed = ''
    try { $observed = [System.IO.File]::ReadAllText($Lock.Path) } catch { return }
    if ($observed -ne $Lock.Token) { return }
    Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue
}

function Get-FmBacklogSource {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    [System.IO.File]::ReadAllText($Path)
}

# Write the rendered document over the backlog, refusing when the file changed
# under us since it was read. The write is a temp file replaced over the
# destination, so a reader sees either the whole old file or the whole new one.
function Save-FmBacklogDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$ExpectedSource
    )

    $current = Get-FmBacklogSource -Path $Path
    if ($current -ne $ExpectedSource) { throw 'Backlog changed on disk; retry the command' }

    # -NoTrailingNewline because the rendered document already carries the
    # file's own final-newline state: adding one would break the byte-exact round
    # trip for a backlog that legitimately ends without it.
    Write-FmStateFile -Path $Path -Content (ConvertTo-FmBacklogMarkdown -Document $Document) -NoTrailingNewline
}

# Run one mutation under the lock: load, apply, persist. The action receives the
# parsed document and returns whatever the caller should see; throwing from it
# refuses the whole mutation, and nothing is written.
#
# The action is a PLAIN scriptblock, deliberately not a closure: PowerShell
# resolves an unbound variable through the runtime scope chain, so an action
# reads its caller's parameters directly, and it resolves functions through the
# session state it was written in. A GetNewClosure() copy binds a fresh scope
# whose function lookup does not survive being called from another host, which is
# exactly the kind of works-here-fails-there difference this port must not have.
function Invoke-FmBacklogMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $lock = Enter-FmBacklogLock -Path $Path
    try {
        $source = Get-FmBacklogSource -Path $Path
        $document = ConvertFrom-FmBacklogMarkdown -Text $(if ($null -eq $source) { '' } else { $source })
        $result = & $Action $document
        Save-FmBacklogDocument -Path $Path -Document $document -ExpectedSource $source
        $result
    } finally {
        Exit-FmBacklogLock -Lock $lock
    }
}

# --- dependency guards ---------------------------------------------------------

function Assert-FmBacklogDependencyExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [AllowEmptyCollection()][object[]]$Dependency = @()
    )

    if ($null -eq $Dependency) { return }
    foreach ($dep in $Dependency) {
        if (Find-FmBacklogEntry -Document $Document -Id $dep.Id) { continue }
        $label = if ($dep.Type -eq 'blocked-by') { 'blocker' } else { 'dependency' }
        throw "$label `"$($dep.Id)`" not found"
    }
}

function Get-FmBacklogActiveDependent {
    [CmdletBinding()]
    [OutputType([string[]], [array])]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Id
    )

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($task in (Get-FmBacklogDocumentTask -Document $Document)) {
        if ($task.State -eq 'done') { continue }
        foreach ($dep in $task.Deps) {
            if ($dep.Type -eq 'blocked-by' -and $dep.Id -eq $Id) { $out.Add($task.Id); break }
        }
    }
    @($out)
}

# --- derived projections -------------------------------------------------------
#
# blocked / ready / held are computed from the full task list, the dependency
# graph, and the structured hold tags - not stored. Every backend gets them for
# free, and a hand-edited file yields the same answers as a tool-edited one.

# A task is blocked iff it is not done and has a blocked-by edge pointing at a
# task that EXISTS and is not done. A legacy hand-edited dangling edge is treated
# as resolved: firstmate drops the edge when the blocker lands, so a missing
# blocker almost always means it is done.
function Get-FmBacklogBlockedId {
    [CmdletBinding()]
    [OutputType([string[]], [array])]
    param([AllowEmptyCollection()][object[]]$Task = @())

    if ($null -eq $Task) { $Task = @() }
    # PowerShell variable names are case-insensitive, so the loop variable must
    # NOT be $task while the parameter is $Task: `foreach ($task in $Task)`
    # rebinds the very collection it is iterating.
    $byId = @{}
    foreach ($item in $Task) { $byId[$item.Id] = $item }
    $blocked = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Task) {
        if ($item.State -eq 'done') { continue }
        foreach ($dep in $item.Deps) {
            if ($dep.Type -ne 'blocked-by') { continue }
            if (-not $byId.ContainsKey($dep.Id)) { continue }
            if ($byId[$dep.Id].State -eq 'done') { continue }
            $blocked.Add($item.Id)
            break
        }
    }
    @($blocked)
}

# A structured hold is active while the task is not done and either carries no
# until date or that date is still in the future. `hold-until` is inactive ON and
# after the named date, matching tasks-axi's `until > today`.
function Test-FmBacklogHoldActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Task,
        [string]$Today = ''
    )

    if ($null -eq $Task.Hold) { return $false }
    if ($Task.State -eq 'done') { return $false }
    if ([string]::IsNullOrEmpty($Task.Hold.Until)) { return $true }
    if ([string]::IsNullOrEmpty($Today)) { $Today = Get-FmBacklogToday }
    ([string]::CompareOrdinal($Task.Hold.Until, $Today) -gt 0)
}

function Get-FmBacklogHeldTask {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [AllowEmptyCollection()][object[]]$Task = @(),
        [string]$Today = ''
    )

    if ($null -eq $Task) { return @() }
    @($Task | Where-Object { Test-FmBacklogHoldActive -Task $_ -Today $Today })
}

# Unblocked, unheld queued work. Public-followup obligations are never
# dispatchable and are excluded here by design.
function Get-FmBacklogReadyTask {
    [CmdletBinding()]
    [OutputType([object[]], [array])]
    param(
        [AllowEmptyCollection()][object[]]$Task = @(),
        [switch]$IncludeHeld,
        [string]$Today = ''
    )

    if ($null -eq $Task) { $Task = @() }
    $blocked = @(Get-FmBacklogBlockedId -Task $Task)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Task) {
        if ($item.State -ne 'queued') { continue }
        if ($item.Kind -eq $script:FmBacklogPublicFollowupKind) { continue }
        if ($blocked -contains $item.Id) { continue }
        if (-not $IncludeHeld -and (Test-FmBacklogHoldActive -Task $item -Today $Today)) { continue }
        $out.Add($item)
    }
    @($out)
}

# The unresolved blocked-by edges for one task.
function Get-FmBacklogActiveBlocker {
    [CmdletBinding()]
    [OutputType([string[]], [array])]
    param(
        [Parameter(Mandatory)]$Task,
        [AllowEmptyCollection()][object[]]$AllTask = @()
    )

    $byId = @{}
    if ($null -ne $AllTask) { foreach ($task in $AllTask) { $byId[$task.Id] = $task } }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($dep in $Task.Deps) {
        if ($dep.Type -ne 'blocked-by') { continue }
        if (-not $byId.ContainsKey($dep.Id)) { continue }
        if ($byId[$dep.Id].State -eq 'done') { continue }
        $out.Add($dep.Id)
    }
    @($out)
}

# --- transitions and retention -------------------------------------------------

function Invoke-FmBacklogTransition {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Id, To, Pr, Report, Note and Date are all read inside the $action closure, which the analyzer cannot see through; verified end to end that each one reaches the file.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('queued', 'in_flight', 'done')][string]$To,
        [AllowEmptyString()][string]$Pr = '',
        [AllowEmptyString()][string]$Report = '',
        [AllowEmptyString()][string]$Note = '',
        [AllowEmptyString()][string]$Date = ''
    )

    $action = {
        param($document)

        Initialize-FmBacklogSection -Document $document
        $found = Find-FmBacklogEntry -Document $document -Id $Id
        if ($null -eq $found) { throw "Task `"$Id`" not found" }
        $task = $found.Entry.Task
        Assert-FmBacklogNotPublicFollowup -Task $task -Operation 'transition'

        $stamp = if ([string]::IsNullOrEmpty($Date)) { Get-FmBacklogToday } else { Assert-FmBacklogDate -Value $Date -Field 'transition date' }

        # Record links and notes BEFORE stamping, so the closure verb sees them.
        foreach ($link in @(
                @{ Kind = 'pr'; Url = $Pr },
                @{ Kind = 'report'; Url = $Report })) {
            if ([string]::IsNullOrEmpty($link.Url)) { continue }
            $task.Title = Add-FmBacklogTitleLink -Title $task.Title -Kind $link.Kind -Url $link.Url
        }
        if (-not [string]::IsNullOrEmpty($Note)) {
            $task.Body = if ([string]::IsNullOrEmpty($task.Body)) { $Note } else { "$($task.Body)`n$Note" }
        }
        $task.Links = @(Get-FmBacklogLink -Text $task.Title)
        $task.State = $To
        if ($To -eq 'done') {
            $task.Closed = $stamp
        } else {
            if ($To -eq 'in_flight' -and [string]::IsNullOrEmpty($task.Created)) { $task.Created = $stamp }
            $task.Closed = ''
        }

        Remove-FmBacklogSectionEntry -Section $found.Section -Index $found.Index
        $moved = [pscustomobject]@{ Kind = 'task'; Lines = @(); Task = $task; Raw = @(); Dirty = $true }
        # Done and started work surfaces at the top; reopened work appends to queued.
        Add-FmBacklogSectionEntry -Section (Get-FmBacklogSection -Document $document -State $To) -Entry $moved -AtTop:($To -ne 'queued')
        $task
    }

    Invoke-FmBacklogMutation -Path $Path -Action $action
}

# The one shape every backlog mutation reports: which verb ran, on which id,
# whether it was already in that state (the idempotent no-op), the resulting
# task, and how many Done rows retention archived.
function New-FmBacklogResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory result record and changes nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowNull()]$Task,
        [switch]$Already,
        [int]$Pruned = 0
    )

    [pscustomobject]@{
        Action  = $Action
        Id      = $Id
        Already = [bool]$Already
        Task    = $Task
        Pruned  = $Pruned
    }
}

function Add-FmBacklogTitleLink {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('pr', 'report', 'doc')][string]$Kind,
        [Parameter(Mandatory)][string]$Url
    )

    if ($Url -match "[`r`n]") { throw 'Task link must be a single line' }
    $trimmed = $Url.Trim()
    if ($trimmed -eq '') { throw 'Task link must not be empty' }

    $derived = Get-FmBacklogLink -Text $trimmed
    $matched = $false
    foreach ($candidate in $derived) {
        if ($candidate.Kind -eq $Kind -and $candidate.Url -eq $trimmed) { $matched = $true; break }
    }
    if (-not $matched) {
        $expected = switch ($Kind) {
            'pr' { 'an http(s) pull request URL ending in /pull/<number>' }
            'report' { 'a data/<id>/report.md path' }
            default { 'an http(s) URL' }
        }
        throw "Task $Kind link must be $expected"
    }
    foreach ($existing in (Get-FmBacklogLink -Text $Title)) {
        if ($existing.Url -eq $trimmed) { return $Title }
    }
    Assert-FmBacklogTitle -Title "$Title $trimmed"
}

function Get-FmBacklogArchiveRestorePoint {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Path = $Path; Existed = $false; Length = [long]0 }
    }
    [pscustomobject]@{ Path = $Path; Existed = $true; Length = (Get-Item -LiteralPath $Path -Force).Length }
}

function Restore-FmBacklogArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Point)

    if (-not $Point.Existed) {
        Remove-Item -LiteralPath $Point.Path -Force -ErrorAction SilentlyContinue
        return
    }
    try {
        $stream = [System.IO.File]::Open($Point.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
        try { $stream.SetLength($Point.Length) } finally { $stream.Dispose() }
    } catch {
        # This rollback is what makes the caller's invariant true: the archive is
        # appended BEFORE the backlog is rewritten, so a failed rewrite must undo
        # the append or the same rows exist in two places. Swallowing a failed
        # undo left that broken silently, while the caller rethrew the original
        # save error and nobody learned the archive had drifted.
        #
        # Warn rather than throw: the caller is already unwinding a failed save
        # and rethrows it, and that original error is the actionable one. Losing
        # it to a secondary rollback failure would be a worse trade.
        Write-Warning ("backlog: could not roll the archive back to its pre-prune size " +
            "($($Point.Path), $($Point.Length) bytes): $_. Those rows are now in BOTH the " +
            'archive and the backlog - reconcile before pruning again.')
    }
}

function Add-FmBacklogArchiveBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Line = @(),
        [Parameter(Mandatory)][string]$Stamp
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrEmpty($dir)) { New-FmDirectory -Path $dir }
    if ($null -eq $Line) { $Line = @() }
    $block = "`n## Archived $Stamp`n" + (($Line -join "`n") + "`n")
    [System.IO.File]::AppendAllText($Path, $block, [System.Text.UTF8Encoding]::new($false))
}
