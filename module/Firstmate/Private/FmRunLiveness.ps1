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
        CommandLine, CpuMs}, or $null when the table could not be read.

        $null and @() are DIFFERENT answers and the difference is the whole
        safety property: @() means "the box has no processes", which cannot
        happen, so only $null is ever produced for a failed read.

        CpuMs is cumulative kernel+user CPU for the process in milliseconds. It
        rides along because the same Win32_Process row already carries it - the
        activity reading below costs no extra query - and because a caller that
        fabricates a table for a test legitimately omits it, every read of it
        goes through Get-FmRunLivenessRowCpuMs rather than a direct property
        access that StrictMode would throw on.
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
                        # 100-ns units on Windows, so /10000 is milliseconds.
                        CpuMs           = [double](([uint64]$row.KernelModeTime + [uint64]$row.UserModeTime) / 10000.0)
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
        $cpuMs = 0.0
        try {
            $stat = [System.IO.File]::ReadAllText((Join-Path $dir.FullName 'stat'))
            # comm is parenthesised and may itself contain spaces and ')', so the
            # fields after it are located from the LAST ')' rather than by split.
            $close = $stat.LastIndexOf(')')
            if ($close -gt 0) {
                $name = $stat.Substring($stat.IndexOf('(') + 1, $close - $stat.IndexOf('(') - 1)
                $rest = ($stat.Substring($close + 1)).Trim() -split '\s+'
                if ($rest.Count -ge 2) { $parent = [int]$rest[1] }
                # $rest[0] is field 3 (state), so utime (14) and stime (15) are
                # $rest[11] and $rest[12]. Ticks, at the near-universal 100 Hz.
                if ($rest.Count -ge 13) { $cpuMs = [double](([long]$rest[11] + [long]$rest[12]) * 10) }
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
                CpuMs           = $cpuMs
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
        [Parameter()][AllowEmptyCollection()][int[]]$AgentProcessId = @(),
        # Activity defaults to `unknown` on EVERY exit, so a caller reading it
        # under StrictMode always finds it, and a path that never measured
        # movement says so rather than leaving the property absent.
        [Parameter()][ValidateSet('advancing', 'unobserved', 'unknown')][string]$Activity = 'unknown',
        [Parameter()][AllowEmptyString()][string]$ActivityDetail = 'movement was not measured'
    )
    [pscustomobject]@{
        TaskId         = $TaskId
        State          = $State
        ProcessId      = @($ProcessId)
        AgentProcessId = @($AgentProcessId)
        Detail         = $Detail
        Activity       = $Activity
        ActivityDetail = $ActivityDetail
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

<#
    ACTIVITY: the second dimension, and the one that is positive-only.

    "Is this task's run ADVANCING?" is not the question the process set answers.
    That a process exists tells you the run has not exited; it does not tell you
    the run is getting anywhere. The candidates, what each costs and how each
    lies are in docs/run-progress-evidence.md, measured on this machine.

    THE MEASUREMENT THAT DECIDES THE SHAPE OF THIS CODE. Two processes were
    sampled at steady state through Win32_Process (docs/windows-e2e-evidence.md):
    one blocked forever on a socket read - which is what a run awaiting a network
    reply looks like - and one sleeping, doing nothing at all. Every counter the
    class exposes was FROZEN for both, identically: CPU, read, write and other
    operation counts, every transfer count. A third process pushing continuous
    socket traffic - genuinely advancing - moved none of them either.

    So THERE IS NO MEASUREMENT HERE THAT CAN SAY "NOT ADVANCING". Absence of
    movement has a benign explanation at least as common as the alarming one, and
    acting on it would rebuild the exact defect docs/finished-run-stall.md
    records: a supervisor confidently telling a working worker it is not working.

    What CAN be said is the positive: something in this task's process set
    executed instructions, or the set itself changed, since the last look. That
    is real evidence, it is cheap, and it is honest. So:

      advancing  - measured movement. Positive evidence, never inferred.
      unobserved - a valid earlier sample existed and nothing moved. This is NOT
                   a stall verdict and NOTHING may escalate on it; it means only
                   that this reading saw nothing, which a healthy run awaiting a
                   reply also produces.
      unknown    - nothing was comparable: no earlier sample, too short a gap, a
                   table carrying no CPU column, or the probe disabled.

    A retry loop burning CPU forever reads `advancing` and is not advancing,
    which is the direction this dimension is allowed to be wrong in: `advancing`
    quiets nothing and grants nothing. It is reported, never acted on.
#>

# Below this the gap is too short for "nothing moved" to mean anything: a run can
# sit between two scheduler slices. Well under the wedge threshold that matters.
$script:FmRunActivityMinSecs = 30

# THE CPU FLOOR IS PER-WINDOW, NOT ABSOLUTE, because the noise it clears grows
# with the window. MEASURED (docs/windows-e2e-evidence.md section 67): a settled
# idle process burns 0 to 15.6 ms per minute - one scheduler tick, quantisation
# rather than work - so a 240 s window can carry about 62 ms of pure housekeeping
# and a fixed 50 ms floor would have called an idle process `advancing`.
# 1 ms per second is 0.1% of a core: about four times the measured noise, while
# the LEAST busy advancing shape measured burned 23 ms per second, clearing it
# more than twentyfold. The 200 ms floor covers short windows, where the tick
# quantisation rather than the rate dominates.
$script:FmRunActivityCpuFloorBaseMs = 200
$script:FmRunActivityCpuFloorPerSecMs = 1.0

function Get-FmRunLivenessRowCpuMs {
    <#
        Cumulative CPU for one table row in milliseconds, or $null when the row
        carries no CPU column. Fabricated tables legitimately omit it, and under
        StrictMode a direct property access on such a row throws - so every read
        goes through here, and a missing column becomes "no information" rather
        than an error or, far worse, a zero that would read as "burned nothing".

        Returns a [double], or $null for "this row cannot say" - the two must stay
        distinguishable, which is why the return is not simply typed [double].
    #>
    [OutputType([object], [double])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Row)
    if (-not ($Row.PSObject.Properties.Name -contains 'CpuMs')) { return $null }
    try {
        $value = $Row.CpuMs
        if ($null -eq $value) { return $null }
        return [double]$value
    } catch {
        return $null
    }
}

function Get-FmRunActivitySamplePath {
    <# One sample per task, beside the watcher's own markers. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatePath
    )
    if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($StatePath)) { return '' }
    return (Join-Path $StatePath ".run-activity-$TaskId")
}

