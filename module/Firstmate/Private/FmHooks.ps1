#requires -Version 7.0
# FmHooks.ps1 - the Claude Code hook surface, ported from bin/fm-sessionstart-run.sh,
# bin/fm-arm-pretool-check.sh, bin/fm-turnend-guard.sh, and
# bin/fm-claude-stop-autoarm.sh. docs/turnend-guard.md is the authoritative
# contract for the turn-end guard and the Stop-owned auto-arm.
#
# WINDOWS-UNVERIFIED: EVERY hook behaviour in this file is documentation-only.
# Claude Code documents a PowerShell-native hook mode on Windows with a per-hook
# "shell": "powershell" field, and documents the SessionStart/PreToolUse/Stop
# payload shapes, the exit-2 blocking convention, and Stop `asyncRewake`. None of
# it has been exercised against Claude Code on Windows from this port, because
# this port was written on Linux where that host does not exist. Every function
# below is written to that documented contract and every hook-observable
# behaviour carries its own WINDOWS-UNVERIFIED marker naming what specifically is
# unproven. The pure predicates (primary scope, supervision need, budget/epoch
# accounting, payload parsing) are ordinary file and JSON logic and ARE exercised
# by tests/FmHooks.Tests.ps1 on this host.
#
# Hook functions never write to the host directly. They return a decision object
# - ExitCode, Stdout, Stderr - and bin/fm-claude-hook.ps1 is the one place that
# turns it into a process exit code and stream writes. That split is what makes
# the exit-2 blocking paths testable at all.

# --- decision objects ---------------------------------------------------------

function New-FmHookDecision {
    [CmdletBinding()]
    param(
        [int]$ExitCode = 0,
        [string[]]$Stdout = @(),
        [string[]]$Stderr = @()
    )

    [pscustomobject]@{
        ExitCode = $ExitCode
        Stdout   = @($Stdout)
        Stderr   = @($Stderr)
    }
}

# --- payload ------------------------------------------------------------------

# Parse a hook payload without depending on any external JSON tool. Returns
# $null for absent or malformed input; every caller treats that as fail-open,
# because a hook that cannot read its own payload must never block a session.
function ConvertFrom-FmHookPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Payload)

    if ([string]::IsNullOrWhiteSpace($Payload)) { return $null }
    try {
        $doc = $Payload | ConvertFrom-Json -AsHashtable -Depth 32
    } catch {
        return $null
    }
    if ($doc -isnot [hashtable]) { return $null }
    return $doc
}

# The loop-guard field, with the typed camel-case spelling taking precedence when
# both appear. A present-but-non-boolean value is malformed: the caller fails
# open rather than guessing.
function Get-FmHookStopHookActive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Payload)

    if ($null -eq $Payload) { return $null }
    foreach ($key in @('stopHookActive', 'stop_hook_active')) {
        if ($Payload.ContainsKey($key)) {
            if ($Payload[$key] -is [bool]) { return [bool]$Payload[$key] }
            return $null
        }
    }
    return $false
}

# --- primary scope ------------------------------------------------------------
# Port of bin/fm-primary-scope-lib.sh. A genuinely-marked secondmate home runs its
# OWN primary firstmate session, so it is force-INCLUDED whether it is a linked
# worktree or a plain clone. Only an UNMARKED checkout falls through to the
# linked-worktree exemption, which keeps crewmate and scout task worktrees inert.

function Test-FmHookSecondmateHome {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $marker = Join-Path $Root '.fm-secondmate-home'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    # A symlinked marker is not a genuine marker. Windows reports symlinks and
    # junctions through the same ReparsePoint attribute, which is the platform's
    # equivalent of the bash `[ -L ]` test.
    if ($item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { return $false }

    $lines = @(Get-FmSessionFileLines -Path $marker)
    if ($lines.Count -lt 1) { return $false }
    $id = $lines[0] -replace '\s', ''
    if ([string]::IsNullOrEmpty($id)) { return $false }
    if ($id -match '[^A-Za-z0-9._-]') { return $false }
    return $true
}

function Test-FmHookPrimaryScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$State
    )

    if (-not (Test-FmHookSecondmateHome -Root $Root)) {
        $gitDir = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-dir')
        if ($gitDir.ExitCode -ne 0) { return $false }
        $common = Invoke-FmSessionCommandLine -Command 'git' -Arguments @('-C', $Root, 'rev-parse', '--git-common-dir')
        if ($common.ExitCode -ne 0) { return $false }
        # Paths are compared case-insensitively on Windows because the filesystem
        # is, and git can report the two dirs with different casing there.
        $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not [string]::Equals(($gitDir.Output -join ''), ($common.Output -join ''), $comparison)) { return $false }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'AGENTS.md') -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'bin') -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath $State -PathType Container)) { return $false }
    return $true
}

