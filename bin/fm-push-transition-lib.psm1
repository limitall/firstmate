# fm-push-transition-lib.psm1 - the watcher's native push-transition escalation.
#
# Twin: bin/fm-push-transition-lib.sh
#
# The watcher and the event-wait smoke test import this module instead of
# loading the whole watcher, to obtain Invoke-FmPushTransition. Its dependency
# list is limited to the four production boundaries the transition handler
# actually calls, exactly as the bash twin's source list is.
#
# What it does: a push-capable backend (herdr) reports that an agent moved to a
# status that needs a human. That edge is escalated IMMEDIATELY rather than
# waiting for the wedge timer - unless the crew has declared a pause, in which
# case it is absorbed into the triage log and left to the poll loop's long
# cadence. Either way the backend's transition is committed, so the same edge is
# never replayed.
#
# bash -> PowerShell function map, so the pairing is greppable from either side:
#
#   bin/fm-push-transition-lib.sh   this file
#   -----------------------------   -------------------------------------
#   TRIAGE_LOG                      Get-FmPushTriageLogPath
#   TRIAGE_LOG_MAX_BYTES            Get-FmPushTriageLogSizeCap
#   triage_log                      Write-FmPushTriageLog
#   wake                            Invoke-FmPushWake
#   (the `case heartbeat*` arm)     Update-FmPushHeartbeatStreak
#   _hb_surfaced_path               Get-FmPushSurfacedPath
#   mark_surfaced                   Set-FmPushSurfaced
#   handle_push_transition          Invoke-FmPushTransition
#
# Imported dependencies, matching the bash twin's four `source` lines:
#   fm-wake-lib.psm1        Add-FmWake (fm_wake_append), Get-FmWakeContext ($STATE)
#   fm-classify-lib.psm1    Get-FmLastStatusLine, Test-FmStatusPaused,
#                           Test-FmStatusCaptainRelevant, Get-FmWindowTask
#   fm-transition-lib.psm1  Get-FmTransitionPaneId, Get-FmTransitionToStatus
#   fm-backend.psm1         Save-FmBackendTransition (fm_backend_commit_transition)
#
# ============================================================================
# 1. THE fm-backend EDGE IS DECLARED, SO IT IS AN IMPORT - NOT A PROBE
# ============================================================================
# The bash twin SOURCES bin/fm-backend.sh, for exactly one function,
# fm_backend_commit_transition, called twice and each time as `|| exit 1`. That
# is a DECLARED source edge, so the faithful twin is an explicit
# Import-Module - and it matters beyond faithfulness: bin/fm-watch.sh sources
# only fm-push-transition-lib.sh and gets fm-backend for free, so a
# fm-watch.ps1 that did the same must too. With a capability probe instead, a
# consumer that forgot to import fm-backend.psm1 would see every push
# transition fail to commit and return 1, silently, forever.
#
# This is deliberately NOT the shape bin/fm-busy-lib.psm1 uses. That module
# probes with Get-Command because fm-busy-lib.sh calls fm_backend_* WITHOUT
# sourcing it - the R4 undeclared class - and because fm-backend did not exist
# when it was written. Neither is true here, so applying the probe pattern to a
# declared edge would be copying a workaround past its reason.
#
#   bash                          PowerShell                    shape
#   ----------------------------  ----------------------------  ---------------------
#   fm_backend_commit_transition  Save-FmBackendTransition      (backend, stateDir,
#                                                                session, record)
#                                                               -> [bool]
#
# Confirmed against the shipped bin/fm-backend.psm1 rather than assumed:
# positional order matches the bash argument order, the return is a real [bool]
# with [OutputType([bool])] on every path, and all four parameters are
# AllowEmptyString/AllowNull so an empty session or record binds rather than
# throwing. `Commit-` and `Submit-` are not approved PowerShell verbs and would
# fail tools/fm-ps-lint.ps1, which is why the export is `Save-`.
#
# It returns $false for herdr until bin/backends/herdr.psm1 lands, because
# fm-backend's adapter import fails closed. That is the faithful twin of bash,
# where fm_backend_commit_transition also returns 1 when fm_backend_source
# fails, so the `|| exit 1` path below is preserved exactly and starts
# succeeding the moment the adapter lands, with no change here.
#
# Test-FmPushBackendResult still normalizes the verdict. Not because the export
# is doubtful - it is a documented [bool] - but because -CommitAction (seam note
# 2) lets a caller substitute the boundary, and a scriptblock that EMITS before
# returning yields an array. Reading the last value, and refusing a string
# outright, is what stops 'False' from being read as success.
#
# ============================================================================
# 2. exit AND THE THREE CALLBACK SEAMS
# ============================================================================
# The bash twin's control flow ends the PROCESS in three places, and a module
# function that called `exit` would be untestable in a batched pwsh (a suite
# that spawns one pwsh per case never finishes on this host - see
# docs/powershell-port.md, "batch pwsh"). Each seam is one the bash twin already
# has in spirit, because its own header says "Tests override this callback":
#
#   wake        -> -WakeAction, a scriptblock receiving the reason string.
#                  The DEFAULT is Invoke-FmPushWake, which does exit 0, so
#                  production behavior is unchanged; a test passes a recorder,
#                  exactly as the bash suite redefines wake().
#   sleep 1     -> -SleepAction, same idea, for the no-pane-id branch.
#   the commit  -> -CommitAction, defaulting to Save-FmBackendTransition. bash
#                  gets this seam for free: a test redefines the shell function
#                  and the library calls the replacement. An imported module
#                  command cannot be shadowed that way, so the injection point
#                  is explicit. It exists for the same reason the other two do -
#                  driving the real herdr adapter would make the differential
#                  about herdr rather than about this file - and both worlds are
#                  stubbed symmetrically in tests/fm-followup-psm1.test.sh.
#   exit 1      -> Invoke-FmPushTransition RETURNS 1. Its caller (fm-watch.ps1)
#                  exits with that code. Returning rather than exiting is what
#                  lets one pwsh evaluate every case; the VALUE is the bash
#                  twin's exit status unchanged.
#
# Invoke-FmPushWake itself takes -NoExit for the same reason, and only for that
# reason: nothing in production passes it.
#
# ============================================================================
# 3. $STATE
# ============================================================================
# The bash twin reads the shell global $STATE, which fm-wake-lib.sh sets at
# source time. A PowerShell module cannot see its caller's variables, so every
# function here takes -State, defaulting to (Get-FmWakeContext).State - the same
# import-time resolution the bash twin gets, and the same shape
# bin/fm-classify-lib.psm1 uses for Get-FmWindowTask -State.
#
# One consequence worth stating rather than discovering: Add-FmWake writes to
# the queue path fm-wake-lib resolved AT ITS OWN IMPORT, so passing a -State
# that differs from that home's state directory would enqueue into the other
# one. Callers (and tests) set FM_STATE_OVERRIDE before importing, exactly as
# the bash twin requires.
#
# ============================================================================
# 4. RECORD PARSING
# ============================================================================
# The transition record is a fixed FIVE-field TAB record with meaningful EMPTY
# middle fields (workspace id and from-status are both empty for an
# edge-triggered backend). This module never splits it: field extraction is
# bin/fm-transition-lib.psm1's job, and that module already owns the
# count-preserving .Split("`t") contract the port doc demands. Reproducing the
# split here would be a second parser to keep in agreement.
#
# Import with:
#   Import-Module (Join-Path $PSScriptRoot 'fm-push-transition-lib.psm1') -Force

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NO -Force on these nested imports, and the rule is not stylistic: a nested
# -Force REMOVES the already-loaded module before re-importing it, and the
# removal is global, so a SCRIPT that had imported fm-common for its own use
# loses ConvertTo-FmNativePath and friends the moment it imports this module.
# The modules themselves keep working - their bindings live in their own session
# states - which is exactly why a module-only unit test cannot catch it and an
# entrypoint can. Found here through this module's import chain, fixed tree-wide,
# and now owned by docs/powershell-port.md ("Never -Force a NESTED module
# import"). Without -Force the loaded instance is reused and everyone keeps
# their commands.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-classify-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-transition-lib.psm1')
# The declared edge, the twin of `. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"`.
# See seam note 1: this is an import and not a probe because the bash twin
# SOURCES it, and because fm-watch.sh's consumers rely on getting fm-backend
# transitively from this file.
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1')

