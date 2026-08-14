#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Take a bare Windows machine with PowerShell 7 to a working firstmate home.

.DESCRIPTION
    The one setup command. It is idempotent: run it as often as you like, and
    after the first run every step reports 'already'.

    It does six things, in this order:

      1. creates the home layout (config/, data/, projects/, state/),
      2. selects the herdr backend when the home has not already chosen one -
         the only session provider this port drives, and without it the first
         session digest asks a Windows machine to install tmux,
      3. persists the chosen home in <RepoRoot>/.fm-home, which is what lets
         bin/fm-*.ps1 find it in a shell that loads no profile, and - when the
         home is NOT the checkout - writes an AGENTS.md/CLAUDE.md into the home
         that stops a session started there and names the checkout,
      3b. repairs the two committed symlinks a Windows clone does not get -
         CLAUDE.md -> AGENTS.md, and .claude/skills -> .agents/skills - so the
         session has an operating contract and skills rather than two short
         text files naming them,
      4. wires this checkout into the user's PowerShell profile so
         `Import-Module Firstmate` resolves and bin/fm-*.ps1 is on PATH in every
         new session, and FM_HOME points at the home,
      5. registers the Claude hooks (SessionStart, PreToolUse, Stop) in the
         checkout's .claude/settings.json,
      6. re-reads the environment and hands back a doctor report.

    STEP 3 IS THE FOUNDATION AND STEP 4 IS THE CONVENIENCE. The profile block is
    loaded by an interactive session and by nothing else - not by a herdr pane,
    a Claude hook, a scheduled task, or the worker sessions firstmate dispatches
    itself. The pointer file is read from the script's own location, so it works
    in all of them. -SkipProfile therefore skips step 4 only.

    DETECT BEFORE MUTATE. The hard prerequisites - PowerShell 7 and git - are
    checked before anything is written. If one is missing NOTHING is installed,
    the reasons are returned, and the machine is left exactly as it was. That is
    the difference between a machine that is not set up and one that is half set
    up.

    WHAT IT DOES NOT DO. It never installs a tool. herdr, treehouse and the
    Claude CLI are reported by the doctor with the command that installs each,
    and installing them is a separate, explicitly approved act
    (Install-FmTool -Approved) - AGENTS.md section 3's detect-ask-install rule.

.PARAMETER FirstmateHome
    Where the home lives. Defaults to $env:FM_HOME, then the home a previous
    setup persisted, then THE CHECKOUT - the layout the Linux firstmate has,
    where the repo root is the home. Naming a different directory is supported
    and gets the home redirect described above.

.PARAMETER RepoRoot
    The checkout to wire in. Defaults to the checkout this module was loaded
    from, which is almost always what you want.

.PARAMETER ProfilePath
    The PowerShell profile to write the managed block into. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER HookSettingsPath
    The Claude settings file to register hooks in. Defaults to
    <RepoRoot>/.claude/settings.json.

.PARAMETER HomePointerPath
    Where to persist the chosen home. Defaults to <RepoRoot>/.fm-home. It is
    overridable for the same reason -ProfilePath is: the suite runs setup
    against the real checkout and must not leave a pointer in it.

.PARAMETER SkipProfile
    Do not touch the profile. The home is still created, the home pointer is
    still written and the hooks are still registered; the doctor will warn about
    the absent profile wiring, because the bare `fm-doctor.ps1` command name
    needs it.

.PARAMETER SkipHooks
    Do not register the Claude hooks.

.PARAMETER KeepHomePointer
    Leave <RepoRoot>/.fm-home naming the home it already names, and leave this
    session's own FM_HOME alone. Use this when provisioning a SECOND home - a
    secondmate's - from a checkout that already serves a primary one: without it,
    the new home becomes the home this checkout resolves to, and the running
    primary silently starts operating against another home's state.

.PARAMETER SkipCheckoutRepair
    Do not repair the CHECKOUT's own AGENTS.md/CLAUDE.md pair or its
    .claude/skills link. Use it when installing a home from a checkout you must
    leave byte-identical - the test suite does exactly that. Without it, a host
    that cannot create symlinks re-materializes both as a junction and a
    hardlink, which leaves the working tree looking dirty.

.EXAMPLE
    bin/fm-setup.ps1

.EXAMPLE
    Install-FmHome -FirstmateHome C:\Users\ADMIN\firstmate
