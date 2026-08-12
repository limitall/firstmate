#requires -Version 7.0
# Pester tests for the setup path and the environment doctor.
#
# What these pin, in priority order:
#
#   1. THE REFUSALS. Setup must not half-install: a missing hard prerequisite,
#      a home path occupied by a file, and an unreadable settings.json each stop
#      the run with nothing written. A refusal that is not tested is a refusal
#      that will not happen.
#   2. IDEMPOTENCE, byte-for-byte. Running setup twice must produce identical
#      files and report 'already' for every step - not "probably fine".
#   3. THE SURROUNDING TEXT. The profile is the captain's file. Everything
#      outside the managed block, including its CRLF line endings, survives.
#   4. HONEST DEGRADATION. When the Claude hook area is not loaded, the hook
#      step reports that it did NOT run; it is never reported as registered.

BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate', $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    # Install-FmHome deliberately wires the CURRENT session too, so a setup run
    # can be followed by a doctor run that reports the truth. In the suite that
    # would leak into every later test, so it is saved and restored.
    $script:SavedEnvironment = @{
        FM_HOME      = $env:FM_HOME
        FM_BACKEND   = $env:FM_BACKEND
        PATH         = $env:PATH
        PSModulePath = $env:PSModulePath
    }

    # FM_BACKEND takes precedence over config/backend in
    # Get-FmBootstrapBackendName, so a value left behind by an earlier test FILE
    # would decide this area's backend checks. Env vars are process-wide.
    $env:FM_BACKEND = $null

    function Reset-InstallTestEnvironment {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: restores this process own environment variables.')]
        param()
        $env:FM_HOME = $script:SavedEnvironment.FM_HOME
        $env:FM_BACKEND = $script:SavedEnvironment.FM_BACKEND
        $env:PATH = $script:SavedEnvironment.PATH
        $env:PSModulePath = $script:SavedEnvironment.PSModulePath
    }

    function New-InstallFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: creates a directory under TestDrive.')]
        param()
        $dir = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        $null = New-Item -ItemType Directory -Path $dir -Force
        [pscustomobject]@{
            Root     = $dir
            Home     = Join-Path $dir 'fmhome'
            Profile  = Join-Path $dir 'profile.ps1'
            Settings = Join-Path $dir 'settings.json'
        }
    }

    function Invoke-Setup {
        param($Fixture, [hashtable]$Extra = @{})
        $splat = @{
            FirstmateHome    = $Fixture.Home
            RepoRoot         = $script:RepoRoot
            ProfilePath      = $Fixture.Profile
            HookSettingsPath = $Fixture.Settings
        }
        foreach ($key in $Extra.Keys) { $splat[$key] = $Extra[$key] }
        Install-FmHome @splat
    }
}

AfterAll {
    # Restored once, at the end: within this file the wiring Install-FmHome
    # applies to the session is exactly what the doctor tests need to see, and
    # leaking it into the next test file would not be.
    Reset-InstallTestEnvironment
}