$script:FmPushOrdinal = [System.StringComparison]::Ordinal

# Interpret whatever the commit boundary returned. Save-FmBackendTransition is a
# documented [bool], but -CommitAction lets a caller substitute the boundary, so
# a bash-style [int] status is accepted too and a string is refused outright.
function Test-FmPushBackendResult {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Position = 0)][AllowNull()]$Result)

    if ($null -eq $Result) { return $false }
    if ($Result -is [bool]) { return $Result }
    if ($Result -is [int] -or $Result -is [long]) { return ($Result -eq 0) }
    if ($Result -is [System.Array]) {
        # A PowerShell function that emits before returning yields an array;
        # the LAST value is the return, matching how bash's `$?` reads the
        # final command rather than everything the function printed.
        if ($Result.Count -eq 0) { return $false }
        return (Test-FmPushBackendResult $Result[$Result.Count - 1])
    }
    return $false
}

# --- state resolution --------------------------------------------------------

# The `${STATE}` twin: the import-time resolution fm-wake-lib performed, so both
# worlds answer identically for one home.
function Resolve-FmPushState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)

    if (-not [string]::IsNullOrEmpty($State)) { return $State }
    return (Get-FmWakeContext).State
}

# --- triage log --------------------------------------------------------------

<#
.SYNOPSIS
The watcher's absorbed-wake debug log path: <state>/.watch-triage.log.
#>
function Get-FmPushTriageLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$State)
    return "$(Resolve-FmPushState $State)/.watch-triage.log"
}

