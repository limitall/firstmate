# Provision and route persistent secondmate homes.
#
# Twin: bin/fm-home-seed.sh
#
# Usage:
#   fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}
#       Provision <home> as an isolated firstmate home. If <home> is "-", acquire
#       a fresh firstmate worktree via "treehouse get --lease", which durably
#       leases the worktree under the secondmate <id> so the home survives with
#       no live process and is never recycled until the lease is released with
#       "treehouse return". Projects are cloned
#       from the active home into the secondmate home's projects/ directory.
#       That project list is non-exclusive provisioning data. Pass --no-projects
#       instead of a project list to seed a project-less home for a domain whose
#       subject is the firstmate repo itself; it is mutually exclusive with a
#       project list, and omitting both still fails loudly. A project-less seed
#       refuses a home with project clones or project-registry entries, so it
#       never converts populated homes in place. The charter brief
#       is copied to data/charter.md, newly cloned no-mistakes projects are
#       initialized, an ignored .fm-secondmate-home identity marker is written, and
#       data/secondmates.md is updated.
#       Seeding is transactional: on validation, clone, init, or registry failure,
#       generated briefs, new homes, new project clones, and registry edits are
#       rolled back. Treehouse-acquired homes are returned only when the rollback
#       target is safe; a failed return warns because the lease may still be held.
#       Set FM_SECONDMATE_CHARTER='<charter>' to seed from inline charter text
#       when no filled charter brief exists. Set FM_SECONDMATE_SCOPE='<scope>'
#       to override the registry routing scope. Otherwise the registry summary
#       and scope are derived from the filled charter brief.
#   fm-home-seed.sh validate
#       Refuse records that operational consumers cannot parse, unavailable or
#       unsafe registry files when present, non-absolute or unresolvable homes,
#       duplicate ids or homes, and nested or overlapping homes.
#
# ---------------------------------------------------------------------------
# RESOLVED PATHS ARE POSIX HERE, AND THAT IS NOT COSMETIC
# ---------------------------------------------------------------------------
# Every path this script canonicalises comes back in POSIX/MSYS form, unlike
# fm-ff-lib.psm1 which canonicalises to native. Three separate reasons make that
# the right call for THIS file, and picking native would have broken each one
# silently:
#
#   1. The registry is a DURABLE record and contract 3 of docs/powershell-port.md
#      keeps stored paths POSIX while the bash twins still read them. This script
#      is the one that WRITES `home:` into data/secondmates.md.
#   2. Resolve-FmSecondmateRegistryBinding's overlap pass tests ancestry with a
#      literal `key + '/'`. Handing it a native resolver would make every nested
#      -home check silently pass, which is the check that stops one secondmate's
#      teardown from taking another's unlanded work.
#   3. Every `path_is_ancestor_of` here has the same `"$ancestor"/*` shape, so
#      one spelling for all of them keeps the guards meaningful.
#
# So Resolve-SeedPath is the twin of the bash `resolved_path`/`pwd -P` pair and
# returns POSIX; anything that must reach a .NET API converts on the way in
# (fm-common's helpers do it themselves, which is most of them).
#
# ---------------------------------------------------------------------------
# THE ROLLBACK IS THE PRODUCT
# ---------------------------------------------------------------------------
# A partially seeded secondmate home is worse than no home at all: it looks
# registered, routes work, and cannot serve it. The bash arms `trap seed_rollback
# EXIT` before the first mutation and disarms it only after the registry write
# succeeds; the twin uses try/finally with the identical guard flags, so the
# rollback runs on every failure path INCLUDING an unexpected exception, and
# no-ops after commit exactly as the bash's SEED_COMMITTED check does.
#
# Nothing in the rollback deletes without proving the target safe first
# (Resolve-SeedRollbackTarget), and a treehouse-leased home is RETURNED rather
# than removed - a failed return warns loudly, because the lease may still be
# held and that is an operator's problem to see, not something to swallow.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

# --- context -----------------------------------------------------------------

$script:FmCtx = Get-FmContext $PSScriptRoot
$script:FmRoot = ConvertTo-FmPosixPath $script:FmCtx.Root
$script:FmHome = ConvertTo-FmPosixPath $script:FmCtx.Home
$script:SeedData = ConvertTo-FmPosixPath $script:FmCtx.Data
$script:SeedProjects = ConvertTo-FmPosixPath $script:FmCtx.Projects
$script:SeedReg = "$($script:SeedData)/secondmates.md"
$script:SubHomeMarker = '.fm-secondmate-home'
$script:SeedBinDir = Join-Path $script:FmCtx.Root 'bin'

# The `return 1` twin. Every refusal below has already written its diagnostic,
# so this only carries the process code out through the rollback's finally.
class FmSeedStop : System.Exception {
    [int]$Code
    FmSeedStop([int]$code) : base("fm-seed-stop:$code") { $this.Code = $code }
}

function Stop-FmSeed {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This changes no state at all: it only raises the sentinel that carries an already-reported refusal out through the rollback. The Stop- verb names what it does to the seed, not to anything on disk.')]
    [CmdletBinding()]
    param([Parameter(Position = 0)][int]$Code = 1)
    throw [FmSeedStop]::new($Code)
}

# --- small path primitives ----------------------------------------------------

# `"$a/$b"` over POSIX strings. Join-Path would introduce a native separator and
# break the '/'-anchored ancestry tests this file depends on.
function Join-FmSeedChild {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Parent,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Child
    )
    if ($Parent -eq '/' ) { return "/$Child" }
    return ($Parent.TrimEnd('/') + '/' + $Child)
}

function Test-FmSeedPathPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    $native = ConvertTo-FmNativePath $Path
    return ((Test-Path -LiteralPath $native) -or (Test-FmSymlink $native))
}

function Test-FmSeedDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return (Test-Path -LiteralPath (ConvertTo-FmNativePath $Path) -PathType Container)
}

function Test-FmSeedFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return [System.IO.File]::Exists((ConvertTo-FmNativePath $Path))
}

function New-FmSeedDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A mkdir -p twin whose bash original creates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath $Path))
        return $true
    } catch {
        return $false
    }
}

