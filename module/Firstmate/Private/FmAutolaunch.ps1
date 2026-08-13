#requires -Version 7.0
# module/Firstmate/Private/FmAutolaunch.ps1 - opt-in auto-start of a command in
# a herdr pane, with a grace period the captain can interrupt.
#
# WHAT THIS IS. The captain sits down at the Windows laptop, a herdr pane comes
# up, and the command they always type is typed FOR them - visibly, unsubmitted -
# with a countdown they can cancel simply by touching the keyboard. Untouched at
# the end of the window, firstmate presses Enter itself.
#
# WHY IT IS OFF UNTIL A FILE SAYS OTHERWISE. The command the captain chose for
# their own machine (`claude --dangerously-skip-permissions --continue --chrome`)
# turns OFF a real safety boundary for every session it starts. That is theirs to
# choose, but it must never be a default that surprises the next person to open
# this repo. So: no config/autolaunch, no behaviour, and the command itself lives
# in that file rather than in this code. bin/fm-doctor.ps1 prints the resolved
# command whenever it is on, so an enabled autolaunch is never invisible.
#
# THE ONE THING THAT MATTERS: THE CAPTAIN'S INPUT WINS.
# A grace period that types over the captain is worse than no grace period, so
# every step of the window fails toward STANDING DOWN:
#
#   - before typing, the pane must be legibly idle by herdr's own agent state
#     AND byte-identical across two captures a settle apart. A pane that is
#     running something, or that is changing under us, is never typed into.
#   - after typing, the exact capture bytes become the armed baseline. Every
#     poll of the window must reproduce them EXACTLY and must still read idle.
#     A changed capture is the captain typing; an unreadable one is a pane we
#     cannot prove anything about. Both stand down.
#   - standing down NEVER touches the pane again: no Enter, no clear, no keys.
#     Whatever the captain typed stays exactly where they typed it, after the
#     command firstmate had already placed there for them to see.
#
# Standing down wrongly costs the captain one keypress. Submitting wrongly runs
# an unpermissioned agent they did not ask for. Those are not symmetric, and the
# code is not symmetric either.
#
# WHY THE UNCHANGED-BYTES TEST RATHER THAN A COMPOSER SHAPE VERDICT.
# Composer SHAPE classification (is this composer empty, does it hold a draft)
# is owned fleet-wide by bin/fm-composer-lib.sh and is deliberately not ported
# here (see FmBackendHerdr.ps1's header), so Get-FmHerdrComposerState reports
# 'unknown' on this port. This area therefore asks a question it CAN answer
# exactly - "did one single byte of this pane change while we waited" - which is
# a strictly stronger test of "untouched" than a shape verdict would be. The
# shape verdict is still consulted: if a classifier is ever loaded and reports
# anything other than an empty composer before typing, that is the captain
# mid-draft and this stands down. 'unknown' alone never licenses typing on its
# own - the idle agent state and the two matching captures do.
#
# The cost of that strictness is real and accepted: a pane whose prompt repaints
# on its own (a clock, a spinner) never reads as unchanged, so autolaunch will
# refuse it rather than fire. That is the safe direction.
#
# WINDOWS-UNVERIFIED: every function here that talks to a live herdr server. The
# tests drive the whole state machine through mocked adapter calls.

Set-StrictMode -Version Latest

# The config file, its default delay, and the ceiling on a configured one. The
# ceiling exists so a fat-fingered `delay=100000` is a refusal the captain sees
# rather than a pane that quietly never fires.
$script:FmAutolaunchConfigName = 'autolaunch'
$script:FmAutolaunchDefaultDelaySeconds = 10
$script:FmAutolaunchMaxDelaySeconds = 3600

# Rows every autolaunch capture compares. Deliberately the same window the
# composer read uses, so "unchanged" means unchanged over the region a composer
# draft would appear in.
$script:FmAutolaunchCaptureLines = 40

# --- configuration -----------------------------------------------------------

