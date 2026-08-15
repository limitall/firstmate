#requires -Version 7.0
<#
.SYNOPSIS
fm-dictate.ps1 - hand a dictated line to firstmate, using the speech engine's
already-loaded model.

.DESCRIPTION
WHY THIS EXISTS, MEASURED. The bridge can transcribe a recording itself by
shelling out to the engine, and that works - but it pays a full model load every
single time:

    run 1  total 14.6s   load 8904ms   transcribe 4759ms
    run 2  total 15.8s   load 10601ms  transcribe 4207ms
    run 3  total 12.6s   load 7609ms   transcribe 4161ms

Two thirds of the wait is loading a model that is ALREADY in memory in the
engine's own process - it holds one resident for minutes at a time. A separate
process cannot borrow that, so the only way to use the warm copy is to let the
engine do the transcribing and hand the text over afterwards.

That is what this is. The engine records and transcribes with its resident
model, then pipes the transcript to this script on stdin. Roughly four seconds
instead of fifteen, and no second copy of a 1.7B model loaded per utterance.

The captain never sees any of it: they hold their dictation key, speak, and the
words reach firstmate.

HOW TO WIRE IT (in the engine's settings):
    paste_method        external_script
    external_script_path <this file>

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
