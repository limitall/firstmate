<#
.SYNOPSIS
install.ps1 - clone this repo, run this once, and the machine is a working
firstmate. Afterwards, `firstmate` is a command.

.DESCRIPTION
This is the whole setup. It assumes NOTHING is already on the machine - not the
shell, not git, not Node, not even the package manager it would use to install
them - and it checks every one of those before it needs them, so an absent one
is an explained skip rather than a "command not found" halfway through.

    git clone <this repo> C:\Users\<you>\firstmate-win
    cd C:\Users\<you>\firstmate-win
    powershell -ExecutionPolicy Bypass -File .\install.ps1

THE -ExecutionPolicy Bypass IS PART OF THE FIRST COMMAND, not an afterthought.
Windows ships with script execution switched off, so a bare `.\install.ps1` on a
clean machine answers "install.ps1 cannot be loaded because running scripts is
disabled on this system" and nothing else happens. That form applies to the one
process it starts, needs no administrator, and changes no machine setting -
which is why it is documented rather than `Set-ExecutionPolicy`.

THREE OUTCOMES PER REQUIREMENT, not two.

  missing        installed, from the vendor's own published source. Running
                 this script is the consent for that; it is what the script is
                 for, so it is not asked about one tool at a time.
  older          installed and working, but behind the latest published
                 version. You are ASKED, one requirement at a time, with what is
                 installed and what is available. Declining is always safe, is
                 always the default, and never stops the run.
  unsupported    installed but below a minimum this repo actually states, and
                 the only way to put what this repo needs there is to REPLACE
                 it. You are TOLD, the step is SKIPPED, and nothing is
                 installed over the top of it. A machine in that state is
                 reported as NOT READY rather than finished.
  superseded     the same, except that what this repo needs installs BESIDE it.
                 That is every PowerShell module, because PowerShell keeps each
                 version of a module in its own directory and loads by version.
                 Windows ships Pester 3.4.0 on every machine and this repo needs
                 5+, so this run installs 5+ into your own module directory and
                 leaves Windows' copy exactly where it is. Nothing is asked and
                 nothing is left for you to run.

NOTHING IS LEFT FOR YOU TO RUN. Every line this script prints is either something
it did, or something that genuinely cannot be done from a script - and that one
is named, with the reason, and with whatever the tool itself said. A step you
have to perform yourself for the machine to work is a defect in this script, not
an instruction to you.

ONE STEP ASKS FOR ADMINISTRATOR, and it is the only one. Every TOOL comes from a
per-user installer or a release archive expanded under %LOCALAPPDATA%\Programs,
and none of those needs elevation; a route that would is named and skipped, and
everything else still installs. What does need it is the Visual C++ runtime -
not firstmate's, but herdr's, which Windows stops before it runs a line of its
own code without it. This run tells you what it is and why, then lets Windows
ask you to allow that one install. Saying no is safe: everything else still
installs, the run still finishes, and it ends by telling you herdr could not be
proven and naming the command. -Unattended skips the whole step and says so,
because a consent dialog nobody is there to see is a run that stops forever.

WHERE THE CHECKOUT IS, ASKED FIRST. A clone somewhere Windows guards refuses a
write two thirds of the way in, with a message about whichever step happened to
write first rather than about the location. This asks before anything is
attempted, and answers by WRITING rather than by guessing.

WHAT IT INSTALLS, YOU CAN FIND. A per-user install registers nothing by itself,
so this run adds PowerShell 7 to your own Start menu and prints where the
executable went. "Installed" has to mean you can open it.

IT ENDS BY PROVING ITSELF. Every tool is run and made to print a version, the
instructions and skills are read and counted, and this repo's own test suite is
executed. The last thing printed is a summary of every requirement and what
happened to it.

RE-RUNNING IS SAFE. Nothing already current is touched.

.PARAMETER Unattended
Never ask anything: install what is missing and leave every older-but-working
tool exactly as it is. This is the safe default for every question, and it
includes the administrator prompt for the Visual C++ runtime - that step is
skipped and reported as skipped, never raised where nobody can answer it.
`-Yes` is the same switch.

