#requires -Version 7.0
# FmToolInstall.ps1 - taking a bare Windows machine's TOOLS to the set firstmate
# needs, without ever asking for administrator.
#
# The neighbouring FmInstall.ps1 answers "what has to be true inside the home and
# the checkout". This file answers the question in front of it: what has to be
# installed on the machine at all, where does each of those genuinely come from,
# and how does the installer prove afterwards that it got the real thing.
#
# FOUR RULES SHAPE EVERYTHING BELOW.
#
# 1. ASSUME NOTHING IS ALREADY THERE. Every requirement is checked, including the
#    ones that feel too basic to check and including the ones the installer would
#    USE to install something else - the shell version, git, Node, npm, winget.
#    A clean Windows machine has almost none of them, and an installer that
#    assumes a base layer fails with "command not found" at the moment the
#    captain can least interpret it.
#
# 2. THREE OUTCOMES PER REQUIREMENT, NOT TWO. Get-FmToolClassification is the
#    owner of that decision and Get-FmToolClassificationReason renders it:
#
#      missing      install it; that is what the script is for
#      older        present and working, but not the latest. ASK, default no,
#                   carry on either way. Force-upgrading a working machine is
#                   worse than leaving it alone.
#      unsupported  present but below a minimum this repo actually STATES. Say
#                   so, ask them to update it, and SKIP that step - never install
#                   over the top of it, and never let the run end looking
#                   successful with an unusable tool in place.
#
#    "Older" and "unsupported" are never blurred. A minimum is only a minimum
#    when this repo states one (Get-FmToolMinimum names where each comes from);
#    where none is stated the answer is "older, ask", never a threshold invented
#    here.
#
# 3. NEVER TRUST A PACKAGE NAME. A route is only correct if running the installed
#    command prints a version this file then reads back. The defect that made
#    this area necessary was a table that installed the npm packages called
#    `treehouse` and `herdr` - an unrelated web framework and an empty 0.0.0
#    placeholder - and reported success because `npm install -g` exited 0.
#
# 4. NO STEP REQUIRES ADMINISTRATOR. Every route this file prefers writes into
#    the user's own profile and puts that directory on the USER PATH. A route
#    that genuinely needs elevation is DECLARED, reported by name, and skipped on
#    an unelevated run rather than crashing it.
#
# THE ROUTE TABLE IS NOT HERE. Get-FmBootstrapInstallCommand,
# Get-FmBootstrapPortableRelease and Get-FmBootstrapManualInstallUrl in the
# bootstrap area own where a tool comes from, because the session-start digest
# has to print the same answer this installer runs.

Set-StrictMode -Version Latest

# --- the catalog ---------------------------------------------------------------
#
# WHAT "READY TO USE AS WE ARE USING IT HERE" MEANS, enumerated. Required is the
# set firstmate cannot dispatch a worker without; optional is everything that
# makes it pleasant and that -SkipOptional drops.
#
# no-mistakes IS DELIBERATELY ABSENT and must stay absent. Its delivery mode is
# refused by name on this port (AGENTS.md section 14), so installing the
# validation pipeline would leave a machine carrying a tool nothing here may use.
# Get-FmToolExcluded records that decision so the installer can say so out loud
# rather than letting the gap read as an oversight.
$script:FmToolCatalog = @(
    @{ Tool = 'git';                 Command = 'git';                 Label = 'git';                 Why = 'isolated copies for workers';     Required = $true }
    @{ Tool = 'node';                Command = 'node';                Label = 'Node.js';             Why = 'carries the npm-published axi tools'; Required = $true }
    @{ Tool = 'claude';              Command = 'claude';              Label = 'Claude CLI';          Why = 'firstmate itself';                Required = $true }
    @{ Tool = 'herdr';               Command = 'herdr';               Label = 'herdr';               Why = 'worker sessions';                 Required = $true }
    @{ Tool = 'treehouse';           Command = 'treehouse';           Label = 'treehouse';           Why = 'isolated worktrees, leased';      Required = $true }
    @{ Tool = 'gh';                  Command = 'gh';                  Label = 'gh';                  Why = 'pull requests';                   Required = $false }
    @{ Tool = 'gh-axi';              Command = 'gh-axi';              Label = 'gh-axi';              Why = 'GitHub, ergonomically';           Required = $false }
    @{ Tool = 'chrome-devtools-axi'; Command = 'chrome-devtools-axi'; Label = 'chrome-devtools-axi'; Why = 'browser work';                    Required = $false }
    @{ Tool = 'lavish-axi';          Command = 'lavish-axi';          Label = 'lavish-axi';          Why = 'visual reviews';                  Required = $false }
    @{ Tool = 'tasks-axi';           Command = 'tasks-axi';           Label = 'tasks-axi';           Why = 'shared backlog format';           Required = $false }
    @{ Tool = 'quota-axi';           Command = 'quota-axi';           Label = 'quota-axi';           Why = 'model headroom before dispatch';  Required = $false }
)

