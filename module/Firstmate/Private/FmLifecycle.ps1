#requires -Version 7.0
# FmLifecycle.ps1 - shared internals for the task-lifecycle area (brief,
# classify, teardown, merge, crew-state). Ports the small helpers the bash
# lifecycle scripts each carried inline: home/state/data resolution
# (bin/fm-brief.sh, bin/fm-teardown.sh headers), `fm_meta_get`
# (bin/fm-backend.sh), and the LF-only file writing every generated firstmate
# artifact depends on.
#
# Nothing here shells out to a POSIX tool. Git and the CLIs firstmate already
# depends on (treehouse, gh, no-mistakes) run through the module's shared
# Invoke-FmChildProcess / Invoke-FmGit, which keep stdout and stderr separate so
# a refusal can quote the exact stderr the bash scripts quoted. The LF-only text
# writer and the `fm_meta_get` reader are likewise the module's shared
# Write-FmTextFileLf and Get-FmMetaValue rather than copies.

Set-StrictMode -Version Latest

$script:FmLifecyclePrivateDir = $PSScriptRoot

# Repo root: Private/ -> Firstmate/ -> module/ -> <repo>. FM_ROOT_OVERRIDE wins,
# exactly as every bash entry point resolves FM_ROOT.
function Get-FmLifecycleRoot {
    [CmdletBinding()]
    param()
    if ($env:FM_ROOT_OVERRIDE) { return $env:FM_ROOT_OVERRIDE }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:FmLifecyclePrivateDir)))
}

# Port of resolve_directory_input (bin/fm-brief.sh): an absolute path is taken
# verbatim; a relative one must resolve to a real directory or the caller stops.
function Resolve-FmLifecycleDirectoryInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath } catch { $resolved = $null }
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "error: $Name directory cannot be resolved: $Path"
    }
    return $resolved
}

# The FM_HOME / state / data / config quartet every lifecycle script resolves
# the same way, honouring the same override variables so a Windows firstmate and
# a Linux one address the identical home.
function Get-FmLifecyclePaths {
    [CmdletBinding()]
    param()
    $root = Get-FmLifecycleRoot
    $homeInput = if ($env:FM_HOME) { $env:FM_HOME } elseif ($env:FM_ROOT_OVERRIDE) { $env:FM_ROOT_OVERRIDE } else { $root }
    $fmHome = Resolve-FmLifecycleDirectoryInput -Name 'FM_HOME' -Path $homeInput
    $state = if ($env:FM_STATE_OVERRIDE) { Resolve-FmLifecycleDirectoryInput -Name 'FM_STATE_OVERRIDE' -Path $env:FM_STATE_OVERRIDE } else { Join-Path $fmHome 'state' }
    $data = if ($env:FM_DATA_OVERRIDE) { Resolve-FmLifecycleDirectoryInput -Name 'FM_DATA_OVERRIDE' -Path $env:FM_DATA_OVERRIDE } else { Join-Path $fmHome 'data' }
    $config = if ($env:FM_CONFIG_OVERRIDE) { Resolve-FmLifecycleDirectoryInput -Name 'FM_CONFIG_OVERRIDE' -Path $env:FM_CONFIG_OVERRIDE } else { Join-Path $fmHome 'config' }
    [pscustomobject]@{
        Root   = $root
        Home   = $fmHome
        State  = $state
        Data   = $data
        Config = $config
    }
}

# Read a text file as lines without inventing a trailing empty line, tolerating
# CRLF so a file written by a Windows editor still parses. Firstmate's own
# writes stay LF-only (Write-FmTextFileLf).
function Get-FmLifecycleFileLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -eq 0) { return , @() }
    $text = $text -replace "`r`n", "`n"
    $lines = $text.Split("`n")
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    return , [string[]]$lines
}

# fm_task_id_path_safe: a task id is a single path component, never a traversal.
function Test-FmLifecycleTaskIdPathSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    if ($Id -eq '.' -or $Id -eq '..') { return $false }
    if ($Id -match '[\\/]') { return $false }
    if ($Id.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
    return $true
}

# First line of a git read, or '' - the `$(git ...)` idiom. Distinct from the
# shared Get-FmGitOutput, which returns the whole trimmed output: the lifecycle
# reads that use this are single-value (`rev-parse`, `symbolic-ref`) or must take
# only the first line the way the bash `| head -1` does.
function Get-FmGitFirstLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    if (-not $Result.Ok) { return '' }
    $out = $Result.StdOut -replace "`r`n", "`n"
    $out = $out.Trim("`n")
    if ($out -eq '') { return '' }
    return $out.Split("`n")[0].Trim()
}

# Is <path> an ordinary file that is not a symlink/reparse point? The bash
# scripts spell this `[ -f "$f" ] && [ ! -L "$f" ]` before trusting a private
# record; the same rule keeps a symlinked state file from escaping the home.
function Test-FmLifecycleRegularFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if ($item.PSIsContainer) { return $false }
    if ($item.LinkTarget) { return $false }
    return $true
}

function Test-FmLifecycleRegularDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (-not $item.PSIsContainer) { return $false }
    if ($item.LinkTarget) { return $false }
    return $true
}

# Write one line to stderr the way the bash scripts do (`echo ... >&2`), without
# turning it into a PowerShell error record a caller might trap.
function Write-FmLifecycleStdErr {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    [Console]::Error.WriteLine($Message)
}
