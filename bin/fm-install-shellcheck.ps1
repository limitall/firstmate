# bin/fm-install-shellcheck.ps1 - install CI's pinned, verified ShellCheck build.
#
# Twin: bin/fm-install-shellcheck.sh
#
# Usage:
#   fm-install-shellcheck.ps1 <destination-directory>
#
# ---------------------------------------------------------------------------
# THE PIN IS THE POINT, SO NOTHING NATIVE REPLACES A CHECK
#
# The pinned version comes from bin/fm-lint.sh's --required-version - resolved
# through Invoke-FmScript so it keeps working whichever side of the conversion
# fm-lint is on - and both the Unix tarball and the Windows zip carry their own
# SHA-256 from the SAME release. Get-FileHash and Expand-Archive would each work
# and would each CHANGE A VERDICT: this twin would install on a host the bash
# twin refuses for want of unzip, and it would accept an asset on a host with no
# sha256sum. While both trees are live, they must accept and refuse the same
# hosts, so curl, sha256sum, unzip and tar stay external, with the same argv,
# the same retry budget, and the same refusal sentences.
#
# Native PowerShell is used only where no verdict rides on it: directory
# creation and the copy that replaces `install -m 0755` (0755 is inert on
# Windows - the noacl rule in docs/powershell-port.md).
#
# Documented divergence: bash's `${1:?usage: ...}` prints a shell diagnostic
# carrying a line number; this twin prints the same usage sentence as one clean
# line and exits 1.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

$FmScSha256 = '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198'
# Windows asset from the SAME pinned release; re-pin both together when
# fm-lint's required version moves.
$FmScSha256Windows = '8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e'
$FmScDownloadAttempts = 3

function Write-FmDie {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-FmErr "fm-install-shellcheck.ps1: $Message"
    Exit-FmScript 1
}

# See bin/fm-install-herdr.ps1 for why platform selection goes through uname.
function Get-FmUnameValue {
    param([Parameter(Mandatory, Position = 0)][ValidateSet('-s', '-m')][string]$Flag)
    $cmd = Get-Command 'uname' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        $result = Invoke-FmTool $cmd.Source @($Flag)
        if ($result.Ok) {
            $first = @($result.StdOut -split "`n")[0]
            if ($first) { return $first.Trim() }
        }
    }
    if ($Flag -eq '-s') {
        if ($IsWindows) { return 'MINGW64_NT-10.0' }
        if ($IsMacOS) { return 'Darwin' }
        return 'Linux'
    }
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { return 'aarch64' }
        'X64' { return 'x86_64' }
        'X86' { return 'i686' }
        default { return 'unknown' }
    }
}

function New-FmScratchDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A private scratch directory under the caller-selected temp root, the twin of `mktemp -d`, removed again by this script. -WhatIf/-Confirm on it would diverge from the bash twin and stall a non-interactive CI install.')]
    param([Parameter(Mandatory, Position = 0)][string]$Prefix)
    $base = Get-FmEnv 'RUNNER_TEMP'
    if (-not $base) { $base = Get-FmEnv 'TMPDIR' }
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    $base = ConvertTo-FmNativePath $base
    $dir = Join-Path $base ("{0}.{1}" -f $Prefix, [System.IO.Path]::GetRandomFileName())
    [void][System.IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Get-FmSha256Hex {
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $sha256sum = Get-Command 'sha256sum' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sha256sum) { return '' }
    $hashed = Invoke-FmTool $sha256sum.Source @($Path)
    $hex = @(@($hashed.StdOut -split "`n")[0] -split '\s+')[0]
    # GNU coreutils ESCAPES a checksum line whose filename contains a
    # backslash by prefixing the whole line with one, so a native Windows
    # path yields "\<hash>  C:\...". The bash twin never sees this because it
    # hands sha256sum a POSIX path; strip it so both trees compare the same
    # 64 hex digits.
    $hex = $hex.TrimStart([char]92)
    return $hex
}

# --- Windows (Git Bash/MSYS2/Cygwin) ----------------------------------------
#
# ShellCheck publishes a Windows zip in the same pinned release the Unix path
# already uses, so Windows gets the identical discipline: exact version, exact
# asset, SHA-256 pin, bounded retries, post-install version check, and the
# binary landing in the caller's <destination-directory>. That asset is the
# PRIMARY route precisely because it is the only one that can satisfy all of
# those at once.
# winget is the fallback for a host that cannot fetch or unpack the asset, and
# it is accepted only when it lands the pinned version, because a floating
# package-manager latest must never satisfy a pinned installer. It is
# deliberately not first: it mutates system state outside <destination-directory>,
# which no caller of a "put this build in this directory" script asks for.
# Everything below is unreachable off Windows, so the Unix path is identical.

