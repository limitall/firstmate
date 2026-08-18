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
        # ONCE, not per turn. This screen speaks as well as prints, and the two
        # need different sentences; Get-FmBridgeSpeechContract owns why.
        '--append-system-prompt', (Get-FmBridgeSpeechContract)
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
    # THE SESSION MAY NOT SPEAK. It reads the same AGENTS.md as any other
    # firstmate and therefore knows bin/fm-say.ps1 exists, so on a home whose
    # captain has created config/voice it would talk out of a process this page
    # cannot reach - leaving them nothing to stop it with but killing the
    # bridge. Speaking on this surface belongs to the page, which stops existing
    # when the captain closes it. Test-FmVoiceSuppressed is the gate, and its
    # help is honest about what this did and did not cause; the variable is
    # inherited, so anything this session starts is covered too.
    $psi.Environment['FM_VOICE_OFF'] = '1'

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
        return [pscustomobject]@{ Ok = $false; Reply = ''; Error = 'firstmate is not running here, so nothing is listening' }
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
        return [pscustomobject]@{ Ok = $false; Reply = ''; Error = "could not reach firstmate: $($_.Exception.Message)" }
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
            Error = 'firstmate lost its place in the conversation and did not answer; start it again'
            Desynced = $true
        }
    }
    if ($partial) {
        return [pscustomobject]@{ Ok = $true; Reply = $partial; Error = 'the answer was still coming when the wait ran out' }
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

function Test-FmBridgeConfigured {
    <#
        .SYNOPSIS
        Has this machine been told where firstmate's workspace lives?

        .DESCRIPTION
        The answer is a real workspace on disk, not a pointer file that happens
        to exist: a pointer naming a directory that was deleted or moved is
        exactly the case where a silent "configured" answer sends every later
        command at nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $marker = Join-Path $RepoRoot '.fm-workspace'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    $path = ''
    try { $path = ([System.IO.File]::ReadAllText($marker)).Trim() } catch { return $false }
    if (-not $path) { return $false }
    Test-Path -LiteralPath (Join-Path $path 'state') -PathType Container
}

function Get-FmBridgeWorkspace {
    <#
        .SYNOPSIS
        The workspace this machine was set up with, or '' when it has none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $marker = Join-Path $RepoRoot '.fm-workspace'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return '' }
    try { return ([System.IO.File]::ReadAllText($marker)).Trim() } catch { return '' }
}

function Initialize-FmBridgeWorkspace {
    <#
        .SYNOPSIS
        Create firstmate's workspace at a captain-chosen path and record it.

        .DESCRIPTION
        Called once, from the browser, on first run. It creates the home layout,
        points this checkout at it, and remembers the choice so every later start
        goes straight there.

        It REFUSES rather than guessing on anything ambiguous: a path that is not
        absolute, a path that is a file, or a path it cannot create. A workspace
        silently created somewhere other than where the captain typed is worse
        than a refusal they can act on.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    $wanted = $Path.Trim().Trim('"')
    if (-not $wanted) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Error = 'no path given' }
    }
    # Expand %VARS% and ~ so a captain can type what they would type anywhere
    # else, rather than learning this box's rules.
    $wanted = [Environment]::ExpandEnvironmentVariables($wanted)
    if ($wanted.StartsWith('~')) {
        $wanted = Join-Path ([Environment]::GetFolderPath('UserProfile')) $wanted.TrimStart('~', '/', '\')
    }
    if (-not [System.IO.Path]::IsPathRooted($wanted)) {
        return [pscustomobject]@{ Ok = $false; Path = $wanted
            Error = 'give a full path, such as C:\Users\you\firstmate' }
    }
    if (Test-Path -LiteralPath $wanted -PathType Leaf) {
        return [pscustomobject]@{ Ok = $false; Path = $wanted; Error = 'that path is a file' }
    }
    # Normalized, so a pasted path with doubled separators or a trailing slash is
    # recorded the way every later comparison will spell it. Observed storing
    # `C:\\Users\\...` verbatim, which worked but made the marker file and the
    # home pointer disagree with everything that reads them back.
    try { $wanted = [System.IO.Path]::GetFullPath($wanted).TrimEnd('\', '/') }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = $wanted; Error = 'that path cannot be read as a location' }
    }

    if (-not $PSCmdlet.ShouldProcess($wanted, 'create the firstmate workspace')) {
        return [pscustomobject]@{ Ok = $false; Path = $wanted; Error = 'not confirmed' }
    }

    try {
        foreach ($d in @('', 'config', 'data', 'projects', 'state')) {
            $target = if ($d) { Join-Path $wanted $d } else { $wanted }
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $target -Force
            }
        }
        # herdr is the only session provider this port drives, so a fresh
        # workspace names it rather than resolving to one nothing can run.
        $backend = Join-Path $wanted 'config' 'backend'
        if (-not (Test-Path -LiteralPath $backend -PathType Leaf)) {
            [System.IO.File]::WriteAllText($backend, "herdr`n", [System.Text.UTF8Encoding]::new($false))
        }
        # Two records, deliberately. .fm-home is what every entry point reads to
        # resolve the home with no profile and no environment; .fm-workspace is
        # what the bridge reads to know setup has HAPPENED, and survives even if
        # the home is later repointed by hand.
        [System.IO.File]::WriteAllText((Join-Path $RepoRoot '.fm-home'), $wanted,
            [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $RepoRoot '.fm-workspace'), "$wanted`n",
            [System.Text.UTF8Encoding]::new($false))
    } catch {
        return [pscustomobject]@{ Ok = $false; Path = $wanted; Error = $_.Exception.Message }
    }

    [pscustomobject]@{ Ok = $true; Path = $wanted; Error = '' }
}

function Get-FmBridgeTokenPath {
    <#
        .SYNOPSIS
        Where the bridge leaves its key for the dictation hook.

        .DESCRIPTION
        Two processes need this path and neither can be handed it: the bridge
        writes the key on start, and bin/fm-dictate.ps1 - which the speech engine
        runs as a separate process - reads it. Owning it here keeps them from
        drifting apart, which a duplicated literal in two files eventually does.

        The key itself is minted per run and never written anywhere else, so it
        dies with the bridge that made it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path ([System.IO.Path]::GetTempPath()) 'fm-bridge-token'
}

