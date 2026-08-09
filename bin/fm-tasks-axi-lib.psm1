# fm-tasks-axi-lib.psm1 - tasks-axi backend selection and compatibility probe.
# Twin: bin/fm-tasks-axi-lib.sh
#
# Shared by bootstrap, teardown, and secondmate backlog handoff. Compatible
# means tasks-axi --version reports 0.1.1 or newer, `tasks-axi update --help`
# exposes --archive-body for recoverable note rewrites, and `tasks-axi mv
# --help` exposes [<id>...] for the atomic multi-ID moves secondmate handoffs
# require (introduced in tasks-axi 0.2.2).
#
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi
# mv`. Absent or any other value keeps the default tasks-axi backend path,
# falling back to manual mutation when the tool is not compatible.
#
# bash -> PowerShell:
#   fm_tasks_axi_version_parts           -> Get-FmTasksAxiVersionPart
#   fm_tasks_axi_compatible              -> Test-FmTasksAxiCompatible
#   fm_tasks_axi_update_has_archive_body -> Test-FmTasksAxiUpdateHasArchiveBody
#   fm_tasks_axi_mv_has_multi_id         -> Test-FmTasksAxiMvHasMultiId
#   fm_backlog_backend_value             -> Get-FmBacklogBackendValue
#   fm_backlog_backend_manual            -> Test-FmBacklogBackendManual
#   fm_tasks_axi_backend_available       -> Test-FmTasksAxiBackendAvailable
#
# Where the PowerShell is shorter: the bash pipes `tasks-axi --version` through
# sed + head (two forks per probe) and pipes each --help through grep (one more
# fork each). Here that is one in-process regex and two in-process substring
# tests, so a bootstrap probe costs one child process per tasks-axi call
# instead of three - the MSYS fork cost this port exists to remove.
#
# Where it must NOT be shorter: the version regex is the sed expression's exact
# twin, greediness included. `.*` before the first group is GREEDY in both
# worlds, so "v10.20.30" yields "0 20 30", not "10 20 30" (verified against the
# bash oracle). Do not "fix" that here; the two worlds must agree, and the
# oracle is bash.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# The sed twin: `s/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p`.
# Compiled once at import rather than per call; a bootstrap run probes this
# more than once and the pattern never changes.
$script:FmTasksAxiVersionRe = [regex]::new('.*([0-9][0-9]*)\.([0-9][0-9]*)\.([0-9][0-9]*)')

<#
.SYNOPSIS
The full executable path of an external tool, or $null when it is not on PATH.
.DESCRIPTION
The `command -v` twin, but returning the PATH rather than a boolean, and that
distinction is not cosmetic. tasks-axi is a Node-style CLI, which on Windows
installs as a `tasks-axi.cmd` shim. Get-Command resolves that shim from the
bare name because it honors PATHEXT - but CreateProcess does NOT: it appends
only `.exe`, so starting a process named 'tasks-axi' fails with "cannot find
the file specified" even though the tool is plainly installed (verified on
this host). Detecting the tool and then failing to run it is the worst of both
answers, so every invocation below goes through the RESOLVED path.

git is called by bare name elsewhere in this tree because git ships as a real
.exe; the resolution matters specifically for tools that may be shims.

Duplicated in bin/fm-quota-axi-lib.psm1 for the same reason. The wave report
asks for this to move into bin/fm-common.psm1 as the natural home.
#>
function Resolve-FmTasksAxiToolPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    $found = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return $null }
    return $found[0].Source
}

<#
.SYNOPSIS
The "<major> <minor> <patch>" triple parsed out of `tasks-axi --version`.
.DESCRIPTION
Three distinct results, all load-bearing for the caller and all preserved from
the bash twin:
  $null - tasks-axi is absent, or the version command failed (bash: return 1).
  ''    - the tool ran but printed nothing this pattern recognizes (bash:
          return 0 with empty stdout, which the compatibility check then
          rejects on its own `[ -n "$parts" ]` test).
  'M m p' - the first line that matched, exactly as `sed -n ... | head -1`
          selects it.
#>
function Get-FmTasksAxiVersionPart {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $tool = Resolve-FmTasksAxiToolPath 'tasks-axi'
    if ($null -eq $tool) { return $null }
    $result = Invoke-FmTool -FilePath $tool -Arguments @('--version')
    if (-not $result.Ok) { return $null }

    # `sed -n ...p | head -1` prints the first MATCHING line, not the first
    # line, so a banner ahead of the version does not suppress the answer.
    foreach ($line in ($result.StdOut -split "`n")) {
        $m = $script:FmTasksAxiVersionRe.Match($line)
        if ($m.Success) {
            return "{0} {1} {2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value
        }
    }
    return ''
}

