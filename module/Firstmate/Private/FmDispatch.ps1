#requires -Version 7.0
# FmDispatch.ps1 - the DECISION half of the spawn: what a task is launched with,
# and what is recorded about it. Ported from bin/fm-spawn.sh (delivery contract,
# harness/model/effort resolution, the state/<id>.meta field set).
#
# WHAT THIS FILE OWNS
#   1. the operational-input wire form a launch brief is delivered in,
#   2. the delivery contract (mode/yolo) and its refusals,
#   3. harness resolution, the verified launch adapters, and the model/effort
#      axes that may be threaded into a launch,
#   4. the state/<id>.meta field set and its order.
#
# WHAT IT DELIBERATELY DOES NOT OWN - and these are OTHER AREAS' names, bound at
# call time, not copies:
#   - the brief itself. Public/FmBrief.ps1 (lifecycle area) scaffolds it and its
#     text is diffed byte-for-byte against bash fixtures; this file only READS
#     the one machine-readable line the spawn must agree with
#     (Get-FmBriefDeliveryMode).
#   - the status stream. Public/FmClassify.ps1 owns the verb/key/note parsers,
#     the captain-relevance tests and both open-decision folds; Add-FmTaskStatus
#     is the writer that speaks that grammar.
#   - state-file I/O. The foundation owns it: Read-FmKeyValueFile /
#     Write-FmKeyValueFile publish the record atomically and LF-only, and
#     Add-FmStateLine appends UNDER A LOCK - which is not belt and braces, since
#     .NET's FileMode.Append loses concurrent lines where bash's `>>` does not.
#   - endpoint creation, the worktree lease, and the isolation assertion
#     (FmBackendHerdr.ps1, FmWorktree.ps1); Start-FmWorker composes them.
#   - relaunch, remote placement, trace context, busy generations, and the
#     presentation projection. Each is another area's; the record writer accepts
#     their fields so a record this port writes and one a Linux firstmate writes
#     stay the same shape.

Set-StrictMode -Version Latest

# --- quoting -----------------------------------------------------------------

# A PowerShell single-quoted literal. The launch command is TYPED INTO A PANE
# whose shell is PowerShell, so every path and value that reaches it has to be
# quoted the way that shell parses, not the way bash does.
function ConvertTo-FmPowerShellLiteral {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    "'" + (([string]$Value) -replace "'", "''") + "'"
}

# A POSIX single-quoted literal. Used only where this port writes text for a
# POSIX shell - i.e. the development-convenience Linux path of the brief
# scaffolder. The product is Windows; see docs/task-dispatch-windows.md.
function ConvertTo-FmShellLiteral {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    "'" + (([string]$Value) -replace "'", "'\''") + "'"
}

# --- the operational-input protocol ------------------------------------------
#
# Ported from bin/fm-operational-input.sh's encode half only. The wire form is
#   U+2063 FIRSTMATE_OP: v1 <kind>: <body>
# and the U+2063 prefix is permanent compatibility, so it is written as one
# constant here rather than being spelled out at any call site.

function Get-FmOperationalInputHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Kind)
    $known = @('session-start', 'watcher', 'turn-end-guard', 'away-supervisor', 'launch-brief')
    if ($known -notcontains $Kind) {
        throw "error: '$Kind' is not a current firstmate operational-input kind"
    }
    "$([char]0x2063)FIRSTMATE_OP: v1 ${Kind}: "
}

# The from-firstmate routing marker a secondmate charter tells its reader to
# look for. It stays byte-compatible with the bash constant because live
# secondmates already carry the label in their charter context.
function Get-FmFromFirstmateLabel {
    [CmdletBinding()]
    param()
    '[fm-from-firstmate]'
}

function ConvertTo-FmOperationalInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    if (-not $Body) { throw "error: an operational input needs a body" }
    (Get-FmOperationalInputHeader -Kind $Kind) + $Body
}

# --- the delivery contract ---------------------------------------------------

function Get-FmDeliveryModeName {
    [CmdletBinding()]
    param()
    , @('no-mistakes', 'direct-PR', 'local-only')
}

# 3 (most rigor) .. 1 (least); 0 when the value is not a task mode. Ported from
# delivery_rigor_rank.
function Get-FmDeliveryRigorRank {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Mode)
    switch ($Mode) {
        'no-mistakes' { 3 }
        'direct-PR' { 2 }
        'local-only' { 1 }
        default { 0 }
    }
}

