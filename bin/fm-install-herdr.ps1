# bin/fm-install-herdr.ps1 - install CI's pinned, verified Herdr build.
#
# Twin: bin/fm-install-herdr.sh
#
# Single owner of the exact Herdr version, official release asset URL, and
# SHA-256 pin used by the required real-Herdr CI lane. Never installs a
# floating package-manager latest.
#
# Usage:
#   fm-install-herdr.ps1 <destination-directory>
#
# Pins Herdr v0.7.4 (protocol 16), the suite-verified protocol-16 release.
# Selects the official GitHub Releases asset for the host OS/arch, downloads
# with a bounded max size, verifies SHA-256 before install, then refuses to
# finish unless the binary reports the exact pin version and a client protocol
# at or above the required floor (16 for the real-Herdr family).
#
# ---------------------------------------------------------------------------
# WHY THIS TWIN SHELLS OUT WHERE POWERSHELL HAS A NATIVE ANSWER
#
# PowerShell can hash a file with Get-FileHash and fetch one with
# Invoke-WebRequest, and using either here would CHANGE A VERDICT:
#
#   - Get-FileHash always succeeds, so the twin's "need sha256sum or shasum"
#     refusal would become unreachable and a host the bash twin refuses would be
#     silently accepted. The pin is a trust boundary; the two trees must refuse
#     the same hosts while both are live.
#   - Invoke-WebRequest has no --max-filesize, so the BOUNDED download - a
#     documented part of the pin - would quietly become unbounded.
#
# So curl and sha256sum/shasum are invoked through Invoke-FmTool exactly as the
# bash twin invokes them, in the same order, with the same argv and the same
# messages. Only `mkdir -p` and `install -m 0755` are done natively: those carry
# no verdict, and the 0755 mode is inert on Windows anyway (the noacl rule in
# docs/powershell-port.md - a PS twin must not enforce ACLs the bash twin
# cannot).
#
# jq is the one deliberate substitution: docs/powershell-port.md makes
# ConvertFrom-Json the replacement for every jq invocation in the port, so the
# bash twin's "jq is required to parse herdr status after install" refusal
# cannot fire here. Unparseable status still lands on the SAME next refusal
# ("could not read herdr client protocol from status --json"), so no status
# output the bash twin rejects is accepted here.
#
# One further documented divergence: bash's `${1:?usage: ...}` produces a shell
# diagnostic naming a line number. This twin prints the same usage sentence as a
# single clean line and exits 1 with it, because reproducing bash's shell noise
# would be reproducing an artifact, not a contract.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

# Exact pin - change only with a re-verified real-Herdr matrix.
$FmHerdrCiVersion = '0.7.4'
$FmHerdrCiTag = "v$FmHerdrCiVersion"
$FmHerdrCiMinProtocol = 16
# Bounded download ceiling (bytes). The largest official 0.7.4 asset is under 20 MiB.
$FmHerdrCiMaxBytes = 25000000
$FmHerdrCiRepo = 'ogulcancelik/herdr'

function Write-FmDie {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-FmErr "fm-install-herdr.ps1: $Message"
    Exit-FmScript 1
}

# `uname -s` / `uname -m`, because the bash twin's platform arms are keyed on
# exactly those strings and both trees must select the same asset from the same
# host. uname is present wherever the bash twin runs (Git Bash, MSYS2, CI); the
# native fallback keeps a bare-pwsh host from failing for want of it, and
# reports the MINGW form so the Windows arm below is the one that matches.
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

# mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr.XXXXXX"
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
        Write-FmErr 'fm-install-herdr.ps1: usage: fm-install-herdr.ps1 <destination-directory>'
        Exit-FmScript 1
    }
    # The destination is echoed back verbatim in the install message, exactly as
    # the bash twin echoes "$DESTINATION", so a POSIX-form argument stays
    # POSIX-form in output; only filesystem calls see the native conversion.
    $destination = [string]$fmArgv[0]

    $os = Get-FmUnameValue '-s'
    $arch = Get-FmUnameValue '-m'

    $asset = ''
    $sha256 = ''
    switch -Regex ("$os-$arch") {
        '^Linux-x86_64$' {
            $asset = 'herdr-linux-x86_64'
            $sha256 = 'bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059'
            break
        }
        '^Linux-(aarch64|arm64)$' {
            $asset = 'herdr-linux-aarch64'
            $sha256 = '544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2'
            break
        }
        '^Darwin-arm64$' {
            $asset = 'herdr-macos-aarch64'
            $sha256 = '24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7'
            break
        }
        '^Darwin-x86_64$' {
            $asset = 'herdr-macos-x86_64'
            $sha256 = 'ddf430133352e1712413d5d865b34a485546f4658893fc89986257d65a7585a8'
            break
        }
        # Windows (Git Bash/MSYS2/Cygwin). No STABLE release carries a Windows
        # asset yet - neither the pinned v0.7.4 nor the current v0.7.5 - so this
        # pinned CI installer has nothing to fetch and refuses here, before any
        # download, rather than 404 mid-install on an asset URL that cannot
        # exist. Windows builds DO exist in PREVIEW releases, and docs/windows.md
        # owns that install route. Pinning one here is an open decision rather
        # than an oversight: a preview pin needs its own verified version and
        # SHA-256, so it belongs as another arm above, replacing this refusal.
        '^(MINGW|MSYS|CYGWIN)' {
            Write-FmDie ("no stable Herdr release carries a Windows asset yet (the pinned v$FmHerdrCiVersion " +
                "is linux/macos only), so this pinned CI installer cannot run on ${os}; Windows builds ship in " +
                'preview releases (tag preview-2026-07-29-44b3adb12552, asset herdr-windows-x86_64.zip) - see ' +
                'docs/windows.md for the Windows install route')
        }
        default {
            Write-FmDie "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
        }
    }

    $url = "https://github.com/$FmHerdrCiRepo/releases/download/$FmHerdrCiTag/$asset"
    $tmp = New-FmScratchDir 'fm-herdr'
    try {
        $assetPath = Join-Path $tmp $asset

        Write-FmErr "fm-install-herdr.ps1: downloading $asset from $url"
        # --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
        $curl = Get-Command 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $downloaded = $false
        if ($curl) {
            $fetch = Invoke-FmTool $curl.Source @('-fsSL', '--max-filesize', "$FmHerdrCiMaxBytes", $url, '-o', $assetPath)
            $downloaded = $fetch.Ok
        }
        if (-not $downloaded) {
            Write-FmDie "download failed for $url (bounded at $FmHerdrCiMaxBytes bytes)"
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
            $hashed = Invoke-FmTool $sha256sum.Source @($assetPath)
            $actualSha256 = @(@($hashed.StdOut -split "`n")[0] -split '\s+')[0]
            $actualSha256 = $actualSha256.TrimStart([char]92)
        } elseif ($shasum) {
            $hashed = Invoke-FmTool $shasum.Source @('-a', '256', $assetPath)
            $actualSha256 = @(@($hashed.StdOut -split "`n")[0] -split '\s+')[0]
            $actualSha256 = $actualSha256.TrimStart([char]92)
        } else {
            Write-FmDie 'need sha256sum or shasum to verify the Herdr asset'
        }

        if ($actualSha256 -cne $sha256) {
            Write-FmDie "checksum mismatch for $asset (expected $sha256, got $actualSha256)"
        }

        $destNative = ConvertTo-FmNativePath $destination
        [void][System.IO.Directory]::CreateDirectory($destNative)
        $installed = Join-Path $destNative 'herdr'
        [System.IO.File]::Copy($assetPath, $installed, $true)

        # Post-install version and protocol gates (no floating latest).
        $versionRun = Invoke-FmTool $installed @('--version')
        $installedVersion = ''
        $versionFirst = @($versionRun.StdOut -split "`n")[0]
        if ($versionFirst) {
            $fields = @($versionFirst.Trim() -split '\s+')
            if ($fields.Count -ge 2) { $installedVersion = $fields[1] }
        }
        if ($installedVersion -cne $FmHerdrCiVersion) {
            $shown = if ($installedVersion) { $installedVersion } else { '<empty>' }
            Write-FmDie "installed herdr version is '$shown', expected exact pin $FmHerdrCiVersion"
        }

        $statusRun = Invoke-FmTool $installed @('status', '--json')
        if (-not $statusRun.Ok) { Write-FmDie "could not run 'herdr status --json' after install" }
        $protocol = ''
        try {
            $parsed = $statusRun.StdOut | ConvertFrom-Json -AsHashtable
            if ($parsed -is [System.Collections.IDictionary] -and $parsed.Contains('client')) {
                $client = $parsed['client']
                if ($client -is [System.Collections.IDictionary] -and $client.Contains('protocol')) {
                    $protocol = [string]$client['protocol']
                }
            }
        } catch {
            # An unparseable status yields no protocol, which lands on the same
            # refusal the bash twin gives for jq producing nothing.
            $protocol = ''
        }
        if ($protocol -eq '' -or $protocol -notmatch '^[0-9]+$') {
            Write-FmDie 'could not read herdr client protocol from status --json'
        }
        if ([int]$protocol -lt $FmHerdrCiMinProtocol) {
            Write-FmDie "herdr protocol $protocol is below the required floor $FmHerdrCiMinProtocol"
        }

        Write-FmErr "fm-install-herdr.ps1: installed herdr $installedVersion (protocol $protocol) to $destination/herdr"
        $final = Invoke-FmTool $installed @('--version')
        if ($final.StdOut) { Write-FmRaw $final.StdOut }
        if ($final.StdErr) { [Console]::Error.Write($final.StdErr) }
        Exit-FmScript $final.ExitCode
    } finally {
        # `trap 'rm -rf "$TMP"' EXIT`.
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { $null = $_ }
    }
}