.PARAMETER SkipOptional
Install only what firstmate cannot run without.

.PARAMETER SkipSpeechModel
Install the speech engine but not its 1.4 GB model. The machine still works and
the summary reports the model as absent rather than pretending it is there;
re-run without this switch to fetch it. Voice is off either way.

.PARAMETER SkipSuite
Do not run the test suite at the end. The verdict then says the install is
unproven rather than claiming a pass it did not take.

.PARAMETER Offline
Do not ask any vendor what it publishes. Nothing is then classified as older,
and the report says currency was not checked.

.PARAMETER DetectOnly
Print what this machine has and what it needs, and change nothing. It still
writes one probe directory into the checkout and removes it again, because
whether this location can be installed into cannot be answered any other way.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Unattended

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DetectOnly
#>
[CmdletBinding()]
param(
    [Alias('Yes')]
    [switch]$Unattended,
    [switch]$SkipOptional,
    [switch]$SkipSpeechModel,
    [switch]$SkipSuite,
    [switch]$Offline,
    [switch]$DetectOnly
)

# ============================================================================
# 0. THE SHELL ITSELF
#
# NO `#requires -Version 7.0` ON THIS FILE, and nothing above the relaunch below
# may use PowerShell 7 syntax. A clean Windows machine opens Windows PowerShell
# 5.1, and a `#requires` line there produces "cannot be run because it contained
# a '#requires' statement" - a true statement that tells the captain nothing
# about what to do next. This block is the one part of the installer that has to
# survive being run by the wrong shell, so it says what is wrong and fixes it.
# ============================================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine('  FIRSTMATE - install')
    [Console]::Out.WriteLine('')
    [Console]::Out.WriteLine("  This is Windows PowerShell $($PSVersionTable.PSVersion). Firstmate is PowerShell 7 only -")
    [Console]::Out.WriteLine("  every script in this repo declares '#requires -Version 7.0'.")
    [Console]::Out.WriteLine('')

    $relaunchArguments = @()
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $relaunchArguments += "-$key" }
        } else {
            $relaunchArguments += "-$key"
            $relaunchArguments += [string]$value
        }
    }

    # Microsoft's own installer, pointed at a per-user directory: it takes the
    # zip rather than the MSI, so it needs no administrator. Named out here
    # because BOTH refusals below print it - the machine with no PowerShell 7 at
    # all, and the machine whose `pwsh` turns out not to be 7.
    $installLine = '& ([scriptblock]::Create((Invoke-RestMethod https://aka.ms/install-powershell.ps1))) ' +
    '-Destination "$env:LOCALAPPDATA\Programs\PowerShell7" -AddToPath'

    $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        $localPwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'
        if (Test-Path -LiteralPath $localPwsh) { $pwshCommand = Get-Command -Name $localPwsh -ErrorAction SilentlyContinue }
    }

    if (-not $pwshCommand) {
        [Console]::Out.WriteLine('  PowerShell 7 is not on this machine. It installs without administrator:')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine("    $installLine")
        [Console]::Out.WriteLine('')
        $answer = 'n'
        if ($Unattended) {
            $answer = 'y'
        } elseif (-not [Console]::IsInputRedirected) {
            $answer = Read-Host '  Install PowerShell 7 now, into your own profile? [Y/n]'
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'y' }
        }
        if ($answer -notmatch '^(y|yes)$') {
            [Console]::Out.WriteLine('  Nothing installed. Run the line above, open a new window, and re-run this script.')
            exit 1
        }
        try {
            $installer = Invoke-RestMethod -Uri 'https://aka.ms/install-powershell.ps1' -ErrorAction Stop
            & ([scriptblock]::Create($installer)) -Destination (Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7') -AddToPath
        } catch {
            [Console]::Out.WriteLine("  Could not install PowerShell 7: $($_.Exception.Message)")
            [Console]::Out.WriteLine('  Run the line above by hand, open a new window, and re-run this script.')
            exit 1
        }
        $localPwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'
        if (-not (Test-Path -LiteralPath $localPwsh)) {
            [Console]::Out.WriteLine('  PowerShell 7 installed, but pwsh.exe is not where this expected it.')
            [Console]::Out.WriteLine('  Open a new window and re-run this script.')
            exit 1
        }
        # SAY WHERE IT WENT. That route expands a zip into a per-user directory:
        # it writes pwsh.exe and edits PATH, and it registers nothing, so a
        # captain told "installed" went looking in the Start menu and found
        # nothing there - measured on a clean Windows 11 machine, 2026-08-20.
        # The relaunched run adds the Start menu entry (Set-FmMachineShellShortcut);
        # this is what the captain can see BEFORE that, at the moment they were
        # previously left guessing.
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('  PowerShell 7 is installed, in your own profile and with no administrator:')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine("    $localPwsh")
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('  That route expands an archive, so nothing has registered it yet. This run adds')
        [Console]::Out.WriteLine('  it to your Start menu as "PowerShell 7", and it is on PATH as pwsh in a NEW')
        [Console]::Out.WriteLine('  window. It does not replace the Windows PowerShell you are in now.')
        [Console]::Out.WriteLine('')
        $pwshCommand = Get-Command -Name $localPwsh -ErrorAction SilentlyContinue
    }

    # ONE RELAUNCH, NEVER TWO. `pwsh` is ALSO what PowerShell 6 is called, so on
    # a machine carrying it Get-Command resolves a shell that is still below 7,
    # which arrives here and relaunches again - a process spawning itself with no
    # bound. The marker travels to the child in its environment, so a second
    # arrival refuses instead. start.ps1 carries the same guard for the same
    # reason; this is the statement of it.
    if ($env:FM_SHELL_RELAUNCHED) {
        [Console]::Out.WriteLine("  This relaunched into a shell that is still PowerShell $($PSVersionTable.PSVersion),")
        [Console]::Out.WriteLine('  so it is stopping rather than doing it again. The pwsh on this machine is not')
        [Console]::Out.WriteLine('  PowerShell 7 - PowerShell 6 uses that name too. This installs 7 beside it:')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine("    $installLine")
        [Console]::Out.WriteLine('')
        exit 1
    }
    $env:FM_SHELL_RELAUNCHED = '1'

    [Console]::Out.WriteLine("  Re-running under $($pwshCommand.Source)...")
    [Console]::Out.WriteLine('')
    # A MACHINE MAY REFUSE THIS, and the refusal must not be a .NET error. Windows
    # declines to start a program for reasons that have nothing to do with this
    # repo and reports every one of them as "access is denied"; unguarded, that
    # arrives here as "Program 'pwsh.exe' failed to run" plus a stack trace, in
    # the first thirty seconds of the captain's first command.
    # Catchable whatever $ErrorActionPreference says: PowerShell raises a refused
    # launch as a terminating ApplicationFailedException, which is why the
    # unguarded form took the whole run with it.
    try {
        & $pwshCommand.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @relaunchArguments
    } catch {
        [Console]::Out.WriteLine('  Windows refused to start PowerShell 7 from here:')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine("    $($pwshCommand.Source)")
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('  The machine declined the launch; PowerShell itself did not fail. Open that')
        [Console]::Out.WriteLine('  program yourself from the Start menu, change to this folder, and run:')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('    .\install.ps1')
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine('  A launch refused with nothing but "access is denied" is usually security')
        [Console]::Out.WriteLine('  software guarding how a program is started, or Controlled folder access,')
        [Console]::Out.WriteLine('  which protects Documents - a checkout that is not under Documents rules')
        [Console]::Out.WriteLine('  the second one out.')
        [Console]::Out.WriteLine('')
        exit 1
    }
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Say { param([string]$Text = '') [Console]::Out.WriteLine($Text) }
function Warn { param([string]$Text) [Console]::Error.WriteLine($Text) }