# Assert-, not Test-: a ship task's mode and yolo are firstmate's per-task
# decision (AGENTS.md section 7). This port never resolves either from the
# project registry, never defaults them, and never carries them onto a kind that
# has no delivery contract - it refuses, with the bash refusal text, so the
# caller cannot mistake a guess for an answer.
function Assert-FmDeliveryContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ship', 'scout', 'secondmate')][string]$Kind,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Mode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Yolo
    )
    if ($Kind -eq 'ship') {
        if (-not $Mode) {
            throw ('error: ship spawns require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake ' +
                "from the captain's instruction and the project's registered posture in data/projects.md")
        }
        if (-not $Yolo) {
            throw ("error: ship spawns require --yolo <on|off>; it is this task's routine approval authority, " +
                'not a project lookup')
        }
        if ($Mode -eq 'no-mistakes-prod-only') {
            throw ('error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task' +
                "'s surface and resolve it to no-mistakes or direct-PR at intake")
        }
        if ((Get-FmDeliveryModeName) -notcontains $Mode) {
            throw "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$Mode')"
        }
        if ($Yolo -ne 'on' -and $Yolo -ne 'off') {
            throw "error: --yolo must be on or off (got '$Yolo')"
        }
        return
    }
    if ($Mode) {
        throw ('error: --mode applies only to ship spawns; a scout delivers a report and a secondmate records ' +
            'its own fixed posture')
    }
    if ($Yolo) {
        throw ('error: --yolo applies only to ship spawns; a scout delivers a report and a secondmate records ' +
            'its own fixed posture')
    }
}

# The mode a scaffolded ship brief recorded, or '' when it carries no contract
# line. The line is fixed text written by New-FmBrief and read here; it is the
# whole mechanism that keeps a worker's instructions and the task record from
# drifting apart.
function Get-FmBriefDeliveryMode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^Delivery contract: mode=(\S+)') { return $Matches[1] }
    }
    ''
}

# Brief/spawn delivery agreement, checked before any endpoint exists. A brief
# scaffolded before the contract line existed warns once and launches on the
# flag; a DISAGREEMENT is a refusal, because launching it would hand a worker
# instructions that contradict its own task record.
function Assert-FmBriefDeliveryAgreement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter(Mandatory)][string]$Mode
    )
    $briefMode = Get-FmBriefDeliveryMode -Path $BriefPath
    if (-not $briefMode) {
        Write-Warning ("$BriefPath records no delivery contract line (scaffolded before ship briefs recorded " +
            "one); launching on the explicit --mode $Mode - confirm its definition of done matches")
        return
    }
    if ($briefMode -ne $Mode) {
        throw ("error: delivery mismatch for ${TaskId}: the brief says mode=$briefMode but this spawn passed " +
            "--mode $Mode; correct the flag or re-scaffold the brief so the worker's instructions and the task " +
            'record agree')
    }
}

# The registry holds the captain's STANDING posture, so shipping below it is
# allowed - a current explicit captain instruction wins - but never silent.
# Get-FmProjectMode is the registry owner; when it is absent the notice is simply
# not emitted, because a missing owner may never manufacture a verdict.
function Write-FmDeliveryPostureNotice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Mode
    )
    $resolver = Get-Command -Name Get-FmProjectMode -CommandType Function -ErrorAction SilentlyContinue
    if (-not $resolver) { return }
    $projectName = Split-Path -Leaf $Project
    $standing = ''
    try {
        # -Raw so a conditional registry policy is seen as itself; its own
        # "not in registry" warning is the registry's business, not this notice's.
        $standing = [string](& $resolver -Name $projectName -Raw -WarningAction SilentlyContinue).Mode
    } catch {
        $standing = ''
    }
    # A conditional policy is excluded: both of its legs are legitimate
    # classifications, so shipping either is not a deviation.
    if (-not $standing -or $standing -eq 'no-mistakes-prod-only') { return }
    if ((Get-FmDeliveryRigorRank -Mode $Mode) -ge (Get-FmDeliveryRigorRank -Mode $standing)) { return }
    Write-Warning ("notice: $TaskId ships mode=$Mode while the standing posture for $projectName is $standing " +
        '- less rigor than the captain' + "'s standing posture; proceed only on a current explicit captain " +
        'instruction or an intake judgment you can state')
}

# --- harness adapters --------------------------------------------------------
#
# The bash launch_template() carries eight adapters. This port carries the ones
# with WINDOWS evidence, and that is exactly one: Claude Code, whose Windows
# PowerShell-native mode is documented and whose crew hook surface is the only
# one this port implements. Every other adapter is KNOWN but UNVERIFIED here, and
# a spawn that names one is refused rather than being silently launched with a
# POSIX-shaped command line into a PowerShell pane - the same failure direction
# bash takes for an unknown harness, for the same reason: an adapter is a set of
# verified empirical facts about a CLI, and this port has none of them on
# Windows. The escape hatch is unchanged: pass a raw launch command.

