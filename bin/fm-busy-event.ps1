# bin/fm-busy-event.ps1 - the ONLY writer of the semantic busy-state contract
# owned by bin/fm-busy-lib.psm1 (record format, gen binding, and classification
# live there; this script owns mutation mechanics only).
#
# Twin: bin/fm-busy-event.sh
#
# Subcommands:
#
#   arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]
#       Mint a fresh incarnation gen token, write the gen sidecar, and seed
#       the record at seq=1 (default: busy, source fm-spawn, event
#       launch-brief - the launch prompt IS a submitted turn). Prints the
#       minted gen on stdout so the caller can embed it into adapter wiring.
#       Arming again replaces the previous incarnation: late events carrying
#       the old gen are rejected as stale from then on.
#
#   apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen)
#         --source S --event E
#       Append one lifecycle event: validate the gen against the armed
#       sidecar, advance seq under the lock, atomically replace the record.
#       Adapter wiring passes the exact --gen embedded at arm time, so a
#       hook that outlives its incarnation is refused here. Firstmate-owned
#       paths (fm-interrupt, fm-recovery) may pass --current-gen to bind to
#       whatever incarnation is armed right now.
#
#   retire <state-dir> <id> (--gen G | --current-gen)
#       Remove one incarnation's sidecar and record while holding the same
#       writer lock used by arm and apply. An exact gen prevents teardown for
#       an old task from retiring a newly armed incarnation. A missing sidecar
#       is already retired, so any orphan record is removed idempotently.
#
# Exit codes: 0 applied; 1 refused (stale gen, unarmed task, lock timeout,
# invalid input); 2 usage. Adapter hook command lines append `|| true` so a
# refusal never breaks the harness's own lifecycle.
#
# ---------------------------------------------------------------------------
# FOUR CONVERSION DECISIONS
#
#   1. THE LOCK IS STILL A DIRECTORY. `mkdir` is bash's atomic claim primitive,
#      and other processes - including the bash twin, which keeps running
#      against the same homes for the whole conversion - identify the holder by
#      the DIRECTORY at <record>.lock. New-Item -ItemType Directory fails when
#      the target exists, which is the same claim; inventing a file lock or a
#      .NET FileStream lock here would make the two writers stop excluding each
#      other (docs/powershell-port.md, "Locks").
#
#   2. `umask 077` HAS NO TWIN, DELIBERATELY. The bash twin narrows the mode of
#      the record and sidecar it creates. On Windows chmod is inert and every
#      path already reads 644/755, so the bash tree accepts owner-held files in
#      place of a mode check. Setting a real ACL here would make files this
#      script writes stricter than the ones its bash twin writes in the same
#      home - the exact divergence docs/powershell-port.md forbids under "the
#      noacl private-file gates". Hardening, if it comes, is one deliberate
#      change across both worlds.
#
#   3. AN ESCAPED EXCEPTION IS A REFUSAL (1), NOT A CRASH. This script MUTATES.
#      A caller that saw anything other than a non-zero code would treat an
#      abandoned half-write as applied, so the catch-all reports the documented
#      refusal code with a diagnostic naming the fault. That is the opposite of
#      the PreToolUse guards in this package, which must fail OPEN - the
#      difference is that a guard's failure mode is "do not block", while a
#      writer's is "do not claim to have written".
#
#   4. THE RECORD VERSION COMES FROM THE LIBRARY. bash hard-codes `v1` in its
#      printf; fm-busy-lib.psm1's header calls out that a second literal would
#      be a silent format fork, so the writer asks Get-FmBusyLibVersion.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on either import. In a freshly spawned process it buys nothing
# (nothing is loaded yet), and it is actively harmful when this entrypoint is
# driven IN-PROCESS, as tests/fm-hooks-psm1.test.sh must drive it to keep the
# suite to one pwsh startup: -Force re-runs fm-common's module body, whose
# console-encoding assignment RESETS [Console]::In/Out, discarding a caller's
# redirection. Dropping it also sidesteps docs/powershell-port.md's
# "Never -Force a NESTED module import" trap entirely, since fm-busy-lib pulls
# fm-common in again.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-busy-lib.psm1')

$fmArgv = @($args)

