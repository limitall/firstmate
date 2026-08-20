#requires -Version 7.0
# FmSessionStart.ps1 - the startup digest, ported from bin/fm-session-start.sh.
#
# COMPOSITION, NOT DUPLICATION. Exactly like the bash original, this file owns
# sequencing and formatting only. Lock acquisition, the wake drain, the guard,
# the supervision block, the deferred network stage, and backend probes are owned
# by other areas of this module. They are resolved by name at call time through
# Resolve-FmSessionCommand, so this file loads and runs before those areas exist
# and degrades to an explicit, loud "not available" line instead of pretending a
# step ran. The names it expects are listed in docs/session-start.md.
#
# ORDERING is the contract the captain reads, so the nine stages, their headings,
# their rules, and their wording are kept byte-for-byte with the bash digest:
#   lock, bootstrap, wake-queue, supervision-instructions, read-once,
#   fleet-state, network-checks, context, next-step.
#
# This file also carries the small shared internals used by FmBootstrap.ps1,
# FmHooks.ps1, and FmProject.ps1 (path resolution, optional-command resolution,
# .meta reads, the per-line cap, LF-only file writes). They live here because
# this is the anchor file of the session-start area and the module loader
# dot-sources every Private/*.ps1 before any of them is called.

# --- shared internals ---------------------------------------------------------

# Resolve this home's effective paths from the same environment contract the
# bash scripts use, so a Linux firstmate and this one address identical files.
function Get-FmSessionPaths {
    [CmdletBinding()]
    param()

    $root = $env:FM_ROOT_OVERRIDE
    if ([string]::IsNullOrEmpty($root)) {
        # module/Firstmate/Private/<this file> -> repo root is three levels up.
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..')).Path
    }
    $home_ = $env:FM_HOME
    if ([string]::IsNullOrEmpty($home_)) {
        $home_ = if ([string]::IsNullOrEmpty($env:FM_ROOT_OVERRIDE)) { $root } else { $env:FM_ROOT_OVERRIDE }
    }

    $state = if ($env:FM_STATE_OVERRIDE) { $env:FM_STATE_OVERRIDE } else { Join-Path $home_ 'state' }
    $data = if ($env:FM_DATA_OVERRIDE) { $env:FM_DATA_OVERRIDE } else { Join-Path $home_ 'data' }
    $config = if ($env:FM_CONFIG_OVERRIDE) { $env:FM_CONFIG_OVERRIDE } else { Join-Path $home_ 'config' }
    $projects = if ($env:FM_PROJECTS_OVERRIDE) { $env:FM_PROJECTS_OVERRIDE } else { Join-Path $home_ 'projects' }

    [pscustomobject]@{
        Root           = $root
        Home           = $home_
        State          = $state
        Data           = $data
        Config         = $config
        Projects       = $projects
        CompletionFile = Join-Path $state '.session-start-complete'
    }
}

# Soft binding to a collaborating area of the module. Returns $null when that
# area is not loaded, so every caller must decide - explicitly and visibly - what
# a missing owner means for its own stage.
function Resolve-FmSessionCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)

    foreach ($n in $Name) {
        $cmd = Get-Command -Name $n -CommandType Function, Cmdlet, Alias -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) { return $cmd }
    }
    return $null
}

# Read a key=value field out of a state/<id>.meta record. Prefers the shared
# owner when the foundation area is loaded, so there is exactly one parser in a
# complete module build.
function Get-FmSessionMetaValue {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key
    )

    $shared = Resolve-FmSessionCommand -Name 'Get-FmMetaValue'
    if ($shared) { return (& $shared -Path $Path -Key $Key) }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    # Last value wins, matching Get-FmMetaValue, so the fallback and the shared
    # owner cannot disagree about a meta file carrying a repeated key.
    $value = ''
    foreach ($line in (Get-FmSessionFileLines -Path $Path)) {
        if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1) }
    }
    return $value
}

# Read a text file as LF-delimited lines with no trailing-empty artifact, so a
# file written by a Linux firstmate and one written here parse identically.
function Get-FmSessionFileLines {
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Length -eq 0) { return @() }
    $text = $text -replace "`r`n", "`n"
    $lines = $text -split "`n"
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    return @($lines)
}

# Write a state/config file with LF endings and no BOM on every platform. The
# byte-for-byte file contract with a Linux firstmate depends on this, so no
# caller in this area may use Set-Content/Out-File for a contract file.
#
# Write-FmTextFileLf owns that rule for the module. This delegates to it so the
# rule has ONE owner, and keeps an identical local implementation for the case
# where this area is loaded on its own - which is how it was developed.
function Write-FmSessionTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $shared = Resolve-FmSessionCommand -Name 'Write-FmTextFileLf'
    if ($shared) {
        & $shared -Path $Path -Text $Content
        return
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), $utf8NoBom)
}

# Atomic-enough replacement: write a sibling temp file then move it over the
# destination. Windows fails a move onto an open file, so the destination is
# removed first when the direct move is refused - the same visible outcome the
# bash `mv -f` has, with the Windows file-locking difference handled here.
function Move-FmSessionFileInPlace {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    try {
        [System.IO.File]::Move($Source, $Destination, $true)
        return $true
    } catch {
        try {
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
            [System.IO.File]::Move($Source, $Destination)
            return $true
        } catch {
            return $false
        }
    }
}

$script:FmLineCapDefault = 220
$script:FmLineCapSuffix = ' [truncated]'

# The shared per-line cap for agent-facing digest lines (bin/fm-line-cap-lib.sh).
function Get-FmSessionCappedLine {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [int]$Max = 0
    )

    if ($Max -le 0) { $Max = $script:FmLineCapDefault }
    if ($Line.Length -le $Max) { return $Line }
    $keep = $Max - $script:FmLineCapSuffix.Length
    if ($keep -lt 0) { $keep = 0 }
    return $Line.Substring(0, $keep) + $script:FmLineCapSuffix
}

