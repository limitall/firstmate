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
#   unusable        present, and this machine refuses to START it
#   unsupported     present, below a minimum this repo STATES, or missing a
#                   stated capability
#   older           present, working, behind the latest published version
#   current         present and at or ahead of the latest published version
#   unknown-version present but its banner carries no readable version
#   unknown-latest  present, but the published version could not be determined
#
# 'unusable' OUTRANKS EVERY OTHER PRESENT CLASS, because none of them can be
# established about a program that never ran: a version was not read, a floor was
# not cleared, and a capability was not proved. Reporting it as any of those
# would state something this machine did not show.
function Get-FmToolClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][bool]$Present,
        [string]$Installed = '',
        [string]$Latest = '',
        [string]$Minimum = '',
        [bool]$CapabilityMet = $true,
        [bool]$Launchable = $true
    )

    if (-not $Present) { return 'missing' }
    if (-not $Launchable) { return 'unusable' }
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
        'unusable' {
            return (Get-FmToolLaunchRefusal -Program $Requirement.Path `
                    -Consequence 'it could not be run and nothing about it is proven' `
                    -Remedy "Open it yourself in a new window - if '$($Requirement.Command) --version' answers there, the refusal is this machine's and not the tool's.")
        }
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

    # AN ENABLER THAT WILL NOT START IS NOT AN ENABLER. Both of these are probed
    # by RUNNING them, and a machine that declines the launch makes the enabler
    # unsatisfied - so the routes that need it are skipped with a reason before
    # they are attempted, rather than each one discovering the same refusal.
    $winget = Get-FmToolWingetPath
    $wingetProbe = if ($winget) { Get-FmInstallCommandProbe -Command $winget } else { $null }
    $enablers += [pscustomobject]@{
        Name        = 'winget'
        Present     = [bool]$winget
        Version     = $(if ($wingetProbe) { $wingetProbe.Version } else { '' })
        Satisfied   = [bool]($wingetProbe -and $wingetProbe.Launched)
        Enables     = 'the git and Node.js routes, which are the only two that come from a package manager'
        Fix         = 'install "App Installer" from the Microsoft Store, or install git and Node.js by hand from git-scm.com and nodejs.org'
    }

    $npm = Get-Command -Name 'npm' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $npmProbe = if ($npm) { Get-FmInstallCommandProbe -Command 'npm' } else { $null }
    $enablers += [pscustomobject]@{
        Name        = 'npm'
        Present     = [bool]$npm
        Version     = $(if ($npmProbe) { $npmProbe.Version } else { '' })
        Satisfied   = [bool]($npmProbe -and $npmProbe.Launched)
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
        return [pscustomobject]@{ Command = $Command; Present = $false; Path = ''; Version = ''; Launchable = $false }
    }
    # THE VERSION IS THE PROOF, not the presence. A command that resolves but
    # answers nothing to --version is reported with an empty version, and the
    # classification treats that as unknown rather than as installed.
    #
    # AND "COULD NOT BE STARTED" IS A THIRD ANSWER, not a version of the second.
    # A file on PATH that Windows declines to launch prints no version either,
    # and calling that "prints no version this installer can read" describes the
    # wrong thing entirely: nothing was read because nothing ran.
    $probe = Get-FmInstallCommandProbe -Command $Command
    [pscustomobject]@{
        Command    = $Command
        Present    = $true
        Path       = [string]$resolved.Source
        Version    = $probe.Version
        Launchable = [bool]$probe.Launched
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

# --- a launch this machine refused -----------------------------------------------
#
# WHAT THIS AREA SHIPPED, and what it cost. A child shell that Windows declined
# to start raised a raw .NET error, took the whole run down with it, and printed
#
#   Program 'pwsh.exe' failed to run: An error occurred trying to start process
#   '...\PowerShell7\pwsh.exe' with working directory '...irstmate'.
#   Access is denied.
#
# followed by a stack trace. MEASURED on the captain's machine, 2026-08-20. That
# text is worse than useless: "access is denied" reads as a permission problem,
# and the first diagnosis drawn from it - one account running another account's
# PowerShell - was WRONG. The captain disproved it by running the whole thing as
# a single user, where it failed identically, and where that same executable had
# started successfully seconds earlier in the same session.
#
# So the report never quotes the exception. It says what was being started, that
# the MACHINE refused the launch rather than the program failing, and what to do
# instead. What refused it cannot be read from inside the denied process, so the
# usual suspects are offered as things to check rather than as a diagnosis.
function Get-FmToolLaunchRefusal {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Program,
        [string]$WorkingDirectory = '',
        [string]$Consequence = '',
        [string]$Remedy = ''
    )

    $what = if ($Program) { "'$Program'" } else { 'the program' }
    $where = if ($WorkingDirectory) { " from $WorkingDirectory" } else { '' }
    $text = "Windows refused to start $what$where"
    if ($Consequence) { $text += ", so $Consequence" }
    $text += '. The machine declined the launch; the program itself did not fail.'
    # The remedy goes LAST because it usually ends in a command to run, and a
    # sentence appended after a command line reads as part of it.
    $text += ' A launch refused with nothing but "access is denied" is usually security software guarding' +
    ' how a program is started, or Controlled folder access, which protects Documents - a checkout that is' +
    ' not under Documents rules the second one out.'
    if ($Remedy) { $text += " $Remedy" }
    $text
}

