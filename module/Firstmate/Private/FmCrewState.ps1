#requires -Version 7.0
# FmCrewState.ps1 - no-mistakes run attribution primitives (bin/fm-nm-run-lib.sh)
# and the internals of the deterministic current-state read (bin/fm-crew-state.sh).
#
# The attribution rule below has ONE owner because getting it wrong is unsafe in
# both directions: a false negative hides a genuinely parked run, and a false
# positive lets teardown act on a run it does not own.

Set-StrictMode -Version Latest

# Bounded `no-mistakes <args>` in a worktree. Fail-open for these read-only
# callers: a timeout or a missing CLI yields '' and the caller falls through to
# another source rather than inventing a verdict.
function Invoke-FmNoMistakes {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if (-not (Get-Command -Name 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue)) { return '' }
    $result = Invoke-FmChildProcess -FilePath 'no-mistakes' -ArgumentList $Arguments -WorkingDirectory $WorktreePath -TimeoutSeconds $TimeoutSeconds
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return '' }
    return $result.StdOut
}

function Get-FmNmTrimmed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Trim()
}

function Get-FmNmUnquoted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $s = $Value.Trim()
    if ($s.Length -ge 2 -and $s.StartsWith('"') -and $s.EndsWith('"')) { $s = $s.Substring(1, $s.Length - 2) }
    return $s.Trim()
}

# Scalar value of a TOON key in captured `axi status` output, quotes stripped.
function Get-FmNmField {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $Output) { return '' }
    foreach ($line in ($Output -replace "`r`n", "`n").Split("`n")) {
        if ($line -match ('^\s*' + [regex]::Escape($Key) + ':\s*(.*)$')) {
            return (Get-FmNmUnquoted -Value $Matches[1])
        }
    }
    return ''
}

<#
.SYNOPSIS
Does a run head match a worktree's code identity?
.DESCRIPTION
  - missing head: cannot bind, reject
  - equal commits (short or full SHA): match
  - worktree HEAD is an ancestor of the run head: match (pipeline fix commits
    advanced the run tip along the same history)
  - run head is a strict ancestor of the worktree HEAD, or diverged: no match
    (local work advanced outside the run, or the tip was rewritten)
#>
function Test-FmNmHeadMatchesWorktree {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunHead
    )
    if (-not $RunHead) { return $false }
    $localFull = Get-FmGitFirstLine (Invoke-FmGit -Directory $WorktreePath -Arguments @('rev-parse', 'HEAD'))
    if (-not $localFull) { return $false }
    $runFull = Get-FmGitFirstLine (Invoke-FmGit -Directory $WorktreePath -Arguments @('rev-parse', '--verify', "$RunHead^{commit}"))
    if (-not $runFull) { return $false }
    if ($runFull -eq $localFull) { return $true }
    return ((Invoke-FmGit -Directory $WorktreePath -Arguments @('merge-base', '--is-ancestor', $localFull, $runFull)).Ok)
}

# Get-FmCrewLivenessDetail: the run-liveness clause the fallback current-state
# line carries, or '' when this build has no owner for the reading.
#
# Read ONLY on the path that has no run to consult and an idle endpoint - the
# exact path whose answer used to come from the crew's own stale status log and
# so reported a worker as `working` whether or not anything of its was running.
# That gap is what let nine genuinely-running suites be declared finished
# (docs/finished-run-stall.md).
#
# An INCONCLUSIVE reading adds nothing here, which is deliberately not what a
# stale wake reason does with the same input. A wake reason is an action prompt,
# so an absent reading there has to say it did not run. This line already carries
# a `source:` field saying where its answer came from, and most `unknown` readings
# mean the ordinary `this task has no live agent` that the line already reports -
# so an `unknown` clause on every such line would be noise, not information. A
# reading that THREW is different and does say so: that one is a real gap.
function Get-FmCrewLivenessDetail {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatePath
    )
    $reader = Get-Command -Name 'Get-FmTaskRunLiveness' -ErrorAction SilentlyContinue
    if (-not $reader) { return '' }
    try {
        $reading = & $reader -TaskId $Id -StatePath $StatePath
    } catch {
        return 'run-liveness: unknown (the reading did NOT run)'
    }
    if ($null -eq $reading -or -not ($reading.PSObject.Properties.Name -contains 'State')) {
        return 'run-liveness: unknown (the reading did NOT run)'
    }
    switch ([string]$reading.State) {
        'none' { return 'run-liveness: none - nothing of this task''s is running' }
        'processes' { return "run-liveness: $(@($reading.ProcessId).Count) live process(es) - work IS in flight" }
        default { return '' }
    }
}

