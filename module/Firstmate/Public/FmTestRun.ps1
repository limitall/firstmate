#requires -Version 7.0
<#
    Public/FmTestRun.ps1 - one process per test file, and the signal that tells
    a real action it is inside a test.

    Four exported verbs:

      Test-FmTestMode          is a suite conducting this process?
      Get-FmTestModeRefusal    the one sentence every refusal under it says
      Get-FmTestRunEnvironment what a test child inherits, and what it does not
      Invoke-FmTestRun         run every test file in its own bounded child

    THE TWO HALVES BELONG TOGETHER. Isolation stops one file reaching the next;
    it does not stop a file reaching the MACHINE. Both defects this replaces did
    the second thing - the real installer ran from inside a fixture, once for
    11.6 hours and once for a 1.4 GB download - so the runner hands every child
    a marker, and the three actions that can cost the captain something refuse
    while it names a live run. Private/FmTestRun.ps1 states why the marker holds
    a process id rather than a flag.

    WHAT THIS IS NOT. It is not a second way to run Pester's filtering, tagging,
    coverage or reporting - the child is a plain `Invoke-Pester` and every one of
    those stays Pester's. It is the process boundary, the bound, the environment
    and the temp directory, and nothing else.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FmTestMode {
    <#
        .SYNOPSIS
        True when this process is running inside firstmate's own test suite.

        .DESCRIPTION
        Reads the marker Invoke-FmTestRun sets on every child it starts, and
        believes it only while it names a process that is still there. A value
        that names nothing - a leftover in a window, a flag somebody exported by
        hand - is read as the leftover it is and ignored, which is the rule
        CONTRIBUTING.md states for FM_SHELL_RELAUNCHED after that marker told a
        captain their PowerShell 7 was not PowerShell 7.

        THE DIRECTION OF THE DOUBT IS DELIBERATE, and it is the opposite of the
        relaunch marker's. This one guards irreversible actions, so an unreadable
        or unparseable value is NOT test mode: a wrong "yes" would refuse a real
        captain's real install, and this is not the last line of defence - the
        fixtures still stub their tools, and the per-file process still contains
        the damage.

        .PARAMETER Marker
        The value to judge instead of the environment's. For tests, which cannot
        put a live process id in a constant.

        .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Marker)

    $value = if ($PSBoundParameters.ContainsKey('Marker')) {
        $Marker
    } else {
        [Environment]::GetEnvironmentVariable((Get-FmTestModeVariableName))
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }

    $runnerId = 0
    if (-not [int]::TryParse($value.Trim(), [ref]$runnerId)) { return $false }
    if ($runnerId -le 0) { return $false }
    [bool](Test-FmProcessAlive -Id $runnerId)
}

function Get-FmTestModeRefusal {
    <#
        .SYNOPSIS
        What a refusal under test mode says, wherever it is raised.

        .DESCRIPTION
        One owner for the sentence, because three places refuse under this and
        three different wordings would be three different things for a reader to
        recognise. Each caller frames it - the installer in its own banner, the
        module steps on stderr - but the reason and the way out are stated here.

        .PARAMETER Action
        What was refused, as a verb phrase: 'install onto this machine',
        'download the 1.4 GB speech model', 'ask Windows for administrator'.

        .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Action)

    $name = Get-FmTestModeVariableName
    $runner = [Environment]::GetEnvironmentVariable($name)
    $who = if ([string]::IsNullOrWhiteSpace($runner)) { 'a test run' } else { "the test run in process $runner" }
    ("REFUSED: this process was started by $who, so it will not $Action. " +
        "A suite has nobody at the keyboard, and a fixture that reaches a real tool has already stopped " +
        "being a fixture. If this is not a test, nothing should be setting $name - clear it and run again.")
}

function Get-FmTestRunEnvironment {
    <#
        .SYNOPSIS
        The environment one test child gets: what is stripped, and what is put
        back deliberately.

        .DESCRIPTION
        Returned rather than applied, so what a child inherits is assertable
        without starting one.

        WHY FM_HOME IS SET RATHER THAN STRIPPED, and it is the one place this
        differs from "scrub everything". With FM_HOME unset the home IS the
        checkout the suite runs in, and in the primary checkout that is the
        captain's own data/ and state/ - so stripping the family and stopping
        there would aim every unpinned test file at the captain's records
        instead of at an operator's stray override. Both are wrong; a private,
        empty directory per file is neither. Three files pin their own home
        already (CONTRIBUTING.md names them and section 62 has the runs); this
        makes the other fifty safe by default.

        WHY FM_VOICE_OFF IS SET, having just been stripped with the family. It
        is the only FM_ variable that is a SAFETY interlock rather than a knob,
        and the captain's standing rule is that nothing this repo starts may
        speak. Inheriting it would be luck; setting it is the rule.

        WHY TEMP AND TMP ARE PRIVATE. Pester puts TestDrive under the temp
        directory and dozens of cases here build their own fixtures beside it,
        so a shared temp is a shared namespace between files. Per file, it is
        also what makes a failure's leftovers attributable to the file that left
        them.

        .OUTPUTS
        [pscustomobject] Remove (name patterns), Set (hashtable)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$HomePath,
        [int]$RunnerProcessId = $PID
    )

    $remove = Get-FmTestRunScrubPattern
    [pscustomobject]@{
        Remove = $remove
        Set    = @{
            (Get-FmTestModeVariableName) = [string]$RunnerProcessId
            'FM_HOME'                    = $HomePath
            'FM_VOICE_OFF'               = '1'
            'TEMP'                       = $TempPath
            'TMP'                        = $TempPath
        }
    }
}

