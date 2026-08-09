# libdemo.psm1 - THROWAWAY module twin for the fm-ps-diff self-test.
# Twin: tools/selftest/libdemo.sh
#
# Shows the Shape='Function' contract: the function writes its output through
# [Console]::Out (byte-controlled, LF) and RETURNS the bash return code as its
# last pipeline object, which the harness's PwshExitFrom='Return' driver turns
# into the process exit code.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-FmDemoJoin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Separator,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $Items
    )
    # ValueFromRemainingArguments binds $null (not an empty array) when nothing
    # remains, and @($null) has Count 1 - the empty-middle-field class of trap
    # docs/powershell-port.md warns about. Note also that `$x = if (..) { @() }`
    # leaves $x $null, because PowerShell unrolls an empty array out of a
    # statement; assign first, then overwrite.
    [string[]] $list = @()
    if ($null -ne $Items) { $list = @($Items) }
    [Console]::Out.Write(($list -join $Separator) + "`n")
    if ($list.Count -eq 0) { return 3 }
    return 0
}

Export-ModuleMember -Function Invoke-FmDemoJoin
