#requires -Version 7.0
<#
    The backlog area's exported surface beyond the task verbs: the backend
    selection probe, the on-disk config, and the retention prune.

    These four were written in Private/FmBacklog.ps1 and called directly by
    bin/fm-backlog.ps1, which is exactly what this repo forbids - an entry point
    may only call EXPORTED functions, because a private helper stops resolving
    the moment the manifest governs the import rather than a dot-source. It
    worked only because fm-backlog.ps1 dot-sources the whole tree through
    bin/fm-module-load.ps1. The module-assembly suite's exported-only check
    found it when the install area landed; the fix is to publish them, since
    `fm-backlog.ps1 prune` and `fm-backlog.ps1 backend` are part of the
    documented command surface and their implementations belong on it.

    Moved verbatim, not reimplemented: there is still exactly one copy of each.
#>

Set-StrictMode -Version Latest

# config/backlog-backend: absent or "tasks-axi" selects the default tasks-axi
# backend; "manual" forces firstmate's own hand-editing path. Any other value is
# returned verbatim so a caller can report it rather than silently defaulting.
function Get-FmBacklogBackend {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $file = Join-Path $ConfigDir 'backlog-backend'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 'tasks-axi' }
    $value = ''
    try { $value = ([System.IO.File]::ReadAllText($file) -replace '\s', '') } catch { return 'tasks-axi' }
    if ([string]::IsNullOrEmpty($value)) { return 'tasks-axi' }
    $value
}

# True when routine firstmate backlog mutations should go through tasks-axi.
# `manual` opts out regardless of what is installed.
function Test-FmTasksAxiBackendAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ConfigDir)

    if (Test-FmBacklogBackendManual -ConfigDir $ConfigDir) { return $false }
    Test-FmTasksAxiCompatible
}

# Move a pre-fix root-level backlog into the canonical data/backlog.md, or
# report the one case that must not be decided here.
#
# WHY MIGRATE RATHER THAN REFUSE. A home whose only backlog is <home>/backlog.md
# holds real captain work items that every reader in this port - the session
# digest, cleanup, a Linux firstmate sharing the home - looks for somewhere
# else. Refusing would leave firstmate unusable until someone moved a file by
# hand, and the items invisible in the meantime; that is the same loss, with an
# error message on top. The move is one rename into the location everything
# already reads, it preserves the file's bytes, and it is reported rather than
# silent.
#
# WHY REFUSE WHEN BOTH EXIST. Two files then hold two real queues, and merging
# them is a judgement about which items are current - the captain's call, not a
# migration's. So that case is named with both paths and refused, which is the
# only outcome here that stops work rather than continuing it.
#
# The Done archive moves with its backlog. The archive is derived as the
# backlog's sibling, so a root-resolved home put it at <home>/done-archive.md;
# leaving it behind would orphan the completed-work history the moment the queue
# moved, which is the same defect one directory over.
function Repair-FmBacklogLocation {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param([string]$HomePath)

    $splat = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and -not [string]::IsNullOrEmpty($HomePath)) {
        $splat['HomePath'] = $HomePath
    }
    $canonical = Get-FmBacklogPath @splat
    $legacy = Get-FmBacklogLegacyPath @splat

    $result = {
        param($Action, $Message, $ArchiveMoved)
        [pscustomobject]@{
            Action       = $Action
            Path         = $canonical
            LegacyPath   = $legacy
            ArchiveMoved = [bool]$ArchiveMoved
            Message      = $Message
        }
    }

    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf)) { return & $result 'none' '' $false }
    if (Test-FmPathEqual -Left $canonical -Right $legacy) { return & $result 'none' '' $false }

    if (Test-Path -LiteralPath $canonical -PathType Leaf) {
        return & $result 'conflict' ("two backlogs in this home: $legacy is the pre-fix location and $canonical is " +
            'the one firstmate reads. Both hold work items, so nothing here decides which is current: move the ' +
            "items you still want into $canonical, then delete $legacy.") $false
    }

    # A held lock means another writer is mid-mutation on the legacy file.
    # Moving it out from under them would be the one way this repair could lose
    # an item, so it waits for the next call instead.
    if (Test-Path -LiteralPath "$legacy.lock") {
        return & $result 'conflict' ("the pre-fix backlog $legacy is locked by another process ($legacy.lock), so it " +
            'cannot be moved safely. Retry once that command has finished.') $false
    }

    if (-not $PSCmdlet.ShouldProcess($legacy, "move to $canonical")) { return & $result 'none' '' $false }

    New-FmDirectory -Path (Split-Path -Parent $canonical)
    Move-Item -LiteralPath $legacy -Destination $canonical
    $archiveMoved = $false
    $legacyArchive = Join-Path (Split-Path -Parent $legacy) 'done-archive.md'
    $canonicalArchive = Join-Path (Split-Path -Parent $canonical) 'done-archive.md'
    if ((Test-Path -LiteralPath $legacyArchive -PathType Leaf) -and
        -not (Test-Path -LiteralPath $canonicalArchive -PathType Leaf)) {
        Move-Item -LiteralPath $legacyArchive -Destination $canonicalArchive
        $archiveMoved = $true
    }

    $message = "moved the backlog from $legacy to $canonical" +
        $(if ($archiveMoved) { ", and its done-archive.md with it" } else { '' })
    Write-Warning "backlog: $message (it was created in the pre-fix location, where nothing else reads it)."
    & $result 'migrated' $message $archiveMoved
}

