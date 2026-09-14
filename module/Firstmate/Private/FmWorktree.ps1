#requires -Version 7.0
# module/Firstmate/Private/FmWorktree.ps1 - worktree isolation for the native
# Windows port. Ported from the worktree half of bin/fm-spawn.sh in the bash
# firstmate (validate_spawn_worktree, freshen_spawn_worktree_base, and the
# `treehouse get` + pane-cwd discovery poll).
#
# THE ONE DELIBERATE DESIGN CHANGE, AND WHY IT IS AN IMPROVEMENT
#
# The bash spawn types `treehouse get` INTO the worker's pane, then polls that
# pane's foreground cwd up to 60 times, requiring two consecutive reads to agree
# on a non-project path, and takes whatever it scraped as the worktree. That
# design exists because `treehouse get` opens an interactive subshell and had no
# other way to report where it landed. It has three costs firstmate documents
# in its own comments: a transiently stale pane cwd can be accepted as the
# worktree, a rename or a mistargeted pane can read firstmate's OWN cwd, and the
# worktree is only ever known to the spawner as a string it scraped off a
# terminal.
#
# treehouse v2 has `get --lease`: a non-interactive, durable acquire that
# reserves the worktree, marks it leased in persistent state, and prints its
# absolute path on stdout (banners go to stderr; `--json` adds the lease
# identity). This port acquires with `--lease` and reads the path from that
# output. The consequences are all improvements:
#   - the path is REPORTED, not inferred; there is no scrape and no poll, so
#     the stale-read failure mode is gone outright,
#   - the lease is durable: a leased worktree is never handed to a later `get`
#     and never removed by `prune` even with no process inside it, which closes
#     the window where a crashed spawn leaves a worktree that looks free,
#   - the lease identity lets the release be conditional
#     (`return --if-lease-id`), so a rollback can never return a worktree that
#     something else has since acquired,
#   - and on Windows it removes the need for the worker's shell to host an
#     interactive subshell for the lifetime of the task.
#
# THE GUARANTEE IS UNCHANGED and is enforced here, not by the mechanism: a
# worker lands in a genuinely isolated copy, and a failed isolation check stops
# the task. Assert-FmWorktreeIsolation is the same three-part test the bash
# validate_spawn_worktree runs (the path resolves, it IS its own git worktree
# root, and it is not the primary checkout), applied to the leased path before
# anything is launched into it.
#
# WINDOWS-UNVERIFIED: every treehouse call here. Treehouse ships official
# Windows builds, but it has NEVER been measured on Windows - not by this repo
# and not upstream as far as this port can establish. Everything below was
# executed against treehouse v2.1.1 on Linux. The Windows-specific risks to
# measure first are (a) whether a leased pool worktree can be reset while a
# handle is open, since Windows locks open files where Linux does not, and (b)
# whether treehouse's pool paths and lease state behave under case-insensitive
# path comparison. Both are handled defensively below and neither is proven.

Set-StrictMode -Version Latest

# --- path helpers ------------------------------------------------------------
#
# MERGE POINT: Resolve-FmPhysicalPath and Test-FmPathEqual are general-purpose
# path primitives that this area needed first. If the foundation module grows
# equivalents, keep one pair and delete the other rather than letting two
# shapes drift.

# Resolve-FmPhysicalPath: the PowerShell equivalent of `pwd -P` for an
# arbitrary path - a fully qualified path with every symlink, junction, and
# `..` segment resolved, including INTERMEDIATE ones. Returns '' when the path
# does not exist.
#
# Why every component and not just the leaf: a symlinked project prefix (the
# classic /tmp -> /private/tmp, and on Windows a junctioned pool root) makes a
# leaf-only resolve compare unequal against an OS-level cwd read, which would
# misfire the isolation guard in BOTH directions - refusing a spawn that never
# tangled, or failing to notice one that did.
function Resolve-FmPhysicalPath {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return ''
    }
    if (-not (Test-Path -LiteralPath $full)) { return '' }

    $root = [System.IO.Path]::GetPathRoot($full)
    $rest = $full.Substring($root.Length)
    $segments = $rest.Split([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
        [System.StringSplitOptions]::RemoveEmptyEntries)

    $current = $root
    foreach ($segment in $segments) {
        $current = Join-Path $current $segment
        $guard = 0
        while ($guard -lt 40) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or -not $item.LinkTarget) { break }
            $resolved = $null
            try { $resolved = $item.ResolveLinkTarget($true) } catch { $resolved = $null }
            if ($null -eq $resolved) { break }
            $current = $resolved.FullName
            $guard++
        }
    }
    $normalized = [System.IO.Path]::GetFullPath($current)
    if ($normalized.Length -gt 1) {
        $trimmed = $normalized.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if ($trimmed) { $normalized = $trimmed }
    }
    $normalized
}