function Invoke-FmTestRun {
    <#
        .SYNOPSIS
        Run every test file in its own fresh, non-interactive, bounded child.

        .DESCRIPTION
        One `pwsh -NoProfile -NonInteractive -File` per *.Tests.ps1, in name
        order, each with the environment Get-FmTestRunEnvironment describes and
        its own temp directory. A file that exceeds -TimeoutSeconds has its
        whole process tree killed and is reported as proving nothing.

        -NonInteractive IS LOAD-BEARING and is not a tidiness flag.
        CONTRIBUTING.md has the measurement: several cases here prove a refusal
        by omitting a mandatory parameter, and without the switch that binds by
        ASKING - down a redirected pipe, where nobody can see the question - so
        the run blocks with no output and no failure instead of reporting one.

        THIS PROCESS IS THE ANCHOR. CONTRIBUTING.md's other suite rule is that
        the process running Pester needs a parent that outlives it, because
        FmIdentity and FmLock are built on parent-process identity and five
        cases fail against a parent that has exited. A runner that waits on each
        child satisfies that by construction - the anchor is no longer something
        the caller has to arrange.

        WHAT IT PRINTS. The child's own output as each file finishes, then one
        line naming the file's outcome, then a summary. Output arrives per file
        rather than per test, which is the price of the process boundary.

        .PARAMETER Path
        The directory of test files. Defaults to <RepoRoot>/tests.

        .PARAMETER RepoRoot
        The checkout under test; also the working directory each child is given,
        which is what `Invoke-Pester -Path ./tests` gives them today.

        .PARAMETER TimeoutSeconds
        The per-FILE bound. 1800 by default.

        THE REFERENCE IMPLEMENTATION USES 900, AND THIS PORT DOES NOT, because
        the files here are not that shape. MEASURED on this seat with nine lanes
        live: FmEntryPoint.Tests.ps1 took 11 minutes, because it copies the
        checkout to a temp path and runs real pwsh children against it. A
        fifteen-minute bound is one busy afternoon away from calling that a hang,
        and a gate that fails on load is worse than no gate - it teaches the
        reader to re-run rather than to look. Thirty minutes still turns the
        11.6-hour run into half an hour, which is the whole point of having one.

        .PARAMETER Filter
        Wildcard patterns matched against file names, for re-running one area.

        .PARAMETER Verbosity
        Pester's output verbosity in the child.

        .PARAMETER KeepTemp
        Keep every file's temp directory, not only a failing file's.

        .PARAMETER Quiet
        Report at the end only. The per-file lines and the children's output are
        still in the returned record.

        .OUTPUTS
        [pscustomobject] Files, Ok, FileCount, FailedFiles, TimedOutFiles,
        Total, Passed, Failed, Skipped, DurationSeconds, TempRoot, Lines.
        The counts are TESTS; FileCount, FailedFiles and TimedOutFiles are
        FILES, and they are named apart because a run with one failing file and
        forty failing tests in it is a sentence that has to say which it means.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path,
        [string]$RepoRoot,
        [double]$TimeoutSeconds = 1800,
        [string[]]$Filter = @(),
        [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Verbosity = 'Normal',
        [switch]$KeepTemp,
        [switch]$Quiet
    )

    if ($TimeoutSeconds -le 0) { throw 'a non-positive per-file bound is not a bound' }
    if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath }
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    if (-not $Path) { $Path = Join-Path $RepoRoot 'tests' }

    $files = Get-FmTestRunFile -Path $Path -Filter $Filter
    if ($files.Count -eq 0) { throw "no *.Tests.ps1 matched under '$Path'" }

    $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fmtr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $runRoot -Force
    $childScript = Write-FmTestRunChildScript -Directory $runRoot
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) { $pwsh = Join-Path $PSHOME 'pwsh' }
    $marker = Get-FmTestRunSummaryMarker

    # Written straight to the console rather than down the pipeline, because a
    # runner's job IS the live report and the pipeline already carries the
    # record the caller gets back. -Quiet is read at each site rather than
    # wrapped in a helper: a helper here would be a scriptblock, and a parameter
    # used only inside one reads as unused to the analyzer.
    $loud = -not $Quiet

    $records = [System.Collections.Generic.List[object]]::new()
    $lines = [System.Collections.Generic.List[string]]::new()
    $runClock = [System.Diagnostics.Stopwatch]::StartNew()
    $index = 0

    foreach ($file in $files) {
        $index++
        # Two digits keep the path short: Windows still has a path limit and
        # Pester's TestDrive plus a fixture's own tree goes underneath this.
        $caseRoot = Join-Path $runRoot ('{0:d2}' -f $index)
        $tempPath = Join-Path $caseRoot 't'
        $homePath = Join-Path $caseRoot 'h'
        $null = New-Item -ItemType Directory -Path $tempPath -Force
        $null = New-Item -ItemType Directory -Path $homePath -Force

        $environment = Get-FmTestRunEnvironment -TempPath $tempPath -HomePath $homePath -RunnerProcessId $PID
        if ($loud) { [Console]::Out.WriteLine(("[{0}/{1}] {2}" -f $index, $files.Count, $file.Name)) }

        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FmBoundedCommand -FilePath $pwsh -TimeoutSeconds $TimeoutSeconds `
            -WorkingDirectory $RepoRoot -Environment $environment.Set -ExcludeEnvironment $environment.Remove `
            -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-NoLogo', '-ExecutionPolicy', 'Bypass',
            '-File', $childScript, '-TestPath', $file.FullName, '-Marker', $marker, '-Verbosity', $Verbosity
        )
        $clock.Stop()

        $summary = Read-FmTestRunSummary -Text $run.StdOut
        $verdict = Get-FmTestRunVerdict -ExitCode $run.ExitCode -TimedOut ([bool]$run.TimedOut) `
            -Summary $summary -TimeoutSeconds $TimeoutSeconds

        $record = [pscustomobject]@{
            Name            = $file.Name
            FullName        = $file.FullName
            Outcome         = $verdict.Outcome
            Ok              = $verdict.Ok
            Detail          = $verdict.Detail
            ExitCode        = $run.ExitCode
            TimedOut        = [bool]$run.TimedOut
            Mechanism       = $run.Mechanism
            Total           = if ($summary) { $summary.Total } else { 0 }
            Passed          = if ($summary) { $summary.Passed } else { 0 }
            Failed          = if ($summary) { $summary.Failed } else { 0 }
            Skipped         = if ($summary) { $summary.Skipped } else { 0 }
            DurationSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
            TempRoot        = $caseRoot
            StdOut          = $run.StdOut
            StdErr          = $run.StdErr
        }
        $records.Add($record)

        if ($run.StdOut -and $loud) { [Console]::Out.WriteLine($run.StdOut.TrimEnd()) }
        if ($run.StdErr) { [Console]::Error.WriteLine($run.StdErr.TrimEnd()) }
        $line = Format-FmTestRunFileLine -File $record
        $lines.Add($line)
        if ($loud) { [Console]::Out.WriteLine($line) }

        # A passing file's leftovers are noise; a failing one's are evidence, so
        # they stay and the line above names where.
        if ($record.Ok -and -not $KeepTemp) {
            try { Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction Stop }
            catch { Write-Verbose "fm-test-run: could not remove $caseRoot`: $_" }
        }
    }
    $runClock.Stop()

    $ran = @($records)
    $failed = @($ran | Where-Object { -not $_.Ok })
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('')
    $summaryLines.Add(('  {0} files, {1} tests, {2} passed, {3} failed, {4} skipped, {5:0.0}s' -f
            $ran.Count,
        (($ran | Measure-Object -Property Total -Sum).Sum),
        (($ran | Measure-Object -Property Passed -Sum).Sum),
        (($ran | Measure-Object -Property Failed -Sum).Sum),
        (($ran | Measure-Object -Property Skipped -Sum).Sum),
            $runClock.Elapsed.TotalSeconds))
    if ($failed.Count -gt 0) {
        $summaryLines.Add('')
        $summaryLines.Add("  $($failed.Count) file(s) did not pass:")
        foreach ($bad in $failed) {
            $summaryLines.Add("    $($bad.Name) - $($bad.Outcome): $($bad.Detail)")
            $summaryLines.Add("      left at $($bad.TempRoot)")
        }
    }
    foreach ($text in $summaryLines) { $lines.Add($text); if ($loud) { [Console]::Out.WriteLine($text) } }

    if ($failed.Count -eq 0 -and -not $KeepTemp) {
        try { Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction Stop }
        catch { Write-Verbose "fm-test-run: could not remove $runRoot`: $_" }
    }

    [pscustomobject]@{
        Files           = $ran
        Ok              = ($failed.Count -eq 0)
        FileCount       = $ran.Count
        FailedFiles     = $failed.Count
        TimedOutFiles   = @($ran | Where-Object { $_.TimedOut }).Count
        Total           = [int](($ran | Measure-Object -Property Total -Sum).Sum)
        Passed          = [int](($ran | Measure-Object -Property Passed -Sum).Sum)
        Failed          = [int](($ran | Measure-Object -Property Failed -Sum).Sum)
        Skipped         = [int](($ran | Measure-Object -Property Skipped -Sum).Sum)
        DurationSeconds = [math]::Round($runClock.Elapsed.TotalSeconds, 1)
        TempRoot        = $runRoot
        Lines           = @($lines)
    }
}