# `${p%/*}` and `${p##*/}` over either separator.
function Get-FmSeedParent {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $cut = [Math]::Max($Path.LastIndexOf('/'), $Path.LastIndexOf('\'))
    if ($cut -lt 0) { return '.' }
    if ($cut -eq 0) { return '/' }
    return $Path.Substring(0, $cut)
}

function Get-FmSeedLeaf {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)
    $cut = [Math]::Max($Path.LastIndexOf('/'), $Path.LastIndexOf('\'))
    if ($cut -lt 0) { return $Path }
    return $Path.Substring($cut + 1)
}

# Twin of normalize_joined_path: append `tail`'s components to `prefix`,
# resolving '.' and '..' textually. '..' at the root stays at the root, which is
# what the bash `[ "$out" != "/" ]` guard does.
function Join-FmSeedNormalizedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Tail
    )
    $out = $Prefix.TrimEnd('/')
    if ($out -eq '') { $out = '/' }
    foreach ($component in @($Tail -split '/')) {
        if ($component -eq '' -or $component -eq '.') { continue }
        if ($component -eq '..') {
            if ($out -ne '/') {
                $out = $out.Substring(0, [Math]::Max($out.LastIndexOf('/'), 0))
                if ($out -eq '') { $out = '/' }
            }
            continue
        }
        if ($out -eq '/') { $out = "/$component" } else { $out = "$out/$component" }
    }
    return $out
}

<#
.SYNOPSIS
The canonical POSIX path for a name that may not exist yet.
.DESCRIPTION
Twin of canonical_path_for_check, which is also `resolved_path` and
`abs_path_for_new`. An existing directory resolves through every link; an
existing non-directory resolves its parent and re-appends the leaf; a path that
does not exist yet walks up to its nearest existing ancestor, resolves THAT, and
re-joins the missing tail textually. A home about to be created therefore gets a
stable key that will still name the same place once it exists.
#>
function Resolve-FmSeedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    $probe = $Path
    if ($probe -eq '') { $probe = '.' }
    if (-not $probe.StartsWith('/') -and $probe -notmatch '^[A-Za-z]:[\\/]') {
        $probe = (Get-Location).Path.TrimEnd('\', '/') + '\' + $probe
    }
    $probe = ConvertTo-FmNativePath $probe

    $root = [System.IO.Path]::GetPathRoot($probe)
    if ([string]::IsNullOrEmpty($root)) { $root = '\' }
    while ($probe.Length -gt $root.Length -and ($probe.EndsWith('\') -or $probe.EndsWith('/'))) {
        $probe = $probe.Substring(0, $probe.Length - 1)
    }

    $resolveLeafOf = {
        param([string]$P)
        $parentPhysical = Resolve-FmPhysicalDirectory -Directory (Get-FmSeedParent -Path $P)
        if ($null -eq $parentPhysical) { return $null }
        return (Join-FmSeedChild -Parent (ConvertTo-FmPosixPath $parentPhysical) -Child (Get-FmSeedLeaf -Path $P))
    }

    if ((Test-Path -LiteralPath $probe) -or (Test-FmSymlink $probe)) {
        if (Test-Path -LiteralPath $probe -PathType Container) {
            $physical = Resolve-FmPhysicalDirectory -Directory $probe
            if ($null -ne $physical) { return (ConvertTo-FmPosixPath $physical) }
        } else {
            $leaf = & $resolveLeafOf $probe
            if ($null -ne $leaf) { return $leaf }
        }
        return (ConvertTo-FmPosixPath $probe)
    }

    $tail = ''
    while (-not ((Test-Path -LiteralPath $probe) -or (Test-FmSymlink $probe)) -and
        $probe.TrimEnd('\', '/') -ne $root.TrimEnd('\', '/')) {
        $leafName = Get-FmSeedLeaf -Path $probe
        $tail = if ($tail -eq '') { $leafName } else { "$leafName/$tail" }
        $next = Get-FmSeedParent -Path $probe
        if ($next -ceq $probe) { break }
        $probe = $next
    }

    $prefix = ''
    if (Test-Path -LiteralPath $probe -PathType Container) {
        $physical = Resolve-FmPhysicalDirectory -Directory $probe
        $prefix = if ($null -ne $physical) { ConvertTo-FmPosixPath $physical } else { ConvertTo-FmPosixPath $probe }
    } elseif ((Test-Path -LiteralPath $probe) -or (Test-FmSymlink $probe)) {
        $leaf = & $resolveLeafOf $probe
        $prefix = if ($null -ne $leaf) { $leaf } else { ConvertTo-FmPosixPath $probe }
    } else {
        $prefix = ConvertTo-FmPosixPath $probe
    }
    return (Join-FmSeedNormalizedPath -Prefix $prefix -Tail $tail)
}

# Twin of path_is_ancestor_of: non-empty, different, and Path begins with
# Ancestor plus a separator. Equality is deliberately NOT ancestry - callers
# test the two conditions separately with different messages.
function Test-FmSeedPathIsAncestor {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Ancestor,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][AllowNull()][string]$Path
    )
    if ([string]::IsNullOrEmpty($Ancestor)) { return $false }
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Ancestor -ceq $Path) { return $false }
    return $Path.StartsWith($Ancestor.TrimEnd('/') + '/', [System.StringComparison]::Ordinal)
}

# --- registry text ------------------------------------------------------------

<#
.SYNOPSIS
Flatten free text into one registry-safe single-line summary.
.DESCRIPTION
Twin of normalize_registry_text. The registry record's field boundaries are
`;` and `)`, so those are replaced by spaces rather than escaped: an escaped
delimiter would still have to be un-escaped by every reader, and the record
format has several (bin/fm-secondmate-registry-lib). Whitespace runs collapse to
one space, each line is trimmed, and the surviving lines are joined by a single
space - so a multi-line charter section becomes one sentence-like summary.
#>
function ConvertTo-FmSeedRegistryText {
    [CmdletBinding()]
    [OutputType([string])]
    # [object], not [string[]]: a section whose lines include an EMPTY one - the
    # blank line that ends nearly every markdown section - fails to bind to a
    # [string[]] parameter with "Cannot bind argument to parameter 'Line'
    # because it is an empty string", and AllowEmptyCollection does not cover
    # an empty ELEMENT. Found live: it aborted the seed on the very first
    # well-formed charter brief. @($Line) below normalizes $null, a bare string
    # and an array to one shape.
    param([Parameter(Position = 0)][AllowNull()][object]$Line)

    $out = ''
    foreach ($raw in @($Line)) {
        if ($null -eq $raw) { continue }
        $text = $raw -creplace '[;()]', ' '
        $text = $text -creplace '[ \t\v\f\r]+', ' '
        # sub(/^ /,"") and sub(/ $/,"") remove ONE space each, not a run - the
        # collapse above already guarantees at most one.
        if ($text.StartsWith(' ')) { $text = $text.Substring(1) }
        if ($text.EndsWith(' ')) { $text = $text.Substring(0, $text.Length - 1) }
        if ($text -eq '') { continue }
        $out = if ($out -eq '') { $text } else { "$out $text" }
    }
    return $out
}

# Twin of brief_section_text: the lines under `# <heading>` up to the next
# top-level heading. The heading match is EXACT, not a prefix, so `# Charter`
# does not also select `# Charter notes`.
function Get-FmSeedBriefSection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Brief,
        [Parameter(Mandatory, Position = 1)][string]$Heading
    )
    $want = "# $Heading"
    $out = [System.Collections.Generic.List[string]]::new()
    $inSection = $false
    foreach ($line in (Get-FmFileLines $Brief)) {
        if ($line -ceq $want) { $inSection = $true; continue }
        if ($inSection -and $line.StartsWith('# ')) { break }
        if ($inSection) { $out.Add($line) }
    }
    return @($out)
}

function Get-FmSeedRegistrySummary {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Brief)
    $charter = Get-FmEnv -Name 'FM_SECONDMATE_CHARTER'
    if ($charter -ne '') {
        return (ConvertTo-FmSeedRegistryText -Line @($charter -split "`r?`n"))
    }
    return (ConvertTo-FmSeedRegistryText -Line (Get-FmSeedBriefSection -Brief $Brief -Heading 'Charter'))
}

function Get-FmSeedRegistryScope {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Brief)
    $scope = Get-FmEnv -Name 'FM_SECONDMATE_SCOPE'
    if ($scope -ne '') {
        return (ConvertTo-FmSeedRegistryText -Line @($scope -split "`r?`n"))
    }
    return (ConvertTo-FmSeedRegistryText -Line (Get-FmSeedBriefSection -Brief $Brief -Heading 'Routing scope'))
}

# Twin of validate_registry_home_text: a home carrying a record delimiter would
# tear the generated record apart at parse time, so it is refused at write time.
function Test-FmSeedRegistryHomeText {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)
    if ($HomePath.Contains(';') -or $HomePath.Contains(')') -or $HomePath.Contains("`n")) {
        Write-FmErr "error: secondmate home path contains registry delimiters: $HomePath"
        return $false
    }
    return $true
}

function Join-FmSeedProjectList {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Project)
    return (@($Project) -join ', ')
}

# --- registry conflicts -------------------------------------------------------

# Twin of registry_home_conflict_for_assignment. Returns an object with Kind
# ('exact' or 'overlap'), Owner and RegisteredKey, or $null for no conflict.
# A malformed entry reports and yields $null, exactly as the bash's
# `conflict=$(... || true)` swallows the non-zero return.
function Get-FmSeedRegistryHomeConflict {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$HomePath
    )
    if (-not (Test-FmSeedFile -Path $script:SeedReg)) { return $null }
    $target = Resolve-FmSeedPath -Path $HomePath
    foreach ($line in (Get-FmFileLines $script:SeedReg)) {
        if (-not $line.StartsWith('- ')) { continue }
        $record = ConvertFrom-FmSecondmateRegistryLine -Line $line
        if ($null -eq $record) {
            Write-FmErr "error: malformed secondmate registry entry: $line"
            return $null
        }
        $registeredKey = Resolve-FmSeedPath -Path $record.Home
        if ($registeredKey -ceq $target) {
            if ($record.Id -ceq $Id) { continue }
            return [pscustomobject]@{ Kind = 'exact'; Owner = $record.Id; RegisteredKey = $registeredKey }
        }
        if ((Test-FmSeedPathIsAncestor -Ancestor $registeredKey -Path $target) -or
            (Test-FmSeedPathIsAncestor -Ancestor $target -Path $registeredKey)) {
            return [pscustomobject]@{ Kind = 'overlap'; Owner = $record.Id; RegisteredKey = $registeredKey }
        }
    }
    return $null
}

# Twin of registry_id_conflict_for_assignment: the OTHER home this id is already
# bound to, or $null. An id bound twice would make routing ambiguous, so the
# assignment is refused rather than silently rebound.
function Get-FmSeedRegistryIdConflict {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$HomePath
    )
    if (-not (Test-FmSeedFile -Path $script:SeedReg)) { return $null }
    $target = Resolve-FmSeedPath -Path $HomePath
    foreach ($line in (Get-FmFileLines $script:SeedReg)) {
        if (-not $line.StartsWith('- ')) { continue }
        $record = ConvertFrom-FmSecondmateRegistryLine -Line $line
        if ($null -eq $record) {
            Write-FmErr "error: malformed secondmate registry entry: $line"
            return $null
        }
        if ($record.Id -cne $Id) { continue }
        $registeredKey = Resolve-FmSeedPath -Path $record.Home
        if ($registeredKey -ceq $target) { continue }
        return $registeredKey
    }
    return $null
}

