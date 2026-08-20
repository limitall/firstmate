#requires -Version 7.0
# FmBootstrap.ps1 - bootstrap detection, ported from bin/fm-bootstrap.sh.
#
# DETECT FIRST, ASK CONSENT, THEN INSTALL. Detection prints one line per
# actionable problem and exits successfully; silence means all good. Nothing in
# this file installs anything. Installation is a separate, explicitly approved
# call (Install-FmTool -Approved), because AGENTS.md section 3 requires captain
# consent in the current session before any install runs.
#
# Diagnostic line shapes are kept byte-for-byte with the bash original, because
# the bootstrap-diagnostics skill matches on them:
#   "MISSING: <tool> (install: <command>)"
#   "MISSING_MANUAL: <tool> (instructions: <url>)"
#   "NEEDS_GH_AUTH"
#   "BACKEND_INVALID: <name> (known: <names>)"
#   "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>"
#   "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>"
#   "TANGLE: <remediation>"
#   "SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)"
#   "BOOTSTRAP_INFO: <completed no-action fact>"
#
# The six MUTATING sweeps (PR-check migration, secondmate convergence, secondmate
# liveness, pending remote handoff retry, X-mode artifact writes, fleet sync) are
# owned by other areas of this module. They are resolved by name at call time and
# skipped silently when that area is not loaded, exactly as -DetectOnly skips
# them; this file never reimplements them.

# --- install commands ---------------------------------------------------------
# Platform-aware on purpose. The line SHAPE is the contract the diagnostics skill
# reads; the command inside it has to actually run on the host being diagnosed,
# and `brew install tmux` is not a runnable instruction on Windows. The Linux
# branch keeps the bash strings verbatim so a mixed fleet reads the same advice.
#
# THIS IS THE ONE OWNER OF "WHERE DOES TOOL X COME FROM". install.ps1 drives the
# machine install from these answers rather than keeping a second table, and it
# keeps a second table for exactly as long as it takes the two to disagree.
# MEASURED, 2026-08-17: install.ps1 did keep one, and it said `npm install -g
# treehouse` and `npm install -g herdr`. Neither npm name is the software:
# `treehouse` on npm is an unrelated single-page-application state framework, and
# `herdr` on npm is a 0.0.0 placeholder that contains nothing. A machine
# following that table got a web framework instead of the worktree tool and an
# empty package instead of the session provider, with nothing saying so until
# dispatch failed later.
#
# EVERY WINDOWS ROUTE BELOW IS THE VENDOR'S OWN PUBLISHED INSTALLER, and each one
# was read before it was written down here. treehouse, herdr, Claude Code and
# PowerShell 7 all install into a per-user directory and add it to the USER PATH,
# so none of them needs administrator. The two that DO need it - the winget
# packages for git and Node.js, which run machine-scope MSIs - are declared as
# such by Test-FmBootstrapInstallNeedsAdministrator so the installer can name and
# skip them instead of crashing an unelevated run.

