# fm-afk-launch.ps1 - the single owner of the away-mode daemon TERMINAL
# lifecycle: launch it in a NON-VISIBLE tracked terminal per backend, record its
# exact id, tear it down by that exact id, and reconcile a leaked one after a
# crash.
#
# Twin: bin/fm-afk-launch.sh
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.ps1 becomes the supervise daemon in whatever terminal it is
# already in. A harness with a native in-pane tracked-background tool (claude,
# grok) runs it there directly and it is fine. A harness with NO native
# background mechanism (pi) has to manufacture a terminal, and doing that by
# SPLITTING the captain's active pane visibly shrinks it. Instead this creates a
# non-visible tracked terminal (a herdr tab/workspace with --no-focus, or a
# detached tmux session) that never touches the captain's active tab, and never
# a fire-and-forget child that the harness can reap.
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited environment. Running it in a separate terminal would
# make it discover its OWN pane, so this captures the captain pane FIRST (from
# the pane this script runs in) and passes it in as FM_SUPERVISOR_TARGET /
# FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.ps1 start          Capture the captain pane, then launch.
#   fm-afk-launch.ps1 start-native   Prepare lifecycle state for a harness-native
#                                    background job; record that no terminal exists.
#   fm-afk-launch.ps1 stop           Ordered exit: signal the daemon, wait, close
#                                    the recorded terminal by exact id, clear .afk last.
#   fm-afk-launch.ps1 reconcile      Close a recorded-but-dead terminal by exact id.
#
# Supported backends: herdr, tmux. Others refuse loudly.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal, FM_AFK_LAUNCH_LABEL pins the herdr workspace label, and
# FM_SUPERVISOR_TARGET / FM_SUPERVISOR_BACKEND override the captured captain pane.
#
# ---------------------------------------------------------------------------
# FIVE CONVERSION DECISIONS THAT ARE BEHAVIOR, NOT STYLE
#
# 1. NO SIGNALS. The bash twin arms `trap ... EXIT/INT/TERM` and stops the daemon
#    with `kill -TERM`. Windows has neither, so (a) the lock is released in a
#    `finally`, which covers every ordinary and exceptional exit but NOT a
#    hard kill, and (b) the daemon is stopped by closing its process, which is
#    the only Windows primitive with the same effect. The bash twin's 130/143
#    exit codes therefore have no twin here (docs/powershell-port.md, "Signals").
#    A daemon that does not exit still PRESERVES lifecycle state, which is the
#    safe direction and is unchanged.
#
# 2. THE PANE COMMAND IS POWERSHELL SYNTAX. The bash twin composes
#    `exec env FM_HOME=%q ... %q` because it drives a POSIX pane. A PowerShell
#    firstmate drives PowerShell panes directly (docs/powershell-port.md,
#    "Windows-native wins"), so the command is `$env:X='...'; & '<entry>'` with
#    single-quote doubling as the quoting rule. The ENTRY ITSELF is resolved the
#    way Invoke-FmScript resolves any execute edge - the .ps1 twin when it exists
#    and is non-empty, the .sh through Git Bash otherwise - so this works
#    whichever side of the conversion the daemon entry is on (contract 7).
#
# 3. THE LAUNCHER LOCK IS THIS SCRIPT'S OWN, NOT fm-wake-lib's. The bash twin
#    rolls a private `mkdir`-gated lock directory holding `pid` and
#    `pid-identity`, with its own incomplete-record and stale-owner reclaim
#    rules. It is NOT the wake-lib protocol and must not be "improved" into it:
#    the two publish different shapes, and a launcher started from bash must be
#    able to read a lock left by PowerShell and vice versa. `New-Item -ItemType
#    Directory` is the exclusive-create primitive (it THROWS when the directory
#    exists), which `[System.IO.Directory]::CreateDirectory` is not.
#
# 4. JSON IS PARSED IN-PROCESS. Every `jq` invocation becomes
#    ConvertFrom-Json -AsHashtable. A malformed or empty herdr response yields
#    $null and is treated exactly as the bash `|| ...` arms treat a jq failure.
#
# 5. THE RECORD FORMAT IS UNCHANGED. state/.afk-daemon-terminal stays exactly one
#    LF-terminated line of three TAB fields, and the validator still demands
#    exactly that (one line, three fields, per-backend extra rules), because a
#    home may be stopped by one language after being started by the other.
#
# NO param() BLOCK and $args CAPTURED FIRST, for the reasons the exemplar
# bin/fm-operational-input.ps1 records.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on fm-common: -Force re-runs the module body, whose console-encoding
# assignment REPLACES [Console]::Out, which would break any caller (or batch
# differential driver) that had redirected it.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-psproc-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervisor-target-lib.psm1')
# The daemon-lock liveness helpers and the stale-artifact clear, imported exactly
# where the bash twin SOURCES bin/fm-afk-start.sh for the same three functions.
Import-Module (Join-Path $PSScriptRoot 'fm-afk-start.psm1')

$fmArgv = @($args)

$script:FmOrdinal = [System.StringComparison]::Ordinal

# --- context -----------------------------------------------------------------
#
# The bash twin resolves a RELATIVE FM_HOME / FM_STATE_OVERRIDE through
# `cd -- "$x" && pwd -P` and exits 1 with a named diagnostic when that fails,
# because every later path is built from it and a silently-relative state
# directory would scatter lifecycle records under whatever cwd the caller had.
# Reproduced exactly, including the two message texts.

function Resolve-FmAfkLaunchDir {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Value,
        [Parameter(Mandatory, Position = 1)][string]$Label
    )

    $native = ConvertTo-FmNativePath -Path $Value
    if ([System.IO.Path]::IsPathRooted($native)) { return $native }
    try {
        $resolved = (Resolve-Path -LiteralPath $native -ErrorAction Stop).ProviderPath
        if ([System.IO.Directory]::Exists($resolved)) { return $resolved }
    } catch {
        $null = $_
    }
    Write-FmErr "error: $Label directory cannot be resolved: $Value"
    Exit-FmScript 1
}

$script:FmLaunchContext = Get-FmContext -ScriptRoot $PSScriptRoot
$script:FmLaunchRoot = $script:FmLaunchContext.Root
$script:FmLaunchHome = Resolve-FmAfkLaunchDir -Value $script:FmLaunchContext.Home -Label 'FM_HOME'
$stateOverride = Get-FmEnv -Name 'FM_STATE_OVERRIDE'
if ($stateOverride -ne '') {
    $script:FmLaunchState = Resolve-FmAfkLaunchDir -Value $stateOverride -Label 'FM_STATE_OVERRIDE'
} else {
    $script:FmLaunchState = "$script:FmLaunchHome/state"
}
$script:FmLaunchRecord = "$script:FmLaunchState/.afk-daemon-terminal"
$script:FmLaunchLock = "$script:FmLaunchState/.afk-launch.lock"
$script:FmLaunchWsLabel = 'firstmate-afk-daemon'

