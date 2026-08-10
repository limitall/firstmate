# bin/fm-promote.ps1 - promote a scout task to a ship task in place: the crewmate
# keeps its window, worktree, and loaded context; only the contract changes.
# Flips kind= to ship in state/<task-id>.meta so fm-teardown applies the full
# ship-task teardown protection again. After promoting, send the crewmate its
# ship instructions via fm-send (inventory scratch state, reset to a clean
# default-branch base, carry over only intended fix changes, create branch
# fm/<task-id>, implement, then report done according to this task's delivery
# mode).
#
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
#
# Twin: bin/fm-promote.sh
#
# Usage: fm-promote.ps1 <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
#
# ---------------------------------------------------------------------------
# SIX MECHANICS THE BASH TWIN GETS FROM ITS SHELL AND THIS FILE MUST SPELL OUT
#
#   1. THE ORDER OF THE CHECKS IS OBSERVABLE, and it is not the order a reader
#      would guess. Everything the argument parser can decide is decided BEFORE
#      the supervision guard runs and before the per-task control lock is taken:
#      a refused promotion must not print a guard banner, must not contend for a
#      lifecycle lock, and must leave no lock artifact behind. The guard runs
#      only once the arguments are known good AND the control lock is held, so
#      its banner accompanies an action that is actually about to happen.
#
#   2. `grep -qx 'kind=scout'` is an ANCHORED WHOLE-LINE match, not a prefix
#      test and not fm_meta_get's last-wins read. A record carrying
#      `kind=scoutish` is NOT a scout, and a record carrying both `kind=ship`
#      and `kind=scout` IS one - because any single line matching is enough.
#      Get-FmMetaValue would answer differently for the second case, so the
#      whole-line scan is reproduced rather than delegated.
#
#   3. `grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"` under
#      `set -e` ABORTS when the filter matches nothing - grep exits 1 on no
#      output - with no diagnostic at all. That is the observable behavior for a
#      meta whose every line is a kind=/mode=/yolo= line, and it is reproduced
#      here (silent exit 1) rather than "fixed", because a caller distinguishing
#      0 from 1 must see the same answer. Unlike the older twin, the temp file
#      does NOT survive: the EXIT trap owns its removal, so the abort leaves the
#      state directory exactly as it found it.
#
#   4. TWO LOCKS, RELEASED IN REVERSE ORDER BY AN EXIT TRAP. The per-task
#      control lock serializes lifecycle actions on one task and is TRY-acquired
#      (a second lifecycle action refuses rather than queueing); the per-meta
#      lock serializes writers of one record and is WAIT-acquired. The trap that
#      releases them also removes the temp file, and it must cover a refusal
#      raised anywhere below the acquire - which is what the try/finally around
#      the locked region is for. `exit` unwinds through `finally` in PowerShell,
#      exactly as an EXIT trap fires in bash.
#
#   5. `printf '%q'` quotes for re-entry into a shell. The next-step line it
#      builds is COPY-PASTED by the captain into a shell, so the quoting is
#      load-bearing rather than cosmetic. Get-FmPromoteShellQuoted reproduces
#      bash's rule for every byte firstmate actually puts in a home path;
#      control characters, which bash renders in $'...' form, are the one shape
#      left unhandled and are documented at the function.
#
#   6. EVERY STRING COMPARISON IS ORDINAL AND CASE-SENSITIVE, because bash's
#      `case` is. `--MODE=No-Mistakes` is not `--mode=no-mistakes`, and
#      `direct-PR` is the one accepted spelling of that mode.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCES FROM THE BASH ORACLE
#
#   THE PROGRAM NAME IN THE USAGE LINE. The bash twin's usage string is a
#   literal that names `fm-promote.sh`, not a `$0` expansion, so this twin
#   prints that same literal rather than its own name - a captain copying the
#   line must get a command that runs on either side of the conversion.
#
#   THE TEMP FILE NAME embeds `${BASHPID:-$$}` in bash and $PID here. Both are
#   this process's id; the durable outcome (the temp is renamed over the meta,
#   or removed) is identical, and no caller reads the intermediate name.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOT -Force, for two independent reasons (docs/powershell-port.md). A -Force
# import REMOVES the loaded module globally first, which would strip fm-common's
# commands from anything that had already imported it in this process; and
# fm-wake-lib snapshots its context at IMPORT, so re-importing it mid-process
# would silently re-resolve the very paths a running caller is using.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-pr-lib.psm1')
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1')