# The usage() heredoc, one array element per line. It goes to STDERR and exits
# 2, unlike the PreToolUse guards whose -h prints to stdout and exits 0. It
# still names the .sh twin: the two files print the same bytes while both exist.
$script:FmBusyEventUsage = @(
    'usage:'
    '  fm-busy-event.sh arm <state-dir> <id> [--state busy|idle|unknown] [--source S] [--event E]'
    '  fm-busy-event.sh apply <state-dir> <id> <busy|idle|unknown> (--gen G | --current-gen) --source S --event E'
    '  fm-busy-event.sh retire <state-dir> <id> (--gen G | --current-gen)'
    'See the header comment for the full contract.'
)

function Write-FmBusyEventUsage {
    [CmdletBinding()]
    [OutputType([void])]
    param()
    foreach ($line in $script:FmBusyEventUsage) { Write-FmErr $line }
}

<#
.SYNOPSIS
The `mkdir "$LOCK"` twin: claim the lock directory, or report it already held.
.DESCRIPTION
New-Item throws when the directory exists, which is the atomic claim. Any other
failure (a missing parent, a denied path) is also "not claimed", matching the
bash twin's `2>/dev/null` swallow - the retry loop above handles both the same
way, and a lock that cannot be created at all ends as a timeout rather than as
an unguarded write.
#>
function New-FmBusyLockDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal helper on a lock path whose bash twin claims unconditionally. A -WhatIf/-Confirm surface would diverge from that twin and could stall the non-interactive adapter hooks that call this script.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    try {
        $null = New-Item -Path $Path -ItemType Directory -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Serialize writers on the record/sidecar pair, breaking a dead holder's lock.
.DESCRIPTION
Twin of lock_acquire: 40 attempts at 50ms, then one staleness check against
FM_BUSY_LOCK_STALE_SECS (default 5) with a single break-and-retake, then a
timeout refusal. Returns $true when the lock is held by this process.
#>
function Enter-FmBusyLock {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$Id
    )

    $native = ConvertTo-FmNativePath $LockPath
    $tries = 0
    while (-not (New-FmBusyLockDirectory $native)) {
        $tries++
        if ($tries -ge 40) {
            $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $mtime = $now
            try {
                $written = [System.IO.Directory]::GetLastWriteTimeUtc($native)
                $mtime = [int64]($written - [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)).TotalSeconds
            } catch {
                $mtime = $now
            }
            $age = $now - $mtime
            $staleSecs = 5
            $configured = Get-FmEnv 'FM_BUSY_LOCK_STALE_SECS' '5'
            $parsed = 0
            if ([int]::TryParse($configured, [ref]$parsed)) { $staleSecs = $parsed }
            if ($age -ge $staleSecs) {
                try { [System.IO.Directory]::Delete($native, $true) } catch { $null = $_ }
                if (New-FmBusyLockDirectory $native) { return $true }
            }
            Write-FmErr "error: busy-state lock timeout for $Id"
            return $false
        }
        Start-Sleep -Milliseconds 50
    }
    return $true
}

<#
.SYNOPSIS
Release the writer lock, best effort.
.DESCRIPTION
Twin of `rmdir "$LOCK" 2>/dev/null || true`. A release that cannot happen must
never turn a completed write into a reported failure; the staleness break above
is what recovers from it.
#>
function Exit-FmBusyLock {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)
    try { [System.IO.Directory]::Delete((ConvertTo-FmNativePath $LockPath), $true) } catch { $null = $_ }
}

<#
.SYNOPSIS
`rm -f` for one path: absent is success, and only a real failure is a failure.
#>
function Remove-FmBusyFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal `rm -f` twin whose bash original removes unconditionally. A -WhatIf/-Confirm surface would diverge from that twin and could stall the non-interactive adapter hooks that call this script.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    $native = ConvertTo-FmNativePath $Path
    try {
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
Write the single-line busy-state record atomically.
.DESCRIPTION
Twin of write_record: one LF-terminated line published by rename, so a
concurrent reader never observes a partial record. The version token comes from
the library rather than a second literal (decision 4 in the header).
#>
function Write-FmBusyRecordLine {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RecordPath,
        [Parameter(Mandatory, Position = 1)][string]$Gen,
        [Parameter(Mandatory, Position = 2)][int]$Seq,
        [Parameter(Mandatory, Position = 3)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory, Position = 4)][AllowEmptyString()][string]$Source,
        [Parameter(Mandatory, Position = 5)][AllowEmptyString()][string]$FmEvent
    )
    $ts = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $line = '{0} gen={1} seq={2} state={3} source={4} event={5} ts={6}' -f
        (Get-FmBusyLibVersion), $Gen, $Seq, $State, $Source, $FmEvent, $ts
    return (Set-FmFileTextAtomic -Path $RecordPath -Text ($line + "`n") -NoNewline)
}