# The recorded terminal, published by Read-FmAfkLaunchRecord exactly as the bash
# twin publishes FM_AFK_REC_BACKEND / FM_AFK_REC_TARGET, because four callers
# read them after an unrelated call has run in between.
$script:FmRecBackend = ''
$script:FmRecTarget = ''

function Write-FmAfkLaunchLog {
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-FmErr "fm-afk-launch: $Message"
}

# --- the launcher's own lock -------------------------------------------------

<#
.SYNOPSIS
True when the launcher lock is held by a live process with the recorded identity.
.DESCRIPTION
Twin of fm_afk_launch_lock_owned. Every one of the bash `cat ... || return 1`
arms is a REFUSAL to claim ownership on missing evidence: no directory, no pid,
no recorded identity, or an unreadable current identity all answer false, which
is what lets the acquire loop reclaim a lock whose owner died mid-write.
#>
function Test-FmAfkLaunchLockOwned {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath -Path $script:FmLaunchLock))) { return $false }
    $lockPid = Get-FmFileText -Path "$script:FmLaunchLock/pid"
    if ([string]::IsNullOrEmpty($lockPid)) { return $false }
    $expected = Get-FmFileText -Path "$script:FmLaunchLock/pid-identity"
    if ([string]::IsNullOrEmpty($expected)) { return $false }
    $actual = Get-FmPidIdentity -ProcessId $lockPid
    if ([string]::IsNullOrEmpty($actual)) { return $false }
    return [string]::Equals($actual, $expected, $script:FmOrdinal)
}

<#
.SYNOPSIS
Claim the launcher lock, waiting out a live holder (fm_afk_launch_lock_acquire).
.DESCRIPTION
Three states the loop distinguishes, and the distinction is the whole point:

  - the directory does not exist    -> claim it, then publish pid and identity;
  - it exists but its records are INCOMPLETE -> a claim is in flight, so wait,
    bounded at 20 consecutive observations before it counts as abandoned;
  - it exists with complete records naming a DEAD or mismatched owner -> reclaim.

`New-Item -ItemType Directory` is the exclusive-create gate: it throws when the
directory already exists, which is the `mkdir` semantics the protocol needs.
[System.IO.Directory]::CreateDirectory succeeds silently on an existing
directory and would hand the lock to two processes at once.
#>
function Request-FmAfkLaunchLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $lockNative = ConvertTo-FmNativePath -Path $script:FmLaunchLock
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $script:FmLaunchState))
    } catch {
        return $false
    }

    $attempt = 0
    $incomplete = 0
    while ($attempt -lt 200) {
        $attempt++
        $claimed = $false
        try {
            [void](New-Item -ItemType Directory -Path $lockNative -ErrorAction Stop)
            $claimed = $true
        } catch {
            $claimed = $false
        }
        if ($claimed) {
            try {
                Set-FmFileText -Path "$script:FmLaunchLock/pid" -Text ([string]$PID) -NoNewline
            } catch {
                Remove-FmAfkLaunchLockDir
                return $false
            }
            $identity = Get-FmPidIdentity -ProcessId ([string]$PID)
            if ([string]::IsNullOrEmpty($identity)) {
                Remove-FmAfkLaunchLockDir
                return $false
            }
            try {
                Set-FmFileText -Path "$script:FmLaunchLock/pid-identity" -Text $identity -NoNewline
            } catch {
                Remove-FmAfkLaunchLockDir
                return $false
            }
            return $true
        }

        $pidText = Get-FmFileText -Path "$script:FmLaunchLock/pid"
        $identityText = Get-FmFileText -Path "$script:FmLaunchLock/pid-identity"
        if ([string]::IsNullOrEmpty($pidText) -or [string]::IsNullOrEmpty($identityText)) {
            $incomplete++
            if ($incomplete -lt 20) {
                Start-Sleep -Milliseconds 50
                continue
            }
        } else {
            $incomplete = 0
        }
        if (-not (Test-FmAfkLaunchLockOwned)) {
            if (-not (Remove-FmAfkLaunchLockDir)) { return $false }
            $incomplete = 0
            continue
        }
        Start-Sleep -Milliseconds 50
    }
    Write-FmAfkLaunchLog 'timed out waiting for launcher lock'
    return $false
}

function Remove-FmAfkLaunchLockDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of `rm -rf` on this script''s own lock directory; a confirmation surface would diverge from the twin and stall a non-interactive launch.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $native = ConvertTo-FmNativePath -Path $script:FmLaunchLock
        if ([System.IO.Directory]::Exists($native)) { [System.IO.Directory]::Delete($native, $true) }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Release the launcher lock, and ONLY when this process owns it.
.DESCRIPTION
Twin of fm_afk_launch_lock_release. The pid check is what makes it safe to arm
before the claim succeeds: a process that never owned the lock removes nothing.
#>
function Unlock-FmAfkLaunchLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $lockPid = Get-FmFileText -Path "$script:FmLaunchLock/pid"
    if (-not [string]::Equals($lockPid, [string]$PID, $script:FmOrdinal)) { return $true }
    return (Remove-FmAfkLaunchLockDir)
}

# --- usage --------------------------------------------------------------------

<#
.SYNOPSIS
The CLI usage text, one array element per line.
.DESCRIPTION
The bash twin renders it from its own comment block (`sed -n '2,34p'`), which has
no honest PowerShell equivalent. Reproduced literally - including the line that
ends mid-sentence, which is what the bash range actually prints, and including
the .sh spellings, because CLI surfaces stay identical during the transition
(docs/powershell-port.md contract 4).
#>
function Get-FmAfkLaunchUsage {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:'
        'launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,'
        'tear it down by that exact id, and reconcile a leaked one after a crash.'
        ''
        'Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):'
        'bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever'
        'terminal it is already in. Harnesses with a native in-pane tracked-background'
        'tool (claude, grok) run it there directly and it is fine. A harness with NO'
        'native background mechanism (pi) has to manufacture a terminal, and doing that'
        "by SPLITTING the captain's active pane visibly shrinks it - the regression this"
        'script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/'
        'workspace with --no-focus, or a detached tmux session) that never touches the'
        "captain's active tab, and NEVER uses shell ``&`` (which herdr/codex can reap)."
        ''
        'Correct supervisor targeting: the daemon finds the captain pane to inject into'
        'from its OWN inherited env (discover_supervisor_target). Running it in a'
        'separate terminal would make it discover its OWN pane, so this captures the'
        'captain pane FIRST (from the pane this script runs in) and passes it in as'
        'FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.'
        ''
        'Usage:'
        '  fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon'
        '                             is already running) launch the daemon in a fresh'
        '                             non-visible terminal for the detected backend and'
        '                             record it. Idempotent: an already-running daemon'
        '                             just refreshes state/.afk; a recorded-but-dead'
        '                             terminal is reconciled (closed by id) first.'
        '  fm-afk-launch.sh start-native'
        '                             Prepare lifecycle state for a harness-native'
        '                             background job and record that no terminal exists.'
        '  fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its'
        '                             cleanup flushes WHILE state/.afk is still present,'
        '                             wait for it, close the recorded terminal by exact'
    )
}