function Get-FmToolCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([switch]$RequiredOnly)

    $entries = @($script:FmToolCatalog | ForEach-Object {
            [pscustomobject]@{
                Tool     = [string]$_.Tool
                Command  = [string]$_.Command
                Label    = [string]$_.Label
                Why      = [string]$_.Why
                Required = [bool]$_.Required
            }
        })
    if ($RequiredOnly) { return @($entries | Where-Object { $_.Required }) }
    $entries
}

# Tools this installer will NOT install, and the reason, so their absence is an
# answer rather than a hole. Read by Install-FmMachine and printed once.
function Get-FmToolExcluded {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    [object[]]@(
        [pscustomobject]@{
            Tool   = 'no-mistakes'
            Reason = 'the validation pipeline has no Windows support and its delivery mode is refused by name (AGENTS.md section 14), so its absence here is expected and is not a failure'
        }
    )
}

# --- PowerShell modules the repo's own bar needs --------------------------------
#
# Neither is needed to RUN firstmate, and both are needed to prove it works:
# Pester runs the suite and PSScriptAnalyzer is the bar tests/FmAnalyzer.Tests.ps1
# sweeps the whole repository against. Install-Module -Scope CurrentUser writes
# into the user's own module directory, so neither needs administrator either.
#
# ONLY PESTER CARRIES A MINIMUM, and it carries one because this repo states it:
# the suite is written against Pester 5's configuration object. Nothing states a
# PSScriptAnalyzer floor, so none is invented here - an older analyzer is
# classified 'older' and asked about, never declared unsupported.
function Get-FmToolModuleRequirement {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    [object[]]@(
        [pscustomobject]@{
            Name           = 'Pester'
            MinimumVersion = '5.0.0'
            MinimumSource  = 'the suite is written for Pester 5+ (CONTRIBUTING.md, and the doctor prerequisite check)'
            Why            = 'runs the test suite that proves this machine works'
        }
        [pscustomobject]@{
            Name           = 'PSScriptAnalyzer'
            MinimumVersion = ''
            MinimumSource  = ''
            Why            = 'the analyzer bar the whole repository is held to'
        }
    )
}

# --- version arithmetic ---------------------------------------------------------

# The first major.minor[.patch] in a version string, as a [version].
#
# Tool banners are not versions: "git version 2.49.0.windows.1", "herdr
# 0.7.5-preview.2026-07-21-0f10e1453a7f", "v2.1.1" and "2.1.233 (Claude Code)"
# are four different shapes. A banner this cannot parse returns $null and is
# reported as an UNKNOWN version, never as a version that passes a floor it was
# never compared against.
function Get-FmToolVersionNumber {
    [CmdletBinding()]
    [OutputType([version])]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '[vV]?(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) { return $null }
    $patch = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
    [version]::new([int]$match.Groups[1].Value, [int]$match.Groups[2].Value, $patch)
}

# The value two builds of the SAME tool are ranked by.
#
# Most tools rank by their semantic version. herdr does not: its Windows builds
# are published only on preview releases, which are tagged
# `preview-<YYYY-MM-DD>-<sha>` and carry no semver at all, while the binary
# reports `0.7.5-preview.2026-07-21-<sha>`. Ranking those two by their semver
# would compare 0.7.5 against nothing at all.
#
# So: when BOTH sides carry a date stamp, the date is what they are ranked by.
# It is a comparison, not a version - it is deliberately not used for a minimum,
# where only a stated semantic version means anything.
function Get-FmToolComparableVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $stamp = [regex]::Match($Text, '(\d{4})-(\d{2})-(\d{2})')
    if ($stamp.Success) {
        return [version]::new([int]$stamp.Groups[1].Value, [int]$stamp.Groups[2].Value, [int]$stamp.Groups[3].Value)
    }
    Get-FmToolVersionNumber -Text $Text
}

function Test-FmToolDateStamped {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, '\d{4}-\d{2}-\d{2}')
}

