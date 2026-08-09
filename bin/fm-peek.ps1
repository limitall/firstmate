# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.ps1 <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
#
# Twin: bin/fm-peek.sh
#
# ---------------------------------------------------------------------------
# THREE MECHANICS WORTH KNOWING BEFORE EDITING
#
#   PATHS STAY IN THE SPELLING THEY ARRIVED IN. FM_HOME and FM_STATE_OVERRIDE
#   reach this script in whatever form the caller used (MSYS /f/... from a bash
#   twin, F:\... from a PowerShell one), and every diagnostic the backend
#   resolver prints embeds that string. So STATE is composed with plain string
#   concatenation, exactly as the bash `"$FM_HOME/state"` does, and the
#   POSIX->native conversion happens only where a .NET API needs it - which for
#   this script is entirely inside fm-common/fm-backend. Rewriting the path here
#   would make the same failure read differently depending on which twin ran.
#
#   THE GUARD RUNS BEFORE THE ARGUMENT CHECK, and its streams belong to the
#   user. The bash twin invokes fm-guard.sh directly, so its banner reaches the
#   terminal unbuffered and BEFORE any resolution diagnostic; -Stream reproduces
#   that (the child inherits the console) rather than capturing and replaying,
#   which would reorder the two.
#
#   A FAILED CAPTURE IS AN EXIT CODE, NOT AN EMPTY STRING. The backend capture
#   contract is "text, or $null when the backend failed"; the bash twin's exit
#   status is whatever the capture command returned, so $null must become a
#   non-zero exit here or a dead endpoint would look like an empty pane.
#
# ---------------------------------------------------------------------------
# DOCUMENTED DIVERGENCE
#
#   With no argument at all the bash twin dies inside `RAW_TARGET=$1` under
#   `set -u`, printing bash's own "unbound variable" message and exiting 1. A
#   PowerShell script has no equivalent failure to reproduce byte for byte, so
#   the twin prints a usage line and keeps the exit code. The differential suite
#   compares the code and stdout for that case, not the stderr text.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'fm-common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fm-backend.psm1') -Force

# No param() block, and $args captured here: see bin/fm-operational-input.ps1
# for both reasons (a bare `-h`-shaped argument must not be bound as a
# parameter, and $args inside the Invoke-FmMain block would be the BLOCK's own
# empty argument array).
$fmArgv = @($args)

Invoke-FmMain -UnexpectedCode 70 {
    # The bash resolution block, verbatim in string terms:
    #   FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    #   FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
    #   STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
    $rootOverride = Get-FmEnv 'FM_ROOT_OVERRIDE'
    $fmRoot = if ($rootOverride) {
        $rootOverride
    } else {
        ConvertTo-FmPosixPath ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
    }
    $homeEnv = Get-FmEnv 'FM_HOME'
    $fmHome = if ($homeEnv) { $homeEnv } elseif ($rootOverride) { $rootOverride } else { $fmRoot }
    $state = Get-FmEnv 'FM_STATE_OVERRIDE' "$fmHome/state"

    # `"$SCRIPT_DIR/fm-guard.sh" || true`: the guard warns, it never blocks.
    $null = Invoke-FmScript 'fm-guard' -Stream

    if ($fmArgv.Count -lt 1) {
        Write-FmErr 'usage: fm-peek.sh <target> [lines=40]'
        Exit-FmScript 1
    }
    $raw = [string]$fmArgv[0]

    # The resolver prints its own refusal; a $null answer is its `return 1`,
    # which under the bash twin's `set -e` ends the script at the assignment.
    $target = Resolve-FmBackendSelector -Raw $raw -StateDir $state
    if ([string]::IsNullOrEmpty($target)) { Exit-FmScript 1 }

    # `${2:-40}`: empty counts as absent.
    $lines = '40'
    if ($fmArgv.Count -ge 2 -and -not [string]::IsNullOrEmpty([string]$fmArgv[1])) {
        $lines = [string]$fmArgv[1]
    }

    $backend = Get-FmBackendOfSelector -Raw $raw -Resolved $target -StateDir $state
    $expectedLabel = Get-FmBackendExpectedLabelOfSelector -Raw $raw -StateDir $state

    $capture = Get-FmBackendCapture -Backend $backend -Target $target -Lines $lines `
        -ExpectedLabel $expectedLabel
    if ($null -eq $capture) { Exit-FmScript 1 }
    # Raw: the capture already carries the backend's own trailing newline, and
    # adding one would change the byte count of every peek.
    Write-FmRaw $capture
    Exit-FmScript 0
}
