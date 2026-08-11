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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if (-not (Get-Command -Name 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue)) { return '' }
    $result = Invoke-FmLifecycleProcess -FilePath 'no-mistakes' -Arguments $Arguments -WorkingDirectory $WorktreePath -TimeoutSeconds $TimeoutSeconds
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunHead
    )
    if (-not $RunHead) { return $false }
    $localFull = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' 'HEAD')
    if (-not $localFull) { return $false }
    $runFull = Get-FmGitOutputLine (Invoke-FmGit -RepoPath $WorktreePath 'rev-parse' '--verify' "$RunHead^{commit}")
    if (-not $runFull) { return $false }
    if ($runFull -eq $localFull) { return $true }
    return (Test-FmGitSucceeded (Invoke-FmGit -RepoPath $WorktreePath 'merge-base' '--is-ancestor' $localFull $runFull))
}

# Map a status-log verb onto a canonical state for the fallback path. `paused`
# is the declared-external-wait verb: a crew with no active run and an idle
# endpoint that declared a known external wait reports `paused` distinctly, so a
# supervisor sees a declared pause rather than a wedge-suspect idle.
function Get-FmCrewStateFromLogVerb {
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
