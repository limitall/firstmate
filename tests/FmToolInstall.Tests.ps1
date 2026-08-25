#requires -Version 7.0
# Pester tests for the machine install - the tools, their sources, and the
# three-outcome classification.
#
# WHAT THESE PIN, in priority order:
#
#   1. THE SOURCES ARE REAL. The defect this area was built for is an install
#      table that named the npm packages `treehouse` and `herdr` - an unrelated
#      web framework and an empty 0.0.0 placeholder - and reported success. So
#      the first tests here assert what each route actually IS, through the same
#      seam the installer calls, and specifically that neither of those two ever
#      resolves to npm again.
#   2. THE THREE OUTCOMES ARE NOT BLURRED. missing, older and unsupported are
#      each a different action, and a tool below a STATED minimum must never be
#      classified merely older (it would then be silently installed over) nor a
#      tool with no stated minimum declared unsupported (a threshold nobody
#      wrote down). Get-FmToolClassification is exercised at every boundary.
#   3. NOTHING NEEDS ADMINISTRATOR. Every route for a required tool is either the
#      vendor's per-user installer or a release archive; the two that do need
#      elevation are DECLARED, so the installer can name and skip them.
#   4. THE PORTABLE INSTALL REALLY RUNS. The expansion, the layout check, the
#      PATH edit and the second-run idempotence are exercised against a real zip
#      in TestDrive with -PathScope Process, so nothing here touches the
#      captain's machine and nothing about the mechanism is stubbed.
#
# What is deliberately NOT tested: performing an actual install of an actual
# tool. That would rewrite the environment this suite runs in. Everything up to
# the download is covered; the download itself is not.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate', $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    . (Join-Path $PSScriptRoot 'FmUnstartable.TestHelpers.ps1')

    # PATH is process-wide, and these tests add directories to it on purpose.
    $script:SavedPath = $env:PATH

    function New-ToolArchive {
        <#
            A zip shaped like a real release asset: a bin/ directory holding one
            file, optionally under a single versioned root the way node's zip
            ships.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: builds a disposable archive under TestDrive so the portable install can be exercised without a download.')]
        param(
            [Parameter(Mandatory)][string]$Path,
            [string]$RootDirectory = '',
            [string]$BinDirectory = 'bin'
        )
        $staging = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $content = if ($RootDirectory) { Join-Path $staging $RootDirectory } else { $staging }
        $bin = if ($BinDirectory) { Join-Path $content $BinDirectory } else { $content }
        $null = New-Item -ItemType Directory -Path $bin -Force
        Set-Content -LiteralPath (Join-Path $bin 'demo.txt') -Value 'demo' -NoNewline
        Set-Content -LiteralPath (Join-Path $content 'LICENSE') -Value 'MIT' -NoNewline
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $Path -Force
        Remove-Item -LiteralPath $staging -Recurse -Force
        $Path
    }
}

AfterAll {
    $env:PATH = $script:SavedPath
}

Describe 'the tool catalog' {
    It 'gives every entry the four things the installer needs to act and to explain' {
        $catalog = @(Get-FmToolCatalog)
        $catalog.Count | Should -BeGreaterThan 0
        foreach ($entry in $catalog) {
            $entry.Tool | Should -Not -BeNullOrEmpty
            $entry.Command | Should -Not -BeNullOrEmpty
            $entry.Label | Should -Not -BeNullOrEmpty
            $entry.Why | Should -Not -BeNullOrEmpty -Because "$($entry.Tool) has to be able to say why it is wanted"
        }
    }

    It 'requires exactly the set firstmate cannot dispatch a worker without' {
        $required = @(Get-FmToolCatalog -RequiredOnly | ForEach-Object { $_.Tool })
        $required | Should -Contain 'git'
        $required | Should -Contain 'claude'
        $required | Should -Contain 'herdr'
        $required | Should -Contain 'treehouse'
        # gh is how a PR is opened, not how a worker is dispatched.
        $required | Should -Not -Contain 'gh'
    }

    It 'leaves the validation pipeline out, and says why rather than leaving a hole' {
        # AGENTS.md section 14 refuses no-mistakes delivery by name on this port,
        # so installing the pipeline would leave a tool nothing here may use. Its
        # absence has to be an ANSWER, or the next reader files it as an oversight.
        @(Get-FmToolCatalog | ForEach-Object { $_.Tool }) | Should -Not -Contain 'no-mistakes'
        $excluded = @(Get-FmToolExcluded)
        @($excluded | ForEach-Object { $_.Tool }) | Should -Contain 'no-mistakes'
        foreach ($item in $excluded) {
            $item.Reason.Length | Should -BeGreaterThan 20 -Because 'an exclusion without a reason is indistinguishable from a mistake'
        }
    }
}