# Run an external command line and capture merged stdout/stderr plus its exit
# code. PowerShell's own invocation operator is used deliberately: on Windows the
# npm-installed tools resolve to .cmd shims, which Process.Start cannot launch
# directly but the invocation operator handles.
#
# FOUND, LAUNCHED AND EXITED ARE THREE DIFFERENT FACTS, and the caller needs all
# three. A command that is not on PATH (Found false), one that resolves but which
# Windows refuses to START at all (Launched false), and one that ran and answered
# badly (ExitCode) call for three different things to be said to the captain, and
# folding the middle one into "it exited 1 and printed this exception" is what
# left a real refusal reported as a tool that prints no version.
function Invoke-FmSessionCommandLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @()
    )

    $resolved = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $resolved) {
        return [pscustomobject]@{ ExitCode = 127; Output = @(); Found = $false; Launched = $false; Refusal = '' }
    }

    $global:LASTEXITCODE = 0
    $out = @()
    try {
        $out = @(& $resolved.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
    } catch {
        # The raw text is kept for a -Debug run and never handed to a caller that
        # prints for the captain; the callers turn Launched into their own words.
        Write-Debug "could not start '$($resolved.Source)': $_"
        return [pscustomobject]@{
            ExitCode = 1
            Output   = @()
            Found    = $true
            Launched = $false
            Refusal  = [string]$resolved.Source
        }
    }
    [pscustomobject]@{
        ExitCode = $global:LASTEXITCODE
        Output   = $out
        Found    = $true
        Launched = $true
        Refusal  = ''
    }
}

# --- digest formatting --------------------------------------------------------

$script:FmSessionRule = '================================================================================'
$script:FmSessionSubRule = '--------------------------------------------------------------------------------'

# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
$script:FmSessionStartStages = @(
    'lock', 'bootstrap', 'wake-queue', 'supervision-instructions', 'read-once',
    'fleet-state', 'network-checks', 'context', 'next-step'
)

function New-FmSessionSection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Formats digest text in memory and changes nothing.')]
    param([Parameter(Mandatory)][string]$Title)
    @('', $script:FmSessionRule, $Title, $script:FmSessionRule)
}

function New-FmSessionSubsection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Formats digest text in memory and changes nothing.')]
    param([Parameter(Mandatory)][string]$Title)
    @('', $Title, $script:FmSessionSubRule)
}

function Set-FmSessionStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal progress breadcrumb for the bounded startup; a skipped write would silently misreport which stage truncated.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ([string]::IsNullOrEmpty($env:FM_SESSION_START_STAGE_FILE)) { return }
    try { Write-FmSessionTextFile -Path $env:FM_SESSION_START_STAGE_FILE -Content "$Name`n" }
    catch { Write-Debug "session-start: could not record stage $Name; a truncation report may name an older stage: $_" }
}

# Full contents under a labeled subsection, or an explicit ABSENT marker.
# Absence is semantically meaningful for every one of these files, so an absent
# file and an empty-but-present file must never print the same.
function Format-FmSessionFileOrAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $out = @(New-FmSessionSubsection -Title $Label)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $len = (Get-Item -LiteralPath $Path -Force).Length
        if ($len -gt 0) {
            $out += Get-FmSessionFileLines -Path $Path
        } else {
            $out += '(present, empty)'
        }
    } else {
        $out += 'ABSENT'
    }
    $out
}

function Format-FmSessionStatusTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Tail = 5
    )

    $out = @("status tail (last $Tail line(s), each capped at $($script:FmLineCapDefault) characters, wake-EVENT history, not current state; full log: $Path):")
    $lines = @(Get-FmSessionFileLines -Path $Path)
    if ($lines.Count -gt $Tail) { $lines = $lines[($lines.Count - $Tail)..($lines.Count - 1)] }
    foreach ($line in $lines) { $out += (Get-FmSessionCappedLine -Line $line) }
    $out
}

# A queued title line whose own text already marks it held or blocked. The manual
# renderer has no task model, so this is the only signal it gets, and it is the
# one tasks-axi's markdown backend writes.
$script:FmSessionManualKeepPattern = '\(hold|blocked-by:'

function Format-FmSessionBacklogManualCompact {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Reason,
        [int]$QueuedLimit = 20
    )

    $out = @("compact backlog listing ($Reason; done rows omitted; every in-flight, held, and blocked title line kept; other queued bounded to $QueuedLimit; indented task bodies omitted)")
    $state = ''
    $inFlight = 0; $doneTotal = 0; $queuedTotal = 0; $gated = 0; $plainShown = 0

    foreach ($line in (Get-FmSessionFileLines -Path $Path)) {
        if ($line -match '^##\s+') {
            $heading = ($line -replace '^##\s+', '') -replace '\s+$', ''
            $state = switch ($heading) {
                'In flight' { 'in_flight'; break }
                'Queued' { 'queued'; break }
                'Done' { 'done'; break }
                default { '' }
            }
            # The Done heading is recognized so its items are skipped, never printed.
            if ($state -ne '' -and $state -ne 'done') { $out += $line }
            continue
        }
        if ($line -notmatch '^[-*]\s+') { continue }
        switch ($state) {
            'in_flight' { $inFlight++; $out += $line }
            'done' { $doneTotal++ }
            'queued' {
                $queuedTotal++
                if ($line -match $script:FmSessionManualKeepPattern) {
                    $gated++
                    $out += $line
                } elseif ($plainShown -lt $QueuedLimit) {
                    $plainShown++
                    $out += $line
                }
            }
        }
    }

    $plainTotal = $queuedTotal - $gated
    if (($inFlight + $queuedTotal + $doneTotal) -eq 0) {
        $out += '(no backlog item title lines found)'
    } else {
        $out += "(shown $inFlight in-flight, $gated held or blocked queued, $plainShown of $plainTotal other queued title line(s); $doneTotal done row(s) omitted)"
        if ($plainTotal -gt $plainShown) {
            $out += "($($plainTotal - $plainShown) more queued - raise FM_SESSION_START_QUEUED_LIMIT or read data/backlog.md for the rest)"
        }
    }
    $out
}

# tasks-axi closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times.
function Remove-FmSessionAxiHelp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Filters a caller-supplied array of lines; despite the verb it removes nothing outside this process.')]
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)

    $out = @()
    foreach ($line in $Lines) {
        if ($line -match '^help\[') { break }
        $out += $line
    }
    $out
}

