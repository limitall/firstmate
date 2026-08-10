# fm-secondmate-registry-lib.psm1 - parser and binding validator for
# data/secondmates.md records.
# Twin: bin/fm-secondmate-registry-lib.sh
#
# A generated record ends with an explicit structured suffix:
#   (home: ...; scope: ...; projects: ...; added YYYY-MM-DD)
# Summary text and scope text are natural language and may contain parentheses
# and semicolons, so field boundaries are anchored to the suffix markers rather
# than to the first incidental punctuation.
#
# bash -> PowerShell:
#   secondmate_registry_parse_line        -> ConvertFrom-FmSecondmateRegistryLine
#   secondmate_registry_line_for_id       -> Get-FmSecondmateRegistryRecord
#   secondmate_registry_field             -> Get-FmSecondmateRegistryField
#   secondmate_registry_path_key          -> Get-FmSecondmateRegistryPathKey
#   secondmate_registry_validate_bindings -> Resolve-FmSecondmateRegistryBinding
#   SECONDMATE_REGISTRY_* out-globals     -> fields on the returned objects
#
# ---------------------------------------------------------------------------
# Out-parameters become return values
# ---------------------------------------------------------------------------
# The bash publishes its results by assigning eleven SECONDMATE_REGISTRY_*
# shell globals that a sourcing caller reads afterwards. A PowerShell module
# has its own scope and cannot write into its caller's, so each function
# returns an object carrying exactly those fields instead - Id/Summary/Home/
# Scope/Projects/Added/Line for a parsed record, and Ok/Error/MatchHome/
# MatchHomeKey/MatchProjects for a validation. This is the idiom for every
# converted lib that used out-globals; it also removes the bash hazard that a
# FAILED parse leaves the previous record's globals partly overwritten.
#
# ---------------------------------------------------------------------------
# What got simpler, and what deliberately did not
# ---------------------------------------------------------------------------
# The bash validator writes the registry to a temp SNAPSHOT file and a TSV
# BINDINGS file under mktemp -d, then runs three awk programs over the
# bindings and rm -rf's the directory on all eleven exit paths. Here the
# snapshot is a single read into an in-memory array - the same "decide against
# one stable view of the file" guarantee, with no temp directory to leak - and
# the three awk programs are three in-process passes. The one bash error that
# therefore has NO twin is "could not create secondmate registry validation
# state" (mktemp failure); every other message below is byte-identical,
# multi-line duplicate reports included, because callers surface them to the
# captain verbatim.
#
# NOT simplified: the record regex, whose greediness is load-bearing. `(.+)`
# for the summary and `(.*)` for the scope are GREEDY in both POSIX ERE and
# .NET, so each binds to the LAST possible delimiter - that is precisely what
# lets a summary contain " (home:" and a scope contain "; projects:" without
# tearing the record apart. The whitespace class is spelled as the six
# C-locale characters rather than .NET's `\s` for the same reason it is in the
# sibling libs: `\s` would additionally accept NBSP, silently admitting a
# record the bash parser rejects.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# [[:space:]] in the C locale: space, tab, LF, VT, FF, CR - and nothing else.
$script:FmRegistrySpace = '[ \t\n\v\f\r]'

# The exact twins of $local_re and $remote_re in bin/fm-secondmate-registry-lib.sh.
# A generated local record ends with (home: ...; scope: ...; projects: ...;
# added ...); a remote record adds its host placement before the existing
# fields: (host: ...; root: ...; home: ...; ...).
$script:FmRegistryLocalRe = [regex]::new(
    '^- ([A-Za-z0-9._-]+) - (.+) \(home:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*scope:' + $script:FmRegistrySpace + '*(.*);' +
    $script:FmRegistrySpace + '*projects:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*added' + $script:FmRegistrySpace + '+([0-9]{4}-[0-9]{2}-[0-9]{2})\)' +
    $script:FmRegistrySpace + '*$')
$script:FmRegistryRemoteRe = [regex]::new(
    '^- ([A-Za-z0-9._-]+) - (.+) \(host:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*root:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*home:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*scope:' + $script:FmRegistrySpace + '*(.*);' +
    $script:FmRegistrySpace + '*projects:' + $script:FmRegistrySpace + '*([^;)]*);' +
    $script:FmRegistrySpace + '*added' + $script:FmRegistrySpace + '+([0-9]{4}-[0-9]{2}-[0-9]{2})\)' +
    $script:FmRegistrySpace + '*$')

