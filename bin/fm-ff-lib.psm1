# fm-ff-lib.psm1 - shared fast-forward machinery for firstmate self-sync.
# Twin: bin/fm-ff-lib.sh
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update) pulls from origin: base mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn on launch, bin/fm-bootstrap on
#     startup) follows the PRIMARY checkout's current default-branch commit: the
#     base mode is that local commit, with NO fetch and no origin dependency.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path
# updates it. A tracked-files fast-forward never touches the gitignored
# operational dirs (data/, state/, config/, projects/, .no-mistakes/), so it
# cannot disturb a secondmate's backlog, projects, or in-flight work. The seeded
# .fm-secondmate-home identity marker is gitignored too; the local sync tolerates
# only that marker during the one-time upgrade of pre-ignore linked-worktree
# homes. Homes are leased at a detached HEAD on the default branch, so the
# fast-forward advances HEAD only and never moves the shared default branch or
# any other worktree's checkout.
#
# THE REFUSALS ARE THE PRODUCT. Every "skipped:" arm below is a decision not to
# touch someone's work, and each one is reproduced with its exact wording because
# bin/fm-bootstrap and bin/fm-spawn surface these lines to the captain verbatim
# (tests/fm-secondmate-sync.test.sh asserts several of them as literal
# substrings). Nothing here recovers, retries, forces, stashes, or resolves: a
# fast-forward that cannot be done cleanly is REFUSED and the target is left
# exactly as it was found.
#
# bash -> PowerShell:
#
#   first_line                    -> Get-FmFfFirstLine
#   default_branch                -> Get-FmFfDefaultBranch
#   primary_head_commit           -> Get-FmFfPrimaryHeadCommit
#   resolve_path                  -> Resolve-FmFfPath
#   resolved_existing_dir         -> Resolve-FmFfExistingDirectory
#   path_is_ancestor_of           -> Test-FmFfPathIsAncestor
#   validate_operational_dirs     -> Get-FmFfOperationalDirectoryError
#   validate_secondmate_home      -> Resolve-FmFfSecondmateHome
#   VALIDATED_HOME/VALIDATION_ERROR -> ValidatedHome/Error on that result
#   fetch_once + FETCHED          -> Invoke-FmFfFetchOnce (+ Clear-FmFfFetchCache)
#   changed_instr                 -> Get-FmFfChangedInstruction
#   dirty_status                  -> Get-FmFfDirtyStatus
#   live_secondmate_meta_records  -> Get-FmFfLiveSecondmateMetaRecord
#   ff_target                     -> Invoke-FmFfTarget
#   FF_STATUS / FF_INSTR          -> Status/Instructions on that result
#   process_secondmate            -> Invoke-FmFfSecondmate
#   sweep_live_secondmate_metas   -> Invoke-FmFfSecondmateSweep
#   FF_NUDGE_WINDOWS/FF_SEEN_HOMES -> New-FmFfSweepState, threaded as -State
#   SUB_HOME_MARKER               -> Get-FmFfSecondmateMarkerName
#   fm_ff_after_instruction_update -> -AfterInstructionUpdate scriptblock
#
# ---------------------------------------------------------------------------
# Out-globals become return values, EXCEPT the printed line
# ---------------------------------------------------------------------------
# The bash publishes FF_STATUS/FF_INSTR/VALIDATED_HOME/VALIDATION_ERROR as shell
# globals a sourcing caller reads afterwards; a module has its own scope, so each
# function returns an object carrying those fields instead.
#
# The printed status line is different, and is kept: ff_target ECHOES one line
# per target and its callers pipe that stdout straight through to the captain.
# So Invoke-FmFfTarget writes the identical line AND returns the object. That is
# safe to combine only because Write-FmOut writes to [Console]::Out directly
# rather than to PowerShell's output stream - it cannot contaminate the returned
# object the way a bare string would. The line is also returned as .Line, so a
# caller that wants to capture rather than emit has it without re-deriving it.
#
# ---------------------------------------------------------------------------
# Paths: one spelling, chosen so the comparisons stay meaningful
# ---------------------------------------------------------------------------
# Every path this module resolves comes back in NATIVE Windows form, because git
# is called as git.exe (which cannot resolve /f/x) and because .NET file APIs
# cannot either. The bash twin's `pwd -P` yields MSYS form, so the two worlds
# spell the same directory differently - but every comparison here is between
# two paths this module resolved itself, so the spelling is internally
# consistent. A caller handing in an MSYS path (from a durable record written by
# a bash twin) is converted on entry.
#
# Comparison is ORDINAL, matching the bash `case` and `!=` tests exactly, and
# deliberately NOT case-insensitive even though Windows filesystems are.
# Verified on this host: MSYS `pwd -P` does NOT canonicalise case either (cd to
# a lowercased spelling of CaseDir answers .../casedir), so ordinal is what
# keeps the two worlds agreeing. Case-insensitive comparison would be STRICTER
# here - every use is a refusal or a skip - so it is a defensible hardening, but
# it is a behavior change and belongs in a deliberate change, not in a port.
#
# ---------------------------------------------------------------------------
# What is NOT reproduced
# ---------------------------------------------------------------------------
# `git merge --ff-only` output is captured as `2>&1` by the bash, which
# interleaves the two streams in real time. Invoke-FmTool keeps them separate,
# so the twin concatenates stdout then stderr before taking the first line. For
# the failure this actually reports (git writes "fatal: ..." to stderr with an
# empty stdout) the first line is identical; a hypothetical failure that wrote to
# BOTH streams could pick a different line here than in bash.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Explicit imports, not a reliance on the caller having imported them. A .psm1
# resolves function names in its OWN scope, so the undeclared cross-lib calls
# the bash tree tolerates (docs/powershell-port-inventory.md R4) would fail here
# at runtime. fm-ff-lib.sh sources fm-secondmate-registry-lib.sh for the
# registry home= fallback; that edge is declared the same way.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

