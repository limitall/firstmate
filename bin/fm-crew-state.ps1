# fm-crew-state.ps1 - deterministic read of a crew's CURRENT state.
#
# Twin: bin/fm-crew-state.sh
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so the last line of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. EXCEPT: while
#      the active step is ci, `axi status` alone cannot tell "still waiting on
#      checks" from "checks green, waiting on merge" (see Get-NmCiChecksState) -
#      a ci-step log-tail check overrides working -> done once checks read
#      green, so a green PR is never silently read as still-validating.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
#
# ---------------------------------------------------------------------------
# WHAT THE CONVERSION HAD TO REPRODUCE EXACTLY, AND WHY
#
#   THE STATE VOCABULARY IS AN INTERFACE. `state:` / `source:` / the ` · `
#   separator and every word after them are parsed by fm-watch.sh and by the
#   session-start digest, so the emitted line is built from literals here and
#   never from a PowerShell formatter. The separator is spelled with an explicit
#   [char] so the file's own encoding can never silently degrade U+00B7 - the
#   same discipline bin/fm-composer-lib.psm1 uses for its border glyphs.
#
#   THE TEXT PARSING IS BYTE SEMANTICS, NOT "CLOSE ENOUGH". The bash twin reads
#   TOON output with sed/grep/`${var%%,*}`, so the twin uses ordinal IndexOf
#   splits with the same first-separator rule (a field with no separator yields
#   the WHOLE string, which is what `${x%%,*}` and `${x#*,}` both do), and
#   whitespace classes are the POSIX set - space, tab, VT, FF, CR - rather than
#   .NET's `\s`, which also matches Unicode separators a TOON table can legally
#   contain inside a value.
#
#   THE RUN-STEP PATH STAYS AUTHORITATIVE OVER PANE LIVENESS. The endpoint is
#   probed only in the no-run fallback. A finished crew whose pane has closed
#   must still report its run-step state, so no liveness check may be hoisted.
#
# ---------------------------------------------------------------------------
# TWO DOCUMENTED DIVERGENCES
#
#   BOUNDING THE no-mistakes CALL. The bash twin picks `timeout`, `gtimeout` or
#   a perl fork-and-alarm, and does nothing at all when none exists. PowerShell
#   bounds the child in-process (Invoke-FmTool -TimeoutSeconds), so the twin is
#   always bounded - including on a host where the bash twin would have run
#   unbounded. On expiry the killed child's PARTIAL stdout is discarded here,
#   where `timeout` would have left whatever bytes it had already written; a
#   truncated TOON table parses to no fields either way, so both sides fall
#   through to the pane/log path.
#
#   SIGNALS. HUP/TERM exit codes cannot be reproduced on Windows; this script
#   never produces them anyway (it exits 0 or 2), so nothing here fakes one.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-tmux-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1') -Force

$fmArgv = @($args)

# ' · ' - see the encoding note above.
$script:Sep = ' ' + [string][char]0x00B7 + ' '

# The POSIX [[:space:]] set, for Trim and for the hand-built regexes below.
$script:Ws = [char[]]@(' ', "`t", "`n", [char]0x0B, [char]0x0C, "`r")
$script:WsRe = '[ \t\n\x0B\x0C\r]'

# Captured `no-mistakes axi status` output, and its lines. Set once by the
# lookup block; every Get-Nm* reader below reads these two and nothing else,
# exactly as the bash twin's helpers all read $RUN_OUT.
$script:RunOut = ''
$script:RunLines = @('')

# Resolved once: the bounded no-mistakes invocation needs the worktree and the
# executable, and neither changes during a read.
$script:WorktreeNative = ''
$script:NmCommand = ''
$script:NmTimeout = 10

# --- byte-semantics string helpers -------------------------------------------

# `${s%%<sep>*}` - everything before the FIRST separator, or the whole string
# when there is none. The no-separator case is load-bearing: a malformed TOON
# row must yield the row rather than an empty field.
function Get-FmBeforeFirst {
    param([AllowEmptyString()][string]$Text, [char]$Separator)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $idx = $Text.IndexOf($Separator)
    if ($idx -lt 0) { return $Text }
    return $Text.Substring(0, $idx)
}