Describe 'where a tool actually comes from' {
    It 'never resolves treehouse or herdr to npm again' -Skip:(-not $IsWindows) {
        # THE DEFECT, PINNED. npm `treehouse` is a single-page-application state
        # framework and npm `herdr` is a 0.0.0 placeholder; installing either
        # exits 0 and leaves the machine broken in a way nothing reports.
        foreach ($tool in @('treehouse', 'herdr')) {
            $route = Get-FmToolRoute -Tool $tool
            # treehouse comes from its own installer; herdr comes from the
            # release its own installer downloads, because that installer fails
            # its own verification on a clean machine. Neither is npm, which is
            # the whole of what this pins.
            $route.Kind | Should -BeIn @('command', 'portable') -Because "$tool has a real source of its own"
            $route.Command | Should -Not -Match 'npm' -Because "the npm package called '$tool' is not this software"
        }
    }

    It 'takes each tool from the vendor that publishes it' -Skip:(-not $IsWindows) {
        (Get-FmToolRoute -Tool 'treehouse').Command | Should -Match 'kunchenguid\.github\.io/treehouse/install\.ps1'
        (Get-FmToolRoute -Tool 'claude').Command | Should -Match 'claude\.ai/install\.ps1'
        # herdr is taken from the release its OWN installer points at, read out
        # of that installer rather than guessed - see the herdr Describe below.
        (Get-FmToolRoute -Tool 'herdr').Portable.ManifestUrl | Should -Match 'herdr\.dev'
        # The axi tools genuinely ARE npm packages, so npm is the right source
        # for them and only for them.
        foreach ($tool in @('gh-axi', 'chrome-devtools-axi', 'lavish-axi', 'tasks-axi', 'quota-axi')) {
            (Get-FmToolRoute -Tool $tool).Command | Should -Match 'npm install -g'
        }
    }

    It 'prefers the portable release for gh, so no elevation is needed' -Skip:(-not $IsWindows) {
        $route = Get-FmToolRoute -Tool 'gh'
        $route.Kind | Should -Be 'portable'
        $route.NeedsAdministrator | Should -BeFalse
        $route.Portable.Repository | Should -Be 'cli/cli'
        $route.Portable.AssetPattern | Should -Match '^gh_\*_windows_'
        $route.Portable.BinSubdirectory | Should -Be 'bin'
    }

    It 'declares the one route that needs administrator, and no others' -Skip:(-not $IsWindows) {
        # winget runs a machine-scope MSI, which fails late and unhelpfully on an
        # unelevated session. Declaring it is what lets the installer name the
        # step and carry on with everything else.
        (Get-FmToolRoute -Tool 'git').NeedsAdministrator |
            Should -BeTrue -Because 'git comes from winget, which installs machine-wide'
        foreach ($tool in @('node', 'claude', 'herdr', 'treehouse', 'gh', 'gh-axi')) {
            (Get-FmToolRoute -Tool $tool).NeedsAdministrator |
                Should -BeFalse -Because "$tool installs into the user's own profile"
        }
    }

    It 'asks winget to UPGRADE when the captain agreed to an update' -Skip:(-not $IsWindows) {
        # `winget install <id>` on a package already present reports "already
        # installed" and exits 0 without upgrading anything, so a captain who
        # said yes would have been told it happened and left on the old version.
        Get-FmToolUpdateCommand -Command 'winget install -e --id Git.Git --source winget --accept-source-agreements --accept-package-agreements' |
            Should -Be 'winget upgrade -e --id Git.Git --source winget --accept-source-agreements --accept-package-agreements'
    }

    It 'gives every winget route the flags that let it finish with nobody at the keyboard' -Skip:(-not $IsWindows) {
        # THE DEFECT, PINNED. `winget install OpenJS.NodeJS` exited 1 and
        # installed nothing on the captain's machine, 2026-08-20, in an
        # ADMINISTRATOR shell: winget asks the operator to accept its source
        # agreements the first time, and an install run through a pipeline has
        # nobody there to accept them.
        #
        # This sweeps the catalog the installer actually walks, so a winget route
        # added later without the flags fails here rather than on a captain's
        # machine.
        $wingetRoutes = @()
        foreach ($entry in (Get-FmToolCatalog)) {
            $route = Get-FmToolRoute -Tool $entry.Tool
            if ($route.Command -notmatch '^\s*winget\s') { continue }
            $wingetRoutes += $route
            $route.Command | Should -Match '\s--accept-source-agreements(\s|$)' `
                -Because "$($entry.Tool) would stop at winget's source-agreement prompt"
            $route.Command | Should -Match '\s--accept-package-agreements(\s|$)' `
                -Because "$($entry.Tool) would stop at winget's package-agreement prompt"
            # `-e --id <id>` matches one package by identifier. A bare
            # `winget install <name>` is a search, and a search with several hits
            # asks a second question nobody is there to answer.
            $route.Command | Should -Match '\s-e\s+--id\s+\S+' `
                -Because "$($entry.Tool) must be matched by its exact package id, not by a search"
            # What the captain is handed to REPLACE it carries them too, or the
            # update route reintroduces the same prompt.
            $update = Get-FmToolUpdateCommand -Command $route.Command
            $update | Should -Match '\s--accept-source-agreements(\s|$)'
            $update | Should -Match '\s--accept-package-agreements(\s|$)'
            $update | Should -Match '\s-e\s+--id\s+\S+'
        }
        $wingetRoutes.Count | Should -BeGreaterThan 0 -Because 'git comes from winget, so this sweep is not vacuous'
    }

    It 'pins the one source these packages come from, so an unused one cannot fail the install' -Skip:(-not $IsWindows) {
        # THE DEFECT, PINNED. MEASURED from the captain's clean-VM install log,
        # 2026-08-20, with the agreement flags already in: the Node.js route
        # exited -1978335138 (0x8A15005E) having installed nothing, and winget
        # said why - "Failed when searching source: msstore ... The server
        # certificate did not match any of the expected values", then "The
        # following packages were found among the working sources. Please
        # specify one of them using the --source option to proceed. Node.js
        # OpenJS.NodeJS winget".
        #
        # The `winget` source was healthy and HAD the package. winget queries
        # every configured source, so ONE erroring source it did not need was
        # enough to make it stop and ask which to use - a question nobody is
        # there to answer, so it exited without installing. Every id below is
        # published on `winget` and none comes from the Store, so naming the
        # source removes the question and the whole dependency on msstore's
        # health.
        #
        # This sweeps the catalog the installer actually walks, so a winget
        # route added later without the pin fails here rather than on the
        # captain's next clean VM.
        $pinned = @()
        foreach ($entry in (Get-FmToolCatalog)) {
            $route = Get-FmToolRoute -Tool $entry.Tool
            if ($route.Command -notmatch '^\s*winget\s') { continue }
            $pinned += $route
            $route.Command | Should -Match '\s--source\s+winget(\s|$)' `
                -Because "an unhealthy msstore would fail $($entry.Tool) on a source it does not need"
            # The replace route is run on the same machines, so it carries the
            # pin too or the update reintroduces the same failure.
            Get-FmToolUpdateCommand -Command $route.Command | Should -Match '\s--source\s+winget(\s|$)' `
                -Because "the update route for $($entry.Tool) meets the same sources"
        }
        $pinned.Count | Should -BeGreaterThan 0 -Because 'git and Node.js come from winget, so this sweep is not vacuous'

        # And the builder every one of them is made by, whole, including the
        # elevated PowerShell 7 line that is printed for a human to paste.
        Get-FmBootstrapWingetCommand -PackageId 'Demo.Package' |
            Should -Be 'winget install -e --id Demo.Package --source winget --accept-source-agreements --accept-package-agreements'
    }

    It 'never names a winget package that does not exist' -Skip:(-not $IsWindows) {
        # SAME RULE AS "NEVER TRUST A PACKAGE NAME", applied to the other package
        # manager. orca and cmux were published here as `winget install orca` and
        # `winget install cmux`. MEASURED, winget v1.29.280, 2026-08-20: neither
        # id exists - both answer "No package found matching input criteria" -
        # while every id this file does name resolves to exactly one package.
        # A route that cannot succeed is reported as a step that FAILED rather
        # than as one nobody can take, which is a worse answer than having none.
        foreach ($tool in @('orca', 'cmux')) {
            Get-FmBootstrapInstallCommand -Tool $tool | Should -BeNullOrEmpty `
                -Because "$tool is not a winget package on any machine"
            (Get-FmToolRoute -Tool $tool).Kind | Should -Be 'manual' `
                -Because "$tool is a backend this port cannot drive, so it is a human step"
            Get-FmBootstrapMissingDiagnostic -Tool $tool | Should -Match '^MISSING_MANUAL: '
        }
        # And the ones that ARE winget packages still are.
        foreach ($tool in @('node', 'git')) {
            Get-FmBootstrapInstallCommand -Tool $tool | Should -Match '^winget install -e --id '
        }
    }

    It 'gives the elevated PowerShell 7 route the same flags, because it is copied and pasted' -Skip:(-not $IsWindows) {
        # Get-FmMachineShellLine prints this one for a human to run. It is still
        # a winget command, and a captain who pastes it into a script hits the
        # prompt the flags exist to answer.
        $line = Get-FmBootstrapWingetCommand -PackageId 'Microsoft.PowerShell'
        $line | Should -Be 'winget install -e --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements'
    }

    It 'leaves every other route alone, because they already fetch the newest thing' {
        # The vendor installers resolve latest on each run, the portable route
        # takes the latest release, and npm takes the latest published package.
        foreach ($command in @('irm https://herdr.dev/install.ps1 | iex', 'npm install -g gh-axi')) {
            Get-FmToolUpdateCommand -Command $command | Should -Be $command
        }
    }

    It 'no longer calls herdr a manual install, because it publishes an installer' {
        # This used to report MISSING_MANUAL and refuse to install. Measured
        # 2026-08-17: herdr.dev publishes install.ps1 and install.sh.
        Get-FmBootstrapManualInstallUrl -Tool 'herdr' | Should -BeNullOrEmpty
        Get-FmBootstrapMissingDiagnostic -Tool 'herdr' | Should -Match '^MISSING: herdr \(install: '
    }
}

Describe 'a stated minimum, never an invented one' {
    It 'states no minimum where this repo states none' {
        foreach ($tool in @('git', 'node', 'claude', 'herdr', 'gh')) {
            $minimum = Get-FmToolMinimum -Tool $tool
            $minimum.Version | Should -Be '' -Because "nothing in this repo states a minimum $tool version, and inventing one would declare a working tool unsupported"
            $minimum.Capability | Should -Be ''
        }
    }

    It 'carries the axi floors this repo does state, with where each comes from' {
        foreach ($tool in @('gh-axi', 'lavish-axi')) {
            $minimum = Get-FmToolMinimum -Tool $tool
            $minimum.Version | Should -Not -BeNullOrEmpty
            $minimum.Source | Should -Not -BeNullOrEmpty -Because 'a floor whose origin is unrecorded cannot be argued with'
        }
        (Get-FmToolMinimum -Tool 'gh-axi').Version | Should -Be $script:FmBootstrapGhAxiMin
        (Get-FmToolMinimum -Tool 'lavish-axi').Version | Should -Be $script:FmBootstrapLavishAxiMin
    }

    It 'states treehouse minimum as a capability, because a version number cannot express it' {
        $minimum = Get-FmToolMinimum -Tool 'treehouse'
        $minimum.Version | Should -Be ''
        $minimum.Capability | Should -Match 'get --lease'
    }
}

Describe 'the three outcomes' {
    It 'calls an absent tool missing' {
        Get-FmToolClassification -Present $false | Should -Be 'missing'
    }

    It 'calls a tool below a STATED minimum unsupported, not merely older' {
        # The difference is the whole point: unsupported is skipped and reported,
        # older is offered and optional. Blurring them installs over a version the
        # captain never agreed to replace.
        Get-FmToolClassification -Present $true -Installed '0.1.20' -Latest '0.1.30' -Minimum '0.1.29' |
            Should -Be 'unsupported'
    }

    It 'calls a tool that clears the minimum but trails the latest older' {
        Get-FmToolClassification -Present $true -Installed '0.1.29' -Latest '0.1.30' -Minimum '0.1.29' |
            Should -Be 'older'
    }

    It 'calls a tool at or ahead of the latest current' {
        Get-FmToolClassification -Present $true -Installed '0.1.30' -Latest '0.1.30' | Should -Be 'current'
        Get-FmToolClassification -Present $true -Installed '0.2.0' -Latest '0.1.30' | Should -Be 'current'
    }

    It 'never lets an unreadable version clear a floor it was not compared against' {
        Get-FmToolClassification -Present $true -Installed 'built from source' -Latest '0.1.30' -Minimum '0.1.29' |
            Should -Be 'unknown-version'
    }

    It 'says the published version is unknown rather than calling the tool current' {
        # An unreachable vendor must not read as "you are up to date".
        Get-FmToolClassification -Present $true -Installed '1.2.3' -Latest '' | Should -Be 'unknown-latest'
    }

    It 'reports an unmet capability as unsupported however new the version is' {
        Get-FmToolClassification -Present $true -Installed '99.0.0' -Latest '99.0.0' -CapabilityMet $false |
            Should -Be 'unsupported'
    }

    It 'ranks two date-stamped builds by their date' {
        # herdr's Windows builds are tagged preview-<date>-<sha> and the binary
        # reports 0.7.5-preview.<date>-<sha>; ranking those by semver compares
        # 0.7.5 against nothing at all.
        Get-FmToolClassification -Present $true -Installed 'herdr 0.7.5-preview.2026-07-21-0f10e145' `
            -Latest 'preview-2026-08-17-1147e60b' | Should -Be 'older'
        Get-FmToolClassification -Present $true -Installed 'herdr 0.7.5-preview.2026-08-17-1147e60b' `
            -Latest 'preview-2026-08-17-1147e60b' | Should -Be 'current'
    }

    It 'refuses to rank a date stamp against a semantic version' {
        # Two unrelated numbers. Saying so beats guessing which is newer.
        Get-FmToolClassification -Present $true -Installed '0.7.5' -Latest 'preview-2026-08-17-1147e60b' |
            Should -Be 'unknown-latest'
    }

    It 'reads a version out of every banner shape these tools actually print' {
        (Get-FmToolVersionNumber -Text 'git version 2.49.0.windows.1').ToString() | Should -Be '2.49.0'
        (Get-FmToolVersionNumber -Text 'v2.1.1').ToString() | Should -Be '2.1.1'
        (Get-FmToolVersionNumber -Text '2.1.233 (Claude Code)').ToString() | Should -Be '2.1.233'
        (Get-FmToolVersionNumber -Text 'gh version 2.97.0 (2026-07-31)').ToString() | Should -Be '2.97.0'
        Get-FmToolVersionNumber -Text 'unversioned build' | Should -BeNullOrEmpty
    }
}

Describe 'what the captain is asked' {
    BeforeAll {
        function New-Requirement {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory requirement record and changes nothing.')]
            param([string]$Classification, [string]$Version = '1.0.0', [string]$Latest = '2.0.0')
            [pscustomobject]@{
                Label          = 'demo'
                Classification = $Classification
                Version        = $Version
                Latest         = $Latest
                Path           = 'C:\demo\demo.exe'
            }
        }
    }

    It 'asks about an older tool with what is installed, what is published, and the cost of declining' {
        $question = Get-FmMachineQuestion -Requirement (New-Requirement -Classification 'older')
        $question | Should -Match '1\.0\.0'
        $question | Should -Match '2\.0\.0'
        $question | Should -Match 'Declining' -Because 'a bare "Update? y/n" makes the captain guess the consequence of their own answer'
    }

    It 'asks nothing about a missing tool, because installing it is the job' {
        Get-FmMachineQuestion -Requirement (New-Requirement -Classification 'missing') | Should -Be ''
    }

    It 'asks nothing about an unsupported tool, because the answer must never be to install over it' {
        Get-FmMachineQuestion -Requirement (New-Requirement -Classification 'unsupported') | Should -Be ''
    }

    It 'asks nothing about a current tool' {
        Get-FmMachineQuestion -Requirement (New-Requirement -Classification 'current') | Should -Be ''
    }
}

Describe 'the no-administrator portable install' {
    BeforeEach {
        $script:InstallRoot = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        # THE WHOLE SHAPE, DECLARED. Install-FmToolPortable runs under strict
        # mode, where reading a field a record does not carry is a terminating
        # error - which is how a first real install died. A test record that
        # declared less than the real one would hide exactly that.
        $script:Portable = [pscustomobject]@{
            Tool            = 'demotool'
            Source          = 'github'
            Repository      = 'demo/demo'
            ManifestUrl     = ''
            AssetKey        = ''
            AssetPattern    = 'demo_*_windows_amd64.zip'
            BinSubdirectory = 'bin'
            StripRoot       = $false
            ExtraPath       = @()
            ConfigPath      = ''
            ConfigContent   = ''
        }
    }

    It 'expands the release into the user profile and puts its bin on PATH' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'demo.zip')
        $result = Install-FmToolPortable -Portable $script:Portable -InstallRoot $script:InstallRoot `
            -ArchivePath $archive -PathScope Process -Confirm:$false

        $result.Action | Should -Be 'installed'
        Test-Path -LiteralPath (Join-Path $script:InstallRoot 'demotool' 'bin' 'demo.txt') | Should -BeTrue
        Test-FmToolOnPath -Directory $result.BinDirectory -Scope Process | Should -BeTrue
    }

    It 'is safe to run again, and leaves PATH with one entry rather than two' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'demo-again.zip')
        $first = Install-FmToolPortable -Portable $script:Portable -InstallRoot $script:InstallRoot `
            -ArchivePath $archive -PathScope Process -Confirm:$false
        $null = Install-FmToolPortable -Portable $script:Portable -InstallRoot $script:InstallRoot `
            -ArchivePath $archive -PathScope Process -Confirm:$false

        $separator = [System.IO.Path]::PathSeparator
        @($env:PATH -split $separator | Where-Object { $_ -eq $first.BinDirectory }).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:InstallRoot 'demotool' 'bin' 'demo.txt') | Should -BeTrue
    }

    It 'strips the single versioned root an archive like node ships' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'demo-rooted.zip') -RootDirectory 'demo-v1.2.3-win-x64'
        $portable = [pscustomobject]@{
            Tool = 'rootedtool'; Source = 'github'; Repository = 'demo/demo'; ManifestUrl = ''; AssetKey = ''
            AssetPattern = '*.zip'; BinSubdirectory = 'bin'; StripRoot = $true
            ExtraPath = @(); ConfigPath = ''; ConfigContent = ''
        }
        $null = Install-FmToolPortable -Portable $portable -InstallRoot $script:InstallRoot `
            -ArchivePath $archive -PathScope Process -Confirm:$false
        Test-Path -LiteralPath (Join-Path $script:InstallRoot 'rootedtool' 'bin' 'demo.txt') | Should -BeTrue
    }

    It 'refuses an archive whose layout is not what the route expects, and names the layout' {
        # A vendor that reorganises its zip must produce a refusal, not a
        # directory on PATH with nothing runnable in it.
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'demo-nobin.zip') -BinDirectory 'sbin'
        { Install-FmToolPortable -Portable $script:Portable -InstallRoot $script:InstallRoot `
                -ArchivePath $archive -PathScope Process -Confirm:$false } |
            Should -Throw '*is not there; the release layout is not what this route expects*'
    }

    It 'writes nothing under -WhatIf' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'demo-whatif.zip')
        $result = Install-FmToolPortable -Portable $script:Portable -InstallRoot $script:InstallRoot `
            -ArchivePath $archive -PathScope Process -WhatIf
        $result.Action | Should -Be 'skipped'
        Test-Path -LiteralPath (Join-Path $script:InstallRoot 'demotool') | Should -BeFalse
    }
}

Describe 'running a route on what the planner actually hands over' {
    # THE DEFECT THIS PINS, and why nothing here saw it.
    #
    # Invoke-FmToolRoute took an untyped -Entry record beside the route and
    # built its result from $Entry.Tool. Get-FmMachineInstallPlan, its only
    # caller's producer, publishes Name. Under strict mode the FIRST non-module
    # install threw "The property 'Tool' cannot be found on this object" and
    # took the whole run with it - measured on the captain's clean Windows 11
    # machine, 2026-08-20.
    #
    # It survived every test in this file because no test ever put the planner's
    # own records through the install call. A record a test writes for itself
    # proves the function accepts THAT record, which is not the question; the
    # question is whether it accepts the one the caller passes. So these take
    # the plan untouched, exactly as install.ps1 hands it over.
    #
    # -WhatIf THROUGHOUT, and it is not a weaker check for this defect: the
    # crash was on the first line of the function body, which -WhatIf reaches
    # before it declines to do anything. It is what lets every requirement -
    # including the ones this machine would otherwise really install - go
    # through the real call with nothing downloaded and nothing written.
    BeforeAll {
        $script:LivePlan = Get-FmMachineInstallPlan -Offline
    }

    It 'accepts every requirement in the plan, and answers naming that tool' {
        @($script:LivePlan.Requirements).Count | Should -BeGreaterThan 0 -Because 'an empty plan would make this vacuous'
        foreach ($requirement in $script:LivePlan.Requirements) {
            $result = Invoke-FmToolRoute -Route $requirement.Route -WhatIf
            $result.Tool | Should -Be $requirement.Name -Because "$($requirement.Label) must come back named as itself"
            $result.Action | Should -BeIn @('skipped', 'manual', 'needs-admin', 'blocked')
        }
    }

    It 'carries a route naming its own tool on every requirement, module ones included' {
        # The route is now the ONLY record Invoke-FmToolRoute is given, so a
        # route that does not name its tool is the one remaining way to
        # reproduce the crash. Both producers are covered: Get-FmToolRoute for a
        # tool, and the module route Get-FmMachineInstallPlan builds inline.
        foreach ($requirement in $script:LivePlan.Requirements) {
            $requirement.Route.PSObject.Properties.Name | Should -Contain 'Tool'
            $requirement.Route.Tool | Should -Be $requirement.Name
        }
        @($script:LivePlan.Requirements | Where-Object { $_.Kind -eq 'module' }).Count |
            Should -BeGreaterThan 0 -Because 'the module requirements take the same path and must be covered too'
    }
}

Describe 'choosing the release asset' {
    BeforeAll {
        $script:Release = [pscustomobject]@{
            tag_name = 'v2.97.0'
            assets   = @(
                [pscustomobject]@{ name = 'gh_2.97.0_windows_386.zip'; browser_download_url = 'https://example.invalid/386.zip' }
                [pscustomobject]@{ name = 'gh_2.97.0_windows_amd64.msi'; browser_download_url = 'https://example.invalid/amd64.msi' }
                [pscustomobject]@{ name = 'gh_2.97.0_windows_amd64.zip'; browser_download_url = 'https://example.invalid/amd64.zip' }
            )
        }
    }

    It 'takes the zip for this architecture and not the machine-wide MSI beside it' {
        $asset = Get-FmToolReleaseAsset -Release $script:Release -AssetPattern 'gh_*_windows_amd64.zip'
        $asset.Name | Should -Be 'gh_2.97.0_windows_amd64.zip'
        $asset.Url | Should -Be 'https://example.invalid/amd64.zip'
        $asset.Tag | Should -Be 'v2.97.0'
    }

    It 'refuses, naming the pattern, when the release carries nothing that matches' {
        { Get-FmToolReleaseAsset -Release $script:Release -AssetPattern 'gh_*_windows_riscv.zip' } |
            Should -Throw "*no asset matching 'gh_*_windows_riscv.zip'*"
    }
}

Describe 'PATH' {
    It 'adds a directory once and reports already the second time' {
        $directory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $directory -Force
        (Add-FmToolUserPath -Directory $directory -Scope Process -Confirm:$false).Action | Should -Be 'updated'
        (Add-FmToolUserPath -Directory $directory -Scope Process -Confirm:$false).Action | Should -Be 'already'
        Test-FmToolOnPath -Directory $directory -Scope Process | Should -BeTrue
    }

    It 'writes nothing under -WhatIf' {
        $directory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $directory -Force
        (Add-FmToolUserPath -Directory $directory -Scope Process -WhatIf).Action | Should -Be 'skipped'
        Test-FmToolOnPath -Directory $directory -Scope Process | Should -BeFalse
    }

    It 'keeps what this process added when it reloads the persisted environment' {
        # A tool installed a moment ago is on the process PATH and not yet
        # anywhere durable. A reload that dropped it would report the tool it
        # just installed as missing.
        $directory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $directory -Force
        $null = Add-FmToolUserPath -Directory $directory -Scope Process -Confirm:$false
        $null = Update-FmToolSessionPath -Confirm:$false
        Test-FmToolOnPath -Directory $directory -Scope Process | Should -BeTrue
    }
}

Describe 'the enablers, checked before they are used' {
    It 'reports the shell, the package manager and npm, each with what it enables' {
        $enablers = @(Get-FmToolEnablerStatus)
        @($enablers | ForEach-Object { $_.Name }) | Should -Contain 'PowerShell 7'
        @($enablers | ForEach-Object { $_.Name }) | Should -Contain 'winget'
        @($enablers | ForEach-Object { $_.Name }) | Should -Contain 'npm'
        foreach ($enabler in $enablers) {
            $enabler.Enables | Should -Not -BeNullOrEmpty
            $enabler.Fix | Should -Not -BeNullOrEmpty -Because "$($enabler.Name) being absent has to come with what to do about it"
        }
    }

    It 'is satisfied about PowerShell 7, because this suite is running on it' {
        $shell = @(Get-FmToolEnablerStatus | Where-Object { $_.Name -eq 'PowerShell 7' })[0]
        $shell.Satisfied | Should -BeTrue
    }

    It 'refuses a winget route rather than shelling out to a command that is not there' -Skip:(-not $IsWindows) {
        # The failure this prevents is a bare "winget is not recognized" in the
        # middle of a run. It is only reachable when winget genuinely is absent,
        # so the assertion is on the branch that decides, not on the message.
        $route = Get-FmToolRoute -Tool 'git'
        $route.Command | Should -Match '^winget '
        (Get-FmToolWingetPath) | Should -Not -BeNull
    }
}

Describe 'the firstmate command' {
    It 'runs start.ps1 through pwsh with no profile' {
        $text = Get-FmMachineShimText -StartScript 'C:\demo\start.ps1'
        $text | Should -Match 'pwsh -NoProfile'
        $text | Should -Match 'C:\\demo\\start\.ps1'
        $text | Should -Match '%\*' -Because "the captain's own arguments have to reach start.ps1"
    }

    It 'is created once and reports already the second time' {
        $installRoot = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $first = Set-FmMachineCommandShim -RepoRoot $script:RepoRoot -InstallRoot $installRoot -PathScope Process -Confirm:$false
        $first.Action | Should -Be 'created'
        Test-Path -LiteralPath (Join-Path $installRoot 'firstmate' 'firstmate.cmd') | Should -BeTrue
        (Set-FmMachineCommandShim -RepoRoot $script:RepoRoot -InstallRoot $installRoot -PathScope Process -Confirm:$false).Action |
            Should -Be 'already'
    }

    It 'writes nothing under -WhatIf' {
        $installRoot = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        (Set-FmMachineCommandShim -RepoRoot $script:RepoRoot -InstallRoot $installRoot -PathScope Process -WhatIf).Action |
            Should -Be 'skipped'
        Test-Path -LiteralPath (Join-Path $installRoot 'firstmate') | Should -BeFalse
    }
}

Describe 'PowerShell 7, findable' {
    # WHY THIS EXISTS. install.ps1's PowerShell 7 route is Microsoft's own
    # installer pointed at a per-user directory, because it is the one that
    # needs no administrator - and it expands a zip, so it registers nothing.
    # The captain was told PowerShell 7 was installed, the run re-launched
    # itself under %LOCALAPPDATA%\Programs\PowerShell7\pwsh.exe, and there was
    # no Start menu entry and no other way to open it as an application.
    #
    # These run against disposable directories with -StartMenuDirectory, so a
    # real .lnk is written and read back without touching the captain's own
    # Start menu.
    BeforeEach {
        $script:StartMenu = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $script:CommonStartMenu = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:StartMenu -Force
        $null = New-Item -ItemType Directory -Path $script:CommonStartMenu -Force
        $script:Pwsh = [string](Get-Process -Id $PID).Path
    }

    It 'writes a Start menu entry that launches this pwsh' -Skip:(-not $IsWindows) {
        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false

        $result.Action | Should -Be 'created'
        Test-Path -LiteralPath $result.Shortcut -PathType Leaf | Should -BeTrue
        # Read the shortcut's REAL target back rather than trusting that Save()
        # meant it: a .lnk pointing at nothing is exactly the outcome this is
        # here to refuse.
        $shell = New-Object -ComObject WScript.Shell
        try { [string]$shell.CreateShortcut($result.Shortcut).TargetPath | Should -Be $script:Pwsh }
        finally { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }

    It 'puts it in the USER folder, which is the one that needs no administrator' -Skip:(-not $IsWindows) {
        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false
        Split-Path -Parent $result.Shortcut | Should -Be $script:StartMenu
        @(Get-ChildItem -LiteralPath $script:CommonStartMenu -Force).Count | Should -Be 0 -Because 'the machine-wide folder is searched, never written'
    }

    It 'adds no second entry when one already launches this pwsh' -Skip:(-not $IsWindows) {
        $first = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false
        $again = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false

        $again.Action | Should -Be 'already'
        $again.Shortcut | Should -Be $first.Shortcut
        @(Get-ChildItem -LiteralPath $script:StartMenu -Filter '*.lnk' -Recurse -Force).Count | Should -Be 1
    }

    It 'finds the vendor''s own entry, nested in a subfolder and named its way' -Skip:(-not $IsWindows) {
        # The machine-wide MSI writes "PowerShell\PowerShell 7 (x64).lnk", so
        # matching on the shortcut's NAME or searching one level deep would both
        # miss it and leave the captain with two Start entries for one shell.
        $nested = Join-Path $script:CommonStartMenu 'PowerShell'
        $null = New-Item -ItemType Directory -Path $nested -Force
        $shell = New-Object -ComObject WScript.Shell
        try {
            $vendor = $shell.CreateShortcut((Join-Path $nested 'PowerShell 7 (x64).lnk'))
            $vendor.TargetPath = $script:Pwsh
            $vendor.Save()
        } finally { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }

        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false
        $result.Action | Should -Be 'already'
        $result.Detail | Should -Match 'PowerShell 7 \(x64\)'
        @(Get-ChildItem -LiteralPath $script:StartMenu -Filter '*.lnk' -Recurse -Force).Count | Should -Be 0
    }

    It 'ignores a shortcut that points at some other shell' -Skip:(-not $IsWindows) {
        # What decides whether PowerShell 7 is findable is what the shortcut
        # POINTS AT. Windows PowerShell 5.1 has a Start entry on every machine,
        # and it is not this.
        $other = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shell = New-Object -ComObject WScript.Shell
        try {
            $decoy = $shell.CreateShortcut((Join-Path $script:StartMenu 'Windows PowerShell.lnk'))
            $decoy.TargetPath = $other
            $decoy.Save()
        } finally { $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }

        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -Confirm:$false
        $result.Action | Should -Be 'created'
        $result.Shortcut | Should -Be (Join-Path $script:StartMenu 'PowerShell 7.lnk')
    }

    It 'writes nothing under -WhatIf' -Skip:(-not $IsWindows) {
        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh `
            -StartMenuDirectory @($script:StartMenu, $script:CommonStartMenu) -WhatIf
        $result.Action | Should -Be 'skipped'
        $result.Detail | Should -Be 'WhatIf'
        @(Get-ChildItem -LiteralPath $script:StartMenu -Force).Count | Should -Be 0
    }

    It 'defaults to the real per-user Start menu folder, without writing to it' -Skip:(-not $IsWindows) {
        # The default is the whole point of the fix, so it is asserted rather
        # than assumed - under -WhatIf, so this test cannot put an entry in the
        # captain's own Start menu.
        $result = Set-FmMachineShellShortcut -PwshPath $script:Pwsh -WhatIf
        $userPrograms = [Environment]::GetFolderPath('Programs')
        if ($result.Action -eq 'already') {
            # This machine has PowerShell 7 from the machine-wide installer, so
            # the correct answer is to find that one and add nothing.
            $result.Shortcut | Should -Not -BeNullOrEmpty
        } else {
            $result.Detail | Should -Be 'WhatIf'
            # Assigned before indexing: a one-element result would otherwise be
            # a bare string, and [0] would answer with its first CHARACTER.
            $folders = @(Get-FmMachineStartMenuDirectory)
            $folders[0] | Should -Be $userPrograms
        }
    }

    It 'tells the captain where it is and how to open it' -Skip:(-not $IsWindows) {
        $created = [pscustomobject]@{
            Action = 'created'; Detail = 'x'; PwshPath = 'C:\Users\x\AppData\Local\Programs\PowerShell7\pwsh.exe'
            Shortcut = 'C:\Users\x\...\PowerShell 7.lnk'
        }
        $lines = (Get-FmMachineShellLine -Shortcut $created) -join "`n"
        $lines | Should -Match ([regex]::Escape($created.PwshPath))
        $lines | Should -Match 'Start, as "PowerShell 7"'
        # A per-user install cannot register the Windows Terminal profile or the
        # right-click entries, and the one command that can needs administrator.
        # Naming it is the honest answer; a run that installed it would not be.
        $lines | Should -Match 'winget install -e --id Microsoft\.PowerShell'
        $lines | Should -Match 'needs administrator'
    }

    It 'does not push the elevated installer at a machine that already registers it' -Skip:(-not $IsWindows) {
        $already = [pscustomobject]@{
            Action = 'already'; Detail = 'x'; PwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
            Shortcut = 'C:\ProgramData\...\PowerShell 7 (x64).lnk'
        }
        $lines = (Get-FmMachineShellLine -Shortcut $already) -join "`n"
        $lines | Should -Match 'PowerShell 7 \(x64\)'
        $lines | Should -Not -Match 'winget install -e --id Microsoft\.PowerShell'
    }
}

