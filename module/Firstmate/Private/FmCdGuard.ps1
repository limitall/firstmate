#requires -Version 7.0

# FmCdGuard.ps1 - the cd guard's environmental scope, ported from the scoping
# block of bin/fm-cd-pretool-check.sh.
#
# This is NOT Test-FmHookPrimaryScope. The two scopes differ on purpose and the
# bash docs say so outright ("docs/cd-guard.md owns this scope; docs/turnend-
# guard.md owns the turn-end guard's separate marker-aware scope"):
#
#   - The turn-end guard's scope force-INCLUDES a marked secondmate home, because
#     that home runs its own primary firstmate session.
#   - The cd guard deliberately does not inspect .fm-secondmate-home at all. It
#     applies in a git-CLONED secondmate home and stays inert when the secondmate
#     home is itself a treehouse-leased linked worktree. That is the documented
#     bash behaviour, not an oversight.
#
# The point of the scope is that a crewmate or scout task worktree - the shape
# bin/fm-spawn.ps1 always hands out - is a linked git worktree, where git-dir and
# git-common-dir differ. A worker there `cd`s freely and must never be denied;
# only the real primary checkout is guarded.
#
# ANY failure to confirm the checkout is INERT (allow), never a block, so a
# broken environment - no git on PATH, an unreadable repo - can never deny a
# shell command.

function Test-FmCdGuardScope {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'AGENTS.md') -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'bin') -PathType Container)) { return $false }

    $gitDir = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-dir')
    if (-not $gitDir.Found -or $gitDir.ExitCode -ne 0) { return $false }
    $common = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-common-dir')
    if (-not $common.Found -or $common.ExitCode -ne 0) { return $false }

    # Case-insensitively on Windows, because the filesystem is and git can report
    # the two directories with different casing there. Test-FmPathEqual is the
    # shared owner of that rule when the foundation area is loaded.
    $left = ($gitDir.Output -join '').Trim()
    $right = ($common.Output -join '').Trim()
    $pathEqual = Resolve-FmSessionCommand -Name 'Test-FmPathEqual'
    if ($pathEqual) {
        try { return [bool](& $pathEqual -Left $left -Right $right) } catch {
            Write-Debug "cd guard: Test-FmPathEqual owner failed; falling back to the built-in comparison: $_"
        }
    }
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return [string]::Equals($left, $right, $comparison)
}