# EVERY WINGET COMMAND THIS REPO PRINTS OR RUNS IS BUILT HERE, so the flags that
# let one finish with nobody at the keyboard are stated once instead of once per
# package.
#
# MEASURED from the captain's install log, 2026-08-20, in an ADMINISTRATOR
# Windows PowerShell: `winget install OpenJS.NodeJS` exited 1 and installed
# nothing. winget asks the operator to accept its source agreements the first
# time it is used, and a run whose output is captured through a pipeline has
# nobody at that prompt - so it declines and exits 1. Elevation was never the
# problem: the same log shows winget v1.9.25200 present and running.
#
# --accept-source-agreements and --accept-package-agreements answer both
# agreements ahead of the prompt. `-e --id` matches ONE package by its exact
# identifier, because a bare `winget install <name>` is a SEARCH, and a search
# that matches several packages asks a second question nobody is there to
# answer either.
#
# --source winget PINS THE ONE SOURCE THESE PACKAGES COME FROM, so a source this
# repo does not use cannot fail an install it was never needed for.
#
# MEASURED from the captain's clean-VM install log, 2026-08-20, with the flags
# above already in: the Node.js route exited -1978335138 (0x8A15005E) and
# installed nothing, and winget's own words were "Failed when searching source:
# msstore ... The server certificate did not match any of the expected values",
# then "The following packages were found among the working sources. Please
# specify one of them using the --source option to proceed. Node.js
# OpenJS.NodeJS winget". The `winget` source was healthy and HAD the package.
# winget queries every configured source, and one erroring source is enough for
# it to stop and ask which to use - a question nobody is there to answer, so it
# exits without installing. A TLS-inspecting proxy, a clock skew or a
# locked-down image is enough to break msstore, and none of that is under this
# repo's control; every id named below is published on `winget`, and nothing
# here comes from the Store. Naming the source ahead of the question removes
# both the question and the whole dependency on the other source's health.
#
# THIS IS WHAT THE REPORTING FIX BOUGHT. The run before it reported the same
# failure as a bare `exited 1` with a fragment of winget's package table for a
# cause, and firstmate read that as needing administrator - twice, wrongly. The
# commit that made a failure carry its own exit code and the tool's own output
# is why the log above says the cause out loud and this took five minutes.
function Get-FmBootstrapWingetCommand {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [string]$Note = ''
    )

    $command = "winget install -e --id $PackageId --source winget --accept-source-agreements --accept-package-agreements"
    if ($Note) { return "$command  # $Note" }
    $command
}

function Get-FmBootstrapInstallCommand {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)

    if ($IsWindows) {
        switch ($Tool) {
            'node' { return (Get-FmBootstrapWingetCommand -PackageId 'OpenJS.NodeJS') }
            'git' { return (Get-FmBootstrapWingetCommand -PackageId 'Git.Git') }
            # The MSI winget runs is machine-scope, so it needs administrator.
            # firstmate's own installer prefers the portable zip from the same
            # project's releases, which does not - see Get-FmBootstrapPortableRelease.
            'gh' { return (Get-FmBootstrapWingetCommand -PackageId 'GitHub.cli' -Note 'or ./install.ps1, which uses the portable zip and needs no administrator') }
            'curl' { return (Get-FmBootstrapWingetCommand -PackageId 'cURL.cURL') }
            'jq' { return (Get-FmBootstrapWingetCommand -PackageId 'jqlang.jq') }
            'zellij' { return 'cargo install --locked zellij  # or the platform''s package manager' }
            # orca and cmux are NOT winget packages, and saying they were was the
            # same defect as the npm names above. MEASURED, winget v1.29.280,
            # 2026-08-20: `winget search -e --id orca` and `-e --id cmux` both
            # answer "No package found matching input criteria", while the six
            # ids this file does name resolve to exactly one package each. A
            # route that cannot succeed is worse than no route, because it is
            # reported as a step that failed rather than as one nobody can take.
            # Both are backends this port cannot drive anyway - Start-FmWorker
            # is [ValidateSet('herdr')] - so they answer as tmux does, by naming
            # a human step. Get-FmBootstrapManualInstallUrl owns that answer.
            { $_ -in 'tmux', 'orca', 'cmux' } { return $null }
            'claude' { return 'irm https://claude.ai/install.ps1 | iex' }
            'treehouse' { return 'irm https://kunchenguid.github.io/treehouse/install.ps1 | iex' }
            'herdr' { return 'irm https://herdr.dev/install.ps1 | iex' }
            'no-mistakes' { return 'irm https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.ps1 | iex' }
            { $_ -in 'gh-axi', 'chrome-devtools-axi', 'lavish-axi' } { return "npm install -g $Tool && $Tool setup hooks" }
            { $_ -in 'tasks-axi', 'quota-axi' } { return "npm install -g $Tool" }
            default { return $null }
        }
    }

    switch ($Tool) {
        { $_ -in 'tmux', 'node', 'git', 'gh', 'curl', 'jq', 'orca', 'zellij' } { return "brew install $Tool  # or the platform's package manager" }
        'cmux' { return 'brew install --cask cmux  # or see https://cmux.com' }
        'claude' { return 'curl -fsSL https://claude.ai/install.sh | bash' }
        'treehouse' { return 'curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh' }
        'herdr' { return 'curl -fsSL https://herdr.dev/install.sh | sh' }
        'no-mistakes' { return 'curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh' }
        { $_ -in 'gh-axi', 'chrome-devtools-axi', 'lavish-axi' } { return "npm install -g $Tool && $Tool setup hooks" }
        { $_ -in 'tasks-axi', 'quota-axi' } { return "npm install -g $Tool" }
        default { return $null }
    }
}

