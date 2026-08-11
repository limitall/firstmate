#requires -Version 7.0
# Shared loader for the bin/ entry points of the session-start, bootstrap, hook,
# and project areas.
#
# The module manifest and loader are owned by the foundation area. This falls
# back to dot-sourcing the module's own files when the manifest is absent or does
# not export what the caller needs, so an entry point stays runnable in a partial
# module build - which is exactly the state a single area is developed in.
#
# Dot-source this from an entry point: . (Join-Path $PSScriptRoot 'fm-module-load.ps1')

$fmRepoRoot = Split-Path -Parent $PSScriptRoot
$fmModuleDir = Join-Path $fmRepoRoot 'module' 'Firstmate'
$fmManifest = Join-Path $fmModuleDir 'Firstmate.psd1'

if (Test-Path -LiteralPath $fmManifest -PathType Leaf) {
    try { Import-Module -Name $fmManifest -Force -ErrorAction Stop } catch { }
}

if (-not (Get-Command -Name 'Invoke-FmSessionStart' -ErrorAction SilentlyContinue)) {
    foreach ($fmSubdir in @('Private', 'Public')) {
        $fmDir = Join-Path $fmModuleDir $fmSubdir
        if (-not (Test-Path -LiteralPath $fmDir -PathType Container)) { continue }
        foreach ($fmFile in (Get-ChildItem -LiteralPath $fmDir -Filter '*.ps1' -File | Sort-Object Name)) {
            . $fmFile.FullName
        }
    }
}