# Resolve the effective backlog configuration for a home: which file, which
# archive, and how many Done rows to keep. Precedence matches tasks-axi:
# explicit -File, then TASKS_AXI_FILE, then the project .tasks.toml, then the
# home ~/.tasks-axi/config.toml, then Get-FmBacklogPath.
#
# This is the single seam every read and every mutation goes through to find the
# file, which is why the legacy reconciliation is called from here rather than
# left to callers - the split it repairs was caused by more than one place
# answering this question. It is the one thing here that can write, and it does
# so only to move a file into the location every reader already uses.
#
# -IgnoreEnvironment drops TASKS_AXI_FILE from that precedence, and exists for
# the one kind of caller that must not honour it: a question about a home OTHER
# than the one this process is operating. TASKS_AXI_FILE is process-wide, so a
# secondmate retirement asking "does that home have work in flight?" under an
# operator's override would read the override's file - most likely this home's -
# and answer about the wrong home entirely. A verdict that decides whether a home
# is deleted reads that home's own record or it does not run.
function Get-FmBacklogConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Root,
        [string]$Path,
        [string]$HomeConfigPath,
        [switch]$IgnoreEnvironment
    )

    if ([string]::IsNullOrEmpty($Root)) { $Root = Get-FmHome }
    if ([string]::IsNullOrEmpty($HomeConfigPath)) {
        $HomeConfigPath = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.tasks-axi' 'config.toml'
    }

    $homeToml = [pscustomobject]@{ Backend = ''; Path = ''; Archive = ''; DoneKeep = $null }
    if (Test-Path -LiteralPath $HomeConfigPath -PathType Leaf) {
        $homeToml = ConvertFrom-FmBacklogConfigToml -Text ([System.IO.File]::ReadAllText($HomeConfigPath))
    }
    $projectTomlPath = Join-Path $Root '.tasks.toml'
    $projectToml = [pscustomobject]@{ Backend = ''; Path = ''; Archive = ''; DoneKeep = $null }
    if (Test-Path -LiteralPath $projectTomlPath -PathType Leaf) {
        $projectToml = ConvertFrom-FmBacklogConfigToml -Text ([System.IO.File]::ReadAllText($projectTomlPath))
    }

    $explicit = $Path
    if ([string]::IsNullOrEmpty($explicit) -and -not $IgnoreEnvironment -and
        -not [string]::IsNullOrEmpty($env:TASKS_AXI_FILE)) {
        $explicit = $env:TASKS_AXI_FILE
    }

    $chosen = $explicit
    if ([string]::IsNullOrEmpty($chosen)) {
        $chosen = if (-not [string]::IsNullOrEmpty($projectToml.Path)) { $projectToml.Path } else { $homeToml.Path }
    }
    # The default is Get-FmBacklogPath and nothing else. It used to be a probe -
    # "<home>/backlog.md if it exists, else <home>/data/backlog.md, else create
    # <home>/backlog.md" - which in a fresh home resolved to the root file while
    # every other reader in the port, and the Linux firstmate, read
    # data/backlog.md. Two owners of one path is the defect; a probe that
    # PREFERS the wrong one is how it stayed invisible.
    #
    # An explicit -Path, TASKS_AXI_FILE, or a .tasks.toml pin still wins, because
    # that precedence is tasks-axi's and a home shared with a Linux firstmate
    # must resolve the same file both tools do.
    $resolved = ''
    if (-not [string]::IsNullOrEmpty($chosen)) {
        $resolved = if ([System.IO.Path]::IsPathRooted($chosen)) { $chosen } else { Join-Path $Root $chosen }
    } else {
        $resolved = Get-FmBacklogPath -HomePath $Root
    }
    # Normalize whatever branch produced it, so a toml-pinned "data/backlog.md"
    # and Get-FmBacklogPath are the SAME string - the lock path, the archive
    # sibling, and the canonical-location comparison below all key off it.
    $resolved = Resolve-FmFullPath -Path $resolved

    # NOT A PROBE, and specifically not "data/backlog.md first, <home>/backlog.md
    # second". That ordering fixes a FRESH home and leaves an already-split one
    # split: the resolver would keep reading <home>/backlog.md while the
    # session-start digest, teardown and a Linux firstmate sharing the home all
    # read data/backlog.md unconditionally, so the digest would go on reporting
    # the queue absent with the captain's items in it. The homes that need the
    # fix most are exactly the ones that already ran the old code, so the
    # location is single-sourced and the stale file is MOVED to it instead.
    #
    # The concern behind that ordering - never silently replace a real queue with
    # a new empty one - is not dropped, it is met more strongly: the migration
    # below moves the existing file rather than creating a second one, so the
    # captain's items arrive at the canonical path instead of being orphaned
    # beside it.
    #
    # Reconcile a pre-fix root-level backlog before anyone reads or writes this
    # home's queue. Only when the resolved file IS the canonical location: a
    # home that deliberately pins somewhere else has not lost anything here, and
    # moving a file it never named would be the surprise, not the fix. That pin
    # is also the escape hatch for the one root-level layout that is legitimate
    # rather than stale - tasks-axi's own default shape for a plain project -
    # because -Root here is a FIRSTMATE HOME: every production caller leaves it
    # to Get-FmHome, and a project's queue is never resolved through this seam.
    if (Test-FmPathEqual -Left $resolved -Right (Get-FmBacklogPath -HomePath $Root)) {
        $repair = Repair-FmBacklogLocation -HomePath $Root
        if ($repair.Action -eq 'conflict') { throw $repair.Message }
    }

    $archive = if (-not [string]::IsNullOrEmpty($projectToml.Archive)) { $projectToml.Archive } else { $homeToml.Archive }
    $archivePath = if (-not [string]::IsNullOrEmpty($archive)) {
        if ([System.IO.Path]::IsPathRooted($archive)) { $archive } else { Join-Path $Root $archive }
    } else {
        Join-Path (Split-Path -Parent $resolved) 'done-archive.md'
    }

    $doneKeep = 10
    if ($null -ne $projectToml.DoneKeep) { $doneKeep = $projectToml.DoneKeep }
    elseif ($null -ne $homeToml.DoneKeep) { $doneKeep = $homeToml.DoneKeep }
    if ($doneKeep -lt 0) { throw 'markdown.done_keep must be a non-negative integer' }

    $backend = if (-not [string]::IsNullOrEmpty($projectToml.Backend)) { $projectToml.Backend }
    elseif (-not [string]::IsNullOrEmpty($homeToml.Backend)) { $homeToml.Backend }
    else { 'markdown' }

    [pscustomobject]@{
        Backend     = $backend
        Path        = $resolved
        ArchivePath = $archivePath
        DoneKeep    = $doneKeep
    }
}

