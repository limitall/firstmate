# fm-bootstrap.ps1 - bootstrap detection, best-effort fleet refresh/prune, and
# installs.
#
# Twin: bin/fm-bootstrap.sh
#
# Usage: fm-bootstrap.ps1
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)",
#                 "NETWORK_CHECKS: fleet lock ownership changed before <label>, ...",
#                 "WINDOWS_SETUP: <remediation>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the six MUTATING sweeps
#          (PR-check migration, secondmate_sync, secondmate_liveness_sweep,
#          secondmate_handoff_resume, x_mode_setup, fleet_sync) while still
#          printing every read-only detect line; the TANGLE line switches to
#          advisory-only wording with no checkout command.
#          Set FM_BOOTSTRAP_NETWORK to split this run by whether a step talks to
#          the network, so a session start can print its digest from local reads
#          alone and run the network half concurrently:
#            all  (default, and any unrecognized value) - everything, exactly as
#                 before. Unrecognized values fall back here on purpose: a typo
#                 must never silently skip a safety sweep.
#            skip - every LOCAL step, and none of the network ones. Skips
#                 `gh auth status`, the liveness sweep, the secondmate sync, the
#                 pending-handoff delivery, and the fleet sync.
#            only - ONLY those network steps and nothing else. No tool detection,
#                 no version floors, no tangle check, no PR-check migration, no
#                 x_mode_setup: those already ran on the local pass.
#          FM_BOOTSTRAP_DETECT_ONLY composes with it unchanged, so `only` plus
#          detect-only is the read-only `gh auth status` probe on its own.
#          bin/fm-startup-network.sh owns the deferral: it runs the `only` phase
#          in a detached bounded worker and publishes the result. This file stays
#          the single owner of every sweep, and the split changes only WHEN each
#          runs, never WHETHER.
#          A relaunch the liveness sweep performs during an `only` run is always
#          reported, because a digest composed before that run already printed the
#          superseded endpoint record.
#          FM_BOOTSTRAP_NETWORK_LOCK_PID, when set by that deferred worker, names
#          the fleet-lock owner the worker was launched for. Every mutating
#          network sweep rechecks state/.lock against it first, so a worker whose
#          session already handed the lock on refuses the sweep loudly rather than
#          racing the new owner.
#        fm-bootstrap.ps1 install <tool>...
#          Install the named tools (only ones the captain approved).
#
# The bash twin's header is the authoritative prose for every diagnostic's
# meaning, the winget routing, the version and feature gates, the fleet-sync
# timeout formula, and the X-mode opt-in contract. It is not restated here;
# what follows is only what a reader of the PowerShell twin needs that the bash
# reader does not.
#
# ===========================================================================
# THESE LINES ARE A PARSED INTERFACE
# ===========================================================================
# .agents/skills/bootstrap-diagnostics/ dispatches on the PREFIX of every line
# above, and AGENTS.md section 3 tells an agent to load that skill for any
# actionable line and to stay silent for BOOTSTRAP_INFO. So the line text, the
# prefixes, and the ORDER in which the sections emit are all contract, not
# formatting. Every string below is byte-identical to its bash twin, and the
# emission order is the bash file's top-to-bottom order:
#
#   pr-check migration -> startup memory budget -> backend validity -> backend
#   tools -> common tools -> treehouse lease -> no-mistakes -> quota-axi ->
#   tasks-axi -> gh auth -> tangle -> windows stubs -> crew harness fact ->
#   crew dispatch -> tasks-axi fact -> liveness -> secondmate sync -> pending
#   handoff delivery -> X mode -> fleet sync -> pending handoff detection.
#
# A phase-split run is that same sequence with one half's lines removed, never a
# reshuffle: `gh auth` sits between the two local blocks because that is where it
# has always sat.
#
# DETECT-ONLY MEANS DETECT-ONLY. Nothing above the FM_BOOTSTRAP_DETECT_ONLY
# guards writes anything, and fm-session-start's read-only path depends on that
# absolutely: it is what lets a SECOND concurrent session report the truth
# without racing the lock holder's sweeps.
#
# ===========================================================================
# FOUR DELIBERATE DIVERGENCES, EACH DOCUMENTED WHERE IT LIVES
# ===========================================================================
# 1. jq IS NOT A DEPENDENCY OF THE CREW-DISPATCH VALIDATOR HERE. The bash twin
#    prints "MISSING: jq" when config/crew-dispatch.json exists and jq does not,
#    because jq is its only JSON reader. PowerShell parses JSON in-process, so
#    there is nothing to be missing and the file is validated regardless. This
#    follows the precedent set by the converted hook guards: the divergence is
#    strictly in the direction of MORE checking, never less. jq remains a real
#    dependency of X mode, whose poll shim is a shell script, and that check is
#    unchanged.
# 2. THE FLEET-SYNC CHILD IS RESOLVED LOCALLY, not through Invoke-FmScript.
#    Invoke-FmScript captures to completion, and this call site must relay
#    PARTIAL output after killing a child that overran its timeout - which is
#    the whole point of the bash twin's background-job-plus-poll shape.
#    Resolve-FmBootstrapSibling applies Invoke-FmScript's EXACT resolution rule
#    (prefer a non-empty .ps1, else the .sh under Git Bash) so no extension is
#    hard-coded here either. Every other child in this file goes through
#    Invoke-FmScript.
# 3. THE X-MODE ARTIFACT WRITER PINS THE VOLUME, NOT THE DEVICE ID. The bash
#    twin passes `stat -c %d` of the parent to fm-x-lib's single-link
#    validators. fm-x-lib.psm1's device reader is module-private, so this file
#    performs the same-filesystem comparison itself against the path's volume
#    root and passes no device to the validators. The single-link, not-a-link
#    and mode gates those validators own are unchanged; only WHO compares the
#    filesystem moves.
# 4. SIGNALS AND umask HAVE NO WINDOWS TWIN (docs/powershell-port.md). The bash
#    fleet-sync path kills a process GROUP and the X-mode writer uses
#    `umask 077`; here the child is killed with its tree, and the temp file's
#    privacy rests on the same noacl acceptance the rest of the tree uses.
#    The `noacl` gates are deliberately NOT hardened (docs, "Things that must
#    NOT be improved").
#
# PRINTED PATHS ARE POSIX (contract 3): the TANGLE line contains a `git -C
# <root> checkout <branch>` command a captain may paste into either world.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-quota-axi-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tangle-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-config-inherit-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-startup-memory-budget-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-x-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$fmArgv = @($args)

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep. The comparison is case-SENSITIVE because the bash `case` is:
# `SKIP` is unrecognized there and must stay unrecognized here.
$script:FmNetworkPhase = 'all'
switch -CaseSensitive (Get-FmEnv 'FM_BOOTSTRAP_NETWORK' 'all') {
    'skip' { $script:FmNetworkPhase = 'skip' }
    'only' { $script:FmNetworkPhase = 'only' }
    default { $script:FmNetworkPhase = 'all' }
}

function Test-FmLocalPhase {
    [OutputType([bool])]
    param()
    return ($script:FmNetworkPhase -cne 'only')
}

function Test-FmNetworkPhase {
    [OutputType([bool])]
    param()
    return ($script:FmNetworkPhase -cne 'skip')
}

# The deferred worker inherits the fleet-lock owner it was launched for. With no
# such pid this is an ordinary in-session run and everything is authorized; with
# one, the CURRENT owner recorded in state/.lock must still be that pid.
function Test-FmNetworkMutationAuthorized {
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$StateDir)
    $expected = Get-FmEnv 'FM_BOOTSTRAP_NETWORK_LOCK_PID'
    if ($expected -eq '') { return $true }
    if ($expected -match '[^0-9]') { return $false }
    $lock = ConvertTo-FmNativePath (Join-Path $StateDir '.lock')
    if (-not [System.IO.File]::Exists($lock)) { return $false }
    if (Test-FmSymlink $lock) { return $false }
    # `current=$(cat ...)` strips trailing NEWLINES only, so a CR left by a
    # CRLF writer stays in the value and refuses the sweep in BOTH worlds
    # rather than in only one of them.
    $current = Get-FmFileText $lock
    $current = $current -replace "`n+$", ''
    return ($current -ceq $expected)
}

function Test-FmNetworkSweepAuthorized {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$Label
    )
    if (Test-FmNetworkMutationAuthorized -StateDir $StateDir) { return $true }
    Write-FmOut "NETWORK_CHECKS: fleet lock ownership changed before $Label, so this stale worker skipped that sweep"
    return $false
}

$script:FmSecondmateNudgeMessage = 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
$script:FmRespawnedSecondmateIds = @()

# --- small primitives ---------------------------------------------------------

# `command -v <tool> >/dev/null 2>&1` plus the run. Resolving through
# Get-Command first means a .cmd/.bat npm shim is found the same way PATH lookup
# finds it for bash, and a missing tool answers 127 rather than throwing.
function Invoke-FmBootstrapTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0
    )
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) {
        return @{ ExitCode = 127; StdOut = ''; StdErr = ''; Ok = $false }
    }
    $call = @{ FilePath = $cmd.Source; Arguments = $Arguments }
    if ($TimeoutSeconds -gt 0) { $call['TimeoutSeconds'] = $TimeoutSeconds }
    return Invoke-FmTool @call
}

