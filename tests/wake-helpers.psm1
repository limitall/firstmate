# tests/wake-helpers.psm1 - shared fixtures for the wake-queue and watcher/lock
# suites on the PowerShell side.
# Twin: tests/wake-helpers.sh
#
# The bash twin carries two kinds of helper, and only one of them has an
# unambiguous PowerShell meaning today:
#
#   PORTED HERE - the wake/lock fixtures whose meaning is defined by
#   bin/fm-wake-lib itself: appending a wake through the production library in a
#   state-scoped child, finding a pid that is provably dead, hashing pane text
#   the way the watcher's suppressor files store it, waiting for a process to
#   exit, and building a per-case fixture directory.
#
#   DELIBERATELY NOT PORTED YET - make_case's fake `tmux`, make_supercase and
#   make_bordered_case. Those are terminal MOCKS: they encode exactly what the
#   watcher, daemon and composer send to a pane and what they expect back. On
#   the PowerShell side that protocol is defined by the backend adapters
#   (bin/backends/*.psm1, wave 3) and consumed by the watcher/daemon twins
#   (wave 4), neither of which exists yet. Writing the mock first would encode
#   guesses about an interface that has not been converted, and a wrong mock is
#   worse than a missing one because a suite built on it passes for the wrong
#   reason. New-FmTestWakeCase therefore builds the fixture LAYOUT its bash twin
#   builds and leaves the pane mock to the package that converts its consumer.
#
# tests/lib.psm1 (the tests/lib.sh port) owns the generic reporters, temp roots
# and fakebin mechanism. It is imported when present and its absence is not an
# error, so this helper is usable before that package lands.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FmTestRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:FmTestWakeModule = Join-Path $script:FmTestRepoRoot 'bin/fm-wake-lib.psm1'

Import-Module (Join-Path $script:FmTestRepoRoot 'bin/fm-common.psm1') -Force
$script:FmTestLib = Join-Path $PSScriptRoot 'lib.psm1'
if (Test-Path -LiteralPath $script:FmTestLib) {
    Import-Module $script:FmTestLib -Force
}

<#
.SYNOPSIS
The repo root, as tests/lib.sh's exported ROOT.
#>
function Get-FmTestRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmTestRepoRoot
}

<#
.SYNOPSIS
Append a wake record to <State>'s durable queue through the production library.
.DESCRIPTION
The append_wake twin. Runs in a CHILD pwsh scoped to <State> by
FM_STATE_OVERRIDE, for the same reason the bash twin uses a subshell: the
library resolves its queue paths once, when it is loaded, so a test that
appends to several state directories from one process would write them all to
whichever one happened to be resolved first. Returns the child's exit code,
which is the library's own status (0 ok, 2 invalid kind).
#>
function Add-FmTestWake {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A test fixture builder whose bash twin appends unconditionally; a confirmation surface would make every suite interactive.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$Kind,
        [Parameter(Position = 2)][AllowEmptyString()][string]$Key = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$Payload = ''
    )

    $script = @'
param($ModulePath, $Kind, $Key, $Payload)
Import-Module $ModulePath -Force
exit (Add-FmWake -Kind $Kind -Key $Key -Payload $Payload)
'@
    $scriptFile = [System.IO.Path]::GetTempFileName() + '.ps1'
    Set-FmFileText -Path $scriptFile -Text $script
    $previous = [Environment]::GetEnvironmentVariable('FM_STATE_OVERRIDE')
    try {
        [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', (ConvertTo-FmNativePath $State))
        $result = Invoke-FmTool -FilePath (Get-FmPwshPath) -Arguments @(
            '-NoProfile', '-File', $scriptFile,
            (ConvertTo-FmNativePath $script:FmTestWakeModule), $Kind, $Key, $Payload)
        return $result.ExitCode
    } finally {
        [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $previous)
        try { [System.IO.File]::Delete($scriptFile) } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
The running pwsh's own executable path, so a child inherits this exact version.
#>
function Get-FmPwshPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = $null
    try { $path = (Get-Process -Id $PID).Path } catch { $path = $null }
    if ([string]::IsNullOrEmpty($path)) { $path = 'pwsh' }
    return $path
}

<#
.SYNOPSIS
Build one per-case fixture directory: <Root>/<Name>/{state,fakebin}.
.DESCRIPTION
The make_case twin, minus the pane mock - see this file's header for why that
part waits for the package that converts its consumer. Returns the case
directory path.
#>
function New-FmTestWakeCase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A test fixture builder whose bash twin creates unconditionally; a confirmation surface would make every suite interactive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Root,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )

    $dir = Join-Path (ConvertTo-FmNativePath $Root) $Name
    [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'state'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'fakebin'))
    return $dir
}