function Get-FmBootstrapManualInstallUrl {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)

    switch ($Tool) {
        # tmux has no native Windows build at all: a Windows home must select a
        # backend that does, so its absence is a manual, human decision.
        #
        # orca and cmux join it for a related reason. Neither is a winget package
        # - measured 2026-08-20, both answer "No package found matching input
        # criteria" - and this port drives neither, so there is no command to
        # print. The same human decision applies: choose a backend this port can
        # drive, or install the tool yourself.
        { $_ -in 'tmux', 'orca', 'cmux' } { if ($IsWindows) { return 'https://firstmate.invalid/windows-backends' } else { return $null } }
        default { return $null }
    }
}

# Does the published route for this tool run an installer that writes outside the
# user's own profile?
#
# Only the winget packages do. Both of them run a machine-scope MSI, which fails
# on a session that is not elevated - and fails LATE, after the download, with a
# message about the installer rather than about privilege. The installer asks
# this first so an unelevated run reports the step by name and carries on with
# everything else, rather than stopping on the first tool a locked-down machine
# will not accept.
function Test-FmBootstrapInstallNeedsAdministrator {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)

    $cmd = Get-FmBootstrapInstallCommand -Tool $Tool
    if (-not $cmd) { return $false }
    return ($cmd -match '^\s*winget\s')
}

# The no-administrator route for a tool whose vendor publishes a plain archive.
#
# THE PATTERN, MEASURED ON THIS MACHINE 2026-08-17. `choco install gh` failed
# with "Access to the path 'C:\ProgramData\chocolatey\lib-bad' is denied" in a
# session that had no elevation. What worked, with none: take the zip from the
# project's own release, expand it under %LOCALAPPDATA%\Programs\<tool>, and put
# that directory's bin on the USER PATH. gh, herdr and treehouse all sit in
# exactly that shape on the captain's machine today, which is why this is the
# pattern to prefer generally rather than a special case for one tool.
#
# Only gh is listed: treehouse, herdr and Claude Code publish their OWN
# installers that do the same thing, and re-deriving their release layout here
# would be a second copy of a contract those vendors already own.
function Get-FmBootstrapPortableRelease {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)

    if (-not $IsWindows) { return $null }
    if ($Tool -ne 'gh') { return $null }

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    [pscustomobject]@{
        Tool            = 'gh'
        Repository      = 'cli/cli'
        AssetPattern    = "gh_*_windows_$arch.zip"
        # The gh zip's root holds bin/ and LICENSE, so the expansion IS the
        # install directory and bin/ under it is what goes on PATH.
        BinSubdirectory = 'bin'
        StripRoot       = $false
    }
}

function Get-FmBootstrapMissingDiagnostic {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Tool)

    $instructions = Get-FmBootstrapManualInstallUrl -Tool $Tool
    if ($instructions) { return "MISSING_MANUAL: $Tool (instructions: $instructions)" }
    $cmd = Get-FmBootstrapInstallCommand -Tool $Tool
    if (-not $cmd) { return "MISSING_MANUAL: $Tool (instructions: unknown tool - no install route is registered)" }
    return "MISSING: $Tool (install: $cmd)"
}

# --- version floors -----------------------------------------------------------
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. Never lower
# a floor to the earliest release that happens to satisfy some depended-on
# behavior.
$script:FmBootstrapNoMistakesMin = '1.31.2'
$script:FmBootstrapGhAxiMin = '0.1.29'
$script:FmBootstrapLavishAxiMin = '0.1.46'
$script:FmBootstrapCommonTools = @('node', 'git', 'gh', 'no-mistakes', 'gh-axi', 'chrome-devtools-axi', 'lavish-axi', 'tasks-axi', 'quota-axi')