$fmArgv = @($args)

# Cleanup state, script-scoped so the finally block below can see what the
# locked region managed to take. These are the twins of the bash TMP /
# META_LOCK / META_LOCK_HELD / CONTROL_LOCK / CONTROL_LOCK_HELD globals that
# promote_cleanup reads.
$script:PromoteTmp = ''
$script:PromoteMetaLock = ''
$script:PromoteMetaLockHeld = $false
$script:PromoteControlLock = ''
$script:PromoteControlLockHeld = $false

<#
.SYNOPSIS
Quote a string for re-entry into a POSIX shell, as bash's `printf '%q'` does.
.DESCRIPTION
bash emits the string unchanged when every byte is in its "safe" set, and
otherwise backslash-escapes each unsafe byte. An EMPTY string becomes '' - the
one case where bash switches representation entirely. Control characters would
become $'...' in bash; firstmate home paths cannot contain them, so that shape
is deliberately not reproduced and would round-trip as a backslash escape here.
#>
function Get-FmPromoteShellQuoted {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text)

    if ($Text -eq '') { return "''" }
    if ($Text -match '\A[A-Za-z0-9_@%+=:,./-]+\z') { return $Text }

    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Text.ToCharArray()) {
        if ("$ch" -match '[A-Za-z0-9_@%+=:,./-]') {
            [void]$sb.Append($ch)
        } else {
            [void]$sb.Append('\').Append($ch)
        }
    }
    return $sb.ToString()
}

<#
.SYNOPSIS
The per-record lock path for a state/<id>.meta file, or '' when the path is not
a lockable meta record.
.DESCRIPTION
Twin of fm_meta_lock_path in bin/fm-wake-lib.sh, which has no PowerShell twin
yet - bin/fm-wake-lib.psm1 exports the lock PRIMITIVES but not this path rule,
and that module is not this task's to edit. Reproduced here arm for arm:

    dir=${meta%/*}      -> everything before the LAST separator, '.' when none
    base=${meta##*/}    -> the leaf
    *.meta              -> required, else refuse
    id=${base%.meta}    -> non-empty and [A-Za-z0-9._-] only, else refuse
    "$dir/.meta-$id.lock"

The refusal cases are unreachable from this script (the id has already passed
Test-FmTaskIdCreationValid and the path is composed here), but they are kept so
the helper is a faithful twin rather than a convenience wrapper. bash returns
nonzero there and the caller exits 1 with no message; '' carries that here.
#>
function Get-FmPromoteMetaLockPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$MetaPath)

    if ([string]::IsNullOrEmpty($MetaPath)) { return '' }
    # Only '/' is a separator for this rule: the bash twin's ${meta%/*} sees
    # nothing else, and every meta path composed in this tree uses it.
    $slash = $MetaPath.LastIndexOf('/')
    $dir = if ($slash -lt 0) { '.' } else { $MetaPath.Substring(0, $slash) }
    $base = if ($slash -lt 0) { $MetaPath } else { $MetaPath.Substring($slash + 1) }
    if (-not $base.EndsWith('.meta', [System.StringComparison]::Ordinal)) { return '' }
    $id = $base.Substring(0, $base.Length - 5)
    if ([string]::IsNullOrEmpty($id)) { return '' }
    if (-not [regex]::IsMatch($id, '\A[A-Za-z0-9._-]+\z')) { return '' }
    return "$dir/.meta-$id.lock"
}

<#
.SYNOPSIS
The EXIT trap: drop the temp file, then release both locks in reverse order.
.DESCRIPTION
Twin of promote_cleanup. Every step is best-effort and none of them may raise:
in bash each is `|| true`, and a cleanup failure must never replace the exit
status the script already decided on.
#>
function Invoke-FmPromoteCleanup {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrEmpty($script:PromoteTmp)) {
        try {
            $native = ConvertTo-FmNativePath $script:PromoteTmp
            if ([System.IO.File]::Exists($native)) { [System.IO.File]::Delete($native) }
        } catch {
            $null = $_
        }
    }
    if ($script:PromoteMetaLockHeld) {
        $script:PromoteMetaLockHeld = $false
        try { Unlock-FmLock -LockPath $script:PromoteMetaLock } catch { $null = $_ }
    }
    if ($script:PromoteControlLockHeld) {
        $script:PromoteControlLockHeld = $false
        try { Unlock-FmLock -LockPath $script:PromoteControlLock } catch { $null = $_ }
    }
}

