# fm-psproc-lib.psm1 - portable process-query primitives.
# Twin: bin/fm-psproc-lib.sh
#
# ONE owner of "how does this platform answer a question about a process?" -
# command name, argument vector, parent pid, process-group id, liveness, and
# native-process identity. Same contract as the bash twin; almost none of the
# bash twin's machinery.
#
# WHY THIS FILE IS SO MUCH SHORTER THAN ITS TWIN (244 lines -> ~this).
# Every workaround in fm-psproc-lib.sh exists because Git Bash's Cygwin `ps`
# and MSYS `/proc` are an EMULATION of the Windows process table, and a
# partial one. PowerShell reads that table directly, so each contortion below
# collapses into one native call:
#
#   bash contortion                        why it existed            replaced by
#   -------------------------------------  ------------------------  ----------------------------
#   `ps -o comm= -p PID` first, then fall   Cygwin ps rejects `-o`    Get-Process -Id, whose
#   back                                    outright (verified here:  properties need no field
#                                           "ps: unknown option --    selection at all
#                                           o", exit 1)
#   _fm_psproc_ps_column: awk over the      Cygwin ps prints ONE      typed properties on the
#   fixed `PID PPID PGID WINPID TTY UID     fixed column set and      returned object
#   STIME COMMAND` column set               nothing else
#   _fm_psproc_ps_command: awk fields       the COMMAND column is a   .Path, already one string
#   8..NF rejoined                          path that may contain
#                                           spaces
#   _fm_psproc_read_value: `read` (not      MSYS charges 10-30x       no /proc, no subprocess,
#   `cat`) over /proc/<pid>/{exename,       Linux per fork, and       nothing to optimize
#   ppid,pgid}                              /proc/<pid>/exename has
#                                           no trailing newline
#   /proc/<pid>/cmdline NUL translation     MSYS keeps argv there     Win32_Process.CommandLine,
#                                           for MSYS processes ONLY   which covers every process
#   `ps -W` WINPID-column matching, with    a NATIVE process gets a   there is one pid space; the
#   a PID-column match only as a fallback   SYNTHETIC MSYS pid and    Windows pid IS the pid
#                                           carries its real Windows
#                                           pid in a second column
#   `tasklist //FI "PID eq N" //FO CSV`     Cygwin ps prints          .Path/.ProcessName from the
#   plus CSV awk                            `*** unknown ***` for     same object, no second tool
#                                           images it cannot read
#   `kill -0` then a native probe           a native process is       Get-Process -Id answers for
#                                           invisible to kill -0      every process
#                                           from Git Bash
#   FM_NATIVE_PID_IMAGE / FM_NATIVE_PID_    a bash function's         a returned object, because
#   PATH globals                            stdout is captured in a   PowerShell has no subshell
#                                           SUBSHELL, so it cannot    boundary to work around
#                                           return two values
#
# Function mapping, so the pairing is greppable in both directions:
#
#   bash                   PowerShell                exported
#   ---------------------  ------------------------  --------
#   fm_proc_comm           Get-FmProcCommand         yes
#   fm_proc_args           Get-FmProcCommandLine     yes
#   fm_proc_ppid           Get-FmProcParentId        yes
#   fm_proc_pgid           Get-FmProcGroupId         yes
#   fm_native_pid_info     Get-FmNativeProcessInfo   yes
#   fm_proc_alive          Test-FmProcAlive          yes
#   _fm_psproc_numeric     ConvertTo-FmProcessId     no (internal)
#   _fm_psproc_ps_column   (deleted - see above)
#   _fm_psproc_ps_command  (deleted - see above)
#   _fm_psproc_read_value  (deleted - see above)
#
# RETURN SHAPE. The bash twin's callers branch on "empty output plus non-zero"
# versus "empty output plus zero" (`comm=$(fm_proc_comm "$pid") || break`), so
# that distinction is the contract, not an implementation detail. Here:
#   $null   = could not answer (the bash non-zero return)
#   a value = answered (the bash zero return)
# A caller therefore tests `if ($null -eq $x) { break }` exactly where its bash
# twin tests `|| break`. No function throws for a pid that does not exist, is
# not numeric, or cannot be inspected - `Set-StrictMode`/`$ErrorActionPreference
# = 'Stop'` make a raw exception the DEFAULT outcome of `Get-Process -Id` on a
# dead pid (verified: ProcessCommandException), so every probe here pins its
# own -ErrorAction and every property read that can fault is guarded.
#
# WHICH PID SPACE. This module speaks NATIVE WINDOWS pids only, and that is a
# real difference from the twin rather than a detail. Git Bash's `$$` is an
# MSYS-side pid from a DIFFERENT number space: verified on this host, one bash
# reported $$ = 2102028 while its Windows pid was 22316, and `Get-Process -Id
# 2102028` finds nothing. The bash twin straddles both spaces (kill -0 and
# /proc for MSYS pids, `ps -W` WINPID matching for Windows pids); this module
# does not need to, because a PowerShell-native firstmate never creates an MSYS
# process. Durable records written by the BASH twins can still carry MSYS pids -
# see the note on state/<id> pid records at the bottom of this header.
#
# CLAUDE_PID REMAINS THE HARNESS IDENTITY SOURCE. On Windows the harness is a
# native Windows process and a bash launched under it reports PPID=1: the MSYS
# process table holds no edge back to the harness at all, so ancestry cannot
# find it and bin/fm-session-lock-lib.sh falls back to the CLAUDE_PID the
# harness exports into every process it launches. That contract is load-bearing
# (the session lock acquires against the Claude pid, verified in production) and
# is preserved: CLAUDE_PID is a native Windows pid, which is exactly the pid
# space these functions take. Get-FmNativeProcessInfo answers for it directly -
# no `ps -W` scan, no tasklist - and Get-FmProcParentId can now walk UPWARD from
# it, which the bash twin cannot do at any price.
#
# COST. Two tiers, measured on this Windows 11 / PowerShell 7.6.4 host:
#   Get-Process and .Parent are ~3ms per call, versus 160ms for the bash twin's
#   `ps -W` probe and ~380ms for its tasklist fallback.
#   Win32_Process (WMI) is ~350ms per query warm and ~2.4s on the first call in
#   a process. ONLY Get-FmProcCommandLine pays it, because the command line is
#   the one field Windows does not expose through the cheap API. That is why
#   Get-FmProcCommand and Get-FmProcParentId deliberately do NOT reuse a single
#   Win32_Process query for everything: an ancestry walk of 16 hops would cost
#   5.5 seconds instead of 50ms.
#
# NOTE FOR CONSUMERS STILL BEING CONVERTED. During the transition a bash twin
# writes `$$` (an MSYS pid) into records such as the watcher lock's `pid` child,
# while a PowerShell twin reading that record would ask Get-Process about a pid
# that does not exist in the Windows space and conclude the owner is dead. That
# is a record-format question for the lock owners (fm-wake-lib, fm-watch,
# fm-supervise-daemon), not something this module can paper over, and it is
# called out here so the conversion of those files does not discover it late.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# An explicit import, not a reliance on the caller having imported it. A .psm1
# resolves function names in its OWN scope, so the undeclared cross-lib calls
# the bash tree tolerates (docs/powershell-port-inventory.md R4) would fail here
# at runtime. Only Test-FmWindows and Invoke-FmTool are used, both on the
# non-Windows process-group path.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# --- input validation --------------------------------------------------------

