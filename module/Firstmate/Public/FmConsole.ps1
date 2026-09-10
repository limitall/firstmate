#requires -Version 7.0
Set-StrictMode -Version Latest

# FmConsole.ps1 - firstmate's own window: the one the captain can watch.
#
# WHY THIS AREA EXISTS. The captain's verdict on the whole product was that it
# does not work like a firstmate:
#
#     still not satisfied with work, it not works like first mate. on start
#     firstmate it must open herder and in that go to project folder and start
#     claude with dangerous skip command so user can see cli also
#
# What `firstmate` opened was a browser page and nothing else. Everything that
# was actually happening - the session taking the helm, each turn, each spawn,
# each refusal - was written to whichever console they had typed in, or to no
# console at all when the shim started one they never see. A firstmate you cannot
# watch is a chatbot with a fleet behind it.
#
# WHAT THIS OPENS, AND WHAT IT DELIBERATELY DOES NOT. It opens ONE herdr window
# holding firstmate's own pane, and firstmate runs there. It does NOT open a
# second agent session. Two live firstmate sessions in one home is exactly what
# the home record prevents, and a design where the terminal and the page fight
# over the home is not one worth having: the page's hosted session is the
# session, it takes the helm (Get-FmBridgeHomeHolder owns that fact), and this
# window is where that session's work becomes visible rather than a rival to it.
#
# THE CLI THE CAPTAIN ASKED TO SEE ARRIVES IN THIS SAME WINDOW. Start-FmWorker
# creates every crewmate's pane in this home's herdr workspace, running
# `claude --dangerously-skip-permissions` in an isolated copy of the project.
# Until now nothing ever opened that workspace, so those panes ran where nobody
# was looking. Opening it here is what puts them in front of the captain: ask for
# work and a real agent CLI appears in the window, doing it.

<#
.SYNOPSIS
Where firstmate's own window should open.

.DESCRIPTION
"The project folder" is the captain's phrase and it has three honest answers on a
real machine, so this returns which one it gave rather than only a path.

  project    exactly one project is cloned in this home - open there
  projects   several are - open at the folder holding them, because choosing
             one of the captain's projects for them would be a guess
  checkout   none are, or there is no home yet - open where firstmate itself
             lives, which is the only directory that is certainly there

THE MACHINE THAT PROMPTED THIS HAD NONE. A captain on a fresh install has no home
until the browser asks them where it goes, and no projects until they add one, so
the empty case is the FIRST case rather than an edge - and it must be a sensible
directory rather than a refusal.

READ FROM THE CLONES, NOT THE REGISTRY. `data/projects.md` records standing
posture for projects that may not be cloned here yet; a directory under
`projects/` is somewhere the captain can actually stand.

.PARAMETER HomePath
The firstmate home. Empty or absent means this machine has not chosen one yet.

.PARAMETER CheckoutPath
The checkout firstmate itself is running from. The answer of last resort.

.EXAMPLE
Get-FmConsoleDirectory -HomePath C:\Users\me\firstmate -CheckoutPath C:\Users\me\firstmate-win
#>
function Get-FmConsoleDirectory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$HomePath = '',
        [Parameter(Mandatory)][string]$CheckoutPath
    )

    $answer = [pscustomobject]@{
        PSTypeName = 'Firstmate.ConsoleDirectory'
        Path       = $CheckoutPath
        Kind       = 'checkout'
        Detail     = 'no projects yet, so it opens where firstmate itself lives'
    }
    if (-not $HomePath) { return $answer }

    $projects = Join-Path $HomePath 'projects'
    if (-not (Test-Path -LiteralPath $projects -PathType Container)) { return $answer }

    $clones = @(Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name)
    if ($clones.Count -eq 1) {
        $answer.Path = $clones[0].FullName
        $answer.Kind = 'project'
        $answer.Detail = $clones[0].Name
        return $answer
    }
    if ($clones.Count -gt 1) {
        # NOT ONE OF THEM. Standing in whichever project sorts first would be a
        # choice made on the captain's behalf out of no information at all, and
        # the folder above them is where every one of them is.
        $answer.Path = $projects
        $answer.Kind = 'projects'
        $answer.Detail = "$($clones.Count) projects"
        return $answer
    }
    $answer
}

<#
.SYNOPSIS
Open firstmate's own window and run one command in it.

.DESCRIPTION
Creates (or joins) this home's herdr workspace, puts firstmate's own tab in it at
the given directory, brings it to the front, and runs the command there.

IT ANSWERS, IT DOES NOT THROW. Every other herdr caller in this port is a spawn,
where a refusal must stop the dispatch. This one is the captain's own start, and
a machine with no herdr on it must still get a firstmate - so a refusal comes
back as `Ok = $false` with a sentence, and start.ps1 decides what to do with it.
Throwing here would mean a missing WINDOW stopped firstmate from running at all,
which is a worse trade than running it where they typed.