# A prompt is only legitimate when the captain is at the keyboard. A redirected
# stdin, a CI run, or -Unattended all mean nobody is there to answer.
#
# THE ADMINISTRATOR PROMPT ASKS THIS TOO, and it has to. -Unattended's documented
# meaning is "never ask anything", and a Windows consent dialog is asking - one
# nobody would ever see, on a run that has already gone on without a person.
function Test-CaptainPresent {
    if ($Unattended) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    $true
}

function Confirm-Update {
    param([Parameter(Mandatory)][string]$Question)

    if (-not (Test-CaptainPresent)) { return $false }
    Say ''
    Say "  $Question"
    $answer = Read-Host '  Update it? [y/N]'
    return ($answer -match '^(y|yes)$')
}

# THE ONE BIG DOWNLOAD, AND THE ONLY QUESTION HERE WHOSE DEFAULT IS YES.
#
# WHY IT IS ASKED AT ALL. Everything else this installer fetches is a few
# megabytes; the speech model is 1.4 GB, which is a real cost on a metered or
# slow connection and the kind of thing somebody is entitled to be told about
# BEFORE it starts rather than to discover from a progress bar. So the size, and
# what declining costs, are printed first.
#
# WHY THE DEFAULT IS YES, unlike Confirm-Update above. That question is "may I
# change something that already works", where the safe answer is always no. This
# one is "may I finish the thing you asked for": the captain asked for speech in
# the installer, and an engine with no model is not that - it drops them into a
# settings screen the first time they turn voice on. Declining is safe and
# reversible; the machine works, and re-running fetches it.
#
# WHY SILENCE MEANS FETCH. -Unattended and a redirected stdin take the DEFAULT,
# and here the default is yes - which is the opposite of Confirm-Update and is
# deliberate. An unattended run is precisely the "one command does everything"
# case the captain's standing instruction is about, and skipping there would
# quietly produce the half-installed machine this step exists to prevent. Nobody
# is being surprised: a run with nobody at the keyboard is a script somebody
# wrote, and -SkipSpeechModel is how that script says no.
function Confirm-SpeechModel {
    # WHAT IS BEING DOWNLOADED IS THE PLAN'S ANSWER, not a second copy of it
    # here. The size in particular: a number retyped into a warning is a number
    # that goes stale the day the pinned model changes, and this one is the whole
    # reason the question is being asked.
    param([Parameter(Mandatory)]$Speech)

    if ($SkipSpeechModel) { return $false }
    Say ''
    Say '  The speech engine needs a model, and it is a LARGE download:'
    Say ''
    Say ("    {0}   {1}   30 languages, auto language detection" -f $Speech.ModelName, $Speech.ModelSizeText)
    Say ''
    Say '  Without it the engine is installed but has nothing to transcribe with.'
    Say '  Declining is safe: the machine still works, the summary says the model is'
    Say '  absent, and re-running this script fetches it. Either way voice stays OFF -'
    Say '  no microphone is opened until you create config/voice.'
    if (-not (Test-CaptainPresent)) {
        Say ''
        Say '  Nobody is at the keyboard, so this is taking the default and fetching it.'
        Say '  Pass -SkipSpeechModel to install the engine without it.'
        return $true
    }
    $answer = Read-Host '  Download it now? [Y/n]'
    return ($answer -notmatch '^(n|no)$')
}

