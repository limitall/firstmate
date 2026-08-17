#requires -Version 7.0
<#
.SYNOPSIS
fm-dictate.ps1 - hand a dictated line to firstmate, using the speech engine's
already-loaded model.

.DESCRIPTION
WHY THIS EXISTS, MEASURED. The bridge can transcribe a recording itself by
shelling out to the engine, and that works - but it pays a full model load every
single time. Three runs of one 5.35s clip on the captain's laptop, wall clock
against the engine's own log:

    run 1  total 19.31s   load 14802ms  transcribe 3.31s
    run 2  total 15.00s   load 10910ms  transcribe 3.02s
    run 3  total 14.80s   load 10852ms  transcribe 2.97s

Three quarters of the wait is loading a model that is ALREADY in memory in the
engine's own process - it holds one resident for minutes at a time. A separate
process cannot borrow that, so the only way to use the warm copy is to let the
engine do the transcribing and hand the text over afterwards. Its own instance
also starts the load AS RECORDING BEGINS, so even a cold model loads while the
captain is still speaking instead of after they stop.

That is what this is. The engine records and transcribes with its resident
model, then hands the transcript to this script - on stdin, or as an argument;
both work. About three seconds of engine work instead of fifteen, and no second
copy of a 1.7B model loaded per utterance.

The captain never sees any of it: they hold their dictation key, speak, and the
words reach firstmate.

THE ONE MANUAL STEP, and it is deliberately left to the captain. In the
dictation app's own settings:

    paste method          external script
    external script path  <this directory>\fm-dictate.cmd

POINT IT AT THE .cmd, NOT AT THIS FILE. The engine spawns its hook as a process
and Windows cannot execute a .ps1 that way at all - measured, CreateProcess
raises "The specified executable is not a valid application for this OS
platform" - while a .cmd runs through the command processor. `fm-dictate.cmd` is
one line in front of this script for exactly that reason.

Until that setting is changed the engine types what it hears wherever the cursor
is, which still works when the browser's message box has focus. The bridge reads
the setting and says which of the two is happening rather than leaving the
captain to guess.

.PARAMETER Port
The bridge's loopback port. Default 7433.

.PARAMETER Echo
Print the transcript back, so the engine also pastes it where the cursor is.
Without this the script prints nothing and the engine pastes nothing, which is
what you want when the browser is the only surface.

.EXAMPLE
"how many tasks are under way" | bin/fm-dictate.ps1
#>
[CmdletBinding()]
param(
    # Accepts a piped string AS WELL AS raw stdin. The engine runs this as an
    # external process and writes to stdin, which [Console]::In reads - but a
    # script whose param block declares no pipeline input REFUSES a PowerShell
    # pipe outright ("cannot be bound to any parameters"), which made it
    # untestable from a shell. Both paths now work.
    [Parameter(ValueFromPipeline)][string]$Text = '',
    [ValidateRange(1024, 65535)][int]$Port = 7433,
    [switch]$Echo
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    . (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmBridgeTokenPath'

    # A real begin/process/end shape, not a bare body. Declaring
    # ValueFromPipeline without a process block binds only the LAST item and the
    # analyzer says so - and a dictated line that arrives as several pipeline
    # items would silently lose all but its final piece.
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($Text) { $lines.Add($Text) }
}

end {
    $said = ($lines -join ' ').Trim()
    if (-not $said) {
        # Nothing came through the PowerShell pipeline, so read the process's own
        # stdin - which is how the engine actually delivers it.
        try { $said = ([Console]::In.ReadToEnd()).Trim() } catch { $said = '' }
    }
    if (-not $said) { exit 0 }

    $tokenFile = Get-FmBridgeTokenPath
    $token = ''
    if (Test-Path -LiteralPath $tokenFile -PathType Leaf) {
        try { $token = ([System.IO.File]::ReadAllText($tokenFile)).Trim() } catch { $token = '' }
    }

    if (-not $token) {
        # No bridge running, so there is nothing to hand this to. Echo it back
        # rather than swallowing it - losing what the captain just said is the
        # one outcome worth avoiding here.
        [Console]::Out.Write($said)
        exit 0
    }

    try {
        $body = @{ text = $said } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod "http://127.0.0.1:$Port/api/dictate" -Method Post `
            -Headers @{ 'X-Fm-Token' = $token; 'Content-Type' = 'application/json' } `
            -Body $body -TimeoutSec 10
    } catch {
        # Unreachable or refused. Same rule: give the words back rather than
        # losing them.
        [Console]::Out.Write($said)
        exit 0
    }

    # Delivered. Printed only if the caller asked, because the browser is already
    # showing the exchange and a second copy pasted under the cursor is noise.
    if ($Echo) { [Console]::Out.Write($said) }
    exit 0
}
