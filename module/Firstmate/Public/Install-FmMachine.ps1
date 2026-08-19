#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Check every requirement this machine has, classify each one, and say where a
    missing one genuinely comes from.

.DESCRIPTION
    Detection only. Nothing on disk is written, so it is safe to run at any time,
    and it is what install.ps1 shows the captain before asking anything. The one
    thing it does change is THIS process's PATH, which it reloads from the
    persisted environment first: a tool installed into a per-user directory by an
    earlier run is on the durable PATH and not on this shell's copy of it, so a
    plan that skipped that step would report a tool that is present as missing.

    ASSUMES NOTHING IS ALREADY THERE. Every requirement is checked, including the
    shell version and the two enablers the installer would itself USE - winget
    and npm - so an absent one is an explained skip rather than a "command not
    found" in the middle of a run.

    Each requirement lands in exactly one class, and the difference between the
    middle two is the whole point:

      missing          not installed; install it
      older            installed and working, behind the latest published
                       version. Optional to update, and the safe answer is no.
      unsupported      installed but below a minimum this repo actually STATES.
                       Cannot work; the step is skipped rather than installed
                       over.
      current          installed and at the latest published version
      unknown-version  installed but prints no readable version, so nothing
                       about it is proven
      unknown-latest   installed, but the published version could not be read,
                       so whether it is current is unknown

    A minimum is only a minimum when this repo states one, and each requirement
    carries where its minimum comes from. Nothing here invents a threshold.

    Every 'older' and 'unknown-version' requirement carries the full Question to
    put to the captain - what is installed, what is available, and what happens
    if they decline. The asking belongs to install.ps1; this decides what is
    worth asking.

.PARAMETER SkipOptional
    Leave the optional tools out of the plan entirely.

.PARAMETER Offline
    Do not look up what each vendor publishes. Everything present is then
    classified 'unknown-latest' and reported as such, rather than being called
    current on no evidence.

.OUTPUTS
    A plan record: Requirements, Enablers, Excluded, and the lines that render it.

.EXAMPLE
    (Get-FmMachineInstallPlan).Requirements | Where-Object Classification -eq 'missing'
