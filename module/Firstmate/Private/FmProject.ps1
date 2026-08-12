#requires -Version 7.0
# FmProject.ps1 - the project registry and delivery-posture parsing, ported from
# bin/fm-project-mode.sh.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to the brief,
# spawn, and promote commands (AGENTS.md section 7).
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake. Mechanical
#                          output maps it to its most rigorous leg, no-mistakes,
#                          so sync, seeding, and init treat such a project as the
#                          remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and
# warns, so a typo never silently drops the gate.

$script:FmProjectKnownModes = @('no-mistakes', 'direct-PR', 'local-only', 'no-mistakes-prod-only')

# Parse ONE registry line into its registered posture, or $null when the line is
# not a registry entry at all. The bash original matches on the first two
# whitespace-separated fields being "-" and the project name.
function Get-FmProjectRegistryLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $fields = @($Line -split '\s+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 2) { return $null }
    if ($fields[0] -ne '-') { return $null }

    $name = $fields[1]
    $mode = 'no-mistakes'
    $yolo = 'off'

    if ($fields.Count -ge 3 -and $fields[2].StartsWith('[')) {
        # Accumulate fields until one ends with the closing bracket, exactly as
        # the awk original does, so "[direct-PR +yolo]" is read as one annotation.
        $parts = @()
        for ($i = 2; $i -lt $fields.Count; $i++) {
            $parts += $fields[$i]
            if ($fields[$i].EndsWith(']')) { break }
        }
        $annotation = ($parts -join ' ') -replace '^\[', '' -replace '\]$', ''
        $tokens = @($annotation -split ' ' | Where-Object { $_ -ne '' })
        if ($tokens.Count -ge 1 -and $tokens[0] -ne '+yolo') { $mode = $tokens[0] }
        if ($tokens -contains '+yolo') { $yolo = 'on' }
    }

    [pscustomobject]@{ Name = $name; Mode = $mode; Yolo = $yolo }
}

# Every registered project, in registry order. Used by callers that need the
# whole navigation registry rather than one project's posture.
function Get-FmProjectRegistryEntry {
    [OutputType([object[]])]
    [CmdletBinding()]
    param([string]$RegistryPath)

    if ([string]::IsNullOrEmpty($RegistryPath)) {
        $RegistryPath = Join-Path (Get-FmSessionPaths).Data 'projects.md'
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return @() }

    $entries = @()
    foreach ($line in (Get-FmSessionFileLines -Path $RegistryPath)) {
        $parsed = Get-FmProjectRegistryLine -Line $line
        if ($null -ne $parsed) { $entries += $parsed }
    }
    $entries
}

# --- registry writing ---------------------------------------------------------
#
# The registry is the private fleet NAVIGATION registry: what exists, where, and
# under which standing posture. It is not project documentation, and nothing
# here writes anything else into it. A registry line is rendered in exactly the
# shape the parser above reads, so a line this port writes is read identically
# by a Linux firstmate's awk.

# The date stamp a new registry line carries. Local date, ISO order, because
# that is what every existing line in data/projects.md uses.
function Get-FmProjectAddedStamp {
    [CmdletBinding()]
    param([datetime]$Date = [datetime]::Now)
    $Date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}

function New-FmProjectRegistryLine {
    # It renders a string and changes nothing; the verb is about what the line
    # is FOR, not about a state change this function performs.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][ValidateSet('on', 'off')][string]$Yolo,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Description,
        [string]$Added = ''
    )

    if (-not $Added) { $Added = Get-FmProjectAddedStamp }
    $annotation = if ($Yolo -eq 'on') { "[$Mode +yolo]" } else { "[$Mode]" }
    $description = ($Description -replace '[\r\n]+', ' ').Trim()
    if (-not $description) { $description = 'no description recorded' }
    "- $Name $annotation - $description (added $Added)"
}