function Get-FmHarnessAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Harness)

    $known = @{
        'claude'    = [pscustomobject]@{
            Name       = 'claude'
            Verified   = $true
            Executable = 'claude'
            ModelAxis  = $true
            EffortAxis = @('low', 'medium', 'high', 'xhigh', 'max')
        }
        'codex'     = [pscustomobject]@{ Name = 'codex'; Verified = $false; Executable = 'codex'; ModelAxis = $true; EffortAxis = @() }
        'opencode'  = [pscustomobject]@{ Name = 'opencode'; Verified = $false; Executable = 'opencode'; ModelAxis = $true; EffortAxis = @() }
        'pi'        = [pscustomobject]@{ Name = 'pi'; Verified = $false; Executable = 'pi'; ModelAxis = $true; EffortAxis = @() }
        'pi-signed' = [pscustomobject]@{ Name = 'pi-signed'; Verified = $false; Executable = 'pi-signed'; ModelAxis = $true; EffortAxis = @() }
        'grok'      = [pscustomobject]@{ Name = 'grok'; Verified = $false; Executable = 'grok'; ModelAxis = $true; EffortAxis = @() }
        'kimi'      = [pscustomobject]@{ Name = 'kimi'; Verified = $false; Executable = 'kimi'; ModelAxis = $true; EffortAxis = @() }
        'muse'      = [pscustomobject]@{ Name = 'muse'; Verified = $false; Executable = 'muse'; ModelAxis = $true; EffortAxis = @() }
    }
    if ($Harness -and $known.ContainsKey($Harness)) { return $known[$Harness] }
    $null
}

# The --model flag for a harness, or '' when the axis is unsupported or the
# model is the default. An unsupported axis is OMITTED, never guessed at: the
# requested value still lives in the task record, but it does not reach a CLI
# that was never verified to accept it.
function Get-FmHarnessModelFlag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Harness,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Model
    )
    if (-not $Model -or $Model -eq 'default') { return '' }
    $adapter = Get-FmHarnessAdapter -Harness $Harness
    if ($null -eq $adapter -or -not $adapter.ModelAxis) { return '' }
    "--model $(ConvertTo-FmPowerShellLiteral $Model) "
}

function Get-FmHarnessEffortFlag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Harness,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Effort
    )
    if (-not $Effort -or $Effort -eq 'default') { return '' }
    $adapter = Get-FmHarnessAdapter -Harness $Harness
    if ($null -eq $adapter -or $adapter.EffortAxis.Count -eq 0) { return '' }
    if ($adapter.EffortAxis -notcontains $Effort) { return '' }
    "--effort $(ConvertTo-FmPowerShellLiteral $Effort) "
}

# Assert-, not Test-: a launch whose executable is not on PATH must stop BEFORE
# any endpoint exists, or the pane is created and then sits at a shell error
# that supervision reads as a wedged worker.
function Assert-FmHarnessExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Harness)
    $adapter = Get-FmHarnessAdapter -Harness $Harness
    if ($null -eq $adapter) { throw "error: unknown harness '$Harness'" }
    $found = Get-Command -Name $adapter.Executable -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $found) {
        throw ("error: the '$($adapter.Executable)' executable was not found on PATH; install it or select a " +
            'different verified harness')
    }
    $found.Source
}

# --- harness resolution from config ------------------------------------------

function Get-FmConfigFirstLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        return $trimmed
    }
    ''
}

# config/secondmate-harness is "<harness> [<model>] [<effort>]"; config/crew-harness
# is a bare adapter name and is never parsed for a model.
function Get-FmSecondmateHarnessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][ValidateSet('Harness', 'Model', 'Effort')][string]$Field
    )
    $line = Get-FmConfigFirstLine -Path (Join-Path $ConfigDir 'secondmate-harness')
    if (-not $line) { return '' }
    $tokens = @($line -split '\s+' | Where-Object { $_ })
    $index = switch ($Field) { 'Harness' { 0 } 'Model' { 1 } 'Effort' { 2 } }
    if ($tokens.Count -le $index) { return '' }
    $tokens[$index]
}

