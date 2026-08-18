#requires -Version 7.0
<#
    FmRunLiveness (private) - "is anything actually running for this task?"

    WHY THIS EXISTS. A crewmate waiting on a background run looks, from outside,
    exactly like a crewmate waiting on one that has already ended: live endpoint,
    quiet pane, an ordinary non-terminal `working:` as its last status line. The
    supervisor used to close that gap with an ad-hoc process count, and
    docs/finished-run-stall.md records what that cost - NINE times in one evening
    it declared a genuinely-running suite finished, by 7 to 54 minutes, and the
    resulting "your run has finished" steer made workers abandon correct runs and
    start again. The completion notice itself was never the defect; it was
    measured being delivered to an idle session in under 35 ms.

    So this is the reading that replaces the guess, and its whole value is being
    RIGHT about the negative.

    THE ONE MEASUREMENT THIS AREA RESTS ON, taken on the captain's Windows 11
    laptop against Claude Code and recorded in docs/windows-e2e-evidence.md:
    a crewmate agent process with nothing running has ZERO live descendants.
    The Bash and PowerShell tool shells are created PER CALL and exit with it -
    they are not long-lived session shells - so "the agent has descendants" and
    "the worker is running something" are the same statement. That is what makes
    a structural rule possible here instead of an ignore-list of program names.

    THE VERDICT IS TRI-STATE AND FAILS TOWARDS "RUNNING". `none` is only ever
    returned after a process table was READ SUCCESSFULLY and found to hold
    nothing; every failure - no metadata, no process table, no agent process,
    the probe disabled - is `unknown`. A caller must never read `unknown` as
    "nothing is running", because the dangerous direction here is telling a
    worker its run is over while the run is still going.

    Public surface and the whole decision procedure: Public/FmRunLiveness.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FmRunLivenessSettings {
    <# The one tunable this area has. There is deliberately no "confirm the
       reading N times" knob: the watcher already requires two consecutive
       identical pane hashes before it classifies anything as stale, and a second
       settling rule here would be a second answer to a question that already has
       an owner. #>
    [OutputType([hashtable])]
    [CmdletBinding()]
    param()
    return @{
        # 1 turns the probe off entirely: every verdict becomes `unknown`, which
        # every caller already treats as "no information".
        Disabled = ($env:FM_RUN_LIVENESS_DISABLE -eq '1')
    }
}

function Get-FmRunLivenessProcessTable {
    <#
        Every live process as {ProcessId, ParentProcessId, Name, ExecutablePath,
        CommandLine}, or $null when the table could not be read.

        $null and @() are DIFFERENT answers and the difference is the whole
        safety property: @() means "the box has no processes", which cannot
        happen, so only $null is ever produced for a failed read.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param()

    if ($IsWindows) {
        # WINDOWS-UNVERIFIED: nothing here is; Win32_Process is the only portable
        # command-line and parent-pid source on Windows and this port has no
        # other way to enumerate. The shapes below were read from a real table on
        # the captain's laptop (docs/windows-e2e-evidence.md).
        try {
            $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        } catch {
            return $null
        }
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            try {
                $out.Add([pscustomobject]@{
                        ProcessId       = [int]$row.ProcessId
                        ParentProcessId = [int]$row.ParentProcessId
                        Name            = [string]$row.Name
                        ExecutablePath  = [string]$row.ExecutablePath
                        CommandLine     = [string]$row.CommandLine
                    })
            } catch {
                continue
            }
        }
        return $out.ToArray()
    }

    # Linux development path only - the product runs on Windows. Reads /proc
    # through .NET rather than shelling out to ps, which this repo forbids.
    if (-not (Test-Path -LiteralPath '/proc' -PathType Container)) { return $null }
    try {
        $dirs = @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^[0-9]+$' })
    } catch {
        return $null
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $dirs) {
        $id = [int]$dir.Name
        $parent = 0
        $name = ''
        try {
            $stat = [System.IO.File]::ReadAllText((Join-Path $dir.FullName 'stat'))
            # comm is parenthesised and may itself contain spaces and ')', so the
            # fields after it are located from the LAST ')' rather than by split.
            $close = $stat.LastIndexOf(')')
            if ($close -gt 0) {
                $name = $stat.Substring($stat.IndexOf('(') + 1, $close - $stat.IndexOf('(') - 1)
                $rest = ($stat.Substring($close + 1)).Trim() -split '\s+'
                if ($rest.Count -ge 2) { $parent = [int]$rest[1] }
            }
        } catch {
            continue
        }
        $cmdline = ''
        try {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir.FullName 'cmdline'))
            if ($bytes.Length -gt 0) {
                $cmdline = ([System.Text.Encoding]::UTF8.GetString($bytes)).TrimEnd([char]0) -replace "`0", ' '
            }
        } catch {
            $cmdline = ''
        }
        $exe = ''
        try { $exe = [string](Get-Item -LiteralPath (Join-Path $dir.FullName 'exe') -Force -ErrorAction Stop).Target } catch { $exe = '' }
        $out.Add([pscustomobject]@{
                ProcessId       = $id
                ParentProcessId = $parent
                Name            = $name
                ExecutablePath  = $exe
                CommandLine     = $cmdline
            })
    }
    if ($out.Count -eq 0) { return $null }
    return $out.ToArray()
}

