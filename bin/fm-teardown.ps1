# bin/fm-teardown.ps1 - tear down a finished task: return the treehouse worktree,
# release the Orca worktree, or retire a secondmate home; kill the recorded
# runtime endpoint, clear volatile state, refresh/prune the project's clone for
# PR-based ship tasks, then print a backlog-refresh reminder for ship and scout
# teardowns (a secondmate teardown prints none, since secondmates are not backlog
# items).
#
# Twin: bin/fm-teardown.sh - which owns the CONTRACT this file reproduces. Read
# its header for the complete landed-work rule, the PR-resolution fallbacks, the
# scout carve-out, the Orca and Herdr sequences, the secondmate retirement path,
# and the transient/stale git-lock recovery window. Nothing about WHEN teardown
# refuses is decided here; this file decides only HOW those same decisions are
# computed without a POSIX shell.
#
# Usage: fm-teardown.ps1 <task-id> [--force]
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work.
#
# ===========================================================================
# THE ONE THING THIS FILE EXISTS TO GET RIGHT
#
# AGENTS.md hard rule 3: NEVER TEAR DOWN UNLANDED WORK. Every refusal path in
# the bash twin refuses here, with the same message on the same stream and the
# same exit code, and `--force` remains the only bypass. Where the two languages
# could plausibly disagree, this file chooses the answer the BASH TWIN GIVES ON
# THIS HOST rather than the answer that is "better":
#
#   * GIT-LOCK STALENESS. bin/fm-lock-lib's proof consults `lsof`, which does
#     not exist under Git Bash, so every uncertainty already answers "not
#     provably stale" and the lock is left in place. Test-FmLockProvablyStale
#     reproduces that verdict exactly and is used unmodified - this file adds no
#     stricter and no looser rule of its own.
#
#   * THE 0700 QUARANTINE MODE GATE. On Windows `chmod` is inert and a directory
#     reads 755, so the bash twin's `!= 700` test refuses whenever a PR-check
#     quarantine directory exists. Get-FmPrFileMode reproduces MSYS `stat -c %a`
#     rather than reading a real ACL, so the PowerShell path refuses in exactly
#     the same situations. Making it accept would let PowerShell destroy state
#     that the bash path preserves.
#
#   * ENDPOINT REMOVAL IS GATED ON PROOF. A transient read failure never
#     licenses removal: only a structured `dead` from the adapter proves a pane
#     gone, and every unknown, malformed, or unavailable answer retains every
#     durable record and exits non-zero.
#
# ===========================================================================
# PATH FORM: POSIX IN, POSIX OUT
#
# Every path this script carries in a variable stays in the spelling it was READ
# in - which for a durable record written by a bash twin is MSYS form (/f/...) -
# because those strings are echoed into refusal messages the differential
# harness compares byte for byte, and because they are compared against each
# other. Conversion to native form happens only where a .NET or provider API is
# actually called, and fm-common's file helpers already do it for themselves.
# Get-FmTdRemovalAbsPath and Get-FmTdCanonicalDir therefore return POSIX form,
# matching `pwd -P` under Git Bash.
#
# The exception is an argument handed to a NATIVE tool. Git Bash silently
# rewrites a POSIX path into Windows form on its way to git.exe or
# treehouse.exe; PowerShell does not, so those call sites convert explicitly.
# Without that, `git -C /f/x` resolves against C:\ and every inspection fails
# open-ended - the exact shape that could turn a refusal into a teardown.
#
# ===========================================================================
# FOUR DIVERGENCES FROM THE BASH ORACLE, EACH DELIBERATE
#
#   1. `2>&1` INTERLEAVING. teardown_treehouse_return captures the child's
#      stdout and stderr as ONE stream and replays it. Invoke-FmTool drains the
#      two pipes separately (it must: reading them serially deadlocks), so this
#      file concatenates stdout then stderr. A child that writes to both, in
#      that order, is byte-identical; a child that interleaves them is not, and
#      no in-process capture can make it so.
#
#   2. `trap ... EXIT`. PowerShell has no exit trap, so the Herdr presentation
#      locks are released from a `finally` around the whole body. Exit-FmScript
#      raises an ExitException, and a finally block runs for it - verified - so
#      a lock is released on the refusal paths as well as the success path.
#
#   3. fm_backend_kill's EXTRA ARGUMENTS. The bash dispatcher forwards a zellij
#      tab id and an `fm-<id>` label to the adapter; the PowerShell dispatcher
#      (Remove-FmBackendTarget) takes backend and target only, because the
#      converted adapters resolve those themselves. This file calls the
#      dispatcher it has rather than inventing a wider one.
#
#   4. SIGNALS. HUP/TERM and the 129/143 codes they produce do not exist here.
#      No path in this script depends on one.
#
# `require_orca_terminal` is not ported: it is defined but never called in the
# bash twin, and a dead function is not a contract.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-lock-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-gate-refuse-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

$fmArgv = @($args)

# --- resolution (the bash preamble, in string terms) -------------------------

$script:TdRootOverride = Get-FmEnv -Name 'FM_ROOT_OVERRIDE'
$script:TdContext = Get-FmContext $PSScriptRoot
$script:TdScriptDir = ConvertTo-FmPosixPath $PSScriptRoot
$script:FmRoot = if ($script:TdRootOverride) { $script:TdRootOverride } else { $script:TdContext.PosixRoot }
$script:TdHomeEnv = Get-FmEnv -Name 'FM_HOME'
$script:FmHome = if ($script:TdHomeEnv) {
    $script:TdHomeEnv
} elseif ($script:TdRootOverride) {
    $script:TdRootOverride
} else {
    $script:FmRoot
}
$script:TdStateOverride = Get-FmEnv -Name 'FM_STATE_OVERRIDE'
$script:TdDataOverride = Get-FmEnv -Name 'FM_DATA_OVERRIDE'
$script:TdConfigOverride = Get-FmEnv -Name 'FM_CONFIG_OVERRIDE'
$script:State = if ($script:TdStateOverride) { $script:TdStateOverride } else { "$($script:FmHome)/state" }
$script:Data = if ($script:TdDataOverride) { $script:TdDataOverride } else { "$($script:FmHome)/data" }
$script:Config = if ($script:TdConfigOverride) { $script:TdConfigOverride } else { "$($script:FmHome)/config" }
$script:SecondmateReg = "$($script:Data)/secondmates.md"
$script:SubHomeMarker = '.fm-secondmate-home'

# Refusal codes, named exactly as the bash twin names them so the two can be
# read side by side.
$script:TeardownTreehouseLockRefused = 2
$script:TeardownWorktreeSafetyLockBlocked = 3

# Mutable task state, assigned in the main body.
$script:Id = ''
$script:Force = ''
$script:Meta = ''
$script:Backend = ''
$script:Target = ''
$script:Worktree = ''
$script:Project = ''
$script:PrUrl = ''
$script:Kind = 'ship'
$script:Mode = 'no-mistakes'
$script:BranchForSafety = ''
$script:StaleWorktreeLockAgeSecs = '30'
$script:TreehouseReturnLockRetries = '3'
$script:TreehouseReturnLockRetryWaitSecs = '1'
$script:HerdrLockRecords = @()
$script:SecondmateRegistryError = ''

# =============================================================================
# PRIMITIVES
#
# The shell tests and utilities the bash twin uses on every other line. They are
# thin on purpose: a reader comparing the two files should see the same shape.
# =============================================================================

# `[ -e "$p" ] || [ -L "$p" ]`. Test-Path reports a reparse point as present
# whether or not its target resolves, which is what the two-test bash idiom is
# reaching for.
function Test-FmTdPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return (Test-Path -LiteralPath (ConvertTo-FmNativePath $Path))
}

# `[ -d "$p" ]` - follows links, as bash does.
function Test-FmTdDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return (Test-Path -LiteralPath (ConvertTo-FmNativePath $Path) -PathType Container)
}

# `[ -f "$p" ]`.
function Test-FmTdRegularFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))
}

# `rm -f` - a missing path is success, exactly as rm -f treats it.
function Remove-FmTdFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm. This stands in for `rm -f` in a twin that removes unconditionally once its guards have passed; a confirmation surface would diverge from the twin and stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $true }
    $native = ConvertTo-FmNativePath $Path
    try {
        if (Test-Path -LiteralPath $native) {
            Remove-Item -LiteralPath $native -Force -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

# `rm -rf -- "$target"`.
function Remove-FmTdTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm. This stands in for `rm -rf` on a target that has already passed validate-removal-target; a confirmation surface would diverge from the twin and stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $true }
    $native = ConvertTo-FmNativePath $Path
    try {
        if (Test-Path -LiteralPath $native) {
            Remove-Item -LiteralPath $native -Recurse -Force -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
The `$( ... )` twin: captured output with every trailing newline stripped.
#>
function Get-FmTdCaptured {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`r", '').TrimEnd("`n")
}

<#
.SYNOPSIS
Split captured output the way a shell pipeline sees it.
.DESCRIPTION
`printf '%s\n' "$x" | ...` turns an EMPTY capture into a single empty line, not
into zero lines, and the bash twin's `head -1` / `head -5` idioms depend on
that. Splitting the (already trailing-newline-stripped) capture reproduces it.
#>
function Get-FmTdLines {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural names the return shape: this yields ALL lines of the capture as an array.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)
    return @($Text.Split("`n"))
}

<#
.SYNOPSIS
Run git against a repository directory, POSIX path in, native path out to git.
.DESCRIPTION
`git -C "$dir" ...`. The directory is converted because git.exe is a NATIVE
binary: Git Bash rewrites the path on the way across and PowerShell does not.
Returns Invoke-FmTool's hashtable.
#>
function Invoke-FmTdGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string[]]$GitArguments,
        [string]$StdIn
    )
    $argv = @('-C', (ConvertTo-FmNativePath $Directory)) + $GitArguments
    if ($PSBoundParameters.ContainsKey('StdIn')) {
        return (Invoke-FmTool -FilePath 'git' -Arguments $argv -StdIn $StdIn)
    }
    return (Invoke-FmTool -FilePath 'git' -Arguments $argv)
}

<#
.SYNOPSIS
The `grep '^key=' file | cut -d= -f2-` twin: EVERY match, newline-joined.
.DESCRIPTION
Deliberately NOT Get-FmMetaValue. Several reads in the bash twin (home=, kind=,
mode=, tasktmp=) use the plain grep form with no `tail -1`, so a record carrying
the key twice yields BOTH values joined by a newline - and a comparison such as
`[ "$KIND" = secondmate ]` then correctly fails. Collapsing that to a last-wins
read would silently hand a duplicated record a different lifecycle.
#>
function Get-FmTdGrepValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    $prefix = "$Key="
    $found = @()
    foreach ($line in (Get-FmFileLines $MetaPath)) {
        if ($line.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $found += $line.Substring($prefix.Length)
        }
    }
    return ($found -join "`n")
}

# =============================================================================
# PORTED FUNCTIONS, in the bash twin's order
# =============================================================================

# meta_value: the last-wins accessor.
function Get-FmTdMetaValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$MetaPath,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )
    return (Get-FmMetaValue $MetaPath $Key)
}

# canonical_existing_dir: `( cd "$target" && pwd -P )`, POSIX form out.
function Get-FmTdCanonicalDir {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (-not (Test-FmTdDirectory $Path)) { return $null }
    $physical = Resolve-FmPhysicalDirectory -Directory $Path
    if ($null -eq $physical) { return $null }
    return (ConvertTo-FmPosixPath $physical)
}

# removal_target_abs_path: a directory resolves through every link; anything
# else resolves its PARENT and re-appends the leaf, exactly as the bash
# `cd "$(dirname)" && printf '%s/%s' "$(pwd -P)" "$(basename)"` does.
function Get-FmTdRemovalAbsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (Test-FmTdDirectory $Path) { return (Get-FmTdCanonicalDir $Path) }

    # POSIX dirname/basename on the ORIGINAL spelling.
    $trimmed = $Path
    while ($trimmed.Length -gt 1 -and $trimmed.EndsWith('/')) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }
    $cut = $trimmed.LastIndexOf('/')
    $parent = if ($cut -lt 0) { '.' } elseif ($cut -eq 0) { '/' } else { $trimmed.Substring(0, $cut) }
    $leaf = if ($cut -lt 0) { $trimmed } else { $trimmed.Substring($cut + 1) }
    if ($leaf -eq '') { return $null }
    $parentAbs = Get-FmTdCanonicalDir $parent
    if ($null -eq $parentAbs) { return $null }
    return ($parentAbs.TrimEnd('/') + '/' + $leaf)
}

