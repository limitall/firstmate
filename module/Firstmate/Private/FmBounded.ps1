#requires -Version 7.0
<#
    Private/FmBounded.ps1 - the internals behind bounded execution.

    Ported from the kill-the-whole-group half of bin/fm-timeout-lib.sh and
    bin/fm-watch.sh's run_check_process. The bash versions build a process GROUP
    (perl setpgrp, or bash monitor mode) and signal its negative pid. Windows has
    no process groups of that shape, so the design report (section 3.3) names the
    replacement: a Job Object - create it, assign the child, terminate the job on
    timeout, with kill-on-close so even an abandoned watcher cannot strand the
    tree. A job object is stronger than a Unix process group in the one way that
    matters for an untrusted check: a child cannot escape by re-grouping itself.

    THE P/INVOKE SURFACE IS NOT HERE. Private/FmJobCustody.ps1 already owns every
    kernel32 job-object declaration this module makes, for the teardown area's
    per-task custody jobs. Bounding needs the opposite LIFETIME from custody - a
    custody job must outlive the process that created it, a bounded run's job
    must die with it - so this file adds that policy on top of
    Firstmate.JobCustody::CreateKillOnClose rather than declaring a second set
    of imports for the same kernel APIs.

    VERIFIED ON WINDOWS 11. This shim now genuinely creates and uses a job
    object there; before, the custody type's hand-computed struct size made
    CreateKillOnClose fail on every call, and this file silently took the
    fallback on the one platform the job object exists for. The bounded-run
    tests assert Mechanism = 'job-object' on Windows precisely so that
    downgrade cannot happen quietly again.

    Whenever the shim cannot load, the fallback is still .NET's
    Process.Kill($true), which walks the child list at kill time. That is the
    weaker "taskkill /T" guarantee - a child can escape it by re-parenting -
    which is why the job object is the primary path rather than the only one.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FmJobObjectSupport {
    <#
        Can a bounded run use a kill-on-close job object? Defers to the custody
        area's loader, which owns compiling the shim.

        FM_BOUNDED_FORCE_FALLBACK=1 forces the process-tree fallback, so that
        path is exercised by the tests on the platform that has job objects too.
    #>
    [OutputType([bool])]
    param()

    if ((Get-FmEnvValue 'FM_BOUNDED_FORCE_FALLBACK') -eq '1') { return $false }
    return (Test-FmJobCustodySupported)
}

function New-FmBoundedJob {
    <#
        An anonymous kill-on-close job for one bounded run, or IntPtr.Zero when
        job objects are unavailable. The caller closes the handle, which is also
        what reaps anything still inside it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([IntPtr])]
    param()

    if (-not (Test-FmJobObjectSupport)) { return [IntPtr]::Zero }
    if (-not $PSCmdlet.ShouldProcess('bounded run', 'create kill-on-close job')) { return [IntPtr]::Zero }
    return [Firstmate.JobCustody]::CreateKillOnClose()
}

function Get-FmBoundedPwshPath {
    <# The pwsh this process is running, so a bounded child is the same host. #>
    [OutputType([string])]
    param()
    $path = ''
    try { $path = (Get-Process -Id $PID).Path } catch { $path = '' }
    if ([string]::IsNullOrEmpty($path)) { $path = 'pwsh' }
    return $path
}