function Get-FmWindowsShellCheckVersion {
    param([Parameter(Mandatory, Position = 0)][string]$Binary)
    $run = Invoke-FmTool $Binary @('--version')
    foreach ($line in @($run.StdOut -split "`n")) {
        if ($line.StartsWith('version: ')) { return $line.Substring('version: '.Length) }
    }
    return ''
}

# winget does not refresh the running shell's PATH, so resolve its portable-shim
# directory explicitly as well as through PATH.
function Get-FmWindowsShellCheckCandidate {
    $candidates = @()
    $onPath = Get-Command 'shellcheck' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates += $onPath.Source }
    $localApp = Get-FmEnv 'LOCALAPPDATA'
    if ($localApp) {
        $candidates += (Join-Path (ConvertTo-FmNativePath $localApp) 'Microsoft\WinGet\Links\shellcheck.exe')
    }
    return $candidates
}

# Fallback route. Returns $false when winget is absent or could not land the pin.
function Install-FmShellCheckFromWinget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An installer script twin whose bash original installs unconditionally; a confirmation surface would diverge from the twin and stall CI.')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Version,
        [Parameter(Mandatory, Position = 1)][string]$Destination
    )
    $winget = Get-Command 'winget' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { return $false }
    Write-FmErr 'fm-install-shellcheck.ps1: installing ShellCheck via winget'
    $run = Invoke-FmTool $winget.Source @('install', '--id', 'koalaman.shellcheck', '-e',
        '--accept-source-agreements', '--accept-package-agreements')
    if ($run.StdOut) { [Console]::Error.Write($run.StdOut) }
    if ($run.StdErr) { [Console]::Error.Write($run.StdErr) }
    if (-not $run.Ok) { return $false }
    foreach ($candidate in (Get-FmWindowsShellCheckCandidate)) {
        if (-not $candidate) { continue }
        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $candidate))) { continue }
        if ((Get-FmWindowsShellCheckVersion $candidate) -cne $Version) { continue }
        $destNative = ConvertTo-FmNativePath $Destination
        try {
            [void][System.IO.Directory]::CreateDirectory($destNative)
            [System.IO.File]::Copy((ConvertTo-FmNativePath $candidate), (Join-Path $destNative 'shellcheck.exe'), $true)
        } catch {
            return $false
        }
        return $true
    }
    Write-FmErr "fm-install-shellcheck.ps1: winget did not provide pinned v$Version"
    return $false
}

# Primary route. Returns $false only when the asset could not be FETCHED or
# unpacked at all - no unzip, or the download exhausted its retries - so the
# caller can try winget. An integrity failure always dies instead: falling back
# after a checksum mismatch or a zip with no shellcheck.exe would defeat the pin.
function Install-FmShellCheckFromPinnedZip {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An installer script twin whose bash original installs unconditionally; a confirmation surface would diverge from the twin and stall CI.')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Version,
        [Parameter(Mandatory, Position = 1)][string]$Destination,
        [Parameter(Mandatory, Position = 2)][string]$Tmp
    )
    $archive = "shellcheck-v$Version.zip"
    $url = "https://github.com/koalaman/shellcheck/releases/download/v$Version/$archive"
    $unzip = Get-Command 'unzip' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $unzip) { return $false }
    $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $archivePath = Join-Path $Tmp $archive
    $attempt = 1
    while ($true) {
        $fetch = if ($curl) { Invoke-FmTool $curl.Source @('-fsSL', $url, '-o', $archivePath) } else { @{ Ok = $false } }
        if ($fetch.Ok) { break }
        if ($attempt -ge $FmScDownloadAttempts) { return $false }
        Write-FmErr "fm-install-shellcheck.ps1: download attempt $attempt failed; retrying"
        Start-Sleep -Seconds $attempt
        $attempt++
    }
    $actual = Get-FmSha256Hex $archivePath
    if ($actual -cne $FmScSha256Windows) { Write-FmDie "checksum mismatch for $archive" }
    $windowsDir = Join-Path $Tmp 'windows'
    $extract = Invoke-FmTool $unzip.Source @('-q', '-o', $archivePath, '-d', $windowsDir)
    if (-not $extract.Ok) { Write-FmDie "could not extract $archive" }
    # Archive layout: shellcheck.exe beside LICENSE.txt at the zip root (v0.11.0).
    $exe = Join-Path $windowsDir 'shellcheck.exe'
    if (-not [System.IO.File]::Exists($exe)) { Write-FmDie "archive $archive did not contain shellcheck.exe" }
    $destNative = ConvertTo-FmNativePath $Destination
    [void][System.IO.Directory]::CreateDirectory($destNative)
    [System.IO.File]::Copy($exe, (Join-Path $destNative 'shellcheck.exe'), $true)
    return $true
}

