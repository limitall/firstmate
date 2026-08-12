#requires -Version 7.0
# FmCrewState.ps1 (public) - deterministic read of a crew's CURRENT state,
# ported from bin/fm-crew-state.sh.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT log.
# Crews append only wake-worthy transitions and nothing when they silently
# resume, so the last line reports the last EVENT, not the current STATE. This
# never infers current state from a tail of that log: it reads the authoritative
# source - a no-mistakes run-step attributed to this crew's branch AND current
# code identity, else the endpoint's busy signature - and reconciles the
# possibly-stale log against it.
#
# Output is one stable, parseable line:
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Read-only and side-effect free.

Set-StrictMode -Version Latest

$script:FmCrewStateSeparator = ' · '

<#
.SYNOPSIS
The one canonical current-state line for a task.
#>
function Get-FmCrewState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id)

    $sep = $script:FmCrewStateSeparator
    $emit = {
        param([string]$state, [string]$source, [string]$detail = '')
        $line = "state: $state${sep}source: $source"
        if ($detail) { $line = "$line$sep$detail" }
        return $line
    }

    if (-not $Id) { throw 'usage: Get-FmCrewState <id>' }
    $paths = Get-FmLifecyclePaths
    $state = $paths.State
    $meta = Join-Path $state "$Id.meta"
    $log = Join-Path $state "$Id.status"

    $nmTimeout = 10
    if ($env:FM_CREW_STATE_NM_TIMEOUT -match '^[0-9]+$') { $nmTimeout = [int]$env:FM_CREW_STATE_NM_TIMEOUT }
    $runsLimit = 200
    if ($env:FM_CREW_STATE_RUNS_LIMIT -match '^[0-9]+$') { $runsLimit = [int]$env:FM_CREW_STATE_RUNS_LIMIT }

    if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) { return (& $emit 'unknown' 'none' "no metadata for $Id") }

    $worktree = Get-FmMetaValue -Path $meta -Key 'worktree'
    $kind = Get-FmMetaValue -Path $meta -Key 'kind'
    if (-not $kind) { $kind = 'ship' }
    $harness = Get-FmMetaValue -Path $meta -Key 'harness'
    $backend = Get-FmMetaValue -Path $meta -Key 'backend'
    if (-not $backend) { $backend = 'tmux' }
    $target = Get-FmMetaValue -Path $meta -Key 'window'
    if (-not $target) { $target = Get-FmMetaValue -Path $meta -Key 'terminal' }

    # A torn-down (or never-created) worktree has no current state to read.
    if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container)) {
        return (& $emit 'unknown' 'none' 'worktree gone (torn down?)')
    }

    $logLine = Get-FmLastStatusLine -Path $log
    $logVerb = Get-FmStatusLineVerb -Line $logLine

    # --- no-mistakes run lookup (authoritative when a run matches this branch)
    # A detached HEAD (a just-spawned crew, or a scout's scratch worktree) has no
    # branch, so there is no run to attribute to this crew.
    $crewBranch = Get-FmGitFirstLine (Invoke-FmGit -Directory $worktree -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD'))
    $haveRun = $false
    $runSource = 'full'
    $coarseStatus = ''
    $runOut = ''
    if ($kind -eq 'ship' -and $crewBranch -and (Get-Command -Name 'no-mistakes' -CommandType Application -ErrorAction SilentlyContinue)) {
        $runOut = Invoke-FmNoMistakes -WorktreePath $worktree -TimeoutSeconds $nmTimeout -Arguments @('axi', 'status')
        if ($runOut) {
            $runBranch = Get-FmNmField -Output $runOut -Key 'branch'
            if ($runBranch -and $runBranch -eq $crewBranch -and (Test-FmNmHeadMatchesWorktree -WorktreePath $worktree -RunHead (Get-FmNmField -Output $runOut -Key 'head'))) {
                $haveRun = $true
            } else {
                # The active-or-most-recent run is another branch's, or the same
                # branch with a rewritten head. Only the attribution missed, so
                # try the coarse runs-list fallback.
                $coarseStatus = Get-FmNmRunsStatusForBranch -WorktreePath $worktree -TimeoutSeconds $nmTimeout -Branch $crewBranch -Limit $runsLimit
                if ($coarseStatus) {
                    $haveRun = $true
                    $runSource = 'coarse'
                }
            }
        }
    }

    if ($haveRun) {
        # The ci-step log tail is the only place no-mistakes records the
        # "checks green, waiting on merge" transition, and it costs another
        # bounded CLI call, so it is resolved lazily.
        # Deliberately NOT .GetNewClosure(): that copy binds a fresh scope whose
        # function lookup does not carry the module's own functions when the
        # scriptblock is invoked from a host that dot-sourced them (a Pester
        # session is the one that bites), so the ci-monitor branch throws
        # CommandNotFoundException instead of resolving. A plain scriptblock
        # resolves $worktree and $nmTimeout through the runtime scope chain -
        # Resolve-FmCrewRunState's caller is this function - and keeps the branch
        # exercisable end to end.
        $ciChecks = {
            param([string]$runId)
            Get-FmNmCiChecksState -WorktreePath $worktree -TimeoutSeconds $nmTimeout -RunId $runId
        }
        $run = Resolve-FmCrewRunState -Output $runOut -RunSource $runSource -CoarseStatus $coarseStatus -CiChecksStateProvider $ciChecks
        $runState = $run.State
        $runDetail = $run.Detail

        # A worker that already reported "PR ... checks green" is finished even
        # while the run keeps monitoring the PR for merge.
        $logReportsCiReady = ($logVerb -eq 'done' -and (Get-FmStatusLineNote -Line $logLine) -match 'PR.*checks green|checks green.*PR')
        if ($runState -eq 'working' -and $logReportsCiReady) {
            $ciLogState = $run.CiLogState
            if ($runSource -eq 'coarse') {
                return (& $emit 'done' 'status-log' ((Get-FmStatusLineNote -Line $logLine) + $sep + 'run still monitoring PR'))
            }
            $ciStepStatus = $run.CiStepStatus
            if (-not $ciStepStatus) { $ciStepStatus = Get-FmNmEffectiveCiStepStatus -Output $runOut -RunStatus $run.RunStatus }
            if ($run.RunStatus -eq 'fixing') { $ciLogState = 'not-ready' }
            elseif ($ciStepStatus -eq 'running' -and -not $ciLogState) {
                $ciLogState = & $ciChecks (Get-FmNmField -Output $runOut -Key 'id')
            } elseif ($ciStepStatus -eq 'fixing') { $ciLogState = 'not-ready' }
            if ($ciLogState -ne 'not-ready') {
                return (& $emit 'done' 'status-log' ((Get-FmStatusLineNote -Line $logLine) + $sep + 'run still monitoring PR'))
            }
        }

        # Reconcile the status log: a needs-decision/blocked line the run-step has
        # moved past is deterministically stale - the gate resolved and the run
        # resumed or finished.
        if ($logVerb -eq 'needs-decision' -or $logVerb -eq 'blocked') {
            if ($runState -ne 'parked') {
                if ($runState -eq 'working') { $runDetail = "$runDetail${sep}status-log superseded by active run" }
                else { $runDetail = "$runDetail${sep}status-log superseded (run $runState)" }
            }
        }
        return (& $emit $runState 'run-step' $runDetail)
    }

    # --- fallback: no run attributed to this crew ---------------------------
    # Any crew with a run was handled above regardless of endpoint liveness, so a
    # finished-but-endpoint-closed crew never reaches here. Down here there is no
    # run to consult, so a dead or unreadable endpoint means the crew is gone:
    # report unknown rather than trusting a possibly-stale status log.
    if (-not $target) { return (& $emit 'unknown' 'none' 'no backend target recorded') }

    if ($kind -ne 'secondmate') {
        $verdict = Get-FmCrewEndpointVerdict -Backend $backend -Target $target -Id $Id -Harness $harness -StatePath $state
        if (-not $verdict.Available) { return (& $emit 'unknown' 'none' $verdict.Detail) }
        switch ($verdict.Verdict) {
            'busy' { return (& $emit 'working' 'pane' "harness busy ($($verdict.Detail))") }
            'idle' { }
            default { return (& $emit 'unknown' 'pane' "harness state unavailable ($($verdict.Detail))") }
        }
    }

    # Fall back to the status log's last line, but ONLY when its verb maps to a
    # real run-state. A decision-closing `resolved:` is not a state - it exists
    # solely to close a keyed decision - so it must never become the current
    # state or leak its resolution prose as the detail.
    if ($logVerb) {
        $logState = Get-FmCrewStateFromLogVerb -Line $logLine
        if ($logState -ne 'unknown') {
            return (& $emit $logState 'status-log' (Get-FmStatusLineNote -Line $logLine))
        }
    }
    return (& $emit 'unknown' 'none' 'no current-state source available')
}