# THE CHILD'S EXIT CODE IS NOT THE TOOL'S, and that is why "exited 1" told the
# captain nothing.
#
# MEASURED here, 2026-08-20: `winget install` on a package that does not exist
# exits -1978335212 (0x8A150014) when run directly, and the same command run as
# `pwsh -Command <it>` makes the child exit 1. `pwsh -Command` reports its own
# verdict - 0 or 1 - and the native code inside it is discarded. So every winget
# failure this installer has ever reported arrived as a bare 1, a number that
# distinguishes nothing from anything and has no meaning to look up. The captain
# was handed exactly that.
#
# The epilogue below hands back the code the TOOL returned, and `$?` decides
# WHETHER the run failed while $LASTEXITCODE only supplies the number:
#   - `$?` is captured first, before any statement of ours can overwrite it
#   - a run `$?` calls successful exits 0 whatever $LASTEXITCODE holds, so a code
#     left behind by some earlier native call inside a vendor script cannot turn
#     a working install into a reported failure
#   - a failure with no native code of its own falls back to 1, which is what the
#     shell would have said anyway
#   - a command that throws never reaches the epilogue, and pwsh exits 1 by itself
#
# IT IS APPENDED ON ITS OWN LINE, not after a semicolon: the published one-liners
# carry trailing `# ...` notes, and on one line a comment swallows everything
# after it - including this.
function Get-FmToolShellCommandText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)

    @(
        $Command
        '$fmOk = $?'
        '$fmCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }'
        'if ($fmOk) { exit 0 }'
        'if ($fmCode -ne 0) { exit $fmCode }'
        'exit 1'
    ) -join [System.Environment]::NewLine
}

# Run one captain-facing install one-liner in a child PowerShell, and never let a
# refused launch escape.
#
# THE CHILD IS DELIBERATE. The published install lines are one-liners written for
# a person (pipelines, `&&` chains), so they are run through PowerShell exactly as
# documented rather than picked apart into arguments here, and a vendor script
# that wrecks its session wrecks a session this run is finished with.
#
# THE CAPTURE IS WHAT MAKES THE LAUNCH DIFFERENT, and it is why one launch of an
# executable can be refused seconds after another succeeded. Collecting the
# child's output through `2>&1 |` means .NET must redirect its streams, and .NET
# REFUSES to redirect a process started through the shell - measured: setting
# both raises "The Process object must have the UseShellExecute property set to
# false in order to redirect IO streams". So this launch always goes through
# CreateProcess, which is also the only path that produces the message the
# captain saw: "An error occurred trying to start process '<exe>' with working
# directory '<dir>'" is .NET's wording for that path and no other. install.ps1's
# own re-launch of the same executable captures nothing, so it is not the same
# operation, which is how one can be allowed and the other refused.
#
# -ShellPath is the suite's seam: it supplies a file that cannot be started, so
# the refusal path runs for real without needing a machine that refuses things.

function Invoke-FmToolShellCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$ShellPath = ''
    )

    $shell = if ($ShellPath) { $ShellPath } else { [string](Get-Process -Id $PID).Path }
    $workingDirectory = [string]$PWD.ProviderPath
    $refused = [pscustomobject]@{
        Launched         = $false
        ExitCode         = 1
        Output           = @()
        Shell            = $shell
        WorkingDirectory = $workingDirectory
    }
    if (-not $shell) { return $refused }

    $global:LASTEXITCODE = 0
    try {
        # -NonInteractive, because THE CAPTURE IS ALSO A GAG. This run collects
        # the child's output through a pipe, so a vendor installer that stops to
        # ask a question asks it INTO THE PIPE, where nobody sees it, and then
        # waits for an answer nobody knows is wanted: an install that stops dead
        # with a blank screen and no way to tell what it is waiting for.
        # -NonInteractive declares the child a host with nobody at it, so
        # PowerShell's own prompts do not wait on a person. MEASURED, 2026-08-20:
        # a route whose command calls Read-Host returns instead of waiting.
        #
        # It governs POWERSHELL's prompting only. A native program's prompt is
        # its own business, and winget's agreements are exactly that - which is
        # why they are answered by winget's flags in Get-FmBootstrapWingetCommand
        # rather than here. Whatever this cannot answer, the verification pass
        # still catches: a route that returned without installing anything is
        # reported by the check that looks for the tool afterwards.
        $out = @(& $shell -NoProfile -NonInteractive -Command (Get-FmToolShellCommandText -Command $Command) 2>&1 |
                ForEach-Object { [string]$_ })
    } catch {
        # Kept for a -Debug run and never shown to the captain: this is the exact
        # text that sent the first diagnosis after a permission problem that did
        # not exist.
        Write-Debug "could not start '$shell' in '$workingDirectory': $_"
        return $refused
    }
    [pscustomobject]@{
        Launched         = $true
        ExitCode         = $global:LASTEXITCODE
        Output           = $out
        Shell            = $shell
        WorkingDirectory = $workingDirectory
    }
}

