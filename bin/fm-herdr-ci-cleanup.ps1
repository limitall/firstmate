# fm-herdr-ci-cleanup.ps1 - bounded cleanup of CI-owned Herdr lab sessions.
#
# Twin: bin/fm-herdr-ci-cleanup.sh
#
# Snapshot the session list before the real-Herdr suite, then at job end only
# stop/delete sessions that:
#   1. match the guarded fm-lab-* name pattern,
#   2. were not present in the pre-suite snapshot (job-proven ownership),
#   3. report default:false on a fresh session list.
#
# Never touches the default session. Never adopts or force-deletes non-lab
# names. Missing herdr is a no-op (exit 0) so portable jobs can call this
# harmlessly; destructive failures for known lab leftovers exit non-zero.
#
# Usage:
#   fm-herdr-ci-cleanup.ps1 snapshot <path>
#   fm-herdr-ci-cleanup.ps1 teardown <snapshot-path>
#
# ---------------------------------------------------------------------------
# THE THREE-PART OWNERSHIP TEST IS THE WHOLE SCRIPT
#
# A bare `herdr session stop` on the wrong name killed a captain's live default
# session in production. Nothing here may widen the candidate set: the name
# pattern is re-checked on every candidate even though the selector already
# applied it, and the refuse-default check is re-read from Herdr FRESH
# immediately before the stop AND again immediately before the delete, because
# a session can gain the default flag between two calls. Every refusal marks the
# run failed rather than being skipped quietly, so a job cannot go green while
# leaving a session it could not prove safe.
#
# ---------------------------------------------------------------------------
# DIVERGENCES FROM THE BASH TWIN, documented per docs/powershell-port.md
#
#   1. NO `jq is required` REFUSAL. This twin parses with ConvertFrom-Json. On
#      any host that has jq - every host the differential harness runs on - the
#      two behave identically; the snapshot file is still written in jq's exact
#      `-c` spelling so a snapshot taken by either twin is read by the other.
#   2. A snapshot file that is not valid JSON aborts with this script's own
#      diagnostic rather than jq's parse error. Same exit code, different text.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

# The bash twin names ITSELF in every diagnostic; the differential harness
# compares those bytes, so the .sh spelling is kept deliberately.
$script:FmCiPrefix = 'fm-herdr-ci-cleanup.sh'

function Write-FmCiLog {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-FmErr "$($script:FmCiPrefix): $Message"
}

# `die`: one diagnostic, exit 1. Never a raw exception (contract 3).
function Invoke-FmCiDie {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-FmCiLog $Message
    Exit-FmScript 1
}

# `herdr session list --json 2>/dev/null || die`. Returns the document text.
function Get-FmCiSessionListJson {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { Invoke-FmCiDie 'could not list Herdr sessions' }
    $result = Invoke-FmTool -FilePath $herdr.Source -Arguments @('session', 'list', '--json')
    if (-not $result.Ok) { Invoke-FmCiDie 'could not list Herdr sessions' }
    return $result.StdOut
}

# ConvertFrom-Json with the bash `2>/dev/null` disposition.
function ConvertFrom-FmCiJson {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

# The `.sessions[]?` array, always as an array.
function Get-FmCiSessionArray {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Position = 0)][AllowNull()]$Document)
    if ($null -eq $Document -or $Document -isnot [System.Collections.IDictionary]) { return @() }
    if (-not $Document.Contains('sessions')) { return @() }
    $sessions = $Document['sessions']
    if ($null -eq $sessions -or $sessions -is [System.Collections.IDictionary]) { return @() }
    if ($sessions -is [System.Collections.IEnumerable] -and $sessions -isnot [string]) { return @($sessions) }
    return @()
}

function Get-FmCiField {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Entry,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    if ($null -eq $Entry -or $Entry -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Entry.Contains($Key)) { return $null }
    return $Entry[$Key]
}

<#
.SYNOPSIS
The guarded lab-name pattern, identical to the bash `=~` test and to the
`test(...)` used inside the candidate selector.
#>
function Test-FmCiLabName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Name = '')
    return ($Name -cmatch '^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$')
}

<#
.SYNOPSIS
The `.default` field of a named session, spelled as jq -r would print it.
.DESCRIPTION
`false` is the ONLY value that permits a destructive call. Absent prints
nothing (the bash `${flag:-<not found>}` case), a null field prints `null`, and
two sessions sharing one name print two lines - all three then fail the
`!= false` test, which is the direction that refuses.
#>
function Get-FmCiDefaultFlag {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Name)

    $herdr = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $herdr) { return '' }
    $result = Invoke-FmTool -FilePath $herdr.Source -Arguments @('session', 'list', '--json')
    if (-not $result.Ok) { return '' }
    $flags = @()
    foreach ($entry in (Get-FmCiSessionArray (ConvertFrom-FmCiJson $result.StdOut))) {
        if ((Get-FmCiField $entry 'name') -ceq $Name) {
            $value = Get-FmCiField $entry 'default'
            if ($null -eq $value) { $flags += 'null' }
            elseif ($value -is [bool]) { $flags += $(if ($value) { 'true' } else { 'false' }) }
            else { $flags += [string]$value }
        }
    }
    return ($flags -join "`n")
}

# `${flag:-<not found>}`
function Get-FmCiShownFlag {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Flag = '')
    if ([string]::IsNullOrEmpty($Flag)) { return '<not found>' }
    return $Flag
}

