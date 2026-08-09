# bin/fm-update.ps1 - self-update a running firstmate and its secondmates to the
# latest origin.
#
# Twin: bin/fm-update.sh
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or a
# standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# bin/fm-fleet-sync: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are fetched
# on their own. Secondmate homes are leased at a detached HEAD on the default
# branch, so a fast-forward there advances HEAD only and never touches any other
# worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.psm1 (base mode "origin"
# here); the same library drives the local-HEAD secondmate sync used by fm-spawn
# and fm-bootstrap, so there is one ff implementation, not several. NOTHING in
# this file re-implements a guard, a refusal, or a status line - every one of
# those belongs to the library, which is why a refusal's wording survives the
# conversion untouched.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# pane actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.ps1 [--help]
#
# ---------------------------------------------------------------------------
# THE OUT-GLOBALS BECAME A SWEEP STATE OBJECT
#
# The bash resets FF_NUDGE_WINDOWS and FF_SEEN_HOMES to "" and reads them back
# after the sweep. A module cannot write its caller's variables, so
# New-FmFfSweepState allocates that accumulator and it is threaded through both
# the live-meta sweep and the registry backstop - which is what makes the two
# passes share one seen-homes set, so a secondmate that is BOTH live and
# registered is still processed exactly once.
#
# The final summary reproduces the bash's `${FF_NUDGE_WINDOWS:- none}` exactly:
# the accumulator is a SPACE-PREFIXED list ("$FF_NUDGE_WINDOWS fm-$id"), so a
# populated result prints as "nudge-secondmates: fm-a fm-b" and an empty one
# takes the `:-` default and prints "nudge-secondmates: none". That leading space
# is part of the parsed contract, not an accident of formatting.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-ff-lib.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-secondmate-registry-lib.psm1') -Force

# No param() block - see bin/fm-operational-input.ps1's header for why.
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    $context = Get-FmContext $PSScriptRoot
    $fmRoot = $context.Root
    $fmHome = $context.Home
    $stateDir = $context.State
    $secondmatesMd = Join-Path (Join-Path $fmHome 'data') 'secondmates.md'

    # `"$SCRIPT_DIR/fm-guard.sh" || true`: the guard warns, it never blocks. It
    # runs BEFORE argument handling in the bash twin, so `--help` prints it too.
    $null = Invoke-FmScript -Name 'fm-guard' -BinDir $PSScriptRoot -Stream

    $usage = { Write-FmErr 'usage: fm-update.sh [--help]' }

    if ($fmArgv.Count -ge 1 -and (([string]$fmArgv[0]) -ceq '--help' -or ([string]$fmArgv[0]) -ceq '-h')) {
        & $usage
        Exit-FmScript 0
    }
    if ($fmArgv.Count -ne 0) {
        & $usage
        Exit-FmScript 1
    }

    # --- main firstmate repo ---------------------------------------------------

    $rereadFirstmate = 'no'
    # ff_target "$FM_ROOT" "firstmate" origin no no - not detached-tolerant and
    # not seed-marker-tolerant: the running repo is a normal checkout.
    $ff = Invoke-FmFfTarget -Directory $fmRoot -Label 'firstmate' -BaseMode 'origin'
    if ($ff.Status -ceq 'updated' -and -not [string]::IsNullOrEmpty($ff.Instructions)) {
        $rereadFirstmate = 'yes'
    }

    # --- secondmates -----------------------------------------------------------
    # An updated live secondmate is nudged whenever it advanced (the bash passes
    # nudge_requires_instr "no" here): /updatefirstmate's nudge is a gentle
    # re-read steer, kept on the same condition it has always used.

    $sweep = New-FmFfSweepState

    # Live direct reports first: state/<id>.meta with kind=secondmate carries the
    # authoritative home= path.
    $null = Invoke-FmFfSecondmateSweep -StateDir $stateDir -BaseMode 'origin' `
        -State $sweep -ActiveHome $fmHome -RepoRoot $fmRoot

    # Registry backstop: a secondmate registered in data/secondmates.md but
    # without a live meta (e.g. between restarts) is still its persistent on-disk
    # home.
    if ([System.IO.File]::Exists((ConvertTo-FmNativePath $secondmatesMd))) {
        foreach ($line in (Get-FmFileLines $secondmatesMd)) {
            if (-not $line.StartsWith('- ', [System.StringComparison]::Ordinal)) { continue }
            # $null is the `! secondmate_registry_parse_line` twin: a record that
            # does not match the structured suffix is REPORTED, never guessed at.
            $record = ConvertFrom-FmSecondmateRegistryLine -Line $line
            if ($null -eq $record) {
                Write-FmErr "secondmate registry: skipped malformed entry: $line"
                continue
            }
            $null = Invoke-FmFfSecondmate -Id $record.Id -HomePath $record.Home -Window '' `
                -BaseMode 'origin' -State $sweep -ActiveHome $fmHome -RepoRoot $fmRoot
        }
    }

    # --- caller action summary -------------------------------------------------

    Write-FmOut "reread-firstmate: $rereadFirstmate"
    $nudge = ''
    foreach ($w in $sweep.NudgeWindows) { $nudge += " $w" }
    if ($nudge -eq '') { $nudge = ' none' }
    Write-FmOut "nudge-secondmates:$nudge"
    Exit-FmScript 0
}