# Windows (Git Bash/MSYS2/Cygwin) remedy routing. The bash predicate reads
# $OSTYPE, which describes the SHELL's platform; a PowerShell twin has no
# OSTYPE and asks the platform directly. Same verdict, same one-line remedy
# switch, and false everywhere else exactly as the bash is.
function Test-FmBootstrapWindowsHost {
    return (Test-FmWindows)
}

# winget package IDs, each verified against the live winget source on Windows 11.
function Get-FmWingetInstallCommand {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tool)
    $id = switch -CaseSensitive ($Tool) {
        'jq' { 'jqlang.jq' }
        'node' { 'OpenJS.NodeJS.LTS' }
        'gh' { 'GitHub.cli' }
        'curl' { 'cURL.cURL' }
        default { $null }
    }
    if ($null -eq $id) { return $null }
    return "winget install --id $id -e --accept-source-agreements --accept-package-agreements"
}

function Get-FmManualInstallUrl {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tool)
    switch -CaseSensitive ($Tool) {
        'herdr' { return 'https://herdr.dev' }
        'tmux' {
            # tmux has no native Windows build and no winget package: on Git Bash
            # it comes from an MSYS2 installation, which docs/windows.md owns.
            # Reporting it as MANUAL also keeps `install tmux` from running a brew
            # command that cannot work there.
            if (-not (Test-FmBootstrapWindowsHost)) { return $null }
            return 'docs/windows.md'
        }
        default { return $null }
    }
}

# $null when the tool has no runnable install command, which is the `return 1`
# the bash callers branch on.
function Get-FmInstallCommand {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tool)
    # A tool routed to manual instructions has no runnable install command.
    if ($null -ne (Get-FmManualInstallUrl $Tool)) { return $null }
    if (Test-FmBootstrapWindowsHost) {
        $winget = Get-FmWingetInstallCommand $Tool
        if ($null -ne $winget) { return $winget }
    }
    switch -CaseSensitive ($Tool) {
        { $_ -cin @('tmux', 'node', 'git', 'gh', 'curl', 'jq', 'orca', 'zellij') } {
            return "brew install $Tool  # or the platform's package manager"
        }
        'cmux' { return 'brew install --cask cmux  # or see https://cmux.com' }
        'treehouse' { return 'curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh' }
        'no-mistakes' { return 'curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh' }
        { $_ -cin @('gh-axi', 'chrome-devtools-axi', 'lavish-axi') } {
            return "npm install -g $Tool && $Tool setup hooks"
        }
        { $_ -cin @('tasks-axi', 'quota-axi') } { return "npm install -g $Tool" }
        default { return $null }
    }
}

function Write-FmMissingToolDiagnostic {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tool)
    $instructions = Get-FmManualInstallUrl $Tool
    if ($null -ne $instructions) {
        Write-FmOut "MISSING_MANUAL: $Tool (instructions: $instructions)"
        return
    }
    # An unknown tool leaves the substitution EMPTY in bash rather than failing,
    # so the line still names the tool. Preserved.
    $cmd = Get-FmInstallCommand $Tool
    if ($null -eq $cmd) { $cmd = '' }
    Write-FmOut "MISSING: $Tool (install: $cmd)"
}

function Test-FmTreehouseSupportsLease {
    $result = Invoke-FmBootstrapTool -Name 'treehouse' -Arguments @('get', '--help')
    $text = $result.StdOut + $result.StdErr
    # grep -E anchors are per LINE, hence Multiline.
    return [regex]::IsMatch($text, '(^|[^a-zA-Z0-9_-])--lease([^a-zA-Z0-9_-]|$)',
        [System.Text.RegularExpressions.RegexOptions]::Multiline)
}

# Shared semantic-version floor. A version string that cannot be parsed into
# exactly one major.minor.patch triple is INCOMPATIBLE, never assumed current, so
# a development or vendored build cannot pass a floor it was never checked
# against.
function Test-FmToolVersionAtLeast {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string]$Minimum
    )
    if (-not (Test-FmCommand $Tool)) { return $false }
    $result = Invoke-FmBootstrapTool -Name $Tool -Arguments @('--version')
    if (-not $result.Ok) { return $false }

    # `sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1`.
    # The leading `.*` is greedy in both engines, so the LAST triple on the first
    # matching line wins - a real difference for "tasks-axi 0.1.1 (node 20.1.1)".
    $major = $null
    foreach ($line in ($result.StdOut -split "`n")) {
        $m = [regex]::Match($line, '^.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*$')
        if ($m.Success) {
            $major = [int]$m.Groups[1].Value
            $minor = [int]$m.Groups[2].Value
            $patch = [int]$m.Groups[3].Value
            break
        }
    }
    if ($null -eq $major) { return $false }

    $minParts = @($Minimum.Split('.'))
    if ($minParts.Count -ne 3) { return $false }
    foreach ($p in $minParts) { if ($p -notmatch '^[0-9]+$') { return $false } }
    $minMajor = [int]$minParts[0]
    $minMinor = [int]$minParts[1]
    $minPatch = [int]$minParts[2]

    if ($major -gt $minMajor) { return $true }
    if ($major -ne $minMajor) { return $false }
    if ($minor -gt $minMinor) { return $true }
    if ($minor -ne $minMinor) { return $false }
    return ($patch -ge $minPatch)
}

# `$(cmd 2>&1)` for a firstmate function that reports through Write-FmOut /
# Write-FmErr, which write to the raw console rather than the PowerShell
# pipeline. Both streams land in one buffer so the merge order matches the
# bash twin's. fm-common is imported WITHOUT -Force everywhere in this tree
# precisely so a nested import cannot reset [Console]::Out underneath this.
function Invoke-FmCapturedConsole {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $origOut = [Console]::Out
    $origErr = [Console]::Error
    $writer = [System.IO.StringWriter]::new()
    try {
        [Console]::SetOut($writer)
        [Console]::SetError($writer)
        & $Body | Out-Null
    } finally {
        [Console]::SetOut($origOut)
        [Console]::SetError($origErr)
    }
    return ($writer.ToString() -replace "`r`n", "`n")
}

# Invoke-FmScript's resolution rule, applied locally. See divergence 2 in the
# header for why this one call site cannot go through Invoke-FmScript itself.
function Resolve-FmBootstrapSibling {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BinDir
    )
    $psTwin = Join-Path $BinDir "$Name.ps1"
    $shTwin = Join-Path $BinDir "$Name.sh"
    if ((Test-Path -LiteralPath $psTwin) -and ((Get-Item -LiteralPath $psTwin).Length -gt 0)) {
        $exe = (Get-Process -Id $PID).Path
        if (-not $exe) { $exe = 'pwsh' }
        return @{ File = $exe; Prefix = @('-NoProfile', '-File', $psTwin) }
    }
    if (Test-Path -LiteralPath $shTwin) {
        $bash = Get-FmBash
        if (-not $bash) { return $null }
        return @{ File = $bash; Prefix = @((ConvertTo-FmPosixPath $shTwin)) }
    }
    return $null
}

# Run a sibling with per-child environment, then restore: the twin of bash's
# `VAR=1 cmd` prefix form, which PowerShell has no equivalent of.
function Invoke-FmBootstrapChild {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [Parameter(Mandatory)][string]$BinDir
    )
    $saved = @{}
    foreach ($key in $Environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
    try {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
        return (Invoke-FmScript -Name $Name -Arguments $Arguments -BinDir $BinDir)
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}

# --- crew-dispatch validation -------------------------------------------------

$script:FmVerifiedHarness = @('claude', 'codex', 'opencode', 'pi', 'pi-signed', 'grok', 'kimi', 'muse')

function Test-FmDispatchEffortOk {
    param(
        [AllowNull()][object]$Harness,
        [AllowNull()][object]$Effort
    )
    if ($null -eq $Effort) { return $true }
    if ($Effort -isnot [string]) { return $false }
    switch -CaseSensitive ([string]$Harness) {
        'claude' { return ([bool](@('low', 'medium', 'high', 'xhigh', 'max') -ccontains $Effort)) }
        'codex' { return ([bool](@('low', 'medium', 'high', 'xhigh') -ccontains $Effort)) }
        'grok' { return ([bool](@('low', 'medium', 'high') -ccontains $Effort)) }
        { $_ -ceq 'pi' -or $_ -ceq 'pi-signed' } {
            return ([bool](@('low', 'medium', 'high', 'xhigh', 'max') -ccontains $Effort))
        }
        'muse' { return ([bool](@('low', 'medium', 'high', 'xhigh', 'max') -ccontains $Effort)) }
        { $_ -ceq 'opencode' -or $_ -ceq 'kimi' } { return $false }
        default { return $true }
    }
}

# jq's `profiles($value)`: an array is itself, an object is a one-element list,
# anything else is empty.
function Get-FmDispatchProfileList {
    param([AllowNull()][object]$Value)
    if ($Value -is [System.Collections.IList]) { return @($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value) }
    return @()
}

function Test-FmDispatchHasKey {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Key)
    if ($Object -isnot [System.Collections.IDictionary]) { return $false }
    return $Object.Contains($Key)
}

function Get-FmDispatchValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-FmDispatchHasKey $Object $Key)) { return $null }
    return $Object[$Key]
}

function Test-FmDispatchMalformedOptionalField {
    param([object[]]$Items)
    foreach ($item in $Items) {
        foreach ($key in @('model', 'effort')) {
            if (Test-FmDispatchHasKey $item $key) {
                $v = Get-FmDispatchValue $item $key
                if ($v -isnot [string]) { return $true }
                if ([string]$v -eq '') { return $true }
            }
        }
    }
    return $false
}