#>
function Install-FmHome {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$FirstmateHome = '',
        [string]$RepoRoot = '',
        [string]$ProfilePath = '',
        [string]$HookSettingsPath = '',
        [string]$HomePointerPath = '',
        [switch]$SkipProfile,
        [switch]$SkipHooks,
        [switch]$KeepHomePointer,
        [switch]$SkipCheckoutRepair
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not (Test-Path -LiteralPath (Join-Path -Path $RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate') -PathType Container)) {
        throw "error: '$RepoRoot' does not look like a firstmate-win checkout (no module/Firstmate); refusing to wire it in"
    }
    if (-not $HomePointerPath) { $HomePointerPath = Get-FmHomePointerPath -RepoRoot $RepoRoot }
    if (-not $FirstmateHome) {
        $FirstmateHome = Resolve-FmEntryPointHome -RepoRoot $RepoRoot -PointerPath $HomePointerPath
    }
    if (-not $ProfilePath) { $ProfilePath = Get-FmInstallProfilePath }
    if (-not $HookSettingsPath) { $HookSettingsPath = Get-FmInstallHookSettingsPath -RepoRoot $RepoRoot }

    # --- gate ------------------------------------------------------------------
    # Everything below this point writes. Nothing above it does.
    $prerequisites = @(Get-FmInstallPrerequisiteCheck)
    $blocking = @($prerequisites | Where-Object { $_.Required -and $_.Status -ne 'ok' })
    if ($blocking.Count -gt 0) {
        return [pscustomobject]@{
            Installed     = $false
            Reason        = 'a hard prerequisite is missing; nothing was installed'
            FirstmateHome = $FirstmateHome
            RepoRoot      = $RepoRoot
            ProfilePath   = $ProfilePath
            HookPath      = $HookSettingsPath
            Steps         = @()
            Checks        = $prerequisites
            Lines         = @(
                'fm-setup: REFUSED - a hard prerequisite is missing, so nothing was installed.'
                ''
            ) + @($blocking | ForEach-Object { Format-FmInstallCheckLine -Check $_ })
        }
    }

    $steps = @()
    $steps += New-FmInstallHomeLayout -FirstmateHome $FirstmateHome

    $backend = Set-FmInstallDefaultBackend -FirstmateHome $FirstmateHome
    $steps += New-FmInstallStep -Name 'backend' -Action $backend.Action -Detail $backend.Detail

    # NOT SKIPPABLE by -SkipProfile, unlike the profile block. This is what makes
    # the entry points work in a shell that loads no profile - a herdr pane, a
    # Claude hook, a dispatched worker - so -SkipProfile must not take it away.
    #
    # -KeepHomePointer is the ONE exception, and it exists for provisioning a
    # SECOND home from a checkout that already serves a first one. The pointer
    # answers "which home does this checkout resolve to with no profile and no
    # environment", and there is exactly one of it per checkout. Rewriting it
    # while provisioning a secondmate silently repointed the PRIMARY session at
    # the new home - the running firstmate kept operating, but against another
    # home's state. That is the failure this switch prevents; it is opt-in
    # because repointing is still the correct behaviour when the captain really
    # is moving this checkout's own home.
    if ($KeepHomePointer) {
        $steps += New-FmInstallStep -Name 'home pointer' -Action 'skipped' `
            -Detail "-KeepHomePointer: left $HomePointerPath naming this checkout's existing home, not $FirstmateHome"
    } else {
        $pointerAction = Write-FmHomePointer -HomePath $FirstmateHome -Path $HomePointerPath
        $steps += New-FmInstallStep -Name 'home pointer' -Action $pointerAction `
            -Detail "$HomePointerPath -> $FirstmateHome"
    }

    # ALSO NOT SKIPPABLE. When the home is not the checkout, `cd <home>; claude` -
    # the workflow every firstmate doc describes - starts an agent with no
    # instructions and no hooks. This is what makes that fail loudly instead.
    $redirect = Set-FmInstallHomeRedirect -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot
    $steps += New-FmInstallStep -Name 'home redirect' -Action $redirect.Action -Detail $redirect.Detail

    # The next two steps are the only ones that write into the CHECKOUT rather
    # than into the home being installed, and that asymmetry has a cost worth
    # naming: on a host without symlink privilege they re-materialize the two
    # committed symlinks as a junction and a hardlink, which git reports as a
    # deleted and a modified file. The instruction surface still WORKS - the
    # doctor reports it healthy - but the working tree now looks dirty, and the
    # obvious cleanup is a trap: `git checkout -- .claude/skills` follows the
    # link and deletes every skill behind it.
    #
    # -SkipCheckoutRepair exists for the caller that is installing a home and has
    # no business touching the checkout at all: the suite, which runs setup
    # against the REAL checkout because the profile block it writes has to name
    # the real module/ and bin/. Every other write that suite makes is already
    # redirected somewhere disposable; these two were the ones that were not.
    if ($SkipCheckoutRepair) {
        $steps += New-FmInstallStep -Name 'checkout memory' -Action 'skipped' `
            -Detail '-SkipCheckoutRepair: left the checkout''s AGENTS.md/CLAUDE.md pair untouched'
        $steps += New-FmInstallStep -Name 'skills link' -Action 'skipped' `
            -Detail '-SkipCheckoutRepair: left the checkout''s .claude/skills untouched'
    } else {
        # `cd <checkout>; claude` is only useful if the checkout's CLAUDE.md holds
        # the instructions rather than the text git leaves behind for a symlink it
        # could not create.
        $memory = Set-FmInstallCheckoutMemory -RepoRoot $RepoRoot
        $steps += New-FmInstallStep -Name 'checkout memory' -Action $memory.Action -Detail $memory.Detail

        # And the second committed symlink. Same failure mode as the one above,
        # one step worse in effect: the contract loads and the session has no
        # skills.
        $skills = Set-FmInstallSkillsLink -RepoRoot $RepoRoot
        $steps += New-FmInstallStep -Name 'skills link' -Action $skills.Action -Detail $skills.Detail
    }

    if ($SkipProfile) {
        $steps += New-FmInstallStep -Name 'profile wiring' -Action 'skipped' -Detail '-SkipProfile'
    } else {
        $block = Get-FmInstallProfileBlock -RepoRoot $RepoRoot -FirstmateHome $FirstmateHome
        $action = Set-FmInstallProfileBlock -Path $ProfilePath -Block $block
        $steps += New-FmInstallStep -Name 'profile wiring' -Action $action -Detail $ProfilePath
    }

    if ($SkipHooks) {
        $steps += New-FmInstallStep -Name 'Claude hooks' -Action 'skipped' -Detail '-SkipHooks'
    } else {
        $hook = Set-FmInstallHookRegistration -Path $HookSettingsPath
        $steps += New-FmInstallStep -Name 'Claude hooks' -Action $hook.Action -Detail $hook.Detail
    }

    # Make THIS session usable too, so the setup run can be followed straight
    # away by a doctor run that reports the truth rather than the state of a
    # session that has not reloaded its profile yet.
    #
    # -KeepHomePointer withholds this for the same reason it withholds the
    # pointer, and it is the SECOND surface of the same defect. The switch
    # declares "the home being built is not the one this checkout serves", so
    # pointing the live session's FM_HOME at it would be the identical hijack one
    # layer up - a session that provisions a secondmate by importing this module
    # rather than shelling out would carry on against the secondmate's state. The
    # durable pointer and the live session must agree, so both are withheld
    # together. The doctor call below takes -FirstmateHome explicitly, so the
    # second home is still reported on accurately.
    if (-not $SkipProfile -and -not $KeepHomePointer -and
        $PSCmdlet.ShouldProcess('this session', 'apply the firstmate environment')) {
        $env:FM_HOME = $FirstmateHome
        $separator = [System.IO.Path]::PathSeparator
        $moduleDir = Join-Path $RepoRoot 'module'
        $binDir = Join-Path $RepoRoot 'bin'
        if (($env:PSModulePath -split $separator) -notcontains $moduleDir) {
            $env:PSModulePath = $moduleDir + $separator + $env:PSModulePath
        }
        if (($env:PATH -split $separator) -notcontains $binDir) {
            $env:PATH = $binDir + $separator + $env:PATH
        }
    }

    $report = Invoke-FmDoctor -FirstmateHome $FirstmateHome -RepoRoot $RepoRoot `
        -ProfilePath $ProfilePath -HookSettingsPath $HookSettingsPath -HomePointerPath $HomePointerPath

    [pscustomobject]@{
        Installed     = $true
        Reason        = ''
        FirstmateHome = $FirstmateHome
        RepoRoot      = $RepoRoot
        ProfilePath   = $ProfilePath
        HookPath      = $HookSettingsPath
        Steps         = $steps
        Checks        = $report.Checks
        Healthy       = $report.Healthy
        Lines         = @("fm-setup: $FirstmateHome", '') +
            @($steps | ForEach-Object { Format-FmInstallStepLine -Step $_ }) +
            @('') + $report.Lines
    }
}