#>
function Get-FmMachineInstallPlan {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [switch]$SkipOptional,
        [switch]$Offline
    )

    $null = Update-FmToolSessionPath -Confirm:$false
    $requirements = @()

    foreach ($entry in (Get-FmToolCatalog)) {
        if ($SkipOptional -and -not $entry.Required) { continue }
        $status = Get-FmToolStatus -Command $entry.Command
        $minimum = Get-FmToolMinimum -Tool $entry.Tool
        $latest = if ($status.Present -and -not $Offline) { Get-FmToolLatestVersion -Tool $entry.Tool } else { '' }
        $capabilityMet = if ($status.Present) { Test-FmToolCapability -Tool $entry.Tool } else { $true }

        $route = Get-FmToolRoute -Tool $entry.Tool
        $requirement = [pscustomobject]@{
            Kind              = 'tool'
            Name              = $entry.Tool
            Command           = $entry.Command
            Label             = $entry.Label
            Why               = $entry.Why
            Required          = $entry.Required
            Present           = $status.Present
            Path              = $status.Path
            Version           = $status.Version
            Latest            = $latest
            Minimum           = $minimum.Version
            MinimumSource     = $minimum.Source
            MinimumCapability = $minimum.Capability
            Classification    = (Get-FmToolClassification -Present $status.Present -Installed $status.Version `
                    -Latest $latest -Minimum $minimum.Version -CapabilityMet $capabilityMet)
            Route             = $route
            # What the CAPTAIN should run to replace what is there, which is not
            # always what installs it fresh: `winget install` on an installed
            # package says "already installed" and upgrades nothing.
            UpdateCommand     = (Get-FmToolUpdateCommand -Command $route.Command)
            Reason            = ''
            Question          = ''
        }
        $requirement.Reason = Get-FmToolClassificationReason -Requirement $requirement
        $requirement.Question = Get-FmMachineQuestion -Requirement $requirement
        $requirements += $requirement
    }

    foreach ($module in (Get-FmToolModuleRequirement)) {
        $status = Get-FmToolModuleStatus -Requirement $module
        $latest = if ($status.Present -and -not $Offline) { Get-FmToolModuleLatestVersion -Name $module.Name } else { '' }
        $requirement = [pscustomobject]@{
            Kind              = 'module'
            Name              = $module.Name
            Command           = $module.Name
            Label             = "module $($module.Name)"
            Why               = $module.Why
            # Neither module is needed to RUN firstmate, and both are needed to
            # PROVE it works, so they are not required tools and their absence is
            # still worth installing without asking.
            Required          = $false
            Present           = $status.Present
            Path              = $status.Path
            Version           = $status.Version
            Latest            = $latest
            Minimum           = $module.MinimumVersion
            MinimumSource     = $module.MinimumSource
            MinimumCapability = ''
            Classification    = (Get-FmToolClassification -Present $status.Present -Installed $status.Version `
                    -Latest $latest -Minimum $module.MinimumVersion)
            Route             = [pscustomobject]@{
                Tool               = $module.Name
                Kind               = 'module'
                Command            = "Install-Module $($module.Name) -Scope CurrentUser"
                Portable           = $null
                NeedsAdministrator = $false
                Instructions       = ''
            }
            UpdateCommand     = "Install-Module $($module.Name) -Scope CurrentUser -Force"
            Reason            = ''
            Question          = ''
        }
        $requirement.Reason = Get-FmToolClassificationReason -Requirement $requirement
        $requirement.Question = Get-FmMachineQuestion -Requirement $requirement
        $requirements += $requirement
    }

    $enablers = @(Get-FmToolEnablerStatus)
    $excluded = @(Get-FmToolExcluded)

    $lines = @('  what this machine has:')
    foreach ($enabler in $enablers) {
        $mark = if ($enabler.Satisfied) { '[ok]' } else { '[missing]' }
        $detail = if ($enabler.Satisfied -and $enabler.Version) { $enabler.Version } else { "needed for $($enabler.Enables)" }
        $lines += ('    {0,-14}{1,-24}{2}' -f $mark, $enabler.Name, $detail)
    }
    $lines += ''
    foreach ($requirement in $requirements) {
        $mark = switch ($requirement.Classification) {
            'current' { '[ok]' }
            'missing' { '[missing]' }
            'older' { '[older]' }
            'unsupported' { '[unsupported]' }
            default { '[unknown]' }
        }
        $lines += ('    {0,-14}{1,-24}{2}' -f $mark, $requirement.Label, $requirement.Reason)
    }
    foreach ($item in $excluded) {
        $lines += ('    {0,-14}{1,-24}{2}' -f '[skipped]', $item.Tool, $item.Reason)
    }

    [pscustomobject]@{
        Requirements = $requirements
        Enablers     = $enablers
        Excluded     = $excluded
        Missing      = @($requirements | Where-Object { $_.Classification -eq 'missing' })
        Older        = @($requirements | Where-Object { $_.Classification -in @('older', 'unknown-version') })
        Unsupported  = @($requirements | Where-Object { $_.Classification -eq 'unsupported' })
        Lines        = $lines
    }
}

<#
.SYNOPSIS
    The question to put to the captain about one requirement, or '' when there is
    nothing to ask.

.DESCRIPTION
    A prompt is only legitimate if it says what is installed, what is available,
    and what happens if the captain declines - a bare "Update? y/n" makes the
    captain guess at the consequence of their own answer.

    Only two classes carry a question. 'missing' is not one of them: installing
    what is absent is what the script is for. 'unsupported' is not one either:
    that one is TOLD, not asked, because the answer must never be "install over
    the top of it".

.PARAMETER Requirement
    One requirement record from Get-FmMachineInstallPlan.

.OUTPUTS
    The question text, or an empty string.

.EXAMPLE
    Get-FmMachineQuestion -Requirement $plan.Older[0]