# `SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"` - overridable from
# the environment, with bash `:-` semantics (an empty value means absent).
$script:FmFfSubHomeMarker = Get-FmEnv -Name 'SUB_HOME_MARKER' -Default '.fm-secondmate-home'

# The FETCHED memo: a single fetch refreshes every worktree that shares an object
# store, so each distinct git-common-dir is fetched at most once per process.
# A List with ordinal .Contains rather than -contains, which is case-INSENSITIVE
# for strings and would collapse two genuinely different object stores.
$script:FmFfFetched = [System.Collections.Generic.List[string]]::new()

# --- helpers -----------------------------------------------------------------

<#
.SYNOPSIS
The name of the seeded secondmate identity marker file.
#>
function Get-FmFfSecondmateMarkerName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:FmFfSubHomeMarker
}

<#
.SYNOPSIS
Forget which object stores have already been fetched this process.
.DESCRIPTION
The bash FETCHED global is per-process and its callers never reset it; this
exists so a long-lived PowerShell session (or a test) can start a fresh sweep
without the memo from an earlier one deciding that a fetch already happened.
#>
function Clear-FmFfFetchCache {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This clears an in-memory memo, touches no file and no external state, and is called from non-interactive sweep code where a confirmation prompt would stall a hook.')]
    [CmdletBinding()]
    param()
    $script:FmFfFetched.Clear()
}

# The `$(cmd)` twin for a single-value git answer: command substitution strips
# TRAILING newlines and nothing else, so leading or interior whitespace in a ref
# name would survive here exactly as it does in bash.
function Get-FmFfCommandOutput {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)
    return $Text.TrimEnd("`n")
}

<#
.SYNOPSIS
Run git against a directory, capturing stdout, stderr and the exit code.
.DESCRIPTION
The `git -C "$dir" ...` twin. The directory is converted to native form first:
git.exe cannot resolve an MSYS path (/f/x reaches it as a relative name), and
durable firstmate records still carry MSYS form while the bash twins write them.
#>
function Invoke-FmFfGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $native = ConvertTo-FmNativePath $Directory
    return (Invoke-FmTool -FilePath 'git' -Arguments (@('-C', $native) + $Arguments))
}

<#
.SYNOPSIS
The first line of a message, with runs of whitespace collapsed to one space.
.DESCRIPTION
Twin of first_line, whose sed program is `1s/[[:space:]]\{1,\}/ /g;1p`. The
class is spelled as the six C-locale whitespace characters rather than .NET's
`\s`, which would additionally match NBSP and the Unicode space separators and
so could rewrite a byte the bash left alone.
#>
function Get-FmFfFirstLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    $normalized = $Text -replace "`r`n", "`n"
    $first = @($normalized -split "`n")[0]
    return ($first -replace '[ \t\v\f\r]+', ' ')
}

<#
.SYNOPSIS
The repository's default branch name, or $null when it cannot be determined.
.DESCRIPTION
origin/HEAD wins when it is set; otherwise the first of main, master that exists
as a local branch. $null is the `return 1` twin, and its one caller turns it into
"skipped: cannot determine default branch" rather than guessing a branch.
#>
function Get-FmFfDefaultBranch {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $result = Invoke-FmFfGit -Directory $Directory -Arguments @(
        'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    # bash captures stdout with `|| true`, so a failure simply yields ''.
    $ref = Get-FmFfCommandOutput -Text $result.StdOut
    if ($ref -ne '') {
        # ${ref#origin/}: strip ONE leading "origin/", nothing more.
        if ($ref.StartsWith('origin/')) { return $ref.Substring('origin/'.Length) }
        return $ref
    }

    foreach ($branch in @('main', 'master')) {
        $verify = Invoke-FmFfGit -Directory $Directory -Arguments @(
            'show-ref', '--verify', '--quiet', "refs/heads/$branch")
        if ($verify.Ok) { return $branch }
    }
    return $null
}

<#
.SYNOPSIS
The PRIMARY checkout's current default-branch commit, or $null.
.DESCRIPTION
Reads the default branch REF rather than HEAD, so even a primary stranded on a
feature branch (the worktree tangle of AGENTS.md section 8) still yields the true
default-branch tip instead of propagating a stray feature branch to the fleet.
#>
function Get-FmFfPrimaryHeadCommit {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Root)

    $default = Get-FmFfDefaultBranch -Directory $Root
    if ([string]::IsNullOrEmpty($default)) { return $null }
    $result = Invoke-FmFfGit -Directory $Root -Arguments @(
        'rev-parse', '--verify', '--quiet', "refs/heads/$default^{commit}")
    if (-not $result.Ok) { return $null }
    $commit = Get-FmFfCommandOutput -Text $result.StdOut
    if ($commit -eq '') { return $null }
    return $commit
}