# The jq if/elif chain, in ORDER: the FIRST matching condition is the reported
# error, so reordering these would change which message a malformed file gets.
# Returns '' when the file is valid.
function Get-FmDispatchValidationError {
    param([AllowNull()][object]$Doc)

    if ($Doc -isnot [System.Collections.IDictionary]) { return 'top-level value must be an object' }
    if ((Test-FmDispatchHasKey $Doc 'rules') -and ($Doc['rules'] -isnot [System.Collections.IList])) {
        return 'rules must be an array'
    }
    $rules = @()
    if (Test-FmDispatchHasKey $Doc 'rules') { $rules = @($Doc['rules']) }

    foreach ($rule in $rules) {
        if ($rule -isnot [System.Collections.IDictionary]) { return 'each rule must be an object' }
    }
    foreach ($rule in $rules) {
        $when = Get-FmDispatchValue $rule 'when'
        if (($when -isnot [string]) -or ([string]$when -eq '')) { return 'each rule needs non-empty when' }
    }
    foreach ($rule in $rules) {
        $use = Get-FmDispatchValue $rule 'use'
        if (($use -isnot [System.Collections.IDictionary]) -and ($use -isnot [System.Collections.IList])) {
            return 'each rule needs use'
        }
    }
    foreach ($rule in $rules) {
        $use = Get-FmDispatchValue $rule 'use'
        if (($use -is [System.Collections.IList]) -and (@($use).Count -eq 0)) {
            return 'each rule needs at least one use profile'
        }
    }
    $ruleProfiles = @()
    foreach ($rule in $rules) { $ruleProfiles += Get-FmDispatchProfileList (Get-FmDispatchValue $rule 'use') }
    foreach ($p in $ruleProfiles) {
        if ($p -isnot [System.Collections.IDictionary]) { return 'each use profile must be an object' }
    }
    foreach ($p in $ruleProfiles) {
        $h = Get-FmDispatchValue $p 'harness'
        if (($h -isnot [string]) -or ([string]$h -eq '')) { return 'each use profile needs harness' }
    }
    if (Test-FmDispatchMalformedOptionalField $ruleProfiles) {
        return 'use profile model and effort must be non-empty strings when present'
    }
    foreach ($rule in $rules) {
        if (Test-FmDispatchHasKey $rule 'select') {
            $s = Get-FmDispatchValue $rule 'select'
            if (($s -isnot [string]) -or ([string]$s -eq '')) { return 'select must be a non-empty string' }
        }
    }
    $unknownSelects = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $rules) {
        $s = Get-FmDispatchValue $rule 'select'
        if ($null -eq $s) { continue }
        if (([string]$s) -cne 'quota-balanced' -and -not $unknownSelects.Contains([string]$s)) {
            $unknownSelects.Add([string]$s)
        }
    }
    if ($unknownSelects.Count -gt 0) {
        # jq's `unique` SORTS as well as dedupes, by codepoint - hence an ORDINAL
        # sort, not Sort-Object's culture-aware default, which would order
        # "Zulu" before "apple" differently from jq.
        $unknownSelects.Sort([System.StringComparer]::Ordinal)
        return 'unknown select: ' + ($unknownSelects -join ', ')
    }

    $defaultProfiles = @()
    if (Test-FmDispatchHasKey $Doc 'default') {
        $def = $Doc['default']
        if (($def -isnot [System.Collections.IDictionary]) -and ($def -isnot [System.Collections.IList])) {
            return 'default must be a profile object or non-empty profile array'
        }
        if (($def -is [System.Collections.IList]) -and (@($def).Count -eq 0)) {
            return 'default needs at least one profile'
        }
        $defaultProfiles = Get-FmDispatchProfileList $def
        foreach ($p in $defaultProfiles) {
            if ($p -isnot [System.Collections.IDictionary]) { return 'each default profile must be an object' }
        }
        foreach ($p in $defaultProfiles) {
            $h = Get-FmDispatchValue $p 'harness'
            if (($h -isnot [string]) -or ([string]$h -eq '')) { return 'each default profile needs harness' }
        }
        if (Test-FmDispatchMalformedOptionalField $defaultProfiles) {
            return 'default profile model and effort must be non-empty strings when present'
        }
    }

    $configured = @($ruleProfiles) + @($defaultProfiles)
    $badHarness = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $configured) {
        $h = Get-FmDispatchValue $p 'harness'
        if ($null -eq $h) { continue }
        if (($script:FmVerifiedHarness -ccontains [string]$h)) { continue }
        if (-not $badHarness.Contains([string]$h)) { $badHarness.Add([string]$h) }
    }
    if ($badHarness.Count -gt 0) {
        $badHarness.Sort([System.StringComparer]::Ordinal)
        return 'unverified harness: ' + ($badHarness -join ', ')
    }

    $badEffort = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $configured) {
        $h = Get-FmDispatchValue $p 'harness'
        $e = Get-FmDispatchValue $p 'effort'
        if ($null -eq $e) { continue }
        if ($h -isnot [string]) { continue }
        if (-not ($script:FmVerifiedHarness -ccontains [string]$h)) { continue }
        if (Test-FmDispatchEffortOk $h $e) { continue }
        $entry = "$h`:$e"
        if (-not $badEffort.Contains($entry)) { $badEffort.Add($entry) }
    }
    if ($badEffort.Count -gt 0) {
        $badEffort.Sort([System.StringComparer]::Ordinal)
        return 'invalid effort: ' + ($badEffort -join ', ')
    }
    return ''
}

function Get-FmDispatchProfileText {
    # Named ProfileObject, not Profile: $PROFILE is a PowerShell automatic
    # variable and shadowing it in a parameter is an analyzer finding.
    param([AllowNull()][object]$ProfileObject)
    $h = Get-FmDispatchValue $ProfileObject 'harness'
    $model = Get-FmDispatchValue $ProfileObject 'model'
    $effort = Get-FmDispatchValue $ProfileObject 'effort'
    $text = [string]$h
    if ($null -ne $model) { $text += '/' + [string]$model }
    elseif ($null -ne $effort) { $text += '/default' }
    if ($null -ne $effort) { $text += '/' + [string]$effort }
    return $text
}

function Get-FmDispatchProfileSetText {
    param([AllowNull()][object]$Value, [AllowNull()][object]$Selector)
    if ($Value -is [System.Collections.IList]) {
        $sel = if ($null -eq $Selector) { 'quota-balanced' } else { [string]$Selector }
        $parts = @()
        foreach ($p in @($Value)) { $parts += Get-FmDispatchProfileText $p }
        return $sel + '[' + ($parts -join ', ') + ']'
    }
    return Get-FmDispatchProfileText $Value
}

function Invoke-FmCrewDispatchValidate {
    param([Parameter(Mandatory)][string]$ConfigDir)
    $file = Join-Path $ConfigDir 'crew-dispatch.json'
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $file))) { return }

    $doc = $null
    try {
        $doc = Get-FmFileText $file | ConvertFrom-Json -AsHashtable -Depth 40
    } catch {
        Write-FmOut 'CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON'
        return
    }
    if ($null -eq $doc) {
        # `jq -e .` fails on an empty document and on a bare `null`.
        Write-FmOut 'CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON'
        return
    }

    $err = Get-FmDispatchValidationError $doc
    if ($err -ne '') {
        Write-FmOut "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
        return
    }
    if ((Get-FmEnv 'FM_BOOTSTRAP_VERBOSE_FACTS' '0') -ceq '1') {
        Write-FmOut 'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json'
        $rules = @()
        if (Test-FmDispatchHasKey $doc 'rules') { $rules = @($doc['rules']) }
        foreach ($rule in $rules) {
            $when = Get-FmDispatchValue $rule 'when'
            $set = Get-FmDispatchProfileSetText (Get-FmDispatchValue $rule 'use') (Get-FmDispatchValue $rule 'select')
            Write-FmOut ('BOOTSTRAP_INFO: crew dispatch rule: ' + [string]$when + ' -> ' + $set)
        }
        if (Test-FmDispatchHasKey $doc 'default') {
            Write-FmOut ('BOOTSTRAP_INFO: crew dispatch default: ' +
                (Get-FmDispatchProfileSetText $doc['default'] $null))
        }
    }
}

# --- Windows checkout integrity (DETECT ONLY, Windows only) -------------------

function Test-FmWindowsSymlinkStub {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-FmBootstrapWindowsHost)) { return }
    $broken = ''
    $claudeMd = ConvertTo-FmNativePath (Join-Path $Root 'CLAUDE.md')
    if ([System.IO.File]::Exists($claudeMd) -and -not (Test-FmSymlink $claudeMd)) {
        # Git writes the stub with no trailing newline; `head -c 4096` then
        # `tr -d '\r'` is reproduced so a stub an editor merely re-saved still
        # classifies as one. bin/fm-windows-setup.sh's is_stub_file uses the
        # identical comparison.
        $head = ''
        try {
            $bytes = [System.IO.File]::ReadAllBytes($claudeMd)
            $take = [Math]::Min(4096, $bytes.Length)
            $head = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $take) -replace "`r", ''
        } catch { $head = '' }
        if ($head -ceq 'AGENTS.md') { $broken = 'CLAUDE.md' }
    }
    # A regular FILE where the skills directory belongs is unambiguous: a real
    # symlink, a directory junction, and a plain copied directory are all -d.
    $skills = ConvertTo-FmNativePath (Join-Path $Root '.claude/skills')
    if ([System.IO.File]::Exists($skills) -and -not (Test-FmSymlink $skills)) {
        $broken = if ($broken -eq '') { '.claude/skills' } else { "$broken, .claude/skills" }
    }
    if ($broken -eq '') { return }
    Write-FmOut "WINDOWS_SETUP: tracked symlinks are checked out as plain stub files ($broken); the agent instruction surface will not load until they are materialized - repair with: bash bin/fm-windows-setup.sh"
}

