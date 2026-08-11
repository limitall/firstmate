#requires -Version 7.0
<#
.SYNOPSIS
fm-send.ps1 - send one line of literal text to a worker endpoint and submit it,
or send one named key.

.DESCRIPTION
Thin entry point over Send-FmText. Text submission is verified: the line is
typed once, then Enter is retried until the backend confirms a submit. If
delivery cannot be confirmed this script exits NON-ZERO, so a caller knows the
steer did not land instead of silently leaving an unsubmitted instruction.

FM_HOME must be explicit (-FirstmateHome or the environment variable), so a
steer cannot silently resolve against another home.

Exit codes: 0 delivered, 1 refusal or unconfirmed delivery, 2 usage.

.EXAMPLE
./bin/fm-send.ps1 my-task push the branch and open the PR

.EXAMPLE
./bin/fm-send.ps1 my-task -Key Escape
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)][string]$Target,
    [string]$Key = '',
    [string]$FirstmateHome = '',
    [int]$Retries = 3,
    [double]$SleepSeconds = 0.4,
    [Parameter(ValueFromRemainingArguments)][string[]]$Message = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module resolution. The manifest is the real entry point; the dot-source
# fallback exists so these scripts run before the module loader lands and is
# harmless once it has.
$fmManifest = Join-Path $PSScriptRoot '../module/Firstmate/Firstmate.psd1'
if (Test-Path -LiteralPath $fmManifest) {
    Import-Module $fmManifest -Force
} else {
    $fmModule = Join-Path $PSScriptRoot '../module/Firstmate'
    foreach ($fmFile in @(Get-ChildItem -Path (Join-Path $fmModule 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -Path (Join-Path $fmModule 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        . $fmFile.FullName
    }
}

$text = ($Message -join ' ').Trim()

if ($Key -and $text) {
    Write-Error 'error: pass either -Key or a message, not both'
    exit 2
}
if (-not $Key -and -not $text) {
    Write-Error 'usage: fm-send.ps1 <target> <message...> | fm-send.ps1 <target> -Key <key>'
    exit 2
}

try {
    if ($Key) {
        $null = Send-FmText -Target $Target -Key $Key -FirstmateHome $FirstmateHome
    } else {
        $null = Send-FmText -Target $Target -Text $text -FirstmateHome $FirstmateHome `
            -Retries $Retries -SleepSeconds $SleepSeconds
    }
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
