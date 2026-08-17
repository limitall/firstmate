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

function Convert-FmSpeechToText {
    <#
        .SYNOPSIS
        Turn a WAV on disk into text using the local engine.

        .DESCRIPTION
        Returns the transcript, or an empty string with a reason. It never
        throws: this sits on the path between the captain speaking and firstmate
        answering, and a thrown error there would lose what they said.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WavPath,
        [int]$TimeoutSeconds = 120
    )

    $engine = Get-FmSpeechEngine
    if (-not $engine) {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = 'no local speech engine is installed' }
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
            return [pscustomobject]@{ Ok = $false; Text = ''; Error = 'the speech engine did not finish in time' }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Text = ''; Error = "could not run the speech engine: $($_.Exception.Message)" }
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

        # Places.
        [pscustomobject]@{ Pattern = '\bworktrees?\b|\bcheckouts?\b'; Plain = 'local copy' }

        # People and their instructions.
        [pscustomobject]@{ Pattern = '\bcrewmates?\b'; Plain = 'worker' }
        [pscustomobject]@{ Pattern = '\bsecondmates?\b'; Plain = 'second mate' }
        [pscustomobject]@{ Pattern = '\bbriefs?\b'; Plain = 'instructions' }

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
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $s = $Text

    $fence = ([char]1).ToString()
    $urls = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($s, 'https?://\S+')) {
        if (-not $urls.Contains($match.Value)) { $urls.Add($match.Value) }
    }
    for ($i = 0; $i -lt $urls.Count; $i++) {
        $s = $s.Replace($urls[$i], "$fence$i$fence")
    }

    $s = $s -replace '^\s*[a-z-]+\s*:\s*', ''          # the state prefix
    $s = $s -replace '\[\s*\d{1,3}\s*%\s*\]\s*', ''     # a percentage prefix
    $s = $s -replace '\[key=[^\]]+\]\s*', ''            # a decision key
    $s = $s -replace '\breport at \S+', 'report ready'  # a path to a report
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

    $s = $s -replace '\s{2,}', ' '
    $s = $s -replace '\s+([,;.])', '$1'
    $s = $s.Trim().Trim('-', ';', ',').Trim()

    if ($s) { $s = $s.Substring(0, 1).ToUpper() + $s.Substring(1) }
    for ($i = 0; $i -lt $urls.Count; $i++) {
        $s = $s.Replace("$fence$i$fence", $urls[$i])
    }
    $s
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
                    $note = ConvertTo-FmBridgePlainText -Text $last

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
                                Question = ConvertTo-FmBridgePlainText -Text $body
                            }
                        } elseif ($s -match '^\s*resolved\s*:') {
                            $key = if ($s -match '\[key=([^\]]+)\]') { $Matches[1] } else { 'default' }
                            $decisions = @($decisions | Where-Object { -not ($_.Task -eq $id -and $_.Key -eq $key) })
                        }
                    }

                    foreach ($l in ($lines | Select-Object -Last 4)) {
                        $plain = ConvertTo-FmBridgePlainText -Text ([string]$l)
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