# Add-FmProjectRegistryEntry: append one project to the registry, creating the
# file with its heading when this home has none yet. Refuses a duplicate name
# rather than registering a second posture for one project - two lines for one
# name would make the posture depend on which one a reader hit first.
function Add-FmProjectRegistryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Line
    )

    $parsed = Get-FmProjectRegistryLine -Line $Line
    if ($null -eq $parsed) {
        throw "error: '$Line' is not a registry entry the parser reads back; refusing to write it"
    }
    $existing = @(Get-FmProjectRegistryEntry -RegistryPath $RegistryPath | Where-Object { $_.Name -eq $parsed.Name })
    if ($existing.Count -gt 0) {
        throw "error: project `"$($parsed.Name)`" is already in the registry at $RegistryPath"
    }

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        $dir = Split-Path -Parent $RegistryPath
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        Write-FmTextFileLf -Path $RegistryPath -Text "# Projects`n`n"
    }
    Add-FmTextLineLf -Path $RegistryPath -Line $Line
    $parsed.Name
}

# Remove-FmProjectRegistryEntry: drop one project's line, leaving every other
# byte of the file alone. Returns $false when the project has no line, so a
# caller can tell "removed" from "was never there".
function Remove-FmProjectRegistryEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($RegistryPath, "remove the registry entry for $Name")) { return $false }
    $lines = @(Get-FmSessionFileLines -Path $RegistryPath)
    $kept = @()
    $removed = $false
    foreach ($line in $lines) {
        $parsed = Get-FmProjectRegistryLine -Line $line
        if ($null -ne $parsed -and $parsed.Name -eq $Name) {
            $removed = $true
            continue
        }
        $kept += $line
    }
    if (-not $removed) { return $false }
    Write-FmTextFileLf -Path $RegistryPath -Text (($kept -join "`n") + "`n")
    $true
}

# --- project paths ------------------------------------------------------------

# Assert-FmProjectName: a project name is BOTH a directory name and the registry
# key, so it must be one path segment with no whitespace - the registry parser
# splits on whitespace, and a name carrying any would be read back as a
# different project than the one that was written.
function Assert-FmProjectName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    if (-not $Name) { throw 'error: a project name is required' }
    if ($Name -match '\s') { throw "error: project name '$Name' contains whitespace; the registry is whitespace-delimited" }
    if ($Name -match '[\\/]') { throw "error: project name '$Name' contains a path separator; it must be one directory name" }
    if ($Name.StartsWith('.')) { throw "error: project name '$Name' starts with '.'" }
    if ($Name -eq '-') { throw "error: project name '-' collides with the registry's own list marker" }
    $true
}

# Get-FmProjectsDir: this home's projects dir, honouring the same override the
# bash scripts read.
function Get-FmProjectsDir {
    [CmdletBinding()]
    param()
    (Get-FmSessionPaths).Projects
}

# Get-FmProjectLabel: what a project is CALLED in output and in the registry -
# its directory name when it lives in this home's projects dir, and its path
# otherwise. Mirrors fm-fleet-sync.sh's project_label.
function Get-FmProjectLabel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ProjectsDir = ''
    )

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }
    $parent = Split-Path -Parent $Path
    if ($parent -and (Test-FmPathEqual -Left $parent -Right $ProjectsDir)) {
        return (Split-Path -Leaf $Path)
    }
    # "projects/<name>" relative forms carry the same label as the resolved one.
    if ($Path -match '^projects[\\/](?<name>[^\\/]+)[\\/]?$') {
        return $Matches['name']
    }
    $Path
}

# Resolve-FmProjectPath: accept a path (used as-is when it already exists) or a
# bare / "projects/<name>" project name resolved against this home's projects
# dir. Falls back to the original argument unresolved, so a genuinely bad path
# still reaches the caller's own "not a directory" handling instead of being
# silently rewritten into something that does exist.
function Resolve-FmProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Argument,
        [string]$ProjectsDir = ''
    )

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }

    if ($Argument -match '^projects[\\/](?<name>.+)$') {
        $candidate = Join-Path $ProjectsDir $Matches['name']
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        return $Argument
    }
    if ($Argument -match '[\\/]') {
        if (Test-Path -LiteralPath $Argument -PathType Container) { return $Argument }
        return $Argument
    }
    $candidate = Join-Path $ProjectsDir $Argument
    if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    if (Test-Path -LiteralPath $Argument -PathType Container) { return $Argument }
    $Argument
}

# --- the removal preflight ----------------------------------------------------
#
# Project removal is destructive and irreversible, so the preflight is the whole
# safety property: it looks for every kind of work that would be DESTROYED, and
# reports all of them at once rather than stopping at the first, because an
# operator fixing one blocker needs to know about the other three.
#
# What counts as unlanded work depends on whether the clone has a remote. A
# remote-backed clone's work is landed once it is on a remote; a local-only
# clone has no remote to land on, so the test is whether its branches are merged
# into the default branch - the same asymmetry bin/fm-teardown.sh applies to a
# worktree.
function Test-FmProjectRemovable {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$ProjectsDir = '',
        [string]$StateDir = '',
        [string]$DataDir = ''
    )

    if (-not $ProjectsDir) { $ProjectsDir = Get-FmProjectsDir }
    if (-not $StateDir) { $StateDir = (Get-FmSessionPaths).State }
    if (-not $DataDir) { $DataDir = (Get-FmSessionPaths).Data }

    $path = Join-Path $ProjectsDir $Name
    $blockers = @()
    $exists = Test-Path -LiteralPath $path -PathType Container

    # 1. Work firstmate itself still has recorded against this clone. A live or
    #    not-yet-torn-down task points at the worktree pool of this project, and
    #    removing the clone underneath it destroys that task's worktree too.
    if (Test-Path -LiteralPath $StateDir -PathType Container) {
        $pathReal = Resolve-FmPhysicalPathOrRaw -Path $path
        foreach ($meta in @(Get-ChildItem -LiteralPath $StateDir -Filter '*.meta' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $taskProject = Get-FmMetaValue -Path $meta.FullName -Key 'project'
            if (-not $taskProject) { continue }
            if (-not (Test-FmPathEqual -Left (Resolve-FmPhysicalPathOrRaw -Path $taskProject) -Right $pathReal)) { continue }
            $taskId = [System.IO.Path]::GetFileNameWithoutExtension($meta.Name)
            $blockers += "task $taskId is still recorded against this project ($($meta.FullName)); tear it down first"
        }
    }

    # 2. A secondmate that was provisioned with a clone of this project owns
    #    work this home cannot see. Absence from this registry is never evidence
    #    that no second mate holds it, so the routing table is read directly.
    $secondmates = Join-Path $DataDir 'secondmates.md'
    if (Test-Path -LiteralPath $secondmates -PathType Leaf) {
        foreach ($line in (Get-FmSessionFileLines -Path $secondmates)) {
            if ($line -match "(^|[^A-Za-z0-9_-])$([regex]::Escape($Name))([^A-Za-z0-9_-]|$)") {
                $blockers += "data/secondmates.md still references this project: $($line.Trim())"
                break
            }
        }
    }

    if ($exists) {
        $isRepo = (Invoke-FmGit -Directory $path -Arguments @('rev-parse', '--is-inside-work-tree')).Ok
        if ($isRepo) {
            # 3. Linked worktrees. `worktree list --porcelain` always lists the
            #    main worktree, so anything beyond the first is a linked one.
            $worktrees = @((Get-FmGitOutput -Directory $path -Arguments @('worktree', 'list', '--porcelain')) -split "`r?`n" |
                Where-Object { $_ -like 'worktree *' })
            if ($worktrees.Count -gt 1) {
                $others = @($worktrees | Select-Object -Skip 1 | ForEach-Object { $_ -replace '^worktree ', '' })
                $blockers += "$($others.Count) linked worktree(s) still exist: $($others -join ', ')"
            }

            # 4. Uncommitted changes.
            $status = Invoke-FmGit -Directory $path -Arguments @('status', '--porcelain')
            if (-not $status.Ok) {
                $blockers += "cannot inspect $path for uncommitted changes; refusing to remove what cannot be checked"
            } elseif ($status.StdOut.Trim()) {
                $blockers += 'uncommitted changes present in the clone'
            }

            # 5. Commits that exist nowhere else. A repository with no commits
            #    at all has no work to lose, and asking it for a default branch
            #    would report a blocker where there is nothing to protect.
            $hasCommits = (Invoke-FmGit -Directory $path -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')).Ok
            $hasRemote = (Invoke-FmGit -Directory $path -Arguments @('remote', 'get-url', 'origin')).Ok
            if (-not $hasCommits) {
                # nothing committed anywhere; the dirty-tree check above still applies
            } elseif ($hasRemote) {
                $unpushed = @((Get-FmGitOutput -Directory $path -Arguments @('log', '--oneline', '--branches', '--not', '--remotes')) -split "`r?`n" |
                    Where-Object { $_.Trim() })
                if ($unpushed.Count -gt 0) {
                    $shown = @($unpushed | Select-Object -First 5)
                    $blockers += "commits not on any remote:`n" + ($shown -join "`n")
                }
            } else {
                $default = Get-FmGitDefaultBranch -Directory $path
                if (-not $default) {
                    $blockers += "cannot determine the default branch of $path; expected origin/HEAD, main, or master"
                } else {
                    $unmerged = @((Get-FmGitOutput -Directory $path -Arguments @('branch', '--no-merged', $default, '--format=%(refname:short)')) -split "`r?`n" |
                        Where-Object { $_.Trim() })
                    if ($unmerged.Count -gt 0) {
                        $blockers += "this clone has no remote and these branches are not merged into $default`: " +
                            ($unmerged -join ', ')
                    }
                }
            }
        } else {
            $blockers += "$path is not a git repository; removing it would discard whatever it is without any landed-work check"
        }
    }

    [pscustomobject]@{
        Name       = $Name
        Path       = $path
        Exists     = $exists
        Removable  = ($blockers.Count -eq 0)
        Blockers   = $blockers
    }
}

# Remove-FmProjectDirectory: delete a clone, with the retry budget Windows
# needs and the refusal Windows gives us for free.
#
# On Windows a directory cannot be deleted while any process holds a handle
# inside it or has its cwd there - the delete FAILS CLOSED where Linux would
# quietly succeed and strand the holder. Transient holders (an indexer, a virus
# scanner mid-scan) clear on their own, so the delete is retried a bounded
# number of times; a persistent holder is reported and the removal REFUSED,
# which is the correct outcome, not a workaround to route around.
function Remove-FmProjectDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Retries = 3,
        [double]$RetryWaitSeconds = 0.5
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Path, 'remove project clone')) { return $false }

    $attempt = 0
    $lastError = ''
    while ($attempt -le $Retries) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_.Exception.Message
        }
        $attempt++
        if ($attempt -le $Retries) { Start-Sleep -Seconds $RetryWaitSeconds }
    }
    throw ("error: could not remove $Path after $($Retries + 1) attempt(s): $lastError. On Windows a directory " +
        'cannot be deleted while a process holds a handle in it or has its cwd there - close whatever is ' +
        'inside it and retry. Nothing was removed from the registry.')
}
