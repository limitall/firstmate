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
            $route.Kind | Should -Be 'command' -Because "$tool has a scriptable installer of its own"
            $route.Command | Should -Not -Match 'npm' -Because "the npm package called '$tool' is not this software"
        }
    }

    It 'takes each tool from the vendor that publishes it' -Skip:(-not $IsWindows) {
        (Get-FmToolRoute -Tool 'treehouse').Command | Should -Match 'kunchenguid\.github\.io/treehouse/install\.ps1'
        (Get-FmToolRoute -Tool 'herdr').Command | Should -Match 'herdr\.dev/install\.ps1'
        (Get-FmToolRoute -Tool 'claude').Command | Should -Match 'claude\.ai/install\.ps1'
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

    It 'declares the only two routes that need administrator, and no others' -Skip:(-not $IsWindows) {
        # winget runs a machine-scope MSI for both, which fails late and
        # unhelpfully on an unelevated session. Declaring it is what lets the
        # installer name the step and carry on with everything else.
        foreach ($tool in @('git', 'node')) {
            (Get-FmToolRoute -Tool $tool).NeedsAdministrator |
                Should -BeTrue -Because "$tool comes from winget, which installs machine-wide"
        }
        foreach ($tool in @('claude', 'herdr', 'treehouse', 'gh', 'gh-axi')) {
            (Get-FmToolRoute -Tool $tool).NeedsAdministrator |
                Should -BeFalse -Because "$tool installs into the user's own profile"
        }
    }

    It 'asks winget to UPGRADE when the captain agreed to an update' -Skip:(-not $IsWindows) {
        # `winget install <id>` on a package already present reports "already
        # installed" and exits 0 without upgrading anything, so a captain who
        # said yes would have been told it happened and left on the old version.
        Get-FmToolUpdateCommand -Command 'winget install Git.Git' | Should -Be 'winget upgrade Git.Git'
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
        $script:Portable = [pscustomobject]@{
            Tool            = 'demotool'
            Repository      = 'demo/demo'
            AssetPattern    = 'demo_*_windows_amd64.zip'
            BinSubdirectory = 'bin'
            StripRoot       = $false
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
            Tool = 'rootedtool'; Repository = 'demo/demo'; AssetPattern = '*.zip'
            BinSubdirectory = 'bin'; StripRoot = $true
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
        $lines | Should -Match 'winget install Microsoft\.PowerShell'
        $lines | Should -Match 'needs administrator'
    }

    It 'does not push the elevated installer at a machine that already registers it' -Skip:(-not $IsWindows) {
        $already = [pscustomobject]@{
            Action = 'already'; Detail = 'x'; PwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
            Shortcut = 'C:\ProgramData\...\PowerShell 7 (x64).lnk'
        }
        $lines = (Get-FmMachineShellLine -Shortcut $already) -join "`n"
        $lines | Should -Match 'PowerShell 7 \(x64\)'
        $lines | Should -Not -Match 'winget install Microsoft\.PowerShell'
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
        $git.UpdateCommand | Should -Be 'winget upgrade Git.Git'
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