# --- startup memory budget ----------------------------------------------------

function Initialize-FmBootstrapStartupMemoryBudget {
    param([Parameter(Mandatory)][string]$HomePath, [Parameter(Mandatory)][string]$ConfigDir)
    # A secondmate is deliberately passive here: its setting must converge from
    # the primary through the inherited-local-material contract rather than
    # becoming a local authority.
    $marker = ConvertTo-FmNativePath (Join-Path $HomePath '.fm-secondmate-home')
    if ([System.IO.File]::Exists($marker) -or [System.IO.Directory]::Exists($marker) -or (Test-FmSymlink $marker)) {
        return
    }
    if (-not (Initialize-FmStartupMemoryBudget -ConfigDir $ConfigDir)) {
        Write-FmOut ("STARTUP_MEMORY_BUDGET: invalid config/$(Get-FmStartupMemoryBudgetFileName) - $(Get-FmStartupMemoryBudgetError)")
    }
}

# --- secondmate liveness ------------------------------------------------------

# `for f in "$STATE"/*.meta` - sorted, dot-prefixed leaves excluded (a bash glob
# never matches a leading dot, and state/ is full of dot-prefixed internals).
function Get-FmBootstrapMetaFile {
    param([Parameter(Mandatory)][string]$StateDir)
    $native = ConvertTo-FmNativePath $StateDir
    $found = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($native, '*.meta')) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($leaf.StartsWith('.')) { continue }
        if (-not $leaf.EndsWith('.meta', [System.StringComparison]::Ordinal)) { continue }
        $found.Add($file)
    }
    $found.Sort([System.StringComparer]::Ordinal)
    return @($found)
}

function Test-FmMetaHasExactLine {
    param([Parameter(Mandatory)][string]$MetaPath, [Parameter(Mandatory)][string]$Line)
    foreach ($l in (Get-FmFileLines $MetaPath)) { if ($l -ceq $Line) { return $true } }
    return $false
}

function Test-FmMetaHasLinePrefix {
    param([Parameter(Mandatory)][string]$MetaPath, [Parameter(Mandatory)][string]$Prefix)
    foreach ($l in (Get-FmFileLines $MetaPath)) { if ($l.StartsWith($Prefix)) { return $true } }
    return $false
}

function Invoke-FmSecondmateLivenessSweep {
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$Root
    )
    # SESSION START ONLY. The detailed state machine and its only
    # recovery-authorizing states are owned by Get-FmBackendAgentState: a missing
    # pane is not enough, the backend must PROVE the endpoint absent. That is what
    # preserves duplicate prevention for an ambiguous process and for every
    # transiently unreadable target.
    $script:FmRespawnedSecondmateIds = @()
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $StateDir))) { return }
    $verbose = ((Get-FmEnv 'FM_BOOTSTRAP_VERBOSE_FACTS' '0') -ceq '1')

    foreach ($meta in (Get-FmBootstrapMetaFile $StateDir)) {
        if (-not (Test-FmMetaHasExactLine $meta 'kind=secondmate')) { continue }
        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
        $window = Get-FmMetaValue -MetaPath $meta -Key 'window'
        if ([string]::IsNullOrEmpty($window)) { continue }
        $harness = Get-FmMetaValue -MetaPath $meta -Key 'harness'
        $backend = Get-FmBackendOfMeta $meta
        $target = Get-FmBackendTargetOfMeta $meta
        if ([string]::IsNullOrEmpty($target)) { $target = $window }

        $agentState = ''
        try { $agentState = Get-FmBackendAgentState $backend $target } catch { $agentState = '' }
        if ([string]::IsNullOrEmpty($agentState)) { $agentState = 'unreadable' }

        if (-not ($script:FmVerifiedHarness -ccontains $harness)) {
            if ($agentState -ceq 'dead' -or $agentState -ceq 'missing') { $agentState = 'unverified-harness' }
        }

        switch -CaseSensitive ($agentState) {
            'alive' {
                if ($verbose) { Write-FmOut "BOOTSTRAP_INFO: secondmate $id already live (backend=$backend)" }
            }
            { $_ -ceq 'dead' -or $_ -ceq 'missing' } {
                $cause = if ($agentState -ceq 'dead') {
                    try { $null = Remove-FmBackendTarget $backend $target } catch { $null = $_ }
                    'confirmed agent absence on existing endpoint'
                } else {
                    'recorded endpoint confidently missing'
                }
                $spawn = Invoke-FmBootstrapChild -Name 'fm-spawn' -BinDir (Join-Path $Root 'bin') `
                    -Arguments @($id, '--secondmate') -Environment @{ FM_SPAWN_NO_GUARD = '1' }
                if ($spawn.Ok) {
                    $script:FmRespawnedSecondmateIds += $id
                    # A relaunch replaces the endpoint record a digest may already
                    # have printed. On the local pass that digest has not been
                    # composed yet, so the fact stays behind the verbose flag as
                    # before; on the deferred network pass the digest is already
                    # out, so reporting it is what keeps the superseded record
                    # from being acted on.
                    if ($verbose -or -not (Test-FmLocalPhase)) {
                        Write-FmOut "BOOTSTRAP_INFO: secondmate $id relaunched after $cause (backend=$backend)"
                    }
                } else {
                    $detail = Get-FmFfFirstLine -Text (($spawn.StdOut + $spawn.StdErr).TrimEnd("`n"))
                    Write-FmOut "SECONDMATE_LIVENESS: secondmate ${id}: respawn failed after ${cause}: $detail"
                }
            }
            'ambiguous' {
                Write-FmOut "SECONDMATE_LIVENESS: secondmate ${id}: skipped: existing endpoint has ambiguous agent process (backend=$backend)"
            }
            'unreadable' {
                Write-FmOut "SECONDMATE_LIVENESS: secondmate ${id}: skipped: endpoint probe unreadable (backend=$backend)"
            }
            'unverified-harness' {
                Write-FmOut "SECONDMATE_LIVENESS: secondmate ${id}: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)"
            }
            default {
                Write-FmOut "SECONDMATE_LIVENESS: secondmate ${id}: skipped: agent recovery classifier unverified (backend=$backend)"
            }
        }
    }
}

# --- secondmate sync ----------------------------------------------------------

# `case "$1" in *[!/A-Za-z0-9._-]*|""|*/*) return 1` - the id must be non-empty,
# hold only that character set, and contain no separator. $null means refused.
function Get-FmSecondmateNudgeMarkerPath {
    param([Parameter(Mandatory)][string]$PendingDir, [AllowEmptyString()][AllowNull()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $null }
    if ($Id -notmatch '^[/A-Za-z0-9._-]+$') { return $null }
    if ($Id.Contains('/')) { return $null }
    return (Join-Path $PendingDir "$Id.pending")
}

function Save-FmSecondmateNudgeMarker {
    param(
        [Parameter(Mandatory)][string]$PendingDir,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$HomePath,
        [AllowEmptyString()][string]$Commit,
        [AllowEmptyString()][string]$Instructions
    )
    $marker = Get-FmSecondmateNudgeMarkerPath $PendingDir $Id
    if ($null -eq $marker) { return $false }
    try {
        $null = [System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $PendingDir))
    } catch { return $false }
    $body = "id=$Id`nselector=fm-$Id`nhome=$HomePath`ncommit=$Commit`ninstructions=$Instructions`nmessage=$script:FmSecondmateNudgeMessage`n"
    return (Set-FmFileTextAtomic -Path $marker -Text $body -NoNewline)
}

function Send-FmSecondmateNudge {
    param(
        [Parameter(Mandatory)][hashtable]$Ctx,
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyString()][string]$HomePath,
        [AllowEmptyString()][string]$Commit,
        [AllowEmptyString()][string]$Instructions
    )
    $selector = "fm-$Id"
    $marker = Get-FmSecondmateNudgeMarkerPath $Ctx.PendingDir $Id
    if ($null -eq $marker) {
        Write-FmOut "NUDGE_SECONDMATES: secondmate ${Id}: send failed: unsafe id"
        return
    }
    if (-not (Save-FmSecondmateNudgeMarker $Ctx.PendingDir $Id $HomePath $Commit $Instructions)) {
        Write-FmOut "NUDGE_SECONDMATES: secondmate ${Id}: send failed: cannot record retry marker"
        return
    }
    $send = Invoke-FmBootstrapChild -Name 'fm-send' -BinDir $Ctx.BinDir `
        -Arguments @($selector, $script:FmSecondmateNudgeMessage) `
        -Environment @{
            FM_HOME           = $Ctx.PosixHome
            FM_ROOT_OVERRIDE  = $Ctx.PosixRoot
            FM_STATE_OVERRIDE = $Ctx.PosixState
        }
    if ($send.Ok) {
        try { [System.IO.File]::Delete((ConvertTo-FmNativePath $marker)) } catch { $null = $_ }
        Write-FmOut "BOOTSTRAP_INFO: nudged $selector with '$script:FmSecondmateNudgeMessage'"
    } else {
        $detail = Get-FmFfFirstLine -Text (($send.StdOut + $send.StdErr).TrimEnd("`n"))
        Write-FmOut "NUDGE_SECONDMATES: secondmate ${Id}: send failed: $detail"
    }
}