# The id character class, shared by the record regex and the standalone id
# checks so the three can never disagree about what an id may contain.
$script:FmRegistryBadIdRe = [regex]::new('[^A-Za-z0-9._-]')

<#
.SYNOPSIS
Parse one registry line into a record object, or $null when it is not a valid
record.
.DESCRIPTION
Returns $null both for a line that does not match the record shape at all and
for one that matches but carries an empty home or scope - the bash makes the
same two cases indistinguishable to its callers (`return 1`), and no caller
distinguishes them.
#>
function ConvertFrom-FmSecondmateRegistryLine {
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Line)

    # The legacy local form is tried FIRST so summary prose that happens to
    # mention remote field names cannot change an existing route's placement
    # semantics - the bash parses in the same order for the same reason.
    #
    # Named homeValue, not home: $HOME is a PowerShell automatic variable and
    # assigning it inside a module every script imports is action at a
    # distance (and a PSScriptAnalyzer error).
    $m = $script:FmRegistryLocalRe.Match($Line)
    if ($m.Success) {
        $homeValue = $m.Groups[3].Value
        $scope = $m.Groups[4].Value
        if ($homeValue -eq '' -or $scope -eq '') { return $null }
        return [pscustomobject]@{
            Id       = $m.Groups[1].Value
            Summary  = $m.Groups[2].Value
            Host     = ''
            Root     = ''
            Home     = $homeValue
            Scope    = $scope
            Projects = $m.Groups[5].Value
            Added    = $m.Groups[6].Value
            Remote   = 0
            Line     = $Line
        }
    }
    $m = $script:FmRegistryRemoteRe.Match($Line)
    if (-not $m.Success) { return $null }
    $hostAlias = $m.Groups[3].Value
    $rootValue = $m.Groups[4].Value
    $homeValue = $m.Groups[5].Value
    $scope = $m.Groups[6].Value
    if ($homeValue -eq '' -or $scope -eq '') { return $null }
    if ($hostAlias -eq '' -or $rootValue -eq '') { return $null }
    return [pscustomobject]@{
        Id       = $m.Groups[1].Value
        Summary  = $m.Groups[2].Value
        Host     = $hostAlias
        Root     = $rootValue
        Home     = $homeValue
        Scope    = $scope
        Projects = $m.Groups[7].Value
        Added    = $m.Groups[8].Value
        Remote   = 1
        Line     = $Line
    }
}

<#
.SYNOPSIS
True when a string is a syntactically valid secondmate id.
#>
function Get-FmSecondmateRegistryLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)
    return "$Directory/.secondmate-registry.lock"
}

function Get-FmSecondmateReplyLifecycleLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Mandatory, Position = 1)][string]$Id
    )
    return "$Directory/.remote-reply-lifecycle-$Id.lock"
}

function Test-FmSecondmateRegistryId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Id)
    if ($Id -eq '') { return $false }
    return (-not $script:FmRegistryBadIdRe.IsMatch($Id))
}

<#
.SYNOPSIS
Read a registry file's lines, or $null when the file is unavailable or unsafe.
.DESCRIPTION
"Unsafe" is the bash `[ -f "$reg" ] && [ ! -L "$reg" ]` gate: a symlinked
registry is refused outright, because the registry decides where firstmate
will write, and a link is how it would be pointed somewhere else.

[System.IO.File]::ReadAllText rather than Get-FmFileText because an UNREADABLE
registry and an EMPTY one must not be confused: an empty registry is a
legitimate state (no secondmates), while an unreadable one is the
"unavailable or unsafe" error the bash raises when its `cat` fails.
#>
function Get-FmSecondmateRegistryLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory, Position = 0)][string]$Registry)

    $native = ConvertTo-FmNativePath $Registry
    if (Test-FmSymlink $native) { return $null }
    if (-not [System.IO.File]::Exists($native)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($native)
    } catch {
        return $null
    }
    if ($text -eq '') { return @() }
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $text -split "`n"
    # The bash loop is `while IFS= read -r line || [ -n "$line" ]`, which
    # processes a final line that carries no terminating newline. Dropping only
    # a trailing EMPTY element reproduces that exactly.
    if ($lines.Length -gt 0 -and $lines[-1] -eq '') {
        $lines = $lines[0..($lines.Length - 2)]
    }
    return @($lines)
}

