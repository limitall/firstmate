# Push declared inherited local material to live secondmate homes.
# Usage: fm-config-push.ps1 [--help]
#
# Twin: bin/fm-config-push.sh
#
# Mid-session convergence for inherited local material such as
# config/crew-dispatch.json, config/backend, or data/captain-shared.md updates.
# This discovers live secondmate homes from state/*.meta, backfills
# home= from data/secondmates.md for older meta records, and reuses the same
# propagation machinery as bootstrap, but deliberately does not
# fast-forward tracked files.
# After a successful per-home propagation that changes any allowlisted config/*
# item, writes a generation-specific literal-content reread instruction and
# sends its pointer to that live secondmate via fm-config-inherit-lib.psm1
# (Send-FmConfigRereadNudge).
# Unchanged config and data/captain-shared.md-only updates send no reread
# message unless a previous send failure is pending for that home.
# Warnings-only skips exit 0; real propagation or reread-send errors exit non-zero.
#
# ---------------------------------------------------------------------------
# THE ONE MECHANIC THAT NEEDED A WINDOWS ANSWER: CAPTURING THE NUDGE
# ---------------------------------------------------------------------------
# The bash captures the reread nudge with `reread_out=$(... 2>&1)` and then
# prints it AFTER its own "config-reread: sent" line, so the ordering of the
# per-home report is stable no matter how chatty the nudge is. That capture is
# free in bash (a subshell) and impossible the same way here: Write-FmOut goes
# to [Console]::Out DIRECTLY, precisely so no PowerShell formatting can touch
# the bytes, which also means no `$(...)`-style capture exists for it.
#
# So the capture is done at the console itself: Console.SetOut/SetError are
# pointed at one StringWriter for the duration of the call and restored in a
# finally. ONE writer for both, not two, because the bash `2>&1` interleaves
# them into a single stream and a caller reading the report sees them in the
# order they were written.
#
# Its one real limit is worth naming: a CHILD PROCESS the nudge starts writes
# to the process's own stdout handle, which SetOut does not redirect, so such
# output would appear before the captured block rather than inside it. The
# nudge's own child invocations go through Invoke-FmScript, which captures
# them, so this does not arise in practice - but it is why the redirect is
# scoped as tightly as possible rather than left installed.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-wake-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-config-inherit-lib.psm1') -Force

$fmArgv = @($args)
$fmScriptRoot = $PSScriptRoot