# Twin of validate_registry. An absent registry is valid (no secondmates yet);
# a registry that EXISTS AS A LINK is not, and the library refuses it.
function Test-FmSeedRegistry {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-FmSeedPathPresent -Path $script:SeedReg)) { return $true }
    $result = Resolve-FmSecondmateRegistryBinding -Registry $script:SeedReg `
        -Resolver { param($p) Resolve-FmSeedPath -Path $p }
    if ($result.Ok) { return $true }
    Write-FmErr "error: $($result.Error)"
    return $false
}

# --- home safety --------------------------------------------------------------

# Twin of refuse_active_home_path. Order is load-bearing: an exact match is
# reported as an exact match before any containment check can describe it as
# containment.
function Test-FmSeedActiveHomePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)

    $absHome = Resolve-FmSeedPath -Path $HomePath
    $absActiveHome = Resolve-FmSeedPath -Path $script:FmHome
    $absRoot = Resolve-FmSeedPath -Path $script:FmRoot

    # `[ "$abs_home" = "/" ]`. A Windows drive root is the same hazard: every
    # path on the volume sits below it.
    if ($absHome -ceq '/' -or $absHome -match '^/[A-Za-z]/?$') {
        Write-FmErr "error: secondmate home cannot be the filesystem root: $HomePath"
        return $false
    }
    if ($absHome -ceq $absActiveHome) {
        Write-FmErr "error: secondmate home cannot be the active firstmate home: $HomePath"
        return $false
    }
    if ($absHome -ceq $absRoot) {
        Write-FmErr "error: secondmate home cannot be the firstmate repo: $HomePath"
        return $false
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absActiveHome -Path $absHome) {
        Write-FmErr "error: secondmate home cannot be inside the active firstmate home: $HomePath"
        return $false
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absRoot -Path $absHome) {
        Write-FmErr "error: secondmate home cannot be inside the firstmate repo: $HomePath"
        return $false
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absActiveHome) {
        Write-FmErr "error: secondmate home cannot be an ancestor of the active firstmate home: $HomePath"
        return $false
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absRoot) {
        Write-FmErr "error: secondmate home cannot be an ancestor of the firstmate repo: $HomePath"
        return $false
    }
    return $true
}

function Test-FmSeedOperationalDirectory {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$HomePath,
        [Parameter(Position = 1)][string]$Name
    )
    # The twin of validate_operational_dirs' loop: with no -Name every one of the
    # four is checked, which is how both callers use it.
    if (-not $PSBoundParameters.ContainsKey('Name') -or [string]::IsNullOrEmpty($Name)) {
        foreach ($each in @('data', 'state', 'config', 'projects')) {
            if (-not (Test-FmSeedOperationalDirectory -HomePath $HomePath -Name $each)) { return $false }
        }
        return $true
    }
    $dir = Join-FmSeedChild -Parent $HomePath -Child $Name
    # A DANGLING link is refused first and by name: `-e` follows links, so a
    # link pointing nowhere would otherwise read as "not created yet".
    if ((Test-FmSymlink (ConvertTo-FmNativePath $dir)) -and
        -not (Test-Path -LiteralPath (ConvertTo-FmNativePath $dir))) {
        Write-FmErr "error: secondmate $Name directory must resolve inside the secondmate home: $dir"
        return $false
    }
    $absHome = Resolve-FmSeedPath -Path $HomePath
    $absDir = Resolve-FmSeedPath -Path $dir
    $absActiveHome = Resolve-FmSeedPath -Path $script:FmHome
    $absRoot = Resolve-FmSeedPath -Path $script:FmRoot
    if (-not (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absDir)) {
        Write-FmErr "error: secondmate $Name directory must resolve inside the secondmate home: $dir"
        return $false
    }
    if (($absDir -ceq $absActiveHome) -or (Test-FmSeedPathIsAncestor -Ancestor $absActiveHome -Path $absDir)) {
        Write-FmErr "error: secondmate $Name directory cannot be inside the active firstmate home: $dir"
        return $false
    }
    if (($absDir -ceq $absRoot) -or (Test-FmSeedPathIsAncestor -Ancestor $absRoot -Path $absDir)) {
        Write-FmErr "error: secondmate $Name directory cannot be inside the firstmate repo: $dir"
        return $false
    }
    return $true
}

# Twin of validate_seed_leaf_files: the three files the seed WRITES must be
# real files inside the home, never links that would redirect the write.
function Test-FmSeedLeafFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)
    $absHome = Resolve-FmSeedPath -Path $HomePath
    foreach ($label in @('data/projects.md', 'data/charter.md', $script:SubHomeMarker)) {
        $path = Join-FmSeedChild -Parent $HomePath -Child $label
        if (Test-FmSymlink (ConvertTo-FmNativePath $path)) {
            Write-FmErr "error: secondmate leaf file must not be a symlink: $path"
            return $false
        }
        if (-not (Test-FmSeedPathPresent -Path $path)) { continue }
        $absPath = Resolve-FmSeedPath -Path $path
        if (-not (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absPath)) {
            Write-FmErr "error: secondmate leaf file must resolve inside the secondmate home: $path"
            return $false
        }
    }
    return $true
}

# Twin of validate_project_destination: returns the resolved destination, or
# $null after reporting which boundary the clone would have crossed.
function Resolve-FmSeedProjectDestination {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$HomePath,
        [Parameter(Mandatory, Position = 1)][string]$Project
    )
    $projectsDir = Join-FmSeedChild -Parent $HomePath -Child 'projects'
    $dst = Join-FmSeedChild -Parent $projectsDir -Child $Project
    $absHome = Resolve-FmSeedPath -Path $HomePath
    $absProjects = Resolve-FmSeedPath -Path $projectsDir
    $absDst = Resolve-FmSeedPath -Path $dst
    $absActiveHome = Resolve-FmSeedPath -Path $script:FmHome
    $absRoot = Resolve-FmSeedPath -Path $script:FmRoot

    if (-not (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absProjects)) {
        Write-FmErr ('error: secondmate projects directory must resolve inside the secondmate home: ' + $projectsDir)
        return $null
    }
    if (-not (Test-FmSeedPathIsAncestor -Ancestor $absProjects -Path $absDst)) {
        Write-FmErr ("error: seeded project $Project destination must resolve inside the secondmate projects directory: $dst")
        return $null
    }
    if (($absDst -ceq $absActiveHome) -or (Test-FmSeedPathIsAncestor -Ancestor $absActiveHome -Path $absDst)) {
        Write-FmErr "error: seeded project $Project destination cannot be inside the active firstmate home: $dst"
        return $null
    }
    if (($absDst -ceq $absRoot) -or (Test-FmSeedPathIsAncestor -Ancestor $absRoot -Path $absDst)) {
        Write-FmErr "error: seeded project $Project destination cannot be inside the firstmate repo: $dst"
        return $null
    }
    return $absDst
}

# --- git / origin -------------------------------------------------------------

function Invoke-FmSeedGit {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string[]]$Argument
    )
    return (Invoke-FmTool -FilePath 'git' -Arguments (@('-C', (ConvertTo-FmNativePath $Directory)) + $Argument))
}

# Twin of normalize_origin_url: a URL stays a URL, an scp-style host:path stays
# as it is, and anything else is a LOCAL path that must be canonicalised
# relative to the repo that reported it - otherwise a relative origin would be
# re-resolved against the secondmate home and point at nothing.
function ConvertTo-FmSeedOriginUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Repo,
        [Parameter(Mandatory, Position = 1)][string]$Url
    )
    if ($Url.StartsWith('file://') -or $Url -match '://') { return $Url }
    $colon = $Url.IndexOf(':')
    if ($colon -ge 0) {
        $prefix = $Url.Substring(0, $colon)
        # `case "$prefix" in */*) ;; *) return the url ;; esac` - a colon with no
        # slash before it is an scp-style remote, not a path.
        if (-not $prefix.Contains('/')) { return $Url }
    }
    $saved = (Get-Location).Path
    try {
        Set-Location -LiteralPath (ConvertTo-FmNativePath $Repo)
        return (Resolve-FmSeedPath -Path $Url)
    } finally {
        Set-Location -LiteralPath $saved
    }
}

function Get-FmSeedSourceOriginUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Project,
        [Parameter(Mandatory, Position = 1)][string]$Mode,
        [Parameter(Mandatory, Position = 2)][string]$Source
    )
    $result = Invoke-FmSeedGit -Directory $Source -Argument @('remote', 'get-url', 'origin')
    $url = if ($result.Ok) { $result.StdOut.TrimEnd("`n") } else { '' }
    if ($url -eq '') {
        Write-FmErr "error: project $Project is $Mode but has no origin remote"
        return $null
    }
    return (ConvertTo-FmSeedOriginUrl -Repo $Source -Url $url)
}

function Get-FmSeedSeededOriginUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Project,
        [Parameter(Mandatory, Position = 1)][string]$Destination,
        [Parameter(Mandatory, Position = 2)][string]$Expected
    )
    $result = Invoke-FmSeedGit -Directory $Destination -Argument @('remote', 'get-url', 'origin')
    $url = if ($result.Ok) { $result.StdOut.TrimEnd("`n") } else { '' }
    if ($url -eq '') {
        Write-FmErr "error: seeded project $Project at $Destination has no origin remote; expected $Expected"
        return $null
    }
    return (ConvertTo-FmSeedOriginUrl -Repo $Destination -Url $url)
}

function Test-FmSeedInsideWorkTree {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)
    return (Invoke-FmSeedGit -Directory $Directory -Argument @('rev-parse', '--is-inside-work-tree')).Ok
}

# --- home acquisition ---------------------------------------------------------

<#
.SYNOPSIS
Durably lease a firstmate worktree from the treehouse pool.
.DESCRIPTION
Twin of acquire_treehouse_home. The lease persists with no live process and is
skipped by later get/prune, so the home survives restarts until teardown or
rollback returns it. treehouse prints only the worktree path to stdout (banners
go to stderr), which is why stderr is forwarded rather than captured into the
result.
#>
function New-FmSeedTreehouseHome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin leases unconditionally as part of a non-interactive seed; a confirmation surface would stall it and diverge from the twin.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Id)

    $result = Invoke-FmTool -FilePath 'treehouse' `
        -Arguments @('get', '--lease', '--lease-holder', $Id) `
        -WorkingDirectory $script:FmRoot
    if ($result.StdErr -ne '') { Write-FmRaw $result.StdErr }
    if (-not $result.Ok) {
        Write-FmErr 'error: treehouse get --lease failed to lease a firstmate home'
        return $null
    }
    $seedHomePath = $result.StdOut.TrimEnd("`n")
    if ($seedHomePath -eq '') {
        Write-FmErr 'error: treehouse get --lease did not report a firstmate home'
        return $null
    }
    return $seedHomePath
}

# Twin of verify_firstmate_home: returns the resolved home, or $null.
function Confirm-FmSeedFirstmateHome {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$HomePath)
    if (-not (Test-FmSeedActiveHomePath -HomePath $HomePath)) { return $null }
    if (-not (Test-FmSeedFile -Path (Join-FmSeedChild -Parent $HomePath -Child 'AGENTS.md'))) {
        Write-FmErr "error: $HomePath is not a firstmate home (missing AGENTS.md)"
        return $null
    }
    if (-not (Test-FmSeedDirectory -Path (Join-FmSeedChild -Parent $HomePath -Child 'bin'))) {
        Write-FmErr "error: $HomePath is not a firstmate home (missing bin/)"
        return $null
    }
    if (-not (Test-FmSeedOperationalDirectory -HomePath $HomePath)) { return $null }
    return (Resolve-FmSeedPath -Path $HomePath)
}

# Twin of ensure_home. Cloning is the only creation path: an EXISTING path must
# already be a directory, and is never replaced.
function Initialize-FmSeedHome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin clones unconditionally inside a transactional seed whose rollback owns the undo; a confirmation surface would stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$Requested
    )
    if ($Requested -ceq '-') {
        $seedHomePath = New-FmSeedTreehouseHome -Id $Id
        if ($null -eq $seedHomePath) { Stop-FmSeed 1 }
        return (Confirm-FmSeedFirstmateHome -HomePath $seedHomePath)
    }

    $seedHomePath = Resolve-FmSeedPath -Path $Requested
    if (-not (Test-FmSeedActiveHomePath -HomePath $seedHomePath)) { return $null }
    if (Test-FmSeedPathPresent -Path $seedHomePath) {
        if (-not (Test-FmSeedDirectory -Path $seedHomePath)) {
            Write-FmErr "error: $seedHomePath exists and is not a directory"
            return $null
        }
    } else {
        [void](New-FmSeedDirectory -Path (Get-FmSeedParent -Path $seedHomePath))
        $clone = Invoke-FmTool -FilePath 'git' -Arguments @(
            'clone', '--quiet', (ConvertTo-FmNativePath $script:FmRoot), (ConvertTo-FmNativePath $seedHomePath))
        if ($clone.StdErr -ne '') { Write-FmRaw $clone.StdErr }
        if ($clone.StdOut -ne '') { Write-FmRaw $clone.StdOut }
        # `set -e` propagates git's own status; the same code is carried here so
        # a caller distinguishing a clone failure from a validation refusal
        # still can.
        if (-not $clone.Ok) { Stop-FmSeed $clone.ExitCode }
    }
    return (Confirm-FmSeedFirstmateHome -HomePath $seedHomePath)
}

# Twin of validate_home_assignment: the marker, then the id binding, then the
# home binding, each refusing rather than rebinding.
function Test-FmSeedHomeAssignment {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$HomePath
    )
    $marker = Join-FmSeedChild -Parent $HomePath -Child $script:SubHomeMarker
    if (Test-FmSeedFile -Path $marker) {
        $markerId = (Get-FmFileText $marker).TrimEnd("`n")
        if ($markerId -cne $Id) {
            $shown = if ($markerId -eq '') { 'unknown' } else { $markerId }
            Write-FmErr "error: secondmate home $HomePath is already marked for $shown"
            return $false
        }
    }
    $idConflict = Get-FmSeedRegistryIdConflict -Id $Id -HomePath $HomePath
    if (-not [string]::IsNullOrEmpty($idConflict)) {
        Write-FmErr ("error: secondmate id $Id is already registered to home $idConflict; " +
            "retire it before assigning $HomePath")
        return $false
    }
    $conflict = Get-FmSeedRegistryHomeConflict -Id $Id -HomePath $HomePath
    if ($null -eq $conflict) { return $true }
    if ($conflict.Kind -ceq 'exact') {
        Write-FmErr "error: secondmate home $HomePath is already registered to $($conflict.Owner)"
        return $false
    }
    Write-FmErr ("error: secondmate home $HomePath overlaps registered secondmate home " +
        "$($conflict.RegisteredKey) for $($conflict.Owner)")
    return $false
}

# --- projects -----------------------------------------------------------------

function Get-FmSeedProjectMode {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Project,
        [Parameter(Mandatory, Position = 1)][hashtable]$EnvironmentOverride
    )
    $saved = @{}
    foreach ($name in $EnvironmentOverride.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        foreach ($name in $EnvironmentOverride.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$EnvironmentOverride[$name])
        }
        $result = Invoke-FmScript -Name 'fm-project-mode' -Arguments @($Project) -BinDir $script:SeedBinDir
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                [Environment]::SetEnvironmentVariable($name, $null)
            } else {
                [Environment]::SetEnvironmentVariable($name, $saved[$name])
            }
        }
    }
    # `read -r mode _`: the first whitespace-delimited word of the FIRST line.
    $firstLine = @(($result.StdOut -replace "`r", '') -split "`n")[0]
    $fields = @($firstLine -split '[ \t]+') | Where-Object { $_ -ne '' }
    if (@($fields).Count -eq 0) { return '' }
    return @($fields)[0]
}

# Twin of clone_project. An EXISTING destination is never replaced: its origin
# must already match the source's, or the seed refuses rather than reconciling.
function Copy-FmSeedProject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin clones unconditionally inside a transactional seed whose rollback owns the undo; a confirmation surface would stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Project,
        [Parameter(Mandatory, Position = 1)][string]$HomePath
    )
    $src = Join-FmSeedChild -Parent $script:SeedProjects -Child $Project
    $dst = Resolve-FmSeedProjectDestination -HomePath $HomePath -Project $Project
    if ($null -eq $dst) { return $false }
    if (-not (Test-FmSeedDirectory -Path $src)) {
        Write-FmErr "error: project $Project not found at $src"
        return $false
    }
    if (-not (Test-FmSeedInsideWorkTree -Directory $src)) {
        Write-FmErr "error: project $Project is not a git repo"
        return $false
    }
    $mode = Get-FmSeedProjectMode -Project $Project -EnvironmentOverride @{
        FM_HOME = $script:FmHome; FM_DATA_OVERRIDE = $script:SeedData
    }
    if ($mode -ceq 'local-only') {
        Write-FmErr ("error: project $Project is local-only; secondmate routes support only " +
            'no-mistakes and direct-PR projects')
        return $false
    }
    if (Test-FmSeedPathPresent -Path $dst) {
        if (-not (Test-FmSeedDirectory -Path $dst)) {
            Write-FmErr "error: seeded project $Project exists at $dst but is not a directory"
            return $false
        }
        if (-not (Test-FmSeedInsideWorkTree -Directory $dst)) {
            Write-FmErr "error: seeded project $Project at $dst is not a git repo"
            return $false
        }
        $url = Get-FmSeedSourceOriginUrl -Project $Project -Mode $mode -Source $src
        if ($null -eq $url) { return $false }
        $dstUrl = Get-FmSeedSeededOriginUrl -Project $Project -Destination $dst -Expected $url
        if ($null -eq $dstUrl) { return $false }
        if ($dstUrl -cne $url) {
            Write-FmErr "error: seeded project $Project at $dst has origin $dstUrl; expected $url"
            return $false
        }
        return $true
    }
    $url = Get-FmSeedSourceOriginUrl -Project $Project -Mode $mode -Source $src
    if ($null -eq $url) { return $false }
    $clone = Invoke-FmTool -FilePath 'git' -Arguments @(
        'clone', '--quiet', $url, (ConvertTo-FmNativePath $dst))
    if ($clone.StdErr -ne '') { Write-FmRaw $clone.StdErr }
    if ($clone.StdOut -ne '') { Write-FmRaw $clone.StdOut }
    if (-not $clone.Ok) { Stop-FmSeed $clone.ExitCode }
    return $true
}

# Twin of validate_seed_project: the pre-flight run BEFORE any mutation, so an
# unusable project list refuses before a home is created or leased.
function Test-FmSeedProject {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Project)
    $src = Join-FmSeedChild -Parent $script:SeedProjects -Child $Project
    if (-not (Test-FmSeedDirectory -Path $src)) {
        Write-FmErr "error: project $Project not found at $src"
        return $false
    }
    if (-not (Test-FmSeedInsideWorkTree -Directory $src)) {
        Write-FmErr "error: project $Project is not a git repo"
        return $false
    }
    $mode = Get-FmSeedProjectMode -Project $Project -EnvironmentOverride @{
        FM_HOME = $script:FmHome; FM_DATA_OVERRIDE = $script:SeedData
    }
    if ($mode -ceq 'local-only') {
        Write-FmErr ("error: project $Project is local-only; secondmate routes support only " +
            'no-mistakes and direct-PR projects')
        return $false
    }
    $result = Invoke-FmSeedGit -Directory $src -Argument @('remote', 'get-url', 'origin')
    $url = if ($result.Ok) { $result.StdOut.TrimEnd("`n") } else { '' }
    if ($url -eq '') {
        Write-FmErr "error: project $Project is $mode but has no origin remote"
        return $false
    }
    return $true
}

# Twin of registry_line_for_project: the parent registry's own line for a
# project, so a seeded home inherits the parent's description and delivery mode
# rather than a generated placeholder.
function Get-FmSeedProjectRegistryLine {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Project)
    $registry = Join-FmSeedChild -Parent $script:SeedData -Child 'projects.md'
    if (-not (Test-FmSeedFile -Path $registry)) { return $null }
    foreach ($line in (Get-FmFileLines $registry)) {
        $fields = @($line -split '[ \t]+') | Where-Object { $_ -ne '' }
        if (@($fields).Count -lt 2) { continue }
        if (@($fields)[0] -ceq '-' -and @($fields)[1] -ceq $Project) { return $line }
    }
    return $null
}

# Twin of sync_project_registry: rewrite the secondmate's project registry so
# the selected projects appear exactly once, preserving every other line.
function Sync-FmSeedProjectRegistry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin rewrites the registry unconditionally inside a transactional seed; a confirmation surface would stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$HomePath,
        [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][string[]]$Project
    )
    $subReg = Join-FmSeedChild -Parent (Join-FmSeedChild -Parent $HomePath -Child 'data') -Child 'projects.md'
    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($p in @($Project)) { [void]$selected.Add($p) }

    $kept = [System.Collections.Generic.List[string]]::new()
    if (Test-FmSeedFile -Path $subReg) {
        foreach ($line in (Get-FmFileLines $subReg)) {
            $fields = @($line -split '[ \t]+') | Where-Object { $_ -ne '' }
            if (@($fields).Count -ge 2 -and @($fields)[0] -ceq '-' -and $selected.Contains(@($fields)[1])) {
                continue
            }
            $kept.Add($line)
        }
    }
    $today = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    foreach ($p in @($Project)) {
        $line = Get-FmSeedProjectRegistryLine -Project $p
        if ([string]::IsNullOrEmpty($line)) { $line = "- $p - cloned project (added $today)" }
        $kept.Add($line)
    }
    $text = if ($kept.Count -eq 0) { '' } else { (($kept -join "`n") + "`n") }
    return (Set-FmFileTextAtomic -Path $subReg -Text $text -NoNewline)
}

# Twin of initialize_no_mistakes_project. A PREEXISTING clone that is not
# initialized is refused rather than mutated: it is not this seed's to change.
function Initialize-FmSeedNoMistakesProject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin initializes unconditionally inside a transactional seed whose rollback owns the undo; a confirmation surface would stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$HomePath,
        [Parameter(Mandatory, Position = 1)][string]$Project,
        [Parameter(Mandatory, Position = 2)][bool]$Created
    )
    $mode = Get-FmSeedProjectMode -Project $Project -EnvironmentOverride @{
        FM_ROOT_OVERRIDE = ''; FM_STATE_OVERRIDE = ''; FM_DATA_OVERRIDE = ''
        FM_PROJECTS_OVERRIDE = ''; FM_CONFIG_OVERRIDE = ''; FM_HOME = $HomePath
    }
    if ($mode -cne 'no-mistakes') { return $true }
    $dst = Resolve-FmSeedProjectDestination -HomePath $HomePath -Project $Project
    if ($null -eq $dst) { return $false }
    if ((Invoke-FmSeedGit -Directory $dst -Argument @('remote', 'get-url', 'no-mistakes')).Ok) {
        return $true
    }
    if (-not $Created) {
        Write-FmErr ("error: seeded project $Project at $dst is not initialized for no-mistakes; " +
            'refusing to mutate preexisting clone')
        return $false
    }
    if (-not (Test-FmCommand 'no-mistakes')) {
        Write-FmErr "error: no-mistakes command not found; cannot initialize $Project in $HomePath"
        return $false
    }
    foreach ($verb in @('init', 'doctor')) {
        $run = Invoke-FmTool -FilePath 'no-mistakes' -Arguments @($verb) -WorkingDirectory $dst
        if ($run.StdOut -ne '') { Write-FmRaw $run.StdOut }
        if ($run.StdErr -ne '') { Write-FmRaw $run.StdErr }
        if (-not $run.Ok) {
            Write-FmErr "error: failed to initialize no-mistakes for $Project at $dst"
            return $false
        }
    }
    return $true
}

# Twin of write_registry.
#
# One deliberate, narrow divergence: the bash drops the id's old line with
# `grep -vE "^- $id( |$)"`, interpolating an UNESCAPED id into an ERE, so an id
# containing a regex metacharacter (`.` is legal in an id) would also drop
# unrelated lines. This matches the same shape literally instead. Where the two
# differ, this twin removes FEWER lines, and the difference is caught rather
# than silent: Test-FmSeedRegistry runs immediately after the write, and a
# surviving duplicate id fails it.
function Write-FmSeedRegistry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes the registry unconditionally inside a transactional seed whose rollback restores it; a confirmation surface would stall a non-interactive seed.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$HomePath,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][string]$ProjectsCsv,
        [Parameter(Mandatory, Position = 3)][string]$Brief
    )
    if (-not (New-FmSeedDirectory -Path $script:SeedData)) { return $false }
    $scope = Get-FmSeedRegistryScope -Brief $Brief
    $summary = Get-FmSeedRegistrySummary -Brief $Brief
    $today = [DateTime]::Now.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

    $kept = [System.Collections.Generic.List[string]]::new()
    if (Test-FmSeedFile -Path $script:SeedReg) {
        $exact = "- $Id"
        $prefix = "- $Id "
        foreach ($line in (Get-FmFileLines $script:SeedReg)) {
            if ($line -ceq $exact -or $line.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }
            $kept.Add($line)
        }
    }
    $kept.Add("- $Id - $summary (home: $HomePath; scope: $scope; projects: $ProjectsCsv; added $today)")
    return (Set-FmFileTextAtomic -Path $script:SeedReg -Text (($kept -join "`n") + "`n") -NoNewline)
}

# Twin of refuse_populated_projectless_home: a --no-projects seed never converts
# a home that already holds project data, because that data would then belong to
# a domain declared project-less.
function Test-FmSeedProjectlessHome {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)

    $projectsDir = Join-FmSeedChild -Parent $HomePath -Child 'projects'
    $projectsNative = ConvertTo-FmNativePath $projectsDir
    if (Test-FmSymlink $projectsNative) {
        Write-FmErr ("error: cannot inspect existing projects directory at $projectsDir because it is a " +
            'symlink; resolve the symlink or retire or clean this home before seeding with --no-projects')
        return $false
    }
    if ((Test-Path -LiteralPath $projectsNative) -and -not (Test-FmSeedDirectory -Path $projectsDir)) {
        Write-FmErr ("error: cannot inspect existing projects directory at $projectsDir because it is not " +
            'a directory; resolve its path or retire or clean this home before seeding with --no-projects')
        return $false
    }

    # The bash expands three globs (`*`, `.[!.]*`, `..?*`) to reach dotfiles too;
    # one enumeration covers all three, and its FAILURE is the `find -P` probe.
    $clones = [System.Collections.Generic.List[string]]::new()
    if (Test-FmSeedDirectory -Path $projectsDir) {
        try {
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($projectsNative)) {
                $clones.Add([System.IO.Path]::GetFileName($entry))
            }
        } catch {
            Write-FmErr ("error: cannot inspect existing projects directory at $projectsDir; resolve its " +
                'access permissions or retire or clean this home before seeding with --no-projects')
            return $false
        }
    }

    $registryProjects = [System.Collections.Generic.List[string]]::new()
    $subReg = Join-FmSeedChild -Parent (Join-FmSeedChild -Parent $HomePath -Child 'data') -Child 'projects.md'
    if (Test-FmSeedFile -Path $subReg) {
        try {
            foreach ($line in (Get-FmFileLines $subReg)) {
                $fields = @($line -split '[ \t]+') | Where-Object { $_ -ne '' }
                if (@($fields).Count -ge 2 -and @($fields)[0] -ceq '-' -and @($fields)[1] -ne '') {
                    $registryProjects.Add(@($fields)[1])
                }
            }
        } catch {
            Write-FmErr ("error: cannot inspect existing project registry at $subReg; resolve its access " +
                'permissions or retire or clean this home before seeding with --no-projects')
            return $false
        }
    }

    if ($clones.Count -eq 0 -and $registryProjects.Count -eq 0) { return $true }

    Write-FmErr "error: cannot seed project-less secondmate home $HomePath because it contains project data"
    if ($clones.Count -gt 0) {
        Write-FmErr "error: projects/ entries: $(Join-FmSeedProjectList -Project @($clones))"
    }
    if ($registryProjects.Count -gt 0) {
        Write-FmErr "error: data/projects.md entries: $(Join-FmSeedProjectList -Project @($registryProjects))"
    }
    Write-FmErr 'error: retire or clean this home first before seeding with --no-projects'
    return $false
}

# Twin of refuse_projectful_projectless_charter: an existing charter that
# describes project clones contradicts --no-projects, and the conflict is
# reported rather than resolved by guessing which the operator meant.
function Test-FmSeedProjectlessCharter {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$Brief
    )
    $section = @(Get-FmSeedBriefSection -Brief $Brief -Heading 'Project clones')
    $hasNoneMarker = $false
    $hasBullet = $false
    foreach ($line in $section) {
        if ($line.Contains('None. This is a project-less domain')) { $hasNoneMarker = $true }
        if ($line -cmatch '^[ \t\v\f\r]*-[ \t\v\f\r]+') { $hasBullet = $true }
    }
    if ($hasNoneMarker -and -not $hasBullet) { return $true }
    Write-FmErr ('error: cannot seed project-less secondmate home because existing charter brief at ' +
        "$Brief conflicts with --no-projects")
    Write-FmErr ("error: re-scaffold it with fm-brief.sh $Id --secondmate --no-projects or remove the " +
        'stale brief before seeding')
    return $false
}

# --- rollback -----------------------------------------------------------------

$script:SeedRollbackActive = $false
$script:SeedCommitted = $false
$script:SeedHome = ''
$script:SeedHomeAcquired = $false
$script:SeedHomeCreated = $false
$script:SeedHomeBackedUp = $false
$script:SeedBackupDir = ''
$script:SeedCreatedProjectsFile = ''
$script:SeedParentRegExisted = $false
$script:SeedParentBrief = ''
$script:SeedParentBriefCreated = $false
$script:SeedParentBriefDirCreated = $false
$script:SeedSubRegExisted = $false
$script:SeedCharterExisted = $false
$script:SeedMarkerExisted = $false

function Restore-FmSeedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][bool]$Existed,
        [Parameter(Mandatory, Position = 1)][string]$Backup,
        [Parameter(Mandatory, Position = 2)][string]$Path
    )
    if ($Existed) {
        [void](New-FmSeedDirectory -Path (Get-FmSeedParent -Path $Path))
        try {
            [System.IO.File]::Copy((ConvertTo-FmNativePath $Backup), (ConvertTo-FmNativePath $Path), $true)
        } catch {
            # `cp ... 2>/dev/null || true`: a rollback that cannot restore one
            # file must still restore the rest.
            Write-Verbose "could not restore $Path during rollback: $($_.Exception.Message)"
        }
    } else {
        try { Remove-Item -LiteralPath (ConvertTo-FmNativePath $Path) -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
}

<#
.SYNOPSIS
The resolved rollback target, or $null after refusing an unsafe one.
.DESCRIPTION
Twin of seed_rollback_target. Nothing in the rollback removes or returns a path
until this has proved it is neither the active home nor the firstmate repo, and
neither contains nor is contained by either. A REFUSED target is loud and the
rollback continues with the rest, because a refusal here means the seed built
something in a place the rollback must not touch.
#>
function Resolve-FmSeedRollbackTarget {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Target,
        [Parameter(Mandatory, Position = 1)][string]$Label
    )
    if ([string]::IsNullOrEmpty($Target)) { return $null }
    if ($Target -ceq '/') {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target"
        return $null
    }
    $absTarget = Resolve-FmSeedPath -Path $Target
    $absHome = Resolve-FmSeedPath -Path $script:FmHome
    $absRoot = Resolve-FmSeedPath -Path $script:FmRoot
    if ($absTarget -ceq $absHome) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is the active firstmate home"
        return $null
    }
    if ($absTarget -ceq $absRoot) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is the firstmate repo"
        return $null
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absTarget -Path $absHome) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is an ancestor of the active firstmate home"
        return $null
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absTarget -Path $absRoot) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is an ancestor of the firstmate repo"
        return $null
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absTarget) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is inside the active firstmate home"
        return $null
    }
    if (Test-FmSeedPathIsAncestor -Ancestor $absRoot -Path $absTarget) {
        Write-FmErr "REFUSED: unsafe $Label rollback target $Target is inside the firstmate repo"
        return $null
    }
    return $absTarget
}

# Twin of seed_return_treehouse_home. A leased home is RETURNED, never removed,
# and a failed return WARNS: the lease may still be held, which is an operator's
# problem to see rather than something to swallow.
function Restore-FmSeedTreehouseHome {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)
    $absHome = Resolve-FmSeedRollbackTarget -Target $HomePath -Label 'treehouse-acquired home'
    if ($null -eq $absHome) { return }
    if (-not (Test-FmCommand 'treehouse')) {
        Write-FmErr ("warning: failed to return treehouse-acquired home $absHome during seed rollback; " +
            'treehouse command not found')
        return
    }
    $result = Invoke-FmTool -FilePath 'treehouse' `
        -Arguments @('return', '--force', (ConvertTo-FmNativePath $absHome)) `
        -WorkingDirectory $script:FmRoot
    if (-not $result.Ok) {
        Write-FmErr ("warning: failed to return treehouse-acquired home $absHome during seed rollback; " +
            'lease may still be held')
    }
}

function Remove-FmSeedCreatedHome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A rollback step whose bash twin removes unconditionally after proving the target safe; a confirmation prompt would strand a half-seeded home in a non-interactive run.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$HomePath)
    $absHome = Resolve-FmSeedRollbackTarget -Target $HomePath -Label 'created home'
    if ($null -eq $absHome) { return }
    try {
        Remove-Item -LiteralPath (ConvertTo-FmNativePath $absHome) -Recurse -Force -ErrorAction SilentlyContinue
    } catch { $null = $_ }
}

# Twin of seed_project_rollback_target: a created clone may be removed only from
# INSIDE the secondmate's own projects directory, on top of the general safety
# proof - one more boundary because this removal is recursive.
function Resolve-FmSeedProjectRollbackTarget {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Target)
    $absTarget = Resolve-FmSeedRollbackTarget -Target $Target -Label 'created project'
    if ($null -eq $absTarget) { return $null }
    $absHome = Resolve-FmSeedPath -Path $script:SeedHome
    $absProjects = Resolve-FmSeedPath -Path (Join-FmSeedChild -Parent $script:SeedHome -Child 'projects')
    if (-not (Test-FmSeedPathIsAncestor -Ancestor $absHome -Path $absProjects)) {
        Write-FmErr ("REFUSED: unsafe created project rollback target $Target has projects directory " +
            'outside the secondmate home')
        return $null
    }
    if (-not (Test-FmSeedPathIsAncestor -Ancestor $absProjects -Path $absTarget)) {
        Write-FmErr ("REFUSED: unsafe created project rollback target $Target is outside the secondmate " +
            'projects directory')
        return $null
    }
    return $absTarget
}

function Remove-FmSeedCreatedProject {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'A rollback step whose bash twin removes unconditionally after proving the target safe; a confirmation prompt would strand a half-seeded home in a non-interactive run.')]
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$ProjectPath)
    $absProject = Resolve-FmSeedProjectRollbackTarget -Target $ProjectPath
    if ($null -eq $absProject) { return }
    try {
        Remove-Item -LiteralPath (ConvertTo-FmNativePath $absProject) -Recurse -Force -ErrorAction SilentlyContinue
    } catch { $null = $_ }
}

# `grep -Fx --`: an exact whole-line match, never a substring.
function Test-FmSeedProjectWasCreated {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$ProjectPath)
    if ([string]::IsNullOrEmpty($script:SeedCreatedProjectsFile)) { return $false }
    if (-not (Test-FmSeedFile -Path $script:SeedCreatedProjectsFile)) { return $false }
    foreach ($line in (Get-FmFileLines $script:SeedCreatedProjectsFile)) {
        if ($line -ceq $ProjectPath) { return $true }
    }
    return $false
}

# Twin of seed_rollback, in the same order. Undoing the generated brief first
# and the parent registry last means a rollback that is itself interrupted still
# leaves the registry - the record that ROUTES work - consistent for longest.
function Invoke-FmSeedRollback {
    [CmdletBinding()]
    param()
    if (-not $script:SeedRollbackActive) { return }
    if ($script:SeedCommitted) { return }

    if ($script:SeedParentBrief -ne '' -and $script:SeedParentBriefCreated) {
        try {
            Remove-Item -LiteralPath (ConvertTo-FmNativePath $script:SeedParentBrief) -Force -ErrorAction SilentlyContinue
        } catch { $null = $_ }
    }
    if ($script:SeedParentBrief -ne '' -and $script:SeedParentBriefDirCreated) {
        # `rmdir` and not `rm -r`: it removes the directory only when this seed
        # left it empty, so a pre-existing sibling artifact is never destroyed.
        $briefDir = ConvertTo-FmNativePath (Get-FmSeedParent -Path $script:SeedParentBrief)
        try {
            if ((Test-Path -LiteralPath $briefDir -PathType Container) -and
                @([System.IO.Directory]::EnumerateFileSystemEntries($briefDir)).Count -eq 0) {
                [System.IO.Directory]::Delete($briefDir)
            }
        } catch { $null = $_ }
    }

    if ($script:SeedHome -ne '' -and $script:SeedHome -cne '/') {
        if ($script:SeedHomeAcquired) {
            Restore-FmSeedTreehouseHome -HomePath $script:SeedHome
        } elseif ($script:SeedHomeCreated) {
            Remove-FmSeedCreatedHome -HomePath $script:SeedHome
        } else {
            if ($script:SeedCreatedProjectsFile -ne '' -and (Test-FmSeedFile -Path $script:SeedCreatedProjectsFile)) {
                foreach ($projectPath in (Get-FmFileLines $script:SeedCreatedProjectsFile)) {
                    if ($projectPath -eq '') { continue }
                    Remove-FmSeedCreatedProject -ProjectPath $projectPath
                }
            }
            if ($script:SeedBackupDir -ne '' -and $script:SeedHomeBackedUp) {
                Restore-FmSeedFile -Existed $script:SeedMarkerExisted `
                    -Backup (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'marker') `
                    -Path (Join-FmSeedChild -Parent $script:SeedHome -Child $script:SubHomeMarker)
                Restore-FmSeedFile -Existed $script:SeedCharterExisted `
                    -Backup (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'charter.md') `
                    -Path (Join-FmSeedChild -Parent $script:SeedHome -Child 'data/charter.md')
                Restore-FmSeedFile -Existed $script:SeedSubRegExisted `
                    -Backup (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'sub-projects.md') `
                    -Path (Join-FmSeedChild -Parent $script:SeedHome -Child 'data/projects.md')
            }
        }
    }

    if ($script:SeedBackupDir -ne '') {
        Restore-FmSeedFile -Existed $script:SeedParentRegExisted `
            -Backup (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'parent-secondmates.md') `
            -Path $script:SeedReg
        try {
            Remove-Item -LiteralPath (ConvertTo-FmNativePath $script:SeedBackupDir) -Recurse -Force -ErrorAction SilentlyContinue
        } catch { $null = $_ }
    }
}

# --- the seed itself ----------------------------------------------------------

function Invoke-FmSeedHome {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This is the entrypoint body of a non-interactive provisioning CLI whose bash twin acts unconditionally; its own rollback is the undo surface, and a confirmation prompt would stall every caller.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$RequestedHome,
        [Parameter(Mandatory, Position = 2)][AllowEmptyCollection()][string[]]$Argument
    )

    # A deliberate --no-projects signal (anywhere in the project position) seeds
    # a project-less home; an accidental omission with no signal still fails
    # loudly.
    $noProjects = $false
    $projects = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @($Argument)) {
        if ($arg -ceq '--no-projects') { $noProjects = $true } else { $projects.Add($arg) }
    }
    if ($noProjects) {
        if ($projects.Count -ne 0) {
            Write-FmErr 'error: --no-projects cannot be combined with a project list'
            Stop-FmSeed 1
        }
    } elseif ($projects.Count -eq 0) {
        Write-FmErr 'error: secondmate needs at least one project, or --no-projects for a project-less home'
        Stop-FmSeed 1
    }

    # Both pre-flights run BEFORE the rollback is armed, because neither has
    # mutated anything yet and there is nothing to undo.
    if (-not (Test-FmSeedRegistry)) { Stop-FmSeed 1 }
    foreach ($project in $projects) {
        if (-not (Test-FmSeedProject -Project $project)) { Stop-FmSeed 1 }
    }

    $script:SeedRollbackActive = $true
    $script:SeedCommitted = $false
    $script:SeedHome = ''
    $script:SeedHomeAcquired = $false
    $script:SeedHomeCreated = $false
    $script:SeedHomeBackedUp = $false
    $backupNative = Join-Path ([System.IO.Path]::GetTempPath()) ("fm-home-seed." + [System.IO.Path]::GetRandomFileName())
    [void][System.IO.Directory]::CreateDirectory($backupNative)
    $script:SeedBackupDir = ConvertTo-FmPosixPath $backupNative
    $script:SeedCreatedProjectsFile = Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'created-projects'
    Set-FmFileText -Path $script:SeedCreatedProjectsFile -Text '' -NoNewline
    $script:SeedParentRegExisted = $false
    $script:SeedParentBrief = Join-FmSeedChild -Parent (Join-FmSeedChild -Parent $script:SeedData -Child $Id) -Child 'brief.md'
    $script:SeedParentBriefCreated = $false
    $script:SeedParentBriefDirCreated = $false
    $script:SeedSubRegExisted = $false
    $script:SeedCharterExisted = $false
    $script:SeedMarkerExisted = $false

    if (Test-FmSeedFile -Path $script:SeedReg) {
        $script:SeedParentRegExisted = $true
        [System.IO.File]::Copy((ConvertTo-FmNativePath $script:SeedReg),
            (ConvertTo-FmNativePath (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'parent-secondmates.md')), $true)
    }

    $seedHomePath = ''
    if ($RequestedHome -ceq '-') {
        $script:SeedHomeAcquired = $true
        $acquired = New-FmSeedTreehouseHome -Id $Id
        if ($null -eq $acquired) { Stop-FmSeed 1 }
        $script:SeedHome = $acquired
        $seedHomePath = Confirm-FmSeedFirstmateHome -HomePath $acquired
        if ($null -eq $seedHomePath) { Stop-FmSeed 1 }
    } else {
        $requestedAbs = Resolve-FmSeedPath -Path $RequestedHome
        if (-not (Test-FmSeedActiveHomePath -HomePath $requestedAbs)) { Stop-FmSeed 1 }
        if (-not (Test-FmSeedHomeAssignment -Id $Id -HomePath $requestedAbs)) { Stop-FmSeed 1 }
        $script:SeedHome = $requestedAbs
        if (-not (Test-FmSeedPathPresent -Path $requestedAbs)) { $script:SeedHomeCreated = $true }
        $seedHomePath = Initialize-FmSeedHome -Id $Id -Requested $requestedAbs
        if ($null -eq $seedHomePath) { Stop-FmSeed 1 }
    }
    $script:SeedHome = $seedHomePath

    if (-not (Test-FmSeedRegistryHomeText -HomePath $seedHomePath)) { Stop-FmSeed 1 }
    if (-not (Test-FmSeedHomeAssignment -Id $Id -HomePath $seedHomePath)) { Stop-FmSeed 1 }
    if (-not (Test-FmSeedOperationalDirectory -HomePath $seedHomePath)) { Stop-FmSeed 1 }
    if (-not (Test-FmSeedLeafFile -HomePath $seedHomePath)) { Stop-FmSeed 1 }
    if ($noProjects) {
        if (-not (Test-FmSeedProjectlessHome -HomePath $seedHomePath)) { Stop-FmSeed 1 }
        if (Test-FmSeedFile -Path $script:SeedParentBrief) {
            if (-not (Test-FmSeedProjectlessCharter -Id $Id -Brief $script:SeedParentBrief)) { Stop-FmSeed 1 }
        }
    }

    foreach ($dir in @($script:SeedData,
            (Join-FmSeedChild -Parent $seedHomePath -Child 'data'),
            (Join-FmSeedChild -Parent $seedHomePath -Child 'state'),
            (Join-FmSeedChild -Parent $seedHomePath -Child 'config'),
            (Join-FmSeedChild -Parent $seedHomePath -Child 'projects'))) {
        if (-not (New-FmSeedDirectory -Path $dir)) { Stop-FmSeed 1 }
    }

    $subProjects = Join-FmSeedChild -Parent $seedHomePath -Child 'data/projects.md'
    if (Test-FmSeedFile -Path $subProjects) {
        $script:SeedSubRegExisted = $true
        [System.IO.File]::Copy((ConvertTo-FmNativePath $subProjects),
            (ConvertTo-FmNativePath (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'sub-projects.md')), $true)
    }
    $subCharter = Join-FmSeedChild -Parent $seedHomePath -Child 'data/charter.md'
    if (Test-FmSeedFile -Path $subCharter) {
        $script:SeedCharterExisted = $true
        [System.IO.File]::Copy((ConvertTo-FmNativePath $subCharter),
            (ConvertTo-FmNativePath (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'charter.md')), $true)
    }
    $subMarker = Join-FmSeedChild -Parent $seedHomePath -Child $script:SubHomeMarker
    if (Test-FmSeedFile -Path $subMarker) {
        $script:SeedMarkerExisted = $true
        [System.IO.File]::Copy((ConvertTo-FmNativePath $subMarker),
            (ConvertTo-FmNativePath (Join-FmSeedChild -Parent $script:SeedBackupDir -Child 'marker')), $true)
    }
    $script:SeedHomeBackedUp = $true

    if (-not (Test-FmSeedFile -Path $script:SeedParentBrief)) {
        if ((Get-FmEnv -Name 'FM_SECONDMATE_CHARTER') -eq '') {
            Write-FmErr ("error: no filled secondmate charter brief at $($script:SeedParentBrief); " +
                'set FM_SECONDMATE_CHARTER or scaffold one and replace {TASK}')
            Stop-FmSeed 1
        }
        if (-not (Test-FmSeedDirectory -Path (Get-FmSeedParent -Path $script:SeedParentBrief))) {
            $script:SeedParentBriefDirCreated = $true
        }
        $briefArgs = if ($noProjects) {
            @($Id, '--secondmate', '--no-projects')
        } else {
            @($Id, '--secondmate') + @($projects)
        }
        $brief = Invoke-FmScript -Name 'fm-brief' -Arguments $briefArgs -BinDir $script:SeedBinDir
        if ($brief.StdOut -ne '') { Write-FmRaw $brief.StdOut }
        if ($brief.StdErr -ne '') { Write-FmRaw $brief.StdErr }
        if (-not $brief.Ok) { Stop-FmSeed $brief.ExitCode }
        $script:SeedParentBriefCreated = $true
    }
    if ((Get-FmFileText $script:SeedParentBrief).Contains('{TASK}')) {
        Write-FmErr ("error: secondmate charter brief at $($script:SeedParentBrief) still contains {TASK}; " +
            'fill it before seeding')
        Stop-FmSeed 1
    }
    $charterSummary = Get-FmSeedRegistrySummary -Brief $script:SeedParentBrief
    if ($charterSummary -eq '') {
        Write-FmErr ("error: secondmate charter brief at $($script:SeedParentBrief) has an empty Charter " +
            'section; fill it before seeding')
        Stop-FmSeed 1
    }
    $charterScope = Get-FmSeedRegistryScope -Brief $script:SeedParentBrief
    if ($charterScope -eq '') {
        Write-FmErr ("error: secondmate charter brief at $($script:SeedParentBrief) has an empty Routing " +
            'scope section; fill it before seeding')
        Stop-FmSeed 1
    }

    foreach ($project in $projects) {
        $projectDst = Resolve-FmSeedProjectDestination -HomePath $seedHomePath -Project $project
        if ($null -eq $projectDst) { Stop-FmSeed 1 }
        # Recorded BEFORE the clone, so a clone that fails half-way still has
        # its destination in the created list and is removed by the rollback.
        if (-not (Test-FmSeedPathPresent -Path $projectDst)) {
            Add-FmFileLine -Path $script:SeedCreatedProjectsFile -Line $projectDst
        }
        if (-not (Copy-FmSeedProject -Project $project -HomePath $seedHomePath)) { Stop-FmSeed 1 }
    }
    if (-not (Sync-FmSeedProjectRegistry -HomePath $seedHomePath -Project @($projects))) { Stop-FmSeed 1 }
    foreach ($project in $projects) {
        $projectDst = Resolve-FmSeedProjectDestination -HomePath $seedHomePath -Project $project
        if ($null -eq $projectDst) { Stop-FmSeed 1 }
        $created = Test-FmSeedProjectWasCreated -ProjectPath $projectDst
        if (-not (Initialize-FmSeedNoMistakesProject -HomePath $seedHomePath -Project $project -Created $created)) {
            Stop-FmSeed 1
        }
    }

    [System.IO.File]::Copy((ConvertTo-FmNativePath $script:SeedParentBrief),
        (ConvertTo-FmNativePath (Join-FmSeedChild -Parent $seedHomePath -Child 'data/charter.md')), $true)

    $projectsCsv = Join-FmSeedProjectList -Project @($projects)
    Set-FmFileText -Path $subMarker -Text "$Id`n" -NoNewline
    if (-not (Write-FmSeedRegistry -Id $Id -HomePath $seedHomePath -ProjectsCsv $projectsCsv -Brief $script:SeedParentBrief)) {
        Stop-FmSeed 1
    }
    if (-not (Test-FmSeedRegistry)) { Stop-FmSeed 1 }

    $script:SeedCommitted = $true
    try {
        Remove-Item -LiteralPath (ConvertTo-FmNativePath $script:SeedBackupDir) -Recurse -Force -ErrorAction SilentlyContinue
    } catch { $null = $_ }
    Write-FmOut "home=$seedHomePath"
}

# --- CLI ----------------------------------------------------------------------

$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $writeUsage = {
        Write-FmErr 'usage: fm-home-seed.sh <id> <home|-> {<project>...|--no-projects}'
        Write-FmErr '       fm-home-seed.sh validate'
    }

    $first = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }

    try {
        if ($first -ceq 'validate') {
            if ($fmArgv.Count -ne 1) { & $writeUsage; Exit-FmScript 1 }
            if (-not (Test-FmSeedRegistry)) { Exit-FmScript 1 }
            Exit-FmScript 0
        }
        if ($first -ceq '-h' -or $first -ceq '--help' -or $first -eq '') {
            & $writeUsage
            Exit-FmScript 0
        }
        if ($fmArgv.Count -lt 3) { & $writeUsage; Exit-FmScript 1 }

        try {
            Invoke-FmSeedHome -Id ([string]$fmArgv[0]) -RequestedHome ([string]$fmArgv[1]) `
                -Argument @($fmArgv[2..($fmArgv.Count - 1)] | ForEach-Object { [string]$_ })
        } finally {
            # The `trap seed_rollback EXIT` twin: it runs on every path out,
            # including an unexpected exception, and no-ops after commit.
            Invoke-FmSeedRollback
        }
        Exit-FmScript 0
    } catch [FmSeedStop] {
        Exit-FmScript $_.Exception.Code
    }
}