# --- supervision predicate ----------------------------------------------------
# Port of bin/fm-supervision-lib.sh's fm_supervision_status. The watcher area owns
# this when it is loaded; this is the same predicate so the hook surface works in
# a partial module build.

function Get-FmHookSupervisionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [int]$Grace = 0
    )

    $shared = Resolve-FmSessionCommand -Name 'Get-FmSupervisionStatus'
    if ($shared) {
        try { return (& $shared -State $State -Grace $Grace) } catch { Write-Debug "hooks: Get-FmSupervisionStatus owner failed; falling back to the local read: $_" }
    }

    if ($Grace -le 0) { $Grace = Get-FmHookGrace }

    $inFlight = 0
    $sources = 0
    if (Test-Path -LiteralPath $State -PathType Container) {
        $inFlight = @(Get-ChildItem -LiteralPath $State -Filter '*.meta' -File -ErrorAction SilentlyContinue).Count
        $proceventDir = Join-Path $State 'procevent'
        if (Test-Path -LiteralPath $proceventDir -PathType Container) {
            $sources = @(Get-ChildItem -LiteralPath $proceventDir -Filter '*.source' -File -ErrorAction SilentlyContinue).Count
        }
    }

    # Every mode treats state/x-watch.check.sh as supervision need, so relay
    # polling remains guarded without an in-flight task.
    $xPoll = Test-Path -LiteralPath (Join-Path $State 'x-watch.check.sh') -PathType Leaf
    $needed = ($inFlight -gt 0) -or $xPoll -or ($sources -gt 0)

    $beat = Join-Path $State '.last-watcher-beat'
    $beaconDesc = 'never'
    $fresh = $false
    if (Test-Path -LiteralPath $beat) {
        $age = Get-FmHookPathAge -Path $beat
        if ($age -ge 0) {
            $beaconDesc = "${age}s ago"
            if ($age -lt $Grace) { $fresh = $true }
        } else {
            $beaconDesc = 'unknown'
        }
    }

    $queuePending = $false
    $queue = Join-Path $State '.wake-queue'
    if ((Test-Path -LiteralPath $queue -PathType Leaf) -and (Get-Item -LiteralPath $queue -Force).Length -gt 0) {
        $queuePending = $true
    }

    [pscustomobject]@{
        InFlight     = $inFlight
        Sources      = $sources
        Needed       = $needed
        WatcherFresh = $fresh
        BeaconDesc   = $beaconDesc
        QueuePending = $queuePending
    }
}

function Get-FmHookGrace {
    [CmdletBinding()]
    param()

    if ($env:FM_GUARD_GRACE -match '^\d+$' -and [int]$env:FM_GUARD_GRACE -gt 0) { return [int]$env:FM_GUARD_GRACE }
    return 300
}

function Get-FmHookPathAge {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [int]([datetime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds
    } catch {
        return 999999
    }
}

function Test-FmHookPidAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$ProcessId)

    if ($ProcessId -notmatch '^\d+$') { return $false }
    return [bool](Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
}

# The PID-strict watcher predicate. Owned by the watcher area; when it is not
# loaded the guard cannot evaluate its own predicate, so callers fail OPEN rather
# than blocking every turn end - the same rule the bash guard applies to a
# missing jq.
function Test-FmHookWatcherHealthy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [int]$Grace = 0
    )

    $shared = Resolve-FmSessionCommand -Name 'Test-FmWatcherHealthy'
    if (-not $shared) { return $null }
    try {
        return [bool](& $shared -State $State -Grace $Grace)
    } catch {
        return $null
    }
}

