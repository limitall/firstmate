#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Check the environment and print exactly what is missing and how to fix it.

.DESCRIPTION
    The Windows counterpart to what bin/fm-bootstrap.sh detects, aimed at a
    human rather than at the digest. Where bootstrap is silent when all is well
    - because the session-start digest folds its output in - the doctor always
    prints every check, so the captain can see what was actually examined.

    Three statuses, and the difference between the last two is load-bearing:

      ok       verified, in this session
      warn     it works, but not as well as it could: either something needed
               at dispatch time is absent (herdr, treehouse, the Claude CLI,
               Pester) or a convenience the profile block provides is absent
               (bin/ on PATH, a bare Import-Module Firstmate)
      missing  a required piece of the installation is absent

    Healthy means no 'missing'. A 'warn' does not make the environment
    unhealthy: a home with no herdr is still a correctly installed home that
    cannot dispatch yet, and an entry point run by its own path works with no
    profile wiring at all. Each warning line says which cost it is carrying.

    A check that could not be evaluated is never reported as passing.

    The `instructions` group is the exception to the "warn is not unhealthy"
    rule above, and deliberately so: every check in it is required. A checkout
    whose operating contract or skills are unreachable has every command and no
    first mate, which is broken rather than merely less ergonomic, and it is the
    one fault a captain would otherwise find by noticing the session's tone.

.PARAMETER FirstmateHome
    The home to check. Defaults to $env:FM_HOME, then the home persisted in
    <RepoRoot>/.fm-home, then the checkout itself - Resolve-FmEntryPointHome
    owns that order.

.PARAMETER RepoRoot
    The checkout to check. Defaults to the one this module was loaded from.

.PARAMETER ProfilePath
    The profile expected to carry the managed block. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER HookSettingsPath
    The Claude settings file expected to carry the hooks. Defaults to
    <RepoRoot>/.claude/settings.json.

.PARAMETER HomePointerPath
    The file expected to carry the home that resolves without the environment.
    Defaults to <RepoRoot>/.fm-home.

.EXAMPLE
    bin/fm-doctor.ps1

.EXAMPLE
    (Invoke-FmDoctor).Checks | Where-Object Status -ne ok
#>
function Invoke-FmDoctor {
    [CmdletBinding()]
    param(
        [string]$FirstmateHome = '',
        [string]$RepoRoot = '',
        [string]$ProfilePath = '',
        [string]$HookSettingsPath = '',
        [string]$HomePointerPath = ''
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not $HomePointerPath) { $HomePointerPath = Get-FmHomePointerPath -RepoRoot $RepoRoot }
    if (-not $FirstmateHome) {
        $FirstmateHome = Resolve-FmEntryPointHome -RepoRoot $RepoRoot -PointerPath $HomePointerPath
    }
    if (-not $ProfilePath) { $ProfilePath = Get-FmInstallProfilePath }
    if (-not $HookSettingsPath) { $HookSettingsPath = Get-FmInstallHookSettingsPath -RepoRoot $RepoRoot }

    $groups = [ordered]@{
        'prerequisites' = @(Get-FmInstallPrerequisiteCheck)
        'home'          = @(Get-FmInstallHomeCheck -FirstmateHome $FirstmateHome -HomePointerPath $HomePointerPath `
                -RepoRoot $RepoRoot) +
            # Printed with the home rather than with wiring because it is a
            # choice recorded IN the home. It always prints the exact command an
            # enabled autolaunch will run: opt-in is only meaningful if the
            # captain can see what they opted into without opening a file.
            @(Get-FmAutolaunchCheck -ConfigDir (Get-FmInstallConfigDirectory -FirstmateHome $FirstmateHome))
        'wiring'        = @(Get-FmInstallWiringCheck -RepoRoot $RepoRoot -FirstmateHome $FirstmateHome `
                -ProfilePath $ProfilePath -HookSettingsPath $HookSettingsPath)
        # The identity. Last because it is the one group whose failure a captain
        # would otherwise discover by noticing the session's tone rather than by
        # any command failing - so it is printed where the eye lands, next to
        # the verdict it decides.
        'instructions'  = @(Get-FmContractCheck -RepoRoot $RepoRoot)
    }

    $checks = @()
    $lines = @("fm-doctor: $RepoRoot -> $FirstmateHome")
    foreach ($group in $groups.Keys) {
        $lines += ''
        $lines += "$group`:"
        foreach ($check in $groups[$group]) {
            $checks += $check
            $lines += Format-FmInstallCheckLine -Check $check
        }
    }

    $missing = @($checks | Where-Object { $_.Status -eq 'missing' })
    $warn = @($checks | Where-Object { $_.Status -eq 'warn' })
    $lines += ''
    if ($missing.Count -eq 0 -and $warn.Count -eq 0) {
        $lines += 'healthy: every check passed.'
    } elseif ($missing.Count -eq 0) {
        # NOT "cannot dispatch": a warning now covers two different costs - a
        # missing dispatch dependency (herdr, treehouse) and a convenience the
        # profile block provides (PATH, the bare Import-Module). Every warning
        # line above says which one it is, so the summary points at them rather
        # than asserting one cause for all of them.
        $lines += "healthy: nothing is missing. $($warn.Count) warning(s) - each line above says what it costs."
    } else {
        $lines += "unhealthy: $($missing.Count) missing, $($warn.Count) warning(s). Fix the missing ones above, then re-run fm-doctor.ps1."
    }

    [pscustomobject]@{
        Healthy       = ($missing.Count -eq 0)
        Missing       = $missing
        Warnings      = $warn
        Checks        = $checks
        Lines         = $lines
        FirstmateHome = $FirstmateHome
        RepoRoot      = $RepoRoot
        ProfilePath   = $ProfilePath
        HookPath      = $HookSettingsPath
        HomePointer   = $HomePointerPath
    }
}
