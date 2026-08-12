# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# Twin: bin/fm-turnend-guard.sh
#
# fm-guard is pull-based: it only warns when some other supervision script
# happens to run. A primary session that ends a turn without resuming its
# harness supervision protocol, and then never runs another fleet-touching
# command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (state/.claude-autoarm.lock owner
#      alive) or to record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one
#      recovery turn; the first fresh exhausted-failure epoch preserves the
#      bounded progression, while later fresh failed epochs consume it instead
#      of resetting it;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open only for an already verified failure episode.
#
# ---------------------------------------------------------------------------
# CONVERSION NOTES
#
# THE EXIT CODE IS THE WHOLE INTERFACE. 2 BLOCKS the turn ending and 0 allows
# it, and the two failure directions are not symmetric: a wrong 2 can wedge a
# captain's session, a wrong 0 lets the fleet run unsupervised. So every path
# below returns an explicit code, the block budget keeps its exact numbers
# (3 consecutive blocks, deliberately below Claude Code's hard 8-block
# override), and the banner bytes are reproduced rather than paraphrased -
# tests/fm-turnend-guard.test.sh matches on them.
#
# NO param() BLOCK, for the reason bin/fm-operational-input.ps1 records: the
# bash CLI takes bare positional words and a declared param block would make
# PowerShell try to BIND them before the script runs.
#
# IMPORTS CARRY NO -Force. -Force re-runs a module body, and fm-common's body
# re-applies the console encoding, which RESETS [Console]::In/Out - so a batched
# differential driver that redirects the console per case would have every case
# after the first read the driver's own stdin (tests/fm-hooks-psm1.test.sh
# records the debugging cycle that cost). It is also the nested-import rule in
# docs/powershell-port.md.
#
# THE LOCK-ROLE AND FAILURE-EPISODE HELPERS ARE LOCAL ON PURPOSE, FOR NOW.
# fm_lock_set_role, fm_lock_role and fm_failure_episode_reset live in
# bin/fm-wake-lib.sh, and bin/fm-wake-lib.psm1 has not yet gained their twins.
# Set-FmHookLockRole / Get-FmHookLockRole / Reset-FmHookFailureEpisode below
# are byte-faithful ports of those three, kept private here (and in the same
# shape in bin/fm-claude-stop-autoarm.ps1, the only other caller) so the turn-end
# hooks match their oracle today. They MOVE into fm-wake-lib.psm1 as
# Set-FmLockRole / Get-FmLockRole / Reset-FmFailureEpisode as soon as that
# module's owner lands them; nothing else may grow a fourth copy.
# Unlock-FmHookLock is the third piece of the same debt and carries its own note.
#
# DECLARED DIVERGENCE 1 - jq. The bash twin needs jq to read the loop-guard
# field and exits 0 when jq is missing, because without it the field cannot be
# read safely. This twin parses JSON in-process, so there is nothing to be
# missing: on a jq-less host it still classifies and still guards. The
# divergence is strictly in the guarding direction and is asserted explicitly in
# tests/fm-turnend-psm1.test.sh rather than normalized away.
#
# DECLARED DIVERGENCE 2 - a MULTI-DOCUMENT payload. `jq` reads a stream, so
# `{"a":1}{"b":2}` makes the bash twin emit one loop-guard answer per document;
# the concatenation is never the literal "true", so bash proceeds as though the
# loop guard were false. ConvertFrom-Json parses exactly one document and
# throws on trailing content, so this twin treats that payload as unreadable and
# allows (exit 0), which is what bash already does for every other unparseable
# payload. No verified harness emits one, and the Grok adapter rejects
# multi-document payloads outright before the guard is ever reached.
#
# THE WATCHER-PATH TOKEN IS PAIRED WITH bin/fm-watch.psm1, not with the bash
# watcher. The lock's watcher-path field is compared as a raw string, so this
# twin resolves the watcher the same way bin/fm-watch.psm1 does (prefer the
# .ps1 twin, fall back to the .sh) and reads a PowerShell watcher's lock.
# Cross-world healthy-watcher recognition is already impossible for a deeper
# reason - fm-wake-lib's documented divergence 2, where a Windows-native pid
# identity compares as MISMATCH against an MSYS one - so nothing is lost.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# No -Force on any of these: see the conversion notes above.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-supervision-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-primary-scope-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$fmArgv = @($args)

# The 71-character rule the banner is drawn with, byte-identical to the bash
# twin's `rule=` assignment.
$script:FmGuardRule = '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# The reason printed when bin/fm-supervision-instructions cannot be run at all.
$script:FmGuardFallbackReason = 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn'

# The bash twin's COUNT and BUDGET_INITIALIZED_FAILURE are plain globals written
# by budget_account_current_epoch and read by autoarm_owns_recovery and
# terminal_fail_open. Script scope is their twin: $global: would leak across the
# module boundaries the port introduces, and passing them back through every
# caller would change which failure paths leave them stale.
$script:FmGuardCount = 0
$script:FmGuardInitializedFailure = 0