# `${s#*<sep>}` - everything after the FIRST separator, or the whole string.
function Get-FmAfterFirst {
    param([AllowEmptyString()][string]$Text, [char]$Separator)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $idx = $Text.IndexOf($Separator)
    if ($idx -lt 0) { return $Text }
    return $Text.Substring($idx + 1)
}

# The bash `trim` helper: POSIX whitespace only, both ends.
function Get-FmTrimmed {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim($script:Ws)
}

# The bash `strip_quotes` helper: trim, drop a surrounding pair of double
# quotes, trim again. A lone quote is not a pair and is left alone.
function Get-FmUnquoted {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    $s = Get-FmTrimmed $Text
    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) {
        $s = $s.Substring(1, $s.Length - 2)
    }
    return (Get-FmTrimmed $s)
}

# --- bounded no-mistakes calls ------------------------------------------------

function Invoke-FmNmRun {
    param([string[]]$NmArgs)
    if ([string]::IsNullOrEmpty($script:NmCommand)) { return '' }
    $result = Invoke-FmTool -FilePath $script:NmCommand -Arguments $NmArgs `
        -WorkingDirectory $script:WorktreeNative -TimeoutSeconds $script:NmTimeout
    # `$( ... )` strips every trailing newline; downstream parsing counts on it.
    return $result.StdOut.TrimEnd("`n")
}

function Set-FmRunOut {
    param([AllowEmptyString()][string]$Text)
    $script:RunOut = $Text
    if ([string]::IsNullOrEmpty($Text)) { $script:RunLines = @('') }
    else { $script:RunLines = @($Text.Split("`n")) }
}

# --- TOON readers over $script:RunOut ----------------------------------------