# path_is_ancestor_of <ancestor> <path>
function Test-FmTdPathAncestor {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Ancestor = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Path = ''
    )
    if ([string]::IsNullOrEmpty($Ancestor)) { return $false }
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Ancestor -ceq $Path) { return $false }
    return $Path.StartsWith("$Ancestor/", [System.StringComparison]::Ordinal)
}

# default_branch: origin/HEAD, then a local main or master; non-zero when none.
function Get-FmTdDefaultBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $r = Invoke-FmTdGit -Directory $script:Project -GitArguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    $ref = Get-FmTdCaptured $r.StdOut
    if ($r.Ok -and $ref -ne '') {
        if ($ref.StartsWith('origin/', [System.StringComparison]::Ordinal)) {
            return $ref.Substring('origin/'.Length)
        }
        return $ref
    }
    foreach ($branch in @('main', 'master')) {
        $v = Invoke-FmTdGit -Directory $script:Project -GitArguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($v.Ok) { return $branch }
    }
    return $null
}

# require_orca_worktree_id
function Get-FmTdOrcaWorktreeId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$MetaPath)
    $value = Get-FmTdMetaValue $MetaPath 'orca_worktree_id'
    if ([string]::IsNullOrEmpty($value)) {
        Write-FmErr "error: missing orca_worktree_id in $MetaPath; cannot remove Orca worktree"
        return $null
    }
    return $value
}

# remove_grok_turnend_auth / remove_kimi_turnend_auth. The token is read from a
# state file and used as a FILENAME, so the bash twin's character gate is the
# whole safety of the path and is reproduced verbatim.
function Remove-FmTdGrokTurnendAuth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; this mirrors an unconditional `rm -f` in the bash twin and must not gain a prompt in a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][string]$TaskId
    )
    $token = Get-FmTdCaptured (Get-FmFileText "$StateDir/$TaskId.grok-turnend-token")
    if ($token -eq '' -or $token -notmatch '\A[A-Za-z0-9._-]+\z') { return }
    $grokHome = Get-FmEnv -Name 'GROK_HOME' -Default ((Get-FmEnv -Name 'HOME') + '/.grok')
    $null = Remove-FmTdFile "$grokHome/hooks/fm-turn-end.d/$token"
}

function Remove-FmTdKimiTurnendAuth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; this mirrors an unconditional `rm -f` in the bash twin and must not gain a prompt in a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][string]$TaskId
    )
    $token = Get-FmTdCaptured (Get-FmFileText "$StateDir/$TaskId.kimi-turnend-token")
    if ($token -eq '' -or $token -notmatch '\A[A-Za-z0-9._-]+\z') { return }
    $null = Remove-FmTdFile ((Get-FmEnv -Name 'HOME') + "/.kimi-code/fm-turn-end.d/$token")
}

# retire_busy_state. Returns the child's exit code (0 when nothing to do), so a
# non-zero retire still aborts the caller exactly as `|| exit 1` does.
function Invoke-FmTdBusyRetire {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][string]$TaskId,
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$Generation = ''
    )
    if (-not [string]::IsNullOrEmpty($Generation)) {
        $r = Invoke-FmScript -Name 'fm-busy-event' -Arguments @('retire', $StateDir, $TaskId, '--gen', $Generation) -Stream
        return $r.ExitCode
    }
    if (Test-FmTdRegularFile "$StateDir/$TaskId.busy-gen") {
        $r = Invoke-FmScript -Name 'fm-busy-event' -Arguments @('retire', $StateDir, $TaskId, '--current-gen') -Stream
        return $r.ExitCode
    }
    return 0
}

<#
.SYNOPSIS
validate_pr_poll_cleanup - prove every task check artifact is an ordinary
single-link file on the state device before anything is destroyed.
.DESCRIPTION
Returns $true to proceed, $false to REFUSE and preserve task state. The refusal
messages and their order are part of the contract.
#>
function Test-FmTdPrPollCleanup {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )

    if (-not (Test-FmTaskIdPathSafe -Id $TaskId)) { return $true }
    $quarantine = "$StateDir/.pr-check-quarantine"

    if ($TaskId -ceq '_noncanonical' -and (
            (Test-FmTdPresent "$quarantine/_noncanonical.diagnostic.pending-noncanonical") -or
            (Test-FmTdPresent "$quarantine/_noncanonical.diagnostic.noncanonical"))) {
        Write-FmErr 'REFUSED: legacy PR-check quarantine migration is incomplete; preserving task state.'
        return $false
    }

    $artifacts = @(
        "$StateDir/$TaskId.check.sh"
        "$StateDir/$TaskId.pr-poll"
        "$StateDir/$TaskId.pr-poll-registration"
        "$StateDir/$TaskId.pr-poll-retirement"
        "$StateDir/$TaskId.check-trust"
    )

    $hasArtifact = $false
    foreach ($artifact in $artifacts) { if (Test-FmTdPresent $artifact) { $hasArtifact = $true } }
    if (Test-FmTdPresent $quarantine) { $hasArtifact = $true }
    if (-not $hasArtifact) { return $true }

    if (-not (Test-FmPrRegularDirectory -Path $StateDir)) { return $false }
    $stateDevice = Get-FmPrFileDevice -Path $StateDir
    if ([string]::IsNullOrEmpty($stateDevice)) { return $false }

    foreach ($artifact in $artifacts) {
        if (-not (Test-FmTdPresent $artifact)) { continue }
        if ((-not (Test-FmPrRegularFile -Path $artifact)) -or
            ((Get-FmPrFileDevice -Path $artifact) -cne $stateDevice) -or
            ((Get-FmPrFileLinkCount -Path $artifact) -cne '1')) {
            Write-FmErr 'REFUSED: unsafe task PR-check artifact; preserving task state.'
            return $false
        }
    }

    if (Test-FmTdPresent "$StateDir/$TaskId.pr-poll-retirement") {
        if ($null -eq (Get-FmPrPollRetirementState -State $StateDir -Id $TaskId)) {
            Write-FmErr 'REFUSED: invalid PR-poll retirement receipt; preserving task state.'
            return $false
        }
    }

    if (-not (Test-FmTdPresent $quarantine)) { return $true }
    if ((-not (Test-FmPrRegularDirectory -Path $StateDir)) -or
        (-not (Test-FmPrRegularDirectory -Path $quarantine))) {
        Write-FmErr "REFUSED: unsafe PR-check quarantine path $quarantine; preserving task state."
        return $false
    }
    if (((Get-FmPrFileDevice -Path $quarantine) -cne $stateDevice) -or
        ((Get-FmPrFileMode -Path $quarantine) -cne '700')) {
        Write-FmErr 'REFUSED: PR-check quarantine is not on the task state device; preserving task state.'
        return $false
    }

    foreach ($entry in (Get-FmTdQuarantineEntry -Quarantine $quarantine -TaskId $TaskId)) {
        if (-not (Test-FmPrPrivateFile -Path $entry -Mode '600' -Device $stateDevice)) {
            Write-FmErr 'REFUSED: unsafe task quarantine entry; preserving task state.'
            return $false
        }
    }
    return $true
}

# The `"$quarantine/$id."*` glob. A non-matching glob in bash yields the literal
# pattern, which its `[ -e ] || [ -L ] || continue` then skips - so an empty
# result here is the same thing.
function Get-FmTdQuarantineEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns every matching entry; the singular would read as get-one-entry.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Quarantine,
        [Parameter(Mandatory)][string]$TaskId
    )
    $native = ConvertTo-FmNativePath $Quarantine
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return @() }
    $prefix = "$TaskId."
    $out = @()
    foreach ($item in ([System.IO.Directory]::GetFileSystemEntries($native))) {
        $leaf = [System.IO.Path]::GetFileName($item)
        if ($leaf.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $out += "$Quarantine/$leaf"
        }
    }
    return @($out)
}

# remove_pr_poll_artifacts
function Remove-FmTdPrPollArtifacts {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; this removes only artifacts that have already passed the validation above, exactly as the bash twin does.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$StateDir,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$TaskId
    )
    if (-not (Test-FmTdPrPollCleanup -StateDir $StateDir -TaskId $TaskId)) { return $false }
    if (-not (Restore-FmPrPollRetirementOne -State $StateDir -Id $TaskId -Template "$($script:TdScriptDir)/fm-pr-poll.sh")) {
        return $false
    }
    foreach ($suffix in @('check.sh', 'pr-poll', 'pr-poll-registration', 'pr-poll-retirement', 'check-trust')) {
        if (-not (Remove-FmTdFile "$StateDir/$TaskId.$suffix")) { return $false }
    }
    if (Test-FmTaskIdPathSafe -Id $TaskId) {
        $quarantine = "$StateDir/.pr-check-quarantine"
        if ((Test-FmTdDirectory $quarantine) -and (-not (Test-FmSymlink $quarantine))) {
            foreach ($entry in (Get-FmTdQuarantineEntry -Quarantine $quarantine -TaskId $TaskId)) {
                if (-not (Remove-FmTdFile $entry)) { return $false }
            }
            # `rmdir ... || true`: removes it only when it is now empty.
            try {
                $native = ConvertTo-FmNativePath $quarantine
                if (@([System.IO.Directory]::GetFileSystemEntries($native)).Count -eq 0) {
                    [System.IO.Directory]::Delete($native)
                }
            } catch { $null = $_ }
        }
    }
    return $true
}

<#
.SYNOPSIS
pr_number_from_branch - resolve a PR number for a worktree branch via gh-axi.
.DESCRIPTION
Fail-safe by construction: $null on no match OR on any lookup failure, so the
caller reads both as "no PR found" and falls through to the content check.
#>
function Get-FmTdPrNumberFromBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Branch = '')
    if ([string]::IsNullOrEmpty($Branch) -or $Branch -ceq 'HEAD') { return $null }
    $r = Invoke-FmTool -FilePath 'gh-axi' `
        -Arguments @('pr', 'list', '--state', 'all', '--head', $Branch, '--limit', '1') `
        -WorkingDirectory $script:Worktree
    if (-not $r.Ok) { return $null }
    foreach ($line in (Get-FmTdLines (Get-FmTdCaptured $r.StdOut))) {
        $m = [regex]::Match($line, '^[ \t]*([0-9]+),')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# pr_number_from_target
function Get-FmTdPrNumberFromTarget {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')
    if ([string]::IsNullOrEmpty($Target)) { return $null }
    $n = ''
    if ($Target.Contains('/pull/')) {
        $n = $Target.Substring($Target.LastIndexOf('/pull/') + '/pull/'.Length)
        $n = [regex]::Match($n, '\A[0-9]*').Value
    } elseif ($Target -match '\A[0-9]') {
        $n = [regex]::Match($Target, '\A[0-9]*').Value
    } else {
        return $null
    }
    if ($n -eq '') { return $null }
    return $n
}

# ensure_commit_object
function Test-FmTdCommitObject {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Commit = ''
    )
    if ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('cat-file', '-e', "$Commit^{commit}")).Ok) {
        return $true
    }
    $n = Get-FmTdPrNumberFromTarget $Target
    if ($null -eq $n) { return $false }
    if (-not (Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('remote', 'get-url', 'origin')).Ok) {
        return $false
    }
    if (-not (Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('fetch', '--quiet', 'origin', "refs/pull/$n/head")).Ok) {
        return $false
    }
    return (Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('cat-file', '-e', "$Commit^{commit}")).Ok
}

# patch_id_for_commit: `git show ... | git patch-id --stable | awk 'NR==1{print $1}'`
function Get-FmTdPatchId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Commit)
    $show = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('show', '--pretty=medium', '--no-ext-diff', $Commit)
    $patch = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('patch-id', '--stable') -StdIn $show.StdOut
    $first = (Get-FmTdLines (Get-FmTdCaptured $patch.StdOut))[0]
    if ([string]::IsNullOrEmpty($first)) { return '' }
    $fields = @($first -split '[ \t]+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 1) { return '' }
    return $fields[0]
}

