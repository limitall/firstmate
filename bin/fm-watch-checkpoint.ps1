# bin/fm-watch-checkpoint.ps1 - run one bounded foreground watcher checkpoint
# for harnesses that should not rely on background-task completion to wake the
# model.
#
# Twin: bin/fm-watch-checkpoint.sh
#
# CLI:
#   fm-watch-checkpoint.ps1 [--seconds <n>] [--seconds=<n>]
#   fm-watch-checkpoint.ps1 -h | --help
#
# On an actionable watcher wake, pass through the watcher output and exit 0.
# On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and
# exit 124. A watcher already running outside this checkpoint exits 1.
#
# ---------------------------------------------------------------------------
# DIVERGENCES, AND WHY NONE OF THEM IS OBSERVABLE
#
#   1. THE TIMEOUT MECHANISM. The bash twin tries `timeout`, then `gtimeout`,
#      then a hand-rolled perl fork/setpgrp/alarm that TERMs and then KILLs the
#      process group. None of those exist natively on Windows, so the bound here
#      comes from Invoke-FmTool's -TimeoutSeconds, which kills the child's whole
#      process TREE and reports 124 - the same exit convention the bash tree
#      already tests against, and the same reason the perl leg builds a process
#      group in the first place (a watcher's own children must not survive it).
#
#   2. OUTPUT CAPTURED ON EXPIRY IS DISCARDED. Invoke-FmTool returns no stdout
#      for a timed-out child. That changes nothing observable: on the 124 leg
#      the bash twin prints ONLY the checkpoint line and discards $OUT and $ERR
#      too. The two branches that DO pass output through - an actionable wake,
#      and "watcher: already running" - are both fast, clean exits that no
#      timeout can reach.
#
#   3. NO TEMP FILES. $OUT/$ERR exist in bash only because a shell cannot hold
#      two streams in variables without more forks; the trap that removes them
#      has nothing to clean up here. `mktemp` failing is therefore not a
#      reachable exit-1 path in this twin.
#
#   4. THE SIBLING IS RESOLVED, NOT SPELLED. The bash twin hard-codes
#      "$SCRIPT_DIR/fm-watch.sh"; this runs the watcher through Invoke-FmScript,
#      which prefers bin/fm-watch.ps1 and falls back to bin/fm-watch.sh under
#      Git Bash, so the checkpoint is correct on either side of the conversion
#      (docs/powershell-port.md contract 7).

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# NOT -Force: see the note in bin/fm-wake-drain.ps1.
Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

# No param() block: the CLI takes bare positional words including `-h`, and a
# declared param block would make PowerShell try to BIND `-h` and fail before
# the script runs. Captured first because inside the Invoke-FmMain script block
# `$args` would resolve to that block's own (empty) argument array.
$fmArgv = @($args)

$FmCheckpointWakeRegex = '^(signal:|stale:|check:|heartbeat($|:))'

function Write-FmCheckpointUsage {
    param([switch]$ToStdErr)

    $lines = @(
        'Usage: fm-watch-checkpoint.sh [--seconds <n>]'
        ''
        'Run bin/fm-watch.sh in the foreground for a bounded checkpoint.'
        'On an actionable watcher wake, pass through the watcher output and exit 0.'
        'On a quiet checkpoint, print "checkpoint: no actionable wake within <n>s" and exit 124.'
    )
    # The usage text names the BASH twin's filenames verbatim. That is
    # deliberate: --help output is a CLI surface (contract 4), the two twins
    # must print the same bytes, and cutover rewrites both together.
    foreach ($line in $lines) {
        if ($ToStdErr) { Write-FmErr $line } else { Write-FmOut $line }
    }
}

# `grep -Eq '<pattern>' <file>`: does ANY line match, anchored at line start.
function Test-FmCheckpointMatch {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($line in ($Text -split "`n")) {
        if ($line -cmatch $Pattern) { return $true }
    }
    return $false
}

