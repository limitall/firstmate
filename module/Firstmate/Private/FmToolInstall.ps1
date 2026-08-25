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
#
# RUNTIME NAMES THE ONE TOOL THAT IMPORTS A RUNTIME WINDOWS DOES NOT SHIP, and
# it is a fact about that tool rather than about firstmate. MEASURED from
# herdr.exe 0.8.2's own import table, not guessed - docs/windows-e2e-evidence.md
# section 40.3 has the full list, and VCRUNTIME140.dll is the single name on it
# that a clean Windows 11 install does not have. It lives here, on the row for
# the tool that has the import, so the day herdr links it statically this row
# changes and nothing else does. Get-FmToolRuntimeRequirement owns what the
# runtime IS; this owns which tools need it.
$script:FmToolCatalog = @(
    @{ Tool = 'git';                 Command = 'git';                 Label = 'git';                 Why = 'isolated copies for workers';     Required = $true;  Runtime = $false }
    @{ Tool = 'node';                Command = 'node';                Label = 'Node.js';             Why = 'carries the npm-published axi tools'; Required = $true;  Runtime = $false }
    @{ Tool = 'claude';              Command = 'claude';              Label = 'Claude CLI';          Why = 'firstmate itself';                Required = $true;  Runtime = $false }
    @{ Tool = 'herdr';               Command = 'herdr';               Label = 'herdr';               Why = 'worker sessions';                 Required = $true;  Runtime = $true }
    @{ Tool = 'treehouse';           Command = 'treehouse';           Label = 'treehouse';           Why = 'isolated worktrees, leased';      Required = $true;  Runtime = $false }
    @{ Tool = 'gh';                  Command = 'gh';                  Label = 'gh';                  Why = 'pull requests';                   Required = $false; Runtime = $false }
    @{ Tool = 'gh-axi';              Command = 'gh-axi';              Label = 'gh-axi';              Why = 'GitHub, ergonomically';           Required = $false; Runtime = $false }
    @{ Tool = 'chrome-devtools-axi'; Command = 'chrome-devtools-axi'; Label = 'chrome-devtools-axi'; Why = 'browser work';                    Required = $false; Runtime = $false }
    @{ Tool = 'lavish-axi';          Command = 'lavish-axi';          Label = 'lavish-axi';          Why = 'visual reviews';                  Required = $false; Runtime = $false }
    @{ Tool = 'tasks-axi';           Command = 'tasks-axi';           Label = 'tasks-axi';           Why = 'shared backlog format';           Required = $false; Runtime = $false }
    @{ Tool = 'quota-axi';           Command = 'quota-axi';           Label = 'quota-axi';           Why = 'model headroom before dispatch';  Required = $false; Runtime = $false }
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
                Runtime  = [bool]$_.Runtime
            }
        })
    if ($RequiredOnly) { return @($entries | Where-Object { $_.Required }) }
    $entries
}

# The command a tool is RUN as, which is not always what it is called. Every
# entry in the catalog above answers for itself; a tool that is not in it - a
# route exercised by the suite under a made-up name - is run as its own name,
# which is the only answer available and the right one for every real case.
function Get-FmToolCommandName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Tool)

    $entry = @(Get-FmToolCatalog | Where-Object { $_.Tool -eq $Tool } | Select-Object -First 1)
    if ($entry.Count -gt 0) { return $entry[0].Command }
    $Tool
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