# The minimum this REPO states for a tool, and where it states it.
#
# An empty Version means no minimum is stated anywhere, which is a real answer
# and not a gap: such a tool can be older but never unsupported.
#
# Capability is the other kind of stated minimum - a build that is new enough by
# number can still be missing the one thing this port needs. treehouse is the
# case: Start-FmWorker acquires a worktree with `treehouse get --lease`, and a
# build without that flag cannot serve a worker whatever it calls itself.
function Get-FmToolMinimum {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Tool)

    $none = [pscustomobject]@{ Version = ''; Source = ''; Capability = '' }
    switch ($Tool) {
        'gh-axi' {
            return [pscustomobject]@{
                Version    = $script:FmBootstrapGhAxiMin
                Source     = 'the axi-family floor bootstrap enforces at session start'
                Capability = ''
            }
        }
        'lavish-axi' {
            return [pscustomobject]@{
                Version    = $script:FmBootstrapLavishAxiMin
                Source     = 'the axi-family floor bootstrap enforces at session start'
                Capability = ''
            }
        }
        'treehouse' {
            return [pscustomobject]@{
                Version    = ''
                Source     = ''
                Capability = "supports 'get --lease', which is how this port acquires a worker's worktree"
            }
        }
        default { return $none }
    }
}

# Does an installed tool meet the stated CAPABILITY floor, where one exists?
# Returns $true when there is no capability to meet, so a caller can ask
# unconditionally.
function Test-FmToolCapability {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Tool)

    if ((Get-FmToolMinimum -Tool $Tool).Capability -eq '') { return $true }
    if ($Tool -eq 'treehouse') { return (Test-FmBootstrapTreehouseSupportsLease) }
    $true
}

# --- what the vendor publishes today --------------------------------------------
#
# "Older than latest" is only answerable against a real published version, so
# each of these names one source and reads it. A source that cannot be reached
# returns '' and the requirement is classified 'unknown-latest' - the installer
# then says it could not tell rather than declaring the tool current, because
# claiming currency it never checked is exactly the silent-success failure this
# whole area exists to remove.

function Get-FmToolGitHubLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [switch]$IncludePrerelease,
        [int]$TimeoutSeconds = 20
    )

    try {
        $headers = @{ 'User-Agent' = 'firstmate-win' }
        if ($IncludePrerelease) {
            # NO @() AROUND Invoke-RestMethod. It hands a JSON array back as ONE
            # object, so wrapping it produces a one-element array holding the
            # whole list - and `$wrapped[0].tag_name` then member-enumerates every
            # tag into one space-joined string. Measured: this returned all
            # twenty herdr tags as a single "version". Piping enumerates
            # correctly, which is what the filter below relies on.
            $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=20" `
                -Headers $headers -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            $first = @($releases | Select-Object -First 1)
            if ($first.Count -eq 0) { return '' }
            return [string]$first[0].tag_name
        }
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" `
            -Headers $headers -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return [string]$release.tag_name
    } catch {
        Write-Debug "could not read the latest release of $Repository`: $_"
        return ''
    }
}

function Get-FmToolNpmLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Package,
        [int]$TimeoutSeconds = 20
    )

    # The registry's own metadata endpoint, not `npm view`: it answers in one
    # request and it works before Node is installed, which is exactly the state a
    # fresh machine is in when this runs.
    try {
        $document = Invoke-RestMethod -Uri "https://registry.npmjs.org/$Package/latest" -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return [string]$document.version
    } catch {
        Write-Debug "could not read the latest published version of $Package`: $_"
        return ''
    }
}