# --- the daemon entry and its pane command -----------------------------------

<#
.SYNOPSIS
The daemon entry command to run inside the created terminal.
.DESCRIPTION
Twin of fm_afk_launch_entry_cmd. FM_AFK_LAUNCH_ENTRY is the test seam and wins
outright; otherwise the entry is resolved the way Invoke-FmScript resolves every
execute edge - bin/fm-afk-start.ps1 when it exists and is non-empty, and
bin/fm-afk-start.sh otherwise - so this launcher is correct whichever side of the
conversion the daemon entry is on, and cutover deletes one branch rather than
editing this call site.
#>
function Get-FmAfkLaunchEntry {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $override = Get-FmEnv -Name 'FM_AFK_LAUNCH_ENTRY'
    if ($override -ne '') { return $override }
    $psTwin = "$script:FmLaunchRoot/bin/fm-afk-start.ps1"
    $native = ConvertTo-FmNativePath -Path $psTwin
    if ([System.IO.File]::Exists($native) -and ([System.IO.FileInfo]::new($native)).Length -gt 0) {
        return $psTwin
    }
    return "$script:FmLaunchRoot/bin/fm-afk-start.sh"
}

<#
.SYNOPSIS
The full command line the created terminal runs.
.DESCRIPTION
The PowerShell twin of
`exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q`.
A PowerShell pane takes PowerShell syntax, so the environment is set with
`$env:` assignments and the entry is invoked with `&`. Quoting is single-quote
doubling, which is PowerShell's only literal-string escape and therefore cannot
be defeated by any character in a path.

A `.sh` entry is run through Git Bash with its POSIX spelling, because Windows
cannot execute a shebang script and bash cannot be relied on to accept a drive
path as a script argument.
#>
function Get-FmAfkLaunchCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$CaptainTarget,
        [Parameter(Mandatory, Position = 1)][string]$CaptainBackend
    )

    $entry = Get-FmAfkLaunchEntry
    $q = { param([string]$s) "'" + ($s -replace "'", "''") + "'" }
    $prefix = '$env:FM_HOME=' + (& $q $script:FmLaunchHome) +
        '; $env:FM_SUPERVISOR_TARGET=' + (& $q $CaptainTarget) +
        '; $env:FM_SUPERVISOR_BACKEND=' + (& $q $CaptainBackend) + '; '
    if ($entry.EndsWith('.sh', [System.StringComparison]::OrdinalIgnoreCase)) {
        $bash = Get-FmBash
        if (-not $bash) { $bash = 'bash' }
        return $prefix + '& ' + (& $q $bash) + ' ' + (& $q (ConvertTo-FmPosixPath $entry))
    }
    if ($entry.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $prefix + '& ' + (& $q $entry)
    }
    return $prefix + '& ' + (& $q $entry)
}

# --- the terminal record ------------------------------------------------------

function Write-FmAfkLaunchRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash mktemp+mv publish; a confirmation surface would diverge from the twin and stall a non-interactive launch.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Extra = ''
    )
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $script:FmLaunchState))
    } catch {
        return $false
    }
    return (Set-FmFileTextAtomic -Path $script:FmLaunchRecord -Text "$Backend`t$Target`t$Extra`n" -NoNewline)
}

<#
.SYNOPSIS
Refresh state/.afk atomically (fm_afk_launch_flag_write).
#>
function Write-FmAfkLaunchFlag {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash mktemp+mv publish of the away-mode flag; a confirmation surface would diverge from the twin and stall a non-interactive launch.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Set-FmFileTextAtomic -Path "$script:FmLaunchState/.afk" `
            -Text ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()))
}

<#
.SYNOPSIS
Read the recorded terminal. 0 = read, 1 = no record, 2 = malformed.
.DESCRIPTION
Twin of fm_afk_launch_record_read, publishing into $script:FmRecBackend /
$script:FmRecTarget. The validation is deliberately strict and its three-way
result is load-bearing: 1 means "nothing to reconcile" and is normal, while 2
means "there IS something recorded and I cannot identify it", which every caller
turns into a refusal rather than a sweep. Closing a terminal by anything other
than its exact recorded id is the failure this whole file exists to prevent.

Exactly ONE line and exactly THREE fields, then per-backend rules: herdr needs
its workspace id, tmux needs nothing more, and `none` must be the exact
`-`/`native` pair a harness-native start writes.
#>
function Read-FmAfkLaunchRecord {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $script:FmRecBackend = ''
    $script:FmRecTarget = ''
    $native = ConvertTo-FmNativePath -Path $script:FmLaunchRecord
    if (-not [System.IO.File]::Exists($native)) { return 1 }

    $lines = @(Get-FmFileLines -Path $script:FmLaunchRecord)
    $malformed = $false
    if ($lines.Count -ne 1) { $malformed = $true }
    $field = @()
    if (-not $malformed) {
        # .Split on the raw string with the count asserted, never a regex split:
        # a record with a legitimately EMPTY middle field must still read as
        # three fields (docs/powershell-port.md, "TAB record parsing").
        $field = @($lines[0].Split("`t", [System.StringSplitOptions]::None))
        if ($field.Count -ne 3) { $malformed = $true }
    }
    if (-not $malformed) {
        $script:FmRecBackend = $field[0]
        $script:FmRecTarget = $field[1]
        $extra = $field[2]
        if ([string]::IsNullOrEmpty($script:FmRecBackend) -or [string]::IsNullOrEmpty($script:FmRecTarget)) {
            $malformed = $true
        } elseif ([string]::Equals($script:FmRecBackend, 'herdr', $script:FmOrdinal)) {
            if ([string]::IsNullOrEmpty($extra)) { $malformed = $true }
        } elseif ([string]::Equals($script:FmRecBackend, 'tmux', $script:FmOrdinal)) {
            $malformed = $false
        } elseif ([string]::Equals($script:FmRecBackend, 'none', $script:FmOrdinal)) {
            if (-not ([string]::Equals($script:FmRecTarget, '-', $script:FmOrdinal) -and
                    [string]::Equals($extra, 'native', $script:FmOrdinal))) {
                $malformed = $true
            }
        } else {
            # An unknown backend is refused WITHOUT the diagnostic, exactly as the
            # bash `*) return 2` arm does: it leaves the case statement before the
            # shared log line.
            return 2
        }
    }
    if ($malformed) {
        Write-FmAfkLaunchLog 'daemon terminal record is malformed; refusing to act on it'
        return 2
    }
    return 0
}

function Test-FmAfkLaunchRecordValid {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Read-FmAfkLaunchRecord) -ne 2)
}

# --- herdr / tmux primitives --------------------------------------------------

