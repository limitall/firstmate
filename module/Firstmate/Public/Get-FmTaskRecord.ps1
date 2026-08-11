#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
Read and write a task's durable record, state/<id>.meta.

.DESCRIPTION
The record is what every later lifecycle command binds against - peek, steer,
relaunch, teardown - so it is the one place a task's identity lives after the
spawn returns. Its field set and ORDER are bin/fm-spawn.sh's, byte for byte,
because a Linux firstmate reads the same file (ConvertTo-FmTaskRecordField in
Private/FmDispatch.ps1 owns that order).

The bytes are the foundation's business, not this file's: Read-FmKeyValueFile
splits on the first '=' only, keeps a duplicated key's LAST value at its FIRST
position, and matches names case-sensitively the way `grep '^home='` does;
Write-FmKeyValueFile publishes atomically, LF-only and BOM-free. This surface
adds only the named properties every consumer of a TASK record expects.

.EXAMPLE
$record = Get-FmTaskRecord -Path (Get-FmTaskStatePath -Id 'my-task' -Extension 'meta')
$record.Worktree
#>
function Get-FmTaskRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $fields = Read-FmKeyValueFile -Path $Path
    $get = { param($key) if ($fields.Contains($key)) { [string]$fields[$key] } else { '' } }

    [pscustomobject]@{
        Path             = $Path
        Field            = $fields
        Window           = & $get 'window'
        EndpointTaskId   = & $get 'endpoint_task_id'
        Worktree         = & $get 'worktree'
        Project          = & $get 'project'
        Harness          = & $get 'harness'
        Kind             = & $get 'kind'
        Mode             = & $get 'mode'
        Yolo             = & $get 'yolo'
        TaskTmp          = & $get 'tasktmp'
        Model            = & $get 'model'
        Effort           = & $get 'effort'
        BusyGeneration   = & $get 'busy_gen'
        # Absent backend= MEANS tmux - the bash compatibility contract, whose
        # owner is Get-FmMetaBackend.
        Backend          = Get-FmMetaBackend -Path $Path
        HerdrSession     = & $get 'herdr_session'
        HerdrWorkspaceId = & $get 'herdr_workspace_id'
        HerdrTabId       = & $get 'herdr_tab_id'
        HerdrPaneId      = & $get 'herdr_pane_id'
        Home             = & $get 'home'
        ProjectList      = & $get 'projects'
        LeaseId          = & $get 'treehouse_lease_id'
        Traceparent      = & $get 'traceparent'
    }
}

<#
.SYNOPSIS
Publish state/<id>.meta atomically, LF-only and without a BOM.

.DESCRIPTION
Atomic because a half-written record is a task that claims an endpoint it may not
have, and every recovery path reads this file before it reads anything else. A
record with more than one writer must be updated inside Invoke-FmWithLock on
Get-FmMetaLockPath; a fresh spawn is the single-writer case and publishes
directly.
#>
function Write-FmTaskRecord {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'publish the task record')) { return }
    Write-FmKeyValueFile -Path $Path -Fields $Fields -Confirm:$false
}