NOT LABELLED LIKE A TASK. `Get-FmHerdrLiveTask` reads every `fm-*` tab in the
workspace as a worker, so firstmate's own tab is `firstmate` and never `fm-`
anything; supervision must not find its own console and reconcile it as a crew.

ONE PER HOME, AND A SECOND START JUST BRINGS IT FORWARD. A captain who types
`firstmate` twice is asking to see firstmate, not to run two of them - and the
second engine would land on a port the first one holds and fail there. So an
already-open window is reported as `AlreadyOpen` and focused, and start.ps1 says
so and stops rather than falling back to a second engine. `New-FmHerdrTask`
remains the backstop: it refuses the duplicate outright if one appears between
the read and the create.

.PARAMETER Cwd
The directory the window opens in. Get-FmConsoleDirectory answers this.

.PARAMETER Command
What to run in the window, written in PowerShell 7 and quoted with single quotes.
It is wrapped for the pane's own shell here rather than by the caller, because
ConvertTo-FmPaneCommand owns that rule and its refusal - a value carrying a
double quote - has to come back as a sentence like every other refusal on this
path rather than as an exception out of the captain's start.

.PARAMETER Label
The tab's name. Defaults to `firstmate`.

.EXAMPLE
Start-FmConsole -Cwd C:\Users\me\firstmate\projects\app -Command "& 'C:\fm\bin\fm-bridge.ps1'"
#>
function Start-FmConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [Parameter(Mandatory)][string]$Command,
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Label = 'firstmate'
    )

    $answer = [pscustomobject]@{
        PSTypeName  = 'Firstmate.Console'
        Ok          = $false
        AlreadyOpen = $false
        Target      = ''
        Session     = ''
        TabId       = ''
        PaneId      = ''
        Cwd         = $Cwd
        Reason      = ''
    }
    if ($Label.StartsWith('fm-')) {
        $answer.Reason = "a console tab may not be labelled '$Label'; anything starting with fm- is read as a worker"
        return $answer
    }
    if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) {
        $answer.Reason = "there is no directory at $Cwd to open a window in"
        return $answer
    }
    $paneCommand = ''
    try { $paneCommand = ConvertTo-FmPaneCommand -Inner $Command }
    catch {
        $answer.Reason = $_.Exception.Message
        return $answer
    }
    if (-not $PSCmdlet.ShouldProcess("herdr window at $Cwd", "open firstmate's console")) { return $answer }

    $container = $null
    try {
        $container = New-FmHerdrContainer -Cwd $Cwd -Confirm:$false
    } catch {
        $answer.Reason = $_.Exception.Message
        return $answer
    }
    if ($null -eq $container) {
        $answer.Reason = 'the session provider did not return a workspace to open a window in'
        return $answer
    }

    # ALREADY OPEN IS NOT A FAILURE. Read before creating, so the answer is
    # "here it is" rather than a refusal the caller has to interpret.
    $existing = ''
    try { $existing = Get-FmHerdrLiveTabIdByLabel -Session $container.Session -WorkspaceId $container.WorkspaceId -Label $Label }
    catch { $existing = '' }
    if ($existing) {
        $null = Set-FmHerdrTabFocus -Session $container.Session -TabId $existing -Confirm:$false -ErrorAction SilentlyContinue
        $answer.AlreadyOpen = $true
        $answer.Session = $container.Session
        $answer.TabId = $existing
        $answer.Reason = 'firstmate is already running in its own window'
        return $answer
    }

    $created = $null
    try {
        $created = New-FmHerdrTask -Container $container.Container -Label $Label -Cwd $Cwd `
            -SeededTabId $container.SeededTabId -Confirm:$false
    } catch {
        $answer.Reason = $_.Exception.Message
        return $answer
    }
    if ($null -eq $created) {
        $answer.Reason = 'the session provider did not return a window to run firstmate in'
        return $answer
    }

    # THE COMMAND FIRST, THE FOCUS SECOND. A window brought to the front with an
    # empty prompt in it is what a captain reads as "it opened and did nothing";
    # `pane run` types and submits in one call, so by the time the window arrives
    # it is already running.
    if (-not (Send-FmHerdrTextLine -Target $created.Target -Text $paneCommand)) {
        # Nothing is left behind that the captain would have to close by hand.
        $null = Remove-FmHerdrPane -Target $created.Target -Confirm:$false -ErrorAction SilentlyContinue
        $answer.Reason = 'firstmate could not be started in the window that was opened for it'
        return $answer
    }
    # Best effort, and deliberately not a failure: firstmate IS running in that
    # window whether or not the window came forward, and reporting a refusal here
    # would send start.ps1 down the fallback path to start a SECOND one.
    $null = Set-FmHerdrTabFocus -Session $created.Session -TabId $created.TabId -Confirm:$false -ErrorAction SilentlyContinue

    $answer.Ok = $true
    $answer.Target = $created.Target
    $answer.Session = $created.Session
    $answer.TabId = $created.TabId
    $answer.PaneId = $created.PaneId
    $answer
}