# ONE READING OF THE NODE DIST INDEX, because two consumers ask about it and they
# must not disagree: the currency check asks "is the installed Node.js behind?",
# and the per-user install route asks "which build am I fetching?". A route that
# installed the newest CURRENT release while the check ranked against the newest
# LTS would report the machine older the moment it finished.
function Get-FmToolNodeLatestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$TimeoutSeconds = 20)

    try {
        # No @(): see Get-FmToolGitHubLatestVersion. The dist index is one JSON
        # array, and wrapping it hid a thousand versions inside a single element.
        $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        # LTS is what a working machine should be on; the newest current release
        # is not what `winget install OpenJS.NodeJS` gives either.
        $lts = @($index | Where-Object { $_.lts } | Select-Object -First 1)
        if ($lts.Count -eq 0) { return '' }
        return [string]$lts[0].version
    } catch {
        Write-Debug "could not read the latest Node.js release: $_"
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
        # THE VENDOR'S OWN ANSWER, from the same manifest their installer reads
        # and this repo's route installs from - so "is it current" and "what
        # would be installed" cannot disagree. It also replaced a GitHub
        # prerelease scan whose newest tag is a date stamp, which nothing can
        # rank against the `herdr 0.8.2` the tool itself prints.
        'herdr' {
            try {
                $manifest = Invoke-RestMethod -Uri 'https://herdr.dev/latest.json' -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                return (Get-FmToolManifestVersion -Manifest $manifest)
            } catch {
                Write-Debug "could not read the latest herdr release: $_"
                return ''
            }
        }
        'claude' {
            try {
                return ([string](Invoke-RestMethod -Uri 'https://downloads.claude.ai/claude-code-releases/latest' `
                            -TimeoutSec $TimeoutSeconds -ErrorAction Stop)).Trim()
            } catch {
                Write-Debug "could not read the latest Claude Code version: $_"
                return ''
            }
        }
        'node' { return (Get-FmToolNodeLatestVersion -TimeoutSeconds $TimeoutSeconds) }
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
#                   stated capability, and what this repo needs can only be put
#                   there by REPLACING it
#   superseded      the same, except that what this repo needs installs BESIDE
#                   it and leaves it exactly where it is
#   older           present, working, behind the latest published version
#   current         present and at or ahead of the latest published version
#   unknown-version present but its banner carries no readable version
#   unknown-latest  present, but the published version could not be determined
#
# 'unusable' OUTRANKS EVERY OTHER PRESENT CLASS, because none of them can be
# established about a program that never ran: a version was not read, a floor was
# not cleared, and a capability was not proved. Reporting it as any of those
# would state something this machine did not show.
#
# WHY 'superseded' IS A CLASS AND NOT A SOFTER 'unsupported'. The rule that an
# unsupported requirement is told and SKIPPED exists to stop this installer
# writing over a working tool the captain never agreed to replace. That rule is
# about REPLACEMENT, and a PowerShell module install is not one: PowerShell keeps
# every version of a module in its own version directory and loads by version, so
# Install-Module -Scope CurrentUser adds a directory to the user's own module
# tree and removes nothing.
#
# MEASURED, 2026-08-21, on the machine this was written on - which is in exactly
# the state a clean VM is in: Windows' own Pester 3.4.0 sits in
# C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0 and a Pester 6.1.0 sits
# in a separate tree, both are listed by Get-Module -ListAvailable, and this
# repo's suite runs on the 6.1.0 one. Side-by-side is not a hope here; it is what
# this machine is doing.
#
# MEASURED on the captain's clean Windows 11 VM, 2026-08-21: every clean machine
# has that Pester 3.4.0, the run refused to install 5+ over it, printed a command
# for the captain to run, and reported the machine NOT READY. That was a step the
# captain had to perform for a job this installer is perfectly able to do, and
# this class is what removes it.
function Get-FmToolClassification {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][bool]$Present,
        [string]$Installed = '',
        [string]$Latest = '',
        [string]$Minimum = '',
        [bool]$CapabilityMet = $true,
        [bool]$Launchable = $true,
        # Set only where installing what this repo needs leaves what is already
        # there untouched. Get-FmMachineInstallPlan is the one caller that sets
        # it, and it sets it for modules and never for tools.
        [bool]$Supersedable = $false
    )

    $belowFloor = if ($Supersedable) { 'superseded' } else { 'unsupported' }

    if (-not $Present) { return 'missing' }
    if (-not $Launchable) { return 'unusable' }
    if (-not $CapabilityMet) { return $belowFloor }

    $have = Get-FmToolVersionNumber -Text $Installed
    if ($Minimum) {
        $floor = Get-FmToolVersionNumber -Text $Minimum
        # An unreadable version cannot be shown to clear a floor, so it is never
        # assumed to. It is reported as unknown and the floor stays unproven.
        if ($null -eq $have) { return 'unknown-version' }
        if ($null -ne $floor -and $have -lt $floor) { return $belowFloor }
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

# THE ONE SENTENCE FOR A TOOL THAT IS THERE AND PROVES NOTHING, said in one place
# because two places were saying it differently and neither said enough.
#
# The proving pass said "'herdr' resolves to <path> but answers nothing to
# --version" and the plan said "installed at <path>, but it prints no version
# this installer can read" - two wordings for one fact, and the drift the
# one-owner rule exists to stop. Both now come through here, and both now carry
# the code the tool returned.
#
# EVERY STRING HERE ACCEPTS EMPTY, and that is a safety property rather than
# tidiness. A mandatory parameter that refuses the value it is handed does not
# fail - it ASKS, and this function is only ever called while composing a report
# on a console nobody is watching. Commit 2f4d97e is that bug in the install's
# own self-check, and `CONTRIBUTING.md` states the rule it broke: a command this
# repo runs for the captain must complete with nobody at the keyboard. A report
# line built from an empty command name is wrong and readable; a report line that
# stops to ask for one hangs the install.
function Get-FmToolUnprovenDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$ExitCode = 0
    )

    $where = if ($Path) { " resolves to $Path but" } else { '' }
    $text = "'$Command'$where answers nothing to --version, so it is not verified as the real tool"
    if ($ExitCode -ne 0) {
        $text += (' - it exited 0x{0:X8}' -f $ExitCode)
        $meaning = Get-FmToolExitCodeMeaning -Command $Command -ExitCode $ExitCode
        if ($meaning) { $text += ", which means $meaning" }
    }
    $text
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
        'superseded' {
            $where = if ($Requirement.Path) { " in $($Requirement.Path)" } else { '' }
            return ("$($Requirement.Version) is installed$where; this repo needs at least $($Requirement.Minimum) " +
                "($($Requirement.MinimumSource)), so this run installs it into your own module directory BESIDE that copy, " +
                'which is left exactly as it is')
        }
        'unknown-version' {
            return (Get-FmToolUnprovenDetail -Command $Requirement.Command -Path $Requirement.Path `
                    -ExitCode $Requirement.ExitCode)
        }
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

# A TOOL THIS RUN INSTALLED, MADE REACHABLE BY THIS RUN.
#
# THE DEFECT, MEASURED on the captain's clean Windows 11 VM, 2026-08-21:
#
#   [created] Claude CLI - irm https://claude.ai/install.ps1 | iex
#   ...
#   [missing] tool Claude CLI - not on PATH - firstmate itself
#             fix: irm https://claude.ai/install.ps1 | iex
#
# Both lines were true. The vendor's installer put claude.exe in the user's own
# profile, this process could not see it, and the run advised the captain to
# repeat an install that had already worked - then called a working machine
# broken. Reloading PATH from the persisted environment is the first answer and
# it is not always enough: an installer that reports where it put the tool
# instead of persisting a PATH entry leaves nothing to reload.
#
# So this asks the last question that is left - IS IT ACTUALLY THERE? - by
# looking in the directory that vendor's own installer uses, and puts that
# directory on PATH when the tool is in it. Get-FmBootstrapInstalledLocation owns
# the list; a tool with no entry, or an entry that is not there, changes nothing
# and this returns $false exactly as before.
function Resolve-FmToolAfterInstall {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string]$Command = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User',
        # The suite's seam: a directory list to search instead of the table, so
        # the recovery runs for real against a disposable directory rather than
        # needing a machine where a vendor installer has misbehaved.
        [string[]]$Candidate = @()
    )

    if (-not $Command) { $Command = $Tool }
    $found = [pscustomobject]@{ Tool = $Tool; Resolved = $false; Directory = ''; Recovered = $false }

    # 1. the environment itself, which is where an installer that persisted a
    #    PATH entry a moment ago has already written it.
    $null = Update-FmToolSessionPath -Confirm:$false
    if (Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue) {
        $found.Resolved = $true
        return $found
    }

    # 2. the vendor's own directory.
    $candidates = if ($Candidate.Count -gt 0) { $Candidate } else { @(Get-FmBootstrapInstalledLocation -Tool $Tool) }
    foreach ($candidate in $candidates) {
        $directory = [System.Environment]::ExpandEnvironmentVariables($candidate)
        if ($directory -match '%\w+%') { continue }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        $executable = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -ieq $Command -and $_.Extension -in @('.exe', '.cmd', '.bat', '.ps1', '') })
        if ($executable.Count -eq 0) { continue }
        if (-not $PSCmdlet.ShouldProcess($directory, "put the directory holding $Tool on PATH")) { continue }
        $null = Add-FmToolUserPath -Directory $directory -Scope $PathScope -Confirm:$false
        $found.Resolved = [bool](Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue)
        $found.Directory = $directory
        $found.Recovered = $found.Resolved
        if ($found.Resolved) { return $found }
    }
    $found
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