# Bound the dispatchable-now listing without rewriting the tool's own rendering:
# `tasks-axi ready` rows are the indented lines under its ready[N]{...} header.
function Format-FmSessionReadyQueuedBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Ready,
        [Parameter(Mandatory)][string]$Path,
        [int]$QueuedLimit = 20
    )

    $out = @()
    $rows = $false
    $total = 0
    $shown = 0
    foreach ($line in $Ready) {
        if ($line -match '^help\[') { break }
        if ($line -match '^ready\[') { $rows = $true; $out += $line; continue }
        if ($rows -and $line -match '^\s') {
            $total++
            if ($shown -lt $QueuedLimit) { $out += $line; $shown++ }
            continue
        }
        $rows = $false
        $out += $line
    }
    if ($total -gt 0) {
        $out += "(shown $shown of $total ready queued item(s))"
        if ($total -gt $shown) {
            $out += "($($total - $shown) more queued - tasks-axi ready --file $Path)"
        }
    }
    $out
}

function Format-FmSessionBacklogTasksAxiCompact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$QueuedLimit = 20
    )

    $fields = 'blocked_by,hold_kind,hold_reason'
    $err = $null
    $groups = @{}
    foreach ($group in @(
            @{ Key = 'in_flight'; Args = @('list', '--file', $Path, '--state', 'in_flight', '--fields', $fields) },
            @{ Key = 'held'; Args = @('list', '--file', $Path, '--state', 'held', '--fields', $fields) },
            @{ Key = 'blocked'; Args = @('list', '--file', $Path, '--state', 'queued', '--blocked', '--fields', $fields) },
            @{ Key = 'ready'; Args = @('ready', '--file', $Path) }
        )) {
        if ($null -ne $err) { break }
        $res = Invoke-FmSessionCommandLine -Command 'tasks-axi' -Arguments $group.Args
        if ($res.ExitCode -ne 0) { $err = $res.Output; break }
        $groups[$group.Key] = $res.Output
    }

    if ($null -eq $err) {
        $out = @("compact backlog listing (tasks-axi; done rows omitted; every in-flight, held, and blocked row shown in full; ready queued bounded to $QueuedLimit; task bodies omitted)")
        $out += ''
        $out += 'in flight:'
        $out += Remove-FmSessionAxiHelp -Lines $groups['in_flight']
        $out += ''
        $out += 'held (captain- or time-gated; an in-flight item that is also held appears in both groups):'
        $out += Remove-FmSessionAxiHelp -Lines $groups['held']
        $out += ''
        $out += 'blocked queued:'
        $out += Remove-FmSessionAxiHelp -Lines $groups['blocked']
        $out += ''
        $out += 'ready queued (dispatchable now):'
        $out += Format-FmSessionReadyQueuedBounded -Ready $groups['ready'] -Path $Path -QueuedLimit $QueuedLimit
        return $out
    }

    $out = @('tasks-axi compact listing failed; falling back to title-line rendering.')
    $out += $err
    $out += Format-FmSessionBacklogManualCompact -Path $Path -Reason 'fallback' -QueuedLimit $QueuedLimit
    $out
}

function Format-FmSessionBacklogCompact {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$LegacyPath = '',
        [int]$QueuedLimit = 20
    )

    $out = @(New-FmSessionSubsection -Title $Label)
    # A home that added work items before the queue's location was single-sourced
    # has them in <home>/backlog.md, which nothing reads. The digest NAMES that
    # rather than reporting an empty queue - reporting ABSENT over a real queue
    # is the exact symptom this line exists to end. It only reports: the digest
    # runs in lock-refused read-only sessions too, and the move is the first
    # backlog command's to make.
    if (-not [string]::IsNullOrEmpty($LegacyPath) -and (Test-Path -LiteralPath $LegacyPath -PathType Leaf)) {
        $out += "LEGACY_BACKLOG: work items are in $LegacyPath, the pre-fix location nothing reads. The next " +
        "backlog command moves them to $Path, or refuses and names both files if both hold items."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return ($out + 'ABSENT') }
    if ((Get-Item -LiteralPath $Path -Force).Length -eq 0) { return ($out + '(present, empty)') }

    if (Test-FmSessionTasksAxiBackendAvailable -ConfigDir $ConfigDir) {
        $out += Format-FmSessionBacklogTasksAxiCompact -Path $Path -QueuedLimit $QueuedLimit
    } elseif (Test-FmSessionBacklogBackendManual -ConfigDir $ConfigDir) {
        $out += Format-FmSessionBacklogManualCompact -Path $Path -Reason 'manual backend' -QueuedLimit $QueuedLimit
    } else {
        $out += Format-FmSessionBacklogManualCompact -Path $Path -Reason 'tasks-axi unavailable or incompatible' -QueuedLimit $QueuedLimit
    }
    $out += 'Full task bodies remain available on demand: tasks-axi show <id> --full when compatible tasks-axi is available, or data/backlog.md.'
    $out
}

# config/backlog-backend: absent or "tasks-axi" is the default backend, "manual"
# forces title-line rendering (AGENTS.md section 2).
function Test-FmSessionBacklogBackendManual {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $shared = Resolve-FmSessionCommand -Name 'Test-FmBacklogBackendManual'
    if ($shared) { return [bool](& $shared -ConfigDir $ConfigDir) }

    $file = Join-Path $ConfigDir 'backlog-backend'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    $value = ([System.IO.File]::ReadAllText($file) -replace '\s', '')
    return ($value -eq 'manual')
}

function Test-FmSessionTasksAxiBackendAvailable {
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir)

    if (Test-FmSessionBacklogBackendManual -ConfigDir $ConfigDir) { return $false }
    return (Test-FmSessionTasksAxiCompatible)
}

# One tasks-axi compatibility verdict per session start. The verdict is handed to
# the bootstrap child through FM_TASKS_AXI_COMPATIBLE exactly as the bash digest
# does, so the probe is not paid twice.
function Test-FmSessionTasksAxiCompatible {
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    if ($env:FM_TASKS_AXI_COMPATIBLE -eq '1') { return $true }
    if ($env:FM_TASKS_AXI_COMPATIBLE -eq '0') { return $false }

    $shared = Resolve-FmSessionCommand -Name 'Test-FmTasksAxiCompatible'
    if ($shared) { return [bool](& $shared) }

    if (-not (Get-Command -Name 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue)) { return $false }
    $res = Invoke-FmSessionCommandLine -Command 'tasks-axi' -Arguments @('--version')
    return ($res.ExitCode -eq 0)
}

