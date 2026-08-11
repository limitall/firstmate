#requires -Version 7.0
# FmLifecycle.ps1 - shared internals for the task-lifecycle area (brief,
# classify, teardown, merge, crew-state). Ports the small helpers the bash
# lifecycle scripts each carried inline: home/state/data resolution
# (bin/fm-brief.sh, bin/fm-teardown.sh headers), `fm_meta_get`
# (bin/fm-backend.sh), and the LF-only file writing every generated firstmate
# artifact depends on.
#
# Nothing here shells out to a POSIX tool. Git and the CLIs firstmate already
# depends on (treehouse, gh, no-mistakes) are invoked through
# Invoke-FmLifecycleProcess, which keeps stdout and stderr separate so a
# refusal can quote the exact stderr the bash scripts quoted.

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
# writes stay LF-only (Write-FmLifecycleText).
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

# Every firstmate artifact is LF-terminated UTF-8 without a BOM, on every
# platform: a Linux firstmate and this one read each other's files.
function Write-FmLifecycleText {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'write')) { return }
    $normalized = $Text -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

# fm_meta_get (bin/fm-backend.sh): the LAST value of `key=` in a meta file, or
# empty when the file or key is absent. Never throws.
function Get-FmLifecycleMetaValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )
    $value = ''
    foreach ($line in (Get-FmLifecycleFileLines -Path $Path)) {
        if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1) }
    }
    return $value
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

# Run a native command with stdout and stderr kept apart. PowerShell's operator
# redirection folds native stderr into the error stream, which loses the exact
# text a refusal has to quote, so the lifecycle area uses Process directly.
function Invoke-FmLifecycleProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 0
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return [pscustomobject]@{ ExitCode = 127; StdOut = ''; StdErr = "$($_.Exception.Message)"; TimedOut = $false }
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { }
        }
    }
    $proc.WaitForExit()
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        TimedOut = $timedOut
    }
}

# `git -C <dir> ...`, the one shape every lifecycle git read uses.
function Invoke-FmGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoPath,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments
    )
    $argv = @('-C', $RepoPath) + $Arguments
    return Invoke-FmLifecycleProcess -FilePath 'git' -Arguments $argv
}

function Test-FmGitSucceeded {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    return ($Result.ExitCode -eq 0)
}

# Trimmed first line of a git read, or '' - the `$(git ...)` idiom.
function Get-FmGitOutputLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)
    if ($Result.ExitCode -ne 0) { return '' }
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