Invoke-FmMain -UnexpectedCode 70 {
    $versionRun = Invoke-FmScript 'fm-lint' @('--required-version') -BinDir $PSScriptRoot
    if (-not $versionRun.Ok) {
        Write-FmErr $versionRun.StdErr.TrimEnd("`n")
        Exit-FmScript $versionRun.ExitCode
    }
    $version = @($versionRun.StdOut -split "`n")[0].Trim()

    $archive = "shellcheck-v$version.linux.x86_64.tar.xz"
    $url = "https://github.com/koalaman/shellcheck/releases/download/v$version/$archive"

    if ($fmArgv.Count -lt 1 -or [string]::IsNullOrEmpty([string]$fmArgv[0])) {
        Write-FmErr 'fm-install-shellcheck.ps1: usage: fm-install-shellcheck.ps1 <destination-directory>'
        Exit-FmScript 1
    }
    $destination = [string]$fmArgv[0]

    $tmp = New-FmScratchDir 'fm-shellcheck'
    try {
        if ((Get-FmUnameValue '-s') -match '^(MINGW|MSYS|CYGWIN)') {
            if (-not (Install-FmShellCheckFromPinnedZip $version $destination $tmp)) {
                if (-not (Install-FmShellCheckFromWinget $version $destination)) {
                    Write-FmDie ("could not install pinned ShellCheck v${version}: the release asset was " +
                        'unreachable (needs curl and unzip) and winget could not provide that version; install ' +
                        "ShellCheck v$version manually into $destination")
                }
            }
            $installedExe = Join-Path (ConvertTo-FmNativePath $destination) 'shellcheck.exe'
            if ((Get-FmWindowsShellCheckVersion $installedExe) -cne $version) {
                Write-FmDie "installed ShellCheck is not the pinned v$version"
            }
            $show = Invoke-FmTool $installedExe @('--version')
            if ($show.StdOut) { Write-FmRaw $show.StdOut }
            if ($show.StdErr) { [Console]::Error.Write($show.StdErr) }
            Exit-FmScript 0
        }

        $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $archivePath = Join-Path $tmp $archive
        $attempt = 1
        while ($true) {
            $fetch = if ($curl) { Invoke-FmTool $curl.Source @('-fsSL', $url, '-o', $archivePath) } else { @{ Ok = $false } }
            if ($fetch.Ok) { break }
            if ($attempt -ge $FmScDownloadAttempts) {
                Write-FmErr "fm-install-shellcheck.ps1: download failed after $FmScDownloadAttempts attempts"
                Exit-FmScript 1
            }
            Write-FmErr "fm-install-shellcheck.ps1: download attempt $attempt failed; retrying"
            Start-Sleep -Seconds $attempt
            $attempt++
        }
        $actual = Get-FmSha256Hex $archivePath
        if ($actual -cne $FmScSha256) {
            Write-FmErr "fm-install-shellcheck.ps1: checksum mismatch for $archive"
            Exit-FmScript 1
        }
        $tar = Get-Command 'tar' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $tar) { Exit-FmScript 1 }
        $untar = Invoke-FmTool $tar.Source @('-xJf', $archivePath, '-C', $tmp)
        if (-not $untar.Ok) {
            if ($untar.StdErr) { [Console]::Error.Write($untar.StdErr) }
            Exit-FmScript $untar.ExitCode
        }
        $destNative = ConvertTo-FmNativePath $destination
        [void][System.IO.Directory]::CreateDirectory($destNative)
        $installed = Join-Path $destNative 'shellcheck'
        [System.IO.File]::Copy((Join-Path $tmp (Join-Path "shellcheck-v$version" 'shellcheck')), $installed, $true)
        $show = Invoke-FmTool $installed @('--version')
        if ($show.StdOut) { Write-FmRaw $show.StdOut }
        if ($show.StdErr) { [Console]::Error.Write($show.StdErr) }
        Exit-FmScript $show.ExitCode
    } finally {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { $null = $_ }
    }
}