function Get-FmToolLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [int]$TimeoutSeconds = 20
    )

    switch ($Tool) {
        'git' { return (Get-FmToolGitHubLatestVersion -Repository 'git-for-windows/git' -TimeoutSeconds $TimeoutSeconds) }
        'gh' { return (Get-FmToolGitHubLatestVersion -Repository 'cli/cli' -TimeoutSeconds $TimeoutSeconds) }
        'treehouse' { return (Get-FmToolGitHubLatestVersion -Repository 'kunchenguid/treehouse' -TimeoutSeconds $TimeoutSeconds) }
        # Windows herdr binaries are published only on PREVIEW releases while
        # native Windows support is in beta, so the newest release of any kind is
        # the one a Windows machine can actually be on.
        'herdr' { return (Get-FmToolGitHubLatestVersion -Repository 'herdrdev/herdr' -IncludePrerelease -TimeoutSeconds $TimeoutSeconds) }
        'claude' {
            try {
                return ([string](Invoke-RestMethod -Uri 'https://downloads.claude.ai/claude-code-releases/latest' `
                            -TimeoutSec $TimeoutSeconds -ErrorAction Stop)).Trim()
            } catch {
                Write-Debug "could not read the latest Claude Code version: $_"
                return ''
            }
        }
        'node' {
            try {
                # Again no @(): see Get-FmToolGitHubLatestVersion. The dist index
                # is one JSON array, and wrapping it hid a thousand versions
                # inside a single element.
                $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                # LTS is what a working machine should be on; the newest current
                # release is not what `winget install OpenJS.NodeJS` gives either.
                $lts = @($index | Where-Object { $_.lts } | Select-Object -First 1)
                if ($lts.Count -eq 0) { return '' }
                return [string]$lts[0].version
            } catch {
                Write-Debug "could not read the latest Node.js release: $_"
                return ''
            }
        }
        { $_ -in 'gh-axi', 'chrome-devtools-axi', 'lavish-axi', 'tasks-axi', 'quota-axi' } {
            return (Get-FmToolNpmLatestVersion -Package $_ -TimeoutSeconds $TimeoutSeconds)
        }
        default { return '' }
    }
}

function Get-FmToolModuleLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $found = Find-Module -Name $Name -ErrorAction Stop | Select-Object -First 1
        return [string]$found.Version
    } catch {
        Write-Debug "could not read the latest published version of module $Name`: $_"
        return ''
    }
}

# --- the classification ---------------------------------------------------------
#
# ONE function decides which of the outcomes a requirement is in, so the plan,
# the prompts, the install loop and the end report cannot disagree about it.
#
#   missing         not present at all
#   unsupported     present, below a minimum this repo STATES, or missing a
#                   stated capability
#   older           present, working, behind the latest published version
#   current         present and at or ahead of the latest published version
#   unknown-version present but its banner carries no readable version
#   unknown-latest  present, but the published version could not be determined
function Get-FmToolClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][bool]$Present,
        [string]$Installed = '',
        [string]$Latest = '',
        [string]$Minimum = '',
        [bool]$CapabilityMet = $true
    )

    if (-not $Present) { return 'missing' }
    if (-not $CapabilityMet) { return 'unsupported' }

    $have = Get-FmToolVersionNumber -Text $Installed
    if ($Minimum) {
        $floor = Get-FmToolVersionNumber -Text $Minimum
        # An unreadable version cannot be shown to clear a floor, so it is never
        # assumed to. It is reported as unknown and the floor stays unproven.
        if ($null -eq $have) { return 'unknown-version' }
        if ($null -ne $floor -and $have -lt $floor) { return 'unsupported' }
    }
    if ($null -eq $have) { return 'unknown-version' }

    # Ranked by whichever key BOTH sides carry. Mixing a date stamp on one side
    # with a semantic version on the other compares two unrelated numbers, so
    # that case is reported as unknown rather than guessed at.
    $bothStamped = (Test-FmToolDateStamped -Text $Installed) -and (Test-FmToolDateStamped -Text $Latest)
    $mine = if ($bothStamped) { Get-FmToolComparableVersion -Text $Installed } else { $have }
    $newest = if ($bothStamped) { Get-FmToolComparableVersion -Text $Latest } else { Get-FmToolVersionNumber -Text $Latest }
    if ($null -eq $newest -or $null -eq $mine) { return 'unknown-latest' }
    if ($mine -lt $newest) { return 'older' }
    'current'
}

function Get-FmToolClassificationReason {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Requirement)

    switch ($Requirement.Classification) {
        'missing' { return "not installed - $($Requirement.Why)" }
        'current' { return "$($Requirement.Version) is the latest published version" }
        'older' { return "$($Requirement.Version) is installed; $($Requirement.Latest) is published" }
        'unsupported' {
            if ($Requirement.MinimumCapability) {
                return "$($Requirement.Version) is installed, and this port needs a build that $($Requirement.MinimumCapability)"
            }
            return "$($Requirement.Version) is installed; this repo requires at least $($Requirement.Minimum) ($($Requirement.MinimumSource))"
        }
        'unknown-version' { return "installed at $($Requirement.Path), but it prints no version this installer can read, so nothing about it is proven" }
        'unknown-latest' { return "$($Requirement.Version) is installed; the published version could not be read, so whether it is current is unknown" }
        default { return '' }
    }
}

# --- PATH ----------------------------------------------------------------------
#
# WHY THE PROCESS PATH IS REBUILT RATHER THAN READ. A tool installed into a
# per-user directory earlier in this same run is on the PERSISTED user PATH and
# not on this shell's copy of it, so the very next detection reports the tool that
# was just installed as missing. Measured with gh, which was present and reported
# absent. Anything this process added on top - a bin directory from a portable
# install - is preserved, because those entries are not persisted yet either.
function Update-FmToolSessionPath {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([string[]]$Keep = @())

    if (-not $PSCmdlet.ShouldProcess('this session', 'reload PATH from the persisted environment')) { return $env:PATH }

    $separator = [System.IO.Path]::PathSeparator
    $persisted = @(
        [Environment]::GetEnvironmentVariable('Path', 'User')
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ) | Where-Object { $_ }
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in @($persisted + $Keep + @($env:PATH))) {
        foreach ($entry in ($chunk -split $separator)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            if ($entries -contains $entry) { continue }
            $entries.Add($entry)
        }
    }
    $env:PATH = ($entries -join $separator)
    $env:PATH
}