function Read-FmRunActivitySample {
    <#
        The previous sample as {Time, CpuMs, ProcessId}, or $null when there is
        none or it does not parse. One LF line: `<unixtime> <cpuMs> <pid,pid>`.
        An unparseable sample is $null, which becomes `unknown` - never a zero
        baseline, which would manufacture a false `advancing` on the next look.
    #>
    [OutputType([object])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $line = Get-FmFirstLine -Path $Path
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $parts = ([string]$line).Trim() -split '\s+'
    if ($parts.Count -lt 2) { return $null }
    if ($parts[0] -notmatch '^[0-9]+$') { return $null }
    $cpu = 0.0
    if (-not [double]::TryParse($parts[1], [ref]$cpu)) { return $null }
    $ids = @()
    if ($parts.Count -ge 3 -and $parts[2]) {
        $ids = @($parts[2] -split ',' | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ })
    }
    return [pscustomobject]@{ Time = [long]$parts[0]; CpuMs = $cpu; ProcessId = @($ids) }
}

function Write-FmRunActivitySample {
    <#
        Record what this look saw, for the next one to compare against. A failed
        write is swallowed deliberately: it costs the NEXT reading its comparison
        (which then answers `unknown`), and that is strictly better than failing a
        liveness reading a supervisor is waiting on.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes one sample marker the next reading compares against. -WhatIf on it would leave every reading answering unknown forever, which is the reading silently ceasing to work rather than declining to act.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][long]$Time,
        [Parameter(Mandatory)][double]$CpuMs,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ProcessId
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        Set-FmFileTextLf -Path $Path -Text ("{0} {1:F0} {2}`n" -f $Time, $CpuMs, ((@($ProcessId) | Sort-Object) -join ','))
    } catch {
        Write-Debug "run-liveness: could not record the activity sample at $Path; the next reading answers unknown: $_"
    }
}

function Clear-FmRunActivitySample {
    <#
        Drop a task's sample once it has no work set left. Without this a task id
        that runs again later would compare its first look against a sample from
        a run that has been over for hours, and a pid set that "changed" across
        that gap would read as movement that nothing measured.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Removes one stale sample marker. -WhatIf on it would leave the next run of the same task id comparing against a dead run''s sample, which is the false reading this exists to prevent.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatePath
    )
    $path = Get-FmRunActivitySamplePath -TaskId $TaskId -StatePath $StatePath
    if (-not $path) { return }
    try { Remove-FmStateFile -Path $path } catch {
        Write-Debug "run-liveness: could not clear the activity sample at $path; the next look may answer unknown: $_"
    }
}