function Invoke-FmSecondmateRetryPendingNudge {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $pendingNative = ConvertTo-FmNativePath $Ctx.PendingDir
    if (-not [System.IO.Directory]::Exists($pendingNative)) { return }
    $markers = [System.Collections.Generic.List[string]]::new()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($pendingNative, '*.pending')) {
        $leaf = [System.IO.Path]::GetFileName($f)
        if ($leaf.StartsWith('.')) { continue }
        if (-not $leaf.EndsWith('.pending', [System.StringComparison]::Ordinal)) { continue }
        $markers.Add($f)
    }
    $markers.Sort([System.StringComparer]::Ordinal)

    foreach ($marker in $markers) {
        $id = Get-FmMetaValue -MetaPath $marker -Key 'id'
        $expected = Get-FmSecondmateNudgeMarkerPath $Ctx.PendingDir $id
        $idLabel = if ([string]::IsNullOrEmpty($id)) { 'unknown' } else { $id }
        if ($null -eq $expected) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${idLabel}: send failed: retry marker has unsafe id"
            continue
        }
        if (-not (Test-FmSamePath $expected $marker)) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${id}: send failed: retry marker filename mismatch"
            continue
        }
        $selector = Get-FmMetaValue -MetaPath $marker -Key 'selector'
        # Named markerHome, not home: $HOME is a read-only PowerShell automatic
        # variable and assigning to it is a hard analyzer error.
        $markerHome = Get-FmMetaValue -MetaPath $marker -Key 'home'
        $commit = Get-FmMetaValue -MetaPath $marker -Key 'commit'
        $message = Get-FmMetaValue -MetaPath $marker -Key 'message'
        if ($selector -cne "fm-$id") {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${idLabel}: send failed: retry marker selector mismatch"
            continue
        }
        if ($message -cne $script:FmSecondmateNudgeMessage) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${idLabel}: send failed: retry marker message mismatch"
            continue
        }
        $meta = Join-Path $Ctx.State "$id.meta"
        if (-not ([System.IO.File]::Exists((ConvertTo-FmNativePath $meta)) -and
                ((Get-FmMetaValue -MetaPath $meta -Key 'kind') -ceq 'secondmate'))) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${idLabel}: send failed: retry target has no live secondmate metadata"
            continue
        }
        $metaHome = Get-FmMetaValue -MetaPath $meta -Key 'home'
        if ([string]::IsNullOrEmpty($metaHome)) {
            $fromRegistry = Get-FmSecondmateRegistryField -Registry $Ctx.Registry -Id $id -Key 'home'
            if ($null -ne $fromRegistry) { $metaHome = $fromRegistry }
        }
        $validation = Resolve-FmFfSecondmateHome -Id $id -HomePath $metaHome `
            -ActiveHome $Ctx.Home -RepoRoot $Ctx.Root
        if (-not $validation.Ok) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${id}: send failed: retry target home unsafe: $($validation.Error)"
            continue
        }
        $homeReal = $validation.ValidatedHome
        if ($homeReal -cne $markerHome) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${id}: send failed: retry target home changed"
            continue
        }
        $headResult = Invoke-FmBootstrapTool -Name 'git' -Arguments @('-C', (ConvertTo-FmNativePath $homeReal), 'rev-parse', 'HEAD')
        $head = if ($headResult.Ok) { $headResult.StdOut.Trim() } else { '' }
        if ([string]::IsNullOrEmpty($head) -or ($head -cne $commit)) {
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${id}: send failed: retry target is not at recorded instruction commit"
            continue
        }
        $send = Invoke-FmBootstrapChild -Name 'fm-send' -BinDir $Ctx.BinDir `
            -Arguments @($selector, $script:FmSecondmateNudgeMessage) `
            -Environment @{
                FM_HOME           = $Ctx.PosixHome
                FM_ROOT_OVERRIDE  = $Ctx.PosixRoot
                FM_STATE_OVERRIDE = $Ctx.PosixState
            }
        if ($send.Ok) {
            try { [System.IO.File]::Delete((ConvertTo-FmNativePath $marker)) } catch { $null = $_ }
            Write-FmOut "BOOTSTRAP_INFO: nudged $selector with '$script:FmSecondmateNudgeMessage'"
        } else {
            $detail = Get-FmFfFirstLine -Text (($send.StdOut + $send.StdErr).TrimEnd("`n"))
            Write-FmOut "NUDGE_SECONDMATES: secondmate ${id}: send failed: $detail"
        }
    }
}

function Invoke-FmSecondmateSync {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home to the
    # primary checkout's current default-branch commit. Purely LOCAL - no fetch,
    # no origin dependency. Startup sends reread nudges only for RUNNING
    # secondmates whose instruction surface actually changed, so a secondmate
    # already on the primary's version is never disturbed.
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $Ctx.State))) { return }

    $primaryHead = Get-FmFfPrimaryHeadCommit -Root $Ctx.Root
    if ([string]::IsNullOrEmpty($primaryHead)) {
        foreach ($meta in (Get-FmBootstrapMetaFile $Ctx.State)) {
            if (-not (Test-FmMetaHasLinePrefix $meta 'kind=secondmate')) { continue }
            $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
            Write-FmOut "SECONDMATE_SYNC: secondmate ${id}: skipped: primary default-branch commit cannot be resolved"
        }
        return
    }

    Invoke-FmSecondmateRetryPendingNudge -Ctx $Ctx

    # The sweep and the after-instruction hook both report through Write-FmOut,
    # which the bash twin captures with `>"$tmp"` and then FILTERS - only three
    # line shapes survive. Capturing the console reproduces that redirect
    # exactly; printing directly would leak the sweep's `updated ...` lines,
    # which bootstrap deliberately keeps quiet.
    $sweepState = New-FmFfSweepState
    $hook = {
        param($hookId, $hookHome, $hookWindow, $hookInstructions)
        $null = $hookWindow
        Send-FmSecondmateNudge -Ctx $Ctx -Id $hookId -HomePath $hookHome `
            -Commit $primaryHead -Instructions $hookInstructions
    }.GetNewClosure()

    $sweepText = Invoke-FmCapturedConsole {
        Invoke-FmFfSecondmateSweep -StateDir $Ctx.State -BaseMode $primaryHead `
            -NudgeRequiresInstruction -Registry $Ctx.Registry -State $sweepState `
            -ActiveHome $Ctx.Home -RepoRoot $Ctx.Root -AfterInstructionUpdate $hook
    }
    foreach ($line in ($sweepText -split "`n")) {
        if ($line -eq '') { continue }
        if ($line -cmatch '^secondmate .*: skipped:') { Write-FmOut "SECONDMATE_SYNC: $line" }
        elseif ($line.StartsWith('BOOTSTRAP_INFO: ')) { Write-FmOut $line }
        elseif ($line.StartsWith('NUDGE_SECONDMATES: ')) { Write-FmOut $line }
    }

    # Inheritance propagation: push the primary-authoritative local inheritance
    # surface into every VALIDATED live secondmate home swept above. The sweep's
    # SeenHomes IS that set, and fm-config-inherit-lib owns the declared items.
    $seenHomes = $sweepState.SeenHomes
    $propagated = [System.Collections.Generic.List[string]]::new()
    foreach ($record in (Get-FmFfLiveSecondmateMetaRecord -StateDir $Ctx.State -Registry $Ctx.Registry)) {
        $id = $record.Id
        $validation = Resolve-FmFfSecondmateHome -Id $id -HomePath $record.Home `
            -ActiveHome $Ctx.Home -RepoRoot $Ctx.Root
        if (-not $validation.Ok) { continue }
        $homeReal = $validation.ValidatedHome
        if (-not $seenHomes.Contains($homeReal)) { continue }
        if ($propagated.Contains($homeReal)) { continue }
        $propagated.Add($homeReal)

        try {
            $null = [System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath (Join-Path $homeReal 'state')))
        } catch {
            Write-FmOut "CONFIG_REREAD: secondmate ${id}: send failed: could not create state directory"
            continue
        }
        $homeLock = Get-FmConfigInheritLockPath $homeReal
        if ([string]::IsNullOrEmpty($homeLock)) {
            Write-FmOut "CONFIG_REREAD: secondmate ${id}: send failed: could not resolve per-home lock"
            continue
        }
        # Wait-FmLock BLOCKS until it holds the lock and returns void, so unlike
        # the bash `fm_lock_acquire_wait ... || {...}` there is no failure arm to
        # branch on. The bash arm is unreachable for the same reason - its twin
        # also loops until it succeeds - so nothing observable is lost, and a
        # `-not (Wait-FmLock ...)` test would have been TRUE on every success.
        Wait-FmLock -LockPath $homeLock
        try {
            $skipPending = 0
            if ($script:FmRespawnedSecondmateIds -ccontains $id) { $skipPending = 1 }
            if ($skipPending -eq 0 -and (Test-FmConfigRereadRetryQueueFull -SourceHome $Ctx.Home -Id $id)) {
                try {
                    $null = Invoke-FmConfigRereadRetryPending -Id $id -DestinationHome $homeReal -BinDir $Ctx.BinDir
                } catch { $null = $_ }
                if (Test-FmConfigRereadRetryQueueFull -SourceHome $Ctx.Home -Id $id) {
                    Write-FmOut "CONFIG_REREAD: secondmate ${id}: send failed: retry instruction queue is full"
                    continue
                }
            }

            $report = Join-Path ([System.IO.Path]::GetTempPath()) ("fm-bootstrap-inherit." + [System.IO.Path]::GetRandomFileName())
            try {
                Set-FmFileText -Path $report -Text '' -NoNewline
            } catch {
                Write-FmOut "SECONDMATE_SYNC: secondmate ${id}: skipped: inheritance failed"
                continue
            }
            try {
                $savedReport = [Environment]::GetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT')
                [Environment]::SetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT', $report)
                $ok = $false
                try {
                    $ok = Sync-FmSecondmateInheritance -SourceHome $Ctx.Home -DestinationHome $homeReal `
                        -SourceConfig $Ctx.Config -SourceData $Ctx.Data
                } catch { $ok = $false }
                if (-not $ok) {
                    Write-FmOut "SECONDMATE_SYNC: secondmate ${id}: skipped: inheritance failed"
                }

                $savedSkip = [Environment]::GetEnvironmentVariable('FM_CONFIG_REREAD_SKIP_PENDING')
                $savedHome = [Environment]::GetEnvironmentVariable('FM_HOME')
                $savedRoot = [Environment]::GetEnvironmentVariable('FM_ROOT_OVERRIDE')
                $savedState = [Environment]::GetEnvironmentVariable('FM_STATE_OVERRIDE')
                $rereadFailed = $false
                $rereadOut = ''
                try {
                    [Environment]::SetEnvironmentVariable('FM_CONFIG_REREAD_SKIP_PENDING', [string]$skipPending)
                    [Environment]::SetEnvironmentVariable('FM_HOME', $Ctx.PosixHome)
                    [Environment]::SetEnvironmentVariable('FM_ROOT_OVERRIDE', $Ctx.PosixRoot)
                    [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $Ctx.PosixState)
                    $rereadOut = Invoke-FmCapturedConsole {
                        try {
                            $r = Send-FmConfigRereadNudge -Id $id -DestinationHome $homeReal `
                                -Report $report -BinDir $Ctx.BinDir
                            if (-not $r) { $script:FmRereadFailed = $true }
                        } catch {
                            $script:FmRereadFailed = $true
                        }
                    }
                    $rereadFailed = [bool]$script:FmRereadFailed
                    $script:FmRereadFailed = $false
                } finally {
                    [Environment]::SetEnvironmentVariable('FM_CONFIG_REREAD_SKIP_PENDING', $savedSkip)
                    [Environment]::SetEnvironmentVariable('FM_HOME', $savedHome)
                    [Environment]::SetEnvironmentVariable('FM_ROOT_OVERRIDE', $savedRoot)
                    [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $savedState)
                }
                $rereadOut = $rereadOut.TrimEnd("`n")
                if ($rereadFailed) {
                    if ($rereadOut -ne '') {
                        Write-FmOut $rereadOut
                    } else {
                        Write-FmOut "CONFIG_REREAD: secondmate ${id}: send failed: unknown error"
                    }
                } elseif ($rereadOut -ne '') {
                    Write-FmOut $rereadOut
                }
            } finally {
                [Environment]::SetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT', $savedReport)
                try { [System.IO.File]::Delete((ConvertTo-FmNativePath $report)) } catch { $null = $_ }
            }
        } finally {
            try { $null = Unlock-FmLock -LockPath $homeLock } catch { $null = $_ }
        }
    }
}

