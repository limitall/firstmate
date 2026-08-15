#requires -Version 7.0
<#
.SYNOPSIS
install.ps1 - install firstmate once. Afterwards, `firstmate` is a command.

.DESCRIPTION
Run this once on a new machine. It installs what is missing, wires the home, and
puts a `firstmate` command on PATH so starting it is one word from any shell:

    firstmate

That is the whole workflow after this. Nothing else is ever run by hand.

WHAT IT INSTALLS, and only with consent. AGENTS.md section 3's rule is detect,
ask, then install - so this reports what is missing and stops unless -Yes is
given or the captain agrees at the prompt. A half-installed machine is worse
than one that refused.

  git                required - isolated copies for workers
  Node.js            required - carries the Claude CLI and the axi tools
  Claude CLI         required - firstmate itself
  herdr, treehouse   required - worker sessions and their isolated copies
  gh                 optional - pull requests
  the axi tools      optional - GitHub, browser, decisions, quota

WHAT IT WILL NOT DO. It never elevates silently. Anything needing administrator
is reported with the exact command rather than attempted, because a prompt the
captain did not expect is how machines get changed without anyone deciding to.

.PARAMETER Yes
Install everything missing without asking.

.PARAMETER SkipOptional
Only install what firstmate cannot run without.

.EXAMPLE
./install.ps1

.EXAMPLE
./install.ps1 -Yes
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$SkipOptional
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
function Say { param([string]$T = '') [Console]::Out.WriteLine($T) }
function Warn { param([string]$T) [Console]::Error.WriteLine($T) }

Say ''
Say '  FIRSTMATE - install'
Say ''

# ---- what is here already ---------------------------------------------------
$required = @(
    @{ Name = 'git';       Cmd = 'git';       Why = 'isolated copies for workers'
       Choco = 'git';      Npm = '' }
    @{ Name = 'Node.js';   Cmd = 'node';      Why = 'carries the Claude CLI and the axi tools'
       Choco = 'nodejs-lts'; Npm = '' }
    @{ Name = 'Claude CLI'; Cmd = 'claude';   Why = 'firstmate itself'
       Choco = '';         Npm = '@anthropic-ai/claude-code' }
    @{ Name = 'herdr';     Cmd = 'herdr';     Why = 'worker sessions'
       Choco = '';         Npm = 'herdr' }
    @{ Name = 'treehouse'; Cmd = 'treehouse'; Why = 'isolated copies, leased'
       Choco = '';         Npm = 'treehouse' }
)
$optional = @(
    @{ Name = 'gh';                  Cmd = 'gh';                  Why = 'pull requests'; Choco = 'gh'; Npm = '' }
    @{ Name = 'gh-axi';              Cmd = 'gh-axi';              Why = 'GitHub, ergonomically'; Choco = ''; Npm = 'gh-axi' }
    @{ Name = 'chrome-devtools-axi'; Cmd = 'chrome-devtools-axi'; Why = 'browser work'; Choco = ''; Npm = 'chrome-devtools-axi' }
    @{ Name = 'lavish-axi';          Cmd = 'lavish-axi';          Why = 'visual reviews'; Choco = ''; Npm = 'lavish-axi' }
    @{ Name = 'tasks-axi';           Cmd = 'tasks-axi';           Why = 'shared backlog format'; Choco = ''; Npm = 'tasks-axi' }
    @{ Name = 'quota-axi';           Cmd = 'quota-axi';           Why = 'model headroom before dispatch'; Choco = ''; Npm = 'quota-axi' }
)

# PATH is re-read from the environment first, because a tool installed into a
# per-user directory earlier in this same session is on the PERSISTED path but
# not on this shell's copy of it - measured with gh, which was present and
# reported missing.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'Machine')

function Missing { param($Set) @($Set | Where-Object { -not (Get-Command $_.Cmd -ErrorAction SilentlyContinue) }) }

# Forced to arrays at the ASSIGNMENT. A pipeline that matches nothing unrolls to
# $null, and $null.Count throws under StrictMode - which is exactly what happened
# on a machine where everything required was already installed, so the installer
# failed only in the case where it had least to do.
$needReq = @(Missing $required)
$needOpt = @(if ($SkipOptional) { } else { Missing $optional })