# Is this directory already on the PATH the given scope would be asked to write?
function Test-FmToolOnPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('User', 'Process')][string]$Scope = 'User'
    )

    $separator = [System.IO.Path]::PathSeparator
    $normalized = $Directory.TrimEnd('\', '/')
    $onProcess = @($env:PATH -split $separator | Where-Object { $_ } |
            Where-Object { $_.TrimEnd('\', '/') -ieq $normalized }).Count -gt 0
    if ($Scope -eq 'Process') { return $onProcess }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onUser = @(($userPath -split $separator) | Where-Object { $_ } |
            Where-Object { $_.TrimEnd('\', '/') -ieq $normalized }).Count -gt 0
    return ($onProcess -and $onUser)
}

# Add a directory to the USER PATH and to this process, idempotently.
#
# -Scope Process exists for the suite: it exercises everything except the
# durable write, so a test run never edits the captain's real environment.
function Add-FmToolUserPath {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('User', 'Process')][string]$Scope = 'User'
    )

    if (Test-FmToolOnPath -Directory $Directory -Scope $Scope) {
        return [pscustomobject]@{ Action = 'already'; Detail = $Directory }
    }
    if (-not $PSCmdlet.ShouldProcess($Directory, "add to the $Scope PATH")) {
        return [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf' }
    }

    $separator = [System.IO.Path]::PathSeparator
    if ($Scope -eq 'User') {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $normalized = $Directory.TrimEnd('\', '/')
        $onUser = @(($userPath -split $separator) | Where-Object { $_ } |
                Where-Object { $_.TrimEnd('\', '/') -ieq $normalized }).Count -gt 0
        if (-not $onUser) {
            $updated = if ([string]::IsNullOrEmpty($userPath)) { $Directory } else { $userPath.TrimEnd($separator) + $separator + $Directory }
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        }
    }
    if (-not (Test-FmToolOnPath -Directory $Directory -Scope 'Process')) {
        $env:PATH = $env:PATH.TrimEnd($separator) + $separator + $Directory
    }
    [pscustomobject]@{ Action = 'updated'; Detail = $Directory }
}

# --- the enablers ---------------------------------------------------------------
#
# The things the installer would USE to install something else. Checked BEFORE
# they are used, and reported, so an absent one is an explained skip rather than
# a "command not found" in the middle of a run.
#
# WINGET IS RESOLVED BY PATH FIRST AND BY ITS REAL LOCATION SECOND.
# MEASURED on the captain's machine 2026-08-17: `Get-Command winget` fails, and
# %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe runs and prints v1.29.280. The
# user PATH carries `C:\WINDOWS\system32\config\systemprofile\AppData\Local\
# Microsoft\WindowsApps` - the SYSTEM profile's app-alias directory rather than
# this user's - so every winget route would have been refused as "winget is not
# available" on a machine that has winget. Looking in the real place turns a
# wrong refusal into a working install.
function Get-FmToolWingetPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $onPath = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return [string]$onPath.Source }
    if (-not $env:LOCALAPPDATA) { return '' }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft' 'WindowsApps' 'winget.exe'
    if (Test-Path -LiteralPath $alias -PathType Leaf) { return $alias }
    ''
}

function Get-FmToolEnablerStatus {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $enablers = @()

    # The shell this whole port is written against, and the one minimum the repo
    # states most often: `#requires -Version 7.0` at the top of every script.
    $psVersion = $PSVersionTable.PSVersion
    $enablers += [pscustomobject]@{
        Name        = 'PowerShell 7'
        Present     = $true
        Version     = $psVersion.ToString()
        Satisfied   = ($psVersion.Major -ge 7)
        Enables     = 'everything: every script in this repo declares #requires -Version 7.0'
        Fix         = 'install PowerShell 7 without administrator: & ([scriptblock]::Create((irm https://aka.ms/install-powershell.ps1))) -Destination "$env:LOCALAPPDATA\Programs\PowerShell7" -AddToPath'
    }

    $winget = Get-FmToolWingetPath
    $enablers += [pscustomobject]@{
        Name        = 'winget'
        Present     = [bool]$winget
        Version     = $(if ($winget) { (Get-FmInstallCommandVersion -Command $winget) } else { '' })
        Satisfied   = [bool]$winget
        Enables     = 'the git and Node.js routes, which are the only two that come from a package manager'
        Fix         = 'install "App Installer" from the Microsoft Store, or install git and Node.js by hand from git-scm.com and nodejs.org'
    }

    $npm = Get-Command -Name 'npm' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $enablers += [pscustomobject]@{
        Name        = 'npm'
        Present     = [bool]$npm
        Version     = $(if ($npm) { (Get-FmInstallCommandVersion -Command 'npm') } else { '' })
        Satisfied   = [bool]$npm
        Enables     = 'the five axi tools, which are published on npm'
        Fix         = 'it arrives with Node.js, so it appears once Node.js is installed - re-run this installer afterwards'
    }
    $enablers
}

# --- what is here, and what version ---------------------------------------------

function Get-FmToolStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Command)

    $resolved = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $resolved) {
        return [pscustomobject]@{ Command = $Command; Present = $false; Path = ''; Version = '' }
    }
    # THE VERSION IS THE PROOF, not the presence. A command that resolves but
    # answers nothing to --version is reported with an empty version, and the
    # classification treats that as unknown rather than as installed.
    [pscustomobject]@{
        Command = $Command
        Present = $true
        Path    = [string]$resolved.Source
        Version = (Get-FmInstallCommandVersion -Command $Command)
    }
}

function Test-FmToolElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not $IsWindows) { return $false }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Debug "could not determine whether this session is elevated: $_"
        return $false
    }
}

# The route for one tool, as a decision the installer can act on and print.
#
# Kind is one of:
#   portable   the vendor's release archive, expanded under the user's profile
#   command    the vendor's own published install one-liner
#   manual     no scriptable install exists; the instructions are printed
#   none       nothing is registered for this tool on this platform
function Get-FmToolRoute {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Tool)

    $portable = Get-FmBootstrapPortableRelease -Tool $Tool
    if ($portable) {
        return [pscustomobject]@{
            Tool               = $Tool
            Kind               = 'portable'
            Command            = "expand the $($portable.Repository) release asset $($portable.AssetPattern) into `$env:LOCALAPPDATA\Programs\$Tool"
            Portable           = $portable
            NeedsAdministrator = $false
            Instructions       = ''
        }
    }

    $manual = Get-FmBootstrapManualInstallUrl -Tool $Tool
    if ($manual) {
        return [pscustomobject]@{
            Tool               = $Tool
            Kind               = 'manual'
            Command            = ''
            Portable           = $null
            NeedsAdministrator = $false
            Instructions       = $manual
        }
    }

    $command = Get-FmBootstrapInstallCommand -Tool $Tool
    if (-not $command) {
        return [pscustomobject]@{
            Tool               = $Tool
            Kind               = 'none'
            Command            = ''
            Portable           = $null
            NeedsAdministrator = $false
            Instructions       = ''
        }
    }
    [pscustomobject]@{
        Tool               = $Tool
        Kind               = 'command'
        # The trailing "  # or ..." hint is advice for a human, not part of the
        # command to run - the same convention Install-FmTool follows.
        Command            = ($command -replace '\s\s#.*$', '')
        Portable           = $null
        NeedsAdministrator = (Test-FmBootstrapInstallNeedsAdministrator -Tool $Tool)
        Instructions       = ''
    }
}