. (Join-Path $PSScriptRoot 'bin' 'fm-module-load.ps1') -RequiredCommand 'Install-FmMachine'

Say ''
Say '  FIRSTMATE - install'
Say ''

# ---- 1. what this machine has, and what it needs ----------------------------
$plan = Get-FmMachineInstallPlan -SkipOptional:$SkipOptional -Offline:$Offline -RepoRoot $PSScriptRoot
foreach ($line in $plan.Lines) { Say $line }
Say ''

foreach ($enabler in $plan.Enablers) {
    if ($enabler.Satisfied) { continue }
    Warn "  $($enabler.Name) is not on this machine, and it is what provides $($enabler.Enables)."
    Warn "    $($enabler.Fix)"
    Say ''
}

# ---- 2. unsupported versions are TOLD, never repaired uninvited --------------
foreach ($requirement in $plan.Unsupported) {
    Warn "  $($requirement.Label) cannot work at the version installed."
    Warn "    $($requirement.Reason)"
    Warn "    Please update it yourself: $($requirement.UpdateCommand)"
    Warn '    This installer will SKIP that step rather than install over the top of it.'
    Say ''
}

# ---- 2a. a module below the floor is INSTALLED BESIDE what is there ----------
# Not the same case as the block above, and the difference is what it does to the
# copy already on the machine: PowerShell keeps every version of a module in its
# own version directory, so this adds one and removes nothing. Windows ships
# Pester 3.4.0 on every machine, which made this the ordinary case - and
# refusing it is what used to end a clean-machine run with a command for the
# captain to run by hand.
foreach ($requirement in $plan.Superseded) {
    Say "  $($requirement.Label) is below what this repo needs, and nothing here replaces it."
    Say "    $($requirement.Reason)"
    Say ''
}

