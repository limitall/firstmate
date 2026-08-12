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
      warn     firstmate installs and runs, but something it needs at dispatch
               time is absent (herdr, treehouse, the Claude CLI, Pester)
      missing  a required piece of the installation is absent

    Healthy means no 'missing'. A 'warn' does not make the environment
    unhealthy, because a home with no herdr is still a correctly installed home
    - it simply cannot dispatch yet, and the line says so.

    A check that could not be evaluated is never reported as passing.

.PARAMETER FirstmateHome
    The home to check. Defaults to $env:FM_HOME, then <userprofile>/firstmate.

.PARAMETER RepoRoot
    The checkout to check. Defaults to the one this module was loaded from.

.PARAMETER ProfilePath
    The profile expected to carry the managed block. Defaults to
    $PROFILE.CurrentUserAllHosts.

.PARAMETER HookSettingsPath
    The Claude settings file expected to carry the hooks. Defaults to
    <RepoRoot>/.claude/settings.json.

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
        [string]$HookSettingsPath = ''
    )

    if (-not $RepoRoot) { $RepoRoot = Get-FmInstallRepoRoot }
    if (-not $FirstmateHome) { $FirstmateHome = Get-FmInstallDefaultHome }
    if (-not $ProfilePath) { $ProfilePath = Get-FmInstallProfilePath }
    if (-not $HookSettingsPath) { $HookSettingsPath = Get-FmInstallHookSettingsPath -RepoRoot $RepoRoot }

    $groups = [ordered]@{
        'prerequisites' = @(Get-FmInstallPrerequisiteCheck)
        'home'          = @(Get-FmInstallHomeCheck -FirstmateHome $FirstmateHome)
        'wiring'        = @(Get-FmInstallWiringCheck -RepoRoot $RepoRoot -FirstmateHome $FirstmateHome `
                -ProfilePath $ProfilePath -HookSettingsPath $HookSettingsPath)
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
        $lines += "healthy: nothing is missing. $($warn.Count) warning(s) - firstmate is installed but cannot dispatch until they are cleared."
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
    }
}