# --- the portable-release install -----------------------------------------------

# Which asset of a release is the one for this machine. Split out from the
# download so the choice is testable against a captured release listing rather
# than only against the network.
function Get-FmToolReleaseAsset {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$AssetPattern
    )

    $assets = @()
    if ($Release.PSObject.Properties.Name -contains 'assets') { $assets = @($Release.assets) }
    $match = @($assets | Where-Object { [string]$_.name -like $AssetPattern } | Select-Object -First 1)
    if ($match.Count -eq 0) {
        throw "error: no asset matching '$AssetPattern' in release '$($Release.tag_name)'"
    }
    [pscustomobject]@{
        Name = [string]$match[0].name
        Url  = [string]$match[0].browser_download_url
        Tag  = [string]$Release.tag_name
    }
}

# Expand an archive into a destination that ends up holding the tool.
#
# -StripRoot is for an archive whose contents sit under one versioned directory.
# Expanding into a staging directory first and then moving is what makes both
# shapes land in the same place, and what makes a re-run replace the previous
# version rather than merge with it.
function Expand-FmToolArchive {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$StripRoot
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "error: '$ArchivePath' is not a file; nothing to expand"
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, "expand $ArchivePath")) { return $Destination }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-tool-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging -Force
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
        $source = $staging
        if ($StripRoot) {
            $roots = @(Get-ChildItem -LiteralPath $staging -Force)
            if ($roots.Count -ne 1 -or -not $roots[0].PSIsContainer) {
                throw "error: -StripRoot expected exactly one directory at the root of '$ArchivePath', found $($roots.Count) entries"
            }
            $source = $roots[0].FullName
        }
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        $parent = Split-Path -Parent $Destination
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force
        }
        Move-Item -LiteralPath $source -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $Destination
}

