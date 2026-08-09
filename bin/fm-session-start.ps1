# fm-session-start.ps1 - one command for the whole session start.
#
# Twin: bin/fm-session-start.sh
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required.
#
# COMPOSITION, NOT DUPLICATION: this script calls fm-lock, fm-bootstrap,
# fm-herdr-session-cleanup, fm-wake-drain, fm-guard, fm-supervision-instructions
# and fm-public-followup as real subprocesses and prints their real output. It
# never re-implements their logic; all sequencing/formatting logic added here
# stays local to this file. Every one of those calls goes through
# Invoke-FmScript, which prefers a sibling's .ps1 twin and falls back to its .sh
# under Git Bash - so this file is correct no matter which side of the
# conversion each of those siblings is on, and cutover deletes one branch inside
# fm-common rather than editing call sites here (docs/powershell-port.md
# contract 7).
#
# ORDERING, and why LOCK runs before BOOTSTRAP:
#
#   1. lock           - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only when
#                       this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's five MUTATING sweeps
#                       also run only when locked.
#   3. wake-drain     - mutates the durable wake queue, so it also only runs
#                       when locked.
#   4. supervision    - the emitted operating block for the detected harness.
#   5. context digest - always read-only, always runs.
#   6. fleet digest   - always read-only, always runs.
#   7. closing reminder.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not go
# dark, so on refusal bootstrap still runs in FM_BOOTSTRAP_DETECT_ONLY=1 mode
# for its read-only detect lines, and both digests run unconditionally.
#
# Usage: fm-session-start.ps1
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud banner
#   inline, never a silent failure or a non-zero exit that would make an agent
#   skip the rest of the digest.
#
# ---------------------------------------------------------------------------
# THREE MECHANICS THIS TWIN HAD TO GET RIGHT
#
#   PER-CHILD ENVIRONMENT. The bash twin sets a variable on the command itself
#   (`FM_BOOTSTRAP_DETECT_ONLY=1 fm-bootstrap.sh`), which scopes it to exactly
#   that child. PowerShell has no such form: $env: assignment is PROCESS-wide
#   and would leak into every later child in this digest - including the
#   unlocked-vs-locked bootstrap distinction, which is the whole read-only
#   contract. Invoke-FmChildScript below sets, invokes, and RESTORES, so the
#   scope matches the bash exactly.
#
#   `2>&1` CAPTURE. Invoke-FmScript returns the two streams separately, on
#   purpose. The bash twin merges them, and the digest prints the merged text,
#   so each capture site concatenates stdout then stderr and then strips
#   trailing newlines the way command substitution does.
#
#   PRINTED PATHS ARE POSIX (docs/powershell-port.md contract 3). Everything
#   this digest prints - the home banner, status-log paths, the
#   fm-public-followup pointers - is what an agent copies into a follow-up
#   command that may run in either world, and the bash twin prints /f/... form.
#   Paths this script READS stay native for the .NET APIs.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-tasks-axi-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-public-followup-lib.psm1')

$script:FmRule = '================================================================================'
$script:FmSubrule = '--------------------------------------------------------------------------------'

function Write-FmSection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)
    Write-FmRaw "`n$script:FmRule`n$Title`n$script:FmRule`n"
}

function Write-FmSubsection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title)
    Write-FmRaw "`n$Title`n$script:FmSubrule`n"
}

# The `$(cmd 2>&1)` twin: merged streams, trailing newlines stripped.
function Get-FmMergedOutput {
    param([Parameter(Mandatory)][hashtable]$Result)
    return ($Result.StdOut + $Result.StdErr).TrimEnd("`n")
}

# Run a sibling with per-child environment, then restore. See the header note.
function Invoke-FmChildScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{},
        [string]$BinDir
    )
    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    try {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key])
        }
        return (Invoke-FmScript -Name $Name -Arguments $Arguments -BinDir $BinDir)
    } finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key])
        }
    }
}

