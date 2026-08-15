#requires -Version 7.0
# FmBridgeSession.ps1 - the persistent firstmate session the bridge hosts.
#
# WHY A HOSTED SESSION RATHER THAN A REIMPLEMENTATION. data/web-ui/report.md
# measured the constraint that picks this shape: a headless `claude` process CAN
# hold this home's session lock (`lock acquired: harness pid 18828`), and a plain
# PowerShell process CANNOT - Get-FmHarnessAncestryPid returns nothing for one.
# So the bridge must HOST firstmate, never be it. Firstmate stays a Claude
# session running the same AGENTS.md, the same skills and the same spawn path;
# the bridge is a courier.
#
# WHY ONE PERSISTENT PROCESS RATHER THAN ONE PER MESSAGE. Also measured, and the
# gap is not marginal: persistent answered in 1188ms and 948ms after a 6031ms
# first token, against 7-8s for `--resume` per message, and a resumed turn paid a
# full 31,230-token cache creation ($0.3125) against $0.0795 on the persistent
# process. Restarting per message would be four times the cost for six times the
# wait.
#
# THE STREAM CONTRACT. `claude -p --input-format stream-json --output-format
# stream-json --verbose` speaks newline-delimited JSON both ways. Each user turn
# is one JSON line in; the reply arrives as a sequence of lines ending in a
# `result` object. Reading is done on a background thread into a queue, because
# the HTTP listener must never block on the agent.

Set-StrictMode -Version Latest

function New-FmBridgeSession {
    <#
        .SYNOPSIS
        Start the hosted firstmate session. Returns a handle, or $null.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts the process the bridge exists to host; the entry point owns the decision to run.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [string]$Model = ''
    )

    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { return $null }

    $sessionId = [guid]::NewGuid().ToString()

    # NOT $args - that is a PowerShell automatic variable, and shadowing it here
    # would change what every call inside this function sees.
    $launchArgs = @(
        '-p'
        '--input-format', 'stream-json'
        '--output-format', 'stream-json'
        '--verbose'
        '--session-id', $sessionId
        # The bridge's whole point is that the captain never has to approve a
        # tool call from a terminal they are not looking at.
        '--dangerously-skip-permissions'
    )
    if ($Model) { $launchArgs += @('--model', $Model) }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $claude.Source
    foreach ($a in $launchArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $HomePath
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    if (-not $proc.Start()) { return $null }

    # NO reader thread. The obvious design - a background thread draining stdout
    # into a queue - does not work here: a PowerShell script block needs a
    # runspace, and a ThreadStart has none, so it dies with "There is no Runspace
    # available to run scripts in this thread" the moment it runs. Measured.
    #
    # Reading synchronously inside the turn is both simpler and correct for this
    # shape, because a turn BLOCKS on the reply anyway - there is nothing else
    # the caller wants to do meanwhile. Output produced between turns waits in
    # the pipe and is drained at the start of the next one, which is exactly the
    # staleness guard Send-FmBridgeTurn already needed.
    [pscustomobject]@{
        PSTypeName = 'Firstmate.BridgeSession'
        Process    = $proc
        SessionId  = $sessionId
        Home       = $HomePath
        Started    = [datetime]::UtcNow
    }
}