Invoke-FmMain -UnexpectedCode 70 {

    # The `usage()` heredoc, byte-identical and on STDOUT as the bash writes it.
    # The text still names bin/fm-config-push.sh: CLI surfaces are identical
    # during the transition (docs/powershell-port.md contract 4).
    $usage = @'
Usage: fm-config-push.sh [--help]

Push the primary firstmate home's declared inherited local material into each
live secondmate home.

This is local-material-only:
  - does not fast-forward tracked files
  - after successful config/* changes, sends a local literal-content pointer or
    one durable marked remote reread nudge
    (no message when config is unchanged unless a previous send failure is pending)
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero for real propagation errors or reread-send failures

Live homes come from state/*.meta records with kind=secondmate.
data/secondmates.md is only a fallback for missing home= fields in older or
incomplete meta records.

Environment overrides follow the rest of firstmate:
  FM_HOME            active firstmate home
  FM_ROOT_OVERRIDE  firstmate repo root
  FM_STATE_OVERRIDE state dir
  FM_DATA_OVERRIDE  data dir
  FM_CONFIG_OVERRIDE config dir
'@

    $first = if ($fmArgv.Count -gt 0) { [string]$fmArgv[0] } else { '' }
    if ($first -ceq '-h' -or $first -ceq '--help') {
        # Write-FmOut, not Write-FmRaw: `cat <<EOF` terminates its last line.
        Write-FmOut $usage
        Exit-FmScript 0
    } elseif ($first -ne '') {
        Write-FmErr 'usage: fm-config-push.sh [--help]'
        Exit-FmScript 2
    }

    $ctx = Get-FmContext $fmScriptRoot
    $secondmatesMd = Join-Path $ctx.Data 'secondmates.md'

    # `"$SCRIPT_DIR/fm-guard.sh" || true`: an advisory guard that never blocks.
    # -Stream because its banner belongs to the operator, not to this script.
    $null = Invoke-FmScript -Name 'fm-guard' -BinDir $fmScriptRoot -Stream

    # `print_item_report`: one line per TSV outcome recorded by the propagation.
    # The bash reads with IFS=$'\t', which - because TAB is IFS WHITESPACE -
    # strips leading and trailing tabs from the remainder field, so a result
    # written with an empty reason reads as an empty reason and not as a
    # trailing tab. The Trim below is that behavior, not a tidy-up.
    $printItemReport = {
        param([string]$ReportPath)
        foreach ($line in (Get-FmFileLines $ReportPath)) {
            # Split with a limit of 3 so a reason containing a TAB stays whole,
            # exactly as `read -r item status reason` gives the remainder to the
            # last variable.
            $fields = @($line.Split("`t", 3))
            $item = $fields[0]
            if ($item -eq '') { continue }
            $status = if ($fields.Length -gt 1) { $fields[1] } else { '' }
            $reason = if ($fields.Length -gt 2) { $fields[2].Trim("`t") } else { '' }
            if ($reason -ne '') {
                Write-FmOut "  ${item}: $status - $reason"
            } else {
                Write-FmOut "  ${item}: $status"
            }
        }
    }

    # Run a scriptblock with both console streams captured into one buffer, the
    # `out=$(cmd 2>&1)` twin. See this file's header for why it is done here.
    $captureConsole = {
        param([scriptblock]$Body)
        $writer = [System.IO.StringWriter]::new()
        $savedOut = [Console]::Out
        $savedErr = [Console]::Error
        $ok = $false
        try {
            [Console]::SetOut($writer)
            [Console]::SetError($writer)
            $ok = [bool](& $Body)
        } finally {
            [Console]::SetOut($savedOut)
            [Console]::SetError($savedErr)
        }
        # `$(...)` strips trailing newlines and nothing else.
        return [pscustomobject]@{ Ok = $ok; Text = $writer.ToString().TrimEnd("`n") }
    }

    $records = @(Get-FmFfLiveSecondmateMetaRecord -StateDir $ctx.State -Registry $secondmatesMd)
    if ($records.Count -eq 0) {
        Write-FmOut 'config-push: no live secondmate homes found'
        Exit-FmScript 0
    }

    Write-FmOut "config-push: $($ctx.Home) -> live secondmate homes"

    # The `trap cleanup EXIT` twin: every per-home report file is removed on the
    # way out, including the failure paths, so a run that refuses part-way
    # through leaves no temporaries behind.
    $reportFiles = [System.Collections.Generic.List[string]]::new()
    $seenHomes = [System.Collections.Generic.List[string]]::new()
    $errors = 0

    try {
        foreach ($record in $records) {
            $id = $record.Id
            if ([string]::IsNullOrEmpty($id)) { continue }
            $homeValue = $record.Home
            if ([string]::IsNullOrEmpty($homeValue)) {
                Write-FmOut "secondmate ${id}: skipped - no home= in $($record.Meta) and no registry home"
                continue
            }

            $validation = Resolve-FmFfSecondmateHome -Id $id -HomePath $homeValue `
                -ActiveHome $ctx.Home -RepoRoot $ctx.Root
            if (-not $validation.Ok) {
                Write-FmOut "secondmate $id (${homeValue}): skipped - unsafe home: $($validation.Error)"
                continue
            }
            $homeReal = $validation.ValidatedHome

            # Ordinal Contains, not -contains: the latter is case-INSENSITIVE
            # for strings and would collapse two genuinely distinct homes.
            if ($seenHomes.Contains($homeReal)) {
                Write-FmOut "secondmate $id (${homeReal}): skipped - already processed for another live meta"
                continue
            }
            $seenHomes.Add($homeReal)

            Write-FmOut "secondmate $id (${homeReal}):"
            if ((Get-FmFfDirtyStatus -Directory $homeReal -IgnoreSeedMarker) -ne '') {
                Write-FmOut '  home: dirty working tree - local-material push continuing'
            }

            $stateDir = Join-Path $homeReal 'state'
            $madeState = $true
            try { [void][System.IO.Directory]::CreateDirectory($stateDir) } catch { $madeState = $false }
            if (-not $madeState) {
                Write-FmOut '  config-reread: error - could not create state directory'
                $errors = 1
                continue
            }

            $homeLock = Get-FmConfigInheritLockPath -DestinationHome $homeReal
            if ([string]::IsNullOrEmpty($homeLock)) {
                Write-FmOut '  config-reread: error - could not resolve per-home lock'
                $errors = 1
                continue
            }
            Wait-FmLock -LockPath $homeLock

            # Everything from here to the release runs under the per-home lock,
            # so the release is in a finally: leaving a lock behind would stall
            # every later convergence for that home. A `continue` from any arm
            # below still runs that finally, which is exactly what the bash's
            # explicit `fm_lock_release` before each `continue` achieves.
            try {
                if (Test-FmConfigRereadRetryQueueFull -SourceHome $ctx.Home -Id $id) {
                    [void](Invoke-FmConfigRereadRetryPending -Id $id -DestinationHome $homeReal -BinDir $fmScriptRoot)
                    if (Test-FmConfigRereadRetryQueueFull -SourceHome $ctx.Home -Id $id) {
                        Write-FmOut '  config-reread: error - retry instruction queue is full'
                        $errors = 1
                        continue
                    }
                }

                $report = New-FmInheritTempFile -Directory ([System.IO.Path]::GetTempPath()) `
                    -Prefix 'fm-config-push-report.'
                if ($null -eq $report) {
                    Write-FmOut '  home: error - could not create report file'
                    $errors = 1
                    continue
                }
                $reportFiles.Add($report)

                $savedReport = [Environment]::GetEnvironmentVariable('FM_CONFIG_INHERIT_REPORT')
                try {
                    $env:FM_CONFIG_INHERIT_REPORT = $report
                    if (-not (Sync-FmSecondmateInheritance -SourceHome $ctx.Home -DestinationHome $homeReal `
                                -SourceConfig $ctx.Config -SourceData $ctx.Data)) {
                        $errors = 1
                    }
                } finally {
                    if ($null -eq $savedReport) {
                        Remove-Item -LiteralPath 'Env:FM_CONFIG_INHERIT_REPORT' -ErrorAction SilentlyContinue
                    } else {
                        $env:FM_CONFIG_INHERIT_REPORT = $savedReport
                    }
                }

                & $printItemReport $report

                $rereadPending = (Test-FmConfigRereadPending -DestinationHome $homeReal) -or
                    (Test-FmConfigRereadStaged -SourceHome $ctx.Home -Id $id)

                # The bash sets FM_HOME/FM_ROOT_OVERRIDE/FM_STATE_OVERRIDE for
                # the nudge call so the nudge resolves the SOURCE home the same
                # way this script did, even when this script was reached through
                # a different override spelling. Same intent here.
                $savedEnv = @{}
                foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE')) {
                    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
                }
                $nudge = $null
                try {
                    $env:FM_HOME = $ctx.Home
                    $env:FM_ROOT_OVERRIDE = $ctx.Root
                    $env:FM_STATE_OVERRIDE = $ctx.State
                    $nudge = & $captureConsole {
                        Send-FmConfigRereadNudge -Id $id -DestinationHome $homeReal `
                            -Report $report -BinDir $fmScriptRoot
                    }
                } finally {
                    foreach ($name in @('FM_HOME', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE')) {
                        if ($null -eq $savedEnv[$name]) {
                            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
                        } else {
                            [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
                        }
                    }
                }

                if ($nudge.Ok) {
                    $changed = Measure-FmInheritItem (Get-FmConfigRereadChangedItem -Report $report)
                    if ($changed -gt 0 -or $rereadPending) {
                        Write-FmOut '  config-reread: sent'
                    }
                    if ($nudge.Text -ne '') { Write-FmOut $nudge.Text }
                } else {
                    $errors = 1
                    if ($nudge.Text -ne '') {
                        Write-FmOut $nudge.Text
                    } else {
                        Write-FmOut '  config-reread: send failed'
                    }
                }
            } finally {
                Unlock-FmLock -LockPath $homeLock
            }
        }
    } finally {
        foreach ($reportFile in $reportFiles) {
            [void](Remove-FmInheritPath -Path $reportFile)
        }
    }

    if ($errors -ne 0) { Exit-FmScript 1 }
    Exit-FmScript 0
}
