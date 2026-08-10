# fm-supervision-instructions.ps1 - render the primary-harness supervision
# operating block for session start, and the short repair line used by guards
# and turn-end hooks.
#
# Twin: bin/fm-supervision-instructions.sh
#
# ---------------------------------------------------------------------------
# WHAT IS ACTUALLY BEING PROTECTED HERE
#
# The block this prints is the ONLY place a session learns how to keep exactly
# one live supervision cycle for its harness (AGENTS.md section 8), and the
# repair line is what a guard hands an agent whose cycle has lapsed. Both are
# read by an agent, not by a parser, but they are still an interface: the
# harness-specific recipes name concrete scripts and flags, and a wrong recipe
# for the running harness produces either a second watcher or none. So the
# snippet files under docs/supervision-protocols/ are rendered VERBATIM apart
# from the four documented placeholders, and the harness->snippet mapping,
# including pi-signed's alias onto pi.md and the unknown fallback, is preserved
# exactly.
#
# Exit codes are part of the interface too: 2 for every usage error, 0 for
# --help and for a successful render. The bash twin runs under `set -eu`, so a
# missing argument value exits 2 with a specific message rather than rendering
# a half-configured block; each of those messages is reproduced byte-for-byte.
#
# PRINTED PATHS ARE POSIX (docs/powershell-port.md contract 3). The bash twin
# derives FM_ROOT with `cd .. && pwd`, which under Git Bash yields /f/... - and
# these lines are copied by an agent into commands that may run in either
# world. So every path this SCRIPT PRINTS is converted back to MSYS form, while
# every path it READS stays native for the .NET APIs. The two directions are
# deliberately separate variables below rather than one that has to be
# remembered.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1')

$fmArgv = @($args)

function Show-FmSupervisionUsage {
    param([switch]$ToStdErr)
    # The bash twin's usage heredoc, line for line. Written as an array rather
    # than a here-string so the closing delimiter cannot be accidentally
    # indented, which is a silent parse failure in PowerShell.
    $text = @(
        'Usage: fm-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]'
        ''
        "Print the current primary harness's supervision operating instructions."
        'With --repair-line, print one concise repair instruction for guard and hook messages.'
    )
    foreach ($line in $text) {
        if ($ToStdErr) { Write-FmErr $line } else { Write-FmOut $line }
    }
}

# `bool_value`: only the listed spellings are true; everything else, including
# an empty value, is 0.
function Get-FmSupervisionBool {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    switch -CaseSensitive ($Value) {
        '1' { return 1 }
        'true' { return 1 }
        'TRUE' { return 1 }
        'yes' { return 1 }
        'YES' { return 1 }
        default { return 0 }
    }
}

# The `shell_quote` twin: single-quote the whole string and rewrite each embedded
# quote as '\'' so the result can be pasted into a shell command unchanged.
function ConvertTo-FmSupervisionShellQuoted {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return "'" + $Value.Replace("'", "'\''") + "'"
}

