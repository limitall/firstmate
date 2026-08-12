#requires -Version 7.0
# module/Firstmate/Private/FmJobCustody.ps1 - process custody for a task's
# worktree, on Windows, without lsof and without process groups.
#
# WHAT THIS REPLACES, AND WHY THE REPLACEMENT IS STRONGER
#
# The bash teardown's Fix 2 (bin/fm-teardown.sh:1412-1513) reaps every process
# whose CURRENT WORKING DIRECTORY is under the task's worktree or its tasktmp,
# found with one bounded `lsof -a -d cwd` scan, then TERM -> KILL with a process
# identity recheck between the passes. Its lsof-less fallback signals the
# backend pane's process GROUP (`kill -TERM -- -$pgid`).
#
# Neither primitive exists on Windows, and the design report settled the
# replacement (report.md section 2 port map, "Teardown custody", and section
# 4.3): a Win32 **job object** per task. The guarantee changes shape in our
# favour:
#
#   - A process group is advisory. A child can call setpgrp() and escape the
#     group its parent will later signal, which is exactly how the observed
#     leaks happened (`go test` binaries reparented to init, surviving the pane
#     close). A process assigned to a job object CANNOT leave it, and every
#     process it spawns is in the job too. TerminateJobObject is therefore a
#     complete answer where `kill -- -$pgid` is a best effort.
#   - The cwd scan is a DISCOVERY mechanism: it finds processes firstmate never
#     spawned. The job is a CUSTODY mechanism: it holds exactly the processes
#     firstmate spawned, and holds them by construction rather than by
#     inference. What is lost is the discovery half - a process that some other
#     tool started inside the worktree is not in our job. Section 4.3 records
#     that loss, and records why the core guarantee survives anyway: on Windows
#     the worktree delete FAILS CLOSED while anything holds a handle or a cwd
#     inside it, so an undiscovered holder produces a refusal from the OS rather
#     than a silent discard. Get-FmFileHolderProcess then names it.
#
# LIFETIME, which is the one subtle part. A named job object lives while any
# handle to it is open OR any process is assigned to it. firstmate's spawner
# exits long before teardown runs, so custody survives only through the
# assigned processes themselves. Two consequences, both handled below and both
# reported honestly rather than papered over:
#   - Open-by-name failing means EITHER the task never registered custody OR
#     every process in it has already exited. Those are indistinguishable from
#     outside, so Stop-FmTaskJob reports 'not-found' - a step that did NOT run,
#     never a step that passed.
#   - JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE is deliberately NOT set. It would kill
#     the worker the moment the spawner exits. Teardown terminates explicitly.
#
# PARTLY VERIFIED ON WINDOWS 11 NOW. CreateKillOnClose is: it was run on the
# laptop, it FAILED (ERROR_BAD_LENGTH from a hand-computed struct size), and it
# passes since the structs were declared properly - see CreateKillOnClose. The
# fact that a documented, stable Win32 API can still be called wrongly is the
# whole argument for the marker: this file carried it for months, the note was
# correct, and the first real execution found a defect that no Linux run could.
#
# WINDOWS-UNVERIFIED: every OTHER P/Invoke here - the named custody job, Assign,
# TerminateJobObject, the job process-id query, and the Restart Manager calls.
# They have still never run on a Windows host. On non-Windows the whole surface
# reports 'unsupported' - it never emulates, and never claims custody it does
# not have.

Set-StrictMode -Version Latest

# The interop lives in one C# type so all the buffer marshalling (job process-id
# lists, Restart Manager's RM_PROCESS_INFO array) stays out of PowerShell, where
# it would be both unreadable and StrictMode-hostile.
$script:FmJobCustodyTypeName = 'Firstmate.JobCustody'
$script:FmJobCustodyTypeState = 'unloaded'

