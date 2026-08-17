#requires -Version 7.0
# FmMachine.ps1 - the two things a tool install does not cover, and the pass that
# proves the whole machine.
#
# WHAT "VERIFIED" HAS TO MEAN HERE. An installer that ends with "Installed." and
# has checked nothing is the thing this area exists to avoid: every failure it
# could have caught is instead discovered later, by the captain, as a command
# that behaves oddly. So the run ends by EXERCISING the machine - every tool is
# run and made to print a version, the operating contract is read and measured,
# the skills are counted, and the repository's own test suite is executed - and
# the verdict is computed from what those returned.
#
# The suite is the last check and the strongest one. It is also the only check
# that costs minutes rather than seconds, which is why -SkipSuite exists; a run
# that skipped it says so in its verdict rather than claiming a pass it did not
# take.

Set-StrictMode -Version Latest

# --- the `firstmate` command ---------------------------------------------------

# NOT %LOCALAPPDATA%\Microsoft\WindowsApps, which is the obvious choice and does
# not work: it is a reparse point Windows reserves for App Execution Aliases, and
# a plain .cmd dropped there is not resolved by the shell even though the folder
# IS on PATH and the file IS present. Measured - `firstmate` came back "not
# recognized" from a cmd.exe given a freshly rebuilt PATH.
#
# A dedicated per-user directory, added to PATH explicitly, is predictable and
# still needs no elevation.
function Get-FmMachineShimDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$InstallRoot = '')

    if (-not $InstallRoot) {
        if (-not $env:LOCALAPPDATA) { throw 'error: LOCALAPPDATA is not set, so there is no per-user place for the firstmate command' }
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    }
    Join-Path $InstallRoot 'firstmate'
}

function Get-FmMachineShimText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StartScript)

    # A .cmd rather than a .ps1: this is what makes a bare `firstmate` work from
    # cmd.exe, from the Run box and from a PowerShell session alike. %* carries
    # the captain's own arguments through to start.ps1.
    @(
        '@echo off'
        "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$StartScript`" %*"
    ) -join "`r`n"
}

function Set-FmMachineCommandShim {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$InstallRoot = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User'
    )

    $binDirectory = Get-FmMachineShimDirectory -InstallRoot $InstallRoot
    $startScript = Join-Path $RepoRoot 'start.ps1'
    $shimPath = Join-Path $binDirectory 'firstmate.cmd'
    $text = Get-FmMachineShimText -StartScript $startScript

    $current = ''
    if (Test-Path -LiteralPath $shimPath -PathType Leaf) { $current = [System.IO.File]::ReadAllText($shimPath) }
    if ($current -eq $text -and (Test-FmToolOnPath -Directory $binDirectory -Scope $PathScope)) {
        return [pscustomobject]@{ Action = 'already'; Detail = "$shimPath -> $startScript" }
    }
    if (-not $PSCmdlet.ShouldProcess($shimPath, 'write the firstmate command')) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }

    if (-not (Test-Path -LiteralPath $binDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $binDirectory -Force
    }
    $action = if (Test-Path -LiteralPath $shimPath -PathType Leaf) { 'updated' } else { 'created' }
    [System.IO.File]::WriteAllText($shimPath, $text)
    $null = Add-FmToolUserPath -Directory $binDirectory -Scope $PathScope -Confirm:$false
    [pscustomobject]@{ Action = $action; Detail = "$shimPath -> $startScript" }
}

# --- the suite -----------------------------------------------------------------