# --- the runtime a native tool needs, and the ONE step that asks for administrator ---
#
# WHY THIS EXISTS AT ALL, and why it reverses a decision recorded in
# docs/windows-e2e-evidence.md section 43.3. That section considered checking for
# the Visual C++ runtime up front and said no, on three grounds: it is herdr's
# dependency rather than firstmate's, running the tool tests the ACTUAL imports
# where a presence probe tests a guessed name, and a prerequisite nobody asked
# for costs a line on every clean install forever. It printed the elevated
# command instead and took no elevated step, because this installer's standing
# rule is that nothing here needs administrator.
#
# THE CAPTAIN OVERRULED IT, and they were right. That rule was ours; their
# instruction is that everything must be done from the script and nothing left
# for them to run by hand. They had already run the printed line themselves on a
# fresh VM, which is precisely what the rule was supposed to prevent.
#
# WHAT SURVIVES OF 43.3, because two thirds of it were never wrong:
#
#   - It is still herdr's dependency, so the FACT lives on herdr's catalog row
#     (Runtime = $true, read out of its import table) rather than on a standing
#     list of things firstmate needs. The day herdr links it statically, that
#     row changes and this whole check goes quiet on its own.
#   - Running the tool is still the stronger test, so it still WINS here:
#     Get-FmToolRuntimeStatus asks the loader first and the filesystem only when
#     no tool that imports the runtime has been run yet. The bar does not move -
#     installing the runtime never certifies herdr, which is still proved by
#     running it and reading a version back.
#   - The cost is now paid for. The line on a clean install is no longer a
#     prerequisite nobody asked for; it is the step that installs it.
#
# AND IT DOES NOT BREAK THE NO-PROMPTING RULE, which is a real rule with a real
# measurement behind it. docs/windows-install.md draws that line exactly: an
# installer may ask a question IT composed and printed, and must never let a
# child it started for verification ask one. A Windows consent dialog raised
# immediately under a printed paragraph saying what is about to be installed and
# why is the first kind. install.ps1 prints that paragraph, and is also the only
# caller that ever enables this - -Unattended and a redirected stdin both skip
# it, because a dialog nobody is there to see is exactly the halt that rule is
# about.

# WHAT THE RUNTIME IS, in one place. The package id, the DLL and the machine
# type are one fact about one Microsoft redistributable, and three callers need
# parts of it: the detection, the elevated install, and the fix line printed
# when a tool dies in the loader.
#
# VCRUNTIME140.dll is MEASURED, not guessed - docs/windows-e2e-evidence.md
# section 40.3 read herdr.exe 0.8.2's import table and found it the one name on
# it that a Windows installation does not supply.
#
# x64 AND NOT THE MACHINE'S ARCHITECTURE. herdr publishes one Windows build,
# windows-x86_64, so an ARM64 machine runs it under emulation and an emulated
# x64 process loads x64 DLLs. Both halves of this record follow from that: the
# package is the x64 one, and a copy of the DLL that is not an x64 image does
# not answer for it however present it looks.
function Get-FmToolRuntimeRequirement {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        Name      = 'vcredist'
        Label     = 'Visual C++ runtime'
        PackageId = 'Microsoft.VCRedist.2015+.x64'
        Dll       = 'VCRUNTIME140.dll'
        Machine   = 'x64'
        Enables   = 'herdr, which is what worker sessions run in - it imports a runtime Windows does not ship'
        Detail    = 'the Visual C++ 2015-2022 runtime it needs is missing from this machine'
    }
}

# What processor a file on disk was built for, read out of its PE header.
#
# THIS IS WHAT STOPS THE PROBE LYING. "VCRUNTIME140.dll exists" is not the
# question; "would an x64 process load THIS file" is. A machine carrying only
# the 32-bit redistributable has the name in SysWOW64, and an ARM64 machine
# carrying only the ARM64 one has it in System32 - both read as present to a
# bare Test-Path, and neither can satisfy the emulated x64 build that failed.
# Returns '' for anything that is not a PE image at all, which is the right
# answer for a file that could not be loaded whatever else is true.
function Get-FmToolImageMachine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $stream = [System.IO.File]::OpenRead($Path)
    } catch {
        Write-Debug "could not read '$Path' to identify it: $_"
        return ''
    }
    try {
        $dos = [byte[]]::new(0x40)
        if ($stream.Read($dos, 0, 0x40) -lt 0x40) { return '' }
        # 'MZ', and then the offset the DOS stub keeps to the real header.
        if ($dos[0] -ne 0x4D -or $dos[1] -ne 0x5A) { return '' }
        $peOffset = [System.BitConverter]::ToInt32($dos, 0x3C)
        if ($peOffset -le 0 -or ($peOffset + 6) -gt $stream.Length) { return '' }
        $stream.Position = $peOffset
        $header = [byte[]]::new(6)
        if ($stream.Read($header, 0, 6) -lt 6) { return '' }
        # 'PE\0\0', then the machine field.
        if ($header[0] -ne 0x50 -or $header[1] -ne 0x45 -or $header[2] -ne 0 -or $header[3] -ne 0) { return '' }
        $machine = [System.BitConverter]::ToUInt16($header, 4)
        switch ($machine) {
            0x8664 { return 'x64' }
            0x014C { return 'x86' }
            0xAA64 { return 'arm64' }
            default { return ('0x{0:X4}' -f $machine) }
        }
    } catch {
        Write-Debug "could not identify '$Path': $_"
        return ''
    } finally {
        $stream.Dispose()
    }
}

# Where an x64 process's loader would look for this DLL.
#
# The same list the diagnostic in docs/windows-e2e-evidence.md section 40.7 uses,
# which was run against all three cases before it was written down: the system
# directory, the Windows directory, then PATH. The exe's own directory is not on
# it because this may run before any tool that needs the runtime is on the
# machine at all - and a tool that shipped its own copy beside itself would
# START, which is answered above this one and never reaches the files.
function Get-FmToolRuntimeSearchPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $directories = @()
    if ($env:SystemRoot) {
        $directories += (Join-Path $env:SystemRoot 'System32')
        $directories += $env:SystemRoot
    }
    if ($env:PATH) {
        $directories += @($env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ })
    }
    [string[]]@($directories)
}