<#
.SYNOPSIS
The watcher script this home's lock would name (the WATCH variable).
.DESCRIPTION
Deliberately the same rule bin/fm-watch.psm1's Resolve-FmWatchSibling applies,
because the lock's watcher-path field is compared as a RAW STRING and a guard
that spelled it differently would never recognize its own watcher. Not
Invoke-FmScript: that owns RUNNING a sibling, and what is needed here is the
path (contract 7 in docs/powershell-port.md).
#>
function Get-FmGuardWatchPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$BinDir)

    $ps1 = Join-Path $BinDir 'fm-watch.ps1'
    if ((Test-Path -LiteralPath $ps1) -and ((Get-Item -LiteralPath $ps1).Length -gt 0)) { return $ps1 }
    $sh = Join-Path $BinDir 'fm-watch.sh'
    if (Test-Path -LiteralPath $sh) { return $sh }
    return $ps1
}

<#
.SYNOPSIS
The `[ -e <path> ]` twin: present as a file OR as a directory.
.DESCRIPTION
Every marker this guard consults is tested with `-e` rather than `-f` in the
bash twin, deliberately: a marker that somehow became a directory still counts
as present, and treating it as absent would let a spent failure episode start
over.
#>
function Test-FmHookPathPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $native = ConvertTo-FmNativePath $Path
    return ([System.IO.File]::Exists($native) -or [System.IO.Directory]::Exists($native))
}

<#
.SYNOPSIS
Read a `${VAR:-<default>}` knob that must be a non-negative integer.
.DESCRIPTION
The twin of the three `case "$VALUE" in ''|*[!0-9]*) VALUE=<default> ;; esac`
guards. -RejectZero adds the `|0` alternative two of the three carry, because a
zero epoch-freshness window or a zero block budget would disable the very bound
the knob exists to impose.
#>
function Get-FmGuardNumericKnob {
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][long]$Default,
        [switch]$RejectZero
    )
    $raw = Get-FmEnv -Name $Name
    if ($raw -notmatch '^[0-9]+$') { return $Default }
    [long]$value = 0
    if (-not [long]::TryParse($raw, [ref]$value)) { return $Default }
    if ($RejectZero -and $value -eq 0) { return $Default }
    return $value
}

<#
.SYNOPSIS
The `$(sed -n 's/<pattern>/\1/p' <file>)` twin: capture group 1, per line.
.DESCRIPTION
Two properties of that construct are load-bearing and easy to lose:

  * a line that does not match contributes NOTHING, rather than contributing
    itself, because the `p` is attached to the substitution;
  * `$( )` joins the surviving lines with LF and strips the trailing one, so a
    multi-line ledger can only compare equal to a bare word when exactly one
    line matched.

A missing file yields the empty string, which is what `2>/dev/null || true`
around the sed produces.
#>
function Get-FmGuardCapturedField {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory, Position = 1)][string]$Pattern
    )

    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-FmFileLines $Path)) {
        $m = [regex]::Match($line, $Pattern)
        if ($m.Success) { $hits.Add($m.Groups[1].Value) }
    }
    return ($hits -join "`n")
}

<#
.SYNOPSIS
The outcome word recorded in the auto-arm epoch ledger, or '' when unreadable.
.DESCRIPTION
`sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p'`: a lower-case outcome word,
HYPHENS INCLUDED, followed by a space. The hyphen is not cosmetic - it is the
difference between reading `failed-suppressed` and reading `failed`, and those
two words take different branches everywhere below. The leading `.*` is greedy,
so the LAST `outcome=` on a line wins.
#>
function Get-FmGuardEpochOutcome {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$State)

    return (Get-FmGuardCapturedField -Path "$State/.claude-autoarm-epoch" -Pattern '^.*outcome=([a-z][a-z-]*) .*$')
}

<#
.SYNOPSIS
The role token published beside a lock's pid (fm_lock_role).
#>
function Get-FmHookLockRole {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    return (Get-FmFileText "$LockPath/role").TrimEnd("`r", "`n")
}

<#
.SYNOPSIS
Publish this process's role into a lock it already holds (fm_lock_set_role).
.DESCRIPTION
Twin of fm_lock_set_role, including all three of its refusals: an unknown role
word, a lock whose published pid is not ours, and a write that does not read
back. The read-back is the point - the lock's owner directory may be published
as a symlink or as a plain file holding the owner path (docs/powershell-port.md,
"Locks"), and a write that landed somewhere else must not be reported as a role
this process holds.
#>
function Set-FmHookLockRole {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal lock-protocol primitive whose bash twin writes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive turn-end hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$LockPath,
        [Parameter(Mandatory, Position = 1)][string]$Role
    )

    if ($Role -cne 'autoarm' -and $Role -cne 'terminal-check') { return $false }
    $current = [string]$PID
    $holder = (Get-FmFileText "$LockPath/pid").TrimEnd("`r", "`n")
    if ($holder -cne $current) { return $false }
    try {
        Set-FmFileText -Path "$LockPath/role" -Text $Role
    } catch {
        $null = $_
        return $false
    }
    return ((Get-FmHookLockRole -LockPath $LockPath) -ceq $Role)
}