function Get-FmSessionFileSha256 {
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return 'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-FmSessionPiExtensionLoaded {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedVersion,
        [Parameter(Mandatory)][string]$LockPath
    )

    if ([string]::IsNullOrEmpty($ExpectedVersion)) { return $false }
    if (-not (Test-Path -LiteralPath $Marker -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { return $false }

    $markerLines = @(Get-FmSessionFileLines -Path $Marker)
    $lockLines = @(Get-FmSessionFileLines -Path $LockPath)
    $markerVersion = if ($markerLines.Count -ge 1) { $markerLines[0] } else { '' }
    $markerPid = if ($markerLines.Count -ge 2) { $markerLines[1] } else { '' }
    $lockPid = if ($lockLines.Count -ge 1) { $lockLines[0] } else { '' }
    if ([string]::IsNullOrEmpty($markerPid)) { return $false }
    return (($markerVersion -eq $ExpectedVersion) -and ($markerPid -eq $lockPid))
}

# --- composed stages ----------------------------------------------------------
# Each of these calls the real owner when it is loaded and otherwise says, in the
# digest itself, that the step did not run. A missing owner is never reported as
# a step that passed.

function Invoke-FmSessionComposedStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$CommandName,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][string]$UnavailableLine
    )

    $cmd = Resolve-FmSessionCommand -Name $CommandName
    if (-not $cmd) {
        return [pscustomobject]@{ Available = $false; Success = $false; Output = @($UnavailableLine) }
    }
    try {
        $out = @(& $cmd @Parameters 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Available = $true; Success = $true; Output = $out }
    } catch {
        return [pscustomobject]@{ Available = $true; Success = $false; Output = @([string]$_) }
    }
}

# Some owners this digest composes are ENTRY-POINT shaped: their report goes to
# the console and their return value is an exit code, not text. Two of them run
# inside the digest - the wake drain and the read-only guard - and calling them
# like an ordinary step gets both halves wrong: the report bypasses the digest
# entirely (in the bounded child, straight past the output file the parent
# streams, so it lands in the terminal out of order or not at all) and the exit
# code is stringified into the digest as a bare "0" where the queue should be.
#
# The wake queue is the turn's FIRST work queue, so losing it is not cosmetic.
# This runs such an owner with the console redirected into memory and reports
# what it wrote, dropping the exit code.
function Invoke-FmSessionConsoleStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$CommandName,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][string]$UnavailableLine
    )

    $cmd = Resolve-FmSessionCommand -Name $CommandName
    if (-not $cmd) {
        return [pscustomobject]@{ Available = $false; Success = $false; Output = @($UnavailableLine) }
    }

    $capturedOut = [System.IO.StringWriter]::new()
    $capturedError = [System.IO.StringWriter]::new()
    $previousOut = [Console]::Out
    $previousError = [Console]::Error
    $piped = @()
    $success = $true
    try {
        [Console]::SetOut($capturedOut)
        [Console]::SetError($capturedError)
        try {
            $piped = @(& $cmd @Parameters 2>&1)
        } catch {
            $success = $false
            $piped = @([string]$_)
        }
    } finally {
        [Console]::SetOut($previousOut)
        [Console]::SetError($previousError)
        $capturedOut.Flush()
        $capturedError.Flush()
    }

    $out = @()
    foreach ($writer in @($capturedOut, $capturedError)) {
        $text = $writer.ToString()
        if ([string]::IsNullOrEmpty($text)) { continue }
        $text = ($text -replace "`r`n", "`n").TrimEnd("`n")
        if ($text.Length -eq 0) { continue }
        $out += ($text -split "`n")
    }
    foreach ($item in $piped) {
        if ($null -eq $item) { continue }
        # The exit code, not digest text. Every other pipeline value is kept, so
        # an owner that reports through the pipeline is not silently dropped.
        if ($item -is [int] -or $item -is [long]) { continue }
        $out += [string]$item
    }

    [pscustomobject]@{ Available = $true; Success = $success; Output = @($out) }
}

# One cheap alive/dead read of a task's recorded backend endpoint. This is a fast
# PRESENCE check only, never a full state read: the digest deliberately skips the
# deeper per-task read so it stays bounded, and Get-FmCrewState is what answers
# "what is this crew actually doing".
#
# The backend area owns every probe here. It ships one session provider, so a
# meta naming an unported backend is reported as unknown rather than guessed at -
# the same refuse-loudly-never-guess rule that area applies elsewhere.
function Get-FmSessionEndpointLine {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MetaPath,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Window
    )

    $backend = 'unknown'
    $backendOf = Resolve-FmSessionCommand -Name 'Get-FmMetaBackend'
    if ($backendOf) {
        try { $backend = [string](& $backendOf -Path $MetaPath) } catch { $backend = 'unknown' }
    }

    $target = ''
    $targetOf = Resolve-FmSessionCommand -Name 'Get-FmMetaTarget'
    if ($targetOf) {
        try { $target = [string](& $targetOf -Path $MetaPath) } catch { $target = '' }
    }
    if ([string]::IsNullOrEmpty($target)) { $target = $Window }

    # A generic cross-backend predicate is preferred if one is ever published;
    # otherwise the probe of the resolved backend is used.
    $probe = Resolve-FmSessionCommand -Name 'Test-FmBackendTargetExists'
    if ($probe) {
        $alive = $false
        try { $alive = [bool](& $probe -Backend $backend -Target $target -Name "fm-$TaskId") } catch { $alive = $false }
        return $(if ($alive) { "endpoint: alive (backend=$backend window=$Window)" } else { "endpoint: dead (backend=$backend window=$Window)" })
    }

    if ($backend -eq 'herdr') {
        $probe = Resolve-FmSessionCommand -Name 'Test-FmHerdrTargetExists'
        if ($probe) {
            $alive = $false
            try { $alive = [bool](& $probe -Target $target) } catch { $alive = $false }
            return $(if ($alive) { "endpoint: alive (backend=$backend window=$Window)" } else { "endpoint: dead (backend=$backend window=$Window)" })
        }
    }

    return "endpoint: unknown (no endpoint probe is loaded for backend '$backend'; window=$Window)"
}