# Resolve-FmPhysicalPathOrRaw: the `real_path_or_raw` contract - resolve when
# possible, otherwise hand back the input unchanged so a comparison against a
# path that no longer exists still compares something meaningful.
function Resolve-FmPhysicalPathOrRaw {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)
    $real = Resolve-FmPhysicalPath -Path $Path
    if ($real) { return $real }
    if ($null -eq $Path) { return '' }
    $Path
}

# Test-FmPathEqual: path comparison with the platform's own case rule. Windows
# paths are case-insensitive, Linux paths are not, and firstmate's isolation
# guard turns on exactly this comparison - so getting it wrong on Windows would
# let "C:\Repos\Proj" and "C:\repos\proj" read as two different checkouts and
# silently pass an isolation check that must fail.
function Test-FmPathEqual {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Left,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Right
    )
    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right)) { return $false }
    $normalize = {
        param($p)
        $p = $p -replace '[\\/]+$', ''
        if ($IsWindows) { $p = $p -replace '/', '\' }
        $p
    }
    $l = & $normalize $Left
    $r = & $normalize $Right
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    [string]::Equals($l, $r, $comparison)
}

# --- git plumbing ------------------------------------------------------------

# Invoke-FmGit: run one git command in <Directory> with no shell. Returns the
# Invoke-FmChildProcess record; callers branch on .Ok and .StdOut.
function Invoke-FmGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TimeoutSeconds = 300
    )
    Invoke-FmChildProcess -FilePath 'git' -ArgumentList (@('-C', $Directory) + $Arguments) -TimeoutSeconds $TimeoutSeconds
}

function Get-FmGitOutput {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $result = Invoke-FmGit -Directory $Directory -Arguments $Arguments
    if (-not $result.Ok) { return '' }
    $result.StdOut.Trim()
}

# Get-FmGitDefaultBranch: origin/HEAD's branch when it is set, else the first
# of main/master that exists locally. Mirrors the bash default_branch.
function Get-FmGitDefaultBranch {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory)
    $ref = Get-FmGitOutput -Directory $Directory -Arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if ($ref) { return ($ref -replace '^origin/', '') }
    foreach ($branch in @('main', 'master')) {
        $probe = Invoke-FmGit -Directory $Directory -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($probe.Ok) { return $branch }
    }
    ''
}

# --- worktree isolation, the guarantee ---------------------------------------

# Test-FmWorktreeIsolation: the three-part isolation test, reported rather than
# thrown, for callers that want to inspect the verdict.
#   1. the candidate path resolves physically at all,
#   2. it IS a git worktree root (its own `rev-parse --show-toplevel` resolves
#      to itself, so a subdirectory of the primary checkout cannot pass),
#   3. it is NOT the primary checkout.
function Test-FmWorktreeIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrimaryCheckout
    )
    $worktreeReal = Resolve-FmPhysicalPath -Path $Worktree
    $primaryReal = Resolve-FmPhysicalPathOrRaw -Path $PrimaryCheckout
    $top = ''
    $topReal = ''
    if ($worktreeReal) {
        $top = Get-FmGitOutput -Directory $worktreeReal -Arguments @('rev-parse', '--show-toplevel')
        if ($top) { $topReal = Resolve-FmPhysicalPath -Path $top }
    }

    $reason = ''
    if (-not $worktreeReal) {
        $reason = "the path did not resolve"
    } elseif (-not $topReal) {
        $reason = "it is not inside a git worktree"
    } elseif (-not (Test-FmPathEqual -Left $worktreeReal -Right $topReal)) {
        $reason = "it is not a worktree root (its root is '$top')"
    } elseif (Test-FmPathEqual -Left $worktreeReal -Right $primaryReal) {
        $reason = "it IS the primary checkout"
    }

    [pscustomobject]@{
        Isolated        = [string]::IsNullOrEmpty($reason)
        Reason          = $reason
        Worktree        = $Worktree
        WorktreeReal    = $worktreeReal
        WorktreeRoot    = $top
        PrimaryCheckout = $PrimaryCheckout
        PrimaryReal     = $primaryReal
    }
}

