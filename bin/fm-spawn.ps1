#requires -Version 7.0
<#
.SYNOPSIS
fm-spawn.ps1 - spawn a direct report: a worker in a leased, isolated worktree
on the herdr session provider.

.DESCRIPTION
Thin entry point over Start-FmWorker. All mechanics live in the module; this
script only resolves the module, forwards arguments, and maps outcomes onto
exit codes (0 success, 1 refusal or failure, 2 usage).

-Mode and -Yolo are this task's delivery contract, REQUIRED for every ship spawn
and refused on scout and secondmate spawns. Firstmate resolves both per task at
intake; data/projects.md holds the captain's standing posture as context, not as
this task's answer, so a spawn never looks the mode up. A ship spawn additionally
reads the brief's recorded "Delivery contract: mode=" line and REFUSES a
mismatch, so the worker's instructions and the recorded task delivery cannot
drift apart.

-Harness names the adapter. Without it, the harness is resolved from config
(config/secondmate-harness -> config/crew-harness -> own for a secondmate;
config/crew-harness for a crewmate, unless config/crew-dispatch.json is active,
which requires an explicit harness so the dispatch rules are never silently
skipped). -Model and -Effort are threaded into the launch only for a harness
whose CLI was verified to accept that axis; an unsupported axis is omitted from
the launch rather than guessed at, and stays recorded in the task's metadata.

-LaunchCommand is the escape hatch for driving an adapter this port has not
verified. Without it, an unverified adapter refuses rather than being launched
with a command line that was never tested against its CLI.

.EXAMPLE
./bin/fm-spawn.ps1 -TaskId my-task -Project C:\repos\thing -BriefPath C:\fm\data\my-task\brief.md -Mode local-only -Yolo off

.EXAMPLE
./bin/fm-spawn.ps1 -TaskId scan-b-q7 -Project C:\repos\thing -BriefPath C:\fm\data\scan-b-q7\brief.md -Kind scout -Harness claude
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$TaskId = '',
    [Parameter(Position = 1)][string]$Project = '',
    [string]$BriefPath = '',
    [string]$Harness = '',
    [string]$LaunchCommand = '',
    [ValidateSet('ship', 'scout', 'secondmate')][string]$Kind = 'ship',
    [string]$Mode = '',
    [string]$Yolo = '',
    [string]$Model = '',
    [string]$Effort = '',
    [string[]]$ProjectList = @(),
    [string]$FirstmateHome = '',
    [string]$LabelHome = '',
    [switch]$SkipBaseRefresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Start-FmWorker'

if (-not $TaskId -or -not $Project) {
    [Console]::Error.WriteLine('usage: fm-spawn.ps1 <task-id> <project-dir> -Mode <no-mistakes|direct-PR|local-only> -Yolo <on|off> [-Harness <name>] [-Model <name>] [-Effort <level>]')
    [Console]::Error.WriteLine('       fm-spawn.ps1 <task-id> <project-dir> -Kind scout [-Harness <name>] [-Model <name>] [-Effort <level>]')
    exit 2
}

# The brief defaults to the one bin/fm-brief.ps1 writes for this task, so the
# common call names the task and the project only. The path comes from the
# foundation's home resolution, not a hand-built join, so this entry point and
# the scaffolder cannot disagree about where a brief lives.
if (-not $BriefPath) {
    $BriefPath = if ($FirstmateHome) {
        Get-FmDataPath -Name @($TaskId, 'brief.md') -HomePath $FirstmateHome
    } else {
        Get-FmDataPath -Name @($TaskId, 'brief.md')
    }
}

try {
    $worker = Start-FmWorker -TaskId $TaskId -Project $Project -BriefPath $BriefPath -Harness $Harness `
        -LaunchCommand $LaunchCommand -Kind $Kind -Mode $Mode -Yolo $Yolo -Model $Model -Effort $Effort `
        -ProjectList $ProjectList -FirstmateHome $FirstmateHome -LabelHome $LabelHome `
        -SkipBaseRefresh:$SkipBaseRefresh
    if ($null -eq $worker) { exit 0 }
    [Console]::Out.Write("$($worker.Message)`n")
    exit 0
} catch {
    # Straight to stderr, not Write-Error: an entry point's refusal is a
    # message for a human or a calling script, not a PowerShell error record
    # with source-line decoration wrapped around it.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
