# bin/fm-install-treehouse.ps1 - install CI's pinned, verified Treehouse build.
#
# Twin: bin/fm-install-treehouse.sh
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need treehouse (spawn worktree acquisition). Same pin/checksum discipline as
# fm-install-herdr.ps1: official release URL, exact asset, SHA-256, bounded
# download, post-install version check. Never a floating package-manager latest.
#
# Usage:
#   fm-install-treehouse.ps1 <destination-directory>
#
# Pins Treehouse v2.0.1, the version exercised by the local real-Herdr suite.
# Linux, macOS, and Windows (Git Bash/MSYS2/Cygwin) are all supported: the
# Windows assets are zips holding treehouse.exe, so the only platform delta is
# the extractor and the installed file name.
#
# ---------------------------------------------------------------------------
# WHY unzip/tar AND sha256sum ARE STILL EXTERNAL HERE
#
# Expand-Archive and Get-FileHash would both work and both would CHANGE A
# VERDICT: this twin would then install on a host where the bash twin refuses
# for want of unzip, and its "need sha256sum or shasum" refusal would become
# unreachable. While both trees are live against the same CI lane they must
# accept and refuse exactly the same hosts, so the external tools, their
# presence checks, their argv, and their refusal sentences are all ported
# literally. curl stays external for the same reason plus one more: only curl
# gives --max-filesize, and the BOUNDED download is part of the pin.
#
# Native PowerShell is used only where no verdict rides on it: directory
# creation, the file copy that replaces `install -m 0755` (0755 is inert on
# Windows - see the noacl rule in docs/powershell-port.md), and the recursive
# search that replaces `find`.
#
# Documented divergence: bash's `${1:?usage: ...}` prints a shell diagnostic
# carrying a line number. This twin prints the same usage sentence as one clean
# line and exits 1.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

$FmTreehouseCiVersion = '2.0.1'
$FmTreehouseCiTag = "v$FmTreehouseCiVersion"
# Bounded download ceiling (bytes). Official 2.0.1 archives are under 8 MiB.
$FmTreehouseCiMaxBytes = 15000000
$FmTreehouseCiRepo = 'kunchenguid/treehouse'

