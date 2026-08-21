#requires -Version 7.0
# Pester tests for bootstrap detection and the consent-gated installer.
# The CREW_DISPATCH and TANGLE expectations were produced by running
# bin/fm-bootstrap.sh in the reference implementation against the same fixtures,
# so these pin byte-for-byte parity with the lines the bootstrap-diagnostics
# skill matches on.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Pester fixtures that build and remove disposable temp homes. -WhatIf on a fixture would leave the test asserting against a home that was never created.')]
param()

BeforeAll {
    # The module loader sets these, so the tests must exercise the same rules.
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    foreach ($subdir in @('Private', 'Public')) {
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'module' 'Firstmate' $subdir) -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { . $_.FullName }
    }

    function New-TestHome {
        $home_ = Join-Path $TestDrive ([System.IO.Path]::GetRandomFileName())
        foreach ($sub in @('state', 'data', 'config', 'projects')) {
            New-Item -ItemType Directory -Path (Join-Path $home_ $sub) -Force | Out-Null
        }
        $home_
    }

    function Set-TestHome {
        param([string]$Path)
        Reset-TestEnvironment
        $env:FM_HOME = $Path
        $env:FM_ROOT_OVERRIDE = $Path
        # A home used as its own root needs the primary-shaped files the scope
        # predicate looks for.
        New-Item -ItemType Directory -Path (Join-Path $Path 'bin') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Path 'AGENTS.md'), "fixture`n")
    }

    function Write-TestConfig {
        param([string]$HomePath, [string]$Name, [string]$Content)
        [System.IO.File]::WriteAllText((Join-Path $HomePath 'config' $Name), $Content)
    }

    # Every test starts from a clean environment contract so no test can inherit
    # another's overrides.
    function Reset-TestEnvironment {
        $env:FM_HOME = $null
        $env:FM_ROOT_OVERRIDE = $null
        $env:FM_BACKEND = $null
        $env:FM_TASKS_AXI_COMPATIBLE = $null
        $env:FM_BOOTSTRAP_DETECT_ONLY = $null
        $env:FM_BOOTSTRAP_NETWORK = $null
        $env:FM_BOOTSTRAP_LOCKED = $null
        $env:FM_BOOTSTRAP_VERBOSE_FACTS = $null
    }
}

AfterAll {
    # Reset-TestEnvironment runs per-Describe, and the last Describe in this file
    # has no BeforeEach - so without this the FM_BACKEND override set by
    # 'reports an unresolvable backend' escaped into every test FILE that runs
    # after this one, where Get-FmBootstrapBackendName honours it ahead of
    # config/backend. Env vars are process-wide; Pester containers are not.
    Reset-TestEnvironment
}

Describe 'Get-FmBootstrapCrewDispatchDiagnostic' {
    BeforeEach {
        $script:TestHome = New-TestHome
        Set-TestHome -Path $script:TestHome
        $script:Config = Join-Path $script:TestHome 'config'
    }

    It 'is silent when no dispatch config exists' {
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config).Count | Should -Be 0
    }

    It 'is silent for a valid config' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"docs","use":{"harness":"claude","effort":"high"}}],"default":{"harness":"codex"}}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config).Count | Should -Be 0
    }

    It 'reports malformed JSON' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content 'not json'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON'
    }

    It 'reports a non-object top level' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '[]'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - top-level value must be an object'
    }

    It 'reports non-array rules' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":"nope"}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - rules must be an array'
    }

    It 'reports an unverified harness' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"x","use":{"harness":"nope"}}]}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: nope'
    }

    It 'reports an effort the harness does not accept' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"x","use":{"harness":"claude","effort":"turbo"}}]}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: claude:turbo'
    }

    It 'reports an effort on a harness that accepts none at all' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"x","use":{"harness":"opencode","effort":"low"}}]}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:low'
    }

    It 'reports an empty default array' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"default":[]}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - default needs at least one profile'
    }

    It 'reports an unknown select' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"whatever"}]}'
        @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config)[0] |
            Should -Be 'CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: whatever'
    }

    It 'prints the active configuration as BOOTSTRAP_INFO facts only when asked' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":[{"when":"docs","use":[{"harness":"claude","effort":"high"},{"harness":"codex"}],"select":"quota-balanced"}],"default":{"harness":"claude","model":"opus"}}'
        $facts = @(Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $script:Config -VerboseFacts)
        $facts[0] | Should -Be 'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json'
        $facts[1] | Should -Be 'BOOTSTRAP_INFO: crew dispatch rule: docs -> quota-balanced[claude/default/high, codex]'
        $facts[2] | Should -Be 'BOOTSTRAP_INFO: crew dispatch default: claude/opus'
    }
}