<#
.SYNOPSIS
Release a lock this guard labelled with a role, clearing the label first.
.DESCRIPTION
COMPENSATES FOR A GAP IN fm-wake-lib.psm1, and is not an embellishment. Bash's
fm_lock_clean_known_files lists `role` among the filenames a lock directory may
contain, so fm_lock_release removes it and the directory then rmdir's. The
PowerShell Clear-FmLockKnownFile does NOT list `role` yet, so a lock this guard
labelled cannot be emptied: measured on this host, releasing such a lock leaves
its whole owner directory behind, where the bash twin leaves nothing. Clearing
the label here - and only the label this guard itself wrote - restores the twin's
observable filesystem result.

Remove the compensation when fm-wake-lib.psm1's Clear-FmLockKnownFile gains
'role' (see the LOCK-ROLE note in the conversion header); until then every
release of a labelled lock must go through this, never Unlock-FmLock directly.
#>
function Unlock-FmHookLock {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal lock-protocol primitive whose bash twin releases unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive turn-end hook.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory, Position = 0)][string]$LockPath)

    try {
        $native = ConvertTo-FmNativePath "$LockPath/role"
        if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
    } catch {
        # `rm -f` semantics: a label that will not go must not stop the release.
        $null = $_
    }
    Unlock-FmLock -LockPath $LockPath
}

<#
.SYNOPSIS
Clear a whole failure episode's durable markers (fm_failure_episode_reset).
.DESCRIPTION
Twin of fm_failure_episode_reset, both modes. `acquire` takes the budget lock
itself and releases it; `held` asserts that THIS process already holds it and
leaves it held, which is what the terminal fail-open needs so its decision and
this reset cannot be interleaved with another firing.

A marker that is a real DIRECTORY refuses the whole reset rather than being
removed: `rm -f` cannot remove one either, and silently succeeding would report
an episode as cleared while its markers still gate every later decision.
#>
function Reset-FmHookFailureEpisode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'An internal `rm -f` twin on the hot path of a turn-end hook whose bash original deletes unconditionally; a -WhatIf/-Confirm surface would diverge from the twin and could stall a non-interactive hook.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Position = 1)][string]$Mode = 'acquire'
    )

    $lock = "$State/.turnend-claude-blocks.lock"
    $acquired = $false
    if ($Mode -ceq 'acquire') {
        if (-not (Request-FmLock -LockPath $lock)) { return $false }
        $acquired = $true
    } elseif ($Mode -ceq 'held') {
        $holder = (Get-FmFileText "$lock/pid").TrimEnd("`r", "`n")
        if ($holder -cne [string]$PID) { return $false }
    } else {
        return $false
    }

    $paths = @(
        "$State/.turnend-claude-blocks"
        "$State/.claude-autoarm-failure-notified"
        "$State/.claude-autoarm-failure-alarmed"
    )
    foreach ($path in $paths) {
        $native = ConvertTo-FmNativePath $path
        if ([System.IO.Directory]::Exists($native) -and -not (Test-FmSymlink -Path $path)) {
            if ($acquired) { Unlock-FmLock -LockPath $lock }
            return $false
        }
    }
    foreach ($path in $paths) {
        $native = ConvertTo-FmNativePath $path
        try {
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $null = $_
            if ($acquired) { Unlock-FmLock -LockPath $lock }
            return $false
        }
    }
    if ($acquired) { Unlock-FmLock -LockPath $lock }
    return $true
}

<#
.SYNOPSIS
The loop-guard field, as a tri-state: $true, $false, or $null for "unreadable".
.DESCRIPTION
Byte-compatible with the bash twin's jq filter, including which shapes are an
ERROR (the `|| exit 0` fail-open) rather than a false:

  * a payload that is not a JSON object            -> unreadable
  * stopHookActive present but not a boolean       -> unreadable
  * stop_hook_active present but not a boolean     -> unreadable (only consulted
                                                     when the camel-case
                                                     spelling is absent, which
                                                     is the typed precedence)
  * neither key present                            -> $false