# Run in a CHILD process on purpose. The suite imports the module, rewrites
# PSModulePath and sets environment variables of its own; running it inside the
# session that just performed an install would leave that session's view of the
# machine decided by the tests rather than by the install. It also means a suite
# that crashes outright is reported as a failed verification rather than taking
# the installer down with it.
function Invoke-FmMachineSuite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$TimeoutSeconds = 3600
    )

    $testsPath = Join-Path $RepoRoot 'tests'
    if (-not (Test-Path -LiteralPath $testsPath -PathType Container)) {
        return [pscustomobject]@{ Ran = $false; Passed = 0; Failed = 0; Detail = "no tests directory at '$testsPath'"; FailedNames = @() }
    }
    if (-not (Get-Module -ListAvailable -Name 'Pester')) {
        return [pscustomobject]@{ Ran = $false; Passed = 0; Failed = 0; Detail = 'Pester is not installed, so the suite could not run'; FailedNames = @() }
    }

    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-suite-' + [guid]::NewGuid().ToString('N') + '.json')
    $runner = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-suite-' + [guid]::NewGuid().ToString('N') + '.ps1')
    [System.IO.File]::WriteAllText($runner, @'
param([Parameter(Mandatory)][string]$Tests, [Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference = 'Continue'
Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = $Tests
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $configuration
$failed = @($result.Failed | ForEach-Object { [string]$_.ExpandedPath })
[pscustomobject]@{
    Passed      = [int]$result.PassedCount
    Failed      = [int]$result.FailedCount
    Skipped     = [int]$result.SkippedCount
    FailedNames = $failed
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
'@, [System.Text.UTF8Encoding]::new($false))

    try {
        # BOUNDED. A wedged test would otherwise hang the installer with no
        # output and nothing to act on, at the exact moment the captain is
        # waiting to be told whether the machine works.
        $pwsh = (Get-Process -Id $PID).Path
        $process = Start-Process -FilePath $pwsh -NoNewWindow -PassThru -ArgumentList @(
            '-NoProfile', '-File', $runner, '-Tests', $testsPath, '-ResultPath', $resultPath)
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Debug "could not stop the suite process: $_" }
            return [pscustomobject]@{
                Ran         = $false
                Passed      = 0
                Failed      = 0
                Detail      = "the suite did not finish within $TimeoutSeconds seconds and was stopped"
                FailedNames = @()
            }
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            return [pscustomobject]@{
                Ran         = $false
                Passed      = 0
                Failed      = 0
                Detail      = "the suite process produced no result file (exit code $($process.ExitCode))"
                FailedNames = @()
            }
        }
        $parsed = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        $names = @($parsed.FailedNames)
        return [pscustomobject]@{
            Ran         = $true
            Passed      = [int]$parsed.Passed
            Failed      = [int]$parsed.Failed
            Detail      = "$([int]$parsed.Passed) passed, $([int]$parsed.Failed) failed, $([int]$parsed.Skipped) skipped"
            FailedNames = $names
        }
    } finally {
        foreach ($temp in @($runner, $resultPath)) {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        }
    }
}

# --- the proving pass ----------------------------------------------------------

# Every tool in the catalog, run and made to answer.
#
# PRESENT IS NOT ENOUGH. A command that resolves but prints no version is
# reported as unverified, because that is exactly the shape a wrong package takes
# - the npm `herdr` placeholder installs a `herdr` that does nothing. Required
# tools that fail this are 'missing'; optional ones are 'warn', because a machine
# without gh is a working firstmate that cannot open a PR.
#
# DELIBERATELY OFFLINE. This asks "does this machine work", not "is it the newest
# version": a tool one release behind is a working tool, and the verdict on a
# finished install must not depend on whether a vendor's API answered.
# Get-FmMachineInstallPlan is where currency is asked about.
function Get-FmMachineToolVerification {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$SkipOptional)

    $checks = @()
    foreach ($entry in (Get-FmToolCatalog)) {
        if ($SkipOptional -and -not $entry.Required) { continue }
        $status = Get-FmToolStatus -Command $entry.Command
        $minimum = Get-FmToolMinimum -Tool $entry.Tool
        $capabilityMet = if ($status.Present) { Test-FmToolCapability -Tool $entry.Tool } else { $true }
        $classification = Get-FmToolClassification -Present $status.Present -Installed $status.Version `
            -Minimum $minimum.Version -CapabilityMet $capabilityMet
        $name = "tool $($entry.Label)"
        $status_ = if ($entry.Required) { 'missing' } else { 'warn' }
        $fix = (Get-FmToolRoute -Tool $entry.Tool).Command

        switch ($classification) {
            'missing' {
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required `
                    -Detail "not on PATH - $($entry.Why)" -Fix $fix
            }
            'unsupported' {
                $detail = if ($minimum.Capability) {
                    "$($status.Version) is installed, and this port needs a build that $($minimum.Capability)"
                } else {
                    "$($status.Version) is installed; this repo requires at least $($minimum.Version) ($($minimum.Source))"
                }
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required -Detail $detail -Fix $fix
            }
            'unknown-version' {
                $checks += New-FmInstallCheck -Name $name -Status $status_ -Required:$entry.Required `
                    -Detail "'$($entry.Command)' resolves to $($status.Path) but answers nothing to --version, so it is not verified as the real tool" `
                    -Fix $fix
            }
            default {
                $checks += New-FmInstallCheck -Name $name -Status 'ok' -Required:$entry.Required `
                    -Detail "$($status.Version) - $($status.Path)"
            }
        }
    }
    $checks
}

# The opt-in channels, reported and never touched.
#
# THE CAPTAIN'S NAME, THE PHONE CHANNEL AND THE SPEECH ENGINE ARE OPTIONAL, and
# an installer that quietly half-set one would be worse than one that ignored
# them: a `config/telegram-token` with no `config/telegram-allow` is a channel
# that looks configured and refuses every message, and a `config/voice` written
# by a script nobody asked is a machine that starts talking. So this WRITES
# NOTHING. It reports each one as on or off, with the one command that turns it
# on, and it returns LINES rather than checks - an off channel is a state, not a
# fault, and must not colour the run's verdict.
function Get-FmMachineOptionalLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$FirstmateHome)

    $configDir = Get-FmInstallConfigDirectory -FirstmateHome $FirstmateHome
    $read = {
        param([string]$Name)
        $path = Join-Path $configDir $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
        ([System.IO.File]::ReadAllText($path)).Trim()
    }

    $lines = @('optional - reported as it is, never assumed and never half-set:')

    $name = & $read 'captain-name'
    $lines += if ($name) {
        '  [on]       captain''s name - firstmate calls you "' + $name + '"'
    } else {
        '  [off]      captain''s name - no config/captain-name, so firstmate says "captain"; set it with bin/fm-name.ps1 <name>'
    }

    $voice = & $read 'voice'
    $lines += if ($voice) {
        '  [on]       voice - config/voice is present, so bin/fm-say.ps1 and bin/fm-ask.ps1 will speak and listen'
    } else {
        '  [off]      voice - no config/voice, so nothing is spoken and the microphone is never opened'
    }

    # BOTH halves, because either alone is the half-set state. A token with no
    # allow-list is a channel that looks configured and refuses every message.
    $token = & $read 'telegram-token'
    $allow = & $read 'telegram-allow'
    $lines += if ($token -and $allow) {
        '  [on]       phone channel - config/telegram-token and config/telegram-allow are both present'
    } elseif ($token -or $allow) {
        '  [partial]  phone channel - only one of config/telegram-token and config/telegram-allow is set, so it will refuse every message; set both or neither'
    } else {
        '  [off]      phone channel - no config/telegram-token, so bin/fm-tell.ps1 sends nothing and nothing is ever received'
    }

    $lines
}

function Get-FmMachineModuleVerification {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $checks = @()
    foreach ($requirement in (Get-FmToolModuleRequirement)) {
        $status = Get-FmToolModuleStatus -Requirement $requirement
        $name = "module $($requirement.Name)"
        $classification = Get-FmToolClassification -Present $status.Present -Installed $status.Version `
            -Minimum $requirement.MinimumVersion
        $fix = "Install-Module $($requirement.Name) -Scope CurrentUser"
        switch ($classification) {
            'missing' {
                $checks += New-FmInstallCheck -Name $name -Status 'warn' -Detail "not installed - $($requirement.Why)" -Fix $fix
            }
            'unsupported' {
                $checks += New-FmInstallCheck -Name $name -Status 'warn' `
                    -Detail "$($status.Version) is installed; this repo requires at least $($requirement.MinimumVersion) ($($requirement.MinimumSource))" `
                    -Fix $fix
            }
            default {
                $checks += New-FmInstallCheck -Name $name -Status 'ok' -Detail "$($status.Version) - $($status.Path)"
            }
        }
    }
    $checks
}