# Captured OUTSIDE the Invoke-FmMain block: inside it, `$args` would resolve to
# that BLOCK's own (empty) argument array, so every invocation would read as
# "no arguments" and print usage (see bin/fm-operational-input.ps1).
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $argv = @($fmArgv)
    $command = if ($argv.Count -ge 1) { $argv[0] } else { '' }
    $path = if ($argv.Count -ge 2) { $argv[1] } else { '' }

    if ([string]::IsNullOrEmpty($command) -or [string]::IsNullOrEmpty($path)) {
        Invoke-FmCiDie 'usage: fm-herdr-ci-cleanup.sh snapshot|teardown <path>'
    }

    if (-not (Test-FmCommand 'herdr')) {
        Write-FmCiLog "herdr not on PATH; nothing to $command"
        Exit-FmScript 0
    }

    if ($command -ceq 'snapshot') {
        $names = @()
        foreach ($entry in (Get-FmCiSessionArray (ConvertFrom-FmCiJson (Get-FmCiSessionListJson)))) {
            $name = Get-FmCiField $entry 'name'
            if ($null -ne $name) { $names += [string]$name }
        }
        # jq's `unique` sorts by JSON collation, which for strings is ordinal.
        # PowerShell's Sort-Object is CULTURE-aware and would order `fm-lab-A`
        # against `fm-lab-a` differently, so the comparer is pinned.
        $unique = [System.Collections.Generic.SortedSet[string]]::new(
            [string[]]$names, [System.StringComparer]::Ordinal)
        $rendered = @()
        foreach ($name in $unique) { $rendered += (ConvertTo-Json -InputObject $name -Compress) }
        # Built by hand rather than through ConvertTo-Json on the array: a
        # single-element array is unrolled to a bare scalar on the way in, which
        # would emit `"x"` where jq emits `["x"]`.
        try {
            Set-FmFileText -Path $path -Text ('[' + ($rendered -join ',') + ']')
        } catch {
            Invoke-FmCiDie "failed to write session snapshot to $path"
        }
        Write-FmCiLog "wrote session snapshot to $path ($($unique.Count) names)"
        Exit-FmScript 0
    }

    if ($command -ceq 'teardown') {
        $nativePath = ConvertTo-FmNativePath $path
        if (-not [System.IO.File]::Exists($nativePath)) {
            Invoke-FmCiDie "snapshot file not found: $path"
        }
        # Wrapped in @( ) rather than assigned bare: `ConvertFrom-Json '[]'`
        # returns an EMPTY enumeration, which an assignment collapses to $null -
        # so an empty snapshot would read as unparseable and refuse a job that
        # legitimately started with no sessions.
        $before = @()
        try {
            $before = [string[]]@(ConvertFrom-Json -InputObject (Get-FmFileText $path) -AsHashtable)
        } catch {
            Invoke-FmCiDie "could not read session snapshot: $path"
        }

        $candidates = @()
        foreach ($entry in (Get-FmCiSessionArray (ConvertFrom-FmCiJson (Get-FmCiSessionListJson)))) {
            if ((Get-FmCiField $entry 'default') -ne $false) { continue }
            $name = [string](Get-FmCiField $entry 'name')
            if (-not (Test-FmCiLabName $name)) { continue }
            if ($before -ccontains $name) { continue }
            $candidates += $name
        }

        if ($candidates.Count -eq 0) {
            Write-FmCiLog 'no job-owned fm-lab-* sessions to clean'
            Exit-FmScript 0
        }

        $herdr = (Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $failed = 0
        foreach ($name in $candidates) {
            if ([string]::IsNullOrEmpty($name)) { continue }
            if (-not (Test-FmCiLabName $name)) {
                Write-FmCiLog "refusing non-lab name from candidate set: $name"
                $failed = 1
                continue
            }
            # Fresh refuse-default check immediately before each destructive call.
            $flag = Get-FmCiDefaultFlag $name
            if ($flag -cne 'false') {
                Write-FmCiLog "refusing cleanup of '$name' (default=$(Get-FmCiShownFlag $flag))"
                $failed = 1
                continue
            }
            Write-FmCiLog "stopping job-owned lab session $name"
            [void](Invoke-FmTool -FilePath $herdr -Arguments @('session', 'stop', $name, '--json'))
            Start-Sleep -Milliseconds 300
            $flag = Get-FmCiDefaultFlag $name
            if ($flag -cne 'false') {
                Write-FmCiLog "refusing delete of '$name' after stop (default=$(Get-FmCiShownFlag $flag))"
                $failed = 1
                continue
            }
            $deleted = Invoke-FmTool -FilePath $herdr -Arguments @('session', 'delete', $name, '--json')
            if ($deleted.Ok) {
                Write-FmCiLog "deleted job-owned lab session $name"
                continue
            }
            # Already gone is success; still present is failure.
            $still = ''
            $listing = Invoke-FmTool -FilePath $herdr -Arguments @('session', 'list', '--json')
            if ($listing.Ok) {
                foreach ($entry in (Get-FmCiSessionArray (ConvertFrom-FmCiJson $listing.StdOut))) {
                    if ((Get-FmCiField $entry 'name') -ceq $name) { $still = $name }
                }
            }
            if (-not [string]::IsNullOrEmpty($still)) {
                Write-FmCiLog "failed to delete lab session $name"
                $failed = 1
            } else {
                Write-FmCiLog "lab session $name already absent after stop"
            }
        }
        if ($failed -ne 0) {
            Invoke-FmCiDie 'one or more job-owned lab sessions could not be cleaned'
        }
        Exit-FmScript 0
    }

    Invoke-FmCiDie "unknown command: $command (use snapshot or teardown)"
}
