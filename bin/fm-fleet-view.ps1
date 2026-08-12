# bin/fm-fleet-view.ps1 - human renderer over bin/fm-fleet-snapshot.
#
# Twin: bin/fm-fleet-view.sh
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot --json and renders that stable
# structured contract for humans.
#
# Usage: fm-fleet-view.ps1 [--json]
#
# ---------------------------------------------------------------------------
# WHY THE CHILD IS NOT CALLED BY EXTENSION
#
# Invoke-FmScript resolves `fm-fleet-snapshot` to its PowerShell twin when one
# exists and to the bash twin otherwise, so this renderer works from either side
# of the conversion and needs no edit at cutover (docs/powershell-port.md
# contract 7). `--json` streams the child straight through, exit code included.
#
# ---------------------------------------------------------------------------
# ONE DECLARED DIVERGENCE
#
#   jq. The bash refuses with "fm-fleet-view: jq not found" (exit 1) when jq is
#   absent, because its rendering IS a jq program. This twin renders in-process
#   and has no jq dependency, so it has no such refusal. Every rendered line and
#   every other exit code is identical.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

# No param() block - see bin/fm-operational-input.ps1's header for why.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {

    $usageText = (@'
usage: fm-fleet-view.sh [--json]

Render a human fleet view from fm-fleet-snapshot.sh.
Use --json to print the underlying snapshot.

'@) -replace "`r`n", "`n"

    $firstArg = if ($fmArgv.Count -ge 1) { [string]$fmArgv[0] } else { '' }
    if ($firstArg -ceq '-h' -or $firstArg -ceq '--help') {
        Write-FmRaw $usageText
        Exit-FmScript 0
    }
    if ($firstArg -ceq '--json') {
        $passthrough = Invoke-FmScript -Name 'fm-fleet-snapshot' -Arguments @('--json') `
            -BinDir $PSScriptRoot -Stream
        Exit-FmScript $passthrough.ExitCode
    }
    if ($firstArg -cne '') {
        [Console]::Error.Write($usageText)
        Exit-FmScript 2
    }

    $child = Invoke-FmScript -Name 'fm-fleet-snapshot' -Arguments @('--json') -BinDir $PSScriptRoot
    if (-not $child.Ok) {
        # `SNAPSHOT=$(...) || exit $?`: the child already reported why on its own
        # stderr, which Invoke-FmTool captured, so it is relayed rather than
        # swallowed - and the child's exit code is preserved.
        [Console]::Error.Write($child.StdErr)
        Exit-FmScript $child.ExitCode
    }

    $snapshot = ConvertFrom-Json $child.StdOut -AsHashtable

    # --- the jq render program, function for function --------------------------

    function Get-JField {
        param($Obj, [string]$Key)
        if ($null -eq $Obj) { return $null }
        if ($Obj -is [System.Collections.IDictionary]) {
            # Unary comma again: a stored value that is itself a COLLECTION would
            # be unrolled on the way out, so an empty array field would come back
            # as $null and the caller's next .Add() would fail. The comma is
            # transparent for scalars.
            if ($Obj.Contains($Key)) { return , $Obj[$Key] }
            return $null
        }
        return $null
    }
    function Get-JPath {
        param($Obj, [string[]]$Keys)
        $cur = $Obj
        foreach ($k in $Keys) {
            $cur = Get-JField $cur $k
            if ($null -eq $cur) { return $null }
        }
        return , $cur
    }
    function Get-JList {
        param($Value)
        if ($null -eq $Value) { return , @() }
        if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return , $Value }
        return , @($Value)
    }

    # `def dash($v): if $v == null or $v == "" then "-" else $v end;`
    function Get-Dash {
        param($Value)
        if ($null -eq $Value -or ([string]$Value) -eq '') { return '-' }
        return [string]$Value
    }

    function Get-EndpointPresence {
        param($Task)
        $e = Get-JPath $Task @('endpoint', 'exists')
        if ($null -eq $e) { return 'unknown' }
        if ($e -eq $true) { return 'present' }
        return 'absent'
    }
    function Get-EndpointOf {
        param($Task)
        if ((Get-JField $Task 'kind') -ceq 'secondmate') {
            return ((Get-EndpointPresence $Task) + ' / ' + [string](Get-JPath $Task @('endpoint', 'agent_alive')))
        }
        return (Get-EndpointPresence $Task)
    }
    function Get-Artifact {
        param($Task)
        $url = Get-JPath $Task @('pr', 'url')
        if ($null -ne $url) { return [string]$url }
        if ((Get-JPath $Task @('paths', 'report', 'present')) -eq $true) {
            return [string](Get-JPath $Task @('paths', 'report', 'path'))
        }
        return '-'
    }
    function Get-PathOf {
        param($Task)
        if ((Get-JPath $Task @('paths', 'home', 'present')) -eq $true) {
            return [string](Get-JPath $Task @('paths', 'home', 'path'))
        }
        if ($null -ne (Get-JPath $Task @('paths', 'home', 'path'))) {
            return ([string](Get-JPath $Task @('paths', 'home', 'path')) + ' (absent)')
        }
        if ((Get-JPath $Task @('paths', 'worktree', 'present')) -eq $true) {
            return [string](Get-JPath $Task @('paths', 'worktree', 'path'))
        }
        if ($null -ne (Get-JPath $Task @('paths', 'worktree', 'path'))) {
            return ([string](Get-JPath $Task @('paths', 'worktree', 'path')) + ' (absent)')
        }
        return '-'
    }
    function Get-ActionOf {
        param($Task)
        if ((Get-JField $Task 'kind') -ceq 'secondmate') {
            return ([string](Get-JPath $Task @('actions', 'send')) + ' - ' +
                [string](Get-JPath $Task @('actions', 'watch')))
        }
        return [string](Get-JPath $Task @('actions', 'watch'))
    }
    function Get-TaskRow {
        param($Task)
        # `.backlog.repo // $t.project` - the merged backlog row's repo wins, and
        # `//` falls through only on null, never on an empty string.
        $repo = Get-JPath $Task @('backlog', 'repo')
        if ($null -eq $repo) { $repo = Get-JField $Task 'project' }
        return ('| ' + [string](Get-JField $Task 'id') +
            ' | ' + [string](Get-JPath $Task @('current_state', 'state')) +
            ' / ' + [string](Get-JPath $Task @('current_state', 'source')) +
            ' | ' + [string](Get-JField $Task 'kind') +
            ' | ' + (Get-Dash $repo) +
            ' | ' + [string](Get-JField $Task 'backend') +
            ' | ' + (Get-EndpointOf $Task) +
            ' | ' + (Get-Artifact $Task) +
            ' | ' + (Get-PathOf $Task) +
            ' | ' + (Get-ActionOf $Task) + ' |')
    }
    function Get-Blocker {
        param($Record)
        $by = Get-JField $Record 'blocked_by'
        if ($null -eq $by -or [string]$by -eq '') { return '-' }
        $reason = Get-JField $Record 'blocked_reason'
        if ($null -eq $reason -or [string]$reason -eq '') { return [string]$by }
        return ([string]$by + ' - ' + [string]$reason)
    }
    function Get-BacklogRow {
        param($Record)
        $id = Get-JField $Record 'id'
        if ($null -eq $id) { $id = '-' }
        $title = Get-JField $Record 'title'
        if ($null -eq $title) { $title = Get-JField $Record 'raw' }
        $artifact = Get-JField $Record 'pr_url'
        if ($null -eq $artifact) { $artifact = Get-JField $Record 'report_path' }
        if ($null -eq $artifact) { $artifact = Get-JField $Record 'local_note' }
        return ('| ' + [string]$id +
            ' | ' + (Get-Dash $title) +
            ' | ' + (Get-Dash (Get-JField $Record 'repo')) +
            ' | ' + (Get-Dash (Get-JField $Record 'kind')) +
            ' | ' + (Get-Blocker $Record) +
            ' | ' + (Get-Dash $artifact) + ' |')
    }

    $tasks = Get-JList (Get-JField $snapshot 'tasks')
    $records = Get-JList (Get-JPath $snapshot @('backlog', 'records'))

    Write-FmOut '# Fleet View'
    Write-FmOut ''
    Write-FmOut ('Schema: ' + [string](Get-JField $snapshot 'schema'))
    Write-FmOut ('Home: ' + [string](Get-JField $snapshot 'fm_home'))
    Write-FmOut ''
    Write-FmOut '## Under Way'
    if ($tasks.Count -eq 0) {
        Write-FmOut 'No live task metadata found.'
    } else {
        Write-FmOut '| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |'
        Write-FmOut '| --- | --- | --- | --- | --- | --- | --- | --- | --- |'
        foreach ($t in $tasks) { Write-FmOut (Get-TaskRow $t) }
    }
    Write-FmOut ''
    Write-FmOut '## Queued'
    $queued = @($records | Where-Object { (Get-JField $_ 'state') -ceq 'queued' })
    if ($queued.Count -eq 0) {
        Write-FmOut 'No queued backlog records found.'
    } else {
        Write-FmOut '| ID | Title | Repo | Kind | Blocked By | Artifact |'
        Write-FmOut '| --- | --- | --- | --- | --- | --- |'
        foreach ($r in $queued) { Write-FmOut (Get-BacklogRow $r) }
    }
    Write-FmOut ''
    Write-FmOut '## Done'
    $done = @($records | Where-Object { (Get-JField $_ 'state') -ceq 'done' })
    if ($done.Count -eq 0) {
        Write-FmOut 'No done backlog records found.'
    } else {
        Write-FmOut '| ID | Title | Repo | Kind | Blocked By | Artifact |'
        Write-FmOut '| --- | --- | --- | --- | --- | --- |'
        foreach ($r in $done) { Write-FmOut (Get-BacklogRow $r) }
    }
    Write-FmOut ''
    Write-FmOut '## Secondmates'
    Write-FmOut ([string](Get-JPath $snapshot @('secondmate_guidance', 'note')))
    Exit-FmScript 0
}
