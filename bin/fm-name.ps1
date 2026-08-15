#requires -Version 7.0
<#
.SYNOPSIS
fm-name.ps1 - read or set what firstmate calls you.

.DESCRIPTION
AGENTS.md requires firstmate to address you directly in every response. This
chooses the WORD it uses; it does not remove the address.

Stored in config/captain-name, which is captain-private and gitignored, so the
choice stays in this home and never travels to another one or into the shared
template.

With no argument, prints the current name. With one, sets it. `-Reset` puts it
back to "captain".

A running session and a running bridge read this at startup, so restart them to
pick up a change.

.EXAMPLE
bin/fm-name.ps1
captain

.EXAMPLE
bin/fm-name.ps1 Dhaval
firstmate will call you: Dhaval
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Name = '',
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmCaptainName'

$configDir = Get-FmConfigRoot
$file = Join-Path $configDir 'captain-name'

if ($Reset) {
    if ($PSCmdlet.ShouldProcess($file, 'reset the address to "captain"')) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        [Console]::Out.WriteLine('firstmate will call you: captain')
    }
    exit 0
}

if (-not $Name) {
    # Assigned first rather than called inline inside the WriteLine argument:
    # the module-assembly check scans for the required command by name and does
    # not see it nested in a method call, so an inline call reads as "declared
    # but never used" and fails the suite.
    $current = Get-FmCaptainName
    [Console]::Out.WriteLine($current)
    exit 0
}

$trimmed = $Name.Trim()
if ($trimmed.Length -gt 48) {
    [Console]::Error.WriteLine('error: keep it under 48 characters - it is used in every reply and read aloud')
    exit 1
}
# Refused rather than sanitized: a newline or a control character here would
# turn every address into two lines, and silently trimming it would hide that
# the name is not what was asked for.
if ($trimmed -match '[\r\n\t]') {
    [Console]::Error.WriteLine('error: a name cannot contain a line break or a tab')
    exit 1
}

if ($PSCmdlet.ShouldProcess($file, "set the address to '$trimmed'")) {
    # New-FmDirectory is module-internal and an entry point may only call
    # exported functions, so this uses the framework directly rather than
    # reaching past the module boundary.
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $configDir -Force
    }
    [System.IO.File]::WriteAllText($file, "$trimmed`n", [System.Text.UTF8Encoding]::new($false))
    [Console]::Out.WriteLine("firstmate will call you: $trimmed")
    [Console]::Out.WriteLine('restart the session or the bridge to pick it up')
}