# Assert-FmWorktreeIsolation: the stop-the-task version. A failed isolation
# check must stop the task - never warn and continue - because the whole point
# is that no agent is ever launched into the primary checkout.
function Assert-FmWorktreeIsolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Worktree,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PrimaryCheckout,
        [string]$Source = 'worktree acquisition',
        [string]$InspectTarget = ''
    )
    $verdict = Test-FmWorktreeIsolation -Worktree $Worktree -PrimaryCheckout $PrimaryCheckout
    if ($verdict.Isolated) { return $verdict }
    $root = if ($verdict.WorktreeRoot) { $verdict.WorktreeRoot } else { 'none' }
    $suffix = if ($InspectTarget) { " Inspect target $InspectTarget" } else { '' }
    throw ("error: $Source did not yield an isolated worktree (resolved '$Worktree'; worktree root '$root'; " +
        "primary '$PrimaryCheckout'; $($verdict.Reason)); refusing to launch to avoid tangling the primary checkout.$suffix")
}

# --- treehouse lease ---------------------------------------------------------

# Assert-, not Test-: a missing treehouse is a hard blocker, and a throw
# refuses identically whatever the caller's $ErrorActionPreference is.
function Assert-FmTreehouseTool {
    [OutputType([bool])]
    [CmdletBinding()]
    param()
    if (Get-Command treehouse -CommandType Application -ErrorAction SilentlyContinue) { return $true }
    throw "error: the 'treehouse' CLI is not installed; firstmate cannot acquire an isolated worktree without it"
}