# Is the runtime on this machine, and what says so.
#
# THE ORDER IS THE WHOLE DESIGN, and it is chosen so this can never report
# present on a machine where the loader would still fail:
#
#   1. A tool that imports it and DIED in the loader. Windows has already
#      answered the question and its answer beats any file on disk - this is the
#      case a file probe cannot see, where the DLL is present and older than the
#      build importing from it (0xC0000139 / 0xC0000138).
#   2. A tool that imports it and RAN, printing a version. The loader resolved
#      every import it has; nothing on disk can contradict that.
#   3. Only then, the file: the DLL, in the directories an x64 loader searches,
#      and an x64 image where one is found.
#
# 3 IS THE ONE THAT CAN STILL BE OPTIMISTIC, and it is named here rather than
# hidden: a copy that is present, x64 and older than some future build needs
# reads as present until a tool is actually run against it. That is exactly why
# the tool proof stays the authority on whether this machine is ready, and why
# the remedy line survives on every path below.
#
# -SearchPath is the suite's seam, and a test that uses it stages $env:PATH too:
# stages 1 and 2 read the real PATH, so a machine with a working herdr on it
# would otherwise answer before the files are ever looked at.
function Get-FmToolRuntimeStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][string[]]$SearchPath = @())

    $requirement = Get-FmToolRuntimeRequirement
    $answer = [pscustomobject]@{
        Label   = $requirement.Label
        Dll     = $requirement.Dll
        Present = $false
        Path    = ''
        Machine = ''
        Source  = 'nothing'
        Detail  = ''
        # CARRIED ON THE RECORD so the one caller outside this module -
        # install.ps1, which prints it before raising the consent dialog and
        # again when it cannot - never builds a second copy of the line. It is
        # here for the same reason a requirement carries UpdateCommand.
        Command = (Get-FmBootstrapWingetCommand -PackageId $requirement.PackageId)
    }

    # 1 and 2: what the loader itself has already said, where a tool that
    # imports the runtime is on this machine.
    $ran = @()
    foreach ($entry in @(Get-FmToolCatalog | Where-Object { $_.Runtime })) {
        $status = Get-FmToolStatus -Command $entry.Command
        if (-not $status.Present) { continue }
        if (Get-FmToolExitCodeRemedy -ExitCode $status.ExitCode) {
            $answer.Source = 'the loader'
            $answer.Detail = ("$($entry.Label) is installed on this machine and Windows stopped it before it ran, " +
                "which is what a missing or outdated $($requirement.Dll) does")
            return $answer
        }
        if ($status.Version) { $ran += $entry.Label }
    }
    if ($ran.Count -gt 0) {
        $answer.Present = $true
        $answer.Source = 'the loader'
        $answer.Detail = "$($ran[0]) runs on this machine, so every import it has, including $($requirement.Dll), resolved"
        return $answer
    }

    # 3: the file, where an x64 loader would look for it.
    $directories = if ($SearchPath.Count -gt 0) { @($SearchPath) } else { @(Get-FmToolRuntimeSearchPath) }
    $wrongMachine = ''
    foreach ($directory in $directories) {
        $candidate = ''
        try { $candidate = Join-Path $directory $requirement.Dll } catch { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $machine = Get-FmToolImageMachine -Path $candidate
        if ($machine -eq $requirement.Machine) {
            $answer.Present = $true
            $answer.Path = $candidate
            $answer.Machine = $machine
            $answer.Source = 'the file'
            $answer.Detail = "$($requirement.Dll) is on this machine, as an $machine build, at $candidate"
            return $answer
        }
        if ($machine -and -not $wrongMachine) {
            $wrongMachine = $machine
            $answer.Path = $candidate
        }
    }

    $answer.Source = 'the file'
    $answer.Machine = $wrongMachine
    $answer.Detail = if ($wrongMachine) {
        ("the only $($requirement.Dll) on this machine is an $wrongMachine build, and the tools that need it are " +
            "$($requirement.Machine) - so it cannot satisfy them")
    } else {
        "$($requirement.Dll) is not on this machine, and it is not part of Windows - it comes from a Microsoft redistributable"
    }
    $answer
}

# Start one program elevated, and never let the refusal escape.
#
# THE ONLY PLACE IN THIS REPO THAT RAISES A CONSENT DIALOG, deliberately kept to
# one function so that the suite can mock it and so that there is exactly one
# thing to read when asking what this installer can ask for. A test must never
# reach the real one: docs/windows-e2e-evidence.md section 41 is what a suite
# putting a Windows dialog on the captain's desktop costs, and a consent dialog
# is that with the stakes raised.
#
# DECLINING IS NOT A FAILURE, and it does not arrive as a distinguishable one:
# Windows reports a dismissed consent dialog as a plain Win32 error 1223, so it
# is read from the exception's NativeErrorCode rather than from its message,
# which is translated on the captain's machine and would match nothing.
#
# NO OUTPUT IS COLLECTED, and that is not an oversight. Elevation goes through
# the shell, and .NET refuses to redirect the streams of a process started that
# way - the same constraint Invoke-FmToolShellCommand records from the other
# side. So the exit code is all there is, and the caller does not trust it: it
# re-reads the machine afterwards, which is this repo's rule for every install.
function Start-FmToolElevated {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @()
    )

    $result = [pscustomobject]@{
        Started   = $false
        Declined  = $false
        ExitKnown = $false
        ExitCode  = 0
    }

    if (-not $IsWindows) { return $result }
    if (-not $PSCmdlet.ShouldProcess($FilePath, 'run elevated, which asks Windows for consent')) { return $result }

    $start = @{ FilePath = $FilePath; Verb = 'RunAs'; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
    if ($ArgumentList.Count -gt 0) { $start['ArgumentList'] = $ArgumentList }
    try {
        $process = Start-Process @start
    } catch {
        # 1223 is ERROR_CANCELLED: the captain saw the dialog and said no. Every
        # other refusal is the machine declining the launch, which is a
        # different sentence and a different outcome.
        $exception = $_.Exception
        while ($exception -and -not ($exception -is [System.ComponentModel.Win32Exception])) {
            $exception = $exception.InnerException
        }
        if ($exception -and $exception.NativeErrorCode -eq 1223) { $result.Declined = $true }
        Write-Debug "could not start '$FilePath' elevated: $_"
        return $result
    }

    $result.Started = $true
    # WAITED FOR TWICE, ON PURPOSE. -Wait is the documented waiter, and this is
    # the belt: the caller decides by RE-READING the machine, so returning
    # before the installer has finished writing would read as "still missing"
    # on an install that was about to succeed. A refusal to wait is caught with
    # everything else below rather than raised.
    try {
        if ($process) { $process.WaitForExit() }
    } catch {
        Write-Debug "could not wait on the elevated process: $_"
    }
    # A parent cannot always read an elevated child's exit code, so this is
    # reported as known or not rather than defaulted to 0 - which would be
    # indistinguishable from success.
    try {
        if ($process) {
            $result.ExitCode = [int]$process.ExitCode
            $result.ExitKnown = $true
        }
    } catch {
        Write-Debug "the elevated process did not hand back an exit code: $_"
    }
    $result
}