ConvertFrom-Json -AsHashtable resolves a duplicated key to the LAST occurrence,
which is what jq's `has`/`.field` pair does too, so a duplicated spelling reads
identically in both worlds.
#>
function Get-FmGuardStopHookActive {
    [CmdletBinding()]
    [OutputType([System.Nullable[bool]])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $parsed = $null
    try {
        $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable
    } catch {
        return $null
    }
    if ($parsed -isnot [System.Collections.IDictionary]) { return $null }

    foreach ($key in @('stopHookActive', 'stop_hook_active')) {
        if (-not $parsed.Contains($key)) { continue }
        $value = $parsed[$key]
        if ($value -isnot [bool]) { return $null }
        return [bool]$value
    }
    return $false
}

<#
.SYNOPSIS
The payload's session id, or 'unknown' (the `.session_id // "unknown"` twin).
.DESCRIPTION
jq's `//` treats both null and false as absent, so both fall through to the
literal default; every other type is rendered the way `jq -r` renders it, with a
container printed as compact JSON.
#>
function Get-FmGuardSessionId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Payload)

    $parsed = $null
    try {
        $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable
    } catch {
        return 'unknown'
    }
    if ($parsed -isnot [System.Collections.IDictionary]) { return 'unknown' }
    if (-not $parsed.Contains('session_id')) { return 'unknown' }
    $value = $parsed['session_id']
    if ($null -eq $value) { return 'unknown' }
    if ($value -is [bool]) { if (-not $value) { return 'unknown' }; return 'true' }
    if ($value -is [string]) { return $value }
    if ($value -is [System.Collections.IDictionary] -or $value -is [System.Collections.IEnumerable]) {
        try { return (ConvertTo-Json -InputObject $value -Depth 20 -Compress) } catch { return 'unknown' }
    }
    return [string]$value
}

<#
.SYNOPSIS
The consecutive-block record's three fields, as written by this guard.
.DESCRIPTION
`sed -n '1s/^session=//p'`, `'2s/^count=//p'` and `'3s/^epoch=//p'`: each
substitution is pinned to ONE line number and the `p` is attached to it, so a
line that does not carry its prefix contributes nothing rather than contributing
itself. A non-numeric count reads as 0, exactly as the bash `case` guard says.

The epoch field is legitimately EMPTY whenever no auto-arm ledger exists, which
is the ordinary case for a home whose Stop hook never ran - the record still
carries the field so the third line's meaning never shifts.

The returned key is BlockCount, not Count, and that is not a style choice:
Hashtable has a real .Count property, so `$record.Count` reads the NUMBER OF
KEYS (3) instead of the parsed field, and the bound would then compare 3 against
the budget on every call while looking perfectly correct.
#>
function Get-FmGuardBudgetRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory, Position = 0)][string]$BudgetFile)

    $lines = (Get-FmFileLines $BudgetFile)
    $session = ''
    if ($lines.Count -ge 1 -and $lines[0].StartsWith('session=', [System.StringComparison]::Ordinal)) {
        $session = $lines[0].Substring('session='.Length)
    }
    $count = ''
    if ($lines.Count -ge 2 -and $lines[1].StartsWith('count=', [System.StringComparison]::Ordinal)) {
        $count = $lines[1].Substring('count='.Length)
    }
    if ($count -notmatch '^[0-9]+$') { $count = '0' }
    $epoch = ''
    if ($lines.Count -ge 3 -and $lines[2].StartsWith('epoch=', [System.StringComparison]::Ordinal)) {
        $epoch = $lines[2].Substring('epoch='.Length)
    }
    return @{ Session = $session; BlockCount = $count; Epoch = $epoch }
}

<#
.SYNOPSIS
Account one consecutive block against the current auto-arm event epoch.
.DESCRIPTION
Twin of budget_account_current_epoch, including the two rules that make the
bound mean something:

  * a record whose epoch field still equals the ledger's CURRENT epoch is the
    same event being re-decided, so it does not spend another block; only a new
    (or absent) epoch increments;
  * a fresh record opened while an exhausted-failure notice already exists
    starts at 0 and reports that through BUDGET_INITIALIZED_FAILURE, so the
    first fresh failed epoch preserves the bounded progression instead of
    resetting it.

$false means the record could not be taken or published, which the callers
treat as "do not decide on this count".
#>
function Invoke-FmGuardBudgetAccount {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$SessionId,
        [Parameter(Mandatory, Position = 2)][string]$FailureNotice
    )

    $budgetFile = "$State/.turnend-claude-blocks"
    $budgetLock = "$State/.turnend-claude-blocks.lock"
    if (-not (Request-FmLock -LockPath $budgetLock)) { return $false }

    $currentEpoch = Get-FmGuardCapturedField -Path "$State/.claude-autoarm-epoch" -Pattern '^epoch=([0-9][0-9]*) .*'
    $outcome = Get-FmGuardEpochOutcome -State $State
    $initialized = 0
    $script:FmGuardCount = 0

    $budgetExists = [System.IO.File]::Exists((ConvertTo-FmNativePath $budgetFile))
    $oldSession = ''
    if ($budgetExists) {
        $record = Get-FmGuardBudgetRecord -BudgetFile $budgetFile
        $oldSession = $record.Session
        if ($oldSession -ceq $SessionId) {
            $script:FmGuardCount = [long]$record.BlockCount
            if (-not ([string]::IsNullOrEmpty($currentEpoch)) -and $record.Epoch -ceq $currentEpoch) {
                # Same event epoch: re-deciding it costs nothing.
            } else {
                $script:FmGuardCount = $script:FmGuardCount + 1
            }
        }
    }
    if ((-not $budgetExists) -or ($oldSession -cne $SessionId)) {
        if ($outcome -ceq 'failed' -or $outcome -ceq 'failed-suppressed') {
            if (Test-FmHookPathPresent $FailureNotice) {
                $initialized = 1
                $script:FmGuardCount = 0
            } else {
                $script:FmGuardCount = 1
            }
        } else {
            $script:FmGuardCount = 1
        }
    }

    $text = "session=$SessionId`ncount=$($script:FmGuardCount)`nepoch=$currentEpoch`n"
    if (-not (Set-FmFileTextAtomic -Path $budgetFile -Text $text -NoNewline)) {
        Unlock-FmLock -LockPath $budgetLock
        return $false
    }
    $script:FmGuardInitializedFailure = $initialized
    Unlock-FmLock -LockPath $budgetLock
    return $true
}

