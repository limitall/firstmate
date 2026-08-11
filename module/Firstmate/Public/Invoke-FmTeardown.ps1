#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Tear down a finished task: prove its work has landed, take custody of its
processes, return its worktree to the pool, and only then erase its records.

.DESCRIPTION
The PowerShell port of bin/fm-teardown.sh. Teardown hard-resets a worktree,
deletes its branch and kills its processes, so the whole design is a sequence of
proofs, each of which REFUSES rather than proceeds when it cannot establish its
fact. In order:

  0. the control lock  - one lifecycle action per task at a time; a contended
                         lock changes nothing at all,
  1. the shape gates   - a backend, a remote placement or a task kind whose
                         destructive machinery is not here is refused BY NAME
                         rather than half-performed,
  2. the scout gate    - a scout's worktree is scratch; its report IS the work
                         product, so teardown refuses without one,
  3. the landed-work   - dirty / unpushed-and-unlanded / (local-only) unmerged.
     test                Uncommitted changes are NEVER landed. A git command
                         that cannot run is not a pass: when a git lock explains
                         it, the staleness proof runs and the checks are RE-RUN;
                         otherwise it is a flat refusal,
  4. process custody   - close the pane, then terminate the task's job object,
                         and refuse on any survivor. A live process in the
                         worktree means the worktree is not ours to reset,
  5. the pool return   - conditional on this task's own lease, so a return can
                         never recycle a lease the pool has re-issued. A FAILED
                         return keeps the worktree AND the state files: never
                         hide a still-held lease by deleting the record that
                         points at it,
  6. the endpoint gate - durable records are erased only once the exact recorded
                         pane is confirmed gone,
  7. the artifact gate - PR-check artifacts are validated as ordinary files in
                         the state directory before removal, so a symlinked one
                         refuses instead of deleting whatever it points at.

ORDERING NOTE, and it is a deliberate divergence from the bash. The bash closes
the pane AFTER returning the worktree. Windows locks open files: the return
fails while anything holds a handle or a cwd inside the worktree, so the report
(data/fmwin-design/report.md section 4.3) settles the order as close-pane ->
terminate-job -> return-with-retries -> name-holders-and-refuse. The cost is
that a refusal after step 4 leaves the task's pane closed; the benefit is that
the return is attempted only once the worktree is provably ours.

-Force IS NOT THE PATH OF LEAST RESISTANCE. It skips the landed-work test and
the scout report gate, which is to say it discards work, so it requires
-DiscardApprovedBy naming who authorized that. -Force on its own is a usage
error, never a slightly-more-forceful retry. (The bash takes a bare --force;
this is the one place the port is deliberately stricter, because the captain's
explicit OK is the actual precondition and an unqualified flag does not record
it.)