# The lock stage gets its own handling rather than the generic composed step,
# because it is the one stage whose RESULT decides what the rest of the digest is
# allowed to do. Refusal is honoured in all three shapes an owner might use:
# throwing, returning an object with Acquired = $false, or simply not existing.
# Every one of them lands on read-only, which is the safe direction: a session
# that cannot verify lock ownership must not mutate shared fleet state.
function Invoke-FmSessionLockStage {
    [CmdletBinding()]
    param()

    $cmd = Resolve-FmSessionCommand -Name 'Invoke-FmLock'
    if (-not $cmd) {
        return [pscustomobject]@{
            Acquired = $false
            Output   = @('lock: NOT ACQUIRED - Invoke-FmLock is not available in this module build, so fleet-lock ownership could not be verified.')
        }
    }

    try {
        $result = @(& $cmd 2>&1)
    } catch {
        return [pscustomobject]@{ Acquired = $false; Output = @([string]$_) }
    }

    $acquired = $true
    foreach ($item in $result) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Management.Automation.ErrorRecord]) { $acquired = $false; continue }
        $property = $item.PSObject.Properties['Acquired']
        if ($null -ne $property) { $acquired = [bool]$property.Value }
    }

    [pscustomobject]@{
        Acquired = $acquired
        Output   = @($result | ForEach-Object { [string]$_ })
    }
}

# --- the digest ---------------------------------------------------------------

