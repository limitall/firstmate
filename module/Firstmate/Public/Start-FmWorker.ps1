#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Spawn one firstmate worker into a genuinely isolated worktree on the herdr
session provider.

.DESCRIPTION
The PowerShell port of bin/fm-spawn.sh's core: acquire an isolated copy, prove
it is isolated, create the worker's pane inside it, publish the durable task
record, and hand the worker its brief.

WHAT IS PRESERVED (the guarantee, not the mechanism)
  - A worker lands in a genuinely isolated copy. The copy is acquired with
    `treehouse get --lease` (Private/FmWorktree.ps1 owns why that is better
    than typing `treehouse get` into the pane and scraping its cwd), and the
    pane is then CREATED IN that copy rather than being told to walk into it.
  - A failed isolation check stops the task. Assert-FmWorktreeIsolation runs
    before any pane exists, and the pane's own reported cwd is confirmed
    against the leased path afterwards; either failure aborts, closes anything
    already created, and releases the lease.
  - The durable record is published only once the endpoint exists, and it
    keeps the bash field set and order byte-for-byte so a Linux firstmate can
    read it.

  - The delivery contract, the harness, and the launch command are RESOLVED
    BEFORE the fleet is touched, by Resolve-FmSpawnPlan (Private/FmDispatch.ps1).
    Mode and yolo are never guessed, an unverified adapter never silently
    becomes another one, and a missing executable refuses before an endpoint
    exists.

WHAT IS NOT PORTED HERE (each belongs to another area of the port, and each
would be a guess if invented here; see docs/task-dispatch-windows.md):
  - the per-harness turn-end hook and busy-state wiring, and trust-dialog
    handling.
  - relaunch, secondmate home provisioning, remote placement, trace-context
    propagation, and the herdr presentation projection.