# The whole no-administrator install for one tool, end to end.
#
# -ArchivePath is the suite's seam: it supplies a local archive so every step
# except the download runs for real against a disposable install root. Nothing
# about the expansion, the layout check or the PATH edit is stubbed, which is
# what makes the test worth having.
function Install-FmToolPortable {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Portable,
        [string]$InstallRoot = '',
        [string]$ArchivePath = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User'
    )

    if (-not $InstallRoot) {
        if (-not $env:LOCALAPPDATA) { throw 'error: LOCALAPPDATA is not set, so there is no per-user place to install into' }
        $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs'
    }
    $destination = Join-Path $InstallRoot $Portable.Tool
    $binDirectory = if ($Portable.BinSubdirectory) { Join-Path $destination $Portable.BinSubdirectory } else { $destination }

    if (-not $PSCmdlet.ShouldProcess($destination, "install $($Portable.Tool) from $($Portable.Repository)")) {
        return [pscustomobject]@{ Tool = $Portable.Tool; Action = 'skipped'; Detail = 'WhatIf'; BinDirectory = $binDirectory }
    }

    $archive = $ArchivePath
    $downloaded = ''
    try {
        if (-not $archive) {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Portable.Repository)/releases/latest" `
                -Headers @{ 'User-Agent' = 'firstmate-win' } -ErrorAction Stop
            $asset = Get-FmToolReleaseAsset -Release $release -AssetPattern $Portable.AssetPattern
            $downloaded = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-tool-' + [guid]::NewGuid().ToString('N') + '-' + $asset.Name)
            Invoke-WebRequest -Uri $asset.Url -OutFile $downloaded -ErrorAction Stop
            $archive = $downloaded
        }
        $null = Expand-FmToolArchive -ArchivePath $archive -Destination $destination -StripRoot:([bool]$Portable.StripRoot) -Confirm:$false
    } finally {
        if ($downloaded -and (Test-Path -LiteralPath $downloaded)) {
            Remove-Item -LiteralPath $downloaded -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path -LiteralPath $binDirectory -PathType Container)) {
        throw "error: '$($Portable.Tool)' expanded into '$destination' but '$binDirectory' is not there; the release layout is not what this route expects"
    }
    $null = Add-FmToolUserPath -Directory $binDirectory -Scope $PathScope -Confirm:$false
    [pscustomobject]@{
        Tool         = $Portable.Tool
        Action       = 'installed'
        Detail       = $destination
        BinDirectory = $binDirectory
    }
}

# --- running one route -----------------------------------------------------------

# The same route, asked to REPLACE what is there rather than to put it there.
#
# Only winget needs the distinction, and needing it is not cosmetic: `winget
# install <id>` on a package that is already present reports "already installed"
# and exits 0 WITHOUT upgrading anything, so a captain who agreed to an update
# would have been told it happened and left on the old version. `winget upgrade`
# is the verb that replaces it.
#
# Every other route already installs the newest thing there is: the vendor
# installers for Claude Code, herdr and treehouse resolve latest on each run,
# the portable route takes the latest release, and `npm install -g` takes the
# latest published package. Rewriting those would be a change with no effect.
function Get-FmToolUpdateCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Command)

    if ($Command -match '^\s*winget\s+install\s') {
        return ($Command -replace '^\s*winget\s+install\s', 'winget upgrade ')
    }
    $Command
}