function Get-FmSpeechEngine {
    <#
        .SYNOPSIS
        The local speech-to-text engine, or $null when none is installed.

        .DESCRIPTION
        Handy (handy.exe) holds a local ASR model and will transcribe a WAV
        headlessly with `--transcribe-file`. That is the whole integration: no
        service to run, no port, no hotkey, and no audio leaving this machine.

        Measured on the captain's laptop with Qwen3-ASR-1.7B on Vulkan: a 5.28s
        clip transcribed in 2.48s, after a 12.9s one-time model load. The model
        stays resident for five minutes, so only the first request after a lull
        pays that load.

        Preferred over the browser's own recognizer for three reasons that are
        facts rather than taste: the model is stronger, it is already tuned to
        this captain's vocabulary, and it runs HERE - the browser's recognizer
        has historically shipped audio to a third party, which is the exact
        question decision `web-ui-voice-listening` exists to settle.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Handy\handy.exe')
        (Join-Path $env:ProgramFiles 'Handy\handy.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    $onPath = Get-Command handy -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    ''
}

function Get-FmSpeechEngineStatus {
    <#
        .SYNOPSIS
        What the local speech engine can do for us right now: installed,
        running, and willing to hand its words over.

        .DESCRIPTION
        WHY THIS IS SEPARATE FROM Get-FmSpeechEngine. Installed and USABLE are
        different facts, and the gap between them is the entire cost of
        dictation. Measured on the captain's laptop, three runs of one 5.35s
        clip through `--transcribe-file`:

            run 1  wall 19.31s   model load 14802ms   transcribe 3.31s
            run 2  wall 15.00s   model load 10910ms   transcribe 3.02s
            run 3  wall 14.80s   model load 10852ms   transcribe 2.97s

        Every one of those loads a model the engine's OWN running instance
        already holds - and only that instance can transcribe with it. Isolated
        in one process that loads once and transcribes the same clip three times:
        load 8686ms against transcribe 3009ms, 2635ms, 2495ms. The load is the
        whole difference, and a warm model does not pay it.

        So the fast path is not a better one-shot; it is to stop making one, let
        the running instance do the work, and receive the words afterwards.

        Three answers, kept apart because the caller acts differently on each:

        - Installed: there is an engine on this machine at all.
        - Running: an instance is UP, which is what makes a warm model
          reachable. Nothing here starts one - see Invoke-FmSpeechCapture.
        - HandsOver: that instance is set to hand the words to firstmate when
          it finishes, rather than typing them wherever the cursor happens to
          be. This READS the captain's own setting and never writes it;
          `bin/fm-dictate.ps1` states the one step they change by hand.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The engine's settings file. A parameter so a test can supply one,
        # defaulted to where the installed engine actually keeps it.
        [string]$SettingsPath = (Join-Path $env:APPDATA 'com.pais.handy\settings_store.json'),
        # The file the captain points the engine at. Named by the caller that
        # knows where this checkout is, so the instruction below can be acted on
        # rather than merely understood.
        [string]$HookPath = ''
    )

    $engine = Get-FmSpeechEngine
    if (-not $engine) {
        return [pscustomobject]@{
            Installed = $false; EnginePath = ''; Running = $false; HandsOver = $false
            Detail    = 'no dictation app is installed on this machine'
            Setup     = ''
        }
    }

    # Matched on the engine's own file name rather than a literal, so an engine
    # found on PATH under another name is still recognised as running.
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($engine)
    $running = [bool]@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count

    $handsOver = $false
    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        try {
            $store = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
            $method = [string](Get-FmJsonValue -InputObject $store -Path 'settings.paste_method')
            $hookFile = [string](Get-FmJsonValue -InputObject $store -Path 'settings.external_script_path')
            # Both halves, because either one alone does nothing: the method
            # chooses the hook and the path says what it runs.
            $handsOver = ($method -eq 'external_script') -and ($hookFile -match 'fm-dictate')
        } catch {
            # An unreadable settings file is reported as not wired, never as
            # wired: the caller uses this to decide whether to promise the
            # captain their words will arrive.
            Write-Debug "could not read the speech engine's settings: $($_.Exception.Message)"
        }
    }

    $detail =
    if (-not $running) { 'your dictation app is not running, so its model is not loaded' }
    elseif ($handsOver) { 'your dictation app is running and hands what it hears straight to firstmate' }
    else { 'your dictation app is running and types what it hears wherever the cursor is' }

    $setup = ''
    if (-not $handsOver) {
        $setup = 'In your dictation app''s settings, set the paste method to "external script"'
        if ($HookPath) { $setup += " and point it at $HookPath" }
        $setup += '.'
    }

    [pscustomobject]@{
        Installed  = $true
        EnginePath = $engine
        Running    = $running
        HandsOver  = $handsOver
        Detail     = $detail
        Setup      = $setup
    }
}

function Invoke-FmSpeechCapture {
    <#
        .SYNOPSIS
        Ask the RUNNING speech engine to start, stop or drop a capture.

        .DESCRIPTION
        This is the whole fast path. The engine's own CLI sends the request to
        the instance that is already up, which records with the model it already
        holds. Measured from its log: 176ms from the flag to a live microphone,
        and when a load IS needed the instance starts it as recording begins -
        so it runs while the captain is still speaking instead of after they
        stop. `--transcribe-file` can only do the opposite.

        IT REFUSES RATHER THAN STARTING AN INSTANCE. Running the engine binary
        when nothing is up launches the whole app and loads a second copy of the
        model, which is the 10.8s-to-14.8s cost this function exists to avoid;
        answering "not now" is the honest result.

        TOGGLE IS THE ENGINE'S OWN SHAPE. One flag starts and stops, so the
        CALLER owns which edge it is on - a stray second stop would begin a new
        recording. `Cancel` drops a capture without transcribing it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Toggle', 'Cancel')][string]$Action = 'Toggle',
        [int]$TimeoutSeconds = 5
    )

    $status = Get-FmSpeechEngineStatus
    if (-not $status.Installed -or -not $status.Running) {
        return [pscustomobject]@{ Ok = $false; Action = $Action; Error = $status.Detail }
    }

    $flag = if ($Action -eq 'Cancel') { '--cancel' } else { '--toggle-transcription' }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $status.EnginePath
    $psi.ArgumentList.Add($flag)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { Write-Debug 'the request process had already gone' }
            return [pscustomobject]@{ Ok = $false; Action = $Action
                Error = 'your dictation app did not answer in time'
            }
        }
        if ($proc.ExitCode -ne 0) {
            $why = ($proc.StandardError.ReadToEnd()).Trim()
            if (-not $why) { $why = "it stopped with code $($proc.ExitCode)" }
            return [pscustomobject]@{ Ok = $false; Action = $Action; Error = $why }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Action = $Action
            Error = "could not reach your dictation app: $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{ Ok = $true; Action = $Action; Error = '' }
}

function Convert-FmSpeechToText {
    <#
        .SYNOPSIS
        Turn a WAV on disk into text using the local engine.

        .DESCRIPTION
        Returns the transcript, or an empty string with a reason. It never
        throws: this sits on the path between the captain speaking and firstmate
        answering, and a thrown error there would lose what they said.

        THIS IS THE SLOW PATH AND IT IS KEPT ON PURPOSE. A one-shot engine
        process loads the model from cold every single time - 10.8s to 14.8s in
        front of 3.0s of transcription, measured three times on one clip - so
        the bridge reaches for Invoke-FmSpeechCapture first and only records a
        WAV itself when no engine instance is running to record instead. On a
        machine with nothing warm to use, fifteen seconds beats refusing to
        listen.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WavPath,
        [int]$TimeoutSeconds = 120
    )

    $engine = Get-FmSpeechEngine
    if (-not $engine) {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = 'no dictation app is installed on this machine' }
    }
    if (-not (Test-Path -LiteralPath $WavPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = 'the recording did not arrive' }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $engine
    $psi.ArgumentList.Add('--transcribe-file')
    $psi.ArgumentList.Add($WavPath)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $null = $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { Write-Debug 'engine already gone' }
            return [pscustomobject]@{ Ok = $false; Text = ''; Error = 'your dictation app did not finish in time' }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = "could not run your dictation app: $($_.Exception.Message)" }
    }

    # The engine prints a diagnostics line and then `text: <transcript>`. Only
    # the transcript is wanted; the rest is machinery the captain must not see.
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^\s*text:\s*(.*)$') {
            $said = $Matches[1].Trim()
            if ($said) { return [pscustomobject]@{ Ok = $true; Text = $said; Error = '' } }
        }
    }
    [pscustomobject]@{ Ok = $false; Text = ''; Error = 'nothing was heard in that recording' }
}

