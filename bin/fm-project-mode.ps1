#requires -Version 7.0
<#
.SYNOPSIS
    Resolve a project's REGISTERED delivery posture from data/projects.md.

.DESCRIPTION
    Prints two words to stdout: "<mode> <yolo>", byte-identical to
    bin/fm-project-mode.sh, so a mechanical consumer reads the same answer on
    either platform.

    MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain
    register for this project", never "how does this task ship".

.PARAMETER Name
    The registered project name.

.PARAMETER Raw
    Print the registered annotation unmapped, so a caller that must tell a
    conditional policy apart from a flat mode sees "no-mistakes-prod-only".
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Name,
    [switch]$Raw
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

# The bash original warns on stderr with a bare "warn: " prefix. Keep that shape
# rather than PowerShell's WARNING banner, because these lines are read by the
# same eyes and greps on both platforms.
$posture = Get-FmProjectMode -Name $Name -Raw:$Raw -WarningVariable warnings -WarningAction SilentlyContinue
foreach ($warning in $warnings) { [Console]::Error.WriteLine("warn: $($warning.Message)") }

[Console]::Out.Write("$($posture.Mode) $($posture.Yolo)`n")
exit 0