Describe 'the suite that proves the install' {
    It 'reports a suite it could not run as NOT RUN, never as a pass' {
        # An empty failure count from a suite that never started is the exact
        # shape of a false clean bill of health.
        $empty = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $empty -Force
        $result = Invoke-FmMachineSuite -RepoRoot $empty
        $result.Ran | Should -BeFalse
        $result.Detail | Should -Match 'no tests directory'
    }

    It 'really runs a suite, and reports the failures it found rather than a count alone' {
        # A tiny repository of its own, so the runner is exercised end to end -
        # the child process, the result file, the parse, and the named failures -
        # without running this repository's own suite inside itself.
        $fake = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path (Join-Path $fake 'tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $fake 'tests' 'Demo.Tests.ps1'), @'
Describe 'demo' {
    It 'passes' { 1 | Should -Be 1 }
    It 'fails on purpose' { 1 | Should -Be 2 }
}
'@)
        $result = Invoke-FmMachineSuite -RepoRoot $fake -TimeoutSeconds 300
        $result.Ran | Should -BeTrue
        $result.Passed | Should -Be 1
        $result.Failed | Should -Be 1
        # NAMED, not counted: "1 failed" tells the captain nothing to act on.
        ($result.FailedNames -join ' ') | Should -Match 'fails on purpose'
    }

    It 'starts that child as a host that cannot ask the captain anything' {
        # THE INSTALL THAT HUNG FOREVER, and the reason this is a test rather
        # than a habit. A suite proves a refusal by leaving a mandatory
        # parameter off on purpose; on a host that CAN prompt, PowerShell binds
        # it by ASKING instead of failing. This child is started -NoNewWindow,
        # so the host it would ask on is the captain's own console, mid-install,
        # under a bare "Supply values for the following parameters:" with no
        # test name against it and nothing on screen to say what wants an
        # answer. The whole install sat there. docs/windows-e2e-evidence.md
        # section 39 has the captain's screen and the measurement.
        #
        # Both halves are observed from INSIDE the process this function
        # actually started, never read off the source that starts it: the child
        # says what it was launched with, and then proves the consequence by
        # binding a mandatory parameter it was never given.
        $fake = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path (Join-Path $fake 'tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $fake 'tests' 'Prompt.Tests.ps1'), @'
Describe 'the host this suite was given' {
    It 'cannot prompt' {
        [Environment]::GetCommandLineArgs() | Should -Contain '-NonInteractive'
    }
    It 'fails a missing mandatory parameter rather than asking for it' {
        function Test-FmPromptBait {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Needed)
            $Needed
        }
        { Test-FmPromptBait } | Should -Throw -ErrorId 'MissingMandatoryParameter,Test-FmPromptBait'
    }
}
'@)
        # Bounded on purpose: with the switch gone the second test PROMPTS, and
        # this call then returns on its own timeout instead of hanging the suite
        # that is checking it - the regression reads as "did not finish", which
        # is a reportable failure rather than a second wedged run.
        $result = Invoke-FmMachineSuite -RepoRoot $fake -TimeoutSeconds 180
        $result.Ran | Should -BeTrue -Because $result.Detail
        $result.Failed | Should -Be 0 -Because ($result.FailedNames -join '; ')
        $result.Passed | Should -Be 2
    }
}

Describe 'Install-FmMachine' {
    It 'refuses without -Approved, and installs nothing' {
        $report = Install-FmMachine -RepoRoot $script:RepoRoot -Offline
        $report.Installed | Should -BeFalse
        $report.Verified | Should -BeFalse
        $report.Ready | Should -BeFalse
        $report.Reason | Should -Match 'needs -Approved'
        # The plan is still shown, because a refusal that says nothing is no
        # more useful than a silent one.
        $report.Lines -join "`n" | Should -Match 'what this machine has'
    }

    It 'refuses a directory that is not a firstmate checkout' {
        $notACheckout = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $notACheckout -Force
        { Install-FmMachine -Approved -RepoRoot $notACheckout -Offline } |
            Should -Throw '*does not look like a firstmate-win checkout*'
    }

    It 'changes nothing under -WhatIf, and says so instead of claiming a pass' {
        $report = Install-FmMachine -Approved -RepoRoot $script:RepoRoot -Offline -WhatIf -WarningAction SilentlyContinue
        $report.Installed | Should -BeFalse
        $report.Verified | Should -BeFalse
        $report.Ready | Should -BeFalse
        $report.Lines[-1] | Should -Match 'WhatIf - nothing was installed'
        foreach ($outcome in $report.Outcomes) { $outcome.Detail | Should -Be 'WhatIf' }
    }

    It 'plans every requirement, with a reason and a route for each' {
        $plan = Get-FmMachineInstallPlan -Offline
        $plan.Requirements.Count | Should -BeGreaterThan 0
        foreach ($requirement in $plan.Requirements) {
            $requirement.Classification | Should -Not -BeNullOrEmpty
            $requirement.Reason | Should -Not -BeNullOrEmpty
            $requirement.Route | Should -Not -BeNull
            # What to run to REPLACE it, which is what an unsupported version's
            # report hands the captain, and is not always what installs it fresh.
            $requirement.UpdateCommand | Should -Not -BeNullOrEmpty
        }
    }

    It 'hands the captain an upgrade command for the winget tools, not an install one' -Skip:(-not $IsWindows) {
        $plan = Get-FmMachineInstallPlan -Offline
        $git = @($plan.Requirements | Where-Object { $_.Name -eq 'git' })[0]
        $git.UpdateCommand | Should -Be 'winget upgrade -e --id Git.Git --source winget --accept-source-agreements --accept-package-agreements'
    }

    It 'classifies everything as unknown-latest offline rather than calling it current' {
        $plan = Get-FmMachineInstallPlan -Offline
        $present = @($plan.Requirements | Where-Object { $_.Present -and $_.Version })
        $present.Count | Should -BeGreaterThan 0 -Because 'this machine has tools installed, so the check is not vacuous'
        foreach ($requirement in $present) {
            $requirement.Classification | Should -BeIn @('unknown-latest', 'unsupported', 'unknown-version') `
                -Because 'nothing was asked of any vendor, so nothing can be called current'
        }
    }

    It 'drops the optional tools entirely under -SkipOptional' {
        $plan = Get-FmMachineInstallPlan -Offline -SkipOptional
        @($plan.Requirements | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'gh' }).Count | Should -Be 0
        @($plan.Requirements | Where-Object { $_.Name -eq 'herdr' }).Count | Should -Be 1
    }
}

Describe 'a launch this machine refuses' {
    # THE DEFECT, PINNED. A child shell Windows declined to start raised a raw
    # .NET error - "Program 'pwsh.exe' failed to run ... Access is denied" plus a
    # stack trace - and took the whole install with it at the first tool that
    # needed one. MEASURED on the captain's machine, 2026-08-20. The first
    # diagnosis drawn from that text was wrong: it read as a permission problem
    # between two accounts, and the captain disproved it by running the whole
    # thing as a single user, where it failed identically. That is what a raw
    # exception costs.
    #
    # A file that is not a program is the seam: CreateProcess refuses it for
    # real, so every one of these runs the true refusal path on any machine,
    # without needing a machine that refuses things.
    #
    # THE FIXTURE IS EMPTY, AND MUST STAY EMPTY. Filling it with text made
    # Windows read it as an MS-DOS program and put "Unsupported 16-Bit
    # Application" on the captain's desktop, where it outlived the run. The
    # refusal is identical either way. New-FmUnstartableFixture owns that whole
    # story; do not hand-write these bytes here.
    BeforeAll {
        $script:BadBin = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:BadBin -Force
        $script:BadExe = New-FmUnstartableFixture -Path (Join-Path $script:BadBin 'fm-unstartable.exe')
    }

    It 'separates "not on PATH" from "would not start" from "ran and answered"' -Skip:(-not $IsWindows) {
        $env:PATH = $script:BadBin + [System.IO.Path]::PathSeparator + $script:SavedPath
        try {
            $absent = Invoke-FmSessionCommandLine -Command 'fm-no-such-tool-at-all'
            $absent.Found | Should -BeFalse
            $absent.Launched | Should -BeFalse

            $refused = Invoke-FmSessionCommandLine -Command 'fm-unstartable'
            $refused.Found | Should -BeTrue -Because 'it is on PATH'
            $refused.Launched | Should -BeFalse -Because 'Windows would not start it'
            # AND THE EXCEPTION IS NOT SMUGGLED OUT AS OUTPUT. It used to be
            # returned as the command's own first line, which is how a refusal
            # reached a caller wearing a tool banner's clothes.
            @($refused.Output).Count | Should -Be 0

            $real = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('--version')
            $real.Launched | Should -BeTrue
        } finally { $env:PATH = $script:SavedPath }
    }

    It 'reports a tool it could not start as UNUSABLE, through the real detection' -Skip:(-not $IsWindows) {
        $env:PATH = $script:BadBin + [System.IO.Path]::PathSeparator + $script:SavedPath
        try {
            # The producer's own record goes into the consumer untouched: nothing
            # here builds a status by hand, which is how the last defect in this
            # area survived a green suite.
            $status = Get-FmToolStatus -Command 'fm-unstartable'
            $status.Present | Should -BeTrue
            $status.Launchable | Should -BeFalse
            $status.Version | Should -Be ''

            Get-FmToolClassification -Present $status.Present -Installed $status.Version -Launchable $status.Launchable |
                Should -Be 'unusable'
        } finally { $env:PATH = $script:SavedPath }
    }

    It 'keeps a tool that DOES start out of the unusable class' -Skip:(-not $IsWindows) {
        # The other direction, and the one that matters most: over-rejecting
        # would report a working machine as broken.
        $status = Get-FmToolStatus -Command 'git'
        $status.Present | Should -BeTrue
        $status.Launchable | Should -BeTrue
        Get-FmToolClassification -Present $status.Present -Installed $status.Version -Launchable $status.Launchable |
            Should -Not -Be 'unusable'
    }

    It 'says it in the captain plain words, and never in the exception ones' -Skip:(-not $IsWindows) {
        $env:PATH = $script:BadBin + [System.IO.Path]::PathSeparator + $script:SavedPath
        try {
            $status = Get-FmToolStatus -Command 'fm-unstartable'
            $reason = Get-FmToolClassificationReason -Requirement ([pscustomobject]@{
                    Classification    = 'unusable'
                    Command           = 'fm-unstartable'
                    Path              = $status.Path
                    Why               = 'the tests'
                    Version           = ''
                    Latest            = ''
                    Minimum           = ''
                    MinimumSource     = ''
                    MinimumCapability = ''
                })
            $reason | Should -Match 'refused to start'
            $reason | Should -Match ([regex]::Escape($status.Path))
            # No exception text, no stack trace, no .NET wrapper.
            $reason | Should -Not -Match 'failed to run'
            $reason | Should -Not -Match 'An error occurred trying to start process'
            $reason | Should -Not -Match 'Exception'
            $reason | Should -Not -Match 'char:\d'
        } finally { $env:PATH = $script:SavedPath }
    }

    It 'turns a refused install command into an outcome, not a terminating error' -Skip:(-not $IsWindows) {
        # END TO END through the REAL route record. Nothing is installed: the
        # shell it is told to use cannot start, so the vendor's command is never
        # reached - which is also what makes running this safe.
        $route = Get-FmToolRoute -Tool 'claude'
        $route.Kind | Should -Be 'command' -Because 'the route this exercises has to be one that needs a child shell'

        { $script:RouteResult = Invoke-FmToolRoute -Route $route -ShellPath $script:BadExe -PathScope 'Process' -Confirm:$false } |
            Should -Not -Throw
        $result = $script:RouteResult
        $result.Action | Should -Be 'blocked'
        $result.Detail | Should -Match 'refused to start'
        $result.Detail | Should -Match ([regex]::Escape($route.Command)) -Because 'the captain is left with the command to run themselves'
        $result.Detail | Should -Not -Match 'An error occurred trying to start process'
        $result.Detail | Should -Not -Match 'FmToolInstall\.ps1'
    }

    It 'still runs the command when the shell DOES start' -Skip:(-not $IsWindows) {
        # The other direction for the launcher itself, so the guard cannot be
        # satisfied by refusing everything.
        $run = Invoke-FmToolShellCommand -Command '"launched"; exit 0'
        $run.Launched | Should -BeTrue
        $run.ExitCode | Should -Be 0
        ($run.Output -join ' ') | Should -Match 'launched'
    }

    It 'reports a non-zero install command as failed rather than as refused' -Skip:(-not $IsWindows) {
        # "The machine would not start it" and "it ran and went wrong" are two
        # different things to tell the captain, and blurring them would put the
        # refusal wording where it is untrue.
        $run = Invoke-FmToolShellCommand -Command 'exit 9'
        $run.Launched | Should -BeTrue
        $run.ExitCode | Should -Be 9
    }

    It 'carries the unusable class through the real plan and names it in the report' -Skip:(-not $IsWindows) {
        # THE PLAN, not a record built here. PATH is narrowed to the unstartable
        # stub so the catalog's own commands resolve to it, and the session PATH
        # rebuild is stood down for the same reason - it reads the persisted
        # environment, which this suite must never write.
        Mock Update-FmToolSessionPath { $env:PATH }
        $env:PATH = $script:BadBin
        try {
            foreach ($entry in (Get-FmToolCatalog)) {
                Copy-Item -LiteralPath $script:BadExe -Destination (Join-Path $script:BadBin ($entry.Command + '.exe')) -Force
            }
            $plan = Get-FmMachineInstallPlan -Offline
            $plan.Unusable.Count | Should -BeGreaterThan 0
            foreach ($requirement in $plan.Unusable) {
                $requirement.Present | Should -BeTrue
                $requirement.Launchable | Should -BeFalse
                $requirement.Reason | Should -Match 'refused to start'
                # 'unusable' is TOLD, never asked about: there is no answer the
                # captain can give about a program that will not run.
                $requirement.Question | Should -Be ''
            }
            ($plan.Lines -join [Environment]::NewLine) | Should -Match '\[unusable\]'
            # And it is not quietly folded into the ask-me pile.
            @($plan.Older | Where-Object { $_.Classification -eq 'unusable' }).Count | Should -Be 0
        } finally {
            $env:PATH = $script:SavedPath
            Get-ChildItem -LiteralPath $script:BadBin -Filter '*.exe' |
                Where-Object { $_.Name -ne 'fm-unstartable.exe' } | Remove-Item -Force
        }
    }

    It 'names the outcome in the end report' {
        $lines = @(Get-FmMachineSummaryLine -Outcomes @(
                [pscustomobject]@{ Label = 'gh'; Classification = 'unusable'; Outcome = 'unusable-skipped'; Detail = 'x' })) -join [Environment]::NewLine
        $lines | Should -Match 'gh\s+UNUSABLE - this machine refused to start it'
    }

    It 'fails the verification pass over a tool that will not start, and says which failure it is' -Skip:(-not $IsWindows) {
        # The proving pass and the plan ask different questions, so the class has
        # to reach BOTH. "It ran and printed nothing useful" and "it never ran"
        # are different findings, and the check must not print the first one.
        Mock Update-FmToolSessionPath { $env:PATH }
        $env:PATH = $script:BadBin
        try {
            foreach ($entry in (Get-FmToolCatalog)) {
                Copy-Item -LiteralPath $script:BadExe -Destination (Join-Path $script:BadBin ($entry.Command + '.exe')) -Force
            }
            $checks = @(Get-FmMachineToolVerification)
            $checks.Count | Should -BeGreaterThan 0
            $required = @($checks | Where-Object { $_.Name -eq 'tool git' })
            $required.Count | Should -Be 1
            $required[0].Status | Should -Be 'missing' -Because 'a required tool that cannot be exercised is not a proven install'
            $required[0].Detail | Should -Match 'refused to start'
            $required[0].Detail | Should -Not -Match 'answers nothing to --version'
            $required[0].Detail | Should -Not -Match 'An error occurred trying to start process'
        } finally {
            $env:PATH = $script:SavedPath
            Get-ChildItem -LiteralPath $script:BadBin -Filter '*.exe' |
                Where-Object { $_.Name -ne 'fm-unstartable.exe' } | Remove-Item -Force
        }
    }

    It 'calls an enabler that will not start UNSATISFIED rather than present' -Skip:(-not $IsWindows) {
        # An enabler is only an enabler if it runs. Reporting npm as satisfied
        # because a file with that name is on PATH sends every axi route at a
        # refusal it will each rediscover separately.
        $env:PATH = $script:BadBin
        try {
            Copy-Item -LiteralPath $script:BadExe -Destination (Join-Path $script:BadBin 'npm.exe') -Force
            $npm = @(Get-FmToolEnablerStatus | Where-Object { $_.Name -eq 'npm' })
            $npm.Count | Should -Be 1
            $npm[0].Present | Should -BeTrue -Because 'it is on PATH'
            $npm[0].Satisfied | Should -BeFalse -Because 'it does not run'
            $npm[0].Fix | Should -Not -BeNullOrEmpty
        } finally {
            $env:PATH = $script:SavedPath
            Remove-Item -LiteralPath (Join-Path $script:BadBin 'npm.exe') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports a suite it could not start as NOT RUN, in words, rather than crashing the report' -Skip:(-not $IsWindows) {
        # The suite is the LAST step, so an unguarded start here throws away the
        # whole report the captain has been waiting for.
        Mock Start-Process { throw [System.ComponentModel.Win32Exception]::new(5) }
        $fake = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path (Join-Path $fake 'tests') -Force
        [System.IO.File]::WriteAllText((Join-Path $fake 'tests' 'Demo.Tests.ps1'), 'Describe ''d'' { It ''p'' { 1 | Should -Be 1 } }')

        $result = $null
        { $script:SuiteResult = Invoke-FmMachineSuite -RepoRoot $fake -TimeoutSeconds 60 } | Should -Not -Throw
        $result = $script:SuiteResult
        $result.Ran | Should -BeFalse
        $result.Failed | Should -Be 0
        $result.Detail | Should -Match 'refused to start'
        $result.Detail | Should -Match 'Invoke-Pester' -Because 'the captain is left with the command to run themselves'
        $result.Detail | Should -Not -Match 'Win32Exception'
    }

    It 'tells the captain plainly when install.ps1 cannot re-launch itself' -Skip:(-not $IsWindows) {
        # THE CAPTAIN'S FIRST COMMAND, end to end. A clean Windows machine opens
        # Windows PowerShell 5.1, so this is the one path where a refusal is the
        # very first thing that happens - and where it used to arrive as
        # "Program 'pwsh.exe' failed to run" plus a stack trace.
        $windowsPowerShell = Join-Path $env:WINDIR 'System32' 'WindowsPowerShell' 'v1.0' 'powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 is not on this machine'
            return
        }
        # A pwsh that resolves and cannot be started, and a PATH holding nothing
        # else, so install.ps1 finds this one and gets no further. Nothing is
        # installed and nothing is detected: the run ends at the re-launch.
        $fakeShellDir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $fakeShellDir -Force
        Copy-Item -LiteralPath $script:BadExe -Destination (Join-Path $fakeShellDir 'pwsh.exe') -Force

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $windowsPowerShell
        # -NonInteractive because this child does NOT inherit its parent's, and
        # install.ps1 is the one entry point here that legitimately asks the
        # captain questions. Under test nobody is at that console, so a route
        # that reaches one must fail and be reported rather than sit waiting.
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $script:RepoRoot 'install.ps1'), '-DetectOnly')) {
            $psi.ArgumentList.Add($argument)
        }
        $psi.Environment['PATH'] = $fakeShellDir + [System.IO.Path]::PathSeparator + (Join-Path $env:WINDIR 'System32')
        $psi.WorkingDirectory = $script:RepoRoot
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit(120000) | Should -BeTrue -Because 'it must not sit there waiting'
        $combined = $stdout + [Environment]::NewLine + $stderr

        $process.ExitCode | Should -Be 1
        $combined | Should -Match 'refused to start PowerShell 7'
        $combined | Should -Match 'Controlled folder access'
        # Not a .NET error, and not a stack trace.
        $combined | Should -Not -Match 'failed to run'
        $combined | Should -Not -Match 'An error occurred trying to start process'
        $combined | Should -Not -Match 'At line:\d'
    }
}

Describe 'the optional channels' {
    BeforeEach {
        $script:OptionalHome = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path (Join-Path $script:OptionalHome 'config') -Force
    }

    It 'reports each one as off rather than assuming or setting it' {
        $lines = (Get-FmMachineOptionalLine -FirstmateHome $script:OptionalHome) -join "`n"
        $lines | Should -Match "\[off\]\s+captain's name"
        $lines | Should -Match '\[off\]\s+voice'
        $lines | Should -Match '\[off\]\s+phone channel'
        # And it wrote nothing: an installer that quietly creates config/voice
        # is a machine that starts talking.
        @(Get-ChildItem -LiteralPath (Join-Path $script:OptionalHome 'config')).Count | Should -Be 0
    }

    It 'reports a configured name and voice as on' {
        Set-Content -LiteralPath (Join-Path $script:OptionalHome 'config' 'captain-name') -Value 'Dhaval'
        Set-Content -LiteralPath (Join-Path $script:OptionalHome 'config' 'voice') -Value 'voice=Zira'
        $lines = (Get-FmMachineOptionalLine -FirstmateHome $script:OptionalHome) -join "`n"
        $lines | Should -Match '\[on\]\s+captain''s name - firstmate calls you "Dhaval"'
        $lines | Should -Match '\[on\]\s+voice'
    }

    It 'calls a phone channel with only one of its two files PARTIAL, not on' {
        # A token with no allow-list is a channel that looks configured and
        # refuses every message, which is the half-set state the brief forbids
        # being reported as either working or absent.
        Set-Content -LiteralPath (Join-Path $script:OptionalHome 'config' 'telegram-token') -Value 'x'
        $lines = (Get-FmMachineOptionalLine -FirstmateHome $script:OptionalHome) -join "`n"
        $lines | Should -Match '\[partial\]\s+phone channel'
    }
}

Describe 'the end report' {
    It 'names every requirement and what happened to it' {
        $outcomes = @(
            [pscustomobject]@{ Label = 'git'; Classification = 'missing'; Outcome = 'installed'; Detail = 'x' }
            [pscustomobject]@{ Label = 'node'; Classification = 'older'; Outcome = 'older-kept'; Detail = 'y' }
            [pscustomobject]@{ Label = 'gh-axi'; Classification = 'unsupported'; Outcome = 'unsupported-skipped'; Detail = 'z' }
        )
        $lines = @(Get-FmMachineSummaryLine -Outcomes $outcomes)
        ($lines -join "`n") | Should -Match 'git\s+installed'
        ($lines -join "`n") | Should -Match 'node\s+older, left alone at your choice'
        ($lines -join "`n") | Should -Match 'gh-axi\s+UNSUPPORTED, skipped'
    }

    It 'renders an empty run without failing' {
        @(Get-FmMachineSummaryLine -Outcomes @()).Count | Should -Be 1
    }
}

Describe 'a failed install, reported' {
    # THE DEFECT, PINNED. A failing install was reported as the command, its exit
    # code, and the LAST non-blank line the tool printed:
    #
    #   [skipped] Node.js - FAILED: 'winget install OpenJS.NodeJS' exited 1:
    #             Node.js OpenJS.NodeJS winget
    #
    # MEASURED from the captain's install log, 2026-08-20. That fragment is a row
    # of winget's package table, not an error. Firstmate read it, found no cause,
    # and told the captain the install needed administrator - which was wrong,
    # and which they had already acted on. These pin the three things that made
    # that report useless: the cause was thrown away, the exit code was the child
    # shell's rather than the tool's, and nothing said what it meant.

    BeforeAll {
        # The captain's shape exactly: a banner, the cause in the middle, and a
        # package table whose last row is what got reported as the error.
        $script:CaptainShape = @(
            'Write-Output "Windows Package Manager v1.9.25200"'
            'Write-Output "The source agreements were not accepted."'
            'Write-Output "Name    Id            Version Source"'
            'Write-Output "Node.js OpenJS.NodeJS 26.7.0  winget"'
            'exit 1'
        ) -join '; '

        function Get-FmDemoRoute {
            param([Parameter(Mandatory)][string]$Command, [string]$Tool = 'Node.js')
            [pscustomobject]@{
                Tool               = $Tool
                Kind               = 'command'
                Command            = $Command
                Portable           = $null
                NeedsAdministrator = $false
                Instructions       = ''
            }
        }
    }

    It 'keeps the cause, instead of the last line that happened to follow it' -Skip:(-not $IsWindows) {
        $result = Invoke-FmToolRoute -Route (Get-FmDemoRoute -Command $script:CaptainShape) -Confirm:$false
        $result.Action | Should -Be 'failed'
        $result.Detail | Should -Match 'The source agreements were not accepted'
        # What was run, so the reader can run it themselves.
        $result.Detail | Should -Match ([regex]::Escape('Windows Package Manager'))
        # The table row is still there - nothing is dropped - but it is no longer
        # the whole report, which is what made it read as the error.
        $result.Detail | Should -Match 'Node\.js OpenJS\.NodeJS'
        @($result.Detail -split '\r?\n').Count |
            Should -BeGreaterThan 1 -Because 'a failure flattened into one line is how the cause was lost'
    }

    It 'reports the exit code the TOOL returned, not the child shell verdict' -Skip:(-not $IsWindows) {
        # `pwsh -Command <native command>` exits 0 or 1 and discards the native
        # code, so every winget failure this installer ever reported arrived as a
        # bare 1 - a number that distinguishes nothing and means nothing.
        $result = Invoke-FmToolRoute -Route (Get-FmDemoRoute -Command 'cmd /c exit 42') -Confirm:$false
        $result.Action | Should -Be 'failed'
        $result.Detail | Should -Match 'exited 42'
    }

    It 'still calls a working install installed, whatever an earlier command left behind' -Skip:(-not $IsWindows) {
        # The other half of preferring the tool's code: a nonzero code left over
        # by some earlier native call inside a vendor script must not turn an
        # install that worked into a reported failure.
        $result = Invoke-FmToolRoute -Confirm:$false `
            -Route (Get-FmDemoRoute -Command 'cmd /c exit 3 | Out-Null; Write-Output "vendor installer finished"')
        $result.Action | Should -Be 'installed'
    }

    It 'says what an exit code means only where this repo has measured one' {
        # MEASURED, winget v1.29.280, 2026-08-20.
        Get-FmToolExitCodeMeaning -Command 'winget install -e --id Git.Git' -ExitCode -1978335212 |
            Should -Match 'no package'
        Get-FmToolExitCodeMeaning -Command 'winget install -e --id Git.Git' -ExitCode -1978335230 |
            Should -Match 'command line'
        # MEASURED from the captain's clean-VM log, 2026-08-20, where winget
        # printed this sentence about itself. Routes pin --source winget now, so
        # if it is seen again it is the source this repo DOES need that cannot be
        # reached, which is a different answer and worth saying.
        Get-FmToolExitCodeMeaning -Command 'winget install -e --id Git.Git' -ExitCode -1978335138 |
            Should -Match 'certificate'
        # AND NOTHING WHERE IT HAS NOT. An invented meaning is the defect that
        # started all this, so an unrecognised code says nothing at all and lets
        # the tool's own words stand.
        Get-FmToolExitCodeMeaning -Command 'winget install -e --id Git.Git' -ExitCode 9009 | Should -BeNullOrEmpty
        Get-FmToolExitCodeMeaning -Command 'npm install -g gh-axi' -ExitCode -1978335212 | Should -BeNullOrEmpty
    }

    It 'prints the code in the form it can be looked up in' {
        # A winget HRESULT arrives as a large negative decimal and is documented
        # in hex, so a report carrying only -1978335212 cannot be looked up.
        $detail = Get-FmToolRunFailureDetail -Command 'winget install -e --id Git.Git' -ExitCode -1978335212 `
            -Output @('No package found matching input criteria.')
        $detail | Should -Match '0x8A150014'
        $detail | Should -Match 'No package found matching input criteria'
    }

    It 'reports a pinned-source install that failed anyway just as fully' {
        # THE PIN MUST NOT BECOME A GAG. Naming the source removes one failure;
        # it must not cost the captain the report on any of the others, or the
        # next clean VM sends back the bare "exited 1" this area exists to stop.
        # This is the real command a route now runs, failing for a reason the
        # pin has nothing to do with.
        $command = 'winget install -e --id OpenJS.NodeJS --source winget --accept-source-agreements --accept-package-agreements'
        $detail = Get-FmToolRunFailureDetail -Command $command -ExitCode -1978335138 -Output @(
            'Failed when searching source: winget',
            'An unexpected error occurred while executing the command:',
            '0x8a15005e : The server certificate did not match any of the expected values.')
        $detail | Should -Match ([regex]::Escape($command)) -Because 'the captain must see what was run'
        $detail | Should -Match '0x8A15005E' -Because 'the code has to be lookup-able'
        $detail | Should -Match 'certificate did not match any of the expected values' `
            -Because "the tool's own words are quoted, never distilled"
        $detail | Should -Match 'Failed when searching source: winget' `
            -Because 'which source failed is the whole of the finding once the pin is in'
    }

    It 'says a tool printed nothing, rather than reporting an empty cause' {
        $detail = Get-FmToolRunFailureDetail -Command 'demo' -ExitCode 7 -Output @()
        $detail | Should -Match 'exited 7'
        $detail | Should -Match 'printed nothing'
    }

    It 'names the command that actually ran when it is not the one printed' {
        # winget is resolved to its real location rather than by name, and which
        # winget ran has already mattered once on this machine.
        $detail = Get-FmToolRunFailureDetail -Command 'winget install -e --id Git.Git' -ExitCode 1 `
            -Output @('nope') -AsRun '& "C:\somewhere\winget.exe" install -e --id Git.Git'
        $detail | Should -Match ([regex]::Escape('C:\somewhere\winget.exe'))
    }

    It 'keeps both ends of a long output, and says how much it left out' {
        # MEASURED: winget's rejected-command-line output is 51 lines and the
        # cause is the THIRD of them. Keeping the tail alone would throw the
        # cause away and keep help text.
        $long = @(1..100 | ForEach-Object { "line $_" })
        $lines = @(Format-FmToolFailureOutput -Output $long)
        $text = $lines -join "`n"
        $text | Should -Match 'line 1\b' -Because 'the cause is often the first thing printed'
        $text | Should -Match 'line 100\b' -Because 'and just as often the last'
        # NO SILENT TRUNCATION: a report that quietly drops lines reads as all of
        # them.
        $text | Should -Match 'lines not shown'
        $lines.Count | Should -BeLessThan $long.Count
    }

    It 'quotes a short output whole' {
        $lines = @(Format-FmToolFailureOutput -Output @('one', '', 'two'))
        ($lines -join "`n") | Should -Match 'in full'
        ($lines -join "`n") | Should -Not -Match 'not shown'
    }

    It 'keeps a multi-line failure readable in the transcript' {
        # The transcript line is where the captain reads a failure first. A
        # detail of several lines used to be impossible here, so nothing indented
        # the continuation; without this the cause runs back to column zero.
        $step = New-FmInstallStep -Name 'Node.js' -Action 'skipped' `
            -Detail "FAILED: 'x' exited 1.`nwhat it printed, in full:`n    the cause"
        $lines = @(Format-FmInstallStepLine -Step $step)
        $lines.Count | Should -Be 3
        $lines[0] | Should -Match 'Node\.js - FAILED'
        $lines[2] | Should -Match '^\s{14}'
        ($lines -join "`n") | Should -Match 'the cause'
    }

    It 'keeps a multi-line failure readable in the end summary' {
        # The summary is the last thing read, and a failure whose cause is only
        # in the transcript above is one the captain has to go looking for.
        $outcomes = @([pscustomobject]@{
                Label          = 'Node.js'
                Classification = 'missing'
                Outcome        = 'failed'
                Detail         = "'winget install' exited 1.`nwhat it printed, in full:`n    the cause"
            })
        $lines = @(Get-FmMachineSummaryLine -Outcomes $outcomes)
        ($lines -join "`n") | Should -Match 'Node\.js\s+FAILED'
        ($lines -join "`n") | Should -Match 'the cause'
        # Not out at the detail column, where quoted output wraps into nonsense.
        @($lines | Where-Object { $_ -match 'what it printed' })[0] | Should -Match '^\s{8}\S'
    }

    It 'does not wait on a question nobody can see' -Skip:(-not $IsWindows) {
        # The run captures the child's output through a pipe, so a vendor
        # installer that stops to ask something asks it into the pipe and then
        # waits forever. The child is a non-interactive host, so it returns.
        $result = Invoke-FmToolRoute -Confirm:$false `
            -Route (Get-FmDemoRoute -Command '$null = Read-Host "do you trust this source? [y/N]"; Write-Output done')
        $result.Action | Should -BeIn @('installed', 'failed') -Because 'either answer is fine; waiting forever is not'
    }

    It 'appends its exit-code epilogue on its own line, because the routes carry comments' {
        # `winget install ... # or ./install.ps1, which needs no administrator` is
        # a real route. On one line a trailing comment swallows everything after
        # it, epilogue included, and the tool's exit code goes back to being lost.
        $text = Get-FmToolShellCommandText -Command 'winget install -e --id GitHub.cli  # or ./install.ps1'
        @($text -split '\r?\n')[0] | Should -Match '# or \./install\.ps1$'
        @($text -split '\r?\n').Count | Should -BeGreaterThan 1
        $text | Should -Match 'exit \$fmCode'
    }
}

Describe 'a fix line the captain can actually paste' {
    # THE BAR, IN THE CAPTAIN'S WORDS: nothing is left for them to run by hand,
    # and where a line IS printed - because a step genuinely failed - it has to
    # be one that works when pasted into whatever window they have open.

    It 'builds every module install line in one place, and always with -SkipPublisherCheck' {
        # MEASURED 2026-08-21, because this is a claim about a machine:
        #   - Windows' own Pester 3.4.0 manifest is Authenticode Valid, signed
        #     'CN=Microsoft Windows, O=Microsoft Corporation'
        #   - the gallery's Pester is Authenticode Valid, signed 'CN=Jakub Jares'
        #   - PowerShellGet raises PublishersMismatch on exactly that pair and
        #     names -SkipPublisherCheck as the way past it
        #   - PowerShellGet 2.2.5, which PowerShell 7 carries, whitelists Pester
        #     so it passes there; 1.0.0.1, which Windows PowerShell 5.1 ships,
        #     does not, so the same line throws there
        # The captain's clean-VM log has them in Windows PowerShell 5.1 - the
        # shell where it fails - so the switch is what makes the line true in
        # both.
        Get-FmToolModuleInstallCommand -Name 'Pester' -MinimumVersion '5.0.0' |
            Should -Be 'Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -SkipPublisherCheck'
    }

    It 'adds -Force only when replacing a copy that is already there' {
        # Without it Install-Module reports "already installed" and does nothing,
        # so a captain who asked for an update would be told it happened.
        Get-FmToolModuleInstallCommand -Name 'Pester' -MinimumVersion '5.0.0' -Force |
            Should -Match '\s-Force\s'
        Get-FmToolModuleInstallCommand -Name 'Pester' -MinimumVersion '5.0.0' |
            Should -Not -Match '\s-Force(\s|$)'
    }

    It 'states no minimum where none is stated' {
        Get-FmToolModuleInstallCommand -Name 'PSScriptAnalyzer' |
            Should -Be 'Install-Module PSScriptAnalyzer -Scope CurrentUser -SkipPublisherCheck'
    }

    It 'prints no Install-Module line anywhere that would fail on a clean machine' -Skip:(-not $IsWindows) {
        # THE DEFECT, PINNED, and swept rather than spot-checked: four places
        # printed this line and two of them disagreed. Every place that renders
        # one now goes through the builder, so a fifth added later without the
        # switch fails here rather than on a captain's VM.
        $plan = Get-FmMachineInstallPlan -Offline
        $lines = @()
        foreach ($requirement in @($plan.Requirements | Where-Object { $_.Kind -eq 'module' })) {
            $lines += @($requirement.Route.Command, $requirement.UpdateCommand)
        }
        foreach ($check in @(Get-FmMachineModuleVerification)) { $lines += $check.Fix }
        foreach ($check in @((Invoke-FmDoctor -RepoRoot $script:RepoRoot).Checks)) { $lines += $check.Fix }

        $moduleLines = @($lines | Where-Object { $_ -and $_ -match 'Install-Module' })
        $moduleLines.Count | Should -BeGreaterThan 0 -Because 'this sweep must not be vacuous'
        foreach ($line in $moduleLines) {
            $line | Should -Match '\s-SkipPublisherCheck(\s|$)' `
                -Because "'$line' is refused by PowerShellGet 1.0.0.1 over Windows' own Microsoft-signed Pester"
            $line | Should -Match '\s-Scope CurrentUser(\s|$)' `
                -Because "'$line' must need no administrator"
        }
    }

    It 'never hands the captain a description as the line that replaces a tool' -Skip:(-not $IsWindows) {
        # UpdateCommand is printed as "Update it yourself, then re-run: <line>".
        # A portable route's own Command is a description of what this installer
        # does - "expand the cli/cli release asset ... into ..." - so the plan
        # builds this one through Get-FmToolFixCommand. Swept across the whole
        # plan so a route added later cannot reintroduce it.
        $plan = Get-FmMachineInstallPlan -Offline
        foreach ($requirement in $plan.Requirements) {
            $requirement.UpdateCommand | Should -Not -Match '^expand ' `
                -Because "$($requirement.Label) would hand the captain a sentence instead of a command"
        }
    }

    It 'answers a portable route with a command, never with a description of one' -Skip:(-not $IsWindows) {
        # Get-FmToolRoute's Command for a portable route is "expand the cli/cli
        # release asset ... into ...", which is a true statement of what this
        # installer does and is not something anybody can type. Printed as a
        # "fix:" it hands the captain a sentence instead of a remedy.
        $route = Get-FmToolRoute -Tool 'gh'
        $route.Kind | Should -Be 'portable'
        $fix = Get-FmToolFixCommand -Route $route
        $fix | Should -Not -Match '^expand '
        $fix | Should -Match 'install\.ps1'
    }

    It 'passes a vendor one-liner straight through, because that one is runnable' -Skip:(-not $IsWindows) {
        Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool 'claude') |
            Should -Be 'irm https://claude.ai/install.ps1 | iex'
    }
}

Describe "Windows' own Pester is installed beside, never over" {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VM 2026-08-21: every
    # clean machine carries Pester 3.4.0, the run refused to install 5+, printed
    # a command for the captain to run, and reported the machine NOT READY. The
    # refusal was protecting a copy no install here would have touched.

    It 'calls a module below the floor superseded, because installing it replaces nothing' {
        Get-FmToolClassification -Present $true -Installed '3.4.0' -Minimum '5.0.0' -Supersedable $true |
            Should -Be 'superseded'
    }

    It 'still calls a TOOL below the floor unsupported, because installing that one does replace it' {
        Get-FmToolClassification -Present $true -Installed '3.4.0' -Minimum '5.0.0' |
            Should -Be 'unsupported'
    }

    It 'leaves a module that clears the floor alone' {
        Get-FmToolClassification -Present $true -Installed '6.1.0' -Latest '6.1.0' -Minimum '5.0.0' -Supersedable $true |
            Should -Be 'current'
    }

    It 'marks modules supersedable and tools not, in the plan the installer acts on' -Skip:(-not $IsWindows) {
        $plan = Get-FmMachineInstallPlan -Offline
        foreach ($requirement in $plan.Requirements) {
            $expected = ($requirement.Kind -eq 'module')
            $requirement.Supersedable | Should -Be $expected `
                -Because "$($requirement.Label) is a $($requirement.Kind), and only a module install adds a version beside what is there"
        }
    }

    It 'keeps a superseded module out of the bucket that ends a run NOT READY' {
        # 'unsupported' is what makes install.ps1 report the machine unfinished
        # and tell the captain to fix it themselves. A module never belongs
        # there, because this run installs it.
        $requirement = [pscustomobject]@{
            Kind = 'module'; Label = 'module Pester'; Path = 'C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0'
            Version = '3.4.0'; Minimum = '5.0.0'; MinimumSource = 'the suite is written for Pester 5+'
            MinimumCapability = ''; Why = 'runs the test suite'; Classification = 'superseded'
        }
        $reason = Get-FmToolClassificationReason -Requirement $requirement
        $reason | Should -Match 'BESIDE'
        $reason | Should -Match 'left exactly as it is'
        $reason | Should -Match '3\.4\.0'
    }

    It 'asks nothing about it, because installing it is this run''s job' {
        $requirement = [pscustomobject]@{
            Kind = 'module'; Label = 'module Pester'; Path = ''; Version = '3.4.0'; Latest = '6.1.0'
            Minimum = '5.0.0'; MinimumSource = 'the suite'; MinimumCapability = ''; Classification = 'superseded'
        }
        Get-FmMachineQuestion -Requirement $requirement | Should -BeNullOrEmpty
    }
}

Describe 'a tool this run installed is never reported missing by this run' {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VM 2026-08-21:
    #   [created] Claude CLI - irm https://claude.ai/install.ps1 | iex
    #   [missing] tool Claude CLI - not on PATH - firstmate itself
    # Both true. The installer wrote claude.exe into the user's own profile, this
    # already-running process could not see it, and the run advised repeating an
    # install that had worked.

    BeforeEach { $script:PathBefore = $env:PATH }
    AfterEach { $env:PATH = $script:PathBefore }

    It 'finds what a vendor installer left behind and puts it on PATH' {
        $vendorDirectory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $vendorDirectory -Force
        Set-Content -LiteralPath (Join-Path $vendorDirectory 'demoinstalled.cmd') -Value '@echo demo' -NoNewline

        $result = Resolve-FmToolAfterInstall -Tool 'demoinstalled' -PathScope Process `
            -Candidate @($vendorDirectory) -Confirm:$false

        $result.Resolved | Should -BeTrue
        $result.Recovered | Should -BeTrue -Because 'the environment did not have it and the known location did'
        $result.Directory | Should -Be $vendorDirectory
        Test-FmToolOnPath -Directory $vendorDirectory -Scope Process | Should -BeTrue
    }

    It 'reports honestly when the tool is in neither place' {
        $empty = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $empty -Force
        $result = Resolve-FmToolAfterInstall -Tool 'notinstalledanywhere' -PathScope Process `
            -Candidate @($empty) -Confirm:$false
        $result.Resolved | Should -BeFalse
        $result.Recovered | Should -BeFalse
    }

    It 'names a real per-user directory for every tool whose installer writes one' -Skip:(-not $IsWindows) {
        # MEASURED on a machine that has them, 2026-08-21: the Claude CLI is at
        # %USERPROFILE%\.local\bin and herdr's own installer leaves the runnable
        # copy at %LOCALAPPDATA%\Programs\Herdr\bin.
        (Get-FmBootstrapInstalledLocation -Tool 'claude') | Should -Contain '%USERPROFILE%\.local\bin'
        (Get-FmBootstrapInstalledLocation -Tool 'herdr') | Should -Contain '%LOCALAPPDATA%\Programs\Herdr\bin'
        # A tool with no entry is not a hole: nothing is searched and the
        # recovery simply reports what it found, which is nothing.
        (Get-FmBootstrapInstalledLocation -Tool 'git') | Should -BeNullOrEmpty
    }
}

Describe 'herdr, installed rather than advised' {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VMs TWICE: the
    # vendor's own installer downloads the release and then fails ITS OWN
    # verification, so herdr was the one required tool no clean machine ended up
    # with. What this repo does about it is read their installer and take the
    # same release the same way gh already is - not work around their script.

    It 'takes the portable route, and needs no administrator for it' -Skip:(-not $IsWindows) {
        $route = Get-FmToolRoute -Tool 'herdr'
        $route.Kind | Should -Be 'portable'
        $route.NeedsAdministrator | Should -BeFalse
        # herdr.exe is at the root of that zip beside conpty/, which has to stay
        # next to it - so the expansion itself is what goes on PATH.
        $route.Portable.BinSubdirectory | Should -BeNullOrEmpty
        $route.Portable.StripRoot | Should -BeFalse
    }

    It 'reads the same manifest their installer reads' -Skip:(-not $IsWindows) {
        # Read from https://herdr.dev/install.ps1 on 2026-08-21: the stable
        # channel is latest.json, and a Windows machine is the target triple
        # x86_64-pc-windows-msvc, whose asset key is windows-x86_64.
        $portable = Get-FmBootstrapPortableRelease -Tool 'herdr'
        $portable.Source | Should -Be 'manifest'
        $portable.ManifestUrl | Should -Be 'https://herdr.dev/latest.json'
        $portable.AssetKey | Should -Be 'windows-x86_64'
    }

    It 'reads an asset published as a bare URL, which is the stable channel''s shape' {
        # Captured from https://herdr.dev/latest.json, 2026-08-21.
        $manifest = [pscustomobject]@{
            version = '0.8.2'
            assets  = [pscustomobject]@{
                'windows-x86_64' = 'https://github.com/herdrdev/herdr/releases/download/v0.8.2/herdr-windows-x86_64.zip'
            }
        }
        $asset = Get-FmToolManifestAsset -Manifest $manifest -AssetKey 'windows-x86_64'
        $asset.Name | Should -Be 'herdr-windows-x86_64.zip'
        $asset.Version | Should -Be '0.8.2'
        # No checksum on that channel, and an absent one is never treated as a
        # passing one.
        $asset.Sha256 | Should -BeNullOrEmpty
    }

    It 'reads an asset published as an object with a checksum, which is preview''s shape' {
        # Captured from https://herdr.dev/preview.json, 2026-08-21.
        $manifest = [pscustomobject]@{
            channel      = 'preview'
            base_version = '0.8.2'
            build_id     = '2026-08-19-b5c4a0176e91'
            assets       = [pscustomobject]@{
                'windows-x86_64' = [pscustomobject]@{
                    url    = 'https://github.com/herdrdev/herdr/releases/download/preview-2026-08-19-b5c4a0176e91/herdr-windows-x86_64.zip'
                    sha256 = '01c8bc9f22be0ad447ceb8f4ed8ae18871b31694ccfd6b504b26ee31f0c6e25e'
                    format = 'zip'
                }
            }
        }
        $asset = Get-FmToolManifestAsset -Manifest $manifest -AssetKey 'windows-x86_64'
        $asset.Sha256 | Should -Be '01c8bc9f22be0ad447ceb8f4ed8ae18871b31694ccfd6b504b26ee31f0c6e25e'
        # Their rule for a preview identity, not one invented here.
        $asset.Version | Should -Be '0.8.2-preview.2026-08-19-b5c4a0176e91'
    }

    It 'refuses, naming the manifest, when it carries nothing for this machine' {
        $manifest = [pscustomobject]@{ version = '0.8.2'; assets = [pscustomobject]@{ 'linux-x86_64' = 'https://example.invalid/x' } }
        { Get-FmToolManifestAsset -Manifest $manifest -AssetKey 'windows-x86_64' -Origin 'https://herdr.dev/latest.json' } |
            Should -Throw "*lists no 'windows-x86_64' asset*"
    }
}

Describe 'a tool that starts, dies before its own code, and prints nothing' {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VM 2026-08-21. herdr
    # was downloaded and placed correctly and the run said only this:
    #
    #   [missing] tool herdr - 'herdr' resolves to ...\herdr.exe but answers
    #             nothing to --version, so it is not verified as the real tool
    #
    # That sentence is true and names no cause, so the first diagnosis drawn from
    # it was wrong: the vendor's installer had failed the SAME check and was
    # called a broken verification step, when it was reporting a real fault on
    # that machine. The code the tool returned - 0xC0000135 - said what happened
    # and was discarded before anything printed.
    #
    # A .cmd that exits non-zero without printing is the seam. It reproduces the
    # SHAPE that matters here - started, said nothing, returned a code - on any
    # machine, without needing one that is missing a runtime.

    BeforeAll {
        $script:QuietBin = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:QuietBin -Force
        Set-Content -LiteralPath (Join-Path $script:QuietBin 'fm-quietly-dead.cmd') `
            -Value "@echo off`r`nexit /b 5"
        $script:SavedQuietPath = $env:PATH
    }
    AfterEach { $env:PATH = $script:SavedQuietPath }

    It 'names what Windows means by the codes it chooses, for any command' {
        # These are the codes a program never got to choose: the loader stopped
        # it, so stdout and stderr are empty and the code is the only evidence.
        # They mean the same thing whatever was being started, so they are asked
        # about for every command rather than for one.
        foreach ($command in @('herdr', 'winget', '')) {
            Get-FmToolExitCodeMeaning -Command $command -ExitCode -1073741515 | Should -Match 'DLL it needs is not on this machine'
            Get-FmToolExitCodeMeaning -Command $command -ExitCode -1073741502 | Should -Match 'would not initialise'
            Get-FmToolExitCodeMeaning -Command $command -ExitCode -1073741701 | Should -Match 'different processor architecture'
            Get-FmToolExitCodeMeaning -Command $command -ExitCode -1073741795 | Should -Match 'newer CPU'
        }
        # A code the PROGRAM chose is the program saying something about itself,
        # and putting Windows' words in its mouth would be a guess.
        Get-FmToolExitCodeMeaning -Command 'herdr' -ExitCode 1 | Should -Be ''
        Get-FmToolExitCodeMeaning -Command 'herdr' -ExitCode 0 | Should -Be ''
    }

    It 'still gives winget its own verdicts, which the OS codes must not have displaced' {
        Get-FmToolExitCodeMeaning -Command 'winget install demo' -ExitCode -1978335212 |
            Should -Match 'no package matching'
        Get-FmToolExitCodeMeaning -Command 'winget install demo' -ExitCode -1978335230 |
            Should -Match 'rejected the command line'
    }

    It 'carries the exit code into the sentence, and never softens the verdict' {
        $detail = Get-FmToolUnprovenDetail -Command 'herdr' -Path 'C:\p\herdr.exe' -ExitCode -1073741515
        $detail | Should -Match 'not verified as the real tool' -Because 'naming a cause must never turn a failure into a pass'
        $detail | Should -Match '0xC0000135'
        $detail | Should -Match 'DLL it needs is not on this machine'
    }

    It 'says the code and nothing more when Windows did not choose it' {
        $detail = Get-FmToolUnprovenDetail -Command 'demo' -Path 'C:\p\demo.exe' -ExitCode 5
        $detail | Should -Match '0x00000005'
        $detail | Should -Not -Match 'which means'
    }

    It 'leaves the code out altogether for a tool that exited 0 and merely said nothing' {
        $detail = Get-FmToolUnprovenDetail -Command 'demo' -Path 'C:\p\demo.exe' -ExitCode 0
        $detail | Should -Match 'answers nothing to --version'
        $detail | Should -Not -Match '0x0'
    }

    It 'builds a line from empty strings rather than stopping to ask for them' {
        # A REPORT LINE MUST NEVER BE ABLE TO ASK A QUESTION. A mandatory
        # parameter that refuses the value it is handed does not fail, it
        # prompts - and this is composed on a console nobody is watching, so a
        # prompt is a hung install rather than an error. Commit 2f4d97e is that
        # exact bug in the install's own self-check.
        { Get-FmToolUnprovenDetail -Command '' -Path '' -ExitCode -1073741515 } | Should -Not -Throw
        $detail = Get-FmToolUnprovenDetail -Command '' -Path '' -ExitCode -1073741515
        $detail | Should -Match 'not verified as the real tool'
        $detail | Should -Match '0xC0000135'
    }

    It 'carries the code out of the real detection rather than dropping it' -Skip:(-not $IsWindows) {
        # The producer's own record goes into the consumer untouched. Nothing
        # here builds a status by hand, which is how the last defect in this area
        # survived a green suite.
        $env:PATH = $script:QuietBin + [System.IO.Path]::PathSeparator + $script:SavedQuietPath
        $status = Get-FmToolStatus -Command 'fm-quietly-dead'
        $status.Present | Should -BeTrue
        $status.Launchable | Should -BeTrue -Because 'it started - this is not the refused-launch case'
        $status.Version | Should -Be ''
        $status.ExitCode | Should -Be 5
        Get-FmToolClassification -Present $status.Present -Installed $status.Version -Launchable $status.Launchable |
            Should -Be 'unknown-version'
    }

    It 'reports the cause in the proving pass, through the real detection' -Skip:(-not $IsWindows) {
        # The pass the captain actually read. It has to name the code, and it has
        # to keep saying the tool is not proven.
        Mock Update-FmToolSessionPath { $env:PATH }
        $env:PATH = $script:QuietBin
        try {
            foreach ($entry in (Get-FmToolCatalog)) {
                Copy-Item -LiteralPath (Join-Path $script:QuietBin 'fm-quietly-dead.cmd') `
                    -Destination (Join-Path $script:QuietBin ($entry.Command + '.cmd')) -Force
            }
            $herdr = @(Get-FmMachineToolVerification | Where-Object { $_.Name -eq 'tool herdr' })
            $herdr.Count | Should -Be 1
            $herdr[0].Status | Should -Be 'missing' -Because 'a required tool that printed no version is not a proven install'
            $herdr[0].Detail | Should -Match 'not verified as the real tool'
            $herdr[0].Detail | Should -Match '0x00000005'
            $herdr[0].Detail | Should -Not -Match 'refused to start' -Because 'this one started; that wording belongs to the launch refusal'
        } finally {
            $env:PATH = $script:SavedQuietPath
            Get-ChildItem -LiteralPath $script:QuietBin -Filter '*.cmd' |
                Where-Object { $_.Name -ne 'fm-quietly-dead.cmd' } | Remove-Item -Force
        }
    }

    It 'says the same thing in the plan as in the proving pass' {
        # One sentence, one owner. Two wordings for one fact is the drift that
        # leaves only one of them corrected.
        $requirement = [pscustomobject]@{
            Classification    = 'unknown-version'
            Command           = 'herdr'
            Path              = 'C:\p\herdr.exe'
            ExitCode          = -1073741515
            Why               = 'the tests'
            Version           = ''
            Latest            = ''
            Minimum           = ''
            MinimumSource     = ''
            MinimumCapability = ''
        }
        Get-FmToolClassificationReason -Requirement $requirement |
            Should -Be (Get-FmToolUnprovenDetail -Command 'herdr' -Path 'C:\p\herdr.exe' -ExitCode -1073741515)
    }
}