# unpushed_patches_are_in_pr_head
function Test-FmTdUnpushedInPrHead {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$PrHead)

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--verify', 'HEAD')
    if (-not $r.Ok) { return $false }
    $current = Get-FmTdCaptured $r.StdOut

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('merge-base', $current, $PrHead)
    if (-not $r.Ok) { return $false }
    $base = Get-FmTdCaptured $r.StdOut

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('log', '--format=%H', "$base..$PrHead", '--')
    $prPatchIds = @()
    foreach ($commit in (Get-FmTdLines (Get-FmTdCaptured $r.StdOut))) {
        if ($commit -eq '') { continue }
        $patchId = Get-FmTdPatchId -Commit $commit
        if ($patchId -ne '') { $prPatchIds += $patchId }
    }
    if ($prPatchIds.Count -eq 0) { return $false }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('log', '--format=%H', 'HEAD', '--not', '--remotes', '--')
    if (-not $r.Ok) { return $false }
    $unpushed = Get-FmTdCaptured $r.StdOut
    if ($unpushed -eq '') { return $false }

    foreach ($commit in (Get-FmTdLines $unpushed)) {
        if ($commit -eq '') { continue }
        $patchId = Get-FmTdPatchId -Commit $commit
        if ($patchId -eq '') { return $false }
        if ($prPatchIds -notcontains $patchId) { return $false }
    }
    return $true
}

# pr_is_merged
function Test-FmTdPrMerged {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Branch = '')

    $target = ''
    if (-not [string]::IsNullOrEmpty($script:PrUrl)) {
        $target = $script:PrUrl
    } else {
        $target = Get-FmTdPrNumberFromBranch $Branch
        if ($null -eq $target) { return $false }
    }
    if ([string]::IsNullOrEmpty($target)) { return $false }

    $r = Invoke-FmTool -FilePath 'gh' `
        -Arguments @('pr', 'view', $target, '--json', 'state,headRefOid', '-q', '.state + "`t" + .headRefOid'.Replace('`t', "`t")) `
        -WorkingDirectory $script:Worktree
    if (-not $r.Ok) { return $false }
    $view = Get-FmTdCaptured $r.StdOut

    # `${view%%$'\t'*}` / `${view#*$'\t'}` plus the `[ "$state" != "$view" ]`
    # test, which is how the bash twin detects "no TAB at all".
    $tab = $view.IndexOf("`t")
    if ($tab -lt 0) { return $false }
    $state = $view.Substring(0, $tab)
    $head = $view.Substring($tab + 1)
    if ($state -cne 'MERGED' -and $state -cne 'merged') { return $false }
    if ([string]::IsNullOrEmpty($head)) { return $false }
    if (-not (Test-FmTdCommitObject $target $head)) { return $false }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--verify', 'HEAD')
    if (-not $r.Ok) { return $false }
    $current = Get-FmTdCaptured $r.StdOut

    if ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('merge-base', '--is-ancestor', $current, $head)).Ok) {
        return $true
    }
    return (Test-FmTdUnpushedInPrHead -PrHead $head)
}

# content_in_default
function Test-FmTdContentInDefault {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $name = Get-FmTdDefaultBranch
    if ($null -eq $name) { return $false }

    $ref = ''
    if ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('remote', 'get-url', 'origin')).Ok) {
        if (-not (Invoke-FmTdGit -Directory $script:Worktree `
                    -GitArguments @('fetch', '--quiet', 'origin', "+refs/heads/${name}:refs/remotes/origin/$name")).Ok) {
            return $false
        }
        $ref = "refs/remotes/origin/$name"
    } elseif ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--quiet', '--verify', "refs/heads/$name")).Ok) {
        $ref = "refs/heads/$name"
    } else {
        return $false
    }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--quiet', '--verify', "$ref^{tree}")
    if (-not $r.Ok) { return $false }
    $defaultTree = Get-FmTdCaptured $r.StdOut
    if ($defaultTree -eq '') { return $false }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('merge-tree', '--write-tree', $ref, 'HEAD')
    if (-not $r.Ok) { return $false }
    $mergedTree = (Get-FmTdLines (Get-FmTdCaptured $r.StdOut))[0]
    return ($mergedTree -ceq $defaultTree)
}

# work_is_landed
function Test-FmTdWorkLanded {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Branch = '')
    if (Test-FmTdPrMerged $Branch) { return $true }
    return (Test-FmTdContentInDefault)
}

# backlog_refresh_reminder
function Write-FmTdBacklogReminder {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if ($script:Kind -ceq 'secondmate') { return }

    if (Test-FmTasksAxiBackendAvailable -ConfigDir $script:Config) {
        $doneCmd = ''
        if ($script:Kind -ceq 'scout') {
            $doneCmd = "tasks-axi done $($script:Id) --report data/$($script:Id)/report.md"
        } elseif ($script:Mode -ceq 'local-only') {
            $doneCmd = "tasks-axi done $($script:Id) --note ""local main"""
        } elseif (-not [string]::IsNullOrEmpty($script:PrUrl)) {
            $doneCmd = "tasks-axi done $($script:Id) --pr $($script:PrUrl)"
        } else {
            $doneCmd = "tasks-axi done $($script:Id) --pr PR_URL"
        }
        Write-FmOut ("Backlog: $($script:Id) just finished. Run $doneCmd, then run tasks-axi ready for " +
            'dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due.')
    } else {
        Write-FmOut ("Backlog: $($script:Id) just finished. Update data/backlog.md - move $($script:Id) to Done, " +
            'keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due.')
    }
}

# worktree_registered_for_project
function Test-FmTdWorktreeRegistered {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Project = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Target = ''
    )
    if ([string]::IsNullOrEmpty($Project)) { return $false }
    if (-not (Test-FmTdDirectory $Project)) { return $false }
    if (-not (Invoke-FmTdGit -Directory $Project -GitArguments @('rev-parse', '--git-dir')).Ok) { return $false }
    $absTarget = Get-FmTdRemovalAbsPath $Target

    $r = Invoke-FmTdGit -Directory $Project -GitArguments @('-c', 'core.quotePath=false', 'worktree', 'list', '--porcelain')
    if (-not $r.Ok) { return $false }
    foreach ($line in (Get-FmTdLines (Get-FmTdCaptured $r.StdOut))) {
        if (-not $line.StartsWith('worktree ', [System.StringComparison]::Ordinal)) { continue }
        $listedAbs = Get-FmTdRemovalAbsPath $line.Substring('worktree '.Length)
        if ($null -ne $listedAbs -and $listedAbs -ceq $absTarget) { return $true }
    }
    return $false
}

# inspectable_git_worktree
function Test-FmTdInspectableWorktree {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '')
    if ([string]::IsNullOrEmpty($Target)) { return $false }
    if (-not (Test-FmTdDirectory $Target)) { return $false }
    $r = Invoke-FmTdGit -Directory $Target -GitArguments @('rev-parse', '--show-toplevel')
    if (-not $r.Ok) { return $false }
    $top = Get-FmTdCaptured $r.StdOut
    if ($top -eq '') { return $false }
    if (-not (Test-FmTdDirectory $top)) { return $false }
    return (Invoke-FmTdGit -Directory $top -GitArguments @('rev-parse', '--git-dir')).Ok
}

# retry_wait_secs_is_valid
function Test-FmTdRetryWait {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Value = '')
    return ($Value -match '\A([0-9]+([.][0-9]*)?|[.][0-9]+)\z')
}

# treehouse_return_is_index_lock_error
function Test-FmTdIndexLockError {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')
    if ($null -eq $Text) { return $false }
    return [regex]::IsMatch($Text, "Unable to create ['`"].*index\.lock['`"]: File exists")
}

# worktree_git_lock_path
function Get-FmTdWorktreeLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Directory = '')
    if ([string]::IsNullOrEmpty($Directory)) { return $null }
    if (-not (Test-FmTdDirectory $Directory)) { return $null }
    $r = Invoke-FmTdGit -Directory $Directory -GitArguments @('rev-parse', '--git-path', 'index.lock')
    if (-not $r.Ok) { return $null }
    $lock = Get-FmTdCaptured $r.StdOut
    if ($lock -eq '') { return $null }
    # `case "$lock" in /*)` - a relative answer is joined to the physical dir.
    # A Windows-absolute answer (git.exe can return one) is equally absolute and
    # must NOT be re-rooted, so it is accepted here too.
    if ($lock.StartsWith('/') -or $lock -match '^[A-Za-z]:[\\/]') { return $lock }
    $absDir = Get-FmTdCanonicalDir $Directory
    if ($null -eq $absDir) { return $null }
    return "$absDir/$lock"
}

# worktree_safety_blocked_by_lock
function Test-FmTdSafetyBlockedByLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Reason)
    $lock = Get-FmTdWorktreeLockPath $script:Worktree
    if ([string]::IsNullOrEmpty($lock) -or -not (Test-FmTdPresent $lock)) { return $false }
    Write-FmErr ("teardown: cannot inspect worktree $($script:Worktree) for $Reason while git lock $lock is " +
        'present; checking whether the lock is stale')
    return $true
}

# cleanup_stale_lock_for_safety_check. Returns 0 to retry the safety checks, or
# TEARDOWN_TREEHOUSE_LOCK_REFUSED to refuse.
function Clear-FmTdStaleLockForSafety {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; the removal here happens only behind the shared provably-stale proof, exactly as in the bash twin, and a prompt would stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $lock = Get-FmTdWorktreeLockPath $Directory
    if ([string]::IsNullOrEmpty($lock) -or -not (Test-FmTdPresent $lock)) { return 0 }

    Write-FmErr ("teardown: worktree safety check blocked by git lock $lock; waiting " +
        "$($script:TreehouseReturnLockRetryWaitSecs)s and retrying (owning process may be exiting)")
    Start-Sleep -Seconds ([double]$script:TreehouseReturnLockRetryWaitSecs)

    if (-not (Test-FmTdPresent $lock)) {
        Write-FmErr 'teardown: worktree safety check lock cleared on its own; retrying safety checks'
        return 0
    }

    if (Test-FmLockProvablyStale $lock $Directory -MinimumAgeSeconds $script:StaleWorktreeLockAgeSecs -LogPrefix 'teardown') {
        $null = Remove-FmTdFile $lock
        Write-FmErr ("teardown: removed provably-stale git lock $lock (age >= " +
            "$($script:StaleWorktreeLockAgeSecs)s, no live holder) and retrying worktree safety checks")
        return 0
    }

    Write-FmErr ("teardown: worktree safety check blocked by git lock $lock that is not provably stale " +
        '(may belong to a live process); leaving it in place')
    return $script:TeardownTreehouseLockRefused
}