<#
.SYNOPSIS
A directory resolved through every symlink, or $null when it is not a directory.
.DESCRIPTION
Twin of resolved_existing_dir (`[ -d "$path" ] || return 1; cd "$path" && pwd -P`).
#>
function Resolve-FmFfExistingDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $null }
    return (Resolve-FmPhysicalDirectory -Directory $Path)
}

<#
.SYNOPSIS
A canonical absolute path, falling back to the input when it does not exist.
.DESCRIPTION
Twin of resolve_path, whose fallback exists so callers can still dedup or skip on
a path that is not there. The fallback is converted to native form rather than
returned verbatim: its only consumers compare it against ANOTHER resolved path,
and leaving one side in MSYS spelling would make two names for one directory
compare as different - which in process_secondmate would mean processing the
firstmate repo itself as its own secondmate. Converting keeps both sides in one
spelling, so the guard still fires.
#>
function Resolve-FmFfPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    $resolved = Resolve-FmPhysicalDirectory -Directory $Path
    if ($null -ne $resolved) { return $resolved }
    return (ConvertTo-FmNativePath $Path)
}

<#
.SYNOPSIS
True when Ancestor strictly contains Path.
.DESCRIPTION
Twin of path_is_ancestor_of: both must be non-empty, they must differ, and Path
must begin with Ancestor plus a separator. Equality is deliberately NOT ancestry,
because the callers test the two conditions separately with different messages.