$script:FmJobCustodySource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Firstmate
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct RM_UNIQUE_PROCESS
    {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    public static class JobCustody
    {
        // Job object access rights. ALL_ACCESS for create; the teardown path
        // asks for only what it uses, so a hardened token still works.
        public const uint JOB_OBJECT_ALL_ACCESS = 0x1F001F;
        public const uint JOB_OBJECT_TERMINATE = 0x0008;
        public const uint JOB_OBJECT_QUERY = 0x0004;
        public const uint SYNCHRONIZE = 0x00100000;
        private const int JobObjectBasicProcessIdList = 3;
        private const int JobObjectExtendedLimitInformation = 9;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        private const int ERROR_MORE_DATA = 234;

        // Declared rather than hand-measured, so the marshaller supplies the
        // x64 padding. See CreateKillOnClose for what hand-measuring cost.
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
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
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenJobObjectW(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateJobObject(IntPtr hJob, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryInformationJobObject(IntPtr hJob, int JobObjectInfoClass,
            IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength, IntPtr lpReturnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass,
            IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
            uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded,
            ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        // Create-or-open the named job. Returns IntPtr.Zero on failure; the
        // caller reads LastWin32Error through Marshal for the diagnostic.
        public static IntPtr Create(string name)
        {
            return CreateJobObjectW(IntPtr.Zero, name);
        }

        // An ANONYMOUS job whose members die when the last handle to it closes.
        //
        // The opposite lifetime to the named custody job above, on purpose. A
        // task's custody job must OUTLIVE the process that created it, so
        // teardown can find and terminate it later; a bounded run's job must
        // die WITH its owner, so a crashed watcher cannot strand a check's
        // process tree. Same kernel object, two rules - kept in one shim so
        // there is a single P/Invoke surface for job objects in this module.
        // Used by Invoke-FmBoundedCommand (docs/bounded-execution.md).
        public static IntPtr CreateKillOnClose()
        {
            IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { return IntPtr.Zero; }
            // THE LAYOUT IS THE MARSHALLER'S JOB, NOT ARITHMETIC'S. This was
            // hand-computed as
            //     (2*8) + 4 + (2*8) + 4 + 8 + (2*4) + (6*8) + (4*8)
            // which sums the FIELDS and misses the x64 padding the compiler
            // inserts twice: 4 bytes after LimitFlags before the pointer-sized
            // MinimumWorkingSetSize, and 4 more after ActiveProcessLimit before
            // Affinity. That yields 136 where the real
            // JOBOBJECT_EXTENDED_LIMIT_INFORMATION is 144, and
            // SetInformationJobObject validates cbJobObjectInformationLength
            // EXACTLY - it failed with ERROR_BAD_LENGTH (24) every time.
            //
            // So CreateKillOnClose returned IntPtr.Zero on every Windows call
            // it ever made, and both callers took their documented fallback
            // without complaint: bounded runs silently used Process.Kill(true)
            // instead of a job, which is the weaker taskkill /T guarantee a
            // child can escape by re-parenting. Measured on Windows 11:
            // len=136 -> false, GetLastError 24; len=144 -> true.
            //
            // Marshal.SizeOf of a real [StructLayout(Sequential)] struct gets
            // the padding right by construction, so this cannot drift again.
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
            return job;
        }

        public static IntPtr OpenForTerminate(string name)
        {
            return OpenJobObjectW(JOB_OBJECT_TERMINATE | JOB_OBJECT_QUERY | SYNCHRONIZE, false, name);
        }

        public static IntPtr OpenForQuery(string name)
        {
            return OpenJobObjectW(JOB_OBJECT_QUERY, false, name);
        }

        public static bool Assign(IntPtr job, int processId)
        {
            // PROCESS_SET_QUOTA | PROCESS_TERMINATE, the documented pair
            // AssignProcessToJobObject requires on the target process.
            IntPtr process = OpenProcess(0x0100 | 0x0001, false, processId);
            if (process == IntPtr.Zero) { return false; }
            try { return AssignProcessToJobObject(job, process); }
            finally { CloseHandle(process); }
        }

        public static bool Terminate(IntPtr job)
        {
            return TerminateJobObject(job, 1);
        }

        public static bool Close(IntPtr handle)
        {
            if (handle == IntPtr.Zero) { return true; }
            return CloseHandle(handle);
        }

        // Live process ids in the job. An empty array means the job holds
        // nothing; null means the query itself failed and the caller must NOT
        // read that as "nothing left alive".
        public static int[] ProcessIds(IntPtr job)
        {
            int capacity = 64;
            for (int attempt = 0; attempt < 6; attempt++)
            {
                // JOBOBJECT_BASIC_PROCESS_ID_LIST: two DWORDs then an inline
                // ULONG_PTR array. Laid out by hand because the trailing array
                // makes it unmarshallable as a struct.
                int size = (2 * sizeof(uint)) + (capacity * IntPtr.Size);
                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    Marshal.WriteInt32(buffer, 0, capacity);
                    Marshal.WriteInt32(buffer, sizeof(uint), 0);
                    if (!QueryInformationJobObject(job, JobObjectBasicProcessIdList, buffer, (uint)size, IntPtr.Zero))
                    {
                        if (Marshal.GetLastWin32Error() == ERROR_MORE_DATA)
                        {
                            capacity *= 4;
                            continue;
                        }
                        return null;
                    }
                    int inList = Marshal.ReadInt32(buffer, sizeof(uint));
                    if (inList < 0) { return null; }
                    int[] ids = new int[inList];
                    for (int i = 0; i < inList; i++)
                    {
                        IntPtr entry = Marshal.ReadIntPtr(buffer, (2 * sizeof(uint)) + (i * IntPtr.Size));
                        ids[i] = (int)entry.ToInt64();
                    }
                    return ids;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            return null;
        }

        // Restart Manager: name the processes holding the given files open.
        // DIAGNOSTIC ONLY - it reports handles on FILES, never a process whose
        // cwd is a directory, so it can explain a refusal but can never
        // authorize a delete. Returns null when Restart Manager itself failed.
        public static string[] FileHolders(string[] paths)
        {
            uint session;
            StringBuilder key = new StringBuilder(33);
            if (RmStartSession(out session, 0, key) != 0) { return null; }
            try
            {
                if (RmRegisterResources(session, (uint)paths.Length, paths, 0, null, 0, null) != 0)
                {
                    return null;
                }
                uint needed = 0;
                uint count = 0;
                uint reasons = 0;
                int rc = RmGetList(session, out needed, ref count, null, ref reasons);
                if (rc == ERROR_MORE_DATA)
                {
                    count = needed;
                    RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[count];
                    reasons = 0;
                    rc = RmGetList(session, out needed, ref count, info, ref reasons);
                    if (rc != 0) { return null; }
                    List<string> holders = new List<string>();
                    for (int i = 0; i < count; i++)
                    {
                        holders.Add(string.Format("{0} (pid {1})",
                            info[i].strAppName, info[i].Process.dwProcessId));
                    }
                    return holders.ToArray();
                }
                if (rc != 0) { return null; }
                return new string[0];
            }
            finally
            {
                RmEndSession(session);
            }
        }
    }
}
'@

# Test-FmJobCustodySupported: is real job-object custody available in this
# process? Compiles the interop on first use. Never throws - an unsupported
# host degrades to an explicit "did not run", which is the whole point.
function Test-FmJobCustodySupported {
    [CmdletBinding()]
    param()
    if (-not $IsWindows) { return $false }
    if ($script:FmJobCustodyTypeState -eq 'loaded') { return $true }
    if ($script:FmJobCustodyTypeState -eq 'failed') { return $false }
    if ($script:FmJobCustodyTypeName -as [type]) {
        $script:FmJobCustodyTypeState = 'loaded'
        return $true
    }
    try {
        Add-Type -TypeDefinition $script:FmJobCustodySource -ErrorAction Stop
        $script:FmJobCustodyTypeState = 'loaded'
        return $true
    } catch {
        $script:FmJobCustodyTypeState = 'failed'
        return $false
    }
}

# Get-FmTaskJobName: the kernel object name for a task's custody job. `Local\`
# is the per-session namespace, which is where firstmate's own processes live;
# a `Global\` name would need SeCreateGlobalPrivilege and would let two logon
# sessions collide on one task id.
function Get-FmTaskJobName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskId)
    if (-not (Test-FmTaskIdShape -TaskId $TaskId)) {
        throw "error: '$TaskId' is not a valid task id; refusing to name a custody job for it"
    }
    "Local\firstmate-task-$TaskId"
}

# New-FmTaskJob: create (or open) the task's custody job and return the open
# handle. The CALLER owns that handle and must keep it open only as long as it
# needs to assign processes - see this file's header on lifetime.
function New-FmTaskJob {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TaskId)

    $name = Get-FmTaskJobName -TaskId $TaskId
    if (-not (Test-FmJobCustodySupported)) {
        return [pscustomobject]@{
            TaskId = $TaskId; Name = $name; Handle = [IntPtr]::Zero
            Ok = $false; Reason = 'job objects are unavailable on this host'
        }
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'create process custody job')) {
        return $null
    }
    $handle = [Firstmate.JobCustody]::Create($name)
    if ($handle -eq [IntPtr]::Zero) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return [pscustomobject]@{
            TaskId = $TaskId; Name = $name; Handle = [IntPtr]::Zero
            Ok = $false; Reason = "CreateJobObject failed (win32 error $code)"
        }
    }
    [pscustomobject]@{
        TaskId = $TaskId; Name = $name; Handle = $handle; Ok = $true; Reason = ''
    }
}

