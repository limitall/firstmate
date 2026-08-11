#requires -Version 7.0
<#
.SYNOPSIS
fm-control.ps1 - the CONTROL PLANE for a firstmate-owned agent: allowlisted
lifecycle verbs addressed to an exact task id.

.DESCRIPTION
Thin entry point over the control-plane verbs.

  interrupt  Deliver the harness's verified interrupt sequence. The agent keeps
             running. Postcondition: delivery succeeded, the endpoint still
             exists, and the agent is still alive. Cancellation itself is
             reported unconfirmed - it is never claimed without an
             adapter-owned acknowledgement.
  exit       Stop the agent, preserving its endpoint, worktree and every
             uncommitted change. Interrupts first when the task reads busy,
             then submits the harness's exit command. Postcondition: the
             backend's recovery-grade classifier reports the agent gone.
             Already-stopped is success.

Why this is separate from fm-send.ps1: fm-send is the DATA plane, text for the
agent to READ. A lifecycle command sent that way arrives as chat the agent
reasons ABOUT instead of executing. There is deliberately no arbitrary-text and
no generic raw-key entry point here.

Teardown and discard are NOT verbs here and never will be: `exit` stops an
agent and preserves everything else.

`relaunch` is not implemented on this port and is refused by name rather than
half-performed - see the refusal message for the two steps that replace it.

Exit codes: 0 success, 1 refusal or failure, 2 usage.

.EXAMPLE
./bin/fm-control.ps1 my-task exit
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [Parameter(Position = 1)][string]$Verb = '',
    [string]$FirstmateHome = '',
    [switch]$ClosePane,
    [switch]$ReleaseWorktree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module resolution. The manifest is the real entry point; the dot-source
# fallback exists so these scripts run before the module loader lands and is
# harmless once it has.
$fmManifest = Join-Path $PSScriptRoot '../module/Firstmate/Firstmate.psd1'
if (Test-Path -LiteralPath $fmManifest) {
    Import-Module $fmManifest -Force
} else {
    $fmModule = Join-Path $PSScriptRoot '../module/Firstmate'
    foreach ($fmFile in @(Get-ChildItem -Path (Join-Path $fmModule 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -Path (Join-Path $fmModule 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        . $fmFile.FullName
    }
}

if (-not $TaskId -or -not $Verb) {
    [Console]::Error.WriteLine('usage: fm-control.ps1 <task-id> <interrupt|exit>')
    exit 2
}

if ($Verb -eq 'relaunch') {
    [Console]::Error.WriteLine(("error: 'relaunch' is not implemented on this port. It is a durable transaction (checkpoint, staged " +
        "rollback, replacement launch) and a partial one is worse than none. Run './bin/fm-control.ps1 <id> exit', " +
        "then spawn a replacement with './bin/fm-spawn.ps1' once its brief carries the progress note."))
    exit 2
}

# The verb allowlist is closed and stated here, in the entry point, because the
# module's capability tables are internal: an entry point that could not name
# its own verbs would have to reach into module internals to refuse one.
$fmControlVerbs = @('interrupt', 'exit')
if ($Verb -notin $fmControlVerbs) {
    [Console]::Error.WriteLine(("error: '$Verb' is not a control verb; allowed verbs: " + ($fmControlVerbs -join ', ')))
    exit 2
}

try {
    switch ($Verb) {
        'exit' {
            $result = Stop-FmWorker -TaskId $TaskId -FirstmateHome $FirstmateHome `
                -ClosePane:$ClosePane -ReleaseWorktree:$ReleaseWorktree
            if ($null -ne $result) { $result | Format-List | Out-String | Write-Output }
        }
        'interrupt' {
            $result = Stop-FmWorker -TaskId $TaskId -FirstmateHome $FirstmateHome -Interrupt
            if ($null -ne $result) { $result | Format-List | Out-String | Write-Output }
        }
    }
    exit 0
} catch {
    # Straight to stderr, not Write-Error: an entry point's refusal is a
    # message for a human or a calling script, not a PowerShell error record
    # with source-line decoration wrapped around it.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