# print_file_or_absent: full contents under a labeled subsection, or an explicit
# ABSENT marker. Absence is semantically meaningful for every one of these files
# (captain.md absent = firstmate repo built-in defaults, projects.md absent =
# rebuild from clones - AGENTS.md section 3) and must never be confused with an
# empty-but-present file, so the two cases print differently.
function Write-FmFileOrAbsent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    Write-FmSubsection $Label
    $native = ConvertTo-FmNativePath $Path
    if ([System.IO.File]::Exists($native)) {
        $text = Get-FmFileText $native
        if ($text.Length -gt 0) {
            # `cat` - byte-for-byte, including a missing final newline.
            Write-FmRaw $text
        } else {
            Write-FmOut '(present, empty)'
        }
    } else {
        Write-FmOut 'ABSENT'
    }
}

# `tail -n <n>` on a file whose last line may lack its terminator. Splitting and
# rejoining would silently ADD one, which would then differ from the bash twin
# byte-for-byte, so the terminator is carried with each unit.
function Get-FmTailText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Count
    )
    $text = Get-FmFileText $Path
    if ($text.Length -eq 0) { return '' }
    $parts = @($text.Split("`n"))
    $units = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -lt $parts.Count - 1) {
            $units.Add($parts[$i] + "`n")
        } elseif ($parts[$i] -ne '') {
            $units.Add($parts[$i])
        }
    }
    if ($units.Count -eq 0) { return '' }
    $start = [Math]::Max(0, $units.Count - $Count)
    return -join $units[$start..($units.Count - 1)]
}

# `for f in "$DIR"/*.<ext>` - sorted, and DOT-PREFIXED LEAVES EXCLUDED.
# Both halves matter: a bash glob never matches a leading dot, and state/ is
# full of dot-prefixed internals (.wake-queue, .pr-check-quarantine, the watcher
# records), so a naive enumeration would sweep records the bash twin never sees.
# The extension is re-checked because .NET's search pattern can match longer
# extensions through 8.3 aliasing.
function Get-FmDigestGlob {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Extension
    )
    $native = ConvertTo-FmNativePath $Directory
    $found = [System.Collections.Generic.List[string]]::new()
    if (-not [System.IO.Directory]::Exists($native)) { return @() }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($native, "*$Extension")) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($leaf.StartsWith('.')) { continue }
        if (-not $leaf.EndsWith($Extension, [System.StringComparison]::Ordinal)) { continue }
        $found.Add($file)
    }
    $found.Sort([System.StringComparer]::Ordinal)
    return @($found)
}

function Write-FmStatusTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PrintPath,
        [Parameter(Mandatory)][string]$Count
    )
    # The count is PRINTED as the raw string the environment supplied, exactly
    # as the bash twin prints "$STATUS_TAIL": a caller who set 05 sees 05.
    Write-FmOut "status tail (last $Count line(s), wake-EVENT history, not current state; full log: $PrintPath):"
    Write-FmRaw (Get-FmTailText -Path $Path -Count ([int]$Count))
}

function Write-FmBacklogPointer {
    Write-FmOut 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.'
}

# The awk twin. `state` PERSISTS across lines, and a heading that is not one of
# the three known sections sets it EMPTY - so items under an unknown heading are
# counted by neither branch and the heading itself is not printed.
function Write-FmBacklogManualCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Limit
    )
    Write-FmOut "compact backlog listing ($Reason; max $Limit item(s); indented task bodies omitted)"
    $sectionState = ''
    $total = 0
    $shown = 0
    foreach ($line in (Get-FmFileLines $Path)) {
        if ($line -cmatch '^##[ \t\v\f\r]+') {
            $heading = ($line -creplace '^##[ \t\v\f\r]+', '') -creplace '[ \t\v\f\r]+$', ''
            $sectionState = switch -CaseSensitive ($heading) {
                'In flight' { 'in_flight' }
                'Queued' { 'queued' }
                'Done' { 'done' }
                default { '' }
            }
            if ($sectionState -ne '') { Write-FmOut $line }
            continue
        }
        if ($sectionState -ne '' -and $line -cmatch '^[-*][ \t\v\f\r]+') {
            $total++
            if ($shown -lt [int]$Limit) {
                Write-FmOut $line
                $shown++
            }
            continue
        }
    }
    if ($total -eq 0) {
        Write-FmOut '(no backlog item title lines found)'
    } else {
        Write-FmOut "(shown $shown of $total backlog item title line(s))"
        if ($total -gt $shown) {
            Write-FmOut "(truncated $($total - $shown) item(s); increase FM_SESSION_START_BACKLOG_LIMIT for a larger startup listing)"
        }
    }
}

function Write-FmBacklogTasksAxiCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Limit
    )
    Write-FmOut "compact backlog listing (tasks-axi; max $Limit item(s); task bodies omitted)"
    $cmd = Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $result = if ($null -eq $cmd) {
        @{ ExitCode = 127; StdOut = ''; StdErr = 'tasks-axi: not found'; Ok = $false }
    } else {
        Invoke-FmTool -FilePath $cmd.Source -Arguments @(
            'list', '--file', (ConvertTo-FmNativePath $Path),
            '--limit', $Limit,
            '--fields', 'blocked_by,hold_kind,hold_reason')
    }
    $out = ($result.StdOut + $result.StdErr).TrimEnd("`n")
    if ($result.ExitCode -eq 0) {
        Write-FmOut $out
    } else {
        Write-FmOut 'tasks-axi compact listing failed; falling back to title-line rendering.'
        Write-FmOut $out
        Write-FmBacklogManualCompact -Path $Path -Reason 'fallback' -Limit $Limit
    }
}

function Write-FmBacklogCompact {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Limit
    )
    Write-FmSubsection $Label
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $Path))) {
        if ((Get-FmFileText $Path).Length -gt 0) {
            if (Test-FmTasksAxiBackendAvailable $ConfigDir) {
                Write-FmBacklogTasksAxiCompact -Path $Path -Limit $Limit
            } elseif (Test-FmBacklogBackendManual $ConfigDir) {
                Write-FmBacklogManualCompact -Path $Path -Reason 'manual backend' -Limit $Limit
            } else {
                Write-FmBacklogManualCompact -Path $Path -Reason 'tasks-axi unavailable or incompatible' -Limit $Limit
            }
            Write-FmBacklogPointer
        } else {
            Write-FmOut '(present, empty)'
        }
    } else {
        Write-FmOut 'ABSENT'
    }
}

# hash_file: shasum -a 256, else sha256sum, else cksum. When either sha tool is
# present the digest is computed IN-PROCESS - the bytes and therefore the
# "sha256:<hex>" line are identical, and this avoids a child process on a host
# where a fork costs 0.36-3.1s. cksum has no in-process equivalent worth
# writing, so that last fallback still shells out. A missing file or a host with
# none of the three yields '' , which is what `$(hash_file ... || printf '')`
# leaves the caller.
function Get-FmDigestFileHash {
    param([Parameter(Mandatory)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    if (-not [System.IO.File]::Exists($native)) { return '' }
    if ((Test-FmCommand 'shasum') -or (Test-FmCommand 'sha256sum')) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash([System.IO.File]::ReadAllBytes($native))
        } finally {
            $sha.Dispose()
        }
        $builder = [System.Text.StringBuilder]::new('sha256:')
        foreach ($b in $bytes) { [void]$builder.Append($b.ToString('x2')) }
        return $builder.ToString()
    }
    if (-not (Test-FmCommand 'cksum')) { return '' }
    $result = Invoke-FmTool -FilePath 'cksum' -Arguments @($native)
    if (-not $result.Ok) { return '' }
    $fields = @($result.StdOut.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 2) { return '' }
    return "cksum:$($fields[0]):$($fields[1])"
}