<#
.SYNOPSIS
Parse a pid argument, or $null when it is not one.
.DESCRIPTION
The _fm_psproc_numeric twin. bash rejects '' and anything holding a non-digit:

    case "$1" in ''|*[!0-9]*) return 1 ;; esac

so a caller may pass an unset variable, a whitespace-padded field, or a line
read from a record file, and gets a clean failure rather than an error. This
takes [string] rather than [int] for exactly that reason: an [int] parameter
would make PowerShell THROW on "abc" at binding time, turning the bash twin's
quiet non-zero return into a terminating error. Digits only - no sign, no
whitespace, no separators - and a value too large for a pid fails the same way
a nonexistent one does.
#>
function ConvertTo-FmProcessId {
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    if ([string]::IsNullOrEmpty($ProcessId)) { return $null }
    if ($ProcessId -notmatch '^[0-9]+$') { return $null }
    $parsed = 0
    if (-not [int]::TryParse($ProcessId, [ref]$parsed)) { return $null }
    return $parsed
}

<#
.SYNOPSIS
The live process object for a pid, or $null.
.DESCRIPTION
The single place this module touches the process table for the cheap fields.
-ErrorAction Ignore rather than SilentlyContinue: a pid that has exited is a
NORMAL answer here (every liveness check asks about one), and SilentlyContinue
would still push a record onto $Error for each, leaving a trail that reads like
a fault to anything inspecting it afterwards.
#>
function Get-FmProcessObject {
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $id = ConvertTo-FmProcessId -ProcessId $ProcessId
    if ($null -eq $id) { return $null }
    return (Get-Process -Id $id -ErrorAction Ignore)
}