<#
.SYNOPSIS
The triage log's size cap in bytes (FM_WATCH_TRIAGE_LOG_MAX_BYTES, default 262144).
.DESCRIPTION
Honors bash `${VAR:-262144}` semantics, so an exported EMPTY value falls back to
the default. A non-numeric value yields the default here rather than the bash
twin's `[ "$sz" -ge "$cap" ]` integer-expression error, which would print a
diagnostic and skip the trim; the OBSERVABLE outcome - the log is not trimmed
this pass - is the same, and the differential suite does not depend on the
diagnostic because the whole trim path is best-effort in both worlds.
#>
function Get-FmPushTriageLogSizeCap {
    [CmdletBinding()]
    [OutputType([long])]
    param()

    $raw = Get-FmEnv -Name 'FM_WATCH_TRIAGE_LOG_MAX_BYTES' -Default '262144'
    [long]$value = 0
    if ([long]::TryParse($raw, [ref]$value)) { return $value }
    return 262144
}

<#
.SYNOPSIS
Append one bounded best-effort line for an absorbed supervision event.
.DESCRIPTION
Twin of triage_log:

    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
    ... if the file reached TRIAGE_LOG_MAX_BYTES, keep only its last 2000 lines

Every step is best-effort and every failure is swallowed, because this log is a
debug aid the watcher must never die for. `date '+...%z'` produces a NUMERIC
offset with no colon (+0530, and +0000 on a UTC host); .NET's "K" and "zzz" both
produce +05:30, so the offset is composed explicitly.

The trim keeps the LAST 2000 lines, published through a sibling temp and a
rename so a concurrent reader never sees a half-written log.
#>
function Write-FmPushTriageLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin appends unconditionally on a watcher hot path with every failure swallowed; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    $log = Get-FmPushTriageLogPath $State
    $native = ConvertTo-FmNativePath $log

    $now = [DateTimeOffset]::Now
    $offset = $now.Offset
    $sign = if ($offset.Ticks -lt 0) { '-' } else { '+' }
    $stamp = '{0}{1}{2:00}{3:00}' -f $now.ToString('yyyy-MM-ddTHH:mm:ss'), $sign,
        [Math]::Abs($offset.Hours), [Math]::Abs($offset.Minutes)

    try {
        Add-FmFileLine -Path $native -Line "[$stamp] $Message"
    } catch {
        # `>> ... 2>/dev/null || return 0`: an unwritable log is not an error.
        return
    }

    $cap = Get-FmPushTriageLogSizeCap
    try {
        $info = [System.IO.FileInfo]::new($native)
        if (-not $info.Exists -or $info.Length -lt $cap) { return }
        $lines = Get-FmFileLines $native
        if ($lines.Length -le 2000) { return }
        $kept = $lines[($lines.Length - 2000)..($lines.Length - 1)]
        [void](Set-FmFileTextAtomic -Path $native -Text (($kept -join "`n") + "`n") -NoNewline)
    } catch {
        # `tail ... && mv ...` with every failure redirected: a trim that could
        # not happen leaves the log oversized until the next append tries again.
        $null = $_
    }
}

# --- wake --------------------------------------------------------------------

<#
.SYNOPSIS
Advance or reset the heartbeat streak for one wake reason. Returns the new value.
.DESCRIPTION
The `case "$1" in heartbeat*)` arm of the bash twin's wake(), split out so it is
testable without exiting the process:

    heartbeat*) streak = (streak file, or 0) + 1
    *)          streak = 0

A streak file that is missing, empty, or non-numeric counts as 0. Missing and
empty match bash's `$(cat ... || echo 0)` exactly.

NON-NUMERIC IS A DOCUMENTED DIVERGENCE, and the honest direction. bash expands
`$(( abc + 1 ))` by treating `abc` as a VARIABLE, and under `set -u` - which
bin/fm-watch.sh sets - that is an unbound-variable error raised during
EXPANSION, before the redirection is applied: the junk stays in the file and the
watcher dies. PowerShell cannot reproduce a shell's unbound-variable abort, and
faking one would be worse than degrading, so an unreadable record is treated as
0 exactly as a missing one is and supervision carries on.
tests/fm-followup-psm1.test.sh asserts BOTH behaviors rather than normalizing
one into the other.