<#
.SYNOPSIS
The single registry record for an id, or $null.
.DESCRIPTION
Exactly one matching line must exist. A SECOND line for the same id is a
failure, not a "first wins" - an id bound twice means the registry itself is
ambiguous about where that secondmate lives, and picking one would send work
to a home the operator did not choose.

Matching is on the literal line prefix (`- <id>` alone, or `- <id> ` followed
by anything), not on the parsed record, so a duplicate is still detected when
the second occurrence is malformed.
#>
function Get-FmSecondmateRegistryRecord {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Registry,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id
    )

    if (-not (Test-FmSecondmateRegistryId -Id $Id)) { return $null }
    $lines = Get-FmSecondmateRegistryLine -Registry $Registry
    if ($null -eq $lines) { return $null }

    $exact = "- $Id"
    $prefix = "- $Id "
    $found = $null
    foreach ($line in $lines) {
        if ($line -ne $exact -and -not $line.StartsWith($prefix)) { continue }
        if ($null -ne $found) { return $null }
        $found = $line
    }
    if ($null -eq $found) { return $null }
    return (ConvertFrom-FmSecondmateRegistryLine -Line $found)
}

<#
.SYNOPSIS
One field (host, root, home, scope, projects, or remote) of a secondmate's
registry record, or $null. 'remote' prints 0 or 1 exactly as the bash does.
.DESCRIPTION
An EMPTY string is a real answer here, not a failure: `projects` is optional in
the record shape, so '' means "registered with no projects" while $null means
"no usable record". Callers that conflate the two would treat a valid
project-less secondmate as unregistered.
#>
function Get-FmSecondmateRegistryField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Registry,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Id,
        [Parameter(Mandatory, Position = 2)][string]$Key
    )

    $record = Get-FmSecondmateRegistryRecord -Registry $Registry -Id $Id
    if ($null -eq $record) { return $null }
    switch ($Key) {
        'host' { return $record.Host }
        'root' { return $record.Root }
        'home' { return $record.Home }
        'scope' { return $record.Scope }
        'projects' { return $record.Projects }
        'remote' { return "$($record.Remote)" }
        default { return $null }
    }
}

<#
.SYNOPSIS
Resolve every symlink and junction in a directory path, the `pwd -P` twin.
.DESCRIPTION
`cd "$dir" && pwd -P` resolves EVERY component, not just the leaf, and that is
the property the binding keys depend on: two registry entries reaching one
home through different links must collapse to the same key, or the duplicate
check silently passes. .NET's ResolveLinkTarget answers for one path at a
time, so the components are walked from the root and each accumulated prefix
is resolved in turn; when a prefix IS a link, the walk continues from its
target, which is how a link that jumps volumes still ends up on the right
physical path.

Returns $null for a path that does not exist or cannot be inspected, matching
`cd` failing.
#>
function Resolve-FmPhysicalDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$Directory)

    $native = ConvertTo-FmNativePath $Directory
    if (-not (Test-Path -LiteralPath $native -PathType Container)) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($native)
        $root = [System.IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrEmpty($root)) { return $null }
        $rest = $full.Substring($root.Length)
        $current = $root
        foreach ($segment in ($rest -split '[\\/]')) {
            if ($segment -eq '') { continue }
            $current = Join-Path $current $segment
            $target = [System.IO.Directory]::ResolveLinkTarget($current, $true)
            if ($null -ne $target) { $current = $target.FullName }
        }
        return [System.IO.Path]::GetFullPath($current)
    } catch {
        return $null
    }
}

<#
.SYNOPSIS
The canonical comparison key for a secondmate home path, or $null.
.DESCRIPTION
An existing directory resolves through every link; a path whose LEAF does not
exist yet resolves its parent and re-appends the leaf name, exactly as the
bash `cd "$(dirname)" && printf '%s/%s' "$(pwd -P)" "$(basename)"` does - a
home about to be created still gets a stable key.

The key comes back in POSIX form so it is byte-comparable with what the bash
twin produces and so the ancestor test in the validator keeps working on '/'
boundaries.