Describe 'Test-FmBootstrapToolVersionAtLeast' {
    It 'refuses a version string it cannot parse into one triple, so an unchecked build never passes a floor' {
        Test-FmBootstrapToolVersionAtLeast -Tool 'definitely-not-a-real-tool' -Minimum '1.0.0' | Should -BeFalse
    }

    It 'refuses a malformed floor' {
        Test-FmBootstrapToolVersionAtLeast -Tool 'pwsh' -Minimum '1.0' | Should -BeFalse
    }

    It 'accepts a real tool at or above its floor' {
        Test-FmBootstrapToolVersionAtLeast -Tool 'pwsh' -Minimum '7.0.0' | Should -BeTrue
    }

    It 'rejects a real tool below an impossible floor' {
        Test-FmBootstrapToolVersionAtLeast -Tool 'pwsh' -Minimum '999.0.0' | Should -BeFalse
    }
}

Describe 'Get-FmBootstrapMissingDiagnostic' {
    It 'renders the MISSING shape the diagnostics skill matches on' {
        Get-FmBootstrapMissingDiagnostic -Tool 'tasks-axi' | Should -Be 'MISSING: tasks-axi (install: npm install -g tasks-axi)'
    }

    It 'renders MISSING_MANUAL for a tool with no automated route' -Skip:(-not $IsWindows) {
        # tmux is the last tool on this port with no scriptable install: there is
        # no native Windows build at all, so choosing another backend is a human
        # decision rather than a command.
        Get-FmBootstrapMissingDiagnostic -Tool 'tmux' |
            Should -Be 'MISSING_MANUAL: tmux (instructions: https://firstmate.invalid/windows-backends)'
    }

    It 'renders MISSING, not MISSING_MANUAL, for herdr' -Skip:(-not $IsWindows) {
        # herdr used to be listed as a manual install. Measured 2026-08-17:
        # herdr.dev publishes install.ps1 and install.sh, so telling the captain
        # to go and read a web page was sending them the long way round.
        #
        # THE ROUTE THEN MOVED AND THIS ASSERTION DID NOT. Any tool this repo
        # installs from a release archive now names install.ps1, because the
        # vendor one-liner was measured failing its own verification on two
        # clean VMs - docs/windows-e2e-evidence.md section 38.4. herdr has a
        # portable release, so Get-FmBootstrapMissingDiagnostic answers with the
        # command that actually does it. What this test still holds is the
        # shape: MISSING with a command, never MISSING_MANUAL with a web page.
        Get-FmBootstrapMissingDiagnostic -Tool 'herdr' |
            Should -Be 'MISSING: herdr (install: powershell -ExecutionPolicy Bypass -File .\install.ps1)'
    }
}

Describe 'Get-FmBootstrapBackendName' {
    BeforeEach {
        $script:TestHome = New-TestHome
        Set-TestHome -Path $script:TestHome
    }

    It 'defaults to tmux with no override' {
        Get-FmBootstrapBackendName -ConfigDir (Join-Path $script:TestHome 'config') | Should -Be 'tmux'
    }

    It 'honours config/backend' {
        Write-TestConfig -HomePath $script:TestHome -Name 'backend' -Content "herdr`n"
        Get-FmBootstrapBackendName -ConfigDir (Join-Path $script:TestHome 'config') | Should -Be 'herdr'
    }

    It 'honours the FM_BACKEND override ahead of config/backend' {
        Write-TestConfig -HomePath $script:TestHome -Name 'backend' -Content "herdr`n"
        $env:FM_BACKEND = 'zellij'
        Get-FmBootstrapBackendName -ConfigDir (Join-Path $script:TestHome 'config') | Should -Be 'zellij'
    }
}

Describe 'Get-FmBootstrapHandoffDiagnostic' {
    It 'counts undelivered items per secondmate outbox' {
        $home_ = New-TestHome
        Set-TestHome -Path $home_
        $handoff = Join-Path $home_ 'data' 'handoff'
        New-Item -ItemType Directory -Path $handoff -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $handoff 'atlas.outbox.md'), "- [ ] one`n- [x] two`nnot an item`n")
        $lines = @(Get-FmBootstrapHandoffDiagnostic -Paths (Get-FmSessionPaths))
        $lines[0] | Should -Be 'SECONDMATE_HANDOFF: secondmate atlas: pending delivery: 2 item(s)'
    }

    It 'is silent with no handoff directory' {
        $home_ = New-TestHome
        Set-TestHome -Path $home_
        @(Get-FmBootstrapHandoffDiagnostic -Paths (Get-FmSessionPaths)).Count | Should -Be 0
    }
}