The file is written as the decimal value plus one LF, matching `echo N >`.
#>
function Update-FmPushHeartbeatStreak {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin rewrites the streak record unconditionally on every wake; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    $path = "$(Resolve-FmPushState $State)/.heartbeat-streak"
    $native = ConvertTo-FmNativePath $path

    [long]$next = 0
    if ($null -ne $Reason -and $Reason.StartsWith('heartbeat', $script:FmPushOrdinal)) {
        [long]$current = 0
        $text = (Get-FmFileText $native).Trim()
        if (-not [long]::TryParse($text, [ref]$current)) { $current = 0 }
        $next = $current + 1
    }
    Set-FmFileText -Path $native -Text ([string]$next)
    return $next
}

<#
.SYNOPSIS
Report one actionable wake on stdout and exit 0.
.DESCRIPTION
Twin of wake(): update the heartbeat streak, print the reason, exit 0. The
watcher's whole contract with its supervisor is that one reason line reaches
stdout and the process ends, so a caller can resume the session-start protocol.

-NoExit is the testability seam and nothing else: the bash suite replaces wake()
wholesale, which a module function cannot allow, so the exit is made optional
instead. Nothing in production passes it.
#>
function Invoke-FmPushWake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Reason,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State,
        [switch]$NoExit
    )

    [void](Update-FmPushHeartbeatStreak -Reason $Reason -State $State)
    Write-FmOut ([string]$Reason)
    if ($NoExit) { return }
    Exit-FmScript 0
}

# --- surfaced markers --------------------------------------------------------

<#
.SYNOPSIS
The per-task surfaced-status marker path.
.DESCRIPTION
Twin of _hb_surfaced_path:

    printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"

Each of ':' '/' '.' becomes '_', so a window-shaped or dotted task id can never
compose a path separator or a dotfile. `tr` works on BYTES; all three are ASCII,
so translating UTF-16 characters is equivalent (a UTF-8 continuation byte is
always >= 0x80 and can never be one of them).
#>
function Get-FmPushSurfacedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Task,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    $safe = ''
    if (-not [string]::IsNullOrEmpty($Task)) {
        $safe = [regex]::Replace($Task, '[:/.]', '_')
    }
    return "$(Resolve-FmPushState $State)/.hb-surfaced-$safe"
}

<#
.SYNOPSIS
Record a captain-relevant status after its durable wake has been enqueued.
.DESCRIPTION
Twin of mark_surfaced. The ORDER this sits in matters more than the function
does: the watcher enqueues the durable wake FIRST and marks surfaced second, so
a crash between them re-fires the wake rather than losing it.

Only a captain-relevant, non-empty last line is recorded, and it is written with
NO trailing newline (`printf '%s' >`), because the next pass compares the marker
against a freshly read status line byte for byte.