# --- hook-owned locks ---------------------------------------------------------
# WINDOWS-NATIVE DIVERGENCE, deliberate: the bash locks are a symlink pointing at
# a freshly created owner directory, because that is how they get an atomic claim
# on a POSIX filesystem. Creating a symlink on Windows needs either Developer
# Mode or an elevated process, so a symlink-based lock would simply fail for most
# users. An exclusive directory create is atomic on NTFS and on every filesystem
# PowerShell 7 runs on, and it leaves the SAME readable layout - <lock>/pid and
# <lock>/role - so a reader written for either platform sees the same fields.
# Locks are volatile runtime state and are never read across machines.

function New-FmHookLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        # -Force is deliberately NOT used: the create must fail when the lock is
        # already held, which is the whole claim.
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    } catch {
        return $false
    }
    try {
        Write-FmSessionTextFile -Path (Join-Path $Path 'pid') -Content "$PID`n"
        return $true
    } catch {
        Remove-FmHookLock -Path $Path
        return $false
    }
}

function Remove-FmHookLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    } catch { Write-Debug "hooks: could not remove $Path; a later claim treats it as a stale lock: $_" }
}

function Set-FmHookLockRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('autoarm', 'terminal-check')][string]$Role
    )

    $ownerPid = Get-FmHookLockField -Path $Path -Field 'pid'
    if ($ownerPid -ne [string]$PID) { return $false }
    try {
        Write-FmSessionTextFile -Path (Join-Path $Path 'role') -Content "$Role`n"
    } catch {
        return $false
    }
    return ((Get-FmHookLockRole -Path $Path) -eq $Role)
}

function Get-FmHookLockRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FmHookLockField -Path $Path -Field 'role')
}

function Get-FmHookLockField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Field
    )

    $lines = @(Get-FmSessionFileLines -Path (Join-Path $Path $Field))
    if ($lines.Count -lt 1) { return '' }
    return $lines[0]
}

# --- the Claude failure-episode ledger ----------------------------------------
# state/.claude-autoarm-epoch and state/.turnend-claude-blocks are shared file
# contracts: a Linux firstmate and this one must read each other's records, so
# both keep the bash byte layout exactly.
#   .claude-autoarm-epoch     "epoch=<n> owner_pid=<pid> outcome=<word> updated_at=<unix>\n"
#   .turnend-claude-blocks    "session=<id>\ncount=<n>\nepoch=<n>\n"

function Get-FmHookEpochRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$State)

    $path = Join-Path $State '.claude-autoarm-epoch'
    $record = [pscustomobject]@{ Epoch = ''; OwnerPid = ''; Outcome = ''; UpdatedAt = ''; Age = 999999; Path = $path }
    $lines = @(Get-FmSessionFileLines -Path $path)
    if ($lines.Count -lt 1) { return $record }
    foreach ($field in ($lines[0] -split ' ')) {
        $kv = $field -split '=', 2
        if ($kv.Count -ne 2) { continue }
        switch ($kv[0]) {
            'epoch' { if ($kv[1] -match '^\d+$') { $record.Epoch = $kv[1] } }
            'owner_pid' { $record.OwnerPid = $kv[1] }
            'outcome' { if ($kv[1] -match '^[a-z][a-z-]*$') { $record.Outcome = $kv[1] } }
            'updated_at' { $record.UpdatedAt = $kv[1] }
        }
    }
    $record.Age = Get-FmHookPathAge -Path $path
    $record
}