# Install the runtime, asking for administrator exactly once.
#
# THE CALLER HAS ALREADY TOLD THE CAPTAIN what is about to appear on their
# screen: this is reached only from install.ps1, only after it has printed what
# is being installed and why, and only when there is somebody at the keyboard.
#
# EVERY WAY OUT OF HERE IS SAFE. Declining, no winget, a refused launch and a
# failed install all return an outcome and let the run carry on, and each one
# carries the same command the captain can run themselves - which is what this
# installer printed before it could take the step at all.
#
# IT PROVES ITSELF BY RE-READING THE MACHINE rather than by winget's exit code.
# That is this repo's oldest rule about installs, and here it also covers the
# case where an elevated child's code cannot be read back at all.
function Install-FmToolRuntime {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        # What this run already found, so the machine is not re-read between the
        # paragraph the captain was shown and the dialog it describes.
        [object]$Status = $null,
        # The suite's seam and the enabler's answer in one: winget resolved by
        # its real location rather than by name.
        [string]$WingetPath = ''
    )

    $requirement = Get-FmToolRuntimeRequirement
    $command = Get-FmBootstrapWingetCommand -PackageId $requirement.PackageId
    $result = [pscustomobject]@{ Action = 'skipped'; Detail = ''; Command = $command }

    $before = if ($Status) { $Status } else { Get-FmToolRuntimeStatus }
    if ($before.Present) {
        $result.Action = 'already-present'
        $result.Detail = $before.Detail
        return $result
    }

    $winget = if ($WingetPath) { $WingetPath } else { Get-FmToolWingetPath }
    if (-not $winget) {
        $result.Action = 'blocked'
        $result.Detail = ("winget is not on this machine, so this step could not run it. Install 'App Installer' from " +
            'the Microsoft Store, or install the runtime yourself from https://aka.ms/vs/17/release/vc_redist.x64.exe')
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($requirement.Label, "install with: $command")) {
        $result.Detail = 'WhatIf'
        return $result
    }

    $run = Start-FmToolElevated -FilePath $winget `
        -ArgumentList (Get-FmBootstrapWingetArgument -PackageId $requirement.PackageId) -Confirm:$false
    if ($run.Declined) {
        $result.Action = 'declined'
        $result.Detail = ('you said no to the administrator prompt, so nothing was installed and the rest of this run ' +
            "carried on. Run this in an ADMINISTRATOR window when you want it: $command")
        return $result
    }
    if (-not $run.Started) {
        $result.Action = 'blocked'
        $result.Detail = (Get-FmToolLaunchRefusal -Program $winget `
                -Consequence "$($requirement.Label) was not installed" `
                -Remedy "Run this yourself in an ADMINISTRATOR window: $command")
        return $result
    }

    # THE INSTALL IS WHAT THE MACHINE SAYS AFTERWARDS, not what the installer
    # said about itself.
    $after = Get-FmToolRuntimeStatus
    if ($after.Present) {
        $result.Action = 'installed'
        $result.Detail = $after.Detail
        return $result
    }

    $result.Action = 'failed'
    $said = if ($run.ExitKnown) {
        (Get-FmToolRunFailureDetail -Command $command -ExitCode $run.ExitCode -AsRun $winget)
    } else {
        "'$command' ran elevated and did not hand back an exit code this run could read"
    }
    $result.Detail = ($said + [System.Environment]::NewLine +
        "$($requirement.Dll) is still not on this machine. Run that line yourself in an ADMINISTRATOR window.")
    $result
}

# The whole of step 0 as one decision, so the switch that gates the consent
# dialog is a thing the suite can hold rather than a branch nobody can reach
# without a real install.
#
# THE SWITCH IS THE WHOLE POINT. -InstallRuntime is install.ps1 saying two
# things at once: the captain has been shown what is about to appear on their
# screen, and there is somebody at the keyboard to answer it. Without it nothing
# is elevated and nothing is asked - the step is a skip that carries the command,
# which is exactly what this installer did before it could take the step at all.
function Invoke-FmToolRuntimeStep {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        # The plan's runtime record, so the machine is not re-read between the
        # paragraph the captain was shown and the dialog it describes.
        [Parameter(Mandatory)]$Runtime,
        # The run is really doing things, rather than a -WhatIf pass.
        [switch]$Performed,
        # install.ps1's consent to raise the dialog. See above.
        [switch]$InstallRuntime
    )

    $outcome = [pscustomobject]@{
        Kind           = 'runtime'
        Label          = $Runtime.Label
        Classification = $(if ($Runtime.Present) { 'current' } else { 'missing' })
        Outcome        = 'skipped'
        Detail         = ''
    }
    $action = 'skipped'

    if (-not $Performed) {
        $outcome.Detail = 'WhatIf'
    } elseif ($Runtime.Present) {
        $outcome.Outcome = 'already-present'
        $outcome.Detail = $Runtime.Detail
        $action = 'already'
    } elseif (-not $InstallRuntime) {
        $outcome.Detail = ('nothing was elevated, because this run had nobody at the keyboard to answer an ' +
            "administrator prompt. Run this yourself in an ADMINISTRATOR window: $($Runtime.Command)")
    } else {
        $install = Install-FmToolRuntime -Status $Runtime -Confirm:$false
        $outcome.Outcome = $install.Action
        $outcome.Detail = $install.Detail
        if ($install.Action -eq 'installed') { $action = 'created' }
    }

    # A step that did not do what it set out to says so in its own line, in the
    # transcript, rather than only in the summary at the end.
    $prefix = if ($outcome.Outcome -in @('failed', 'blocked', 'declined')) {
        $outcome.Outcome.ToUpperInvariant() + ': '
    } else { '' }
    [pscustomobject]@{
        Outcome = $outcome
        Step    = (New-FmInstallStep -Name $outcome.Label -Action $action -Detail ($prefix + $outcome.Detail))
    }
}

# --- what is here, and what version ---------------------------------------------

function Get-FmToolStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Command)

    $resolved = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $resolved) {
        return [pscustomobject]@{ Command = $Command; Present = $false; Path = ''; Version = ''; Launchable = $false; ExitCode = 0 }
    }
    # THE VERSION IS THE PROOF, not the presence. A command that resolves but
    # answers nothing to --version is reported with an empty version, and the
    # classification treats that as unknown rather than as installed.
    #
    # AND "COULD NOT BE STARTED" IS A THIRD ANSWER, not a version of the second.
    # A file on PATH that Windows declines to launch prints no version either,
    # and calling that "prints no version this installer can read" describes the
    # wrong thing entirely: nothing was read because nothing ran.
    #
    # THE EXIT CODE COMES WITH IT, because between those two there is a third
    # thing a program can do: START, die before its own code runs, and print
    # nothing. That looks identical to an empty version and is a completely
    # different fault, and the code is the only place it is written down.
    $probe = Get-FmInstallCommandProbe -Command $Command
    [pscustomobject]@{
        Command    = $Command
        Present    = $true
        Path       = [string]$resolved.Source
        Version    = $probe.Version
        Launchable = [bool]$probe.Launched
        ExitCode   = [int]$probe.ExitCode
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

# A LINE THE CAPTAIN CAN ACTUALLY PASTE, for a tool that is not here.
#
# Get-FmToolRoute's Command is a description for a portable route - "expand the
# cli/cli release asset gh_*_windows_amd64.zip into ..." - which is exactly right
# as a statement of what this installer does and is not a command anybody can
# run. Printing it as a "fix:" hands the captain a sentence instead of a remedy.
#
# Every fix line this repo prints has to be one that works when pasted, so a
# route nobody can type by hand answers with the thing that DOES it: this
# installer, which needs no administrator and is safe to run again.
#
# EXCEPT WHEN THE TOOL IS ALREADY THERE AND CANNOT START. The route answers "this
# tool is not on the machine"; it is the wrong question entirely for a binary
# that is on the machine, in the right place, and dies in the loader. Printing
# the installer at that captain sends them round a loop: it re-expands the same
# archive and reaches the same dead binary. So an exit code that names a missing
# dependency takes precedence over the route, because the dependency is what has
# to be installed before the route's own work can matter.
function Get-FmToolFixCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Route,
        # What the tool RETURNED, where one was run. 0 for a tool that was never
        # started - which is every caller asking about a tool that is simply
        # absent, and is why this defaults rather than being demanded.
        [int]$ExitCode = 0
    )

    $remedy = Get-FmToolExitCodeRemedy -ExitCode $ExitCode
    if ($remedy) {
        # The trailing "  # ..." is this repo's convention for advice attached to
        # a command - see Get-FmBootstrapInstallCommand - and it is a comment in
        # the shell it is pasted into, so the whole line runs as written.
        $where = if ($remedy.NeedsAdministrator) { 'run this in an ADMINISTRATOR window' } else { 'no administrator needed' }
        return "$($remedy.Command)  # $where - $($remedy.Detail)"
    }

    switch ($Route.Kind) {
        'portable' { return 'powershell -ExecutionPolicy Bypass -File .\install.ps1   # installs it from the vendor''s own release archive, no administrator' }
        'manual' { return "install it by hand: $($Route.Instructions)" }
        'none' { return '' }
        default { return [string]$Route.Command }
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

# WHERE ONE PORTABLE ROUTE'S ARCHIVE ACTUALLY IS, as a { Name; Url; Version;
# Sha256 } record - the same shape whichever vendor publishes it, so
# Install-FmToolPortable has one download to perform rather than one per source.
#
# 'manifest' IS NOT A GITHUB RELEASE LOOKUP even when the file it names lives on
# GitHub. herdr publishes a small JSON saying which release is current and where
# its assets are, and their own installer reads exactly that - so this reads the
# same file rather than re-deriving the answer from the releases API and hoping
# the two agree. Their asset value is a bare URL string on the stable channel and
# an object carrying url/sha256/format on preview; their Get-ManifestAsset
# accepts both shapes and so does this.
function Get-FmToolPortableAsset {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Portable,
        [int]$TimeoutSeconds = 30
    )

    if ($Portable.Source -eq 'manifest') {
        $manifest = Invoke-RestMethod -Uri $Portable.ManifestUrl -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return Get-FmToolManifestAsset -Manifest $manifest -AssetKey $Portable.AssetKey -Origin $Portable.ManifestUrl
    }

    # 'nodejs' IS NEITHER OF THE OTHER TWO. nodejs.org publishes a dist index and
    # a predictable path under it, and the nodejs/node GitHub releases carry no
    # Windows zip at all - so asking GitHub for one would fail on an asset that
    # was never there. The version comes from the SAME reader the currency check
    # uses, so "is it current" and "what would be installed" cannot disagree.
    if ($Portable.Source -eq 'nodejs') {
        $version = Get-FmToolNodeLatestVersion -TimeoutSeconds $TimeoutSeconds
        if (-not $version) {
            throw 'error: nodejs.org did not answer which release is current, so there is nothing to download'
        }
        # node-v24.19.0-win-x64.zip, under https://nodejs.org/dist/v24.19.0/.
        # Built from the route's own pattern, which already carries this
        # machine's architecture, rather than from a second copy of the naming
        # convention.
        $name = $Portable.AssetPattern -replace '\*', $version.TrimStart('v')
        return [pscustomobject]@{
            Name    = $name
            Url     = "https://nodejs.org/dist/$version/$name"
            Version = $version
            Sha256  = ''
        }
    }

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Portable.Repository)/releases/latest" `
        -Headers @{ 'User-Agent' = 'firstmate-win' } -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    $asset = Get-FmToolReleaseAsset -Release $release -AssetPattern $Portable.AssetPattern
    [pscustomobject]@{ Name = $asset.Name; Url = $asset.Url; Version = $asset.Tag; Sha256 = '' }
}