# A version string that cannot be parsed into exactly one major.minor.patch
# triple is incompatible, never assumed current, so a development or vendored
# build cannot pass a floor it was never checked against.
function Test-FmBootstrapToolVersionAtLeast {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Minimum
    )

    if (-not (Get-Command -Name $Tool -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    $res = Invoke-FmSessionCommandLine -Command $Tool -Arguments @('--version')
    if ($res.ExitCode -ne 0) { return $false }

    $found = $null
    foreach ($line in $res.Output) {
        $m = [regex]::Match($line, '[vV]?(\d+)\.(\d+)\.(\d+)')
        if ($m.Success) { $found = $m; break }
    }
    if (-not $found) { return $false }

    $minMatch = [regex]::Match($Minimum, '^(\d+)\.(\d+)\.(\d+)$')
    if (-not $minMatch.Success) { return $false }

    $have = [int[]]@($found.Groups[1].Value, $found.Groups[2].Value, $found.Groups[3].Value)
    $want = [int[]]@($minMatch.Groups[1].Value, $minMatch.Groups[2].Value, $minMatch.Groups[3].Value)
    for ($i = 0; $i -lt 3; $i++) {
        if ($have[$i] -gt $want[$i]) { return $true }
        if ($have[$i] -lt $want[$i]) { return $false }
    }
    return $true
}

function Test-FmBootstrapTreehouseSupportsLease {
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    $res = Invoke-FmSessionCommandLine -Command 'treehouse' -Arguments @('get', '--help')
    foreach ($line in $res.Output) {
        if ($line -match '(^|[^\w-])--lease([^\w-]|$)') { return $true }
    }
    return $false
}

# --- backend resolution -------------------------------------------------------
# Required-tool detection follows the RESOLVED backend, not a one-size default, so
# a herdr/zellij/cmux home is never told tmux is missing and only orca drops
# treehouse. The backend area owns this when it is loaded; the table below is the
# same verified dependency set, kept here so bootstrap detection still works in a
# partial module build.
$script:FmBootstrapBackendTools = @{
    tmux   = @('tmux', 'treehouse')
    herdr  = @('herdr', 'treehouse')
    zellij = @('zellij', 'treehouse')
    cmux   = @('cmux', 'treehouse')
    orca   = @('orca')
}

function Get-FmBootstrapBackendName {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $shared = Resolve-FmSessionCommand -Name 'Get-FmBackendName'
    if ($shared) {
        try { return [string](& $shared) } catch { Write-Debug "bootstrap: Get-FmBackendName owner failed; falling back to the local detection: $_" }
    }
    # Fallback for a partial module build: the explicit override, then the
    # configured backend, then tmux. Runtime auto-detection (the backend firstmate
    # itself is executing inside) belongs to the backend area and is deliberately
    # NOT guessed at here.
    if ($env:FM_BACKEND) { return $env:FM_BACKEND }
    $file = Join-Path $ConfigDir 'backend'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $value = ([System.IO.File]::ReadAllText($file) -replace '\s', '')
        if ($value) { return $value }
    }
    return 'tmux'
}

function Get-FmBootstrapBackendRequiredTool {
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Backend)

    $shared = Resolve-FmSessionCommand -Name 'Get-FmBackendRequiredTool'
    if ($shared) {
        try { return @(& $shared -Backend $Backend) } catch { return $null }
    }
    if ($script:FmBootstrapBackendTools.ContainsKey($Backend)) { return @($script:FmBootstrapBackendTools[$Backend]) }
    return $null
}

function Get-FmBootstrapKnownBackend {
    [OutputType([string])]
    [CmdletBinding()]
    param()

    $shared = Resolve-FmSessionCommand -Name 'Get-FmBackendKnown'
    if ($shared) {
        try { return [string](& $shared) } catch { Write-Debug "bootstrap: Get-FmBackendKnown owner failed; falling back to the local table: $_" }
    }
    return ($script:FmBootstrapBackendTools.Keys | Sort-Object) -join ' '
}

function Test-FmBootstrapBackendToolAvailable {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Backend,
        [Parameter(Mandatory)][string]$Tool
    )

    $shared = Resolve-FmSessionCommand -Name 'Test-FmBackendRequiredToolAvailable'
    if ($shared) {
        try { return [bool](& $shared -Backend $Backend -Tool $Tool) } catch { Write-Debug "bootstrap: Test-FmBackendRequiredToolAvailable owner failed; falling back to a PATH lookup: $_" }
    }
    return [bool](Get-Command -Name $Tool -CommandType Application -ErrorAction SilentlyContinue)
}