function Get-FmSessionStartDigest {
    [CmdletBinding()]
    param(
        [switch]$Reemit
    )

    $paths = Get-FmSessionPaths
    $out = @()

    $statusTail = 5
    if ($env:FM_SESSION_START_STATUS_TAIL -match '^\d+$') { $statusTail = [int]$env:FM_SESSION_START_STATUS_TAIL }
    $queuedLimit = 20
    if ($env:FM_SESSION_START_QUEUED_LIMIT -match '^\d+$' -and [int]$env:FM_SESSION_START_QUEUED_LIMIT -gt 0) {
        $queuedLimit = [int]$env:FM_SESSION_START_QUEUED_LIMIT
    }

    $harnessCmd = Resolve-FmSessionCommand -Name 'Get-FmHarness'
    $primaryHarness = 'unknown'
    if ($harnessCmd) {
        try { $primaryHarness = [string](& $harnessCmd) } catch { $primaryHarness = 'unknown' }
        if ([string]::IsNullOrWhiteSpace($primaryHarness)) { $primaryHarness = 'unknown' }
    }

    # One tasks-axi compatibility verdict per session start, handed on to the
    # bootstrap child rather than re-probed there.
    $tasksAxiCompatible = if (Test-FmSessionTasksAxiCompatible) { '1' } else { '0' }

    if ($Reemit) {
        $out += New-FmSessionSection -Title "SESSION START (CONTEXT RE-EMIT) - $($paths.Home)"
        $out += 'This session already took the helm at its own startup and has only lost its'
        $out += 'context. Lock ownership is re-verified and the durable records below are'
        $out += 'reprinted, but the sweeps startup already reconciled - project clone refresh,'
        $out += 'secondmate convergence and liveness, PR-check migration, pending remote handoff'
        $out += 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.'
        $out += 'Queued wakes ARE still drained: they arrived after startup and are this turn work.'
    } else {
        $out += New-FmSessionSection -Title "SESSION START - $($paths.Home)"
    }

    # --- 1. lock --------------------------------------------------------------
    Set-FmSessionStage -Name 'lock'
    $out += New-FmSessionSubsection -Title 'LOCK'
    $lock = Invoke-FmSessionLockStage
    $out += $lock.Output
    $readOnly = -not $lock.Acquired

    if ($readOnly) {
        $bar = '●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        $out += $bar
        $out += '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED'
        foreach ($line in $lock.Output) { $out += "●  $line" }
        $out += '●  Skipping every mutating step: PR-check migration, stale Herdr child cleanup,'
        $out += '●  secondmate convergence, secondmate liveness, pending remote handoff retry,'
        $out += '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap'
        $out += '●  diagnostics and the rest of this read-only-safe digest still ran below.'
        $out += '●  Operate read-only until this resolves - do not spawn, steer, merge, or'
        $out += '●  otherwise mutate fleet state from this session.'
        $out += $bar
    } else {
        if (-not $Reemit) {
            Remove-Item -LiteralPath $paths.CompletionFile -Force -ErrorAction SilentlyContinue
        }
        $trace = Resolve-FmSessionCommand -Name 'Set-FmTraceContextSessionStart'
        if ($trace) {
            try { & $trace -ConfigDir $paths.Config -EffectiveFile (Join-Path $paths.State '.trace-context-effective') | Out-Null }
            catch { Write-Debug "session-start: Set-FmTraceContextSessionStart owner failed; the trace context was NOT refreshed: $_" }
        }
        # Every network call this session start owes is launched HERE, detached
        # and bounded, so it runs concurrently with the whole digest below.
        # Step 7 harvests whatever it has finished, without ever waiting.
        $networkStageLocked = if ($Reemit) { 0 } else { 1 }
        $netStart = Resolve-FmSessionCommand -Name 'Start-FmStartupNetwork'
        if ($netStart) {
            try { & $netStart -Locked $networkStageLocked -HarvestPid $PID | Out-Null }
            catch { Write-Debug "session-start: Start-FmStartupNetwork owner failed; step 7 harvests nothing: $_" }
        }
    }

    # --- 2. bootstrap ---------------------------------------------------------
    Set-FmSessionStage -Name 'bootstrap'
    $out += New-FmSessionSubsection -Title 'BOOTSTRAP'
    $bootOut = @()
    $previousCompatible = $env:FM_TASKS_AXI_COMPATIBLE
    try {
        $env:FM_TASKS_AXI_COMPATIBLE = $tasksAxiCompatible
        if ($readOnly) {
            $bootOut = @(Invoke-FmBootstrap -DetectOnly -Network skip)
        } elseif ($Reemit) {
            $bootOut = @(Invoke-FmBootstrap -DetectOnly -Locked -Network skip)
        } else {
            $cleanup = Resolve-FmSessionCommand -Name 'Invoke-FmHerdrSessionCleanup'
            if ($cleanup) {
                try { $bootOut += @(& $cleanup 2>&1 | ForEach-Object { [string]$_ }) }
                catch { Write-Debug "session-start: Invoke-FmHerdrSessionCleanup owner failed; stale Herdr children were NOT swept: $_" }
            }
            $bootOut += @(Invoke-FmBootstrap -Network skip)
        }
    } finally {
        $env:FM_TASKS_AXI_COMPATIBLE = $previousCompatible
    }
    $bootOut = @($bootOut | Where-Object { $null -ne $_ })
    if ($bootOut.Count -gt 0) { $out += $bootOut } else { $out += '(silent - all good)' }

    # --- 3. wake-drain --------------------------------------------------------
    Set-FmSessionStage -Name 'wake-queue'
    $out += New-FmSessionSubsection -Title 'WAKE QUEUE'
    if ($readOnly) {
        $queueFile = Join-Path $paths.State '.wake-queue'
        $qlen = 0
        if (Test-Path -LiteralPath $queueFile -PathType Leaf) {
            $qlen = @(Get-FmSessionFileLines -Path $queueFile | Where-Object { $_ -ne '' }).Count
        }
        $out += "skipped (read-only session) - $qlen record(s) remain queued because this session lacks verified fleet-lock ownership."
        $previousGuardReadOnly = $env:FM_GUARD_READ_ONLY
        try {
            $env:FM_GUARD_READ_ONLY = '1'
            $guard = Invoke-FmSessionConsoleStep -CommandName @('Invoke-FmGuard') `
                -UnavailableLine 'guard: NOT RUN - Invoke-FmGuard is not available in this module build, so the tangle and watcher-liveness alarms were not evaluated.'
            if ($guard.Available -and @($guard.Output).Count -gt 0) { $out += $guard.Output }
        } finally { $env:FM_GUARD_READ_ONLY = $previousGuardReadOnly }
    } else {
        $drain = Invoke-FmSessionConsoleStep -CommandName @('Invoke-FmWakeDrain') `
            -UnavailableLine 'wake queue: NOT DRAINED - Invoke-FmWakeDrain is not available in this module build, so queued wakes were neither presented nor acknowledged.'
        if (@($drain.Output).Count -gt 0) { $out += $drain.Output } else { $out += '(no queued wakes)' }
    }

    # --- 4. supervision operating instructions --------------------------------
    Set-FmSessionStage -Name 'supervision-instructions'
    $afkPresent = if (Test-Path -LiteralPath (Join-Path $paths.State '.afk')) { 1 } else { 0 }
    $xModePresent = if (Test-Path -LiteralPath (Join-Path $paths.Config 'x-mode.env') -PathType Leaf) { 1 } else { 0 }

    if ($primaryHarness -eq 'pi' -or $primaryHarness -eq 'pi-signed') {
        $piExt = Join-Path $paths.Root '.pi' 'extensions' 'fm-primary-pi-watch.ts'
        $piTurnendExt = Join-Path $paths.Root '.pi' 'extensions' 'fm-primary-turnend-guard.ts'
        $piWatchMarker = Join-Path $paths.State '.pi-watch-extension-loaded'
        $piTurnendMarker = Join-Path $paths.State '.pi-turnend-extension-loaded'
        $piLock = Join-Path $paths.State '.lock'
        $piRestartCommand = if ($primaryHarness -eq 'pi') { 'plain pi' } else { $primaryHarness }
        $piWatchVersion = Get-FmSessionFileSha256 -Path $piExt
        $piTurnendVersion = Get-FmSessionFileSha256 -Path $piTurnendExt
        if (-not (Test-FmSessionPiExtensionLoaded -Marker $piWatchMarker -ExpectedVersion $piWatchVersion -LockPath $piLock) -or
            -not (Test-FmSessionPiExtensionLoaded -Marker $piTurnendMarker -ExpectedVersion $piTurnendVersion -LockPath $piLock)) {
            $out += "PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart $piRestartCommand so $piTurnendExt and $piExt auto-load for turn-end guard and background wake coverage; use -e $piTurnendExt -e $piExt only if project hooks are not trusted"
        }
    }

    $supervision = Invoke-FmSessionComposedStep -CommandName @('Get-FmSupervisionInstructions') `
        -Parameters @{ Harness = $primaryHarness; ReadOnly = [int]([bool]$readOnly); Afk = $afkPresent; XMode = $xModePresent } `
        -UnavailableLine 'SUPERVISION INSTRUCTIONS: NOT EMITTED - Get-FmSupervisionInstructions is not available in this module build. Do not end a turn with work in flight until the harness supervision protocol is re-established by hand.'
    $out += $supervision.Output

    # --- 5. read-once contract ------------------------------------------------
    Set-FmSessionStage -Name 'read-once'
    $out += New-FmSessionSection -Title 'READ-ONCE CONTRACT'
    $out += @(
        'Everything below is printed in full for this session start: every state/*.meta,'
        'a compact data/backlog.md listing, a bounded tail of every state/*.status,'
        'data/projects.md, data/secondmates.md, data/captain.md, data/captain-shared.md,'
        'and data/learnings.md.'
        'Do NOT re-read any of them after reading this digest, and do NOT bulk-read'
        'data/backlog.md or state/*.status: re-reading everything defeats the entire'
        'point of this command.'
        ''
        'Go to a source directly only when:'
        '  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),'
        '  - its contents looked unparseable or corrupt,'
        '  - an individual full status log is needed for older wake-event history, or a'
        '    status line was capped and its tail matters (each task''s full log path is'
        '    printed with its tail),'
        '  - a full task body is needed (tasks-axi show <id> --full, or data/backlog.md),'
        '  - the backlog listing disclosed omitted queued items and this turn needs them,'
        '  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this'
        '    turn needs their verdict (Invoke-FmStartupNetwork -Report),'
        '  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in'
        '    which case that stage''s sources were never emitted and must be reconciled.'
    )

    # --- 6. fleet-state digest ------------------------------------------------
    Set-FmSessionStage -Name 'fleet-state'
    $out += New-FmSessionSection -Title 'FLEET STATE'
    # Get-FmBacklogPath, not a second Join-Path of its own: this digest and the
    # backlog commands each used to compute the queue's location, they disagreed,
    # and the digest reported ABSENT while the captain's items sat in the file
    # the other one had created.
    $out += Format-FmSessionBacklogCompact -Path (Get-FmBacklogPath -HomePath $paths.Home) -Label 'data/backlog.md' `
        -LegacyPath (Get-FmBacklogLegacyPath -HomePath $paths.Home) -ConfigDir $paths.Config -QueuedLimit $queuedLimit

    $out += New-FmSessionSubsection -Title 'Work under way (state/*.meta)'
    $metaFiles = @()
    if (Test-Path -LiteralPath $paths.State -PathType Container) {
        $metaFiles = @(Get-ChildItem -LiteralPath $paths.State -Filter '*.meta' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    foreach ($meta in $metaFiles) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($meta.Name)
        $out += ''
        $out += "--- $id ---"
        $out += Get-FmSessionFileLines -Path $meta.FullName

        $window = Get-FmSessionMetaValue -Path $meta.FullName -Key 'window'
        if (-not [string]::IsNullOrEmpty($window)) {
            $out += Get-FmSessionEndpointLine -MetaPath $meta.FullName -TaskId $id -Window $window
        } else {
            $out += 'endpoint: unknown (no window recorded)'
        }

        $status = Join-Path $paths.State "$id.status"
        if (Test-Path -LiteralPath $status -PathType Leaf) {
            $out += Format-FmSessionStatusTail -Path $status -Tail $statusTail
        } else {
            $out += "status tail: (no status file yet: $status)"
        }
    }
    if ($metaFiles.Count -eq 0) { $out += '(none)' }

    $out += New-FmSessionSubsection -Title 'Orphan status logs (state/*.status without matching .meta)'
    $orphanFound = $false
    if (Test-Path -LiteralPath $paths.State -PathType Container) {
        foreach ($status in @(Get-ChildItem -LiteralPath $paths.State -Filter '*.status' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $id = [System.IO.Path]::GetFileNameWithoutExtension($status.Name)
            if (Test-Path -LiteralPath (Join-Path $paths.State "$id.meta") -PathType Leaf) { continue }
            $orphanFound = $true
            $out += ''
            $out += "--- $id ---"
            $out += Format-FmSessionStatusTail -Path $status.FullName -Tail $statusTail
        }
    }
    if (-not $orphanFound) { $out += '(none)' }

    $out += New-FmSessionSubsection -Title 'AFK'
    if (Test-Path -LiteralPath (Join-Path $paths.State '.afk')) {
        $out += 'present - away-mode supervision is active; the daemon owns the watcher.'
    } else {
        $out += 'absent'
    }

    # Public commitments made through the myfirstmate relay. The relay gate and
    # the registration/event gates are owned by the relay area; a home that never
    # opted in prints no subsection at all.
    $pfPending = Resolve-FmSessionCommand -Name 'Get-FmPublicFollowupPending'
    if ($pfPending) {
        $pf = @()
        try { $pf = @(& $pfPending 2>$null | ForEach-Object { [string]$_ }) } catch { $pf = @() }
        $pf = @($pf | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($pf.Count -gt 0) {
            $out += New-FmSessionSubsection -Title 'Public commitments awaiting delivery'
            $out += $pf
            $out += ''
            $out += 'Each line is a public reply this home still owes. Reconcile terminal results with'
            $out += 'Invoke-FmPublicFollowup -Consume, then deliver a ready one with'
            $out += 'Invoke-FmPublicFollowup -Deliver <id>. Load fmx-respond for the procedure.'
        }
    }

    # --- 7. network checks ----------------------------------------------------
    Set-FmSessionStage -Name 'network-checks'
    $out += New-FmSessionSection -Title 'NETWORK CHECKS'
    if ($readOnly) {
        $out += 'skipped (read-only session) - GitHub authentication, project clone refresh,'
        $out += 'secondmate liveness and convergence, and pending handoff delivery were not run.'
        $out += 'They need the fleet lock, and this session must not spawn, steer, or merge, so it'
        $out += 'has no action they would gate. The session holding the lock runs them.'
    } else {
        $harvest = Invoke-FmSessionComposedStep -CommandName @('Invoke-FmStartupNetworkHarvest') `
            -Parameters @{ HarvestPid = $PID } `
            -UnavailableLine 'NETWORK CHECKS: NOT CONFIRMED - Invoke-FmStartupNetworkHarvest is not available in this module build, so GitHub auth, secondmate liveness and convergence, pending handoff delivery, and project clone refresh are all unverified this session.'
        $out += $harvest.Output
    }

    # --- 8. context digest ----------------------------------------------------
    Set-FmSessionStage -Name 'context'
    $out += New-FmSessionSection -Title 'CONTEXT'
    $out += Format-FmSessionFileOrAbsent -Path (Join-Path $paths.Data 'projects.md') -Label 'data/projects.md'
    $out += Format-FmSessionFileOrAbsent -Path (Join-Path $paths.Data 'secondmates.md') -Label 'data/secondmates.md'
    $out += Format-FmSessionFileOrAbsent -Path (Join-Path $paths.Data 'captain.md') -Label 'data/captain.md'
    $out += Format-FmSessionFileOrAbsent -Path (Join-Path $paths.Data 'captain-shared.md') -Label 'data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)'
    $out += Format-FmSessionFileOrAbsent -Path (Join-Path $paths.Data 'learnings.md') -Label 'data/learnings.md'

    # --- 9. closing reminder --------------------------------------------------
    Set-FmSessionStage -Name 'next-step'
    $out += New-FmSessionSection -Title 'NEXT STEP'
    if ($readOnly) {
        $out += @(
            'This session did not acquire the fleet lock. Stay read-only: do not arm,'
            'drain, spawn, steer, merge, or repair fleet state from here. Only a session'
            'with verified fleet-lock ownership may perform mutable follow-up.'
            ''
        )
    } elseif ($afkPresent -eq 1) {
        $out += @(
            'Away mode is active. Follow the supervision operating instructions block above:'
            'load /afk and ensure the daemon is running, because the daemon owns watcher'
            'supervision.'
            ''
        )
    } elseif ($xModePresent -eq 1) {
        $out += @(
            "Follow the supervision operating instructions block above for harness '$primaryHarness'."
            'X mode is active, so the emitted block''s cadence instruction applies.'
            'This script never starts supervision itself.'
            ''
        )
    } else {
        $out += @(
            "Follow the supervision operating instructions block above for harness '$primaryHarness'."
            'This script never starts supervision itself.'
            ''
        )
    }
    $out += 'The digest above is complete for this session start. The READ-ONCE CONTRACT'
    $out += 'section near the top of it governs what may still be read from disk.'

    if (-not $readOnly -and -not $Reemit) {
        $out += Set-FmSessionStartCompletion -Paths $paths
    }

    $out
}

# Record that a full startup finished under the current lock owner, so a later
# /clear or /compact can re-emit instead of re-running the mutating sweeps.
function Set-FmSessionStartCompletion {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal step of a session start that has already been decided; the digest reports the outcome either way.')]
    [OutputType([object[]])]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)

    $lockFile = Join-Path $Paths.State '.lock'
    $completionPid = ''
    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
        $lines = @(Get-FmSessionFileLines -Path $lockFile)
        if ($lines.Count -ge 1) { $completionPid = $lines[0] }
    }
    if ($completionPid -notmatch '^\d+$') { $completionPid = '' }

    $ok = $false
    if (-not [string]::IsNullOrEmpty($completionPid)) {
        $tmp = "$($Paths.CompletionFile).tmp.$PID"
        try {
            Write-FmSessionTextFile -Path $tmp -Content "$completionPid`n"
            $ok = Move-FmSessionFileInPlace -Source $tmp -Destination $Paths.CompletionFile
        } catch {
            $ok = $false
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $ok) {
        return @('', 'SESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.')
    }
    return @()
}