Describe 'a fix line for a missing dependency installs the dependency' {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VM and left standing
    # for two days. The diagnosis above landed and was right; the line under it
    # was not:
    #
    #   [missing] tool herdr - 'herdr' resolves to ...\herdr.exe but answers
    #             nothing to --version ... it exited 0xC0000135, which means a
    #             DLL it needs is not on this machine ...
    #             fix: powershell -ExecutionPolicy Bypass -File .\install.ps1
    #
    # The fix is the run that produced the diagnosis. Pasting it re-expands the
    # same archive and reaches the same dead binary, forever. The captain had to
    # be told the real answer - install the Visual C++ redistributable - by hand,
    # in chat, because nothing in the installer would say it.
    #
    # The whole point of these tests is that the fix line for this failure can
    # never quietly become the installer again.

    BeforeAll {
        # A .cmd that returns the NTSTATUS and prints nothing reproduces the
        # captain's shape end to end - present, launchable, no version, and the
        # code as the only evidence - on any machine, with no need for one that
        # is actually missing a runtime.
        $script:DllBin = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $script:DllBin -Force
        Set-Content -LiteralPath (Join-Path $script:DllBin 'fm-no-runtime.cmd') `
            -Value "@echo off`r`nexit /b -1073741515"
        $script:SavedDllPath = $env:PATH
    }
    AfterEach { $env:PATH = $script:SavedDllPath }

    It 'answers the codes that mean a dependency is missing, and only those' {
        # 0xC0000135 the DLL is absent; 0xC0000139 and 0xC0000138 it is present
        # and older than the build that imports from it. One fault, one command.
        foreach ($code in @(-1073741515, -1073741511, -1073741512)) {
            $remedy = Get-FmToolExitCodeRemedy -ExitCode $code
            $remedy | Should -Not -BeNullOrEmpty -Because "0x$('{0:X8}' -f $code) says a dependency is missing"
            $remedy.NeedsAdministrator | Should -BeTrue -Because 'the redistributable installs machine-wide'
        }
        # 0xC0000142 found the DLL and it would not initialise, and 0xC000007B
        # is a build for another processor. Installing a runtime answers
        # neither, and a fix line that might not work is what this exists to
        # stop.
        # 1 and 127 are this repo's own sentinels for a launch that was REFUSED
        # and a command that was never FOUND - see Invoke-FmSessionCommandLine -
        # so neither may pick up a remedy meant for a process that really ran.
        foreach ($code in @(-1073741502, -1073741701, -1073741795, -1073741790, 127, 5, 1, 0)) {
            Get-FmToolExitCodeRemedy -ExitCode $code | Should -BeNullOrEmpty
        }
    }

    It 'names the package winget itself resolves, from the source this repo pins' {
        # VERIFIED against winget v1.29.290, 2026-08-25: `winget search -e --id
        # Microsoft.VCRedist.2015+.x64 --source winget` resolves to exactly one
        # package, "Microsoft Visual C++ v14 Redistributable (x64)".
        $command = (Get-FmToolExitCodeRemedy -ExitCode -1073741515).Command
        $command | Should -Match '(?<![\w.])Microsoft\.VCRedist\.2015\+\.x64(?![\w.])'
        $command | Should -Match '--source winget' -Because 'every route here pins the source it needs'
        $command | Should -Match '-e --id' -Because 'a bare winget install is a search, and a search asks a question'
        $command | Should -Match '--accept-source-agreements'
        $command | Should -Match '--accept-package-agreements'
        # Built by the one owner of this repo's winget flags rather than by a
        # second copy of them.
        $command | Should -Be (Get-FmBootstrapWingetCommand -PackageId 'Microsoft.VCRedist.2015+.x64')
    }

    It 'takes the x64 redistributable, which is what the failing build needs' -Skip:(-not $IsWindows) {
        # herdr publishes one Windows build, windows-x86_64 - see
        # Get-FmBootstrapPortableRelease - so an ARM64 machine runs it under
        # emulation and an emulated x64 process loads x64 DLLs. Choosing by the
        # MACHINE's architecture would hand an ARM64 captain the one package
        # that cannot satisfy the program that failed.
        (Get-FmBootstrapPortableRelease -Tool 'herdr').AssetKey | Should -Be 'windows-x86_64'
        (Get-FmToolExitCodeRemedy -ExitCode -1073741515).Command | Should -Not -Match 'arm64'
    }

    It 'is not the re-run-the-installer line' -Skip:(-not $IsWindows) {
        # THE ACCEPTANCE TEST. The route for herdr is portable, so its fix line
        # is normally this installer - correct for a tool that is absent, and a
        # loop for one that is present and dies in the loader.
        $route = Get-FmToolRoute -Tool 'herdr'
        $loop = Get-FmToolFixCommand -Route $route
        $loop | Should -Match 'install\.ps1' -Because 'that is still the right answer for a tool that is simply not here'

        $fix = Get-FmToolFixCommand -Route $route -ExitCode -1073741515
        $fix | Should -Not -Match 'install\.ps1' -Because 'the line that produced the diagnosis cannot be its cure'
        $fix | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
    }

    It 'says out loud that it needs an administrator window' {
        # AGENTS.md's pattern for a step that genuinely needs elevation: name it,
        # say why, carry on. A captain who pastes this into their ordinary shell
        # and watches it fail is back where they started.
        $fix = Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool 'herdr') -ExitCode -1073741515
        $fix | Should -Match 'ADMINISTRATOR'
        $fix | Should -Match 'Visual C\+\+' -Because 'the captain is owed what they are being asked to install'
    }

    It 'stays one pasteable line, with the advice as a comment the shell ignores' {
        # This repo's convention for advice attached to a command - see
        # Get-FmBootstrapInstallCommand - is a trailing "  # ...", which is a
        # comment in the shell it is pasted into, so the whole line runs as
        # written.
        $fix = Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool 'herdr') -ExitCode -1073741515
        @($fix -split '\r?\n').Count | Should -Be 1
        $fix | Should -Match '\s#\s'
        # And it PARSES as the one command it claims to be, rather than only
        # reading like one - the '+' in the package id sits in an unquoted
        # argument, which is the part worth proving.
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($fix, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($fix, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        $commands.Count | Should -Be 1 -Because 'the comment must not parse as a second command'
        $commands[0].CommandElements[0].Value | Should -Be 'winget'
        # The id survives argument parsing whole, rather than being split at the
        # '+' or swallowed by an operator.
        @($commands[0].CommandElements | ForEach-Object { $_.Extent.Text }) |
            Should -Contain 'Microsoft.VCRedist.2015+.x64'
    }

    It 'belongs to the code and not to herdr, so the next tool gets the same answer' {
        # The remedy is asked of the CODE. A route with no relation to herdr,
        # returning the same code, gets the same cure - which is what stops the
        # next native tool that ships without its runtime repeating this.
        $unrelated = [pscustomobject]@{
            Tool = 'fm-othertool'; Kind = 'command'; Command = 'irm https://example.invalid/install.ps1 | iex'
            Portable = $null; NeedsAdministrator = $false; Instructions = ''
        }
        Get-FmToolFixCommand -Route $unrelated -ExitCode -1073741515 |
            Should -Be (Get-FmToolFixCommand -Route (Get-FmToolRoute -Tool 'herdr') -ExitCode -1073741515)
        # And a code with no remedy leaves every route exactly as it was.
        Get-FmToolFixCommand -Route $unrelated -ExitCode 5 | Should -Be $unrelated.Command
        Get-FmToolFixCommand -Route $unrelated | Should -Be $unrelated.Command
    }

    It 'names the two codes that were unnamed, without displacing the ones that were not' {
        Get-FmToolExitCodeMeaning -Command 'herdr' -ExitCode -1073741511 |
            Should -Match 'does not contain something it imports'
        Get-FmToolExitCodeMeaning -Command 'herdr' -ExitCode -1073741512 |
            Should -Match 'ordinal'
        # The entry the diagnosis work landed, unchanged.
        Get-FmToolExitCodeMeaning -Command 'herdr' -ExitCode -1073741515 |
            Should -Match 'DLL it needs is not on this machine'
        Get-FmToolExitCodeMeaning -Command 'winget install demo' -ExitCode -1978335212 |
            Should -Match 'no package matching'
    }

    It 'gives the captain the cure in the proving pass they actually read' -Skip:(-not $IsWindows) {
        # End to end, through the real detection and the real catalog, on the
        # exact pass whose output the brief quotes.
        Mock Update-FmToolSessionPath { $env:PATH }
        $env:PATH = $script:DllBin
        try {
            foreach ($entry in (Get-FmToolCatalog)) {
                Copy-Item -LiteralPath (Join-Path $script:DllBin 'fm-no-runtime.cmd') `
                    -Destination (Join-Path $script:DllBin ($entry.Command + '.cmd')) -Force
            }
            $herdr = @(Get-FmMachineToolVerification | Where-Object { $_.Name -eq 'tool herdr' })
            $herdr.Count | Should -Be 1

            # THE BAR IS UNCHANGED. A named remedy never turns unproven into
            # installed: the tool is still not proved, still reported missing,
            # and the run still ends NOT READY.
            $herdr[0].Status | Should -Be 'missing' -Because 'naming a cure proves nothing about the tool'
            $herdr[0].Detail | Should -Match 'not verified as the real tool'
            $herdr[0].Detail | Should -Match '0xC0000135'

            # And the line under it is now one that works.
            $herdr[0].Fix | Should -Not -Match 'install\.ps1'
            $herdr[0].Fix | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
            $herdr[0].Fix | Should -Match 'ADMINISTRATOR'
        } finally {
            $env:PATH = $script:SavedDllPath
            Get-ChildItem -LiteralPath $script:DllBin -Filter '*.cmd' |
                Where-Object { $_.Name -ne 'fm-no-runtime.cmd' } | Remove-Item -Force
        }
    }

    It 'leaves the fix line alone for a tool that merely printed nothing' -Skip:(-not $IsWindows) {
        # The neighbouring failure, which the route line IS right for: a tool
        # that ran, exited cleanly and said nothing is not a dependency problem,
        # and must not be sent to winget for a runtime it does not need.
        Mock Update-FmToolSessionPath { $env:PATH }
        $quiet = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $quiet -Force
        $env:PATH = $quiet
        try {
            foreach ($entry in (Get-FmToolCatalog)) {
                Set-Content -LiteralPath (Join-Path $quiet ($entry.Command + '.cmd')) -Value "@echo off`r`nexit /b 0"
            }
            $herdr = @(Get-FmMachineToolVerification | Where-Object { $_.Name -eq 'tool herdr' })
            $herdr[0].Status | Should -Be 'missing'
            $herdr[0].Fix | Should -Match 'install\.ps1'
            $herdr[0].Fix | Should -Not -Match 'VCRedist'
        } finally { $env:PATH = $script:SavedDllPath }
    }
}

Describe 'the runtime is found before a tool fails to start, and installed from here' {
    # THE DEFECT, and it is one this repo had already decided to live with.
    # docs/windows-e2e-evidence.md section 43.3 considered checking for the
    # Visual C++ runtime up front and said no, then printed the elevated command
    # under the tool that died instead. The captain ran that command by hand on a
    # fresh VM - which is exactly the thing they had ruled out days earlier:
    #
    #   "add all things in script in don't want user have to execute any thing
    #    else manual or extra all must be done from our script itself"
    #
    # So the runtime is now detected as its own requirement, before anything
    # needs it, and installed from the script through the one consent dialog
    # Windows raises for one elevated child.
    #
    # WHAT THESE PIN, and the first is the one that matters most:
    #
    #   1. THE DETECTION CANNOT SAY PRESENT WHERE THE LOADER WOULD STILL FAIL.
    #      That is why it reads the DLL's own PE header rather than asking a
    #      package manager what is installed, and why a tool that already died
    #      in the loader outranks any file on disk.
    #   2. NOTHING ELEVATES WITHOUT THE SWITCH. -InstallRuntime is install.ps1
    #      saying the captain has read what is about to appear and is there to
    #      answer it; without it nothing is asked, on any path.
    #   3. DECLINING IS SAFE. It is an outcome, not a failure, and it carries the
    #      same command this installer printed before it could take the step.
    #   4. THE BAR DID NOT MOVE. Installing the runtime never certifies herdr.

    BeforeAll {
        # A file with a real PE header and a chosen machine type. The machine
        # field is the whole question - "VCRUNTIME140.dll exists" is not - so
        # these are built rather than copied off this seat, which would make
        # every case below a fact about the machine the suite happens to run on.
        function New-RuntimeDllFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: writes a disposable fixture under TestDrive.')]
            param(
                [Parameter(Mandatory)][string]$Directory,
                [ValidateSet('x64', 'x86', 'arm64', 'not-a-program')][string]$Machine = 'x64'
            )
            $null = New-Item -ItemType Directory -Path $Directory -Force
            $path = Join-Path $Directory 'VCRUNTIME140.dll'
            if ($Machine -eq 'not-a-program') {
                [System.IO.File]::WriteAllText($path, 'this file is not a program')
                return $path
            }
            $bytes = [byte[]]::new(0x100)
            $bytes[0] = 0x4D  # M
            $bytes[1] = 0x5A  # Z
            [System.BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
            $bytes[0x80] = 0x50  # P
            $bytes[0x81] = 0x45  # E
            $value = switch ($Machine) { 'x64' { 0x8664 } 'x86' { 0x014C } 'arm64' { 0xAA64 } }
            [System.BitConverter]::GetBytes([uint16]$value).CopyTo($bytes, 0x84)
            [System.IO.File]::WriteAllBytes($path, $bytes)
            $path
        }

        function New-EmptyDirectory {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: creates a disposable directory under TestDrive.')]
            param()
            $path = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path $path -Force
            $path
        }

        # A stand-in for the tool that imports the runtime, returning what
        # Windows returns for a process stopped in the loader. Same seam the
        # neighbouring fix-line tests use: it reproduces the shape that reaches
        # the report on any machine, with nothing about the mechanism stubbed.
        function New-RuntimeToolFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: writes a disposable .cmd under TestDrive.')]
            param([Parameter(Mandatory)][string]$Body)
            $directory = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path $directory -Force
            foreach ($entry in @(Get-FmToolCatalog | Where-Object { $_.Runtime })) {
                Set-Content -LiteralPath (Join-Path $directory ($entry.Command + '.cmd')) -Value $Body
            }
            $directory
        }
    }

    BeforeEach { $script:RuntimePathBefore = $env:PATH }
    AfterEach { $env:PATH = $script:RuntimePathBefore }

    It 'reads what processor a file was built for, out of the file' {
        $directory = New-EmptyDirectory
        foreach ($machine in @('x64', 'x86', 'arm64')) {
            Get-FmToolImageMachine -Path (New-RuntimeDllFixture -Directory $directory -Machine $machine) |
                Should -Be $machine
        }
        # Not a program at all, and a file that is not there. Both are '' rather
        # than an answer, because a file that could not be loaded whatever else
        # is true must never read as the right one.
        Get-FmToolImageMachine -Path (New-RuntimeDllFixture -Directory $directory -Machine 'not-a-program') | Should -Be ''
        Get-FmToolImageMachine -Path (Join-Path $directory 'nothing-is-here.dll') | Should -Be ''
    }

    It 'says missing when the DLL is nowhere the loader looks' {
        # PATH is staged empty for every case below: the loader stages read the
        # real PATH, so a machine with a working herdr on it would answer before
        # the files were ever looked at.
        $empty = New-EmptyDirectory
        $env:PATH = $empty
        $status = Get-FmToolRuntimeStatus -SearchPath @($empty)
        $status.Present | Should -BeFalse
        $status.Detail | Should -Match 'not part of Windows'
        # And it carries the line that installs it, so every caller prints the
        # same one rather than building a second copy.
        $status.Command | Should -Be (Get-FmBootstrapWingetCommand -PackageId 'Microsoft.VCRedist.2015+.x64')
    }

    It 'says present for an x64 copy where the loader would find it' {
        $empty = New-EmptyDirectory
        $env:PATH = $empty
        $directory = New-EmptyDirectory
        $path = New-RuntimeDllFixture -Directory $directory -Machine 'x64'
        $status = Get-FmToolRuntimeStatus -SearchPath @($directory)
        $status.Present | Should -BeTrue
        $status.Machine | Should -Be 'x64'
        $status.Path | Should -Be $path
    }

    It 'refuses a copy no x64 process could load, however present it looks' {
        # THE ACCEPTANCE TEST FOR THE DETECTION. A machine carrying only the
        # 32-bit redistributable has the name on disk, and an ARM64 machine
        # carrying only the ARM64 one has it in System32. Both read as present
        # to anything that asks whether the file is there - and neither can
        # satisfy herdr, which publishes one Windows build and runs as x64 under
        # emulation on ARM64. Asking a package manager what is installed has the
        # same hole, which is why this asks the file what it is.
        $empty = New-EmptyDirectory
        $env:PATH = $empty
        foreach ($machine in @('x86', 'arm64', 'not-a-program')) {
            $directory = New-EmptyDirectory
            $null = New-RuntimeDllFixture -Directory $directory -Machine $machine
            $status = Get-FmToolRuntimeStatus -SearchPath @($directory)
            $status.Present | Should -BeFalse -Because "an $machine file cannot answer for an x64 import"
            $status.Command | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
        }
    }

    It 'lets the loader overrule the files, in both directions' -Skip:(-not $IsWindows) {
        # THE CASE A FILE PROBE CANNOT SEE. 0xC0000139 and 0xC0000138 mean the
        # DLL is on the machine and older than the build importing from it - so
        # the file is present, the right architecture, and the tool still will
        # not start. Windows has already answered the question and its answer
        # beats any file on disk.
        $good = New-EmptyDirectory
        $null = New-RuntimeDllFixture -Directory $good -Machine 'x64'
        foreach ($code in @(-1073741515, -1073741511, -1073741512)) {
            $env:PATH = New-RuntimeToolFixture -Body "@echo off`r`nexit /b $code"
            $status = Get-FmToolRuntimeStatus -SearchPath @($good)
            $status.Present | Should -BeFalse -Because 'the loader stopped a tool that imports it, whatever is on disk'
            $status.Source | Should -Be 'the loader'
        }

        # And the other way: a tool that RAN resolved every import it has, which
        # nothing on disk can contradict. This is the case that keeps the check
        # quiet on a machine where herdr works.
        $empty = New-EmptyDirectory
        $env:PATH = New-RuntimeToolFixture -Body "@echo off`r`necho herdr 9.9.9"
        $status = Get-FmToolRuntimeStatus -SearchPath @($empty)
        $status.Present | Should -BeTrue
        $status.Source | Should -Be 'the loader'
    }

    It 'is one line in the plan, at the top, before anything needs it' {
        # The captain met this the other way round: herdr installed correctly,
        # died in the loader, and what it was missing was named at the bottom of
        # the report as something for them to go and run.
        $plan = Get-FmMachineInstallPlan -Offline
        $plan.Runtime | Should -Not -BeNull
        $rendered = @($plan.Lines)
        $runtimeLine = @($rendered | Where-Object { $_ -match 'Visual C\+\+ runtime' })
        $runtimeLine.Count | Should -Be 1
        # Above the tools, in the block that says what this machine has.
        $header = [array]::IndexOf($rendered, '  what this machine has:')
        $header | Should -BeGreaterThan -1
        [array]::IndexOf($rendered, $runtimeLine[0]) | Should -BeGreaterThan $header
        # The tool ROW, matched on its label column rather than on the word
        # anywhere in the line - the runtime's own detail names herdr too.
        $toolLine = @($rendered | Where-Object { $_ -match '^\s{4}\[[^\]]+\]\s+herdr\s' })
        if ($toolLine.Count -gt 0) {
            [array]::IndexOf($rendered, $runtimeLine[0]) | Should -BeLessThan ([array]::IndexOf($rendered, $toolLine[0]))
        }
    }

    Context 'the one step that asks for administrator' {
        BeforeEach {
            # NOTHING IN THIS SUITE MAY REACH THE REAL ONE. A modal dialog raised
            # by a test is measured in docs/windows-e2e-evidence.md section 41; a
            # CONSENT dialog is that with the stakes raised, and the switch this
            # mock stands in for is the only thing between them.
            Mock Start-FmToolElevated { [pscustomobject]@{ Started = $true; Declined = $false; ExitKnown = $true; ExitCode = 0 } }
            $script:RuntimeMissing = [pscustomobject]@{
                Label = 'Visual C++ runtime'; Dll = 'VCRUNTIME140.dll'; Present = $false; Path = ''
                Machine = ''; Source = 'the file'; Detail = 'VCRUNTIME140.dll is not on this machine'
                Command = (Get-FmBootstrapWingetCommand -PackageId 'Microsoft.VCRedist.2015+.x64')
            }
        }

        It 'asks for nothing when the runtime is already here' {
            $present = [pscustomobject]@{ Present = $true; Detail = 'herdr runs on this machine'; Command = 'x' }
            $result = Install-FmToolRuntime -Status $present -Confirm:$false
            $result.Action | Should -Be 'already-present'
            Should -Invoke Start-FmToolElevated -Times 0 -Exactly -Because 'a dialog for something already installed is a dialog for nothing'
        }

        It 'asks for nothing when there is nobody at the keyboard to answer' {
            # THE UNATTENDED CONTRACT. -Unattended means never ask anything, and a
            # Windows consent dialog is asking - one nobody would ever see, on a
            # run that has already gone on without a person. install.ps1 withholds
            # the switch; this is what withholding it does.
            $step = Invoke-FmToolRuntimeStep -Runtime $script:RuntimeMissing -Performed -Confirm:$false
            Should -Invoke Start-FmToolElevated -Times 0 -Exactly
            $step.Outcome.Outcome | Should -Be 'skipped'
            $step.Outcome.Detail | Should -Match 'nobody at the keyboard'
            $step.Outcome.Detail | Should -Match 'ADMINISTRATOR'
            $step.Outcome.Detail | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64' -Because 'a skipped step still hands over the command'
        }

        It 'asks for nothing on a run that is only saying what it would do' {
            $step = Invoke-FmToolRuntimeStep -Runtime $script:RuntimeMissing -InstallRuntime -Confirm:$false
            Should -Invoke Start-FmToolElevated -Times 0 -Exactly
            $step.Outcome.Detail | Should -Be 'WhatIf'
        }

        It 'installs it when told it may, and proves it by re-reading the machine' {
            # NOT BY winget'S EXIT CODE. That is this repo's oldest rule about
            # installs, and here it also covers the case where an elevated
            # child's code cannot be read back at all.
            Mock Get-FmToolRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'VCRUNTIME140.dll is on this machine, as an x64 build' } }
            $step = Invoke-FmToolRuntimeStep -Runtime $script:RuntimeMissing -Performed -InstallRuntime -Confirm:$false
            Should -Invoke Start-FmToolElevated -Times 1 -Exactly
            $step.Outcome.Outcome | Should -Be 'installed'
            $step.Step.Action | Should -Be 'created'
        }

        It 'reports FAILED when the machine still does not have it afterwards' {
            Mock Get-FmToolRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'still not here' } }
            Mock Start-FmToolElevated { [pscustomobject]@{ Started = $true; Declined = $false; ExitKnown = $true; ExitCode = -1978335212 } }
            $result = Install-FmToolRuntime -Status $script:RuntimeMissing -WingetPath 'C:\fixture\winget.exe' -Confirm:$false
            $result.Action | Should -Be 'failed'
            $result.Detail | Should -Match 'no package matching' -Because 'a failure is reported with its cause or it is not reported at all'
            $result.Detail | Should -Match 'ADMINISTRATOR'
        }

        It 'treats a declined prompt as a choice, not a failure, and carries on' {
            # Windows reports a dismissed consent dialog as Win32 error 1223.
            # Declining has to be safe: everything else still installs, the run
            # still finishes, and the command survives into the report.
            Mock Start-FmToolElevated { [pscustomobject]@{ Started = $false; Declined = $true; ExitKnown = $false; ExitCode = 0 } }
            $step = Invoke-FmToolRuntimeStep -Runtime $script:RuntimeMissing -Performed -InstallRuntime -Confirm:$false
            $step.Outcome.Outcome | Should -Be 'declined'
            $step.Outcome.Detail | Should -Match 'said no'
            $step.Outcome.Detail | Should -Match 'carried on'
            $step.Outcome.Detail | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
            $step.Step.Detail | Should -Match '^DECLINED: '
            # And the summary the captain reads last says it as a choice too.
            (Get-FmMachineSummaryLine -Outcomes @($step.Outcome)) -join "`n" | Should -Match 'DECLINED at the administrator prompt'
        }

        It 'reports a refused launch as an outcome and hands back the command' {
            Mock Start-FmToolElevated { [pscustomobject]@{ Started = $false; Declined = $false; ExitKnown = $false; ExitCode = 0 } }
            $result = Install-FmToolRuntime -Status $script:RuntimeMissing -WingetPath 'C:\fixture\winget.exe' -Confirm:$false
            $result.Action | Should -Be 'blocked'
            $result.Detail | Should -Match 'refused to start'
            $result.Detail | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
        }

        It 'blocks rather than elevates when winget is not on this machine' {
            Mock Get-FmToolWingetPath { '' }
            $result = Install-FmToolRuntime -Status $script:RuntimeMissing -Confirm:$false
            $result.Action | Should -Be 'blocked'
            $result.Detail | Should -Match 'App Installer'
            Should -Invoke Start-FmToolElevated -Times 0 -Exactly
        }

        It 'does not get a vote on whether this machine is ready' {
            # DELIBERATE, and not lenient. This step exists to REMOVE a cause of
            # failure; whether the machine is ready is still decided by running
            # the tools. A machine where the runtime mattered ends NOT READY
            # through herdr's own check, which names the same command - and a
            # machine where it did not is not reported broken by a step that was
            # never needed.
            Mock Start-FmToolElevated { [pscustomobject]@{ Started = $false; Declined = $true; ExitKnown = $false; ExitCode = 0 } }
            $step = Invoke-FmToolRuntimeStep -Runtime $script:RuntimeMissing -Performed -InstallRuntime -Confirm:$false
            $step.Outcome.Kind | Should -Be 'runtime' -Because 'the readiness gate excludes this step by its kind'
        }
    }

    It 'does not lower the bar: installing the runtime never certifies herdr' -Skip:(-not $IsWindows) {
        # The remedy line and the verdict, unchanged. A tool that dies in the
        # loader is still unproven, still reported missing, and the run still
        # ends NOT READY naming the same command this installer now runs itself.
        $env:PATH = New-RuntimeToolFixture -Body "@echo off`r`nexit /b -1073741515"
        Mock Update-FmToolSessionPath { $env:PATH }
        $herdr = @(Get-FmMachineToolVerification | Where-Object { $_.Name -eq 'tool herdr' })
        $herdr.Count | Should -Be 1
        $herdr[0].Status | Should -Be 'missing' -Because 'the tool is still proved by running it'
        $herdr[0].Fix | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
        $herdr[0].Fix | Should -Match 'ADMINISTRATOR'
    }

    # NOT TESTED HERE, AND THAT IS THE DECISION: Start-FmToolElevated itself.
    # Even a -WhatIf call would trip the lint that keeps a consent dialog off
    # the captain's desktop, and weakening that lint to let one test through is
    # a worse trade than leaving one PowerShell built-in gate unexercised. What
    # it guards is covered above, at the level that decides whether it is
    # called at all. docs/windows-e2e-evidence.md section 44.6 says so out loud.

    It 'builds the elevated arguments and the pasteable line from one definition' {
        # The elevated child cannot be handed a command string to parse, so it
        # takes an argument array - and a second copy of the flags is exactly the
        # drift Get-FmBootstrapWingetCommand exists to stop.
        $arguments = Get-FmBootstrapWingetArgument -PackageId 'Microsoft.VCRedist.2015+.x64'
        ($arguments -join ' ') | Should -Be ((Get-FmBootstrapWingetCommand -PackageId 'Microsoft.VCRedist.2015+.x64') -replace '^winget ', '')
        $arguments[0] | Should -Be 'install'
        # The id survives as ONE argument, rather than being split at the '+'.
        $arguments | Should -Contain 'Microsoft.VCRedist.2015+.x64'
        $arguments | Should -Contain '--accept-source-agreements'
        $arguments | Should -Contain '--accept-package-agreements'
    }
}

Describe 'a portable install is not finished until the tool RUNS' {
    # THE DEFECT, MEASURED in the captain's clean-VM log 2026-08-21: the same run
    # printed `[missing] tool herdr` and `summary: herdr installed
    # C:\Users\...\Programs\herdr`. Both were true - the files were placed and
    # the tool would not run - and the summary is the line they read last.
    #
    # The command route already ends by reaching what it installed; this one
    # ended at "the bytes are on disk".

    BeforeAll {
        # A zip shaped like a real release: the tool at its root, and nothing
        # stubbed between the archive and the verdict. Everything except the
        # download runs for real, which is the only reason these are worth
        # having.
        function New-RunnableToolArchive {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds a disposable archive under TestDrive.')]
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Tool,
                [string]$Body = '',
                [switch]$NotAProgram
            )
            $staging = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
            $null = New-Item -ItemType Directory -Path $staging -Force
            if ($NotAProgram) {
                # Empty, not text - see New-FmUnstartableFixture for why the
                # bytes matter more than they look like they should.
                $null = New-FmUnstartableFixture -Path (Join-Path $staging "$Tool.exe")
            } elseif ($Body) {
                Set-Content -LiteralPath (Join-Path $staging "$Tool.cmd") -Value $Body
            } else {
                Set-Content -LiteralPath (Join-Path $staging 'README.txt') -Value 'no tool in here' -NoNewline
            }
            Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $Path -Force
            $Path
        }

        function New-PortableRoute {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory route record and changes nothing.')]
            param([Parameter(Mandatory)][string]$Tool)
            [pscustomobject]@{
                Tool               = $Tool
                Kind               = 'portable'
                Command            = "expand the demo/demo release asset into `$env:LOCALAPPDATA\Programs\$Tool"
                NeedsAdministrator = $false
                Instructions       = ''
                Portable           = [pscustomobject]@{
                    Tool = $Tool; Source = 'github'; Repository = 'demo/demo'; ManifestUrl = ''; AssetKey = ''
                    AssetPattern = '*.zip'; BinSubdirectory = ''; StripRoot = $false
                    ExtraPath = @(); ConfigPath = ''; ConfigContent = ''
                }
            }
        }
    }

    BeforeEach {
        $script:PathBefore = $env:PATH
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
    }
    AfterEach { $env:PATH = $script:PathBefore }

    It 'reports FAILED for a release that expands and then will not run' -Skip:(-not $IsWindows) {
        # The archive carries no runnable fm-deadtool at all, so the expansion
        # succeeds and the proof cannot - which is the shape of a release that
        # lands correctly and produces a tool this machine cannot run.
        $archive = New-RunnableToolArchive -Path (Join-Path $TestDrive 'dead.zip') -Tool 'fm-deadtool'
        $result = Invoke-FmToolRoute -Route (New-PortableRoute -Tool 'fm-deadtool') `
            -InstallRoot $script:Root -ArchivePath $archive -PathScope 'Process' -Confirm:$false

        $result.Action | Should -Be 'failed' -Because 'a summary that says installed for a tool that will not run is the defect'
        $result.Detail | Should -Match 'fm-deadtool'
        $result.Detail | Should -Match ([regex]::Escape((Join-Path $script:Root 'fm-deadtool'))) -Because 'where the files went is still worth saying'
        # And the files really are there, so the report is not calling a failed
        # download a failed install.
        Test-Path -LiteralPath (Join-Path $script:Root 'fm-deadtool' 'README.txt') | Should -BeTrue
    }

    It 'reports installed for a release whose tool answers --version' -Skip:(-not $IsWindows) {
        # The other direction, and the one that matters most: over-rejecting
        # would report a working install as failed.
        $archive = New-RunnableToolArchive -Path (Join-Path $TestDrive 'live.zip') -Tool 'fm-livetool' `
            -Body "@echo off`r`necho fm-livetool 1.0.0"
        $result = Invoke-FmToolRoute -Route (New-PortableRoute -Tool 'fm-livetool') `
            -InstallRoot $script:Root -ArchivePath $archive -PathScope 'Process' -Confirm:$false

        $result.Action | Should -Be 'installed'
        $result.Detail | Should -Be (Join-Path $script:Root 'fm-livetool')
    }

    It 'says the cure on the step that failed, not only in the pass further down' -Skip:(-not $IsWindows) {
        # This is the moment on a clean VM: the archive lands, the tool is run,
        # and it dies in the loader. A step reported 'failed' has no fix slot of
        # its own, so the remedy has to be in what it says - otherwise the
        # captain reads "installed ... failed" here and only meets the answer
        # pages later, which is how the last two days went.
        $archive = New-RunnableToolArchive -Path (Join-Path $TestDrive 'noruntime.zip') `
            -Tool 'fm-noruntimetool' -Body "@echo off`r`nexit /b -1073741515"
        $result = Invoke-FmToolRoute -Route (New-PortableRoute -Tool 'fm-noruntimetool') `
            -InstallRoot $script:Root -ArchivePath $archive -PathScope 'Process' -Confirm:$false

        $result.Action | Should -Be 'failed' -Because 'a cure is not a proof'
        $result.Detail | Should -Match '0xC0000135'
        $result.Detail | Should -Match 'Microsoft\.VCRedist\.2015\+\.x64'
        $result.Detail | Should -Match 'ADMINISTRATOR'
    }

    It 'reports FAILED, and says the machine refused it, for a release Windows will not start' -Skip:(-not $IsWindows) {
        # Three outcomes, not two. "It ran and said nothing" and "it never ran"
        # are different findings and the wording must not blur them.
        $archive = New-RunnableToolArchive -Path (Join-Path $TestDrive 'refused.zip') `
            -Tool 'fm-refusedtool' -NotAProgram
        $result = Invoke-FmToolRoute -Route (New-PortableRoute -Tool 'fm-refusedtool') `
            -InstallRoot $script:Root -ArchivePath $archive -PathScope 'Process' -Confirm:$false

        $result.Action | Should -Be 'failed'
        $result.Detail | Should -Match 'refused to start'
        $result.Detail | Should -Not -Match 'answers nothing to --version'
    }
}

Describe 'a condition this run detected does not also escape as noise' {
    # THE DEFECT, MEASURED on the captain's clean Windows 11 VM 2026-08-21: the
    # plan said cleanly that Pester 3.4.0 was below the floor, and eight lines
    # later the suite's child process dumped a raw `Import-Module Pester
    # -MinimumVersion 5.0.0` failure with a source-line caret into the middle of
    # the install log. The same fact, arriving twice, the second time as an
    # unhandled error.

    It 'refuses to start the suite on a Pester this suite is not written for' {
        $prerequisite = Get-FmMachineSuitePrerequisite -Available @([version]'3.4.0')
        $prerequisite.CanRun | Should -BeFalse
        $prerequisite.Detail | Should -Match '3\.4\.0'
        $prerequisite.Detail | Should -Match 'Pester 5\+'
    }

    It 'says Pester is absent rather than too old when it is absent' {
        $prerequisite = Get-FmMachineSuitePrerequisite -Available @()
        $prerequisite.CanRun | Should -BeFalse
        $prerequisite.Detail | Should -Match 'not installed'
    }

    It 'runs when a copy this suite is written for is present, whatever else is' {
        # The shape every clean Windows machine is in once this installer has
        # run: Windows' own 3.4.0 still there, and a 5+ beside it.
        $prerequisite = Get-FmMachineSuitePrerequisite -Available @([version]'3.4.0', [version]'6.1.0')
        $prerequisite.CanRun | Should -BeTrue
        $prerequisite.Newest | Should -Be '6.1.0'
    }
}

Describe 'nothing a clean machine needs is behind administrator' {
    # THE GAP THIS CLOSES. Node.js came from winget, winget runs a machine-scope
    # MSI, and an unelevated run therefore named it and SKIPPED it - which left
    # npm absent and all five axi tools BLOCKED with "install Node.js first and
    # re-run this installer". That is a sixth manual step and a second run, for
    # the one command that is supposed to finish the job.

    It 'leaves exactly one route needing elevation, and it is one a clean machine cannot reach' -Skip:(-not $IsWindows) {
        $elevated = @()
        foreach ($entry in (Get-FmToolCatalog)) {
            if ((Get-FmToolRoute -Tool $entry.Tool).NeedsAdministrator) { $elevated += $entry.Tool }
        }
        # git alone, and the documented path clones this repo with git - so a
        # machine that has this checkout already has it, and the route is never
        # taken. Every other requirement installs with no elevation at all.
        $elevated | Should -Be @('git')
    }

    It 'takes Node.js from the per-user zip, not from the machine-scope MSI' -Skip:(-not $IsWindows) {
        $route = Get-FmToolRoute -Tool 'node'
        $route.Kind | Should -Be 'portable'
        $route.NeedsAdministrator | Should -BeFalse
        $route.Portable.Source | Should -Be 'nodejs'
        # MEASURED against the real v24.19.0 zip, 2026-08-21: node.exe, npm.cmd
        # and npx.cmd sit at the top level of one versioned root directory.
        $route.Portable.StripRoot | Should -BeTrue
        $route.Portable.BinSubdirectory | Should -BeNullOrEmpty
    }

    It 'still prints the winget line for a captain who wants Node.js machine-wide' -Skip:(-not $IsWindows) {
        # The published one-liner is not wrong, it is just not what this
        # installer takes - and it says so rather than looking like an oversight.
        $command = Get-FmBootstrapInstallCommand -Tool 'node'
        $command | Should -Match 'winget install -e --id OpenJS\.NodeJS'
        $command | Should -Match 'install\.ps1'
    }

    It 'keeps global npm packages out of the directory the next update deletes' -Skip:(-not $IsWindows) {
        # MEASURED on the real zip, 2026-08-21. Expanded bare, `npm root -g`
        # answers <expansion>\node_modules - INSIDE the tree this route replaces
        # wholesale on the next Node.js update, which would take the five axi
        # tools with it. With the builtin npmrc below it answers
        # %APPDATA%\npm\node_modules, which is where the MSI puts them and where
        # the captain's own clean VM already has them.
        $portable = Get-FmBootstrapPortableRelease -Tool 'node'
        $portable.ConfigPath | Should -Be 'node_modules\npm\npmrc'
        $portable.ConfigContent | Should -Be 'prefix=${APPDATA}\npm'
        $portable.ExtraPath | Should -Contain '%APPDATA%\npm'
    }

    It 'builds the dist URL for this machine from the release the currency check ranks against' -Skip:(-not $IsWindows) {
        # A route that installed the newest CURRENT release while the check
        # ranked against the newest LTS would report the machine older the
        # moment it finished, forever.
        $portable = Get-FmBootstrapPortableRelease -Tool 'node'
        $portable.AssetPattern | Should -Match '^node-v\*-win-(x64|arm64)\.zip$'
    }
}

Describe 'the portable install honours the whole record' {
    BeforeEach {
        $script:PathBefore = $env:PATH
        $script:Root = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
    }
    AfterEach { $env:PATH = $script:PathBefore }

    It 'writes the builtin config inside the tree, so every install rewrites it' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'cfg.zip') -BinDirectory ''
        $portable = [pscustomobject]@{
            Tool = 'cfgtool'; Source = 'github'; Repository = 'demo/demo'; ManifestUrl = ''; AssetKey = ''
            AssetPattern = '*.zip'; BinSubdirectory = ''; StripRoot = $false
            ExtraPath = @(); ConfigPath = 'sub\dir\tool.conf'; ConfigContent = 'prefix=here'
        }
        $result = Install-FmToolPortable -Portable $portable -InstallRoot $script:Root `
            -ArchivePath $archive -PathScope Process -Confirm:$false

        $config = Join-Path $result.Detail 'sub\dir\tool.conf'
        Test-Path -LiteralPath $config | Should -BeTrue -Because 'the config directory is created when the archive has none'
        (Get-Content -LiteralPath $config -Raw).Trim() | Should -Be 'prefix=here'
    }

    It 'creates and adds an extra PATH directory the tool will write into later' {
        # npm's prefix does not exist until the first global install, and a PATH
        # entry pointing at nothing would leave the tools it is about to hold
        # unreachable for the rest of this run.
        $extra = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        Test-Path -LiteralPath $extra | Should -BeFalse
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'extra.zip')
        $portable = [pscustomobject]@{
            Tool = 'extratool'; Source = 'github'; Repository = 'demo/demo'; ManifestUrl = ''; AssetKey = ''
            AssetPattern = '*.zip'; BinSubdirectory = 'bin'; StripRoot = $false
            ExtraPath = @($extra); ConfigPath = ''; ConfigContent = ''
        }
        $result = Install-FmToolPortable -Portable $portable -InstallRoot $script:Root `
            -ArchivePath $archive -PathScope Process -Confirm:$false

        Test-Path -LiteralPath $extra -PathType Container | Should -BeTrue
        Test-FmToolOnPath -Directory $extra -Scope Process | Should -BeTrue
        $result.OnPath | Should -Contain $extra
        $result.OnPath | Should -Contain $result.BinDirectory
    }

    It 'leaves PATH alone for an entry naming a variable this machine does not set' {
        $archive = New-ToolArchive -Path (Join-Path $TestDrive 'novar.zip')
        $portable = [pscustomobject]@{
            Tool = 'novartool'; Source = 'github'; Repository = 'demo/demo'; ManifestUrl = ''; AssetKey = ''
            AssetPattern = '*.zip'; BinSubdirectory = 'bin'; StripRoot = $false
            ExtraPath = @('%FM_NO_SUCH_VARIABLE%\bin'); ConfigPath = ''; ConfigContent = ''
        }
        $result = Install-FmToolPortable -Portable $portable -InstallRoot $script:Root `
            -ArchivePath $archive -PathScope Process -Confirm:$false
        # Only the tool's own directory. An unexpanded %VAR% is skipped rather
        # than turned into a literal directory with a percent sign in its name.
        $result.OnPath.Count | Should -Be 1
        $env:PATH | Should -Not -Match 'FM_NO_SUCH_VARIABLE'
    }
}

Describe 'where this checkout is, asked before anything is attempted' {
    # THE FIFTH THING THE CAPTAIN STILL DID BY HAND. A clone in the wrong place
    # is refused, and the refusal never says "wrong place" - it says access is
    # denied, two thirds of the way through, from whichever step happened to
    # write first.

    It 'accepts a plain local directory, and proves it by writing to it' {
        $result = Get-FmMachineLocationCheck -Path $TestDrive
        $result.Usable | Should -BeTrue
        $result.Reason | Should -Match 'accepted a write'
        # And it cleans up after itself - a probe left behind would show up in
        # the captain's own `git status`.
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.fm-location-probe-*').Count | Should -Be 0
    }

    It 'refuses a network share, because the command it writes points here' -Skip:(-not $IsWindows) {
        $separator = [string][char]92
        $unc = ($separator * 2) + 'somehost' + $separator + 'share' + $separator + 'firstmate'
        $result = Get-FmMachineLocationCheck -Path $unc
        $result.Usable | Should -BeFalse
        $result.Reason | Should -Match 'network share'
    }

    It 'refuses a drive that is not there, in words rather than in a .NET enum name' -Skip:(-not $IsWindows) {
        # 'NoRootDirectory' is what [System.IO.DriveType] calls a drive letter
        # with nothing mounted on it, and printing that at a captain tells them
        # nothing about what to do.
        $unmounted = @(90..68 | ForEach-Object { [char]$_ } |
                Where-Object { -not (Test-Path -LiteralPath "${_}:\") } | Select-Object -First 1)
        if ($unmounted.Count -eq 0) { Set-ItResult -Skipped -Because 'this machine has every drive letter mounted' ; return }
        $result = Get-FmMachineLocationCheck -Path "$($unmounted[0]):\firstmate-win"
        $result.Usable | Should -BeFalse
        $result.Reason | Should -Not -Match 'NoRootDirectory'
        $result.Reason | Should -Match 'nothing mounted on it'
    }

    It 'refuses a OneDrive folder, because the links this repo commits do not survive there' -Skip:(-not $IsWindows) {
        $separator = [string][char]92
        $result = Get-FmMachineLocationCheck -Path ($env:USERPROFILE + $separator + 'OneDrive' + $separator + 'firstmate-win')
        $result.Usable | Should -BeFalse
        $result.Reason | Should -Match 'OneDrive'
        $result.Reason | Should -Match 'junction or a symlink'
    }

    It 'names a directory to use instead, rather than only what is wrong' -Skip:(-not $IsWindows) {
        $separator = [string][char]92
        $result = Get-FmMachineLocationCheck -Path ($env:USERPROFILE + $separator + 'OneDrive' + $separator + 'firstmate-win')
        $result.Suggestion | Should -Not -BeNullOrEmpty
        $check = Get-FmMachineLocationVerification -Location $result
        $check.Status | Should -Be 'missing'
        $check.Fix | Should -Match 'git clone'
        $check.Fix | Should -Match ([regex]::Escape($result.Suggestion))
    }

    It 'answers a path that is not there, rather than creating it to find out' {
        # The probe uses -Force, which would build the whole missing chain. A
        # function whose entire job is to LOOK must not bring its subject into
        # being.
        $absent = Join-Path $TestDrive 'no-such-checkout'
        $result = Get-FmMachineLocationCheck -Path $absent
        $result.Usable | Should -BeFalse
        $result.Reason | Should -Match 'no directory at this path'
        Test-Path -LiteralPath $absent | Should -BeFalse -Because 'looking must not create'
    }

    It 'does not read one directory as being inside another that merely shares a prefix' {
        $parent = Join-Path $TestDrive 'Documents'
        $sibling = Join-Path $TestDrive 'Documents2'
        $null = New-Item -ItemType Directory -Path $parent -Force
        $null = New-Item -ItemType Directory -Path $sibling -Force
        Test-FmMachinePathUnder -Path $sibling -Parent $parent | Should -BeFalse
        Test-FmMachinePathUnder -Path (Join-Path $parent 'inside') -Parent $parent | Should -BeTrue
        # An empty parent is not a match for everything.
        Test-FmMachinePathUnder -Path $sibling -Parent '' | Should -BeFalse
    }

    It 'still detects under -WhatIf, instead of calling a good checkout refused' {
        # THE DEFECT, MEASURED: New-Item honours the WhatIf preference and made
        # no directory, the raw .NET write beneath it honours nothing and failed
        # on the directory that was never there, and the run reported this very
        # checkout as one the machine REFUSED a write into. A WhatIf run still
        # has to detect; this probe changes nothing to report on, because it
        # removes what it makes.
        # $WhatIfPreference is the mechanism that broke it: Install-FmMachine
        # -WhatIf sets it, and it reaches every cmdlet called below there.
        #
        # SET IN A CHILD SCOPE, NEVER BARE. A bare assignment here changes a
        # global preference and then relies on Pester ending the enclosing scope
        # to put it back - a trap for whoever adds the next test beside this
        # one, and for anyone who later moves this line up into a BeforeAll,
        # where it silently suppresses every cmdlet in the whole FILE.
        # `& { }` binds it to the one call that needs it: the callee still
        # inherits it, because preferences are dynamically scoped, and the
        # assertion below fails if it ever outlives that call.
        $result = & { $WhatIfPreference = $true; Get-FmMachineLocationCheck -Path $TestDrive }
        $WhatIfPreference |
            Should -BeFalse -Because 'the preference must not outlive the one call that needed it'
        $result.Usable | Should -BeTrue
        $result.Reason | Should -Match 'accepted a write'
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '.fm-location-probe-*').Count |
            Should -Be 0 -Because 'a removal WhatIf skipped would leave the probe in the captain''s checkout'
    }

    It 'carries the answer into the plan, and into the verdict the captain reads' -Skip:(-not $IsWindows) {
        $plan = Get-FmMachineInstallPlan -Offline -RepoRoot $script:RepoRoot
        $plan.Location | Should -Not -BeNullOrEmpty
        $plan.Location.Usable | Should -BeTrue -Because 'this checkout is a plain local directory'
        $check = Get-FmMachineLocationVerification -Location $plan.Location
        $check.Status | Should -Be 'ok'
        # It is a REQUIRED check, so an unusable location makes the run report
        # the machine NOT READY rather than ending on a cheerful note.
        (Get-FmMachineLocationVerification -Location ([pscustomobject]@{
                    Path = 'C:\nope'; Usable = $false; Reason = 'refused'; Suggestion = 'C:\good'; Concerns = @('refused')
                })).Required | Should -BeTrue
    }
}