function Test-FmPiExtensionLoaded {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Marker,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedVersion,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Lock
    )
    if ([string]::IsNullOrEmpty($ExpectedVersion)) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Marker))) { return $false }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $Lock))) { return $false }
    $markerLines = @(Get-FmFileLines $Marker)
    $lockLines = @(Get-FmFileLines $Lock)
    # `sed -n '1p'` / `sed -n '2p'` on a short file print nothing.
    $markerVersion = if ($markerLines.Count -ge 1) { $markerLines[0] } else { '' }
    $markerPid = if ($markerLines.Count -ge 2) { $markerLines[1] } else { '' }
    $lockPid = if ($lockLines.Count -ge 1) { $lockLines[0] } else { '' }
    if ([string]::IsNullOrEmpty($markerPid)) { return $false }
    return (($markerVersion -ceq $ExpectedVersion) -and ($markerPid -ceq $lockPid))
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot
    $binDir = $ctx.ScriptRoot
    $state = $ctx.State
    $data = $ctx.Data
    $config = $ctx.Config
    $printRoot = ConvertTo-FmPosixPath $ctx.Root
    $printHome = $ctx.PosixHome
    $printState = ConvertTo-FmPosixPath $state

    $harnessProbe = Invoke-FmScript -Name 'fm-harness' -BinDir $binDir
    $primaryHarness = if ($harnessProbe.Ok) { $harnessProbe.StdOut.TrimEnd("`n") } else { 'unknown' }
    if ([string]::IsNullOrEmpty($primaryHarness)) { $primaryHarness = 'unknown' }

    $statusTail = Get-FmEnv 'FM_SESSION_START_STATUS_TAIL' '5'
    if ($statusTail -notmatch '^[0-9]+$') { $statusTail = '5' }
    $backlogLimit = Get-FmEnv 'FM_SESSION_START_BACKLOG_LIMIT' '80'
    # `''|*[!0-9]*|0` - a non-numeric OR literally "0" both fall back to 80.
    if ($backlogLimit -notmatch '^[0-9]+$' -or $backlogLimit -ceq '0') { $backlogLimit = '80' }

    Write-FmSection "SESSION START - $printHome"

    # --- 1. lock ------------------------------------------------------------
    Write-FmSubsection 'LOCK'
    $lockResult = Invoke-FmScript -Name 'fm-lock' -BinDir $binDir
    $lockOut = Get-FmMergedOutput $lockResult
    Write-FmOut $lockOut
    $readOnly = 0
    if (-not $lockResult.Ok) {
        $readOnly = 1
        $bar = '●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        Write-FmOut $bar
        Write-FmOut '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED'
        Write-FmOut "●  $lockOut"
        Write-FmOut '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,'
        Write-FmOut '●  secondmate sync, X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap'
        Write-FmOut '●  diagnostics and the rest of this read-only-safe digest still ran below.'
        Write-FmOut '●  Operate read-only until this resolves - do not spawn, steer, merge, or'
        Write-FmOut '●  otherwise mutate fleet state from this session.'
        Write-FmOut $bar
    }

    # --- 2. bootstrap -------------------------------------------------------
    Write-FmSubsection 'BOOTSTRAP'
    if ($readOnly -eq 1) {
        $bootResult = Invoke-FmChildScript -Name 'fm-bootstrap' -BinDir $binDir `
            -Environment @{ FM_BOOTSTRAP_DETECT_ONLY = '1' }
        $bootOut = Get-FmMergedOutput $bootResult
    } else {
        # The bash runs both inside ONE command substitution, so the cleanup's
        # output precedes bootstrap's in a single buffer and its failure is
        # swallowed (`|| true`).
        $cleanupResult = Invoke-FmScript -Name 'fm-herdr-session-cleanup' -BinDir $binDir
        $bootResult = Invoke-FmScript -Name 'fm-bootstrap' -BinDir $binDir
        $combined = $cleanupResult.StdOut + $cleanupResult.StdErr + $bootResult.StdOut + $bootResult.StdErr
        $bootOut = $combined.TrimEnd("`n")
    }
    if ($bootOut.Length -gt 0) {
        Write-FmOut $bootOut
    } else {
        Write-FmOut '(silent - all good)'
    }

    # --- 3. wake-drain ------------------------------------------------------
    # Drained records are this turn's first work queue (AGENTS.md section 8); the
    # drain also runs fm-guard internally on the locked path, so the
    # tangle/watcher-liveness alarms land right here too. The read-only path
    # never touches the queue because it lacks mutation authority, and another
    # session may be actively draining it. It still runs fm-guard directly with
    # non-mutating advisory text, so the same alarms surface without repair
    # commands.
    Write-FmSubsection 'WAKE QUEUE'
    if ($readOnly -eq 1) {
        $queuePath = Join-Path $state '.wake-queue'
        $qlen = 0
        $queueText = Get-FmFileText $queuePath
        if ($queueText.Length -gt 0) {
            # `grep -c .` counts NON-EMPTY lines, not all lines.
            foreach ($line in (Get-FmFileLines $queuePath)) {
                if ($line -ne '') { $qlen++ }
            }
        }
        Write-FmOut "skipped (read-only session) - $qlen record(s) remain queued because this session lacks verified fleet-lock ownership."
        $guardResult = Invoke-FmChildScript -Name 'fm-guard' -BinDir $binDir `
            -Environment @{ FM_GUARD_READ_ONLY = '1' }
        $guardOut = Get-FmMergedOutput $guardResult
        if ($guardOut.Length -gt 0) { Write-FmOut $guardOut }
    } else {
        $drainResult = Invoke-FmScript -Name 'fm-wake-drain' -BinDir $binDir
        $drainOut = Get-FmMergedOutput $drainResult
        if ($drainOut.Length -gt 0) {
            Write-FmOut $drainOut
        } else {
            Write-FmOut '(no queued wakes)'
        }
    }

    # --- 4. supervision operating instructions ------------------------------
    $afkPresent = 0
    $afkPath = ConvertTo-FmNativePath (Join-Path $state '.afk')
    if ([System.IO.File]::Exists($afkPath) -or [System.IO.Directory]::Exists($afkPath)) { $afkPresent = 1 }
    $xModeEnvPath = ConvertTo-FmNativePath (Join-Path $config 'x-mode.env')
    $xModePresent = 0
    if ([System.IO.File]::Exists($xModeEnvPath)) { $xModePresent = 1 }

    if ($primaryHarness -ceq 'pi' -or $primaryHarness -ceq 'pi-signed') {
        $piExt = "$printRoot/.pi/extensions/fm-primary-pi-watch.ts"
        $piTurnendExt = "$printRoot/.pi/extensions/fm-primary-turnend-guard.ts"
        $piWatchMarker = Join-Path $state '.pi-watch-extension-loaded'
        $piTurnendMarker = Join-Path $state '.pi-turnend-extension-loaded'
        $piLock = Join-Path $state '.lock'
        $piRestartCommand = if ($primaryHarness -cne 'pi') { 'plain pi' } else { $primaryHarness }
        $piWatchVersion = Get-FmDigestFileHash (Join-Path $ctx.Root '.pi/extensions/fm-primary-pi-watch.ts')
        $piTurnendVersion = Get-FmDigestFileHash (Join-Path $ctx.Root '.pi/extensions/fm-primary-turnend-guard.ts')
        if ((-not (Test-FmPiExtensionLoaded $piWatchMarker $piWatchVersion $piLock)) -or
            (-not (Test-FmPiExtensionLoaded $piTurnendMarker $piTurnendVersion $piLock))) {
            Write-FmOut ("PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart $piRestartCommand so $piTurnendExt and $piExt auto-load for turn-end guard and background wake coverage; use -e $piTurnendExt -e $piExt only if project hooks are not trusted")
        }
    }

    $superResult = Invoke-FmScript -Name 'fm-supervision-instructions' -BinDir $binDir -Arguments @(
        '--harness', $primaryHarness,
        '--read-only', [string]$readOnly,
        '--afk', [string]$afkPresent,
        '--x-mode', [string]$xModePresent
    )
    Write-FmRaw $superResult.StdOut
    if ($superResult.StdErr.Length -gt 0) { Write-FmRaw $superResult.StdErr }

    # --- 5. context digest ---------------------------------------------------
    Write-FmSection 'CONTEXT'
    Write-FmFileOrAbsent (Join-Path $data 'projects.md') 'data/projects.md'
    Write-FmFileOrAbsent (Join-Path $data 'secondmates.md') 'data/secondmates.md'
    Write-FmFileOrAbsent (Join-Path $data 'captain.md') 'data/captain.md'
    Write-FmFileOrAbsent (Join-Path $data 'captain-shared.md') 'data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)'
    Write-FmFileOrAbsent (Join-Path $data 'learnings.md') 'data/learnings.md'

    # --- 6. fleet-state digest ----------------------------------------------
    Write-FmSection 'FLEET STATE'
    Write-FmBacklogCompact -Path (Join-Path $data 'backlog.md') -Label 'data/backlog.md' `
        -ConfigDir $config -Limit $backlogLimit

    Write-FmSubsection 'Work under way (state/*.meta)'
    $metaFound = $false
    foreach ($meta in (Get-FmDigestGlob $state '.meta')) {
        $metaFound = $true
        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta)
        Write-FmRaw "`n--- $id ---`n"
        Write-FmRaw (Get-FmFileText $meta)

        $window = Get-FmMetaValue -MetaPath $meta -Key 'window'
        $target = Get-FmBackendTargetOfMeta $meta
        if (-not [string]::IsNullOrEmpty($window)) {
            $backend = Get-FmBackendOfMeta $meta
            $probeTarget = if ([string]::IsNullOrEmpty($target)) { $window } else { $target }
            if (Test-FmBackendTargetExists $backend $probeTarget "fm-$id") {
                Write-FmOut "endpoint: alive (backend=$backend window=$window)"
            } else {
                Write-FmOut "endpoint: dead (backend=$backend window=$window)"
            }
        } else {
            Write-FmOut 'endpoint: unknown (no window recorded)'
        }

        $statusPath = Join-Path $state "$id.status"
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath $statusPath))) {
            Write-FmStatusTail -Path $statusPath -PrintPath "$printState/$id.status" -Count $statusTail
        } else {
            Write-FmOut "status tail: (no status file yet: $printState/$id.status)"
        }
    }
    if (-not $metaFound) { Write-FmOut '(none)' }

    Write-FmSubsection 'Orphan status logs (state/*.status without matching .meta)'
    $orphanFound = $false
    foreach ($status in (Get-FmDigestGlob $state '.status')) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($status)
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath (Join-Path $state "$id.meta")))) { continue }
        $orphanFound = $true
        Write-FmRaw "`n--- $id ---`n"
        Write-FmStatusTail -Path $status -PrintPath "$printState/$id.status" -Count $statusTail
    }
    if (-not $orphanFound) { Write-FmOut '(none)' }

    Write-FmSubsection 'AFK'
    if ($afkPresent -eq 1) {
        Write-FmOut 'present - away-mode supervision is active; the daemon owns the watcher.'
    } else {
        Write-FmOut 'absent'
    }

    # Public commitments made through the myfirstmate relay. A promise to reply
    # in a public thread must survive compaction and restart, so it is surfaced
    # from disk here rather than from conversation memory. A home that never
    # opted into the relay runs one existence test, prints no subsection, and
    # never reaches fm-public-followup.
    if ((Test-FmPfRelayActive $ctx.Home) -and
        ((Test-FmPfHasRegistration $state) -or (Test-FmPfHasEvent $state))) {
        $pfResult = Invoke-FmScript -Name 'fm-public-followup' -BinDir $binDir -Arguments @('pending')
        $publicFollowup = if ($pfResult.Ok) { $pfResult.StdOut.TrimEnd("`n") } else { '' }
        if ($publicFollowup.Length -gt 0) {
            Write-FmSubsection 'Public commitments awaiting delivery'
            Write-FmOut $publicFollowup
            Write-FmRaw "`nEach line is a public reply this home still owes. Reconcile terminal results with`n"
            Write-FmOut "$printRoot/bin/fm-public-followup.sh consume, then deliver a ready one with"
            Write-FmOut "$printRoot/bin/fm-public-followup.sh deliver <id>. Load fmx-respond for the procedure."
        }
    }

    # --- 7. closing reminder -------------------------------------------------
    Write-FmSection 'NEXT STEP'
    if ($readOnly -eq 1) {
        Write-FmRaw @"
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.


"@
    } elseif ($afkPresent -eq 1) {
        Write-FmRaw @"
Away mode is active. Follow the supervision operating instructions block above:
load /afk and ensure the daemon is running, because the daemon owns watcher
supervision.


"@
    } elseif ($xModePresent -eq 1) {
        Write-FmRaw @"
Follow the supervision operating instructions block above for harness '$primaryHarness'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.


"@
    } else {
        Write-FmRaw @"
Follow the supervision operating instructions block above for harness '$primaryHarness'.
This script never starts supervision itself.


"@
    }
    Write-FmRaw @"
The digest above is complete for this session start. Do NOT re-read
data/projects.md, data/secondmates.md, data/captain.md,
data/captain-shared.md, data/learnings.md,
or state/*.meta now - they were just printed in full.
Do NOT bulk-read data/backlog.md now either: the compact identity/metadata
listing was just printed with a pointer for targeted full-body follow-up.
Do NOT bulk-read state/*.status now either: their bounded tails were just
printed with full log paths for targeted follow-up when older wake-event
history is actually needed. Re-reading everything defeats the entire point
of this command. Re-read a file only if this digest flagged it ABSENT (then
rebuild or create it per AGENTS.md), its contents looked unparseable/corrupt,
or an individual full status log is needed for older wake-event history.

"@

    Exit-FmScript 0
}