function Get-FmBridgeVocabulary {
    <#
        .SYNOPSIS
        Section 9's translation table, as ordered (pattern, plain word) pairs.

        .DESCRIPTION
        `AGENTS.md` section 9 lists the internal terms that must never reach the
        captain and the plain noun each becomes. This is that list, and it is
        deliberately a data table rather than a chain of replacements so the two
        can be read against each other.

        ORDER IS LOAD-BEARING. The longer phrase wins, because "primary checkout"
        translated a word at a time becomes "primary local copy" - which reads as
        a distinction the captain is meant to understand and is exactly the noise
        this removes. Multi-word entries therefore come first.

        WHERE SECTION 9 OFFERS A CHOICE, THE MILDEST READING WINS. `stale` may be
        "waiting too long" or "stopped responding"; a panel that announces a
        worker has stopped when it has merely gone quiet is a false alarm the
        captain acts on, so it says the weaker of the two. The strong reading
        belongs in an escalation a human wrote, not in an automatic rewrite.

        PRODUCT NAMES ARE MACHINERY TOO. The runtime and worktree tools are named
        in status lines constantly and mean nothing outside this repository, so
        they are folded into the same "tool" noun as the rest.

        THE SESSION'S OWN ARRANGEMENT IS MACHINERY, and it is the half that leaked
        first. This table was built against what a WORKER writes into a status
        line, so it had every word a worker uses and none of the words a session
        uses about itself. Observed on screen, in one reply: a process number, the
        lock, "read-only", "dispatch, steer, or merge", and the captain's own
        checkout having uncommitted changes. None of that is the captain's
        business and all of it reached them, so the words a session reaches for
        when it describes its own limits are in the table now too.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        # Multi-word first - see ORDER IS LOAD-BEARING above.
        [pscustomobject]@{ Pattern = '\bprimary\s+checkouts?\b'; Plain = 'main local copy' }
        [pscustomobject]@{ Pattern = '\btask\s+worktrees?\b'; Plain = 'isolated local copy' }
        [pscustomobject]@{ Pattern = '\blocal[\s-]main\b'; Plain = 'the local branch' }
        [pscustomobject]@{ Pattern = '\bstatus\s+files?\b|\bmetadata\b|\btask\s+ids?\b'; Plain = 'record' }
        [pscustomobject]@{ Pattern = '\bask[\s-]user\b|\bneeds[\s-]decisions?\b'; Plain = 'decision' }
        [pscustomobject]@{ Pattern = '\bwake\s+queue\b'; Plain = 'notifications' }
        [pscustomobject]@{ Pattern = '\bfail[\s-]closed\b|\bfails\s+closed\b|\bfail\s+loudly\b'; Plain = 'stops safely' }
        [pscustomobject]@{ Pattern = '\bfail[\s-]open\b|\bfails\s+open\b'; Plain = 'continues without that check' }
        [pscustomobject]@{ Pattern = '\buncommitted\s+changes\b'; Plain = 'unsaved edits' }
        # The article is eaten with the noun on purpose: translating `lock` alone
        # leaves "holds the the controls" wherever it was written naturally.
        [pscustomobject]@{ Pattern = '\b(?:the\s+)?(?:fleet|session|home|file)\s+locks?\b'; Plain = 'the controls' }
        [pscustomobject]@{ Pattern = '\b(?:the\s+)?locks?\b'; Plain = 'the controls' }
        [pscustomobject]@{ Pattern = '\bread[\s-]only\b'; Plain = 'watching only' }

        # Places.
        [pscustomobject]@{ Pattern = '\bworktrees?\b|\bcheckouts?\b'; Plain = 'local copy' }

        # People and their instructions.
        [pscustomobject]@{ Pattern = '\bcrewmates?\b'; Plain = 'worker' }
        [pscustomobject]@{ Pattern = '\bsecondmates?\b'; Plain = 'second mate' }
        [pscustomobject]@{ Pattern = '\bbriefs?\b'; Plain = 'instructions' }

        # What a session says it can and cannot do. Inflected separately rather
        # than as one stem, because "I can't dispatch" and "dispatching the
        # worker" want different English and a single noun makes one of them
        # ungrammatical.
        [pscustomobject]@{ Pattern = '\bdispatching\b'; Plain = 'starting work' }
        [pscustomobject]@{ Pattern = '\bdispatched\b'; Plain = 'started' }
        [pscustomobject]@{ Pattern = '\bdispatch(?:es)?\b'; Plain = 'start work' }
        [pscustomobject]@{ Pattern = '\bsteering\b'; Plain = 'redirecting' }
        [pscustomobject]@{ Pattern = '\bsteers\b'; Plain = 'redirects' }
        [pscustomobject]@{ Pattern = '\bsteer(?:ed)?\b'; Plain = 'redirect' }
        # NO PLAIN WORD MAY END IN A PREPOSITION THIS FILE STRIPS. "bring the
        # work in" was the first try, and the dangling-preposition rule below -
        # written to tidy up after a REMOVAL - then ate the "in" it had just been
        # handed: "it was brought in." became "it was brought." The rule cannot
        # tell a leftover from a word this table meant, so the table stays clear
        # of them. `Get-FmBridgeVocabulary` has a test that pins this.
        [pscustomobject]@{ Pattern = '\bmerging\b'; Plain = 'landing the work' }
        [pscustomobject]@{ Pattern = '\bmerged\b'; Plain = 'landed' }
        [pscustomobject]@{ Pattern = '\bmerges\b'; Plain = 'lands the work' }
        [pscustomobject]@{ Pattern = '\bmerge\b'; Plain = 'land the work' }

        # Lifecycle.
        [pscustomobject]@{ Pattern = '\bteardowns?\b'; Plain = 'cleanup' }
        [pscustomobject]@{ Pattern = '\btorn\s+down\b'; Plain = 'cleaned up' }
        [pscustomobject]@{ Pattern = '\bpromot(?:e|ed|ion)\b'; Plain = 'carried forward' }

        # Supervision. `stale` and `wedged` take the mild reading on purpose.
        [pscustomobject]@{ Pattern = '\bwatchers?\b'; Plain = 'monitoring' }
        [pscustomobject]@{ Pattern = '\bheartbeats?\b'; Plain = 'sign of life' }
        [pscustomobject]@{ Pattern = '\bstale\b'; Plain = 'quiet for a while' }
        [pscustomobject]@{ Pattern = '\bwedged\b'; Plain = 'stuck' }
        [pscustomobject]@{ Pattern = '\bwakes?\b'; Plain = 'notification' }

        # Tools, including the ones with product names.
        [pscustomobject]@{ Pattern = '\bharness(?:es)?\b|\badapters?\b'; Plain = 'tool' }
        [pscustomobject]@{ Pattern = '\bherdr\b|\btreehouse\b|\borca\b|\bcmux\b'; Plain = 'the tool' }

        # Delivery vocabulary. `no-mistakes` is a mode name, not an outcome, and
        # reads on a panel as a boast about the work rather than a label.
        [pscustomobject]@{ Pattern = '\bdirect[\s-]PR\b'; Plain = 'a pull request' }
        [pscustomobject]@{ Pattern = '\blocal[\s-]only\b'; Plain = 'a local branch' }
        [pscustomobject]@{ Pattern = '\bno[\s-]mistakes(?:[\s-]prod[\s-]only)?\b'; Plain = 'the full checks' }
        [pscustomobject]@{ Pattern = '\byolo\b'; Plain = 'deciding routine things itself' }
    )
}