# ---- 2b. and so is a tool this machine will not start ------------------------
# Installing a second copy into the same place would be refused in the same way,
# so this is told rather than repaired, exactly like the block above.
foreach ($requirement in $plan.Unusable) {
    Warn "  $($requirement.Label) is installed, and this machine will not start it."
    Warn "    $($requirement.Reason)"
    Warn '    This installer will SKIP that step rather than install another copy it cannot run.'
    Say ''
}

if ($DetectOnly) {
    Say '  -DetectOnly: nothing was installed and nothing was left changed.'
    Say ''
    exit 0
}

# ---- 3. the optional updates, one question each -----------------------------
$agreed = @()
foreach ($requirement in $plan.Older) {
    if (Confirm-Update -Question $requirement.Question) { $agreed += $requirement.Name }
}
if ($plan.Older.Count -gt 0) { Say '' }

# ---- 3a. the ONE step that needs administrator ------------------------------
#
# THE CAPTAIN'S INSTRUCTION, and it overrides a rule this installer set itself:
# everything must be done from this script, with nothing left for them to run by
# hand. This run used to print the command for the Visual C++ runtime and stop
# there - and they ran it themselves on a fresh VM, which is exactly what the
# rule was supposed to prevent.
#
# WINDOWS CAN ELEVATE ONE CHILD, so this run stays unelevated and one step asks.
# What appears is the standard consent dialog, and it is raised immediately under
# the paragraph below - because a consent dialog with no explanation above it is
# indistinguishable from something going wrong.
#
# NOBODY AT THE KEYBOARD MEANS NOBODY TO SEE IT. -Unattended and a redirected
# stdin both skip this entirely and say so; a dialog waiting on a person who is
# not there is the halt this installer's no-prompting rule exists to prevent.
$installRuntime = $false
if (-not $plan.Runtime.Present) {
    Say '  ONE THING ON THIS MACHINE NEEDS ADMINISTRATOR, and it is not firstmate:'
    Say ''
    Say "    $($plan.Runtime.Detail)"
    Say ''
    Say '  herdr - what worker sessions run in - imports it, and Windows stops a program'
    Say '  that needs it before it runs a line of its own code. The runtime installs'
    Say '  machine-wide, which is the whole reason this one step asks when nothing else'
    Say '  in this run does.'
    Say ''
    if (Test-CaptainPresent) {
        Say '  Windows is about to ask you to allow it. Everything else in this run is'
        Say '  installed into your own profile and asks for nothing.'
        Say ''
        Say '  Saying no is safe: the rest still installs, this run still finishes, and it'
        Say '  ends by telling you herdr could not be proven and naming the command below.'
        Say ''
        Say "    $($plan.Runtime.Command)"
        Say ''
        $installRuntime = $true
    } else {
        $why = if ($Unattended) { '-Unattended was given' } else { 'this run has no console to answer on' }
        Warn "  SKIPPED, because $why - an administrator prompt needs somebody at the keyboard."
        Warn '  Everything else still installs. Run this yourself in an ADMINISTRATOR window:'
        Warn ''
        Warn "    $($plan.Runtime.Command)"
        Say ''
    }
}

