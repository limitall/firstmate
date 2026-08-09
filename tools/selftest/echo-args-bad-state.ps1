# echo-args-bad-state.ps1 - THROWAWAY negative twin: identical exit code,
# stdout and stderr, but the durable state file is wrong (argc counts the exit
# code argument too). Proves fm-ps-diff catches a divergence that is INVISIBLE
# on both streams - the class of bug a console-only comparison would miss.
# Twin: tools/selftest/echo-args.sh

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$code = [int]$args[0]
$rest = @($args | Select-Object -Skip 1)

$stateDir = Join-Path $env:FM_HOME 'state'
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

$stdinContent = ([Console]::In.ReadToEnd()).TrimEnd("`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("home=$($env:FM_HOME)")
# THE DEFECT: an off-by-one in a durable record. Nothing on stdout or stderr
# reveals it.
$lines.Add("argc=$($args.Count)")
$i = 0
foreach ($a in $rest) {
    $i++
    $lines.Add("arg$i=$a")
}
$lines.Add("stdin=$stdinContent")
$lines.Add("written_at=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss'))Z")
$lines.Add("epoch=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
$lines.Add("pid=$PID")

[System.IO.File]::WriteAllText((Join-Path $stateDir 'echo.meta'), (($lines -join "`n") + "`n"), $utf8NoBom)

[Console]::Out.Write("args: $($rest -join ' ')`n")
[Console]::Out.Write("home: $($env:FM_HOME)`n")
[Console]::Out.Write("stdin-bytes: $($stdinContent.Length)`n")
[Console]::Error.Write("diag: preparing exit $code`n")

exit $code