# --- gate detail parsing ----------------------------------------------------

function Get-FmNmGateStepRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    foreach ($line in ($Output -replace "`r`n", "`n").Split("`n")) {
        if ($line -match '^\s*[^,]+,\s*"?(awaiting_approval|fix_review)"?\s*,') {
            $fields = $line.Trim().Split(',')
            return [pscustomobject]@{
                Step     = $fields[0].Trim()
                Status   = (Get-FmNmUnquoted -Value $fields[1])
                Findings = if ($fields.Count -gt 2) { $fields[2].Trim() } else { '' }
            }
        }
    }
    return $null
}

function Get-FmNmGateStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    foreach ($line in ($Output -replace "`r`n", "`n").Split("`n")) {
        if ($line -match '^\s*(status|state):\s*"?(awaiting_approval|fix_review)"?\s*$') { return $Matches[2] }
    }
    $row = Get-FmNmGateStepRow -Output $Output
    if ($row) { return $row.Status }
    return ''
}

function Get-FmNmGateName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    $gate = Get-FmNmField -Output $Output -Key 'gate'
    if ($gate) { return $gate }
    $inGate = $false
    foreach ($line in ($Output -replace "`r`n", "`n").Split("`n")) {
        if ($line -match '^\s*gate:\s*$') { $inGate = $true; continue }
        if ($inGate) {
            if ($line -match '^[^\s][^:]*:') { break }
            if ($line -match '^\s*step:\s*(.*)$') { return (Get-FmNmUnquoted -Value $Matches[1]) }
        }
    }
    $row = Get-FmNmGateStepRow -Output $Output
    if ($row) { return $row.Step }
    return ''
}

function Get-FmNmGateFindingsCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Output)
    if ($Output -match 'findings\[([0-9]+)\]') { return $Matches[1] }
    $row = Get-FmNmGateStepRow -Output $Output
    if ($row -and $row.Findings -match '^[0-9]+$') { return $row.Findings }
    return ''
}

function Get-FmNmEffectiveCiStepStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Output,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunStatus
    )
    if ($RunStatus -eq 'fixing') { return 'fixing' }
    foreach ($line in ($Output -replace "`r`n", "`n").Split("`n")) {
        if ($line -match '^\s*ci,\s*"?(running|fixing)"?\s*,') { return $Matches[1] }
    }
    if ($RunStatus -eq 'ci') { return 'running' }
    return ''
}
