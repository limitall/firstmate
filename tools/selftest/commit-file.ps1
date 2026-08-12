# commit-file.ps1 - THROWAWAY PowerShell twin exercising the git-aware
# dimension. Twin: tools/selftest/commit-file.sh
# Usage: commit-file.ps1 <message>

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$msg = [string]$args[0]
$repo = Join-Path $env:FM_HOME 'repo'

[System.IO.File]::WriteAllText((Join-Path $repo 'added.txt'), "added by the twin`n", $utf8NoBom)

& git -C $repo add added.txt
& git -C $repo commit -qm $msg

[Console]::Out.Write("committed: $msg`n")