# READING THE MANIFEST, split from FETCHING it, so the two shapes a vendor
# actually publishes can be exercised against captured documents rather than
# only against the network.
function Get-FmToolManifestAsset {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$AssetKey,
        [string]$Origin = 'the release manifest'
    )

    $assets = $null
    if ($Manifest.PSObject.Properties.Name -contains 'assets') { $assets = $Manifest.assets }
    $entry = if ($assets -and ($assets.PSObject.Properties.Name -contains $AssetKey)) { $assets.$AssetKey } else { $null }
    if (-not $entry) {
        throw "error: $Origin lists no '$AssetKey' asset, so there is nothing to download for this machine"
    }
    # A bare URL string on one channel and an object carrying url/sha256/format
    # on the other. Their own reader accepts both, so this does too.
    $url = if ($entry -is [string]) { [string]$entry } elseif ($entry.PSObject.Properties.Name -contains 'url') { [string]$entry.url } else { '' }
    if (-not $url) { throw "error: the '$AssetKey' asset in $Origin carries no URL" }
    $sha = if ($entry -isnot [string] -and ($entry.PSObject.Properties.Name -contains 'sha256')) { [string]$entry.sha256 } else { '' }
    [pscustomobject]@{
        Name    = [System.IO.Path]::GetFileName(([uri]$url).AbsolutePath)
        Url     = $url
        Version = (Get-FmToolManifestVersion -Manifest $Manifest)
        Sha256  = $sha
    }
}

