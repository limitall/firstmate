#requires -Version 7.0
<#
.SYNOPSIS
start.ps1 - start firstmate. One command; everything else happens in the browser.

.DESCRIPTION
This is the only thing that needs running by hand. It checks the machine is
ready, starts the engine, opens the browser, and hands over - from that point
every activity happens in the page.

It is deliberately at the repo root rather than in bin/, because it is the one
entry point that is not for firstmate's own use: it is for the captain, once.

WHAT IT DOES
  1. checks the tools that must be present, and says plainly what is missing
  2. repairs the home if setup has never run here
  3. starts the bridge, which hosts a real firstmate session
  4. opens the browser at the page, carrying this run's key

WHAT IT DOES NOT DO. It installs nothing. A missing tool is reported with the
command that installs it and the run stops, because a half-started fleet is
worse than one that refused - AGENTS.md section 3's detect-ask-install rule.

.PARAMETER Port
Loopback port for the browser. Default 7433.

.PARAMETER NoBrowser
Start the engine without opening a browser.

.EXAMPLE
./start.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 7433,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
[Console]::Out.WriteLine()
[Console]::Out.WriteLine('  FIRSTMATE')
[Console]::Out.WriteLine('  starting up...')
[Console]::Out.WriteLine()

# ---- 1. what must be present ------------------------------------------------
$missing = @()
foreach ($t in @(
        @{ n = 'git'; why = 'isolated copies for workers'; get = 'winget install Git.Git' }
        @{ n = 'claude'; why = 'firstmate itself'; get = 'npm install -g @anthropic-ai/claude-code' }
    )) {
    if (-not (Get-Command $t.n -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing.Count) {
    # stderr, because this is the refusal path and a caller redirecting stdout
    # must still see WHY nothing started.
    [Console]::Error.WriteLine('  Cannot start - something required is missing:')
    foreach ($m in $missing) {
        [Console]::Error.WriteLine("    $($m.n)  - $($m.why)")
        [Console]::Error.WriteLine("      install with: $($m.get)")
    }
    [Console]::Error.WriteLine('')
    exit 1
}

# ---- 2. repair the home if this machine has never been set up ---------------
# A Windows clone arrives with the two committed symlinks as placeholder text,
# which silently means no instructions and no skills. Setup is idempotent, so
# running it here costs nothing on a machine that is already wired.
$pointer = Join-Path $root '.fm-home'
$claudeMd = Join-Path $root 'CLAUDE.md'

# The size is read by READING it, not from the directory entry. Get-Item reports
# Length 0 for a symlink - measured here, where CLAUDE.md is a 53KB link that the
# entry calls 0 bytes - so an entry-size check declares a healthy machine
# unconfigured and re-runs setup on every start.
$contractChars = 0
if (Test-Path -LiteralPath $claudeMd -PathType Leaf) {
    try { $contractChars = ([System.IO.File]::ReadAllText($claudeMd)).Length } catch { $contractChars = 0 }
}
$needsSetup = (-not (Test-Path -LiteralPath $pointer)) -or ($contractChars -lt 200)
if ($needsSetup) {
    [Console]::Out.WriteLine('  First run here - wiring up the home...')
    & (Join-Path $root 'bin' 'fm-setup.ps1') | Out-Null
}

# ---- 3. the engine ----------------------------------------------------------
[Console]::Out.WriteLine('  Starting the engine and opening your browser.')
[Console]::Out.WriteLine('  Everything happens in the page from here. Ctrl+C stops it.')
[Console]::Out.WriteLine()

# A HASHTABLE, not an array. Splatting an array passes its elements
# positionally, so `@('-Port', 7433)` arrived as the literal string '-Port' bound
# to the first positional parameter and failed to convert to an int.
$bridgeArgs = @{ Port = $Port }
if ($NoBrowser) { $bridgeArgs['NoLaunch'] = $true }
& (Join-Path $root 'bin' 'fm-bridge.ps1') @bridgeArgs