# --- pending backlog handoff --------------------------------------------------

# Deliver anything a previous session left pending in an outbox. Entirely
# best-effort and entirely silent: the delivery script owns its own reporting and
# a failure here must never colour a bootstrap digest.
function Invoke-FmSecondmateHandoffResume {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath (Join-Path $Ctx.Data 'handoff')))) { return }
    try {
        $null = Invoke-FmScript -Name 'fm-backlog-handoff' -BinDir $Ctx.BinDir -Arguments @('--resume-pending')
    } catch { $null = $_ }
}

# Report what is still undelivered. Read-only, so it runs on every local pass
# including a detect-only one.
function Invoke-FmSecondmateHandoffDetect {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $dir = ConvertTo-FmNativePath (Join-Path $Ctx.Data 'handoff')
    if (-not [System.IO.Directory]::Exists($dir)) { return }
    # `for outbox in "$DATA/handoff"/*.outbox.md` - sorted, dot-prefixed leaves
    # excluded, and DIRECTORIES included, because a directory with that name is
    # exactly one of the shapes the unsafe-outbox arm below exists to catch.
    $entries = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($dir, '*.outbox.md')) {
        $leaf = [System.IO.Path]::GetFileName($entry)
        if ($leaf.StartsWith('.')) { continue }
        if (-not $leaf.EndsWith('.outbox.md', [System.StringComparison]::Ordinal)) { continue }
        $entries.Add($entry)
    }
    $entries.Sort([System.StringComparer]::Ordinal)

    foreach ($outbox in $entries) {
        # `[ -e ]` - a dangling link expands from the glob but is then skipped.
        if (-not ([System.IO.File]::Exists($outbox) -or [System.IO.Directory]::Exists($outbox))) { continue }
        $leaf = [System.IO.Path]::GetFileName($outbox)
        $id = $leaf.Substring(0, $leaf.Length - '.outbox.md'.Length)
        if ($id -eq '' -or $id -notmatch '^[A-Za-z0-9._-]+$') { $id = 'unknown' }
        # `[ ! -f ] || [ -L ]`: -f follows the link, so a symlink TO a regular
        # file is still unsafe.
        if ((-not [System.IO.File]::Exists($outbox)) -or (Test-FmSymlink $outbox)) {
            Write-FmOut "SECONDMATE_HANDOFF: secondmate ${id}: pending delivery: unsafe outbox"
            continue
        }
        $count = 'unknown'
        try {
            $n = 0
            foreach ($line in (Get-FmFileLines $outbox)) {
                if ($line -cmatch '^- \[[ x]\] ') { $n++ }
            }
            $count = [string]$n
        } catch { $count = 'unknown' }
        Write-FmOut "SECONDMATE_HANDOFF: secondmate ${id}: pending delivery: $count item(s)"
    }
}

# --- X mode -------------------------------------------------------------------

# See divergence 3 in the header: the same-filesystem pin is performed here
# against the volume root rather than delegated to fm-x-lib's private device id.
function Get-FmBootstrapVolumeToken {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    if (Test-FmWindows) {
        try { return ([System.IO.Path]::GetPathRoot($native)).ToUpperInvariant() } catch { return $null }
    }
    $result = Invoke-FmBootstrapTool -Name 'stat' -Arguments @('-c', '%d', $native)
    if (-not $result.Ok) { return $null }
    return $result.StdOut.Trim()
}

function Set-FmXModeArtifactIfChanged {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are private helpers inside a non-interactive bootstrap whose bash twin writes unconditionally; a confirmation surface would diverge from the twin and could stall a hook.')]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Mode
    )
    $destNative = ConvertTo-FmNativePath $Destination
    $parent = [System.IO.Path]::GetDirectoryName($destNative)
    if ([string]::IsNullOrEmpty($parent) -or ($parent -ceq $destNative)) { return $false }
    if (-not [System.IO.Directory]::Exists($parent)) { return $false }
    if (Test-FmSymlink $parent) { return $false }
    $parentVolume = Get-FmBootstrapVolumeToken $parent
    if ($null -eq $parentVolume) { return $false }

    $body = $Content + "`n"
    $destExists = [System.IO.File]::Exists($destNative) -or
        [System.IO.Directory]::Exists($destNative) -or (Test-FmSymlink $destNative)
    if ($destExists) {
        if (-not (Test-FmxSingleLinkFile -Path $destNative)) { return $false }
        if ((Get-FmBootstrapVolumeToken $destNative) -cne $parentVolume) { return $false }
        # `stat -c %a` cannot express the bit on Windows, so the mode never
        # compares equal there and the artifact is republished - which is exactly
        # what the bash twin does on a noacl mount, where stat reports 644/755.
        if ((Test-FmxSingleLinkFileMode -Path $destNative -Mode $Mode) -and
            ((Get-FmFileText $destNative) -ceq $body)) {
            return $true
        }
    }

    $temp = Join-Path $parent ('.fm-x-mode.' + [System.IO.Path]::GetRandomFileName())
    try {
        Set-FmFileText -Path $temp -Text $body -NoNewline
        Set-FmXModeUnixMode -Path $temp -Mode $Mode
        if (-not (Test-FmxSingleLinkFileMode -Path $temp -Mode $Mode)) {
            try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
            return $false
        }
        if ($destExists -and -not (Test-FmxSingleLinkFile -Path $destNative)) {
            try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
            return $false
        }
        [System.IO.File]::Move($temp, $destNative, $true)
    } catch {
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { $null = $_ }
        return $false
    }
    if ((-not (Test-FmxSingleLinkFileMode -Path $destNative -Mode $Mode)) -or
        ((Get-FmFileText $destNative) -cne $body)) {
        try { [System.IO.File]::Delete($destNative) } catch { $null = $_ }
        return $false
    }
    return $true
}

# `chmod <mode>` - inert on Windows by construction, and deliberately NOT
# replaced by a real ACL (docs/powershell-port.md, "Things that must NOT be
# improved"): enforcing ACLs here would make the PowerShell path refuse
# artifacts the bash path accepts.
function Set-FmXModeUnixMode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are private helpers inside a non-interactive bootstrap whose bash twin writes unconditionally; a confirmation surface would diverge from the twin and could stall a hook.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Mode)
    if (Test-FmWindows) { return }
    $result = Invoke-FmBootstrapTool -Name 'chmod' -Arguments @($Mode, (ConvertTo-FmNativePath $Path))
    $null = $result
}