Both separators are accepted because this module resolves to native form (`\`)
while a caller may hand in a durable record's POSIX form (`/`); the bash only
ever sees `/`. The comparison is ordinal - see the header on case.
#>
function Test-FmFfPathIsAncestor {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Ancestor,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$Path
    )

    if ([string]::IsNullOrEmpty($Ancestor)) { return $false }
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Ancestor -ceq $Path) { return $false }
    return ($Path.StartsWith($Ancestor + '\', [System.StringComparison]::Ordinal) -or
        $Path.StartsWith($Ancestor + '/', [System.StringComparison]::Ordinal))
}

# --- secondmate home validation ----------------------------------------------

<#
.SYNOPSIS
The reason a secondmate home's operational dirs are unsafe, or $null when safe.
.DESCRIPTION
Twin of validate_operational_dirs. data/, state/, config/ and projects/ hold a
secondmate's backlog, runtime records and clones; each must resolve INSIDE that
home and outside both the active firstmate home and the firstmate repo, or a
fast-forward of the home could reach work that is not its own.

A dangling symlink is rejected first and by name: `-e` follows links, so a link
pointing nowhere would otherwise fall through to the "create it later" arm and
be treated as absent.
#>
function Get-FmFfOperationalDirectoryError {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ActiveHome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoRoot
    )

    foreach ($name in @('data', 'state', 'config', 'projects')) {
        $dir = Join-Path $HomePath $name
        if ((Test-FmSymlink $dir) -and -not (Test-Path -LiteralPath $dir)) {
            return "secondmate $name directory must resolve inside the secondmate home"
        }

        $absDir = $null
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $absDir = Resolve-FmPhysicalDirectory -Directory $dir
            if ($null -eq $absDir) {
                return "secondmate $name directory cannot be resolved"
            }
        } elseif (Test-Path -LiteralPath $dir) {
            return "secondmate $name path is not a directory"
        } else {
            $absDir = $dir
        }

        if (-not (Test-FmFfPathIsAncestor -Ancestor $HomePath -Path $absDir)) {
            return "secondmate $name directory must resolve inside the secondmate home"
        }
        if (($absDir -ceq $ActiveHome) -or (Test-FmFfPathIsAncestor -Ancestor $ActiveHome -Path $absDir)) {
            return "secondmate $name directory cannot be inside the active firstmate home"
        }
        if (($absDir -ceq $RepoRoot) -or (Test-FmFfPathIsAncestor -Ancestor $RepoRoot -Path $absDir)) {
            return "secondmate $name directory cannot be inside the firstmate repo"
        }
    }
    return $null
}

<#
.SYNOPSIS
Validate a secondmate home, returning Ok, ValidatedHome and Error.
.DESCRIPTION
Twin of validate_secondmate_home, in the same order, with byte-identical reasons.
Order is load-bearing: "cannot be the active firstmate home" must be reported
before "cannot be inside" it, or an exact match would be described as
containment.

The home is proven to BE a seeded firstmate home carrying this exact id before
anything is allowed to fast-forward it. That marker check is the difference
between advancing a secondmate and advancing an unrelated checkout that merely
sits at the recorded path.

ActiveHome and RepoRoot are parameters rather than reads of $FM_HOME/$FM_ROOT:
the bash relies on those being SHELL variables its sourcing caller already set
(they are not necessarily exported), which a module cannot see. They default to
the environment so a converted caller can still lean on it, and a caller holding
a Get-FmContext result passes $ctx.Home and $ctx.Root explicitly.
#>
function Resolve-FmFfSecondmateHome {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [string]$ActiveHome,
        [string]$RepoRoot
    )

    if (-not $PSBoundParameters.ContainsKey('ActiveHome')) { $ActiveHome = Get-FmEnv -Name 'FM_HOME' }
    if (-not $PSBoundParameters.ContainsKey('RepoRoot')) { $RepoRoot = Get-FmEnv -Name 'FM_ROOT' }

    $result = [pscustomobject]@{ Ok = $false; ValidatedHome = ''; Error = '' }

    $absHome = Resolve-FmFfExistingDirectory -Path $HomePath
    if ($null -eq $absHome) {
        $result.Error = 'not a directory'
        return $result
    }
    $absActiveHome = Resolve-FmFfExistingDirectory -Path $ActiveHome
    if ($null -eq $absActiveHome) {
        $result.Error = 'active firstmate home is not a directory'
        return $result
    }
    $absRoot = Resolve-FmFfExistingDirectory -Path $RepoRoot
    if ($null -eq $absRoot) {
        $result.Error = 'firstmate repo is not a directory'
        return $result
    }

    # `[ "$abs_home" = "/" ]`. The POSIX filesystem root has no single Windows
    # spelling, so a drive root (F:\) is its twin: it is the same "everything
    # below this is the whole volume" hazard the bash refuses.
    if ($absHome -ceq '/' -or $absHome -match '^[A-Za-z]:[\\/]?$') {
        $result.Error = 'secondmate home cannot be the filesystem root'
        return $result
    }
    if ($absHome -ceq $absActiveHome) {
        $result.Error = 'secondmate home cannot be the active firstmate home'
        return $result
    }
    if ($absHome -ceq $absRoot) {
        $result.Error = 'secondmate home cannot be the firstmate repo'
        return $result
    }
    if (Test-FmFfPathIsAncestor -Ancestor $absActiveHome -Path $absHome) {
        $result.Error = 'secondmate home cannot be inside the active firstmate home'
        return $result
    }
    if (Test-FmFfPathIsAncestor -Ancestor $absRoot -Path $absHome) {
        $result.Error = 'secondmate home cannot be inside the firstmate repo'
        return $result
    }
    if (Test-FmFfPathIsAncestor -Ancestor $absHome -Path $absActiveHome) {
        $result.Error = 'secondmate home cannot be an ancestor of the active firstmate home'
        return $result
    }
    if (Test-FmFfPathIsAncestor -Ancestor $absHome -Path $absRoot) {
        $result.Error = 'secondmate home cannot be an ancestor of the firstmate repo'
        return $result
    }

    $dirError = Get-FmFfOperationalDirectoryError -HomePath $absHome `
        -ActiveHome $absActiveHome -RepoRoot $absRoot
    if ($null -ne $dirError) {
        $result.Error = $dirError
        return $result
    }

    $marker = Join-Path $absHome $script:FmFfSubHomeMarker
    # Symlink FIRST: `-f` follows links, so a link to a real file would pass the
    # regular-file test while pointing the identity check somewhere else.
    if (Test-FmSymlink $marker) {
        $result.Error = 'secondmate marker must not be a symlink'
        return $result
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $marker))) {
        $result.Error = 'not a seeded secondmate home'
        return $result
    }
    # `$(cat ...)` strips trailing newlines and nothing else, so a CRLF marker
    # keeps its CR and fails the identity comparison in both worlds.
    $markerId = (Get-FmFileText $marker).TrimEnd("`n")
    if ($markerId -cne $Id) {
        $shown = if ($markerId -eq '') { 'unknown' } else { $markerId }
        $result.Error = "marked for secondmate $shown, expected $Id"
        return $result
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $absHome 'AGENTS.md')))) {
        $result.Error = 'not a firstmate home (missing AGENTS.md)'
        return $result
    }
    if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath (Join-Path $absHome 'bin')) -PathType Container)) {
        $result.Error = 'not a firstmate home (missing bin/)'
        return $result
    }

    $result.ValidatedHome = $absHome
    $result.Ok = $true
    return $result
}

# --- fetch, diff, dirtiness ---------------------------------------------------