<#
.SYNOPSIS
Split a herdr target into its session and pane, or $null when it is not one.
.DESCRIPTION
`session=${target%%:*}` and `pane=${target#*:}` plus the guard that BOTH are
non-empty and that the pane differs from the whole target - which is bash's way
of proving a ':' was actually present.
#>
function Split-FmAfkLaunchHerdrTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Target = '')

    if ([string]::IsNullOrEmpty($Target)) { return $null }
    $idx = $Target.IndexOf(':', $script:FmOrdinal)
    if ($idx -lt 0) { return $null }
    $session = $Target.Substring(0, $idx)
    $pane = $Target.Substring($idx + 1)
    if ([string]::IsNullOrEmpty($session) -or [string]::IsNullOrEmpty($pane)) { return $null }
    return @{ Session = $session; Pane = $pane }
}

<#
.SYNOPSIS
Parse a herdr JSON response into a hashtable, or $null.
.DESCRIPTION
The jq replacement (conversion decision 4). Every failure mode jq had - empty
output, invalid JSON, a scalar where an object was expected - collapses to $null
here, which every caller treats exactly as the bash `|| return`/`|| continue`
arms treated a jq failure.
#>
function ConvertFrom-FmAfkLaunchJson {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text = '')

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        $parsed = $Text | ConvertFrom-Json -AsHashtable
    } catch {
        return $null
    }
    if ($parsed -is [hashtable]) { return $parsed }
    return $null
}

<#
.SYNOPSIS
Walk a dotted key path through a parsed response, or $null.
#>
function Get-FmAfkLaunchJsonValue {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Node,
        [Parameter(Mandatory, Position = 1)][string[]]$Path
    )

    $current = $Node
    foreach ($key in $Path) {
        if ($null -eq $current) { return $null }
        if ($current -isnot [System.Collections.IDictionary]) { return $null }
        if (-not $current.Contains($key)) { return $null }
        $current = $current[$key]
    }
    return $current
}

function Close-FmAfkLaunchTerminal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash close-by-exact-id call; a confirmation surface would diverge from the twin and stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = ''
    )

    if ([string]::Equals($Backend, 'herdr', $script:FmOrdinal)) {
        if (-not (Import-FmBackendAdapter -Name 'herdr')) { return $false }
        $parts = Split-FmAfkLaunchHerdrTarget -Target $Target
        if ($null -eq $parts) { return $false }
        $result = Invoke-FmBackendHerdrCli -Session $parts.Session -Arguments @('pane', 'close', $parts.Pane)
        return [bool]$result.Ok
    }
    if ([string]::Equals($Backend, 'tmux', $script:FmOrdinal)) {
        # The recorded DEDICATED daemon session name - killed exactly, never a
        # pattern and never a sweep.
        if (-not (Test-FmCommand 'tmux')) { return $false }
        $result = Invoke-FmTool -FilePath 'tmux' -Arguments @('kill-session', '-t', $Target)
        return [bool]$result.Ok
    }
    if ([string]::Equals($Backend, 'none', $script:FmOrdinal)) { return $true }
    Write-FmAfkLaunchLog "cannot close unknown recorded backend '$Backend'"
    return $false
}

<#
.SYNOPSIS
True only when the terminal is PROVABLY gone (fm_afk_launch_terminal_absent).
.DESCRIPTION
Proof, not inference: herdr must answer with the exact `pane_not_found` error
code, and tmux must exit exactly 1 with its own "can't find session" wording. A
transport failure, an unreachable server, or any other error answers FALSE - so
an unconfirmed teardown preserves the exact id instead of dropping the record and
losing the ability to close the terminal later.
#>
function Test-FmAfkLaunchTerminalAbsent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = ''
    )

    if ([string]::Equals($Backend, 'herdr', $script:FmOrdinal)) {
        $parts = Split-FmAfkLaunchHerdrTarget -Target $Target
        if ($null -eq $parts) { return $false }
        $result = Invoke-FmBackendHerdrCli -Session $parts.Session -Arguments @('pane', 'get', $parts.Pane)
        if ($result.Ok) { return $false }
        $parsed = ConvertFrom-FmAfkLaunchJson -Text ($result.StdOut + $result.StdErr)
        $code = Get-FmAfkLaunchJsonValue -Node $parsed -Path @('error', 'code')
        return ($null -ne $code -and [string]::Equals([string]$code, 'pane_not_found', $script:FmOrdinal))
    }
    if ([string]::Equals($Backend, 'tmux', $script:FmOrdinal)) {
        if (-not (Test-FmCommand 'tmux')) { return $false }
        $result = Invoke-FmTool -FilePath 'tmux' -Arguments @('has-session', '-t', $Target)
        if ($result.ExitCode -ne 1) { return $false }
        return (($result.StdOut + $result.StdErr) -match "can't find session")
    }
    if ([string]::Equals($Backend, 'none', $script:FmOrdinal)) { return $true }
    return $false
}

function Close-FmAfkLaunchRecorded {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash teardown call; a confirmation surface would diverge from the twin and stall a non-interactive teardown.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $closed = Close-FmAfkLaunchTerminal -Backend $script:FmRecBackend -Target $script:FmRecTarget
    if (Test-FmAfkLaunchTerminalAbsent -Backend $script:FmRecBackend -Target $script:FmRecTarget) {
        $native = ConvertTo-FmNativePath -Path $script:FmLaunchRecord
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            return $false
        }
        if (-not $closed) {
            Write-FmAfkLaunchLog 'terminal close command failed, but exact absence was confirmed'
        }
        return $true
    }
    Write-FmAfkLaunchLog 'recorded terminal teardown is unconfirmed; preserving exact id'
    return $false
}

function Test-FmAfkLaunchTerminalAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = ''
    )

    if ([string]::Equals($Backend, 'herdr', $script:FmOrdinal)) {
        $parts = Split-FmAfkLaunchHerdrTarget -Target $Target
        if ($null -eq $parts) { return $false }
        return [bool](Invoke-FmBackendHerdrCli -Session $parts.Session -Arguments @('pane', 'get', $parts.Pane)).Ok
    }
    if ([string]::Equals($Backend, 'tmux', $script:FmOrdinal)) {
        if (-not (Test-FmCommand 'tmux')) { return $false }
        return [bool](Invoke-FmTool -FilePath 'tmux' -Arguments @('has-session', '-t', $Target)).Ok
    }
    # NOTE the missing `none` arm: it is missing in the bash twin too, so a
    # harness-native record is never "alive" here. Only Test-FmAfkLaunchTerminalAbsent
    # knows about `none`, which is what makes a native stop confirmable.
    return $false
}