function ConvertTo-FmBridgePlainText {
    <#
        .SYNOPSIS
        Strip internal machinery out of a line before the captain sees it.

        .DESCRIPTION
        `AGENTS.md` section 9's translation contract is a UI requirement, not a
        chat habit, and piping raw status lines into a panel is exactly the
        mistake it exists to prevent. Observed on screen: file paths, branch
        names, bracketed decision keys, percentage prefixes and line references
        into this repo's own documents.

        This removes the labels that are noise to a reader. It does not pretend
        to be a full translation - a worker writes its own note and only that
        worker knows what it meant - so the honest goal is to strip what is
        certainly internal and leave the sentence alone.

        STRIPPING THE LABELS IS NOT ENOUGH, and that gap shipped once. Removing
        the `done:` prefix and the path out of

            done: PR ready in worktree fm/tg-build

        leaves "PR ready in worktree" on screen, which is still three quarters of
        section 9's forbidden list. Measured on four of five sample lines:
        `worktree`, `crewmate`, `teardown`, `harness`, `watcher`, `heartbeat` and
        the runtime's own product name all reached the panel intact. So the
        vocabulary is translated too, from section 9's own table, and the
        `harness=claude backend=herdr` machinery pairs are dropped whole.

        WORD-FOR-WORD, NEVER SENTENCE-FOR-SENTENCE. Each replacement is the noun
        section 9 names for that term, so the sentence a worker wrote survives
        with its meaning: "crewmate wedged" becomes "worker stuck", not a
        rewritten summary this function is in no position to write. Where section
        9 offers several readings the mildest is used, because overstating a
        worker's note is worse than leaving it flat.

        A URL IS NEVER MACHINERY, and every rule below would happily eat one:
        `https:` reads as a state prefix, and a path segment spelt `docs/` or
        `bin/` reads as a path into this repository. `AGENTS.md` section 9
        requires the full https:// URL of a PR in every mention - and on a phone
        a mangled link is not a cosmetic defect, it is the one thing on screen the
        captain needed to tap. So URLs are masked out first and put back last,
        untouched.

        THE REPLY IS A SURFACE TOO, and it was the one surface this never saw.
        Every panel on the page went through here; the answer beside them did
        not, so the assistant put a process number, the controls, "read-only" and
        "dispatch, steer, or merge" on the same screen the panels had just been
        scrubbed for. `-Prose` is that missing call, and it is the SAME
        translator rather than a second one: one vocabulary, one set of removals,
        one place to add a word.

        WHAT `-Prose` CHANGES, AND WHY ONLY THAT. A status line is one line with
        a label on the front; a reply is paragraphs, bullets and blank lines. So
        prose is translated line by line with the line's own indentation put
        back, and the three cosmetics that only make sense on a status line are
        skipped: the free-form `word:` prefix strip would eat the start of an
        ordinary sentence, the leading-dash trim would eat a bullet, and forcing
        a capital would shout at every wrapped line. The label strip still runs
        in prose for the KNOWN state words, because an assistant quoting
        `blocked: ...` back at the captain is the same leak by another route.

        A NAME THE SCREEN IS SHOWING IS NEVER MACHINERY, and `-Keep` is that
        rule. Caught in the browser, one screen, same moment: the panel row read
        LOCK IDENTITY and the reply beside it called the same job
        "controls-identity", because the vocabulary translated `lock` inside a
        job's own name. That is the exact defect this whole seam exists to end -
        two halves of one screen disagreeing about one thing - reintroduced by
        the cure. So the caller passes the names the screen is displaying and
        they are masked and restored untouched, on the same principle as a URL:
        this translates the words a session CHOSE, never a name it was given.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [switch]$Prose,
        # Names the screen is showing - job names, and anything else the captain
        # reads in one panel and must recognise in the other.
        [string[]]$Keep = @()
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    # MASKED OVER THE WHOLE TEXT, BEFORE ANYTHING IS SPLIT. A URL never spans a
    # line, so doing this once is the same as doing it per line - and it has to
    # happen before the process-number pass below, which would otherwise take
    # `pid` out of a path that happened to contain it.
    $fence = ([char]1).ToString()
    $whole = $Text
    $preserved = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($whole, 'https?://\S+')) {
        if (-not $preserved.Contains($match.Value)) { $preserved.Add($match.Value) }
    }
    # The longest name first, so a job called `lock` cannot mask half of a job
    # called `lock-identity` and leave the rest to be translated.
    foreach ($name in (@($Keep | Where-Object { $_ }) | Sort-Object -Property Length -Descending)) {
        foreach ($match in [regex]::Matches($whole, [regex]::Escape($name), 'IgnoreCase')) {
            # The matched text, not the name as given: the session may have
            # written it in its own case and that is what the captain is reading.
            if (-not $preserved.Contains($match.Value)) { $preserved.Add($match.Value) }
        }
    }
    for ($i = 0; $i -lt $preserved.Count; $i++) {
        $whole = $whole.Replace($preserved[$i], "$fence$i$fence")
    }

    # A process number, which has no plain word to become - the captain has no
    # use for one and nothing to do with it. Removed rather than translated, and
    # the parenthesised form goes with its brackets so the sentence does not
    # close on an empty pair.
    #
    # BEFORE THE SPLIT, and that is not tidiness. The reply that shipped this
    # wrapped mid-term - "(pid\n25876)" - so a per-line pass took the word `pid`
    # and left the number sitting in the captain's brackets, which is the digit
    # they were never meant to see with the label that explained it gone. `\s`
    # crosses a line break; a line-by-line pass cannot.
    $whole = $whole -replace '\s*\(\s*(?:pid|process\s*id)s?\s*[:#]?\s*\d+\s*\)', ''
    $whole = $whole -replace '\b(?:pid|process\s*id)s?\s*[:#]?\s*\d+\b', ''
    $whole = $whole -replace '\b(?:pid|process\s*id)s?\b', ''

    # A status line stays ONE blob, exactly as before. Only prose is split, so
    # nothing about the panel path changes shape here.
    $inputLines = if ($Prose) { @($whole -split '\r?\n') } else { @($whole) }
    $out = [System.Collections.Generic.List[string]]::new()

    foreach ($rawLine in $inputLines) {
        if ([string]::IsNullOrWhiteSpace($rawLine)) { $out.Add(''); continue }

        # Indentation carries meaning in prose - a nested bullet under a parent -
        # and the whitespace collapse below would flatten it. Held aside and put
        # back, the same trick the URLs get.
        $indent = ''
        $s = $rawLine
        if ($Prose -and $s -match '^(\s+)') { $indent = $Matches[1]; $s = $s.Substring($indent.Length) }

        if ($Prose) {
            # Named states only. The status line's `[a-z-]+:` would take "note:",
            # "example:" and the first word of any sentence that happens to end
            # in a colon with it.
            $s = $s -replace '^\s*(?:working|blocked|paused|done|failed|needs-decision|resolved|signal|check|stale|heartbeat)\s*:\s*', ''
            # THE PAGE SHOWS TEXT, NOT MARKDOWN, AND THE VOICE READS IT ALOUD.
            # Seen on screen: "- **lock-identity** - 75%, working", asterisks and
            # all, because a reply is set as text rather than parsed. Emphasis
            # markers and heading hashes are noise on the panel and worse than
            # noise spoken, so they go. The bullet itself stays - it reads as a
            # list either way.
            $s = $s -replace '\*\*([^*]+)\*\*', '$1'
            $s = $s -replace '__([^_]+)__', '$1'
            $s = $s -replace '^\s*#{1,6}\s+', ''
        } else {
            $s = $s -replace '^\s*[a-z-]+\s*:\s*', ''      # the state prefix
        }
        $s = $s -replace '\[\s*\d{1,3}\s*%\s*\]\s*', ''     # a percentage prefix
        $s = $s -replace '\[key=[^\]]+\]\s*', ''            # a decision key

        # A REMOVAL AT THE HEAD OF A LINE TAKES THE SUBJECT WITH IT, and the
        # rules below cannot tell that from taking a stray token. Measured
        # against the records that produced them:
        #
        #     FmLock.Tests.ps1 is through          -> Is through
        #     tests/FmBridge.Tests.ps1 needs a case -> Needs another case
        #
        # A summary mangled into nonsense is worse than one carrying a little
        # jargon: jargon can be decoded and nonsense cannot, and the captain
        # cannot tell a mangled note from a worker that wrote nonsense. So a
        # name at the head leaves a noun behind rather than a hole. Only at the
        # head, and only when a sentence follows - a line that is nothing but a
        # path has no sentence worth saving and still goes.
        $s = $s -replace '^\s*(?:[A-Za-z0-9_.-]+\.(?:md|ps1|json|yml)|(?:data|state|docs|module|bin|tests|ui)/[^\s,;]+)(?:\s+\d+(?:-\d+)?)?\s+', 'that file '
        $s = $s -replace '^\s*fm/[^\s,;]+\s+', 'that branch '

        # "report at <path>" reads as a finished report when the path ENDS the
        # line, and as a subject when the sentence carries on. Answering both
        # with "report ready" produced "Report ready is ready".
        $s = $s -replace '\breport at \S+$', 'report ready'
        $s = $s -replace '\breport at \S+', 'the report'
        $s = $s -replace '\bat (?:data|state|docs|module|bin|tests)/\S+', ''
        $s = $s -replace '\b(?:data|state|docs|module|bin|tests|ui)/[^\s,;]+', ''
        $s = $s -replace '\bin branch \S+', ''              # a branch name
        $s = $s -replace '\bfm/[^\s,;]+', ''
        $s = $s -replace '\b[A-Za-z0-9_.-]+\.(?:md|ps1|json|yml)\b(?:\s+\d+(?:-\d+)?)?', ''
        # The machinery pairs a status line carries verbatim. Named rather than
        # matched as any `word=value`, because a worker's own note may legitimately
        # contain one and eating that would lose meaning rather than jargon.
        $s = $s -replace '\b(?:harness|backend|runtime|adapter|window|worktree|project|model|effort|kind|mode|yolo|tasktmp|endpoint_task_id|treehouse_lease_id)=\S+', ''

        foreach ($rule in (Get-FmBridgeVocabulary)) {
            $s = [regex]::Replace($s, $rule.Pattern, $rule.Plain, 'IgnoreCase')
        }

        # LAST OF THE REMOVALS, AFTER THE VOCABULARY, and the order is the point: a
        # stripped token leaves the word that introduced it dangling, and every pass
        # above can leave one behind. "Writing the test in fm/fix-signin" became
        # "writing the test in" - visibly broken English rather than merely terse, on a
        # phone, where the captain cannot go and look at what was meant. Only a
        # preposition at the very end or immediately before punctuation goes; anything
        # with a word after it still has its object.
        $s = $s -replace '\s+(?:in|on|at|to|from|into|under|via|see)\s*([,;.])', '$1'
        $s = $s -replace '\s+(?:in|on|at|to|from|into|under|via|see)\s*$', ''
        $s = $s -replace '\s{2,}', ' '
        $s = $s -replace '\s+([,;.])', '$1'
        if ($Prose) {
            $s = $s.TrimEnd()
        } else {
            $s = $s.Trim().Trim('-', ';', ',').Trim()
            if ($s) { $s = $s.Substring(0, 1).ToUpper() + $s.Substring(1) }
        }

        for ($i = 0; $i -lt $preserved.Count; $i++) {
            $s = $s.Replace("$fence$i$fence", $preserved[$i])
        }
        $out.Add("$indent$s")
    }

    if (-not $Prose) { return $out[0] }

    # A line the translation emptied leaves a hole where a sentence was, and
    # three blank lines in a row read as the answer having been cut off. Runs
    # are closed up to one.
    (($out -join "`n") -replace '(?:[ \t]*\n){3,}', "`n`n").Trim()
}

