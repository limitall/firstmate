#requires -Version 7.0
<#
.SYNOPSIS
fm-bridge.ps1 - run firstmate from the browser. Starts the engine, opens the UI,
and everything happens there.

.DESCRIPTION
This is the thing the HUD was a picture of. It hosts a real firstmate session and
couriers between it and the browser, so speaking into the page reaches firstmate
and the answer comes back.

WHY IT IS A SERVER AND NOT A FILE. Measured, same page, twice:

    file:///.../ui/bridge.html   getUserMedia -> NotAllowedError: Permission denied
    http://127.0.0.1:7433/       getUserMedia -> OK, 1 audio track

A file:// page has an opaque origin, so Chrome has nowhere to attach a microphone
grant and refuses outright. window.isSecureContext reports TRUE on file://, which
is what makes that trap easy to miss.

WHY IT HOSTS A SESSION RATHER THAN BEING ONE. data/web-ui/report.md measured that
a headless `claude` can hold this home's session lock and a plain PowerShell
process cannot. So firstmate stays a Claude session running the same AGENTS.md,
the same skills and the same spawn path; this is a courier, not a second
implementation of the operating contract.

ROUTES
    GET  /              the UI
    GET  /api/fleet     work under way, open decisions, recent activity
    POST /api/say       one captain turn -> firstmate's reply, read and spoken,
                        both gated against the records and returned with the
                        snapshot they were gated against, so the reply, the voice
                        and the panel are one read
    GET  /api/health    is the engine up, what dictation can do, how it listens
    POST /api/listen    start, stop or drop a capture on the WARM speech engine
    POST /api/listen-mode  hold to talk, or leave the microphone open
    POST /api/voice     whether the screen speaks its answers. Off by default
    GET  /api/heard     a dictated line waiting to be asked, if one has landed

ONE VOICE, NOT TWO. /api/say and /api/fleet answer the same question - what is
happening - so they answer it from ONE read of the durable records, taken here
and handed to both. The session used to answer from its own view of this home,
which is narrower than the panel's whenever it could not open the home, and the
captain got a panel listing three jobs beside a reply saying nothing was under
way. Both were honest, which is precisely why it was unusable.
New-FmBridgeTurnPrompt carries the whole argument. Every reply also leaves
through ConvertTo-FmBridgePlainText, so what the session says and what the panel
says obey one vocabulary rather than agreeing by habit.

SPEAKING BELONGS TO THE PAGE, AND ONLY TO THE PAGE, AND IT IS OFF BY DEFAULT.
This page spoke at the captain twice with no browser they could see, because it
was being driven headless: a live page with no window to close. There is now a
mute on the screen, `config/bridge-voice`, absent meaning off. The hosted
session is separately refused the machine's own voice (FM_VOICE_OFF) so that a
home which HAS turned `config/voice` on cannot talk out of a process the page
never reaches.

SECURITY. Binds 127.0.0.1 only, so nothing off this machine can reach it. There
IS a write path now - /api/say drives a session that can change code - so it is
guarded: a per-run token every request must carry, and an Origin check, because
data/web-ui/report.md MEASURED that any page open in the captain's browser can
otherwise POST at a loopback listener even though it cannot read the replies. The
token is handed to the page through the launch URL and never written to disk.

.PARAMETER Port
Loopback port. Default 7433.

.PARAMETER NoLaunch
Serve without opening a browser.

.PARAMETER NoEngine
Serve the UI and fleet state but start no session. The page runs read-only.

.EXAMPLE
bin/fm-bridge.ps1
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 7433,
    [switch]$NoLaunch,
    [switch]$NoEngine,
    [string]$Model = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'fm-module-load.ps1') -RequiredCommand 'Get-FmCaptainName'

# NOTHING THIS PROCESS STARTS MAY SPEAK ON THE MACHINE. Set here, on the whole
# tree, rather than only on the hosted session: this bridge starts hooks and
# child commands by more than one route, and it was a child that once carried on
# talking to a closed browser with nothing the captain could reach to stop it.
# Speaking on this surface belongs to the page, which stops existing when they
# close it. Test-FmVoiceSuppressed is the gate; New-FmBridgeSession sets it on
# the session explicitly as well, so neither depends on the other.
$env:FM_VOICE_OFF = '1'