<#
.SYNOPSIS
True when this home is in a VERIFIED exhausted-failure episode.
.DESCRIPTION
Twin of failure_episode_verified, and the gate that keeps the attended fail-open
from ever firing on an ordinary blind turn: an away home is the daemon's
problem, and without both the auto-arm's own failure notice and a failed outcome
in its ledger there is no evidence that the automatic mechanism was even tried.
#>
function Test-FmGuardFailureEpisodeVerified {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$FailureNotice
    )

    if (Test-FmHookPathPresent "$State/.afk") { return $false }
    if (-not (Test-FmHookPathPresent $FailureNotice)) { return $false }
    $outcome = Get-FmGuardEpochOutcome -State $State
    return ($outcome -ceq 'failed' -or $outcome -ceq 'failed-suppressed')
}

<#
.SYNOPSIS
True when the Stop-owned auto-arm already owns recovery for this event epoch.
.DESCRIPTION
Twin of autoarm_owns_recovery. Three independent proofs, in the bash twin's
order: a healthy watcher, a live owner-lock holder whose published role is
`autoarm`, or a fresh actionable outcome recorded in the epoch ledger. Any one
of them means a continuation would be a DUPLICATE, and the whole point of the
cooperative path is not to spend one.

The ROLE check is not decoration. The same lock is taken by this guard's own
terminal fail-open, so a live holder proves the auto-arm owns recovery only when
the holder says it is the auto-arm.

A fresh `failed` epoch owns recovery only the FIRST time it is accounted, and a
fresh `failed-suppressed` epoch never does - it only spends its block - which is
how an already-verified failure episode progresses toward the attended fail-open
instead of allowing forever.
#>
function Test-FmGuardAutoarmOwnsRecovery {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$WatchPath,
        [Parameter(Mandatory, Position = 2)][string]$Grace,
        [Parameter(Mandatory, Position = 3)][string]$FmHome,
        [Parameter(Mandatory, Position = 4)][long]$EpochFresh,
        [Parameter(Mandatory, Position = 5)][string]$SessionId,
        [Parameter(Mandatory, Position = 6)][string]$FailureNotice
    )

    if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) {
        return $true
    }
    $ownerLock = "$State/.claude-autoarm.lock"
    $ownerPid = (Get-FmFileText "$ownerLock/pid").TrimEnd("`r", "`n")
    $role = Get-FmHookLockRole -LockPath $ownerLock
    if ((Test-FmPidAlive -ProcessId $ownerPid) -and $role -ceq 'autoarm') {
        if (Test-FmHookPathPresent $FailureNotice) {
            $null = Invoke-FmGuardBudgetAccount -State $State -SessionId $SessionId -FailureNotice $FailureNotice
        }
        return $true
    }

    $outcome = Get-FmGuardEpochOutcome -State $State
    $epochPath = "$State/.claude-autoarm-epoch"
    if ($outcome -ceq 'rewake') {
        $age = Get-FmPathAge -Path $epochPath
        if ($age -lt $EpochFresh) {
            if (Test-FmHookPathPresent $FailureNotice) {
                $null = Invoke-FmGuardBudgetAccount -State $State -SessionId $SessionId -FailureNotice $FailureNotice
            }
            return $true
        }
    } elseif ($outcome -ceq 'failed') {
        $age = Get-FmPathAge -Path $epochPath
        if ($age -lt $EpochFresh -and (Test-FmHookPathPresent $FailureNotice) -and
            (Invoke-FmGuardBudgetAccount -State $State -SessionId $SessionId -FailureNotice $FailureNotice)) {
            if ($script:FmGuardInitializedFailure -eq 1) { return $true }
        }
    } elseif ($outcome -ceq 'failed-suppressed') {
        $age = Get-FmPathAge -Path $epochPath
        if ($age -lt $EpochFresh -and (Test-FmHookPathPresent $FailureNotice)) {
            $null = Invoke-FmGuardBudgetAccount -State $State -SessionId $SessionId -FailureNotice $FailureNotice
        }
    }
    return $false
}