#>
function Get-FmMachineQuestion {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Requirement)

    switch ($Requirement.Classification) {
        'older' {
            return ("$($Requirement.Label): $($Requirement.Version) is installed and working; $($Requirement.Latest) is published. " +
                "Update it? Declining leaves $($Requirement.Version) exactly where it is and the rest of the install carries on.")
        }
        'unknown-version' {
            return ("$($Requirement.Label): resolves to $($Requirement.Path) but prints no version this installer can read, " +
                'so it cannot be shown to be the real tool. Reinstall it from its official source? ' +
                'Declining leaves it exactly as it is and the rest of the install carries on.')
        }
        default { return '' }
    }
}

<#
.SYNOPSIS
    Take a machine that has cloned this repo to a working firstmate, and prove it.

.DESCRIPTION
    The whole of install.ps1, as a function, so every decision in it is testable
    and held to the same analyzer bar as the rest of the module.

    It does five things, in this order:

      1. acts on each requirement's class - installs what is MISSING from its
         genuine source, updates only what the captain named in -UpdateTool, and
         SKIPS anything UNSUPPORTED rather than installing over the top of it,
      2. installs Pester and PSScriptAnalyzer into the user's own module
         directory, which the suite and the analyzer bar need,
      3. runs the home setup (Install-FmHome): the home layout, the herdr
         backend, the home pointer, the two committed symlinks a Windows clone
         does not get, the skip-worktree protection that stops `git checkout`
         emptying the skills tree, the profile wiring and the Claude hooks,
      4. writes the `firstmate` command onto the user's PATH,
      5. PROVES the result: every tool is run and made to print a version, the
         doctor re-reads the home and the instruction surface, and the
         repository's own test suite is executed.

    NO STEP REQUIRES ADMINISTRATOR. A route that truly does is named, skipped,
    and reported with the exact command to run in an elevated shell; the rest of
    the run continues.

    NEVER INSTALLS UNASKED. AGENTS.md section 3 is detect, ask, then install, so
    without -Approved this prints the plan and writes nothing. install.ps1 is
    what asks the captain and passes the answers through.

    RE-RUNNING IS SAFE. Nothing already current is touched, setup reports
    'already' for each of its steps, and the command shim is written only when it
    differs.

    A PARTIAL FAILURE IS REPORTED, NOT HIDDEN. Every requirement is attempted,
    whatever the ones before it did, and the end report lists every one of them
    with its outcome. An unsupported-and-skipped requirement means the machine is
    NOT fully ready, and the verdict says exactly that rather than ending on a
    cheerful note.

.PARAMETER Approved
    Assert that the captain approved this install in the current session.

.PARAMETER UpdateTool
    The names of the requirements the captain agreed to update. Anything not
    named here that is merely older is left exactly as it is.

.PARAMETER Plan
    A plan Get-FmMachineInstallPlan already produced. install.ps1 passes the one
    it showed the captain, so the vendors are not asked what they publish a
    second time between the question and the answer. Omitted, one is computed.

.PARAMETER SkipOptional
    Install only what firstmate cannot run without.

.PARAMETER SkipSuite
    Do not run the test suite in the verification pass. The verdict then says so
    rather than claiming a pass it did not take.

.PARAMETER Offline
    Do not look up what each vendor publishes; classify everything present as
    'unknown-latest' instead.

.PARAMETER RepoRoot
    The checkout to install. Defaults to the one this module was loaded from.

.PARAMETER InstallRoot
    Where a portable tool and the `firstmate` command are installed. Defaults to
    %LOCALAPPDATA%\Programs. Overridable so the suite can exercise the real
    expansion into a disposable directory.

.PARAMETER PathScope
    Whether a new bin directory is added to the durable USER PATH or only to this
    process. 'Process' is for the suite, which must not edit the captain's
    environment.

.OUTPUTS
    A report: Installed, Verified, Ready, Outcomes, Checks, Suite and the lines
    that render all of it.

.EXAMPLE
    ./install.ps1

.EXAMPLE
    Install-FmMachine -Approved -UpdateTool gh, node