Say '  Checking what is already here...'
foreach ($t in ($required + $optional)) {
    $have = [bool](Get-Command $t.Cmd -ErrorAction SilentlyContinue)
    Say ("    {0} {1,-22} {2}" -f $(if ($have) { '[ok]     ' } else { '[missing]' }), $t.Name, $t.Why)
}
Say ''

# ---- consent ----------------------------------------------------------------
if ($needReq.Count -or $needOpt.Count) {
    $list = @($needReq + $needOpt | ForEach-Object { $_.Name }) -join ', '
    Say "  Missing: $list"
    if (-not $Yes) {
        $answer = Read-Host '  Install these now? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Say '  Nothing installed. Re-run when you are ready.'
            exit 1
        }
    }
    Say ''
} else {
    Say '  Everything needed is already here.'
    Say ''
}

# ---- install ----------------------------------------------------------------
$failed = [System.Collections.Generic.List[object]]::new()
foreach ($t in @($needReq + $needOpt)) {
    Say "  Installing $($t.Name)..."
    try {
        if ($t.Npm) {
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
                throw 'npm is not available yet - install Node.js first, then re-run'
            }
            & npm install -g $t.Npm 2>&1 | Out-Null
        } elseif ($t.Choco) {
            if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
                throw "needs Chocolatey or a manual install: choco install $($t.Choco)"
            }
            # Machine-wide, so it needs an elevated shell. Reported rather than
            # attempted: silently raising a UAC prompt is how a machine gets
            # changed without anyone deciding to.
            & choco install $t.Choco -y 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "run this in an ADMINISTRATOR shell: choco install $($t.Choco) -y" }
        } else {
            throw 'no install route known'
        }
        if (Get-Command $t.Cmd -ErrorAction SilentlyContinue) { Say "    done" }
        else { $failed.Add($t); Warn "    installed, but '$($t.Cmd)' is not on PATH yet - open a new shell" }
    } catch {
        $failed.Add($t)
        Warn "    could not install $($t.Name): $($_.Exception.Message)"
    }
}
Say ''

# ---- wire the home ----------------------------------------------------------
Say '  Wiring the home...'
& (Join-Path $root 'bin' 'fm-setup.ps1') | Out-Null
Say '    done'

# ---- the `firstmate` command ------------------------------------------------
# A shim on the user's PATH, so starting it is one word from any shell.
#
# NOT %LOCALAPPDATA%\Microsoft\WindowsApps, which is the obvious choice and does
# not work: it is a reparse point Windows reserves for App Execution Aliases, and
# a plain .cmd dropped there is not resolved by the shell even though the folder
# IS on PATH and the file IS present. Measured - `firstmate` came back "not
# recognized" from a cmd.exe given a freshly rebuilt PATH.
#
# A dedicated per-user directory, added to PATH explicitly, is predictable and
# still needs no elevation.
Say '  Adding the `firstmate` command...'
$binDir = Join-Path $env:LOCALAPPDATA 'Programs\firstmate'
if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $binDir -Force
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $binDir), 'User')
}

$startPath = Join-Path $root 'start.ps1'
# Two shims: a .cmd so it works from cmd.exe and from a bare `firstmate`, and a
# .ps1 for a PowerShell caller that wants to pass parameters through.
$cmdShim = @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$startPath" %*
"@
[System.IO.File]::WriteAllText((Join-Path $binDir 'firstmate.cmd'), $cmdShim)
Say "    firstmate -> $startPath"
Say ''

# ---- done -------------------------------------------------------------------
if ($failed.Count) {
    Warn '  Finished, but some things did not install:'
    foreach ($f in $failed) { Warn "    $($f.Name) - $($f.Why)" }
    Warn '  Firstmate may refuse to start until those are present.'
    Say ''
}

Say '  Installed.'
Say ''
Say '    firstmate          start it - opens your browser, everything happens there'
Say ''
Say '  Open a NEW shell first, so the command is on PATH.'
Say ''