# Add-FmTaskJobProcess: put one process - and, from that moment, every process
# it spawns - under the task's custody. This is the call the spawn path makes
# with the pane's process id once herdr reports it.
function Add-FmTaskJobProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][IntPtr]$JobHandle,
        [Parameter(Mandatory)][int]$ProcessId
    )
    if (-not (Test-FmJobCustodySupported)) { return $false }
    if ($JobHandle -eq [IntPtr]::Zero) { return $false }
    if (-not $PSCmdlet.ShouldProcess("process $ProcessId", 'assign to the task custody job')) {
        return $false
    }
    [Firstmate.JobCustody]::Assign($JobHandle, $ProcessId)
}

# Close-FmTaskJob: release this process's handle. Does NOT end custody -
# assigned processes keep the job alive, which is exactly what lets teardown
# find it later.
function Close-FmTaskJob {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$JobHandle)
    if (-not (Test-FmJobCustodySupported)) { return $false }
    [Firstmate.JobCustody]::Close($JobHandle)
}

# Get-FmTaskJobProcessId: the live process ids under a task's custody.
#
# Returns a record, not a bare list, because the three answers are genuinely
# different and teardown must not collapse them:
#   State='processes'  Ids has the live ids           -> a holder exists
#   State='empty'      the job exists and holds none  -> proven clear
#   State='not-found'  no such job                    -> custody NOT proven
#   State='unsupported'/'error'                       -> custody NOT proven
function Get-FmTaskJobProcessId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TaskId)

    $name = Get-FmTaskJobName -TaskId $TaskId
    if (-not (Test-FmJobCustodySupported)) {
        return [pscustomobject]@{ TaskId = $TaskId; Name = $name; State = 'unsupported'; Ids = @() }
    }
    $handle = [Firstmate.JobCustody]::OpenForQuery($name)
    if ($handle -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ TaskId = $TaskId; Name = $name; State = 'not-found'; Ids = @() }
    }
    try {
        $ids = [Firstmate.JobCustody]::ProcessIds($handle)
        if ($null -eq $ids) {
            return [pscustomobject]@{ TaskId = $TaskId; Name = $name; State = 'error'; Ids = @() }
        }
        $state = if ($ids.Count -gt 0) { 'processes' } else { 'empty' }
        [pscustomobject]@{ TaskId = $TaskId; Name = $name; State = $state; Ids = @($ids) }
    } finally {
        $null = [Firstmate.JobCustody]::Close($handle)
    }
}