# --- reporting an install that failed ----------------------------------------------
#
# THE DEFECT, AND WHAT IT COST. A failing install was reported as the command, its
# exit code, and the LAST non-blank line the tool printed:
#
#   [skipped] Node.js - FAILED: 'winget install OpenJS.NodeJS' exited 1:
#             Node.js OpenJS.NodeJS winget
#
# MEASURED from the captain's install log, 2026-08-20. That trailing fragment is
# not a sentence and not an error. It is a row of winget's package table - name,
# id, source - which is simply what the last line of that run happened to be.
# Firstmate read the report, found no cause in it, and told the captain the
# install needed administrator. It did not, and they were ALREADY running as
# administrator, because of that same advice. One failure reported without its
# cause produced a wrong diagnosis and cost them the time twice.
#
# THE LAST LINE OF A FAILING RUN IS NOT THE ERROR, and taking it is not a
# summary but a coin toss. MEASURED here, winget v1.29.280, 2026-08-20: a
# rejected command line prints a banner, then the error, then the usage block.
# The last line of that is usage boilerplate, and the error is in the middle.
#
# So the report carries what was run, what came back in full, and what the exit
# code means where this repo can say. Nothing here tries to pick out the one
# line that is the cause, because nothing reliably can.

# How much of a failing tool's output the report keeps, and what it says when it
# cannot keep all of it.
#
# QUOTE THE TOOL, NEVER SUMMARISE IT. A phrase distilled from an error is exactly
# the thing that has to be guessed at afterwards, and a report that quietly drops
# lines reads as the whole of the output - so a truncation says how many it left
# out and where.
#
# BOTH ENDS ARE KEPT, and that is not symmetry for its own sake. MEASURED here,
# winget v1.29.280, 2026-08-20: a rejected command line prints 51 lines, of which
# the cause - "Argument name was not recognized for the current command" - is the
# THIRD, and the remaining 48 are the usage block. Keeping the tail alone would
# have thrown that one line away and kept help text, which is the same mistake as
# reporting the last line, made more expensively.
$script:FmToolFailureOutputLines = 24
$script:FmToolFailureOutputHead = 8

function Format-FmToolFailureOutput {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Output = @())

    $said = @(@($Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd() })
    if ($said.Count -eq 0) { return [string[]]@() }
    if ($said.Count -le $script:FmToolFailureOutputLines) {
        return [string[]](@('what it printed, in full:') + @($said | ForEach-Object { "    $_" }))
    }

    $head = $script:FmToolFailureOutputHead
    $tail = $script:FmToolFailureOutputLines - $head
    $dropped = $said.Count - $script:FmToolFailureOutputLines
    [string[]](
        @("what it printed - $($said.Count) lines, of which the first $head and the last ${tail}:") +
        @(@($said | Select-Object -First $head) | ForEach-Object { "    $_" }) +
        @("    ... $dropped lines not shown ...") +
        @(@($said | Select-Object -Last $tail) | ForEach-Object { "    $_" })
    )
}

# What this repo can say a nonzero exit MEANS, and not one word more.
#
# Every entry was measured on this machine rather than copied off a table, and an
# unrecognised code returns '' so the report carries the tool's own text instead
# of a meaning invented for it. Guessing at a cause is the defect this whole
# area exists to stop repeating.
function Get-FmToolExitCodeMeaning {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory)][int]$ExitCode
    )

    if ($Command -match '(^|\s)winget(\s|$)|winget\.exe') {
        # MEASURED, winget v1.29.280, 2026-08-20. winget reports its own failures
        # as HRESULTs in the 0x8A15xxxx range, which arrive here as large
        # negative numbers.
        switch ($ExitCode) {
            -1978335230 { return 'winget rejected the command line it was given' }
            -1978335212 { return 'winget found no package matching what it was asked for' }
            # MEASURED from the captain's clean-VM install log, 2026-08-20:
            # winget printed this one about itself - "0x8a15005e : The server
            # certificate did not match any of the expected values" - so this
            # entry is winget's own sentence, not a meaning invented for a
            # number. It reached the captain because the msstore source was
            # unhealthy on that machine; every route now pins --source winget,
            # so seeing it again means the source this repo DOES need is the one
            # that cannot be reached - a TLS-inspecting proxy or a clock skew on
            # the machine itself, not a package problem.
            -1978335138 { return "a source's server certificate did not match what winget expected" }
            default { return '' }
        }
    }
    ''
}