<#
.SYNOPSIS
teardown_treehouse_return - return a worktree or home, tolerating a transient or
stale git index.lock left by a killed crew process.
.DESCRIPTION
Returns 0 on success, TEARDOWN_TREEHOUSE_LOCK_REFUSED when a lock that is not
provably stale outlived the patience window, and 1 for every other failure.
-PostCleanupCheck is the safety re-check the caller wants run after a stale lock
is removed and before the destructive retry.
#>
function Invoke-FmTdTreehouseReturn {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string]$WorkingDirectory,
        [Parameter(Mandatory, Position = 2)][string]$Label,
        [scriptblock]$PostCleanupCheck
    )

    # `2>&1` cannot be reproduced as one ordered stream; see divergence 1.
    $run = {
        $r = Invoke-FmTool -FilePath 'treehouse' `
            -Arguments @('return', '--force', (ConvertTo-FmNativePath $Directory)) `
            -WorkingDirectory $WorkingDirectory
        return @{ Ok = $r.Ok; Out = (Get-FmTdCaptured ($r.StdOut + $r.StdErr)) }
    }

    $attemptResult = & $run
    if ($attemptResult.Ok) {
        if ($attemptResult.Out -ne '') { Write-FmOut $attemptResult.Out }
        return 0
    }
    if ($attemptResult.Out -ne '') { Write-FmErr $attemptResult.Out }

    if (-not (Test-FmTdIndexLockError $attemptResult.Out)) { return 1 }

    $lock = Get-FmTdWorktreeLockPath $Directory
    $lockDesc = if ([string]::IsNullOrEmpty($lock)) { 'index.lock' } else { $lock }

    $maxRetries = 3
    if ($script:TreehouseReturnLockRetries -match '\A[0-9]+\z') {
        $maxRetries = [int]$script:TreehouseReturnLockRetries
    }

    $attempt = 0
    while ($attempt -lt $maxRetries) {
        $attempt++
        Write-FmErr ("teardown: $Label return failed with transient git lock ($lockDesc); waiting " +
            "$($script:TreehouseReturnLockRetryWaitSecs)s and retrying ($attempt/$maxRetries)")
        Start-Sleep -Seconds ([double]$script:TreehouseReturnLockRetryWaitSecs)

        $attemptResult = & $run
        if ($attemptResult.Ok) {
            if ($attemptResult.Out -ne '') { Write-FmOut $attemptResult.Out }
            Write-FmErr "teardown: $Label return succeeded on retry; lock cleared on its own"
            return 0
        }
        if ($attemptResult.Out -ne '') { Write-FmErr $attemptResult.Out }

        if (-not (Test-FmTdIndexLockError $attemptResult.Out)) {
            Write-FmErr "teardown: $Label return failed with a non-lock error after retry; aborting"
            return 1
        }
    }

    # The lock may have appeared, moved, or cleared while we waited.
    $lock = Get-FmTdWorktreeLockPath $Directory
    if (-not [string]::IsNullOrEmpty($lock) -and (Test-FmTdPresent $lock)) {
        $lockDesc = $lock
        if (Test-FmLockProvablyStale $lock $Directory -MinimumAgeSeconds $script:StaleWorktreeLockAgeSecs -LogPrefix 'teardown') {
            $null = Remove-FmTdFile $lock
            Write-FmErr ("teardown: removed provably-stale git lock $lock (age >= " +
                "$($script:StaleWorktreeLockAgeSecs)s, no live holder) and retrying $Label return")
            if ($PSBoundParameters.ContainsKey('PostCleanupCheck') -and $null -ne $PostCleanupCheck) {
                if ((& $PostCleanupCheck) -ne 0) {
                    Write-FmErr "teardown: $Label return aborted after stale-lock cleanup because safety checks failed"
                    return 1
                }
            }
            $attemptResult = & $run
            if ($attemptResult.Ok) {
                if ($attemptResult.Out -ne '') { Write-FmOut $attemptResult.Out }
                Write-FmErr "teardown: $Label return succeeded after stale-lock cleanup"
                return 0
            }
            if ($attemptResult.Out -ne '') { Write-FmErr $attemptResult.Out }
            Write-FmErr "teardown: $Label return still failing after stale-lock cleanup"
            return 1
        }

        Write-FmErr ("teardown: $Label return failed: git lock $lockDesc persisted across $maxRetries retries " +
            "(waiting $($script:TreehouseReturnLockRetryWaitSecs)s each) and is not provably stale " +
            '(may belong to a live process); leaving it in place')
        return $script:TeardownTreehouseLockRefused
    }

    Write-FmErr ("teardown: $Label return failed: git index.lock signature persisted across $maxRetries retries " +
        "(waiting $($script:TreehouseReturnLockRetryWaitSecs)s each) even after the lock file disappeared")
    return 1
}

<#
.SYNOPSIS
validate_worktree_teardown_safety - THE landed-work test.
.DESCRIPTION
Returns 0 when teardown may proceed, 1 to REFUSE, and
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED when a git lock made the inspection
impossible (the caller then clears a provably-stale lock and re-runs this).

Every refusal message and every stream is part of hard rule 3's contract; do not
reword one without changing the bash twin in the same commit.
#>
function Test-FmTdWorktreeSafety {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (-not (Test-FmTdDirectory $script:Worktree)) { return 0 }
    if ($script:Force -ceq '--force') { return 0 }
    if ($script:Kind -ceq 'secondmate' -or $script:Kind -ceq 'scout') { return 0 }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('status', '--porcelain')
    if (-not $r.Ok) {
        if (Test-FmTdSafetyBlockedByLock -Reason 'uncommitted changes') {
            return $script:TeardownWorktreeSafetyLockBlocked
        }
        Write-FmErr "REFUSED: cannot inspect worktree $($script:Worktree) for uncommitted changes."
        Write-FmErr 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
        return 1
    }
    $dirty = ''
    foreach ($line in (Get-FmTdLines (Get-FmTdCaptured $r.StdOut))) {
        if ($line -match '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)') { continue }
        $dirty = $line
        break
    }

    $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('log', '--oneline', 'HEAD', '--not', '--remotes', '--')
    if (-not $r.Ok) {
        if (Test-FmTdSafetyBlockedByLock -Reason 'commits not on a remote') {
            return $script:TeardownWorktreeSafetyLockBlocked
        }
        Write-FmErr "REFUSED: cannot inspect worktree $($script:Worktree) for commits not on a remote."
        Write-FmErr 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
        return 1
    }
    $unpushed = (Get-FmTdLines (Get-FmTdCaptured $r.StdOut) | Select-Object -First 5) -join "`n"

    if ($unpushed -ne '' -and $script:Mode -ceq 'local-only') {
        $default = Get-FmTdDefaultBranch
        if ($null -eq $default) {
            Write-FmErr ("REFUSED: cannot determine default branch for $($script:Project); " +
                'expected origin/HEAD, main, or master.')
            return 1
        }
        $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('log', '--oneline', 'HEAD', '--not', $default, '--')
        if (-not $r.Ok) {
            if (Test-FmTdSafetyBlockedByLock -Reason "commits not on $default") {
                return $script:TeardownWorktreeSafetyLockBlocked
            }
            Write-FmErr "REFUSED: cannot inspect worktree $($script:Worktree) for commits not on $default."
            Write-FmErr 'Restore the git index state, or get the captain''s explicit OK to discard, then --force.'
            return 1
        }
        $unmerged = (Get-FmTdLines (Get-FmTdCaptured $r.StdOut) | Select-Object -First 5) -join "`n"
        if ($dirty -ne '' -or $unmerged -ne '') {
            Write-FmErr ("REFUSED: local-only worktree $($script:Worktree) has work not yet merged into " +
                "$default and not on any remote.")
            if ($dirty -ne '') { Write-FmErr 'uncommitted changes present' }
            if ($unmerged -ne '') { Write-FmErr "commits not yet on ${default}:`n$unmerged" }
            Write-FmErr ("Merge the branch into local $default first (bin/fm-merge-local.sh after the captain " +
                'approves), or push to a fork/remote, or get the captain''s explicit OK to discard, then --force.')
            return 1
        }
    } elseif ($dirty -ne '') {
        Write-FmErr "REFUSED: worktree $($script:Worktree) has uncommitted changes."
        Write-FmErr 'uncommitted changes present'
        Write-FmErr 'Commit them (or get the captain''s explicit OK to discard, then --force).'
        return 1
    } elseif ($unpushed -ne '') {
        # Memoized exactly as the bash twin memoizes it, so a re-run after a
        # stale-lock cleanup cannot resolve a different branch.
        if ($script:BranchForSafety -eq '') {
            $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD')
            $script:BranchForSafety = if ($r.Ok) { Get-FmTdCaptured $r.StdOut } else { 'HEAD' }
        }
        if (-not (Test-FmTdWorkLanded $script:BranchForSafety)) {
            Write-FmErr "REFUSED: worktree $($script:Worktree) has work not on any remote and not landed."
            Write-FmErr "unpushed commits:`n$unpushed"
            Write-FmErr 'Push the branch, land its PR, or get the captain''s explicit OK to discard, then --force.'
            return 1
        }
    }
    return 0
}

# require_orca_worktree_path_match
function Test-FmTdOrcaPathMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorktreeId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Inspected = ''
    )
    $resolved = Get-FmBackendWorktreePath 'orca' $WorktreeId
    if ([string]::IsNullOrEmpty($resolved)) {
        Write-FmErr "REFUSED: cannot resolve Orca worktree id $WorktreeId to a path; preserving metadata."
        return $false
    }
    $inspectedAbs = Get-FmTdCanonicalDir $Inspected
    if ($null -eq $inspectedAbs) {
        $shown = if ([string]::IsNullOrEmpty($Inspected)) { '<missing>' } else { $Inspected }
        Write-FmErr "REFUSED: cannot canonicalize inspected worktree $shown; preserving metadata."
        return $false
    }
    $resolvedAbs = Get-FmTdCanonicalDir $resolved
    if ($null -eq $resolvedAbs) {
        $shown = if ([string]::IsNullOrEmpty($resolved)) { '<missing>' } else { $resolved }
        Write-FmErr "REFUSED: Orca worktree id $WorktreeId resolved to uninspectable path $shown; preserving metadata."
        return $false
    }
    if ($resolvedAbs -cne $inspectedAbs) {
        Write-FmErr "REFUSED: Orca worktree id $WorktreeId resolves to $resolvedAbs, not inspected worktree $inspectedAbs."
        Write-FmErr 'Cannot verify dirty or unlanded work for the worktree Orca would remove; preserving metadata.'
        return $false
    }
    return $true
}

# require_orca_worktree_path_match_if_present
function Test-FmTdOrcaPathMatchIfPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$WorktreeId = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Inspected = ''
    )
    if ([string]::IsNullOrEmpty($Inspected) -or -not (Test-FmTdPresent $Inspected)) { return $true }
    return (Test-FmTdOrcaPathMatch $WorktreeId $Inspected)
}

# firstmate_home_has_treehouse_slot
function Test-FmTdHomeHasTreehouseSlot {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)
    return (Test-FmTdWorktreeRegistered $script:FmRoot $HomePath)
}

<#
.SYNOPSIS
validate_removal_target - the destructive-path guard.
.DESCRIPTION
Returns @{Ok;Path}. Ok=$false means REFUSE. Ok=$true with an empty Path is the
"target does not exist, nothing to do" answer the bash twin gives by returning 0
with no stdout - several callers depend on that distinction.
#>
function Get-FmTdValidatedRemovalTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Label = ''
    )
    $skip = @{ Ok = $true; Path = '' }
    $deny = @{ Ok = $false; Path = '' }

    if ([string]::IsNullOrEmpty($Target)) { return $skip }
    if (-not (Test-FmTdPresent $Target)) { return $skip }

    $absTarget = Get-FmTdRemovalAbsPath $Target
    $absHome = Get-FmTdCanonicalDir $script:FmHome
    if ($null -eq $absHome) { $absHome = '' }
    $absRoot = Get-FmTdCanonicalDir $script:FmRoot

    if ([string]::IsNullOrEmpty($absTarget) -or $absTarget -ceq '/') {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target"
        return $deny
    }
    if ($absHome -ne '' -and $absTarget -ceq $absHome) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is the active firstmate home"
        return $deny
    }
    if ($absTarget -ceq $absRoot) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is the firstmate repo"
        return $deny
    }
    if ($absHome -ne '' -and (Test-FmTdPathAncestor $absTarget $absHome)) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is an ancestor of the active firstmate home"
        return $deny
    }
    if (Test-FmTdPathAncestor $absTarget $absRoot) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is an ancestor of the firstmate repo"
        return $deny
    }
    if ($absHome -ne '' -and (Test-FmTdPathAncestor $absHome $absTarget)) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is inside the active firstmate home"
        return $deny
    }
    if (Test-FmTdPathAncestor $absRoot $absTarget) {
        Write-FmErr "REFUSED: unsafe $Label removal target $Target is inside the firstmate repo"
        return $deny
    }
    return @{ Ok = $true; Path = $absTarget }
}

<#
.SYNOPSIS
registered_descendant_home_for_removal.
.DESCRIPTION
Returns @{Code;Id;Home}. Code 0 = a registered descendant home was found (and
must block the removal), 1 = none found, 2 = the registry itself refused. The
bash twin's three-way return is preserved because the caller treats 1 and 2
differently.
#>
function Get-FmTdDescendantHome {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Registry,
        [Parameter(Mandatory, Position = 1)][string]$Target
    )
    $none = @{ Code = 1; Id = ''; Home = '' }
    if (-not (Test-FmTdRegularFile $Registry)) { return $none }

    $binding = Resolve-FmSecondmateRegistryBinding -Registry $Registry
    if (-not $binding.Ok) {
        $script:SecondmateRegistryError = $binding.Error
        Write-FmErr "REFUSED: $($binding.Error)"
        return @{ Code = 2; Id = ''; Home = '' }
    }

    foreach ($line in (Get-FmFileLines $Registry)) {
        if (-not $line.StartsWith('- ', [System.StringComparison]::Ordinal)) { continue }
        $record = ConvertFrom-FmSecondmateRegistryLine $line
        if ($null -eq $record) {
            Write-FmErr "REFUSED: malformed secondmate registry entry: $line"
            return @{ Code = 2; Id = ''; Home = '' }
        }
        $registeredAbs = Get-FmTdRemovalAbsPath $record.Home
        if ([string]::IsNullOrEmpty($registeredAbs)) { continue }
        if ($registeredAbs -ceq $Target) { continue }
        if (Test-FmTdPathAncestor $Target $registeredAbs) {
            return @{ Code = 0; Id = $record.Id; Home = $registeredAbs }
        }
    }
    return $none
}