Describe 'Install-FmHome: the home layout' {
    It 'creates the four home directories' {
        $fixture = New-InstallFixture
        $report = Invoke-Setup -Fixture $fixture

        $report.Installed | Should -BeTrue
        foreach ($name in @('config', 'data', 'projects', 'state')) {
            Test-Path -LiteralPath (Join-Path $fixture.Home $name) -PathType Container |
                Should -BeTrue -Because "the home layout includes $name"
        }
    }

    It 'reports every step as created on the first run' {
        $fixture = New-InstallFixture
        $report = Invoke-Setup -Fixture $fixture
        @($report.Steps | Where-Object { $_.Action -eq 'already' }).Count | Should -Be 0
    }

    It 'is idempotent: the second run changes nothing and reports already' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $profileBefore = [System.IO.File]::ReadAllBytes($fixture.Profile)
        $settingsBefore = [System.IO.File]::ReadAllBytes($fixture.Settings)

        $second = Invoke-Setup -Fixture $fixture

        @($second.Steps | Where-Object { $_.Action -ne 'already' }) | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllBytes($fixture.Profile) | Should -Be $profileBefore
        [System.IO.File]::ReadAllBytes($fixture.Settings) | Should -Be $settingsBefore
    }

    It 'refuses when the home path is occupied by a file' {
        $fixture = New-InstallFixture
        [System.IO.File]::WriteAllText($fixture.Home, "not a home`n")
        { Invoke-Setup -Fixture $fixture } | Should -Throw '*is not a directory*'
    }

    It 'refuses when a home subdirectory is occupied by a file' {
        $fixture = New-InstallFixture
        $null = New-Item -ItemType Directory -Path $fixture.Home -Force
        [System.IO.File]::WriteAllText((Join-Path $fixture.Home 'state'), "not a directory`n")
        { Invoke-Setup -Fixture $fixture } | Should -Throw '*refusing to install over it*'
    }

    It 'refuses a repo root that is not a firstmate-win checkout' {
        $fixture = New-InstallFixture
        { Invoke-Setup -Fixture $fixture -Extra @{ RepoRoot = $fixture.Root } } |
            Should -Throw '*does not look like a firstmate-win checkout*'
    }
}

Describe 'Install-FmHome: detect before mutate' {
    It 'installs nothing at all when a hard prerequisite is missing' {
        $fixture = New-InstallFixture
        Mock Get-FmInstallPrerequisiteCheck {
            @(New-FmInstallCheck -Name 'git' -Status 'missing' -Required -Detail 'not on PATH' -Fix 'winget install Git.Git')
        }

        $report = Invoke-Setup -Fixture $fixture

        $report.Installed | Should -BeFalse
        $report.Reason | Should -BeLike '*nothing was installed*'
        # The point of the gate: the filesystem is untouched.
        Test-Path -LiteralPath $fixture.Home | Should -BeFalse
        Test-Path -LiteralPath $fixture.Profile | Should -BeFalse
        Test-Path -LiteralPath $fixture.Settings | Should -BeFalse
    }

    It 'names the missing prerequisite and its fix in the output' {
        $fixture = New-InstallFixture
        Mock Get-FmInstallPrerequisiteCheck {
            @(New-FmInstallCheck -Name 'git' -Status 'missing' -Required -Detail 'not on PATH' -Fix 'winget install Git.Git')
        }

        $report = Invoke-Setup -Fixture $fixture
        ($report.Lines -join "`n") | Should -BeLike '*git*'
        ($report.Lines -join "`n") | Should -BeLike '*winget install Git.Git*'
    }

    It 'a warn-level prerequisite does not stop the install' {
        $fixture = New-InstallFixture
        Mock Get-FmInstallPrerequisiteCheck {
            @(New-FmInstallCheck -Name 'herdr' -Status 'warn' -Detail 'not on PATH' -Fix 'see https://herdr.dev')
        }

        $report = Invoke-Setup -Fixture $fixture
        $report.Installed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.Home 'state') -PathType Container | Should -BeTrue
    }
}