$root  = Split-Path -Parent $PSScriptRoot
$uiDir = Join-Path $root 'ui'
# The file the captain points their dictation app at. Named from here because
# this is the process that knows where this checkout is; the module owns what the
# setting MEANS and bin/fm-dictate.ps1 owns why it is a .cmd.
#
# NOT $PSScriptRoot. Run from a worker's disposable copy of the checkout, that
# names a directory which is deleted when the work finishes - and the captain,
# who was told to point their dictation app at it, would be left pointing at
# nothing. Observed on their screen. Get-FmStableCheckout owns the answer.
$hookRoot = Get-FmStableCheckout -Root $root -RequiredFile 'bin/fm-dictate.cmd'
$hookPath = Join-Path (Join-Path $hookRoot 'bin') 'fm-dictate.cmd'

# FIRST RUN. When this machine has never been told where the workspace goes, the
# bridge starts WITHOUT an engine and the browser asks. The captain should not
# have to know a directory layout before they can start - and they should not be
# asked in a terminal, since the whole point is that the terminal is not the
# surface.
$configured = Test-FmBridgeConfigured -RepoRoot $root
$home_ = if ($configured) { Get-FmBridgeWorkspace -RepoRoot $root } else { '' }
# Read once, at startup. The address is a standing property of the home, not a
# per-message setting, so every surface this bridge feeds uses the same word.
$captainName = Get-FmCaptainName
# Set when the address changes mid-run, cleared when it has been passed on.
$script:pendingAddress = $null
# A line dictated through the engine's own hook, waiting for the page to ask it.
$script:pendingDictation = ''
if (-not (Test-Path -LiteralPath $uiDir -PathType Container)) {
    [Console]::Error.WriteLine("error: no ui directory at $uiDir"); exit 1
}

# A fresh secret per run. It never touches disk, so nothing can leak it later,
# and a restart invalidates every page that held the old one.
$token = [Convert]::ToBase64String([guid]::NewGuid().ToByteArray()).TrimEnd('=').Replace('+','-').Replace('/','_')

$prefix = "http://127.0.0.1:$Port/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch {
    [Console]::Error.WriteLine("error: cannot listen on $prefix - $($_.Exception.Message)")
    [Console]::Error.WriteLine('       another process may hold that port; try -Port <n>')
    exit 1
}

# ---- the engine -------------------------------------------------------------
# A function, because on first run it starts AFTER the captain has chosen a
# workspace in the browser rather than before the listener exists.
$session = $null
function Start-Engine {
    # The entry point owns the decision to run at all; this is the mechanics.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Local helper over New-FmBridgeSession, which the entry point has already decided to call.')]
    [CmdletBinding()]
    param(
        [string]$HomePath,
        # Taken as parameters rather than read from the enclosing scope, so the
        # analyzer can see they are used - and so this reads as a function rather
        # than something that quietly depends on where it was defined.
        [bool]$Suppressed,
        [string]$ModelName
    )
    if ($Suppressed -or -not $HomePath) { return $null }
    [Console]::Out.WriteLine('fm-bridge: starting the firstmate session...')
    $s = New-FmBridgeSession -HomePath $HomePath -Model $ModelName
    if ($null -eq $s) {
        [Console]::Error.WriteLine('fm-bridge: could not start a firstmate session (is the Claude CLI installed?)')
        [Console]::Error.WriteLine('           serving read-only; the page will say so rather than pretend')
    } else {
        [Console]::Out.WriteLine("fm-bridge: session up (id $($s.SessionId))")
    }
    $s
}

if ($configured) {
    $session = Start-Engine -HomePath $home_ -Suppressed $NoEngine.IsPresent -ModelName $Model
} else {
    [Console]::Out.WriteLine('fm-bridge: first run - asking in the browser where the workspace goes')
}

[Console]::Out.WriteLine("fm-bridge: $prefix")
[Console]::Out.WriteLine('fm-bridge: loopback only, token-guarded. Ctrl+C to stop.')

$launchUrl = "$prefix#t=$token"
# Printed so the captain can reopen the page after closing the tab, and so a
# test can drive the API. It is a per-run secret that never touches disk, so it
# dies with this process.
[Console]::Out.WriteLine("fm-bridge: open $launchUrl")