# Stop-FmTaskJob: terminate every process under the task's custody and prove it.
#
# TerminateJobObject is synchronous in the sense that it marks every process for
# termination, but the process objects linger until their last handle closes, so
# the proof is the follow-up query: poll until the job holds nothing, or the
# budget runs out. A survivor is reported, never assumed away - teardown refuses
# on it, because a live process in the worktree means the worktree is not ours
# to hard-reset.
function Stop-FmTaskJob {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [double]$TimeoutSeconds = 10,
        [double]$PollSeconds = 0.25
    )

    $name = Get-FmTaskJobName -TaskId $TaskId
    $result = [ordered]@{
        TaskId = $TaskId; Name = $name; Outcome = ''; Survivors = @(); Detail = ''
    }
    if (-not (Test-FmJobCustodySupported)) {
        $result['Outcome'] = 'unsupported'
        $result['Detail'] = if ($IsWindows) {
            'the job-object interop could not be loaded'
        } else {
            'job objects exist only on Windows'
        }
        return [pscustomobject]$result
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'terminate the task process custody job')) {
        $result['Outcome'] = 'skipped'
        $result['Detail'] = 'not confirmed'
        return [pscustomobject]$result
    }

    $handle = [Firstmate.JobCustody]::OpenForTerminate($name)
    if ($handle -eq [IntPtr]::Zero) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $result['Outcome'] = 'not-found'
        $result['Detail'] = ("no custody job named $name (win32 error $code); either this task never " +
            'registered custody or every process in it has already exited - the two are indistinguishable from here')
        return [pscustomobject]$result
    }
    try {
        if (-not [Firstmate.JobCustody]::Terminate($handle)) {
            $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            $result['Outcome'] = 'terminate-failed'
            $result['Detail'] = "TerminateJobObject failed (win32 error $code)"
            return [pscustomobject]$result
        }
        $elapsed = 0.0
        while ($true) {
            $ids = [Firstmate.JobCustody]::ProcessIds($handle)
            if ($null -eq $ids) {
                $result['Outcome'] = 'unverified'
                $result['Detail'] = 'the job was terminated but its process list could not be read back'
                return [pscustomobject]$result
            }
            if ($ids.Count -eq 0) {
                $result['Outcome'] = 'terminated'
                $result['Detail'] = 'the custody job holds no live process'
                return [pscustomobject]$result
            }
            if ($elapsed -ge $TimeoutSeconds) {
                $result['Outcome'] = 'survivors'
                $result['Survivors'] = @($ids)
                $result['Detail'] = "processes still alive after ${TimeoutSeconds}s: $($ids -join ', ')"
                return [pscustomobject]$result
            }
            Start-Sleep -Seconds $PollSeconds
            $elapsed += $PollSeconds
        }
    } finally {
        $null = [Firstmate.JobCustody]::Close($handle)
    }
}

# Get-FmFileHolderProcess: name the processes holding the given files open.
#
# This is the section 4.3 diagnostic, and only a diagnostic. Restart Manager
# reports handles on FILES; it cannot see a process whose CWD is a directory,
# which is precisely the case lsof covered on Linux. It exists so a refusal can
# say WHO, not so a delete can be authorized.
#
# Returns @() when nothing holds them and $null when Restart Manager itself
# could not answer - a caller must not read $null as "nobody".
function Get-FmFileHolderProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)

    if (-not (Test-FmJobCustodySupported)) { return $null }
    $existing = @($Path | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($existing.Count -eq 0) { return @() }
    try {
        $holders = [Firstmate.JobCustody]::FileHolders([string[]]$existing)
    } catch {
        return $null
    }
    if ($null -eq $holders) { return $null }
    @($holders)
}
