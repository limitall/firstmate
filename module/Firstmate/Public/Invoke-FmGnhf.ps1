#requires -Version 7.0
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The only way firstmate runs gnhf on this machine.

.DESCRIPTION
    PowerShell port of docs/fm-gnhf.reference.sh. Private/FmGnhf.ps1 documents
    why the guards live on the command line instead of in ~/.gnhf/config.yml -
    that file was measured to be decorative, and gnhf checked its own branch out
    in a PRIMARY checkout while it was set to prevent exactly that.

    Always applied, never overridable by a caller:

      --worktree            gnhf gets its own worktree, never the crew's checkout
      --max-iterations <n>  required, 1-100; a run is always bounded
      no push flag          delivery stays the captain's decision

    Refused up front: a path that is not a git repo, a max-iterations that is
    missing or silly, an empty objective, and a dirty tree (with the dirt
    printed, because "it is dirty" is not actionable on its own).

    THE GUARD THAT MATTERS runs after gnhf exits. The primary checkout's branch
    and commit are recorded before the run and compared after. A change is a hard
    failure carrying the exact restore command - gnhf is not trusted to have
    behaved, it is checked. Nothing is lost when it fires: gnhf's work is on its
    own branch, so restoring the checkout only undoes the thing that should not
    have happened.

.PARAMETER RepoPath
    The project to work in. Must be a git repository with a clean tree.

.PARAMETER MaxIterations
    1-100. Always bounded, never open-ended.

.PARAMETER Objective
    What to grind at. A direction rather than a destination is the right shape
    for gnhf; a specific deliverable belongs to a crewmate.

.PARAMETER ExtraArgument
    Passed through to gnhf after the guarded flags. It cannot be used to defeat a
    guard: --worktree and --max-iterations are already set, and a push flag is
    refused here rather than quietly forwarded.

.OUTPUTS
    A record carrying ExitCode, GuardHeld, Before/After state and the lines that
    were printed. ExitCode is gnhf's own on a clean run, 1 for a refusal, 3 when
    the checkout guard fired.

.EXAMPLE
    Invoke-FmGnhf -RepoPath C:\repos\thing -MaxIterations 20 -Objective 'raise test coverage'
#>
function Invoke-FmGnhf {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RepoPath,
        [Parameter(Mandatory, Position = 1)][string]$MaxIterations,
        [Parameter(Mandatory, Position = 2)][string]$Objective,
        [string[]]$ExtraArgument = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $fail = {
        param($Code, $Message)
        $lines.Add($Message)
        [pscustomobject]@{
            ExitCode  = $Code
            GuardHeld = $null
            Refused   = $true
            Before    = $null
            After     = $null
            Lines     = $lines.ToArray()
        }
    }

    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        return (& $fail 1 "fm-gnhf: not a directory: $RepoPath")
    }
    $repo = Resolve-FmFullPath -Path $RepoPath
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        return (& $fail 1 "fm-gnhf: not a git repo: $repo")
    }

    # Validated as text on purpose: '20abc', '' and '3.5' must all be refused
    # with the value quoted back, not silently coerced to something plausible.
    if ($MaxIterations -notmatch '^\d+$') {
        return (& $fail 1 "fm-gnhf: max-iterations must be a whole number, got '$MaxIterations'")
    }
    $maxIt = [int]$MaxIterations
    if ($maxIt -lt 1 -or $maxIt -gt 100) {
        return (& $fail 1 "fm-gnhf: max-iterations must be 1-100, got $maxIt")
    }
    if ([string]::IsNullOrWhiteSpace($Objective)) {
        return (& $fail 1 'fm-gnhf: empty objective')
    }

    # A caller must not be able to reintroduce what this wrapper exists to
    # withhold. Refuse rather than strip: silently dropping a flag a caller asked
    # for is how a caller comes to believe it was honoured.
    foreach ($extra in @($ExtraArgument)) {
        if ([string]$extra -match '^--push$|^--current-branch$') {
            return (& $fail 1 ("fm-gnhf: refusing '$extra' - it defeats a guard this wrapper exists to apply; " +
                    'push is the captain''s decision and the worktree is not optional'))
        }
    }

    $dirty = @(Get-FmGnhfDirtyLine -RepoPath $repo)
    if ($dirty.Count -gt 0) {
        $lines.Add("fm-gnhf: $repo has $($dirty.Count) uncommitted change(s); refusing.")
        foreach ($line in ($dirty | Select-Object -First 10)) { $lines.Add($line) }
        return [pscustomobject]@{
            ExitCode  = 1
            GuardHeld = $null
            Refused   = $true
            Before    = $null
            After     = $null
            Lines     = $lines.ToArray()
        }
    }

    $before = Get-FmGnhfCheckoutState -RepoPath $repo
    $lines.Add("fm-gnhf: $repo on '$($before.Branch)' at $($before.Short), bound $maxIt iterations")

    if (-not $PSCmdlet.ShouldProcess($repo, "run gnhf bounded to $maxIt iterations")) {
        return [pscustomobject]@{
            ExitCode  = 0
            GuardHeld = $null
            Refused   = $false
            Before    = $before
            After     = $null
            Lines     = $lines.ToArray()
        }
    }

    $rc = Invoke-FmGnhfProcess -RepoPath $repo -Objective $Objective -MaxIterations $maxIt -ExtraArgument $ExtraArgument

    # The check that matters. It runs whatever gnhf exited with, because a
    # failing run that moved the checkout is exactly the case that must be seen.
    $after = Get-FmGnhfCheckoutState -RepoPath $repo
    if ($before.Branch -ne $after.Branch -or $before.Head -ne $after.Head) {
        $lines.Add('fm-gnhf: GUARD FAILED - the primary checkout moved.')
        $lines.Add("  before: $($before.Branch) @ $($before.Short)")
        $lines.Add("  after:  $($after.Branch) @ $($after.Short)")
        $lines.Add('Restore it before doing anything else:')
        $lines.Add("  git -C `"$repo`" checkout $($before.Branch)")
        $lines.Add("gnhf's own branch still holds its work; nothing is lost by restoring.")
        return [pscustomobject]@{
            ExitCode  = 3
            GuardHeld = $false
            Refused   = $false
            Before    = $before
            After     = $after
            Lines     = $lines.ToArray()
        }
    }

    $lines.Add("fm-gnhf: guard held - $repo still on '$($after.Branch)' at $($after.Short)")
    $lines.Add("fm-gnhf: gnhf exited $rc; its work is on its own gnhf/* branch, unpushed")
    [pscustomobject]@{
        ExitCode  = $rc
        GuardHeld = $true
        Refused   = $false
        Before    = $before
        After     = $after
        Lines     = $lines.ToArray()
    }
}
