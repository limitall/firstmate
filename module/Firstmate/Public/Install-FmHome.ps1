#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Take a bare Windows machine with PowerShell 7 to a working firstmate home.

.DESCRIPTION
    The one setup command. It is idempotent: run it as often as you like, and
    after the first run every step reports 'already'.

    It does four things, in this order:

      1. creates the home layout (config/, data/, projects/, state/),
      2. selects the herdr backend when the home has not already chosen one -
         the only session provider this port drives, and without it the first
         session digest asks a Windows machine to install tmux,
      3. wires this checkout into the user's PowerShell profile so
         `Import-Module Firstmate` resolves and bin/fm-*.ps1 is on PATH in every
         new session, and FM_HOME points at the home,
      4. registers the Claude hooks (SessionStart, PreToolUse, Stop) in the
         checkout's .claude/settings.json,
      5. re-reads the environment and hands back a doctor report.

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
    Where the home lives. Defaults to $env:FM_HOME, then <userprofile>/firstmate.

.PARAMETER RepoRoot
    The checkout to wire in. Defaults to the checkout this module was loaded
    from, which is almost always what you want.

.PARAMETER ProfilePath
    The PowerShell profile to write the managed block into. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER HookSettingsPath
    The Claude settings file to register hooks in. Defaults to
    <RepoRoot>/.claude/settings.json.

.PARAMETER SkipProfile
    Do not touch the profile. The home is still created and the hooks are still
    registered; the doctor will report the wiring as missing, because it is.

.PARAMETER SkipHooks
    Do not register the Claude hooks.

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
        [switch]$SkipProfile,
        [switch]$SkipHooks
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not (Test-Path -LiteralPath (Join-Path -Path $RepoRoot -ChildPath 'module' -AdditionalChildPath 'Firstmate') -PathType Container)) {
        throw "error: '$RepoRoot' does not look like a firstmate-win checkout (no module/Firstmate); refusing to wire it in"
    }
    if (-not $FirstmateHome) { $FirstmateHome = Get-FmInstallDefaultHome }
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
    if (-not $SkipProfile -and $PSCmdlet.ShouldProcess('this session', 'apply the firstmate environment')) {
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
        -ProfilePath $ProfilePath -HookSettingsPath $HookSettingsPath

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