function Send-FmBridgeTurn {
    <#
        .SYNOPSIS
        Send one captain turn to the hosted session and collect the reply.

        .DESCRIPTION
        Blocks until the session emits its `result` object or the bound expires.
        A timeout returns what arrived rather than nothing, because a partial
        answer is more use to the captain than silence - and it says so.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes to a running child process the caller already owns.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Text,
        [int]$TimeoutSeconds = 300
    )

    if ($null -eq $Session -or $Session.Process.HasExited) {
        return [pscustomobject]@{ Ok = $false; Reply = ''; Error = 'the firstmate session is not running' }
    }

    # NO pre-drain. The obvious guard - Peek() the stream and discard whatever is
    # already buffered - HANGS: Peek() on a redirected pipe blocks when nothing
    # is buffered, so an idle session froze the turn before it was even sent.
    # Measured: the request reached the bridge, logged the captain's line, and
    # never returned.
    #
    # It turns out the guard was solving a problem that does not exist. Every
    # turn returns the moment it reads its `result` line, which leaves the stream
    # positioned immediately after that result, so there is nothing stale to
    # drain. The session's one-time startup messages - hook events and `init` -
    # arrive before the first result and are skipped by type below.

    $payload = [ordered]@{
        type    = 'user'
        message = [ordered]@{
            role    = 'user'
            content = @(@{ type = 'text'; text = $Text })
        }
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress

    try {
        $Session.Process.StandardInput.WriteLine($json)
        $Session.Process.StandardInput.Flush()
    } catch {
        return [pscustomobject]@{ Ok = $false; Reply = ''; Error = "could not reach the session: $($_.Exception.Message)" }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    # NOT $text - that is this function's own [string] parameter, and assigning a
    # StringBuilder over it left the accumulator as a string, so the first
    # .Append() threw and every browser turn came back 500 while the same call
    # from PowerShell appeared to work.
    $collected = [System.Text.StringBuilder]::new()
    $line = ''

    while ([datetime]::UtcNow -lt $deadline) {
        if ($Session.Process.HasExited) { break }
        try { $line = $Session.Process.StandardOutput.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $obj) { continue }

        $type = ''
        if ($obj.PSObject.Properties['type']) { $type = [string]$obj.type }

        if ($type -eq 'assistant' -and $obj.PSObject.Properties['message']) {
            foreach ($block in @($obj.message.content)) {
                if ($null -ne $block -and $block.PSObject.Properties['type'] -and $block.type -eq 'text') {
                    $null = $collected.Append([string]$block.text)
                }
            }
        } elseif ($type -eq 'result') {
            # The turn is over. Prefer the session's own result string when it
            # carries one; it is the same text the terminal would have shown.
            if ($obj.PSObject.Properties['result'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.result)) {
                return [pscustomobject]@{ Ok = $true; Reply = ([string]$obj.result).Trim(); Error = '' }
            }
            return [pscustomobject]@{ Ok = $true; Reply = $collected.ToString().Trim(); Error = '' }
        }
    }

    # ---- RESYNC, and this is not optional ----------------------------------
    # A turn that gives up mid-flight leaves its `result` line unread in the
    # pipe, and the NEXT turn reads it as its own answer. Measured, and it is the
    # worst failure this whole path can have: the captain asks something and gets
    # a confident, well-formed answer to the question BEFORE it, with nothing on
    # screen suggesting anything went wrong.
    #
    #     captain: Say PONG
    #     firstmate: BRIDGE ALIVE     <- the previous turn's answer
    #
    # So an abandoned turn must consume its own result before returning. The cap
    # is a hard bound rather than a duration: if the stream cannot be realigned,
    # the session is declared desynced and the caller is told, because answering
    # from a stream you have lost your place in is worse than not answering.
    $resynced = $false
    for ($i = 0; $i -lt 4000; $i++) {
        if ($Session.Process.HasExited) { break }
        try { $line = $Session.Process.StandardOutput.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $o = $line | ConvertFrom-Json
            if ($o -and $o.PSObject.Properties['type'] -and [string]$o.type -eq 'result') { $resynced = $true; break }
        } catch {
            # A line that will not parse is not a result, which is the only thing
            # this loop is looking for. Keep reading rather than abandoning the
            # resync, because giving up here is what leaves the stream misaligned.
            Write-Debug "resync skipped an unparseable line: $($_.Exception.Message)"
        }
    }

    $partial = $collected.ToString().Trim()
    if (-not $resynced) {
        return [pscustomobject]@{
            Ok = $false; Reply = ''
            Error = 'the session lost sync and was not answered; restart the bridge'
            Desynced = $true
        }
    }
    if ($partial) {
        return [pscustomobject]@{ Ok = $true; Reply = $partial; Error = 'the turn was still going when the wait ran out' }
    }
    [pscustomobject]@{ Ok = $false; Reply = ''; Error = 'no answer within the wait' }
}

function Stop-FmBridgeSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Session)
    if ($null -eq $Session) { return }
    if (-not $PSCmdlet.ShouldProcess('hosted firstmate session', 'stop')) { return }
    # Closing stdin asks the session to finish; the kill is the backstop. Both
    # are best-effort by design: this runs on the bridge's way out, and a session
    # that has already died must not turn shutdown into a failure.
    try { $Session.Process.StandardInput.Close() }
    catch { Write-Debug "session stdin already closed: $($_.Exception.Message)" }
    try { if (-not $Session.Process.WaitForExit(4000)) { $Session.Process.Kill($true) } }
    catch { Write-Debug "session already gone: $($_.Exception.Message)" }
}