# validate_firstmate_operational_dirs_for_removal
function Test-FmTdOperationalDirs {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$HomePath,
        [Parameter(Mandatory, Position = 1)][string]$Label
    )
    $absHome = Get-FmTdRemovalAbsPath $HomePath
    foreach ($name in @('data', 'state', 'config', 'projects')) {
        $dir = "$HomePath/$name"
        $isLink = Test-FmSymlink $dir
        $reachable = Test-FmTdDirectory $dir
        if (-not (Test-FmTdPresent $dir) -and -not $isLink) { continue }
        if ($isLink -and -not $reachable -and -not (Test-FmTdRegularFile $dir)) {
            Write-FmErr "REFUSED: unsafe $Label $name directory $dir resolves outside the secondmate home"
            return $false
        }
        $absDir = ''
        if ($reachable) {
            $absDir = Get-FmTdCanonicalDir $dir
            if ($null -eq $absDir) { $absDir = '' }
        } elseif (Test-FmTdPresent $dir) {
            Write-FmErr "REFUSED: unsafe $Label $name path $dir is not a directory"
            return $false
        }
        if ($absDir -eq '' -or -not (Test-FmTdPathAncestor $absHome $absDir)) {
            Write-FmErr "REFUSED: unsafe $Label $name directory $dir resolves outside the secondmate home"
            return $false
        }
    }
    return $true
}

# validate_child_worktree_for_removal
function Get-FmTdValidatedChildWorktree {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Project = ''
    )
    $skip = @{ Ok = $true; Path = '' }
    $deny = @{ Ok = $false; Path = '' }

    if ([string]::IsNullOrEmpty($Target)) { return $skip }
    if (-not (Test-FmTdPresent $Target)) { return $skip }

    $validated = Get-FmTdValidatedRemovalTarget $Target 'child worktree'
    if (-not $validated.Ok) { return $deny }
    $absTarget = $validated.Path

    $absHome = Get-FmTdCanonicalDir $script:FmHome
    if ($null -ne $absHome -and (Test-FmTdPathAncestor $absHome $absTarget)) {
        Write-FmErr "REFUSED: unsafe child worktree removal target $Target is inside the active firstmate home"
        return $deny
    }
    $absRoot = Get-FmTdCanonicalDir $script:FmRoot
    if (Test-FmTdPathAncestor $absRoot $absTarget) {
        Write-FmErr "REFUSED: unsafe child worktree removal target $Target is inside the firstmate repo"
        return $deny
    }
    if (-not (Test-FmTdWorktreeRegistered $Project $Target)) {
        $shown = if ([string]::IsNullOrEmpty($Project)) { 'the recorded project' } else { $Project }
        Write-FmErr "REFUSED: unsafe child worktree removal target $Target is not a git worktree for $shown"
        return $deny
    }
    return @{ Ok = $true; Path = $absTarget }
}

# safe_rm_rf
function Remove-FmTdSafeTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; the guard is validate-removal-target, exactly as in the bash twin, and a prompt would stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 1)][string]$Label
    )
    if (-not (Get-FmTdValidatedRemovalTarget $Target $Label).Ok) { return $false }
    return (Remove-FmTdTree $Target)
}

# safe_rm_rf_child_worktree
function Remove-FmTdSafeChildWorktree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; the guard is validate-child-worktree-for-removal, exactly as in the bash twin.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Project
    )
    if (-not (Get-FmTdValidatedChildWorktree $Target $Project).Ok) { return $false }
    return (Remove-FmTdTree $Target)
}