function Remove-FmBridgeRepetition {
    <#
        .SYNOPSIS
        Collapse a reply that says the same thing several times over.

        .DESCRIPTION
        WHAT THIS IS FOR. An internal mechanism that keeps firing does not get to
        keep talking. Observed: a supervision event re-fired while the session
        could do nothing about it, the session was continued after each one, and
        the eight near-identical answers that produced arrived as a single reply
        and stacked up on the captain's screen - "the guard is firing again",
        "same guard, same answer", "nothing has changed". A screen that repeats
        itself while nothing changes trains the captain to stop reading it, which
        costs far more than the one message it was trying to deliver.

        WHY THE REPLY AND NOT THE EVENT. The event belongs to supervision, which
        is shared with every terminal session and is not this seam's to change.
        What IS this seam's is the boundary: whatever the session produced, only
        one voice reaches the captain, and it does not stammer.

        TWO RULES, AND ONLY TWO. A piece whose normalised form has already been
        said is dropped wherever it appears. A piece that is a near-repeat of the
        one before it is dropped as well, measured as shared-word overlap - the
        eight messages differed by a word or two each, so exact matching alone
        would have let all eight through.

        ADJACENT ONLY, for the near-repeat rule. A long answer that returns to a
        theme three paragraphs later is developing an argument, not stammering,
        and cutting that would lose the captain real content. Adjacency is what
        separates the two, and it is the conservative reading: this drops less
        than it could rather than more.

        THE PIECE IS A SENTENCE, NOT A LINE, and that is the captain's finding.
        A line-by-line pass is blind to the shape they actually hit, which was
        one paragraph saying one thing twice in a row:

            ... I can see this work but cannot start or stop any of it from here.
            I can see the work but cannot start or stop anything from here.

        Line structure is still preserved - sentences are put back on the line
        they came from, and a line left with nothing goes - so an answer keeps
        its paragraphs and its bullets.

        WHERE THE THRESHOLD CAME FROM. That observed pair shares eleven of the
        seventeen distinct words between them, which is 0.65, so a rule set at
        0.7 watched it go past. It is calibrated on the real duplicate rather
        than on a round number, and every list and stepped answer in this file's
        tests sits below 0.35 - there is a wide gap between the two, not a fine
        line being walked.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a shortened copy of a string; what it removes is duplicate text, not anything on the machine.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        # Shared-word overlap above which an adjacent sentence is the same
        # sentence said again. See WHERE THE THRESHOLD CAME FROM above.
        [ValidateRange(0.0, 1.0)][double]$Similarity = 0.6
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $kept = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $previousWords = $null

    foreach ($line in ($Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { $kept.Add(''); continue }

        # Split so a terminator stays with the sentence it ends, because a
        # sentence put back without its full stop reads as a truncation.
        $survivors = [System.Collections.Generic.List[string]]::new()
        foreach ($piece in [regex]::Split($line, '(?<=[.!?])\s+')) {
            if ([string]::IsNullOrWhiteSpace($piece)) { continue }

            # Punctuation and case differ between two sayings of one thing, so
            # neither counts towards whether it IS one thing.
            #
            # DIGITS DO COUNT, and dropping them was a real over-collapse: "Step
            # 1 complete." and "Step 2 complete." normalise to the same words
            # once the numbers go, and the second - a different step, real
            # content the captain needs - disappeared. A number is often the
            # only thing that distinguishes two pieces of an answer. The
            # near-repeat rule below is what absorbs small wording differences;
            # this one stays literal.
            $normal = ((($piece.ToLowerInvariant() -replace '[^a-z0-9 ]', ' ') -replace '\s{2,}', ' ')).Trim()
            if (-not $normal) { $survivors.Add($piece.Trim()); continue }

            if (-not $seen.Add($normal)) { continue }

            $words = [System.Collections.Generic.HashSet[string]]::new([string[]]($normal -split ' '))
            if ($null -ne $previousWords -and $words.Count -and $previousWords.Count) {
                $shared = [System.Collections.Generic.HashSet[string]]::new($words)
                $shared.IntersectWith($previousWords)
                $union = [System.Collections.Generic.HashSet[string]]::new($words)
                $union.UnionWith($previousWords)
                if (($shared.Count / [double]$union.Count) -ge $Similarity) { continue }
            }

            $previousWords = $words
            $survivors.Add($piece.Trim())
        }

        # A line whose every sentence was a repeat had nothing of its own left
        # to say, so it goes rather than leaving a blank where a paragraph was.
        if (-not $survivors.Count) { continue }

        # The line's own indentation survives with it - a nested bullet under a
        # parent means something, and rebuilding from the trimmed pieces alone
        # would flatten it.
        $indent = if ($line -match '^(\s+)') { $Matches[1] } else { '' }
        $kept.Add($indent + ($survivors -join ' '))
    }

    (($kept -join "`n") -replace '(?:[ \t]*\n){3,}', "`n`n").Trim()
}

function Test-FmBridgeSessionCanAct {
    <#
        .SYNOPSIS
        Can the session this bridge hosts change anything, or only look?

        .DESCRIPTION
        Asked by the bridge, never by the session, and that is the point. The
        session's own answer to this question is what leaked the arrangement onto
        the captain's screen in the first place - a process number, who held
        what, and a verb list of what it could not do. The bridge knows the same
        fact from one comparison and can say it in one sentence of English.

        THE COMPARISON. This home is held by exactly one live session at a time,
        and the holder is recorded. The hosted session can act when the holder is
        the hosted session; anything else - held elsewhere, not held, unreadable -
        means it can look and nothing more. Unreadable counts as cannot, because
        promising the captain an action this cannot deliver is the worse mistake.

        NOT A LOCK CHANGE. This reads the same record `Invoke-FmLock -Status`
        reads and writes nothing; how the record is taken, broken or renewed is
        untouched.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HomePath,
        [int]$SessionProcessId = 0
    )

    if ($SessionProcessId -le 0) { return $false }
    $status = $null
    try { $status = Get-FmSessionLockStatus -StatePath (Join-Path $HomePath 'state') }
    catch {
        Write-Debug "bridge: could not read who holds this home - $($_.Exception.Message)"
        return $false
    }
    if ($null -eq $status -or $status.State -ne 'held') { return $false }
    if ($null -eq $status.ProcessId) { return $false }
    return ([int]$status.ProcessId -eq $SessionProcessId)
}

function Test-FmBridgeVoiceAllowed {
    <#
        .SYNOPSIS
        May this screen speak out loud, or must it stay silent?

        .DESCRIPTION
        THIS EXISTS BECAUSE THE SCREEN SPOKE ON THE CAPTAIN'S MACHINE WITH NO
        WINDOW OPEN. `ui/bridge.html` called the browser's speech synthesis on
        every reply, unconditionally, and a page driven for a check runs in a
        browser with nothing on screen to find or silence - so three copies of it
        talked out of a machine whose owner could see no browser at all.

        IT IS THE CONTRACT, NOT A PREFERENCE. `AGENTS.md` section 9: the voice
        channel "is off until the captain creates `config/voice`, and nothing
        calls it by itself". A page that speaks by itself, through a channel that
        was never switched on, is that rule broken by the one surface loud enough
        to be noticed across a room.

        THE GATE HAS ONE OWNER and it is not this function. `Get-FmBridgeVoice`
        reads `config/bridge-voice` and decides; this asks it on the browser's
        behalf, the same way Test-FmBridgeSessionCanAct asks the lock reader
        rather than parsing the record itself. A second gate would be a second
        thing to forget.

        WHY THAT FILE AND NOT `config/voice`, WHICH THIS FIRST USED. Two things
        the captain asked for outright: a mute they can see and press on the
        screen, and one that survives a restart - "where is setting on screen",
        and then "a visible mute the captain controls, effective at once,
        remembered". `config/voice` cannot be that. It has no control on the
        page, and it is the switch for the MACHINE's voice: pressing a button on
        the screen would have turned `bin/fm-say.ps1` on for the whole home, and
        silencing the screen would have silenced a supervision alert the captain
        never asked to lose. So the page gets its own one-word file, written by
        the toggle beside the dock, and the two channels stay separate exactly as
        `docs/voice-windows.md` describes them.

        WHAT DID NOT CHANGE is the rule this function was written for: OFF is the
        default, absence means off, and nothing here speaks because a page
        happened to load. `AGENTS.md` section 9's "off until the captain turns it
        on" is satisfied by a switch that starts off and takes a deliberate press
        - not by which file records the press.

        SILENT WHEN IT CANNOT TELL. Anything unreadable, missing, or thrown
        counts as off, because being wrong in that direction is a quiet screen
        and being wrong in the other is this defect again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HomePath = '')

    try {
        $state = if ($HomePath) { Get-FmBridgeVoice -HomePath $HomePath } else { Get-FmBridgeVoice }
    } catch {
        Write-Debug "bridge: could not read whether the screen may speak - $($_.Exception.Message)"
        return $false
    }
    return ($state -eq 'on')
}