Invoke-FmMain -UnexpectedCode 70 {
    $ctx = Get-FmContext $PSScriptRoot

    # REPO_ROOT is where the DOCS live and is always script-derived; FM_ROOT is
    # the override-aware root the printed instructions refer to. The bash twin
    # keeps them separate for the same reason and they are not interchangeable.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $ctx.ScriptRoot '..'))
    $docDir = Join-Path $repoRoot 'docs/supervision-protocols'

    $harness = ''
    $readOnly = 0
    $afk = 0
    $xMode = 0
    $repairLineOnly = 0
    $queuePending = 0

    $i = 0
    while ($i -lt $fmArgv.Count) {
        $arg = [string]$fmArgv[$i]
        switch -CaseSensitive ($arg) {
            '--harness' {
                if ($i + 1 -ge $fmArgv.Count) {
                    Write-FmErr 'error: --harness requires a value'
                    Exit-FmScript 2
                }
                $harness = [string]$fmArgv[$i + 1]
                $i += 2
            }
            '--read-only' {
                if ($i + 1 -ge $fmArgv.Count) {
                    Write-FmErr 'error: --read-only requires 0 or 1'
                    Exit-FmScript 2
                }
                $readOnly = Get-FmSupervisionBool ([string]$fmArgv[$i + 1])
                $i += 2
            }
            '--afk' {
                if ($i + 1 -ge $fmArgv.Count) {
                    Write-FmErr 'error: --afk requires 0 or 1'
                    Exit-FmScript 2
                }
                $afk = Get-FmSupervisionBool ([string]$fmArgv[$i + 1])
                $i += 2
            }
            '--x-mode' {
                if ($i + 1 -ge $fmArgv.Count) {
                    Write-FmErr 'error: --x-mode requires 0 or 1'
                    Exit-FmScript 2
                }
                $xMode = Get-FmSupervisionBool ([string]$fmArgv[$i + 1])
                $i += 2
            }
            '--queue-pending' {
                if ($i + 1 -ge $fmArgv.Count) {
                    Write-FmErr 'error: --queue-pending requires 0 or 1'
                    Exit-FmScript 2
                }
                $queuePending = Get-FmSupervisionBool ([string]$fmArgv[$i + 1])
                $i += 2
            }
            '--repair-line' {
                $repairLineOnly = 1
                $i += 1
            }
            '-h' { Show-FmSupervisionUsage; Exit-FmScript 0 }
            '--help' { Show-FmSupervisionUsage; Exit-FmScript 0 }
            default {
                Write-FmErr "error: unknown argument: $arg"
                Show-FmSupervisionUsage -ToStdErr
                Exit-FmScript 2
            }
        }
    }

    if ([string]::IsNullOrEmpty($harness)) {
        # `$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)`; command
        # substitution strips the trailing newline.
        $probe = Invoke-FmScript -Name 'fm-harness' -BinDir $ctx.ScriptRoot
        if ($probe.Ok) {
            $harness = $probe.StdOut.TrimEnd("`n")
        } else {
            $harness = 'unknown'
        }
        if ([string]::IsNullOrEmpty($harness)) { $harness = 'unknown' }
    }

    $snippet = switch -CaseSensitive ($harness) {
        'claude' { Join-Path $docDir 'claude.md' }
        'codex' { Join-Path $docDir 'codex.md' }
        'opencode' { Join-Path $docDir 'opencode.md' }
        'pi' { Join-Path $docDir 'pi.md' }
        'grok' { Join-Path $docDir 'grok.md' }
        'pi-signed' { Join-Path $docDir 'pi.md' }
        default { $harness = 'unknown'; Join-Path $docDir 'unknown.md' }
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FmNativePath $snippet))) {
        $snippet = Join-Path $docDir 'unknown.md'
    }

    $checkpointSeconds = Get-FmEnv 'FM_CODEX_WATCH_CHECKPOINT' '180'
    # Printed forms (POSIX) and read forms (native) are kept apart deliberately.
    $printRoot = ConvertTo-FmPosixPath $ctx.Root
    $piExt = "$printRoot/.pi/extensions/fm-primary-pi-watch.ts"
    $piTurnendExt = "$printRoot/.pi/extensions/fm-primary-turnend-guard.ts"
    $xModeEnv = (ConvertTo-FmPosixPath $ctx.Config) + '/x-mode.env'
    $xModeEnvNative = Join-Path $ctx.Config 'x-mode.env'
    $xModeEnvSh = ConvertTo-FmSupervisionShellQuoted $xModeEnv

    if ($xMode -eq 0 -and [System.IO.File]::Exists((ConvertTo-FmNativePath $xModeEnvNative))) {
        $xMode = 1
    }

    if ($repairLineOnly -eq 1) {
        if ($readOnly -eq 1) {
            Write-FmOut 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
            Exit-FmScript 0
        }
        if ($afk -eq 1) {
            Write-FmOut 'Away mode owns watcher supervision; load /afk and ensure the daemon is running instead of starting normal supervision directly.'
            Exit-FmScript 0
        }
        $prefix = ''
        if ($queuePending -eq 1) { $prefix = 'After draining queued wakes, ' }
        if ($xMode -eq 1) { $prefix = "${prefix}source $xModeEnvSh first, then " }
        switch -CaseSensitive ($harness) {
            'claude' {
                Write-FmOut ($prefix + 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.')
            }
            'codex' {
                Write-FmOut ($prefix + 'repair missing watcher supervision with a foreground checkpoint: bin/fm-watch-checkpoint.sh --seconds ' + $checkpointSeconds + '.')
            }
            { $_ -ceq 'pi' -or $_ -ceq 'pi-signed' } {
                Write-FmOut ($prefix + 'repair a missing or failed watcher cycle with the Pi tool fm_watch_arm_pi, or restart Pi with -e ' + $piTurnendExt + ' -e ' + $piExt + ' if the extensions are not loaded.')
            }
            'opencode' {
                Write-FmOut ($prefix + 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/fm-watch-arm.sh only as a manual recovery probe if the plugin reports failure.')
            }
            'grok' {
                Write-FmOut ($prefix + 'repair missing watcher supervision with bin/fm-watch-arm.sh as its own Grok tracked background task, never shell &.')
            }
            default {
                Write-FmOut ($prefix + 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.')
            }
        }
        Exit-FmScript 0
    }

    $rule = '================================================================================'
    Write-FmOut $rule
    Write-FmOut "SUPERVISION OPERATING INSTRUCTIONS - primary harness: $harness"
    Write-FmOut $rule
    Write-FmOut 'Current state:'
    if ($readOnly -eq 1) {
        Write-FmOut '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
    } else {
        Write-FmOut '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
    }
    if ($afk -eq 1) {
        Write-FmOut '- Away mode: active; load /afk and keep normal harness supervision paused while the daemon owns the watcher.'
    } else {
        Write-FmOut '- Away mode: inactive.'
    }
    if ($xMode -eq 1) {
        Write-FmOut ('- X mode: active; source ' + $xModeEnv + ' before launching any watcher process so the 30s cadence is inherited.')
    } else {
        Write-FmOut '- X mode: inactive; use the default watcher cadence.'
    }

    switch -CaseSensitive ($harness) {
        'claude' {
            Write-FmOut '- Ordinary wake: the Stop-owned auto-arm (bin/fm-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
        }
        'codex' {
            Write-FmOut '- Ordinary wake: take the next foreground bin/fm-watch-checkpoint.sh checkpoint as directed below.'
        }
        { $_ -ceq 'pi' -or $_ -ceq 'pi-signed' } {
            Write-FmOut '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
        }
        'opencode' {
            Write-FmOut '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
        }
        'grok' {
            Write-FmOut '- Ordinary wake: re-arm exactly one bin/fm-watch-arm.sh Grok tracked background task as directed below.'
        }
        default {
            Write-FmOut '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
        }
    }

    Write-FmOut ''

    # render_snippet: the four placeholders, in the bash twin's ORDER. The _SH_
    # form must be substituted before the bare one, or the bare pattern would
    # consume its prefix and leave a stray "_SH__" behind.
    foreach ($line in (Get-FmFileLines $snippet)) {
        $out = $line.Replace('__FM_PI_EXT__', $piExt)
        $out = $out.Replace('__FM_PI_TURNEND_EXT__', $piTurnendExt)
        $out = $out.Replace('__FM_X_MODE_ENV_SH__', $xModeEnvSh)
        $out = $out.Replace('__FM_X_MODE_ENV__', $xModeEnv)
        Write-FmOut $out
    }

    Write-FmOut ''
    Exit-FmScript 0
}