Returns $true when a marker was written, $false when there was nothing to mark -
information bash carries only as "the function returned", and which the
differential suite uses to tell "absorbed" from "recorded".
#>
function Set-FmPushSurfaced {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The bash twin writes the surfaced marker unconditionally on the watcher hot path; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive watcher.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$StatusPath,
        [Parameter(Position = 1)][AllowEmptyString()][AllowNull()][string]$State
    )

    if ([string]::IsNullOrEmpty($StatusPath)) { return $false }
    # `task=$(basename "$f"); task="${task%.status}"` - the LEAF with one
    # trailing ".status" removed, not every extension.
    $task = [System.IO.Path]::GetFileName($StatusPath.TrimEnd('/', '\'))
    if ($task.EndsWith('.status', $script:FmPushOrdinal)) {
        $task = $task.Substring(0, $task.Length - '.status'.Length)
    }

    $last = Get-FmLastStatusLine -Path $StatusPath
    if ([string]::IsNullOrEmpty($last)) { return $false }
    if (-not (Test-FmStatusCaptainRelevant -Line $last)) { return $false }

    Set-FmFileText -Path (Get-FmPushSurfacedPath -Task $task -State $State) -Text $last -NoNewline
    return $true
}

# --- the transition handler --------------------------------------------------

<#
.SYNOPSIS
Act on a fresh actionable transition from a push-capable backend.
.DESCRIPTION
Twin of handle_push_transition <backend> <session> <record>. Returns the bash
twin's exit status: 0 where it returns, 1 where it exits 1. The normal path does
not return at all in production, because the default -WakeAction exits 0 - the
same as bash.

The four outcomes, in the twin's order:

  1. NO PANE ID in the record -> sleep 1 and return. A record the backend could
     not attribute to a pane is not actionable, and the sleep is what keeps the
     watcher from spinning on a broken event stream.
  2. THE CREW DECLARED A PAUSE -> log the absorb, commit the transition, return.
     A declared pause is a bounded external wait expected to clear on its own,
     so it must NOT be fast-escalated; the poll loop's long cadence owns it.
  3. OTHERWISE -> enqueue a durable `stale` wake, commit the transition, mark
     the status surfaced, and wake. ENQUEUE BEFORE COMMIT is load-bearing: the
     dedupe marker the backend writes on commit must never exist for an edge
     whose durable wake was not stored, or a human-waiting agent is dropped
     silently. tests/fm-supervision-events.test.sh pins exactly that ordering.
  4. Any of those three failures (enqueue, either commit) -> 1.

The reason string is reproduced verbatim, including the "herdr:" prefix on a
line that any backend can produce. It is an observable contract: it lands in the
durable wake queue, the supervisor reads it, and the bash suite greps it.
#>
function Invoke-FmPushTransition {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Backend,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory, Position = 2)][AllowEmptyString()][AllowNull()][string]$Record,
        [Parameter(Position = 3)][AllowEmptyString()][AllowNull()][string]$State,
        [scriptblock]$WakeAction,
        [scriptblock]$SleepAction,
        [scriptblock]$CommitAction
    )

    $stateDir = Resolve-FmPushState $State

    $paneId = Get-FmTransitionPaneId -Record $Record
    $to = Get-FmTransitionToStatus -Record $Record

    if ([string]::IsNullOrEmpty($paneId)) {
        # $null = ... on both callbacks: anything a caller's scriptblock emits
        # would join this function's OUTPUT, and the return value here is an
        # exit status a caller branches on. A polluted return would read as a
        # failure that never happened.
        if ($SleepAction) { $null = & $SleepAction } else { Start-Sleep -Seconds 1 }
        return 0
    }

    $window = "${Session}:${paneId}"
    $task = Get-FmWindowTask -Window $window -State $stateDir

    if (Test-FmStatusPaused -Line (Get-FmLastStatusLine -Path "$stateDir/$task.status")) {
        Write-FmPushTriageLog "absorbed push $to (declared pause, awaiting external): $window" $stateDir
        if (-not (Invoke-FmPushCommitTransition -Backend $Backend -State $stateDir -Session $Session -Record $Record -CommitAction $CommitAction)) {
            return 1
        }
        return 0
    }

    $reason = "stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"

    if ((Add-FmWake -Kind 'stale' -Key $window -Payload $reason) -ne 0) { return 1 }
    if (-not (Invoke-FmPushCommitTransition -Backend $Backend -State $stateDir -Session $Session -Record $Record -CommitAction $CommitAction)) {
        return 1
    }
    [void](Set-FmPushSurfaced -StatusPath "$stateDir/$task.status" -State $stateDir)

    if ($WakeAction) { $null = & $WakeAction $reason } else { Invoke-FmPushWake -Reason $reason -State $stateDir }
    return 0
}

# The `fm_backend_commit_transition ... || exit 1` call. Save-FmBackendTransition
# comes from the declared import above; -CommitAction substitutes it (seam note
# 2). A throw is reported once on stderr and treated as a FAILURE rather than
# escaping, because the caller's contract here is an exit status, and a
# committed-but-not-really transition would replay the same edge forever while
# an uncommitted-but-reported-committed one would drop a human-waiting agent.
function Invoke-FmPushCommitTransition {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Backend,
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Session,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Record,
        [scriptblock]$CommitAction
    )

    try {
        # Positional in both arms, matching the bash twin's argument order.
        if ($CommitAction) {
            return (Test-FmPushBackendResult (& $CommitAction $Backend $State $Session $Record))
        }
        return (Test-FmPushBackendResult (Save-FmBackendTransition $Backend $State $Session $Record))
    } catch {
        Write-FmLog "fm_backend_commit_transition failed: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function @(
    'Test-FmPushBackendResult',
    'Resolve-FmPushState',
    'Get-FmPushTriageLogPath', 'Get-FmPushTriageLogSizeCap', 'Write-FmPushTriageLog',
    'Update-FmPushHeartbeatStreak', 'Invoke-FmPushWake',
    'Get-FmPushSurfacedPath', 'Set-FmPushSurfaced',
    'Invoke-FmPushTransition', 'Invoke-FmPushCommitTransition'
)