.EXAMPLE
Start-FmWorker -TaskId my-task -Project C:\repos\thing -BriefPath C:\fm\data\my-task\brief.md -Harness claude -Mode local-only -Yolo off
#>
function Start-FmWorker {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter()][AllowEmptyString()][string]$Harness = '',
        [string]$LaunchCommand = '',
        [ValidateSet('ship', 'scout', 'secondmate')][string]$Kind = 'ship',
        [string]$Mode = '',
        [string]$Yolo = '',
        [string]$Model = '',
        [string]$Effort = '',
        [string[]]$ProjectList = @(),
        [string]$FirstmateHome = '',
        [string]$LabelHome = '',
        [ValidateSet('herdr')][string]$Backend = 'herdr',
        [switch]$SkipBaseRefresh
    )

    # The foundation's id rule, not the backend's looser shape check: this call
    # is about to create state files, and Test-FmTaskId is the owner that also
    # rejects '.', '..' and a trailing dot (which Windows silently strips,
    # aliasing two ids onto one record).
    if (-not (Test-FmTaskId -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id (allowed: A-Z a-z 0-9 . _ -, and never '.', '..' or a trailing dot)"
    }
    # A NAMED home is a request for that home's state; an ambient
    # FM_STATE_OVERRIDE may only redirect the home this process inherited. That
    # is Get-FmStateRoot's distinction, and going through it is what keeps the
    # record where the watcher and the drain look for it.
    $namedHome = [bool]$FirstmateHome
    if (-not $FirstmateHome) { $FirstmateHome = $env:FM_HOME }
    if (-not $FirstmateHome) {
        throw 'error: FM_HOME is not set; fm-spawn refuses to publish a task record without an explicit firstmate home'
    }
    if (-not (Test-Path -LiteralPath $FirstmateHome -PathType Container)) {
        throw "error: FM_HOME '$FirstmateHome' is not a directory"
    }
    $projectReal = Resolve-FmPhysicalPath -Path $Project
    if (-not $projectReal) {
        throw "error: project '$Project' does not resolve to a directory"
    }
    if (-not (Test-Path -LiteralPath $BriefPath -PathType Leaf)) {
        throw "error: brief '$BriefPath' does not exist; a worker is never launched without its instructions"
    }

    $stateDir = if ($namedHome) { Get-FmStateRoot -HomePath $FirstmateHome } else { Get-FmStateRoot }
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $stateDir -Force
    }
    $metaPath = Get-FmMetaPath -StateDir $stateDir -TaskId $TaskId
    if (Test-Path -LiteralPath $metaPath) {
        throw "error: task $TaskId already has a durable record at $metaPath; refusing a duplicate launch"
    }

    # Everything a spawn must DECIDE, decided before the fleet is touched: the
    # delivery contract, the harness, the profile axes, and the launch command.
    # Every refusal in there happens while nothing has been created yet, so a
    # refused spawn leaves no worktree leased and no endpoint behind.
    $plan = Resolve-FmSpawnPlan -TaskId $TaskId -Kind $Kind -BriefPath $BriefPath -Project $projectReal `
        -ConfigDir (Join-Path $FirstmateHome 'config') -Harness $Harness -LaunchCommand $LaunchCommand `
        -Mode $Mode -Yolo $Yolo -Model $Model -Effort $Effort
    $Harness = $plan.Harness
    $LaunchCommand = $plan.LaunchCommand
    $Model = $plan.Model
    $Effort = $plan.Effort
    if (-not $LaunchCommand) {
        throw "error: no launch command for harness '$Harness'; pass -LaunchCommand, because this port never guesses how to start an agent"
    }

    # The herdr workspace label is derived from FM_HOME: the primary home is
    # "firstmate", a seeded secondmate home is "2ndmate-<id>". A PRIMARY home
    # spawning a SECONDMATE must therefore label the container with the
    # SECONDMATE's home, not its own - otherwise that secondmate's workers land
    # in the primary's workspace and every later per-home lookup finds the wrong
    # container. The bash spawn shadows FM_HOME around the container call for
    # exactly this; here it is an explicit parameter, and a secondmate launch
    # must name it rather than silently inheriting the wrong label.
    if (-not $LabelHome) {
        if ($Kind -eq 'secondmate') {
            throw ("error: a secondmate launch must name that secondmate's own home with -LabelHome, so its herdr " +
                "workspace carries that home's label instead of the launching home's")
        }
        $LabelHome = $FirstmateHome
    }

    $label = "fm-$TaskId"
    if (-not $PSCmdlet.ShouldProcess("task $TaskId", "spawn a $Harness worker on $Backend")) { return $null }

    $lease = $null
    $created = $null
    try {
        # 1. The isolated copy. New-FmIsolatedWorktree leases it, proves the
        #    isolation guarantee, and refreshes the pooled base - and releases
        #    the lease itself if any of that fails.
        $lease = New-FmIsolatedWorktree -Project $projectReal -LeaseHolder $label `
            -SkipBaseRefresh:$SkipBaseRefresh -Confirm:$false
        if ($null -eq $lease) { throw 'error: worktree acquisition returned nothing' }
        $worktree = $lease.Path

        # 2. The container. A fresh per-home workspace is created in the
        #    PROJECT directory, exactly as the bash spawn does, so an
        #    unlabelled workspace's displayed name still reads as the project.
        $savedHome = $env:FM_HOME
        try {
            $env:FM_HOME = $LabelHome
            $container = New-FmHerdrContainer -Cwd $projectReal `
                -Relationship $(if ($Kind -eq 'secondmate') { 'other-home' } else { 'launcher-home' }) -Confirm:$false
        } finally {
            $env:FM_HOME = $savedHome
        }

        # 3. The pane, created directly IN the leased worktree. This is where
        #    the mechanism changes and the guarantee does not: the bash spawn
        #    creates the pane in the project and then types `treehouse get`
        #    into it, so the worker's own shell is what moves; here the pane is
        #    born in the isolated copy and never touches the primary checkout.
        $created = New-FmHerdrTask -Container $container.Container -Label $label -Cwd $worktree `
            -SeededTabId $container.SeededTabId -Confirm:$false
        if ($null -eq $created) { throw "error: herdr did not return a tab/pane id for $label" }

        # 4. Confirm the endpoint really is in the isolated copy. The lease
        #    reported the path and the isolation check already passed, so this
        #    is the independent second reading: if the pane is anywhere else,
        #    the task stops here rather than running in the wrong tree.
        Confirm-FmWorkerWorktree -Target $created.Target -Worktree $worktree -Project $projectReal

        # 5. Per-task temp root. Nested so other per-task temp can live
        #    alongside it later and teardown removes one deterministic path.
        $taskTmp = Join-Path ([System.IO.Path]::GetTempPath()) "fm-$TaskId"
        $null = New-Item -ItemType Directory -Path (Join-Path $taskTmp 'gotmp') -Force

        # 6. Publish the durable record. Field set and ORDER are owned by
        #    ConvertTo-FmTaskRecordField, which follows bin/fm-spawn.sh exactly so a
        #    Linux firstmate reads this file unchanged.
        $fields = ConvertTo-FmTaskRecordField -TaskId $TaskId -Window $created.Target -Worktree $worktree `
            -Project $projectReal -Harness $Harness -Kind $Kind -Mode $Mode -Yolo $Yolo -TaskTmp $taskTmp `
            -Model $Model -Effort $Effort -Backend 'herdr' -HerdrSession $container.Session `
            -HerdrWorkspaceId $container.WorkspaceId -HerdrTabId $created.TabId -HerdrPaneId $created.PaneId `
            -ProjectList (@($ProjectList | Where-Object { $_ }) -join ' ') -LeaseId $lease.LeaseId

        Write-FmTaskRecord -Path $metaPath -Fields $fields -Confirm:$false

        # 7. Hand the worker its brief. `pane run` types and submits in one
        #    call, so there is no unsubmitted-launch state to recover from.
        if (-not (Send-FmHerdrTextLine -Target $created.Target -Text $LaunchCommand)) {
            throw "error: the launch command could not be delivered to $($created.Target)"
        }

        # The success line is bin/fm-spawn.sh's, so a Windows home's spawn output
        # reads the same as a Linux one's in a shared log or transcript.
        $contract = if ($Kind -eq 'ship') { " mode=$Mode yolo=$Yolo" } else { '' }
        [pscustomobject]@{
            TaskId      = $TaskId
            Target      = $created.Target
            Backend     = 'herdr'
            Session     = $container.Session
            WorkspaceId = $container.WorkspaceId
            TabId       = $created.TabId
            PaneId      = $created.PaneId
            Worktree    = $worktree
            LeaseId     = $lease.LeaseId
            Project     = $projectReal
            MetaPath    = $metaPath
            Label       = $label
            Harness     = $Harness
            Kind        = $Kind
            Mode        = $Mode
            Yolo        = $Yolo
            Message     = "spawned $TaskId harness=$Harness kind=$Kind$contract window=$($created.Target) worktree=$worktree"
        }
    } catch {
        # Rollback, most recent first. Every step is best-effort and none of
        # them may mask the original refusal.
        if ($null -ne $created) {
            $null = Remove-FmHerdrPane -Target $created.Target -Confirm:$false -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $metaPath) {
            Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $lease) {
            $null = Remove-FmWorktreeLease -Path $lease.Path -IfLeaseId $lease.LeaseId -Confirm:$false -ErrorAction SilentlyContinue
        }
        throw
    }
}

# Confirm-FmWorkerWorktree: the endpoint's own reading of where it is, checked
# against the leased path. Bounded: a pane reports its foreground cwd as soon
# as its shell is up, but "as soon as" is not "immediately".
#
# This is deliberately a CONFIRMATION, not a discovery. The bash spawn has to
# discover the worktree this way and therefore has to defend against a
# transiently stale first read by requiring two consecutive agreeing reads;
# here the answer is already known from the lease, so a disagreement is not
# ambiguity to resolve - it is a refusal.
#
# WINDOWS: a pane's live `foreground_cwd` is MEASURED to come back EMPTY on the
# Windows herdr preview (data/fmwin-design/report.md section 3.2). An empty
# reading is NO INFORMATION, not evidence the pane is elsewhere, so treating it
# as a refusal would stop every Windows spawn while adding nothing - the copy was
# already proven isolated, and the pane was created IN it rather than told to
# walk into it. The fallback is a real second reading rather than a shrug: the
# pane's own creation `cwd`, which herdr freezes at creation time and which
# therefore still answers "was this pane created where we asked". Only when
# neither field is readable does this report that the check did NOT run - never
# that it passed - and the brief's own isolation assertion remains the worker-side
# backstop for exactly that case.
function Confirm-FmWorkerWorktree {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [int]$Polls = 30,
        [double]$PollSeconds = 0.5
    )
    $wantReal = Resolve-FmPhysicalPathOrRaw -Path $Worktree
    $refusal = "not its leased isolated copy '$Worktree' (primary checkout '$Project'); refusing to launch an " +
        'agent outside the copy holding its work'

    # Poll while the reading disagrees, exactly as the bash spawn does: a pane's
    # shell may report its starting directory for a moment before it settles.
    $seen = ''
    for ($i = 0; $i -lt $Polls; $i++) {
        $seen = Get-FmHerdrCurrentPath -Target $Target
        if ($seen -and (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $seen) -Right $wantReal)) {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($seen) {
        throw "error: the worker's endpoint $Target reports '$seen' as its live foreground path, $refusal"
    }

    $created = Get-FmHerdrPaneCreationPath -Target $Target
    if ($created) {
        if (-not (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $created) -Right $wantReal)) {
            throw "error: the worker's endpoint $Target reports '$created' as its creation path, $refusal"
        }
        Write-Warning ("the endpoint $Target reported no live foreground path within $Polls polls, so the " +
            "live-cwd confirmation did NOT run; it was confirmed against the pane's creation path instead")
        return $true
    }

    Write-Warning ("the endpoint $Target reported neither a live foreground path nor a creation path, so the " +
        "endpoint-side worktree confirmation did NOT run for $Worktree; the lease and the isolation assertion " +
        "stand, and the brief's own isolation assertion is the worker-side backstop")
    $false
}