# Run one route, and report what it did.
#
# THE ROUTE NAMES ITS OWN TOOL, and that is the whole parameter list on purpose.
# This function used to take a second, untyped -Entry record as well and read
# $Entry.Tool off it. Nothing declared what shape that record had to be, and the
# one caller passes a requirement from Get-FmMachineInstallPlan, which publishes
# Name rather than Tool. Under strict mode the very first non-module install
# threw "The property 'Tool' cannot be found on this object" and took the whole
# run with it - MEASURED on the captain's clean Windows 11 machine, 2026-08-20,
# at the one step no machine that already had the tools could ever reach.
#
# So there is no second record to disagree with any more. Every route record -
# Get-FmToolRoute's, and the module route Install-FmMachine builds - carries
# Tool, because a route for no particular tool is not a thing.
function Invoke-FmToolRoute {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Route,
        [string]$InstallRoot = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User',
        [switch]$Update
    )

    $result = [pscustomobject]@{ Tool = $Route.Tool; Action = 'skipped'; Detail = '' }

    switch ($Route.Kind) {
        'none' {
            $result.Action = 'skipped'
            $result.Detail = 'no install route is registered for this tool on this platform'
            return $result
        }
        'manual' {
            # A named manual step is an acceptable answer; a silently wrong
            # install is not. The instructions are the whole report.
            $result.Action = 'manual'
            $result.Detail = "install it by hand: $($Route.Instructions)"
            return $result
        }
        'portable' {
            if (-not $PSCmdlet.ShouldProcess($Route.Tool, 'install from the vendor release archive')) {
                $result.Detail = 'WhatIf'
                return $result
            }
            try {
                $installed = Install-FmToolPortable -Portable $Route.Portable -InstallRoot $InstallRoot `
                    -PathScope $PathScope -Confirm:$false
                $result.Action = 'installed'
                $result.Detail = $installed.Detail
            } catch {
                $result.Action = 'failed'
                $result.Detail = [string]$_.Exception.Message
            }
            return $result
        }
    }

    # 'command': the vendor's own published one-liner.
    if ($Route.NeedsAdministrator -and -not (Test-FmToolElevated)) {
        $result.Action = 'needs-admin'
        $result.Detail = "run this once in an ADMINISTRATOR shell, then re-run this installer: $($Route.Command)"
        return $result
    }
    if (-not $PSCmdlet.ShouldProcess($Route.Tool, "run: $($Route.Command)")) {
        $result.Detail = 'WhatIf'
        return $result
    }

    # THE ENABLER IS CHECKED BEFORE IT IS USED, never after it has failed.
    $command = $Route.Command
    if ($Update) { $command = Get-FmToolUpdateCommand -Command $command }
    if ($command -match '^\s*winget\s') {
        $winget = Get-FmToolWingetPath
        if (-not $winget) {
            $result.Action = 'blocked'
            $result.Detail = "winget is not on this machine, so '$command' cannot run. Install 'App Installer' from the Microsoft Store, or install this tool by hand, then re-run"
            return $result
        }
        $command = $command -replace '^\s*winget\s', ('& "' + $winget + '" ')
    }
    if ($command -match '(^|\s)npm\s' -and -not (Get-Command -Name 'npm' -CommandType Application -ErrorAction SilentlyContinue)) {
        $result.Action = 'blocked'
        $result.Detail = 'npm is not on this machine yet - it arrives with Node.js, so install Node.js first and re-run this installer'
        return $result
    }

    # The published install lines are captain-facing one-liners (pipelines, &&
    # chains), so they are run through PowerShell exactly as documented rather
    # than picked apart into arguments here.
    $pwsh = (Get-Process -Id $PID).Path
    $output = @(& $pwsh -NoProfile -Command $command 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        $tail = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
        $result.Action = 'failed'
        $result.Detail = "'$($Route.Command)' exited $LASTEXITCODE" + $(if ($tail.Count) { ": $($tail[0])" } else { '' })
        return $result
    }
    $result.Action = 'installed'
    $result.Detail = $Route.Command
    $result
}

# --- the modules ----------------------------------------------------------------

function Get-FmToolModuleStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Requirement)

    $found = @(Get-Module -ListAvailable -Name $Requirement.Name -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1)
    if ($found.Count -eq 0) {
        return [pscustomobject]@{ Name = $Requirement.Name; Present = $false; Version = ''; Path = '' }
    }
    [pscustomobject]@{
        Name    = $Requirement.Name
        Present = $true
        Version = $found[0].Version.ToString()
        Path    = [string]$found[0].ModuleBase
    }
}

function Install-FmToolModule {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Requirement,
        [switch]$Update
    )

    if (-not $PSCmdlet.ShouldProcess($Requirement.Name, 'Install-Module -Scope CurrentUser')) {
        return [pscustomobject]@{ Name = $Requirement.Name; Action = 'skipped'; Detail = 'WhatIf' }
    }
    try {
        $parameters = @{
            Name               = $Requirement.Name
            Scope              = 'CurrentUser'
            Force              = $true
            AllowClobber       = $true
            SkipPublisherCheck = $true
            ErrorAction        = 'Stop'
        }
        if ($Requirement.MinimumVersion) { $parameters['MinimumVersion'] = $Requirement.MinimumVersion }
        Install-Module @parameters
    } catch {
        return [pscustomobject]@{
            Name   = $Requirement.Name
            Action = 'failed'
            Detail = "$($_.Exception.Message) - install it by hand with: Install-Module $($Requirement.Name) -Scope CurrentUser"
        }
    }
    $after = Get-FmToolModuleStatus -Requirement $Requirement
    if (-not $after.Present) {
        return [pscustomobject]@{ Name = $Requirement.Name; Action = 'failed'; Detail = 'installed, but the module still does not resolve' }
    }
    [pscustomobject]@{
        Name   = $Requirement.Name
        Action = $(if ($Update) { 'updated' } else { 'installed' })
        Detail = $after.Version
    }
}