<#
.SYNOPSIS
Wait for the launched daemon to take the lock, or for its terminal to die.
.DESCRIPTION
Twin of fm_afk_launch_wait_ready. Under the FM_AFK_LAUNCH_ENTRY test seam the
placeholder never claims the daemon lock, so readiness degrades to "the terminal
exists" - which is exactly what a topology test is asserting. Otherwise the loop
exits early the moment the terminal dies, so a daemon that failed to start is a
prompt failure rather than a five-second stall.
#>
function Wait-FmAfkLaunchReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = ''
    )

    if ((Get-FmEnv -Name 'FM_AFK_LAUNCH_ENTRY') -ne '') {
        return (Test-FmAfkLaunchTerminalAlive -Backend $Backend -Target $Target)
    }
    $attempt = 0
    while ($attempt -lt 100) {
        $attempt++
        if (Test-FmAfkDaemonLockLive -LockPath "$script:FmLaunchState/.supervise-daemon.lock") { return $true }
        if (-not (Test-FmAfkLaunchTerminalAlive -Backend $Backend -Target $Target)) { return $false }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Confirm-FmAfkLaunchTerminal {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Backend = '',
        [Parameter(Position = 1)][AllowEmptyString()][string]$Target = '',
        [Parameter(Position = 2)][AllowEmptyString()][string]$Extra = '',
        [Parameter(Position = 3)][bool]$AlreadyRecorded = $false
    )

    if (-not $AlreadyRecorded) {
        if (-not (Write-FmAfkLaunchRecord -Backend $Backend -Target $Target -Extra $Extra)) {
            Write-FmAfkLaunchLog "failed to persist daemon terminal record; closing ${Backend}:${Target}"
            [void](Close-FmAfkLaunchTerminal -Backend $Backend -Target $Target)
            return $false
        }
    }
    if (-not (Wait-FmAfkLaunchReady -Backend $Backend -Target $Target)) {
        Write-FmAfkLaunchLog "daemon did not become ready; closing ${Backend}:${Target}"
        $script:FmRecBackend = $Backend
        $script:FmRecTarget = $Target
        [void](Close-FmAfkLaunchRecorded)
        return $false
    }
    return $true
}

<#
.SYNOPSIS
Recover the exact workspace/pane ids of a herdr create that lost its response.
.DESCRIPTION
Twin of fm_afk_launch_herdr_recover_created. The label is unique per launch, so
finding EXACTLY ONE workspace carrying it and EXACTLY ONE pane inside it is
proof of identity; any other count refuses outright rather than picking one,
because a wrong id here would later close somebody else's terminal.
#>
function Get-FmAfkLaunchHerdrCreated {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Session,
        [Parameter(Mandatory, Position = 1)][string]$Label
    )

    $attempt = 0
    while ($attempt -lt 20) {
        $attempt++
        $listResult = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('workspace', 'list')
        if (-not $listResult.Ok) { Start-Sleep -Milliseconds 50; continue }
        $parsed = ConvertFrom-FmAfkLaunchJson -Text $listResult.StdOut
        $workspaces = Get-FmAfkLaunchJsonValue -Node $parsed -Path @('result', 'workspaces')
        if ($null -eq $workspaces) { Start-Sleep -Milliseconds 50; continue }
        $matched = @(@($workspaces) | Where-Object {
                $_ -is [System.Collections.IDictionary] -and $_.Contains('label') -and
                [string]::Equals([string]$_['label'], $Label, $script:FmOrdinal)
            })
        if ($matched.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }
        if ($matched.Count -ne 1) { return $null }
        $wsid = [string](Get-FmAfkLaunchJsonValue -Node $matched[0] -Path @('workspace_id'))
        if ([string]::IsNullOrEmpty($wsid)) { return $null }

        $paneResult = Invoke-FmBackendHerdrCli -Session $Session -Arguments @('pane', 'list', '--workspace', $wsid)
        if (-not $paneResult.Ok) { Start-Sleep -Milliseconds 50; continue }
        $panesParsed = ConvertFrom-FmAfkLaunchJson -Text $paneResult.StdOut
        $panes = Get-FmAfkLaunchJsonValue -Node $panesParsed -Path @('result', 'panes')
        if ($null -eq $panes) { Start-Sleep -Milliseconds 50; continue }
        $paneList = @($panes)
        if ($paneList.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }
        if ($paneList.Count -ne 1) { return $null }
        $pane = [string](Get-FmAfkLaunchJsonValue -Node $paneList[0] -Path @('pane_id'))
        if ([string]::IsNullOrEmpty($pane)) { return $null }
        return @{ Workspace = $wsid; Pane = $pane }
    }
    return $null
}

<#
.SYNOPSIS
Close a recorded-but-dead daemon terminal and drop the record.
.DESCRIPTION
Twin of fm_afk_launch_reconcile. A live daemon means there is nothing leaked, so
this is a no-op; a malformed record refuses (1) rather than guessing; and no
record at all is the ordinary clean state.
#>
function Invoke-FmAfkLaunchReconcile {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (Test-FmAfkDaemonLockLive -LockPath "$script:FmLaunchState/.supervise-daemon.lock") { return 0 }
    $read = Read-FmAfkLaunchRecord
    if ($read -eq 0) {
        Write-FmAfkLaunchLog "reconciling leaked daemon terminal $($script:FmRecBackend):$($script:FmRecTarget)"
        if (Close-FmAfkLaunchRecorded) { return 0 }
        return 1
    }
    if ($read -eq 2) { return 1 }
    return 0
}

# --- the launch transaction's backup / rollback -------------------------------

$script:FmLaunchArtifacts = @('.subsuper-escalations', '.subsuper-escalations.since', '.subsuper-inject-wedged')

