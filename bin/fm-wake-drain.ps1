#requires -Version 7.0
<#
    .SYNOPSIS
    Present durable watcher wake records, optionally acknowledge handled ones,
    annotate validated signal status keys, then assert supervision liveness.

    .DESCRIPTION
    Thin entry point for Invoke-FmWakeDrain. Native Windows PowerShell port of
    bin/fm-wake-drain.sh; the record format it reads and writes is byte-identical.

    .EXAMPLE
    pwsh bin/fm-wake-drain.ps1
    Present the queue. Records stay durable until acknowledged.

    .EXAMPLE
    pwsh bin/fm-wake-drain.ps1 -AckThrough 42 -RecoveryGeneration 1234.5678.ab12
    Consume records through sequence 42, bound to that recovery generation.
#>
[CmdletBinding()]
param(
    [AllowEmptyString()][string]$AckThrough,
    [AllowEmptyString()][string]$RecoveryGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path $PSScriptRoot '..' 'module' 'Firstmate'
foreach ($area in @('Private', 'Public')) {
    foreach ($file in (Get-ChildItem -Path (Join-Path $moduleRoot $area) -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        . $file.FullName
    }
}

$splat = @{}
if ($PSBoundParameters.ContainsKey('AckThrough')) { $splat['AckThrough'] = $AckThrough }
if ($PSBoundParameters.ContainsKey('RecoveryGeneration')) { $splat['RecoveryGeneration'] = $RecoveryGeneration }

exit (Invoke-FmWakeDrain @splat)
