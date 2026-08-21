#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Check every requirement this machine has, classify each one, and say where a
    missing one genuinely comes from.

.DESCRIPTION
    Detection, and it is what install.ps1 shows the captain before asking
    anything. Nothing on disk is left changed, so it is safe to run at any time.

    TWO THINGS IT DOES TOUCH, both stated because "nothing is written" would not
    be true. It reloads THIS process's PATH from the persisted environment: a
    tool installed into a per-user directory by an earlier run is on the durable
    PATH and not on this shell's copy of it, so a plan that skipped that step
    would report a tool that is present as missing. And it writes one probe
    directory and file into the checkout and removes them again, because whether
    a location can be installed into is only answerable by writing to it -
    Get-FmMachineLocationCheck owns that, and its removal is in a finally.

    ASSUMES NOTHING IS ALREADY THERE. Every requirement is checked, including the
    shell version and the two enablers the installer would itself USE - winget
    and npm - so an absent one is an explained skip rather than a "command not
    found" in the middle of a run.

    Each requirement lands in exactly one class, and the difference between the
    middle two is the whole point:

      missing          not installed; install it
      unusable         installed, and this machine refuses to START it. Nothing
                       is installed over the top - a second copy in the same
                       place would be refused the same way - and the run says so
                       in the captain's words rather than raising the .NET error
                       the refusal arrives as.
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
        [switch]$Offline,
        [string]$RepoRoot = ''
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    $null = Update-FmToolSessionPath -Confirm:$false
    # WHERE THE CHECKOUT IS, ASKED FIRST. A location this machine guards refuses
    # the install two thirds of the way through, with a message about whichever
    # step happened to write first rather than about the location - so the
    # question is answered before anything is attempted, and the answer is
    # carried all the way to the final report.
    $location = Get-FmMachineLocationCheck -Path $RepoRoot
    $requirements = @()

    foreach ($entry in (Get-FmToolCatalog)) {
        if ($SkipOptional -and -not $entry.Required) { continue }
        $status = Get-FmToolStatus -Command $entry.Command
        $minimum = Get-FmToolMinimum -Tool $entry.Tool
        # Nothing is asked of the vendor, and no capability probe is run, for a
        # tool this machine will not START: both questions are about a program
        # that never ran, and the answers would be about nothing.
        $usable = ($status.Present -and $status.Launchable)
        $latest = if ($usable -and -not $Offline) { Get-FmToolLatestVersion -Tool $entry.Tool } else { '' }
        $capabilityMet = if ($usable) { Test-FmToolCapability -Tool $entry.Tool } else { $true }

        $route = Get-FmToolRoute -Tool $entry.Tool
        $requirement = [pscustomobject]@{
            Kind              = 'tool'
            Name              = $entry.Tool
            Command           = $entry.Command
            Label             = $entry.Label
            Why               = $entry.Why
            Required          = $entry.Required
            Present           = $status.Present
            Launchable        = $status.Launchable
            Path              = $status.Path
            Version           = $status.Version
            Latest            = $latest
            Minimum           = $minimum.Version
            MinimumSource     = $minimum.Source
            MinimumCapability = $minimum.Capability
            # A tool is installed OVER what is there, so a version below a
            # stated floor is told and skipped rather than replaced.
            Supersedable      = $false
            Classification    = (Get-FmToolClassification -Present $status.Present -Installed $status.Version `
                    -Latest $latest -Minimum $minimum.Version -CapabilityMet $capabilityMet -Launchable $status.Launchable)
            Route             = $route
            # What the CAPTAIN should run to replace what is there, which is not
            # always what installs it fresh: `winget install` on an installed
            # package says "already installed" and upgrades nothing.
            #
            # Through Get-FmToolFixCommand first, because a portable route's
            # Command is a DESCRIPTION - "expand the cli/cli release asset ..." -
            # and this line is printed to the captain as something to run. No
            # portable tool carries a stated minimum today, so the line is not
            # reachable yet; giving one a floor later must not silently turn it
            # into a sentence.
            UpdateCommand     = (Get-FmToolUpdateCommand -Command (Get-FmToolFixCommand -Route $route))
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
            # A module is imported, never started as a program, so the launch
            # question does not arise - but the field is here because both kinds
            # of requirement flow into ONE set of consumers, and a record that is
            # a field short throws under strict mode rather than degrading.
            Launchable        = $status.Present
            Path              = $status.Path
            Version           = $status.Version
            Latest            = $latest
            Minimum           = $module.MinimumVersion
            MinimumSource     = $module.MinimumSource
            MinimumCapability = ''
            # A module is not. PowerShell keeps every version of a module in its
            # own version directory, so Install-Module -Scope CurrentUser adds
            # one to the user's own tree and removes nothing - which is what
            # makes Windows' own Pester 3.4.0 this run's job rather than the
            # captain's.
            Supersedable      = $true
            Classification    = (Get-FmToolClassification -Present $status.Present -Installed $status.Version `
                    -Latest $latest -Minimum $module.MinimumVersion -Supersedable $true)
            Route             = [pscustomobject]@{
                Tool               = $module.Name
                Kind               = 'module'
                Command            = (Get-FmToolModuleInstallCommand -Name $module.Name -MinimumVersion $module.MinimumVersion)
                Portable           = $null
                NeedsAdministrator = $false
                Instructions       = ''
            }
            UpdateCommand     = (Get-FmToolModuleInstallCommand -Name $module.Name -MinimumVersion $module.MinimumVersion -Force)
            Reason            = ''
            Question          = ''
        }
        $requirement.Reason = Get-FmToolClassificationReason -Requirement $requirement
        $requirement.Question = Get-FmMachineQuestion -Requirement $requirement
        $requirements += $requirement
    }

    $enablers = @(Get-FmToolEnablerStatus)
    $excluded = @(Get-FmToolExcluded)

    $lines = @()
    if (-not $location.Usable) {
        $lines += @("  THIS CHECKOUT IS SOMEWHERE THE INSTALL CANNOT FINISH: $($location.Path)",
            "    $($location.Reason)",
            "    Clone it here instead, and run install.ps1 from there: $($location.Suggestion)",
            '')
    } elseif (@($location.Concerns).Count -gt 0) {
        $lines += @("  where this checkout is: $($location.Path)")
        foreach ($concern in @($location.Concerns)) { $lines += "    $concern" }
        $lines += ''
    }
    $lines += '  what this machine has:'
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
            'superseded' { '[superseded]' }
            'unusable' { '[unusable]' }
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
        Location     = $location
        RepoRoot     = $RepoRoot
        Missing      = @($requirements | Where-Object { $_.Classification -eq 'missing' })
        Older        = @($requirements | Where-Object { $_.Classification -in @('older', 'unknown-version') })
        Unsupported  = @($requirements | Where-Object { $_.Classification -eq 'unsupported' })
        Superseded   = @($requirements | Where-Object { $_.Classification -eq 'superseded' })
        Unusable     = @($requirements | Where-Object { $_.Classification -eq 'unusable' })
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
    the top of it". Nor is 'unusable', for the same reason and one more - the
    captain cannot answer a question about a program the machine will not run.

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
         SKIPS anything UNSUPPORTED or UNUSABLE rather than installing over the
         top of it,
      2. installs Pester and PSScriptAnalyzer into the user's own module
         directory, which the suite and the analyzer bar need,
      3. runs the home setup (Install-FmHome): the home layout, the herdr
         backend, the home pointer, the two committed symlinks a Windows clone
         does not get, the skip-worktree protection that stops `git checkout`
         emptying the skills tree, the profile wiring and the Claude hooks,
      4. writes the `firstmate` command onto the user's PATH, and puts
         PowerShell 7 in the captain's Start menu - a per-user install expands
         an archive and registers nothing, so without this the shell it just
         installed is on disk and nowhere a person looks,
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

    AND A MACHINE THAT REFUSES A LAUNCH DOES NOT END THE RUN. Windows can decline
    to start a program for reasons that have nothing to do with this repo, and it
    reports every one of them as "access is denied". That used to arrive as a raw
    .NET error at the first tool that needed a child shell, killing the run with
    every later requirement unattempted; it is now one requirement's outcome,
    said in the captain's words, and everything else still runs.

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
    $plan = if ($Plan) { $Plan } else { Get-FmMachineInstallPlan -SkipOptional:$SkipOptional -Offline:$Offline -RepoRoot $RepoRoot }

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

        # NEITHER IS INSTALLING OVER IT THE ANSWER HERE. The tool is on the
        # machine and this machine refused to start it, so a fresh copy in the
        # same place would be refused in the same way; what the captain needs is
        # to be told, not a second unusable install. The run carries on with
        # every other requirement and the verdict says the machine is not ready.
        if ($requirement.Classification -eq 'unusable') {
            $outcome.Outcome = 'unusable-skipped'
            $outcome.Detail = $requirement.Reason
            $outcomes += $outcome
            $steps += New-FmInstallStep -Name $requirement.Label -Action 'skipped' -Detail ('UNUSABLE: ' + $outcome.Detail)
            continue
        }

        # 'superseded' IS INSTALLED WITHOUT ASKING, exactly like 'missing', and
        # for the same reason: what this repo needs is not on the machine yet,
        # and putting it there replaces nothing. The older copy stays.
        $wanted = switch ($requirement.Classification) {
            'missing' { $true }
            'superseded' { $true }
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

        # Not an update of what is on the machine: a version that was not there
        # before, put beside the one that was.
        $updating = ($requirement.Classification -notin @('missing', 'superseded'))
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
        # SAME RULE AS THE TOOL LOOP. Setup writes into the checkout and into the
        # user's profile, and a machine can refuse a write for reasons that have
        # nothing to do with this repo - the checkout sitting somewhere protected
        # is the obvious one. Refusing is an answer the captain can act on; an
        # unhandled exception at the two-thirds mark is not.
        try {
            $setup = Install-FmHome -RepoRoot $RepoRoot -Confirm:$false
        } catch {
            Write-Debug "the home setup did not complete: $_"
            $setup = [pscustomobject]@{
                Installed = $false
                Reason    = ("setting up the home in '$RepoRoot' did not complete - this machine refused a change it had to make. " +
                    'Nothing after that step ran. A checkout somewhere the machine does not guard, such as your own profile ' +
                    'rather than Documents or OneDrive, is the first thing to try; re-run this script from there.')
                Steps     = @()
                Checks    = @()
                Lines     = @()
            }
        }
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

        # --- 4. the one-word command, and a shell a person can open -------------
        try {
            $shim = Set-FmMachineCommandShim -RepoRoot $RepoRoot -InstallRoot $InstallRoot -PathScope $PathScope -Confirm:$false
        } catch {
            # Not a reason to lose the report: everything is installed and the
            # home is wired; what is missing is a one-word command on PATH.
            Write-Debug "could not write the firstmate command: $_"
            $shim = [pscustomobject]@{
                Action = 'skipped'
                Detail = ("this machine refused to write the one-word command. Start firstmate with " +
                    "pwsh -File `"$(Join-Path $RepoRoot 'start.ps1')`" until that is sorted out.")
            }
        }
        $steps += New-FmInstallStep -Name 'firstmate command' -Action $shim.Action -Detail $shim.Detail

        # The per-user PowerShell 7 install is a zip expansion, so it registers
        # nothing; a captain told it succeeded then could not find it anywhere.
        # This runs on EVERY install, not only the one that installed the shell,
        # so a machine already in that state is repaired by re-running.
        $shortcut = Set-FmMachineShellShortcut -Confirm:$false
        $steps += New-FmInstallStep -Name 'PowerShell 7 in Start' -Action $shortcut.Action -Detail $shortcut.Detail
    } else {
        $steps += New-FmInstallStep -Name 'home' -Action 'skipped' -Detail 'WhatIf'
        $steps += New-FmInstallStep -Name 'firstmate command' -Action 'skipped' -Detail 'WhatIf'
        $shortcut = [pscustomobject]@{ Action = 'skipped'; Detail = 'WhatIf'; PwshPath = ''; Shortcut = '' }
        $steps += New-FmInstallStep -Name 'PowerShell 7 in Start' -Action 'skipped' -Detail 'WhatIf'
    }

    # --- 5. the proof ------------------------------------------------------------
    #
    # The tool group and the doctor's prerequisite group deliberately overlap on
    # herdr, treehouse and the Claude CLI, because they answer different
    # questions at different thresholds: the doctor asks whether this HOME is
    # healthy, where an absent herdr is a warning, and this asks whether the
    # INSTALL delivered what it promised, where a required tool that cannot print
    # a version is a failure.
    $locationCheck = @(Get-FmMachineLocationVerification -Location $plan.Location)
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

    $checks = $locationCheck + $toolChecks + $moduleChecks + @($doctor.Checks) + $suiteCheck
    $blocking = @($checks | Where-Object { $_.Status -eq 'missing' })
    $warnings = @($checks | Where-Object { $_.Status -eq 'warn' })
    $unsupported = @($outcomes | Where-Object { $_.Outcome -eq 'unsupported-skipped' })
    $unusable = @($outcomes | Where-Object { $_.Outcome -eq 'unusable-skipped' })
    $failed = @($outcomes | Where-Object { $_.Outcome -in @('failed', 'blocked', 'needs-administrator') })
    $verified = ($performed -and $blocking.Count -eq 0)
    $ready = ($verified -and $unsupported.Count -eq 0 -and $unusable.Count -eq 0 -and $failed.Count -eq 0)

    $lines = @("install: $RepoRoot", '')
    $lines += @($steps | ForEach-Object { Format-FmInstallStepLine -Step $_ })
    $lines += @('', 'verification - where this checkout is:')
    $lines += @($locationCheck | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('', 'verification - tools:')
    $lines += @($toolChecks + $moduleChecks | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('', 'verification - home, wiring and instructions:')
    $lines += @($doctor.Checks | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    $lines += @('', 'verification - the suite:')
    $lines += @($suiteCheck | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
    # Only on a run that did something. A WhatIf run has not looked at the Start
    # menu and has installed nothing, so telling the captain how to open a shell
    # it did not touch - let alone naming an elevated command - would be advice
    # about a machine this run never read.
    if ($performed) {
        $shellLines = @(Get-FmMachineShellLine -Shortcut $shortcut)
        if ($shellLines.Count) { $lines += @('') + $shellLines }
    }
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
    } elseif ($unusable.Count -gt 0) {
        $lines += ("NOT READY: $($unusable.Count) requirement(s) are installed and this machine refused to START them, so they were SKIPPED. " +
            'Nothing was installed over the top of them - a second copy in the same place would be refused the same way. ' +
            'The lines above say what to check, then re-run ./install.ps1.')
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
        'unusable-skipped'    = 'UNUSABLE - this machine refused to start it'
        'failed'              = 'FAILED'
        'blocked'             = 'BLOCKED'
        'needs-administrator' = 'NEEDS ADMINISTRATOR, skipped'
        'manual'              = 'manual step, not installed'
        'skipped'             = 'skipped'
    }

    $lines = @('summary - every requirement and what happened to it:')
    foreach ($outcome in $Outcomes) {
        $word = if ($wording.ContainsKey($outcome.Outcome)) { $wording[$outcome.Outcome] } else { $outcome.Outcome }
        # A failed outcome's detail quotes the tool's own output, so it arrives
        # as several lines. They are indented under the row rather than folded
        # away: the summary is the last thing the captain reads, and a failure
        # whose cause is only in the transcript above is a failure they have to
        # go looking for.
        $detail = @([string]$outcome.Detail -split '\r?\n')
        $lines += ('    {0,-24} {1,-42} {2}' -f $outcome.Label, $word, $detail[0])
        # Indented under the row, not out at the detail column: quoted tool
        # output starting at column 72 wraps into nonsense on a normal terminal.
        $lines += @($detail | Select-Object -Skip 1 | ForEach-Object { '        ' + $_ })
    }
    $lines
}