function Get-FmBridgeRoute {
    <#
        .SYNOPSIS
        How a thing the captain asked for actually gets done from this screen.

        .DESCRIPTION
        THE CAPTAIN THREW OUT THE SENTENCE THIS REPLACES, and they were right.
        What used to sit here was one honest line - "I can see the work but
        cannot start or stop anything from here" - and their answer to it was
        that a system worth talking to never says that at all:

            > as smart AI system it never should say this line instead it
            > should give the solution of that or way to do that

        A limitation is an explanation of this system's own arrangement wearing
        the clothes of an answer. The captain did not ask how the screen is put
        together. They asked for something, and they get either the thing or the
        route to it.

        SO THIS RETURNS A ROUTE, NEVER A REFUSAL. Softening the confession would
        have been the same mistake with better manners, and deleting it and
        saying nothing would have left the captain asking twice. What the screen
        owes them is the next step, in their own words.

        WHAT THE ROUTE ACTUALLY IS, and it is a real one rather than a polite
        deferral: starting, stopping and steering work happens in the captain's
        own firstmate window, which is open on this machine whenever this screen
        is the one that cannot do it - that is the same fact, read from the other
        side. So the route names that window and offers to say exactly what to
        ask for there.

        RETURNED TO THE SESSION, NOT TO THE SCREEN. This is guidance in the turn
        prompt; the session writes the actual sentence, in the captain's
        language, shaped to what they asked. A canned line appended underneath
        an answer is what produced the same statement twice in one reply.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][bool]$CanAct)

    if ($CanAct) { return '' }
    @(
        'Starting, stopping and steering work happens in the firstmate window the captain'
        'already has open on this machine, not here. That is the route, and it is the only'
        'thing you may say about it: name what they should ask for there, or offer to write'
        'it out for them, and carry on with everything you CAN do from here.'
    ) -join "`n"
}

function Split-FmBridgeReply {
    <#
        .SYNOPSIS
        One turn's answer, split into what is READ and what is SPOKEN.

        .DESCRIPTION
        THE SAME TEXT CANNOT BE BOTH. A reply written for the screen is long,
        dense, and front-loads its qualifications, because the captain can go
        back over it. Spoken, that is a paragraph they cannot re-read, arriving
        at the speed the engine chooses. `AGENTS.md` section 9 already says the
        spoken channel binds harder for exactly that reason, and the biggest
        lever on how mechanical this screen sounds is simply not to speak the
        thing that was written for reading.

        So the session is asked to end its reply with one `SPOKEN:` line - see
        Get-FmBridgeSpeechContract, which is the instruction it is given - and
        this takes that line as the spoken form and removes it from the written
        one. The captain never sees the marker and never hears the essay.

        WHEN THERE IS NO MARKER the answer is DERIVED rather than refused: an
        older session, a resumed one, or a turn that simply forgot still has to
        be speakable. The derivation is the honest one available without a model
        - the opening sentences, prepared for speech and bounded - and it is
        strictly better than reading the whole reply aloud.

        Everything spoken goes through ConvertTo-FmSpokenText whichever route it
        took, INCLUDING a marker the session wrote itself: a model asked for
        plain words still reaches for a path or a bold phrase, and one owner for
        "what is spoken" is worth more than trusting the instruction.

        .PARAMETER Reply
        The turn's raw text, as the session emitted it.

        .EXAMPLE
        Split-FmBridgeReply -Reply "Four are running.`nSPOKEN: Four jobs, nothing waiting."
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reply,
        # Names the panel is SHOWING, passed straight to the translator so a job
        # id survives it intact. Same argument, same reason, as the caller's.
        [string[]]$Keep = @()
    )

    $result = [pscustomobject]@{ Written = ''; Spoken = ''; Marked = $false }
    if ([string]::IsNullOrWhiteSpace($Reply)) { return $result }

    $text = $Reply -replace "`r`n", "`n" -replace "`r", "`n"
    $marked = ''
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`n")) {
        # The LAST marker wins. A session that restates it has changed its mind,
        # and the correction is the line the captain would expect to hear.
        if ($line -match '^\s*(?:\*\*)?SPOKEN(?:\*\*)?\s*:\s*(.*)$') { $marked = $Matches[1].Trim(); continue }
        $kept.Add($line)
    }

    # THE MARKER COMES OFF BEFORE THE TRANSLATOR RUNS. ConvertTo-FmBridgePlainText
    # strips a leading `word:` state prefix and its match is case-insensitive, so
    # a translated reply would have lost the very line that says what to speak.
    $written = ConvertTo-FmBridgePlainText -Text (($kept -join "`n").Trim()) -Prose -Keep $Keep

    # AND THE SPOKEN HALF IS TRANSLATED TOO, harder than the written one is.
    # AGENTS.md section 9 says so outright, because the captain cannot re-read a
    # spoken sentence to work out what a word meant. The order is translate then
    # prepare: the translation puts plain English in, and the preparation has the
    # last word on how the symbols in it are pronounced.
    $candidate = if ($marked) { ConvertTo-FmBridgePlainText -Text $marked -Prose -Keep $Keep } else { Get-FmSpokenLead -Text $written }
    $bounded = Get-FmVoiceSpeechText -Message $candidate

    [pscustomobject]@{
        Written = $written
        Spoken  = $bounded.Text
        Marked  = [bool]$marked
    }
}

function Get-FmSpokenLead {
    <#
        .SYNOPSIS
        The opening of a written answer, as much of it as is worth hearing.

        .DESCRIPTION
        The fallback for a reply that carries no spoken form of its own. It
        cannot reorder an answer to lead with the point - only the session that
        wrote it can do that - so it takes the sentences the answer opens with
        and stops at the first full stop past a comfortable length.

        Two sentences, not one: a single sentence often lands mid-thought
        ("Two things went wrong.") and leaves the captain with the fact that
        there is news and none of the news.

        .PARAMETER Text
        The written answer.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $prepared = ConvertTo-FmSpokenText -Text $Text
    if (-not $prepared) { return '' }

    $sentences = [regex]::Split($prepared, '(?<=[.!?])\s+')
    $lead = ''
    $taken = 0
    foreach ($sentence in $sentences) {
        if ($taken -ge 2) { break }
        $next = if ($lead) { "$lead $sentence" } else { $sentence }
        # Past the bound the engine would cut it anyway, and a cut sentence is
        # worse than one fewer sentence.
        if ($taken -ge 1 -and $next.Length -gt (Get-FmVoiceMaxLength)) { break }
        $lead = $next
        $taken++
    }
    $lead
}

function Get-FmBridgeSpeechContract {
    <#
        .SYNOPSIS
        The instruction the hosted session is started with, so its answers can
        be heard as well as read.

        .DESCRIPTION
        Appended to the session's system prompt ONCE at start rather than
        prepended to every turn, because it is a standing property of this
        channel and paying for it per message would be paying for it forever.

        It states the WIRE FORMAT and nothing else. What a spoken message may
        say is `AGENTS.md` section 9's, and this points at it rather than
        restating it - two copies of that rule would drift the moment one was
        edited.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @(
        'You are answering on the bridge screen, where the captain READS your reply and HEARS it at the same time.'
        'End every reply with one final line beginning "SPOKEN:" holding the same answer said out loud.'
        'That line is the only part spoken, so it is one or two sentences, under 200 characters, the answer first, and it obeys AGENTS.md section 9 more strictly than the written reply does: no markup, no file paths, no URLs, no internal vocabulary.'
        'Everything above that line is what is read, and it keeps the full substance the captain needs - never shorten the written answer to make the spoken one easier.'
        'Never run bin/fm-say.ps1 or bin/fm-ask.ps1 here: the screen decides whether anyone is listening, and it is already refused for this session.'
    ) -join ' '
}

function Get-FmListenMode {
    <#
        .SYNOPSIS
        How the microphone listens on this home: 'push' or 'continuous'.

        .DESCRIPTION
        `config/listen-mode` holds one word, in the same shape as the rest of
        `config/` - see `AGENTS.md` section 2.

        PUSH IS THE DEFAULT AND IT IS THE DEFAULT ON EVERY FAILURE. Absent,
        unreadable, or holding a word this does not recognise all answer 'push'.
        The two modes are not equally safe: continuous holds the microphone open
        with nobody's hand on it, and arriving there by way of a typo is not a
        thing this may do.

        .PARAMETER HomePath
        Which home to read. Defaults to this session's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)

    $homeArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $homeArgs['HomePath'] = $HomePath }
    Get-FmBridgeChoice -Name 'listen-mode' -Allowed @('push', 'continuous') -Default 'push' @homeArgs
}