function Test-FmXModeArtifactPresent {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    return ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native) -or (Test-FmSymlink $native))
}

function Remove-FmXModeArtifact {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets that need -WhatIf/-Confirm. These are private helpers inside a non-interactive bootstrap whose bash twin removes unconditionally; a confirmation surface would diverge from the twin and could stall a hook.')]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-FmXModeArtifactPresent $Path)) { return $true }
    $native = ConvertTo-FmNativePath $Path
    $parent = [System.IO.Path]::GetDirectoryName($native)
    if ([string]::IsNullOrEmpty($parent) -or -not [System.IO.Directory]::Exists($parent)) { return $false }
    if (Test-FmSymlink $parent) { return $false }
    try { [System.IO.File]::Delete($native) } catch { return $false }
    return (-not (Test-FmXModeArtifactPresent $Path))
}

function Invoke-FmXModeSetup {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $envFile = Join-Path $Ctx.Home '.env'
    $shim = Join-Path $Ctx.State 'x-watch.check.sh'
    $cadence = Join-Path $Ctx.Config 'x-mode.env'

    $token = ''
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $envFile))) {
        $token = Get-FmxEnvValue -Key 'FMX_PAIRING_TOKEN' -File $envFile
        if ($null -eq $token) { $token = '' }
    }

    $removeArtifacts = {
        $failed = $false
        if (-not (Remove-FmXModeArtifact $shim)) { $failed = $true }
        if (-not (Remove-FmXModeArtifact $cadence)) { $failed = $true }
        return (-not $failed)
    }.GetNewClosure()

    $supervisionRepair = {
        $probe = Invoke-FmScript -Name 'fm-supervision-instructions' -BinDir $Ctx.BinDir -Arguments @('--repair-line')
        if ($probe.Ok) {
            $line = $probe.StdOut.TrimEnd("`n")
            if ($line -ne '') { return $line }
        }
        return 'repair missing watcher supervision according to the session-start operating block.'
    }.GetNewClosure()

    if ($token -eq '') {
        # Opt-out (or never opted in): drop any X artifacts; stay silent unless
        # something was actually removed.
        if ((Test-FmXModeArtifactPresent $shim) -or (Test-FmXModeArtifactPresent $cadence)) {
            if (& $removeArtifacts) {
                Write-FmOut ("FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; " + (& $supervisionRepair))
            } else {
                Write-FmOut 'FMX: X mode off - failed to remove relay poll shim or 30s cadence'
            }
        }
        return
    }

    $missing = $false
    foreach ($tool in @('curl', 'jq')) {
        if (-not (Test-FmCommand $tool)) {
            $cmd = Get-FmInstallCommand $tool
            if ($null -eq $cmd) { $cmd = '' }
            Write-FmOut "MISSING: $tool (install: $cmd)"
            $missing = $true
        }
    }
    if ($missing) {
        if ((Test-FmXModeArtifactPresent $shim) -or (Test-FmXModeArtifactPresent $cadence)) {
            if (& $removeArtifacts) {
                Write-FmOut 'FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap'
            } else {
                Write-FmOut 'FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies'
            }
        }
        return
    }

    $armFailed = {
        if (& $removeArtifacts) {
            Write-FmOut 'FMX: X mode off - failed to arm relay poll shim or 30s cadence'
        } else {
            Write-FmOut 'FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain'
        }
    }.GetNewClosure()

    try {
        $null = [System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $Ctx.State))
        $null = [System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $Ctx.Config))
    } catch {
        & $armFailed
        return
    }

    # The shim is a SHELL script the watcher executes, and fm-x-lib renders and
    # re-validates its bytes, so the paths baked into it must be the MSYS form
    # the bash twin writes - contract 3, and here it is load-bearing rather than
    # cosmetic.
    $shimBody = Get-FmxPollShimContent -HomePath $Ctx.PosixHome -Root $Ctx.PosixRoot
    if (-not (Set-FmXModeArtifactIfChanged -Destination $shim -Content $shimBody -Mode '700')) {
        & $armFailed
        return
    }
    if (-not (Test-FmxPollShim -Path $shim -HomePath $Ctx.PosixHome -Root $Ctx.PosixRoot)) {
        & $armFailed
        return
    }

    $cadenceBody = @(
        '# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.'
        '# Source this before the active harness protocol starts a watcher process so'
        '# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and'
        '# keep the default 300s cadence.'
        'export FM_CHECK_INTERVAL=30'
    ) -join "`n"
    if (-not (Set-FmXModeArtifactIfChanged -Destination $cadence -Content $cadenceBody -Mode '600')) {
        & $armFailed
        return
    }

    Write-FmOut 'FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env'
}

# --- fleet sync ---------------------------------------------------------------

function Get-FmFleetSyncOriginBackedProjectCount {
    param([Parameter(Mandatory)][string]$ProjectsDir)
    $native = ConvertTo-FmNativePath $ProjectsDir
    if (-not [System.IO.Directory]::Exists($native)) { return 0 }
    $count = 0
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($native)) {
        $probe = Invoke-FmBootstrapTool -Name 'git' -Arguments @('-C', $dir, 'rev-parse', '--git-dir')
        if (-not $probe.Ok) { continue }
        $remote = Invoke-FmBootstrapTool -Name 'git' -Arguments @('-C', $dir, 'remote', 'get-url', 'origin')
        if (-not $remote.Ok) { continue }
        $count++
    }
    return $count
}

function Get-FmFleetSyncBootstrapTimeout {
    param([Parameter(Mandatory)][string]$ProjectsDir)
    $override = Get-FmEnv 'FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT'
    if ($override -ne '') {
        if ($override -match '[^0-9]') { return 20 }
        return [int]$override
    }
    $count = Get-FmFleetSyncOriginBackedProjectCount $ProjectsDir
    $timeout = 5 + (3 * $count)
    if ($timeout -lt 20) { $timeout = 20 }
    return $timeout
}

function Write-FmFleetSyncFiltered {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($line in ($Text -split "`n")) {
        # The bash `case` is ORDERED: the two silent shapes are exact SUFFIX
        # matches and must be tested before the containment patterns below them.
        if ($line.EndsWith(': skipped: local-only project')) { continue }
        if ($line.EndsWith(': skipped: no origin remote')) { continue }
        if ($line.Contains(': skipped:')) { Write-FmOut "FLEET_SYNC: $line"; continue }
        if ($line.Contains(': STUCK:')) { Write-FmOut "FLEET_SYNC: $line"; continue }
        if ($line.Contains(': recovered:')) { Write-FmOut "FLEET_SYNC: $line"; continue }
    }
}

function Write-FmFleetSyncAll {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($line in ($Text -split "`n")) {
        if ($line -eq '') { continue }
        Write-FmOut "FLEET_SYNC: $line"
    }
}

function Invoke-FmFleetSync {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $sibling = Resolve-FmBootstrapSibling -Name 'fm-fleet-sync' -BinDir (Join-Path $Ctx.Root 'bin')
    if ($null -eq $sibling) { return }
    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $Ctx.Projects))) { return }

    $timeout = Get-FmFleetSyncBootstrapTimeout $Ctx.Projects

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $sibling.File
    foreach ($a in $sibling.Prefix) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    # `2>/dev/null` - the bash twin discards the child's stderr entirely.
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $timedOut = $false
    $elapsed = 0
    $out = ''
    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.WaitForExit(1000)) {
            $elapsed = [int][Math]::Floor($watch.Elapsed.TotalSeconds)
            if ($elapsed -ge $timeout) {
                # The bash kills the process GROUP; a Windows process has no
                # group, so the whole tree is killed instead (header divergence 4).
                try { $proc.Kill($true) } catch { $null = $_ }
                $timedOut = $true
                break
            }
        }
        if (-not $timedOut) { $elapsed = [int][Math]::Floor($watch.Elapsed.TotalSeconds) }
        $proc.WaitForExit()
        try { $out = $outTask.GetAwaiter().GetResult() } catch { $out = '' }
        try { $null = $errTask.GetAwaiter().GetResult() } catch { $null = $_ }
    } finally {
        $proc.Dispose()
    }
    $out = ($out -replace "`r", '').TrimEnd("`n")

    if ($timedOut) {
        Write-FmFleetSyncAll $out
        Write-FmOut "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
        return
    }
    Write-FmFleetSyncFiltered $out
}

# --- main ---------------------------------------------------------------------

