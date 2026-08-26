#requires -Version 7.0
Set-StrictMode -Version Latest

# FmMachineStart.ps1 - the last ten seconds of an install: what the captain is
# told about starting firstmate, and who decides whether it starts.
#
# WHY THIS AREA EXISTS AT ALL. Two clean-machine installs in a row ended on an
# error. The run finished perfectly, printed "open a NEW window and type
# firstmate", and the captain typed it in the window they were standing in -
# `firstmate` the second time, `claude` and `.\start.ps1` the time before.
#
# WHAT IS ACTUALLY TRUE, measured rather than assumed - the reproduction is in
# `docs/windows-install.md` under "The last ten seconds":
#
#   - The installing PROCESS resolves `firstmate` perfectly well. Add-FmToolUserPath
#     updates `$env:PATH` for the process it runs in, so the shim is on the PATH
#     of the pwsh that ran the install.
#   - The captain's WINDOW is not that process. `powershell -ExecutionPolicy
#     Bypass -File .\install.ps1` is a child, and install.ps1 relaunches itself
#     under pwsh, so the work happens two processes below the prompt. Nothing a
#     child does can reach an ancestor's environment, and no design can change
#     that.
#   - So a bare `firstmate` in that window cannot be made to work, and cannot be
#     made to teach either: a function would have to be defined in the captain's
#     own session, and the installer never runs there.
#
# WHAT CAN BE DONE, and is what this file is: stop ending on an instruction to
# go somewhere else. Name a command that works in the window the captain is
# already in, and offer to finish the job here.

<#
.SYNOPSIS
    How to start firstmate, said for the window the captain is standing in.

.DESCRIPTION
    The closing lines of an install. They give two commands rather than one,
    because the two windows a captain can be in need different answers:

      - the INSTALLING window took its copy of PATH when it opened, so the
        one-word command is not in it and cannot be put there. The shim's full
        path works there anyway - it needs neither PATH nor an execution policy,
        because a `.cmd` is not subject to one and the `pwsh` it starts is given
        `-ExecutionPolicy Bypass`.
      - any NEW window has the PATH the install wrote, so `firstmate` works.

    Naming both, and saying which is which, is the whole point: the previous
    ending named only the one that does not work where it was being read.

    A run whose shim could not be written has neither, and gets a single command
    through `pwsh` instead rather than a pair naming a file that is not there.

.PARAMETER ShimPath
    Full path to the `firstmate.cmd` this run wrote, or an empty string when it
    could not be written. `Install-FmMachine` reports it as `StartCommand`.

.PARAMETER RepoRoot
    The checkout, used only for the fallback when there is no shim.

.EXAMPLE
    Get-FmMachineStartLine -ShimPath 'C:\Users\me\AppData\Local\Programs\firstmate\firstmate.cmd' -RepoRoot 'C:\Users\me\firstmate'
#>
function Get-FmMachineStartLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ShimPath,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $lines = @(
        '  HOW TO START IT. This window took its copy of PATH when it opened, so the'
        '  one-word command is not in it yet - a program cannot reach back into a window'
        '  that is already running, and no installer can.'
        ''
    )

    # NO SHIM IS A DIFFERENT ANSWER, not a missing line. Set-FmMachineCommandShim
    # is allowed to fail without failing the install - everything is installed
    # and the home is wired, and what is absent is a one-word command. Printing
    # the pair anyway would name a file that is not there.
    if (-not $ShimPath) {
        return [string[]]($lines + @(
                '  The one-word command could not be written on this machine either, so this is'
                '  what starts firstmate from any window until that is sorted out:'
                ''
                "    pwsh -NoProfile -File `"$(Join-Path $RepoRoot 'start.ps1')`""
                ''
            ))
    }

    [string[]]($lines + @(
            '  So which of these you want depends only on which window you are in:'
            ''
            "    $ShimPath"
            '        works HERE, in this window, right now'
            ''
            '    firstmate'
            '        works in any NEW window, from now on'
            ''
        ))
}

<#
.SYNOPSIS
    Whether the install may start firstmate, and what it says about not doing so.

.DESCRIPTION
    The consent gate on the one thing an install is otherwise forbidden to do.

    `AGENTS.md` is emphatic that nothing starts itself - it is how the captain
    ended up with audio playing from a window they could not find - so this
    function exists to make "only an explicit yes starts it" a decision that can
    be tested, rather than a condition buried in `install.ps1`.

    THREE THINGS ARE A NO, and only one thing is a yes. No captain at the
    keyboard is a no and is never even asked. An empty answer is a no, so
    pressing Enter cannot start anything. Anything that is not `y` or `yes` is a
    no. That is the opposite of `Confirm-SpeechModel`, whose default is yes, and
    the difference is what the two questions do: one finishes a download, this
    one starts a process and opens a browser.

.PARAMETER Answer
    What the captain typed, or an empty string when they were not asked.

.PARAMETER CaptainPresent
    Somebody is at the keyboard. `install.ps1` decides this with
    `Test-CaptainPresent`: `-Unattended` and a redirected stdin are both absent.

.PARAMETER AbsenceReason
    Why nobody was asked, said back to whoever reads the transcript later.

.EXAMPLE
    (Get-FmMachineStartDecision -Answer 'y' -CaptainPresent).Start
    True

.EXAMPLE
    (Get-FmMachineStartDecision -Answer '' -CaptainPresent).Start
    False
#>
function Get-FmMachineStartDecision {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Answer,
        [switch]$CaptainPresent,
        [AllowEmptyString()][string]$AbsenceReason = ''
    )

    if (-not $CaptainPresent) {
        $why = if ($AbsenceReason) { $AbsenceReason } else { 'nobody is at the keyboard' }
        return [pscustomobject]@{
            Start = $false
            Lines = [string[]]@("  Nothing was started, because $why.", '  What is printed above starts it whenever you like.')
        }
    }

    # Trimmed, because a captain who typed a trailing space still said yes; and
    # anchored, because "yes please" is a sentence this must not read as consent
    # on a question whose cost is a running process.
    if ($Answer.Trim() -match '^(y|yes)$') {
        return [pscustomobject]@{ Start = $true; Lines = [string[]]@() }
    }

    [pscustomobject]@{
        Start = $false
        Lines = [string[]]@('  Not started. What is printed above starts it whenever you like.')
    }
}