# Image path for a process object, or '' when Windows will not give one.
# Guarded because Path is not a plain field: PowerShell resolves it through
# MainModule, which faults for a protected or system process (pid 4 answers
# with an empty path here, and an elevated process can answer with an access
# denial instead). With $ErrorActionPreference = 'Stop' an unguarded read would
# abort the caller over a process it merely could not describe.
function Get-FmProcessObjectPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][System.Diagnostics.Process]$Process)

    try {
        $path = $Process.Path
        if ([string]::IsNullOrEmpty($path)) { return '' }
        return $path
    } catch {
        return ''
    }
}

# --- primitives --------------------------------------------------------------

<#
.SYNOPSIS
The process's command name or executable path, never its arguments.
.DESCRIPTION
Twin of fm_proc_comm. Returns the full image path when Windows exposes one and
the bare process name when it does not (a protected or system process: pid 4
answers "System"), which is the same degradation the bash twin shows when it
falls through from `ps -o comm=` to the Cygwin COMMAND column to tasklist's
image name. $null means the pid could not be resolved at all.

Callers basename it themselves, exactly as they did for `ps -o comm=` output.
Two consequences of the value being a WINDOWS path, both of which a caller
converting its own basename step must handle and neither of which this module
should hide by rewriting the platform's answer:
  - the leaf carries `.exe` (bash.exe, kimi.exe), so a caller matching an exact
    leaf name - fm-harness.sh's `kimi)` and `pi)` arms, fm-session-lock-lib.sh's
    `^pi$` pattern - must strip it. The bash twin's own native path already
    returns `claude.exe` and has the same gap.
  - the separator is `\`, so a caller splitting on `/` alone will not find the
    leaf. [System.IO.Path]::GetFileName handles both.
#>
function Get-FmProcCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $proc = Get-FmProcessObject -ProcessId $ProcessId
    if ($null -eq $proc) { return $null }

    $path = Get-FmProcessObjectPath -Process $proc
    if ($path) { return $path }

    try {
        $name = $proc.ProcessName
        if ([string]::IsNullOrEmpty($name)) { return $null }
        return $name
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
The full argument vector as one line.
.DESCRIPTION
Twin of fm_proc_args, and the function that most justifies this conversion.
The bash twin can answer only for an MSYS process, from /proc/<pid>/cmdline,
and documents that a NATIVE Windows process's argv "is not observable from Git
Bash at all" - Cygwin ps prints the image path and nothing else - so it fails
rather than return an empty string a caller could read as "started with no
arguments". Windows has always had the value; only the MSYS emulation lacked
it. Win32_Process.CommandLine returns it for every process, native or not.

The shape differs from the bash twin's in one respect worth stating rather than
normalizing away: this is the Windows COMMAND LINE, a single string in which
argv[0] is the full quoted image path (`"C:\...\sleep.exe" 40`), where
/proc/<pid>/cmdline yields the NUL-separated argv bash rejoins as `sleep 40`.
Both are "the full argument vector as one line" and every caller in the tree
substring-matches it (`case "$args" in *claude*`), so the difference is
invisible to them - but a caller that split on the first space would be wrong.

$null when the pid is gone, and also when Windows withholds the command line
(protected processes answer with nothing) - preserving the bash twin's refusal
to let "unknown" read as "no arguments".

This is the only primitive here that pays for WMI (~350ms warm, ~2.4s on the
first query in a process, measured on this host). That is the same order as
the bash twin's own native probes (`ps -W` ~160ms, tasklist ~380ms), so it is
not a regression - but it is why nothing else in this module touches CIM.
#>
function Get-FmProcCommandLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $id = ConvertTo-FmProcessId -ProcessId $ProcessId
    if ($null -eq $id) { return $null }

    $cim = $null
    try {
        $cim = Get-CimInstance -ClassName 'Win32_Process' -Filter "ProcessId=$id" -ErrorAction Ignore
    } catch {
        return $null
    }
    if ($null -eq $cim) { return $null }

    $line = $null
    try { $line = $cim.CommandLine } catch { return $null }
    if ([string]::IsNullOrEmpty($line)) { return $null }

    # The bash twin trims trailing whitespace and treats an all-whitespace
    # result as a failure; /proc/<pid>/cmdline's trailing NUL becomes a trailing
    # space there, and Windows can hand back a trailing space of its own.
    $line = $line -replace '\s+$', ''
    if ([string]::IsNullOrEmpty($line)) { return $null }
    return $line
}

<#
.SYNOPSIS
The parent pid.
.DESCRIPTION
Twin of fm_proc_ppid, and the primitive whose ANSWER changes most, because on
Windows the bash twin's answer is frequently a fiction. A Git Bash process
whose parent is a native Windows process reports PPID=1: the MSYS process table
holds no edge back to it, so the ancestry chain every harness-detection walk
depends on is SEVERED at its first hop (bin/fm-session-lock-lib.sh documents
this at length, and it is why the CLAUDE_PID fallback exists). Windows itself
never lost the edge, and this returns it.

Resolved through the process object's Parent rather than
Win32_Process.ParentProcessId for two reasons: cost (~3ms against ~350ms, and
an ancestry walk makes this call on every hop), and correctness - Parent
validates that the recorded parent pid still names the process that actually
started this one, so a RECYCLED pid resolves to $null instead of to an
unrelated process. Windows reuses pids aggressively.

One consequence, stated because it is a real difference from the twin: when the
parent has exited, this returns $null where the bash twin would return the raw
number. Every walk in the tree treats that identically - fm-harness.sh,
fm-session-lock-lib.sh, fm-sessionstart-nudge.sh and fm-backend.sh all break
when the ppid is empty, and each one's very next step reads that pid's command
name, which fails for a dead process anyway - so no caller can tell the
difference, and the pid-reuse hole closes.
#>
function Get-FmProcParentId {
    [CmdletBinding()]
    [OutputType([System.Nullable[int]])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $proc = Get-FmProcessObject -ProcessId $ProcessId
    if ($null -eq $proc) { return $null }

    try {
        $parent = $proc.Parent
        if ($null -eq $parent) { return $null }
        return [int]$parent.Id
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
The process-group id, where the platform has process groups.
.DESCRIPTION
Twin of fm_proc_pgid, and the ONE primitive that a native Windows
implementation cannot answer: Windows has no POSIX process groups. The nearest
thing - the console process group a child joins under
CREATE_NEW_PROCESS_GROUP - is not exposed by any query API, and a job object is
a different concept with different membership rules. Returning a job id, or the
pid itself, would be inventing an answer.

So on Windows this returns $null, which is precisely the degraded path the one
caller already handles: bin/fm-watch.sh reads it as `pgid=$(fm_proc_pgid ...)`
and its own comment says an empty result "skips the group-mismatch abort rather
than inventing one". A fabricated value would do the opposite - it would not
match the expected group, and the watcher would abort a healthy check.

Off Windows the bash twin's FIRST branch (`ps -o pgid= -p <pid>`) works, so it
is used unchanged. That is a subprocess per call, which this module otherwise
avoids; it is acceptable because it is the only way to read a POSIX concept and
because it never runs on the platform this port targets.
#>
function Get-FmProcGroupId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $id = ConvertTo-FmProcessId -ProcessId $ProcessId
    if ($null -eq $id) { return $null }

    if (Test-FmWindows) { return $null }

    # Guarded because a host without `ps` makes Invoke-FmTool THROW (verified:
    # MethodInvocationException from Process.Start), and no primitive in this
    # module may raise for a question it simply cannot answer.
    $result = $null
    try {
        $result = Invoke-FmTool -FilePath 'ps' -Arguments @('-o', 'pgid=', '-p', "$id")
    } catch {
        return $null
    }
    if (-not $result.Ok) { return $null }
    $value = $result.StdOut.Trim()
    if ([string]::IsNullOrEmpty($value)) { return $null }
    return $value
}

<#
.SYNOPSIS
Prove a native Windows process is alive and report its image name and path.
.DESCRIPTION
Twin of fm_native_pid_info. Returns a hashtable with Image (the leaf, e.g.
"claude.exe") and Path (the full image path), or $null for a pid that is dead
or unknown.

The bash twin needs two external tools and a column-matching rule to get here:
`ps -W` to list native processes, matching the WINPID column rather than the
PID column because a native process's PID column holds a synthetic MSYS id
(verified there: claude.exe with Windows pid 34248 appears as PID 4228552 /
WINPID 34248), then `tasklist //FI ... //FO CSV` whenever Cygwin ps answers
`*** unknown ***`. None of that is needed when there is one pid space and the
process table is directly readable.