<#
.SYNOPSIS
Decide the one loud attended fail-open: 0 take it, 1 refuse, 2 allow silently.
.DESCRIPTION
Twin of terminal_fail_open, and the three-valued return is the interface: 0
means publish the alarm and print the systemMessage, 1 means block as usual, and
2 means allow WITHOUT the message because recovery turned out to be under way
after all.

Everything below the first three refusals is a re-check under the owner lock,
because the cheap checks were made before it was held. Publishing the alarm with
an exclusive create is what makes the fail-open ONE-time across concurrent
firings.
#>
function Invoke-FmGuardTerminalFailOpen {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$State,
        [Parameter(Mandatory, Position = 1)][string]$WatchPath,
        [Parameter(Mandatory, Position = 2)][string]$Grace,
        [Parameter(Mandatory, Position = 3)][string]$FmHome,
        [Parameter(Mandatory, Position = 4)][string]$SessionId,
        [Parameter(Mandatory, Position = 5)][long]$BlockBudget,
        [Parameter(Mandatory, Position = 6)][string]$FailureNotice,
        [Parameter(Mandatory, Position = 7)][string]$FailureAlarm
    )

    if (-not ($script:FmGuardCount -gt $BlockBudget)) { return 1 }
    if (-not (Test-FmGuardFailureEpisodeVerified -State $State -FailureNotice $FailureNotice)) { return 1 }
    if (Test-FmHookPathPresent $FailureAlarm) { return 1 }

    $ownerLock = "$State/.claude-autoarm.lock"
    $budgetLock = "$State/.turnend-claude-blocks.lock"
    if (-not (Request-FmLock -LockPath $ownerLock)) {
        $ownerPid = (Get-FmFileText "$ownerLock/pid").TrimEnd("`r", "`n")
        $role = Get-FmHookLockRole -LockPath $ownerLock
        if ((Test-FmPidAlive -ProcessId $ownerPid) -and $role -ceq 'autoarm') { return 2 }
        return 1
    }
    if (-not (Set-FmHookLockRole -LockPath $ownerLock -Role 'terminal-check')) {
        Unlock-FmHookLock -LockPath $ownerLock
        return 1
    }
    if (-not (Request-FmLock -LockPath $budgetLock)) {
        Unlock-FmHookLock -LockPath $ownerLock
        return 1
    }

    $record = Get-FmGuardBudgetRecord -BudgetFile "$State/.turnend-claude-blocks"
    $role = Get-FmHookLockRole -LockPath $ownerLock
    if ($role -cne 'terminal-check' -or $record.Session -cne $SessionId -or
        [long]$record.BlockCount -le $BlockBudget -or
        -not (Test-FmGuardFailureEpisodeVerified -State $State -FailureNotice $FailureNotice) -or
        (Test-FmHookPathPresent $FailureAlarm)) {
        Unlock-FmLock -LockPath $budgetLock
        Unlock-FmHookLock -LockPath $ownerLock
        return 1
    }

    if (Test-FmWatcherHealthy -State $State -WatchPath $WatchPath -Grace $Grace -FmHome $FmHome) {
        if (-not (Reset-FmHookFailureEpisode -State $State -Mode 'held')) {
            Unlock-FmLock -LockPath $budgetLock
            Unlock-FmHookLock -LockPath $ownerLock
            return 1
        }
        Unlock-FmLock -LockPath $budgetLock
        Unlock-FmHookLock -LockPath $ownerLock
        return 2
    }

    # `(set -C; : > "$FAILURE_ALARM")`: an exclusive create, so exactly one
    # firing can ever open the attended fail-open for this episode.
    try {
        $stream = [System.IO.File]::Open((ConvertTo-FmNativePath $FailureAlarm),
            [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Dispose()
    } catch {
        $null = $_
        Unlock-FmLock -LockPath $budgetLock
        Unlock-FmHookLock -LockPath $ownerLock
        return 1
    }
    Unlock-FmLock -LockPath $budgetLock
    Unlock-FmHookLock -LockPath $ownerLock
    return 0
}

<#
.SYNOPSIS
Print the blind-turn banner on stderr. The caller then exits 2.
.DESCRIPTION
Twin of block_stop, including that the repair line comes from
bin/fm-supervision-instructions (through Invoke-FmScript, so the transition
picks whichever twin exists) and that a failure to run it degrades to the
literal fallback rather than to silence - a block with no instruction would be a
wedge with no way out.

The middle line names WHY supervision is needed, and the three cases are ordered
exactly as the bash twin orders them: in-flight tasks, then registered
process-event sources, then X-mode relay polling. A home can need a watcher
without holding a single task, which is the whole reason the second and third
lines exist.
#>
function Write-FmGuardBlockBanner {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$BinDir,
        [Parameter(Mandatory, Position = 1)][string]$State,
        [Parameter(Mandatory, Position = 2)][string]$ConfigDir,
        [Parameter(Mandatory, Position = 3)][int]$InFlight,
        [Parameter(Mandatory, Position = 4)][int]$Sources,
        [Parameter(Mandatory, Position = 5)][string]$BeaconDescription,
        [Parameter(Mandatory, Position = 6)][bool]$ClaudeMode
    )

    # `[ -e ... ]` and `[ -f ... ]`, kept distinct exactly as the bash twin has
    # them: an away-mode flag counts whatever kind of entry it is, while the
    # X-mode cadence must be a regular file.
    $afk = 0
    if (Test-FmHookPathPresent "$State/.afk") { $afk = 1 }
    $xMode = 0
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath "$ConfigDir/x-mode.env"))) { $xMode = 1 }

    $reason = $script:FmGuardFallbackReason
    try {
        $result = Invoke-FmScript -Name 'fm-supervision-instructions' -BinDir $BinDir -Arguments @(
            '--afk', [string]$afk, '--x-mode', [string]$xMode, '--repair-line'
        )
        if ($result.Ok) {
            $text = $result.StdOut.TrimEnd("`n")
            if (-not [string]::IsNullOrEmpty($text)) { $reason = $text }
        }
    } catch {
        # `|| printf '%s\n' '<fallback>'`: an unrunnable instruction renderer
        # must never turn a block into a silent one.
        $null = $_
    }

    $rule = $script:FmGuardRule
    Write-FmErr "●$rule"
    Write-FmErr '●  TURN WOULD END BLIND - SUPERVISION IS OFF'
    if ($InFlight -gt 0) {
        Write-FmErr "●  $InFlight task(s) in flight, but no live watcher holds this home lock (last beat: $BeaconDescription)."
    } elseif ($Sources -gt 0) {
        Write-FmErr "●  $Sources process-event source(s) registered, but no live watcher holds this home lock (last beat: $BeaconDescription)."
    } else {
        Write-FmErr "●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: $BeaconDescription)."
    }
    if ($ClaudeMode) {
        Write-FmErr '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.'
    }
    Write-FmErr "●  $reason"
    Write-FmErr "●$rule"
}