# The harness firstmate itself runs on. Get-FmHarness is the harness area's; when
# it is absent this falls back to the one marker this port can read for itself
# and otherwise says 'unknown', which every caller treats as "no usable answer".
function Get-FmOwnHarness {
    [CmdletBinding()]
    param()
    $resolver = Get-Command -Name Get-FmHarness -CommandType Function -ErrorAction SilentlyContinue
    if ($resolver) {
        $value = [string](& $resolver)
        if ($value) { return $value.Trim() }
    }
    if ($env:CLAUDECODE -eq '1') { return 'claude' }
    'unknown'
}

# Resolve the harness for a spawn that named none.
#
# Resolving on EVERY spawn is what makes the secondmate-vs-crewmate split durable
# across respawns. The crew-dispatch.json refusal is the consultation backstop:
# when a dispatch profile is active, a crewmate/scout spawn must name the harness
# the profile chose, so the profile can never be silently skipped.
function Get-FmConfiguredHarness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][ValidateSet('ship', 'scout', 'secondmate')][string]$Kind
    )
    if ($Kind -eq 'secondmate') {
        $harness = Get-FmSecondmateHarnessToken -ConfigDir $ConfigDir -Field 'Harness'
        if ($harness -and $harness -ne 'default') {
            return [pscustomobject]@{ Harness = $harness; Source = 'config/secondmate-harness' }
        }
        $crew = Get-FmConfigFirstLine -Path (Join-Path $ConfigDir 'crew-harness')
        if ($crew -and $crew -ne 'default') {
            return [pscustomobject]@{ Harness = $crew; Source = 'config/crew-harness' }
        }
        return [pscustomobject]@{ Harness = (Get-FmOwnHarness); Source = 'own harness' }
    }
    if (Test-Path -LiteralPath (Join-Path $ConfigDir 'crew-dispatch.json') -PathType Leaf) {
        throw ('error: config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch ' +
            'rules (the consultation backstop, so the rules are never silently skipped).')
    }
    $crew = Get-FmConfigFirstLine -Path (Join-Path $ConfigDir 'crew-harness')
    if ($crew -and $crew -ne 'default') {
        return [pscustomobject]@{ Harness = $crew; Source = 'config/crew-harness' }
    }
    [pscustomobject]@{ Harness = (Get-FmOwnHarness); Source = 'own harness' }
}

# --- the resolved spawn plan -------------------------------------------------