# --- local detection ----------------------------------------------------------

function Get-FmBootstrapLocalToolDiagnostic {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $out = @()
    $backend = Get-FmBootstrapBackendName -ConfigDir $ConfigDir
    $backendTools = Get-FmBootstrapBackendRequiredTool -Backend $backend
    if ($null -eq $backendTools) {
        $out += "BACKEND_INVALID: $backend (known: $(Get-FmBootstrapKnownBackend))"
        $backendTools = @()
    }

    foreach ($tool in $backendTools) {
        if (-not (Test-FmBootstrapBackendToolAvailable -Backend $backend -Tool $tool)) {
            $out += Get-FmBootstrapMissingDiagnostic -Tool $tool
        }
    }
    foreach ($tool in $script:FmBootstrapCommonTools) {
        if (-not (Get-Command -Name $tool -CommandType Application -ErrorAction SilentlyContinue)) {
            $out += Get-FmBootstrapMissingDiagnostic -Tool $tool
        }
    }

    # The treehouse lease-support upgrade check is only relevant when the resolved
    # backend actually requires treehouse; an orca home must not be told to
    # upgrade a provider it never uses.
    if (($backendTools -contains 'treehouse') -and
        (Get-Command -Name 'treehouse' -CommandType Application -ErrorAction SilentlyContinue) -and
        -not (Test-FmBootstrapTreehouseSupportsLease)) {
        $out += Get-FmBootstrapMissingDiagnostic -Tool 'treehouse'
    }

    foreach ($gate in @(
            @{ Tool = 'no-mistakes'; Min = $script:FmBootstrapNoMistakesMin },
            @{ Tool = 'gh-axi'; Min = $script:FmBootstrapGhAxiMin },
            @{ Tool = 'lavish-axi'; Min = $script:FmBootstrapLavishAxiMin }
        )) {
        if ((Get-Command -Name $gate.Tool -CommandType Application -ErrorAction SilentlyContinue) -and
            -not (Test-FmBootstrapToolVersionAtLeast -Tool $gate.Tool -Minimum $gate.Min)) {
            $out += Get-FmBootstrapMissingDiagnostic -Tool $gate.Tool
        }
    }

    # tasks-axi and quota-axi feature probes are separate defense-in-depth checks:
    # an installed but incompatible build reports MISSING so the operator upgrades
    # rather than silently running an older tool.
    if (Get-Command -Name 'quota-axi' -CommandType Application -ErrorAction SilentlyContinue) {
        $quota = Resolve-FmSessionCommand -Name 'Test-FmQuotaAxiCompatible'
        if ($quota) {
            $ok = $false
            try { $ok = [bool](& $quota) } catch { $ok = $false }
            if (-not $ok) { $out += Get-FmBootstrapMissingDiagnostic -Tool 'quota-axi' }
        }
    }
    if (Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue) {
        if (-not (Test-FmSessionTasksAxiCompatible)) { $out += Get-FmBootstrapMissingDiagnostic -Tool 'tasks-axi' }
    }

    $out
}

# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch. Scoped to the primary only; detached-HEAD
# worktrees and secondmate homes never trip it.
function Get-FmBootstrapTangleBranch {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $shared = Resolve-FmSessionCommand -Name 'Get-FmPrimaryTangleBranch'
    if ($shared) {
        try { return [string](& $shared -Root $Root) } catch { return '' }
    }

    $gitDir = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-dir')
    if ($gitDir.ExitCode -ne 0) { return '' }
    $common = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-common-dir')
    if ($common.ExitCode -ne 0) { return '' }
    # A linked worktree is a crewmate or scout checkout, never the primary.
    if (($gitDir.Output -join '') -ne ($common.Output -join '')) { return '' }

    $branch = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branch.ExitCode -ne 0) { return '' }
    $current = ($branch.Output | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($current)) { return '' }
    $default = Get-FmBootstrapDefaultBranch -Root $Root
    if ($current -eq $default) { return '' }
    return $current
}