$script:FmRereadFailed = $false

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $ctx = @{
        BinDir     = $context.ScriptRoot
        Root       = $context.Root
        Home       = $context.Home
        State      = $context.State
        Data       = $context.Data
        Config     = $context.Config
        Projects   = $context.Projects
        PosixRoot  = $context.PosixRoot
        PosixHome  = $context.PosixHome
        PosixState = ConvertTo-FmPosixPath $context.State
        Registry   = Join-Path $context.Data 'secondmates.md'
        PendingDir = Join-Path $context.State '.secondmate-nudge-pending'
    }

    if ($fmArgv.Count -gt 0 -and ([string]$fmArgv[0]) -ceq 'install') {
        # Built by index rather than by range slice: `$fmArgv[1..0]` on a
        # one-element array does NOT yield an empty list, it yields two reads,
        # one of them out of bounds.
        $tools = [System.Collections.Generic.List[string]]::new()
        for ($k = 1; $k -lt $fmArgv.Count; $k++) { $tools.Add([string]$fmArgv[$k]) }
        if ($tools.Count -eq 0) {
            Write-FmErr 'usage: fm-bootstrap.sh install <tool>...'
            Exit-FmScript 1
        }
        foreach ($tool in $tools) {
            $cmd = Get-FmInstallCommand ([string]$tool)
            if ($null -eq $cmd) {
                $instructions = Get-FmManualInstallUrl ([string]$tool)
                if ($null -eq $instructions) {
                    Write-FmErr "error: unknown tool $tool"
                    Exit-FmScript 1
                }
                Write-FmErr "error: $tool requires manual installation (instructions: $instructions)"
                Exit-FmScript 1
            }
            # `${cmd%%  #*}` - strip the trailing "  # or ..." human note.
            $idx = $cmd.IndexOf('  #')
            if ($idx -ge 0) { $cmd = $cmd.Substring(0, $idx) }
            Write-FmOut "installing ${tool}: $cmd"
            # The `eval "$cmd"` twin. These commands are shell pipelines
            # (`curl ... | sh`, `npm install -g x && x setup hooks`), so they run
            # through a shell exactly as the bash twin runs them, and a failure
            # does not stop the loop or change the exit code - matching the bash,
            # which has no `set -e`.
            $bash = Get-FmBash
            if (-not $bash) {
                Write-FmErr "error: no shell available to run the install command for $tool"
                Exit-FmScript 1
            }
            $run = Invoke-FmTool -FilePath $bash -Arguments @('-c', $cmd)
            if ($run.StdOut -ne '') { Write-FmRaw $run.StdOut }
            if ($run.StdErr -ne '') { Write-FmErr ($run.StdErr.TrimEnd("`n")) }
        }
        Exit-FmScript 0
    }

    $detectOnly = ((Get-FmEnv 'FM_BOOTSTRAP_DETECT_ONLY' '0') -ceq '1')
    $verboseFacts = ((Get-FmEnv 'FM_BOOTSTRAP_VERBOSE_FACTS' '0') -ceq '1')

    # The FIRST mutating sweep at a locked session boundary: it neutralizes legacy
    # PR checks before any later bootstrap mutation can leave old artifacts
    # runnable. Detect-only sessions never touch state, and the deferred network
    # pass never repeats it: the local pass that ran first already closed that
    # window.
    if ((-not $detectOnly) -and (Test-FmLocalPhase)) {
        $migrate = Invoke-FmScript -Name 'fm-pr-check-migrate' -BinDir $ctx.BinDir
        if ($migrate.StdOut -ne '') { Write-FmRaw $migrate.StdOut }
        if ($migrate.StdErr -ne '') { Write-FmErr ($migrate.StdErr.TrimEnd("`n")) }
        Initialize-FmBootstrapStartupMemoryBudget -HomePath $ctx.Home -ConfigDir $ctx.Config
    }

    # Required-tool detection follows the RESOLVED backend, not a one-size
    # default: a universal toolchain every home needs plus the backend-specific
    # delta owned by Get-FmBackendRequiredTool. So a herdr/zellij/cmux home is
    # never told tmux is missing, and only orca drops treehouse.
    $commonTools = @('node', 'git', 'gh', 'no-mistakes', 'gh-axi', 'chrome-devtools-axi', 'lavish-axi', 'tasks-axi', 'quota-axi')
    $backend = Get-FmBackendName $ctx.Config
    $backendTools = Get-FmBackendRequiredTool $backend
    $backendValid = $true
    if ($null -eq $backendTools) {
        $backendValid = $false
        $backendTools = ''
    }
    $backendToolList = @($backendTools -split '\s+' | Where-Object { $_ -ne '' })
    $allTools = (@($backendToolList) + @($commonTools)) -join ' '
    $noMistakesMin = '1.31.2'

    # Local detection: presence, version floors, and configuration. Nothing here
    # leaves this machine, so it stays on the session-start critical path.
    if (Test-FmLocalPhase) {
        if (-not $backendValid) {
            Write-FmOut "BACKEND_INVALID: $backend (known: $(Get-FmBackendKnownName))"
        }
        foreach ($tool in $backendToolList) {
            if (-not (Test-FmBackendRequiredTool $backend $tool)) { Write-FmMissingToolDiagnostic $tool }
        }
        foreach ($tool in $commonTools) {
            if (-not (Test-FmCommand $tool)) { Write-FmMissingToolDiagnostic $tool }
        }
        # The treehouse lease-support upgrade check is only relevant when the
        # resolved backend actually requires treehouse; an orca home must not be
        # told to upgrade a provider it never uses.
        if ((Test-FmBackendListContains $allTools 'treehouse') -and (Test-FmCommand 'treehouse') -and
            -not (Test-FmTreehouseSupportsLease)) {
            Write-FmOut "MISSING: treehouse (install: $(Get-FmInstallCommand 'treehouse'))"
        }
        if ((Test-FmCommand 'no-mistakes') -and -not (Test-FmToolVersionAtLeast 'no-mistakes' $noMistakesMin)) {
            Write-FmOut "MISSING: no-mistakes (install: $(Get-FmInstallCommand 'no-mistakes'))"
        }
        if ((Test-FmCommand 'quota-axi') -and -not (Test-FmQuotaAxiCompatible)) {
            Write-FmOut "MISSING: quota-axi (install: $(Get-FmInstallCommand 'quota-axi'))"
        }
        if ((Test-FmCommand 'tasks-axi') -and -not (Test-FmTasksAxiCompatible)) {
            Write-FmOut "MISSING: tasks-axi (install: $(Get-FmInstallCommand 'tasks-axi'))"
        }
    }

    # The GitHub-auth probe sits BETWEEN the two local blocks because that is
    # where it has always sat, so a `skip` run is the same output with the
    # network lines removed rather than a reshuffle.
    if (Test-FmNetworkPhase) {
        $ghAuth = Invoke-FmBootstrapTool -Name 'gh' -Arguments @('auth', 'status')
        if (-not $ghAuth.Ok) { Write-FmOut 'NEEDS_GH_AUTH' }
    }

    if (Test-FmLocalPhase) {
        # Worktree-tangle check: the firstmate primary checkout must sit on its
        # default branch, not a feature branch. Scoped to the primary only;
        # detached-HEAD worktrees and secondmate homes never trip it.
        $tangleBranch = ''
        try { $tangleBranch = Get-FmPrimaryTangleBranch -Root $ctx.Root } catch { $tangleBranch = '' }
        if (-not [string]::IsNullOrEmpty($tangleBranch)) {
            $tangleDefault = ''
            try { $tangleDefault = Get-FmDefaultBranch -Directory $ctx.Root } catch { $tangleDefault = '' }
            if ([string]::IsNullOrEmpty($tangleDefault)) { $tangleDefault = 'main' }
            if ($detectOnly) {
                Write-FmOut "TANGLE: primary checkout on feature branch '$tangleBranch' (expected '$tangleDefault'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
            } else {
                Write-FmOut "TANGLE: primary checkout on feature branch '$tangleBranch' (expected '$tangleDefault'); the work is safe on that ref - restore the primary with: git -C $($ctx.PosixRoot) checkout $tangleDefault, then re-validate the branch in a proper worktree"
            }
        }

        Test-FmWindowsSymlinkStub -Root $ctx.Root

        $crew = ''
        $crewFile = Join-Path $ctx.Config 'crew-harness'
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $crewFile))) {
            $crew = (Get-FmFileText $crewFile) -replace '\s', ''
        }
        if ($verboseFacts -and $crew -ne '' -and $crew -cne 'default') {
            Write-FmOut "BOOTSTRAP_INFO: crew harness override active: $crew"
        }
        Invoke-FmCrewDispatchValidate -ConfigDir $ctx.Config
        if ($verboseFacts -and -not (Test-FmBacklogBackendManual $ctx.Config) -and (Test-FmTasksAxiCompatible)) {
            Write-FmOut 'BOOTSTRAP_INFO: tasks-axi available'
        }
    }

    if (-not $detectOnly) {
        # The liveness sweep hands SECONDMATE_RESPAWNED ids to the convergence
        # sweep, so those two always run together in the same phase.
        if (Test-FmNetworkPhase) {
            if (Test-FmNetworkSweepAuthorized -StateDir $ctx.State -Label 'dead-secondmate relaunch') {
                Invoke-FmSecondmateLivenessSweep -StateDir $ctx.State -Root $ctx.Root
            }
            if (Test-FmNetworkSweepAuthorized -StateDir $ctx.State -Label 'secondmate convergence') {
                Invoke-FmSecondmateSync -Ctx $ctx
            }
            if (Test-FmNetworkSweepAuthorized -StateDir $ctx.State -Label 'pending handoff delivery') {
                Invoke-FmSecondmateHandoffResume -Ctx $ctx
            }
        }
        # X mode writes local Relay artifacts only and never leaves the machine.
        if (Test-FmLocalPhase) { Invoke-FmXModeSetup -Ctx $ctx }
        if ((Test-FmNetworkPhase) -and
            (Test-FmNetworkSweepAuthorized -StateDir $ctx.State -Label 'project clone refresh')) {
            Invoke-FmFleetSync -Ctx $ctx
        }
    }
    if (Test-FmLocalPhase) { Invoke-FmSecondmateHandoffDetect -Ctx $ctx }

    Exit-FmScript 0
}
