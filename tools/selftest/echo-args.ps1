# echo-args.ps1 - THROWAWAY PowerShell twin for the fm-ps-diff self-test.
# Twin: tools/selftest/echo-args.sh
#
# Usage: echo-args.ps1 <exit-code> [args...]
#
# Deliberately behaves IDENTICALLY to its bash twin so the harness has a
# genuine positive case. The *-bad-*.ps1 siblings each break exactly one
# dimension so the harness can be shown catching it.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$code = [int]$args[0]
$rest = @($args | Select-Object -Skip 1)

$stateDir = Join-Path $env:FM_HOME 'state'
[System.IO.Directory]::CreateDirectory($stateDir) | Out-Null

# Mirror bash's `$(cat)`: command substitution strips every trailing newline.
# ReadToEnd() keeps them, and that one-character difference is exactly the kind
# of thing this harness exists to surface.
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

# LF only, no BOM: contract 2 of docs/powershell-port.md. Set-Content would
# emit CRLF on Windows and the harness would (correctly) fail this file.
[System.IO.File]::WriteAllText((Join-Path $stateDir 'echo.meta'), (($lines -join "`n") + "`n"), $utf8NoBom)

[Console]::Out.Write("args: $($rest -join ' ')`n")
[Console]::Out.Write("home: $($env:FM_HOME)`n")
[Console]::Out.Write("stdin-bytes: $($stdinContent.Length)`n")
[Console]::Error.Write("diag: preparing exit $code`n")

exit $code