function Get-FmRunActivity {
    <#
        Whether anything in $ProcessId moved since the last look, as
        {State, Detail}: `advancing`, `unobserved` or `unknown`.

        Two independent positives, either of which is enough:
          1. CPU burned, summed over the pids present in BOTH samples - so a pid
             that started or ended in between cannot fake a delta out of its whole
             lifetime's CPU;
          2. the pid set CHANGED, which means the run started or finished a step.
             A monolithic run never shows this; a per-file test runner shows
             little else.

        Pid reuse can only push this towards `advancing`, which grants nothing.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TaskId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StatePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ProcessId,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Table
    )
    $path = Get-FmRunActivitySamplePath -TaskId $TaskId -StatePath $StatePath
    if (-not $path) {
        return [pscustomobject]@{ State = 'unknown'; Detail = 'no state path for the activity sample' }
    }

    $ids = @($ProcessId | Sort-Object)
    $byId = @{}
    foreach ($row in $Table) { $byId[[int]$row.ProcessId] = $row }

    # Sum only what the table can actually answer for. One row with no CPU column
    # makes the whole total uncomparable, because the missing part would read as
    # CPU that was not burned.
    $total = 0.0
    $complete = $true
    foreach ($id in $ids) {
        if (-not $byId.ContainsKey($id)) { $complete = $false; continue }
        $cpu = Get-FmRunLivenessRowCpuMs -Row $byId[$id]
        if ($null -eq $cpu) { $complete = $false; continue }
        $total += [double]$cpu
    }

    if (-not $complete) {
        # Nothing measurable, so nothing worth recording: overwriting here would
        # also destroy a usable baseline the next caller could have compared to.
        return [pscustomobject]@{ State = 'unknown'; Detail = 'this process table carries no CPU time, so movement could not be measured' }
    }

    $now = Get-FmUnixTime
    $previous = Read-FmRunActivitySample -Path $path
    if ($null -eq $previous) {
        Write-FmRunActivitySample -Path $path -Time $now -CpuMs $total -ProcessId $ids
        return [pscustomobject]@{ State = 'unknown'; Detail = 'first look at this task, so there is nothing to compare against yet' }
    }

    $gap = $now - $previous.Time
    if ($gap -lt 0) {
        # A baseline dated in the future - a clock correction, or a sample from
        # another machine's home. Restart from now rather than measure against it.
        Write-FmRunActivitySample -Path $path -Time $now -CpuMs $total -ProcessId $ids
        return [pscustomobject]@{ State = 'unknown'; Detail = 'the last sample is dated in the future, so the baseline was restarted' }
    }
    if ($gap -lt $script:FmRunActivityMinSecs) {
        # THE BASELINE IS DELIBERATELY LEFT ALONE. Rewriting it on every look
        # would mean anything polling faster than the minimum gap - a supervisor
        # running fm-crew-state a few times a minute - reset the window forever
        # and never got an answer at all. Letting the old sample age is what
        # allows the gap to reach a length worth reading.
        return [pscustomobject]@{ State = 'unknown'; Detail = "only ${gap}s since the last look, too short to read movement from" }
    }
    Write-FmRunActivitySample -Path $path -Time $now -CpuMs $total -ProcessId $ids

    $before = @($previous.ProcessId | Sort-Object)
    if (($before -join ',') -ne ($ids -join ',')) {
        return [pscustomobject]@{ State = 'advancing'; Detail = "its set of live processes changed in the last ${gap}s, so it started or finished a step" }
    }

    $burned = $total - [double]$previous.CpuMs
    $floor = [math]::Max($script:FmRunActivityCpuFloorBaseMs, $gap * $script:FmRunActivityCpuFloorPerSecMs)
    if ($burned -ge $floor) {
        return [pscustomobject]@{ State = 'advancing'; Detail = ("it burned {0:N1}s of CPU in the last {1}s, so something IS executing" -f ($burned / 1000.0), $gap) }
    }

    # The load-bearing wording. Everything downstream quotes this rather than
    # paraphrasing it, because the paraphrase a supervisor reaches for unaided is
    # "it is stuck", and that paraphrase is what this area exists to refuse.
    return [pscustomobject]@{
        State  = 'unobserved'
        Detail = "no CPU burned and no process started or ended in the last ${gap}s, which does NOT mean it is stalled - a run awaiting a network reply measures identically"
    }
}