Describe 'Get-FmInstallHomeDirectory: binding to the layout owner' {
    # REGRESSION. An earlier revision read Get-FmHomeLayout's output as a list
    # of directory NAMES. It returns one pscustomobject, so the delegation
    # stringified it into a single bogus name - '@{Root=...; Home=...}' - and
    # setup created that instead of the four directories. It passed every test
    # while the foundation area was unlanded and broke the moment it landed.
    It 'returns exactly the four home directories, by name' {
        $fixture = New-InstallFixture
        $entries = @(Get-FmInstallHomeDirectory -FirstmateHome $fixture.Home)

        $entries.Count | Should -Be 4
        ($entries | ForEach-Object { $_.Name } | Sort-Object) -join ',' |
            Should -BeExactly 'config,data,projects,state'
    }

    It 'never produces a name that looks like a stringified object' {
        $fixture = New-InstallFixture
        foreach ($entry in (Get-FmInstallHomeDirectory -FirstmateHome $fixture.Home)) {
            $entry.Name | Should -Not -BeLike '*@{*'
            $entry.Path | Should -Not -BeLike '*@{*'
            $entry.Path | Should -Not -BeNullOrEmpty
        }
    }

    It 'falls back to the local layout when the owner is absent' {
        $fixture = New-InstallFixture
        Mock Resolve-FmSessionCommand { $null } -ParameterFilter { $Name -contains 'Get-FmHomeLayout' }

        $entries = @(Get-FmInstallHomeDirectory -FirstmateHome $fixture.Home)
        $entries.Count | Should -Be 4
        foreach ($entry in $entries) {
            $entry.Path | Should -BeExactly (Join-Path -Path $fixture.Home -ChildPath $entry.Name)
        }
    }

    It 'ignores an owner whose shape it was not written against' {
        $fixture = New-InstallFixture
        # A partial answer is worse than the local fallback: half a home.
        Mock Resolve-FmSessionCommand { { [pscustomobject]@{ Config = 'x' } } } -ParameterFilter {
            $Name -contains 'Get-FmHomeLayout'
        }

        $entries = @(Get-FmInstallHomeDirectory -FirstmateHome $fixture.Home)
        $entries.Count | Should -Be 4
        ($entries | ForEach-Object { $_.Path }) | Should -Not -Contain 'x'
    }
}

Describe 'Install-FmHome: the backend a fresh home gets' {
    It 'writes config/backend=herdr, LF-only and without a BOM' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture

        $path = Join-Path -Path $fixture.Home -ChildPath 'config' -AdditionalChildPath 'backend'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly "herdr`n"
        $bytes | Should -Not -Contain 13
    }

    It 'never overwrites a backend the home already chose' {
        $fixture = New-InstallFixture
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Home 'config') -Force
        $path = Join-Path -Path $fixture.Home -ChildPath 'config' -AdditionalChildPath 'backend'
        [System.IO.File]::WriteAllText($path, "zellij`n")

        $report = Invoke-Setup -Fixture $fixture

        [System.IO.File]::ReadAllText($path) | Should -BeExactly "zellij`n"
        ($report.Steps | Where-Object { $_.Name -eq 'backend' }).Action | Should -Be 'already'
    }

    It 'is what stops the first digest asking a Windows machine to install tmux' {
        # Regression guard with a reason: Get-FmBootstrapBackendName falls back
        # to tmux for a home with no config/backend, and the bootstrap section
        # of the session digest then reports tmux as MISSING.
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture

        $configDir = Join-Path $fixture.Home 'config'
        Get-FmBootstrapBackendName -ConfigDir $configDir | Should -Be 'herdr'
    }

    It 'warns when the home resolves to a backend this port cannot drive' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $path = Join-Path -Path $fixture.Home -ChildPath 'config' -AdditionalChildPath 'backend'
        [System.IO.File]::WriteAllText($path, "zellij`n")

        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        $check = $doctor.Checks | Where-Object { $_.Name -eq 'backend' }
        $check.Status | Should -Be 'warn'
        $check.Detail | Should -BeLike '*cannot dispatch*'
        # A backend it cannot drive is a warning, not a broken installation.
        $doctor.Healthy | Should -BeTrue
    }
}

