#requires -Version 7.0
<#
.SYNOPSIS
    One command for the whole session start.

.DESCRIPTION
    Prints the full ordered digest to stdout and ALWAYS exits 0: this is a
    reporting command, not a gate. A lock refusal is reported as a loud banner
    inline, never a silent failure or a non-zero exit that would make an agent
    skip the rest of the digest.

    Runtime bound: the whole digest runs as one bounded child process
    (FM_SESSION_START_TIMEOUT, default 120s). Everything the child emitted before
    the bound was hit is delivered, then a loud STARTUP TRUNCATED banner names
    the stage that did not finish. FM_SESSION_START_STAGE_FILE is both the
    child's breadcrumb and the flag that tells a child it is the child, so the
    parent never recurses.

.PARAMETER Reemit
    This process ALREADY took the helm at its own startup and has only lost its
    context (a /clear or a compaction). Skips the mutating sweeps that startup
    already reconciled and re-emits the rest. Wake-queue presentation is NOT
    skipped: queued records arrived after startup and are this turn's work.
#>
[CmdletBinding()]
param(
    [switch]$Reemit,
    [Parameter(ValueFromRemainingArguments)][string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# `--reemit` is accepted alongside -Reemit so the bash muscle memory, the tracked
# hook command lines, and PowerShell's own convention all work.
if ($RemainingArguments -contains '--reemit') { $Reemit = [switch]$true }
foreach ($arg in @($RemainingArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
    if ($arg -notin @('--reemit')) {
        [Console]::Error.WriteLine("fm-session-start: unknown argument: $arg")
        [Console]::Error.WriteLine('usage: fm-session-start.ps1 [--reemit]')
        exit 2
    }
}

. (Join-Path $PSScriptRoot 'fm-module-load.ps1')

if ([string]::IsNullOrEmpty($env:FM_SESSION_START_STAGE_FILE)) {
    # Parent: run the digest as one bounded child.
    Invoke-FmSessionStart -Bounded -Reemit:$Reemit -EntryScript $PSCommandPath
    exit 0
}

# Child: emit the digest. When the parent gave it an output file, everything goes
# there and the parent streams it; that keeps exactly one writer per stream and
# preserves every line already emitted when the bound is hit.
$outputFile = $env:FM_SESSION_START_OUTPUT_FILE
if ([string]::IsNullOrEmpty($outputFile)) {
    Invoke-FmSessionStart -Reemit:$Reemit
    exit 0
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$stream = [System.IO.StreamWriter]::new($outputFile, $true, $utf8NoBom)
$stream.AutoFlush = $true
$stream.NewLine = "`n"
try {
    Invoke-FmSessionStart -Reemit:$Reemit | ForEach-Object { $stream.WriteLine([string]$_) }
} finally {
    $stream.Dispose()
}
exit 0
