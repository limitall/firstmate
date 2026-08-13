#requires -Version 7.0
<#
    Firstmate module loader.

    Dot-sources every Private/*.ps1 (internals) and Public/*.ps1 (exported verbs)
    into module scope, then exports:

      1. the foundation surface listed in $script:FmFoundationExports below, and
      2. every top-level function defined in a Public/*.ps1 file, discovered by
         parsing each file rather than by a hand-maintained list.

    (2) is deliberate: several areas add Public files independently, and a
    hand-maintained export list in this file or in the manifest would be a
    permanent merge conflict. Add a Public/*.ps1 file and its functions are
    exported; nothing here or in the manifest needs to change.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FmModuleRoot = $PSScriptRoot

# The foundation lives in Private/ (it is module internals shared by every other
# area) but part of it is the module's own public contract: entry points under
# bin/ and this module's tests call it directly. Listed explicitly so the
# foundation's export surface is a decision, not an accident.
$script:FmFoundationExports = @(
    # FmPaths
    'Resolve-FmFullPath'
    'Get-FmRoot'
    'Get-FmHome'
    'Get-FmStateRoot'
    'Get-FmDataRoot'
    'Get-FmConfigRoot'
    'Get-FmProjectsRoot'
    'Get-FmPath'
    'Get-FmStatePath'
    'Get-FmDataPath'
    'Get-FmBacklogPath'
    'Get-FmBacklogLegacyPath'
    'Get-FmConfigPath'
    'Get-FmProjectPath'
    'Get-FmTaskStatePath'
    'Test-FmTaskId'
    'Get-FmHomeLayout'
    'Initialize-FmHome'
    # FmIdentity
    'Get-FmProcessIdentity'
    'Test-FmProcessAlive'
    'Get-FmParentProcessId'
    'Get-FmProcessAncestry'
    'Get-FmProcessCommandLine'
    'Test-FmHarnessProcess'
    'Test-FmHarnessPidAlive'
    'Get-FmHarnessAncestry'
    'Get-FmHarnessAncestryPid'
    # FmState
    'Invoke-FmFileRetry'
    'Read-FmStateFile'
    'Read-FmStateLines'
    'Write-FmStateFile'
    'Write-FmStateLines'
    'Add-FmStateLine'
    'Remove-FmStateFile'
    'Get-FmPathMtime'
    'Get-FmPathAge'
    'Read-FmKeyValueFile'
    'Write-FmKeyValueFile'
    'Set-FmKeyValueField'
    # FmLock
    'Request-FmLock'
    'Wait-FmLock'
    'Unlock-FmLock'
    'Get-FmLockInfo'
    'Get-FmLastLockHolder'
    'Invoke-FmWithLock'
    'Get-FmHeldLock'
    'Get-FmMetaLockPath'
    'Get-FmTaskSetLockPath'
    'Get-FmSessionLockPath'
    'Request-FmSessionLock'
    'Unlock-FmSessionLock'
    'Get-FmSessionLockStatus'
    'Test-FmSessionLockOwnedBySelf'
)

function Get-FmModuleScriptFile {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -Filter '*.ps1' -File | Sort-Object -Property Name)
}

$script:FmPrivateFiles = Get-FmModuleScriptFile -Directory (Join-Path $PSScriptRoot 'Private')
$script:FmPublicFiles = Get-FmModuleScriptFile -Directory (Join-Path $PSScriptRoot 'Public')

# A `foreach` statement, not ForEach-Object: dot-sourcing inside a pipeline
# script block would land the definitions in that block's scope, not module scope.
foreach ($file in $script:FmPrivateFiles) { . $file.FullName }
foreach ($file in $script:FmPublicFiles) { . $file.FullName }

$script:FmPublicFunctionNames = [System.Collections.Generic.List[string]]::new()
foreach ($file in $script:FmPublicFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    foreach ($fn in $ast.FindAll($predicate, $false)) {
        $script:FmPublicFunctionNames.Add($fn.Name)
    }
}

$script:FmExportedFunctions = @($script:FmFoundationExports + $script:FmPublicFunctionNames) |
    Sort-Object -Unique

Export-ModuleMember -Function $script:FmExportedFunctions