function Set-FmListenMode {
    <#
        .SYNOPSIS
        Record how the microphone listens. Returns a verdict; never throws.

        .DESCRIPTION
        Written to `config/listen-mode` so the choice survives a reload of the
        page AND a restart of the bridge - a setting that resets is not a
        setting. An unrecognised mode is REFUSED rather than written, because
        the reader treats anything it does not know as push and the captain
        would be left with a screen that says continuous and a microphone that
        is not.

        .PARAMETER Mode
        'push' or 'continuous'.

        .PARAMETER HomePath
        Which home to write. Defaults to this session's.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Mode,
        [string]$HomePath
    )

    $homeArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $homeArgs['HomePath'] = $HomePath }

    if (-not $PSCmdlet.ShouldProcess('config/listen-mode', "set the listening mode to $Mode")) {
        return [pscustomobject]@{ Ok = $true; Mode = (Get-FmListenMode @homeArgs); Error = '' }
    }
    $set = Set-FmBridgeChoice -Name 'listen-mode' -Value $Mode -Allowed @('push', 'continuous') @homeArgs
    if (-not $set.Ok) {
        # The mode reported back is the one still in force, not the one asked
        # for: a page that shows what it wanted rather than what happened is how
        # a refused save becomes a setting the captain believes they made.
        return [pscustomobject]@{
            Ok    = $false
            Mode  = (Get-FmListenMode @homeArgs)
            Error = $set.Error
        }
    }
    [pscustomobject]@{ Ok = $true; Mode = $set.Value; Error = '' }
}

function Get-FmBridgeVoice {
    <#
        .SYNOPSIS
        Does the browser screen speak its answers: 'on' or 'off'.

        .DESCRIPTION
        `config/bridge-voice`, one word, in the same shape as the rest of
        `config/`.

        OFF IS THE DEFAULT, AND IT IS THE DEFAULT BECAUSE OF WHAT HAPPENED.
        This page spoke at the captain twice with no browser anywhere they could
        see - it was being driven HEADLESS for checks, so the window they would
        have closed did not exist - and the only thing that stopped it was the
        processes behind it being killed. There was no switch in front of
        `speechSynthesis` at all. A surface that can make noise starts silent
        after that, and it starts silent for the same reason `AGENTS.md`
        section 9 has the machine's own voice off until `config/voice` is
        created: a machine that talks without being asked is a defect, not a
        feature with a good default. One click on the screen turns it on, and
        the choice is kept.

        SEPARATE FROM config/voice ON PURPOSE. That file governs the machine's
        own voice, for `bin/fm-say.ps1` and `bin/fm-ask.ps1` on a home with no
        browser anywhere near it. This one governs a page, which stops existing
        the moment the captain closes it. Two channels, two switches, and the
        bridge's hosted session is refused the first one outright - see
        Test-FmVoiceSuppressed.

        .PARAMETER HomePath
        Which home to read. Defaults to this session's.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HomePath)

    $homeArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $homeArgs['HomePath'] = $HomePath }
    Get-FmBridgeChoice -Name 'bridge-voice' -Allowed @('on', 'off') -Default 'off' @homeArgs
}

function Set-FmBridgeVoice {
    <#
        .SYNOPSIS
        Record whether the browser screen speaks. Returns a verdict.

        .PARAMETER State
        'on' or 'off'.

        .PARAMETER HomePath
        Which home to write. Defaults to this session's.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [string]$HomePath
    )

    $homeArgs = @{}
    if ($PSBoundParameters.ContainsKey('HomePath') -and $HomePath) { $homeArgs['HomePath'] = $HomePath }

    if (-not $PSCmdlet.ShouldProcess('config/bridge-voice', "turn the screen's voice $State")) {
        return [pscustomobject]@{ Ok = $true; State = (Get-FmBridgeVoice @homeArgs); Error = '' }
    }
    $set = Set-FmBridgeChoice -Name 'bridge-voice' -Value $State -Allowed @('on', 'off') @homeArgs
    if (-not $set.Ok) {
        return [pscustomobject]@{
            Ok    = $false
            State = (Get-FmBridgeVoice @homeArgs)
            Error = $set.Error
        }
    }
    [pscustomobject]@{ Ok = $true; State = $set.Value; Error = '' }
}

function Get-FmStableCheckout {
    <#
        .SYNOPSIS
        The checkout a captain-facing instruction may name: this one, or the
        primary one when this is a disposable copy.

        .DESCRIPTION
        THE BRIDGE TELLS THE CAPTAIN TO POINT THEIR DICTATION APP AT A FILE, and
        that instruction is only worth giving if the file is still there
        tomorrow. Run from a worker's isolated copy the obvious answer -
        `$PSScriptRoot` - names a directory that is deleted when that piece of
        work finishes, and the captain would have configured their app to point
        at nothing. Observed on the captain's own screen.

        A linked git worktree knows where its primary checkout is: its own git
        directory sits under the common one, and the common one's parent is the
        durable copy. That is the answer used, and only when the file the
        instruction names is actually there.

        Anything unreadable answers with the checkout it was given. A guess that
        names a directory which does not exist would be worse than a path that
        is merely short-lived.

        .PARAMETER Root
        The running checkout.

        .PARAMETER RequiredFile
        A path, relative to a checkout, that the answer must contain. Without it
        this would happily name a primary checkout that has been moved away.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Root,
        [string]$RequiredFile = ''
    )

    if ([string]::IsNullOrEmpty($Root)) { return '' }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $Root }

    $gitDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--absolute-git-dir')
    $commonDir = Get-FmGitOutput -Directory $Root -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir')
    if (-not $gitDir -or -not $commonDir) { return $Root }
    # Equal means this IS the primary checkout, which is already the answer.
    if (Test-FmPathEqual -Left $gitDir -Right $commonDir) { return $Root }

    $primary = Split-Path -Parent $commonDir
    if (-not $primary -or -not (Test-Path -LiteralPath $primary -PathType Container)) { return $Root }
    if ($RequiredFile -and -not (Test-Path -LiteralPath (Join-Path $primary $RequiredFile) -PathType Leaf)) { return $Root }
    $primary
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
                    $note = ConvertTo-FmBridgePlainText -Text $last -Keep $id

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
                                Question = ConvertTo-FmBridgePlainText -Text $body -Keep $id
                            }
                        } elseif ($s -match '^\s*resolved\s*:') {
                            $key = if ($s -match '\[key=([^\]]+)\]') { $Matches[1] } else { 'default' }
                            $decisions = @($decisions | Where-Object { -not ($_.Task -eq $id -and $_.Key -eq $key) })
                        }
                    }

                    foreach ($l in ($lines | Select-Object -Last 4)) {
                        $plain = ConvertTo-FmBridgePlainText -Text ([string]$l) -Keep $id
                        if (-not $plain) { continue }
                        $activity += [pscustomobject]@{
                            Task = $id
                            Text = $plain
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
        House     = @(Get-FmBridgeHouseWork)
        At        = (Get-Date).ToString('HH:mm:ss')
    }
}

