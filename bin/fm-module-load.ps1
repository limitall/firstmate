#requires -Version 7.0
# The prelude EVERY bin/ entry point dot-sources, and the only place that knows
# how to make a bare shell usable.
#
#     . (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'New-FmBrief'
#
# It does three things, in this order, because each one depends on the last:
#
#   1. Puts this checkout's module/ on PSModulePath for THIS process. A module
#      cannot fix PSModulePath from inside itself - it has to be importable
#      first - so this is the one rule that genuinely cannot live in the module.
#   2. Imports the module, with a dot-source fallback for a partial build, which
#      is exactly the state a single area is developed in.
#   3. Publishes the resolved home into $env:FM_HOME for this process and every
#      child it spawns.
#
# WHY (3) IS A PUBLICATION AND NOT A LOOKUP. Nine functions across seven areas
# read $env:FM_HOME directly (Get-FmPane, Send-FmText, Start-FmWorker,
# Stop-FmWorker, Invoke-FmTeardown, the session-start paths, the lifecycle
# paths, the herdr backend, the install default). Teaching each of them the new
# precedence would be seven cross-area edits that the next area to land would
# have to remember too. Resolving once here and exporting the answer fixes all
# of them, and fixes the herdr pane firstmate dispatches a worker into, which
# inherits the environment of the process that launched it.
#
# WHAT IT DELIBERATELY DOES NOT DO: it does not put bin/ on PATH. Nothing in
# this port invokes an entry point by bare name, and adding it would make
# fm-doctor's PATH check pass in its own process while the captain's interactive
# shell still could not type `fm-doctor.ps1`. That check is about the captain's
# shell, and it has to keep telling the truth about it.
#
# -RequiredCommand is the command that entry point cannot run without, so the
# dot-source fallback triggers on ITS command rather than on a sentinel from
# another area. It used to be a $fmRequiredCommand variable the prelude read back
# out of the caller's scope, which needed an analyzer suppression in every entry
# point to explain the assignment nothing appeared to read.
param(
    [string]$RequiredCommand = 'Invoke-FmSessionStart'
)

$fmRepoRoot = Split-Path -Parent $PSScriptRoot
$fmModuleDir = Join-Path $fmRepoRoot 'module'
$fmManifest = Join-Path $fmModuleDir 'Firstmate' 'Firstmate.psd1'

# 1. Import-Module by absolute path would load the module, but `Import-Module
#    Firstmate` from a hook, a nested script or a child process would not.
#    Prepending is per-process and inherited, so both spellings resolve from
#    here on.
$fmPathSeparator = [System.IO.Path]::PathSeparator
if (($env:PSModulePath -split $fmPathSeparator) -notcontains $fmModuleDir) {
    $env:PSModulePath = $fmModuleDir + $fmPathSeparator + $env:PSModulePath
}

# 2. The manifest is the real load path. The dot-source below is the fallback.
if (Test-Path -LiteralPath $fmManifest -PathType Leaf) {
    try {
        Import-Module -Name $fmManifest -Force -ErrorAction Stop
    } catch {
        # A partial module build is exactly the state one area is developed in;
        # the dot-source fallback below covers it.
        Write-Debug "Firstmate manifest import failed: $($_.Exception.Message)"
    }
}

if (-not (Get-Command -Name $RequiredCommand -ErrorAction SilentlyContinue)) {
    foreach ($fmSubdir in @('Private', 'Public')) {
        $fmDir = Join-Path $fmModuleDir 'Firstmate' $fmSubdir
        if (-not (Test-Path -LiteralPath $fmDir -PathType Container)) { continue }
        foreach ($fmFile in (Get-ChildItem -LiteralPath $fmDir -Filter '*.ps1' -File | Sort-Object Name)) {
            . $fmFile.FullName
        }
    }
}

# 3. Initialize-FmEntryPointHome is the owner of the precedence AND of the
#    decision not to publish a guess; if the area that defines it is not loaded,
#    leave the environment exactly as it was rather than resolving a home here -
#    a wrong home is worse than an unset one, and fm-doctor reports the unset
#    case by name.
if (Get-Command -Name 'Initialize-FmEntryPointHome' -ErrorAction SilentlyContinue) {
    try {
        $null = Initialize-FmEntryPointHome -RepoRoot $fmRepoRoot -Confirm:$false
    } catch {
        Write-Debug "firstmate home resolution failed: $($_.Exception.Message)"
    }
}