Invoke-FmMain -UnexpectedCode 70 {
    # The bash resolution block, in string terms. FM_HOME is kept in the
    # spelling the caller supplied (POSIX under Git Bash) because it is ECHOED
    # into the next-step command line; native form is used only where a .NET
    # file API needs it, which fm-common's helpers do for themselves.
    $rootOverride = Get-FmEnv -Name 'FM_ROOT_OVERRIDE'
    $homeEnv = Get-FmEnv -Name 'FM_HOME'
    $context = Get-FmContext $PSScriptRoot

    $fmRoot = if ($rootOverride) { $rootOverride } else { $context.PosixRoot }
    $fmHome = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }
    $stateOverride = Get-FmEnv -Name 'FM_STATE_OVERRIDE'
    $state = if ($stateOverride) { $stateOverride } else { "$fmHome/state" }

    # --- argument parsing ---------------------------------------------------
    #
    # bash's two-pass shape: a pending `want_value` consumes the NEXT argument,
    # and an argument that itself starts with `--` is refused rather than eaten,
    # so `--mode --yolo on` never silently promotes with mode='--yolo'.
    $mode = ''
    $yolo = ''
    $modeSet = $false
    $yoloSet = $false
    $positional = [System.Collections.Generic.List[string]]::new()
    $wantValue = ''

    foreach ($rawArg in $fmArgv) {
        $a = [string]$rawArg
        if ($wantValue -ne '') {
            if ($a.StartsWith('--', [System.StringComparison]::Ordinal)) {
                Write-FmErr "error: --$wantValue requires a value"
                Exit-FmScript 1
            }
            if ($wantValue -ceq 'mode') { $mode = $a; $modeSet = $true }
            elseif ($wantValue -ceq 'yolo') { $yolo = $a; $yoloSet = $true }
            $wantValue = ''
            continue
        }
        if ($a -ceq '--mode') {
            $wantValue = 'mode'
        } elseif ($a.StartsWith('--mode=', [System.StringComparison]::Ordinal)) {
            $mode = $a.Substring(7); $modeSet = $true
        } elseif ($a -ceq '--yolo') {
            $wantValue = 'yolo'
        } elseif ($a.StartsWith('--yolo=', [System.StringComparison]::Ordinal)) {
            $yolo = $a.Substring(7); $yoloSet = $true
        } else {
            $positional.Add($a)
        }
    }
    if ($wantValue -ne '') {
        Write-FmErr "error: --$wantValue requires a value"
        Exit-FmScript 1
    }
    if ($positional.Count -lt 1) {
        Write-FmErr 'usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>'
        Exit-FmScript 1
    }
    if (-not $modeSet) {
        Write-FmErr ("error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now " +
            "from the scout's findings and the project's registered posture in data/projects.md")
        Exit-FmScript 1
    }
    if (-not $yoloSet) {
        Write-FmErr ("error: promotion requires --yolo <on|off>; it is this task's routine approval " +
            'authority, not a project lookup')
        Exit-FmScript 1
    }
    if ($mode -cne 'no-mistakes' -and $mode -cne 'direct-PR' -and $mode -cne 'local-only') {
        if ($mode -ceq 'no-mistakes-prod-only') {
            Write-FmErr ('error: no-mistakes-prod-only is a registry policy, not a task mode; classify ' +
                "this task's surface and resolve it to no-mistakes or direct-PR")
        } else {
            Write-FmErr "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$mode')"
        }
        Exit-FmScript 1
    }
    if ($yolo -cne 'on' -and $yolo -cne 'off') {
        Write-FmErr "error: --yolo must be on or off (got '$yolo')"
        Exit-FmScript 1
    }

    $id = [string]$positional[0]
    if (-not (Test-FmTaskIdCreationValid -Id $id)) {
        Write-FmErr 'error: invalid task id'
        Exit-FmScript 2
    }

    # --- locked region ------------------------------------------------------
    #
    # From here the EXIT trap is armed (the finally below), exactly as bash arms
    # `trap promote_cleanup EXIT` before its first acquire.
    $script:PromoteControlLock = "$state/.control-$id.lock"
    try {
        if (-not (Request-FmLock -LockPath $script:PromoteControlLock)) {
            Write-FmErr "error: another lifecycle action is already running for task $id; nothing was changed"
            Exit-FmScript 1
        }
        $script:PromoteControlLockHeld = $true

        # `|| true`: the guard is advisory here and its failure never blocks a
        # promotion. Streamed rather than captured because its output is the
        # captain's, exactly as the bash twin's unredirected call is.
        $null = Invoke-FmScript -Name 'fm-guard' -BinDir "$fmRoot/bin" -Stream

        $meta = "$state/$id.meta"
        if (-not [System.IO.Directory]::Exists((ConvertTo-FmNativePath $state))) {
            Write-FmErr "error: state dir not found: $state"
            Exit-FmScript 1
        }

        $script:PromoteMetaLock = Get-FmPromoteMetaLockPath $meta
        # bash: `META_LOCK=$(fm_meta_lock_path "$META") || exit 1` - a refusal
        # exits 1 with no diagnostic of its own.
        if ([string]::IsNullOrEmpty($script:PromoteMetaLock)) { Exit-FmScript 1 }
        Wait-FmLock -LockPath $script:PromoteMetaLock
        $script:PromoteMetaLockHeld = $true

        if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
            Write-FmErr "error: no meta for task $id at $meta"
            Exit-FmScript 1
        }

        # grep -qx: whole-line, unanchored to position in the file.
        $lines = (Get-FmFileLines $meta)
        $isScout = $false
        foreach ($line in $lines) { if ($line -ceq 'kind=scout') { $isScout = $true } }
        if (-not $isScout) {
            Write-FmErr "error: task $id is not a scout task (kind=scout not in meta)"
            Exit-FmScript 1
        }

        $kept = @($lines | Where-Object {
                -not ($_.StartsWith('kind=', [System.StringComparison]::Ordinal) -or
                    $_.StartsWith('mode=', [System.StringComparison]::Ordinal) -or
                    $_.StartsWith('yolo=', [System.StringComparison]::Ordinal))
            })
        $script:PromoteTmp = "$state/.$id.meta.promote.$PID"

        # grep writes its (possibly empty) output before its exit status is
        # known, so the temp file exists either way; the cleanup then removes it
        # on the abort path. See mechanic 3 in the header.
        $body = ''
        foreach ($line in $kept) { $body += "$line`n" }
        Set-FmFileText -Path $script:PromoteTmp -Text $body -NoNewline
        if ($kept.Count -eq 0) { Exit-FmScript 1 }

        Add-FmFileLine -Path $script:PromoteTmp -Line 'kind=ship'
        Add-FmFileLine -Path $script:PromoteTmp -Line "mode=$mode"
        Add-FmFileLine -Path $script:PromoteTmp -Line "yolo=$yolo"
        [System.IO.File]::Move((ConvertTo-FmNativePath $script:PromoteTmp),
            (ConvertTo-FmNativePath $meta), $true)
        # `TMP=` after the mv: the record is published, so the cleanup must not
        # go looking for a file that is now the meta.
        $script:PromoteTmp = ''

        Unlock-FmLock -LockPath $script:PromoteMetaLock
        $script:PromoteMetaLockHeld = $false

        $homeQuoted = Get-FmPromoteShellQuoted $fmHome
        Write-FmOut "promoted $id to ship mode=$mode yolo=$yolo (teardown protection restored)"
        Write-FmOut ("next: FM_HOME=$homeQuoted bin/fm-send.sh fm-$id " +
            "'<ship instructions for mode=${mode}: review scratch state with git status and git log; " +
            'reset to a clean default-branch base; carry over only intended fix changes; ' +
            "create branch fm/${id}; implement; report done>'")
        Exit-FmScript 0
    } finally {
        Invoke-FmPromoteCleanup
    }
}