Describe 'Install-FmHome: the managed profile block' {
    It 'wires FM_HOME, PSModulePath and PATH' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $text = [System.IO.File]::ReadAllText($fixture.Profile)

        $text | Should -BeLike '*$env:FM_HOME*'
        $text | Should -BeLike ('*' + (Join-Path $script:RepoRoot 'module') + '*')
        $text | Should -BeLike ('*' + (Join-Path $script:RepoRoot 'bin') + '*')
    }

    It 'a fresh session that dot-sources the profile can import the module and find the entry points' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture

        # The actual requirement, exercised the way the captain meets it: a new
        # PowerShell process that loads only the profile.
        $probe = @(
            ". '$($fixture.Profile)'"
            'Import-Module Firstmate -ErrorAction Stop'
            '$env:FM_HOME'
            '(Get-Command Invoke-FmDoctor -Module Firstmate).Name'
            '(Get-Command fm-doctor.ps1).Source'
        ) -join '; '
        $out = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command $probe 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -BeLike "*$($fixture.Home)*"
        ($out -join "`n") | Should -BeLike '*Invoke-FmDoctor*'
        ($out -join "`n") | Should -BeLike '*fm-doctor.ps1*'
    }

    It 'replaces its own block instead of appending a second one' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $moved = Join-Path $fixture.Root 'fmhome2'
        $null = Invoke-Setup -Fixture $fixture -Extra @{ FirstmateHome = $moved }

        $text = [System.IO.File]::ReadAllText($fixture.Profile)
        @([regex]::Matches($text, [regex]::Escape('# >>> firstmate-win >>>'))).Count | Should -Be 1
        $text | Should -BeLike "*$moved*"
        $text | Should -Not -BeLike "*$($fixture.Home)'*"
    }

    It 'leaves the rest of the profile untouched, CRLF and all' {
        $fixture = New-InstallFixture
        $before = "# the captain's own profile`r`nSet-Alias ll Get-ChildItem`r`n"
        [System.IO.File]::WriteAllText($fixture.Profile, $before)

        $null = Invoke-Setup -Fixture $fixture

        $after = [System.IO.File]::ReadAllText($fixture.Profile)
        $after.StartsWith($before) | Should -BeTrue -Because 'the pre-existing text is preserved byte-for-byte'
        $after | Should -BeLike '*firstmate-win*'
    }

    It 'writes the profile without a BOM' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $bytes = [System.IO.File]::ReadAllBytes($fixture.Profile)
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191'
    }

    It 'skips the profile on -SkipProfile and says so' {
        $fixture = New-InstallFixture
        $report = Invoke-Setup -Fixture $fixture -Extra @{ SkipProfile = [switch]$true }

        Test-Path -LiteralPath $fixture.Profile | Should -BeFalse
        ($report.Steps | Where-Object { $_.Name -eq 'profile wiring' }).Action | Should -Be 'skipped'
    }
}

Describe 'Install-FmHome: Claude hook registration' {
    It 'registers the three events this port owns' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture

        $document = [System.IO.File]::ReadAllText($fixture.Settings) | ConvertFrom-Json -AsHashtable
        foreach ($hookEvent in @('SessionStart', 'PreToolUse', 'Stop')) {
            $document['hooks'].Contains($hookEvent) | Should -BeTrue -Because "$hookEvent is registered"
        }
        Test-FmInstallHookRegistered -Path $fixture.Settings | Should -BeTrue
    }

    It 'writes settings.json LF-only and without a BOM' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $bytes = [System.IO.File]::ReadAllBytes($fixture.Settings)
        @($bytes[0], $bytes[1], $bytes[2]) -join ',' | Should -Not -Be '239,187,191'
        $bytes | Should -Not -Contain 13
    }

    It 'preserves unrelated top-level keys and unrelated hook events' {
        $fixture = New-InstallFixture
        $existing = @{
            permissions = @{ allow = @('Bash(ls:*)') }
            hooks       = @{ UserPromptSubmit = @(@{ hooks = @(@{ type = 'command'; command = 'echo hi' }) }) }
        } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($fixture.Settings, $existing)

        $null = Invoke-Setup -Fixture $fixture

        $document = [System.IO.File]::ReadAllText($fixture.Settings) | ConvertFrom-Json -AsHashtable
        $document.Contains('permissions') | Should -BeTrue
        $document['hooks'].Contains('UserPromptSubmit') | Should -BeTrue
        $document['hooks'].Contains('SessionStart') | Should -BeTrue
    }

    It 'replaces a stale registration of an event it owns rather than adding a second' {
        $fixture = New-InstallFixture
        $existing = @{
            hooks = @{ SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'old-and-wrong.sh' }) }) }
        } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($fixture.Settings, $existing)

        $null = Invoke-Setup -Fixture $fixture

        $text = [System.IO.File]::ReadAllText($fixture.Settings)
        $text | Should -Not -BeLike '*old-and-wrong.sh*'
        $text | Should -BeLike '*fm-claude-hook.ps1*'
    }

    It 'refuses to overwrite a settings file it cannot parse' {
        $fixture = New-InstallFixture
        [System.IO.File]::WriteAllText($fixture.Settings, "{ this is not json")
        { Invoke-Setup -Fixture $fixture } | Should -Throw '*not valid JSON*'
        # The unreadable file is left exactly as it was.
        [System.IO.File]::ReadAllText($fixture.Settings) | Should -Be '{ this is not json'
    }

    It 'refuses a settings file whose top level is not an object' {
        $fixture = New-InstallFixture
        [System.IO.File]::WriteAllText($fixture.Settings, '["a", "b"]')
        { Invoke-Setup -Fixture $fixture } | Should -Throw '*does not contain a JSON object*'
    }

    It 'skips the hooks on -SkipHooks and says so' {
        $fixture = New-InstallFixture
        $report = Invoke-Setup -Fixture $fixture -Extra @{ SkipHooks = [switch]$true }

        Test-Path -LiteralPath $fixture.Settings | Should -BeFalse
        ($report.Steps | Where-Object { $_.Name -eq 'Claude hooks' }).Action | Should -Be 'skipped'
    }

    It 'reports the step as NOT run when the Claude hook area is absent' {
        $fixture = New-InstallFixture
        # The cross-area rule: a missing owner is a step that did not run, never
        # one that passed.
        Mock Resolve-FmSessionCommand { $null } -ParameterFilter {
            $Name -contains 'Get-FmClaudeHookSettingsObject'
        }

        $result = Set-FmInstallHookRegistration -Path $fixture.Settings

        $result.Action | Should -Be 'skipped'
        $result.Detail | Should -BeLike '*hook area is not loaded*'
        Test-Path -LiteralPath $fixture.Settings | Should -BeFalse
    }
}