<#
.SYNOPSIS
The seq currently recorded for <Gen>, or 0 when the record does not bind to it.
.DESCRIPTION
Twin of the OLD_SEQ block. Uses `head -n 1` semantics, NOT fm-busy-lib's strict
single-line read: an unterminated final line still yields its seq here, exactly
as head does, because this path only advances a counter and must not silently
restart it at 1. The gen test requires spaces on BOTH sides, so a gen that is
merely a prefix of the recorded one can never match.
#>
function Get-FmBusyRecordedSeq {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RecordPath,
        [Parameter(Mandatory, Position = 1)][string]$Gen
    )

    $native = ConvertTo-FmNativePath $RecordPath
    if (-not [System.IO.File]::Exists($native)) { return 0 }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($native) } catch { return 0 }
    if ($text -eq '') { return 0 }
    $nl = $text.IndexOf("`n")
    $line = if ($nl -ge 0) { $text.Substring(0, $nl) } else { $text }

    if (-not $line.Contains(" gen=$Gen ")) { return 0 }

    # ${line##* seq=} strips through the LAST ' seq=', then %% * keeps the head.
    $idx = $line.LastIndexOf(' seq=')
    $field = if ($idx -lt 0) { $line } else { $line.Substring($idx + 5) }
    $space = $field.IndexOf(' ')
    if ($space -ge 0) { $field = $field.Substring(0, $space) }
    if ($field -cnotmatch '\A[0-9]+\z') { return 0 }
    $value = 0
    if (-not [int]::TryParse($field, [ref]$value)) { return 0 }
    return $value
}