# ---- 3b. the one large download, asked before it starts ---------------------
# Only when the engine is going to be there to use it: -SkipOptional drops the
# engine, and 1.4 GB for a program that will not be installed is pure waste.
#
# AND ONLY WHEN THERE IS SOMETHING TO DOWNLOAD. A machine that already has the
# model must not be asked about fetching it - the answer would change nothing,
# and a question whose answer changes nothing trains the captain to stop reading
# them. Install-FmMachine asks the engine again and is the authority; this asks
# only to decide whether the QUESTION is worth putting.
$speechWanted = @($plan.Requirements | Where-Object { $_.Name -eq 'handy' }).Count -gt 0
$speechModel = 'skip'
if ($speechWanted) {
    if ($plan.Speech.ModelReady -or (Confirm-SpeechModel -Speech $plan.Speech)) { $speechModel = 'fetch' }
    Say ''
}

# ---- 4. install ---------------------------------------------------------------
# Running this script IS the consent to install what is missing; that is the
# whole job it was invoked for, so it is not re-asked one tool at a time.
Say '  Installing what is missing, and proving the result. This takes a few minutes.'
Say ''
# The plan is handed over rather than recomputed: it already asked every vendor
# what it publishes, and asking them a second time would double the slowest part
# of the run for an answer that cannot have changed since the prompt above.
$report = Install-FmMachine -Approved -Plan $plan -UpdateTool $agreed -InstallRuntime:$installRuntime `
    -SkipOptional:$SkipOptional -SkipSuite:$SkipSuite -Offline:$Offline -RepoRoot $PSScriptRoot `
    -SpeechModel $speechModel -Confirm:$false

foreach ($line in $report.Lines) { Say ([string]$line) }
Say ''

if (-not $report.Ready) {
    Warn '  This machine is NOT fully ready. The summary above names every requirement and its outcome.'
    Say ''
    exit 1
}

# NOT A STEP IN THE INSTALL. Everything above is done and proven; what is left is
# the WINDOW you are standing in, which took its copy of PATH when it opened and
# cannot be given a new one from inside.
#
# WHY THIS ENDING CHANGED. It used to say "type this in a NEW one" and name
# `firstmate`. That was true, and two clean-machine installs in a row still ended
# on an error, because the captain typed it here - `firstmate` the second time,
# `claude` and `.\start.ps1` the time before. A finish line most people trip over
# is badly placed, and blaming the reader is the wrong conclusion.
#
# So the run no longer ends by sending the captain somewhere else. It names the
# command that works in THIS window, and then offers to do the last step here.
# Public/FmMachineStart.ps1 owns both, has the measurements behind them, and says
# why a bare `firstmate` in this window can be neither made to work nor made to
# teach: the installer is not running in the captain's session and never was.
foreach ($line in (Get-FmMachineStartLine -ShimPath $report.StartCommand -RepoRoot $PSScriptRoot)) { Say $line }

# THE OFFER, AND WHY IT IS SAFE. Nothing in this repo may start itself - it is
# how the captain ended up with audio playing from a window they could not find -
# so this asks, once, and only an explicit yes starts anything. Pressing Enter is
# a no. -Unattended and a redirected stdin are never asked at all, on exactly the
# reasoning Test-CaptainPresent already states for the administrator prompt.
$answer = ''
$captainPresent = Test-CaptainPresent
if ($captainPresent) { $answer = [string](Read-Host '  Start firstmate now? [y/N]') }

$absence = if ($Unattended) { '-Unattended was given' } else { 'this run has no console to answer on' }
$decision = Get-FmMachineStartDecision -Answer $answer -CaptainPresent:$captainPresent -AbsenceReason $absence
Say ''
foreach ($line in $decision.Lines) { Say $line }
if (-not $decision.Start) {
    Say ''
    exit 0
}

# In THIS process, which is the PowerShell 7 this script relaunched itself into
# and which already has the shim on its PATH. The shim exists for the captain's
# other windows; going through it here would only add a process.
& (Join-Path $PSScriptRoot 'start.ps1')
exit 0