<#
.SYNOPSIS
True when <Pid> is a live process, in either pid namespace.
.DESCRIPTION
The is_live_non_zombie twin. Windows has no zombie state - a process that has
exited leaves no entry to observe - so the zombie leg of the bash twin has
nothing to reproduce, and the liveness question is answered by the production
library so a fixture and the code under test cannot disagree about it.
#>
function Test-FmTestProcessLive {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ProcessId)

    Import-Module $script:FmTestWakeModule -Force
    return (Test-FmPidAlive -ProcessId $ProcessId)
}

<#
.SYNOPSIS
Wait for <Pid> to exit, up to <LimitTenths> tenths of a second.
.DESCRIPTION
The wait_for_exit twin. Returns $true when the process ended within the budget
and $false on timeout, where the bash twin returns 124; the caller decides what
a timeout means, and a bool cannot be confused with a real exit code.
#>
function Wait-FmTestProcessExit {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$ProcessId,
        [Parameter(Position = 1)][int]$LimitTenths = 50
    )

    for ($i = 0; $i -lt $LimitTenths; $i++) {
        if (-not (Test-FmTestProcessLive -ProcessId $ProcessId)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

<#
.SYNOPSIS
A pid that is provably not running, in either pid namespace.
.DESCRIPTION
The dead_pid twin. Both namespaces are checked because a fixture pid that looks
dead here but live to a Git Bash reader would make a cross-world lock test
prove the opposite of what it claims.
#>
function Get-FmTestDeadPid {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Import-Module $script:FmTestWakeModule -Force
    $candidate = 999999
    while (Test-FmPidAlive -ProcessId ([string]$candidate)) { $candidate++ }
    return [string]$candidate
}

<#
.SYNOPSIS
The lowercase MD5 hex of <Text>, matching `printf '%s' ... | md5sum`.
.DESCRIPTION
The hash_text twin. The watcher stores this digest in its .hash-* suppressor
files, so a fixture that primes one must produce the byte-identical digest the
bash twin would have written - no trailing newline in the input, lowercase hex
out.
#>
function Get-FmTestTextHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    } finally {
        $md5.Dispose()
    }
    $sb = [System.Text.StringBuilder]::new($bytes.Length * 2)
    foreach ($b in $bytes) { [void]$sb.Append($b.ToString('x2')) }
    return $sb.ToString()
}

<#
.SYNOPSIS
Install the wedge-alarm recorder seam so no suite can post a real notification.
.DESCRIPTION
The safety seam from the bash twin, and the reason it lives in a shared helper
rather than in each suite: the away-mode wedge alarm fires a REAL OS-level
desktop notification by default, and pointing FM_WEDGE_ALARM_EXEC at a recorder
must be impossible to forget. The recorder is an on-disk program (a daemon a
test spawns inherits the path and records too), so it is written in the form
this platform can execute directly - a .cmd on Windows, a shell script
elsewhere - rather than as a .ps1, which is not directly executable by a
non-PowerShell parent.

It logs "<channel><TAB><summary>" to FM_WEDGE_ALARM_LOG, which a test sets to
its own file; unset discards. FM_WEDGE_ALARM_FAIL=<channel> makes it exit
non-zero for that channel, to exercise graceful degradation. Returns the
recorder path and sets FM_WEDGE_ALARM_EXEC for this process and its children.
#>
function Install-FmTestWedgeAlarmRecorder {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A safety seam a suite installs unconditionally; making it confirmable would let a run proceed without it and post a real desktop notification.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $dir = ConvertTo-FmNativePath $Directory
    [void][System.IO.Directory]::CreateDirectory($dir)
    if (Test-FmWindows) {
        $recorder = Join-Path $dir 'fm-wedge-rec.cmd'
        $body = @'
@echo off
setlocal enabledelayedexpansion
if "%FM_WEDGE_ALARM_LOG%"=="" goto :checkfail
>>"%FM_WEDGE_ALARM_LOG%" echo %~1	%~2
:checkfail
if "%FM_WEDGE_ALARM_FAIL%"=="" exit /b 0
echo " %FM_WEDGE_ALARM_FAIL% " | find " %~1 " >nul && exit /b 1
exit /b 0
'@
    } else {
        $recorder = Join-Path $dir 'fm-wedge-rec'
        $body = @'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
'@
    }
    Set-FmFileText -Path $recorder -Text $body
    if (-not (Test-FmWindows)) {
        try { & 'chmod' '+x' $recorder } catch { $null = $_ }
    }
    [Environment]::SetEnvironmentVariable('FM_WEDGE_ALARM_EXEC', $recorder)
    return $recorder
}

Export-ModuleMember -Function @(
    'Get-FmTestRoot', 'Get-FmPwshPath', 'Add-FmTestWake', 'New-FmTestWakeCase',
    'Test-FmTestProcessLive', 'Wait-FmTestProcessExit', 'Get-FmTestDeadPid',
    'Get-FmTestTextHash', 'Install-FmTestWedgeAlarmRecorder'
)
