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

# Resolve the effective backlog configuration for a home: which file, which
# archive, and how many Done rows to keep. Precedence matches tasks-axi:
# explicit -File, then TASKS_AXI_FILE, then the project .tasks.toml, then the
# home ~/.tasks-axi/config.toml, then the first existing default candidate.
function Get-FmBacklogConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Root,
        [string]$Path,
        [string]$HomeConfigPath
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
    if ([string]::IsNullOrEmpty($explicit) -and -not [string]::IsNullOrEmpty($env:TASKS_AXI_FILE)) {
        $explicit = $env:TASKS_AXI_FILE
    }

    $chosen = $explicit
    if ([string]::IsNullOrEmpty($chosen)) {
        $chosen = if (-not [string]::IsNullOrEmpty($projectToml.Path)) { $projectToml.Path } else { $homeToml.Path }
    }
    $resolved = ''
    if (-not [string]::IsNullOrEmpty($chosen)) {
        $resolved = if ([System.IO.Path]::IsPathRooted($chosen)) { $chosen } else { Join-Path $Root $chosen }
    } else {
        # data/ FIRST, and as the default. AGENTS.md section 10 makes
        # data/backlog.md this home's durable queue, and it is the exact path the
        # session-start digest reads, teardown names, and a Linux firstmate
        # sharing the home writes. Resolving the bare root copy first meant a
        # home with no backlog yet created one at the root that NOTHING ever read
        # back - the digest reported the queue absent while items accumulated
        # beside it, and because the root candidate then won every later lookup,
        # the split was permanent rather than self-correcting.
        #
        # The root candidate stays, second, so a home that already carries one -
        # tasks-axi's own default shape for a plain project - keeps resolving to
        # the file it has instead of being silently replaced by a new empty one.
        foreach ($candidate in @((Join-Path 'data' 'backlog.md'), 'backlog.md')) {
            $full = Join-Path $Root $candidate
            if (Test-Path -LiteralPath $full -PathType Leaf) { $resolved = $full; break }
        }
        if ([string]::IsNullOrEmpty($resolved)) { $resolved = Join-Path $Root 'data' 'backlog.md' }
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
