#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Promote a scout task to a ship task in place.

.DESCRIPTION
The PowerShell port of bin/fm-promote.sh.

The crewmate keeps its window, worktree, and loaded context; only the contract
changes. kind= is flipped to ship in state/<task-id>.meta so teardown applies
the full ship-task protection again.

A scout records no delivery posture, so promotion is where this task's delivery
contract is decided: -Mode and -Yolo are REQUIRED and written into the meta
alongside the kind= flip. Firstmate resolves both at promotion time, having just
read the scout's report; data/projects.md holds the captain's standing posture
as context, and this command never looks it up. no-mistakes-prod-only is a
registry policy rather than a task mode and is refused by name.

After promoting, send the crewmate its ship instructions - the returned
NextStep line is that command, and it carries the requirement that the promoted
worker inventories its scratch state, returns to a clean default-branch base,
and leaves its scratch commits behind, carrying over only the changes it
intends to ship.

.PARAMETER TaskId
The scout task being promoted.

.PARAMETER Mode
This task's delivery mode. Required - it is a decision, not a lookup.

.PARAMETER Yolo
This task's routine approval authority. Required, for the same reason.

.PARAMETER StateDir
Override the state directory. Defaults to this home's.

.EXAMPLE
Invoke-FmPromote -TaskId my-scout -Mode local-only -Yolo off
#>
function Invoke-FmPromote {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Yolo,
        [string]$StateDir = '',
        [string]$FirstmateHome = ''
    )

    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw 'error: invalid task id'
    }
    if ($Mode -eq 'no-mistakes-prod-only') {
        throw ('error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task''s ' +
            'surface and resolve it to no-mistakes or direct-PR')
    }
    # Mode validity first, then whether this port can deliver it: "unknown mode"
    # and "real mode this port cannot run" are different problems.
    $null = Assert-FmDeliveryModeSupported -Mode $Mode
    if ($Yolo -ne 'on' -and $Yolo -ne 'off') {
        throw "error: -Yolo must be on or off (got '$Yolo')"
    }

    if (-not $FirstmateHome) { $FirstmateHome = (Get-FmSessionPaths).Home }
    if (-not $StateDir) { $StateDir = (Get-FmSessionPaths).State }
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
        throw "error: state dir not found: $StateDir"
    }

    # The control lock first, so two lifecycle actions cannot run against one
    # task, then the meta lock around the read-modify-write itself. Both are the
    # foundation's locks (Request-FmLock / Unlock-FmLock); this area no longer
    # carries its own, and Get-FmMetaLockPath owns the meta-lock path.
    #
    # Request-, not Wait-: a second lifecycle action against one task must be
    # REFUSED with the bash's message, not silently queued behind the first.
    $metaPath = Get-FmMetaPath -StateDir $StateDir -TaskId $TaskId
    $controlLockPath = Get-FmDeliveryControlLockPath -StateDir $StateDir -TaskId $TaskId
    $control = $null
    try {
        $control = Request-FmLock -Path $controlLockPath -Role 'promote'
    } catch {
        # The owner refuses re-entry by throwing rather than returning $null: a
        # lock is per PROCESS, so taking it twice would deadlock. For this
        # command that IS the refusal - another lifecycle action holds the task,
        # it just happens to be in this process - so it is reported in this
        # command's own words. Anything else is a real failure and is rethrown
        # unchanged, because "already running" must never stand in for "the
        # state directory is unwritable".
        if ($_.Exception.Message -notlike '*already holds the lock*') { throw }
    }
    if (-not $control) {
        throw "error: another lifecycle action is already running for task $TaskId; nothing was changed"
    }

    $metaLock = $null
    try {
        $null = Invoke-FmDeliveryGuard

        $metaLock = Request-FmLock -Path (Get-FmMetaLockPath -MetaPath $metaPath) -Role 'promote'
        if (-not $metaLock) {
            throw "error: task $TaskId`'s record is locked by another writer; nothing was changed"
        }

        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            throw "error: no meta for task $TaskId at $metaPath"
        }
        # Exactly the bash `grep -qx 'kind=scout'` test: a whole line, not a
        # prefix, so kind=scout-ish never promotes.
        $isScout = @(Get-FmSessionFileLines -Path $metaPath | Where-Object { $_ -eq 'kind=scout' }).Count -gt 0
        if (-not $isScout) {
            throw "error: task $TaskId is not a scout task (kind=scout not in meta)"
        }

        if (-not $PSCmdlet.ShouldProcess("task $TaskId", "promote to ship mode=$Mode yolo=$Yolo")) { return $null }
        $null = Set-FmTaskPromotionMeta -MetaPath $metaPath -Mode $Mode -Yolo $Yolo
    } finally {
        # Released whatever happened, including a throw from the checks above:
        # a refused promotion must never leave the task locked.
        if ($metaLock) { $null = Unlock-FmLock -Lock $metaLock -Confirm:$false }
        $null = Unlock-FmLock -Lock $control -Confirm:$false
    }

    [pscustomobject]@{
        Promoted = $true
        TaskId   = $TaskId
        Kind     = 'ship'
        Mode     = $Mode
        Yolo     = $Yolo
        Message  = "promoted $TaskId to ship mode=$Mode yolo=$Yolo (teardown protection restored)"
        NextStep = Get-FmPromotionNextStep -TaskId $TaskId -Mode $Mode -FirstmateHome $FirstmateHome
    }
}