function Get-FmBootstrapDefaultBranch {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $shared = Resolve-FmSessionCommand -Name 'Get-FmDefaultBranch'
    if ($shared) {
        try {
            $value = [string](& $shared -Root $Root)
            if ($value) { return $value }
        } catch { Write-Debug "bootstrap: Get-FmDefaultBranch owner failed; falling back to asking git directly: $_" }
    }
    $res = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if ($res.ExitCode -eq 0) {
        $ref = ($res.Output | Select-Object -First 1)
        if ($ref -match '/') { return ($ref -split '/')[-1] }
    }
    return 'main'
}

# config/crew-dispatch.json validation, ported off jq to native JSON parsing:
# nothing in this port shells out to a Unix text tool.
function Get-FmBootstrapCrewDispatchDiagnostic {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [switch]$VerboseFacts
    )

    $file = Join-Path $ConfigDir 'crew-dispatch.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }

    $verified = @('claude', 'codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'muse')
    $effortsByHarness = @{
        'claude'    = @('low', 'medium', 'high', 'xhigh', 'max')
        'codex'     = @('low', 'medium', 'high', 'xhigh')
        'grok'      = @('low', 'medium', 'high')
        'pi'        = @('low', 'medium', 'high', 'xhigh', 'max')
        'pi-signed' = @('low', 'medium', 'high', 'xhigh', 'max')
        'muse'      = @('low', 'medium', 'high', 'xhigh', 'max')
        'opencode'  = @()
        'kimi'      = @()
    }

    $doc = $null
    try {
        $doc = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable
    } catch {
        return @('CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON')
    }

    $fail = { param($reason) return @("CREW_DISPATCH: invalid config/crew-dispatch.json - $reason") }

    if ($doc -isnot [hashtable]) { return (& $fail 'top-level value must be an object') }

    $rules = @()
    if ($doc.ContainsKey('rules')) {
        if ($doc['rules'] -isnot [object[]]) { return (& $fail 'rules must be an array') }
        $rules = @($doc['rules'])
    }

    $profileList = {
        param($value)
        if ($value -is [object[]]) { return @($value) }
        if ($value -is [hashtable]) { return @($value) }
        return @()
    }

    foreach ($rule in $rules) {
        if ($rule -isnot [hashtable]) { return (& $fail 'each rule must be an object') }
        if (-not $rule.ContainsKey('when') -or $rule['when'] -isnot [string] -or $rule['when'].Length -eq 0) {
            return (& $fail 'each rule needs non-empty when')
        }
        if (-not $rule.ContainsKey('use') -or (($rule['use'] -isnot [hashtable]) -and ($rule['use'] -isnot [object[]]))) {
            return (& $fail 'each rule needs use')
        }
        if ($rule['use'] -is [object[]] -and @($rule['use']).Count -eq 0) {
            return (& $fail 'each rule needs at least one use profile')
        }
        foreach ($useProfile in (& $profileList $rule['use'])) {
            if ($useProfile -isnot [hashtable]) { return (& $fail 'each use profile must be an object') }
            if (-not $useProfile.ContainsKey('harness') -or $useProfile['harness'] -isnot [string] -or $useProfile['harness'].Length -eq 0) {
                return (& $fail 'each use profile needs harness')
            }
            foreach ($optional in @('model', 'effort')) {
                if ($useProfile.ContainsKey($optional) -and (($useProfile[$optional] -isnot [string]) -or $useProfile[$optional].Length -eq 0)) {
                    return (& $fail 'use profile model and effort must be non-empty strings when present')
                }
            }
        }
        if ($rule.ContainsKey('select')) {
            if ($rule['select'] -isnot [string] -or $rule['select'].Length -eq 0) {
                return (& $fail 'select must be a non-empty string')
            }
            if ($rule['select'] -ne 'quota-balanced') {
                return (& $fail "unknown select: $($rule['select'])")
            }
        }
    }

    if ($doc.ContainsKey('default')) {
        if (($doc['default'] -isnot [hashtable]) -and ($doc['default'] -isnot [object[]])) {
            return (& $fail 'default must be a profile object or non-empty profile array')
        }
        if ($doc['default'] -is [object[]] -and @($doc['default']).Count -eq 0) {
            return (& $fail 'default needs at least one profile')
        }
        foreach ($defaultProfile in (& $profileList $doc['default'])) {
            if ($defaultProfile -isnot [hashtable]) { return (& $fail 'each default profile must be an object') }
            if (-not $defaultProfile.ContainsKey('harness') -or $defaultProfile['harness'] -isnot [string] -or $defaultProfile['harness'].Length -eq 0) {
                return (& $fail 'each default profile needs harness')
            }
            foreach ($optional in @('model', 'effort')) {
                if ($defaultProfile.ContainsKey($optional) -and (($defaultProfile[$optional] -isnot [string]) -or $defaultProfile[$optional].Length -eq 0)) {
                    return (& $fail 'default profile model and effort must be non-empty strings when present')
                }
            }
        }
    }

    $configured = @()
    foreach ($rule in $rules) { $configured += (& $profileList $rule['use']) }
    if ($doc.ContainsKey('default')) { $configured += (& $profileList $doc['default']) }

    $badHarnesses = @($configured |
            Where-Object { $_ -is [hashtable] -and $_['harness'] -is [string] -and $verified -notcontains $_['harness'] } |
            ForEach-Object { $_['harness'] } | Select-Object -Unique)
    if ($badHarnesses.Count -gt 0) {
        return (& $fail ("unverified harness: " + ($badHarnesses -join ', ')))
    }

    $badEfforts = @($configured | Where-Object {
            $_ -is [hashtable] -and $_.ContainsKey('effort') -and $null -ne $_['effort'] -and
            $_['harness'] -is [string] -and $verified -contains $_['harness'] -and
            (($_['effort'] -isnot [string]) -or ($effortsByHarness[$_['harness']] -notcontains $_['effort']))
        } | ForEach-Object { "$($_['harness']):$($_['effort'])" } | Select-Object -Unique)
    if ($badEfforts.Count -gt 0) {
        return (& $fail ("invalid effort: " + ($badEfforts -join ', ')))
    }

    if (-not $VerboseFacts) { return @() }

    $describe = {
        param($p)
        $text = [string]$p['harness']
        if ($p.ContainsKey('model') -and $null -ne $p['model']) { $text += "/$($p['model'])" }
        elseif ($p.ContainsKey('effort') -and $null -ne $p['effort']) { $text += '/default' }
        if ($p.ContainsKey('effort') -and $null -ne $p['effort']) { $text += "/$($p['effort'])" }
        $text
    }
    $describeSet = {
        param($value, $selector)
        if ($value -is [object[]]) {
            $sel = if ($selector) { $selector } else { 'quota-balanced' }
            return "$sel[" + ((@($value) | ForEach-Object { & $describe $_ }) -join ', ') + ']'
        }
        return (& $describe $value)
    }

    $facts = @('BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json')
    foreach ($rule in $rules) {
        $facts += "BOOTSTRAP_INFO: crew dispatch rule: $($rule['when']) -> " + (& $describeSet $rule['use'] $rule['select'])
    }
    if ($doc.ContainsKey('default')) {
        $facts += 'BOOTSTRAP_INFO: crew dispatch default: ' + (& $describeSet $doc['default'] $null)
    }
    $facts
}

function Get-FmBootstrapLocalConfigDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Paths,
        [switch]$DetectOnly,
        [switch]$Locked,
        [switch]$VerboseFacts
    )

    $out = @()
    $tangleBranch = Get-FmBootstrapTangleBranch -Root $Paths.Root
    if (-not [string]::IsNullOrEmpty($tangleBranch)) {
        $default = Get-FmBootstrapDefaultBranch -Root $Paths.Root
        if ($DetectOnly -and -not $Locked) {
            $out += "TANGLE: primary checkout on feature branch '$tangleBranch' (expected '$default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
        } else {
            $out += "TANGLE: primary checkout on feature branch '$tangleBranch' (expected '$default'); the work is safe on that ref - restore the primary with: git -C $($Paths.Root) checkout $default, then re-validate the branch in a proper worktree"
        }
    }

    $crewFile = Join-Path $Paths.Config 'crew-harness'
    $crew = ''
    if (Test-Path -LiteralPath $crewFile -PathType Leaf) {
        $crew = ([System.IO.File]::ReadAllText($crewFile) -replace '\s', '')
    }
    if ($VerboseFacts -and $crew -and $crew -ne 'default') {
        $out += "BOOTSTRAP_INFO: crew harness override active: $crew"
    }

    $out += Get-FmBootstrapCrewDispatchDiagnostic -ConfigDir $Paths.Config -VerboseFacts:$VerboseFacts

    if ($VerboseFacts -and
        -not (Test-FmSessionBacklogBackendManual -ConfigDir $Paths.Config) -and
        (Test-FmSessionTasksAxiCompatible)) {
        $out += 'BOOTSTRAP_INFO: tasks-axi available'
    }

    $out
}