Describe 'Set-FmBootstrapStartupMemoryBudget' {
    It 'materializes the visible default on a primary home' {
        $home_ = New-TestHome
        Set-TestHome -Path $home_
        @(Set-FmBootstrapStartupMemoryBudget -Paths (Get-FmSessionPaths)).Count | Should -Be 0
        $budget = Join-Path $home_ 'config' 'startup-memory-budget'
        # The file contract is LF-only with no BOM, so a Linux firstmate reading
        # this home sees exactly the same bytes.
        [System.IO.File]::ReadAllText($budget) | Should -Be "7500`n"
    }

    It 'stays passive in a secondmate home, whose value must converge from the primary' {
        $home_ = New-TestHome
        Set-TestHome -Path $home_
        [System.IO.File]::WriteAllText((Join-Path $home_ '.fm-secondmate-home'), "atlas`n")
        Set-FmBootstrapStartupMemoryBudget -Paths (Get-FmSessionPaths) | Out-Null
        Test-Path -LiteralPath (Join-Path $home_ 'config' 'startup-memory-budget') | Should -BeFalse
    }

    It 'reports an existing malformed budget rather than guessing at it' {
        $home_ = New-TestHome
        Set-TestHome -Path $home_
        Write-TestConfig -HomePath $home_ -Name 'startup-memory-budget' -Content "lots`n"
        @(Set-FmBootstrapStartupMemoryBudget -Paths (Get-FmSessionPaths))[0] |
            Should -Be 'STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - not a positive integer token count'
    }
}

Describe 'Invoke-FmBootstrap' {
    BeforeEach {
        $script:TestHome = New-TestHome
        Set-TestHome -Path $script:TestHome
        $env:FM_TASKS_AXI_COMPATIBLE = '1'
    }

    It 'detects only, and never installs, when told to detect only' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":"nope"}'
        $lines = @(Invoke-FmBootstrap -DetectOnly -Network skip)
        $lines | Should -Contain 'CREW_DISPATCH: invalid config/crew-dispatch.json - rules must be an array'
        # -DetectOnly skips the mutating sweeps, including budget materialization.
        Test-Path -LiteralPath (Join-Path $script:TestHome 'config' 'startup-memory-budget') | Should -BeFalse
    }

    It 'materializes the primary defaults on a full local run' {
        Invoke-FmBootstrap -Network skip | Out-Null
        Test-Path -LiteralPath (Join-Path $script:TestHome 'config' 'startup-memory-budget') | Should -BeTrue
    }

    It 'runs no local detection at all in the network-only phase' {
        Write-TestConfig -HomePath $script:TestHome -Name 'crew-dispatch.json' -Content '{"rules":"nope"}'
        $lines = @(Invoke-FmBootstrap -Network only -DetectOnly)
        $lines | Should -Not -Contain 'CREW_DISPATCH: invalid config/crew-dispatch.json - rules must be an array'
    }

    It 'calls a mutating sweep owner when that area is loaded, and only outside detect-only' {
        function Invoke-FmFleetSync { 'FLEET_SYNC: alpha: recovered: fast-forwarded' }
        try {
            @(Invoke-FmBootstrap -Network all -DetectOnly) | Should -Not -Contain 'FLEET_SYNC: alpha: recovered: fast-forwarded'
            @(Invoke-FmBootstrap -Network all) | Should -Contain 'FLEET_SYNC: alpha: recovered: fast-forwarded'
        } finally {
            Remove-Item -Path 'function:Invoke-FmFleetSync' -ErrorAction SilentlyContinue
        }
    }

    It 'reports an unresolvable backend rather than silently detecting the wrong tools' {
        $env:FM_BACKEND = 'nonesuch'
        $lines = @(Invoke-FmBootstrap -DetectOnly -Network skip)
        @($lines | Where-Object { $_ -like 'BACKEND_INVALID: nonesuch (known: *' }).Count | Should -Be 1
    }
}

Describe 'Install-FmTool' {
    It 'refuses to install without explicit approval and shows what it would run' {
        $out = @(Install-FmTool -Name 'tasks-axi')
        $out[0] | Should -Be 'refused: Install-FmTool needs -Approved. Bootstrap detects, then asks for consent, then installs - never installs unasked.'
        $out[1] | Should -Be 'would install tasks-axi: npm install -g tasks-axi'
    }

    It 'refuses a tool that has no automated install route' -Skip:(-not $IsWindows) {
        { Install-FmTool -Name 'tmux' -Approved } |
            Should -Throw 'error: tmux requires manual installation (instructions: https://firstmate.invalid/windows-backends)'
    }

    It 'offers herdr and treehouse from their own installers, never from npm' -Skip:(-not $IsWindows) {
        # The npm packages called `treehouse` and `herdr` are an unrelated web
        # framework and an empty 0.0.0 placeholder. Installing either exits 0 and
        # leaves the machine broken with nothing reporting it, so the refusal
        # this pins is against the wrong software rather than against no
        # software.
        foreach ($tool in @('herdr', 'treehouse')) {
            $out = @(Install-FmTool -Name $tool)
            $out[1] | Should -Not -Match 'npm'
            $out[1] | Should -Match 'install\.ps1'
        }
    }

    It 'refuses an unknown tool' {
        { Install-FmTool -Name 'nonesuch' -Approved } | Should -Throw 'error: unknown tool nonesuch'
    }

    It 'runs nothing under -WhatIf even when approved' {
        $out = @(Install-FmTool -Name 'tasks-axi' -Approved -WhatIf)
        $out.Count | Should -Be 0
    }
}