# Map a status-log verb onto a canonical state for the fallback path. `paused`
# is the declared-external-wait verb: a crew with no active run and an idle
# endpoint that declared a known external wait reports `paused` distinctly, so a
# supervisor sees a declared pause rather than a wedge-suspect idle.
function Get-FmCrewStateFromLogVerb {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
    if (Test-FmStatusIsPaused -Line $Line) { return 'paused' }
    switch (Get-FmStatusLineVerb -Line $Line) {
        'working' { return 'working' }
        'needs-decision' { return 'parked' }
        'blocked' { return 'blocked' }
        'done' { return 'done' }
        'failed' { return 'failed' }
        default { return 'unknown' }
    }
}

# The ci step's own log text is the ONLY place no-mistakes records the
# "checks green, waiting on merge" transition: `axi status` reports plain
# ci,running for the whole CI-monitor phase, including long after every check is
# green. Scan the ci log tail for the MOST RECENT recognized marker (the log is
# chronological, so the last match is current).
function Get-FmNmCiChecksState {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId
    )
    if (-not $RunId) { return 'unknown' }
    $logTail = Invoke-FmNoMistakes -WorktreePath $WorktreePath -TimeoutSeconds $TimeoutSeconds -Arguments @('axi', 'logs', '--step', 'ci', '--run', $RunId)
    if (-not $logTail) { return 'unknown' }
    $marker = ''
    foreach ($line in ($logTail -replace "`r`n", "`n").Split("`n")) {
        if ($line -match 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout') {
            $marker = $line
        }
    }
    if ($marker -eq '') { return 'unknown' }
    if ($marker -match 'checks passed' -or $marker -match 'no CI checks reported - still monitoring') { return 'green' }
    if ($marker -match 'no CI checks reported yet|checks failed|issues detected|CI checks running' -or ($marker -match 'base branch advanced' -and $marker -match 're-arming CI monitor timeout')) { return 'not-ready' }
    return 'unknown'
}

# Coarse cross-branch fallback: `no-mistakes runs` is newest-first plain text,
# "<status> <branch> <short-sha> <date> [<pr-url>]". Branch plus coarse status is
# exactly what this needs - is a run for THIS branch active right now - and the
# same code-identity rule still applies to the row's short sha.
function Get-FmNmRunsStatusForBranch {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][int]$Limit
    )
    $out = Invoke-FmNoMistakes -WorktreePath $WorktreePath -TimeoutSeconds $TimeoutSeconds -Arguments @('runs', '--limit', "$Limit")
    if (-not $out) { return '' }
    foreach ($row in ($out -replace "`r`n", "`n").Split("`n")) {
        $row = $row.Trim()
        if ($row -eq '') { continue }
        $fields = $row -split '\s+'
        if ($fields.Count -lt 3) { continue }
        if ($fields[1] -ne $Branch) { continue }
        if (-not (Test-FmNmHeadMatchesWorktree -WorktreePath $WorktreePath -RunHead $fields[2])) { continue }
        return $fields[0]
    }
    return ''
}

