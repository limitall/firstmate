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

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Send-FmText'

$text = ($Message -join ' ').Trim()

# PowerShell does not refuse a switch this script does not declare: the trailing
# remaining-arguments list takes it, value and all, and it would be TYPED into
# the worker as part of the steer while this script exits 0. That is how a
# printed close hint naming a missing flag delivered `-ResolveKey api-shape
# <answer>` to a worker as chat. A lone dash-word is therefore refused here,
# before anything is resolved or sent; a message that really contains one goes
# as a single quoted argument, which never arrives as a lone token.
$flagLike = @($Message | Where-Object { $_ -match '^--?[A-Za-z][A-Za-z0-9-]*$' })
if ($flagLike.Count -gt 0) {
    [Console]::Error.WriteLine(("error: fm-send.ps1 has no parameter '$($flagLike[0])'; it would have been typed into the " +
        'worker as text, so nothing was sent. Check the flag against fm-send.ps1 -? or, if the message really ' +
        'contains that word, pass the whole message as one quoted argument.'))
    exit 2
}

if ($Key -and $text) {
    [Console]::Error.WriteLine('error: pass either -Key or a message, not both')
    exit 2
}
if (-not $Key -and -not $text) {
    [Console]::Error.WriteLine('usage: fm-send.ps1 <target> <message...> | fm-send.ps1 <target> -Key <key>')
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
    # Straight to stderr, not Write-Error: an entry point's refusal is a
    # message for a human or a calling script, not a PowerShell error record
    # with source-line decoration wrapped around it.
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
