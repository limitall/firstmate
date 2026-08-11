#requires -Version 7.0
<#
    Public/FmBounded.ps1 - bounded execution, and the watcher's check seam.

    Ported from bin/fm-timeout-lib.sh (fm_run_timed) and the check half of
    bin/fm-watch.sh. Two exported verbs:

      Invoke-FmBoundedCommand  run one command under a HARD bound, exit 124 when
                               the bound is hit, whole process tree killed with it
      Invoke-FmValidatedCheck  the seam Invoke-FmWatchCheckSweep calls: refuse a
                               check that cannot be authenticated, otherwise run
                               it - bounded - from a private snapshot

    WHY 124 IS LOAD-BEARING. GNU timeout, the perl fallback and the bash fallback
    in the reference implementation all agree that 124 means "the bound was hit"
    and nothing else. Callers branch on it, so this port keeps the number rather
    than inventing a boolean of its own. A non-positive bound is refused, because
    `timeout 0` and `alarm 0` both DISABLE the deadline - a caller that passes 0
    would silently get an unbounded run.

    WHERE THIS SITS. Invoke-FmChildProcess (backend area) stays the generic argv
    runner for ordinary CLI calls; its -TimeoutSeconds is a courtesy bound on a
    cooperating tool. This file owns the other thing: a hard bound on code
    firstmate does not trust, where the whole tree must die and the caller must
    be able to tell "it ran and said nothing" from "it never finished".
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-FmBoundedCommand {
    <#
        .SYNOPSIS
        Run one command with a hard bound. ExitCode 124 means the bound was hit.

        .DESCRIPTION
        No shell anywhere: the command is launched from an argv array. Never
        throws for a failed or missing binary - callers branch on the returned
        record exactly as the bash callers branch on exit status.

        On Windows the child is assigned to a kill-on-close Job Object, so the
        bound kills the whole tree the check spawned and a crash of this process
        kills it too. Elsewhere, and when the shim cannot load, the fallback is
        Process.Kill($true). The record's Mechanism says which one ran, so a test
        (and a bug report) can tell them apart.

        .OUTPUTS
        [pscustomobject] ExitCode, StdOut, StdErr, TimedOut, Mechanism
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$FilePath,
        [Parameter(Position = 1)][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][double]$TimeoutSeconds,
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{}
    )

    if ($TimeoutSeconds -le 0) {
        # A non-positive bound is not a bound. Refusing is the only safe answer:
        # running unbounded would silently be a different contract.
        return [pscustomobject]@{
            ExitCode  = 124
            StdOut    = ''
            StdErr    = 'bounded run: refused, a non-positive bound is not a bound'
            TimedOut  = $true
            Mechanism = 'refused'
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }

    $useJob = Test-FmJobObjectSupport
    $mechanism = if ($useJob) { 'job-object' } else { 'process-tree' }
    $job = [IntPtr]::Zero
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    try {
        if ($useJob) {
            $job = [Firstmate.FmJobObjectNative]::CreateKillOnCloseJob()
            if ($job -eq [IntPtr]::Zero) { $useJob = $false; $mechanism = 'process-tree' }
        }
        try { $null = $proc.Start() }
        catch {
            return [pscustomobject]@{
                ExitCode  = 127
                StdOut    = ''
                StdErr    = "bounded run: could not start '$FilePath': $($_.Exception.Message)"
                TimedOut  = $false
                Mechanism = $mechanism
            }
        }
        if ($useJob) {
            # Assigned immediately after start: every process the child spawns
            # from here is created inside the job and inherits its fate.
            if (-not [Firstmate.FmJobObjectNative]::AssignProcessToJobObject($job, $proc.Handle)) {
                $useJob = $false
                $mechanism = 'process-tree'
            }
        }

        # Read both pipes asynchronously before waiting: a child that fills a
        # pipe buffer would otherwise block forever and turn the bound into a
        # hang of this process too.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Close()

        $timedOut = $false
        if (-not $proc.WaitForExit([int][math]::Ceiling($TimeoutSeconds * 1000))) {
            $timedOut = $true
            if ($useJob) { $null = [Firstmate.FmJobObjectNative]::TerminateJobObject($job, 124) }
            else { try { $proc.Kill($true) } catch { $null = $_ } }
            try { $null = $proc.WaitForExit(5000) } catch { $null = $_ }
        }

        $stdout = ''
        $stderr = ''
        try { $stdout = $outTask.GetAwaiter().GetResult() } catch { $null = $_ }
        try { $stderr = $errTask.GetAwaiter().GetResult() } catch { $null = $_ }

        $code = 124
        if (-not $timedOut) {
            try { $code = $proc.ExitCode } catch { $code = 124 }
        }

        return [pscustomobject]@{
            ExitCode  = $code
            StdOut    = $stdout
            StdErr    = $stderr
            TimedOut  = $timedOut
            Mechanism = $mechanism
        }
    }
    finally {
        $proc.Dispose()
        if ($job -ne [IntPtr]::Zero) { $null = [Firstmate.FmJobObjectNative]::CloseHandle($job) }
    }
}