The bash twin also PUBLISHES its two values in FM_NATIVE_PID_IMAGE and
FM_NATIVE_PID_PATH, because a bash function returns through stdout and a
caller capturing stdout runs it in a subshell where assignments cannot escape.
PowerShell has no such boundary, so the pair is returned as one object and the
globals are gone. A caller ported from bash reads $info.Image / $info.Path
where it read those two variables.

Path degrades to the image name when Windows exposes no path (a protected or
system process), which is exactly what the bash twin does on its tasklist
branch: `FM_NATIVE_PID_PATH=$image`.
#>
function Get-FmNativeProcessInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    $proc = Get-FmProcessObject -ProcessId $ProcessId
    if ($null -eq $proc) { return $null }

    $path = Get-FmProcessObjectPath -Process $proc
    if ($path) {
        $image = [System.IO.Path]::GetFileName($path)
        if ([string]::IsNullOrEmpty($image)) { $image = $path }
        return @{ Image = $image; Path = $path }
    }

    $name = $null
    try { $name = $proc.ProcessName } catch { $name = $null }
    if ([string]::IsNullOrEmpty($name)) { return $null }
    return @{ Image = $name; Path = $name }
}

<#
.SYNOPSIS
True when the pid names a live process.
.DESCRIPTION
Twin of fm_proc_alive. The bash twin is a two-step: `kill -0` first, then
fm_native_pid_info as a last resort, because a native Windows process is
invisible to kill -0 from Git Bash - the case its header calls out. Here one
lookup covers every process, native or otherwise.

A pid that does not exist is a clean $false, never an exception: under
$ErrorActionPreference = 'Stop', Get-Process -Id on a dead pid THROWS
(ProcessCommandException, verified), which would propagate out of a predicate
callers use in an `if`. Get-FmProcessObject pins -ErrorAction Ignore for
exactly that reason. A non-numeric or empty pid is $false, matching the bash
twin's _fm_psproc_numeric guard.
#>
function Test-FmProcAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$ProcessId)

    return ($null -ne (Get-FmProcessObject -ProcessId $ProcessId))
}

Export-ModuleMember -Function @(
    'Get-FmProcCommand', 'Get-FmProcCommandLine', 'Get-FmProcParentId',
    'Get-FmProcGroupId', 'Get-FmNativeProcessInfo', 'Test-FmProcAlive'
)