<#
.SYNOPSIS
Take the pre-launch snapshot the rollback restores from. $null on failure.
#>
function New-FmAfkLaunchBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that creates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $stamp = [System.IO.Path]::GetRandomFileName().Replace('.', '').Substring(0, 6)
    $backup = "$script:FmLaunchState/.afk-launch-backup.$stamp"
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $backup))
    } catch {
        return $null
    }
    $hadAfk = $false
    try {
        if ([System.IO.File]::Exists((ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk"))) {
            $hadAfk = $true
            Copy-Item -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk") `
                -Destination (ConvertTo-FmNativePath -Path "$backup/.afk") -Force -ErrorAction Stop
        }
        foreach ($artifact in $script:FmLaunchArtifacts) {
            $source = ConvertTo-FmNativePath -Path "$script:FmLaunchState/$artifact"
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (ConvertTo-FmNativePath -Path "$backup/$artifact") `
                    -Force -ErrorAction Stop
            }
        }
    } catch {
        Remove-FmAfkLaunchTree -Path $backup
        return $null
    }
    return @{ Path = $backup; HadAfk = $hadAfk }
}

function Remove-FmAfkLaunchTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of `rm -rf` on this script''s own scratch directory; a confirmation surface would diverge from the twin and stall a non-interactive launch.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    try {
        $native = ConvertTo-FmNativePath -Path $Path
        if ([System.IO.Directory]::Exists($native)) { [System.IO.Directory]::Delete($native, $true) }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Undo a failed launch: restore the pre-launch away-mode state exactly.
.DESCRIPTION
Twin of fm_afk_launch_restore_backup. Everything the transaction may have
written is removed FIRST, then the snapshot is copied back, so a file that did
not exist before does not survive the rollback. A partial restoration RETAINS the
backup directory and says where it is, because losing the captain's buffered
escalations silently is worse than leaving a directory behind.
#>
function Restore-FmAfkLaunchBackup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash rollback that restores unconditionally; a confirmation surface would diverge from the twin and could leave a half-rolled-back home.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][hashtable]$Backup)

    $ok = $true
    foreach ($name in (@('.afk') + $script:FmLaunchArtifacts)) {
        $native = ConvertTo-FmNativePath -Path "$script:FmLaunchState/$name"
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $ok = $false
        }
    }
    if ($Backup.HadAfk) {
        try {
            Copy-Item -LiteralPath (ConvertTo-FmNativePath -Path "$($Backup.Path)/.afk") `
                -Destination (ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk") -Force -ErrorAction Stop
        } catch {
            $ok = $false
        }
    }
    foreach ($artifact in $script:FmLaunchArtifacts) {
        $source = ConvertTo-FmNativePath -Path "$($Backup.Path)/$artifact"
        if (Test-Path -LiteralPath $source) {
            try {
                Copy-Item -LiteralPath $source `
                    -Destination (ConvertTo-FmNativePath -Path "$script:FmLaunchState/$artifact") -Force -ErrorAction Stop
            } catch {
                $ok = $false
            }
        }
    }
    if ($ok) {
        if (-not (Remove-FmAfkLaunchTree -Path $Backup.Path)) { return $false }
        return $true
    }
    Write-FmAfkLaunchLog "rollback restoration incomplete; backup retained at $($Backup.Path)"
    return $false
}

# --- terminal creation --------------------------------------------------------

<#
.SYNOPSIS
Launch the daemon in a non-visible herdr workspace in the CAPTAIN's session.
.DESCRIPTION
Twin of fm_afk_launch_create_herdr. The workspace is created with --no-focus in
the captain's own session (the daemon must be able to inject into a pane that
lives there), and holds exactly one tab, so closing the pane takes the workspace
with it and no separate workspace close is needed.

The failure ordering is the interesting part and is preserved exactly: when the
create call FAILS but still returned exact ids, those ids are persisted BEFORE
the close attempt, so a crash in between still leaves the leaked terminal
identifiable rather than orphaned.
#>
function New-FmAfkLaunchHerdrTerminal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that creates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$CaptainTarget,
        [Parameter(Mandatory, Position = 1)][string]$CaptainBackend
    )

    $colon = $CaptainTarget.IndexOf(':', $script:FmOrdinal)
    $session = if ($colon -ge 0) { $CaptainTarget.Substring(0, $colon) } else { '' }
    if ([string]::IsNullOrEmpty($session)) {
        Write-FmAfkLaunchLog "cannot derive herdr session from captain target '$CaptainTarget'"
        return $false
    }
    if (-not (Import-FmBackendAdapter -Name 'herdr')) { return $false }
    if (-not (Initialize-FmBackendHerdrServer $session)) {
        Write-FmAfkLaunchLog "herdr server not ready for session '$session'"
        return $false
    }

    $label = Get-FmEnv -Name 'FM_AFK_LAUNCH_LABEL'
    if ($label -eq '') {
        $label = '{0}-{1}-{2}-{3}' -f $script:FmLaunchWsLabel, $PID, (Get-Random -Maximum 32768),
            ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }

    $created = Invoke-FmBackendHerdrCli -Session $session -Arguments @(
        'workspace', 'create', '--cwd', $script:FmLaunchHome, '--label', $label, '--no-focus')
    $parsed = ConvertFrom-FmAfkLaunchJson -Text $created.StdOut
    $wsid = [string](Get-FmAfkLaunchJsonValue -Node $parsed -Path @('result', 'workspace', 'workspace_id'))
    $pane = [string](Get-FmAfkLaunchJsonValue -Node $parsed -Path @('result', 'root_pane', 'pane_id'))

    if ((-not $created.Ok) -and $wsid -and $pane) {
        Write-FmAfkLaunchLog "herdr create failed after returning exact ids; closing ${session}:${pane}"
        if (Write-FmAfkLaunchRecord -Backend 'herdr' -Target "${session}:${pane}" -Extra $wsid) {
            $script:FmRecBackend = 'herdr'
            $script:FmRecTarget = "${session}:${pane}"
            [void](Close-FmAfkLaunchRecorded)
        } else {
            Write-FmAfkLaunchLog 'failed to persist exact id for failed herdr create'
        }
        return $false
    }
    if ((-not $wsid) -or (-not $pane)) {
        $recovered = Get-FmAfkLaunchHerdrCreated -Session $session -Label $label
        if ($null -eq $recovered) {
            Write-FmAfkLaunchLog 'herdr create did not yield a recoverable exact workspace/pane id'
            return $false
        }
        $wsid = $recovered.Workspace
        $pane = $recovered.Pane
    }

    $command = Get-FmAfkLaunchCommand -CaptainTarget $CaptainTarget -CaptainBackend $CaptainBackend
    if (-not (Write-FmAfkLaunchRecord -Backend 'herdr' -Target "${session}:${pane}" -Extra $wsid)) {
        Write-FmAfkLaunchLog "failed to persist herdr daemon terminal record; closing ${session}:${pane}"
        [void](Close-FmAfkLaunchTerminal -Backend 'herdr' -Target "${session}:${pane}")
        return $false
    }
    $run = Invoke-FmBackendHerdrCli -Session $session -Arguments @('pane', 'run', $pane, $command)
    if (-not $run.Ok) {
        Write-FmAfkLaunchLog "failed to run daemon in herdr pane ${session}:${pane}; closing it"
        $script:FmRecBackend = 'herdr'
        $script:FmRecTarget = "${session}:${pane}"
        [void](Close-FmAfkLaunchRecorded)
        return $false
    }
    if (-not (Confirm-FmAfkLaunchTerminal -Backend 'herdr' -Target "${session}:${pane}" -Extra $wsid -AlreadyRecorded $true)) {
        return $false
    }
    Write-FmAfkLaunchLog "daemon launched in non-visible herdr workspace $wsid (pane ${session}:${pane}), supervising $CaptainTarget"
    return $true
}

<#
.SYNOPSIS
The POSIX `cksum` checksum of a string, as a decimal number.
.DESCRIPTION
Used only to name the dedicated tmux daemon session after the home it serves, so
two homes on one tmux server never collide. Reproduced as the real CRC-32/cksum
algorithm rather than substituted with another hash, so a session name minted by
either language for the same home has the same stem - which is what makes a
`tmux ls` readable when a home has been stopped by one world and started by the
other.
#>
function Get-FmAfkLaunchCksum {
    [CmdletBinding()]
    [OutputType([uint32])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    $table = [uint32[]]::new(256)
    for ($i = 0; $i -lt 256; $i++) {
        [uint32]$c = [uint32]$i -shl 24
        for ($k = 0; $k -lt 8; $k++) {
            if ($c -band 0x80000000) { $c = (($c -shl 1) -bxor 0x04C11DB7) } else { $c = $c -shl 1 }
            $c = $c -band 0xFFFFFFFF
        }
        $table[$i] = $c
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    [uint32]$crc = 0
    foreach ($b in $bytes) {
        $crc = ((($crc -shl 8) -band 0xFFFFFFFF) -bxor $table[((($crc -shr 24) -bxor $b) -band 0xFF)])
    }
    [uint64]$len = $bytes.Length
    while ($len -ne 0) {
        $crc = ((($crc -shl 8) -band 0xFFFFFFFF) -bxor $table[((($crc -shr 24) -bxor ($len -band 0xFF)) -band 0xFF)])
        $len = $len -shr 8
    }
    return [uint32](($crc -bxor 0xFFFFFFFF) -band 0xFFFFFFFF)
}

<#
.SYNOPSIS
Launch the daemon in a DETACHED tmux session, never a split of the captain's.
.DESCRIPTION
Twin of fm_afk_launch_create_tmux. The record is written BEFORE the session is
created: tmux pane ids are server-global, so the daemon still reaches the captain
pane from a separate session, and persisting the planned name first means a crash
during creation still leaves the exact id to reconcile.
#>
function New-FmAfkLaunchTmuxTerminal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash function that creates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$CaptainTarget,
        [Parameter(Mandatory, Position = 1)][string]$CaptainBackend
    )

    $hash = [string](Get-FmAfkLaunchCksum -Text $script:FmLaunchHome)
    $nonce = '{0}-{1}-{2}' -f $PID, (Get-Random -Maximum 32768), ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $session = "fm-afk-daemon-$hash-$nonce"
    $command = Get-FmAfkLaunchCommand -CaptainTarget $CaptainTarget -CaptainBackend $CaptainBackend

    if (-not (Write-FmAfkLaunchRecord -Backend 'tmux' -Target $session -Extra '')) {
        Write-FmAfkLaunchLog "failed to persist planned tmux daemon session '$session'"
        return $false
    }
    $created = $false
    if (Test-FmCommand 'tmux') {
        $created = (Invoke-FmTool -FilePath 'tmux' -Arguments @('new-session', '-d', '-s', $session, $command)).Ok
    }
    if (-not $created) {
        Write-FmAfkLaunchLog "failed to create detached tmux daemon session '$session'"
        $native = ConvertTo-FmNativePath -Path $script:FmLaunchRecord
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            Write-FmAfkLaunchLog 'failed to remove planned tmux daemon record after creation failure'
        }
        return $false
    }
    if (-not (Confirm-FmAfkLaunchTerminal -Backend 'tmux' -Target $session -Extra '' -AlreadyRecorded $true)) {
        return $false
    }
    Write-FmAfkLaunchLog "daemon launched in detached tmux session '$session', supervising $CaptainTarget"
    return $true
}

# --- the four commands --------------------------------------------------------

<#
.SYNOPSIS
Enter away mode and launch the daemon in a fresh non-visible terminal.
.DESCRIPTION
Twin of fm_afk_launch_start, and a TRANSACTION: the away-mode flag and the
previous session's escalation artifacts are snapshotted before anything is
touched, and any failure - reconcile, stale-artifact clear, flag write, or the
backend launch itself - rolls the whole away-mode state back. Entering away mode
half-way is the failure this ordering prevents.

The captain pane is captured FIRST, before anything is created, because the
daemon must be told which pane to inject into and a pane discovered from inside
the new terminal would be the daemon's own.
#>
function Start-FmAfkLaunch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash command that mutates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk-return-catchup")) {
        Write-FmAfkLaunchLog 'return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode'
        return 1
    }
    $target = Get-FmSupervisorTarget
    if (-not $target.Detected) {
        Write-FmAfkLaunchLog 'could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)'
        return 1
    }
    $backend = Get-FmSupervisorBackend
    if (-not $backend.Detected) {
        Write-FmAfkLaunchLog 'could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)'
        return 1
    }
    $captainTarget = [string]$target.Value
    $captainBackend = [string]$backend.Value

    [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $script:FmLaunchState))

    if (Test-FmAfkDaemonLockLive -LockPath "$script:FmLaunchState/.supervise-daemon.lock") {
        if (-not (Test-FmAfkLaunchRecordValid)) { return 1 }
        if (-not (Write-FmAfkLaunchFlag)) {
            Write-FmAfkLaunchLog 'failed to refresh away-mode flag'
            return 1
        }
        Write-FmAfkLaunchLog 'daemon already running; refreshed away-mode flag (no new terminal)'
        return 0
    }

    $backup = New-FmAfkLaunchBackup
    if ($null -eq $backup) { return 1 }

    $result = 0
    if ((Invoke-FmAfkLaunchReconcile) -ne 0) {
        $result = 1
    } elseif (-not (Clear-FmAfkStaleArtifact -State $script:FmLaunchState)) {
        Write-FmAfkLaunchLog 'failed to clear stale away-mode artifacts'
        $result = 1
    }
    if ($result -eq 0 -and -not (Write-FmAfkLaunchFlag)) {
        Write-FmAfkLaunchLog 'failed to write away-mode flag'
        $result = 1
    }

    if ($result -eq 0) {
        if ([string]::Equals($captainBackend, 'herdr', $script:FmOrdinal)) {
            if (-not (New-FmAfkLaunchHerdrTerminal -CaptainTarget $captainTarget -CaptainBackend $captainBackend)) { $result = 1 }
        } elseif ([string]::Equals($captainBackend, 'tmux', $script:FmOrdinal)) {
            if (-not (New-FmAfkLaunchTmuxTerminal -CaptainTarget $captainTarget -CaptainBackend $captainBackend)) { $result = 1 }
        } else {
            Write-FmAfkLaunchLog "no non-visible daemon-launch primitive for backend '$captainBackend' yet (supported: herdr, tmux)"
            $result = 1
        }
    }

    if ($result -ne 0) {
        if (-not (Restore-FmAfkLaunchBackup -Backup $backup)) { $result = 1 }
    } elseif (-not (Remove-FmAfkLaunchTree -Path $backup.Path)) {
        $result = 1
    }
    return $result
}

<#
.SYNOPSIS
Prepare away-mode state for a harness-native background job.
.DESCRIPTION
Twin of fm_afk_launch_start_native. Same transaction as Start-FmAfkLaunch, but no
terminal is manufactured at all: the record says `none<TAB>-<TAB>native`, which
is the shape that lets `stop` confirm teardown without a backend to ask.
#>
function Start-FmAfkLaunchNative {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash command that mutates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode entry.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()

    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-FmNativePath -Path $script:FmLaunchState))
    } catch {
        return 1
    }
    if (Test-Path -LiteralPath (ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk-return-catchup")) {
        Write-FmAfkLaunchLog 'return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode'
        return 1
    }
    if (Test-FmAfkDaemonLockLive -LockPath "$script:FmLaunchState/.supervise-daemon.lock") {
        if (-not (Test-FmAfkLaunchRecordValid)) { return 1 }
        if (-not (Write-FmAfkLaunchFlag)) { return 1 }
        Write-FmAfkLaunchLog 'daemon already running; refreshed away-mode flag'
        return 0
    }

    $backup = New-FmAfkLaunchBackup
    if ($null -eq $backup) { return 1 }

    $result = 0
    if ((Invoke-FmAfkLaunchReconcile) -ne 0) { $result = 1 }
    if ($result -eq 0) {
        if (-not (Clear-FmAfkStaleArtifact -State $script:FmLaunchState)) {
            Write-FmAfkLaunchLog 'failed to clear stale away-mode artifacts'
            $result = 1
        } elseif (-not (Write-FmAfkLaunchFlag)) {
            $result = 1
        }
    }
    if ($result -eq 0) {
        if (-not (Write-FmAfkLaunchRecord -Backend 'none' -Target '-' -Extra 'native')) { $result = 1 }
    }
    if ($result -ne 0) {
        if (-not (Restore-FmAfkLaunchBackup -Backup $backup)) { $result = 1 }
    } elseif (-not (Remove-FmAfkLaunchTree -Path $backup.Path)) {
        $result = 1
    }
    return $result
}

<#
.SYNOPSIS
Leave away mode in the one order that does not lose buffered escalations.
.DESCRIPTION
Twin of fm_afk_launch_stop, and the ORDER is the whole contract:

  1. stop the daemon while state/.afk is STILL PRESENT, so its cleanup flush is
     not silently discarded by the flag's own presence gate;
  2. close the daemon's own terminal by its exact recorded id;
  3. clear state/.afk LAST.

A daemon that will not stop, or a terminal whose teardown cannot be confirmed,
PRESERVES the lifecycle state and reports it - the record stays so a later stop
can finish the job.

DIVERGENCE, stated plainly rather than glossed (docs/powershell-port.md,
"Signals"): Windows has no SIGTERM, and Stop-Process TERMINATES rather than
asking. So step 1 still happens while state/.afk is present, and the ORDER this
function exists to enforce is intact, but the daemon's own cleanup flush is not
guaranteed to run the way a signalled bash daemon's trap is. The safety net that
still holds is the one that always mattered most: nothing here clears .afk before
the daemon is gone, and any condition still true is re-derived by the next away
session rather than being read out of that flush. The identity re-check after the
wait is unchanged, so a REUSED pid is never mistaken for a daemon that refused to
exit.
#>
function Stop-FmAfkLaunch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The twin of a bash command that mutates unconditionally; a confirmation surface would diverge from the twin and stall a non-interactive away-mode exit.')]
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $read = Read-FmAfkLaunchRecord
    if ($read -eq 2) {
        Write-FmAfkLaunchLog 'malformed daemon terminal record; refusing to stop away mode'
        return 1
    }

    $result = 0
    $daemonPid = ''
    $pidIdentity = ''
    $lockPath = "$script:FmLaunchState/.supervise-daemon.lock"
    if (Test-FmAfkDaemonLockLive -LockPath $lockPath) {
        $daemonPid = Get-FmAfkDaemonLockPid -LockPath $lockPath
        if ([string]::IsNullOrEmpty($daemonPid)) { return 1 }
        $pidIdentity = Get-FmPidIdentity -ProcessId $daemonPid
        if ([string]::IsNullOrEmpty($pidIdentity)) { return 1 }
    }
    if (-not [string]::IsNullOrEmpty($daemonPid)) {
        $signalled = $false
        try {
            # The `kill -TERM` twin, as close as Windows gets. A console process
            # has no window to close politely, so this terminates; see the
            # DIVERGENCE note above for what that costs and what still holds.
            Stop-Process -Id ([int]$daemonPid) -ErrorAction Stop
            $signalled = $true
        } catch {
            $signalled = $false
        }
        if (-not $signalled) {
            Write-FmAfkLaunchLog "failed to signal away-mode daemon pid=$daemonPid"
            $result = 1
        }
        for ($i = 0; $i -lt 40; $i++) {
            if (-not (Test-FmPidAlive -ProcessId $daemonPid)) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    if ((-not [string]::IsNullOrEmpty($daemonPid)) -and (Test-FmPidAlive -ProcessId $daemonPid)) {
        $current = Get-FmPidIdentity -ProcessId $daemonPid
        if ([string]::IsNullOrEmpty($current)) {
            Write-FmAfkLaunchLog 'could not confirm away-mode daemon exit; preserving lifecycle state'
            return 1
        }
        if ([string]::Equals($current, $pidIdentity, $script:FmOrdinal)) {
            Write-FmAfkLaunchLog 'away-mode daemon did not exit after SIGTERM; preserving lifecycle state'
            return 1
        }
    }
    if ($read -eq 0) {
        if (-not (Close-FmAfkLaunchRecorded)) { $result = 1 }
    }
    $afkNative = ConvertTo-FmNativePath -Path "$script:FmLaunchState/.afk"
    try {
        if ([System.IO.File]::Exists($afkNative)) { [System.IO.File]::Delete($afkNative) }
    } catch {
        Write-FmAfkLaunchLog 'failed to clear away-mode flag'
        $result = 1
    }
    if ($result -eq 0) {
        Write-FmAfkLaunchLog 'away mode stopped; daemon terminal torn down and .afk cleared'
    } else {
        Write-FmAfkLaunchLog 'away mode stopped; terminal teardown remains recorded for retry'
    }
    return $result
}

<#
.SYNOPSIS
The CLI body: acquire the launcher lock, run one command, release it.
.DESCRIPTION
Twin of fm_afk_launch_main. The lock is released in a `finally` rather than by a
trap (conversion decision 1), which covers every ordinary and exceptional exit;
the release only ever removes a lock THIS process owns, so arming it before the
claim - as the bash twin's trap ordering deliberately does - stays safe.
#>
function Invoke-FmAfkLaunchMain {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }
    $argv = @($Arguments)
    $command = if ($argv.Count -ge 1) { [string]$argv[0] } else { 'start' }

    if (-not (Request-FmAfkLaunchLock)) { return 1 }
    $result = 0
    try {
        if ([string]::Equals($command, 'start', $script:FmOrdinal)) {
            $result = Start-FmAfkLaunch
        } elseif ([string]::Equals($command, 'start-native', $script:FmOrdinal)) {
            $result = Start-FmAfkLaunchNative
        } elseif ([string]::Equals($command, 'stop', $script:FmOrdinal)) {
            $result = Stop-FmAfkLaunch
        } elseif ([string]::Equals($command, 'reconcile', $script:FmOrdinal)) {
            $result = Invoke-FmAfkLaunchReconcile
        } elseif ($command -cin @('-h', '--help', 'help')) {
            foreach ($line in @(Get-FmAfkLaunchUsage)) { Write-FmOut $line }
            $result = 0
        } else {
            foreach ($line in @(Get-FmAfkLaunchUsage)) { Write-FmErr $line }
            $result = 2
        }
    } finally {
        if (-not (Unlock-FmAfkLaunchLock)) { $result = 1 }
    }
    return $result
}

# UnexpectedCode 70: this CLI documents 0, 1 and 2, and an escaped exception is a
# DEFECT rather than a documented refusal - a caller must never absorb one as a
# routine failure.
Invoke-FmMain -UnexpectedCode 70 {
    $fmExitCode = Invoke-FmAfkLaunchMain -Arguments $fmArgv
    Exit-FmScript -Code $fmExitCode
}
