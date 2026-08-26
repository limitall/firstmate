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

WHAT IT DOES NOT DO. It installs nothing, and it does not keep its own list of
where a tool comes from. A missing tool is reported and the run stops, pointing
at ./install.ps1, which is the one thing that installs - because a half-started
fleet is worse than one that refused (AGENTS.md section 3's detect-ask-install
rule) and a second install table is how two tools came to be installed from the
wrong npm packages.

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

# ============================================================================
# 0. THE SHELL THIS WAS STARTED IN
#
# NO `#requires -Version 7.0` ON THIS FILE, and nothing above the relaunch below
# may use PowerShell 7 syntax. This file used to carry the directive, and a
# captain on their first successful install typed `.\start.ps1` in the Windows
# PowerShell 5.1 window they had just run the installer from. What they got was
#
#     The script 'start.ps1' cannot be run because it contained a "#requires"
#     statement for Windows PowerShell 7.0.
#
# which is accurate, is not firstmate speaking, and does not say what to do. The
# machine was fine: `install.ps1` had already put PowerShell 7 on it. Only the
# window was wrong, and a wrong window is something this script can fix itself.
#
# TYPING THIS IS THE CONSENT TO START. Relaunching does not start anything the
# captain did not ask for - it runs the command they typed, in the shell it
# needs. Nothing here decides to start on its own.
#
# WHY THIS IS NOT install.ps1's BLOCK. That one has to survive on a machine with
# no PowerShell 7 at all, so it offers to INSTALL the shell; this one runs after
# that install and must never install anything (see WHAT IT DOES NOT DO above).
# They share only how pwsh is found, which is four lines and one well-known
# location.
# ============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('  FIRSTMATE')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("  This is Windows PowerShell $($PSVersionTable.PSVersion), and firstmate runs on")
    [Console]::Out.WriteLine('  PowerShell 7. A script cannot change the shell it was started in.')
    [Console]::Out.WriteLine('')

    $relaunchArguments = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $relaunchArguments += "-$key" }
        } else {
            $relaunchArguments += "-$key"
            $relaunchArguments += [string]$value
        }
    }

    $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        $localPwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'
        if (Test-Path -LiteralPath $localPwsh) { $pwshCommand = Get-Command -Name $localPwsh -ErrorAction SilentlyContinue }
    }
    if (-not $pwshCommand) {
        # A machine that has never been set up, rather than a wrong window. This
        # installs nothing itself: install.ps1 is the one thing that installs,
        # which is the same rule the missing-tool refusal below is built on.
        [Console]::Error.WriteLine('  PowerShell 7 is not on this machine, so nothing here can start yet.')
        [Console]::Error.WriteLine('  This puts it there, along with everything else firstmate needs:')
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine("    powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'install.ps1')`"")
        [Console]::Error.WriteLine('')
        exit 1
    }

    # ONE RELAUNCH, NEVER TWO. install.ps1's block states why: `pwsh` is also
    # PowerShell 6's name, and relaunching into one would arrive back here.
    if ($env:FM_SHELL_RELAUNCHED) {
        [Console]::Error.WriteLine("  This relaunched into a shell that is still PowerShell $($PSVersionTable.PSVersion),")
        [Console]::Error.WriteLine('  so it is stopping rather than doing it again. The pwsh on this machine is not')
        [Console]::Error.WriteLine('  PowerShell 7 - PowerShell 6 uses that name too. This puts 7 beside it:')
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine("    powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'install.ps1')`"")
        [Console]::Error.WriteLine('')
        exit 1
    }
    $env:FM_SHELL_RELAUNCHED = '1'

    # Said only once it is known to be true. Announcing the switch above, before
    # pwsh has been found, promises it on the one machine that cannot do it.
    [Console]::Out.WriteLine('  Switching to PowerShell 7 and carrying on there.')
    [Console]::Out.WriteLine('')

    # A MACHINE MAY REFUSE THIS, and the refusal must not be a .NET error -
    # PowerShell raises a declined launch as a terminating exception whatever
    # $ErrorActionPreference says. install.ps1's relaunch carries the same guard
    # and docs/windows-install.md has the measurement behind it.
    try {
        & $pwshCommand.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @relaunchArguments
    } catch {
        [Console]::Error.WriteLine('  Windows refused to start PowerShell 7 from here:')
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine("    $($pwshCommand.Source)")
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine('  The machine declined the launch; PowerShell itself did not fail. Open')
        [Console]::Error.WriteLine('  "PowerShell 7" from your Start menu, change to this folder, and run:')
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine('    .\start.ps1')
        [Console]::Error.WriteLine('')
        exit 1
    }
    exit $LASTEXITCODE
}

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
        @{ n = 'git'; why = 'isolated copies for workers' }
        @{ n = 'claude'; why = 'firstmate itself' }
    )) {
    if (-not (Get-Command $t.n -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing.Count) {
    # stderr, because this is the refusal path and a caller redirecting stdout
    # must still see WHY nothing started.
    [Console]::Error.WriteLine('  Cannot start - something required is missing:')
    foreach ($m in $missing) {
        [Console]::Error.WriteLine("    $($m.n)  - $($m.why)")
    }
    [Console]::Error.WriteLine('')
    # ONE remedy, not one per tool. install.ps1 reads every route from the
    # bootstrap area, checks the versions afterwards and reports what it could
    # not do; a command copied into this file would be a third place the answer
    # lives and the first one to go stale.
    [Console]::Error.WriteLine("  Install everything this machine needs with:  $(Join-Path $root 'install.ps1')")
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