# Scalar value of a TOON key: the first `key: value` line, value to end of line.
function Get-NmField {
    param([string]$Key)
    $re = '^' + $script:WsRe + '*' + [regex]::Escape($Key) + ':' + $script:WsRe + '*(.*)$'
    foreach ($line in $script:RunLines) {
        $m = [regex]::Match($line, $re)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# Finding count from a findings[N]{...} table header; '' when none.
function Get-NmFindingsCount {
    $m = [regex]::Match($script:RunOut, 'findings\[([0-9]+)\]')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# The first steps[] row parked at a gate, as "<step>|<status>|<findings>".
# Returns '' when no row is parked.
function Get-NmGateStepRow {
    $re = '^' + $script:WsRe + '*[^,]+,' + $script:WsRe + '*"?(awaiting_approval|fix_review)"?' + $script:WsRe + '*,'
    $row = ''
    foreach ($line in $script:RunLines) {
        if ([regex]::IsMatch($line, $re)) { $row = $line; break }
    }
    if ([string]::IsNullOrEmpty($row)) { return '' }
    $row = Get-FmTrimmed $row
    $step = Get-FmTrimmed (Get-FmBeforeFirst $row ',')
    $rest = Get-FmAfterFirst $row ','
    $status = Get-FmUnquoted (Get-FmTrimmed (Get-FmBeforeFirst $rest ','))
    $rest = Get-FmAfterFirst $rest ','
    $findings = Get-FmTrimmed (Get-FmBeforeFirst $rest ',')
    return "$step|$status|$findings"
}

function Get-NmGateStatus {
    $re = '^' + $script:WsRe + '*(status|state):' + $script:WsRe + '*"?(awaiting_approval|fix_review)"?' + $script:WsRe + '*$'
    foreach ($line in $script:RunLines) {
        if ([regex]::IsMatch($line, $re)) {
            return (Get-FmUnquoted (Get-FmTrimmed (Get-FmAfterFirst $line ':')))
        }
    }
    $row = Get-NmGateStepRow
    if ([string]::IsNullOrEmpty($row)) { return '' }
    $rest = Get-FmAfterFirst $row '|'
    return (Get-FmBeforeFirst $rest '|')
}

function Test-NmHasGate {
    $re = '^' + $script:WsRe + '*gate:' + $script:WsRe + '*'
    foreach ($line in $script:RunLines) {
        if ([regex]::IsMatch($line, $re)) { return $true }
    }
    return $false
}

# The gate's own name: the scalar `gate:` value, else the first `step:` inside
# the `gate:` block. The block is delimited exactly as the bash twin's sed
# address range is - from a bare `gate:` line to the next unindented `key:` line
# - including the rule that the OPENING line can never also close the range.
function Get-NmGateLineName {
    $gate = Get-FmUnquoted (Get-NmField 'gate')
    if (-not [string]::IsNullOrEmpty($gate)) { return $gate }

    $startRe = '^' + $script:WsRe + '*gate:' + $script:WsRe + '*$'
    $endRe = '^[^ \t\n\x0B\x0C\r][^:]*:'
    $stepRe = '^' + $script:WsRe + '*step:' + $script:WsRe + '*(.*)$'
    $inRange = $false
    foreach ($line in $script:RunLines) {
        $justStarted = $false
        if (-not $inRange) {
            if (-not [regex]::IsMatch($line, $startRe)) { continue }
            $inRange = $true
            $justStarted = $true
        }
        $m = [regex]::Match($line, $stepRe)
        if ($m.Success) { return (Get-FmUnquoted $m.Groups[1].Value) }
        if (-not $justStarted -and [regex]::IsMatch($line, $endRe)) { $inRange = $false }
    }
    return ''
}

function Get-NmGateName {
    $gate = Get-NmGateLineName
    if (-not [string]::IsNullOrEmpty($gate)) { return $gate }
    $row = Get-NmGateStepRow
    if ([string]::IsNullOrEmpty($row)) { return '' }
    return (Get-FmBeforeFirst $row '|')
}

function Get-NmGateFindingsCount {
    $f = Get-NmFindingsCount
    if (-not [string]::IsNullOrEmpty($f)) { return $f }
    $row = Get-NmGateStepRow
    if ([string]::IsNullOrEmpty($row)) { return '' }
    $rest = Get-FmAfterFirst $row '|'
    $rest = Get-FmAfterFirst $rest '|'
    $rest = Get-FmBeforeFirst $rest '|'
    if ([string]::IsNullOrEmpty($rest)) { return '' }
    if (-not [regex]::IsMatch($rest, '^[0-9]+$')) { return '' }
    return $rest
}

function Get-NmCiStepStatus {
    $re = '^' + $script:WsRe + '*ci,' + $script:WsRe + '*"?(running|fixing)"?' + $script:WsRe + '*,'
    foreach ($line in $script:RunLines) {
        if ([regex]::IsMatch($line, $re)) {
            $row = Get-FmTrimmed $line
            $rest = Get-FmAfterFirst $row ','
            return (Get-FmUnquoted (Get-FmTrimmed (Get-FmBeforeFirst $rest ',')))
        }
    }
    return ''
}

# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or failed/cancelled if closed). `axi status`'s steps[] table
# never distinguishes "still waiting on checks" from "checks green, waiting on
# merge": both read as plain `ci,running,...`. The only place that transition is
# recorded is the ci step's own log text, e.g. "all CI checks passed - still
# monitoring until merged or closed". Reads the ci step's log tail via
# `axi logs` and scans it for the MOST RECENT recognized marker (the log is
# append-only/chronological, so the last match is current): green with nothing
# red after it means CI is green right now, still only waiting on merge/close.
function Get-NmCiChecksState {
    $runId = Get-FmUnquoted (Get-NmField 'id')
    if ([string]::IsNullOrEmpty($runId)) { return 'unknown' }
    $logTail = Invoke-FmNmRun @('axi', 'logs', '--step', 'ci', '--run', $runId)
    if ([string]::IsNullOrEmpty($logTail)) { return 'unknown' }
    $markerRe = 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout'
    $marker = ''
    foreach ($line in @($logTail.Split("`n"))) {
        if ([regex]::IsMatch($line, $markerRe)) { $marker = $line }
    }
    if ([string]::IsNullOrEmpty($marker)) { return 'unknown' }
    if ($marker.Contains('checks passed') -or
        $marker.Contains('no CI checks reported - still monitoring')) { return 'green' }
    if ($marker.Contains('no CI checks reported yet') -or $marker.Contains('checks failed') -or
        $marker.Contains('issues detected') -or $marker.Contains('CI checks running') -or
        [regex]::IsMatch($marker, 'base branch advanced.*re-arming CI monitor timeout')) { return 'not-ready' }
    return 'unknown'
}

# --- git identity -------------------------------------------------------------

function Invoke-FmGit {
    param([string[]]$GitArgs)
    return (Invoke-FmTool -FilePath 'git' -Arguments (@('-C', $script:WorktreeNative) + $GitArgs))
}

# 0 if the run head and this worktree name the same code identity. Rules:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip)
#   - run head a strict ancestor of worktree HEAD, or diverged: no match
function Test-FmRunHeadMatchesWorktree {
    param([AllowEmptyString()][string]$RunHead)
    if ([string]::IsNullOrEmpty($RunHead)) { return $false }
    $local = Invoke-FmGit @('rev-parse', 'HEAD')
    if (-not $local.Ok) { return $false }
    $localFull = $local.StdOut.TrimEnd("`n")
    $run = Invoke-FmGit @('rev-parse', '--verify', "$RunHead^{commit}")
    if (-not $run.Ok) { return $false }
    $runFull = $run.StdOut.TrimEnd("`n")
    if ($runFull -ceq $localFull) { return $true }
    return (Invoke-FmGit @('merge-base', '--is-ancestor', $localFull, $runFull)).Ok
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". Same rules.
function Test-FmCoarseHeadMatchesWorktree {
    param([AllowEmptyString()][string]$ShortSha)
    return (Test-FmRunHeadMatchesWorktree -RunHead $ShortSha)
}

# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one exists,
# else falls back to some other branch's run purely as informational display, so
# a crew whose branch genuinely has no run yet sees another branch's answer.
#
# The real run-listing command is the top-level `no-mistakes runs` (the `axi`
# surface exposes only abort/logs/respond/run/status, so the TOON runs table the
# original fallback expected never existed). It is plain, human-oriented text -
# no run id, newest-first, columns "<status> <branch> <short-sha> <date>
# [<pr-url>]" separated by runs of spaces - but branch + coarse status is
# exactly what this predicate needs. Echoes the first (most recent) matching
# row's status word, or '' when the branch has no run within the row limit.
function Get-NmRunsStatusForBranch {
    param([string]$Branch, [string]$Limit)
    $out = Invoke-FmNmRun @('runs', '--limit', $Limit)
    if ([string]::IsNullOrEmpty($out)) { return '' }
    foreach ($raw in @($out.Split("`n"))) {
        $row = Get-FmTrimmed $raw
        if ([string]::IsNullOrEmpty($row)) { continue }
        $st = Get-FmBeforeFirst $row ' '
        $rest = Get-FmTrimmed (Get-FmAfterFirst $row ' ')
        $br = Get-FmBeforeFirst $rest ' '
        $rest = Get-FmTrimmed (Get-FmAfterFirst $rest ' ')
        $sha = Get-FmBeforeFirst $rest ' '
        if ($br -cne $Branch) { continue }
        # Same code-identity rule as axi status: skip a same-branch row whose
        # short-sha does not match this worktree (rewritten or advanced tip).
        if (-not (Test-FmCoarseHeadMatchesWorktree -ShortSha $sha)) { continue }
        return $st
    }
    return ''
}

# --- the read -----------------------------------------------------------------

Invoke-FmMain -UnexpectedCode 70 {
    $id = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    if ([string]::IsNullOrEmpty($id)) {
        Write-FmErr 'usage: fm-crew-state.sh <id>'
        Exit-FmScript 2
    }

    # Paths keep the caller's spelling; see bin/fm-peek.ps1's header for why.
    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
    }
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }
    $state = Get-FmEnv 'FM_STATE_OVERRIDE' "$fmHome/state"

    $meta = "$state/$id.meta"
    $log = "$state/$id.status"

    $nmTimeout = Get-FmEnv 'FM_CREW_STATE_NM_TIMEOUT' '10'
    if ([string]::IsNullOrEmpty($nmTimeout) -or -not [regex]::IsMatch($nmTimeout, '^[0-9]+$')) {
        $nmTimeout = '10'
    }
    $script:NmTimeout = [int]$nmTimeout
    # How many of the most recent `no-mistakes runs` rows the cross-branch
    # fallback scans. Generous enough to still find a branch's own run on a busy
    # multi-crew fleet without listing the entire history every call.
    $runsLimit = Get-FmEnv 'FM_CREW_STATE_RUNS_LIMIT' '200'
    if ([string]::IsNullOrEmpty($runsLimit) -or -not [regex]::IsMatch($runsLimit, '^[0-9]+$')) {
        $runsLimit = '200'
    }

    # Emit the one canonical line and exit 0. Detail is optional.
    function Send-CrewState {
        param(
            [Parameter(Position = 0)][string]$CrewState,
            [Parameter(Position = 1)][string]$Source,
            [Parameter(Position = 2)][AllowEmptyString()][string]$Detail = ''
        )
        $line = "state: $CrewState$($script:Sep)source: $Source"
        if (-not [string]::IsNullOrEmpty($Detail)) { $line = "$line$($script:Sep)$Detail" }
        Write-FmOut $line
        Exit-FmScript 0
    }

    # --- meta resolution ------------------------------------------------------

    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        Send-CrewState -CrewState unknown -Source none -Detail "no metadata for $id"
    }

    $wt = Get-FmMetaValue $meta 'worktree'
    $kind = Get-FmMetaValue $meta 'kind'
    $harness = Get-FmMetaValue $meta 'harness'
    if ([string]::IsNullOrEmpty($kind)) { $kind = 'ship' }

    # A torn-down (or never-created) worktree has no current state to read.
    $script:WorktreeNative = ConvertTo-FmNativePath $wt
    if ([string]::IsNullOrEmpty($wt) -or
        -not [System.IO.Directory]::Exists($script:WorktreeNative)) {
        Send-CrewState -CrewState unknown -Source none -Detail 'worktree gone (torn down?)'
    }

    # --- status log -----------------------------------------------------------

    $logLine = Get-FmLastStatusLine -Path $log
    $logVerb = Get-FmStatusLineVerb -Line $logLine

    # Map a status-log verb onto a canonical state for the fallback path.
    # `paused` is the deliberate-external-wait verb (fm-classify-lib's
    # FM_CLASSIFY_PAUSED_VERB): a crew with no active run and an idle pane that
    # declared a known external wait reports `paused` distinctly, so a supervisor
    # reading this sees a declared pause and its reason rather than a
    # wedge-suspect idle.
    function Get-LogState {
        param([AllowEmptyString()][string]$Line)
        if (Test-FmStatusPaused -Line $Line) { return 'paused' }
        switch -CaseSensitive (Get-FmStatusLineVerb -Line $Line) {
            'working' { return 'working' }
            'needs-decision' { return 'parked' }
            'blocked' { return 'blocked' }
            'done' { return 'done' }
            'failed' { return 'failed' }
            default { return 'unknown' }
        }
    }

    # The endpoint is consulted ONLY in the no-run fallback below. The run-step
    # path stays authoritative regardless of pane liveness - judge by the
    # run-step, not the shell - so a finished crew whose endpoint has closed
    # still reports its run-step state (e.g. done) instead of being masked as
    # unknown. Backend-aware (Get-FmBackendOfMeta defaults an absent backend= to
    # tmux, the P1 contract): a herdr task is read through the backend capture
    # instead of a bare tmux probe.
    $taskBackend = Get-FmBackendOfMeta $meta
    $backendTarget = Get-FmBackendTargetOfMeta $meta
    $expectedLabel = "fm-$id"

    function Test-PaneReadable {
        param([string]$Target)
        if ($taskBackend -ceq 'tmux') {
            return [bool](Invoke-FmTmuxCommand @('display-message', '-p', '-t', $Target, '#{pane_id}')).Ok
        }
        $capture = Get-FmBackendCapture -Backend $taskBackend -Target $Target -Lines '1' `
            -ExpectedLabel $expectedLabel
        return ($null -ne $capture)
    }

    # The crew's semantic busy state from the one contract owner
    # (bin/fm-busy-lib.psm1), as "<busy|idle|unknown> <source>". A converted
    # adapter answers from its own lifecycle record; Grok answers from its
    # isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
    # when no record exists, but its native `idle` is NOT, because agent.get
    # reports generation state (idle while a crew blocks on its own long-running
    # foreground tool call) rather than turn state.
    function Get-CrewBusyVerdict {
        param([string]$Target)
        $tail40 = ''
        if ($harness -clike 'grok*') {
            $captured = Get-FmBackendCapture -Backend $taskBackend -Target $Target -Lines '40' `
                -ExpectedLabel $expectedLabel
            if ($null -ne $captured) { $tail40 = $captured }
        }
        return (Get-FmBusyClassification -Backend $taskBackend -Target $Target -Harness $harness `
                -Id $id -StateDir $state -Tail $tail40)
    }

    function Test-LogReportsCiReady {
        if ($logVerb -cne 'done') { return $false }
        $note = Get-FmStatusLineNote -Line $logLine
        # `*PR*"checks green"*` or `*"checks green"*PR*`: the two tokens in
        # either order, ordinal.
        $pr = $note.IndexOf('PR', [System.StringComparison]::Ordinal)
        if ($pr -ge 0 -and $note.IndexOf('checks green', $pr, [System.StringComparison]::Ordinal) -ge 0) {
            return $true
        }
        $green = $note.IndexOf('checks green', [System.StringComparison]::Ordinal)
        if ($green -ge 0 -and $note.IndexOf('PR', $green, [System.StringComparison]::Ordinal) -ge 0) {
            return $true
        }
        return $false
    }

    # --- no-mistakes run lookup (authoritative when a run matches this branch) -

    # CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
    # scratch worktree); with no branch there is no run to attribute to this crew.
    $branchResult = Invoke-FmGit @('symbolic-ref', '--quiet', '--short', 'HEAD')
    $crewBranch = if ($branchResult.Ok) { $branchResult.StdOut.TrimEnd("`n") } else { '' }

    $haveRun = $false
    # $runSource distinguishes the two ways $haveRun can be true: 'full' means
    # $script:RunOut is real `axi status` TOON with step/gate detail; 'coarse'
    # means only a bare status word came back from the runs-list fallback, so the
    # run-step block below skips the TOON field parsing entirely for this crew.
    $runSource = 'full'
    $coarseStatus = ''

    $nmCmd = Get-Command 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $script:NmCommand = if ($nmCmd) { $nmCmd.Source } else { '' }

    # Scouts and secondmates never drive a no-mistakes validation of their own
    # worktree, so skip the lookup for them and read state from pane/log directly.
    if ($kind -ceq 'ship' -and -not [string]::IsNullOrEmpty($crewBranch) -and
        -not [string]::IsNullOrEmpty($script:NmCommand)) {
        Set-FmRunOut (Invoke-FmNmRun @('axi', 'status'))
        if (-not [string]::IsNullOrEmpty($script:RunOut)) {
            $runBranch = Get-FmUnquoted (Get-NmField 'branch')
            if (-not [string]::IsNullOrEmpty($runBranch) -and $runBranch -ceq $crewBranch -and
                (Test-FmRunHeadMatchesWorktree -RunHead (Get-FmUnquoted (Get-NmField 'head')))) {
                $haveRun = $true
            } else {
                # The active-or-most-recent run is for another branch, or the same
                # branch with a rewritten/diverged head (the CLI is alive and
                # answered; only the attribution missed) - try the coarse
                # fallback. Deliberately nested inside the non-empty test: an
                # empty/timed-out primary call means the CLI itself did not
                # respond, so retrying it immediately with a second bounded call
                # would just double the wait for no better answer.
                $coarseStatus = Get-NmRunsStatusForBranch -Branch $crewBranch -Limit $runsLimit
                if (-not [string]::IsNullOrEmpty($coarseStatus)) {
                    $haveRun = $true
                    $runSource = 'coarse'
                }
            }
        }
    }

    # --- run-step authoritative path -----------------------------------------

    if ($haveRun) {
        $runState = 'working'
        $runDetail = ''
        $ciStepStatus = ''
        $ciLogState = ''
        $runStatus = ''
        if ($runSource -ceq 'coarse') {
            # No step/gate detail is available from the plain runs list - only
            # ever working, done, or failed. A crew genuinely parked at a gate
            # still gets full detail once `axi status` reports its own branch
            # again, and its own needs-decision/blocked status-log append (a
            # captain-relevant VERB) is surfaced through the actionable-signal
            # path regardless of this coarse-vs-full distinction, so a real gate
            # is never silently missed.
            switch -CaseSensitive ($coarseStatus) {
                'running' { $runState = 'working'; $runDetail = 'validating (background run)' }
                'completed' { $runState = 'done'; $runDetail = 'run completed' }
                'failed' { $runState = 'failed'; $runDetail = 'run failed' }
                'cancelled' { $runState = 'failed'; $runDetail = 'run cancelled' }
                default { $runState = 'unknown'; $runDetail = "runs list status: $coarseStatus" }
            }
        } else {
            $status = Get-FmUnquoted (Get-NmField 'status')
            $runStatus = $status
            $outcome = Get-FmUnquoted (Get-NmField 'outcome')
            $awaiting = ''
            foreach ($line in $script:RunLines) {
                if ([regex]::IsMatch($line, '^' + $script:WsRe + '*awaiting_agent:')) { $awaiting = $line; break }
            }
            $gateStatus = Get-NmGateStatus
            $hasGate = Test-NmHasGate

            if (-not [string]::IsNullOrEmpty($outcome)) {
                switch -CaseSensitive ($outcome) {
                    'passed' { $runState = 'done'; $runDetail = 'run passed: PR merged/closed' }
                    'checks-passed' { $runState = 'done'; $runDetail = 'checks green: PR ready for review' }
                    'failed' { $runState = 'failed'; $runDetail = 'run failed' }
                    'cancelled' { $runState = 'failed'; $runDetail = 'run cancelled' }
                    default { $runState = 'unknown'; $runDetail = "outcome: $outcome" }
                }
            } elseif (-not [string]::IsNullOrEmpty($awaiting) -or $status -ceq 'awaiting_approval' -or
                      $status -ceq 'fix_review' -or -not [string]::IsNullOrEmpty($gateStatus) -or $hasGate) {
                $gate = if ($hasGate) { Get-NmGateLineName } else { Get-NmGateName }
                if ([string]::IsNullOrEmpty($gate)) { $gate = $status }
                if ([string]::IsNullOrEmpty($gate)) { $gate = 'gate' }
                $runState = 'parked'
                $runDetail = "parked at $gate"
                $fcount = Get-NmGateFindingsCount
                if (-not [string]::IsNullOrEmpty($fcount)) { $runDetail = "${runDetail}: $fcount finding(s)" }
                if ($script:RunOut.Contains('ask-user')) {
                    $runDetail = "$runDetail (ask-user: authority decision)"
                }
            } else {
                switch -CaseSensitive ($status) {
                    'ci' { $runState = 'working'; $runDetail = 'ci running' }
                    { $_ -ceq 'running' -or $_ -ceq 'fixing' } {
                        $runState = 'working'; $runDetail = "validating ($status)"
                    }
                    'completed' { $runState = 'done'; $runDetail = 'run completed' }
                    'failed' { $runState = 'failed'; $runDetail = 'run failed' }
                    'cancelled' { $runState = 'failed'; $runDetail = 'run cancelled' }
                    '' { $runState = 'working'; $runDetail = 'run active' }
                    default { $runState = 'working'; $runDetail = "run active ($status)" }
                }
                if ($runState -ceq 'working') {
                    $ciStepStatus = if ($runStatus -ceq 'fixing') {
                        'fixing'
                    } else {
                        $stepStatus = Get-NmCiStepStatus
                        if (-not [string]::IsNullOrEmpty($stepStatus)) { $stepStatus }
                        elseif ($runStatus -ceq 'ci') { 'running' }
                        else { '' }
                    }
                    if ($ciStepStatus -ceq 'running') {
                        $ciLogState = Get-NmCiChecksState
                        if ($ciLogState -ceq 'green') {
                            $runState = 'done'
                            $runDetail = 'checks green: PR ready for review (still monitoring for merge/close)'
                        }
                    } elseif ($ciStepStatus -ceq 'fixing') {
                        $ciLogState = 'not-ready'
                    }
                }
            }
        }

        if ($runState -ceq 'working' -and (Test-LogReportsCiReady)) {
            $note = Get-FmStatusLineNote -Line $logLine
            if ($runSource -ceq 'coarse') {
                Send-CrewState -CrewState 'done' -Source status-log -Detail "$note$($script:Sep)run still monitoring PR"
            }
            if ([string]::IsNullOrEmpty($ciStepStatus)) {
                $ciStepStatus = if ($runStatus -ceq 'fixing') {
                    'fixing'
                } else {
                    $stepStatus = Get-NmCiStepStatus
                    if (-not [string]::IsNullOrEmpty($stepStatus)) { $stepStatus }
                    elseif ($runStatus -ceq 'ci') { 'running' }
                    else { '' }
                }
            }
            if ($runStatus -ceq 'fixing') {
                $ciLogState = 'not-ready'
            } elseif ($ciStepStatus -ceq 'running' -and [string]::IsNullOrEmpty($ciLogState)) {
                $ciLogState = Get-NmCiChecksState
            } elseif ($ciStepStatus -ceq 'fixing') {
                $ciLogState = 'not-ready'
            }
            if ($ciLogState -cne 'not-ready') {
                Send-CrewState -CrewState 'done' -Source status-log -Detail "$note$($script:Sep)run still monitoring PR"
            }
        }

        # Reconcile the status log. A needs-decision/blocked log line that the
        # run-step has moved past (anything but a genuinely parked run) is
        # deterministically stale: the gate resolved and the run resumed or
        # finished.
        if ($logVerb -ceq 'needs-decision' -or $logVerb -ceq 'blocked') {
            if ($runState -cne 'parked') {
                if ($runState -ceq 'working') {
                    $runDetail = "$runDetail$($script:Sep)status-log superseded by active run"
                } else {
                    $runDetail = "$runDetail$($script:Sep)status-log superseded (run $runState)"
                }
            }
        }

        Send-CrewState -CrewState $runState -Source run-step -Detail $runDetail
    }

    # --- fallback: no run attributed to this crew -----------------------------
    # The run-step path above already handled any crew with a run, regardless of
    # pane liveness, so a finished-but-pane-closed crew never reaches here. Down
    # here there is no run to consult, so a dead/unreadable target means the crew
    # is gone: report unknown rather than trusting a possibly-stale status log as
    # the current state.
    if ([string]::IsNullOrEmpty($backendTarget)) {
        Send-CrewState -CrewState unknown -Source none -Detail 'no backend target recorded'
    }
    if (-not (Test-PaneReadable -Target $backendTarget)) {
        Send-CrewState -CrewState unknown -Source none -Detail "backend target gone: $backendTarget"
    }

    # Secondmates idle on their own watcher (idle pane = healthy), so the busy
    # state is not meaningful for them; read their state from the status log
    # only. Only an exact busy verdict reports working here, and only an exact
    # idle verdict permits the status-log fallback below. Missing, malformed,
    # stale, or unverified semantic state remains unknown.
    if ($kind -cne 'secondmate') {
        $busyVerdict = Get-CrewBusyVerdict -Target $backendTarget
        if ($null -eq $busyVerdict) { $busyVerdict = '' }
        $verdictWord = Get-FmBeforeFirst $busyVerdict ' '
        $verdictSource = Get-FmAfterFirst $busyVerdict ' '
        if ($verdictWord -ceq 'busy') {
            Send-CrewState -CrewState working -Source pane -Detail "harness busy ($verdictSource)"
        } elseif ($verdictWord -cne 'idle') {
            Send-CrewState -CrewState unknown -Source pane -Detail "harness state unavailable ($busyVerdict)"
        }
    }

    # Fall back to the status log's last line, but ONLY when its verb maps to a
    # real run-state. A decision-closing event - resolved: (fm-classify-lib's
    # FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a
    # state: it exists solely to CLOSE a keyed decision in the durable fold, so a
    # trailing resolved: must never become the current state or leak its
    # resolution prose as the detail. Skipping it lets a just-resolved idle crew
    # (typically a secondmate, which has no busy check above) fall through to the
    # idle default instead of rendering `unknown` with the resolution note as
    # `doing`. Get-LogState is the single owner of the verb->state mapping
    # (including the configurable paused verb), so reusing its `unknown` verdict
    # as the "not a state" test needs no second verb list here.
    if (-not [string]::IsNullOrEmpty($logVerb)) {
        $logState = Get-LogState -Line $logLine
        if ($logState -cne 'unknown') {
            Send-CrewState -CrewState $logState -Source status-log -Detail (Get-FmStatusLineNote -Line $logLine)
        }
    }

    Send-CrewState -CrewState unknown -Source none -Detail 'no current-state source available'
}