One deliberate widening over the bash `case "$path" in /*)` gate: a Windows
drive-absolute path (F:\x) is accepted alongside a POSIX-absolute one, because
on this platform they name the same category of thing and a PowerShell caller
holds the native spelling (Get-FmContext returns native paths). A RELATIVE
path is still refused. The registry's own stored-home gate in
Resolve-FmSecondmateRegistryBinding stays strictly POSIX-absolute, because
that one governs what may be WRITTEN into a durable record, where contract 3
of docs/powershell-port.md keeps POSIX form.
#>
function Get-FmSecondmateRegistryPathKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Path)

    if ($Path -eq '') { return $null }
    $isPosixAbsolute = $Path.StartsWith('/')
    $isDriveAbsolute = $Path -match '^[A-Za-z]:[\\/]'
    if (-not $isPosixAbsolute -and -not $isDriveAbsolute) { return $null }

    $native = ConvertTo-FmNativePath $Path
    if (Test-Path -LiteralPath $native -PathType Container) {
        $physical = Resolve-FmPhysicalDirectory -Directory $native
        if ($null -eq $physical) { return $null }
        return (ConvertTo-FmPosixPath $physical)
    }

    # POSIX dirname/basename on the ORIGINAL spelling, then resolve the parent.
    $trimmed = $Path
    while ($trimmed.Length -gt 1 -and ($trimmed.EndsWith('/') -or $trimmed.EndsWith('\'))) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }
    $cut = [Math]::Max($trimmed.LastIndexOf('/'), $trimmed.LastIndexOf('\'))
    if ($cut -lt 0) { return $null }
    $parent = if ($cut -eq 0) { $trimmed.Substring(0, 1) } else { $trimmed.Substring(0, $cut) }
    $base = $trimmed.Substring($cut + 1)
    if ($base -eq '') { return $null }

    $parentPhysical = Resolve-FmPhysicalDirectory -Directory $parent
    if ($null -eq $parentPhysical) { return $null }
    return ((ConvertTo-FmPosixPath $parentPhysical).TrimEnd('/') + '/' + $base)
}

<#
.SYNOPSIS
Invoke a caller-supplied home resolver the way the bash invokes "$resolver".
.DESCRIPTION
The bash passes a FUNCTION NAME and calls it as a command; three call sites do
this with three different resolvers (fm-teardown passes the library's own,
fm-spawn and fm-home-seed pass their local ones). The PowerShell twin accepts
either a scriptblock or a command name, so a converted caller can hand over a
closure without inventing a global function.

Any failure - a name that resolves to nothing, a resolver that throws, a
resolver that prints nothing - collapses to '' , which the caller reports as
"unresolvable secondmate home". That matches `$("$resolver" "$home" 2>/dev/null
|| true)`, which swallows the error and leaves the variable empty.
#>
function Invoke-FmSecondmateHomeResolver {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][object]$Resolver,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$HomePath
    )
    try {
        $raw = if ($Resolver -is [scriptblock]) {
            & $Resolver $HomePath
        } else {
            & ([string]$Resolver) $HomePath
        }
    } catch {
        return ''
    }
    if ($null -eq $raw) { return '' }
    # `$(...)` strips trailing newlines and joins a multi-line result the way
    # the shell would have written it into one variable.
    $text = (@($raw) -join "`n")
    return $text.TrimEnd("`n")
}

<#
.SYNOPSIS
Validate every home/id binding in the registry, optionally checking one
expected secondmate against one expected home.
.DESCRIPTION
Returns an object with Ok, Error, MatchHost, MatchRoot, MatchHome,
MatchHomeKey, MatchProjects and MatchRemote. Binding keys are route-qualified:
a resolved local home becomes "local:<physical-path>" and a remote route
becomes "ssh:<host>:<home>", so a local and a remote home can never collide in
the duplicate or overlap passes.
The checks run in the bash's order, and the order is load-bearing: a duplicate
home is reported before an overlap, so an exact-duplicate pair is never
described as "contains" itself.

Every message here is byte-identical to the bash twin's, including the
multi-line duplicate/overlap reports, because bin/fm-teardown and bin/fm-spawn
surface them to the captain verbatim.
#>
function Resolve-FmSecondmateRegistryBinding {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Registry,
        [Parameter(Position = 1)][object]$Resolver = $null,
        [Parameter(Position = 2)][AllowEmptyString()][string]$ExpectedId = '',
        [Parameter(Position = 3)][AllowEmptyString()][string]$ExpectedHome = ''
    )

    if ($null -eq $Resolver) {
        $Resolver = { param($p) Get-FmSecondmateRegistryPathKey -Path $p }
    }

    $result = [pscustomobject]@{
        Ok            = $false
        Error         = ''
        MatchHost     = ''
        MatchRoot     = ''
        MatchHome     = ''
        MatchHomeKey  = ''
        MatchProjects = ''
        MatchRemote   = 0
    }

    # An EMPTY ExpectedId means "no expected id" and is allowed; only a
    # non-empty id with an illegal character is rejected here. The bash `case`
    # has the same shape, and fm-teardown relies on the empty form for its
    # whole-registry sweep.
    if ($ExpectedId -ne '' -and $script:FmRegistryBadIdRe.IsMatch($ExpectedId)) {
        $result.Error = "invalid secondmate id: $ExpectedId"
        return $result
    }

    $lines = Get-FmSecondmateRegistryLine -Registry $Registry
    if ($null -eq $lines) {
        $result.Error = "secondmate registry is unavailable or unsafe: $Registry"
        return $result
    }

    # The in-memory twin of the temp snapshot + TSV bindings file: one stable
    # view of the registry, and one ordered list of (key, id) pairs.
    $bindings = [System.Collections.Generic.List[psobject]]::new()

    foreach ($line in $lines) {
        if (-not $line.StartsWith('- ')) { continue }
        $record = ConvertFrom-FmSecondmateRegistryLine -Line $line
        if ($null -eq $record) {
            $result.Error = "malformed secondmate registry entry: $line"
            return $result
        }
        $id = $record.Id
        $hostAlias = $record.Host
        $rootPath = $record.Root
        $homePath = $record.Home

        # Stored homes stay POSIX-absolute: this gate governs the durable
        # record, not a caller's in-memory spelling.
        if (-not $homePath.StartsWith('/')) {
            $result.Error = "unsafe non-absolute secondmate home for ${id}: $homePath"
            return $result
        }
        # A TAB would split the binding record's own field boundary; LF and CR
        # are checked for literal parity with the bash even though this
        # module's line reader cannot deliver them into a field.
        $route = "$homePath$hostAlias$rootPath"
        if ($route.Contains("`t") -or $route.Contains("`n") -or $route.Contains("`r")) {
            $result.Error = "unsafe secondmate route for $id"
            return $result
        }

        if ($record.Remote -eq 1) {
            # A remote route is validated STRUCTURALLY, never resolved: the
            # path lives on another host, so the only checks that mean
            # anything here are the ones a hostile or mangled record could
            # fail. Each refusal is byte-identical to the bash twin's.
            if ($hostAlias -eq '' -or $hostAlias.StartsWith('-') -or
                $script:FmRegistryBadIdRe.IsMatch($hostAlias)) {
                $result.Error = "unsafe SSH host alias for ${id}: $hostAlias"
                return $result
            }
            if (-not $rootPath.StartsWith('/')) {
                $result.Error = "unsafe non-absolute remote root for ${id}: $rootPath"
                return $result
            }
            if ("/$rootPath/".Contains('/../') -or "/$rootPath/".Contains('/./')) {
                $result.Error = "remote code root contains traversal components for ${id}: $rootPath"
                return $result
            }
            if ("/$homePath/".Contains('/../') -or "/$homePath/".Contains('/./')) {
                $result.Error = "remote home contains traversal components for ${id}: $homePath"
                return $result
            }
            if (("$rootPath" + "$homePath").Contains('//')) {
                $result.Error = "remote route contains an empty path component for $id"
                return $result
            }
            if ($rootPath -eq $homePath) {
                $result.Error = "overlapping remote root and home for ${id}: $rootPath"
                return $result
            }
            if (("$homePath" + '/').StartsWith("$rootPath" + '/')) {
                $result.Error = "remote home for $id is inside its code root: $homePath"
                return $result
            }
            if (("$rootPath" + '/').StartsWith("$homePath" + '/')) {
                $result.Error = "remote code root for $id is inside its home: $rootPath"
                return $result
            }
            $homeKey = "ssh:${hostAlias}:$homePath"
        } else {
            $homeKey = Invoke-FmSecondmateHomeResolver -Resolver $Resolver -HomePath $homePath
            if ($homeKey -eq '') {
                $result.Error = "unresolvable secondmate home for ${id}: $homePath"
                return $result
            }
            $homeKey = "local:$homeKey"
        }
        $bindings.Add([pscustomobject]@{ Key = $homeKey; Id = $id })

        if ($ExpectedId -ne '' -and $id -eq $ExpectedId) {
            $result.MatchHost = $hostAlias
            $result.MatchRoot = $rootPath
            $result.MatchHome = $homePath
            $result.MatchHomeKey = $homeKey
            $result.MatchProjects = $record.Projects
            $result.MatchRemote = $record.Remote
        }
    }

    # Pass 1: two ids claiming one home.
    $owner = @{}
    $duplicateHomes = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $bindings) {
        if ($owner.ContainsKey($b.Key)) {
            $duplicateHomes.Add("$($b.Key): $($owner[$b.Key]), $($b.Id)")
        } else {
            $owner[$b.Key] = $b.Id
        }
    }
    if ($duplicateHomes.Count -gt 0) {
        $result.Error = "duplicate secondmate home assignment: $($duplicateHomes -join "`n")"
        return $result
    }

    # Pass 2: one id claiming two homes.
    $homeOf = @{}
    $duplicateIds = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $bindings) {
        if ($homeOf.ContainsKey($b.Id)) {
            $duplicateIds.Add("$($b.Id): $($homeOf[$b.Id]), $($b.Key)")
        } else {
            $homeOf[$b.Id] = $b.Key
        }
    }
    if ($duplicateIds.Count -gt 0) {
        $result.Error = "duplicate secondmate id assignment: $($duplicateIds -join "`n")"
        return $result
    }

    # Pass 3: one home nested inside another. Two homes where one contains the
    # other cannot be independently owned - teardown of the outer would take
    # the inner's unlanded work with it.
    $overlaps = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.List[psobject]]::new()
    foreach ($b in $bindings) {
        foreach ($prev in $seen) {
            # awk: ancestor(a, b) = a != b && index(b, a "/") == 1
            if ($b.Key -ne $prev.Key -and $prev.Key.StartsWith($b.Key + '/')) {
                $overlaps.Add("$($b.Key) ($($b.Id)) contains $($prev.Key) ($($prev.Id))")
            } elseif ($prev.Key -ne $b.Key -and $b.Key.StartsWith($prev.Key + '/')) {
                $overlaps.Add("$($prev.Key) ($($prev.Id)) contains $($b.Key) ($($b.Id))")
            }
        }
        $seen.Add($b)
    }
    if ($overlaps.Count -gt 0) {
        $result.Error = "overlapping secondmate home assignment: $($overlaps -join "`n")"
        return $result
    }

    if ($ExpectedId -ne '' -and $result.MatchHome -eq '') {
        $result.Error = "no registry binding for secondmate $ExpectedId"
        return $result
    }

    if ($ExpectedHome -ne '') {
        if ($result.MatchRemote -eq 1) {
            $expectedKey = "ssh:$($result.MatchHost):$ExpectedHome"
        } else {
            $expectedKey = Invoke-FmSecondmateHomeResolver -Resolver $Resolver -HomePath $ExpectedHome
            if ($expectedKey -ne '') { $expectedKey = "local:$expectedKey" }
        }
        if ($expectedKey -eq '' -or $expectedKey -ne $result.MatchHomeKey) {
            $result.Error = "secondmate $ExpectedId is registered at $($result.MatchHome), not $ExpectedHome"
            return $result
        }
    }

    $result.Ok = $true
    return $result
}

Export-ModuleMember -Function @(
    'ConvertFrom-FmSecondmateRegistryLine',
    'Test-FmSecondmateRegistryId',
    'Get-FmSecondmateRegistryLockPath',
    'Get-FmSecondmateReplyLifecycleLockPath',
    'Get-FmSecondmateRegistryLine',
    'Get-FmSecondmateRegistryRecord',
    'Get-FmSecondmateRegistryField',
    'Resolve-FmPhysicalDirectory',
    'Get-FmSecondmateRegistryPathKey',
    'Invoke-FmSecondmateHomeResolver',
    'Resolve-FmSecondmateRegistryBinding'
)