Invoke-FmMain -UnexpectedCode 70 {
    $secondsArg = Get-FmEnv -Name 'FM_CODEX_WATCH_CHECKPOINT' -Default '180'

    # if/elseif rather than `switch`: PowerShell's `continue` inside a switch
    # binds to the SWITCH, not to the enclosing while, so a switch-shaped
    # translation of this loop silently stops advancing the index.
    $i = 0
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        if ($arg -ceq '--seconds') {
            if ($i + 1 -ge $fmArgv.Count) {
                Write-FmErr 'error: --seconds requires a value'
                Exit-FmScript -Code 2
            }
            $secondsArg = [string]$fmArgv[$i + 1]
            $i += 2
        } elseif ($arg.StartsWith('--seconds=', [System.StringComparison]::Ordinal)) {
            $secondsArg = $arg.Substring('--seconds='.Length)
            $i++
        } elseif ($arg -ceq '-h' -or $arg -ceq '--help') {
            Write-FmCheckpointUsage
            Exit-FmScript -Code 0
        } else {
            Write-FmErr "error: unknown argument: $arg"
            Write-FmCheckpointUsage -ToStdErr
            Exit-FmScript -Code 2
        }
    }

    # `case "$SECONDS_ARG" in ''|*[!0-9]*) ... ;; 0) ... ;; esac` - an empty or
    # non-digit value and a literal zero are distinct diagnostics, and a
    # multi-digit "00" reaches neither because it is digits and not the string
    # "0". Reproduced exactly, including that last quirk.
    if ([string]::IsNullOrEmpty($secondsArg) -or $secondsArg -notmatch '^[0-9]+$') {
        Write-FmErr 'error: --seconds must be a positive integer'
        Exit-FmScript -Code 2
    }
    if ($secondsArg -ceq '0') {
        Write-FmErr 'error: --seconds must be greater than zero'
        Exit-FmScript -Code 2
    }

    [int]$timeout = 0
    if (-not [int]::TryParse($secondsArg, [ref]$timeout)) {
        # A digit string too long for an int cannot bound anything sensible;
        # bash would hand it to timeout(1), which refuses it the same way.
        Write-FmErr 'error: --seconds must be a positive integer'
        Exit-FmScript -Code 2
    }

    $result = Invoke-FmScript -Name 'fm-watch' -TimeoutSeconds $timeout
    $out = [string]$result.StdOut
    $err = [string]$result.StdErr
    $rc = [int]$result.ExitCode
    if ($rc -eq 124) {
        # Invoke-FmTool synthesizes its own 'fm: timed out' diagnostic; the bash
        # twin's timeout(1) prints nothing, so it is dropped rather than leaked
        # into the checkpoint's stderr.
        $out = ''
        $err = ''
    }

    if (Test-FmCheckpointMatch -Text $out -Pattern $FmCheckpointWakeRegex) {
        # `cat "$OUT"` then `[ ! -s "$ERR" ] || cat "$ERR" >&2`. stdout is a raw
        # pass-through; stderr goes through the LF-terminating writer with one
        # trailing newline folded, which is what a watcher diagnostic (always a
        # single newline-terminated line) actually carries.
        Write-FmRaw $out
        if (-not [string]::IsNullOrEmpty($err)) { Write-FmErr ($err.TrimEnd("`n")) }
        Exit-FmScript -Code 0
    }

    if ((Test-FmCheckpointMatch -Text $out -Pattern '^watcher: already running') -or
        (Test-FmCheckpointMatch -Text $err -Pattern '^watcher: already running')) {
        if (-not [string]::IsNullOrEmpty($out)) { Write-FmRaw $out }
        if (-not [string]::IsNullOrEmpty($err)) { Write-FmErr ($err.TrimEnd("`n")) }
        Write-FmErr 'checkpoint: watcher is already running outside this foreground checkpoint'
        Exit-FmScript -Code 1
    }

    if ($rc -eq 124) {
        Write-FmOut "checkpoint: no actionable wake within ${secondsArg}s"
        Exit-FmScript -Code 124
    }

    if (-not [string]::IsNullOrEmpty($out)) { Write-FmRaw $out }
    if (-not [string]::IsNullOrEmpty($err)) { Write-FmErr ($err.TrimEnd("`n")) }
    Exit-FmScript -Code $rc
}