<#
.SYNOPSIS
validate_firstmate_home_for_removal - a home may be retired only when it is a
seeded secondmate home, marked for the expected id, registry-consistent, and
contains no registered descendant home.
.DESCRIPTION
Returns @{Ok;Path}, with the same "exists?" distinction as
Get-FmTdValidatedRemovalTarget.
#>
function Get-FmTdValidatedHome {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$HomePath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Label = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedId = ''
    )
    $skip = @{ Ok = $true; Path = '' }
    $deny = @{ Ok = $false; Path = '' }

    if ([string]::IsNullOrEmpty($HomePath)) { return $skip }
    if (-not (Test-FmTdPresent $HomePath)) { return $skip }

    $validated = Get-FmTdValidatedRemovalTarget $HomePath $Label
    if (-not $validated.Ok) { return $deny }
    $absHomePath = $validated.Path

    if (-not (Test-FmTdRegularFile "$absHomePath/$($script:SubHomeMarker)")) {
        Write-FmErr "REFUSED: unsafe $Label removal target $HomePath is not a seeded secondmate home"
        return $deny
    }

    if (-not [string]::IsNullOrEmpty($ExpectedId)) {
        $markerId = Get-FmTdCaptured (Get-FmFileText "$absHomePath/$($script:SubHomeMarker)")
        if ($markerId -cne $ExpectedId) {
            $shown = if ($markerId -eq '') { 'unknown' } else { $markerId }
            Write-FmErr ("REFUSED: unsafe $Label removal target $HomePath is marked for secondmate $shown, " +
                "expected $ExpectedId")
            return $deny
        }
        if (Test-FmTdPresent $script:SecondmateReg) {
            $binding = Resolve-FmSecondmateRegistryBinding -Registry $script:SecondmateReg `
                -ExpectedId $ExpectedId -ExpectedHome $absHomePath
            if (-not $binding.Ok) {
                $script:SecondmateRegistryError = $binding.Error
                if ($binding.Error.StartsWith('overlapping secondmate home assignment:', [System.StringComparison]::Ordinal)) {
                    Write-FmErr ("REFUSED: unsafe $Label removal target $HomePath contains registered " +
                        "secondmate home; $($binding.Error)")
                } else {
                    Write-FmErr "REFUSED: $($binding.Error)"
                }
                return $deny
            }
        }
    }

    if (-not (Test-FmTdOperationalDirs -HomePath $absHomePath -Label $Label)) { return $deny }

    $conflict = Get-FmTdDescendantHome -Registry $script:SecondmateReg -Target $absHomePath
    if ($conflict.Code -eq 2) { return $deny }
    if ($conflict.Code -ne 0) {
        $conflict = Get-FmTdDescendantHome -Registry "$absHomePath/data/secondmates.md" -Target $absHomePath
        if ($conflict.Code -eq 2) { return $deny }
    }
    if ($conflict.Code -eq 0) {
        Write-FmErr ("REFUSED: unsafe $Label removal target $HomePath contains registered secondmate home " +
            "$($conflict.Home) for $($conflict.Id)")
        return $deny
    }
    return @{ Ok = $true; Path = $absHomePath }
}

# remove_firstmate_home. A LEASED home is returned to the treehouse pool so the
# slot is freed; a failed return leaves the home and state in place rather than
# hiding a still-held lease.
function Remove-FmTdFirstmateHome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; removal happens only behind validate-firstmate-home-for-removal, exactly as in the bash twin.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$HomePath = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Label = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$ExpectedId = ''
    )
    if ([string]::IsNullOrEmpty($HomePath)) { return $true }
    if (-not (Test-FmTdPresent $HomePath)) { return $true }

    $validated = Get-FmTdValidatedHome $HomePath $Label -ExpectedId $ExpectedId
    if (-not $validated.Ok) { return $false }
    if ([string]::IsNullOrEmpty($validated.Path)) { return $true }
    $absHomePath = $validated.Path

    if (Test-FmTdHomeHasTreehouseSlot $absHomePath) {
        if (-not (Test-FmCommand 'treehouse')) {
            Write-FmErr "error: treehouse command not found; cannot return $Label $absHomePath"
            return $false
        }
        if ((Invoke-FmTdTreehouseReturn -Directory $absHomePath -WorkingDirectory $script:FmRoot -Label $Label) -ne 0) {
            Write-FmErr "error: treehouse return failed for $Label $absHomePath; lease may still be held"
            return $false
        }
        return $true
    }
    return (Remove-FmTdSafeTree $absHomePath $Label)
}

# The `for child_meta in "$sub_state"/*.meta` glob, in filesystem order.
function Get-FmTdChildMeta {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns every child meta record; the singular would read as get-one-record.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$StateDir)
    $native = ConvertTo-FmNativePath $StateDir
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return @() }
    $out = @()
    foreach ($item in ([System.IO.Directory]::GetFileSystemEntries($native, '*.meta'))) {
        $out += "$StateDir/$([System.IO.Path]::GetFileName($item))"
    }
    return @($out)
}

# validate_firstmate_home_children_removal
function Test-FmTdHomeChildrenRemoval {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)

    $subState = "$HomePath/state"
    if (-not (Test-FmTdDirectory $subState)) { return $true }

    foreach ($childMeta in (Get-FmTdChildMeta -StateDir $subState)) {
        if (-not (Test-FmTdPresent $childMeta)) { continue }
        $childId = [System.IO.Path]::GetFileNameWithoutExtension($childMeta)
        if (-not (Get-FmBackendValidatedEndpoint $childMeta $childId).Ok) { return $false }
        if (-not (Test-FmTdPrPollCleanup -StateDir $subState -TaskId $childId)) { return $false }

        $childWt = Get-FmTdMetaValue $childMeta 'worktree'
        $childKind = Get-FmTdMetaValue $childMeta 'kind'
        if ([string]::IsNullOrEmpty($childKind)) { $childKind = 'ship' }
        $childBackend = Get-FmBackendOfMeta $childMeta

        if ($childKind -ceq 'secondmate') {
            $childHome = Get-FmTdMetaValue $childMeta 'home'
            if ([string]::IsNullOrEmpty($childHome)) { $childHome = $childWt }
            if (-not (Get-FmTdValidatedHome $childHome 'child firstmate home' -ExpectedId $childId).Ok) { return $false }
            if (-not (Test-FmTdHomeChildrenRemoval $childHome)) { return $false }
        } elseif ($childBackend -ceq 'orca') {
            $childOrcaId = Get-FmTdOrcaWorktreeId $childMeta
            if ($null -eq $childOrcaId) { return $false }
            if (-not [string]::IsNullOrEmpty($childWt) -and (Test-FmTdPresent $childWt)) {
                $childProj = Get-FmTdMetaValue $childMeta 'project'
                if (-not (Get-FmTdValidatedChildWorktree $childWt $childProj).Ok) { return $false }
                if (-not (Test-FmTdOrcaPathMatch $childOrcaId $childWt)) { return $false }
            }
        } elseif (-not [string]::IsNullOrEmpty($childWt) -and (Test-FmTdPresent $childWt)) {
            $childProj = Get-FmTdMetaValue $childMeta 'project'
            if (-not (Get-FmTdValidatedChildWorktree $childWt $childProj).Ok) { return $false }
        }
    }
    return $true
}

# --- Herdr presentation locks ------------------------------------------------
#
# TEARDOWN_HERDR_LOCK_RECORDS is a TAB-delimited "<session>\t<lock path>" list in
# bash; here it is an array of hashtables. Release happens from the finally in
# the main body, standing in for `trap ... EXIT` (divergence 2).

function Unlock-FmTdHerdrLocks {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if ($script:HerdrLockRecords.Count -eq 0) { return }
    foreach ($record in $script:HerdrLockRecords) {
        if ([string]::IsNullOrEmpty($record.Path)) { continue }
        try { Unlock-FmLock -LockPath $record.Path } catch { $null = $_ }
    }
    $script:HerdrLockRecords = @()
}

function Test-FmTdHerdrLockHeld {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Session = '')
    foreach ($record in $script:HerdrLockRecords) {
        if ($record.Session -ceq $Session) { return $true }
    }
    return $false
}

# teardown_herdr_require_prerequisites
function Test-FmTdHerdrPrerequisites {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$TaskId)

    $unavailable = ("error: herdr teardown prerequisites are unavailable for $TaskId; nothing was changed - " +
        'restore the adapter and rerun teardown')
    if (-not (Import-FmBackendAdapter 'herdr')) {
        Write-FmErr $unavailable
        return $false
    }
    foreach ($prerequisite in @(
            'Get-FmBackendHerdrTarget'
            'Get-FmBackendHerdrPanePresenceState'
            'Get-FmBackendHerdrWorkspacePresenceState'
            'Test-FmBackendHerdrEndpointGone'
            'Close-FmBackendHerdrPaneExplicit'
            'Get-FmBackendHerdrPresentationSessionLockPath')) {
        if (-not (Get-Command $prerequisite -ErrorAction SilentlyContinue)) {
            Write-FmErr $unavailable
            return $false
        }
    }
    if (-not (Get-Command 'Request-FmLock' -ErrorAction SilentlyContinue)) {
        # The lazy source of the lock machinery. NOT -Force: that would remove
        # the already-loaded module tree globally, and fm-common would vanish
        # from under this script (docs/powershell-port.md).
        try { Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Global } catch { $null = $_ }
    }
    if ((-not (Get-Command 'Request-FmLock' -ErrorAction SilentlyContinue)) -or
        (-not (Get-Command 'Unlock-FmLock' -ErrorAction SilentlyContinue))) {
        Write-FmErr ("error: herdr teardown lock machinery is unavailable for $TaskId; nothing was changed - " +
            'restore the lock support and rerun teardown')
        return $false
    }
    return $true
}

# teardown_herdr_preflight_target
function Test-FmTdHerdrPreflight {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Target = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$TaskId = ''
    )
    if (-not (Test-FmTdHerdrPrerequisites -TaskId $TaskId)) { return $false }

    $parsed = Get-FmBackendHerdrTarget $Target
    if ($null -eq $parsed) {
        Write-FmErr ("error: herdr endpoint $Target for $TaskId could not be parsed exactly; nothing was " +
            'changed - repair the endpoint metadata and rerun teardown')
        return $false
    }
    $session = $parsed.Session
    $pane = $parsed.Pane

    $presence = Get-FmBackendHerdrPanePresenceState -Session $session -PaneId $pane
    if ($presence -cne 'dead' -and $presence -cne 'present') {
        Write-FmErr ("error: herdr endpoint $Target for $TaskId has ambiguous structured presence; nothing was " +
            'changed - restore reliable endpoint inspection and rerun teardown')
        return $false
    }

    $lockPath = Get-FmBackendHerdrPresentationSessionLockPath $session
    if ([string]::IsNullOrEmpty($lockPath)) {
        Write-FmErr ("error: herdr session presentation lock could not be resolved for $TaskId; nothing was " +
            'changed - rerun teardown once the session is reachable and unambiguous')
        return $false
    }

    foreach ($record in $script:HerdrLockRecords) {
        if ($record.Session -cne $session) { continue }
        if ($record.Path -cne $lockPath) {
            Write-FmErr ("error: herdr session presentation lock changed during preflight for $TaskId; nothing " +
                'was changed - rerun teardown once session identity is stable')
            return $false
        }
        return $true
    }

    $attempt = 0
    while ($attempt -lt 50) {
        if (Request-FmLock -LockPath $lockPath) {
            $verified = Get-FmBackendHerdrPresentationSessionLockPath $session
            if ([string]::IsNullOrEmpty($verified) -or $verified -cne $lockPath) {
                try { Unlock-FmLock -LockPath $lockPath } catch { $null = $_ }
                Write-FmErr ("error: herdr session presentation lock changed during preflight for $TaskId; " +
                    'nothing was changed - rerun teardown once session identity is stable')
                return $false
            }
            $script:HerdrLockRecords += @{ Session = $session; Path = $lockPath }
            return $true
        }
        Start-Sleep -Milliseconds 100
        $attempt++
    }
    Write-FmErr ("error: herdr session presentation lock is contended for $TaskId; nothing was changed - " +
        'rerun teardown once the contention clears')
    return $false
}

# preflight_firstmate_home_herdr_children
function Test-FmTdHerdrChildrenPreflight {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)

    $subState = "$HomePath/state"
    if (-not (Test-FmTdDirectory $subState)) { return $true }

    foreach ($childMeta in (Get-FmTdChildMeta -StateDir $subState)) {
        if (-not (Test-FmTdPresent $childMeta)) { continue }
        $childId = [System.IO.Path]::GetFileNameWithoutExtension($childMeta)
        $endpoint = Get-FmBackendValidatedEndpoint $childMeta $childId
        if (-not $endpoint.Ok) { return $false }
        if ($endpoint.Backend -ceq 'herdr') {
            if (-not (Test-FmTdHerdrPreflight $endpoint.Target $childId)) { return $false }
        }
        $childKind = Get-FmTdMetaValue $childMeta 'kind'
        if ([string]::IsNullOrEmpty($childKind)) { $childKind = 'ship' }
        if ($childKind -ceq 'secondmate') {
            $childWt = Get-FmTdMetaValue $childMeta 'worktree'
            $childHome = Get-FmTdMetaValue $childMeta 'home'
            if ([string]::IsNullOrEmpty($childHome)) { $childHome = $childWt }
            if (-not (Test-FmTdHerdrChildrenPreflight $childHome)) { return $false }
        }
    }
    return $true
}

<#
.SYNOPSIS
cleanup_firstmate_home_children - the --force discard path for a secondmate's
whole child tree.
.DESCRIPTION
Returns 0 on success, TEARDOWN_TREEHOUSE_LOCK_REFUSED when a child worktree
return hit a lock that is not provably stale, and 1 for every other refusal.
Every child's durable identity records are RETAINED whenever its endpoint could
not be proved gone.
#>
function Clear-FmTdHomeChildren {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; this is the explicit --force discard path whose authority is the captain, checked by the caller, exactly as in the bash twin.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)

    $subState = "$HomePath/state"
    if (-not (Test-FmTdDirectory $subState)) { return 0 }

    foreach ($childMeta in (Get-FmTdChildMeta -StateDir $subState)) {
        if (-not (Test-FmTdPresent $childMeta)) { continue }
        $childId = [System.IO.Path]::GetFileNameWithoutExtension($childMeta)
        $childWt = Get-FmTdMetaValue $childMeta 'worktree'
        $childProj = Get-FmTdMetaValue $childMeta 'project'
        $childKind = Get-FmTdMetaValue $childMeta 'kind'
        if ([string]::IsNullOrEmpty($childKind)) { $childKind = 'ship' }
        $childBackend = Get-FmBackendOfMeta $childMeta

        $childTarget = if ($childBackend -ceq 'orca') {
            Get-FmTdMetaValue $childMeta 'terminal'
        } else {
            Get-FmBackendTargetOfMeta $childMeta
        }

        $childOrcaId = ''
        if ($childBackend -ceq 'orca' -and $childKind -cne 'secondmate') {
            $childOrcaId = Get-FmTdOrcaWorktreeId $childMeta
            if ($null -eq $childOrcaId) { return 1 }
            if (-not [string]::IsNullOrEmpty($childWt) -and (Test-FmTdPresent $childWt)) {
                if (-not (Get-FmTdValidatedChildWorktree $childWt $childProj).Ok) { return 1 }
            }
        }

        if (-not [string]::IsNullOrEmpty($childTarget)) {
            if ($childBackend -ceq 'herdr') {
                $parsed = Get-FmBackendHerdrTarget $childTarget
                if ($null -eq $parsed) { return 1 }
                if (-not (Test-FmTdHerdrLockHeld $parsed.Session)) {
                    Write-FmErr ("error: herdr session presentation lock is not held for child $childId; " +
                        "retaining that child's durable identity records and stopping forced cleanup")
                    return 1
                }
                try {
                    $null = Remove-FmBackendHerdrTargetSerialized $parsed.Session $parsed.Pane
                } catch { $null = $_ }
                if (-not (Test-FmBackendHerdrEndpointGone $childTarget)) {
                    Write-FmErr ("error: herdr pane $childTarget for child $childId is not confirmed gone; " +
                        "retaining that child's durable identity records and stopping forced cleanup")
                    return 1
                }
            } elseif ($childBackend -ceq 'zellij') {
                # Zellij titles are scoped by the owning home tag, so forced
                # secondmate cleanup must verify child tabs as that CHILD home.
                # The bash twin scopes that with a `( ... )` subshell; here the
                # three variables are saved and restored around the call.
                $savedRootOverride = [Environment]::GetEnvironmentVariable('FM_ROOT_OVERRIDE')
                $savedHome = [Environment]::GetEnvironmentVariable('FM_HOME')
                $savedRoot = [Environment]::GetEnvironmentVariable('FM_ROOT')
                try {
                    [Environment]::SetEnvironmentVariable('FM_ROOT_OVERRIDE', $null)
                    [Environment]::SetEnvironmentVariable('FM_HOME', $HomePath)
                    [Environment]::SetEnvironmentVariable('FM_ROOT', $HomePath)
                    $null = Remove-FmBackendTarget $childBackend $childTarget
                } catch {
                    $null = $_
                } finally {
                    [Environment]::SetEnvironmentVariable('FM_ROOT_OVERRIDE', $savedRootOverride)
                    [Environment]::SetEnvironmentVariable('FM_HOME', $savedHome)
                    [Environment]::SetEnvironmentVariable('FM_ROOT', $savedRoot)
                }
            } else {
                try { $null = Remove-FmBackendTarget $childBackend $childTarget } catch { $null = $_ }
            }
        }

        if ($childKind -ceq 'secondmate') {
            $childHome = Get-FmTdMetaValue $childMeta 'home'
            if ([string]::IsNullOrEmpty($childHome)) { $childHome = $childWt }
            if (-not [string]::IsNullOrEmpty($childHome) -and (Test-FmTdDirectory $childHome)) {
                $rc = Clear-FmTdHomeChildren $childHome
                if ($rc -ne 0) { return $rc }
                $null = Remove-FmTdFirstmateHome $childHome 'child firstmate home' $childId
            }
        } elseif ($childBackend -ceq 'orca') {
            if (-not [string]::IsNullOrEmpty($childWt) -and (Test-FmTdDirectory $childWt)) {
                if (-not (Get-FmTdValidatedChildWorktree $childWt $childProj).Ok) { return 1 }
                foreach ($leaf in @('.claude/settings.local.json', '.opencode/plugins/fm-turn-end.js',
                        '.fm-grok-turnend', '.fm-kimi-turnend')) {
                    $null = Remove-FmTdFile "$childWt/$leaf"
                }
            }
            if (-not (Remove-FmBackendWorktree $childBackend $childOrcaId)) { return 1 }
        } elseif (-not [string]::IsNullOrEmpty($childWt) -and (Test-FmTdDirectory $childWt)) {
            if (-not (Get-FmTdValidatedChildWorktree $childWt $childProj).Ok) { return 1 }
            foreach ($leaf in @('.claude/settings.local.json', '.opencode/plugins/fm-turn-end.js',
                    '.opencode/plugins/fm-busy-state.js', '.fm-grok-turnend', '.fm-kimi-turnend')) {
                $null = Remove-FmTdFile "$childWt/$leaf"
            }
            if ((-not [string]::IsNullOrEmpty($childProj)) -and (Test-FmTdDirectory $childProj) -and (Test-FmCommand 'treehouse')) {
                $rc = Invoke-FmTdTreehouseReturn -Directory $childWt -WorkingDirectory $childProj -Label 'child worktree'
                if ($rc -ne 0) {
                    if ($rc -eq $script:TeardownTreehouseLockRefused) { return $rc }
                    $null = Remove-FmTdSafeChildWorktree $childWt $childProj
                }
            } else {
                $null = Remove-FmTdSafeChildWorktree $childWt $childProj
            }
        }

        Remove-FmTdGrokTurnendAuth $subState $childId
        Remove-FmTdKimiTurnendAuth $subState $childId
        if (-not (Remove-FmTdPrPollArtifacts -StateDir $subState -TaskId $childId)) { return 1 }

        $childBusyGen = Get-FmTdMetaValue $childMeta 'busy_gen'
        if ([string]::IsNullOrEmpty($childBusyGen)) {
            $childBusyGen = Get-FmTdCaptured (Get-FmFileText "$subState/$childId.busy-gen")
        }
        if ((Invoke-FmTdBusyRetire $subState $childId -Generation $childBusyGen) -ne 0) { return 1 }

        # muse-session / muse-session-current are muse's whole wiring footprint: it
        # installs no hook, so the session-log binding sidecar and its resolution
        # cache are the only artifacts a retired muse pane leaves behind.
        foreach ($suffix in @('status', 'turn-ended', 'meta', 'pi-ext.ts', 'grok-turnend-token',
                'kimi-turnend-token', 'muse-session', 'muse-session-current')) {
            $null = Remove-FmTdFile "$subState/$childId.$suffix"
        }
    }
    return 0
}

# remove_secondmate_registry_entry
function Remove-FmTdRegistryEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'SupportsShouldProcess is for user-facing cmdlets needing -WhatIf/-Confirm; this rewrites a private registry after the retirement it records has already been authorized.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$TaskId)
    if (-not (Test-FmTdRegularFile $script:SecondmateReg)) { return }
    $body = ''
    foreach ($line in (Get-FmFileLines $script:SecondmateReg)) {
        if ($line -match ("^- " + [regex]::Escape($TaskId) + "( |$)")) { continue }
        $body += "$line`n"
    }
    # The bash twin writes a sibling temp and `mv`s it over; Set-FmFileTextAtomic
    # is that pattern's owner.
    $null = Set-FmFileTextAtomic -Path $script:SecondmateReg -Text $body -NoNewline
}

# public_followup_resolve_primary_home
function Resolve-FmTdPrimaryHome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Parent = '',
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$Child = '',
        [Parameter(Position = 2)][AllowEmptyString()][AllowNull()][string]$TaskId = ''
    )
    if (-not (Test-FmPfHomeId "secondmate:$TaskId")) { return $null }
    # `case "$parent" in /*)` - absolute only. A drive-absolute spelling is the
    # same category on this platform and is accepted alongside it, matching
    # Get-FmSecondmateRegistryPathKey's documented widening.
    if (-not ($Parent.StartsWith('/') -or $Parent -match '^[A-Za-z]:[\\/]')) { return $null }

    $parentAbs = Get-FmTdCanonicalDir $Parent
    if ($null -eq $parentAbs) { return $null }
    $childAbs = Get-FmTdCanonicalDir $Child
    if ($null -eq $childAbs) { return $null }
    if ($parentAbs -ceq $childAbs) { return $null }

    $parentMeta = "$parentAbs/state/$TaskId.meta"
    if (-not (Test-FmTdRegularFile $parentMeta) -or (Test-FmSymlink $parentMeta)) { return $null }
    if ((Get-FmTdMetaValue $parentMeta 'kind') -cne 'secondmate') { return $null }

    $metaHome = Get-FmTdCanonicalDir (Get-FmTdMetaValue $parentMeta 'home')
    if ($null -eq $metaHome) { return $null }
    if ($metaHome -cne $childAbs) { return $null }

    $binding = Resolve-FmSecondmateRegistryBinding -Registry "$parentAbs/data/secondmates.md" `
        -ExpectedId $TaskId -ExpectedHome $childAbs
    if (-not $binding.Ok) { return $null }
    return $parentAbs
}

# =============================================================================
# MAIN
# =============================================================================

Invoke-FmMain -UnexpectedCode 70 {
    try {
        # --- argument gate ---------------------------------------------------
        if ($fmArgv.Count -lt 1 -or -not (Test-FmTaskIdPathSafe -Id ([string]$fmArgv[0]))) {
            Write-FmErr 'error: invalid teardown request'
            Exit-FmScript 2
        }
        $script:Id = [string]$fmArgv[0]
        $script:Force = if ($fmArgv.Count -ge 2) { [string]$fmArgv[1] } else { '' }

        # Fail closed before any fleet mutation: a no-mistakes gate agent must
        # never tear down a worktree. Exits by itself when it refuses.
        Assert-FmNotGateAgent

        $script:Meta = "$($script:State)/$($script:Id).meta"
        if (-not (Test-FmTdRegularFile $script:Meta)) {
            Write-FmErr "error: no meta for task $($script:Id) at $($script:Meta)"
            Exit-FmScript 1
        }

        # THE FIRST cleanup authorization check: metadata-only, and it must
        # complete before the guard, a backend command, any file removal, a
        # branch deletion, a worktree return, a registry change, or a process
        # termination can run.
        $endpoint = Get-FmBackendValidatedEndpoint $script:Meta $script:Id
        if (-not $endpoint.Ok) { Exit-FmScript 1 }
        $script:Backend = $endpoint.Backend
        $script:Target = $endpoint.Target

        $script:Worktree = Get-FmTdMetaValue $script:Meta 'worktree'
        $script:Project = Get-FmTdMetaValue $script:Meta 'project'
        $orcaTerminal = if ($script:Backend -ceq 'orca') { $script:Target } else { '' }

        $null = Invoke-FmScript -Name 'fm-guard' -BinDir "$($script:FmRoot)/bin" -Stream

        $homePath = Get-FmTdGrepValue $script:Meta 'home'
        $script:PrUrl = Get-FmMetaValue $script:Meta 'pr'
        # tasktmp is recorded by fm-spawn for tasks that set up a per-task temp
        # root; absent for older tasks, so tolerate empty.
        $taskTmp = Get-FmTdGrepValue $script:Meta 'tasktmp'
        $busyGen = Get-FmTdMetaValue $script:Meta 'busy_gen'
        if ([string]::IsNullOrEmpty($busyGen)) {
            $busyGen = Get-FmTdCaptured (Get-FmFileText "$($script:State)/$($script:Id).busy-gen")
        }
        $orcaWorktreeId = Get-FmTdMetaValue $script:Meta 'orca_worktree_id'
        $orcaPathMatchVerified = $false

        $script:Kind = Get-FmTdGrepValue $script:Meta 'kind'
        if ([string]::IsNullOrEmpty($script:Kind)) { $script:Kind = 'ship' }
        $script:Mode = Get-FmTdGrepValue $script:Meta 'mode'
        if ([string]::IsNullOrEmpty($script:Mode)) { $script:Mode = 'no-mistakes' }

        # --- public-followup home resolution ---------------------------------
        $pfHome = $script:FmHome
        $pfState = $script:State
        $pfWorkHome = 'main'
        $pfParentUnresolved = $false
        $pfParentRelayActive = $false
        $pfRelayActive = $false
        $secondMateId = ''

        if (Test-FmTdRegularFile "$($script:FmHome)/$($script:SubHomeMarker)") {
            $markerLines = (Get-FmFileLines "$($script:FmHome)/$($script:SubHomeMarker)")
            $secondMateId = if ($markerLines.Count -ge 1) { $markerLines[0] } else { '' }
            # A marked child only enters the primary-binding path when the
            # authoritative parent relay is active.
            $primaryHomeEnv = Get-FmEnv -Name 'FM_PUBLIC_FOLLOWUP_PRIMARY_HOME'
            if ($primaryHomeEnv) {
                if (Test-FmPfRelayActive $primaryHomeEnv) { $pfParentRelayActive = $true }
            } elseif (Test-FmPfRelayActive $script:FmHome) {
                $pfParentRelayActive = $true
            }
            if ($pfParentRelayActive) {
                $pfParentUnresolved = $true
                if (Test-FmPfHomeId "secondmate:$secondMateId") {
                    $pfWorkHome = "secondmate:$secondMateId"
                    $resolved = Resolve-FmTdPrimaryHome $primaryHomeEnv $script:FmHome $secondMateId
                    if ($null -ne $resolved) {
                        $pfHome = $resolved
                        $pfState = "$resolved/state"
                        $pfParentUnresolved = $false
                        if ($script:Force -cne '--force' -and (Test-FmPfRelayActive $pfHome)) {
                            $pfRelayActive = $true
                        }
                    } else {
                        $pfHome = ''
                        $pfState = ''
                    }
                }
            } else {
                $pfHome = ''
                $pfState = ''
            }
        } elseif ($script:Kind -ceq 'secondmate') {
            $pfWorkHome = "secondmate:$($script:Id)"
            if ($script:Force -cne '--force' -and (Test-FmPfRelayActive $script:FmHome)) { $pfRelayActive = $true }
        } elseif ($script:Force -cne '--force' -and (Test-FmPfRelayActive $script:FmHome)) {
            $pfRelayActive = $true
        }

        # --- Orca endpoint resolution ----------------------------------------
        if ($script:Backend -ceq 'orca' -and $script:Kind -cne 'secondmate') {
            $orcaWorktreeId = Get-FmTdOrcaWorktreeId $script:Meta
            if ($null -eq $orcaWorktreeId) { Exit-FmScript 1 }
            $orcaTerminal = Get-FmTdMetaValue $script:Meta 'terminal'
            if (-not [string]::IsNullOrEmpty($orcaTerminal)) { $script:Target = $orcaTerminal }
        }

        # --- lock-recovery knobs ---------------------------------------------
        $script:StaleWorktreeLockAgeSecs = Get-FmEnv -Name 'FM_STALE_WORKTREE_LOCK_AGE_SECS' -Default '30'
        $script:TreehouseReturnLockRetries = Get-FmEnv -Name 'FM_TREEHOUSE_RETURN_LOCK_RETRIES' -Default '3'
        $script:TreehouseReturnLockRetryWaitSecs = Get-FmEnv -Name 'FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS' `
            -Default (Get-FmEnv -Name 'FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS' -Default '1')
        if (-not (Test-FmTdRetryWait $script:TreehouseReturnLockRetryWaitSecs)) {
            Write-FmErr ("teardown: invalid treehouse return lock retry wait " +
                "'$($script:TreehouseReturnLockRetryWaitSecs)'; using 1s")
            $script:TreehouseReturnLockRetryWaitSecs = '1'
        }

        # --- PR-check artifact validation ------------------------------------
        if (-not (Test-FmTdPrPollCleanup -StateDir $script:State -TaskId $script:Id)) { Exit-FmScript 1 }

        # --- secondmate retirement gates -------------------------------------
        if ($script:Kind -ceq 'secondmate') {
            if ([string]::IsNullOrEmpty($homePath)) { $homePath = $script:Worktree }
            if (-not (Get-FmTdValidatedHome $homePath 'secondmate home' -ExpectedId $script:Id).Ok) { Exit-FmScript 1 }
            if ($script:Force -ceq '--force') {
                if (-not (Test-FmTdHomeChildrenRemoval $homePath)) { Exit-FmScript 1 }
                if ($script:Backend -ceq 'herdr') {
                    if (-not (Test-FmTdHerdrPreflight $script:Target $script:Id)) { Exit-FmScript 1 }
                }
                if (-not (Test-FmTdHerdrChildrenPreflight $homePath)) { Exit-FmScript 1 }
            }
        }

        if ($script:Kind -ceq 'secondmate' -and $script:Force -cne '--force') {
            $subState = "$homePath/state"
            if (Test-FmTdDirectory $subState) {
                foreach ($childMeta in (Get-FmTdChildMeta -StateDir $subState)) {
                    if (-not (Test-FmTdPresent $childMeta)) { continue }
                    Write-FmErr "REFUSED: secondmate $($script:Id) still has in-flight work in $subState."
                    Write-FmErr ("Found $([System.IO.Path]::GetFileName($childMeta)). Let that home finish or " +
                        'explicitly discard with --force.')
                    Exit-FmScript 1
                }
            }
        }

        if ($script:Kind -ceq 'secondmate' -and $script:Force -ceq '--force') {
            # The bash twin does NOT check this return value; a non-zero result
            # falls through to the rest of teardown exactly as it does there.
            $null = Clear-FmTdHomeChildren $homePath
        }

        # --- scout gates ------------------------------------------------------
        if ($script:Kind -ceq 'scout' -and $script:Force -cne '--force') {
            $report = "$($script:Data)/$($script:Id)/report.md"
            if (-not (Test-FmTdRegularFile $report)) {
                Write-FmErr "REFUSED: scout task $($script:Id) has no report at $report."
                Write-FmErr ('The report is the work product. Have the crewmate write it, or use --force after ' +
                    'explicit discard approval.')
                Exit-FmScript 1
            }
            $savedEnv = @{}
            foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE')) {
                $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            $holdOk = $false
            try {
                [Environment]::SetEnvironmentVariable('FM_HOME', $script:FmHome)
                [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $script:State)
                [Environment]::SetEnvironmentVariable('FM_DATA_OVERRIDE', $script:Data)
                [Environment]::SetEnvironmentVariable('FM_CONFIG_OVERRIDE', $script:Config)
                # stdout is discarded (`>/dev/null`), stderr belongs to the user.
                $r = Invoke-FmScript -Name 'fm-decision-hold' -Arguments @('verify', $script:Id)
                if ($r.StdErr -ne '') { Write-FmRaw $r.StdErr }
                $holdOk = $r.Ok
            } finally {
                foreach ($name in $savedEnv.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
                }
            }
            if (-not $holdOk) {
                Write-FmErr "REFUSED: scout task $($script:Id) has not passed the unresolved-decision completion gate."
                Write-FmErr 'Inventory its report and any visual review through bin/fm-decision-hold.sh before teardown.'
                Exit-FmScript 1
            }
        }

        # --- public follow-up gates ------------------------------------------
        # A public commitment is not kept until its final reply lands in the
        # ORIGINAL thread, and this cleanup removes the records that make the
        # promise reconcilable.
        if ($script:Force -cne '--force' -and $pfParentUnresolved) {
            Write-FmErr ("REFUSED: cannot resolve the primary home for marked secondmate $secondMateId; " +
                'refusing cleanup without its durable parent binding.')
            Exit-FmScript 1
        }
        if ($script:Force -cne '--force' -and $pfState -ne '' -and $pfRelayActive -and (Test-FmPfHasRegistration $pfState)) {
            $savedEnv = @{}
            foreach ($name in @('FM_HOME', 'FM_STATE_OVERRIDE')) {
                $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            $guard = $null
            try {
                [Environment]::SetEnvironmentVariable('FM_HOME', $pfHome)
                [Environment]::SetEnvironmentVariable('FM_STATE_OVERRIDE', $pfState)
                $guard = Invoke-FmScript -Name 'fm-public-followup' -Arguments @('guard-work', $pfWorkHome, $script:Id)
            } finally {
                foreach ($name in $savedEnv.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
                }
            }
            if (-not $guard.Ok) {
                Write-FmErr "REFUSED: task $($script:Id) still owes a public reply through the myfirstmate relay."
                Write-FmErr (Get-FmTdCaptured $guard.StdOut)
                Write-FmErr ('Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with ' +
                    'tasks-axi public-followup waive, or use --force after explicit discard approval.')
                Exit-FmScript 1
            }
        }

        # --- Orca inspectability ---------------------------------------------
        if ($script:Backend -ceq 'orca' -and $script:Kind -cne 'scout' -and
            $script:Kind -cne 'secondmate' -and $script:Force -cne '--force') {
            if (-not (Test-FmTdInspectableWorktree $script:Worktree)) {
                $shown = if ([string]::IsNullOrEmpty($script:Worktree)) { '<missing>' } else { $script:Worktree }
                Write-FmErr "REFUSED: Orca ship task $($script:Id) has no inspectable git worktree at $shown."
                Write-FmErr ('Cannot verify dirty or unlanded work; restore the worktree path or get explicit OK ' +
                    'to discard, then --force.')
                Exit-FmScript 1
            }
            if (-not (Test-FmTdOrcaPathMatch $orcaWorktreeId $script:Worktree)) { Exit-FmScript 1 }
            $orcaPathMatchVerified = $true
        }

        # --- THE landed-work gate --------------------------------------------
        if ((Test-FmTdDirectory $script:Worktree) -and $script:Force -cne '--force') {
            $safetyRc = Test-FmTdWorktreeSafety
            if ($safetyRc -ne 0) {
                if ($safetyRc -eq $script:TeardownWorktreeSafetyLockBlocked) {
                    if ((Clear-FmTdStaleLockForSafety -Directory $script:Worktree) -ne 0) { Exit-FmScript 1 }
                    if ((Test-FmTdWorktreeSafety) -ne 0) { Exit-FmScript 1 }
                } else {
                    Exit-FmScript 1
                }
            }
        }

        # --- Herdr presentation lock, acquired BEFORE anything destructive ---
        $herdrSession = ''
        $herdrPane = ''
        if ($script:Backend -ceq 'herdr') {
            if (-not (Test-FmTdHerdrPreflight $script:Target $script:Id)) { Exit-FmScript 1 }
            $parsed = Get-FmBackendHerdrTarget $script:Target
            if ($null -eq $parsed) { Exit-FmScript 1 }
            $herdrSession = $parsed.Session
            $herdrPane = $parsed.Pane
        }

        # --- branch cleanup and worktree return ------------------------------
        if ($script:Backend -ceq 'orca' -and $script:Kind -cne 'secondmate') {
            if (-not $orcaPathMatchVerified) {
                if (-not (Test-FmTdOrcaPathMatchIfPresent $orcaWorktreeId $script:Worktree)) { Exit-FmScript 1 }
                $orcaPathMatchVerified = $true
            }
            if (Test-FmTdDirectory $script:Worktree) {
                $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD')
                $branch = if ($r.Ok) { Get-FmTdCaptured $r.StdOut } else { 'HEAD' }
                if ($branch -cne 'HEAD') {
                    if ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('checkout', '--detach', '-q')).Ok) {
                        $null = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('branch', '-D', $branch)
                    }
                }
                foreach ($leaf in @('.claude/settings.local.json', '.opencode/plugins/fm-turn-end.js',
                        '.opencode/plugins/fm-busy-state.js', '.fm-grok-turnend', '.fm-kimi-turnend')) {
                    $null = Remove-FmTdFile "$($script:Worktree)/$leaf"
                }
            }
            if (-not [string]::IsNullOrEmpty($orcaTerminal)) {
                try { $null = Remove-FmBackendTarget $script:Backend $script:Target } catch { $null = $_ }
            }
            $null = Remove-FmBackendWorktree $script:Backend $orcaWorktreeId
        } elseif ((Test-FmTdDirectory $script:Worktree) -and $script:Kind -cne 'secondmate') {
            $r = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD')
            $branch = if ($r.Ok) { Get-FmTdCaptured $r.StdOut } else { 'HEAD' }
            if ($branch -cne 'HEAD') {
                if ((Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('checkout', '--detach', '-q')).Ok) {
                    $null = Invoke-FmTdGit -Directory $script:Worktree -GitArguments @('branch', '-D', $branch)
                }
            }
            # Remove our hook file so a reused pool worktree cannot fire signals
            # for a dead task.
            foreach ($leaf in @('.claude/settings.local.json', '.opencode/plugins/fm-turn-end.js',
                    '.fm-grok-turnend', '.fm-kimi-turnend')) {
                $null = Remove-FmTdFile "$($script:Worktree)/$leaf"
            }
            # Kills remaining processes in the worktree (including the agent),
            # resets, returns to pool. treehouse resolves the pool from the
            # working directory, so run it from the project.
            $postCheck = $null
            if ($script:Force -cne '--force' -and $script:Kind -cne 'scout' -and $script:Kind -cne 'secondmate') {
                $postCheck = { Test-FmTdWorktreeSafety }
            }
            $returnArgs = @{
                Directory        = $script:Worktree
                WorkingDirectory = $script:Project
                Label            = 'worktree'
            }
            if ($null -ne $postCheck) { $returnArgs['PostCleanupCheck'] = $postCheck }
            if ((Invoke-FmTdTreehouseReturn @returnArgs) -ne 0) {
                Write-FmErr "error: treehouse return failed for worktree $($script:Worktree); teardown aborted"
                Exit-FmScript 1
            }
        }

        # --- Herdr presentation journal --------------------------------------
        $journal = "$($script:State)/$($script:Id).herdr-presentation"
        $retireCandidate = $false
        $presentationSession = ''
        $presentationPane = ''
        if ($script:Backend -ceq 'herdr' -and (Test-FmTdPresent $journal)) {
            $null = Import-FmBackendAdapter 'herdr'
            $presentationSession = Get-FmTdMetaValue $script:Meta 'herdr_session'
            $presentationWorkspace = Get-FmTdMetaValue $script:Meta 'herdr_workspace_id'
            $presentationPane = Get-FmTdMetaValue $script:Meta 'herdr_pane_id'
            if ((-not [string]::IsNullOrEmpty($presentationSession)) -and
                (-not [string]::IsNullOrEmpty($presentationWorkspace)) -and
                (-not [string]::IsNullOrEmpty($presentationPane)) -and
                ($script:Target -ceq "${presentationSession}:${presentationPane}") -and
                (Test-FmBackendHerdrProjectionEndpointJournal -Session $presentationSession `
                        -WorkspaceId $presentationWorkspace -Journal $journal -TaskId $script:Id)) {
                $retireCandidate = $true
            }
        }

        if ($retireCandidate) {
            # The presentation lock was acquired before the worktree return
            # above; a contended lock already refused while everything was intact.
            if (Test-FmTdHerdrLockHeld $presentationSession) {
                try {
                    $null = Close-FmBackendHerdrProjectionPane $presentationSession $presentationPane
                } catch { $null = $_ }
            } else {
                Write-FmErr ('warning: herdr presentation focus lock unavailable; refusing a concurrent ' +
                    'focus-unsafe pane close')
            }
        } elseif ($script:Backend -ceq 'herdr') {
            if (Test-FmTdHerdrLockHeld $herdrSession) {
                try { $null = Remove-FmBackendHerdrTargetSerialized $herdrSession $herdrPane } catch { $null = $_ }
            } else {
                Write-FmErr ('warning: herdr session presentation lock path is unavailable; skipping the pane ' +
                    'close rather than closing unlocked')
            }
        } elseif ($script:Backend -cne 'orca') {
            try { $null = Remove-FmBackendTarget $script:Backend $script:Target } catch { $null = $_ }
        }

        if ($retireCandidate) {
            if ((Get-FmBackendHerdrPaneAgentState -Session $presentationSession -PaneId $presentationPane) -ceq 'dead') {
                $null = Remove-FmTdFile $journal
            } else {
                Write-FmErr ("warning: exact herdr task-pane close could not be confirmed for $($script:Id); " +
                    'retaining the presentation journal and attempting no workspace cleanup')
            }
        } elseif ($script:Backend -ceq 'herdr' -and (Test-FmTdPresent $journal)) {
            Write-FmErr ("warning: herdr presentation journal for $($script:Id) remains quarantined; no " +
                'workspace cleanup was attempted')
        }

        # A refused, skipped, or failed Herdr close must never erase a live
        # task's durable endpoint identity. Only a structured not-found proves
        # the pane gone; unknown presence, missing or malformed endpoint
        # identity, and missing confirmation machinery all refuse.
        if ($script:Backend -ceq 'herdr') {
            $null = Import-FmBackendAdapter 'herdr'
            if (-not (Get-Command 'Test-FmBackendHerdrEndpointGone' -ErrorAction SilentlyContinue)) {
                Write-FmErr ("error: herdr endpoint confirmation is unavailable for $($script:Id); retaining " +
                    'every durable task record')
                Exit-FmScript 1
            }
            if (-not (Test-FmBackendHerdrEndpointGone $script:Target)) {
                Write-FmErr ("error: herdr pane $($script:Target) for $($script:Id) is not confirmed gone after " +
                    'its close was refused, skipped, or failed; retaining every durable task record - rerun ' +
                    'teardown once the close can run under the session lock')
                Exit-FmScript 1
            }
        }

        # --- durable record removal ------------------------------------------
        if ($script:Kind -ceq 'secondmate') {
            if ([string]::IsNullOrEmpty($homePath)) { $homePath = $script:Worktree }
            $null = Remove-FmTdFirstmateHome $homePath 'secondmate home' $script:Id
            Remove-FmTdRegistryEntry $script:Id
        }
        Remove-FmTdGrokTurnendAuth $script:State $script:Id
        Remove-FmTdKimiTurnendAuth $script:State $script:Id
        try { $null = Clear-FmBackendTransition $script:Backend $script:State $script:Target } catch { $null = $_ }

        # The per-task temp root recorded by spawn. Read BEFORE the state-file
        # removals below; empty (a pre-tasktmp task) is a no-op.
        if (-not [string]::IsNullOrEmpty($taskTmp)) { $null = Remove-FmTdTree $taskTmp }

        if (-not (Remove-FmTdPrPollArtifacts -StateDir $script:State -TaskId $script:Id)) { Exit-FmScript 1 }
        if ((Invoke-FmTdBusyRetire $script:State $script:Id -Generation $busyGen) -ne 0) { Exit-FmScript 1 }
        # muse leaves no hook behind - only its session-log binding sidecar and the
        # resolution cache keyed to it, both of which must go with the pane.
        foreach ($suffix in @('status', 'turn-ended', 'meta', 'pi-ext.ts', 'grok-turnend-token',
                'kimi-turnend-token', 'muse-session', 'muse-session-current')) {
            $null = Remove-FmTdFile "$($script:State)/$($script:Id).$suffix"
        }

        if ($script:Kind -cne 'scout' -and $script:Kind -cne 'secondmate' -and $script:Mode -cne 'local-only') {
            $null = Invoke-FmScript -Name 'fm-fleet-sync' -BinDir "$($script:FmRoot)/bin" `
                -Arguments @($script:Project) -Stream
        }

        Write-FmOut "teardown $($script:Id) complete (window $($script:Target), worktree $($script:Worktree))"
        Write-FmTdBacklogReminder
        Exit-FmScript 0
    } finally {
        # Stands in for `trap teardown_release_herdr_locks EXIT`: Exit-FmScript
        # raises an ExitException, and a finally runs for it, so the session
        # presentation lock is released on the refusal paths too.
        Unlock-FmTdHerdrLocks
    }
}