Describe 'Test-FmInstallHookRegistered' {
    It 'is false when the settings file does not exist' {
        Test-FmInstallHookRegistered -Path (Join-Path $TestDrive 'nope.json') | Should -BeFalse
    }

    It 'is false when the settings file is malformed' {
        $path = Join-Path $TestDrive 'bad.json'
        [System.IO.File]::WriteAllText($path, '{ nope')
        Test-FmInstallHookRegistered -Path $path | Should -BeFalse
    }

    It 'is false when one owned event is missing' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $document = [System.IO.File]::ReadAllText($fixture.Settings) | ConvertFrom-Json -AsHashtable
        $document['hooks'].Remove('Stop')
        [System.IO.File]::WriteAllText($fixture.Settings, ($document | ConvertTo-Json -Depth 12))

        Test-FmInstallHookRegistered -Path $fixture.Settings | Should -BeFalse
    }

    It 'is false when an owned event points somewhere else' {
        $path = Join-Path $TestDrive 'other.json'
        $document = @{
            hooks = @{
                SessionStart = @(@{ hooks = @(@{ type = 'command'; command = 'something-else.ps1' }) })
                PreToolUse   = @(@{ hooks = @(@{ type = 'command'; command = 'something-else.ps1' }) })
                Stop         = @(@{ hooks = @(@{ type = 'command'; command = 'something-else.ps1' }) })
            }
        }
        [System.IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 12))
        Test-FmInstallHookRegistered -Path $path | Should -BeFalse
    }
}