<#
.SYNOPSIS
The whole guard, returning the process exit code instead of taking it.
#>
function Invoke-FmTurnendGuard {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Position = 0)][AllowEmptyCollection()][string[]]$Arguments = @())

    $context = Get-FmContext -ScriptRoot $PSScriptRoot
    $state = $context.State
    $configDir = $context.Config
    $grace = Get-FmEnv -Name 'FM_GUARD_GRACE' -Default '300'
    $watch = Get-FmGuardWatchPath -BinDir $PSScriptRoot
    $syncWaitMs = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_AUTOARM_SYNC_WAIT_MS' -Default 800
    $epochFresh = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_AUTOARM_EPOCH_FRESH' -Default 15 -RejectZero
    $blockBudget = Get-FmGuardNumericKnob -Name 'FM_CLAUDE_TURNEND_BLOCK_BUDGET' -Default 3 -RejectZero

    $claudeMode = $false
    foreach ($arg in $Arguments) {
        if ($arg -ceq '--claude') {
            $claudeMode = $true
            continue
        }
        # The usage line still names the .sh twin: it is the documented CLI
        # surface (contract 4) and both files must print the same bytes while
        # both exist.
        Write-FmErr 'usage: fm-turnend-guard.sh [--claude]'
        return 2
    }

    # Read the whole turn-end hook payload once; never block on unreadable or
    # absent stdin. `$(cat)` strips trailing newlines, so a payload of nothing
    # but newlines is empty in both worlds.
    $payload = ''
    try { $payload = [Console]::In.ReadToEnd() } catch { $payload = '' }
    if ($null -eq $payload) { $payload = '' }
    $payload = $payload.TrimEnd("`n")
    if ($payload -eq '') { return 0 }

    $stopHookActive = Get-FmGuardStopHookActive -Payload $payload
    if ($null -eq $stopHookActive) { return 0 }
    if (-not $claudeMode -and $stopHookActive) { return 0 }

    # --- scope precisely to a PRIMARY checkout -------------------------------
    # A genuinely-marked secondmate home runs its OWN primary firstmate session,
    # so force-INCLUDE it as a guarded primary whether treehouse leased it as a
    # linked worktree (git-dir != git-common-dir) or it is a git-cloned plain
    # checkout. Only an UNMARKED checkout (or one with an invalid marker) falls
    # through to the linked-worktree exemption: firstmate hands out
    # crewmate/scout task worktrees as genuine linked worktrees, and those never
    # carry the gitignored marker.
    if (-not (Test-FmPrimaryScopeMatch -Root $context.Root -State $state)) { return 0 }

    # --- the actual predicate ------------------------------------------------
    $budgetFile = "$state/.turnend-claude-blocks"
    $budgetLock = "$state/.turnend-claude-blocks.lock"
    $failureNotice = "$state/.claude-autoarm-failure-notified"
    $failureAlarm = "$state/.claude-autoarm-failure-alarmed"
    $sessionId = Get-FmGuardSessionId -Payload $payload

    $resetBudget = {
        if ($claudeMode) {
            if (Request-FmLock -LockPath $budgetLock) {
                try {
                    $native = ConvertTo-FmNativePath $budgetFile
                    if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
                } catch {
                    # `rm -f ... || true`.
                    $null = $_
                }
                Unlock-FmLock -LockPath $budgetLock
            }
        }
    }

    $status = Get-FmSupervisionStatus -State $state -Grace $grace
    # NEEDED, not the in-flight count, in BOTH modes: an X-only home and a home
    # whose only registered supervision is a process-event source both need a
    # live watcher while carrying no tasks at all.
    if (-not $status.Needed) {
        # A home in an open failure episode keeps its record: clearing it here
        # would hand the next episode a fresh budget it did not earn.
        if (-not (Test-FmHookPathPresent $failureNotice)) { & $resetBudget }
        return 0
    }
    if (Test-FmWatcherHealthy -State $state -WatchPath $watch -Grace $grace -FmHome $context.Home) {
        if (-not $claudeMode) { return 0 }
        if (Reset-FmHookFailureEpisode -State $state) { return 0 }
        return 2
    }

    $blockArgs = @{
        BinDir            = $PSScriptRoot
        State             = $state
        ConfigDir         = $configDir
        InFlight          = $status.InFlight
        Sources           = $status.Sources
        BeaconDescription = $status.BeaconDescription
        ClaudeMode        = $claudeMode
    }

    if (-not $claudeMode) {
        Write-FmGuardBlockBanner @blockArgs
        return 2
    }

    # --- --claude cooperative path -------------------------------------------
    # The Stop-owned auto-arm fires on the same Stop event. Give it a brief
    # bounded window to prove it owns recovery for this event epoch before
    # consuming one of Claude's bounded continuations.
    $ownsArgs = @{
        State         = $state
        WatchPath     = $watch
        Grace         = $grace
        FmHome        = $context.Home
        EpochFresh    = $epochFresh
        SessionId     = $sessionId
        FailureNotice = $failureNotice
    }
    $healthyArgs = @{
        State     = $state
        WatchPath = $watch
        Grace     = $grace
        FmHome    = $context.Home
    }
    $iterations = [long][Math]::Floor($syncWaitMs / 100)
    for ($i = 0; $i -lt $iterations; $i++) {
        if (Test-FmGuardAutoarmOwnsRecovery @ownsArgs) {
            if (Test-FmWatcherHealthy @healthyArgs) {
                if (-not (Reset-FmHookFailureEpisode -State $state)) { return 2 }
            }
            return 0
        }
        Start-Sleep -Milliseconds 100
    }
    if (Test-FmGuardAutoarmOwnsRecovery @ownsArgs) {
        if (Test-FmWatcherHealthy @healthyArgs) {
            if (-not (Reset-FmHookFailureEpisode -State $state)) { return 2 }
        }
        return 0
    }

    # The auto-arm genuinely failed to establish: consume the bounded re-block
    # budget before considering the verified one-time attended fail-open.
    if (-not (Invoke-FmGuardBudgetAccount -State $state -SessionId $sessionId -FailureNotice $failureNotice)) {
        Write-FmGuardBlockBanner @blockArgs
        return 2
    }
    $terminalStatus = Invoke-FmGuardTerminalFailOpen -State $state -WatchPath $watch -Grace $grace `
        -FmHome $context.Home -SessionId $sessionId -BlockBudget $blockBudget `
        -FailureNotice $failureNotice -FailureAlarm $failureAlarm
    if ($terminalStatus -eq 0) {
        $needDesc = 'X-mode relay polling active'
        if ($status.InFlight -gt 0) {
            $needDesc = "$($status.InFlight) task(s) in flight"
        } elseif ($status.Sources -gt 0) {
            $needDesc = "$($status.Sources) process-event source(s) registered"
        }
        Write-FmOut ('{"systemMessage":"FIRSTMATE SUPERVISION IS GENUINELY DOWN: ' + $needDesc +
            ', the Stop-owned auto-arm exhausted its bounded retries and one failure notice,' +
            ' no watcher or automatic continuation exists, and the block budget is exhausted.' +
            ' Keep this session attended and diagnose the automatic Stop-hook and watcher startup' +
            ' before relying on unattended supervision."}')
        return 0
    }
    if ($terminalStatus -eq 2) { return 0 }
    Write-FmGuardBlockBanner @blockArgs
    return 2
}

# Not Invoke-FmMain: an escaped exception must NOT become a nonzero code here,
# because 2 is the BLOCK signal and a defect that blocked every turn end would
# wedge the captain's session. A guard that cannot decide allows, exactly as
# every documented failure path in the bash twin does.
$fmExitCode = 0
try {
    foreach ($fmItem in @(Invoke-FmTurnendGuard -Arguments $fmArgv)) {
        if ($fmItem -is [int]) { $fmExitCode = $fmItem }
    }
} catch {
    $null = $_
    $fmExitCode = 0
}
Exit-FmScript $fmExitCode