function Get-FmBridgeFleet {
    <#
        .SYNOPSIS
        The fleet as the browser needs it: progress, decisions, activity.

        .DESCRIPTION
        Every field comes from durable records that survive with no session at
        all, which is what makes the browser a view rather than a second source
        of truth. The percentage keeps the honesty rule from Get-FmProgress: a
        task that claimed none reports null, never zero.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$HomePath)

    $state = Join-Path $HomePath 'state'
    $tasks = @()
    $decisions = @()
    $activity = @()

    if (Test-Path -LiteralPath $state -PathType Container) {
        foreach ($meta in @(Get-ChildItem -LiteralPath $state -Filter '*.meta' -File -ErrorAction SilentlyContinue)) {
            $id = $meta.BaseName
            $statusPath = Join-Path $state "$id.status"
            $percent = $null
            $note = ''
            $st = ''

            if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                $lines = @([System.IO.File]::ReadAllLines($statusPath) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($lines.Count) {
                    $last = [string]$lines[-1]
                    if ($last -match '^\s*([a-z-]+)\s*:') { $st = $Matches[1] }
                    $note = ($last -replace '^\s*[a-z-]+\s*:\s*', '') -replace '^\[\s*\d{1,3}\s*%\s*\]\s*', ''

                    if ($st -eq 'done') {
                        $percent = 100
                    } else {
                        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                            if ([string]$lines[$i] -match '^\s*(?:[a-z-]+:\s*)?\[\s*(\d{1,3})\s*%\s*\]') {
                                $v = [int]$Matches[1]
                                if ($v -ge 0 -and $v -le 100) { $percent = $v }
                                break
                            }
                        }
                    }

                    # Open decisions: raised by a needs-decision line and closed
                    # only by a resolved line carrying the same key.
                    foreach ($l in $lines) {
                        $s = [string]$l
                        if ($s -match '^\s*needs-decision\s*:\s*(.+)$') {
                            $body = $Matches[1]
                            $key = if ($body -match '\[key=([^\]]+)\]') { $Matches[1] } else { 'default' }
                            $decisions += [pscustomobject]@{
                                Task     = $id
                                Key      = $key
                                Question = ($body -replace '\[\s*\d{1,3}\s*%\s*\]\s*', '' -replace '\[key=[^\]]+\]\s*', '').Trim()
                            }
                        } elseif ($s -match '^\s*resolved\s*:') {
                            $key = if ($s -match '\[key=([^\]]+)\]') { $Matches[1] } else { 'default' }
                            $decisions = @($decisions | Where-Object { -not ($_.Task -eq $id -and $_.Key -eq $key) })
                        }
                    }

                    foreach ($l in ($lines | Select-Object -Last 4)) {
                        $activity += [pscustomobject]@{
                            Task = $id
                            Text = [string]$l
                            At   = (Get-Item -LiteralPath $statusPath).LastWriteTime.ToString('HH:mm:ss')
                        }
                    }
                }
            }

            $tasks += [pscustomobject]@{
                Id      = $id
                Percent = $percent
                State   = $st
                Note    = $note
            }
        }
    }

    [pscustomobject]@{
        Tasks     = @($tasks | Sort-Object Id)
        Decisions = @($decisions)
        Activity  = @($activity | Sort-Object At -Descending | Select-Object -First 24)
        At        = (Get-Date).ToString('HH:mm:ss')
    }
}