# The version identity a herdr-style manifest names, by their own rule: the
# stable channel carries `version`, and the preview channel carries a
# base_version and a build_id that combine into one.
function Get-FmToolManifestVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Manifest)

    $names = $Manifest.PSObject.Properties.Name
    $version = if ($names -contains 'version') { [string]$Manifest.version } else { '' }
    if ($version) { return $version }
    $base = if ($names -contains 'base_version') { [string]$Manifest.base_version } else { '' }
    $build = if ($names -contains 'build_id') { [string]$Manifest.build_id } else { '' }
    if ($base -and $build) { return "$base-preview.$build" }
    ''
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
        return [pscustomobject]@{ Tool = $Portable.Tool; Action = 'skipped'; Detail = 'WhatIf'; BinDirectory = $binDirectory; OnPath = @() }
    }

    $archive = $ArchivePath
    $downloaded = ''
    try {
        if (-not $archive) {
            $asset = Get-FmToolPortableAsset -Portable $Portable
            $downloaded = Join-Path ([System.IO.Path]::GetTempPath()) ('fm-tool-' + [guid]::NewGuid().ToString('N') + '-' + $asset.Name)
            Invoke-WebRequest -Uri $asset.Url -OutFile $downloaded -ErrorAction Stop
            # WHERE THE VENDOR PUBLISHES A CHECKSUM, IT IS CHECKED. herdr's
            # preview manifest carries one; their stable manifest does not, and
            # an absent checksum is not treated as a passing one.
            if ($asset.Sha256) {
                $actual = (Get-FileHash -LiteralPath $downloaded -Algorithm SHA256).Hash
                if ($actual -ne $asset.Sha256.ToUpperInvariant()) {
                    throw "error: the download of $($asset.Name) does not match the checksum $($Portable.Repository) published for it (got $actual, expected $($asset.Sha256)); nothing was installed"
                }
            }
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

    # THE CONFIG GOES INSIDE THE TREE THAT WAS JUST REPLACED, so every install
    # rewrites it rather than one install leaving it behind. Node.js is the case:
    # the builtin npmrc is what keeps globally installed packages OUT of the
    # directory the next update deletes.
    if ($Portable.ConfigPath) {
        $configFile = Join-Path $destination $Portable.ConfigPath
        $configParent = Split-Path -Parent $configFile
        if ($configParent -and -not (Test-Path -LiteralPath $configParent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $configParent -Force
        }
        [System.IO.File]::WriteAllText($configFile, $Portable.ConfigContent + [System.Environment]::NewLine)
    }

    # A directory the tool WRITES INTO rather than one it ships. It need not
    # exist yet - npm creates its prefix on the first global install - so it is
    # created here, because a PATH entry pointing at nothing would leave the
    # tools it is about to hold unreachable for the rest of this run.
    $onPath = @($binDirectory)
    foreach ($extra in @($Portable.ExtraPath)) {
        if (-not $extra) { continue }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($extra)
        if ($expanded -match '%\w+%') {
            Write-Debug "skipping the extra PATH entry '$extra': this environment does not define it"
            continue
        }
        if (-not (Test-Path -LiteralPath $expanded -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $expanded -Force
        }
        $onPath += $expanded
    }
    foreach ($directory in $onPath) {
        $null = Add-FmToolUserPath -Directory $directory -Scope $PathScope -Confirm:$false
    }
    [pscustomobject]@{
        Tool         = $Portable.Tool
        Action       = 'installed'
        Detail       = $destination
        BinDirectory = $binDirectory
        OnPath       = $onPath
    }
}

# --- a launch this machine refused -----------------------------------------------
#
# WHAT THIS AREA SHIPPED, and what it cost. A child shell that Windows declined
# to start raised a raw .NET error, took the whole run down with it, and printed
#
#   Program 'pwsh.exe' failed to run: An error occurred trying to start process
#   '...\PowerShell7\pwsh.exe' with working directory '...\firstmate'.
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
        #
        # -ExecutionPolicy Bypass, STATED RATHER THAN INHERITED. The documented
        # first command carries it, and PowerShell does hand it down through the
        # PSExecutionPolicyPreference environment variable - MEASURED here,
        # 2026-08-21: a child of `pwsh -ExecutionPolicy Bypass` reports Bypass.
        # But that inheritance only exists when the parent got the switch, and a
        # run started from a window that is ALREADY PowerShell 7 never passes
        # through the relaunch that supplies it. A vendor one-liner that
        # downloads a .ps1 and runs it is then refused for the very reason the
        # first command needs the switch: Windows ships script execution
        # switched off. A child of that command must not put it back.
        $out = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -Command (Get-FmToolShellCommandText -Command $Command) 2>&1 |
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
#
# TWO KINDS OF CODE ARRIVE HERE, and only one of them is the program speaking.
# A code in the 0x8A15xxxx range is winget's own verdict about what it was asked
# to do. A code in the 0xC00000xx range is an NTSTATUS: WINDOWS chose it, for a
# process that never reached its own first instruction. That second kind is worth
# naming for every command rather than for one, because the program had no chance
# to say anything at all - stdout and stderr are both empty and the code is the
# only evidence there is.
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
            # NOT a return: winget can fail to start for the same OS reasons
            # anything else can, and those are named below.
            default { }
        }
    }

    # MEASURED, 2026-08-21, on the real herdr 0.8.2 release binary with one of its
    # imported DLL names rewritten to a name this machine does not have: exit
    # 0xC0000135, zero bytes on stdout, zero bytes on stderr, and no launch
    # exception - which is exactly the shape the captain's clean Windows 11 VM
    # reported as "answers nothing to --version" and nothing more.
    switch ($ExitCode) {
        -1073741515 { return 'a DLL it needs is not on this machine, so Windows stopped it before it ran any of its own code' }
        # THE SAME FAULT ONE STEP LATER, and both belong here because both are
        # answered by the same remedy: the DLL was found and is the wrong one, so
        # the export the program imports is not in it. An old runtime beside a
        # newer build produces these, and installing the current runtime is what
        # replaces it.
        -1073741511 { return 'a DLL it needs is on this machine but does not contain something it imports, so the copy here is older than the build that needs it' }
        -1073741512 { return 'a DLL it needs is on this machine but does not contain something it imports by ordinal, so the copy here is older than the build that needs it' }
        -1073741502 { return 'a DLL it needs is on this machine but would not initialise, so it stopped before it ran any of its own code' }
        -1073741701 { return 'Windows could not load it as a program - the usual cause is a build for a different processor architecture' }
        -1073741795 { return 'it used a processor instruction this machine does not have, so the build is for a newer CPU than this one' }
        -1073741790 { return 'this machine denied it access as it started' }
        default { return '' }
    }
}