<#
.SYNOPSIS
Fetch origin for a directory's object store at most once per process.
.DESCRIPTION
Twin of fetch_once. Used ONLY by the origin base mode; the local-HEAD secondmate
sync never fetches, which tests/fm-secondmate-sync.test.sh proves by shadowing
git and asserting no fetch was invoked.

A directory whose git-common-dir cannot be read is still fetched, and simply not
memoized - the bash does the same, preferring a redundant fetch to skipping one.
#>
function Invoke-FmFfFetchOnce {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $commonResult = Invoke-FmFfGit -Directory $Directory -Arguments @(
        'rev-parse', '--path-format=absolute', '--git-common-dir')
    $common = ''
    if ($commonResult.Ok) { $common = Get-FmFfCommandOutput -Text $commonResult.StdOut }

    if ($common -ne '' -and $script:FmFfFetched.Contains($common)) { return $true }

    $fetch = Invoke-FmFfGit -Directory $Directory -Arguments @('fetch', 'origin', '--prune', '--quiet')
    if ($fetch.Ok) {
        if ($common -ne '') { $script:FmFfFetched.Add($common) }
        return $true
    }
    return $false
}

<#
.SYNOPSIS
Which watched instruction paths changed between HEAD and a base, comma-listed.
.DESCRIPTION
Twin of changed_instr. These are the files a running agent actually reads or
runs: its instructions (AGENTS.md, which CLAUDE.md symlinks), its agent-loaded
skills (.agents/skills/), and its tooling (bin/). Public skills/ is
installer-facing and intentionally not part of this watched surface.

`! git diff --quiet` is true for ANY non-zero status, so a git ERROR counts as
"changed" exactly as it does in bash - which is the safe direction: it can only
cause a re-read nudge that was not strictly needed, never suppress one.
#>
function Get-FmFfChangedInstruction {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Base
    )

    $out = ''
    foreach ($p in @('AGENTS.md', 'bin', '.agents/skills')) {
        $diff = Invoke-FmFfGit -Directory $Directory -Arguments @(
            'diff', '--quiet', 'HEAD', $Base, '--', $p)
        if (-not $diff.Ok) {
            if ($out -ne '') { $out += ', ' }
            $out += $p
        }
    }
    return $out
}

<#
.SYNOPSIS
The first porcelain status line that counts as dirt, or '' when the tree is clean.
.DESCRIPTION
Twin of dirty_status. With -IgnoreSeedMarker the untracked seed marker alone is
forgiven, which is what lets a home seeded before .fm-secondmate-home was
gitignored converge on the very fast-forward that lands the ignore rule. It
forgives NOTHING else: a genuine uncommitted edit alongside the marker still
reads as dirty and still refuses the fast-forward.
#>
function Get-FmFfDirtyStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [switch]$IgnoreSeedMarker
    )

    $status = Invoke-FmFfGit -Directory $Directory -Arguments @('status', '--porcelain')
    # bash discards stderr and reads whatever came out; a failed git yields ''.
    $text = $status.StdOut
    if ([string]::IsNullOrEmpty($text)) { return '' }

    $marker = "?? $($script:FmFfSubHomeMarker)"
    foreach ($line in ($text -split "`n")) {
        if ($line -eq '') { continue }
        if ($IgnoreSeedMarker -and $line -ceq $marker) { continue }
        return $line
    }
    return ''
}

<#
.SYNOPSIS
This home's LIVE secondmate direct reports, from state/<id>.meta records.
.DESCRIPTION
Twin of live_secondmate_meta_records. The meta file is the liveness signal;
data/secondmates.md is only the fallback for durable fields such as home= when an
older or incomplete meta lacks them.

Returns objects with Id/Home/Window/Meta plus Text, the pipe-delimited record the
bash prints. Ordering is explicit and ordinal: a bash glob is sorted by the
shell, while .NET enumerates in filesystem order, so a sweep would otherwise
process homes in an order that varies between the two worlds and between runs.
#>
function Get-FmFfLiveSecondmateMetaRecord {
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [AllowEmptyString()][AllowNull()][string]$Registry = ''
    )

    # An EMPTY result leaves here as $null, because PowerShell collapses @() on
    # the way out of a function. `foreach` over it iterates zero times, which is
    # what every consumer in this module does; a consumer that instead counted
    # with `@(...).Count` would read 1 and treat a home with no live direct
    # reports as having one unreadable record.
    $records = [System.Collections.Generic.List[psobject]]::new()
    $native = ConvertTo-FmNativePath $StateDir
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return @($records) }

    $metas = [System.Collections.Generic.List[string]]::new()
    foreach ($f in [System.IO.Directory]::EnumerateFiles($native, '*.meta')) { $metas.Add($f) }
    $metas.Sort([System.StringComparer]::Ordinal)

    foreach ($meta in $metas) {
        if (-not [System.IO.File]::Exists($meta)) { continue }
        # `grep -q '^kind=secondmate$'`: an exact line anywhere in the record,
        # not a last-wins key read.
        $isSecondmate = $false
        foreach ($line in (Get-FmFileLines $meta)) {
            if ($line -ceq 'kind=secondmate') { $isSecondmate = $true; break }
        }
        if (-not $isSecondmate) { continue }

        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
        $homeValue = Get-FmMetaValue -MetaPath $meta -Key 'home'
        if ([string]::IsNullOrEmpty($homeValue) -and -not [string]::IsNullOrEmpty($Registry)) {
            $fromRegistry = Get-FmSecondmateRegistryField -Registry $Registry -Id $id -Key 'home'
            if ($null -ne $fromRegistry) { $homeValue = $fromRegistry }
        }
        $window = Get-FmMetaValue -MetaPath $meta -Key 'window'

        $records.Add([pscustomobject]@{
                Id     = $id
                Home   = $homeValue
                Window = $window
                Meta   = $meta
                Text   = "$id|$homeValue|$window|$meta"
            })
    }
    return @($records)
}

