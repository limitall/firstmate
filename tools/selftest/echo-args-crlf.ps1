# echo-args-crlf.ps1 - THROWAWAY negative twin: same text, wrong line endings.
# Written with Set-Content, which is CRLF-by-default on Windows - the single
# easiest way to break contract 2 of docs/powershell-port.md without noticing,
# because the rendered text looks identical. Proves fm-ps-diff names the `eol`
# dimension instead of showing a baffling whitespace diff.
# Twin: tools/selftest/echo-args.sh

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$code = [int]$args[0]
$rest = @($args | Select-Object -Skip 1)

$stateDir = Join-Path $env:FM_HOME 'state'
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

$stdinContent = ([Console]::In.ReadToEnd()).TrimEnd("`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("home=$($env:FM_HOME)")
$lines.Add("argc=$($rest.Count)")
$i = 0
foreach ($a in $rest) {
    $i++
    $lines.Add("arg$i=$a")
}
$lines.Add("stdin=$stdinContent")
$lines.Add("written_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss'))Z")
$lines.Add("epoch=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
$lines.Add("pid=$PID")

# THE DEFECT: Set-Content writes CRLF and a trailing newline per line on
# Windows. Byte-wise this file is wrong; visually it is not.
Set-Content -LiteralPath (Join-Path $stateDir 'echo.meta') -Value $lines -Encoding utf8NoBOM

[Console]::Out.Write("args: $($rest -join ' ')`n")
[Console]::Out.Write("home: $($env:FM_HOME)`n")
[Console]::Out.Write("stdin-bytes: $($stdinContent.Length)`n")
[Console]::Error.Write("diag: preparing exit $code`n")

exit $code