# THE CURE, KEPT BESIDE THE CAUSE.
#
# THE DEFECT, MEASURED on the captain's clean Windows 11 VM 2026-08-21 and left
# standing for two days. The run diagnosed herdr exactly right - "it exited
# 0xC0000135, which means a DLL it needs is not on this machine" - and then
# printed, as the fix, the installer that had just produced that line. Running it
# again re-expands the same archive and reaches the same dead binary, forever.
# The captain had to be told the actual answer by hand, in chat.
#
# WHY IT LIVES WITH THE MEANING RATHER THAN WITH herdr. The codes above are
# Windows' verdicts about a process that never reached its own first
# instruction; nothing about them is particular to which program was started. A
# remedy hung off the herdr route would have to be written again for the next
# native tool that ships without its runtime, and would be missed. So the answer
# is asked of the CODE, exactly like the meaning is, and every tool that returns
# one of these gets the same answer.
#
# WHY THE VISUAL C++ RUNTIME IS THE ANSWER. It is the one shared runtime a fresh
# Windows install does not have and a native tool routinely imports. herdr.exe
# imports VCRUNTIME140.dll from it - read out of the binary's import table, not
# guessed - and that DLL ships with the redistributable rather than with Windows.
# `docs/windows-e2e-evidence.md` section 40.9 is careful about what that is: the
# import is measured, and that it is the MISSING one on the captain's VM is the
# strongest available inference, because that machine was never instrumented. A
# named remedy is the right weight for an inference this strong - it costs one
# line, it is correct for every clean machine, and it proves nothing on its own.
#
# WHY x64 AND NOT THE MACHINE'S ARCHITECTURE. herdr publishes one Windows build,
# `windows-x86_64` - see Get-FmBootstrapPortableRelease - so an ARM64 machine
# runs the x64 binary under emulation, and an emulated x64 process loads x64
# DLLs. Picking the redistributable by the MACHINE's architecture would hand an
# ARM64 captain the one package that cannot satisfy the program that failed.
#
# THE IDENTIFIER WAS VERIFIED AGAINST winget ITSELF, v1.29.290, 2026-08-25:
# `winget search -e --id Microsoft.VCRedist.2015+.x64 --source winget` resolves
# to exactly one package, "Microsoft Visual C++ v14 Redistributable (x64)"
# 14.51.36247.0. The command is built by Get-FmBootstrapWingetCommand so it
# carries this repo's pinned source and both agreement flags rather than a second
# set.
#
# 0xC0000142 IS NOT ON THIS LIST, deliberately. That DLL was found and loaded and
# its own initialisation failed, which installing it does not answer, and a fix
# line that might not work is the thing this function exists to stop. Nor is
# 0xC000007B: a build for another processor is cured by a different build, not by
# a runtime.
#
# THIS DOES NOT LOWER THE BAR. It names what to run; it proves nothing. The tool
# is still unproven, still reported, and the run still ends NOT READY until the
# tool itself answers --version.
function Get-FmToolExitCodeRemedy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][int]$ExitCode)

    # 0xC0000135 the DLL is absent; 0xC0000139 and 0xC0000138 it is present and
    # too old to carry what is imported. All three are one fault - the runtime
    # this machine has is not the runtime the build needs - and one command
    # replaces it.
    if ($ExitCode -notin @(-1073741515, -1073741511, -1073741512)) { return $null }

    # THE PACKAGE AND ITS DESCRIPTION COME FROM Get-FmToolRuntimeRequirement,
    # which is the one owner of what this runtime is. This line is now the
    # SECOND thing that acts on that fact - the installer takes the step itself
    # since the captain asked for it - and the two agreeing has to be structural
    # rather than remembered.
    $requirement = Get-FmToolRuntimeRequirement
    [pscustomobject]@{
        Command            = (Get-FmBootstrapWingetCommand -PackageId $requirement.PackageId)
        NeedsAdministrator = $true
        # What the command is FOR, in the captain's terms, so the fix line says
        # why it is being asked for something the rest of this installer only
        # asks for once.
        Detail             = $requirement.Detail
    }
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
        [string]$ShellPath = '',
        # The same idea for the portable route, forwarded whole to
        # Install-FmToolPortable: a local archive instead of a download, so the
        # expansion, the PATH edit and the proof below all run for real.
        [string]$ArchivePath = ''
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
                    -ArchivePath $ArchivePath -PathScope $PathScope -Confirm:$false
            } catch {
                $result.Action = 'failed'
                $result.Detail = [string]$_.Exception.Message
                return $result
            }
            # PLACING THE FILES IS NOT INSTALLING THE TOOL, and the captain's
            # clean Windows 11 VM printed both halves of that on 2026-08-21:
            #
            #   [missing] tool herdr - 'herdr' resolves to ...\herdr.exe but
            #             answers nothing to --version
            #   summary:  herdr  installed  C:\Users\...\Programs\herdr
            #
            # Both lines were true and the summary was the one they read last.
            # The command route already ends by reaching what it installed; this
            # one ended at "the bytes are on disk", so a tool that would never
            # run was reported as installed. It is proved the same way everything
            # else in this repo is - by RUNNING it - and a failure here is a
            # failed install rather than a footnote further down the report.
            $result.Detail = $installed.Detail
            $name = Get-FmToolCommandName -Tool $Route.Tool
            $proof = Get-FmToolStatus -Command $name
            if ($proof.Version) {
                $result.Action = 'installed'
                return $result
            }
            $result.Action = 'failed'
            $result.Detail = if (-not $proof.Present) {
                "the release was expanded into $($installed.Detail) but '$name' is still not reachable, so nothing was proved"
            } elseif (-not $proof.Launchable) {
                (Get-FmToolLaunchRefusal -Program $proof.Path `
                        -Consequence "the release expanded into $($installed.Detail) could not be exercised" `
                        -Remedy "Open a new window and run '$name --version' yourself.")
            } else {
                # THIS IS THE MOMENT THE CAPTAIN NEEDS THE CURE, on the step that
                # failed rather than only in the proving pass further down. A
                # step reported 'failed' has no fix slot of its own, so the
                # remedy is said in the detail - by the same owner, so the two
                # can never disagree.
                $said = "the release was expanded into $($installed.Detail), and " +
                (Get-FmToolUnprovenDetail -Command $name -Path $proof.Path -ExitCode $proof.ExitCode)
                $remedy = Get-FmToolExitCodeRemedy -ExitCode $proof.ExitCode
                if ($remedy) {
                    $said += [System.Environment]::NewLine +
                    "run this once in an ADMINISTRATOR window, then re-run this installer: $($remedy.Command)"
                }
                $said
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
    # THE INSTALL IS NOT FINISHED UNTIL THIS RUN CAN REACH WHAT IT INSTALLED.
    # A vendor installer edits an environment this already-running process cannot
    # see, so without this the very next check reports the tool that was just
    # installed as missing - measured on the captain's clean VM with the Claude
    # CLI, which was installed and then declared not on PATH eight lines later.
    $reached = Resolve-FmToolAfterInstall -Tool $Route.Tool -PathScope $PathScope -Confirm:$false
    $result.Action = 'installed'
    $result.Detail = $Route.Command
    if ($reached.Recovered) {
        $result.Detail += " (and put on PATH from $($reached.Directory), which its installer did not do for this session)"
    }
    $result
}

# --- the modules ----------------------------------------------------------------

# THE ONE LINE THIS REPO PRINTS FOR A MODULE, built in one place because four
# places printed it and two of them disagreed.
#
# -SkipPublisherCheck IS NOT OPTIONAL HERE, and the reason is Pester specifically.
# Windows ships Pester 3.4.0 in C:\Program Files\WindowsPowerShell\Modules, and
# PowerShellGet refuses to put a differently-signed newer copy anywhere near it
# unless it is told to carry on.
#
# MEASURED here, 2026-08-21, because this is a claim about a machine and had to
# be one:
#   - the shipped Pester 3.4.0 manifest is Authenticode Valid and signed
#     'CN=Microsoft Windows, O=Microsoft Corporation'
#   - the gallery's Pester is Authenticode Valid and signed 'CN=Jakub Jares'
#   - PowerShellGet raises PublishersMismatch on exactly that pair, and names
#     -SkipPublisherCheck as the way past it
#   - PowerShellGet 2.2.5, which PowerShell 7 carries, holds a WhitelistedModules
#     table containing 'Pester', so THERE the mismatch is downgraded to a warning
#     and the line succeeds without the switch
#   - PowerShellGet 1.0.0.1, which Windows PowerShell 5.1 ships, has no such
#     table, so THERE the same line throws
#
# The captain's clean-VM log has them sitting in Windows PowerShell 5.1 - which
# is the shell this fix line was handed to, and the one it fails in. A printed
# fix is a line someone pastes into whatever window they have open, so it has to
# work in both and this is what makes it.
function Get-FmToolModuleInstallCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$MinimumVersion = '',
        # For a copy that is already there: -Force is what stops Install-Module
        # reporting "already installed" and doing nothing.
        [switch]$Force
    )

    $command = "Install-Module $Name"
    if ($MinimumVersion) { $command += " -MinimumVersion $MinimumVersion" }
    $command += ' -Scope CurrentUser'
    if ($Force) { $command += ' -Force' }
    "$command -SkipPublisherCheck"
}

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
        $byHand = Get-FmToolModuleInstallCommand -Name $Requirement.Name -MinimumVersion $Requirement.MinimumVersion
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