# --- the runtime bound --------------------------------------------------------
# The digest runs on a session-open hook that blocks session initialization, so
# an unbounded digest can strand a whole session behind one hung subprocess. The
# whole digest therefore runs as ONE bounded child process. Windows has no fork,
# so the child is a real `pwsh` process started from the entry script - which is
# also what the bash version does with its own re-exec.

function Invoke-FmSessionStartBounded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryScript,
        [switch]$Reemit
    )

    $budget = 120
    if ($env:FM_SESSION_START_TIMEOUT -match '^\d+$' -and [int]$env:FM_SESSION_START_TIMEOUT -gt 0) {
        # A non-positive or non-numeric budget is not a budget, so an unusable
        # value falls back to the default rather than removing the bound.
        $budget = [int]$env:FM_SESSION_START_TIMEOUT
    }

    $tempRoot = [System.IO.Path]::GetTempPath()
    $stageFile = Join-Path $tempRoot ("fm-session-start-stage." + [System.IO.Path]::GetRandomFileName())
    $outFile = Join-Path $tempRoot ("fm-session-start-out." + [System.IO.Path]::GetRandomFileName())
    Write-FmSessionTextFile -Path $stageFile -Content ''
    Write-FmSessionTextFile -Path $outFile -Content ''

    $pwshPath = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($pwshPath)) { $pwshPath = 'pwsh' }

    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $EntryScript)
    if ($Reemit) { $childArgs += '--reemit' }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwshPath
    foreach ($a in $childArgs) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.EnvironmentVariables['FM_SESSION_START_STAGE_FILE'] = $stageFile
    $psi.EnvironmentVariables['FM_SESSION_START_OUTPUT_FILE'] = $outFile

    $proc = $null
    $truncated = $false
    $emitted = 0
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $deadline = [datetime]::UtcNow.AddSeconds($budget)
        while (-not $proc.HasExited) {
            $pending = Read-FmSessionPendingOutput -Path $outFile -Offset $emitted
            $emitted = $pending.Offset
            foreach ($line in $pending.Lines) { Write-Output $line }
            if ([datetime]::UtcNow -ge $deadline) {
                $truncated = $true
                try { $proc.Kill($true) } catch { Write-Debug "session-start: kill after the runtime bound failed (the child had already exited): $_" }
                break
            }
            Start-Sleep -Milliseconds 100
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch { Write-Debug "session-start: waiting for the bounded child to exit failed: $_" }
        $pending = Read-FmSessionPendingOutput -Path $outFile -Offset $emitted
        $emitted = $pending.Offset
        foreach ($line in $pending.Lines) { Write-Output $line }
    } finally {
        if ($proc) { $proc.Dispose() }
    }

    if ($truncated) {
        $lastStage = ''
        try { $lastStage = ([System.IO.File]::ReadAllText($stageFile)).Trim() } catch { Write-Debug "session-start: could not read the stage file; the truncation notice reports unknown: $_" }
        if ([string]::IsNullOrEmpty($lastStage)) { $lastStage = 'unknown' }
        $idx = $script:FmSessionStartStages.IndexOf($lastStage)
        $pending = if ($idx -ge 0) {
            ($script:FmSessionStartStages[$idx..($script:FmSessionStartStages.Count - 1)]) -join ' '
        } else {
            '(unknown - the digest may be incomplete anywhere)'
        }
        $bar = '●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        Write-Output ''
        Write-Output $bar
        Write-Output "●  STARTUP TRUNCATED - SESSION START HIT ITS $($budget)s RUNTIME BOUND"
        Write-Output "●  It stopped during the `"$lastStage`" stage, so everything above is COMPLETE"
        Write-Output '●  only up to that point.'
        Write-Output '●  RECONCILE these stages before acting on anything they would have shown:'
        Write-Output "●    $pending"
        Write-Output '●  Rerun bin/fm-session-start.ps1 now to finish taking the helm. If it truncates'
        Write-Output '●  again, raise FM_SESSION_START_TIMEOUT and report the slow stage - a stage that'
        Write-Output '●  cannot finish inside the bound is a fleet problem, not a reporting detail.'
        Write-Output $bar
    }

    Remove-Item -LiteralPath $stageFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
}

# Read whatever the bounded child has written since the last pass. Everything it
# emitted before the bound was hit is delivered, exactly as the bash version
# guarantees. Returns the new offset plus the complete lines to print; the caller
# does the printing so this stays a pure reader.
function Read-FmSessionPendingOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Offset
    )

    $none = [pscustomobject]@{ Offset = $Offset; Lines = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $none }
    $text = ''
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.UTF8Encoding]::new($false))
            $text = $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    } catch {
        return $none
    }
    if ($text.Length -le $Offset) { return $none }

    $fresh = $text.Substring($Offset)
    # Only whole lines are emitted, so a half-written line is never split across
    # two prints; the remainder is picked up on the next pass.
    $lastNewline = $fresh.LastIndexOf("`n")
    if ($lastNewline -lt 0) { return $none }
    $complete = $fresh.Substring(0, $lastNewline)
    [pscustomobject]@{
        Offset = $Offset + $lastNewline + 1
        Lines  = @($complete -split "`n")
    }
}