# Read-FmAutolaunchConfig: resolve config/autolaunch into a decision.
#
# Status is one of:
#   off      - no file. The feature does not exist for this home.
#   enabled  - a complete, valid file. Command and DelaySeconds are usable.
#   invalid  - a file that is present but not usable. This is NOT treated as
#              off-and-never-mind: the caller refuses and the doctor prints it,
#              because a typo silently disabling a feature the captain believes
#              is on is exactly the failure this format is strict to avoid.
#
# The strictness is why this parses the file itself rather than calling
# Read-FmKeyValueFile: that reader owns state/<id>.meta, where an unrecognized
# line is ignored on purpose and the last duplicate wins. Here an unrecognized
# key, a duplicate, or a line that is not key=value is a refusal.
function Read-FmAutolaunchConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $path = Join-Path -Path $ConfigDir -ChildPath $script:FmAutolaunchConfigName
    $off = {
        param($reason)
        [pscustomobject]@{
            Path = $path; Status = 'off'; Enabled = $false; Command = ''
            DelaySeconds = $script:FmAutolaunchDefaultDelaySeconds; Reason = $reason
        }
    }
    $invalid = {
        param($reason)
        [pscustomobject]@{
            Path = $path; Status = 'invalid'; Enabled = $false; Command = ''
            DelaySeconds = $script:FmAutolaunchDefaultDelaySeconds; Reason = $reason
        }
    }

    if (-not [System.IO.File]::Exists($path)) {
        return (& $off "no $path - autolaunch is off")
    }
    # This file names a command firstmate will run unattended, so it must be the
    # regular file it looks like and not a link pointing somewhere else.
    try {
        if ([System.IO.FileInfo]::new($path).LinkTarget) {
            return (& $invalid "$path is a link; autolaunch reads a regular file only")
        }
    } catch {
        return (& $invalid "$path could not be inspected: $($_.Exception.Message)")
    }

    try {
        $lines = [System.IO.File]::ReadAllLines($path)
    } catch {
        return (& $invalid "$path could not be read: $($_.Exception.Message)")
    }

    $fields = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    $number = 0
    foreach ($line in $lines) {
        $number++
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $index = $trimmed.IndexOf('=')
        if ($index -lt 1) {
            return (& $invalid "$path line ${number}: expected key=value, got '$trimmed'")
        }
        $key = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim()
        if ($key -cnotin @('command', 'delay')) {
            return (& $invalid "$path line ${number}: unknown key '$key' (expected command or delay)")
        }
        if ($fields.Contains($key)) {
            return (& $invalid "$path line ${number}: '$key' is set twice")
        }
        $fields[$key] = $value
    }

    if (-not $fields.Contains('command')) {
        return (& $invalid "$path has no command= line, so there is nothing to start")
    }
    $command = [string]$fields['command']
    if (-not $command) {
        return (& $invalid "$path has an empty command=")
    }

    $delay = $script:FmAutolaunchDefaultDelaySeconds
    if ($fields.Contains('delay')) {
        $raw = [string]$fields['delay']
        if ($raw -notmatch '^[0-9]+$') {
            return (& $invalid "$path has delay='$raw', which is not a whole number of seconds")
        }
        $parsed = [int]$raw
        if ($parsed -lt 1 -or $parsed -gt $script:FmAutolaunchMaxDelaySeconds) {
            return (& $invalid ("$path has delay=$parsed, outside 1-$($script:FmAutolaunchMaxDelaySeconds) seconds " +
                    '(a zero-second window would leave the captain nothing to interrupt)'))
        }
        $delay = $parsed
    }

    [pscustomobject]@{
        Path         = $path
        Status       = 'enabled'
        Enabled      = $true
        Command      = $command
        DelaySeconds = $delay
        Reason       = "$path selects '$command' after ${delay}s"
    }
}

# Get-FmAutolaunchCheck: the doctor's line for this feature.
#
# An enabled autolaunch always prints the EXACT command, because the whole point
# of making it opt-in is that a captain (or the next person to read this home)
# can see what will run without opening a file.
function Get-FmAutolaunchCheck {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$ConfigDir)

    $config = Read-FmAutolaunchConfig -ConfigDir $ConfigDir
    switch ($config.Status) {
        'enabled' {
            return @(New-FmInstallCheck -Name 'autolaunch' -Status 'ok' `
                    -Detail ("on - types '$($config.Command)' into a named pane and submits it after " +
                        "$($config.DelaySeconds)s unless the pane is touched"))
        }
        'invalid' {
            # A warning, not a missing: the home is installed correctly and
            # nothing is auto-started. The cost is that the captain believes a
            # feature is on which is not, so the line says exactly why.
            return @(New-FmInstallCheck -Name 'autolaunch' -Status 'warn' `
                    -Detail "off - $($config.Reason)" `
                    -Fix "correct $($config.Path) (command=<command>, optional delay=<seconds>) or delete it")
        }
        default {
            return @(New-FmInstallCheck -Name 'autolaunch' -Status 'ok' `
                    -Detail 'off - no config/autolaunch, so nothing is started automatically')
        }
    }
}