# New-FmWorktreeLease: acquire one worktree from <Project>'s treehouse pool
# with a durable lease and report where it landed.
#
# `treehouse get --lease --json` prints the lease allocation as JSON on stdout
# (path plus lease identity) with every banner on stderr, so the path is read,
# never scraped. When the installed treehouse answers something unparseable,
# the documented plain `--lease` contract is the fallback: stdout is exactly
# the absolute path.
#
# The returned record carries Path, LeaseId, LeaseHolder and Name. LeaseId is
# what makes the release conditional (Remove-FmWorktreeLease -IfLeaseId), so a
# rollback can never return a worktree something else has since acquired.
#
# This function does NOT check isolation. Callers must run
# Assert-FmWorktreeIsolation on the returned path before launching anything
# into it - the acquire and the guarantee are deliberately separate, so no
# future acquisition mechanism can quietly inherit a pass.
function New-FmWorktreeLease {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$LeaseHolder = '',
        [double]$TimeoutSeconds = 300
    )
    $null = Assert-FmTreehouseTool
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) {
        throw "project '$Project' is not a directory; cannot acquire a worktree from its pool"
    }
    # A repository with no commit anywhere (what New-FmProject creates) has
    # nothing to check a copy out at, and treehouse reports that as an invalid
    # 'refs/remotes/origin/main', which names a remote the project never had.
    $anyCommit = Invoke-FmGit -Directory $Project -Arguments @('rev-list', '-n', '1', '--all')
    if ($anyCommit.Ok -and -not $anyCommit.StdOut.Trim()) {
        throw ("error: project '$Project' has no commits yet, so there is nothing to start a worker copy from; " +
            'it needs a first commit before any worker can be spawned into it, and that commit is the captain''s to make or approve')
    }
    if (-not $PSCmdlet.ShouldProcess($Project, 'treehouse get --lease')) { return $null }

    $argv = @('get', '--lease', '--json')
    if ($LeaseHolder) { $argv += @('--lease-holder', $LeaseHolder) }
    $result = Invoke-FmChildProcess -FilePath 'treehouse' -ArgumentList $argv `
        -WorkingDirectory $Project -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Ok) {
        $detail = ($result.StdErr, $result.StdOut | Where-Object { $_ } | ForEach-Object { $_.Trim() }) -join ' '
        throw "error: 'treehouse get --lease' failed for project '$Project' (exit $($result.ExitCode)): $detail"
    }

    $stdout = $result.StdOut.Trim()
    $json = ConvertFrom-FmJsonSafe -Text $stdout
    $path = ''
    $leaseId = ''
    $leaseHolder = ''
    $name = ''
    if ($null -ne $json) {
        $path = [string](Get-FmJsonValue -InputObject $json -Path 'path')
        $leaseId = [string](Get-FmJsonValue -InputObject $json -Path 'lease_id')
        $leaseHolder = [string](Get-FmJsonValue -InputObject $json -Path 'lease_holder')
        $name = [string](Get-FmJsonValue -InputObject $json -Path 'name')
    }
    if (-not $path) {
        # Documented plain-`--lease` contract: stdout is only the path.
        $lines = @($stdout -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 1) { $path = $lines[0].Trim() }
    }
    if (-not $path) {
        throw "error: 'treehouse get --lease' printed no usable worktree path for project '$Project'; refusing to launch without a reported isolated copy"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "error: 'treehouse get --lease' reported worktree '$path' for project '$Project', but it is not a directory; refusing to launch into an unusable copy"
    }

    [pscustomobject]@{
        Path        = $path
        LeaseId     = $leaseId
        LeaseHolder = $leaseHolder
        Name        = $name
        Project     = $Project
    }
}

# Remove-FmWorktreeLease: release a leased worktree. Conditional on the exact
# lease identity when one is known, so a rollback can never return a worktree
# that has since been handed to someone else.
#
# NOT a teardown: this releases a lease this port acquired. Removing worktrees,
# discarding work, and the landed-work test stay with the teardown owner.
function Remove-FmWorktreeLease {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$IfLeaseId = '',
        [switch]$Force,
        [double]$TimeoutSeconds = 300
    )
    $null = Assert-FmTreehouseTool
    if (-not $PSCmdlet.ShouldProcess($Path, 'treehouse return')) { return $false }
    $argv = @('return', $Path)
    if ($IfLeaseId) { $argv += @('--if-lease-id', $IfLeaseId) }
    if ($Force) { $argv += '--force' }
    $result = Invoke-FmChildProcess -FilePath 'treehouse' -ArgumentList $argv -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Ok) {
        Write-Warning "'treehouse return' did not release '$Path' (exit $($result.ExitCode)): $($result.StdErr.Trim())"
        return $false
    }
    $true
}

# --- pooled-base freshening --------------------------------------------------

# Update-FmWorktreeBase: put a pooled worktree on the newest commit of the
# project's default branch before a worker starts in it, refusing rather than
# discarding work or guessing between histories.
#
# The newest commit is chosen from BOTH tips, local <default> and a freshly
# fetched origin/<default>: whichever contains the other. The Linux
# freshen_spawn_worktree_base takes origin/<default> alone, which is right only
# where origin is where work lands; a local-only merge lands on the local
# branch and pushes nothing, so there origin is a stale mirror and every worker
# started behind the landed work. docs/worktree-isolation-windows.md, "The
# pooled base", owns that reasoning. Each refusal keeps its meaning:
#   - a dirty worktree is refused before anything is fetched, never reset over;
#   - no origin remote means nothing remote to be stale against, so the local
#     branch is the base and no fetch is attempted;
#   - an origin that cannot be fetched or resolved still refuses;
#   - diverged tips refuse, because starting on either drops the other's commits.
function Update-FmWorktreeBase {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Worktree)

    if (-not $PSCmdlet.ShouldProcess($Worktree, 'refresh pooled worktree base')) { return $false }

    $status = Invoke-FmGit -Directory $Worktree -Arguments @('status', '--porcelain')
    if (-not $status.Ok) {
        throw "error: could not inspect pooled worktree '$Worktree' before refreshing its base"
    }
    if ($status.StdOut.Trim()) {
        throw "error: pooled worktree '$Worktree' is not clean; refusing to discard uncommitted work while refreshing its base"
    }

    $remotes = Invoke-FmGit -Directory $Worktree -Arguments @('remote')
    if (-not $remotes.Ok) {
        throw "error: could not list the remotes of pooled worktree '$Worktree' before refreshing its base"
    }
    $hasOrigin = @($remotes.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains 'origin'
    if ($hasOrigin) {
        if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('fetch', '--quiet', 'origin')).Ok) {
            throw "error: could not fetch origin for pooled worktree '$Worktree'; refusing to launch from a potentially stale base"
        }
        if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('remote', 'set-head', 'origin', '--auto')).Ok) {
            throw "error: could not resolve origin's current default branch for pooled worktree '$Worktree'; refusing to launch from a potentially stale base"
        }
    }
    $default = Get-FmGitDefaultBranch -Directory $Worktree
    if (-not $default) {
        throw "error: could not determine the default branch for pooled worktree '$Worktree' (expected origin/HEAD, main, or master); refusing to launch from a potentially stale base"
    }

    $localTip = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$default^{commit}")
    $originTip = ''
    if ($hasOrigin) {
        if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('fetch', '--quiet', 'origin', "+refs/heads/$default`:refs/remotes/origin/$default")).Ok) {
            throw "error: could not fetch 'origin/$default' for pooled worktree '$Worktree'; refusing to launch from a potentially stale base"
        }
        $originTip = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$default^{commit}")
        if (-not $originTip) {
            throw "error: 'origin/$default' is not a commit for pooled worktree '$Worktree'; refusing to launch from a potentially stale base"
        }
    } elseif (-not $localTip) {
        throw "error: '$default' is not a commit for pooled worktree '$Worktree', and there is no origin to take it from; refusing to launch from an unknown base"
    }

    $target = $default
    $expected = $localTip
    if ($originTip -and $originTip -ne $localTip) {
        # merge-base --is-ancestor answers 1 for "no" and 128 for an error; both
        # fall through to the next reading, and an error at both ends refuses.
        if (-not $localTip -or (Invoke-FmGit -Directory $Worktree -Arguments @('merge-base', '--is-ancestor', $localTip, $originTip)).Ok) {
            $target = "origin/$default"
            $expected = $originTip
        } elseif (-not (Invoke-FmGit -Directory $Worktree -Arguments @('merge-base', '--is-ancestor', $originTip, $localTip)).Ok) {
            # The trailing '--' stops git reading a range as a path: without it,
            # a long pool path makes git fail to stat the range and count nothing.
            $localOnly = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-list', '--count', "$originTip..$localTip", '--')
            $originOnly = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-list', '--count', "$localTip..$originTip", '--')
            throw ("error: local '$default' and 'origin/$default' have diverged for pooled worktree '$Worktree' " +
                "(local is $(if ($localOnly) { $localOnly } else { '?' }) ahead and " +
                "$(if ($originOnly) { $originOnly } else { '?' }) behind); refusing to launch from either, " +
                "because each would drop the other's commits. This needs a person: decide which history is right, " +
                "reconcile the project's '$default' with 'origin/$default', then spawn again")
        }
    }

    # Detach in place first, which moves no file, so the hard reset can never
    # drag a branch a slot was handed out on to the new base.
    if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('checkout', '--quiet', '--detach')).Ok) {
        throw "error: could not detach pooled worktree '$Worktree' before refreshing its base; refusing to move a checked-out branch"
    }
    # WINDOWS-UNVERIFIED: on Windows an open handle inside the worktree (an
    # editor, a running test, a virus scanner mid-scan) can make this reset fail
    # where Linux would let it through. The refusal below is the correct
    # Windows behaviour - it stops the task rather than launching from a
    # half-reset base - but the frequency of that failure on a real Windows
    # host is unmeasured.
    if (-not (Invoke-FmGit -Directory $Worktree -Arguments @('reset', '--quiet', '--hard', $expected)).Ok) {
        throw "error: could not reset pooled worktree '$Worktree' to '$target'; refusing to launch from a potentially stale base"
    }
    $actual = Get-FmGitOutput -Directory $Worktree -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')
    if ($actual -ne $expected) {
        $shown = if ($actual) { $actual } else { 'unknown' }
        throw "error: pooled worktree '$Worktree' is at '$shown', not current '$target' ('$expected'); refusing to launch"
    }
    $true
}

# --- composed acquisition ----------------------------------------------------

# New-FmIsolatedWorktree: the whole contract in one call - lease a worktree,
# prove it is isolated, and (unless suppressed) freshen its base. Any failure
# after the lease is acquired releases that lease conditionally, so a refused
# spawn leaves no worktree reserved to a task that never started.
function New-FmIsolatedWorktree {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$LeaseHolder = '',
        [switch]$SkipBaseRefresh
    )
    if (-not $PSCmdlet.ShouldProcess($Project, 'acquire isolated worktree')) { return $null }
    $lease = New-FmWorktreeLease -Project $Project -LeaseHolder $LeaseHolder -Confirm:$false
    if ($null -eq $lease) { return $null }
    try {
        $null = Assert-FmWorktreeIsolation -Worktree $lease.Path -PrimaryCheckout $Project `
            -Source 'treehouse get --lease'
        if (-not $SkipBaseRefresh) {
            $null = Update-FmWorktreeBase -Worktree $lease.Path -Confirm:$false
        }
    } catch {
        $null = Remove-FmWorktreeLease -Path $lease.Path -IfLeaseId $lease.LeaseId -Confirm:$false
        throw
    }
    $lease
}