function New-FmBridgeTurnPrompt {
    <#
        .SYNOPSIS
        One captain turn, with the reading the panel beside it is painting.

        .DESCRIPTION
        THE DEFECT THIS ENDS. One screen, one moment, two answers to one
        question: the panel listed three jobs with live percentages while the
        reply beside it said nothing was under way and then explained, in
        machinery, why it could not see any. Both halves were being honest. The
        panel reads the durable records; the assistant was answering from its own
        much narrower view of this home, which it had not been able to open. A
        screen arguing with itself destroys trust in both halves at once, and the
        captain has no way to tell which half to believe.

        THE FIX IS ONE READING, RENDERED TWICE. Not two read paths that agree by
        convention - two renderings of the SAME object, taken at the same instant
        by the same call. `Get-FmBridgeFleet` is already the panel's source; this
        hands that very reading to the session with the captain's words, so the
        answer is drawn from what is on screen rather than from a second look
        that could differ in timing, in parsing, or in what it was allowed to
        see. Drift is not discouraged here, it is unavailable.

        WHY NOT SIMPLY FORBID THE SESSION FROM SPEAKING ABOUT THE FLEET. It was
        the other honest option and it is worse. The captain talks to this screen
        precisely to ask what is happening; an assistant that must answer "I
        cannot say" to the main question is a worse screen than one that can
        answer it, and the two halves would still disagree the moment the captain
        read the panel and the reply together.

        WHAT GOES IN IS WHAT THE PANEL SHOWS, AND NO MORE. The job names are
        here because the panel prints them and the captain must be able to match
        a reply to a row. A decision's record handle is NOT, and used to be: the
        session repeated it back as "the carrier question", which names a thing
        the captain has never seen. Anything in this prompt can end up in the
        answer, so the rule is not "send it and ask for discretion" - it is do
        not send what the captain must not read.

        NOT A SUBSTITUTE FOR THE TRANSLATOR. Asking the model for plain words is
        a request; `ConvertTo-FmBridgePlainText -Prose` on the way out is the
        guarantee. Both, because a request is not a contract.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Composes an in-memory string from a reading it was handed and changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Fleet,
        [bool]$CanAct = $true,
        # A change of address made since the last turn, carried along rather than
        # given a blocking round trip of its own.
        [string]$Address = ''
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[THE SCREEN BESIDE YOUR REPLY, read at ' + [string]$Fleet.At + ' from the durable records.')
    $lines.Add('This is what the captain can see right now, so it is what you are answering from.')

    $tasks = @($Fleet.Tasks)
    if ($tasks.Count) {
        $lines.Add("under way ($($tasks.Count)):")
        foreach ($t in $tasks) {
            $shown = if ($null -eq $t.Percent) { 'no percentage given' } else { "$($t.Percent)%" }
            $note = if ($t.Note) { " - $($t.Note)" } else { '' }
            $lines.Add("  $($t.Id): $shown, $($t.State)$note")
        }
    } else {
        $lines.Add('under way: nothing on the captain projects')
    }

    $house = @($Fleet.House)
    if ($house.Count) {
        $lines.Add('on this machine: ' + (($house | ForEach-Object { "$($_.Name) ($($_.Detail))" }) -join '; '))
    }

    $decisions = @($Fleet.Decisions)
    if ($decisions.Count) {
        $lines.Add("waiting on the captain ($($decisions.Count)):")
        # NO RECORD HANDLE HERE, and it was in this line until the browser
        # showed why. The reading used to carry each decision's exact key so the
        # session could close it; the session then told the captain that
        # tg-route was "still held up on the carrier question" - `carrier` being
        # the handle, a word that means nothing to them and is not on any panel.
        # Asking the model to hold a secret is not a design. The session reads
        # the record for the handle at the moment it actually writes to it,
        # which is the only moment it needs one, so it is never carrying a word
        # it must remember not to say.
        foreach ($d in $decisions) { $lines.Add("  $($d.Task): $($d.Question)") }
    } else {
        $lines.Add('waiting on the captain: nothing')
    }

    $lines.Add('')
    $lines.Add('You are the one voice of this screen. Answer from the reading above: never say nothing')
    $lines.Add('is under way when it lists work, and never give a count or a percentage that differs')
    $lines.Add('from it. If you have not looked yourself, the reading above is the answer.')
    # Observed in a headed browser: asked for plain sentences, the session
    # described the jobs by position - "one is at 75 percent, another at 25" -
    # which the captain then has to match to the panel by arithmetic. Agreeing
    # with the panel is worth little if the captain cannot see that it agrees.
    $lines.Add('Call each piece of work by the name the reading gives it, so the captain can match')
    $lines.Add('what you say to the row beside it.')
    # NEVER A LIMITATION AS THE ANSWER. The captain's own ruling on the sentence
    # that used to go here: a system worth talking to gives the solution or the
    # way to do it, never a confession about itself. Get-FmBridgeRoute owns the
    # route; this only insists it is what gets said.
    $lines.Add('NEVER answer with something you cannot do. Not as the reply, not as a closing line,')
    $lines.Add('not softened. If the captain asks for something this screen does not do directly,')
    $lines.Add('answer with how it gets done - the next step, or what you will do about it - and')
    $lines.Add('then do everything about it you can. If there is no route at all, say what IS')
    $lines.Add('possible instead.')
    # "can you do it yourself? yes or no" came back as "No." - responsive, and
    # still a limitation standing alone as the whole reply. A yes-or-no is the
    # captain asking for brevity, not for a dead end.
    $lines.Add('This holds even when the captain asks for a yes or a no: answer them, and put the')
    $lines.Add('next step in the same breath rather than leaving a bare no on the screen.')
    $route = Get-FmBridgeRoute -CanAct $CanAct
    if ($route) { $lines.Add($route) }
    $lines.Add('Never describe how this screen is arranged and never name anything internal: no process')
    $lines.Add('numbers, no lock, no read-only, no dispatch, steer or merge, no checkout, no uncommitted')
    $lines.Add('changes, no file or branch names. Say nothing twice: not the same point in two')
    $lines.Add('sentences, and not a line you have already sent in this conversation.')
    # The page sets a reply as text and the voice reads it aloud, so markdown
    # arrives as literal asterisks in both.
    $lines.Add('Answer in plain sentences. No markdown, no bold, no headings.]')
    if ($Address) {
        $lines.Add("[Address me as '$Address' from now on, in every reply.]")
    }
    $lines.Add('')
    $lines.Add($Text)

    $lines -join "`n"
}

function Get-FmBridgeHouseWork {
    <#
        .SYNOPSIS
        What this machine is doing for itself, as distinct from work on the
        captain's projects.

        .DESCRIPTION
        THE CAPTAIN ASKED "WHAT IS RUNNING" AND THE SCREEN SAID NOTHING while
        four things were. Both answers were true and that is the whole problem:
        the panel counts work on the captain's projects, there was genuinely
        none, and it reported that as if it were the whole question. A screen
        that quietly narrows the question it answers is worse than one that
        answers nothing, because it is believed.

        KEPT SEPARATE FROM Tasks ON PURPOSE. Folding these in would show "4 under
        way" when none of it touches the captain's code, which is a bigger lie
        than the blank panel it replaces. Housekeeping and project work are
        different things and the screen says so.

        READ FROM LIVE PROCESSES, not from a record this could drift from. The
        durable records answer "what work exists"; only the process table
        answers "what is running right now", which is the question asked.

        NAMED IN THE CAPTAIN'S NOUNS. `AGENTS.md` section 9 binds on a panel
        exactly as in chat, so nothing here surfaces a script name.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    # Script actually being RUN, to plain noun. Anything not named here is
    # deliberately not shown: an unrecognised process is not evidence of work the
    # captain cares about, and guessing a label for it would put machinery back
    # on the screen.
    $known = @{
        'fm-bridge'  = @{ Name = 'This screen'; Detail = 'ready' }
        'fm-tg-poll' = @{ Name = 'Listening to your phone'; Detail = 'ready' }
        'fm-watch'   = @{ Name = 'Watching for progress'; Detail = 'ready' }
        'fm-doctor'  = @{ Name = 'Health check'; Detail = 'running' }
    }

    $out = [System.Collections.Generic.List[object]]::new()
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction Stop)
    } catch {
        # A process table this cannot read is reported as not knowing, never as
        # nothing running - the second is the failure this function exists for.
        return @([pscustomobject]@{ Name = 'Could not check what is running'; Detail = 'unknown' })
    }

    # MATCH WHAT IS RUNNING, NOT WHAT IS MENTIONED. A plain substring search over
    # the command line reported "Watching for progress" for two processes that
    # merely NAMED that script inside a long `-Command` string - so the panel
    # built to stop the screen misleading the captain misled them within the
    # hour. Only the argument of `-File` is the script actually being executed.
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($p in $procs) {
        if (-not $p.CommandLine) { continue }
        if ($p.CommandLine -notmatch '(?i)-File\s+"?([^"]*?\bfm-[a-z0-9-]+)\.ps1"?') { continue }
        $null = $seen.Add((Split-Path $Matches[1] -Leaf))
    }

    # A test run is a pwsh process with no script of its own, so it is recognised
    # by the runner it invokes rather than by a -File argument.
    if (@($procs | Where-Object { $_.CommandLine -match '(?i)Invoke-Pester' }).Count) {
        $out.Add([pscustomobject]@{ Name = 'Running the checks'; Detail = 'working' })
    }

    foreach ($name in ($seen | Sort-Object)) {
        if ($known.ContainsKey($name)) {
            $out.Add([pscustomobject]@{ Name = $known[$name].Name; Detail = $known[$name].Detail })
        }
    }
    $out.ToArray()
}
