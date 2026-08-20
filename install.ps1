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
  unsupported    installed but below a minimum this repo actually states. You
                 are TOLD, the step is SKIPPED, and nothing is installed over
                 the top of it. A machine in that state is reported as NOT
                 READY rather than finished.

NO STEP NEEDS ADMINISTRATOR. Every tool comes from a per-user installer or a
release archive expanded under %LOCALAPPDATA%\Programs. The two routes that
genuinely need elevation - the winget packages for git and Node.js - are named
and skipped on an unelevated run, and everything else still installs.

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
tool exactly as it is. This is the safe default for every question. `-Yes` is
the same switch.

.PARAMETER SkipOptional
Install only what firstmate cannot run without.

.PARAMETER SkipSuite
Do not run the test suite at the end. The verdict then says the install is
unproven rather than claiming a pass it did not take.

.PARAMETER Offline
Do not ask any vendor what it publishes. Nothing is then classified as older,
and the report says currency was not checked.

.PARAMETER DetectOnly
Print what this machine has and what it needs, and change nothing.

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

    $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) {
        $localPwsh = Join-Path $env:LOCALAPPDATA 'Programs\PowerShell7\pwsh.exe'
        if (Test-Path -LiteralPath $localPwsh) { $pwshCommand = Get-Command -Name $localPwsh -ErrorAction SilentlyContinue }
    }

    if (-not $pwshCommand) {
        # Microsoft's own installer, pointed at a per-user directory: it takes
        # the zip rather than the MSI, so it needs no administrator.
        $installLine = '& ([scriptblock]::Create((Invoke-RestMethod https://aka.ms/install-powershell.ps1))) ' +
        '-Destination "$env:LOCALAPPDATA\Programs\PowerShell7" -AddToPath'
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
# stdin, a CI run, or -Unattended all take the safe default instead of waiting
# for an answer nobody is there to give.
function Confirm-Update {
    param([Parameter(Mandatory)][string]$Question)

    if ($Unattended) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    Say ''
    Say "  $Question"
    $answer = Read-Host '  Update it? [y/N]'
    return ($answer -match '^(y|yes)$')
}

. (Join-Path $PSScriptRoot 'bin' 'fm-module-load.ps1') -RequiredCommand 'Install-FmMachine'

Say ''
Say '  FIRSTMATE - install'
Say ''

# ---- 1. what this machine has, and what it needs ----------------------------
$plan = Get-FmMachineInstallPlan -SkipOptional:$SkipOptional -Offline:$Offline
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
    Say '  -DetectOnly: nothing was changed.'
    Say ''
    exit 0
}

# ---- 3. the optional updates, one question each -----------------------------
$agreed = @()
foreach ($requirement in $plan.Older) {
    if (Confirm-Update -Question $requirement.Question) { $agreed += $requirement.Name }
}
if ($plan.Older.Count -gt 0) { Say '' }

# ---- 4. install ---------------------------------------------------------------
# Running this script IS the consent to install what is missing; that is the
# whole job it was invoked for, so it is not re-asked one tool at a time.
Say '  Installing what is missing, and proving the result. This takes a few minutes.'
Say ''
# The plan is handed over rather than recomputed: it already asked every vendor
# what it publishes, and asking them a second time would double the slowest part
# of the run for an answer that cannot have changed since the prompt above.
$report = Install-FmMachine -Approved -Plan $plan -UpdateTool $agreed -SkipOptional:$SkipOptional `
    -SkipSuite:$SkipSuite -Offline:$Offline -RepoRoot $PSScriptRoot -Confirm:$false

foreach ($line in $report.Lines) { Say ([string]$line) }
Say ''

if (-not $report.Ready) {
    Warn '  This machine is NOT fully ready. The summary above names every requirement and its outcome.'
    Say ''
    exit 1
}

Say '  Open a NEW shell, so the `firstmate` command is on PATH, then:'
Say ''
Say '    firstmate          start it - opens your browser, everything happens there'
Say ''
exit 0