function Write-FmHookEpochRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Outcome
    )

    $path = Join-Path $State '.claude-autoarm-epoch'
    $seq = 0
    $existing = Get-FmHookEpochRecord -State $State
    if ($existing.Epoch -match '^\d+$') { $seq = [int]$existing.Epoch }
    $seq++
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $tmp = "$path.tmp.$PID"
    try {
        Write-FmSessionTextFile -Path $tmp -Content "epoch=$seq owner_pid=$PID outcome=$Outcome updated_at=$now`n"
        [void](Move-FmSessionFileInPlace -Source $tmp -Destination $path)
    } catch { Write-Debug "hooks: could not record the auto-arm epoch; the next stop re-reads the previous one: $_" } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FmHookBudgetRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$State)

    $path = Join-Path $State '.turnend-claude-blocks'
    $record = [pscustomobject]@{ Session = ''; Count = 0; Epoch = ''; Present = $false; Path = $path }
    $lines = @(Get-FmSessionFileLines -Path $path)
    if ($lines.Count -lt 1) { return $record }
    $record.Present = $true
    foreach ($line in $lines) {
        $kv = $line -split '=', 2
        if ($kv.Count -ne 2) { continue }
        switch ($kv[0]) {
            'session' { $record.Session = $kv[1] }
            'count' { if ($kv[1] -match '^\d+$') { $record.Count = [int]$kv[1] } }
            'epoch' { $record.Epoch = $kv[1] }
        }
    }
    $record
}

function Write-FmHookBudgetRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Epoch
    )

    $path = Join-Path $State '.turnend-claude-blocks'
    $tmp = "$path.tmp.$PID"
    try {
        Write-FmSessionTextFile -Path $tmp -Content "session=$Session`ncount=$Count`nepoch=$Epoch`n"
        return (Move-FmSessionFileInPlace -Source $tmp -Destination $path)
    } catch {
        return $false
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Positive watcher recovery clears the block budget, the failure notice, and the
# attended alarm together, so a future independent episode starts clean.
function Reset-FmHookFailureEpisode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [ValidateSet('acquire', 'held')][string]$Mode = 'acquire'
    )

    $lock = Join-Path $State '.turnend-claude-blocks.lock'
    $acquired = $false
    if ($Mode -eq 'acquire') {
        if (-not (New-FmHookLock -Path $lock)) { return $false }
        $acquired = $true
    } else {
        if ((Get-FmHookLockField -Path $lock -Field 'pid') -ne [string]$PID) { return $false }
    }

    $ok = $true
    foreach ($name in @('.turnend-claude-blocks', '.claude-autoarm-failure-notified', '.claude-autoarm-failure-alarmed')) {
        $path = Join-Path $State $name
        if (Test-Path -LiteralPath $path -PathType Container) { $ok = $false; break }
        try {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        } catch {
            $ok = $false
            break
        }
    }
    if ($acquired) { Remove-FmHookLock -Path $lock }
    return $ok
}

# --- SessionStart -------------------------------------------------------------

# Source routing, port of bin/fm-sessionstart-run.sh.
# WINDOWS-UNVERIFIED: the set of session-open source values Claude Code emits on
# Windows. An unrecognized source deliberately routes to a full digest, so an
# unexpected value costs one redundant startup rather than a missed one.
#   startup, new         full digest - this process has not taken the helm
#   clear, compact       re-emit only when this lock owner recorded a completed
#                        full startup; otherwise a full digest, so a startup
#                        killed mid-sweep is finished first
#   resume, reload, fork  delegate to the nudge, because prior context is restored
function Get-FmHookSessionStartRoute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Source,
        [Parameter(Mandatory)][bool]$StartupCompleted
    )

    switch ($Source) {
        { $_ -in 'resume', 'reload', 'fork' } { return 'nudge' }
        { $_ -in 'clear', 'compact' } { return $(if ($StartupCompleted) { 'reemit' } else { 'full' }) }
        # An unreadable or unrecognized source is treated as `startup`, because
        # taking the helm redundantly is cheap and idempotent while not taking it
        # is the whole bug.
        default { return 'full' }
    }
}

function Test-FmHookStartupCompleted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$State)

    $lockFile = Join-Path $State '.lock'
    $completionFile = Join-Path $State '.session-start-complete'
    foreach ($path in @($lockFile, $completionFile)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not $item -or $item.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) { return $false }
    }

    $ownedBySelf = Resolve-FmSessionCommand -Name 'Test-FmSessionLockOwnedBySelf'
    if ($ownedBySelf) {
        try { if (-not (& $ownedBySelf -State $State)) { return $false } } catch { return $false }
    }

    $lockLines = @(Get-FmSessionFileLines -Path $lockFile)
    $completionLines = @(Get-FmSessionFileLines -Path $completionFile)
    if ($lockLines.Count -lt 1 -or $completionLines.Count -lt 1) { return $false }
    if ($lockLines[0] -notmatch '^\d+$') { return $false }
    return ($completionLines[0] -eq $lockLines[0])
}