# --- pane safety -------------------------------------------------------------

# Test-FmAutolaunchWorkerPane: is this target a pane THIS home already recorded
# as a worker's? Autolaunch types an interactive command, so a worker endpoint is
# never a legitimate destination - one that got typed into would receive the
# command as chat, or lose its own composer contents.
function Test-FmAutolaunchWorkerPane {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][AllowEmptyString()][string]$StateDir
    )
    if (-not $StateDir) { return $false }
    if (-not [System.IO.Directory]::Exists($StateDir)) { return $false }
    $parsed = Split-FmHerdrTarget -Target $Target
    foreach ($meta in [System.IO.Directory]::GetFiles($StateDir, '*.meta')) {
        $record = Get-FmTaskRecord -Path $meta
        if (-not $record) { continue }
        if ($record.Window -and $record.Window -eq $Target) { return $true }
        if ($parsed -and $record.HerdrPaneId -and $record.HerdrPaneId -eq $parsed.PaneId) { return $true }
    }
    $false
}

# New-FmAutolaunchResult: the one shape every exit from the state machine takes.
#
#   submitted    - Enter was sent and herdr confirmed a turn started.
#   unconfirmed  - Enter was sent and the confirmation could not be read. The
#                  command may or may not be running; the caller must say so.
#   stood-down   - the command was typed, the captain (or an unreadable pane)
#                  interrupted the window, and nothing was submitted.
#   refused      - nothing was typed at all, and Reason says what stopped it.
#   disabled     - no config, so there was nothing to do.
#   skipped      - -WhatIf.
function New-FmAutolaunchResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; nothing outside the pipeline changes.')]
    param(
        [Parameter(Mandatory)][ValidateSet('submitted', 'unconfirmed', 'stood-down', 'refused', 'disabled', 'skipped')]
        [string]$Action,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Target = '',
        [string]$Command = '',
        [int]$DelaySeconds = 0,
        [switch]$Armed
    )
    [pscustomobject]@{
        Action       = $Action
        Reason       = $Reason
        Target       = $Target
        Command      = $Command
        DelaySeconds = $DelaySeconds
        Armed        = [bool]$Armed
        Submitted    = ($Action -eq 'submitted')
    }
}

# --- the arm / grace / submit state machine ----------------------------------

# Test-FmAutolaunchPaneIdle: herdr's own agent state for the pane, reduced to the
# one answer this area accepts. Only a legible 'idle' is a yes; 'busy' means
# something is running there and 'unknown' means we could not read it, and both
# of those are reasons not to type.
function Test-FmAutolaunchPaneIdle {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Target)
    $state = Get-FmHerdrBusyState -Target $Target
    if ($state -eq 'idle') { return '' }
    if ($state -eq 'busy') { return 'the pane is running something' }
    "the pane's state could not be read (herdr reported '$state')"
}