# --- the fast-forward itself --------------------------------------------------

<#
.SYNOPSIS
Fast-forward one target to a base, or refuse and say why. Prints its status line.
.DESCRIPTION
Twin of ff_target. Returns an object with:
  Status       updated | current | skipped
  Instructions comma list of changed instruction paths (only when updated)
  Line         the exact status line, which is also written to stdout

-BaseMode selects where the fast-forward base comes from:
  origin       fetch origin and advance to origin/<default> (the /updatefirstmate
               path); requires an origin remote and network reachability.
  <commit-ish> advance to that LOCAL commit with NO fetch and no origin
               dependency (the local-HEAD secondmate sync). The commit must
               already exist in the target's object store, which it always does
               for a worktree of this same repo; a standalone clone that lacks it
               is skipped rather than fetched.

Guards are identical in both modes: ff-only (never force, merge or stash); skip a
dirty, diverged, or wrong-branch target and leave its work untouched. Every arm
returns "success" in the bash sense - a refusal is a normal, reportable outcome,
not an error - so a caller distinguishes them by Status, never by throwing.
#>
function Invoke-FmFfTarget {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$BaseMode,
        [switch]$AllowDetached,
        [switch]$IgnoreSeedMarker
    )

    $result = [pscustomobject]@{ Status = 'skipped'; Instructions = ''; Line = '' }

    # One writer for every exit, so no arm can print a line it did not record.
    $emit = {
        param([string]$Text)
        $result.Line = $Text
        Write-FmOut $Text
        return $result
    }

    $native = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $native -PathType Container)) {
        return (& $emit "${Label}: skipped: not a directory")
    }
    $inTree = Invoke-FmFfGit -Directory $native -Arguments @('rev-parse', '--is-inside-work-tree')
    if (-not $inTree.Ok) {
        return (& $emit "${Label}: skipped: not a git repo")
    }

    $default = Get-FmFfDefaultBranch -Directory $native
    if ([string]::IsNullOrEmpty($default)) {
        return (& $emit "${Label}: skipped: cannot determine default branch")
    }

    $base = ''
    if ($BaseMode -ceq 'origin') {
        $remote = Invoke-FmFfGit -Directory $native -Arguments @('remote', 'get-url', 'origin')
        if (-not $remote.Ok) {
            return (& $emit "${Label}: skipped: no origin remote")
        }
        if (-not (Invoke-FmFfFetchOnce -Directory $native)) {
            return (& $emit "${Label}: skipped: fetch failed")
        }
        $base = "origin/$default"
    } else {
        $base = $BaseMode
    }

    $baseExists = Invoke-FmFfGit -Directory $native -Arguments @(
        'rev-parse', '--verify', '--quiet', "$base^{commit}")
    if (-not $baseExists.Ok) {
        return (& $emit "${Label}: skipped: $base does not exist")
    }

    $head = Invoke-FmFfGit -Directory $native -Arguments @('symbolic-ref', '--short', 'HEAD')
    $current = ''
    if ($head.Ok) { $current = Get-FmFfCommandOutput -Text $head.StdOut }
    if ($current -eq '' -and -not $AllowDetached) {
        return (& $emit "${Label}: skipped: detached HEAD, expected $default")
    }
    if ($current -ne '' -and $current -cne $default) {
        return (& $emit "${Label}: skipped: on $current, expected $default")
    }

    if ((Get-FmFfDirtyStatus -Directory $native -IgnoreSeedMarker:$IgnoreSeedMarker) -ne '') {
        return (& $emit "${Label}: skipped: dirty working tree")
    }

    $localRevResult = Invoke-FmFfGit -Directory $native -Arguments @('rev-parse', 'HEAD')
    if (-not $localRevResult.Ok) {
        return (& $emit "${Label}: skipped: cannot read HEAD")
    }
    $localRev = Get-FmFfCommandOutput -Text $localRevResult.StdOut
    $baseRevResult = Invoke-FmFfGit -Directory $native -Arguments @('rev-parse', $base)
    if (-not $baseRevResult.Ok) {
        return (& $emit "${Label}: skipped: cannot read $base")
    }
    $baseRev = Get-FmFfCommandOutput -Text $baseRevResult.StdOut

    if ($localRev -ceq $baseRev) {
        $result.Status = 'current'
        return (& $emit "${Label}: already current")
    }

    $ancestor = Invoke-FmFfGit -Directory $native -Arguments @(
        'merge-base', '--is-ancestor', 'HEAD', $base)
    if (-not $ancestor.Ok) {
        return (& $emit "${Label}: skipped: diverged from $base")
    }

    $instructions = Get-FmFfChangedInstruction -Directory $native -Base $base
    $beforeResult = Invoke-FmFfGit -Directory $native -Arguments @('rev-parse', '--short', 'HEAD')
    $before = Get-FmFfCommandOutput -Text $beforeResult.StdOut

    $merge = Invoke-FmFfGit -Directory $native -Arguments @('merge', '--ff-only', $base)
    if (-not $merge.Ok) {
        # The `2>&1` twin, with the caveat in this file's header.
        $combined = $merge.StdOut + $merge.StdErr
        $detail = Get-FmFfFirstLine -Text ($combined.TrimEnd("`n"))
        return (& $emit "${Label}: skipped: fast-forward failed: $detail")
    }

    $afterResult = Invoke-FmFfGit -Directory $native -Arguments @('rev-parse', '--short', 'HEAD')
    $after = Get-FmFfCommandOutput -Text $afterResult.StdOut

    $result.Status = 'updated'
    $result.Instructions = $instructions
    if ($instructions -ne '') {
        return (& $emit "${Label}: updated $before..$after (instructions changed: $instructions)")
    }
    return (& $emit "${Label}: updated $before..$after")
}

