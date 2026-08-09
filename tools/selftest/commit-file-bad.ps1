# commit-file-bad.ps1 - THROWAWAY negative twin: identical stdout, identical
# exit code, identical working tree - but the commit it records carries a
# different subject, so only the git history diverges. Proves fm-ps-diff's
# git-aware dimension catches repository state a file-by-file tree diff cannot
# see (the .git internals are excluded from byte comparison by design).
# Twin: tools/selftest/commit-file.sh

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$msg = [string]$args[0]
$repo = Join-Path $env:FM_HOME 'repo'

[System.IO.File]::WriteAllText((Join-Path $repo 'added.txt'), "added by the twin`n", $utf8NoBom)

& git -C $repo add added.txt
# THE DEFECT: the recorded subject is not the one the caller asked for.
& git -C $repo commit -qm "$msg (ps)"

[Console]::Out.Write("committed: $msg`n")