<#
.SYNOPSIS
The whole CLI, returning the process exit code instead of taking it.
#>
function Invoke-FmBusyEventMain {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'This is a script entrypoint body, not a user-facing cmdlet. Its bash twin writes unconditionally, and adding a -WhatIf/-Confirm surface would diverge from that twin and could stall the non-interactive adapter hooks that call it.')]
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $argv = @($Arguments)

    $cmd = if ($argv.Count -ge 1) { $argv[0] } else { '' }
    if ($cmd -cne 'arm' -and $cmd -cne 'apply' -and $cmd -cne 'retire') {
        Write-FmBusyEventUsage
        return 2
    }
    $argv = @($argv | Select-Object -Skip 1)

    $stateDir = if ($argv.Count -ge 1) { $argv[0] } else { '' }
    $id = if ($argv.Count -ge 2) { $argv[1] } else { '' }
    if ([string]::IsNullOrEmpty($stateDir) -or [string]::IsNullOrEmpty($id)) {
        Write-FmBusyEventUsage
        return 2
    }
    $argv = @($argv | Select-Object -Skip 2)

    if ($id -cmatch '[^A-Za-z0-9._\-]') {
        Write-FmErr 'error: invalid task id'
        return 1
    }
    if (-not (Test-Path -LiteralPath (ConvertTo-FmNativePath $stateDir) -PathType Container)) {
        Write-FmErr "error: state dir not found: $stateDir"
        return 1
    }

    $newState = ''
    $gen = ''
    $useCurrentGen = $false
    $source = ''
    $fmEvent = ''

    if ($cmd -ceq 'apply') {
        $newState = if ($argv.Count -ge 1) { $argv[0] } else { '' }
        if ($newState -cne 'busy' -and $newState -cne 'idle' -and $newState -cne 'unknown') {
            Write-FmBusyEventUsage
            return 2
        }
        $argv = @($argv | Select-Object -Skip 1)
    } elseif ($cmd -ceq 'arm') {
        $newState = 'busy'
        $source = 'fm-spawn'
        $fmEvent = 'launch-brief'
    }

    $i = 0
    while ($i -lt $argv.Count) {
        $arg = $argv[$i]
        # `shift 2 || usage`: bash's shift fails when fewer than two arguments
        # remain, so a trailing value-taking flag with no value is a usage error
        # rather than an empty assignment.
        if ($arg -ceq '--state' -or $arg -ceq '--gen' -or $arg -ceq '--source' -or $arg -ceq '--event') {
            if ($i + 2 -gt $argv.Count) {
                Write-FmBusyEventUsage
                return 2
            }
            $value = $argv[$i + 1]
            switch ($arg) {
                '--state' { $newState = $value }
                '--gen' { $gen = $value }
                '--source' { $source = $value }
                '--event' { $fmEvent = $value }
            }
            $i += 2
        } elseif ($arg -ceq '--current-gen') {
            $useCurrentGen = $true
            $i += 1
        } else {
            Write-FmBusyEventUsage
            return 2
        }
    }

    if ($cmd -cne 'retire') {
        if ($newState -cne 'busy' -and $newState -cne 'idle' -and $newState -cne 'unknown') {
            Write-FmBusyEventUsage
            return 2
        }
        if (-not (Test-FmBusyToken $source)) {
            Write-FmErr 'error: invalid --source'
            return 1
        }
        if (-not (Test-FmBusyToken $fmEvent)) {
            Write-FmErr 'error: invalid --event'
            return 1
        }
    }

    $record = Get-FmBusyRecordPath $stateDir $id
    $genFile = Get-FmBusyGenPath $stateDir $id
    $lock = "$record.lock"

    if ($cmd -ceq 'arm') {
        $gen = 'g{0}.{1}.{2}' -f ([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()), $PID, (Get-Random -Minimum 0 -Maximum 32768)
        if (-not (Enter-FmBusyLock $lock $id)) { return 1 }
        $ok = Set-FmFileTextAtomic -Path $genFile -Text ($gen + "`n") -NoNewline
        if ($ok) {
            $ok = Write-FmBusyRecordLine $record $gen 1 $newState $source $fmEvent
        }
        Exit-FmBusyLock $lock
        if (-not $ok) {
            Write-FmErr "error: arm failed for $id"
            return 1
        }
        Write-FmOut $gen
        return 0
    }

    # apply / retire
    if ($useCurrentGen -and $cmd -cne 'retire') {
        $resolved = Get-FmBusyCurrentGen $stateDir $id
        if ($null -eq $resolved) {
            Write-FmErr "error: no armed busy-state gen for $id"
            return 1
        }
        $gen = $resolved
    }
    if (-not $useCurrentGen -or $cmd -cne 'retire') {
        if (-not (Test-FmBusyToken $gen)) {
            Write-FmErr 'error: invalid --gen'
            return 1
        }
    }

    if (-not (Enter-FmBusyLock $lock $id)) { return 1 }

    $current = Get-FmBusyCurrentGen $stateDir $id
    if ($null -eq $current) {
        # A retire with no sidecar at all is already retired, so any orphan
        # record is removed idempotently. Test-FmSymlink stands in for bash's
        # `-L`: a reparse point counts as present even when it resolves nowhere.
        $genNative = ConvertTo-FmNativePath $genFile
        $absent = -not ([System.IO.File]::Exists($genNative) -or
                        [System.IO.Directory]::Exists($genNative) -or
                        (Test-FmSymlink $genFile))
        if ($cmd -ceq 'retire' -and $absent) {
            $removed = Remove-FmBusyFile $record
            Exit-FmBusyLock $lock
            if (-not $removed) {
                Write-FmErr "error: busy-state retirement failed for $id"
                return 1
            }
            return 0
        }
        Exit-FmBusyLock $lock
        Write-FmErr "error: no armed busy-state gen for $id"
        return 1
    }

    if ($cmd -ceq 'retire' -and $useCurrentGen) { $gen = $current }
    if ($gen -cne $current) {
        Exit-FmBusyLock $lock
        Write-FmErr "error: stale busy-state gen for $id (event rejected)"
        return 1
    }

    if ($cmd -ceq 'retire') {
        $removed = (Remove-FmBusyFile $genFile) -and (Remove-FmBusyFile $record)
        Exit-FmBusyLock $lock
        if (-not $removed) {
            Write-FmErr "error: busy-state retirement failed for $id"
            return 1
        }
        return 0
    }

    $oldSeq = Get-FmBusyRecordedSeq $record $gen
    $written = Write-FmBusyRecordLine $record $gen ($oldSeq + 1) $newState $source $fmEvent
    Exit-FmBusyLock $lock
    if (-not $written) {
        Write-FmErr "error: record write failed for $id"
        return 1
    }
    return 0
}

$fmExitCode = 1
try {
    foreach ($fmItem in @(Invoke-FmBusyEventMain -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    # A writer refuses loudly rather than letting a half-write read as applied
    # (decision 3 in the header).
    Write-FmLog "busy-state event failed: $($_.Exception.Message)"
    $fmExitCode = 1
}
Exit-FmScript $fmExitCode
