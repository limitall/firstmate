#requires -Version 7.0
<#
    Private/FmBounded.ps1 - the Win32 Job Object shim behind bounded execution.

    Ported from the kill-the-whole-group half of bin/fm-timeout-lib.sh and
    bin/fm-watch.sh's run_check_process. The bash versions build a process GROUP
    (perl setpgrp, or bash monitor mode) and signal its negative pid. Windows has
    no process groups of that shape, so the design report (section 3.3) names the
    replacement: a Job Object - create it, assign the child, terminate the job on
    timeout, with kill-on-close so even an abandoned watcher cannot strand the
    tree.

    A job object is stronger than a Unix process group in the one way that
    matters for an untrusted check script: a child cannot escape its job by
    re-grouping itself.

    There is no managed API for job objects, so this needs a small P/Invoke shim.
    # WINDOWS-UNVERIFIED: the shim has never been executed on Windows by this
    # repo. Everywhere else - and whenever the shim cannot be loaded - the
    # fallback is .NET's own Process.Kill($true), which walks the child list at
    # kill time. That is the weaker "taskkill /T" guarantee the report names,
    # which is why the job object is the primary path rather than the only one.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FmJobObjectTypeName = 'Firstmate.FmJobObjectNative'
$script:FmJobObjectSupported = $null

function Test-FmJobObjectSupport {
    <#
        Load the P/Invoke shim once. $true when job objects can be used for the
        bound; $false selects the process-tree fallback.

        FM_BOUNDED_FORCE_FALLBACK=1 forces the fallback, so the fallback path is
        exercised by the tests on the platform that has job objects too.
    #>
    [OutputType([bool])]
    param()

    # The two cheap answers are re-read every call, never memoised: a test that
    # forces the fallback must take effect in the same process.
    if (-not $IsWindows) { return $false }
    if ((Get-FmEnvValue 'FM_BOUNDED_FORCE_FALLBACK') -eq '1') { return $false }
    # Only the expensive part - compiling the shim - is remembered.
    if ($null -ne $script:FmJobObjectSupported) { return $script:FmJobObjectSupported }
    if (-not ([System.Management.Automation.PSTypeName]$script:FmJobObjectTypeName).Type) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Firstmate {
    public static class FmJobObjectNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        public const int JobObjectExtendedLimitInformation = 9;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);

        // Kill everything in the job when the last handle to it closes. That is
        // what stops a crashed or abandoned watcher from stranding a check's
        // process tree.
        public static IntPtr CreateKillOnCloseJob() {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { return IntPtr.Zero; }
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(length);
            try {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)length)) {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            } finally {
                Marshal.FreeHGlobal(buffer);
            }
            return job;
        }
    }
}
'@ -ErrorAction Stop
        }
        catch {
            $script:FmJobObjectSupported = $false
            return $false
        }
    }
    $script:FmJobObjectSupported = $true
    return $true
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