# --- sweep --------------------------------------------------------------------

<#
.SYNOPSIS
A fresh accumulator for one sweep: the nudge selectors and the homes already seen.
.DESCRIPTION
Twin of the FF_NUDGE_WINDOWS / FF_SEEN_HOMES globals the bash callers reset before
a sweep and read after. Passing the state explicitly removes the failure mode
where a caller forgets to reset and inherits the previous sweep's selectors.
#>
function New-FmFfSweepState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This allocates an in-memory accumulator and writes nothing durable, so a confirmation surface would only stall the non-interactive sweeps that use it.')]
    [CmdletBinding()]
    [OutputType([psobject])]
    param()
    return [pscustomobject]@{
        NudgeWindows = [System.Collections.Generic.List[string]]::new()
        SeenHomes    = [System.Collections.Generic.List[string]]::new()
    }
}

<#
.SYNOPSIS
Validate and fast-forward one secondmate home, accumulating its nudge selector.
.DESCRIPTION
Twin of process_secondmate. A home is nudged only when it ACTUALLY advanced
(Status updated) and has a live window. With -NudgeRequiresInstruction the
advance must also have changed the instruction surface: an already-current home,
or one whose only change was non-instruction tracked files, is left undisturbed.
The firstmate repo itself is never processed as its own secondmate, and each
resolved home is processed at most once.

An unsafe home is REPORTED and skipped, never repaired: the validation reasons
name the specific boundary that failed so an operator can fix the real problem.

-AfterInstructionUpdate is the twin of the optional
`type fm_ff_after_instruction_update` hook bin/fm-bootstrap defines around its
sweep. It is invoked with (Id, Home, Window, Instructions) on exactly the same
condition. A caller may instead define a function named
Invoke-FmFfAfterInstructionUpdate, which is probed the same optional way the bash
probes for its function - absent means "no hook", never an error.
#>
function Invoke-FmFfSecondmate {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HomePath,
        [AllowEmptyString()][AllowNull()][string]$Window = '',
        [Parameter(Mandatory)][string]$BaseMode,
        [switch]$NudgeRequiresInstruction,
        [Parameter(Mandatory)][psobject]$State,
        [string]$ActiveHome,
        [string]$RepoRoot,
        [scriptblock]$AfterInstructionUpdate
    )

    if (-not $PSBoundParameters.ContainsKey('ActiveHome')) { $ActiveHome = Get-FmEnv -Name 'FM_HOME' }
    if (-not $PSBoundParameters.ContainsKey('RepoRoot')) { $RepoRoot = Get-FmEnv -Name 'FM_ROOT' }

    if ([string]::IsNullOrEmpty($Id)) { return $null }
    if ([string]::IsNullOrEmpty($HomePath)) { return $null }

    $rootReal = Resolve-FmFfPath -Path $RepoRoot
    $homeReal = Resolve-FmFfPath -Path $HomePath
    if ($homeReal -ceq $rootReal) { return $null }

    $validation = Resolve-FmFfSecondmateHome -Id $Id -HomePath $HomePath `
        -ActiveHome $ActiveHome -RepoRoot $RepoRoot
    if (-not $validation.Ok) {
        $line = "secondmate ${Id}: skipped: unsafe home: $($validation.Error)"
        Write-FmOut $line
        return [pscustomobject]@{ Status = 'skipped'; Instructions = ''; Line = $line }
    }
    $homeReal = $validation.ValidatedHome

    if ($State.SeenHomes.Contains($homeReal)) { return $null }
    $State.SeenHomes.Add($homeReal)

    $ff = Invoke-FmFfTarget -Directory $homeReal -Label "secondmate $Id" -BaseMode $BaseMode `
        -AllowDetached -IgnoreSeedMarker

    if ($ff.Status -ceq 'updated' -and -not [string]::IsNullOrEmpty($Window)) {
        if ($NudgeRequiresInstruction -and $ff.Instructions -eq '') { return $ff }
        $State.NudgeWindows.Add("fm-$Id")
        if ($NudgeRequiresInstruction -and $ff.Instructions -ne '') {
            $hook = $AfterInstructionUpdate
            if ($null -eq $hook) {
                # The `type fm_ff_after_instruction_update` twin: an optional
                # capability, absent by default and never an error when missing.
                $command = Get-Command -Name 'Invoke-FmFfAfterInstructionUpdate' -ErrorAction SilentlyContinue
                if ($null -ne $command) {
                    $hook = { param($a, $b, $c, $d) Invoke-FmFfAfterInstructionUpdate $a $b $c $d }
                }
            }
            if ($null -ne $hook) {
                & $hook $Id $homeReal $Window $ff.Instructions
            }
        }
    }
    return $ff
}

