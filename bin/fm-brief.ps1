#requires -Version 7.0
<#
Scaffold a crewmate brief or persistent secondmate charter at
data/<task-id>/brief.md under the active firstmate home.

Usage: fm-brief.ps1 <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only> [--herdr-lab]
       fm-brief.ps1 <task-id> <repo-name> --scout [--herdr-lab]
       fm-brief.ps1 <task-id> --secondmate {<project>...|--no-projects}

The flag spelling matches bin/fm-brief.sh so the documented command works
unchanged; New-FmBrief is the PowerShell-native entry point.
  --scout       writes the scout contract: the deliverable is a report at
                data/<task-id>/report.md (no branch, no push, no PR).
  --secondmate  writes a persistent secondmate charter. --no-projects writes a
                project-less charter and is mutually exclusive with a project
                list; omitting both fails loudly.
                FM_SECONDMATE_CHARTER / FM_SECONDMATE_SCOPE fill the text.
  --herdr-lab   MANDATORY when the task will issue Herdr lifecycle commands.
                It must be explicit because {TASK} is filled in after
                scaffolding, so a brief without it carries a loud declaration
                rather than a silently missing isolation contract.
  --mode        REQUIRED for ship tasks and refused for scout and secondmate
                scaffolds: a scout delivers a report and a charter is not a
                delivery contract.

There is no --yolo: the worker never owns approval decisions, so yolo is a
spawn-time and firstmate-side input only.
Refuses to overwrite an existing brief.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'module' 'Firstmate' 'Firstmate.psd1') -Force

if ($args.Count -ge 1 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
    Get-Help -Full $PSCommandPath
    exit 0
}

$positional = [System.Collections.Generic.List[string]]::new()
$briefArgs = @{}
$wantValue = ''
foreach ($a in $args) {
    if ($wantValue) {
        if ("$a".StartsWith('--')) {
            [Console]::Error.WriteLine("error: --$wantValue requires a value")
            exit 1
        }
        $briefArgs[$wantValue] = "$a"
        $wantValue = ''
        continue
    }
    switch -Regex ("$a") {
        '^--scout$' { $briefArgs['Scout'] = $true }
        '^--secondmate$' { $briefArgs['Secondmate'] = $true }
        '^--herdr-lab$' { $briefArgs['HerdrLab'] = $true }
        '^--no-projects$' { $briefArgs['NoProjects'] = $true }
        '^--mode$' { $wantValue = 'Mode' }
        '^--mode=' { $briefArgs['Mode'] = "$a".Substring('--mode='.Length) }
        # yolo never reaches the worker: it is firstmate's approval authority,
        # not a brief input. Refuse it loudly so it is never silently dropped
        # here and then believed to have been recorded.
        '^--yolo' {
            [Console]::Error.WriteLine('error: --yolo is not a brief input; pass it to the spawn path, which records the task''s approval posture')
            exit 1
        }
        default { $positional.Add("$a") }
    }
}
if ($wantValue) {
    [Console]::Error.WriteLine("error: --$wantValue requires a value")
    exit 1
}
if ($positional.Count -lt 1) {
    [Console]::Error.WriteLine('usage: fm-brief.ps1 <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only>')
    exit 1
}

$briefArgs['Id'] = $positional[0]
if ($briefArgs.ContainsKey('Secondmate')) {
    if ($briefArgs.ContainsKey('HerdrLab')) {
        [Console]::Error.WriteLine('error: --herdr-lab applies only to crewmate ship or scout briefs')
        exit 1
    }
    if ($briefArgs.ContainsKey('Mode')) {
        [Console]::Error.WriteLine('error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract')
        exit 1
    }
    if ($positional.Count -gt 1) { $briefArgs['Project'] = @($positional[1..($positional.Count - 1)]) }
} else {
    if ($briefArgs.ContainsKey('NoProjects')) {
        [Console]::Error.WriteLine('error: --no-projects applies only to --secondmate charters')
        exit 1
    }
    if ($briefArgs.ContainsKey('Scout') -and $briefArgs.ContainsKey('Mode')) {
        [Console]::Error.WriteLine('error: --mode applies only to ship briefs; a scout delivers a report and a secondmate charter is not a delivery contract')
        exit 1
    }
    if (-not $briefArgs.ContainsKey('Scout') -and -not $briefArgs.ContainsKey('Mode')) {
        [Console]::Error.WriteLine('error: ship briefs require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain''s instruction and the project''s registered posture in data/projects.md')
        exit 1
    }
    if ($positional.Count -lt 2) {
        [Console]::Error.WriteLine('usage: fm-brief.ps1 <task-id> <repo-name> --mode <no-mistakes|direct-PR|local-only>')
        exit 1
    }
    $briefArgs['Repo'] = $positional[1]
}

$result = New-FmBrief @briefArgs
exit $result.ExitCode