<#
.SYNOPSIS
True when `tasks-axi update --help` advertises --archive-body.
.DESCRIPTION
The bash captures `2>&1` deliberately: some builds print their help to stderr,
and a usage error still carries the flag list. Invoke-FmTool keeps the two
streams apart, so this joins them back the same way rather than reading only
stdout and silently answering "no" on such a build.
#>
function Test-FmTasksAxiUpdateHasArchiveBody {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $tool = Resolve-FmTasksAxiToolPath 'tasks-axi'
    if ($null -eq $tool) { return $false }
    $result = Invoke-FmTool -FilePath $tool -Arguments @('update', '--help')
    if (-not $result.Ok) { return $false }
    return (($result.StdOut + $result.StdErr).Contains('--archive-body'))
}

<#
.SYNOPSIS
True when `tasks-axi mv --help` advertises the multi-ID `[<id>...]` form.
.DESCRIPTION
Atomic multi-ID moves are what makes a secondmate backlog handoff all-or-
nothing, so an older tasks-axi must not be treated as usable for handoffs.
`grep -F` in the bash twin is a FIXED-string match - the brackets and dots are
literal - hence String.Contains here rather than a regex.
#>
function Test-FmTasksAxiMvHasMultiId {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $tool = Resolve-FmTasksAxiToolPath 'tasks-axi'
    if ($null -eq $tool) { return $false }
    $result = Invoke-FmTool -FilePath $tool -Arguments @('mv', '--help')
    if (-not $result.Ok) { return $false }
    return (($result.StdOut + $result.StdErr).Contains('[<id>...]'))
}

<#
.SYNOPSIS
True when the installed tasks-axi meets the compatibility floor AND exposes
both required subcommand capabilities.
.DESCRIPTION
Floor: 0.1.1. The version comparison is done on explicitly cast [long] values -
PowerShell's `-gt` on two strings is a STRING comparison ('10' -gt '9' is
$false), which would silently pass a 0.9.x build as newer than 0.10.x. The
bash `[ "$major" -gt 0 ]` was always integer, so the cast is what preserves the
twin's meaning, not a refinement of it.

A version string this cannot parse into three integers is incompatible, never
assumed current: in bash a non-numeric `[ x -gt 0 ]` fails the test outright,
and returning $false here is the same refusal.
#>
function Test-FmTasksAxiCompatible {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $parts = Get-FmTasksAxiVersionPart
    if ([string]::IsNullOrEmpty($parts)) { return $false }

    $fields = $parts.Split(' ')
    if ($fields.Length -lt 3) { return $false }
    [long]$major = 0; [long]$minor = 0; [long]$patch = 0
    if (-not [long]::TryParse($fields[0], [ref]$major)) { return $false }
    if (-not [long]::TryParse($fields[1], [ref]$minor)) { return $false }
    if (-not [long]::TryParse($fields[2], [ref]$patch)) { return $false }

    $meetsFloor = ($major -gt 0) -or
                  ($major -eq 0 -and $minor -gt 1) -or
                  ($major -eq 0 -and $minor -eq 1 -and $patch -ge 1)
    if (-not $meetsFloor) { return $false }

    return ((Test-FmTasksAxiUpdateHasArchiveBody) -and (Test-FmTasksAxiMvHasMultiId))
}

<#
.SYNOPSIS
The configured backlog backend name for a config directory.
.DESCRIPTION
Absent file, unreadable file, or a file that is all whitespace all resolve to
'tasks-axi' - the default backend - because the bash twin's `tr -d '[:space:]'`
plus `[ -n "$value" ] || value=tasks-axi` collapses those three cases together.

The whitespace class is spelled out as the six C-locale characters rather than
.NET's `\s`, which additionally strips NBSP and the Unicode space separators.
A config value differing only by an invisible NBSP must be REJECTED as an
unknown backend by both worlds, not silently normalized by one of them.
#>
function Get-FmBacklogBackendValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    $backendFile = Join-Path (ConvertTo-FmNativePath $ConfigDir) 'backlog-backend'
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $backendFile))) {
        return 'tasks-axi'
    }
    $value = (Get-FmFileText $backendFile) -replace '[ \t\n\v\f\r]', ''
    if ($value -eq '') { return 'tasks-axi' }
    return $value
}

<#
.SYNOPSIS
True when this home has opted routine backlog mutation out of tasks-axi.
#>
function Test-FmBacklogBackendManual {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    return ((Get-FmBacklogBackendValue -ConfigDir $ConfigDir) -eq 'manual')
}

<#
.SYNOPSIS
True when routine backlog work should go through tasks-axi in this home.
.DESCRIPTION
`manual` short-circuits before the compatibility probe, so an opted-out home
never pays for the three tasks-axi child processes - and never reports a
tooling problem it has already declared irrelevant.
#>
function Test-FmTasksAxiBackendAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ConfigDir)

    if (Test-FmBacklogBackendManual -ConfigDir $ConfigDir) { return $false }
    return (Test-FmTasksAxiCompatible)
}

Export-ModuleMember -Function @(
    'Get-FmTasksAxiVersionPart',
    'Test-FmTasksAxiCompatible',
    'Test-FmTasksAxiUpdateHasArchiveBody',
    'Test-FmTasksAxiMvHasMultiId',
    'Get-FmBacklogBackendValue',
    'Test-FmBacklogBackendManual',
    'Test-FmTasksAxiBackendAvailable'
)