# --- PreToolUse ---------------------------------------------------------------

# The command string a PreToolUse payload carries. Grok writes toolInput,
# Claude and Codex write tool_input.
function Get-FmHookToolCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Payload)

    if ($null -eq $Payload) { return '' }
    foreach ($key in @('toolInput', 'tool_input')) {
        if ($Payload.ContainsKey($key) -and $Payload[$key] -is [hashtable]) {
            $input_ = $Payload[$key]
            if ($input_.ContainsKey('command') -and $input_['command'] -is [string]) { return [string]$input_['command'] }
        }
    }
    return ''
}

# Read one field off a policy verdict without assuming the shape. The policy
# owners live in other areas, so a verdict missing a field is an invalid response
# to fail open on, not an exception to throw - and under Set-StrictMode -Version
# Latest a bare property access on a missing member IS an exception.
function Get-FmHookVerdictField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Verdict,
        [Parameter(Mandatory)][string]$Field
    )

    if ($null -eq $Verdict) { return $null }
    if ($Verdict -is [hashtable]) {
        if ($Verdict.ContainsKey($Field)) { return $Verdict[$Field] }
        return $null
    }
    $property = $Verdict.PSObject.Properties[$Field]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Render the established Claude-shaped deny response. Claude requires stdout to
# remain empty on deny, so the decision object carries it on stderr only.
# WINDOWS-UNVERIFIED: that Claude Code on Windows reads this hookSpecificOutput
# shape from a PowerShell-native hook's stderr.
function New-FmHookDenyDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Reason
    )

    $detail = "[$Code] $Reason"
    $body = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName      = 'PreToolUse'
            permissionDecision = 'deny'
        }
        systemMessage      = ($detail -replace "`r?`n", ' ')
    }
    New-FmHookDecision -ExitCode 2 -Stderr @(($body | ConvertTo-Json -Compress -Depth 8))
}

# --- Claude Code settings emission --------------------------------------------

# WINDOWS-UNVERIFIED: the "shell": "powershell" per-hook field and the exact
# command-string quoting Claude Code applies on Windows are taken from Claude
# Code's documentation and have not been executed against a Windows host.
function Get-FmClaudeHookSettingsObject {
    [CmdletBinding()]
    param()

    $entry = {
        param($script, $argument)
        $command = "& `"`$env:CLAUDE_PROJECT_DIR/bin/$script`""
        if ($argument) { $command += " $argument" }
        [ordered]@{ type = 'command'; shell = 'powershell'; command = $command }
    }

    $sessionStart = & $entry 'fm-claude-hook.ps1' '-Event SessionStart'
    $preToolArm = & $entry 'fm-claude-hook.ps1' '-Event PreToolUse -Check arm'
    $preToolCd = & $entry 'fm-claude-hook.ps1' '-Event PreToolUse -Check cd'
    $preToolSubagent = & $entry 'fm-claude-hook.ps1' '-Event PreToolUse -Check subagent'
    $stopGuard = & $entry 'fm-claude-hook.ps1' '-Event Stop -Check turnend-guard'
    $stopAutoArm = & $entry 'fm-claude-hook.ps1' '-Event Stop -Check autoarm'
    # asyncRewake fires the auto-arm in the background on EVERY Stop, with a
    # multi-hour timeout, and lets its exit 2 wake an idle session.
    $stopAutoArm['asyncRewake'] = $true
    $stopAutoArm['timeout'] = 28800

    [ordered]@{
        hooks = [ordered]@{
            SessionStart = @(@{ hooks = @($sessionStart) })
            PreToolUse   = @(
                [ordered]@{ matcher = 'Bash'; hooks = @($preToolArm, $preToolCd) },
                [ordered]@{ matcher = '.*'; hooks = @($preToolSubagent) }
            )
            Stop         = @(@{ hooks = @($stopGuard, $stopAutoArm) })
        }
    }
}