function Write-FmDie {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-FmErr "fm-install-treehouse.ps1: $Message"
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

Invoke-FmMain -UnexpectedCode 70 {
    if ($fmArgv.Count -lt 1 -or [string]::IsNullOrEmpty([string]$fmArgv[0])) {
        Write-FmErr 'fm-install-treehouse.ps1: usage: fm-install-treehouse.ps1 <destination-directory>'
        Exit-FmScript 1
    }
    $destination = [string]$fmArgv[0]

    $os = Get-FmUnameValue '-s'
    $arch = Get-FmUnameValue '-m'

    $archive = ''
    $sha256 = ''
    switch -Regex ("$os-$arch") {
        '^Linux-x86_64$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-linux-amd64.tar.gz"
            $sha256 = '1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2'
            break
        }
        '^Linux-(aarch64|arm64)$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-linux-arm64.tar.gz"
            $sha256 = 'eaccc9c5b98125df8bd77425598eeecee66cb0371db4eb1cf75f0d813c18fab9'
            break
        }
        '^Darwin-arm64$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-darwin-arm64.tar.gz"
            $sha256 = '7ee5078f3d1f33c01196548797fce65408e459d53530b77d4ba56e074fa1c1a2'
            break
        }
        '^Darwin-x86_64$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-darwin-amd64.tar.gz"
            $sha256 = '1cf44580a5837f995e1d3bb74f4fbd3112b642acd20406087d9735a8106112fd'
            break
        }
        # Windows (Git Bash/MSYS2/Cygwin). Treehouse ships official windows-amd64
        # and windows-arm64 zips in the same pinned release, and the extracted
        # treehouse.exe reports `v2.0.1` and advertises `get --lease` exactly like
        # the Unix builds, so the worktree provider every spawn depends on is
        # genuinely available here. These SHA-256 values come from the release's
        # own checksums.txt, which also reproduces all four Unix pins above.
        '^(MINGW|MSYS|CYGWIN).*-x86_64$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-windows-amd64.zip"
            $sha256 = 'd4c7bebc876b6dc1f9cf2f2b934803234d4f2f6e1c1c314505db85e64f5100bc'
            break
        }
        '^(MINGW|MSYS|CYGWIN).*-(aarch64|arm64)$' {
            $archive = "treehouse-v$FmTreehouseCiVersion-windows-arm64.zip"
            $sha256 = '4cb39138565822c26f694a5594787b770296061247cc6f3a3b6852d7c4212381'
            break
        }
        default {
            Write-FmDie ("unsupported platform ${os}-${arch}; official Treehouse assets are " +
                'linux/darwin/windows amd64 and arm64')
        }
    }

    # The Windows assets are zips holding treehouse.exe; every Unix asset stays a
    # gzip tarball holding treehouse. BinName keeps the Unix path identical.
    $binName = 'treehouse'
    $unzip = $null
    if ($archive.EndsWith('.zip')) {
        $binName = 'treehouse.exe'
        $unzip = Get-Command 'unzip' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $unzip) { Write-FmDie "need unzip to extract $archive (MSYS2: pacman -S unzip)" }
    }

    $url = "https://github.com/$FmTreehouseCiRepo/releases/download/$FmTreehouseCiTag/$archive"
    $tmp = New-FmScratchDir 'fm-treehouse'
    try {
        $archivePath = Join-Path $tmp $archive

        Write-FmErr "fm-install-treehouse.ps1: downloading $archive from $url"
        $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $downloaded = $false
        if ($curl) {
            $fetch = Invoke-FmTool $curl.Source @('-fsSL', '--max-filesize', "$FmTreehouseCiMaxBytes", $url, '-o', $archivePath)
            $downloaded = $fetch.Ok
        }
        if (-not $downloaded) {
            Write-FmDie "download failed for $url (bounded at $FmTreehouseCiMaxBytes bytes)"
        }

        $actualSha256 = ''
        # GNU coreutils ESCAPES a checksum line whose filename contains a
        # backslash by prefixing the whole line with one, so a native
        # Windows path yields "\<hash>  C:\..." and the first field is the
        # hash with a leading backslash. The bash twin never sees this
        # because it hands sha256sum a POSIX path; strip it so both trees
        # compare the same 64 hex digits.
        $sha256sum = Get-Command 'sha256sum' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $shasum = Get-Command 'shasum' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sha256sum) {
            $hashed = Invoke-FmTool $sha256sum.Source @($archivePath)
            $actualSha256 = @(@($hashed.StdOut -split "`n")[0] -split '\s+')[0]
            $actualSha256 = $actualSha256.TrimStart([char]92)
        } elseif ($shasum) {
            $hashed = Invoke-FmTool $shasum.Source @('-a', '256', $archivePath)
            $actualSha256 = @(@($hashed.StdOut -split "`n")[0] -split '\s+')[0]
            $actualSha256 = $actualSha256.TrimStart([char]92)
        } else {
            Write-FmDie 'need sha256sum or shasum to verify the Treehouse archive'
        }

        if ($actualSha256 -cne $sha256) {
            Write-FmDie "checksum mismatch for $archive (expected $sha256, got $actualSha256)"
        }

        if ($archive.EndsWith('.zip')) {
            $extract = Invoke-FmTool $unzip.Source @('-q', '-o', $archivePath, '-d', $tmp)
            if (-not $extract.Ok) { Write-FmDie "could not extract $archive" }
        } else {
            $tar = Get-Command 'tar' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $tar) { Write-FmDie "could not extract $archive" }
            $extract = Invoke-FmTool $tar.Source @('-xzf', $archivePath, '-C', $tmp)
            if (-not $extract.Ok) { Write-FmDie "could not extract $archive" }
        }

        # Archive layout: a single `treehouse` binary at the archive root
        # (verified for v2.0.1 on Unix and Windows alike).
        $bin = ''
        $flat = Join-Path $tmp $binName
        $nested = Join-Path $tmp (Join-Path "treehouse-v$FmTreehouseCiVersion" $binName)
        if ([System.IO.File]::Exists($flat)) {
            $bin = $flat
        } elseif ([System.IO.File]::Exists($nested)) {
            $bin = $nested
        } else {
            $found = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Filter $binName -ErrorAction SilentlyContinue)
            if ($found.Count -gt 0) { $bin = $found[0].FullName }
            if (-not $bin) { Write-FmDie "archive $archive did not contain a treehouse binary" }
        }

        $destNative = ConvertTo-FmNativePath $destination
        [void][System.IO.Directory]::CreateDirectory($destNative)
        $installed = Join-Path $destNative $binName
        [System.IO.File]::Copy($bin, $installed, $true)

        # treehouse prints "v2.0.1" (leading v) on --version.
        $versionRun = Invoke-FmTool $installed @('--version')
        $installedVersion = ($versionRun.StdOut -replace '\s', '')
        if ($installedVersion -cne "v$FmTreehouseCiVersion" -and $installedVersion -cne $FmTreehouseCiVersion) {
            $shown = if ($installedVersion) { $installedVersion } else { '<empty>' }
            Write-FmDie "installed treehouse version is '$shown', expected exact pin v$FmTreehouseCiVersion"
        }

        Write-FmErr "fm-install-treehouse.ps1: installed treehouse $installedVersion to $destination/$binName"
        $final = Invoke-FmTool $installed @('--version')
        if ($final.StdOut) { Write-FmRaw $final.StdOut }
        if ($final.StdErr) { [Console]::Error.Write($final.StdErr) }
        Exit-FmScript $final.ExitCode
    } finally {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { $null = $_ }
    }
}