#>
function Install-FmMachine {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [switch]$Approved,
        [string[]]$UpdateTool = @(),
        [object]$Plan = $null,
        [switch]$SkipOptional,
        [switch]$SkipSuite,
        [switch]$Offline,
        [string]$RepoRoot = '',
        [string]$InstallRoot = '',
        [ValidateSet('User', 'Process')][string]$PathScope = 'User'
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'module' 'Firstmate') -PathType Container)) {
        throw "error: '$RepoRoot' does not look like a firstmate-win checkout (no module/Firstmate); refusing to install from it"
    }

    # A tool installed into a per-user directory by an earlier run is on the
    # persisted PATH and not on this shell's copy of it, so detection has to read
    # the environment before it reads PATH.
    $null = Update-FmToolSessionPath -Confirm:$false
    $plan = if ($Plan) { $Plan } else { Get-FmMachineInstallPlan -SkipOptional:$SkipOptional -Offline:$Offline }

    if (-not $Approved) {
        return [pscustomobject]@{
            Installed = $false
            Verified  = $false
            Ready     = $false
            Reason    = 'refused: Install-FmMachine needs -Approved. It detects, then asks for consent, then installs - never installs unasked.'
            Plan      = $plan
            Outcomes  = @()
            Steps     = @()
            Checks    = @()
            Suite     = $null
            Lines     = @('install: REFUSED - nothing was installed.', '') + $plan.Lines
        }
    }

    $performed = $PSCmdlet.ShouldProcess($RepoRoot, 'install firstmate on this machine')
    $steps = @()
    $outcomes = @()

    # --- 1 and 2. every requirement, by its class -------------------------------
    foreach ($requirement in $plan.Requirements) {
        $outcome = [pscustomobject]@{
            Label          = $requirement.Label
            Classification = $requirement.Classification
            Outcome        = ''
            Detail         = ''
        }

        if (-not $performed) {
            $outcome.Outcome = 'skipped'
            $outcome.Detail = 'WhatIf'
            $outcomes += $outcome
            continue
        }

        # UNSUPPORTED IS TOLD, NOT REPAIRED. Installing over a version the
        # captain has not agreed to replace is exactly the uninvited repair the
        # addendum forbids, and letting the run finish looking successful with an
        # unusable tool in place is what makes it dangerous.
        if ($requirement.Classification -eq 'unsupported') {
            $outcome.Outcome = 'unsupported-skipped'
            $outcome.Detail = "$($requirement.Reason). Update it yourself, then re-run: $($requirement.UpdateCommand)"
            $outcomes += $outcome
            $steps += New-FmInstallStep -Name $requirement.Label -Action 'skipped' -Detail ('UNSUPPORTED: ' + $outcome.Detail)
            continue
        }

        $wanted = switch ($requirement.Classification) {
            'missing' { $true }
            'older' { $UpdateTool -contains $requirement.Name }
            'unknown-version' { $UpdateTool -contains $requirement.Name }
            default { $false }
        }
        if (-not $wanted) {
            $outcome.Outcome = switch ($requirement.Classification) {
                'current' { 'already-current' }
                'older' { 'older-kept' }
                'unknown-version' { 'kept-unproven' }
                default { 'already-present' }
            }
            $outcome.Detail = $requirement.Reason
            $outcomes += $outcome
            continue
        }

        $updating = ($requirement.Classification -ne 'missing')
        if ($requirement.Kind -eq 'module') {
            $module = @(Get-FmToolModuleRequirement | Where-Object { $_.Name -eq $requirement.Name })[0]
            $result = Install-FmToolModule -Requirement $module -Update:$updating -Confirm:$false
        } else {
            $result = Invoke-FmToolRoute -Route $requirement.Route `
                -InstallRoot $InstallRoot -PathScope $PathScope -Update:$updating -Confirm:$false
            # PATH is reloaded after every install, so the tool just written into
            # a per-user directory is visible to the next detection and to the
            # verification pass, without opening a new shell.
            $null = Update-FmToolSessionPath -Confirm:$false
        }

        $outcome.Outcome = switch ($result.Action) {
            'installed' { if ($updating) { 'updated' } else { 'installed' } }
            'updated' { 'updated' }
            'failed' { 'failed' }
            'blocked' { 'blocked' }
            'needs-admin' { 'needs-administrator' }
            'manual' { 'manual' }
            default { 'skipped' }
        }
        $outcome.Detail = $result.Detail
        $outcomes += $outcome

        $stepAction = if ($outcome.Outcome -in @('installed', 'updated')) { 'created' } else { 'skipped' }
        $prefix = if ($outcome.Outcome -in @('failed', 'blocked', 'needs-administrator', 'manual')) { $outcome.Outcome.ToUpperInvariant() + ': ' } else { '' }
        $steps += New-FmInstallStep -Name $requirement.Label -Action $stepAction -Detail ($prefix + $outcome.Detail)
    }

    # --- 3. the home, the symlinks, the protection, the hooks -------------------
    if ($performed) {
        $setup = Install-FmHome -RepoRoot $RepoRoot -Confirm:$false
        $steps += @($setup.Steps)
        if (-not $setup.Installed) {
            return [pscustomobject]@{
                Installed = $false
                Verified  = $false
                Ready     = $false
                Reason    = $setup.Reason
                Plan      = $plan
                Outcomes  = $outcomes
                Steps     = $steps
                Checks    = @($setup.Checks)
                Suite     = $null
                Lines     = @('install: REFUSED by setup - the machine was left as it was.', '') +
                    @($steps | ForEach-Object { Format-FmInstallStepLine -Step $_ }) + @('') + @($setup.Lines)
            }
        }

        # --- 4. the one-word command -------------------------------------------
        $shim = Set-FmMachineCommandShim -RepoRoot $RepoRoot -InstallRoot $InstallRoot -PathScope $PathScope -Confirm:$false
        $steps += New-FmInstallStep -Name 'firstmate command' -Action $shim.Action -Detail $shim.Detail
    } else {
        $steps += New-FmInstallStep -Name 'home' -Action 'skipped' -Detail 'WhatIf'
        $steps += New-FmInstallStep -Name 'firstmate command' -Action 'skipped' -Detail 'WhatIf'
    }

    # --- 5. the proof ------------------------------------------------------------
    #
    # The tool group and the doctor's prerequisite group deliberately overlap on
    # herdr, treehouse and the Claude CLI, because they answer different
    # questions at different thresholds: the doctor asks whether this HOME is
    # healthy, where an absent herdr is a warning, and this asks whether the
    # INSTALL delivered what it promised, where a required tool that cannot print
    # a version is a failure.
    $toolChecks = @(Get-FmMachineToolVerification -SkipOptional:$SkipOptional)
    $moduleChecks = @(Get-FmMachineModuleVerification)
    $doctor = Invoke-FmDoctor -RepoRoot $RepoRoot

    $suite = $null
    $suiteCheck = @()
    if ($SkipSuite -or -not $performed) {
        $suiteCheck += New-FmInstallCheck -Name 'test suite' -Status 'warn' `
            -Detail $(if ($performed) { 'not run (-SkipSuite), so this install is not proven by the suite' } else { 'not run (WhatIf)' }) `
            -Fix "Invoke-Pester -Path (Join-Path '$RepoRoot' 'tests')"
    } else {
        $suite = Invoke-FmMachineSuite -RepoRoot $RepoRoot
        if (-not $suite.Ran) {
            $suiteCheck += New-FmInstallCheck -Name 'test suite' -Status 'missing' -Required -Detail $suite.Detail `
                -Fix "Invoke-Pester -Path (Join-Path '$RepoRoot' 'tests')"
        } elseif ($suite.Failed -gt 0) {
            $named = @($suite.FailedNames | Select-Object -First 5)
            $suiteCheck += New-FmInstallCheck -Name 'test suite' -Status 'missing' -Required `
                -Detail ($suite.Detail + $(if ($named.Count) { ' - first failures: ' + ($named -join '; ') } else { '' })) `
                -Fix "Invoke-Pester -Path (Join-Path '$RepoRoot' 'tests')"
        } else {
            $suiteCheck += New-FmInstallCheck -Name 'test suite' -Status 'ok' -Detail $suite.Detail
        }
    }

    $checks = $toolChecks + $moduleChecks + @($doctor.Checks) + $suiteCheck
    $blocking = @($checks | Where-Object { $_.Status -eq 'missing' })
    $warnings = @($checks | Where-Object { $_.Status -eq 'warn' })
    $unsupported = @($outcomes | Where-Object { $_.Outcome -eq 'unsupported-skipped' })
    $failed = @($outcomes | Where-Object { $_.Outcome -in @('failed', 'blocked', 'needs-administrator') })
    $verified = ($performed -and $blocking.Count -eq 0)
    $ready = ($verified -and $unsupported.Count -eq 0 -and $failed.Count -eq 0)

    $lines = @("install: $RepoRoot", '')
    $lines += @($steps | ForEach-Object { Format-FmInstallStepLine -Step $_ })
    $lines += @('', 'verification - tools:')
    $lines += @($toolChecks + $moduleChecks | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('', 'verification - home, wiring and instructions:')
    $lines += @($doctor.Checks | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('', 'verification - the suite:')
    $lines += @($suiteCheck | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('') + @(Get-FmMachineOptionalLine -FirstmateHome $doctor.FirstmateHome)
    $lines += @('') + (Get-FmMachineSummaryLine -Outcomes $outcomes)
    $lines += ''
    if (-not $performed) {
        $lines += 'install: WhatIf - nothing was installed, and nothing above was proven.'
    } elseif ($ready -and $warnings.Count -eq 0) {
        $lines += 'READY: every tool answered with a version, the instructions are present, and the suite passed.'
    } elseif ($ready) {
        $lines += "READY, with $($warnings.Count) warning(s) - each line above says what it costs."
    } elseif ($unsupported.Count -gt 0) {
        $lines += ("NOT READY: $($unsupported.Count) requirement(s) are installed at a version this repo cannot work with and were SKIPPED, " +
            'so this machine is not fully set up. Update the tools named above, then re-run ./install.ps1.')
    } else {
        $lines += ("NOT READY: $($blocking.Count) check(s) failed and $($failed.Count) install(s) did not complete. " +
            'Fix the failures above, then re-run ./install.ps1.')
    }

    [pscustomobject]@{
        Installed = $performed
        Verified  = $verified
        Ready     = $ready
        Reason    = ''
        Plan      = $plan
        Outcomes  = $outcomes
        Steps     = $steps
        Checks    = $checks
        Doctor    = $doctor
        Suite     = $suite
        Lines     = $lines
    }
}

<#
.SYNOPSIS
    The end-of-run summary: every requirement and exactly what happened to it.

.DESCRIPTION
    The deliverable of a run. Anyone reading it should know what state the
    machine is in without running anything else, so every requirement appears -
    including the ones nothing was done to - with the outcome spelled out rather
    than implied by its absence.

.PARAMETER Outcomes
    The per-requirement outcome records from Install-FmMachine.

.OUTPUTS
    The rendered summary lines.

.EXAMPLE
    Get-FmMachineSummaryLine -Outcomes (Install-FmMachine -Approved).Outcomes
#>
function Get-FmMachineSummaryLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Outcomes)

    $wording = @{
        'installed'           = 'installed'
        'updated'             = 'updated'
        'already-current'     = 'already current'
        'already-present'     = 'already present'
        'older-kept'          = 'older, left alone at your choice'
        'kept-unproven'       = 'present but unproven, left alone at your choice'
        'unsupported-skipped' = 'UNSUPPORTED, skipped'
        'failed'              = 'FAILED'
        'blocked'             = 'BLOCKED'
        'needs-administrator' = 'NEEDS ADMINISTRATOR, skipped'
        'manual'              = 'manual step, not installed'
        'skipped'             = 'skipped'
    }

    $lines = @('summary - every requirement and what happened to it:')
    foreach ($outcome in $Outcomes) {
        $word = if ($wording.ContainsKey($outcome.Outcome)) { $wording[$outcome.Outcome] } else { $outcome.Outcome }
        $lines += ('    {0,-24} {1,-42} {2}' -f $outcome.Label, $word, $outcome.Detail)
    }
    $lines
}
