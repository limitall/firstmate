# echo-args-no-state.ps1 - THROWAWAY negative twin: streams and exit code are
# perfect, but the durable record is never written at all. Proves fm-ps-diff
# catches file EXISTENCE divergence, not just content divergence.
# Twin: tools/selftest/echo-args.sh

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$code = [int]$args[0]
$rest = @($args | Select-Object -Skip 1)

$stateDir = Join-Path $env:FM_HOME 'state'
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

$stdinContent = ([Console]::In.ReadToEnd()).TrimEnd("`n")

# THE DEFECT: an early-return path that skips the state write. The streams
# still look right, which is what makes this class of bug expensive.

[Console]::Out.Write("args: $($rest -join ' ')`n")
[Console]::Out.Write("home: $($env:FM_HOME)`n")
[Console]::Out.Write("stdin-bytes: $($stdinContent.Length)`n")
[Console]::Error.Write("diag: preparing exit $code`n")

exit $code