# One failed run, reported so the reader can act without guessing: what was run,
# what came back, and what the exit code means where that is known.
function Get-FmToolRunFailureDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowEmptyCollection()][AllowNull()][string[]]$Output = @(),
        # What actually ran, when that is not what the captain would type. winget
        # is resolved to its real location rather than by name, and knowing WHICH
        # winget ran has already mattered once on this machine.
        [string]$AsRun = ''
    )

    # A winget HRESULT is unreadable as a signed decimal, which is the form it
    # arrives in, so both forms are printed for anything outside a plain exit
    # status.
    $code = if ($ExitCode -lt 0 -or $ExitCode -gt 255) { '{0} (0x{1:X8})' -f $ExitCode, $ExitCode } else { [string]$ExitCode }
    $headline = "'$Command' exited $code"
    $meaning = Get-FmToolExitCodeMeaning -Command $Command -ExitCode $ExitCode
    if ($meaning) { $headline += ", which means $meaning" }

    $said = @(Format-FmToolFailureOutput -Output $Output)
    $lines = @()
    if ($said.Count) {
        $lines += "$headline."
        $lines += $said
    } else {
        # AN EMPTY ANSWER IS ITSELF THE FINDING. "No cause was printed" and "no
        # cause was reported" are different facts, and only one of them is about
        # the tool.
        $lines += "$headline, and printed nothing at all - so there is no error text to read, and the exit code is the whole of what it said."
    }
    if ($AsRun -and $AsRun -ne $Command) { $lines += "run as: $AsRun" }
    $lines -join [System.Environment]::NewLine
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
        [switch]$Update,
        # The suite's seam, forwarded whole to Invoke-FmToolShellCommand: a shell
        # that cannot be started, so the refusal this function must survive is
        # exercised end to end without a machine that refuses anything.
        [string]$ShellPath = ''
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

    # A REFUSED LAUNCH IS AN OUTCOME, NOT AN EXCEPTION. This used to be a bare
    # invocation, so a machine that declined to start the child shell ended the
    # whole install with a .NET error and a stack trace at the first tool that
    # needed one - every later requirement went unattempted and unreported.
    $run = Invoke-FmToolShellCommand -Command $command -ShellPath $ShellPath
    if (-not $run.Launched) {
        $result.Action = 'blocked'
        $result.Detail = Get-FmToolLaunchRefusal -Program $run.Shell -WorkingDirectory $run.WorkingDirectory `
            -Consequence "$($Route.Tool) was not installed" `
            -Remedy "Run this yourself in a new PowerShell 7 window, then re-run this installer: $($Route.Command)"
        return $result
    }
    if ($run.ExitCode -ne 0) {
        $result.Action = 'failed'
        # The ROUTE's command is the headline because it is the line the captain
        # can run themselves; the resolved one follows only when it differs.
        $result.Detail = Get-FmToolRunFailureDetail -Command $Route.Command -ExitCode $run.ExitCode `
            -Output $run.Output -AsRun $command
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

# THE OTHER THING THAT CAN STOP AND ASK. PSGallery is Untrusted on a machine
# nobody has told otherwise, and Install-Module then asks "are you sure you want
# to install the modules from 'PSGallery'?" before it does anything. -Force is
# what answers that ahead of the prompt, and it is why it is here; -Confirm:$false
# refuses the other route to the same halt, a ShouldProcess confirmation
# inherited from a caller that asked for one. The portable route already defends
# itself this way, and this one did not.
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
            Confirm            = $false
            ErrorAction        = 'Stop'
        }
        if ($Requirement.MinimumVersion) { $parameters['MinimumVersion'] = $Requirement.MinimumVersion }
        Install-Module @parameters
    } catch {
        # SAME RULE AS A FAILED ROUTE. What was run, then what it said, quoted
        # rather than folded into a sentence of this repo's own.
        $byHand = "Install-Module $($Requirement.Name) -Scope CurrentUser"
        $said = @(Format-FmToolFailureOutput -Output @([string]$_.Exception.Message -split '\r?\n'))
        $lines = @("'$byHand' did not complete.") + $said
        $lines += "Run that line yourself to see it fail in front of you, then re-run this installer."
        return [pscustomobject]@{
            Name   = $Requirement.Name
            Action = 'failed'
            Detail = ($lines -join [System.Environment]::NewLine)
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