# state/handoff outbox detection: how many undelivered items a secondmate still
# owes. Read-only; the retry itself is a mutating sweep owned elsewhere.
function Get-FmBootstrapHandoffDiagnostic {
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    $handoffDir = Join-Path $Paths.Data 'handoff'
    if (-not (Test-Path -LiteralPath $handoffDir -PathType Container)) { return @() }

    $out = @()
    foreach ($outbox in @(Get-ChildItem -LiteralPath $handoffDir -Filter '*.outbox.md' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $id = $outbox.Name -replace '\.outbox\.md$', ''
        if ($id -match '[^A-Za-z0-9._-]' -or [string]::IsNullOrEmpty($id)) { $id = 'unknown' }
        if ($outbox -isnot [System.IO.FileInfo] -or $outbox.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
            $out += "SECONDMATE_HANDOFF: secondmate $id`: pending delivery: unsafe outbox"
            continue
        }
        $count = @(Get-FmSessionFileLines -Path $outbox.FullName | Where-Object { $_ -match '^- \[[ x]\] ' }).Count
        $out += "SECONDMATE_HANDOFF: secondmate $id`: pending delivery: $count item(s)"
    }
    $out
}

# config/startup-memory-budget: the primary publishes the visible default when
# absent. A secondmate home is deliberately passive - its value must converge
# from the primary rather than becoming a local authority.
function Set-FmBootstrapStartupMemoryBudget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Materializes the documented default for a config file bootstrap has already decided is missing; the diagnostic line reports the outcome.')]
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    foreach ($marker in @('.fm-secondmate-home')) {
        if (Test-Path -LiteralPath (Join-Path $Paths.Home $marker)) { return @() }
    }

    $shared = Resolve-FmSessionCommand -Name 'Set-FmStartupMemoryBudget'
    if ($shared) {
        try {
            & $shared -ConfigDir $Paths.Config | Out-Null
            return @()
        } catch {
            return @("STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - $([string]$_)")
        }
    }

    $file = Join-Path $Paths.Config 'startup-memory-budget'
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $value = ([System.IO.File]::ReadAllText($file) -replace '\s', '')
        if ($value -notmatch '^\d+$' -or [int]$value -le 0) {
            return @('STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - not a positive integer token count')
        }
        return @()
    }
    try {
        if (-not (Test-Path -LiteralPath $Paths.Config -PathType Container)) {
            New-Item -ItemType Directory -Path $Paths.Config -Force -ErrorAction Stop | Out-Null
        }
        Write-FmSessionTextFile -Path $file -Content "7500`n"
    } catch {
        return @('STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - could not materialize the default')
    }
    return @()
}

# --- the mutating sweeps ------------------------------------------------------
# Owned by other areas. Invoked by name when loaded, skipped when not; this file
# never reimplements one. Ordering matches bin/fm-bootstrap.sh so a `skip` run is
# the same output with the network lines removed, never a reshuffle.
function Invoke-FmBootstrapSweep {
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandName,
        [hashtable]$Parameters = @{}
    )

    $cmd = Resolve-FmSessionCommand -Name $CommandName
    if (-not $cmd) { return @() }
    try {
        return @(& $cmd @Parameters 2>&1 | ForEach-Object { [string]$_ })
    } catch {
        return @()
    }
}
