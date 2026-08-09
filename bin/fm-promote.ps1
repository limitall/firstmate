# bin/fm-promote.ps1 - promote a scout task to a ship task in place: the crewmate
# keeps its window, worktree, and loaded context; only the contract changes.
# Flips kind= to ship in state/<task-id>.meta so fm-teardown applies the full
# ship-task teardown protection again. After promoting, send the crewmate its
# ship instructions via fm-send (inventory scratch state, reset to a clean
# default-branch base, carry over only intended fix changes, create branch
# fm/<task-id>, implement, then report done according to the project's delivery
# mode).
#
# Twin: bin/fm-promote.sh
#
# Usage: fm-promote.ps1 <task-id>
#
# ---------------------------------------------------------------------------
# THREE MECHANICS THE BASH TWIN GETS FROM ITS SHELL AND THIS FILE MUST SPELL OUT
#
#   1. `grep -qx 'kind=scout'` is an ANCHORED WHOLE-LINE match, not a prefix
#      test and not fm_meta_get's last-wins read. A record carrying
#      `kind=scoutish` is NOT a scout, and a record carrying both `kind=ship`
#      and `kind=scout` IS one - because any single line matching is enough.
#      Get-FmMetaValue would answer differently for the second case, so the
#      whole-line scan is reproduced rather than delegated.
#
#   2. `grep -v '^kind=' "$META" > "$TMP"` under `set -e` ABORTS when the filter
#      matches nothing - grep exits 1 on no output - leaving the (empty) temp
#      file behind and the meta untouched, with no diagnostic at all. That is
#      the observable behavior for a meta whose every line is a kind= line, and
#      it is reproduced here (silent exit 1, temp left) rather than "fixed",
#      because a caller distinguishing 0 from 1 must see the same answer.
#
#   3. `printf '%q'` quotes for re-entry into a shell. The next-step line it
#      builds is COPY-PASTED by the captain into a shell, so the quoting is
#      load-bearing rather than cosmetic. Get-FmPromoteShellQuoted reproduces
#      bash's rule for every byte firstmate actually puts in a home path;
#      control characters, which bash renders in $'...' form, are the one shape
#      left unhandled and are documented at the function.
#
# ---------------------------------------------------------------------------
# KNOWN DIVERGENCE FROM THE BASH ORACLE
#
#   MISSING ARGUMENT. `ID=$1` under `set -u` aborts bash with its own
#   "fm-promote.sh: line 17: $1: unbound variable" - a message that embeds a
#   line number no twin should pin. The exit code (1) is reproduced; the text is
#   not. The differential suite compares the code and the state tree, not that
#   line.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force

$fmArgv = @($args)

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

    # `|| true`: the guard is advisory here and its failure never blocks a
    # promotion. Streamed rather than captured because its output is the
    # captain's, exactly as the bash twin's unredirected call is.
    $null = Invoke-FmScript -Name 'fm-guard' -BinDir "$fmRoot/bin" -Stream

    # `ID=$1` under set -u: no argument is a hard abort with code 1.
    if ($fmArgv.Count -lt 1) { Exit-FmScript 1 }
    $id = [string]$fmArgv[0]

    $meta = "$state/$id.meta"
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $meta))) {
        Write-FmErr "error: no meta for task $id at $meta"
        Exit-FmScript 1
    }

    # grep -qx: whole-line, unanchored to position in the file.
    $lines = @(Get-FmFileLines $meta)
    $isScout = $false
    foreach ($line in $lines) { if ($line -ceq 'kind=scout') { $isScout = $true } }
    if (-not $isScout) {
        Write-FmErr "error: task $id is not a scout task (kind=scout not in meta)"
        Exit-FmScript 1
    }

    $kept = @($lines | Where-Object { -not $_.StartsWith('kind=', [System.StringComparison]::Ordinal) })
    $tmp = "$meta.tmp"

    # grep writes its (possibly empty) output before its exit status is known,
    # so the temp file exists either way; see mechanic 2 in the header.
    $body = ''
    foreach ($line in $kept) { $body += "$line`n" }
    Set-FmFileText -Path $tmp -Text $body -NoNewline
    if ($kept.Count -eq 0) { Exit-FmScript 1 }

    Add-FmFileLine -Path $tmp -Line 'kind=ship'
    [System.IO.File]::Move((ConvertTo-FmNativePath $tmp), (ConvertTo-FmNativePath $meta), $true)

    $homeQuoted = Get-FmPromoteShellQuoted $fmHome
    Write-FmOut "promoted $id to ship (teardown protection restored)"
    Write-FmOut ("next: FM_HOME=$homeQuoted bin/fm-send.sh fm-$id " +
        "'<ship instructions: review scratch state with git status and git log; " +
        "reset to a clean default-branch base; carry over only intended fix changes; " +
        "create branch fm/$id; implement; report done>'")
    Exit-FmScript 0
}