# Keep only the configured most recent Done rows, appending the surplus to the
# archive. The surplus keeps its ORIGINAL lines when it has them, so archiving
# never rewrites a historical record's prose. An active public-followup
# obligation is never counted and never archived.
function Invoke-FmBacklogPrune {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Keep,
        [string]$ArchivePath = '',
        [switch]$NoArchive,
        [string]$State = 'done',
        [string]$Date = ''
    )

    if ($Keep -lt 0) { $Keep = 0 }
    $archived = [System.Collections.Generic.List[string]]::new()
    $archiveLines = [System.Collections.Generic.List[string]]::new()

    $lock = Enter-FmBacklogLock -Path $Path
    try {
        $source = Get-FmBacklogSource -Path $Path
        $document = ConvertFrom-FmBacklogMarkdown -Text $(if ($null -eq $source) { '' } else { $source })

        $section = $null
        foreach ($candidate in $document.Sections) { if ($candidate.State -eq $State) { $section = $candidate; break } }
        if ($null -eq $section) { return [pscustomobject]@{ Archived = 0; Ids = @() } }

        $indexes = [System.Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $section.Entries.Count; $i++) {
            $entry = $section.Entries[$i]
            if ($entry.Kind -ne 'task') { continue }
            if (-not (Test-FmBacklogPublicFollowupTerminal -Task $entry.Task)) { continue }
            $indexes.Add($i)
        }
        if ($indexes.Count -le $Keep) { return [pscustomobject]@{ Archived = 0; Ids = @() } }

        $surplus = @($indexes[$Keep..($indexes.Count - 1)])
        foreach ($index in $surplus) {
            $entry = $section.Entries[$index]
            $archived.Add($entry.Task.Id)
            $lines = if ($entry.Raw.Count -gt 0) { $entry.Raw } else { Get-FmBacklogTaskLine -Task $entry.Task }
            foreach ($line in $lines) { $archiveLines.Add($line) }
        }
        # Remove from the bottom up so earlier indexes stay valid.
        foreach ($index in ($surplus | Sort-Object -Descending)) {
            Remove-FmBacklogSectionEntry -Section $section -Index $index
        }

        # The archive is appended BEFORE the backlog is rewritten, and rolled back
        # to its previous size if that rewrite fails, so a failed prune never
        # leaves a record in two places or in none.
        $restore = $null
        if (-not $NoArchive) {
            if ([string]::IsNullOrEmpty($ArchivePath)) {
                $ArchivePath = Join-Path (Split-Path -Parent $Path) 'done-archive.md'
            }
            $current = Get-FmBacklogSource -Path $Path
            if ($current -ne $source) { throw 'Backlog changed on disk; retry the command' }
            $restore = Get-FmBacklogArchiveRestorePoint -Path $ArchivePath
            $stamp = if ([string]::IsNullOrEmpty($Date)) { Get-FmBacklogToday } else { $Date }
            Add-FmBacklogArchiveBlock -Path $ArchivePath -Line @($archiveLines) -Stamp $stamp
        }
        try {
            Save-FmBacklogDocument -Path $Path -Document $document -ExpectedSource $source
        } catch {
            if ($null -ne $restore) { Restore-FmBacklogArchive -Point $restore }
            throw
        }
        [pscustomobject]@{ Archived = $archived.Count; Ids = @($archived) }
    } finally {
        Exit-FmBacklogLock -Lock $lock
    }
}
