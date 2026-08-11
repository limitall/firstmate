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

WHAT IS NOT PORTED HERE (each belongs to another area of the port, and each
would be a guess if invented here; see docs/spawn-windows.md):
  - harness launch-command templates, trust-dialog handling, and the per-
    harness turn-end hook and busy-state wiring. Pass -LaunchCommand, or load
    a module that provides Get-FmHarnessLaunchCommand and it will be used.
  - relaunch, secondmate provisioning, remote placement, dispatch profiles,
    trace-context propagation, and the herdr presentation projection.

.EXAMPLE
Start-FmWorker -TaskId my-task -Project C:\repos\thing -BriefPath C:\fm\data\my-task\brief.md -Harness claude -LaunchCommand 'claude'
#>
function Start-FmWorker {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter(Mandatory)][string]$Harness,
        [string]$LaunchCommand = '',
        [ValidateSet('ship', 'scout', 'secondmate')][string]$Kind = 'ship',
        [string]$Mode = '',
        [string]$Yolo = '',
        [string]$Model = '',
        [string]$Effort = '',
        [string]$FirstmateHome = '',
        [ValidateSet('herdr')][string]$Backend = 'herdr',
        [switch]$SkipBaseRefresh
    )

    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id (allowed: A-Z a-z 0-9 . _ -, not starting with '.')"
    }
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

    $stateDir = Join-Path $FirstmateHome 'state'
    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $stateDir -Force
    }
    $metaPath = Get-FmMetaPath -StateDir $stateDir -TaskId $TaskId
    if (Test-Path -LiteralPath $metaPath) {
        throw "error: task $TaskId already has a durable record at $metaPath; refusing a duplicate launch"
    }

    if (-not $LaunchCommand) {
        $resolver = Get-Command -Name Get-FmHarnessLaunchCommand -ErrorAction SilentlyContinue
        if ($resolver) {
            $LaunchCommand = [string](& $resolver -Harness $Harness -BriefPath $BriefPath -Model $Model -Effort $Effort)
        }
    }
    if (-not $LaunchCommand) {
        throw "error: no launch command for harness '$Harness'; pass -LaunchCommand, because this port never guesses how to start an agent"
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
        $container = New-FmHerdrContainer -Cwd $projectReal `
            -Relationship $(if ($Kind -eq 'secondmate') { 'other-home' } else { 'launcher-home' }) -Confirm:$false

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

        # 6. Publish the durable record. Field set and ORDER follow
        #    bin/fm-spawn.sh exactly; `backend=` is written only because this
        #    is a non-default backend, and the four herdr_* fields are what the
        #    shared endpoint validation binds against.
        $fields = [ordered]@{
            window           = $created.Target
            endpoint_task_id = $TaskId
            worktree         = $worktree
            project          = $projectReal
            harness          = $Harness
            kind             = $Kind
        }
        if ($Mode) { $fields['mode'] = $Mode }
        if ($Yolo) { $fields['yolo'] = $Yolo }
        $fields['tasktmp'] = $taskTmp
        $fields['model'] = $(if ($Model) { $Model } else { 'default' })
        $fields['effort'] = $(if ($Effort) { $Effort } else { 'default' })
        $fields['backend'] = 'herdr'
        $fields['herdr_session'] = $container.Session
        $fields['herdr_workspace_id'] = $container.WorkspaceId
        $fields['herdr_tab_id'] = $created.TabId
        $fields['herdr_pane_id'] = $created.PaneId
        if ($lease.LeaseId) { $fields['treehouse_lease_id'] = $lease.LeaseId }

        Write-FmTaskMeta -Path $metaPath -Fields $fields

        # 7. Hand the worker its brief. `pane run` types and submits in one
        #    call, so there is no unsubmitted-launch state to recover from.
        if (-not (Send-FmHerdrTextLine -Target $created.Target -Text $LaunchCommand)) {
            throw "error: the launch command could not be delivered to $($created.Target)"
        }

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
function Confirm-FmWorkerWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [int]$Polls = 30,
        [double]$PollSeconds = 0.5
    )
    $wantReal = Resolve-FmPhysicalPathOrRaw -Path $Worktree
    $seen = ''
    for ($i = 0; $i -lt $Polls; $i++) {
        $seen = Get-FmHerdrCurrentPath -Target $Target
        if ($seen -and (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $seen) -Right $wantReal)) {
            return $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $shown = if ($seen) { $seen } else { 'unknown' }
    throw ("error: the worker's endpoint $Target reports '$shown', not its leased isolated copy '$Worktree' " +
        "(primary checkout '$Project'); refusing to launch an agent outside the copy holding its work")
}

# Write-FmTaskMeta: publish state/<id>.meta atomically and with LF endings.
# Atomic because a half-written record is a task that claims an endpoint it may
# not have; LF because the record is a shared file contract with a Linux
# firstmate, and Windows PowerShell would otherwise write CRLF.
function Write-FmTaskMeta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields
    )
    $sb = [System.Text.StringBuilder]::new()
    foreach ($key in $Fields.Keys) {
        $null = $sb.Append([string]$key).Append('=').Append([string]$Fields[$key]).Append("`n")
    }
    $tmp = "$Path.tmp.$PID"
    Write-FmTextFileLf -Path $tmp -Text $sb.ToString()
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