Describe 'Invoke-FmDoctor' {
    It 'is healthy right after a successful setup' {
        $fixture = New-InstallFixture
        $report = Invoke-Setup -Fixture $fixture

        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings
        $doctor.Healthy | Should -BeTrue
        $report.Healthy | Should -BeTrue
    }

    It 'reports an absent home as missing, with the command that fixes it' {
        $fixture = New-InstallFixture
        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        $doctor.Healthy | Should -BeFalse
        $layout = $doctor.Checks | Where-Object { $_.Name -eq 'home layout' }
        $layout.Status | Should -Be 'missing'
        $layout.Fix | Should -BeLike '*fm-setup.ps1*'
    }

    It 'reports a home missing one directory, and names that directory' {
        $fixture = New-InstallFixture
        foreach ($name in @('config', 'data', 'projects')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $fixture.Home $name) -Force
        }
        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        $layout = $doctor.Checks | Where-Object { $_.Name -eq 'home layout' }
        $layout.Status | Should -Be 'missing'
        $layout.Detail | Should -BeLike '*state*'
    }

    It 'reports unregistered hooks as missing' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture -Extra @{ SkipHooks = [switch]$true }

        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings
        ($doctor.Checks | Where-Object { $_.Name -eq 'Claude hooks' }).Status | Should -Be 'missing'
        $doctor.Healthy | Should -BeFalse
    }

    It 'reports an absent profile as missing' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture -Extra @{ SkipProfile = [switch]$true }

        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings
        ($doctor.Checks | Where-Object { $_.Name -eq 'profile wiring' }).Status | Should -Be 'missing'
    }

    It 'warns rather than fails when the checkout or the home has moved' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture

        # Same profile, different home: the block is present but stale.
        $doctor = Invoke-FmDoctor -FirstmateHome (Join-Path $fixture.Root 'elsewhere') -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings
        ($doctor.Checks | Where-Object { $_.Name -eq 'profile wiring' }).Status | Should -Be 'warn'
    }

    It 'a warning alone does not make the environment unhealthy' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        Mock Get-FmInstallPrerequisiteCheck {
            @(New-FmInstallCheck -Name 'herdr' -Status 'warn' -Detail 'not on PATH' -Fix 'see https://herdr.dev')
        }

        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        $doctor.Healthy | Should -BeTrue
        $doctor.Warnings.Count | Should -Be 1
        ($doctor.Lines -join "`n") | Should -BeLike '*cannot dispatch*'
    }

    It 'prints every check, passing or not' {
        $fixture = New-InstallFixture
        $null = Invoke-Setup -Fixture $fixture
        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        foreach ($check in $doctor.Checks) {
            ($doctor.Lines -join "`n") | Should -BeLike "*$($check.Name)*"
        }
        $doctor.Checks.Count | Should -BeGreaterOrEqual 10
    }

    It 'prints a fix for every check that is not ok' {
        $fixture = New-InstallFixture
        $doctor = Invoke-FmDoctor -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings

        foreach ($check in ($doctor.Checks | Where-Object { $_.Status -ne 'ok' })) {
            $check.Fix | Should -Not -BeNullOrEmpty -Because "$($check.Name) is $($check.Status)"
        }
    }
}

Describe 'the entry points' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
    }

    It 'fm-setup.ps1 exits 0 on a healthy install' {
        $fixture = New-InstallFixture
        $out = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path -Path $script:RepoRoot -ChildPath 'bin' -AdditionalChildPath 'fm-setup.ps1') `
            -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        ($out -join "`n") | Should -BeLike '*healthy*'
    }

    It 'fm-doctor.ps1 exits 1 and names the problem when the home is absent' {
        $fixture = New-InstallFixture
        $out = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path -Path $script:RepoRoot -ChildPath 'bin' -AdditionalChildPath 'fm-doctor.ps1') `
            -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -BeLike '*unhealthy*'
        ($out -join "`n") | Should -BeLike '*home layout*'
    }

    It 'fm-doctor.ps1 exits 0 after fm-setup.ps1' {
        $fixture = New-InstallFixture
        $null = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path -Path $script:RepoRoot -ChildPath 'bin' -AdditionalChildPath 'fm-setup.ps1') `
            -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings 2>&1
        $out = & $script:Pwsh -NoProfile -NonInteractive -File (Join-Path -Path $script:RepoRoot -ChildPath 'bin' -AdditionalChildPath 'fm-doctor.ps1') `
            -FirstmateHome $fixture.Home -RepoRoot $script:RepoRoot `
            -ProfilePath $fixture.Profile -HookSettingsPath $fixture.Settings 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }
}