<#
.SYNOPSIS
Sweep this home's LIVE secondmate direct reports, fast-forwarding each to a base.
.DESCRIPTION
Twin of sweep_live_secondmate_metas. Only state/<id>.meta records carrying
kind=secondmate are swept - a home with no live metadata is not a running direct
report and is never touched. The registry argument is only the home= fallback for
older or incomplete meta records.

Accumulates into the -State object, which the caller creates with
New-FmFfSweepState and reads afterwards.
#>
function Invoke-FmFfSecondmateSweep {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)][string]$StateDir,
        [Parameter(Mandatory)][string]$BaseMode,
        [switch]$NudgeRequiresInstruction,
        [AllowEmptyString()][AllowNull()][string]$Registry,
        [psobject]$State,
        [string]$ActiveHome,
        [string]$RepoRoot,
        [scriptblock]$AfterInstructionUpdate
    )

    if (-not $PSBoundParameters.ContainsKey('ActiveHome')) { $ActiveHome = Get-FmEnv -Name 'FM_HOME' }
    if (-not $PSBoundParameters.ContainsKey('RepoRoot')) { $RepoRoot = Get-FmEnv -Name 'FM_ROOT' }
    if (-not $PSBoundParameters.ContainsKey('State') -or $null -eq $State) { $State = New-FmFfSweepState }
    if (-not $PSBoundParameters.ContainsKey('Registry') -or [string]::IsNullOrEmpty($Registry)) {
        # bash: ${4:-$FM_HOME/data/secondmates.md}
        $registryHome = if ([string]::IsNullOrEmpty($ActiveHome)) { '' } else { $ActiveHome }
        $Registry = if ($registryHome -eq '') { '' } else { Join-Path (Join-Path $registryHome 'data') 'secondmates.md' }
    }

    $native = ConvertTo-FmNativePath $StateDir
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $State }

    foreach ($record in (Get-FmFfLiveSecondmateMetaRecord -StateDir $native -Registry $Registry)) {
        $call = @{
            Id       = $record.Id
            HomePath = $record.Home
            Window   = $record.Window
            BaseMode = $BaseMode
            State    = $State
        }
        if ($NudgeRequiresInstruction) { $call['NudgeRequiresInstruction'] = $true }
        # Passed explicitly rather than left to the callee's own env fallback:
        # this sweep already resolved them, and a second resolution could differ.
        $call['ActiveHome'] = $ActiveHome
        $call['RepoRoot'] = $RepoRoot
        if ($null -ne $AfterInstructionUpdate) { $call['AfterInstructionUpdate'] = $AfterInstructionUpdate }
        $null = Invoke-FmFfSecondmate @call
    }
    return $State
}

Export-ModuleMember -Function @(
    'Get-FmFfSecondmateMarkerName', 'Clear-FmFfFetchCache',
    'Get-FmFfFirstLine', 'Get-FmFfDefaultBranch', 'Get-FmFfPrimaryHeadCommit',
    'Resolve-FmFfPath', 'Resolve-FmFfExistingDirectory', 'Test-FmFfPathIsAncestor',
    'Get-FmFfOperationalDirectoryError', 'Resolve-FmFfSecondmateHome',
    'Invoke-FmFfFetchOnce', 'Get-FmFfChangedInstruction', 'Get-FmFfDirtyStatus',
    'Get-FmFfLiveSecondmateMetaRecord',
    'Invoke-FmFfTarget', 'New-FmFfSweepState',
    'Invoke-FmFfSecondmate', 'Invoke-FmFfSecondmateSweep'
)