function Test-FmRunLivenessNamesPath {
    <#
        Does this text name $Directory - the directory itself or anything under
        it? Compares both separator spellings because a Windows path reaches a
        command line as `C:\a\b` from PowerShell and as `C:/a/b` from the Bash
        tool, and matching only one of them silently halves the discovery.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Directory
    )
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Directory)) { return $false }
    $trimmed = $Directory -replace '[\\/]+$', ''
    if (-not $trimmed) { return $false }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($spelling in @(($trimmed -replace '/', '\'), ($trimmed -replace '\\', '/'))) {
        if ($Text.IndexOf($spelling, $comparison) -ge 0) { return $true }
    }
    return $false
}

function Get-FmRunLivenessDescendantId {
    <#
        Every process id reachable from $RootId by parent links, $RootId
        excluded. Iterative rather than recursive so a pid-reuse cycle - a
        recycled pid whose recorded parent is now its own descendant - cannot
        make this run forever.

        Pid reuse can only ADD an unrelated process here, never drop a real one,
        and adding reads as "something is running", which is the safe direction.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$RootId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Table
    )
    $byParent = @{}
    foreach ($row in $Table) {
        $key = [int]$row.ParentProcessId
        if (-not $byParent.ContainsKey($key)) { $byParent[$key] = [System.Collections.Generic.List[object]]::new() }
        $byParent[$key].Add($row)
    }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $pending = [System.Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootId)
    $walked = [System.Collections.Generic.HashSet[int]]::new()
    [void]$walked.Add($RootId)
    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not $byParent.ContainsKey($current)) { continue }
        foreach ($child in $byParent[$current]) {
            $id = [int]$child.ProcessId
            if ($id -eq $current) { continue }
            if (-not $walked.Add($id)) { continue }
            [void]$seen.Add($id)
            $pending.Enqueue($id)
        }
    }
    return @($seen)
}

function New-FmRunLivenessRecord {
    <#
        The verdict record, built in one place so every exit from the decision
        procedure has the same shape and no caller has to test for a missing
        property under StrictMode.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns one verdict record and touches nothing. -WhatIf on a pure constructor would make the reading return nothing at all, which every caller would read as an answer it never got.')]
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][ValidateSet('processes', 'none', 'unknown')][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Detail,
        [Parameter()][AllowEmptyCollection()][int[]]$ProcessId = @(),
        [Parameter()][AllowEmptyCollection()][int[]]$AgentProcessId = @()
    )
    [pscustomobject]@{
        TaskId         = $TaskId
        State          = $State
        ProcessId      = @($ProcessId)
        AgentProcessId = @($AgentProcessId)
        Detail         = $Detail
    }
}

function Get-FmRunLivenessSpineId {
    <#
        The launch spine: the launcher process itself plus every process in the
        task's set that IS the harness program. Everything else in the set is
        work the agent started.

        Defined structurally rather than by an ignore-list of program names, and
        the harness name comes from the task record (`harness=`) rather than from
        a constant, so a spawn this port does not verify still classifies right.
        When the harness has no adapter the spine is the launcher alone - which
        leaves the agent process itself counted as work, so the verdict can only
        become `processes`, never a false `none`.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$LauncherId,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$CandidateId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Table,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Harness
    )
    $spine = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in $LauncherId) { [void]$spine.Add([int]$id) }

    $executable = ''
    $adapter = $null
    $resolve = Get-Command -Name 'Get-FmHarnessAdapter' -ErrorAction SilentlyContinue
    if ($resolve -and $Harness) {
        try { $adapter = & $resolve -Harness $Harness } catch { $adapter = $null }
    }
    if ($adapter) { $executable = [string]$adapter.Executable }
    if (-not $executable) { return @($spine) }

    $wanted = [System.IO.Path]::GetFileNameWithoutExtension($executable)
    foreach ($row in $Table) {
        $id = [int]$row.ProcessId
        if (-not ($CandidateId -contains $id)) { continue }
        $leaf = [string]$row.Name
        if ($leaf) { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
        if (-not $leaf -and $row.ExecutablePath) { $leaf = [System.IO.Path]::GetFileNameWithoutExtension([string]$row.ExecutablePath) }
        if ($leaf -and $leaf.Equals($wanted, [System.StringComparison]::OrdinalIgnoreCase)) { [void]$spine.Add($id) }
    }
    return @($spine)
}