# Everything a spawn must decide BEFORE it touches the fleet: the delivery
# contract, the harness, the launch command, and the profile axes. Every failure
# here is a refusal, and every refusal happens before a worktree is leased or an
# endpoint exists, so a refused spawn leaves nothing behind.
function Resolve-FmSpawnPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][ValidateSet('ship', 'scout', 'secondmate')][string]$Kind,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter()][AllowEmptyString()][string]$Harness = '',
        [Parameter()][AllowEmptyString()][string]$LaunchCommand = '',
        [Parameter()][AllowEmptyString()][string]$Mode = '',
        [Parameter()][AllowEmptyString()][string]$Yolo = '',
        [Parameter()][AllowEmptyString()][string]$Model = '',
        [Parameter()][AllowEmptyString()][string]$Effort = ''
    )
    Assert-FmDeliveryContract -Kind $Kind -Mode $Mode -Yolo $Yolo
    if ($Kind -eq 'ship') {
        Assert-FmBriefDeliveryAgreement -TaskId $TaskId -BriefPath $BriefPath -Mode $Mode
        Write-FmDeliveryPostureNotice -TaskId $TaskId -Project $Project -Mode $Mode
    }

    $harnessName = $Harness
    $harnessSource = 'explicit'
    if (-not $harnessName) {
        if ($LaunchCommand) {
            # A raw launch command is the unverified-adapter escape hatch. The
            # harness NAME is still recorded, derived from the first word that is
            # not an environment assignment, exactly as bash derives it.
            $harnessSource = 'raw launch command'
            foreach ($word in ($LaunchCommand -split '\s+' | Where-Object { $_ })) {
                if ($word -match '^\$env:' -or $word -match '^[A-Za-z_][A-Za-z0-9_]*=') { continue }
                $harnessName = Split-Path -Leaf ($word.Trim("'", '"'))
                break
            }
        } else {
            $resolved = Get-FmConfiguredHarness -ConfigDir $ConfigDir -Kind $Kind
            $harnessName = $resolved.Harness
            $harnessSource = $resolved.Source
        }
    }
    if (-not $harnessName) {
        throw "error: no harness could be resolved for task $TaskId, and no raw launch command was given"
    }

    # config/secondmate-harness may pin model and effort alongside the harness.
    # They apply only when this spawn also resolved its harness from that file,
    # and an explicit flag always wins.
    if ($Kind -eq 'secondmate' -and $harnessSource -eq 'config/secondmate-harness') {
        if (-not $Model) { $Model = Get-FmSecondmateHarnessToken -ConfigDir $ConfigDir -Field 'Model' }
        if (-not $Effort) {
            $token = Get-FmSecondmateHarnessToken -ConfigDir $ConfigDir -Field 'Effort'
            if ($token) {
                if (@('low', 'medium', 'high', 'xhigh', 'max') -contains $token) {
                    $Effort = $token
                } else {
                    Write-Warning ("config/secondmate-harness effort token '$token' is not one of low, medium, " +
                        'high, xhigh, max; ignoring')
                }
            }
        }
    }

    $launch = $LaunchCommand
    if (-not $launch) {
        $launch = Get-FmHarnessLaunchCommand -Harness $harnessName -BriefPath $BriefPath `
            -Model $Model -Effort $Effort -Kind $Kind
    }

    [pscustomobject]@{
        TaskId        = $TaskId
        Kind          = $Kind
        Harness       = $harnessName
        HarnessSource = $harnessSource
        LaunchCommand = $launch
        Mode          = $Mode
        Yolo          = $Yolo
        Model         = $Model
        Effort        = $Effort
    }
}

# --- the task record: state/<id>.meta ----------------------------------------

# The field ORDER is bin/fm-spawn.sh's, byte for byte, because a Linux firstmate
# reads this file. Optional fields are omitted exactly where bash omits them:
# mode/yolo only on a ship, backend only when it is not the default tmux (absent
# backend= MEANS tmux), the herdr_* quartet only on herdr, home/projects only on
# a secondmate. treehouse_lease_id is this port's own field - the durable lease
# identity that replaced scraping a pane's cwd - and is written last so a reader
# that does not know it simply never reaches it.
function ConvertTo-FmTaskRecordField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Window,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Harness,
        [Parameter(Mandatory)][ValidateSet('ship', 'scout', 'secondmate')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$Mode = '',
        [Parameter()][AllowEmptyString()][string]$Yolo = '',
        [Parameter(Mandatory)][string]$TaskTmp,
        [Parameter()][AllowEmptyString()][string]$Model = '',
        [Parameter()][AllowEmptyString()][string]$Effort = '',
        [Parameter()][AllowEmptyString()][string]$BusyGeneration = '',
        [Parameter()][AllowEmptyString()][string]$Backend = 'tmux',
        [Parameter()][AllowEmptyString()][string]$HerdrSession = '',
        [Parameter()][AllowEmptyString()][string]$HerdrWorkspaceId = '',
        [Parameter()][AllowEmptyString()][string]$HerdrTabId = '',
        [Parameter()][AllowEmptyString()][string]$HerdrPaneId = '',
        # NOT -Home: $Home is a read-only automatic variable, so a parameter of
        # that name cannot even be bound.
        [Parameter()][AllowEmptyString()][string]$SecondmateHome = '',
        [Parameter()][AllowEmptyString()][string]$ProjectList = '',
        [Parameter()][AllowEmptyString()][string]$LeaseId = ''
    )
    $fields = [ordered]@{
        window           = $Window
        endpoint_task_id = $TaskId
        worktree         = $Worktree
        project          = $Project
        harness          = $Harness
        kind             = $Kind
    }
    if ($Mode) { $fields['mode'] = $Mode }
    if ($Yolo) { $fields['yolo'] = $Yolo }
    $fields['tasktmp'] = $TaskTmp
    $fields['model'] = $(if ($Model) { $Model } else { 'default' })
    $fields['effort'] = $(if ($Effort) { $Effort } else { 'default' })
    if ($BusyGeneration) { $fields['busy_gen'] = $BusyGeneration }
    if ($Backend -and $Backend -ne 'tmux') { $fields['backend'] = $Backend }
    if ($Backend -eq 'herdr') {
        $fields['herdr_session'] = $HerdrSession
        $fields['herdr_workspace_id'] = $HerdrWorkspaceId
        $fields['herdr_tab_id'] = $HerdrTabId
        $fields['herdr_pane_id'] = $HerdrPaneId
    }
    if ($Kind -eq 'secondmate') {
        $fields['home'] = $(if ($SecondmateHome) { $SecondmateHome } else { $Project })
        $fields['projects'] = $ProjectList
    }
    if ($LeaseId) { $fields['treehouse_lease_id'] = $LeaseId }
    $fields
}
