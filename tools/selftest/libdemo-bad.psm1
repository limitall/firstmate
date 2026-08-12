# libdemo-bad.psm1 - THROWAWAY negative module twin: joins correctly but loses
# the distinct return code 3 for the empty case, returning 0 instead. Proves
# fm-ps-diff catches an exit-code divergence through the Shape='Function' path
# too, not just for entrypoint scripts.
# Twin: tools/selftest/libdemo.sh

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
    [string[]] $list = @()
    if ($null -ne $Items) { $list = @($Items) }
    [Console]::Out.Write(($list -join $Separator) + "`n")
    # THE DEFECT: `[ "$#" -gt 0 ] || return 3` silently became "always succeed".
    return 0
}

Export-ModuleMember -Function Invoke-FmDemoJoin