# The run-step is AUTHORITATIVE when a run is attributed to this crew, so this
# mapping decides what a supervisor acts on. Kept pure - the only outside call is
# the caller-supplied ci-checks provider - so every branch is exercisable without
# a no-mistakes install.
#   running/fixing/ci -> working, awaiting_approval/fix_review/any gate -> parked,
#   passed/checks-passed -> done, failed/cancelled -> failed.
# The one exception is the ci step: `axi status` alone cannot tell "still waiting
# on checks" from "checks green, waiting on merge", so a green ci log promotes
# working -> done and a green PR is never read as still-validating.
function Resolve-FmCrewRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][ValidateSet('full', 'coarse')][string]$RunSource,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CoarseStatus,
        [Parameter(Mandatory)][scriptblock]$CiChecksStateProvider
    )
    $state = 'working'
    $detail = ''
    $runStatus = ''
    $ciStepStatus = ''
    $ciLogState = ''

    if ($RunSource -eq 'coarse') {
        # The plain runs list carries no step or gate detail - only ever
        # working, done, or failed. A crew genuinely parked at a gate still gets
        # full detail once `axi status` reports its own branch again, and its own
        # needs-decision append surfaces regardless, so a real gate is never
        # silently missed.
        switch ($CoarseStatus) {
            'running' { $state = 'working'; $detail = 'validating (background run)' }
            'completed' { $state = 'done'; $detail = 'run completed' }
            'failed' { $state = 'failed'; $detail = 'run failed' }
            'cancelled' { $state = 'failed'; $detail = 'run cancelled' }
            default { $state = 'unknown'; $detail = "runs list status: $CoarseStatus" }
        }
    } else {
        $runStatus = Get-FmNmField -Output $Output -Key 'status'
        $outcome = Get-FmNmField -Output $Output -Key 'outcome'
        $awaiting = ($Output -match '(?m)^\s*awaiting_agent:')
        $hasGate = ($Output -match '(?m)^\s*gate:\s*')
        $gateStatus = Get-FmNmGateStatus -Output $Output

        if ($outcome) {
            switch ($outcome) {
                'passed' { $state = 'done'; $detail = 'run passed: PR merged/closed' }
                'checks-passed' { $state = 'done'; $detail = 'checks green: PR ready for review' }
                'failed' { $state = 'failed'; $detail = 'run failed' }
                'cancelled' { $state = 'failed'; $detail = 'run cancelled' }
                default { $state = 'unknown'; $detail = "outcome: $outcome" }
            }
        } elseif ($awaiting -or $runStatus -eq 'awaiting_approval' -or $runStatus -eq 'fix_review' -or $gateStatus -or $hasGate) {
            $gate = Get-FmNmGateName -Output $Output
            if (-not $gate) { $gate = $runStatus }
            if (-not $gate) { $gate = 'gate' }
            $state = 'parked'
            $detail = "parked at $gate"
            $findings = Get-FmNmGateFindingsCount -Output $Output
            if ($findings) { $detail = "${detail}: $findings finding(s)" }
            if ($Output -match 'ask-user') { $detail = "$detail (ask-user: authority decision)" }
        } else {
            switch ($runStatus) {
                'ci' { $state = 'working'; $detail = 'ci running' }
                { $_ -in @('running', 'fixing') } { $state = 'working'; $detail = "validating ($runStatus)" }
                'completed' { $state = 'done'; $detail = 'run completed' }
                'failed' { $state = 'failed'; $detail = 'run failed' }
                'cancelled' { $state = 'failed'; $detail = 'run cancelled' }
                '' { $state = 'working'; $detail = 'run active' }
                default { $state = 'working'; $detail = "run active ($runStatus)" }
            }
            if ($state -eq 'working') {
                $ciStepStatus = Get-FmNmEffectiveCiStepStatus -Output $Output -RunStatus $runStatus
                if ($ciStepStatus -eq 'running') {
                    $ciLogState = [string](& $CiChecksStateProvider (Get-FmNmField -Output $Output -Key 'id'))
                    if ($ciLogState -eq 'green') {
                        $state = 'done'
                        $detail = 'checks green: PR ready for review (still monitoring for merge/close)'
                    }
                } elseif ($ciStepStatus -eq 'fixing') {
                    $ciLogState = 'not-ready'
                }
            }
        }
    }
    return [pscustomobject]@{
        State        = $state
        Detail       = $detail
        RunStatus    = $runStatus
        CiStepStatus = $ciStepStatus
        CiLogState   = $ciLogState
    }
}

# The endpoint reader is the backend area's contract. Absent it, the honest
# answer is `unknown`, never `working`: absorb-only-when-provably-working means
# a missing reader must surface the wake, not silence it.
function Get-FmCrewEndpointVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Backend,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Harness,
        [Parameter(Mandatory)][string]$StatePath
    )
    $reader = Get-Command -Name 'Get-FmBackendBusyVerdict' -ErrorAction SilentlyContinue
    if (-not $reader) {
        return [pscustomobject]@{ Available = $false; Verdict = 'unknown'; Detail = "no backend state reader available (backend $Backend)" }
    }
    try {
        $verdict = [string](& $reader -Backend $Backend -Target $Target -Id $Id -Harness $Harness -StatePath $StatePath)
    } catch {
        return [pscustomobject]@{ Available = $true; Verdict = 'unknown'; Detail = "harness state unavailable ($($_.Exception.Message))" }
    }
    if (-not $verdict) { $verdict = 'unknown' }
    $word = ($verdict -split ' ')[0]
    return [pscustomobject]@{ Available = $true; Verdict = $word; Detail = $verdict }
}