function Invoke-FmValidatedCheck {
    <#
        .SYNOPSIS
        Authenticate one state check, then run it under a hard bound. Returns
        $null or Authorized = $false for anything it will not execute.

        .DESCRIPTION
        The seam Invoke-FmWatchCheckSweep calls, with its argument order:
        <check path> <state dir> <timeout seconds>.

        FAIL-CLOSED BY CONSTRUCTION. A check is executed only when ALL of these
        hold, and the watcher reports every refusal as
        "check: rejected unauthenticated state checks":

          1. it is a *.check.ps1. A *.check.sh belongs to a Linux firstmate
             sharing this home; this port has no bash and never invents one, so
             the .sh is REFUSED rather than skipped silently;
          2. it is a regular file directly inside the state directory, and not a
             reparse point - a check that is a link is a check that points
             somewhere nobody authenticated;
          3. the check-registry seam authenticates it. That registry (the port of
             bin/fm-check-register.sh's sha256 binding) is not in the module yet,
             so TODAY EVERY CHECK IS REFUSED - which is exactly the state the
             watcher was already in, now with the execution half in place behind
             it. When that area lands it publishes Test-FmCheckRegistered, or it
             takes this seam over wholesale and calls Invoke-FmBoundedCommand.

        SNAPSHOT BEFORE EXECUTE. What runs is never the file that was
        authenticated: the bytes are copied to a private temporary, hashed again,
        and the SNAPSHOT is what the bounded child executes. That closes the
        window between "authenticated" and "executed" in which the original could
        be swapped, the same reason the bash watcher runs a snapshot.

        THE BOUND. Whole tree, exit 124, per Invoke-FmBoundedCommand. A check
        that hits its bound produces no Output, so - exactly as in bash - it
        wakes nobody; the timeout is written to the triage log instead, because a
        check that never finishes is a supervision fact even when it is silent.

        .OUTPUTS
        [pscustomobject] Authorized, Output, ExitCode, TimedOut, Reason
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$State,
        [Parameter(Position = 2)][int]$TimeoutSeconds = 30
    )

    $refused = {
        param([string]$Why)
        [pscustomobject]@{ Authorized = $false; Output = ''; ExitCode = -1; TimedOut = $false; Reason = $Why }
    }

    if (-not $Path.EndsWith('.check.ps1')) { return (& $refused 'not a .check.ps1') }

    $info = $null
    try { $info = [System.IO.FileInfo]::new($Path) } catch { return (& $refused 'unreadable') }
    if (-not $info.Exists) { return (& $refused 'absent') }
    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return (& $refused 'a check may not be a link')
    }
    $parent = [System.IO.Path]::GetFullPath($info.DirectoryName)
    if ($parent -ne [System.IO.Path]::GetFullPath($State)) {
        return (& $refused 'not directly inside the state directory')
    }

    if (-not (Test-FmCheckAuthenticated -Path $Path -State $State)) {
        return (& $refused 'no registry entry authenticates this check')
    }

    $snapshot = Join-Path $State ('.fm-check-snapshot.' + [Guid]::NewGuid().ToString('N') + '.ps1')
    $result = $null
    try {
        $before = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        [System.IO.File]::Copy($Path, $snapshot)
        Set-FmPrivateFileMode -Path $snapshot
        $after = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
        if ($before -ne $after) {
            # The file changed while it was being snapshotted. Refuse: what was
            # authenticated and what would run are no longer the same bytes.
            return (& $refused 'the check changed while it was being snapshotted')
        }

        $result = Invoke-FmBoundedCommand -FilePath (Get-FmBoundedPwshPath) `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $snapshot) `
            -TimeoutSeconds $TimeoutSeconds `
            -Environment @{ FM_HOME = (Get-FmEnvValue 'FM_HOME'); FM_STATE_OVERRIDE = $State }
    }
    catch {
        return (& $refused "the check could not be prepared: $($_.Exception.Message)")
    }
    finally {
        if (Test-Path -LiteralPath $snapshot) {
            Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue
        }
    }

    if ($result.TimedOut) {
        $context = Get-FmWakeContext -State $State
        Write-FmTriageLog -Message "check hit its ${TimeoutSeconds}s bound and was killed with its whole tree (exit 124): $Path" -Context $context
    }

    return [pscustomobject]@{
        Authorized = $true
        Output     = ([string]$result.StdOut).Trim()
        ExitCode   = $result.ExitCode
        TimedOut   = $result.TimedOut
        Reason     = ''
    }
}

function Test-FmCheckAuthenticated {
    <#
        The authentication verdict for one check, delegated to the check-registry
        area (the port of bin/fm-check-register.sh's content-hash binding).

        WITH NO REGISTRY LOADED THIS IS ALWAYS $false. That is the fail-closed
        direction and it is deliberate: only the owner of the trust chain may say
        a check is trusted, and "nobody can tell us" is not a yes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$State
    )

    $cmd = Get-Command -Name 'Test-FmCheckRegistered' -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    try { return [bool](& $cmd $Path $State) } catch { return $false }
}