# Invoke-FmAutolaunchArm: type <Command> into <Target>, hold the grace window,
# and submit only if every single check in it confirms the pane is untouched.
#
# -PollSeconds and -SettleSeconds are parameters rather than constants so the
# tests can drive the whole window in milliseconds; their defaults are the real
# operating values.
function Invoke-FmAutolaunchArm {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][int]$DelaySeconds,
        [double]$PollSeconds = 1,
        [double]$SettleSeconds = 0.4
    )

    $result = {
        param($action, $reason, [switch]$armed)
        New-FmAutolaunchResult -Action $action -Reason $reason -Target $Target -Command $Command `
            -DelaySeconds $DelaySeconds -Armed:$armed
    }

    if (-not (Split-FmHerdrTarget -Target $Target)) {
        return (& $result 'refused' "'$Target' is not a herdr pane target of the form <session>:<pane-id>")
    }
    if (-not (Test-FmHerdrTargetReady -Target $Target)) {
        return (& $result 'refused' "the herdr session for '$Target' could not be reached")
    }
    if (-not (Test-FmHerdrTargetExists -Target $Target)) {
        return (& $result 'refused' "there is no live pane '$Target'")
    }

    $notIdle = Test-FmAutolaunchPaneIdle -Target $Target
    if ($notIdle) { return (& $result 'refused' "nothing was typed: $notIdle") }

    # The shape verdict, when a classifier is loaded. 'unknown' is this port's
    # normal answer and is carried by the unchanged-bytes test below; anything
    # else that is not a confirmed-empty composer is a draft we must not join.
    $composer = Get-FmHerdrComposerState -Target $Target
    if ($composer -notin @('empty', 'unknown')) {
        return (& $result 'refused' "nothing was typed: the pane's composer is not empty (state '$composer')")
    }

    $before = Get-FmHerdrCapture -Target $Target -Lines $script:FmAutolaunchCaptureLines
    if ($null -eq $before) {
        return (& $result 'refused' "nothing was typed: the pane '$Target' could not be read")
    }
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    $stillBefore = Get-FmHerdrCapture -Target $Target -Lines $script:FmAutolaunchCaptureLines
    if ($null -eq $stillBefore) {
        return (& $result 'refused' "nothing was typed: the pane '$Target' stopped being readable")
    }
    if ($stillBefore -cne $before) {
        return (& $result 'refused' 'nothing was typed: the pane is changing, so it is already in use')
    }

    if (-not $PSCmdlet.ShouldProcess($Target, "type '$Command' and submit it after ${DelaySeconds}s unless touched")) {
        return (& $result 'skipped' 'WhatIf: nothing was typed')
    }

    if (-not (Send-FmHerdrLiteral -Target $Target -Text $Command)) {
        return (& $result 'refused' "the command could not be typed into '$Target'")
    }
    if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }

    # From here on the pane HAS firstmate's text in it, so every remaining exit
    # leaves it there unsubmitted rather than trying to tidy up.
    $armed = Get-FmHerdrCapture -Target $Target -Lines $script:FmAutolaunchCaptureLines
    if ($null -eq $armed) {
        return (& $result 'stood-down' 'the command was typed but the pane stopped being readable; nothing was submitted' -armed)
    }
    if ($armed -ceq $before) {
        return (& $result 'stood-down' 'the typed command never appeared in the pane; nothing was submitted' -armed)
    }

    # The grace window. Every poll must reproduce the armed capture EXACTLY and
    # must still read idle; the first that does not ends the window in the
    # captain's favour.
    $deadline = [datetime]::UtcNow.AddSeconds($DelaySeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        $sleep = [math]::Min([math]::Max($PollSeconds, 0), [math]::Max($remaining, 0))
        if ($sleep -gt 0) { Start-Sleep -Seconds $sleep }

        $now = Get-FmHerdrCapture -Target $Target -Lines $script:FmAutolaunchCaptureLines
        if ($null -eq $now) {
            return (& $result 'stood-down' 'the pane stopped being readable during the wait; nothing was submitted' -armed)
        }
        if ($now -cne $armed) {
            return (& $result 'stood-down' 'the pane changed during the wait, so the captain is using it; nothing was submitted' -armed)
        }
        $notIdle = Test-FmAutolaunchPaneIdle -Target $Target
        if ($notIdle) {
            return (& $result 'stood-down' "$notIdle during the wait; nothing was submitted" -armed)
        }
    }

    $parsed = Split-FmHerdrTarget -Target $Target
    if (-not (Send-FmHerdrKey -Target $Target -Key 'Enter')) {
        return (& $result 'stood-down' 'the wait completed but Enter could not be sent; the command is still unsubmitted' -armed)
    }
    $verdict = Wait-FmHerdrWorking -Session $parsed.Session -PaneId $parsed.PaneId
    if ($verdict -eq 'busy') {
        return (& $result 'submitted' "started '$Command' after ${DelaySeconds}s untouched" -armed)
    }
    (& $result 'unconfirmed' ("Enter was sent after ${DelaySeconds}s untouched, but the pane did not confirm the " +
            "command started (herdr reported '$verdict')") -armed)
}