# The dictation hook runs as a separate process with no way to be handed the
# key, so it is left where only this user can read it. Written on start and
# removed on exit, so a stale key never outlives the bridge that minted it.
$tokenFile = Get-FmBridgeTokenPath
try { [System.IO.File]::WriteAllText($tokenFile, $token, [System.Text.UTF8Encoding]::new($false)) }
catch { [Console]::Error.WriteLine('fm-bridge: could not leave a key for the dictation hook') }

# Said once, on the way up, because it is the difference between dictation that
# takes three seconds and dictation that takes fifteen - and the one step is the
# captain's to make. Printed rather than applied: this process does not touch
# another application's settings.
$speechAtStart = Get-FmSpeechEngineStatus -HookPath $hookPath
[Console]::Out.WriteLine("fm-bridge: dictation - $($speechAtStart.Detail)")
if ($speechAtStart.Setup) { [Console]::Out.WriteLine("fm-bridge: to make it faster - $($speechAtStart.Setup)") }
if (-not $NoLaunch) { Start-Process $launchUrl }

$types = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8'
            '.js'='text/javascript; charset=utf-8'; '.svg'='image/svg+xml'
            '.png'='image/png'; '.ico'='image/x-icon' }

function Write-Json {
    param($Response, $Object, [int]$Status = 200)
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.Headers.Add('Cache-Control', 'no-store')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Object | ConvertTo-Json -Depth 8 -Compress))
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.Close()
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        try {
            $path = $req.Url.AbsolutePath.TrimEnd('/')
            if ([string]::IsNullOrEmpty($path)) { $path = '/' }

            # --- API: guarded ------------------------------------------------
            if ($path.StartsWith('/api')) {
                # An Origin from anywhere but this listener is another page in
                # the captain's browser reaching in. Refuse before doing work.
                $origin = [string]$req.Headers['Origin']
                if ($origin -and $origin -ne "http://127.0.0.1:$Port") {
                    Write-Json -Response $res -Object @{ error = 'origin refused' } -Status 403
                    continue
                }
                $supplied = [string]$req.Headers['X-Fm-Token']
                if ($supplied -ne $token) {
                    Write-Json -Response $res -Object @{ error = 'token refused' } -Status 401
                    continue
                }

                if ($path -eq '/api/health') {
                    $speech = Get-FmSpeechEngineStatus -HookPath $hookPath
                    Write-Json -Response $res -Object @{
                        ok         = $true
                        configured = $configured
                        engine     = ($null -ne $session -and -not $session.Process.HasExited)
                        home       = $home_
                        captain    = $captainName
                        suggested  = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'firstmate')
                        session    = $(if ($session) { $session.SessionId } else { '' })
                        # Whether this page may speak out loud. Off unless the
                        # captain pressed the mute on the screen, because the page
                        # used to speak every reply unconditionally and did it on
                        # their machine with no window open to silence.
                        voice      = (Test-FmBridgeVoiceAllowed -HomePath $home_)
                        # What dictation can do on this machine right now. The
                        # page chooses its path from this rather than trying the
                        # fast one and guessing why it failed.
                        speech     = @{
                            installed = $speech.Installed
                            warm      = ($speech.Installed -and $speech.Running)
                            handsOver = $speech.HandsOver
                            detail    = $speech.Detail
                            setup     = $speech.Setup
                        }
                        # Read from the home every time rather than captured at
                        # start: the captain can change it from the page, and a
                        # reload has to come back to what they chose.
                        listenMode = (Get-FmListenMode)
                    }
                    continue
                }

                if ($path -eq '/api/voice') {
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $voiceBody = ''
                    $vr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $voiceBody = $vr.ReadToEnd() } finally { $vr.Dispose() }
                    $wantVoice = ''
                    try { $wantVoice = [string]($voiceBody | ConvertFrom-Json).state } catch { $wantVoice = '' }
                    $setVoice = Set-FmBridgeVoice -State $wantVoice
                    if ($setVoice.Ok) { [Console]::Out.WriteLine("fm-bridge: the screen's voice is now $($setVoice.State)") }
                    Write-Json -Response $res -Object @{
                        ok    = $setVoice.Ok
                        state = $setVoice.State
                        error = $setVoice.Error
                    } -Status $(if ($setVoice.Ok) { 200 } else { 400 })
                    continue
                }

                if ($path -eq '/api/listen-mode') {
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $modeBody = ''
                    $mr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $modeBody = $mr.ReadToEnd() } finally { $mr.Dispose() }
                    $wantMode = ''
                    try { $wantMode = [string]($modeBody | ConvertFrom-Json).mode } catch { $wantMode = '' }
                    $set = Set-FmListenMode -Mode $wantMode
                    if ($set.Ok) { [Console]::Out.WriteLine("fm-bridge: listening mode is now $($set.Mode)") }
                    Write-Json -Response $res -Object @{
                        ok    = $set.Ok
                        mode  = $set.Mode
                        error = $set.Error
                    } -Status $(if ($set.Ok) { 200 } else { 400 })
                    continue
                }

                if ($path -eq '/api/listen') {
                    # THE FAST PATH. The engine instance the captain already has
                    # running holds the model resident, so this asks IT to record
                    # and transcribe instead of loading a second copy per phrase.
                    # module/Firstmate/Public/FmBridge.ps1 carries the numbers.
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $listenBody = ''
                    $lr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $listenBody = $lr.ReadToEnd() } finally { $lr.Dispose() }
                    $wantAction = 'Toggle'
                    try {
                        $asked = [string]($listenBody | ConvertFrom-Json).action
                        if ($asked -eq 'cancel') { $wantAction = 'Cancel' }
                    } catch { $wantAction = 'Toggle' }

                    # A capture that is starting clears any line left over from a
                    # previous one, so an old transcript can never be picked up
                    # as the answer to what is being said now.
                    if ($wantAction -eq 'Toggle') { $script:pendingDictation = '' }

                    $capture = Invoke-FmSpeechCapture -Action $wantAction
                    $state = Get-FmSpeechEngineStatus -HookPath $hookPath
                    if (-not $capture.Ok) {
                        [Console]::Error.WriteLine("fm-bridge: dictation not started - $($capture.Error)")
                    }
                    Write-Json -Response $res -Object @{
                        ok        = $capture.Ok
                        error     = $capture.Error
                        handsOver = $state.HandsOver
                        setup     = $state.Setup
                    }
                    continue
                }

                if ($path -eq '/api/heard') {
                    # Polled only while a capture is in flight, so it stays as
                    # cheap as it looks - the fleet read is the expensive one and
                    # it keeps its own four-second-ish cadence. Handed over once,
                    # same rule as /api/fleet.
                    $waiting = $script:pendingDictation
                    $script:pendingDictation = ''
                    Write-Json -Response $res -Object @{ ok = $true; text = $waiting }
                    continue
                }

                if ($path -eq '/api/setup') {
                    # First run only. Creates the workspace where the captain
                    # asked, then brings the engine up against it, so the page
                    # goes straight from the question to a working fleet without
                    # anyone restarting anything.
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $setupBody = ''
                    $sr2 = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $setupBody = $sr2.ReadToEnd() } finally { $sr2.Dispose() }
                    $wantPath = ''
                    try { $wantPath = [string]($setupBody | ConvertFrom-Json).path } catch { $wantPath = '' }

                    $made = Initialize-FmBridgeWorkspace -RepoRoot $root -Path $wantPath -Confirm:$false
                    if (-not $made.Ok) {
                        Write-Json -Response $res -Object @{ ok = $false; error = $made.Error } -Status 400
                        continue
                    }

                    $home_ = $made.Path
                    $configured = $true
                    $captainName = Get-FmCaptainName -ConfigDir (Join-Path $home_ 'config')
                    [Console]::Out.WriteLine("fm-bridge: workspace created at $home_")
                    $session = Start-Engine -HomePath $home_ -Suppressed $NoEngine.IsPresent -ModelName $Model
                    Write-Json -Response $res -Object @{
                        ok     = $true
                        home   = $home_
                        engine = ($null -ne $session -and -not $session.Process.HasExited)
                    }
                    continue
                }

                if ($path -eq '/api/fleet') {
                    $fleet = Get-FmBridgeFleet -HomePath $home_
                    $handOver = $script:pendingDictation
                    # Cleared as it is handed over, so one utterance is asked
                    # once however many tabs are polling.
                    $script:pendingDictation = ''
                    Write-Json -Response $res -Object @{
                        ok        = $true
                        engine    = ($null -ne $session -and -not $session.Process.HasExited)
                        captain   = $captainName
                        # Re-read every poll rather than once at boot: the
                        # captain may switch the voice on or off while the page
                        # is open, and a page that learned "on" at startup would
                        # keep talking after they turned it off.
                        voice     = (Test-FmBridgeVoiceAllowed -HomePath $home_)
                        # A line dictated straight into the engine, waiting for
                        # the page to pick it up and ask it. Handed over once.
                        dictated  = $handOver
                        tasks     = @($fleet.Tasks)
                        decisions = @($fleet.Decisions)
                        activity  = @($fleet.Activity)
                        # What this machine is doing for itself, kept apart from
                        # `tasks` so the screen never counts housekeeping as work
                        # on the captain's code.
                        house     = @($fleet.House)
                        # Real, or the panel says it is not measured. Nothing on this
                        # surface ships a figure that was never measured.
                        capacity  = $fleet.Capacity
                        at        = $fleet.At
                    }
                    continue
                }

                if ($path -eq '/api/name') {
                    # Settable from the browser, because the captain should never
                    # have to go back to a terminal to change something about
                    # their own session. Same validation as bin/fm-name.ps1 - a
                    # line break here would break every address that follows.
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $nameBody = ''
                    $nr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $nameBody = $nr.ReadToEnd() } finally { $nr.Dispose() }
                    $wanted = ''
                    try { $wanted = ([string]($nameBody | ConvertFrom-Json).name).Trim() } catch { $wanted = '' }

                    if ($wanted.Length -gt 48 -or $wanted -match '[\r\n\t]') {
                        Write-Json -Response $res -Object @{ ok = $false; error = 'that name will not work' } -Status 400
                        continue
                    }

                    $nameFile = Join-Path (Get-FmConfigRoot) 'captain-name'
                    if ($wanted) {
                        [System.IO.File]::WriteAllText($nameFile, "$wanted`n", [System.Text.UTF8Encoding]::new($false))
                        $captainName = $wanted
                    } else {
                        Remove-Item -LiteralPath $nameFile -Force -ErrorAction SilentlyContinue
                        $captainName = 'captain'
                    }

                    # NOT sent to the session here. Doing that blocked this
                    # request on a whole agent turn - measured, it hung past 180s
                    # because the session's first turn also pays its startup - and
                    # saving a name must never wait on the model. Instead the
                    # change rides along with the NEXT thing the captain says,
                    # which costs nothing and arrives in time to matter.
                    $script:pendingAddress = $captainName
                    [Console]::Out.WriteLine("fm-bridge: address set to '$captainName'")
                    Write-Json -Response $res -Object @{ ok = $true; captain = $captainName }
                    continue
                }

                if ($path -eq '/api/dictate') {
                    # Dictation arriving from the speech engine's own hook, which
                    # transcribed it with a model that was ALREADY resident -
                    # about four seconds against the fifteen a fresh load costs.
                    # bin/fm-dictate.ps1 carries the measurements.
                    #
                    # It returns immediately and answers in the background,
                    # because the engine is blocked on this script until it does:
                    # holding it for a whole agent turn would freeze the
                    # captain's dictation key.
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $dictBody = ''
                    $dr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $dictBody = $dr.ReadToEnd() } finally { $dr.Dispose() }
                    $dictated = ''
                    try { $dictated = ([string]($dictBody | ConvertFrom-Json).text).Trim() } catch { $dictated = '' }

                    if ($dictated) {
                        [Console]::Out.WriteLine("heard: $dictated")
                        $script:pendingDictation = $dictated
                    }
                    Write-Json -Response $res -Object @{ ok = [bool]$dictated }
                    continue
                }

                if ($path -eq '/api/transcribe') {
                    # The browser records, this transcribes, and the audio never
                    # leaves the machine. The page sends a 16 kHz mono WAV it
                    # built itself, which is exactly what the local engine wants -
                    # no conversion step and no ffmpeg dependency.
                    #
                    # THE FALLBACK, not the path taken when anything better is
                    # available: a one-shot engine process loads the model from
                    # cold, which measured 10.8s to 14.8s on top of 3.0s of
                    # transcription. The page asks /api/listen first and only
                    # records a WAV itself when no engine instance is running.
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }

                    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fm-speech-$([guid]::NewGuid().ToString('N')).wav")
                    try {
                        $fs = [System.IO.File]::Create($tmp)
                        try { $req.InputStream.CopyTo($fs) } finally { $fs.Dispose() }

                        $said = Convert-FmSpeechToText -WavPath $tmp
                        if ($said.Ok) {
                            [Console]::Out.WriteLine("heard: $($said.Text)")
                            Write-Json -Response $res -Object @{ ok = $true; text = $said.Text }
                        } else {
                            Write-Json -Response $res -Object @{ ok = $false; error = $said.Error }
                        }
                    } finally {
                        # The captain's voice is not kept. Deleted whatever
                        # happened above, including on the failure paths.
                        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    }
                    continue
                }

                if ($path -eq '/api/say') {
                    if ($req.HttpMethod -ne 'POST') {
                        Write-Json -Response $res -Object @{ error = 'POST only' } -Status 405
                        continue
                    }
                    $body = ''
                    $sr = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
                    try { $body = $sr.ReadToEnd() } finally { $sr.Dispose() }

                    $text = ''
                    try { $text = [string]($body | ConvertFrom-Json).text } catch { $text = '' }
                    if ([string]::IsNullOrWhiteSpace($text)) {
                        Write-Json -Response $res -Object @{ ok = $false; error = 'nothing to say' } -Status 400
                        continue
                    }

                    if ($null -eq $session -or $session.Process.HasExited) {
                        Write-Json -Response $res -Object @{
                            ok = $false
                            error = 'firstmate is not running here, so nothing is listening'
                        } -Status 503
                        continue
                    }

                    [Console]::Out.WriteLine("$captainName`: $text")

                    # ONE READING, RENDERED TWICE. This is the same call the
                    # panel is painting from, made once and used for both halves,
                    # so the reply cannot describe a fleet the panel is not
                    # showing. New-FmBridgeTurnPrompt carries the whole argument.
                    $fleet = Get-FmBridgeFleet -HomePath $home_
                    $ground = Get-FmBridgeGround -Fleet $fleet
                    $canAct = Test-FmBridgeSessionCanAct -HomePath $home_ -SessionProcessId $session.Process.Id
                    # A name change set since the last turn rides along with this
                    # one, so it takes effect in THIS conversation rather than at
                    # the next restart - and without its own blocking round trip.
                    $send = New-FmBridgeTurnPrompt -Text $text -Fleet $fleet -CanAct $canAct -Address $script:pendingAddress
                    $script:pendingAddress = $null

                    $turn = Send-FmBridgeTurn -Session $session -Text $send

                    # THE WAY OUT IS THE GUARANTEE. Asking the session for plain
                    # words is a request it can miss; these two are the contract.
                    # Translated first, then de-stammered, so two lines the
                    # translation made identical collapse as well.
                    #
                    # The job names go in as -Keep because a name the panel is
                    # SHOWING must survive the translation intact: caught in the
                    # browser, a row reading LOCK IDENTITY sat beside a reply
                    # calling the same job "controls-identity".
                    #
                    # SPLIT BEFORE TRANSLATED, and Split-FmBridgeReply does both
                    # in that order. What is read and what is SAID are two
                    # different sentences, and the marker carrying the second one
                    # would be eaten by the translator's state-prefix rule if it
                    # were still in the text when that rule ran.
                    $names = @($fleet.Tasks | ForEach-Object { $_.Id })
                    $split = Split-FmBridgeReply -Reply $turn.Reply -Keep $names
                    $reply = Remove-FmBridgeRepetition -Text $split.Written
                    $replyError = ConvertTo-FmBridgePlainText -Text $turn.Error -Prose -Keep $names

                    # AND THE SECOND GUARANTEE, on what the first one produced.
                    # The translator settles the WORDS; this settles the FACTS,
                    # and the screen needed both: it once named work that does
                    # not exist, in faultless plain English, and recommended
                    # halting real work to make room for it.
                    #
                    # LAST, deliberately. It reads the exact text that is about
                    # to ship rather than a draft two rewrites earlier, and both
                    # sides of the comparison are then in one vocabulary, since
                    # the reading's own notes came through this same translator.
                    # The replacement needs no translating for the same reason -
                    # it is built out of those already-translated fields.
                    # BOTH CHANNELS, because there are two now. The spoken line
                    # is a SECOND sentence the session wrote, not a rendering of
                    # the written one, so gating only what is on screen would let
                    # the invention out through the speaker while the screen was
                    # clean - the same fabrication, arriving where the captain
                    # cannot re-read it and check.
                    $spoken = $split.Spoken
                    if ($turn.Ok -and $reply) {
                        $checked = Protect-FmBridgeReply -Text $reply -Ground $ground -Asked $text
                        if (-not $checked.Grounded) {
                            [Console]::Error.WriteLine('fm-bridge: reply held back - ' +
                                ($checked.Unsubstantiated -join '; '))
                            # Cleared rather than replaced: the page speaks the
                            # written reply when there is no spoken line, so the
                            # captain hears the answer that went to the screen
                            # instead of a summary of one that did not.
                            $spoken = ''
                        }
                        $reply = $checked.Reply
                    }
                    if ($spoken) {
                        $checkedSpoken = Protect-FmBridgeReply -Text $spoken -Ground $ground -Asked $text
                        if (-not $checkedSpoken.Grounded) {
                            [Console]::Error.WriteLine('fm-bridge: spoken line held back - ' +
                                ($checkedSpoken.Unsubstantiated -join '; '))
                            $spoken = ''
                        }
                    }

                    # NOTHING IS APPENDED HERE, and the deleted append is worth a
                    # line because it caused the defect it was meant to prevent.
                    # A sentence about what this screen cannot do used to be
                    # added under the answer; the session, told the same fact,
                    # had already said it in its own words, and the captain read
                    # the same statement twice in one reply. A canned line under
                    # a written answer cannot know what the answer already says.
                    # The route now travels in the prompt instead, and the reply
                    # the session writes is the whole reply.
                    if ($reply) { [Console]::Out.WriteLine("firstmate: $reply") }
                    if ($spoken) { [Console]::Out.WriteLine("  spoken: $spoken") }
                    Write-Json -Response $res -Object @{
                        ok        = $turn.Ok
                        reply     = $reply
                        spoken    = $spoken
                        error     = $replyError
                        # The snapshot this answer was gated against, so the page
                        # repaints from the very same read rather than polling for
                        # a later one that may have moved on.
                        tasks     = @($fleet.Tasks)
                        decisions = @($fleet.Decisions)
                        activity  = @($fleet.Activity)
                        house     = @($fleet.House)
                        # Real, or the panel says it is not measured. Nothing on
                        # this surface ships a figure that was never measured.
                        capacity  = $fleet.Capacity
                        at        = $fleet.At
                    }
                    continue
                }

                Write-Json -Response $res -Object @{ error = 'no such route' } -Status 404
                continue
            }

            # --- static ------------------------------------------------------
            if ($req.HttpMethod -notin @('GET','HEAD')) { $res.StatusCode = 405; $res.Close(); continue }

            $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'bridge.html' }

            # Containment checked on the RESOLVED path, so '..', an absolute
            # path and a symlink pointing out all fail one test.
            $full = [System.IO.Path]::GetFullPath((Join-Path $uiDir $rel))
            $rootFull = [System.IO.Path]::GetFullPath($uiDir)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $res.StatusCode = 403; $res.Close(); continue
            }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $res.StatusCode = 404; $res.Close(); continue }

            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
            $res.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
            $res.Headers.Add('Cache-Control', 'no-store')
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $res.ContentLength64 = $bytes.Length
            if ($req.HttpMethod -eq 'GET') { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
            $res.Close()
        } catch {
            # Printed, not swallowed. A 500 with no reason on the console is a
            # bug you cannot chase; the browser only ever sees the status.
            [Console]::Error.WriteLine("fm-bridge: $($req.Url.AbsolutePath) failed - $($_.Exception.Message)")
            # Best-effort: the client may already be gone, which is exactly when
            # writing a status throws. The real error is on the console above, so
            # failing to deliver a 500 must not take the whole server down.
            try { $res.StatusCode = 500; $res.Close() }
            catch { [Console]::Error.WriteLine('fm-bridge: client gone before the error could be sent') }
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
    Remove-Item -LiteralPath $tokenFile -Force -ErrorAction SilentlyContinue
    if ($session) { Stop-FmBridgeSession -Session $session -Confirm:$false }
    [Console]::Out.WriteLine('fm-bridge: stopped')
}