NOT PORTED, and refused BY NAME rather than approximated: secondmate home
retirement (the descendant-home, registry and process-event machinery is its own
area), remote-placed secondmates, the Orca backend (dropped by directive), the
myfirstmate public-followup gate, and the Herdr presentation journal. Each
missing owner is reported as a step that did NOT run.
#>
function Invoke-FmTeardown {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TaskId,
        [string]$FirstmateHome = '',
        [switch]$Force,
        [string]$DiscardApprovedBy = '',
        [double]$CustodyTimeoutSeconds = 10
    )

    if ($Force -and -not $DiscardApprovedBy) {
        throw ('usage: -Force discards work that has not landed, so it requires -DiscardApprovedBy ' +
            "naming who approved the discard; refusing to tear down $TaskId on an unqualified flag")
    }

    # --- resolve the task ----------------------------------------------------

    if (-not $FirstmateHome) { $FirstmateHome = $env:FM_HOME }
    if (-not $FirstmateHome) {
        throw 'error: FM_HOME is not set; teardown refuses to resolve a task without an explicit firstmate home'
    }
    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: invalid teardown request: '$TaskId' is not a valid task id"
    }
    $stateDir = Join-Path $FirstmateHome 'state'
    $dataDir = Join-Path $FirstmateHome 'data'
    $configDir = Join-Path $FirstmateHome 'config'
    $metaPath = Get-FmMetaPath -StateDir $stateDir -TaskId $TaskId

    # The control lock is taken BEFORE the meta is read and held for the whole
    # teardown: two concurrent teardowns of one task would race on the same
    # worktree, the same pool slot and the same records. A contended lock is a
    # refusal that changes nothing.
    $controlLock = Join-Path $stateDir ".control-$TaskId.lock"
    if (-not (Enter-FmTeardownLock -LockPath $controlLock)) {
        throw "error: another lifecycle action is already running for task $TaskId; nothing was changed"
    }

    try {
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            throw "error: no meta for task $TaskId at $metaPath"
        }

        $worktree = Get-FmMetaValue -Path $metaPath -Key 'worktree'
        $project = Get-FmMetaValue -Path $metaPath -Key 'project'
        $kind = Get-FmMetaValue -Path $metaPath -Key 'kind'
        if (-not $kind) { $kind = 'ship' }
        $mode = Get-FmMetaValue -Path $metaPath -Key 'mode'
        $prUrl = Get-FmMetaValue -Path $metaPath -Key 'pr'
        $taskTmp = Get-FmMetaValue -Path $metaPath -Key 'tasktmp'
        $leaseId = Get-FmMetaValue -Path $metaPath -Key 'treehouse_lease_id'
        $backend = Get-FmMetaBackend -Path $metaPath
        $target = Get-FmMetaTarget -Path $metaPath

        $steps = [System.Collections.Generic.List[object]]::new()
        $note = {
            param([string]$Name, [string]$Outcome, [string]$Detail = '')
            $steps.Add([pscustomobject]@{ Step = $Name; Outcome = $Outcome; Detail = $Detail })
        }
        $refuse = {
            param([string[]]$Lines)
            throw (($Lines | Where-Object { $null -ne $_ }) -join [Environment]::NewLine)
        }

        # --- shape gates -----------------------------------------------------

        if ($backend -ne 'herdr') {
            & $refuse @("REFUSED: task $TaskId records backend '$backend'; this PowerShell port drives the herdr session provider only.",
                'Tear it down from the implementation that owns that backend.')
        }

        # A remote placement means the work, the worktree and the runtime all
        # live on another machine, so nothing here could verify - let alone
        # perform - its retirement.
        if (Get-FmMetaValue -Path $metaPath -Key 'remote_host') {
            & $refuse @("REFUSED: task $TaskId is a remote-placed secondmate; its retirement is not part of this port.",
                'Retire it from the home that owns its route; every record here is preserved.')
        }

        if ($kind -eq 'secondmate') {
            $homePath = Get-FmMetaValue -Path $metaPath -Key 'home'
            if (-not $homePath) { $homePath = $worktree }
            $subState = Join-Path $homePath 'state'
            if (-not $Force -and (Test-Path -LiteralPath $subState -PathType Container)) {
                $child = @(Get-ChildItem -LiteralPath $subState -Filter '*.meta' -File -ErrorAction SilentlyContinue)
                if ($child.Count -gt 0) {
                    & $refuse @("REFUSED: secondmate $TaskId still has in-flight work in $subState.",
                        "Found $($child[0].Name). Let that home finish or explicitly discard with --force.")
                }
            }
            # Retiring a home is descendant-home cleanup, registry surgery and
            # process-event restoration - a separate area. Refusing by name is
            # the honest degradation; half a home retirement is worse than none.
            & $refuse @("REFUSED: secondmate $TaskId cannot be retired by this port yet.",
                'Its home retirement owner (descendant task locks, the registry entry, and process-event restoration) has not landed;',
                'no step of it ran, and every record is preserved.')
        }

        # --- the scout gate --------------------------------------------------

        if ($kind -eq 'scout' -and -not $Force) {
            $report = Join-Path (Join-Path $dataDir $TaskId) 'report.md'
            if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
                & $refuse @("REFUSED: scout task $TaskId has no report at $report.",
                    'The report is the work product. Have the crewmate write it, or use --force after explicit discard approval.')
            }
            & $note 'scout-report' 'passed' $report

            # Two candidate names: the decision-hold area has not landed, and
            # the two teardown ports that preceded this one each expected a
            # different one. Accepting both means whichever it publishes works.
            $gate = $null
            $gateName = ''
            foreach ($candidate in @('Test-FmDecisionHoldComplete', 'Test-FmDecisionHoldVerified')) {
                $gate = Resolve-FmTeardownOwner -Name $candidate
                if ($gate) { $gateName = $candidate; break }
            }
            if (-not $gate) {
                # Fail CLOSED: this gate exists to stop a scout's unresolved
                # decisions being erased with its state. An absent owner cannot
                # prove they are resolved, and teardown is destructive.
                & $refuse @("REFUSED: scout task $TaskId cannot pass the unresolved-decision completion gate.",
                    'Its owner (Test-FmDecisionHoldComplete or Test-FmDecisionHoldVerified) has not landed, so the gate did NOT run and cannot report a pass.',
                    'Inventory the report and any visual review through the decision-hold owner before teardown, or use --force after explicit discard approval.')
            }
            $passed = if ($gateName -eq 'Test-FmDecisionHoldVerified') {
                & $gate -Id $TaskId
            } else {
                & $gate -TaskId $TaskId -FirstmateHome $FirstmateHome
            }
            if (-not $passed) {
                & $refuse @("REFUSED: scout task $TaskId has not passed the unresolved-decision completion gate.",
                    'Inventory its report and any visual review through the decision-hold owner before teardown.')
            }
            & $note 'decision-hold-gate' 'passed' $gateName
        } elseif ($kind -eq 'scout') {
            & $note 'scout-report' 'skipped' 'forced discard'
        }

        # --- the landed-work test --------------------------------------------

        $safetyArgs = @{
            Worktree = $worktree; Project = $project; Kind = $kind; Mode = $mode; PrUrl = $prUrl
        }
        if ($Force) {
            & $note 'landed-work-test' 'skipped' "forced discard approved by $DiscardApprovedBy"
        } else {
            $verdict = Test-FmTeardownWorktreeSafety @safetyArgs
            if ($verdict.Verdict -eq 'lock-blocked') {
                foreach ($line in $verdict.Message) { Write-Warning $line }
                if ((Clear-FmTeardownStaleLock -Worktree $worktree -TaskId $TaskId -Confirm:$false) -ne 'cleared') {
                    & $refuse @("REFUSED: worktree $worktree for $TaskId cannot be inspected while a git lock that is not provably stale is present.",
                        'Every record is preserved; rerun teardown once the lock clears or its owner exits.')
                }
                $verdict = Test-FmTeardownWorktreeSafety @safetyArgs
                if ($verdict.Verdict -eq 'lock-blocked') {
                    & $refuse @("REFUSED: worktree $worktree for $TaskId is still not inspectable after clearing a stale git lock.",
                        'Every record is preserved.')
                }
            }
            if ($verdict.Verdict -ne 'allow') { & $refuse $verdict.Message }
            & $note 'landed-work-test' 'passed'
        }

        if (-not $PSCmdlet.ShouldProcess("task $TaskId (worktree $worktree)", 'tear down: kill processes, return the worktree, erase records')) {
            return $null
        }

        # --- conclude this task's own parked pipeline run --------------------
        #
        # Before the worktree goes away: a run parked at a gate with no worker
        # left to answer it holds a fleet slot indefinitely. Only a run this
        # worktree provably owns is aborted, and a failure here never strands
        # the teardown - it is housekeeping, not a safety property.

        try {
            $concluded = Stop-FmTaskNoMistakesRun -WorktreePath $worktree
            if ($concluded) {
                & $note 'no-mistakes-run' 'concluded' $concluded
            } else {
                & $note 'no-mistakes-run' 'nothing-to-do'
            }
        } catch {
            & $note 'no-mistakes-run' 'failed' $_.Exception.Message
        }

        # --- process custody --------------------------------------------------

        if ($target) {
            $closed = [bool](Remove-FmHerdrPane -Target $target -Confirm:$false)
            & $note 'pane-close' $(if ($closed) { 'closed' } else { 'unconfirmed' }) $target
        } else {
            & $note 'pane-close' 'did-not-run' 'no endpoint recorded'
        }

        $custody = Stop-FmTaskJob -TaskId $TaskId -TimeoutSeconds $CustodyTimeoutSeconds -Confirm:$false
        switch ($custody.Outcome) {
            'terminated' { & $note 'process-custody' 'terminated' $custody.Detail }
            'survivors' {
                & $refuse @("REFUSED: task $TaskId still has live processes in its worktree after its custody job was terminated.",
                    "surviving process ids: $($custody.Survivors -join ', ')",
                    'A live process in the worktree means the worktree is not ours to reset; the worktree and every record are preserved.')
            }
            default {
                # not-found / unsupported / unverified: custody was NOT proven.
                # Continue, because on Windows the pool return itself fails
                # closed while anything holds the worktree - but say so, and
                # never record it as a step that passed.
                & $note 'process-custody' 'did-not-run' $custody.Detail
            }
        }

        # --- worktree cleanup and the pool return ----------------------------

        if ($worktree -and (Test-Path -LiteralPath $worktree -PathType Container)) {
            # Named before anything is touched: without treehouse the worktree
            # cannot be returned at all, and finding that out after deleting the
            # branch would be a pointless loss.
            if (-not (Test-FmTeardownTreehouseAvailable)) {
                & $refuse @("REFUSED: treehouse is not available, so worktree $worktree cannot be returned to its pool.",
                    'It was left in place and no task record was removed.')
            }

            # Our own dropped-in hook files go first, so a reused pool worktree
            # can never fire signals for a dead task.
            foreach ($relative in @(
                    (Join-Path '.claude' 'settings.local.json'),
                    (Join-Path (Join-Path '.opencode' 'plugins') 'fm-turn-end.js'),
                    (Join-Path (Join-Path '.opencode' 'plugins') 'fm-busy-state.js'),
                    '.fm-grok-turnend', '.fm-kimi-turnend')) {
                Remove-Item -LiteralPath (Join-Path $worktree $relative) -Force -ErrorAction SilentlyContinue
            }

            $branch = Get-FmGitOutput -Directory $worktree -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
            if ($branch -and $branch -ne 'HEAD') {
                if ((Invoke-FmGit -Directory $worktree -Arguments @('checkout', '--detach', '-q')).Ok) {
                    $null = Invoke-FmGit -Directory $worktree -Arguments @('branch', '-D', $branch)
                    & $note 'branch-delete' 'deleted' $branch
                } else {
                    & $note 'branch-delete' 'skipped' "could not detach HEAD in $worktree"
                }
            }

            $postCheck = $null
            if (-not $Force -and $kind -notin @('scout', 'secondmate')) {
                $postCheck = { (Test-FmTeardownWorktreeSafety @safetyArgs).Verdict -eq 'allow' }.GetNewClosure()
            }
            $returned = Invoke-FmTeardownWorktreeReturn -Worktree $worktree -Project $project `
                -LeaseId $leaseId -TaskId $TaskId -PostCleanupCheck $postCheck -Confirm:$false
            if ($returned.Outcome -ne 'returned') {
                # Leaving the state files in place is the point: a record that
                # still names the worktree is how a still-held lease stays
                # visible.
                & $refuse @("REFUSED: treehouse return failed for worktree $worktree; teardown aborted for $TaskId.",
                    $returned.Detail,
                    'The worktree and every state file are preserved so the lease it still holds is not hidden.')
            }
            $leaseNote = if ($leaseId) { "conditional on lease $leaseId" } else { 'unconditional: no lease id recorded' }
            & $note 'worktree-return' 'returned' $leaseNote
        } else {
            & $note 'worktree-return' 'did-not-run' 'no worktree on disk'
        }

        # --- the endpoint gate, then the records -----------------------------

        if ($target) {
            if (-not (Test-FmHerdrEndpointGone -Target $target)) {
                & $refuse @("REFUSED: herdr pane $target for $TaskId is not confirmed gone after its close was refused, skipped, or failed.",
                    'Every durable task record is retained - rerun teardown once the close can be confirmed.')
            }
            & $note 'endpoint-gone' 'confirmed' $target
        }

        if ($taskTmp -and (Test-Path -LiteralPath $taskTmp -PathType Container)) {
            Remove-Item -LiteralPath $taskTmp -Recurse -Force -ErrorAction SilentlyContinue
            & $note 'tasktmp' 'removed' $taskTmp
        }

        # PR-check artifacts are validated before removal: a symlinked one
        # refuses rather than deleting whatever is on the other end.
        if (-not (Remove-FmTaskPrPollArtifact -StatePath $stateDir -Id $TaskId -Confirm:$false)) {
            & $refuse @("REFUSED: task $TaskId's PR-check artifacts did not pass validation; preserving task state.",
                'Every remaining record is retained for inspection.')
        }
        & $note 'pr-check-artifacts' 'removed'

        foreach ($suffix in @(
                '.status', '.turn-ended', '.meta', '.pi-ext.ts', '.grok-turnend-token',
                '.kimi-turnend-token', '.muse-session', '.muse-session-current',
                '.control-relaunch', '.control-relaunch.meta-prior',
                '.control-relaunch.brief-prior', '.control-relaunch.note')) {
            Remove-Item -LiteralPath (Join-Path $stateDir "$TaskId$suffix") -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath (Join-Path $stateDir ".$TaskId.open-decisions-cursor") -Force -ErrorAction SilentlyContinue
        & $note 'state-records' 'removed'

        $reminder = Get-FmTeardownBacklogReminder -TaskId $TaskId -Kind $kind -Mode $mode -PrUrl $prUrl `
            -TasksAxiAvailable:(Test-FmTeardownTasksAxiBacklog -ConfigPath $configDir)

        [pscustomobject]@{
            TaskId   = $TaskId
            Outcome  = 'complete'
            Worktree = $worktree
            Target   = $target
            Forced   = [bool]$Force
            Steps    = @($steps)
            Summary  = "teardown $TaskId complete (window $target, worktree $worktree)"
            Reminder = $reminder
        }
    } finally {
        Exit-FmTeardownLock -LockPath $controlLock
    }
}
